// SPDX-License-Identifier: MIT

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/src/features/graph/graph_focus.dart';
import 'package:zanshin/src/features/graph/recorded_graph_layout.dart';

import '../../../widgetbook/graph/synthetic_layout.dart';
import 'graph_harness.dart';

void main() {
  test('the focus set is the node, its ancestors and its descendants, not its siblings or cousins', () {
    // m merges b and c; b and c sit on a; d on c; x is a side branch on a; root under everything.
    //   m(0) → b(1), c(2); d(3) → c; b → a(4); c → a; x(5) → a; a → root(6)
    final RecordedGraphLayout layout = handLayout(
      const <(String, int, int)>[
        ('m', 4, 0),
        ('b', 3, 0),
        ('c', 3, 1),
        ('d', 4, 2),
        ('a', 2, 0),
        ('x', 3, 3),
        ('root', 0, 0),
      ],
      edges: const <(int, int)>[(0, 1), (0, 2), (3, 2), (1, 4), (2, 4), (5, 4), (4, 6)],
      root: 6,
    );
    Set<String> keys(Uint8List set) => <String>{
      for (var i = 0; i < set.length; i++)
        if (set[i] != 0) layout.keyOf(i),
    };
    expect(keys(graphFocusSet(layout, 2)), <String>{'c', 'm', 'd', 'a', 'root'});
    expect(keys(graphFocusSet(layout, 1)), <String>{'b', 'm', 'a', 'root'});
    expect(keys(graphFocusSet(layout, 4)), <String>{'a', 'b', 'c', 'm', 'd', 'x', 'root'});
    expect(keys(graphFocusSet(layout, 5)), <String>{'x', 'a', 'root'});
  });

  test('the focus set at 100k: the root reaches every node (timing printed, not gated)', () {
    final RecordedGraphLayout layout = syntheticLayout(100000);
    final int root = layout.rootIndex ?? layout.nodeCount - 1;
    final watch = Stopwatch()..start();
    final Uint8List set = graphFocusSet(layout, root);
    watch.stop();
    // ignore: avoid_print
    print('graphFocusSet(100k, root): ${watch.elapsedMicroseconds} µs');
    expect(set.length, layout.nodeCount);
    expect(set[root], isNonZero);
  });
}
