// SPDX-License-Identifier: MIT

//! Story 10.10's measurement of the drop-preview hover path (deferred-work "Surfaced in Story
//! 9.31", I1/I2): what one `Repo::drop_actions` query costs when the dragged change has a deep
//! stack of descendants — the rebase rows' no-op check applies jj-lib's whole move on a dropped
//! transaction — and how many `refs/jj/keep/*` refs one query leaves behind.
//!
//! The stack is built in the bench's own copy of the `tiny-3-commits` fixture: `DEPTH` changes on `@`, each
//! adding its own file and appending to one shared file, so a move merges every descendant's
//! tree. The query is the drop menu's: one target `T` (the stack base's parent) at `-o`, `-A` and
//! `-B`.
//!
//! Prints min / median and the keep-ref growth only; asserts nothing about wall-clock. Not run by
//! `cargo make test` / coverage (benches are excluded; see docs/coverage.md):
//!
//! ```sh
//! cargo bench -p zanshin-jj --bench drop_actions_depth
//! ```

use std::env;
use std::fmt::Write as _;
use std::fs;
use std::path::Path;
use std::process::Command;
use std::sync::LazyLock;
use std::time::{Duration, Instant};

use test_helpers::extract_fixture;
use zanshin_jj::{ChangeId, DropLocation, DropSource, Repo};

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

const DEPTH: usize = 200;
const ITERS: u32 = 10;

fn main() {
    LazyLock::force(&ENV_GUARD);
    let fixture = extract_fixture("tiny-3-commits").expect("fixture must extract");
    let root = fixture.path.as_path();
    let mut repo = Repo::open(root).expect("open");
    let target = repo.status().expect("status").parent_change_id.expect("@ has a parent");

    let mut ids = Vec::with_capacity(DEPTH);
    let mut shared = String::new();
    for i in 0..DEPTH {
        fs::create_dir_all(root.join("deep")).expect("mkdir");
        fs::write(root.join(format!("deep/f{i}.txt")), format!("{i}\n")).expect("write");
        writeln!(shared, "line {i}").expect("write to a String");
        fs::write(root.join("deep/shared.txt"), &shared).expect("write");
        let at = repo.status().expect("snapshot").working_copy_change_id.expect("@");
        repo.new_change(std::slice::from_ref(&at), &[], &[]).expect("new");
        ids.push(at);
    }

    for depth in [1, 10, 50, 100, DEPTH - 1] {
        let source = DropSource::Change(ids[DEPTH - depth].clone());
        let locations = locations(&target);
        let before = keep_refs(root);
        let objects_before = loose_objects(root);
        let (min, med) = measure(|| {
            std::hint::black_box(repo.drop_actions(&source, &locations).expect("drop_actions"));
        });
        let grown = keep_refs(root) - before;
        let objects = loose_objects(root) - objects_before;
        eprintln!(
            "[{depth} descendants] drop_actions (-o/-A/-B): min {min:?} / med {med:?}; \
             +{grown} refs/jj/keep, +{objects} loose git objects over {} queries",
            ITERS + 1
        );
    }
    let (min, med) = measure(|| {
        std::hint::black_box(repo.status().expect("status"));
    });
    eprintln!("Repo::status (with_verb floor): min {min:?} / med {med:?}");
}

fn locations(target: &ChangeId) -> Vec<DropLocation> {
    let one = vec![target.clone()];
    vec![
        DropLocation {
            onto: one.clone(),
            insert_after: vec![],
            insert_before: vec![],
        },
        DropLocation {
            onto: vec![],
            insert_after: one.clone(),
            insert_before: vec![],
        },
        DropLocation {
            onto: vec![],
            insert_after: vec![],
            insert_before: one,
        },
    ]
}

/// The store's `refs/jj/keep/*` count.
fn keep_refs(root: &Path) -> usize {
    let git_dir = root.join(".jj").join("repo").join("store").join("git");
    let out = Command::new("git")
        .arg(format!("--git-dir={}", git_dir.display()))
        .args(["for-each-ref", "refs/jj/keep/"])
        .output()
        .expect("git for-each-ref runs");
    String::from_utf8_lossy(&out.stdout).lines().count()
}

/// The store's loose git object count (`git count-objects`'s first number): what the rows' plans write.
fn loose_objects(root: &Path) -> usize {
    let git_dir = root.join(".jj").join("repo").join("store").join("git");
    let out = Command::new("git")
        .arg(format!("--git-dir={}", git_dir.display()))
        .arg("count-objects")
        .output()
        .expect("git count-objects runs");
    String::from_utf8_lossy(&out.stdout)
        .split_whitespace()
        .next()
        .and_then(|n| n.parse().ok())
        .expect("a count")
}

/// Returns `(min, median)` over `ITERS` timed runs after one untimed run.
fn measure(mut f: impl FnMut()) -> (Duration, Duration) {
    f();
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
