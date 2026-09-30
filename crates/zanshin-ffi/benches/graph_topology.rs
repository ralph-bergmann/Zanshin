// SPDX-License-Identifier: MIT

//! Story 4.10 re-measure: the index-only graph topology call and the op-pinned content call,
//! per store kind.
//!
//! Stores: `medium-1k-commits` and `large-10k-commits` as committed (every object LOOSE), and a
//! `git gc`-PACKED copy of `large-10k-commits` (packed in the bench's own extracted temp copy,
//! fixture-setup style — the only shell-out). Per store it times:
//!
//! - `Repo::graph_topology` over `all()` with the default anchors — the call total;
//! - `Repo::snapshot()` on the unchanged tree — the precondition's share of that total;
//! - the same call with NO anchors — the anchor share is the difference;
//! - the same call `with_timestamps` — the per-call object loads — both repeated on the reused
//!   handle and as the FIRST call on a fresh handle (Story 4.10 OQ 1's trigger is the first
//!   call);
//! - `zanshin_commit_contents` pages of 60 and 200 ids, without and with a merge in the page,
//!   before and after building jj's changed-path index — each on a FRESH handle (a cold commit
//!   cache, as the first page after a reload is);
//! - an EMPTY-list content call — the pinned `load_operation` + `load_at` share of a page;
//! - topology + contents for every id, and `Repo::walk_graph(all())` driven to the end — the
//!   old one-call cost — each on a fresh handle.
//!
//! Prints node counts and min / median only; asserts nothing about wall-clock. Not run by
//! `cargo make test` / coverage (benches are excluded; see docs/coverage.md):
//!
//! ```sh
//! cargo bench -p zanshin-ffi --bench graph_topology
//! ```

use std::ffi::CString;
use std::ops::ControlFlow;
use std::path::Path;
use std::process::Command;
use std::sync::LazyLock;
use std::time::{Duration, Instant};
use std::{env, hint};

use test_helpers::{build_changed_path_index, extract_fixture};
use zanshin_ffi::commit_contents::zanshin_commit_contents;
use zanshin_ffi::fbs;
use zanshin_ffi::ffi_strings::{zanshin_buffer_free_token, ZanshinBuf};
use zanshin_ffi::repo::{zanshin_repo_close, zanshin_repo_open};
use zanshin_jj::{CommitId, GraphTopology, Repo, DEFAULT_GRAPH_PRIORITIZE, DEFAULT_LOG_REVSET};

static ENV_GUARD: LazyLock<()> = LazyLock::new(|| {
    // SAFETY: set once before any workspace load; pins jj-lib/git off the developer's
    // globals for reproducible timing (mirrors the test suites).
    unsafe {
        env::set_var("JJ_CONFIG", "");
        env::set_var("GIT_CONFIG_GLOBAL", "");
        env::set_var("JJ_USER", "Zanshin");
        env::set_var("JJ_EMAIL", "zanshin@localhost");
        env::set_var("JJ_OP_HOSTNAME", "localhost");
        env::set_var("JJ_OP_USERNAME", "zanshin");
        env::set_var("XDG_CONFIG_HOME", test_helpers::leaked_xdg_config_home());
    }
});

const WARMUP: u32 = 1;
const ITERS: u32 = 5;

fn main() {
    LazyLock::force(&ENV_GUARD);
    bench_store("medium-1k-commits", false);
    bench_store("large-10k-commits", false);
    bench_store("large-10k-commits", true);
}

/// Returns `(min, median)` over `ITERS` timed runs after `WARMUP` untimed runs.
fn measure(mut f: impl FnMut()) -> (Duration, Duration) {
    measure_with(|| (), |()| f(), |()| {})
}

/// [`measure`] with an untimed per-run `setup` and `teardown` around the timed `f` (a fresh
/// handle, so every timed run starts with a cold commit cache, closed outside the timing).
fn measure_with<S>(
    mut setup: impl FnMut() -> S,
    mut f: impl FnMut(&mut S),
    mut teardown: impl FnMut(S),
) -> (Duration, Duration) {
    for _ in 0..WARMUP {
        let mut state = setup();
        f(&mut state);
        teardown(state);
    }
    let mut samples: Vec<Duration> = (0..ITERS)
        .map(|_| {
            let mut state = setup();
            let t = Instant::now();
            f(&mut state);
            let elapsed = t.elapsed();
            teardown(state);
            elapsed
        })
        .collect();
    samples.sort_unstable();
    (samples[0], samples[samples.len() / 2])
}

fn report(store: &str, what: &str, (min, med): (Duration, Duration)) {
    eprintln!("[{store}] {what}: min {min:?} / med {med:?}");
}

fn topology(repo: &mut Repo, anchors: &[String], with_timestamps: bool) -> GraphTopology {
    repo.graph_topology(
        "all()",
        DEFAULT_GRAPH_PRIORITIZE,
        DEFAULT_LOG_REVSET,
        anchors,
        with_timestamps,
    )
    .expect("topology")
}

fn default_anchors() -> Vec<String> {
    vec!["trunk()".to_owned(), "present(@)".to_owned()]
}

/// Opens a raw FFI handle on `root`.
fn open_handle(root: &Path) -> u64 {
    let path = CString::new(root.to_str().expect("UTF-8 path")).expect("no NUL");
    // SAFETY: `path` is a valid NUL-terminated C string alive for the call.
    let bytes = unsafe { read_and_free(zanshin_repo_open(path.as_ptr())) };
    let env = flatbuffers::root::<fbs::Envelope>(&bytes).expect("envelope");
    assert!(env.ok(), "open");
    env.data_as_repo_handle().expect("handle").handle()
}

fn close_handle(handle: u64) {
    // SAFETY: the handle came from `open_handle` and is closed once.
    let bytes = unsafe { read_and_free(zanshin_repo_close(handle)) };
    assert!(
        flatbuffers::root::<fbs::Envelope>(&bytes).expect("envelope").ok(),
        "close"
    );
}

/// # Safety
/// `token` must be a fresh, non-null token from a `zanshin_*` function.
unsafe fn read_and_free(token: *mut ZanshinBuf) -> Vec<u8> {
    let bytes = unsafe {
        let t = &*token;
        std::slice::from_raw_parts(t.ptr.cast_const(), t.len).to_vec()
    };
    unsafe { zanshin_buffer_free_token(token) };
    bytes
}

/// One `zanshin_commit_contents` call through the extern — request encode, the pinned read,
/// the payload encode and the token round trip. Returns the entry count.
fn contents_call(handle: u64, operation_id: &str, ids: &[String]) -> usize {
    let mut b = flatbuffers::FlatBufferBuilder::with_capacity(64 + ids.len() * 160);
    let op = b.create_string(operation_id);
    let offsets: Vec<_> = ids.iter().map(|id| b.create_string(id)).collect();
    let ids_vec = b.create_vector(&offsets);
    let req = fbs::CommitContentsRequest::create(
        &mut b,
        &fbs::CommitContentsRequestArgs {
            kind: fbs::RequestKind::CommitContents,
            operation_id: Some(op),
            commit_ids: Some(ids_vec),
        },
    );
    b.finish(req, None);
    let request = b.finished_data();
    // SAFETY: the handle is live; `request` outlives the call.
    let bytes = unsafe { read_and_free(zanshin_commit_contents(handle, request.as_ptr(), request.len())) };
    let env = flatbuffers::root::<fbs::Envelope>(&bytes).expect("envelope");
    assert!(env.ok(), "{:?}", env.error().and_then(|e| e.context()));
    env.data_as_commit_contents()
        .and_then(|c| c.contents())
        .map_or(0, |c| c.len())
}

/// The content pages the bench times: 60 and 200 consecutive nodes, without a merge (the
/// first merge-free window) and with one (a window around the first merge), when the store
/// has such a window.
fn pages(topology: &GraphTopology) -> Vec<(String, Vec<String>)> {
    let merge_at = |i: usize| topology.nodes[i].meta.parent_count > 1;
    let ids = |start: usize, len: usize| -> Vec<String> {
        topology.nodes[start..start + len]
            .iter()
            .map(|n| n.commit_id.0.clone())
            .collect()
    };
    let mut out = Vec::new();
    for len in [60usize, 200] {
        if topology.nodes.len() < len {
            continue;
        }
        let windows = 0..=topology.nodes.len() - len;
        if let Some(start) = windows.clone().find(|&s| !(s..s + len).any(merge_at)) {
            out.push((format!("{len} ids, no merge"), ids(start, len)));
        }
        if let Some(first_merge) = (0..topology.nodes.len()).find(|&i| merge_at(i)) {
            let start = first_merge.saturating_sub(len / 2).min(topology.nodes.len() - len);
            let merges = (start..start + len).filter(|&i| merge_at(i)).count();
            out.push((format!("{len} ids, {merges} merge(s)"), ids(start, len)));
        }
    }
    out
}

fn bench_pages(store: &str, root: &Path, operation_id: &str, pages: &[(String, Vec<String>)], index: &str) {
    for (label, ids) in pages {
        let timing = measure_with(
            || open_handle(root),
            |handle| {
                hint::black_box(contents_call(*handle, operation_id, ids));
            },
            close_handle,
        );
        report(store, &format!("contents page {label}, {index}"), timing);
    }
}

/// The whole revset's content, each on a fresh handle: topology + contents for every node, and
/// `Repo::walk_graph(all())` driven to the end — the old one-call cost.
fn bench_whole_revset(store: &str, root: &Path, first: &GraphTopology) {
    let anchors = default_anchors();
    let all_ids: Vec<CommitId> = first.nodes.iter().map(|n| n.commit_id.clone()).collect();
    report(
        store,
        "topology + contents for every id (fresh handle)",
        measure_with(
            || Repo::open(root).expect("open"),
            |fresh| {
                let t = topology(fresh, &anchors, false);
                hint::black_box(fresh.commit_contents(&t.operation_id, &all_ids).expect("contents"));
            },
            drop,
        ),
    );
    report(
        store,
        "walk_graph(all()) to the end (fresh handle) — the old one-call cost",
        measure_with(
            || Repo::open(root).expect("open"),
            |fresh| {
                let mut rows = 0usize;
                let flow = fresh
                    .walk_graph("all()", DEFAULT_GRAPH_PRIORITIZE, DEFAULT_LOG_REVSET, |node| {
                        hint::black_box(node);
                        rows += 1;
                        ControlFlow::Continue(())
                    })
                    .expect("walk_graph");
                assert_eq!(flow, ControlFlow::Continue(()));
                assert_eq!(rows, first.nodes.len());
            },
            drop,
        ),
    );
}

fn bench_store(name: &str, packed: bool) {
    let fixture = extract_fixture(name).expect("fixture must extract");
    let root = fixture.path.as_path();
    if packed {
        let git_dir = root.join(".jj").join("repo").join("store").join("git");
        let status = Command::new("git")
            .arg(format!("--git-dir={}", git_dir.display()))
            .args(["-c", "gc.pruneExpire=never", "gc", "--quiet"])
            .status()
            .expect("git gc runs");
        assert!(status.success(), "git gc");
    }
    let store = format!("{name} {}", if packed { "packed" } else { "loose" });

    let mut repo = Repo::open(root).expect("open");
    let anchors = default_anchors();
    let first = topology(&mut repo, &anchors, false);
    let merges = first.nodes.iter().filter(|n| n.meta.parent_count > 1).count();
    eprintln!(
        "[{store}] nodes={} all_count={} merges={merges}",
        first.nodes.len(),
        first.all_count
    );

    report(
        &store,
        "graph_topology (default anchors)",
        measure(|| {
            hint::black_box(topology(&mut repo, &anchors, false));
        }),
    );
    report(
        &store,
        "Repo::snapshot() on the unchanged tree (precondition share)",
        measure(|| {
            hint::black_box(repo.snapshot().expect("snapshot"));
        }),
    );
    report(
        &store,
        "graph_topology (anchors [])",
        measure(|| {
            hint::black_box(topology(&mut repo, &[], false));
        }),
    );
    report(
        &store,
        "graph_topology with_timestamps (repeat call, reused handle)",
        measure(|| {
            hint::black_box(topology(&mut repo, &anchors, true));
        }),
    );
    report(
        &store,
        "graph_topology with_timestamps (FIRST call on a fresh handle)",
        measure_with(
            || Repo::open(root).expect("open"),
            |fresh| {
                hint::black_box(topology(fresh, &anchors, true));
            },
            drop,
        ),
    );

    let op = first.operation_id.0.clone();
    let pages = pages(&first);
    report(
        &store,
        "contents, empty list (load_operation + load_at share)",
        measure_with(
            || open_handle(root),
            |handle| {
                hint::black_box(contents_call(*handle, &op, &[]));
            },
            close_handle,
        ),
    );
    bench_pages(&store, root, &op, &pages, "no changed-path index");

    bench_whole_revset(&store, root, &first);

    build_changed_path_index(root);
    bench_pages(&store, root, &op, &pages, "changed-path index");
}
