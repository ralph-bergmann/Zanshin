// SPDX-License-Identifier: MIT

//! Leftover run D after the story loop 9.25–9.46: what `Repo::get_change` costs per call with a
//! FULL change id since it resolves through the effective `revsets.short-prefixes` id-prefix
//! context (commit 0e180ac) — the context is populated on every call.
//!
//! Stores: `large-10k-commits` as committed (every object LOOSE) and a `git gc`-PACKED copy
//! (packed in the bench's own extracted temp copy, fixture-setup style, as `revset_counts`).
//! One warm handle per store; `Repo::status()` on the same handle is the per-call `with_verb`
//! floor. The source compiles unchanged at the pre-change baseline 16d1be5, so the same file
//! times both revisions.
//!
//! Prints min / median only; asserts nothing about wall-clock. Not run by `cargo make test` /
//! coverage (benches are excluded; see docs/coverage.md):
//!
//! ```sh
//! cargo bench -p zanshin-jj --bench get_change
//! ```

use std::env;
use std::process::Command;
use std::sync::LazyLock;
use std::time::{Duration, Instant};

use test_helpers::extract_fixture;
use zanshin_jj::Repo;

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

const WARMUP: u32 = 2;
const ITERS: u32 = 20;

fn main() {
    LazyLock::force(&ENV_GUARD);
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
    let id = repo.status().expect("status").parent_change_id.expect("@ has a parent");

    let (min, med) = measure(|| {
        std::hint::black_box(repo.status().expect("status"));
    });
    eprintln!("[{store}] Repo::status (with_verb floor): min {min:?} / med {med:?}");
    let (min, med) = measure(|| {
        std::hint::black_box(repo.get_change(&id).expect("get_change"));
    });
    eprintln!("[{store}] Repo::get_change(full id of @-): min {min:?} / med {med:?}");
}
