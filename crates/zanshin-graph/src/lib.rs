// SPDX-License-Identifier: MIT

#![deny(missing_docs)]

//! `zanshin-graph` — streaming lane assignment for the commit graph (FR-GR-1).
//!
//! Implements a single-pass "straight branches" (pvigier-style) lane-assignment
//! algorithm over a topologically-ordered stream of [`GraphNode`]s, assigning each
//! node a stable lane, a deterministic palette color index, and per-parent edge
//! routing — one final [`Row`] emitted per node, in input order, with no full-graph
//! buffering. The input shape mirrors jj-lib's `TopoGroupedGraph` revset-graph stream
//! (ADR-0002: the graph is derived lazily on every `op_heads` change, never held as a
//! materialized cache); see [`GraphNode`] for the input contract this algorithm relies
//! on. This crate has no `jj_lib` dependency — `zanshin-jj` is the sole importer
//! (FR-JJ-16); [`stream_lanes`] maps `zanshin_jj::Repo::walk_graph`'s stream into these
//! types and drives it through the assigner on demand (Story 4.3: this crate depends on
//! `zanshin-jj`, never the reverse). [`collect_lanes`] is the one-call return-all API over
//! that stream (Story 4.4; windowing is deferred past WIP).
//!
//! Since Story 4.8 a [`Row`] is self-contained renderable: it carries the lanes passing
//! THROUGH it ([`ActiveLane`]), the synthetic-elided-row flag, and the `jj log`-parity
//! display metadata the upstream stream extracted. That metadata is an **opaque
//! pass-through** — a `zanshin_jj::CommitMeta` this crate moves from node to row and never
//! inspects, so the lane algorithm stays a pure, `jj_lib`-free function of the topology.

mod lane;
mod slice;
mod stream;

pub use lane::{
    assign_lanes, ActiveLane, EdgeKind, GraphEdge, GraphError, GraphNode, LaneAssigner, NodeId, Row, RowEdge,
    PALETTE_SIZE,
};
pub use slice::collect_lanes;
pub use stream::{stream_lanes, LaneStreamError};
