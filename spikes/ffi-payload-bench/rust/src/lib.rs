// SPDX-License-Identifier: Apache-2.0
//
// JSON-vs-FlatBuffers payload spike (Rust producer side).
//
// We generate one synthetic model per size, then serialize the SAME model two
// ways (serde_json and FlatBuffers) so the comparison is apples-to-apples.
// The producer direction mirrors the real FFI hot path: Rust builds, Dart reads.

#![allow(clippy::missing_panics_doc)] // WHY: spike binary/bench, not a published API

/// FlatBuffers accessors generated from `schema/payload.fbs` by `build.rs`.
#[allow(warnings)] // WHY: machine-generated; not subject to our lint bar
pub(crate) mod generated {
    include!(concat!(env!("OUT_DIR"), "/payload_generated.rs"));
}

pub mod flat;
pub mod json;
pub mod model;

pub use flat::{to_fb_diff, to_fb_graph};
pub use json::{to_json_diff, to_json_graph};
pub use model::{gen_diff, gen_graph, Diff, GraphSlice};

/// Graph slice sizes (node counts) swept by the bench and the artifact writer.
pub const GRAPH_SIZES: &[usize] = &[1_000, 10_000, 50_000];

/// Diff sizes (file counts) swept by the bench and the artifact writer.
/// Each file expands to ~3 hunks * ~16 lines, so 2_000 files ≈ 100k lines.
pub const DIFF_SIZES: &[usize] = &[50, 500, 2_000];
