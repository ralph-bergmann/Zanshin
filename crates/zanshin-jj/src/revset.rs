// SPDX-License-Identifier: MIT

use std::collections::HashSet;
use std::ops::ControlFlow;
use std::path::Path;
use std::sync::Arc;

use futures::{StreamExt as _, TryStreamExt as _};
use jj_lib::backend::CommitId as JjCommitId;
use jj_lib::config::{ConfigSource, StackedConfig};
use jj_lib::dsl_util::{AliasDeclarationParser, AliasesMap};
use jj_lib::fileset::{FilePatternParseError, FilesetAliasesMap, FilesetParseError};
use jj_lib::id_prefix::IdPrefixContext;
use jj_lib::ref_name::WorkspaceName;
use jj_lib::repo::Repo as _;
use jj_lib::repo_path::RepoPathBuf;
use jj_lib::revset::{
    self, ResolvedRevset, ResolvedRevsetExpression, Revset, RevsetAliasesMap, RevsetDiagnostics, RevsetExpression,
    RevsetExtensions, RevsetParseContext, RevsetParseError, RevsetParseErrorKind, RevsetResolutionError,
    RevsetStreamExt as _, RevsetWorkspaceContext, SymbolResolver, UserRevsetExpression,
};
use jj_lib::str_util::StringPatternParseError;
use jj_lib::ui_path::{RepoPathUiConverter, UiPathParseError};
use jj_lib::workspace::Workspace;

use crate::change::change_from_commit;
use crate::config::ConfigError;
use crate::warning::{self, Load, Warning, WarningKind, Warnings};
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
    /// The pre-verb snapshot failed (Story 9.26), so the read never ran — see
    /// [`crate::PreconditionError`].
    #[error(transparent)]
    Precondition(#[from] crate::PreconditionError),
    /// The expression is syntactically invalid or names an unknown function.
    #[error("invalid revset: {reason}")]
    ParseError {
        /// Human-readable parse failure from jj-lib.
        reason: String,
        /// The structured failure (Story 9.25): kind, span into the caller's text, the named
        /// symbol, its similar names and the CLI's hint lines.
        detail: Box<RevsetErrorDetail>,
    },
    /// The expression is well-formed but a symbol could not be resolved
    /// (unknown bookmark/tag, missing working copy, ambiguous/divergent id).
    #[error("cannot resolve revset: {reason}")]
    ResolutionError {
        /// Human-readable resolution failure from jj-lib.
        reason: String,
        /// The structured failure (Story 9.25); a resolution error has no span.
        detail: Box<RevsetErrorDetail>,
    },
    /// An underlying jj-lib failure (evaluation/backend), opaque-string-wrapped
    /// so no `jj_lib` type escapes the public API (FR-JJ-16).
    #[error("jj-lib error: {0}")]
    JjLibError(String),
    /// The repo's effective jj config could not be read (Story 4.9) — a malformed file, a
    /// bad `config-id`, or a wrong-typed value. Never a silent fall-back to the builtins.
    #[error(transparent)]
    Config(#[from] ConfigError),
    /// A Direct/Indirect edge of [`crate::Repo::graph_topology`] names a target that is not a
    /// node of the walked graph (Story 4.10) — a violation of jj-lib's stream contract (a
    /// target always arrives later in the stream), so unreachable through jj-lib itself.
    #[error("dangling edge: target {target} is not a node of the graph")]
    DanglingEdge {
        /// Hex commit id of the edge's target.
        target: String,
    },
}

impl RevsetError {
    /// The CLI's hint lines for a parse or resolution error (`revset_parse_error_hint` /
    /// `revset_resolution_error_hints`, `cli/src/command_error.rs:892-977` @ v0.46.0), in the
    /// CLI's order; empty for every other variant.
    #[must_use]
    pub fn hints(&self) -> Vec<String> {
        match self {
            Self::ParseError { detail, .. } | Self::ResolutionError { detail, .. } => detail.hints.clone(),
            _ => Vec::new(),
        }
    }

    /// This error with its parse span dropped — for a failing text that is not the call's primary
    /// expression, whose span a UI would otherwise underline in the wrong text.
    pub(crate) fn without_span(mut self) -> Self {
        if let Self::ParseError { detail, .. } = &mut self {
            detail.span = None;
        }
        self
    }
}

/// Which jj-lib revset failure a [`RevsetErrorDetail`] describes (Story 9.25) — jj-lib's
/// `RevsetParseErrorKind` variants, then its `RevsetResolutionError` variants, one to one.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RevsetErrorKind {
    /// A syntax error.
    SyntaxError,
    /// An operator used as a prefix operator that is none (`:x`).
    NotPrefixOperator,
    /// An operator used as a postfix operator that is none (`x^`).
    NotPostfixOperator,
    /// An operator used as an infix operator that is none.
    NotInfixOperator,
    /// An unknown function; `symbol` is its name, `candidates` jj-lib's similar names.
    NoSuchFunction,
    /// A function called with invalid arguments; `symbol` is its name.
    InvalidFunctionArguments,
    /// A file pattern without a workspace.
    FsPathWithoutWorkspace,
    /// `@` without a workspace.
    WorkingCopyWithoutWorkspace,
    /// A function parameter defined twice.
    RedefinedFunctionParameter,
    /// Some other expression error (an invalid string or date pattern, …).
    Expression,
    /// A failure inside an alias's expansion; `symbol` is the alias.
    InAliasExpansion,
    /// A failure inside a function parameter's expansion; `symbol` is the parameter.
    InParameterExpansion,
    /// An alias that expands into itself; `symbol` is the alias.
    RecursiveAlias,
    /// An unknown revision; `symbol` is the name, `candidates` jj-lib's similar names.
    NoSuchRevision,
    /// A workspace without a working-copy commit; `symbol` is the workspace.
    WorkspaceMissingWorkingCopy,
    /// An empty string as a revision.
    EmptyString,
    /// An ambiguous commit id prefix; `symbol` is the prefix.
    AmbiguousCommitIdPrefix,
    /// An ambiguous change id prefix; `symbol` is the prefix.
    AmbiguousChangeIdPrefix,
    /// A divergent change id; `symbol` is the id.
    DivergentChangeId,
    /// A conflicted bookmark or tag; `symbol` is its name.
    ConflictedRef,
    /// A commit-backend failure during resolution.
    Backend,
    /// Any other resolution failure.
    Other,
}

impl RevsetErrorDetail {
    /// A detail of `kind` with no span, symbol, candidates or hints — for tests that build a
    /// [`RevsetError`] by hand.
    #[cfg(test)]
    pub(crate) fn bare(kind: RevsetErrorKind) -> Self {
        Self {
            kind,
            span: None,
            symbol: None,
            candidates: Vec::new(),
            hints: Vec::new(),
        }
    }
}

/// Where a parse error points in the caller's expression (Story 9.25), in BYTES.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RevsetSpan {
    /// Byte offset of the span's start.
    pub offset: u32,
    /// Byte length; `0` for a position, `None` when it is unknown: the span crosses lines, or
    /// pest's render cannot tell an empty span from a one-char one.
    pub length: Option<u32>,
}

/// The structured form of a revset parse or resolution error (Story 9.25) — what the UI needs to
/// point at the failing part of an expression without parsing the message.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RevsetErrorDetail {
    /// The top-level error's kind (inside an alias: the alias expansion).
    pub kind: RevsetErrorKind,
    /// The top-level error's span in the call's primary expression (the topology's `revset`, a
    /// search's `expression`); `None` for a resolution error and for an error in any other text
    /// of the call (`prioritize`, `short_prefixes`, an anchor).
    pub span: Option<RevsetSpan>,
    /// The function, revision, alias, operator or prefix the error names, if any.
    pub symbol: Option<String>,
    /// jj-lib's similar names (or the suggested operator); empty when it has none.
    pub candidates: Vec<String>,
    /// The CLI's hint lines for the error, verbatim and in the CLI's order.
    pub hints: Vec<String>,
}

/// Resolve a jj revset expression to a deduplicated, fully materialized list of change ids.
///
/// Uses jj-lib's revset parser/evaluator — the input is never string-manipulated.
/// Resolves committed view state at head; it does not snapshot the working copy,
/// so `@` reflects the last committed working-copy commit, not un-snapshotted edits.
/// That is deliberate (Story 9.26): this `&Repo` resolver is exported to neither FFI nor
/// MCP and serves as the test oracle over the current head. The CLI-counterpart surface
/// is [`crate::Repo::eval_revset`], which runs the pre-verb snapshot first.
///
/// Warnings (Story 9.32) are NOT returned: this oracle has no warning channel, so its
/// alias-load warnings (`jj.config_alias_invalid` / `jj.config_alias_redefined`) and revset
/// parse diagnostics (`jj.revset_diagnostic`) are only logged (`tracing::warn!`) and dropped.
/// [`crate::Repo::eval_revset`] reports them.
///
/// Short id prefixes resolve within the effective `revsets.short-prefixes` set first, as the CLI's.
///
/// # Errors
///
/// - [`RevsetError::ParseError`] — syntactically invalid expression or unknown function
///   (e.g. `bogus_function()`).
/// - [`RevsetError::ResolutionError`] — a symbol cannot be resolved: unknown bookmark/tag
///   (`nonexistent-branch`), no working-copy commit for `@`, or an unmatched/ambiguous id.
/// - [`RevsetError::Config`] — the repo's effective jj config is malformed or unreadable,
///   or a layer's `revset-aliases` is not a table. A single bad alias ENTRY is not an
///   error: like the CLI, it warns (see above) and is skipped. Also an effective
///   `revsets.short-prefixes` that is not a string or does not parse.
/// - [`RevsetError::JjLibError`] — an internal jj-lib evaluation or backend failure.
#[must_use = "the resolved change ids are the result of this call"]
pub fn resolve_revset(repo: &Repo, expr: &str) -> Result<Vec<ChangeId>, RevsetError> {
    // 1. Reload to head (ADR-0002; sync via pollster — mirrors status.rs:85).
    let readonly = crate::snapshot::reload_head(repo.workspace()).map_err(RevsetError::JjLibError)?;
    let repo_dyn: &dyn jj_lib::repo::Repo = readonly.as_ref();

    // 2. Parse → resolve → evaluate (shared with the graph walk in `graph.rs`), symbols through
    //    the effective `revsets.short-prefixes` id-prefix context as the CLI's. This oracle has
    //    no warning channel, so its parse warnings are logged and dropped.
    let mut sink = Warnings::default();
    let parsed = parse_with_prefixes(repo, expr, &mut sink);
    crate::warning::log_dropped("resolve_revset", sink.take());
    let (parsed, prefixes) = parsed?;
    let set = evaluate_revset(repo_dyn, &parsed, Some(&prefixes))?;

    // 3. Collect the change-id stream (0.42: `commit_change_ids` returns a Stream — drive it
    //    synchronously via pollster, mirroring the head load above), then
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

/// [`resolve_revset`]'s parse: the effective config loaded once, `revsets.short-prefixes` parsed
/// into the id-prefix context first (the CLI's start-up order), then `expr`.
fn parse_with_prefixes(
    repo: &Repo,
    expr: &str,
    sink: &mut Warnings,
) -> Result<(Arc<UserRevsetExpression>, IdPrefixContext), RevsetError> {
    // A `&Repo` read outside any call: resolved for `jj log`, whose `-r` it answers (Story 9.41).
    let config = crate::config::load_for(repo, crate::cli_command::LOG)?;
    let parse_config = revset_config(&config, sink)?;
    let workspace = repo.workspace();
    let short = crate::template::load_short_prefixes(
        (workspace.workspace_root(), workspace.workspace_name()),
        &parse_config,
        &config,
        sink,
    )?;
    let parsed = parse_revset_with(repo, &parse_config, expr, sink)?;
    Ok((parsed, crate::graph::prefix_context(short.as_ref())))
}

/// Streams the commits `revset` denotes through `visit`, one [`Change`] at a time.
///
/// The generic read primitive of ADR-0003 §5: the commit stream is driven item by item and is
/// never collected, so a caller that stops early pays for the rows it consumed rather than for
/// the whole set. `visit` returning [`ControlFlow::Break`] stops the walk and yields `Ok(Break)`;
/// an exhausted stream yields `Ok(Continue)`. Exactly one [`Change`] is built per visited row,
/// but the *I/O* is not equally tight: jj-lib's `RevsetStreamExt::commits` pipelines commit loads
/// with `.buffered(store.concurrency())`, so a `Break` may leave up to that many loads already
/// dispatched. Bounded by a constant, never by the size of the set.
///
/// One row per COMMIT, not per change: unlike [`resolve_revset`], nothing is deduplicated, so a
/// divergent change contributes one row per visible commit — each carrying the same
/// [`Change::id`] with `divergent` set. A caller keying rows by change id must handle that.
///
/// Symbols resolve through `prefixes`, the call's start-up id-prefix context (the CLI's
/// `default_symbol_resolver`).
///
/// The five phases mirror [`crate::graph::walk_graph`]: load the effective config once, build
/// the alias map, parse (no loaded operation needed, so a syntax error costs no head load
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
/// - [`RevsetError::JjLibError`] — the head load, evaluation, or a per-item stream/store
///   failure. Changes already handed to `visit` before an `Err` are not retracted — discard
///   partial output on `Err`.
pub(crate) fn eval_revset(
    repo: &Repo,
    sink: &mut Warnings,
    revset: &str,
    prefixes: &IdPrefixContext,
    mut visit: impl FnMut(Change) -> ControlFlow<()>,
) -> Result<ControlFlow<()>, RevsetError> {
    // 1. Effective config ONCE per walk (never cached — Story 4.9), then parse against the
    //    alias map it feeds. Parsing needs no loaded operation.
    let config = crate::config::load(repo)?;
    let parse_config = revset_config(&config, sink)?;
    let parsed = parse_revset_with(repo, &parse_config, revset, sink)?;

    // 2. Reload to head (ADR-0002; sync via pollster — mirrors `resolve_revset` above).
    let readonly = crate::snapshot::reload_head(repo.workspace()).map_err(RevsetError::JjLibError)?;
    let repo_dyn: &dyn jj_lib::repo::Repo = readonly.as_ref();
    let store = readonly.store();

    // 3. Evaluate to a lazy revset borrowing `readonly`. The stream is never returned — items
    //    leave through `visit` — which is what keeps that borrow local.
    let set = evaluate_revset(repo_dyn, &parsed, Some(prefixes))?;

    // 4. Drive the lazy stream into the visitor; stop at the first `Break`. The order is the
    //    RAW revset order (topological, children before parents) — `jj log`'s printed order is
    //    `walk_graph`'s job, not this primitive's.
    pollster::block_on(async {
        let mut stream = std::pin::pin!(set.stream().commits(store));
        while let Some(item) = stream.next().await {
            let commit = item.map_err(|e| RevsetError::JjLibError(e.to_string()))?;
            let change = change_from_commit(repo_dyn, &commit).map_err(RevsetError::JjLibError)?;
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
/// map once, then calls [`parse_revset_with`] directly. The alias load's warnings and the
/// parse diagnostics land in `sink` (Story 9.32).
///
/// # Errors
///
/// - [`RevsetError::ParseError`] — syntactically invalid expression or unknown function.
/// - [`RevsetError::Config`] — the repo's jj config is malformed or unreadable.
pub(crate) fn parse_revset(
    repo: &Repo,
    expr: &str,
    sink: &mut Warnings,
) -> Result<Arc<UserRevsetExpression>, RevsetError> {
    let config = crate::config::load(repo)?;
    let parse_config = revset_config(&config, sink)?;
    parse_revset_with(repo, &parse_config, expr, sink)
}

/// The config-derived inputs of a revset parse, read off ONE effective stack: the alias map
/// and `mine()`'s `user.email`.
pub(crate) struct RevsetConfig {
    aliases_map: RevsetAliasesMap,
    user_email: String,
}

impl RevsetConfig {
    /// The `[revset-aliases]` map — also what a template's `RevsetParseContext` expands
    /// (Story 9.51).
    pub(crate) fn aliases_map(&self) -> &RevsetAliasesMap {
        &self.aliases_map
    }

    /// `mine()`'s `user.email`.
    pub(crate) fn user_email(&self) -> &str {
        &self.user_email
    }
}

/// Reads [`RevsetConfig`] out of a loaded stack — the CLI's `load_revset_aliases`
/// (`cli/src/cli_util.rs:3415-3423` @ v0.44.0): the alias map, then the builtin-redefinition
/// check. Their warnings are recorded once per call into `sink` (Story 9.32).
///
/// # Errors
///
/// - [`ConfigError::Load`] — a layer's `revset-aliases` is not a table, or `user.email` is
///   not a string.
pub(crate) fn revset_config(config: &StackedConfig, sink: &mut Warnings) -> Result<RevsetConfig, ConfigError> {
    let (aliases_map, mut warnings) = build_aliases_map(config, "revset-aliases")?;
    warnings.extend(redefined_builtins(config));
    sink.record_load(Load::RevsetAliases, warnings);
    Ok(RevsetConfig {
        aliases_map,
        user_email: crate::config::user_email(config)?,
    })
}

/// The CLI's `warn_user_redefined_builtin` (`cli/src/revset_util.rs:154-180` @ v0.44.0): one
/// [`WarningKind::ConfigAliasRedefined`] per non-builtin layer that redefines one of the three
/// mutability builtins.
fn redefined_builtins(config: &StackedConfig) -> Vec<Warning> {
    const CHECKED: [&str; 3] = ["mutable()", "immutable()", "builtin_immutable_heads()"];
    let mut out = Vec::new();
    for layer in config
        .layers()
        .iter()
        .skip_while(|layer| layer.source == ConfigSource::Default)
    {
        let Ok(Some(table)) = layer.look_up_table("revset-aliases") else {
            continue;
        };
        for decl in CHECKED.iter().filter(|decl| table.contains_key(decl)) {
            out.push(warning::local(
                WarningKind::ConfigAliasRedefined,
                format!("Redefining `revset-aliases.{decl}` is not recommended; redefine `immutable_heads()` instead."),
            ));
        }
    }
    out
}

/// The context line the CLI prints above a user revset's parse diagnostics
/// (`cli/src/cli_util.rs:1851` @ v0.44.0).
pub(crate) const IN_REVSET_EXPRESSION: &str = "In revset expression";

/// Parses `expr` in this workspace's revset context (`parse_config`'s aliases and user email,
/// the workspace name for `@`, a `git`-default ignored remote). Pure parsing — no symbol is
/// resolved yet, so the result is independent of any loaded operation. Its diagnostics land in
/// `sink` under the CLI's "In revset expression" (Story 9.32).
///
/// # Errors
///
/// - [`RevsetError::ParseError`] — syntactically invalid expression or unknown function.
pub(crate) fn parse_revset_with(
    repo: &Repo,
    parse_config: &RevsetConfig,
    expr: &str,
    sink: &mut Warnings,
) -> Result<Arc<UserRevsetExpression>, RevsetError> {
    parse_diagnosed(repo.workspace(), parse_config, (expr, IN_REVSET_EXPRESSION), sink)
}

/// Parses `expr` and records its diagnostics under `context` — the CLI's `revset::parse`
/// followed by `print_parse_diagnostics(ui, context, …)`, which prints only after a
/// SUCCESSFUL parse. `(expr, context)` travel as one pair.
///
/// # Errors
///
/// - [`RevsetError::ParseError`] — syntactically invalid expression or unknown function.
pub(crate) fn parse_diagnosed(
    workspace: &Workspace,
    parse_config: &RevsetConfig,
    (expr, context): (&str, &str),
    sink: &mut Warnings,
) -> Result<Arc<UserRevsetExpression>, RevsetError> {
    parse_diagnosed_with(workspace, parse_config, (expr, context), &[], sink)
}

/// [`parse_diagnosed`] with string-valued local variables bound in the parse context — the CLI's
/// `context.local_variables.insert(name, revset::new_string_node(value))`, which `jj git push`
/// uses to bind `remote` while it parses `revsets.git-push` (`push.rs:1433-1436` @ v0.46.0).
///
/// # Errors
///
/// - [`RevsetError::ParseError`] — syntactically invalid expression or unknown function.
pub(crate) fn parse_diagnosed_with(
    workspace: &Workspace,
    parse_config: &RevsetConfig,
    (expr, context): (&str, &str),
    locals: &[(&str, &str)],
    sink: &mut Warnings,
) -> Result<Arc<UserRevsetExpression>, RevsetError> {
    parse_diagnosed_at(
        (workspace.workspace_root(), workspace.workspace_name()),
        parse_config,
        (expr, context),
        locals,
        sink,
    )
}

/// Parses every text in `exprs` and UNIONS them — the CLI's `parse_union_revsets`
/// (`cli/src/cli_util.rs:1889-1903` @ v0.46.0): one diagnostics sink for all of them, recorded
/// under "In revset expression" only once EVERY text parsed (Story 9.19).
///
/// # Errors
///
/// - [`RevsetError::ParseError`] — a text is syntactically invalid or names an unknown function.
pub(crate) fn parse_union_diagnosed(
    workspace: &Workspace,
    parse_config: &RevsetConfig,
    exprs: &[String],
    sink: &mut Warnings,
) -> Result<Arc<UserRevsetExpression>, RevsetError> {
    let mut diagnostics = RevsetDiagnostics::new();
    let mut expressions = Vec::with_capacity(exprs.len());
    for expr in exprs {
        expressions.push(parse_revset_in(
            (workspace.workspace_root(), workspace.workspace_name()),
            parse_config,
            expr,
            &[],
            &mut diagnostics,
        )?);
    }
    sink.extend(warning::parse_diagnostics(
        WarningKind::RevsetDiagnostic,
        IN_REVSET_EXPRESSION,
        &diagnostics,
    ));
    Ok(RevsetExpression::union_all(&expressions))
}

/// [`parse_diagnosed_with`] for a workspace given by its root and name — a template's
/// `revsets.short-prefixes` parse, which may be for a workspace no [`Workspace`] is at hand for
/// (`workspace add`'s new one, Story 9.51).
///
/// # Errors
///
/// - [`RevsetError::ParseError`] — syntactically invalid expression or unknown function.
pub(crate) fn parse_diagnosed_at(
    workspace: (&Path, &WorkspaceName),
    parse_config: &RevsetConfig,
    (expr, context): (&str, &str),
    locals: &[(&str, &str)],
    sink: &mut Warnings,
) -> Result<Arc<UserRevsetExpression>, RevsetError> {
    let mut diagnostics = RevsetDiagnostics::new();
    let parsed = parse_revset_in(workspace, parse_config, expr, locals, &mut diagnostics)?;
    sink.extend(warning::parse_diagnostics(
        WarningKind::RevsetDiagnostic,
        context,
        &diagnostics,
    ));
    Ok(parsed)
}

/// The context line the CLI prints above the `revsets.short-prefixes` parse diagnostics
/// (`load_short_prefixes_expression`, `cli/src/cli_util.rs:1139` @ v0.46.0).
pub(crate) const IN_SHORT_PREFIXES: &str = "In `revsets.short-prefixes`";

/// Parses the `revsets.short-prefixes` text `expr` for a workspace given by its root and name —
/// [`parse_diagnosed_at`] with its diagnostics recorded once per call ([`Load::ShortPrefixes`]):
/// the CLI parses the key once per command, in its start-up environment.
///
/// # Errors
///
/// - [`RevsetError::ParseError`] — syntactically invalid expression or unknown function.
pub(crate) fn parse_short_prefixes(
    workspace: (&Path, &WorkspaceName),
    parse_config: &RevsetConfig,
    expr: &str,
    sink: &mut Warnings,
) -> Result<Arc<UserRevsetExpression>, RevsetError> {
    let mut own = Warnings::default();
    let parsed = parse_diagnosed_at(workspace, parse_config, (expr, IN_SHORT_PREFIXES), &[], &mut own)?;
    sink.record_load(Load::ShortPrefixes, own.take());
    Ok(parsed)
}

/// Parses `expr` for a caller that holds a bare [`Workspace`], collecting jj-lib's parse
/// diagnostics into `diagnostics` — the conversion verbs' pre-verb snapshot runs before any
/// [`Repo`] exists (Story 9.26).
///
/// # Errors
///
/// - [`RevsetError::ParseError`] — syntactically invalid expression or unknown function.
fn parse_revset_in(
    (workspace_root, workspace_name): (&Path, &WorkspaceName),
    parse_config: &RevsetConfig,
    expr: &str,
    locals: &[(&str, &str)],
    diagnostics: &mut RevsetDiagnostics,
) -> Result<Arc<UserRevsetExpression>, RevsetError> {
    // Parse context — every borrowed local is declared before `context` so it outlives it.
    let fileset_aliases = FilesetAliasesMap::new();
    let extensions = RevsetExtensions::default();
    // `mine()`'s input comes from the per-call effective config, like the aliases: the CLI
    // reads it per invocation, so an external `jj config set user.email` is seen at once.
    let user_email: &str = &parse_config.user_email;
    let date_ctx: jj_lib::time_util::DatePatternContext = chrono::Local::now().into();
    let path_converter = RepoPathUiConverter::Fs {
        cwd: workspace_root.to_owned(),
        base: workspace_root.to_owned(),
    };
    let workspace_ctx = RevsetWorkspaceContext {
        path_converter: &path_converter,
        workspace_name,
    };
    // WHY: three USER-VISIBLE revset-language changes arrived with the jj-lib 0.42 → 0.44 bump
    // (Story 9.0a). None is a no-op; all reach users through `resolve_revset` and through
    // `walk_graph` / `graph_topology` and the FFI `graphTopology(revset:)` pass-through (the
    // `graphSlice` one until Story 4.12, 2026-10-01), where the revset is user-typed.
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
    //    Pinned by `revset_bare_pattern_arg_is_exact_not_substring` in tests/it/revset.rs.
    //
    // 2. Git-like symbols (e.g. `refs/heads/main`) are NO LONGER resolved to revisions; the
    //    bookmark/tag `<name>` or `<name>@<remote>` syntax replaces them. A revset that relied
    //    on the old form now fails to resolve rather than silently changing meaning.
    //
    // 3. The `git_head()` and `git_refs()` FUNCTIONS are gone from jj-lib's revset table
    //    (present at `jj-lib-0.42.0/src/revset.rs:982,991`, absent in 0.44). A revset using
    //    them is now a parse error. The underlying `View::git_head()` / `View::git_refs()` are
    //    unchanged, so the property those functions exposed is still assertable one level down —
    //    which is how `tests/it/convert.rs` and `tests/it/op_log.rs` were re-anchored in this story.
    //
    // Changes 2 and 3 are LOUD (the revset fails to parse or resolve, so the user is told);
    // change 1 is SILENT — same input, different valid answer — which is why only it carries a
    // regression test.
    let context = RevsetParseContext {
        aliases_map: &parse_config.aliases_map,
        local_variables: locals
            .iter()
            .map(|(name, value)| (*name, revset::new_string_node(value)))
            .collect(),
        user_email,
        date_pattern_context: date_ctx,
        default_ignored_remote: Some("git".as_ref()),
        fileset_aliases_map: &fileset_aliases,
        extensions: &extensions,
        workspace: Some(workspace_ctx),
    };

    // The source chain too (`In alias …` → the alias body's own error): the CLI prints it as
    // "Caused by:" lines; jj-lib's `Display` shows only the outermost error.
    revset::parse(diagnostics, expr, &context).map_err(|e| RevsetError::ParseError {
        reason: crate::mutate::flatten_chain(&e),
        detail: Box::new(parse_detail(expr, &e)),
    })
}

/// The [`RevsetErrorDetail`] of a parse error of `expr`: the top-level error's kind, span and
/// named symbol, and the CLI's hint (which reads the BOTTOM error of the alias chain).
fn parse_detail(expr: &str, e: &RevsetParseError) -> RevsetErrorDetail {
    use RevsetErrorKind as K;
    use RevsetParseErrorKind as P;
    let (kind, symbol, candidates) = match e.kind() {
        P::SyntaxError => (K::SyntaxError, None, Vec::new()),
        P::NotPrefixOperator { op, similar_op, .. } => (K::NotPrefixOperator, Some(op), vec![similar_op.clone()]),
        P::NotPostfixOperator { op, similar_op, .. } => (K::NotPostfixOperator, Some(op), vec![similar_op.clone()]),
        P::NotInfixOperator { op, similar_op, .. } => (K::NotInfixOperator, Some(op), vec![similar_op.clone()]),
        P::NoSuchFunction { name, candidates } => (K::NoSuchFunction, Some(name), candidates.clone()),
        P::InvalidFunctionArguments { name, .. } => (K::InvalidFunctionArguments, Some(name), Vec::new()),
        P::FsPathWithoutWorkspace => (K::FsPathWithoutWorkspace, None, Vec::new()),
        P::WorkingCopyWithoutWorkspace => (K::WorkingCopyWithoutWorkspace, None, Vec::new()),
        P::RedefinedFunctionParameter => (K::RedefinedFunctionParameter, None, Vec::new()),
        P::Expression(_) => (K::Expression, None, Vec::new()),
        P::InAliasExpansion(name) => (K::InAliasExpansion, Some(name), Vec::new()),
        P::InParameterExpansion(name) => (K::InParameterExpansion, Some(name), Vec::new()),
        P::RecursiveAlias(name) => (K::RecursiveAlias, Some(name), Vec::new()),
    };
    RevsetErrorDetail {
        kind,
        span: render_span(expr, &e.to_string()),
        symbol: symbol.cloned(),
        candidates,
        hints: parse_hint(e).into_iter().collect(),
    }
}

/// The [`RevsetErrorDetail`] of a resolution error, with the CLI's hint lines.
fn resolution_detail(e: &RevsetResolutionError) -> RevsetErrorDetail {
    use RevsetErrorKind as K;
    use RevsetResolutionError as R;
    let (kind, symbol, candidates) = match e {
        R::NoSuchRevision { name, candidates } => (K::NoSuchRevision, Some(name.clone()), candidates.clone()),
        R::WorkspaceMissingWorkingCopy { name } => (
            K::WorkspaceMissingWorkingCopy,
            Some(name.as_symbol().to_string()),
            Vec::new(),
        ),
        R::EmptyString => (K::EmptyString, None, Vec::new()),
        R::AmbiguousCommitIdPrefix(prefix) => (K::AmbiguousCommitIdPrefix, Some(prefix.clone()), Vec::new()),
        R::AmbiguousChangeIdPrefix(prefix) => (K::AmbiguousChangeIdPrefix, Some(prefix.clone()), Vec::new()),
        R::DivergentChangeId { symbol, .. } => (K::DivergentChangeId, Some(symbol.clone()), Vec::new()),
        R::ConflictedRef { symbol, .. } => (K::ConflictedRef, Some(symbol.clone()), Vec::new()),
        R::Backend(_) => (K::Backend, None, Vec::new()),
        R::Other(_) => (K::Other, None, Vec::new()),
    };
    RevsetErrorDetail {
        kind,
        span: None,
        symbol,
        candidates,
        hints: resolution_hints(e),
    }
}

/// Reads the span of a jj-lib parse error out of its `Display` text, pest's render: the header
/// ` --> L:C` (1-based line, 1-based CHAR column) gives the start, the one-line render's
/// underline the length (`^---` a position, `^^` two chars, `^-…-^` n). A lone `^` is `None`:
/// pest draws it for an empty span and for a one-char span alike. A render whose span crosses
/// lines has no one-line underline: `length` is `None` too. Offsets and lengths are converted to
/// bytes of `expr`; `None` when the render does not fit `expr`.
///
/// shortcut: parses pest's render because jj-lib 0.46 keeps the span private; replace when jj-lib exposes it
fn render_span(expr: &str, render: &str) -> Option<RevsetSpan> {
    let mut lines = render.lines();
    let (line, column) = lines.next()?.trim_start().strip_prefix("--> ")?.split_once(':')?;
    let (line, column): (usize, usize) = (line.parse().ok()?, column.parse().ok()?);
    let line_start: usize = expr.split('\n').take(line.checked_sub(1)?).map(|l| l.len() + 1).sum();
    let tail = expr.get(line_start..)?;
    let char_end = |n: usize| tail.char_indices().map(|(i, _)| i).chain([tail.len()]).nth(n);
    let start = char_end(column.checked_sub(1)?)?;
    // Skip the empty gutter line and the source line; then either `  | <underline>` (one line)
    // or `L | <continued line>` (the span crosses lines).
    let (gutter, underline) = lines.nth(2)?.split_once('|')?;
    let marks = underline.trim_start_matches([' ', '\t']);
    // WHY a lone `^` has no length: pest renders an empty span and a one-char span the same.
    let length = if gutter.trim().is_empty() && marks.starts_with('^') && marks != "^" {
        let chars = if marks == "^---" { 0 } else { marks.chars().count() };
        Some(u32::try_from(char_end(column - 1 + chars)? - start).ok()?)
    } else {
        // A line number, or the `...` of a span that skips lines.
        None
    };
    Some(RevsetSpan {
        offset: u32::try_from(line_start + start).ok()?,
        length,
    })
}

/// The CLI's `format_similarity_hint` (`cli/src/command_error.rs:227` @ v0.46.0).
fn similarity_hint(candidates: &[String]) -> Option<String> {
    if candidates.is_empty() {
        return None;
    }
    let quoted: Vec<String> = candidates.iter().map(|c| format!("`{c}`")).collect();
    Some(format!("Did you mean {}?", quoted.join(", ")))
}

/// The CLI's revset-syntax hint.
const REVSET_SYNTAX_HINT: &str = "See https://docs.jj-vcs.dev/latest/revsets/ or use `jj help -k revsets` for revsets \
                                  syntax and how to quote symbols.";

/// The CLI's `revset_parse_error_hint` (`cli/src/command_error.rs:892-923` @ v0.46.0): only for
/// the bottom error of the alias chain, usually the root cause.
fn parse_hint(err: &RevsetParseError) -> Option<String> {
    use RevsetParseErrorKind as P;
    let bottom = std::iter::successors(Some(err), |e| e.origin()).last()?;
    match bottom.kind() {
        P::SyntaxError => Some(REVSET_SYNTAX_HINT.to_owned()),
        P::NotPrefixOperator {
            similar_op,
            description,
            ..
        }
        | P::NotPostfixOperator {
            similar_op,
            description,
            ..
        }
        | P::NotInfixOperator {
            similar_op,
            description,
            ..
        } => Some(format!("Did you mean `{similar_op}` for {description}?")),
        P::NoSuchFunction { candidates, .. } => similarity_hint(candidates),
        P::InvalidFunctionArguments { .. } | P::Expression(_) => source_hint(bottom),
        _ => None,
    }
}

/// The CLI's `find_source_parse_error_hint` (`cli/src/command_error.rs:789-815` @ v0.46.0) for
/// the sources a revset parse error carries: a fileset, file-pattern or string-pattern error.
/// The CLI also checks bookmark-name, config, tag-name, template and resolution sources, which
/// no revset parse error carries.
fn source_hint(err: &dyn std::error::Error) -> Option<String> {
    let source = err.source()?;
    if let Some(e) = source.downcast_ref::<FilePatternParseError>() {
        file_pattern_hint(e)
    } else if let Some(e) = source.downcast_ref::<FilesetParseError>() {
        fileset_hint(e)
    } else if let Some(e) = source.downcast_ref::<StringPatternParseError>() {
        matches!(e, StringPatternParseError::InvalidKind(_)).then(|| {
            "Try prefixing with one of `exact:`, `glob:`, `regex:`, `substring:`, or one of these with `-i` suffix \
             added (e.g. `glob-i:`) for case-insensitive matching"
                .to_owned()
        })
    } else {
        None
    }
}

/// The CLI's `file_pattern_parse_error_hint` (`cli/src/command_error.rs:840-855` @ v0.46.0).
fn file_pattern_hint(err: &FilePatternParseError) -> Option<String> {
    match err {
        FilePatternParseError::InvalidKind(_) => Some(
            "See https://docs.jj-vcs.dev/latest/filesets/#file-patterns or `jj help -k filesets` for valid prefixes."
                .to_owned(),
        ),
        FilePatternParseError::UiPath(UiPathParseError::Fs(e)) => RepoPathBuf::from_relative_path(&e.input)
            .ok()
            .map(|path| format!("Consider using root:{path:?} to specify repo-relative path")),
        FilePatternParseError::RelativePath(_) | FilePatternParseError::GlobPattern(_) => None,
    }
}

/// The CLI's `fileset_parse_error_hint` (`cli/src/command_error.rs:857-873` @ v0.46.0).
fn fileset_hint(err: &FilesetParseError) -> Option<String> {
    use jj_lib::fileset::FilesetParseErrorKind as F;
    match err.kind() {
        F::SyntaxError => Some(
            "See https://docs.jj-vcs.dev/latest/filesets/ or use `jj help -k filesets` for filesets syntax and how to \
             match file paths."
                .to_owned(),
        ),
        F::NoSuchFunction { candidates, .. } => similarity_hint(candidates),
        F::InvalidArguments { .. } | F::Expression(_) => source_hint(err),
        F::RedefinedFunctionParameter | F::InAliasExpansion(_) | F::InParameterExpansion(_) | F::RecursiveAlias(_) => {
            None
        }
    }
}

/// The CLI's `revset_resolution_error_hints` (`cli/src/command_error.rs:925-977` @ v0.46.0).
fn resolution_hints(err: &RevsetResolutionError) -> Vec<String> {
    use RevsetResolutionError as R;
    let multiple_targets_hint = |targets: &[JjCommitId]| {
        let ids: Vec<String> = targets.iter().map(|id| format!("{id:.12}")).collect();
        format!("Use commit ID to select single revision from: {}", ids.join(", "))
    };
    match err {
        R::NoSuchRevision { candidates, .. } => similarity_hint(candidates).into_iter().collect(),
        R::DivergentChangeId {
            symbol,
            visible_targets,
        } => {
            let offsets: Vec<String> = visible_targets
                .iter()
                .map(|(offset, _)| format!("{symbol}/{offset}"))
                .collect();
            vec![
                format!("Use change offset to select single revision: {}", offsets.join(", ")),
                format!("Use `change_id({symbol})` to select all revisions"),
                "To abandon unneeded revisions, run `jj abandon <commit_id>`".to_owned(),
            ]
        }
        R::ConflictedRef {
            kind: "bookmark",
            symbol,
            targets,
        } => vec![
            multiple_targets_hint(targets),
            format!("Use `bookmarks({symbol})` to select all revisions"),
            format!("To set which revision the bookmark points to, run `jj bookmark set {symbol} -r <REVISION>`"),
        ],
        R::ConflictedRef { targets, .. } => vec![multiple_targets_hint(targets)],
        R::EmptyString
        | R::WorkspaceMissingWorkingCopy { .. }
        | R::AmbiguousCommitIdPrefix(_)
        | R::AmbiguousChangeIdPrefix(_)
        | R::Backend(_)
        | R::Other(_) => Vec::new(),
    }
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
/// `prefixes` as in [`resolve_for_evaluation`].
///
/// # Errors
///
/// - [`RevsetError::ResolutionError`] — a symbol cannot be resolved (unknown bookmark/tag,
///   no working-copy commit for `@`, unmatched/ambiguous id).
pub(crate) fn resolve_expression(
    repo_dyn: &dyn jj_lib::repo::Repo,
    expr: &Arc<UserRevsetExpression>,
    prefixes: Option<&IdPrefixContext>,
) -> Result<Arc<ResolvedRevsetExpression>, RevsetError> {
    // WHY drop the other repos: the CLI's `RevsetExpressionEvaluator::resolve`
    // (`cli/src/revset_util.rs:118-121` @ v0.46.0) does the same — only `evaluate` needs the
    // index `at_operation()` merges in.
    let (expression, _other_repos) = resolve_for_evaluation(repo_dyn, expr, prefixes)?.into_inner();
    Ok(expression)
}

/// [`resolve_expression`] keeping what jj-lib needs to EVALUATE the result: the repos an
/// `at_operation()` brings into context, whose commits a non-ancestor operation may not have
/// in `repo_dyn`'s index.
///
/// With `prefixes`, short id prefixes resolve within its disambiguation set first — the CLI's
/// `SymbolResolver::with_id_prefix_context` (`cli/src/revset_util.rs:197-203` @ v0.46.0), which
/// every user or config revset the CLI evaluates goes through (`attach_revset_evaluator` →
/// `default_symbol_resolver`, `cli/src/cli_util.rs:1905-1921`). `None` only where the CLI uses a
/// plain resolver; a set that fails to populate refuses only an id-prefix-shaped symbol (commit
/// or change id; jj-lib's `RevsetResolutionError::Other`).
pub(crate) fn resolve_for_evaluation<'r>(
    repo_dyn: &'r dyn jj_lib::repo::Repo,
    expr: &Arc<UserRevsetExpression>,
    prefixes: Option<&IdPrefixContext>,
) -> Result<ResolvedRevset<'r>, RevsetError> {
    let extensions = RevsetExtensions::default();
    let symbol_resolver = SymbolResolver::new(repo_dyn, extensions.symbol_resolvers());
    let symbol_resolver = match prefixes {
        Some(context) => symbol_resolver.with_id_prefix_context(context),
        None => symbol_resolver,
    };
    expr.resolve_user_expression(repo_dyn, &symbol_resolver)
        .map_err(|e| RevsetError::ResolutionError {
            reason: e.to_string(),
            detail: Box::new(resolution_detail(&e)),
        })
}

/// Resolves the symbols of a parsed expression against `repo_dyn` (a head-resolved
/// `ReadonlyRepo`, ADR-0002) and evaluates it to a lazy revset borrowing that repo. `prefixes` as
/// in [`resolve_for_evaluation`].
///
/// # Errors
///
/// - [`RevsetError::ResolutionError`] — a symbol cannot be resolved (unknown bookmark/tag,
///   no working-copy commit for `@`, unmatched/ambiguous id).
/// - [`RevsetError::JjLibError`] — an internal jj-lib evaluation failure.
pub(crate) fn evaluate_revset<'r>(
    repo_dyn: &'r dyn jj_lib::repo::Repo,
    expr: &Arc<UserRevsetExpression>,
    prefixes: Option<&IdPrefixContext>,
) -> Result<Box<dyn Revset + 'r>, RevsetError> {
    // `ResolvedRevset::evaluate`, as the CLI's `RevsetExpressionEvaluator::evaluate`
    // (`cli/src/revset_util.rs:134-139` @ v0.46.0): it evaluates against an index merged with
    // the repos an `at_operation()` brought in.
    resolve_for_evaluation(repo_dyn, expr, prefixes)?
        .evaluate()
        .map_err(|e| RevsetError::JjLibError(e.to_string()))
}

/// Builds an alias map from every `[<table_name>]` table in `config`, lowest layer first —
/// Zanshin's builtin defaults, then the user, repo and workspace layers.
///
/// ONE port for every alias language, generic over jj-lib's declaration parser exactly like
/// the CLI's own `load_aliases_map`: `revset-aliases` builds the `RevsetAliasesMap` the revset
/// parser expands, and `fileset-aliases` (Story 9.22, the CLI's `load_fileset_aliases`,
/// `cli/src/cli_util.rs:3407-3413`) builds the `FilesetAliasesMap` `snapshot.auto-track` is
/// parsed with.
///
/// Mirrors the CLI's `load_aliases_map` (`cli/src/config.rs:930-981`): insertion is keyed
/// by (name, arity), so a user's `trunk()` REPLACES the builtin while a user's `trunk(x)`
/// merely adds an overload. A value may be a plain string or a table with a `definition`
/// string key.
///
/// The CLI's two failure levels are mirrored exactly, and they differ:
///
/// - **The TABLE level is a hard error.** A layer whose `<table_name>` is not a table at
///   all aborts the load (`cli/src/config.rs:943-953` returns `ConfigGetError::Type`).
///   Skipping it would silently fall back to the builtin aliases — the one behaviour this
///   story exists to prevent.
/// - **The ENTRY level warns and continues** (`cli/src/config.rs:1009-1032` @ v0.44.0): a
///   non-string value or a declaration jj-lib's parser rejects is skipped with a
///   [`WarningKind::ConfigAliasInvalid`] carrying the CLI's "Failed to load `{table}.{decl}`: …"
///   (Story 9.32), and every other alias still loads. One messy entry must not take down the
///   whole table. The warnings are RETURNED; the caller records them once per call.
///
/// jj-lib does not check the DEFINITION (`dsl_util.rs:594-597`), so a malformed `defn`
/// surfaces later still, when the alias is substituted.
///
/// # Errors
///
/// - [`ConfigError::Load`] — a config layer's `<table_name>` key is not a table.
pub(crate) fn build_aliases_map<P>(
    config: &StackedConfig,
    table_name: &'static str,
) -> Result<(AliasesMap<P, String>, Vec<Warning>), ConfigError>
where
    P: AliasDeclarationParser + Default,
    P::Error: std::fmt::Display,
{
    let mut map = AliasesMap::<P, String>::new();
    let mut warnings = Vec::new();
    for layer in config.layers() {
        let table = match layer.look_up_table(table_name) {
            Ok(Some(table)) => table,
            Ok(None) => continue,
            Err(item) => {
                let path = layer.path.as_deref().unwrap_or(Path::new("<builtin>"));
                return Err(ConfigError::Load {
                    reason: format!(
                        "{}: {table_name}: Expected a table, but is {}",
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
            let failure = match definition {
                Some(definition) => map.insert(decl, definition, doc).err().map(|e| e.to_string()),
                None => Some(format!(
                    "Expected a string or a table with a `definition` string key, but is {}",
                    item.type_name()
                )),
            };
            if let Some(reason) = failure {
                warnings.push(warning::local(
                    WarningKind::ConfigAliasInvalid,
                    format!("Failed to load `{table_name}.{decl}`: {reason}"),
                ));
            }
        }
    }
    Ok((map, warnings))
}

/// Builds the CLI's immutable-set expression, `::(immutable_heads() | root())`.
///
/// Mirrors the CLI's *in-code* construction (`cli/src/revset_util.rs:193-203` +
/// `cli/src/cli_util.rs:956-961`: parse the `immutable_heads()` definition, union
/// `root()`, then `ancestors()`) rather than the `immutable()` alias, which exists only
/// for user-written revsets. Both denote the same set, but mirroring the in-code form is
/// what lets Story 4.9's config override of `immutable_heads()` flow through unchanged.
///
/// Like `parse_immutable_heads_expression`, it parses the alias's DEFINITION text, so a parse
/// diagnostic points into the definition exactly as the CLI's does; the diagnostics are
/// recorded once per call under "In `revset-aliases.immutable_heads()`" (Story 9.32). Should
/// the 0-arity alias be missing (the builtin layer always defines it), the call expression is
/// parsed instead and jj-lib names the problem.
///
/// # Errors
///
/// - [`ConfigError::Load`] — the `immutable_heads()` alias does not parse: "Invalid
///   `revset-aliases.immutable_heads()`: {jj-lib's parse error}", as
///   [`immutable_heads_expression`].
pub(crate) fn immutable_expression(
    workspace: &Workspace,
    parse_config: &RevsetConfig,
    sink: &mut Warnings,
) -> Result<Arc<UserRevsetExpression>, ConfigError> {
    Ok(immutable_heads_expression(workspace, parse_config, sink)?
        .union(&RevsetExpression::root())
        .ancestors())
}

/// The CLI's `revset_util::try_resolve_trunk_alias` (`cli/src/revset_util.rs:220-241` @ v0.46.0)
/// as `load_from_workspace` consumes it (Story 9.56): the resolution error of the `trunk()`
/// alias's definition against `repo`, or `None` when it resolves — or does not even parse (the CLI
/// then leaves it to the commands that use it).
pub(crate) fn trunk_resolution_error(
    workspace: &Workspace,
    parse_config: &RevsetConfig,
    repo: &dyn jj_lib::repo::Repo,
) -> Option<String> {
    let (_, _, definition, _) = parse_config.aliases_map.get_function("trunk", 0)?;
    let expression = parse_revset_in(
        (workspace.workspace_root(), workspace.workspace_name()),
        parse_config,
        definition,
        &[],
        &mut RevsetDiagnostics::new(),
    )
    .ok()?;
    // WHY no id-prefix context: `try_resolve_trunk_alias` resolves with a plain
    // `SymbolResolver::new` (`cli/src/revset_util.rs:237` @ v0.46.0).
    match resolve_expression(repo, &expression, None) {
        Err(RevsetError::ResolutionError { reason, .. }) => Some(reason),
        _ => None,
    }
}

/// The `immutable_heads()` expression alone — the CLI's `immutable_heads_expression()`
/// (`cli/src/cli_util.rs` @ v0.46.0), which [`immutable_expression`] widens to the immutable SET
/// and `jj git push`'s commit checks use as it is (Story 9.20). Its diagnostics are recorded once
/// per call, as in [`immutable_expression`].
///
/// # Errors
///
/// - [`ConfigError::Load`] — the `immutable_heads()` alias does not parse. The reason is the
///   CLI's start-up text, "Invalid `revset-aliases.immutable_heads()`: " + jj-lib's parse error
///   (`load_immutable_heads_expression`, `cli/src/cli_util.rs:1106-1117` @ v0.46.0, raised for
///   every command — `jj git push` included), in the shape of `revsets.short-prefixes`'s.
pub(crate) fn immutable_heads_expression(
    workspace: &Workspace,
    parse_config: &RevsetConfig,
    sink: &mut Warnings,
) -> Result<Arc<UserRevsetExpression>, ConfigError> {
    let definition = parse_config
        .aliases_map
        .get_function("immutable_heads", 0)
        .map(|(_, _, definition, _)| definition.clone());
    let mut diagnostics = RevsetDiagnostics::new();
    let heads = parse_revset_in(
        (workspace.workspace_root(), workspace.workspace_name()),
        parse_config,
        definition.as_deref().unwrap_or("immutable_heads()"),
        &[],
        &mut diagnostics,
    )
    .map_err(|e| ConfigError::Load {
        reason: format!(
            "Invalid `revset-aliases.immutable_heads()`: {}",
            crate::template::parse_reason(e)
        ),
    })?;
    sink.record_load(
        Load::ImmutableHeads,
        warning::parse_diagnostics(
            WarningKind::RevsetDiagnostic,
            "In `revset-aliases.immutable_heads()`",
            &diagnostics,
        ),
    );
    Ok(heads)
}

#[cfg(test)]
mod tests {
    use jj_lib::config::{ConfigLayer, ConfigSource};

    use super::{immutable_expression, immutable_heads_expression, revset_config, RevsetConfig};
    use crate::config::ConfigError;
    use crate::warning::Warnings;

    const PREFIX: &str = "Invalid `revset-aliases.immutable_heads()`: ";

    /// A fresh repo and the revset config of its effective config with `toml` as a user layer.
    fn repo_with(toml: &str) -> (tempfile::TempDir, crate::Repo, RevsetConfig) {
        test_helpers::pin_test_env();
        let tmp = tempfile::TempDir::new().expect("tempdir");
        let repo = crate::Repo::init(&crate::InitOptions {
            path: tmp.path().to_owned(),
            ..Default::default()
        })
        .result
        .expect("init");
        let mut config = crate::config::load(&repo).expect("config");
        config.add_layer(ConfigLayer::parse(ConfigSource::User, toml).expect("toml"));
        let parse_config = revset_config(&config, &mut Warnings::default()).expect("revset config");
        (tmp, repo, parse_config)
    }

    fn reason<T>(result: Result<T, ConfigError>) -> String {
        let ConfigError::Load { reason } = result.err().expect("expected a config error");
        reason
    }

    /// An unparseable `immutable_heads()` refuses with the CLI's start-up text
    /// (`cli_util.rs:1106-1117` @ v0.46.0), jj-lib's parse error after it — without
    /// `RevsetError`'s own `invalid revset: ` prefix.
    #[test]
    fn an_unparseable_alias_is_the_clis_config_error() {
        let (_tmp, repo, parse_config) = repo_with("[revset-aliases]\n'immutable_heads()' = 'bogus_function('\n");
        for reason in [
            reason(immutable_heads_expression(
                repo.workspace(),
                &parse_config,
                &mut Warnings::default(),
            )),
            reason(immutable_expression(
                repo.workspace(),
                &parse_config,
                &mut Warnings::default(),
            )),
        ] {
            assert!(reason.starts_with(PREFIX), "{reason}");
            assert!(!reason.contains("invalid revset: "), "{reason}");
            assert!(
                reason.contains("bogus_function"),
                "jj-lib's parse error follows: {reason}"
            );
        }
    }

    /// A parse error inside a nested alias keeps jj-lib's source chain — each `In alias …` level
    /// down to the broken body's own error — as the CLI's "Caused by:" lines do; jj-lib's
    /// `Display` alone shows only the outermost level.
    #[test]
    fn a_parse_error_in_a_nested_alias_keeps_its_cause_chain() {
        let (_tmp, repo, parse_config) =
            repo_with("[revset-aliases]\n'immutable_heads()' = 'broken()'\n'broken()' = 'bogus_function('\n");
        let reason = reason(immutable_heads_expression(
            repo.workspace(),
            &parse_config,
            &mut Warnings::default(),
        ));
        assert!(reason.starts_with(PREFIX), "{reason}");
        assert!(reason.contains("In alias `broken()`"), "{reason}");
        assert!(
            reason.contains("bogus_function"),
            "the broken body's own error closes the chain: {reason}"
        );
    }

    /// The builtin alias parses, into both the heads and the set.
    #[test]
    fn the_builtin_alias_parses() {
        let (_tmp, repo, parse_config) = repo_with("");
        let mut sink = Warnings::default();
        assert!(immutable_heads_expression(repo.workspace(), &parse_config, &mut sink).is_ok());
        assert!(immutable_expression(repo.workspace(), &parse_config, &mut sink).is_ok());
    }

    // ── Story 9.25: span and hints ───────────────────────────────────────────

    use jj_lib::backend::CommitId;
    use jj_lib::revset::RevsetResolutionError as R;

    use super::{render_span, resolution_hints, RevsetErrorDetail, RevsetErrorKind as K, RevsetSpan};

    /// The span `render` names in `expr`, as `(offset, length)`.
    fn spanned(expr: &str, render: &str) -> (u32, Option<u32>) {
        let RevsetSpan { offset, length } = render_span(expr, render).expect("a span");
        (offset, length)
    }

    #[test]
    fn a_position_is_a_zero_length_span() {
        let render = " --> 1:15\n  |\n1 | description(\"x\n  |               ^---\n  |\n  = expected x";
        assert_eq!(spanned("description(\"x", render), (14, Some(0)));
    }

    #[test]
    fn one_two_and_n_char_spans_read_their_underline() {
        let one = " --> 1:3\n  |\n1 | a|b\n  |   ^\n  |\n  = m";
        assert_eq!(
            spanned("a|b", one),
            (2, None),
            "a lone `^` is an empty or a one-char span"
        );
        let two = " --> 1:1\n  |\n1 | ab\n  | ^^\n  |\n  = m";
        assert_eq!(spanned("ab", two), (0, Some(2)));
        let four = " --> 1:1\n  |\n1 | fooo()\n  | ^--^\n  |\n  = m";
        assert_eq!(spanned("fooo()", four), (0, Some(4)));
        let tabbed = " --> 1:2\n  |\n1 | \tfooo()\n  | \t^--^\n  |\n  = m";
        assert_eq!(spanned("\tfooo()", tabbed), (1, Some(4)));
    }

    #[test]
    fn columns_count_chars_and_the_span_is_in_bytes() {
        // `äö | ` is 5 chars but 7 bytes; `fööo` 4 chars but 6 bytes.
        let render = " --> 1:6\n  |\n1 | äö | fööo()\n  |      ^--^\n  |\n  = m";
        assert_eq!(spanned("äö | fööo()", render), (7, Some(6)));
    }

    #[test]
    fn a_span_on_a_later_line_counts_the_earlier_lines() {
        let render = " --> 2:3\n  |\n2 | xyfooo\n  |   ^--^\n  |\n  = m";
        assert_eq!(spanned("ab\nxyfooo", render), (5, Some(4)));
    }

    #[test]
    fn a_span_across_lines_has_no_length() {
        let two = " --> 1:1\n  |\n1 | a\n2 | b\n  | ^^\n  |\n  = m";
        assert_eq!(spanned("a\nb", two), (0, None));
        let gap = " --> 1:1\n  |\n1 | a\n  | ...\n3 | c\n  | ^^\n  |\n  = m";
        assert_eq!(spanned("a\nb\nc", gap), (0, None));
    }

    #[test]
    fn a_render_that_does_not_fit_the_text_has_no_span() {
        assert_eq!(render_span("x", "no header"), None);
        assert_eq!(render_span("x", " --> 9:1\n  |\n9 | x\n  | ^\n"), None);
        assert_eq!(render_span("x", " --> 1:9\n  |\n1 | x\n  | ^\n"), None);
    }

    /// The parse detail of `expr`.
    fn parse_detail(parse_config: &RevsetConfig, repo: &crate::Repo, expr: &str) -> RevsetErrorDetail {
        let workspace = repo.workspace();
        let Err(crate::RevsetError::ParseError { detail, .. }) = super::parse_revset_in(
            (workspace.workspace_root(), workspace.workspace_name()),
            parse_config,
            expr,
            &[],
            &mut jj_lib::revset::RevsetDiagnostics::new(),
        ) else {
            panic!("{expr} parses");
        };
        *detail
    }

    /// Real jj-lib renders: an empty span, a non-ASCII text, a span on a later line and one that
    /// crosses lines.
    #[test]
    fn jj_lib_parse_errors_read_back_their_spans() {
        let (_tmp, repo, parse_config) = repo_with("");
        let span = |expr| {
            let detail = parse_detail(&parse_config, &repo, expr);
            detail.span.map(|s| (s.offset, s.length))
        };
        assert_eq!(span("author()"), Some((7, None)), "the empty argument list");
        assert_eq!(
            span("author(\"Jörg\") & fooo()"),
            Some((18, Some(4))),
            "bytes, not chars"
        );
        assert_eq!(span("all() &\nfooo()"), Some((8, Some(4))), "on the second line");
        assert_eq!(span("author(a,\nb)"), Some((7, None)), "the arguments, across lines");
    }

    #[test]
    fn parse_hints_follow_the_clis_per_kind_rules() {
        let (_tmp, repo, parse_config) = repo_with("");
        let detail = |expr| parse_detail(&parse_config, &repo, expr);

        let syntax = detail("(");
        assert_eq!((syntax.kind, syntax.hints.len()), (K::SyntaxError, 1));
        let postfix = detail("foo^");
        assert_eq!(postfix.kind, K::NotPostfixOperator);
        assert_eq!(postfix.symbol.as_deref(), Some("^"));
        assert_eq!(postfix.hints, ["Did you mean `-` for parents?"]);
        assert_eq!(detail(":foo").hints, ["Did you mean `::` for ancestors?"]);
        let infix = detail("foo + bar");
        assert_eq!(infix.kind, K::NotInfixOperator);
        assert_eq!(infix.candidates, ["|"]);
        assert_eq!(infix.hints, ["Did you mean `|` for union?"]);
        let similar = detail("descripton(x)");
        assert!(
            similar.hints.len() == 1 && similar.hints[0].contains("`description`"),
            "{similar:?}"
        );
        let arguments = detail("author(a, b)");
        assert_eq!(arguments.kind, K::InvalidFunctionArguments);
        assert_eq!(arguments.symbol.as_deref(), Some("author"));
        assert!(arguments.hints.is_empty());
        assert!(detail(r#"description(bogus:"x")"#).hints[0].starts_with("Try prefixing with one of `exact:`"));
        assert!(detail(r#"files(bogus:"x")"#).hints[0].contains("filesets/#file-patterns"));
        assert!(detail("files(a::)").hints[0].contains("filesets syntax"));
    }

    #[test]
    fn resolution_hints_follow_the_clis_per_kind_rules() {
        let id = CommitId::from_hex("0123456789abcdef0123456789abcdef01234567");
        assert_eq!(
            resolution_hints(&R::NoSuchRevision {
                name: "x".to_owned(),
                candidates: vec!["a".to_owned(), "b".to_owned()],
            }),
            ["Did you mean `a`, `b`?"]
        );
        assert!(resolution_hints(&R::NoSuchRevision {
            name: "x".to_owned(),
            candidates: Vec::new(),
        })
        .is_empty());
        assert_eq!(
            resolution_hints(&R::DivergentChangeId {
                symbol: "k".to_owned(),
                visible_targets: vec![(0, id.clone()), (2, id.clone())],
            }),
            [
                "Use change offset to select single revision: k/0, k/2",
                "Use `change_id(k)` to select all revisions",
                "To abandon unneeded revisions, run `jj abandon <commit_id>`",
            ]
        );
        let targets = vec![id.clone(), id];
        assert_eq!(
            resolution_hints(&R::ConflictedRef {
                kind: "bookmark",
                symbol: "main".to_owned(),
                targets: targets.clone(),
            }),
            [
                "Use commit ID to select single revision from: 0123456789ab, 0123456789ab",
                "Use `bookmarks(main)` to select all revisions",
                "To set which revision the bookmark points to, run `jj bookmark set main -r <REVISION>`",
            ]
        );
        assert_eq!(
            resolution_hints(&R::ConflictedRef {
                kind: "tag",
                symbol: "v1".to_owned(),
                targets,
            }),
            ["Use commit ID to select single revision from: 0123456789ab, 0123456789ab"]
        );
        assert!(resolution_hints(&R::AmbiguousChangeIdPrefix("k".to_owned())).is_empty());
        assert!(resolution_hints(&R::EmptyString).is_empty());
    }

    #[test]
    fn resolution_details_name_their_symbol() {
        let detail = super::resolution_detail(&R::AmbiguousCommitIdPrefix("ab".to_owned()));
        assert_eq!(
            (detail.kind, detail.symbol.as_deref(), detail.span),
            (K::AmbiguousCommitIdPrefix, Some("ab"), None)
        );
        let empty = super::resolution_detail(&R::EmptyString);
        assert_eq!((empty.kind, empty.symbol), (K::EmptyString, None));
    }
}
