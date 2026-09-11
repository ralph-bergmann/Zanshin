// SPDX-License-Identifier: MIT

// The windowing API is experimental and only reachable through implementation
// imports; see https://github.com/flutter/flutter/issues/30701.
// ignore_for_file: invalid_use_of_internal_member, implementation_imports

import 'package:flutter/src/widgets/_window.dart';
import 'package:flutter/widgets.dart';

import '../window/app_windows.dart';
import '../window/splash_window_controller.dart';
import 'splash_card.dart';
import 'zanshin_bootstrap.dart';

/// Key the main window's frame is remembered under, in the
/// `<bundle id>.window_frames` defaults suite.
const mainWindowKey = 'main';

/// Title of the main window.
const mainWindowTitle = 'Zanshin';

/// The real [BootWindowHost]: the only place that creates windows.
///
/// Not unit-tested — everything it touches (`runWidget`, the macOS window
/// controllers, the window channels) needs a live engine. The sequencing it
/// serves is tested against a fake host instead; this class is covered by the
/// runtime smoke check.
class ZanshinWindowHost implements BootWindowHost {
  ZanshinWindowHost({required this.windows});

  /// Keyed registry of the app's windows; also the exit-when-empty rule.
  final AppWindows windows;

  SplashWindowController? _splash;
  WindowEntry? _splashEntry;

  /// Whether `runWidget` has already run — it may only run once.
  var _presented = false;

  @override
  Future<void> openSplash() async {
    final SplashWindowController splash = await SplashWindowController.create(size: splashWindowSize);
    final entry = WindowEntry(controller: splash, builder: windows.capture((_) => const SplashCard()));
    _splash = splash;
    _splashEntry = entry;
    _present(entry);
  }

  @override
  Future<void> openMain(Widget content) async =>
      _present(await windows.create(key: mainWindowKey, title: mainWindowTitle, builder: (_) => content));

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
  }

  /// Hands [entry] to the engine.
  ///
  /// The first window must be part of `runWidget`: the engine only shows a
  /// window once it has presented a frame, and only that warm-up frame is
  /// timer-driven — every later frame waits for the display link of a view
  /// that does not exist yet. Whichever window comes first (the splash on a
  /// slow boot, the main window on a fast one) is therefore the one
  /// `runWidget` gets; the rest go through the registry.
  void _present(WindowEntry entry) {
    if (_presented) {
      windows.register(entry);
      return;
    }
    _presented = true;
    runWidget(WindowManager(initialWindows: <WindowEntry>[entry]));
  }
}
