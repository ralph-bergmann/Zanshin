// SPDX-License-Identifier: MIT

//! Graph-walk **blueprint** + decision-input benchmark (ADR-0002 AC-4 / Story 3.11).
//!
//! This is runnable reference code for the jj-lib Stream-based revset-graph traversal
//! that `zanshin-graph` (lane layout) will build on. It deliberately loads the workspace
//! through `jj_lib` directly (not `zanshin_jj::Repo`) so the whole path — open → resolve
//! head → stream the topo-grouped graph — is visible in one place and self-contained.
//!
//! It is NOT run by `cargo make test` / coverage (benches are excluded; see docs/coverage.md).
//! Run it on demand, optimised (`--large` needs `cargo xtask gen-fixture --size large` first):
//!
//! ```sh
//! cargo bench -p zanshin-jj --bench graph_blueprint            # medium fixture
//! cargo bench -p zanshin-jj --bench graph_blueprint -- --large # also the 10k fixture
//! ```
//!
//! ADR-0002 AC-4 result (already recorded; no longer needed as decision input): full
//! derive ~3 ms @ 10k, first-100 page ~27 µs → no materialized lane cache, lazy stream.
//! *(2026-09-30, Story 4.10: this walk is the raw jj-lib TOPOLOGY stream only — index-only,
//! no commit loads, no per-node metadata. Since Story 4.8 `Repo::walk_graph` loads every
//! emitted commit for its metadata, so those figures time neither `walk_graph` nor
//! `Repo::graph_topology`, which adds the per-node view half (change-id resolution, prefix
//! lengths, immutable containment). The two extra passes below are the topology call's
//! per-call index-only passes: `all_count` and the `ParentCount` refinement. Full-call
//! numbers: `crates/zanshin-ffi/benches/graph_topology.rs`.)*

use std::path::Path;
use std::sync::{Arc, LazyLock};
use std::time::{Duration, Instant};
use std::{env, hint};

use futures::executor::block_on;
use futures::StreamExt as _;
use jj_lib::backend::CommitId;
use jj_lib::default_backend_factories::{default_backend_factories, default_working_copy_factories};
use jj_lib::graph::TopoGroupedGraph;
use jj_lib::repo::{ReadonlyRepo, Repo as JjRepo};
use jj_lib::revset::{ResolvedRevsetExpression, RevsetFilterPredicate};
use jj_lib::workspace::Workspace;
use test_helpers::extract_fixture;

type BenchErr = Box<dyn std::error::Error>;

fn main() {
    pin_env();
    // The medium fixture is committed; the large one needs
    // `cargo xtask gen-fixture --size large` first — pass `--large` to include it.
    bench_graph("medium-1k-commits");
    if env::args().any(|a| a == "--large") {
        bench_graph("large-10k-commits");
    }
}

static ENV_GUARD: LazyLock<()> = LazyLock::new(|| {
    // SAFETY: set once before any workspace load; empty values pin jj-lib/git off
    // the developer's globals for reproducible timing (mirrors the test suites).
    unsafe {
        env::set_var("JJ_CONFIG", "");
        env::set_var("GIT_CONFIG_GLOBAL", "");
        env::set_var("JJ_USER", "Zanshin");
        env::set_var("JJ_EMAIL", "zanshin@localhost");
        env::set_var("JJ_OP_HOSTNAME", "localhost");
        env::set_var("JJ_OP_USERNAME", "zanshin");
    }
});

fn pin_env() {
    LazyLock::force(&ENV_GUARD);
}

/// Returns `(min, median)` over `iters` timed runs after `warmup` untimed runs.
/// `min` is the least-noisy floor; `median` is robust to a single outlier.
fn measure<F: FnMut()>(warmup: u32, iters: u32, mut f: F) -> (Duration, Duration) {
    for _ in 0..warmup {
        f();
    }
    let mut samples: Vec<Duration> = (0..iters)
        .map(|_| {
            let t = Instant::now();
            f();
            t.elapsed()
        })
        .collect();
    samples.sort_unstable();
    (samples[0], samples[samples.len() / 2])
}

/// Load a workspace from `path` and re-resolve to the head operation (ADR-0002).
/// A plain `Workspace::load` with the pinned test settings — NOT `zanshin_jj::Repo::open`'s
/// path, which splits the load into loader → effective config stack → settings → load
/// (Story 9.27); the settings do not affect a graph walk, so the bench stays self-contained
/// and ACL-clean (no `Repo` internals reached).
fn load_head(path: &Path) -> Arc<ReadonlyRepo> {
    let settings = test_helpers::test_settings();
    let workspace = Workspace::load(
        &settings,
        path,
        &default_backend_factories(),
        &default_working_copy_factories(),
    )
    .expect("workspace must load");
    pollster::block_on(workspace.repo_loader().load_at_head()).expect("load_at_head must succeed")
}

/// Walk the whole commit graph in topological order (children-before-parents — the
/// lane-drawable order GG consumes) via jj-lib's Stream-based revset graph API. This is
/// the derive cost a lane cache OR a stream must pay on an `op_heads` change; `limit`
/// models the streamed initial-render-slice (the GG `QuerySession` page).
fn walk_graph(repo: &Arc<ReadonlyRepo>, limit: Option<usize>) -> Result<usize, BenchErr> {
    // `all()` carries no symbols, so it needs no resolver/extensions/prefix-context.
    let expr = ResolvedRevsetExpression::all();
    let repo_dyn: &dyn JjRepo = repo.as_ref();
    let revset = expr.evaluate(repo_dyn)?;
    // identity id-mapper, annotated for HRTB inference (mirrors GG's commit_id_identity).
    let as_id: for<'a> fn(&'a CommitId) -> &'a CommitId = |id| id;
    let mut stream = Box::pin(TopoGroupedGraph::new(revset.stream_graph(), as_id).stream());
    let mut count = 0usize;
    while let Some(item) = block_on(stream.next()) {
        item?; // GraphNode<CommitId> = (CommitId, Vec<GraphEdge<CommitId>>)
        count += 1;
        if limit.is_some_and(|n| count >= n) {
            break;
        }
    }
    Ok(count)
}

/// Story 4.10's `all_count` pass: count `|all()|` by iterating its stream (index-only).
fn count_all(repo: &Arc<ReadonlyRepo>) -> Result<usize, BenchErr> {
    let repo_dyn: &dyn JjRepo = repo.as_ref();
    let revset = ResolvedRevsetExpression::all().evaluate(repo_dyn)?;
    let mut stream = revset.stream();
    let mut count = 0usize;
    while let Some(item) = block_on(stream.next()) {
        item?;
        count += 1;
    }
    Ok(count)
}

/// The ids a resolved expression denotes.
fn ids_of(repo_dyn: &dyn JjRepo, expr: Arc<ResolvedRevsetExpression>) -> Result<Vec<CommitId>, BenchErr> {
    let revset = expr.evaluate(repo_dyn)?;
    let mut stream = revset.stream();
    let mut ids = Vec::new();
    while let Some(item) = block_on(stream.next()) {
        ids.push(item?);
    }
    Ok(ids)
}

/// Story 4.10's `parent_count` passes over `all()`: `ParentCount(2..)` once, then each
/// refinement `k = 3, 4, …` over the previous pass's set until one is empty. Returns the number
/// of merges.
fn parent_count_passes(repo: &Arc<ReadonlyRepo>) -> Result<usize, BenchErr> {
    let repo_dyn: &dyn JjRepo = repo.as_ref();
    let merges = ids_of(
        repo_dyn,
        ResolvedRevsetExpression::all().filtered(RevsetFilterPredicate::ParentCount(2..u32::MAX)),
    )?;
    let count = merges.len();
    let mut candidates = merges;
    let mut k = 3u32;
    while !candidates.is_empty() {
        candidates = ids_of(
            repo_dyn,
            ResolvedRevsetExpression::commits(candidates).filtered(RevsetFilterPredicate::ParentCount(k..u32::MAX)),
        )?;
        k += 1;
    }
    Ok(count)
}

fn bench_graph(name: &str) {
    pin_env();
    let fixture = extract_fixture(name).expect("fixture must extract");
    let repo = load_head(&fixture.path);

    let nodes = walk_graph(&repo, None).expect("walk must succeed");
    let (full_min, full_med) = measure(2, 7, || {
        hint::black_box(walk_graph(&repo, None).expect("walk must succeed"));
    });
    let (page_min, page_med) = measure(3, 21, || {
        hint::black_box(walk_graph(&repo, Some(100)).expect("walk must succeed"));
    });
    let all = count_all(&repo).expect("count must succeed");
    let (count_min, count_med) = measure(2, 7, || {
        hint::black_box(count_all(&repo).expect("count must succeed"));
    });
    let merges = parent_count_passes(&repo).expect("passes must succeed");
    let (pc_min, pc_med) = measure(2, 7, || {
        hint::black_box(parent_count_passes(&repo).expect("passes must succeed"));
    });

    eprintln!(
        "[graph {name}] nodes={nodes} | topology-only walk: min {full_min:?} / med {full_med:?} | first-100: min {page_min:?} / med {page_med:?}"
    );
    eprintln!(
        "[graph {name}] all()={all} count pass: min {count_min:?} / med {count_med:?} | merges={merges} ParentCount passes: min {pc_min:?} / med {pc_med:?}"
    );
}
