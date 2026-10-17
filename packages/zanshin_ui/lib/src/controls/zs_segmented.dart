// SPDX-License-Identifier: MIT

import 'dart:ui' show lerpDouble;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../design/zs_appearance.dart';
import '../design/zs_colors.dart';
import '../design/zs_metrics.dart';
import '../design/zs_motion.dart';
import '../design/zs_type.dart';
import '../icons/zanshin_icon.dart';
import 'zs_control.dart';
import 'zs_control_core.dart';
import 'zs_control_text.dart';
import 'zs_focus_ring.dart';
import 'zs_lerp_builder.dart';

/// One segment of a [ZsSegmented].
@immutable
class ZsSegment<T> {
  /// A segment for [value].
  const ZsSegment({required this.value, this.label, this.icon, this.tooltip, this.disabledReason})
    : assert(label != null || icon != null, 'A segment shows a label, an icon or both.');

  /// The value it chooses.
  final T value;

  /// The text; an icon-only segment takes [tooltip] as its name.
  final String? label;

  /// A `ZI` glyph before the label.
  final String? icon;

  /// The name of an icon-only segment.
  final String? tooltip;

  /// Why it cannot be chosen; it stays visible at .4, keeps its hover for the reason and is skipped by the arrows.
  final String? disabledReason;
}

/// A segmented control's variant (DS components/forms/Segmented.d.ts; forms.css:16-22).
enum ZsSegmentedVariant {
  /// 26 (View options).
  standard,

  /// 36: the Settings window's scope tabs; VoiceOver reads tabs.
  tabs,

  /// 30: inside a settings row, on the darker `--seg-inset-bg` track.
  inset,
}

/// A segmented control's size (DS components/forms/Segmented.d.ts).
enum ZsSegmentedSize {
  /// The variant's own height.
  md,

  /// 22: icon toggles in a diff toolbar.
  sm,
}

/// A segmented control for 2–4 exclusive options (DS components/forms/Segmented.{d.ts,jsx,prompt.md};
/// forms.css:5-22).
///
/// | variant | outer | track padding | segment | padding | radius (track · segment) | type |
/// |---|---|---|---|---|---|---|
/// | standard | 26 | 2 | 22 | 0 9 | `--radius-md` · `--radius-sm` | `--fs-md` |
/// | tabs | 36 | 3 | 30 | 0 14 | `--radius-card` · `--radius-chip` | `--fs-control` |
/// | inset | 30 | 2 | 26 | 0 10 | `--radius-md` · `--radius-sm` | `--fs-md` |
/// | sm | 22 | 2 | 18 | 0 7 | `--radius-md` · `--radius-sm` | `--fs-xs` |
///
/// The track is `--fl-hover` (inset: `--seg-inset-bg`); a `--fl-on` thumb lies under the chosen segment and slides
/// there — X and width — on `--dur-toggle` / `--ease-glide` (simply there under reduce motion, and on the first
/// layout). Hover brightens only the label (`--text-muted` → `--text`); a pressed segment that is not chosen shows
/// `--fl-hover` under it. Under increased contrast the track and the thumb add a 1 px `--border-strong` edge (DS
/// tokens/contrast.css:23, :25). The focus ring sits inside the segment (a flush segment).
///
/// One Tab stop, the chosen segment — the first enabled one when the chosen one is disabled (r4out a11y KVS-11); ←/→
/// (and ↑/↓) choose, skipping disabled segments, and wrap. VoiceOver: a radio group named [label] of radios (tabs:
/// selected tabs).
class ZsSegmented<T> extends StatefulWidget implements ZsControl {
  /// A segmented control over [segments] showing [value].
  const ZsSegmented({
    required this.segments,
    required this.value,
    required this.onChanged,
    this.label,
    this.variant = ZsSegmentedVariant.standard,
    this.size = ZsSegmentedSize.md,
    this.statesControllers,
    this.identifier,
    super.key,
  });

  /// The segments, in order.
  final List<ZsSegment<T>> segments;

  /// The chosen value.
  final T value;

  /// Called with the chosen value; null disables the control.
  final ValueChanged<T>? onChanged;

  /// The group's accessible name.
  final String? label;

  /// The variant.
  final ZsSegmentedVariant variant;

  /// md or sm.
  final ZsSegmentedSize size;

  /// One states controller per segment, in order; the catalogue forces states through them.
  final List<WidgetStatesController>? statesControllers;

  @override
  final String? identifier;

  @override
  State<ZsSegmented<T>> createState() => _ZsSegmentedState<T>();
}

class _ZsSegmentedState<T> extends State<ZsSegmented<T>> with SingleTickerProviderStateMixin {
  late final _slide = AnimationController(vsync: this, value: 1);
  late final _glide = CurvedAnimation(parent: _slide, curve: ZsMotion.full.easeGlide);
  final _nodes = <FocusNode>[];

  int get _selected => widget.segments.indexWhere((segment) => segment.value == widget.value);

  bool _enabled(int index) => widget.onChanged != null && widget.segments[index].disabledReason == null;

  /// The one Tab stop: the chosen segment, else the first enabled one.
  int get _tabStop {
    final int selected = _selected;
    if (selected >= 0 && _enabled(selected)) {
      return selected;
    }
    return List<int>.generate(widget.segments.length, (i) => i).firstWhere(_enabled, orElse: () => -1);
  }

  void _syncNodes() {
    while (_nodes.length < widget.segments.length) {
      _nodes.add(FocusNode(debugLabel: 'ZsSegment ${_nodes.length}'));
    }
    while (_nodes.length > widget.segments.length) {
      _nodes.removeLast().dispose();
    }
  }

  @override
  void initState() {
    super.initState();
    _syncNodes();
  }

  @override
  void didUpdateWidget(ZsSegmented<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncNodes();
    if (oldWidget.value != widget.value) {
      _slide
        ..duration = ZsMotion.of(context).durToggle
        ..forward(from: 0);
    }
  }

  @override
  void dispose() {
    _glide.dispose();
    _slide.dispose();
    for (final FocusNode node in _nodes) {
      node.dispose();
    }
    super.dispose();
  }

  void _choose(int index) {
    if (_enabled(index) && widget.segments[index].value != widget.value) {
      widget.onChanged?.call(widget.segments[index].value);
    }
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent || !_nodes.any((node) => node.hasPrimaryFocus)) {
      return KeyEventResult.ignored;
    }
    final LogicalKeyboardKey key = event.logicalKey;
    final step = key == LogicalKeyboardKey.arrowRight || key == LogicalKeyboardKey.arrowDown
        ? 1
        : (key == LogicalKeyboardKey.arrowLeft || key == LogicalKeyboardKey.arrowUp ? -1 : 0);
    if (step == 0) {
      return KeyEventResult.ignored;
    }
    final int count = widget.segments.length;
    final int from = _nodes.indexWhere((node) => node.hasPrimaryFocus);
    for (var k = 1; k <= count; k++) {
      final int j = (from + step * k + count * 2) % count;
      if (_enabled(j)) {
        _choose(j);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && j < _nodes.length) {
            _nodes[j].requestFocus();
          }
        });
        break;
      }
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final metrics = ZsMetrics.of(context);
    final ZsColors colors = ZsColors.of(context);
    final tabs = widget.variant == ZsSegmentedVariant.tabs;
    final small = widget.size == ZsSegmentedSize.sm;
    // The track's padding `2px` (tabs `3px`) and the segment heights `calc(--control-* − 4px)` (tabs `− 6px`) (DS
    // components/forms/forms.css:7, :9, :17, :19, :21-22).
    final double pad = tabs ? 3 : 2;
    final double height = switch ((widget.variant, small)) {
      (_, true) => metrics.controlXs - 4,
      (ZsSegmentedVariant.tabs, false) => metrics.controlLg - 6,
      (ZsSegmentedVariant.inset, false) => metrics.controlMd - 4,
      (ZsSegmentedVariant.standard, false) => metrics.controlSm - 4,
    };
    final double trackRadius = tabs ? metrics.radiusCard : metrics.radiusMd;
    final double segmentRadius = tabs ? metrics.radiusChip : metrics.radiusSm;
    final int stop = _tabStop;
    final int selected = _selected;
    final bool contrast = ZsAppearance.of(context).increasedContrast;
    return Semantics(
      container: true,
      identifier: widget.identifier,
      label: widget.label,
      explicitChildNodes: true,
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        includeSemantics: false,
        onKeyEvent: _handleKey,
        child: _SegmentTrack(
          padding: pad,
          gap: 2,
          selected: selected,
          slide: _glide,
          trackColor: widget.variant == ZsSegmentedVariant.inset ? colors.segInsetBg : colors.flHover,
          thumbColor: colors.flOn,
          edgeColor: contrast ? colors.borderStrong : null,
          trackRadius: trackRadius,
          thumbRadius: segmentRadius,
          children: <Widget>[
            for (var i = 0; i < widget.segments.length; i++)
              ExcludeFocus(
                excluding: i != stop,
                child: _segment(context, i, height, segmentRadius, selected: i == selected),
              ),
          ],
        ),
      ),
    );
  }

  Widget _segment(BuildContext context, int index, double height, double radius, {required bool selected}) {
    final ZsSegment<T> segment = widget.segments[index];
    final tabs = widget.variant == ZsSegmentedVariant.tabs;
    final small = widget.size == ZsSegmentedSize.sm;
    final List<WidgetStatesController>? controllers = widget.statesControllers;
    return ZsControlCore(
      focusNode: _nodes[index],
      statesController: controllers != null && index < controllers.length ? controllers[index] : null,
      onActivate: () => _choose(index),
      enabled: widget.onChanged != null,
      disabledReason: segment.disabledReason,
      selected: selected,
      semantics: SemanticsProperties(
        label: segment.label ?? segment.tooltip,
        inMutuallyExclusiveGroup: tabs ? null : true,
        checked: tabs ? null : selected,
        selected: tabs ? selected : null,
        button: tabs ? true : null,
      ),
      ring: ZsRingPlacement.inside,
      ringRadius: radius,
      builder: (context, status) {
        final ZsColors colors = ZsColors.of(context);
        final ZsMotion motion = ZsMotion.of(context);
        final bool lit = status.selected || status.hovered || status.pressed;
        final Color fill = status.pressed && !status.selected ? colors.flHover : const Color(0x00000000);
        final double fontSize = small ? ZsType.fsXs : (tabs ? ZsType.fsControl : ZsType.fsMd);
        // `padding:0 9px` · tabs `0 14px` · inset `0 10px` · sm `0 7px` (DS components/forms/forms.css:9, :19, :21-22).
        final double padX = small ? 7 : (tabs ? 14 : (widget.variant == ZsSegmentedVariant.inset ? 10 : 9));
        final String? icon = segment.icon;
        final String? label = segment.label;
        return ZsLerpBuilder<(Color, Color)>(
          value: (fill, lit ? colors.text : colors.textMuted),
          lerp: (a, b, t) => (Color.lerp(a.$1, b.$1, t)!, Color.lerp(a.$2, b.$2, t)!),
          duration: status.pressed ? motion.durInstant : motion.durHover,
          curve: motion.easeState,
          builder: (context, look, _) => DecoratedBox(
            decoration: BoxDecoration(color: look.$1, borderRadius: BorderRadius.circular(radius)),
            child: SizedBox(
              height: height,
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: padX),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  spacing: tabs ? 7 : 5,
                  children: <Widget>[
                    if (icon != null) ZanshinIcon(icon, size: tabs ? ZsIconSize.md : ZsIconSize.sm, color: look.$2),
                    if (label != null) Text(label, style: zsSans(fontSize).copyWith(color: look.$2), softWrap: false),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Lays the segments out in a row and paints the track and the sliding thumb under them.
class _SegmentTrack extends MultiChildRenderObjectWidget {
  const _SegmentTrack({
    required this.padding,
    required this.gap,
    required this.selected,
    required this.slide,
    required this.trackColor,
    required this.thumbColor,
    required this.edgeColor,
    required this.trackRadius,
    required this.thumbRadius,
    required super.children,
  });

  final double padding;
  final double gap;
  final int selected;
  final Animation<double> slide;
  final Color trackColor;
  final Color thumbColor;
  final Color? edgeColor;
  final double trackRadius;
  final double thumbRadius;

  @override
  _RenderSegmentTrack createRenderObject(BuildContext context) => _RenderSegmentTrack(
    padding: padding,
    gap: gap,
    selected: selected,
    slide: slide,
    trackColor: trackColor,
    thumbColor: thumbColor,
    edgeColor: edgeColor,
    trackRadius: trackRadius,
    thumbRadius: thumbRadius,
  );

  @override
  void updateRenderObject(BuildContext context, _RenderSegmentTrack renderObject) {
    renderObject
      ..padding = padding
      ..gap = gap
      ..selected = selected
      ..slide = slide
      ..trackColor = trackColor
      ..thumbColor = thumbColor
      ..edgeColor = edgeColor
      ..trackRadius = trackRadius
      ..thumbRadius = thumbRadius;
  }
}

class _SegmentParentData extends ContainerBoxParentData<RenderBox> {}

class _RenderSegmentTrack extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _SegmentParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _SegmentParentData> {
  _RenderSegmentTrack({
    required this._padding,
    required this._gap,
    required this._selected,
    required this._slide,
    required this._trackColor,
    required this._thumbColor,
    required this._edgeColor,
    required this._trackRadius,
    required this._thumbRadius,
  });

  double _padding;
  double get padding => _padding;
  set padding(double value) {
    if (value != _padding) {
      _padding = value;
      markNeedsLayout();
    }
  }

  double _gap;
  double get gap => _gap;
  set gap(double value) {
    if (value != _gap) {
      _gap = value;
      markNeedsLayout();
    }
  }

  int _selected;
  int get selected => _selected;
  set selected(int value) {
    if (value != _selected) {
      // The thumb slides from where it is painted now, even mid-slide.
      _from = _painted;
      _selected = value;
      markNeedsPaint();
    }
  }

  Animation<double> _slide;
  Animation<double> get slide => _slide;
  set slide(Animation<double> value) {
    if (value != _slide) {
      if (attached) {
        _slide.removeListener(markNeedsPaint);
        value.addListener(markNeedsPaint);
      }
      _slide = value;
      markNeedsPaint();
    }
  }

  Color _trackColor;
  Color get trackColor => _trackColor;
  set trackColor(Color value) {
    if (value != _trackColor) {
      _trackColor = value;
      markNeedsPaint();
    }
  }

  Color _thumbColor;
  Color get thumbColor => _thumbColor;
  set thumbColor(Color value) {
    if (value != _thumbColor) {
      _thumbColor = value;
      markNeedsPaint();
    }
  }

  Color? _edgeColor;
  Color? get edgeColor => _edgeColor;
  set edgeColor(Color? value) {
    if (value != _edgeColor) {
      _edgeColor = value;
      markNeedsPaint();
    }
  }

  double _trackRadius;
  double get trackRadius => _trackRadius;
  set trackRadius(double value) {
    if (value != _trackRadius) {
      _trackRadius = value;
      markNeedsPaint();
    }
  }

  double _thumbRadius;
  double get thumbRadius => _thumbRadius;
  set thumbRadius(double value) {
    if (value != _thumbRadius) {
      _thumbRadius = value;
      markNeedsPaint();
    }
  }

  /// Where the thumb was when the choice changed; null on the first layout.
  Rect? _from;

  /// Where the thumb was last painted.
  Rect? _painted;

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _slide.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    _slide.removeListener(markNeedsPaint);
    super.detach();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _SegmentParentData) {
      child.parentData = _SegmentParentData();
    }
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    double width = _padding * 2;
    var height = 0.0;
    var count = 0;
    for (RenderBox? child = firstChild; child != null; child = childAfter(child)) {
      final Size size = child.getDryLayout(const BoxConstraints());
      width += size.width;
      height = height < size.height ? size.height : height;
      count++;
    }
    width += _gap * (count > 0 ? count - 1 : 0);
    return constraints.constrain(Size(width, height + _padding * 2));
  }

  @override
  void performLayout() {
    double x = _padding;
    var height = 0.0;
    for (RenderBox? child = firstChild; child != null; child = childAfter(child)) {
      child.layout(const BoxConstraints(), parentUsesSize: true);
      (child.parentData! as _SegmentParentData).offset = Offset(x, _padding);
      x += child.size.width + _gap;
      height = height < child.size.height ? child.size.height : height;
    }
    final double width = childCount > 0 ? x - _gap + _padding : _padding * 2;
    size = constraints.constrain(Size(width, height + _padding * 2));
  }

  Rect? _segmentRect(int index) {
    var i = 0;
    for (RenderBox? child = firstChild; child != null; child = childAfter(child)) {
      if (i == index) {
        return (child.parentData! as _SegmentParentData).offset & child.size;
      }
      i++;
    }
    return null;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final Canvas canvas = context.canvas;
    final track = RRect.fromRectAndRadius(offset & size, Radius.circular(_trackRadius));
    canvas.drawRRect(track, Paint()..color = _trackColor);
    final Color? edge = _edgeColor;
    if (edge != null) {
      canvas.drawDRRect(track, track.deflate(1), Paint()..color = edge);
    }
    final Rect? target = _segmentRect(_selected);
    if (target != null) {
      final Rect? from = _from;
      final double t = _slide.value;
      final Rect rect = from == null || t >= 1
          ? target
          : Rect.fromLTWH(
              lerpDouble(from.left, target.left, t)!,
              target.top,
              lerpDouble(from.width, target.width, t)!,
              target.height,
            );
      _painted = rect;
      final thumb = RRect.fromRectAndRadius(rect.shift(offset), Radius.circular(_thumbRadius));
      canvas.drawRRect(thumb, Paint()..color = _thumbColor);
      if (edge != null) {
        canvas.drawDRRect(thumb, thumb.deflate(1), Paint()..color = edge);
      }
    } else {
      _painted = null;
    }
    defaultPaint(context, offset);
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}
