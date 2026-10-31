// SPDX-License-Identifier: MIT

import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

import '../../l10n/strings.dart';
import 'day_axis.dart';
import 'graph_card_render.dart';
import 'graph_layout.dart';

/// The cards' interaction state (Story 10.3): one controller for the whole graph, read by every card through
/// listeners, so hover, selection, focus, an open menu and the minute tick build no card.
///
/// 10.6 drives [hovered] beyond the card, [focused] and the keyboard; 10.15 overrides [openMenu] and [openBookmarks];
/// 10.5 owns [now] in the app.
class GraphCardController {
  /// A controller whose "now" starts at [now] (epoch ms).
  GraphCardController({required int now}) : now = ValueNotifier<int>(now);

  /// The hovered card's key.
  final hovered = ValueNotifier<String?>(null);

  /// The selected card's key.
  final selected = ValueNotifier<String?>(null);

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
    selected.value = key;
    menuOpen.value = null;
  }

  /// Opens [key]'s card menu at [anchor] (global), or closes it when it is open.
  void openMenu(String key, Rect anchor) => menuOpen.value = menuOpen.value == key ? null : key;

  /// Opens [key]'s bookmark popover at [anchor] (global); 10.15 builds it.
  void openBookmarks(String key, Rect anchor) {}

  /// Releases the notifiers.
  void dispose() {
    _disposed = true;
    hovered.dispose();
    selected.dispose();
    focused.dispose();
    menuOpen.dispose();
    now.dispose();
    actionsEnabled.dispose();
  }

  var _disposed = false;

  /// Whether [dispose] ran; a card's deferred hover reset checks it.
  bool get isDisposed => _disposed;
}

/// The facts one card shows (Story 10.3), read from its layout once per build.
@immutable
class GraphCardData {
  /// The facts, given; the app uses [GraphCardData.of].
  const GraphCardData({
    required this.key,
    required this.changeId,
    required this.prefixLength,
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
  });

  /// The facts of [node] in [layout].
  factory GraphCardData.of(GraphLayout layout, int node) {
    final isRoot = node == layout.rootIndex;
    return GraphCardData(
      key: layout.keyOf(node),
      changeId: layout.changeIdOf(node),
      prefixLength: layout.changeIdPrefixLengthOf(node),
      changeOffset: layout.changeOffsetOf(node),
      isRoot: isRoot,
      isWorkingCopy: node == layout.workingCopyIndex,
      immutable: isRoot || layout.isImmutable(node),
      hidden: layout.isHidden(node),
      divergent: layout.isDivergent(node),
      // Missing parents included (10.1 item 2): the edge count would drop a merge whose other parent is outside.
      merge: layout.parentCountOf(node) >= 2,
      timestampMs: layout.timestampOf(node),
      utcOffsetMinutes: layout.utcOffsetMinutes,
      refs: layout.refsOf(node),
      workingCopies: layout.workingCopiesOf(node),
      workspaceName: layout.workspaceName,
      content: layout.contentOf(node),
    );
  }

  /// The node key.
  final String key;

  /// The full change id.
  final String changeId;

  /// jj's shortest unique prefix length.
  final int prefixLength;

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

  /// The author as the card shows it (Claude's proposal (d)): the first word of the name, else the email's local
  /// part, else null.
  String? get author {
    final GraphCommitContent? content = this.content;
    if (content == null) {
      return null;
    }
    final String first = content.authorName.trim().split(RegExp(r'\s+')).first;
    if (first.isNotEmpty) {
      return first;
    }
    final String local = content.authorEmail.split('@').first.trim();
    return local.isEmpty ? null : local;
  }
}

const _minuteMs = 60000;
const _hourMs = 3600000;
const _dayMs = 86400000;

/// The relative committer time a card shows in [strings] (Story 10.3, Claude's proposal (h)), against [nowMs]: "now"
/// under a minute and in the future, "Nm" under an hour, "Nh" under a day, "Nd" under a week, else the day as
/// [graphDayLabel] writes it ("Sep 19", "Sep 19, 2025" in another year) at the layout's offset.
String graphRelativeDate(AppLocalizations strings, int tsMs, {required int nowMs, required int utcOffsetMinutes}) {
  final int age = nowMs - tsMs;
  if (age < _minuteMs) {
    return strings.relativeNow;
  }
  if (age < _hourMs) {
    return strings.relativeMinutes(age ~/ _minuteMs);
  }
  if (age < _dayMs) {
    return strings.relativeHours(age ~/ _hourMs);
  }
  if (age < 7 * _dayMs) {
    return strings.relativeDays(age ~/ _dayMs);
  }
  return graphDayLabel(
    strings,
    graphLocalDay(tsMs, utcOffsetMinutes: utcOffsetMinutes),
    nowMs: nowMs,
    utcOffsetMinutes: utcOffsetMinutes,
  );
}

/// [graphRelativeDate] as VoiceOver speaks it: "now", "N minutes ago", "N hours ago", "N days ago", else the same
/// day form.
String _spokenRelativeDate(AppLocalizations strings, int tsMs, {required int nowMs, required int utcOffsetMinutes}) {
  final int age = nowMs - tsMs;
  if (age < _minuteMs) {
    return strings.relativeNow;
  }
  if (age < _hourMs) {
    return strings.spokenMinutesAgo(age ~/ _minuteMs);
  }
  if (age < _dayMs) {
    return strings.spokenHoursAgo(age ~/ _hourMs);
  }
  if (age < 7 * _dayMs) {
    return strings.spokenDaysAgo(age ~/ _dayMs);
  }
  return graphRelativeDate(strings, tsMs, nowMs: nowMs, utcOffsetMinutes: utcOffsetMinutes);
}

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

/// One commit card (Story 10.3): the detailed (62) or compact (40) card, drawn by one leaf [RenderGraphCard] in the
/// box the viewport gives it — the card rect inflated by `graphCardOverhang` on every side.
///
/// Hover, selection, focus, an open menu, [GraphCardController.actionsEnabled] and the minute tick reach the render
/// object through listeners and build nothing; the State owns only the affordances' reveal animation.
class GraphCard extends StatefulWidget {
  /// The card of [node] in [layout].
  const GraphCard({required this.layout, required this.node, required this.controller, super.key});

  /// The layout [node] belongs to.
  final GraphLayout layout;

  /// The node shown.
  final int node;

  /// The graph's card controller.
  final GraphCardController controller;

  @override
  State<GraphCard> createState() => _GraphCardState();
}

class _GraphCardState extends State<GraphCard> with SingleTickerProviderStateMixin {
  late final _reveal = AnimationController(vsync: this, duration: ZsMotion.full.durHover);
  var _inactive = false;

  String get _key => widget.layout.keyOf(widget.node);

  bool get _revealed {
    final GraphCardController c = widget.controller;
    final String key = _key;
    return (!_inactive && c.hovered.value == key) || c.focused.value == key || c.menuOpen.value == key;
  }

  @override
  void initState() {
    super.initState();
    _listen(widget.controller);
  }

  @override
  void didUpdateWidget(GraphCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      _unlisten(oldWidget.controller);
      _listen(widget.controller);
    }
    _update();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _inactive = ZsAppearance.maybeOf(context)?.inactive ?? false;
    _reveal.duration = ZsMotion.of(context).durHover;
    _update();
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
    _reveal.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final IconRegistry? registry = IconRegistryScope.maybeOf(context);
    return _GraphCardLeaf(
      data: GraphCardData.of(widget.layout, widget.node),
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
