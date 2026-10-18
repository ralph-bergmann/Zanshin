// SPDX-License-Identifier: MIT

// The windowing API is experimental and only reachable through implementation
// imports; see https://github.com/flutter/flutter/issues/30701.
// ignore_for_file: invalid_use_of_internal_member, implementation_imports

import 'package:flutter/services.dart';
import 'package:flutter/src/widgets/_window.dart';
import 'package:flutter/src/widgets/_window_macos.dart';
import 'package:flutter/widgets.dart';

/// The chrome the runner gives a window (Story 11.12 item 2).
enum WindowChromeKind {
  /// The project window's (Story 11.4): miniaturizable and resizable, the 880 × 560 minimum, the canvas base.
  main,

  /// A dialog window's: the engine's style mask plus full-size content, no minimum, the window fill's base.
  secondary,
}

/// What the runner remembers of a window's frame (Story 11.12 item 3).
enum WindowFrameMode {
  /// Size and position.
  full,

  /// The position only, for a window sized to its content: its top edge stays where it was, also when the content
  /// height changes (Settings).
  position,
}

/// The window's level (Story 11.12 item 6; decisions 16.19, 16.38, 16.42 b).
enum WindowLevel {
  /// The normal level.
  normal,

  /// `.floating` while Zanshin is active, `.normal` once it resigns (jj log Configurations).
  floatingWhileActive,
}

/// The `restore` arguments both remembered controllers send on `zanshin/window_frames`: the NSWindow handle
/// [window], the frame [key], the [chrome] kind, the [frame] mode and the [level], each a name the runner parses
/// strictly (`main|secondary`, `full|position`, `normal|floating`).
Map<String, Object> restoreArguments({
  required int window,
  required String key,
  required WindowChromeKind chrome,
  required WindowFrameMode frame,
  required WindowLevel level,
}) => <String, Object>{
  'window': window,
  'key': key,
  'chrome': chrome.name,
  'frame': frame.name,
  'level': switch (level) {
    WindowLevel.normal => 'normal',
    WindowLevel.floatingWhileActive => 'floating',
  },
};

/// The channel the remembered controllers restore their frames over; the runner also calls `reopen` on it.
const windowFramesChannel = MethodChannel('zanshin/window_frames');

/// How a native window is made (`planNativeWindow`, Story 11.12): the window's [key] (also its frame key), [title],
/// content [constraints] and whether it is [resizable], and what the runner's `restore` gets — the [chrome] kind, the
/// [frame] mode and the [level].
///
/// The plan is what a test pins; the remembered controllers only carry it out (`createRememberedWindow`).
sealed class NativeWindowPlan {
  const NativeWindowPlan({
    required this.key,
    required this.title,
    required this.constraints,
    required this.resizable,
    required this.chrome,
    required this.frame,
    required this.level,
  });

  /// The window's key, also its frame key.
  final String key;

  /// The window's title.
  final String title;

  /// The window's content constraints, its minimum included.
  final BoxConstraints constraints;

  /// Whether the user can resize the window (and zoom it).
  final bool resizable;

  /// The chrome the runner gives the window.
  final WindowChromeKind chrome;

  /// What the runner remembers of the window's frame.
  final WindowFrameMode frame;

  /// The window's level.
  final WindowLevel level;

  /// The `restore` arguments for the NSWindow handle [window]: [restoreArguments] of this plan.
  Map<String, Object> runnerArguments({required int window}) =>
      restoreArguments(window: window, key: key, chrome: chrome, frame: frame, level: level);
}

/// A project window's plan, carried out by [RememberedWindowController]: resizable, of [size], with the main chrome,
/// the full frame and the normal level.
final class ProjectWindowPlan extends NativeWindowPlan {
  /// The project window [key] titled [title], of [size] within [constraints].
  const ProjectWindowPlan({required super.key, required super.title, required this.size, required super.constraints})
    : super(resizable: true, chrome: WindowChromeKind.main, frame: WindowFrameMode.full, level: WindowLevel.normal);

  /// The first-launch content size; afterwards the remembered frame wins.
  final Size size;
}

/// A dialog window's plan, carried out by `RememberedDialogWindowController`: of [size] (null: sized to its content),
/// [resizable] or not, with the secondary chrome.
final class DialogWindowPlan extends NativeWindowPlan {
  /// The dialog window [key] titled [title], of [size] within [constraints], [resizable] or not, in [frame] mode at
  /// [level].
  const DialogWindowPlan({
    required super.key,
    required super.title,
    required this.size,
    required super.constraints,
    required super.resizable,
    required super.frame,
    required super.level,
  }) : super(chrome: WindowChromeKind.secondary);

  /// The first-launch content size, or null for a window sized to its content.
  final Size? size;
}

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
    required super.resizable,
    super.constraints,
    super.title,
  }) : super(owner: WidgetsBinding.instance.windowingOwner as WindowingOwnerMacOS);

  /// Creates the native window (still hidden) as [plan] says and restores its frame with the plan's runner
  /// arguments; without a saved frame the runner centres it, like the first launch used to.
  ///
  /// The runner also applies the project window's chrome ([WindowChromeKind.main]) — transparent full-size-content
  /// titlebar, opaque canvas-base background, traffic-light overlay. It happens in this same round-trip and *before*
  /// the frame, because `.fullSizeContentView` redefines what a frame means: applying one under the old style mask
  /// would shave the titlebar height off the window on every launch.
  static Future<RememberedWindowController> create(
    ProjectWindowPlan plan, {
    required WindowControllerDelegate delegate,
  }) async {
    final controller = RememberedWindowController._(
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

  /// Identifies the remembered frame, e.g. `main`; the project window keeps the one key `main` whichever project it
  /// shows (decision 16.42 j).
  final String key;
}
