// SPDX-License-Identifier: MIT

//! Graph-slice `FlatBuffers` payload builder (Story 4.2).
//!
//! Serialises the lane rows Story 4.1 emits (`zanshin_graph::Row`) into a
//! `FlatBuffers` `Envelope` carrying a `GraphSlice` payload — the wire form the
//! Dart side decodes through its generated typed accessors (ADR-0001). No
//! `extern "C"` fn lives here yet: Story 4.6 adds the `zanshin_graph_*` wrappers
//! that call [`graph_slice_to_envelope`].

use flatbuffers::{FlatBufferBuilder, WIPOffset};
use zanshin_graph::{EdgeKind, Row};

use crate::fbs;

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
/// rows.len()` (WIP return-all semantics; Story 4.4 windowing may decouple
/// it). A `RowEdge::target_lane` of `None` (iff `Missing`) is written as `0`;
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

#[cfg(test)]
mod tests {
    use flatbuffers::root as fb_root;
    use zanshin_graph::{assign_lanes, EdgeKind, GraphEdge, GraphNode, Row, RowEdge};

    use super::{edge_kind, graph_slice_to_envelope};
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
    fn edge_kind_maps_every_variant_in_order() {
        assert_eq!(edge_kind(EdgeKind::Direct), fbs::GraphEdgeKind::Direct);
        assert_eq!(edge_kind(EdgeKind::Indirect), fbs::GraphEdgeKind::Indirect);
        assert_eq!(edge_kind(EdgeKind::Missing), fbs::GraphEdgeKind::Missing);
    }
}
