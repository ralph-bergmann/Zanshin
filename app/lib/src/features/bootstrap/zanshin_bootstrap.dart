// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:yaru/yaru.dart';
import 'package:zanshin_settings/zanshin_settings.dart';

/// Root widget of the app: runs the asynchronous boot behind the first frame.
///
/// Paints the app's background colour immediately and swaps to the widget
/// [startApp] returned once both boot steps are done.
class ZanshinBootstrap extends StatefulWidget {
  const ZanshinBootstrap({required this.openSettings, required this.startApp, super.key});

  /// First boot step: the persisted settings, needed by the DI graph and by
  /// the splash colour.
  final Future<SettingsStore> Function() openSettings;

  /// Second boot step: builds the DI graph over the loaded settings, starts
  /// the worker and returns the app widget.
  final Future<Widget> Function(SettingsStore settings) startApp;

  @override
  State<ZanshinBootstrap> createState() => _ZanshinBootstrapState();
}

class _ZanshinBootstrapState extends State<ZanshinBootstrap> {
  /// Persisted theme choice; `system` until [ZanshinBootstrap.openSettings]
  /// answered, which follows the platform brightness either way.
  ThemeMode _persistedMode = ThemeMode.system;

  /// The finished app.
  Widget? _content;

  var _splashDismissed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_boot());
  }

  Future<void> _boot() async {
    final SettingsStore settings = await widget.openSettings();
    if (!mounted) {
      return;
    }
    setState(() => _persistedMode = settings.value.appearance.themeMode);
    final Widget app = await widget.startApp(settings);
    if (!mounted) {
      return;
    }
    setState(() {
      _content = app;
      _splashDismissed = true;
    });
  }

  @override
  Widget build(BuildContext context) => Directionality(
    // Stack's default alignment is directional, and no MaterialApp exists yet.
    textDirection: TextDirection.ltr,
    child: MediaQuery.fromView(
      // Platform brightness (and later accessibility flags) without a MaterialApp.
      view: View.of(context),
      child: Stack(
        fit: StackFit.expand,
        children: [
          ?_content,
          if (!_splashDismissed) IgnorePointer(child: _SplashScreen(mode: _persistedMode)),
        ],
      ),
    ),
  );
}

/// The blank splash: the colour `ZanshinApp`'s scaffold paints first.
class _SplashScreen extends StatelessWidget {
  const _SplashScreen({required this.mode});

  final ThemeMode mode;

  @override
  Widget build(BuildContext context) => ColoredBox(color: _scaffoldBackground(_resolveBrightness(context, mode)));
}

/// A persisted light/dark choice wins; `system` follows the platform.
Brightness _resolveBrightness(BuildContext context, ThemeMode mode) => switch (mode) {
  ThemeMode.light => Brightness.light,
  ThemeMode.dark => Brightness.dark,
  ThemeMode.system => MediaQuery.platformBrightnessOf(context),
};

/// The scaffold background of the yaru theme `ZanshinApp` uses for [brightness]
/// (independent of the accent colour, so it matches the real app theme).
Color _scaffoldBackground(Brightness brightness) =>
    (brightness == Brightness.dark ? yaruDark : yaruLight).scaffoldBackgroundColor;
