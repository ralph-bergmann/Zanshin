// SPDX-License-Identifier: MIT

import 'dart:math' as math;
import 'dart:ui' show Tristate;

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/src/features/graph/graph_card.dart';
import 'package:zanshin/src/features/graph/graph_card_render.dart';
import 'package:zanshin/src/features/graph/graph_layout.dart';
import 'package:zanshin/src/features/graph/graph_metrics.dart';
import 'package:zanshin/src/features/graph/graph_viewport.dart';
import 'package:zanshin/src/features/graph/hatch_swatch.dart';
import 'package:zanshin/src/features/graph/recorded_graph_layout.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

import '../../../widgetbook/graph/graph_recordings.g.dart';
import '../../helpers/icon_registry.dart';
import 'graph_harness.dart';

final macOS = TargetPlatformVariant.only(TargetPlatform.macOS);

// Sep 28 2026, 12:00 UTC.
const _now = 1790596800000;
const _minute = 60000;
const int _hour = 60 * _minute;
const int _day = 24 * _hour;

const _content = GraphCommitContent(subject: 'feat: swipe gestures', authorName: 'Ralph Stein');

const int _imm = RecordedGraphLayout.flagImmutable;

/// A one-node layout with the given card facts.
RecordedGraphLayout one({
  String id = 'kxwsnptmqrvl',
  int prefix = 3,
  int? offset,
  bool workingCopy = false,
  bool root = false,
  int flags = 0,
  List<GraphRef> refs = const <GraphRef>[],
  List<String> workspaces = const <String>[],
  String? workspaceName,
  GraphCommitContent? content = _content,
  int? ts = _now - 40 * _minute,
  int parents = 1,
}) => handLayout(
  <(String, int, int)>[(id, 0, 0)],
  workingCopy: workingCopy ? 0 : null,
  root: root ? 0 : null,
  timestamps: <int?>[ts],
  refs: <List<GraphRef>>[refs],
  contents: <GraphCommitContent?>[content],
  flags: <int>[flags],
  prefixLengths: <int>[prefix],
  offsets: <int?>[offset],
  workspaces: <List<String>>[workspaces],
  workspaceName: workspaceName,
  parentCounts: <int>[parents],
);

/// Records the controller's calls.
class RecordingController extends GraphCardController {
  RecordingController({super.now = _now});

  final calls = <(String, String, Rect)>[];

  @override
  void select(String key) {
    calls.add(('select', key, Rect.zero));
    super.select(key);
  }

  @override
  void openMenu(String key, Rect anchor) {
    calls.add(('menu', key, anchor));
    super.openMenu(key, anchor);
  }

  @override
  void openBookmarks(String key, Rect anchor) => calls.add(('bookmarks', key, anchor));
}

/// Where a standalone card's box sits on screen.
const _at = Offset(20, 20);

Future<RenderGraphCard> pumpCard(
  WidgetTester tester,
  GraphLayout layout,
  GraphCardController controller, {
  double width = 240,
  bool detailed = true,
  ZsAppearance appearance = const ZsAppearance(),
}) async {
  tester.view
    ..physicalSize = surface
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    IconRegistryScope(
      registry: testIconRegistry,
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: ZsRoot(
          appearance: appearance,
          child: Align(
            alignment: Alignment.topLeft,
            child: Padding(
              padding: EdgeInsets.only(left: _at.dx, top: _at.dy),
              child: SizedBox(
                width: width + 2 * graphCardOverhang,
                height: (detailed ? 62 : 40) + 2 * graphCardOverhang,
                child: GraphCard(layout: layout, node: 0, controller: controller),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  return tester.renderObject<RenderGraphCard>(find.byType(GraphCard));
}

List<GraphCardSlot> kinds(RenderGraphCard card) => <GraphCardSlot>[
  for (final slot in card.debugSlots)
    if (slot.kind.index <= GraphCardSlot.merge.index) slot.kind,
];

String? textOf(RenderGraphCard card, GraphCardSlot kind) =>
    card.debugSlots.where((slot) => slot.kind == kind).map((slot) => slot.text).firstOrNull;

List<String?> textsOf(RenderGraphCard card, GraphCardSlot kind) => <String?>[
  for (final slot in card.debugSlots.where((slot) => slot.kind == kind)) slot.text,
];

Rect rectOf(RenderGraphCard card, GraphCardSlot kind) => card.debugSlots.firstWhere((slot) => slot.kind == kind).rect;

/// No content slot reaches past the card's padding box.
void expectNoOverflow(RenderGraphCard card) {
  final Rect box = card.cardRect.deflate(12);
  for (final ({GraphCardSlot kind, Rect rect, TextStyle? style, String? text}) slot in card.debugSlots) {
    if (slot.kind.index <= GraphCardSlot.merge.index) {
      expect(slot.rect.left, greaterThanOrEqualTo(box.left - 1e-6), reason: '${slot.kind}');
      expect(slot.rect.right, lessThanOrEqualTo(box.right + 1e-6), reason: '${slot.kind}');
    }
  }
}

/// Every drawRRect / drawOval / drawLine / scale call the card paints.
List<(Symbol, List<dynamic>)> paintCalls(RenderGraphCard card) {
  final calls = <(Symbol, List<dynamic>)>[];
  expect(
    card,
    paints..everything((method, arguments) {
      calls.add((method, arguments));
      return true;
    }),
  );
  return calls;
}

/// The painted rrects with their colours as ARGB (a [Paint] stores its colour in 32 bits).
List<(RRect, int)> rrects(List<(Symbol, List<dynamic>)> calls) => <(RRect, int)>[
  for (final (Symbol method, List<dynamic> args) in calls)
    if (method == #drawRRect) (args[0] as RRect, (args[1] as Paint).color.toARGB32()),
];

List<int> lineColors(List<(Symbol, List<dynamic>)> calls) => <int>[
  for (final (Symbol method, List<dynamic> args) in calls)
    if (method == #drawLine) (args[2] as Paint).color.toARGB32(),
];

/// A viewport of GraphCards over [layout], counting the card builds.
final class Host {
  Host(this.layout, this.controller);

  final GraphLayout layout;
  final GraphCardController controller;
  final v = ScrollController();
  final h = ScrollController();
  var builds = 0;

  Widget card(BuildContext context, int node) {
    builds++;
    return GraphCard(layout: layout, node: node, controller: controller);
  }

  Future<void> pump(WidgetTester tester) async {
    tester.view
      ..physicalSize = surface
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    addTearDown(v.dispose);
    addTearDown(h.dispose);
    await tester.pumpWidget(
      IconRegistryScope(
        registry: testIconRegistry,
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: ZsRoot(
            appearance: const ZsAppearance(),
            child: GraphViewport(
              layout: layout,
              metrics: GraphMetrics(),
              cardBuilder: card,
              verticalController: v,
              horizontalController: h,
            ),
          ),
        ),
      ),
    );
  }

  RenderGraphCard render(WidgetTester tester, String key) => tester.renderObject(
    find.byWidgetPredicate((w) => w is GraphCard && w.layout.keyOf(w.node) == key, skipOffstage: false),
  );

  /// [node]'s card rect in content coordinates (U = 1, the default metrics).
  Rect rectOf(int node) =>
      Rect.fromLTWH(56 + layout.colOf(node) * 296.0, 56.0 + (layout.rows - 1 - layout.rowOf(node)) * 110, 240, 62);
}

void main() {
  setUpIconRegistry();

  group('pure helpers', () {
    test('graphRelativeDate: now, Nm, Nh, Nd, the day, another year; the future is now', () {
      String rel(int ts) => graphRelativeDate(ts, nowMs: _now, utcOffsetMinutes: 0);
      expect(rel(_now - 30000), 'now');
      expect(rel(_now - 40 * _minute), '40m');
      expect(rel(_now - 20 * _hour), '20h');
      expect(rel(_now - 3 * _day), '3d');
      expect(rel(_now - 9 * _day), 'Sep 19');
      expect(rel(DateTime.utc(2025, 12, 29, 12).millisecondsSinceEpoch), 'Dec 29, 2025');
      expect(rel(_now + 5 * _hour), 'now');
      // The day form is read at the layout's offset: 23:30 UTC on Sep 18 is Sep 19 at +02:00.
      expect(
        graphRelativeDate(DateTime.utc(2026, 9, 18, 23, 30).millisecondsSinceEpoch, nowMs: _now, utcOffsetMinutes: 120),
        'Sep 19',
      );
    });

    test('graphLegendParts: a ticket leads, else the last segment; remote and sigils', () {
      expect(graphLegendParts(const GraphRef('feature/ZAN-412_onboarding-swipe')), (
        prefix: '',
        main: 'ZAN-412',
        remote: '',
        sigil: '',
        rest: 'onboarding-swipe',
      ));
      expect(graphLegendParts(const GraphRef('release/1.5.x', remote: 'origin')), (
        prefix: 'release/',
        main: '1.5.x',
        remote: '@origin',
        sigil: '',
        rest: '',
      ));
      expect(graphLegendParts(const GraphRef('riverpod')).main, 'riverpod');
      expect(graphLegendParts(const GraphRef('main', conflicted: true)).sigil, '??');
      expect(graphLegendParts(const GraphRef('dev', synced: false)).sigil, '*');
      expect(graphLegendParts(const GraphRef('dev', remote: 'origin', synced: false)).sigil, '', reason: 'local only');
    });

    test("GraphRef.display prints jj's CommitRef", () {
      expect(const GraphRef('main', conflicted: true).display, 'main??');
      expect(const GraphRef('dev', synced: false).display, 'dev*');
      expect(const GraphRef('main', conflicted: true, synced: false).display, 'main??');
      expect(const GraphRef('release/1.5.x', remote: 'origin').display, 'release/1.5.x@origin');
      expect(const GraphRef('my bm', remote: 'up stream', synced: false).display, '"my bm"@"up stream"');
      expect(const GraphRef('my bm', synced: false).display, '"my bm"*');
    });

    test("jjRefSymbol: ref_name.rs's is_safe_identifier, else format_string", () {
      expect(jjRefSymbol(''), '""');
      expect(jjRefSymbol('foo'), 'foo');
      expect(jjRefSymbol('..'), '".."');
      expect(jjRefSymbol('柔術'), '"柔術"');
      expect(jjRefSymbol('foo.bar-v1+7'), 'foo.bar-v1+7');
      expect(jjRefSymbol('foo_bar/baz'), 'foo_bar/baz');
      expect(jjRefSymbol('foo--bar'), '"foo--bar"');
      expect(jjRefSymbol('-foo'), '"-foo"');
      expect(jjRefSymbol('foo+'), '"foo+"');
      expect(jjRefSymbol('*/foo/**'), '"*/foo/**"');
      expect(jjRefSymbol('0'), '0');
      expect(jjRefSymbol('my ws'), '"my ws"');
    });

    test('GraphCardController: openMenu toggles, select closes the menu', () {
      final controller = GraphCardController(now: _now);
      addTearDown(controller.dispose);
      controller.openMenu('k', Rect.zero);
      expect(controller.menuOpen.value, 'k');
      controller.openMenu('k', Rect.zero);
      expect(controller.menuOpen.value, isNull);
      controller
        ..openMenu('k', Rect.zero)
        ..select('k');
      expect(controller.menuOpen.value, isNull);
      expect(controller.selected.value, 'k');
    });

    test("jjRevsetSymbol: identifiers plain, everything else quoted with format_string's escapes", () {
      expect(jjRevsetSymbol('default'), 'default');
      expect(jjRevsetSymbol('feature/x-1.2+b'), 'feature/x-1.2+b');
      expect(jjRevsetSymbol('ünïcode_ws'), 'ünïcode_ws');
      expect(jjRevsetSymbol('my ws'), '"my ws"');
      expect(jjRevsetSymbol('a..b'), '"a..b"');
      expect(jjRevsetSymbol('-lead'), '"-lead"');
      expect(jjRevsetSymbol('q"b\\s\t\r\n\u0000\u0001\u007f'), r'"q\"b\\s\t\r\n\0\x01\x7f"');
    });

    test("idParts: jj's shortest(n) — max(prefix, 8) detailed, max(prefix, 5) on @ and compact, then /offset", () {
      GraphCardData data({int prefix = 3, bool wc = false, int? offset}) => GraphCardData(
        key: 'k',
        changeId: 'kxwsnptmqrvlzz',
        prefixLength: prefix,
        isWorkingCopy: wc,
        changeOffset: offset,
      );
      expect(data().idParts(detailed: true), (prefix: 'kxw', rest: 'snptm', offset: ''));
      expect(data(prefix: 2, wc: true).idParts(detailed: true), (prefix: 'kx', rest: 'wsn', offset: ''));
      expect(data().idParts(detailed: false), (prefix: 'kxw', rest: 'sn', offset: ''));
      expect(data(prefix: 10).idParts(detailed: true), (prefix: 'kxwsnptmqr', rest: '', offset: ''));
      expect(data(offset: 1).idParts(detailed: true).offset, '/1');
    });

    test('the author: the first word of the name, else the email local part, else nothing', () {
      GraphCardData data(GraphCommitContent? content) =>
          GraphCardData(key: 'k', changeId: 'k', prefixLength: 1, content: content);
      expect(data(const GraphCommitContent(subject: '', authorName: 'Lena König')).author, 'Lena');
      expect(data(const GraphCommitContent(subject: '', authorEmail: 'ci-bot@example.com')).author, 'ci-bot');
      expect(data(const GraphCommitContent(subject: '')).author, isNull);
      expect(data(null).author, isNull);
    });

    test('graphCardLabel: the states, the workspaces and the date with its day label (I1)', () {
      GraphCardData of(RecordedGraphLayout layout) => GraphCardData.of(layout, 0);
      expect(
        graphCardLabel(of(one(flags: _imm)), nowMs: _now),
        'Immutable, feat: swipe gestures, kxwsnptm, Ralph, 40 minutes ago, Today',
      );
      expect(
        graphCardLabel(of(one(root: true, flags: _imm, content: null, ts: null)), nowMs: _now),
        'root(), kxwsnptm',
      );
      expect(
        graphCardLabel(
          of(one(workingCopy: true, workspaces: <String>['default', 'ci'], workspaceName: 'default')),
          nowMs: _now,
        ),
        startsWith('Working copy of default, working copy of ci, feat: swipe gestures'),
      );
      expect(graphCardLabel(of(one(workingCopy: true)), nowMs: _now), startsWith('Working copy, feat'));
      expect(graphCardLabel(of(one(ts: _now - 9 * _day)), nowMs: _now), endsWith(', Ralph, Sep 19'));
      expect(graphCardLabel(of(one(ts: _now - 20 * _hour)), nowMs: _now), endsWith(', 20 hours ago, Yesterday'));
      expect(graphCardLabel(of(one(ts: _now - 30000)), nowMs: _now), endsWith(', Ralph, now, Today'));
      expect(graphCardLabel(of(one(ts: _now - _minute)), nowMs: _now), endsWith(', 1 minute ago, Today'));
      expect(graphCardLabel(of(one(ts: _now - _hour)), nowMs: _now), endsWith(', 1 hour ago, Today'));
      expect(graphCardLabel(of(one(ts: _now - _day)), nowMs: _now), endsWith(', 1 day ago, Yesterday'));
      expect(graphCardLabel(of(one(ts: _now - 3 * _day)), nowMs: _now), endsWith(', 3 days ago, Sep 25'));
      expect(graphCardLabel(of(one(content: null)), nowMs: _now), 'kxwsnptm, 40 minutes ago, Today');
      expect(
        graphCardLabel(
          of(
            one(
              offset: 1,
              flags: RecordedGraphLayout.flagDivergent,
              parents: 2,
              content: const GraphCommitContent(subject: '', empty: true, conflict: true),
            ),
          ),
          nowMs: _now,
        ),
        'no description, kxwsnptm/1, 40 minutes ago, Today, empty, conflict, merge, divergent',
      );
      expect(
        graphCardLabel(of(one(flags: RecordedGraphLayout.flagDivergent | RecordedGraphLayout.flagHidden)), nowMs: _now),
        endsWith(', hidden'),
      );
    });

    test('RecordedGraphLayout: the default prefix is the shortest unique one among the layout ids', () {
      final RecordedGraphLayout layout = handLayout(const <(String, int, int)>[
        ('kxwab', 2, 0),
        ('kxwcd', 1, 0),
        ('zz', 0, 0),
      ]);
      expect(<int>[for (var i = 0; i < 3; i++) layout.changeIdPrefixLengthOf(i)], <int>[4, 4, 1]);
      expect(layout.changeIdOf(0), 'kxwab');
      expect(layout.refsOf(0), isEmpty);
      expect(layout.contentOf(0), isNull);
      expect(layout.isImmutable(0) || layout.isHidden(0) || layout.isDivergent(0), isFalse);
    });

    test('fromSpec reads immutable into the flags (the root included) and takes content and refs', () {
      final RecordedGraphLayout layout = recording('design-all compact greedy');
      expect(layout.isImmutable(layout.rootIndex!), isTrue);
      expect(<bool>[for (var i = 0; i < layout.nodeCount; i++) layout.isImmutable(i)], contains(isTrue));
      expect(<bool>[for (var i = 0; i < layout.nodeCount; i++) layout.isImmutable(i)], contains(isFalse));
      final (String input, String output) = graphRecordings['design-default compact greedy']!;
      final withContent = RecordedGraphLayout.fromSpec(
        input,
        output,
        content: (node, key) => GraphCommitContent(subject: key),
        refs: (node, key) => <GraphRef>[GraphRef('b$node')],
      );
      expect(withContent.contentOf(2)!.subject, withContent.keyOf(2));
      expect(withContent.refsOf(2), const <GraphRef>[GraphRef('b2')]);
    });
  });

  group('layout', () {
    testWidgets('the id is one paragraph: prefix 3 bold, then the dim rest, no gap', (tester) async {
      final RenderGraphCard card = await pumpCard(tester, one(), GraphCardController(now: _now));
      final List<({GraphCardSlot kind, Rect rect, TextStyle? style, String? text})> ids = card.debugSlots
          .where((slot) => slot.kind == GraphCardSlot.id)
          .toList();
      expect(ids, hasLength(1));
      expect(ids.single.text, 'kxwsnptm');
      expect(ids.single.rect.width, 8 * 11.5, reason: 'eight glyphs of the test font, no gap between the spans');
    });

    testWidgets('a short prefix on @ shows five characters; a long prefix is all bold', (tester) async {
      RenderGraphCard card = await pumpCard(tester, one(prefix: 2, workingCopy: true), GraphCardController(now: _now));
      expect(textOf(card, GraphCardSlot.id), 'kxwsn');
      card = await pumpCard(tester, one(prefix: 10), GraphCardController(now: _now));
      expect(textOf(card, GraphCardSlot.id), 'kxwsnptmqr');
    });

    testWidgets('divergent: the id carries /1', (tester) async {
      final RenderGraphCard card = await pumpCard(
        tester,
        one(offset: 1, flags: RecordedGraphLayout.flagDivergent),
        GraphCardController(now: _now),
      );
      expect(textOf(card, GraphCardSlot.id), 'kxwsnptm/1');
    });

    testWidgets('detailed: subject, then the meta line in order', (tester) async {
      final RenderGraphCard card = await pumpCard(
        tester,
        one(
          workingCopy: true,
          parents: 2,
          content: const GraphCommitContent(subject: 'x', authorName: 'Bob', empty: true, conflict: true),
        ),
        GraphCardController(now: _now),
        width: 400,
      );
      expect(kinds(card), <GraphCardSlot>[
        GraphCardSlot.subject,
        GraphCardSlot.atBadge,
        GraphCardSlot.id,
        GraphCardSlot.author,
        GraphCardSlot.date,
        GraphCardSlot.empty,
        GraphCardSlot.conflict,
        GraphCardSlot.merge,
      ]);
      expect(textOf(card, GraphCardSlot.atBadge), '@');
      expect(rectOf(card, GraphCardSlot.subject).bottom, lessThan(rectOf(card, GraphCardSlot.id).top));
    });

    testWidgets('an empty description shows the placeholder in italic dim; null content shows id, date and flags', (
      tester,
    ) async {
      RenderGraphCard card = await pumpCard(
        tester,
        one(content: const GraphCommitContent(subject: '')),
        GraphCardController(now: _now),
      );
      final ({GraphCardSlot kind, Rect rect, TextStyle? style, String? text}) subject = card.debugSlots.firstWhere(
        (slot) => slot.kind == GraphCardSlot.subject,
      );
      expect(subject.text, '(no description set)');
      expect(subject.style!.fontStyle, FontStyle.italic);
      expect(subject.style!.color, GraphTheme.night.cardTextDim);

      card = await pumpCard(tester, one(content: null, parents: 2), GraphCardController(now: _now));
      expect(tester.takeException(), isNull);
      expect(textOf(card, GraphCardSlot.subject), '');
      expect(kinds(card), isNot(contains(GraphCardSlot.author)));
      expect(kinds(card), containsAll(<GraphCardSlot>[GraphCardSlot.id, GraphCardSlot.date, GraphCardSlot.merge]));
    });

    testWidgets('a merge with a Missing parent shows the merge glyph', (tester) async {
      final layout = RecordedGraphLayout.fromSpec(
        '{"nodes":[{"key":"m","parents":[{"kind":"direct","id":"p"},{"kind":"missing"}],"ts_ms":$_now},'
            '{"key":"p","parents":[]}]}',
        '{"mode":"compact","unit":1,"rows":2,"lanes":1,"nodes":[{"col":0,"row":1},{"col":0,"row":0}],'
            '"edges":[{"from":1,"to":0,"kind":"direct","route":"straight"}],"buckets":[]}',
      );
      expect(layout.elidedOf(0), isTrue);
      final RenderGraphCard card = await pumpCard(tester, layout, GraphCardController(now: _now));
      expect(kinds(card), contains(GraphCardSlot.merge));
    });

    testWidgets('a 500-character subject and a long author ellipsize; the size stays 240 × 62', (tester) async {
      final RenderGraphCard card = await pumpCard(
        tester,
        one(
          content: GraphCommitContent(subject: 'x' * 500, authorName: 'A${'b' * 80} Long'),
        ),
        GraphCardController(now: _now),
      );
      expect(card.cardRect.size, const Size(240, 62));
      expect(card.size, const Size(240 + 22, 62 + 22));
      expectNoOverflow(card);
    });

    testWidgets('workspaces: none, two, five and a quoted name', (tester) async {
      RenderGraphCard card = await pumpCard(tester, one(workingCopy: true), GraphCardController(now: _now));
      expect(textOf(card, GraphCardSlot.atBadge), '@');
      expect(kinds(card), isNot(contains(GraphCardSlot.workspaceTag)));

      card = await pumpCard(
        tester,
        one(workingCopy: true, workspaces: <String>['ci', 'default'], workspaceName: 'default'),
        GraphCardController(now: _now),
        width: 400,
      );
      expect(textOf(card, GraphCardSlot.atBadge), 'default@');
      expect(textsOf(card, GraphCardSlot.workspaceTag), <String>['ci@']);

      card = await pumpCard(
        tester,
        one(
          workingCopy: true,
          workspaces: <String>['default', 'zz', 'ci', 'docs', 'release'],
          workspaceName: 'default',
          content: const GraphCommitContent(subject: 'x'),
          ts: null,
        ),
        GraphCardController(now: _now),
        width: 400,
      );
      expect(textOf(card, GraphCardSlot.atBadge), 'default@');
      expect(textsOf(card, GraphCardSlot.workspaceTag), <String>['ci@', 'docs@']);
      expect(textOf(card, GraphCardSlot.moreTag), '+2');

      card = await pumpCard(
        tester,
        one(workspaces: <String>['my ws', 'default'], workspaceName: 'default'),
        GraphCardController(now: _now),
        width: 400,
      );
      expect(textsOf(card, GraphCardSlot.workspaceTag), <String>['default@', '"my ws"@'], reason: 'by name');
    });

    testWidgets('yield at 240: the author goes, the tags fold, the names shorten, the date stays', (tester) async {
      final RenderGraphCard card = await pumpCard(
        tester,
        one(
          workingCopy: true,
          workspaces: <String>['default', 'ci', 'docs', 'release'],
          workspaceName: 'default',
          content: const GraphCommitContent(subject: 'x', authorName: 'Maximilian-Alexander'),
        ),
        GraphCardController(now: _now),
      );
      expect(kinds(card), <GraphCardSlot>[
        GraphCardSlot.subject,
        GraphCardSlot.atBadge,
        GraphCardSlot.moreTag,
        GraphCardSlot.id,
        GraphCardSlot.date,
      ]);
      expect(textOf(card, GraphCardSlot.moreTag), '+3');
      expect(rectOf(card, GraphCardSlot.atBadge).width, inInclusiveRange(24, 96 - 1));
      expect(rectOf(card, GraphCardSlot.id).width, 5 * 11.5, reason: 'the @ id, whole');
      expectNoOverflow(card);
    });

    testWidgets('yield at 160 compact: the subject goes first; ours and the full id stay', (tester) async {
      final RenderGraphCard card = await pumpCard(
        tester,
        one(workingCopy: true, workspaces: <String>['default', 'ci', 'docs'], workspaceName: 'default'),
        GraphCardController(now: _now),
        width: 160,
        detailed: false,
      );
      expect(kinds(card), <GraphCardSlot>[GraphCardSlot.atBadge, GraphCardSlot.moreTag, GraphCardSlot.id]);
      expect(textOf(card, GraphCardSlot.id), 'kxwsn');
      expect(rectOf(card, GraphCardSlot.id).width, 5 * 11.5);
      expectNoOverflow(card);
    });

    testWidgets('compact at 240: one line — @, id, subject, flags', (tester) async {
      final RenderGraphCard card = await pumpCard(
        tester,
        one(workingCopy: true, parents: 2),
        GraphCardController(now: _now),
        detailed: false,
      );
      expect(kinds(card), <GraphCardSlot>[
        GraphCardSlot.atBadge,
        GraphCardSlot.id,
        GraphCardSlot.subject,
        GraphCardSlot.merge,
      ]);
      expect(card.cardRect.size, const Size(240, 40));
      expectNoOverflow(card);
    });

    testWidgets('the root: root() in mono, no bookmark control, ••• kept', (tester) async {
      final RenderGraphCard card = await pumpCard(
        tester,
        one(id: 'zzzzzzzzzzzz', prefix: 1, root: true, flags: _imm, content: null, ts: null),
        GraphCardController(now: _now),
      );
      final ({GraphCardSlot kind, Rect rect, TextStyle? style, String? text}) subject = card.debugSlots.firstWhere(
        (slot) => slot.kind == GraphCardSlot.subject,
      );
      expect(subject.text, 'root()');
      expect(subject.style!.fontFamily, ZsType.monoFamily);
      expect(subject.style!.fontStyle, isNot(FontStyle.italic));
      expect(subject.style!.color, GraphTheme.night.cardTextMuted);
      final all = <GraphCardSlot>[for (final slot in card.debugSlots) slot.kind];
      expect(all, isNot(contains(GraphCardSlot.legend)));
      expect(all, isNot(contains(GraphCardSlot.addBookmark)));
      expect(all, contains(GraphCardSlot.more));
    });

    for (final (String name, GraphRef ref, int more, List<String> texts) in <(String, GraphRef, int, List<String>)>[
      ('ticket', const GraphRef('feature/ZAN-412_onboarding-swipe'), 0, <String>['ZAN-412', 'onboarding-swipe']),
      // The test font's 11 px glyphs overflow the 166 px pill at 400, so the prefix yields first (the full order is
      // graphLegendParts' witness).
      ('path + remote', const GraphRef('release/1.5.x', remote: 'origin'), 0, <String>['1.5.x', '@origin']),
      ('more', const GraphRef('riverpod'), 2, <String>['riverpod', '+2']),
      ('sigil', const GraphRef('main', conflicted: true), 0, <String>['main', '??']),
    ]) {
      testWidgets('legend $name: the parts in order at 400, and at most W/2 − 34 at 160, 240 and 400', (tester) async {
        final refs = <GraphRef>[ref, for (var i = 0; i < more; i++) GraphRef('x$i')];
        for (final width in <double>[160, 240, 400]) {
          final RenderGraphCard card = await pumpCard(
            tester,
            one(refs: refs),
            GraphCardController(now: _now),
            width: width,
          );
          final Rect legend = rectOf(card, GraphCardSlot.legend);
          expect(legend.width, lessThanOrEqualTo(width / 2 - 34 + 1e-6), reason: '$width');
          expect(legend.right, card.cardRect.right - 10);
          expect(legend.top, card.cardRect.top - 11);
          if (width == 400) {
            expect(card.debugLegendTexts, texts);
          }
          // The pill paints after the card's content.
          final List<(Symbol, List<dynamic>)> calls = paintCalls(card);
          final int pill = calls.indexWhere(
            (call) => call.$1 == #drawRRect && (call.$2[0] as RRect).outerRect == legend,
          );
          expect(pill, greaterThan(calls.indexWhere((call) => call.$1 == #drawParagraph)));
        }
      });
    }
  });

  group('paint', () {
    for (final ZsTheme theme in ZsTheme.values) {
      testWidgets('rings and borders of selected and @-selected match the DS in ${theme.name}', (tester) async {
        final appearance = ZsAppearance(theme: theme);
        final elevation = ZsElevation.resolve(appearance);
        final graph = GraphTheme.resolve(appearance);
        for (final (bool wc, ZsShadowStack ring, Color border) in <(bool, ZsShadowStack, Color)>[
          (false, elevation.ringSelect, graph.cardSelectedBorder),
          (true, elevation.ringWcSelect, graph.workingCopyLine),
        ]) {
          final controller = GraphCardController(now: _now)..selected.value = 'kxwsnptmqrvl';
          final RenderGraphCard card = await pumpCard(tester, one(workingCopy: wc), controller, appearance: appearance);
          final rrect = RRect.fromRectAndRadius(card.cardRect, const Radius.circular(10));
          final List<(RRect, int)> painted = rrects(paintCalls(card));
          final expected = <(RRect, int)>[
            for (final BoxShadow shadow in ring.boxShadows.reversed)
              (rrect.shift(shadow.offset).inflate(shadow.spreadRadius), shadow.color.toARGB32()),
          ];
          expect(painted.take(expected.length), expected, reason: 'the rings come first, back to front');
          expect(painted, contains((rrect.deflate(.5), border.toARGB32())));
        }
      });
    }

    testWidgets('an immutable card and the root paint the hatch in every state, and nothing paints a ◆', (
      tester,
    ) async {
      for (final (String what, RecordedGraphLayout layout) in <(String, RecordedGraphLayout)>[
        ('immutable', one(flags: _imm)),
        ('root', one(root: true, flags: _imm, content: null)),
      ]) {
        for (final state in <String>['base', 'hover', 'selected', 'menu']) {
          final controller = GraphCardController(now: _now);
          final String key = layout.keyOf(0);
          switch (state) {
            case 'hover':
              controller.hovered.value = key;
            case 'selected':
              controller.selected.value = key;
            case 'menu':
              controller.menuOpen.value = key;
          }
          final RenderGraphCard card = await pumpCard(tester, layout, controller);
          final List<int> hatch = lineColors(paintCalls(card));
          expect(hatch, isNotEmpty, reason: '$what $state');
          expect(hatch.every((color) => color == GraphTheme.night.hatch.toARGB32()), isTrue, reason: '$what $state');
          expect(card.debugSlots.any((slot) => slot.text?.contains('◆') ?? false), isFalse);
        }
      }
      final RenderGraphCard mutable = await pumpCard(tester, one(), GraphCardController(now: _now));
      expect(lineColors(paintCalls(mutable)), isEmpty);
    });

    testWidgets('HatchSwatch paints its lines every 3 px at 12 px', (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: Center(child: HatchSwatch()),
        ),
      );
      expect(tester.getSize(find.byType(HatchSwatch)), const Size.square(12));
      final starts = <double>[];
      expect(
        tester.renderObject(find.byType(CustomPaint)),
        paints..everything((method, arguments) {
          if (method == #drawLine) {
            expect((arguments[2] as Paint).color.toARGB32(), GraphTheme.night.hatchMark.toARGB32());
            starts.add((arguments[0] as Offset).dx);
          }
          return true;
        }),
      );
      expect(starts.length, greaterThan(3));
      for (var i = 1; i < starts.length; i++) {
        expect(starts[i] - starts[i - 1], closeTo(3 * math.sqrt2, 1e-9));
      }
      expect(starts.first, closeTo(2.5 * math.sqrt2, 1e-9));
    });

    testWidgets('a labelled HatchSwatch is an image with its label', (tester) async {
      final SemanticsHandle semantics = tester.ensureSemantics();
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: Center(child: HatchSwatch(label: 'Immutable')),
        ),
      );
      expect(find.bySemanticsLabel('Immutable'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('keyboard focus paints a 2 px focus-ring outline at offset 3 under traditional highlighting', (
      tester,
    ) async {
      addTearDown(() => FocusManager.instance.highlightStrategy = FocusHighlightStrategy.automatic);
      FocusManager.instance.highlightStrategy = FocusHighlightStrategy.alwaysTraditional;
      final controller = GraphCardController(now: _now)..focused.value = 'kxwsnptmqrvl';
      final RenderGraphCard card = await pumpCard(tester, one(), controller);
      final RRect ring = RRect.fromRectAndRadius(card.cardRect, const Radius.circular(10)).inflate(4);
      final int color = GraphTheme.night.focusRing.toARGB32();
      expect(rrects(paintCalls(card)), contains((ring, color)));
      FocusManager.instance.highlightStrategy = FocusHighlightStrategy.alwaysTouch;
      await tester.pump();
      expect(rrects(paintCalls(card)), isNot(contains((ring, color))));
    });

    testWidgets('an inactive window: no hover look, no affordance; the selected ring is the neutral one', (
      tester,
    ) async {
      const appearance = ZsAppearance(inactive: true);
      final controller = GraphCardController(now: _now)
        ..hovered.value = 'kxwsnptmqrvl'
        ..selected.value = 'kxwsnptmqrvl';
      final RenderGraphCard card = await pumpCard(tester, one(), controller, appearance: appearance);
      await tester.pumpAndSettle();
      final List<(Symbol, List<dynamic>)> calls = paintCalls(card);
      final graph = GraphTheme.resolve(appearance);
      final rrect = RRect.fromRectAndRadius(card.cardRect, const Radius.circular(10));
      expect(rrects(calls), contains((rrect, graph.cardFill.toARGB32())));
      expect(rrects(calls), isNot(contains((rrect, graph.cardFillHover.toARGB32()))));
      expect(calls.where((call) => call.$1 == #drawOval), isEmpty);
      final BoxShadow neutral = ZsElevation.resolve(appearance).ringSelect.boxShadows.single;
      expect(neutral.color, isNot(ZsElevation.night.ringSelect.boxShadows.single.color));
      expect(rrects(calls).first, (rrect.inflate(neutral.spreadRadius), neutral.color.toARGB32()));
      final result = BoxHitTestResult();
      expect(card.hitTest(result, position: rectOf(card, GraphCardSlot.more).center), isFalse);
    });

    for (final reduce in <bool>[false, true]) {
      testWidgets('reduce motion $reduce: ••• ${reduce ? 'only fades, at scale 1' : 'fades and scales in'}', (
        tester,
      ) async {
        final controller = GraphCardController(now: _now);
        final RenderGraphCard card = await pumpCard(
          tester,
          one(),
          controller,
          appearance: ZsAppearance(reduceMotion: reduce),
        );
        controller.hovered.value = 'kxwsnptmqrvl';
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 40));
        final List<(Symbol, List<dynamic>)> calls = paintCalls(card);
        final scales = <double>[
          for (final (Symbol method, List<dynamic> args) in calls)
            if (method == #scale) args[0] as double,
        ];
        final ovals = <Color>[
          for (final (Symbol method, List<dynamic> args) in calls)
            if (method == #drawOval) (args[1] as Paint).color,
        ];
        expect(ovals, isNotEmpty);
        expect(ovals.first.a, inExclusiveRange(0, 1), reason: 'mid-fade');
        final Iterable<double> affordance = scales.where((s) => s != 12 / 16);
        if (reduce) {
          expect(affordance.every((s) => s == 1), isTrue);
        } else {
          expect(affordance.any((s) => s > .85 && s < 1), isTrue);
        }
        await tester.pumpAndSettle();
      });
    }

    testWidgets('the affordances fade out when the hover ends', (tester) async {
      final controller = GraphCardController(now: _now)..hovered.value = 'kxwsnptmqrvl';
      final RenderGraphCard card = await pumpCard(tester, one(), controller);
      await tester.pumpAndSettle();
      controller.hovered.value = null;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      final ovals = <Color>[
        for (final (Symbol method, List<dynamic> args) in paintCalls(card))
          if (method == #drawOval) (args[1] as Paint).color,
      ];
      expect(ovals, hasLength(4), reason: '••• and the add-bookmark circle, fill and border each');
      expect(ovals.first.a, inExclusiveRange(0, 1), reason: 'mid-fade');
      await tester.pumpAndSettle();
      expect(paintCalls(card).where((call) => call.$1 == #drawOval), isEmpty);
    });

    testWidgets('disabled actions paint the affordances at --disabled-opacity and ignore their taps', (tester) async {
      final controller = RecordingController()
        ..hovered.value = 'kxwsnptmqrvl'
        ..actionsEnabled.value = false;
      final RenderGraphCard card = await pumpCard(tester, one(), controller);
      await tester.pumpAndSettle();
      final ovals = <Color>[
        for (final (Symbol method, List<dynamic> args) in paintCalls(card))
          if (method == #drawOval) (args[1] as Paint).color,
      ];
      expect(ovals.first.a, closeTo(GraphTheme.night.cardFillHover.a * .4, 1e-6));
      await tester.tapAt(_at + rectOf(card, GraphCardSlot.more).center);
      expect(controller.calls, isEmpty);
    });
  });

  group('input and semantics', () {
    testWidgets(
      'affordances reveal on hover, are hit in the overhang and keep the hover; not hovered, a tap there misses',
      (tester) async {
        final controller = RecordingController();
        final RenderGraphCard card = await pumpCard(tester, one(), controller);
        final Offset more = _at + rectOf(card, GraphCardSlot.more).center;
        final Offset add = _at + rectOf(card, GraphCardSlot.addBookmark).center;
        expect(card.cardRect.contains(more - _at), isFalse, reason: 'in the overhang');
        await tester.tapAt(more);
        await tester.tapAt(add);
        expect(controller.calls, isEmpty);

        final TestGesture mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: _at + card.cardRect.center);
        addTearDown(mouse.removePointer);
        await tester.pump();
        expect(controller.hovered.value, 'kxwsnptmqrvl');
        await mouse.moveTo(more);
        await tester.pump();
        expect(controller.hovered.value, 'kxwsnptmqrvl', reason: 'on ••• the card stays hovered');
        await mouse.down(more);
        await mouse.up();
        expect(controller.calls.single.$1, 'menu');
        expect(controller.calls.single.$3, (_at + rectOf(card, GraphCardSlot.more).topLeft) & const Size(20, 20));
        await mouse.moveTo(add);
        await tester.pump();
        await mouse.down(add);
        await mouse.up();
        expect(controller.calls.last.$1, 'bookmarks');
        await mouse.moveTo(const Offset(700, 500));
        await tester.pump();
        expect(controller.hovered.value, isNull);
      },
      variant: macOS,
    );

    testWidgets('a right-click opens the menu at the pointer; a body tap selects; a pill tap opens the bookmarks', (
      tester,
    ) async {
      final controller = RecordingController();
      final RenderGraphCard card = await pumpCard(
        tester,
        one(refs: const <GraphRef>[GraphRef('main')]),
        controller,
      );
      final Offset body = _at + card.cardRect.center;
      await tester.tapAt(body, buttons: kSecondaryMouseButton, kind: PointerDeviceKind.mouse);
      expect(controller.calls.single, ('menu', 'kxwsnptmqrvl', Rect.fromLTWH(body.dx, body.dy, 0, 0)));
      await tester.tapAt(body);
      expect(controller.calls.last.$1, 'select');
      expect(controller.selected.value, 'kxwsnptmqrvl');
      await tester.tapAt(_at + rectOf(card, GraphCardSlot.legend).center);
      expect(controller.calls.last.$1, 'bookmarks');
      expect(
        controller.calls.last.$3,
        (_at + rectOf(card, GraphCardSlot.legend).topLeft) & rectOf(card, GraphCardSlot.legend).size,
      );
    });

    testWidgets('one semantics node: the label, the selected flag, the identifier and the custom actions', (
      tester,
    ) async {
      final SemanticsHandle semantics = tester.ensureSemantics();
      final controller = RecordingController()..selected.value = 'kxwsnptmqrvl';
      await pumpCard(
        tester,
        one(flags: _imm, refs: const <GraphRef>[GraphRef('main'), GraphRef('dev', synced: false)]),
        controller,
      );
      final SemanticsNode node = tester.getSemantics(find.byType(GraphCard));
      final SemanticsData data = node.getSemanticsData();
      expect(data.label, 'Immutable, feat: swipe gestures, kxwsnptm, Ralph, 40 minutes ago, Today');
      expect(data.identifier, 'graph-card-kxwsnptmqrvl');
      expect(data.flagsCollection.isSelected, Tristate.isTrue);
      expect(data.flagsCollection.isButton, isTrue);
      expect(
        <String>[for (final int id in data.customSemanticsActionIds!) CustomSemanticsAction.getAction(id)!.label!],
        <String>['Actions', 'Bookmarks: main, dev*'],
      );
      final RenderGraphCard card = tester.renderObject(find.byType(GraphCard));
      expect(node.rect, card.cardRect);

      await pumpCard(tester, one(), controller);
      final SemanticsData plain = tester.getSemantics(find.byType(GraphCard)).getSemanticsData();
      expect(
        <String>[for (final int id in plain.customSemanticsActionIds!) CustomSemanticsAction.getAction(id)!.label!],
        <String>['Actions', 'Add bookmark'],
      );

      await pumpCard(tester, one(root: true, flags: _imm, content: null), controller);
      final SemanticsData root = tester.getSemantics(find.byType(GraphCard)).getSemanticsData();
      expect(root.label, startsWith('root(), '));
      expect(
        <String>[for (final int id in root.customSemanticsActionIds!) CustomSemanticsAction.getAction(id)!.label!],
        <String>['Actions'],
      );
      semantics.dispose();
    });
  });

  group('in the viewport', () {
    testWidgets('hover A, then B, selection A → B and a minute tick build no card; only changed dates lay out', (
      tester,
    ) async {
      final RecordedGraphLayout layout = handLayout(
        const <(String, int, int)>[('a', 1, 0), ('b', 1, 1), ('c', 0, 0)],
        timestamps: const <int?>[_now - 30000, _now - 3 * _day, _now - 3 * _day],
        contents: const <GraphCommitContent?>[_content, _content, _content],
      );
      final controller = GraphCardController(now: _now);
      addTearDown(controller.dispose);
      final host = Host(layout, controller);
      await host.pump(tester);
      host.builds = 0;
      final RenderGraphCard a = host.render(tester, 'a');
      final RenderGraphCard b = host.render(tester, 'b');
      final RenderGraphCard c = host.render(tester, 'c');

      final TestGesture mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(790, 590));
      addTearDown(mouse.removePointer);
      await mouse.moveTo(host.rectOf(0).center);
      expect(controller.hovered.value, 'a');
      expect(a.debugNeedsPaint, isTrue);
      expect(b.debugNeedsPaint || c.debugNeedsPaint, isFalse);
      await tester.pumpAndSettle();
      await mouse.moveTo(host.rectOf(1).center);
      expect(controller.hovered.value, 'b');
      expect(a.debugNeedsPaint && b.debugNeedsPaint, isTrue);
      expect(c.debugNeedsPaint, isFalse);
      await tester.pumpAndSettle();
      expect(host.builds, 0);

      controller.selected.value = 'a';
      await tester.pump();
      controller.selected.value = 'b';
      await tester.pump();
      expect(host.builds, 0);

      controller.now.value += 60000;
      expect(a.debugNeedsLayout, isTrue, reason: '"now" → "1m"');
      expect(b.debugNeedsLayout || c.debugNeedsLayout, isFalse, reason: '"3d" stays');
      await tester.pump();
      expect(host.builds, 0);
    }, variant: macOS);

    testWidgets('a mouse drag that starts 5 px above a card pans the canvas', (tester) async {
      final RecordedGraphLayout layout = chainLayout(60);
      final controller = GraphCardController(now: _now);
      addTearDown(controller.dispose);
      final host = Host(layout, controller);
      await host.pump(tester);
      host.v.jumpTo(300);
      host.h.jumpTo(300);
      await tester.pump();
      // A card fully on screen, not under the pill (it has no refs): 5 px above its top centre.
      final int node =
          <int>[
            for (var i = 0; i < layout.nodeCount; i++) i,
          ].firstWhere(
            (i) => (const Offset(300, 300) & const Size(800, 600)).deflate(40).contains(host.rectOf(i).topCenter),
          );
      final Offset start = host.rectOf(node).topCenter - const Offset(300, 305);
      final TestGesture drag = await tester.startGesture(start, kind: PointerDeviceKind.mouse);
      await drag.moveBy(const Offset(-30, -30));
      await drag.moveBy(const Offset(-30, -30));
      await drag.up();
      await tester.pump();
      expect(host.h.offset, greaterThan(300));
      expect(host.v.offset, greaterThan(300));
      expect(controller.selected.value, isNull);
    }, variant: macOS);

    /// A node of [layout] whose card is fully on screen at scroll 0.
    int onScreen(Host host) => <int>[
      for (var i = 0; i < host.layout.nodeCount; i++) i,
    ].firstWhere((i) => (Offset.zero & surface).deflate(40).contains(host.rectOf(i).bottomRight + const Offset(0, 11)));

    testWidgets('a viewport card: its box is the inflated card rect, and hover then ••• reaches openMenu', (
      tester,
    ) async {
      final RecordedGraphLayout layout = chainLayout(60, cols: 2);
      final controller = RecordingController();
      addTearDown(controller.dispose);
      final host = Host(layout, controller);
      await host.pump(tester);
      final int node = onScreen(host);
      final RenderGraphCard card = host.render(tester, layout.keyOf(node));
      expect(card.size, const Size(240 + 22, 62 + 22));
      expect(card.localToGlobal(card.cardRect.topLeft) & card.cardRect.size, host.rectOf(node));

      final TestGesture mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: host.rectOf(node).center);
      addTearDown(mouse.removePointer);
      await tester.pump();
      expect(controller.hovered.value, layout.keyOf(node));
      final Offset more = card.localToGlobal(rectOf(card, GraphCardSlot.more).center);
      await mouse.moveTo(more);
      await tester.pump();
      await mouse.down(more);
      await mouse.up();
      expect(controller.calls.last.$1, 'menu');
      expect(
        controller.calls.last.$3,
        card.localToGlobal(rectOf(card, GraphCardSlot.more).topLeft) & const Size(20, 20),
      );
    }, variant: macOS);

    testWidgets('a press on the overhang half of ••• never arms the pan', (tester) async {
      // Two columns: a card fully on screen at scroll 0, and the plane scrolls vertically.
      final RecordedGraphLayout layout = chainLayout(60, cols: 2);
      final controller = RecordingController();
      addTearDown(controller.dispose);
      final host = Host(layout, controller);
      await host.pump(tester);
      final int node = onScreen(host);
      final RenderGraphCard card = host.render(tester, layout.keyOf(node));
      final TestGesture mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: host.rectOf(node).center);
      addTearDown(mouse.removePointer);
      await tester.pump();
      // The lower half of •••: outside the card rect, in the overhang.
      final Offset below = card.localToGlobal(rectOf(card, GraphCardSlot.more).center + const Offset(0, 5));
      expect(host.rectOf(node).contains(below), isFalse);
      await mouse.moveTo(below);
      await tester.pump();

      // 3 px is past the mouse's pan slop (2 px): an armed pan would scroll.
      await mouse.down(below);
      await mouse.moveBy(const Offset(-3, -3));
      await mouse.up();
      await tester.pump();
      expect(Offset(host.h.offset, host.v.offset), Offset.zero);

      // Within the mouse's tap slop (1 px) the press opens the menu, still without a scroll.
      await mouse.moveTo(below);
      await mouse.down(below);
      await mouse.moveBy(const Offset(-1, 0));
      await mouse.up();
      await tester.pump();
      expect(Offset(host.h.offset, host.v.offset), Offset.zero);
      expect(controller.calls.last.$1, 'menu');
    }, variant: macOS);
  });

  group('the minute tick', () {
    testWidgets('the label speaks the new relative time, and a crossed midnight updates the day label', (
      tester,
    ) async {
      final SemanticsHandle semantics = tester.ensureSemantics();
      String label() => tester.getSemantics(find.byType(GraphCard)).label;
      var controller = GraphCardController(now: _now);
      await pumpCard(tester, one(ts: _now - 30000), controller);
      expect(label(), endsWith(', now, Today'));
      controller.now.value += 60000;
      await tester.pump();
      expect(label(), endsWith(', 1 minute ago, Today'));

      // Sep 28 23:59:30 → Sep 29 00:00:30: still "1 day ago", but Sep 27 is no longer "Yesterday".
      const int lateNight = _now + 12 * _hour - 30000;
      controller = GraphCardController(now: lateNight);
      await pumpCard(tester, one(ts: _now - 23 * _hour), controller);
      expect(label(), endsWith(', 1 day ago, Yesterday'));
      controller.now.value += 60000;
      await tester.pump();
      expect(label(), endsWith(', 1 day ago, Sep 27'));
      semantics.dispose();
    });
  });
}
