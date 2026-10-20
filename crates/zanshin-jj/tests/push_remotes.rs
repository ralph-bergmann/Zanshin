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

/// No remote, or several without `origin`: nothing — not the push's refusal.
#[test]
fn no_matching_remote_is_an_empty_list() {
    let (_tmp, _root, mut repo) = repo_with(&[], None);
    assert!(repo.git_push_remotes().expect("remotes").is_empty());
    let (_tmp, _root, mut repo) = repo_with(&["a", "b"], None);
    assert!(repo.git_push_remotes().expect("remotes").is_empty());
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

/// A native backend has no remotes to push to.
#[test]
fn a_native_backend_has_none() {
    test_helpers::pin_test_env();
    let tmp = TempDir::new().expect("tempdir");
    let mut repo = Repo::init(&zanshin_jj::InitOptions {
        path: tmp.path().to_path_buf(),
        ..Default::default()
    })
    .result
    .expect("init");
    assert!(repo.git_push_remotes().expect("remotes").is_empty());
}
