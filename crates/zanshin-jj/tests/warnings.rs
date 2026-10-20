// SPDX-License-Identifier: MIT

//! Story 9.32 — the warning channel: one witness per warning code a public-API test can
//! produce that no other suite already pins, plus the channel's own rules (record-once config
//! loads, the CLI's print order, warnings on the error arm).
//!
//! Every message is asserted VERBATIM against the jj CLI @ v0.44.0's text block (minus the
//! `Warning: ` heading and hints). Warnings are read right after the verb under test: every
//! later verb — `op_log` included — starts a fresh list.
//!
//! Witnesses living elsewhere: `jj.identity_missing` (`config_identity.rs`),
//! `jj.working_copy_immutable` snapshot variant / `jj.snapshot_files_refused`
//! (`snapshot_precondition.rs`, `file_track_untrack.rs`), `jj.jjconflict_files_present` /
//! `jj.git_head_update_failed` / `jj.git_export_failed` (`snapshot_colocated.rs`),
//! `jj.git_import_failed` (`git_sync.rs`), `jj.absorb_path_skipped` (`content_ops.rs`),
//! `jj.path_not_a_file` (`file_reads.rs`), `jj.short_prefixes_failed` (`graph.rs`),
//! `jj.path_access_denied` (`file.rs` inline), the config verbs' three (`config_cmd.rs` and
//! `config_cmd.rs` inline). `jj.snapshot_paths_not_utf8` has no witness here: APFS refuses
//! non-UTF-8 names, so its rendering is pinned inline in `warning.rs`.

use std::ops::ControlFlow;
use std::path::{Path, PathBuf};
use std::sync::LazyLock;
use std::{env, fs};

use tempfile::TempDir;
use zanshin_jj::{
    resolve_revset, Backend, ChangeId, MutateError, PreconditionError, Repo, RevisionRef, Warning, WarningKind,
    DEFAULT_GRAPH_PRIORITIZE,
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

/// A fresh internal-git workspace whose legacy repo-level config is `config`.
struct Fx {
    _tmp: TempDir,
    root: PathBuf,
}

fn git_fx(config: &str) -> Fx {
    pin_env();
    let tmp = TempDir::new().expect("tempdir");
    let root = Repo::init(&zanshin_jj::InitOptions {
        path: std::path::PathBuf::from(tmp.path()),
        backend: Some(Backend::Git),
        colocate: Some(false),
        ..Default::default()
    })
    .result
    .expect("init")
    .workspace_root()
    .to_owned();
    fs::write(root.join(".jj").join("repo").join("config.toml"), config).expect("repo config");
    Fx { _tmp: tmp, root }
}

fn write(root: &Path, rel: &str, content: &str) {
    fs::write(root.join(rel), content).expect("write file");
}

fn kinds(warnings: &[Warning]) -> Vec<WarningKind> {
    warnings.iter().map(|w| w.kind).collect()
}

/// The one warning of `kind` among `warnings`, asserting there is exactly one.
fn only(warnings: &[Warning], kind: WarningKind) -> &Warning {
    let found: Vec<&Warning> = warnings.iter().filter(|w| w.kind == kind).collect();
    assert_eq!(found.len(), 1, "exactly one {kind:?} in {warnings:?}");
    found[0]
}

fn at(repo: &Repo) -> ChangeId {
    resolve_revset(repo, "@").expect("@ resolves").swap_remove(0)
}

fn unmatched(paths: &str) -> String {
    format!("No matching entries for paths: {paths}")
}

// ── jj.paths_unmatched, per verb ─────────────────────────────────────────────────

#[test]
fn file_list_warns_about_an_unmatched_path() {
    let fx = git_fx("");
    write(&fx.root, "a.txt", "a");
    let mut repo = Repo::open(&fx.root).expect("open");

    let listed = repo
        .file_list(None, &["a.txt".to_owned(), "nope.txt".to_owned()])
        .expect("list");

    assert_eq!(listed.len(), 1);
    let warnings = repo.take_warnings();
    assert_eq!(kinds(&warnings), [WarningKind::PathsUnmatched]);
    assert_eq!(warnings[0].message, unmatched("nope.txt"));
    // A clean call — every path matched — warns about nothing.
    repo.file_list(None, &["a.txt".to_owned()]).expect("list");
    assert!(repo.take_warnings().is_empty());
}

#[test]
fn file_untrack_warns_about_an_unmatched_path_and_keeps_the_data() {
    let fx = git_fx("");
    let mut repo = Repo::open(&fx.root).expect("open");

    let result = repo.file_untrack(&["nope/".to_owned()]).expect("untrack");

    assert_eq!(
        result.unmatched_paths,
        ["nope"],
        "the normalised form, as the CLI formats it"
    );
    let warnings = repo.take_warnings();
    assert_eq!(kinds(&warnings), [WarningKind::PathsUnmatched]);
    assert_eq!(warnings[0].message, unmatched("nope"));
}

#[test]
fn file_show_and_file_search_warn_about_unmatched_paths_on_the_multi_path_branch() {
    let fx = git_fx("");
    write(&fx.root, "a.txt", "needle");
    let mut repo = Repo::open(&fx.root).expect("open");

    repo.file_show(None, &["a.txt".to_owned(), "x".to_owned(), "y".to_owned()])
        .expect("show");
    assert_eq!(
        only(&repo.take_warnings(), WarningKind::PathsUnmatched).message,
        unmatched("x, y")
    );

    repo.file_search(None, "needle", &["nope".to_owned()], false)
        .expect("search");
    assert_eq!(
        only(&repo.take_warnings(), WarningKind::PathsUnmatched).message,
        unmatched("nope")
    );
}

#[test]
fn restore_absorb_and_interdiff_warn_about_unmatched_paths() {
    let fx = git_fx("");
    write(&fx.root, "f.txt", "one\n");
    let mut repo = Repo::open(&fx.root).expect("open");
    let parent = at(&repo);
    repo.new_change(std::slice::from_ref(&parent), &[], &[]).expect("new @");
    write(&fx.root, "f.txt", "two\n");
    let nope = ["nope".to_owned()];

    repo.restore(None, None, None, &nope, false).expect("restore");
    assert_eq!(
        only(&repo.take_warnings(), WarningKind::PathsUnmatched).message,
        unmatched("nope")
    );

    repo.absorb(None, None, &nope).expect("absorb");
    assert_eq!(
        only(&repo.take_warnings(), WarningKind::PathsUnmatched).message,
        unmatched("nope")
    );

    repo.interdiff(Some(RevisionRef::ChangeId(parent)), None, &nope)
        .expect("interdiff");
    assert_eq!(
        only(&repo.take_warnings(), WarningKind::PathsUnmatched).message,
        unmatched("nope")
    );

    // A path present in ANY of the checked trees matches: `f.txt` is in both.
    repo.restore(None, None, None, &["f.txt".to_owned()], false)
        .expect("restore");
    assert!(repo
        .take_warnings()
        .iter()
        .all(|w| w.kind != WarningKind::PathsUnmatched));
}

/// "Unmatched" means absent from EVERY tree the verb checks: a file `@` deleted exists only in
/// restore's source tree (`@-`), and naming it is a match.
#[test]
fn restoring_a_file_at_deleted_is_not_an_unmatched_path() {
    let fx = git_fx("");
    write(&fx.root, "f.txt", "one\n");
    let mut repo = Repo::open(&fx.root).expect("open");
    let parent = at(&repo);
    repo.new_change(std::slice::from_ref(&parent), &[], &[]).expect("new @");
    fs::remove_file(fx.root.join("f.txt")).expect("delete f.txt in @");

    repo.restore(None, None, None, &["f.txt".to_owned()], false)
        .expect("restore");

    assert!(repo
        .take_warnings()
        .iter()
        .all(|w| w.kind != WarningKind::PathsUnmatched));
}

// ── Config-load warnings ─────────────────────────────────────────────────────────

/// A bad alias ENTRY warns (and is skipped) on a precondition verb, and a call that loads the
/// table twice — the graph walk re-reads it for its own parse — records it ONCE.
#[test]
fn a_bad_alias_entry_warns_once_per_call_on_status_and_the_graph_walk() {
    let fx = git_fx("[revset-aliases]\n'bad(' = 'x'\n\n[fileset-aliases]\n'worse(' = 'y'\n");
    let mut repo = Repo::open(&fx.root).expect("open");

    repo.status().expect("a bad entry is skipped, not an error");
    let warnings = repo.take_warnings();
    assert_eq!(
        kinds(&warnings),
        [WarningKind::ConfigAliasInvalid, WarningKind::ConfigAliasInvalid],
        "the CLI loads fileset aliases, then revset aliases"
    );
    assert!(
        warnings[0]
            .message
            .starts_with("Failed to load `fileset-aliases.worse(`: "),
        "{}",
        warnings[0].message
    );
    // Twin-checked against the installed `jj` CLI's stderr block (minus `Warning: `).
    assert_eq!(
        warnings[1].message,
        "Failed to load `revset-aliases.bad(`:  --> 1:5\n  |\n1 | bad(\n  |     ^---\n  |\n  = expected <strict_identifier>"
    );

    let flow = repo
        .walk_graph("all()", DEFAULT_GRAPH_PRIORITIZE, "", |_| ControlFlow::Continue(()))
        .expect("graph");
    assert_eq!(flow, ControlFlow::Continue(()));
    assert_eq!(
        repo.take_warnings(),
        warnings,
        "two loads of the same tables in one call, one set of warnings"
    );
}

/// A verb that re-loads the revset table for its OWN parse (`show`, after the precondition's
/// load) still records the bad entry once.
#[test]
fn show_records_a_bad_revset_alias_entry_once() {
    let fx = git_fx("[revset-aliases]\n'bad(' = 'x'\n");
    let mut repo = Repo::open(&fx.root).expect("open");

    repo.show(Some("@"), None).expect("show");

    assert_eq!(kinds(&repo.take_warnings()), [WarningKind::ConfigAliasInvalid]);
}

/// A NON-STRING alias value is the other entry failure (`config.rs:1018-1024` @ v0.44.0).
#[test]
fn a_non_string_alias_value_warns_with_its_type() {
    let fx = git_fx("[revset-aliases]\n'foo()' = 42\n");
    let mut repo = Repo::open(&fx.root).expect("open");

    repo.status().expect("a bad entry is skipped, not an error");

    let warnings = repo.take_warnings();
    assert_eq!(kinds(&warnings), [WarningKind::ConfigAliasInvalid]);
    assert_eq!(
        warnings[0].message,
        "Failed to load `revset-aliases.foo()`: Expected a string or a table with a `definition` string key, but is \
         integer"
    );
}

#[test]
fn redefining_a_mutability_builtin_warns() {
    let fx = git_fx("[revset-aliases]\n'mutable()' = '~immutable()'\n");
    let mut repo = Repo::open(&fx.root).expect("open");

    repo.status().expect("status");

    let warnings = repo.take_warnings();
    assert_eq!(kinds(&warnings), [WarningKind::ConfigAliasRedefined]);
    assert_eq!(
        warnings[0].message,
        "Redefining `revset-aliases.mutable()` is not recommended; redefine `immutable_heads()` instead."
    );
}

/// The redefinition check walks the LAYERS, as the CLI's `warn_user_redefined_builtin` does: the
/// same builtin redefined in the repo AND the workspace config warns once per layer.
#[test]
fn a_builtin_redefined_in_two_layers_warns_once_per_layer() {
    let fx = git_fx("[revset-aliases]\n'mutable()' = '~immutable()'\n");
    fs::write(
        fx.root.join(".jj").join("workspace-config.toml"),
        "[revset-aliases]\n'mutable()' = '~immutable()'\n",
    )
    .expect("workspace config");
    let mut repo = Repo::open(&fx.root).expect("open");

    repo.status().expect("status");

    assert_eq!(
        kinds(&repo.take_warnings()),
        [WarningKind::ConfigAliasRedefined, WarningKind::ConfigAliasRedefined]
    );
}

#[test]
fn revset_parse_diagnostics_warn_under_the_clis_context_line() {
    let fx = git_fx("");
    let mut repo = Repo::open(&fx.root).expect("open");

    repo.show(Some("diff_contains(\"x\")"), None).expect("show");

    let warnings = repo.take_warnings();
    assert_eq!(kinds(&warnings), [WarningKind::RevsetDiagnostic]);
    assert!(
        warnings[0].message.starts_with("In revset expression\n")
            && warnings[0]
                .message
                .contains("diff_contains() is deprecated; use diff_lines() instead"),
        "{}",
        warnings[0].message
    );
}

/// The `immutable_heads()` definition's diagnostics carry the CLI's own context line, and are
/// recorded once per call although the graph walk parses the immutable set again. The start-up
/// `revsets.short-prefixes` parse (Story 9.51 closing run) expands the same alias through the
/// default `revsets.log` (`builtin_log()`), so — as the pinned CLI's `jj log -r @` prints — its
/// diagnostic follows, once.
#[test]
fn immutable_heads_diagnostics_warn_once_per_call() {
    let fx = git_fx("[revset-aliases]\n'immutable_heads()' = 'diff_contains(\"zzz\") & none()'\n");
    let mut repo = Repo::open(&fx.root).expect("open");

    let flow = repo
        .walk_graph("@", DEFAULT_GRAPH_PRIORITIZE, "", |_| ControlFlow::Continue(()))
        .expect("graph");
    assert_eq!(flow, ControlFlow::Continue(()));

    let warnings = repo.take_warnings();
    assert_eq!(
        kinds(&warnings),
        [WarningKind::RevsetDiagnostic, WarningKind::RevsetDiagnostic]
    );
    assert!(
        warnings[0]
            .message
            .starts_with("In `revset-aliases.immutable_heads()`\n"),
        "{}",
        warnings[0].message
    );
    assert!(
        warnings[1].message.starts_with("In `revsets.short-prefixes`\n"),
        "{}",
        warnings[1].message
    );
}

// ── Verb-body warnings ───────────────────────────────────────────────────────────

#[test]
fn adding_a_remote_with_a_url_another_remote_uses_warns() {
    let fx = git_fx("");
    let mut repo = Repo::open(&fx.root).expect("open");
    let url = "https://example.com/project.git";

    repo.git_remote_add("first", url, None).expect("first");
    assert!(repo.take_warnings().is_empty(), "no other remote yet");
    repo.git_remote_add("second", url, None).expect("second");

    let warnings = repo.take_warnings();
    assert_eq!(kinds(&warnings), [WarningKind::RemoteUrlDuplicate]);
    assert_eq!(warnings[0].message, "Remote first already uses the same URL.");
}

/// The new remote's PUSH URL is checked too: a push URL another remote already fetches from
/// warns although the fetch URLs differ.
#[test]
fn adding_a_remote_whose_push_url_another_remote_uses_warns() {
    let fx = git_fx("");
    let mut repo = Repo::open(&fx.root).expect("open");
    let url = "https://example.com/project.git";

    repo.git_remote_add("first", url, None).expect("first");
    repo.git_remote_add("second", "https://example.com/other.git", Some(url))
        .expect("second");

    let warnings = repo.take_warnings();
    assert_eq!(kinds(&warnings), [WarningKind::RemoteUrlDuplicate]);
    assert_eq!(warnings[0].message, "Remote first already uses the same URL.");
}

/// The URL check skips the remote being added and every remote section that does not load, as
/// the CLI's `warn_if_remote_url_matches` does: an EMPTY `[remote "first"]` section does not stop
/// `first` from being added (jj-lib finds no remote there), a section without a URL (which gix
/// 0.88 loads, with no URL) matches nothing, and a section that does not load — an invalid fetch
/// refspec, though its URL is the new one — is skipped instead of failing the call or warning.
#[test]
fn the_remote_url_check_skips_the_new_remote_and_sections_that_do_not_load() {
    let fx = git_fx("");
    let git_config = fx
        .root
        .join(".jj")
        .join("repo")
        .join("store")
        .join("git")
        .join("config");
    let mut text = fs::read_to_string(&git_config).expect("git config");
    text.push_str("[remote \"first\"]\n[remote \"nourl\"]\n\tfetch = +refs/heads/*:refs/remotes/nourl/*\n");
    text.push_str("[remote \"badspec\"]\n\turl = https://example.com/project.git\n\tfetch = ^^^\n");
    fs::write(&git_config, text).expect("git config");
    let mut repo = Repo::open(&fx.root).expect("open");

    repo.git_remote_add("first", "https://example.com/project.git", None)
        .expect("an empty section is no remote yet");

    assert!(repo.take_warnings().is_empty());
}

#[test]
fn creating_a_bookmark_on_an_empty_revision_warns() {
    let fx = git_fx("");
    let mut repo = Repo::open(&fx.root).expect("open");

    repo.bookmark_create(&["b".to_owned()], None).expect("create");

    let warnings = repo.take_warnings();
    assert_eq!(kinds(&warnings), [WarningKind::BookmarkTargetEmpty]);
    assert_eq!(warnings[0].message, "Target revision is empty.");
}

#[test]
fn deleting_an_exact_name_that_matches_no_bookmark_warns_before_the_no_op() {
    let fx = git_fx("");
    let mut repo = Repo::open(&fx.root).expect("open");

    repo.bookmark_delete(&["nope".to_owned(), "exact:\"a b\"".to_owned(), "glob:x*".to_owned()])
        .expect("matching nothing is a success");

    let warnings = repo.take_warnings();
    assert_eq!(kinds(&warnings), [WarningKind::BookmarkNamesUnmatched]);
    assert_eq!(
        warnings[0].message, "No matching bookmarks for names: nope, \"a b\"",
        "exact patterns only (a glob never warns), quoted as revset symbols"
    );
}

/// `@` left inside the immutable set by a verb gets a new `@` on top — the finish's
/// "became immutable" — AFTER the verb body's own warning: the CLI's print order.
#[test]
fn a_verb_that_leaves_at_immutable_warns_after_its_own_warnings() {
    let fx = git_fx("[revset-aliases]\n'immutable_heads()' = 'bookmarks(frozen)'\n");
    let mut repo = Repo::open(&fx.root).expect("open");

    repo.bookmark_create(&["frozen".to_owned()], None).expect("create");

    let warnings = repo.take_warnings();
    assert_eq!(
        kinds(&warnings),
        [WarningKind::BookmarkTargetEmpty, WarningKind::WorkingCopyImmutable]
    );
    assert_eq!(
        warnings[1].message,
        "The working-copy commit became immutable; a new commit has been created on top of it."
    );
}

/// The checkout skips a file that already exists on disk but was never tracked — the CLI's
/// "conflicting changes in the working copy".
#[test]
fn a_checkout_over_an_untracked_file_warns_about_the_skipped_update() {
    let fx = git_fx("snapshot.auto-track = \"none()\"\n");
    let target = test_helpers::add_commit_with_files(&fx.root, &[], &[("a.txt", "from the commit\n")], "target");
    write(&fx.root, "a.txt", "untracked on disk\n");
    let mut repo = Repo::open(&fx.root).expect("open");
    let target = resolve_revset(&repo, &target).expect("target").swap_remove(0);

    repo.edit(target).expect("edit");

    let warnings = repo.take_warnings();
    assert_eq!(kinds(&warnings), [WarningKind::CheckoutFilesSkipped]);
    assert_eq!(
        warnings[0].message,
        "1 of those updates were skipped because there were conflicting changes in the working copy."
    );
    assert_eq!(
        fs::read_to_string(fx.root.join("a.txt")).expect("read"),
        "untracked on disk\n",
        "the on-disk file is left alone"
    );
}

/// Story 9.53: `edit` onto a conflicted merge — the CLI's "There are unresolved conflicts at
/// these paths:" with one padded line per conflicted path (`print_updated_working_copy_stats`,
/// `cli_util.rs:2318-2329` @ v0.46.0).
#[test]
fn an_edit_onto_a_conflicted_merge_lists_the_unresolved_conflicts() {
    let fx = git_fx("");
    let merge = test_helpers::add_conflicted_merge_off_root(&fx.root);
    let mut repo = Repo::open(&fx.root).expect("open");
    let merge = resolve_revset(&repo, &merge).expect("merge").swap_remove(0);

    repo.edit(merge).expect("edit");

    let warnings = repo.take_warnings();
    assert_eq!(kinds(&warnings), [WarningKind::UnresolvedConflicts]);
    assert_eq!(
        warnings[0].message,
        "There are unresolved conflicts at these paths:\nconflicted.txt    2-sided conflict"
    );
}

/// Story 9.53: the CLI's print order — `print_checkout_stats`' skipped-files warning, then the
/// unresolved conflicts (`print_updated_working_copy_stats`, `cli_util.rs:2318-2329` @ v0.46.0).
#[test]
fn a_checkout_that_skips_files_onto_a_conflict_warns_skipped_first() {
    let fx = git_fx("snapshot.auto-track = \"none()\"\n");
    let merge = test_helpers::add_conflicted_merge_with_extra_files(&fx.root, &[("extra.txt", "from the merge\n")]);
    write(&fx.root, "extra.txt", "untracked on disk\n");
    let mut repo = Repo::open(&fx.root).expect("open");
    let merge = resolve_revset(&repo, &merge).expect("merge").swap_remove(0);

    repo.edit(merge).expect("edit");

    assert_eq!(
        kinds(&repo.take_warnings()),
        [WarningKind::CheckoutFilesSkipped, WarningKind::UnresolvedConflicts]
    );
}

/// Story 9.53: the warning needs BOTH a conflicted new `@` and a moved `@` — a clean checkout
/// and a finish that leaves the conflicted `@` where it was say nothing; a rewrite of the
/// conflicted `@` (a new commit) warns again, as in the CLI (`Some(new) != old`).
#[test]
fn only_a_moved_conflicted_at_warns_about_unresolved_conflicts() {
    let fx = git_fx("");
    let clean = test_helpers::add_commit_with_files(&fx.root, &[], &[("a.txt", "a\n")], "clean");
    let merge = test_helpers::add_conflicted_merge_off_root(&fx.root);
    let mut repo = Repo::open(&fx.root).expect("open");
    let clean = resolve_revset(&repo, &clean).expect("clean").swap_remove(0);
    let merge = resolve_revset(&repo, &merge).expect("merge").swap_remove(0);

    repo.edit(clean).expect("edit clean");
    assert!(repo.take_warnings().is_empty(), "a clean checkout");

    repo.edit(merge.clone()).expect("edit merge");
    assert_eq!(kinds(&repo.take_warnings()), [WarningKind::UnresolvedConflicts]);

    repo.bookmark_create(&["here".to_owned()], None).expect("bookmark on @");
    assert!(repo.take_warnings().is_empty(), "@ did not move");

    repo.describe(merge, "described").expect("describe @");
    assert_eq!(
        kinds(&repo.take_warnings()),
        [WarningKind::UnresolvedConflicts],
        "a rewritten @ is a new commit"
    );
}

// ── The channel's rules ──────────────────────────────────────────────────────────

/// Config loads, then the snapshot's stats, then the verb body — the CLI's print order.
#[test]
fn warnings_come_in_the_clis_print_order() {
    let fx = git_fx("snapshot.max-new-file-size = 5\n[revset-aliases]\n'bad(' = 'x'\n");
    write(&fx.root, "big.bin", &"b".repeat(20));
    let mut repo = Repo::open(&fx.root).expect("open");

    repo.file_list(None, &["nope".to_owned()]).expect("list");

    assert_eq!(
        kinds(&repo.take_warnings()),
        [
            WarningKind::ConfigAliasInvalid,
            WarningKind::SnapshotFilesRefused,
            WarningKind::PathsUnmatched
        ]
    );
}

/// A refusal keeps what was warned before it: the precondition's warnings survive a verb
/// that refuses, and a failing precondition keeps the ones recorded before its failure.
#[test]
fn warnings_ride_the_error_arm_too() {
    let fx = git_fx("[revset-aliases]\n'bad(' = 'x'\n");
    let mut repo = Repo::open(&fx.root).expect("open");

    let root = resolve_revset(&repo, "root()").expect("root").swap_remove(0);
    let err = repo.describe(root, "root").expect_err("the root commit refuses");
    assert!(matches!(err, MutateError::InvalidInput { .. }), "{err:?}");
    assert_eq!(kinds(&repo.take_warnings()), [WarningKind::ConfigAliasInvalid]);

    fs::write(
        fx.root.join(".jj").join("repo").join("config.toml"),
        "snapshot.max-new-file-size = true\n[fileset-aliases]\n'bad(' = 'x'\n",
    )
    .expect("repo config");
    let err = repo.status().expect_err("a wrong-typed knob refuses");
    assert!(
        matches!(
            &err,
            zanshin_jj::StatusError::Precondition(PreconditionError::Config { .. })
        ),
        "{err:?}"
    );
    assert_eq!(
        kinds(&repo.take_warnings()),
        [WarningKind::ConfigAliasInvalid],
        "the fileset aliases load before the size knob is read"
    );
}

/// Story 9.34: the revset-alias table loads with the start-up environment, BEFORE the snapshot
/// knobs are read (`cli_util.rs:939` vs `:2068-2070` @ v0.44.0), so a bad `[revset-aliases]` entry
/// warns even when a wrong-typed size knob then refuses — as the CLI prints it.
#[test]
fn a_revset_alias_warning_precedes_a_wrong_typed_knob() {
    let fx = git_fx("snapshot.max-new-file-size = true\n[revset-aliases]\n'bad(' = 'x'\n");
    let mut repo = Repo::open(&fx.root).expect("open");

    let err = repo.status().expect_err("a wrong-typed knob refuses");

    assert!(
        matches!(
            &err,
            zanshin_jj::StatusError::Precondition(PreconditionError::Config { reason })
                if reason.contains("snapshot.max-new-file-size")
        ),
        "{err:?}"
    );
    assert_eq!(
        kinds(&repo.take_warnings()),
        [WarningKind::ConfigAliasInvalid],
        "the revset aliases load before the size knob is read"
    );
}
