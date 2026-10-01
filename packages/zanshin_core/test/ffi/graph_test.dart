// SPDX-License-Identifier: MIT

// Decode-contract tests for [GraphTopologyView] (Story 4.12), using synthetic
// FlatBuffers envelopes built with the generated `fbs.EnvelopeObjectBuilder` +
// `fbs.GraphTopologyObjectBuilder`. No real cdylib required. Every value the view
// reads by hand (typed-data views over the scalar vectors) is checked against the
// generated `fbs.GraphTopology` accessors (project-context: "read through the
// generated typed accessors"), and the id formatting against an independent
// formatter in this file. Mirrors the Rust round-trip in
// crates/zanshin-ffi/src/graph.rs.

import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:test/test.dart';
import 'package:zanshin_core/src/ffi/envelope_zanshin.ffi_generated.dart' as fbs;
import 'package:zanshin_core/src/ffi/graph.dart';
import 'package:zanshin_core/src/ffi/warning.dart';
import 'package:zanshin_core/src/worker/responses.dart';

/// Node 0's commit id bytes (`00 11 … ee ff 01 23 45 67`), node 1's (`ff ee … 98`), the
/// root's (all zero).
final List<int> _commitBytes = [
  ...[0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99],
  ...[0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff, 0x01, 0x23, 0x45, 0x67],
  ...[0xff, 0xee, 0xdd, 0xcc, 0xbb, 0xaa, 0x99, 0x88, 0x77, 0x66],
  ...[0x55, 0x44, 0x33, 0x22, 0x11, 0x00, 0xfe, 0xdc, 0xba, 0x98],
  ...List.filled(20, 0),
];

/// Node 0's change id bytes (`01 23 … ef` twice), node 1's (`fe dc … 10` twice), the
/// root's (all zero).
final List<int> _changeBytes = [
  ...[0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef, 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef],
  ...[0xfe, 0xdc, 0xba, 0x98, 0x76, 0x54, 0x32, 0x10, 0xfe, 0xdc, 0xba, 0x98, 0x76, 0x54, 0x32, 0x10],
  ...List.filled(16, 0),
];

/// `[@ = A, B, root]`: A is a merge with a Direct and an Indirect edge to B (a
/// repeated target) and a Missing edge; B has a Missing edge and a Direct edge to
/// the root. Every per-node value differs between nodes so a cross-wired slot shows.
/// [omit] leaves the named fields absent; the other parameters replace a field.
Uint8List _envelope({
  Set<String> omit = const {},
  List<int>? changeIds,
  List<int>? commitIds,
  int commitIdStride = 20,
  List<int>? parentCount,
  List<int>? edgeTarget,
  List<int>? timestamps,
  List<int>? anchorStart,
  List<fbs.WarningObjectBuilder>? warnings,
}) {
  List<T>? field<T>(String name, List<T> value) => omit.contains(name) ? null : value;
  return fbs.EnvelopeObjectBuilder(
    ok: true,
    dataType: fbs.PayloadTypeId.GraphTopology,
    warnings: warnings,
    data: fbs.GraphTopologyObjectBuilder(
      operationId: omit.contains('operation_id') ? null : 'ab' * 64,
      allCount: 9,
      commitIds: field('commit_ids', commitIds ?? _commitBytes),
      changeIds: field('change_ids', changeIds ?? _changeBytes),
      commitIdStride: commitIdStride,
      changeIdStride: 16,
      // bit 0 working copy, 1 immutable, 2 hidden, 3 divergent, 4 root, 5 has change offset
      flags: field('flags', [0x29, 0x06, 0x12]),
      changeOffset: field('change_offset', [7, 0, 0]),
      changeIdPrefixLen: field('change_id_prefix_len', [3, 5, 1]),
      commitIdPrefixLen: field('commit_id_prefix_len', [4, 6, 2]),
      parentCount: field('parent_count', parentCount ?? [3, 2, 0]),
      edgeStart: field('edge_start', [0, 3, 5, 5]),
      edgeTarget: field('edge_target', edgeTarget ?? [1, 1, -1, -1, 2]),
      edgeKind: field('edge_kind', [
        fbs.GraphEdgeKind.Direct,
        fbs.GraphEdgeKind.Indirect,
        fbs.GraphEdgeKind.Missing,
        fbs.GraphEdgeKind.Missing,
        fbs.GraphEdgeKind.Direct,
      ]),
      timestamps: timestamps,
      refs: field('refs', [
        fbs.TopologyRefObjectBuilder(node: 0, kind: fbs.TopologyRefKind.Bookmark, name: 'feature', synced: true),
        fbs.TopologyRefObjectBuilder(
          node: 0,
          kind: fbs.TopologyRefKind.Bookmark,
          name: 'feature',
          remote: 'origin',
          conflicted: true,
        ),
        fbs.TopologyRefObjectBuilder(node: 0, kind: fbs.TopologyRefKind.Tag, name: 'v1', synced: true),
        fbs.TopologyRefObjectBuilder(node: 1, kind: fbs.TopologyRefKind.Tag, name: 'v0', synced: true),
      ]),
      workingCopies: field('working_copies', [
        fbs.TopologyWorkingCopyObjectBuilder(node: 0, workspace: 'default'),
        fbs.TopologyWorkingCopyObjectBuilder(node: 0, workspace: 'second'),
      ]),
      anchorStart: field('anchor_start', anchorStart ?? [0, 1, 1, 3]),
      anchorNode: field('anchor_node', [2, 0, 1]),
    ),
  ).toBytes();
}

/// An independent formatter: two digits per byte, high nibble first.
String _format(List<int> bytes, String digits) => bytes.map((b) => '${digits[b >> 4]}${digits[b & 0x0f]}').join();

const _hex = '0123456789abcdef';
const _reverseHex = 'zyxwvutsrqponmlk';

/// The single position of [pattern] in [bytes].
int _onlyIndexOf(Uint8List bytes, List<int> pattern) {
  final hits = <int>[
    for (var i = 0; i + pattern.length <= bytes.length; i++)
      if (Iterable<int>.generate(pattern.length).every((k) => bytes[i + k] == pattern[k])) i,
  ];
  expect(hits, hasLength(1), reason: 'the pattern must be unambiguous');
  return hits.single;
}

/// Asserts every value [view] reads equals the generated accessors' value.
void _expectMatchesAccessors(GraphTopologyView view, Uint8List bytes) {
  final payload = fbs.Envelope(bytes).data as fbs.GraphTopology;
  final int n = payload.flags!.length;
  expect(view.nodeCount, n);
  expect(view.operationId, payload.operationId);
  expect(view.allCount, payload.allCount);
  final int cs = payload.commitIdStride;
  final int hs = payload.changeIdStride;
  for (var i = 0; i < n; i++) {
    final int flags = payload.flags![i];
    expect(view.commitId(i), _format(payload.commitIds!.sublist(i * cs, (i + 1) * cs), _hex));
    expect(view.changeId(i), _format(payload.changeIds!.sublist(i * hs, (i + 1) * hs), _reverseHex));
    expect(view.commitIdPrefixLength(i), payload.commitIdPrefixLen![i]);
    expect(view.changeIdPrefixLength(i), payload.changeIdPrefixLen![i]);
    expect(view.flags[i], flags);
    expect(view.isWorkingCopy(i), flags & 1 != 0);
    expect(view.isImmutable(i), flags & 2 != 0);
    expect(view.isHidden(i), flags & 4 != 0);
    expect(view.isDivergent(i), flags & 8 != 0);
    expect(view.isRoot(i), flags & 16 != 0);
    expect(view.changeOffset(i), flags & 32 != 0 ? payload.changeOffset![i] : null);
    expect(view.parentCount(i), payload.parentCount![i]);
    expect(view.parentCounts[i], payload.parentCount![i]);
    expect(view.edgeStart(i), payload.edgeStart![i]);
    expect(view.edgeEnd(i), payload.edgeStart![i + 1]);
    final List<int>? timestamps = payload.timestamps;
    expect(view.timestamp(i), timestamps == null || flags & 16 != 0 ? null : timestamps[i]);
  }
  final List<fbs.GraphEdgeKind> kinds = payload.edgeKind!;
  for (var e = 0; e < kinds.length; e++) {
    expect(view.edgeKind(e).index, kinds[e].value, reason: 'the Dart enum mirrors the wire values');
    expect(view.edgeKinds[e], kinds[e].value);
    expect(view.edgeTargets[e], payload.edgeTarget![e]);
    expect(view.edgeTarget(e), kinds[e] == fbs.GraphEdgeKind.Missing ? null : payload.edgeTarget![e]);
  }
  expect(view.hasTimestamps, payload.timestamps != null);
  expect(view.timestamps, payload.timestamps);
  final List<fbs.TopologyRef> refs = payload.refs!;
  expect(view.refs.map((r) => (r.node, r.kind.index, r.name, r.remote, r.synced, r.conflicted)), [
    for (final r in refs) (r.node, r.kind.value, r.name, r.remote, r.synced, r.conflicted),
  ]);
  expect(view.workingCopies.map((w) => (w.node, w.workspace)), [
    for (final w in payload.workingCopies!) (w.node, w.workspace),
  ]);
  final List<int> starts = payload.anchorStart!;
  expect(view.anchorCount, starts.length - 1);
  for (var a = 0; a + 1 < starts.length; a++) {
    expect(view.anchorNodes(a), payload.anchorNode!.sublist(starts[a], starts[a + 1]));
  }
  expect(view.anchorStarts, starts);
  expect(view.anchorNodesFlat, payload.anchorNode);
  expect(view.edgeStarts, payload.edgeStart);
}

Matcher _throwsUnknown(String context) => throwsA(
  isA<ZanshinFfiException>().having((e) => e.code, 'code', 'ffi.unknown').having((e) => e.context, 'context', context),
);

void main() {
  group('graph pre-fills', () {
    test('defaultGraphAnchors is the trunk chain first, then @ (Story 4.10)', () {
      // The editable pre-fill for the topology call's required `anchors`; the
      // order is the priority order 4.11's rule reads.
      expect(defaultGraphAnchors, ['trunk()', 'present(@)']);
    });
  });

  group('GraphTopologyView decode contract', () {
    test('random access equals the generated accessors, timestamps absent', () {
      final Uint8List bytes = _envelope();
      _expectMatchesAccessors(GraphTopologyView.fromEnvelope(bytes), bytes);
    });

    test('random access equals the generated accessors, timestamps present', () {
      final Uint8List bytes = _envelope(timestamps: [1700000000123, -5, 0]);
      final view = GraphTopologyView.fromEnvelope(bytes);

      _expectMatchesAccessors(view, bytes);
      expect(view.timestamp(0), 1700000000123);
      expect(view.timestamp(1), -5);
      expect(view.timestamp(2), isNull, reason: "the root's slot 0 reads as null");
    });

    test('formats commit ids as hex and change ids as reverse-hex, extremes included', () {
      final view = GraphTopologyView.fromEnvelope(_envelope());

      expect(view.commitId(0), '00112233445566778899aabbccddeeff01234567');
      expect(view.commitId(1), 'ffeeddccbbaa99887766554433221100fedcba98');
      expect(view.changeId(0), 'zyxwvutsrqponmlk' * 2, reason: '0x01 → zy … 0xef → lk');
      expect(view.changeId(1), 'klmnopqrstuvwxyz' * 2, reason: '0xfe → kl … 0x10 → yz');
      expect(view.changeId(2), 'z' * 32, reason: 'nibble 0 → z');
    });

    test('reads null for every absence', () {
      final view = GraphTopologyView.fromEnvelope(_envelope());

      expect(view.changeOffset(0), 7);
      expect(view.changeOffset(1), isNull, reason: 'presence bit clear');
      expect(view.edgeTarget(2), isNull, reason: "a Missing edge's −1 slot");
      expect(view.edgeTargets[2], -1);
      expect(view.hasTimestamps, isFalse);
      expect(view.timestamp(0), isNull, reason: 'none requested');
      expect(view.timestamps, isNull);
      expect(view.refs.first.remote, isNull, reason: 'the local entry has no remote');
      expect(view.refs[1].remote, 'origin');
    });

    test('refsOf and workingCopiesOf find each node by binary search', () {
      final view = GraphTopologyView.fromEnvelope(_envelope());

      expect(view.refsOf(0).map((r) => (r.kind, r.name, r.remote)), [
        (TopologyRefKind.bookmark, 'feature', null),
        (TopologyRefKind.bookmark, 'feature', 'origin'),
        (TopologyRefKind.tag, 'v1', null),
      ]);
      expect(view.refsOf(1).map((r) => r.name), ['v0']);
      expect(view.refsOf(2), isEmpty);
      expect(view.workingCopiesOf(0).map((w) => w.workspace), ['default', 'second']);
      expect(view.workingCopiesOf(1), isEmpty);
      expect(() => view.refsOf(3), throwsRangeError);
      expect(() => view.workingCopiesOf(-1), throwsRangeError);
    });

    test('anchors read through their CSR, an empty anchor included', () {
      final view = GraphTopologyView.fromEnvelope(_envelope());

      expect(view.anchorCount, 3);
      expect(view.anchorNodes(0), [2]);
      expect(view.anchorNodes(1), isEmpty);
      expect(view.anchorNodes(2), [0, 1]);
      expect(() => view.anchorNodes(3), throwsRangeError);
    });

    test('an index past the last node is a RangeError, not an empty id', () {
      final view = GraphTopologyView.fromEnvelope(_envelope());

      expect(() => view.commitId(3), throwsRangeError);
      expect(() => view.changeId(-1), throwsRangeError);
      expect(() => view.parentCount(3), throwsRangeError);
      expect(() => view.timestamp(3), throwsRangeError);
    });

    test('an empty topology reads as no node with present, empty vectors', () {
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.GraphTopology,
        data: fbs.GraphTopologyObjectBuilder(
          operationId: 'cd',
          allCount: 5,
          commitIds: const [],
          changeIds: const [],
          flags: const [],
          changeOffset: const [],
          changeIdPrefixLen: const [],
          commitIdPrefixLen: const [],
          parentCount: const [],
          edgeStart: const [0],
          edgeTarget: const [],
          edgeKind: const [],
          refs: const [],
          workingCopies: const [],
          anchorStart: const [0, 0, 0],
          anchorNode: const [],
        ),
      ).toBytes();
      final view = GraphTopologyView.fromEnvelope(bytes);

      expect(view.nodeCount, 0);
      expect(view.allCount, 5);
      expect(view.anchorCount, 2);
      expect(view.anchorNodes(1), isEmpty);
      expect(view.indexOfCommitId('00'), isNull);
      expect(() => view.commitId(0), throwsRangeError);
    });
  });

  group('GraphTopologyView malformed buffers', () {
    test('an error envelope throws its ZanshinFfiException with the call warnings', () {
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: false,
        error: fbs.FfiErrorObjectBuilder(code: 'jj.revset_parse_error', context: 'bad'),
        warnings: [fbs.WarningObjectBuilder(code: ZanshinWarningCode.revsetDiagnostic, message: 'm')],
      ).toBytes();

      expect(
        () => GraphTopologyView.fromEnvelope(bytes),
        throwsA(
          isA<ZanshinFfiException>()
              .having((e) => e.code, 'code', 'jj.revset_parse_error')
              .having((e) => e.context, 'context', 'bad')
              .having((e) => e.warnings.single.message, 'warnings', 'm'),
        ),
      );
    });

    test('an ok envelope with another payload throws ffi.unknown', () {
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.RepoHandle,
        data: fbs.RepoHandleObjectBuilder(handle: 1),
      ).toBytes();

      expect(
        () => GraphTopologyView.fromEnvelope(bytes),
        _throwsUnknown('expected GraphTopology payload, got PayloadTypeId.RepoHandle'),
      );
    });

    for (final field in [
      'operation_id',
      'refs',
      'working_copies',
      'flags',
      'commit_ids',
      'change_ids',
      'change_offset',
      'change_id_prefix_len',
      'commit_id_prefix_len',
      'parent_count',
      'edge_start',
      'edge_target',
      'edge_kind',
      'anchor_start',
      'anchor_node',
    ]) {
      test('a missing $field throws ffi.unknown', () {
        expect(
          () => GraphTopologyView.fromEnvelope(_envelope(omit: {field})),
          _throwsUnknown('GraphTopology is missing its $field'),
        );
      });
    }

    test('a vector of the wrong length throws ffi.unknown', () {
      expect(
        () => GraphTopologyView.fromEnvelope(_envelope(parentCount: [3, 2])),
        _throwsUnknown('GraphTopology.parent_count has 2 entries, expected 3'),
      );
      expect(
        () => GraphTopologyView.fromEnvelope(_envelope(edgeTarget: [1, 1, -1, -1])),
        _throwsUnknown('GraphTopology.edge_target has 4 entries, expected 5'),
      );
      expect(
        () => GraphTopologyView.fromEnvelope(_envelope(timestamps: [1, 2])),
        _throwsUnknown('GraphTopology.timestamps has 2 entries, expected 3'),
      );
      expect(
        () => GraphTopologyView.fromEnvelope(_envelope(commitIds: _commitBytes.sublist(1))),
        _throwsUnknown('GraphTopology.commit_ids has 59 entries, expected 60'),
      );
      expect(
        () => GraphTopologyView.fromEnvelope(_envelope(anchorStart: [0, 1, 1, 4])),
        _throwsUnknown('GraphTopology.anchor_node has 3 entries, expected 4'),
      );
    });

    test('nodes with a zero id stride or an empty anchor_start throw ffi.unknown', () {
      expect(
        () => GraphTopologyView.fromEnvelope(_envelope(commitIdStride: 0, commitIds: const [])),
        _throwsUnknown('GraphTopology has nodes but a zero id stride'),
      );
      expect(
        () => GraphTopologyView.fromEnvelope(_envelope(anchorStart: const [])),
        _throwsUnknown('GraphTopology.anchor_start is empty, expected anchors + 1 entries'),
      );
    });

    test('a vector length running past the buffer throws ffi.unknown', () {
      final Uint8List bytes = _envelope();
      // anchor_start = [0, 1, 1, 3], after its u32 length prefix 4.
      final int at = _onlyIndexOf(bytes, [4, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 3, 0, 0, 0]);
      bytes.setAll(at, [0xff, 0xff, 0xff, 0x00]);

      expect(
        () => GraphTopologyView.fromEnvelope(bytes),
        _throwsUnknown('GraphTopology.anchor_start runs past the end of the buffer'),
      );
    });

    test('an unknown edge-kind byte throws ffi.unknown on access only', () {
      final Uint8List bytes = _envelope();
      // edge_kind = [0, 1, 2, 2, 0] after its u32 length prefix 5.
      final int at = _onlyIndexOf(bytes, [5, 0, 0, 0, 0, 1, 2, 2, 0]);
      bytes[at + 4 + 2] = 7;
      final view = GraphTopologyView.fromEnvelope(bytes);

      expect(view.edgeKind(0), GraphEdgeKind.direct, reason: 'the other edges still read');
      expect(() => view.edgeKind(2), _throwsUnknown('GraphTopology.edge_kind[2] is 7'));
      expect(() => view.edgeTarget(2), _throwsUnknown('GraphTopology.edge_kind[2] is 7'));
    });

    test('a ref without its name throws ffi.unknown when the refs are read', () {
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.GraphTopology,
        data: fbs.GraphTopologyObjectBuilder(
          operationId: 'cd',
          commitIds: const [],
          changeIds: const [],
          flags: const [],
          changeOffset: const [],
          changeIdPrefixLen: const [],
          commitIdPrefixLen: const [],
          parentCount: const [],
          edgeStart: const [0],
          edgeTarget: const [],
          edgeKind: const [],
          refs: [fbs.TopologyRefObjectBuilder()],
          workingCopies: [fbs.TopologyWorkingCopyObjectBuilder()],
          anchorStart: const [0],
          anchorNode: const [],
        ),
      ).toBytes();
      final view = GraphTopologyView.fromEnvelope(bytes);

      expect(() => view.refs, _throwsUnknown('GraphTopology is missing its refs[].name'));
      expect(() => view.workingCopies, _throwsUnknown('GraphTopology is missing its working_copies[].workspace'));
    });
  });

  // The Dart `fb.Builder` aligns a `[long]` vector's LENGTH PREFIX to 8, so its
  // elements sit at 4 mod 8 — unlike the Rust builder, which aligns the elements
  // (the real-cdylib worker test pins 0 copies WITH timestamps). The synthetic
  // "aligned" buffers below therefore carry only 1- and 4-byte vectors.
  group('GraphTopologyView memory', () {
    test('aligned bytes are read through views that share the buffer, nothing copied', () {
      final bytes = Uint8List.fromList(_envelope());
      final view = GraphTopologyView.fromEnvelope(bytes);
      expect(view.copiedVectorCount, 0);

      // parent_count = [3, 2, 0] after its u32 length prefix 3: rewrite node 0's
      // count in the SOURCE bytes and read it back through the view.
      final int at = _onlyIndexOf(bytes, [3, 0, 0, 0, 3, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0]);
      bytes[at + 4] = 9;
      expect(view.parentCount(0), 9, reason: 'the view aliases the envelope bytes');
      expect(() => view.bytes[at + 4] = 1, throwsUnsupportedError, reason: 'the view never writes them');
    });

    test('bytes at offset 1 copy the misaligned vectors and read the same values', () {
      final Uint8List source = _envelope(timestamps: [1700000000123, -5, 0]);
      final shifted = Uint8List(source.length + 1)..setAll(1, source);
      final misaligned = Uint8List.sublistView(shifted, 1);
      final view = GraphTopologyView.fromEnvelope(misaligned);

      // change_offset, parent_count, edge_start, edge_target, timestamps,
      // anchor_start, anchor_node — every vector wider than a byte.
      expect(view.copiedVectorCount, 7);
      _expectMatchesAccessors(view, misaligned);
    });

    test('a view over malloc-ed native memory reads the same values', () {
      for (final List<int>? timestamps in [
        null,
        const [1700000000123, -5, 0],
      ]) {
        final Uint8List source = _envelope(timestamps: timestamps);
        final ffi.Pointer<ffi.Uint8> ptr = malloc.allocate<ffi.Uint8>(source.length);
        try {
          final Uint8List native = ptr.asTypedList(source.length)..setAll(0, source);
          final view = GraphTopologyView.fromEnvelope(native);

          if (timestamps == null) {
            expect(view.copiedVectorCount, 0, reason: 'malloc memory is aligned');
          }
          _expectMatchesAccessors(view, native);
        } finally {
          malloc.free(ptr);
        }
      }
    });
  });

  group('GraphTopologyView lookups', () {
    test('indexOfCommitId hits every node and misses with null', () {
      final view = GraphTopologyView.fromEnvelope(_envelope());

      for (var i = 0; i < view.nodeCount; i++) {
        expect(view.indexOfCommitId(view.commitId(i)), i);
      }
      expect(view.indexOfCommitId('ff' * 20), isNull);
      expect(view.indexOfCommitId('00112233445566778899AABBCCDDEEFF01234567'), isNull, reason: 'lowercase only');
    });

    test('indicesOfChangeId returns both divergent twins and [] on a miss', () {
      // Nodes 0 and 1 share node 0's change id.
      final view = GraphTopologyView.fromEnvelope(
        _envelope(changeIds: [..._changeBytes.sublist(0, 16), ..._changeBytes.sublist(0, 16), ...List.filled(16, 0)]),
      );

      expect(view.indicesOfChangeId(view.changeId(0)), [0, 1]);
      expect(view.indicesOfChangeId('z' * 32), [2]);
      expect(view.indicesOfChangeId('k' * 32), isEmpty);
    });

    test('indicesOfChangeId returns every node of a change divergent three ways', () {
      // All three nodes carry node 0's change id (the lookup does not care which is the root).
      final List<int> shared = _changeBytes.sublist(0, 16);
      final view = GraphTopologyView.fromEnvelope(_envelope(changeIds: [...shared, ...shared, ...shared]));

      expect(view.indicesOfChangeId(view.changeId(0)), [0, 1, 2]);
    });
  });
}
