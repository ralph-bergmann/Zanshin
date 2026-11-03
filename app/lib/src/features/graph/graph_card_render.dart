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
import 'day_axis.dart';
import 'graph_card.dart';
import 'graph_drag.dart';
import 'graph_layout.dart';
import 'graph_viewport_render.dart' show graphCardOverhang;
import 'hatch_swatch.dart';

/// The DS drag threshold (DS components/content/ProjectRow.prompt.md:11, "4px threshold"): a press on a card or an
/// affordance that travels further is no click.
const double graphDragThreshold = 4;

/// A laid-out part of a card, for the yield witnesses ([RenderGraphCard.debugSlots]).
enum GraphCardSlot {
  /// The subject.
  subject,

  /// The @ badge (`name@` with two or more workspaces).
  atBadge,

  /// Another workspace's `name@` tag.
  workspaceTag,

  /// The `+N` tag of the folded workspaces.
  moreTag,

  /// The change id.
  id,

  /// The author's first name.
  author,

  /// The relative date.
  date,

  /// The "empty" word.
  empty,

  /// The conflict flag.
  conflict,

  /// The merge flag.
  merge,

  /// The bookmark legend pill.
  legend,

  /// The add-bookmark circle.
  addBookmark,

  /// The ••• circle.
  more,
}

enum _Deco { none, badge, tag }

enum _Area { body, bookmarks, more }

/// One item of a card line: a text, an icon or a decorated (badge / tag) text.
class _Item {
  _Item.text(this.kind, TextPainter this.text, {this.deco = _Deco.none}) : icon = null, iconColor = null;

  _Item.icon(this.kind, this.icon, Color this.iconColor) : text = null, deco = _Deco.none;

  final GraphCardSlot kind;
  final TextPainter? text;
  final ui.Picture? icon;
  final Color? iconColor;
  final _Deco deco;
  double width = 0;
  double gapBefore = 0;
  Rect rect = Rect.zero;

  double get natural => text == null
      ? _icon
      : deco == _Deco.none
      ? text!.width
      : text!.width + 2 * _slotPadX;

  double get height => deco != _Deco.none
      ? _slotH
      : text == null
      ? _icon
      : text!.height;
}

// The card's geometry (DS components/graph/graph.css:1-24, :33-53, :87-96).
const double _icon = 12;
const double _lineGap = 5;
const double _metaGap = 8;
const double _compactGap = 7;
const double _slotH = 16;
const double _slotPadX = 5;
const double _slotMax = 96;
const double _slotMin = 24;
const double _afford = 20;
const double _affordRight = 10;
const double _affordOut = 11;
const double _pillH = 20;
const double _pillPadL = 6;
const double _pillPadR = 8;
const double _pillGap = 4;
const double _pillMoreGap = 2;
const double _hatchPeriod = 6;
// The skeleton bar in the subject slot (DS components/controls/Skeleton.jsx: the card's 9 px subject bar, 58 %).
const double _skeletonBarH = 9;
const _skeletonShare = .58;

/// The render box of a `GraphCard` (Story 10.3): one leaf that lays out its texts with [TextPainter]s and paints
/// rings, fill, tint, hatch, border, content, focus ring, the bookmark control and •••.
///
/// Its size is the card rect inflated by `graphCardOverhang`; it hit-tests only the card's rounded rect, the legend
/// pill and the revealed affordances, so the empty margin reaches the viewport. It is a [MouseTrackerAnnotation]
/// that sets [GraphCardController.hovered] and defers the cursor. Hover, selection, focus, menu, the actions switch
/// and the reveal repaint; a minute tick lays out only when the date text changes.
class RenderGraphCard extends RenderBox implements MouseTrackerAnnotation {
  /// Creates the render box.
  RenderGraphCard({
    required this._data,
    required this._theme,
    required this._elevation,
    required this._metrics,
    required this._motion,
    required this._inactive,
    required this._icons,
    required this._strings,
    required this._controller,
    required this._reveal,
    this._skeleton,
  });

  // A press released within the DS drag threshold clicks, as on macOS; past it nothing opens (without a slop a render
  // recognizer would take `kTouchSlop`, 18 px).
  late final _tap =
      TapGestureRecognizer(
          debugOwner: this,
          preAcceptSlopTolerance: graphDragThreshold,
          postAcceptSlopTolerance: graphDragThreshold,
        )
        ..onTapUp = _onTapUp
        ..onSecondaryTapUp = _onSecondaryTapUp;

  // Story 10.10: a press on the body or the legend pill that travels past the drag threshold starts the graph's drag,
  // which follows the mouse itself from then on.
  late final _drag = GraphDragRecognizer(debugOwner: this)
    ..onBegin = (at) {
      final GraphDragPayload? payload = _pressPayload;
      if (payload != null) {
        _controller.drag?.start(payload, at);
      }
    };
  GraphDragPayload? _pressPayload;

  /// The facts shown.
  GraphCardData get data => _data;
  GraphCardData _data;
  set data(GraphCardData value) {
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
    if (value == _theme) {
      return;
    }
    _theme = value;
    markNeedsLayout();
  }

  /// The rings.
  ZsElevation get elevation => _elevation;
  ZsElevation _elevation;
  set elevation(ZsElevation value) {
    if (value == _elevation) {
      return;
    }
    _elevation = value;
    markNeedsPaint();
  }

  /// The geometry tokens.
  ZsMetrics get metrics => _metrics;
  ZsMetrics _metrics;
  set metrics(ZsMetrics value) {
    if (value == _metrics) {
      return;
    }
    _metrics = value;
    markNeedsLayout();
  }

  /// The motion tokens of the reveal.
  ZsMotion get motion => _motion;
  ZsMotion _motion;
  set motion(ZsMotion value) {
    if (value == _motion) {
      return;
    }
    _motion = value;
    markNeedsPaint();
  }

  /// Whether the window is not key: no hover look, no hover reveal, no focus ring.
  bool get inactive => _inactive;
  bool _inactive;
  set inactive(bool value) {
    if (value == _inactive) {
      return;
    }
    _inactive = value;
    markNeedsPaint();
  }

  /// The glyphs.
  GraphCardIcons get icons => _icons;
  GraphCardIcons _icons;
  set icons(GraphCardIcons value) {
    if (value == _icons) {
      return;
    }
    _icons = value;
    // The flag items hold their glyph from layout.
    markNeedsLayout();
  }

  /// The words: the dates, the "empty" flag, the label and the custom actions.
  AppLocalizations get strings => _strings;
  AppLocalizations _strings;
  set strings(AppLocalizations value) {
    if (identical(value, _strings)) {
      return;
    }
    _strings = value;
    markNeedsLayout();
    markNeedsSemanticsUpdate();
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
    markNeedsSemanticsUpdate();
  }

  /// The affordances' reveal, 0–1.
  Animation<double> get reveal => _reveal;
  Animation<double> _reveal;
  set reveal(Animation<double> value) {
    if (identical(value, _reveal)) {
      return;
    }
    if (attached) {
      _reveal.removeListener(markNeedsPaint);
      value.addListener(markNeedsPaint);
    }
    _reveal = value;
    markNeedsPaint();
  }

  /// The skeleton bar while it shows (Story 10.11): painted in the subject slot of a non-root card without content;
  /// null paints none.
  GraphCardSkeleton? get skeleton => _skeleton;
  GraphCardSkeleton? _skeleton;
  set skeleton(GraphCardSkeleton? value) {
    if (value == _skeleton) {
      return;
    }
    if (attached) {
      _skeleton?.sweep.removeListener(markNeedsPaint);
      value?.sweep.addListener(markNeedsPaint);
    }
    final toggled = (value == null) != (_skeleton == null);
    _skeleton = value;
    if (toggled) {
      markNeedsLayout();
    } else {
      markNeedsPaint();
    }
  }

  // ---- interaction state, from the controller ----

  var _hovered = false;
  var _selected = false;
  var _focused = false;
  var _menuOpen = false;
  var _dropTarget = false;
  var _pointerOnMore = false;
  var _pointerOnAdd = false;
  // Whether the add circle was revealed before the fade-out started (an open menu alone never reveals it).
  var _addWasRevealed = false;
  _Area? _downArea;
  String? _relative;
  String? _day;

  bool get _hoverShown => _hovered && !_inactive;

  bool get _moreRevealed => _hoverShown || _focused || _menuOpen;

  bool get _addRevealed => _hoverShown || _focused;

  void _sync() {
    final String key = _data.key;
    _hovered = _controller.hovered.value == key;
    _selected = _controller.selected.value == key;
    _focused = _controller.focused.value == key;
    _menuOpen = _controller.menuOpen.value == key;
    _dropTarget = _controller.dropTarget.value == key;
  }

  void _onDropTarget() {
    final value = _controller.dropTarget.value == _data.key;
    if (value != _dropTarget) {
      _dropTarget = value;
      markNeedsPaint();
    }
  }

  void _onHovered() {
    final value = _controller.hovered.value == _data.key;
    if (value != _hovered) {
      _hovered = value;
      if (!value) {
        _pointerOnMore = false;
        _pointerOnAdd = false;
      }
      markNeedsPaint();
    }
  }

  void _onSelected() {
    final value = _controller.selected.value == _data.key;
    if (value != _selected) {
      _selected = value;
      markNeedsPaint();
      markNeedsSemanticsUpdate();
    }
  }

  void _onFocused() {
    final value = _controller.focused.value == _data.key;
    if (value != _focused) {
      _focused = value;
      markNeedsPaint();
    }
  }

  void _onMenuOpen() {
    final value = _controller.menuOpen.value == _data.key;
    if (value != _menuOpen) {
      _menuOpen = value;
      markNeedsPaint();
    }
  }

  void _onHighlightMode(FocusHighlightMode mode) {
    if (_focused) {
      markNeedsPaint();
    }
  }

  ({String? relative, String? day}) _dates() {
    final int? ts = _data.timestampMs;
    if (ts == null) {
      return (relative: null, day: null);
    }
    final int now = _controller.now.value;
    final int off = _data.utcOffsetMinutes;
    return (
      relative: graphRelativeDate(_strings, ts, nowMs: now, utcOffsetMinutes: off),
      day: graphDayLabel(
        _strings,
        graphLocalDay(ts, utcOffsetMinutes: off),
        nowMs: now,
        utcOffsetMinutes: off,
      ),
    );
  }

  void _onNow() {
    final (:String? relative, :String? day) = _dates();
    if (relative == _relative && day == _day) {
      return;
    }
    // Only the detailed card shows the date; the compact one updates its label alone.
    if (relative != _relative && _detailed) {
      markNeedsLayout();
    }
    _relative = relative;
    _day = day;
    markNeedsSemanticsUpdate();
  }

  void _listen() {
    _controller.hovered.addListener(_onHovered);
    _controller.selected.addListener(_onSelected);
    _controller.focused.addListener(_onFocused);
    _controller.menuOpen.addListener(_onMenuOpen);
    _controller.dropTarget.addListener(_onDropTarget);
    _controller.now.addListener(_onNow);
    _controller.actionsEnabled.addListener(markNeedsPaint);
  }

  void _unlisten() {
    _controller.hovered.removeListener(_onHovered);
    _controller.selected.removeListener(_onSelected);
    _controller.focused.removeListener(_onFocused);
    _controller.menuOpen.removeListener(_onMenuOpen);
    _controller.dropTarget.removeListener(_onDropTarget);
    _controller.now.removeListener(_onNow);
    _controller.actionsEnabled.removeListener(markNeedsPaint);
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _sync();
    _listen();
    _reveal.addListener(markNeedsPaint);
    _skeleton?.sweep.addListener(markNeedsPaint);
    FocusManager.instance.addHighlightModeListener(_onHighlightMode);
  }

  @override
  void detach() {
    // A detached card gets no onExit (validForMouseTracker is false): give its hover back after this frame.
    final GraphCardController controller = _controller;
    final String key = _data.key;
    if (controller.hovered.value == key) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        // A host that unmounted with its cards may have disposed the controller meanwhile.
        if (!controller.isDisposed && controller.hovered.value == key && !attached) {
          controller.hovered.value = null;
        }
      });
    }
    _pointerOnMore = false;
    _pointerOnAdd = false;
    _unlisten();
    _reveal.removeListener(markNeedsPaint);
    _skeleton?.sweep.removeListener(markNeedsPaint);
    FocusManager.instance.removeHighlightModeListener(_onHighlightMode);
    super.detach();
  }

  @override
  void dispose() {
    _tap.dispose();
    _drag.dispose();
    _disposeTexts();
    super.dispose();
  }

  // ---- layout ----

  Rect _card = Rect.zero;
  var _detailed = true;
  final _texts = <TextPainter>[];
  final _items = <_Item>[];
  final _legendItems = <_Item>[];
  Rect? _legend;
  Rect? _add;
  Rect _more = Rect.zero;
  // The skeleton bar: set for a non-root card without content while [skeleton] is set.
  Rect? _bar;
  // The other workspaces folded into the `+N` tag.
  var _folded = const <String>[];

  /// The laid-out slots in local coordinates, for the yield witnesses.
  @visibleForTesting
  List<({GraphCardSlot kind, Rect rect, String? text, TextStyle? style})> get debugSlots =>
      <({GraphCardSlot kind, Rect rect, String? text, TextStyle? style})>[
        for (final _Item item in _items)
          (kind: item.kind, rect: item.rect, text: item.text?.plainText, style: item.text?.text?.style),
        if (_legend != null) (kind: GraphCardSlot.legend, rect: _legend!, text: null, style: null),
        if (_add != null) (kind: GraphCardSlot.addBookmark, rect: _add!, text: null, style: null),
        (kind: GraphCardSlot.more, rect: _more, text: null, style: null),
      ];

  /// The legend pill's texts in render order, for the legend witnesses.
  @visibleForTesting
  List<String> get debugLegendTexts => <String>[for (final _Item item in _legendItems) item.text!.plainText];

  /// The card rect in local coordinates.
  Rect get cardRect => _card;

  /// The skeleton bar this card paints now, in local coordinates; null when it paints none.
  @visibleForTesting
  Rect? get debugSkeletonBar => _bar;

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

  TextPainter _plain(String text, TextStyle style) => _paragraph(TextSpan(text: text, style: style));

  static TextStyle _weight(TextStyle style, FontWeight weight) => style.copyWith(
    fontWeight: weight,
    fontVariations: <FontVariation>[FontVariation.weight(weight.value.toDouble())],
  );

  static final TextStyle _mono11 = ZsType.id.copyWith(fontSize: ZsType.fsSm);

  @override
  bool get sizedByParent => true;

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.biggest;

  @override
  void performLayout() {
    _disposeTexts();
    _items.clear();
    _legendItems.clear();
    const double o = graphCardOverhang;
    _card = Rect.fromLTWH(o, o, math.max(0, size.width - 2 * o), math.max(0, size.height - 2 * o));
    _detailed = _card.height >= _metrics.cardHDetailed;
    final (:String? relative, :String? day) = _dates();
    _relative = relative;
    _day = day;
    _layoutLines();
    _layoutBookmarkControl();
    _more = Rect.fromLTWH(_card.right - _affordRight - _afford, _card.bottom + _affordOut - _afford, _afford, _afford);
  }

  void _layoutLines() {
    final GraphTheme t = _theme;
    final GraphCardData d = _data;
    final GraphCommitContent? content = d.content;
    final double avail = math.max(0, _card.width - 2 * _metrics.cardPadX);
    final double gap = _detailed ? _metaGap : _compactGap;
    // A compact card reserves the bar's slot only while the bar shows, so a card without a loader lays out as before.
    final bool waiting = content == null && !d.isRoot && _skeleton != null;

    // The subject (graph.css:11-14).
    final Color subjectColor = d.immutable ? t.cardTextMuted : t.cardText;
    final TextPainter subject = d.isRoot
        ? _plain(
            'root()', // l10n-ignore: jj's text
            _weight(ZsType.cardSubject, FontWeight.w400).copyWith(
              fontFamily: ZsType.monoFamily,
              fontFamilyFallback: const <String>[ZsType.sansFamily],
              color: t.cardTextMuted,
            ),
          )
        : content != null && content.subject.isEmpty
        ? _plain(
            '(no description set)', // l10n-ignore: jj's text
            _weight(
              ZsType.cardSubject,
              FontWeight.w400,
            ).copyWith(fontStyle: FontStyle.italic, color: d.immutable ? t.cardTextMuted : t.cardTextDim),
          )
        : _plain(content?.subject ?? '', ZsType.cardSubject.copyWith(color: subjectColor));
    final subjectItem = _Item.text(GraphCardSlot.subject, subject);

    // The @ slots (graph.css:38-45).
    final bool named = d.workingCopies.isNotEmpty;
    final String? ours = d.workspaceName;
    final _Item? badge = d.isWorkingCopy
        ? _Item.text(
            GraphCardSlot.atBadge,
            _plain(
              named && ours != null ? '${jjRefSymbol(ours)}@' : '@',
              _weight(_mono11, FontWeight.w700).copyWith(height: 1, color: t.atBadgeText),
            ),
            deco: _Deco.badge,
          )
        : null;
    final List<String> others = d.otherWorkspaces;
    final tags = <_Item>[
      for (final String name in others.take(2))
        _Item.text(
          GraphCardSlot.workspaceTag,
          _plain(
            '${jjRefSymbol(name)}@',
            _weight(_mono11, FontWeight.w600).copyWith(height: 1, color: t.cardTextMuted),
          ),
          deco: _Deco.tag,
        ),
    ];
    final plusTags = <int, _Item>{};
    _Item plus(int n) => plusTags.putIfAbsent(
      n,
      () => _Item.text(
        GraphCardSlot.moreTag,
        _plain('+$n', _mono11.copyWith(height: 1, color: t.cardTextDim)),
        deco: _Deco.tag,
      ),
    );

    // The id (graph.css:34-35; commit_templater.rs:2316-2321 @ v0.46.0): one paragraph, no gap between the spans.
    final (:String prefix, :String rest, :String offset) = d.idParts(detailed: _detailed);
    final id = _Item.text(
      GraphCardSlot.id,
      _paragraph(
        TextSpan(
          style: ZsType.id.copyWith(color: t.cardTextFaint),
          children: <InlineSpan>[
            if (prefix.isNotEmpty)
              TextSpan(
                text: prefix,
                style: _weight(ZsType.id, FontWeight.w700).copyWith(color: t.cardText),
              ),
            if (rest.isNotEmpty) TextSpan(text: rest),
            if (offset.isNotEmpty) TextSpan(text: offset),
          ],
        ),
      ),
    );

    final TextStyle meta = ZsType.meta.copyWith(color: t.cardTextDim);
    final String? authorText = d.author;
    final _Item? author = _detailed && authorText != null
        ? _Item.text(GraphCardSlot.author, _plain(authorText, meta))
        : null;
    final _Item? date = _detailed && _relative != null
        ? _Item.text(GraphCardSlot.date, _plain(_relative!, meta))
        : null;
    final flags = <_Item>[
      if (_detailed && (content?.empty ?? false))
        _Item.text(
          GraphCardSlot.empty,
          _plain(_strings.cardEmpty, meta.copyWith(fontStyle: FontStyle.italic, color: t.cardTextFaint)),
        ),
      if (content?.conflict ?? false) _Item.icon(GraphCardSlot.conflict, _icons.conflict, t.conflict),
      if (d.merge) _Item.icon(GraphCardSlot.merge, _icons.merge, t.cardTextDim),
    ];

    // The yield order (Story 10.3, epics.md:8831-8832): detailed — the author shrinks (dropped below one character),
    // then tags fold into +N, then names shorten below 96 (to 24), then the date goes; compact — the subject first.
    int shown = tags.length;
    double cap = _slotMax;
    double authorW = author?.natural ?? 0;
    var showDate = date != null;
    double subjectW = 0;
    // A name slot (the named badge, a tag) is at most `cap` wide; the plain @ badge and +N never shorten.
    double slot(_Item item) => item.kind == GraphCardSlot.workspaceTag || (item.kind == GraphCardSlot.atBadge && named)
        ? math.min(cap, item.natural)
        : item.natural;
    List<(_Item, double)> line() => <(_Item, double)>[
      if (badge != null) (badge, slot(badge)),
      for (final _Item tag in tags.take(shown)) (tag, slot(tag)),
      if (others.length > shown) (plus(others.length - shown), slot(plus(others.length - shown))),
      (id, id.natural),
      if (_detailed) ...<(_Item, double)>[
        if (author != null && authorW > 0) (author, authorW),
        if (date != null && showDate) (date, date.natural),
      ] else if (subjectW > 0)
        (subjectItem, subjectW),
      for (final _Item flag in flags) (flag, flag.natural),
    ];
    double total() {
      final List<(_Item, double)> items = line();
      return items.fold<double>(0, (sum, item) => sum + item.$2) + gap * math.max(0, items.length - 1);
    }

    if (_detailed) {
      if (author != null && total() > avail) {
        final double oneChar = _plain(authorText!.characters.first, meta).width;
        authorW = math.max(0, authorW - (total() - avail));
        if (authorW < oneChar) {
          authorW = 0;
        }
      }
    } else {
      final double rest = total();
      final double ellipsis = _plain('…', subject.text!.style!).width;
      // Without content the slot holds the skeleton bar, up to its 58 %.
      subjectW = math.min(waiting ? avail * _skeletonShare : subject.width, avail - rest - gap);
      if (subjectW < ellipsis) {
        subjectW = 0;
      }
    }
    while (total() > avail && shown > 0) {
      shown--;
    }
    while (total() > avail && cap > _slotMin) {
      cap = math.max(_slotMin, cap - 1);
    }
    if (total() > avail) {
      showDate = false;
    }

    final List<(_Item, double)> items = line();
    _folded = others.length > shown ? others.sublist(shown) : const <String>[];
    for (final (_Item item, double width) in items) {
      item.width = width;
      item.text?.layout(maxWidth: math.max(0, item.deco == _Deco.none ? width : width - 2 * _slotPadX));
    }
    double lineHeight(Iterable<_Item> line) => line.fold(0, (h, item) => math.max(h, item.height));
    if (_detailed) {
      subjectItem.width = math.min(subject.width, avail);
      subject.layout(maxWidth: avail);
      final double h1 = subject.height;
      final double h2 = lineHeight(items.map((e) => e.$1));
      final double top = _card.top + (_card.height - h1 - _lineGap - h2) / 2;
      _place(<_Item>[subjectItem], top + h1 / 2, gap);
      _place(<_Item>[for (final (_Item item, _) in items) item], top + h1 + _lineGap + h2 / 2, gap);
    } else {
      _place(<_Item>[for (final (_Item item, _) in items) item], _card.center.dy, gap);
    }
    final double barWidth = _detailed ? avail * _skeletonShare : subjectW;
    _bar = waiting && barWidth > 0
        ? Rect.fromLTWH(
            subjectItem.rect.left,
            subjectItem.rect.center.dy - _skeletonBarH / 2,
            barWidth,
            _skeletonBarH,
          )
        : null;
  }

  void _place(List<_Item> line, double centreY, double gap) {
    double x = _card.left + _metrics.cardPadX;
    for (final item in line) {
      item.rect = Rect.fromLTWH(x, centreY - item.height / 2, item.width, item.height);
      x += item.width + gap;
      _items.add(item);
    }
  }

  void _layoutBookmarkControl() {
    _legend = null;
    _add = null;
    if (_data.isRoot) {
      return;
    }
    final double top = _card.top - _affordOut;
    final double right = _card.right - _affordRight;
    if (_data.refs.isEmpty) {
      _add = Rect.fromLTWH(right - _afford, top, _afford, _afford);
      return;
    }
    final GraphTheme t = _theme;
    final (:String prefix, :String main, :String remote, :String sigil, :String rest) = graphLegendParts(
      _data.refs.first,
    );
    final int more = _data.refs.length - 1;
    final TextStyle dim = _mono11.copyWith(color: t.cardTextDim);
    final TextStyle bold = _weight(_mono11, FontWeight.w600).copyWith(color: t.cardText);
    final double ch = _plain('0', _mono11).width;
    _Item item(String text, TextStyle style, {double gap = _pillGap}) =>
        _Item.text(GraphCardSlot.legend, _plain(text, style))..gapBefore = gap;
    // The render order (epics.md:8909): prefix · main · @remote · sigil · rest · +N.
    final _Item? prefixItem = prefix.isEmpty ? null : item(prefix, dim);
    final _Item? mainItem = main.isEmpty ? null : item(main, bold);
    final _Item? remoteItem = remote.isEmpty ? null : item(remote, dim);
    final _Item? sigilItem = sigil.isEmpty ? null : item(sigil, bold, gap: 0);
    final _Item? restItem = rest.isEmpty ? null : item(rest, dim);
    final _Item? moreItem = more <= 0
        ? null
        : item(
            '+$more',
            _mono11.copyWith(fontSize: ZsType.fsXs, color: t.cardTextDim),
            gap: _pillGap + _pillMoreGap,
          );
    final items = <_Item>[?prefixItem, ?mainItem, ?remoteItem, ?sigilItem, ?restItem, ?moreItem];
    for (final each in items) {
      each.width = identical(each, prefixItem) ? math.min(each.natural, 4 * ch) : each.natural;
    }
    // At most W/2 − 34 (the 2026-10-14 note): the prefix shrinks first, then the rest, the remote, the main; the sigil
    // and +N go last, whole.
    final double maxWidth = math.max(0, _card.width / 2 - 34);
    double width() =>
        1 + _pillPadL + _icon + items.fold(0.0, (sum, each) => sum + each.gapBefore + each.width) + _pillPadR + 1;
    for (final each in <_Item?>[prefixItem, restItem, remoteItem, mainItem, sigilItem, moreItem]) {
      if (each == null || width() <= maxWidth) {
        continue;
      }
      final bool whole = identical(each, sigilItem) || identical(each, moreItem);
      each.width = whole ? 0 : math.max(0, each.width - (width() - maxWidth));
      if (each.width < ch) {
        items.remove(each);
      }
    }
    final double pillWidth = width();
    final legend = Rect.fromLTWH(right - pillWidth, top, pillWidth, _pillH);
    double x = legend.left + 1 + _pillPadL + _icon;
    for (final each in items) {
      x += each.gapBefore;
      each.text!.layout(maxWidth: each.width);
      each.rect = Rect.fromLTWH(x, legend.center.dy - each.height / 2, each.width, each.height);
      x += each.width;
      _legendItems.add(each);
    }
    _legend = legend;
  }

  // ---- paint ----

  RRect get _cardRRect => RRect.fromRectAndRadius(_card, Radius.circular(_metrics.radiusCard));

  static Color _alpha(Color color, double alpha) => color.withValues(alpha: color.a * alpha);

  @override
  void paint(PaintingContext context, Offset offset) {
    final Canvas canvas = context.canvas;
    final GraphTheme t = _theme;
    final RRect rrect = _cardRRect;
    final bool wc = _data.isWorkingCopy;
    final bool hover = _hoverShown;
    canvas
      ..save()
      ..translate(offset.dx, offset.dy);

    // Rings: ZsShadowStack is front-first, so paint it reversed.
    // Story 10.10: a drop target wins (graph.css:8 `.zs-card.is-drop`).
    final bool drop = _dropTarget;
    final ZsShadowStack? ring = drop
        ? _elevation.ringDrop
        : wc
        ? (_selected ? _elevation.ringWcSelect : _elevation.ringWc)
        : _selected
        ? _elevation.ringSelect
        : null;
    if (ring != null) {
      for (final BoxShadow shadow in ring.boxShadows.reversed) {
        canvas.drawRRect(rrect.shift(shadow.offset).inflate(shadow.spreadRadius), shadow.toPaint());
      }
    }

    // Fill and the @ tint (graph.css:2-6, :85): the menu's hover look wins, the @ fill wins over hover.
    canvas.drawRRect(rrect, Paint()..color = drop || _menuOpen || (hover && !wc) ? t.cardFillHover : t.cardFill);
    if (wc && !_menuOpen && !drop) {
      canvas.drawRRect(
        rrect,
        Paint()
          ..shader = ZsLinearGradient(
            angle: 135,
            stops: <ZsGradientStop>[
              ZsGradientStop(t.workingCopyTint, percent: 0),
              ZsGradientStop(t.workingCopyTint.withValues(alpha: 0), percent: 70),
            ],
          ).createShader(_card),
      );
    }
    if (_data.immutable) {
      paintGraphHatch(canvas, rrect, period: _hatchPeriod, color: t.hatch);
    }
    final Color border = drop
        ? t.dropTargetLine
        : _menuOpen
        ? t.cardBorderHover
        : wc
        ? t.workingCopyLine
        : _selected
        ? t.cardSelectedBorder
        : hover
        ? t.cardBorderHover
        : t.cardBorder;
    // Then the content, clipped to the padding box so no text overflows W − 24.
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
    for (final _Item item in _items) {
      _paintItem(canvas, item);
    }
    final GraphCardSkeleton? skeleton = _skeleton;
    final Rect? bar = _bar;
    if (skeleton != null && bar != null) {
      paintZsSkeletonBar(
        canvas,
        bar,
        t: skeleton.sweep.value,
        base: skeleton.base,
        high: skeleton.high,
        radius: _metrics.radiusXs,
        motion: _motion.motion,
      );
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

    final Rect? legend = _legend;
    if (legend != null) {
      final pill = RRect.fromRectAndRadius(legend, const Radius.circular(_pillH / 2));
      canvas
        ..drawRRect(pill, Paint()..color = hover ? t.cardFillHover : t.cardFill)
        ..drawRRect(
          pill.deflate(.5),
          Paint()
            ..color = wc
                ? t.workingCopyLine
                : _selected
                ? t.cardSelectedBorder
                : hover
                ? t.cardBorderHover
                : t.cardBorder
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1,
        )
        ..save()
        ..clipRRect(pill);
      _paintIcon(
        canvas,
        _icons.bookmarkFilled,
        Offset(legend.left + 1 + _pillPadL, legend.center.dy - _icon / 2),
        t.cardTextDim,
      );
      for (final _Item item in _legendItems) {
        _paintItem(canvas, item);
      }
      canvas.restore();
    }

    final double v = _reveal.value;
    if (v > 0) {
      final double alpha =
          _motion.easeState.transform(v) * (_controller.actionsEnabled.value ? 1 : _metrics.disabledOpacity);
      final double scale = 1 - .15 * _motion.motion * (1 - _motion.easeGlide.transform(v));
      final Rect? add = _add;
      // Nothing revealed while v > 0 is the fade-out: both fade with it, the add circle only if it was shown. An open
      // menu alone reveals ••• only.
      if (_addRevealed) {
        _addWasRevealed = true;
      } else if (_moreRevealed) {
        _addWasRevealed = false;
      }
      if (add != null && (_addRevealed || (!_moreRevealed && _addWasRevealed))) {
        // graph.css:96: the pointer over the add circle lights its glyph only.
        _paintAffordance(canvas, add, _icons.bookmark, alpha: alpha, scale: scale, lit: false, glyphLit: _pointerOnAdd);
      }
      _paintAffordance(canvas, _more, _icons.more, alpha: alpha, scale: scale, lit: _pointerOnMore || _menuOpen);
    }
    canvas.restore();
  }

  void _paintItem(Canvas canvas, _Item item) {
    final GraphTheme t = _theme;
    final Rect rect = item.rect;
    switch (item.deco) {
      case _Deco.badge:
        canvas.drawRRect(
          RRect.fromRectAndRadius(rect, Radius.circular(_metrics.radiusXs)),
          Paint()..color = t.atBadgeFill,
        );
      case _Deco.tag:
        canvas.drawRRect(
          RRect.fromRectAndRadius(rect, Radius.circular(_metrics.radiusXs)).deflate(.5),
          Paint()
            ..color = t.cardBorder
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1,
        );
      case _Deco.none:
        break;
    }
    final TextPainter? text = item.text;
    if (text != null) {
      final double left = item.deco == _Deco.none ? rect.left : rect.left + _slotPadX;
      text.paint(canvas, Offset(left, rect.center.dy - text.height / 2));
    } else {
      _paintIcon(canvas, item.icon, rect.topLeft, item.iconColor!);
    }
  }

  /// Paints [picture] (a 16-unit glyph) at 12 px tinted [color], as `RenderZanshinIcon.paint` does.
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

  void _paintAffordance(
    Canvas canvas,
    Rect rect,
    ui.Picture? glyph, {
    required double alpha,
    required double scale,
    required bool lit,
    bool? glyphLit,
  }) {
    final GraphTheme t = _theme;
    final bool hover = _hoverShown;
    final Color fill = lit || hover ? t.cardFillHover : t.cardFill;
    final Color border = lit
        ? t.cardBorderHover
        : _data.isWorkingCopy
        ? t.workingCopyLine
        : _selected
        ? t.cardSelectedBorder
        : hover
        ? t.cardBorderHover
        : t.cardBorder;
    final Offset c = rect.center;
    canvas
      ..save()
      ..translate(c.dx, c.dy)
      ..scale(scale)
      ..translate(-c.dx, -c.dy)
      ..drawOval(rect, Paint()..color = _alpha(fill, alpha))
      ..drawOval(
        rect.deflate(.5),
        Paint()
          ..color = _alpha(border, alpha)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
    _paintIcon(
      canvas,
      glyph,
      c - const Offset(_icon / 2, _icon / 2),
      _alpha(glyphLit ?? lit ? t.cardText : t.cardTextFaint, alpha),
    );
    canvas.restore();
  }

  // ---- hit testing and input ----

  static bool _inCircle(Rect rect, Offset p) => (p - rect.center).distance <= rect.width / 2;

  _Area? _areaAt(Offset p) {
    if (_moreRevealed && _inCircle(_more, p)) {
      return _Area.more;
    }
    final Rect? legend = _legend;
    if (legend != null && RRect.fromRectAndRadius(legend, const Radius.circular(_pillH / 2)).contains(p)) {
      return _Area.bookmarks;
    }
    final Rect? add = _add;
    if (add != null && _addRevealed && _inCircle(add, p)) {
      return _Area.bookmarks;
    }
    return _cardRRect.contains(p) ? _Area.body : null;
  }

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (_areaAt(position) == null) {
      return false;
    }
    result.add(BoxHitTestEntry(this, position));
    return true;
  }

  @override
  void handleEvent(PointerEvent event, BoxHitTestEntry entry) {
    if (event is PointerDownEvent) {
      _downArea = _areaAt(entry.localPosition);
      _tap.addPointer(event);
      _pressPayload = _dragPayloadAt(entry.localPosition);
      if (_pressPayload != null && _controller.drag != null && _controller.actionsEnabled.value) {
        _drag.addPointer(event);
      }
    } else if (event is PointerHoverEvent) {
      final bool onMore = _moreRevealed && _inCircle(_more, entry.localPosition);
      final Rect? add = _add;
      final bool onAdd = add != null && _addRevealed && _inCircle(add, entry.localPosition);
      if (onMore != _pointerOnMore || onAdd != _pointerOnAdd) {
        _pointerOnMore = onMore;
        _pointerOnAdd = onAdd;
        markNeedsPaint();
      }
      _controller.enter(_data.key, _hoverAreaAt(entry.localPosition));
    }
  }

  /// The part of the card at [p] (local) for the peek and the affordance tooltips (Story 10.6).
  GraphCardHoverArea _hoverAreaAt(Offset p) {
    final Offset origin = _card.topLeft;
    GraphCardHoverArea area(GraphCardHoverPart part, Rect rect, String? tooltip) =>
        (part: part, rect: rect.shift(-origin), tooltip: tooltip);
    if (_moreRevealed && _inCircle(_more, p)) {
      return area(GraphCardHoverPart.more, _more, _strings.cardActionsTooltip);
    }
    final Rect? legend = _legend;
    if (legend != null && RRect.fromRectAndRadius(legend, const Radius.circular(_pillH / 2)).contains(p)) {
      return area(
        GraphCardHoverPart.bookmarks,
        legend,
        _strings.cardBookmarks(_data.refs.map((r) => r.display).join(', ')),
      );
    }
    final Rect? add = _add;
    if (add != null && _addRevealed && _inCircle(add, p)) {
      return area(GraphCardHoverPart.bookmarks, add, _strings.cardAddBookmark);
    }
    for (final _Item item in _items) {
      if (item.kind == GraphCardSlot.moreTag && item.rect.contains(p)) {
        return area(GraphCardHoverPart.moreTag, item.rect, _folded.join(', '));
      }
    }
    return area(GraphCardHoverPart.body, _card, null);
  }

  Rect _global(Rect rect) => MatrixUtils.transformRect(getTransformTo(null), rect);

  /// What a drag from [p] (local) carries (Story 10.10): the change from the body of a non-root card, the first ref
  /// from the legend pill when it is a local bookmark without `@`; null elsewhere (•••, the add circle).
  GraphDragPayload? _dragPayloadAt(Offset p) {
    final GraphCardData d = _data;
    switch (_areaAt(p)) {
      case _Area.body:
        return d.isRoot ? null : graphChangeDragOf(d);
      case _Area.bookmarks:
        final Rect? legend = _legend;
        final GraphRef? first = d.refs.firstOrNull;
        final bool onPill =
            legend != null && RRect.fromRectAndRadius(legend, const Radius.circular(_pillH / 2)).contains(p);
        return onPill && first != null && graphBookmarkDraggable(first.name, remote: first.remote)
            ? GraphBookmarkDrag(first.name)
            : null;
      case _Area.more || null:
        return null;
    }
  }

  void _onTapUp(TapUpDetails details) {
    final bool enabled = _controller.actionsEnabled.value;
    switch (_downArea) {
      case _Area.more:
        if (enabled) {
          _controller.openMenu(_data.key, _global(_more));
        }
      case _Area.bookmarks:
        if (enabled) {
          _controller.openBookmarks(_data.key, _global(_legend ?? _add ?? _card));
        }
      case _Area.body:
        _controller.click(_data.key, editable: !_data.immutable);
      case null:
        break;
    }
  }

  void _onSecondaryTapUp(TapUpDetails details) =>
      _controller.openMenu(_data.key, Rect.fromLTWH(details.globalPosition.dx, details.globalPosition.dy, 0, 0));

  void _enter(PointerEnterEvent event) => _controller.enter(_data.key, _hoverAreaAt(event.localPosition));

  void _exit(PointerExitEvent event) {
    _controller.leave(_data.key);
    _pointerOnMore = false;
    _pointerOnAdd = false;
  }

  @override
  MouseCursor get cursor => MouseCursor.defer;

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
    final GraphCardData d = _data;
    config
      ..isSemanticBoundary = true
      ..isButton = true
      ..isSelected = _selected
      ..identifier = 'graph-card-${d.key}'
      ..label = graphCardLabel(_strings, d, nowMs: _controller.now.value, detailed: _detailed)
      ..textDirection = TextDirection.ltr
      ..onTap = _semanticSelect
      ..customSemanticsActions = <CustomSemanticsAction, VoidCallback>{
        CustomSemanticsAction(label: _strings.cardActions): _semanticMenu,
        if (!d.isRoot)
          CustomSemanticsAction(
            label: d.refs.isEmpty
                ? _strings.cardAddBookmark
                : _strings.cardBookmarks(d.refs.map((r) => r.display).join(', ')),
          ): _semanticBookmarks,
        if (d.expandedRunSize case final int count)
          CustomSemanticsAction(label: _strings.stackCollapseTooltip(count)): _semanticCollapse,
      };
  }

  void _semanticSelect() => _controller.select(_data.key);

  void _semanticCollapse() => _controller.onCollapseStack?.call(_data.key);

  void _semanticMenu() => _controller.openMenu(_data.key, _global(_more));

  void _semanticBookmarks() {
    // As a tap on the pill or the add circle, ignored while the actions are disabled.
    if (!_controller.actionsEnabled.value) {
      return;
    }
    _controller.openBookmarks(_data.key, _global(_legend ?? _add ?? _card));
  }
}
