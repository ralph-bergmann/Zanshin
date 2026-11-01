// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

import '../../l10n/strings.dart';
import 'graph_gaps.dart';
import 'graph_layout.dart';
import 'graph_search_controller.dart';
import 'graph_view_model.dart';

/// The gap legend (Story 10.19; design/graph-gaps.jsx:195-216, graph.css:327-334) in the VIEW island after the
/// search field: a small dashed glyph and "N gaps" ("1 gap") in 11 px mono `--text-faint`, a button named "N gaps"
/// for VoiceOver; nothing while the layout has no gap. N counts one per Indirect edge (a hidden merge once) and one
/// per Missing edge.
///
/// Its popover on the one menu material opens `--delay-callout` after hover or focus and stays `--delay-callout-out`
/// after both the chip and the popover are left, fading in on `--dur-pop` and out on `--dur-exit`: the title, the
/// rows Solid / Dashed (· N×) / End (· M×), the line about stacks, and "Show `all()`" — [GraphSearchController.showAll]
/// (else the model's revset switch), which re-centres on @.
class GraphGapLegend extends StatefulWidget {
  /// The legend of [model]'s layout.
  const GraphGapLegend({required this.model, this.search, super.key});

  /// The view model.
  final GraphViewModel model;

  /// The graph search its "Show `all()`" switches.
  final GraphSearchController? search;

  @override
  State<GraphGapLegend> createState() => _GraphGapLegendState();
}

/// The legend popover's width (design/graph.css `.gtb-gaps-inner`).
const double graphGapLegendWidth = 320;

/// The gap counts per layout: computed once per layout, not per model notification.
final _counts = Expando<({int dashed, int ends})>('gap counts');

class _GraphGapLegendState extends State<GraphGapLegend> with SingleTickerProviderStateMixin {
  final _portal = OverlayPortalController();
  final _link = LayerLink();
  late final _fade = AnimationController(vsync: this)..addStatusListener(_fadeStatus);
  Timer? _timer;
  var _hovered = 0;
  var _focused = false;
  var _hover = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final ZsMotion motion = ZsMotion.of(context);
    _fade
      ..duration = motion.durPop
      ..reverseDuration = motion.durExit;
  }

  @override
  void dispose() {
    _timer?.cancel();
    _fade.dispose();
    super.dispose();
  }

  void _fadeStatus(AnimationStatus status) {
    if (status == AnimationStatus.dismissed && _portal.isShowing) {
      _portal.hide();
    }
  }

  bool get _wanted => _hovered > 0 || _focused;

  void _sync() {
    _timer?.cancel();
    final ZsMotion motion = ZsMotion.of(context);
    if (_wanted) {
      if (!_portal.isShowing || _fade.status == AnimationStatus.reverse) {
        _timer = Timer(motion.delayCallout, () {
          if (mounted && _wanted) {
            _portal.show();
            _fade.forward();
          }
        });
      }
    } else if (_portal.isShowing) {
      _timer = Timer(motion.delayCalloutOut, () {
        if (mounted && !_wanted) {
          _fade.reverse();
        }
      });
    }
  }

  void _enter() {
    _hovered++;
    _sync();
  }

  void _leave() {
    _hovered = _hovered > 0 ? _hovered - 1 : 0;
    _sync();
  }

  /// The chip's activation (VoiceOver, Enter, Space): opens the popover at once, or closes an open one.
  void _activate() {
    _timer?.cancel();
    _timer = null;
    if (_portal.isShowing && _fade.status != AnimationStatus.reverse) {
      _fade.reverse();
    } else {
      _portal.show();
      _fade.forward();
    }
  }

  /// The layout lost its gaps: nothing may open or stay open (the chip and its regions are gone).
  void _reset() {
    _timer?.cancel();
    _timer = null;
    _hovered = 0;
    _hover = false;
    // The chip's Focus is unmounted with it and reports no focus loss.
    _focused = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _portal.isShowing) {
        _fade.value = 0;
        _portal.hide();
      }
    });
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent &&
        (event.logicalKey == LogicalKeyboardKey.enter ||
            event.logicalKey == LogicalKeyboardKey.numpadEnter ||
            event.logicalKey == LogicalKeyboardKey.space)) {
      _activate();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// The popover's shift left of the chip's left edge that keeps it 8 inside the window's right edge, like View
  /// options (the left and bottom edges cannot be reached: the chip is not built at or below 1040 px).
  double _shift(BuildContext overlay) {
    final RenderObject? chip = context.findRenderObject();
    if (chip is! RenderBox || !chip.hasSize) {
      return 0;
    }
    final double right = chip.localToGlobal(Offset.zero).dx + graphGapLegendWidth;
    return math.min(0, MediaQuery.sizeOf(overlay).width - 8 - right);
  }

  void _showAll() {
    _timer?.cancel();
    // The popover goes at once; the pointer left it with it.
    _hovered = 0;
    _fade.reverse(from: 0);
    final GraphSearchController? search = widget.search;
    if (search != null) {
      search.showAll();
    } else {
      widget.model.setRevset('all()'); // l10n-ignore: jj revset
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.model,
    builder: (context, _) {
      final GraphLayout? layout = widget.model.layout;
      final ({int dashed, int ends}) counts = layout == null
          ? (dashed: 0, ends: 0)
          : (_counts[layout] ??= graphGapCounts(layout));
      final int n = counts.dashed + counts.ends;
      if (n == 0) {
        if (_timer != null || _portal.isShowing || _hovered > 0 || _focused) {
          _reset();
        }
        return const SizedBox.shrink();
      }
      final ZsColors colors = ZsColors.of(context);
      final String label = context.l10n.gapCount(n);
      final Color ink = _hover || _focused ? colors.textMuted : colors.textFaint;
      return OverlayPortal(
        controller: _portal,
        overlayChildBuilder: (overlay) => Positioned(
          left: 0,
          top: 0,
          child: CompositedTransformFollower(
            link: _link,
            targetAnchor: Alignment.bottomLeft,
            offset: Offset(_shift(overlay), 6),
            child: MouseRegion(
              onEnter: (_) => _enter(),
              onExit: (_) => _leave(),
              child: FadeTransition(
                opacity: _fade,
                child: _LegendPopover(counts: counts, onShowAll: _showAll),
              ),
            ),
          ),
        ),
        child: CompositedTransformTarget(
          link: _link,
          child: Focus(
            onKeyEvent: _onKey,
            onFocusChange: (focused) {
              setState(() => _focused = focused);
              _sync();
            },
            child: MouseRegion(
              onEnter: (_) {
                setState(() => _hover = true);
                _enter();
              },
              onExit: (_) {
                setState(() => _hover = false);
                _leave();
              },
              child: Semantics(
                button: true,
                label: label,
                identifier: 'graph-gap-legend',
                onTap: _activate,
                excludeSemantics: true,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(7, 0, 9, 0),
                  child: SizedBox(
                    height: 28,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      spacing: 6,
                      children: <Widget>[
                        CustomPaint(
                          size: const Size(12, 18),
                          painter: _LegendGlyph(_LegendKind.dashed, line: colors.edge, cut: ink),
                        ),
                        Text(
                          label,
                          style: ZsType.code.copyWith(fontSize: ZsType.fsSm, height: 1, color: ink),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}

class _LegendPopover extends StatelessWidget {
  const _LegendPopover({required this.counts, required this.onShowAll});

  final ({int dashed, int ends}) counts;
  final VoidCallback onShowAll;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations strings = context.l10n;
    final ZsColors colors = ZsColors.of(context);
    final TextStyle text = ZsType.meta.copyWith(fontSize: ZsType.fsMd, color: colors.textDim);
    final TextStyle name = text.copyWith(
      color: colors.text,
      fontWeight: FontWeight.w500,
      fontVariations: const <FontVariation>[FontVariation.weight(500)],
    );
    Widget row(_LegendKind kind, String title, String what, int? times) => Row(
      spacing: 10,
      children: <Widget>[
        CustomPaint(
          size: const Size(22, 22),
          painter: _LegendGlyph(kind, line: colors.edge, cut: colors.textFaint),
        ),
        Expanded(
          child: Text.rich(
            TextSpan(
              style: text,
              children: <InlineSpan>[
                TextSpan(text: title, style: name),
                TextSpan(text: ' — $what'), // l10n-ignore: a separator
                if (times != null && times > 0)
                  TextSpan(
                    text: ' · ${strings.gapLegendTimes(times)}', // l10n-ignore: a separator
                    style: text.copyWith(fontSize: ZsType.fsSm),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
    return SizedBox(
      width: graphGapLegendWidth,
      child: ZsMenuMaterial(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 8,
          children: <Widget>[
            Text(
              strings.gapLegendTitle,
              style: ZsType.cardSubject.copyWith(
                fontSize: ZsType.fsBase,
                fontWeight: FontWeight.w600,
                fontVariations: const <FontVariation>[FontVariation.weight(600)],
                color: colors.text,
              ),
            ),
            row(_LegendKind.solid, strings.gapLegendSolid, strings.gapLegendSolidText, null),
            row(_LegendKind.dashed, strings.gapLegendDashed, strings.gapLegendDashedText, counts.dashed),
            row(_LegendKind.end, strings.gapLegendEnd, strings.gapLegendEndText, counts.ends),
            Text(strings.gapLegendNote, style: text),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: ZsButton(
                label: strings.gapLegendShow('all()'), // l10n-ignore: jj revset
                onPressed: onShowAll,
                identifier: 'graph-gap-legend-show-all',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

enum _LegendKind { solid, dashed, end }

/// The legend's glyphs (design/graph-gaps.jsx:131-142), scaled to their box: a solid line; a dashed line with the
/// `//`; an end stub.
class _LegendGlyph extends CustomPainter {
  _LegendGlyph(this.kind, {required this.line, required this.cut});

  final _LegendKind kind;
  final Color line;
  final Color cut;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = line;
    final double x = size.width / 2;
    final double h = size.height;
    switch (kind) {
      case _LegendKind.solid:
        canvas.drawLine(Offset(x, 1), Offset(x, h - 1), paint);
      case _LegendKind.dashed:
        for (var y = 1.0; y < h / 2 - 5; y += 8) {
          canvas.drawLine(Offset(x, y), Offset(x, y + 3), paint);
        }
        for (double y = h / 2 + 5; y < h - 1; y += 8) {
          canvas.drawLine(Offset(x, y), Offset(x, y + 3), paint);
        }
        graphPaintGapCuts(canvas, Offset(x, h / 2), cut);
      case _LegendKind.end:
        canvas
          ..drawLine(Offset(x, 2), Offset(x, 5), paint)
          ..drawLine(Offset(x, 10), Offset(x, 11), paint);
        graphPaintGapCuts(canvas, Offset(x, 15), cut);
    }
  }

  @override
  bool shouldRepaint(_LegendGlyph oldDelegate) =>
      kind != oldDelegate.kind || line != oldDelegate.line || cut != oldDelegate.cut;
}
