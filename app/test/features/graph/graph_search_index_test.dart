// SPDX-License-Identifier: MIT

import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/src/features/graph/graph_search_index.dart';
import 'package:zanshin/src/features/graph/graph_search_model.dart';
import 'package:zanshin_core/zanshin_core.dart';

import '../../helpers/fake_graph_search_source.dart';

/// [n] changes `kxa…`, each authored by "Author i" with the subject "fix cache i".
List<GraphSearchChange> _changes(int n, {String subject = 'fix cache'}) => <GraphSearchChange>[
  for (var i = 0; i < n; i++)
    GraphSearchChange(
      key: 'kx${String.fromCharCode(0x6b + i)}zzzzzz',
      commitId: 'c$i${'0' * 39}',
      prefixLength: 3,
      subject: '$subject $i',
      authorName: 'Author $i',
      authorEmail: 'a$i@x.org',
      timestampMs: i,
    ),
];

GraphSearchIndex _index({int changes = 5, List<String> paths = const <String>[], String? email}) => GraphSearchIndex(
  changes: _changes(changes),
  bookmarks: <GraphSearchRef>[for (var i = 0; i < 4; i++) GraphSearchRef('feat/cache-$i', 'kxkzzzzzz')],
  authors: <String, String>{for (var i = 0; i < 4; i++) 'Author $i': 'a$i@x.org', 'Lena König': 'lena@x.org'},
  paths: paths,
  userEmail: email,
);

void main() {
  group('prefixes', () {
    test('short and long forms switch the scope and strip the prefix', () {
      expect(parseGraphSearchPrefix('f: lib/'), (scope: GraphSearchScope.file, rest: 'lib/'));
      expect(parseGraphSearchPrefix('a:lena'), (scope: GraphSearchScope.author, rest: 'lena'));
      expect(parseGraphSearchPrefix('Commit:ab'), (scope: GraphSearchScope.change, rest: 'ab'));
      expect(parseGraphSearchPrefix('desc: x')?.scope, GraphSearchScope.description);
      expect(parseGraphSearchPrefix('bookmark:')?.scope, GraphSearchScope.bookmark);
      expect(parseGraphSearchPrefix('t:v1.'), (scope: GraphSearchScope.tag, rest: 'v1.'));
      expect(parseGraphSearchPrefix('Tag: v1'), (scope: GraphSearchScope.tag, rest: 'v1'));
      expect(GraphSearchScope.tag.prefix, 't:');
      expect(GraphSearchScope.tag.isGoTo, isTrue);
      expect(parseGraphSearchPrefix('lib/a: b'), isNull);
    });
  });

  group('filters', () {
    test('revsets and commands come from the builder, shell-quoted', () {
      final filter = GraphFilter.author('Lena König');
      expect(filter.revset, 'author(exact:"Lena König")');
      expect(filter.command, '''jj log -r 'author(exact:"Lena König")\'''');
      expect(GraphFilter.files('lib/').revset, 'files(cwd:"lib/")');
      expect(GraphFilter.files('*.md', pattern: RevsetPathPattern.glob).revset, 'files(glob:"*.md")');
      expect(GraphFilter.description('cache').revset, 'description(substring-i:"cache")');
      expect(const GraphFilter.mine('me@x.org').revset, 'mine()');
    });

    test('views and recent entries round-trip; unknown text reads as the default search', () {
      for (final view in <GraphShownView>[
        const GraphAllView(),
        const GraphLogView(),
        const GraphConfigView('c1'),
        GraphFilterView(GraphFilter.author('x', pattern: RevsetTextPattern.substring, ci: true)),
        const GraphFilterView(GraphFilter.mine('me@x.org')),
      ]) {
        expect(GraphShownView.decode(view.encode()), view);
      }
      expect(GraphShownView.decode(null), GraphShownView.defaultSearch);
      expect(GraphShownView.decode('{oops'), GraphShownView.defaultSearch);
      expect(
        GraphShownView.decode('{"filter":{"scope":"file","kind":"bogus","value":"x"}}'),
        GraphShownView.defaultSearch,
      );
      for (final recent in <GraphRecent>[
        const GraphRecentGoTo('kx', bookmark: 'main'),
        const GraphRecentGoTo('kx', bookmark: 'v1.4.2', tag: true),
        const GraphRecentGoTo('kx'),
        GraphRecentFilter(GraphFilter.files('a/b')),
      ]) {
        expect(GraphRecent.decode(recent.encode()), recent);
      }
      expect(const GraphRecentGoTo('kx', bookmark: 'main').encode(), isNot(contains('tag')));
      expect(const GraphRecentGoTo('kx', bookmark: 'v1', tag: true).encode(), contains('"tag":true'));
      expect(GraphRecent.decode('[]'), isNull);
    });
  });

  test('build: local refs by name, remote ones as name@remote; a null target and @git skipped, each shown once', () {
    final index = GraphSearchIndex.build(
      bookmarks: <Bookmark>[
        localBookmark('main', 'k1'),
        remoteBookmark('main', 'origin', 'k2'),
        remoteBookmark('main', 'git', 'k1'),
        remoteBookmark('rel', 'origin', 'k3', tracked: false),
        remoteBookmark('rel', 'origin', 'k3', tracked: false),
        localBookmark('gone', null),
      ],
      tags: <Tag>[
        localTag('v1.4.2', 'k1'),
        remoteTag('v1.5.0', 'origin', 'k2', tracked: false),
        remoteTag('v1.4.2', 'git', 'k1'),
        localTag('deleted', null),
      ],
    );
    expect(index.bookmarks, <GraphSearchRef>[
      const GraphSearchRef('main', 'k1'),
      const GraphSearchRef('main', 'k2', remote: 'origin'),
      const GraphSearchRef('rel', 'k3', remote: 'origin', tracked: false),
    ]);
    expect(index.bookmarks.map((r) => r.display), <String>['main', 'main@origin', 'rel@origin']);
    expect(index.tags, <GraphSearchRef>[
      const GraphSearchRef('v1.4.2', 'k1'),
      const GraphSearchRef('v1.5.0', 'k2', remote: 'origin', tracked: false),
    ]);
  });

  test('build: a synced remote row is left out, as plain jj bookmark list leaves it; ahead or untracked ones stay', () {
    final index = GraphSearchIndex.build(
      bookmarks: <Bookmark>[
        localBookmark('main', 'k1'),
        remoteBookmark('main', 'origin', 'k1', synced: true),
        localBookmark('dev', 'k2'),
        remoteBookmark('dev', 'origin', 'k1'),
        remoteBookmark('rel', 'origin', 'k3', tracked: false),
      ],
      tags: <Tag>[localTag('v1', 'k1'), remoteTag('v1', 'origin', 'k1', synced: true)],
    );
    expect(index.bookmarks.map((r) => r.display), <String>['main', 'dev', 'dev@origin', 'rel@origin']);
    expect(index.tags.map((r) => r.display), <String>['v1']);
  });

  group('Story 10.47: tags and the actions of a ref row', () {
    const index = GraphSearchIndex(
      bookmarks: <GraphSearchRef>[
        GraphSearchRef('feature/auth-flow', 'k1'),
        GraphSearchRef('main', 'k2', remote: 'origin'),
        GraphSearchRef('release/1.4.x', 'k3', remote: 'origin', tracked: false),
      ],
      tags: <GraphSearchRef>[
        GraphSearchRef('v1.4.2', 'k1'),
        GraphSearchRef('v1.5.0-rc1', 'k2'),
        GraphSearchRef('v1.5.0', 'k3', remote: 'origin', tracked: false),
      ],
    );

    GraphBookmarkRow row(GraphSearchScope scope, String q) =>
        suggestGraphSearch(index, scope, q).rows.whereType<GraphBookmarkRow>().first;

    test('t:v1. lists the tags with the match; Any groups 2 + "1 more in Tag"', () {
      final List<GraphBookmarkRow> tags = suggestGraphSearch(
        index,
        GraphSearchScope.tag,
        'v1.',
      ).rows.whereType<GraphBookmarkRow>().toList();
      expect(tags.map((r) => r.name), <String>['v1.4.2', 'v1.5.0-rc1', 'v1.5.0@origin']);
      expect(tags.every((r) => r.tag), isTrue);
      expect(tags.first.match, (0, 3));
      final GraphSearchGroup any = suggestGraphSearch(
        index,
        GraphSearchScope.any,
        'v1',
      ).groups.singleWhere((g) => g.scope == GraphSearchScope.tag);
      expect(any.rows.whereType<GraphBookmarkRow>(), hasLength(2));
      expect((any.rows.last as GraphMoreRow).count, 1);
      expect((any.rows.last as GraphMoreRow).scope, GraphSearchScope.tag);
    });

    test('New runs jj new on the ref; Track only on an untracked remote ref', () {
      final GraphBookmarkRow local = row(GraphSearchScope.bookmark, 'feature/auth');
      expect(local.newAction!.command, 'jj new feature/auth-flow');
      expect(local.newAction!.revsets, <String>['feature/auth-flow']);
      expect(local.newAction!.revsetTarget, 'k1');
      expect(local.trackAction, isNull, reason: 'a local ref');
      final GraphBookmarkRow tracked = row(GraphSearchScope.bookmark, 'main');
      expect(tracked.newAction!.command, 'jj new main@origin');
      expect(tracked.trackAction, isNull, reason: 'already tracked');
      final GraphBookmarkRow untracked = row(GraphSearchScope.bookmark, 'rel');
      expect(untracked.trackAction!.command, 'jj bookmark track release/1.4.x@origin');
      final GraphBookmarkRow tag = row(GraphSearchScope.tag, 'v1.5.0@');
      expect(tag.newAction!.command, 'jj new v1.5.0@origin');
      expect(tag.trackAction!.command, 'jj tag track v1.5.0@origin');
      const gone = GraphBookmarkRow('old-name', 'k9', score: 0);
      expect(gone.newAction, isNull, reason: 'a Recent entry whose ref is gone');
      expect(gone.trackAction, isNull);
    });
  });

  group('suggestions', () {
    test('Any: Changes 3, Bookmarks 2, Tags 2, Authors 2, Files 3, Descriptions 1, each with "N more"', () {
      final GraphSuggestions s = suggestGraphSearch(
        GraphSearchIndex(
          changes: _changes(5, subject: 'a'),
          bookmarks: <GraphSearchRef>[for (var i = 0; i < 4; i++) GraphSearchRef('a$i', 'k')],
          tags: <GraphSearchRef>[for (var i = 0; i < 3; i++) GraphSearchRef('va$i', 'k')],
          authors: <String, String>{for (var i = 0; i < 4; i++) 'a$i': 'e$i'},
          paths: const <String>['a1.txt', 'a2.txt', 'a3.txt', 'a4.txt'],
        ),
        GraphSearchScope.any,
        'a',
      );
      final groups = <GraphSearchScope, List<GraphSearchRow>>{for (final g in s.groups) g.scope: g.rows};
      expect(groups[GraphSearchScope.change]!.whereType<GraphChangeRow>(), hasLength(3));
      expect((groups[GraphSearchScope.change]!.last as GraphMoreRow).count, 2);
      expect(groups[GraphSearchScope.bookmark]!.whereType<GraphBookmarkRow>(), hasLength(2));
      expect((groups[GraphSearchScope.bookmark]!.last as GraphMoreRow).count, 2);
      expect(groups[GraphSearchScope.tag]!.whereType<GraphBookmarkRow>().map((r) => r.tag), <bool>[true, true]);
      expect((groups[GraphSearchScope.tag]!.last as GraphMoreRow).count, 1);
      expect(groups[GraphSearchScope.author]!.whereType<GraphFilterRow>(), hasLength(2));
      expect((groups[GraphSearchScope.author]!.last as GraphMoreRow).count, 2);
      expect(groups[GraphSearchScope.file]!.whereType<GraphFilterRow>(), hasLength(3));
      expect((groups[GraphSearchScope.file]!.last as GraphMoreRow).count, 1);
      expect(groups[GraphSearchScope.description], hasLength(1));
      expect(s.fallback, isFalse);
    });

    test('a single scope shows up to 8 rows; Author adds "containing" unless exactly one matches', () {
      final GraphSuggestions s = suggestGraphSearch(_index(changes: 12), GraphSearchScope.change, 'fix');
      expect(s.rows, hasLength(8));
      final GraphSuggestions authors = suggestGraphSearch(_index(), GraphSearchScope.author, 'author');
      expect(authors.rows.whereType<GraphFilterRow>().last.kind, GraphFilterRowKind.contains);
      final GraphSuggestions lena = suggestGraphSearch(_index(), GraphSearchScope.author, 'lena');
      expect(lena.rows.single, isA<GraphFilterRow>());
      expect((lena.rows.single as GraphFilterRow).filter.revset, 'author(exact:"Lena König")');
    });

    test('"you" is the author whose email is user.email, case-insensitively: mine()', () {
      final GraphSuggestions s = suggestGraphSearch(_index(email: 'LENA@x.org'), GraphSearchScope.author, 'lena');
      expect((s.rows.single as GraphFilterRow).filter.isMine, isTrue);
    });

    test('Description: the description row and up to 6 changes by subject', () {
      final GraphSuggestions s = suggestGraphSearch(_index(changes: 9), GraphSearchScope.description, 'cache');
      expect(s.groups.first.rows.single, isA<GraphFilterRow>());
      expect(s.groups.last.scope, GraphSearchScope.change);
      expect(s.groups.last.rows, hasLength(6));
    });

    test('no match in a scope: the note leads to Any; no match anywhere: nothing (Any keeps its description row)', () {
      final GraphSuggestions fallback = suggestGraphSearch(_index(), GraphSearchScope.bookmark, 'author 1');
      expect(fallback.fallback, isTrue);
      expect(fallback.groups, isNotEmpty);
      final GraphSuggestions none = suggestGraphSearch(const GraphSearchIndex(), GraphSearchScope.file, 'zzz');
      expect(none.groups, isEmpty);
      expect(none.fallback, isFalse);
      expect(
        suggestGraphSearch(const GraphSearchIndex(), GraphSearchScope.any, 'zzz').rows.single,
        isA<GraphFilterRow>(),
      );
    });

    test('files: folders and paths, a glob row for wildcards; an id prefix ranks first', () {
      final GraphSuggestions s = suggestGraphSearch(
        _index(paths: <String>['lib/a/x.dart', 'lib/b.dart']),
        GraphSearchScope.file,
        'lib',
      );
      expect((s.rows.first as GraphFilterRow).kind, GraphFilterRowKind.dir);
      expect((s.rows.first as GraphFilterRow).filter.revset, 'files(cwd:"lib/")');
      final GraphSuggestions glob = suggestGraphSearch(_index(), GraphSearchScope.file, '*.md');
      expect((glob.rows.single as GraphFilterRow).filter.revset, 'files(glob:"*.md")');
      final GraphSuggestions id = suggestGraphSearch(_index(), GraphSearchScope.any, 'kxk');
      expect((id.groups.first.rows.first as GraphChangeRow).how, GraphChangeMatch.id);
    });

    test('a refusal row leads the changes', () {
      final GraphSuggestions s = suggestGraphSearch(
        _index(),
        GraphSearchScope.change,
        'kx',
        refusal: 'Change ID prefix `kx` is ambiguous',
      );
      expect(s.rows.first, isA<GraphRefusalRow>());
    });
  });
}
