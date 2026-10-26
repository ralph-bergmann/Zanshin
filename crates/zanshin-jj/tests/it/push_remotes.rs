// SPDX-License-Identifier: MIT

//! Story 9.54 witnesses for `Repo::git_push_remotes` — the remotes `jj git push` without
//! `--remote` would push to (`push.rs:294-323`, `get_default_push_remotes` `:1107-1130` @
//! v0.46.0), one per row of the I/O matrix. Remotes are added in-test with fake local URLs;
//! nothing is fetched or pushed.

use std::path::{Path, PathBuf};

use tempfile::TempDir;
use zanshin_jj::{Backend, ConfigScope, ConfigTarget, MutateError, Repo, WarningKind};

/// A fresh non-colocated Git-backed repo with `remotes` added, and `git_push` (a TOML value) as
/// the repo-level `git.push` when given.
fn repo_with(remotes: &[&str], git_push: Option<&str>) -> (TempDir, PathBuf, Repo) {
    test_helpers::pin_test_env();
    let tmp = TempDir::new().expect("tempdir");
    let mut repo = Repo::init(&zanshin_jj::InitOptions {
        path: tmp.path().to_path_buf(),
        backend: Some(Backend::Git),
        colocate: Some(false),
        ..Default::default()
    })
    .result
    .expect("init");
    let root = repo.workspace_root().to_owned();
    for name in remotes {
        let url = tmp.path().join(format!("{name}.git"));
        repo.git_remote_add(name, &url.to_string_lossy(), None)
            .expect("add remote");
    }
    if let Some(value) = git_push {
        set_git_push(&root, value);
    }
    let _ = repo.take_warnings();
    (tmp, root, repo)
}

fn set_git_push(root: &Path, value: &str) {
    zanshin_jj::config_set(Some(root), &ConfigTarget::Scope(ConfigScope::Repo), "git.push", value)
        .result
        .expect("config set");
}

fn names(list: &[&str]) -> Vec<String> {
    list.iter().map(|name| (*name).to_owned()).collect()
}

/// Without `git.push`, `origin` among several remotes.
#[test]
fn origin_is_the_default_among_several_remotes() {
    let (_tmp, _root, mut repo) = repo_with(&["origin", "upstream"], None);
    assert_eq!(repo.git_push_remotes().expect("remotes"), names(&["origin"]));
    assert!(repo.take_warnings().is_empty());
}

/// The single remote is the default, whatever its name — no hint, no warning.
#[test]
fn the_single_remote_is_the_default() {
    let (_tmp, _root, mut repo) = repo_with(&["fork"], None);
    assert_eq!(repo.git_push_remotes().expect("remotes"), names(&["fork"]));
    assert!(repo.take_warnings().is_empty());
}

/// No remote, or several without `origin`: nothing — not the push's refusal; the implicit
/// `origin` warns as the push warns it.
#[test]
fn no_matching_remote_is_an_empty_list() {
    for remotes in [&[][..], &["a", "b"][..]] {
        let (_tmp, _root, mut repo) = repo_with(remotes, None);
        assert!(repo.git_push_remotes().expect("remotes").is_empty());
        let warnings = repo.take_warnings();
        assert!(
            warnings
                .iter()
                .any(|w| w.kind == WarningKind::PushRemotesUnmatched
                    && w.message == "No matching remotes for names: origin"),
            "{warnings:?}"
        );
    }
}

/// `git.push` as a name, a list and a pattern — matched in remote-name order.
#[test]
fn git_push_names_the_remotes() {
    let (_tmp, root, mut repo) = repo_with(&["a", "b", "origin", "upstream"], Some("'upstream'"));
    assert_eq!(repo.git_push_remotes().expect("remotes"), names(&["upstream"]));
    set_git_push(&root, "['b', 'a']");
    assert_eq!(repo.git_push_remotes().expect("remotes"), names(&["a", "b"]));
    set_git_push(&root, "'glob:*r*'");
    assert_eq!(
        repo.git_push_remotes().expect("remotes"),
        names(&["origin", "upstream"])
    );
    assert!(repo.take_warnings().is_empty());
}

/// An exact `git.push` name no remote carries warns as the push warns; the rest still match.
#[test]
fn an_unmatched_git_push_name_warns() {
    let (_tmp, _root, mut repo) = repo_with(&["origin"], Some("['nope', 'origin']"));
    assert_eq!(repo.git_push_remotes().expect("remotes"), names(&["origin"]));
    let warnings = repo.take_warnings();
    assert!(
        warnings
            .iter()
            .any(|w| w.kind == WarningKind::PushRemotesUnmatched && w.message == "No matching remotes for names: nope"),
        "{warnings:?}"
    );
}

/// A wrong-typed `git.push` and a bad pattern refuse as the push refuses them.
#[test]
fn a_bad_git_push_refuses() {
    let (_tmp, root, mut repo) = repo_with(&["origin"], Some("1"));
    let err = repo.git_push_remotes().expect_err("wrong type");
    assert!(matches!(err, MutateError::Config { .. }), "{err:?}");
    set_git_push(&root, "'regex:('");
    let err = repo.git_push_remotes().expect_err("bad pattern");
    assert!(matches!(err, MutateError::InvalidInput { .. }), "{err:?}");
}

/// A native backend is refused, as `git push` refuses it (`push.rs:814`) — after `git.push` is
/// read, as the push reads it first.
#[test]
fn a_native_backend_is_not_a_git_repo() {
    let (_tmp, root, mut repo) = native_repo();
    let err = repo.git_push_remotes().expect_err("native");
    assert!(matches!(err, MutateError::NotAGitRepo), "{err:?}");
    set_git_push(&root, "1");
    let err = repo.git_push_remotes().expect_err("wrong type");
    assert!(matches!(err, MutateError::Config { .. }), "{err:?}");
}

/// A native-backend repo the push's remote resolution runs against (Story 9.56).
fn native_repo() -> (TempDir, PathBuf, Repo) {
    test_helpers::pin_test_env();
    let tmp = TempDir::new().expect("tempdir");
    let repo = Repo::init(&zanshin_jj::InitOptions {
        path: tmp.path().to_path_buf(),
        ..Default::default()
    })
    .result
    .expect("init");
    let root = repo.workspace_root().to_owned();
    (tmp, root, repo)
}

fn push(repo: &mut Repo, args: &zanshin_jj::GitPushArgs) -> Result<zanshin_jj::GitPushOutcome, MutateError> {
    repo.git_push(args, &|_: zanshin_jj::ProgressEvent| {}, None)
}

/// Story 9.56: `git.push` is read before the remotes are listed, as the CLI reads it
/// (`push.rs:294-301` @ v0.46.0) — the fetch's order: without a Git backend a malformed one still
/// refuses as `Config`, not `NotAGitRepo`.
#[test]
fn a_malformed_git_push_setting_refuses_before_the_backend_check() {
    let (_tmp, root, mut repo) = native_repo();
    set_git_push(&root, "1");
    let err = push(&mut repo, &zanshin_jj::GitPushArgs::default()).expect_err("malformed");
    assert!(
        matches!(&err, MutateError::Config { reason } if reason.contains("git.push")),
        "{err:?}"
    );
}

/// Story 9.56: `--remote` patterns are parsed before the remotes are listed: without a Git
/// backend an unparsable one still refuses as `InvalidInput`, not `NotAGitRepo`; a parsable one
/// reaches the backend check.
#[test]
fn an_unparsable_push_remote_pattern_refuses_before_the_backend_check() {
    let (_tmp, _root, mut repo) = native_repo();
    let args = |pattern: &str| zanshin_jj::GitPushArgs {
        remotes: Some(vec![pattern.to_owned()]),
        ..zanshin_jj::GitPushArgs::default()
    };
    let err = push(&mut repo, &args("regex:(")).expect_err("unparsable");
    assert!(matches!(err, MutateError::InvalidInput { .. }), "{err:?}");
    let err = push(&mut repo, &args("origin")).expect_err("no Git backend");
    assert!(matches!(err, MutateError::NotAGitRepo), "{err:?}");
}
