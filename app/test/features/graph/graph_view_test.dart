// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/src/features/graph/graph_canvas.dart';
import 'package:zanshin/src/features/graph/graph_card.dart';
import 'package:zanshin/src/features/graph/graph_card_render.dart';
import 'package:zanshin/src/features/graph/graph_layout.dart';
import 'package:zanshin/src/features/graph/graph_peek.dart';
import 'package:zanshin/src/features/graph/graph_ports.dart';
import 'package:zanshin/src/features/graph/graph_view.dart';
import 'package:zanshin/src/features/graph/graph_view_model.dart';
import 'package:zanshin/src/features/graph/graph_viewport.dart';
import 'package:zanshin/src/features/graph/recorded_graph_layout.dart';
import 'package:zanshin/src/features/shell/graph_insets.dart';
import 'package:zanshin/src/features/shell/shell_controller.dart';
import 'package:zanshin/src/features/shell/shell_layout.dart';
import 'package:zanshin/src/features/shell/shell_scope.dart';
import 'package:zanshin_core/zanshin_core.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

import '../../helpers/icon_registry.dart';
import '../../helpers/scripted_graph_source.dart';
import '../../helpers/shell_host.dart';
import 'graph_harness.dart';

/// A chain of [rows] commits `r0` … `r<rows−1>` (column `row % 6`) under [heads] (newest first, column 0), @ at [at].
RecordedGraphLayout chainAt(
  int rows, {
  required String at,
  List<String> heads = const <String>[],
  Map<String, int> colOf = const <String, int>{},
}) {
  final nodes = <(String, int, int)>[
    for (var i = 0; i < heads.length; i++) (heads[i], rows + heads.length - 1 - i, 0),
    for (int row = rows - 1; row >= 0; row--) ('r$row', row, colOf['r$row'] ?? row % 6),
  ];
  final int wc = nodes.indexWhere((node) => node.$1 == at);
  return handLayout(
    nodes,
    edges: <(int, int)>[for (var i = 0; i + 1 < nodes.length; i++) (i, i + 1)],
    workingCopy: wc < 0 ? null : wc,
  );
}

/// The shell's insets of the design: top 60, the rail 76, the minimap column 158, bottom 12.
const _shellInsets = GraphInsets(top: 60, left: 76, right: 158, bottom: 12, inspectorWidth: 460, minimapWidth: 134);

class _Recorder extends ShellController {
  final reported = <double>[];

  double get total => reported.fold(0, (a, b) => a + b);

  @override
  void reportUserScroll(double amount) {
    reported.add(amount);
    super.reportUserScroll(amount);
  }
}

/// A [GraphView] host whose inputs a test changes before each pump.
class _Host {
  _Host(this.model);

  final GraphViewModel model;
  ShellController? shell;
  GraphInsets insets = _shellInsets;
  var appearance = const ZsAppearance();
  var options = const GraphViewOptions();

  Widget build() {
    Widget view = GraphView(model: model, options: options);
    final ShellController? shell = this.shell;
    if (shell != null) {
      view = ShellScope(
        controller: shell,
        layout: ShellLayout(
          panelWidth: 300,
          inspectorWidth: 460,
          collapsed: false,
          insets: insets,
          panelMax: 440,
          inspectorMax: 720,
        ),
        child: view,
      );
    }
    return wrap(view, appearance: appearance);
  }
}

/// Each run waits on [gate] while it is set, else writes one operation.
class _Actions implements GraphActions {
  final ran = <GraphAction>[];
  Completer<MutationResult>? gate;

  @override
  Future<String> headOpId() async => 'op${ran.length}';

  @override
  Future<MutationResult> run(GraphAction action) async {
    ran.add(action);
    if (gate case final gate?) {
      return gate.future;
    }
    return MutationResult(
      newOpId: 'op${ran.length}',
      newChangeIds: const <String>[],
      abandonedChangeIds: const <String>[],
      workingCopyChangeId: null,
      finish: null,
    );
  }
}

/// [child] in the shell tests' window root (an Overlay for the tooltips).
Widget wrap(Widget child, {ZsAppearance appearance = const ZsAppearance()}) => shellHost(child, appearance: appearance);

Finder cardOf(String key) =>
    find.byWidgetPredicate((w) => w is GraphCard && w.layout.keyOf(w.node) == key, skipOffstage: false);

RenderGraphViewport viewportOf(WidgetTester tester) => tester.allRenderObjects.whereType<RenderGraphViewport>().single;

GraphCardController cardsOf(WidgetTester tester) => tester.widget<GraphCanvas>(find.byType(GraphCanvas)).cards;

/// The keys of the cards fully on screen, with their top-left.
Map<String, Offset> onScreen(WidgetTester tester) => <String, Offset>{
  for (final Element element in find.byType(GraphCard, skipOffstage: false).evaluate())
    if ((Offset.zero & surface).contains(tester.getTopLeft(find.byWidget(element.widget))) &&
        (Offset.zero & surface).contains(tester.getBottomRight(find.byWidget(element.widget))))
      (element.widget as GraphCard).layout.keyOf((element.widget as GraphCard).node): tester.getTopLeft(
        find.byWidget(element.widget),
      ),
};

void main() {
  setUpIconRegistry();
  late ScriptedGraphSource source;
  late GraphViewModel model;
  late _Host host;
  final noon = DateTime.utc(2026, 10, 30, 12);
  var clock = noon;

  var created = false;

  setUp(() {
    clock = noon;
    created = false;
    source = ScriptedGraphSource(respond: (_) => chainAt(200, at: 'r100'));
  });

  /// Creates the model inside the test, so its first request runs on the test's clock.
  void create({ShellController? shell, GraphActions? actions}) {
    created = true;
    model = GraphViewModel()..init(source, actions: actions, clock: () => clock);
    host = _Host(model)..shell = shell;
  }

  Future<void> pump(WidgetTester tester) async {
    if (!created) {
      create();
    }
    tester.view
      ..physicalSize = surface
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(host.build());
    await tester.pump();
  }

  /// Unmounts the view, then disposes the model (its minute timer must not outlive the test) and the shell.
  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    model.dispose();
    host.shell?.dispose();
  }

  Rect visible(EdgeInsets insets) => insets.deflateRect(Offset.zero & surface);

  Future<void> heads(WidgetTester tester) async {
    source.emit(const OpHeadsChangedEvent(0, <String>[]));
    await tester.pump();
    await tester.pump();
  }

  testWidgets('the first layout centres @ in the visible rect in the relayout it lands with', (tester) async {
    source.hold = true;
    create(shell: ShellController());
    await pump(tester);
    expect(find.byType(GraphCanvas), findsNothing, reason: 'loading shows nothing');
    source.held.single.complete(GraphLoad(chainAt(200, at: 'r100')));
    // The first frame that shows the canvas already has @ centred.
    for (var i = 0; i < 3 && find.byType(GraphCanvas).evaluate().isEmpty; i++) {
      await tester.pump();
    }
    expect(tester.getCenter(cardOf('r100')), visible(viewportOf(tester).insets).center);
    await finish(tester);
  });

  testWidgets('a hot reload (reassemble, debug only) requests the layout once more', (tester) async {
    await pump(tester);
    final int requests = source.requests.length;
    // Not awaited: its future waits on a frame, which only the pumps below produce.
    unawaited(tester.binding.reassembleApplication());
    await tester.pump();
    await tester.pump();
    expect(source.requests, hasLength(requests + 1));
    await finish(tester);
  });

  testWidgets('insets come from the ShellScope; pinning and an edge drag move no card', (tester) async {
    create(shell: ShellController());
    await pump(tester);
    expect(viewportOf(tester).insets, const EdgeInsets.fromLTRB(76, 60, 158, 12));
    final Map<String, Offset> before = onScreen(tester);
    expect(before, isNotEmpty);
    for (final left in <double>[388, 400, 420, 76]) {
      host.insets = GraphInsets(top: 60, left: left, right: 484, bottom: 12, inspectorWidth: 460, minimapWidth: 134);
      await tester.pumpWidget(host.build());
      expect(viewportOf(tester).insets, EdgeInsets.fromLTRB(left, 60, 484, 12));
      for (final MapEntry<String, Offset>(:key, :value) in before.entries) {
        expect(tester.getTopLeft(cardOf(key)), value, reason: '$key at left $left');
      }
    }
    await finish(tester);
  });

  testWidgets('the inspector opening scrolls a covered selection clear; an uncovered one and a width drag stay (I4)', (
    tester,
  ) async {
    const closed = GraphInsets(top: 60, left: 76, right: 158, bottom: 12, inspectorWidth: 0, minimapWidth: 134);
    const open = GraphInsets(top: 60, left: 76, right: 484, bottom: 12, inspectorWidth: 460, minimapWidth: 0);
    create(shell: ShellController());
    host.insets = closed;
    await pump(tester);
    final Rect openArea = visible(const EdgeInsets.fromLTRB(76, 60, 484, 12));
    Rect rectOf(String key) => tester.getRect(cardOf(key));
    final Map<String, Offset> shown = onScreen(tester);
    // Covered: wholly in the closed visible rect, but not inside the open one.
    final String covered = shown.keys.firstWhere((key) {
      final Rect card = rectOf(key);
      return card.left >= 76 && card.right <= 800 - 158 && card.right > openArea.right;
    });
    model.select(covered);
    await tester.pump();
    host.insets = open;
    await tester.pumpWidget(host.build());
    await tester.pumpAndSettle();
    // A covered card is centred in the rect the open inspector leaves (`GraphRevealAlignment.covered`).
    expect(rectOf(covered).center.dx, moreOrLessEquals(openArea.center.dx, epsilon: 1));

    // A width drag moves nothing.
    final Map<String, Offset> before = onScreen(tester);
    host.insets = const GraphInsets(top: 60, left: 76, right: 544, bottom: 12, inspectorWidth: 520, minimapWidth: 0);
    await tester.pumpWidget(host.build());
    await tester.pumpAndSettle();
    for (final MapEntry<String, Offset>(:key, :value) in before.entries) {
      expect(tester.getTopLeft(cardOf(key)), value, reason: key);
    }

    // Closed again, then opened over an uncovered selection: nothing moves.
    host.insets = closed;
    await tester.pumpWidget(host.build());
    await tester.pumpAndSettle();
    final Map<String, Offset> rest = onScreen(tester);
    // Uncovered: the card itself (inside its overhang) lies wholly in the open visible rect.
    final String inside = rest.keys.firstWhere((key) {
      final Rect card = rectOf(key).deflate(graphCardOverhang);
      return card.left >= openArea.left && card.right <= openArea.right && card.top >= openArea.top + 40;
    });
    model.select(inside);
    await tester.pump();
    host.insets = open;
    await tester.pumpWidget(host.build());
    await tester.pumpAndSettle();
    for (final MapEntry<String, Offset>(:key, :value) in rest.entries) {
      expect(tester.getTopLeft(cardOf(key)), value, reason: key);
    }
    await finish(tester);
  });

  testWidgets('outside a shell the insets parameter applies', (tester) async {
    create();
    await tester.pumpWidget(wrap(GraphView(model: model, insets: const EdgeInsets.only(left: 30))));
    await tester.pump();
    expect(viewportOf(tester).insets, const EdgeInsets.only(left: 30));
    await finish(tester);
  });

  testWidgets('a 45 px mouse pan reports ≥ 30 px and turns calm on; a programmatic reveal reports nothing', (
    tester,
  ) async {
    final shell = _Recorder();
    create(shell: shell);
    await pump(tester);
    final RenderGraphViewport render = viewportOf(tester);
    bool clear(Offset p) => <Offset>[
      for (final double dx in <double>[-14, 0, 14])
        for (final double dy in <double>[-14, 0, 14]) p + Offset(dx, dy),
    ].every((q) => !render.isOnCard(q));
    final Offset spot = <Offset>[
      for (double y = 120; y < 560; y += 7)
        for (double x = 120; x < 620; x += 7) Offset(x, y),
    ].firstWhere(clear);
    final TestGesture gesture = await tester.startGesture(spot, kind: PointerDeviceKind.mouse);
    for (var i = 0; i < 3; i++) {
      await gesture.moveBy(const Offset(0, -15));
      await tester.pump();
    }
    await gesture.up();
    expect(shell.total, greaterThanOrEqualTo(30));
    expect(shell.calm.value.calm, isTrue);

    await tester.pump(const Duration(seconds: 1));
    shell.reported.clear();
    model.scrollToWorkingCopy();
    await tester.pumpAndSettle();
    expect(tester.getCenter(cardOf('r100')), visible(render.insets).center);
    expect(shell.reported, isEmpty);
    await finish(tester);
  });

  testWidgets(
    'a fling reports its glide after the drag, not the drag itself',
    (tester) async {
      final shell = _Recorder();
      create(shell: shell);
      await pump(tester);
      final RenderGraphViewport render = viewportOf(tester);
      await tester.flingFrom(const Offset(400, 400), const Offset(0, -240), 1500);
      expect(shell.reported, isEmpty, reason: 'the drag is the shell trackpad/touch counting, not ours');
      final double atUp = render.verticalOffset.pixels;
      await tester.pumpAndSettle();
      final double glide = (render.verticalOffset.pixels - atUp).abs();
      expect(glide, greaterThan(0));
      expect(shell.total, closeTo(glide, 1));
      await finish(tester);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets("now: the model's now reaches the cards, and the window turning active refreshes it and reloads once", (
    tester,
  ) async {
    await pump(tester);
    expect(cardsOf(tester).now.value, noon.millisecondsSinceEpoch);
    final int requests = source.requests.length;
    clock = noon.add(const Duration(minutes: 7));
    host.appearance = const ZsAppearance(inactive: true);
    await tester.pumpWidget(host.build());
    await tester.pump();
    expect(cardsOf(tester).now.value, noon.millisecondsSinceEpoch);
    expect(source.requests, hasLength(requests), reason: 'turning inactive reloads nothing');
    host.appearance = const ZsAppearance();
    await tester.pumpWidget(host.build());
    await tester.pump();
    expect(model.now.value, clock.millisecondsSinceEpoch);
    expect(cardsOf(tester).now.value, clock.millisecondsSinceEpoch);
    expect(source.requests, hasLength(requests + 1), reason: 'turning active reloads the graph once');
    await finish(tester);
  });

  testWidgets('the selection is the same in the cards and the model', (tester) async {
    await pump(tester);
    cardsOf(tester).select('r101');
    expect(model.selected, 'r101');
    model.select(null);
    await tester.pump();
    expect(cardsOf(tester).selected.value, isNull);
    model.select('r99');
    await tester.pump();
    expect(cardsOf(tester).selected.value, 'r99');
    await finish(tester);
  });

  testWidgets('a reload keeps the visible selection in place, else the centre card', (tester) async {
    await pump(tester);
    model.select('r99');
    await tester.pump();
    final Offset selected = tester.getTopLeft(cardOf('r99'));
    expect(tester.getCenter(cardOf('r99')), isNot(visible(EdgeInsets.zero).center));
    // The centre card (@, r100) moves to column 0, the selection does not: the selection is the anchor.
    source.respond = (_) => chainAt(200, at: 'r100', colOf: const <String, int>{'r100': 0});
    await heads(tester);
    expect(tester.getTopLeft(cardOf('r99')), selected);

    final RenderGraphViewport render = viewportOf(tester);
    render.verticalOffset.jumpTo(render.verticalOffset.pixels + 3000);
    await tester.pump();
    var centre = '';
    double best = double.infinity;
    for (final Element element in find.byType(GraphCard, skipOffstage: false).evaluate()) {
      final card = element.widget as GraphCard;
      final double d = (tester.getCenter(find.byWidget(card)) - surface.center(Offset.zero)).distanceSquared;
      if (d < best) {
        best = d;
        centre = card.layout.keyOf(card.node);
      }
    }
    final Offset at = tester.getTopLeft(cardOf(centre));
    // Off screen, the selection moving column (and a new head) does not anchor: the centre card does.
    source.respond = (_) =>
        chainAt(200, at: 'r100', heads: <String>['h1'], colOf: const <String, int>{'r100': 0, 'r99': 0});
    await heads(tester);
    expect(tester.getTopLeft(cardOf(centre)), at);
    expect(model.selected, 'r99');
    await finish(tester);
  });

  testWidgets('a revset switch centres @ in that relayout; a card-width change and an event reload do not', (
    tester,
  ) async {
    await pump(tester);
    final RenderGraphViewport render = viewportOf(tester);
    render.verticalOffset.jumpTo(render.verticalOffset.pixels + 2000);
    await tester.pump();
    model.setRevset('all()');
    await tester.pump();
    await tester.pump();
    expect(tester.getCenter(cardOf('r100')), visible(EdgeInsets.zero).center);

    render.verticalOffset.jumpTo(render.verticalOffset.pixels - 250);
    await tester.pump();
    final int requests = source.requests.length;
    host.options = const GraphViewOptions(cardWidth: 300);
    await tester.pumpWidget(host.build());
    expect(source.requests, hasLength(requests), reason: 'a card size needs no layout request');
    expect(tester.getCenter(cardOf('r100')), isNot(visible(EdgeInsets.zero).center));
    await heads(tester);
    expect(tester.getCenter(cardOf('r100')), isNot(visible(EdgeInsets.zero).center));
    await finish(tester);
  });

  for (final cause in <String>['stale', 'sibling_operation', 'operation_not_found']) {
    testWidgets('stale ($cause): the notice names the command, carries jj message, offers the update; the cards stay', (
      tester,
    ) async {
      await pump(tester);
      source.respond = (_) => throw staleError(cause);
      await heads(tester);
      final GraphStale stale = model.stale!;
      await tester.pumpWidget(
        wrap(
          Stack(
            children: <Widget>[
              Positioned.fill(child: GraphView(model: model)),
              Positioned(top: 12, left: 0, right: 0, child: Center(child: GraphView.staleNotice(model))),
            ],
          ),
        ),
      );
      expect(find.text('Working copy is stale'), findsOneWidget);
      expect(find.text(stale.command), findsOneWidget);
      expect(
        stale.command,
        cause == 'sibling_operation' ? 'jj op integrate aaaaaaaaaaaa' : 'jj workspace update-stale',
      );
      expect(find.byWidgetPredicate((w) => w is ZsTooltip && w.message == stale.message), findsOneWidget);
      expect(find.text('Update working copy'), findsOneWidget);
      expect(find.byType(GraphCard), findsWidgets, reason: 'the last layout still renders');
      await tester.tap(find.text('Update working copy'));
      await tester.pump();
      expect(source.updates, 1);
      await finish(tester);
    });
  }

  testWidgets('no notice slot without a stale working copy', (tester) async {
    await pump(tester);
    expect(GraphView.staleNotice(model), isNull);
    await finish(tester);
  });

  testWidgets('a failed load shows the caption with Retry, which requests again; an empty one its caption', (
    tester,
  ) async {
    source.respond = (_) => throw const ZanshinFfiException('jj.io_error');
    await pump(tester);
    expect(find.text('The graph could not be loaded (jj.io_error).'), findsOneWidget);
    source.respond = (_) => chainAt(0, at: '');
    await tester.tap(find.text('Retry'));
    await tester.pump();
    await tester.pump();
    expect(source.requests, hasLength(2));
    expect(find.text('No changes match this revset.'), findsOneWidget);

    // A revset error after the empty layout keeps that layout but drops the empty caption (10.21 shows the error).
    source.respond = (_) => throw const ZanshinFfiException('jj.revset_parse_error', 'bad');
    model.setRevset('bad(');
    await tester.pump();
    await tester.pump();
    expect(model.revsetError, isNotNull);
    expect(find.text('No changes match this revset.'), findsNothing);
    await finish(tester);
  });

  testWidgets('the day axis gets a new painter when "now" crosses local midnight, not on a same-day tick', (
    tester,
  ) async {
    // The layout's offset is 0, so its local midnight is UTC midnight.
    clock = DateTime.utc(2026, 10, 30, 23, 58, 30);
    await pump(tester);
    final GraphPaintHook? before = viewportOf(tester).paintBackground;
    expect(before, isNotNull);

    clock = DateTime.utc(2026, 10, 30, 23, 59);
    await tester.pump(const Duration(seconds: 30));
    await tester.pump();
    expect(cardsOf(tester).now.value, clock.millisecondsSinceEpoch, reason: 'the minute tick reached the cards');
    expect(viewportOf(tester).paintBackground, before, reason: 'the same day keeps the painter');

    clock = DateTime.utc(2026, 10, 31);
    await tester.pump(const Duration(minutes: 1));
    await tester.pump();
    expect(cardsOf(tester).now.value, clock.millisecondsSinceEpoch);
    expect(viewportOf(tester).paintBackground, isNot(before), reason: 'a new day, a new painter');
    await finish(tester);
  });

  group('Story 10.6', () {
    /// @ `w` on mutable `m`, on immutable `i`, on the root; each with content and a timestamp an hour before noon.
    RecordedGraphLayout peekLayout() => handLayout(
      const <(String, int, int)>[
        ('wkmnvxoqrstl', 3, 0),
        ('mzvqrstklnwp', 2, 0),
        ('ivxzkqlmtnrw', 1, 0),
        ('zzzzzzzz', 0, 0),
      ],
      edges: const <(int, int)>[(0, 1), (1, 2), (2, 3)],
      workingCopy: 0,
      root: 3,
      flags: const <int>[0, 0, RecordedGraphLayout.flagImmutable, RecordedGraphLayout.flagImmutable],
      prefixLengths: const <int>[2, 3, 2, 1],
      // @ is also four other workspaces' working copy: its `+N` tag folds some of them.
      workspaces: const <List<String>>[
        <String>['default', 'ci', 'docs', 'release', 'scratch'],
        <String>[],
        <String>[],
        <String>[],
      ],
      workspaceName: 'default',
      timestamps: <int?>[for (var i = 0; i < 3; i++) noon.millisecondsSinceEpoch - 3600000, null],
      contents: const <GraphCommitContent?>[
        GraphCommitContent(subject: 'wip: the working copy', authorName: 'Ralph Stein'),
        GraphCommitContent(subject: 'feat(onboarding): swipe gestures', authorName: 'Lena König'),
        GraphCommitContent(subject: 'release: 1.4', authorEmail: 'bob@example.com'),
        null,
      ],
    );

    Future<TestGesture> hover(WidgetTester tester, Offset at) async {
      final TestGesture mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: at);
      addTearDown(mouse.removePointer);
      await tester.pump();
      return mouse;
    }

    Future<void> leaveAll(WidgetTester tester, TestGesture mouse) async {
      await mouse.moveTo(const Offset(799, 599));
      await tester.pump(graphHoverIntent);
      await tester.pumpAndSettle();
    }

    FocusNode graphFocus(WidgetTester tester) => tester
        .widget<Focus>(find.byWidgetPredicate((w) => w is Focus && w.focusNode?.debugLabel == 'graph'))
        .focusNode!;

    testWidgets('Esc closes an open menu, then clears the selection, only while the graph has focus', (tester) async {
      await pump(tester);
      final GraphCardController cards = cardsOf(tester)..select('r104');
      await tester.pumpAndSettle();
      cards.menuOpen.value = 'r104';
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      expect(cards.menuOpen.value, 'r104', reason: 'the graph has no focus yet');
      graphFocus(tester).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      expect(cards.menuOpen.value, isNull);
      expect(model.selected, 'r104');
      await tester.pumpAndSettle();
      final RenderGraphViewport render = viewportOf(tester);
      final scroll = Offset(render.horizontalOffset.pixels, render.verticalOffset.pixels);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      expect(model.selected, isNull);
      await tester.pumpAndSettle();
      expect(cards.focused.value, 'r104', reason: 'the focus card stays, it does not fall back to @');
      expect(
        Offset(render.horizontalOffset.pixels, render.verticalOffset.pixels),
        scroll,
        reason: 'Esc scrolls nothing',
      );

      // A click still in its double-click window does not select after Esc.
      await tester.tapAt(tester.getCenter(cardOf('r100')));
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump(graphDoubleClickWindow * 2);
      expect(model.selected, isNull);
      await finish(tester);
    });

    testWidgets('the graph is one Tab stop: its focus card is @, then the selection; Enter selects it', (tester) async {
      await pump(tester);
      final GraphCardController cards = cardsOf(tester);
      final FocusNode node = graphFocus(tester);
      expect(node.canRequestFocus && !node.skipTraversal, isTrue);
      expect(
        find.byWidgetPredicate((w) => w is Focus && w.focusNode != null && w.focusNode!.debugLabel == 'graph'),
        findsOneWidget,
      );
      node.requestFocus();
      await tester.pump();
      expect(node.hasFocus, isTrue);
      expect(cards.focused.value, 'r100');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(model.selected, 'r100');
      model.select('r99');
      await tester.pump();
      expect(cards.focused.value, 'r99');
      model.select(null);
      await tester.pump();
      expect(cards.focused.value, 'r99', reason: 'a cleared selection keeps the focus card');
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      expect(model.selected, 'r99', reason: 'Space selects the focus card');
      graphFocus(tester).unfocus();
      await tester.pump();
      expect(cards.focused.value, isNull);
      await tester.pumpAndSettle();
      await finish(tester);
    });

    testWidgets('keyboard focus on an off-screen focus card reveals it wholly inside the visible rect', (tester) async {
      FocusManager.instance.highlightStrategy = FocusHighlightStrategy.alwaysTraditional;
      addTearDown(() => FocusManager.instance.highlightStrategy = FocusHighlightStrategy.automatic);
      await pump(tester);
      model.select('r150');
      await tester.pump();
      final Rect area = visible(viewportOf(tester).insets);
      bool inside() {
        final Finder card = cardOf('r150');
        if (card.evaluate().isEmpty) {
          return false;
        }
        final Rect r = tester.getRect(card).deflate(graphCardOverhang);
        return r.left >= area.left && r.top >= area.top && r.right <= area.right && r.bottom <= area.bottom;
      }

      expect(inside(), isFalse, reason: 'r150 starts off screen');
      graphFocus(tester).requestFocus();
      await tester.pumpAndSettle();
      expect(cardsOf(tester).focused.value, 'r150');
      expect(inside(), isTrue);
      await finish(tester);
    });

    testWidgets(
      'a mouse press that focuses the graph shows no focus card and does not scroll to the selection (macOS)',
      (tester) async {
        await pump(tester);
        model.select('r150');
        await tester.pumpAndSettle();
        final RenderGraphViewport render = viewportOf(tester);
        final scroll = Offset(render.horizontalOffset.pixels, render.verticalOffset.pixels);
        final TestGesture mouse = await tester.startGesture(const Offset(790, 590), kind: PointerDeviceKind.mouse);
        await mouse.up();
        await tester.pumpAndSettle();
        expect(graphFocus(tester).hasFocus, isTrue);
        expect(FocusManager.instance.highlightMode, FocusHighlightMode.traditional);
        expect(cardsOf(tester).focused.value, isNull, reason: 'no keyboard ring after a press');
        expect(Offset(render.horizontalOffset.pixels, render.verticalOffset.pixels), scroll);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(cardsOf(tester).focused.value, 'r150', reason: 'a key shows the focus card again');
        await finish(tester);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    );

    testWidgets('a double-click on a mutable card in the view runs edit through the model', (tester) async {
      final actions = _Actions();
      create(actions: actions);
      await pump(tester);
      final Offset at = tester.getCenter(cardOf('r100'));
      await tester.tapAt(at);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tapAt(at);
      await tester.pumpAndSettle();
      expect(actions.ran.map((a) => a.command), <String>['jj edit r100']);
      expect(model.selected, isNull);
      await finish(tester);
    });

    testWidgets("while an action runs the viewport anchors on the model's anchor hint, then on the selection", (
      tester,
    ) async {
      final actions = _Actions()..gate = Completer<MutationResult>();
      create(actions: actions);
      await pump(tester);
      model.select('r150');
      unawaited(model.run(const GraphAbandon(<String>['r100'])));
      await tester.pump();
      expect(model.anchorHint, 'r99');
      expect(viewportOf(tester).anchorKey, model.anchorHint);
      actions.gate!.complete(
        const MutationResult(
          newOpId: 'op9',
          newChangeIds: <String>[],
          abandonedChangeIds: <String>['r100'],
          workingCopyChangeId: null,
          finish: null,
        ),
      );
      await tester.pumpAndSettle();
      expect(model.anchorHint, isNull);
      expect(viewportOf(tester).anchorKey, isNull, reason: 'abandon cleared the selection');
      await finish(tester);
    });

    testWidgets('while edit runs its card paints pending, the affordances are off and a second double-click runs '
        'nothing (I2)', (tester) async {
      final actions = _Actions()..gate = Completer<MutationResult>();
      create(actions: actions);
      await pump(tester);
      Future<void> doubleClick(String key) async {
        final Offset at = tester.getCenter(cardOf(key));
        await tester.tapAt(at);
        await tester.pump(const Duration(milliseconds: 50));
        await tester.tapAt(at);
        await tester.pump();
      }

      await doubleClick('r100');
      await tester.pump();
      final GraphLayout layout = model.layout!;
      final double disabled = ZsMetrics.of(tester.element(find.byType(GraphCanvas))).disabledOpacity;
      expect(viewportOf(tester).opacityOf!(layout.indexOfKey('r100')!), disabled);
      expect(viewportOf(tester).opacityOf!(layout.indexOfKey('r99')!), 1);
      expect(cardsOf(tester).actionsEnabled.value, isFalse);
      await doubleClick('r100');
      await doubleClick('r99');
      expect(actions.ran, hasLength(1));

      actions.gate!.complete(
        const MutationResult(
          newOpId: 'op9',
          newChangeIds: <String>[],
          abandonedChangeIds: <String>[],
          workingCopyChangeId: null,
          finish: null,
        ),
      );
      await tester.pumpAndSettle();
      expect(viewportOf(tester).opacityOf, isNull);
      expect(cardsOf(tester).actionsEnabled.value, isTrue);
      expect(source.requests, hasLength(2), reason: 'one reload after the edit');
      await finish(tester);
    });

    testWidgets('a click on a card under the left inset centres it in the visible rect; a visible one does not move', (
      tester,
    ) async {
      create(shell: ShellController());
      await pump(tester);
      final RenderGraphViewport render = viewportOf(tester);
      final Rect area = visible(render.insets);
      // @ (r100) lies centred, wholly visible: selecting it scrolls nothing.
      final scroll = Offset(render.horizontalOffset.pixels, render.verticalOffset.pixels);
      await tester.tapAt(tester.getCenter(cardOf('r100')));
      await tester.pump(graphDoubleClickWindow);
      await tester.pumpAndSettle();
      expect(model.selected, 'r100');
      expect(Offset(render.horizontalOffset.pixels, render.verticalOffset.pixels), scroll);

      final Rect r99 = tester.getRect(cardOf('r99')).deflate(graphCardOverhang);
      expect(r99.left < area.left && r99.right > area.left, isTrue, reason: 'r99 sits half under the rail');
      await tester.tapAt(Offset(r99.right - 20, r99.center.dy));
      await tester.pump(graphDoubleClickWindow);
      await tester.pumpAndSettle();
      expect(model.selected, 'r99');
      expect(tester.getCenter(cardOf('r99')), area.center);
      await finish(tester);
    });

    testWidgets('calm scrolling and an inactive window clear the hover and keep it off', (tester) async {
      final shell = ShellController();
      create(shell: shell);
      await pump(tester);
      final GraphCardController cards = cardsOf(tester);
      final TestGesture mouse = await hover(tester, tester.getCenter(cardOf('r100')));
      expect(cards.hovered.value, 'r100');
      shell.calm.addUserScroll(40);
      await tester.pump();
      expect(shell.calm.value.calm, isTrue);
      expect(cards.hovered.value, isNull);
      await mouse.moveBy(const Offset(1, 0));
      await tester.pump();
      expect(cards.hovered.value, isNull, reason: 'ignored while calm');
      await tester.pump(const Duration(seconds: 2));
      expect(shell.calm.value.calm, isFalse);
      await mouse.moveBy(const Offset(1, 0));
      await tester.pump();
      expect(cards.hovered.value, 'r100');
      host.appearance = const ZsAppearance(inactive: true);
      await tester.pumpWidget(host.build());
      expect(cards.hovered.value, isNull);
      await leaveAll(tester, mouse);
      await finish(tester);
    });

    testWidgets('@ wholly below: direction down, the pill reads "Working copy, below" and its tap reveals @ only', (
      tester,
    ) async {
      final SemanticsHandle semantics = tester.ensureSemantics();
      create();
      tester.view
        ..physicalSize = surface
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        wrap(
          Stack(
            children: <Widget>[
              Positioned.fill(child: GraphView(model: model)),
              Positioned(bottom: 20, left: 0, right: 0, child: Center(child: GraphView.atPill(model))),
            ],
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(model.workingCopyDirection.value, isNull);
      expect(find.text('Working copy'), findsNothing);
      model.select('r150');
      final RenderGraphViewport render = viewportOf(tester);
      render.verticalOffset.jumpTo(render.verticalOffset.pixels - 1000);
      await tester.pump();
      expect(model.workingCopyDirection.value, GraphDirection.down);
      await tester.pumpAndSettle();
      final Finder pill = find.bySemanticsLabel('Working copy, below');
      expect(pill, findsOneWidget);
      await tester.tap(find.text('Working copy'));
      await tester.pumpAndSettle();
      expect(tester.getCenter(cardOf('r100')), visible(viewportOf(tester).insets).center);
      expect(model.selected, 'r150');
      expect(model.workingCopyDirection.value, isNull);
      await tester.pumpAndSettle();
      expect(find.text('Working copy'), findsNothing, reason: 'the pill fades out');
      semantics.dispose();
      await finish(tester);
    });

    /// Pumps the view with the pill under it, @ at [at].
    Future<void> pumpWithPill(WidgetTester tester, String at) async {
      source = ScriptedGraphSource(respond: (_) => chainAt(200, at: at));
      create();
      tester.view
        ..physicalSize = surface
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        wrap(
          Stack(
            children: <Widget>[
              Positioned.fill(child: GraphView(model: model)),
              Positioned(bottom: 20, left: 0, right: 0, child: Center(child: GraphView.atPill(model))),
            ],
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
    }

    for (final (GraphDirection direction, String at, Offset by, String label)
        in <(GraphDirection, String, Offset, String)>[
          (GraphDirection.up, 'r100', const Offset(0, 1000), 'Working copy, above'),
          (GraphDirection.right, 'r100', const Offset(-600, 0), 'Working copy, right'),
          (GraphDirection.left, 'r96', const Offset(600, 0), 'Working copy, left'),
        ]) {
      testWidgets('@ wholly ${direction.name} of the visible rect: the pill reads "$label"', (tester) async {
        final SemanticsHandle semantics = tester.ensureSemantics();
        await pumpWithPill(tester, at);
        expect(model.workingCopyDirection.value, isNull);
        final RenderGraphViewport render = viewportOf(tester);
        render.horizontalOffset.jumpTo(render.horizontalOffset.pixels + by.dx);
        render.verticalOffset.jumpTo(render.verticalOffset.pixels + by.dy);
        await tester.pump();
        expect(model.workingCopyDirection.value, direction);
        await tester.pumpAndSettle();
        expect(find.bySemanticsLabel(label), findsOneWidget);
        semantics.dispose();
        await finish(tester);
      });
    }

    testWidgets('@ within 8 px of the visible rect still has a direction; deeper inside it has none', (tester) async {
      await pumpWithPill(tester, 'r100');
      final RenderGraphViewport render = viewportOf(tester);
      final double top = tester.getRect(cardOf('r100')).top + graphCardOverhang;
      // The card's top 4 px below the bottom edge minus the margin (592): it still overlaps the viewport.
      render.verticalOffset.jumpTo(render.verticalOffset.pixels - (596 - top));
      await tester.pump();
      expect(tester.getRect(cardOf('r100')).top + graphCardOverhang, 596);
      expect(model.workingCopyDirection.value, GraphDirection.down);
      render.verticalOffset.jumpTo(render.verticalOffset.pixels + 16);
      await tester.pump();
      expect(model.workingCopyDirection.value, isNull, reason: 'its top lies 12 px inside the margin');
      await tester.pumpAndSettle();
      await finish(tester);
    });

    testWidgets('a hover dims every card outside the focus path to .4 by opacity layers and builds no card', (
      tester,
    ) async {
      source = ScriptedGraphSource(
        respond: (_) => handLayout(
          const <(String, int, int)>[('a', 2, 0), ('b', 1, 0), ('c', 1, 1), ('root', 0, 0)],
          edges: const <(int, int)>[(0, 1), (1, 3), (2, 3)],
          root: 3,
        ),
      );
      await pump(tester);
      // Content landing rebuilds its cards (Story 10.11): let it land first.
      await tester.pump(graphContentSettle);
      await tester.pump();
      // A card build makes a new leaf widget.
      Set<Widget> leaves() =>
          tester.widgetList(find.byWidgetPredicate((w) => w.runtimeType.toString() == '_GraphCardLeaf')).toSet();
      final Set<Widget> before = leaves();
      final TestGesture mouse = await hover(tester, tester.getCenter(cardOf('b')));
      await tester.pump(ZsMotion.full.durHover);
      final RenderGraphViewport render = viewportOf(tester);
      final GraphLayout layout = model.layout!;
      expect(render.opacityOf!(layout.indexOfKey('c')!), closeTo(.4, 1e-9));
      for (final key in <String>['a', 'b', 'root']) {
        expect(render.opacityOf!(layout.indexOfKey(key)!), 1, reason: key);
      }
      final Iterable<OpacityLayer> dimmed = tester.layers.whereType<OpacityLayer>().where(
        (layer) => layer.alpha == Color.getAlphaFromOpacity(.4),
      );
      expect(dimmed, hasLength(1));
      // The edges: c → root (off the path) dims to .28, a → b and b → root take the hover tone.
      final GraphTheme theme = GraphTheme.of(tester.element(find.byType(GraphCanvas)));
      final colors = <int>[];
      expect(
        render,
        paints..everything((method, args) {
          if (method == #drawPath) {
            colors.add((args[1] as Paint).color.toARGB32());
          }
          return true;
        }),
      );
      expect(colors, contains(theme.edge.withValues(alpha: theme.edge.a * (1 - .72)).toARGB32()));
      expect(colors, contains(theme.edgeHover.toARGB32()));
      expect(colors, isNot(contains(theme.edge.toARGB32())), reason: 'no off-path edge stays undimmed');
      expect(leaves().every((leaf) => before.any((old) => identical(old, leaf))), isTrue, reason: 'no card was built');
      await leaveAll(tester, mouse);
      expect(viewportOf(tester).opacityOf, isNull, reason: 'the dim faded out');
      await finish(tester);
    });

    testWidgets(
      'pending cards paint at disabledOpacity on the focus path and × .4 off it; the hovered card stays at 1',
      (
        tester,
      ) async {
        source = ScriptedGraphSource(
          respond: (_) => handLayout(
            const <(String, int, int)>[('a', 2, 0), ('b', 1, 0), ('c', 1, 1), ('root', 0, 0)],
            edges: const <(int, int)>[(0, 1), (1, 3), (2, 3)],
            root: 3,
          ),
        );
        final actions = _Actions()..gate = Completer<MutationResult>();
        create(actions: actions);
        await pump(tester);
        final TestGesture mouse = await hover(tester, tester.getCenter(cardOf('b')));
        await tester.pump(ZsMotion.full.durHover);
        unawaited(model.run(const GraphAbandon(<String>['a', 'c'])));
        await tester.pump();
        expect(actions.ran, hasLength(1));
        final RenderGraphViewport render = viewportOf(tester);
        final GraphLayout layout = model.layout!;
        final double disabled = ZsMetrics.of(tester.element(find.byType(GraphCanvas))).disabledOpacity;
        expect(render.opacityOf!(layout.indexOfKey('c')!), closeTo(disabled * .4, 1e-9));
        expect(render.opacityOf!(layout.indexOfKey('a')!), closeTo(disabled, 1e-9), reason: 'pending, on the path');
        expect(render.opacityOf!(layout.indexOfKey('b')!), 1);

        actions.gate!.complete(
          const MutationResult(
            newOpId: 'op9',
            newChangeIds: <String>[],
            abandonedChangeIds: <String>[],
            workingCopyChangeId: null,
            finish: null,
          ),
        );
        await tester.pumpAndSettle();
        // The run is over, the hover stays: only the dim is left.
        expect(viewportOf(tester).opacityOf!(model.layout!.indexOfKey('c')!), closeTo(.4, 1e-9));
        expect(viewportOf(tester).opacityOf!(model.layout!.indexOfKey('a')!), 1);
        await leaveAll(tester, mouse);
        await finish(tester);
      },
    );

    group('the peek', () {
      setUp(() => source = ScriptedGraphSource(respond: (_) => peekLayout()));

      testWidgets('after 450 ms on a mutable body: subject, id, author, date and the hint; leaving closes it', (
        tester,
      ) async {
        await pump(tester);
        final TestGesture mouse = await hover(tester, tester.getCenter(cardOf('mzvqrstklnwp')));
        await tester.pump(ZsMotion.full.delayPeek - const Duration(milliseconds: 1));
        expect(find.byType(GraphPeek), findsNothing);
        await tester.pump(const Duration(milliseconds: 1));
        await tester.pump();
        expect(find.byType(GraphPeek), findsOneWidget);
        expect(find.text('feat(onboarding): swipe gestures'), findsOneWidget);
        expect(find.text('Lena König'), findsOneWidget);
        expect(find.text('1h'), findsOneWidget);
        expect(find.text('Click: details · Double-click: jj edit'), findsOneWidget);
        expect(find.textContaining('IMMUTABLE'), findsNothing);
        final RichText id = tester
            .widgetList<RichText>(find.descendant(of: find.byType(GraphPeek), matching: find.byType(RichText)))
            .firstWhere((t) => t.text.toPlainText() == 'mzvqrstk');
        final runs = <(String, FontWeight?)>[];
        id.text.visitChildren((span) {
          if (span is TextSpan && span.text != null) {
            runs.add((span.text!, span.style?.fontWeight));
          }
          return true;
        });
        expect(runs, <(String, FontWeight?)>[('mzv', FontWeight.w700), ('qrstk', null)], reason: 'jj prefix bold');
        expect(viewportOf(tester).pinnedKeys, contains('mzvqrstklnwp'));
        final Rect peek = tester.getRect(find.byType(GraphPeek));
        final Rect card = tester.getRect(cardOf('mzvqrstklnwp')).deflate(graphCardOverhang);
        expect(peek.left, card.right + 8);
        expect(peek.top, card.top);
        // Across the 8 px gap into the peek: the hover and the peek stay.
        await mouse.moveTo(Offset(card.right + 4, card.top + 20));
        await tester.pump(const Duration(milliseconds: 50));
        await mouse.moveTo(peek.center);
        await tester.pump(graphHoverIntent * 2);
        expect(cardsOf(tester).hovered.value, 'mzvqrstklnwp');
        expect(find.byType(GraphPeek), findsOneWidget);
        // Out of the peek onto empty canvas: both clear after the intent.
        await mouse.moveTo(Offset(peek.right + 20, peek.center.dy));
        await tester.pump(graphHoverIntent + const Duration(milliseconds: 1));
        expect(cardsOf(tester).hovered.value, isNull);
        await tester.pumpAndSettle();
        expect(find.byType(GraphPeek), findsNothing);
        await leaveAll(tester, mouse);
        await finish(tester);
      }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

      testWidgets('the eyebrow on an immutable change only; @ and the root have their own hints', (tester) async {
        await pump(tester);
        final TestGesture mouse = await hover(tester, tester.getCenter(cardOf('ivxzkqlmtnrw')));
        await tester.pump(ZsMotion.full.delayPeek);
        await tester.pump();
        expect(find.text('IMMUTABLE'), findsOneWidget);
        expect(find.text('Click: details'), findsOneWidget);
        expect(find.text('bob@example.com'), findsOneWidget);

        for (final (String key, String? hint) in <(String, String?)>[
          ('wkmnvxoqrstl', 'Working copy (@) · Click for details'),
          ('zzzzzzzz', null),
        ]) {
          await mouse.moveTo(tester.getCenter(cardOf(key)));
          await tester.pump(ZsMotion.full.delayPeek);
          await tester.pump();
          expect(find.text('IMMUTABLE'), findsNothing, reason: key);
          if (hint == null) {
            expect(find.text('root()'), findsNWidgets(1));
            expect(find.textContaining('Click'), findsNothing);
          } else {
            expect(find.text(hint), findsOneWidget);
          }
        }
        await leaveAll(tester, mouse);
        await finish(tester);
      }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

      testWidgets('over •••: no peek, but the tooltip after its delay; an open menu and calm keep the peek closed', (
        tester,
      ) async {
        final shell = ShellController();
        create(shell: shell);
        await pump(tester);
        final GraphCardController cards = cardsOf(tester);
        final Finder card = cardOf('mzvqrstklnwp');
        final TestGesture mouse = await hover(tester, tester.getCenter(card));
        await tester.pump(const Duration(milliseconds: 200));
        final Rect box = tester.getRect(card);
        // ••• sits 10 px from the right, its centre on the card's bottom edge (the overhang's 11 px below it).
        await mouse.moveTo(Offset(box.right - graphCardOverhang - 20, box.bottom - graphCardOverhang));
        await tester.pump(ZsMotion.full.delayTooltip);
        await tester.pump();
        expect(cards.hoverArea.value?.part, GraphCardHoverPart.more);
        expect(find.byType(GraphPeek), findsNothing);
        expect(find.text('Actions (or right-click the card)'), findsOneWidget);

        // @'s `+N` tag: its bubble names the folded workspaces.
        final RenderGraphCard at = tester.renderObject(cardOf('wkmnvxoqrstl'));
        final ({GraphCardSlot kind, Rect rect, String? text, TextStyle? style}) tag = at.debugSlots.firstWhere(
          (slot) => slot.kind == GraphCardSlot.moreTag,
        );
        await mouse.moveTo(at.localToGlobal(tag.rect.center));
        await tester.pump(ZsMotion.full.delayTooltip);
        await tester.pump();
        expect(cards.hoverArea.value?.part, GraphCardHoverPart.moreTag);
        final int folded = int.parse(tag.text!.substring(1));
        final others = <String>['ci', 'docs', 'release', 'scratch'];
        expect(find.text(others.sublist(others.length - folded).join(', ')), findsOneWidget);
        expect(find.text('Actions (or right-click the card)'), findsNothing);

        cards.menuOpen.value = 'mzvqrstklnwp';
        await mouse.moveTo(tester.getCenter(card));
        await tester.pump(ZsMotion.full.delayPeek * 2);
        expect(find.byType(GraphPeek), findsNothing, reason: 'a card menu is open');
        expect(find.text('Actions (or right-click the card)'), findsNothing);
        cards.menuOpen.value = null;
        shell.calm.addUserScroll(40);
        await tester.pump(ZsMotion.full.delayPeek * 2);
        expect(find.byType(GraphPeek), findsNothing, reason: 'calm');
        await tester.pump(const Duration(seconds: 2));
        await leaveAll(tester, mouse);
        await finish(tester);
      }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
    });

    group('goTo', () {
      /// The outer rect of every `drawDRRect` the viewport paints: only the pulse ring draws one.
      List<RRect> rings(WidgetTester tester) {
        final found = <RRect>[];
        expect(
          viewportOf(tester),
          paints..everything((method, args) {
            if (method == #drawDRRect) {
              found.add(args[0] as RRect);
            }
            return true;
          }),
        );
        return found;
      }

      for (final reduce in <bool>[false, true]) {
        testWidgets(
          'goTo selects and centres its target and pulses it 3 × 650 ms, then idles (reduce motion $reduce)',
          (
            tester,
          ) async {
            create();
            host.appearance = ZsAppearance(reduceMotion: reduce);
            await pump(tester);
            model.goTo('r104');
            await tester.pump();
            expect(model.selected, 'r104');
            expect(viewportOf(tester).pinnedKeys, contains('r104'));
            await tester.pump(graphPulseCycle ~/ 2);
            final RRect outer = rings(tester).single;
            final double spread = (outer.width - 240) / 2;
            if (reduce) {
              expect(spread, closeTo(2, 1e-6), reason: 'the spread holds under reduce motion');
            } else {
              expect(spread, greaterThan(10));
            }
            await tester.pump(graphPulseCycle);
            expect(rings(tester), hasLength(1), reason: 'the second pulse');
            // A repeat restarts it.
            model.goTo('r104');
            await tester.pump();
            await tester.pump(graphPulseCycle * 2 + graphPulseCycle ~/ 2);
            expect(rings(tester), hasLength(1));
            await tester.pumpAndSettle();
            expect(rings(tester), isEmpty);
            expect(viewportOf(tester).pinnedKeys, isNot(contains('r104')));
            expect(tester.getCenter(cardOf('r104')), visible(viewportOf(tester).insets).center);
            await finish(tester);
          },
        );
      }
    });
  });
}
