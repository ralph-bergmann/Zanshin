// SPDX-License-Identifier: MIT

//! Story 9.30 witnesses for `Repo::git_fetch`'s remote and ref selection and
//! `Repo::git_fetch_remotes` — one test per row of the spec's I/O matrix, against
//! `cmd_git_fetch` (`cli/src/commands/git/fetch.rs` @ v0.46.0). Upstreams are local bare
//! repos built in-test with plain `git` (fixture setup only); nothing reaches the network.

use std::path::{Path, PathBuf};
use std::process::Command;

use jj_lib::default_backend_factories::{default_backend_factories, default_working_copy_factories};
use jj_lib::object_id::ObjectId;
use jj_lib::ref_name::{RefName, RemoteName};
use jj_lib::workspace::Workspace;
use tempfile::TempDir;
use zanshin_jj::{
    Backend, BookmarkKind, ConfigScope, ConfigTarget, FetchRefs, FetchRemotes, GitFetchArgs, GitFetchOutcome,
    MutateError, ProgressEvent, RemoteRefChangeKind, Repo, TagKind, Warning, WarningKind,
};

/// Runs `git` in `dir`; panics on a non-zero exit. Returns trimmed stdout.
fn git(args: &[&str], dir: &Path) -> String {
    let out = Command::new("git")
        .args(args)
        .current_dir(dir)
        .output()
        .expect("git spawns");
    assert!(
        out.status.success(),
        "git {args:?} failed in {}: {}",
        dir.display(),
        String::from_utf8_lossy(&out.stderr)
    );
    String::from_utf8_lossy(&out.stdout).trim().to_owned()
}

/// A Git working repo and the bare repo it publishes to — the remote a jj repo fetches from.
#[derive(Debug)]
struct Upstream {
    work: PathBuf,
    bare: PathBuf,
}

impl Upstream {
    /// A working repo with one commit on `main`, published to `<dir>/<name>.git`.
    fn new(dir: &Path, name: &str) -> Self {
        let work = dir.join(format!("{name}-work"));
        std::fs::create_dir_all(&work).expect("work dir");
        git(&["init", "-q", "--initial-branch=main"], &work);
        git(&["config", "user.email", "test@zanshin.test"], &work);
        git(&["config", "user.name", "Fixture"], &work);
        let bare = dir.join(format!("{name}.git"));
        git(&["init", "-q", "--bare", &bare.to_string_lossy()], dir);
        let upstream = Self { work, bare };
        upstream.commit("main", "initial");
        upstream
    }

    /// Commits `content` on `branch` (created off `main` when new) and publishes.
    fn commit(&self, branch: &str, content: &str) -> &Self {
        let exists = Command::new("git")
            .args(["rev-parse", "--verify", "-q", &format!("refs/heads/{branch}")])
            .current_dir(&self.work)
            .output()
            .expect("git spawns")
            .status
            .success();
        if exists {
            git(&["checkout", "-q", branch], &self.work);
        } else if branch == "main" {
            // The unborn `main` of a fresh repo.
        } else {
            git(&["checkout", "-q", "-b", branch, "main"], &self.work);
        }
        std::fs::write(self.work.join(format!("{branch}.txt")), content).expect("write");
        git(&["add", "."], &self.work);
        git(&["commit", "-q", "-m", content], &self.work);
        self.publish()
    }

    /// Tags `main` as `tag` and publishes.
    fn tag(&self, tag: &str) -> &Self {
        git(&["tag", tag, "main"], &self.work);
        self.publish()
    }

    /// Moves `tag` to `main` and publishes.
    fn retag(&self, tag: &str) -> &Self {
        git(&["tag", "-f", tag, "main"], &self.work);
        self.publish()
    }

    fn publish(&self) -> &Self {
        git(&["push", "-q", "--mirror", &self.bare.to_string_lossy()], &self.work);
        self
    }

    fn url(&self) -> String {
        self.bare.to_string_lossy().into_owned()
    }

    /// The commit id `branch` points at.
    fn head(&self, branch: &str) -> String {
        git(&["rev-parse", branch], &self.work)
    }
}

/// A fresh non-colocated Git-backed jj repo with `remotes` added, each at its upstream.
struct Fx {
    tmp: TempDir,
    root: PathBuf,
    repo: Repo,
}

impl Fx {
    fn new(remotes: &[(&str, &Upstream)]) -> Self {
        test_helpers::pin_test_env();
        let tmp = TempDir::new().expect("tempdir");
        let path = tmp.path().join("repo");
        let mut repo = Repo::init(&zanshin_jj::InitOptions {
            path: path.clone(),
            backend: Some(Backend::Git),
            colocate: Some(false),
            ..Default::default()
        })
        .result
        .expect("init");
        for (name, upstream) in remotes {
            repo.git_remote_add(name, &upstream.url(), None).expect("add remote");
        }
        let root = repo.workspace_root().to_owned();
        let _ = repo.take_warnings();
        Self { tmp, root, repo }
    }

    /// Sets `key` (a TOML `value`) in the repo-level config.
    fn set(&mut self, key: &str, value: &str) {
        zanshin_jj::config_set(Some(&self.root), &ConfigTarget::Scope(ConfigScope::Repo), key, value)
            .result
            .expect("config set");
    }

    fn fetch(&mut self, args: &GitFetchArgs) -> Result<GitFetchOutcome, MutateError> {
        self.repo.git_fetch(args, &|_: ProgressEvent| {}, None)
    }

    fn head_op(&mut self) -> (String, String) {
        let op = self.repo.op_log(Some(1)).expect("op log").swap_remove(0);
        (op.id.0, op.description)
    }

    /// The commit-id hex of `<name>@<remote>`, tracked or not.
    fn remote_bookmark(&mut self, name: &str, remote: &str) -> Option<String> {
        let target = self
            .repo
            .list_bookmarks()
            .expect("bookmarks")
            .into_iter()
            .find(|b| {
                b.name == name && matches!(&b.kind, BookmarkKind::Remote { remote_name, .. } if remote_name == remote)
            })?
            .target?;
        let mut ids = Vec::new();
        let _ = self
            .repo
            .eval_revset(&format!("change_id({})", target.0), |change| {
                ids.push(change.commit_id.0);
                std::ops::ControlFlow::Continue(())
            })
            .expect("eval");
        ids.pop()
    }

    /// The commit-id hex of the remote tag `<name>@<remote>`, tracked or not, read off the view.
    fn remote_tag(&self, name: &str, remote: &str) -> Option<String> {
        let readonly = self.load_head();
        let symbol = RefName::new(name).to_remote_symbol(RemoteName::new(remote));
        let hex = readonly
            .view()
            .get_remote_tag(symbol)
            .target
            .as_normal()
            .map(ObjectId::hex);
        hex
    }

    /// Untracks the remote tag `<name>@<remote>` (no Zanshin verb does it yet).
    fn untrack_tag(&self, name: &str, remote: &str) {
        let readonly = self.load_head();
        let mut tx = readonly.start_transaction();
        tx.repo_mut()
            .untrack_remote_tag(RefName::new(name).to_remote_symbol(RemoteName::new(remote)));
        pollster::block_on(tx.commit("untrack tag")).expect("commit");
    }

    fn load_head(&self) -> std::sync::Arc<jj_lib::repo::ReadonlyRepo> {
        let workspace = Workspace::load(
            &test_helpers::test_settings(),
            &self.root,
            &default_backend_factories(),
            &default_working_copy_factories(),
        )
        .expect("load workspace");
        pollster::block_on(workspace.repo_loader().load_at_head()).expect("load head")
    }

    /// The names of the tags tracked from `remote`.
    fn remote_tags(&mut self, remote: &str) -> Vec<String> {
        self.repo
            .list_tags()
            .expect("tags")
            .into_iter()
            .filter(|t| matches!(&t.kind, TagKind::Remote { remote_name } if remote_name == remote))
            .map(|t| t.name)
            .collect()
    }
}

fn named(names: &[&str]) -> GitFetchArgs {
    GitFetchArgs {
        remotes: FetchRemotes::Named(names.iter().map(|n| (*n).to_owned()).collect()),
        refs: FetchRefs::Default,
    }
}

fn strings(list: &[&str]) -> Vec<String> {
    list.iter().map(|s| (*s).to_owned()).collect()
}

fn has(warnings: &[Warning], kind: WarningKind, message: &str) -> bool {
    warnings.iter().any(|w| w.kind == kind && w.message == message)
}

/// Asserts the refusal "No git remotes to fetch from", its warning and that no operation was
/// written.
fn assert_refused(fx: &mut Fx, args: &GitFetchArgs, unmatched: &str) {
    let (before, _) = fx.head_op();
    let err = fx.fetch(args).expect_err("nothing to fetch from");
    let warnings = fx.repo.take_warnings();
    assert!(
        matches!(&err, MutateError::InvalidInput { reason } if reason == "No git remotes to fetch from"),
        "{err:?}"
    );
    assert!(
        has(
            &warnings,
            WarningKind::FetchRemotesUnmatched,
            &format!("No matching remotes for names: {unmatched}")
        ),
        "{warnings:?}"
    );
    assert_eq!(fx.head_op().0, before, "a refusal writes no operation");
}

#[test]
fn default_fetches_origin_without_a_hint() {
    let dir = TempDir::new().unwrap();
    let origin = Upstream::new(dir.path(), "origin");
    let mut fx = Fx::new(&[("origin", &origin)]);
    let outcome = fx.fetch(&GitFetchArgs::default()).expect("fetch");
    assert_eq!(outcome.remotes, strings(&["origin"]));
    assert!(outcome.hints.is_empty(), "{:?}", outcome.hints);
    assert!(outcome.failed_ref_names.is_empty());
    let (op, description) = fx.head_op();
    assert_eq!(op, outcome.mutation.new_op_id.0);
    assert_eq!(description, "fetch from git remote(s) origin");
    assert_eq!(fx.remote_bookmark("main", "origin"), Some(origin.head("main")));
}

#[test]
fn default_fetches_the_only_remote_with_the_cli_hint() {
    let dir = TempDir::new().unwrap();
    let up = Upstream::new(dir.path(), "up");
    let mut fx = Fx::new(&[("up", &up)]);
    let outcome = fx.fetch(&GitFetchArgs::default()).expect("fetch");
    assert_eq!(outcome.remotes, strings(&["up"]));
    assert_eq!(outcome.hints, strings(&["Fetching from the only existing remote: up"]));
    assert_eq!(fx.head_op().1, "fetch from git remote(s) up");
    assert_eq!(fx.remote_bookmark("main", "up"), Some(up.head("main")));
}

#[test]
fn default_picks_origin_among_several_remotes() {
    let dir = TempDir::new().unwrap();
    let (origin, up) = (Upstream::new(dir.path(), "origin"), Upstream::new(dir.path(), "up"));
    let mut fx = Fx::new(&[("origin", &origin), ("up", &up)]);
    let outcome = fx.fetch(&GitFetchArgs::default()).expect("fetch");
    assert_eq!(outcome.remotes, strings(&["origin"]));
    assert!(outcome.hints.is_empty());
    assert_eq!(fx.remote_bookmark("main", "up"), None, "up is not fetched");
}

#[test]
fn default_without_origin_among_several_remotes_refuses() {
    let dir = TempDir::new().unwrap();
    let (up, up2) = (Upstream::new(dir.path(), "up"), Upstream::new(dir.path(), "up2"));
    let mut fx = Fx::new(&[("up", &up), ("up2", &up2)]);
    assert_refused(&mut fx, &GitFetchArgs::default(), "origin");
}

#[test]
fn git_fetch_names_the_remotes_in_remote_order() {
    let dir = TempDir::new().unwrap();
    let (origin, up) = (Upstream::new(dir.path(), "origin"), Upstream::new(dir.path(), "up"));
    let mut fx = Fx::new(&[("origin", &origin), ("up", &up)]);
    fx.set("git.fetch", "['up', 'origin']");
    let outcome = fx.fetch(&GitFetchArgs::default()).expect("fetch both");
    assert_eq!(outcome.remotes, strings(&["origin", "up"]));
    assert_eq!(fx.head_op().1, "fetch from git remote(s) origin,up");

    up.commit("main", "second");
    fx.set("git.fetch", "'up'");
    let outcome = fx.fetch(&GitFetchArgs::default()).expect("fetch up");
    assert_eq!(outcome.remotes, strings(&["up"]));
    assert!(outcome.hints.is_empty(), "a configured remote has no hint");
    assert_eq!(fx.head_op().1, "fetch from git remote(s) up");
    assert_eq!(fx.remote_bookmark("main", "up"), Some(up.head("main")));
}

#[test]
fn named_remotes_warn_about_a_name_no_remote_carries() {
    let dir = TempDir::new().unwrap();
    let origin = Upstream::new(dir.path(), "origin");
    let mut fx = Fx::new(&[("origin", &origin)]);
    let outcome = fx.fetch(&named(&["origin", "nope"])).expect("fetch origin");
    let warnings = fx.repo.take_warnings();
    assert_eq!(outcome.remotes, strings(&["origin"]));
    assert!(
        has(
            &warnings,
            WarningKind::FetchRemotesUnmatched,
            "No matching remotes for names: nope"
        ),
        "{warnings:?}"
    );
    assert_eq!(fx.remote_bookmark("main", "origin"), Some(origin.head("main")));
}

#[test]
fn named_remotes_that_match_nothing_refuse() {
    let dir = TempDir::new().unwrap();
    let origin = Upstream::new(dir.path(), "origin");
    let mut fx = Fx::new(&[("origin", &origin)]);
    assert_refused(&mut fx, &named(&["nope"]), "nope");
}

#[test]
fn all_remotes_are_fetched_in_one_operation() {
    let dir = TempDir::new().unwrap();
    let (origin, up) = (Upstream::new(dir.path(), "origin"), Upstream::new(dir.path(), "up"));
    let mut fx = Fx::new(&[("origin", &origin), ("up", &up)]);
    let before = fx.repo.op_log(None).expect("op log").len();
    let outcome = fx
        .fetch(&GitFetchArgs {
            remotes: FetchRemotes::All,
            refs: FetchRefs::Default,
        })
        .expect("fetch all");
    assert_eq!(outcome.remotes, strings(&["origin", "up"]));
    assert_eq!(fx.repo.op_log(None).expect("op log").len(), before + 1, "ONE operation");
    assert_eq!(fx.head_op().1, "fetch from git remote(s) origin,up");
    assert_eq!(fx.remote_bookmark("main", "origin"), Some(origin.head("main")));
    assert_eq!(fx.remote_bookmark("main", "up"), Some(up.head("main")));
}

#[test]
fn branch_patterns_fetch_only_the_matching_branches_and_no_tag() {
    let dir = TempDir::new().unwrap();
    let origin = Upstream::new(dir.path(), "origin");
    origin.commit("feat1", "feature").tag("v1");
    let mut fx = Fx::new(&[("origin", &origin)]);
    let outcome = fx
        .fetch(&GitFetchArgs {
            remotes: FetchRemotes::Default,
            refs: FetchRefs::Patterns {
                branches: strings(&["feat*"]),
                tags: Vec::new(),
            },
        })
        .expect("fetch");
    assert!(fx.repo.take_warnings().is_empty());
    assert_eq!(outcome.remotes, strings(&["origin"]));
    assert_eq!(fx.remote_bookmark("feat1", "origin"), Some(origin.head("feat1")));
    assert_eq!(fx.remote_bookmark("main", "origin"), None);
    assert!(fx.remote_tags("origin").is_empty(), "an empty tag list fetches no tag");
}

#[test]
fn a_branch_name_no_remote_has_warns() {
    let dir = TempDir::new().unwrap();
    let origin = Upstream::new(dir.path(), "origin");
    let mut fx = Fx::new(&[("origin", &origin)]);
    fx.fetch(&GitFetchArgs {
        remotes: FetchRemotes::Default,
        refs: FetchRefs::Patterns {
            branches: strings(&["nope", "main"]),
            tags: Vec::new(),
        },
    })
    .expect("fetch");
    let warnings = fx.repo.take_warnings();
    assert!(
        has(
            &warnings,
            WarningKind::FetchBranchesUnmatched,
            "No matching branches found on any specified/configured remote: nope"
        ),
        "{warnings:?}"
    );
    assert_eq!(fx.remote_bookmark("main", "origin"), Some(origin.head("main")));
}

#[test]
fn tracked_fetches_only_the_tracked_bookmarks() {
    let dir = TempDir::new().unwrap();
    let origin = Upstream::new(dir.path(), "origin");
    origin.commit("a", "a1").commit("b", "b1");
    let mut fx = Fx::new(&[("origin", &origin)]);
    fx.set("remotes.origin.auto-track-bookmarks", "'exact:a'");
    fx.fetch(&GitFetchArgs::default()).expect("first fetch");
    let (old_a, old_b) = (origin.head("a"), origin.head("b"));
    origin.commit("a", "a2").commit("b", "b2");

    fx.fetch(&GitFetchArgs {
        remotes: FetchRemotes::Default,
        refs: FetchRefs::Tracked,
    })
    .expect("tracked fetch");
    assert_ne!(origin.head("a"), old_a);
    assert_eq!(
        fx.remote_bookmark("a", "origin"),
        Some(origin.head("a")),
        "a is tracked"
    );
    assert_eq!(fx.remote_bookmark("b", "origin"), Some(old_b), "b is not tracked");
}

#[test]
fn remote_fetch_bookmarks_selects_the_default_branches() {
    let dir = TempDir::new().unwrap();
    let origin = Upstream::new(dir.path(), "origin");
    origin.commit("other", "other");
    let mut fx = Fx::new(&[("origin", &origin)]);
    fx.set("remotes.origin.fetch-bookmarks", "'main'");
    fx.fetch(&GitFetchArgs::default()).expect("fetch");
    assert_eq!(fx.remote_bookmark("main", "origin"), Some(origin.head("main")));
    assert_eq!(fx.remote_bookmark("other", "origin"), None);
}

#[test]
fn remote_fetch_tags_selects_the_default_tags() {
    let dir = TempDir::new().unwrap();
    let origin = Upstream::new(dir.path(), "origin");
    origin.tag("v1").tag("x1");
    let mut fx = Fx::new(&[("origin", &origin)]);
    fx.set("remotes.origin.fetch-tags", "'v*'");
    fx.fetch(&GitFetchArgs::default()).expect("fetch");
    assert_eq!(fx.remote_tags("origin"), strings(&["v1"]));
}

#[test]
fn a_git_refspec_jj_ignores_warns_and_the_fetch_goes_on() {
    let dir = TempDir::new().unwrap();
    let origin = Upstream::new(dir.path(), "origin");
    let fx = Fx::new(&[("origin", &origin)]);
    let git_dir = fx.root.join(".jj").join("repo").join("store").join("git");
    git(
        &[
            "--git-dir",
            &git_dir.to_string_lossy(),
            "config",
            "--add",
            "remote.origin.fetch",
            "+refs/pull/*/head:refs/remotes/origin/pr/*",
        ],
        fx.tmp.path(),
    );
    // A fresh handle, so the Git backend re-reads the edited Git config.
    let Fx { tmp, root, .. } = fx;
    let mut fx = Fx {
        repo: Repo::open(&root).expect("reopen"),
        tmp,
        root,
    };
    fx.fetch(&GitFetchArgs::default()).expect("fetch");
    let warnings = fx.repo.take_warnings();
    assert!(
        has(
            &warnings,
            WarningKind::FetchRefspecIgnored,
            "Ignored refspec `+refs/pull/*/head:refs/remotes/origin/pr/*` from `origin`: only refs/heads/ is \
             supported for refspec sources"
        ),
        "{warnings:?}"
    );
    assert_eq!(fx.remote_bookmark("main", "origin"), Some(origin.head("main")));
}

#[test]
fn a_malformed_remote_fetch_setting_is_a_config_error() {
    let dir = TempDir::new().unwrap();
    let origin = Upstream::new(dir.path(), "origin");
    let mut fx = Fx::new(&[("origin", &origin)]);
    fx.set("remotes.origin.fetch-bookmarks", "'glob:('");
    let (before, _) = fx.head_op();
    let err = fx.fetch(&GitFetchArgs::default()).expect_err("malformed");
    assert!(
        matches!(&err, MutateError::Config { reason } if reason.contains("Invalid `remotes.origin.fetch-bookmarks`: ")),
        "{err:?}"
    );
    assert_eq!(fx.head_op().0, before);
}

#[test]
fn a_malformed_git_fetch_setting_is_a_config_error() {
    let dir = TempDir::new().unwrap();
    let origin = Upstream::new(dir.path(), "origin");
    let mut fx = Fx::new(&[("origin", &origin)]);
    fx.set("git.fetch", "1");
    let (before, _) = fx.head_op();
    let err = fx.fetch(&GitFetchArgs::default()).expect_err("malformed");
    assert!(
        matches!(&err, MutateError::Config { reason } if reason.contains("git.fetch")),
        "{err:?}"
    );
    assert_eq!(fx.head_op().0, before);
}

#[test]
fn a_native_backend_is_not_a_git_repo() {
    test_helpers::pin_test_env();
    let tmp = TempDir::new().expect("tempdir");
    let mut repo = Repo::init(&zanshin_jj::InitOptions {
        path: tmp.path().to_path_buf(),
        ..Default::default()
    })
    .result
    .expect("init");
    let err = repo
        .git_fetch(&GitFetchArgs::default(), &|_: ProgressEvent| {}, None)
        .expect_err("native");
    assert!(matches!(err, MutateError::NotAGitRepo), "{err:?}");
    assert!(repo.git_fetch_remotes().expect("remotes").is_empty());
}

/// One `Default` row: the remotes, `git.fetch` (TOML), the expected answer, the unmatched name.
type DefaultRow<'a> = (
    &'a [(&'a str, &'a Upstream)],
    Option<&'a str>,
    &'a [&'a str],
    Option<&'a str>,
);

/// `git_fetch_remotes` answers every `Default` row as the fetch resolves it, with the same
/// warnings, and writes no operation.
#[test]
fn git_fetch_remotes_resolves_each_default_row() {
    let dir = TempDir::new().unwrap();
    let (origin, up) = (Upstream::new(dir.path(), "origin"), Upstream::new(dir.path(), "up"));
    let up2 = Upstream::new(dir.path(), "up2");
    let cases: [DefaultRow<'_>; 6] = [
        (&[("origin", &origin)], None, &["origin"], None),
        (&[("up", &up)], None, &["up"], None),
        (&[("origin", &origin), ("up", &up)], None, &["origin"], None),
        (&[("up", &up), ("up2", &up2)], None, &[], Some("origin")),
        (
            &[("origin", &origin), ("up", &up)],
            Some("['up', 'origin']"),
            &["origin", "up"],
            None,
        ),
        (
            &[("origin", &origin)],
            Some("['nope', 'origin']"),
            &["origin"],
            Some("nope"),
        ),
    ];
    for (remotes, git_fetch, expected, unmatched) in cases {
        let mut fx = Fx::new(remotes);
        if let Some(value) = git_fetch {
            fx.set("git.fetch", value);
        }
        let (before, _) = fx.head_op();
        assert_eq!(
            fx.repo.git_fetch_remotes().expect("remotes"),
            strings(expected),
            "{remotes:?}"
        );
        let warnings = fx.repo.take_warnings();
        match unmatched {
            Some(name) => assert!(
                has(
                    &warnings,
                    WarningKind::FetchRemotesUnmatched,
                    &format!("No matching remotes for names: {name}")
                ),
                "{warnings:?}"
            ),
            None => assert!(warnings.is_empty(), "{warnings:?}"),
        }
        assert_eq!(fx.head_op().0, before, "the query writes no operation");
    }
}

/// A ref in jj's reserved `refs/remotes/git/` namespace of the backing Git repo fails the
/// fetch's import: it warns `jj.git_import_failed` and is reported by name.
#[test]
fn a_ref_the_import_cannot_read_is_reported() {
    let dir = TempDir::new().unwrap();
    let origin = Upstream::new(dir.path(), "origin");
    let mut fx = Fx::new(&[("origin", &origin)]);
    fx.fetch(&GitFetchArgs::default()).expect("first fetch");
    let git_dir = fx.root.join(".jj").join("repo").join("store").join("git");
    git(
        &[
            "--git-dir",
            &git_dir.to_string_lossy(),
            "update-ref",
            "refs/remotes/git/stolen",
            &origin.head("main"),
        ],
        fx.tmp.path(),
    );
    origin.commit("main", "second");
    let outcome = fx.fetch(&GitFetchArgs::default()).expect("second fetch");
    let warnings = fx.repo.take_warnings();
    assert_eq!(outcome.failed_ref_names, strings(&["refs/remotes/git/stolen"]));
    assert!(
        has(
            &warnings,
            WarningKind::GitImportFailed,
            "Failed to import some Git refs:\n  refs/remotes/git/stolen"
        ),
        "{warnings:?}"
    );
}

/// The poll asks only about the refs a bare fetch would fetch (I4): with
/// `remotes.origin.fetch-bookmarks = "main"`, a new upstream `other` is not reported, a moved
/// `main` still is.
#[test]
fn the_poll_is_filtered_like_the_fetch() {
    let dir = TempDir::new().unwrap();
    let origin = Upstream::new(dir.path(), "origin");
    let mut fx = Fx::new(&[("origin", &origin)]);
    fx.set("remotes.origin.fetch-bookmarks", "'main'");
    fx.fetch(&GitFetchArgs::default()).expect("fetch");
    origin.commit("main", "second").commit("other", "other");
    let changes = fx.repo.remote_changes("origin", None).expect("poll");
    let names: Vec<(&str, RemoteRefChangeKind)> = changes.iter().map(|c| (c.name.as_str(), c.change)).collect();
    assert_eq!(names, [("main", RemoteRefChangeKind::Moved)], "{changes:?}");
}

#[test]
fn tag_patterns_fetch_only_the_matching_tags_and_no_branch() {
    let dir = TempDir::new().unwrap();
    let origin = Upstream::new(dir.path(), "origin");
    origin.tag("v1").tag("x1");
    let mut fx = Fx::new(&[("origin", &origin)]);
    fx.fetch(&GitFetchArgs {
        remotes: FetchRemotes::Default,
        refs: FetchRefs::Patterns {
            branches: Vec::new(),
            tags: strings(&["v*"]),
        },
    })
    .expect("fetch");
    assert_eq!(fx.remote_tags("origin"), strings(&["v1"]));
    assert_eq!(
        fx.remote_bookmark("main", "origin"),
        None,
        "an empty branch list fetches no branch"
    );
}

#[test]
fn tracked_fetches_only_the_tracked_tags() {
    let dir = TempDir::new().unwrap();
    let origin = Upstream::new(dir.path(), "origin");
    origin.tag("v1").tag("x1");
    let mut fx = Fx::new(&[("origin", &origin)]);
    fx.fetch(&GitFetchArgs::default()).expect("first fetch");
    fx.untrack_tag("x1", "origin");
    let old = origin.head("main");
    origin.commit("main", "second").retag("v1").retag("x1");

    fx.fetch(&GitFetchArgs {
        remotes: FetchRemotes::Default,
        refs: FetchRefs::Tracked,
    })
    .expect("tracked fetch");
    assert_eq!(
        fx.remote_tag("v1", "origin"),
        Some(origin.head("main")),
        "v1 is tracked"
    );
    assert_eq!(fx.remote_tag("x1", "origin"), Some(old), "x1 is not tracked");
}

/// `--tracked` still reads every `remotes.<name>` entry, as the CLI's `remote_settings()` does.
#[test]
fn tracked_refuses_a_malformed_remote_entry() {
    let dir = TempDir::new().unwrap();
    let origin = Upstream::new(dir.path(), "origin");
    let mut fx = Fx::new(&[("origin", &origin)]);
    fx.set("remotes.origin.fetch-bookmarks", "1");
    let (before, _) = fx.head_op();
    let err = fx
        .fetch(&GitFetchArgs {
            remotes: FetchRemotes::Default,
            refs: FetchRefs::Tracked,
        })
        .expect_err("malformed entry");
    assert!(matches!(err, MutateError::Config { .. }), "{err:?}");
    assert_eq!(fx.head_op().0, before);
}

/// The poll's tag filter: with `remotes.origin.fetch-tags = "v*"`, a new `v2` is reported and a
/// new `x1` is not.
#[test]
fn the_poll_filters_tags_like_the_fetch() {
    let dir = TempDir::new().unwrap();
    let origin = Upstream::new(dir.path(), "origin");
    let mut fx = Fx::new(&[("origin", &origin)]);
    fx.set("remotes.origin.fetch-tags", "'v*'");
    fx.fetch(&GitFetchArgs::default()).expect("fetch");
    origin.tag("v2").tag("x1");
    let changes = fx.repo.remote_changes("origin", None).expect("poll");
    let names: Vec<(&str, RemoteRefChangeKind)> = changes.iter().map(|c| (c.name.as_str(), c.change)).collect();
    assert_eq!(names, [("v2", RemoteRefChangeKind::New)], "{changes:?}");
}

/// A malformed filter refuses the poll as `Config`; a pattern the fetch cannot turn into a
/// refspec refuses both as `InvalidInput`.
#[test]
fn the_poll_refuses_what_the_fetch_refuses() {
    let dir = TempDir::new().unwrap();
    let origin = Upstream::new(dir.path(), "origin");
    let mut fx = Fx::new(&[("origin", &origin)]);
    fx.set("remotes.origin.fetch-bookmarks", "'glob:('");
    let err = fx.repo.remote_changes("origin", None).expect_err("malformed");
    assert!(
        matches!(&err, MutateError::Config { reason } if reason.contains("Invalid `remotes.origin.fetch-bookmarks`: ")),
        "{err:?}"
    );

    fx.set("remotes.origin.fetch-bookmarks", "'glob:\"a?b\"'");
    let err = fx.repo.remote_changes("origin", None).expect_err("no refspec");
    assert!(matches!(err, MutateError::InvalidInput { .. }), "{err:?}");
    let err = fx.fetch(&GitFetchArgs::default()).expect_err("no refspec");
    assert!(matches!(err, MutateError::InvalidInput { .. }), "{err:?}");
}

/// Without `remotes.origin.fetch-bookmarks`, the remote's Git fetch refspecs pick the default
/// branches (`load_default_fetch_bookmarks`) — for the fetch and for the poll alike.
#[test]
fn a_narrowed_git_refspec_selects_the_default_branches() {
    let dir = TempDir::new().unwrap();
    let origin = Upstream::new(dir.path(), "origin");
    origin.commit("other", "other");
    let fx = Fx::new(&[("origin", &origin)]);
    let git_dir = fx.root.join(".jj").join("repo").join("store").join("git");
    git(
        &[
            "--git-dir",
            &git_dir.to_string_lossy(),
            "config",
            "remote.origin.fetch",
            "+refs/heads/main:refs/remotes/origin/main",
        ],
        fx.tmp.path(),
    );
    // A fresh handle, so the Git backend re-reads the edited Git config.
    let Fx { tmp, root, .. } = fx;
    let mut fx = Fx {
        repo: Repo::open(&root).expect("reopen"),
        tmp,
        root,
    };
    fx.fetch(&GitFetchArgs::default()).expect("fetch");
    assert!(fx.repo.take_warnings().is_empty());
    assert_eq!(fx.remote_bookmark("main", "origin"), Some(origin.head("main")));
    assert_eq!(
        fx.remote_bookmark("other", "origin"),
        None,
        "the refspec excludes other"
    );

    origin.commit("main", "second").commit("other", "other2");
    let changes = fx.repo.remote_changes("origin", None).expect("poll");
    let names: Vec<(&str, RemoteRefChangeKind)> = changes.iter().map(|c| (c.name.as_str(), c.change)).collect();
    assert_eq!(names, [("main", RemoteRefChangeKind::Moved)], "{changes:?}");
}

fn branches(names: &[&str], remotes: FetchRemotes) -> GitFetchArgs {
    GitFetchArgs {
        remotes,
        refs: FetchRefs::Patterns {
            branches: strings(names),
            tags: Vec::new(),
        },
    }
}

/// `warn_if_branches_not_found`: a name is missing only when NO matched remote has it — one
/// remote carrying it is enough.
#[test]
fn a_branch_name_one_of_several_remotes_has_does_not_warn() {
    let dir = TempDir::new().unwrap();
    let (origin, up) = (Upstream::new(dir.path(), "origin"), Upstream::new(dir.path(), "up"));
    origin.commit("feat", "feature");
    let mut fx = Fx::new(&[("origin", &origin), ("up", &up)]);
    let outcome = fx.fetch(&branches(&["feat"], FetchRemotes::All)).expect("fetch");
    assert_eq!(outcome.remotes, strings(&["origin", "up"]));
    let warnings = fx.repo.take_warnings();
    assert!(
        !warnings.iter().any(|w| w.kind == WarningKind::FetchBranchesUnmatched),
        "{warnings:?}"
    );
    assert_eq!(fx.remote_bookmark("feat", "origin"), Some(origin.head("feat")));
}

/// `warn_if_branches_not_found` also looks at the base view: a branch deleted upstream since the
/// last fetch was there, so naming it does not warn.
#[test]
fn a_branch_deleted_upstream_since_the_last_fetch_does_not_warn() {
    let dir = TempDir::new().unwrap();
    let origin = Upstream::new(dir.path(), "origin");
    origin.commit("feat", "feature");
    let mut fx = Fx::new(&[("origin", &origin)]);
    fx.fetch(&branches(&["feat"], FetchRemotes::Default))
        .expect("first fetch");
    assert_eq!(fx.remote_bookmark("feat", "origin"), Some(origin.head("feat")));

    git(&["checkout", "-q", "main"], &origin.work);
    git(&["branch", "-q", "-D", "feat"], &origin.work);
    origin.publish();
    let _ = fx.repo.take_warnings();
    fx.fetch(&branches(&["feat"], FetchRemotes::Default))
        .expect("second fetch");
    let warnings = fx.repo.take_warnings();
    assert!(
        !warnings.iter().any(|w| w.kind == WarningKind::FetchBranchesUnmatched),
        "{warnings:?}"
    );
    assert_eq!(fx.remote_bookmark("feat", "origin"), None, "the deletion is imported");
}

/// `warn_if_branches_not_found` names only the exact names the pattern ACCEPTS: a negated name
/// is no missing branch.
#[test]
fn a_negated_branch_name_does_not_warn() {
    let dir = TempDir::new().unwrap();
    let origin = Upstream::new(dir.path(), "origin");
    let mut fx = Fx::new(&[("origin", &origin)]);
    fx.fetch(&branches(&["~nope"], FetchRemotes::Default)).expect("fetch");
    let warnings = fx.repo.take_warnings();
    assert!(
        !warnings.iter().any(|w| w.kind == WarningKind::FetchBranchesUnmatched),
        "{warnings:?}"
    );
    assert_eq!(fx.remote_bookmark("main", "origin"), Some(origin.head("main")));
}
