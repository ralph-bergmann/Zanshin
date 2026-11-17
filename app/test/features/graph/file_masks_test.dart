// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/src/features/graph/file_masks.dart';
import 'package:zanshin_settings/zanshin_settings.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

import '../../helpers/icon_registry.dart';
import '../../helpers/settle_settings.dart';
import '../../helpers/shell_host.dart';

/// Whether the ticked entry [mask] hides [path].
bool _hides(String mask, String path) => FileMaskMatcher(<FileMask>[FileMask(mask: mask, active: true)]).hides(path);

Finder _id(String identifier) => find.byWidgetPredicate(
  (widget) => switch (widget) {
    final ZsControl control => control.identifier == identifier,
    final ZsControlCore core => core.identifier == identifier,
    _ => false,
  },
);

Finder _semantics(String identifier) =>
    find.byWidgetPredicate((widget) => widget is Semantics && widget.properties.identifier == identifier);

void main() {
  setUpIconRegistry();

  group('the matcher', () {
    test('an entry of several masks: the generated Dart files', () {
      const entry = '*.g.dart, *.freezed.dart';
      for (final path in <String>[
        'app/lib/routing/app_routes.g.dart',
        'packages/logic_designer/lib/src/domain/models/automation.freezed.dart',
        'packages/logic_designer/lib/src/domain/models/automation.g.dart',
      ]) {
        expect(_hides(entry, path), isTrue, reason: path);
      }
      expect(_hides(entry, 'packages/logic_designer/lib/src/domain/models/automation.dart'), isFalse);
      expect(_hides(entry, 'app/pubspec.lock'), isFalse);
    });

    test('a mask with "/" matches the whole path, anchored', () {
      expect(_hides('docs/*.png', 'docs/packages.png'), isTrue);
      expect(_hides('docs/*.png', 'a/docs/x.png'), isFalse);
      expect(_hides('docs/*.png', 'img.png'), isFalse);
      expect(_hides('docs/*.png', 'docs/sub/x.png'), isFalse, reason: '* stays inside a name');
      expect(_hides('/docs/*.png', 'docs/packages.png'), isTrue, reason: 'a leading / is dropped');
    });

    test('a name glob matches the file name in any folder', () {
      for (final name in <String>['core_localizations.dart', 'core_localizations_de.dart']) {
        expect(_hides('core_localizations*.dart', 'packages/localization/lib/src/l10n/$name'), isTrue, reason: name);
      }
      expect(
        _hides('core_localizations*.dart', 'packages/localization/lib/src/l10n/core_localizations_en.dart'),
        isTrue,
      );
      expect(_hides('core_localizations*.dart', 'core_localizations/x.dart'), isFalse);
    });

    test('**/ is zero or more folders, a lone ** crosses folders', () {
      expect(_hides('packages/**/*.g.dart', 'packages/x/lib/a.g.dart'), isTrue);
      expect(_hides('packages/**/*.g.dart', 'packages/a.g.dart'), isTrue);
      expect(_hides('packages/**/*.g.dart', 'app/a.g.dart'), isFalse);
      expect(_hides('docs/**', 'docs/a/b/c.png'), isTrue);
      expect(_hides('docs/**', 'app/docs/x'), isFalse);
    });

    test('? is one character but /; the rest is literal; case-sensitive', () {
      expect(_hides('a?.dart', 'lib/ab.dart'), isTrue);
      expect(_hides('a?.dart', 'lib/abc.dart'), isFalse);
      expect(_hides('a?b', 'a/b'), isFalse);
      expect(_hides('a.dart', 'lib/axdart'), isFalse, reason: 'the dot is literal');
      expect(_hides('(x)+.txt', 'lib/(x)+.txt'), isTrue);
      expect(_hides('*.G.dart', 'a.g.dart'), isFalse);
    });

    test('blank masks of an entry are skipped; an unticked entry hides nothing but still counts', () {
      expect(_hides(' , *.lock ,', 'app/pubspec.lock'), isTrue);
      expect(_hides(' , ', 'a'), isFalse);
      final matcher = FileMaskMatcher(const <FileMask>[FileMask(mask: '*.lock'), FileMask(mask: '*.md', active: true)]);
      expect(matcher.hides('pubspec.lock'), isFalse);
      expect(matcher.hides('README.md'), isTrue);
      expect(matcher.activeCount, 1);
      expect(matcher.count(0, <String>['a.lock', 'b/c.lock', 'd.md']), 2);
    });

    test('a lone "/" or "," holds no usable mask and hides nothing', () {
      for (final entry in <String>[',', '/', ' / , ', '']) {
        expect(FileMaskMatcher.usable(entry), isFalse, reason: entry);
        expect(_hides(entry, 'a'), isFalse, reason: entry);
        expect(_hides(entry, ''), isFalse, reason: entry);
      }
      expect(FileMaskMatcher.usable('/ , *.lock'), isTrue);
      expect(_hides('/ , *.lock', 'pubspec.lock'), isTrue);
    });
  });

  group('the edits and the popover', () {
    late Directory dir;
    late SettingsStore settings;

    setUp(() async {
      dir = Directory.systemTemp.createTempSync('zanshin_masks');
      settings = await SettingsStore.load(File('${dir.path}/settings.json'));
    });

    tearDown(() => dir.deleteSync(recursive: true));

    List<FileMask> masks() => settings.value.general.fileMasks;

    testWidgets('add puts a trimmed entry on top, ticked; re-adding moves it; blank adds nothing', (tester) async {
      addTearDown(() => settleSettingsWrites(tester, settings));
      expect(masks(), defaultFileMasks);
      settings.addFileMask('  *.arb ');
      expect(masks().first, const FileMask(mask: '*.arb', active: true));
      expect(masks(), hasLength(3));
      settings.addFileMask('*.lock');
      expect(masks(), const <FileMask>[
        FileMask(mask: '*.lock', active: true),
        FileMask(mask: '*.arb', active: true),
        FileMask(mask: '*.g.dart, *.freezed.dart'),
      ]);
      for (final unusable in <String>['   ', ',', '/', ' / , ']) {
        settings.addFileMask(unusable);
        expect(masks(), hasLength(3), reason: 'nothing stored for "$unusable"');
      }
      settings.toggleFileMask(1);
      expect(masks()[1].active, isFalse);
      settings.removeFileMask(1);
      expect(masks().map((m) => m.mask), <String>['*.lock', '*.g.dart, *.freezed.dart']);
      await settleSettingsWrites(tester, settings);
      final SettingsStore restarted = (await tester.runAsync(
        () => SettingsStore.load(File('${dir.path}/settings.json')),
      ))!;
      expect(restarted.value.general.fileMasks, masks(), reason: 'a store loaded again reads the same masks');
    });

    Future<MenuController> pump(
      WidgetTester tester, {
      List<String> paths = const <String>[],
      FocusNode? opener,
      Size window = shellWindow,
    }) async {
      addTearDown(() => settleSettingsWrites(tester, settings));
      useShellWindow(tester, window);
      final controller = MenuController();
      await tester.pumpWidget(
        shellHost(
          Align(
            alignment: Alignment.topLeft,
            child: Padding(
              padding: const EdgeInsets.all(40),
              child: FileMasksAnchor(
                settings: settings,
                paths: paths,
                controller: controller,
                builder: (context, open) => Focus(
                  focusNode: opener,
                  child: FileMasksButton(
                    active: FileMaskMatcher(settings.value.general.fileMasks).activeCount,
                    open: open,
                    onPressed: () => controller.isOpen ? controller.close() : controller.open(),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      return controller;
    }

    Future<void> settle(WidgetTester tester) async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }

    testWidgets('↩ adds the field\'s mask and clears it; a row click toggles; × removes; Esc closes', (tester) async {
      await pump(tester, paths: <String>['a.g.dart', 'b.freezed.dart', 'c.dart']);
      await tester.tap(_id('inspector-file-masks'));
      await settle(tester);
      expect(_semantics('file-masks-popover'), findsOneWidget);
      expect(find.text('Hide files matching'), findsOneWidget);
      expect(find.text('2'), findsOneWidget, reason: 'the first seed matches two of the files');
      final Finder field = find.descendant(of: _id('file-masks-field'), matching: find.byType(EditableText));
      expect(tester.widget<EditableText>(field).focusNode.hasFocus, isTrue, reason: 'the field takes the focus');

      await tester.enterText(field, ' *.dart ');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await settle(tester);
      expect(masks().first, const FileMask(mask: '*.dart', active: true));
      expect(tester.widget<EditableText>(field).controller.text, isEmpty);
      expect(find.text('3'), findsOneWidget, reason: '*.dart matches all three');

      await tester.tap(_semantics('file-mask-1'));
      await settle(tester);
      expect(masks()[1].active, isTrue, reason: 'a click on the row ticks it');
      await tester.tap(_semantics('file-mask-1'));
      await settle(tester);
      expect(masks()[1].active, isFalse);

      await tester.tap(_id('file-mask-0-remove'));
      await settle(tester);
      expect(masks().map((m) => m.mask), isNot(contains('*.dart')));

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
      expect(_semantics('file-masks-popover'), findsNothing);
    });

    testWidgets('the funnel shows the ticked count in --accent and its tooltip names it', (tester) async {
      settings.addFileMask('*.lock');
      await pump(tester);
      await tester.pump();
      expect(find.descendant(of: _id('inspector-file-masks'), matching: find.text('1')), findsOneWidget);
      final ZsTooltip tip = tester.widget<ZsTooltip>(
        find.ancestor(of: _id('inspector-file-masks'), matching: find.byType(ZsTooltip)).first,
      );
      expect(tip.message, 'Hiding files matching 1 mask');
      final ZsColors colors = ZsColors.of(tester.element(find.text('1')));
      expect(tester.widget<Text>(find.text('1')).style!.color, colors.accent);
    });

    testWidgets('Esc gives the focus back to the opener', (tester) async {
      final opener = FocusNode(debugLabel: 'opener');
      addTearDown(opener.dispose);
      final MenuController controller = await pump(tester, opener: opener);
      opener.requestFocus();
      await tester.pump();
      controller.open();
      await settle(tester);
      expect(opener.hasFocus, isFalse, reason: 'the field took the focus');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
      expect(_semantics('file-masks-popover'), findsNothing);
      expect(opener.hasFocus, isTrue);
    });

    testWidgets('many entries in a short window: the entries scroll, the footer stays reachable', (tester) async {
      unawaited(
        settings.update(
          (s) => s.copyWith.general(
            fileMasks: <FileMask>[for (var i = 0; i < 40; i++) FileMask(mask: '*.x$i')],
          ),
        ),
      );
      final MenuController controller = await pump(tester, window: const Size(800, 360));
      controller.open();
      await settle(tester);
      expect(tester.takeException(), isNull, reason: 'no overflow');
      final Finder footer = find.textContaining('Separate several with commas');
      expect(footer, findsOneWidget);
      expect(tester.getBottomLeft(footer).dy, lessThanOrEqualTo(360));
      expect(find.byType(SingleChildScrollView), findsOneWidget);
    });
  });
}
