// SPDX-License-Identifier: MIT

// The windowing API is experimental and only reachable through implementation
// imports; see https://github.com/flutter/flutter/issues/30701.
// ignore_for_file: invalid_use_of_internal_member, implementation_imports

import 'dart:async';
import 'dart:ui' show AppExitType;

import 'package:flutter/services.dart';
import 'package:flutter/src/widgets/_window.dart';
import 'package:flutter/widgets.dart';

import 'remembered_window_controller.dart';

/// First-launch content size of an app window; afterwards the frame
/// remembered under the window's key wins.
const defaultWindowSize = Size(1200, 800);

/// Smallest content size of an app window.
const defaultWindowConstraints = BoxConstraints(minWidth: 900, minHeight: 600);

/// Creates the native window behind [AppWindows.create].
///
/// The seam exists for tests: the real factory
/// ([RememberedWindowController.create]) reaches the engine through FFI and a
/// method channel, neither of which a widget test can serve.
typedef AppWindowFactory = Future<WindowController> Function({
  required String key,
  required String title,
  required Size size,
  required BoxConstraints constraints,
  required WindowControllerDelegate delegate,
  required bool chrome,
});

/// Ends the process once the last window is gone.
typedef AppExit = Future<void> Function();

Future<void> _exitProcess() => ServicesBinding.instance.exitApplication(AppExitType.required);

/// The app's windows, keyed so the same window never opens twice.
///
/// Every window is created from Dart and lives in the [WindowRegistry] that
/// [WindowManager] owns. A destroyed window removes itself again, and the last
/// one to go takes the process with it — the runner no longer terminates on
/// its own when the last window closes.
class AppWindows {
  AppWindows({this.createController = RememberedWindowController.create, this.exitProcess = _exitProcess});

  /// Builds the native window controller. Defaults to the real one; a test
  /// passes a factory over the generic [WindowController] instead.
  final AppWindowFactory createController;

  /// Injected for tests as well: the test binding refuses a required
  /// application exit outright.
  final AppExit exitProcess;

  /// The open windows by key.
  final _entries = <String, WindowEntry>{};

  /// The registry [WindowManager] owns — see [attach].
  WindowRegistry? _registry;

  /// Takes over the registry of the running [WindowManager].
  ///
  /// [WindowManager] keeps its registry private; the only way in is
  /// [WindowRegistry.of] from a window's content, so [capture] wraps every
  /// window builder and hands it over on the first build. The first call wins:
  /// every window resolves the same registry.
  void attach(WindowRegistry registry) => _registry ??= registry;

  /// Wraps [builder] so the window it builds hands its registry to [attach].
  WidgetBuilder capture(WidgetBuilder builder) => (context) {
    attach(WindowRegistry.of(context));
    return builder(context);
  };

  /// Creates the window for [key] and returns its entry **without**
  /// registering it.
  ///
  /// The very first window has to exist before `runWidget`: the engine only
  /// shows a window once it has presented a frame, and only the warm-up frame
  /// is timer-driven — every later frame waits for the display link of a view
  /// that would not exist yet. So the first window goes into
  /// [WindowManager.initialWindows], not into the registry.
  Future<WindowEntry> create({
    required String key,
    required String title,
    required WidgetBuilder builder,
    Size size = defaultWindowSize,
    BoxConstraints constraints = defaultWindowConstraints,
  }) async {
    if (_entries.containsKey(key)) {
      // Overwriting would leave the open window registered but unreachable:
      // no longer activatable, and its key freed for a second native window.
      throw StateError('A window for "$key" is already open; use openOrActivate.');
    }
    final lifecycle = _WindowLifecycle(this);
    final WindowController controller = await createController(
      key: key,
      title: title,
      size: size,
      constraints: constraints,
      delegate: lifecycle,
      // Every app window wears the app's chrome; the splash is not one of
      // these and is configured through its own channel.
      chrome: true,
    );
    final entry = WindowEntry(controller: controller, builder: capture(builder));
    lifecycle.entry = entry;
    _entries[key] = entry;
    return entry;
  }

  /// Opens the window for [key], or brings it to the front when it is already
  /// open.
  Future<void> openOrActivate({
    required String key,
    required String title,
    required WidgetBuilder builder,
    Size size = defaultWindowSize,
    BoxConstraints constraints = defaultWindowConstraints,
  }) async {
    if (_entries[key]?.controller case final WindowController open) {
      open.activate();
      return;
    }
    register(await create(key: key, title: title, builder: builder, size: size, constraints: constraints));
  }

  /// Adds [entry] to the registry, which renders its window.
  void register(WindowEntry entry) => _attached.register(entry);

  /// Removes [entry] from the registry; once no window is left the process
  /// ends, because in this runner shape AppKit no longer does it.
  ///
  /// Also takes windows this instance does not key, so the splash can go
  /// through the same exit rule.
  void unregister(WindowEntry entry) {
    _entries.removeWhere((_, open) => identical(open, entry));
    final WindowRegistry registry = _attached..unregister(entry);
    if (registry.windows.isEmpty) {
      unawaited(exitProcess());
    }
  }

  /// The captured registry, or a loud failure.
  ///
  /// Both callers are on the dangerous side of the seam: without a registry a
  /// created window would never be rendered, and the exit-when-empty rule
  /// would never fire — the app would sit there with no window and no way to
  /// quit. Better to blow up than to do nothing.
  WindowRegistry get _attached {
    final WindowRegistry? registry = _registry;
    if (registry == null) {
      throw StateError(
        'No WindowRegistry attached. The first window built must pass through '
        'capture() (or attach() must be called) before windows are registered.',
      );
    }
    return registry;
  }
}

/// Unregisters a destroyed window; the last one takes the process with it.
class _WindowLifecycle with WindowControllerDelegate {
  _WindowLifecycle(this.windows);

  final AppWindows windows;

  /// Assigned right after the controller — the entry cannot exist earlier.
  late final WindowEntry entry;

  @override
  void onWindowDestroyed() {
    super.onWindowDestroyed();
    windows.unregister(entry);
  }
}
