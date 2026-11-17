// SPDX-License-Identifier: MIT

// The windowing API is experimental and only reachable through implementation
// imports; see https://github.com/flutter/flutter/issues/30701.
// ignore_for_file: invalid_use_of_internal_member

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/src/foundation/_features.dart';
import 'package:flutter/src/widgets/_window.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' show ThemeMode;
import 'package:zanshin/src/features/settings/general_tab.dart';
import 'package:zanshin/src/features/settings/immutable_heads.dart';
import 'package:zanshin/src/features/settings/settings_view_model.dart';
import 'package:zanshin/src/features/settings/settings_widgets.dart' show SettingsRow;
import 'package:zanshin/src/features/settings/settings_window_state.dart';
import 'package:zanshin/src/features/window/app_window_actions.dart';
import 'package:zanshin/src/features/window/app_windows.dart';
import 'package:zanshin_core/zanshin_core.dart';
import 'package:zanshin_settings/zanshin_settings.dart';
import 'package:zanshin_ui/zanshin_ui.dart' show ZsAppearance, ZsDensity, ZsNamiMark, ZsRoot, ZsSwitch;

import '../../helpers/icon_registry.dart';
import '../../helpers/settings_rig.dart';
import '../../helpers/shell_host.dart';

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
      expect(rig.store.value.appearance.themeMode, ThemeMode.dark);

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

    testWidgets('Changed words: a switch, on by default, writes general.diffWordMarks and no jj config (Story 5.14)', (
      tester,
    ) async {
      final rig = _Rig(tester);
      await rig.pump(project: false);
      expect(rig.store.value.general.diffWordMarks, isTrue);
      expect(find.text('Changed words'), findsOneWidget);
      expect(find.text('Marks the words that changed inside a line, where jj diff underlines them.'), findsOneWidget);
      final Finder marks = find.byWidgetPredicate((w) => w is ZsSwitch && w.identifier == 'settings-diff-marks');
      expect(tester.widget<ZsSwitch>(marks).value, isTrue);
      for (final on in <bool>[false, true]) {
        await rig.tap('settings-diff-marks');
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await rig.settle();
        expect(rig.store.value.general.diffWordMarks, on);
      }
      expect(rig.calls, isEmpty, reason: 'an app preference, not jj config');
    });

    testWidgets(
      'Density says it is space only; the Zoom row offers the steps and writes appearance.zoom (Story 11.20)',
      (
        tester,
      ) async {
        final rig = _Rig(tester);
        await rig.pump(project: false);

        expect(find.text('Space between rows and cards. Text keeps its size.'), findsOneWidget);
        expect(find.text('Text and everything with it, in every window. ⌘+ ⌘− ⌘0'), findsOneWidget);
        expect(find.text('100% (Actual Size)'), findsOneWidget);

        await rig.tap('settings-zoom');
        await rig.settle();
        for (final label in <String>['90%', '110%', '125%', '150%']) {
          expect(find.text(label), findsOneWidget, reason: label);
        }
        await tester.tap(find.text('125%'));
        // The picked row blinks before it applies.
        await tester.pump(const Duration(seconds: 1));
        await rig.settle();
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        expect(rig.store.value.appearance.zoom, 125);
        expect(rig.calls, isEmpty, reason: 'an app preference, not jj config');
      },
    );

    testWidgets('a zoom change reaches the open window: its minimum becomes 620 × 420 × the zoom', (tester) async {
      final bool windowingWasEnabled = isWindowingEnabled;
      isWindowingEnabled = true;
      addTearDown(() => isWindowingEnabled = windowingWasEnabled);
      final rig = _Rig(tester);
      rig.windows.attach(WindowRegistry());
      final WindowEntry entry = await rig.windows.create(
        key: settingsWindowKey,
        title: 'General',
        builder: (_) => const SizedBox(),
        dialog: settingsWindowSpec,
      );
      addTearDown(entry.controller.destroy);
      await rig.pump(project: false);
      final window = entry.controller as DialogWindowController;

      await tester.runAsync(() => rig.store.update((s) => s.copyWith.appearance(zoom: 125)));
      await rig.settle();

      // The test controller keeps its constraints private; a request below them shows the minimum.
      window.setSize(Size.zero);
      expect(window.contentSize, const Size(775, 525));
    });

    testWidgets('a settings row gains the density step: its minimum and half the step above and below', (tester) async {
      Future<(double, double)> row(ZsDensity density, {String? hint}) async {
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: ZsRoot(
              appearance: ZsAppearance(density: density),
              // A column, as a settings group is: the row takes its own height.
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  SizedBox(
                    width: 500,
                    child: SettingsRow(
                      label: 'Label',
                      hint: hint,
                      child: const SizedBox(key: ValueKey<String>('control'), width: 40, height: 20),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
        final Rect rect = tester.getRect(find.byType(SettingsRow));
        return (rect.height, tester.getRect(find.text('Label')).top - rect.top);
      }

      expect((await row(ZsDensity.compact)).$1, 46);
      expect((await row(ZsDensity.comfy)).$1, 52, reason: 'min 46 + 6');
      final (double compactHeight, double compactTop) = await row(ZsDensity.compact, hint: 'A hint on its line.');
      final (double comfyHeight, double comfyTop) = await row(ZsDensity.comfy, hint: 'A hint on its line.');
      expect(comfyTop - compactTop, 3, reason: 'padding 8 + 3');
      expect(comfyHeight - compactHeight, 6, reason: 'a row with a hint grows too');
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

  group("Diffs: jj's color-words keys (Story 5.12)", () {
    const context = 'diff.color-words.context';
    const conflict = 'diff.color-words.conflict';
    const inline = 'diff.color-words.max-inline-alternation';
    const contextHint = 'Unchanged lines shown around each change.';
    const inlineHint =
        'How often a line may switch between removed and added words before it shows as an old and a new line. '
        'Experimental in jj.';

    // Opens the select [identifier] and picks the row [label].
    Future<void> pick(WidgetTester tester, _Rig rig, String identifier, String label) async {
      await rig.tap(identifier);
      await rig.settle();
      await tester.tap(find.text(label).last);
      // The picked row blinks before it applies.
      await tester.pump(const Duration(seconds: 1));
      await rig.settle();
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      // The list fades out.
      await tester.pump(const Duration(seconds: 1));
      await rig.settle();
    }

    double top(_Rig rig, String identifier) => rig.tester.getRect(rig.id(identifier)).top;

    // The General tab of [rig]'s window alone, its editors detected by [editors] (Story 10.39).
    Future<void> pumpGeneral(WidgetTester tester, _Rig rig, List<String> Function() editors) async {
      final SettingsViewModel vm = tester.widget<SettingsGeneralTab>(find.byType(SettingsGeneralTab)).vm;
      await tester.pumpWidget(
        shellHost(
          ListenableBuilder(
            // As the window does: the tab follows the view model and the store.
            listenable: Listenable.merge(<Listenable>[vm, rig.store]),
            builder: (context, _) => SingleChildScrollView(
              child: SettingsGeneralTab(vm: vm, editors: editors),
            ),
          ),
        ),
      );
      await rig.settle();
    }

    testWidgets("fresh config: jj's defaults, no source note, each row shows its key; no Conflicts row", (
      tester,
    ) async {
      final rig = _Rig(tester);
      await rig.pump(project: false);
      expect(find.text('3'), findsOneWidget, reason: 'Context lines');
      expect(find.text(contextHint), findsOneWidget);
      expect(find.text(context), findsOneWidget);
      expect(find.text('Up to 3'), findsOneWidget);
      expect(find.text(inline), findsOneWidget);
      expect(find.text(inlineHint), findsOneWidget);
      // Story 5.14: the diff still reads `diff.color-words.conflict`, but no row writes it.
      expect(find.text('Conflicts'), findsNothing);
      expect(find.text(conflict), findsNothing);
      expect(rig.id('settings-diff-conflict'), findsNothing);
      expect(rig.calls, isEmpty);
    });

    testWidgets('the rows run Layout, Whitespace, Changed words, Inline changes, Context lines', (tester) async {
      final rig = _Rig(tester);
      await rig.pump(project: false);
      final List<double> rows = <String>[
        'settings-diff-layout',
        'settings-diff-whitespace',
        'settings-diff-marks',
        'settings-diff-inline',
        'settings-diff-context',
      ].map((id) => top(rig, id)).toList();
      expect(rows, List<double>.of(rows)..sort());
      expect(rows.toSet(), hasLength(5));
    });

    group('Story 10.50: Code font and Code size', () {
      const builtIn = 'JetBrains Mono · built in';

      testWidgets('they sit right after Layout: the built-in font and 11 pt · default', (tester) async {
        final rig = _Rig(tester);
        await rig.pump(project: false);
        final List<double> rows = <String>[
          'settings-diff-layout',
          'settings-code-font',
          'settings-code-size',
          'settings-diff-whitespace',
        ].map((id) => top(rig, id)).toList();
        expect(rows, List<double>.of(rows)..sort());
        expect(rows.toSet(), hasLength(4));
        expect(find.text(builtIn), findsOneWidget);
        expect(find.text('11 pt · default'), findsOneWidget);
        expect(find.text('The monospaced fonts on this Mac.'), findsOneWidget);
        expect(find.text('Diffs and the config file. Zoom scales it like everything else.'), findsOneWidget);
      });

      testWidgets('a pick writes codeFont and codeSize; the built-in font writes null; no jj config', (tester) async {
        final rig = _Rig(tester);
        await rig.pump(project: false);

        await pick(tester, rig, 'settings-code-font', 'Menlo');
        expect(rig.store.value.general.codeFont, 'Menlo');
        await pick(tester, rig, 'settings-code-size', '14 pt');
        expect(rig.store.value.general.codeSize, 14);
        expect(find.text('14 pt'), findsOneWidget);
        await pick(tester, rig, 'settings-code-font', builtIn);
        expect(rig.store.value.general.codeFont, isNull);
        expect(rig.calls, isEmpty);
      });

      testWidgets('a saved font the Mac lacks shows as not installed and stays saved', (tester) async {
        final rig = _Rig(tester);
        await rig.pump(project: false);
        await tester.runAsync(() => rig.store.update((s) => s.copyWith.general(codeFont: 'Gone Mono')));
        await rig.settle();
        expect(find.text('Gone Mono (not installed) — using JetBrains Mono'), findsOneWidget);
        expect(rig.store.value.general.codeFont, 'Gone Mono');
      });

      testWidgets('while the list is unknown the saved font shows plain', (tester) async {
        final rig = _Rig(tester)..codeFamilies = null;
        await rig.pump(project: false);
        await tester.runAsync(() => rig.store.update((s) => s.copyWith.general(codeFont: 'Gone Mono')));
        await rig.settle();
        expect(find.text('Gone Mono'), findsOneWidget);
        expect(find.textContaining('not installed'), findsNothing);
      });

      testWidgets('a hand-edited size outside 6…72 shows as it draws, clamped', (tester) async {
        final rig = _Rig(tester);
        await rig.pump(project: false);
        await tester.runAsync(() => rig.store.update((s) => s.copyWith.general(codeSize: 500)));
        await rig.settle();
        expect(find.text('72 pt'), findsOneWidget);
        expect(find.text('500 pt'), findsNothing);
        expect(rig.store.value.general.codeSize, 500, reason: 'nothing is written');
      });

      testWidgets('an installed JetBrains Mono shows once, as the built-in font', (tester) async {
        final rig = _Rig(tester)..codeFamilies = const ['JetBrains Mono', 'Menlo'];
        await rig.pump(project: false);
        await rig.tap('settings-code-font');
        await rig.settle();
        expect(find.text('JetBrains Mono'), findsNothing);
        expect(find.text(builtIn), findsWidgets);
        expect(find.text('Menlo'), findsOneWidget);
      });

      testWidgets('an installed JetBrains Mono that is saved shows as itself', (tester) async {
        final rig = _Rig(tester)..codeFamilies = const ['JetBrains Mono', 'Menlo'];
        await rig.pump(project: false);
        await tester.runAsync(() => rig.store.update((s) => s.copyWith.general(codeFont: 'JetBrains Mono')));
        await rig.settle();
        expect(find.text('JetBrains Mono'), findsOneWidget);
      });

      testWidgets('the families show when the list arrives after the window settled', (tester) async {
        final families = Completer<List<String>?>();
        final rig = _Rig(tester)..codeFontReader = () => families.future;
        await rig.pump(project: false);
        await tester.runAsync(() => rig.store.update((s) => s.copyWith.general(codeFont: 'Gone Mono')));
        await rig.settle();
        expect(find.text('Gone Mono'), findsOneWidget, reason: 'the list is still unknown');

        families.complete(const ['Menlo']);
        await rig.settle();
        expect(find.text('Gone Mono (not installed) — using JetBrains Mono'), findsOneWidget);
      });

      testWidgets('a hand-edited size off the list shows, added in order', (tester) async {
        final rig = _Rig(tester);
        await rig.pump(project: false);
        await tester.runAsync(() => rig.store.update((s) => s.copyWith.general(codeSize: 17)));
        await rig.settle();
        expect(find.text('17 pt'), findsOneWidget);
        await rig.tap('settings-code-size');
        await rig.settle();
        final List<double> rows = <String>[
          '16 pt',
          '17 pt',
          '18 pt',
        ].map((label) => tester.getRect(find.text(label).last).top).toList();
        expect(rows, List<double>.of(rows)..sort());
        expect(rows.toSet(), hasLength(3));
      });
    });

    testWidgets('Story 10.33: Whitespace shows the app setting and writes it; no jj config', (tester) async {
      final rig = _Rig(tester);
      await rig.pump(project: false);
      expect(find.text('Show all whitespace'), findsOneWidget);

      await pick(tester, rig, 'settings-diff-whitespace', 'Ignore all whitespace');
      expect(rig.store.value.general.diffWhitespace, DiffWhitespaceSetting.ignoreAll);
      expect(find.text('Ignore all whitespace'), findsOneWidget);
      expect(rig.calls, isEmpty);
    });

    testWidgets('Story 10.39: File list writes general.diffFileList; no jj config', (tester) async {
      final rig = _Rig(tester);
      await rig.pump(project: false);
      expect(rig.store.value.general.diffFileList, DiffFileListSetting.flat);
      await tester.tap(find.text('Tree').last);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await rig.settle();
      expect(rig.store.value.general.diffFileList, DiffFileListSetting.tree);
      expect(rig.calls, isEmpty);
    });

    testWidgets(
      'Story 10.39: Editor offers None, the stored launcher and Custom; a command without {file} is refused',
      (
        tester,
      ) async {
        final rig = _Rig(tester);
        await rig.pump(project: false);
        // The tab again with a detection of its own, so nothing reads the host's PATH.
        await pumpGeneral(tester, rig, () => const <String>['idea']);
        expect(find.text('Open files in'), findsOneWidget);
        expect(find.text('None'), findsOneWidget, reason: 'no editor by default');
        expect(rig.id('settings-editor-command'), findsNothing);

        // A detected launcher is offered and written by its program.
        await pick(tester, rig, 'settings-editor', 'IntelliJ IDEA — idea');
        expect(rig.store.value.general.editor, 'idea');

        // A stored launcher shows even when it is not detected. The store has the value at once; the write queued behind
        // the last one ends in the rig's teardown.
        unawaited(rig.store.update((s) => s.copyWith.general(editor: 'zed')));
        await rig.settle();
        expect(find.text('Zed — zed'), findsOneWidget);

        await pick(tester, rig, 'settings-editor', 'Custom command');
        expect(rig.store.value.general.editor, 'zed', reason: 'Custom writes nothing until a command is committed');
        expect(find.text('{file} and {line} are replaced; IntelliJ: idea --line {line} {file}'), findsOneWidget);
        await rig.submit('settings-editor-command', 'subl');
        expect(find.text('The command must hold {file}.'), findsOneWidget);
        expect(rig.store.value.general.editor, 'zed');
        await rig.submit('settings-editor-command', 'subl {file}:{line}');
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await rig.settle();
        expect(rig.store.value.general.editor, 'subl {file}:{line}');
        expect(find.text('Custom command'), findsOneWidget);

        await pick(tester, rig, 'settings-editor', 'None');
        expect(rig.store.value.general.editor, isNull);
        expect(rig.id('settings-editor-command'), findsNothing);
        expect(rig.calls, isEmpty, reason: 'an app preference, not jj config');
      },
    );

    testWidgets('Story 10.33: the user config\'s context 5 shows in the Context lines row', (tester) async {
      final rig = _Rig(tester);
      rig.env.configEntries[context] = <ConfigEntry>[_entry(context, '5', ConfigValueSource.user)];
      await rig.pump(project: false);
      expect(find.text('5'), findsOneWidget);
    });

    testWidgets('a choice writes at user scope, defaults too, and the row shows it', (tester) async {
      final rig = _Rig(tester);
      await rig.pump(project: false);

      await pick(tester, rig, 'settings-diff-context', '10');
      await pick(tester, rig, 'settings-diff-inline', 'Never');
      await pick(tester, rig, 'settings-diff-inline', 'Always');

      expect(rig.calls, <String>[
        'set user $context 10',
        'set user $inline 0',
        'set user $inline -1',
      ]);
      expect(find.text('10'), findsOneWidget);
      expect(find.text('Always'), findsOneWidget);
    });

    testWidgets('an off-list value is its own option, in order, chosen', (tester) async {
      final rig = _Rig(tester);
      rig.env.configEntries[context] = <ConfigEntry>[_entry(context, '7', ConfigValueSource.user)];
      await rig.pump(project: false);
      expect(find.text('7'), findsOneWidget);

      await rig.tap('settings-diff-context');
      await rig.settle();
      final double five = tester.getRect(find.text('5').last).top;
      final double seven = tester.getRect(find.text('7').last).top;
      final double ten = tester.getRect(find.text('10').last).top;
      expect(five < seven && seven < ten, isTrue);
    });

    testWidgets("a value jj can't read chooses nothing and says so; picking the default writes it", (tester) async {
      final rig = _Rig(tester);
      rig.env.configEntries[context] = <ConfigEntry>[_entry(context, '"many"', ConfigValueSource.user)];
      await rig.pump(project: false);
      expect(find.text('jj can\'t read "many".'), findsOneWidget);
      expect(find.text('3'), findsNothing);

      await pick(tester, rig, 'settings-diff-context', '3');
      expect(rig.calls, <String>['set user $context 3']);
      expect(find.textContaining("jj can't read"), findsNothing);
      expect(find.text('3'), findsOneWidget);
    });

    testWidgets('the open project setting its own value adds a note; the General row shows the user value', (
      tester,
    ) async {
      final rig = _Rig(tester);
      rig.env.configEntries[context] = <ConfigEntry>[
        _entry(context, '5', ConfigValueSource.user),
        _entry(context, '7', ConfigValueSource.repo),
      ];
      await rig.pump(target: SettingsTarget.general);
      expect(find.text('5'), findsOneWidget);
      expect(find.text('$contextHint The open project sets its own value.'), findsOneWidget);
    });

    testWidgets('a value from another layer names it after the hint', (tester) async {
      final rig = _Rig(tester);
      rig.env.configEntries[context] = <ConfigEntry>[_entry(context, '3', ConfigValueSource.envBase)];
      await rig.pump(project: false);
      expect(find.text('$contextHint From environment config'), findsOneWidget);
    });

    testWidgets('a failed write shows its error under the row and keeps the value', (tester) async {
      final rig = _Rig(tester);
      rig.env.configFailure = const ZanshinFfiException('jj.config_error', 'Failed to write the config');
      await rig.pump(project: false);

      await pick(tester, rig, 'settings-diff-context', '10');
      expect(find.text('Failed to write the config'), findsOneWidget);
      expect(find.text('3'), findsOneWidget);
      expect(find.text('10'), findsNothing);
    });

    testWidgets('an off-list Inline value sits before Always, which stays last', (tester) async {
      final rig = _Rig(tester);
      rig.env.configEntries[inline] = <ConfigEntry>[_entry(inline, '8', ConfigValueSource.user)];
      await rig.pump(project: false);
      expect(find.text('Up to 8'), findsOneWidget);

      await rig.tap('settings-diff-inline');
      await rig.settle();
      final double five = tester.getRect(find.text('Up to 5').last).top;
      final double eight = tester.getRect(find.text('Up to 8').last).top;
      final double always = tester.getRect(find.text('Always').last).top;
      expect(five < eight && eight < always, isTrue);
    });

    testWidgets("a value from jj's defaults shows no source note", (tester) async {
      final rig = _Rig(tester);
      rig.env.configEntries[context] = <ConfigEntry>[_entry(context, '3', ConfigValueSource.defaults)];
      await rig.pump(project: false);
      expect(find.text(contextHint), findsOneWidget);
    });

    testWidgets('the project note also for a workspace value', (tester) async {
      final rig = _Rig(tester);
      rig.env.configEntries[context] = <ConfigEntry>[
        _entry(context, '5', ConfigValueSource.user),
        _entry(context, '7', ConfigValueSource.workspace),
      ];
      await rig.pump(target: SettingsTarget.general);
      expect(find.text('$contextHint The open project sets its own value.'), findsOneWidget);
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

    testWidgets('Story 10.37: Reset view state clears the open project\'s marks and toggles', (tester) async {
      final rig = _Rig(tester);
      await rig.pump(target: SettingsTarget.project);
      final ProjectStateStore state = rig.store.projectStates.of(settingsRigProject)!;
      unawaited(
        state.update(
          (_) => const ProjectState(
            viewedFiles: <String>['k:ff:a'],
            expandedStacks: <String>['x'],
            collapsedStacks: <String>['y'],
          ),
        ),
      );
      await rig.settle();
      expect(find.text('Clears the files marked Viewed and the stacks you expanded or collapsed.'), findsOneWidget);

      await tester.ensureVisible(rig.id('settings-reset-view-state'));
      await rig.tap('settings-reset-view-state');

      expect(state.value, const ProjectState());
      expect(rig.calls, isEmpty, reason: 'view state, not jj config');
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
