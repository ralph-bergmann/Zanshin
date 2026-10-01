// SPDX-License-Identifier: MIT

// The input builder (topology → engine input) and the worker glue around it (Story 4.11), over
// synthetic GraphTopology envelopes (support/topology_envelope.dart). No cdylib needed: the real
// call is test/worker/graph_layout_test.dart.

import 'dart:isolate';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zanshin_core/src/ffi/envelope_zanshin.ffi_generated.dart' as fbs;
import 'package:zanshin_core/src/ffi/graph.dart';
import 'package:zanshin_core/src/graph_layout/graph_grid_view.dart';
import 'package:zanshin_core/src/graph_layout/input_builder.dart';
import 'package:zanshin_core/src/graph_layout/layout_engine.dart';
import 'package:zanshin_core/src/graph_layout/layout_input.dart';
import 'package:zanshin_core/src/graph_layout/layout_reply.dart';
import 'package:zanshin_core/src/graph_layout/layout_request.dart';
import 'package:zanshin_core/src/worker/responses.dart';

import 'support/topology_envelope.dart';

const fbs.GraphEdgeKind _d = fbs.GraphEdgeKind.Direct;
const fbs.GraphEdgeKind _i = fbs.GraphEdgeKind.Indirect;
const fbs.GraphEdgeKind _m = fbs.GraphEdgeKind.Missing;

/// The engine input of [bytes]' topology.
LayoutInput build(Uint8List bytes, {int utcOffsetMin = 0}) =>
    buildLayoutInput(GraphTopologyView.fromEnvelope(bytes), utcOffsetMin: utcOffsetMin);

/// tiny-3-commits `all()`: [@, c3, c2, c1, root]; @ → root, c3 → c2 → c1 → root.
List<List<(int, fbs.GraphEdgeKind)>> get tiny => [
  [(4, _d)],
  [(2, _d)],
  [(3, _d)],
  [(4, _d)],
  [],
];

Matcher violates(String rule) => throwsA(isA<LayoutContractException>().having((e) => e.rule, 'rule', rule));

Uint8List layOut(LayoutInput input) =>
    computeGraphGrid(input, mode: LayoutMode.free, order: LaneOrder.compact, budget: defaultLayoutBudget);

void main() {
  group('repeated targets', () {
    // One child (node 0) with A = node 1 and B = node 2.
    LayoutInput child(List<(int, fbs.GraphEdgeKind)> edges) => build(
      topologyEnvelope([
        edges,
        [(2, _d)],
        [],
      ]),
    );

    test('a_direct_repeat_makes_the_first_position_direct', () {
      expect(parentsOf(child([(1, _i), (2, _d), (1, _d)]), 0), [(1, parentDirect), (2, parentDirect)]);
    });

    test('an_indirect_repeat_of_a_direct_target_is_dropped', () {
      expect(parentsOf(child([(1, _d), (1, _i)]), 0), [(1, parentDirect)]);
    });

    test('two_indirect_edges_to_one_target_stay_one_indirect_parent', () {
      expect(parentsOf(child([(1, _i), (1, _i)]), 0), [(1, parentIndirect)]);
    });

    test('missing_edges_are_kept_and_never_merged', () {
      expect(parentsOf(child([(-1, _m), (1, _d), (-1, _m)]), 0), [
        (-1, parentMissing),
        (1, parentDirect),
        (-1, parentMissing),
      ]);
    });

    test('the_first_parent_and_positions_follow_the_first_occurrence', () {
      // [Ind→A, Dir→B, Dir→A]: fp = A (now direct), B at position 1 — a merge.
      final LayoutInput input = child([(1, _i), (2, _d), (1, _d)]);
      final engine = LayoutEngine(input, LayoutMode.compact)..layering();
      expect([engine.fp[0], engine.edgeParent[engine.lpStart[0]], engine.edgeParent[engine.lpStart[0] + 1]], [1, 1, 2]);
      expect(engine.edgeKind[engine.lpStart[0]], parentDirect);
      layOut(input); // V3 holds after the rule
    });
  });

  group('priority classes', () {
    test('tiny_with_the_default_anchors_is_trunk_chain_then_at_then_the_rest', () {
      final LayoutInput input = build(
        topologyEnvelope(
          tiny,
          roots: {4},
          anchors: [
            [4],
            [0],
          ],
        ),
      );
      expect(input.priority, [1, 2, 2, 2, 0]);
    });

    test('no_anchor_puts_every_node_in_class_0', () {
      expect(build(topologyEnvelope(tiny, roots: {4})).priority, [0, 0, 0, 0, 0]);
    });

    test('an_empty_anchor_leaves_its_class_empty', () {
      final LayoutInput input = build(
        topologyEnvelope(
          tiny,
          anchors: [
            [],
            [0],
          ],
        ),
      );
      expect(input.priority, [1, 2, 2, 2, 1], reason: "@'s chain reaches the root; the rest is class 2");
    });

    test('three_anchors_each_stop_at_the_first_lower_class', () {
      final LayoutInput input = build(
        topologyEnvelope(
          tiny,
          anchors: [
            [2],
            [0],
            [1],
          ],
        ),
      );
      expect(input.priority, [1, 2, 0, 0, 0]);
    });

    test('an_anchor_node_already_in_a_lower_class_keeps_it', () {
      final LayoutInput input = build(
        topologyEnvelope(
          tiny,
          anchors: [
            [2],
            [3, 0],
          ],
        ),
      );
      expect(input.priority, [1, 2, 0, 0, 0]);
    });

    test('the_chain_follows_the_first_non_missing_parent_indirect_included', () {
      final LayoutInput input = build(
        topologyEnvelope(
          [
            [(-1, _m), (2, _i)],
            [(2, _d)],
            [],
          ],
          anchors: [
            [],
            [0],
          ],
        ),
      );
      expect(input.priority, [1, 2, 1]);
    });

    test('an_anchor_node_beyond_the_nodes_is_ffi_unknown', () {
      expect(
        () => build(
          topologyEnvelope(
            tiny,
            anchors: [
              [9],
            ],
          ),
        ),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'ffi.unknown')),
      );
    });
  });

  group('timestamps', () {
    test('a_node_has_a_timestamp_iff_they_were_loaded_and_it_is_not_the_root', () {
      final LayoutInput loaded = build(topologyEnvelope(tiny, roots: {4}, timestamps: [50, 40, 30, 20, 0]));
      expect(loaded.hasTs, [1, 1, 1, 1, 0]);
      expect(loaded.ts.sublist(0, 4), [50, 40, 30, 20]);
      expect(loaded.isRoot, [0, 0, 0, 0, 1]);
      final LayoutInput none = build(topologyEnvelope(tiny, roots: {4}));
      expect(none.hasTs, [0, 0, 0, 0, 0]);
    });

    test('the_utc_offset_is_passed_through', () {
      expect(build(topologyEnvelope(tiny), utcOffsetMin: -300).utcOffsetMin, -300);
    });
  });

  group('contract violations', () {
    test('a_direct_edge_without_a_target_is_v1', () {
      expect(
        () => layOut(
          build(
            topologyEnvelope([
              [(-1, _d)],
              [],
            ]),
          ),
        ),
        violates('V1'),
      );
    });

    test('a_missing_edge_with_a_target_is_v1', () {
      expect(
        () => layOut(
          build(
            topologyEnvelope([
              [(1, _m)],
              [],
            ]),
          ),
        ),
        violates('V1'),
      );
    });

    test('a_target_not_above_its_child_or_beyond_n_is_v2', () {
      expect(
        () => layOut(
          build(
            topologyEnvelope([
              [(0, _d)],
              [],
            ]),
          ),
        ),
        violates('V2'),
        reason: 'itself',
      );
      expect(
        () => layOut(
          build(
            topologyEnvelope([
              [],
              [(0, _d)],
            ]),
          ),
        ),
        violates('V2'),
        reason: 'below',
      );
      expect(
        () => layOut(
          build(
            topologyEnvelope([
              [(7, _i)],
              [],
            ]),
          ),
        ),
        violates('V2'),
        reason: 'beyond n',
      );
    });

    test('an_anchor_chain_stops_at_a_target_beyond_n_and_the_engine_names_v2', () {
      final LayoutInput input = build(
        topologyEnvelope(
          [
            [(7, _d)],
            [],
          ],
          anchors: [
            [0],
          ],
        ),
      );
      expect(input.priority, [0, 1]);
      expect(() => layOut(input), violates('V2'));
    });

    test('two_edges_to_one_target_beyond_n_are_copied_verbatim_and_named_v2', () {
      final LayoutInput input = build(
        topologyEnvelope([
          [(7, _d), (7, _d)],
          [],
        ]),
      );
      expect(parentsOf(input, 0), [(7, parentDirect), (7, parentDirect)], reason: 'never merged out of range');
      expect(() => layOut(input), violates('V2'));
    });

    test('an_edge_kind_byte_that_is_no_kind_is_ffi_unknown', () {
      final Uint8List bytes = topologyEnvelope([
        [(1, _d)],
        [],
      ]);
      final view = GraphTopologyView.fromEnvelope(bytes);
      bytes[view.edgeKinds.offsetInBytes - bytes.offsetInBytes] = 5;
      expect(
        () => buildLayoutInput(GraphTopologyView.fromEnvelope(bytes), utcOffsetMin: 0),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'ffi.unknown')),
      );
    });
  });

  group('worker glue', () {
    GraphLayoutResult reply(Uint8List topology, ({Uint8List? grid, LayoutContractException? violation}) layout) =>
        GraphLayoutResult(
          topology: TransferableTypedData.fromList([topology]),
          grid: layout.grid == null ? null : TransferableTypedData.fromList([layout.grid!]),
          violation: layout.violation,
        );

    ({Uint8List? grid, LayoutContractException? violation}) layOutAt(Uint8List bytes) =>
        layOutTopology(bytes, mode: LayoutMode.free, order: LaneOrder.compact, utcOffsetMin: 120, budget: 0);

    test('a_valid_topology_round_trips_into_the_topology_and_the_grid', () {
      final Uint8List bytes = topologyEnvelope(tiny, roots: {4}, timestamps: [50, 40, 30, 20, 0]);
      final ({Uint8List? grid, LayoutContractException? violation}) layout = layOutAt(bytes);
      expect(layout.violation, isNull);
      final ({GraphTopologyView topology, GraphGridView grid}) decoded = decodeGraphLayoutReply(
        bytes,
        reply(bytes, layout),
      );
      expect(decoded.topology.nodeCount, 5);
      expect([decoded.grid.mode, decoded.grid.order, decoded.grid.nodeCount], [LayoutMode.free, LaneOrder.compact, 5]);
      expect(decoded.grid.bytes, layout.grid);
    });

    test('an_error_envelope_lays_out_nothing_and_decodes_to_its_exception', () {
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: false,
        error: fbs.FfiErrorObjectBuilder(code: 'jj.revset_parse_error', context: 'bogus'),
      ).toBytes();
      final ({Uint8List? grid, LayoutContractException? violation}) layout = layOutAt(bytes);
      expect([layout.grid, layout.violation], [null, null]);
      expect(
        () => decodeGraphLayoutReply(bytes, reply(bytes, layout)),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'jj.revset_parse_error')),
      );
    });

    test('a_contract_violation_crosses_as_the_exception_and_is_rethrown', () {
      final Uint8List bytes = topologyEnvelope([
        [(-1, _d)],
        [],
      ]);
      final ({Uint8List? grid, LayoutContractException? violation}) layout = layOutAt(bytes);
      expect(layout.grid, isNull);
      expect(layout.violation?.rule, 'V1');
      expect(() => decodeGraphLayoutReply(bytes, reply(bytes, layout)), violates('V1'));
    });

    test('a_corrupt_value_the_builder_refuses_is_reproduced_on_the_calling_side', () {
      final Uint8List bytes = topologyEnvelope(
        tiny,
        anchors: [
          [9],
        ],
      );
      final ({Uint8List? grid, LayoutContractException? violation}) layout = layOutAt(bytes);
      expect([layout.grid, layout.violation], [null, null]);
      expect(
        () => decodeGraphLayoutReply(bytes, reply(bytes, layout)),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'ffi.unknown')),
      );
    });

    test('a_reply_without_grid_or_error_is_a_state_error', () {
      final Uint8List bytes = topologyEnvelope(tiny);
      expect(
        () => decodeGraphLayoutReply(bytes, reply(bytes, (grid: null, violation: null))),
        throwsStateError,
      );
    });
  });
}
