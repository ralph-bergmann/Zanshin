// SPDX-License-Identifier: MIT

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:inject_annotation/inject_annotation.dart' show Provider;
import 'package:inject_flutter/inject_flutter.dart';
import 'package:material_ui/material_ui.dart';
import 'package:zanshin/src/features/app/zanshin_app.dart';
import 'package:zanshin/src/features/app/zanshin_app_view_model.dart';
import 'package:zanshin/src/features/home/home_page.dart';
import 'package:zanshin/src/features/shell/floating_shell.dart';
import 'package:zanshin/src/features/shell/floating_shell_view_model.dart';
import 'package:zanshin_settings/zanshin_settings.dart';
import 'package:zanshin_shell_platform_interface/zanshin_shell_platform_interface.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

import '../../helpers/recording_shell.dart';

/// The home page the DI graph would build, over [_store], with a fake FFI version.
class _HomePageFactory implements HomePageFactory {
  _HomePageFactory(this._store);

  final SettingsStore _store;

  @override
  HomePage create({Key? key}) => HomePage(
    key: key,
    zanshinFfiVersion: () => 'test',
    viewModelFactory: _viewModels(() => FloatingShellViewModel(_store)),
  );
}

class _Provider<T> implements Provider<T> {
  _Provider(this._create);

  final T Function() _create;

  @override
  T get() => _create();
}

/// The view-model factory the DI graph would hand over, creating each view model with [create].
ViewModelFactory<T> _viewModels<T extends ChangeNotifier>(T Function() create) =>
    ({
      required builder,
      child,
      error,
      init,
      key,
      loading,
    }) => ViewModelBuilder<T>(
      key: key,
      viewModelProvider: _Provider<T>(create),
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

  /// Pumps the app over persisted [settingsJson] in a 1440 × 900 window, answers the shell with [theme] (or leaves it
  /// pending when null) and returns a context below the app root (the home page's floating shell). File IO runs
  /// outside the fake-async zone; the shell is made inside it, so its answers arrive on the fake clock's microtasks.
  Future<BuildContext> pumpApp(WidgetTester tester, String settingsJson, ShellTheme? theme) async {
    tester.view
      ..physicalSize = const Size(1440, 900)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    shell = RecordingShell();
    ZanshinShellPlatform.instance = shell;
    addTearDown(shell.close);
    final SettingsStore? store = await tester.runAsync(() async {
      await file.writeAsString(settingsJson);
      return SettingsStore.load(file);
    });
    await tester.pumpWidget(
      ZanshinApp(
        homePageFactory: _HomePageFactory(store!),
        viewModelFactory: _viewModels(() => ZanshinAppViewModel(store)),
      ),
    );
    if (theme == null) {
      // The shell has not answered yet: the first frame.
      await tester.pump();
    } else {
      shell.theme.complete(theme);
      await tester.pumpAndSettle();
    }
    return tester.element(find.byType(FloatingShell));
  }

  testWidgets('the home is HomePage over the floating shell, titled Zanshin; the Yaru test page is gone', (
    tester,
  ) async {
    await pumpApp(tester, '{}', _shell());

    expect(find.byType(HomePage), findsOneWidget);
    expect(find.descendant(of: find.byType(HomePage), matching: find.byType(FloatingShell)), findsOneWidget);
    expect(tester.widget<MaterialApp>(find.byType(MaterialApp)).title, 'Zanshin');
    expect(find.byType(Scaffold), findsNothing);
    expect(find.byType(AppBar), findsNothing);
  });

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

    final BuildContext after = tester.element(find.byType(FloatingShell));
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
