// SPDX-License-Identifier: MIT

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/src/features/graph/graph_layout.dart';
import 'package:zanshin/src/features/graph/recorded_graph_layout.dart';

import '../../../widgetbook/graph/graph_recordings.g.dart';
import 'graph_harness.dart';

void main() {
  test('fromSpec joins the input view facts with the output geometry', () {
    const input =
        '{"now_ms":0,"utc_offset_min":120,"nodes":['
        '{"id":"c1","ts_ms":300,"is_root":false,"priority":0,"parents":[{"idx":1,"kind":"direct"},'
        '{"idx":2,"kind":"indirect"},{"idx":null,"kind":"missing"}],"key":"k1","parent_count":4,'
        '"working_copy":"this"},'
        '{"id":"c2","ts_ms":200,"is_root":false,"priority":0,"parents":[{"idx":2,"kind":"direct"}]},'
        '{"id":"c3","ts_ms":null,"is_root":true,"priority":0,"parents":[]}]}';
    const output =
        '{"mode":"free","order":"compact","unit":16,"rows":48,"lanes":2,"nodes":[{"row":32,"lane":1,"col":1},'
        '{"row":16,"lane":0,"col":0},{"row":0,"lane":0,"col":0}],"edges":['
        '{"from":1,"to":0,"kind":"direct","route":"branch_off","blocked":false},'
        '{"from":2,"to":0,"kind":"indirect","route":"merge","blocked":false},'
        '{"from":2,"to":1,"kind":"direct","route":"straight","blocked":false}],'
        '"buckets":[{"kind":"day","value":86400000,"start":0,"end":32}]}';
    final layout = RecordedGraphLayout.fromSpec(input, output);
    expect(layout.mode, GraphMode.free);
    expect(layout.unit, 16);
    expect(layout.rows, 48);
    expect(layout.colCount, 2);
    expect(layout.nodeCount, 3);
    expect(<String>[for (var i = 0; i < 3; i++) layout.keyOf(i)], <String>['k1', 'c2', 'c3']);
    expect(layout.indexOfKey('c2'), 1);
    expect(layout.indexOfKey('c1'), isNull, reason: 'the key wins over the id');
    expect(layout.colOf(0), 1);
    expect(layout.rowOf(1), 16);
    expect(layout.timestampOf(0), 300);
    expect(layout.timestampOf(2), isNull);
    expect(layout.parentCountOf(0), 4);
    expect(layout.parentCountOf(1), 1, reason: 'without parent_count, the parent entries');
    expect(layout.elidedOf(0), isTrue);
    expect(layout.elidedOf(1), isFalse);
    expect(layout.workingCopyIndex, 0);
    expect(layout.rootIndex, 2);
    expect(layout.utcOffsetMinutes, 120);
    expect(layout.shownCount, 3);
    expect(layout.totalCount, isNull);
    expect(layout.operationId, isNull);

    expect(layout.edgeCount, 3);
    expect(
      <GraphEdgeShape>[for (var e = 0; e < 3; e++) layout.shapeOf(e)],
      <GraphEdgeShape>[
        GraphEdgeShape.branchOff,
        GraphEdgeShape.merge,
        GraphEdgeShape.straight,
      ],
    );
    expect(layout.kindOf(1), GraphEdgeKind.indirect);
    expect(layout.parentEdges(0), (start: 0, end: 2));
    expect(layout.parentEdges(2), (start: 3, end: 3));
    final ({int start, int end}) children = layout.childEdges(2);
    expect(<int>[for (int s = children.start; s < children.end; s++) layout.childEdgeAt(s)], <int>[1, 2]);
    expect(layout.childEdges(0), (start: 0, end: 0));

    expect(layout.bucketCount, 1);
    expect(layout.bucketKindOf(0), GraphBucketKind.day);
    expect(layout.bucketValueOf(0), 86400000);
    expect(layout.bucketFirstRowOf(0), 0);
    expect(layout.bucketLastRowOf(0), 32);
  });

  test('two layouts never share a version', () {
    expect(recording('design-default free compact').version, isNot(recording('design-default free compact').version));
  });

  test('every recording joins: counts, the working copy of the design sample, CSR ranges over every edge', () {
    for (final String name in graphRecordingNames) {
      final (String input, String output) = graphRecordings[name]!;
      final layout = RecordedGraphLayout.fromSpec(input, output);
      final out = jsonDecode(output) as Map<String, Object?>;
      expect(layout.nodeCount, (out['nodes']! as List<Object?>).length, reason: name);
      expect(layout.edgeCount, (out['edges']! as List<Object?>).length, reason: name);
      if (name.startsWith('design-default') || name.startsWith('design-all')) {
        expect(layout.workingCopyIndex, isNotNull, reason: name);
      }
      var parentSlots = 0;
      var childSlots = 0;
      for (var i = 0; i < layout.nodeCount; i++) {
        final ({int start, int end}) up = layout.parentEdges(i);
        for (int e = up.start; e < up.end; e++) {
          expect(layout.childOf(e), i);
        }
        parentSlots += up.end - up.start;
        final ({int start, int end}) down = layout.childEdges(i);
        for (int s = down.start; s < down.end; s++) {
          expect(layout.parentOf(layout.childEdgeAt(s)), i);
        }
        childSlots += down.end - down.start;
      }
      expect(parentSlots, layout.edgeCount, reason: name);
      expect(childSlots, layout.edgeCount, reason: name);
    }
  });

  test("the CLI-faithful design variant drops wq and makes vr's parent Missing", () {
    final RecordedGraphLayout layout = recording('design-cli-default compact greedy');
    expect(layout.nodeCount, 13);
    expect(layout.indexOfKey('wqnwkozp'), isNull);
    expect(layout.elidedOf(layout.indexOfKey('vruxwmqv')!), isTrue);
  });

  test('the medium-narrow recordings carry indirect edges and Missing stubs', () {
    final RecordedGraphLayout layout = recording('medium-narrow compact compact');
    expect(<GraphEdgeKind>{
      for (var e = 0; e < layout.edgeCount; e++) layout.kindOf(e),
    }, contains(GraphEdgeKind.indirect));
    expect(<bool>{for (var i = 0; i < layout.nodeCount; i++) layout.elidedOf(i)}, contains(true));
  });
}
