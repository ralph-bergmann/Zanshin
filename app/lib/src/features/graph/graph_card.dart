// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

import '../../l10n/strings.dart';
import 'day_axis.dart';
import 'graph_card_render.dart';
import 'graph_content.dart';
import 'graph_drag.dart';
import 'graph_layout.dart';

/// The double-click window (Story 10.6 item 2; the prototype's 220 ms, GV:550-558): a click selects only after it.
const graphDoubleClickWindow = Duration(milliseconds: 220);

/// The hover intent (Story 10.6, the 2026-10-14 note; GV:954-960): leaving a card clears the hover after it.
const graphHoverIntent = Duration(milliseconds: 140);

/// The part of a card under the pointer (Story 10.6): the body, or an affordance.
enum GraphCardHoverPart {
  /// The card body.
  body,

  /// The ••• circle.
  more,

  /// The bookmark control: the legend pill or the add circle.
  bookmarks,

  /// The `+N` tag of the folded workspaces.
  moreTag,
}

/// Where the pointer rests on the hovered card: the `part`, its `rect` relative to the card rect's top-left, and the
/// affordance's `tooltip` (null on the body).
typedef GraphCardHoverArea = ({GraphCardHoverPart part, Rect rect, String? tooltip});

/// The cards' interaction state (Story 10.3): one controller for the whole graph, read by every card through
/// listeners, so hover, selection, focus, an open menu and the minute tick build no card.
///
/// Story 10.6 adds the pointer model: [click] selects after [graphDoubleClickWindow], and a second click inside it runs
/// [onEdit] on an editable card instead; [enter] and [leave] keep [hovered] with [graphHoverIntent], [holdHover] keeps
/// it while the pointer is in the card's peek, [hoverEnabled] turns hover off (calm scrolling, an inactive window).
/// [openMenu] and [openBookmarks] record what the graph's menu hosts show (Story 10.15); 10.5 owns [now] in the app.
class GraphCardController {
  /// A controller whose "now" starts at [now] (epoch ms).
  GraphCardController({required int now}) : now = ValueNotifier<int>(now);

  /// The hovered card's key.
  final hovered = ValueNotifier<String?>(null);

  /// Where the pointer rests on the hovered card; null without a hover.
  final hoverArea = ValueNotifier<GraphCardHoverArea?>(null);

  /// The selected card's key.
  final selected = ValueNotifier<String?>(null);

  /// Counts the user's selections through [select] (a click, VoiceOver, the keyboard), so the canvas can reveal a
  /// covered card; the model's own selection changes do not count.
  final userSelections = ValueNotifier<int>(0);

  /// Runs `jj edit` for a double-clicked editable card.
  ValueChanged<String>? onEdit;

  /// Expands the stack card of the given key (Story 10.17: a click, Enter or Space, VoiceOver).
  ValueChanged<String>? onExpandStack;

  /// Collapses the expanded run the given member key belongs to (Story 10.17: VoiceOver's action on a member).
  ValueChanged<String>? onCollapseStack;

  Timer? _click;
  String? _clickKey;
  Timer? _leave;
  var _hoverEnabled = true;

  /// The key of the card that holds the keyboard focus (10.6's roving focus).
  final focused = ValueNotifier<String?>(null);

  /// The key of the card whose menu is open.
  final menuOpen = ValueNotifier<String?>(null);

  /// "Now" for the relative dates, in epoch ms.
  final ValueNotifier<int> now;

  /// Whether the card affordances act; false paints them at `--disabled-opacity` and ignores their taps.
  final actionsEnabled = ValueNotifier<bool>(true);

  /// Selects [key] and closes an open menu.
  void select(String key) {
    cancelClick();
    selected.value = key;
    closeMenus();
    userSelections.value++;
  }

  /// A primary click on [key]'s body: it selects after [graphDoubleClickWindow]; a second click on the same card
  /// inside it cancels the select and, when [editable], runs [onEdit] (design question (a): an immutable card does
  /// nothing). A click on another card selects the pending one at once.
  void click(String key, {required bool editable}) {
    final Timer? pending = _click;
    _click = null;
    if (pending != null && pending.isActive) {
      pending.cancel();
      if (_clickKey == key) {
        if (editable) {
          onEdit?.call(key);
        }
        return;
      }
      select(_clickKey!);
    }
    _clickKey = key;
    _click = Timer(graphDoubleClickWindow, () {
      _click = null;
      select(key);
    });
  }

  /// Drops a click still waiting for its double-click window (Esc, another select).
  void cancelClick() {
    _click?.cancel();
    _click = null;
  }

  /// Whether hover is taken; turning it off clears the hover.
  bool get hoverEnabled => _hoverEnabled;
  set hoverEnabled(bool value) {
    _hoverEnabled = value;
    if (!value) {
      _leave?.cancel();
      _leave = null;
      hovered.value = null;
      hoverArea.value = null;
    }
  }

  /// The pointer is on [key] at [area]: it becomes the hover at once (a pending leave is cancelled).
  void enter(String key, GraphCardHoverArea area) {
    _leave?.cancel();
    _leave = null;
    if (!_hoverEnabled) {
      return;
    }
    hovered.value = key;
    hoverArea.value = area;
  }

  /// The pointer left [key] (its card or its peek): the hover clears after [graphHoverIntent] unless the pointer
  /// enters a card or the peek first.
  void leave(String key) {
    if (hovered.value != key) {
      return;
    }
    _leave?.cancel();
    _leave = Timer(graphHoverIntent, () {
      _leave = null;
      if (hovered.value == key) {
        hovered.value = null;
        hoverArea.value = null;
      }
    });
  }

  /// The pointer entered the hovered card's peek: the hover stays.
  void holdHover() {
    _leave?.cancel();
    _leave = null;
  }

  /// Where the open card menu hangs (global): the ••• circle, or a zero-size box at the pointer for a right-click.
  Rect? menuAnchor;

  /// The key of the card whose bookmark popover is open (Story 10.15).
  final bookmarksOpen = ValueNotifier<String?>(null);

  /// Where the open bookmark popover hangs (global): the card's bookmark control.
  Rect? bookmarksAnchor;

  /// Opens [key]'s card menu at [anchor] (global), or closes it when it is open; an open bookmark popover closes.
  void openMenu(String key, Rect anchor) {
    if (menuOpen.value == key) {
      menuOpen.value = null;
      return;
    }
    bookmarksOpen.value = null;
    menuAnchor = anchor;
    menuOpen.value = key;
  }

  /// Opens [key]'s bookmark popover at [anchor] (global), or closes it when it is open; an open card menu closes.
  void openBookmarks(String key, Rect anchor) {
    if (bookmarksOpen.value == key) {
      bookmarksOpen.value = null;
      return;
    }
    menuOpen.value = null;
    bookmarksAnchor = anchor;
    bookmarksOpen.value = key;
  }

  /// Closes the card menu and the bookmark popover.
  void closeMenus() {
    menuOpen.value = null;
    bookmarksOpen.value = null;
  }

  /// The graph's drag (Story 10.10): a card body or its legend pill starts it past the drag threshold; null drags
  /// nothing.
  GraphDrag? drag;

  /// The highlighted drop target's key (Story 10.10): that card paints the drop look.
  final dropTarget = ValueNotifier<String?>(null);

  /// Releases the notifiers.
  void dispose() {
    _disposed = true;
    _click?.cancel();
    _leave?.cancel();
    hovered.dispose();
    hoverArea.dispose();
    selected.dispose();
    userSelections.dispose();
    focused.dispose();
    menuOpen.dispose();
    bookmarksOpen.dispose();
    dropTarget.dispose();
    now.dispose();
    actionsEnabled.dispose();
  }

  var _disposed = false;

  /// Whether [dispose] ran; a card's deferred hover reset checks it.
  bool get isDisposed => _disposed;
}

/// A node's id as a command shows it (`graphShortId`): max(jj's unique [prefix], 8) of the [changeId]; a hidden or
/// divergent node's [key] is its commit id.
String graphShortIdOf({required String key, required String changeId, required int prefix}) {
  if (key != changeId) {
    // shortcut: 12 hex digits as jj's `commit_id.short()`, not the commit's unique prefix (the layout has none).
    return key.substring(0, math.min(12, key.length));
  }
  return changeId.substring(0, math.min(changeId.length, math.max(prefix, 8)));
}

/// The drag of the change [d] shows (Story 10.10): its key, id, subject and @, and its id as a command shows it.
GraphChangeDrag graphChangeDragOf(GraphCardData d) => GraphChangeDrag(
  key: d.key,
  changeId: d.changeId,
  prefix: d.prefixLength,
  short: graphShortIdOf(key: d.key, changeId: d.changeId, prefix: d.prefixLength),
  subject: d.content?.subject ?? '',
  workingCopy: d.isWorkingCopy,
);

/// The facts one card shows (Story 10.3), read from its layout once per build.
@immutable
class GraphCardData {
  /// The facts, given; the app uses [GraphCardData.of].
  const GraphCardData({
    required this.key,
    required this.changeId,
    required this.prefixLength,
    this.commitId,
    this.commitPrefixLength = 0,
    this.changeOffset,
    this.isRoot = false,
    this.isWorkingCopy = false,
    this.immutable = false,
    this.hidden = false,
    this.divergent = false,
    this.merge = false,
    this.timestampMs,
    this.utcOffsetMinutes = 0,
    this.refs = const <GraphRef>[],
    this.workingCopies = const <String>[],
    this.workspaceName,
    this.content,
    this.expandedRunSize,
  });

  /// The facts of [node] in [layout]; the content is [content]'s cache entry, else the layout's own (Story 10.11), and
  /// the date the layout's timestamp, else the content's.
  factory GraphCardData.of(GraphLayout layout, int node, {GraphContent? content}) {
    final isRoot = node == layout.rootIndex;
    final GraphCommitContent? loaded = content == null ? layout.contentOf(node) : content.of(layout, node);
    final int? run = layout.runOf(node);
    return GraphCardData(
      expandedRunSize: run != null && layout.stackNodeOf(run) == null ? layout.runMembersOf(run).length : null,
      key: layout.keyOf(node),
      changeId: layout.changeIdOf(node),
      prefixLength: layout.changeIdPrefixLengthOf(node),
      commitId: layout.isStackNode(node) ? null : layout.commitIdOf(node),
      commitPrefixLength: layout.commitIdPrefixLengthOf(node),
      changeOffset: layout.changeOffsetOf(node),
      isRoot: isRoot,
      isWorkingCopy: node == layout.workingCopyIndex,
      immutable: isRoot || layout.isImmutable(node),
      hidden: layout.isHidden(node),
      divergent: layout.isDivergent(node),
      // Missing parents included (10.1 item 2): the edge count would drop a merge whose other parent is outside.
      merge: layout.parentCountOf(node) >= 2,
      timestampMs: layout.timestampOf(node) ?? loaded?.timestampMs,
      utcOffsetMinutes: layout.utcOffsetMinutes,
      refs: layout.refsOf(node),
      workingCopies: layout.workingCopiesOf(node),
      workspaceName: layout.workspaceName,
      content: loaded,
    );
  }

  /// The node key.
  final String key;

  /// The full change id.
  final String changeId;

  /// jj's shortest unique prefix length.
  final int prefixLength;

  /// The full commit id; null for a stack node.
  final String? commitId;

  /// jj's shortest unique commit-id prefix length; 0 when the layout carries none.
  final int commitPrefixLength;

  /// jj's change offset, when hidden or divergent.
  final int? changeOffset;

  /// Whether this is `root()`.
  final bool isRoot;

  /// Whether this is our workspace's `@`.
  final bool isWorkingCopy;

  /// Whether the commit is immutable (the root is).
  final bool immutable;

  /// Whether the commit is hidden.
  final bool hidden;

  /// Whether the change is divergent.
  final bool divergent;

  /// Whether the commit has two or more parents.
  final bool merge;

  /// The committer timestamp, epoch ms.
  final int? timestampMs;

  /// The layout's fixed UTC offset, in minutes.
  final int utcOffsetMinutes;

  /// The bookmarks, in jj's order.
  final List<GraphRef> refs;

  /// jj's `working_copies()` names.
  final List<String> workingCopies;

  /// Our workspace's name.
  final String? workspaceName;

  /// The content, null until loaded.
  final GraphCommitContent? content;

  /// The member count of the expanded run this change belongs to (Story 10.17), else null.
  final int? expandedRunSize;

  /// The other workspaces whose working copy this is, by name.
  List<String> get otherWorkspaces => <String>[
    for (final String name in workingCopies)
      if (!isWorkingCopy || name != workspaceName) name,
  ]..sort();

  /// The id as the card shows it (jj's `shortest(n)`, commit_templater.rs:2295-2321 @ v0.46.0): the bold prefix, the
  /// dim rest up to max(prefix, 8) on a detailed non-@ card and max(prefix, 5) otherwise, then jj's `/offset`.
  ({String prefix, String rest, String offset}) idParts({required bool detailed}) {
    final shown = detailed && !isWorkingCopy ? 8 : 5;
    final int prefix = prefixLength.clamp(0, changeId.length);
    final int total = (prefix > shown ? prefix : shown).clamp(0, changeId.length);
    return (
      prefix: changeId.substring(0, prefix),
      rest: changeId.substring(prefix, total),
      offset: changeOffset == null ? '' : '/$changeOffset',
    );
  }

  /// The author as the card shows it (Claude's proposal (d)): the first word of the name — of the part after the comma
  /// for a "Last, First" name (directory-style git identities) — else the email's local part, else null.
  String? get author {
    final GraphCommitContent? content = this.content;
    if (content == null) {
      return null;
    }
    return graphAuthorShort(content.authorName, content.authorEmail);
  }
}

/// An author's short form (cards, search suggestions): the first word of [name] — of the part after the comma for a
/// "Last, First" name (directory-style git identities) — else [email]'s local part, else null.
String? graphAuthorShort(String name, [String email = '']) {
  final String full = name.trim();
  final int comma = full.indexOf(',');
  final String given = comma < 0 ? full : full.substring(comma + 1).trim();
  final String first = (given.isEmpty ? full.replaceAll(',', '') : given).trim().split(RegExp(r'\s+')).first;
  if (first.isNotEmpty) {
    return first;
  }
  final String local = email.split('@').first.trim();
  return local.isEmpty ? null : local;
}

const _minuteMs = 60000;
const _hourMs = 3600000;
const _dayMs = 86400000;

/// The relative committer time a card shows in [strings] (Story 10.3, Claude's proposal (h)), against [nowMs]: "now"
/// under a minute and in the future, then for today "Nm" under an hour, else "Nh"; before today "Nd" in calendar days
/// (1d = yesterday, matching the day axis) under a week, else the day as [graphDayLabel] writes it for a card ("Sep 19",
/// "Sep 19, 2025" in another year) at the layout's offset.
String graphRelativeDate(AppLocalizations strings, int tsMs, {required int nowMs, required int utcOffsetMinutes}) {
  final int age = nowMs - tsMs;
  if (age < _minuteMs) {
    return strings.relativeNow;
  }
  final int days = _calendarDaysAgo(tsMs, nowMs, utcOffsetMinutes);
  if (days == 0) {
    return age < _hourMs ? strings.relativeMinutes(age ~/ _minuteMs) : strings.relativeHours(age ~/ _hourMs);
  }
  if (days < 7) {
    return strings.relativeDays(days);
  }
  return graphDayLabel(
    strings,
    graphLocalDay(tsMs, utcOffsetMinutes: utcOffsetMinutes),
    nowMs: nowMs,
    utcOffsetMinutes: utcOffsetMinutes,
    withYear: true,
  );
}

/// [graphRelativeDate] as VoiceOver speaks it: "now", "N minutes ago", "N hours ago", "N days ago", else the same
/// day form.
String _spokenRelativeDate(AppLocalizations strings, int tsMs, {required int nowMs, required int utcOffsetMinutes}) {
  final int age = nowMs - tsMs;
  if (age < _minuteMs) {
    return strings.relativeNow;
  }
  final int days = _calendarDaysAgo(tsMs, nowMs, utcOffsetMinutes);
  if (days == 0) {
    return age < _hourMs ? strings.spokenMinutesAgo(age ~/ _minuteMs) : strings.spokenHoursAgo(age ~/ _hourMs);
  }
  if (days < 7) {
    return strings.spokenDaysAgo(days);
  }
  return graphRelativeDate(strings, tsMs, nowMs: nowMs, utcOffsetMinutes: utcOffsetMinutes);
}

/// How many local calendar days [tsMs] lies before [nowMs] at the fixed offset: 0 today, 1 yesterday.
int _calendarDaysAgo(int tsMs, int nowMs, int utcOffsetMinutes) =>
    (graphLocalDay(nowMs, utcOffsetMinutes: utcOffsetMinutes) -
        graphLocalDay(tsMs, utcOffsetMinutes: utcOffsetMinutes)) ~/
    _dayMs;

/// The local midnight (epoch ms) of the day [tsMs] falls in, at the fixed offset [utcOffsetMinutes].
int graphLocalDay(int tsMs, {required int utcOffsetMinutes}) {
  final int off = utcOffsetMinutes * _minuteMs;
  final int local = tsMs + off;
  return local - local % _dayMs - off;
}

/// A bookmark legend's parts (DS components/graph/BookmarkChip.jsx:5-12; epics.md:8903-8909): a ticket key
/// `[A-Z][A-Z0-9]+-\d+` at a word start leads with the rest (its `_-/.` lead trimmed) after it; otherwise the prefix path, then the
/// last segment. `remote` is `@remote` or empty, `sigil` jj's `??` / `*`.
({String prefix, String main, String remote, String sigil, String rest}) graphLegendParts(GraphRef ref) {
  // jj's CommitRef prints both as revset symbols (quoted when not an identifier), as [GraphRef.display] does.
  final String base = jjRevsetSymbol(ref.name);
  final remote = ref.remote == null ? '' : '@${jjRevsetSymbol(ref.remote!)}';
  final sigil = ref.conflicted
      ? '??'
      : ref.remote == null && !ref.synced
      ? '*'
      : '';
  final RegExpMatch? ticket = RegExp(r'(?<![A-Za-z0-9])[A-Z][A-Z0-9]+-\d+').firstMatch(base);
  if (ticket != null) {
    final String rest = base.substring(ticket.end).replaceFirst(RegExp(r'^[_\-/.]+'), '');
    return (prefix: '', main: ticket[0]!, remote: remote, sigil: sigil, rest: rest);
  }
  final int slash = base.lastIndexOf('/');
  if (slash >= 0) {
    return (
      prefix: base.substring(0, slash + 1),
      main: base.substring(slash + 1),
      remote: remote,
      sigil: sigil,
      rest: '',
    );
  }
  return (prefix: '', main: base, remote: remote, sigil: sigil, rest: '');
}

/// A card's VoiceOver label (Story 10.3 item 11; DS components/graph/ChangeCard.jsx:39):
/// `[Working copy[ of ours], ][working copy of others, ][Immutable, ]subject, id, author, date[, empty][, conflict]
/// [, merge][, hidden | , divergent]`. The root leaves "Immutable, " out; without content the subject and the author
/// are left out. The date is spoken ("40 minutes ago", not the card's "40m"), then ", day label" unless the spoken
/// text is the day label.
String graphCardLabel(AppLocalizations strings, GraphCardData data, {required int nowMs, bool detailed = true}) {
  final GraphCommitContent? content = data.content;
  final List<String> others = data.otherWorkspaces;
  final (:String prefix, :String rest, :String offset) = data.idParts(detailed: detailed);
  final int? ts = data.timestampMs;
  final int off = data.utcOffsetMinutes;
  final String? relative = ts == null ? null : _spokenRelativeDate(strings, ts, nowMs: nowMs, utcOffsetMinutes: off);
  final String? day = ts == null
      ? null
      : graphDayLabel(
          strings,
          graphLocalDay(ts, utcOffsetMinutes: off),
          nowMs: nowMs,
          utcOffsetMinutes: off,
          withYear: true,
        );
  final String? author = data.author;
  final String? workspace = data.workspaceName;
  return <String>[
    if (data.isWorkingCopy && data.workingCopies.isNotEmpty && workspace != null)
      strings.cardWorkingCopyOf(workspace)
    else if (data.isWorkingCopy)
      strings.cardWorkingCopy,
    if (others.isNotEmpty) strings.cardOtherWorkingCopy(others.join(', ')),
    if (data.immutable && !data.isRoot) strings.cardImmutable,
    if (data.isRoot)
      'root()' // l10n-ignore: jj's text
    else if (content != null && content.subject.isEmpty)
      strings.cardNoDescription
    else if (content != null)
      content.subject,
    '$prefix$rest$offset',
    ?author,
    if (relative != null && relative == day) relative else if (relative != null) '$relative, $day',
    if (content?.empty ?? false) strings.cardEmpty,
    if (content?.conflict ?? false) strings.cardConflict,
    if (data.merge) strings.cardMerge,
    if (data.hidden) strings.cardHidden else if (data.divergent) strings.cardDivergent,
  ].join(', ');
}

/// The glyphs a card paints, from the [IconRegistryScope] (null paints nothing).
typedef GraphCardIcons = ({
  ui.Picture? bookmark,
  ui.Picture? bookmarkFilled,
  ui.Picture? more,
  ui.Picture? conflict,
  ui.Picture? merge,
});

/// A shown skeleton bar (Story 10.11): its sweep and its `--skeleton` / `--skeleton-hi` colours.
typedef GraphCardSkeleton = ({Animation<double> sweep, Color base, Color high});

/// One commit card (Story 10.3): the detailed (62) or compact (40) card, drawn by one leaf [RenderGraphCard] in the
/// box the viewport gives it — the card rect inflated by `graphCardOverhang` on every side.
///
/// Hover, selection, focus, an open menu, [GraphCardController.actionsEnabled] and the minute tick reach the render
/// object through listeners and build nothing; the State owns the affordances' reveal animation and, with a [content]
/// loader (Story 10.11), the skeleton: a non-root card still without content paints a skeleton bar in its subject slot
/// once `--delay-skeleton` has passed, swept every `--dur-shimmer`, and rebuilds when its entry arrives.
class GraphCard extends StatefulWidget {
  /// The card of [node] in [layout].
  const GraphCard({required this.layout, required this.node, required this.controller, this.content, super.key});

  /// The layout [node] belongs to.
  final GraphLayout layout;

  /// The node shown.
  final int node;

  /// The graph's card controller.
  final GraphCardController controller;

  /// The content cache; null shows the layout's own content and never a skeleton.
  final GraphContent? content;

  @override
  State<GraphCard> createState() => _GraphCardState();
}

class _GraphCardState extends State<GraphCard> with TickerProviderStateMixin {
  late final _reveal = AnimationController(vsync: this, duration: ZsMotion.full.durHover);
  late final _sweep = AnimationController(vsync: this, duration: ZsMotion.full.durShimmer);
  var _inactive = false;
  Duration _delaySkeleton = ZsMotion.full.delaySkeleton;
  Timer? _skeletonWait;
  var _skeletonShown = false;
  GraphCommitContent? _content;

  String get _key => widget.layout.keyOf(widget.node);

  GraphCommitContent? _contentNow() => widget.content?.of(widget.layout, widget.node);

  /// Whether this card waits for its content: a loader exists, it is not the root, and nothing has arrived.
  bool get _waiting => widget.content != null && widget.node != widget.layout.rootIndex && _contentNow() == null;

  /// Starts the skeleton delay while the card waits, ends the skeleton once it does not.
  void _syncSkeleton() {
    if (!_waiting) {
      _skeletonWait?.cancel();
      _skeletonWait = null;
      if (_skeletonShown) {
        _skeletonShown = false;
        _sweep.stop();
      }
      return;
    }
    if (!_skeletonShown && _skeletonWait == null) {
      _skeletonWait = Timer(_delaySkeleton, () {
        _skeletonWait = null;
        if (mounted && _waiting) {
          setState(() => _skeletonShown = true);
          _sweep.repeat();
        }
      });
    }
  }

  void _contentChanged() {
    if (!identical(_contentNow(), _content)) {
      setState(_syncSkeleton);
    }
  }

  bool get _revealed {
    final GraphCardController c = widget.controller;
    final String key = _key;
    return (!_inactive && c.hovered.value == key) || c.focused.value == key || c.menuOpen.value == key;
  }

  @override
  void initState() {
    super.initState();
    _listen(widget.controller);
    widget.content?.addListener(_contentChanged);
  }

  @override
  void didUpdateWidget(GraphCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      _unlisten(oldWidget.controller);
      _listen(widget.controller);
    }
    if (!identical(oldWidget.content, widget.content)) {
      oldWidget.content?.removeListener(_contentChanged);
      widget.content?.addListener(_contentChanged);
    }
    _update();
    _syncSkeleton();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _inactive = ZsAppearance.maybeOf(context)?.inactive ?? false;
    final ZsMotion motion = ZsMotion.of(context);
    _reveal.duration = motion.durHover;
    _sweep.duration = motion.durShimmer;
    _delaySkeleton = motion.delaySkeleton;
    _update();
    _syncSkeleton();
  }

  void _listen(GraphCardController c) {
    c.hovered.addListener(_update);
    c.focused.addListener(_update);
    c.menuOpen.addListener(_update);
  }

  void _unlisten(GraphCardController c) {
    c.hovered.removeListener(_update);
    c.focused.removeListener(_update);
    c.menuOpen.removeListener(_update);
  }

  void _update() {
    if (_revealed) {
      _reveal.forward();
    } else {
      _reveal.reverse();
    }
  }

  @override
  void dispose() {
    _unlisten(widget.controller);
    widget.content?.removeListener(_contentChanged);
    _skeletonWait?.cancel();
    _reveal.dispose();
    _sweep.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final IconRegistry? registry = IconRegistryScope.maybeOf(context);
    final data = GraphCardData.of(widget.layout, widget.node, content: widget.content);
    _content = widget.content == null ? null : data.content;
    final ZsColors colors = ZsColors.of(context);
    return _GraphCardLeaf(
      data: data,
      skeleton: _skeletonShown ? (sweep: _sweep, base: colors.skeleton, high: colors.skeletonHi) : null,
      theme: GraphTheme.of(context),
      elevation: ZsElevation.of(context),
      metrics: ZsMetrics.of(context),
      motion: ZsMotion.of(context),
      inactive: _inactive,
      icons: (
        bookmark: registry?[ZI.bookmark]?.picture,
        bookmarkFilled: registry?[ZI.bookmarkFilled]?.picture,
        more: registry?[ZI.more]?.picture,
        conflict: registry?[ZI.conflict]?.picture,
        merge: registry?[ZI.merge]?.picture,
      ),
      strings: context.l10n,
      controller: widget.controller,
      reveal: _reveal,
    );
  }
}

class _GraphCardLeaf extends LeafRenderObjectWidget {
  const _GraphCardLeaf({
    required this.data,
    required this.skeleton,
    required this.theme,
    required this.elevation,
    required this.metrics,
    required this.motion,
    required this.inactive,
    required this.icons,
    required this.strings,
    required this.controller,
    required this.reveal,
  });

  final GraphCardData data;
  final GraphCardSkeleton? skeleton;
  final GraphTheme theme;
  final ZsElevation elevation;
  final ZsMetrics metrics;
  final ZsMotion motion;
  final bool inactive;
  final GraphCardIcons icons;
  final AppLocalizations strings;
  final GraphCardController controller;
  final Animation<double> reveal;

  @override
  RenderGraphCard createRenderObject(BuildContext context) => RenderGraphCard(
    data: data,
    skeleton: skeleton,
    theme: theme,
    elevation: elevation,
    metrics: metrics,
    motion: motion,
    inactive: inactive,
    icons: icons,
    strings: strings,
    controller: controller,
    reveal: reveal,
  );

  @override
  void updateRenderObject(BuildContext context, RenderGraphCard renderObject) => renderObject
    ..data = data
    ..skeleton = skeleton
    ..theme = theme
    ..elevation = elevation
    ..metrics = metrics
    ..motion = motion
    ..inactive = inactive
    ..icons = icons
    ..strings = strings
    ..controller = controller
    ..reveal = reveal;
}
