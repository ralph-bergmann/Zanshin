// SPDX-License-Identifier: MIT

//! Story 9.59 — `Repo::tag_set`, `tag_delete`, `tag_track`, `tag_untrack` and the reworked
//! `Repo::list_tags` against jj-lib state: every row of the spec's I/O matrix — targets, tracking
//! states and list rows, warnings in the CLI's order, and every refusal and no-op leaving the head
//! operation where it was (`new_op_id` = the pre-call head).
//!
//! The fixture is `bookmark_move.rs`'s: a non-colocated Git-backed repo `root → A → B → C`, `D` a
//! second child of `B`, `@` = `C`. Remote tags are set in-test (`set_remote_tag`, which also
//! creates the remote's view) or pushed to a local bare remote, never by regenerating a fixture.

use std::fs;
use std::path::Path;
use std::process::Command;

use jj_lib::object_id::ObjectId;
use jj_lib::op_store::RefTarget;
use jj_lib::ref_name::{RefName, RemoteName};
use tempfile::TempDir;
use zanshin_jj::{ChangeId, GitPushArgs, MutateError, ProgressEvent, Tag, TagKind, WarningKind};

use crate::bookmark_move::{assert_no_op, assert_refused, base, head_op, hex, invalid_reason, names, wc, Fx};

fn load(root: &Path) -> std::sync::Arc<jj_lib::repo::ReadonlyRepo> {
    let workspace = test_helpers::load_workspace(
        &test_helpers::test_settings(),
        root,
        &jj_lib::default_backend_factories::default_backend_factories(),
        &jj_lib::default_backend_factories::default_working_copy_factories(),
    )
    .expect("load workspace");
    pollster::block_on(workspace.load_at_head()).expect("load head")
}

/// The local tag `name`'s target.
fn local_tag(root: &Path, name: &str) -> RefTarget {
    load(root).view().get_local_tag(RefName::new(name)).clone()
}

/// The remote tag `name@remote`: `(present target hex, tracked)`.
fn remote_tag(root: &Path, name: &str, remote: &str) -> (Option<String>, bool) {
    let repo = load(root);
    let remote_ref = repo
        .view()
        .get_remote_tag(RefName::new(name).to_remote_symbol(RemoteName::new(remote)))
        .clone();
    (
        remote_ref.target.as_normal().map(ObjectId::hex),
        remote_ref.is_tracked(),
    )
}

/// The local tag `name`'s normal target hex.
fn tag_hex(fx: &Fx, name: &str) -> Option<String> {
    local_tag(&fx.root, name).as_normal().map(ObjectId::hex)
}

/// Points the local tag `name` at `target` and reopens.
fn set_tag(fx: &mut Fx, name: &str, target: &ChangeId) {
    test_helpers::set_tag(&fx.root, name, &[&hex(&fx.root, target)]);
    fx.reopen();
}

/// Points `name@remote` at `target` and reopens.
fn set_remote(fx: &mut Fx, name: &str, remote: &str, target: &ChangeId, tracked: bool) {
    test_helpers::set_remote_tag(&fx.root, name, remote, &hex(&fx.root, target), tracked);
    fx.reopen();
}

/// A refusal after the pre-verb snapshot: nothing but a possible snapshot was written.
fn assert_refused_after_snapshot(fx: &mut Fx, err: &MutateError, expected: &str, before: &(String, String)) {
    assert_eq!(invalid_reason(err).0, expected);
    assert!(fx.repo.take_precondition().is_some(), "the snapshot ran first");
    assert_refused(fx, before);
}

/// A clap refusal: before the snapshot, so a dirty working copy stays as it is.
fn assert_clap_refusal(fx: &mut Fx, err: &MutateError, expected: &str, before: &(String, String)) {
    assert_eq!(invalid_reason(err).0, expected);
    assert_refused(fx, before);
    assert!(fx.repo.take_precondition().is_none(), "no snapshot ran");
}

/// `TagKind::Remote` of `remote` and `tracked`.
fn remote_kind(remote: &str, tracked: bool) -> TagKind {
    TagKind::Remote {
        remote_name: remote.to_owned(),
        tracked,
    }
}

// ── set ────────────────────────────────────────────────────────────────────────

#[test]
fn set_creates_a_tag_on_at_with_the_cli_description() {
    let mut fx = base();
    let c = fx.c.clone();
    let result = fx.repo.tag_set(&names(&["v1"]), None, false).expect("set");
    let c_hex = hex(&fx.root, &c);
    assert_eq!(tag_hex(&fx, "v1"), Some(c_hex.clone()));
    let (id, description) = head_op(&fx.root);
    assert_eq!(result.new_op_id.0, id);
    assert_eq!(description, format!("set tag v1 to commit {c_hex}"));
    // `tags()` is in the builtin immutable heads, so the tagged `@` gets a new `@` on top.
    assert_eq!(fx.kinds(), [became_immutable()]);
    assert_eq!(
        fx.repo.list_tags().expect("tags"),
        [Tag {
            name: "v1".to_owned(),
            target: Some(c),
            conflicted: false,
            synced: true,
            kind: TagKind::Local,
        }]
    );
}

/// `-r` names the target; names in ARGUMENT order in the description, quoted where the revset
/// syntax needs it.
#[test]
fn set_on_a_revision_names_every_tag_in_argument_order() {
    let mut fx = base();
    let b = fx.b.clone();
    fx.repo.tag_set(&names(&["z", "a b"]), Some(&b), false).expect("set");
    let b_hex = hex(&fx.root, &b);
    assert_eq!(tag_hex(&fx, "z"), Some(b_hex.clone()));
    assert_eq!(tag_hex(&fx, "a b"), Some(b_hex.clone()));
    assert_eq!(head_op(&fx.root).1, format!("set tag z, \"a b\" to commit {b_hex}"));
}

#[test]
fn set_of_an_existing_tag_is_refused_fail_fast_unless_allowed() {
    let mut fx = base();
    let (a, b) = (fx.a.clone(), fx.b.clone());
    set_tag(&mut fx, "v1", &a);
    let before = head_op(&fx.root);
    let err = fx
        .repo
        .tag_set(&names(&["v2", "v1"]), Some(&b), false)
        .expect_err("existing tag");
    assert_eq!(
        invalid_reason(&err),
        (
            "Refusing to move tag: v1",
            vec!["Use --allow-move to update existing tags.".to_owned()]
        )
    );
    assert_refused(&fx, &before);
    assert!(local_tag(&fx.root, "v2").is_absent(), "fail-fast: v2 is not created");

    fx.repo.tag_set(&names(&["v1"]), Some(&b), true).expect("allowed");
    assert_eq!(tag_hex(&fx, "v1"), Some(hex(&fx.root, &b)));
    assert_eq!(
        head_op(&fx.root).1,
        format!("set tag v1 to commit {}", hex(&fx.root, &b))
    );
}

#[test]
fn set_to_the_same_target_writes_no_operation() {
    let mut fx = base();
    let b = fx.b.clone();
    set_tag(&mut fx, "v1", &b);
    let before = head_op(&fx.root);
    let result = fx.repo.tag_set(&names(&["v1"]), Some(&b), true).expect("no-op");
    assert_no_op(&fx, &before, &result);
}

#[test]
fn set_to_an_empty_target_warns_and_sets() {
    let mut fx = base();
    let c = fx.c.clone();
    fx.repo.new_change(&[c], &[], &[]).expect("new");
    let at = wc(&fx.root);
    let _ = fx.repo.take_warnings();
    fx.repo.tag_set(&names(&["e"]), None, false).expect("set");
    assert_eq!(tag_hex(&fx, "e"), Some(hex(&fx.root, &at)));
    assert_eq!(
        fx.kinds(),
        [
            (WarningKind::TagTargetEmpty, "Target revision is empty.".to_owned()),
            became_immutable()
        ]
    );
}

/// The finish's warning when the tagged `@` turned immutable.
fn became_immutable() -> (WarningKind, String) {
    (
        WarningKind::WorkingCopyImmutable,
        "The working-copy commit became immutable; a new commit has been created on top of it.".to_owned(),
    )
}

#[test]
fn set_clap_refusals_come_before_the_snapshot() {
    let mut fx = base();
    let before = head_op(&fx.root);
    fs::write(fx.root.join("dirty.txt"), "dirty\n").expect("write");
    let err = fx.repo.tag_set(&[], None, false).expect_err("no names");
    assert_clap_refusal(&mut fx, &err, "tag set requires at least one name", &before);
    let err = fx
        .repo
        .tag_set(&names(&["ok", ""]), None, false)
        .expect_err("empty name");
    assert_clap_refusal(&mut fx, &err, "tag name must not be empty", &before);
}

/// An unknown `revision` refuses `ChangeNotFound` and writes nothing.
#[test]
fn set_on_an_unknown_revision_is_change_not_found() {
    let mut fx = base();
    let before = head_op(&fx.root);
    let unknown = ChangeId("xyxyxyxy".to_owned());
    let err = fx
        .repo
        .tag_set(&names(&["v1"]), Some(&unknown), false)
        .expect_err("unknown revision");
    assert!(
        matches!(&err, MutateError::ChangeNotFound { id } if *id == unknown.0),
        "{err:?}"
    );
    assert_refused(&fx, &before);
    assert!(local_tag(&fx.root, "v1").is_absent());
}

// ── delete ─────────────────────────────────────────────────────────────────────

#[test]
fn delete_by_glob_deletes_the_matches_in_view_order() {
    let mut fx = base();
    let b = fx.b.clone();
    for name in ["v1.1", "v2", "v1.0"] {
        set_tag(&mut fx, name, &b);
    }
    fx.repo.tag_delete(&names(&["v1.*"])).expect("delete");
    assert!(local_tag(&fx.root, "v1.0").is_absent());
    assert!(local_tag(&fx.root, "v1.1").is_absent());
    assert!(local_tag(&fx.root, "v2").is_present());
    assert_eq!(head_op(&fx.root).1, "delete tag v1.0, v1.1");
    assert!(fx.kinds().is_empty());
}

#[test]
fn delete_of_an_unmatched_name_warns_and_writes_no_operation() {
    let mut fx = base();
    let before = head_op(&fx.root);
    let result = fx.repo.tag_delete(&names(&["nope"])).expect("no-op");
    assert_no_op(&fx, &before, &result);
    assert_eq!(
        fx.kinds(),
        [(
            WarningKind::TagNamesUnmatched,
            "No matching tags for names: nope".to_owned()
        )]
    );
}

#[test]
fn delete_refusals() {
    let mut fx = base();
    let before = head_op(&fx.root);
    fs::write(fx.root.join("dirty.txt"), "dirty\n").expect("write");
    let err = fx.repo.tag_delete(&[]).expect_err("no names");
    assert_clap_refusal(&mut fx, &err, "tag delete requires at least one name", &before);
    let err = fx.repo.tag_delete(&names(&["glob:\"[\""])).expect_err("bad glob");
    assert!(
        invalid_reason(&err).0.starts_with("failed to parse name pattern"),
        "{err:?}"
    );
    assert!(
        fx.repo.take_precondition().is_some(),
        "the pattern is parsed after the snapshot"
    );
}

/// Runs `git` in `dir`; panics on a non-zero exit. Fixture setup only.
fn git(args: &[&str], dir: &Path) {
    let out = Command::new("git")
        .args(args)
        .current_dir(dir)
        .output()
        .expect("git spawns");
    assert!(
        out.status.success(),
        "git {args:?}: {}",
        String::from_utf8_lossy(&out.stderr)
    );
}

/// A tag pushed with `jj git push -t` is tracked on the remote; deleting it locally keeps the
/// tracked `v1@origin` row — the "deleted" state the next push sends. The local row stays as the
/// CLI's `(deleted)` row, without a target.
#[test]
fn delete_of_a_pushed_tag_keeps_the_tracked_remote_row() {
    let mut fx = base();
    let c = fx.c.clone();
    let remote_dir = TempDir::new().expect("tempdir");
    let bare = remote_dir.path().join("origin.git");
    git(&["init", "--bare", &bare.to_string_lossy()], remote_dir.path());
    fx.repo
        .git_remote_add("origin", &bare.to_string_lossy(), None)
        .expect("remote add");
    fx.repo.tag_set(&names(&["v1"]), Some(&c), false).expect("set");
    fx.repo
        .git_push(
            &GitPushArgs {
                tags: names(&["v1"]),
                ..Default::default()
            },
            &|_: ProgressEvent| {},
            None,
        )
        .expect("push -t");
    assert_eq!(remote_tag(&fx.root, "v1", "origin"), (Some(hex(&fx.root, &c)), true));

    fx.repo.tag_delete(&names(&["v1"])).expect("delete");
    assert!(local_tag(&fx.root, "v1").is_absent());
    assert_eq!(head_op(&fx.root).1, "delete tag v1");
    assert_eq!(
        fx.repo.list_tags().expect("tags"),
        [
            Tag {
                name: "v1".to_owned(),
                target: None,
                conflicted: false,
                synced: false,
                kind: TagKind::Local,
            },
            Tag {
                name: "v1".to_owned(),
                target: Some(c),
                conflicted: false,
                synced: false,
                kind: remote_kind("origin", true),
            },
        ]
    );
}

// ── track / untrack ────────────────────────────────────────────────────────────

#[test]
fn track_and_untrack_a_symbol_flip_the_tracking() {
    let mut fx = base();
    let b = fx.b.clone();
    set_remote(&mut fx, "v1", "origin", &b, false);
    fx.repo.tag_track(&names(&["v1@origin"]), &[]).expect("track");
    assert_eq!(remote_tag(&fx.root, "v1", "origin"), (Some(hex(&fx.root, &b)), true));
    assert_eq!(
        tag_hex(&fx, "v1"),
        Some(hex(&fx.root, &b)),
        "tracking merges into the local tag"
    );
    assert_eq!(head_op(&fx.root).1, "track remote tag v1@origin");

    fx.repo.tag_untrack(&names(&["v1@origin"]), &[]).expect("untrack");
    assert_eq!(remote_tag(&fx.root, "v1", "origin"), (Some(hex(&fx.root, &b)), false));
    assert_eq!(head_op(&fx.root).1, "untrack remote tag v1@origin");
    assert!(fx.kinds().is_empty());
}

/// A pattern matches every remote but `git`; unmatched exact names and remotes warn.
#[test]
fn track_by_pattern_skips_git_and_warns_the_unmatched() {
    let mut fx = base();
    let b = fx.b.clone();
    set_remote(&mut fx, "v1", "origin", &b, false);
    set_remote(&mut fx, "v1", "git", &b, false);
    fx.repo.tag_track(&names(&["v*", "nope"]), &[]).expect("track");
    assert!(remote_tag(&fx.root, "v1", "origin").1);
    assert!(
        !remote_tag(&fx.root, "v1", "git").1,
        "the default remote filter skips git"
    );
    assert_eq!(head_op(&fx.root).1, "track remote tag v1@origin");
    assert_eq!(
        fx.kinds(),
        [(
            WarningKind::TagNamesUnmatched,
            "No matching tags for names: nope".to_owned()
        )]
    );

    let before = head_op(&fx.root);
    let result = fx
        .repo
        .tag_track(&names(&["v1"]), &names(&["upstream"]))
        .expect("no remote");
    assert_no_op(&fx, &before, &result);
    assert_eq!(
        fx.kinds(),
        [(
            WarningKind::TagRemotesUnmatched,
            "No matching remotes for names: upstream".to_owned()
        )]
    );
}

#[test]
fn track_of_a_tracked_or_unknown_symbol_warns_and_writes_nothing() {
    let mut fx = base();
    let b = fx.b.clone();
    set_remote(&mut fx, "v1", "origin", &b, true);
    let before = head_op(&fx.root);
    let result = fx
        .repo
        .tag_track(&names(&["v1@origin", "v9@origin"]), &[])
        .expect("nothing to track");
    assert_no_op(&fx, &before, &result);
    assert_eq!(
        fx.kinds(),
        [
            (
                WarningKind::RemoteTagsUnmatched,
                "No matching remote tags for names: v9@origin".to_owned()
            ),
            (
                WarningKind::TagAlreadyTracked,
                "Remote tag already tracked: v1@origin".to_owned()
            ),
        ]
    );
}

#[test]
fn untrack_of_git_or_an_untracked_tag_warns_and_writes_nothing() {
    let mut fx = base();
    let b = fx.b.clone();
    set_remote(&mut fx, "v1", "git", &b, true);
    set_remote(&mut fx, "v2", "origin", &b, false);
    let before = head_op(&fx.root);
    let result = fx
        .repo
        .tag_untrack(&names(&["v1@git", "v2@origin"]), &[])
        .expect("nothing to untrack");
    assert_no_op(&fx, &before, &result);
    assert!(remote_tag(&fx.root, "v1", "git").1, "the git tag stays tracked");
    assert_eq!(
        fx.kinds(),
        [
            (
                WarningKind::TagGitTrackingUntrack,
                "Git-tracking tag cannot be untracked: v1@git".to_owned()
            ),
            (
                WarningKind::TagNotTracked,
                "Remote tag not tracked yet: v2@origin".to_owned()
            ),
        ]
    );
}

/// A LOCAL-only `v2` is trackable on a remote whose view lacks it — by pattern (the absent half
/// of `trackable_matching`) and by symbol (`resolve_trackable`'s local-present arm): the remote row
/// becomes tracked with no target ("not created yet").
#[test]
fn track_of_a_local_only_tag_onto_a_remote_view_without_it() {
    for text in ["v2", "v2@origin"] {
        let mut fx = base();
        let (a, b) = (fx.a.clone(), fx.b.clone());
        set_remote(&mut fx, "v1", "origin", &b, true);
        set_tag(&mut fx, "v2", &a);
        fx.repo.tag_track(&names(&[text]), &[]).expect("track");
        assert_eq!(head_op(&fx.root).1, "track remote tag v2@origin", "{text}");
        assert!(fx.kinds().is_empty(), "{text}");
        let row = fx
            .repo
            .list_tags()
            .expect("tags")
            .into_iter()
            .find(|t| t.name == "v2" && t.kind == remote_kind("origin", true))
            .expect("a tracked v2@origin row");
        assert_eq!(row.target, None, "{text}: not created on the remote yet");
    }
}

/// `untrack` by PATTERN: the default filter leaves out `git`; an untracked match warns.
#[test]
fn untrack_by_pattern_skips_git_and_warns_the_untracked() {
    let mut fx = base();
    let b = fx.b.clone();
    set_remote(&mut fx, "v1", "origin", &b, true);
    set_remote(&mut fx, "v1", "git", &b, true);
    set_remote(&mut fx, "v2", "origin", &b, false);
    fx.repo.tag_untrack(&names(&["v*"]), &[]).expect("untrack");
    assert_eq!(head_op(&fx.root).1, "untrack remote tag v1@origin");
    assert!(!remote_tag(&fx.root, "v1", "origin").1);
    assert!(remote_tag(&fx.root, "v1", "git").1, "the default filter skips git");
    assert_eq!(
        fx.kinds(),
        [(
            WarningKind::TagNotTracked,
            "Remote tag not tracked yet: v2@origin".to_owned()
        )]
    );
}

#[test]
fn track_refusals() {
    let mut fx = base();
    let before = head_op(&fx.root);
    let err = fx.repo.tag_track(&[], &[]).expect_err("no names");
    assert_clap_refusal(&mut fx, &err, "tag track requires at least one name", &before);
    let err = fx
        .repo
        .tag_untrack(&names(&["v1", "v2@origin"]), &[])
        .expect_err("mixed");
    assert_refused_after_snapshot(
        &mut fx,
        &err,
        "Cannot specify both <tag> patterns and <tag>@<remote> symbols",
        &before,
    );
    let err = fx
        .repo
        .tag_track(&names(&["v2@origin"]), &names(&["origin"]))
        .expect_err("--remote with symbols");
    assert_refused_after_snapshot(
        &mut fx,
        &err,
        "--remote cannot be used with <tag>@<remote> symbols",
        &before,
    );
}

// ── list ───────────────────────────────────────────────────────────────────────

/// The spec's list row: local `v1` + tracked `v1@origin` + untracked `v2@origin` + `@git` rows.
#[test]
fn list_shows_local_tracked_and_untracked_rows_without_git() {
    let mut fx = base();
    let (b, c) = (fx.b.clone(), fx.c.clone());
    set_tag(&mut fx, "v1", &b);
    set_remote(&mut fx, "v1", "origin", &b, true);
    set_remote(&mut fx, "v1", "git", &b, true);
    set_remote(&mut fx, "v2", "origin", &c, false);
    let rows: Vec<(String, TagKind, Option<ChangeId>, bool)> = fx
        .repo
        .list_tags()
        .expect("tags")
        .into_iter()
        .map(|t| (t.name, t.kind, t.target, t.synced))
        .collect();
    assert_eq!(
        rows,
        [
            ("v1".to_owned(), TagKind::Local, Some(b.clone()), true),
            ("v1".to_owned(), remote_kind("origin", true), Some(b), true),
            ("v2".to_owned(), remote_kind("origin", false), Some(c), false),
        ]
    );
}
