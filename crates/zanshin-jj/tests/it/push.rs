// SPDX-License-Identifier: MIT

//! Story 9.20 witnesses for `Repo::git_push` — `jj git push` at v0.46.0 — against local bare
//! remotes (`git init --bare` / `git clone --bare`), never the network. The remote's refs are
//! read back with `git for-each-ref`. The oracle (`crates/zanshin-parity`) compares the same
//! flows with the stock CLI.

use std::collections::BTreeMap;
use std::fs;
use std::ops::ControlFlow;
use std::path::{Path, PathBuf};
use std::process::Command;

use tempfile::TempDir;
use zanshin_jj::{
    ChangeId, CloneOptions, GitPushArgs, GitPushOutcome, MutateError, ProgressEvent, PushFailureKind, PushPath,
    PushRefKind, PushRefName, PushRefStatus, Repo, WarningKind,
};

/// Runs `git` in `dir`; panics on a non-zero exit. Fixture setup only.
fn git(args: &[&str], dir: &Path) -> String {
    let out = Command::new("git")
        .args(args)
        .current_dir(dir)
        .output()
        .expect("git spawns");
    assert!(
        out.status.success(),
        "git {args:?} failed: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    String::from_utf8_lossy(&out.stdout).trim().to_owned()
}

/// A pushable world: a bare remote cloned from a source with `main` (two commits) and `side`
/// (one more), and a jj workspace cloned from it (not colocated) — `main@origin` tracked, `@` an
/// empty commit on `main`.
struct World {
    _dirs: Vec<TempDir>,
    bare: PathBuf,
    root: PathBuf,
    repo: Repo,
}

fn world() -> World {
    test_helpers::pin_test_env();
    let src = TempDir::new().unwrap();
    git(&["init", "--initial-branch=main"], src.path());
    git(&["config", "user.email", "test@zanshin.test"], src.path());
    git(&["config", "user.name", "Fixture"], src.path());
    fs::write(src.path().join("README.md"), "hello").unwrap();
    git(&["add", "."], src.path());
    git(&["commit", "-m", "initial"], src.path());
    git(&["checkout", "-b", "side"], src.path());
    fs::write(src.path().join("side.txt"), "side").unwrap();
    git(&["add", "."], src.path());
    git(&["commit", "-m", "side"], src.path());
    git(&["checkout", "main"], src.path());
    fs::write(src.path().join("README.md"), "hello again").unwrap();
    git(&["add", "."], src.path());
    git(&["commit", "-m", "second"], src.path());
    let parent = TempDir::new().unwrap();
    let bare = parent.path().join("remote.git");
    git(
        &[
            "clone",
            "--bare",
            &src.path().to_string_lossy(),
            &bare.to_string_lossy(),
        ],
        parent.path(),
    );
    let ws = TempDir::new().unwrap();
    let root = ws.path().join("ws");
    let repo = Repo::clone(
        &CloneOptions {
            source: bare.to_string_lossy().into_owned(),
            destination: root.clone(),
            colocate: Some(false),
            ..Default::default()
        },
        &|_: ProgressEvent| {},
        None,
    )
    .result
    .expect("clone the remote");
    let root = fs::canonicalize(root).unwrap();
    World {
        _dirs: vec![src, parent, ws],
        bare,
        root,
        repo,
    }
}

impl World {
    /// Appends `toml` to the workspace's repo-level config file (the secure one the clone's
    /// presets created) and re-opens the handle.
    fn add_repo_config(&mut self, toml: &str) {
        let id = fs::read_to_string(self.root.join(".jj").join("repo").join("config-id")).expect("config-id");
        let xdg = PathBuf::from(std::env::var_os("XDG_CONFIG_HOME").expect("pinned"));
        let path = xdg.join("jj").join("repos").join(id.trim()).join("config.toml");
        let text = fs::read_to_string(&path).unwrap_or_default();
        fs::write(&path, format!("{text}\n{toml}")).expect("write the repo config");
        self.reopen();
    }

    /// The remote's refs: `refname -> object id`.
    fn remote_refs(&self) -> BTreeMap<String, String> {
        git(&["for-each-ref", "--format=%(refname) %(objectname)"], &self.bare)
            .lines()
            .filter_map(|line| line.split_once(' '))
            .map(|(name, id)| (name.to_owned(), id.to_owned()))
            .collect()
    }

    /// The commit hex of a revset that resolves to one commit.
    fn hex(&mut self, revset: &str) -> String {
        self.change(revset).1
    }

    fn change(&mut self, revset: &str) -> (ChangeId, String) {
        let mut found = Vec::new();
        let _ = self
            .repo
            .eval_revset(revset, |change| {
                found.push((change.id, change.commit_id.0));
                ControlFlow::Continue(())
            })
            .expect("revset");
        assert_eq!(found.len(), 1, "{revset}");
        found.remove(0)
    }

    /// A new commit on `parents` (hex) with `description`.
    fn commit(&mut self, parents: &[&str], file: &str, description: &str) -> String {
        test_helpers::add_commit_with_files(&self.root, parents, &[(file, description)], description)
    }

    /// Re-opens the handle (after a direct jj-lib write).
    fn reopen(&mut self) {
        self.repo = Repo::open(&self.root).expect("reopen");
    }

    /// `@` moved onto a new empty child of `parents`.
    fn new_wc_on(&mut self, parents: &[&str]) {
        let ids: Vec<ChangeId> = parents.iter().map(|hex| self.change(hex).0).collect();
        self.repo.new_change(&ids, &[], &[]).expect("new @");
    }

    fn push(&mut self, args: &GitPushArgs) -> Result<GitPushOutcome, MutateError> {
        self.repo.git_push(args, &|_: ProgressEvent| {}, None)
    }

    fn head_op(&mut self) -> String {
        self.repo.op_log(Some(1)).expect("op log")[0].id.0.clone()
    }

    fn warnings(&mut self) -> Vec<(WarningKind, String)> {
        self.repo
            .take_warnings()
            .into_iter()
            .map(|w| (w.kind, w.message))
            .collect()
    }
}

/// `main` moved onto a new described commit, `@` a child of it.
fn advance_main(w: &mut World) -> String {
    let main = w.hex("main");
    let third = w.commit(&[&main], "third.txt", "third");
    test_helpers::set_local_bookmark(&w.root, "main", &[&third]);
    w.reopen();
    w.new_wc_on(&[&third]);
    third
}

fn short(hex: &str) -> &str {
    &hex[..12]
}

#[test]
fn a_bare_push_moves_a_tracked_bookmark_forward_and_records() {
    let mut w = world();
    let old = w.hex("main@origin");
    let third = advance_main(&mut w);
    let outcome = w.push(&GitPushArgs::default()).expect("push");
    assert!(outcome.failure.is_none(), "{:?}", outcome.failure);
    assert!(outcome.recorded && !outcome.dry_run && !outcome.nothing_changed);
    assert_eq!(
        outcome.description.as_deref(),
        Some("push bookmark main to git remote origin")
    );
    assert_eq!(outcome.remotes.len(), 1);
    let remote = &outcome.remotes[0];
    assert!(remote.finished && remote.error.is_none());
    assert_eq!(remote.refs.len(), 1);
    let row = &remote.refs[0];
    assert_eq!(
        (row.kind, row.name.as_str(), row.path),
        (PushRefKind::Bookmark, "main", PushPath::Push)
    );
    assert_eq!(
        row.action.as_deref(),
        Some(format!("move forward from {} to {}", short(&old), short(&third)).as_str())
    );
    assert_eq!(row.status, Some(PushRefStatus::Pushed));
    assert_eq!(w.remote_refs()["refs/heads/main"], third);
    assert_eq!(w.head_op(), outcome.new_op_id);
    assert_eq!(w.hex("main@origin"), third, "the remote bookmark follows");
}

#[test]
fn nothing_to_push_is_nothing_changed_and_writes_no_operation() {
    let mut w = world();
    let before = w.head_op();
    let outcome = w.push(&GitPushArgs::default()).expect("push");
    assert!(outcome.nothing_changed && !outcome.recorded);
    assert!(outcome.description.is_none() && outcome.failure.is_none());
    assert_eq!(outcome.new_op_id, before);
    assert_eq!(w.head_op(), before);
}

#[test]
fn a_dry_run_plans_what_the_real_push_does() {
    let mut w = world();
    advance_main(&mut w);
    let before_refs = w.remote_refs();
    let plan = w
        .push(&GitPushArgs {
            dry_run: true,
            ..Default::default()
        })
        .expect("dry run");
    let after_plan = w.head_op();
    assert!(plan.dry_run && !plan.recorded && plan.failure.is_none());
    assert_eq!(plan.new_op_id, after_plan, "the dry run writes no operation");
    assert_eq!(w.remote_refs(), before_refs, "nothing was sent");
    let real = w.push(&GitPushArgs::default()).expect("push");
    assert_eq!(real.description, plan.description);
    let names = |o: &GitPushOutcome| {
        o.remotes[0]
            .refs
            .iter()
            .filter(|r| r.path == PushPath::Push)
            .map(|r| r.name.clone())
            .collect::<Vec<_>>()
    };
    assert_eq!(names(&real), names(&plan));
}

/// The bare push skips a bookmark whose commit has no description (warned) and pushes the rest;
/// `-b` on that bookmark refuses the whole push, and its dry run marks the row.
#[test]
fn skip_versus_abort_for_a_commit_without_description() {
    let mut w = world();
    let main = w.hex("main");
    let side = w.hex("side@origin");
    let third = w.commit(&[&main], "third.txt", "third");
    let bad = test_helpers::add_commit_with_files(&w.root, &[&side], &[("bad.txt", "x")], "");
    test_helpers::set_local_bookmark(&w.root, "main", &[&third]);
    test_helpers::set_remote_bookmark(&w.root, "side", "origin", &side, true);
    test_helpers::set_local_bookmark(&w.root, "side", &[&bad]);
    w.reopen();
    w.new_wc_on(&[&third, &bad]);

    let before = w.head_op();
    let err = w
        .push(&GitPushArgs {
            bookmarks: vec!["side".to_owned()],
            ..Default::default()
        })
        .expect_err("an explicit ref with a rejected commit refuses");
    let message = format!("Won't push commit {} since it has no description", short(&bad));
    assert!(
        matches!(&err, MutateError::PushCommitRejected { message: m, .. } if *m == message),
        "{err:?}"
    );
    // Story 9.56: the CLI's "Rejected commit: <summary>" hint (`push.rs:768-773` @ v0.46.0).
    let hints = err.hints();
    assert_eq!(hints.len(), 1, "{hints:?}");
    assert!(
        hints[0].starts_with("Rejected commit: ") && hints[0].contains(&short(&bad)[..8]),
        "{hints:?}"
    );
    assert_eq!(w.head_op(), before, "a refusal before the network writes nothing");
    let plan = w
        .push(&GitPushArgs {
            bookmarks: vec!["side".to_owned()],
            dry_run: true,
            ..Default::default()
        })
        .expect("the dry run plans");
    let failure = plan.failure.expect("the dry run carries the refusal");
    assert_eq!(
        (failure.kind, failure.message.as_str()),
        (PushFailureKind::CommitRejected, message.as_str())
    );
    assert!(failure.hint.expect("hint").starts_with("Rejected commit: "));
    let row = &plan.remotes[0].refs[0];
    assert_eq!((row.name.as_str(), row.path), ("side", PushPath::Abort));
    assert_eq!(
        row.rejection.as_ref().expect("rejection").reasons,
        ["has no description"]
    );
    assert!(
        plan.description.is_none(),
        "every explicit ref aborts: nothing to describe"
    );

    // Two explicit bookmarks, only one commit undescribed: the good row is planned, the bad one
    // aborts, and the description names only the good one.
    let plan = w
        .push(&GitPushArgs {
            bookmarks: vec!["main".to_owned(), "side".to_owned()],
            dry_run: true,
            ..Default::default()
        })
        .expect("the dry run plans");
    let rows: Vec<_> = plan.remotes[0].refs.iter().map(|r| (r.name.as_str(), r.path)).collect();
    assert_eq!(rows, [("main", PushPath::Push), ("side", PushPath::Abort)]);
    let side_row = &plan.remotes[0].refs[1];
    assert_eq!(
        side_row.rejection.as_ref().map(|r| r.message.as_str()),
        Some(message.as_str())
    );
    assert_eq!(
        plan.failure.as_ref().map(|f| f.kind),
        Some(PushFailureKind::CommitRejected)
    );
    assert_eq!(
        plan.description.as_deref(),
        Some("push bookmark main to git remote origin")
    );

    w.take_and_ignore_warnings();
    let outcome = w.push(&GitPushArgs::default()).expect("the bare push skips");
    assert!(outcome.recorded && outcome.failure.is_none());
    let rows: Vec<_> = outcome.remotes[0]
        .refs
        .iter()
        .map(|r| (r.name.as_str(), r.path))
        .collect();
    assert_eq!(rows, [("main", PushPath::Push), ("side", PushPath::Skip)]);
    assert!(w.warnings().contains(&(
        WarningKind::PushCommitSkipped,
        format!("Won't push bookmark side: commit {} has no description", short(&bad))
    )));
    assert_eq!(w.remote_refs()["refs/heads/main"], third);
    assert_eq!(w.remote_refs()["refs/heads/side"], side, "the skipped ref was not sent");
}

impl World {
    fn take_and_ignore_warnings(&mut self) {
        let _ = self.repo.take_warnings();
    }
}

/// The refusal table: a conflicted local bookmark, a non-tracking remote bookmark, a new one, a
/// deleted one — warned and skipped by the modes that skip, refused for `-b`.
#[test]
fn refused_refs_carry_the_cli_message_and_hint() {
    let mut w = world();
    let main = w.hex("main");
    let side = w.hex("side@origin");
    let a = w.commit(&[&main], "a.txt", "a");
    let b = w.commit(&[&main], "b.txt", "b");
    test_helpers::set_local_bookmark(&w.root, "main", &[&a, &b]);
    test_helpers::set_local_bookmark(&w.root, "side", &[&a]);
    test_helpers::set_local_bookmark(&w.root, "fresh", &[&b]);
    w.reopen();
    w.new_wc_on(&[&a, &b]);

    let err = w
        .push(&GitPushArgs {
            bookmarks: vec!["main".to_owned()],
            ..Default::default()
        })
        .expect_err("a conflicted explicit bookmark refuses");
    assert!(
        matches!(&err, MutateError::PushRefRefused { message, .. } if message == "Bookmark main is conflicted"),
        "{err:?}"
    );
    // Story 9.56: the refusal's hint (`push.rs:1148-1153` @ v0.46.0).
    assert_eq!(
        err.hints(),
        ["Run `jj bookmark list` to inspect, and use `jj bookmark set` to fix it up."]
    );
    let plan = w
        .push(&GitPushArgs {
            all: true,
            dry_run: true,
            ..Default::default()
        })
        .expect("--all plans");
    let row = |name: &str| {
        plan.remotes[0]
            .refs
            .iter()
            .find(|r| r.name == name)
            .unwrap_or_else(|| panic!("{name}"))
            .clone()
    };
    let main_row = row("main");
    assert_eq!(main_row.path, PushPath::Skip);
    let refusal = main_row.refusal.expect("refused");
    assert_eq!(refusal.message, "Bookmark main is conflicted");
    assert_eq!(
        refusal.hint.as_deref(),
        Some("Run `jj bookmark list` to inspect, and use `jj bookmark set` to fix it up.")
    );
    let side_row = row("side");
    assert_eq!(side_row.path, PushPath::Skip);
    assert_eq!(
        side_row.refusal.as_ref().map(|r| r.message.as_str()),
        Some("Non-tracking remote bookmark side@origin exists")
    );
    assert_eq!(
        side_row.refusal.clone().and_then(|r| r.hint).as_deref(),
        Some("Run `jj bookmark track side@origin` to import the remote bookmark.")
    );
    assert_eq!(
        side_row.explicit_refusal, side_row.refusal,
        "-b would refuse it with the same CLI text"
    );
    assert_eq!(
        main_row.explicit_refusal.map(|r| r.message).as_deref(),
        Some("Bookmark main is conflicted")
    );
    let fresh_row = row("fresh");
    assert_eq!(fresh_row.path, PushPath::Push, "--all allows new bookmarks");
    assert_eq!(fresh_row.action, Some(format!("add to {}", short(&b))));
    assert!(
        fresh_row.explicit_refusal.is_none(),
        "an untracked name may be pushed with -b"
    );

    let outcome = w.push(&GitPushArgs::default()).expect("the bare push");
    assert!(outcome.nothing_changed, "every candidate is refused");
    let fresh = outcome.remotes[0]
        .refs
        .iter()
        .find(|r| r.name == "fresh")
        .expect("fresh is in the default revset");
    assert_eq!(fresh.path, PushPath::Skip);
    let refusal = fresh.refusal.as_ref().expect("the bare push refuses a new bookmark");
    assert_eq!(refusal.message, "Refusing to create new remote bookmark fresh@origin");
    assert_eq!(
        refusal.hint.as_deref(),
        Some("Run `jj bookmark track fresh@origin` and try again.")
    );
    assert!(fresh.explicit_refusal.is_none(), "and -b would push it");
    let refused = w
        .warnings()
        .into_iter()
        .filter(|(kind, _)| *kind == WarningKind::PushRefSkipped)
        .count();
    assert_eq!(refused, 3, "main, side and fresh are warned");
    let _ = side;
}

/// `--tracked` without `--deleted` refuses a deleted bookmark; `--deleted` deletes it on the
/// remote.
#[test]
fn deleted_bookmarks_need_the_deleted_flag() {
    let mut w = world();
    let side = w.hex("side@origin");
    test_helpers::set_remote_bookmark(&w.root, "side", "origin", &side, true);
    w.reopen();
    let plan = w
        .push(&GitPushArgs {
            tracked: true,
            dry_run: true,
            ..Default::default()
        })
        .expect("--tracked plans");
    let row = &plan.remotes[0].refs[0];
    assert_eq!((row.name.as_str(), row.path), ("side", PushPath::Skip));
    let refusal = row.refusal.as_ref().expect("refused");
    assert_eq!(refusal.message, "Refusing to push deleted bookmark side");
    assert_eq!(
        refusal.hint.as_deref(),
        Some("Push deleted bookmarks with --deleted or forget the bookmark to suppress this warning.")
    );
    assert_eq!(row.action, Some(format!("delete from {}", short(&side))));
    assert!(
        plan.nothing_changed && plan.description.is_none(),
        "nothing left to push"
    );

    let outcome = w
        .push(&GitPushArgs {
            deleted: true,
            ..Default::default()
        })
        .expect("--deleted pushes");
    assert!(outcome.recorded);
    assert_eq!(
        outcome.description.as_deref(),
        Some("push all deleted bookmarks/tags to git remote origin")
    );
    assert!(!w.remote_refs().contains_key("refs/heads/side"));
}

/// `-c @-` creates `push-<12 change hex>`, pushes and tracks it; `--named` names it.
#[test]
fn change_and_named_create_their_bookmarks() {
    let mut w = world();
    let main = w.hex("main");
    let third = w.commit(&[&main], "third.txt", "third");
    w.reopen();
    w.new_wc_on(&[&third]);
    let (change, _) = w.change(&third);
    let name = format!("push-{}", &change.0[..12]);
    let outcome = w
        .push(&GitPushArgs {
            changes: vec!["@-".to_owned()],
            ..Default::default()
        })
        .expect("-c pushes");
    assert_eq!(outcome.created_bookmarks.len(), 1);
    assert_eq!(outcome.created_bookmarks[0].name, name);
    assert_eq!(
        outcome.description,
        Some(format!("push bookmark {name} to git remote origin"))
    );
    assert_eq!(w.remote_refs()[&format!("refs/heads/{name}")], third);

    let again = w
        .push(&GitPushArgs {
            changes: vec!["@-".to_owned()],
            ..Default::default()
        })
        .expect("the existing bookmark at that commit is allowed");
    assert!(again.nothing_changed);
    assert!(again.created_bookmarks.is_empty());

    let outcome = w
        .push(&GitPushArgs {
            named: vec!["feat=@-".to_owned()],
            ..Default::default()
        })
        .expect("--named pushes");
    assert_eq!(
        outcome.description.as_deref(),
        Some("push bookmark feat to git remote origin")
    );
    assert_eq!(w.remote_refs()["refs/heads/feat"], third);
    for (argument, expected) in [
        (
            "nope",
            "Argument 'nope' must include '=' and have the form NAME=REVISION",
        ),
        (
            "=@",
            "Argument '=@' must have the form NAME=REVISION, with both NAME and REVISION non-empty",
        ),
    ] {
        let err = w
            .push(&GitPushArgs {
                named: vec![argument.to_owned()],
                ..Default::default()
            })
            .expect_err("a malformed --named refuses");
        assert!(
            matches!(&err, MutateError::InvalidInput { reason, .. } if reason == expected),
            "{err:?}"
        );
        // Story 9.56: `parse_named_bookmark`'s hint (`push.rs:1278-1297` @ v0.46.0).
        assert_eq!(err.hints(), ["For example, `--named myfeature=@` is valid syntax"]);
    }
    let err = w
        .push(&GitPushArgs {
            named: vec!["feat=@-".to_owned()],
            ..Default::default()
        })
        .expect_err("an existing name refuses");
    assert!(
        matches!(&err, MutateError::BookmarkExists { name, .. } if name == "feat"),
        "{err:?}"
    );
    // Story 9.56: `ensure_new_bookmark_name`'s hint (`push.rs:1260-1262` @ v0.46.0).
    assert_eq!(
        err.hints(),
        ["Use 'jj bookmark move' to move it, and 'jj git push -b feat' to push it"]
    );

    // Deleted locally while `feat@origin` stays tracked: the tracked-remote refusal and its hint
    // (`push.rs:1264-1272` @ v0.46.0).
    w.repo
        .bookmark_delete(&["feat".to_owned()])
        .expect("delete the local bookmark");
    let err = w
        .push(&GitPushArgs {
            named: vec!["feat=@-".to_owned()],
            ..Default::default()
        })
        .expect_err("a tracked remote bookmark refuses");
    assert!(
        matches!(&err, MutateError::BookmarkTrackedRemoteExists { name } if name == "feat"),
        "{err:?}"
    );
    assert_eq!(
        err.hints(),
        ["Use `jj bookmark set` to recreate the local bookmark. Run `jj bookmark untrack feat` to disassociate them."]
    );
}

/// The remotes: an unmatched `--remote` name warns, no match at all refuses, the only remote not
/// named `origin` gets the CLI's hint.
#[test]
fn remotes_resolve_like_the_cli() {
    let mut w = world();
    advance_main(&mut w);
    let err = w
        .push(&GitPushArgs {
            remotes: Some(vec!["nope".to_owned()]),
            ..Default::default()
        })
        .expect_err("no matching remote");
    assert!(
        matches!(&err, MutateError::InvalidInput { reason, .. } if reason == "No git remotes to push to"),
        "{err:?}"
    );
    assert!(w.warnings().contains(&(
        WarningKind::PushRemotesUnmatched,
        "No matching remotes for names: nope".to_owned()
    )));
    let outcome = w
        .push(&GitPushArgs {
            remotes: Some(vec!["nope".to_owned(), "origin".to_owned()]),
            dry_run: true,
            ..Default::default()
        })
        .expect("origin matches");
    assert_eq!(outcome.remotes.len(), 1);
    assert!(w
        .warnings()
        .iter()
        .any(|(kind, _)| *kind == WarningKind::PushRemotesUnmatched));

    let err = w
        .push(&GitPushArgs {
            all: true,
            bookmarks: vec!["main".to_owned()],
            ..Default::default()
        })
        .expect_err("conflicting flags");
    assert!(matches!(err, MutateError::InvalidInput { .. }), "{err:?}");
}

/// A remote moved under us: the lease fails, nothing is exported, nothing recorded, and the
/// CLI's "Failed to push some bookmarks".
#[test]
fn a_lease_failure_records_nothing() {
    let mut w = world();
    advance_main(&mut w);
    let other = TempDir::new().unwrap();
    git(
        &["clone", &w.bare.to_string_lossy(), &other.path().to_string_lossy()],
        other.path().parent().unwrap(),
    );
    git(&["config", "user.email", "x@zanshin.test"], other.path());
    git(&["config", "user.name", "X"], other.path());
    fs::write(other.path().join("moved.txt"), "moved").unwrap();
    git(&["add", "."], other.path());
    git(&["commit", "-m", "moved"], other.path());
    git(&["push", "origin", "main"], other.path());

    let before = w.head_op();
    let outcome = w.push(&GitPushArgs::default()).expect("the outcome is data");
    assert!(!outcome.recorded);
    let failure = outcome.failure.expect("failed");
    assert_eq!(
        (failure.kind, failure.message.as_str()),
        (PushFailureKind::SomeRefsFailed, "Failed to push some bookmarks")
    );
    assert_eq!(outcome.remotes[0].refs[0].status, Some(PushRefStatus::LeaseRejected));
    assert!(outcome
        .hints
        .iter()
        .any(|hint| hint.starts_with("Try fetching from the remote")));
    assert!(w
        .warnings()
        .iter()
        .any(|(kind, _)| *kind == WarningKind::PushRefsMovedOnRemote));
    assert_eq!(w.head_op(), before);
}

/// Two remotes, the second unreachable: the first is pushed and finished, the second reports the
/// git error, nothing is recorded.
#[test]
fn a_second_unreachable_remote_stops_the_push() {
    let mut w = world();
    let third = advance_main(&mut w);
    let missing = w.bare.with_file_name("missing.git");
    w.repo
        .git_remote_add("zz", &missing.to_string_lossy(), None)
        .expect("add a remote");
    let old = w.hex("main@origin");
    test_helpers::set_remote_bookmark(&w.root, "main", "zz", &old, true);
    w.reopen();
    let before = w.head_op();
    let outcome = w
        .push(&GitPushArgs {
            remotes: Some(vec!["origin".to_owned(), "zz".to_owned()]),
            ..Default::default()
        })
        .expect("the outcome is data");
    assert!(!outcome.recorded);
    assert_eq!(
        outcome.failure.as_ref().map(|f| f.kind),
        Some(PushFailureKind::PushError)
    );
    assert!(outcome.remotes[0].finished);
    assert_eq!(outcome.remotes[0].refs[0].status, Some(PushRefStatus::Pushed));
    assert!(!outcome.remotes[1].finished && outcome.remotes[1].error.is_some());
    assert_eq!(
        w.remote_refs()["refs/heads/main"],
        third,
        "the first remote has the ref"
    );
    assert_eq!(w.head_op(), before, "nothing recorded");
    assert_eq!(
        outcome.description.as_deref(),
        Some("push bookmark main to git remotes origin, zz")
    );
}

/// A remote whose `pre-receive` hook declines: the remote's rejection with its hint.
#[test]
fn a_remote_rejection_is_reported_per_ref() {
    let mut w = world();
    advance_main(&mut w);
    let hook = w.bare.join("hooks").join("pre-receive");
    fs::write(&hook, "#!/bin/sh\nexit 1\n").unwrap();
    let mut permissions = fs::metadata(&hook).unwrap().permissions();
    std::os::unix::fs::PermissionsExt::set_mode(&mut permissions, 0o755);
    fs::set_permissions(&hook, permissions).unwrap();
    let outcome = w.push(&GitPushArgs::default()).expect("the outcome is data");
    assert_eq!(outcome.remotes[0].refs[0].status, Some(PushRefStatus::RemoteRejected));
    assert_eq!(outcome.failure.map(|f| f.kind), Some(PushFailureKind::SomeRefsFailed));
    assert!(outcome
        .hints
        .contains(&"Try checking if you have permission to push to all the bookmarks.".to_owned()));
    assert!(w
        .warnings()
        .iter()
        .any(|(kind, _)| *kind == WarningKind::PushRemoteRejected));
}

/// Tags: a tag in the bare push's revset is new on the remote and refused; `-t` pushes it.
#[test]
fn tags_are_planned_and_pushed() {
    let mut w = world();
    let third = advance_main(&mut w);
    test_helpers::set_tag(&w.root, "v2", &[&third]);
    w.reopen();
    let plan = w
        .push(&GitPushArgs {
            dry_run: true,
            ..Default::default()
        })
        .expect("plan");
    let tag = plan.remotes[0]
        .refs
        .iter()
        .find(|r| r.kind == PushRefKind::Tag)
        .expect("the tag is a candidate");
    assert_eq!(tag.path, PushPath::Skip);
    assert_eq!(
        tag.refusal.as_ref().map(|r| r.message.as_str()),
        Some("Refusing to create new remote tag v2@origin")
    );
    let outcome = w
        .push(&GitPushArgs {
            tags: vec!["v2".to_owned()],
            ..Default::default()
        })
        .expect("-t pushes");
    assert_eq!(outcome.description.as_deref(), Some("push tag v2 to git remote origin"));
    assert_eq!(w.remote_refs()["refs/tags/v2"], third);
}

/// `-r` with a revision no ref points to warns; an unmatched exact `-b` warns.
#[test]
fn explicit_targets_that_match_nothing_warn() {
    let mut w = world();
    let outcome = w
        .push(&GitPushArgs {
            revisions: vec!["root()".to_owned()],
            bookmarks: vec!["nope".to_owned()],
            ..Default::default()
        })
        .expect("nothing to push");
    assert!(outcome.nothing_changed);
    let kinds: Vec<WarningKind> = w.warnings().into_iter().map(|(kind, _)| kind).collect();
    assert!(kinds.contains(&WarningKind::PushBookmarksUnmatched));
    assert!(kinds.contains(&WarningKind::PushRevisionsEmpty));
}

/// A customised `templates.git_push_bookmark` names the `-c` bookmark (Story 9.51): the dry run
/// plans it under the rendered name, and the push creates and pushes that bookmark.
#[test]
fn a_customised_push_bookmark_template_names_the_change_bookmark() {
    let mut w = world();
    w.add_repo_config("[templates]\ngit_push_bookmark = '\"mine-\" ++ change_id.short()'\n");
    let (change, commit) = w.change("@-");
    let name = format!("mine-{}", &change.0[..12]);
    let args = GitPushArgs {
        changes: vec!["@-".to_owned()],
        ..Default::default()
    };
    let plan = w
        .push(&GitPushArgs {
            dry_run: true,
            ..args.clone()
        })
        .expect("dry run");
    assert_eq!(plan.created_bookmarks.len(), 1);
    assert_eq!(plan.created_bookmarks[0].name, name);
    let outcome = w.push(&args).expect("push");
    assert_eq!(outcome.created_bookmarks[0].name, name);
    assert_eq!(w.remote_refs()[&format!("refs/heads/{name}")], commit);
}

/// A `templates.git_push_bookmark` that renders nothing refuses `-c` with the CLI's text, before
/// anything is written (Story 9.51).
#[test]
fn an_empty_push_bookmark_name_refuses() {
    let mut w = world();
    w.add_repo_config("[templates]\ngit_push_bookmark = '\"\"'\n");
    let before = w.head_op();
    let err = w
        .push(&GitPushArgs {
            changes: vec!["@-".to_owned()],
            ..Default::default()
        })
        .expect_err("refused");
    assert!(
        matches!(&err, MutateError::Config { reason } if reason == "Empty bookmark name generated"),
        "{err:?}"
    );
    assert_eq!(w.head_op(), before);
}

/// Sign-on-push with jj-lib's `test` signing backend (the CLI's own test signer): the commits to
/// push are signed before the push and the counts reported.
#[test]
fn sign_on_push_signs_the_commits_to_push() {
    let mut w = world();
    w.add_repo_config("[git]\nsign-on-push = true\n\n[signing]\nbackend = \"test\"\n");
    let third = advance_main(&mut w);
    let outcome = w.push(&GitPushArgs::default()).expect("push");
    let signing = outcome.signing.expect("signed");
    assert_eq!(signing.updated_signatures, 1);
    assert_eq!(signing.rebased_descendants, 1, "@ is rebased onto the signed commit");
    let pushed = w.remote_refs()["refs/heads/main"].clone();
    assert_ne!(pushed, third, "the signed commit is pushed");
    let mut signed = false;
    let _ = w
        .repo
        .eval_revset(&pushed, |change| {
            signed = change.is_signed;
            ControlFlow::Break(())
        })
        .expect("revset");
    assert!(signed);
}

/// A new commit on `parent` whose author has neither name nor email — written through jj-lib,
/// since every Zanshin verb stamps the configured identity.
fn commit_without_author(root: &Path, parent: &str) -> String {
    let settings = test_helpers::test_settings();
    let workspace = jj_lib::workspace::Workspace::load(
        &settings,
        root,
        &jj_lib::default_backend_factories::default_backend_factories(),
        &jj_lib::default_backend_factories::default_working_copy_factories(),
    )
    .expect("load");
    let repo = pollster::block_on(workspace.repo_loader().load_at_head()).expect("head");
    let parent = jj_lib::backend::CommitId::try_from_hex(parent).expect("hex");
    let tree = jj_lib::repo::Repo::store(repo.as_ref())
        .get_commit(&parent)
        .expect("parent")
        .tree();
    let mut tx = repo.start_transaction();
    let builder = tx.repo_mut().new_commit(vec![parent], tree);
    let timestamp = builder.author().timestamp;
    let commit = pollster::block_on(
        builder
            .set_author(jj_lib::backend::Signature {
                name: String::new(),
                email: String::new(),
                timestamp,
            })
            .set_description("no author")
            .write(),
    )
    .expect("write");
    pollster::block_on(tx.commit("test: commit without author")).expect("commit");
    jj_lib::object_id::ObjectId::hex(commit.id())
}

/// The commit checks and their overrides: a conflicted commit (`--allow-conflicts`), an
/// undescribed one (`--allow-empty-description`), a commit without author (never overridable).
#[test]
fn commit_checks_have_their_overrides() {
    let mut w = world();
    let main = w.hex("main");
    let conflicted = test_helpers::add_conflicted_merge_off_root(&w.root);
    let undescribed = w.commit(&[&main], "u.txt", "");
    let no_author = commit_without_author(&w.root, &main);
    test_helpers::set_local_bookmark(&w.root, "conf", &[&conflicted]);
    test_helpers::set_local_bookmark(&w.root, "undesc", &[&undescribed]);
    test_helpers::set_local_bookmark(&w.root, "anon", &[&no_author]);
    w.reopen();
    let only = |name: &str| GitPushArgs {
        bookmarks: vec![name.to_owned()],
        ..Default::default()
    };
    let rejected = |err: &MutateError| match err {
        MutateError::PushCommitRejected { message, .. } => message.clone(),
        other => panic!("{other:?}"),
    };

    let err = w.push(&only("conf")).expect_err("a conflicted commit is rejected");
    assert!(rejected(&err).ends_with("since it has conflicts"), "{err:?}");
    let outcome = w
        .push(&GitPushArgs {
            allow_conflicts: true,
            ..only("conf")
        })
        .expect("--allow-conflicts pushes it");
    assert!(outcome.recorded && outcome.failure.is_none());
    assert_eq!(w.remote_refs()["refs/heads/conf"], conflicted);

    let err = w.push(&only("undesc")).expect_err("an undescribed commit is rejected");
    assert_eq!(
        rejected(&err),
        format!("Won't push commit {} since it has no description", short(&undescribed))
    );
    w.push(&GitPushArgs {
        allow_empty_description: true,
        ..only("undesc")
    })
    .expect("--allow-empty-description pushes it");
    assert_eq!(w.remote_refs()["refs/heads/undesc"], undescribed);

    let err = w
        .push(&GitPushArgs {
            allow_empty_description: true,
            allow_private: true,
            allow_conflicts: true,
            ..only("anon")
        })
        .expect_err("no flag overrides a missing author");
    assert_eq!(
        rejected(&err),
        format!(
            "Won't push commit {} since it has no author and/or committer set",
            short(&no_author)
        )
    );
    assert!(!w.remote_refs().contains_key("refs/heads/anon"));
}

/// `git.private-commits`: a private commit is rejected with the CLI's reason and hint (after the
/// "Rejected commit" one); `--allow-private` pushes it.
#[test]
fn private_commits_are_rejected_unless_allowed() {
    let mut w = world();
    let main = w.hex("main");
    let wip = w.commit(&[&main], "wip.txt", "wip: not yet");
    test_helpers::set_local_bookmark(&w.root, "main", &[&wip]);
    w.add_repo_config("[git]\nprivate-commits = \"description(glob:'wip*')\"\n");
    w.new_wc_on(&[&wip]);
    let message = format!("Won't push commit {} since it is private", short(&wip));
    let main_only = GitPushArgs {
        bookmarks: vec!["main".to_owned()],
        ..Default::default()
    };
    let err = w.push(&main_only).expect_err("a private commit is rejected");
    assert!(
        matches!(&err, MutateError::PushCommitRejected { message: m, .. } if *m == message),
        "{err:?}"
    );
    let plan = w
        .push(&GitPushArgs {
            dry_run: true,
            ..main_only.clone()
        })
        .expect("the dry run plans");
    let rejection = plan.remotes[0].refs[0].rejection.clone().expect("rejected");
    assert_eq!(rejection.reasons, ["is private"]);
    let hint = "Configured git.private-commits: 'description(glob:'wip*')'";
    assert_eq!(rejection.hints.last().map(String::as_str), Some(hint));
    let failure_hint = plan.failure.and_then(|f| f.hint).expect("hint");
    let lines: Vec<&str> = failure_hint.lines().collect();
    assert!(lines[0].starts_with("Rejected commit: "), "{failure_hint}");
    assert_eq!(lines[1..], [hint], "every hint of the rejection is kept");

    let outcome = w
        .push(&GitPushArgs {
            allow_private: true,
            ..main_only
        })
        .expect("--allow-private pushes it");
    assert!(outcome.recorded);
    assert_eq!(w.remote_refs()["refs/heads/main"], wip);
}

/// A second remote `up`: a clone of the bare remote, with `main@up` tracked where `main@origin`
/// is.
fn add_second_remote(w: &mut World) -> PathBuf {
    let up = w.bare.with_file_name("up.git");
    git(
        &["clone", "--bare", &w.bare.to_string_lossy(), &up.to_string_lossy()],
        w.bare.parent().unwrap(),
    );
    w.repo
        .git_remote_add("up", &up.to_string_lossy(), None)
        .expect("add a remote");
    let old = w.hex("main@origin");
    test_helpers::set_remote_bookmark(&w.root, "main", "up", &old, true);
    w.reopen();
    up
}

/// `git.push` as a string picks the remote of a bare push.
#[test]
fn git_push_config_as_a_string_selects_the_remote() {
    let mut w = world();
    let up = add_second_remote(&mut w);
    w.add_repo_config("[git]\npush = \"up\"\n");
    let third = advance_main(&mut w);
    let outcome = w.push(&GitPushArgs::default()).expect("push");
    let names: Vec<&str> = outcome.remotes.iter().map(|r| r.name.as_str()).collect();
    assert_eq!(names, ["up"]);
    assert_eq!(
        outcome.description.as_deref(),
        Some("push bookmark main to git remote up")
    );
    assert_eq!(
        git(&["rev-parse", "refs/heads/main"], &up),
        third,
        "the configured remote got the ref"
    );
    assert_ne!(w.remote_refs()["refs/heads/main"], third, "origin did not");
}

/// `git.push` as a list picks every remote it names, in sorted order.
#[test]
fn git_push_config_as_a_list_selects_the_remotes() {
    let mut w = world();
    add_second_remote(&mut w);
    w.add_repo_config("[git]\npush = [\"up\", \"origin\"]\n");
    advance_main(&mut w);
    let plan = w
        .push(&GitPushArgs {
            dry_run: true,
            ..Default::default()
        })
        .expect("plan");
    let names: Vec<&str> = plan.remotes.iter().map(|r| r.name.as_str()).collect();
    assert_eq!(names, ["origin", "up"]);
    assert_eq!(
        plan.description.as_deref(),
        Some("push bookmark main to git remotes origin, up")
    );
}

/// The only remote, not named `origin`, is pushed to with the CLI's hint.
#[test]
fn the_only_remote_not_named_origin_gets_the_hint() {
    let mut w = world();
    w.repo.git_remote_rename("origin", "up").expect("rename");
    let third = advance_main(&mut w);
    let outcome = w.push(&GitPushArgs::default()).expect("push");
    assert_eq!(outcome.hints, ["Pushing to the only existing remote: up".to_owned()]);
    assert_eq!(outcome.remotes[0].name, "up");
    assert_eq!(w.remote_refs()["refs/heads/main"], third);
}

/// A custom `revsets.git-push` decides which refs a bare push plans.
#[test]
fn a_custom_git_push_revset_changes_the_planned_refs() {
    let mut w = world();
    let side = w.hex("side@origin");
    let next = w.commit(&[&side], "next.txt", "next");
    test_helpers::set_remote_bookmark(&w.root, "side", "origin", &side, true);
    test_helpers::set_local_bookmark(&w.root, "side", &[&next]);
    w.reopen();
    advance_main(&mut w);
    let names = |w: &mut World| {
        let plan = w
            .push(&GitPushArgs {
                dry_run: true,
                ..Default::default()
            })
            .expect("plan");
        plan.remotes[0].refs.iter().map(|r| r.name.clone()).collect::<Vec<_>>()
    };
    assert_eq!(names(&mut w), ["main"], "the default revset follows @");
    w.add_repo_config("[revsets]\ngit-push = \"side\"\n");
    assert_eq!(names(&mut w), ["side"], "the configured revset");
}

/// A second `-b main` after `main` was pushed: the CLI's "already matches" fact, nothing changed.
#[test]
fn an_explicit_bookmark_already_on_the_remote_already_matches() {
    let mut w = world();
    advance_main(&mut w);
    let main_only = GitPushArgs {
        bookmarks: vec!["main".to_owned()],
        ..Default::default()
    };
    w.push(&main_only).expect("first push");
    let again = w.push(&main_only).expect("second push");
    assert!(again.nothing_changed);
    assert_eq!(
        again.remotes[0].already_matches,
        [PushRefName {
            kind: PushRefKind::Bookmark,
            name: "main".to_owned()
        }]
    );
}

/// One ref pushed and exported, another lease-rejected: the operation is recorded (the CLI's
/// record rule) with its description, and the failure is still "Failed to push some bookmarks".
#[test]
fn a_partial_success_with_an_export_records() {
    let mut w = world();
    let side = w.hex("side@origin");
    let next = w.commit(&[&side], "next.txt", "next");
    test_helpers::set_remote_bookmark(&w.root, "side", "origin", &side, true);
    test_helpers::set_local_bookmark(&w.root, "side", &[&next]);
    w.reopen();
    let main = w.hex("main");
    let third = w.commit(&[&main], "third.txt", "third");
    test_helpers::set_local_bookmark(&w.root, "main", &[&third]);
    w.reopen();
    w.new_wc_on(&[&third, &next]);
    let other = TempDir::new().unwrap();
    git(
        &["clone", &w.bare.to_string_lossy(), &other.path().to_string_lossy()],
        other.path().parent().unwrap(),
    );
    git(&["config", "user.email", "x@zanshin.test"], other.path());
    git(&["config", "user.name", "X"], other.path());
    git(&["checkout", "side"], other.path());
    fs::write(other.path().join("moved.txt"), "moved").unwrap();
    git(&["add", "."], other.path());
    git(&["commit", "-m", "moved"], other.path());
    git(&["push", "origin", "side"], other.path());

    let before = w.head_op();
    let outcome = w.push(&GitPushArgs::default()).expect("the outcome is data");
    assert!(outcome.recorded, "main was exported");
    assert_eq!(
        outcome.failure.as_ref().map(|f| (f.kind, f.message.as_str())),
        Some((PushFailureKind::SomeRefsFailed, "Failed to push some bookmarks"))
    );
    let statuses: Vec<_> = outcome.remotes[0]
        .refs
        .iter()
        .map(|r| (r.name.as_str(), r.status))
        .collect();
    assert_eq!(
        statuses,
        [
            ("main", Some(PushRefStatus::Pushed)),
            ("side", Some(PushRefStatus::LeaseRejected))
        ]
    );
    assert_ne!(outcome.new_op_id, before);
    assert_eq!(w.head_op(), outcome.new_op_id);
    let description = w.repo.op_log(Some(1)).expect("op log")[0].description.clone();
    assert_eq!(description, "push bookmarks main, side to git remote origin");
    assert_eq!(outcome.description.as_deref(), Some(description.as_str()));
    assert_eq!(w.remote_refs()["refs/heads/main"], third);
}

/// Sign-on-push skips an immutable commit to push with the CLI's warning and its commit list —
/// each line `templates.commit_summary` rendered, the default's and a custom one's.
#[test]
fn sign_on_push_lists_the_immutable_commits_it_skips() {
    for summary in ["", "[templates]\ncommit_summary = 'commit_id.short() ++ \" custom\"'\n"] {
        let mut w = world();
        w.add_repo_config(&format!(
            "[git]\nsign-on-push = true\n\n[signing]\nbackend = \"test\"\n\n{summary}"
        ));
        let third = advance_main(&mut w);
        // A tag makes `third` immutable (`builtin_immutable_heads()` holds `tags()`).
        test_helpers::set_tag(&w.root, "v2", &[&third]);
        w.reopen();
        let outcome = w.push(&GitPushArgs::default()).expect("push");
        assert!(outcome.signing.is_none(), "nothing mutable needed a signature");
        let warning = w
            .warnings()
            .into_iter()
            .find(|(kind, _)| *kind == WarningKind::PushSigningSkippedImmutable)
            .map(|(_, message)| message)
            .expect("warned");
        let lines: Vec<&str> = warning.lines().collect();
        assert_eq!(lines[0], "Skipped signing 1 immutable commits:");
        assert_eq!(lines.len(), 2, "{warning}");
        if summary.is_empty() {
            assert!(
                lines[1].starts_with("  ") && lines[1].contains(&third[..8]) && lines[1].ends_with(" main* | third"),
                "{warning}"
            );
        } else {
            assert_eq!(lines[1], format!("  {} custom", short(&third)), "{warning}");
        }
        assert_eq!(w.remote_refs()["refs/heads/main"], third, "pushed unsigned");
    }
}

/// `templates.commit_summary` renders the "Rejected commit:" hint of `-c @` on an undescribed `@`,
/// in the refusal and in the dry run's failure and row (the CLI's `write_commit_summary`).
#[test]
fn the_rejected_commit_hint_renders_the_commit_summary_template() {
    let mut w = world();
    w.add_repo_config("[templates]\ncommit_summary = 'commit_id.short() ++ \" custom\"'\n");
    let at = w.hex("@");
    let hint = format!("Rejected commit: {} custom", short(&at));
    let change = GitPushArgs {
        changes: vec!["@".to_owned()],
        ..Default::default()
    };
    let before = w.head_op();
    let err = w.push(&change).expect_err("an undescribed @ is rejected");
    assert_eq!(err.hints(), std::slice::from_ref(&hint));
    assert_eq!(w.head_op(), before, "a refusal before the network writes nothing");
    let plan = w
        .push(&GitPushArgs {
            dry_run: true,
            ..change
        })
        .expect("the dry run plans");
    assert_eq!(plan.failure.and_then(|f| f.hint), Some(hint.clone()));
    let row = &plan.remotes[0].refs[0];
    assert_eq!(row.rejection.as_ref().expect("rejected").hints, [hint]);
}

/// An unparsable `templates.commit_summary` refuses a push whose rejection hint would render it —
/// real run and dry run alike — as `Config`, writing nothing (the CLI refuses such a template at
/// start-up).
#[test]
fn a_broken_commit_summary_template_refuses_the_push() {
    let mut w = world();
    w.add_repo_config("[templates]\ncommit_summary = 'nope('\n");
    let before = w.head_op();
    for dry_run in [false, true] {
        let err = w
            .push(&GitPushArgs {
                changes: vec!["@".to_owned()],
                dry_run,
                ..Default::default()
            })
            .expect_err("the summary template does not parse");
        assert!(
            matches!(&err, MutateError::Config { reason } if reason.starts_with("Failed to parse template: ")),
            "dry run {dry_run}: {err:?}"
        );
        assert_eq!(w.head_op(), before, "dry run {dry_run}: nothing written");
    }
}
