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

static ENV_GUARD: LazyLock<()> = LazyLock::new(|| unsafe {
    env::set_var("JJ_CONFIG", "");
    env::set_var("GIT_CONFIG_GLOBAL", "");
});

fn pin_env() {
    LazyLock::force(&ENV_GUARD);
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

fn head_op_id(repo: &Repo) -> String {
    repo.op_log(Some(1)).expect("op log").swap_remove(0).id.0
}

fn head_op_description(repo: &Repo) -> String {
    repo.op_log(Some(1)).expect("op log").swap_remove(0).description.clone()
}

/// Remote names as `Repo::list_remotes` reports them, on the handle passed in.
fn remote_names(repo: &Repo) -> Vec<String> {
    repo.list_remotes()
        .expect("list_remotes")
        .into_iter()
        .map(|r| r.name)
        .collect()
}

/// The fetch URL `Repo::list_remotes` reports for `name`, if any.
fn remote_url(repo: &Repo, name: &str) -> Option<String> {
    repo.list_remotes()
        .expect("list_remotes")
        .into_iter()
        .find(|r| r.name == name)
        .map(|r| r.url)
}

/// A git-backed workspace plus a directory to use as a plausible remote URL.
///
/// The URL is never fetched from — these four verbs only rewrite config — so a plain
/// existing directory path is exactly as good as a real remote and far cheaper.
fn git_workspace() -> (TempDir, TempDir, String) {
    let tmp = TempDir::new().expect("tempdir");
    Repo::init(tmp.path(), Some(Backend::Git)).expect("git-backed init");
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
    let before = head_op_id(&repo);

    let result = repo.git_remote_add("origin", &url, None).expect("add must succeed");

    assert_ne!(result.new_op_id.0, before, "adding a remote writes an operation");
    assert_eq!(
        head_op_description(&repo),
        "add git remote origin",
        "the op-log description is the CLI's own, byte-identical (NFR-R-2)"
    );
    assert_eq!(remote_names(&repo), vec!["origin".to_owned()], "no reopen required");
    assert_eq!(remote_url(&repo, "origin").as_deref(), Some(url.as_str()));
}

/// `push_url` must actually reach jj-lib. The oracle is the raw git config, not a second
/// call into the code under test — `list_remotes` only reports the FETCH url, so a wrapper
/// that silently dropped the push url would otherwise pass.
#[test]
fn git_remote_add_carries_a_push_url_into_the_git_config() {
    pin_env();
    let (tmp, _remote_dir, url) = git_workspace();
    let push = format!("{url}-push");
    let mut repo = Repo::open(tmp.path()).expect("open");

    repo.git_remote_add("origin", &url, Some(&push))
        .expect("add with a push url must succeed");

    let (ok, out) = git_try(&["config", "--get", "remote.origin.pushurl"], &git_store(tmp.path()));
    assert!(ok, "git config must hold a pushurl for the remote");
    assert_eq!(out, push);
}

#[test]
fn git_remote_add_refuses_a_duplicate_name() {
    pin_env();
    let (tmp, _remote_dir, url) = git_workspace();
    let mut repo = Repo::open(tmp.path()).expect("open");
    repo.git_remote_add("origin", &url, None).expect("first add");
    let before = head_op_id(&repo);

    let err = repo
        .git_remote_add("origin", &url, None)
        .expect_err("a duplicate name must refuse");

    assert!(
        matches!(&err, MutateError::RemoteExists { name } if name == "origin"),
        "unexpected error: {err:?}"
    );
    assert_eq!(head_op_id(&repo), before, "a refusal writes nothing");
}

/// jj-lib's three name refusals are one fault class with one remedy, so all three arrive as
/// `InvalidInput` carrying jj-lib's own reason verbatim.
#[test]
fn git_remote_add_refuses_every_invalid_name() {
    pin_env();
    let (tmp, _remote_dir, url) = git_workspace();
    let mut repo = Repo::open(tmp.path()).expect("open");
    let before = head_op_id(&repo);

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

    assert_eq!(head_op_id(&repo), before, "no refusal writes an operation");
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
        head_op_description(&repo),
        "remove git remote origin",
        "the op-log description is the CLI's own, byte-identical (NFR-R-2)"
    );
    assert_eq!(result.new_op_id.0, head_op_id(&repo));
    assert!(remote_names(&repo).is_empty(), "no reopen required");
}

#[test]
fn git_remote_remove_refuses_a_missing_remote() {
    pin_env();
    let (tmp, _remote_dir, _url) = git_workspace();
    let mut repo = Repo::open(tmp.path()).expect("open");
    let before = head_op_id(&repo);

    let err = repo
        .git_remote_remove("nonexistent")
        .expect_err("a missing remote must refuse");

    assert!(
        matches!(&err, MutateError::RemoteNotFound { name } if name == "nonexistent"),
        "unexpected error: {err:?}"
    );
    assert_eq!(head_op_id(&repo), before);
}

/// The other half of the story's op-log criterion: the reserved remote `git` IS removable —
/// jj-lib does not validate the name on this verb — but removing it changes no jj view
/// state, so NO operation is written. The CLI carries the same guard with the comment
/// "Do not print \"Nothing changed.\" for the remote named \"git\"".
///
/// The section has to be created with plain `git`, because `git_remote_add` (correctly)
/// refuses the name.
#[test]
fn git_remote_remove_of_the_reserved_git_remote_writes_no_operation() {
    pin_env();
    let (tmp, _remote_dir, url) = git_workspace();
    git_cmd(&["remote", "add", "git", &url], &git_store(tmp.path()));
    let mut repo = Repo::open(tmp.path()).expect("open AFTER the config write");
    assert_eq!(remote_names(&repo), vec!["git".to_owned()], "precondition");
    let before = head_op_id(&repo);

    let result = repo
        .git_remote_remove("git")
        .expect("the reserved remote is removable, unlike an added one");

    assert_eq!(
        result.new_op_id.0, before,
        "removing `git` touches no view state, so nothing is written"
    );
    assert_eq!(head_op_id(&repo), before, "the op log is byte-identical");
    assert!(remote_names(&repo).is_empty(), "the git config really was rewritten");
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
    let before = head_op_id(&repo);

    let err = repo
        .git_remote_remove("origin")
        .expect_err("jj refuses to rewrite a nonstandard remote section");

    assert!(
        matches!(&err, MutateError::RemoteNonstandardConfig { name } if name == "origin"),
        "unexpected error: {err:?}"
    );
    assert_eq!(head_op_id(&repo), before);
    assert_eq!(
        remote_names(&repo),
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
        head_op_description(&repo),
        "rename git remote origin to upstream",
        "the op-log description is the CLI's own, byte-identical (NFR-R-2)"
    );
    assert_eq!(remote_names(&repo), vec!["upstream".to_owned()], "no reopen required");
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
    let before = head_op_id(&repo);

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

    assert_eq!(head_op_id(&repo), before, "no refusal writes an operation");
}

/// Renaming FROM the reserved remote `git` rewrites the git config and refs but touches no
/// jj view state, so no operation is written — the same guard `remove` carries.
#[test]
fn git_remote_rename_from_the_reserved_git_remote_writes_no_operation() {
    pin_env();
    let (tmp, _remote_dir, url) = git_workspace();
    git_cmd(&["remote", "add", "git", &url], &git_store(tmp.path()));
    let mut repo = Repo::open(tmp.path()).expect("open AFTER the config write");
    let before = head_op_id(&repo);

    let result = repo
        .git_remote_rename("git", "origin")
        .expect("renaming away from the reserved name is allowed");

    assert_eq!(
        result.new_op_id.0, before,
        "renaming FROM `git` touches no view state, so nothing is written"
    );
    assert_eq!(head_op_id(&repo), before, "the op log is byte-identical");
    assert_eq!(
        remote_names(&repo),
        vec!["origin".to_owned()],
        "the git config really was rewritten"
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
    let before = head_op_id(&repo);

    let result = repo
        .git_remote_set_url("origin", Some(&repointed), None)
        .expect("set-url must succeed");

    assert_eq!(result.new_op_id.0, before, "set-url never opens a transaction");
    assert_eq!(head_op_id(&repo), before, "the op log is byte-identical");
    assert_eq!(
        remote_url(&repo, "origin").as_deref(),
        Some(repointed.as_str()),
        "no reopen required"
    );
    let (has_push, _) = git_try(&["config", "--get", "remote.origin.pushurl"], &git_store(tmp.path()));
    assert!(!has_push, "a fetch-only set-url must not invent a push url");
}

/// set-url's `push_url` argument, which no other row exercises: every other call passes
/// `None`, so replacing the parameter with a literal `None` would leave them all green. The
/// oracle is the raw git config, because `list_remotes` only reports the FETCH url.
#[test]
fn git_remote_set_url_changes_only_the_push_url_when_only_that_is_given() {
    pin_env();
    let (tmp, _remote_dir, url) = git_workspace();
    let push = format!("{url}-push");
    let mut repo = Repo::open(tmp.path()).expect("open");
    repo.git_remote_add("origin", &url, None)
        .expect("add without a push url");
    let before = head_op_id(&repo);

    let result = repo
        .git_remote_set_url("origin", None, Some(&push))
        .expect("a push-only set-url must succeed");

    assert_eq!(result.new_op_id.0, before, "set-url never opens a transaction");
    let (ok, out) = git_try(&["config", "--get", "remote.origin.pushurl"], &git_store(tmp.path()));
    assert!(ok, "git config must now hold a pushurl");
    assert_eq!(out, push, "the push url must reach jj-lib verbatim");
    assert_eq!(
        remote_url(&repo, "origin").as_deref(),
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
    let before = head_op_id(&repo);

    let result = repo
        .git_remote_set_url("nonexistent", None, None)
        .expect("jj-lib's own early return: no urls, no work, no refusal");

    assert_eq!(result.new_op_id.0, before);
    assert_eq!(head_op_id(&repo), before);
}

#[test]
fn git_remote_set_url_refuses_a_missing_remote_and_the_reserved_name() {
    pin_env();
    let (tmp, _remote_dir, url) = git_workspace();
    let mut repo = Repo::open(tmp.path()).expect("open");
    let before = head_op_id(&repo);

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

    assert_eq!(head_op_id(&repo), before, "no refusal writes an operation");
}

/// A native workspace has no git backend, so every remote verb refuses with the answerable
/// code — including `set_url`, which never opens a transaction and therefore takes its own
/// path to the same refusal.
#[test]
fn every_remote_verb_refuses_a_native_backend() {
    pin_env();
    let tmp = TempDir::new().expect("tempdir");
    Repo::init(tmp.path(), None).expect("native init");
    let mut repo = Repo::open(tmp.path()).expect("open");
    let before = head_op_id(&repo);

    for err in [
        repo.git_remote_add("origin", "/tmp/nowhere", None).unwrap_err(),
        repo.git_remote_remove("origin").unwrap_err(),
        repo.git_remote_rename("origin", "upstream").unwrap_err(),
        repo.git_remote_set_url("origin", Some("/tmp/nowhere"), None)
            .unwrap_err(),
    ] {
        assert!(matches!(err, MutateError::NotAGitRepo), "unexpected error: {err:?}");
    }
    assert_eq!(head_op_id(&repo), before, "no refusal writes an operation");
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
    assert_eq!(remote_names(&repo), vec!["renamed".to_owned()]);

    repo.git_remote_remove("renamed").expect("remove");
    assert!(remote_names(&repo).is_empty());
}

/// `.jj/repo/config.toml` is untouched by remove (and rename): the CLI edits it — dropping
/// `[remotes.<name>]` and rewriting the `revset-aliases.'trunk()'` alias — and this crate
/// deliberately does not, because `config.rs` is read-only. This row pins the resulting
/// divergence so it stays a decision rather than drifting into an accident.
#[test]
fn remove_does_not_edit_the_jj_repo_config() {
    pin_env();
    let (tmp, _remote_dir, url) = git_workspace();
    let config_path = tmp.path().join(".jj").join("repo").join("config.toml");
    fs::write(
        &config_path,
        "[revset-aliases]\n'trunk()' = 'remote_bookmarks(exact:\"main\", exact:\"origin\")'\n",
    )
    .expect("repo config must be writable");
    let mut repo = Repo::open(tmp.path()).expect("open");
    repo.git_remote_add("origin", &url, None).expect("add");

    repo.git_remote_remove("origin").expect("remove");

    let after = fs::read_to_string(&config_path).expect("the repo config must still be readable");
    assert!(
        after.contains("exact:\"origin\""),
        "the jj repo config is deliberately NOT rewritten — a `trunk()` alias pinned to a \
         removed remote keeps naming it (documented divergence), got: {after:?}"
    );
}

/// The reload's own failure path: `Repo::reload_after_config_write` runs the reopen on the
/// FAILURE path too — `remove_remote`/`rename_remote` write the git config BEFORE the
/// git-ref edits that can still fail, so a mid-verb failure would otherwise leave a stale
/// gix config cache behind for the rest of the session.
///
/// Provoked by removing `.jj/working_copy` from under an open handle: `Workspace::load`
/// needs it, while the already-built repo loader does not — so the verbs still run and only
/// the reopen fails. Both halves of the contract are asserted, and the second assertion is
/// also what proves the reload really is failing (otherwise it would read as a success).
#[test]
fn a_failed_reload_is_surfaced_only_when_the_verb_itself_succeeded() {
    pin_env();
    let (tmp, _remote_dir, url) = git_workspace();
    let mut repo = Repo::open(tmp.path()).expect("open");
    fs::remove_dir_all(tmp.path().join(".jj").join("working_copy")).expect("remove working copy state");

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
    // The oracle is the raw git config, not another `Repo`: with `.jj/working_copy` gone,
    // `Workspace::load` fails for EVERY handle — which is itself the proof that the reload
    // above really failed rather than quietly succeeding.
    let (ok, out) = git_try(&["config", "--get", "remote.origin.url"], &git_store(tmp.path()));
    assert!(ok, "the remote really was written despite the Err");
    assert_eq!(
        out, url,
        "the mutation landed despite the Err — that is the documented trap"
    );
}
