// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:zanshin/src/features/graph/graph_layout.dart';
import 'package:zanshin/src/features/graph/graph_ports.dart';
import 'package:zanshin_core/zanshin_core.dart';

import 'fake_content.dart';

/// The catalogue's [GraphSearchSource] (Story 10.21) over the `all()` recording [all]: counts are a deterministic
/// sample of each expression (every fifth one zero, a `files()` count capped), the lookups resolve a change-id prefix
/// against [all] (two hits are jj's ambiguity refusal), bookmarks are [all]'s refs, @'s paths a fixed tree, and
/// `user.email` is the design's first author. Each answer takes [latency].
class FakeGraphSearchSource implements GraphSearchSource {
  /// The search reads over [all].
  FakeGraphSearchSource(this.all, {this.latency = const Duration(milliseconds: 250)});

  /// The `all()` layout the lookups search.
  final GraphLayout Function() all;

  /// How long an answer takes.
  final Duration latency;

  @override
  Future<RevsetCounts> revsetCounts(String operationId, List<String> expressions, {required int cap}) async {
    await Future<void>.delayed(latency);
    return WarnedList<RevsetCount>(<RevsetCount>[
      for (final String e in expressions)
        // A `:::` is jj's syntax error at its third colon (Story 10.30), as the backend reports it.
        if (e.indexOf(':::') case final int at when at >= 0)
          RevsetCount(
            n: 0,
            capped: false,
            error: ZanshinFfiException.withReport(
              'jj.revset_parse_error',
              'Syntax error', // l10n-ignore: jj's message
              precondition: null,
              warnings: const <ZanshinWarning>[],
              revsetError: RevsetErrorDetail(
                kind: RevsetErrorKind.syntaxError,
                span: RevsetSpan(offset: at + 2, length: 0),
                symbol: null,
                candidates: const <String>[],
                message: 'Syntax error at ${at + 3}: expected <EOI>, `|`, `&`, or `~`', // l10n-ignore: jj's message
              ),
            ),
          )
        else if (e.startsWith('files(') && e.contains('cwd:'))
          RevsetCount(n: cap, capped: true, error: null)
        else
          RevsetCount(n: e.hashCode % 5 == 0 ? 0 : e.hashCode % 240 + 1, capped: false, error: null),
    ], const <ZanshinWarning>[]);
  }

  @override
  Future<FoundChanges> findChanges(
    String operationId,
    String expression, {
    required int limit,
    required String shortPrefixes,
  }) async {
    await Future<void>.delayed(latency);
    final GraphLayout layout = all();
    final hits = <FoundChange>[
      if (RegExp(r'^[a-z0-9]+$').hasMatch(expression))
        for (var node = 0; node < layout.nodeCount; node++)
          if (!layout.isStackNode(node) && layout.keyOf(node).startsWith(expression))
            FoundChange(
              commitId: layout.commitIdOf(node),
              changeId: layout.keyOf(node),
              commitPrefixLen: 7,
              changePrefixLen: layout.changeIdPrefixLengthOf(node),
            ),
    ];
    if (hits.length > 1) {
      throw ZanshinFfiException.withReport(
        'jj.revset_resolution_error',
        'Change ID prefix `$expression` is ambiguous', // l10n-ignore: jj's message
        precondition: null,
        warnings: const <ZanshinWarning>[],
        revsetError: RevsetErrorDetail(
          kind: RevsetErrorKind.ambiguousChangeIdPrefix,
          span: null,
          symbol: expression,
          candidates: const <String>[],
          message: 'Change ID prefix `$expression` is ambiguous', // l10n-ignore: jj's message
        ),
      );
    }
    return FoundChanges(entries: hits.take(limit).toList(), truncated: false, warnings: const <ZanshinWarning>[]);
  }

  @override
  Future<List<Bookmark>> bookmarks() async {
    final GraphLayout layout = all();
    return <Bookmark>[
      for (var node = 0; node < layout.nodeCount; node++)
        for (final GraphRef ref in layout.refsOf(node))
          if (ref.remote == null)
            Bookmark(
              name: ref.name,
              target: layout.keyOf(node),
              kind: const LocalBookmark(),
              conflicted: ref.conflicted,
              synced: ref.synced,
            ),
    ];
  }

  @override
  Future<List<String>> files() async => const <String>[
    'lib/features/settings/settings_page.dart',
    'lib/features/settings/cache_store.dart',
    'lib/features/graph/graph_view.dart',
    'lib/main.dart',
    'docs/api-reference.md',
    'README.md',
    'pubspec.yaml',
  ];

  @override
  Future<String?> userEmail() async => fakeContent(0, '').authorEmail;

  @override
  Future<Map<String, GraphCommitContent>> content(String? operationId, List<String> commitIds) async =>
      <String, GraphCommitContent>{for (final String id in commitIds) id: fakeContent(id.hashCode, id)};
}
