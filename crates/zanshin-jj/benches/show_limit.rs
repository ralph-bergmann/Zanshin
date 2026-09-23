// SPDX-License-Identifier: MIT

//! `Repo::show` perf **witness** for `ShowRequest.limit` (Epic 9 follow-up F).
//!
//! `show` builds ONE owned list in which every entry pays a merged-parent tree diff, a
//! per-parent copy-record stream and a `change_from_commit`. The `limit` added by this run is
//! `take(n)` on the commit stream BEFORE that per-entry work, so "the rest is not computed" is a
//! STRUCTURAL property no behavioural test can observe — a skipped entry leaves no trace in the
//! result. This bench is the evidence for it: on `medium-1k-commits` it prints the unbounded
//! `show("all()")` cost next to a handful of small limits, so the cost per entry and the
//! early-stop are both visible.
//!
//! It asserts NOTHING about wall-clock. Perf-budget enforcement is deferred to the release phase
//! (project-context § "Performance assertions"), and a timing assertion here would be exactly
//! the flaky test the project bans `#[ignore]` as a workaround for. It DOES assert the entry
//! COUNTS, which cannot be flaky: without them a `take` that stopped bounding the walk would
//! print faster numbers and read as a success — the opposite of a witness.
//!
//! It is NOT run by `cargo make test` / coverage (benches are excluded; see docs/coverage.md),
//! but `cargo clippy --workspace --all-targets` DOES compile it. Run it on demand, optimised:
//!
//! ```sh
//! cargo bench -p zanshin-jj --bench show_limit
//! ```

use std::env;
use std::sync::LazyLock;
use std::time::{Duration, Instant};

use test_helpers::extract_fixture;
use zanshin_jj::Repo;

/// The fixture is committed and holds ~1000 commits; the limits bracket a GUI's first page.
const FIXTURE: &str = "medium-1k-commits";
const LIMITS: [usize; 3] = [1, 10, 100];

fn main() {
    pin_env();
    let fixture = extract_fixture(FIXTURE).expect("fixture must extract");
    let repo = Repo::open(&fixture.path).expect("fixture must open");

    // This run doubles as the warmup, so the expensive unbounded case is not paid one extra
    // time purely to print a count.
    let total = repo.show(Some("all()"), None).expect("show must succeed").len();
    let (full_min, full_med) = measure(0, 3, || {
        let entries = repo.show(Some("all()"), None).expect("show must succeed");
        assert_eq!(entries.len(), total, "the unbounded entry count must be stable");
        std::hint::black_box(entries);
    });
    eprintln!("[show {FIXTURE}] entries={total} | unbounded: min {full_min:?} / med {full_med:?}");

    for limit in LIMITS {
        let (min, med) = measure(2, 7, || {
            let entries = repo.show(Some("all()"), Some(limit)).expect("show must succeed");
            // NOT a timing assertion — those are the flaky kind this file exists to avoid.
            // A `take` that silently stopped bounding the walk would print FASTER numbers and
            // read as a SUCCESS, so the witness has to pin the shape of the answer as well as
            // print its cost.
            assert_eq!(
                entries.len(),
                limit.min(total),
                "limit={limit} must bound the entry count"
            );
            std::hint::black_box(entries);
        });
        eprintln!("[show {FIXTURE}] limit={limit}: min {min:?} / med {med:?}");
    }
}

static ENV_GUARD: LazyLock<()> = LazyLock::new(|| {
    // SAFETY: set once before any workspace load; empty values pin jj-lib/git off the
    // developer's globals for reproducible timing (mirrors `graph_blueprint.rs`).
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
