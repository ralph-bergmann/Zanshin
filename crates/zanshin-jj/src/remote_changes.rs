// SPDX-License-Identifier: MIT

//! `remote_changes.rs` — the remote-change poll (Story 9.24, FR-JJ-13c).
//!
//! Asks one configured git remote for its refs (`git ls-remote --heads --tags`) and diffs the
//! advertisement against the head view's `<name>@<remote>` bookmarks and tags, without fetching:
//! no objects are downloaded, no transaction is opened, no snapshot runs and no operation is
//! written. jj-lib has no public ls-remote (its `GitSubprocessContext` is `pub(crate)`), so the
//! `git` is spawned here exactly as jj-lib spawns its own (`git_subprocess.rs:102-160` @ v0.46.0):
//! same executable, flags, environment and error texts. Never shells to the `jj` CLI (AR-AP-1).
//!
//! Only the refs a bare `jj git fetch` of the remote would fetch take part (Story 9.30): the
//! advertised names and the view's names both pass the remote's default fetch filters first.

use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;
use std::process::{Command, Stdio};

use jj_lib::git::{self, GitSubprocessOptions};
use jj_lib::object_id::ObjectId as _;
use jj_lib::op_store::RefTarget;
use jj_lib::ref_name::RemoteName;
use jj_lib::repo::Repo as _;
use jj_lib::settings::UserSettings;
use jj_lib::str_util::StringMatcher;
use jj_lib::workspace::Workspace;

use crate::cancel::CancelGuard;
use crate::mutate::{self, MutateError};
use crate::CommitId;

/// One ref whose `<name>@<remote>` target in the head view differs from what the remote
/// advertises now (Story 9.24).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RemoteRefChange {
    /// Whether the ref is a bookmark (a Git branch) or a tag.
    pub kind: RemoteRefKind,
    /// The ref's name without its namespace, e.g. `"main"` for `refs/heads/main`.
    pub name: String,
    /// How the advertised ref differs from the view.
    pub change: RemoteRefChangeKind,
    /// The view's `<name>@<remote>` target — one id, or several for a conflicted target, in
    /// jj's order. Empty for [`RemoteRefChangeKind::New`].
    pub old_commit_ids: Vec<CommitId>,
    /// The commit the remote advertises — for an annotated tag the commit it peels to, not the
    /// tag object. `None` for [`RemoteRefChangeKind::Deleted`].
    pub new_commit_id: Option<CommitId>,
}

/// The kind of a [`RemoteRefChange`]'s ref.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RemoteRefKind {
    /// A bookmark — a Git branch under `refs/heads/`.
    Bookmark,
    /// A tag — under `refs/tags/`.
    Tag,
}

/// How a [`RemoteRefChange`]'s ref differs from the view.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RemoteRefChangeKind {
    /// The remote advertises another commit than the view's target (or the target is
    /// conflicted).
    Moved,
    /// The remote advertises a ref the view has no `<name>@<remote>` target for.
    New,
    /// The view has a `<name>@<remote>` target the remote no longer advertises.
    Deleted,
}

/// The remote's advertised refs: name → full lowercase hex commit id, per kind.
#[derive(Debug, Default, PartialEq, Eq)]
struct Advertisement {
    bookmarks: BTreeMap<String, String>,
    tags: BTreeMap<String, String>,
}

/// Diffs `remote_name`'s ref advertisement against the head view (Story 9.24). See
/// [`crate::Repo::remote_changes`] for the contract.
///
/// # Errors
///
/// - [`MutateError::Precondition`] — the head could not be loaded.
/// - [`MutateError::NotAGitRepo`] — the workspace has no Git backend.
/// - [`MutateError::RemoteNotFound`] — no configured remote is named `remote_name`.
/// - [`MutateError::Config`] — `git.executable-path` does not read, or a `remotes.<name>` entry or
///   the remote's `fetch-bookmarks`/`fetch-tags` is malformed.
/// - [`MutateError::InvalidInput`] — the remote's Git config does not read (jj-lib's
///   `load_default_fetch_bookmarks`), or a filter cannot become a refspec (jj-lib's
///   `expand_fetch_refspecs`, as the fetch refuses it).
/// - [`MutateError::Cancelled`] — `cancel`'s token was cancelled.
/// - [`MutateError::NetworkError`] — `git` could not run or failed.
/// - [`MutateError::Backend`] — `git` printed something that is not a ref advertisement.
pub(crate) fn remote_changes(
    workspace: &Workspace,
    settings: &UserSettings,
    remote_name: &str,
    cancel: Option<&CancelGuard>,
) -> Result<Vec<RemoteRefChange>, MutateError> {
    let repo = crate::snapshot::load_head(workspace)?;
    let store = repo.store();
    let backend = git::get_git_backend(store).map_err(|_| MutateError::NotAGitRepo)?;
    let names = git::get_all_remote_names(store).map_err(|_| MutateError::NotAGitRepo)?;
    if !names.iter().any(|name| name.as_str() == remote_name) {
        return Err(MutateError::RemoteNotFound {
            name: remote_name.to_owned(),
        });
    }
    let remote = RemoteName::new(remote_name);
    // The bare fetch's filters (Story 9.30); its ignored refspecs are dropped silently — the poll
    // is no CLI verb, so it has no warning of the CLI's to report them with.
    let filters = crate::remotes::remote_fetch_refs(
        settings.config(),
        &backend.git_repo(),
        remote,
        (None, None),
        &mut Vec::new(),
    )?;
    // Refused as the fetch refuses it: a pattern that cannot become a refspec.
    jj_lib::git::expand_fetch_refspecs(remote, filters.clone()).map_err(crate::remotes::invalid)?;
    let (bookmark_matcher, tag_matcher) = (filters.bookmark.to_matcher(), filters.tag.to_matcher());
    let options = crate::environment::git_subprocess_options(settings, cancel).map_err(mutate::cfg)?;
    crate::cancel::watch_store(cancel, store);
    crate::cancel::checkpoint(cancel)?;
    let stdout = ls_remote(backend.git_repo_path(), &options, remote_name).map_err(|e| {
        if crate::cancel::is_cancelled(cancel) {
            MutateError::Cancelled
        } else {
            e
        }
    })?;
    crate::cancel::checkpoint(cancel)?;

    let advertised = parse_advertisement(&stdout)?;
    let view = repo.view();
    let mut changes = diff_against_view(
        RemoteRefKind::Bookmark,
        &bookmark_matcher,
        &advertised.bookmarks,
        view.remote_bookmarks(remote)
            .map(|(name, remote_ref)| (name.as_str(), &remote_ref.target)),
    );
    changes.extend(diff_against_view(
        RemoteRefKind::Tag,
        &tag_matcher,
        &advertised.tags,
        view.remote_tags(remote)
            .map(|(name, remote_ref)| (name.as_str(), &remote_ref.target)),
    ));
    Ok(changes)
}

/// Runs `git ls-remote --heads --tags -- <remote>` the way jj-lib's `create_command` /
/// `spawn_cmd` / `wait_with_output` run every git (`git_subprocess.rs` @ v0.46.0) and returns its
/// stdout.
///
/// # Errors
///
/// [`MutateError::NetworkError`] with jj-lib's own text: git could not be spawned, not be waited
/// for, or exited non-zero.
fn ls_remote(git_dir: &Path, options: &GitSubprocessOptions, remote: &str) -> Result<Vec<u8>, MutateError> {
    let network = |reason: String| MutateError::NetworkError { reason };
    let mut command = Command::new(&options.executable_path);
    command
        .args(["-c", "core.fsmonitor=false"])
        .args(["-c", "submodule.recurse=false"])
        .arg("--git-dir")
        .arg(git_dir)
        .env_remove("LC_ALL")
        .env_remove("LANGUAGE")
        .env("LC_MESSAGES", "C")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .envs(&options.environment)
        .args(["ls-remote", "--heads", "--tags", "--", remote]);
    let path = options.executable_path.display();
    let child = command.spawn().map_err(|_| {
        network(if options.executable_path.is_absolute() {
            format!("Could not execute git process at specified path '{path}'")
        } else {
            format!("Could not execute the git process, found in the OS path '{path}'")
        })
    })?;
    let output = child
        .wait_with_output()
        .map_err(|_| network("Failed to wait for the git process".to_owned()))?;
    if !output.status.success() {
        return Err(network(format!(
            "External git program failed:\n{}",
            String::from_utf8_lossy(&output.stderr)
        )));
    }
    Ok(output.stdout)
}

/// Parses `git ls-remote` output (`<hex>\t<refname>` per line) into the bookmarks and tags jj
/// would import: `refs/heads/<n>` except `HEAD` (jj-lib `parse_git_ref`), `refs/tags/<n>` with a
/// `refs/tags/<n>^{}` line's peeled id winning. Other refs and non-UTF-8 names are skipped.
///
/// # Errors
///
/// [`MutateError::Backend`] — a line without a tab, or with an empty or non-hex id.
fn parse_advertisement(stdout: &[u8]) -> Result<Advertisement, MutateError> {
    let mut advertisement = Advertisement::default();
    let mut peeled = BTreeMap::new();
    let text = stdout.strip_suffix(b"\n").unwrap_or(stdout);
    if text.is_empty() {
        return Ok(advertisement);
    }
    for line in text.split(|&b| b == b'\n') {
        let malformed = || {
            MutateError::Backend(format!(
                "unexpected git ls-remote output: {}",
                String::from_utf8_lossy(line)
            ))
        };
        let tab = line.iter().position(|&b| b == b'\t').ok_or_else(malformed)?;
        let (id, refname) = (&line[..tab], &line[tab + 1..]);
        if id.is_empty() || !id.iter().all(u8::is_ascii_hexdigit) {
            return Err(malformed());
        }
        let id = String::from_utf8_lossy(id).to_ascii_lowercase();
        let Ok(refname) = std::str::from_utf8(refname) else {
            continue;
        };
        if let Some(name) = refname.strip_prefix("refs/heads/") {
            if name != "HEAD" {
                advertisement.bookmarks.insert(name.to_owned(), id);
            }
        } else if let Some(tag) = refname.strip_prefix("refs/tags/") {
            match tag.strip_suffix("^{}") {
                Some(name) => peeled.insert(name.to_owned(), id),
                None => advertisement.tags.insert(tag.to_owned(), id),
            };
        }
    }
    advertisement.tags.extend(peeled);
    Ok(advertisement)
}

/// The changes of one ref kind: every advertised name and every name with a present view
/// target that `matcher` accepts, by name (byte order).
fn diff_against_view<'a>(
    kind: RemoteRefKind,
    matcher: &StringMatcher,
    advertised: &BTreeMap<String, String>,
    view: impl Iterator<Item = (&'a str, &'a RefTarget)>,
) -> Vec<RemoteRefChange> {
    let view: BTreeMap<&str, &RefTarget> = view
        .filter(|(name, target)| target.is_present() && matcher.is_match(name))
        .collect();
    let names: BTreeSet<&str> = advertised
        .keys()
        .map(String::as_str)
        .filter(|name| matcher.is_match(name))
        .chain(view.keys().copied())
        .collect();
    names
        .into_iter()
        .filter_map(|name| {
            let new = advertised.get(name);
            let old = view.get(name);
            let change = match (old, new) {
                (None, Some(_)) => RemoteRefChangeKind::New,
                (Some(_), None) => RemoteRefChangeKind::Deleted,
                (Some(target), Some(id)) if target.as_normal().is_some_and(|old| old.hex() == *id) => {
                    return None;
                }
                _ => RemoteRefChangeKind::Moved,
            };
            Some(RemoteRefChange {
                kind,
                name: name.to_owned(),
                change,
                old_commit_ids: old
                    .map(|target| target.present_adds().map(|id| CommitId(id.hex())).collect())
                    .unwrap_or_default(),
                new_commit_id: new.map(|id| CommitId(id.clone())),
            })
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use std::collections::{BTreeMap, HashMap};
    use std::path::Path;

    use jj_lib::backend::CommitId as JjCommitId;
    use jj_lib::git::GitSubprocessOptions;
    use jj_lib::op_store::RefTarget;
    use jj_lib::str_util::{StringExpression, StringMatcher};

    use super::{
        diff_against_view, ls_remote, parse_advertisement, Advertisement, RemoteRefChange, RemoteRefChangeKind,
        RemoteRefKind,
    };
    use crate::{CommitId, MutateError};

    const A: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const B: &str = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    const C: &str = "cccccccccccccccccccccccccccccccccccccccc";

    fn target(hex: &'static str) -> RefTarget {
        RefTarget::normal(JjCommitId::from_hex(hex))
    }

    fn map(entries: &[(&str, &str)]) -> BTreeMap<String, String> {
        entries
            .iter()
            .map(|(k, v)| ((*k).to_owned(), (*v).to_owned()))
            .collect()
    }

    /// Asserts `stdout` is refused as a `Backend` error reading exactly `expected`.
    fn assert_malformed(stdout: &str, expected: &str) {
        let result = parse_advertisement(stdout.as_bytes());
        assert!(
            matches!(&result, Err(MutateError::Backend(reason)) if reason == expected),
            "expected a Backend error {expected:?}, got {result:?}"
        );
    }

    #[test]
    fn heads_and_tags_are_parsed_and_other_refs_and_head_are_skipped() {
        let stdout = format!(
            "{A}\tHEAD\n{A}\trefs/heads/main\n{B}\trefs/heads/feature/x\n{C}\trefs/heads/HEAD\n\
             {C}\trefs/pull/1/head\n{B}\trefs/tags/t1\n"
        );
        let parsed = parse_advertisement(stdout.as_bytes()).expect("parses");
        assert_eq!(parsed.bookmarks, map(&[("feature/x", B), ("main", A)]));
        assert_eq!(parsed.tags, map(&[("t1", B)]));
    }

    #[test]
    fn a_peeled_tag_id_wins_whatever_the_line_order() {
        let before = format!("{C}\trefs/tags/v1^{{}}\n{B}\trefs/tags/v1\n");
        let after = format!("{B}\trefs/tags/v1\n{C}\trefs/tags/v1^{{}}");
        for stdout in [before, after] {
            let parsed = parse_advertisement(stdout.as_bytes()).expect("parses");
            assert_eq!(parsed.tags, map(&[("v1", C)]), "{stdout}");
        }
    }

    #[test]
    fn ids_are_lowercased_and_empty_output_is_no_refs() {
        let parsed = parse_advertisement(format!("{}\trefs/heads/main\n", A.to_uppercase()).as_bytes()).unwrap();
        assert_eq!(parsed.bookmarks, map(&[("main", A)]));
        assert_eq!(parse_advertisement(b"").expect("parses"), Advertisement::default());
    }

    #[test]
    fn a_non_utf8_ref_name_is_skipped() {
        let mut stdout = format!("{A}\trefs/heads/").into_bytes();
        stdout.extend([0xff, b'\n']);
        stdout.extend(format!("{B}\trefs/heads/ok\n").into_bytes());
        let parsed = parse_advertisement(&stdout).expect("parses");
        assert_eq!(parsed.bookmarks, map(&[("ok", B)]));
    }

    #[test]
    fn malformed_lines_are_backend_errors() {
        assert_malformed("no tab here\n", "unexpected git ls-remote output: no tab here");
        assert_malformed(
            "\trefs/heads/main",
            "unexpected git ls-remote output: \trefs/heads/main",
        );
        assert_malformed(
            "xyz\trefs/heads/main",
            "unexpected git ls-remote output: xyz\trefs/heads/main",
        );
    }

    fn change(
        kind: RemoteRefKind,
        name: &str,
        change: RemoteRefChangeKind,
        old: &[&str],
        new: Option<&str>,
    ) -> RemoteRefChange {
        RemoteRefChange {
            kind,
            name: name.to_owned(),
            change,
            old_commit_ids: old.iter().map(|id| CommitId((*id).to_owned())).collect(),
            new_commit_id: new.map(|id| CommitId(id.to_owned())),
        }
    }

    #[test]
    fn the_diff_reports_moved_new_and_deleted_by_name_and_skips_unchanged() {
        use RemoteRefChangeKind::{Deleted, Moved, New};
        let advertised = map(&[("main", B), ("feature", C), ("same", A)]);
        let (main, same, gone, absent) = (target(A), target(A), target(C), RefTarget::absent());
        let view = [("gone", &gone), ("main", &main), ("same", &same), ("absent", &absent)];
        let changes = diff_against_view(
            RemoteRefKind::Bookmark,
            &StringMatcher::all(),
            &advertised,
            view.into_iter(),
        );
        assert_eq!(
            changes,
            [
                change(RemoteRefKind::Bookmark, "feature", New, &[], Some(C)),
                change(RemoteRefKind::Bookmark, "gone", Deleted, &[C], None),
                change(RemoteRefKind::Bookmark, "main", Moved, &[A], Some(B)),
            ]
        );
    }

    #[test]
    fn a_conflicted_view_target_is_moved_with_every_added_id() {
        let conflicted = RefTarget::from_legacy_form(
            [JjCommitId::from_hex(C)],
            [JjCommitId::from_hex(A), JjCommitId::from_hex(B)],
        );
        let advertised = map(&[("main", A)]);
        let changes = diff_against_view(
            RemoteRefKind::Tag,
            &StringMatcher::all(),
            &advertised,
            [("main", &conflicted)].into_iter(),
        );
        assert_eq!(
            changes,
            [change(
                RemoteRefKind::Tag,
                "main",
                RemoteRefChangeKind::Moved,
                &[A, B],
                Some(A)
            )]
        );
    }

    /// Story 9.30: a name the filter rejects takes no part — neither advertised nor in the view —
    /// so a new, moved or deleted ref outside the bare fetch's refs is not reported.
    #[test]
    fn names_the_filter_rejects_are_left_out_on_both_sides() {
        use RemoteRefChangeKind::{Deleted, Moved};
        let matcher = StringExpression::exact("main")
            .union(StringExpression::exact("gone"))
            .to_matcher();
        let advertised = map(&[("main", B), ("other", C), ("moved", B)]);
        let (main, moved, gone, stale) = (target(A), target(A), target(C), target(C));
        let view = [("gone", &gone), ("main", &main), ("moved", &moved), ("stale", &stale)];
        let changes = diff_against_view(RemoteRefKind::Bookmark, &matcher, &advertised, view.into_iter());
        assert_eq!(
            changes,
            [
                change(RemoteRefKind::Bookmark, "gone", Deleted, &[C], None),
                change(RemoteRefKind::Bookmark, "main", Moved, &[A], Some(B)),
            ]
        );
        let none = diff_against_view(
            RemoteRefKind::Tag,
            &StringExpression::none().to_matcher(),
            &advertised,
            view.into_iter(),
        );
        assert!(none.is_empty(), "{none:?}");
    }

    fn options(executable: &str) -> GitSubprocessOptions {
        GitSubprocessOptions {
            executable_path: executable.into(),
            environment: HashMap::new(),
        }
    }

    /// Asserts `ls_remote` with `executable` fails as a `NetworkError` whose reason `accepts`
    /// accepts; `expectation` describes it for the failure message.
    fn assert_network_error(executable: &str, expectation: &str, accepts: impl Fn(&str) -> bool) {
        let result = ls_remote(Path::new("/nonexistent"), &options(executable), "origin");
        assert!(
            matches!(&result, Err(MutateError::NetworkError { reason }) if accepts(reason)),
            "expected a NetworkError {expectation}, got {result:?}"
        );
    }

    #[test]
    fn a_git_that_cannot_be_spawned_reports_jj_libs_texts() {
        assert_network_error("zanshin-no-such-git", "naming the OS path", |reason| {
            reason == "Could not execute the git process, found in the OS path 'zanshin-no-such-git'"
        });
        assert_network_error("/nonexistent/zanshin-git", "naming the specified path", |reason| {
            reason == "Could not execute git process at specified path '/nonexistent/zanshin-git'"
        });
    }

    #[test]
    fn a_failing_git_reports_its_stderr() {
        const PREFIX: &str = "External git program failed:\n";
        // A longer reason than the prefix: git's stderr is forwarded.
        assert_network_error("git", "with git's stderr after the prefix", |reason| {
            reason.starts_with(PREFIX) && reason.len() > PREFIX.len()
        });
    }
}
