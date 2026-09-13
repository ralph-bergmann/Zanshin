// SPDX-License-Identifier: MIT

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/src/features/projects/tree_drop.dart';

void main() {
  group('treeDropPlacement', () {
    TreeDropPlacement groupRow(double dy) => treeDropPlacement(dy: dy, rowExtent: 32, canHaveChildren: true);
    TreeDropPlacement leafRow(double dy) => treeDropPlacement(dy: dy, rowExtent: 32, canHaveChildren: false);

    test('rows that can hold children split into quarters', () {
      expect(
        [groupRow(0), groupRow(7.9), groupRow(8), groupRow(23.9), groupRow(24), groupRow(32)],
        [
          TreeDropPlacement.before,
          TreeDropPlacement.before,
          TreeDropPlacement.inside,
          TreeDropPlacement.inside,
          TreeDropPlacement.after,
          TreeDropPlacement.after,
        ],
      );
    });

    test('other rows split into halves', () {
      expect(
        [leafRow(0), leafRow(15.9), leafRow(16), leafRow(32)],
        [
          TreeDropPlacement.before,
          TreeDropPlacement.before,
          TreeDropPlacement.after,
          TreeDropPlacement.after,
        ],
      );
    });
  });

  group('insertion points', () {
    late TreeSliverNode<String> api;
    late TreeSliverNode<String> deep;
    late TreeSliverNode<String> sub;
    late TreeSliverNode<String> web;
    late TreeSliverNode<String> work;
    late TreeSliverNode<String> old;
    late TreeSliverNode<String> archive;
    late TreeSliverNode<String> empty;
    late TreeSliverNode<String> loose;
    late List<TreeSliverNode<String>> roots;

    // work (expanded): api, sub (collapsed): deep, web
    // archive (collapsed): old
    // empty
    // loose
    setUp(() {
      api = TreeSliverNode('api');
      deep = TreeSliverNode('deep');
      sub = TreeSliverNode('sub', children: [deep]);
      web = TreeSliverNode('web');
      work = TreeSliverNode('work', children: [api, sub, web], expanded: true);
      old = TreeSliverNode('old');
      archive = TreeSliverNode('archive', children: [old]);
      empty = TreeSliverNode('empty');
      loose = TreeSliverNode('loose');
      roots = [work, archive, empty, loose];
    });

    test('before a node takes its place', () {
      expect(
        treeInsertionPoint(roots, loose, TreeDropPlacement.before),
        const TreeInsertionPoint<String>(parent: null, index: 3, depth: 0),
      );
      expect(
        treeInsertionPoint(roots, web, TreeDropPlacement.before),
        TreeInsertionPoint(parent: work, index: 2, depth: 1),
      );
      expect(
        treeInsertionPoint(roots, deep, TreeDropPlacement.before),
        TreeInsertionPoint(parent: sub, index: 0, depth: 2),
      );
    });

    test('after a node goes right behind it', () {
      expect(
        treeInsertionPoint(roots, web, TreeDropPlacement.after),
        TreeInsertionPoint(parent: work, index: 3, depth: 1),
      );
      expect(
        treeInsertionPoint(roots, archive, TreeDropPlacement.after),
        const TreeInsertionPoint<String>(parent: null, index: 2, depth: 0),
      );
    });

    test('after an expanded node with children goes first inside it', () {
      expect(
        treeInsertionPoint(roots, work, TreeDropPlacement.after),
        TreeInsertionPoint(parent: work, index: 0, depth: 1),
      );
    });

    test('inside a node appends to its children', () {
      expect(
        treeInsertionPoint(roots, archive, TreeDropPlacement.inside),
        TreeInsertionPoint(parent: archive, index: 1, depth: 1),
      );
      expect(
        treeInsertionPoint(roots, empty, TreeDropPlacement.inside),
        TreeInsertionPoint(parent: empty, index: 0, depth: 1),
      );
      expect(
        treeInsertionPoint(roots, sub, TreeDropPlacement.inside),
        TreeInsertionPoint(parent: sub, index: 1, depth: 2),
      );
    });

    test('a node outside the tree is an argument error', () {
      expect(
        () => treeInsertionPoint(roots, TreeSliverNode('stranger'), TreeDropPlacement.before),
        throwsArgumentError,
      );
    });

    test('the append point is the end of the top level', () {
      expect(treeAppendPoint(roots), const TreeInsertionPoint<String>(parent: null, index: 4, depth: 0));
    });

    test('insertTreeNodes inserts in order at the point', () {
      final TreeSliverNode<String> a = TreeSliverNode('a');
      final TreeSliverNode<String> b = TreeSliverNode('b');
      insertTreeNodes(roots, TreeInsertionPoint(parent: work, index: 1, depth: 1), [a, b]);
      expect(work.children, [api, a, b, sub, web]);

      final TreeSliverNode<String> c = TreeSliverNode('c');
      insertTreeNodes(roots, treeAppendPoint(roots), [c]);
      expect(roots, [work, archive, empty, loose, c]);
    });
  });
}
