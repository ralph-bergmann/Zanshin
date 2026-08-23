// SPDX-License-Identifier: MIT

//! Return-all-lanes-for-revset API (Story 4.4): the revset-selected slice of the commit
//! graph, collected in one call — the source of the FFI `GraphSlice` wire payload.
//!
//! There is no windowing (`start`/`count`/`limit`/`reversed`): the WIP rework of this story
//! dropped pagination, and ADR-0002 AC-4 leaves no materialized cache to slice. A future page
//! composes as an early-exit sink on [`stream_lanes`] (O(prefix)), never as a scan over held rows.

use std::ops::ControlFlow;

use crate::{stream_lanes, LaneStreamError, Row};

/// Collects every lane-assigned [`Row`] of `revset`, in `jj log` order.
///
/// A collecting wrapper over [`stream_lanes`]: the graph is re-derived from the head operation
/// on every call and nothing is retained between calls. `revset` and `prioritize` are caller
/// pass-throughs (see [`zanshin_jj::DEFAULT_GRAPH_PRIORITIZE`] for the CLI-default pre-fill;
/// `"none()"` is the canonical "no prioritization" value). The stream is always exhausted, so
/// [`crate::LaneAssigner::finish`] has run on the returned rows; the FFI `GraphSlice`'s
/// `total_rows` equals `len()` by construction.
///
/// # Errors
///
/// - [`LaneStreamError::Revset`] — either expression failed to parse/resolve/evaluate, or
///   jj-lib failed mid-stream. No rows are returned alongside the error.
/// - [`LaneStreamError::Graph`] — the exhausted stream left a dangling non-`Missing` edge
///   (contract violation by the upstream stream).
pub fn collect_lanes(repo: &zanshin_jj::Repo, revset: &str, prioritize: &str) -> Result<Vec<Row>, LaneStreamError> {
    let mut rows = Vec::new();
    // The sink never breaks, so the stream is always exhausted (finish() ran).
    let _exhausted = stream_lanes(repo, revset, prioritize, |row| {
        rows.push(row);
        ControlFlow::Continue(())
    })?;
    Ok(rows)
}
