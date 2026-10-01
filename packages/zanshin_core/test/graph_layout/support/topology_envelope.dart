// SPDX-License-Identifier: MIT

// Synthetic GraphTopology envelopes for the input builder's tests (Story 4.11), built with the
// generated `fbs.GraphTopologyObjectBuilder` (pattern of test/ffi/graph_test.dart).

import 'dart:typed_data';

import 'package:zanshin_core/src/ffi/envelope_zanshin.ffi_generated.dart' as fbs;
import 'package:zanshin_core/src/ffi/graph.dart';
import 'package:zanshin_core/src/graph_layout/layout_input.dart';

/// A synthetic `GraphTopology` envelope of `edges.length` nodes: node i's edges are `edges[i]`,
/// each `(target, kind)` (a Missing edge's target is −1 unless given otherwise); [roots] carry the
/// root flag; [timestamps] (one per node) are present iff given; [anchors] are node lists.
Uint8List topologyEnvelope(
  List<List<(int, fbs.GraphEdgeKind)>> edges, {
  Set<int> roots = const {},
  List<int>? timestamps,
  List<List<int>> anchors = const [],
}) {
  final int n = edges.length;
  final edgeStart = <int>[0];
  for (final e in edges) {
    edgeStart.add(edgeStart.last + e.length);
  }
  final anchorStart = <int>[0];
  for (final a in anchors) {
    anchorStart.add(anchorStart.last + a.length);
  }
  return fbs.EnvelopeObjectBuilder(
    ok: true,
    dataType: fbs.PayloadTypeId.GraphTopology,
    data: fbs.GraphTopologyObjectBuilder(
      operationId: 'ab' * 64,
      allCount: n,
      commitIds: [for (var i = 0; i < n; i++) ...List.filled(20, i & 0xFF)],
      changeIds: [for (var i = 0; i < n; i++) ...List.filled(16, i & 0xFF)],
      commitIdStride: 20,
      changeIdStride: 16,
      flags: [
        for (var i = 0; i < n; i++)
          if (roots.contains(i)) GraphTopologyView.flagRoot else 0,
      ],
      changeOffset: List.filled(n, 0),
      changeIdPrefixLen: List.filled(n, 1),
      commitIdPrefixLen: List.filled(n, 1),
      parentCount: [for (final List<(int, fbs.GraphEdgeKind)> e in edges) e.length],
      edgeStart: edgeStart,
      edgeTarget: [
        for (final List<(int, fbs.GraphEdgeKind)> e in edges)
          for (final (int target, _) in e) target,
      ],
      edgeKind: [
        for (final List<(int, fbs.GraphEdgeKind)> e in edges)
          for (final (_, fbs.GraphEdgeKind kind) in e) kind,
      ],
      timestamps: timestamps,
      refs: const [],
      workingCopies: const [],
      anchorStart: anchorStart,
      anchorNode: [for (final List<int> a in anchors) ...a],
    ),
  ).toBytes();
}

/// Node [i]'s parents in [input] as `(idx, kind)` pairs.
List<(int, int)> parentsOf(LayoutInput input, int i) => [
  for (int k = input.parStart[i]; k < input.parStart[i + 1]; k++) (input.parIdx[k], input.parKind[k]),
];
