// SPDX-License-Identifier: MIT

use std::collections::{HashMap, HashSet};
use std::ops::ControlFlow;
use std::path::Path;
use std::sync::Arc;

use futures::{StreamExt as _, TryStreamExt as _};
use jj_lib::config::StackedConfig;
use jj_lib::fileset::FilesetAliasesMap;
use jj_lib::repo::Repo as _;
use jj_lib::repo_path::RepoPathUiConverter;
use jj_lib::revset::{
    self, ResolvedRevsetExpression, Revset, RevsetAliasesMap, RevsetDiagnostics, RevsetExpression, RevsetExtensions,
    RevsetParseContext, RevsetStreamExt as _, RevsetWorkspaceContext, SymbolResolver, UserRevsetExpression,
};

use crate::change::change_from_commit;
use crate::config::ConfigError;
use crate::{Change, ChangeId, Repo};

/// The jj CLI's default `revsets.log` (`cli/src/config/revsets.toml` at v0.42.0) — the
/// revset `jj log` shows without `-r`, and the CLI's fallback for
/// `revsets.short-prefixes`.
///
/// A pre-fill for the caller's `revset` / `short_prefixes` parameters; nothing in this
/// crate applies it silently (FR-JJ-17). It parses only because the builtin config layer
/// defines the CLI's `[revset-aliases]`. The repo's own effective value — which a user's
/// config may override — is [`Repo::log_defaults`].
pub const DEFAULT_LOG_REVSET: &str = "present(@) | ancestors(immutable_heads().., 2) | trunk()";

/// Errors returned by [`resolve_revset`], [`Repo::eval_revset`] and [`Repo::walk_graph`].
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
    /// The repo's effective jj config could not be read (Story 4.9) — a malformed file, a
    /// bad `config-id`, or a wrong-typed value. Never a silent fall-back to the builtins.
    #[error(transparent)]
    Config(#[from] ConfigError),
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
/// - [`RevsetError::Config`] — the repo's effective jj config is malformed or unreadable,
///   or a layer's `revset-aliases` is not a table. A single bad alias ENTRY is not an
///   error: like the CLI, it warns and is skipped.
/// - [`RevsetError::JjLibError`] — an internal jj-lib evaluation or backend failure.
#[must_use = "the resolved change ids are the result of this call"]
pub fn resolve_revset(repo: &Repo, expr: &str) -> Result<Vec<ChangeId>, RevsetError> {
    // 1. Reload to head (ADR-0002; sync via pollster — mirrors status.rs:85).
    let readonly = pollster::block_on(repo.workspace().repo_loader().load_at_head())
        .map_err(|e| RevsetError::JjLibError(e.to_string()))?;
    let repo_dyn: &dyn jj_lib::repo::Repo = readonly.as_ref();

    // 2. Parse → resolve → evaluate (shared with the graph walk in `graph.rs`).
    let parsed = parse_revset(repo, expr)?;
    let set = evaluate_revset(repo_dyn, &parsed)?;

    // 3. Collect the change-id stream (0.42: `commit_change_ids` returns a Stream — drive it
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

/// Streams the commits `revset` denotes through `visit`, one [`Change`] at a time.
///
/// The generic read primitive of ADR-0003 §5: the commit stream is driven item by item and is
/// never collected, so a caller that stops early pays only for what it consumed. `visit`
/// returning [`ControlFlow::Break`] stops the walk and yields `Ok(Break)`; an exhausted stream
/// yields `Ok(Continue)`.
///
/// The five phases mirror [`crate::graph::walk_graph`]: load the effective config once, build
/// the alias map, parse (no loaded operation needed, so a syntax error costs no `load_at_head`
/// I/O), reload to head (ADR-0002), evaluate, then drive `Revset::stream()` through
/// jj-lib's own `RevsetStreamExt::commits` — the same hydration the CLI's `jj log` uses
/// (`cli/src/commands/log.rs` @ v0.44.0).
///
/// # Errors
///
/// - [`RevsetError::ParseError`] — `revset` is syntactically invalid or names an unknown
///   function; raised before any repo I/O.
/// - [`RevsetError::ResolutionError`] — a symbol cannot be resolved (unknown bookmark/tag,
///   no working-copy commit for `@`, unmatched/ambiguous id).
/// - [`RevsetError::Config`] — the repo's effective jj config is malformed or unreadable. A
///   single bad `[revset-aliases]` entry is NOT an error: like the CLI, it warns and is skipped.
/// - [`RevsetError::JjLibError`] — `load_at_head`, evaluation, or a per-item stream/store
///   failure. Changes already handed to `visit` before an `Err` are not retracted — discard
///   partial output on `Err`.
pub(crate) fn eval_revset(
    repo: &Repo,
    revset: &str,
    mut visit: impl FnMut(Change) -> ControlFlow<()>,
) -> Result<ControlFlow<()>, RevsetError> {
    // 1. Effective config ONCE per walk (never cached — Story 4.9), then parse against the
    //    alias map it feeds. Parsing needs no loaded operation.
    let config = crate::config::load(repo)?;
    let aliases = build_aliases_map(&config)?;
    let parsed = parse_revset_with(repo, &aliases, revset)?;

    // 2. Reload to head (ADR-0002; sync via pollster — mirrors `resolve_revset` above).
    let readonly = pollster::block_on(repo.workspace().repo_loader().load_at_head())
        .map_err(|e| RevsetError::JjLibError(e.to_string()))?;
    let repo_dyn: &dyn jj_lib::repo::Repo = readonly.as_ref();
    let store = readonly.store();
    let view = readonly.view();

    // 3. Evaluate to a lazy revset borrowing `readonly`. The stream is never returned — items
    //    leave through `visit` — which is what keeps that borrow local.
    let set = evaluate_revset(repo_dyn, &parsed)?;

    // 4. Drive the lazy stream into the visitor; stop at the first `Break`. The order is the
    //    RAW revset order (topological, children before parents) — `jj log`'s printed order is
    //    `walk_graph`'s job, not this primitive's.
    pollster::block_on(async {
        let mut stream = std::pin::pin!(set.stream().commits(store));
        while let Some(item) = stream.next().await {
            let commit = item.map_err(|e| RevsetError::JjLibError(e.to_string()))?;
            let change = change_from_commit(repo_dyn, store, view, &commit).map_err(RevsetError::JjLibError)?;
            if visit(change).is_break() {
                return Ok(ControlFlow::Break(()));
            }
        }
        Ok(ControlFlow::Continue(()))
    })
}

/// Parses `expr` in this workspace's revset context, building a fresh alias map from the
/// repo's effective jj config.
///
/// Convenience wrapper over [`parse_revset_with`] for call sites that parse a single
/// expression; a call site parsing several (the graph walk) loads the config and builds the
/// map once, then calls [`parse_revset_with`] directly.
///
/// # Errors
///
/// - [`RevsetError::ParseError`] — syntactically invalid expression or unknown function.
/// - [`RevsetError::Config`] — the repo's jj config is malformed or unreadable.
pub(crate) fn parse_revset(repo: &Repo, expr: &str) -> Result<Arc<UserRevsetExpression>, RevsetError> {
    let config = crate::config::load(repo)?;
    let aliases_map = build_aliases_map(&config)?;
    parse_revset_with(repo, &aliases_map, expr)
}

/// Parses `expr` in this workspace's revset context (`aliases_map`'s aliases, the
/// workspace name for `@`, the user email, a `git`-default ignored remote). Pure parsing —
/// no symbol is resolved yet, so the result is independent of any loaded operation.
///
/// # Errors
///
/// - [`RevsetError::ParseError`] — syntactically invalid expression or unknown function.
pub(crate) fn parse_revset_with(
    repo: &Repo,
    aliases_map: &RevsetAliasesMap,
    expr: &str,
) -> Result<Arc<UserRevsetExpression>, RevsetError> {
    let workspace = repo.workspace();

    // Parse context — every borrowed local is declared before `context` so it outlives it.
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
    // WHY: three USER-VISIBLE revset-language changes arrived with the jj-lib 0.42 → 0.44 bump
    // (Story 9.0a). None is a no-op; all reach users through `resolve_revset` and through
    // `walk_graph` / the FFI `graphSlice(revset:)` pass-through, where the revset is user-typed.
    //
    // 1. `RevsetParseContext::use_glob_by_default` is GONE — this struct literal used to set it
    //    to `false`. In 0.42 that made the default kind for a bare/quoted pattern argument
    //    "substring"; 0.44 always parses it as a glob (and `StringPattern::glob` degrades to
    //    `exact` when the string holds no glob metacharacter). So `description(fix)` used to
    //    match any description CONTAINING "fix" and now matches only one EQUAL to "fix" — same
    //    for `subject`/`author`/`committer`/`bookmarks`/`remote_bookmarks`/`tags`/`files`/
    //    `diff_contains`. Explicit kinds (`substring:"fix"`, `glob:`, `regex:`, `exact:`) are
    //    unaffected. This is a PARITY IMPROVEMENT, not a regression: jj's own CLI shipped
    //    `ui.revsets-use-glob-by-default = true` in `cli/src/config/misc.toml` at v0.42.0, so
    //    our hardcoded `false` had been diverging from the CLI that NFR-R-2 makes the semantic
    //    reference; 0.44 deleted the knob, leaving glob as the only — and CLI-correct — behavior.
    //    Pinned by `revset_bare_pattern_arg_is_exact_not_substring` in tests/revset.rs.
    //
    // 2. Git-like symbols (e.g. `refs/heads/main`) are NO LONGER resolved to revisions; the
    //    bookmark/tag `<name>` or `<name>@<remote>` syntax replaces them. A revset that relied
    //    on the old form now fails to resolve rather than silently changing meaning.
    //
    // 3. The `git_head()` and `git_refs()` FUNCTIONS are gone from jj-lib's revset table
    //    (present at `jj-lib-0.42.0/src/revset.rs:982,991`, absent in 0.44). A revset using
    //    them is now a parse error. The underlying `View::git_head()` / `View::git_refs()` are
    //    unchanged, so the property those functions exposed is still assertable one level down —
    //    which is how `tests/convert.rs` and `tests/op_log.rs` were re-anchored in this story.
    //
    // Changes 2 and 3 are LOUD (the revset fails to parse or resolve, so the user is told);
    // change 1 is SILENT — same input, different valid answer — which is why only it carries a
    // regression test.
    let context = RevsetParseContext {
        aliases_map,
        local_variables: HashMap::new(),
        user_email,
        date_pattern_context: date_ctx,
        default_ignored_remote: Some("git".as_ref()),
        fileset_aliases_map: &fileset_aliases,
        extensions: &extensions,
        workspace: Some(workspace_ctx),
    };

    let mut diagnostics = RevsetDiagnostics::new();
    revset::parse(&mut diagnostics, expr, &context).map_err(|e| RevsetError::ParseError { reason: e.to_string() })
}

/// Resolves the symbols of a parsed expression against `repo_dyn` without evaluating it.
///
/// `repo_dyn` is usually a head-resolved `ReadonlyRepo` (ADR-0002), but any
/// `jj_lib::repo::Repo` works — including the `MutableRepo` a transaction hands out, which
/// is how [`crate::op_support`] resolves the immutable set mid-mutation.
///
/// The resolved expression is what jj-lib's own rewrite plumbing consumes
/// (`MutableRepo::rebase_descendants_with_options` takes a `ResolvedRevsetExpression`), so
/// callers that need the expression itself — not the commits it denotes — stop here instead
/// of going through [`evaluate_revset`].
///
/// # Errors
///
/// - [`RevsetError::ResolutionError`] — a symbol cannot be resolved (unknown bookmark/tag,
///   no working-copy commit for `@`, unmatched/ambiguous id).
pub(crate) fn resolve_expression(
    repo_dyn: &dyn jj_lib::repo::Repo,
    expr: &Arc<UserRevsetExpression>,
) -> Result<Arc<ResolvedRevsetExpression>, RevsetError> {
    let extensions = RevsetExtensions::default();
    let symbol_resolver = SymbolResolver::new(repo_dyn, extensions.symbol_resolvers());
    expr.resolve_user_expression(repo_dyn, &symbol_resolver)
        .map_err(|e| RevsetError::ResolutionError { reason: e.to_string() })
}

/// Resolves the symbols of a parsed expression against `repo_dyn` (a head-resolved
/// `ReadonlyRepo`, ADR-0002) and evaluates it to a lazy revset borrowing that repo.
///
/// # Errors
///
/// - [`RevsetError::ResolutionError`] — a symbol cannot be resolved (unknown bookmark/tag,
///   no working-copy commit for `@`, unmatched/ambiguous id).
/// - [`RevsetError::JjLibError`] — an internal jj-lib evaluation failure.
pub(crate) fn evaluate_revset<'r>(
    repo_dyn: &'r dyn jj_lib::repo::Repo,
    expr: &Arc<UserRevsetExpression>,
) -> Result<Box<dyn Revset + 'r>, RevsetError> {
    resolve_expression(repo_dyn, expr)?
        .evaluate(repo_dyn)
        .map_err(|e| RevsetError::JjLibError(e.to_string()))
}

/// Builds the `RevsetAliasesMap` from every `[revset-aliases]` table in `config`, lowest
/// layer first — Zanshin's builtin defaults, then the user, repo and workspace layers.
///
/// Mirrors the CLI's `load_aliases_map` (`cli/src/config.rs:930-981`): insertion is keyed
/// by (name, arity), so a user's `trunk()` REPLACES the builtin while a user's `trunk(x)`
/// merely adds an overload. A value may be a plain string or a table with a `definition`
/// string key.
///
/// The CLI's two failure levels are mirrored exactly, and they differ:
///
/// - **The TABLE level is a hard error.** A layer whose `revset-aliases` is not a table at
///   all aborts the load (`cli/src/config.rs:943-953` returns `ConfigGetError::Type`).
///   Skipping it would silently fall back to the builtin aliases — the one behaviour this
///   story exists to prevent.
/// - **The ENTRY level warns and continues** (`cli/src/config.rs:964-977`): a non-string
///   value or a declaration jj-lib's parser rejects is logged and skipped, and every other
///   alias still loads. One messy entry must not take down the whole table.
///
/// jj-lib does not check the DEFINITION (`dsl_util.rs:594-597`), so a malformed `defn`
/// surfaces later still, when the alias is substituted.
///
/// # Errors
///
/// - [`ConfigError::Load`] — a config layer's `revset-aliases` key is not a table.
pub(crate) fn build_aliases_map(config: &StackedConfig) -> Result<RevsetAliasesMap, ConfigError> {
    let mut map = RevsetAliasesMap::new();
    for layer in config.layers() {
        let table = match layer.look_up_table("revset-aliases") {
            Ok(Some(table)) => table,
            Ok(None) => continue,
            Err(item) => {
                let path = layer.path.as_deref().unwrap_or(Path::new("<builtin>"));
                return Err(ConfigError::Load {
                    reason: format!(
                        "{}: revset-aliases: Expected a table, but is {}",
                        path.display(),
                        item.type_name()
                    ),
                });
            }
        };
        for (decl, item) in table.iter() {
            let (definition, doc) = match item.as_table_like() {
                Some(t) => (
                    t.get("definition").and_then(jj_lib::config::ConfigItem::as_str),
                    t.get("doc")
                        .and_then(jj_lib::config::ConfigItem::as_str)
                        .map(ToOwned::to_owned),
                ),
                None => (item.as_str(), None),
            };
            let Some(definition) = definition else {
                let found = item.type_name();
                tracing::warn!(
                    alias = decl,
                    found,
                    "revset alias is neither a string nor a table with a `definition` string key; skipped"
                );
                continue;
            };
            if let Err(e) = map.insert(decl, definition, doc) {
                tracing::warn!(alias = decl, error = %e, "failed to load revset alias; skipped");
            }
        }
    }
    Ok(map)
}

/// Builds the CLI's immutable-set expression, `::(immutable_heads() | root())`.
///
/// Mirrors the CLI's *in-code* construction (`cli/src/revset_util.rs:193-203` +
/// `cli/src/cli_util.rs:956-961`: parse the `immutable_heads()` definition, union
/// `root()`, then `ancestors()`) rather than the `immutable()` alias, which exists only
/// for user-written revsets. Both denote the same set, but mirroring the in-code form is
/// what lets Story 4.9's config override of `immutable_heads()` flow through unchanged.
///
/// # Errors
///
/// - [`RevsetError::ParseError`] — the `immutable_heads()` alias does not parse.
pub(crate) fn immutable_expression(
    repo: &Repo,
    aliases_map: &RevsetAliasesMap,
) -> Result<Arc<UserRevsetExpression>, RevsetError> {
    let heads = parse_revset_with(repo, aliases_map, "immutable_heads()")?;
    Ok(heads.union(&RevsetExpression::root()).ancestors())
}
