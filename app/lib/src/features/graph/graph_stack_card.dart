// SPDX-License-Identifier: MIT

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

import '../../l10n/strings.dart';
import 'graph_card.dart';
import 'graph_card_render.dart' show graphDragThreshold;
import 'graph_content.dart';
import 'graph_layout.dart';
import 'graph_viewport_render.dart' show graphCardOverhang;
import 'hatch_swatch.dart';

/// What one stack card shows (Story 10.17), read from its run's members once per build.
@immutable
class GraphStackData {
  /// The facts, given; the app uses [GraphStackData.of].
  const GraphStackData({
    required this.key,
    required this.count,
    required this.newest,
    required this.oldest,
    this.authors,
    this.utcOffsetMinutes = 0,
    this.conflict = false,
    this.immutable = false,
  });

  /// The facts of the stack node [node] in [layout]: its members' through [content] (else the layout's own).
  factory GraphStackData.of(GraphLayout layout, int node, {GraphContent? content}) {
    final List<int> members = layout.runMembersOf(layout.runOf(node)!);
    GraphCardData card(int member) => GraphCardData.of(layout, member, content: content);
    final GraphCardData newest = card(members.last);
    final GraphCardData oldest = card(members.first);
    final names = <String>{};
    var conflict = false;
    for (final int member in members.reversed) {
      final GraphCardData data = member == members.last
          ? newest
          : member == members.first
          ? oldest
          : card(member);
      if (data.author case final String name) {
        names.add(name);
      }
      conflict = conflict || (data.content?.conflict ?? false);
    }
    return GraphStackData(
      key: layout.keyOf(node),
      count: members.length,
      newest: newest,
      oldest: oldest,
      authors: names.isEmpty ? null : names.join(', '),
      utcOffsetMinutes: layout.utcOffsetMinutes,
      conflict: conflict,
      immutable: layout.isImmutable(node),
    );
  }

  /// The stack node's key.
  final String key;

  /// The number of members.
  final int count;

  /// The newest member's facts: the subject, the range's first id, the newest date.
  final GraphCardData newest;

  /// The oldest member's facts: the range's last id, the oldest date.
  final GraphCardData oldest;

  /// The members' distinct author first names, newest first, joined by ", "; null when none is known.
  final String? authors;

  /// The layout's fixed UTC offset, in minutes.
  final int utcOffsetMinutes;

  /// Whether any member has a conflict.
  final bool conflict;

  /// Whether every member is immutable.
  final bool immutable;

  /// The id range as the card shows it: newest‥oldest, each id max(prefix, 5) long.
  String get range => '${_id(newest)}‥${_id(oldest)}';

  static String _id(GraphCardData data) {
    final (:String prefix, :String rest, :String offset) = data.idParts(detailed: false);
    return '$prefix$rest$offset';
  }

  /// The date range in [strings] against [nowMs]: oldest – newest, one date when both read the same; null without
  /// timestamps.
  String? dates(AppLocalizations strings, int nowMs) {
    String? at(GraphCardData data) => data.timestampMs == null
        ? null
        : graphRelativeDate(strings, data.timestampMs!, nowMs: nowMs, utcOffsetMinutes: utcOffsetMinutes);
    final String? from = at(oldest);
    final String? to = at(newest);
    if (from == null || to == null || from == to) {
      return to ?? from;
    }
    return '$from – $to'; // l10n-ignore: a range of two dates
  }
}

/// One stack card (Story 10.17; DS components/graph/StackCard.*, graph.css:27-31): a collapsed linear run, drawn by one
/// leaf [RenderGraphStackCard] in the box the viewport gives every card. A primary click expands it through
/// [GraphCardController.onExpandStack]; it has no selection, double-click, bookmark control, ••• or menu, and it is
/// neither a drag source nor a drop target. It rebuilds when a member's content arrives.
class GraphStackCard extends StatefulWidget {
  /// The card of the stack node [node] in [layout].
  const GraphStackCard({required this.layout, required this.node, required this.controller, this.content, super.key});

  /// The layout [node] belongs to.
  final GraphLayout layout;

  /// The stack node shown.
  final int node;

  /// The graph's card controller.
  final GraphCardController controller;

  /// The content cache; null shows the layout's own content.
  final GraphContent? content;

  @override
  State<GraphStackCard> createState() => _GraphStackCardState();
}

class _GraphStackCardState extends State<GraphStackCard> {
  @override
  void initState() {
    super.initState();
    widget.content?.addListener(_contentChanged);
  }

  @override
  void didUpdateWidget(GraphStackCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.content, widget.content)) {
      oldWidget.content?.removeListener(_contentChanged);
      widget.content?.addListener(_contentChanged);
    }
  }

  @override
  void dispose() {
    widget.content?.removeListener(_contentChanged);
    super.dispose();
  }

  void _contentChanged() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final ZsColors colors = ZsColors.of(context);
    return _GraphStackLeaf(
      data: GraphStackData.of(widget.layout, widget.node, content: widget.content),
      theme: GraphTheme.of(context),
      badgeFill: colors.bgCard2,
      metrics: ZsMetrics.of(context),
      inactive: ZsAppearance.maybeOf(context)?.inactive ?? false,
      conflictIcon: IconRegistryScope.maybeOf(context)?[ZI.conflict]?.picture,
      strings: context.l10n,
      controller: widget.controller,
    );
  }
}

class _GraphStackLeaf extends LeafRenderObjectWidget {
  const _GraphStackLeaf({
    required this.data,
    required this.theme,
    required this.badgeFill,
    required this.metrics,
    required this.inactive,
    required this.conflictIcon,
    required this.strings,
    required this.controller,
  });

  final GraphStackData data;
  final GraphTheme theme;
  final Color badgeFill;
  final ZsMetrics metrics;
  final bool inactive;
  final ui.Picture? conflictIcon;
  final AppLocalizations strings;
  final GraphCardController controller;

  @override
  RenderGraphStackCard createRenderObject(BuildContext context) => RenderGraphStackCard(
    data: data,
    theme: theme,
    badgeFill: badgeFill,
    metrics: metrics,
    inactive: inactive,
    conflictIcon: conflictIcon,
    strings: strings,
    controller: controller,
  );

  @override
  void updateRenderObject(BuildContext context, RenderGraphStackCard renderObject) => renderObject
    ..data = data
    ..theme = theme
    ..badgeFill = badgeFill
    ..metrics = metrics
    ..inactive = inactive
    ..conflictIcon = conflictIcon
    ..strings = strings
    ..controller = controller;
}

// The geometry (DS components/graph/graph.css:9, :15, :27-29).
const double _lineGap = 5;
const double _metaGap = 8;
const double _gap = 7;
const double _badgeH = 18;
const double _badgePadX = 5;
const double _icon = 12;
const double _hatchPeriod = 6;

/// A laid-out part of a stack card, for the witnesses ([RenderGraphStackCard.debugSlots]).
enum GraphStackSlot {
  /// The count badge.
  badge,

  /// The newest member's subject.
  subject,

  /// The id range.
  range,

  /// The members' authors.
  authors,

  /// The date range.
  dates,

  /// The conflict flag.
  conflict,
}

/// The render box of a [GraphStackCard]: the two offset layers (graph.css:27-28), fill, hatch, border, the count badge,
/// the texts and the focus ring; hover through [GraphCardController.enter] / [GraphCardController.leave], a click
/// within [graphDragThreshold] expands. Semantics: one button, `N changes, <subject>, <range>`, tap and expand expand.
class RenderGraphStackCard extends RenderBox implements MouseTrackerAnnotation {
  /// Creates the render box.
  RenderGraphStackCard({
    required this._data,
    required this._theme,
    required this._badgeFill,
    required this._metrics,
    required this._inactive,
    required this._conflictIcon,
    required this._strings,
    required this._controller,
  });

  late final _tap = TapGestureRecognizer(
    debugOwner: this,
    preAcceptSlopTolerance: graphDragThreshold,
    postAcceptSlopTolerance: graphDragThreshold,
  )..onTap = _expand;

  /// The facts shown.
  GraphStackData get data => _data;
  GraphStackData _data;
  set data(GraphStackData value) {
    if (identical(value, _data)) {
      return;
    }
    _data = value;
    _sync();
    markNeedsLayout();
    markNeedsSemanticsUpdate();
  }

  /// The colours.
  GraphTheme get theme => _theme;
  GraphTheme _theme;
  set theme(GraphTheme value) {
    if (value != _theme) {
      _theme = value;
      markNeedsLayout();
    }
  }

  /// The badge's fill (`--bg-card-2`).
  Color get badgeFill => _badgeFill;
  Color _badgeFill;
  set badgeFill(Color value) {
    if (value != _badgeFill) {
      _badgeFill = value;
      markNeedsPaint();
    }
  }

  /// The geometry tokens.
  ZsMetrics get metrics => _metrics;
  ZsMetrics _metrics;
  set metrics(ZsMetrics value) {
    if (value != _metrics) {
      _metrics = value;
      markNeedsLayout();
    }
  }

  /// Whether the window is not key: no hover look, no focus ring.
  bool get inactive => _inactive;
  bool _inactive;
  set inactive(bool value) {
    if (value != _inactive) {
      _inactive = value;
      markNeedsPaint();
    }
  }

  /// The conflict glyph.
  ui.Picture? get conflictIcon => _conflictIcon;
  ui.Picture? _conflictIcon;
  set conflictIcon(ui.Picture? value) {
    if (!identical(value, _conflictIcon)) {
      _conflictIcon = value;
      markNeedsPaint();
    }
  }

  /// The words.
  AppLocalizations get strings => _strings;
  AppLocalizations _strings;
  set strings(AppLocalizations value) {
    if (!identical(value, _strings)) {
      _strings = value;
      markNeedsLayout();
      markNeedsSemanticsUpdate();
    }
  }

  /// The graph's card controller.
  GraphCardController get controller => _controller;
  GraphCardController _controller;
  set controller(GraphCardController value) {
    if (identical(value, _controller)) {
      return;
    }
    if (attached) {
      _unlisten();
    }
    _controller = value;
    if (attached) {
      _listen();
    }
    _sync();
    markNeedsLayout();
  }

  var _hovered = false;
  var _focused = false;

  bool get _hoverShown => _hovered && !_inactive;

  void _sync() {
    _hovered = _controller.hovered.value == _data.key;
    _focused = _controller.focused.value == _data.key;
  }

  void _onState() {
    final bool hovered = _hovered;
    final bool focused = _focused;
    _sync();
    if (hovered != _hovered || focused != _focused) {
      markNeedsPaint();
    }
  }

  void _onHighlightMode(FocusHighlightMode mode) {
    if (_focused) {
      markNeedsPaint();
    }
  }

  void _listen() {
    _controller.hovered.addListener(_onState);
    _controller.focused.addListener(_onState);
    _controller.now.addListener(markNeedsLayout);
  }

  void _unlisten() {
    _controller.hovered.removeListener(_onState);
    _controller.focused.removeListener(_onState);
    _controller.now.removeListener(markNeedsLayout);
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _sync();
    _listen();
    FocusManager.instance.addHighlightModeListener(_onHighlightMode);
  }

  @override
  void detach() {
    // As a card: a detached box gets no onExit, so its hover is given back after this frame.
    final GraphCardController controller = _controller;
    final String key = _data.key;
    if (controller.hovered.value == key) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (!controller.isDisposed && controller.hovered.value == key && !attached) {
          controller.hovered.value = null;
        }
      });
    }
    _unlisten();
    FocusManager.instance.removeHighlightModeListener(_onHighlightMode);
    super.detach();
  }

  @override
  void dispose() {
    _tap.dispose();
    _disposeTexts();
    super.dispose();
  }

  // ---- layout ----

  Rect _card = Rect.zero;
  var _detailed = true;
  final _texts = <TextPainter>[];
  final _slots = <(GraphStackSlot, Rect, TextPainter?)>[];

  /// The laid-out slots in local coordinates, for the witnesses.
  @visibleForTesting
  List<({GraphStackSlot kind, Rect rect, String? text})> get debugSlots =>
      <({GraphStackSlot kind, Rect rect, String? text})>[
        for (final (GraphStackSlot kind, Rect rect, TextPainter? text) in _slots)
          (kind: kind, rect: rect, text: text?.plainText),
      ];

  /// The card rect in local coordinates.
  Rect get cardRect => _card;

  void _disposeTexts() {
    for (final TextPainter text in _texts) {
      text.dispose();
    }
    _texts.clear();
  }

  TextPainter _paragraph(InlineSpan span) {
    final text = TextPainter(text: span, textDirection: TextDirection.ltr, maxLines: 1, ellipsis: '…')..layout();
    _texts.add(text);
    return text;
  }

  static TextStyle _weight(TextStyle style, FontWeight weight) => style.copyWith(
    fontWeight: weight,
    fontVariations: <FontVariation>[FontVariation.weight(weight.value.toDouble())],
  );

  @override
  bool get sizedByParent => true;

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.biggest;

  @override
  void performLayout() {
    _disposeTexts();
    _slots.clear();
    const double o = graphCardOverhang;
    _card = Rect.fromLTWH(o, o, math.max(0, size.width - 2 * o), math.max(0, size.height - 2 * o));
    _detailed = _card.height >= _metrics.cardHDetailed;
    final GraphTheme t = _theme;
    final GraphStackData d = _data;
    final double avail = math.max(0, _card.width - 2 * _metrics.cardPadX);

    final TextPainter badge = _paragraph(
      TextSpan(
        text: '${d.count}',
        style: _weight(ZsType.id, FontWeight.w600).copyWith(fontSize: ZsType.fsXs, height: 1, color: t.cardText),
      ),
    );
    final double badgeW = math.max(_badgeH, badge.width + 2 * _badgePadX);
    final GraphCommitContent? newest = d.newest.content;
    final TextPainter subject = newest != null && newest.subject.isEmpty
        ? _paragraph(
            TextSpan(
              text: '(no description set)', // l10n-ignore: jj's text
              style: _weight(ZsType.cardSubject, FontWeight.w400).copyWith(
                fontStyle: FontStyle.italic,
                color: d.immutable ? t.cardTextMuted : t.cardTextDim,
              ),
            ),
          )
        : _paragraph(
            TextSpan(
              text: newest?.subject ?? '',
              style: ZsType.cardSubject.copyWith(color: d.immutable ? t.cardTextMuted : t.cardText),
            ),
          );
    InlineSpan id(GraphCardData member) {
      final (:String prefix, :String rest, :String offset) = member.idParts(detailed: false);
      return TextSpan(
        children: <InlineSpan>[
          TextSpan(
            text: prefix,
            style: _weight(ZsType.id, FontWeight.w700).copyWith(color: t.cardText),
          ),
          TextSpan(text: '$rest$offset'),
        ],
      );
    }

    // One paragraph: newest‥oldest, the separator faint (graph.css:31); its 1 px padding rides on the letter spacing.
    final TextPainter range = _paragraph(
      TextSpan(
        style: ZsType.id.copyWith(color: t.cardTextFaint),
        children: <InlineSpan>[
          id(d.newest),
          TextSpan(text: '‥', style: ZsType.id.copyWith(letterSpacing: 2)), // l10n-ignore: a range separator
          id(d.oldest),
        ],
      ),
    );
    final TextStyle meta = ZsType.meta.copyWith(color: t.cardTextDim);
    final String? authorsText = _detailed ? d.authors : null;
    final String? datesText = _detailed ? d.dates(_strings, _controller.now.value) : null;
    final TextPainter? authors = authorsText == null ? null : _paragraph(TextSpan(text: authorsText, style: meta));
    final TextPainter? dates = datesText == null ? null : _paragraph(TextSpan(text: datesText, style: meta));
    final bool conflict = d.conflict;

    double x0 = _card.left + _metrics.cardPadX;
    void place(GraphStackSlot kind, double width, double centreY, TextPainter? text, {double height = 0}) {
      final double h = height > 0 ? height : text?.height ?? 0;
      text?.layout(maxWidth: math.max(0, kind == GraphStackSlot.badge ? width - 2 * _badgePadX : width));
      _slots.add((kind, Rect.fromLTWH(x0, centreY - h / 2, width, h), text));
      x0 += width;
    }

    if (_detailed) {
      // Line 2's yield: the authors shrink (gone below one character), then the dates go.
      final double fixed = range.width + (conflict ? _metaGap + _icon : 0);
      double datesW = dates == null ? 0 : _metaGap + dates.width;
      double authorsW = authors == null ? 0 : math.max(0, avail - fixed - datesW - _metaGap);
      if (authors != null) {
        authorsW = math.min(authorsW, authors.width);
        if (authorsW < _paragraph(TextSpan(text: authorsText!.characters.first, style: meta)).width) {
          authorsW = 0;
        }
      }
      if (fixed + datesW + (authorsW > 0 ? _metaGap + authorsW : 0) > avail) {
        datesW = 0;
      }
      final double h1 = math.max(_badgeH, subject.height);
      final double h2 = range.height;
      final double top = _card.top + (_card.height - h1 - _lineGap - h2) / 2;
      final double c1 = top + h1 / 2;
      place(GraphStackSlot.badge, badgeW, c1, badge, height: _badgeH);
      x0 += _gap;
      place(GraphStackSlot.subject, math.max(0, math.min(subject.width, avail - badgeW - _gap)), c1, subject);
      final double c2 = top + h1 + _lineGap + h2 / 2;
      x0 = _card.left + _metrics.cardPadX;
      place(GraphStackSlot.range, math.min(range.width, avail), c2, range);
      if (authorsW > 0) {
        x0 += _metaGap;
        place(GraphStackSlot.authors, authorsW, c2, authors);
      }
      if (datesW > 0) {
        x0 += _metaGap;
        place(GraphStackSlot.dates, dates!.width, c2, dates);
      }
      if (conflict) {
        x0 += _metaGap;
        place(GraphStackSlot.conflict, _icon, c2, null, height: _icon);
      }
    } else {
      // One line: the subject yields first.
      final double c = _card.center.dy;
      final double rest = badgeW + _gap + range.width + _gap + (conflict ? _gap + _icon : 0);
      final double subjectW = math.max(0, math.min(subject.width, avail - rest));
      place(GraphStackSlot.badge, badgeW, c, badge, height: _badgeH);
      x0 += _gap;
      place(GraphStackSlot.range, math.min(range.width, math.max(0, avail - badgeW - _gap)), c, range);
      if (subjectW > 0) {
        x0 += _gap;
        place(GraphStackSlot.subject, subjectW, c, subject);
      }
      if (conflict) {
        x0 += _gap;
        place(GraphStackSlot.conflict, _icon, c, null, height: _icon);
      }
    }
  }

  // ---- paint ----

  RRect get _cardRRect => RRect.fromRectAndRadius(_card, Radius.circular(_metrics.radiusCard));

  /// A box-shadow layer `0 [dy] 0 [spread]` of the card (CSS: the rect shifted, grown by the negative spread, its
  /// radius grown with it).
  RRect _layer(double dy, double spread) => RRect.fromRectAndRadius(
    _card.shift(Offset(0, dy)).inflate(spread),
    Radius.circular(math.max(0, _metrics.radiusCard + spread)),
  );

  @override
  void paint(PaintingContext context, Offset offset) {
    final Canvas canvas = context.canvas;
    final GraphTheme t = _theme;
    final bool hover = _hoverShown;
    final Color fill = hover ? t.cardFillHover : t.cardFill;
    final Color border = hover ? t.cardBorderHover : t.cardBorder;
    canvas
      ..save()
      ..translate(offset.dx, offset.dy);
    // Back to front (CSS paints the first shadow on top): 14/−6 border, 14/−7 fill, 7/−3 border, 7/−4 fill.
    for (final (double dy, double spread) in const <(double, double)>[(14, -6), (7, -3)]) {
      canvas
        ..drawRRect(_layer(dy, spread), Paint()..color = border)
        ..drawRRect(_layer(dy, spread - 1), Paint()..color = fill);
      if (_data.immutable) {
        paintGraphHatch(canvas, _layer(dy, spread - 1), period: _hatchPeriod, color: t.hatch);
      }
    }
    final RRect rrect = _cardRRect;
    canvas.drawRRect(rrect, Paint()..color = fill);
    if (_data.immutable) {
      paintGraphHatch(canvas, rrect, period: _hatchPeriod, color: t.hatch);
    }
    canvas
      ..drawRRect(
        rrect.deflate(.5),
        Paint()
          ..color = border
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      )
      ..save()
      ..clipRect(
        Rect.fromLTRB(_card.left + _metrics.cardPadX, _card.top, _card.right - _metrics.cardPadX, _card.bottom),
      );
    for (final (GraphStackSlot kind, Rect rect, TextPainter? text) in _slots) {
      switch (kind) {
        case GraphStackSlot.badge:
          final pill = RRect.fromRectAndRadius(rect, const Radius.circular(_badgeH / 2));
          canvas
            ..drawRRect(pill, Paint()..color = _badgeFill)
            ..drawRRect(
              pill.deflate(.5),
              Paint()
                ..color = border
                ..style = PaintingStyle.stroke
                ..strokeWidth = 1,
            );
          text?.paint(canvas, rect.center - Offset(text.width / 2, text.height / 2));
        case GraphStackSlot.conflict:
          _paintIcon(canvas, _conflictIcon, rect.topLeft, t.conflict);
        case GraphStackSlot.subject || GraphStackSlot.range || GraphStackSlot.authors || GraphStackSlot.dates:
          text?.paint(canvas, Offset(rect.left, rect.center.dy - text.height / 2));
      }
    }
    canvas.restore();
    if (_focused && !_inactive && FocusManager.instance.highlightMode == FocusHighlightMode.traditional) {
      final double w = _metrics.focusW;
      canvas.drawRRect(
        rrect.inflate(_metrics.focusOffsetCard + w / 2),
        Paint()
          ..color = t.focusRing
          ..style = PaintingStyle.stroke
          ..strokeWidth = w,
      );
    }
    canvas.restore();
  }

  static void _paintIcon(Canvas canvas, ui.Picture? picture, Offset topLeft, Color color) {
    if (picture == null) {
      return;
    }
    const double scale = _icon / 16;
    canvas
      ..save()
      ..translate(topLeft.dx, topLeft.dy)
      ..saveLayer(
        Offset.zero & const Size.square(_icon),
        Paint()..colorFilter = ColorFilter.mode(color, BlendMode.srcIn),
      )
      ..scale(scale, scale)
      ..drawPicture(picture)
      ..restore()
      ..restore();
  }

  // ---- hit testing and input ----

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (!_cardRRect.contains(position)) {
      return false;
    }
    result.add(BoxHitTestEntry(this, position));
    return true;
  }

  GraphCardHoverArea get _area => (part: GraphCardHoverPart.body, rect: _card.shift(-_card.topLeft), tooltip: null);

  @override
  void handleEvent(PointerEvent event, BoxHitTestEntry entry) {
    if (event is PointerDownEvent) {
      _tap.addPointer(event);
    } else if (event is PointerHoverEvent) {
      _controller.enter(_data.key, _area);
    }
  }

  void _expand() => _controller.onExpandStack?.call(_data.key);

  @override
  MouseCursor get cursor => MouseCursor.defer;

  void _enter(PointerEnterEvent event) => _controller.enter(_data.key, _area);

  void _exit(PointerExitEvent event) => _controller.leave(_data.key);

  @override
  PointerEnterEventListener? get onEnter => _enter;

  @override
  PointerExitEventListener? get onExit => _exit;

  @override
  bool get validForMouseTracker => attached;

  // ---- semantics ----

  @override
  Rect get semanticBounds => _card;

  @override
  void describeSemanticsConfiguration(SemanticsConfiguration config) {
    super.describeSemanticsConfiguration(config);
    final GraphStackData d = _data;
    final GraphCommitContent? newest = d.newest.content;
    final String subject = newest == null
        ? ''
        : newest.subject.isEmpty
        ? _strings.cardNoDescription
        : newest.subject;
    config
      ..isSemanticBoundary = true
      ..isButton = true
      ..isExpanded = false
      ..identifier = 'graph-stack-${d.key}'
      ..label = _strings.stackLabel(d.count, subject, d.range)
      ..textDirection = TextDirection.ltr
      ..onTap = _expand
      ..onExpand = _expand;
  }
}
