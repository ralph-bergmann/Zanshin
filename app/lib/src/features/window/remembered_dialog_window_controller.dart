// SPDX-License-Identifier: MIT

// The windowing API is experimental and only reachable through implementation
// imports; see https://github.com/flutter/flutter/issues/30701.
// ignore_for_file: invalid_use_of_internal_member, implementation_imports

import 'package:flutter/src/widgets/_window.dart';
import 'package:flutter/src/widgets/_window_macos.dart';
import 'package:flutter/widgets.dart';

import 'remembered_window_controller.dart';

/// A parentless dialog window — Settings, Projects, jj log Configurations (decisions 16.13, 16.19; Story 11.12
/// item 1) — that remembers its frame under [key] like [RememberedWindowController].
///
/// The engine makes a parentless dialog Titled | Closable, plus Resizable where it asks for it, never Miniaturizable,
/// FullScreenAuxiliary, and key on its first frame (`FlutterWindowController.mm`). The owner's factories drop the
/// constraints, so this controller builds on the `*MacOS` constructor, which passes them: a dialog without a size is
/// sized to its content and needs finite maximum constraints for it (r3out windows.md C3). A parented dialog would
/// become a critical sheet; this one never has a parent.
///
/// [create] restores the frame with the secondary chrome ([WindowChromeKind.secondary]) before the engine shows the
/// window, as the project window's controller does.
class RememberedDialogWindowController extends DialogWindowControllerMacOS {
  RememberedDialogWindowController._({
    required this.key,
    required super.size,
    required super.constraints,
    required super.resizable,
    required super.title,
    required super.delegate,
  }) : super(owner: WidgetsBinding.instance.windowingOwner as WindowingOwnerMacOS);

  /// Creates the native window (still hidden) as [plan] says — under its key, titled, of its size (null: sized to its
  /// content) within its constraints, resizable or not — and restores its frame with the plan's runner arguments.
  static Future<RememberedDialogWindowController> create(
    DialogWindowPlan plan, {
    required DialogWindowControllerDelegate delegate,
  }) async {
    final controller = RememberedDialogWindowController._(
      key: plan.key,
      size: plan.size,
      constraints: plan.constraints,
      resizable: plan.resizable,
      title: plan.title,
      delegate: delegate,
    );
    await windowFramesChannel.invokeMethod<void>(
      'restore',
      plan.runnerArguments(window: controller.windowHandle.address),
    );
    return controller;
  }

  /// Identifies the remembered frame, e.g. `projects`.
  final String key;
}
