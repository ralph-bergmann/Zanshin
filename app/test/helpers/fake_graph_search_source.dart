// SPDX-License-Identifier: MIT

import 'package:zanshin/src/features/graph/graph_layout.dart';
import 'package:zanshin/src/features/graph/graph_ports.dart';
import 'package:zanshin_core/zanshin_core.dart';

/// A [GraphSearchSource] a test scripts: counts from [count], finds from [find] (either may throw), and records every
/// call.
class FakeGraphSearchSource implements GraphSearchSource {
  /// The count of an expression; 0 by default.
  RevsetCount Function(String expression) count = (_) => const RevsetCount(n: 0, capped: false, error: null);

  /// The answer to a find; nothing by default.
  FoundChanges Function(String expression, int limit) find = (_, _) =>
      const FoundChanges(entries: <FoundChange>[], truncated: false, warnings: <ZanshinWarning>[]);

  /// The bookmarks.
  var bookmarkList = <Bookmark>[];

  /// @'s paths.
  var paths = <String>[];

  /// `user.email`.
  String? email;

  /// The content of a found change.
  var foundContent = <String, GraphCommitContent>{};

  /// Every count call: its operation and expressions.
  final countCalls = <({String operationId, List<String> expressions})>[];

  /// Every find call: its operation and expression.
  final findCalls = <({String operationId, String expression})>[];

  @override
  Future<RevsetCounts> revsetCounts(String operationId, List<String> expressions, {required int cap}) async {
    countCalls.add((operationId: operationId, expressions: expressions));
    return WarnedList<RevsetCount>(<RevsetCount>[
      for (final String e in expressions) count(e),
    ], const <ZanshinWarning>[]);
  }

  @override
  Future<FoundChanges> findChanges(
    String operationId,
    String expression, {
    required int limit,
    required String shortPrefixes,
  }) async {
    findCalls.add((operationId: operationId, expression: expression));
    return find(expression, limit);
  }

  @override
  Future<List<Bookmark>> bookmarks() async {
    bookmarkReads++;
    return bookmarkList;
  }

  /// How many times `bookmarks()` was read.
  var bookmarkReads = 0;

  @override
  Future<List<String>> files() async => paths;

  @override
  Future<String?> userEmail() async => email;

  @override
  Future<Map<String, GraphCommitContent>> content(String? operationId, List<String> commitIds) async =>
      <String, GraphCommitContent>{
        for (final String id in commitIds)
          if (foundContent[id] case final GraphCommitContent c) id: c,
      };
}

/// A local bookmark [name] on [target].
Bookmark localBookmark(String name, String? target) =>
    Bookmark(name: name, target: target, kind: const LocalBookmark(), conflicted: false, synced: true);

/// A tracked remote bookmark [name]@[remote] on [target].
Bookmark remoteBookmark(String name, String remote, String target) => Bookmark(
  name: name,
  target: target,
  kind: RemoteBookmark(remote, tracked: true),
  conflicted: false,
  synced: true,
);
