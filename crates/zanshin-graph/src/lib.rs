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
//! (FR-JJ-16); mapping the real stream into these types is downstream work
//! (Story 4.3 decides where that mapping lives).

mod lane;

pub use lane::{assign_lanes, EdgeKind, GraphEdge, GraphError, GraphNode, LaneAssigner, Row, RowEdge, PALETTE_SIZE};
