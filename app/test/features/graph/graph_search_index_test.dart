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
  bookmarks: <({String name, String key})>[
    for (var i = 0; i < 4; i++) (name: 'feat/cache-$i', key: 'kxkzzzzzz'),
  ],
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
        const GraphRecentGoTo('kx'),
        GraphRecentFilter(GraphFilter.files('a/b')),
      ]) {
        expect(GraphRecent.decode(recent.encode()), recent);
      }
      expect(GraphRecent.decode('[]'), isNull);
    });
  });

  test('build: local bookmarks by name, remote ones as name@remote, a null target skipped', () {
    final index = GraphSearchIndex.build(
      bookmarks: <Bookmark>[
        localBookmark('main', 'k1'),
        remoteBookmark('main', 'origin', 'k2'),
        localBookmark('gone', null),
      ],
    );
    expect(index.bookmarks, <({String name, String key})>[(name: 'main', key: 'k1'), (name: 'main@origin', key: 'k2')]);
  });

  group('suggestions', () {
    test('Any: Changes 3, Bookmarks 2, Authors 2, Files 3, Descriptions 1, each with "N more"', () {
      final GraphSuggestions s = suggestGraphSearch(
        GraphSearchIndex(
          changes: _changes(5, subject: 'a'),
          bookmarks: <({String name, String key})>[for (var i = 0; i < 4; i++) (name: 'a$i', key: 'k')],
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
