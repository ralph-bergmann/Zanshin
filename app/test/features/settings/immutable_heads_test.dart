// SPDX-License-Identifier: MIT

import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/src/features/settings/immutable_heads.dart';
import 'package:zanshin/src/features/settings/settings_window_state.dart';
import 'package:zanshin/src/features/window/app_window_actions.dart';

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
}
