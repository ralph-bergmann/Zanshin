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
    activeLanes: const [],
    syntheticElided: false,
    meta: _fullMeta(),
  ),
  fbs.GraphRowObjectBuilder(
    commitId: 'b',
    lane: 1,
    colorIdx: 1,
    edges: [
      fbs.GraphRowEdgeObjectBuilder(target: 'outside', targetLane: 0, kind: fbs.GraphEdgeKind.Missing),
    ],
    activeLanes: [fbs.GraphActiveLaneObjectBuilder(lane: 0, kind: fbs.GraphEdgeKind.Direct)],
    syntheticElided: false,
    meta: _fullMeta(),
  ),
  fbs.GraphRowObjectBuilder(
    commitId: 'a',
    lane: 0,
    colorIdx: 0,
    edges: const [],
    activeLanes: const [],
    syntheticElided: false,
    meta: _fullMeta(),
  ),
];

/// A fully-populated `GraphRowMeta` — every field distinct so a cross-wired slot
/// is visible in the decode.
fbs.GraphRowMetaObjectBuilder _fullMeta() => fbs.GraphRowMetaObjectBuilder(
  changeId: 'qpvuntsm',
  changeIdPrefixLen: 2,
  commitIdPrefixLen: 3,
  changeOffset: 7,
  hasChangeOffset: true,
  authorName: 'Ada Lovelace',
  authorEmail: 'ada@example.com',
  committerTimestampMillis: 1700000000123,
  committerTzOffsetMinutes: -420,
  bookmarks: [
    fbs.GraphCommitRefObjectBuilder(name: 'feature', synced: false, conflicted: true),
    fbs.GraphCommitRefObjectBuilder(name: 'feature', remote: 'origin', synced: false, conflicted: false),
  ],
  tags: [fbs.GraphCommitRefObjectBuilder(name: 'v1.0', synced: true, conflicted: false)],
  workingCopies: ['default', 'second'],
  workingCopy: true,
  immutable: false,
  conflict: true,
  empty: false,
  hidden: true,
  divergent: false,
  root: true,
  descriptionFirstLine: 'first line',
);

void main() {
  group('graph pre-fills', () {
    test('defaultGraphAnchors is the trunk chain first, then @ (Story 4.10)', () {
      // The editable pre-fill for the topology call's required `anchors`; the
      // order is the priority order 4.11's rule reads.
      expect(defaultGraphAnchors, ['trunk()', 'present(@)']);
    });
  });

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

      // Pass-through lanes ride the row itself (Story 4.8).
      expect(merge.activeLanes, isEmpty);
      expect(sideline.activeLanes, hasLength(1));
      expect(sideline.activeLanes.single.lane, equals(0));
      expect(sideline.activeLanes.single.kind, equals(GraphEdgeKind.direct));
    });

    // ── Story 4.8: metadata, elided rows ──────────────────────────────────

    test('decodes every GraphRowMeta field into its own slot', () {
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.GraphSlice,
        data: fbs.GraphSliceObjectBuilder(rows: _forkThenMergeRows(), totalRows: 3),
      ).toBytes();

      final GraphRowMeta meta = decodeGraphSliceEnvelope(bytes).rows.first.meta!;

      expect(meta.changeId, equals('qpvuntsm'));
      expect(meta.changeIdPrefixLen, equals(2));
      expect(meta.commitIdPrefixLen, equals(3));
      expect(meta.changeOffset, equals(7));
      expect(meta.authorName, equals('Ada Lovelace'));
      expect(meta.authorEmail, equals('ada@example.com'));
      expect(meta.committerTimestampMillis, equals(1700000000123));
      expect(meta.committerTzOffsetMinutes, equals(-420));
      expect(meta.workingCopies, equals(['default', 'second']));
      expect(meta.workingCopy, isTrue);
      expect(meta.immutable, isFalse);
      expect(meta.conflict, isTrue);
      expect(meta.empty, isFalse);
      expect(meta.hidden, isTrue);
      expect(meta.divergent, isFalse);
      expect(meta.root, isTrue);
      expect(meta.descriptionFirstLine, equals('first line'));

      // Refs: the local entry has no remote (null-for-absence), the remote one does.
      expect(meta.bookmarks, hasLength(2));
      expect(meta.bookmarks[0].name, equals('feature'));
      expect(meta.bookmarks[0].remote, isNull, reason: 'local entry ⇒ remote null');
      expect(meta.bookmarks[0].conflicted, isTrue);
      expect(meta.bookmarks[1].remote, equals('origin'));
      expect(meta.bookmarks[1].synced, isFalse);
      expect(meta.tags.single.name, equals('v1.0'));
      expect(meta.tags.single.synced, isTrue);
    });

    test('decodes an absent changeOffset as null via the presence flag', () {
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.GraphSlice,
        data: fbs.GraphSliceObjectBuilder(
          rows: [
            fbs.GraphRowObjectBuilder(
              commitId: 'c',
              lane: 0,
              colorIdx: 0,
              edges: const [],
              activeLanes: const [],
              syntheticElided: false,
              // hasChangeOffset false + the 0 placeholder Rust writes.
              meta: fbs.GraphRowMetaObjectBuilder(changeId: 'c', changeOffset: 0, hasChangeOffset: false),
            ),
          ],
          totalRows: 1,
        ),
      ).toBytes();

      final GraphRowMeta meta = decodeGraphSliceEnvelope(bytes).rows.single.meta!;

      expect(meta.changeOffset, isNull, reason: 'the 0 placeholder must not surface as 0');
    });

    test('decodes a synthetic elided row with a null meta', () {
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.GraphSlice,
        data: fbs.GraphSliceObjectBuilder(
          rows: [
            fbs.GraphRowObjectBuilder(
              commitId: 'elided-target',
              lane: 1,
              colorIdx: 1,
              edges: [
                fbs.GraphRowEdgeObjectBuilder(
                  target: 'elided-target',
                  targetLane: 1,
                  kind: fbs.GraphEdgeKind.Direct,
                ),
              ],
              activeLanes: const [],
              syntheticElided: true,
            ),
          ],
          totalRows: 1,
        ),
      ).toBytes();

      final GraphRow row = decodeGraphSliceEnvelope(bytes).rows.single;

      expect(row.syntheticElided, isTrue);
      expect(row.meta, isNull, reason: 'an elided row carries no metadata');
      expect(row.commitId, equals('elided-target'), reason: 'the elided TARGET id');
      expect(row.edges.single.target, equals('elided-target'));
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
              activeLanes: [
                fbs.GraphActiveLaneObjectBuilder(lane: 1, kind: fbs.GraphEdgeKind.Indirect),
                fbs.GraphActiveLaneObjectBuilder(lane: 4, kind: fbs.GraphEdgeKind.Missing),
              ],
              syntheticElided: false,
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
      // Every kind decodes on an active lane too (they share the wire enum).
      expect(
        slice.rows.single.activeLanes.map((l) => (l.lane, l.kind)).toList(),
        equals([(1, GraphEdgeKind.indirect), (4, GraphEdgeKind.missing)]),
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
          rows: [
            fbs.GraphRowObjectBuilder(
              commitId: 'far',
              lane: 9,
              colorIdx: 1,
              edges: const [],
              activeLanes: const [],
              syntheticElided: false,
            ),
          ],
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
