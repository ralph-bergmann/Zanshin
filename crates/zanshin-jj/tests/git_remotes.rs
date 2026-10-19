// SPDX-License-Identifier: MIT

//! Integration tests for Story 9.5's four remote-config verbs: `Repo::git_remote_add`,
//! `_remove`, `_rename` and `_set_url`.
//!
//! Integration level is right: all four are public `Repo` methods whose whole point is a
//! side effect on the backing git repo's config, which only a real workspace has.
//!
//! Two assertions carry this story:
//!
//! 1. **The reload.** jj-lib writes the git config file but leaves the already-loaded
//!    backend's gix config cache stale, so `list_remotes()` on the SAME handle would
//!    otherwise report the pre-call list. Every happy-path row below reads the list back
//!    through the same handle it mutated.
//! 2. **The op-log effect.** A refusal, and the reserved-remote `git` cases that change no
//!    view state, must leave the head op id byte-identical; a success must carry the CLI's
//!    own description verbatim (NFR-R-2).
//!
//! Oracles are read with plain `git` against `.jj/repo/store/git` (fixture setup only —
//! AR-AP-1's allowed exception), never by a second call into the code under test.

use std::path::{Path, PathBuf};
use std::sync::LazyLock;
use std::{env, fs};

use tempfile::TempDir;
use zanshin_jj::{Backend, MutateError, Repo};

// ── Harness ───────────────────────────────────────────────────────────────────────

/// The process-lifetime `$XDG_CONFIG_HOME` this suite runs under — deliberately LEAKED
/// (`TempDir::keep`), because it must outlive every test and there is no teardown hook that
/// could outlive them all.
///
/// Pinning it matters for more than hygiene: `config.rs` resolves the repo layer to
/// `$XDG_CONFIG_HOME/jj/repos/<config-id>/config.toml` and only falls back to the legacy
/// `.jj/repo/config.toml` when no `config-id` exists — so without a pin the canonical rows
/// below would address a path under the DEVELOPER's real `$HOME`.
static ENV_GUARD: LazyLock<PathBuf> = LazyLock::new(|| {
    let xdg = TempDir::new().expect("xdg tempdir").keep();
    // SAFETY: set once, before any test body runs, and never changed afterwards.
    unsafe {
        env::set_var("JJ_CONFIG", "");
        env::set_var("GIT_CONFIG_GLOBAL", "");
        env::set_var("JJ_USER", "Zanshin");
        env::set_var("JJ_EMAIL", "zanshin@localhost");
        env::set_var("JJ_OP_HOSTNAME", "localhost");
        env::set_var("JJ_OP_USERNAME", "zanshin");
        env::set_var("XDG_CONFIG_HOME", &xdg);
    }
    xdg
});

/// Pins the process environment; returns the pinned `$XDG_CONFIG_HOME`.
fn pin_env() -> &'static Path {
    &ENV_GUARD
}

/// Run a git command in `dir`; panics on non-zero exit.
fn git_cmd(args: &[&str], dir: &Path) {
    let status = std::process::Command::new("git")
        .args(args)
        .current_dir(dir)
        .status()
        .expect("git command failed to spawn");
    assert!(status.success(), "git {args:?} failed in {}", dir.display());
}

/// Run a git command and return `(success, trimmed stdout)`.
fn git_try(args: &[&str], dir: &Path) -> (bool, String) {
    let out = std::process::Command::new("git")
        .args(args)
        .current_dir(dir)
        .output()
        .expect("git command failed to spawn");
    let stdout = String::from_utf8_lossy(&out.stdout).trim().to_owned();
    (out.status.success(), stdout)
}

/// The backing git repository of a `Backend::Git` workspace.
fn git_store(root: &Path) -> PathBuf {
    root.join(".jj").join("repo").join("store").join("git")
}

fn head_op_id(repo: &mut Repo) -> String {
    repo.op_log(Some(1)).expect("op log").swap_remove(0).id.0
}

fn head_op_description(repo: &mut Repo) -> String {
    repo.op_log(Some(1)).expect("op log").swap_remove(0).description.clone()
}

/// Remote names as `Repo::list_remotes` reports them, on the handle passed in.
fn remote_names(repo: &mut Repo) -> Vec<String> {
    repo.list_remotes()
        .expect("list_remotes")
        .into_iter()
        .map(|r| r.name)
        .collect()
}

/// The fetch URL `Repo::list_remotes` reports for `name`, if any.
fn remote_url(repo: &mut Repo, name: &str) -> Option<String> {
    repo.list_remotes()
        .expect("list_remotes")
        .into_iter()
        .find(|r| r.name == name)
        .map(|r| r.url)
}

/// The push URL `Repo::list_remotes` reports for `name` — `None` both when the remote is
/// missing and when it pushes to its own fetch URL (the field is a DIFFERENCE, matching
/// `jj git remote list`'s `(push: …)` suffix).
fn remote_push_url(repo: &mut Repo, name: &str) -> Option<String> {
    repo.list_remotes()
        .expect("list_remotes")
        .into_iter()
        .find(|r| r.name == name)
        .and_then(|r| r.push_url)
}

/// A git-backed workspace plus a directory to use as a plausible remote URL.
///
/// The URL is never fetched from — these four verbs only rewrite config — so a plain
/// existing directory path is exactly as good as a real remote and far cheaper.
fn git_workspace() -> (TempDir, TempDir, String) {
    let tmp = TempDir::new().expect("tempdir");
    Repo::init(&zanshin_jj::InitOptions {
        path: std::path::PathBuf::from(tmp.path()),
        backend: Some(Backend::Git),
        colocate: Some(false),
        ..Default::default()
    })
    .result
    .expect("git-backed init");
    let remote_dir = TempDir::new().expect("remote tempdir");
    let url = remote_dir.path().to_string_lossy().into_owned();
    (tmp, remote_dir, url)
}

// ── git remote add ────────────────────────────────────────────────────────────────

/// The acceptance criterion this story exists for: after `git_remote_add`,
/// `list_remotes()` on the SAME handle already sees the remote. Without the workspace
/// reload it would report the pre-call list — a defect a GUI hits on its first session.
#[test]
fn git_remote_add_is_visible_through_the_same_handle_and_writes_the_cli_operation() {
    pin_env();
    let (tmp, _remote_dir, url) = git_workspace();
    let mut repo = Repo::open(tmp.path()).expect("open");
    let before = head_op_id(&mut repo);

    let result = repo.git_remote_add("origin", &url, None).expect("add must succeed");

    assert_ne!(result.new_op_id.0, before, "adding a remote writes an operation");
    assert_eq!(
        head_op_description(&mut repo),
        "add git remote origin",
        "the op-log description is the CLI's own, byte-identical (NFR-R-2)"
    );
    assert_eq!(remote_names(&mut repo), vec!["origin".to_owned()], "no reopen required");
    assert_eq!(remote_url(&mut repo, "origin").as_deref(), Some(url.as_str()));
}

/// `push_url` must actually reach jj-lib. `list_remotes` now reports the push URL as well
/// as the fetch URL, so the write is witnessed through the shipped read rather than through
/// a raw `git config --get remote.origin.pushurl` shell-out: a wrapper that silently dropped
/// the push url still fails here, and the assertion no longer depends on git's on-disk key
/// names.
#[test]
fn git_remote_add_carries_a_push_url_into_the_git_config() {
    pin_env();
    let (tmp, _remote_dir, url) = git_workspace();
    let push = format!("{url}-push");
    let mut repo = Repo::open(tmp.path()).expect("open");

    repo.git_remote_add("origin", &url, Some(&push))
        .expect("add with a push url must succeed");

    assert_eq!(remote_push_url(&mut repo, "origin").as_deref(), Some(push.as_str()));
    assert_eq!(
        remote_url(&mut repo, "origin").as_deref(),
        Some(url.as_str()),
        "the fetch url is untouched by the push url"
    );
}

#[test]
fn git_remote_add_refuses_a_duplicate_name() {
    pin_env();
    let (tmp, _remote_dir, url) = git_workspace();
    let mut repo = Repo::open(tmp.path()).expect("open");
    repo.git_remote_add("origin", &url, None).expect("first add");
    let before = head_op_id(&mut repo);

    let err = repo
        .git_remote_add("origin", &url, None)
        .expect_err("a duplicate name must refuse");

    assert!(
        matches!(&err, MutateError::RemoteExists { name } if name == "origin"),
        "unexpected error: {err:?}"
    );
    assert_eq!(head_op_id(&mut repo), before, "a refusal writes nothing");
}

/// jj-lib's three name refusals are one fault class with one remedy, so all three arrive as
/// `InvalidInput` carrying jj-lib's own reason verbatim.
#[test]
fn git_remote_add_refuses_every_invalid_name() {
    pin_env();
    let (tmp, _remote_dir, url) = git_workspace();
    let mut repo = Repo::open(tmp.path()).expect("open");
    let before = head_op_id(&mut repo);

    let reserved = repo
        .git_remote_add("git", &url, None)
        .expect_err("`git` is reserved for the local git repo");
    assert!(
        matches!(&reserved, MutateError::InvalidInput { reason } if reason.contains("reserved")),
        "jj-lib's own reason must be forwarded: {reserved:?}"
    );

    let slashed = repo
        .git_remote_add("a/b", &url, None)
        .expect_err("a slash is incompatible with jj");
    assert!(
        matches!(&slashed, MutateError::InvalidInput { .. }),
        "unexpected error: {slashed:?}"
    );

    let empty = repo
        .git_remote_add("", &url, None)
        .expect_err("an empty name is invalid");
    assert!(
        matches!(&empty, MutateError::InvalidInput { .. }),
        "unexpected error: {empty:?}"
    );

    assert_eq!(head_op_id(&mut repo), before, "no refusal writes an operation");
}

// ── git remote remove ─────────────────────────────────────────────────────────────

#[test]
fn git_remote_remove_is_visible_through_the_same_handle_and_writes_the_cli_operation() {
    pin_env();
    let (tmp, _remote_dir, url) = git_workspace();
    let mut repo = Repo::open(tmp.path()).expect("open");
    repo.git_remote_add("origin", &url, None).expect("add");

    let result = repo.git_remote_remove("origin").expect("remove must succeed");

    assert_eq!(
        head_op_description(&mut repo),
        "remove git remote origin",
        "the op-log description is the CLI's own, byte-identical (NFR-R-2)"
    );
    assert_eq!(result.new_op_id.0, head_op_id(&mut repo));
    assert!(remote_names(&mut repo).is_empty(), "no reopen required");
}

#[test]
fn git_remote_remove_refuses_a_missing_remote() {
    pin_env();
    let (tmp, _remote_dir, _url) = git_workspace();
    let mut repo = Repo::open(tmp.path()).expect("open");
    let before = head_op_id(&mut repo);

    let err = repo
        .git_remote_remove("nonexistent")
        .expect_err("a missing remote must refuse");

    assert!(
        matches!(&err, MutateError::RemoteNotFound { name } if name == "nonexistent"),
        "unexpected error: {err:?}"
    );
    assert_eq!(head_op_id(&mut repo), before);
}

/// The other half of the story's op-log criterion: the reserved remote `git` IS removable —
/// jj-lib does not validate the name on this verb — but removing it changes no jj view
/// state, so NO operation is written. The CLI carries the same guard with the comment
/// "Do not print \"Nothing changed.\" for the remote named \"git\"".
///
/// The section has to be created with plain `git`, because `git_remote_add` (correctly)
/// refuses the name.
///
/// This is also the row that pins WHERE the repo-config rewrite sits: it runs BEFORE the
/// CLI's `has_changes()` guard, so it must happen even though no operation is written. A
/// repo config is present here for exactly that reason — gating the rewrite on a committed
/// transaction would leave every other row green and only fail here.
#[test]
fn git_remote_remove_of_the_reserved_git_remote_writes_no_operation() {
    pin_env();
    let (tmp, _remote_dir, url) = git_workspace();
    git_cmd(&["remote", "add", "git", &url], &git_store(tmp.path()));
    let config_path = write_repo_config(
        tmp.path(),
        "[remotes.git]\nfetch-tags = \"none\"\n\n[revset-aliases]\n'trunk()' = 'main@git'\n",
    );
    let mut repo = Repo::open(tmp.path()).expect("open AFTER the config write");
    assert_eq!(remote_names(&mut repo), vec!["git".to_owned()], "precondition");
    let before = head_op_id(&mut repo);

    let result = repo
        .git_remote_remove("git")
        .expect("the reserved remote is removable, unlike an added one");

    assert_eq!(
        result.new_op_id.0, before,
        "removing `git` touches no view state, so nothing is written"
    );
    assert_eq!(head_op_id(&mut repo), before, "the op log is byte-identical");
    assert!(
        remote_names(&mut repo).is_empty(),
        "the git config really was rewritten"
    );

    let after = fs::read_to_string(&config_path).expect("the repo config must still be readable");
    assert!(
        !after.contains("[remotes.git]") && !after.contains("trunk()"),
        "the repo-config rewrite runs even when NO operation is written: {after:?}"
    );
}

/// A remote ADDED with a push URL cannot afterwards be removed: jj-lib's own `save_remote`
/// writes a `pushurl` key, and its `remove_remote` refuses any key outside
/// `url`/`fetch`/`tagOpt`. Plausible enough to deserve its own error code — this is the row
/// that proves it is reachable through this crate's public API alone.
#[test]
fn git_remote_remove_refuses_a_remote_that_was_added_with_a_push_url() {
    pin_env();
    let (tmp, _remote_dir, url) = git_workspace();
    let push = format!("{url}-push");
    let mut repo = Repo::open(tmp.path()).expect("open");
    repo.git_remote_add("origin", &url, Some(&push)).expect("add");
    let before = head_op_id(&mut repo);

    let err = repo
        .git_remote_remove("origin")
        .expect_err("jj refuses to rewrite a nonstandard remote section");

    assert!(
        matches!(&err, MutateError::RemoteNonstandardConfig { name } if name == "origin"),
        "unexpected error: {err:?}"
    );
    assert_eq!(head_op_id(&mut repo), before);
    assert_eq!(
        remote_names(&mut repo),
        vec!["origin".to_owned()],
        "the refusal is real: the remote survives"
    );
}

// ── git remote rename ─────────────────────────────────────────────────────────────

#[test]
fn git_remote_rename_is_visible_through_the_same_handle_and_writes_the_cli_operation() {
    pin_env();
    let (tmp, _remote_dir, url) = git_workspace();
    let mut repo = Repo::open(tmp.path()).expect("open");
    repo.git_remote_add("origin", &url, None).expect("add");

    repo.git_remote_rename("origin", "upstream")
        .expect("rename must succeed");

    assert_eq!(
        head_op_description(&mut repo),
        "rename git remote origin to upstream",
        "the op-log description is the CLI's own, byte-identical (NFR-R-2)"
    );
    assert_eq!(
        remote_names(&mut repo),
        vec!["upstream".to_owned()],
        "no reopen required"
    );
}

/// jj-lib validates the NEW name BEFORE it reports that the OLD one is missing. Both
/// conditions hold here, and the reserved-name refusal is the one that must win — that
/// ordering is jj-lib's own and is reproduced, not corrected.
#[test]
fn git_remote_rename_checks_the_new_name_before_the_old_ones_existence() {
    pin_env();
    let (tmp, _remote_dir, _url) = git_workspace();
    let mut repo = Repo::open(tmp.path()).expect("open");

    let err = repo
        .git_remote_rename("nonexistent", "git")
        .expect_err("the reserved new name must refuse");

    assert!(
        matches!(&err, MutateError::InvalidInput { reason } if reason.contains("reserved")),
        "the NEW name is validated first, so this is not RemoteNotFound: {err:?}"
    );
}

#[test]
fn git_remote_rename_refuses_a_missing_old_name_and_a_taken_new_name() {
    pin_env();
    let (tmp, _remote_dir, url) = git_workspace();
    let mut repo = Repo::open(tmp.path()).expect("open");
    repo.git_remote_add("origin", &url, None).expect("add origin");
    repo.git_remote_add("upstream", &url, None).expect("add upstream");
    let before = head_op_id(&mut repo);

    let missing = repo
        .git_remote_rename("nonexistent", "fresh")
        .expect_err("a missing old name must refuse");
    assert!(
        matches!(&missing, MutateError::RemoteNotFound { name } if name == "nonexistent"),
        "unexpected error: {missing:?}"
    );

    let taken = repo
        .git_remote_rename("origin", "upstream")
        .expect_err("a taken new name must refuse");
    assert!(
        matches!(&taken, MutateError::RemoteExists { name } if name == "upstream"),
        "the NEW name is the one that is taken: {taken:?}"
    );

    assert_eq!(head_op_id(&mut repo), before, "no refusal writes an operation");
}

/// Renaming FROM the reserved remote `git` rewrites the git config and refs but touches no
/// jj view state, so no operation is written — the same guard `remove` carries, and the same
/// reason a repo config is present: the rewrite must survive the no-operation path.
#[test]
fn git_remote_rename_from_the_reserved_git_remote_writes_no_operation() {
    pin_env();
    let (tmp, _remote_dir, url) = git_workspace();
    git_cmd(&["remote", "add", "git", &url], &git_store(tmp.path()));
    let config_path = write_repo_config(
        tmp.path(),
        "[remotes.git]\nfetch-tags = \"none\"\n\n[revset-aliases]\n'trunk()' = 'main@git'\n",
    );
    let mut repo = Repo::open(tmp.path()).expect("open AFTER the config write");
    let before = head_op_id(&mut repo);

    let result = repo
        .git_remote_rename("git", "origin")
        .expect("renaming away from the reserved name is allowed");

    assert_eq!(
        result.new_op_id.0, before,
        "renaming FROM `git` touches no view state, so nothing is written"
    );
    assert_eq!(head_op_id(&mut repo), before, "the op log is byte-identical");
    assert_eq!(
        remote_names(&mut repo),
        vec!["origin".to_owned()],
        "the git config really was rewritten"
    );

    let after = fs::read_to_string(&config_path).expect("the repo config must still be readable");
    assert!(
        after.contains("[remotes.origin]") && !after.contains("[remotes.git]"),
        "the repo-config rewrite runs even when NO operation is written: {after:?}"
    );
    assert!(
        after.contains("'trunk()' = \"main@origin\"\n"),
        "…including the alias re-point: {after:?}"
    );
}

// ── git remote set-url ────────────────────────────────────────────────────────────

/// set-url NEVER writes an operation — jj-lib takes a `&Store`, not a transaction — yet the
/// new URL must still be visible through the same handle, which is what the reload buys.
#[test]
fn git_remote_set_url_changes_the_fetch_url_without_writing_an_operation() {
    pin_env();
    let (tmp, _remote_dir, url) = git_workspace();
    let repointed = format!("{url}-elsewhere");
    let mut repo = Repo::open(tmp.path()).expect("open");
    repo.git_remote_add("origin", &url, None).expect("add");
    let before = head_op_id(&mut repo);

    let result = repo
        .git_remote_set_url("origin", Some(&repointed), None)
        .expect("set-url must succeed");

    assert_eq!(result.new_op_id.0, before, "set-url never opens a transaction");
    assert_eq!(head_op_id(&mut repo), before, "the op log is byte-identical");
    assert_eq!(
        remote_url(&mut repo, "origin").as_deref(),
        Some(repointed.as_str()),
        "no reopen required"
    );
    assert_eq!(
        remote_push_url(&mut repo, "origin"),
        None,
        "a fetch-only set-url must not invent a push url"
    );
    // `push_url` is a DIFFERENCE, so the assertion above alone is blind to the specific
    // regression the retired `git config --get remote.origin.pushurl` oracle caught: a
    // set-url that copied its `url` argument into the push slot as well would write
    // `pushurl == url`, and `list_remotes` would still report `None`. That stray key is not
    // cosmetic — jj-lib's `remove_remote_git_config_sections` refuses ANY key outside
    // `url`/`fetch`, so the remote would become unremovable. `remove` is therefore the
    // witness for key ABSENCE that the difference rule cannot give us.
    repo.git_remote_remove("origin")
        .expect("a fetch-only set-url leaves a standard remote section, so remove succeeds");
}

/// set-url's `push_url` argument, which no other row exercises: every other call passes
/// `None`, so replacing the parameter with a literal `None` would leave them all green.
/// Witnessed through `list_remotes`' own `push_url`, not a raw `git config` shell-out.
#[test]
fn git_remote_set_url_changes_only_the_push_url_when_only_that_is_given() {
    pin_env();
    let (tmp, _remote_dir, url) = git_workspace();
    let push = format!("{url}-push");
    let mut repo = Repo::open(tmp.path()).expect("open");
    repo.git_remote_add("origin", &url, None)
        .expect("add without a push url");
    let before = head_op_id(&mut repo);

    let result = repo
        .git_remote_set_url("origin", None, Some(&push))
        .expect("a push-only set-url must succeed");

    assert_eq!(result.new_op_id.0, before, "set-url never opens a transaction");
    assert_eq!(
        remote_push_url(&mut repo, "origin").as_deref(),
        Some(push.as_str()),
        "the push url must reach jj-lib verbatim"
    );
    assert_eq!(
        remote_url(&mut repo, "origin").as_deref(),
        Some(url.as_str()),
        "an absent fetch url means LEAVE IT ALONE, not clear it"
    );
}

/// jj-lib returns `Ok(())` for two absent URLs in `set_remote_urls`' first two lines —
/// BEFORE its own existence check — so the call succeeds even for a remote that does not
/// exist. Mirrored deliberately; inventing a refusal there would be a divergence.
#[test]
fn git_remote_set_url_with_both_urls_absent_succeeds_even_for_a_missing_remote() {
    pin_env();
    let (tmp, _remote_dir, _url) = git_workspace();
    let mut repo = Repo::open(tmp.path()).expect("open");
    let before = head_op_id(&mut repo);

    let result = repo
        .git_remote_set_url("nonexistent", None, None)
        .expect("jj-lib's own early return: no urls, no work, no refusal");

    assert_eq!(result.new_op_id.0, before);
    assert_eq!(head_op_id(&mut repo), before);
}

#[test]
fn git_remote_set_url_refuses_a_missing_remote_and_the_reserved_name() {
    pin_env();
    let (tmp, _remote_dir, url) = git_workspace();
    let mut repo = Repo::open(tmp.path()).expect("open");
    let before = head_op_id(&mut repo);

    let missing = repo
        .git_remote_set_url("nonexistent", Some(&url), None)
        .expect_err("a url on a missing remote must refuse");
    assert!(
        matches!(&missing, MutateError::RemoteNotFound { name } if name == "nonexistent"),
        "unexpected error: {missing:?}"
    );

    let reserved = repo
        .git_remote_set_url("git", Some(&url), None)
        .expect_err("the reserved name must refuse");
    assert!(
        matches!(&reserved, MutateError::InvalidInput { reason } if reason.contains("reserved")),
        "unexpected error: {reserved:?}"
    );

    assert_eq!(head_op_id(&mut repo), before, "no refusal writes an operation");
}

/// A native workspace has no git backend, so every remote verb refuses with the answerable
/// code — including `set_url`, which never opens a transaction and therefore takes its own
/// path to the same refusal.
#[test]
fn every_remote_verb_refuses_a_native_backend() {
    pin_env();
    let tmp = TempDir::new().expect("tempdir");
    Repo::init(&zanshin_jj::InitOptions {
        path: std::path::PathBuf::from(tmp.path()),
        ..Default::default()
    })
    .result
    .expect("native init");
    let mut repo = Repo::open(tmp.path()).expect("open");
    let before = head_op_id(&mut repo);

    for err in [
        repo.git_remote_add("origin", "/tmp/nowhere", None).unwrap_err(),
        repo.git_remote_remove("origin").unwrap_err(),
        repo.git_remote_rename("origin", "upstream").unwrap_err(),
        repo.git_remote_set_url("origin", Some("/tmp/nowhere"), None)
            .unwrap_err(),
    ] {
        assert!(matches!(err, MutateError::NotAGitRepo), "unexpected error: {err:?}");
    }
    assert_eq!(head_op_id(&mut repo), before, "no refusal writes an operation");
}

/// A remote registered by an external `jj`/`git` process must be reachable by these verbs
/// too — the handle re-resolves per call (ADR-0002) and the workspace is reloaded around
/// every config write, so nothing is cached across calls.
#[test]
fn a_remote_added_externally_can_be_renamed_and_removed_through_the_same_handle() {
    pin_env();
    let (tmp, _remote_dir, url) = git_workspace();
    git_cmd(&["remote", "add", "external", &url], &git_store(tmp.path()));
    let mut repo = Repo::open(tmp.path()).expect("open AFTER the external write");

    repo.git_remote_rename("external", "renamed").expect("rename");
    assert_eq!(remote_names(&mut repo), vec!["renamed".to_owned()]);

    repo.git_remote_remove("renamed").expect("remove");
    assert!(remote_names(&mut repo).is_empty());
}

// ── The repo-config rewrite (Epic 9 follow-up J) ──────────────────────────────────
//
// `remote remove`/`rename` rewrite the repo-level jj config exactly as the CLI does:
// `[remotes.<name>]` is dropped or moved, and a plain-remote-symbol `revset-aliases.
// 'trunk()'` naming that remote is deleted or re-pointed. These rows are the ones that need
// a REPO: the transaction ordering, and the same-session read-back through the very layer
// the rewrite edited. The file-shape matrix (comment preservation, non-symbol aliases,
// unparseable/unwritable files) is unit-tested inline in `src/config.rs`.
//
// A workspace created by `Repo::init` carries no `.jj/repo/config-id`, so the legacy
// `.jj/repo/config.toml` IS this repo's config layer — the same fact `tests/revset.rs`'s
// repo-layer rows rely on. `the_canonical_config_id_addressed_file_is_the_one_rewritten`
// covers the OTHER half, the 0.44.0 layout under the pinned `$XDG_CONFIG_HOME`, which the
// legacy fallback would otherwise leave untested.

/// Path of the repo-level config layer of a `Repo::init`ed workspace.
fn repo_config_path(root: &Path) -> PathBuf {
    root.join(".jj").join("repo").join("config.toml")
}

/// Writes `body` as the repo-level config layer and returns its path.
fn write_repo_config(root: &Path, body: &str) -> PathBuf {
    let path = repo_config_path(root);
    fs::write(&path, body).expect("repo config must be writable");
    path
}

/// A repo config with `[remotes.origin]` and a `trunk()` pinned to `origin`.
fn write_pinned_repo_config(root: &Path) -> PathBuf {
    write_repo_config(
        root,
        "# keep me\n\
         [revsets]\n\
         log = \"mine\"\n\n\
         [remotes.origin]\n\
         fetch-bookmarks = \"main\"\n\n\
         [remotes.keepme]\n\
         fetch-tags = \"none\"\n\n\
         [revset-aliases]\n\
         'trunk()' = 'main@origin'\n\
         'wip()' = 'description(\"wip\")'\n",
    )
}

/// `trunk()` evaluated through the SAME handle: `Ok` with the resolved changes, or the
/// refusal's reason.
fn eval_trunk(repo: &mut Repo) -> Result<usize, String> {
    let mut n = 0;
    repo.eval_revset("trunk()", |_| {
        n += 1;
        std::ops::ControlFlow::Continue(())
    })
    .map(|_| n)
    .map_err(|e| e.to_string())
}

/// The rewrite this follow-up ports: after `remove`, the section is gone, the pinned
/// `trunk()` alias is DELETED — so the builtin applies again, on the same handle — and
/// everything else in the file survives.
#[test]
fn remove_rewrites_the_jj_repo_config_and_the_builtin_trunk_applies_again() {
    pin_env();
    let (tmp, _remote_dir, url) = git_workspace();
    let config_path = write_pinned_repo_config(tmp.path());
    let mut repo = Repo::open(tmp.path()).expect("open");
    repo.git_remote_add("origin", &url, None).expect("add");

    repo.git_remote_remove("origin").expect("remove");

    let after = fs::read_to_string(&config_path).expect("the repo config must still be readable");
    assert!(
        !after.contains("[remotes.origin]"),
        "the removed remote's section must be gone: {after:?}"
    );
    assert!(
        !after.contains("trunk()"),
        "a `trunk()` pinned to the removed remote must be deleted: {after:?}"
    );
    // Everything the two edits do not touch survives, comments and quoting included.
    assert!(after.contains("# keep me"), "comments must survive: {after:?}");
    assert!(after.contains("log = \"mine\""), "unrelated keys survive: {after:?}");
    assert!(after.contains("[remotes.keepme]"), "other remotes survive: {after:?}");
    assert!(
        after.contains("'wip()' = 'description(\"wip\")'"),
        "other aliases survive: {after:?}"
    );

    assert_eq!(
        eval_trunk(&mut repo),
        Ok(1),
        "the SAME handle must resolve `trunk()` through the builtin alias (root(), in a \
         repo with no remote bookmarks) — config is re-read per call"
    );
}

/// Rename's mirror image: the section moves, the alias keeps its bookmark and names the NEW
/// remote — proved by the same-session refusal, which names `upstream`, not `origin`.
#[test]
fn rename_moves_the_repo_config_section_and_repoints_the_trunk_alias() {
    pin_env();
    let (tmp, _remote_dir, url) = git_workspace();
    let config_path = write_pinned_repo_config(tmp.path());
    let mut repo = Repo::open(tmp.path()).expect("open");
    repo.git_remote_add("origin", &url, None).expect("add");

    repo.git_remote_rename("origin", "upstream").expect("rename");

    let after = fs::read_to_string(&config_path).expect("the repo config must still be readable");
    assert!(
        !after.contains("[remotes.origin]"),
        "the old key must be gone: {after:?}"
    );
    // The SECTION, not just the re-pointed alias: `contains("upstream")` alone would stay
    // green if the `[remotes.<old>]` → `[remotes.<new>]` move were dropped entirely.
    assert!(after.contains("[remotes.upstream]"), "the section must move: {after:?}");
    assert!(
        after.contains("fetch-bookmarks = \"main\""),
        "the section's value survives the move: {after:?}"
    );
    // Pinned exactly rather than hedged across quotings: `set_value` re-emits the value.
    assert!(
        after.contains("'trunk()' = \"main@upstream\"\n"),
        "the alias keeps its bookmark and names the new remote: {after:?}"
    );

    let refusal = eval_trunk(&mut repo).expect_err("`main@upstream` names no remote bookmark");
    assert!(
        refusal.contains("upstream"),
        "the reloaded session must read the RE-POINTED alias, got: {refusal}"
    );
}

/// Both edits key on the remote NAME alone, and only on a plain remote symbol: an alias
/// naming another remote, and one that is any richer expression, are left alone by both
/// verbs.
#[test]
fn an_alias_naming_another_remote_or_a_compound_expression_survives_both_verbs() {
    pin_env();
    for alias in ["'main@other'", "'latest(main@origin)'"] {
        let (tmp, _remote_dir, url) = git_workspace();
        let config_path = repo_config_path(tmp.path());
        let body = format!("[revset-aliases]\n'trunk()' = {alias}\n");
        fs::write(&config_path, &body).expect("repo config must be writable");
        let mut repo = Repo::open(tmp.path()).expect("open");
        repo.git_remote_add("origin", &url, None).expect("add");

        repo.git_remote_rename("origin", "upstream").expect("rename");
        repo.git_remote_remove("upstream").expect("remove");

        assert_eq!(
            fs::read_to_string(&config_path).expect("readable"),
            body,
            "{alias} is not a plain symbol naming the touched remote, so it must survive"
        );
    }
}

/// The CLI's helpers early-return when no repo-level config file was loaded; the ported ones
/// resolve the path and filter by existence, so neither verb may bring a file into being.
#[test]
fn without_a_repo_config_file_both_verbs_succeed_and_create_none() {
    pin_env();
    let (tmp, _remote_dir, url) = git_workspace();
    let config_path = repo_config_path(tmp.path());
    let mut repo = Repo::open(tmp.path()).expect("open");
    repo.git_remote_add("origin", &url, None).expect("add");

    repo.git_remote_rename("origin", "upstream").expect("rename");
    assert!(!config_path.exists(), "rename must not create a repo config file");

    repo.git_remote_remove("upstream").expect("remove");
    assert!(!config_path.exists(), "remove must not create a repo config file");
}

/// The path is resolved BEFORE the transaction opens, so a malformed `config-id` refuses
/// with nothing mutated at all — the remote is still there afterwards.
#[test]
fn a_malformed_config_id_refuses_before_anything_is_mutated() {
    pin_env();
    let (tmp, _remote_dir, url) = git_workspace();
    let mut repo = Repo::open(tmp.path()).expect("open");
    repo.git_remote_add("origin", &url, None).expect("add");
    let before = head_op_id(&mut repo);
    fs::write(tmp.path().join(".jj").join("repo").join("config-id"), "not-hex").expect("config-id must be writable");

    let err = repo
        .git_remote_remove("origin")
        .expect_err("a malformed config-id must refuse");

    // The pre-verb snapshot reads the stack first (Story 9.26); the state is read back once the
    // id is repaired, since every verb refuses while it is broken.
    assert!(
        matches!(
            err,
            MutateError::Precondition(zanshin_jj::PreconditionError::Config { .. })
        ),
        "got: {err:?}"
    );
    fs::remove_file(tmp.path().join(".jj").join("repo").join("config-id")).expect("config-id removable");
    assert_eq!(
        remote_names(&mut repo),
        vec!["origin".to_owned()],
        "nothing was mutated"
    );
    assert_eq!(head_op_id(&mut repo), before, "and no operation was written");
}

/// Every READ-side config fault is raised before the transaction opens — the file is loaded
/// there, exactly as the CLI parses its repo layer at process start — so an unparseable repo
/// config leaves NOTHING mutated: no operation, and no git-config edit either.
#[test]
fn an_unparseable_repo_config_refuses_before_anything_is_mutated() {
    pin_env();
    let (tmp, _remote_dir, url) = git_workspace();
    let mut repo = Repo::open(tmp.path()).expect("open");
    repo.git_remote_add("origin", &url, None).expect("add");
    let before = head_op_id(&mut repo);
    write_repo_config(tmp.path(), "not = = toml\n");

    let err = repo
        .git_remote_remove("origin")
        .expect_err("an unparseable repo config must refuse");

    // The pre-verb snapshot reads the stack first (Story 9.26); the state is read back once the
    // file is repaired, since every verb refuses while it is broken.
    assert!(
        matches!(
            err,
            MutateError::Precondition(zanshin_jj::PreconditionError::Config { .. })
        ),
        "got: {err:?}"
    );
    write_repo_config(tmp.path(), "");
    assert_eq!(head_op_id(&mut repo), before, "no operation was written");
    assert_eq!(
        remote_names(&mut repo),
        vec!["origin".to_owned()],
        "and jj-lib's git-config edit never ran either — the load precedes it"
    );
}

/// Rename reaches the same code by a different arm (`set_value`, not `delete_value`), so it
/// gets its own refusal row rather than inheriting `remove`'s.
#[test]
fn an_unparseable_repo_config_refuses_rename_too_before_anything_is_mutated() {
    pin_env();
    let (tmp, _remote_dir, url) = git_workspace();
    let mut repo = Repo::open(tmp.path()).expect("open");
    repo.git_remote_add("origin", &url, None).expect("add");
    let before = head_op_id(&mut repo);
    write_repo_config(tmp.path(), "not = = toml\n");

    let err = repo
        .git_remote_rename("origin", "upstream")
        .expect_err("an unparseable repo config must refuse");

    // The pre-verb snapshot reads the stack first (Story 9.26); the state is read back once the
    // file is repaired, since every verb refuses while it is broken.
    assert!(
        matches!(
            err,
            MutateError::Precondition(zanshin_jj::PreconditionError::Config { .. })
        ),
        "got: {err:?}"
    );
    write_repo_config(tmp.path(), "");
    assert_eq!(head_op_id(&mut repo), before, "no operation was written");
    assert_eq!(
        remote_names(&mut repo),
        vec!["origin".to_owned()],
        "and the git config was not rewritten"
    );
}

/// The other ordering, and the only one that can still abort a transaction late: an
/// UNWRITABLE repo config loads fine, so the refusal lands on `save()` — after jj-lib has
/// already rewritten the git config. That asymmetry is the CLI's own (its `?` aborts the
/// same way) and is exactly what the facades' "an `Err` does not mean nothing happened"
/// paragraph is about. Both orderings stay pinned so neither can drift into the other.
#[test]
fn an_unwritable_repo_config_aborts_the_transaction_after_the_git_config_edit() {
    use std::os::unix::fs::PermissionsExt as _;

    pin_env();
    let (tmp, _remote_dir, url) = git_workspace();
    let mut repo = Repo::open(tmp.path()).expect("open");
    repo.git_remote_add("origin", &url, None).expect("add");
    let config_path = write_pinned_repo_config(tmp.path());
    // Story 9.37: the next verb's start-up fix-up MIGRATES the legacy file (a fresh, writable
    // secure file; the legacy path becomes a symlink to it), so the migration runs first and the
    // chmod — which follows the symlink — lands on the file the remote writer saves.
    repo.snapshot().expect("the snapshot migrates the legacy repo config");
    let before = head_op_id(&mut repo);
    fs::set_permissions(&config_path, fs::Permissions::from_mode(0o444)).expect("chmod");

    let err = repo
        .git_remote_remove("origin")
        .expect_err("an unwritable repo config must refuse");

    fs::set_permissions(&config_path, fs::Permissions::from_mode(0o644)).expect("chmod back");
    assert!(matches!(err, MutateError::Config { .. }), "got: {err:?}");
    assert_eq!(head_op_id(&mut repo), before, "the transaction was dropped");
    assert!(
        remote_names(&mut repo).is_empty(),
        "jj-lib's own git-config edit ran before the save and is NOT rolled back"
    );
}

/// The canonical 0.44.0 layout, which every other row here reaches only through the LEGACY
/// `.jj/repo/config.toml` fallback: with a valid `config-id`, the file that must be rewritten
/// lives at `$XDG_CONFIG_HOME/jj/repos/<id>/config.toml`. Swapping `repos` for anything else
/// in the resolver would disable the rewrite on every real repo while leaving the legacy rows
/// green, so this row is what makes the resolver's own composition load-bearing.
#[test]
fn the_canonical_config_id_addressed_file_is_the_one_rewritten() {
    let xdg = pin_env();
    let (tmp, _remote_dir, url) = git_workspace();
    let id = "0f1e2d3c4b5a69788796";
    fs::write(tmp.path().join(".jj").join("repo").join("config-id"), id).expect("config-id must be writable");
    let canonical_dir = xdg.join("jj").join("repos").join(id);
    fs::create_dir_all(&canonical_dir).expect("the canonical config dir must be creatable");
    let canonical = canonical_dir.join("config.toml");
    fs::write(
        &canonical,
        "[remotes.origin]\nfetch-bookmarks = \"main\"\n\n[revset-aliases]\n'trunk()' = 'main@origin'\n",
    )
    .expect("the canonical config must be writable");
    // Present on purpose: with a valid id file the legacy path is neither read nor written.
    let legacy = write_repo_config(tmp.path(), "[revsets]\nlog = \"legacy\"\n");

    let mut repo = Repo::open(tmp.path()).expect("open");
    repo.git_remote_add("origin", &url, None).expect("add");
    repo.git_remote_remove("origin").expect("remove");

    let after = fs::read_to_string(&canonical).expect("the canonical config must still be readable");
    assert!(
        !after.contains("[remotes.origin]") && !after.contains("trunk()"),
        "the config-id-addressed file is the one rewritten: {after:?}"
    );
    assert_eq!(
        fs::read_to_string(&legacy).expect("readable"),
        "[revsets]\nlog = \"legacy\"\n",
        "the legacy file is neither read nor written once a config-id exists"
    );
    assert_eq!(
        eval_trunk(&mut repo),
        Ok(1),
        "the same-session read-back must agree: the rewritten file IS this repo's repo layer"
    );
}

/// The reload's own failure path: `Repo::reload_after_config_write` runs the reopen on the
/// FAILURE path too — `remove_remote`/`rename_remote` write the git config BEFORE the
/// git-ref edits that can still fail, so a mid-verb failure would otherwise leave a stale
/// gix config cache behind for the rest of the session.
///
/// Provoked by removing `.jj/working_copy/type` from under an open handle: `Workspace::load`
/// needs it, while the already-built working copy does not — so the pre-verb snapshot (which
/// locks and snapshots through the loaded working copy) and the verbs still run, and only the
/// reopen fails. Both halves of the contract are asserted, and the second assertion is
/// also what proves the reload really is failing (otherwise it would read as a success).
#[test]
fn a_failed_reload_is_surfaced_only_when_the_verb_itself_succeeded() {
    pin_env();
    let (tmp, _remote_dir, url) = git_workspace();
    let mut repo = Repo::open(tmp.path()).expect("open");
    fs::remove_file(tmp.path().join(".jj").join("working_copy").join("type")).expect("remove working copy type");

    // Verb fails AND reload fails: the VERB's error survives — it is the one that explains
    // what the user did. The reload's is traced (`tracing::warn!`), never silently dropped.
    let refused = repo
        .git_remote_remove("nonexistent")
        .expect_err("the verb itself must still refuse");
    assert!(
        matches!(&refused, MutateError::RemoteNotFound { name } if name == "nonexistent"),
        "a failed reload must NOT replace the verb's own error: {refused:?}"
    );

    // Verb SUCCEEDS and reload fails: the reload error is surfaced. This is exactly the
    // "an `Err` does not mean nothing happened" case the four facades document — the remote
    // really was added, and a caller that assumed otherwise would be wrong.
    let reload_err = repo
        .git_remote_add("origin", &url, None)
        .expect_err("a failed reopen must surface once the verb itself succeeded");
    assert!(
        matches!(&reload_err, MutateError::Backend(_)),
        "unexpected error: {reload_err:?}"
    );
    // The oracle is the raw git config, not another `Repo`: with `.jj/working_copy/type` gone,
    // `Workspace::load` fails for EVERY handle — which is itself the proof that the reload
    // above really failed rather than quietly succeeding.
    let (ok, out) = git_try(&["config", "--get", "remote.origin.url"], &git_store(tmp.path()));
    assert!(ok, "the remote really was written despite the Err");
    assert_eq!(
        out, url,
        "the mutation landed despite the Err — that is the documented trap"
    );
}
