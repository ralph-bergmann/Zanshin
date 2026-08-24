// SPDX-License-Identifier: MIT

//! The streaming "straight branches" (pvigier-style) lane-assignment algorithm.
//!
//! Reference: pvigier, *Drawing Commit Graphs*
//! (<https://pvigier.github.io/2019/05/06/commit-graph-drawing-algorithms.html>),
//! the strategy GUI commit-graph renderers such as gitamine use.
//! Adapted here to single-pass streaming: no look-ahead, no `J(c)` forbidden-lane
//! refinement (a look-ahead-dependent visual-crossing optimization that conflicts
//! with streaming and is deferred until real UI feedback asks for it).
//!
//! See [`GraphNode`] for the input contract and [`LaneAssigner::push`] for the
//! placement/routing rules.

use std::collections::HashMap;

use zanshin_jj::CommitMeta;

/// Identity of a node in the lane graph: a commit id plus whether this is the
/// synthetic "elided revisions" row standing in for that commit.
///
/// Mirrors the CLI's `(CommitId, bool)` renderdag key
/// (`cli/src/commands/log.rs:245-329`): a synthetic row must be able to reserve
/// and consume its own lane without colliding with the real commit that arrives
/// later. Namespacing the flag into the id string instead would leak into
/// [`Row::commit_id`] and [`GraphError::DanglingEdge`].
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct NodeId {
    /// Hex commit id (`zanshin_jj::CommitId.0` upstream).
    pub commit_id: String,
    /// `true` for the synthetic elided row standing in front of `commit_id`.
    pub synthetic: bool,
}

impl NodeId {
    /// The real commit's identity.
    #[must_use]
    pub fn commit(commit_id: impl Into<String>) -> Self {
        Self {
            commit_id: commit_id.into(),
            synthetic: false,
        }
    }

    /// The synthetic elided row standing in front of `commit_id`.
    #[must_use]
    pub fn elided(commit_id: impl Into<String>) -> Self {
        Self {
            commit_id: commit_id.into(),
            synthetic: true,
        }
    }
}

/// One lane passing vertically THROUGH a [`Row`] — it neither starts nor ends at
/// that row's node.
///
/// `kind` is the kind of the edge that opened the segment, so a renderer can
/// style the pass-through (e.g. dash an [`EdgeKind::Indirect`] segment) without
/// looking at any neighbouring row. The color is derivable as
/// `lane % PALETTE_SIZE`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ActiveLane {
    /// The lane the segment occupies.
    pub lane: u32,
    /// The kind of the edge that opened the segment.
    pub kind: EdgeKind,
}

/// How a [`GraphEdge`]'s target was classified by the upstream revset-graph
/// stream.
///
/// [Source: jj-lib 0.42.0 `src/default_index/revset_graph_iterator.rs:38-69`]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EdgeKind {
    /// The parent is in the revset; it WILL arrive later in the stream.
    Direct,
    /// The direct parent was elided from the revset; this edge points at the
    /// closest ancestor that IS in the set, which WILL arrive later. Lane
    /// assignment treats this identically to [`EdgeKind::Direct`]; renderers
    /// may draw it dashed.
    Indirect,
    /// The edge leads outside the revset; its target will NEVER arrive. No
    /// lane is ever reserved for a `Missing` edge.
    Missing,
}

/// One parent edge of a [`GraphNode`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GraphEdge {
    /// The parent's node identity (a real commit, or the synthetic elided row
    /// spliced in front of it).
    pub target: NodeId,
    /// How this edge was classified by the upstream stream.
    pub kind: EdgeKind,
}

/// One node of the input stream: a commit id and its parent edges.
///
/// Mirrors the shape jj-lib's `TopoGroupedGraph` stream yields
/// (`GraphNode<CommitId> = (CommitId, Vec<GraphEdge<CommitId>>)`; see
/// `crates/zanshin-jj/benches/graph_blueprint.rs` for the runnable upstream
/// pipeline — Story 4.3 owns feeding a real stream through these types). This
/// algorithm relies on three contract properties:
///
/// 1. **Topological order, children before parents** — a node's parents
///    always arrive *after* the node itself
///    [Source: jj-lib 0.42.0 `src/graph.rs:120-131`].
/// 2. **No duplicate nodes** — each commit id is emitted exactly once.
/// 3. **Every [`EdgeKind::Direct`] or [`EdgeKind::Indirect`] target eventually
///    arrives**; [`EdgeKind::Missing`] targets never do. Violating this is
///    exactly what [`LaneAssigner::finish`] detects via
///    [`GraphError::DanglingEdge`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GraphNode {
    /// This node's identity (see [`NodeId`]).
    pub id: NodeId,
    /// Parent edges in upstream stream order. Upstream that is parent order,
    /// but NOT one edge per parent: an elided parent contributes zero, one, or
    /// several [`EdgeKind::Indirect`] edges after jj-lib's ancestor dedup and
    /// transitive-edge removal. The first non-[`EdgeKind::Missing`] edge is the
    /// continuation edge (see [`LaneAssigner::push`]).
    pub parents: Vec<GraphEdge>,
    /// `jj log`-parity display metadata, carried verbatim from the upstream
    /// stream onto the [`Row`] this node produces. **Opaque to this crate** —
    /// the lane algorithm never reads it (and could not: `zanshin-graph` has no
    /// `jj_lib` dependency, FR-JJ-16). `None` on a synthetic elided row.
    pub meta: Option<CommitMeta>,
}

/// One parent edge of a [`Row`], carrying the lane it was routed to.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RowEdge {
    /// The parent commit id (same as the input [`GraphEdge::target`]).
    pub target: String,
    /// The lane this edge is routed to, at the child's emit time. `None` if
    /// and only if `kind` is [`EdgeKind::Missing`] — a missing edge never
    /// reserves a lane to land in.
    pub target_lane: Option<u32>,
    /// The edge's kind, carried through unchanged from the input.
    pub kind: EdgeKind,
}

/// The number of distinct colors in the deterministic color palette.
///
/// [`Row::color_idx`] is always `lane % PALETTE_SIZE`.
pub const PALETTE_SIZE: u32 = 8;

/// One output row: a node's assigned lane, color, and routed parent edges.
///
/// Final at emit time: every `target_lane` is knowable when the row is built —
/// first-parent edges target the node's own (just-decided) lane, merge edges
/// target an existing or freshly allocated reservation. No later node can
/// invalidate an already-emitted `Row` (see [`LaneAssigner::push`]).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Row {
    /// The commit id this row represents (the input [`NodeId::commit_id`]). On a
    /// synthetic elided row this is the ELIDED TARGET's commit id.
    pub commit_id: String,
    /// The lane this commit was placed on.
    pub lane: u32,
    /// Deterministic palette color index, `lane % PALETTE_SIZE`.
    pub color_idx: u32,
    /// One [`RowEdge`] per input parent edge, in the same order.
    pub edges: Vec<RowEdge>,
    /// This is a synthetic "(elided revisions)" row, not a real commit
    /// (the input [`NodeId::synthetic`]).
    pub synthetic_elided: bool,
    /// Lanes carrying a vertical segment THROUGH this row — neither starting nor
    /// ending at this row's node — in ascending lane order. Together with
    /// [`Self::lane`] and [`Self::edges`] this is everything a renderer needs to
    /// paint the row's complete graph cross-section without any neighbouring row.
    pub active_lanes: Vec<ActiveLane>,
    /// `jj log`-parity display metadata, opaque to this crate. `None` on a
    /// synthetic elided row.
    pub meta: Option<CommitMeta>,
}

/// Errors from [`LaneAssigner::finish`] / [`assign_lanes`].
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum GraphError {
    /// A non-[`EdgeKind::Missing`] parent edge's target never arrived in the
    /// input stream — the input violated the children-before-parents /
    /// target-in-set contract documented on [`GraphNode`]. The algorithm
    /// itself cannot otherwise fail.
    #[error("dangling edge: target {target} never arrived in the input stream")]
    DanglingEdge {
        /// The commit id a reservation was still open for.
        target: String,
    },
}

/// Incremental "straight branches" lane assigner.
///
/// Push nodes in topological (children-before-parents) order via [`push`];
/// each call returns that node's final [`Row`] without buffering the graph:
/// the work per node is bounded by the number of *currently active* lanes
/// (the leftmost-free scan), never by the number of nodes seen so far, and
/// memory is proportional to active lanes plus open reservations. This is
/// what lets a consumer stream the first render page without materializing
/// the whole graph (ADR-0002).
///
/// Every pushed node yields exactly one row, in push order — nothing is
/// filtered or special-cased here (anonymous changes, working-copy commits,
/// conflicted commits are all just nodes); membership is decided entirely by
/// the upstream revset.
///
/// [`push`]: LaneAssigner::push
#[derive(Debug, Default)]
pub struct LaneAssigner {
    /// Lane slots, indexed by lane number. `Some(reservation)` = an edge is
    /// running down this lane toward a node that has not arrived yet; `None` =
    /// free. Slots are cleared, never removed — removing would shift every
    /// following lane index and invalidate already-emitted rows.
    lanes: Vec<Option<Reservation>>,
    /// Node id -> lanes reserved for it, kept sorted ascending so "leftmost"
    /// is O(1). An id can hold more than one reservation at once (multiple
    /// children each reserving a different lane for the same not-yet-arrived
    /// parent); all but the leftmost are freed when that parent is placed.
    reservations: HashMap<NodeId, Vec<u32>>,
}

/// A lane held open for a node that has not arrived yet.
#[derive(Debug, Clone, PartialEq, Eq)]
struct Reservation {
    /// The node this lane is waiting for.
    target: NodeId,
    /// The kind of the edge that OPENED this segment. A later edge joining the
    /// same lane joins an existing segment; it does not restyle it.
    kind: EdgeKind,
}

impl LaneAssigner {
    /// Creates an assigner with no active lanes or reservations.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Places `node` on a lane, routes its parent edges, and returns its
    /// final row.
    ///
    /// **Placement:** if one or more lanes are reserved for `node.id`, it
    /// takes the leftmost of them and every other reservation for it is freed
    /// at this row (their branches converge here). Otherwise (a head or new
    /// root) it takes the leftmost free lane, or a new one if none is free.
    ///
    /// **Edge routing**, in `node.parents` order: the first non-`Missing`
    /// edge reserves the node's *own* lane for its target — even if that
    /// target already holds a reservation elsewhere — so a first-parent chain
    /// stays in one lane until its fork commit (the "straight" rule). A
    /// `Missing` edge ahead of it does not consume that continuation. Every
    /// other non-`Missing` edge targets its target's existing leftmost
    /// reservation, or a freshly allocated lane if it has none yet. A
    /// `Missing` edge never reserves a lane; its `target_lane` is `None` — if
    /// every edge is `Missing`, the node's lane simply ends here.
    ///
    /// **Pass-through lanes** are read from the live reservation state the
    /// instant after placement and before any edge is routed: at that point
    /// every lane landing at this row has been cleared and the node's own lane
    /// is free in BOTH placement branches, so the still-occupied slots are
    /// exactly the segments crossing this row.
    pub fn push(&mut self, node: GraphNode) -> Row {
        let lane = self.place(&node.id);
        let active_lanes = self.active_lanes();
        let mut edges = Vec::with_capacity(node.parents.len());
        let mut own_lane_unclaimed = true;
        for edge in node.parents {
            let continues_own_lane = own_lane_unclaimed && edge.kind != EdgeKind::Missing;
            if continues_own_lane {
                own_lane_unclaimed = false;
            }
            let target_lane = self.route_edge(lane, continues_own_lane, &edge);
            edges.push(RowEdge {
                target: edge.target.commit_id,
                target_lane,
                kind: edge.kind,
            });
        }
        Row {
            commit_id: node.id.commit_id,
            lane,
            color_idx: lane % PALETTE_SIZE,
            edges,
            synthetic_elided: node.id.synthetic,
            active_lanes,
            meta: node.meta,
        }
    }

    /// Consumes the assigner, checking that every reservation was eventually
    /// consumed by its target arriving.
    ///
    /// # Errors
    ///
    /// Returns [`GraphError::DanglingEdge`] if a non-`Missing` reservation was
    /// never claimed — the input violated the contract documented on
    /// [`GraphNode`]. Which dangling target is reported is unspecified when
    /// more than one remains.
    pub fn finish(self) -> Result<(), GraphError> {
        if let Some(reservation) = self.lanes.into_iter().flatten().next() {
            return Err(GraphError::DanglingEdge {
                target: reservation.target.commit_id,
            });
        }
        Ok(())
    }

    /// Snapshots the currently-occupied lane slots, ascending.
    fn active_lanes(&self) -> Vec<ActiveLane> {
        self.lanes
            .iter()
            .enumerate()
            .filter_map(|(index, slot)| {
                slot.as_ref().map(|reservation| ActiveLane {
                    lane: Self::lane_number(index),
                    kind: reservation.kind,
                })
            })
            .collect()
    }

    /// Places `id`: takes its leftmost reservation (freeing every other
    /// reservation held for `id`), or the leftmost free lane, or a new lane.
    fn place(&mut self, id: &NodeId) -> u32 {
        if let Some(lanes) = self.reservations.remove(id) {
            let placed = lanes[0];
            for lane in lanes {
                self.lanes[Self::index(lane)] = None;
            }
            placed
        } else {
            self.alloc_lane()
        }
    }

    /// Routes one parent edge and returns the lane its target was assigned,
    /// or `None` for a `Missing` edge (which never reserves a lane).
    fn route_edge(&mut self, own_lane: u32, continues_own_lane: bool, edge: &GraphEdge) -> Option<u32> {
        if edge.kind == EdgeKind::Missing {
            return None;
        }
        let lane = if continues_own_lane {
            own_lane
        } else if let Some(existing) = self.leftmost_reservation(&edge.target) {
            existing
        } else {
            self.alloc_lane()
        };
        self.reserve(edge.target.clone(), lane, edge.kind);
        Some(lane)
    }

    /// Returns the target's leftmost already-reserved lane, if any.
    fn leftmost_reservation(&self, target: &NodeId) -> Option<u32> {
        self.reservations.get(target).and_then(|lanes| lanes.first().copied())
    }

    /// Marks `lane` reserved for `target`: occupies the lane slot and records
    /// the reservation (idempotent — reserving an already-held lane again is
    /// a no-op on the reservation list, keeping it duplicate-free).
    ///
    /// The slot's `kind` is written only when the slot was free. A lane is only
    /// ever re-reserved for the target that already holds it (`route_edge`
    /// reuses a lane through [`Self::leftmost_reservation`], and the node's own
    /// lane is always free at that point), so a later edge joining the segment
    /// must not restyle the segment the earlier edge opened.
    fn reserve(&mut self, target: NodeId, lane: u32, kind: EdgeKind) {
        let slot = &mut self.lanes[Self::index(lane)];
        if let Some(held) = slot.as_ref() {
            debug_assert_eq!(
                held.target, target,
                "a lane is only ever re-reserved for the target that already holds it"
            );
        } else {
            *slot = Some(Reservation {
                target: target.clone(),
                kind,
            });
        }
        let lanes = self.reservations.entry(target).or_default();
        if let Err(pos) = lanes.binary_search(&lane) {
            lanes.insert(pos, lane);
        }
    }

    /// Returns the leftmost free lane, growing the lane vector by one if none
    /// is free.
    fn alloc_lane(&mut self) -> u32 {
        if let Some(pos) = self.lanes.iter().position(Option::is_none) {
            Self::lane_number(pos)
        } else {
            self.lanes.push(None);
            Self::lane_number(self.lanes.len() - 1)
        }
    }

    // WHY: these two `expect()`s are FFI-reachable since Story 4.6 (`zanshin_graph_slice` →
    // `collect_lanes` → `push`), and project rules forbid `expect()` on FFI-reachable library
    // paths — kept deliberately (decision recorded in deferred-work, 4.1 review item): both
    // conversions are infallible on the supported 64-bit target (`u32` → `usize` cannot fail;
    // `usize` → `u32` fails only past 4·10⁹ concurrently open lanes, which no graph of
    // addressable size produces), so carrying lanes as `usize` internally would add a
    // conversion at the FFI edge for no reachable failure. `catch_unwind` in `zanshin-ffi`
    // remains the backstop (`internal.panic`) should the impossible ever happen.
    fn index(lane: u32) -> usize {
        usize::try_from(lane).expect("lane number fits in usize on any supported platform")
    }

    fn lane_number(index: usize) -> u32 {
        u32::try_from(index).expect("lane count fits in u32 for any realistic graph size")
    }
}

/// Runs [`LaneAssigner`] over `nodes` and collects every row, in input order.
///
/// # Errors
///
/// Returns [`GraphError::DanglingEdge`] if the input didn't satisfy the
/// contract documented on [`GraphNode`].
pub fn assign_lanes(nodes: impl IntoIterator<Item = GraphNode>) -> Result<Vec<Row>, GraphError> {
    let mut assigner = LaneAssigner::new();
    let rows: Vec<Row> = nodes.into_iter().map(|node| assigner.push(node)).collect();
    assigner.finish()?;
    Ok(rows)
}

#[cfg(test)]
mod tests {
    use super::{ActiveLane, EdgeKind, GraphEdge, GraphNode, LaneAssigner, NodeId, Reservation};

    fn direct(target: &str) -> GraphEdge {
        GraphEdge {
            target: NodeId::commit(target),
            kind: EdgeKind::Direct,
        }
    }

    fn held(target: &str, kind: EdgeKind) -> Reservation {
        Reservation {
            target: NodeId::commit(target),
            kind,
        }
    }

    fn node(id: &str, parents: Vec<GraphEdge>) -> GraphNode {
        GraphNode {
            id: NodeId::commit(id),
            parents,
            meta: None,
        }
    }

    #[test]
    fn alloc_lane_reuses_leftmost_free_slot() {
        let mut assigner = LaneAssigner::new();
        assigner.lanes = vec![None, Some(held("x", EdgeKind::Direct)), None];
        assert_eq!(assigner.alloc_lane(), 0);
    }

    #[test]
    fn alloc_lane_appends_when_no_free_slot() {
        let mut assigner = LaneAssigner::new();
        assigner.lanes = vec![Some(held("a", EdgeKind::Direct)), Some(held("b", EdgeKind::Direct))];
        assert_eq!(assigner.alloc_lane(), 2);
        assert_eq!(assigner.lanes.len(), 3);
    }

    #[test]
    fn reserve_then_leftmost_reservation_returns_smallest() {
        let mut assigner = LaneAssigner::new();
        assigner.lanes = vec![None, None, None];
        assigner.reserve(NodeId::commit("p"), 2, EdgeKind::Direct);
        assigner.reserve(NodeId::commit("p"), 0, EdgeKind::Direct);
        assert_eq!(assigner.leftmost_reservation(&NodeId::commit("p")), Some(0));
        assert_eq!(assigner.reservations.get(&NodeId::commit("p")), Some(&vec![0, 2]));
    }

    #[test]
    fn reserve_is_idempotent_for_the_same_lane() {
        let mut assigner = LaneAssigner::new();
        assigner.lanes = vec![None];
        assigner.reserve(NodeId::commit("p"), 0, EdgeKind::Direct);
        assigner.reserve(NodeId::commit("p"), 0, EdgeKind::Direct);
        assert_eq!(assigner.reservations.get(&NodeId::commit("p")), Some(&vec![0]));
    }

    /// A later edge joining an open segment must not restyle it: the reservation
    /// keeps the kind of the edge that CREATED it.
    #[test]
    fn reserve_keeps_the_kind_of_the_edge_that_opened_the_segment() {
        let mut assigner = LaneAssigner::new();
        assigner.lanes = vec![None];
        assigner.reserve(NodeId::commit("p"), 0, EdgeKind::Indirect);
        assigner.reserve(NodeId::commit("p"), 0, EdgeKind::Direct);
        assert_eq!(assigner.lanes[0], Some(held("p", EdgeKind::Indirect)));
    }

    #[test]
    fn place_frees_every_reservation_held_for_the_arriving_id() {
        let mut assigner = LaneAssigner::new();
        assigner.lanes = vec![None, None, None];
        assigner.reserve(NodeId::commit("p"), 1, EdgeKind::Direct);
        assigner.reserve(NodeId::commit("p"), 2, EdgeKind::Direct);
        let lane = assigner.place(&NodeId::commit("p"));
        assert_eq!(lane, 1);
        assert_eq!(assigner.lanes, vec![None, None, None]);
        assert!(!assigner.reservations.contains_key(&NodeId::commit("p")));
    }

    #[test]
    fn place_with_no_reservation_allocates_a_lane() {
        let mut assigner = LaneAssigner::new();
        assert_eq!(assigner.place(&NodeId::commit("root")), 0);
    }

    /// A synthetic elided row and the real commit it stands for are distinct
    /// identities: the elided row consumes its own reservation and leaves the
    /// real commit's untouched.
    #[test]
    fn an_elided_node_id_does_not_collide_with_its_real_commit() {
        let mut assigner = LaneAssigner::new();
        assigner.lanes = vec![None, None];
        assigner.reserve(NodeId::elided("p"), 0, EdgeKind::Direct);
        assigner.reserve(NodeId::commit("p"), 1, EdgeKind::Direct);
        assert_eq!(assigner.place(&NodeId::elided("p")), 0);
        assert_eq!(
            assigner.lanes[1],
            Some(held("p", EdgeKind::Direct)),
            "the real commit still waits"
        );
    }

    #[test]
    fn route_edge_missing_never_reserves() {
        let mut assigner = LaneAssigner::new();
        assigner.lanes = vec![None];
        let edge = GraphEdge {
            target: NodeId::commit("gone"),
            kind: EdgeKind::Missing,
        };
        let target_lane = assigner.route_edge(0, true, &edge);
        assert_eq!(target_lane, None);
        assert_eq!(assigner.lanes, vec![None]);
        assert!(assigner.reservations.is_empty());
    }

    #[test]
    fn route_edge_first_parent_reserves_own_lane_even_if_target_reserved_elsewhere() {
        let mut assigner = LaneAssigner::new();
        assigner.lanes = vec![None, None];
        assigner.reserve(NodeId::commit("shared"), 0, EdgeKind::Direct);
        let target_lane = assigner.route_edge(1, true, &direct("shared"));
        assert_eq!(target_lane, Some(1));
        assert_eq!(assigner.reservations.get(&NodeId::commit("shared")), Some(&vec![0, 1]));
    }

    /// The pass-through set is read AFTER `place()` and BEFORE the edge loop: the
    /// lane that lands here is already cleared, the node's own lane is still
    /// free, and only the segment crossing the row remains.
    #[test]
    fn push_reads_active_lanes_after_placement_and_before_routing() {
        let mut assigner = LaneAssigner::new();
        // `crosser` opens lane 0 toward `far`; `head` opens lane 1 toward `p`.
        assigner.push(node("crosser", vec![direct("far")]));
        assigner.push(node("head", vec![direct("p")]));

        let row = assigner.push(node("p", vec![direct("q")]));

        assert_eq!(row.lane, 1, "p claims the reservation it was promised");
        assert_eq!(
            row.active_lanes,
            vec![ActiveLane {
                lane: 0,
                kind: EdgeKind::Direct
            }],
            "only the segment crossing this row is listed: not p's own lane 1 \
             (freed by place, re-taken by p's own edge), not the landed edge"
        );
    }

    /// A pass-through carries the kind of the edge that opened it, so a renderer
    /// can dash an elided segment without inspecting any other row.
    #[test]
    fn active_lanes_carry_the_kind_of_the_segment_that_crosses_the_row() {
        let mut assigner = LaneAssigner::new();
        assigner.push(node("crosser", vec![direct("far")]));
        assigner.push(node(
            "eliding",
            vec![GraphEdge {
                target: NodeId::commit("elided-target"),
                kind: EdgeKind::Indirect,
            }],
        ));
        // Swap the crossing segment for the Indirect one by letting `far` land first.
        let row = assigner.push(node("far", vec![]));

        assert_eq!(row.lane, 0);
        assert_eq!(
            row.active_lanes,
            vec![ActiveLane {
                lane: 1,
                kind: EdgeKind::Indirect
            }]
        );
    }
}
