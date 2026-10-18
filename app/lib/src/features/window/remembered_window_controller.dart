// SPDX-License-Identifier: MIT

// The windowing API is experimental and only reachable through implementation
// imports; see https://github.com/flutter/flutter/issues/30701.
// ignore_for_file: invalid_use_of_internal_member, implementation_imports

import 'package:flutter/services.dart';
import 'package:flutter/src/widgets/_window.dart';
import 'package:flutter/src/widgets/_window_macos.dart';
import 'package:flutter/widgets.dart';

/// A regular window that remembers its frame — size and position, together
/// with the display it was on — under [key], and comes back there the next
/// time a window with the same key is created.
///
/// The windowing API sets a content size but knows no position, so the runner
/// applies the saved frame natively over the `zanshin/window_frames` channel,
/// through the NSWindow handle, and keeps saving the frame on every move and
/// resize. Use [create]: the frame must be in place before the engine shows
/// the window on its first frame, so the controller is only ready once the
/// native call has returned. The size is only the first-launch default.
class RememberedWindowController extends WindowControllerMacOS {
  RememberedWindowController._({
    required this.key,
    required super.size,
    required super.delegate,
    super.constraints,
    super.title,
  }) : super(owner: WidgetsBinding.instance.windowingOwner as WindowingOwnerMacOS, resizable: true);

  /// Creates the native window (still hidden) and restores its frame; without
  /// a saved frame the runner centres it, like the first launch used to.
  ///
  /// With [chrome] the runner also applies the app's custom window chrome —
  /// transparent full-size-content titlebar, opaque canvas-base background,
  /// traffic-light overlay. It happens in this same round-trip and *before* the frame,
  /// because `.fullSizeContentView` redefines what a frame means: applying one
  /// under the old style mask would shave the titlebar height off the window on
  /// every launch.
  static Future<RememberedWindowController> create({
    required String key,
    required Size size,
    required bool chrome,
    BoxConstraints? constraints,
    String? title,
    WindowControllerDelegate? delegate,
  }) async {
    final controller = RememberedWindowController._(
      key: key,
      size: size,
      constraints: constraints,
      title: title,
      delegate: delegate ?? WindowControllerDelegate(),
    );
    await _channel.invokeMethod<void>('restore', <String, Object>{
      'window': controller.windowHandle.address,
      'key': key,
      'chrome': chrome,
    });
    return controller;
  }

  /// Identifies the remembered frame, e.g. `main`; the project window keeps the one key `main` whichever project it
  /// shows (decision 16.42 j).
  final String key;

  static const _channel = MethodChannel('zanshin/window_frames');
}
