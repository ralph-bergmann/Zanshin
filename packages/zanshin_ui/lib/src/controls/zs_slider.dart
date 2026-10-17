// SPDX-License-Identifier: MIT

import 'package:flutter/gestures.dart' show kPrimaryButton;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../design/zs_colors.dart';
import '../design/zs_elevation.dart';
import '../design/zs_metrics.dart';
import '../design/zs_motion.dart';
import '../design/zs_type.dart';
import '../design/zs_values.dart';
import 'zs_control.dart';
import 'zs_control_core.dart';
import 'zs_control_text.dart';
import 'zs_lerp_builder.dart';

typedef _SliderLook = ({Color groove, Color edge, Color readout, ZsShadowStack shadow});

_SliderLook _lerpSlider(_SliderLook a, _SliderLook b, double t) => (
  groove: Color.lerp(a.groove, b.groove, t)!,
  edge: Color.lerp(a.edge, b.edge, t)!,
  readout: Color.lerp(a.readout, b.readout, t)!,
  shadow: ZsShadowStack.lerp(a.shadow, b.shadow, t),
);

/// A slider for continuous view settings (DS components/forms/Slider.{d.ts,jsx,prompt.md}; forms.css:37-56), its
/// track a render box: a 4 px groove in an 18 px track, filled in `--accent-line` up to the value and `--track` after
/// it (hover `--track-hover`), with a 1 px `--track-edge` around it (hover `--track-edge-hover`); a 14 px `--thumb`
/// knob with a 1 px `--thumb-edge` and `--thumb-shadow` (hover `--thumb-shadow-hover`); while dragged a 5 px
/// `--accent-ring` halo appears at once. Ticks (1 × 3 `--tick`) mark every step when there are at most 21, or the
/// given values. The readout is `--fs-sm` mono, tabular, `--text-dim`, at least 38 wide, turning `--text` while
/// dragging.
///
/// Focus is the one rule drawn around the thumb: a `--focus-offset` gap, then a `--focus-w` ring in `--focus-ring`.
/// The gap stays transparent rather than `--card-solid` (DS components/forms/forms.css:49-50), because the slider
/// also sits on glass and in the Settings window (r4out a11y KVS-13; Claude's proposal, Story 11.11).
///
/// The value never tweens: a drag follows the pointer, a press on the track jumps there and continues as a drag, and
/// keys land at once — ← ↓ one step down, → ↑ one up, Page Down / Page Up ten steps (at most to the ends), Home / End
/// the ends (DS readme.md:282). VoiceOver: a slider named [label] whose value reads with [unit] ("240 px").
class ZsSlider extends StatefulWidget implements ZsControl {
  /// A slider showing [value].
  const ZsSlider({
    required this.value,
    required this.onChanged,
    this.min = 0,
    this.max = 100,
    this.step = 1,
    this.width = 120,
    this.unit = '',
    this.label,
    this.showValue = true,
    this.ticks = false,
    this.tickValues,
    this.disabledReason,
    this.focusNode,
    this.statesController,
    this.identifier,
    super.key,
  }) : assert(max > min, 'The range must not be empty.'),
       assert(step > 0, 'The step must be positive.');

  /// The value, between [min] and [max].
  final double value;

  /// Called with each new value; null disables the slider.
  final ValueChanged<double>? onChanged;

  /// The smallest value.
  final double min;

  /// The largest value.
  final double max;

  /// The step the value snaps to.
  final double step;

  /// The track's width.
  final double width;

  /// Appended to the readout and the value VoiceOver reads ("px").
  final String unit;

  /// The accessible name.
  final String? label;

  /// Whether the readout shows.
  final bool showValue;

  /// Whether every step carries a tick (only with at most 21 steps).
  final bool ticks;

  /// The values to mark, instead of every step.
  final List<double>? tickValues;

  /// Why the slider is disabled.
  final String? disabledReason;

  /// The slider's focus node.
  final FocusNode? focusNode;

  /// A states controller; the catalogue forces states through it.
  final WidgetStatesController? statesController;

  @override
  final String? identifier;

  /// The track box's height and the knob (DS components/forms/forms.css:40, :43).
  static const double _trackHeight = 18;
  static const double _thumb = 14;

  /// The gap between the track and the readout, and the readout's smallest width (DS components/forms/forms.css:39,
  /// :53).
  static const double _readoutGap = 10;
  static const double _readoutWidth = 38;

  /// Page Up / Page Down move ten steps (DS components/forms/Slider.jsx:24).
  static const _page = 10;

  /// Ticks show for at most this many intervals (21 values; DS components/forms/Slider.jsx:17).
  static const _maxTickIntervals = 20;

  @override
  State<ZsSlider> createState() => _ZsSliderState();
}

class _ZsSliderState extends State<ZsSlider> {
  final GlobalKey _track = GlobalKey();

  bool get _enabled => widget.onChanged != null && widget.disabledReason == null;

  double _snap(double value) {
    final double clamped = value.clamp(widget.min, widget.max);
    final double snapped = widget.min + ((clamped - widget.min) / widget.step).roundToDouble() * widget.step;
    return snapped.clamp(widget.min, widget.max);
  }

  void _set(double value) {
    final double next = _snap(value);
    if (next != widget.value) {
      widget.onChanged?.call(next);
    }
  }

  void _toPointer(Offset global) {
    final box = _track.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) {
      return;
    }
    final double x = box.globalToLocal(global).dx;
    final double travel = box.size.width - ZsSlider._thumb;
    final double p = ((x - ZsSlider._thumb / 2) / travel).clamp(0, 1);
    _set(widget.min + p * (widget.max - widget.min));
  }

  String _format(double value) {
    final number = value == value.roundToDouble() ? value.toInt().toString() : value.toString();
    return '$number${widget.unit}';
  }

  List<double> get _marks {
    final List<double>? values = widget.tickValues;
    if (values != null) {
      return values;
    }
    if (!widget.ticks) {
      return const <double>[];
    }
    final int n = ((widget.max - widget.min) / widget.step).round();
    return n > ZsSlider._maxTickIntervals
        ? const <double>[]
        : <double>[for (var i = 0; i <= n; i++) widget.min + i * widget.step];
  }

  @override
  Widget build(BuildContext context) {
    final double step = widget.step;
    final double value = widget.value;
    void by(double delta) => _set(value + delta);
    final shortcuts = <ShortcutActivator, Intent>{
      const SingleActivator(LogicalKeyboardKey.arrowLeft): VoidCallbackIntent(() => by(-step)),
      const SingleActivator(LogicalKeyboardKey.arrowDown): VoidCallbackIntent(() => by(-step)),
      const SingleActivator(LogicalKeyboardKey.arrowRight): VoidCallbackIntent(() => by(step)),
      const SingleActivator(LogicalKeyboardKey.arrowUp): VoidCallbackIntent(() => by(step)),
      const SingleActivator(LogicalKeyboardKey.pageUp): VoidCallbackIntent(() => by(step * ZsSlider._page)),
      const SingleActivator(LogicalKeyboardKey.pageDown): VoidCallbackIntent(() => by(-step * ZsSlider._page)),
      const SingleActivator(LogicalKeyboardKey.home): VoidCallbackIntent(() => _set(widget.min)),
      const SingleActivator(LogicalKeyboardKey.end): VoidCallbackIntent(() => _set(widget.max)),
    };
    return ZsControlCore(
      identifier: widget.identifier,
      focusNode: widget.focusNode,
      statesController: widget.statesController,
      enabled: widget.onChanged != null,
      disabledReason: widget.disabledReason,
      activateOnKeys: false,
      shortcuts: shortcuts,
      actions: <Type, Action<Intent>>{VoidCallbackIntent: VoidCallbackAction()},
      semantics: SemanticsProperties(
        slider: true,
        label: widget.label,
        value: _format(value),
        increasedValue: _format(_snap(value + step)),
        decreasedValue: _format(_snap(value - step)),
        onIncrease: () => by(step),
        onDecrease: () => by(-step),
      ),
      builder: (context, status) {
        final ZsColors colors = ZsColors.of(context);
        final ZsElevation elevation = ZsElevation.of(context);
        final ZsMotion motion = ZsMotion.of(context);
        final metrics = ZsMetrics.of(context);
        final bool drag = status.pressed;
        final _SliderLook target = (
          groove: status.hovered ? colors.trackHover : colors.track,
          edge: status.hovered ? colors.trackEdgeHover : colors.trackEdge,
          readout: drag ? colors.text : colors.textDim,
          shadow: status.hovered ? elevation.thumbShadowHover : elevation.thumbShadow,
        );
        return ZsLerpBuilder<_SliderLook>(
          value: target,
          lerp: _lerpSlider,
          duration: motion.durHover,
          curve: motion.easeState,
          builder: (context, look, _) {
            final Widget track = Listener(
              onPointerDown: (event) {
                if (_enabled && event.buttons & kPrimaryButton != 0) {
                  _toPointer(event.position);
                }
              },
              onPointerMove: (event) {
                if (_enabled && event.buttons & kPrimaryButton != 0) {
                  _toPointer(event.position);
                }
              },
              child: _SliderTrack(
                key: _track,
                width: widget.width,
                fraction: (value - widget.min) / (widget.max - widget.min),
                marks: <double>[for (final double m in _marks) (m - widget.min) / (widget.max - widget.min)],
                fill: colors.accentLine,
                groove: look.groove,
                edge: look.edge,
                tick: colors.tick,
                thumb: colors.thumb,
                thumbEdge: colors.thumbEdge,
                shadow: look.shadow,
                halo: drag ? colors.accentRing : null,
                ring: status.focusVisible ? colors.focusRing : null,
                ringGap: metrics.focusOffset,
                ringWidth: metrics.focusW,
              ),
            );
            if (!widget.showValue) {
              return track;
            }
            return Row(
              mainAxisSize: MainAxisSize.min,
              spacing: ZsSlider._readoutGap,
              children: <Widget>[
                track,
                ConstrainedBox(
                  constraints: const BoxConstraints(minWidth: ZsSlider._readoutWidth),
                  child: Text(_format(value), style: zsMono(ZsType.fsSm, height: 1.35).copyWith(color: look.readout)),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

class _SliderTrack extends LeafRenderObjectWidget {
  const _SliderTrack({
    required this.width,
    required this.fraction,
    required this.marks,
    required this.fill,
    required this.groove,
    required this.edge,
    required this.tick,
    required this.thumb,
    required this.thumbEdge,
    required this.shadow,
    required this.halo,
    required this.ring,
    required this.ringGap,
    required this.ringWidth,
    super.key,
  });

  final double width;
  final double fraction;
  final List<double> marks;
  final Color fill;
  final Color groove;
  final Color edge;
  final Color tick;
  final Color thumb;
  final Color thumbEdge;
  final ZsShadowStack shadow;
  final Color? halo;
  final Color? ring;
  final double ringGap;
  final double ringWidth;

  @override
  _RenderSliderTrack createRenderObject(BuildContext context) => _RenderSliderTrack(this);

  @override
  void updateRenderObject(BuildContext context, _RenderSliderTrack renderObject) => renderObject.config = this;
}

/// Paints the groove, the ticks and the knob, with its halo and focus ring, on a `width × 18` box.
class _RenderSliderTrack extends RenderBox {
  _RenderSliderTrack(this._config);

  /// The groove's height (DS components/forms/forms.css:41).
  static const double _groove = 4;

  /// The ticks: 1 × 3 at 13 px from the top of the track, inset 7 px at both ends (DS components/forms/forms.css:51-52).
  static const double _tickTop = 13;
  static const double _tickHeight = 3;

  /// The drag halo's spread (DS components/forms/forms.css:47).
  static const double _halo = 5;

  _SliderTrack _config;
  _SliderTrack get config => _config;
  set config(_SliderTrack value) {
    if (value.width != _config.width) {
      _config = value;
      markNeedsLayout();
      return;
    }
    _config = value;
    markNeedsPaint();
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) =>
      constraints.constrain(Size(_config.width, ZsSlider._trackHeight));

  @override
  void performLayout() {
    size = computeDryLayout(constraints);
  }

  @override
  bool hitTestSelf(Offset position) => true;

  @override
  void paint(PaintingContext context, Offset offset) {
    final Canvas canvas = context.canvas;
    final _SliderTrack c = _config;
    final double midY = offset.dy + size.height / 2;
    final groove = RRect.fromRectAndRadius(
      Rect.fromLTWH(offset.dx, midY - _groove / 2, size.width, _groove),
      const Radius.circular(_groove / 2),
    );
    // `box-shadow:0 0 0 1px var(--track-edge)`: a ring just outside the groove.
    canvas
      ..drawDRRect(groove.inflate(1), groove, Paint()..color = c.edge)
      ..drawRRect(groove, Paint()..color = c.groove)
      ..save()
      ..clipRect(Rect.fromLTWH(offset.dx, groove.top, size.width * c.fraction.clamp(0, 1), _groove))
      ..drawRRect(groove, Paint()..color = c.fill)
      ..restore();
    final double travel = size.width - ZsSlider._thumb;
    for (final double mark in c.marks) {
      final double x = offset.dx + ZsSlider._thumb / 2 + travel * mark.clamp(0, 1);
      canvas.drawRect(Rect.fromLTWH(x, offset.dy + _tickTop, 1, _tickHeight), Paint()..color = c.tick);
    }
    final centre = Offset(offset.dx + ZsSlider._thumb / 2 + travel * c.fraction.clamp(0, 1), midY);
    const double r = ZsSlider._thumb / 2;
    final Color? ring = c.ring;
    if (ring != null && ring.a > 0) {
      // `0 0 0 1px edge, 0 0 0 (1 + offset) gap, 0 0 0 (1 + offset + w) ring`: the gap stays transparent.
      final double inner = r + 1 + c.ringGap;
      canvas.drawCircle(
        centre,
        inner + c.ringWidth / 2,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = c.ringWidth
          ..color = ring,
      );
    }
    final Color? halo = c.halo;
    if (halo != null) {
      canvas.drawCircle(centre, r + _halo, Paint()..color = halo);
    }
    final knob = Rect.fromCircle(center: centre, radius: r);
    for (final BoxShadow shadow in c.shadow.boxShadows.reversed) {
      canvas.drawCircle(
        centre + shadow.offset,
        r + shadow.spreadRadius,
        Paint()
          ..color = shadow.color
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, shadow.blurSigma),
      );
    }
    canvas
      ..drawCircle(centre, r + 1, Paint()..color = c.thumbEdge)
      ..drawOval(knob, Paint()..color = c.thumb);
  }

  @override
  double computeMinIntrinsicWidth(double height) => _config.width;

  @override
  double computeMaxIntrinsicWidth(double height) => _config.width;

  @override
  double computeMinIntrinsicHeight(double width) => ZsSlider._trackHeight;

  @override
  double computeMaxIntrinsicHeight(double width) => ZsSlider._trackHeight;

  @override
  void debugFillProperties(DiagnosticPropertiesBuilder properties) {
    super.debugFillProperties(properties);
    properties.add(DoubleProperty('fraction', _config.fraction));
  }
}
