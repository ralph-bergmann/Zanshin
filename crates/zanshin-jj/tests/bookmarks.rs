// SPDX-License-Identifier: MIT

use std::env;
use std::fs;
use std::path::Path;
use std::sync::LazyLock;

use jj_lib::default_backend_factories::{default_backend_factories, default_working_copy_factories};
use jj_lib::op_store::{RefTarget, RemoteRef, RemoteRefState};
use jj_lib::ref_name::RemoteRefSymbol;
use jj_lib::repo::Repo as _;
use jj_lib::settings::UserSettings;
use jj_lib::workspace::Workspace;
use tempfile::TempDir;
use test_helpers::{extract_fixture, FixtureHandle};
use zanshin_jj::{BookmarkError, BookmarkKind, Repo};

static ENV_GUARD: LazyLock<()> = LazyLock::new(|| unsafe {
    env::set_var("JJ_CONFIG", "");
    env::set_var("GIT_CONFIG_GLOBAL", "");
    env::set_var("JJ_USER", "Zanshin");
    env::set_var("JJ_EMAIL", "zanshin@localhost");
    env::set_var("JJ_OP_HOSTNAME", "localhost");
    env::set_var("JJ_OP_USERNAME", "zanshin");
});

fn pin_env() {
    LazyLock::force(&ENV_GUARD);
}

/// Open the fixture as a raw jj-lib `Workspace` for oracle reads.
fn oracle_workspace(root: &Path) -> (Workspace, UserSettings) {
    let settings = test_helpers::test_settings();
    let workspace = Workspace::load(
        &settings,
        root,
        &default_backend_factories(),
        &default_working_copy_factories(),
    )
    .expect("oracle workspace load");
    (workspace, settings)
}

// ── AC-8 #15: empty on tiny ────────────────────────────────────────────────────

#[test]
fn bookmarks_on_tiny_returns_empty() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
    let bms = repo.list_bookmarks().unwrap();
    assert!(bms.is_empty(), "tiny fixture has no bookmarks; got {bms:?}");
}

// ── AC-3 #8, oracle equality: 29 local bookmarks match jj-lib view ───────────

#[test]
fn bookmarks_on_medium_equals_local_oracle() {
    pin_env();
    let fx = extract_fixture("medium-1k-commits").unwrap();
    let mut repo = Repo::open(&fx.path).unwrap();
    let bms = repo.list_bookmarks().unwrap();

    // All medium entries are Local (fixture has no remote bookmarks).
    assert!(
        bms.iter().all(|b| b.kind == BookmarkKind::Local),
        "medium fixture has no remote bookmarks"
    );

    // Build the oracle: walk view().local_bookmarks(), resolve CommitId → ChangeId.
    let (oracle_ws, _) = oracle_workspace(&fx.path);
    let readonly = pollster::block_on(oracle_ws.repo_loader().load_at_head()).unwrap();
    let view = readonly.view();
    let store = readonly.store();
    let mut oracle: Vec<(String, String)> = view
        .local_bookmarks()
        .filter_map(|(name, target)| {
            let cid = target.added_ids().next()?;
            let commit = store.get_commit(cid).ok()?;
            Some((name.as_str().to_owned(), commit.change_id().reverse_hex()))
        })
        .collect();
    oracle.sort_by(|a, b| a.0.cmp(&b.0));

    let got: Vec<(String, String)> = bms.iter().map(|b| (b.name.clone(), b.target.0.clone())).collect();

    assert_eq!(got.len(), 29, "medium fixture has exactly 29 local bookmarks");
    assert_eq!(got, oracle, "bookmarks must equal oracle by (name, change_id)");
}

// ── Shared setup for in-test remote bookmark construction ─────────────────────

/// Extracts the medium fixture, adds in one transaction:
/// - "feature" local bookmark + "feature/origin" tracked-remote (AC-3 #7)
/// - "ghost/origin" absent-tracked ref (AC-8 #16, `is_present` filter)
/// - "untracked/origin" present-New ref (AC-8 #16, `is_tracked` filter)
///
/// Returns `(FixtureHandle, expected_change_id)` where `expected_change_id` is
/// the reverse-hex change id that both the Local and Remote "feature" entries
/// should target.
fn setup_with_remote_bookmarks() -> (FixtureHandle, String) {
    let fx = extract_fixture("medium-1k-commits").unwrap();
    let (oracle_ws, _) = oracle_workspace(&fx.path);
    let base = pollster::block_on(oracle_ws.repo_loader().load_at_head()).unwrap();

    // Grab a real CommitId from the fixture's existing local bookmarks.
    let commit_id = base
        .view()
        .local_bookmarks()
        .find_map(|(_, target)| target.added_ids().next().cloned())
        .expect("medium fixture has at least one local bookmark");

    // Resolve CommitId → ChangeId (reverse-hex) before the transaction.
    let change_id = base.store().get_commit(&commit_id).unwrap().change_id().reverse_hex();

    let mut tx = base.start_transaction();
    let mr = tx.repo_mut();

    // Local + tracked-remote pair (covers AC-3 #7).
    mr.set_local_bookmark_target("feature".as_ref(), RefTarget::normal(commit_id.clone()));
    mr.set_remote_bookmark(
        RemoteRefSymbol {
            name: "feature".as_ref(),
            remote: "origin".as_ref(),
        },
        RemoteRef {
            target: RefTarget::normal(commit_id.clone()),
            state: RemoteRefState::Tracked,
        },
    );

    // Absent-tracked: is_present() == false → must be skipped (AC-8 #16).
    mr.set_remote_bookmark(
        RemoteRefSymbol {
            name: "ghost".as_ref(),
            remote: "origin".as_ref(),
        },
        RemoteRef {
            target: RefTarget::absent(),
            state: RemoteRefState::Tracked,
        },
    );

    // Present-untracked (New state): is_tracked() == false → must be skipped (AC-8 #16).
    mr.set_remote_bookmark(
        RemoteRefSymbol {
            name: "untracked".as_ref(),
            remote: "origin".as_ref(),
        },
        RemoteRef {
            target: RefTarget::normal(commit_id.clone()),
            state: RemoteRefState::New,
        },
    );

    pollster::block_on(tx.commit("test: add local + remote-tracking bookmarks")).unwrap();

    (fx, change_id)
}

// ── AC-3 #7: local + tracked-remote pair yields exactly two entries ───────────

#[test]
fn bookmarks_local_and_remote_tracking_yields_two_entries() {
    pin_env();
    let (fx, expected_change) = setup_with_remote_bookmarks();

    // Re-resolves to head (ADR-0002): the Repo opened after the transaction sees
    // the new operation.
    let mut repo = Repo::open(&fx.path).unwrap();
    let bms = repo.list_bookmarks().unwrap();

    let feature_bms: Vec<_> = bms.iter().filter(|b| b.name == "feature").collect();
    assert_eq!(
        feature_bms.len(),
        2,
        "'feature' must have exactly 2 entries (Local + Remote); got {feature_bms:?}"
    );

    let local = feature_bms
        .iter()
        .find(|b| b.kind == BookmarkKind::Local)
        .expect("'feature' must have a Local entry");
    let remote = feature_bms
        .iter()
        .find(|b| matches!(&b.kind, BookmarkKind::Remote { .. }))
        .expect("'feature' must have a Remote entry");

    assert_eq!(local.target.0, expected_change, "Local target change_id must match");
    assert_eq!(remote.target.0, expected_change, "Remote target change_id must match");
    assert!(
        matches!(&remote.kind, BookmarkKind::Remote { remote_name } if remote_name == "origin"),
        "remote_name must be 'origin', got {:?}",
        remote.kind
    );
}

// ── AC-8 #16: absent-tracked and present-untracked refs are skipped ───────────

#[test]
fn bookmarks_skips_absent_and_untracked_remotes() {
    pin_env();
    let (fx, _) = setup_with_remote_bookmarks();

    let mut repo = Repo::open(&fx.path).unwrap();
    let bms = repo.list_bookmarks().unwrap();

    assert!(
        !bms.iter().any(|b| b.name == "ghost"),
        "'ghost' (absent-tracked) must be skipped; full list: {bms:?}"
    );
    assert!(
        !bms.iter().any(|b| b.name == "untracked"),
        "'untracked' (present-New) must be skipped; full list: {bms:?}"
    );
}

// ── AC-4: sorted by (name, kind) — Local before Remote ───────────────────────

#[test]
fn bookmarks_are_sorted_by_name_then_kind() {
    pin_env();
    let (fx, _) = setup_with_remote_bookmarks();

    let mut repo = Repo::open(&fx.path).unwrap();
    let bms = repo.list_bookmarks().unwrap();

    // Assert the full list is sorted by (name, kind).
    for pair in bms.windows(2) {
        let a = &pair[0];
        let b = &pair[1];
        let ord = a.name.cmp(&b.name).then_with(|| a.kind.cmp(&b.kind));
        assert!(
            ord.is_le(),
            "bookmarks out of order: {:?} should not come after {:?}",
            (&a.name, &a.kind),
            (&b.name, &b.kind)
        );
    }

    // "feature/Local" must be immediately adjacent before "feature/Remote{origin}".
    let feature_idxs: Vec<usize> = bms
        .iter()
        .enumerate()
        .filter(|(_, b)| b.name == "feature")
        .map(|(i, _)| i)
        .collect();
    assert_eq!(feature_idxs.len(), 2, "'feature' must appear exactly twice");
    assert_eq!(
        feature_idxs[1],
        feature_idxs[0] + 1,
        "'feature' Local and Remote entries must be adjacent"
    );
    assert_eq!(
        bms[feature_idxs[0]].kind,
        BookmarkKind::Local,
        "Local must precede Remote for the same name"
    );
}

// ── AC-7 / Backend error on corrupt repo ─────────────────────────────────────

#[test]
fn bookmarks_on_corrupt_repo_returns_backend_error() {
    pin_env();
    let tmp = TempDir::new().unwrap();
    Repo::init(tmp.path(), None).unwrap();

    let mut repo = Repo::open(tmp.path()).unwrap();

    // Corrupt AFTER open: list_bookmarks() re-resolves to head per call (ADR-0002),
    // so removing op_heads makes load_at_head() fail → BookmarkError::Backend.
    let op_heads = tmp.path().join(".jj").join("repo").join("op_heads");
    fs::remove_dir_all(&op_heads).unwrap();

    let result = repo.list_bookmarks();
    assert!(
        matches!(result, Err(BookmarkError::Precondition(zanshin_jj::PreconditionError::Backend(_)))),
        "the pre-verb snapshot fails first (Story 9.26, as the CLI would): corrupt repo must yield Backend error, got: {result:?}"
    );
}

// ── AC-5 #11: conflicted/divergent target → first added_ids() change id ───────

#[test]
fn bookmarks_conflicted_target_uses_first_added_change_id() {
    pin_env();
    let fx = extract_fixture("medium-1k-commits").unwrap();
    let (oracle_ws, _) = oracle_workspace(&fx.path);
    let base = pollster::block_on(oracle_ws.repo_loader().load_at_head()).unwrap();

    // Collect three distinct commit ids from the fixture's local bookmarks to
    // build a divergent (multi-add) RefTarget. `added_ids()` preserves add order,
    // so the FIRST add must be the change id `list_bookmarks` reports (AC-5 #11).
    let mut commit_ids = Vec::new();
    for (_, target) in base.view().local_bookmarks() {
        if let Some(cid) = target.added_ids().next() {
            if !commit_ids.contains(cid) {
                commit_ids.push(cid.clone());
            }
            if commit_ids.len() >= 3 {
                break;
            }
        }
    }
    assert!(
        commit_ids.len() >= 3,
        "medium fixture must have >=3 distinct bookmark targets; got {}",
        commit_ids.len()
    );
    let first_add = commit_ids[0].clone();
    let second_add = commit_ids[1].clone();
    let removed = commit_ids[2].clone();

    // Expected: the divergent bookmark resolves to the FIRST added id's change id.
    let expected_change = base.store().get_commit(&first_add).unwrap().change_id().reverse_hex();

    let mut tx = base.start_transaction();
    let mr = tx.repo_mut();
    // Divergent local bookmark: two adds + one remove (a merge has adds = removes + 1).
    mr.set_local_bookmark_target(
        "divergent".as_ref(),
        RefTarget::from_legacy_form([removed], [first_add, second_add]),
    );
    pollster::block_on(tx.commit("test: add divergent local bookmark")).unwrap();

    let mut repo = Repo::open(&fx.path).unwrap();
    let bms = repo.list_bookmarks().unwrap();

    let divergent: Vec<_> = bms.iter().filter(|b| b.name == "divergent").collect();
    assert_eq!(
        divergent.len(),
        1,
        "a divergent bookmark must yield exactly one entry; got {divergent:?}"
    );
    assert_eq!(divergent[0].kind, BookmarkKind::Local, "divergent entry must be Local");
    assert_eq!(
        divergent[0].target.0, expected_change,
        "divergent bookmark must resolve to the FIRST added_ids() change id"
    );
}

// ── AC-4 #10: non-ASCII name preserved verbatim + codepoint-order sort ─────────

#[test]
fn bookmarks_preserve_non_ascii_name_and_sort_by_codepoint() {
    pin_env();
    let fx = extract_fixture("medium-1k-commits").unwrap();
    let (oracle_ws, _) = oracle_workspace(&fx.path);
    let base = pollster::block_on(oracle_ws.repo_loader().load_at_head()).unwrap();
    let commit_id = base
        .view()
        .local_bookmarks()
        .find_map(|(_, target)| target.added_ids().next().cloned())
        .expect("medium fixture has at least one local bookmark");

    let mut tx = base.start_transaction();
    let mr = tx.repo_mut();
    // Shared "zzz-" prefix → both sort after the fixture's lowercase ASCII names
    // and adjacent to each other. At the 5th char 'a' (U+0061) < 'é' (U+00E9), so
    // codepoint order is "zzz-ascii" < "zzz-éclair".
    mr.set_local_bookmark_target("zzz-ascii".as_ref(), RefTarget::normal(commit_id.clone()));
    mr.set_local_bookmark_target("zzz-éclair".as_ref(), RefTarget::normal(commit_id.clone()));
    pollster::block_on(tx.commit("test: non-ASCII bookmark name")).unwrap();

    let mut repo = Repo::open(&fx.path).unwrap();
    let bms = repo.list_bookmarks().unwrap();

    // Verbatim UTF-8 preservation of the non-ASCII name.
    assert!(
        bms.iter().any(|b| b.name == "zzz-éclair"),
        "non-ASCII bookmark name must be preserved verbatim"
    );

    // Codepoint-order sort: "zzz-ascii" must precede "zzz-éclair".
    let i_ascii = bms
        .iter()
        .position(|b| b.name == "zzz-ascii")
        .expect("zzz-ascii present");
    let i_nonascii = bms
        .iter()
        .position(|b| b.name == "zzz-éclair")
        .expect("zzz-éclair present");
    assert!(
        i_ascii < i_nonascii,
        "codepoint order: 'zzz-ascii' (#{i_ascii}) must precede 'zzz-éclair' (#{i_nonascii})"
    );
}
