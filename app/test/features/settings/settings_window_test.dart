// SPDX-License-Identifier: MIT

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' show ThemeMode;
import 'package:zanshin/src/features/settings/immutable_heads.dart';
import 'package:zanshin/src/features/settings/settings_view_model.dart';
import 'package:zanshin/src/features/settings/settings_window_state.dart';
import 'package:zanshin/src/features/window/app_window_actions.dart';
import 'package:zanshin_core/zanshin_core.dart';
import 'package:zanshin_settings/zanshin_settings.dart';
import 'package:zanshin_ui/zanshin_ui.dart' show ZsNamiMark;

import '../../helpers/icon_registry.dart';
import '../../helpers/settings_rig.dart';

TopologyRef _ref(String name, {TopologyRefKind kind = TopologyRefKind.bookmark, String? remote, bool synced = false}) =>
    // A synced remote entry is tracked (synced = tracked AND agrees).
    TopologyRef(
      node: 0,
      kind: kind,
      name: name,
      remote: remote,
      synced: synced,
      conflicted: false,
      tracked: remote != null && synced,
    );

typedef _Rig = SettingsRig;

ConfigEntry _entry(String name, String value, ConfigValueSource source) =>
    ConfigEntry(name: name, value: value, source: source, path: null, overridden: false);

void main() {
  setUpIconRegistry();

  group('General', () {
    testWidgets('the scope line names the user config; preferences write the store and the theme', (tester) async {
      final rig = _Rig(tester);
      await rig.pump(project: false);

      expect(find.textContaining('/Users/me/.config/jj/config.toml', findRichText: true), findsOneWidget);
      expect(find.textContaining('For Zanshin on this Mac', findRichText: true), findsOneWidget);
      expect(find.textContaining('View options', findRichText: true), findsOneWidget);

      await tester.tap(find.text('Night'));
      await rig.settle();
      expect(rig.themes, <ThemeMode>[ThemeMode.dark]);

      await tester.tap(find.text('Comfy'));
      await tester.tap(find.text('Zanshin'));
      await tester.tap(find.text('Side by side'));
      await rig.tap('settings-hide-controls');
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      expect(rig.store.value.appearance.density, DensitySetting.comfy);
      expect(rig.store.value.appearance.accentSource, AccentSource.zanshin);
      expect(rig.store.value.general.diffLayout, DiffLayoutSetting.sideBySide);
      expect(rig.store.value.general.hideControls, isFalse);
      expect(rig.calls, isEmpty, reason: 'app preferences are not jj config');
    });

    testWidgets('Name writes once at user scope on ↩; an unchanged blur writes nothing; the author fact shows', (
      tester,
    ) async {
      final rig = _Rig(tester);
      rig.env.configEntries['user.name'] = <ConfigEntry>[_entry('user.name', '"Ralph"', ConfigValueSource.user)];
      rig.env.workingCopyAuthor = const WorkingCopyAuthor(name: 'Ralph', email: 'old@example.com');
      var writes = 0;
      rig.env.configWrites.addListener(() => writes++);
      await rig.pump(target: SettingsTarget.general);

      await tester.tap(rig.field('settings-user-name'));
      await rig.settle();
      FocusManager.instance.primaryFocus?.unfocus();
      await rig.settle();
      expect(rig.calls, isEmpty, reason: 'the text is the value read');

      await rig.submit('settings-user-name', 'Ralph Stein');
      expect(rig.calls, <String>['set user user.name Ralph Stein']);
      expect(writes, 1, reason: 'the Projects footer reads again');
      expect(
        find.text('@ keeps the author Ralph <old@example.com>. jj metaedit --update-author changes it.'),
        findsOneWidget,
      );

      FocusManager.instance.primaryFocus?.unfocus();
      await rig.settle();
      expect(rig.calls, hasLength(1), reason: 'the blur after the write changes nothing');
    });

    testWidgets('a failed write shows its error on the row and keeps the text', (tester) async {
      final rig = _Rig(tester);
      rig.env.configFailure = const ZanshinFfiException('jj.config_error', 'Failed to write the config');
      await rig.pump(project: false);

      await rig.submit('settings-user-email', 'me@example.com');

      expect(find.text('Failed to write the config'), findsWidgets);
      expect(tester.widget<EditableText>(rig.field('settings-user-email')).controller.text, 'me@example.com');
    });
  });

  group('Project', () {
    testWidgets('the scope line names the repo config; Fetch from shows the CLI default, a list read-only', (
      tester,
    ) async {
      final rig = _Rig(tester);
      rig.env.configEntries['git.push'] = <ConfigEntry>[
        _entry('git.push', '["origin", "upstream"]', ConfigValueSource.repo),
      ];
      await rig.pump(target: SettingsTarget.project);

      expect(find.textContaining('For zanshin only', findRichText: true), findsOneWidget);
      expect(find.textContaining('/Users/me/.config/jj/repos/abc/config.toml', findRichText: true), findsOneWidget);
      expect(find.descendant(of: rig.id('settings-git-fetch'), matching: find.text('origin')), findsOneWidget);
      expect(find.text('["origin", "upstream"]'), findsOneWidget);
      expect(rig.id('settings-git-push'), findsNothing);
    });

    testWidgets('a Trunk pick writes <name>@<remote> at repo scope and re-requests the graph once', (tester) async {
      final rig = _Rig(tester);
      await rig.pump(target: SettingsTarget.project);

      await rig.tap('settings-trunk');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('main@origin'));
      // The picked row blinks before the menu closes and reports it.
      await tester.pump(const Duration(milliseconds: 500));
      await rig.settle();

      expect(rig.calls, <String>['set repo revset-aliases."trunk()" main@origin']);
      expect(rig.model.configChanges, 1);
    });

    testWidgets('the identity switch sets and unsets the repo email', (tester) async {
      final rig = _Rig(tester);
      rig.env.configEntries['user.email'] = <ConfigEntry>[
        _entry('user.email', '"ralph@example.com"', ConfigValueSource.user),
      ];
      await rig.pump(target: SettingsTarget.project);
      expect(find.text('From user config'), findsNothing, reason: 'no Email row while off');

      await rig.tap('settings-own-email');
      expect(rig.calls, <String>['set repo user.email ralph@example.com']);
      expect(rig.id('settings-project-email'), findsOneWidget);

      await rig.tap('settings-own-email');
      expect(rig.calls.last, 'unset repo user.email');
      expect(rig.id('settings-project-email'), findsNothing);
    });

    testWidgets('Check for remote changes writes the project entry', (tester) async {
      final rig = _Rig(tester);
      await rig.pump(target: SettingsTarget.project);

      await tester.tap(find.text('Off'));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await rig.settle();

      expect(rig.store.value.projects.projects.single.remotePoll, RemotePollSetting.off);
    });
  });

  group('Immutable commits', () {
    testWidgets('the navigation row opens the page; back and ⌘[ return; General hides it, Project shows it', (
      tester,
    ) async {
      final rig = _Rig(tester);
      await rig.pump(target: SettingsTarget.project);
      expect(find.text('14'), findsOneWidget, reason: 'the count beside the row');

      await rig.tap('settings-immutable-commits');
      expect(rig.state.page, SettingsPage.immutableCommits);
      expect(find.text('Immutable commits'), findsOneWidget);
      expect(find.bySemanticsLabel('Back to zanshin'), findsOneWidget);

      await rig.tap('settings-page-back');
      expect(rig.state.page, isNull);

      await rig.tap('settings-immutable-commits');
      await tester.tap(rig.field('settings-immutable-custom'));
      await rig.settle();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.meta);
      await tester.sendKeyEvent(LogicalKeyboardKey.bracketLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.meta);
      await rig.settle();
      expect(rig.state.page, isNull, reason: '⌘[ goes back');

      rig.state
        ..openPage(SettingsPage.immutableCommits)
        ..selectTab(SettingsTab.general);
      await rig.settle();
      expect(find.byKey(const ValueKey<String>('settings-immutable-toml')), findsNothing);
      rig.state.selectTab(SettingsTab.project);
      await rig.settle();
      expect(find.byKey(const ValueKey<String>('settings-immutable-toml')), findsOneWidget);
    });

    testWidgets('switches write the alias at repo scope, each re-requests the graph once; Reset unsets it', (
      tester,
    ) async {
      final rig = _Rig(tester);
      await rig.pump(target: SettingsTarget.immutableCommits);
      expect(rig.id('settings-immutable-reset'), findsNothing, reason: "jj's default");

      await rig.tap('settings-immutable-tags');
      expect(rig.calls, <String>[
        'set repo revset-aliases."immutable_heads()" trunk() | untracked_remote_bookmarks() | untracked_remote_tags()',
      ]);
      expect(rig.model.configChanges, 1);
      expect(
        find.textContaining('"immutable_heads()" = "trunk() | untracked_remote_bookmarks()', findRichText: true),
        findsOneWidget,
      );

      await rig.tap('settings-immutable-reset');
      expect(rig.calls.last, 'unset repo revset-aliases."immutable_heads()"');
      expect(rig.model.configChanges, 2);
    });

    testWidgets('the alias maps onto the controls; a chip and Other people write in order', (tester) async {
      final rig = _Rig(tester);
      rig.env.configEntries[immutableHeadsKey] = <ConfigEntry>[
        _entry(
          immutableHeadsKey,
          '"builtin_immutable_heads() | present(develop) | heads(foo)"',
          ConfigValueSource.repo,
        ),
      ];
      await rig.pump(target: SettingsTarget.immutableCommits);

      expect(rig.id('settings-immutable-chip-develop'), findsOneWidget);
      expect(tester.widget<EditableText>(rig.field('settings-immutable-custom')).controller.text, 'heads(foo)');

      await rig.tap('settings-immutable-others');
      expect(
        rig.calls.single,
        'set repo revset-aliases."immutable_heads()" '
        'builtin_immutable_heads() | present(develop) | (trunk().. & ~mine()) | heads(foo)',
      );
    });

    testWidgets('a custom revset jj cannot resolve shows its error and writes nothing', (tester) async {
      final rig = _Rig(tester);
      rig.reads.errors['bad(('] = const ZanshinFfiException('jj.revset_parse_error', 'Failed to parse revset');
      await rig.pump(target: SettingsTarget.immutableCommits);

      await rig.submit('settings-immutable-custom', 'bad((');

      expect(rig.calls, isEmpty);
      expect(find.text('Failed to parse revset'), findsWidgets);
    });

    testWidgets('a pending valid custom revset is written when the window closes; the page goes with it', (
      tester,
    ) async {
      final rig = _Rig(tester);
      await rig.pump(target: SettingsTarget.immutableCommits);

      await tester.enterText(rig.field('settings-immutable-custom'), 'heads(foo)');
      await tester.runAsync(rig.content.close);
      await rig.settle();

      expect(rig.calls, <String>['set repo revset-aliases."immutable_heads()" builtin_immutable_heads() | heads(foo)']);
      expect(rig.state.page, isNull);
      expect(rig.state.tab, SettingsTab.project);
    });

    testWidgets('a pending invalid custom revset is dropped when the window closes', (tester) async {
      final rig = _Rig(tester);
      rig.reads.errors['bad(('] = const ZanshinFfiException('jj.revset_parse_error', 'Failed to parse revset');
      await rig.pump(target: SettingsTarget.immutableCommits);

      await tester.enterText(rig.field('settings-immutable-custom'), 'bad((');
      await tester.runAsync(rig.content.close);
      await rig.settle();

      expect(rig.calls, isEmpty);
      expect(rig.state.page, isNull);
    });

    testWidgets('a capped count reads 10,000+', (tester) async {
      final rig = _Rig(tester);
      rig.reads.count = const RevsetCount(n: 10000, capped: true, error: null);
      await rig.pump(target: SettingsTarget.project);

      expect(find.text('10,000+'), findsOneWidget);
    });

    testWidgets('an alias from the user config hides Reset (jj config unset --repo cannot reach it)', (tester) async {
      final rig = _Rig(tester);
      rig.env.configEntries[immutableHeadsKey] = <ConfigEntry>[
        _entry(immutableHeadsKey, '"trunk()"', ConfigValueSource.user),
      ];
      await rig.pump(target: SettingsTarget.immutableCommits);

      expect(find.byKey(const ValueKey<String>('settings-immutable-toml')), findsOneWidget);
      expect(rig.id('settings-immutable-reset'), findsNothing);
    });

    testWidgets("the hints name this repository's matches; the heads stand under the count and follow a write", (
      tester,
    ) async {
      final rig = _Rig(tester);
      rig.reads.members
        ..['tags()'] = <RevsetMember>[
          RevsetMember(refs: <TopologyRef>[_ref('v1.0.0', kind: TopologyRefKind.tag)]),
          RevsetMember(refs: <TopologyRef>[_ref('v1.4.2', kind: TopologyRefKind.tag)]),
        ]
        ..['untracked_remote_bookmarks()'] = <RevsetMember>[]
        ..['untracked_remote_tags()'] = <RevsetMember>[]
        ..['immutable_heads()'] = <RevsetMember>[
          RevsetMember(
            refs: <TopologyRef>[
              _ref('main'),
              _ref('main', remote: 'origin', synced: true),
            ],
          ),
          RevsetMember(refs: <TopologyRef>[_ref('v1.0.0', kind: TopologyRefKind.tag)]),
          const RevsetMember(changeIdPrefix: 'kxyz'),
        ];
      await rig.pump(target: SettingsTarget.immutableCommits);

      expect(find.text('Released versions: v1.0.0, v1.4.2.'), findsOneWidget);
      expect(find.text('Fetched, but not yours to rewrite: none here.'), findsOneWidget);
      expect(find.text('None in this repository.'), findsOneWidget);
      expect(find.text('main · v1.0.0 · kxyz'), findsOneWidget);

      rig.reads.members['immutable_heads()'] = <RevsetMember>[
        RevsetMember(refs: <TopologyRef>[_ref('main')]),
      ];
      await rig.tap('settings-immutable-tags');
      final Finder heads = find.byKey(const ValueKey<String>('settings-immutable-heads'));
      expect(tester.widget<Text>(heads).data, 'main', reason: 'the heads line is read again with the count');

      rig.reads.members.remove('immutable_heads()');
      await rig.tap('settings-immutable-tags');
      expect(heads, findsNothing, reason: 'a failed re-read drops the heads line');
    });

    testWidgets('the remote hints name the untracked remote refs', (tester) async {
      final rig = _Rig(tester);
      rig.reads.members
        ..['untracked_remote_bookmarks()'] = <RevsetMember>[
          RevsetMember(refs: <TopologyRef>[_ref('release', remote: 'origin')]),
        ]
        ..['untracked_remote_tags()'] = <RevsetMember>[
          RevsetMember(
            refs: <TopologyRef>[_ref('t1', kind: TopologyRefKind.tag, remote: 'upstream')],
          ),
        ];
      await rig.pump(target: SettingsTarget.immutableCommits);

      expect(find.text('Fetched, but not yours to rewrite: release@origin.'), findsOneWidget);
      expect(find.text('Fetched, but not yours to move: t1@upstream.'), findsOneWidget);
    });

    testWidgets('an unread repository keeps the fixed hints and shows no heads line', (tester) async {
      final rig = _Rig(tester);
      await rig.pump(target: SettingsTarget.immutableCommits);

      expect(find.text('Released versions.'), findsOneWidget);
      expect(find.text('Fetched, but not yours to rewrite.'), findsOneWidget);
      expect(find.text('Fetched, but not yours to move.'), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('settings-immutable-result-count')), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('settings-immutable-heads')), findsNothing);
    });
  });

  testWidgets('the Project segment draws the Nami mark, no folder glyph', (tester) async {
    final rig = _Rig(tester);
    await rig.pump(target: SettingsTarget.project);

    final Finder tabs = rig.id('settings-tabs');
    expect(find.descendant(of: tabs, matching: find.byType(ZsNamiMark)), findsOneWidget);
    expect(tester.getSize(find.byType(ZsNamiMark)), const Size(14, 14));
    expect(
      tester.getRect(find.byType(ZsNamiMark)).right,
      lessThanOrEqualTo(tester.getRect(find.descendant(of: tabs, matching: find.text('zanshin'))).left),
    );
  });

  testWidgets('a switch to no project drops everything the project read', (tester) async {
    final rig = _Rig(tester);
    rig.env.configEntries['git.fetch'] = <ConfigEntry>[_entry('git.fetch', '"origin"', ConfigValueSource.repo)];
    rig.reads.members
      ..['tags()'] = <RevsetMember>[
        RevsetMember(refs: <TopologyRef>[_ref('v1.0.0', kind: TopologyRefKind.tag)]),
      ]
      ..['immutable_heads()'] = <RevsetMember>[
        RevsetMember(refs: <TopologyRef>[_ref('main')]),
      ];
    await rig.pump(target: SettingsTarget.project);
    final SettingsViewModel vm = rig.content.viewModel;
    expect(vm.projectConfig, isNotEmpty);
    expect(vm.remotes, isNotEmpty);
    expect(vm.immutableCount, isNotNull);
    expect(vm.builtinMatches, isNotEmpty);
    expect(vm.immutableHeadLabels, isNotNull);

    await tester.runAsync(rig.session.closeProject);
    await rig.settle();

    expect(vm.projectConfig, isEmpty);
    expect(vm.repoPath, isNull);
    expect(vm.remotes, isEmpty);
    expect(vm.fetchDefault, isEmpty);
    expect(vm.pushDefault, isEmpty);
    expect(vm.trunkChoices, isEmpty);
    expect(vm.bookmarks, isEmpty);
    expect(vm.immutableCount, isNull);
    expect(vm.builtinMatches, isEmpty);
    expect(vm.immutableHeadLabels, isNull);
    expect(rig.state.tab, SettingsTab.general);
  });
}
