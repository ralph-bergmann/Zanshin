// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/l10n/app_localizations_en.dart';
import 'package:zanshin/src/features/graph/graph_canvas.dart';
import 'package:zanshin/src/features/graph/graph_card.dart';
import 'package:zanshin/src/features/graph/graph_card_menu.dart';
import 'package:zanshin/src/features/graph/graph_inspector.dart';
import 'package:zanshin/src/features/graph/graph_layout.dart';
import 'package:zanshin/src/features/graph/graph_ports.dart';
import 'package:zanshin/src/features/graph/graph_view.dart';
import 'package:zanshin/src/features/graph/graph_view_model.dart';
import 'package:zanshin/src/features/graph/inspector_viewed_store.dart';
import 'package:zanshin/src/features/graph/recorded_graph_layout.dart';
import 'package:zanshin_core/zanshin_core.dart';
import 'package:zanshin_settings/zanshin_settings.dart' show SettingsStore;
import 'package:zanshin_ui/zanshin_ui.dart';

import '../../helpers/fake_bookmark_list.dart';
import '../../helpers/icon_registry.dart';
import '../../helpers/scripted_graph_source.dart';
import '../../helpers/shell_host.dart';
import 'graph_harness.dart';

final _en = AppLocalizationsEn();

const _at = 'wwwwwwwwwwww';
// The fixture card of test-fixtures/commands/card-menu.txt: unique prefix 2, shown as `kmnvxoqp`.
const _b = 'kmnvxoqpzzzzzzzzzzzzzzzzzzzzzzzz';
const _side = 'ssssssssssss';
const _empty = 'aaaaaaaaaaaa';
const _merge = 'mmmmmmmmmmmm';
const _imm = 'iiiiiiiiiiii';
const _immChild = 'jjjjjjjjjjjj';
const _root = 'zzzzzzzzzzzz';
const _immParent = 'kkkkkkkkkkkk';
const _onImm = 'pppppppppppp';

const _keys = <String>[_at, _b, _side, _empty, _merge, _imm, _immChild, _root, _immParent, _onImm];

/// @ → B → A (empty) → the merge of I and J (both immutable); S beside B on A; I → root; J → K (immutable) → root;
/// P on I.
RecordedGraphLayout _layout() {
  const int imm = RecordedGraphLayout.flagImmutable;
  return handLayout(
    <(String, int, int)>[
      (_at, 6, 0),
      (_b, 5, 0),
      (_side, 5, 1),
      (_empty, 4, 0),
      (_merge, 3, 0),
      (_imm, 2, 0),
      (_immChild, 2, 1),
      (_root, 0, 0),
      (_immParent, 1, 1),
      (_onImm, 3, 2),
    ],
    edges: <(int, int)>[(0, 1), (1, 3), (2, 3), (3, 4), (4, 5), (4, 6), (5, 7), (6, 8), (8, 7), (9, 5)],
    workingCopy: 0,
    root: 7,
    parentCounts: const <int>[1, 1, 1, 1, 2, 1, 1, 0, 1, 1],
    flags: const <int>[0, 0, 0, 0, 0, imm, imm, imm, imm, 0],
    prefixLengths: const <int>[1, 2, 1, 1, 1, 1, 1, 1, 1, 1],
    commitIds: <String>[for (final String key in _keys) 'c$key'],
    refs: <List<GraphRef>>[
      for (final String key in _keys)
        if (key == _b)
          const <GraphRef>[GraphRef('b-mark'), GraphRef('b-mark', remote: 'origin'), GraphRef('b-mark', remote: 'git')]
        else
          const <GraphRef>[],
    ],
    contents: <GraphCommitContent?>[
      for (final String key in _keys)
        if (key == _root)
          null
        else
          GraphCommitContent(subject: 'about $key', description: 'about $key\n', empty: key == _empty),
    ],
    operationId: 'op0',
  );
}

final GraphLayout _l = _layout();

int _node(String key) => _l.indexOfKey(key)!;

List<ZsMenuEntry> _menu(
  String key, {
  String? blocked,
  ValueChanged<GraphAction>? run,
  ValueChanged<String>? onDescribe,
  ValueChanged<String>? onSquash,
}) => graphCardMenuEntries(
  _en,
  _l,
  _node(key),
  blocked: blocked,
  run: run ?? (_) {},
  onDescribe: onDescribe ?? (_) {},
  onSquash: onSquash,
);

List<ZsMenuItem> _items(List<ZsMenuEntry> entries) => entries.whereType<ZsMenuItem>().toList();

ZsMenuItem _row(List<ZsMenuEntry> entries, String label) => _items(entries).singleWhere((i) => i.label == label);

/// The label of each entry: a row's label, `—` for a separator, `note: …` for a note.
List<String> _shape(List<ZsMenuEntry> entries) => <String>[
  for (final ZsMenuEntry entry in entries)
    switch (entry) {
      ZsMenuItem(:final String label) => label,
      ZsMenuSeparator() => '—',
      ZsMenuNote(:final String label) => 'note: $label',
      ZsMenuHeader(:final String label) => 'header: $label',
    },
];

List<ZsMenuEntry> _popover({
  List<Bookmark>? bookmarks,
  String? blocked,
  ValueChanged<GraphAction>? run,
  ValueChanged<GraphNameRequest>? ask,
}) => graphBookmarkMenuEntries(
  _en,
  _l,
  _node(_b),
  blocked: blocked,
  run: run ?? (_) {},
  bookmarks: bookmarks,
  ask: ask ?? (_) {},
);

List<Bookmark> _rows({required bool tracked}) => <Bookmark>[
  localRow('b-mark', 'c$_b'),
  remoteRow('b-mark', 'origin', 'c$_b', tracked: tracked),
];

/// The requests Create… and the bookmark's Rename… and Move to… ask for, by label.
Map<String, GraphNameRequest> _requests() {
  final asked = <GraphNameRequest>[];
  final List<ZsMenuEntry> entries = _popover(bookmarks: _rows(tracked: false), ask: asked.add);
  final List<ZsMenuEntry> local = _row(entries, 'b-mark').submenu!;
  for (final item in <ZsMenuItem>[
    _row(local, 'Rename…'),
    _row(local, 'Move to…'),
    _row(entries, 'Create bookmark here…'),
    _row(entries, 'Move existing here…'),
  ]) {
    item.onSelected!();
  }
  return <String, GraphNameRequest>{
    'rename': asked[0],
    'moveTo': asked[1],
    'create': asked[2],
    'moveHere': asked[3],
  };
}

/// Runs every action and writes one operation each.
class _Actions implements GraphActions {
  final ran = <GraphAction>[];

  @override
  Future<String> headOpId() async => 'op${ran.length}';

  @override
  Future<MutationResult> run(GraphAction action) async {
    ran.add(action);
    return MutationResult(
      newOpId: 'op${ran.length}',
      newChangeIds: const <String>[],
      abandonedChangeIds: const <String>[],
      workingCopyChangeId: null,
      finish: null,
    );
  }
}

/// Reads that never answer: the inspector's fetch stays pending.
class _Details implements GraphDetails {
  @override
  Future<ShowEntry> show(String commitId) => Completer<ShowEntry>().future;

  @override
  Future<ChangeActions> changeActions(String changeId) => Completer<ChangeActions>().future;

  @override
  Future<Diff> diff(String commitId, {List<String> paths = const [], bool summary = false}) => Completer<Diff>().future;

  /// Every plan asked for, by change id; none combines a description, so the squash runs at once.
  final plans = <String>[];

  @override
  Future<SquashPlan> squashPlan(String changeId) async {
    plans.add(changeId);
    return const SquashPlan(combinedDescription: null);
  }
}

void main() {
  setUpIconRegistry();

  group('graphCardMenuEntries', () {
    test('a mutable change: the rows, each command with the short id', () {
      final List<ZsMenuEntry> entries = _menu(_b);
      expect(_shape(entries), <String>[
        'New change on top',
        'Insert after',
        'Insert before',
        '—',
        'Edit',
        'Describe…',
        'Squash into parent',
        'Copy',
        '—',
        'Revert',
        'Abandon',
      ]);
      expect(_items(entries).every((i) => i.enabled), isTrue);
      expect(_row(entries, 'Revert').cmd, 'jj revert -r kmnvxoqp -B @', reason: 'B is an ancestor of @');
      expect(_row(entries, 'Abandon').danger, isTrue);
      expect(_row(entries, 'Copy').submenu!.map((e) => (e as ZsMenuItem).label), <String>['Change id', 'Description']);
      expect(_row(entries, 'Copy').cmd, isNull);
    });

    test('every enabled row runs its action with the full key', () {
      final ran = <GraphAction>[];
      final described = <String>[];
      final List<ZsMenuEntry> entries = _menu(_b, run: ran.add, onDescribe: described.add);
      for (final ZsMenuItem item in _items(entries)) {
        if (item.submenu == null) {
          item.onSelected!();
        }
      }
      expect(described, <String>[_b]);
      expect(ran.map((a) => a.command), <String>[
        'jj new $_b',
        'jj new -A $_b',
        'jj new -B $_b',
        'jj edit $_b',
        'jj squash -r $_b',
        'jj revert -r $_b -B @',
        'jj abandon $_b',
      ]);
      expect(ran.last, isA<GraphAbandon>().having((a) => a.ids, 'ids', <String>[_b]));
    });

    test('with onSquash, Squash into parent calls it with the key instead of running (Story 10.25)', () {
      final ran = <GraphAction>[];
      final squashed = <String>[];
      final ZsMenuItem row = _row(_menu(_b, run: ran.add, onSquash: squashed.add), 'Squash into parent');
      expect(row.cmd, 'jj squash -r kmnvxoqp');
      row.onSelected!();
      expect(squashed, <String>[_b]);
      expect(ran, isEmpty);
    });

    test('@: Edit and Revert disabled with their reasons', () {
      final List<ZsMenuEntry> entries = _menu(_at);
      expect(_row(entries, 'Edit').enabled, isFalse);
      expect(_row(entries, 'Edit').tooltip, 'Already the working copy');
      expect(_row(entries, 'Revert').enabled, isFalse);
      expect(_row(entries, 'Revert').tooltip, "The revert lands below @ — @ itself can't be reverted");
      expect(_row(entries, 'Abandon').enabled, isTrue);
    });

    test("Revert: off outside @'s history and on an empty change", () {
      expect(_row(_menu(_side), 'Revert').tooltip, "The revert lands below @ — only changes in @'s history");
      expect(_row(_menu(_empty), 'Revert').tooltip, 'Nothing to revert — the change is empty');
    });

    test('Squash: off on a merge and on an immutable parent', () {
      expect(_row(_menu(_merge), 'Squash into parent').tooltip, 'A merge has more than one parent');
      expect(_row(_menu(_onImm), 'Squash into parent').tooltip, 'The parent is immutable');
      expect(_row(_menu(_b), 'Squash into parent').tooltip, isNull);
    });

    test('an immutable change: the locked menu; Insert after only without an immutable child', () {
      final List<ZsMenuEntry> entries = _menu(_imm);
      expect(_shape(entries), <String>[
        'New change on top',
        'Insert after',
        'Revert',
        '—',
        'note: Immutable',
        'Immutable commits…',
      ]);
      expect(_row(entries, 'Revert').enabled, isTrue, reason: 'an immutable ancestor of @');
      expect((entries[4] as ZsMenuNote).leading, isNotNull);
      expect(_row(entries, 'Immutable commits…').enabled, isFalse);
      expect(_row(entries, 'Immutable commits…').tooltip, 'Comes with the Settings window');
      expect(_row(entries, 'Immutable commits…').icon, ZI.settings);
      expect(_shape(_menu(_immParent)), <String>[
        'New change on top',
        'Revert',
        '—',
        'note: Immutable',
        'Immutable commits…',
      ]);
    });

    test('the root: New change on top only', () {
      expect(_shape(_menu(_root)), <String>['New change on top']);
      expect(_row(_menu(_root), 'New change on top').cmd, 'jj new zzzzzzzz');
    });

    test('busy or stale: every jj row disabled with the reason; nothing runs; Copy stays on', () {
      final ran = <GraphAction>[];
      for (final key in <String>[_b, _imm, _root]) {
        for (final ZsMenuItem item in _items(_menu(key, blocked: 'Another action is running', run: ran.add))) {
          if (item.label == 'Copy') {
            expect(item.enabled, isTrue, reason: 'read-only');
            expect(item.submenu!.every((e) => (e as ZsMenuItem).enabled), isTrue);
            continue;
          }
          expect(item.enabled, isFalse, reason: '$key ${item.label}');
          expect(item.tooltip, 'Another action is running', reason: '$key ${item.label}');
        }
      }
      expect(ran, isEmpty);
    });

    test('Copy › Change id and Description write the full id and description; Description waits for content', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final copied = <String?>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied.add((call.arguments as Map<Object?, Object?>)['text'] as String?);
          }
          return null;
        },
      );
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      final List<ZsMenuEntry> copy = _row(_menu(_b), 'Copy').submenu!;
      _row(copy, 'Change id').onSelected!();
      _row(copy, 'Description').onSelected!();
      await Future<void>.delayed(Duration.zero);
      expect(copied, <String>[_b, 'about $_b\n']);

      final GraphLayout bare = handLayout(<(String, int, int)>[(_b, 0, 0)], changeIds: const <String>[_b]);
      final ZsMenuItem description = _row(
        _row(graphCardMenuEntries(_en, bare, 0, blocked: null, run: (_) {}), 'Copy').submenu!,
        'Description',
      );
      expect(description.enabled, isFalse, reason: 'no content yet');
    });
  });

  group('graphBookmarkMenuEntries', () {
    test('a local bookmark: Rename…, Move to…, Delete; the remote row waits for the read; git is left out', () {
      final List<ZsMenuEntry> entries = _popover();
      expect(_shape(entries), <String>['b-mark', 'b-mark@origin', '—', 'Create bookmark here…', 'Move existing here…']);
      expect(_row(entries, 'b-mark').mono, isTrue);
      expect(_shape(_row(entries, 'b-mark').submenu!), <String>['Rename…', 'Move to…', 'Delete']);
      expect(_row(entries, 'b-mark@origin').enabled, isFalse);
      expect(_row(entries, 'b-mark@origin').tooltip, 'Reading bookmarks…');
    });

    test('Track for an untracked remote, Untrack for a tracked one; Delete', () {
      final ran = <GraphAction>[];
      final List<ZsMenuEntry> untracked = _popover(bookmarks: _rows(tracked: false), run: ran.add);
      final ZsMenuItem track = _row(_row(untracked, 'b-mark@origin').submenu!, 'Track');
      track.onSelected!();
      expect(
        ran.single,
        isA<GraphBookmarkTrack>().having((a) => a.name, 'name', 'b-mark').having((a) => a.remote, 'remote', 'origin'),
      );
      final List<ZsMenuEntry> tracked = _popover(bookmarks: _rows(tracked: true), run: ran.add);
      expect(_shape(_row(tracked, 'b-mark@origin').submenu!), <String>['Untrack']);
      _row(_row(untracked, 'b-mark').submenu!, 'Delete').onSelected!();
      expect(ran.last, isA<GraphBookmarkDelete>().having((a) => a.names, 'names', <String>['b-mark']));
    });

    test('Create… asks for a name; the action names the change', () {
      final GraphNameRequest create = _requests()['create']!;
      expect(create.title, 'Create bookmark here');
      expect(create.action('x', _b), isA<GraphBookmarkCreate>().having((a) => a.revision, 'revision', _b));
    });

    test('a failed read: the remote row disabled with the failure', () {
      final ZsMenuItem remote = _row(
        graphBookmarkMenuEntries(
          _en,
          _l,
          _node(_b),
          blocked: null,
          run: (_) {},
          bookmarks: null,
          readFailed: true,
          ask: (_) {},
        ),
        'b-mark@origin',
      );
      expect(remote.enabled, isFalse);
      expect(remote.tooltip, "Couldn't read the bookmarks");
    });

    test('busy: every row disabled', () {
      for (final ZsMenuItem item in _items(_popover(bookmarks: _rows(tracked: false), blocked: 'stale'))) {
        expect(item.enabled, isFalse, reason: item.label);
        expect(item.tooltip, 'stale');
      }
    });
  });

  test('test-fixtures/commands/card-menu.txt holds the commands the menu, the popover and the sheets show', () {
    final List<ZsMenuEntry> menu = _menu(_b);
    final ZsMenuItem local = _row(_popover(bookmarks: _rows(tracked: false)), 'b-mark');
    final Map<String, GraphNameRequest> sheets = _requests();
    const short = 'kmnvxoqp';
    final commands = <String>[
      for (final ZsMenuItem item in _items(menu))
        if (item.cmd case final String cmd) cmd,
      _row(local.submenu!, 'Delete').cmd!,
      _row(_row(_popover(bookmarks: _rows(tracked: false)), 'b-mark@origin').submenu!, 'Track').cmd!,
      _row(_row(_popover(bookmarks: _rows(tracked: true)), 'b-mark@origin').submenu!, 'Untrack').cmd!,
      sheets['rename']!.action('feature/x', short).command,
      sheets['moveTo']!.action('@', short).command,
      sheets['create']!.action('ü', short).command,
      sheets['moveHere']!.action('b-mark', short).command,
    ];
    final List<String> lines = File('../test-fixtures/commands/card-menu.txt').readAsLinesSync();
    expect(commands, lines);
  });

  group('in the graph', () {
    late ScriptedGraphSource source;
    late GraphViewModel model;
    late _Actions actions;
    InspectorViewModel? inspector;
    late Widget view;
    const ZsMotion m = ZsMotion.full;

    Future<void> pump(WidgetTester tester, {Future<List<Bookmark>> Function()? bookmarks}) async {
      source = ScriptedGraphSource(respond: (_) => _layout());
      actions = _Actions();
      model = GraphViewModel()..init(source, actions: actions, clock: () => DateTime.utc(2026, 10, 30, 12));
      final Directory dir = Directory.systemTemp.createTempSync('zanshin_card_menu');
      addTearDown(() => dir.deleteSync(recursive: true));
      final SettingsStore settings = await SettingsStore.load(File('${dir.path}/settings.json'));
      inspector = InspectorViewModel(
        graph: model,
        details: _Details(),
        viewed: ProjectViewedStore(settings, '/r'),
        settings: settings,
      );
      tester.view
        ..physicalSize = surface
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      view = GraphView(model: model, inspectorModel: inspector, bookmarks: bookmarks);
      await tester.pumpWidget(shellHost(view));
      await tester.pump();
      await tester.pump();
    }

    Future<void> finish(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      inspector?.dispose();
      model.dispose();
    }

    GraphCardController cards(WidgetTester tester) => tester.widget<GraphCanvas>(find.byType(GraphCanvas)).cards;

    Finder card(String key) =>
        find.byWidgetPredicate((w) => w is GraphCard && w.layout.keyOf(w.node) == key, skipOffstage: false);

    Future<void> settle(WidgetTester tester) async {
      await tester.pump();
      await tester.pump(m.durMenu);
      await tester.pump(m.durExit);
    }

    testWidgets('a right-click opens the menu at the pointer; Esc closes it and clears menuOpen', (tester) async {
      await pump(tester);
      final Offset at = tester.getCenter(card(_b));
      await tester.tapAt(at, buttons: kSecondaryButton);
      await settle(tester);
      expect(cards(tester).menuOpen.value, _b);
      expect(find.text('Insert before'), findsOneWidget);
      expect(find.text('about $_b'), findsOneWidget, reason: 'the subject heads the menu');
      final Rect panel = tester.getRect(find.byType(ZsMenuMaterial));
      expect(panel.topLeft, at, reason: 'at the pointer');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
      expect(find.text('Insert before'), findsNothing);
      expect(cards(tester).menuOpen.value, isNull);
      await finish(tester);
    });

    testWidgets('••• twice opens then closes; a scroll and a new selection close it', (tester) async {
      await pump(tester);
      final GraphCardController c = cards(tester);
      final more = Rect.fromCenter(center: tester.getCenter(card(_b)), width: 18, height: 18);
      c.openMenu(_b, more);
      await settle(tester);
      expect(find.text('Insert before'), findsOneWidget);
      expect(tester.getRect(find.byType(ZsMenuMaterial)).top, more.bottom + 4, reason: 'below the circle');
      c.openMenu(_b, more);
      await settle(tester);
      expect(find.text('Insert before'), findsNothing);
      expect(c.menuOpen.value, isNull);

      c.openMenu(_b, more);
      await settle(tester);
      final pointer = TestPointer(1, PointerDeviceKind.mouse)..hover(tester.getCenter(card(_side)));
      await tester.sendEventToBinding(pointer.scroll(const Offset(0, 40)));
      await settle(tester);
      expect(find.text('Insert before'), findsNothing);
      expect(c.menuOpen.value, isNull);

      c.openMenu(_b, more);
      await settle(tester);
      c.select(_side);
      await settle(tester);
      expect(find.text('Insert before'), findsNothing);
      await tester.pump(graphDoubleClickWindow);
      await finish(tester);
    });

    testWidgets('Abandon runs GraphAbandon with the key and closes the menu; Describe… opens the form', (tester) async {
      await pump(tester);
      final GraphCardController c = cards(tester)
        ..openMenu(_b, Rect.fromCenter(center: tester.getCenter(card(_b)), width: 18, height: 18));
      await settle(tester);
      await tester.tap(find.text('Abandon'));
      await tester.pump(m.durBlink);
      await tester.pump(m.durBlink);
      await settle(tester);
      expect(actions.ran.single, isA<GraphAbandon>().having((a) => a.ids, 'ids', <String>[_b]));
      expect(c.menuOpen.value, isNull);
      expect(find.text('Insert before'), findsNothing);
      await tester.pump();
      await tester.pump();

      c.openMenu(_side, Rect.fromCenter(center: tester.getCenter(card(_side)), width: 18, height: 18));
      await settle(tester);
      await tester.tap(find.text('Describe…'));
      await tester.pump(m.durBlink);
      await tester.pump(m.durBlink);
      await settle(tester);
      expect(model.selected, _side);
      expect(inspector!.isOpen(_side), isTrue);
      await finish(tester);
    });

    testWidgets('Squash into parent goes through the inspector: it selects the change, asks the plan, squashes', (
      tester,
    ) async {
      await pump(tester);
      cards(tester).openMenu(_side, Rect.fromCenter(center: tester.getCenter(card(_side)), width: 18, height: 18));
      await settle(tester);
      await tester.tap(find.text('Squash into parent'));
      await tester.pump(m.durBlink);
      await tester.pump(m.durBlink);
      await settle(tester);
      expect(model.selected, _side);
      expect((inspector!.details as _Details).plans, <String>[_side]);
      expect(actions.ran.single, isA<GraphSquash>().having((a) => a.revision, 'revision', _side));
      await finish(tester);
    });

    testWidgets('an open menu closes when the window turns inactive and when the view size changes', (tester) async {
      await pump(tester);
      final GraphCardController c = cards(tester);
      final more = Rect.fromCenter(center: tester.getCenter(card(_b)), width: 18, height: 18);
      c.openMenu(_b, more);
      await settle(tester);
      expect(find.byType(ZsMenuMaterial), findsOneWidget);
      await tester.pumpWidget(shellHost(view, appearance: const ZsAppearance(inactive: true)));
      await settle(tester);
      expect(c.menuOpen.value, isNull);
      expect(find.byType(ZsMenuMaterial), findsNothing);

      await tester.pumpWidget(shellHost(view));
      await settle(tester);
      c.openMenu(_b, Rect.fromCenter(center: tester.getCenter(card(_b)), width: 18, height: 18));
      await settle(tester);
      expect(find.byType(ZsMenuMaterial), findsOneWidget);
      tester.view.physicalSize = const Size(900, 640);
      await tester.pump();
      await settle(tester);
      expect(c.menuOpen.value, isNull);
      expect(find.byType(ZsMenuMaterial), findsNothing);
      await finish(tester);
    });

    testWidgets("a reload whose layout lacks the open card's key closes its menu", (tester) async {
      await pump(tester);
      final GraphCardController c = cards(tester)
        ..openMenu(_side, Rect.fromCenter(center: tester.getCenter(card(_side)), width: 18, height: 18));
      await settle(tester);
      expect(find.byType(ZsMenuMaterial), findsOneWidget);
      source
        ..respond = ((_) => handLayout(
          <(String, int, int)>[(_at, 1, 0), (_root, 0, 0)],
          edges: const <(int, int)>[(0, 1)],
          workingCopy: 0,
          root: 1,
          flags: const <int>[0, RecordedGraphLayout.flagImmutable],
          operationId: 'op1',
        ))
        ..emit(const OpHeadsChangedEvent(0, <String>[]));
      await tester.pump();
      await tester.pump();
      await settle(tester);
      expect(c.menuOpen.value, isNull);
      expect(find.byType(ZsMenuMaterial), findsNothing);
      await finish(tester);
    });

    testWidgets('the popover: Track after the read; Create… asks in the name sheet and runs create', (tester) async {
      final read = Completer<List<Bookmark>>();
      await pump(tester, bookmarks: () => read.future);
      final GraphCardController c = cards(tester);
      final pill = Rect.fromCenter(center: tester.getCenter(card(_b)), width: 40, height: 16);
      c.openBookmarks(_b, pill);
      await settle(tester);
      expect(find.text('b-mark@origin'), findsOneWidget);
      read.complete(_rows(tracked: false));
      await tester.pump();
      await tester.tap(find.text('b-mark@origin'));
      await settle(tester);
      await tester.tap(find.text('Track'));
      await tester.pump(m.durBlink);
      await tester.pump(m.durBlink);
      await settle(tester);
      expect(actions.ran.single, isA<GraphBookmarkTrack>().having((a) => a.symbol, 'symbol', 'b-mark@origin'));
      expect(c.bookmarksOpen.value, isNull);
      await tester.pump();
      await tester.pump();

      c.openBookmarks(_b, pill);
      await settle(tester);
      await tester.tap(find.text('Create bookmark here…'));
      await tester.pump(m.durBlink);
      await tester.pump(m.durBlink);
      await tester.pump();
      await tester.pump(m.durPop);
      expect(find.byType(GraphNameSheet), findsOneWidget);
      final ZsButton confirm = tester.widget<ZsButton>(
        find.byWidgetPredicate((w) => w is ZsButton && w.identifier == 'name-sheet-confirm'),
      );
      expect(confirm.onPressed, isNull, reason: 'the field is empty');
      await tester.enterText(find.byType(EditableText), 'feature');
      await tester.pump();
      expect(
        tester.widget<Text>(find.byKey(const ValueKey<String>('name-sheet-command'))).data,
        'jj bookmark create feature -r kmnvxoqp',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      await tester.pump(m.durExitLg);
      await tester.pump();
      expect(
        actions.ran.last,
        isA<GraphBookmarkCreate>()
            .having((a) => a.names, 'names', <String>['feature'])
            .having((a) => a.revision, 'revision', _b),
      );
      expect(find.byType(GraphNameSheet), findsNothing);
      await finish(tester);
    });
  });
}
