// SPDX-License-Identifier: MIT

import 'package:flutter/widgets.dart';

import '../design/zs_appearance.dart';
import '../design/zs_colors.dart';
import '../design/zs_metrics.dart';
import '../design/zs_motion.dart';
import '../design/zs_type.dart';
import 'zs_control.dart';
import 'zs_control_text.dart';
import 'zs_focus_ring.dart';
import 'zs_lerp_builder.dart';
import 'zs_tooltip.dart';

typedef _RadioLook = ({Color fill, Color edge, Color veil, Color dot});

_RadioLook _lerpRadio(_RadioLook a, _RadioLook b, double t) => (
  fill: Color.lerp(a.fill, b.fill, t)!,
  edge: Color.lerp(a.edge, b.edge, t)!,
  veil: Color.lerp(a.veil, b.veil, t)!,
  dot: Color.lerp(a.dot, b.dot, t)!,
);

/// One option of a [ZsRadioGroup].
@immutable
class ZsRadioOption<T> {
  /// An option for [value] labelled [label].
  const ZsRadioOption({required this.value, required this.label, this.hint, this.disabledReason});

  /// The value it chooses.
  final T value;

  /// The label beside the circle.
  final String label;

  /// A dim second line under the label.
  final String? hint;

  /// Why it cannot be chosen; the option stays visible at .4 and carries the reason.
  final String? disabledReason;
}

/// The 15 px radio circle (DS components/controls/Radio.{d.ts,jsx,prompt.md}; controls.css:19-34), on `RawRadio`
/// inside the nearest [RadioGroup] of [T]: a 1.5 px `--text-faint` edge; hover `--text-muted`; pressed `--fl-on`;
/// on `--accent` with an `--accent-line` edge and a 6 px `--accent-ink` dot that grows 0 → 1 on `--dur-toggle` /
/// `--ease-glide` (simply there under reduce motion); on + hover and on + pressed veil the fill with
/// `--fill-on-hover` / `--fill-on-press`. The focus ring sits outside; colours fade on `--dur-hover`.
///
/// `RawRadio` gives the group's keys (arrows move, wrap and skip disabled options; Tab reaches the chosen one) and the
/// radio semantics (checked, in a mutually exclusive group); [ZsRadioGroup] puts the label beside it.
class ZsRadio<T> extends StatefulWidget implements ZsControl {
  /// A radio for [value].
  const ZsRadio({
    required this.value,
    this.enabled = true,
    this.rowHovered = false,
    this.statesController,
    this.identifier,
    super.key,
  });

  /// The value this radio chooses.
  final T value;

  /// Whether it can be chosen.
  final bool enabled;

  /// Whether the pointer is over the radio's row, which hovers the radio too (DS
  /// components/controls/controls.css:26).
  final bool rowHovered;

  /// A states controller whose states are shown on top of the radio's own; the catalogue forces states through it.
  final WidgetStatesController? statesController;

  @override
  final String? identifier;

  /// The circle's side, its edge and the dot (DS components/controls/controls.css:25, :31).
  static const double _side = 15;
  static const _edge = 1.5;
  static const double _dot = 6;

  @override
  State<ZsRadio<T>> createState() => _ZsRadioState<T>();
}

class _ZsRadioState<T> extends State<ZsRadio<T>> {
  final _focus = FocusNode(debugLabel: 'ZsRadio');

  @override
  void initState() {
    super.initState();
    widget.statesController?.addListener(_changed);
  }

  @override
  void didUpdateWidget(ZsRadio<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.statesController != widget.statesController) {
      oldWidget.statesController?.removeListener(_changed);
      widget.statesController?.addListener(_changed);
    }
  }

  @override
  void dispose() {
    widget.statesController?.removeListener(_changed);
    _focus.dispose();
    super.dispose();
  }

  void _changed() => setState(() {});

  _RadioLook _look(ZsColors c, {required bool on, required bool hover, required bool press}) {
    const clear = Color(0x00000000);
    if (on) {
      return (
        fill: c.accent,
        edge: c.accentLine,
        veil: press ? c.fillOnPress : (hover ? c.fillOnHover : clear),
        dot: c.accentInk,
      );
    }
    return (
      fill: press ? c.flOn : clear,
      edge: hover || press ? c.textMuted : c.textFaint,
      veil: clear,
      dot: c.accentInk,
    );
  }

  @override
  Widget build(BuildContext context) {
    final Widget radio = RawRadio<T>(
      value: widget.value,
      mouseCursor: const WidgetStatePropertyAll<MouseCursor>(SystemMouseCursors.basic),
      toggleable: false,
      focusNode: _focus,
      autofocus: false,
      groupRegistry: RadioGroup.maybeOf<T>(context),
      enabled: widget.enabled,
      builder: (context, state) {
        final states = <WidgetState>{...state.states, ...?widget.statesController?.value};
        final bool inactive = ZsAppearance.of(context).inactive;
        final bool enabled = !states.contains(WidgetState.disabled);
        final bool on = state.value ?? false;
        final bool hover = enabled && !inactive && (states.contains(WidgetState.hovered) || widget.rowHovered);
        final bool press = enabled && (state.downPosition != null || states.contains(WidgetState.pressed));
        final ZsMotion motion = ZsMotion.of(context);
        return ZsFocusRing(
          visible: states.contains(WidgetState.focused),
          radius: ZsRadio._side / 2,
          child: ZsLerpBuilder<double>(
            value: on ? 1 : 0,
            lerp: (a, b, t) => a + (b - a) * t,
            duration: motion.durToggle,
            curve: motion.easeGlide,
            builder: (context, dot, _) => ZsLerpBuilder<_RadioLook>(
              value: _look(ZsColors.of(context), on: on, hover: hover, press: press),
              lerp: _lerpRadio,
              duration: press ? motion.durInstant : motion.durHover,
              curve: motion.easeState,
              builder: (context, look, _) => CustomPaint(
                size: const Size.square(ZsRadio._side),
                painter: _RadioPainter(look: look, dot: dot),
              ),
            ),
          ),
        );
      },
    );
    return widget.identifier == null ? radio : Semantics(identifier: widget.identifier, child: radio);
  }
}

class _RadioPainter extends CustomPainter {
  _RadioPainter({required this.look, required this.dot});

  final _RadioLook look;
  final double dot;

  @override
  void paint(Canvas canvas, Size size) {
    final Offset centre = size.center(Offset.zero);
    final double r = size.shortestSide / 2;
    canvas.drawCircle(centre, r, Paint()..color = look.fill);
    if (look.veil.a > 0) {
      canvas.drawCircle(centre, r - ZsRadio._edge, Paint()..color = look.veil);
    }
    canvas.drawCircle(
      centre,
      r - ZsRadio._edge / 2,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = ZsRadio._edge
        ..color = look.edge,
    );
    if (dot > 0) {
      canvas.drawCircle(centre, ZsRadio._dot / 2 * dot, Paint()..color = look.dot);
    }
  }

  @override
  bool shouldRepaint(_RadioPainter oldDelegate) => oldDelegate.look != look || oldDelegate.dot != dot;
}

/// A radio group for one choice among options that need a sentence each (DS components/controls/Radio.{d.ts,jsx,
/// prompt.md}; controls.css:19-34), on `RadioGroup`: rows of a [ZsRadio] and its label (`--fs-control` `--text`)
/// with an optional hint (`--fs-id`, line height 1.4, `--text-dim`), gap 8, the rows 10 apart in a column or
/// 8 × 18 in a wrapping row.
///
/// A click on the label chooses. One Tab stop, the chosen radio (else the first); the arrows move, choose, wrap and
/// skip disabled options. A disabled option sits at .4, row and label together, and carries its reason on a wrapper
/// (a `ZsTooltip` and the radio's hint), overriding Radio.jsx's native disabled (DS readme.md:127). VoiceOver: a
/// radio group named [label] of radios.
class ZsRadioGroup<T> extends StatelessWidget implements ZsControl {
  /// A group of [options] showing [value].
  const ZsRadioGroup({
    required this.options,
    required this.value,
    required this.onChanged,
    this.label,
    this.direction = Axis.vertical,
    this.identifier,
    super.key,
  });

  /// The options, in order.
  final List<ZsRadioOption<T>> options;

  /// The chosen value.
  final T? value;

  /// Called with the chosen value; null disables the group.
  final ValueChanged<T>? onChanged;

  /// The group's accessible name.
  final String? label;

  /// A column (default) or a wrapping row.
  final Axis direction;

  @override
  final String? identifier;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[
      for (final ZsRadioOption<T> option in options) _RadioRow<T>(option: option, onChanged: onChanged),
    ];
    return Semantics(
      container: true,
      identifier: identifier,
      label: label,
      explicitChildNodes: true,
      child: RadioGroup<T>(
        groupValue: value,
        onChanged: (chosen) {
          if (chosen != null) {
            onChanged?.call(chosen);
          }
        },
        child: direction == Axis.vertical
            ? Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 10,
                children: rows,
              )
            : Wrap(spacing: 18, runSpacing: 8, children: rows),
      ),
    );
  }
}

class _RadioRow<T> extends StatefulWidget {
  const _RadioRow({required this.option, required this.onChanged});

  final ZsRadioOption<T> option;
  final ValueChanged<T>? onChanged;

  @override
  State<_RadioRow<T>> createState() => _RadioRowState<T>();
}

class _RadioRowState<T> extends State<_RadioRow<T>> {
  var _hovered = false;

  @override
  Widget build(BuildContext context) {
    final ZsColors colors = ZsColors.of(context);
    final ZsRadioOption<T> option = widget.option;
    final String? reason = option.disabledReason;
    final bool enabled = widget.onChanged != null && reason == null;
    final String? hint = option.hint;
    // The radio's own semantics (checked, enabled, in a mutually exclusive group) merge into this node; it adds only
    // the label and the reason, so no flag of the two overlaps.
    Widget row = Semantics(
      container: true,
      label: option.label,
      hint: reason,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          excludeFromSemantics: true,
          onTap: enabled ? () => widget.onChanged?.call(option.value) : null,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 8,
            children: <Widget>[
              ZsRadio<T>(value: option.value, enabled: enabled, rowHovered: _hovered),
              Flexible(
                child: ExcludeSemantics(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    spacing: 2,
                    children: <Widget>[
                      Text(
                        option.label,
                        style: zsSans(ZsType.fsControl, height: 15 / ZsType.fsControl).copyWith(color: colors.text),
                      ),
                      if (hint != null)
                        Text(hint, style: zsSans(ZsType.fsId, height: 1.4).copyWith(color: colors.textDim)),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (!enabled) {
      row = Opacity(opacity: ZsMetrics.of(context).disabledOpacity, child: row);
    }
    if (reason != null) {
      row = ZsTooltip(
        message: reason,
        child: IgnorePointer(child: ExcludeFocus(child: row)),
      );
    }
    return row;
  }
}
