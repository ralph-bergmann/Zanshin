// SPDX-License-Identifier: MIT

//! Graph-slice `FlatBuffers` payload builder (Story 4.2) and the `zanshin_graph_slice`
//! FFI wrapper (Story 4.6).
//!
//! [`graph_slice_to_envelope`] serialises the lane rows Story 4.1 emits
//! (`zanshin_graph::Row`) into a `FlatBuffers` `Envelope` carrying a `GraphSlice`
//! payload — the wire form the Dart side decodes through its generated typed
//! accessors (ADR-0001). [`zanshin_graph_slice`] borrows the `RepoSession`, passes the
//! caller's `revset` + `prioritize` through to `zanshin_graph::collect_lanes` (re-derived
//! from head on every call, nothing retained — ADR-0002) and returns that envelope.

use std::ffi::c_char;

use flatbuffers::{FlatBufferBuilder, WIPOffset};
use tracing::debug;
use zanshin_graph::{collect_lanes, EdgeKind, GraphError, LaneStreamError, Row};
use zanshin_jj::RevsetError;

use crate::envelope::{
    catch, FfiErrorObj, FFI_INVALID_HANDLE, GRAPH_DANGLING_EDGE, JJ_JJ_LIB_ERROR, JJ_REVSET_PARSE_ERROR,
    JJ_REVSET_RESOLUTION_ERROR,
};
use crate::fbs;
use crate::ffi_strings::{cstr_to_string, vec_into_token, ZanshinBuf};
use crate::handle::handle_from_raw;
use crate::repo::RepoSession;

// ── Error mapping ─────────────────────────────────────────────────────────────

fn map_lane_stream_err(e: LaneStreamError) -> FfiErrorObj {
    match e {
        LaneStreamError::Revset(RevsetError::ParseError { reason }) => FfiErrorObj {
            code: JJ_REVSET_PARSE_ERROR.to_owned(),
            context: Some(reason),
        },
        LaneStreamError::Revset(RevsetError::ResolutionError { reason }) => FfiErrorObj {
            code: JJ_REVSET_RESOLUTION_ERROR.to_owned(),
            context: Some(reason),
        },
        LaneStreamError::Revset(RevsetError::JjLibError(reason)) => FfiErrorObj {
            code: JJ_JJ_LIB_ERROR.to_owned(),
            context: Some(reason),
        },
        LaneStreamError::Graph(GraphError::DanglingEdge { target }) => FfiErrorObj {
            code: GRAPH_DANGLING_EDGE.to_owned(),
            context: Some(target),
        },
    }
}

// ── Row → FlatBuffers builder ─────────────────────────────────────────────────

/// Map `zanshin_graph::EdgeKind` onto the wire enum (order-identical by contract).
fn edge_kind(kind: EdgeKind) -> fbs::GraphEdgeKind {
    match kind {
        EdgeKind::Direct => fbs::GraphEdgeKind::Direct,
        EdgeKind::Indirect => fbs::GraphEdgeKind::Indirect,
        EdgeKind::Missing => fbs::GraphEdgeKind::Missing,
    }
}

/// Build one `GraphRow` table; its edge tables and strings are created first
/// (children before parents).
fn row_offset<'a>(b: &mut FlatBufferBuilder<'a>, row: &Row) -> WIPOffset<fbs::GraphRow<'a>> {
    let mut edge_offs = Vec::with_capacity(row.edges.len());
    for e in &row.edges {
        let target = b.create_string(&e.target);
        edge_offs.push(fbs::GraphRowEdge::create(
            b,
            &fbs::GraphRowEdgeArgs {
                target: Some(target),
                // `None` iff `Missing` (4.1 contract); the wire has no optional scalar for
                // Dart, so presence rides on `kind` and 0 is a placeholder the reader ignores.
                target_lane: e.target_lane.unwrap_or(0),
                kind: edge_kind(e.kind),
            },
        ));
    }
    let edges = b.create_vector(&edge_offs);
    let commit_id = b.create_string(&row.commit_id);
    fbs::GraphRow::create(
        b,
        &fbs::GraphRowArgs {
            commit_id: Some(commit_id),
            lane: row.lane,
            color_idx: row.color_idx,
            edges: Some(edges),
        },
    )
}

/// Serialise `&[Row]` into a finished `Envelope<GraphSlice>` buffer.
///
/// Infallible: every `Row` is representable, so the envelope is always `ok`.
/// `rows` are written in input (stream / `jj log`) order — one `GraphRow` per
/// `Row`, one `GraphRowEdge` per `RowEdge`, same order. `total_rows ==
/// rows.len()` (Story 4.4 delivered return-all; windowing is deferred past
/// WIP and may decouple it later). A `RowEdge::target_lane` of `None` (iff
/// `Missing`) is written as `0`;
/// the Dart model restores `null` from `kind`.
#[must_use]
pub fn graph_slice_to_envelope(rows: &[Row]) -> Vec<u8> {
    let mut b = FlatBufferBuilder::with_capacity(1024);
    let row_offs: Vec<_> = rows.iter().map(|r| row_offset(&mut b, r)).collect();
    let rows_vec = b.create_vector(&row_offs);
    let slice = fbs::GraphSlice::create(
        &mut b,
        &fbs::GraphSliceArgs {
            rows: Some(rows_vec),
            // A slice of more than u32::MAX rows cannot exist; clamp instead of an `as` truncation.
            total_rows: u32::try_from(rows.len()).unwrap_or(u32::MAX),
        },
    );
    let envelope = fbs::Envelope::create(
        &mut b,
        &fbs::EnvelopeArgs {
            ok: true,
            error: None,
            data_type: fbs::Payload::GraphSlice,
            data: Some(slice.as_union_value()),
        },
    );
    b.finish(envelope, None);
    b.finished_data().to_vec()
}

// ── extern "C" ────────────────────────────────────────────────────────────────

/// Return every lane-assigned row of `revset` in the repo referenced by `handle`, in
/// `jj log` order — the revset-selected slice of the commit graph.
///
/// Both expressions are caller pass-throughs (FR-JJ-17): `revset` selects the rows,
/// `prioritize` is the branch-prioritisation revset (`jj log`'s
/// `revsets.log-graph-prioritize`; CLI default `present(@)`, `none()` = no prioritisation;
/// a blank expression is a parse error). The graph is re-derived from the head operation
/// on every call and nothing is retained Rust-side (ADR-0002) — an operation performed by
/// another process between two calls is visible in the second. There is no windowing:
/// `total_rows == rows.len()`.
///
/// Returns a `FlatBuffers` `Envelope` carrying a `GraphSlice` payload on success.
///
/// # Errors
/// - `ffi.invalid_handle` — `handle` is `0` (null) or the borrow yields `None`.
/// - `ffi.null_pointer` — `revset` or `prioritize` is a null pointer.
/// - `ffi.utf8_error` — `revset` or `prioritize` is not valid UTF-8.
/// - `jj.revset_parse_error` — either expression is syntactically invalid or names an
///   unknown function; jj-lib's reason in `context`.
/// - `jj.revset_resolution_error` — either expression names a symbol that cannot be
///   resolved (unknown bookmark/tag, missing `@`, ambiguous id); reason in `context`.
/// - `jj.jj_lib_error` — a jj-lib evaluation/backend failure; detail in `context`.
/// - `graph.dangling_edge` — the revset graph stream violated its contract (a dangling
///   non-`Missing` edge after the stream was exhausted); the target id in `context`.
///
/// # Safety
/// `handle` must be a value returned by a successful `zanshin_repo_open`,
/// `zanshin_repo_init`, `zanshin_repo_clone`, or `zanshin_repo_convert` that has not
/// been closed. `0` is detected and returned as `ffi.invalid_handle`. A stale non-zero
/// handle is undefined behaviour; the Dart worker's Model-A handle table (Story 3.9)
/// makes a stale handle unreachable.
/// `revset` and `prioritize` must be NUL-terminated UTF-8 C strings owned by the caller
/// (Dart allocates them via `toNativeUtf8()` and frees them with `calloc.free()` after
/// this call returns — AR-P-5 inbound rule). Rust only borrows them for the duration of
/// the call; they are never freed on the Rust side.
/// The returned token must be freed exactly once via `zanshin_buffer_free_token`.
#[no_mangle]
pub unsafe extern "C" fn zanshin_graph_slice(
    handle: u64,
    revset: *const c_char,
    prioritize: *const c_char,
) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_graph_slice", handle);
    let buf = catch(|| {
        // SAFETY: non-zero handle originated from arm_session's handle_into_raw
        // (Box<RepoSession>) in zanshin_repo_open/init/clone/convert; single-isolate
        // model (AD-2) guarantees no concurrent access.
        let session =
            unsafe { handle_from_raw::<RepoSession>(handle as *mut RepoSession) }.ok_or_else(|| FfiErrorObj {
                code: FFI_INVALID_HANDLE.to_owned(),
                context: None,
            })?;
        // SAFETY: both are caller-owned NUL-terminated C strings (Dart allocates + frees).
        let revset = unsafe { cstr_to_string(revset) }?; // null → ffi.null_pointer; bad utf8 → ffi.utf8_error
        let prioritize = unsafe { cstr_to_string(prioritize) }?;
        let rows = collect_lanes(&session.repo, &revset, &prioritize).map_err(map_lane_stream_err)?;
        Ok(graph_slice_to_envelope(&rows))
    });
    vec_into_token(buf)
}

// ── Tests ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use flatbuffers::root as fb_root;
    use zanshin_graph::{assign_lanes, EdgeKind, GraphEdge, GraphError, GraphNode, LaneStreamError, Row, RowEdge};
    use zanshin_jj::RevsetError;

    use super::{edge_kind, graph_slice_to_envelope, map_lane_stream_err};
    use crate::envelope::{GRAPH_DANGLING_EDGE, JJ_JJ_LIB_ERROR, JJ_REVSET_PARSE_ERROR, JJ_REVSET_RESOLUTION_ERROR};
    use crate::fbs;

    fn edge(target: &str, target_lane: Option<u32>, kind: EdgeKind) -> RowEdge {
        RowEdge {
            target: target.to_owned(),
            target_lane,
            kind,
        }
    }

    fn row(commit_id: &str, lane: u32, edges: Vec<RowEdge>) -> Row {
        Row {
            commit_id: commit_id.to_owned(),
            lane,
            color_idx: lane % zanshin_graph::PALETTE_SIZE,
            edges,
        }
    }

    /// Fork-then-merge shape from the spec's I/O matrix: a merge row with a
    /// `Direct` + an `Indirect` edge, a row with a `Missing` edge, a root.
    fn fork_then_merge_rows() -> Vec<Row> {
        vec![
            row(
                "m\u{e9}rge-\u{2713} id",
                0,
                vec![
                    edge("a", Some(0), EdgeKind::Direct),
                    edge("b", Some(1), EdgeKind::Indirect),
                ],
            ),
            row("b", 1, vec![edge("outside", None, EdgeKind::Missing)]),
            row("a", 0, vec![]),
        ]
    }

    fn kind_from_wire(kind: fbs::GraphEdgeKind) -> EdgeKind {
        match kind {
            fbs::GraphEdgeKind::Direct => EdgeKind::Direct,
            fbs::GraphEdgeKind::Indirect => EdgeKind::Indirect,
            fbs::GraphEdgeKind::Missing => EdgeKind::Missing,
            other => panic!("unexpected wire GraphEdgeKind {other:?}"),
        }
    }

    /// Verify the buffer and read the `GraphSlice` payload back through the typed accessors.
    fn verified_slice(buf: &[u8]) -> fbs::GraphSlice<'_> {
        let env = fb_root::<fbs::Envelope>(buf).expect("FlatBuffers Verifier must pass");
        assert!(env.ok(), "envelope must be ok");
        assert_eq!(
            env.data_type(),
            fbs::Payload::GraphSlice,
            "data_type must be GraphSlice"
        );
        env.data_as_graph_slice().expect("data_as_graph_slice must succeed")
    }

    /// Map the wire payload back to the 4.1 domain type (`Missing` ⇒ `target_lane: None`).
    fn rows_from_wire(slice: fbs::GraphSlice<'_>) -> Vec<Row> {
        slice
            .rows()
            .expect("rows must be present")
            .iter()
            .map(|r| Row {
                commit_id: r.commit_id().expect("commit_id must be present").to_owned(),
                lane: r.lane(),
                color_idx: r.color_idx(),
                edges: r
                    .edges()
                    .expect("edges must be present")
                    .iter()
                    .map(|e| {
                        let kind = kind_from_wire(e.kind());
                        RowEdge {
                            target: e.target().expect("target must be present").to_owned(),
                            target_lane: (kind != EdgeKind::Missing).then_some(e.target_lane()),
                            kind,
                        }
                    })
                    .collect(),
            })
            .collect()
    }

    #[test]
    fn graph_slice_roundtrips_fork_then_merge_rows_verbatim() {
        let rows = fork_then_merge_rows();
        let buf = graph_slice_to_envelope(&rows);

        let slice = verified_slice(&buf);
        assert_eq!(slice.total_rows(), 3, "total_rows must equal the input length");
        assert_eq!(slice.rows().map(|v| v.len()), Some(3), "one GraphRow per input Row");
        assert_eq!(
            rows_from_wire(slice),
            rows,
            "wire payload must map back to the input rows"
        );
    }

    #[test]
    fn graph_slice_roundtrips_rows_produced_by_assign_lanes() {
        // The same shape, but driven through the real 4.1 producer so the builder is
        // proven against rows `assign_lanes` actually emits (AC-2).
        let nodes = vec![
            GraphNode {
                id: "merge".into(),
                parents: vec![
                    GraphEdge {
                        target: "a".into(),
                        kind: EdgeKind::Direct,
                    },
                    GraphEdge {
                        target: "b".into(),
                        kind: EdgeKind::Indirect,
                    },
                ],
            },
            GraphNode {
                id: "b".into(),
                parents: vec![GraphEdge {
                    target: "outside".into(),
                    kind: EdgeKind::Missing,
                }],
            },
            GraphNode {
                id: "a".into(),
                parents: vec![],
            },
        ];
        let rows = assign_lanes(nodes).expect("contract-conforming input must assign");
        assert!(
            rows.iter().any(|r| r.edges.iter().any(|e| e.kind == EdgeKind::Missing)),
            "fixture must exercise the Missing (target_lane: None) path"
        );

        let buf = graph_slice_to_envelope(&rows);

        let slice = verified_slice(&buf);
        assert_eq!(usize::try_from(slice.total_rows()).ok(), Some(rows.len()));
        assert_eq!(rows_from_wire(slice), rows);
    }

    #[test]
    fn empty_slice_has_present_empty_rows_and_zero_total() {
        let buf = graph_slice_to_envelope(&[]);

        let slice = verified_slice(&buf);
        assert_eq!(slice.rows().map(|v| v.len()), Some(0), "rows must be present and empty");
        assert_eq!(slice.total_rows(), 0, "total_rows must be 0");
    }

    #[test]
    fn missing_edge_is_written_as_target_lane_zero_with_kind_missing() {
        let rows = vec![row("x", 0, vec![edge("outside", None, EdgeKind::Missing)])];
        let buf = graph_slice_to_envelope(&rows);

        let slice = verified_slice(&buf);
        let wire_edge = slice.rows().expect("rows").get(0).edges().expect("edges").get(0);
        assert_eq!(wire_edge.target(), Some("outside"));
        assert_eq!(wire_edge.target_lane(), 0, "Missing edge must carry the 0 placeholder");
        assert_eq!(wire_edge.kind(), fbs::GraphEdgeKind::Missing);
    }

    #[test]
    fn lane_and_color_idx_are_written_to_distinct_slots() {
        // Every other fixture has `lane == color_idx` (lanes < PALETTE_SIZE), which
        // could not tell a lane/color_idx cross-wire apart; a lane past the palette
        // wraps its color and pins the two slots independently.
        let rows = vec![Row {
            commit_id: "far".to_owned(),
            lane: 9,
            color_idx: 1,
            edges: vec![],
        }];
        let buf = graph_slice_to_envelope(&rows);

        let slice = verified_slice(&buf);
        let wire_row = slice.rows().expect("rows").get(0);
        assert_eq!(wire_row.lane(), 9, "lane must land in the lane slot");
        assert_eq!(wire_row.color_idx(), 1, "color_idx must land in the color_idx slot");
        assert_eq!(rows_from_wire(slice), rows);
    }

    #[test]
    fn edge_kind_maps_every_variant_in_order() {
        assert_eq!(edge_kind(EdgeKind::Direct), fbs::GraphEdgeKind::Direct);
        assert_eq!(edge_kind(EdgeKind::Indirect), fbs::GraphEdgeKind::Indirect);
        assert_eq!(edge_kind(EdgeKind::Missing), fbs::GraphEdgeKind::Missing);
    }

    /// Every `LaneStreamError` variant lands on its registry code with the reason/target
    /// as `context`. `graph.dangling_edge` is unreachable with real fixtures (the jj-lib
    /// stream never dangles), so this is the only place that arm is pinned.
    #[test]
    fn map_lane_stream_err_maps_every_variant() {
        let parse = map_lane_stream_err(LaneStreamError::Revset(RevsetError::ParseError {
            reason: "bad syntax".to_owned(),
        }));
        assert_eq!(parse.code, JJ_REVSET_PARSE_ERROR);
        assert_eq!(parse.context.as_deref(), Some("bad syntax"));

        let resolution = map_lane_stream_err(LaneStreamError::Revset(RevsetError::ResolutionError {
            reason: "no such bookmark".to_owned(),
        }));
        assert_eq!(resolution.code, JJ_REVSET_RESOLUTION_ERROR);
        assert_eq!(resolution.context.as_deref(), Some("no such bookmark"));

        let jj_lib = map_lane_stream_err(LaneStreamError::Revset(RevsetError::JjLibError("boom".to_owned())));
        assert_eq!(jj_lib.code, JJ_JJ_LIB_ERROR);
        assert_eq!(jj_lib.context.as_deref(), Some("boom"));

        let dangling = map_lane_stream_err(LaneStreamError::Graph(GraphError::DanglingEdge {
            target: "deadbeef".to_owned(),
        }));
        assert_eq!(dangling.code, GRAPH_DANGLING_EDGE);
        assert_eq!(dangling.context.as_deref(), Some("deadbeef"));
    }
}
