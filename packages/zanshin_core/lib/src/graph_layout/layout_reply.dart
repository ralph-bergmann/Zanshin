// SPDX-License-Identifier: MIT

import 'dart:isolate';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../ffi/graph.dart' show GraphTopologyView;
import '../worker/responses.dart' show GraphLayoutResult, ZanshinFfiException;
import 'graph_grid_view.dart';
import 'input_builder.dart';
import 'layout_engine.dart';
import 'layout_input.dart';
import 'layout_request.dart';

// The glue between the worker's `GraphLayoutCommand` and the engine (Story 4.11): the worker
// side lays out the topology envelope it has; the caller side turns the reply into the topology
// view and the grid view, or into the error the call ended with.

/// The worker side of `RepoHandle.graphLayout`: reads [topologyEnvelope] (the
/// `zanshin_graph_topology` reply, possibly a view over native memory) and lays it out.
///
/// Returns the grid buffer ([GraphGridView]'s format), or the [LayoutContractException] the
/// engine's validation threw. Returns neither when the envelope is an error envelope, the view
/// cannot be built over it, or the topology carries a corrupt value the input builder refuses —
/// [decodeGraphLayoutReply] then reproduces that error from the same bytes.
({Uint8List? grid, LayoutContractException? violation}) layOutTopology(
  Uint8List topologyEnvelope, {
  required LayoutMode mode,
  required LaneOrder order,
  required int utcOffsetMin,
  required int budget,
}) {
  try {
    final topology = GraphTopologyView.fromEnvelope(topologyEnvelope);
    final LayoutInput input = buildLayoutInput(topology, utcOffsetMin: utcOffsetMin);
    return (grid: computeGraphGrid(input, mode: mode, order: order, budget: budget), violation: null);
  } on LayoutContractException catch (e) {
    return (grid: null, violation: e);
  } on ZanshinFfiException {
    return (grid: null, violation: null);
  }
}

/// The caller side of `RepoHandle.graphLayout`: the topology view over [topologyBytes] (the
/// materialized `reply.topology`) and the grid view over `reply.grid`, materialized here once.
///
/// Throws, in this order: the topology's [ZanshinFfiException] (an error envelope, with its
/// precondition and warnings, or a corrupt buffer), the reply's [LayoutContractException], the
/// input builder's `ffi.unknown` for a corrupt value, and a [StateError] for a reply that carries
/// none of them and no grid.
///
/// Exposed for decode-contract tests; production goes through `ZanshinWorker.graphLayout`.
@visibleForTesting
({GraphTopologyView topology, GraphGridView grid}) decodeGraphLayoutReply(
  Uint8List topologyBytes,
  GraphLayoutResult reply,
) => decodeGraphLayoutReplyInternal(topologyBytes, reply);

/// Internal decoder used by production code in `isolate.dart`; see [decodeGraphLayoutReply].
({GraphTopologyView topology, GraphGridView grid}) decodeGraphLayoutReplyInternal(
  Uint8List topologyBytes,
  GraphLayoutResult reply,
) {
  final topology = GraphTopologyView.fromEnvelope(topologyBytes);
  final LayoutContractException? violation = reply.violation;
  if (violation != null) {
    throw violation;
  }
  final TransferableTypedData? grid = reply.grid;
  if (grid == null) {
    // The worker refused the topology's values; building the input again names why.
    buildLayoutInput(topology, utcOffsetMin: 0);
    throw StateError('a graphLayout reply carries neither a grid nor an error');
  }
  return (topology: topology, grid: GraphGridView.fromBytes(grid.materialize().asUint8List()));
}
