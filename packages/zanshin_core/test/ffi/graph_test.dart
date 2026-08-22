// SPDX-License-Identifier: MIT

// Decode-contract tests for [decodeGraphSliceEnvelope] using synthetic
// FlatBuffers buffers built via the generated `*ObjectBuilder`s. No real cdylib
// required — these tests exercise the Dart-side decode logic in isolation and
// mirror the Rust round-trip in crates/zanshin-ffi/src/graph.rs (AR-P-7 parity).
//
// Mirrors packages/zanshin_core/test/ffi/change_test.dart.

import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zanshin_core/src/ffi/envelope_zanshin.ffi_generated.dart' as fbs;
import 'package:zanshin_core/src/ffi/graph.dart';
import 'package:zanshin_core/src/worker/responses.dart';

/// The fork-then-merge shape from the spec's I/O matrix: a merge row with a
/// Direct + an Indirect edge, a row with a Missing edge (Rust writes
/// targetLane 0), and a root with no edges.
List<fbs.GraphRowObjectBuilder> _forkThenMergeRows() => [
  fbs.GraphRowObjectBuilder(
    commitId: 'mérge-✓ id',
    lane: 0,
    colorIdx: 0,
    edges: [
      fbs.GraphRowEdgeObjectBuilder(target: 'a', targetLane: 0, kind: fbs.GraphEdgeKind.Direct),
      fbs.GraphRowEdgeObjectBuilder(target: 'b', targetLane: 1, kind: fbs.GraphEdgeKind.Indirect),
    ],
  ),
  fbs.GraphRowObjectBuilder(
    commitId: 'b',
    lane: 1,
    colorIdx: 1,
    edges: [
      fbs.GraphRowEdgeObjectBuilder(target: 'outside', targetLane: 0, kind: fbs.GraphEdgeKind.Missing),
    ],
  ),
  fbs.GraphRowObjectBuilder(commitId: 'a', lane: 0, colorIdx: 0, edges: const []),
];

void main() {
  group('decodeGraphSliceEnvelope decode contract', () {
    // ── Error envelope ────────────────────────────────────────────────────────

    test('throws ZanshinFfiException on error envelope', () {
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: false,
        error: fbs.FfiErrorObjectBuilder(code: 'ffi.invalid_handle', context: 'handle 0'),
      ).toBytes();

      expect(
        () => decodeGraphSliceEnvelope(bytes),
        throwsA(
          isA<ZanshinFfiException>()
              .having((e) => e.code, 'code', 'ffi.invalid_handle')
              .having((e) => e.context, 'context', 'handle 0'),
        ),
      );
    });

    // ── Wrong payload type ────────────────────────────────────────────────────

    test('throws ffi.unknown on ok envelope with non-GraphSlice payload', () {
      // ok == true but union variant is RepoHandle, not GraphSlice: the
      // discriminant guard must surface ZanshinFfiException('ffi.unknown').
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.RepoHandle,
        data: fbs.RepoHandleObjectBuilder(handle: 0),
      ).toBytes();

      expect(
        () => decodeGraphSliceEnvelope(bytes),
        throwsA(
          isA<ZanshinFfiException>().having((e) => e.code, 'code', 'ffi.unknown'),
        ),
      );
    });

    // ── Full round-trip field equality ────────────────────────────────────────

    test('decodes fork-then-merge rows; targetLane null iff kind == missing', () {
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.GraphSlice,
        data: fbs.GraphSliceObjectBuilder(rows: _forkThenMergeRows(), totalRows: 3),
      ).toBytes();

      final GraphSlice slice = decodeGraphSliceEnvelope(bytes);

      expect(slice.totalRows, equals(3));
      expect(slice.rows.length, equals(3));

      // Merge row: Direct + Indirect edges, both with a lane.
      final GraphRow merge = slice.rows[0];
      expect(merge.commitId, equals('mérge-✓ id'), reason: 'strings cross verbatim');
      expect(merge.lane, equals(0));
      expect(merge.colorIdx, equals(0));
      expect(merge.edges.length, equals(2));
      expect(merge.edges[0].target, equals('a'));
      expect(merge.edges[0].targetLane, equals(0));
      expect(merge.edges[0].kind, equals(GraphEdgeKind.direct));
      expect(merge.edges[1].target, equals('b'));
      expect(merge.edges[1].targetLane, equals(1));
      expect(merge.edges[1].kind, equals(GraphEdgeKind.indirect));

      // Missing edge: the wire 0 placeholder must surface as null.
      final GraphRow sideline = slice.rows[1];
      expect(sideline.commitId, equals('b'));
      expect(sideline.lane, equals(1));
      expect(sideline.colorIdx, equals(1));
      expect(sideline.edges.length, equals(1));
      expect(sideline.edges[0].target, equals('outside'));
      expect(sideline.edges[0].targetLane, isNull, reason: 'Missing ⇒ targetLane null');
      expect(sideline.edges[0].kind, equals(GraphEdgeKind.missing));

      // Root: no edges.
      final GraphRow root = slice.rows[2];
      expect(root.commitId, equals('a'));
      expect(root.lane, equals(0));
      expect(root.edges, isEmpty);
    });

    test('decodes every GraphEdgeKind variant', () {
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.GraphSlice,
        data: fbs.GraphSliceObjectBuilder(
          rows: [
            fbs.GraphRowObjectBuilder(
              commitId: 'x',
              lane: 2,
              colorIdx: 2,
              edges: [
                fbs.GraphRowEdgeObjectBuilder(target: 'd', targetLane: 2, kind: fbs.GraphEdgeKind.Direct),
                fbs.GraphRowEdgeObjectBuilder(target: 'i', targetLane: 3, kind: fbs.GraphEdgeKind.Indirect),
                fbs.GraphRowEdgeObjectBuilder(target: 'm', targetLane: 0, kind: fbs.GraphEdgeKind.Missing),
              ],
            ),
          ],
          totalRows: 1,
        ),
      ).toBytes();

      final GraphSlice slice = decodeGraphSliceEnvelope(bytes);

      expect(
        slice.rows.single.edges.map((e) => e.kind).toList(),
        equals([GraphEdgeKind.direct, GraphEdgeKind.indirect, GraphEdgeKind.missing]),
      );
      expect(
        slice.rows.single.edges.map((e) => e.targetLane).toList(),
        equals([2, 3, null]),
      );
    });

    test('decodes lane and colorIdx into distinct fields', () {
      // Every other fixture has lane == colorIdx (lanes < PALETTE_SIZE), which
      // could not tell a lane/colorIdx cross-wire apart; a lane past the palette
      // wraps its color and pins the two fields independently.
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.GraphSlice,
        data: fbs.GraphSliceObjectBuilder(
          rows: [fbs.GraphRowObjectBuilder(commitId: 'far', lane: 9, colorIdx: 1, edges: const [])],
          totalRows: 1,
        ),
      ).toBytes();

      final GraphRow row = decodeGraphSliceEnvelope(bytes).rows.single;

      expect(row.lane, equals(9));
      expect(row.colorIdx, equals(1));
    });

    // ── Empty slice ───────────────────────────────────────────────────────────

    test('decodes empty GraphSlice', () {
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.GraphSlice,
        data: fbs.GraphSliceObjectBuilder(rows: const [], totalRows: 0),
      ).toBytes();

      final GraphSlice slice = decodeGraphSliceEnvelope(bytes);

      expect(slice.rows, isEmpty);
      expect(slice.totalRows, equals(0));
    });
  });
}
