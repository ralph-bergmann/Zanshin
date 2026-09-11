// SPDX-License-Identifier: MIT

// Windowing-API proof of concept (used by `lib/main2.dart` only; not wired
// into the real boot). Design:
// docs/superpowers/specs/2026-09-11-windowing-splash-poc-design.md
//
// The windowing API is experimental and only reachable through implementation
// imports; see https://github.com/flutter/flutter/issues/30701.
// ignore_for_file: invalid_use_of_internal_member, implementation_imports

import 'package:flutter/services.dart';
import 'package:flutter/src/widgets/_window.dart';
import 'package:flutter/src/widgets/_window_macos.dart';
import 'package:flutter/widgets.dart';

/// A window controller for a splash window: borderless (no title bar, no
/// traffic lights), fixed size, centred on screen and floating above the
/// app's other windows.
///
/// The windowing API has no borderless top-level window type — only tooltips
/// and popups are borderless, and both need a parent window. So this
/// controller takes the plain dialog window the macOS engine creates (a
/// parentless dialog: neither minimisable nor maximisable, the closest
/// built-in type to a splash) and lets the runner strip its chrome over the
/// `zanshin/splash_window` channel, using the NSWindow handle the macOS
/// controller exposes for exactly this purpose. Nothing else is overridden.
///
/// Use [create]: the chrome must be gone before the engine shows the window on
/// its first frame, so the controller is only ready once the native call has
/// returned.
class SplashWindowController extends DialogWindowControllerMacOS {
  SplashWindowController._({required Size size, required super.delegate})
    : super(
        owner: WidgetsBinding.instance.windowingOwner as WindowingOwnerMacOS,
        size: size,
        resizable: false,
      );

  /// Creates the native window (still hidden) and strips its chrome.
  ///
  /// The returned controller is ready to be handed to a [DialogWindow].
  static Future<SplashWindowController> create({required Size size}) async {
    final controller = SplashWindowController._(size: size, delegate: DialogWindowControllerDelegate());
    await _channel.invokeMethod<void>('configure', <String, Object>{
      'window': controller.windowHandle.address,
      'width': size.width,
      'height': size.height,
    });
    return controller;
  }

  static const _channel = MethodChannel('zanshin/splash_window');

  /// Fades the window out natively, shadow included. The window stays alive
  /// (invisible) until the caller destroys it.
  Future<void> fadeOut({Duration duration = const Duration(milliseconds: 250)}) =>
      _channel.invokeMethod<void>('fadeOut', <String, Object>{
        'window': windowHandle.address,
        'durationMs': duration.inMilliseconds,
      });
}
