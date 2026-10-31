// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/src/features/graph/graph_inspector.dart';
import 'package:zanshin/src/features/graph/graph_layout.dart';
import 'package:zanshin/src/features/graph/graph_ports.dart';
import 'package:zanshin/src/features/graph/graph_view.dart';
import 'package:zanshin/src/features/graph/graph_view_model.dart';
import 'package:zanshin/src/features/graph/hatch_swatch.dart';
import 'package:zanshin/src/features/graph/recorded_graph_layout.dart';
import 'package:zanshin_core/zanshin_core.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

import '../../helpers/icon_registry.dart';
import '../../helpers/scripted_graph_source.dart';
import '../../helpers/shell_host.dart';
import 'graph_harness.dart';

const _at = 'wwwwwwwwwwww';
const _mutable = 'mmmmmmmmmmmm';
const _merge = 'gggggggggggg';
const _left = 'pppppppppppp';
const _right = 'qqqqqqqqqqqq';
const _root = 'zzzzzzzzzzzz';

const _keys = <String>[_at, _mutable, _merge, _left, _right, _root];

/// @ → m → the merge of p and q (both immutable) → the root, at operation [op].
RecordedGraphLayout _layout(String op) {
  const int imm = RecordedGraphLayout.flagImmutable;
  return handLayout(
    <(String, int, int)>[(_at, 5, 0), (_mutable, 4, 0), (_merge, 3, 0), (_left, 2, 0), (_right, 1, 1), (_root, 0, 0)],
    edges: <(int, int)>[(0, 1), (1, 2), (2, 3), (2, 4), (3, 5), (4, 5)],
    workingCopy: 0,
    root: 5,
    parentCounts: const <int>[1, 1, 2, 1, 1, 0],
    flags: const <int>[0, 0, 0, imm, imm, imm],
    prefixLengths: const <int>[1, 3, 2, 2, 2, 1],
    commitIds: <String>[for (final String key in _keys) 'c$key'],
    timestamps: <int?>[for (final _ in _keys) DateTime.utc(2026, 10, 30, 11).millisecondsSinceEpoch],
    refs: const <List<GraphRef>>[
      <GraphRef>[],
      <GraphRef>[GraphRef('main'), GraphRef('dev', synced: false), GraphRef('main', remote: 'origin')],
      <GraphRef>[],
      <GraphRef>[],
      <GraphRef>[],
      <GraphRef>[],
    ],
    contents: <GraphCommitContent?>[
      for (final String key in _keys) GraphCommitContent(subject: 'about $key', authorName: 'Ada', empty: key == _at),
    ],
    operationId: op,
  );
}

/// The inspector's reads: an entry per commit id from [descriptions] and [files]; [hold] parks each `show`.
class _Details implements GraphDetails {
  final shows = <String>[];
  final previews = <String>[];
  final descriptions = <String, String>{
    for (final String key in _keys) key: key == _root ? '' : 'about $key\n',
  };
  final files = <String, List<FileChange>>{
    _mutable: const <FileChange>[
      FileChange(path: 'src/a.dart', kind: FileChangeKind.modified),
      FileChange(path: 'src/new.dart', kind: FileChangeKind.renamed, fromPath: 'src/old.dart'),
    ],
  };
  var hold = false;

  /// The keys whose entry is conflicted.
  final conflicted = <String>{};
  final held = <(String, Completer<ShowEntry>)>[];
  ZanshinFfiException? refuse;
  ActionOutcome squash = _available;
  void Function()? onShow;

  static const _available = ActionOutcome(
    status: ActionStatus.available,
    refusal: null,
    combinedDescriptionNeeded: false,
    allowBackwardsNeeded: false,
  );

  static const _parents = <String, List<String>>{
    _at: <String>[_mutable],
    _mutable: <String>[_merge],
    _merge: <String>[_left, _right],
    _left: <String>[_root],
    _right: <String>[_root],
    _root: <String>[],
  };

  ShowEntry entryOf(String key) {
    const author = Signature(name: 'Ada Lovelace', email: 'ada@example.com', timestampMillis: 0, tzOffsetMinutes: 0);
    return ShowEntry(
      change: Change(
        id: key,
        commitId: 'c$key',
        parents: _parents[key]!,
        description: descriptions[key]!,
        author: author,
        committer: author,
        isSigned: false,
        conflict: conflicted.contains(key) ? ConflictState.conflicted : ConflictState.clean,
        conflictedPaths: const <String>[],
        isAnonymous: false,
        divergent: false,
      ),
      fileChanges: files[key] ?? const <FileChange>[],
    );
  }

  @override
  Future<ShowEntry> show(String commitId) {
    shows.add(commitId);
    onShow?.call();
    final String key = commitId.substring(1);
    if (refuse case final error?) {
      return Future<ShowEntry>.error(error);
    }
    if (hold) {
      final completer = Completer<ShowEntry>();
      held.add((key, completer));
      return completer.future;
    }
    return Future<ShowEntry>.value(entryOf(key));
  }

  @override
  Future<ChangeActions> changeActions(String changeId) async {
    previews.add(changeId);
    return ChangeActions(
      newOnto: _available,
      newInsertAfter: _available,
      newInsertBefore: _available,
      edit: _available,
      describe: _available,
      squashIntoParent: squash,
      abandon: _available,
    );
  }
}

/// Runs every action, writes one operation each and applies a describe to [details].
class _Actions implements GraphActions {
  _Actions(this.details);

  final _Details details;
  final ran = <GraphAction>[];

  /// While set, every run refuses with it.
  ZanshinFfiException? refuse;

  @override
  Future<String> headOpId() async => 'op${ran.length}';

  @override
  Future<MutationResult> run(GraphAction action) async {
    ran.add(action);
    if (refuse case final error?) {
      throw error;
    }
    if (action is GraphDescribe) {
      details.descriptions[action.id] = action.description;
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

Finder _id(String identifier) => find.byWidgetPredicate(
  (widget) => switch (widget) {
    final ZsControl control => control.identifier == identifier,
    final ZsControlCore core => core.identifier == identifier,
    _ => false,
  },
);

Finder _button(String identifier) =>
    find.byWidgetPredicate((widget) => widget is ZsButton && widget.identifier == identifier);

String _tooltipOf(WidgetTester tester, String identifier) =>
    tester.widget<ZsTooltip>(find.ancestor(of: _button(identifier), matching: find.byType(ZsTooltip)).first).message;

void main() {
  setUpIconRegistry();
  late ScriptedGraphSource source;
  late _Details details;
  late _Actions actions;
  late GraphViewModel graph;
  late InspectorViewModel inspector;
  var ops = 0;

  setUp(() {
    ops = 0;
    source = ScriptedGraphSource(respond: (_) => _layout('op${ops++}'));
    details = _Details();
    actions = _Actions(details);
  });

  Future<void> pump(WidgetTester tester, {String? select = _mutable}) async {
    useShellWindow(tester);
    graph = GraphViewModel()..init(source, actions: actions, clock: () => DateTime.utc(2026, 10, 30, 12));
    inspector = InspectorViewModel(graph: graph, details: details);
    await tester.pumpWidget(
      shellHost(
        Align(
          alignment: Alignment.topRight,
          child: SizedBox(width: 460, height: 840, child: GraphInspector(model: inspector)),
        ),
      ),
    );
    await tester.pump();
    graph.select(select);
    await tester.pump();
    await tester.pump();
  }

  /// A new operation: the graph reloads, the inspector reads again.
  Future<void> reload(WidgetTester tester) async {
    source.emit(const OpHeadsChangedEvent(0, <String>[]));
    await tester.pump();
    await tester.pump();
  }

  Future<void> openForm(WidgetTester tester) async {
    await tester.tap(_id('inspector-title'));
    await tester.pump();
    await tester.pump();
  }

  Future<void> esc(WidgetTester tester) async {
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
  }

  /// Unmounts the inspector, then disposes the models (the graph's minute timer must not outlive the test).
  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    inspector.dispose();
    graph.dispose();
  }

  testWidgets('the header: the full change id as one Text.rich, the prefix bold, the commit id its tooltip', (
    tester,
  ) async {
    await pump(tester);
    final Text id = tester.widget<Text>(find.byKey(const ValueKey<String>('inspector-id')));
    final List<InlineSpan> spans = (id.textSpan! as TextSpan).children!;
    expect(spans, hasLength(2));
    expect((spans[0] as TextSpan).text, 'mmm');
    expect((spans[0] as TextSpan).style!.fontWeight, FontWeight.w600);
    expect((spans[1] as TextSpan).text, 'mmmmmmmmm');
    expect(
      tester.widget<ZsTooltip>(find.ancestor(of: find.byWidget(id), matching: find.byType(ZsTooltip)).first).message,
      'c$_mutable',
    );
    expect(find.text('about $_mutable'), findsOneWidget, reason: 'the title');
    expect(details.shows, <String>['c$_mutable'], reason: 'one read, no diff request');
    expect(details.previews, <String>[_mutable]);
    await unmount(tester);
  });

  testWidgets('a mutable change: Edit, Squash into parent disabled, Abandon; tooltips are the commands', (
    tester,
  ) async {
    await pump(tester);
    expect(_tooltipOf(tester, 'inspector-edit'), 'jj edit mmmmmmmm');
    expect(tester.widget<ZsButton>(_button('inspector-edit')).variant, ZsButtonVariant.primary);
    expect(tester.widget<ZsButton>(_button('inspector-edit')).icon, ZI.workingCopyAt);
    expect(_tooltipOf(tester, 'inspector-squash'), 'Comes with the commit composer');
    expect(tester.widget<ZsButton>(_button('inspector-squash')).onPressed, isNull);
    expect(_tooltipOf(tester, 'inspector-abandon'), 'jj abandon mmmmmmmm');
    expect(_button('inspector-new'), findsNothing);
    await tester.tap(_button('inspector-edit'));
    await tester.pump();
    expect(actions.ran.single, isA<GraphEdit>().having((a) => a.id, 'id', _mutable));
    await tester.pump();
    await tester.tap(_button('inspector-abandon'));
    await tester.pump();
    expect(actions.ran.last.command, 'jj abandon $_mutable', reason: 'no confirmation');
    await tester.pump();
    expect(graph.selected, isNull, reason: 'abandon clears the selection');
    await unmount(tester);
  });

  testWidgets('Squash refused by the backend: disabled, its tooltip the refusal', (tester) async {
    details.squash = const ActionOutcome(
      status: ActionStatus.refused,
      refusal: ActionRefusal('jj.immutable', 'Commit gggggggg is immutable'),
      combinedDescriptionNeeded: false,
      allowBackwardsNeeded: false,
    );
    await pump(tester);
    expect(_tooltipOf(tester, 'inspector-squash'), 'Commit gggggggg is immutable');
    expect(tester.widget<ZsButton>(_button('inspector-squash')).disabledReason, 'Commit gggggggg is immutable');
    await unmount(tester);
  });

  testWidgets('@ with no files: the flag, the empty text, New change / Squash / Abandon', (tester) async {
    await pump(tester, select: _at);
    expect(find.text('@ Working copy'), findsOneWidget);
    expect(find.text('Empty'), findsOneWidget);
    expect(find.text('No changes yet — whatever you edit in your editor lands here.'), findsOneWidget);
    expect(find.descendant(of: _button('inspector-new'), matching: find.text('New change')), findsOneWidget);
    expect(_tooltipOf(tester, 'inspector-new'), 'jj new wwwwwwww');
    expect(_button('inspector-squash'), findsOneWidget);
    expect(_button('inspector-abandon'), findsOneWidget);
    expect(_button('inspector-edit'), findsNothing);
    await tester.tap(_button('inspector-new'));
    await tester.pump();
    expect(actions.ran.single, isA<GraphNew>().having((a) => a.parents, 'parents', <String>[_at]));
    await tester.pump();
    await unmount(tester);
  });

  testWidgets('an immutable change: the hatch flag, no ◆, no pen or form, only New change on top', (tester) async {
    await pump(tester, select: _left);
    final Finder flag = find.ancestor(of: find.text('Immutable'), matching: find.byType(ZsTooltip));
    expect(find.descendant(of: flag, matching: find.byType(HatchSwatch)), findsOneWidget);
    expect(tester.widget<ZsTooltip>(flag.first).message, 'Immutable');
    expect(find.textContaining('◆'), findsNothing);
    expect(_id('inspector-title'), findsNothing);
    expect(find.descendant(of: _button('inspector-new'), matching: find.text('New change on top')), findsOneWidget);
    expect(_tooltipOf(tester, 'inspector-new'), 'jj new pppppppp');
    expect(_button('inspector-edit'), findsNothing);
    expect(_button('inspector-abandon'), findsNothing);
    expect(details.previews, isEmpty, reason: 'no verb previews for an immutable change');
    await unmount(tester);
  });

  testWidgets('the root: no parents, no Immutable flag, its empty text, New change on top', (tester) async {
    await pump(tester, select: _root);
    expect(find.text('Immutable'), findsNothing);
    expect(find.text('The root of all history.'), findsOneWidget);
    expect(find.textContaining('parent'), findsNothing);
    expect(_button('inspector-new'), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('a merge: the flag, both parents in the meta, its empty text', (tester) async {
    await pump(tester, select: _merge);
    expect(find.text('Merge'), findsOneWidget);
    final String meta = tester
        .widget<Text>(find.byKey(const ValueKey<String>('inspector-meta')))
        .textSpan!
        .toPlainText();
    expect(meta, contains('parents pppppppp + qqqqqqqq'));
    expect(meta, contains('Ada Lovelace'));
    expect(meta, contains('1h'), reason: "the card's relative date");
    expect(find.text('A merge — no changes of its own.'), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('the chips and the files: ✓ / local / remote, the count, a rename, ↑ ↓ move the highlight', (
    tester,
  ) async {
    await pump(tester);
    expect(find.text('main'), findsOneWidget);
    expect(find.text('✓'), findsOneWidget);
    expect(find.text('local'), findsOneWidget);
    expect(find.text('main@origin'), findsOneWidget);
    expect(find.text('remote'), findsOneWidget);
    expect(find.text('Changes'), findsOneWidget);
    expect(find.text('2 files'), findsOneWidget);
    expect(find.text('src/old.dart → src/new.dart'), findsOneWidget);
    final ZsColors colors = ZsColors.of(tester.element(find.text('src/a.dart')));
    Color? ink(String path) => tester.widget<Text>(find.text(path)).style!.color;
    await tester.tap(find.text('src/a.dart'));
    await tester.pump();
    expect(ink('src/a.dart'), colors.text, reason: 'the clicked row is highlighted');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(ink('src/a.dart'), colors.textMuted);
    expect(ink('src/old.dart → src/new.dart'), colors.text);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(ink('src/a.dart'), colors.text);
    await unmount(tester);
  });

  testWidgets('Save sends "S\\n\\nD\\n" once as the CLI\'s -m paragraphs; unchanged sends nothing', (tester) async {
    await pump(tester);
    await openForm(tester);
    expect(find.byType(ZsTextField), findsNWidgets(2), reason: 'only Zs controls');
    expect(_button('inspector-edit'), findsNothing, reason: 'the action row hides while the form is open');
    await tester.enterText(find.descendant(of: _id('inspector-summary'), matching: find.byType(EditableText)), 'S');
    await tester.enterText(find.descendant(of: _id('inspector-details'), matching: find.byType(EditableText)), 'D');
    await tester.pump();
    expect(find.text('jj describe mmmmmmmmmmmm -m S -m D'), findsOneWidget, reason: 'the footer shows the command');
    await tester.tap(_button('inspector-save'));
    await tester.pump();
    await tester.pump();
    await tester.pump();
    final describe = actions.ran.single as GraphDescribe;
    expect(describe.description, 'S\n\nD\n');
    expect(describe.command, 'jj describe $_mutable -m S -m D');
    expect(_id('inspector-summary'), findsNothing, reason: 'the form closed');
    expect(find.text('S'), findsOneWidget, reason: 'the title shows the new description');
    expect(find.text('D'), findsOneWidget);

    await openForm(tester);
    await tester.tap(_button('inspector-save'));
    await tester.pump();
    await tester.pump();
    expect(actions.ran, hasLength(1), reason: 'the unchanged text sends nothing');
    expect(_id('inspector-summary'), findsNothing);
    await unmount(tester);
  });

  testWidgets('summary only saves "S\\n"; ↩ in Summary saves', (tester) async {
    await pump(tester);
    await openForm(tester);
    final Finder summary = find.descendant(of: _id('inspector-summary'), matching: find.byType(EditableText));
    await tester.enterText(find.descendant(of: _id('inspector-details'), matching: find.byType(EditableText)), '');
    await tester.enterText(summary, 'S');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    await tester.pump();
    expect((actions.ran.single as GraphDescribe).description, 'S\n');
    await unmount(tester);
  });

  testWidgets('an undescribed change reads "Describe this change…"; its form starts empty with Summary focused', (
    tester,
  ) async {
    details.descriptions[_mutable] = '';
    await pump(tester);
    expect(find.text('Describe this change…'), findsOneWidget);
    await openForm(tester);
    final EditableText summary = tester.widget<EditableText>(
      find.descendant(of: _id('inspector-summary'), matching: find.byType(EditableText)),
    );
    expect(summary.controller.text, isEmpty);
    expect(summary.focusNode.hasFocus, isTrue);
    await unmount(tester);
  });

  testWidgets('a draft survives a selection change and comes back open', (tester) async {
    await pump(tester);
    await openForm(tester);
    await tester.enterText(
      find.descendant(of: _id('inspector-summary'), matching: find.byType(EditableText)),
      'draft',
    );
    graph.select(_at);
    await tester.pump();
    await tester.pump();
    expect(_id('inspector-summary'), findsNothing);
    graph.select(_mutable);
    await tester.pump();
    await tester.pump();
    final EditableText summary = tester.widget<EditableText>(
      find.descendant(of: _id('inspector-summary'), matching: find.byType(EditableText)),
    );
    expect(summary.controller.text, 'draft');
    await unmount(tester);
  });

  testWidgets('Esc: a dirty field only unfocuses, then the form closes, then the selection clears', (tester) async {
    await pump(tester);
    await openForm(tester);
    final Finder field = find.descendant(of: _id('inspector-summary'), matching: find.byType(EditableText));
    await tester.enterText(field, 'changed');
    await tester.pump();
    expect(tester.widget<EditableText>(field).focusNode.hasFocus, isTrue);
    await esc(tester);
    expect(_id('inspector-summary'), findsOneWidget, reason: 'the first Esc leaves the field');
    expect(tester.widget<EditableText>(field).focusNode.hasFocus, isFalse);
    await esc(tester);
    expect(_id('inspector-summary'), findsNothing, reason: 'the second closes the form');
    expect(graph.selected, _mutable);
    await esc(tester);
    expect(graph.selected, isNull, reason: 'the third clears the selection');
    expect(inspector.draftOf(_mutable)?.summary, 'changed', reason: 'the draft stays for the session');
    await unmount(tester);
  });

  testWidgets('Esc on an unchanged form closes it at once', (tester) async {
    await pump(tester);
    await openForm(tester);
    await esc(tester);
    expect(_id('inspector-summary'), findsNothing);
    expect(graph.selected, _mutable);
    await unmount(tester);
  });

  testWidgets('Close (Esc) clears the selection; the shell slot is null then', (tester) async {
    await pump(tester);
    expect(GraphView.inspector(inspector), isNotNull);
    await tester.tap(find.byWidgetPredicate((w) => w is ZsIconButton && w.identifier == 'inspector-close'));
    await tester.pump();
    expect(graph.selected, isNull);
    expect(GraphView.inspector(inspector), isNull);
    await unmount(tester);
  });

  testWidgets('describe(key) selects the change and opens its form (the card menu’s Describe…)', (tester) async {
    await pump(tester, select: null);
    inspector.describe(_mutable);
    await tester.pump();
    await tester.pump();
    expect(graph.selected, _mutable);
    expect(_id('inspector-summary'), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('the stale state: no read, "Working copy is stale", actions and describe disabled with the reason', (
    tester,
  ) async {
    await pump(tester);
    details.shows.clear();
    source.respond = (_) => throw staleError('stale');
    await reload(tester);
    expect(graph.stale, isNotNull);
    expect(details.shows, isEmpty);
    expect(find.text('Working copy is stale'), findsWidgets);
    expect(tester.widget<ZsButton>(_button('inspector-edit')).disabledReason, 'Working copy is stale');
    expect(tester.widget<ZsButton>(_button('inspector-abandon')).onPressed, isNull);
    expect(tester.widget<ZsControlCore>(_id('inspector-title')).disabledReason, 'Working copy is stale');
    expect(find.text('about $_mutable'), findsOneWidget, reason: 'the title from the view facts');
    await unmount(tester);
  });

  testWidgets('a refusal shows its message in the file list', (tester) async {
    details.refuse = const ZanshinFfiException.withReport(
      'jj.revset_resolution_error',
      'Revision `cmmm` does not exist',
      precondition: null,
      warnings: <ZanshinWarning>[],
    );
    await pump(tester);
    expect(find.text('Revision `cmmm` does not exist'), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('a late reply for an older selection is dropped', (tester) async {
    details.hold = true;
    await pump(tester);
    graph.select(_at);
    await tester.pump();
    expect(details.held.map((h) => h.$1), <String>[_mutable, _at]);
    details.held[1].$2.complete(details.entryOf(_at));
    await tester.pump();
    details.held[0].$2.complete(details.entryOf(_mutable));
    await tester.pump();
    expect(inspector.entry?.change.id, _at);
    await unmount(tester);
  });

  testWidgets("show()'s snapshot writing an operation reads once more, then settles", (tester) async {
    var bumped = false;
    details.onShow = () {
      if (!bumped) {
        bumped = true;
        // The snapshot wrote an operation: the watcher reports it.
        scheduleMicrotask(() => source.emit(const OpHeadsChangedEvent(0, <String>[])));
      }
    };
    await pump(tester);
    for (var i = 0; i < 5; i++) {
      await tester.pump();
    }
    expect(details.shows, <String>['c$_mutable', 'c$_mutable']);
    await unmount(tester);
  });

  testWidgets('a reload that drops the selection empties the shell slot (the inspector exits)', (tester) async {
    await pump(tester);
    source.respond = (_) => keysLayout(<String>['a', 'b'], at: 'a');
    await reload(tester);
    expect(graph.selected, isNull);
    expect(GraphView.inspector(inspector), isNull);
    expect(find.byType(ZsIsland), findsOneWidget, reason: 'the last panel stays for the exit the shell plays');
    await unmount(tester);
  });

  testWidgets('an untouched form on a description jj would not write from -m ("S\\nD") sends nothing', (tester) async {
    details.descriptions[_mutable] = 'S\nD';
    await pump(tester);
    await openForm(tester);
    await tester.tap(_button('inspector-save'));
    await tester.pump();
    await tester.pump();
    expect(actions.ran, isEmpty);
    expect(_id('inspector-summary'), findsNothing, reason: 'the form closed');
    await unmount(tester);
  });

  testWidgets('a refused Save keeps the form open and the draft', (tester) async {
    actions.refuse = const ZanshinFfiException.withReport(
      'jj.immutable',
      'Commit mmmmmmmm is immutable',
      precondition: null,
      warnings: <ZanshinWarning>[],
    );
    await pump(tester);
    await openForm(tester);
    await tester.enterText(find.descendant(of: _id('inspector-summary'), matching: find.byType(EditableText)), 'S');
    await tester.enterText(find.descendant(of: _id('inspector-details'), matching: find.byType(EditableText)), 'D');
    await tester.tap(_button('inspector-save'));
    await tester.pump();
    await tester.pump();
    expect(actions.ran.single, isA<GraphDescribe>());
    expect(_id('inspector-summary'), findsOneWidget, reason: 'the form stays open');
    expect(inspector.draftOf(_mutable), (summary: 'S', details: 'D'));
    await unmount(tester);
  });

  testWidgets('a conflicted change shows the Conflict flag in the warn colours', (tester) async {
    details.conflicted.add(_mutable);
    await pump(tester);
    expect(find.text('Conflict'), findsOneWidget);
    final ZsColors colors = ZsColors.of(tester.element(find.text('Conflict')));
    expect(tester.widget<Text>(find.text('Conflict')).style!.color, colors.warn);
    await unmount(tester);
  });

  test('draftFrom splits the first line from the rest after the blank line', () {
    expect(InspectorViewModel.draftFrom('S\n\nD\n'), (summary: 'S', details: 'D'));
    expect(InspectorViewModel.draftFrom('S\n'), (summary: 'S', details: ''));
    expect(InspectorViewModel.draftFrom(''), (summary: '', details: ''));
    expect(InspectorViewModel.draftFrom('S\n\nA\n\nB\n'), (summary: 'S', details: 'A\n\nB'));
  });
}
