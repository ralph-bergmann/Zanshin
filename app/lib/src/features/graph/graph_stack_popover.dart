// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show clampDouble;
import 'package:flutter/widgets.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

import '../../l10n/strings.dart';
import 'graph_card.dart';
import 'graph_content.dart';
import 'graph_layout.dart';
import 'graph_peek.dart';

/// A stack list row's height (Claude's proposal for the design's open point on large stacks).
const double graphStackRowHeight = 28;

/// The stack list shows at most this many rows; beyond, it scrolls.
const graphStackMaxRows = 8;

/// How long a row rests under the pointer before its member's callout opens.
const graphStackRowRest = Duration(milliseconds: 180);

// The gap between the card and the list, and the list's padding (DS ui_kits/desktop/kit.css:21-25).
const double _gap = 12;
const double _pad = 5;

/// The stack list (Story 10.17 item 2; DS ui_kits/desktop/kit.css:20-25) of the stack node [node], laid out over the
/// whole canvas: below [card] with a 12 px gap, above it when it does not fit above [area]'s bottom; clamp(card width,
/// 280, 380) wide, its x clamped into [area]; on the one menu material. Its rows, newest first, show each member's id
/// (jj's prefix bold, max(prefix, 8)), subject and relative date; then the hint "Click to expand N changes". At most
/// [graphStackMaxRows] rows show; beyond, the list scrolls and builds only the visible rows. A row resting
/// [graphStackRowRest] opens its member's [GraphPeek] beside it ([graphPeekPosition], flipping left).
///
/// Moving card → list → callout keeps the hover ([GraphCardController.holdHover]); leaving them starts the card's
/// leave. It enters with a fade on `--dur-pop` and leaves ([closing]) with a fade and a 4 px drift back toward the card
/// × `--motion` on `--dur-exit-lg` / `--ease-exit`. Not announced, as the peek.
class GraphStackPopover extends StatefulWidget {
  /// The list of [node] in [layout], at [card] (viewport coordinates) inside [area].
  const GraphStackPopover({
    required this.layout,
    required this.node,
    required this.card,
    required this.area,
    required this.controller,
    required this.closing,
    this.content,
    super.key,
  });

  /// The layout [node] belongs to.
  final GraphLayout layout;

  /// The stack node.
  final int node;

  /// The stack card's rect.
  final Rect card;

  /// The unobscured area.
  final Rect area;

  /// The graph's card controller.
  final GraphCardController controller;

  /// Whether it is leaving.
  final bool closing;

  /// The content cache; null shows the layout's own content.
  final GraphContent? content;

  @override
  State<GraphStackPopover> createState() => _GraphStackPopoverState();
}

class _GraphStackPopoverState extends State<GraphStackPopover> with SingleTickerProviderStateMixin {
  late final _motion = AnimationController(vsync: this);
  final _scroll = ScrollController();
  Timer? _rest;
  int? _callout;
  ZsMotion _tokens = ZsMotion.full;
  var _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _tokens = ZsMotion.of(context);
    _motion
      ..duration = _tokens.durPop
      ..reverseDuration = _tokens.durExitLg;
    if (!_started) {
      _started = true;
      _motion.forward();
    }
  }

  @override
  void didUpdateWidget(GraphStackPopover oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.closing != oldWidget.closing) {
      if (widget.closing) {
        _rest?.cancel();
        _motion.reverse();
      } else {
        _motion.forward();
      }
    }
  }

  @override
  void dispose() {
    _rest?.cancel();
    _motion.dispose();
    _scroll.dispose();
    super.dispose();
  }

  String get _key => widget.layout.keyOf(widget.node);

  void _rowEntered(int row) {
    _rest?.cancel();
    _rest = Timer(graphStackRowRest, () {
      if (mounted && !widget.closing) {
        setState(() => _callout = row);
      }
    });
  }

  void _rowExited() => _rest?.cancel();

  @override
  Widget build(BuildContext context) {
    final GraphLayout layout = widget.layout;
    final List<int> members = layout.runMembersOf(layout.runOf(widget.node)!);
    final GraphCardController cards = widget.controller;
    final String key = _key;
    int memberAt(int row) => members[members.length - 1 - row];
    final Widget list = MouseRegion(
      onEnter: (_) => cards.holdHover(),
      onExit: (_) => cards.leave(key),
      child: ZsMenuMaterial(
        padding: const EdgeInsets.all(_pad),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            SizedBox(
              height: math.min(members.length, graphStackMaxRows) * graphStackRowHeight,
              child: ListView.builder(
                controller: _scroll,
                padding: EdgeInsets.zero,
                itemExtent: graphStackRowHeight,
                itemCount: members.length,
                itemBuilder: (context, row) => MouseRegion(
                  key: ValueKey<String>('graph-stack-row-${layout.keyOf(memberAt(row))}'),
                  onEnter: (_) => _rowEntered(row),
                  onExit: (_) => _rowExited(),
                  child: _StackRow(
                    data: GraphCardData.of(layout, memberAt(row), content: widget.content),
                    nowMs: cards.now.value,
                  ),
                ),
              ),
            ),
            _StackHint(count: members.length),
          ],
        ),
      ),
    );
    final int? callout = _callout;
    return ExcludeSemantics(
      child: IgnorePointer(
        ignoring: widget.closing,
        child: CustomMultiChildLayout(
          delegate: _PopoverLayout(
            card: widget.card,
            area: widget.area,
            row: callout,
            scroll: _scroll,
            motion: _motion,
            closing: widget.closing,
            factor: _tokens.motion,
          ),
          children: <Widget>[
            LayoutId(
              id: _Part.list,
              child: FadeTransition(
                opacity: CurvedAnimation(
                  parent: _motion,
                  curve: _tokens.easeGlide,
                  reverseCurve: _tokens.easeExit.flipped,
                ),
                child: list,
              ),
            ),
            if (callout != null && callout < members.length)
              LayoutId(
                id: _Part.callout,
                child: FadeTransition(
                  opacity: _motion,
                  child: MouseRegion(
                    onEnter: (_) => cards.holdHover(),
                    onExit: (_) => cards.leave(key),
                    child: GraphPeek(
                      key: ValueKey<String>('graph-stack-callout-${layout.keyOf(memberAt(callout))}'),
                      data: GraphCardData.of(layout, memberAt(callout), content: widget.content),
                      nowMs: cards.now.value,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

enum _Part { list, callout }

class _PopoverLayout extends MultiChildLayoutDelegate {
  _PopoverLayout({
    required this.card,
    required this.area,
    required this.row,
    required this.scroll,
    required this.motion,
    required this.closing,
    required this.factor,
  }) : super(relayout: Listenable.merge(<Listenable>[motion, scroll]));

  final Rect card;
  final Rect area;
  final int? row;
  final ScrollController scroll;
  final Animation<double> motion;
  final bool closing;
  final double factor;

  @override
  void performLayout(Size size) {
    final double width = clampDouble(card.width, 280, 380);
    final Size list = layoutChild(_Part.list, BoxConstraints(minWidth: width, maxWidth: width, maxHeight: size.height));
    final bool below = card.bottom + _gap + list.height <= area.bottom;
    // Fitting neither side, it stays at the area's top.
    final double y = below ? card.bottom + _gap : math.max(area.top, card.top - _gap - list.height);
    final double x = clampDouble(card.left, area.left, math.max(area.left, area.right - width));
    // The drift on leaving points back at the card.
    final double drift = closing ? (below ? -4 : 4) * factor * (1 - motion.value) : 0;
    positionChild(_Part.list, Offset(x, y + drift));
    final int? row = this.row;
    if (row != null && hasChild(_Part.callout)) {
      final double offset = scroll.hasClients ? scroll.offset : 0;
      final rowRect = Rect.fromLTWH(x, y + _pad + 1 + row * graphStackRowHeight - offset, width, graphStackRowHeight);
      final Size peek = layoutChild(_Part.callout, BoxConstraints.loose(size));
      positionChild(_Part.callout, graphPeekPosition(rowRect, peek, area).topLeft);
    }
  }

  @override
  bool shouldRelayout(_PopoverLayout oldDelegate) =>
      card != oldDelegate.card ||
      area != oldDelegate.area ||
      row != oldDelegate.row ||
      closing != oldDelegate.closing ||
      factor != oldDelegate.factor;
}

/// One member row (kit.css:22-24): id, subject, relative date.
class _StackRow extends StatelessWidget {
  const _StackRow({required this.data, required this.nowMs});

  final GraphCardData data;
  final int nowMs;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations strings = context.l10n;
    final ZsColors colors = ZsColors.of(context);
    final int prefix = data.prefixLength.clamp(0, data.changeId.length);
    final int shown = math.max(prefix, 8).clamp(0, data.changeId.length);
    final GraphCommitContent? content = data.content;
    final TextStyle text = ZsType.control.copyWith(fontSize: ZsType.fsMd, color: colors.text);
    final int? ts = data.timestampMs;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        spacing: 10,
        children: <Widget>[
          Text.rich(
            TextSpan(
              style: ZsType.id.copyWith(color: colors.textFaint),
              children: <InlineSpan>[
                TextSpan(
                  text: data.changeId.substring(0, prefix),
                  style: ZsType.id.copyWith(
                    fontWeight: FontWeight.w700,
                    fontVariations: const <FontVariation>[FontVariation.weight(700)],
                    color: colors.text,
                  ),
                ),
                TextSpan(text: data.changeId.substring(prefix, shown)),
                if (data.changeOffset != null) TextSpan(text: '/${data.changeOffset}'),
              ],
            ),
          ),
          Expanded(
            child: content == null
                ? const SizedBox.shrink()
                : Text(
                    content.subject.isEmpty ? '(no description set)' : content.subject, // l10n-ignore: jj's text
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: content.subject.isEmpty
                        ? text.copyWith(fontStyle: FontStyle.italic, color: colors.textDim)
                        : text,
                  ),
          ),
          if (ts != null)
            Text(
              graphRelativeDate(strings, ts, nowMs: nowMs, utcOffsetMinutes: data.utcOffsetMinutes),
              style: ZsType.id.copyWith(fontSize: ZsType.fsSm, color: colors.textFaint),
            ),
        ],
      ),
    );
  }
}

/// The list's last line (kit.css:25).
class _StackHint extends StatelessWidget {
  const _StackHint({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final ZsColors colors = ZsColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: colors.border)),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 7, 8, 3),
          child: Text(
            context.l10n.stackExpandHint(count),
            style: ZsType.meta.copyWith(fontSize: ZsType.fsSm, color: colors.textDim),
          ),
        ),
      ),
    );
  }
}
