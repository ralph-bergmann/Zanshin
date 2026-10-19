// SPDX-License-Identifier: MIT

//! Story 9.26 — the implicit pre-verb snapshot, NON-colocated rows of the I/O matrix plus the
//! verb-independent witnesses: the explicit `Repo::snapshot` verb, the loop-free refresh, the
//! no-snapshot `workspace root`, the three stale causes and `Updated`, and the on-disk-edit
//! witnesses of the verbs that used to read a stale `@` (restore, absorb, the file reads,
//! interdiff, workspace list).
//!
//! Every repo is built in-test (`Repo::init`), because the rows need files ON DISK next to a
//! working-copy state, which the committed fixtures do not model. The op log is read through
//! jj-lib ([`raw_ops`]) wherever a `Repo::op_log` call would itself snapshot and so disturb what
//! is being measured.

use std::path::{Path, PathBuf};
use std::sync::{Arc, LazyLock};
use std::{env, fs};

use futures::TryStreamExt as _;
use jj_lib::default_backend_factories::{default_backend_factories, default_working_copy_factories};
use jj_lib::object_id::ObjectId as _;
use jj_lib::op_store::OperationId as JjOperationId;
use jj_lib::repo::{ReadonlyRepo, Repo as _};
use jj_lib::workspace::Workspace;
use tempfile::TempDir;
use zanshin_jj::{
    Backend, ChangeId, PreconditionError, Repo, RevisionRef, StaleCause, StaleRecoveryOutcome, StatusError,
    UntrackedPath, UntrackedReason, WarningKind,
};

static ENV_GUARD: LazyLock<()> = LazyLock::new(|| {
    // SAFETY: every test calls `pin_env()` FIRST; the `LazyLock` blocks them all until this
    // initialiser returns, so no test body has read the environment yet.
    unsafe {
        for (name, value) in test_helpers::TEST_ENV {
            env::set_var(name, value);
        }
        // Story 9.37: the start-up fix-up migrates the legacy repo configs written here.
        env::set_var("XDG_CONFIG_HOME", test_helpers::leaked_xdg_config_home());
    }
});

fn pin_env() {
    LazyLock::force(&ENV_GUARD);
}

/// A fresh internal-git (NON-colocated) workspace whose legacy repo-level config is `config`.
struct Fx {
    _tmp: TempDir,
    root: PathBuf,
}

fn init(backend: Option<Backend>, config: &str) -> Fx {
    pin_env();
    let tmp = TempDir::new().expect("tempdir");
    let root = Repo::init(&zanshin_jj::InitOptions {
        path: std::path::PathBuf::from(tmp.path()),
        backend,
        colocate: backend.map(|_| false),
        ..Default::default()
    })
    .result
    .expect("init")
    .workspace_root()
    .to_owned();
    fs::write(root.join(".jj").join("repo").join("config.toml"), config).expect("repo config");
    Fx { _tmp: tmp, root }
}

fn git_fx(config: &str) -> Fx {
    init(Some(Backend::Git), config)
}

fn write(root: &Path, rel: &str, content: &str) {
    fs::write(root.join(rel), content).expect("write file");
}

fn load(root: &Path) -> (Workspace, Arc<ReadonlyRepo>) {
    let workspace = Workspace::load(
        &test_helpers::test_settings(),
        root,
        &default_backend_factories(),
        &default_working_copy_factories(),
    )
    .expect("load workspace");
    let repo = pollster::block_on(workspace.repo_loader().load_at_head()).expect("load head");
    (workspace, repo)
}

/// The op log through jj-lib, newest first — no snapshot of its own.
fn raw_ops(root: &Path) -> Vec<jj_lib::operation::Operation> {
    let (_workspace, head) = load(root);
    pollster::block_on(jj_lib::op_walk::walk_ancestors(std::slice::from_ref(head.operation())).try_collect())
        .expect("op walk")
}

fn descriptions(root: &Path) -> Vec<String> {
    raw_ops(root)
        .iter()
        .map(|op| op.metadata().description.clone())
        .collect()
}

/// `@`'s commit in the head view.
fn at_commit(root: &Path) -> jj_lib::commit::Commit {
    let (workspace, repo) = load(root);
    let id = repo
        .view()
        .get_wc_commit_id(workspace.workspace_name())
        .expect("@")
        .clone();
    repo.store().get_commit(&id).expect("@ commit")
}

fn at_paths(root: &Path) -> Vec<String> {
    at_commit(root)
        .tree()
        .entries()
        .map(|(path, _)| path.as_internal_file_string().to_owned())
        .collect()
}

// ── The matrix, non-colocated rows ───────────────────────────────────────────────

/// "Nothing changed": a clean tree writes no operation and reports nothing.
#[test]
fn a_clean_tree_writes_no_operation() {
    let fx = git_fx("");
    let mut repo = Repo::open(&fx.root).expect("open");
    let before = raw_ops(&fx.root).len();

    let report = repo.snapshot().expect("snapshot");

    assert!(!report.was_snapshot_taken);
    assert_eq!(report.snapshot_stats, zanshin_jj::SnapshotStats::default());
    assert!(
        report.git_refs.is_none(),
        "no refs import outside a colocated workspace"
    );
    assert!(!report.git_head_imported);
    assert!(report.finish.is_none());
    assert_eq!(raw_ops(&fx.root).len(), before);
    assert!(repo.take_warnings().is_empty(), "a clean call warns about nothing");
}

/// "File edited outside Zanshin (non-colocated)": one `snapshot working copy` operation, flagged
/// `is_snapshot`, and `@`'s tree updated — the snapshot alone, no Git steps.
#[test]
fn an_edit_outside_zanshin_lands_in_at_as_one_snapshot_operation() {
    let fx = git_fx("");
    let mut repo = Repo::open(&fx.root).expect("open");
    let before = raw_ops(&fx.root).len();
    write(&fx.root, "a.txt", "edited outside");

    let status = repo.status().expect("status");

    let ops = raw_ops(&fx.root);
    assert_eq!(ops.len(), before + 1, "exactly one operation");
    assert_eq!(ops[0].metadata().description, "snapshot working copy");
    assert!(ops[0].metadata().is_snapshot, "the snapshot operation is flagged");
    assert!(
        !ops[1].metadata().is_snapshot,
        "is_snapshot is true only on the snapshot operation"
    );
    assert_eq!(at_paths(&fx.root), vec!["a.txt".to_owned()]);
    assert_eq!(status.files.len(), 1, "status sees the edit");
    let report = repo.take_precondition().expect("status left a report");
    assert!(report.was_snapshot_taken);
    assert!(repo.take_precondition().is_none(), "taking the report leaves none");
}

/// "New file over limit": not tracked, reported as `FileTooLarge`, and no operation when
/// nothing else changed.
#[test]
fn a_new_file_over_the_limit_stays_untracked_and_writes_nothing() {
    let fx = git_fx("snapshot.max-new-file-size = 10\n");
    let mut repo = Repo::open(&fx.root).expect("open");
    let before = raw_ops(&fx.root).len();
    write(&fx.root, "big.bin", &"x".repeat(20));

    let report = repo.snapshot().expect("snapshot");

    assert!(!report.was_snapshot_taken);
    assert_eq!(
        report.snapshot_stats.untracked,
        vec![UntrackedPath {
            path: "big.bin".to_owned(),
            reason: UntrackedReason::FileTooLarge { size: 20, max_size: 10 },
        }]
    );
    assert_eq!(raw_ops(&fx.root).len(), before);
    // Story 9.32: `print_snapshot_stats`' warning, verbatim minus heading and hint; the typed
    // stats above stay the data.
    let warnings = repo.take_warnings();
    assert_eq!(warnings.len(), 1, "{warnings:?}");
    assert_eq!(warnings[0].kind, WarningKind::SnapshotFilesRefused);
    assert_eq!(
        warnings[0].message,
        "Refused to snapshot some files:\n  big.bin: 20.0B (20 bytes); the maximum size allowed is 10.0B (10 bytes)"
    );
}

/// "`snapshot.auto-track = "none()"`": a new file stays untracked as `FileNotAutoTracked`.
#[test]
fn auto_track_none_leaves_a_new_file_untracked() {
    let fx = git_fx("snapshot.auto-track = \"none()\"\n");
    let mut repo = Repo::open(&fx.root).expect("open");
    let before = raw_ops(&fx.root).len();
    write(&fx.root, "new.txt", "new");

    let report = repo.snapshot().expect("snapshot");

    assert_eq!(
        report.snapshot_stats.untracked,
        vec![UntrackedPath {
            path: "new.txt".to_owned(),
            reason: UntrackedReason::FileNotAutoTracked,
        }]
    );
    assert_eq!(raw_ops(&fx.root).len(), before);
    assert!(
        repo.take_warnings().is_empty(),
        "a file that is merely not auto-tracked is never warned about (`build_untracked_reason_message`)"
    );
}

/// "`@` immutable": the snapshot creates a NEW commit on top of `@` instead of rewriting it.
#[test]
fn an_immutable_at_gets_a_new_commit_on_top() {
    let fx = git_fx("[revset-aliases]\n'immutable_heads()' = '@'\n");
    let old_at = at_commit(&fx.root);
    let mut repo = Repo::open(&fx.root).expect("open");
    write(&fx.root, "a.txt", "edited");

    let report = repo.snapshot().expect("snapshot");

    let warnings = repo.take_warnings();
    assert_eq!(warnings.len(), 1, "{warnings:?}");
    assert_eq!(warnings[0].kind, WarningKind::WorkingCopyImmutable);
    assert_eq!(
        warnings[0].message,
        "The working-copy commit is immutable; a new commit has been created on top of it."
    );
    let new_at = at_commit(&fx.root);
    assert_ne!(new_at.id(), old_at.id());
    assert_eq!(
        new_at.parent_ids(),
        std::slice::from_ref(old_at.id()),
        "on top of the old @"
    );
    assert_eq!(at_paths(&fx.root), vec!["a.txt".to_owned()]);
    assert!(
        report.finish.is_none(),
        "no Git bookkeeping outside a colocated workspace"
    );
}

/// "Native backend": the middle step only — no lock file, no Git steps.
#[test]
fn a_native_backend_snapshots_without_any_git_step() {
    let fx = init(None, "");
    let mut repo = Repo::open(&fx.root).expect("open");
    write(&fx.root, "a.txt", "native");

    let report = repo.snapshot().expect("snapshot");

    assert!(report.was_snapshot_taken);
    assert!(report.git_refs.is_none());
    assert!(!report.git_head_imported);
    assert!(
        !fx.root.join(".jj").join("repo").join("git_import_export.lock").exists(),
        "no Git import/export lock outside a colocated workspace"
    );
    assert_eq!(descriptions(&fx.root)[0], "snapshot working copy");
}

/// "Explicit verb": `Repo::snapshot` on a dirty tree writes `snapshot working copy`.
#[test]
fn the_explicit_snapshot_verb_reports_the_operation_it_wrote() {
    let fx = git_fx("");
    let mut repo = Repo::open(&fx.root).expect("open");
    write(&fx.root, "a.txt", "dirty");

    let report = repo.snapshot().expect("snapshot");

    assert!(report.was_snapshot_taken);
    assert_eq!(report.snapshot_rebased, 0);
    assert_eq!(descriptions(&fx.root)[0], "snapshot working copy");
    assert!(
        repo.take_precondition().is_none(),
        "`snapshot` hands its report out itself"
    );
}

/// "Zanshin's own op → watcher → refresh": after any snapshot, the refresh a watcher triggers
/// (reads, a second snapshot) writes ZERO further operations.
#[test]
fn a_refresh_after_a_snapshot_writes_no_further_operation() {
    let fx = git_fx("");
    let mut repo = Repo::open(&fx.root).expect("open");
    write(&fx.root, "a.txt", "dirty");
    repo.snapshot().expect("first snapshot");
    let after_snapshot = raw_ops(&fx.root).len();
    let checkout = fs::read(fx.root.join(".jj").join("working_copy").join("checkout")).expect("checkout");

    repo.status().expect("status");
    repo.op_log(None).expect("op log");
    repo.list_bookmarks().expect("bookmarks");
    let again = repo.snapshot().expect("second snapshot");

    assert!(!again.was_snapshot_taken);
    assert_eq!(raw_ops(&fx.root).len(), after_snapshot, "zero further operations");
    assert_eq!(
        fs::read(fx.root.join(".jj").join("working_copy").join("checkout")).expect("checkout"),
        checkout,
        "the working copy is not even re-finished"
    );
}

/// "No-snapshot verb": `workspace root` (and the config read `log_defaults`) never snapshot.
#[test]
fn workspace_root_and_log_defaults_never_snapshot() {
    let fx = git_fx("");
    let mut repo = Repo::open(&fx.root).expect("open");
    let before = raw_ops(&fx.root).len();
    write(&fx.root, "a.txt", "dirty");

    repo.resolve_workspace_root(None).expect("workspace root");
    let _ = repo.workspace_root();
    repo.log_defaults().expect("log defaults");

    assert_eq!(raw_ops(&fx.root).len(), before, "no precondition ran");
    assert!(repo.take_precondition().is_none(), "and none left a report");
    assert!(repo.take_warnings().is_empty(), "nor any warning");
    assert!(at_paths(&fx.root).is_empty());
}

/// "Wrong-typed knob": refused as a config fault naming the key; nothing written.
#[test]
fn a_wrong_typed_knob_is_a_config_fault_naming_the_key() {
    let fx = git_fx("snapshot.max-new-file-size = true\n");
    let mut repo = Repo::open(&fx.root).expect("open");
    let before = raw_ops(&fx.root).len();
    write(&fx.root, "a.txt", "dirty");

    let err = repo.status().expect_err("a wrong-typed knob refuses");

    assert!(
        matches!(&err, StatusError::Precondition(PreconditionError::Config { reason })
            if reason.contains("snapshot.max-new-file-size")),
        "{err:?}"
    );
    assert_eq!(raw_ops(&fx.root).len(), before);
    assert!(
        repo.take_precondition().is_some(),
        "an error still leaves the (empty) report behind"
    );
}

/// `snapshot.auto-update-stale` is read ONLY on a stale working copy, like the CLI
/// (`cli_util.rs:500` @ v0.46.0): a wrong type is harmless on a fresh one and a config fault on
/// a stale one.
#[test]
fn a_wrong_typed_auto_update_stale_only_matters_on_a_stale_working_copy() {
    let fx = git_fx("snapshot.auto-update-stale = \"sometimes\"\n");
    let mut repo = Repo::open(&fx.root).expect("open");
    repo.status().expect("a fresh working copy never reads the key");

    let at = at_commit(&fx.root).id().hex();
    let _ = test_helpers::rewrite_commit_files(&fx.root, &at, &[("elsewhere.txt", "x")]);
    let err = repo.status().expect_err("stale");

    assert!(
        matches!(&err, StatusError::Precondition(PreconditionError::Config { reason })
            if reason.contains("snapshot.auto-update-stale")),
        "{err:?}"
    );
}

/// `remotes.<name>.auto-track-bookmarks` is parsed like the CLI's, but only where the CLI reads
/// it: NOT by the non-colocated pre-verb snapshot (which imports no refs), so a read succeeds,
/// while `git import` itself refuses with the CLI's own wording.
#[test]
fn an_invalid_auto_track_bookmarks_expression_refuses_only_the_import() {
    let fx = git_fx("[remotes.origin]\nauto-track-bookmarks = \"glob:(\"\n");
    let mut repo = Repo::open(&fx.root).expect("open");

    repo.status()
        .expect("the non-colocated snapshot never reads the import options");
    let err = repo
        .git_import()
        .expect_err("an unparseable matcher refuses the import");

    assert!(
        matches!(&err, zanshin_jj::MutateError::Config { reason }
            if reason.contains("Invalid `remotes.origin.auto-track-bookmarks`")),
        "{err:?}"
    );
}

/// A `.jjconflict` entry is only reported in a COLOCATED workspace, as in the CLI.
#[test]
fn a_jjconflict_entry_is_not_reported_outside_a_colocated_workspace() {
    let fx = git_fx("");
    let mut repo = Repo::open(&fx.root).expect("open");
    write(&fx.root, ".jjconflict-base-0", "x");

    repo.snapshot().expect("snapshot");

    assert!(
        repo.take_warnings()
            .iter()
            .all(|w| w.kind != WarningKind::JjconflictFilesPresent),
        "the `.jjconflict` warning is colocated-only"
    );
}

// ── Stale working copies ─────────────────────────────────────────────────────────

fn assert_stale(err: &PreconditionError, expected: StaleCause) {
    assert!(
        matches!(err, PreconditionError::StaleWorkingCopy { cause, working_copy_op_id, repo_op_id }
            if *cause == expected && working_copy_op_id.len() == 128 && repo_op_id.len() == 128),
        "expected {expected:?}, got {err:?}"
    );
}

/// "Stale WC": `@` rewritten by another writer that never checked it out.
#[test]
fn a_rewritten_but_unchecked_out_at_is_stale() {
    let fx = git_fx("");
    let mut repo = Repo::open(&fx.root).expect("open");
    let at = at_commit(&fx.root).id().hex();
    let _ = test_helpers::rewrite_commit_files(&fx.root, &at, &[("elsewhere.txt", "x")]);
    let before = raw_ops(&fx.root).len();

    let err = repo.snapshot().expect_err("stale");

    assert_stale(&err, StaleCause::Stale);
    assert_eq!(raw_ops(&fx.root).len(), before, "no operation");
}

/// Story 9.23 (I1): `snapshot.auto-update-stale = true` recovers a stale working copy inside the
/// precondition, under its lock (`cli_util.rs:497-512` @ v0.46.0), and the verb runs on the
/// recovered state: the rewritten `@`'s files are on disk and the report says what the recovery
/// did — with no operation of its own, since the working copy was clean.
#[test]
fn auto_update_stale_recovers_a_stale_working_copy() {
    let fx = git_fx("snapshot.auto-update-stale = true\n");
    let mut repo = Repo::open(&fx.root).expect("open");
    let at = at_commit(&fx.root).id().hex();
    let rewritten = test_helpers::rewrite_commit_files(&fx.root, &at, &[("elsewhere.txt", "x")]);
    let before = raw_ops(&fx.root).len();

    let report = repo.snapshot().expect("the precondition recovers");

    let recovery = report.stale_recovery.expect("the recovery is reported");
    assert_eq!(recovery.outcome, StaleRecoveryOutcome::Updated);
    assert_eq!(recovery.commit_id.map(|c| c.0), Some(rewritten));
    assert_eq!(recovery.checkout.map(|c| c.added), Some(1));
    assert_eq!(recovery.git_head_reset_op_id, None, "not colocated");
    assert_eq!(fs::read_to_string(fx.root.join("elsewhere.txt")).expect("on disk"), "x");
    assert_eq!(raw_ops(&fx.root).len(), before, "a clean recovery writes no operation");
    assert!(!report.was_snapshot_taken);
    repo.status().expect("fresh again");
}

/// The auto arm on the SIBLING cause: the working copy at an unpublished operation is checked
/// out onto the published head's `@`.
#[test]
fn auto_update_stale_recovers_a_working_copy_at_a_sibling_operation() {
    let fx = git_fx("snapshot.auto-update-stale = true\n");
    let mut repo = Repo::open(&fx.root).expect("open");
    let _ = unpublished_op_with_the_working_copy_at_it(&fx.root);
    let _ = test_helpers::add_commit_off_root(&fx.root, "published sibling");

    let report = repo.snapshot().expect("the precondition recovers");

    let recovery = report.stale_recovery.expect("the recovery is reported");
    assert_eq!(recovery.outcome, StaleRecoveryOutcome::Updated);
    assert_eq!(recovery.commit_id.map(|c| c.0), Some(at_commit(&fx.root).id().hex()));
    repo.status().expect("fresh again");
}

/// The auto arm on the NOT-FOUND cause: jj-lib's `recovery commit` holds the files on disk, and
/// the trailing snapshot records the dirty one.
#[test]
fn auto_update_stale_recovers_a_working_copy_at_a_missing_operation() {
    let fx = git_fx("snapshot.auto-update-stale = true\n");
    let mut repo = Repo::open(&fx.root).expect("open");
    {
        let (mut workspace, _repo) = load(&fx.root);
        let locked = pollster::block_on(workspace.start_working_copy_mutation()).expect("lock");
        pollster::block_on(locked.finish(JjOperationId::new(vec![0xab; 64]))).expect("finish");
    }
    write(&fx.root, "kept.txt", "kept");

    let report = repo.snapshot().expect("the precondition recovers");

    let recovery = report.stale_recovery.expect("the recovery is reported");
    assert_eq!(recovery.outcome, StaleRecoveryOutcome::Recovered);
    assert_eq!(recovery.checkout, None);
    assert_eq!(
        &descriptions(&fx.root)[..2],
        ["snapshot working copy", "recovery commit"]
    );
    let at = at_commit(&fx.root);
    assert!(at
        .description()
        .starts_with("RECOVERY COMMIT FROM `jj workspace update-stale`"));
    assert!(at_paths(&fx.root).contains(&"kept.txt".to_owned()));
    assert!(report.was_snapshot_taken);
}

/// Story 9.34: the snapshot knobs are read at the top of the snapshot step, BEFORE the
/// working-copy lock and the stale check (`cli_util.rs:2065-2079` @ v0.44.0), so a stale working
/// copy with a wrong-typed knob refuses on the knob, as in the CLI.
#[test]
fn a_wrong_typed_knob_wins_over_a_stale_working_copy() {
    let fx = git_fx("snapshot.max-new-file-size = true\n");
    let mut repo = Repo::open(&fx.root).expect("open");
    let at = at_commit(&fx.root).id().hex();
    let _ = test_helpers::rewrite_commit_files(&fx.root, &at, &[("elsewhere.txt", "x")]);
    let before = raw_ops(&fx.root).len();

    let err = repo.snapshot().expect_err("the knob refuses first");

    assert!(
        matches!(&err, PreconditionError::Config { reason } if reason.contains("snapshot.max-new-file-size")),
        "{err:?}"
    );
    assert_eq!(raw_ops(&fx.root).len(), before, "no operation");
}

/// Writes an UNPUBLISHED operation from the current head that describes `@`, and finishes the
/// working copy at it — the state a CLI leaves behind between writing an operation and
/// publishing it.
fn unpublished_op_with_the_working_copy_at_it(root: &Path) -> JjOperationId {
    let (mut workspace, repo) = load(root);
    let at = at_commit(root);
    let mut tx = repo.start_transaction();
    pollster::block_on(tx.repo_mut().rewrite_commit(&at).set_description("unpublished").write()).expect("describe");
    pollster::block_on(tx.repo_mut().rebase_descendants()).expect("rebase");
    let unpublished = pollster::block_on(tx.write("test: unpublished"))
        .expect("write")
        .leave_unpublished();
    let locked = pollster::block_on(workspace.start_working_copy_mutation()).expect("lock");
    pollster::block_on(locked.finish(unpublished.op_id().clone())).expect("finish");
    unpublished.op_id().clone()
}

/// "Updated WC": the working copy is at an operation NEWER than the head (the CLI snapshotted
/// between load and lock). The repo is reloaded at the working copy's operation and the
/// snapshot proceeds.
#[test]
fn a_working_copy_ahead_of_the_head_reloads_and_proceeds() {
    let fx = git_fx("");
    let mut repo = Repo::open(&fx.root).expect("open");
    let _ = unpublished_op_with_the_working_copy_at_it(&fx.root);
    write(&fx.root, "a.txt", "dirty");

    let report = repo.snapshot().expect("an updated working copy proceeds");

    assert!(report.was_snapshot_taken);
    assert_eq!(descriptions(&fx.root)[0], "snapshot working copy");
    assert_eq!(
        at_commit(&fx.root).description(),
        "unpublished",
        "built on the reloaded op"
    );
}

/// "Stale WC" — the SIBLING cause: the working copy sits at an unpublished operation while a
/// different operation from the same parent was published.
#[test]
fn a_working_copy_at_a_sibling_operation_is_refused() {
    let fx = git_fx("");
    let mut repo = Repo::open(&fx.root).expect("open");
    let _ = unpublished_op_with_the_working_copy_at_it(&fx.root);
    let _ = test_helpers::add_commit_off_root(&fx.root, "published sibling");
    let before = raw_ops(&fx.root).len();

    let err = repo.snapshot().expect_err("sibling");

    assert_stale(&err, StaleCause::SiblingOperation);
    assert_eq!(raw_ops(&fx.root).len(), before);
}

/// "Stale WC" — the NOT-FOUND cause: the working copy names an operation that does not exist.
#[test]
fn a_working_copy_at_a_missing_operation_is_refused() {
    let fx = git_fx("");
    let mut repo = Repo::open(&fx.root).expect("open");
    {
        let (mut workspace, _repo) = load(&fx.root);
        let locked = pollster::block_on(workspace.start_working_copy_mutation()).expect("lock");
        pollster::block_on(locked.finish(JjOperationId::new(vec![0xab; 64]))).expect("finish");
    }

    let err = repo.snapshot().expect_err("not found");

    assert_stale(&err, StaleCause::OperationNotFound);
}

/// Story 9.23: the pre-verb snapshot loads the head the CLI's way (`resolve_operation`,
/// `cli_util.rs:800-829` @ v0.46.0), so the `reconcile divergent operations` it writes for two
/// operation heads names THIS workspace — jj-lib's own `load_at_head` would name none.
#[test]
fn the_precondition_reconciles_divergent_heads_as_this_workspace() {
    let fx = git_fx("");
    let mut repo = Repo::open(&fx.root).expect("open");
    {
        let (_workspace, base) = load(&fx.root);
        for name in ["left", "right"] {
            let mut tx = base.start_transaction();
            let tree = base.store().root_commit().tree();
            let commit = pollster::block_on(
                tx.repo_mut()
                    .new_commit(vec![base.store().root_commit_id().clone()], tree)
                    .set_description(name)
                    .write(),
            )
            .expect("sibling commit");
            drop(commit);
            pollster::block_on(tx.commit(format!("test: {name}"))).expect("commit");
        }
    }

    repo.snapshot().expect("snapshot");

    let (_workspace, head) = load(&fx.root);
    let meta = head.operation().metadata();
    assert_eq!(meta.description, "reconcile divergent operations");
    assert_eq!(meta.workspace_name.as_ref().map(|name| name.as_str()), Some("default"));
}

// ── On-disk edits reach every verb that reads `@` ────────────────────────────────

/// `f.txt = "one\ntwo\n"` committed into `@-`, and `@` a fresh empty child — the repo every
/// on-disk-edit witness below edits.
fn with_parent_file() -> (Fx, Repo, ChangeId) {
    let fx = git_fx("");
    let mut repo = Repo::open(&fx.root).expect("open");
    write(&fx.root, "f.txt", "one\ntwo\nthree\n");
    let at = repo.status().expect("status").working_copy_change_id;
    let parent = at.clone();
    repo.new_change(&[at], &[], &[]).expect("new @ on top");
    (fx, repo, parent)
}

/// `jj restore` snapshots first: the on-disk edit is recorded into `@` and THEN undone, so the
/// disk goes back to the parent's content.
#[test]
fn restore_sees_an_on_disk_edit() {
    let (fx, mut repo, _parent) = with_parent_file();
    write(&fx.root, "f.txt", "one\nEDITED\nthree\n");

    repo.restore(None, None, None, &[], false).expect("restore");

    let ops = descriptions(&fx.root);
    assert_eq!(ops[1], "snapshot working copy");
    assert!(ops[0].starts_with("restore into commit "), "{ops:?}");
    assert_eq!(
        fs::read_to_string(fx.root.join("f.txt")).expect("read"),
        "one\ntwo\nthree\n",
        "the restored parent content is checked out"
    );
}

/// `jj absorb` snapshots first: the on-disk edit is what gets absorbed into `@-`.
#[test]
fn absorb_sees_an_on_disk_edit() {
    let (fx, mut repo, parent) = with_parent_file();
    write(&fx.root, "f.txt", "one\nABSORBED\nthree\n");

    let result = repo.absorb(None, None, &[]).expect("absorb");

    assert_eq!(result.rewritten_change_ids, vec![parent.clone()]);
    let shown = repo.file_show(Some(parent), &["f.txt".to_owned()]).expect("show");
    assert_eq!(shown.files[0].content, b"one\nABSORBED\nthree\n");
}

/// The file reads snapshot first: an omitted revision is the up-to-date `@`.
#[test]
fn the_file_reads_see_an_on_disk_edit() {
    let (fx, mut repo, _parent) = with_parent_file();
    write(&fx.root, "f.txt", "one\nREAD\nthree\n");
    write(&fx.root, "g.txt", "new");

    let shown = repo.file_show(None, &["f.txt".to_owned()]).expect("show");
    assert_eq!(shown.files[0].content, b"one\nREAD\nthree\n");
    let listed = repo.file_list(None, &[]).expect("list");
    assert_eq!(
        listed.iter().map(|e| e.path.as_str()).collect::<Vec<_>>(),
        ["f.txt", "g.txt"]
    );
    let found = repo.file_search(None, "READ", &[], false).expect("search");
    assert_eq!(found.matches.len(), 1);
    let annotated = repo.file_annotate(None, "f.txt").expect("annotate");
    assert_eq!(annotated.len(), 3);
}

/// `jj interdiff` snapshots first: `@`'s side carries the on-disk edit.
#[test]
fn interdiff_sees_an_on_disk_edit() {
    let (fx, mut repo, parent) = with_parent_file();
    write(&fx.root, "f.txt", "one\nINTER\nthree\n");

    let view = repo
        .interdiff(Some(RevisionRef::ChangeId(parent)), None, &[])
        .expect("interdiff");

    assert!(
        view.file_changes
            .iter()
            .any(|c| c.path == std::path::Path::new("f.txt")),
        "the edit is part of @: {view:?}"
    );
}

/// `jj workspace list` snapshots first: the listed `@` is the snapshotted one.
#[test]
fn workspace_list_sees_an_on_disk_edit() {
    let (fx, mut repo, _parent) = with_parent_file();
    let before = at_commit(&fx.root).id().hex();
    write(&fx.root, "f.txt", "one\nLISTED\nthree\n");

    let listed = repo.list_workspaces().expect("list");

    assert_ne!(listed[0].wc_commit_id.0, before, "the listed @ is the snapshotted one");
    assert_eq!(listed[0].wc_commit_id.0, at_commit(&fx.root).id().hex());
}
