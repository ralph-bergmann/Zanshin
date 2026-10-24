// SPDX-License-Identifier: MIT

//! Story 9.11 — `Repo::bookmark_set`, `bookmark_forget`, `bookmark_track` and `bookmark_untrack`
//! against jj-lib state: every row of the spec's I/O matrix — targets, tracking states and remote
//! rows read back through jj-lib, warnings in the CLI's order, and every refusal and no-op leaving
//! the head operation where it was (`new_op_id` = the pre-call head).
//!
//! The fixture is `bookmark_move.rs`'s: a non-colocated Git-backed repo `root → A → B → C`, `D` a
//! second child of `B`, `@` = `C`. Remote rows are set in-test (`set_remote_bookmark`, which also
//! creates the remote's view), never by regenerating a fixture.

use std::fs;

use zanshin_jj::{MutateError, Repo, WarningKind};

use crate::bookmark_move::{
    assert_no_op, assert_refused, base, commit_id, head_op, hex, invalid_reason, local, names, remote, set_repo_config,
    wc, Fx,
};

/// Adds a git remote with a fake URL — enough for jj-lib to create its remote view.
fn add_remote(fx: &mut Fx, name: &str) {
    let url = fx.root.join(format!("{name}.git"));
    fx.repo
        .git_remote_add(name, &url.to_string_lossy(), None)
        .expect("git remote add");
    let _ = fx.repo.take_warnings();
}

/// A refusal after the pre-verb snapshot: the dirty working copy was snapshotted (an operation of
/// its own, as the CLI writes one), the verb wrote nothing more.
fn assert_refused_after_snapshot(fx: &mut Fx, err: &MutateError, expected: &str) {
    assert_eq!(invalid_reason(err).0, expected);
    assert!(fx.repo.take_precondition().is_some(), "the snapshot ran first");
    assert_eq!(
        head_op(&fx.root).1,
        "snapshot working copy",
        "only the snapshot was written"
    );
}

/// A clap refusal: before the snapshot, so a dirty working copy stays as it is.
fn assert_clap_refusal(fx: &mut Fx, err: &MutateError, expected: &str, before: &(String, String)) {
    assert_eq!(invalid_reason(err).0, expected);
    assert_refused(fx, before);
    assert!(fx.repo.take_precondition().is_none(), "no snapshot ran");
}

// ── set ────────────────────────────────────────────────────────────────────────

#[test]
fn set_creates_a_new_bookmark_with_the_cli_description() {
    let mut fx = base();
    let b = fx.b.clone();
    let result = fx.repo.bookmark_set(&names(&["new"]), Some(&b), false).expect("set");
    let b_hex = hex(&fx.root, &b);
    assert_eq!(fx.normal("new"), Some(b_hex.clone()));
    let (id, description) = head_op(&fx.root);
    assert_eq!(result.new_op_id.0, id);
    assert_eq!(description, format!("point bookmark new to commit {b_hex}"));
    assert!(fx.kinds().is_empty());
}

#[test]
fn set_moves_forward_and_a_second_identical_set_writes_no_operation() {
    let mut fx = base();
    let (b, c) = (fx.b.clone(), fx.c.clone());
    fx.set("b-mark", &[&b]);
    fx.repo
        .bookmark_set(&names(&["b-mark"]), Some(&c), false)
        .expect("forward");
    assert_eq!(fx.normal("b-mark"), Some(hex(&fx.root, &c)));
    let before = head_op(&fx.root);
    let result = fx
        .repo
        .bookmark_set(&names(&["b-mark"]), Some(&c), false)
        .expect("no-op");
    assert_no_op(&fx, &before, &result);
}

/// Names in ARGUMENT order in the description; the default revision is `@`; a conflicted bookmark
/// gets a normal target.
#[test]
fn set_names_every_bookmark_in_argument_order_and_resolves_a_conflict() {
    let mut fx = base();
    let (b, c, d) = (fx.b.clone(), fx.c.clone(), fx.d.clone());
    fx.set("z", &[&b, &d]);
    fx.repo.bookmark_set(&names(&["z", "a"]), None, false).expect("set");
    let c_hex = hex(&fx.root, &c);
    assert_eq!(fx.normal("z"), Some(c_hex.clone()));
    assert_eq!(fx.normal("a"), Some(c_hex.clone()));
    assert_eq!(head_op(&fx.root).1, format!("point bookmark z, a to commit {c_hex}"));
}

#[test]
fn set_backwards_is_refused_fail_fast_with_the_hint_unless_allowed() {
    let mut fx = base();
    let (a, b) = (fx.a.clone(), fx.b.clone());
    fx.set("b-mark", &[&b]);
    let before = head_op(&fx.root);
    let err = fx
        .repo
        .bookmark_set(&names(&["new", "b-mark"]), Some(&a), false)
        .expect_err("backwards");
    assert_eq!(
        invalid_reason(&err),
        (
            "Refusing to move bookmark backwards or sideways: b-mark",
            vec!["Use --allow-backwards to allow it.".to_owned()]
        )
    );
    assert_refused(&fx, &before);
    assert!(
        local(&fx.root, "new").is_absent(),
        "fail-fast: the first name is not set either"
    );

    fx.repo
        .bookmark_set(&names(&["b-mark"]), Some(&a), true)
        .expect("allowed");
    assert_eq!(fx.normal("b-mark"), Some(hex(&fx.root, &a)));
}

#[test]
fn set_to_an_empty_target_warns_and_sets() {
    let mut fx = base();
    let c = fx.c.clone();
    fx.repo.new_change(&[c], &[], &[]).expect("new");
    let at = wc(&fx.root);
    let _ = fx.repo.take_warnings();
    fx.repo.bookmark_set(&names(&["e"]), None, false).expect("set");
    assert_eq!(fx.normal("e"), Some(hex(&fx.root, &at)));
    assert_eq!(
        fx.kinds(),
        [(WarningKind::BookmarkTargetEmpty, "Target revision is empty.".to_owned())]
    );
}

#[test]
fn set_clap_refusals_come_before_the_snapshot() {
    let mut fx = base();
    let before = head_op(&fx.root);
    fs::write(fx.root.join("dirty.txt"), "dirty\n").expect("write");
    let err = fx.repo.bookmark_set(&[], None, false).expect_err("no names");
    assert_clap_refusal(&mut fx, &err, "bookmark set requires at least one name", &before);
    let err = fx
        .repo
        .bookmark_set(&names(&["ok", ""]), None, false)
        .expect_err("empty name");
    assert_clap_refusal(&mut fx, &err, "bookmark name must not be empty", &before);
}

/// A NEW name is auto-tracked as `create` does it (one shared loop): on a remote with a view whose
/// matcher accepts it, an existing row warning first; a name that already exists locally is not.
#[test]
fn set_auto_tracks_new_names_like_create() {
    let mut fx = base();
    let (b, c, d) = (fx.b.clone(), fx.c.clone(), fx.d.clone());
    add_remote(&mut fx, "origin");
    set_repo_config(&fx.root, "remotes.origin.auto-track-created-bookmarks", "\"*\"");
    fx.set_remote("feature", "origin", &d, false);
    fx.set("old", &[&b]);
    fx.set_remote("old", "origin", &b, false);
    fx.repo
        .bookmark_set(&names(&["other", "feature", "old"]), Some(&c), false)
        .expect("set");
    assert_eq!(remote(&fx.root, "other", "origin"), (None, true));
    assert_eq!(remote(&fx.root, "feature", "origin"), (Some(hex(&fx.root, &d)), true));
    assert_eq!(remote(&fx.root, "old", "origin"), (Some(hex(&fx.root, &b)), false));
    assert_eq!(
        fx.kinds(),
        [(
            WarningKind::BookmarkAutoTrackExisting,
            "Auto-tracking bookmark that exists on the remote: feature@origin".to_owned()
        )]
    );
}

/// An absent local bookmark that still tracks a remote is RESURRECTED, not created: no
/// auto-tracking anywhere — and a following `create` of the name is refused, as in the CLI.
#[test]
fn set_resurrects_a_tracked_name_without_auto_tracking() {
    let mut fx = base();
    let (b, c) = (fx.b.clone(), fx.c.clone());
    set_repo_config(&fx.root, "remotes.upstream.auto-track-created-bookmarks", "\"*\"");
    fx.set_remote("x", "origin", &b, true);
    fx.set_remote("x", "upstream", &b, false);
    let err = fx
        .repo
        .bookmark_create(&names(&["x"]), Some(&c))
        .expect_err("the tracked remote blocks create");
    assert!(
        matches!(err, MutateError::BookmarkTrackedRemoteExists { .. }),
        "{err:?}"
    );

    fx.repo.bookmark_set(&names(&["x"]), Some(&c), false).expect("set");
    assert_eq!(fx.normal("x"), Some(hex(&fx.root, &c)));
    assert_eq!(remote(&fx.root, "x", "upstream"), (Some(hex(&fx.root, &b)), false));
    assert!(fx.kinds().is_empty());
    let err = fx
        .repo
        .bookmark_create(&names(&["x"]), Some(&c))
        .expect_err("now a local bookmark");
    assert!(matches!(err, MutateError::BookmarkExists { .. }), "{err:?}");
}

// ── forget ─────────────────────────────────────────────────────────────────────

/// The local bookmark goes, its tracked remotes are untracked, the Git-tracking `git` one is left
/// alone; the pattern is a glob.
#[test]
fn forget_drops_the_local_bookmark_and_untracks_its_remotes() {
    let mut fx = base();
    let b = fx.b.clone();
    let b_hex = hex(&fx.root, &b);
    fx.set("b-mark", &[&b]);
    fx.set_remote("b-mark", "origin", &b, true);
    fx.set_remote("b-mark", "git", &b, true);
    let result = fx
        .repo
        .bookmark_forget(&names(&["glob:\"b-*\""]), false)
        .expect("forget");
    assert!(local(&fx.root, "b-mark").is_absent());
    assert_eq!(remote(&fx.root, "b-mark", "origin"), (Some(b_hex.clone()), false));
    assert_eq!(remote(&fx.root, "b-mark", "git"), (Some(b_hex), true));
    let (id, description) = head_op(&fx.root);
    assert_eq!(result.new_op_id.0, id);
    assert_eq!(description, "forget bookmark b-mark");
    assert!(fx.kinds().is_empty());
}

#[test]
fn forget_include_remotes_drops_every_remote_row_git_included() {
    let mut fx = base();
    let b = fx.b.clone();
    fx.set("x", &[&b]);
    fx.set_remote("x", "origin", &b, true);
    fx.set_remote("x", "git", &b, true);
    fx.repo.bookmark_forget(&names(&["x"]), true).expect("forget");
    assert!(local(&fx.root, "x").is_absent());
    assert_eq!(remote(&fx.root, "x", "origin"), (None, false));
    assert_eq!(remote(&fx.root, "x", "git"), (None, false));
}

/// A remote-only name matches (its untrack changes nothing, so nothing is written); a name with
/// no row anywhere warns and writes nothing.
#[test]
fn forget_of_an_untracked_remote_only_or_unknown_name_writes_no_operation() {
    let mut fx = base();
    let d = fx.d.clone();
    fx.set_remote("y", "origin", &d, false);
    let before = head_op(&fx.root);
    let result = fx.repo.bookmark_forget(&names(&["y"]), false).expect("forget y");
    assert_no_op(&fx, &before, &result);
    assert!(fx.kinds().is_empty());

    let result = fx.repo.bookmark_forget(&names(&["nope"]), false).expect("forget nope");
    assert_no_op(&fx, &before, &result);
    assert_eq!(
        fx.kinds(),
        [(
            WarningKind::BookmarkNamesUnmatched,
            "No matching bookmarks for names: nope".to_owned()
        )]
    );
}

#[test]
fn forget_refuses_no_patterns_before_and_a_bad_one_after_the_snapshot() {
    let mut fx = base();
    let before = head_op(&fx.root);
    fs::write(fx.root.join("dirty.txt"), "dirty\n").expect("write");
    let err = fx.repo.bookmark_forget(&[], false).expect_err("no patterns");
    assert_clap_refusal(&mut fx, &err, "bookmark forget requires at least one name", &before);
    let err = fx
        .repo
        .bookmark_forget(&names(&["glob:\"[\""]), false)
        .expect_err("bad glob");
    assert_refused_after_snapshot(
        &mut fx,
        &err,
        "failed to parse name pattern: Invalid string pattern: error parsing glob '[': unclosed character class; \
         missing ']'",
    );
}

// ── track ──────────────────────────────────────────────────────────────────────

#[test]
fn track_a_symbol_tracks_it_and_merges_its_target() {
    let mut fx = base();
    let d = fx.d.clone();
    let d_hex = hex(&fx.root, &d);
    fx.set_remote("y", "origin", &d, false);
    let result = fx.repo.bookmark_track(&names(&["y@origin"]), &[]).expect("track");
    assert_eq!(remote(&fx.root, "y", "origin"), (Some(d_hex.clone()), true));
    assert_eq!(fx.normal("y"), Some(d_hex));
    let (id, description) = head_op(&fx.root);
    assert_eq!(result.new_op_id.0, id);
    assert_eq!(description, "track remote bookmark y@origin");
    assert!(fx.kinds().is_empty());
}

/// A pattern matches a local name the remote lacks: tracked, target-absent ("not created yet").
/// The default filter leaves out `git`, whose view exists here.
#[test]
fn track_a_pattern_tracks_a_local_name_absent_on_the_remote() {
    let mut fx = base();
    let (b, d) = (fx.b.clone(), fx.d.clone());
    fx.set("x", &[&b]);
    fx.set_remote("z", "origin", &d, false);
    fx.set_remote("z", "git", &d, true);
    fx.repo.bookmark_track(&names(&["x"]), &[]).expect("track");
    assert_eq!(remote(&fx.root, "x", "origin"), (None, true));
    assert_eq!(remote(&fx.root, "x", "git"), (None, false));
    assert_eq!(head_op(&fx.root).1, "track remote bookmark x@origin");
    assert!(fx.kinds().is_empty());
}

/// Without a `git` view the default filter ignores no remote: a pattern matches every remote.
#[test]
fn track_a_pattern_without_a_git_view_matches_every_remote() {
    let mut fx = base();
    let d = fx.d.clone();
    let d_hex = hex(&fx.root, &d);
    fx.set_remote("y", "origin", &d, false);
    let result = fx.repo.bookmark_track(&names(&["y"]), &[]).expect("track");
    assert_eq!(remote(&fx.root, "y", "origin"), (Some(d_hex.clone()), true));
    assert_eq!(fx.normal("y"), Some(d_hex));
    let (id, description) = head_op(&fx.root);
    assert_eq!(result.new_op_id.0, id);
    assert_eq!(description, "track remote bookmark y@origin");
    assert!(fx.kinds().is_empty());
}

#[test]
fn track_of_tracked_or_unmatched_refs_warns_and_writes_no_operation() {
    let mut fx = base();
    let b = fx.b.clone();
    fx.set("x", &[&b]);
    fx.set_remote("x", "origin", &b, true);
    let before = head_op(&fx.root);
    let result = fx
        .repo
        .bookmark_track(&names(&["x@origin", "nope@origin"]), &[])
        .expect("track");
    assert_no_op(&fx, &before, &result);
    assert_eq!(
        fx.kinds(),
        [
            (
                WarningKind::RemoteBookmarksUnmatched,
                "No matching remote bookmarks for names: nope@origin".to_owned()
            ),
            (
                WarningKind::BookmarkAlreadyTracked,
                "Remote bookmark already tracked: x@origin".to_owned()
            ),
        ]
    );

    let result = fx
        .repo
        .bookmark_track(&names(&["x", "gone"]), &names(&["nope"]))
        .expect("track --remote nope");
    assert_no_op(&fx, &before, &result);
    assert_eq!(
        fx.kinds(),
        [
            (
                WarningKind::BookmarkNamesUnmatched,
                "No matching bookmarks for names: gone".to_owned()
            ),
            (
                WarningKind::BookmarkRemotesUnmatched,
                "No matching remotes for names: nope".to_owned()
            ),
        ]
    );
}

#[test]
fn track_and_untrack_refuse_bad_arguments_after_the_snapshot() {
    let cases: [(&[&str], &[&str], &str); 4] = [
        (
            &["a", "b@origin"],
            &[],
            "Cannot specify both <bookmark> patterns and <bookmark>@<remote> symbols",
        ),
        (
            &["b@origin"],
            &["origin"],
            "--remote cannot be used with <bookmark>@<remote> symbols",
        ),
        (
            &["glob:\"[\""],
            &[],
            "failed to parse name pattern or remote symbol: Invalid string pattern: error parsing glob '[': \
             unclosed character class; missing ']'",
        ),
        (
            &["a"],
            &["glob:\"[\""],
            "failed to parse name pattern: Invalid string pattern: error parsing glob '[': unclosed character \
             class; missing ']'",
        ),
    ];
    for untrack in [false, true] {
        for (texts, remotes, expected) in cases {
            let mut fx = base();
            fs::write(fx.root.join("dirty.txt"), "dirty\n").expect("write");
            let call = if untrack {
                Repo::bookmark_untrack
            } else {
                Repo::bookmark_track
            };
            let err = call(&mut fx.repo, &names(texts), &names(remotes)).expect_err(expected);
            assert_refused_after_snapshot(&mut fx, &err, expected);
        }
    }
    let mut fx = base();
    let before = head_op(&fx.root);
    fs::write(fx.root.join("dirty.txt"), "dirty\n").expect("write");
    let err = fx.repo.bookmark_track(&[], &[]).expect_err("no names");
    assert_clap_refusal(&mut fx, &err, "bookmark track requires at least one name", &before);
    let err = fx.repo.bookmark_untrack(&[], &[]).expect_err("no names");
    assert_clap_refusal(&mut fx, &err, "bookmark untrack requires at least one name", &before);
}

// ── untrack ────────────────────────────────────────────────────────────────────

/// Untracking keeps the local bookmark; a second untrack warns and writes nothing; `@git` warns.
#[test]
fn untrack_untracks_and_warns_the_untracked_and_git_tracking_refs() {
    let mut fx = base();
    let b = fx.b.clone();
    let b_hex = hex(&fx.root, &b);
    fx.set("x", &[&b]);
    fx.set_remote("x", "origin", &b, true);
    fx.set_remote("x", "git", &b, true);
    let result = fx.repo.bookmark_untrack(&names(&["x@origin"]), &[]).expect("untrack");
    assert_eq!(remote(&fx.root, "x", "origin"), (Some(b_hex.clone()), false));
    assert_eq!(fx.normal("x"), Some(b_hex));
    let (id, description) = head_op(&fx.root);
    assert_eq!(result.new_op_id.0, id);
    assert_eq!(description, "untrack remote bookmark x@origin");

    let before = head_op(&fx.root);
    let result = fx
        .repo
        .bookmark_untrack(&names(&["x@origin", "x@git"]), &[])
        .expect("untrack again");
    assert_no_op(&fx, &before, &result);
    assert_eq!(
        fx.kinds(),
        [
            (
                WarningKind::BookmarkGitTrackingUntrack,
                "Git-tracking bookmark cannot be untracked: x@git".to_owned()
            ),
            (
                WarningKind::BookmarkNotTracked,
                "Remote bookmark not tracked yet: x@origin".to_owned()
            ),
        ]
    );
}

/// A pattern untracks on every remote but `git` by default; `--remote git` names it and warns.
#[test]
fn untrack_a_pattern_leaves_git_out_unless_named() {
    let mut fx = base();
    let b = fx.b.clone();
    fx.set("x", &[&b]);
    fx.set_remote("x", "origin", &b, true);
    fx.set_remote("x", "git", &b, true);
    fx.repo.bookmark_untrack(&names(&["x"]), &[]).expect("untrack");
    assert!(!remote(&fx.root, "x", "origin").1);
    assert!(remote(&fx.root, "x", "git").1);
    assert!(fx.kinds().is_empty());

    let before = head_op(&fx.root);
    let result = fx
        .repo
        .bookmark_untrack(&names(&["x"]), &names(&["git"]))
        .expect("untrack --remote git");
    assert_no_op(&fx, &before, &result);
    assert_eq!(
        fx.kinds(),
        [(
            WarningKind::BookmarkGitTrackingUntrack,
            "Git-tracking bookmark cannot be untracked: x@git".to_owned()
        )]
    );
}

/// The `jj.bookmark_tracked_remote_exists` remedy: untracking the remote frees the name for
/// `create`.
#[test]
fn untrack_frees_a_name_blocked_by_a_tracked_remote_for_create() {
    let mut fx = base();
    let (b, c) = (fx.b.clone(), fx.c.clone());
    fx.set_remote("x", "origin", &b, true);
    let err = fx.repo.bookmark_create(&names(&["x"]), Some(&c)).expect_err("blocked");
    assert!(
        matches!(err, MutateError::BookmarkTrackedRemoteExists { .. }),
        "{err:?}"
    );
    fx.repo.bookmark_untrack(&names(&["x@origin"]), &[]).expect("untrack");
    fx.repo.bookmark_create(&names(&["x"]), Some(&c)).expect("create");
    assert_eq!(fx.normal("x"), Some(hex(&fx.root, &c)));
}

// ── review follow-ups ──────────────────────────────────────────────────────────

/// A broken auto-track pattern refuses `set` as the CLI's `remote_settings()` parse does — even
/// for an EXISTING name, whose auto-tracking never runs — but only after the per-name checks: a
/// backwards move refuses first.
#[test]
fn set_refuses_a_broken_auto_track_pattern_after_the_backwards_check() {
    let mut fx = base();
    let (a, b, c) = (fx.a.clone(), fx.b.clone(), fx.c.clone());
    fx.set("b-mark", &[&b]);
    set_repo_config(&fx.root, "remotes.origin.auto-track-created-bookmarks", "\"(\"");
    let before = head_op(&fx.root);
    let err = fx
        .repo
        .bookmark_set(&names(&["b-mark"]), Some(&c), false)
        .expect_err("broken pattern");
    assert!(matches!(err, MutateError::Config { .. }), "{err:?}");
    assert_refused(&fx, &before);
    assert_eq!(fx.normal("b-mark"), Some(hex(&fx.root, &b)));

    let err = fx
        .repo
        .bookmark_set(&names(&["b-mark"]), Some(&a), false)
        .expect_err("backwards");
    assert_eq!(
        invalid_reason(&err).0,
        "Refusing to move bookmark backwards or sideways: b-mark"
    );
    assert_refused(&fx, &before);
}

/// Repeated symbols are sorted and deduplicated: one ref in the description, one warning for an
/// already tracked one.
#[test]
fn track_deduplicates_repeated_symbols() {
    let mut fx = base();
    let (b, d) = (fx.b.clone(), fx.d.clone());
    fx.set_remote("y", "origin", &d, false);
    fx.repo
        .bookmark_track(&names(&["y@origin", "y@origin"]), &[])
        .expect("track");
    assert_eq!(head_op(&fx.root).1, "track remote bookmark y@origin");

    fx.set("x", &[&b]);
    fx.set_remote("x", "origin", &b, true);
    let _ = fx.kinds();
    let before = head_op(&fx.root);
    let result = fx
        .repo
        .bookmark_track(&names(&["x@origin", "x@origin"]), &[])
        .expect("already tracked");
    assert_no_op(&fx, &before, &result);
    assert_eq!(
        fx.kinds(),
        [(
            WarningKind::BookmarkAlreadyTracked,
            "Remote bookmark already tracked: x@origin".to_owned()
        )]
    );
}

/// A symbol whose remote has a view but no such row is trackable when the local bookmark exists:
/// tracked, target-absent.
#[test]
fn track_a_symbol_of_a_local_name_the_remote_lacks() {
    let mut fx = base();
    let (b, d) = (fx.b.clone(), fx.d.clone());
    fx.set("x", &[&b]);
    fx.set_remote("z", "origin", &d, false);
    let result = fx.repo.bookmark_track(&names(&["x@origin"]), &[]).expect("track");
    assert_eq!(remote(&fx.root, "x", "origin"), (None, true));
    let (id, description) = head_op(&fx.root);
    assert_eq!(result.new_op_id.0, id);
    assert_eq!(description, "track remote bookmark x@origin");
}

/// Tracking a remote bookmark that points at a SIBLING of the local target (`C` and `D`, both
/// children of `B`) merges it into the local one: a conflict of both.
#[test]
fn track_merges_a_diverged_remote_target_into_a_conflict() {
    let mut fx = base();
    let (c, d) = (fx.c.clone(), fx.d.clone());
    let (c_id, d_id) = (commit_id(&fx.root, &c), commit_id(&fx.root, &d));
    fx.set("x", &[&c]);
    fx.set_remote("x", "origin", &d, false);
    fx.repo.bookmark_track(&names(&["x@origin"]), &[]).expect("track");
    let target = local(&fx.root, "x");
    assert!(!target.is_resolved(), "conflicted: {target:?}");
    let adds: Vec<_> = target.present_adds().cloned().collect();
    assert!(adds.contains(&c_id) && adds.contains(&d_id), "{adds:?}");
    assert!(remote(&fx.root, "x", "origin").1);
}

/// `forget` names the matched bookmarks in VIEW order, not argument order.
#[test]
fn forget_describes_several_names_in_view_order() {
    let mut fx = base();
    let b = fx.b.clone();
    fx.set("z", &[&b]);
    fx.set("a", &[&b]);
    fx.repo.bookmark_forget(&names(&["z", "a"]), false).expect("forget");
    assert_eq!(head_op(&fx.root).1, "forget bookmark a, z");
}

/// `remotes` are PATTERNS: `glob:"up*"` picks `upstream` and leaves `origin` alone.
#[test]
fn track_with_a_remote_pattern_touches_only_the_matching_remote() {
    let mut fx = base();
    let d = fx.d.clone();
    fx.set_remote("y", "origin", &d, false);
    fx.set_remote("y", "upstream", &d, false);
    fx.repo
        .bookmark_track(&names(&["y"]), &names(&["glob:\"up*\""]))
        .expect("track");
    assert!(remote(&fx.root, "y", "upstream").1);
    assert!(!remote(&fx.root, "y", "origin").1);
    assert_eq!(head_op(&fx.root).1, "track remote bookmark y@upstream");
}

/// On a NATIVE backend no remote is default-ignored: `forget` untracks a tracked `x@git` and
/// `untrack` of `x@git` untracks it without the Git-tracking warning.
#[test]
fn a_native_backend_ignores_no_remote() {
    test_helpers::pin_test_env();
    let tmp = tempfile::TempDir::new().expect("tempdir");
    let root = Repo::init(&zanshin_jj::InitOptions {
        path: tmp.path().to_owned(),
        ..Default::default()
    })
    .result
    .expect("init")
    .workspace_root()
    .to_owned();
    let at_hex = hex(&root, &wc(&root));
    let mut repo = Repo::open(&root).expect("open");
    test_helpers::set_local_bookmark(&root, "x", &[&at_hex]);
    test_helpers::set_remote_bookmark(&root, "x", "git", &at_hex, true);
    test_helpers::set_remote_bookmark(&root, "y", "git", &at_hex, true);
    repo.bookmark_forget(&names(&["x"]), false).expect("forget");
    assert!(local(&root, "x").is_absent());
    assert_eq!(remote(&root, "x", "git"), (Some(at_hex.clone()), false));

    let _ = repo.take_warnings();
    repo.bookmark_untrack(&names(&["y@git"]), &[]).expect("untrack");
    assert_eq!(remote(&root, "y", "git"), (Some(at_hex), false));
    assert_eq!(head_op(&root).1, "untrack remote bookmark y@git");
    assert!(
        repo.take_warnings()
            .iter()
            .all(|w| w.kind != WarningKind::BookmarkGitTrackingUntrack),
        "no Git-tracking warning on a native backend"
    );
}
