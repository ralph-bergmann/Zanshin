// SPDX-License-Identifier: MIT

//! `bookmarks.rs` — jj bookmark list read (FR-JJ-8, Stories 9.29 and 9.19).
//!
//! Exposes a `jj_lib`-type-free view of `jj bookmark list`: the CLI's arguments as typed
//! [`BookmarkListOptions`] and its rows, in the CLI's order, as typed [`Bookmark`]s — local rows
//! (present, or `(deleted)` with tracked remotes), tracked remote rows (synced or not, present or
//! `(not created yet)`) and untracked remote rows, each with its target change id,
//! `conflicted`/`synced`, and on a remote row `tracked` plus the ahead/behind distances to the
//! local target. Re-resolves to the head operation per call (ADR-0002) and never shells to the
//! `jj` CLI (AR-AP-1).
//!
//! Ports `cmd_bookmark_list` (`cli/src/commands/bookmark/list.rs:135-213`), `RefFilterPredicates`,
//! `collect_items`, `SortKey`, `parse_sort_keys` and `sort` (`cli/src/commit_ref_list.rs`) and
//! `warn_unmatched_local_or_remote_bookmarks` (`bookmark/mod.rs:205-226`), all @ v0.46.0.
//!
//! # Deliberate divergences from the CLI
//!
//! - **No `-T` template.** The typed rows replace the CLI's rendered output.
//! - **No hints.** "Some bookmarks have conflicts. …" and the two deleted-bookmark hints are
//!   terminal advice derivable from the rows (a conflicted local row; a deleted local row with
//!   tracked remotes).

use std::cmp;
use std::collections::{HashMap, HashSet};
use std::sync::Arc;

use futures::TryStreamExt as _;
use jj_lib::backend::{self, CommitId};
use jj_lib::config::StackedConfig;
use jj_lib::op_store::{LocalRemoteRefTarget, RefTarget, RemoteRef};
use jj_lib::ref_name::{RefName, RemoteName};
use jj_lib::repo::Repo as _;
use jj_lib::revset::{walk_revs, RevsetExpression};
use jj_lib::str_util::{StringExpression, StringMatcher};
use jj_lib::workspace::Workspace;

use crate::warning::{WarningKind, Warnings};
use crate::{ChangeId, ConfigError, RevsetError};

/// A commit count between a remote bookmark and its local counterpart, as jj-lib's
/// `Revset::count_estimate` reports it (the CLI's `tracking_ahead_count` /
/// `tracking_behind_count`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RefDistance {
    /// At least this many commits.
    pub lower: u64,
    /// At most this many commits; `None` when jj-lib could not bound the count (the CLI's
    /// "at least N commits"). Equal to `lower` for an exact count.
    pub upper: Option<u64>,
}

/// The distance of a synced pair — the CLI's `(0, Some(0))` fast path.
const SYNCED: RefDistance = RefDistance {
    lower: 0,
    upper: Some(0),
};

/// Whether a bookmark row is the local bookmark or a remote one, with the remote-only facts.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BookmarkKind {
    /// A bookmark local to this repository.
    Local,
    /// A remote bookmark, tracked or not. `remote_name` is always present for a `Remote`
    /// entry (never `None`); it may be the empty string only in the theoretical
    /// empty-remote edge case (jj does not forbid an empty remote name). It is
    /// never fabricated — an absent value across the FFI wire is corruption.
    Remote {
        /// The remote this bookmark lives on (e.g. `"origin"`, or `"git"` in a colocated repo).
        remote_name: String,
        /// Whether the local bookmark tracks this remote bookmark (jj-lib `RemoteRef::is_tracked`).
        tracked: bool,
        /// Commits this remote target has that the local target lacks (`local..remote`).
        /// Present only on a tracked row whose own target and the local target are both present.
        ahead: Option<RefDistance>,
        /// Commits the local target has that this remote target lacks (`remote..local`).
        /// Present exactly when `ahead` is.
        behind: Option<RefDistance>,
    },
}

/// One row of `jj bookmark list` (FR-JJ-8, Stories 9.29 and 9.19).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Bookmark {
    /// Bookmark name, preserved as UTF-8 (jj-lib `RefName`).
    pub name: String,
    /// Target change id in jj reverse-hex form; for a conflicted target the first added
    /// commit's change id. `None` when the row's target is absent: a local bookmark that was
    /// deleted while still tracking a remote (the CLI's `(deleted)`), or a tracked remote
    /// bookmark not pushed yet (the CLI's `(not created yet)`).
    pub target: Option<ChangeId>,
    /// The target is an unresolved conflict (`!RefTarget::is_resolved`).
    pub conflicted: bool,
    /// Local row: every tracked remote bookmark of this name points where the local one does
    /// (true when none is tracked). Remote row: tracked and pointing where the local one does.
    pub synced: bool,
    /// Whether this row is the local bookmark or a remote one.
    pub kind: BookmarkKind,
}

/// One `--sort` key of `jj bookmark list` (Story 9.19) — the CLI's `SortKey`
/// (`commit_ref_list.rs:123-147` @ v0.46.0). A `…Desc` key is the CLI's spelling with a trailing
/// `-` (`name-`, `author-date-`, …).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum BookmarkSortKey {
    /// `name`: by bookmark name, then remote name (the local row first).
    Name,
    /// `name-`: [`BookmarkSortKey::Name`] descending.
    NameDesc,
    /// `author-name`: by the target's author name.
    AuthorName,
    /// `author-name-`: descending.
    AuthorNameDesc,
    /// `author-email`: by the target's author email.
    AuthorEmail,
    /// `author-email-`: descending.
    AuthorEmailDesc,
    /// `author-date`: by the target's author timestamp.
    AuthorDate,
    /// `author-date-`: descending.
    AuthorDateDesc,
    /// `committer-name`: by the target's committer name.
    CommitterName,
    /// `committer-name-`: descending.
    CommitterNameDesc,
    /// `committer-email`: by the target's committer email.
    CommitterEmail,
    /// `committer-email-`: descending.
    CommitterEmailDesc,
    /// `committer-date`: by the target's committer timestamp.
    CommitterDate,
    /// `committer-date-`: descending.
    CommitterDateDesc,
}

impl BookmarkSortKey {
    /// The key the CLI spells `name` — `ui.bookmark-list-sort-keys`' value names (clap's
    /// `ValueEnum` names).
    pub(crate) fn from_cli_name(name: &str) -> Option<Self> {
        Some(match name {
            "name" => Self::Name,
            "name-" => Self::NameDesc,
            "author-name" => Self::AuthorName,
            "author-name-" => Self::AuthorNameDesc,
            "author-email" => Self::AuthorEmail,
            "author-email-" => Self::AuthorEmailDesc,
            "author-date" => Self::AuthorDate,
            "author-date-" => Self::AuthorDateDesc,
            "committer-name" => Self::CommitterName,
            "committer-name-" => Self::CommitterNameDesc,
            "committer-email" => Self::CommitterEmail,
            "committer-email-" => Self::CommitterEmailDesc,
            "committer-date" => Self::CommitterDate,
            "committer-date-" => Self::CommitterDateDesc,
            _ => return None,
        })
    }

    /// The CLI's `is_commit_dependant`: every key but the two name keys reads the target commit.
    fn is_commit_dependant(self) -> bool {
        !matches!(self, Self::Name | Self::NameDesc)
    }
}

/// The arguments of [`crate::Repo::list_bookmarks`] (Story 9.19) — the CLI's `BookmarkListArgs`
/// (`bookmark/list.rs:52-133` @ v0.46.0) without `-T`. The default is the CLI's own: no argument
/// given. An empty list means the argument was not given (clap never yields an empty one).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct BookmarkListOptions {
    /// The CLI's positional NAMES: string PATTERNS, passed through verbatim (a bare pattern is a
    /// GLOB), unioned. OR-ed with `revisions`.
    pub names: Vec<String>,
    /// The CLI's `-r/--revision`: revset TEXTS, unioned; a bookmark whose LOCAL target is in them
    /// is listed. OR-ed with `names`.
    pub revisions: Vec<String>,
    /// The CLI's `--remote`: remote-name PATTERNS. Lists the tracked and untracked remote
    /// bookmarks of the matching remotes, synced ones included.
    pub remotes: Vec<String>,
    /// The CLI's `-a/--all-remotes`: every tracked and untracked remote bookmark, synced ones
    /// included. Conflicts with `remotes`, `tracked` and `conflicted`.
    pub all_remotes: bool,
    /// The CLI's `-t/--tracked`: tracked remote bookmarks only (without `remotes`, the remote
    /// `git` is left out on a Git-backed repo).
    pub tracked: bool,
    /// The CLI's `-c/--conflicted`: bookmarks whose local target is conflicted only.
    pub conflicted: bool,
    /// The CLI's `--sort`, most significant key first; empty applies `ui.bookmark-list-sort-keys`.
    pub sort: Vec<BookmarkSortKey>,
}

/// Errors returned by [`crate::Repo::list_bookmarks`].
#[derive(Debug, thiserror::Error)]
pub enum BookmarkError {
    /// The pre-verb snapshot failed (Story 9.26), so the read never ran — see
    /// [`crate::PreconditionError`].
    #[error(transparent)]
    Precondition(#[from] crate::PreconditionError),
    /// The arguments are refused (Story 9.19): `all_remotes` with `remotes`, `tracked` or
    /// `conflicted` (clap's `conflicts_with`), or a name or remote pattern does not parse.
    #[error("invalid input: {reason}")]
    InvalidInput {
        /// Human-readable reason the input was rejected.
        reason: String,
    },
    /// A `revisions` text is syntactically invalid or names an unknown function (Story 9.19).
    #[error("invalid revset: {reason}")]
    RevsetParseError {
        /// Human-readable parse failure from jj-lib.
        reason: String,
    },
    /// A `revisions` text names a symbol that does not resolve (Story 9.19).
    #[error("cannot resolve revset: {reason}")]
    RevsetResolutionError {
        /// Human-readable resolution failure from jj-lib.
        reason: String,
    },
    /// The effective config could not be read (Story 9.19): `ui.bookmark-list-sort-keys` is not
    /// an array of the CLI's key names, or the revset aliases do not load.
    #[error(transparent)]
    Config(#[from] ConfigError),
    /// An underlying jj-lib failure (loader / view / store read / distance revset),
    /// opaque-string-wrapped so no `jj_lib` type escapes the public API (FR-JJ-16).
    #[error("jj-lib error: {0}")]
    Backend(String),
}

/// Converts any jj-lib error to [`BookmarkError::Backend`].
fn be<E: std::fmt::Display>(e: E) -> BookmarkError {
    BookmarkError::Backend(e.to_string())
}

/// Classifies a [`RevsetError`] of the `revisions` argument.
fn rev(e: RevsetError) -> BookmarkError {
    match e {
        RevsetError::ParseError { reason } => BookmarkError::RevsetParseError { reason },
        RevsetError::ResolutionError { reason } => BookmarkError::RevsetResolutionError { reason },
        RevsetError::Config(inner) => BookmarkError::Config(inner),
        RevsetError::Precondition(inner) => BookmarkError::Precondition(inner),
        e @ (RevsetError::JjLibError(_) | RevsetError::DanglingEdge { .. }) => be(e),
    }
}

/// Refuses clap's `conflicts_with = "all_remotes"` (`bookmark/list.rs:66-80` @ v0.46.0) — before
/// the pre-verb snapshot ([`crate::Repo::list_bookmarks`]), as the CLI parses its arguments first.
///
/// # Errors
///
/// [`BookmarkError::InvalidInput`] naming the two conflicting arguments.
pub(crate) fn check_list_flags(options: &BookmarkListOptions) -> Result<(), BookmarkError> {
    if !options.all_remotes {
        return Ok(());
    }
    let conflicting = [
        ("--remote", !options.remotes.is_empty()),
        ("--tracked", options.tracked),
        ("--conflicted", options.conflicted),
    ];
    match conflicting.iter().find(|(_, given)| *given) {
        Some((flag, _)) => Err(BookmarkError::InvalidInput {
            reason: format!("the argument '--all-remotes' cannot be used with '{flag}'"),
        }),
        None => Ok(()),
    }
}

/// The CLI's `RefFilterPredicates` (`commit_ref_list.rs:45-61` @ v0.46.0).
struct Predicates {
    /// Matches local names.
    name_matcher: StringMatcher,
    /// Matches remote names.
    remote_matcher: StringMatcher,
    /// Matches any of the local targets.
    matched_local_targets: HashSet<CommitId>,
    /// Selects local refs having conflicted targets.
    conflicted: bool,
    /// Which rows beyond the matched names are included.
    include: Include,
}

/// The `include_*` half of the CLI's `RefFilterPredicates`.
struct Include {
    /// Includes local-only refs.
    local_only: bool,
    /// Includes tracked remote refs pointing to the same local targets.
    synced_remotes: bool,
    /// Includes untracked remote refs.
    untracked_remotes: bool,
}

/// The primary row of a [`Item`]: the local bookmark, or an untracked remote one.
enum Primary<'a> {
    /// The local row; `remote_refs` are ALL its remote refs (its `synced` fact reads them).
    Local {
        /// Every `(remote, ref)` of this name.
        remote_refs: Vec<(&'a RemoteName, &'a RemoteRef)>,
    },
    /// An untracked remote ref (`CommitRef::remote_only`).
    Untracked {
        /// The remote.
        remote: &'a RemoteName,
        /// The remote ref.
        remote_ref: &'a RemoteRef,
    },
}

/// The CLI's `RefListItem`: a primary row and the tracked remote rows sorted with it.
struct Item<'a> {
    /// The bookmark name.
    name: &'a RefName,
    /// The local target (absent for a deleted or remote-only name).
    local_target: &'a RefTarget,
    /// The primary row.
    primary: Primary<'a>,
    /// The tracked remote refs listed under the primary.
    tracked: Vec<(&'a RemoteName, &'a RemoteRef)>,
}

impl Item<'_> {
    /// The primary's remote name — `None` for the local row.
    fn remote_name(&self) -> Option<&str> {
        match &self.primary {
            Primary::Local { .. } => None,
            Primary::Untracked { remote, .. } => Some(remote.as_str()),
        }
    }

    /// The primary's target.
    fn target(&self) -> &RefTarget {
        match &self.primary {
            Primary::Local { .. } => self.local_target,
            Primary::Untracked { remote_ref, .. } => &remote_ref.target,
        }
    }
}

/// The CLI's `collect_items` (`commit_ref_list.rs:63-121` @ v0.46.0): per name in view order, the
/// local item (with its tracked remote refs) and then one item per untracked remote ref.
fn collect_items<'a>(
    all_refs: impl IntoIterator<Item = (&'a RefName, LocalRemoteRefTarget<'a>)>,
    predicates: &Predicates,
) -> Vec<Item<'a>> {
    let mut items = Vec::new();
    for (name, targets) in all_refs {
        let LocalRemoteRefTarget {
            local_target,
            remote_refs,
        } = targets;
        let selected = predicates.name_matcher.is_match(name.as_str())
            || local_target
                .present_adds()
                .any(|id| predicates.matched_local_targets.contains(id));
        if !selected || (predicates.conflicted && local_target.is_resolved()) {
            continue;
        }
        let (mut tracked, untracked): (Vec<_>, Vec<_>) = remote_refs
            .iter()
            .copied()
            .filter(|(remote, _)| predicates.remote_matcher.is_match(remote.as_str()))
            .partition(|(_, remote_ref)| remote_ref.is_tracked());
        if !predicates.include.synced_remotes {
            tracked.retain(|(_, remote_ref)| remote_ref.target != *local_target);
        }
        if predicates.include.local_only && local_target.is_present() || !tracked.is_empty() {
            items.push(Item {
                name,
                local_target,
                primary: Primary::Local {
                    remote_refs: remote_refs.clone(),
                },
                tracked,
            });
        }
        if predicates.include.untracked_remotes {
            items.extend(untracked.into_iter().map(|(remote, remote_ref)| Item {
                name,
                local_target,
                primary: Primary::Untracked { remote, remote_ref },
                tracked: Vec::new(),
            }));
        }
    }
    items
}

/// The CLI's `sort` (`commit_ref_list.rs:184-207` @ v0.46.0): loads the primaries' commits when a
/// key needs them, then [`sort_inner`].
fn sort(
    store: &Arc<jj_lib::store::Store>,
    items: &mut [Item<'_>],
    sort_keys: &[BookmarkSortKey],
) -> Result<(), BookmarkError> {
    let mut commits = HashMap::new();
    if sort_keys.iter().any(|key| key.is_commit_dependant()) {
        for commit_id in items.iter().filter_map(|item| item.target().present_adds().next()) {
            let commit = store.get_commit(commit_id).map_err(be)?;
            commits.insert(commit_id.clone(), commit.store_commit().clone());
        }
    }
    sort_inner(items, sort_keys, &commits);
    Ok(())
}

/// The CLI's `sort_inner` (`commit_ref_list.rs:209-298` @ v0.46.0): one stable pass per key, least
/// significant first, skipping trailing `name` keys because the items already come in name order.
fn sort_inner(
    items: &mut [Item<'_>],
    sort_keys: &[BookmarkSortKey],
    commits: &HashMap<CommitId, Arc<backend::Commit>>,
) {
    use BookmarkSortKey as K;
    let to_commit = |item: &Item<'_>| commits.get(item.target().present_adds().next()?);
    let name_key = |item: &Item<'_>| (item.name.as_str().to_owned(), item.remote_name().map(ToOwned::to_owned));
    for sort_key in sort_keys.iter().rev().skip_while(|key| **key == K::Name) {
        match sort_key {
            K::Name => items.sort_by_key(name_key),
            K::NameDesc => items.sort_by_key(|item| cmp::Reverse(name_key(item))),
            K::AuthorName => items.sort_by_key(|item| to_commit(item).map(|c| c.author.name.clone())),
            K::AuthorNameDesc => items.sort_by_key(|item| cmp::Reverse(to_commit(item).map(|c| c.author.name.clone()))),
            K::AuthorEmail => items.sort_by_key(|item| to_commit(item).map(|c| c.author.email.clone())),
            K::AuthorEmailDesc => {
                items.sort_by_key(|item| cmp::Reverse(to_commit(item).map(|c| c.author.email.clone())));
            }
            K::AuthorDate => items.sort_by_key(|item| to_commit(item).map(|c| c.author.timestamp)),
            K::AuthorDateDesc => items.sort_by_key(|item| cmp::Reverse(to_commit(item).map(|c| c.author.timestamp))),
            K::CommitterName => items.sort_by_key(|item| to_commit(item).map(|c| c.committer.name.clone())),
            K::CommitterNameDesc => {
                items.sort_by_key(|item| cmp::Reverse(to_commit(item).map(|c| c.committer.name.clone())));
            }
            K::CommitterEmail => items.sort_by_key(|item| to_commit(item).map(|c| c.committer.email.clone())),
            K::CommitterEmailDesc => {
                items.sort_by_key(|item| cmp::Reverse(to_commit(item).map(|c| c.committer.email.clone())));
            }
            K::CommitterDate => items.sort_by_key(|item| to_commit(item).map(|c| c.committer.timestamp)),
            K::CommitterDateDesc => {
                items.sort_by_key(|item| cmp::Reverse(to_commit(item).map(|c| c.committer.timestamp)));
            }
        }
    }
}

/// `warn_unmatched_local_or_remote_bookmarks` (`bookmark/mod.rs:205-226` @ v0.46.0): one warning
/// naming every exact name with neither a local bookmark nor a bookmark on any remote.
pub(crate) fn warn_unmatched(sink: &mut Warnings, view: &jj_lib::view::View, expression: &StringExpression) {
    let unmatched: Vec<String> = expression
        .exact_strings()
        .map(RefName::new)
        .filter(|name| {
            view.get_local_bookmark(name).is_absent()
                && view
                    .remote_views()
                    .all(|(_, remote_view)| !remote_view.bookmarks.contains_key(*name))
        })
        .map(|name| name.as_symbol().to_string())
        .collect();
    if !unmatched.is_empty() {
        sink.push(
            WarningKind::BookmarkNamesUnmatched,
            format!("No matching bookmarks for names: {}", unmatched.join(", ")),
        );
    }
}

/// Lists the rows `jj bookmark list` with `options` prints, in its order (FR-JJ-8, Stories 9.29
/// and 9.19) — `cmd_bookmark_list` (`bookmark/list.rs:135-213` @ v0.46.0) without its template.
///
/// Names and revisions are OR-ed; `revisions` match LOCAL targets only (parsed and unioned, their
/// diagnostics under "In revset expression", intersected with `bookmarks()`). The remote filter is
/// `remotes`, else — with `tracked` on a Git-backed repo — every remote but `git`. The rows come
/// per item as the CLI prints them: the primary, then its tracked remote rows; items in name
/// order (each name's local item, then its untracked remote items), then sorted by `sort` or
/// `ui.bookmark-list-sort-keys` (read from `config`). An exact name that matches no local or
/// remote bookmark warns `jj.bookmark_names_unmatched` into `sink`, after the rows.
///
/// Re-resolves to the head operation every call (ADR-0002). Read-only.
///
/// # Errors
///
/// - [`BookmarkError::InvalidInput`] — a name or remote pattern does not parse.
/// - [`BookmarkError::RevsetParseError`] / [`BookmarkError::RevsetResolutionError`] — a
///   `revisions` text.
/// - [`BookmarkError::Config`] — the revset aliases do not load, or `ui.bookmark-list-sort-keys`
///   is malformed.
/// - [`BookmarkError::Backend`] — the head load, a store read or a distance revset failed;
///   the jj-lib reason is forwarded as a string.
#[must_use = "the Result must be used; drop it explicitly if intentional"]
pub(crate) fn list_bookmarks(
    workspace: &Workspace,
    config: &StackedConfig,
    sink: &mut Warnings,
    options: &BookmarkListOptions,
) -> Result<Vec<Bookmark>, BookmarkError> {
    let readonly = crate::snapshot::reload_head(workspace).map_err(be)?;
    let view = readonly.view();
    let invalid = |reason| BookmarkError::InvalidInput { reason };

    // Like `cmd_git_push()`, names and revisions are OR-ed (`list.rs:143-147`).
    let name_expr = if !options.names.is_empty() {
        crate::bookmark_ops::union_patterns(&options.names).map_err(invalid)?
    } else if !options.revisions.is_empty() {
        StringExpression::none()
    } else {
        StringExpression::all()
    };
    let matched_local_targets = if options.revisions.is_empty() {
        HashSet::new()
    } else {
        let parse_config = crate::revset::revset_config(config, sink)?;
        let expression = crate::revset::parse_union_diagnosed(workspace, &parse_config, &options.revisions, sink)
            .map_err(rev)?
            .intersection(&RevsetExpression::bookmarks(StringExpression::all()));
        let revset = crate::revset::evaluate_revset(readonly.as_ref(), &expression).map_err(rev)?;
        pollster::block_on(revset.stream().try_collect::<HashSet<CommitId>>()).map_err(be)?
    };

    let ignored_tracked_remote = jj_lib::git::get_git_backend(readonly.store())
        .is_ok()
        .then_some(jj_lib::git::REMOTE_NAME_FOR_LOCAL_GIT_REPO);
    // `--tracked` implies `--remote=~git` by default (`list.rs:171-179`).
    let remote_expr = if !options.remotes.is_empty() {
        crate::bookmark_ops::union_patterns(&options.remotes).map_err(invalid)?
    } else if let (true, Some(ignored)) = (options.tracked, ignored_tracked_remote) {
        StringExpression::exact(ignored.as_str()).negated()
    } else {
        StringExpression::all()
    };
    let remotes_given = !options.remotes.is_empty();
    let predicates = Predicates {
        name_matcher: name_expr.to_matcher(),
        remote_matcher: remote_expr.to_matcher(),
        matched_local_targets,
        conflicted: options.conflicted,
        include: Include {
            local_only: !options.tracked && !remotes_given,
            synced_remotes: options.tracked || options.all_remotes || remotes_given,
            untracked_remotes: !options.tracked && (options.all_remotes || remotes_given),
        },
    };
    let mut items = collect_items(view.bookmarks(), &predicates);
    let sort_keys = if options.sort.is_empty() {
        crate::config::ui_bookmark_list_sort_keys(config)?
    } else {
        options.sort.clone()
    };
    sort(readonly.store(), &mut items, &sort_keys)?;

    let lister = Lister { repo: &readonly };
    let mut out = Vec::new();
    for item in &items {
        lister.push_rows(item, &mut out)?;
    }
    warn_unmatched(sink, view, &name_expr);
    Ok(out)
}

/// The head repo one listing reads.
struct Lister<'a> {
    repo: &'a jj_lib::repo::ReadonlyRepo,
}

impl Lister<'_> {
    /// Appends one item's rows: its primary, then its tracked remote rows (`list.rs:197-200`).
    fn push_rows(&self, item: &Item<'_>, out: &mut Vec<Bookmark>) -> Result<(), BookmarkError> {
        let name = item.name.as_str();
        match &item.primary {
            Primary::Local { remote_refs } => out.push(Bookmark {
                name: name.to_owned(),
                target: self.change_of(item.local_target)?,
                conflicted: !item.local_target.is_resolved(),
                synced: remote_refs
                    .iter()
                    .all(|(_, remote_ref)| !remote_ref.is_tracked() || remote_ref.target == *item.local_target),
                kind: BookmarkKind::Local,
            }),
            Primary::Untracked { remote, remote_ref } => {
                out.push(self.remote_row(name, remote.as_str(), remote_ref, item.local_target)?);
            }
        }
        for (remote, remote_ref) in &item.tracked {
            out.push(self.remote_row(name, remote.as_str(), remote_ref, item.local_target)?);
        }
        Ok(())
    }

    /// One remote row (`CommitRef::remote` when tracked, `CommitRef::remote_only` otherwise).
    fn remote_row(
        &self,
        name: &str,
        remote_name: &str,
        remote_ref: &RemoteRef,
        local_target: &RefTarget,
    ) -> Result<Bookmark, BookmarkError> {
        let tracked = remote_ref.is_tracked();
        let synced = tracked && remote_ref.target == *local_target;
        let distances = if tracked && remote_ref.target.is_present() && local_target.is_present() {
            Some(if synced {
                (SYNCED, SYNCED)
            } else {
                let remote_ids: Vec<CommitId> = remote_ref.target.present_adds().cloned().collect();
                let local_ids: Vec<CommitId> = local_target.present_adds().cloned().collect();
                (
                    self.distance(&remote_ids, &local_ids)?,
                    self.distance(&local_ids, &remote_ids)?,
                )
            })
        } else {
            None
        };
        let (ahead, behind) = distances.unzip();
        Ok(Bookmark {
            name: name.to_owned(),
            target: self.change_of(&remote_ref.target)?,
            conflicted: !remote_ref.target.is_resolved(),
            synced,
            kind: BookmarkKind::Remote {
                remote_name: remote_name.to_owned(),
                tracked,
                ahead,
                behind,
            },
        })
    }

    /// The change id of `target`'s first present add, `None` when absent.
    fn change_of(&self, target: &RefTarget) -> Result<Option<ChangeId>, BookmarkError> {
        target
            .present_adds()
            .next()
            .map(|commit_id| {
                let commit = self.repo.store().get_commit(commit_id).map_err(be)?;
                Ok(ChangeId(commit.change_id().reverse_hex()))
            })
            .transpose()
    }

    /// `count_estimate` of `unwanted..wanted` (jj-lib `walk_revs`), as the CLI counts.
    fn distance(&self, wanted: &[CommitId], unwanted: &[CommitId]) -> Result<RefDistance, BookmarkError> {
        let (lower, upper) = walk_revs(self.repo, wanted, unwanted)
            .map_err(be)?
            .count_estimate()
            .map_err(be)?;
        Ok(RefDistance {
            lower: lower as u64,
            upper: upper.map(|upper| upper as u64),
        })
    }
}

#[cfg(test)]
mod tests {
    use std::collections::HashMap;
    use std::sync::Arc;

    use jj_lib::backend::{self, ChangeId, CommitId, MillisSinceEpoch, Signature, Timestamp, TreeId};
    use jj_lib::merge::Merge;
    use jj_lib::op_store::{RefTarget, RemoteRef, RemoteRefState};
    use jj_lib::ref_name::{RefNameBuf, RemoteNameBuf};

    use super::{
        check_list_flags, list_bookmarks, rev, sort_inner, BookmarkError, BookmarkListOptions, BookmarkSortKey as K,
        Item, Primary,
    };

    /// A head that no longer loads is this module's own `Backend` failure. Through
    /// [`crate::Repo`] the pre-verb snapshot (Story 9.26) hits it first, so the module function
    /// is called directly.
    #[test]
    fn a_head_that_no_longer_loads_is_a_backend_error() {
        let (_tmp, repo) = crate::test_support::repo_with_a_broken_head();
        let config = crate::config::load(&repo).expect("config");
        let result = list_bookmarks(
            repo.workspace(),
            &config,
            &mut crate::warning::Warnings::default(),
            &BookmarkListOptions::default(),
        );
        assert!(matches!(result, Err(BookmarkError::Backend(_))), "{result:?}");
    }

    /// Story 9.19: clap's `conflicts_with = "all_remotes"`, one refusal per conflicting flag.
    #[test]
    fn all_remotes_conflicts_with_remote_tracked_and_conflicted() {
        assert!(check_list_flags(&BookmarkListOptions::default()).is_ok());
        let all = BookmarkListOptions {
            all_remotes: true,
            ..Default::default()
        };
        assert!(check_list_flags(&all).is_ok());
        for (options, flag) in [
            (
                BookmarkListOptions {
                    remotes: vec!["origin".to_owned()],
                    ..all.clone()
                },
                "--remote",
            ),
            (
                BookmarkListOptions {
                    tracked: true,
                    ..all.clone()
                },
                "--tracked",
            ),
            (
                BookmarkListOptions {
                    conflicted: true,
                    ..all.clone()
                },
                "--conflicted",
            ),
        ] {
            let err = check_list_flags(&options).expect_err("clap refuses it");
            assert!(
                matches!(&err, BookmarkError::InvalidInput { reason }
                    if *reason == format!("the argument '--all-remotes' cannot be used with '{flag}'")),
                "{err:?}"
            );
        }
    }

    /// Every [`crate::RevsetError`] lands in its own [`BookmarkError`] stage; the two jj-lib
    /// failures are `Backend`.
    #[test]
    fn rev_keeps_the_revset_taxonomy() {
        use crate::RevsetError as R;
        let r = || "r".to_owned();
        assert!(
            matches!(rev(R::ParseError { reason: r() }), BookmarkError::RevsetParseError { reason } if reason == "r")
        );
        assert!(matches!(
            rev(R::ResolutionError { reason: r() }),
            BookmarkError::RevsetResolutionError { reason } if reason == "r"
        ));
        assert!(matches!(
            rev(R::Config(crate::ConfigError::Load { reason: r() })),
            BookmarkError::Config(_)
        ));
        assert!(matches!(
            rev(R::Precondition(crate::PreconditionError::Backend(r()))),
            BookmarkError::Precondition(_)
        ));
        assert!(matches!(rev(R::JjLibError(r())), BookmarkError::Backend(reason) if reason == "jj-lib error: r"));
        assert!(matches!(
            rev(R::DanglingEdge { target: r() }),
            BookmarkError::Backend(reason) if reason.contains("dangling edge")
        ));
    }

    /// Every CLI key spelling round-trips; anything else is unknown.
    #[test]
    fn sort_keys_parse_the_clis_spellings() {
        let all = [
            ("name", K::Name),
            ("name-", K::NameDesc),
            ("author-name", K::AuthorName),
            ("author-name-", K::AuthorNameDesc),
            ("author-email", K::AuthorEmail),
            ("author-email-", K::AuthorEmailDesc),
            ("author-date", K::AuthorDate),
            ("author-date-", K::AuthorDateDesc),
            ("committer-name", K::CommitterName),
            ("committer-name-", K::CommitterNameDesc),
            ("committer-email", K::CommitterEmail),
            ("committer-email-", K::CommitterEmailDesc),
            ("committer-date", K::CommitterDate),
            ("committer-date-", K::CommitterDateDesc),
        ];
        for (name, key) in all {
            assert_eq!(K::from_cli_name(name), Some(key), "{name}");
        }
        assert_eq!(K::from_cli_name("Name"), None);
        assert_eq!(K::from_cli_name(""), None);
    }

    fn signature() -> Signature {
        Signature {
            name: "Test User".to_owned(),
            email: "test.user@g.com".to_owned(),
            timestamp: Timestamp {
                timestamp: MillisSinceEpoch(0),
                tz_offset: 0,
            },
        }
    }

    fn backend_commit(author: Signature, committer: Signature) -> Arc<backend::Commit> {
        Arc::new(backend::Commit {
            parents: vec![],
            predecessors: vec![],
            root_tree: Merge::resolved(TreeId::new(vec![])),
            conflict_labels: Merge::resolved(String::new()),
            change_id: ChangeId::new(vec![]),
            description: String::new(),
            author,
            committer,
            secure_sig: None,
        })
    }

    /// The CLI's `prepare_data_sort_and_snapshot` (`commit_ref_list.rs:353-450` @ v0.46.0): five
    /// refs, sorted by name, then by `sort_keys`, rendered as the CLI's snapshot rows.
    fn sorted_rows(sort_keys: &[K]) -> Vec<String> {
        let people = ["bob", "alice", "eve", "bob", "bob"];
        let emails = ["bob@g.com", "alice@g.com", "eve@g.com", "bob@g.com", "bob@g.com"];
        let bookmark_names = ["feature", "bug-fix", "chore", "bug-fix", "feature"];
        let remote_names = [None, Some("upstream"), None, Some("origin"), Some("origin")];
        let deleted = [false, false, false, false, true];
        let uses = |keys: &[K]| keys.iter().any(|key| sort_keys.contains(key));
        let mut next_ts = Some(1_i64).into_iter().chain(1_i64..).map(|ms| Timestamp {
            timestamp: MillisSinceEpoch(ms),
            tz_offset: 0,
        });

        let mut names = Vec::new();
        let mut remotes = Vec::new();
        let mut targets = Vec::new();
        let mut commits = HashMap::new();
        for i in 0..5 {
            let commit_id = CommitId::new((i as u128 + 1).to_le_bytes().into());
            let (mut author, mut committer) = (signature(), signature());
            if uses(&[K::AuthorName, K::AuthorNameDesc]) {
                author.name = people[i].to_owned();
            }
            if uses(&[K::AuthorEmail, K::AuthorEmailDesc]) {
                author.email = emails[i].to_owned();
            }
            if uses(&[K::AuthorDate, K::AuthorDateDesc]) {
                author.timestamp = next_ts.next().expect("endless");
            }
            if uses(&[K::CommitterName, K::CommitterNameDesc]) {
                committer.name = people[i].to_owned();
            }
            if uses(&[K::CommitterEmail, K::CommitterEmailDesc]) {
                committer.email = emails[i].to_owned();
            }
            if uses(&[K::CommitterDate, K::CommitterDateDesc]) {
                committer.timestamp = next_ts.next().expect("endless");
            }
            let name = if uses(&[K::Name, K::NameDesc]) {
                bookmark_names[i]
            } else {
                "foo"
            };
            names.push(RefNameBuf::from(name));
            remotes.push(remote_names[i].map(RemoteNameBuf::from));
            // The CLI's deleted row is an absent remote-only primary.
            targets.push(RemoteRef {
                target: if deleted[i] {
                    RefTarget::absent()
                } else {
                    RefTarget::normal(commit_id.clone())
                },
                state: RemoteRefState::New,
            });
            commits.insert(commit_id, backend_commit(author, committer));
        }
        let mut items: Vec<Item<'_>> = (0..5)
            .map(|i| Item {
                name: &names[i],
                local_target: &targets[i].target,
                primary: match &remotes[i] {
                    Some(remote) => Primary::Untracked {
                        remote,
                        remote_ref: &targets[i],
                    },
                    None => Primary::Local { remote_refs: vec![] },
                },
                tracked: vec![],
            })
            .collect();
        items.sort_by_key(|item| (item.name.as_str().to_owned(), item.remote_name().map(ToOwned::to_owned)));
        sort_inner(&mut items, sort_keys, &commits);

        items
            .iter()
            .map(|item| {
                let name = match item.remote_name() {
                    Some(remote) => format!("{}@{remote}", item.name.as_str()),
                    None => item.name.as_str().to_owned(),
                };
                let commit = item.target().present_adds().next().and_then(|id| commits.get(id));
                let field = |f: &dyn Fn(&backend::Commit) -> String| commit.map_or_else(|| "-".to_owned(), |c| f(c));
                format!(
                    "{:<20}{:<16}{:<17}{:<14}{:<16}{:<17}{}",
                    name,
                    field(&|c| c.author.name.clone()),
                    field(&|c| c.author.email.clone()),
                    field(&|c| c.author.timestamp.timestamp.0.to_string()),
                    field(&|c| c.committer.name.clone()),
                    field(&|c| c.committer.email.clone()),
                    field(&|c| c.committer.timestamp.timestamp.0.to_string()),
                )
                .trim_end()
                .to_owned()
            })
            .collect()
    }

    /// The CLI's own sort tests (`commit_ref_list.rs:528-749` @ v0.46.0), expectations verbatim
    /// (trailing blanks trimmed): every key, both directions, and multi-key orders.
    const SORT_CASES: &[(&[K], &[&str])] = &[
        (
            // `test_sort_by_name`
            &[K::Name],
            &[
                "bug-fix@origin      Test User       test.user@g.com  0             Test User       test.user@g.com  0",
                "bug-fix@upstream    Test User       test.user@g.com  0             Test User       test.user@g.com  0",
                "chore               Test User       test.user@g.com  0             Test User       test.user@g.com  0",
                "feature             Test User       test.user@g.com  0             Test User       test.user@g.com  0",
                "feature@origin      -               -                -             -               -                -",
            ],
        ),
        (
            // `test_sort_by_name_desc`
            &[K::NameDesc],
            &[
                "feature@origin      -               -                -             -               -                -",
                "feature             Test User       test.user@g.com  0             Test User       test.user@g.com  0",
                "chore               Test User       test.user@g.com  0             Test User       test.user@g.com  0",
                "bug-fix@upstream    Test User       test.user@g.com  0             Test User       test.user@g.com  0",
                "bug-fix@origin      Test User       test.user@g.com  0             Test User       test.user@g.com  0",
            ],
        ),
        (
            // `test_sort_by_author_name`
            &[K::AuthorName],
            &[
                "foo@origin          -               -                -             -               -                -",
                "foo@upstream        alice           test.user@g.com  0             Test User       test.user@g.com  0",
                "foo                 bob             test.user@g.com  0             Test User       test.user@g.com  0",
                "foo@origin          bob             test.user@g.com  0             Test User       test.user@g.com  0",
                "foo                 eve             test.user@g.com  0             Test User       test.user@g.com  0",
            ],
        ),
        (
            // `test_sort_by_author_name_desc`
            &[K::AuthorNameDesc],
            &[
                "foo                 eve             test.user@g.com  0             Test User       test.user@g.com  0",
                "foo                 bob             test.user@g.com  0             Test User       test.user@g.com  0",
                "foo@origin          bob             test.user@g.com  0             Test User       test.user@g.com  0",
                "foo@upstream        alice           test.user@g.com  0             Test User       test.user@g.com  0",
                "foo@origin          -               -                -             -               -                -",
            ],
        ),
        (
            // `test_sort_by_author_email`
            &[K::AuthorEmail],
            &[
                "foo@origin          -               -                -             -               -                -",
                "foo@upstream        Test User       alice@g.com      0             Test User       test.user@g.com  0",
                "foo                 Test User       bob@g.com        0             Test User       test.user@g.com  0",
                "foo@origin          Test User       bob@g.com        0             Test User       test.user@g.com  0",
                "foo                 Test User       eve@g.com        0             Test User       test.user@g.com  0",
            ],
        ),
        (
            // `test_sort_by_author_email_desc`
            &[K::AuthorEmailDesc],
            &[
                "foo                 Test User       eve@g.com        0             Test User       test.user@g.com  0",
                "foo                 Test User       bob@g.com        0             Test User       test.user@g.com  0",
                "foo@origin          Test User       bob@g.com        0             Test User       test.user@g.com  0",
                "foo@upstream        Test User       alice@g.com      0             Test User       test.user@g.com  0",
                "foo@origin          -               -                -             -               -                -",
            ],
        ),
        (
            // `test_sort_by_author_date`
            &[K::AuthorDate],
            &[
                "foo@origin          -               -                -             -               -                -",
                "foo                 Test User       test.user@g.com  1             Test User       test.user@g.com  0",
                "foo@upstream        Test User       test.user@g.com  1             Test User       test.user@g.com  0",
                "foo                 Test User       test.user@g.com  2             Test User       test.user@g.com  0",
                "foo@origin          Test User       test.user@g.com  3             Test User       test.user@g.com  0",
            ],
        ),
        (
            // `test_sort_by_author_date_desc`
            &[K::AuthorDateDesc],
            &[
                "foo@origin          Test User       test.user@g.com  3             Test User       test.user@g.com  0",
                "foo                 Test User       test.user@g.com  2             Test User       test.user@g.com  0",
                "foo                 Test User       test.user@g.com  1             Test User       test.user@g.com  0",
                "foo@upstream        Test User       test.user@g.com  1             Test User       test.user@g.com  0",
                "foo@origin          -               -                -             -               -                -",
            ],
        ),
        (
            // `test_sort_by_committer_name`
            &[K::CommitterName],
            &[
                "foo@origin          -               -                -             -               -                -",
                "foo@upstream        Test User       test.user@g.com  0             alice           test.user@g.com  0",
                "foo                 Test User       test.user@g.com  0             bob             test.user@g.com  0",
                "foo@origin          Test User       test.user@g.com  0             bob             test.user@g.com  0",
                "foo                 Test User       test.user@g.com  0             eve             test.user@g.com  0",
            ],
        ),
        (
            // `test_sort_by_committer_name_desc`
            &[K::CommitterNameDesc],
            &[
                "foo                 Test User       test.user@g.com  0             eve             test.user@g.com  0",
                "foo                 Test User       test.user@g.com  0             bob             test.user@g.com  0",
                "foo@origin          Test User       test.user@g.com  0             bob             test.user@g.com  0",
                "foo@upstream        Test User       test.user@g.com  0             alice           test.user@g.com  0",
                "foo@origin          -               -                -             -               -                -",
            ],
        ),
        (
            // `test_sort_by_committer_email`
            &[K::CommitterEmail],
            &[
                "foo@origin          -               -                -             -               -                -",
                "foo@upstream        Test User       test.user@g.com  0             Test User       alice@g.com      0",
                "foo                 Test User       test.user@g.com  0             Test User       bob@g.com        0",
                "foo@origin          Test User       test.user@g.com  0             Test User       bob@g.com        0",
                "foo                 Test User       test.user@g.com  0             Test User       eve@g.com        0",
            ],
        ),
        (
            // `test_sort_by_committer_email_desc`
            &[K::CommitterEmailDesc],
            &[
                "foo                 Test User       test.user@g.com  0             Test User       eve@g.com        0",
                "foo                 Test User       test.user@g.com  0             Test User       bob@g.com        0",
                "foo@origin          Test User       test.user@g.com  0             Test User       bob@g.com        0",
                "foo@upstream        Test User       test.user@g.com  0             Test User       alice@g.com      0",
                "foo@origin          -               -                -             -               -                -",
            ],
        ),
        (
            // `test_sort_by_committer_date`
            &[K::CommitterDate],
            &[
                "foo@origin          -               -                -             -               -                -",
                "foo                 Test User       test.user@g.com  0             Test User       test.user@g.com  1",
                "foo@upstream        Test User       test.user@g.com  0             Test User       test.user@g.com  1",
                "foo                 Test User       test.user@g.com  0             Test User       test.user@g.com  2",
                "foo@origin          Test User       test.user@g.com  0             Test User       test.user@g.com  3",
            ],
        ),
        (
            // `test_sort_by_committer_date_desc`
            &[K::CommitterDateDesc],
            &[
                "foo@origin          Test User       test.user@g.com  0             Test User       test.user@g.com  3",
                "foo                 Test User       test.user@g.com  0             Test User       test.user@g.com  2",
                "foo                 Test User       test.user@g.com  0             Test User       test.user@g.com  1",
                "foo@upstream        Test User       test.user@g.com  0             Test User       test.user@g.com  1",
                "foo@origin          -               -                -             -               -                -",
            ],
        ),
        (
            // `test_sort_by_author_date_desc_and_name`
            &[K::AuthorDateDesc, K::Name],
            &[
                "bug-fix@origin      Test User       test.user@g.com  3             Test User       test.user@g.com  0",
                "chore               Test User       test.user@g.com  2             Test User       test.user@g.com  0",
                "bug-fix@upstream    Test User       test.user@g.com  1             Test User       test.user@g.com  0",
                "feature             Test User       test.user@g.com  1             Test User       test.user@g.com  0",
                "feature@origin      -               -                -             -               -                -",
            ],
        ),
        (
            // `test_sort_by_committer_name_and_name_desc`
            &[K::CommitterName, K::NameDesc],
            &[
                "feature@origin      -               -                -             -               -                -",
                "bug-fix@upstream    Test User       test.user@g.com  0             alice           test.user@g.com  0",
                "feature             Test User       test.user@g.com  0             bob             test.user@g.com  0",
                "bug-fix@origin      Test User       test.user@g.com  0             bob             test.user@g.com  0",
                "chore               Test User       test.user@g.com  0             eve             test.user@g.com  0",
            ],
        ),
        (
            // `test_sort_by_name_and_committer_date`
            &[K::Name, K::AuthorDate],
            &[
                "bug-fix@origin      Test User       test.user@g.com  3             Test User       test.user@g.com  0",
                "bug-fix@upstream    Test User       test.user@g.com  1             Test User       test.user@g.com  0",
                "chore               Test User       test.user@g.com  2             Test User       test.user@g.com  0",
                "feature             Test User       test.user@g.com  1             Test User       test.user@g.com  0",
                "feature@origin      -               -                -             -               -                -",
            ],
        ),
    ];

    /// Runs [`SORT_CASES`].
    #[test]
    fn sort_matches_the_clis_own_sort_tests() {
        for (keys, expected) in SORT_CASES {
            assert_eq!(sorted_rows(keys), *expected, "{keys:?}");
        }
    }
}
