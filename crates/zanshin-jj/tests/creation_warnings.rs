// SPDX-License-Identifier: MIT

//! Story 9.33 witnesses: the creation paths — `Repo::init`, `Repo::clone`, `convert_colocated`,
//! `convert_import` — report what the jj CLI @ v0.44.0 prints on the same flows, in its order,
//! on success AND on failure, plus the conversion's snapshot report.
//!
//! # Why one test in its own binary
//!
//! The identity rows need `JJ_USER` / `JJ_EMAIL` REMOVED (an empty identity), the others need
//! them set, the refs-step failure needs a user config file and the late-failure row a broken
//! `XDG_CONFIG_HOME`. All of these are process-global, so — the `tests/config_identity.rs`
//! idiom — this file holds exactly ONE `#[test]` that walks the I/O matrix in sequence,
//! changing the environment between phases. `JJ_CONFIG` is `""` except for the one phase that
//! repoints it at a file of its own — never unset: that would re-enable discovery of the
//! developer's real config — and `XDG_CONFIG_HOME` points into a temp dir, so the secure repo
//! config root is ours.
//!
//! The FFI rows (`open`) live in `crates/zanshin-ffi/tests/repo_ffi.rs`; the clone clean-up
//! failure is pinned inline in `src/repo.rs` (a `.jj/` that cannot be removed).

use std::env;
use std::fs;
use std::path::Path;
use std::process::Command;

use tempfile::TempDir;
use zanshin_jj::{
    convert_colocated, convert_import, Backend, CreationOutcome, Repo, RepoError, SnapshotStats, UntrackedPath,
    UntrackedReason, WarningKind,
};

/// Sets (or, for `None`, removes) one process environment variable.
fn set_env(name: &str, value: Option<&str>) {
    // SAFETY: single-threaded — this binary contains exactly one #[test], and every change
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

/// The outcome's warnings as `(kind, message)` pairs, in order.
fn warnings(outcome: &CreationOutcome) -> Vec<(WarningKind, &str)> {
    outcome.warnings.iter().map(|w| (w.kind, w.message.as_str())).collect()
}

/// The CLI's identity warning for a fully empty identity (`cli_util.rs:2397-2401`).
const IDENTITY: &str = "Name and email not configured. Until configured, your commits will be created with the \
                        empty identity, and can't be pushed to remotes.";

/// `print_failed_git_import` for the reserved ref the rows below plant.
const STOLEN: &str = "Failed to import some Git refs:\n  refs/remotes/git/stolen";

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
    clone_warns_an_empty_identity_once_and_last();
    convert_import_warns_an_empty_identity_once();
    convert_colocated_does_not_warn_an_empty_identity();
    clone_warns_the_checkout_skip_before_the_identity();
    convert_import_warns_refusal_then_checkout_skip_then_identity();

    // ── A configured identity ─────────────────────────────────────────────────────
    set_env("JJ_USER", Some("Zanshin"));
    set_env("JJ_EMAIL", Some("zanshin@localhost"));
    clone_with_an_identity_reports_nothing();
    clone_over_an_untracked_file_skips_it();
    a_big_new_file_is_refused_and_reported();
    a_reserved_ref_warns_in_the_refs_step_and_again_in_the_snapshot();
    a_refs_step_that_imports_nothing_still_warns();
    a_bad_alias_entry_warns_between_the_two_imports(tmp.path());
    a_jjconflict_entry_is_reported_by_the_colocated_conversion();
    a_snapshot_failure_keeps_a_partial_report();
    a_refs_step_failure_reports_no_snapshot(tmp.path());
    a_late_failure_keeps_the_report(tmp.path(), &xdg);
}

/// Init: the CLI's empty-directory `jj git init` finishes no transaction — no warning, not even
/// with an empty identity, and no snapshot report.
fn init_reports_nothing() {
    for backend in [Some(Backend::Git), None] {
        let dir = TempDir::new().unwrap();
        let outcome = Repo::init(dir.path(), backend);
        assert!(outcome.result.is_ok(), "{:?}", outcome.result);
        assert!(outcome.warnings.is_empty(), "{:?}", outcome.warnings);
        assert!(outcome.precondition.is_none());
    }
}

/// Clone with an empty identity: exactly ONE `jj.identity_missing` (Zanshin writes one `clone`
/// operation where the CLI finishes up to three), and it is the last warning.
fn clone_warns_an_empty_identity_once_and_last() {
    let src = TempDir::new().unwrap();
    git_with_commit(src.path());
    let dst = TempDir::new().unwrap();
    let outcome = Repo::clone(&file_url(src.path()), dst.path());
    assert!(outcome.result.is_ok(), "{:?}", outcome.result);
    assert_eq!(warnings(&outcome), [(WarningKind::IdentityMissing, IDENTITY)]);
    assert!(outcome.precondition.is_none(), "a clone runs no snapshot");
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

/// Clone over an untracked colliding `README.md` with an empty identity: the checkout's skip,
/// then the identity — the finish's order (`cli_util.rs:2369` → `:3304`, then `:2387`). The
/// collision is reachable only because Zanshin's clone accepts a non-empty target (the CLI
/// refuses it, `git/clone.rs:188-192`) — a Story 9.20 divergence; this row flips to a refusal
/// when 9.20 lands.
fn clone_warns_the_checkout_skip_before_the_identity() {
    let src = TempDir::new().unwrap();
    git_with_commit(src.path());
    let dst = TempDir::new().unwrap();
    fs::write(dst.path().join("README.md"), "local").unwrap();
    let outcome = Repo::clone(&file_url(src.path()), dst.path());
    assert!(outcome.result.is_ok(), "{:?}", outcome.result);
    assert_eq!(
        warnings(&outcome),
        [
            (WarningKind::CheckoutFilesSkipped, SKIPPED),
            (WarningKind::IdentityMissing, IDENTITY)
        ]
    );
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
    let outcome = Repo::clone(&file_url(src.path()), dst.path());
    assert!(outcome.result.is_ok(), "{:?}", outcome.result);
    assert!(outcome.warnings.is_empty(), "{:?}", outcome.warnings);
    assert!(outcome.precondition.is_none());
}

/// The target already holds an untracked `README.md` the default branch also has: the checkout
/// leaves it alone and says so (`print_checkout_stats`). Reachable only because Zanshin's clone
/// accepts a non-empty target, which the CLI refuses (`git/clone.rs:188-192`) — a Story 9.20
/// divergence; this row flips to a refusal when 9.20 lands.
fn clone_over_an_untracked_file_skips_it() {
    let src = TempDir::new().unwrap();
    git_with_commit(src.path());
    let dst = TempDir::new().unwrap();
    fs::write(dst.path().join("README.md"), "local").unwrap();
    let outcome = Repo::clone(&file_url(src.path()), dst.path());
    assert!(outcome.result.is_ok(), "{:?}", outcome.result);
    assert_eq!(
        warnings(&outcome),
        [(
            WarningKind::CheckoutFilesSkipped,
            "1 of those updates were skipped because there were conflicting changes in the working copy."
        )]
    );
    assert_eq!(fs::read_to_string(dst.path().join("README.md")).unwrap(), "local");
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
/// snapshot failed, and the snapshot's refs import never ran), although the rollback removed
/// `.jj/`.
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
    assert!(!dir.path().join(".jj").exists(), "the failed conversion is rolled back");
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
/// starts: no snapshot report, nothing warned, `.jj/` rolled back.
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
    assert!(!dir.path().join(".jj").exists(), "the failed conversion is rolled back");
}

/// A conversion that fails AFTER its snapshot (the `trunk()` alias cannot be written, as in
/// `tests/convert_alias_write_failure.rs`) still reports the snapshot and every warning so far,
/// although the rollback has removed `.jj/`.
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
    assert!(!work.join(".jj").exists(), "the failed conversion is rolled back");
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
