// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart' show kPrimaryButton;
import 'package:flutter/rendering.dart' show BoxHitTestResult, RenderProxyBox;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../design/zs_colors.dart';
import '../design/zs_metrics.dart';
import '../design/zs_motion.dart';
import '../design/zs_root.dart';
import 'zs_control.dart';
import 'zs_focus_ring.dart';
import 'zs_lerp_builder.dart';

/// A scroll area with the macOS overlay scroll bar (DS components/controls/ScrollArea.{d.ts,jsx,prompt.md};
/// controls.css:111-124), over any scrollable [child] that runs on [controller] (and, for both axes,
/// [horizontalController]).
///
/// **Bar.** An overlay that never takes width: a 14 px gutter (`--scroll-gutter`) 2 px in from the ends, a pill
/// thumb at least 24 long — `--scroll-w` 6 wide, 4 from the edge; with the pointer in the gutter or while dragged
/// `--scroll-w-hover` 10 wide, 2 from the edge (geometry on `--dur-nudge` / glide, 0 under reduce motion), in
/// `--scroll-thumb`, `--scroll-thumb-hover`, `--scroll-thumb-drag`, over a `--scroll-track` while hovered or dragged
/// (colours on `--dur-hover`). Hidden at rest: it fades in on `--dur-hover` while scrolling or with the pointer in
/// the gutter and out on `--dur-exit-lg` `--delay-scroll-hide` after the last scroll — unless the shell reports the
/// legacy scroller style ("Show scroll bars: Always") or [alwaysShowScrollBars] is set.
///
/// **Track press.** One page (the viewport less 40 — the DS's Page Down) toward the press, or with "Jump to the spot
/// that's clicked" the thumb centred on the press (story 11.11 item 2, r4out a11y KVS-14); ⌥ does the other; the
/// press continues as a thumb drag. The behaviour is [jumpToClickedSpot], else the shell's
/// `ShellTheme.jumpToClickedSpot` from `ZsShellScope`, read at the moment of the press. Every move jumps; nothing
/// tweens. Claude's proposal (Story 11.11): a bar of its own over the caller's scrollable, because `RawScrollbar`'s
/// track tap pages 0.8 × the viewport with a tween and never continues as a drag (`scrollbar.dart:1916-1956`,
/// `:2460-2469`); and the page amount of the keys for the track.
///
/// **Keys.** The viewport is a Tab stop only while it scrolls and holds nothing focusable itself (r4out a11y KVS-1;
/// V2 §4), with the ring inside; while it has focus ↑ ↓ (and ← → with a horizontal controller) move 40, Page Up / Page
/// Down and Space / ⇧Space one page less 40, Home / End to the ends. VoiceOver: a region named [label]; the bars are
/// decoration.
class ZsScrollArea extends StatefulWidget implements ZsControl {
  /// A scroll area over [child].
  const ZsScrollArea({
    required this.controller,
    required this.child,
    this.horizontalController,
    this.label,
    this.jumpToClickedSpot,
    this.alwaysShowScrollBars,
    this.identifier,
    super.key,
  });

  /// The vertical scroll position of [child].
  final ScrollController controller;

  /// The horizontal scroll position, for an area scrolling both ways; it adds a bar along the bottom.
  final ScrollController? horizontalController;

  /// A scrollable on [controller].
  final Widget child;

  /// The region's accessible name.
  final String? label;

  /// Whether a track press jumps to the spot; null follows the shell.
  final bool? jumpToClickedSpot;

  /// Whether the bars always show; null follows the shell's scroller style.
  final bool? alwaysShowScrollBars;

  @override
  final String? identifier;

  /// A key or page step's margin and an arrow key's step (DS components/controls/ScrollArea.jsx:9, :47, :56).
  static const double _keyStep = 40;

  /// The gutter's inset from the ends of the area (DS components/controls/controls.css:115).
  static const double _inset = 2;

  /// The thumb's smallest length (DS components/controls/ScrollArea.jsx:22).
  static const double _minThumb = 24;

  @override
  State<ZsScrollArea> createState() => _ZsScrollAreaState();
}

class _ZsScrollAreaState extends State<ZsScrollArea> {
  final _viewport = FocusNode(debugLabel: 'ZsScrollArea');
  var _tabStop = false;
  var _focused = false;
  var _scrolling = false;
  Axis? _hover;
  Axis? _drag;
  Timer? _hide;

  /// The shell's scroll bar preferences as the last build read them, so a track press reads the current ones.
  var _shellAlwaysShows = false;
  var _shellJumps = false;
  var _evaluating = false;

  @override
  void initState() {
    super.initState();
    _viewport.addListener(_focusChanged);
    widget.controller.addListener(_scrolled);
    widget.horizontalController?.addListener(_scrolled);
  }

  @override
  void didUpdateWidget(ZsScrollArea oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_scrolled);
      widget.controller.addListener(_scrolled);
    }
    if (oldWidget.horizontalController != widget.horizontalController) {
      oldWidget.horizontalController?.removeListener(_scrolled);
      widget.horizontalController?.addListener(_scrolled);
    }
  }

  @override
  void dispose() {
    _hide?.cancel();
    widget.controller.removeListener(_scrolled);
    widget.horizontalController?.removeListener(_scrolled);
    _viewport
      ..removeListener(_focusChanged)
      ..dispose();
    super.dispose();
  }

  void _focusChanged() {
    final bool focused = _viewport.hasPrimaryFocus;
    if (focused != _focused) {
      setState(() => _focused = focused);
    }
  }

  void _scrolled() {
    if (!mounted) {
      return;
    }
    _hide?.cancel();
    _hide = Timer(ZsMotion.of(context).delayScrollHide, () {
      if (mounted) {
        setState(() => _scrolling = false);
      }
    });
    setState(() => _scrolling = true);
  }

  /// Whether the viewport is a Tab stop: it scrolls and nothing below it takes focus (r4out a11y KVS-1).
  void _scheduleTabStop() {
    if (_evaluating) {
      return;
    }
    _evaluating = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _evaluating = false;
      if (!mounted) {
        return;
      }
      final bool scrolls = _scrolls(widget.controller) || _scrolls(widget.horizontalController);
      final bool holdsFocusable = _viewport.descendants.any((node) => node.canRequestFocus && !node.skipTraversal);
      final bool stop = scrolls && !holdsFocusable;
      if (stop != _tabStop) {
        setState(() => _tabStop = stop);
      }
    });
  }

  static bool _scrolls(ScrollController? controller) =>
      controller != null &&
      controller.hasClients &&
      controller.position.hasContentDimensions &&
      controller.position.maxScrollExtent > controller.position.minScrollExtent;

  bool get _alwaysShow => widget.alwaysShowScrollBars ?? _shellAlwaysShows;

  bool get _jumpToSpot => widget.jumpToClickedSpot ?? _shellJumps;

  /// Whether [controller] had a scrollable to move; without one the key is left to the areas around.
  bool _jump(ScrollController? controller, double delta) {
    if (controller == null || !controller.hasClients) {
      return false;
    }
    final ScrollPosition position = controller.position;
    controller.jumpTo((position.pixels + delta).clamp(position.minScrollExtent, position.maxScrollExtent));
    return true;
  }

  /// Whether [controller] had a scrollable to move, as [_jump].
  bool _jumpTo(ScrollController? controller, {required bool end}) {
    if (controller == null || !controller.hasClients) {
      return false;
    }
    final ScrollPosition position = controller.position;
    controller.jumpTo(end ? position.maxScrollExtent : position.minScrollExtent);
    return true;
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent || !_viewport.hasPrimaryFocus) {
      return KeyEventResult.ignored;
    }
    final ScrollController vertical = widget.controller;
    final ScrollController? horizontal = widget.horizontalController;
    final double page = vertical.hasClients
        ? math.max(0, vertical.position.viewportDimension - ZsScrollArea._keyStep)
        : 0;
    final LogicalKeyboardKey key = event.logicalKey;
    final bool moved = switch (key) {
      LogicalKeyboardKey.arrowDown => _jump(vertical, ZsScrollArea._keyStep),
      LogicalKeyboardKey.arrowUp => _jump(vertical, -ZsScrollArea._keyStep),
      LogicalKeyboardKey.arrowRight => _jump(horizontal, ZsScrollArea._keyStep),
      LogicalKeyboardKey.arrowLeft => _jump(horizontal, -ZsScrollArea._keyStep),
      LogicalKeyboardKey.pageDown => _jump(vertical, page),
      LogicalKeyboardKey.pageUp => _jump(vertical, -page),
      LogicalKeyboardKey.space => _jump(vertical, HardwareKeyboard.instance.isShiftPressed ? -page : page),
      LogicalKeyboardKey.home => _jumpTo(vertical, end: false),
      LogicalKeyboardKey.end => _jumpTo(vertical, end: true),
      _ => false,
    };
    return moved ? KeyEventResult.handled : KeyEventResult.ignored;
  }

  void _pointerHover(Offset local, Size size, double gutter) {
    Axis? hover;
    if (size.width - local.dx <= gutter && _scrolls(widget.controller)) {
      hover = Axis.vertical;
    } else if (size.height - local.dy <= gutter && _scrolls(widget.horizontalController)) {
      hover = Axis.horizontal;
    }
    if (hover != _hover) {
      setState(() => _hover = hover);
    }
  }

  @override
  Widget build(BuildContext context) {
    _shellAlwaysShows = ZsShellScope.alwaysShowsScrollBars(context);
    _shellJumps = ZsShellScope.jumpsToClickedSpot(context);
    _scheduleTabStop();
    final metrics = ZsMetrics.of(context);
    final ScrollController? horizontal = widget.horizontalController;
    final bool show = _alwaysShow || _scrolling || _hover != null || _drag != null;
    return NotificationListener<ScrollMetricsNotification>(
      onNotification: (_) {
        _scheduleTabStop();
        return false;
      },
      child: Semantics(
        container: true,
        identifier: widget.identifier,
        label: widget.label,
        child: Focus(
          focusNode: _viewport,
          canRequestFocus: _tabStop,
          skipTraversal: !_tabStop,
          onKeyEvent: _handleKey,
          child: ZsFocusRing(
            visible: _focused,
            placement: ZsRingPlacement.inside,
            child: Builder(
              builder: (context) => MouseRegion(
                onHover: (event) => _pointerHover(event.localPosition, context.size!, metrics.scrollGutter),
                onExit: (_) {
                  if (_hover != null) {
                    setState(() => _hover = null);
                  }
                },
                // WHY: the content is the one non-positioned child, so the area takes its size — it fills under tight
                // constraints and hugs a short scrollable under loose ones (a popover below its max height).
                child: Stack(
                  fit: StackFit.passthrough,
                  children: <Widget>[
                    // WHY: on macOS the default scroll behaviour wraps every scrollable in a `RawScrollbar` of its
                    // own, a second bar beside this one while scrolling; the area draws the only bar.
                    ScrollConfiguration(
                      behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
                      child: widget.child,
                    ),
                    Positioned(
                      top: ZsScrollArea._inset,
                      bottom: ZsScrollArea._inset,
                      right: 0,
                      width: metrics.scrollGutter,
                      child: _HitWhen(
                        active: () => _scrolls(widget.controller),
                        child: _Bar(
                          axis: Axis.vertical,
                          controller: widget.controller,
                          visible: show,
                          hovered: _hover == Axis.vertical,
                          dragging: _drag == Axis.vertical,
                          jumpToSpot: () => _jumpToSpot,
                          onDrag: (dragging) => setState(() => _drag = dragging ? Axis.vertical : null),
                        ),
                      ),
                    ),
                    if (horizontal != null)
                      Positioned(
                        left: ZsScrollArea._inset,
                        right: ZsScrollArea._inset,
                        bottom: 0,
                        height: metrics.scrollGutter,
                        child: _HitWhen(
                          active: () => _scrolls(horizontal),
                          child: _Bar(
                            axis: Axis.horizontal,
                            controller: horizontal,
                            visible: show,
                            hovered: _hover == Axis.horizontal,
                            dragging: _drag == Axis.horizontal,
                            jumpToSpot: () => _jumpToSpot,
                            onDrag: (dragging) => setState(() => _drag = dragging ? Axis.horizontal : null),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Takes the pointer only while [active] says so, asked at hit-test time: a bar whose axis does not scroll leaves
/// the content's clicks and wheel alone, as the DS renders no bar then (components/controls/ScrollArea.jsx:67,
/// :72).
class _HitWhen extends SingleChildRenderObjectWidget {
  const _HitWhen({required this.active, required super.child});

  final bool Function() active;

  @override
  _RenderHitWhen createRenderObject(BuildContext context) => _RenderHitWhen(active);

  @override
  void updateRenderObject(BuildContext context, _RenderHitWhen renderObject) => renderObject.active = active;
}

class _RenderHitWhen extends RenderProxyBox {
  _RenderHitWhen(this.active);

  bool Function() active;

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) =>
      active() && super.hitTest(result, position: position);
}

typedef _BarLook = ({double opacity, Color track, Color thumb});

_BarLook _lerpBar(_BarLook a, _BarLook b, double t) => (
  opacity: a.opacity + (b.opacity - a.opacity) * t,
  track: Color.lerp(a.track, b.track, t)!,
  thumb: Color.lerp(a.thumb, b.thumb, t)!,
);

/// One overlay bar: its gutter takes the pointer; a press on the thumb drags it, a press on the track pages or
/// jumps and then drags.
class _Bar extends StatefulWidget {
  const _Bar({
    required this.axis,
    required this.controller,
    required this.visible,
    required this.hovered,
    required this.dragging,
    required this.jumpToSpot,
    required this.onDrag,
  });

  final Axis axis;
  final ScrollController controller;
  final bool visible;
  final bool hovered;
  final bool dragging;
  final bool Function() jumpToSpot;
  final ValueChanged<bool> onDrag;

  @override
  State<_Bar> createState() => _BarState();
}

class _BarState extends State<_Bar> {
  /// The pointer's position along the axis and the scroll offset where the current drag started.
  double? _dragFrom;
  double _offsetFrom = 0;

  bool get _vertical => widget.axis == Axis.vertical;

  ScrollPosition? get _position {
    final ScrollController controller = widget.controller;
    if (!controller.hasClients) {
      return null;
    }
    final ScrollPosition position = controller.position;
    return position.hasContentDimensions && position.hasViewportDimension ? position : null;
  }

  /// The thumb's start and length along a track [track] long.
  (double, double) _thumb(ScrollPosition position, double track) {
    final double content = position.maxScrollExtent - position.minScrollExtent + position.viewportDimension;
    final double length = math.min(
      track,
      math.max(ZsScrollArea._minThumb, track * position.viewportDimension / content),
    );
    final double range = position.maxScrollExtent - position.minScrollExtent;
    final double fraction = range <= 0 ? 0 : ((position.pixels - position.minScrollExtent) / range).clamp(0, 1);
    return (fraction * (track - length), length);
  }

  double _along(Offset local) => _vertical ? local.dy : local.dx;

  double _trackLength(Size size) => _vertical ? size.height : size.width;

  void _down(PointerDownEvent event) {
    final ScrollPosition? position = _position;
    final box = context.findRenderObject() as RenderBox?;
    if (position == null ||
        box == null ||
        event.buttons & kPrimaryButton == 0 ||
        position.maxScrollExtent <= position.minScrollExtent) {
      return;
    }
    final double track = _trackLength(box.size);
    final double at = _along(event.localPosition);
    final (double start, double length) = _thumb(position, track);
    if (at < start || at > start + length) {
      final spot = widget.jumpToSpot() != HardwareKeyboard.instance.isAltPressed;
      final double range = position.maxScrollExtent - position.minScrollExtent;
      double target;
      if (spot) {
        // The thumb centred on the press.
        final double travel = track - length;
        final double fraction = travel <= 0 ? 0 : ((at - length / 2) / travel).clamp(0, 1);
        target = position.minScrollExtent + fraction * range;
      } else {
        final double page = math.max(0, position.viewportDimension - ZsScrollArea._keyStep);
        target = position.pixels + (at < start ? -page : page);
      }
      widget.controller.jumpTo(target.clamp(position.minScrollExtent, position.maxScrollExtent));
    }
    _dragFrom = at;
    _offsetFrom = widget.controller.position.pixels;
    widget.onDrag(true);
  }

  void _move(PointerMoveEvent event) {
    final double? from = _dragFrom;
    final ScrollPosition? position = _position;
    final box = context.findRenderObject() as RenderBox?;
    if (from == null || position == null || box == null) {
      return;
    }
    final double track = _trackLength(box.size);
    final (double _, double length) = _thumb(position, track);
    final double travel = track - length;
    if (travel <= 0) {
      return;
    }
    final double range = position.maxScrollExtent - position.minScrollExtent;
    final double target = _offsetFrom + (_along(event.localPosition) - from) * range / travel;
    widget.controller.jumpTo(target.clamp(position.minScrollExtent, position.maxScrollExtent));
  }

  void _up(PointerEvent event) {
    if (_dragFrom != null) {
      _dragFrom = null;
      widget.onDrag(false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ZsColors colors = ZsColors.of(context);
    final metrics = ZsMetrics.of(context);
    final ZsMotion motion = ZsMotion.of(context);
    final bool wide = widget.hovered || widget.dragging;
    final _BarLook look = (
      opacity: widget.visible ? 1 : 0,
      track: wide ? colors.scrollTrack : const Color(0x00000000),
      thumb: widget.dragging ? colors.scrollThumbDrag : (widget.hovered ? colors.scrollThumbHover : colors.scrollThumb),
    );
    return ExcludeSemantics(
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: _down,
        onPointerMove: _move,
        onPointerUp: _up,
        onPointerCancel: _up,
        child: ZsLerpBuilder<double>(
          value: wide ? metrics.scrollWHover : metrics.scrollW,
          lerp: (a, b, t) => a + (b - a) * t,
          duration: motion.durNudge,
          curve: motion.easeGlide,
          builder: (context, width, _) => ZsLerpBuilder<_BarLook>(
            value: look,
            lerp: _lerpBar,
            duration: widget.visible ? motion.durHover : motion.durExitLg,
            curve: motion.easeState,
            builder: (context, look, _) => ListenableBuilder(
              listenable: widget.controller,
              builder: (context, _) => CustomPaint(
                size: Size.infinite,
                painter: _BarPainter(
                  axis: widget.axis,
                  position: _position,
                  look: look,
                  thumbWidth: width,
                  gutter: metrics.scrollGutter,
                  radius: metrics.radiusChip,
                  thumbOf: _thumb,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _BarPainter extends CustomPainter {
  _BarPainter({
    required this.axis,
    required this.position,
    required this.look,
    required this.thumbWidth,
    required this.gutter,
    required this.radius,
    required this.thumbOf,
  });

  final Axis axis;
  final ScrollPosition? position;
  final _BarLook look;
  final double thumbWidth;
  final double gutter;
  final double radius;
  final (double, double) Function(ScrollPosition position, double track) thumbOf;

  /// The thumb's distance from the outer edge: 4 at `--scroll-w`, 2 at `--scroll-w-hover`, in step with the width
  /// (DS components/controls/controls.css:118-120).
  double get _edge => 4 - (thumbWidth - 6) / 2;

  @override
  void paint(Canvas canvas, Size size) {
    final ScrollPosition? at = position;
    if (look.opacity == 0 || at == null || at.maxScrollExtent <= at.minScrollExtent) {
      return;
    }
    final vertical = axis == Axis.vertical;
    final Rect box = Offset.zero & size;
    if (look.track.a > 0) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(box, Radius.circular(radius)),
        Paint()..color = look.track.withValues(alpha: look.track.a * look.opacity),
      );
    }
    final (double start, double length) = thumbOf(at, vertical ? size.height : size.width);
    final thumb = vertical
        ? Rect.fromLTWH(size.width - _edge - thumbWidth, start, thumbWidth, length)
        : Rect.fromLTWH(start, size.height - _edge - thumbWidth, length, thumbWidth);
    canvas.drawRRect(
      RRect.fromRectAndRadius(thumb, Radius.circular(thumbWidth / 2)),
      Paint()..color = look.thumb.withValues(alpha: look.thumb.a * look.opacity),
    );
  }

  @override
  bool shouldRepaint(_BarPainter oldDelegate) => true;
}
