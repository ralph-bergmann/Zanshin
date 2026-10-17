// SPDX-License-Identifier: MIT

import 'package:flutter/rendering.dart' show SemanticsProperties;
import 'package:flutter/widgets.dart';

import '../design/zs_colors.dart';
import '../design/zs_motion.dart';
import 'zs_control.dart';
import 'zs_control_core.dart';
import 'zs_focus_ring.dart';
import 'zs_lerp_builder.dart';

typedef _SwitchLook = ({Color track, Color edge, Color knob, Color veil});

_SwitchLook _lerpSwitch(_SwitchLook a, _SwitchLook b, double t) => (
  track: Color.lerp(a.track, b.track, t)!,
  edge: Color.lerp(a.edge, b.edge, t)!,
  knob: Color.lerp(a.knob, b.knob, t)!,
  veil: Color.lerp(a.veil, b.veil, t)!,
);

/// An on/off switch for a binary setting that applies at once (DS components/forms/Switch.{d.ts,jsx,prompt.md};
/// forms.css:24-35), on `ToggleableStateMixin`: a 30 × 18 pill with a 1 px edge and a 12 px knob 2 px inside it.
///
/// Off: `--bg-card-2` with a `--border-strong` edge and a `--text-dim` knob; hover borrows `--edge-hov` and the knob
/// turns `--text-muted`. On: `--accent` with an `--accent-line` edge and an `--accent-ink` knob, 12 px to the right;
/// on + hover lays `--fill-on-hover` over the fill. Pressed stretches the knob 12 → 15 px toward its travel (on: it
/// moves back to 9). The knob slides and stretches on `--dur-toggle` / `--ease-glide` (0 under reduce motion);
/// every colour fades on `--dur-hover`, never on the toggle duration. In an inactive window the on-state is the
/// neutral accent of the tokens.
///
/// A Tab stop; Space and ↩ toggle, as macOS. VoiceOver: a switch (toggled) named [label].
class ZsSwitch extends StatefulWidget implements ZsControl {
  /// A switch showing [value].
  const ZsSwitch({
    required this.value,
    required this.onChanged,
    required this.label,
    this.disabledReason,
    this.focusNode,
    this.statesController,
    this.identifier,
    super.key,
  });

  /// Whether it is on.
  final bool value;

  /// Called with the new value; null disables the switch.
  final ValueChanged<bool>? onChanged;

  /// The accessible name (the row's label).
  final String label;

  /// Why the switch is disabled.
  final String? disabledReason;

  /// The switch's focus node.
  final FocusNode? focusNode;

  /// A states controller; the catalogue forces states through it.
  final WidgetStatesController? statesController;

  @override
  final String? identifier;

  /// `width:30px;height:18px` (DS components/forms/forms.css:26).
  static const _size = Size(30, 18);

  /// The knob's side, its inset (`top:2px;left:2px` inside the 1 px edge) and its travel (DS
  /// components/forms/forms.css:27, :32).
  static const double _knob = 12;
  static const double _inset = 3;
  static const double _travel = 12;

  /// The pressed knob's extra width, 12 → 15 (DS components/forms/forms.css:30, :35).
  static const double _stretch = 3;

  @override
  State<ZsSwitch> createState() => _ZsSwitchState();
}

class _ZsSwitchState extends State<ZsSwitch> with TickerProviderStateMixin, ToggleableStateMixin {
  late final _travel = CurvedAnimation(
    parent: positionController,
    curve: ZsMotion.full.easeGlide,
    reverseCurve: ZsMotion.full.easeGlide.flipped,
  );

  @override
  bool? get value => widget.value;

  @override
  bool get tristate => false;

  @override
  ValueChanged<bool?>? get onChanged {
    final ValueChanged<bool>? changed = widget.onChanged;
    return changed == null ? null : (value) => changed(value ?? false);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final Duration toggle = ZsMotion.of(context).durToggle;
    positionController
      ..duration = toggle
      ..reverseDuration = toggle;
  }

  @override
  void didUpdateWidget(ZsSwitch oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value) {
      animateToValue();
    }
  }

  @override
  void dispose() {
    _travel.dispose();
    super.dispose();
  }

  _SwitchLook _look(ZsColors c, ZsControlStatus s) {
    const clear = Color(0x00000000);
    if (widget.value) {
      return (track: c.accent, edge: c.accentLine, knob: c.accentInk, veil: s.hovered ? c.fillOnHover : clear);
    }
    return (
      track: c.bgCard2,
      edge: s.hovered ? c.edgeHov : c.borderStrong,
      knob: s.hovered ? c.textMuted : c.textDim,
      veil: clear,
    );
  }

  @override
  Widget build(BuildContext context) => ZsControlCore(
    identifier: widget.identifier,
    focusNode: widget.focusNode,
    statesController: widget.statesController,
    onActivate: () => widget.onChanged?.call(!widget.value),
    enabled: widget.onChanged != null,
    disabledReason: widget.disabledReason,
    selected: widget.value,
    semantics: SemanticsProperties(toggled: widget.value, label: widget.label),
    ring: ZsRingPlacement.outside,
    ringRadius: ZsSwitch._size.height / 2,
    builder: (context, status) {
      final ZsMotion motion = ZsMotion.of(context);
      return ZsLerpBuilder<double>(
        value: status.pressed ? 1 : 0,
        lerp: (a, b, t) => a + (b - a) * t,
        duration: motion.durToggle,
        curve: motion.easeGlide,
        builder: (context, stretch, _) => ZsLerpBuilder<_SwitchLook>(
          value: _look(ZsColors.of(context), status),
          lerp: _lerpSwitch,
          duration: motion.durHover,
          curve: motion.easeState,
          builder: (context, look, _) => CustomPaint(
            size: ZsSwitch._size,
            painter: _SwitchPainter(look: look, travel: _travel, stretch: stretch),
          ),
        ),
      );
    },
  );
}

class _SwitchPainter extends CustomPainter {
  _SwitchPainter({required this.look, required this.travel, required this.stretch}) : super(repaint: travel);

  final _SwitchLook look;
  final Animation<double> travel;
  final double stretch;

  @override
  void paint(Canvas canvas, Size size) {
    final pill = RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(size.height / 2));
    final RRect inside = pill.deflate(1);
    // CSS order: the background under the border, an inset shadow inside the border, then the border.
    canvas.drawRRect(pill, Paint()..color = look.track);
    if (look.veil.a > 0) {
      // `inset 0 0 0 9px var(--fill-on-hover)` covers the whole fill inside the edge.
      canvas.drawRRect(inside, Paint()..color = look.veil);
    }
    canvas.drawDRRect(pill, inside, Paint()..color = look.edge);
    final double width = ZsSwitch._knob + ZsSwitch._stretch * stretch;
    final double x = ZsSwitch._inset + travel.value * (ZsSwitch._travel - ZsSwitch._stretch * stretch);
    final knob = Rect.fromLTWH(x, ZsSwitch._inset, width, ZsSwitch._knob);
    canvas.drawRRect(
      RRect.fromRectAndRadius(knob, const Radius.circular(ZsSwitch._knob / 2)),
      Paint()..color = look.knob,
    );
  }

  @override
  bool shouldRepaint(_SwitchPainter oldDelegate) =>
      oldDelegate.look != look || oldDelegate.travel != travel || oldDelegate.stretch != stretch;
}
