// SPDX-License-Identifier: MIT

import 'dart:ui' show PathMetric;

import 'package:flutter/rendering.dart' show SemanticsProperties;
import 'package:flutter/widgets.dart';

import '../design/zs_colors.dart';
import '../design/zs_motion.dart';
import 'zs_control.dart';
import 'zs_control_core.dart';
import 'zs_focus_ring.dart';
import 'zs_lerp_builder.dart';
import 'zs_tooltip.dart';

/// A checkbox's size (DS components/forms/Checkbox.d.ts).
enum ZsCheckboxSize {
  /// 15 px, radius 4.5, edge 1.5, the mark on 10 (files, hunks, settings).
  md(side: 15, radius: 4.5, edge: 1.5, mark: 10),

  /// 13 px, radius 3.5, edge 1.4, the mark on 9 (inside the Viewed chip).
  sm(side: 13, radius: 3.5, edge: 1.4, mark: 9);

  const ZsCheckboxSize({required this.side, required this.radius, required this.edge, required this.mark});

  /// The box's side (DS components/forms/forms.css:73, :83).
  final double side;

  /// The box's radius, the checkbox's own geometry (DS readme.md:94).
  final double radius;

  /// The edge's width.
  final double edge;

  /// The side the 16-unit mark is drawn at (DS components/forms/forms.css:79, :84).
  final double mark;
}

/// A checkbox's tone (DS components/forms/Checkbox.d.ts).
enum ZsCheckboxTone {
  /// Selection: `--accent` with an `--accent-ink` mark.
  accent,

  /// The Viewed review state: `--add` with an `--add-ink` mark.
  add,
}

typedef _CheckLook = ({Color fill, Color edge, Color veil, Color mark});

_CheckLook _lerpCheck(_CheckLook a, _CheckLook b, double t) => (
  fill: Color.lerp(a.fill, b.fill, t)!,
  edge: Color.lerp(a.edge, b.edge, t)!,
  veil: Color.lerp(a.veil, b.veil, t)!,
  mark: Color.lerp(a.mark, b.mark, t)!,
);

/// A checkbox for selecting files and hunks, and at sm in the add tone the Viewed review state (DS
/// components/forms/Checkbox.{d.ts,jsx,prompt.md}; forms.css:71-89), on `ToggleableStateMixin`.
///
/// Rest: transparent with a `--text-faint` edge; hover `--text-muted` edge; pressed `--fl-on` under it. On and mixed
/// fill `--accent` with an `--accent-line` edge and an `--accent-ink` mark; on + hover lays `--fill-on-hover` over the
/// fill, on + pressed `--fill-on-press` (add tone: `--add`, `--add-ink`). The mark is one three-point path on a
/// 16-unit grid — the check `M3.6 8.4 L6.6 11.3 L12.6 4.9`, the dash `M4 8 L8 8 L12 8`, stroke 2.2 with round caps:
/// it draws in on `--dur-toggle` / `--ease-glide` toward on or mixed and morphs between them by moving its points;
/// unchecking clears it at once while the fill fades on `--dur-hover`. Under reduce motion it is simply there.
///
/// [value] null is mixed (only with [tristate]); a click on a mixed box selects all. A Tab stop; Space and ↩ toggle.
/// VoiceOver: a checkbox, "mixed" when partial, named [label], which is also its tooltip. A [presentational] box
/// takes no pointer and no focus and is hidden from VoiceOver: the button around it owns the role.
class ZsCheckbox extends StatefulWidget implements ZsControl {
  /// A checkbox showing [value].
  const ZsCheckbox({
    required this.value,
    this.onChanged,
    this.tristate = false,
    this.label,
    this.size = ZsCheckboxSize.md,
    this.tone = ZsCheckboxTone.accent,
    this.presentational = false,
    this.disabledReason,
    this.focusNode,
    this.statesController,
    this.identifier,
    super.key,
  }) : assert(tristate || value != null, 'Only a tristate checkbox can be mixed.');

  /// Checked, unchecked, or mixed (null).
  final bool? value;

  /// Called with the new value; null disables the box.
  final ValueChanged<bool>? onChanged;

  /// Whether [value] may be null.
  final bool tristate;

  /// The accessible name and tooltip.
  final String? label;

  /// md or sm.
  final ZsCheckboxSize size;

  /// Accent or add.
  final ZsCheckboxTone tone;

  /// Whether the box only shows a state inside another control.
  final bool presentational;

  /// Why the box is disabled.
  final String? disabledReason;

  /// The box's focus node.
  final FocusNode? focusNode;

  /// A states controller; the catalogue forces states through it.
  final WidgetStatesController? statesController;

  @override
  final String? identifier;

  /// The check and the dash, on the mark's 16-unit grid (DS components/forms/forms.css:80, :82).
  static const _check = <Offset>[Offset(3.6, 8.4), Offset(6.6, 11.3), Offset(12.6, 4.9)];
  static const _dash = <Offset>[Offset(4, 8), Offset(8, 8), Offset(12, 8)];

  /// The mark's grid and stroke (DS components/forms/Checkbox.jsx:11; forms.css:80).
  static const double _grid = 16;
  static const _stroke = 2.2;

  @override
  State<ZsCheckbox> createState() => _ZsCheckboxState();
}

class _ZsCheckboxState extends State<ZsCheckbox> with TickerProviderStateMixin, ToggleableStateMixin {
  late final _draw = CurvedAnimation(parent: positionController, curve: ZsMotion.full.easeGlide);

  @override
  bool? get value => widget.value;

  @override
  bool get tristate => widget.tristate;

  @override
  ValueChanged<bool?>? get onChanged {
    final ValueChanged<bool>? changed = widget.onChanged;
    return changed == null ? null : (value) => changed(value ?? false);
  }

  bool get _marked => widget.value != false;

  @override
  void initState() {
    super.initState();
    positionController.value = _marked ? 1 : 0;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    positionController.duration = ZsMotion.of(context).durToggle;
  }

  @override
  void didUpdateWidget(ZsCheckbox oldWidget) {
    super.didUpdateWidget(oldWidget);
    if ((oldWidget.value != false) == _marked) {
      return;
    }
    if (_marked) {
      positionController.forward();
    } else {
      positionController.value = 0;
    }
  }

  @override
  void dispose() {
    _draw.dispose();
    super.dispose();
  }

  _CheckLook _look(ZsColors c, ZsControlStatus s) {
    const clear = Color(0x00000000);
    final add = widget.tone == ZsCheckboxTone.add;
    final Color ink = add ? c.addInk : c.accentInk;
    if (_marked) {
      return (
        fill: add ? c.add : c.accent,
        edge: add ? c.add : c.accentLine,
        veil: s.pressed ? c.fillOnPress : (s.hovered ? c.fillOnHover : clear),
        mark: ink,
      );
    }
    final Color hoverEdge = add ? c.add : c.textMuted;
    return (
      fill: s.pressed ? c.flOn : clear,
      edge: s.hovered || s.pressed ? hoverEdge : c.textFaint,
      veil: clear,
      mark: ink,
    );
  }

  Widget _box(BuildContext context, ZsControlStatus status) {
    final ZsMotion motion = ZsMotion.of(context);
    return ZsLerpBuilder<double>(
      value: widget.value == null ? 1 : 0,
      lerp: (a, b, t) => a + (b - a) * t,
      duration: motion.durToggle,
      curve: motion.easeGlide,
      builder: (context, morph, _) => ZsLerpBuilder<_CheckLook>(
        value: _look(ZsColors.of(context), status),
        lerp: _lerpCheck,
        duration: status.pressed ? motion.durInstant : motion.durHover,
        curve: motion.easeState,
        builder: (context, look, _) => CustomPaint(
          size: Size.square(widget.size.side),
          painter: _CheckboxPainter(look: look, size: widget.size, draw: _draw, morph: morph),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.presentational) {
      return IgnorePointer(
        child: ExcludeSemantics(
          child: _box(context, ZsControlStatus(states: <WidgetState>{if (_marked) WidgetState.selected})),
        ),
      );
    }
    final bool? checked = widget.value;
    final Widget box = ZsControlCore(
      identifier: widget.identifier,
      focusNode: widget.focusNode,
      statesController: widget.statesController,
      onActivate: () => widget.onChanged?.call(checked == null || !checked),
      enabled: widget.onChanged != null,
      disabledReason: widget.disabledReason,
      selected: _marked,
      semantics: SemanticsProperties(
        checked: checked ?? false,
        mixed: checked == null ? true : null,
        label: widget.label,
      ),
      ring: ZsRingPlacement.outside,
      ringRadius: widget.size.radius,
      builder: _box,
    );
    final String? label = widget.label;
    return label == null ? box : ZsTooltip(message: label, child: box);
  }
}

class _CheckboxPainter extends CustomPainter {
  _CheckboxPainter({required this.look, required this.size, required this.draw, required this.morph})
    : super(repaint: draw);

  final _CheckLook look;
  final ZsCheckboxSize size;
  final Animation<double> draw;
  final double morph;

  @override
  void paint(Canvas canvas, Size box) {
    final rrect = RRect.fromRectAndRadius(Offset.zero & box, Radius.circular(size.radius));
    final RRect inside = rrect.deflate(size.edge);
    canvas.drawRRect(rrect, Paint()..color = look.fill);
    if (look.veil.a > 0) {
      // `inset 0 0 0 8px` covers the whole box inside its edge (DS components/forms/forms.css:77-78).
      canvas.drawRRect(inside, Paint()..color = look.veil);
    }
    canvas.drawDRRect(rrect, inside, Paint()..color = look.edge);
    final double drawn = draw.value;
    if (drawn == 0) {
      return;
    }
    final double scale = size.mark / ZsCheckbox._grid;
    final double origin = (box.width - size.mark) / 2;
    final path = Path();
    for (var i = 0; i < 3; i++) {
      final Offset point =
          Offset.lerp(ZsCheckbox._check[i], ZsCheckbox._dash[i], morph)! * scale + Offset(origin, origin);
      if (i == 0) {
        path.moveTo(point.dx, point.dy);
      } else {
        path.lineTo(point.dx, point.dy);
      }
    }
    final mark = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = ZsCheckbox._stroke * scale
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = look.mark;
    if (drawn >= 1) {
      canvas.drawPath(path, mark);
      return;
    }
    // `stroke-dashoffset` 1 → 0 over `pathLength="1"`: the stroke grows along the path.
    final PathMetric metric = path.computeMetrics().first;
    canvas.drawPath(metric.extractPath(0, metric.length * drawn), mark);
  }

  @override
  bool shouldRepaint(_CheckboxPainter oldDelegate) =>
      oldDelegate.look != look || oldDelegate.size != size || oldDelegate.draw != draw || oldDelegate.morph != morph;
}
