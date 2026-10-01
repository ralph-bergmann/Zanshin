#![forbid(unsafe_code)]
// Index-addressed loops over flat arrays are the SPEC §8.3 data layout, kept 1:1 with Dart.
#![allow(clippy::needless_range_loop)]

//! `graph-layout` — the Rust side of the graph-layout A/B spike (`docs/graph-layout.md`).
//!
//! Maps a revset-induced commit DAG (as jj's graph iterator yields it: children before
//! parents, typed Direct / Indirect / Missing edges) onto an abstract grid: per node
//! `(row, lane, col)`, per layout edge `(route, blocked)`, per time bucket a row range (`time`,
//! and `free`'s day buckets since the 2026-10-01 amendment).
//! Integers only, no pixels, no jj-lib dependency — the zanshin-graph shape, so the
//! winner can move into the product almost verbatim.
//!
//! The pipeline is split into the benchmark phases of SPEC §8 so `bench` can time them:
//! [`layout::prep`] + [`layout::layering`] (phase "layering"), [`layout::lanes`],
//! [`layout::blocked`], [`layout::routing`], [`order::ordering`]. [`layout::layout`] runs
//! them all; [`output`] writes the canonical JSON (SPEC §3) and the bench digest (§8.4).
//!
//! Data layout follows SPEC §8.3: flat index-addressed arrays, CSR adjacency, no per-node
//! heap objects or maps on the hot paths, single-threaded.

#[cfg(test)]
mod checks;
pub mod input;
pub mod layout;
pub mod order;
pub mod output;

pub use input::{parse_input, Input, Kind};
pub use layout::{layout, Bucket, BucketKind, Layout, Mode, Order, Route};
