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
use test_helpers::{
    add_commit_off_root, add_commit_with_files, describe_commit, extract_fixture, set_local_bookmark,
    set_remote_bookmark, FixtureHandle,
};
use zanshin_jj::{convert_colocated, Bookmark, BookmarkError, BookmarkKind, RefDistance, Repo};

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

    // All medium entries are Local (fixture has no remote bookmarks), hence vacuously synced.
    assert!(
        bms.iter()
            .all(|b| b.kind == BookmarkKind::Local && b.synced && !b.conflicted),
        "medium fixture has no remote bookmarks: {bms:?}"
    );

    // Build the oracle: walk view().local_bookmarks(), resolve CommitId → ChangeId.
    let (oracle_ws, _) = oracle_workspace(&fx.path);
    let readonly = pollster::block_on(oracle_ws.repo_loader().load_at_head()).unwrap();
    let view = readonly.view();
    let store = readonly.store();
    let mut oracle: Vec<(String, String)> = view
        .local_bookmarks()
        .filter_map(|(name, target)| {
            let cid = target.present_adds().next()?;
            let commit = store.get_commit(cid).ok()?;
            Some((name.as_str().to_owned(), commit.change_id().reverse_hex()))
        })
        .collect();
    oracle.sort_by(|a, b| a.0.cmp(&b.0));

    let got: Vec<(String, String)> = bms
        .iter()
        .map(|b| (b.name.clone(), b.target.clone().expect("present local target").0))
        .collect();

    assert_eq!(got.len(), 29, "medium fixture has exactly 29 local bookmarks");
    assert_eq!(got, oracle, "bookmarks must equal oracle by (name, change_id)");
}

// ── Shared setup for in-test remote bookmark construction ─────────────────────

/// Extracts the medium fixture, adds in one transaction:
/// - "feature" local bookmark + "feature/origin" tracked-remote (AC-3 #7)
/// - "ghost/origin" absent-tracked ref without a local bookmark (jj-lib never stores it)
/// - "untracked/origin" present-New ref (an untracked remote row, Story 9.29)
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
        .find_map(|(_, target)| target.present_adds().next().cloned())
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

    // Absent-tracked with no local bookmark: `View::set_remote_bookmark` drops it.
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

    // Present-untracked (New state): listed as an untracked remote row (Story 9.29).
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

    assert_eq!(
        local.target.as_ref().unwrap().0,
        expected_change,
        "Local target change_id must match"
    );
    assert_eq!(
        remote.target.as_ref().unwrap().0,
        expected_change,
        "Remote target change_id must match"
    );
    assert!(
        matches!(&remote.kind, BookmarkKind::Remote { remote_name, .. } if remote_name == "origin"),
        "remote_name must be 'origin', got {:?}",
        remote.kind
    );
}

// ── Story 9.29: the untracked remote is a row; an unstorable ghost is not ─────

#[test]
fn bookmarks_list_untracked_remotes_and_never_an_unstored_ghost() {
    pin_env();
    let (fx, expected_change) = setup_with_remote_bookmarks();

    let mut repo = Repo::open(&fx.path).unwrap();
    let bms = repo.list_bookmarks().unwrap();

    assert!(
        !bms.iter().any(|b| b.name == "ghost"),
        "'ghost' (absent-tracked, no local) is never stored by jj-lib; full list: {bms:?}"
    );
    let untracked: Vec<_> = bms.iter().filter(|b| b.name == "untracked").collect();
    assert_eq!(
        untracked,
        vec![&Bookmark {
            name: "untracked".to_owned(),
            target: Some(zanshin_jj::ChangeId(expected_change)),
            conflicted: false,
            synced: false,
            kind: remote("origin", false, None, None),
        }],
        "an untracked remote is one Remote row and no Local row"
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
        let ord = a.name.cmp(&b.name).then_with(|| remote_of(a).cmp(&remote_of(b)));
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
    Repo::init(&zanshin_jj::InitOptions {
        path: std::path::PathBuf::from(tmp.path()),
        ..Default::default()
    })
    .result
    .unwrap();

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
        if let Some(cid) = target.present_adds().next() {
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
    assert!(divergent[0].conflicted, "a multi-add target is conflicted");
    assert!(divergent[0].synced, "no tracked remote: vacuously synced");
    assert_eq!(
        divergent[0].target.as_ref().unwrap().0,
        expected_change,
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
        .find_map(|(_, target)| target.present_adds().next().cloned())
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

// ── Story 9.29: the `--all-remotes` row set and its facts (I/O matrix) ─────────

/// A remote row's kind.
fn remote(remote_name: &str, tracked: bool, ahead: Option<RefDistance>, behind: Option<RefDistance>) -> BookmarkKind {
    BookmarkKind::Remote {
        remote_name: remote_name.to_owned(),
        tracked,
        ahead,
        behind,
    }
}

/// An exact distance of `n` commits.
fn exact(n: u64) -> RefDistance {
    RefDistance {
        lower: n,
        upper: Some(n),
    }
}

/// The sort key's second half: the local row (`None`) before remotes by remote name.
fn remote_of(bookmark: &Bookmark) -> Option<&str> {
    match &bookmark.kind {
        BookmarkKind::Local => None,
        BookmarkKind::Remote { remote_name, .. } => Some(remote_name),
    }
}

/// The reverse-hex change id of the commit `commit_hex`.
fn change_of(root: &Path, commit_hex: &str) -> zanshin_jj::ChangeId {
    let (ws, _) = oracle_workspace(root);
    let repo = pollster::block_on(ws.repo_loader().load_at_head()).unwrap();
    let id = jj_lib::backend::CommitId::try_from_hex(commit_hex).unwrap();
    zanshin_jj::ChangeId(repo.store().get_commit(&id).unwrap().change_id().reverse_hex())
}

/// The listed rows named `name`.
fn rows(root: &Path, name: &str) -> Vec<Bookmark> {
    let mut repo = Repo::open(root).unwrap();
    repo.list_bookmarks()
        .unwrap()
        .into_iter()
        .filter(|b| b.name == name)
        .collect()
}

/// A local row.
fn local_row(name: &str, target: Option<zanshin_jj::ChangeId>, synced: bool) -> Bookmark {
    Bookmark {
        name: name.to_owned(),
        target,
        conflicted: false,
        synced,
        kind: BookmarkKind::Local,
    }
}

/// A remote row on `origin`.
fn origin_row(
    name: &str,
    target: Option<zanshin_jj::ChangeId>,
    synced: bool,
    ahead: Option<RefDistance>,
    behind: Option<RefDistance>,
) -> Bookmark {
    Bookmark {
        name: name.to_owned(),
        target,
        conflicted: false,
        synced,
        kind: remote("origin", true, ahead, behind),
    }
}

/// A parent commit off root and a child of it, as hex ids.
fn parent_and_child(root: &Path) -> (String, String) {
    let parent = add_commit_off_root(root, "parent");
    let child = add_commit_with_files(root, &[&parent], &[("child.txt", "child")], "child");
    (parent, child)
}

#[test]
fn synced_pair_is_synced_on_both_rows_with_zero_distances() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let commit = add_commit_off_root(&fx.path, "c");
    set_local_bookmark(&fx.path, "f", &[&commit]);
    set_remote_bookmark(&fx.path, "f", "origin", &commit, true);
    let c = Some(change_of(&fx.path, &commit));

    assert_eq!(
        rows(&fx.path, "f"),
        vec![
            local_row("f", c.clone(), true),
            origin_row("f", c, true, Some(exact(0)), Some(exact(0))),
        ]
    );
}

#[test]
fn remote_ahead_counts_on_the_remote_rows_ahead() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let (parent, child) = parent_and_child(&fx.path);
    set_local_bookmark(&fx.path, "f", &[&parent]);
    set_remote_bookmark(&fx.path, "f", "origin", &child, true);

    assert_eq!(
        rows(&fx.path, "f"),
        vec![
            local_row("f", Some(change_of(&fx.path, &parent)), false),
            origin_row(
                "f",
                Some(change_of(&fx.path, &child)),
                false,
                Some(exact(1)),
                Some(exact(0))
            ),
        ]
    );
}

#[test]
fn local_ahead_counts_on_the_remote_rows_behind() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let (parent, child) = parent_and_child(&fx.path);
    set_local_bookmark(&fx.path, "f", &[&child]);
    set_remote_bookmark(&fx.path, "f", "origin", &parent, true);

    assert_eq!(
        rows(&fx.path, "f"),
        vec![
            local_row("f", Some(change_of(&fx.path, &child)), false),
            origin_row(
                "f",
                Some(change_of(&fx.path, &parent)),
                false,
                Some(exact(0)),
                Some(exact(1))
            ),
        ]
    );
}

/// The session's case (I1): a local rewrite keeps the change id, so comparing targets says
/// "in sync" while the CLI says ahead by 1, behind by 1.
#[test]
fn a_local_rewrite_is_ahead_one_and_behind_one_under_the_same_change_id() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let commit = add_commit_off_root(&fx.path, "before");
    set_local_bookmark(&fx.path, "f", &[&commit]);
    set_remote_bookmark(&fx.path, "f", "origin", &commit, true);
    let change = Some(change_of(&fx.path, &commit));
    let _rewritten = describe_commit(&fx.path, &commit, "after");

    assert_eq!(
        rows(&fx.path, "f"),
        vec![
            local_row("f", change.clone(), false),
            origin_row("f", change, false, Some(exact(1)), Some(exact(1))),
        ]
    );
}

/// jj-lib's `testing` feature (zanshin-jj's dev build) caps `count_estimate` at 10 and
/// leaves the upper bound open — the CLI's "ahead by at least 10 commits".
#[test]
fn a_count_jj_lib_cannot_bound_carries_no_upper() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let base = add_commit_off_root(&fx.path, "base");
    let mut tip = base.clone();
    for i in 0..12 {
        tip = add_commit_with_files(&fx.path, &[&tip], &[("n.txt", &i.to_string())], "ahead");
    }
    set_local_bookmark(&fx.path, "f", &[&base]);
    set_remote_bookmark(&fx.path, "f", "origin", &tip, true);

    let listed = rows(&fx.path, "f");
    assert_eq!(
        listed[1].kind,
        remote(
            "origin",
            true,
            Some(RefDistance { lower: 10, upper: None }),
            Some(exact(0))
        )
    );
}

#[test]
fn an_untracked_remote_without_a_local_is_one_remote_row_without_distances() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let commit = add_commit_off_root(&fx.path, "r");
    set_remote_bookmark(&fx.path, "r", "origin", &commit, false);

    assert_eq!(
        rows(&fx.path, "r"),
        vec![Bookmark {
            name: "r".to_owned(),
            target: Some(change_of(&fx.path, &commit)),
            conflicted: false,
            synced: false,
            kind: remote("origin", false, None, None),
        }]
    );
}

/// An untracked remote next to a present local: the local row is vacuously synced (only
/// TRACKED remotes count), the remote row is not.
#[test]
fn an_untracked_remote_next_to_a_local_leaves_the_local_synced() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let (parent, child) = parent_and_child(&fx.path);
    set_local_bookmark(&fx.path, "u", &[&parent]);
    set_remote_bookmark(&fx.path, "u", "origin", &child, false);

    assert_eq!(
        rows(&fx.path, "u"),
        vec![
            local_row("u", Some(change_of(&fx.path, &parent)), true),
            Bookmark {
                name: "u".to_owned(),
                target: Some(change_of(&fx.path, &child)),
                conflicted: false,
                synced: false,
                kind: remote("origin", false, None, None),
            },
        ]
    );
}

/// One tracked remote agrees, another does not: the local row is unsynced, each remote row
/// reports its own `synced`.
#[test]
fn a_local_with_one_synced_and_one_unsynced_tracked_remote_is_unsynced() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let (parent, child) = parent_and_child(&fx.path);
    set_local_bookmark(&fx.path, "m", &[&parent]);
    set_remote_bookmark(&fx.path, "m", "origin", &parent, true);
    set_remote_bookmark(&fx.path, "m", "upstream", &child, true);
    let p = Some(change_of(&fx.path, &parent));

    assert_eq!(
        rows(&fx.path, "m"),
        vec![
            local_row("m", p.clone(), false),
            origin_row("m", p, true, Some(exact(0)), Some(exact(0))),
            Bookmark {
                name: "m".to_owned(),
                target: Some(change_of(&fx.path, &child)),
                conflicted: false,
                synced: false,
                kind: remote("upstream", true, Some(exact(1)), Some(exact(0))),
            },
        ]
    );
}

#[test]
fn a_deleted_local_with_a_tracked_remote_is_the_cli_deleted_row() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let commit = add_commit_off_root(&fx.path, "d");
    set_local_bookmark(&fx.path, "d", &[&commit]);
    set_remote_bookmark(&fx.path, "d", "origin", &commit, true);
    set_local_bookmark(&fx.path, "d", &[]);

    assert_eq!(
        rows(&fx.path, "d"),
        vec![
            local_row("d", None, false),
            origin_row("d", Some(change_of(&fx.path, &commit)), false, None, None),
        ]
    );
}

/// A tracked remote ref with an ABSENT target, kept by jj-lib only while the local exists —
/// the CLI's `@origin (not created yet)`. Built in a raw transaction: `set_remote_bookmark`
/// always writes a present target.
#[test]
fn a_tracked_remote_not_created_yet_has_no_target_and_no_distances() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let commit = add_commit_off_root(&fx.path, "n");
    set_local_bookmark(&fx.path, "n", &[&commit]);
    let (ws, _) = oracle_workspace(&fx.path);
    let base = pollster::block_on(ws.repo_loader().load_at_head()).unwrap();
    let mut tx = base.start_transaction();
    tx.repo_mut().set_remote_bookmark(
        RemoteRefSymbol {
            name: "n".as_ref(),
            remote: "origin".as_ref(),
        },
        RemoteRef {
            target: RefTarget::absent(),
            state: RemoteRefState::Tracked,
        },
    );
    pollster::block_on(tx.commit("test: tracked remote not created yet")).unwrap();

    assert_eq!(
        rows(&fx.path, "n"),
        vec![
            local_row("n", Some(change_of(&fx.path, &commit)), false),
            origin_row("n", None, false, None, None),
        ]
    );
}

#[test]
fn a_conflicted_local_reports_its_first_add_and_conflicted() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let a = add_commit_off_root(&fx.path, "a");
    let b = add_commit_off_root(&fx.path, "b");
    set_local_bookmark(&fx.path, "c", &[&a, &b]);

    assert_eq!(
        rows(&fx.path, "c"),
        vec![Bookmark {
            name: "c".to_owned(),
            target: Some(change_of(&fx.path, &a)),
            conflicted: true,
            synced: true,
            kind: BookmarkKind::Local,
        }]
    );
}

/// A conflicted remote target diverges from a present local: distances over the present adds.
#[test]
fn a_conflicted_tracked_remote_is_conflicted_and_unsynced() {
    pin_env();
    let fx = extract_fixture("tiny-3-commits").unwrap();
    let (parent, child) = parent_and_child(&fx.path);
    let other = add_commit_off_root(&fx.path, "other");
    set_local_bookmark(&fx.path, "x", &[&parent]);
    set_remote_bookmark(&fx.path, "x", "origin", &child, true);
    // Turn the remote target into a conflict [child, other].
    let (ws, _) = oracle_workspace(&fx.path);
    let base = pollster::block_on(ws.repo_loader().load_at_head()).unwrap();
    let ids = [&child, &other].map(|hex| jj_lib::backend::CommitId::try_from_hex(hex).unwrap());
    let mut tx = base.start_transaction();
    tx.repo_mut().set_remote_bookmark(
        RemoteRefSymbol {
            name: "x".as_ref(),
            remote: "origin".as_ref(),
        },
        RemoteRef {
            target: RefTarget::from_legacy_form([jj_lib::backend::CommitId::try_from_hex(&parent).unwrap()], ids),
            state: RemoteRefState::Tracked,
        },
    );
    pollster::block_on(tx.commit("test: conflicted remote")).unwrap();

    let listed = rows(&fx.path, "x");
    assert!(!listed[0].synced && !listed[0].conflicted, "{listed:?}");
    assert_eq!(listed[1].target, Some(change_of(&fx.path, &child)));
    assert!(listed[1].conflicted && !listed[1].synced, "{listed:?}");
    assert_eq!(listed[1].kind, remote("origin", true, Some(exact(2)), Some(exact(0))));
}

/// In a colocated repo `@git` is a remote like any other: tracked, synced, zero distances.
#[test]
fn a_colocated_bookmark_has_a_synced_git_row() {
    pin_env();
    let tmp = TempDir::new().unwrap();
    git(&["init", "--initial-branch=main"], tmp.path());
    git(&["config", "user.email", "test@zanshin.test"], tmp.path());
    git(&["config", "user.name", "Fixture"], tmp.path());
    fs::write(tmp.path().join("README.md"), "hello").unwrap();
    git(&["add", "."], tmp.path());
    git(&["commit", "-m", "initial"], tmp.path());
    let mut repo = convert_colocated(tmp.path()).result.expect("convert");
    repo.bookmark_create(&["feature".to_owned()], None).unwrap();

    let listed: Vec<Bookmark> = repo
        .list_bookmarks()
        .unwrap()
        .into_iter()
        .filter(|b| b.name == "feature")
        .collect();
    let target = listed[0].target.clone();
    assert!(target.is_some(), "{listed:?}");
    assert_eq!(
        listed,
        vec![
            local_row("feature", target.clone(), true),
            Bookmark {
                name: "feature".to_owned(),
                target,
                conflicted: false,
                synced: true,
                kind: remote("git", true, Some(exact(0)), Some(exact(0))),
            },
        ]
    );
}

/// Runs `git` in `dir`, panicking on failure.
fn git(args: &[&str], dir: &Path) {
    let out = std::process::Command::new("git")
        .args(args)
        .current_dir(dir)
        .output()
        .expect("git spawns");
    assert!(
        out.status.success(),
        "git {args:?} failed: {}",
        String::from_utf8_lossy(&out.stderr)
    );
}
