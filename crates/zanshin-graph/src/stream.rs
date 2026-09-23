// SPDX-License-Identifier: MIT

//! Lane computation on demand: the revset graph stream of `zanshin-jj` fed through
//! [`LaneAssigner`], one final [`Row`] per node as it arrives.
//!
//! There is no lane cache (ADR-0002 AC-4): every [`stream_lanes`] call re-derives the
//! graph from the head operation via [`zanshin_jj::Repo::walk_graph`] and retains nothing.

use std::ops::ControlFlow;

use crate::{EdgeKind, GraphEdge, GraphError, GraphNode, LaneAssigner, NodeId, Row};

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

/// Maps one upstream node into the lane-assigner's input, rewriting elided
/// ancestry when `synthetic_elided` is on.
///
/// Mirrors `cmd_log` (`cli/src/commands/log.rs:245-329`): each `Indirect` edge becomes a
/// `Direct` edge to the ELIDED identity `(target, synthetic = true)`, and the target is
/// collected so the caller can splice one synthetic row per collected target right after
/// this node's row. `Missing` edges are untouched (out-of-revset stubs). With the toggle
/// off, every edge keeps its upstream kind and points at the real commit — the pre-4.8
/// stream, verbatim.
fn splice_elided(node: zanshin_jj::GraphNode, synthetic_elided: bool) -> (GraphNode, Vec<String>) {
    let mut elided_targets = Vec::new();
    let parents = node
        .parents
        .into_iter()
        .map(|edge| {
            let target = edge.target.0;
            if synthetic_elided && edge.kind == zanshin_jj::GraphEdgeKind::Indirect {
                elided_targets.push(target.clone());
                GraphEdge {
                    target: NodeId::elided(target),
                    kind: EdgeKind::Direct,
                }
            } else {
                GraphEdge {
                    target: NodeId::commit(target),
                    kind: edge.kind.into(),
                }
            }
        })
        .collect();
    let node = GraphNode {
        id: NodeId::commit(node.id.0),
        parents,
        meta: Some(node.meta),
    };
    (node, elided_targets)
}

/// The synthetic "(elided revisions)" row for `target`: one `Direct` edge to the real
/// commit, no metadata.
fn elided_node(target: String) -> GraphNode {
    GraphNode {
        parents: vec![GraphEdge {
            target: NodeId::commit(target.clone()),
            kind: EdgeKind::Direct,
        }],
        id: NodeId::elided(target),
        meta: None,
    }
}

/// Streams the lane-assigned rows of `revset` through `sink`, in `jj log` order.
///
/// Drives [`zanshin_jj::Repo::walk_graph`] (re-resolved to head per call; `prioritize` and
/// `short_prefixes` passed through — see [`zanshin_jj::DEFAULT_GRAPH_PRIORITIZE`] and
/// [`zanshin_jj::DEFAULT_LOG_REVSET`]) through a fresh [`LaneAssigner`], emitting each
/// node's final [`Row`] as it arrives, metadata included. `sink` returning
/// [`ControlFlow::Break`] stops the stream early: no further rows are produced, the
/// assigner's open reservations are legitimately left unchecked, and the result is
/// `Ok(Break)`. When the stream is exhausted, [`LaneAssigner::finish`] runs and the result
/// is `Ok(Continue)`.
///
/// With `synthetic_elided` (the CLI's `ui.log-synthetic-elided-nodes` default) every
/// `Indirect` edge becomes a `Direct` edge into a spliced synthetic row emitted right
/// after its child — see [`splice_elided`]. With it off the output is the pre-4.8 stream:
/// plain `Indirect` edges, no synthetic rows.
///
/// `"none()"` is the canonical "no prioritization" value; an empty/blank `prioritize` is a
/// parse error (the CLI fails on an empty config value too), whereas an EMPTY
/// `short_prefixes` disables prefix disambiguation. Rows already handed to `sink` before an
/// `Err` are not retracted — discard partial output on `Err`.
///
/// # Errors
///
/// - [`LaneStreamError::Revset`] — an expression failed to parse/resolve/evaluate, or
///   jj-lib failed mid-stream.
/// - [`LaneStreamError::Graph`] — the exhausted stream left a dangling non-`Missing` edge
///   (contract violation by the upstream stream).
pub fn stream_lanes(
    repo: &mut zanshin_jj::Repo,
    revset: &str,
    prioritize: &str,
    short_prefixes: &str,
    synthetic_elided: bool,
    sink: impl FnMut(Row) -> ControlFlow<()>,
) -> Result<ControlFlow<()>, LaneStreamError> {
    drive_lanes(
        |visit| repo.walk_graph(revset, prioritize, short_prefixes, visit),
        synthetic_elided,
        sink,
    )
}

/// The visitor a graph walk hands each node to (see [`drive_lanes`]).
type Visit<'a> = &'a mut dyn FnMut(zanshin_jj::GraphNode) -> ControlFlow<()>;

/// Drives the nodes `walk` yields through a fresh [`LaneAssigner`] into `sink`, splicing
/// the synthetic elided rows; `finish()` runs only when `walk` reports an exhausted stream
/// (`Continue`).
///
/// Separated from [`stream_lanes`] so the exhausted-stream `finish()` path is observable with a
/// synthetic walk — a real revset stream never leaves a dangling edge.
fn drive_lanes(
    walk: impl FnOnce(Visit<'_>) -> Result<ControlFlow<()>, zanshin_jj::RevsetError>,
    synthetic_elided: bool,
    mut sink: impl FnMut(Row) -> ControlFlow<()>,
) -> Result<ControlFlow<()>, LaneStreamError> {
    let mut assigner = LaneAssigner::new();
    let flow = walk(&mut |node| {
        let (node, elided_targets) = splice_elided(node, synthetic_elided);
        sink(assigner.push(node))?;
        // One synthetic row per collected target, right after its child — duplicates are
        // NOT deduped (the CLI does not dedup either).
        for target in elided_targets {
            sink(assigner.push(elided_node(target)))?;
        }
        ControlFlow::Continue(())
    })?;
    if flow.is_continue() {
        assigner.finish()?;
    }
    Ok(flow)
}

#[cfg(test)]
mod tests {
    use std::ops::ControlFlow;

    use super::{
        drive_lanes, elided_node, splice_elided, EdgeKind, GraphEdge, GraphError, GraphNode, LaneStreamError, NodeId,
        Visit,
    };

    /// A metadata payload with every field at its neutral value — the pass-through is
    /// opaque to this crate, so the values never matter here, only that they survive.
    fn meta(change_id: &str) -> zanshin_jj::CommitMeta {
        zanshin_jj::CommitMeta {
            change_id: change_id.to_string(),
            change_id_prefix_len: 1,
            commit_id_prefix_len: 1,
            change_offset: None,
            author_name: String::new(),
            author_email: String::new(),
            committer_timestamp: zanshin_jj::Timestamp {
                millis_since_epoch: 0,
                tz_offset_minutes: 0,
            },
            bookmarks: vec![],
            tags: vec![],
            working_copies: vec![],
            working_copy: false,
            immutable: false,
            conflict: false,
            empty: false,
            hidden: false,
            divergent: false,
            root: false,
            description_first_line: String::new(),
        }
    }

    fn upstream_node(id: &str, parents: &[(&str, zanshin_jj::GraphEdgeKind)]) -> zanshin_jj::GraphNode {
        zanshin_jj::GraphNode {
            id: zanshin_jj::CommitId(id.to_string()),
            parents: parents
                .iter()
                .map(|(target, kind)| zanshin_jj::GraphEdge {
                    target: zanshin_jj::CommitId((*target).to_string()),
                    kind: *kind,
                })
                .collect(),
            meta: meta(id),
        }
    }

    #[test]
    fn drive_lanes_reports_a_dangling_edge_when_the_exhausted_stream_never_delivered_the_target() {
        fn walk(visit: Visit<'_>) -> ControlFlow<()> {
            let flow = visit(upstream_node(
                "child",
                &[("never-arrives", zanshin_jj::GraphEdgeKind::Direct)],
            ));
            assert_eq!(flow, ControlFlow::Continue(()), "the sink did not break");
            ControlFlow::Continue(())
        }

        let mut rows = 0usize;
        let result = drive_lanes(
            |visit| Ok(walk(visit)),
            true,
            |_row| {
                rows += 1;
                ControlFlow::Continue(())
            },
        );

        assert_eq!(rows, 1, "the row is emitted before finish() runs");
        assert!(
            matches!(
                result,
                Err(LaneStreamError::Graph(GraphError::DanglingEdge { ref target })) if target == "never-arrives"
            ),
            "an exhausted stream with an open Direct reservation must fail finish(), got: {result:?}"
        );
    }

    /// A `Break` on the CHILD row must not emit the synthetic rows queued behind it.
    #[test]
    fn drive_lanes_break_on_the_child_row_skips_its_spliced_elided_rows() {
        fn walk(visit: Visit<'_>) -> ControlFlow<()> {
            visit(upstream_node("child", &[("gone", zanshin_jj::GraphEdgeKind::Indirect)]))
        }

        let mut rows = Vec::new();
        let result = drive_lanes(
            |visit| Ok(walk(visit)),
            true,
            |row| {
                rows.push(row.commit_id);
                ControlFlow::Break(())
            },
        );

        assert!(matches!(result, Ok(ControlFlow::Break(()))), "got: {result:?}");
        assert_eq!(rows, vec!["child".to_string()], "the synthetic row is not emitted");
    }

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
    fn splice_elided_off_keeps_indirect_edges_and_collects_nothing() {
        let upstream = upstream_node(
            "child",
            &[
                ("p1", zanshin_jj::GraphEdgeKind::Missing),
                ("p2", zanshin_jj::GraphEdgeKind::Indirect),
            ],
        );

        let (node, targets) = splice_elided(upstream, false);

        assert!(targets.is_empty(), "nothing is spliced with the toggle off");
        assert_eq!(
            node,
            GraphNode {
                id: NodeId::commit("child"),
                parents: vec![
                    GraphEdge {
                        target: NodeId::commit("p1"),
                        kind: EdgeKind::Missing,
                    },
                    GraphEdge {
                        target: NodeId::commit("p2"),
                        kind: EdgeKind::Indirect,
                    },
                ],
                meta: Some(meta("child")),
            }
        );
    }

    #[test]
    fn splice_elided_on_rewrites_indirect_to_direct_and_collects_the_target_in_edge_order() {
        let upstream = upstream_node(
            "child",
            &[
                ("e1", zanshin_jj::GraphEdgeKind::Indirect),
                ("p", zanshin_jj::GraphEdgeKind::Missing),
                ("e2", zanshin_jj::GraphEdgeKind::Indirect),
            ],
        );

        let (node, targets) = splice_elided(upstream, true);

        assert_eq!(targets, vec!["e1".to_string(), "e2".to_string()], "edge order");
        assert_eq!(
            node.parents,
            vec![
                GraphEdge {
                    target: NodeId::elided("e1"),
                    kind: EdgeKind::Direct,
                },
                GraphEdge {
                    target: NodeId::commit("p"),
                    kind: EdgeKind::Missing,
                },
                GraphEdge {
                    target: NodeId::elided("e2"),
                    kind: EdgeKind::Direct,
                },
            ]
        );
    }

    #[test]
    fn splice_elided_with_no_parents_is_a_root_and_keeps_its_metadata() {
        let (node, targets) = splice_elided(upstream_node("root", &[]), true);

        assert!(targets.is_empty());
        assert_eq!(
            node,
            GraphNode {
                id: NodeId::commit("root"),
                parents: vec![],
                meta: Some(meta("root")),
            }
        );
    }

    #[test]
    fn elided_node_links_the_synthetic_identity_to_the_real_commit_without_metadata() {
        assert_eq!(
            elided_node("target".to_string()),
            GraphNode {
                id: NodeId::elided("target"),
                parents: vec![GraphEdge {
                    target: NodeId::commit("target"),
                    kind: EdgeKind::Direct,
                }],
                meta: None,
            }
        );
    }
}
