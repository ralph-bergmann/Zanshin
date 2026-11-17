// SPDX-License-Identifier: MIT

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/src/features/window/code_font.dart';
import 'package:zanshin_settings/zanshin_settings.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

void main() {
  group('codeTextStyle', () {
    test('defaults draw the built-in mono at 11 with height 1.65', () {
      final TextStyle style = codeTextStyle(const GeneralSettings(), const ['Menlo']);
      expect(style.fontFamily, ZsType.monoFamily);
      expect(style.fontSize, 11);
      expect(style.height, 1.65);
    });

    test('a picked installed family draws with JetBrains Mono then Inter behind it', () {
      final TextStyle style = codeTextStyle(const GeneralSettings(codeFont: 'Menlo'), const ['Menlo']);
      expect(style.fontFamily, 'Menlo');
      expect(style.fontFamilyFallback, [ZsType.monoFamily, ZsType.sansFamily]);
    });

    test('a family missing from the read list draws the built-in mono', () {
      const general = GeneralSettings(codeFont: 'Gone Mono');
      expect(codeTextStyle(general, const ['Menlo']).fontFamily, ZsType.monoFamily);
      expect(codeFontMissing('Gone Mono', const ['Menlo']), isTrue);
    });

    test('while the list is unknown the saved family is used as is', () {
      expect(codeTextStyle(const GeneralSettings(codeFont: 'Gone Mono'), null).fontFamily, 'Gone Mono');
      expect(codeFontMissing('Gone Mono', null), isFalse);
      expect(codeFontMissing(null, const ['Menlo']), isFalse);
    });

    test('the size follows the setting and is clamped to 6…72', () {
      expect(codeTextStyle(const GeneralSettings(codeSize: 14), null).fontSize, 14);
      expect(codeTextStyle(const GeneralSettings(codeSize: 0), null).fontSize, 6);
      expect(codeTextStyle(const GeneralSettings(codeSize: 500), null).fontSize, 72);
    });
  });

  group('InstalledCodeFonts', () {
    test('refresh sorts the families case-insensitively and notifies', () async {
      final fonts = InstalledCodeFonts.withReader(() async => const ['monaco', 'Menlo', 'Andale Mono']);
      var notifications = 0;
      fonts.addListener(() => notifications++);
      expect(fonts.families, isNull);

      await fonts.refresh();
      expect(fonts.families, ['Andale Mono', 'Menlo', 'monaco']);
      expect(notifications, 1);

      await fonts.refresh();
      expect(notifications, 1, reason: 'an unchanged list notifies nobody');
    });

    testWidgets('the runner reader asks zanshin/fonts for monospacedFamilies', (tester) async {
      const channel = MethodChannel('zanshin/fonts');
      final methods = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
        methods.add(call.method);
        return <Object?>['Menlo', 'Andale Mono'];
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));

      final fonts = InstalledCodeFonts();
      await fonts.refresh();
      expect(methods, ['monospacedFamilies']);
      expect(fonts.families, ['Andale Mono', 'Menlo']);
    });

    test('a failed read keeps the list unknown', () async {
      for (final Object error in [PlatformException(code: 'x'), MissingPluginException()]) {
        final fonts = InstalledCodeFonts.withReader(() async => throw error);
        await fonts.refresh();
        expect(fonts.families, isNull, reason: '$error');
      }
      final empty = InstalledCodeFonts.withReader(() async => null);
      await empty.refresh();
      expect(empty.families, isNull);
    });
  });

  testWidgets('without a scope the code style is ZsType.code', (tester) async {
    late TextStyle seen;
    await tester.pumpWidget(
      Builder(
        builder: (context) {
          seen = CodeStyleScope.of(context);
          return const SizedBox.shrink();
        },
      ),
    );
    expect(seen, ZsType.code);
  });
}
