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
    /// The parent commit's id.
    pub target: String,
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
    /// Hex commit id (`zanshin_jj::CommitId.0` upstream).
    pub id: String,
    /// Parent edges in upstream stream order. Upstream that is parent order,
    /// but NOT one edge per parent: an elided parent contributes zero, one, or
    /// several [`EdgeKind::Indirect`] edges after jj-lib's ancestor dedup and
    /// transitive-edge removal. The first non-[`EdgeKind::Missing`] edge is the
    /// continuation edge (see [`LaneAssigner::push`]).
    pub parents: Vec<GraphEdge>,
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
    /// The commit id this row represents (same as the input [`GraphNode::id`]).
    pub commit_id: String,
    /// The lane this commit was placed on.
    pub lane: u32,
    /// Deterministic palette color index, `lane % PALETTE_SIZE`.
    pub color_idx: u32,
    /// One [`RowEdge`] per input parent edge, in the same order.
    pub edges: Vec<RowEdge>,
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
    /// Lane slots, indexed by lane number. `Some(id)` = a pending reservation
    /// for `id` occupies this lane (an edge is running down it toward `id`);
    /// `None` = free. Slots are cleared, never removed — removing would shift
    /// every following lane index and invalidate already-emitted rows.
    lanes: Vec<Option<String>>,
    /// Commit id -> lanes reserved for it, kept sorted ascending so "leftmost"
    /// is O(1). An id can hold more than one reservation at once (multiple
    /// children each reserving a different lane for the same not-yet-arrived
    /// parent); all but the leftmost are freed when that parent is placed.
    reservations: HashMap<String, Vec<u32>>,
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
    pub fn push(&mut self, node: GraphNode) -> Row {
        let lane = self.place(&node.id);
        let mut edges = Vec::with_capacity(node.parents.len());
        let mut own_lane_unclaimed = true;
        for edge in node.parents {
            let continues_own_lane = own_lane_unclaimed && edge.kind != EdgeKind::Missing;
            if continues_own_lane {
                own_lane_unclaimed = false;
            }
            let target_lane = self.route_edge(lane, continues_own_lane, &edge);
            edges.push(RowEdge {
                target: edge.target,
                target_lane,
                kind: edge.kind,
            });
        }
        Row {
            commit_id: node.id,
            lane,
            color_idx: lane % PALETTE_SIZE,
            edges,
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
        if let Some(target) = self.lanes.into_iter().flatten().next() {
            return Err(GraphError::DanglingEdge { target });
        }
        Ok(())
    }

    /// Places `id`: takes its leftmost reservation (freeing every other
    /// reservation held for `id`), or the leftmost free lane, or a new lane.
    fn place(&mut self, id: &str) -> u32 {
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
        self.reserve(edge.target.clone(), lane);
        Some(lane)
    }

    /// Returns the target's leftmost already-reserved lane, if any.
    fn leftmost_reservation(&self, target: &str) -> Option<u32> {
        self.reservations.get(target).and_then(|lanes| lanes.first().copied())
    }

    /// Marks `lane` reserved for `target`: occupies the lane slot and records
    /// the reservation (idempotent — reserving an already-held lane again is
    /// a no-op on the reservation list, keeping it duplicate-free).
    fn reserve(&mut self, target: String, lane: u32) {
        self.lanes[Self::index(lane)] = Some(target.clone());
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
    use super::{EdgeKind, GraphEdge, LaneAssigner};

    fn direct(target: &str) -> GraphEdge {
        GraphEdge {
            target: target.to_string(),
            kind: EdgeKind::Direct,
        }
    }

    #[test]
    fn alloc_lane_reuses_leftmost_free_slot() {
        let mut assigner = LaneAssigner::new();
        assigner.lanes = vec![None, Some("x".to_string()), None];
        assert_eq!(assigner.alloc_lane(), 0);
    }

    #[test]
    fn alloc_lane_appends_when_no_free_slot() {
        let mut assigner = LaneAssigner::new();
        assigner.lanes = vec![Some("a".to_string()), Some("b".to_string())];
        assert_eq!(assigner.alloc_lane(), 2);
        assert_eq!(assigner.lanes.len(), 3);
    }

    #[test]
    fn reserve_then_leftmost_reservation_returns_smallest() {
        let mut assigner = LaneAssigner::new();
        assigner.lanes = vec![None, None, None];
        assigner.reserve("p".to_string(), 2);
        assigner.reserve("p".to_string(), 0);
        assert_eq!(assigner.leftmost_reservation("p"), Some(0));
        assert_eq!(assigner.reservations.get("p"), Some(&vec![0, 2]));
    }

    #[test]
    fn reserve_is_idempotent_for_the_same_lane() {
        let mut assigner = LaneAssigner::new();
        assigner.lanes = vec![None];
        assigner.reserve("p".to_string(), 0);
        assigner.reserve("p".to_string(), 0);
        assert_eq!(assigner.reservations.get("p"), Some(&vec![0]));
    }

    #[test]
    fn place_frees_every_reservation_held_for_the_arriving_id() {
        let mut assigner = LaneAssigner::new();
        assigner.lanes = vec![None, None, None];
        assigner.reserve("p".to_string(), 1);
        assigner.reserve("p".to_string(), 2);
        let lane = assigner.place("p");
        assert_eq!(lane, 1);
        assert_eq!(assigner.lanes, vec![None, None, None]);
        assert!(!assigner.reservations.contains_key("p"));
    }

    #[test]
    fn place_with_no_reservation_allocates_a_lane() {
        let mut assigner = LaneAssigner::new();
        assert_eq!(assigner.place("root"), 0);
    }

    #[test]
    fn route_edge_missing_never_reserves() {
        let mut assigner = LaneAssigner::new();
        assigner.lanes = vec![None];
        let edge = GraphEdge {
            target: "gone".to_string(),
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
        assigner.reserve("shared".to_string(), 0);
        let target_lane = assigner.route_edge(1, true, &direct("shared"));
        assert_eq!(target_lane, Some(1));
        assert_eq!(assigner.reservations.get("shared"), Some(&vec![0, 1]));
    }
}
