// SPDX-License-Identifier: MIT

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/src/features/graph/graph_gaps.dart';
import 'package:zanshin/src/features/graph/graph_layout.dart';
import 'package:zanshin/src/features/graph/layout_invariants.dart';
import 'package:zanshin/src/features/graph/recorded_graph_layout.dart';

import '../../../widgetbook/graph/graph_recordings.g.dart';
import '../../../widgetbook/graph/graph_stack_recordings.g.dart';
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
    expect(layout.missingCountOf(0), 1);
    expect(layout.missingCountOf(1), 0);
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

  test("Story 10.19: a collapsed stack node reports its oldest member's Missing parents (a constructed layout: the "
      'engine never groups a member with a Missing parent, docs/graph-layout.md §4.8)', () {
    final RecordedGraphLayout base = hugeStackLayout(3);
    final int stack = base.stackNodeOf(0)!;
    final int oldest = base.runMembersOf(0).first;
    final layout = RecordedGraphLayout(
      mode: base.mode,
      unit: base.unit,
      rows: base.rows,
      colCount: base.colCount,
      keys: <String>[for (var i = 0; i < base.nodeCount; i++) base.keyOf(i)],
      cols: Int32List.fromList(<int>[for (var i = 0; i < base.nodeCount; i++) base.colOf(i)]),
      nodeRows: Int32List.fromList(<int>[for (var i = 0; i < base.nodeCount; i++) base.rowOf(i)]),
      parentCounts: Int32List.fromList(<int>[for (var i = 0; i < base.nodeCount; i++) base.parentCountOf(i)]),
      elided: Uint8List(base.nodeCount)..[oldest] = 2,
      edgeChildren: Int32List.fromList(<int>[for (var k = 0; k < base.edgeCount; k++) base.childOf(k)]),
      edgeParents: Int32List.fromList(<int>[for (var k = 0; k < base.edgeCount; k++) base.parentOf(k)]),
      edgeKinds: <GraphEdgeKind>[for (var k = 0; k < base.edgeCount; k++) base.kindOf(k)],
      edgeShapes: <GraphEdgeShape>[for (var k = 0; k < base.edgeCount; k++) base.shapeOf(k)],
      runMembers: <List<int>>[base.runMembersOf(0)],
      runStackNodes: <int?>[stack],
    );
    expect(layout.missingCountOf(stack), 2);
    expect(layout.elidedOf(stack), isTrue);
    expect(graphGapCounts(layout).ends, 2, reason: 'the folded member is not counted twice');
  });

  test("the CLI-faithful design variant drops wq and makes vr's parent Missing", () {
    final RecordedGraphLayout layout = recording('design-cli-default compact greedy');
    expect(layout.nodeCount, 13);
    expect(layout.indexOfKey('wqnwkozp'), isNull);
    expect(layout.elidedOf(layout.indexOfKey('vruxwmqv')!), isTrue);
  });

  group('format 4 (Story 10.17)', () {
    test('fromSpec reads n + S nodes and the runs: folded members at −1, stack nodes with their own facts', () {
      final RecordedGraphLayout layout = stackRecording('design-default free default', inlineContent: false);
      final (String input, String output, _) = graphStackRecordings['design-default free default']!;
      final int n = ((jsonDecode(input) as Map<String, Object?>)['nodes']! as List<Object?>).length;
      final runs = (jsonDecode(output) as Map<String, Object?>)['runs']! as List<Object?>;
      expect(layout.runCount, runs.length);
      expect(layout.shownCount, n, reason: 'the stack nodes are not counted; folded members count as shown');
      expect(layout.nodeCount, n + layout.runCount, reason: 'every run of the default is collapsed here');
      for (var r = 0; r < layout.runCount; r++) {
        final run = runs[r]! as Map<String, Object?>;
        final List<int> members = layout.runMembersOf(r);
        expect(members, <int>[for (final Object? m in run['members']! as List<Object?>) m! as int]);
        final int stack = layout.stackNodeOf(r)!;
        expect(stack, run['node']);
        expect(layout.keyOf(stack), graphStackKey(layout.keyOf(members.first)));
        expect(layout.indexOfKey(graphStackKey(layout.keyOf(members.first))), stack);
        expect(layout.isStackNode(stack), isTrue);
        expect(layout.isFolded(stack), isFalse);
        expect(layout.runOf(stack), r);
        expect(layout.timestampOf(stack), layout.timestampOf(members.last), reason: 'the newest member’s');
        expect(layout.parentCountOf(stack), 1);
        expect(layout.isImmutable(stack), members.every(layout.isImmutable));
        for (final m in members) {
          expect(layout.runOf(m), r);
          expect(layout.isFolded(m), isTrue);
          expect((layout.rowOf(m), layout.colOf(m)), (-1, -1));
          expect(layout.placeOfKey(layout.keyOf(m)), stack);
          expect(layout.parentEdges(m), (start: layout.parentEdges(m).start, end: layout.parentEdges(m).start));
        }
      }
      expect(layout.placeOfKey('srkvzmop'), layout.indexOfKey('srkvzmop'), reason: 'a visible key is its own place');
      expect(layout.placeOfKey('absent'), isNull);
      expect(layout.changeIdPrefixLengthOf(0), lessThan(9), reason: 'the stack keys never lengthen a jj prefix');
    });

    test('an expanded run has no stack node; its members are laid out', () {
      final RecordedGraphLayout layout = stackRecording('design-default free expanded');
      expect(layout.runCount, greaterThan(0));
      for (var r = 0; r < layout.runCount; r++) {
        expect(layout.stackNodeOf(r), isNull);
        for (final int m in layout.runMembersOf(r)) {
          expect(layout.isFolded(m), isFalse);
          expect(layout.rowOf(m), greaterThanOrEqualTo(0));
          expect(layout.placeOfKey(layout.keyOf(m)), m);
        }
      }
      expect(layout.nodeCount, layout.shownCount);
    });

    test('an ungrouped layout has no runs', () {
      final RecordedGraphLayout layout = recording('design-default free compact');
      expect(layout.runCount, 0);
      expect(layout.runOf(0), isNull);
      expect(layout.isStackNode(0), isFalse);
      expect(layout.isFolded(0), isFalse);
    });

    test('a malformed format 4 output is refused', () {
      const input =
          '{"now_ms":0,"nodes":[{"id":"a","ts_ms":2,"is_root":false,"priority":0,"parents":[{"idx":1,"kind":"direct"}]},'
          '{"id":"b","ts_ms":1,"is_root":false,"priority":0,"parents":[]}]}';
      // A collapsed run that names no stack node.
      const output =
          '{"mode":"compact","order":"compact","unit":1,"rows":1,"lanes":1,"nodes":[null,null],"edges":[],'
          '"buckets":[],"runs":[{"members":[1,0],"state":"collapsed","node":null}]}';
      expect(() => RecordedGraphLayout.fromSpec(input, output), throwsFormatException);
    });

    test('every stack recording passes the hard invariants and I7 against its ungrouped recording', () {
      for (final String name in graphStackRecordings.keys) {
        final RecordedGraphLayout layout = stackRecording(name, inlineContent: false);
        expect(checkLayoutInvariants(layout), isEmpty, reason: name);
        final List<String> parts = name.split(' ');
        final RecordedGraphLayout ungrouped = recording('${parts[0]} ${parts[1]} compact');
        for (var i = 0; i < layout.nodeCount; i++) {
          if (layout.isFolded(i)) {
            continue;
          }
          // I7: a visible node or expanded member keeps its ungrouped column; a stack node takes its newest member's.
          final int at = layout.isStackNode(i)
              ? ungrouped.indexOfKey(layout.keyOf(layout.runMembersOf(layout.runOf(i)!).last))!
              : ungrouped.indexOfKey(layout.keyOf(i))!;
          expect(layout.colOf(i), ungrouped.colOf(at), reason: '$name: ${layout.keyOf(i)}');
        }
      }
    });
  });

  test('the medium-narrow recordings carry indirect edges and Missing stubs', () {
    final RecordedGraphLayout layout = recording('medium-narrow compact compact');
    expect(<GraphEdgeKind>{
      for (var e = 0; e < layout.edgeCount; e++) layout.kindOf(e),
    }, contains(GraphEdgeKind.indirect));
    expect(<bool>{for (var i = 0; i < layout.nodeCount; i++) layout.elidedOf(i)}, contains(true));
  });
}
