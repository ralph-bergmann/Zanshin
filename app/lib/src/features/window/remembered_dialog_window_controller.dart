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

  /// Creates the native window (still hidden) under [key], titled [title], of [size] (null: sized to its content)
  /// within [constraints], [resizable] or not, and restores its frame in [frame] mode at [level].
  static Future<RememberedDialogWindowController> create({
    required String key,
    required String title,
    required Size? size,
    required BoxConstraints constraints,
    required bool resizable,
    required WindowFrameMode frame,
    required WindowLevel level,
    required DialogWindowControllerDelegate delegate,
  }) async {
    final controller = RememberedDialogWindowController._(
      key: key,
      size: size,
      constraints: constraints,
      resizable: resizable,
      title: title,
      delegate: delegate,
    );
    await windowFramesChannel.invokeMethod<void>(
      'restore',
      restoreArguments(
        window: controller.windowHandle.address,
        key: key,
        chrome: WindowChromeKind.secondary,
        frame: frame,
        level: level,
      ),
    );
    return controller;
  }

  /// Identifies the remembered frame, e.g. `projects`.
  final String key;
}
