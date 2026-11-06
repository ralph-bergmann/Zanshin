// SPDX-License-Identifier: MIT

// The windowing API is experimental and only reachable through implementation
// imports; see https://github.com/flutter/flutter/issues/30701.
// ignore_for_file: invalid_use_of_internal_member, implementation_imports

import 'dart:async';
import 'dart:ui' show AppExitType;

import 'package:flutter/services.dart';
import 'package:flutter/src/widgets/_window.dart';
import 'package:flutter/widgets.dart';
import 'package:logging/logging.dart';

import '../../l10n/strings.dart';
import 'remembered_dialog_window_controller.dart';
import 'remembered_window_controller.dart';

export 'remembered_window_controller.dart'
    show DialogWindowPlan, NativeWindowPlan, ProjectWindowPlan, WindowFrameMode, WindowLevel;

final _log = Logger('zanshin.window');

/// The one project window's key, which is also its frame key whichever project it shows (decision 16.42 j).
const mainWindowKey = 'main';

/// The Projects window's key (Story 11.6; decision 16.13).
const projectsWindowKey = 'projects';

/// The Settings window's key (Story 11.7).
const settingsWindowKey = 'settings';

/// The jj log Configurations window's key (Story 10.22; decision 16.19).
const revsetConfigsWindowKey = 'revset-configs';

/// First-launch content size of a project window; afterwards the frame
/// remembered under the window's key wins.
const defaultWindowSize = Size(1200, 800);

/// Smallest content size of the project window (decision 16.37; DS readme.md:193), the default of every project
/// window; a dialog window passes its own ([DialogWindowSpec.constraints]) and never takes this one.
const defaultWindowConstraints = BoxConstraints(minWidth: 880, minHeight: 560);

/// How a dialog window is made: a parentless `DialogWindowControllerMacOS` (Story 11.12 item 1).
///
/// - [constraints] are required: a dialog window passes its own minimum and never inherits the project window's
///   (Claude's proposal, 11.4's note).
/// - [size] null sizes the window to its content; it then needs finite maximum [constraints] (r3out windows.md C3)
///   and no minimum: the engine reports the window's still empty view first, and metrics below a minimum are refused
///   (`FlutterEngineSendWindowMetricsEvent`: "Width and height must be within the specified constraints"), so the
///   window would never get its first frame. Its width comes from the content (a stretched column takes the maximum).
///   The runner places it once its content size is known.
/// - [frame] and [level] reach the runner's `restore`; [keepsAppAlive] decides the exit rule (decision 16.42 f):
///   Projects keeps the app alive, Settings and Configurations do not.
@immutable
class DialogWindowSpec {
  /// A dialog within [constraints]; see the class for the rest.
  const DialogWindowSpec({
    required this.constraints,
    this.size,
    this.resizable = true,
    this.frame = WindowFrameMode.full,
    this.level = WindowLevel.normal,
    this.keepsAppAlive = false,
  });

  /// The window's content constraints, its minimum included.
  final BoxConstraints constraints;

  /// The first-launch content size, or null for a window sized to its content.
  final Size? size;

  /// Whether the user can resize the window (and zoom it).
  final bool resizable;

  /// What the runner remembers of the window's frame.
  final WindowFrameMode frame;

  /// The window's level.
  final WindowLevel level;

  /// Whether an open window of this kind keeps the process running.
  final bool keepsAppAlive;
}

/// The Projects window's title, for the Window menu and Mission Control (Story 11.6), in the platform's strings.
String get projectsWindowTitle => platformStrings().projectsTitle;

/// The Projects window (Story 11.6 item 1; DS readme.md:191): 900 × 640, resizable down to 680 × 440, the full frame
/// remembered, the normal level, and it keeps the app alive.
const projectsWindowSpec = DialogWindowSpec(
  size: Size(900, 640),
  constraints: BoxConstraints(minWidth: 680, minHeight: 440),
  keepsAppAlive: true,
);

/// The Settings window (Stories 11.7, 11.19; DS readme.md:189, Window.prompt.md): sized to its content at 620 wide
/// and at most 740 high, resizable (and zoomable), only its position remembered, and it does not keep the app alive.
/// No minimum at creation: a window sized to its content takes none (see [DialogWindowSpec.size]); the content sets
/// [settingsWindowMinimum] once its first frame is up and keeps its height following the shown tab until the user
/// resizes it (`SettingsHeightFollower`).
const settingsWindowSpec = DialogWindowSpec(
  constraints: BoxConstraints(maxWidth: 620, maxHeight: 740),
  frame: WindowFrameMode.position,
);

/// The Settings window's smallest content size (Story 11.19), set after its first frame.
const settingsWindowMinimum = Size(620, 420);

/// The jj log Configurations window (Story 10.22; DS RevsetDialog.prompt.md, the story's 820 px minimum): 880 × 580,
/// resizable down to 820 × 460, the full frame remembered, floating above the project window while Zanshin is active,
/// and it does not keep the app alive.
const revsetConfigsWindowSpec = DialogWindowSpec(
  size: Size(880, 580),
  constraints: BoxConstraints(minWidth: 820, minHeight: 460),
  level: WindowLevel.floatingWhileActive,
);

/// What [AppWindows] asks its [AppWindowFactory] for: the window [key] titled [title], with [dialog]'s spec or, for a
/// project window, of [size] within [constraints]; its lifecycle runs through [delegate].
@immutable
class AppWindowRequest {
  /// The request for the window [key].
  const AppWindowRequest({
    required this.key,
    required this.title,
    required this.delegate,
    required this.constraints,
    this.size,
    this.dialog,
  });

  /// The window's key, also its frame key.
  final String key;

  /// The window's title.
  final String title;

  /// The window's lifecycle: hand it to the controller as its delegate.
  final AppWindowLifecycle delegate;

  /// The content constraints: the project window's, or [dialog]'s.
  final BoxConstraints constraints;

  /// The first-launch content size; null only for a dialog sized to its content.
  final Size? size;

  /// The dialog window's spec, or null for a project window.
  final DialogWindowSpec? dialog;
}

/// Creates the native window behind [AppWindows.create]: a `WindowController` for a project window, a
/// `DialogWindowController` for a dialog window.
///
/// The seam exists for tests: the real factory ([createRememberedWindow]) reaches the engine through FFI and a
/// method channel, neither of which a widget test can serve.
typedef AppWindowFactory = Future<BaseWindowController> Function(AppWindowRequest request);

/// What the native window for [request] is made of: for a project window a [ProjectWindowPlan] of [request]'s size
/// ([defaultWindowSize] without one) within its constraints; for a dialog window a [DialogWindowPlan] from its
/// [DialogWindowSpec] — size, constraints, resizable, frame and level.
///
/// Pure, so a test pins every request kind's plan; [createRememberedWindow] only carries it out.
NativeWindowPlan planNativeWindow(AppWindowRequest request) {
  final DialogWindowSpec? dialog = request.dialog;
  if (dialog == null) {
    return ProjectWindowPlan(
      key: request.key,
      title: request.title,
      size: request.size ?? defaultWindowSize,
      constraints: request.constraints,
    );
  }
  return DialogWindowPlan(
    key: request.key,
    title: request.title,
    size: dialog.size,
    constraints: dialog.constraints,
    resizable: dialog.resizable,
    frame: dialog.frame,
    level: dialog.level,
  );
}

/// The real [AppWindowFactory]: carries out [planNativeWindow]'s plan — a [RememberedWindowController] for a project
/// window, a [RememberedDialogWindowController] for a dialog window.
///
/// The plan is the tested part; what needs the engine is the controller's constructor call with the plan's values and
/// the channel call with its runner arguments.
Future<BaseWindowController> createRememberedWindow(AppWindowRequest request) => switch (planNativeWindow(request)) {
  final ProjectWindowPlan plan => RememberedWindowController.create(plan, delegate: request.delegate),
  final DialogWindowPlan plan => RememberedDialogWindowController.create(plan, delegate: request.delegate),
};

/// Ends the process once no window keeps it alive.
typedef AppExit = Future<void> Function();

Future<void> _exitProcess() => ServicesBinding.instance.exitApplication(AppExitType.required);

/// A window this instance keys: its `entry` and whether it keeps the process running.
typedef _OpenWindow = ({WindowEntry entry, bool keepsAppAlive});

/// The app's windows, keyed so the same window never opens twice.
///
/// Every window is created from Dart and lives in the [WindowRegistry] that [WindowManager] owns. A destroyed
/// window removes itself again.
///
/// - **Kinds:** a project window (the regular `WindowController`, the main chrome, [defaultWindowConstraints]) or,
///   with a [DialogWindowSpec], a parentless dialog window with its own constraints.
/// - **Exit rule** (decision 16.42 f): the process ends when a window unregisters and no open window keeps it alive.
///   A project window always does; a dialog window as its spec says (Projects yes, Settings and Configurations no).
///   The runner no longer terminates on its own when the last window closes.
/// - **Close requests** (the red button) go to the key's close handler ([setCloseHandler]); a key without one is
///   destroyed at once.
/// - **Close guards** ([addCloseGuard], [mayClose]) are the hook for 10.22's "Discard changes?": closing the project
///   and quitting ask them first.
class AppWindows {
  AppWindows({this.createController = createRememberedWindow, this.exitProcess = _exitProcess});

  /// Builds the native window controller. Defaults to the real one; a test
  /// passes a factory over the generic controllers instead.
  final AppWindowFactory createController;

  /// Injected for tests as well: the test binding refuses a required
  /// application exit outright.
  final AppExit exitProcess;

  /// The open windows by key.
  final _open = <String, _OpenWindow>{};

  /// The windows being created, by key, so a second open of the same key waits for the first, and a window on its
  /// way counts for the exit rule.
  final _creating = <String, ({Future<WindowEntry> future, bool keepsAppAlive})>{};

  final _closeHandlers = <String, Future<void> Function()>{};
  final _guards = <Future<bool> Function()>[];

  /// The registry [WindowManager] owns — see [attach].
  WindowRegistry? _registry;
  final _attached = Completer<void>();

  /// Takes over the registry of the running [WindowManager].
  ///
  /// [WindowManager] keeps its registry private; the only way in is
  /// [WindowRegistry.of] from a window's content, so [capture] wraps every
  /// window builder and hands it over on the first build. The first call wins:
  /// every window resolves the same registry.
  void attach(WindowRegistry registry) {
    if (_registry != null) {
      return;
    }
    _registry = registry;
    _attached.complete();
  }

  /// Completes once a registry is attached: from then on windows can be registered.
  Future<void> get attached => _attached.future;

  /// Wraps [builder] so the window it builds hands its registry to [attach].
  WidgetBuilder capture(WidgetBuilder builder) => (context) {
    attach(WindowRegistry.of(context));
    return builder(context);
  };

  /// Whether the window [key] is open (or being created).
  bool isOpen(String key) => _open.containsKey(key) || _creating.containsKey(key);

  /// The controller of the open window [key], or null.
  BaseWindowController? controllerOf(String key) => _open[key]?.entry.controller;

  /// Creates the window for [key] and returns its entry **without**
  /// registering it.
  ///
  /// A project window takes [size] (default [defaultWindowSize]) and [constraints] (default
  /// [defaultWindowConstraints]); with a [dialog] spec the window is a dialog window, which takes its size and
  /// constraints from the spec only — passing [size] or [constraints] as well is an [ArgumentError].
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
    Size? size,
    BoxConstraints? constraints,
    DialogWindowSpec? dialog,
  }) async {
    if (isOpen(key)) {
      // Overwriting would leave the open window registered but unreachable:
      // no longer activatable, and its key freed for a second native window.
      throw StateError('A window for "$key" is already open; use openOrActivate.');
    }
    if (dialog != null && (size != null || constraints != null)) {
      throw ArgumentError('A dialog window takes its size and constraints from its DialogWindowSpec.');
    }
    if (dialog != null && dialog.size == null && dialog.constraints.smallest != Size.zero) {
      throw ArgumentError('A window sized to its content takes no minimum constraints; it would never show.');
    }
    // Recorded before the first await, so a second open of the key sees it.
    final Future<WindowEntry> creating = _create(
      key: key,
      title: title,
      builder: builder,
      size: dialog == null ? size ?? defaultWindowSize : dialog.size,
      constraints: dialog?.constraints ?? constraints ?? defaultWindowConstraints,
      dialog: dialog,
    );
    _creating[key] = (future: creating, keepsAppAlive: dialog?.keepsAppAlive ?? true);
    try {
      return await creating;
    } finally {
      _creating.remove(key);
    }
  }

  Future<WindowEntry> _create({
    required String key,
    required String title,
    required WidgetBuilder builder,
    required Size? size,
    required BoxConstraints constraints,
    required DialogWindowSpec? dialog,
  }) async {
    final lifecycle = AppWindowLifecycle._(this, key);
    final BaseWindowController controller = await createController(
      AppWindowRequest(
        key: key,
        title: title,
        delegate: lifecycle,
        constraints: constraints,
        size: size,
        dialog: dialog,
      ),
    );
    final entry = WindowEntry(controller: controller, builder: capture(builder));
    lifecycle._entry = entry;
    _open[key] = (entry: entry, keepsAppAlive: dialog?.keepsAppAlive ?? true);
    return entry;
  }

  /// Opens the window for [key], or brings it to the front when it is already open; [size], [constraints] and
  /// [dialog] as for [create].
  Future<void> openOrActivate({
    required String key,
    required String title,
    required WidgetBuilder builder,
    Size? size,
    BoxConstraints? constraints,
    DialogWindowSpec? dialog,
  }) async {
    if (_creating[key] case (:final Future<WindowEntry> future, keepsAppAlive: _)) {
      // The first open registers the window, and the engine shows it key on its first frame; activating it before
      // that frame would show an empty window.
      await future;
      return;
    }
    if (_open[key]?.entry.controller case final BaseWindowController open) {
      _activate(open);
      return;
    }
    register(
      await create(key: key, title: title, builder: builder, size: size, constraints: constraints, dialog: dialog),
    );
  }

  /// Brings the open window [key] to the front; nothing when it is not open.
  void activate(String key) {
    if (controllerOf(key) case final BaseWindowController open) {
      _activate(open);
    }
  }

  static void _activate(BaseWindowController controller) {
    switch (controller) {
      case final WindowController window:
        window.activate();
      case final DialogWindowController dialog:
        dialog.activate();
      case _:
        break;
    }
  }

  /// The Flutter view id of the open window [key], or null.
  int? viewIdOf(String key) => controllerOf(key)?.rootView.viewId;

  /// The key of the open window showing the Flutter view [viewId], or null.
  String? keyOfView(int viewId) {
    for (final MapEntry<String, _OpenWindow> open in _open.entries) {
      if (open.value.entry.controller.rootView.viewId == viewId) {
        return open.key;
      }
    }
    return null;
  }

  /// Destroys the window [key] (it unregisters itself); nothing when it is not open.
  void close(String key) => controllerOf(key)?.destroy();

  /// Asks to close the open window [key] as its red button does (⌘W): its close handler, else it is destroyed.
  void requestClose(String key) {
    if (controllerOf(key) case final BaseWindowController controller) {
      _closeRequested(key, controller);
    }
  }

  /// Runs [handler] instead of destroying the window [key] when the user asks to close it (the red button); null
  /// restores the default, which destroys it.
  void setCloseHandler(String key, Future<void> Function()? handler) {
    if (handler == null) {
      _closeHandlers.remove(key);
    } else {
      _closeHandlers[key] = handler;
    }
  }

  /// Adds [guard] to what [mayClose] asks; the returned callback removes it again.
  VoidCallback addCloseGuard(Future<bool> Function() guard) {
    _guards.add(guard);
    return () => _guards.remove(guard);
  }

  /// Asks every close guard in the order they were added and answers false at the first that refuses.
  Future<bool> mayClose() async {
    for (final guard in List<Future<bool> Function()>.of(_guards)) {
      if (!await guard()) {
        return false;
      }
    }
    return true;
  }

  /// Adds [entry] to the registry, which renders its window.
  void register(WindowEntry entry) => _attachedRegistry.register(entry);

  /// Removes [entry] from the registry; once no open window keeps the app alive the process ends, because in this
  /// runner shape AppKit no longer does it.
  ///
  /// Also takes windows this instance does not key, so the splash goes through the same exit rule.
  void unregister(WindowEntry entry) {
    _open.removeWhere((_, open) => identical(open.entry, entry));
    _attachedRegistry.unregister(entry);
    if (!_open.values.any((open) => open.keepsAppAlive) && !_creating.values.any((open) => open.keepsAppAlive)) {
      unawaited(exitProcess());
    }
  }

  void _closeRequested(String key, BaseWindowController controller) {
    final Future<void> Function()? handler = _closeHandlers[key];
    if (handler == null) {
      controller.destroy();
      return;
    }
    // WHY a timer: Flutter's macOS windowing calls the red button's delegate straight from AppKit
    // (`FlutterWindowOwner windowShouldClose:`), outside an engine task, and the engine drains microtasks only after
    // its own tasks — in an inactive app the next one is the focus event, so every `await` of the handler would stall
    // until then. A timer is such a task, posted now. Upstream: https://github.com/flutter/flutter/issues/195963
    // (drop the timer once it is fixed).
    Timer.run(
      () => unawaited(
        handler().catchError((Object error, StackTrace stackTrace) {
          _log.severe('Closing the window $key failed', error, stackTrace);
        }),
      ),
    );
  }

  /// The captured registry, or a loud failure.
  ///
  /// Both callers are on the dangerous side of the seam: without a registry a
  /// created window would never be rendered, and the exit rule would never fire
  /// — the app would sit there with no window and no way to quit. Better to blow
  /// up than to do nothing.
  WindowRegistry get _attachedRegistry {
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

/// A window's lifecycle for [AppWindows]: a close request goes to the key's close handler (none: the window is
/// destroyed), and a destroyed window unregisters, once.
///
/// One class serves both controller kinds: the two delegate mixins' `onWindowCloseRequested` take different
/// controller types, so it implements both with the [BaseWindowController] they share.
final class AppWindowLifecycle implements WindowControllerDelegate, DialogWindowControllerDelegate {
  AppWindowLifecycle._(this._windows, this._key);

  final AppWindows _windows;
  final String _key;

  /// Assigned right after the controller — the entry cannot exist earlier.
  late final WindowEntry _entry;
  var _destroyed = false;

  @override
  void onWindowCloseRequested(BaseWindowController controller) => _windows._closeRequested(_key, controller);

  @override
  void onWindowDestroyed() {
    // `destroy` may be called more than once; the window unregisters on the first.
    if (_destroyed) {
      return;
    }
    _destroyed = true;
    _windows.unregister(_entry);
  }
}
