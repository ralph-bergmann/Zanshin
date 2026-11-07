// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:flutter/gestures.dart' show PointerDeviceKind, kSecondaryMouseButton;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/src/features/settings/config_file_page.dart';
import 'package:zanshin/src/features/settings/immutable_heads.dart' show immutableHeadsKey;
import 'package:zanshin/src/features/settings/settings_window_state.dart';
import 'package:zanshin/src/features/window/app_window_actions.dart';
import 'package:zanshin_core/zanshin_core.dart';

import '../../helpers/icon_registry.dart';
import '../../helpers/settings_rig.dart';

const _userPath = '/Users/me/.config/jj/config.toml';
const _repoPath = '/Users/me/.config/jj/repos/abc/config.toml';
const _userText = '[ui]\npager = "less -FRX"\n';

extension on SettingsRig {
  /// The page's one text field, the editor.
  Finder get editor => find.byType(EditableText);

  String get editorText => tester.widget<EditableText>(editor).controller.text;

  /// The Settings window on [target] with Edit… pressed.
  Future<void> openConfig({SettingsTarget target = SettingsTarget.general}) async {
    env.configFileTexts[ConfigScope.user] ??= _userText;
    await pump(target: target);
    await tap('settings-config-edit');
  }

  Future<void> edit(String text) async {
    await tester.enterText(editor, text);
    await settle();
  }

  /// Taps [button] in the Discard sheet and lets the sheet leave.
  Future<void> answer(String button) async {
    await tester.tap(find.text(button).last);
    await tester.pumpAndSettle();
  }

  /// Lets "✓ Saved" go.
  Future<void> afterSaved() => tester.pump(const Duration(seconds: 2));
}

void main() {
  setUpIconRegistry();

  group('ConfigParseFailure', () {
    test("maps jj's byte span onto the draft's characters, past non-ASCII text", () {
      const draft = 'name = "Rälph"\nx = y';
      final ConfigParseFailure failure = ConfigParseFailure.of(
        const ZanshinFfiException('jj.config_parse_error', '20..21\ninvalid string\nexpected `"`, `\'`'),
        draft,
      )!;

      expect(failure.range, const TextRange(start: 19, end: 20));
      expect(failure.range!.textInside(draft), 'y');
      expect((failure.line, failure.column), (2, 5));
      expect(failure.message, 'invalid string\nexpected `"`, `\'`');
    });

    test('a span on the first line; a context without a span is only the message; other codes are none', () {
      final ConfigParseFailure failure = ConfigParseFailure.of(
        const ZanshinFfiException('jj.config_parse_error', '8..12\ninvalid string'),
        'pager = less',
      )!;
      expect((failure.line, failure.column, failure.range), (1, 9, const TextRange(start: 8, end: 12)));

      final ConfigParseFailure bare = ConfigParseFailure.of(
        const ZanshinFfiException('jj.config_parse_error', 'expected newline'),
        'a = 1 2',
      )!;
      expect((bare.message, bare.range, bare.line), ('expected newline', null, null));

      expect(ConfigParseFailure.of(const ZanshinFfiException('jj.config_error', 'nope'), ''), isNull);
    });
  });

  group('SettingsWindowState', () {
    test('a config page per tab; leaving one with edits asks, a refusal stays, a left page closes', () async {
      final answers = <bool>[false, true];
      var asked = 0;
      final state = SettingsWindowState()
        ..projectOpen = true
        ..confirmDiscard = () async {
          asked++;
          return answers.removeAt(0);
        };
      addTearDown(state.dispose);

      state.openPage(SettingsPage.configFile);
      expect((state.tab, state.page), (SettingsTab.general, SettingsPage.configFile));
      state.selectTab(SettingsTab.project);
      expect((state.tab, state.page), (SettingsTab.project, null), reason: 'no edits: it just leaves, and closes');
      state.selectTab(SettingsTab.general);
      expect(state.page, isNull, reason: 'coming back shows the tab');

      state
        ..openPage(SettingsPage.configFile)
        ..editing = true
        ..selectTab(SettingsTab.project);
      await Future<void>.delayed(Duration.zero);
      expect((asked, state.tab, state.page), (1, SettingsTab.general, SettingsPage.configFile), reason: 'Cancel');

      state.show(SettingsTarget.project);
      await Future<void>.delayed(Duration.zero);
      expect((asked, state.tab, state.page), (2, SettingsTab.project, null), reason: 'Discard');
      expect(state.editing, isFalse);
    });

    test('an entry point staying on the page does not ask; a closed window and a closed project drop the pages', () {
      final state = SettingsWindowState()
        ..projectOpen = true
        ..confirmDiscard = () => throw StateError('asked');
      addTearDown(state.dispose);

      state
        ..openPage(SettingsPage.configFile)
        ..editing = true
        ..show(SettingsTarget.general);
      expect(state.page, SettingsPage.configFile);

      state.windowClosed();
      expect((state.page, state.editing), (null, false));

      state
        ..selectTab(SettingsTab.project)
        ..openPage(SettingsPage.configFile)
        ..editing = true
        ..projectOpen = false;
      expect((state.tab, state.page, state.editing), (SettingsTab.general, null, false));
    });
  });

  group('the Config file page', () {
    testWidgets("General › Edit… shows the user file's exact text, Save and Revert off; no Edit… on the page", (
      tester,
    ) async {
      final rig = SettingsRig(tester);
      await rig.openConfig();

      expect(rig.state.page, SettingsPage.configFile);
      expect(find.text('Config file'), findsWidgets);
      expect(find.text(_userPath), findsOneWidget, reason: "the well's bar");
      expect(rig.editorText, _userText);
      expect(find.text('1\n2\n3', findRichText: true), findsOneWidget, reason: 'line numbers, the last line empty');
      expect(rig.id('settings-config-edit'), findsNothing);
      expect(find.bySemanticsLabel(RegExp('^Contents of $_userPath')), findsOneWidget);

      await rig.tap('settings-config-save');
      await rig.tap('settings-config-revert');
      expect(rig.env.configFileWrites, isEmpty, reason: 'both off while nothing changed');
    });

    testWidgets('Project › Edit… edits the repo file', (tester) async {
      final rig = SettingsRig(tester);
      rig.env.configFileTexts[ConfigScope.repo] = '[revset-aliases]\n';
      await rig.openConfig(target: SettingsTarget.project);

      expect(find.text(_repoPath), findsOneWidget);
      expect(rig.editorText, '[revset-aliases]\n');
      expect(find.textContaining('jj’s settings for zanshin only', findRichText: true), findsOneWidget);
    });

    testWidgets('a failed read shows its text and no editor', (tester) async {
      final rig = SettingsRig(tester);
      rig.env.configFileReadFailure = const ZanshinFfiException('jj.config_error', 'Permission denied');
      await rig.openConfig();

      expect(find.text('Permission denied'), findsOneWidget);
      expect(rig.id('settings-config-editor'), findsNothing);
    });

    testWidgets('Save writes the draft to the path read, shows Saved, re-reads the rows and tells the graph', (
      tester,
    ) async {
      final rig = SettingsRig(tester);
      var writes = 0;
      rig.env.configWrites.addListener(() => writes++);
      rig.env.onConfigFileWrite = (path, text) => rig.env.configEntries['user.name'] = <ConfigEntry>[
        const ConfigEntry(
          name: 'user.name',
          value: '"Ralph"',
          source: ConfigValueSource.user,
          path: null,
          overridden: false,
        ),
      ];
      await rig.openConfig();

      await rig.edit('[user]\nname = "Ralph"\n');
      expect(find.text('Edited'), findsOneWidget);
      await rig.tap('settings-config-save');

      expect(rig.env.configFileWrites, <String>['$_userPath [user]\nname = "Ralph"\n']);
      expect(find.text('Saved'), findsOneWidget);
      expect(find.text('Edited'), findsNothing);
      expect(writes, 1, reason: 'other windows read again');
      expect(rig.model.configChanges, 1);
      expect(rig.content.viewModel.stringValue('user.name', project: false), 'Ralph');
      expect(rig.state.editing, isFalse);

      await rig.afterSaved();
      expect(find.text('Saved'), findsNothing);
    });

    testWidgets(
      "a right click opens the DS text menu; its Undo reverts the editor's last edit",
      (tester) async {
        final rig = SettingsRig(tester);
        await rig.openConfig();
        // The undo history records an edit once its throttle (500 ms) has passed.
        await rig.edit('a = 1\n');
        await tester.pump(const Duration(seconds: 1));
        await rig.edit('a = 2\n');
        await tester.pump(const Duration(seconds: 1));

        final TestGesture mouse = await tester.startGesture(
          tester.getCenter(rig.editor),
          kind: PointerDeviceKind.mouse,
          buttons: kSecondaryMouseButton,
        );
        await mouse.up();
        await tester.pumpAndSettle();
        for (final label in <String>['Undo', 'Redo', 'Cut', 'Copy', 'Paste', 'Select all']) {
          expect(find.text(label), findsOneWidget, reason: label);
        }
        await tester.tap(find.text('Undo'));
        // The activation blink, then the command.
        await tester.pump(const Duration(milliseconds: 200));
        await tester.pumpAndSettle();
        expect(rig.editorText, 'a = 1\n');
      },
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    );

    testWidgets('⌘S saves', (tester) async {
      final rig = SettingsRig(tester);
      await rig.openConfig();
      await rig.edit('a = 1\n');

      await tester.sendKeyDownEvent(LogicalKeyboardKey.meta);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.meta);
      await rig.settle();

      expect(rig.env.configFileWrites, <String>['$_userPath a = 1\n']);
      await rig.afterSaved();
    });

    testWidgets("a parse error writes nothing and shows jj's message at its line and column; Show; Revert clears it", (
      tester,
    ) async {
      final rig = SettingsRig(tester);
      rig.env.configFileWriteFailure = const ZanshinFfiException(
        'jj.config_parse_error',
        '8..12\ninvalid string\nexpected `"`, `\'`',
      );
      await rig.openConfig();
      await rig.edit('pager = less');

      await rig.tap('settings-config-save');

      expect(rig.env.configFileWrites, isEmpty);
      expect(find.text('Not saved: line 1, column 9'), findsOneWidget);
      expect(find.text('invalid string\nexpected `"`, `\'`'), findsOneWidget);
      expect(
        find.text('jj only writes a file it can read back. Fix the marked spot, or Revert to the saved file.'),
        findsOneWidget,
      );
      expect(rig.id('settings-config-error'), findsOneWidget);
      final EditableText editor = tester.widget<EditableText>(rig.editor);
      expect(editor.focusNode.hasFocus, isTrue, reason: 'the caret goes to the spot');
      expect(editor.controller.selection, const TextSelection.collapsed(offset: 8));

      editor.controller.selection = const TextSelection.collapsed(offset: 0);
      await rig.tap('settings-config-show');
      expect(editor.controller.selection, const TextSelection.collapsed(offset: 8));

      await rig.tap('settings-config-revert');
      expect(rig.editorText, _userText);
      expect(rig.id('settings-config-error'), findsNothing);
    });

    testWidgets('a parse error without a span and another failure show "Not saved" and the text, nothing marked', (
      tester,
    ) async {
      final rig = SettingsRig(tester);
      rig.env.configFileWriteFailure = const ZanshinFfiException('jj.config_parse_error', 'expected newline');
      await rig.openConfig();
      await rig.edit('a = 1 2');

      await rig.tap('settings-config-save');
      expect(find.text('Not saved'), findsOneWidget);
      expect(find.text('expected newline'), findsOneWidget);
      expect(rig.id('settings-config-show'), findsNothing);

      rig.env.configFileWriteFailure = const ZanshinFfiException('jj.config_error', 'Permission denied');
      await rig.tap('settings-config-save');
      expect(find.text('Not saved'), findsOneWidget);
      expect(find.text('Permission denied'), findsOneWidget);
    });

    testWidgets('back with edits asks; Cancel stays with the edits; Discard leaves', (tester) async {
      final rig = SettingsRig(tester);
      await rig.openConfig();
      await rig.edit('a = 1\n');

      await rig.tap('settings-page-back');
      expect(find.text('Discard your edits to config.toml?'), findsOneWidget);
      expect(find.text('The file stays as you last saved it.'), findsOneWidget);
      await rig.answer('Cancel');
      expect(rig.state.page, SettingsPage.configFile);
      expect(rig.editorText, 'a = 1\n');

      await rig.tap('settings-page-back');
      await rig.answer('Discard edits');
      expect(rig.state.page, isNull);
      expect(rig.env.configFileWrites, isEmpty);
    });

    testWidgets('the other tab with edits asks first', (tester) async {
      final rig = SettingsRig(tester);
      await rig.openConfig();
      await rig.edit('a = 1\n');

      await tester.tap(find.descendant(of: rig.id('settings-tabs'), matching: find.text('zanshin')));
      await rig.settle();
      expect(find.text('Discard your edits to config.toml?'), findsOneWidget);
      await rig.answer('Discard edits');

      expect((rig.state.tab, rig.state.page), (SettingsTab.project, null));
      rig.state.selectTab(SettingsTab.general);
      await rig.settle();
      expect(rig.state.page, isNull, reason: 'the left page closed');
    });

    testWidgets('closing the window with edits asks; Cancel keeps it, Discard closes', (tester) async {
      final rig = SettingsRig(tester);
      await rig.openConfig();
      await rig.edit('a = 1\n');

      Future<void> closing = rig.content.close();
      await rig.settle();
      await rig.answer('Cancel');
      await closing;
      expect(rig.state.page, SettingsPage.configFile);

      closing = rig.content.close();
      await rig.settle();
      await rig.answer('Discard edits');
      await closing;
      expect(rig.state.page, isNull);
    });

    testWidgets('closing the project or quitting (the close guard) asks with edits, and only then', (tester) async {
      final rig = SettingsRig(tester);
      await rig.openConfig();

      expect(await rig.windows.mayClose(), isTrue, reason: 'no edits');
      expect(find.text('Discard your edits to config.toml?'), findsNothing);

      await rig.edit('a = 1\n');
      Future<bool> asking = rig.windows.mayClose();
      await rig.settle();
      expect(find.text('Discard your edits to config.toml?'), findsOneWidget);
      await rig.answer('Cancel');
      expect(await asking, isFalse);

      asking = rig.windows.mayClose();
      await rig.settle();
      await rig.answer('Discard edits');
      expect(await asking, isTrue);
    });

    testWidgets("the mark and Show follow the refused draft only; jj's message stays", (tester) async {
      final rig = SettingsRig(tester);
      rig.env.configFileWriteFailure = const ZanshinFfiException('jj.config_parse_error', '8..12\ninvalid string');
      await rig.openConfig();
      await rig.edit('pager = less');
      await rig.tap('settings-config-save');
      expect(rig.id('settings-config-show'), findsOneWidget);

      await rig.edit('pager = lesss');
      expect(rig.id('settings-config-show'), findsNothing);
      expect(find.text('invalid string'), findsOneWidget);
    });

    testWidgets('a page dropped with edits (re-keyed by a project switch) reports no edits', (tester) async {
      final rig = SettingsRig(tester);
      await rig.openConfig();
      await rig.edit('a = 1\n');
      expect(rig.state.editing, isTrue);

      await tester.runAsync(rig.session.closeProject);
      await rig.settle();
      expect(rig.state.editing, isFalse);
    });

    testWidgets('a change on disk shows without edits, and raises the notice with Reload over edits', (tester) async {
      final rig = SettingsRig(tester);
      await rig.openConfig();
      final StreamController<void> disk = rig.env.fileChangeControllers[_userPath]!;
      addTearDown(disk.close);

      rig.env.configFileTexts[ConfigScope.user] = 'b = 2\n';
      disk.add(null);
      await rig.settle();
      expect(rig.editorText, 'b = 2\n');
      expect(rig.id('settings-config-stale'), findsNothing);

      await rig.edit('c = 3\n');
      rig.env.configFileTexts[ConfigScope.user] = 'd = 4\n';
      disk.add(null);
      await rig.settle();
      expect(find.text('The file changed on disk while you edited it.'), findsOneWidget);
      expect(rig.editorText, 'c = 3\n');

      await rig.tap('settings-config-reload');
      expect(rig.editorText, 'd = 4\n');
      expect(rig.id('settings-config-stale'), findsNothing);
      expect(find.text('Edited'), findsNothing);
    });

    testWidgets('a saved alias reaches the Immutable commits page', (tester) async {
      final rig = SettingsRig(tester);
      const alias = '"trunk() | tags()"';
      rig.env.onConfigFileWrite = (path, text) => rig.env.configEntries[immutableHeadsKey] = <ConfigEntry>[
        ConfigEntry(
          name: immutableHeadsKey,
          value: alias,
          source: ConfigValueSource.repo,
          path: path,
          overridden: false,
        ),
      ];
      await rig.openConfig(target: SettingsTarget.project);
      expect(rig.state.page, SettingsPage.configFile);
      expect(find.text(_repoPath), findsOneWidget);
      expect(rig.editor, findsOneWidget);

      await rig.edit('[revset-aliases]\n"immutable_heads()" = $alias\n');
      await rig.tap('settings-config-save');
      await rig.afterSaved();
      await rig.tap('settings-page-back');
      expect(rig.state.page, isNull, reason: 'saved: no question');
      rig.state.openPage(SettingsPage.immutableCommits);
      await rig.settle();

      expect(rig.model.configChanges, 1);
      expect(find.textContaining('"immutable_heads()" = "trunk() | tags()"', findRichText: true), findsOneWidget);
    });
  });
}
