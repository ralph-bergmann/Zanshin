// SPDX-License-Identifier: MIT

import 'dart:ui';

import 'package:flutter/foundation.dart' show immutable;

/// What a window shows of the system's chrome, as measured for one of its Flutter views: whether it is in full
/// screen and where the standard window buttons (close, minimise, zoom) sit.
@immutable
class WindowChrome {
  const WindowChrome({this.fullScreen = false, this.trafficLights});

  /// Whether the window is in full screen or entering it.
  final bool fullScreen;

  /// The union of the visible standard window buttons in the Flutter view's logical pixels, origin top left; null in
  /// full screen and while no button is visible.
  final Rect? trafficLights;

  @override
  bool operator ==(Object other) =>
      other is WindowChrome && other.fullScreen == fullScreen && other.trafficLights == trafficLights;

  @override
  int get hashCode => Object.hash(fullScreen, trafficLights);

  @override
  String toString() => 'WindowChrome(fullScreen: $fullScreen, trafficLights: $trafficLights)';
}

/// A watched Flutter view's new [WindowChrome].
typedef WindowChromeChange = ({int viewId, WindowChrome chrome});
