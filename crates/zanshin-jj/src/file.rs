// SPDX-License-Identifier: MIT

//! `file.rs` — the four `jj file` READ verbs of ADR-0003: `list`, `show`, `annotate`,
//! `search` (Story 9.4, Epic 9 Tier A).
//!
//! Every operation resolves to the head operation per call (ADR-0002), reads a committed
//! tree, and returns `jj_lib`-type-free owned data. The read itself writes no operation — not
//! even on a refusal; like the CLI's `workspace_helper`, [`crate::Repo`] snapshots the working
//! copy FIRST (Story 9.26), and that snapshot is what may write one. An omitted `revision` is
//! therefore the up-to-date `@`, on-disk edits included.
//!
//! CLI parity is at tag **v0.46.0** (`cli/src/commands/file/{list,show,annotate,search}.rs`)
//! for the observable behavior — defaults, refusals, skip rules, pattern parsing — never for
//! its terminal UX (NFR-R-2, ADR-0003): `-T/--template` and `--line-number` render text and
//! are dropped, because the typed result already carries the structured fields they would
//! have formatted. `--name-only` IS carried through: it changes the WORK done (a file's scan
//! stops at its first match), not the rendering.
//!
//! Resource note: `MaterializedFileValue::read_all` and `materialize_merge_result_to_bytes`
//! have no size cap, so [`file_show`] and [`file_search`] hold whole files in memory where
//! the CLI streams to stdout. That is a resource divergence, not a behavioral one.

use std::collections::HashMap;
use std::sync::Arc;

use jj_lib::annotate::FileAnnotator;
use jj_lib::backend::TreeValue;
use jj_lib::backend::{MergedTreeValue, MergedTreeValueExt as _};
use jj_lib::commit::Commit;
use jj_lib::conflict_labels::ConflictLabels;
use jj_lib::conflicts::{
    materialize_merge_result_to_bytes, materialize_tree_value, resolve_file_executable, ConflictMaterializeOptions,
    MaterializedTreeValue,
};
use jj_lib::id_prefix::IdPrefixContext;
use jj_lib::object_id::ObjectId as _;
use jj_lib::repo::{ReadonlyRepo, Repo as _};
use jj_lib::repo_path::{RepoPath, RepoPathBuf};
use jj_lib::revset::RevsetExpression;
use jj_lib::store::Store;
use jj_lib::str_util::StringPattern;
use jj_lib::workspace::Workspace;

use crate::op_support::{build_matcher, parse_prefixes, resolve_or_wc, ResolveError};
use crate::warning::{self, WarningKind, Warnings};
use crate::{ChangeId, CommitId, SkippedPath};

/// What a tree entry IS, mirroring the CLI's `TreeEntry.file_type` keyword
/// (`cli/src/commit_templater.rs::describe_file_type` @ v0.46.0).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FileType {
    /// A regular file.
    File,
    /// A symbolic link.
    Symlink,
    /// A directory. UNREACHABLE through [`crate::Repo::file_list`] — `entries_matching`
    /// recurses into subtrees rather than yielding them — but modelled so the mapping from
    /// jj's own tree-value kinds is total.
    Tree,
    /// A Git submodule.
    GitSubmodule,
    /// An unresolved conflict. The number of sides is
    /// [`FileEntry::conflict_side_count`]; a subtree that conflicts with a non-tree lands
    /// here as ONE entry and is not descended into, so a GUI file tree must render it as an
    /// opaque conflict rather than an empty directory.
    Conflict,
}

/// One entry of a revision's tree, modelled on the CLI's `TreeEntry` keywords.
///
/// The CLI's `conflict` keyword (`!value.is_resolved()`) has no field of its own: it is
/// exactly `file_type == FileType::Conflict`, so carrying it too would be a second,
/// desyncable spelling of one fact.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FileEntry {
    /// Repo-relative path in jj's internal (`/`-separated) form.
    pub path: String,
    /// What the entry is.
    pub file_type: FileType,
    /// The executable bit. `false` for a symlink, a submodule, and for a conflict whose
    /// sides disagree about it — the CLI's `is_executable_file(...).unwrap_or_default()`.
    pub executable: bool,
    /// Number of sides of the SIMPLIFIED merge: `1` for a resolved entry, `≥ 2` for a
    /// conflict (the CLI's `conflict_side_count` keyword). `Merge::num_sides()` is
    /// `values.len() / 2 + 1`, so the SMALLEST conflict — a 3-term merge — has two sides.
    /// Saturates at [`u32::MAX`].
    pub conflict_side_count: u32,
}

/// One file's content as `jj file show` would print it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ShownFile {
    /// Repo-relative path in jj's internal (`/`-separated) form.
    pub path: String,
    /// The file's bytes. NOT guaranteed UTF-8 — a tracked file may be binary. For a
    /// conflicted path this is the MATERIALIZED merge, with conflict markers in the style
    /// the repo's effective `ui.conflict-marker-style` selects.
    pub content: Vec<u8>,
    /// Whether `content` is a materialized conflict rather than a resolved file.
    pub conflict: bool,
}

/// The result of `jj file show`: the files that could be rendered, plus the paths that
/// could not.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FileContents {
    /// One entry per rendered file, in `entries_matching` (tree) order.
    pub files: Vec<ShownFile>,
    /// Paths that are not renderable as file content — a symlink, a Git submodule, a path
    /// whose blob could not be read, and the two cases the CLI `panic!`s on rather than
    /// reports (`"Path '…' is absent."`, `"Path '…' is a directory."`). The CLI prints one
    /// warning per entry and keeps going; dropping them would leave a file silently missing
    /// from the result with no way for a GUI to say why.
    pub skipped: Vec<SkippedPath>,
}

/// One annotated line of a file — `jj file annotate`'s per-line row.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AnnotationLine {
    /// Hex commit id of the commit the line originates from.
    pub commit_id: CommitId,
    /// Reverse-hex change id of that same commit, resolved once per DISTINCT commit
    /// (the CLI does one `get_commit_async` per LINE).
    pub change_id: ChangeId,
    /// 1-BASED line number the line had in `commit_id`'s version of the file. jj-lib
    /// reports this 0-based; the `+1` matches what the CLI renders. Saturates at
    /// 4294967295, as [`FileEntry::conflict_side_count`] does.
    pub original_line_number: u32,
    /// The raw line, newline included when the source line had one. NOT guaranteed UTF-8.
    pub content: Vec<u8>,
    /// `true` when the originating commit was found inside the search domain; `false` when
    /// the search stopped at the domain boundary and `commit_id` is only where it stopped.
    /// The CLI collapses this distinction to the root commit for display — this API keeps
    /// it. There is deliberately no `line_number` field: it is the 1-based index in the
    /// returned `Vec`.
    pub origin_found: bool,
}

/// One matching line of `jj file search`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SearchMatch {
    /// Repo-relative path in jj's internal (`/`-separated) form.
    pub path: String,
    /// 1-based line number WITHIN the searched content. For a conflicted path the count
    /// restarts at each side (`conflict_side`) — there is no meaningful unified numbering
    /// across sides, which is the CLI's own reasoning at `search.rs:146-147`. Saturates at
    /// 4294967295, as [`FileEntry::conflict_side_count`] does.
    pub line_number: u32,
    /// The raw matching line, newline included when the source line had one.
    pub content: Vec<u8>,
    /// 0-based index of the conflict side this line came from, or `None` for a resolved
    /// file — null-for-absence. Saturates at 4294967295, as
    /// [`FileEntry::conflict_side_count`] does.
    pub conflict_side: Option<u32>,
}

/// The result of `jj file search`: the matching lines, plus the paths that could not be
/// searched.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FileSearch {
    /// One entry per matching line, in `entries_matching` (tree) order then line order.
    pub matches: Vec<SearchMatch>,
    /// Paths whose blob could NOT be read. This carries `AccessDenied` and nothing else,
    /// because that is the only case `jj file search` warns about
    /// (`cli/src/commands/file/search.rs:109-115` @ v0.46.0); symlinks, Git submodules and
    /// non-file conflicts are skipped SILENTLY there and never appear here — the exact
    /// OPPOSITE of `jj file show`, whose [`FileContents::skipped`] reports them.
    ///
    /// An unreadable blob is not an error: the call succeeds for the remaining paths.
    /// Without this channel a GUI could not tell "nothing matched" from "a blob was
    /// unreadable", which is why it exists.
    pub skipped: Vec<SkippedPath>,
}

/// Errors returned by [`crate::Repo::file_list`], [`crate::Repo::file_show`],
/// [`crate::Repo::file_annotate`] and [`crate::Repo::file_search`].
#[derive(Debug, thiserror::Error)]
pub enum FileError {
    /// The pre-verb snapshot failed (Story 9.26), so the read never ran — see
    /// [`crate::PreconditionError`].
    #[error(transparent)]
    Precondition(#[from] crate::PreconditionError),
    /// The `revision` argument is malformed or carried by no VISIBLE commit (unknown or
    /// only-hidden) — the same refusal `mutate.rs` makes. Not to be confused with an ABSENT
    /// `revision`, which is not an error at all: it applies the CLI's `-r` default `@`.
    #[error("change not found: {id}")]
    ChangeNotFound {
        /// The reverse-hex change id that could not be resolved.
        id: String,
    },
    /// The `revision` argument does not resolve to ONE commit, as the CLI's `-r`
    /// (`resolve_single_rev`) refuses it: an AMBIGUOUS change-id prefix, a DIVERGENT change, a
    /// `revsets.short-prefixes` set that fails to load, or an ABSENT `revision`'s `@` in a
    /// workspace with no working-copy commit. `reason` is jj-lib's own
    /// `RevsetResolutionError` text.
    #[error("revset resolution error: {reason}")]
    RevsetResolutionError {
        /// jj-lib's resolution error text.
        reason: String,
        /// The CLI's hints for it (a divergent change's three); empty otherwise.
        hints: Vec<String>,
    },
    /// The path does not exist in the target revision's tree (the CLI's
    /// `No such path: …`).
    #[error("path not found: {path}")]
    PathNotFound {
        /// The repo-relative path that is absent from the tree.
        path: String,
    },
    /// The path exists but is not a regular file, so it cannot be annotated (the CLI's
    /// `Path exists but is not a regular file: …`). Distinct from
    /// [`FileError::PathNotFound`] on purpose: "you selected a directory" and "you mistyped
    /// the path" need different remedies.
    #[error("path exists but is not a regular file: {path}")]
    NotAFile {
        /// The repo-relative path that is not a regular file.
        path: String,
    },
    /// The caller's arguments are structurally invalid: a `paths` entry is not a valid repo
    /// path, `file_show` was given no paths at all (the CLI marks FILESETS `required`), or
    /// a search pattern does not parse.
    #[error("invalid input: {reason}")]
    InvalidInput {
        /// Human-readable reason the input was rejected.
        reason: String,
    },
    /// The repo's effective jj config is unreadable or malformed, so
    /// [`crate::Repo::file_show`] cannot learn which `ui.conflict-marker-style` to
    /// materialize a conflict with. Reported separately from [`FileError::Backend`] because
    /// it is the user's own config that is wrong, not the repository — the same distinction
    /// every other config-reading verb makes (`log_defaults`, `graph_topology`, the Story
    /// 9.1/9.3 mutations).
    #[error("config error: {reason}")]
    Config {
        /// Human-readable reason the effective config could not be used.
        reason: String,
    },
    /// An underlying jj-lib failure, opaque-string-wrapped so no `jj_lib` type escapes the
    /// public API (FR-JJ-16).
    #[error("jj-lib error: {0}")]
    Backend(String),
}

/// Converts any jj-lib error to [`FileError::Backend`].
fn be<E: std::fmt::Display>(e: E) -> FileError {
    FileError::Backend(e.to_string())
}

/// Converts a config-stack failure to [`FileError::Config`].
fn cfg<E: std::fmt::Display>(e: E) -> FileError {
    FileError::Config { reason: e.to_string() }
}

/// Converts a shared [`ResolveError`] to this module's taxonomy.
fn res(e: ResolveError, revision: Option<&ChangeId>) -> FileError {
    match e {
        ResolveError::NotFound => FileError::ChangeNotFound {
            id: revision.map(|r| r.0.clone()).unwrap_or_default(),
        },
        // The CLI gives `WorkspaceMissingWorkingCopy` no hints
        // (`cli/src/command_error.rs:971-976` @ v0.46.0).
        ResolveError::NoWorkingCopy(reason) => FileError::RevsetResolutionError { reason, hints: vec![] },
        ResolveError::Resolution { reason, hints } => FileError::RevsetResolutionError { reason, hints },
        ResolveError::Backend(reason) => FileError::Backend(reason),
    }
}

/// Parses one caller-supplied repo path exactly as [`parse_prefixes`] parses each
/// entry (Story 9.53): `.` components drop and `..` pops, as the CLI's `parse_file_path` from the
/// workspace root; a path that leaves the repo, or is malformed, is invalid input.
fn parse_path(path: &str) -> Result<RepoPathBuf, FileError> {
    parse_prefixes(std::slice::from_ref(&path.to_owned()))
        .map(|mut parsed| parsed.swap_remove(0))
        .map_err(|reason| FileError::InvalidInput { reason })
}

/// Re-resolves to the head operation and resolves `revision` (or `@`) to its commit, through
/// `prefixes` — the call's `revsets.short-prefixes` context.
///
/// The single ADR-0002 entry point all four verbs share; the returned `ReadonlyRepo` is the
/// snapshot every subsequent read in the call is taken from, so a concurrent operation can
/// never make two halves of one result disagree.
fn head_commit(
    workspace: &Workspace,
    prefixes: &IdPrefixContext,
    revision: Option<&ChangeId>,
) -> Result<(Arc<ReadonlyRepo>, Commit), FileError> {
    let readonly = crate::snapshot::reload_head(workspace).map_err(be)?;
    let commit = resolve_or_wc(readonly.as_ref(), workspace.workspace_name(), prefixes, revision)
        .map_err(|e| res(e, revision))?;
    Ok((readonly, commit))
}

/// Classifies a tree value the way the CLI's `describe_file_type` does.
///
/// `None` is jj's `""` (absent) case, which `entries_matching` never yields and
/// `path_value` is guarded against before this is called — so a `None` entry is silently
/// dropped rather than fabricating a variant for a state the API cannot observe.
fn file_type_of(value: &MergedTreeValue) -> Option<FileType> {
    match value.as_resolved() {
        Some(Some(TreeValue::File { .. })) => Some(FileType::File),
        Some(Some(TreeValue::Symlink(_))) => Some(FileType::Symlink),
        Some(Some(TreeValue::Tree(_))) => Some(FileType::Tree),
        Some(Some(TreeValue::GitSubmodule(_))) => Some(FileType::GitSubmodule),
        Some(None) => None,
        None => Some(FileType::Conflict),
    }
}

/// The executable bit as the CLI's `is_executable_file(...).unwrap_or_default()` reports it.
fn is_executable(value: &MergedTreeValue) -> bool {
    value
        .to_executable_merge()
        .and_then(|merge| resolve_file_executable(&merge))
        .unwrap_or_default()
}

/// Projects one tree entry into a [`FileEntry`].
fn to_file_entry(path: &RepoPath, value: &MergedTreeValue) -> Option<FileEntry> {
    Some(FileEntry {
        path: path.as_internal_file_string().to_owned(),
        file_type: file_type_of(value)?,
        executable: is_executable(value),
        // WHY saturate: the count is a display figure for the UI, never something a
        // decision keys off, and a merge with four billion sides is not worth failing over.
        conflict_side_count: u32::try_from(value.simplify().num_sides()).unwrap_or(u32::MAX),
    })
}

/// Lists the entries of `revision`'s tree that match `paths` (Story 9.4).
///
/// Ports `cli/src/commands/file/list.rs::cmd_file_list` @ v0.46.0: resolve the revision,
/// take its tree, build the matcher, walk `entries_matching`. The CLI has NO refusals here
/// at all — a path matching nothing only produces a trailing warning
/// (`print_unmatched_explicit_paths`), recorded into `sink` as `jj.paths_unmatched`
/// (Story 9.32).
///
/// # Errors
///
/// - [`FileError::ChangeNotFound`] — `revision` is malformed or carried by no VISIBLE commit
///   (unknown or only-hidden). Not to be confused with an ABSENT `revision`, which is not an
///   error at all: it applies the CLI's `-r` default `@`.
/// - [`FileError::RevsetResolutionError`] — `revision` is an ambiguous prefix or a divergent
///   change, or `revsets.short-prefixes` fails to load.
/// - [`FileError::InvalidInput`] — a `paths` entry is not a valid repo path.
/// - [`FileError::Backend`] — the head load or a tree read failed.
#[must_use = "the Result must be used; drop it explicitly if intentional"]
pub(crate) fn file_list(
    workspace: &Workspace,
    sink: &mut Warnings,
    prefixes: &IdPrefixContext,
    revision: Option<&ChangeId>,
    paths: &[String],
) -> Result<Vec<FileEntry>, FileError> {
    let (_readonly, commit) = head_commit(workspace, prefixes, revision)?;
    let matcher = build_matcher(paths).map_err(|reason| FileError::InvalidInput { reason })?;
    let tree = commit.tree();

    let mut out = Vec::new();
    for (path, value) in tree.entries_matching(matcher.as_ref()) {
        let value = value.map_err(be)?;
        if let Some(entry) = to_file_entry(&path, &value) {
            out.push(entry);
        }
    }
    warn_unmatched(workspace, sink, paths, &tree)?;
    Ok(out)
}

/// `print_unmatched_explicit_paths(…, [&tree])` over the explicit `paths` — the trailing
/// warning every multi-entry file read prints (Story 9.32).
///
/// # Errors
///
/// - [`FileError::InvalidInput`] — an entry is not a valid repo path.
/// - [`FileError::Backend`] — a tree read failed.
fn warn_unmatched(
    workspace: &Workspace,
    sink: &mut Warnings,
    paths: &[String],
    tree: &jj_lib::merged_tree::MergedTree,
) -> Result<(), FileError> {
    let explicit = parse_prefixes(paths).map_err(|reason| FileError::InvalidInput { reason })?;
    warning::warn_unmatched_paths(sink, workspace.workspace_root(), &explicit, &[tree]).map_err(be)
}

/// A conflicted file's text: its terms merged and materialized with conflict markers — what
/// `file show` prints and the builtin diff editor sections (`read_file_contents`,
/// `cli/src/merge_tools/builtin.rs:178-198` @ v0.46.0). The one place both cut it.
fn conflict_text(
    file: &jj_lib::conflicts::MaterializedFileConflictValue,
    options: &ConflictMaterializeOptions,
) -> Vec<u8> {
    materialize_merge_result_to_bytes(&file.contents, &file.labels, options).into()
}

/// One side of a changed path as the builtin diff editor reads it, when it is FILE-LIKE: a
/// resolved regular file, or a file conflict.
pub(crate) struct FileLike {
    /// The builtin editor's mode: a resolved file's bit; a conflict's merged bit, `true` only when
    /// it resolves to executable.
    pub(crate) executable: bool,
    /// Its content; a conflict materialized with markers ([`conflict_text`]).
    pub(crate) content: Vec<u8>,
}

/// `value` read as the builtin diff editor reads one side of a diff (`read_file_contents`,
/// `builtin.rs:124-218` @ v0.46.0), with `labels` its tree's conflict labels — `None` unless it
/// is file-like (absent, a symlink, a submodule, a non-file conflict, an unreadable file).
///
/// # Errors
///
/// A backend read failed.
pub(crate) async fn materialize_file_like(
    store: &Store,
    path: &RepoPath,
    value: MergedTreeValue,
    labels: &ConflictLabels,
    options: &ConflictMaterializeOptions,
) -> jj_lib::backend::BackendResult<Option<FileLike>> {
    Ok(match materialize_tree_value(store, path, value, labels).await? {
        MaterializedTreeValue::File(mut file) => Some(FileLike {
            executable: file.executable,
            content: file.read_all(path).await?,
        }),
        MaterializedTreeValue::FileConflict(file) => Some(FileLike {
            executable: file.executable == Some(true),
            content: conflict_text(&file, options),
        }),
        _ => None,
    })
}

/// What [`render_entry`] makes of one tree value: the file, or the path it skipped together with
/// the warning the CLI prints for it — `None` for the two cases the CLI `panic!`s on instead.
type Rendered = Result<ShownFile, (SkippedPath, Option<WarningKind>)>;

/// Renders one materialized tree value into either a [`ShownFile`] or a [`SkippedPath`].
fn render_entry(
    store: &Arc<Store>,
    path: &RepoPath,
    value: MergedTreeValue,
    labels: &ConflictLabels,
    options: &ConflictMaterializeOptions,
) -> Result<Rendered, FileError> {
    let display = path.as_internal_file_string().to_owned();
    let materialized = pollster::block_on(materialize_tree_value(store, path, value, labels)).map_err(be)?;
    let shown = |content: Vec<u8>, conflict: bool| ShownFile {
        path: display.clone(),
        content,
        conflict,
    };
    // WHY the CLI's exact sentences: they are what a jj user sees for these paths, and a
    // GUI showing the same wording needs no translation table (NFR-R-2).
    let skipped = |reason: String, kind: Option<WarningKind>| {
        (
            SkippedPath {
                path: display.clone(),
                reason,
            },
            kind,
        )
    };
    Ok(match materialized {
        MaterializedTreeValue::File(mut file) => {
            let content = pollster::block_on(file.read_all(path)).map_err(be)?;
            Ok(shown(content, false))
        }
        MaterializedTreeValue::FileConflict(file) => Ok(shown(conflict_text(&file, options), true)),
        MaterializedTreeValue::OtherConflict { id, labels } => Ok(shown(id.describe(&labels).into_bytes(), true)),
        MaterializedTreeValue::Symlink { .. } | MaterializedTreeValue::GitSubmodule(_) => Err(skipped(
            format!("Path '{display}' exists but is not a file."),
            Some(WarningKind::PathNotAFile),
        )),
        MaterializedTreeValue::AccessDenied(e) => Err(skipped(
            format!("Path '{display}' exists but access is denied: {e}"),
            Some(WarningKind::PathAccessDenied),
        )),
        // The CLI `panic!`s on both; a library must not abort the process on a path a
        // caller could in principle reach, so each becomes a SkippedPath naming what it is
        // — the call still succeeds for the remaining paths. No warning: the CLI prints none.
        // `entries_matching` never yields either, and the single-path branch guards absent.
        MaterializedTreeValue::Absent => Err(skipped(format!("Path '{display}' is absent."), None)),
        MaterializedTreeValue::Tree(_) => Err(skipped(format!("Path '{display}' is a directory."), None)),
    })
}

/// Prints the contents of the files selected by `paths` in `revision` (Story 9.4).
///
/// Ports `cli/src/commands/file/show.rs::cmd_file_show` @ v0.46.0, both branches: with
/// exactly ONE path the CLI takes a fast path through `tree.path_value` (absent ⇒ refuse,
/// non-tree ⇒ render that single entry), otherwise it walks `entries_matching`. A directory
/// is visited recursively either way.
///
/// Takes the crate's [`crate::Repo`] rather than a bare `Workspace` because materializing a
/// conflict needs `ConflictMaterializeOptions.marker_style`, which is the repo's effective
/// `ui.conflict-marker-style` — re-read per call, never cached, never a Rust constant.
///
/// Warnings (Story 9.32), in the CLI's order: one per skipped path as it is rendered
/// (`jj.path_access_denied` / `jj.path_not_a_file` — the CLI's own sentences), then — on the
/// multi-entry branch only — `jj.paths_unmatched`.
///
/// # Errors
///
/// - [`FileError::InvalidInput`] — `paths` is empty (the CLI marks FILESETS `required`), or
///   an entry is not a valid repo path or leaves the repo through `..` (`./x` and `a/../x` read
///   `x` on both branches, Story 9.53).
/// - [`FileError::ChangeNotFound`] / [`FileError::RevsetResolutionError`] — `revision` does
///   not resolve (see [`file_list`]).
/// - [`FileError::PathNotFound`] — exactly one path was given and it is absent from the
///   tree; it names the resolved path.
/// - [`FileError::Config`] — the effective jj config is unreadable or malformed (including
///   an `ui.conflict-marker-style` that is not one of jj's four style names).
/// - [`FileError::Backend`] — the head load or a blob read failed.
#[must_use = "the Result must be used; drop it explicitly if intentional"]
pub(crate) fn file_show(
    repo: &crate::Repo,
    sink: &mut Warnings,
    prefixes: &IdPrefixContext,
    revision: Option<&ChangeId>,
    paths: &[String],
) -> Result<FileContents, FileError> {
    if paths.is_empty() {
        return Err(FileError::InvalidInput {
            reason: "at least one path is required".to_owned(),
        });
    }
    let config = crate::config::load(repo).map_err(cfg)?;
    let marker_style = crate::config::conflict_marker_style(&config).map_err(cfg)?;

    let (readonly, commit) = head_commit(repo.workspace(), prefixes, revision)?;
    let store = readonly.store().clone();
    let options = ConflictMaterializeOptions {
        marker_style,
        marker_len: None,
        merge: store.merge_options().clone(),
    };
    let tree = commit.tree();

    let mut out = FileContents {
        files: Vec::new(),
        skipped: Vec::new(),
    };
    let mut push = |rendered: Rendered, sink: &mut Warnings| match rendered {
        Ok(file) => out.files.push(file),
        Err((skipped, kind)) => {
            if let Some(kind) = kind {
                sink.push(kind, skipped.reason.clone());
            }
            out.skipped.push(skipped);
        }
    };

    // Fast path for a single entry — the CLI's `get_single_path` branch, which is also the
    // ONLY place `jj file show` refuses an absent path.
    if let [single] = paths {
        let path = parse_path(single)?;
        let value = pollster::block_on(tree.path_value(&path)).map_err(be)?;
        if value.is_absent() {
            return Err(FileError::PathNotFound {
                path: path.as_internal_file_string().to_owned(),
            });
        }
        if !value.is_tree() {
            push(render_entry(&store, &path, value, tree.labels(), &options)?, sink);
            return Ok(out);
        }
    }

    let matcher = build_matcher(paths).map_err(|reason| FileError::InvalidInput { reason })?;
    for (path, value) in tree.entries_matching(matcher.as_ref()) {
        let value = value.map_err(be)?;
        push(render_entry(&store, &path, value, tree.labels(), &options)?, sink);
    }
    warn_unmatched(repo.workspace(), sink, paths, &tree)?;
    Ok(out)
}

/// Annotates `path` in `revision` line by line (Story 9.4).
///
/// Ports `cli/src/commands/file/annotate.rs::cmd_file_annotate` @ v0.46.0. `path` is a
/// PLAIN path, not a fileset — it is `parse_file_path` in the CLI too. Both guards run
/// BEFORE the annotator because `FileAnnotator::from_commit` returns an EMPTY annotation
/// for a missing file rather than an error.
///
/// The search domain is hardcoded to `all()`, exactly as the CLI does (it carries an
/// upstream TODO about exposing one, and jj-lib silently under-reports for a non-contiguous
/// domain — an option that can only produce wrong answers is not offered).
///
/// # KNOWN DIVERGENCE: a missing origin commit fails the call
///
/// For a line whose origin search stopped outside the domain, this resolves
/// `origin.commit_id` in the store; the CLI substitutes the ROOT commit instead
/// (`cli/src/commands/file/annotate.rs:124-129` @ v0.46.0), and its comment says WHY: a repo
/// that was jj-initialized shallowly and then unshallow'd with git has commits jj never
/// imported, so that id may be ABSENT from the store. There, the CLI still renders every
/// line; here the store read fails and the whole call becomes [`FileError::Backend`].
/// The fallback is deliberately NOT implemented: no fixture in this repo can construct a
/// shallow-then-unshallowed history, so the extra branch would be unreachable by any test
/// and the coverage ratchet would reject it. Implement it together with a test that can
/// reach it.
///
/// # Errors
///
/// - [`FileError::ChangeNotFound`] / [`FileError::RevsetResolutionError`] — `revision` does
///   not resolve (see [`file_list`]).
/// - [`FileError::InvalidInput`] — `path` is not a valid repo path or leaves the repo through
///   `..` (`invalid path: Path "../x" is not in the repo "."`); `./x` and `a/../x` read `x`, as
///   the CLI's `parse_file_path` from the workspace root (Story 9.53).
/// - [`FileError::PathNotFound`] — `path` is absent from the revision's tree.
/// - [`FileError::NotAFile`] — `path` exists but is not a regular file (a directory, a
///   symlink, a submodule, or a conflict with a non-file side). Both name the resolved path.
/// - [`FileError::Backend`] — the head load, the annotation walk, or a store read failed.
#[must_use = "the Result must be used; drop it explicitly if intentional"]
pub(crate) fn file_annotate(
    workspace: &Workspace,
    prefixes: &IdPrefixContext,
    revision: Option<&ChangeId>,
    path: &str,
) -> Result<Vec<AnnotationLine>, FileError> {
    let file_path = parse_path(path)?;
    let (readonly, commit) = head_commit(workspace, prefixes, revision)?;

    let value = pollster::block_on(commit.tree().path_value(&file_path)).map_err(be)?;
    let display = file_path.as_internal_file_string().to_owned();
    if value.is_absent() {
        return Err(FileError::PathNotFound { path: display });
    }
    if value.to_file_merge().is_none() {
        return Err(FileError::NotAFile { path: display });
    }

    let mut annotator = pollster::block_on(FileAnnotator::from_commit(&commit, &file_path)).map_err(be)?;
    pollster::block_on(annotator.compute(readonly.as_ref(), &RevsetExpression::all())).map_err(be)?;
    let annotation = annotator.to_annotation();

    // Commit id → change id, resolved once per DISTINCT commit. The CLI does one
    // `get_commit_async` per LINE; a thousand-line file annotated to three commits is three
    // store reads here.
    let mut change_ids: HashMap<jj_lib::backend::CommitId, ChangeId> = HashMap::new();
    let mut out = Vec::new();
    for (origin, line) in annotation.line_origins() {
        let (origin_found, origin) = match origin {
            Ok(o) => (true, o),
            Err(o) => (false, o),
        };
        let change_id = if let Some(id) = change_ids.get(&origin.commit_id) {
            id.clone()
        } else {
            // DIVERGENCE (documented on this fn): the CLI substitutes the root commit here
            // because on a shallow-then-unshallowed repo this id may be absent from the
            // store; ours propagates the read failure instead — no fixture can reach that
            // state, so a fallback branch would be untestable.
            let commit = readonly.store().get_commit(&origin.commit_id).map_err(be)?;
            let id = ChangeId(commit.change_id().reverse_hex());
            change_ids.insert(origin.commit_id.clone(), id.clone());
            id
        };
        out.push(AnnotationLine {
            commit_id: CommitId(origin.commit_id.hex()),
            change_id,
            // jj-lib's `LineOrigin.line_number` is 0-based; the CLI adds 1 before display.
            original_line_number: u32::try_from(origin.line_number.saturating_add(1)).unwrap_or(u32::MAX),
            content: line.to_vec(),
            origin_found,
        });
    }
    Ok(out)
}

/// Splits `pattern` into jj's `kind:pattern` form, exactly as `search.rs:95-101` does.
///
/// A bare pattern (no `:`) defaults to kind `regex`; the FIRST `:` is the separator, so
/// `substring:a:b` is the substring `a:b`.
fn parse_pattern(pattern: &str) -> Result<StringPattern, FileError> {
    let parsed = match pattern.split_once(':') {
        Some((kind, rest)) => StringPattern::from_str_kind(rest, kind),
        None => StringPattern::from_str_kind(pattern, "regex"),
    };
    parsed.map_err(|e| FileError::InvalidInput { reason: e.to_string() })
}

/// Appends every matching line of `content` to `out`.
///
/// Re-splits with `split_inclusive(b'\n')` + `enumerate()` because jj-lib's
/// `StringMatcher::match_lines` yields matching lines WITHOUT their indices — which is
/// exactly why the CLI's `write_matches` re-splits too. The trailing newline is stripped
/// before matching but KEPT in the reported bytes, again as the CLI does.
///
/// Returns `true` if at least one match was appended.
fn collect_matches(
    path: &str,
    content: &[u8],
    matcher: &jj_lib::str_util::StringMatcher,
    conflict_side: Option<u32>,
    name_only: bool,
    out: &mut Vec<SearchMatch>,
) -> bool {
    let mut found = false;
    for (i, line) in content.split_inclusive(|b| *b == b'\n').enumerate() {
        let stripped = line.strip_suffix(b"\n").unwrap_or(line);
        if !matcher.is_match_bytes(stripped) {
            continue;
        }
        found = true;
        out.push(SearchMatch {
            path: path.to_owned(),
            line_number: u32::try_from(i.saturating_add(1)).unwrap_or(u32::MAX),
            content: line.to_vec(),
            conflict_side,
        });
        if name_only {
            break;
        }
    }
    found
}

/// Searches the files of `revision` matching `paths` for `pattern` (Story 9.4).
///
/// Ports `cli/src/commands/file/search.rs::cmd_file_search` @ v0.46.0. `pattern` is jj's
/// `kind:pattern` string-pattern syntax, defaulting to `regex`. Symlinks, Git submodules and
/// non-file conflicts are silently not searched, exactly as the CLI skips them
/// (`search.rs:134, :159-161`); a path whose blob cannot be READ is reported in
/// [`FileSearch::skipped`] with the CLI's own warning sentence (`search.rs:109-115`), which
/// is the only case it warns about.
///
/// `name_only` stops a file's scan at its FIRST match — it changes the work done, not the
/// result shape, so each file still contributes its first matching line. That is a superset
/// of the CLI's output, which prints only the path.
///
/// Warnings (Story 9.32): `jj.path_access_denied` per unreadable blob as it is reached, then
/// `jj.paths_unmatched`.
///
/// # Errors
///
/// - [`FileError::ChangeNotFound`] / [`FileError::RevsetResolutionError`] — `revision` does
///   not resolve (see [`file_list`]).
/// - [`FileError::InvalidInput`] — `pattern` names an unknown kind or does not parse, or a
///   `paths` entry is not a valid repo path.
/// - [`FileError::Backend`] — the head load or a blob read failed.
#[must_use = "the Result must be used; drop it explicitly if intentional"]
pub(crate) fn file_search(
    workspace: &Workspace,
    sink: &mut Warnings,
    prefixes: &IdPrefixContext,
    revision: Option<&ChangeId>,
    pattern: &str,
    paths: &[String],
    name_only: bool,
) -> Result<FileSearch, FileError> {
    let matcher = parse_pattern(pattern)?.to_matcher();
    let path_matcher = build_matcher(paths).map_err(|reason| FileError::InvalidInput { reason })?;
    let (readonly, commit) = head_commit(workspace, prefixes, revision)?;
    let store = readonly.store().clone();
    let tree = commit.tree();

    let mut out = Vec::new();
    let mut skipped = Vec::new();
    for (path, value) in tree.entries_matching(path_matcher.as_ref()) {
        let value = value.map_err(be)?;
        let display = path.as_internal_file_string().to_owned();
        let materialized =
            pollster::block_on(materialize_tree_value(&store, &path, value, tree.labels())).map_err(be)?;
        match materialized {
            MaterializedTreeValue::File(mut file) => {
                let content = pollster::block_on(file.read_all(&path)).map_err(be)?;
                collect_matches(&display, &content, &matcher, None, name_only, &mut out);
            }
            MaterializedTreeValue::FileConflict(file) => {
                // Line numbers restart per side: there is no meaningful unified numbering
                // across sides (the CLI's own reasoning at `search.rs:146-147`).
                for (side, content) in file.contents.adds().enumerate() {
                    let side = u32::try_from(side).unwrap_or(u32::MAX);
                    let found = collect_matches(&display, content, &matcher, Some(side), name_only, &mut out);
                    // `--name-only` names a FILE, so one hit on any side ends the file.
                    if name_only && found {
                        break;
                    }
                }
            }
            // An unreadable blob is the ONE case `jj file search` warns about
            // (`search.rs:109-115`), so it gets a SkippedPath rather than silence. The
            // sentence is search's own — `file show`'s wording is a different verb's
            // contract and must not be reused here (NFR-R-2).
            MaterializedTreeValue::AccessDenied(e) => {
                let reason = format!("Skipping '{display}' due to permission error: {e}");
                sink.push(WarningKind::PathAccessDenied, reason.clone());
                skipped.push(SkippedPath { reason, path: display });
            }
            // Silently not searched — CLI parity (`search.rs:134, :159-160`). `Absent` and
            // `Tree` are `panic!`s the walk cannot actually produce.
            MaterializedTreeValue::Symlink { .. }
            | MaterializedTreeValue::GitSubmodule(_)
            | MaterializedTreeValue::OtherConflict { .. }
            | MaterializedTreeValue::Absent
            | MaterializedTreeValue::Tree(_) => {}
        }
    }
    warn_unmatched(workspace, sink, paths, &tree)?;
    Ok(FileSearch { matches: out, skipped })
}

#[cfg(test)]
mod tests {
    use jj_lib::backend::{CopyId, FileId, SymlinkId, TreeId, TreeValue};
    use jj_lib::id_prefix::IdPrefixContext;
    use jj_lib::merge::Merge;

    use super::{
        collect_matches, file_type_of, is_executable, parse_path, parse_pattern, res, ChangeId, FileError, FileType,
        ResolveError,
    };

    /// A head that no longer loads is this module's own `Backend` failure. Through
    /// [`crate::Repo`] the pre-verb snapshot (Story 9.26) hits it first, so the module function
    /// is called directly.
    #[test]
    fn a_head_that_no_longer_loads_is_a_backend_error() {
        let (_tmp, repo) = crate::test_support::repo_with_a_broken_head();
        let result = super::file_list(
            repo.workspace(),
            &mut crate::warning::Warnings::default(),
            &IdPrefixContext::default(),
            None,
            &[],
        );
        assert!(matches!(result, Err(FileError::Backend(_))), "{result:?}");
    }

    /// `file_show`'s own read of `ui.conflict-marker-style` refuses a wrong value as a config
    /// fault. Through [`crate::Repo`] the pre-verb snapshot (Story 9.26) re-reads the changed
    /// stack first and refuses before it, so the module function is called directly.
    #[test]
    fn file_show_refuses_a_malformed_conflict_marker_style_as_config() {
        test_helpers::pin_test_env();
        let tmp = tempfile::TempDir::new().expect("tempdir");
        let repo = crate::Repo::init(&crate::InitOptions {
            path: std::path::PathBuf::from(tmp.path()),
            ..Default::default()
        })
        .result
        .expect("init");
        std::fs::write(
            repo.workspace().repo_path().join("config.toml"),
            "ui.conflict-marker-style = \"bogus\"\n",
        )
        .expect("repo config");
        let result = super::file_show(
            &repo,
            &mut crate::warning::Warnings::default(),
            &IdPrefixContext::default(),
            None,
            &["a.txt".to_owned()],
        );
        assert!(
            matches!(&result, Err(FileError::Config { reason }) if reason.contains("conflict-marker-style")),
            "{result:?}"
        );
    }

    /// `file_search` reports an UNREADABLE blob in `skipped`, with `jj file search`'s own
    /// warning sentence, while every other matching file still reports normally.
    ///
    /// **Why this test is INLINE rather than in `tests/`.** `MaterializedTreeValue::AccessDenied`
    /// comes from exactly one jj-lib error (`BackendError::ReadAccessDenied`), which exactly one
    /// backend raises: the `testing`-gated `SecretBackend`, which refuses any path containing
    /// `secret`. That backend cannot be reached through [`crate::Repo`] — `Repo::open` hardcodes
    /// `default_backend_factories()` and this change deliberately does NOT widen it — so the
    /// witness builds the `Workspace` itself and calls the `pub(crate)` [`super::file_search`]
    /// directly. Corrupting or chmod-ing a git object produces a DIFFERENT `BackendError`, which
    /// surfaces as [`FileError::Backend`], so there is no public-API construction to use instead.
    #[test]
    fn file_search_reports_an_unreadable_blob_as_skipped() {
        use jj_lib::default_backend_factories::{default_backend_factories, default_working_copy_factories};
        use jj_lib::repo::Repo as _;
        use jj_lib::secret_backend::SecretBackend;
        use jj_lib::workspace::Workspace;
        use test_helpers::{add_commit_with_entries, extract_fixture, Entry};

        test_helpers::pin_test_env();
        let fx = extract_fixture("tiny-3-commits").expect("fixture extracts");
        // `secret.txt` is refused by SecretBackend purely because of its PATH; `plain.txt`
        // carries the same needle and must still match, which is what makes this a skip
        // rather than a failed call.
        let commit_hex = add_commit_with_entries(
            &fx.path,
            &[],
            &[
                ("plain.txt", Entry::File("needle here\n")),
                ("secret.txt", Entry::File("needle there\n")),
            ],
            "one readable and one unreadable blob",
        );

        // Flip the store type AFTER the commit is written: the tree must be built through the
        // plain git backend, which SecretBackend wraps unchanged for writes.
        SecretBackend::adopt_git_repo(&fx.path);

        let settings = test_helpers::test_settings();

        let mut factories = default_backend_factories();
        factories.add_backend(
            SecretBackend::NAME,
            Box::new(|settings, store_path| Ok(Box::new(SecretBackend::load(settings, store_path)?))),
        );
        let workspace = Workspace::load(&settings, &fx.path, &factories, &default_working_copy_factories())
            .expect("the secret-backend workspace loads");

        let readonly = pollster::block_on(workspace.repo_loader().load_at_head()).expect("load_at_head");
        let commit_id = jj_lib::backend::CommitId::try_from_hex(&commit_hex).expect("hex commit id");
        let change = ChangeId(
            readonly
                .store()
                .get_commit(&commit_id)
                .expect("commit")
                .change_id()
                .reverse_hex(),
        );

        let mut sink = crate::warning::Warnings::default();
        let prefixes = IdPrefixContext::default();
        let search = super::file_search(&workspace, &mut sink, &prefixes, Some(&change), "needle", &[], false)
            .expect("an unreadable blob is not an error — the call SUCCEEDS");

        let paths: Vec<&str> = search.matches.iter().map(|m| m.path.as_str()).collect();
        assert_eq!(
            paths,
            vec!["plain.txt"],
            "the readable file still matches; the refused one contributes no match"
        );
        assert_eq!(search.skipped.len(), 1, "exactly one path was skipped");
        assert_eq!(search.skipped[0].path, "secret.txt");
        assert!(
            search.skipped[0]
                .reason
                .starts_with("Skipping 'secret.txt' due to permission error: "),
            "the reason is `jj file search`'s OWN sentence, not `jj file show`'s \
             (\"Path '…' exists but access is denied: …\"); got: {}",
            search.skipped[0].reason
        );
        // Story 9.32: the CLI's `ui.warning_default()` line for the same path, as a coded fact.
        let warnings = sink.take();
        assert_eq!(warnings.len(), 1, "{warnings:?}");
        assert_eq!(warnings[0].kind, crate::WarningKind::PathAccessDenied);
        assert_eq!(warnings[0].message, search.skipped[0].reason);
    }

    /// `render_entry` pairs every `SkippedPath` it makes with the warning the CLI prints for it
    /// (Story 9.32): an unreadable blob carries `jj.path_access_denied` with `jj file show`'s own
    /// sentence, while the two arms the CLI `panic!`s on (absent, directory) carry none.
    ///
    /// Inline for the reason given on the search witness above: only the `testing`-gated
    /// `SecretBackend` raises `AccessDenied`, and it cannot be reached through [`crate::Repo`].
    #[test]
    fn render_entry_pairs_each_skipped_path_with_the_clis_warning() {
        use jj_lib::backend::MergedTreeValue;
        use jj_lib::conflicts::{ConflictMarkerStyle, ConflictMaterializeOptions};
        use jj_lib::default_backend_factories::{default_backend_factories, default_working_copy_factories};
        use jj_lib::merge::Merge;
        use jj_lib::repo::Repo as _;
        use jj_lib::secret_backend::SecretBackend;
        use jj_lib::workspace::Workspace;
        use test_helpers::{add_commit_with_entries, extract_fixture, Entry};

        test_helpers::pin_test_env();
        let fx = extract_fixture("tiny-3-commits").expect("fixture extracts");
        let commit_hex = add_commit_with_entries(
            &fx.path,
            &[],
            &[("secret.txt", Entry::File("hidden\n"))],
            "one unreadable blob",
        );
        SecretBackend::adopt_git_repo(&fx.path);
        let mut factories = default_backend_factories();
        factories.add_backend(
            SecretBackend::NAME,
            Box::new(|settings, store_path| Ok(Box::new(SecretBackend::load(settings, store_path)?))),
        );
        let workspace = Workspace::load(
            &test_helpers::test_settings(),
            &fx.path,
            &factories,
            &default_working_copy_factories(),
        )
        .expect("the secret-backend workspace loads");
        let readonly = pollster::block_on(workspace.repo_loader().load_at_head()).expect("load_at_head");
        let store = readonly.store().clone();
        let commit_id = jj_lib::backend::CommitId::try_from_hex(&commit_hex).expect("hex commit id");
        let tree = store.get_commit(&commit_id).expect("commit").tree();
        let options = ConflictMaterializeOptions {
            marker_style: ConflictMarkerStyle::Diff,
            marker_len: None,
            merge: store.merge_options().clone(),
        };
        let render = |path: &str, value: MergedTreeValue| {
            let path = super::parse_path(path).expect("valid path");
            super::render_entry(&store, &path, value, tree.labels(), &options)
                .expect("renders")
                .expect_err("a skipped path")
        };

        let secret = super::parse_path("secret.txt").expect("valid path");
        let value = pollster::block_on(tree.path_value(&secret)).expect("path value");
        let (skipped, kind) = render("secret.txt", value);
        assert_eq!(kind, Some(crate::WarningKind::PathAccessDenied));
        assert!(
            skipped
                .reason
                .starts_with("Path 'secret.txt' exists but access is denied: "),
            "{}",
            skipped.reason
        );

        let (absent, kind) = render("gone.txt", Merge::absent());
        assert_eq!((absent.reason.as_str(), kind), ("Path 'gone.txt' is absent.", None));
        let dir = Merge::normal(TreeValue::Tree(store.empty_tree_id().clone()));
        let (tree_skip, kind) = render("dir", dir);
        assert_eq!((tree_skip.reason.as_str(), kind), ("Path 'dir' is a directory.", None));
    }

    /// The shared resolver's two outcomes must keep landing in the two DIFFERENT read
    /// variants: "that revision does not resolve" is the caller's problem (`ChangeNotFound`,
    /// id echoed), an index/store failure is not (`Backend`). Pinned directly, exactly as
    /// `mutate.rs` pins its own mapping, because the `Backend` arm needs a store failure
    /// mid-resolution that no fixture can provoke deterministically.
    #[test]
    fn res_preserves_the_not_found_and_backend_split() {
        let id = ChangeId("zzzzzzzz".to_owned());
        assert!(matches!(
            res(ResolveError::NotFound, Some(&id)),
            FileError::ChangeNotFound { id } if id == "zzzzzzzz"
        ));
        // `head_commit(None)` delegates to `resolve_or_wc`, which never fails with
        // `NotFound`, so the `None` id is the defensive arm: it must still produce a
        // ChangeNotFound with an EMPTY id rather than panicking.
        assert!(matches!(
            res(ResolveError::NotFound, None),
            FileError::ChangeNotFound { id } if id.is_empty()
        ));
        assert!(matches!(
            res(ResolveError::Backend("index read failed".to_owned()), Some(&id)),
            FileError::Backend(reason) if reason == "index read failed"
        ));
        assert!(matches!(
            res(
                ResolveError::Resolution {
                    reason: "ambiguous".to_owned(),
                    hints: vec!["h".to_owned()],
                },
                Some(&id)
            ),
            FileError::RevsetResolutionError { reason, hints } if reason == "ambiguous" && hints == ["h"]
        ));
        assert!(matches!(
            res(ResolveError::NoWorkingCopy("no @".to_owned()), None),
            FileError::RevsetResolutionError { reason, hints } if reason == "no @" && hints.is_empty()
        ));
    }

    fn file(executable: bool) -> TreeValue {
        TreeValue::File {
            id: FileId::new(vec![1]),
            executable,
            copy_id: CopyId::placeholder(),
        }
    }

    /// The five kinds the CLI's `describe_file_type` distinguishes, plus its `""` (absent)
    /// case — which this API drops rather than modelling, since neither `entries_matching`
    /// nor the guarded `path_value` branch can yield it.
    #[test]
    fn file_type_of_maps_every_tree_value_kind() {
        assert_eq!(file_type_of(&Merge::normal(file(false))), Some(FileType::File));
        assert_eq!(
            file_type_of(&Merge::normal(TreeValue::Symlink(SymlinkId::new(vec![2])))),
            Some(FileType::Symlink)
        );
        assert_eq!(
            file_type_of(&Merge::normal(TreeValue::Tree(TreeId::new(vec![3])))),
            Some(FileType::Tree)
        );
        assert_eq!(
            file_type_of(&Merge::normal(TreeValue::GitSubmodule(jj_lib::backend::CommitId::new(
                vec![4]
            )))),
            Some(FileType::GitSubmodule)
        );
        assert_eq!(file_type_of(&Merge::absent()), None, "absent is dropped, not modelled");

        let conflict = Merge::from_vec(vec![Some(file(false)), None, Some(file(true))]);
        assert_eq!(file_type_of(&conflict), Some(FileType::Conflict));
        assert_eq!(conflict.simplify().num_sides(), 2, "a 3-term merge has 2 sides");
    }

    #[test]
    fn is_executable_follows_the_cli_unwrap_or_default_rule() {
        assert!(is_executable(&Merge::normal(file(true))));
        assert!(!is_executable(&Merge::normal(file(false))));
        assert!(
            !is_executable(&Merge::normal(TreeValue::Symlink(SymlinkId::new(vec![2])))),
            "a non-file has no executable bit, and the CLI defaults it to false"
        );
    }

    #[test]
    fn parse_pattern_splits_kind_on_the_first_colon() {
        assert!(parse_pattern("substring:needle").is_ok());
        // A bare pattern is a regex, so an unbalanced paren is a parse failure.
        let err = parse_pattern("(").expect_err("an unbalanced paren is not a valid regex");
        assert!(
            matches!(&err, FileError::InvalidInput { reason } if !reason.is_empty()),
            "unexpected error: {err:?}"
        );
        let err = parse_pattern("nosuchkind:x").expect_err("an unknown kind is refused");
        assert!(
            matches!(&err, FileError::InvalidInput { reason } if reason.contains("nosuchkind")),
            "unexpected error: {err:?}"
        );
    }

    #[test]
    fn parse_path_refuses_a_malformed_repo_path() {
        let err = parse_path("/absolute.txt").expect_err("a leading slash is not a repo path");
        assert!(
            matches!(&err, FileError::InvalidInput { reason } if reason.contains("invalid path")),
            "unexpected error: {err:?}"
        );
    }

    #[test]
    fn collect_matches_reports_one_based_lines_and_keeps_the_newline() {
        let matcher = parse_pattern("substring:needle").expect("valid pattern").to_matcher();
        let content = b"first\nneedle here\nthird\nneedle again";

        let mut out = Vec::new();
        assert!(collect_matches("a.txt", content, &matcher, None, false, &mut out));
        assert_eq!(out.len(), 2);
        assert_eq!(out[0].line_number, 2, "line numbers are 1-based");
        assert_eq!(out[0].content, b"needle here\n".to_vec(), "the newline is kept");
        assert_eq!(out[1].line_number, 4);
        assert_eq!(
            out[1].content,
            b"needle again".to_vec(),
            "a final line without a newline is reported as-is"
        );
        assert!(out.iter().all(|m| m.conflict_side.is_none()));

        // name_only stops the file's scan at the first match.
        let mut one = Vec::new();
        assert!(collect_matches("a.txt", content, &matcher, Some(1), true, &mut one));
        assert_eq!(one.len(), 1, "name_only stops at the first match");
        assert_eq!(one[0].conflict_side, Some(1));

        let mut none = Vec::new();
        assert!(!collect_matches(
            "a.txt",
            b"nothing here",
            &matcher,
            None,
            false,
            &mut none
        ));
        assert!(none.is_empty());
    }
}
