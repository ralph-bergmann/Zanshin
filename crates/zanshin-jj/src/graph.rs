// SPDX-License-Identifier: MIT

//! Revset graph stream — the `jj log`-faithful graph read.
//!
//! *(2026-10-01, Story 4.12: this stream fed the lane crate's lane assignment; that crate and
//! its FFI slice are gone. `walk_graph` stays as the `jj log`-faithful read and the oracle of
//! Story 4.10's topology call, which the graph wire now carries.)*
//!
//! [`walk_graph`] reproduces the `jj log` pipeline at v0.42.0 (`cli/src/commands/log.rs`):
//! `TopoGroupedGraph::new(revset.stream_graph(), |id| id)` prioritised by the
//! `revsets.log-graph-prioritize` mechanics, so the visit order is the order `jj log
//! -r <revset>` prints (NFR-R-2, ADR-0003). The graph is re-derived from the head
//! operation on every call and never retained (ADR-0002 AC-4).
//!
//! The parse → load → evaluate → topo-group setup ([`LogParse`], [`LogSetup`]) is shared with
//! the index-only [`crate::topology::graph_topology`] (Story 4.10); `walk_graph` keeps its
//! per-row commit load and full rows.

use std::ops::ControlFlow;
use std::sync::Arc;

use futures::stream::LocalBoxStream;
use futures::{StreamExt as _, TryStreamExt as _};
use jj_lib::backend::CommitId as JjCommitId;
use jj_lib::graph::{GraphEdge as JjGraphEdge, GraphEdgeType, GraphNode as JjGraphNodeOf, TopoGroupedGraph};
use jj_lib::id_prefix::{IdPrefixContext, IdPrefixIndex};
use jj_lib::object_id::ObjectId as _;
use jj_lib::ref_name::WorkspaceName;
use jj_lib::repo::Repo as _;
use jj_lib::revset::{ResolvedRevsetExpression, Revset, RevsetEvaluationError, RevsetExtensions, UserRevsetExpression};

use crate::commit_meta::LogMetaIndex;
use crate::revset::{
    evaluate_revset, immutable_expression, parse_diagnosed, parse_revset_with, parse_short_prefixes,
    resolve_expression, revset_config, RevsetConfig, IN_SHORT_PREFIXES,
};
use crate::warning::{self, WarningKind, Warnings};
use crate::{CommitId, CommitMeta, Repo, RevsetError};

/// The jj CLI's default `revsets.log-graph-prioritize` (`cli/src/config/revsets.toml` at
/// v0.42.0): emit the working-copy branch first.
///
/// A pre-fill for the caller's `prioritize` parameter — [`Repo::walk_graph`] never applies it
/// silently (FR-JJ-17).
pub const DEFAULT_GRAPH_PRIORITIZE: &str = "present(@)";

/// How a [`GraphEdge`]'s target was classified by jj-lib's revset-graph stream.
///
/// Variant order follows the wire's `GraphEdgeKind` (`schemas/envelope.fbs`; 2026-10-01,
/// Story 4.12 — it followed the removed lane crate's `EdgeKind` before), not jj-lib's — the
/// two are mapped by an exhaustive `match`, never by discriminant.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GraphEdgeKind {
    /// The parent is in the revset; it arrives later in the stream.
    Direct,
    /// The direct parent was elided from the revset; the edge points at the closest
    /// ancestor that IS in the set, which arrives later in the stream.
    Indirect,
    /// The edge leads outside the revset; its target never arrives.
    Missing,
}

/// One parent edge of a [`GraphNode`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GraphEdge {
    /// The parent commit's id.
    pub target: CommitId,
    /// How jj-lib classified this edge.
    pub kind: GraphEdgeKind,
}

/// One node of the revset graph stream: a commit id and its parent edges.
///
/// Edges are in stream order and are NOT one-per-parent: jj-lib splices elided-parent
/// edges, so an elided parent contributes zero, one, or several [`GraphEdgeKind::Indirect`]
/// edges after ancestor dedup and transitive-edge removal (jj-lib 0.42.0
/// `default_index/revset_graph_iterator.rs`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GraphNode {
    /// Hex commit id (rows are keyed by commit id, not change id).
    pub id: CommitId,
    /// Parent edges in stream order.
    pub parents: Vec<GraphEdge>,
    /// `jj log`-parity display metadata, extracted from the SAME head-resolved snapshot
    /// as the edges (Story 4.8) — one call is one coherent view of the repo (ADR-0002).
    pub meta: CommitMeta,
}

/// Converts any jj-lib error to [`RevsetError::JjLibError`].
fn jj<E: std::fmt::Display>(e: E) -> RevsetError {
    RevsetError::JjLibError(e.to_string())
}

/// Maps jj-lib's edge type onto the crate-owned kind (exhaustive — the variant orders differ).
pub(crate) fn edge_kind(kind: GraphEdgeType) -> GraphEdgeKind {
    match kind {
        GraphEdgeType::Missing => GraphEdgeKind::Missing,
        GraphEdgeType::Direct => GraphEdgeKind::Direct,
        GraphEdgeType::Indirect => GraphEdgeKind::Indirect,
    }
}

/// Converts one `TopoGroupedGraph` stream item plus its extracted metadata into the
/// crate-owned node.
fn to_node(id: &JjCommitId, edges: Vec<JjGraphEdge<JjCommitId>>, meta: CommitMeta) -> GraphNode {
    GraphNode {
        id: CommitId(id.hex()),
        parents: edges
            .into_iter()
            .map(|edge| GraphEdge {
                target: CommitId(edge.target.hex()),
                kind: edge_kind(edge.edge_type),
            })
            .collect(),
        meta,
    }
}

/// Builds the shortest-prefix index, degrading to the full repo index like the CLI does.
///
/// A PARSE failure of the caller's `short_prefixes` expression is a hard error (raised
/// before this point). Everything that can only fail while LOADING the disambiguation
/// index — symbol resolution included — is a warning: the CLI keeps rendering with
/// full-index prefixes rather than failing the command
/// (`cli/src/commit_templater.rs:2203-2216` @ v0.44.0, pinned by jj's own
/// `cli/tests/test_log_command.rs::test_log_bad_short_prefixes`, where
/// `revsets.short-prefixes = 'missing'` warns and still prints the whole log). The warning is
/// `jj.short_prefixes_failed` (Story 9.32): the CLI's `print_parse_diagnostics` block — its
/// "In template expression" context line, "Failed to load short-prefixes index" and the
/// failure's source chain. One deviation remains: the CLI also renders the template position
/// (the `-->` span over the template text); Zanshin renders no template, so there is none.
pub(crate) fn short_prefix_index<'c>(
    ctx: &'c IdPrefixContext,
    repo_dyn: &dyn jj_lib::repo::Repo,
    sink: &mut Warnings,
) -> IdPrefixIndex<'c> {
    match ctx.populate(repo_dyn) {
        Ok(index) => index,
        Err(e) => {
            let mut lines = vec![
                "In template expression".to_owned(),
                "Failed to load short-prefixes index".to_owned(),
            ];
            lines.extend(warning::error_chain_lines(&e));
            sink.push(WarningKind::ShortPrefixesFailed, lines.join("\n"));
            IdPrefixIndex::empty()
        }
    }
}

/// Builds the `IdPrefixContext` for `short_prefixes`.
///
/// An EMPTY expression disables disambiguation (full-index prefixes) — the CLI's
/// `revsets.short-prefixes` toggle semantic, deliberately unlike `prioritize`, where a
/// blank value is a parse error.
pub(crate) fn prefix_context(short: Option<&Arc<UserRevsetExpression>>) -> IdPrefixContext {
    let ctx = IdPrefixContext::new(Arc::new(RevsetExtensions::default()));
    match short {
        Some(expr) => ctx.disambiguate_within(expr.clone()),
        None => ctx,
    }
}

/// The identity id-mapper `TopoGroupedGraph` needs, as a `fn` pointer (HRTB inference).
type IdFn = for<'a> fn(&'a JjCommitId) -> &'a JjCommitId;

/// The `jj log` graph stream over a repo borrowed for `'r`: `TopoGroupedGraph` over
/// `Revset::stream_graph`, prioritised.
pub(crate) type LogTopo<'r> = TopoGroupedGraph<
    JjCommitId,
    JjCommitId,
    LocalBoxStream<'r, Result<JjGraphNodeOf<JjCommitId>, RevsetEvaluationError>>,
    IdFn,
>;

/// Everything one `jj log` walk parses BEFORE it loads a repo — shared by [`walk_graph`] and
/// [`crate::topology::graph_topology`] (Story 4.10), so both parse in the CLI's order with the
/// same diagnostics.
pub(crate) struct LogParse {
    /// The ONE alias map (+ `mine()`'s email) every expression of the call parses against.
    pub(crate) config: RevsetConfig,
    immutable: Arc<UserRevsetExpression>,
    short: Option<Arc<UserRevsetExpression>>,
    /// The caller's `revset`.
    pub(crate) log: Arc<UserRevsetExpression>,
    /// `prioritize ∩ revset`, intersected as user expressions before resolution.
    prio: Arc<UserRevsetExpression>,
}

impl LogParse {
    /// Loads the effective config ONCE per walk (never cached — Story 4.9) and parses
    /// everything against the ONE alias map it feeds: `short_prefixes` first, where the CLI
    /// parses `revsets.short-prefixes` (its command environment, before the command's own
    /// revsets), then `revset` and `prioritize`. Parsing needs no loaded operation, so a syntax
    /// error costs no head-load I/O.
    ///
    /// # Errors
    ///
    /// - [`RevsetError::ParseError`] — any expression is syntactically invalid.
    /// - [`RevsetError::Config`] — the repo's effective jj config is malformed or unreadable, or
    ///   its `immutable_heads()` alias does not parse.
    pub(crate) fn new(
        repo: &Repo,
        sink: &mut Warnings,
        revset: &str,
        prioritize: &str,
        short_prefixes: &str,
    ) -> Result<Self, RevsetError> {
        let config = crate::config::load(repo)?;
        let parse_config = revset_config(&config, sink)?;
        let immutable = immutable_expression(repo.workspace(), &parse_config, sink)?;
        // The effective `revsets.short-prefixes` text is the one the start-up environment parsed
        // (`jj log` prints its diagnostics once): its parse here records under the same once-per-
        // call load. A caller-supplied override that differs warns on its own.
        let effective = crate::config::revsets_short_prefixes(&config).ok();
        let short = (!short_prefixes.is_empty())
            .then(|| {
                if effective.as_deref() == Some(short_prefixes) {
                    parse_short_prefixes(
                        (repo.workspace().workspace_root(), repo.workspace().workspace_name()),
                        &parse_config,
                        short_prefixes,
                        sink,
                    )
                } else {
                    parse_diagnosed(
                        repo.workspace(),
                        &parse_config,
                        (short_prefixes, IN_SHORT_PREFIXES),
                        sink,
                    )
                }
            })
            .transpose()
            .map_err(RevsetError::without_span)?;
        let log = parse_revset_with(repo, &parse_config, revset, sink)?;
        let prio = parse_revset_with(repo, &parse_config, prioritize, sink)
            .map_err(RevsetError::without_span)?
            .intersection(&log);
        Ok(Self {
            config: parse_config,
            immutable,
            short,
            log,
            prio,
        })
    }

    /// Resolves and evaluates the parsed expressions against the loaded `repo_dyn`, every
    /// symbol through ONE id-prefix context disambiguated within `short_prefixes` (the CLI's
    /// `default_symbol_resolver`); the prioritised commit ids are materialised (they are a tiny
    /// set).
    ///
    /// # Errors
    ///
    /// - [`RevsetError::ResolutionError`] — a symbol in `revset` or `prioritize` cannot be
    ///   resolved.
    /// - [`RevsetError::JjLibError`] — evaluation failed.
    pub(crate) fn evaluate<'r>(&self, repo_dyn: &'r dyn jj_lib::repo::Repo) -> Result<LogSetup<'r>, RevsetError> {
        let prefix_ctx = prefix_context(self.short.as_ref());
        let resolved = resolve_expression(repo_dyn, &self.log, Some(&prefix_ctx))?;
        let set = resolved.clone().evaluate(repo_dyn).map_err(jj)?;
        let prio_set = evaluate_revset(repo_dyn, &self.prio, Some(&prefix_ctx))?;
        let prio_ids: Vec<JjCommitId> = pollster::block_on(prio_set.stream().try_collect()).map_err(jj)?;
        let immutable_set = evaluate_revset(repo_dyn, &self.immutable, Some(&prefix_ctx))?;
        Ok(LogSetup {
            resolved,
            set,
            prio_ids,
            prefix_ctx,
            immutable_set,
        })
    }
}

/// One walk's evaluated state over a repo borrowed for `'r`: the revset, the prioritised ids and
/// what the per-call metadata indexes borrow (the prefix context, the immutable set).
pub(crate) struct LogSetup<'r> {
    /// The caller's `revset`, resolved once — what the topology's index-only passes refine.
    pub(crate) resolved: Arc<ResolvedRevsetExpression>,
    /// The caller's `revset`, evaluated.
    pub(crate) set: Box<dyn Revset + 'r>,
    prio_ids: Vec<JjCommitId>,
    /// The call's id-prefix context — what every symbol of the call resolves through.
    pub(crate) prefix_ctx: IdPrefixContext,
    immutable_set: Box<dyn Revset + 'r>,
}

impl<'r> LogSetup<'r> {
    /// Builds the per-call O(1) metadata indexes (Story 4.8). An index-LOAD failure of
    /// `short_prefixes` warns into `sink` and degrades (see [`short_prefix_index`]).
    pub(crate) fn meta_index(
        &self,
        repo_dyn: &dyn jj_lib::repo::Repo,
        workspace_name: &WorkspaceName,
        sink: &mut Warnings,
    ) -> LogMetaIndex<'_> {
        LogMetaIndex::new(
            repo_dyn,
            workspace_name,
            short_prefix_index(&self.prefix_ctx, repo_dyn, sink),
            self.immutable_set.containing_fn(),
        )
    }

    /// `TopoGroupedGraph::new(set.stream_graph(), |id| id)` with `prioritize_branch` for every
    /// prioritised commit id — the CLI's `jj log` graph pipeline.
    pub(crate) fn topo(&self) -> LogTopo<'r> {
        let as_id: IdFn = |id| id;
        let mut topo = TopoGroupedGraph::new(self.set.stream_graph(), as_id);
        for id in &self.prio_ids {
            topo.prioritize_branch(id.clone());
        }
        topo
    }
}

/// Streams the commit graph of `revset` in `jj log` order through `visit`, each node
/// carrying its `jj log`-parity metadata.
///
/// Pipeline (jj CLI v0.42.0 `cli/src/commands/log.rs`): parse every expression against ONE
/// builtin-alias map — `short_prefixes` first, where the CLI parses `revsets.short-prefixes`
/// (its command environment, before the command's own revsets), each parse's diagnostics
/// warning under the CLI's context line (Story 9.32) — intersect `prioritize` with `revset` as
/// user expressions BEFORE
/// resolution (an out-of-set prioritised id would make `TopoGroupedGraph` panic), evaluate
/// against the head-resolved repo, build the per-call metadata indexes, then
/// `TopoGroupedGraph::new(set.stream_graph(), |id| id)` with `prioritize_branch` for every
/// prioritised commit id, driven lazily into `visit` — one `store.get_commit_async` per
/// node, exactly as the CLI's render loop does.
///
/// # Errors
///
/// - [`RevsetError::ParseError`] — any expression is syntactically invalid.
/// - [`RevsetError::ResolutionError`] — a symbol in `revset` or `prioritize` cannot be
///   resolved. NOT raised for `short_prefixes`: an unresolvable disambiguation set only
///   warns and degrades (see [`short_prefix_index`]).
/// - [`RevsetError::Config`] — the repo's effective jj config is malformed or unreadable.
/// - [`RevsetError::JjLibError`] — the head load, evaluation, metadata extraction, or a
///   per-item stream failure.
pub(crate) fn walk_graph(
    repo: &Repo,
    sink: &mut Warnings,
    revset: &str,
    prioritize: &str,
    short_prefixes: &str,
    mut visit: impl FnMut(GraphNode) -> ControlFlow<()>,
) -> Result<ControlFlow<()>, RevsetError> {
    // 1. Parse everything before any repo I/O (shared with `graph_topology`, Story 4.10).
    let parsed = LogParse::new(repo, sink, revset, prioritize, short_prefixes)?;

    // 2. Reload to head (ADR-0002; sync via pollster — mirrors revset.rs).
    let readonly = crate::snapshot::reload_head(repo.workspace()).map_err(jj)?;
    let repo_dyn: &dyn jj_lib::repo::Repo = readonly.as_ref();
    let store = readonly.store();

    // 3.–5. Evaluate, build the per-call metadata indexes, topo-group + prioritise.
    let setup = parsed.evaluate(repo_dyn)?;
    let meta = setup.meta_index(repo_dyn, repo.workspace().workspace_name(), sink);
    let topo = setup.topo();

    // 6. Drive the lazy stream into the visitor; stop at the first `Break`.
    pollster::block_on(async {
        let mut stream = std::pin::pin!(topo.stream());
        while let Some(item) = stream.next().await {
            let (id, edges) = item.map_err(jj)?;
            let commit = store.get_commit_async(&id).await.map_err(jj)?;
            let node_meta = meta.extract(repo_dyn, &commit)?;
            if visit(to_node(&id, edges, node_meta)).is_break() {
                return Ok(ControlFlow::Break(()));
            }
        }
        Ok(ControlFlow::Continue(()))
    })
}

#[cfg(test)]
mod tests {
    use jj_lib::graph::GraphEdgeType;

    use super::{edge_kind, GraphEdgeKind};

    #[test]
    fn edge_kind_maps_every_jj_lib_variant_by_name_not_discriminant() {
        assert_eq!(edge_kind(GraphEdgeType::Missing), GraphEdgeKind::Missing);
        assert_eq!(edge_kind(GraphEdgeType::Direct), GraphEdgeKind::Direct);
        assert_eq!(edge_kind(GraphEdgeType::Indirect), GraphEdgeKind::Indirect);
    }
}
