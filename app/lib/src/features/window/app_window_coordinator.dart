// SPDX-License-Identifier: MIT

// The windowing API is experimental and only reachable through implementation
// imports; see https://github.com/flutter/flutter/issues/30701.
// ignore_for_file: invalid_use_of_internal_member, implementation_imports

import 'dart:async';
import 'dart:io';
import 'dart:ui' show ViewFocusEvent, ViewFocusState;

import 'package:flutter/services.dart';
import 'package:flutter/src/widgets/_window.dart';
import 'package:flutter/widgets.dart';
import 'package:logging/logging.dart';

import '../bootstrap/boot_window_host.dart' show mainWindowTitle;
import '../bootstrap/zanshin_bootstrap.dart';
import '../projects/project_session.dart';
import 'app_window_actions.dart';
import 'app_windows.dart';
import 'remembered_window_controller.dart' show windowFramesChannel;

final _log = Logger('zanshin.window');

bool _defaultFolderExists(String path) => Directory(path).existsSync();

/// Which window shows when (Story 11.12 item 7; decisions 16.13, 16.15, 16.16, 16.42 f; 11.5's and 11.6's design
/// updates): the launch window, the switch between Projects and the one project window, the project window's red
/// button and the Dock's reopen.
///
/// - **Launch** ([start]): with a stored open project whose folder exists, the project window comes first and the
///   project reopens beside it; otherwise Projects is the first and only window. Once the first window is up
///   (`onShown`) the coordinator waits for the reopen and reconciles: a project is open → the project window; none →
///   Projects, and the project window goes.
/// - **Following the session:** when a project opens the project window opens (or comes forward); when the open
///   project closes, Projects opens first and then the project window and jj log Configurations go, so no moment
///   counts zero windows that keep the app alive.
/// - **The red button** on the project window asks the close guards (10.22's "Discard changes?"), then closes the
///   project — or, with none open, shows Projects instead of the window.
/// - **Projects' opens** (the Projects content's `onOpened`): the project window opens or switches, then Projects
///   closes — unless the outcome carries warnings: Projects then stays with its notice and comes forward once the
///   project window is up, after its first focus event (Claude's proposal until 10.23's toast).
/// - **Dock reopen** (the runner's `reopen` on `zanshin/window_frames`, sent only when no window is visible): a
///   minimised project window comes back, else Projects opens or comes forward.
///
/// Nothing acts before the first window is up: until then a second project window could be created next to the boot's.
/// The transitions run one at a time, in call order. Each window's content is built once, inside an
/// [AppWindowActionsScope] over this coordinator. A project window the coordinator created is not activated before its
/// view's first focus event: the engine shows a new window key on its first frame, and activating it earlier would show
/// it empty.
class AppWindowCoordinator implements AppWindowActions {
  /// A coordinator of [windows] over [session], building the project window's content with [buildProject] and the
  /// Projects window's with [buildProjects] (which hands its `onOpened` on); `folderExists` (the stored project's
  /// folder check) and `channel` (the runner's) are seams for tests.
  AppWindowCoordinator({
    required this.windows,
    required this.session,
    required this.buildProject,
    required this.buildProjects,
    this._folderExists = _defaultFolderExists,
    this._channel = windowFramesChannel,
  });

  /// The app's windows.
  final AppWindows windows;

  /// The open project.
  final ProjectSession session;

  /// The project window's content: its root over `HomePage`.
  final Widget Function() buildProject;

  /// The Projects window's content: its root over the Projects content, whose `onOpened` is the given callback.
  final Widget Function(ValueChanged<ProjectOpened> onOpened) buildProjects;

  final bool Function(String path) _folderExists;
  final MethodChannel _channel;

  /// The launch's reopen, until the first window is up.
  Future<void>? _reopen;

  /// The project window the coordinator created last, until its view's first focus event.
  _FirstFocus? _projectFirstFocus;

  /// How long Projects waits for a new project window's first focus event before it comes forward anyway.
  static const _firstFocusTimeout = Duration(seconds: 2);

  /// Completes once the first window is up and the coordinator has reconciled.
  final _ready = Completer<void>();
  var _wasOpen = false;
  var _queue = Future<void>.value();

  bool get _projectOpen => session.repo != null;

  /// Decides the first window (the launch), starts the reopen of the stored project, takes the project window's close
  /// requests and the runner's reopen calls, and hands the boot its first window.
  BootFirstWindow start() {
    final String? stored = session.registry.value.openProject;
    final bool projectFirst = stored != null && _folderExists(stored);
    // The content first: a throw here leaves the boot's failure page without a close handler that waits forever.
    final Widget content = projectFirst ? _projectContent() : _projectsContent();
    windows.setCloseHandler(mainWindowKey, _closeProjectWindow);
    _channel.setMethodCallHandler(_handleNativeCall);
    // `_shown` awaits it and logs a failure; until then nothing listens.
    _reopen = session.reopenLast()..ignore();
    return BootFirstWindow(
      content: content,
      kind: projectFirst ? BootWindowKind.project : BootWindowKind.projects,
      onShown: _shown,
    );
  }

  @override
  Future<void> openProjects() async {
    await _ready.future;
    await _serial(_openProjects);
  }

  /// The Dock's reopen with no window visible: the minimised project window comes back, else Projects. Before the
  /// first window is up it does nothing — the boot is about to show one.
  Future<void> reopen() async {
    if (!_ready.isCompleted) {
      return;
    }
    await _serial(() async {
      if (windows.controllerOf(mainWindowKey) case final WindowController main) {
        if (main.isMinimized) {
          main.setMinimized(false);
        }
        if (_projectWindowShown) {
          main.activate();
        }
        return;
      }
      await _openProjects();
    });
  }

  Future<Object?> _handleNativeCall(MethodCall call) async {
    if (call.method != 'reopen') {
      throw MissingPluginException('zanshin/window_frames has no Dart method ${call.method}');
    }
    await reopen();
    return null;
  }

  /// The first window is up: the reopen is awaited, the session followed from now on, and the windows reconciled
  /// with what opened.
  Future<void> _shown() async {
    try {
      await _reopen;
    } catch (error, stackTrace) {
      // Reopening reports its failures as outcomes; a throw is a bug, and the windows still have to settle.
      _log.severe('Reopening the last project failed', error, stackTrace);
    }
    _reopen = null;
    _wasOpen = _projectOpen;
    session.addListener(_sessionChanged);
    try {
      await _serial(_wasOpen ? _ensureProjectWindow : _showProjectsInstead);
    } finally {
      _ready.complete();
    }
  }

  void _sessionChanged() {
    final bool open = _projectOpen;
    if (open == _wasOpen) {
      return;
    }
    _wasOpen = open;
    unawaited(
      _serial(open ? _ensureProjectWindow : _showProjectsInstead).catchError((Object error, StackTrace stackTrace) {
        _log.severe('Following the open project with the windows failed', error, stackTrace);
      }),
    );
  }

  /// The project window's red button.
  Future<void> _closeProjectWindow() async {
    await _ready.future;
    await _serial(() async {
      if (!await windows.mayClose()) {
        return;
      }
      if (_projectOpen) {
        // The session's notification queues the switch to Projects behind this task.
        await session.closeProject();
      } else {
        await _showProjectsInstead();
      }
    });
  }

  /// A project opened in Projects ([outcome]): the project window opens or switches, then Projects closes, or stays
  /// with the outcome's warnings in its notice and comes forward.
  void _openedInProjects(ProjectOpened outcome) => unawaited(_afterOpenInProjects(outcome));

  Future<void> _afterOpenInProjects(ProjectOpened outcome) async {
    await _ready.future;
    try {
      await _serial(() async {
        await _ensureProjectWindow();
        if (outcome.warnings.isEmpty) {
          windows.close(projectsWindowKey);
        }
      });
      if (outcome.warnings.isNotEmpty) {
        // A new project window shows key on its first frame; Projects comes forward after it, or it would be hidden.
        final _FirstFocus? first = _projectFirstFocus;
        if (first != null && !first.isDone) {
          await first.done.timeout(_firstFocusTimeout, onTimeout: () {});
        }
        windows.activate(projectsWindowKey);
      }
    } catch (error, stackTrace) {
      _log.severe('Showing the opened project failed', error, stackTrace);
    }
  }

  /// Whether the project window the coordinator created last has had its first focus event (or none is pending).
  bool get _projectWindowShown => _projectFirstFocus?.isDone ?? true;

  /// Opens the project window, or brings it forward once it has shown (see [_projectWindowShown]).
  Future<void> _ensureProjectWindow() async {
    if (windows.isOpen(mainWindowKey)) {
      if (_projectWindowShown) {
        windows.activate(mainWindowKey);
      }
      return;
    }
    await _show(mainWindowKey, mainWindowTitle, _projectContent);
    final BaseWindowController? created = windows.controllerOf(mainWindowKey);
    if (created != null) {
      _projectFirstFocus?.finish();
      _projectFirstFocus = _FirstFocus(created.rootView.viewId);
    }
  }

  Future<void> _openProjects() =>
      _show(projectsWindowKey, projectsWindowTitle, _projectsContent, dialog: projectsWindowSpec);

  /// Opens the window [key] showing what [build] makes, or brings it forward when it is open. The content is built
  /// once, before the window: the window manager calls a window's builder again whenever any window opens or closes.
  Future<void> _show(String key, String title, Widget Function() build, {DialogWindowSpec? dialog}) {
    // An open window keeps its content; openOrActivate then only brings it forward and never builds.
    final Widget content = windows.isOpen(key) ? const SizedBox.shrink() : build();
    return windows.openOrActivate(key: key, title: title, builder: (_) => content, dialog: dialog);
  }

  /// Projects opens first, then the project window and its jj log Configurations go.
  Future<void> _showProjectsInstead() async {
    await _openProjects();
    windows
      ..close(revsetConfigsWindowKey)
      ..close(mainWindowKey);
    _projectFirstFocus?.finish();
    _projectFirstFocus = null;
  }

  Widget _projectContent() => AppWindowActionsScope(actions: this, child: buildProject());

  Widget _projectsContent() => AppWindowActionsScope(actions: this, child: buildProjects(_openedInProjects));

  Future<void> _serial(Future<void> Function() task) {
    final Future<void> result = _queue.then((_) => task());
    // WHY: keep the chain alive after a failure — the error reaches this task's caller through `result`.
    _queue = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }
}

/// Waits for the first focus event of the Flutter view [viewId]: the engine reports a window becoming key as its view
/// gaining focus, and shows a new window key on its first frame.
class _FirstFocus with WidgetsBindingObserver {
  _FirstFocus(this.viewId) {
    WidgetsBinding.instance.addObserver(this);
  }

  final int viewId;
  final _done = Completer<void>();

  /// Completes on the view's first focus event, or when [finish]ed.
  Future<void> get done => _done.future;

  /// Whether [done] has completed.
  bool get isDone => _done.isCompleted;

  @override
  void didChangeViewFocus(ViewFocusEvent event) {
    if (event.viewId == viewId && event.state == ViewFocusState.focused) {
      finish();
    }
  }

  /// Stops waiting.
  void finish() {
    if (_done.isCompleted) {
      return;
    }
    WidgetsBinding.instance.removeObserver(this);
    _done.complete();
  }
}
