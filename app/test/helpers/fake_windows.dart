// SPDX-License-Identifier: MIT

// The windowing API is experimental and only reachable through implementation
// imports; see https://github.com/flutter/flutter/issues/30701.
// ignore_for_file: invalid_use_of_internal_member

import 'dart:async';

import 'package:flutter/src/widgets/_window.dart';
import 'package:flutter/widgets.dart';
import 'package:zanshin/src/features/window/app_windows.dart';

/// Stands in for the real factory, which needs the engine: the generic controllers `flutter_test`'s windowing owner
/// provides (a dialog one for a dialog spec) are enough to exercise the registry bookkeeping. Records every request.
class FakeWindowFactory {
  final requests = <AppWindowRequest>[];

  /// The lifecycle each controller got: the test owner keeps its delegate private and cannot press a red button, so
  /// a test calls what the engine would.
  final delegates = <BaseWindowController, AppWindowLifecycle>{};

  /// While set, a creation waits for it before it makes its controller (a test acts while a window is on its way).
  Completer<void>? gate;

  Future<BaseWindowController> call(AppWindowRequest request) async {
    requests.add(request);
    await gate?.future;
    final BaseWindowController controller = _controller(request);
    delegates[controller] = request.delegate;
    return controller;
  }

  static BaseWindowController _controller(AppWindowRequest request) {
    final DialogWindowSpec? dialog = request.dialog;
    if (dialog == null) {
      return WindowController(
        size: request.size!,
        constraints: request.constraints,
        title: request.title,
        delegate: request.delegate,
      );
    }
    final Size? size = request.size;
    return size == null
        ? DialogWindowController.shrinkWrap(
            constraints: request.constraints,
            title: request.title,
            delegate: request.delegate,
          )
        : DialogWindowController(
            size: size,
            constraints: request.constraints,
            title: request.title,
            delegate: request.delegate,
          );
  }

  /// Asks to close [controller], as its red button would.
  void requestClose(BaseWindowController controller) => delegates[controller]!.onWindowCloseRequested(controller);
}
