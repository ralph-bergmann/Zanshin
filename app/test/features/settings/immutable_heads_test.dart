// SPDX-License-Identifier: MIT

import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/src/features/settings/immutable_heads.dart';
import 'package:zanshin/src/features/settings/settings_window_state.dart';
import 'package:zanshin/src/features/window/app_window_actions.dart';
import 'package:zanshin_core/zanshin_core.dart' show TopologyRef, TopologyRefKind;

void main() {
  group('splitRevsetUnion', () {
    test('splits at top-level | only, not inside parentheses or quotes', () {
      expect(splitRevsetUnion('builtin_immutable_heads() | present(develop) | heads(foo)'), <String>[
        'builtin_immutable_heads()',
        'present(develop)',
        'heads(foo)',
      ]);
      expect(splitRevsetUnion('(a | b) | description("x | y") | c'), <String>['(a | b)', 'description("x | y")', 'c']);
      expect(splitRevsetUnion('  '), isEmpty);
    });
  });

  group('ImmutableHeads', () {
    test('compose: all four built-ins write builtin_immutable_heads()', () {
      expect(const ImmutableHeads().compose(), 'builtin_immutable_heads()');
      expect(const ImmutableHeads().isDefault, isTrue);
    });

    test('compose: tags off writes the other three in the CLI order', () {
      const heads = ImmutableHeads(
        builtins: <String>{'untracked_remote_tags()', 'trunk()', 'untracked_remote_bookmarks()'},
      );
      expect(heads.compose(), 'trunk() | untracked_remote_bookmarks() | untracked_remote_tags()');
    });

    test('compose: built-ins, chips as present(<name>), other people, custom; none() when empty', () {
      const heads = ImmutableHeads(bookmarks: <String>['develop', 'my branch'], others: true, custom: ' heads(foo) ');
      expect(
        heads.compose(),
        'builtin_immutable_heads() | present(develop) | present("my branch") | (trunk().. & ~mine()) | heads(foo)',
      );
      expect(const ImmutableHeads(builtins: <String>{}).compose(), 'none()');
    });

    test('parse maps the terms onto the controls; unset is the default', () {
      expect(
        ImmutableHeads.parse('builtin_immutable_heads() | present(develop) | heads(foo)'),
        const ImmutableHeads(bookmarks: <String>['develop'], custom: 'heads(foo)'),
      );
      expect(ImmutableHeads.parse(null), const ImmutableHeads());
      expect(
        ImmutableHeads.parse(
          'trunk() | release | trunk()..&~mine() | none() | a & b | heads(c)',
          bookmarks: const <String>['release'],
        ),
        const ImmutableHeads(
          builtins: <String>{'trunk()'},
          bookmarks: <String>['release'],
          others: true,
          custom: 'a & b | heads(c)',
        ),
      );
    });

    test('a parsed alias composes back to itself', () {
      const alias = 'trunk() | tags() | present(develop) | (trunk().. & ~mine()) | heads(foo)';
      expect(ImmutableHeads.parse(alias).compose(), alias);
    });

    test('a bare symbol is a chip only when it is a known local bookmark; anything else stays custom', () {
      expect(
        ImmutableHeads.parse('@- | main@origin | develop | v1.0', bookmarks: const <String>['develop']),
        const ImmutableHeads(builtins: <String>{}, bookmarks: <String>['develop'], custom: '@- | main@origin | v1.0'),
      );
    });
  });

  test('tomlStringValue reads multi-line strings; the newline after the opening delimiter goes', () {
    expect(tomlStringValue("'''\ntrunk() | tags()'''"), 'trunk() | tags()');
    expect(tomlStringValue('"""\ntrunk() |\\n tags()"""'), 'trunk() |\n tags()');
    expect(tomlStringValue('"""a "b" c"""'), 'a "b" c');
  });

  test("tomlString escapes a basic string when the text holds both ' and \"", () {
    expect(tomlString('main'), '"main"');
    expect(tomlString('description("x")'), '\'description("x")\'');
    expect(
      tomlString('a\'b"c\\d'),
      r'"a'
      "'"
      r'b\"c\\d"',
    );
  });

  test('tomlStringValue reads basic and literal strings; anything else is null', () {
    expect(tomlStringValue('"main@origin"'), 'main@origin');
    expect(tomlStringValue(r'"a \"b\" é"'), 'a "b" é');
    expect(tomlStringValue("'x|y'"), 'x|y');
    expect(tomlStringValue('["origin", "upstream"]'), isNull);
    expect(tomlStringValue('42'), isNull);
    expect(tomlStringValue(null), isNull);
  });

  group('SettingsWindowState', () {
    test('Project only while a project is open; a project closing shows General; the page belongs to Project', () {
      final state = SettingsWindowState();
      addTearDown(state.dispose);
      state.selectTab(SettingsTab.project);
      expect(state.tab, SettingsTab.general, reason: 'no project');

      state
        ..projectOpen = true
        ..show(SettingsTarget.immutableCommits);
      expect((state.tab, state.page), (SettingsTab.project, SettingsPage.immutableCommits));
      state.selectTab(SettingsTab.general);
      expect(state.page, isNull, reason: 'General hides the page');
      state.selectTab(SettingsTab.project);
      expect(state.page, SettingsPage.immutableCommits, reason: 'Project shows it again');

      state.windowClosed();
      expect((state.tab, state.page), (SettingsTab.project, null), reason: 'the tab survives a close, the page not');

      state.projectOpen = false;
      expect(state.tab, SettingsTab.general);
      state.show(SettingsTarget.project);
      expect(state.tab, SettingsTab.general, reason: 'no project: General');
    });
  });

  group('revset members', () {
    TopologyRef ref(
      String name, {
      TopologyRefKind kind = TopologyRefKind.bookmark,
      String? remote,
      bool synced = false,
    }) => TopologyRef(node: 0, kind: kind, name: name, remote: remote, synced: synced, conflicted: false);

    test('tags() names the local tags, deduplicated, in order', () {
      final members = <RevsetMember>[
        RevsetMember(
          refs: <TopologyRef>[
            ref('main'),
            ref('v1.0.0', kind: TopologyRefKind.tag),
          ],
        ),
        RevsetMember(
          refs: <TopologyRef>[
            ref('v1.4.2', kind: TopologyRefKind.tag),
            ref('v1.4.2', kind: TopologyRefKind.tag, remote: 'origin'),
            ref('v1.0.0', kind: TopologyRefKind.tag),
          ],
        ),
      ];
      expect(matchNames(members, 'tags()'), <String>['v1.0.0', 'v1.4.2']);
    });

    test('the untracked terms name remote refs of their kind, neither synced nor on git', () {
      final members = <RevsetMember>[
        RevsetMember(
          refs: <TopologyRef>[
            ref('main', remote: 'origin', synced: true),
            ref('release', remote: 'origin'),
            ref('x', remote: 'git'),
            ref('t1', kind: TopologyRefKind.tag, remote: 'upstream'),
          ],
        ),
      ];
      expect(matchNames(members, 'untracked_remote_bookmarks()'), <String>['release@origin']);
      expect(matchNames(members, 'untracked_remote_tags()'), <String>['t1@upstream']);
    });

    test('heads: local names, else remote, else root(), else the change id prefix', () {
      final members = <RevsetMember>[
        RevsetMember(
          refs: <TopologyRef>[
            ref('main'),
            ref('main', remote: 'origin', synced: true),
          ],
        ),
        RevsetMember(refs: <TopologyRef>[ref('v1.0.0', kind: TopologyRefKind.tag)]),
        RevsetMember(
          refs: <TopologyRef>[
            ref('x', remote: 'git'),
            ref('feat', remote: 'origin'),
          ],
        ),
        const RevsetMember(changeIdPrefix: 'zzzz', isRoot: true),
        const RevsetMember(changeIdPrefix: 'kxyz'),
        RevsetMember(refs: <TopologyRef>[ref('main')]),
      ];
      expect(headLabels(members), <String>['main', 'v1.0.0', 'feat@origin', 'root()', 'kxyz']);
    });

    test('nameList caps and counts the rest', () {
      final names = <String>['a', 'b', 'c', 'd', 'e', 'f', 'g'];
      expect(nameList(names, 5, (n) => '$n more'), <String>['a', 'b', 'c', 'd', 'e', '2 more']);
      expect(nameList(names.take(5).toList(), 5, (n) => '$n more'), <String>['a', 'b', 'c', 'd', 'e']);
    });
  });
}
