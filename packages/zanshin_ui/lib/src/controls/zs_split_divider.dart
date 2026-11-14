// SPDX-License-Identifier: MIT

import 'dart:math' as math;

import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../l10n/zs_localizations.dart';
import '../design/zs_colors.dart';
import '../zs_strings.dart';
import 'zs_control.dart';
import 'zs_control_core.dart';
import 'zs_focus_ring.dart';
import 'zs_tooltip.dart';

/// The band between two panes of a split that sets how much room the leading pane gets (DS
/// components/surfaces/SplitDivider.{jsx,prompt.md}; design `Inspector Study.html`, DESIGN-SYSTEM-SYNC #25): the
/// inspector's divider between its file list and its diff (Story 10.38).
///
/// **Geometry.** [band] (12) thick across [axis], as long as its parent makes it. [axis] is the axis the panes lie
/// along: [Axis.horizontal] puts them side by side (a vertical band), [Axis.vertical] one above the other.
///
/// **Look.** A 4 px grip in `--fl-border`, centred, 10 % of the band's length. On hover and while dragging, a 2 px
/// `--accent` line the band's full length instead.
///
/// **Cursor.** `resizeColumn` (side by side) or `resizeRow` (stacked); while dragging it holds for the whole window
/// through an `OverlayPortal` (skipped without an `Overlay`), as `ZsResizeEdge` does.
///
/// **Drag.** [value] (the leading pane's length) follows the pointer, rounded to whole points and clamped to [min] …
/// [max]; [onChanged] runs per move and [onChangeEnd] once on release when the value changed. A double-click resets to
/// [defaultValue] at once.
///
/// **Keys** (a Tab stop with the focus ring inside the band): ← → (side by side) or ↑ ↓ (stacked) by 10, with ⇧ by
/// 50; ↩ resets. Each step that changes the value runs [onChanged] and [onChangeEnd].
///
/// **VoiceOver** (Claude's proposal, mirroring `ZsResizeEdge`): an adjustable `slider` named [label], its value the
/// leading pane's share of [total] in percent; increase = 10 more for the leading pane.
class ZsSplitDivider extends StatefulWidget implements ZsControl {
  /// A divider for a split along [axis] whose leading pane is [value] long.
  const ZsSplitDivider({
    required this.axis,
    required this.value,
    required this.min,
    required this.max,
    required this.defaultValue,
    required this.total,
    required this.label,
    required this.onChanged,
    this.onChangeEnd,
    this.tooltip,
    this.statesController,
    this.identifier,
    super.key,
  });

  /// The axis the two panes lie along.
  final Axis axis;

  /// The leading pane's length.
  final double value;

  /// The leading pane's smallest length.
  final double min;

  /// The leading pane's largest length.
  final double max;

  /// The length a double-click and ↩ go back to.
  final double defaultValue;

  /// The length both panes share (the band left out); VoiceOver reads [value] as a share of it.
  final double total;

  /// The accessible name ("Files and diff").
  final String label;

  /// Runs with each new length.
  final ValueChanged<double> onChanged;

  /// Runs with the length a drag, a reset or a key step ends at.
  final ValueChanged<double>? onChangeEnd;

  /// The tooltip ("Drag to resize · double-click to reset"), or null for none.
  final String? tooltip;

  /// A states controller; the catalogue's state matrix forces states through it.
  final WidgetStatesController? statesController;

  @override
  final String? identifier;

  /// The band's thickness (`flex:0 0 12px`, design inspector-study.css:78).
  static const double band = 12;

  /// A key step and the step with ⇧.
  static const double _step = 10;
  static const double _bigStep = 50;

  @override
  State<ZsSplitDivider> createState() => _ZsSplitDividerState();
}

class _ZsSplitDividerState extends State<ZsSplitDivider> {
  final _portal = OverlayPortalController(debugLabel: 'ZsSplitDivider');

  var _dragging = false;
  Offset _dragStart = Offset.zero;
  var _dragValue = 0.0;

  /// The last value this divider reported, which the parent may not have passed back yet.
  double? _reported;

  double get _value => _reported ?? widget.value;

  bool get _sideBySide => widget.axis == Axis.horizontal;

  @override
  void didUpdateWidget(ZsSplitDivider oldWidget) {
    super.didUpdateWidget(oldWidget);
    _reported = null;
  }

  @override
  void dispose() {
    if (_portal.isShowing) {
      _portal.hide();
    }
    super.dispose();
  }

  // The minimum loses when both cannot hold: the host passes the other pane's minimum through [max].
  double _clamp(double value) => math.max(0, math.min(widget.max, math.max(widget.min, value)));

  void _report(double value) {
    if (value != _value) {
      _reported = value;
      widget.onChanged(value);
    }
  }

  void _settle(double value) {
    final double next = _clamp(value);
    if (next == _value) {
      return;
    }
    _report(next);
    widget.onChangeEnd?.call(next);
  }

  // A reset to where it already is reports nothing, so the host writes nothing.
  void _reset() => _settle(widget.defaultValue);

  void _start(DragStartDetails details) {
    _dragStart = details.globalPosition;
    _dragValue = _value;
    if (Overlay.maybeOf(context) != null) {
      _portal.show();
    }
    setState(() => _dragging = true);
  }

  void _update(DragUpdateDetails details) {
    if (!_dragging) {
      return;
    }
    // Both points through the current transform, so the divider's own movement cancels out.
    final box = context.findRenderObject()! as RenderBox;
    final Offset travel = box.globalToLocal(details.globalPosition) - box.globalToLocal(_dragStart);
    _report(_clamp((_dragValue + (_sideBySide ? travel.dx : travel.dy)).roundToDouble()));
  }

  void _end([Object? _]) {
    if (!_dragging) {
      return;
    }
    if (_portal.isShowing) {
      _portal.hide();
    }
    setState(() => _dragging = false);
    if (_value != _dragValue) {
      widget.onChangeEnd?.call(_value);
    }
  }

  String _share(ZsLocalizations strings, double value) =>
      strings.splitShare(widget.total > 0 ? (value / widget.total).clamp(0, 1) : 0);

  @override
  Widget build(BuildContext context) {
    final ZsLocalizations strings = zsStrings(context);
    final double value = _value;
    void by(double delta) => _settle(_value + delta);
    final LogicalKeyboardKey less = _sideBySide ? LogicalKeyboardKey.arrowLeft : LogicalKeyboardKey.arrowUp;
    final LogicalKeyboardKey more = _sideBySide ? LogicalKeyboardKey.arrowRight : LogicalKeyboardKey.arrowDown;
    final shortcuts = <ShortcutActivator, Intent>{
      SingleActivator(less): VoidCallbackIntent(() => by(-ZsSplitDivider._step)),
      SingleActivator(more): VoidCallbackIntent(() => by(ZsSplitDivider._step)),
      SingleActivator(less, shift: true): VoidCallbackIntent(() => by(-ZsSplitDivider._bigStep)),
      SingleActivator(more, shift: true): VoidCallbackIntent(() => by(ZsSplitDivider._bigStep)),
      const SingleActivator(LogicalKeyboardKey.enter): VoidCallbackIntent(_reset),
      const SingleActivator(LogicalKeyboardKey.numpadEnter): VoidCallbackIntent(_reset),
    };
    final MouseCursor cursor = _sideBySide ? SystemMouseCursors.resizeColumn : SystemMouseCursors.resizeRow;
    Widget divider = ZsControlCore(
      identifier: widget.identifier,
      statesController: widget.statesController,
      activateOnKeys: false,
      activateOnTap: false,
      shortcuts: shortcuts,
      actions: <Type, Action<Intent>>{VoidCallbackIntent: VoidCallbackAction()},
      cursor: cursor,
      ring: ZsRingPlacement.inside,
      ringRadius: 4,
      semantics: SemanticsProperties(
        slider: true,
        label: widget.label,
        value: _share(strings, value),
        increasedValue: _share(strings, _clamp(value + ZsSplitDivider._step)),
        decreasedValue: _share(strings, _clamp(value - ZsSplitDivider._step)),
        onIncrease: () => by(ZsSplitDivider._step),
        onDecrease: () => by(-ZsSplitDivider._step),
      ),
      builder: (context, status) {
        final ZsColors colors = ZsColors.of(context);
        final bool active = _dragging || status.hovered || status.pressed;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          excludeFromSemantics: true,
          dragStartBehavior: DragStartBehavior.down,
          onHorizontalDragStart: _sideBySide ? _start : null,
          onHorizontalDragUpdate: _sideBySide ? _update : null,
          onHorizontalDragEnd: _sideBySide ? _end : null,
          onHorizontalDragCancel: _sideBySide ? _end : null,
          onVerticalDragStart: _sideBySide ? null : _start,
          onVerticalDragUpdate: _sideBySide ? null : _update,
          onVerticalDragEnd: _sideBySide ? null : _end,
          onVerticalDragCancel: _sideBySide ? null : _end,
          onDoubleTap: _reset,
          child: CustomPaint(
            size: _sideBySide ? const Size.fromWidth(ZsSplitDivider.band) : const Size.fromHeight(ZsSplitDivider.band),
            painter: _DividerPainter(
              sideBySide: _sideBySide,
              active: active,
              grip: colors.flBorder,
              line: colors.accent,
            ),
          ),
        );
      },
    );
    final String? tooltip = widget.tooltip;
    if (tooltip != null) {
      divider = ZsTooltip(message: tooltip, child: divider);
    }
    if (Overlay.maybeOf(context) != null) {
      divider = OverlayPortal(
        controller: _portal,
        overlayChildBuilder: (context) => Positioned.fill(child: MouseRegion(cursor: cursor)),
        child: divider,
      );
    }
    return SizedBox(
      width: _sideBySide ? ZsSplitDivider.band : null,
      height: _sideBySide ? null : ZsSplitDivider.band,
      child: divider,
    );
  }
}

/// The grip (4 px, 10 % of the length, `--fl-border`) or, while active, the full-length 2 px accent line (design
/// inspector-study.css:80-85).
class _DividerPainter extends CustomPainter {
  const _DividerPainter({required this.sideBySide, required this.active, required this.grip, required this.line});

  final bool sideBySide;
  final bool active;
  final Color grip;
  final Color line;

  @override
  void paint(Canvas canvas, Size size) {
    final double length = sideBySide ? size.height : size.width;
    final double across = sideBySide ? size.width : size.height;
    final double thick = active ? 2 : 4;
    final double long = active ? length : length * .1;
    final double start = (length - long) / 2;
    final double inset = (across - thick) / 2;
    final rect = sideBySide ? Rect.fromLTWH(inset, start, thick, long) : Rect.fromLTWH(start, inset, long, thick);
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, Radius.circular(thick / 2)),
      Paint()..color = active ? line : grip,
    );
  }

  @override
  bool shouldRepaint(_DividerPainter oldDelegate) =>
      oldDelegate.sideBySide != sideBySide ||
      oldDelegate.active != active ||
      oldDelegate.grip != grip ||
      oldDelegate.line != line;
}
