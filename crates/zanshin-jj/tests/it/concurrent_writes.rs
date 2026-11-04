// SPDX-License-Identifier: MIT

//! Same-repo concurrency (FR-MCP-9): two independent `Repo` handles, each on its own
//! `std::thread`, mutate the same on-disk repo with interleaved `describe` and
//! `new_change` calls. jj-lib's own op-heads + working-copy file locking is the ONLY
//! synchronization point (AD-2) — zanshin-jj adds no coordination lock of its own; this
//! test proves that model holds for the P0 mutations rather than adding one.
//!
//! Concurrent, uncoordinated writers can legitimately produce divergent op heads that
//! jj-lib reconciles into a "reconcile divergent operations" merge op on the next read
//! that observes them — that is normal jj-lib behavior, not an error, so assertions
//! below never depend on the total op count (which varies with how much divergence the
//! scheduler happens to produce) — only on each thread's own labeled operations having
//! landed.
//!
//! The two writers live in two WORKSPACES of the one repo. Since Story 9.26 every verb snapshots
//! its working copy first, exactly like the CLI — and two uncoordinated writers sharing ONE
//! working copy can then hit the CLI's own refusals (a stale working copy, a sibling operation,
//! a concurrent checkout) purely by timing, which two concurrent `jj` processes in one workspace
//! can hit too. Two workspaces keep the op-heads model under test deterministic.

use std::path::Path;
use std::sync::{Arc, Barrier};
use std::thread;

use jj_lib::default_backend_factories::{default_backend_factories, default_working_copy_factories};
use jj_lib::repo::Repo as _;
use test_helpers::extract_fixture;
use zanshin_jj::{ChangeId, Repo};

/// Discovers Commit 1's and Commit 3's change ids (see `tests/it/mutate.rs` for the
/// `tiny-3-commits` fixture's shape: `@` and a separate `Commit 1 -> 2 -> 3` chain).
fn oracle_targets(workspace_root: &Path) -> (String, String) {
    let settings = test_helpers::test_settings();
    let workspace = test_helpers::load_workspace(
        &settings,
        workspace_root,
        &default_backend_factories(),
        &default_working_copy_factories(),
    )
    .expect("oracle workspace load");
    let repo = pollster::block_on(workspace.load_at_head()).expect("oracle load_at_head");
    let store = repo.store();

    let mut commit1 = None;
    let mut commit3 = None;
    for head in repo.view().heads() {
        let mut cur = store.get_commit(head).unwrap();
        loop {
            match cur.description() {
                "Commit 1" => commit1 = Some(cur.change_id().reverse_hex()),
                "Commit 3" => commit3 = Some(cur.change_id().reverse_hex()),
                _ => {}
            }
            let Some(parent_id) = cur.parent_ids().first() else {
                break;
            };
            if parent_id == store.root_commit_id() {
                break;
            }
            cur = store.get_commit(parent_id).unwrap();
        }
    }
    (
        commit1.expect("fixture has Commit 1"),
        commit3.expect("fixture has Commit 3"),
    )
}

const ITERATIONS: usize = 8;

#[test]
fn concurrent_describe_and_new_change_from_two_repo_handles() {
    test_helpers::pin_test_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let (second, _second_wc) = test_helpers::add_workspace(&fx.path, "second");
    let (commit1_change_id, commit3_change_id) = oracle_targets(&fx.path);
    let barrier = Arc::new(Barrier::new(2));

    let describer = {
        let path = fx.path.clone();
        let change_id = commit1_change_id.clone();
        let barrier = Arc::clone(&barrier);
        thread::spawn(move || {
            let mut repo = Repo::open(&path).unwrap();
            barrier.wait();
            for i in 0..ITERATIONS {
                repo.describe(ChangeId(change_id.clone()), &format!("describe iteration {i}"))
                    .expect("describe must not observe a spurious concurrency error");
            }
        })
    };

    let creator = {
        let path = second.path.clone();
        let change_id = commit3_change_id;
        let barrier = Arc::clone(&barrier);
        thread::spawn(move || {
            let mut repo = Repo::open(&path).unwrap();
            barrier.wait();
            for _ in 0..ITERATIONS {
                repo.new_change(&[ChangeId(change_id.clone())], &[], &[])
                    .expect("new_change must not observe a spurious concurrency error");
            }
        })
    };

    describer.join().expect("describer thread must not panic");
    creator.join().expect("creator thread must not panic");

    // A fresh third handle, opened only after both threads finished: every operation
    // from both threads must be visible via the shared op-heads store.
    let mut repo = Repo::open(&fx.path).unwrap();
    let ops = repo.op_log(None).unwrap();

    let describe_ops = ops
        .iter()
        .filter(|o| o.description.starts_with("describe commit "))
        .count();
    let new_change_ops = ops.iter().filter(|o| o.description == "new empty commit").count();
    assert_eq!(describe_ops, ITERATIONS, "every describe call must land exactly once");
    assert_eq!(
        new_change_ops, ITERATIONS,
        "every new_change call must land exactly once"
    );

    // Thread A's calls all targeted the same change id sequentially from one `Repo`
    // handle, so the last one written wins; thread B never touched Commit 1.
    let change = repo.get_change(&ChangeId(commit1_change_id)).unwrap();
    assert_eq!(change.description, format!("describe iteration {}", ITERATIONS - 1));
}
