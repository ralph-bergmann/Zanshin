// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:logging/logging.dart';
import 'package:lottie/lottie.dart';
import 'package:material_ui/material_ui.dart';
import 'package:yaru/yaru.dart';
import 'package:zanshin_settings/zanshin_settings.dart';

/// Loader animation shown while the app boots. Swap for
/// `assets/lottie/nami_loader_transparent.json` to show the waves without the
/// indigo tile (both files are bundled).
const splashAnimationAsset = 'assets/lottie/nami_loader.json';

/// Edge length of the loader animation in logical pixels.
const double splashAnimationSize = 96;

/// How long a boot may take before the loader appears at all.
const splashIndicatorDelay = Duration(milliseconds: 500);

/// Once shown, the loader stays at least this long so it never just blinks.
const splashIndicatorMinShow = Duration(milliseconds: 1000);

/// Fade-in of the loader when [splashIndicatorDelay] elapses.
const splashIndicatorFadeIn = Duration(milliseconds: 150);

/// Fade-out of the whole splash over the finished app.
const splashFadeOut = Duration(milliseconds: 200);

final _log = Logger('zanshin.bootstrap');

/// Root widget of the app: runs the asynchronous boot behind the first frame.
///
/// Paints the app's background colour immediately, shows the loader only when
/// [openSettings] + [startApp] take longer than [splashIndicatorDelay] (and
/// then for at least [splashIndicatorMinShow]), and finally the widget
/// [startApp] returned.
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

  // Timing is driven by these two timers and the flags below, never by
  // reading a clock, so the fake time of widget tests controls it fully.
  late final Timer _delayTimer;
  Timer? _minShowTimer;

  var _indicatorVisible = false;
  var _minShowElapsed = false;
  var _bootFinished = false;
  var _fadingOut = false;
  var _splashDismissed = false;

  @override
  void initState() {
    super.initState();
    _delayTimer = Timer(splashIndicatorDelay, _showIndicator);
    unawaited(_boot());
  }

  @override
  void dispose() {
    _delayTimer.cancel();
    _minShowTimer?.cancel();
    super.dispose();
  }

  Future<void> _boot() async {
    Widget content;
    try {
      content = await _load();
    } catch (error, stackTrace) {
      // Process-level boundary: a failed boot may surface as an Error (FFI,
      // isolate spawn), so this deliberately catches everything.
      _log.severe('App boot failed', error, stackTrace);
      content = _BootFailure(error: error, mode: _persistedMode);
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _content = content;
      _bootFinished = true;
    });
    _onBootFinished();
  }

  /// Both boot steps; the persisted mode reaches the splash between them.
  Future<Widget> _load() async {
    final SettingsStore settings = await widget.openSettings();
    if (mounted) {
      setState(() => _persistedMode = settings.value.appearance.themeMode);
    }
    return widget.startApp(settings);
  }

  void _showIndicator() {
    setState(() => _indicatorVisible = true);
    _minShowTimer = Timer(splashIndicatorMinShow, _onMinShowElapsed);
  }

  void _onMinShowElapsed() {
    _minShowElapsed = true;
    if (_bootFinished) {
      _startFadeOut();
    }
  }

  void _onBootFinished() {
    if (!_indicatorVisible) {
      // Fast boot: nothing was ever shown, so nothing has to fade.
      _delayTimer.cancel();
      setState(() => _splashDismissed = true);
    } else if (_minShowElapsed) {
      _startFadeOut();
    }
    // Otherwise _onMinShowElapsed starts the fade when the minimum is over.
  }

  void _startFadeOut() => setState(() => _fadingOut = true);

  void _dismissSplash() => setState(() => _splashDismissed = true);

  @override
  Widget build(BuildContext context) => Directionality(
    // Stack's default alignment is directional, and no MaterialApp exists yet.
    textDirection: TextDirection.ltr,
    child: MediaQuery.fromView(
      // Platform brightness and accessibility flags without a MaterialApp.
      view: View.of(context),
      child: Stack(
        fit: StackFit.expand,
        children: [
          ?_content,
          if (!_splashDismissed)
            IgnorePointer(
              child: AnimatedOpacity(
                opacity: _fadingOut ? 0 : 1,
                duration: splashFadeOut,
                onEnd: _dismissSplash,
                child: _SplashScreen(mode: _persistedMode, showIndicator: _indicatorVisible),
              ),
            ),
        ],
      ),
    ),
  );
}

/// The splash: the colour `ZanshinApp`'s scaffold paints first, with the
/// loader fading in once [showIndicator] is set.
class _SplashScreen extends StatelessWidget {
  const _SplashScreen({required this.mode, required this.showIndicator});

  final ThemeMode mode;
  final bool showIndicator;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: _scaffoldBackground(_resolveBrightness(context, mode)),
    child: Center(
      child: AnimatedOpacity(
        opacity: showIndicator ? 1 : 0,
        duration: splashIndicatorFadeIn,
        // Only in the tree once needed: a fast boot never loads the asset.
        child: showIndicator
            ? Lottie.asset(
                splashAnimationAsset,
                width: splashAnimationSize,
                height: splashAnimationSize,
                // "Reduce motion": the first frame is the static logo.
                animate: !MediaQuery.disableAnimationsOf(context),
              )
            : null,
      ),
    ),
  );
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

/// Shown instead of the app when the boot failed: same background, a headline
/// and the selectable error text. No retry — ⌘Q quits as usual.
class _BootFailure extends StatelessWidget {
  const _BootFailure({required this.error, required this.mode});

  final Object error;
  final ThemeMode mode;

  @override
  Widget build(BuildContext context) => MaterialApp(
    theme: yaruLight,
    darkTheme: yaruDark,
    themeMode: mode,
    home: Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            spacing: 12,
            children: [
              const Text('Zanshin could not start.'),
              SelectableText('$error'),
            ],
          ),
        ),
      ),
    ),
  );
}
