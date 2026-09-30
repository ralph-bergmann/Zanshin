// SPDX-License-Identifier: MIT

//! The index-only graph topology of a whole revset (Story 4.10).
//!
//! [`graph_topology`] is the CLI's one `jj log` (`cli/src/commands/log.rs` @ v0.44.0) split
//! along "index/View-derived" vs "object-derived": it runs [`crate::graph::walk_graph`]'s
//! parse → load → `TopoGroupedGraph` + `prioritize_branch` pipeline, but reads nothing per node
//! that needs the commit object. Per node it carries the commit id, jj's edges verbatim (targets
//! resolved to node indices) and the view half ([`TopologyMeta`]); the object half is
//! [`crate::Repo::commit_contents`], pinned to the [`GraphTopology::operation_id`] this call
//! loaded. Per-call loads are fine (`trunk()`'s `latest` candidates, a filter alias); per-node
//! loads happen only for the committer timestamps a caller requests.

use std::collections::HashMap;
use std::hash::Hash;
use std::sync::Arc;

use futures::{StreamExt as _, TryStreamExt as _};
use jj_lib::backend::{ChangeId as JjChangeId, CommitId as JjCommitId};
use jj_lib::object_id::ObjectId as _;
use jj_lib::repo::Repo as _;
use jj_lib::revset::{ResolvedRevsetExpression, RevsetFilterPredicate};

use crate::graph::{edge_kind, LogParse};
use crate::revset::{evaluate_revset, parse_revset_with};
use crate::warning::Warnings;
use crate::{CommitId, CommitRef, GraphEdgeKind, OperationId, Repo, RevsetError};

/// The whole revset's index-only topology at one operation (Story 4.10).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GraphTopology {
    /// The operation this call's own `load_at_head` loaded — after the call's precondition
    /// snapshot, if that wrote one. [`crate::Repo::commit_contents`] reads the object half at it.
    pub operation_id: OperationId,
    /// The revset's nodes in `jj log` order (children before parents, `prioritize` first).
    pub nodes: Vec<TopologyNode>,
    /// Per caller-supplied anchor, in request order: the indices of the nodes it selects (the
    /// anchor intersected with the revset), ascending — which is `jj log` order.
    pub anchors: Vec<Vec<usize>>,
    /// `|all()|`, counted by iterating — the "shown / total" denominator. It counts the
    /// VISIBLE commits only, so a revset that names hidden commits can yield more nodes than
    /// this.
    pub all_count: usize,
}

/// One node of a [`GraphTopology`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TopologyNode {
    /// The commit's full hex id.
    pub commit_id: CommitId,
    /// jj's parent edges verbatim, in `TopoGroupedGraph` stream order: repeated targets are
    /// kept (a merge can carry a Direct and an Indirect edge to one node).
    pub edges: Vec<TopologyEdge>,
    /// The view half of the node's `jj log` metadata.
    pub meta: TopologyMeta,
    /// The committer timestamp (millis since the Unix epoch) — `None` when timestamps were not
    /// requested, and always for the root commit.
    pub committer_timestamp_ms: Option<i64>,
}

/// One parent edge of a [`TopologyNode`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TopologyEdge {
    /// The target node's index in [`GraphTopology::nodes`]; `None` iff the edge is
    /// [`GraphEdgeKind::Missing`] (its target is outside the revset).
    pub target: Option<usize>,
    /// How jj-lib classified the edge.
    pub kind: GraphEdgeKind,
}

/// The view half of a `jj log` row (Story 4.10): what the index and the operation's View
/// answer, plus the node's exact parent count. The object half is [`crate::CommitContent`];
/// both compose [`crate::CommitMeta`].
// WHY(clippy::struct_excessive_bools): the same independent template keywords as on
// `CommitMeta` (see its WHY) — one commit can be an immutable, hidden, divergent working copy.
#[allow(clippy::struct_excessive_bools)]
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TopologyMeta {
    /// Change id in jj reverse-hex display form.
    pub change_id: String,
    /// Shortest unique prefix length of [`Self::change_id`], within the `short_prefixes`
    /// disambiguation set (or the full index when disabled).
    pub change_id_prefix_len: u32,
    /// Shortest unique prefix length of the node's commit id, same scoping.
    pub commit_id_prefix_len: u32,
    /// Index of this commit among the commits sharing its change id, when jj-lib yields one.
    pub change_offset: Option<u32>,
    /// Bookmarks pointing at this commit, CLI-filtered (see [`CommitRef`]).
    pub bookmarks: Vec<CommitRef>,
    /// Tags pointing at this commit, same shape and filter.
    pub tags: Vec<CommitRef>,
    /// Names of the workspaces whose working-copy commit this is; always empty in a
    /// single-workspace repo (the CLI's guard).
    pub working_copies: Vec<String>,
    /// This workspace's `@`.
    pub working_copy: bool,
    /// Contained in `::(immutable_heads() | root())`.
    pub immutable: bool,
    /// The commit is not visible (reachable only when the revset names hidden ids).
    pub hidden: bool,
    /// The change id resolves to more than one visible commit.
    pub divergent: bool,
    /// The repository's root commit.
    pub root: bool,
    /// The commit's real parent count, Missing parents included: 0 for the root, 1 for any
    /// other non-merge. Read from the index, never from edges (a hidden parent can yield several
    /// Indirect edges, and a merge can yield two edges to one target).
    pub parent_count: u32,
}

/// Converts any jj-lib error to [`RevsetError::JjLibError`].
fn jj<E: std::fmt::Display>(e: E) -> RevsetError {
    RevsetError::JjLibError(e.to_string())
}

/// Computes the revset's index-only topology — see [`crate::Repo::graph_topology`].
///
/// Passes: (1) parse `revset`/`prioritize`/`short_prefixes` like `walk_graph`, then every anchor
/// against the same alias map, intersected with `revset` as a user expression — all before the
/// load; (2) `load_at_head`, evaluate, resolve every anchor once; (3) one `commit_change_ids`
/// pass into a commit → change map; (4) the `ParentCount` passes; (5) the `TopoGroupedGraph`
/// stream, the view half per node and — only when asked — each non-root commit's committer
/// timestamp; (6) edge targets resolved to node indices; (7) anchors mapped to node indices;
/// (8) `all_count`.
///
/// # Errors
///
/// - [`RevsetError::ParseError`] — any expression (anchors included) is syntactically invalid;
///   raised before any repo I/O.
/// - [`RevsetError::ResolutionError`] — a symbol in `revset`, `prioritize` or an anchor cannot
///   be resolved.
/// - [`RevsetError::Config`] — the repo's effective jj config is malformed or unreadable.
/// - [`RevsetError::DanglingEdge`] — a Direct/Indirect edge names a target outside the node
///   set (jj-lib's stream contract rules it out).
/// - [`RevsetError::JjLibError`] — `load_at_head`, evaluation, a view-half lookup, a stream
///   item, or a timestamp's commit load failed.
pub(crate) fn graph_topology(
    repo: &Repo,
    sink: &mut Warnings,
    revset: &str,
    prioritize: &str,
    short_prefixes: &str,
    anchors: &[String],
    with_timestamps: bool,
) -> Result<GraphTopology, RevsetError> {
    // (1) Parse everything before the load.
    let parsed = LogParse::new(repo, sink, revset, prioritize, short_prefixes)?;
    let anchor_exprs = anchors
        .iter()
        .map(|anchor| Ok(parse_revset_with(repo, &parsed.config, anchor, sink)?.intersection(&parsed.log)))
        .collect::<Result<Vec<_>, RevsetError>>()?;

    // (2) Reload to head (ADR-0002), evaluate, resolve the anchors once.
    let readonly = pollster::block_on(repo.workspace().repo_loader().load_at_head()).map_err(jj)?;
    let repo_dyn: &dyn jj_lib::repo::Repo = readonly.as_ref();
    let store = readonly.store();
    let setup = parsed.evaluate(repo_dyn)?;
    let anchor_ids = anchor_exprs
        .iter()
        .map(|expr| {
            let set = evaluate_revset(repo_dyn, expr)?;
            pollster::block_on(set.stream().try_collect::<Vec<_>>()).map_err(jj)
        })
        .collect::<Result<Vec<_>, RevsetError>>()?;
    let meta = setup.meta_index(repo_dyn, repo.workspace().workspace_name(), sink);

    // (3) + (4) Index-only per-call passes.
    let change_ids: HashMap<JjCommitId, JjChangeId> =
        pollster::block_on(setup.set.commit_change_ids().try_collect()).map_err(jj)?;
    let merge_counts = parent_counts(repo_dyn, &setup.resolved)?;

    // (5) The `jj log` stream.
    let root_id = store.root_commit_id();
    let mut index_of: HashMap<JjCommitId, usize> = HashMap::new();
    let mut nodes: Vec<TopologyNode> = Vec::new();
    let mut raw_edges: Vec<Vec<(JjCommitId, GraphEdgeKind)>> = Vec::new();
    pollster::block_on(async {
        let mut stream = std::pin::pin!(setup.topo().stream());
        while let Some(item) = stream.next().await {
            let (id, edges) = item.map_err(jj)?;
            let change_id = change_ids
                .get(&id)
                .ok_or_else(|| RevsetError::JjLibError(format!("no change id for commit {}", id.hex())))?;
            let is_root = &id == root_id;
            let parent_count = if is_root {
                0
            } else {
                merge_counts.get(&id).copied().unwrap_or(1)
            };
            let view = meta.view_half(repo_dyn, &id, change_id, parent_count)?;
            let committer_timestamp_ms = if with_timestamps && !is_root {
                let commit = store.get_commit_async(&id).await.map_err(jj)?;
                Some(commit.committer().timestamp.timestamp.0)
            } else {
                None
            };
            index_of.insert(id.clone(), nodes.len());
            raw_edges.push(
                edges
                    .into_iter()
                    .map(|edge| (edge.target, edge_kind(edge.edge_type)))
                    .collect(),
            );
            nodes.push(TopologyNode {
                commit_id: CommitId(id.hex()),
                edges: Vec::new(),
                meta: view,
                committer_timestamp_ms,
            });
        }
        Ok::<(), RevsetError>(())
    })?;

    // (6) Targets → node indices, after the complete pass.
    for (node, edges) in nodes.iter_mut().zip(raw_edges) {
        node.edges = resolve_edges(edges, &index_of)?;
    }

    // (7) + (8)
    let anchors = anchor_ids.iter().map(|ids| anchor_indices(ids, &index_of)).collect();
    let all = ResolvedRevsetExpression::all().evaluate(repo_dyn).map_err(jj)?;
    let all_count = pollster::block_on(all.stream().try_fold(0usize, |n, _| async move { Ok(n + 1) })).map_err(jj)?;

    Ok(GraphTopology {
        operation_id: OperationId(readonly.op_id().hex()),
        nodes,
        anchors,
        all_count,
    })
}

/// The exact parent count of every merge in the revset, index-only: one `ParentCount(2..)`
/// filter pass over the resolved revset yields its merges, then each refinement `k = 3, 4, …`
/// tests only the previous pass's set (`ParentCount` reads the index entry). Commits absent from
/// the map have fewer than two parents.
///
/// # Errors
///
/// - [`RevsetError::JjLibError`] — an evaluation or stream failure.
fn parent_counts(
    repo_dyn: &dyn jj_lib::repo::Repo,
    resolved: &Arc<ResolvedRevsetExpression>,
) -> Result<HashMap<JjCommitId, u32>, RevsetError> {
    let ids_of = |expr: Arc<ResolvedRevsetExpression>| -> Result<Vec<JjCommitId>, RevsetError> {
        let set = expr.evaluate(repo_dyn).map_err(jj)?;
        pollster::block_on(set.stream().try_collect()).map_err(jj)
    };
    let merges = ids_of(resolved.filtered(RevsetFilterPredicate::ParentCount(2..u32::MAX)))?;
    refine_parent_counts(merges, |k, candidates| {
        ids_of(ResolvedRevsetExpression::commits(candidates).filtered(RevsetFilterPredicate::ParentCount(k..u32::MAX)))
    })
}

/// The refinement bookkeeping of [`parent_counts`]: every id of `merges` has ≥ 2 parents;
/// `pass(k, candidates)` returns the candidates with ≥ k parents. Stops at the first empty pass.
fn refine_parent_counts<I: Clone + Eq + Hash, E>(
    merges: Vec<I>,
    mut pass: impl FnMut(u32, Vec<I>) -> Result<Vec<I>, E>,
) -> Result<HashMap<I, u32>, E> {
    let mut counts: HashMap<I, u32> = merges.iter().map(|id| (id.clone(), 2)).collect();
    let mut candidates = merges;
    let mut k: u32 = 3;
    while !candidates.is_empty() {
        candidates = pass(k, candidates)?;
        for id in &candidates {
            counts.insert(id.clone(), k);
        }
        // An empty `k..u32::MAX` range at the top ends the loop even without the saturation.
        k = k.saturating_add(1);
    }
    Ok(counts)
}

/// Resolves one node's edge targets to node indices: a Missing edge has no target, a
/// Direct/Indirect target outside `index_of` is [`RevsetError::DanglingEdge`].
///
/// # Errors
///
/// - [`RevsetError::DanglingEdge`] — a Direct/Indirect target is not a node.
fn resolve_edges(
    edges: Vec<(JjCommitId, GraphEdgeKind)>,
    index_of: &HashMap<JjCommitId, usize>,
) -> Result<Vec<TopologyEdge>, RevsetError> {
    edges
        .into_iter()
        .map(|(target, kind)| {
            let target = match kind {
                GraphEdgeKind::Missing => None,
                GraphEdgeKind::Direct | GraphEdgeKind::Indirect => Some(
                    *index_of
                        .get(&target)
                        .ok_or_else(|| RevsetError::DanglingEdge { target: target.hex() })?,
                ),
            };
            Ok(TopologyEdge { target, kind })
        })
        .collect()
}

/// The node indices of an anchor's commits, ascending (= `jj log` order). An anchor is
/// intersected with the revset, so every id is a node; one that is not is skipped.
fn anchor_indices(ids: &[JjCommitId], index_of: &HashMap<JjCommitId, usize>) -> Vec<usize> {
    let mut indices: Vec<usize> = ids.iter().filter_map(|id| index_of.get(id).copied()).collect();
    indices.sort_unstable();
    indices
}

#[cfg(test)]
mod tests {
    use std::collections::HashMap;

    use jj_lib::backend::CommitId as JjCommitId;

    use super::{anchor_indices, refine_parent_counts, resolve_edges, TopologyEdge};
    use crate::{GraphEdgeKind, RevsetError};

    fn id(hex: &'static str) -> JjCommitId {
        JjCommitId::from_hex(hex)
    }

    fn index(pairs: &[(&'static str, usize)]) -> HashMap<JjCommitId, usize> {
        pairs.iter().map(|&(hex, i)| (id(hex), i)).collect()
    }

    #[test]
    fn resolve_edges_maps_targets_and_keeps_repeated_ones_in_order() {
        let index_of = index(&[("aa", 1), ("bb", 2)]);
        let edges = resolve_edges(
            vec![
                (id("aa"), GraphEdgeKind::Direct),
                (id("aa"), GraphEdgeKind::Indirect),
                (id("bb"), GraphEdgeKind::Direct),
            ],
            &index_of,
        )
        .unwrap();
        assert_eq!(
            edges,
            vec![
                TopologyEdge {
                    target: Some(1),
                    kind: GraphEdgeKind::Direct
                },
                TopologyEdge {
                    target: Some(1),
                    kind: GraphEdgeKind::Indirect
                },
                TopologyEdge {
                    target: Some(2),
                    kind: GraphEdgeKind::Direct
                },
            ]
        );
    }

    #[test]
    fn resolve_edges_gives_a_missing_edge_no_target_even_when_the_id_is_a_node() {
        let index_of = index(&[("aa", 0)]);
        let edges = resolve_edges(
            vec![(id("aa"), GraphEdgeKind::Missing), (id("cc"), GraphEdgeKind::Missing)],
            &index_of,
        )
        .unwrap();
        assert_eq!(
            edges,
            vec![
                TopologyEdge {
                    target: None,
                    kind: GraphEdgeKind::Missing
                },
                TopologyEdge {
                    target: None,
                    kind: GraphEdgeKind::Missing
                },
            ]
        );
    }

    #[test]
    fn resolve_edges_reports_a_direct_or_indirect_miss_as_a_dangling_edge() {
        let index_of = index(&[("aa", 0)]);
        for kind in [GraphEdgeKind::Direct, GraphEdgeKind::Indirect] {
            let err = resolve_edges(vec![(id("cc"), kind)], &index_of).unwrap_err();
            assert!(
                matches!(err, RevsetError::DanglingEdge { ref target } if target == "cc"),
                "got {err:?}"
            );
        }
    }

    #[test]
    fn anchor_indices_sort_ascending_and_skip_non_nodes() {
        let index_of = index(&[("aa", 4), ("bb", 0), ("cc", 2)]);
        assert_eq!(
            anchor_indices(&[id("aa"), id("dd"), id("bb"), id("cc")], &index_of),
            vec![0, 2, 4]
        );
        assert!(anchor_indices(&[], &index_of).is_empty());
    }

    #[test]
    fn refine_parent_counts_records_the_highest_passed_threshold() {
        // "a" has 2 parents, "b" 3, "c" 5: each pass keeps the candidates with ≥ k parents.
        let parents: HashMap<&str, u32> = [("a", 2), ("b", 3), ("c", 5)].into_iter().collect();
        let mut passes = Vec::new();
        let counts = refine_parent_counts(vec!["a", "b", "c"], |k, candidates| {
            passes.push(k);
            Ok::<_, ()>(candidates.into_iter().filter(|c| parents[c] >= k).collect())
        })
        .unwrap();
        assert_eq!(counts, parents);
        assert_eq!(passes, vec![3, 4, 5, 6], "stops after the first empty pass");
    }

    #[test]
    fn refine_parent_counts_without_merges_runs_no_pass() {
        let counts = refine_parent_counts(Vec::<&str>::new(), |_, _| -> Result<Vec<&str>, ()> {
            panic!("no merge, no refinement pass")
        })
        .unwrap();
        assert!(counts.is_empty());
    }

    #[test]
    fn refine_parent_counts_forwards_a_failing_pass() {
        let err = refine_parent_counts(vec!["a"], |_, _| Err::<Vec<&str>, _>("index unreadable")).unwrap_err();
        assert_eq!(err, "index unreadable");
    }
}
