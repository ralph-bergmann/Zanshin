// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:zanshin_settings/zanshin_settings.dart' show SettingsStore;

import 'app_windows.dart';

/// The Zoom steps in percent (Story 11.20; DS readme › Density and zoom): Settings › General › Zoom and View › Zoom
/// In / Zoom Out step through them.
const zoomSteps = <int>[90, 100, 110, 125, 150];

/// Actual Size, the default zoom.
const zoomActualSize = 100;

/// The step nearest [percent]; a tie goes to the lower step (a stored 95 is 90).
int zoomStepOf(int percent) {
  int best = zoomSteps.first;
  for (final int step in zoomSteps) {
    if ((step - percent).abs() < (best - percent).abs()) {
      best = step;
    }
  }
  return best;
}

/// The step after [percent]'s step; the largest stays.
int zoomInFrom(int percent) {
  final int index = zoomSteps.indexOf(zoomStepOf(percent));
  return zoomSteps[index == zoomSteps.length - 1 ? index : index + 1];
}

/// The step before [percent]'s step; the smallest stays.
int zoomOutFrom(int percent) {
  final int index = zoomSteps.indexOf(zoomStepOf(percent));
  return zoomSteps[index == 0 ? 0 : index - 1];
}

/// The scale factor of [percent] (snapped to its step): 1.25 for 125.
double zoomScaleOf(int percent) => zoomStepOf(percent) / 100;

/// [data] as the content of a window zoomed by [scale] sees it: the size and the insets in zoomed units, the device
/// pixel ratio multiplied, so rasters keep the screen's resolution.
MediaQueryData zoomedMediaQuery(MediaQueryData data, double scale) => scale == 1
    ? data
    : data.copyWith(
        size: data.size / scale,
        padding: data.padding / scale,
        viewPadding: data.viewPadding / scale,
        viewInsets: data.viewInsets / scale,
        devicePixelRatio: data.devicePixelRatio * scale,
      );

/// Keeps every window's zoom on the settings' `appearance.zoom` (Story 11.20): sets [windows]'s zoom now and on
/// every change, and handles ⌘= app-wide as Zoom In (the same key as the View menu's ⌘+ without Shift, which the
/// menu's character activator never sees; app-wide, so it works with nothing focused); the returned callback stops
/// both.
VoidCallback bindWindowZoom(SettingsStore store, AppWindows windows) {
  void apply() => windows.zoom = zoomScaleOf(store.value.appearance.zoom);
  bool zoomIn(KeyEvent event) {
    final HardwareKeyboard keyboard = HardwareKeyboard.instance;
    if (event is! KeyDownEvent ||
        event.logicalKey != LogicalKeyboardKey.equal ||
        !keyboard.isMetaPressed ||
        keyboard.isShiftPressed ||
        keyboard.isControlPressed ||
        keyboard.isAltPressed) {
      return false;
    }
    unawaited(store.update((s) => s.copyWith.appearance(zoom: zoomInFrom(s.appearance.zoom))));
    return true;
  }

  apply();
  store.addListener(apply);
  HardwareKeyboard.instance.addHandler(zoomIn);
  return () {
    store.removeListener(apply);
    HardwareKeyboard.instance.removeHandler(zoomIn);
  };
}

/// Scales a window's content by [scale] (Story 11.20): the child is laid out at the incoming constraints divided by
/// [scale], and painted and hit-tested scaled, so everything below grows together and global positions stay window
/// coordinates. A box mixing a global position with its local size must therefore go through its transform.
///
/// Not a device-pixel-ratio override: pointer positions are divided by the view's real ratio in the gesture binding,
/// which no window can change.
class WindowZoomBox extends SingleChildRenderObjectWidget {
  /// Scales [child] by [scale].
  const WindowZoomBox({required this.scale, super.child, super.key});

  /// The zoom factor, 1 for Actual Size.
  final double scale;

  @override
  RenderWindowZoom createRenderObject(BuildContext context) => RenderWindowZoom(scale: scale);

  @override
  void updateRenderObject(BuildContext context, RenderWindowZoom renderObject) => renderObject.scale = scale;
}

/// [WindowZoomBox]'s render box.
class RenderWindowZoom extends RenderProxyBox {
  /// A box scaling its child by [scale].
  RenderWindowZoom({required this._scale});

  /// The zoom factor.
  double get scale => _scale;
  double _scale;
  set scale(double value) {
    if (value != _scale) {
      _scale = value;
      markNeedsLayout();
    }
  }

  Matrix4 get _transform => Matrix4.diagonal3Values(_scale, _scale, 1);

  final _layer = LayerHandle<TransformLayer>();

  @override
  double computeMinIntrinsicWidth(double height) => (child?.getMinIntrinsicWidth(height / _scale) ?? 0) * _scale;

  @override
  double computeMaxIntrinsicWidth(double height) => (child?.getMaxIntrinsicWidth(height / _scale) ?? 0) * _scale;

  @override
  double computeMinIntrinsicHeight(double width) => (child?.getMinIntrinsicHeight(width / _scale) ?? 0) * _scale;

  @override
  double computeMaxIntrinsicHeight(double width) => (child?.getMaxIntrinsicHeight(width / _scale) ?? 0) * _scale;

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    final RenderBox? child = this.child;
    return child == null
        ? constraints.smallest
        : constraints.constrain(child.getDryLayout(constraints / _scale) * _scale);
  }

  @override
  void performLayout() {
    final RenderBox? child = this.child;
    if (child == null) {
      size = constraints.smallest;
      return;
    }
    child.layout(constraints / _scale, parentUsesSize: true);
    size = constraints.constrain(child.size * _scale);
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (child == null) {
      _layer.layer = null;
      return;
    }
    _layer.layer = context.pushTransform(needsCompositing, offset, _transform, super.paint, oldLayer: _layer.layer);
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    final RenderBox? child = this.child;
    return child != null &&
        result.addWithPaintTransform(
          transform: _transform,
          position: position,
          hitTest: (result, position) => child.hitTest(result, position: position),
        );
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) => transform.multiply(_transform);

  @override
  void dispose() {
    _layer.layer = null;
    super.dispose();
  }

  @override
  void debugFillProperties(DiagnosticPropertiesBuilder properties) {
    super.debugFillProperties(properties);
    properties.add(DoubleProperty('scale', _scale));
  }
}
