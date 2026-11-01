// SPDX-License-Identifier: MIT

// The windowing API is experimental and only reachable through implementation
// imports; see https://github.com/flutter/flutter/issues/30701.
// ignore_for_file: invalid_use_of_internal_member, implementation_imports

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/src/widgets/_window.dart';
import 'package:flutter/widgets.dart';
import 'package:logging/logging.dart';
import 'package:zanshin_shell/zanshin_shell.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

import '../shell/app_menu.dart';
import '../window/app_windows.dart';
import '../window/splash_window_controller.dart';
import 'splash_card.dart';
import 'zanshin_bootstrap.dart';

export '../window/app_windows.dart' show mainWindowKey;

/// Title of the main window.
const mainWindowTitle = 'Zanshin'; // l10n-ignore: the product name

final _log = Logger('zanshin.bootstrap');

/// The real [BootWindowHost]: the only place that creates windows.
///
/// Its requests and both presentation paths — the first window through
/// `runWidget`, every later one through the registry — are tested over a fake
/// window factory. The splash and the native controllers need a live engine:
/// the check for them is a running app — the DEBUG `zanshin.window` restore
/// lines and the CGWindowList probe. The sequencing the host serves is tested
/// against a fake host.
class ZanshinWindowHost implements BootWindowHost {
  ZanshinWindowHost({required this.windows, required this.icons, required this.menu});

  /// Keyed registry of the app's windows; also the exit rule.
  final AppWindows windows;

  /// The menu bar's model (Story 11.13), null until the DI graph exists: until then the menu bar shows the system's
  /// items only.
  final ValueListenable<AppMenuModel?> menu;

  /// The boot-loaded icons, provided above every window (Claude's proposal,
  /// Story 11.1), so the dialog windows share them; null until loaded.
  final ValueListenable<IconRegistry?> icons;

  SplashWindowController? _splash;
  WindowEntry? _splashEntry;

  /// macOS Reduce motion for the splash card; Flutter's embedder never
  /// reports it, the shell does.
  final _reduceMotion = ValueNotifier<bool>(false);
  StreamSubscription<ShellTheme>? _shellChanges;

  /// Whether `runWidget` has already run — it may only run once.
  var _presented = false;

  @override
  Future<void> openSplash({
    required ValueListenable<String> status,
    required ValueListenable<SplashVersion?> version,
  }) async {
    final SplashWindowController splash = await SplashWindowController.create(size: splashWindowSize);
    _followReduceMotion();
    final entry = WindowEntry(
      controller: splash,
      builder: windows.capture((_) => SplashCard(status: status, version: version, reduceMotion: _reduceMotion)),
    );
    _splash = splash;
    _splashEntry = entry;
    _present(entry);
  }

  @override
  Future<void> openMain(Widget content) async =>
      _present(await windows.create(key: mainWindowKey, title: mainWindowTitle, builder: (_) => content));

  @override
  Future<void> openProjects(Widget content) async => _present(
    await windows.create(
      key: projectsWindowKey,
      title: projectsWindowTitle,
      builder: (_) => content,
      dialog: projectsWindowSpec,
    ),
  );

  @override
  Future<void> dismissSplash(Duration fade) async {
    final SplashWindowController? splash = _splash;
    final WindowEntry? entry = _splashEntry;
    if (splash == null || entry == null) {
      return;
    }
    _splash = null;
    _splashEntry = null;
    // The engine shows a window right after its first frame was presented.
    // `endOfFrame` completes when that frame is built and handed over, a few
    // milliseconds earlier, so the fade starts while the main window pops up
    // underneath the floating splash. A very slow first raster would let the
    // splash fade before the window shows.
    await WidgetsBinding.instance.endOfFrame;
    await splash.fadeOut(duration: fade);
    windows.unregister(entry);
    splash.destroy();
    await _shellChanges?.cancel();
    _shellChanges = null;
  }

  /// Feeds [_reduceMotion] from the shell for as long as the splash is up. A
  /// shell that does not answer leaves the loader animating.
  void _followReduceMotion() {
    void apply(ShellTheme theme) => _reduceMotion.value = theme.reduceMotion;
    _shellChanges = ZanshinShell.onThemeChanged.listen(apply);
    unawaited(
      ZanshinShell.getTheme().then(apply).catchError((Object error, StackTrace stackTrace) {
        _log.warning('The shell theme could not be read for the splash', error, stackTrace);
      }),
    );
  }

  /// Hands [entry] to the engine.
  ///
  /// The first window must be part of `runWidget`: the engine only shows a
  /// window once it has presented a frame, and only that warm-up frame is
  /// timer-driven — every later frame waits for the display link of a view
  /// that does not exist yet. Whichever window comes first (the splash on a
  /// slow boot, the first app window on a fast one) is therefore the one
  /// `runWidget` gets; the rest go through the registry.
  void _present(WindowEntry entry) {
    if (_presented) {
      windows.register(entry);
      return;
    }
    _presented = true;
    // The menu bar sits above every window and keeps its shape from this first frame on.
    runWidget(
      ValueListenableBuilder<AppMenuModel?>(
        valueListenable: menu,
        builder: (context, model, child) => AppMenuBar(model: model, child: child!),
        child: ValueListenableBuilder<IconRegistry?>(
          valueListenable: icons,
          builder: (context, registry, child) => IconRegistryScope(registry: registry, child: child!),
          child: WindowManager(initialWindows: <WindowEntry>[entry]),
        ),
      ),
    );
  }
}
