// SPDX-License-Identifier: MIT

import 'package:flutter/rendering.dart' show SemanticsProperties;
import 'package:flutter/widgets.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

import '../../l10n/strings.dart';
import 'graph_view_model.dart';

/// The "@ Working copy" locator (Story 10.6 item 6; DS components/actions/AtPill.*, actions.css:47-54): a 36 px
/// (`--control-lg`) glass pill with the `--at-chrome-edge` border, padding 0 12 0 9, gap 8 — the @ badge, "Working
/// copy" in `--type-control` and `ZI.arrowUp` in `--text-dim`, turned toward @ on `--dur-toggle` / glide (× `--motion`).
/// A click, ↩ or Space runs [onPressed]; its tooltip names ⇧⌘J; VoiceOver reads "Working copy, below" (or above, left,
/// right).
class AtPill extends StatelessWidget {
  /// A pill pointing [direction].
  const AtPill({required this.direction, required this.onPressed, super.key});

  /// Where @ lies.
  final GraphDirection direction;

  /// Scrolls to @.
  final VoidCallback onPressed;

  static double _turns(GraphDirection direction) => switch (direction) {
    GraphDirection.up => 0,
    GraphDirection.right => .25,
    GraphDirection.down => .5,
    GraphDirection.left => .75,
  };

  @override
  Widget build(BuildContext context) {
    final AppLocalizations strings = context.l10n;
    final metrics = ZsMetrics.of(context);
    return ZsTooltip(
      message: strings.atPillTooltip,
      shortcut: '⇧⌘J',
      placement: ZsTooltipPlacement.above,
      child: ZsControlCore(
        identifier: 'graph.at-pill',
        onActivate: onPressed,
        semantics: SemanticsProperties(button: true, label: strings.atPillSemantics(direction.name)),
        ring: ZsRingPlacement.outside,
        ringRadius: metrics.controlLg / 2,
        builder: (context, status) => _paint(context, status, metrics, strings),
      ),
    );
  }

  Widget _paint(BuildContext context, ZsControlStatus status, ZsMetrics metrics, AppLocalizations strings) {
    final ZsColors colors = ZsColors.of(context);
    final ZsElevation elevation = ZsElevation.of(context);
    final ZsMotion motion = ZsMotion.of(context);
    final GraphTheme graph = GraphTheme.of(context);
    final Color fill = status.pressed
        ? Color.alphaBlend(colors.flOn, colors.flBg)
        : status.hovered
        ? Color.alphaBlend(colors.flHover, colors.flBg)
        : colors.flBg;
    return SizedBox(
      height: metrics.controlLg,
      child: ZsSurface(
        fill: fill,
        sheen: colors.flSheen,
        border: colors.atChromeEdge,
        shadow: elevation.flShadow,
        filter: elevation.glassBlur,
        radius: metrics.radiusPill,
        padding: const EdgeInsets.only(left: 9, right: 12),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          spacing: 8,
          children: <Widget>[
            Container(
              height: 16,
              padding: const EdgeInsets.symmetric(horizontal: 5),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: graph.atBadgeFill,
                borderRadius: BorderRadius.circular(metrics.radiusXs),
              ),
              child: Text(
                '@',
                style: ZsType.id.copyWith(
                  fontSize: ZsType.fsSm,
                  height: 1,
                  fontWeight: FontWeight.w700,
                  fontVariations: const <FontVariation>[FontVariation.weight(700)],
                  color: graph.atBadgeText,
                ),
              ),
            ),
            Text(strings.atPillLabel, style: ZsType.control.copyWith(color: colors.text)),
            AnimatedRotation(
              turns: _turns(direction),
              duration: motion.motion == 0 ? Duration.zero : motion.durToggle,
              curve: motion.easeGlide,
              child: ZanshinIcon(ZI.arrowUp, size: ZsIconSize.md, color: colors.textDim),
            ),
          ],
        ),
      ),
    );
  }
}

/// The shell's `atPill` slot for [model] (`GraphView.atPill`): an [AtPill] while [GraphViewModel.workingCopyDirection]
/// is set — in with a fade and a 10 px rise (× `--motion`) on `--dur-slide` / glide, out with a fade on `--dur-exit`,
/// keeping its last direction — that reveals @ and leaves the selection alone. While leaving it is no Tab stop.
class GraphAtPill extends StatefulWidget {
  /// The pill of [model].
  const GraphAtPill({required this.model, super.key});

  /// The graph's view model.
  final GraphViewModel model;

  @override
  State<GraphAtPill> createState() => _GraphAtPillState();
}

class _GraphAtPillState extends State<GraphAtPill> {
  // The pill keeps its last direction while it fades out.
  late GraphDirection _last;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<GraphDirection?>(
    valueListenable: widget.model.workingCopyDirection,
    builder: (context, direction, _) {
      if (direction != null) {
        _last = direction;
      }
      return ZsPresence(
        open: direction != null,
        exit: ZsMotion.of(context).durExit,
        builder: (context, closing) => _PillMotion(
          closing: closing,
          child: ExcludeFocus(
            excluding: closing,
            child: AtPill(direction: _last, onPressed: widget.model.scrollToWorkingCopy),
          ),
        ),
      );
    },
  );
}

class _PillMotion extends StatefulWidget {
  const _PillMotion({required this.closing, required this.child});

  final bool closing;
  final Widget child;

  @override
  State<_PillMotion> createState() => _PillMotionState();
}

class _PillMotionState extends State<_PillMotion> with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(vsync: this);
  var _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final ZsMotion motion = ZsMotion.of(context);
    _controller
      ..duration = motion.durSlide
      ..reverseDuration = motion.durExit;
    if (!_started) {
      _started = true;
      _controller.forward();
    }
  }

  @override
  void didUpdateWidget(_PillMotion oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.closing != oldWidget.closing) {
      if (widget.closing) {
        _controller.reverse();
      } else {
        _controller.forward();
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ZsMotion motion = ZsMotion.of(context);
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final double v = _controller.value;
        final double eased = widget.closing ? motion.easeExit.flipped.transform(v) : motion.easeGlide.transform(v);
        return Transform.translate(
          offset: Offset(0, widget.closing ? 0 : 10 * motion.motion * (1 - eased)),
          child: ZsFade(opacity: eased.clamp(0, 1), child: child!),
        );
      },
      child: widget.child,
    );
  }
}
