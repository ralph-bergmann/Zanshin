// SPDX-License-Identifier: MIT

import 'dart:math' as math;

import 'package:flutter/foundation.dart' show clampDouble;
import 'package:flutter/widgets.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

import '../../l10n/strings.dart';
import 'graph_drag.dart';

/// The drop menu's width (DS components/menus/menus.css:6, the menu's 250–320; the commands carry two short ids).
const double graphDropMenuWidth = 320;

/// The gap between the menu and its card (Story 10.10).
const double graphDropMenuGap = 12;

const double _pad = 5;
const double _rowH = 28;
const double _rowGap = 1;
const double _sepH = 9;
const double _footerH = 30;

/// The drop menu's geometry for [rows] (Story 10.10): its size, each row's rect and the footer's, top-down; [above]
/// runs the list bottom-up (the default row nearest the card below it) with the footer on top.
({Size size, List<Rect> rows, Rect footer}) graphDropMenuGeometry(List<GraphDropRow> rows, {required bool above}) {
  const double inner = graphDropMenuWidth - 2 * _pad;
  // Top-down in list order: each row's height and whether a hairline comes before it.
  final order = List<int>.generate(rows.length, (k) => above ? rows.length - 1 - k : k);
  final rects = List<Rect>.filled(rows.length, Rect.zero);
  double y = _pad;
  Rect footer = Rect.zero;
  if (above) {
    footer = Rect.fromLTWH(_pad, y, inner, _footerH);
    y += _footerH;
  }
  for (var k = 0; k < order.length; k++) {
    final int i = order[k];
    if (k > 0 && rows[order[k - 1]].group != rows[i].group) {
      y += _sepH;
    } else if (k > 0) {
      y += _rowGap;
    }
    rects[i] = Rect.fromLTWH(_pad, y, inner, _rowH);
    y += _rowH;
  }
  if (!above) {
    footer = Rect.fromLTWH(_pad, y, inner, _footerH);
    y += _footerH;
  }
  return (size: Size(graphDropMenuWidth, y + _pad), rows: rects, footer: footer);
}

/// Where the drop menu goes for [card] (viewport coordinates) inside [area] (the unobscured part): 12 px above the
/// card when it fits under the area's top, else 12 px below (its top clamped so it stays inside the area's bottom, never
/// above its top); centred on the card and clamped into the area.
({Offset topLeft, bool above}) graphDropMenuPlacement(Rect card, Size menu, Rect area) {
  final bool above = card.top - graphDropMenuGap - menu.height >= area.top;
  final double below = card.bottom + graphDropMenuGap;
  final double top = above
      ? card.top - graphDropMenuGap - menu.height
      : clampDouble(below, area.top, math.max(area.top, area.bottom - menu.height));
  final double maxLeft = math.max(area.left, area.right - menu.width);
  final double left = clampDouble(card.center.dx - menu.width / 2, area.left, maxLeft);
  return (topLeft: Offset(left, top), above: above);
}

/// The drop menu (Story 10.10; DS components/menus/DropMenu.prompt.md): on the menu material, each row its glyph, its
/// label and its short verb in mono, hairlines between groups, the highlighted row's full command in the footer. The
/// highlight is solid `--accent` with `--accent-ink`. The pointer is the drag's, so the canvas highlights by geometry.
/// It fades in (its scale × `--motion`).
class GraphDropMenu extends StatefulWidget {
  /// A menu of [rows].
  const GraphDropMenu({
    required this.rows,
    required this.highlight,
    required this.above,
    super.key,
  });

  /// The Available rows.
  final List<GraphDropRow> rows;

  /// The highlighted row.
  final int highlight;

  /// Whether it opens above the card (the list runs bottom-up).
  final bool above;

  @override
  State<GraphDropMenu> createState() => _GraphDropMenuState();
}

class _GraphDropMenuState extends State<GraphDropMenu> with SingleTickerProviderStateMixin {
  late final _fade = AnimationController(vsync: this);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final ZsMotion motion = ZsMotion.of(context);
    _fade.duration = motion.durMenu;
    if (!_fade.isAnimating && _fade.value == 0) {
      _fade.forward();
    }
  }

  @override
  void dispose() {
    _fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations strings = context.l10n;
    final ZsColors colors = ZsColors.of(context);
    final ZsMotion motion = ZsMotion.of(context);
    final metrics = ZsMetrics.of(context);
    final List<GraphDropRow> rows = widget.rows;
    final ({Size size, List<Rect> rows, Rect footer}) geometry = graphDropMenuGeometry(rows, above: widget.above);
    final int hi = widget.highlight.clamp(0, math.max(0, rows.length - 1));
    final children = <Widget>[];
    for (var i = 0; i < rows.length; i++) {
      final GraphDropRow row = rows[i];
      final on = i == hi;
      final Color ink = on ? colors.accentInk : colors.text;
      final Color side = on ? colors.accentInk : colors.textDim;
      final Widget cell = DecoratedBox(
        decoration: BoxDecoration(
          color: on ? colors.accent : const Color(0x00000000),
          borderRadius: BorderRadius.circular(metrics.radiusMd),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            spacing: 10,
            children: <Widget>[
              ZanshinIcon(row.glyph, size: ZsIconSize.md, color: on ? colors.accentInk : colors.textMuted),
              Expanded(
                child: Text(
                  row.label(strings),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ZsType.control.copyWith(color: ink),
                ),
              ),
              Text(
                row.short,
                style: ZsType.id.copyWith(fontSize: ZsType.fsSm, color: side),
              ),
            ],
          ),
        ),
      );
      children.add(
        Positioned.fromRect(
          rect: geometry.rows[i],
          child: Semantics(
            identifier: 'graph-drop-${row.kind.name}',
            selected: on,
            button: true,
            label: row.label(strings),
            hint: row.command,
            child: cell,
          ),
        ),
      );
    }
    final GraphDropRow? shown = rows.isEmpty ? null : rows[hi];
    final Rect footer = geometry.footer;
    children.add(
      Positioned.fromRect(
        rect: footer,
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: widget.above
                ? Border(bottom: BorderSide(color: colors.border))
                : Border(top: BorderSide(color: colors.border)),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                shown?.command ?? '',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: ZsType.id.copyWith(fontSize: ZsType.fsSm, color: colors.textMuted),
              ),
            ),
          ),
        ),
      ),
    );
    return Semantics(
      identifier: 'graph-drop-menu',
      label: strings.dropMenuLabel,
      liveRegion: true,
      container: true,
      child: AnimatedBuilder(
        animation: _fade,
        builder: (context, child) {
          final double t = motion.easeState.transform(_fade.value);
          return Opacity(
            opacity: t,
            child: Transform.scale(
              scale: 1 - .04 * motion.motion * (1 - t),
              alignment: widget.above ? Alignment.bottomCenter : Alignment.topCenter,
              child: child,
            ),
          );
        },
        child: SizedBox.fromSize(
          size: geometry.size,
          child: ZsMenuMaterial(child: Stack(children: children)),
        ),
      ),
    );
  }
}
