// SPDX-License-Identifier: MIT

//! Graph-slice `FlatBuffers` payload builder (Story 4.2) and the `zanshin_graph_slice`
//! FFI wrapper (Story 4.6).
//!
//! [`graph_slice_to_envelope`] serialises the lane rows Story 4.1 emits
//! (`zanshin_graph::Row`) into a `FlatBuffers` `Envelope` carrying a `GraphSlice`
//! payload — the wire form the Dart side decodes through its generated typed
//! accessors (ADR-0001). Since Story 4.8 each commit row also carries its `jj log`-parity
//! metadata (`GraphRowMeta`) and its pass-through lanes (`GraphActiveLane`), so a log view
//! renders from ONE call. [`zanshin_graph_slice`] borrows the `RepoSession`, passes the
//! caller's `revset` + `prioritize` + `short_prefixes` + `synthetic_elided` through to
//! `zanshin_graph::collect_lanes` (re-derived from head on every call, nothing retained —
//! ADR-0002) and returns that envelope.

use std::ffi::c_char;

use flatbuffers::{FlatBufferBuilder, WIPOffset};
use tracing::debug;
use zanshin_graph::{collect_lanes, EdgeKind, GraphError, LaneStreamError, Row};
use zanshin_jj::{CommitMeta, CommitRef, ConfigError, RevsetError};

use crate::envelope::{
    catch, session_from_handle, FfiErrorObj, GRAPH_DANGLING_EDGE, JJ_CONFIG_ERROR, JJ_JJ_LIB_ERROR,
    JJ_REVSET_PARSE_ERROR, JJ_REVSET_RESOLUTION_ERROR,
};
use crate::fbs;
use crate::ffi_strings::{cstr_to_string, vec_into_token, ZanshinBuf};

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
        LaneStreamError::Revset(RevsetError::Config(ConfigError::Load { reason })) => FfiErrorObj {
            code: JJ_CONFIG_ERROR.to_owned(),
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

/// Build the `[GraphCommitRef]` vector for one row's bookmarks or tags.
fn refs_offset<'a>(
    b: &mut FlatBufferBuilder<'a>,
    refs: &[CommitRef],
) -> WIPOffset<flatbuffers::Vector<'a, flatbuffers::ForwardsUOffset<fbs::GraphCommitRef<'a>>>> {
    let mut offs = Vec::with_capacity(refs.len());
    for r in refs {
        let name = b.create_string(&r.name);
        // `remote` stays absent for the local entry (null-for-absence in Dart).
        let remote = r.remote.as_deref().map(|s| b.create_string(s));
        offs.push(fbs::GraphCommitRef::create(
            b,
            &fbs::GraphCommitRefArgs {
                name: Some(name),
                remote,
                synced: r.synced,
                conflicted: r.conflicted,
            },
        ));
    }
    b.create_vector(&offs)
}

/// Build one `GraphRowMeta` table; its child strings and vectors are created first.
fn meta_offset<'a>(b: &mut FlatBufferBuilder<'a>, meta: &CommitMeta) -> WIPOffset<fbs::GraphRowMeta<'a>> {
    let bookmarks = refs_offset(b, &meta.bookmarks);
    let tags = refs_offset(b, &meta.tags);
    let wc_offs: Vec<_> = meta.working_copies.iter().map(|n| b.create_string(n)).collect();
    let working_copies = b.create_vector(&wc_offs);
    let change_id = b.create_string(&meta.change_id);
    let author_name = b.create_string(&meta.author_name);
    let author_email = b.create_string(&meta.author_email);
    let description_first_line = b.create_string(&meta.description_first_line);
    fbs::GraphRowMeta::create(
        b,
        &fbs::GraphRowMetaArgs {
            change_id: Some(change_id),
            change_id_prefix_len: meta.change_id_prefix_len,
            commit_id_prefix_len: meta.commit_id_prefix_len,
            // Presence pair — the wire has no optional scalar for Dart.
            change_offset: meta.change_offset.unwrap_or(0),
            has_change_offset: meta.change_offset.is_some(),
            author_name: Some(author_name),
            author_email: Some(author_email),
            committer_timestamp_millis: meta.committer_timestamp.millis_since_epoch,
            committer_tz_offset_minutes: meta.committer_timestamp.tz_offset_minutes,
            bookmarks: Some(bookmarks),
            tags: Some(tags),
            working_copies: Some(working_copies),
            working_copy: meta.working_copy,
            immutable: meta.immutable,
            conflict: meta.conflict,
            empty: meta.empty,
            hidden: meta.hidden,
            divergent: meta.divergent,
            root: meta.root,
            description_first_line: Some(description_first_line),
        },
    )
}

/// Build one `GraphRow` table; its edge/active-lane/meta tables and strings are created
/// first (children before parents).
fn row_offset<'a>(b: &mut FlatBufferBuilder<'a>, row: &Row) -> WIPOffset<fbs::GraphRow<'a>> {
    debug_assert_eq!(
        row.meta.is_none(),
        row.synthetic_elided,
        "wire contract: GraphRow.meta is absent IFF the row is a synthetic elided row"
    );
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
    let lane_offs: Vec<_> = row
        .active_lanes
        .iter()
        .map(|l| {
            fbs::GraphActiveLane::create(
                b,
                &fbs::GraphActiveLaneArgs {
                    lane: l.lane,
                    kind: edge_kind(l.kind),
                },
            )
        })
        .collect();
    let active_lanes = b.create_vector(&lane_offs);
    // Absent on a synthetic elided row — the nested table is what makes Dart see `null`.
    let meta = row.meta.as_ref().map(|m| meta_offset(b, m));
    let commit_id = b.create_string(&row.commit_id);
    fbs::GraphRow::create(
        b,
        &fbs::GraphRowArgs {
            commit_id: Some(commit_id),
            lane: row.lane,
            color_idx: row.color_idx,
            edges: Some(edges),
            active_lanes: Some(active_lanes),
            synthetic_elided: row.synthetic_elided,
            meta,
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
/// `jj log` order — the revset-selected slice of the commit graph, each commit row
/// carrying the `jj log` display metadata of the same head-resolved snapshot.
///
/// Every expression is a caller pass-through (FR-JJ-17): `revset` selects the rows,
/// `prioritize` is the branch-prioritisation revset (`jj log`'s
/// `revsets.log-graph-prioritize`; CLI default `present(@)`, `none()` = no prioritisation;
/// a blank expression is a parse error), and `short_prefixes` is the disambiguation set
/// for the shortest-prefix lengths (CLI default = `revsets.log`; an EMPTY string DISABLES
/// disambiguation and falls back to full-index prefixes — the CLI's toggle semantic,
/// deliberately unlike `prioritize`). `synthetic_elided` (the CLI's
/// `ui.log-synthetic-elided-nodes`, default `true`) turns each elided-ancestor edge into a
/// spliced synthetic row; `false` restores plain `Indirect` edges. The graph is re-derived
/// from the head operation on every call and nothing is retained Rust-side (ADR-0002) — an
/// operation performed by another process between two calls is visible in the second.
/// There is no windowing: `total_rows == rows.len()`.
///
/// Returns a `FlatBuffers` `Envelope` carrying a `GraphSlice` payload on success.
///
/// # Errors
/// - `ffi.invalid_handle` — `handle` is `0` (null) or the borrow yields `None`.
/// - `ffi.null_pointer` — `revset`, `prioritize`, or `short_prefixes` is a null pointer.
/// - `ffi.utf8_error` — `revset`, `prioritize`, or `short_prefixes` is not valid UTF-8.
/// - `jj.revset_parse_error` — an expression is syntactically invalid or names an
///   unknown function; jj-lib's reason in `context`.
/// - `jj.revset_resolution_error` — an expression names a symbol that cannot be
///   resolved (unknown bookmark/tag, missing `@`, ambiguous id); reason in `context`.
/// - `jj.jj_lib_error` — a jj-lib evaluation/backend failure; detail in `context`.
/// - `jj.config_error` — the repo's effective jj config, which the revset aliases are
///   resolved against, is unreadable, not valid TOML, has a malformed `config-id`, or holds
///   a wrong-typed value; the file path or config key in `context`. A single bad
///   `[revset-aliases]` entry does NOT produce this — it warns and is skipped.
/// - `graph.dangling_edge` — the revset graph stream violated its contract (a dangling
///   non-`Missing` edge after the stream was exhausted); the target id in `context`.
///
/// # Safety
/// `handle` must be a value returned by a successful `zanshin_repo_open`,
/// `zanshin_repo_init`, `zanshin_repo_clone`, or `zanshin_repo_convert` that has not
/// been closed. `0` is detected and returned as `ffi.invalid_handle`. A stale non-zero
/// handle is undefined behaviour; the Dart worker's Model-A handle table (Story 3.9)
/// makes a stale handle unreachable.
/// `revset`, `prioritize`, and `short_prefixes` must be NUL-terminated UTF-8 C strings
/// owned by the caller (Dart allocates them via `toNativeUtf8()` and frees them with
/// `calloc.free()` after this call returns — AR-P-5 inbound rule). Rust only borrows them
/// for the duration of the call; they are never freed on the Rust side.
/// The returned token must be freed exactly once via `zanshin_buffer_free_token`.
#[no_mangle]
pub unsafe extern "C" fn zanshin_graph_slice(
    handle: u64,
    revset: *const c_char,
    prioritize: *const c_char,
    synthetic_elided: bool,
    short_prefixes: *const c_char,
) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_graph_slice", handle);
    let buf = catch(|| {
        // SAFETY: see `session_from_handle`.
        let session = unsafe { session_from_handle(handle) }?;
        // SAFETY: all three are caller-owned NUL-terminated C strings (Dart allocates + frees).
        let revset = unsafe { cstr_to_string(revset) }?; // null → ffi.null_pointer; bad utf8 → ffi.utf8_error
        let prioritize = unsafe { cstr_to_string(prioritize) }?;
        let short_prefixes = unsafe { cstr_to_string(short_prefixes) }?;
        let rows = collect_lanes(&session.repo, &revset, &prioritize, &short_prefixes, synthetic_elided)
            .map_err(map_lane_stream_err)?;
        Ok(graph_slice_to_envelope(&rows))
    });
    vec_into_token(buf)
}

// ── Tests ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use flatbuffers::root as fb_root;
    use zanshin_graph::{
        assign_lanes, ActiveLane, EdgeKind, GraphEdge, GraphError, GraphNode, LaneStreamError, NodeId, Row, RowEdge,
    };
    use zanshin_jj::{CommitMeta, CommitRef, ConfigError, RevsetError, Timestamp};

    use super::{edge_kind, graph_slice_to_envelope, map_lane_stream_err};
    use crate::envelope::{
        GRAPH_DANGLING_EDGE, JJ_CONFIG_ERROR, JJ_JJ_LIB_ERROR, JJ_REVSET_PARSE_ERROR, JJ_REVSET_RESOLUTION_ERROR,
    };
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
            synthetic_elided: false,
            active_lanes: vec![],
            meta: Some(full_meta()),
        }
    }

    /// A fully-populated `CommitMeta` — every field distinct so a cross-wired slot in the
    /// builder or the reader is visible in the round-trip.
    fn full_meta() -> CommitMeta {
        CommitMeta {
            change_id: "qpvuntsm".to_owned(),
            change_id_prefix_len: 2,
            commit_id_prefix_len: 3,
            change_offset: Some(7),
            author_name: "Ada Lovelace".to_owned(),
            author_email: "ada@example.com".to_owned(),
            committer_timestamp: Timestamp {
                millis_since_epoch: 1_700_000_000_123,
                tz_offset_minutes: -420,
            },
            bookmarks: vec![
                CommitRef {
                    name: "feature".to_owned(),
                    remote: None,
                    synced: false,
                    conflicted: true,
                },
                CommitRef {
                    name: "feature".to_owned(),
                    remote: Some("origin".to_owned()),
                    synced: false,
                    conflicted: false,
                },
            ],
            tags: vec![CommitRef {
                name: "v1.0".to_owned(),
                remote: None,
                synced: true,
                conflicted: false,
            }],
            working_copies: vec!["default".to_owned(), "second".to_owned()],
            working_copy: true,
            immutable: false,
            conflict: true,
            empty: false,
            hidden: true,
            divergent: false,
            root: true,
            description_first_line: "first line".to_owned(),
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

    /// Map one wire `GraphCommitRef` back to the domain type.
    fn ref_from_wire(r: fbs::GraphCommitRef<'_>) -> CommitRef {
        CommitRef {
            name: r.name().expect("name must be present").to_owned(),
            remote: r.remote().map(ToOwned::to_owned),
            synced: r.synced(),
            conflicted: r.conflicted(),
        }
    }

    /// Map one wire `GraphRowMeta` back to the domain type (`has_change_offset` restores
    /// the `Option`).
    fn meta_from_wire(m: fbs::GraphRowMeta<'_>) -> CommitMeta {
        CommitMeta {
            change_id: m.change_id().expect("change_id must be present").to_owned(),
            change_id_prefix_len: m.change_id_prefix_len(),
            commit_id_prefix_len: m.commit_id_prefix_len(),
            change_offset: m.has_change_offset().then(|| m.change_offset()),
            author_name: m.author_name().expect("author_name must be present").to_owned(),
            author_email: m.author_email().expect("author_email must be present").to_owned(),
            committer_timestamp: Timestamp {
                millis_since_epoch: m.committer_timestamp_millis(),
                tz_offset_minutes: m.committer_tz_offset_minutes(),
            },
            bookmarks: m
                .bookmarks()
                .expect("bookmarks must be present")
                .iter()
                .map(ref_from_wire)
                .collect(),
            tags: m
                .tags()
                .expect("tags must be present")
                .iter()
                .map(ref_from_wire)
                .collect(),
            working_copies: m
                .working_copies()
                .expect("working_copies must be present")
                .iter()
                .map(ToOwned::to_owned)
                .collect(),
            working_copy: m.working_copy(),
            immutable: m.immutable(),
            conflict: m.conflict(),
            empty: m.empty(),
            hidden: m.hidden(),
            divergent: m.divergent(),
            root: m.root(),
            description_first_line: m
                .description_first_line()
                .expect("description_first_line must be present")
                .to_owned(),
        }
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
                synthetic_elided: r.synthetic_elided(),
                active_lanes: r
                    .active_lanes()
                    .expect("active_lanes must be present")
                    .iter()
                    .map(|l| ActiveLane {
                        lane: l.lane(),
                        kind: kind_from_wire(l.kind()),
                    })
                    .collect(),
                meta: r.meta().map(meta_from_wire),
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
                id: NodeId::commit("merge"),
                parents: vec![
                    GraphEdge {
                        target: NodeId::commit("a"),
                        kind: EdgeKind::Direct,
                    },
                    GraphEdge {
                        target: NodeId::commit("b"),
                        kind: EdgeKind::Indirect,
                    },
                ],
                meta: Some(full_meta()),
            },
            GraphNode {
                id: NodeId::commit("b"),
                parents: vec![GraphEdge {
                    target: NodeId::commit("outside"),
                    kind: EdgeKind::Missing,
                }],
                meta: Some(full_meta()),
            },
            GraphNode {
                id: NodeId::commit("a"),
                parents: vec![],
                meta: Some(full_meta()),
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
            synthetic_elided: false,
            active_lanes: vec![],
            meta: Some(full_meta()),
        }];
        let buf = graph_slice_to_envelope(&rows);

        let slice = verified_slice(&buf);
        let wire_row = slice.rows().expect("rows").get(0);
        assert_eq!(wire_row.lane(), 9, "lane must land in the lane slot");
        assert_eq!(wire_row.color_idx(), 1, "color_idx must land in the color_idx slot");
        assert_eq!(rows_from_wire(slice), rows);
    }

    // ── Story 4.8: metadata, active lanes, elided rows ────────────────────────

    /// Every catalogued metadata field survives the round-trip in its own slot.
    #[test]
    fn graph_row_meta_roundtrips_every_field() {
        let rows = vec![Row {
            meta: Some(full_meta()),
            ..row("c", 0, vec![])
        }];
        let buf = graph_slice_to_envelope(&rows);

        let slice = verified_slice(&buf);
        assert_eq!(rows_from_wire(slice), rows);
    }

    /// `change_offset` rides a presence pair (flatc 25.12.19 has no optional scalar for
    /// Dart), so `None` must come back as `None` and never as the `0` placeholder.
    #[test]
    fn absent_change_offset_is_written_as_zero_with_the_presence_flag_clear() {
        let rows = vec![Row {
            meta: Some(CommitMeta {
                change_offset: None,
                ..full_meta()
            }),
            ..row("c", 0, vec![])
        }];
        let buf = graph_slice_to_envelope(&rows);

        let slice = verified_slice(&buf);
        let wire_meta = slice.rows().expect("rows").get(0).meta().expect("meta");
        assert_eq!(wire_meta.change_offset(), 0, "the placeholder is 0");
        assert!(!wire_meta.has_change_offset(), "the presence flag must be clear");
        assert_eq!(
            rows_from_wire(slice)[0].meta.as_ref().and_then(|m| m.change_offset),
            None
        );
    }

    /// A synthetic elided row carries no metadata: the nested table must be ABSENT so
    /// Dart decodes `null` (a flat scalar could not express that).
    #[test]
    fn a_synthetic_elided_row_writes_no_meta_table() {
        let rows = vec![Row {
            synthetic_elided: true,
            meta: None,
            ..row(
                "elided-target",
                1,
                vec![edge("elided-target", Some(1), EdgeKind::Direct)],
            )
        }];
        let buf = graph_slice_to_envelope(&rows);

        let slice = verified_slice(&buf);
        let wire_row = slice.rows().expect("rows").get(0);
        assert!(wire_row.synthetic_elided(), "the elided flag must be set");
        assert!(wire_row.meta().is_none(), "meta must be absent on an elided row");
        assert_eq!(rows_from_wire(slice), rows);
    }

    #[test]
    fn active_lanes_roundtrip_in_order_with_their_kinds() {
        let rows = vec![Row {
            active_lanes: vec![
                ActiveLane {
                    lane: 1,
                    kind: EdgeKind::Indirect,
                },
                ActiveLane {
                    lane: 4,
                    kind: EdgeKind::Direct,
                },
            ],
            ..row("c", 0, vec![])
        }];
        let buf = graph_slice_to_envelope(&rows);

        let slice = verified_slice(&buf);
        let wire_lanes = slice.rows().expect("rows").get(0).active_lanes().expect("active_lanes");
        assert_eq!(wire_lanes.len(), 2);
        assert_eq!(wire_lanes.get(0).lane(), 1);
        assert_eq!(wire_lanes.get(0).kind(), fbs::GraphEdgeKind::Indirect);
        assert_eq!(rows_from_wire(slice), rows);
    }

    /// The local entry has no remote: `remote` must stay absent (null-for-absence), never
    /// become an empty string.
    #[test]
    fn a_local_commit_ref_writes_no_remote_string() {
        let rows = vec![Row {
            meta: Some(CommitMeta {
                bookmarks: vec![CommitRef {
                    name: "feature".to_owned(),
                    remote: None,
                    synced: true,
                    conflicted: false,
                }],
                ..full_meta()
            }),
            ..row("c", 0, vec![])
        }];
        let buf = graph_slice_to_envelope(&rows);

        let slice = verified_slice(&buf);
        let wire_ref = slice
            .rows()
            .expect("rows")
            .get(0)
            .meta()
            .expect("meta")
            .bookmarks()
            .expect("bookmarks")
            .get(0);
        assert_eq!(wire_ref.name(), Some("feature"));
        assert_eq!(wire_ref.remote(), None, "a local entry has no remote");
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

        let config = map_lane_stream_err(LaneStreamError::Revset(RevsetError::Config(ConfigError::Load {
            reason: "/r/.jj/repo/config.toml: bad TOML".to_owned(),
        })));
        assert_eq!(config.code, JJ_CONFIG_ERROR);
        assert_eq!(config.context.as_deref(), Some("/r/.jj/repo/config.toml: bad TOML"));

        let dangling = map_lane_stream_err(LaneStreamError::Graph(GraphError::DanglingEdge {
            target: "deadbeef".to_owned(),
        }));
        assert_eq!(dangling.code, GRAPH_DANGLING_EDGE);
        assert_eq!(dangling.context.as_deref(), Some("deadbeef"));
    }
}
