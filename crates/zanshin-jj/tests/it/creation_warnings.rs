// SPDX-License-Identifier: MIT

//! Story 9.33 witnesses: the creation paths — `Repo::init`, `Repo::clone`, `convert_colocated`,
//! `convert_import` — report what the jj CLI @ v0.44.0 prints on the same flows, in its order,
//! on success AND on failure, plus the conversion's snapshot report. Story 9.34 adds the
//! conversions' config read points: the start-up environment before the snapshot, the snapshot
//! knobs inside it.
//!
//! # Why one test in its own process
//!
//! The identity rows need `JJ_USER` / `JJ_EMAIL` REMOVED (an empty identity), the others need
//! them set, the refs-step failure and the Story 9.34 rows need a user config file and the
//! late-failure row a broken `XDG_CONFIG_HOME`. All of these are process-global, so — the
//! `tests/it/config_identity.rs` idiom — this file holds exactly ONE `#[test]` that walks the I/O
//! matrix in sequence, changing the environment between phases. `JJ_CONFIG` is `""` except for the phases that
//! repoint it at a file of their own — never unset: that would re-enable discovery of the
//! developer's real config — and `XDG_CONFIG_HOME` points into a temp dir, so the secure repo
//! config root is ours.
//!
//! The FFI rows (`open`) live in `crates/zanshin-ffi/tests/it/repo_ffi.rs`; the clone clean-up
//! failure is pinned inline in `src/creation.rs` (a `.jj/` that cannot be removed). Story 9.20
//! re-derives the clone rows for the CLI's three operations and its non-empty refusal.

use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

use tempfile::TempDir;
use zanshin_jj::{
    convert_colocated, convert_import, Backend, CreationOutcome, Repo, RepoError, SnapshotStats, UntrackedPath,
    UntrackedReason, WarningKind,
};

/// Sets (or, for `None`, removes) one process environment variable.
fn set_env(name: &str, value: Option<&str>) {
    // SAFETY: single-threaded — this test runs alone in its own process (`own_process!`), and every change
    // happens between the calls that read the environment.
    unsafe {
        match value {
            Some(v) => env::set_var(name, v),
            None => env::remove_var(name),
        }
    }
}

/// Run a git command in `dir`; panics on non-zero exit. Fixture setup only.
fn git(args: &[&str], dir: &Path) {
    let status = Command::new("git")
        .args(args)
        .current_dir(dir)
        .status()
        .expect("git command failed to spawn");
    assert!(status.success(), "git {args:?} failed in {}", dir.display());
}

/// A plain git repo at `dir` with one commit on `main` holding `README.md` = `hello`.
fn git_with_commit(dir: &Path) {
    git(&["init", "--initial-branch=main"], dir);
    git(&["config", "user.email", "test@zanshin.test"], dir);
    git(&["config", "user.name", "Fixture"], dir);
    fs::write(dir.join("README.md"), "hello").expect("write README");
    git(&["add", "."], dir);
    git(&["commit", "-m", "initial"], dir);
}

fn file_url(dir: &Path) -> String {
    format!("file://{}", dir.display())
}

/// Story 9.57: a failed colocated conversion leaves its `.jj/` as the CLI leaves it (`do_init`
/// propagates every error with `?`), `.git/` untouched, and reports the canonical `.jj/` as left
/// behind.
fn assert_left_jj(left_behind: &[PathBuf], root: &Path) {
    assert!(
        root.join(".jj").is_dir(),
        "the failed conversion leaves its .jj/, as the CLI"
    );
    assert!(root.join(".git").is_dir(), ".git/ is never touched");
    let root = root.canonicalize().unwrap();
    assert_eq!(left_behind, [root.join(".jj")]);
}

/// The outcome's warnings as `(kind, message)` pairs, in order.
fn warnings(outcome: &CreationOutcome) -> Vec<(WarningKind, &str)> {
    outcome.warnings.iter().map(|w| (w.kind, w.message.as_str())).collect()
}

/// The CLI's identity warning for a fully empty identity (`cli_util.rs:2397-2401`).
const IDENTITY: &str = "Name and email not configured. Until configured, your commits will be created with the \
                        empty identity, and can't be pushed to remotes.";

/// `print_failed_git_import` for the reserved ref the rows below plant.
const STOLEN: &str = "Failed to import some Git refs:\n  refs/remotes/git/stolen";

/// The CLI's prefix of an unresolvable `immutable_heads()` (`cli_util.rs:1146-1167` @ v0.46.0;
/// Story 9.58) — and of an unparseable one (`cli_util.rs:1106-1117`; Story 9.58 closing run).
const IMMUTABLE_HEADS_INVALID: &str = "Invalid `revset-aliases.immutable_heads()`: ";

/// A 2 MiB file — twice the builtin `snapshot.max-new-file-size` (1 MiB).
const BIG: usize = 2 * 1024 * 1024;

/// `print_untracked_files` for [`BIG`] bytes at `big.bin` under the builtin limit.
const REFUSED: &str = "Refused to snapshot some files:\n  big.bin: 2.0MiB (2097152 bytes); \
                       the maximum size allowed is 1.0MiB (1048576 bytes)";

/// `print_checkout_stats` for one file the checkout left alone (`cli_util.rs:3304-3309`).
const SKIPPED: &str = "1 of those updates were skipped because there were conflicting changes in the working copy.";

/// The colocated snapshot's `.jjconflict` warning (`cli_util.rs:2206-2210`).
const JJCONFLICT: &str = "The working copy contains '.jjconflict' files. These files are used by `jj` internally \
                          and should not be present in the working copy.";

#[test]
fn creation_paths_report_what_the_cli_prints() {
    test_helpers::own_process!("creation_paths_report_what_the_cli_prints");
    let tmp = TempDir::new().unwrap();
    let xdg = tmp.path().join("xdg");
    fs::create_dir_all(&xdg).unwrap();
    set_env("XDG_CONFIG_HOME", Some(xdg.to_str().unwrap()));
    set_env("JJ_CONFIG", Some(""));
    set_env("GIT_CONFIG_GLOBAL", Some(""));
    set_env("JJ_OP_HOSTNAME", Some("localhost"));
    set_env("JJ_OP_USERNAME", Some("zanshin"));

    // ── An EMPTY identity ─────────────────────────────────────────────────────────
    set_env("JJ_USER", None);
    set_env("JJ_EMAIL", None);
    init_reports_nothing();
    clone_warns_an_empty_identity_per_finish();
    clone_of_an_empty_source_warns_the_identity_once();
    convert_import_warns_an_empty_identity_once();
    convert_colocated_does_not_warn_an_empty_identity();
    convert_import_warns_refusal_then_checkout_skip_then_identity();

    // ── A configured identity ─────────────────────────────────────────────────────
    set_env("JJ_USER", Some("Zanshin"));
    set_env("JJ_EMAIL", Some("zanshin@localhost"));
    clone_with_an_identity_reports_nothing();
    clone_into_a_non_empty_destination_is_refused();
    a_big_new_file_is_refused_and_reported();
    a_reserved_ref_warns_in_the_refs_step_and_again_in_the_snapshot();
    a_refs_step_that_imports_nothing_still_warns();
    a_refs_step_export_failure_warns_first(tmp.path());
    a_bad_alias_entry_warns_between_the_two_imports(tmp.path());
    a_jjconflict_entry_is_reported_by_the_colocated_conversion();
    a_snapshot_failure_keeps_a_partial_report();
    a_refs_step_failure_reports_no_snapshot(tmp.path());
    a_wrong_typed_snapshot_knob_fails_inside_the_conversion_snapshot(tmp.path());
    a_bad_immutable_heads_alias_fails_before_the_conversion_snapshot(tmp.path());
    a_bad_immutable_heads_alias_fails_a_new_colocated_init_after_its_jj(tmp.path());
    a_failed_colocated_init_into_an_existing_dir_names_its_git(tmp.path());
    an_unresolvable_immutable_heads_alias_refuses_the_import_at_its_head_finish(tmp.path());
    an_unresolvable_immutable_heads_alias_does_not_refuse_a_colocated_conversion(tmp.path());
    an_unresolvable_immutable_heads_alias_refuses_a_clone_into_a_new_destination(tmp.path());
    an_unresolvable_immutable_heads_alias_refuses_a_colocated_clone_into_an_empty_directory(tmp.path());
    a_wrong_typed_snapshot_knob_fails_inside_the_import_snapshot(tmp.path());
    a_late_failure_keeps_the_report(tmp.path(), &xdg);
    a_clone_failing_after_the_fetch_keeps_the_workspace(tmp.path(), &xdg);
}

/// Init: the CLI's empty-directory `jj git init` finishes no transaction — no warning, not even
/// with an empty identity, and no snapshot report.
fn init_reports_nothing() {
    for backend in [Some(Backend::Git), None] {
        let dir = TempDir::new().unwrap();
        let outcome = Repo::init(&zanshin_jj::InitOptions {
            path: std::path::PathBuf::from(dir.path()),
            backend,
            colocate: backend.map(|_| false),
            ..Default::default()
        });
        assert!(outcome.result.is_ok(), "{:?}", outcome.result);
        assert!(outcome.warnings.is_empty(), "{:?}", outcome.warnings);
        assert!(outcome.precondition.is_none());
    }
}

/// Clone with an empty identity: one `jj.identity_missing` per finished transaction — `add git
/// remote origin`, `fetch from git remote into empty repo`, `check out git remote's branch: main`
/// (`clone.rs:352`, `:457`, `:314` @ v0.46.0; Story 9.20's op split).
fn clone_warns_an_empty_identity_per_finish() {
    let src = TempDir::new().unwrap();
    git_with_commit(src.path());
    let dst = TempDir::new().unwrap();
    let outcome = Repo::clone(
        &zanshin_jj::CloneOptions {
            source: file_url(src.path()),
            destination: dst.path().to_owned(),
            colocate: Some(false),
            ..Default::default()
        },
        &|_: zanshin_jj::ProgressEvent| {},
        None,
    );
    assert!(outcome.result.is_ok(), "{:?}", outcome.result);
    assert_eq!(
        warnings(&outcome),
        [
            (WarningKind::IdentityMissing, IDENTITY),
            (WarningKind::IdentityMissing, IDENTITY),
            (WarningKind::IdentityMissing, IDENTITY)
        ]
    );
    assert!(outcome.precondition.is_none(), "a clone runs no snapshot");
}

/// A source without commits: the fetch and the checkout change nothing and finish nothing, so
/// only the `add git remote` finish warns the empty identity.
fn clone_of_an_empty_source_warns_the_identity_once() {
    let src = TempDir::new().unwrap();
    git(&["init", "--initial-branch=main"], src.path());
    let dst = TempDir::new().unwrap();
    let outcome = Repo::clone(
        &zanshin_jj::CloneOptions {
            source: file_url(src.path()),
            destination: dst.path().to_owned(),
            colocate: Some(false),
            ..Default::default()
        },
        &|_: zanshin_jj::ProgressEvent| {},
        None,
    );
    assert!(outcome.result.is_ok(), "{:?}", outcome.result);
    assert_eq!(warnings(&outcome), [(WarningKind::IdentityMissing, IDENTITY)]);
}

/// The non-colocated conversion finishes its `import git head` (`init.rs:268`): ONE identity
/// warning. The refs step before it commits raw and warns nothing.
fn convert_import_warns_an_empty_identity_once() {
    let src = TempDir::new().unwrap();
    git_with_commit(src.path());
    let parent = TempDir::new().unwrap();
    let dst = parent.path().join("dst");
    let outcome = convert_import(src.path(), &dst);
    assert!(outcome.result.is_ok(), "{:?}", outcome.result);
    assert_eq!(warnings(&outcome), [(WarningKind::IdentityMissing, IDENTITY)]);
    let precondition = outcome.precondition.expect("the conversion's snapshot ran");
    assert!(
        !precondition.was_snapshot_taken,
        "an empty destination snapshots nothing"
    );
}

/// The colocated conversion commits its head import through `maybe_commit_transaction`, not a
/// finish, and a repo whose refs do not move again finishes nothing: no identity warning.
fn convert_colocated_does_not_warn_an_empty_identity() {
    let dir = TempDir::new().unwrap();
    git_with_commit(dir.path());
    let outcome = convert_colocated(dir.path());
    assert!(outcome.result.is_ok(), "{:?}", outcome.result);
    assert!(outcome.warnings.is_empty(), "{:?}", outcome.warnings);
    let precondition = outcome.precondition.expect("the conversion's snapshot ran");
    assert!(precondition.git_head_imported);
    assert!(precondition.was_snapshot_taken);
}

/// `convert_import` from a source whose HEAD holds a [`BIG`] `big.bin` into an EXISTING
/// destination that already holds its own untracked one, with an empty identity: the
/// destination's snapshot refuses it (`cli_util.rs:1340`), then the head import's finish leaves
/// it alone (`print_checkout_stats`) and warns the identity (`git/init.rs:268`) — in that order.
fn convert_import_warns_refusal_then_checkout_skip_then_identity() {
    let src = TempDir::new().unwrap();
    git_with_commit(src.path());
    fs::write(src.path().join("big.bin"), vec![b'b'; BIG]).unwrap();
    git(&["add", "big.bin"], src.path());
    git(&["commit", "-m", "big"], src.path());
    let dst = TempDir::new().unwrap();
    fs::write(dst.path().join("big.bin"), vec![b'a'; BIG]).unwrap();
    let outcome = convert_import(src.path(), dst.path());
    assert!(outcome.result.is_ok(), "{:?}", outcome.result);
    assert_eq!(
        warnings(&outcome),
        [
            (WarningKind::SnapshotFilesRefused, REFUSED),
            (WarningKind::CheckoutFilesSkipped, SKIPPED),
            (WarningKind::IdentityMissing, IDENTITY)
        ]
    );
    assert_eq!(
        fs::read(dst.path().join("big.bin")).unwrap(),
        vec![b'a'; BIG],
        "the checkout leaves the untracked file alone"
    );
}

fn clone_with_an_identity_reports_nothing() {
    let src = TempDir::new().unwrap();
    git_with_commit(src.path());
    let dst = TempDir::new().unwrap();
    let outcome = Repo::clone(
        &zanshin_jj::CloneOptions {
            source: String::from(&file_url(src.path())),
            destination: std::path::PathBuf::from(dst.path()),
            colocate: Some(false),
            ..Default::default()
        },
        &|_: zanshin_jj::ProgressEvent| {},
        None,
    );
    assert!(outcome.result.is_ok(), "{:?}", outcome.result);
    assert!(outcome.warnings.is_empty(), "{:?}", outcome.warnings);
    assert!(outcome.precondition.is_none());
}

/// A clone into a destination that already holds a file is refused before anything is created
/// (`clone.rs:187-192` @ v0.46.0; Story 9.20): no warning, the file untouched, no `.jj`.
fn clone_into_a_non_empty_destination_is_refused() {
    let src = TempDir::new().unwrap();
    git_with_commit(src.path());
    let dst = TempDir::new().unwrap();
    fs::write(dst.path().join("README.md"), "local").unwrap();
    let outcome = Repo::clone(
        &zanshin_jj::CloneOptions {
            source: file_url(src.path()),
            destination: dst.path().to_owned(),
            colocate: Some(false),
            ..Default::default()
        },
        &|_: zanshin_jj::ProgressEvent| {},
        None,
    );
    assert!(
        matches!(outcome.result, Err(RepoError::DestinationNotEmpty { .. })),
        "{:?}",
        outcome.result
    );
    assert!(outcome.warnings.is_empty(), "{:?}", outcome.warnings);
    assert_eq!(fs::read_to_string(dst.path().join("README.md")).unwrap(), "local");
    assert!(!dst.path().join(".jj").exists());
}

/// A clone whose repo presets cannot be written (`<xdg>/jj` is a FILE, so no repo config file
/// can be created) fails AFTER the clean-up scope: the workspace stays (`clone.rs:287-301`).
fn a_clone_failing_after_the_fetch_keeps_the_workspace(tmp: &Path, xdg: &Path) {
    let src = TempDir::new().unwrap();
    git_with_commit(src.path());
    let parent = TempDir::new().unwrap();
    let dst = parent.path().join("dst");
    let broken = tmp.join("broken-xdg-clone");
    fs::create_dir_all(&broken).unwrap();
    fs::write(broken.join("jj"), "not a directory").unwrap();
    set_env("XDG_CONFIG_HOME", Some(broken.to_str().unwrap()));
    let outcome = Repo::clone(
        &zanshin_jj::CloneOptions {
            source: file_url(src.path()),
            destination: dst.clone(),
            colocate: Some(false),
            ..Default::default()
        },
        &|_: zanshin_jj::ProgressEvent| {},
        None,
    );
    set_env("XDG_CONFIG_HOME", Some(xdg.to_str().unwrap()));
    assert!(
        matches!(outcome.result, Err(RepoError::Config { .. })),
        "{:?}",
        outcome.result
    );
    assert!(
        dst.join(".jj").is_dir(),
        "a failure after the fetch keeps the workspace"
    );
    assert!(outcome.warnings.is_empty(), "{:?}", outcome.warnings);
}

/// A new file over `snapshot.max-new-file-size` stays untracked: the conversion's snapshot
/// report names it and the snapshot stats warn — colocated, and importing into an EXISTING
/// destination that holds it.
fn a_big_new_file_is_refused_and_reported() {
    let expected_stats = SnapshotStats {
        untracked: vec![UntrackedPath {
            path: "big.bin".to_owned(),
            reason: UntrackedReason::FileTooLarge {
                size: BIG as u64,
                max_size: 1024 * 1024,
            },
        }],
        invalid_utf8_paths: Vec::new(),
    };

    let colocated = TempDir::new().unwrap();
    git_with_commit(colocated.path());
    fs::write(colocated.path().join("big.bin"), vec![b'a'; BIG]).unwrap();
    let outcome = convert_colocated(colocated.path());
    assert!(outcome.result.is_ok(), "{:?}", outcome.result);
    assert_eq!(warnings(&outcome), [(WarningKind::SnapshotFilesRefused, REFUSED)]);
    assert_eq!(
        outcome.precondition.expect("snapshot ran").snapshot_stats,
        expected_stats
    );

    let src = TempDir::new().unwrap();
    git_with_commit(src.path());
    let dst = TempDir::new().unwrap();
    fs::write(dst.path().join("big.bin"), vec![b'a'; BIG]).unwrap();
    let outcome = convert_import(src.path(), dst.path());
    assert!(outcome.result.is_ok(), "{:?}", outcome.result);
    assert_eq!(warnings(&outcome), [(WarningKind::SnapshotFilesRefused, REFUSED)]);
    assert_eq!(
        outcome.precondition.expect("snapshot ran").snapshot_stats,
        expected_stats
    );
}

/// A ref in the reserved `refs/remotes/git/` namespace fails BOTH imports the CLI runs — the
/// refs step (`init.rs:304`) and the snapshot's own (`cli_util.rs:1440`) — and each warns.
fn a_reserved_ref_warns_in_the_refs_step_and_again_in_the_snapshot() {
    let dir = TempDir::new().unwrap();
    git_with_commit(dir.path());
    git(&["update-ref", "refs/remotes/git/stolen", "HEAD"], dir.path());
    let outcome = convert_colocated(dir.path());
    assert!(outcome.result.is_ok(), "{:?}", outcome.result);
    assert_eq!(
        warnings(&outcome),
        [
            (WarningKind::GitImportFailed, STOLEN),
            (WarningKind::GitImportFailed, STOLEN)
        ]
    );
    let refs = outcome
        .precondition
        .expect("snapshot ran")
        .git_refs
        .expect("the colocated refs import ran");
    assert_eq!(refs.failed_ref_names, ["refs/remotes/git/stolen"]);
}

/// A colocated repo whose ONLY ref is the reserved `refs/remotes/git/stolen` (its branch deleted,
/// HEAD unborn): the refs step imports nothing and writes no operation, yet warns BEFORE its
/// early return (`git/init.rs:304`); the snapshot's own refs import warns again.
fn a_refs_step_that_imports_nothing_still_warns() {
    let dir = TempDir::new().unwrap();
    git_with_commit(dir.path());
    git(&["update-ref", "refs/remotes/git/stolen", "HEAD"], dir.path());
    git(&["update-ref", "-d", "refs/heads/main"], dir.path());
    let outcome = convert_colocated(dir.path());
    assert!(outcome.result.is_ok(), "{:?}", outcome.result);
    assert_eq!(
        warnings(&outcome),
        [
            (WarningKind::GitImportFailed, STOLEN),
            (WarningKind::GitImportFailed, STOLEN)
        ]
    );
}

/// `remotes.origin.auto-track-bookmarks` makes the refs step create a local `foo/bar` from
/// `foo/bar@origin`; its colocated export cannot write `refs/heads/foo/bar` beside
/// `refs/heads/foo` (a Git file/directory conflict), so the refs step warns
/// `jj.git_export_failed` (`git/init.rs:311-312`) — the conversion's first warning.
fn a_refs_step_export_failure_warns_first(tmp: &Path) {
    let user = tmp.join("auto-track.toml");
    fs::write(&user, "[remotes.origin]\nauto-track-bookmarks = \"glob:*\"\n").unwrap();
    set_env("JJ_CONFIG", Some(user.to_str().unwrap()));
    let dir = TempDir::new().unwrap();
    git_with_commit(dir.path());
    git(&["update-ref", "refs/heads/foo", "HEAD"], dir.path());
    git(&["update-ref", "refs/remotes/origin/foo/bar", "HEAD"], dir.path());
    let outcome = convert_colocated(dir.path());
    set_env("JJ_CONFIG", Some(""));

    assert!(outcome.result.is_ok(), "{:?}", outcome.result);
    let kinds: Vec<WarningKind> = outcome.warnings.iter().map(|w| w.kind).collect();
    assert_eq!(kinds, [WarningKind::GitExportFailed], "{:?}", outcome.warnings);
    assert!(
        outcome.warnings[0]
            .message
            .starts_with("Failed to export some bookmarks:\n  foo/bar"),
        "{:?}",
        outcome.warnings[0].message
    );
}

/// A bad `[revset-aliases]` entry: the conversion loads the alias tables where the CLI's
/// `for_workable_repo` does — AFTER the refs step (`git/init.rs:251-254`), BEFORE the snapshot —
/// so its warning sits between the two reports of an unreadable ref.
fn a_bad_alias_entry_warns_between_the_two_imports(tmp: &Path) {
    let user = tmp.join("bad-alias.toml");
    fs::write(&user, "[revset-aliases]\n'bad(' = 'x'\n").unwrap();
    set_env("JJ_CONFIG", Some(user.to_str().unwrap()));
    let dir = TempDir::new().unwrap();
    git_with_commit(dir.path());
    git(&["update-ref", "refs/remotes/git/stolen", "HEAD"], dir.path());
    let outcome = convert_colocated(dir.path());
    set_env("JJ_CONFIG", Some(""));

    assert!(outcome.result.is_ok(), "{:?}", outcome.result);
    let kinds: Vec<WarningKind> = outcome.warnings.iter().map(|w| w.kind).collect();
    assert_eq!(
        kinds,
        [
            WarningKind::GitImportFailed,
            WarningKind::ConfigAliasInvalid,
            WarningKind::GitImportFailed
        ]
    );
    assert!(
        outcome.warnings[1]
            .message
            .starts_with("Failed to load `revset-aliases.bad(`:"),
        "{:?}",
        outcome.warnings[1].message
    );
}

/// A `.jjconflict`-prefixed entry in the colocated work tree: the conversion's snapshot records
/// it and warns, as every colocated precondition does.
fn a_jjconflict_entry_is_reported_by_the_colocated_conversion() {
    let dir = TempDir::new().unwrap();
    git_with_commit(dir.path());
    fs::write(
        dir.path().join(".jjconflict-base-0"),
        "left behind by a plain git checkout\n",
    )
    .unwrap();
    let outcome = convert_colocated(dir.path());
    assert!(outcome.result.is_ok(), "{:?}", outcome.result);
    assert_eq!(warnings(&outcome), [(WarningKind::JjconflictFilesPresent, JJCONFLICT)]);
}

/// A conversion whose own snapshot fails — a new file it cannot open (mode `0o000`): the error
/// keeps the refs step's warning and the PARTIAL snapshot report (the head import ran before the
/// snapshot failed, and the snapshot's refs import never ran), and — as the CLI's `do_init`, which
/// propagates the snapshot error with `?` (`git/init.rs` @ v0.46.0) — the `.jj/` stays and is
/// reported as left behind (Story 9.57).
fn a_snapshot_failure_keeps_a_partial_report() {
    use std::os::unix::fs::PermissionsExt as _;

    let dir = TempDir::new().unwrap();
    git_with_commit(dir.path());
    git(&["update-ref", "refs/remotes/git/stolen", "HEAD"], dir.path());
    let locked = dir.path().join("locked.txt");
    fs::write(&locked, "unreadable").unwrap();
    fs::set_permissions(&locked, fs::Permissions::from_mode(0o000)).unwrap();
    let outcome = convert_colocated(dir.path());
    fs::set_permissions(&locked, fs::Permissions::from_mode(0o644)).unwrap();

    assert!(
        matches!(outcome.result, Err(RepoError::ConvertFailed { .. })),
        "{:?}",
        outcome.result
    );
    assert_left_jj(&outcome.left_behind, dir.path());
    assert_eq!(warnings(&outcome), [(WarningKind::GitImportFailed, STOLEN)]);
    let precondition = outcome.precondition.expect("the snapshot started");
    assert!(
        precondition.git_head_imported,
        "the head import ran before the snapshot failed"
    );
    assert!(precondition.was_snapshot_taken, "the head import moved the head");
}

/// A conversion whose `import git refs` step cannot read its import options (the CLI's
/// `load_git_import_options` in `init_git_refs`, `git/init.rs:300`) fails BEFORE the snapshot
/// starts: no snapshot report, nothing warned, `.jj/` left as the CLI leaves it (Story 9.57).
fn a_refs_step_failure_reports_no_snapshot(tmp: &Path) {
    let user = tmp.join("bad-auto-track.toml");
    fs::write(&user, "[remotes.origin]\nauto-track-bookmarks = \"glob:(\"\n").unwrap();
    set_env("JJ_CONFIG", Some(user.to_str().unwrap()));
    let dir = TempDir::new().unwrap();
    git_with_commit(dir.path());
    let outcome = convert_colocated(dir.path());
    set_env("JJ_CONFIG", Some(""));

    let Err(RepoError::Config { reason }) = &outcome.result else {
        panic!(
            "an unparseable auto-track-bookmarks fails the refs step: {:?}",
            outcome.result
        );
    };
    assert!(
        reason.contains("Invalid `remotes.origin.auto-track-bookmarks`"),
        "{reason}"
    );
    assert!(outcome.precondition.is_none(), "the snapshot never started");
    assert!(outcome.warnings.is_empty(), "{:?}", outcome.warnings);
    assert_left_jj(&outcome.left_behind, dir.path());
}

/// Story 9.34: the conversion reads its snapshot knobs where the CLI does — inside
/// `maybe_snapshot`'s snapshot step (`cli_util.rs:2065-2070`), after the colocated
/// `import git head` — so a wrong-typed `snapshot.max-new-file-size` fails with the PARTIAL
/// snapshot report naming that operation, and `.jj/` stays as the CLI leaves it (Story 9.57).
fn a_wrong_typed_snapshot_knob_fails_inside_the_conversion_snapshot(tmp: &Path) {
    let user = tmp.join("bad-size.toml");
    fs::write(&user, "snapshot.max-new-file-size = true\n").unwrap();
    set_env("JJ_CONFIG", Some(user.to_str().unwrap()));
    let dir = TempDir::new().unwrap();
    git_with_commit(dir.path());
    let outcome = convert_colocated(dir.path());
    set_env("JJ_CONFIG", Some(""));

    let Err(RepoError::Config { reason }) = &outcome.result else {
        panic!("a wrong-typed size knob fails the snapshot step: {:?}", outcome.result);
    };
    assert!(reason.contains("snapshot.max-new-file-size"), "{reason}");
    let precondition = outcome.precondition.expect("the snapshot started");
    assert!(
        precondition.git_head_imported,
        "the head import ran before the knob was read"
    );
    assert!(precondition.was_snapshot_taken, "the head import moved the head");
    assert!(precondition.git_refs.is_none(), "the snapshot's refs import never ran");
    assert!(outcome.warnings.is_empty(), "{:?}", outcome.warnings);
    assert_left_jj(&outcome.left_behind, dir.path());
}

/// Story 9.34: the conversion's start-up environment stays at the CLI's `for_workable_repo`
/// point (`git/init.rs:252`), BEFORE `maybe_snapshot`: a bad `immutable_heads()` alias fails with
/// no snapshot report, and `.jj/` stays as the CLI leaves it (Story 9.57).
fn a_bad_immutable_heads_alias_fails_before_the_conversion_snapshot(tmp: &Path) {
    let user = tmp.join("bad-immutable.toml");
    fs::write(&user, "[revset-aliases]\n'immutable_heads()' = 'bogus_function()'\n").unwrap();
    set_env("JJ_CONFIG", Some(user.to_str().unwrap()));
    let dir = TempDir::new().unwrap();
    git_with_commit(dir.path());
    let outcome = convert_colocated(dir.path());
    set_env("JJ_CONFIG", Some(""));

    let Err(RepoError::Config { reason }) = &outcome.result else {
        panic!(
            "a bad immutable_heads() alias fails the start-up environment: {:?}",
            outcome.result
        );
    };
    assert!(reason.starts_with(IMMUTABLE_HEADS_INVALID), "{reason}");
    assert!(reason.contains("bogus_function"), "{reason}");
    assert!(outcome.precondition.is_none(), "the snapshot never started");
    assert_left_jj(&outcome.left_behind, dir.path());
}

/// Story 9.58: a new colocated init builds its start-up environment after `init_colocated_git`
/// (`git/init.rs` @ v0.46.0, `for_workable_repo`), so a bad `immutable_heads()` alias refuses with
/// the destination the init created, its `.jj/` and the `.git/` jj-lib created left — all named,
/// canonical, outermost first.
fn a_bad_immutable_heads_alias_fails_a_new_colocated_init_after_its_jj(tmp: &Path) {
    let user = tmp.join("bad-immutable-init.toml");
    fs::write(&user, "[revset-aliases]\n'immutable_heads()' = 'bogus_function()'\n").unwrap();
    set_env("JJ_CONFIG", Some(user.to_str().unwrap()));
    let parent = TempDir::new().unwrap();
    let dst = parent.path().join("new-colocated");
    let outcome = Repo::init(&zanshin_jj::InitOptions {
        path: dst.clone(),
        backend: Some(Backend::Git),
        colocate: Some(true),
        ..Default::default()
    });
    set_env("JJ_CONFIG", Some(""));

    let Err(RepoError::Config { reason }) = &outcome.result else {
        panic!("{:?}", outcome.result);
    };
    assert!(reason.starts_with(IMMUTABLE_HEADS_INVALID), "{reason}");
    assert!(reason.contains("bogus_function"), "{reason}");
    assert!(dst.join(".jj").is_dir(), "the .jj/ stays, as the CLI leaves it");
    let canonical = dst.canonicalize().unwrap();
    assert_eq!(
        outcome.left_behind,
        [canonical.clone(), canonical.join(".jj"), canonical.join(".git")]
    );
}

/// A new colocated init into an EXISTING empty directory that fails late names the `.jj/` and the
/// `.git/` it created, not the directory (the user's); jj-lib's cleanup removes neither.
fn a_failed_colocated_init_into_an_existing_dir_names_its_git(tmp: &Path) {
    let user = tmp.join("bad-immutable-init-existing.toml");
    fs::write(&user, "[revset-aliases]\n'immutable_heads()' = 'bogus_function()'\n").unwrap();
    set_env("JJ_CONFIG", Some(user.to_str().unwrap()));
    let dst = TempDir::new().unwrap();
    let outcome = Repo::init(&zanshin_jj::InitOptions {
        path: dst.path().to_owned(),
        backend: Some(Backend::Git),
        colocate: Some(true),
        ..Default::default()
    });
    set_env("JJ_CONFIG", Some(""));

    assert!(
        matches!(outcome.result, Err(RepoError::Config { .. })),
        "{:?}",
        outcome.result
    );
    let canonical = dst.path().canonicalize().unwrap();
    assert_eq!(outcome.left_behind, [canonical.join(".jj"), canonical.join(".git")]);
}

/// Story 9.57: an `immutable_heads()` alias that PARSES but does not resolve passes the start-up
/// environment and the snapshot; the non-colocated `import git head` finish then resolves the
/// immutable set, as the CLI's `tx.finish` does (`cli_util.rs:2849-2866`, `:2986-3002` @ v0.46.0),
/// and refuses with the CLI's config error — after `.jj/` exists, with the ops `add workspace` and
/// `import git refs` written, the destination and its `.jj/` left behind.
fn an_unresolvable_immutable_heads_alias_refuses_the_import_at_its_head_finish(tmp: &Path) {
    let user = tmp.join("unresolvable-immutable-import.toml");
    fs::write(
        &user,
        "[revset-aliases]\n'immutable_heads()' = 'nonexistent_symbol_xyz'\n",
    )
    .unwrap();
    set_env("JJ_CONFIG", Some(user.to_str().unwrap()));
    let src = TempDir::new().unwrap();
    git_with_commit(src.path());
    let parent = TempDir::new().unwrap();
    let dst = parent.path().join("dst");
    let outcome = convert_import(src.path(), &dst);
    set_env("JJ_CONFIG", Some(""));

    let Err(RepoError::Config { reason }) = &outcome.result else {
        panic!(
            "an unresolvable immutable_heads() refuses the head finish: {:?}",
            outcome.result
        );
    };
    assert!(reason.starts_with(IMMUTABLE_HEADS_INVALID), "{reason}");
    assert!(reason.contains("nonexistent_symbol_xyz"), "{reason}");
    assert!(
        dst.join(".jj").is_dir(),
        "the refusal comes after .jj/ exists, as in the CLI"
    );
    let canonical = dst.canonicalize().unwrap();
    assert_eq!(outcome.left_behind, [canonical.clone(), canonical.join(".jj")]);
    let mut repo = Repo::open(&dst).expect("the left-behind workspace opens");
    let ops: Vec<String> = repo
        .op_log(None)
        .unwrap()
        .into_iter()
        .map(|op| op.description)
        .collect();
    assert_eq!(ops[..2], ["import git refs", "add workspace 'default'"], "{ops:?}");
}

/// Story 9.57: the colocated conversion runs no `tx.finish` (its head import is the snapshot's
/// own commit), so the same unresolvable alias does not refuse it — as `jj git init --colocate`.
fn an_unresolvable_immutable_heads_alias_does_not_refuse_a_colocated_conversion(tmp: &Path) {
    let user = tmp.join("unresolvable-immutable-colocated.toml");
    fs::write(
        &user,
        "[revset-aliases]\n'immutable_heads()' = 'nonexistent_symbol_xyz'\n",
    )
    .unwrap();
    set_env("JJ_CONFIG", Some(user.to_str().unwrap()));
    let dir = TempDir::new().unwrap();
    git_with_commit(dir.path());
    let outcome = convert_colocated(dir.path());
    set_env("JJ_CONFIG", Some(""));

    assert!(outcome.result.is_ok(), "{:?}", outcome.result);
    assert!(outcome.left_behind.is_empty(), "{:?}", outcome.left_behind);
}

/// Points `JJ_CONFIG` at a user config whose `immutable_heads()` parses but does not resolve,
/// clones a one-commit Git source into `destination` and restores `JJ_CONFIG` to `""`.
fn clone_with_an_unresolvable_immutable_heads_alias(
    tmp: &Path,
    file: &str,
    destination: &Path,
    colocate: Option<bool>,
) -> CreationOutcome {
    let user = tmp.join(file);
    fs::write(
        &user,
        "[revset-aliases]\n'immutable_heads()' = 'nonexistent_symbol_xyz'\n",
    )
    .unwrap();
    set_env("JJ_CONFIG", Some(user.to_str().unwrap()));
    let src = TempDir::new().unwrap();
    git_with_commit(src.path());
    let outcome = Repo::clone(
        &zanshin_jj::CloneOptions {
            source: file_url(src.path()),
            destination: destination.to_owned(),
            colocate,
            ..Default::default()
        },
        &|_: zanshin_jj::ProgressEvent| {},
        None,
    );
    set_env("JJ_CONFIG", Some(""));
    outcome
}

/// The clone's refusal for [`clone_with_an_unresolvable_immutable_heads_alias`]: the CLI's config
/// error naming the symbol, nothing left behind and no warning.
fn assert_clone_refused_by_the_alias(outcome: &CreationOutcome) {
    let Err(RepoError::Config { reason }) = &outcome.result else {
        panic!(
            "an unresolvable immutable_heads() refuses the clone's first finish: {:?}",
            outcome.result
        );
    };
    assert!(reason.starts_with(IMMUTABLE_HEADS_INVALID), "{reason}");
    assert!(reason.contains("nonexistent_symbol_xyz"), "{reason}");
    assert!(outcome.left_behind.is_empty(), "{:?}", outcome.left_behind);
    assert!(outcome.warnings.is_empty(), "{:?}", outcome.warnings);
}

/// Story 9.57 closing run: the clone's first finish with changes (`add git remote origin`)
/// resolves the immutable set as the CLI's `tx.finish` does (`cli_util.rs:2986-3002` @ v0.46.0)
/// and refuses with its config error inside the clean-up scope (`clone.rs:262-284`): the
/// destination the clone created is removed.
fn an_unresolvable_immutable_heads_alias_refuses_a_clone_into_a_new_destination(tmp: &Path) {
    let parent = TempDir::new().unwrap();
    let dst = parent.path().join("dst");
    let outcome =
        clone_with_an_unresolvable_immutable_heads_alias(tmp, "unresolvable-immutable-clone.toml", &dst, Some(false));

    assert_clone_refused_by_the_alias(&outcome);
    assert!(!dst.exists(), "the clean-up removes the destination the clone created");
}

/// The same refusal for a colocated clone into an existing empty directory: the clean-up removes
/// `.jj` and `.git` and keeps the directory, empty.
fn an_unresolvable_immutable_heads_alias_refuses_a_colocated_clone_into_an_empty_directory(tmp: &Path) {
    let dst = TempDir::new().unwrap();
    let outcome = clone_with_an_unresolvable_immutable_heads_alias(
        tmp,
        "unresolvable-immutable-colocated-clone.toml",
        dst.path(),
        Some(true),
    );

    assert_clone_refused_by_the_alias(&outcome);
    let entries: Vec<_> = fs::read_dir(dst.path()).unwrap().collect();
    assert!(entries.is_empty(), "the existing destination stays, empty: {entries:?}");
}

/// Story 9.34, the non-colocated arm: `convert_import`'s snapshot (no Git head import there)
/// reads its knobs inside the snapshot step too, so a wrong-typed `snapshot.max-new-file-size`
/// fails with a PARTIAL report that records no operation, and the created destination and its
/// `.jj/` stay as the CLI leaves them (Story 9.57).
fn a_wrong_typed_snapshot_knob_fails_inside_the_import_snapshot(tmp: &Path) {
    let user = tmp.join("bad-size-import.toml");
    fs::write(&user, "snapshot.max-new-file-size = true\n").unwrap();
    set_env("JJ_CONFIG", Some(user.to_str().unwrap()));
    let src = TempDir::new().unwrap();
    git_with_commit(src.path());
    let parent = TempDir::new().unwrap();
    let dst = parent.path().join("dst");
    let outcome = convert_import(src.path(), &dst);
    set_env("JJ_CONFIG", Some(""));

    let Err(RepoError::Config { reason }) = &outcome.result else {
        panic!("a wrong-typed size knob fails the snapshot step: {:?}", outcome.result);
    };
    assert!(reason.contains("snapshot.max-new-file-size"), "{reason}");
    let precondition = outcome.precondition.expect("the snapshot started");
    assert!(
        !precondition.git_head_imported,
        "the non-colocated snapshot imports no head"
    );
    assert!(
        !precondition.was_snapshot_taken,
        "nothing was written before the failure"
    );
    assert!(
        dst.join(".jj").is_dir(),
        "the failed conversion leaves its .jj/, as the CLI"
    );
    let canonical = dst.canonicalize().unwrap();
    assert_eq!(outcome.left_behind, [canonical.clone(), canonical.join(".jj")]);
}

/// A conversion that fails AFTER its snapshot (the `trunk()` alias cannot be written, as in
/// `tests/it/convert_alias_write_failure.rs`) still reports the snapshot and every warning so far,
/// and the `.jj/` they describe stays, as the CLI leaves it (Story 9.57).
fn a_late_failure_keeps_the_report(tmp: &Path, xdg: &Path) {
    let src = TempDir::new().unwrap();
    git_with_commit(src.path());
    let parent = TempDir::new().unwrap();
    let work = parent.path().join("work");
    git(
        &["clone", &src.path().to_string_lossy(), &work.to_string_lossy()],
        parent.path(),
    );
    git(&["update-ref", "refs/remotes/git/stolen", "HEAD"], &work);

    // `<xdg>/jj` as a regular FILE: the repo-level config the alias goes to cannot be created.
    let broken = tmp.join("broken-xdg");
    fs::create_dir_all(&broken).unwrap();
    fs::write(broken.join("jj"), "not a directory").unwrap();
    set_env("XDG_CONFIG_HOME", Some(broken.to_str().unwrap()));
    let outcome = convert_colocated(&work);
    set_env("XDG_CONFIG_HOME", Some(xdg.to_str().unwrap()));

    assert!(
        matches!(outcome.result, Err(RepoError::ConvertFailed { .. })),
        "{:?}",
        outcome.result
    );
    assert_left_jj(&outcome.left_behind, &work);
    assert_eq!(
        warnings(&outcome),
        [
            (WarningKind::GitImportFailed, STOLEN),
            (WarningKind::GitImportFailed, STOLEN)
        ]
    );
    let precondition = outcome.precondition.expect("the snapshot ran before the failure");
    assert!(precondition.git_head_imported);
    assert!(precondition.was_snapshot_taken);
}
