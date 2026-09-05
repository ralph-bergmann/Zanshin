// SPDX-License-Identifier: MIT

use std::io;
use std::ops::ControlFlow;
use std::path::{Path, PathBuf};

use jj_lib::config::{ConfigLayer, ConfigSource, StackedConfig};
use jj_lib::default_backend_factories::{default_backend_factories, default_working_copy_factories};
use jj_lib::git::{
    expand_fetch_refspecs, GitFetch, GitFetchRefExpression, GitImportOptions, GitProgress, GitSidebandLineTerminator,
    GitSubprocessCallback, GitSubprocessOptions,
};
use jj_lib::ref_name::{RemoteName, RemoteNameBuf};
use jj_lib::repo::Repo as _;
use jj_lib::settings::UserSettings;
use jj_lib::str_util::{StringExpression, StringPattern};
use jj_lib::workspace::Workspace;

/// Errors returned by [`Repo::open`], [`Repo::init`], [`Repo::clone`], and
/// [`crate::convert_colocated`].
#[derive(Debug, thiserror::Error)]
pub enum RepoError {
    /// The supplied path does not exist on the filesystem.
    #[error("path not found: {path}")]
    PathNotFound {
        /// The path that does not exist.
        path: PathBuf,
    },
    /// The path exists but is not a jj workspace (`.jj/` is absent).
    #[error("not a jj repository: {path}")]
    NotARepo {
        /// The path that lacks a `.jj/` directory.
        path: PathBuf,
    },
    /// jj workspace initialisation failed.
    #[error("init failed: {reason}")]
    InitFailed {
        /// Human-readable failure reason from jj-lib.
        reason: String,
    },
    /// jj workspace clone failed (init, remote registration, fetch, or import).
    #[error("clone failed: {reason}")]
    CloneFailed {
        /// Human-readable failure reason from jj-lib.
        reason: String,
    },
    /// The path is already a jj workspace (`.jj/` is present).
    #[error("already a jj repository: {path}")]
    AlreadyJjRepo {
        /// The path that is already a jj workspace.
        path: PathBuf,
    },
    /// The path is not a Git repository (no `.git/`), or does not exist.
    #[error("not a git repository: {path}")]
    NotAGitRepo {
        /// The path that is neither a Git repo nor exists.
        path: PathBuf,
    },
    /// Colocated conversion failed; the partially-created `.jj/` has been rolled back.
    #[error("convert failed: {reason}")]
    ConvertFailed {
        /// Human-readable failure reason from jj-lib or `detect_repo`.
        reason: String,
    },
    /// Underlying `jj_lib` failure, flattened to its Display so no `jj_lib` type escapes the public API.
    #[error("jj-lib error: {0}")]
    Backend(String),
}

/// Selects the jj backend for a new workspace.
#[derive(Clone, Copy)]
pub enum Backend {
    /// Git-backed workspace (`init --git`).
    Git,
}

/// Handle to an open jj workspace (FR-JJ-16 adapter).
///
/// Created via [`Repo::open`], [`Repo::init`], or [`Repo::clone`]. The handle
/// is a warm `Workspace` loader that re-resolves to the operation-log head on
/// every call (ADR-0002) — it is not an authoritative state cache.
pub struct Repo {
    workspace: Workspace,
    settings: UserSettings,
}

impl std::fmt::Debug for Repo {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Repo")
            .field("workspace_root", &self.workspace.workspace_root())
            .finish_non_exhaustive()
    }
}

impl Repo {
    /// Returns the workspace root path.
    #[must_use]
    pub fn workspace_root(&self) -> &Path {
        self.workspace.workspace_root()
    }

    /// Returns a reference to the underlying jj workspace (crate-internal use only).
    pub(crate) fn workspace(&self) -> &Workspace {
        &self.workspace
    }

    /// Returns a mutable reference to the underlying jj workspace (crate-internal use only).
    pub(crate) fn workspace_mut(&mut self) -> &mut Workspace {
        &mut self.workspace
    }

    /// Returns the user settings used to open this workspace (crate-internal use only).
    pub(crate) fn settings(&self) -> &UserSettings {
        &self.settings
    }

    /// Returns the working-copy status: files changed between `@` and `@-`.
    ///
    /// Re-resolves to head on every call (ADR-0002). Read-only — does not snapshot
    /// the working copy.
    ///
    /// # Errors
    ///
    /// Returns [`crate::StatusError::NoWorkingCopy`] if the workspace has no
    /// working-copy commit, or [`crate::StatusError::Backend`] on jj-lib failure.
    pub fn status(&self) -> Result<crate::Status, crate::StatusError> {
        crate::status::working_copy_status(&self.workspace)
    }

    /// Returns full metadata for the change identified by `id` (jj reverse-hex form).
    ///
    /// Re-resolves to head on every call (ADR-0002). Read-only.
    ///
    /// # Errors
    ///
    /// - [`crate::ChangeError::NotFound`] — `id` is malformed (not valid reverse-hex),
    ///   absent from the index, or only points to hidden/abandoned commits.
    /// - [`crate::ChangeError::Backend`] — an underlying jj-lib failure.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    pub fn get_change(&self, id: &crate::ChangeId) -> Result<crate::Change, crate::ChangeError> {
        crate::change::get_change(&self.workspace, id)
    }

    /// Returns the operation log in reverse-chronological order (most-recent first, root op last).
    ///
    /// `limit = None` returns the full history; `Some(n)` returns at most the `n` most-recent
    /// operations. Re-resolves to the head operation per call (ADR-0002). Read-only; never shells
    /// to `jj op log` (AR-AP-1).
    ///
    /// # Errors
    ///
    /// - [`crate::OpLogError::Backend`] — `load_at_head` or the op-store walk failed; the
    ///   jj-lib reason is forwarded as a string.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    pub fn op_log(&self, limit: Option<usize>) -> Result<Vec<crate::Operation>, crate::OpLogError> {
        crate::op_log::op_log(self.workspace(), limit)
    }

    /// Lists local + tracked-remote bookmarks, sorted by name then kind (FR-JJ-8).
    ///
    /// Re-resolves to the head operation per call (ADR-0002). Read-only; never shells
    /// to `jj bookmark list` (AR-AP-1). A conflicted target resolves to the first added
    /// commit's change id (listing scope only).
    ///
    /// # Errors
    ///
    /// - [`crate::BookmarkError::Backend`] — `load_at_head` or a store read failed; the
    ///   jj-lib reason is forwarded as a string.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    pub fn list_bookmarks(&self) -> Result<Vec<crate::Bookmark>, crate::BookmarkError> {
        crate::bookmarks::list_bookmarks(self.workspace())
    }

    /// Lists local + tracked-remote tags, sorted by name then kind (ADR-0003 §5).
    ///
    /// Re-resolves to the head operation per call (ADR-0002). Read-only; never shells to
    /// `jj tag list` (AR-AP-1). A conflicted target resolves to the first added commit's
    /// change id (listing scope only). Unlike the CLI's `jj tag list`, a tracked remote tag
    /// whose target equals the local one is NOT hidden — that filter is a display default and
    /// belongs to [`crate::CommitMeta::tags`], exactly as for [`Repo::list_bookmarks`].
    ///
    /// # Errors
    ///
    /// - [`crate::ViewError::Backend`] — `load_at_head` or a store read failed; the jj-lib
    ///   reason is forwarded as a string.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    pub fn list_tags(&self) -> Result<Vec<crate::Tag>, crate::ViewError> {
        crate::view::list_tags(self.workspace())
    }

    /// Lists the repo's visible head commits, sorted by hex commit id (ADR-0003 §5).
    ///
    /// Re-resolves to the head operation per call (ADR-0002). Read-only. jj-lib's
    /// `View::heads()` is an unordered set, so the sort is Zanshin's and is the determinism
    /// guarantee. Heads are COMMIT ids: two divergent commits of one change can both be heads,
    /// so a change-id form would fabricate duplicates.
    ///
    /// # Errors
    ///
    /// - [`crate::ViewError::Backend`] — `load_at_head` failed; the jj-lib reason is forwarded
    ///   as a string.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    pub fn list_heads(&self) -> Result<Vec<crate::CommitId>, crate::ViewError> {
        crate::view::list_heads(self.workspace())
    }

    /// Lists every workspace of this repo with its working-copy commit id (ADR-0003 §5).
    ///
    /// The view half of `jj workspace list`, in jj-lib's own lexicographic-by-name order.
    /// Re-resolves to the head operation per call (ADR-0002). Read-only. No workspace *path*
    /// is reported — that lives in the `WorkspaceStore`, not the `View`.
    ///
    /// # Errors
    ///
    /// - [`crate::ViewError::Backend`] — `load_at_head` failed; the jj-lib reason is forwarded
    ///   as a string.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    pub fn list_working_copies(&self) -> Result<Vec<crate::WorkingCopy>, crate::ViewError> {
        crate::view::list_working_copies(self.workspace())
    }

    /// Lists configured git remotes with fetch URLs, sorted by name (FR-JJ-9).
    ///
    /// Re-resolves to the head operation per call (ADR-0002). Read-only; never
    /// shells to `jj git remote list` (AR-AP-1). A non-git (native) backend, or a
    /// git-backed repo with no remotes, yields `Ok(vec![])`.
    ///
    /// # Errors
    ///
    /// - [`crate::RemoteError::Backend`] — `load_at_head` failed; the jj-lib
    ///   reason is forwarded as a string.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    pub fn list_remotes(&self) -> Result<Vec<crate::Remote>, crate::RemoteError> {
        crate::remotes::list_remotes(self.workspace())
    }

    /// Returns the effective `jj log` defaults of this repo (Story 4.9): the values the
    /// user's own `jj` CLI would apply for `revsets.log`, `revsets.log-graph-prioritize`,
    /// `revsets.short-prefixes` and `ui.log-synthetic-elided-nodes`.
    ///
    /// The config stack is re-read on every call and never cached — config files change
    /// externally and the op-heads watcher does not cover them. Read-only: nothing is
    /// created, migrated or symlinked.
    ///
    /// These are *offers*, not policy: [`Repo::walk_graph`]'s parameters stay caller
    /// pass-throughs (FR-JJ-17), so the UI pre-fills these values and the user edits them.
    /// `short_prefixes` falls back to `log` when the key is absent from every layer; an
    /// explicit empty string means "disambiguation disabled" and is returned verbatim.
    ///
    /// # Errors
    ///
    /// - [`crate::ConfigError::Load`] — a config file is unreadable or not valid TOML, a
    ///   `config-id` is malformed, or one of the four values has the wrong type. Never a
    ///   silent fall-back to the builtin defaults.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    pub fn log_defaults(&self) -> Result<crate::LogDefaults, crate::ConfigError> {
        crate::config::log_defaults(&crate::config::load(self)?)
    }

    /// Lists the entries of a revision's tree (Story 9.4) — the CLI's `jj file list`.
    ///
    /// Re-resolves to the head operation per call (ADR-0002). Read-only; never shells to
    /// `jj file list` (AR-AP-1), and never writes an operation — unlike the CLI, whose
    /// `workspace_helper` snapshots the working copy first.
    ///
    /// `revision = None` is the CLI's own `-r` default, `@` — which here is the
    /// LAST-SNAPSHOTTED working-copy commit, because Zanshin never snapshots (D2). `paths`
    /// entries are repo-relative paths interpreted as PREFIXES (an empty list means all
    /// paths); an empty-STRING entry is the repository root, which prefixes everything, so
    /// `paths = [""]` matches all paths just as `paths = []` does. The fileset DSL is
    /// terminal input language and is not parsed here.
    ///
    /// Entries come in jj-lib's own `entries_matching` (tree) order. Like the CLI, this verb
    /// has NO refusals for the paths themselves: a path matching nothing simply contributes
    /// no entry, where the CLI prints a trailing warning. Subtrees are visited recursively
    /// and never yielded — except a subtree that CONFLICTS with a non-tree, which is emitted
    /// as one [`crate::FileType::Conflict`] entry and not descended into.
    ///
    /// # Errors
    ///
    /// - [`crate::FileError::ChangeNotFound`] — `revision` is malformed, carried by no
    ///   VISIBLE commit (unknown or only-hidden), or divergent (the CLI's `-r` refuses an
    ///   ambiguous revision too). An ABSENT `revision` is not an error: it is what applies
    ///   the CLI's `-r` default `@`.
    /// - [`crate::FileError::InvalidInput`] — a `paths` entry is not a valid repo path.
    /// - [`crate::FileError::Backend`] — an underlying jj-lib failure.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    // WHY: owned `ChangeId` is the house currency for a single-revision parameter
    // (epics.md Story 6.1 / AC-1); the implementation only needs to borrow it.
    #[allow(clippy::needless_pass_by_value)]
    pub fn file_list(
        &self,
        revision: Option<crate::ChangeId>,
        paths: &[String],
    ) -> Result<Vec<crate::FileEntry>, crate::FileError> {
        crate::file::file_list(self.workspace(), revision.as_ref(), paths)
    }

    /// Reads the contents of the files selected by `paths` in a revision (Story 9.4) — the
    /// CLI's `jj file show`.
    ///
    /// Re-resolves to the head operation per call (ADR-0002). Read-only; never shells to
    /// `jj file show` (AR-AP-1), and never writes an operation.
    ///
    /// `revision` and `paths` behave exactly as for [`Repo::file_list`], with one
    /// difference the CLI also makes: `paths` may not be EMPTY (its FILESETS argument is
    /// `required`). A directory is visited recursively.
    ///
    /// With exactly ONE path the CLI takes a fast path that refuses an absent path
    /// ([`crate::FileError::PathNotFound`]); with several, a path that is absent simply
    /// contributes nothing. That asymmetry is the CLI's, reproduced deliberately.
    ///
    /// A conflicted file's content is the MATERIALIZED merge, with markers in the style the
    /// repo's effective `ui.conflict-marker-style` selects — re-read per call and never
    /// cached, so the user's own jj config decides how a conflict renders. Paths that exist
    /// but are not renderable as file content (a symlink, a Git submodule, a blob whose
    /// access is denied) land in [`crate::FileContents::skipped`] instead of failing the
    /// call — carrying the CLI's own wording for the three cases it warns about, and
    /// Zanshin's own for the two it `panic!`s on rather than reports. A blob that
    /// materializes but then fails to READ still fails the whole call, as it does in the CLI.
    ///
    /// Whole files are held in memory (jj-lib's `read_all` has no size cap) where the CLI
    /// streams to stdout — a resource divergence, not a behavioral one.
    ///
    /// # Errors
    ///
    /// - [`crate::FileError::InvalidInput`] — `paths` is empty, or an entry is not a valid
    ///   repo path.
    /// - [`crate::FileError::ChangeNotFound`] — `revision` does not resolve.
    /// - [`crate::FileError::PathNotFound`] — exactly one path was given and it is absent
    ///   from the revision's tree.
    /// - [`crate::FileError::Config`] — the repo's effective jj config is unreadable or
    ///   malformed, so the `ui.conflict-marker-style` to materialize a conflict with cannot
    ///   be determined. `file_show` is the only one of the four verbs that reads config, and
    ///   the only one that can return this variant.
    /// - [`crate::FileError::Backend`] — an underlying jj-lib failure.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    // WHY: see `file_list`.
    #[allow(clippy::needless_pass_by_value)]
    pub fn file_show(
        &self,
        revision: Option<crate::ChangeId>,
        paths: &[String],
    ) -> Result<crate::FileContents, crate::FileError> {
        crate::file::file_show(self, revision.as_ref(), paths)
    }

    /// Annotates one file line by line (Story 9.4) — the CLI's `jj file annotate`.
    ///
    /// Re-resolves to the head operation per call (ADR-0002). Read-only; never shells to
    /// `jj file annotate` (AR-AP-1), and never writes an operation.
    ///
    /// `path` is a PLAIN repo-relative path, not a fileset — it is `parse_file_path` in the
    /// CLI too, and prefix semantics would be meaningless for a single annotated file.
    /// `revision = None` is `@`, as for [`Repo::file_list`].
    ///
    /// The search domain is `all()`, hardcoded exactly as the CLI hardcodes it (it carries
    /// an upstream TODO about exposing one, and jj-lib silently under-reports for a
    /// non-contiguous domain — an option that can only produce wrong answers is not
    /// offered).
    ///
    /// One entry per line of the file, in file order, so a line's own 1-based number is its
    /// index in the returned `Vec` + 1 — which is why
    /// [`crate::AnnotationLine`] carries only `original_line_number`, the line's number in
    /// the ORIGINATING commit. Where the CLI collapses "the search stopped outside the
    /// domain" to the root commit for display, [`crate::AnnotationLine::origin_found`]
    /// keeps the distinction.
    ///
    /// # Errors
    ///
    /// - [`crate::FileError::ChangeNotFound`] — `revision` does not resolve.
    /// - [`crate::FileError::InvalidInput`] — `path` is not a valid repo path.
    /// - [`crate::FileError::PathNotFound`] — `path` is absent from the revision's tree.
    /// - [`crate::FileError::NotAFile`] — `path` exists but is not a regular file (a
    ///   directory, a symlink, a submodule, or a conflict with a non-file side).
    /// - [`crate::FileError::Backend`] — an underlying jj-lib failure.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    // WHY: see `file_list`.
    #[allow(clippy::needless_pass_by_value)]
    pub fn file_annotate(
        &self,
        revision: Option<crate::ChangeId>,
        path: &str,
    ) -> Result<Vec<crate::AnnotationLine>, crate::FileError> {
        crate::file::file_annotate(self.workspace(), revision.as_ref(), path)
    }

    /// Searches the files of a revision for `pattern` (Story 9.4) — the CLI's
    /// `jj file search`.
    ///
    /// Re-resolves to the head operation per call (ADR-0002). Read-only; never shells to
    /// `jj file search` (AR-AP-1), and never writes an operation.
    ///
    /// `pattern` is jj's own `kind:pattern` string-pattern syntax passed through verbatim
    /// (FR-JJ-17); a bare pattern defaults to kind `regex`, and the FIRST `:` is the
    /// separator. `revision` and `paths` behave as for [`Repo::file_list`].
    ///
    /// `name_only` is carried through because it changes the WORK done — a file's scan stops
    /// at its first match — not the rendering; the result shape is unchanged, so each
    /// matching file still contributes its first matching line, a superset of what the CLI
    /// prints. The CLI's `--line-number` has no counterpart: the result always carries
    /// [`crate::SearchMatch::line_number`], so there is nothing left for the flag to switch.
    ///
    /// A conflicted path is searched side by side, with `conflict_side` set and line numbers
    /// restarting at each side (the CLI's own choice — there is no meaningful unified
    /// numbering across sides). Symlinks, Git submodules, non-file conflicts, and paths whose
    /// blob cannot be read are silently not searched, as the CLI skips them.
    ///
    /// # Errors
    ///
    /// - [`crate::FileError::ChangeNotFound`] — `revision` does not resolve.
    /// - [`crate::FileError::InvalidInput`] — `pattern` names an unknown kind or does not
    ///   parse, or a `paths` entry is not a valid repo path.
    /// - [`crate::FileError::Backend`] — an underlying jj-lib failure.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    // WHY: see `file_list`.
    #[allow(clippy::needless_pass_by_value)]
    pub fn file_search(
        &self,
        revision: Option<crate::ChangeId>,
        pattern: &str,
        paths: &[String],
        name_only: bool,
    ) -> Result<Vec<crate::SearchMatch>, crate::FileError> {
        crate::file::file_search(self.workspace(), revision.as_ref(), pattern, paths, name_only)
    }

    /// Streams the commit graph of `revset` — one [`crate::GraphNode`] per commit, children
    /// before parents — through `visit`, in the order `jj log -r <revset>` prints it with
    /// `revsets.log-graph-prioritize = <prioritize>` (NFR-R-2, ADR-0003).
    ///
    /// Every node also carries its [`crate::CommitMeta`] — the `jj log`-parity display
    /// metadata — extracted from the SAME head-resolved snapshot in the same pass (Story
    /// 4.8), so a row's lanes and its content can never disagree.
    ///
    /// All three expressions are caller pass-throughs (FR-JJ-17);
    /// [`crate::DEFAULT_GRAPH_PRIORITIZE`] is the CLI's default for `prioritize` and
    /// [`crate::DEFAULT_LOG_REVSET`] the CLI's default for `revset` / `short_prefixes`
    /// (the repo's *effective* values are [`Repo::log_defaults`]). Aliases are resolved
    /// from the repo's effective jj config, builtin defaults included — a user's
    /// `[revset-aliases]` override of `trunk()` or `immutable_heads()` changes the row set
    /// and the per-row `immutable` flag exactly as it does in their CLI (Story 4.9). The
    /// config is re-read per call and never cached.
    /// Re-resolves to the head operation per call (ADR-0002); nothing is retained across
    /// calls. The stream is lazy: `visit` returning `ControlFlow::Break` stops it early, and
    /// the result is `Ok(Break)`; `Ok(Continue)` means the stream was exhausted. Read-only;
    /// never shells to `jj log` (AR-AP-1).
    ///
    /// `"none()"` is the canonical "no prioritization" value; an empty/blank `prioritize` is a
    /// [`crate::RevsetError::ParseError`], as the CLI fails on an empty config value. An EMPTY
    /// `short_prefixes` instead DISABLES prefix disambiguation (full-index prefix lengths) —
    /// the CLI's `revsets.short-prefixes` toggle semantic. The
    /// prioritized set (`prioritize ∩ revset`) is materialized before streaming — keep it small
    /// (the CLI default `present(@)` is one commit; `all()` would materialize every id). The
    /// `jj log` order parity holds for the CLI's graph mode without `--reversed`/`--limit`
    /// (paging/presentation concerns). Nodes already handed to `visit` before an `Err` are not
    /// retracted — discard partial output on `Err`. No internal locking: callers serialize
    /// access (single worker isolate, AD-2).
    ///
    /// # Errors
    ///
    /// - [`crate::RevsetError::ParseError`] — any expression is syntactically invalid.
    /// - [`crate::RevsetError::ResolutionError`] — a symbol in `revset` or `prioritize`
    ///   cannot be resolved. An unresolvable `short_prefixes` is NOT an error: like the
    ///   CLI, it warns and degrades to full-index prefix lengths.
    /// - [`crate::RevsetError::Config`] — the repo's effective jj config is malformed or
    ///   unreadable. A single bad `[revset-aliases]` entry is NOT an error: like the CLI, it
    ///   warns and is skipped.
    /// - [`crate::RevsetError::JjLibError`] — `load_at_head`, evaluation, metadata
    ///   extraction, or a per-item stream failure; the jj-lib reason is forwarded as a string.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    pub fn walk_graph(
        &self,
        revset: &str,
        prioritize: &str,
        short_prefixes: &str,
        visit: impl FnMut(crate::GraphNode) -> ControlFlow<()>,
    ) -> Result<ControlFlow<()>, crate::RevsetError> {
        crate::graph::walk_graph(self, revset, prioritize, short_prefixes, visit)
    }

    /// Streams the commits `revset` denotes through `visit`, one [`crate::Change`] per commit
    /// (ADR-0003 §5's generic read primitive).
    ///
    /// `revset` is a caller pass-through (FR-JJ-17); [`crate::DEFAULT_LOG_REVSET`] is the CLI's
    /// default and the repo's *effective* value is [`Repo::log_defaults`]. Aliases resolve from
    /// the repo's effective jj config, builtin defaults included, so a user's
    /// `[revset-aliases]` override of `trunk()` changes the denoted set exactly as it does in
    /// their CLI. The config is re-read per call and never cached; the repo is re-resolved to
    /// the head operation per call (ADR-0002).
    ///
    /// The walk is LAZY and the set is never materialized: `visit` returning
    /// [`ControlFlow::Break`] stops it and the result is `Ok(Break)`, while `Ok(Continue)` means
    /// the stream was exhausted. `Break` IS the limit — there is no `limit`/`start`/`count`
    /// parameter. Exactly one [`crate::Change`] is built per visited row; commit *loads* are
    /// pipelined a constant number ahead, so a `Break` may leave a few already dispatched —
    /// bounded by the backend's concurrency, never by the size of the set.
    ///
    /// One row per COMMIT, not per change: unlike [`crate::resolve_revset`], nothing is
    /// deduplicated, so a divergent change contributes one row per visible commit — each with the
    /// same [`crate::Change::id`] and `divergent` set. A caller keying rows by change id must
    /// handle that.
    ///
    /// Order is the RAW revset order — jj-lib's `Revset::stream()` contract, topological with
    /// children before parents. It is deliberately NOT `jj log`'s printed order: the
    /// topo-grouping and `revsets.log-graph-prioritize` handling that produce that order live in
    /// [`Repo::walk_graph`], and this primitive is the unopinionated one. Read-only; never
    /// shells to the `jj` CLI (AR-AP-1). Changes already handed to `visit` before an `Err` are
    /// not retracted — discard partial output on `Err`. No internal locking: callers serialize
    /// access (single worker isolate, AD-2).
    ///
    /// # Errors
    ///
    /// - [`crate::RevsetError::ParseError`] — `revset` is syntactically invalid or names an
    ///   unknown function; raised before any repo I/O.
    /// - [`crate::RevsetError::ResolutionError`] — a symbol cannot be resolved (unknown
    ///   bookmark/tag, no working-copy commit for `@`, unmatched/ambiguous id).
    /// - [`crate::RevsetError::Config`] — the repo's effective jj config is malformed or
    ///   unreadable. A single bad `[revset-aliases]` entry is NOT an error: like the CLI, it
    ///   warns and is skipped.
    /// - [`crate::RevsetError::JjLibError`] — `load_at_head`, evaluation, or a per-item
    ///   stream/store failure; the jj-lib reason is forwarded as a string.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    pub fn eval_revset(
        &self,
        revset: &str,
        visit: impl FnMut(crate::Change) -> ControlFlow<()>,
    ) -> Result<ControlFlow<()>, crate::RevsetError> {
        crate::revset::eval_revset(self, revset, visit)
    }

    /// Rewrites `change_id`'s description to `description` (FR-JJ-10a).
    ///
    /// Opens a jj-lib transaction, mutates via `tx.repo_mut()`, and commits with a
    /// CLI-parity op-log description (NFR-R-2) — jj-lib only, never shells to `jj`
    /// (AR-AP-1). `description` may be empty (jj convention).
    ///
    /// # Errors
    ///
    /// - [`crate::MutateError::ChangeNotFound`] — `change_id` is malformed, absent,
    ///   only-hidden, or divergent.
    /// - [`crate::MutateError::InvalidInput`] — `change_id` resolves to the root commit.
    /// - [`crate::MutateError::Immutable`] — `change_id` resolves to a non-root commit
    ///   inside the repo's effective immutable set.
    /// - [`crate::MutateError::Config`] — the repo's jj config or its
    ///   `revset-aliases."immutable_heads()"` could not be read, parsed, or resolved.
    /// - [`crate::MutateError::Backend`] — an underlying jj-lib failure.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    // WHY: signature (owned `ChangeId`) is fixed by epics.md Story 6.1 / AC-1; the
    // implementation only needs to borrow it, but the public API takes ownership.
    #[allow(clippy::needless_pass_by_value)]
    pub fn describe(
        &mut self,
        change_id: crate::ChangeId,
        description: &str,
    ) -> Result<crate::MutationResult, crate::MutateError> {
        // WHY: built from `&self` BEFORE `workspace_mut()` takes `&mut self`. The helper
        // returns an owned `Arc`, so the shared borrow ends here (Story 9.1).
        let immutable = crate::op_support::immutable_user_expression(self)?;
        crate::mutate::describe(self.workspace_mut(), &immutable, &change_id, description)
    }

    /// Creates a new, empty change on top of `parents` (FR-JJ-10a) — a merge commit
    /// when `parents.len() > 1` — and switches the working copy to it.
    ///
    /// # Errors
    ///
    /// - [`crate::MutateError::InvalidInput`] — `parents` is empty.
    /// - [`crate::MutateError::ChangeNotFound`] — a parent id is malformed, absent,
    ///   only-hidden, or divergent.
    /// - [`crate::MutateError::Backend`] — an underlying jj-lib failure.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    pub fn new_change(&mut self, parents: &[crate::ChangeId]) -> Result<crate::MutationResult, crate::MutateError> {
        crate::mutate::new_change(self.workspace_mut(), parents)
    }

    /// Switches the working copy to `change_id` without creating a new commit
    /// (FR-JJ-10a).
    ///
    /// # Errors
    ///
    /// - [`crate::MutateError::ChangeNotFound`] — `change_id` is malformed, absent,
    ///   only-hidden, or divergent.
    /// - [`crate::MutateError::Immutable`] — `change_id` resolves to a commit inside the
    ///   repo's effective immutable set (the root commit included — see
    ///   [`crate::MutateError::Immutable`]).
    /// - [`crate::MutateError::Config`] — the repo's jj config or its
    ///   `revset-aliases."immutable_heads()"` could not be read, parsed, or resolved.
    /// - [`crate::MutateError::Backend`] — an underlying jj-lib failure.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    // WHY: signature (owned `ChangeId`) is fixed by epics.md Story 6.1 / AC-1; the
    // implementation only needs to borrow it, but the public API takes ownership.
    #[allow(clippy::needless_pass_by_value)]
    pub fn edit(&mut self, change_id: crate::ChangeId) -> Result<crate::MutationResult, crate::MutateError> {
        // WHY: see `describe` — the expression is built while `self` is still shared.
        let immutable = crate::op_support::immutable_user_expression(self)?;
        crate::mutate::edit(self.workspace_mut(), &immutable, &change_id)
    }

    /// Abandons `change_ids`, rebasing descendants onto their parents and deleting any
    /// bookmarks that pointed only at the abandoned commits (FR-JJ-10a). If `@` itself
    /// is among `change_ids`, jj-lib creates a fresh empty commit at the (merged)
    /// parent(s) and repoints the working copy at it automatically — its change id is
    /// reported in the result's `new_change_ids`.
    ///
    /// # Errors
    ///
    /// - [`crate::MutateError::InvalidInput`] — `change_ids` is empty, or resolves the
    ///   root commit.
    /// - [`crate::MutateError::ChangeNotFound`] — a target id is malformed, absent,
    ///   only-hidden, or divergent.
    /// - [`crate::MutateError::Immutable`] — a target resolves to a non-root commit inside
    ///   the repo's effective immutable set.
    /// - [`crate::MutateError::Config`] — the repo's jj config or its
    ///   `revset-aliases."immutable_heads()"` could not be read, parsed, or resolved.
    /// - [`crate::MutateError::Backend`] — an underlying jj-lib failure.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    pub fn abandon(&mut self, change_ids: &[crate::ChangeId]) -> Result<crate::MutationResult, crate::MutateError> {
        // WHY: see `describe` — the expression is built while `self` is still shared.
        let immutable = crate::op_support::immutable_user_expression(self)?;
        crate::mutate::abandon(self.workspace_mut(), &immutable, change_ids)
    }

    /// Reverts the last operation, one step back from the current head (FR-JJ-14a).
    ///
    /// Mirrors the CLI's `jj undo`: restores the head operation's single parent's repo
    /// state + local bookmarks/tags + remote-tracking bookmarks (leaving `git_refs`/
    /// `git_head` untouched) onto a freshly-committed op. Calling `undo()` twice in a
    /// row redoes the first `undo()`.
    ///
    /// # Errors
    ///
    /// - [`crate::MutateError::NothingToUndo`] — the head operation IS the op-store root
    ///   (no parent to restore to).
    /// - [`crate::MutateError::InvalidInput`] — the head operation has more than one
    ///   parent (a divergent-write merge op) — undoing a merge operation is refused.
    /// - [`crate::MutateError::Backend`] — an underlying jj-lib failure.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    pub fn undo(&mut self) -> Result<crate::MutationResult, crate::MutateError> {
        crate::op_log::undo(self.workspace_mut())
    }

    /// Fetches all branches and tags from `remote_name` and imports them (FR-JJ-13).
    ///
    /// Always fetches ALL branches and tags — there is no branch/tag filter
    /// parameter (unlike the CLI's `jj git fetch -b`/`--branch`). Mirrors
    /// [`Repo::clone`]'s own fetch step, but forwards real progress via `progress`
    /// instead of discarding it, and never moves `@` — fetch only updates
    /// remote-tracking refs. A fresh operation is committed even when nothing changed
    /// (CLI parity).
    ///
    /// # Errors
    ///
    /// - [`crate::MutateError::RemoteNotFound`] — `remote_name` has no configured git
    ///   remote, or the repo has no git backend at all.
    /// - [`crate::MutateError::NetworkError`] — the underlying `git` subprocess
    ///   failed.
    /// - [`crate::MutateError::Backend`] — any other underlying jj-lib failure.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    pub fn git_fetch(
        &mut self,
        remote_name: &str,
        progress: &crate::ProgressFn,
    ) -> Result<crate::MutationResult, crate::MutateError> {
        crate::remotes::git_fetch(self.workspace(), self.settings(), remote_name, progress)
    }

    /// Reloads the workspace from disk so a freshly-written git config is visible.
    ///
    /// jj-lib's four remote mutators call `save_git_config()`, which writes the git config
    /// file immediately but does NOT update the already-loaded `GitBackend`'s in-memory gix
    /// config cache. Without this reload, `git_remote_add(…)` followed by `list_remotes()`
    /// on the SAME handle would return the pre-call list. This is exactly step 3 of
    /// [`Repo::clone_into`], which drops its throwaway transaction and reloads for the same
    /// reason.
    fn reload_workspace(&mut self) -> Result<(), crate::MutateError> {
        let root = self.workspace.workspace_root().to_owned();
        self.workspace = Workspace::load(
            &self.settings,
            &root,
            &default_backend_factories(),
            &default_working_copy_factories(),
        )
        .map_err(crate::mutate::be)?;
        Ok(())
    }

    /// Runs [`Repo::reload_workspace`] after a verb that rewrote the git config, on BOTH
    /// the success and the failure path — `remove_remote`/`rename_remote` write the config
    /// BEFORE the git-ref edits that can still fail, so a mid-verb failure would otherwise
    /// leave a stale cache behind.
    ///
    /// A reload failure is surfaced only when the verb itself succeeded: an already-failing
    /// call must keep its own error, which is the one that explains what the user did. That
    /// swallowing is why the reload failure is ALWAYS traced first — otherwise a stale
    /// config cache would silently outlive the call for the rest of the session, which is
    /// exactly the condition this helper exists to prevent.
    ///
    /// Neither ordering makes an `Err` mean "nothing happened" — see the four facades' docs.
    fn reload_after_config_write(
        &mut self,
        result: Result<crate::MutationResult, crate::MutateError>,
    ) -> Result<crate::MutationResult, crate::MutateError> {
        let reload = self.reload_workspace().inspect_err(|e| {
            tracing::warn!(error = %e, "git config was rewritten but the workspace could not be reloaded");
        });
        let value = result?;
        reload.map(|()| value)
    }

    /// Imports the backing git repo's refs into jj's view (Story 9.5) — the CLI's
    /// `jj git import`.
    ///
    /// Unlike the CLI this is NOT skipped in a colocated workspace. The CLI's skip exists
    /// because its own `workspace_helper` imports refs during its implicit per-command
    /// snapshot; Zanshin never snapshots (D2), so the premise is false here and the skip
    /// would make the verb unusable in exactly the repos that need it.
    ///
    /// `git.abandon-unreachable-commits` and `git.record-synthetic-predecessors` are read
    /// from the repo's EFFECTIVE config per call and never cached (FR-JJ-17). Per-remote
    /// `auto-track-bookmarks` is NOT honoured — [`Repo::git_fetch`] and `clone` already
    /// leave it empty, and changing that is a separate, three-call-site change.
    ///
    /// If nothing needed importing, NO operation is written and
    /// `GitImportResult::mutation.new_op_id` is the pre-call op-log head. A ref that could
    /// not be imported is reported in `failed_ref_names` and never fails the call — the CLI
    /// warns and exits 0.
    ///
    /// # Errors
    ///
    /// - [`crate::MutateError::NotAGitRepo`] — the workspace has no git backend.
    /// - [`crate::MutateError::Config`] — the repo's jj config, its
    ///   `revset-aliases."immutable_heads()"`, or one of the two `git.*` keys above could
    ///   not be read, parsed, or resolved.
    /// - [`crate::MutateError::Backend`] — an underlying jj-lib failure.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    pub fn git_import(&mut self) -> Result<crate::GitImportResult, crate::MutateError> {
        // WHY: both are built from `&self` BEFORE `workspace_mut()` takes `&mut self` —
        // the same borrow split `describe`/`restore` use.
        let immutable = crate::op_support::immutable_user_expression(self)?;
        let config = crate::config::load(self).map_err(crate::mutate::cfg)?;
        let options = crate::config::git_import_options(&config).map_err(crate::mutate::cfg)?;
        crate::git::git_import(self.workspace_mut(), &immutable, &options)
    }

    /// Writes jj's bookmarks and tags back to the backing git repo (Story 9.5) — the CLI's
    /// `jj git export`.
    ///
    /// Not skipped in a colocated workspace either — see [`Repo::git_import`] for why.
    /// Export rewrites no commit, so it needs neither the immutable set nor a descendant
    /// pass, and it never moves `@`.
    ///
    /// If git already matched, NO operation is written and
    /// `GitExportResult::mutation.new_op_id` is the pre-call op-log head. Refs that could
    /// not be written are reported in `failed_bookmarks` / `failed_tags` and never fail the
    /// call — the CLI warns and exits 0. The classic case is two bookmarks named `foo` and
    /// `foo/bar`, which git cannot both hold.
    ///
    /// # Errors
    ///
    /// - [`crate::MutateError::NotAGitRepo`] — the workspace has no git backend.
    /// - [`crate::MutateError::Backend`] — an underlying jj-lib failure.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    pub fn git_export(&mut self) -> Result<crate::GitExportResult, crate::MutateError> {
        crate::git::git_export(self.workspace_mut())
    }

    /// Registers a new git remote (Story 9.5) — the CLI's `jj git remote add`.
    ///
    /// `url` and `push_url` are passed through VERBATIM (FR-JJ-17); unlike the CLI, a
    /// relative local path is NOT resolved against a process CWD a GUI backend has no
    /// business consulting. The workspace is reloaded before returning, so
    /// [`Repo::list_remotes`] on this SAME handle sees the new remote immediately.
    ///
    /// Adding a remote WITH a push URL is worth one warning: jj-lib writes a `pushurl` key,
    /// and its own `remove_remote` then refuses that remote as
    /// [`crate::MutateError::RemoteNonstandardConfig`].
    ///
    /// **An `Err` does NOT mean "nothing happened."** jj-lib writes the git config file
    /// BEFORE the git-ref edits, and both happen before the transaction commits, so a
    /// refusal raised late can leave the config already rewritten; and a reload failure is
    /// reported only AFTER the operation has committed, discarding an otherwise-successful
    /// [`crate::MutationResult`]. Re-read [`Repo::list_remotes`] to learn the actual state
    /// rather than assuming the pre-call one.
    ///
    /// # Errors
    ///
    /// - [`crate::MutateError::RemoteExists`] — `name` is already taken.
    /// - [`crate::MutateError::InvalidInput`] — `name` is the reserved `git`, contains a
    ///   slash, or is not a valid gix remote name.
    /// - [`crate::MutateError::NotAGitRepo`] — the workspace has no git backend.
    /// - [`crate::MutateError::Backend`] — an underlying jj-lib failure.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    pub fn git_remote_add(
        &mut self,
        name: &str,
        url: &str,
        push_url: Option<&str>,
    ) -> Result<crate::MutationResult, crate::MutateError> {
        let result = crate::git::git_remote_add(self.workspace_mut(), name, url, push_url);
        self.reload_after_config_write(result)
    }

    /// Removes a git remote and forgets its bookmarks (Story 9.5) — the CLI's
    /// `jj git remote remove`.
    ///
    /// The workspace is reloaded before returning (see [`Repo::git_remote_add`]).
    /// Removing the reserved remote `git` succeeds and updates the git config and refs, but
    /// changes no jj view state, so NO operation is written and the returned `new_op_id` is
    /// the pre-call op-log head — the CLI behaves identically.
    ///
    /// Unlike the CLI, `.jj/repo/config.toml` is NOT edited: a `[remotes.<name>]` section
    /// survives, and a `revset-aliases.'trunk()'` pinned to this remote keeps naming it.
    ///
    /// **An `Err` does NOT mean "nothing happened."** jj-lib writes the git config file
    /// BEFORE the git-ref edits, and both happen before the transaction commits, so a
    /// refusal raised late can leave the config already rewritten; and a reload failure is
    /// reported only AFTER the operation has committed, discarding an otherwise-successful
    /// [`crate::MutationResult`]. Re-read [`Repo::list_remotes`] to learn the actual state
    /// rather than assuming the pre-call one.
    ///
    /// # Errors
    ///
    /// - [`crate::MutateError::RemoteNotFound`] — no such remote.
    /// - [`crate::MutateError::RemoteNonstandardConfig`] — jj refuses to rewrite this
    ///   remote's git config (a remote added with a push URL is exactly this case).
    /// - [`crate::MutateError::NotAGitRepo`] — the workspace has no git backend.
    /// - [`crate::MutateError::Backend`] — an underlying jj-lib failure.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    pub fn git_remote_remove(&mut self, name: &str) -> Result<crate::MutationResult, crate::MutateError> {
        let result = crate::git::git_remote_remove(self.workspace_mut(), name);
        self.reload_after_config_write(result)
    }

    /// Renames a git remote (Story 9.5) — the CLI's `jj git remote rename`.
    ///
    /// The workspace is reloaded before returning (see [`Repo::git_remote_add`]). Renaming
    /// FROM the reserved remote `git` writes no operation, for the same reason removing it
    /// does not. `.jj/repo/config.toml` is NOT edited — see [`Repo::git_remote_remove`].
    ///
    /// jj-lib validates `new_name` BEFORE it reports that `old_name` is missing, so
    /// `git_remote_rename("nonexistent", "git")` reports the reserved-name refusal. That
    /// ordering is jj-lib's own and is reproduced, not corrected.
    ///
    /// **An `Err` does NOT mean "nothing happened."** jj-lib writes the git config file
    /// BEFORE the git-ref edits, and both happen before the transaction commits, so a
    /// refusal raised late can leave the config already rewritten; and a reload failure is
    /// reported only AFTER the operation has committed, discarding an otherwise-successful
    /// [`crate::MutationResult`]. Re-read [`Repo::list_remotes`] to learn the actual state
    /// rather than assuming the pre-call one.
    ///
    /// # Errors
    ///
    /// - [`crate::MutateError::InvalidInput`] — `new_name` is the reserved `git`, contains
    ///   a slash, or is not a valid gix remote name.
    /// - [`crate::MutateError::RemoteNotFound`] — `old_name` has no configured remote.
    /// - [`crate::MutateError::RemoteExists`] — `new_name` is already taken.
    /// - [`crate::MutateError::RemoteNonstandardConfig`] — `old_name`'s git config is not
    ///   the plain single-fetch-refspec shape jj knows how to rewrite.
    /// - [`crate::MutateError::NotAGitRepo`] — the workspace has no git backend.
    /// - [`crate::MutateError::Backend`] — an underlying jj-lib failure.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    pub fn git_remote_rename(
        &mut self,
        old_name: &str,
        new_name: &str,
    ) -> Result<crate::MutationResult, crate::MutateError> {
        let result = crate::git::git_remote_rename(self.workspace_mut(), old_name, new_name);
        self.reload_after_config_write(result)
    }

    /// Re-points a git remote's fetch and/or push URL (Story 9.5) — the CLI's
    /// `jj git remote set-url`.
    ///
    /// NO operation is ever written: jj-lib's `set_remote_urls` takes a `&Store`, and the
    /// CLI opens no transaction either — so the returned `new_op_id` is always the pre-call
    /// op-log head. The workspace is still reloaded, so [`Repo::list_remotes`] on this same
    /// handle reports the new URL.
    ///
    /// A `None` URL leaves that side unchanged (jj-lib cannot REMOVE a URL). With BOTH
    /// `None` the call succeeds and does nothing — even for a remote that does not exist,
    /// because jj-lib returns early before its own existence check. That is mirrored
    /// deliberately.
    ///
    /// **An `Err` does NOT mean "nothing happened."** jj-lib writes the git config file
    /// BEFORE the git-ref edits, and both happen before the transaction commits, so a
    /// refusal raised late can leave the config already rewritten; and a reload failure is
    /// reported only AFTER the operation has committed, discarding an otherwise-successful
    /// [`crate::MutationResult`]. Re-read [`Repo::list_remotes`] to learn the actual state
    /// rather than assuming the pre-call one.
    ///
    /// # Errors
    ///
    /// - [`crate::MutateError::RemoteNotFound`] — at least one URL was supplied and `name`
    ///   has no configured remote.
    /// - [`crate::MutateError::InvalidInput`] — `name` is the reserved `git`, contains a
    ///   slash, or is not a valid gix remote name.
    /// - [`crate::MutateError::NotAGitRepo`] — the workspace has no git backend.
    /// - [`crate::MutateError::Backend`] — an underlying jj-lib failure.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    pub fn git_remote_set_url(
        &mut self,
        name: &str,
        url: Option<&str>,
        push_url: Option<&str>,
    ) -> Result<crate::MutationResult, crate::MutateError> {
        let result = crate::git::git_remote_set_url(self.workspace_mut(), name, url, push_url);
        self.reload_after_config_write(result)
    }

    /// Shows each revision `revset` denotes with what it changed (Story 9.6) — the CLI's
    /// `jj show`.
    ///
    /// Re-resolves to the head operation per call (ADR-0002). Read-only; never shells to
    /// `jj show` (AR-AP-1), and never writes an operation — not even on a refusal.
    ///
    /// `revset` is a caller pass-through EXPRESSION, not a change id (FR-JJ-17): the CLI takes
    /// `Vec<RevisionArg>` and unions them, so entries are per COMMIT — a revset naming two
    /// commits of ONE divergent change yields two entries carrying the same
    /// [`crate::Change::id`], both with `divergent` set. A BARE divergent change-id symbol does
    /// NOT get that far: jj-lib's own `SymbolResolver` refuses it
    /// (`RevsetResolutionError::DivergentChangeId`, `revset.rs:2827` @ 0.44.0), exactly as
    /// `jj show <divergent-id>` fails in the CLI, and it arrives here as
    /// [`crate::CommitViewError::RevsetResolutionError`]. Address both commits by unioning their
    /// COMMIT hexes, which are ordinary revset symbols. That is still a real, observable
    /// difference from [`Repo::interdiff`], which refuses the same change as
    /// [`crate::CommitViewError::ChangeNotFound`] from its own single-revision resolver.
    /// `None` applies the CLI's own default `@` — here the LAST-SNAPSHOTTED working-copy commit,
    /// because Zanshin never snapshots (D2).
    /// Aliases come from the repo's effective jj config, re-read per call and never cached.
    ///
    /// Entries come in RAW revset order (topological, children before parents); the CLI's
    /// `--reversed` is rendering and is not ported. Each entry's
    /// [`crate::ShowEntry::file_changes`] is the diff of the commit's MERGED parent tree
    /// against its own tree — for a merge commit, only what the merge itself changed; for the
    /// root commit, empty. Copy records are accumulated over EVERY parent, as the CLI's
    /// `show_patch` does, so a rename surfaces as one [`crate::ChangeKind::Renamed`] entry on a
    /// git-backed repo (the native backend reports no copies and degrades to an
    /// `Added`+`Removed` pair).
    ///
    /// There is no path argument and no textual patch: the CLI hardcodes `EverythingMatcher`,
    /// and line/word-level diffing is Epic 5's (`zanshin-diff`).
    ///
    /// # Errors
    ///
    /// - [`crate::CommitViewError::RevsetParseError`] — `revset` is syntactically invalid or
    ///   names an unknown function; raised before any repo read.
    /// - [`crate::CommitViewError::RevsetResolutionError`] — a symbol cannot be resolved.
    /// - [`crate::CommitViewError::Config`] — the repo's effective jj config is malformed or
    ///   unreadable.
    /// - [`crate::CommitViewError::Backend`] — an underlying jj-lib failure.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    pub fn show(&self, revset: Option<&str>) -> Result<Vec<crate::ShowEntry>, crate::CommitViewError> {
        crate::commit_views::show(self, revset)
    }

    /// Walks the evolution of the changes `revset` denotes (Story 9.6) — the CLI's `jj evolog`.
    ///
    /// Re-resolves to the head operation per call (ADR-0002). Read-only; never shells to
    /// `jj evolog` (AR-AP-1), and never writes an operation — not even on a refusal.
    ///
    /// `revset` behaves exactly as for [`Repo::show`] (a pass-through expression, `None` = `@`).
    /// `limit` is the CLI's `-n/--limit`, applied as `take(limit)` in WALK order: the CLI limits
    /// before reversing, and both the reversal and the `TopoGroupedGraph` re-ordering its graph
    /// mode applies are rendering the GUI does itself. `Some(0)` is an empty result, not an
    /// error.
    ///
    /// Rows carry COMMIT ids, not change ids: every predecessor shares the change's id, and
    /// predecessors are hidden by construction. [`crate::EvologEntry::operation_id`] is `None`
    /// exactly for the entries the walk flushes when it reaches an operation that stores no
    /// predecessors — the only signal that an evolution may be TRUNCATED, which the CLI leaves
    /// silent.
    ///
    /// The CLI's `-p/--patch` has no counterpart: it *is* an interdiff of each entry's
    /// predecessors. Note that [`Repo::interdiff`]'s change-id currency cannot address those
    /// predecessors — they are hidden — so the two verbs do NOT currently compose into it.
    ///
    /// [`crate::EvologEntry::change`] carries two fields derived against the CURRENT view
    /// rather than this version's moment (`divergent`, `is_anonymous`); see its doc.
    ///
    /// # Errors
    ///
    /// - [`crate::CommitViewError::RevsetParseError`] — `revset` is syntactically invalid.
    /// - [`crate::CommitViewError::RevsetResolutionError`] — a symbol cannot be resolved.
    /// - [`crate::CommitViewError::Config`] — the repo's effective jj config is malformed or
    ///   unreadable.
    /// - [`crate::CommitViewError::Backend`] — an underlying jj-lib failure, including jj-lib's
    ///   own predecessor-cycle detection.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    pub fn evolog(
        &self,
        revset: Option<&str>,
        limit: Option<usize>,
    ) -> Result<Vec<crate::EvologEntry>, crate::CommitViewError> {
        crate::commit_views::evolog(self, revset, limit)
    }

    /// Compares what two revisions each CHANGE, with the parent difference factored out
    /// (Story 9.6) — the CLI's `jj interdiff`.
    ///
    /// Re-resolves to the head operation per call (ADR-0002). Read-only; never shells to
    /// `jj interdiff` (AR-AP-1), and never writes an operation — not even on a refusal. Nothing
    /// is written by the rebase either: `rebase_to_dest_parent` merges in memory.
    ///
    /// Unlike [`Repo::show`], each side is a SINGLE revision, and it inherits the CLI's
    /// `resolve_single_rev` REFUSAL — a divergent id is rejected rather than guessed. It does
    /// NOT inherit the CLI's address space: a side is a reverse-hex CHANGE-ID prefix resolved
    /// to the one VISIBLE commit carrying it, so a commit hex, a revset expression (`main`,
    /// `@-`) and a HIDDEN commit are all unaddressable here, where the CLI accepts all three.
    /// That is the house currency (Story 9.3, FR-JJ-17); its consequence is that the
    /// predecessors [`Repo::evolog`] reports — hidden by construction — cannot be fed back in,
    /// so the two verbs do not compose into a diff of one version against the next.
    /// An absent side defaults to `@` — but omitting BOTH is a refusal, mirroring the CLI's
    /// `ArgGroup … required(true)`: interdiffing `@` against itself is trivially empty and
    /// never what a caller meant.
    ///
    /// `paths` entries are repo-relative paths interpreted as PREFIXES (an empty list means all
    /// paths); an empty-STRING entry is the repository root, which prefixes everything, so
    /// `paths = [""]` matches all paths just as `paths = []` does. The fileset DSL is terminal
    /// input language and is not parsed here. A filter that matches nothing yields an empty
    /// list, where the CLI prints a warning.
    ///
    /// NO `Renamed`/`Copied` entry is ever produced: the CLI's `show_inter_diff` passes
    /// `CopyRecords::default()`, and that asymmetry with [`Repo::show`] is reproduced
    /// deliberately, not corrected.
    ///
    /// # Errors
    ///
    /// - [`crate::CommitViewError::InvalidInput`] — both `from` and `to` are absent, or a
    ///   `paths` entry is not a valid repo path.
    /// - [`crate::CommitViewError::ChangeNotFound`] — `from` or `to` is malformed, carried by
    ///   no VISIBLE commit (unknown or only-hidden), or divergent. Not to be confused with
    ///   the ABSENT of the bullet above: ONE absent side is not an error, it is what applies
    ///   the CLI's `--from`/`--to` default `@`.
    /// - [`crate::CommitViewError::Backend`] — an underlying jj-lib failure.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    // WHY: owned `ChangeId`s match the house currency for single-revision parameters
    // (epics.md Story 6.1 / AC-1); the implementation only needs to borrow them.
    #[allow(clippy::needless_pass_by_value)]
    pub fn interdiff(
        &self,
        from: Option<crate::ChangeId>,
        to: Option<crate::ChangeId>,
        paths: &[String],
    ) -> Result<Vec<crate::FileChange>, crate::CommitViewError> {
        crate::commit_views::interdiff(self.workspace(), from.as_ref(), to.as_ref(), paths)
    }

    /// Lists every workspace with its working-copy commit and root directory (Story 9.7) — the
    /// CLI's `jj workspace list`.
    ///
    /// Re-resolves to the head operation per call (ADR-0002). Read-only; never shells to
    /// `jj workspace list` (AR-AP-1), and never writes an operation. Takes no argument: the CLI's
    /// only flag is `-T/--template`, which is rendering.
    ///
    /// This is [`Repo::list_working_copies`] plus the path half. The name/commit columns are
    /// literally that call's result — same values, same jj-lib `BTreeMap` order (lexicographic by
    /// workspace name) — and `root` is one `WorkspaceStore` lookup per row, canonicalized to an
    /// absolute path. The CLI's `root.relative()` rendering is not ported.
    ///
    /// A row whose path cannot be reported keeps its name and commit and reports
    /// [`crate::WorkspaceEntry::root`] as `None`: workspaces created before jj 0.38.0 have no
    /// recorded path, a store may be unreadable, and a recorded directory may have moved or been
    /// deleted. NONE of those fails the listing — the CLI degrades the same way
    /// (`cli/src/commit_templater.rs:1787` @ v0.44.0) and points at
    /// [`Repo::resolve_workspace_root`] for strict path diagnostics. That asymmetry between the
    /// two verbs is reproduced, not smoothed over.
    ///
    /// # Errors
    ///
    /// - [`crate::WorkspaceError::Backend`] — `load_at_head` failed, i.e. the VIEW half could not
    ///   be read; the jj-lib reason is forwarded as a string. No path failure reaches this.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    pub fn list_workspaces(&self) -> Result<Vec<crate::WorkspaceEntry>, crate::WorkspaceError> {
        crate::workspace::list_workspaces(self.workspace())
    }

    /// Returns a workspace's root directory (Story 9.7) — the CLI's `jj workspace root [--name]`.
    ///
    /// Read-only; never shells to `jj workspace root` (AR-AP-1), and never writes an operation —
    /// not even on a refusal. `name` is the CLI's long-only `--name`, passed through rather than
    /// defaulted here (FR-JJ-17); `None` is its documented default, the CURRENT workspace.
    ///
    /// `resolve_workspace_root(None)` returns exactly what the infallible
    /// [`Repo::workspace_root`] accessor returns, and reads the loader alone — no repo load, no
    /// store read (`cli/src/commands/workspace/root.rs:78` @ v0.44.0). That is the ONLY overlap
    /// between the two: with a name — even the CURRENT workspace's own — the call goes through
    /// the `WorkspaceStore` and can REFUSE, because the CLI's named path never shortcuts to the
    /// loader. A named lookup runs the CLI's four stages in ITS order (store load, view
    /// membership, recorded path, join + canonicalize), each with its own refusal, and returns an
    /// ABSOLUTE path — the CLI's CWD-relative rendering is the GUI's job.
    ///
    /// An explicitly present EMPTY name is a VALUE, not an absence: no workspace is named `""`,
    /// so it refuses as [`crate::WorkspaceError::NotFound`].
    ///
    /// # Errors
    ///
    /// - [`crate::WorkspaceError::NotFound`] — no workspace of that name is in the head view.
    /// - [`crate::WorkspaceError::NoRecordedPath`] — the workspace exists but the store holds no
    ///   path for it (it predates jj 0.38.0, or its entry was wiped).
    /// - [`crate::WorkspaceError::PathUnresolved`] — a path IS recorded but does not resolve; the
    ///   I/O reason rides in `reason`.
    /// - [`crate::WorkspaceError::Backend`] — the workspace store could not be loaded or read, or
    ///   `load_at_head` failed.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    pub fn resolve_workspace_root(&self, name: Option<&str>) -> Result<PathBuf, crate::WorkspaceError> {
        crate::workspace::resolve_root(self.workspace(), name)
    }

    /// Creates local bookmarks pointing at one revision (Story 9.8) — the CLI's
    /// `jj bookmark create`.
    ///
    /// `names` are DECODED bookmark names, not CLI argument text: the CLI validates each with
    /// `revset::parse_symbol`, so a name containing a space or an `@` has to be QUOTED on a
    /// terminal — and that quoting is exactly the terminal input syntax the GUI replaces
    /// (ADR-0003). Pass the name the user typed into the field. The one refusal kept from
    /// `parse_symbol` is the one no spelling can avoid: an EMPTY name.
    ///
    /// `revision` is the CLI's `-r/--revision`, whose clap `default_value` is the literal
    /// `"@"` — so `None` targets the working-copy commit, here the LAST-SNAPSHOTTED one since
    /// Zanshin never snapshots (D2). It is a change id, so it inherits `resolve_single_rev`'s
    /// ambiguity REFUSAL (a divergent id is rejected, never guessed) but not its address
    /// space: a commit hex, a revset expression and a hidden commit are unaddressable, the
    /// same trade [`Repo::interdiff`] and [`Repo::file_list`] document.
    ///
    /// Both per-name preconditions run in ARGUMENT order and are FAIL-FAST, as the CLI's are:
    /// a run whose second name already exists creates NOTHING — not even the first name — and
    /// writes no operation.
    ///
    /// Unlike the CLI, a created bookmark is never AUTO-TRACKED: honouring
    /// `remotes.<r>.auto-track-bookmarks` needs `track_remote_bookmark`, the verb Story 9.11
    /// owns. Deliberately deferred.
    ///
    /// # Errors
    ///
    /// - [`crate::MutateError::InvalidInput`] — `names` is empty, or a name is the empty
    ///   string.
    /// - [`crate::MutateError::ChangeNotFound`] — `revision` is malformed, carried by no
    ///   VISIBLE commit (unknown or only-hidden), or divergent. An ABSENT `revision` is not
    ///   an error: it is what applies the CLI's `-r` default `@`.
    /// - [`crate::MutateError::BookmarkExists`] — a name is already a local bookmark.
    /// - [`crate::MutateError::BookmarkTrackedRemoteExists`] — a name's local bookmark is
    ///   absent but it still has a tracked remote bookmark. A colocated `name@git` does NOT
    ///   count: the default-ignored remote is excluded, exactly as in the CLI.
    /// - [`crate::MutateError::Backend`] — an underlying jj-lib failure.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    pub fn bookmark_create(
        &mut self,
        names: &[String],
        revision: Option<&crate::ChangeId>,
    ) -> Result<crate::MutationResult, crate::MutateError> {
        crate::bookmark_ops::create(self.workspace_mut(), names, revision)
    }

    /// Deletes the local bookmarks matching `patterns` (Story 9.8) — the CLI's
    /// `jj bookmark delete`.
    ///
    /// Each entry is jj's own string-pattern syntax, passed through VERBATIM (FR-JJ-17) and
    /// unioned across the list; `exact:`, `glob:`, `regex:`, `substring:` and the `~`/`&`/`|`
    /// operators all work. **A BARE pattern is a GLOB, not an exact name** — deleting a
    /// bookmark whose name contains `*`, `?` or `[` requires `exact:"…"`, and a bare `foo*`
    /// deletes both a bookmark literally named `foo*` and one named `foo1`.
    ///
    /// Matching NOTHING is a SUCCESS, not a refusal: no operation is written and the returned
    /// `new_op_id` is the PRE-CALL op-log head — the machine-readable form of the CLI's "No
    /// bookmarks to delete." A CONFLICTED local bookmark is deleted like any other.
    ///
    /// A TRACKED `name@remote` SURVIVES, by design: [`Repo::list_bookmarks`] keeps reporting
    /// it, which is jj's "deleted bookmark, propagates on the next push" state rather than a
    /// leak. `jj bookmark forget` — the verb that drops the remote rows too — is Story 9.11's.
    ///
    /// # Errors
    ///
    /// - [`crate::MutateError::InvalidInput`] — `patterns` is empty, or a pattern does not
    ///   parse; jj-lib's reason is forwarded.
    /// - [`crate::MutateError::Backend`] — an underlying jj-lib failure.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    pub fn bookmark_delete(&mut self, patterns: &[String]) -> Result<crate::MutationResult, crate::MutateError> {
        crate::bookmark_ops::delete(self.workspace_mut(), patterns)
    }

    /// Gives the paths matching `paths` in one commit the content they have in another
    /// (Story 9.3) — the CLI's `jj restore`, whole-file only.
    ///
    /// Default resolution is the CLI's (`cli/src/commands/restore.rs:119-137` @ v0.44.0):
    /// if either `from` or `into` is given the omitted one is `@`; if NEITHER is given the
    /// destination is `changes_in` (or `@`) and the source is that commit's PARENT tree,
    /// which undoes its own diff while keeping its description. `changes_in` cannot be
    /// combined with `from`/`into` — the CLI's clap `conflicts_with_all`.
    ///
    /// `paths` entries are repo-relative paths interpreted as PREFIXES (an empty list means
    /// all paths); the fileset DSL is terminal input language and is not parsed here. An
    /// empty-STRING entry is the repository root, which prefixes everything, so `paths = [""]`
    /// matches all paths just as `paths = []` does — send an empty LIST to mean "no filter".
    /// `restore_descendants` reparents children (preserving their content) instead of
    /// rebasing them.
    ///
    /// A path that matches NOTHING in the two trees being compared is silently a no-op here,
    /// where the CLI prints a warning (`print_unmatched_explicit_paths`). That divergence is
    /// deliberate: [`crate::MutationResult`] has no warning channel, and adding one would
    /// change the payload of all six already-shipped mutation verbs. The GUI can detect the
    /// case itself — an unmatched filter leaves the destination tree unchanged, which this
    /// call reports as the no-op described above.
    ///
    /// If the resulting tree already equals the destination's, NO operation is written and
    /// the returned `new_op_id` is the pre-call op-log head — the CLI's own
    /// "Nothing changed." path.
    ///
    /// The working copy is NOT snapshotted first (D2): `@` is the last-snapshotted
    /// working-copy commit, where the CLI's `workspace_helper` would have picked up
    /// on-disk edits. Snapshotting is Story 9.22's scope.
    ///
    /// # Errors
    ///
    /// - [`crate::MutateError::InvalidInput`] — `changes_in` combined with `from`/`into`,
    ///   or a `paths` entry is not a valid repo path.
    /// - [`crate::MutateError::ChangeNotFound`] — `from`, `into` or `changes_in` is
    ///   malformed, carried by no VISIBLE commit (unknown or only-hidden), or divergent. An
    ///   ABSENT one is not an error: it is what selects the CLI's
    ///   `--from`/`--into`/`--changes-in` defaults described above.
    /// - [`crate::MutateError::Immutable`] — the destination resolves to a commit inside the
    ///   repo's effective immutable set. Unlike `describe`/`abandon` this verb has no
    ///   separate root-commit guard, so the ROOT commit reports this code too — which is
    ///   what the CLI reports for it.
    /// - [`crate::MutateError::Config`] — the repo's jj config or its
    ///   `revset-aliases."immutable_heads()"` could not be read, parsed, or resolved.
    /// - [`crate::MutateError::Backend`] — an underlying jj-lib failure.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    // WHY: owned `ChangeId`s match the house currency for single-revision parameters
    // (epics.md Story 6.1 / AC-1); the implementation only needs to borrow them.
    #[allow(clippy::needless_pass_by_value)]
    pub fn restore(
        &mut self,
        from: Option<crate::ChangeId>,
        into: Option<crate::ChangeId>,
        changes_in: Option<crate::ChangeId>,
        paths: &[String],
        restore_descendants: bool,
    ) -> Result<crate::MutationResult, crate::MutateError> {
        // WHY: see `describe` — the expression is built while `self` is still shared.
        let immutable = crate::op_support::immutable_user_expression(self)?;
        crate::mutate::restore(
            self.workspace_mut(),
            &immutable,
            from.as_ref(),
            into.as_ref(),
            changes_in.as_ref(),
            paths,
            restore_descendants,
        )
    }

    /// Moves each hunk of `from` into the closest commit in `destinations` where the
    /// corresponding lines were last modified (Story 9.3) — the CLI's `jj absorb`,
    /// non-interactive only.
    ///
    /// `from = None` is `@`. `destinations` is a revset EXPRESSION, not an id list: the CLI's
    /// `--into` is a set whose default is the dynamic `mutable()` alias, and materializing it
    /// into ids would destroy that meaning (FR-JJ-17). `None` applies the CLI's own clap
    /// default, `"mutable()"` — an ALIAS resolved through the repo's effective config, so a
    /// user's `[revset-aliases]` decides what it denotes.
    ///
    /// Parameter order follows the CLI's own reading ("absorb FROM … INTO …") and matches
    /// [`Repo::restore`], the `AbsorbRequest` wire table, and the Dart API.
    ///
    /// `paths` behaves exactly as for [`Repo::restore`], empty-string entry included. Hunks
    /// that cannot be attributed unambiguously stay in the source; paths jj-lib refuses to
    /// split are reported in [`crate::AbsorbResult::skipped_paths`] instead of failing the
    /// call — the CLI prints one warning per entry. If nothing is absorbable, NO operation is
    /// written and `rewritten_change_ids` is empty.
    ///
    /// Two CLI warnings have NO counterpart on the error path, because an `Err` carries no
    /// payload:
    ///
    /// - **Skipped paths are lost on a refusal.** They are computed before the rewritability
    ///   guard — the CLI's own order (`absorb.rs:154-158` warns, then `:160-162` checks) — but
    ///   an [`crate::MutateError::Immutable`] return discards them, so a caller sees the
    ///   refusal where a CLI user would ALSO have seen "Skipping <path>: <reason>". Surfacing
    ///   them would require an error variant carrying data, which no verb in this crate has.
    /// - **An explicitly named path that matches nothing is silent** — see [`Repo::restore`]
    ///   for why.
    ///
    /// The working copy is NOT snapshotted first (D2) — see [`Repo::restore`].
    ///
    /// # Errors
    ///
    /// - [`crate::MutateError::RevsetParseError`] — `destinations` is syntactically invalid
    ///   or names an unknown function.
    /// - [`crate::MutateError::RevsetResolutionError`] — a symbol in `destinations` cannot
    ///   be resolved.
    /// - [`crate::MutateError::InvalidInput`] — a `paths` entry is not a valid repo path.
    /// - [`crate::MutateError::ChangeNotFound`] — `from` is malformed, carried by no VISIBLE
    ///   commit (unknown or only-hidden), or divergent. An ABSENT `from` is not an error: it
    ///   is what applies the CLI's `--from` default `@`.
    /// - [`crate::MutateError::Immutable`] — a commit the hunks would be absorbed into is
    ///   inside the repo's effective immutable set. Unreachable with the `mutable()`
    ///   default, which excludes that set by construction.
    /// - [`crate::MutateError::Config`] — the repo's jj config or its
    ///   `revset-aliases."immutable_heads()"` could not be read, parsed, or resolved.
    /// - [`crate::MutateError::Backend`] — an underlying jj-lib failure.
    #[must_use = "the Result must be used; drop it explicitly if intentional"]
    // WHY: see `restore` — owned `ChangeId` is the house currency for a single revision.
    #[allow(clippy::needless_pass_by_value)]
    pub fn absorb(
        &mut self,
        from: Option<crate::ChangeId>,
        destinations: Option<&str>,
        paths: &[String],
    ) -> Result<crate::AbsorbResult, crate::MutateError> {
        // WHY: see `describe` — both expressions are built while `self` is still shared.
        let immutable = crate::op_support::immutable_user_expression(self)?;
        // WHY the literal: it is the CLI's own clap default for `--into`
        // (`cli/src/commands/absorb.rs:64` @ v0.44.0), and it is an ALIAS — `config.rs`'s
        // builtin layer defines `'mutable()' = '~immutable()'`, which a user's config may
        // replace. The default is therefore a pre-filled, user-editable value that resolves
        // through the effective config layer, never a hardcoded commit set.
        let destinations =
            crate::revset::parse_revset(self, destinations.unwrap_or("mutable()")).map_err(crate::mutate::rev)?;
        crate::mutate::absorb(self.workspace_mut(), &immutable, from.as_ref(), &destinations, paths)
    }

    /// Opens an existing jj workspace rooted at `path`.
    ///
    /// # Errors
    ///
    /// Returns [`RepoError::PathNotFound`] if `path` does not exist,
    /// [`RepoError::NotARepo`] if `.jj` is absent, or [`RepoError::Backend`] on jj-lib failure.
    pub fn open(path: &Path) -> Result<Self, RepoError> {
        if !path.exists() {
            return Err(RepoError::PathNotFound { path: path.to_owned() });
        }
        if !path.join(".jj").is_dir() {
            return Err(RepoError::NotARepo { path: path.to_owned() });
        }
        let settings = make_settings()?;
        let workspace = Workspace::load(
            &settings,
            path,
            &default_backend_factories(),
            &default_working_copy_factories(),
        )
        .map_err(|e| RepoError::Backend(e.to_string()))?;
        Ok(Self { workspace, settings })
    }

    /// Initialises a new jj workspace at `path`.
    ///
    /// `backend = Some(Backend::Git)` creates a git-backed workspace;
    /// `backend = None` uses jj's native backend.
    ///
    /// # Errors
    ///
    /// Returns [`RepoError::InitFailed`] on jj-lib workspace initialisation failure.
    pub fn init(path: &Path, backend: Option<Backend>) -> Result<Self, RepoError> {
        let settings = make_settings()?;
        let (workspace, _repo) = match backend {
            // WHY: `object_hash` is jj 0.44's new parameter. jj's CLI resolves it from the
            // `git.object-hash` config, whose builtin default is "sha1" — passing `Sha1` here
            // mirrors that default and reproduces pre-0.44 behaviour exactly.
            // TODO(FR-JJ-17, Epic 9 Story 9.20): resolve `object_hash` the way the CLI does
            // (`git.object-hash` config, caller-overridable) instead of hardcoding it here and in
            // `clone_into`; until then a user configuring "sha256" silently gets sha1.
            Some(Backend::Git) => {
                pollster::block_on(Workspace::init_internal_git(&settings, path, gix::hash::Kind::Sha1))
                    .map_err(|e| RepoError::InitFailed { reason: e.to_string() })?
            }
            None => pollster::block_on(Workspace::init_simple(&settings, path))
                .map_err(|e| RepoError::InitFailed { reason: e.to_string() })?,
        };
        Ok(Self { workspace, settings })
    }

    /// Clones a remote Git repository into a new jj workspace at `target_path`.
    ///
    /// Composes: `init_internal_git` → `add_remote("origin")` → `GitFetch::fetch` → `import_refs`,
    /// then points the working copy at the fetched default branch (a fresh `@` commit on its tip).
    ///
    /// On failure, any partial workspace created under `target_path` is rolled back so a
    /// retry into the same path starts clean.
    ///
    /// # Errors
    ///
    /// Returns [`RepoError::CloneFailed`] if init, remote registration, fetch, or import fails.
    pub fn clone(url: &str, target_path: &Path) -> Result<Self, RepoError> {
        let settings = make_settings()?;
        let created_dir = !target_path.exists();

        match Self::clone_into(&settings, url, target_path) {
            Ok(workspace) => Ok(Self { workspace, settings }),
            Err(e) => {
                // Roll back only what clone created: the whole dir if we created it,
                // otherwise just the `.jj/` that init_internal_git wrote.
                if created_dir {
                    let _ = std::fs::remove_dir_all(target_path);
                } else {
                    let _ = std::fs::remove_dir_all(target_path.join(".jj"));
                }
                Err(e)
            }
        }
    }

    /// Composes the clone steps, returning the workspace reloaded at the committed head.
    fn clone_into(settings: &UserSettings, url: &str, target_path: &Path) -> Result<Workspace, RepoError> {
        // Step 1: Create git-backed jj workspace.
        // WHY: `gix::hash::Kind::Sha1` mirrors jj's own `git.object-hash` default (see
        // `Repo::init`); making it a caller parameter is Story 9.20's scope.
        let (_workspace_init, repo) = pollster::block_on(Workspace::init_internal_git(
            settings,
            target_path,
            gix::hash::Kind::Sha1,
        ))
        .map_err(|e| RepoError::CloneFailed { reason: e.to_string() })?;

        let remote_name_buf: RemoteNameBuf = "origin".into();
        let remote_name: &RemoteName = &remote_name_buf;

        // Step 2: Write remote to disk via a throwaway transaction.
        // add_remote calls save_git_config() which writes to disk immediately but
        // does NOT update the gix::ThreadSafeRepository's in-memory config cache.
        // We therefore drop this transaction without committing — its only purpose
        // is the disk side-effect. Step 3 reloads from disk to pick it up.
        {
            let mut tx = repo.start_transaction();
            // WHY: jj 0.44 dropped `add_remote`'s trailing `fetch_tags` argument — tag selection
            // is now driven purely by the fetch refspec, and it is `fetch_expr.tag` below (not
            // `.bookmark`) that carries it: glob("*"), i.e. the same "all tags" behaviour the old
            // `Tags::All` requested.
            jj_lib::git::add_remote(tx.repo_mut(), remote_name, url, None)
                .map_err(|e| RepoError::CloneFailed { reason: e.to_string() })?;
            // tx is intentionally dropped without commit.
        }

        // Step 3: Reload workspace so Workspace::load constructs a fresh Store /
        // GitBackend that reads the git config from disk (now containing "origin").
        let mut workspace = Workspace::load(
            settings,
            target_path,
            &default_backend_factories(),
            &default_working_copy_factories(),
        )
        .map_err(|e| RepoError::CloneFailed { reason: e.to_string() })?;
        let workspace_name = workspace.workspace_name().to_owned();

        let fresh_repo = pollster::block_on(workspace.repo_loader().load_at_head())
            .map_err(|e| RepoError::CloneFailed { reason: e.to_string() })?;

        // Step 4: Fetch + import refs using the fresh repo whose GitBackend sees "origin".
        let subprocess_options = GitSubprocessOptions::from_settings(settings)
            .map_err(|e| RepoError::CloneFailed { reason: e.to_string() })?;

        let import_options = GitImportOptions {
            record_synthetic_predecessors: false,
            abandon_unreachable_commits: true,
            remote_auto_track_bookmarks: std::collections::HashMap::new(),
        };

        let fetch_expr = GitFetchRefExpression {
            bookmark: StringExpression::Pattern(Box::new(
                // WHY: glob("*") selects all remote branches for a full clone.
                StringPattern::glob("*").map_err(|e| RepoError::CloneFailed { reason: e.to_string() })?,
            )),
            tag: StringExpression::Pattern(Box::new(
                // WHY: glob("*") selects all remote tags for a full clone.
                StringPattern::glob("*").map_err(|e| RepoError::CloneFailed { reason: e.to_string() })?,
            )),
        };
        let refspecs = expand_fetch_refspecs(remote_name, fetch_expr)
            .map_err(|e| RepoError::CloneFailed { reason: e.to_string() })?;

        let import_stats;
        let default_branch;
        let mut tx = fresh_repo.start_transaction();
        {
            let mut_repo = tx.repo_mut();
            let mut fetcher = GitFetch::new(mut_repo, subprocess_options, &import_options)
                .map_err(|e| RepoError::CloneFailed { reason: e.to_string() })?;
            // TODO(FR-JJ-13, Epic 6 Story 6.4a): wire NativeCallable progress callback
            // WHY: `depth: None` = a full (non-shallow) clone. jj 0.44 dropped `fetch`'s
            // trailing `fetch_tags_override`, so the 0.42 call's second `None` is the one that
            // went away — the remaining one is `depth`, unchanged.
            let depth = None;
            fetcher
                .fetch(remote_name, refspecs, &mut NoopCallback, depth)
                .map_err(|e| RepoError::CloneFailed { reason: e.to_string() })?;
            import_stats = pollster::block_on(fetcher.import_refs())
                .map_err(|e| RepoError::CloneFailed { reason: e.to_string() })?;
            default_branch = fetcher
                .get_default_branch(remote_name)
                .map_err(|e| RepoError::CloneFailed { reason: e.to_string() })?;
        }

        // Point `@` at the fetched default branch: create a fresh working-copy commit
        // on its tip so the cloned workspace shows the default branch's files.
        let target_commit_id = default_branch.as_ref().and_then(|branch| {
            import_stats.changed_remote_bookmarks.iter().find_map(|update| {
                if &update.symbol.name == branch && update.symbol.remote == remote_name_buf {
                    update.new_target.as_normal()
                } else {
                    None
                }
            })
        });

        let new_wc_commit = match target_commit_id {
            Some(commit_id) => {
                let mut_repo = tx.repo_mut();
                let commit = mut_repo
                    .store()
                    .get_commit(commit_id)
                    .map_err(|e| RepoError::CloneFailed { reason: e.to_string() })?;
                let wc_commit = pollster::block_on(mut_repo.check_out(workspace_name.clone(), &commit))
                    .map_err(|e| RepoError::CloneFailed { reason: e.to_string() })?;
                // check_out rewrites the working-copy commit; jj requires descendants to be
                // rebased before the transaction can commit.
                pollster::block_on(mut_repo.rebase_descendants())
                    .map_err(|e| RepoError::CloneFailed { reason: e.to_string() })?;
                Some(wc_commit)
            }
            None => None,
        };

        let new_repo =
            pollster::block_on(tx.commit("clone")).map_err(|e| RepoError::CloneFailed { reason: e.to_string() })?;

        // Materialise the working copy on disk to match the new `@` commit.
        if let Some(wc_commit) = &new_wc_commit {
            pollster::block_on(workspace.check_out(new_repo.op_id().clone(), None, wc_commit))
                .map_err(|e| RepoError::CloneFailed { reason: e.to_string() })?;
        }

        // Reload so the returned handle reflects the committed clone + checked-out working copy.
        let workspace = Workspace::load(
            settings,
            target_path,
            &default_backend_factories(),
            &default_working_copy_factories(),
        )
        .map_err(|e| RepoError::CloneFailed { reason: e.to_string() })?;

        Ok(workspace)
    }
}

/// No-op subprocess callback — discards all progress and sideband output.
/// Replaced by a `NativeCallable` in Epic 6 Story 6.4a (FR-JJ-13).
struct NoopCallback;

impl GitSubprocessCallback for NoopCallback {
    fn needs_progress(&self) -> bool {
        false
    }

    fn progress(&mut self, _progress: &GitProgress) -> io::Result<()> {
        Ok(())
    }

    fn local_sideband(&mut self, _message: &[u8], _term: Option<GitSidebandLineTerminator>) -> io::Result<()> {
        Ok(())
    }

    fn remote_sideband(&mut self, _message: &[u8], _term: Option<GitSidebandLineTerminator>) -> io::Result<()> {
        Ok(())
    }
}

pub(crate) fn make_settings() -> Result<UserSettings, RepoError> {
    let mut config = StackedConfig::with_defaults();
    config.add_layer(
        ConfigLayer::parse(
            ConfigSource::User,
            r#"
                    [user]
                    name = "Zanshin"
                    email = "zanshin@localhost"
                    [operation]
                    username = "zanshin"
                    hostname = "localhost"
                "#,
        )
        .map_err(|e| RepoError::Backend(e.to_string()))?,
    );
    UserSettings::from_config(config).map_err(|e| RepoError::Backend(e.to_string()))
}
