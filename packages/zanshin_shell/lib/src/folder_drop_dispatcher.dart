// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:zanshin_shell_platform_interface/zanshin_shell_platform_interface.dart';

import 'folder_drop_target.dart';

/// Routes the platform's folder drags to the [FolderDropTarget]s of each view.
///
/// Targets retain the view they live in. The first retain binds the dispatcher
/// to [ZanshinShellPlatform.instance] and the last release lets go of it, so
/// nothing touches the platform before a target exists, and a hot restart or
/// a test that swaps the platform starts clean.
class FolderDropDispatcher {
  FolderDropDispatcher._();

  /// The dispatcher every [FolderDropTarget] shares.
  static final instance = FolderDropDispatcher._();

  /// Mounted targets per view id.
  final _targets = <int, int>{};

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
    unawaited(_report('disabling', viewId, () => platform.disableFolderDrops(viewId)));
    if (_targets.isEmpty) {
      platform.setFolderDragHandler(null);
      _platform = null;
    }
  }

  ZanshinShellPlatform _bind() => _platform = ZanshinShellPlatform.instance..setFolderDragHandler(_handle);

  /// Answers the platform's folder drag events.
  bool _handle(FolderDragEvent event) => false;

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
