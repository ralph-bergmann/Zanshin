// SPDX-License-Identifier: MIT

//! Revset graph stream — the jj-lib-free input of `zanshin-graph`'s lane assignment.
//!
//! [`walk_graph`] reproduces the `jj log` pipeline at v0.42.0 (`cli/src/commands/log.rs`):
//! `TopoGroupedGraph::new(revset.stream_graph(), |id| id)` prioritised by the
//! `revsets.log-graph-prioritize` mechanics, so the visit order is the order `jj log
//! -r <revset>` prints (NFR-R-2, ADR-0003). The graph is re-derived from the head
//! operation on every call and never retained (ADR-0002 AC-4).

use std::ops::ControlFlow;
use std::sync::Arc;

use futures::{StreamExt as _, TryStreamExt as _};
use jj_lib::backend::CommitId as JjCommitId;
use jj_lib::graph::{GraphEdge as JjGraphEdge, GraphEdgeType, TopoGroupedGraph};
use jj_lib::id_prefix::{IdPrefixContext, IdPrefixIndex};
use jj_lib::object_id::ObjectId as _;
use jj_lib::repo::Repo as _;
use jj_lib::revset::{RevsetExtensions, UserRevsetExpression};

use crate::commit_meta::LogMetaIndex;
use crate::revset::{build_aliases_map, evaluate_revset, immutable_expression, parse_revset_with};
use crate::{CommitId, CommitMeta, Repo, RevsetError};

/// The jj CLI's default `revsets.log-graph-prioritize` (`cli/src/config/revsets.toml` at
/// v0.42.0): emit the working-copy branch first.
///
/// A pre-fill for the caller's `prioritize` parameter — [`Repo::walk_graph`] never applies it
/// silently (FR-JJ-17).
pub const DEFAULT_GRAPH_PRIORITIZE: &str = "present(@)";

/// How a [`GraphEdge`]'s target was classified by jj-lib's revset-graph stream.
///
/// Variant order follows `zanshin_graph::EdgeKind` (Story 4.1 / 4.2), not jj-lib's —
/// the two are mapped by an exhaustive `match`, never by discriminant.
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
fn edge_kind(kind: GraphEdgeType) -> GraphEdgeKind {
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
/// (`cli/src/commit_templater.rs:2231-2243`, pinned by jj's own
/// `cli/tests/test_log_command.rs::test_log_bad_short_prefixes` @ v0.42.0, where
/// `revsets.short-prefixes = 'missing'` warns and still prints the whole log).
fn short_prefix_index<'c>(ctx: &'c IdPrefixContext, repo_dyn: &dyn jj_lib::repo::Repo) -> IdPrefixIndex<'c> {
    match ctx.populate(repo_dyn) {
        Ok(index) => index,
        Err(e) => {
            tracing::warn!(
                error = %e,
                "short-prefixes disambiguation index unavailable; falling back to full-index prefixes"
            );
            IdPrefixIndex::empty()
        }
    }
}

/// Builds the `IdPrefixContext` for `short_prefixes`.
///
/// An EMPTY expression disables disambiguation (full-index prefixes) — the CLI's
/// `revsets.short-prefixes` toggle semantic, deliberately unlike `prioritize`, where a
/// blank value is a parse error.
fn prefix_context(short: Option<&Arc<UserRevsetExpression>>) -> IdPrefixContext {
    let ctx = IdPrefixContext::new(Arc::new(RevsetExtensions::default()));
    match short {
        Some(expr) => ctx.disambiguate_within(expr.clone()),
        None => ctx,
    }
}

/// Streams the commit graph of `revset` in `jj log` order through `visit`, each node
/// carrying its `jj log`-parity metadata.
///
/// Pipeline (jj CLI v0.42.0 `cli/src/commands/log.rs`): parse every expression against ONE
/// builtin-alias map, intersect `prioritize` with `revset` as user expressions BEFORE
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
/// - [`RevsetError::JjLibError`] — `load_at_head`, evaluation, metadata extraction, or a
///   per-item stream failure.
pub(crate) fn walk_graph(
    repo: &Repo,
    revset: &str,
    prioritize: &str,
    short_prefixes: &str,
    mut visit: impl FnMut(GraphNode) -> ControlFlow<()>,
) -> Result<ControlFlow<()>, RevsetError> {
    // 1. Parse everything against ONE alias map (built once per walk — Story 4.9's seam).
    //    Parsing needs no loaded operation, so a syntax error costs no `load_at_head` I/O.
    let aliases = build_aliases_map()?;
    let log = parse_revset_with(repo, &aliases, revset)?;
    let prio = parse_revset_with(repo, &aliases, prioritize)?.intersection(&log);
    let short = (!short_prefixes.is_empty())
        .then(|| parse_revset_with(repo, &aliases, short_prefixes))
        .transpose()?;
    let immutable = immutable_expression(repo, &aliases)?;

    // 2. Reload to head (ADR-0002; sync via pollster — mirrors revset.rs).
    let readonly = pollster::block_on(repo.workspace().repo_loader().load_at_head()).map_err(jj)?;
    let repo_dyn: &dyn jj_lib::repo::Repo = readonly.as_ref();
    let store = readonly.store();

    // 3. Evaluate; the prioritised commit ids are materialised (they are a tiny set).
    let set = evaluate_revset(repo_dyn, &log)?;
    let prio_set = evaluate_revset(repo_dyn, &prio)?;
    let prio_ids: Vec<JjCommitId> = pollster::block_on(prio_set.stream().try_collect()).map_err(jj)?;

    // 4. Per-call O(1) metadata setup. `prefix_ctx` and `immutable_set` are locals so the
    //    borrows inside `meta` (the prefix index, the containment closure) stay valid.
    let prefix_ctx = prefix_context(short.as_ref());
    let immutable_set = evaluate_revset(repo_dyn, &immutable)?;
    let meta = LogMetaIndex::new(
        repo_dyn,
        repo.workspace().workspace_name(),
        short_prefix_index(&prefix_ctx, repo_dyn),
        immutable_set.containing_fn(),
    );

    // 5. Topo-group + prioritise (identity id-mapper as a `fn` pointer — HRTB inference).
    let as_id: for<'a> fn(&'a JjCommitId) -> &'a JjCommitId = |id| id;
    let mut topo = TopoGroupedGraph::new(set.stream_graph(), as_id);
    for id in prio_ids {
        topo.prioritize_branch(id);
    }

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
