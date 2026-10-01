// SPDX-License-Identifier: MIT

// The grid buffer's decode contract (Story 4.11): GraphGridView over Dart-built buffers — the
// header slots, the 8-aligned array offsets and counts, the enum codes, every refusal as a
// FormatException, and the one copy of a buffer that does not start 8-aligned.

import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zanshin_core/src/graph_layout/graph_grid_view.dart';
import 'package:zanshin_core/src/graph_layout/layout_request.dart';

/// A grid of 3 nodes, 2 edges and 2 buckets with distinct values per slot.
Uint8List grid() => writeGraphGrid(
  mode: LayoutMode.free,
  order: LaneOrder.compact,
  unit: 16,
  rows: 48,
  lanes: 2,
  nodeRows: Int64List.fromList([32, 16, 0]),
  nodeLanes: Int32List.fromList([1, 0, 0]),
  nodeCols: Int32List.fromList([1, 0, 0]),
  edgeFroms: Int32List.fromList([2, 2]),
  edgeTos: Int32List.fromList([0, 1]),
  edgeKinds: Uint8List.fromList([GraphGridView.edgeKindIndirect, GraphGridView.edgeKindDirect]),
  edgeRoutes: Uint8List.fromList([GraphGridView.routeBranchOff, GraphGridView.routeStraight]),
  edgeBlocked: Uint8List.fromList([1, 0]),
  bucketValues: Int64List.fromList([-86400000, 1700000000000]),
  bucketStarts: Int64List.fromList([16, 32]),
  bucketEnds: Int64List.fromList([16, 32]),
);

/// A version-2 grid (Story 4.13) of n = 4 topology nodes and S = 1 stack node (node 4): run 0
/// ([2, 1]) collapsed behind it, run 1 ([3, 0]) expanded; 2 edges and 1 bucket.
Uint8List stackGrid() => writeStackGrid(
  mode: LayoutMode.compact,
  order: LaneOrder.greedy,
  unit: 1,
  rows: 4,
  lanes: 1,
  nodeRows: Int64List.fromList([3, -1, -1, 0, 1]),
  nodeLanes: Int32List.fromList([0, -1, -1, 0, 0]),
  nodeCols: Int32List.fromList([0, -1, -1, 0, 0]),
  edgeFroms: Int32List.fromList([4, 3]),
  edgeTos: Int32List.fromList([0, 4]),
  edgeKinds: Uint8List.fromList([GraphGridView.edgeKindIndirect, GraphGridView.edgeKindDirect]),
  edgeRoutes: Uint8List.fromList([GraphGridView.routeStraight, GraphGridView.routeStraight]),
  edgeBlocked: Uint8List(2),
  bucketValues: Int64List.fromList([86400000]),
  bucketStarts: Int64List.fromList([1]),
  bucketEnds: Int64List.fromList([3]),
  nodeRuns: Int32List.fromList([1, 0, 0, 1]),
  runStates: Uint8List.fromList([GraphGridView.runCollapsed, GraphGridView.runExpanded]),
  runNodes: Int32List.fromList([4, -1]),
  runStarts: Int32List.fromList([0, 2, 4]),
  runMembers: Int32List.fromList([2, 1, 3, 0]),
);

/// Header slot [k] of [bytes].
int slot(Uint8List bytes, int k) => ByteData.sublistView(bytes).getInt32(4 * k, Endian.little);

/// [bytes] with header slot [k] set to [value].
Uint8List withSlot(Uint8List bytes, int k, int value) {
  final copy = Uint8List.fromList(bytes);
  ByteData.sublistView(copy).setInt32(4 * k, value, Endian.little);
  return copy;
}

Matcher get refused => throwsA(isA<FormatException>());

void main() {
  test('the_header_carries_version_mode_order_unit_and_counts', () {
    final Uint8List bytes = grid();
    expect([for (var k = 0; k < 9; k++) slot(bytes, k)], [1, 1, 1, 16, 48, 2, 3, 2, 2]);
  });

  test('every_array_starts_8_aligned_after_the_previous_one_the_first_at_136', () {
    final Uint8List bytes = grid();
    const sizes = [4, 4, 4, 4, 4, 1, 1, 1, 1, 8, 4, 4];
    var end = 132;
    for (var k = 0; k < 12; k++) {
      final int offset = slot(bytes, 9 + 2 * k);
      final int count = slot(bytes, 10 + 2 * k);
      expect(offset, (end + 7) & ~7, reason: 'array $k');
      expect(count, k < 3 ? 3 : 2, reason: 'array $k: n = 3, E = B = 2');
      end = offset + count * sizes[k];
    }
    expect(slot(bytes, 9), 136);
    expect(bytes.length, end);
  });

  test('the_views_read_every_value_and_the_enum_codes', () {
    final view = GraphGridView.fromBytes(grid());
    expect([view.mode, view.order, view.unit, view.rows, view.lanes], [LayoutMode.free, LaneOrder.compact, 16, 48, 2]);
    expect([view.nodeCount, view.edgeCount, view.bucketCount], [3, 2, 2]);
    expect(
      [view.nodeRows, view.nodeLanes, view.nodeCols],
      [
        [32, 16, 0],
        [1, 0, 0],
        [1, 0, 0],
      ],
    );
    expect(
      [view.edgeFroms, view.edgeTos, view.edgeKinds, view.edgeRoutes, view.edgeBlocked],
      [
        [2, 2],
        [0, 1],
        [1, 0],
        [2, 0],
        [1, 0],
      ],
    );
    expect(
      [view.bucketKinds, view.bucketValues, view.bucketStarts, view.bucketEnds],
      [
        [2, 2],
        [-86400000, 1700000000000],
        [16, 32],
        [16, 32],
      ],
    );
    expect(
      [
        GraphGridView.routeStraight,
        GraphGridView.routeMerge,
        GraphGridView.routeBranchOff,
        GraphGridView.bucketKindDay,
      ],
      [0, 1, 2, 2],
    );
    expect(view.copied, isFalse);
    expect(() => view.nodeRows[0] = 1, throwsUnsupportedError, reason: 'unmodifiable');
    expect(() => view.bytes[0] = 1, throwsUnsupportedError, reason: 'unmodifiable');
  });

  test('an_empty_grid_decodes', () {
    final view = GraphGridView.fromBytes(
      writeGraphGrid(
        mode: LayoutMode.compact,
        order: LaneOrder.greedy,
        unit: 1,
        rows: 0,
        lanes: 0,
        nodeRows: Int64List(0),
        nodeLanes: Int32List(0),
        nodeCols: Int32List(0),
        edgeFroms: Int32List(0),
        edgeTos: Int32List(0),
        edgeKinds: Uint8List(0),
        edgeRoutes: Uint8List(0),
        edgeBlocked: Uint8List(0),
        bucketValues: Int64List(0),
        bucketStarts: Int64List(0),
        bucketEnds: Int64List(0),
      ),
    );
    expect(
      [view.mode, view.order, view.unit, view.nodeCount, view.edgeCount, view.bucketCount],
      [
        LayoutMode.compact,
        LaneOrder.greedy,
        1,
        0,
        0,
        0,
      ],
    );
  });

  test('a_buffer_that_does_not_start_8_aligned_is_copied_once_with_equal_values', () {
    final Uint8List bytes = grid();
    final shifted = Uint8List(bytes.length + 4)..setAll(4, bytes);
    final view = GraphGridView.fromBytes(Uint8List.sublistView(shifted, 4));
    expect(view.copied, isTrue);
    expect(view.bytes, bytes);
    expect(view.bucketValues, [-86400000, 1700000000000]);
    expect(view.nodeRows, [32, 16, 0]);
    final aligned = Uint8List(bytes.length + 8)..setAll(8, bytes);
    expect(GraphGridView.fromBytes(Uint8List.sublistView(aligned, 8)).copied, isFalse, reason: 'an 8-aligned view');
  });

  test('every_malformed_header_is_a_format_exception', () {
    final Uint8List bytes = grid();
    expect(() => GraphGridView.fromBytes(Uint8List.sublistView(bytes, 0, 131)), refused, reason: 'short buffer');
    expect(() => GraphGridView.fromBytes(withSlot(bytes, 0, 2)), refused, reason: 'version');
    expect(() => GraphGridView.fromBytes(withSlot(bytes, 1, 2)), refused, reason: 'mode code');
    expect(() => GraphGridView.fromBytes(withSlot(bytes, 1, -1)), refused, reason: 'mode code');
    expect(() => GraphGridView.fromBytes(withSlot(bytes, 2, 3)), refused, reason: 'order code');
    expect(() => GraphGridView.fromBytes(withSlot(bytes, 3, 1)), refused, reason: 'a unit not the mode\'s');
    expect(() => GraphGridView.fromBytes(withSlot(bytes, 6, -1)), refused, reason: 'negative n');
    expect(() => GraphGridView.fromBytes(withSlot(bytes, 6, 4)), refused, reason: 'node count ≠ array counts');
    expect(() => GraphGridView.fromBytes(withSlot(bytes, 10, 2)), refused, reason: 'an array count mismatch');
    expect(() => GraphGridView.fromBytes(withSlot(bytes, 9, 140)), refused, reason: 'an unaligned offset');
    expect(() => GraphGridView.fromBytes(withSlot(bytes, 9, 128)), refused, reason: 'an offset inside the header');
    expect(() => GraphGridView.fromBytes(withSlot(bytes, 9 + 2 * 11, bytes.length)), refused, reason: 'out of bounds');
    expect(
      () => GraphGridView.fromBytes(Uint8List.sublistView(bytes, 0, bytes.length - 1)),
      refused,
      reason: 'truncated',
    );
  });

  group('format version 2 (stacks, Story 4.13)', () {
    test('a_version_1_grid_reads_as_one_without_stacks', () {
      final view = GraphGridView.fromBytes(grid());
      expect([view.hasStacks, view.stackCount, view.runCount], [false, 0, 0]);
      expect([view.nodeRuns, view.runStates, view.runNodes, view.runStarts, view.runMembers], everyElement(isNull));
      expect([view.isHidden(0), view.isHidden(2)], [false, false]);
    });

    test('the_header_carries_the_stack_counts_after_version_1s_slots', () {
      final Uint8List bytes = stackGrid();
      expect([for (var k = 0; k < 9; k++) slot(bytes, k)], [2, 0, 0, 1, 4, 1, 4, 2, 1]);
      expect([slot(bytes, 33), slot(bytes, 34), slot(bytes, 35)], [1, 2, 4], reason: 'S, R, M');
    });

    test('all_seventeen_arrays_start_8_aligned_the_first_at_184', () {
      final Uint8List bytes = stackGrid();
      const sizes = [4, 4, 4, 4, 4, 1, 1, 1, 1, 8, 4, 4, 4, 1, 4, 4, 4];
      const counts = [5, 5, 5, 2, 2, 2, 2, 2, 1, 1, 1, 1, 4, 2, 2, 3, 4];
      var end = 184;
      for (var k = 0; k < 17; k++) {
        final int offsetSlot = k < 12 ? 9 + 2 * k : 36 + 2 * (k - 12);
        final int offset = slot(bytes, offsetSlot);
        expect(offset, (end + 7) & ~7, reason: 'array $k');
        expect(
          slot(bytes, offsetSlot + 1),
          counts[k],
          reason: 'array $k: n + S = 5, n = 4, E = 2, B = 1, R = 2, M = 4',
        );
        end = offset + counts[k] * sizes[k];
      }
      expect(slot(bytes, 9), 184);
      expect(bytes.length, end);
    });

    test('the_views_read_the_runs_and_the_hidden_nodes', () {
      final view = GraphGridView.fromBytes(stackGrid());
      expect([view.hasStacks, view.nodeCount, view.stackCount, view.runCount], [true, 4, 1, 2]);
      expect(
        [view.nodeRows, view.nodeLanes, view.nodeCols],
        [
          [3, -1, -1, 0, 1],
          [0, -1, -1, 0, 0],
          [0, -1, -1, 0, 0],
        ],
      );
      expect(
        [view.edgeFroms, view.edgeTos, view.bucketStarts, view.bucketEnds],
        [
          [4, 3],
          [0, 4],
          [1],
          [3],
        ],
      );
      expect(
        [view.nodeRuns, view.runStates, view.runNodes, view.runStarts, view.runMembers],
        [
          [1, 0, 0, 1],
          [1, 0],
          [4, -1],
          [0, 2, 4],
          [2, 1, 3, 0],
        ],
      );
      expect([GraphGridView.runExpanded, GraphGridView.runCollapsed], [0, 1]);
      expect([for (var i = 0; i < 5; i++) view.isHidden(i)], [false, true, true, false, false]);
      expect(() => view.isHidden(5), throwsRangeError);
      expect(() => view.runMembers![0] = 9, throwsUnsupportedError, reason: 'unmodifiable');
    });

    test('a_shifted_version_2_buffer_is_copied_once_with_equal_values', () {
      final Uint8List bytes = stackGrid();
      final shifted = Uint8List(bytes.length + 4)..setAll(4, bytes);
      final view = GraphGridView.fromBytes(Uint8List.sublistView(shifted, 4));
      expect(view.copied, isTrue);
      expect(
        [view.runMembers, view.nodeRows],
        [
          [2, 1, 3, 0],
          [3, -1, -1, 0, 1],
        ],
      );
    });

    test('every_malformed_version_2_header_is_a_format_exception', () {
      final Uint8List bytes = stackGrid();
      expect(() => GraphGridView.fromBytes(Uint8List.sublistView(bytes, 0, 183)), refused, reason: 'short header');
      expect(() => GraphGridView.fromBytes(withSlot(bytes, 0, 3)), refused, reason: 'version');
      expect(() => GraphGridView.fromBytes(withSlot(bytes, 33, -1)), refused, reason: 'negative S');
      expect(() => GraphGridView.fromBytes(withSlot(bytes, 33, 2)), refused, reason: 'S ≠ the node arrays');
      expect(() => GraphGridView.fromBytes(withSlot(bytes, 34, 3)), refused, reason: 'R ≠ the run arrays');
      expect(() => GraphGridView.fromBytes(withSlot(bytes, 35, 5)), refused, reason: 'M ≠ the members');
      expect(() => GraphGridView.fromBytes(withSlot(bytes, 37, 3)), refused, reason: 'node run count ≠ n');
      expect(() => GraphGridView.fromBytes(withSlot(bytes, 36, 180)), refused, reason: 'inside the header');
      expect(() => GraphGridView.fromBytes(withSlot(bytes, 36 + 2 * 4, 260)), refused, reason: 'unaligned');
      expect(
        () => GraphGridView.fromBytes(withSlot(bytes, 36 + 2 * 4, bytes.length)),
        refused,
        reason: 'out of bounds',
      );
      expect(() => GraphGridView.fromBytes(withSlot(bytes, 9, 136)), refused, reason: "version 1's first offset");
    });
  });
}
