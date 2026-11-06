// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../l10n/zs_localizations.dart';
import '../design/zs_colors.dart';
import '../design/zs_metrics.dart';
import '../design/zs_motion.dart';
import '../zs_strings.dart';
import 'zs_control.dart';
import 'zs_control_core.dart';
import 'zs_focus_ring.dart';
import 'zs_lerp_builder.dart';

/// The side of its island a [ZsResizeEdge] sits on.
enum ZsResizeSide {
  /// The island's left edge (the inspector): the island lies to the right, dragging left widens it.
  left,

  /// The island's right edge (a pinned panel): the island lies to the left, dragging right widens it.
  right;

  /// The pointer direction that widens the island (DS components/surfaces/ResizeEdge.jsx:17).
  double get _grow => this == left ? -1 : 1;
}

/// The grab zone on a floating island's edge toward the graph (DS components/surfaces/ResizeEdge.{jsx,prompt.md};
/// surfaces.css:61-69; decisions 16.22, 16.24, 16.42 (k) (q)): the inspector's left edge (10.8) and a pinned panel's
/// right edge (11.3).
///
/// **Geometry.** A sibling of its island, `--resize-hit` (10) wide — `--resize-hit-out` (7) in the gap, 3 over the
/// island — as high as its parent makes it; the host places it along the straight part of the edge, the
/// `--radius-panel` corners left out.
///
/// **Line.** A 2 px pill in `--edge-hov` on the island's 1 px edge (x 1.5–3.5 of the strip on the right side,
/// 6.5–8.5 on the left), the strip's full height. It fades in on `--dur-hover` once the hover has lasted
/// `--delay-resize`, shows without the wait while dragging, and fades out on `--dur-hover`. No accent: it is a
/// handle, not a selection. An inactive window paints no hover, so no line either.
///
/// **Cursor.** `resizeColumn` at once; at the minimum or the maximum the one direction left (`resizeRight` /
/// `resizeLeft`, mirrored on the left side); while dragging the cursor holds for the whole window through an
/// `OverlayPortal` (skipped without an `Overlay`), because a clamped drag leaves the 10 pt zone.
///
/// **Drag.** The width follows the pointer with no tween, rounded to whole points and clamped to [min] … [max] (the
/// host passes the limit that keeps `--graph-min-w` of graph as [max]); [onChanged] runs per move, [onDragStart] and
/// [onDragEnd] bracket the drag, and [onChangeEnd] runs once on release when the width changed. A double-click resets
/// to [defaultValue] itself (not clamped to [max]: the host limits what shows, the default is what is remembered) on
/// `--dur-expand` (a jump under reduce motion, DS tokens/motion.css:70) on `--ease-glide` (Claude's proposal for the
/// curve: the DS names none, and glide is its curve for what resizes).
///
/// **Keys** (a Tab stop, the ring outside the strip): ← → by 10 (⇧ 50) — on the right side → widens, on the left
/// side → narrows (the edge follows the arrow); Home / End the minimum / maximum; ↩ the animated reset. Each step
/// that changes the width runs [onChanged] and [onChangeEnd]; a step against a limit reports nothing.
///
/// **VoiceOver** (decision 16.24; Claude's proposal): an adjustable value, not a splitter — `slider` named [label],
/// the value "300 points", increase = 10 wider.
///
/// [inert] (during item drags, decision 16.42 (k)): no pointer, no hover, no line.
class ZsResizeEdge extends StatefulWidget implements ZsControl {
  /// An edge on the [side] of an island [value] wide.
  const ZsResizeEdge({
    required this.side,
    required this.value,
    required this.min,
    required this.max,
    required this.defaultValue,
    required this.label,
    required this.onChanged,
    this.onChangeEnd,
    this.onDragStart,
    this.onDragEnd,
    this.inert = false,
    this.statesController,
    this.identifier,
    super.key,
  });

  /// The island side the edge is on.
  final ZsResizeSide side;

  /// The island's width.
  final double value;

  /// The smallest width.
  final double min;

  /// The largest width, the drag limit included.
  final double max;

  /// The width a double-click and ↩ go back to.
  final double defaultValue;

  /// The accessible name ("Panel width").
  final String label;

  /// Runs with each new width.
  final ValueChanged<double> onChanged;

  /// Runs with the width a drag, a reset or a key step ends at.
  final ValueChanged<double>? onChangeEnd;

  /// Runs when a drag starts.
  final VoidCallback? onDragStart;

  /// Runs when a drag ends or is cancelled.
  final VoidCallback? onDragEnd;

  /// Whether the edge ignores the pointer and shows no line.
  final bool inert;

  /// A states controller; the catalogue's state matrix forces states through it (a forced hover or press shows the
  /// line at once, as the DS matrix's `.st-hover` does, DS components/surfaces/surfaces.css:69).
  final WidgetStatesController? statesController;

  @override
  final String? identifier;

  /// A key step and the double step with ⇧ (DS components/surfaces/ResizeEdge.jsx:13, :25).
  static const double _step = 10;
  static const double _bigStep = 50;

  /// `width:2px` (DS components/surfaces/surfaces.css:65).
  static const double _lineWidth = 2;

  @override
  State<ZsResizeEdge> createState() => _ZsResizeEdgeState();
}

class _ZsResizeEdgeState extends State<ZsResizeEdge> with SingleTickerProviderStateMixin {
  final _portal = OverlayPortalController(debugLabel: 'ZsResizeEdge');
  late final _reset = AnimationController(vsync: this)
    ..addListener(_resetTick)
    ..addStatusListener(_resetStatus);

  var _dragging = false;
  var _dragX = 0.0;
  var _dragValue = 0.0;

  /// The last width this edge reported, which the parent may not have passed back yet.
  double? _reported;

  var _resetFrom = 0.0;
  var _resetTo = 0.0;

  /// Whether the pointer is over the strip, and whether that hover has lasted `--delay-resize`.
  var _inside = false;
  var _aged = false;
  Timer? _ageing;

  double get _value => _reported ?? widget.value;

  @override
  void didUpdateWidget(ZsResizeEdge oldWidget) {
    super.didUpdateWidget(oldWidget);
    _reported = null;
    if (widget.inert && !oldWidget.inert) {
      _ageing?.cancel();
      _aged = false;
    }
  }

  @override
  void dispose() {
    _ageing?.cancel();
    _reset.dispose();
    if (_portal.isShowing) {
      _portal.hide();
    }
    // A host that removes the edge mid-drag (the inspector closing) still gets the drag's end; deferred, because the
    // host's callbacks may set state, which the tree being torn down forbids.
    if (_dragging) {
      final VoidCallback? onDragEnd = widget.onDragEnd;
      final ValueChanged<double>? onChangeEnd = _value != _dragValue ? widget.onChangeEnd : null;
      final double value = _value;
      scheduleMicrotask(() {
        onDragEnd?.call();
        onChangeEnd?.call(value);
      });
    }
    super.dispose();
  }

  double _clamp(double value) => math.max(widget.min, math.min(widget.max, value));

  void _report(double value) {
    if (value != _value) {
      _reported = value;
      widget.onChanged(value);
    }
  }

  /// A key step or a jump: changes the width at once and ends the change — only when it changed, so a step against a
  /// limit never reports the clamped width as the user's (Story 11.3 review).
  void _settle(double value) {
    _reset.stop();
    final double next = _clamp(value);
    if (next == _value) {
      return;
    }
    _report(next);
    widget.onChangeEnd?.call(next);
  }

  /// The reset goes to [ZsResizeEdge.defaultValue] itself, not clamped to [ZsResizeEdge.max]: a narrow window's limit
  /// is the host's to apply to what shows, and the default is what the user asked to be remembered.
  void _startReset() {
    _reset.stop();
    final double target = math.max(widget.min, widget.defaultValue);
    final Duration duration = ZsMotion.of(context).durExpand;
    if (duration == Duration.zero || target == _value) {
      _report(target);
      widget.onChangeEnd?.call(target);
      return;
    }
    _resetFrom = _value;
    _resetTo = target;
    _reset
      ..duration = duration
      ..forward(from: 0);
  }

  void _resetTick() {
    final double t = ZsMotion.full.easeGlide.transform(_reset.value);
    _report(_resetFrom + (_resetTo - _resetFrom) * t);
  }

  void _resetStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed) {
      _report(_resetTo);
      widget.onChangeEnd?.call(_resetTo);
    }
  }

  void _dragStart(DragStartDetails details) {
    _reset.stop();
    _dragX = details.globalPosition.dx;
    _dragValue = _value;
    if (Overlay.maybeOf(context) != null) {
      _portal.show();
    }
    setState(() => _dragging = true);
    widget.onDragStart?.call();
  }

  void _dragUpdate(DragUpdateDetails details) {
    if (_dragging) {
      // The travel in the edge's own units (a zoomed window scales them); both points through the current transform,
      // so the edge's own movement cancels out.
      final box = context.findRenderObject()! as RenderBox;
      final double travel = box.globalToLocal(details.globalPosition).dx - box.globalToLocal(Offset(_dragX, 0)).dx;
      _report(_clamp((_dragValue + travel * widget.side._grow).roundToDouble()));
    }
  }

  void _dragEnd([DragEndDetails? _]) {
    if (!_dragging) {
      return;
    }
    if (_portal.isShowing) {
      _portal.hide();
    }
    setState(() => _dragging = false);
    widget.onDragEnd?.call();
    // A drag that ends where it started (or stayed clamped at a limit) changed nothing the user set.
    if (_value != _dragValue) {
      widget.onChangeEnd?.call(_value);
    }
  }

  void _hover(bool inside) {
    _ageing?.cancel();
    _inside = inside;
    if (!inside || widget.inert) {
      if (_aged) {
        setState(() => _aged = false);
      }
      return;
    }
    _ageing = Timer(ZsMotion.of(context).delayResize, () {
      if (mounted) {
        setState(() => _aged = true);
      }
    });
  }

  MouseCursor get _cursor {
    final double value = _value;
    final bool atMin = value <= widget.min;
    final bool atMax = value >= widget.max;
    final right = widget.side == ZsResizeSide.right;
    if (atMin && atMax) {
      return SystemMouseCursors.basic;
    }
    if (atMin) {
      return right ? SystemMouseCursors.resizeRight : SystemMouseCursors.resizeLeft;
    }
    if (atMax) {
      return right ? SystemMouseCursors.resizeLeft : SystemMouseCursors.resizeRight;
    }
    return SystemMouseCursors.resizeColumn;
  }

  // One decimal at most; the ARB's `decimalPattern` drops a zero fraction ("300", "300.5").
  static String _points(ZsLocalizations strings, double value) => strings.resizePoints((value * 10).round() / 10);

  @override
  Widget build(BuildContext context) {
    final ZsLocalizations strings = zsStrings(context);
    final double value = _value;
    final double grow = widget.side._grow;
    // The value at the moment of the key, which a step earlier in the same frame may already have moved.
    void by(double delta) => _settle(_value + delta);
    final shortcuts = <ShortcutActivator, Intent>{
      const SingleActivator(LogicalKeyboardKey.arrowLeft): VoidCallbackIntent(() => by(-grow * ZsResizeEdge._step)),
      const SingleActivator(LogicalKeyboardKey.arrowRight): VoidCallbackIntent(() => by(grow * ZsResizeEdge._step)),
      const SingleActivator(LogicalKeyboardKey.arrowLeft, shift: true): VoidCallbackIntent(
        () => by(-grow * ZsResizeEdge._bigStep),
      ),
      const SingleActivator(LogicalKeyboardKey.arrowRight, shift: true): VoidCallbackIntent(
        () => by(grow * ZsResizeEdge._bigStep),
      ),
      const SingleActivator(LogicalKeyboardKey.home): VoidCallbackIntent(() => _settle(widget.min)),
      const SingleActivator(LogicalKeyboardKey.end): VoidCallbackIntent(() => _settle(widget.max)),
      const SingleActivator(LogicalKeyboardKey.enter): VoidCallbackIntent(_startReset),
      const SingleActivator(LogicalKeyboardKey.numpadEnter): VoidCallbackIntent(_startReset),
    };
    final MouseCursor cursor = _cursor;
    Widget edge = ZsControlCore(
      identifier: widget.identifier,
      statesController: widget.statesController,
      activateOnKeys: false,
      activateOnTap: false,
      shortcuts: shortcuts,
      actions: <Type, Action<Intent>>{VoidCallbackIntent: VoidCallbackAction()},
      cursor: cursor,
      ring: ZsRingPlacement.outside,
      semantics: SemanticsProperties(
        slider: true,
        label: widget.label,
        value: _points(strings, value),
        increasedValue: _points(strings, _clamp(value + ZsResizeEdge._step)),
        decreasedValue: _points(strings, _clamp(value - ZsResizeEdge._step)),
        onIncrease: () => by(ZsResizeEdge._step),
        onDecrease: () => by(-ZsResizeEdge._step),
      ),
      builder: (context, status) {
        final ZsMotion motion = ZsMotion.of(context);
        // A hover the pointer makes waits `--delay-resize`; a forced one (the state matrix) shows at once.
        final bool shown = !widget.inert && (_dragging || status.pressed || (status.hovered && (_aged || !_inside)));
        return MouseRegion(
          onEnter: (_) => _hover(true),
          onExit: (_) => _hover(false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            excludeFromSemantics: true,
            dragStartBehavior: DragStartBehavior.down,
            onHorizontalDragStart: _dragStart,
            onHorizontalDragUpdate: _dragUpdate,
            onHorizontalDragEnd: _dragEnd,
            onHorizontalDragCancel: _dragEnd,
            onDoubleTap: _startReset,
            child: ZsLerpBuilder<double>(
              value: shown ? 1 : 0,
              lerp: (a, b, t) => a + (b - a) * t,
              duration: motion.durHover,
              curve: motion.easeState,
              builder: (context, opacity, _) => _EdgeLine(
                side: widget.side,
                color: ZsColors.of(context).edgeHov,
                opacity: opacity,
                metrics: ZsMetrics.of(context),
              ),
            ),
          ),
        );
      },
    );
    if (Overlay.maybeOf(context) != null) {
      edge = OverlayPortal(
        controller: _portal,
        overlayChildBuilder: (context) => Positioned.fill(child: MouseRegion(cursor: cursor)),
        child: edge,
      );
    }
    return IgnorePointer(ignoring: widget.inert, child: edge);
  }
}

class _EdgeLine extends LeafRenderObjectWidget {
  const _EdgeLine({required this.side, required this.color, required this.opacity, required this.metrics});

  final ZsResizeSide side;
  final Color color;
  final double opacity;
  final ZsMetrics metrics;

  /// The line's left edge in the strip: centred on the island's 1 px edge, `right` (or `left`) `calc(--resize-hit-out
  /// - .5px)` (DS components/surfaces/surfaces.css:66-67).
  double get _lineLeft => switch (side) {
    ZsResizeSide.right => metrics.resizeHit - (metrics.resizeHitOut - .5) - ZsResizeEdge._lineWidth,
    ZsResizeSide.left => metrics.resizeHitOut - .5,
  };

  @override
  _RenderEdgeLine createRenderObject(BuildContext context) =>
      _RenderEdgeLine(width: metrics.resizeHit, lineLeft: _lineLeft, color: color, opacity: opacity);

  @override
  void updateRenderObject(BuildContext context, _RenderEdgeLine renderObject) {
    renderObject
      ..width = metrics.resizeHit
      ..lineLeft = _lineLeft
      ..color = color
      ..opacity = opacity;
  }
}

/// The strip: `--resize-hit` wide, as high as its parent allows, painting the line at [opacity].
class _RenderEdgeLine extends RenderBox {
  _RenderEdgeLine({required this._width, required this._lineLeft, required this._color, required this._opacity});

  double get width => _width;
  double _width;
  set width(double value) {
    if (value != _width) {
      _width = value;
      markNeedsLayout();
    }
  }

  double get lineLeft => _lineLeft;
  double _lineLeft;
  set lineLeft(double value) {
    if (value != _lineLeft) {
      _lineLeft = value;
      markNeedsPaint();
    }
  }

  Color get color => _color;
  Color _color;
  set color(Color value) {
    if (value != _color) {
      _color = value;
      markNeedsPaint();
    }
  }

  double get opacity => _opacity;
  double _opacity;
  set opacity(double value) {
    if (value != _opacity) {
      _opacity = value;
      markNeedsPaint();
    }
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) =>
      constraints.constrain(Size(_width, constraints.hasBoundedHeight ? constraints.maxHeight : 0));

  @override
  void performLayout() {
    size = computeDryLayout(constraints);
  }

  @override
  bool hitTestSelf(Offset position) => true;

  @override
  double computeMinIntrinsicWidth(double height) => _width;

  @override
  double computeMaxIntrinsicWidth(double height) => _width;

  @override
  void paint(PaintingContext context, Offset offset) {
    if (_opacity <= 0) {
      return;
    }
    final rect = Rect.fromLTWH(offset.dx + _lineLeft, offset.dy, ZsResizeEdge._lineWidth, size.height);
    context.canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(ZsResizeEdge._lineWidth / 2)),
      Paint()..color = _color.withValues(alpha: _color.a * _opacity),
    );
  }

  @override
  void debugFillProperties(DiagnosticPropertiesBuilder properties) {
    super.debugFillProperties(properties);
    properties.add(DoubleProperty('opacity', _opacity));
  }
}
