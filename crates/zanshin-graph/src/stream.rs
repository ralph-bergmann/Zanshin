// SPDX-License-Identifier: MIT

//! Lane computation on demand: the revset graph stream of `zanshin-jj` fed through
//! [`LaneAssigner`], one final [`Row`] per node as it arrives.
//!
//! There is no lane cache (ADR-0002 AC-4): every [`stream_lanes`] call re-derives the
//! graph from the head operation via [`zanshin_jj::Repo::walk_graph`] and retains nothing.

use std::ops::ControlFlow;

use crate::{EdgeKind, GraphEdge, GraphError, GraphNode, LaneAssigner, Row};

/// Errors returned by [`stream_lanes`].
#[derive(Debug, thiserror::Error)]
pub enum LaneStreamError {
    /// The revset graph stream failed (parse/resolution/jj-lib failure of either expression).
    #[error(transparent)]
    Revset(#[from] zanshin_jj::RevsetError),
    /// The stream violated the [`GraphNode`] contract (a dangling edge at the end).
    #[error(transparent)]
    Graph(#[from] GraphError),
}

impl From<zanshin_jj::GraphEdgeKind> for EdgeKind {
    fn from(kind: zanshin_jj::GraphEdgeKind) -> Self {
        match kind {
            zanshin_jj::GraphEdgeKind::Direct => Self::Direct,
            zanshin_jj::GraphEdgeKind::Indirect => Self::Indirect,
            zanshin_jj::GraphEdgeKind::Missing => Self::Missing,
        }
    }
}

impl From<zanshin_jj::GraphNode> for GraphNode {
    fn from(node: zanshin_jj::GraphNode) -> Self {
        Self {
            id: node.id.0,
            parents: node
                .parents
                .into_iter()
                .map(|edge| GraphEdge {
                    target: edge.target.0,
                    kind: edge.kind.into(),
                })
                .collect(),
        }
    }
}

/// Streams the lane-assigned rows of `revset` through `sink`, in `jj log` order.
///
/// Drives [`zanshin_jj::Repo::walk_graph`] (re-resolved to head per call, `prioritize`
/// passed through — see [`zanshin_jj::DEFAULT_GRAPH_PRIORITIZE`]) through a fresh
/// [`LaneAssigner`], emitting each node's final [`Row`] as it arrives. `sink` returning
/// [`ControlFlow::Break`] stops the stream early: no further rows are produced, the
/// assigner's open reservations are legitimately left unchecked, and the result is
/// `Ok(Break)`. When the stream is exhausted, [`LaneAssigner::finish`] runs and the result
/// is `Ok(Continue)`.
///
/// `"none()"` is the canonical "no prioritization" value; an empty/blank `prioritize` is a
/// parse error (the CLI fails on an empty config value too). Rows already handed to `sink`
/// before an `Err` are not retracted — discard partial output on `Err`.
///
/// # Errors
///
/// - [`LaneStreamError::Revset`] — either expression failed to parse/resolve/evaluate, or
///   jj-lib failed mid-stream.
/// - [`LaneStreamError::Graph`] — the exhausted stream left a dangling non-`Missing` edge
///   (contract violation by the upstream stream).
pub fn stream_lanes(
    repo: &zanshin_jj::Repo,
    revset: &str,
    prioritize: &str,
    mut sink: impl FnMut(Row) -> ControlFlow<()>,
) -> Result<ControlFlow<()>, LaneStreamError> {
    let mut assigner = LaneAssigner::new();
    let flow = repo.walk_graph(revset, prioritize, |node| sink(assigner.push(node.into())))?;
    if flow.is_continue() {
        assigner.finish()?;
    }
    Ok(flow)
}

#[cfg(test)]
mod tests {
    use super::{EdgeKind, GraphEdge, GraphError, GraphNode, LaneStreamError};

    #[test]
    fn lane_stream_error_wraps_graph_error_transparently() {
        let inner = GraphError::DanglingEdge {
            target: "x".to_string(),
        };
        let expected = inner.to_string();
        let error = LaneStreamError::from(inner);
        assert!(matches!(error, LaneStreamError::Graph(..)), "got: {error:?}");
        assert_eq!(
            error.to_string(),
            expected,
            "#[error(transparent)] forwards the message"
        );
    }

    #[test]
    fn edge_kind_from_jj_maps_every_variant_by_name() {
        assert_eq!(EdgeKind::from(zanshin_jj::GraphEdgeKind::Direct), EdgeKind::Direct);
        assert_eq!(EdgeKind::from(zanshin_jj::GraphEdgeKind::Indirect), EdgeKind::Indirect);
        assert_eq!(EdgeKind::from(zanshin_jj::GraphEdgeKind::Missing), EdgeKind::Missing);
    }

    #[test]
    fn graph_node_from_jj_moves_ids_and_keeps_edge_order() {
        let upstream = zanshin_jj::GraphNode {
            id: zanshin_jj::CommitId("child".to_string()),
            parents: vec![
                zanshin_jj::GraphEdge {
                    target: zanshin_jj::CommitId("p1".to_string()),
                    kind: zanshin_jj::GraphEdgeKind::Missing,
                },
                zanshin_jj::GraphEdge {
                    target: zanshin_jj::CommitId("p2".to_string()),
                    kind: zanshin_jj::GraphEdgeKind::Indirect,
                },
            ],
        };
        assert_eq!(
            GraphNode::from(upstream),
            GraphNode {
                id: "child".to_string(),
                parents: vec![
                    GraphEdge {
                        target: "p1".to_string(),
                        kind: EdgeKind::Missing,
                    },
                    GraphEdge {
                        target: "p2".to_string(),
                        kind: EdgeKind::Indirect,
                    },
                ],
            }
        );
    }

    #[test]
    fn graph_node_from_jj_with_no_parents_is_a_root() {
        let upstream = zanshin_jj::GraphNode {
            id: zanshin_jj::CommitId("root".to_string()),
            parents: vec![],
        };
        assert_eq!(
            GraphNode::from(upstream),
            GraphNode {
                id: "root".to_string(),
                parents: vec![],
            }
        );
    }
}
