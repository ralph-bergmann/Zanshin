// SPDX-License-Identifier: MIT

import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../window/app_windows.dart' show settingsWindowMinimum, settingsWindowSpec;

/// The Settings window's tallest content height while its height follows the tab (DS readme.md:189).
final double settingsWindowMaxHeight = settingsWindowSpec.constraints.maxHeight;

/// Keeps the Settings window's content height on the shown tab's until the user resizes it (Story 11.19).
///
/// The engine sizes a resizable content-sized window on its first frame only; afterwards the content reports its
/// natural height ([contentHeight], from [NaturalHeight]) and the follower asks for that content size, clamped to
/// [minimum] and [maxHeight]. The window reports every size it takes ([windowSized]): the first one is its first
/// frame — the follower then sets the [minimum] (a content-sized window takes none at creation) — and any later size
/// it did not ask for is the user's resize or zoom: it stops following for good and notifies, so the body fills the
/// window from then on.
///
/// Pure: [setSize] and [setConstraints] are the window controller's.
class SettingsHeightFollower extends ChangeNotifier {
  /// A follower driving a window through [setSize] and [setConstraints].
  SettingsHeightFollower({
    required this.setSize,
    required this.setConstraints,
    this.minimum = settingsWindowMinimum,
    double? maxHeight,
  }) : maxHeight = maxHeight ?? settingsWindowMaxHeight;

  /// Asks the window for a content size.
  final void Function(Size size) setSize;

  /// Sets the window's content constraints.
  final void Function(BoxConstraints constraints) setConstraints;

  /// The smallest content size.
  final Size minimum;

  /// The tallest content height while following.
  final double maxHeight;

  Size? _asked;
  double? _content;
  var _following = true;

  /// A window size within a pixel of another is the same size (AppKit rounds to its backing pixels).
  static const double _tolerance = 1;

  /// Whether the window's first frame is up.
  bool get ready => _asked != null;

  /// Whether the window's height still follows the content (the user has not resized it).
  bool get following => _following;

  /// The window took [size] (its content size): its first frame, or a resize.
  void windowSized(Size size) {
    final Size? asked = _asked;
    if (asked == null) {
      // Recorded before the calls: the engine reports the resize they cause synchronously.
      final Size clamped = _clamp(size);
      _asked = clamped;
      setConstraints(BoxConstraints(minWidth: minimum.width, minHeight: minimum.height));
      if (!_near(clamped, size)) {
        setSize(clamped);
      }
      _follow();
      return;
    }
    if (_following && !_near(size, asked)) {
      _following = false;
      notifyListeners();
    }
  }

  /// The shown content's natural height.
  void contentHeight(double height) {
    _content = height;
    _follow();
  }

  void _follow() {
    final Size? asked = _asked;
    final double? content = _content;
    if (!_following || asked == null || content == null) {
      return;
    }
    final Size target = _clamp(Size(asked.width, content));
    if (_near(target, asked)) {
      return;
    }
    _asked = target;
    setSize(target);
  }

  Size _clamp(Size size) => Size(
    size.width < minimum.width ? minimum.width : size.width,
    size.height.clamp(minimum.height, maxHeight < minimum.height ? minimum.height : maxHeight),
  );

  static bool _near(Size a, Size b) =>
      (a.width - b.width).abs() < _tolerance && (a.height - b.height).abs() < _tolerance;
}

/// Measures its child's natural height — laid out under the incoming width and at most [maxHeight] high — and reports
/// it to [onHeight] after the frame whenever it changed (Story 11.19). While [measuring] the child keeps that layout
/// (the box itself takes the incoming size, cutting an overflow until the window caught up): laid out again to the
/// window's tight constraints it would become a relayout boundary, and its later changes of height would never
/// reach the measure. Without [measuring] it is a plain proxy.
class NaturalHeight extends SingleChildRenderObjectWidget {
  /// Reports [child]'s natural height to [onHeight].
  const NaturalHeight({required this.onHeight, this.measuring = true, this._maxHeight, super.child, super.key});

  /// Receives the natural height after the frame it changed in.
  final ValueChanged<double> onHeight;

  /// Whether the child is measured.
  final bool measuring;

  final double? _maxHeight;

  /// The tallest natural height measured.
  double get maxHeight => _maxHeight ?? settingsWindowMaxHeight;

  @override
  RenderNaturalHeight createRenderObject(BuildContext context) =>
      RenderNaturalHeight(onHeight: onHeight, measuring: measuring, maxHeight: maxHeight);

  @override
  void updateRenderObject(BuildContext context, RenderNaturalHeight renderObject) => renderObject
    ..onHeight = onHeight
    ..measuring = measuring
    ..maxHeight = maxHeight;
}

/// [NaturalHeight]'s render box.
class RenderNaturalHeight extends RenderProxyBox {
  /// A box reporting its child's natural height to [onHeight].
  RenderNaturalHeight({required this.onHeight, required this._measuring, required this._maxHeight});

  /// Receives the natural height.
  ValueChanged<double> onHeight;

  /// Whether the child is measured.
  bool get measuring => _measuring;
  bool _measuring;
  set measuring(bool value) {
    if (value != _measuring) {
      _measuring = value;
      _reported = null;
      markNeedsLayout();
    }
  }

  /// The tallest natural height measured.
  double get maxHeight => _maxHeight;
  double _maxHeight;
  set maxHeight(double value) {
    if (value != _maxHeight) {
      _maxHeight = value;
      markNeedsLayout();
    }
  }

  double? _reported;

  @override
  void performLayout() {
    final RenderBox? child = this.child;
    if (child == null) {
      size = constraints.smallest;
      return;
    }
    if (!_measuring || !constraints.hasBoundedWidth) {
      child.layout(constraints, parentUsesSize: true);
      size = constraints.constrain(child.size);
      return;
    }
    // One layout, at the natural height: a second one to tight constraints would make the child a relayout
    // boundary, and a tab's change of height would no longer reach this box.
    final double width = constraints.maxWidth;
    child.layout(BoxConstraints(minWidth: width, maxWidth: width, maxHeight: _maxHeight), parentUsesSize: true);
    size = constraints.constrain(child.size);
    final double height = child.size.height;
    if (height != _reported) {
      _reported = height;
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (attached && _reported == height) {
          onHeight(height);
        }
      });
    }
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final RenderBox? child = this.child;
    // Until the window has grown to the content, the content's overflow is cut at the window's edge.
    if (child != null && child.size.height > size.height) {
      _clip.layer = context.pushClipRect(
        needsCompositing,
        offset,
        Offset.zero & size,
        super.paint,
        oldLayer: _clip.layer,
      );
    } else {
      _clip.layer = null;
      super.paint(context, offset);
    }
  }

  final _clip = LayerHandle<ClipRectLayer>();

  @override
  void dispose() {
    _clip.layer = null;
    super.dispose();
  }
}
