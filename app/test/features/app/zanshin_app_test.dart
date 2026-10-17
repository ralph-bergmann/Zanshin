// SPDX-License-Identifier: MIT

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:inject_annotation/inject_annotation.dart' show Provider;
import 'package:inject_flutter/inject_flutter.dart';
import 'package:material_ui/material_ui.dart';
import 'package:zanshin/src/features/app/zanshin_app.dart';
import 'package:zanshin/src/features/app/zanshin_app_view_model.dart';
import 'package:zanshin/src/features/home/home_page.dart';
import 'package:zanshin/src/shared/design/zs_appearance.dart';
import 'package:zanshin/src/shared/design/zs_colors.dart';
import 'package:zanshin/src/shared/design/zs_elevation.dart';
import 'package:zanshin/src/shared/design/zs_motion.dart';
import 'package:zanshin_settings/zanshin_settings.dart';
import 'package:zanshin_shell_platform_interface/zanshin_shell_platform_interface.dart';

import '../../helpers/recording_shell.dart';

/// The home page is unused while the Yaru test page is the app's home.
class _UnusedHomePageFactory implements HomePageFactory {
  @override
  HomePage create({Key? key}) => throw UnimplementedError('the Yaru test page is the home');
}

class _ViewModelProvider implements Provider<ZanshinAppViewModel> {
  _ViewModelProvider(this._store);

  final SettingsStore _store;

  @override
  ZanshinAppViewModel get() => ZanshinAppViewModel(_store);
}

/// The view-model factory the DI graph would hand over, over [store].
ViewModelFactory<ZanshinAppViewModel> _viewModels(SettingsStore store) =>
    ({
      required builder,
      child,
      error,
      init,
      key,
      loading,
    }) => ViewModelBuilder<ZanshinAppViewModel>(
      key: key,
      viewModelProvider: _ViewModelProvider(store),
      init: init,
      loading: loading,
      error: error,
      builder: builder,
      child: child,
    );

/// A dark shell; by default macOS on Multicolor with Zanshin's app accent (`--accent-native`) as the reported colour.
ShellTheme _shell({bool reduceMotion = false, int? appleAccentColor, Color accentColor = const Color(0xFF4757A1)}) =>
    ShellTheme(
      brightness: Brightness.dark,
      accentColor: accentColor,
      appleAccentColor: appleAccentColor,
      reduceMotion: reduceMotion,
    );

void main() {
  late Directory dir;
  late File file;
  late RecordingShell shell;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('zanshin_app_test');
    file = File('${dir.path}/settings.json');
  });

  tearDown(() async {
    await dir.delete(recursive: true);
  });

  /// Pumps the app over persisted [settingsJson], answers the shell with [theme] (or leaves it pending when null) and
  /// returns a context below the app root (the home page's scaffold). File IO runs outside the fake-async zone; the shell is made inside it, so
  /// its answers arrive on the fake clock's microtasks.
  Future<BuildContext> pumpApp(WidgetTester tester, String settingsJson, ShellTheme? theme) async {
    shell = RecordingShell();
    ZanshinShellPlatform.instance = shell;
    addTearDown(shell.close);
    final SettingsStore? store = await tester.runAsync(() async {
      await file.writeAsString(settingsJson);
      return SettingsStore.load(file);
    });
    await tester.pumpWidget(
      ZanshinApp(homePageFactory: _UnusedHomePageFactory(), viewModelFactory: _viewModels(store!)),
    );
    if (theme == null) {
      // The shell has not answered yet: the first frame.
      await tester.pump();
    } else {
      shell.theme.complete(theme);
      await tester.pumpAndSettle();
    }
    return tester.element(find.byType(Scaffold));
  }

  for (final (String mode, ZsTheme expected) in const <(String, ZsTheme)>[
    ('light', ZsTheme.paper),
    ('dark', ZsTheme.night),
    ('system', ZsTheme.night),
  ]) {
    testWidgets('the setting $mode with the shell in dark shows ${expected.name}, with the token extensions', (
      tester,
    ) async {
      final BuildContext probe = await pumpApp(tester, '{"appearance": {"themeMode": "$mode"}}', _shell());

      expect(ZsAppearance.of(probe).theme, expected);
      final ZsColors? colors = Theme.of(probe).extension<ZsColors>();
      expect(colors, expected == ZsTheme.paper ? ZsColors.paper : ZsColors.night);
      expect(Theme.of(probe).extension<ZsElevation>(), isNotNull);
      expect(Theme.of(probe).brightness, expected.brightness);
    });
  }

  testWidgets('before the shell answers, setting system follows the platform brightness', (tester) async {
    // The test platform's brightness is light.
    final BuildContext probe = await pumpApp(tester, '{"appearance": {"themeMode": "system"}}', null);

    expect(shell.calls, contains('getTheme'));
    expect(ZsAppearance.of(probe).theme, ZsTheme.paper);
    expect(ZsColors.of(probe), ZsColors.paper);
  });

  testWidgets("the shell's text selection colour reaches the window root", (tester) async {
    const selection = Color(0xFF3F638B);
    final BuildContext probe = await pumpApp(
      tester,
      '{"appearance": {"themeMode": "dark"}}',
      const ShellTheme(
        brightness: Brightness.dark,
        accentColor: Color(0xFF4757A1),
        selectedTextBackgroundDark: selection,
      ),
    );

    expect(DefaultSelectionStyle.of(probe).selectionColor, selection);
  });

  testWidgets('a shell reporting reduce motion disables animations below the app root, live', (tester) async {
    final BuildContext probe = await pumpApp(
      tester,
      '{"appearance": {"themeMode": "dark"}}',
      _shell(reduceMotion: true),
    );

    expect(MediaQuery.disableAnimationsOf(probe), isTrue);
    final ZsMotion reduced = ZsMotion.of(probe);
    expect(reduced.motion, 0);
    expect(
      <Duration>[reduced.durNudge, reduced.durToggle, reduced.durExpand, reduced.durMove, reduced.durFlip],
      <Duration>[
        Duration.zero,
        Duration.zero,
        Duration.zero,
        Duration.zero,
        Duration.zero,
      ],
    );
    expect(reduced.durHover, ZsMotion.full.durHover);
    expect(reduced.durFlash, ZsMotion.full.durFlash);

    shell.changes.add(_shell());
    await tester.pumpAndSettle();

    final BuildContext after = tester.element(find.byType(Scaffold));
    expect(MediaQuery.disableAnimationsOf(after), isFalse);
    expect(ZsMotion.of(after), ZsMotion.full);
  });

  for (final (String label, String settingsJson, ShellTheme theme, Color accent)
      in <(String, String, ShellTheme, Color)>[
        ('AppleAccentColor 4 shows Blue', '{}', _shell(appleAccentColor: 4), const Color(0xFF67AFFD)),
        (
          'no key and the app accent shows moon',
          '{}',
          _shell(),
          const Color(0xFFAEBCEC),
        ),
        (
          'no key and an iMac orange shows Orange',
          '{}',
          _shell(accentColor: const Color(0xFFF7821B)),
          const Color(0xFFFE8954),
        ),
        (
          'the setting Zanshin shows moon whatever the shell reports',
          '{"appearance": {"accentSource": "zanshin"}}',
          _shell(appleAccentColor: 4),
          const Color(0xFFAEBCEC),
        ),
      ]) {
    testWidgets('accent: $label', (tester) async {
      final BuildContext probe = await pumpApp(tester, settingsJson, theme);
      expect(ZsColors.of(probe).accent, accent);
      expect(Theme.of(probe).colorScheme.primary, accent);
    });
  }
}
