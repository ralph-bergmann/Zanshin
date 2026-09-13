// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:zanshin_shell_platform_interface/zanshin_shell_platform_interface.dart';

import 'folder_drop_target.dart';

/// The innermost target under a position, with the position in its space.
typedef _Hit = ({RenderFolderDropTarget target, Offset localPosition});

/// Routes the platform's folder drags to the [FolderDropTarget]s of each view.
///
/// Targets retain the view they live in. The first retain binds the dispatcher
/// to [ZanshinShellPlatform.instance] and the last release lets go of it, so
/// nothing touches the platform before a target exists, and a hot restart or
/// a test that swaps the platform starts clean.
///
/// The target of a drag is the innermost [RenderFolderDropTarget] in the
/// framework's hit test at the drag position. Outer targets are never asked,
/// and every visit of a target ends with exactly one `onDragExit` or
/// `onDrop`.
class FolderDropDispatcher {
  FolderDropDispatcher._();

  /// The dispatcher every [FolderDropTarget] shares.
  static final instance = FolderDropDispatcher._();

  /// Mounted targets per view id.
  final _targets = <int, int>{};

  /// The drag in progress per view id.
  final _sessions = <int, _Session>{};

  /// The platform the handler is installed on, while any target is mounted.
  ZanshinShellPlatform? _platform;

  /// Registers a target mounted in the view [viewId].
  void retain(int viewId) {
    final ZanshinShellPlatform platform = _platform ?? _bind();
    final int count = (_targets[viewId] ?? 0) + 1;
    _targets[viewId] = count;
    if (count == 1) {
      unawaited(_report('enabling', viewId, () => platform.enableFolderDrops(viewId)));
    }
  }

  /// Unregisters a target that left the view [viewId].
  void release(int viewId) {
    final ZanshinShellPlatform? platform = _platform;
    final int? count = _targets[viewId];
    if (platform == null || count == null) {
      return;
    }
    if (count > 1) {
      _targets[viewId] = count - 1;
      return;
    }
    _targets.remove(viewId);
    _sessions.remove(viewId);
    unawaited(_report('disabling', viewId, () => platform.disableFolderDrops(viewId)));
    if (_targets.isEmpty) {
      platform.setFolderDragHandler(null);
      _platform = null;
      _sessions.clear();
    }
  }

  /// Takes [target] out of every drag without calling it: it left the tree.
  void forget(RenderFolderDropTarget target) {
    for (final _Session session in _sessions.values) {
      if (identical(session.target, target)) {
        session.target = null;
      }
    }
  }

  ZanshinShellPlatform _bind() => _platform = ZanshinShellPlatform.instance..setFolderDragHandler(_handle);

  /// Answers the platform's folder drag events.
  bool _handle(FolderDragEvent event) => switch (event) {
    FolderDragEntered(:final viewId, :final position, :final paths) => _enter(viewId, position, paths),
    FolderDragUpdated(:final viewId, :final position) => _update(viewId, position),
    FolderDragExited(:final viewId) => _exit(viewId),
    FolderDropped(:final viewId, :final position, :final paths) => _drop(viewId, position, paths),
  };

  bool _enter(int viewId, Offset position, List<String> paths) {
    _exit(viewId);
    if (!_targets.containsKey(viewId)) {
      return false;
    }
    _sessions[viewId] = _Session(paths);
    return _update(viewId, position);
  }

  bool _update(int viewId, Offset position) {
    final _Session? session = _sessions[viewId];
    if (session == null) {
      return false;
    }
    final _Hit? hit = _hitTest(viewId, position);
    if (!identical(hit?.target, session.target)) {
      _leave(session);
      session.target = hit?.target;
    }
    if (hit == null) {
      return false;
    }
    return _ask(
      hit.target,
      FolderDragDetails(paths: session.paths, localPosition: hit.localPosition, globalPosition: position),
    );
  }

  bool _exit(int viewId) {
    if (_sessions.remove(viewId) case final _Session session) {
      _leave(session);
    }
    return false;
  }

  /// A drop carries its own paths, so it is evaluated even without a session.
  bool _drop(int viewId, Offset position, List<String> paths) {
    final _Session session = _sessions.remove(viewId) ?? _Session(paths);
    final _Hit? hit = _targets.containsKey(viewId) ? _hitTest(viewId, position) : null;
    if (!identical(hit?.target, session.target)) {
      _leave(session);
    }
    if (hit == null) {
      return false;
    }
    final RenderFolderDropTarget target = hit.target;
    final details = FolderDragDetails(paths: paths, localPosition: hit.localPosition, globalPosition: position);
    if (!_ask(target, details)) {
      _call('onDragExit', () => target.widget.onDragExit?.call());
      return false;
    }
    _call('onDrop', () => target.widget.onDrop(details));
    return true;
  }

  /// Ends the visit of the session's current target, if there is one.
  void _leave(_Session session) {
    final RenderFolderDropTarget? target = session.target;
    session.target = null;
    if (target != null) {
      _call('onDragExit', () => target.widget.onDragExit?.call());
    }
  }

  /// Whether [target] accepts [details]; a throwing callback rejects.
  bool _ask(RenderFolderDropTarget target, FolderDragDetails details) {
    var accepted = false;
    _call('onDragUpdate', () => accepted = target.widget.onDragUpdate?.call(details) ?? true);
    return accepted;
  }

  /// The innermost target under [position] in the view [viewId].
  _Hit? _hitTest(int viewId, Offset position) {
    final result = HitTestResult();
    WidgetsBinding.instance.hitTestInView(result, position, viewId);
    for (final HitTestEntry entry in result.path) {
      if (entry case BoxHitTestEntry(:final RenderFolderDropTarget target, :final localPosition)) {
        return (target: target, localPosition: localPosition);
      }
    }
    return null;
  }

  /// Runs a target callback and reports what it throws.
  void _call(String callback, VoidCallback body) {
    try {
      body();
    } catch (error, stack) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'zanshin_shell',
          context: ErrorDescription('while calling FolderDropTarget.$callback'),
        ),
      );
    }
  }

  /// Runs a platform call and reports a failure instead of throwing it into
  /// the widget tree.
  Future<void> _report(String action, int viewId, Future<void> Function() call) async {
    try {
      await call();
    } catch (error, stack) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'zanshin_shell',
          context: ErrorDescription('while $action folder drops for view $viewId'),
        ),
      );
    }
  }
}

/// A folder drag over one view.
class _Session {
  _Session(this.paths);

  /// The dragged folders.
  final List<String> paths;

  /// The target the drag is visiting, if any.
  RenderFolderDropTarget? target;
}
