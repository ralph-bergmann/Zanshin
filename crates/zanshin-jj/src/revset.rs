// SPDX-License-Identifier: MIT

use std::collections::{HashMap, HashSet};

use futures::TryStreamExt as _;
use jj_lib::fileset::FilesetAliasesMap;
use jj_lib::repo_path::RepoPathUiConverter;
use jj_lib::revset::{
    self, RevsetAliasesMap, RevsetDiagnostics, RevsetExtensions, RevsetParseContext, RevsetWorkspaceContext,
    SymbolResolver,
};

use crate::{ChangeId, Repo};

/// Errors returned by [`resolve_revset`].
#[derive(Debug, thiserror::Error)]
pub enum RevsetError {
    /// The expression is syntactically invalid or names an unknown function.
    #[error("invalid revset: {reason}")]
    ParseError {
        /// Human-readable parse failure from jj-lib.
        reason: String,
    },
    /// The expression is well-formed but a symbol could not be resolved
    /// (unknown bookmark/tag, missing working copy, ambiguous/divergent id).
    #[error("cannot resolve revset: {reason}")]
    ResolutionError {
        /// Human-readable resolution failure from jj-lib.
        reason: String,
    },
    /// An underlying jj-lib failure (evaluation/backend), opaque-string-wrapped
    /// so no `jj_lib` type escapes the public API (FR-JJ-16).
    #[error("jj-lib error: {0}")]
    JjLibError(String),
}

/// Resolve a jj revset expression to a deduplicated, fully materialized list of change ids.
///
/// Uses jj-lib's revset parser/evaluator — the input is never string-manipulated.
/// Resolves committed view state at head; it does not snapshot the working copy,
/// so `@` reflects the last committed working-copy commit, not un-snapshotted edits.
///
/// # Errors
///
/// - [`RevsetError::ParseError`] — syntactically invalid expression or unknown function
///   (e.g. `bogus_function()`).
/// - [`RevsetError::ResolutionError`] — a symbol cannot be resolved: unknown bookmark/tag
///   (`nonexistent-branch`), no working-copy commit for `@`, or an unmatched/ambiguous id.
/// - [`RevsetError::JjLibError`] — an internal jj-lib evaluation or backend failure.
#[must_use = "the resolved change ids are the result of this call"]
pub fn resolve_revset(repo: &Repo, expr: &str) -> Result<Vec<ChangeId>, RevsetError> {
    // 1. Reload to head (ADR-0002; sync via pollster — mirrors status.rs:85).
    let readonly = pollster::block_on(repo.workspace().repo_loader().load_at_head())
        .map_err(|e| RevsetError::JjLibError(e.to_string()))?;
    let repo_dyn: &dyn jj_lib::repo::Repo = readonly.as_ref();
    let workspace = repo.workspace();

    // 2. Parse context — every borrowed local is declared before `context` so it outlives it.
    let aliases_map = build_aliases_map()?;
    let fileset_aliases = FilesetAliasesMap::new();
    let extensions = RevsetExtensions::default();
    let user_email: &str = repo.settings().user_email();
    let date_ctx: jj_lib::time_util::DatePatternContext = chrono::Local::now().into();
    let path_converter = RepoPathUiConverter::Fs {
        cwd: workspace.workspace_root().to_owned(),
        base: workspace.workspace_root().to_owned(),
    };
    let workspace_ctx = RevsetWorkspaceContext {
        path_converter: &path_converter,
        workspace_name: workspace.workspace_name(),
    };
    let context = RevsetParseContext {
        aliases_map: &aliases_map,
        local_variables: HashMap::new(),
        user_email,
        date_pattern_context: date_ctx,
        default_ignored_remote: Some("git".as_ref()),
        fileset_aliases_map: &fileset_aliases,
        use_glob_by_default: false,
        extensions: &extensions,
        workspace: Some(workspace_ctx),
    };

    // 3. Parse → resolve → evaluate.
    let mut diagnostics = RevsetDiagnostics::new();
    let parsed = revset::parse(&mut diagnostics, expr, &context)
        .map_err(|e| RevsetError::ParseError { reason: e.to_string() })?;
    let symbol_resolver = SymbolResolver::new(repo_dyn, extensions.symbol_resolvers());
    let resolved = parsed
        .resolve_user_expression(repo_dyn, &symbol_resolver)
        .map_err(|e| RevsetError::ResolutionError { reason: e.to_string() })?;
    let set = resolved
        .evaluate(repo_dyn)
        .map_err(|e| RevsetError::JjLibError(e.to_string()))?;

    // 4. Collect the change-id stream (0.42: `commit_change_ids` returns a Stream — drive it
    //    synchronously via pollster, mirroring the `load_at_head` call above), then
    //    reverse-hex → dedup (preserve first-seen topological order) → materialize.
    let pairs: Vec<_> = pollster::block_on(set.commit_change_ids().try_collect())
        .map_err(|e| RevsetError::JjLibError(e.to_string()))?;
    let mut out: Vec<ChangeId> = Vec::new();
    let mut seen: HashSet<String> = HashSet::new();
    for (_commit_id, change_id) in pairs {
        let rev_hex = change_id.reverse_hex();
        if seen.insert(rev_hex.clone()) {
            out.push(ChangeId(rev_hex));
        }
    }
    Ok(out)
}

/// Builds a `RevsetAliasesMap` seeded with jj's default `trunk()` alias.
///
/// # WHY: jj-lib ships no built-in `trunk()` function — it is a default alias
/// defined by the jj CLI binary. Without this map, `parse("trunk()..@")` returns
/// `NoSuchFunction`. The fallback to `root()` makes `trunk()..@` resolve cleanly
/// on fixtures that have no remote bookmarks named main/master/trunk (Decision D2).
fn build_aliases_map() -> Result<RevsetAliasesMap, RevsetError> {
    let mut map = RevsetAliasesMap::new();
    // The canonical default trunk() alias (jj 0.41-compatible syntax).
    // Uses remote_bookmarks(<name>) single-arg form (confirmed valid in jj-lib 0.41.0).
    // Falls back to root() when no matching remote bookmark exists.
    let trunk_def = "latest(\
        remote_bookmarks(exact:\"main\") | \
        remote_bookmarks(exact:\"master\") | \
        remote_bookmarks(exact:\"trunk\") | \
        root()\
    )";
    map.insert("trunk()", trunk_def, None)
        .map_err(|e| RevsetError::ParseError { reason: e.to_string() })?;
    Ok(map)
}
