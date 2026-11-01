// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' show SelectionArea;
import 'package:zanshin/src/features/graph/graph_inspector.dart';
import 'package:zanshin/src/features/graph/graph_layout.dart';
import 'package:zanshin/src/features/graph/graph_ports.dart';
import 'package:zanshin/src/features/graph/graph_view.dart';
import 'package:zanshin/src/features/graph/graph_view_model.dart';
import 'package:zanshin/src/features/graph/hatch_swatch.dart';
import 'package:zanshin/src/features/graph/inspector_viewed_store.dart';
import 'package:zanshin/src/features/graph/recorded_graph_layout.dart';
import 'package:zanshin_core/zanshin_core.dart';
import 'package:zanshin_settings/zanshin_settings.dart';
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
RecordedGraphLayout _layout(String op, {List<String>? changeIds}) {
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
    changeIds: changeIds,
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

  /// Every `diff` call: the commit id, the paths, whether it was the summary.
  final diffs = <(String, List<String>, bool)>[];

  /// The full file diffs per key; a summary drops their hunks.
  final fileDiffs = <String, List<FileDiff>>{
    _mutable: <FileDiff>[
      fileDiff(
        'src/a.dart',
        added: 3,
        removed: 1,
        fingerprint: 'fa',
        hunks: <Hunk>[
          hunk(
            before: (start: 1, end: 3),
            after: (start: 1, end: 5),
            lines: const <HunkLine>[
              HunkLine(kind: HunkLineKind.context, text: 'keep\n'),
              HunkLine(kind: HunkLineKind.removed, text: 'old a\n'),
              HunkLine(kind: HunkLineKind.added, text: 'new a\n'),
              HunkLine(kind: HunkLineKind.added, text: 'new b\n'),
              HunkLine(kind: HunkLineKind.added, text: 'new c\n'),
            ],
          ),
        ],
      ),
      fileDiff(
        'src/new.dart',
        kind: FileChangeKind.renamed,
        added: 2,
        fingerprint: 'fb',
        hunks: <Hunk>[
          hunk(
            before: (start: 0, end: 0),
            after: (start: 0, end: 2),
            symbol: 'fn main()',
            lines: const <HunkLine>[
              HunkLine(kind: HunkLineKind.added, text: 'b one\n'),
              HunkLine(kind: HunkLineKind.added, text: 'b two\n'),
            ],
          ),
        ],
      ),
    ],
  };
  ZanshinFfiException? refuseSummary;
  ZanshinFfiException? refuseDiff;

  /// While set, each focused-file read (not the summary) parks in [heldDiffs].
  var holdDiff = false;
  final heldDiffs = <(String, List<String>, Completer<Diff>)>[];

  /// The focused-file reads, in call order.
  List<(String, List<String>, bool)> get focusReads => diffs.where((d) => !d.$3).toList();

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

  @override
  Future<Diff> diff(String changeId, {List<String> paths = const [], bool summary = false}) async {
    diffs.add((changeId, paths, summary));
    if ((summary ? refuseSummary : refuseDiff) case final error?) {
      throw error;
    }
    if (holdDiff && !summary) {
      final completer = Completer<Diff>();
      heldDiffs.add((changeId, paths, completer));
      return completer.future;
    }
    return diffOf(changeId, paths: paths, summary: summary);
  }

  /// What [diff] answers for [changeId].
  Diff diffOf(String changeId, {List<String> paths = const [], bool summary = false}) {
    final List<FileDiff> files = fileDiffs[changeId] ?? const <FileDiff>[];
    return Diff(
      files: <FileDiff>[
        for (final FileDiff file in files)
          if (paths.isEmpty || paths.contains(file.path))
            if (summary)
              fileDiff(
                file.path,
                kind: file.kind,
                added: file.added,
                removed: file.removed,
                fingerprint: file.fingerprint,
              )
            else
              file,
      ],
      operationId: 'op',
      commitId: 'c$changeId',
    );
  }
}

/// A file diff of [path].
FileDiff fileDiff(
  String path, {
  FileChangeKind kind = FileChangeKind.modified,
  int added = 0,
  int removed = 0,
  String fingerprint = 'f0',
  List<Hunk> hunks = const <Hunk>[],
  bool binary = false,
  bool modeChange = false,
}) => FileDiff(
  path: path,
  kind: kind,
  fromPath: null,
  binary: binary,
  modeChange: modeChange,
  sections: const [],
  hunks: hunks,
  removed: removed,
  added: added,
  fingerprint: fingerprint,
);

/// A hunk over [lines], its counts taken from them.
Hunk hunk({
  required ({int start, int end}) before,
  required ({int start, int end}) after,
  required List<HunkLine> lines,
  String? symbol,
}) => Hunk(
  before: before,
  after: after,
  symbol: symbol,
  sections: const [],
  removed: lines.where((l) => l.kind == HunkLineKind.removed).length,
  added: lines.where((l) => l.kind == HunkLineKind.added).length,
  lines: lines,
);

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
  late Directory dir;
  late SettingsStore settings;
  var ops = 0;

  setUp(() async {
    ops = 0;
    source = ScriptedGraphSource(respond: (_) => _layout('op${ops++}'));
    details = _Details();
    actions = _Actions(details);
    dir = Directory.systemTemp.createTempSync('zanshin_inspector');
    final file = File('${dir.path}/settings.json')
      ..writeAsStringSync(
        jsonEncode(
          const AppSettings(
            projects: ProjectsSettings(
              projects: <ProjectEntry>[
                ProjectEntry(path: '/r/a', name: 'a'),
                ProjectEntry(path: '/r/b', name: 'b'),
              ],
            ),
          ).toJson(),
        ),
      );
    settings = await SettingsStore.load(file);
  });

  tearDown(() => dir.deleteSync(recursive: true));

  Future<void> pump(WidgetTester tester, {String? select = _mutable, String repo = '/r/a'}) async {
    useShellWindow(tester);
    graph = GraphViewModel()..init(source, actions: actions, clock: () => DateTime.utc(2026, 10, 30, 12));
    inspector = InspectorViewModel(
      graph: graph,
      details: details,
      viewed: ProjectViewedStore(settings, repo),
      settings: settings,
    );
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
    expect(details.shows, <String>['c$_mutable'], reason: 'one read');
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
    expect(find.textContaining('2 files', findRichText: true), findsOneWidget);
    expect(find.text('src/old.dart → src/new.dart'), findsOneWidget);
    // The row comes before the diff bar's path.
    final ZsColors colors = ZsColors.of(tester.element(find.text('src/a.dart').first));
    Color? ink(String path) => tester.widget<Text>(find.text(path).first).style!.color;
    expect(ink('src/old.dart → src/new.dart'), colors.textMuted);
    await tester.tap(find.text('src/a.dart').first);
    await tester.pump();
    expect(ink('src/a.dart'), colors.text, reason: 'the clicked row is focused');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(ink('src/old.dart → src/new.dart'), colors.text, reason: 'highlighted');
    expect(inspector.focusedPath, 'src/a.dart', reason: '↓ only moves the highlight');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await tester.pump();
    expect(inspector.focusedPath, 'src/new.dart', reason: '↩ focuses the highlighted row');
    expect(details.focusReads.last.$2, <String>['src/new.dart']);
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

  group('the diff (Story 10.24)', () {
    String meta(WidgetTester tester) =>
        tester.widget<Text>(find.byKey(const ValueKey<String>('inspector-files-meta'))).textSpan!.toPlainText();

    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 3; i++) {
        await tester.pump();
      }
    }

    testWidgets('the header sums the summary, the rows show ±, the first file is focused with one read', (
      tester,
    ) async {
      await pump(tester);
      await settle(tester);
      expect(meta(tester), '2 files  +5  −1');
      expect(find.text('+3'), findsNWidgets(2), reason: 'the row and the hunk header');
      expect(find.text('−1'), findsNWidgets(2));
      expect(find.text('+2'), findsOneWidget, reason: "new.dart's row; its hunk does not show");
      expect(inspector.focusedPath, 'src/a.dart');
      expect(details.diffs.map((d) => '${d.$1} ${d.$2} ${d.$3}'), <String>[
        '$_mutable [] true',
        '$_mutable [src/a.dart] false',
      ]);
      expect(find.text('@@ −2,2 +2,4 @@'), findsOneWidget);
      expect(find.text('old a'), findsOneWidget, reason: 'the text without its newline');
      expect(find.byType(SelectionArea), findsOneWidget, reason: 'the diff text is selectable');
      await unmount(tester);
    });

    testWidgets('a click on another file reads only that file', (tester) async {
      await pump(tester);
      await settle(tester);
      await tester.tap(find.text('src/old.dart → src/new.dart'));
      await settle(tester);
      expect(details.focusReads.map((d) => d.$2), <List<String>>[
        <String>['src/a.dart'],
        <String>['src/new.dart'],
      ]);
      expect(find.text('fn main()'), findsOneWidget, reason: 'the hunk symbol');
      expect(find.text('b one'), findsOneWidget);
      expect(find.text('old a'), findsNothing);
      await unmount(tester);
    });

    testWidgets('Viewed folds the block, marks the row and shows the counter; the folded row unfolds it', (
      tester,
    ) async {
      await pump(tester);
      await settle(tester);
      expect(find.text('1/2 viewed'), findsNothing, reason: 'the counter appears with the first viewed file');
      await tester.tap(find.byWidgetPredicate((w) => w is ZsControlCore && w.identifier == 'inspector-viewed'));
      await tester.pump();
      expect(find.text('Viewed — diff folded away. Click to show it again.'), findsOneWidget);
      expect(find.text('old a'), findsNothing);
      expect(find.byKey(const ValueKey<String>('inspector-file-viewed')), findsOneWidget);
      expect(find.text('1/2 viewed'), findsOneWidget);
      expect(find.text('Mark all'), findsOneWidget);
      expect(settings.value.projects.projects.first.viewedFiles, <String>['$_mutable:fa:src/a.dart']);
      await tester.tap(find.text('Viewed — diff folded away. Click to show it again.'));
      await tester.pump();
      expect(inspector.isViewed('src/a.dart'), isFalse);
      expect(find.text('old a'), findsOneWidget);
      expect(find.text('1/2 viewed'), findsNothing);
      await unmount(tester);
    });

    testWidgets('Mark all, then "all viewed" with Reset, which clears every mark', (tester) async {
      await pump(tester);
      await settle(tester);
      inspector.setViewed('src/a.dart', true);
      await tester.pump();
      await tester.tap(find.text('Mark all'));
      await tester.pump();
      expect(find.text('all viewed'), findsOneWidget);
      expect(inspector.viewedCount, 2);
      await tester.tap(find.text('Reset'));
      await tester.pump();
      expect(inspector.viewedCount, 0);
      expect(find.text('all viewed'), findsNothing);
      expect(settings.value.projects.projects.first.viewedFiles, isEmpty);
      await unmount(tester);
    });

    testWidgets('a reload keeps Viewed for the same fingerprint and the focus; a changed one resets it', (
      tester,
    ) async {
      await pump(tester);
      await settle(tester);
      await tester.tap(find.text('src/old.dart → src/new.dart'));
      await settle(tester);
      inspector.setViewed('src/new.dart', true);
      await reload(tester);
      await settle(tester);
      expect(inspector.focusedPath, 'src/new.dart');
      expect(inspector.isViewed('src/new.dart'), isTrue);
      expect(details.diffs.where((d) => d.$3), hasLength(2), reason: 'one summary per operation');
      expect(details.focusReads.last.$2, <String>['src/new.dart'], reason: 'the focused file is read again');

      details.fileDiffs[_mutable] = <FileDiff>[
        details.fileDiffs[_mutable]!.first,
        fileDiff('src/new.dart', kind: FileChangeKind.renamed, added: 3, fingerprint: 'fc'),
      ];
      await reload(tester);
      await settle(tester);
      expect(inspector.isViewed('src/new.dart'), isFalse, reason: 'its changed lines reset the mark');
      await unmount(tester);
    });

    testWidgets('a reload without the focused path focuses the first file', (tester) async {
      await pump(tester);
      await settle(tester);
      await tester.tap(find.text('src/old.dart → src/new.dart'));
      await settle(tester);
      details.files[_mutable] = const <FileChange>[FileChange(path: 'src/a.dart', kind: FileChangeKind.modified)];
      await reload(tester);
      await settle(tester);
      expect(inspector.focusedPath, 'src/a.dart');
      expect(find.text('old a'), findsOneWidget);
      await unmount(tester);
    });

    testWidgets('Viewed is per repository: the same change, path and fingerprint elsewhere is not viewed', (
      tester,
    ) async {
      await pump(tester);
      await settle(tester);
      inspector.setViewed('src/a.dart', true);
      await unmount(tester);
      await pump(tester, repo: '/r/b');
      await settle(tester);
      expect(inspector.isViewed('src/a.dart'), isFalse);
      await unmount(tester);
      await pump(tester);
      await settle(tester);
      expect(inspector.isViewed('src/a.dart'), isTrue, reason: "A's mark stays on A's entry");
      await unmount(tester);
    });

    testWidgets('Side by side: chosen in the bar, written to the settings, follows another writer', (tester) async {
      await pump(tester);
      await settle(tester);
      expect(find.byKey(const ValueKey<String>('inspector-diff-split')), findsNothing);
      tester.widget<ZsSegmented<DiffLayoutSetting>>(find.byType(ZsSegmented<DiffLayoutSetting>)).onChanged!(
        DiffLayoutSetting.sideBySide,
      );
      await tester.pump();
      expect(settings.value.general.diffLayout, DiffLayoutSetting.sideBySide);
      expect(find.byKey(const ValueKey<String>('inspector-diff-split')), findsOneWidget);
      unawaited(
        settings
            .update((s) => s.copyWith(general: s.general.copyWith(diffLayout: DiffLayoutSetting.unified)))
            .onError<FileSystemException>((_, _) {}),
      );
      await tester.pump();
      expect(inspector.layout, DiffLayoutSetting.unified);
      expect(find.byKey(const ValueKey<String>('inspector-diff-split')), findsNothing);
      await unmount(tester);
    });

    testWidgets('a refused summary: no ±, no totals, no diff block, no focused read', (tester) async {
      details.refuseSummary = const ZanshinFfiException('jj.internal', 'no');
      await pump(tester);
      await settle(tester);
      expect(meta(tester), '2 files');
      expect(find.text('+3'), findsNothing);
      expect(find.byKey(const ValueKey<String>('inspector-diff')), findsNothing);
      expect(details.focusReads, isEmpty);
      await unmount(tester);
    });

    testWidgets('a node keyed by its commit id (hidden, divergent) reads no diff: the diff resolves change ids', (
      tester,
    ) async {
      source.respond = (_) => _layout(
        'op${ops++}',
        changeIds: <String>[
          for (final String key in _keys)
            if (key == _mutable) 'dddddddddddd' else key,
        ],
      );
      await pump(tester);
      await settle(tester);
      expect(inspector.entry, isNotNull);
      expect(details.diffs, isEmpty);
      expect(find.byKey(const ValueKey<String>('inspector-diff')), findsNothing);
      await unmount(tester);
    });

    testWidgets("a late read of the previously focused file is dropped: B's diff shows, A's lines never", (
      tester,
    ) async {
      details.holdDiff = true;
      await pump(tester);
      await settle(tester);
      await tester.tap(find.text('src/old.dart → src/new.dart'));
      await settle(tester);
      expect(details.heldDiffs.map((h) => h.$2.single), <String>['src/a.dart', 'src/new.dart']);
      details.heldDiffs[1].$3.complete(details.diffOf(_mutable, paths: <String>['src/new.dart']));
      await settle(tester);
      details.heldDiffs[0].$3.complete(details.diffOf(_mutable, paths: <String>['src/a.dart']));
      await settle(tester);
      expect(find.text('b one'), findsOneWidget);
      expect(find.text('old a'), findsNothing);
      await unmount(tester);
    });

    testWidgets("a read held across a selection change never lands on the new change's block", (tester) async {
      details
        ..holdDiff = true
        ..files[_at] = const <FileChange>[FileChange(path: 'src/at.dart', kind: FileChangeKind.modified)]
        ..fileDiffs[_at] = <FileDiff>[
          fileDiff(
            'src/at.dart',
            added: 1,
            hunks: <Hunk>[
              hunk(
                before: (start: 0, end: 0),
                after: (start: 0, end: 1),
                lines: const <HunkLine>[HunkLine(kind: HunkLineKind.added, text: 'at line\n')],
              ),
            ],
          ),
        ];
      await pump(tester);
      await settle(tester);
      graph.select(_at);
      await settle(tester);
      expect(details.heldDiffs.map((h) => h.$1), <String>[_mutable, _at]);
      details.heldDiffs[0].$3.complete(details.diffOf(_mutable, paths: <String>['src/a.dart']));
      await settle(tester);
      expect(inspector.focusedDiff, isNull, reason: "the old change's reply is dropped");
      expect(find.text('old a'), findsNothing);
      details.heldDiffs[1].$3.complete(details.diffOf(_at, paths: <String>['src/at.dart']));
      await settle(tester);
      expect(find.text('at line'), findsOneWidget);
      await unmount(tester);
    });

    testWidgets("a refused focused diff shows the refusal's text in the block", (tester) async {
      details.refuseDiff = const ZanshinFfiException('jj.internal', 'the diff failed');
      await pump(tester);
      await settle(tester);
      expect(find.text('the diff failed'), findsOneWidget);
      await unmount(tester);
    });

    for (final (String name, FileDiff file, String text) in <(String, FileDiff, String)>[
      ('binary', fileDiff('src/a.dart', binary: true), 'Binary file'),
      ('mode-only', fileDiff('src/a.dart', modeChange: true), 'Executable bit changed'),
      ('hunk-less', fileDiff('src/a.dart'), 'No line changes'),
    ]) {
      testWidgets('a $name file shows its one-line placeholder', (tester) async {
        details.fileDiffs[_mutable] = <FileDiff>[file];
        await pump(tester);
        await settle(tester);
        expect(find.text(text), findsOneWidget);
        await unmount(tester);
      });
    }
  });

  test('the layout persists in the settings file and opens from it after a restart', () async {
    final model = GraphViewModel();
    final first = InspectorViewModel(
      graph: model,
      details: _Details(),
      viewed: ProjectViewedStore(settings, '/r/a'),
      settings: settings,
    )..setLayout(DiffLayoutSetting.sideBySide);
    // Writes run in order: awaiting a later one awaits the layout's.
    await settings.update((s) => s.copyWith(general: s.general.copyWith(hideControls: false)));
    final SettingsStore restarted = await SettingsStore.load(File('${dir.path}/settings.json'));
    final second = InspectorViewModel(
      graph: model,
      details: _Details(),
      viewed: ProjectViewedStore(restarted, '/r/a'),
      settings: restarted,
    );
    expect(second.layout, DiffLayoutSetting.sideBySide);
    first.dispose();
    second.dispose();
    model.dispose();
  });

  test('ProjectViewedStore: a path outside the registry keeps its marks in memory; the newest 2000 stay', () {
    final memory = ProjectViewedStore(settings, '/r/none');
    final AppSettings before = settings.value;
    memory.save(<String>{'k1'});
    expect(memory.load(), <String>{'k1'});
    expect(settings.value, before);
    final stored = ProjectViewedStore(settings, '/r/a')..save(<String>{for (var i = 0; i < 2005; i++) 'k$i'});
    expect(stored.load(), hasLength(2000));
    expect(stored.load().first, 'k5', reason: 'the oldest go');
    expect(viewedKey('abc', 'a:b.dart', 'ff'), 'abc:ff:a:b.dart');
  });

  test('draftFrom splits the first line from the rest after the blank line', () {
    expect(InspectorViewModel.draftFrom('S\n\nD\n'), (summary: 'S', details: 'D'));
    expect(InspectorViewModel.draftFrom('S\n'), (summary: 'S', details: ''));
    expect(InspectorViewModel.draftFrom(''), (summary: '', details: ''));
    expect(InspectorViewModel.draftFrom('S\n\nA\n\nB\n'), (summary: 'S', details: 'A\n\nB'));
  });
}
