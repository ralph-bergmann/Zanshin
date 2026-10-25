// SPDX-License-Identifier: MIT

//! Story 9.25 I7: what `Repo::revset_counts` costs per expression at cap 10 000, per store.
//!
//! Stores: `medium-1k-commits` and `large-10k-commits` as committed (every object LOOSE), and a
//! `git gc`-PACKED copy of `large-10k-commits` (packed in the bench's own extracted temp copy,
//! fixture-setup style — the only shell-out, as `zanshin-ffi/benches/graph_topology.rs`). Each
//! large store is timed again after `build_changed_path_index`, which is what `files()` reads.
//! The expressions are the graph search's expensive kinds: `author()` / `description()` /
//! `mine()` load every commit, `files()` diffs each one without the index, `all()` is the
//! index-only floor.
//!
//! Prints the count and min / median only; asserts nothing about wall-clock. Not run by
//! `cargo make test` / coverage (benches are excluded; see docs/coverage.md):
//!
//! ```sh
//! cargo bench -p zanshin-jj --bench revset_counts
//! ```

use std::env;
use std::path::Path;
use std::process::Command;
use std::sync::LazyLock;
use std::time::{Duration, Instant};

use test_helpers::{build_changed_path_index, extract_fixture};
use zanshin_jj::{OperationId, Repo, DEFAULT_GRAPH_PRIORITIZE, DEFAULT_LOG_REVSET};

static ENV_GUARD: LazyLock<()> = LazyLock::new(|| {
    // SAFETY: set once before any workspace load; pins jj-lib/git off the developer's globals
    // for reproducible timing (mirrors the test suites).
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
const CAP: u64 = 10_000;
const EXPRESSIONS: [&str; 5] = [
    r#"author(substring-i:"fixture")"#,
    r#"description(substring-i:"branch")"#,
    "mine()",
    r#"files(glob:"commit-1*.txt")"#,
    "all()",
];

fn main() {
    LazyLock::force(&ENV_GUARD);
    bench_store("medium-1k-commits", false);
    bench_store("large-10k-commits", false);
    bench_store("large-10k-commits", true);
}

/// Returns `(min, median)` over `ITERS` timed runs after `WARMUP` untimed runs.
fn measure(mut f: impl FnMut()) -> (Duration, Duration) {
    for _ in 0..WARMUP {
        f();
    }
    let mut samples: Vec<Duration> = (0..ITERS)
        .map(|_| {
            let t = Instant::now();
            f();
            t.elapsed()
        })
        .collect();
    samples.sort_unstable();
    (samples[0], samples[samples.len() / 2])
}

/// Times each expression's count on a fresh handle (a cold commit cache, as a search after a
/// reload has). The bare `Repo::open` row is that handle's share of every row.
fn bench_expressions(store: &str, root: &Path, op: &OperationId, index: &str) {
    let (min, med) = measure(|| {
        std::hint::black_box(Repo::open(root).expect("open"));
    });
    eprintln!("[{store}, {index}] Repo::open alone: min {min:?} / med {med:?}");
    for expr in EXPRESSIONS {
        let expressions = [expr.to_owned()];
        let repo = Repo::open(root).expect("open");
        let n = repo.revset_counts(op, &expressions, CAP).expect("counts").counts[0]
            .as_ref()
            .map(|c| c.n)
            .expect("count");
        let (min, med) = measure(|| {
            let fresh = Repo::open(root).expect("open");
            std::hint::black_box(fresh.revset_counts(op, &expressions, CAP).expect("counts"));
        });
        eprintln!("[{store}, {index}] {expr} = {n}: min {min:?} / med {med:?}");
    }
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
    let op = Repo::open(root)
        .expect("open")
        .graph_topology("@", DEFAULT_GRAPH_PRIORITIZE, DEFAULT_LOG_REVSET, &[], false)
        .expect("topology")
        .operation_id;

    bench_expressions(&store, root, &op, "no changed-path index");
    if name.starts_with("large") {
        build_changed_path_index(root);
        bench_expressions(&store, root, &op, "changed-path index");
    }
}
