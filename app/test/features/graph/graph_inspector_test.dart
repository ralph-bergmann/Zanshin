// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' show SelectionArea;
import 'package:zanshin/src/features/graph/graph_drag.dart';
import 'package:zanshin/src/features/graph/graph_inspector.dart';
import 'package:zanshin/src/features/graph/graph_layout.dart';
import 'package:zanshin/src/features/graph/graph_ports.dart';
import 'package:zanshin/src/features/graph/graph_view.dart';
import 'package:zanshin/src/features/graph/graph_view_model.dart';
import 'package:zanshin/src/features/graph/hatch_swatch.dart';
import 'package:zanshin/src/features/graph/immutable_reasons.dart';
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

  /// Per-key overrides of the parents `show` answers.
  final parents = <String, List<String>>{};

  ShowEntry entryOf(String key) {
    const author = Signature(name: 'Ada Lovelace', email: 'ada@example.com', timestampMillis: 0, tzOffsetMinutes: 0);
    return ShowEntry(
      change: Change(
        id: key,
        commitId: 'c$key',
        parents: parents[key] ?? _parents[key]!,
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
  Future<Diff> diff(String commitId, {List<String> paths = const [], bool summary = false}) async {
    // Keyed by commit id as [show]: `c<key>`.
    final String changeId = commitId.substring(1);
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

  /// Every `squashPlan` call's change id; [combined] is its answer, [refusePlan] its refusal.
  final plans = <String>[];
  String? combined;
  ZanshinFfiException? refusePlan;

  @override
  Future<SquashPlan> squashPlan(String changeId) async {
    plans.add(changeId);
    if (refusePlan case final error?) {
      throw error;
    }
    return SquashPlan(combinedDescription: combined);
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
      commitIds: <String>['c$changeId'],
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

  /// While set, every run waits for it before it answers.
  Completer<void>? hold;

  /// The changes each run reports as new.
  var born = const <String>[];

  @override
  Future<String> headOpId() async => 'op${ran.length}';

  @override
  Future<MutationResult> run(GraphAction action) async {
    ran.add(action);
    if (hold case final hold?) {
      await hold.future;
    }
    if (refuse case final error?) {
      throw error;
    }
    if (action is GraphDescribe) {
      details.descriptions[action.id] = action.description;
    }
    return MutationResult(
      newOpId: 'op${ran.length}',
      newChangeIds: born,
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

  Future<void> pump(
    WidgetTester tester, {
    String? select = _mutable,
    String repo = '/r/a',
    ZsAppearance appearance = const ZsAppearance(),
    ImmutableReasons? reasons,
  }) async {
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
        ImmutableReasonScope(
          reasons: reasons,
          child: Align(
            alignment: Alignment.topRight,
            child: SizedBox(width: 460, height: 840, child: GraphInspector(model: inspector)),
          ),
        ),
        appearance: appearance,
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

  testWidgets('Story 10.30: the header reads the short change id ʲʲ and the short commit id ᵍⁱᵗ, '
      '"Click to copy" over each full id', (tester) async {
    await pump(tester);
    List<InlineSpan> spansOf(String key) =>
        (tester
                    .widget<Text>(
                      find.descendant(of: find.byKey(ValueKey<String>(key)), matching: find.byType(Text)).first,
                    )
                    .textSpan!
                as TextSpan)
            .children!;
    final List<InlineSpan> change = spansOf('inspector-id');
    expect((change[0] as TextSpan).text, 'mmm');
    expect((change[0] as TextSpan).style!.fontWeight, FontWeight.w600);
    expect((change[1] as TextSpan).text, 'mmmmm', reason: 'max(prefix, 8)');
    expect(find.text('jj'), findsOneWidget);
    final List<InlineSpan> commit = spansOf('inspector-commit-id');
    expect((commit[0] as TextSpan).text, 'cmmmmmmm', reason: 'max(commit prefix, 8); no prefix in this layout');
    expect(find.text('git'), findsOneWidget);
    final ZsColors colors = ZsColors.of(tester.element(find.text('git')));
    expect(tester.widget<Text>(find.text('git')).style!.color, colors.textFaint);
    final List<ZsTooltip> tips = tester
        .widgetList<ZsTooltip>(
          find.descendant(
            of: find.byKey(const ValueKey<String>('inspector-commit-id')),
            matching: find.byType(ZsTooltip),
          ),
        )
        .toList();
    expect((tips.single.message, tips.single.cmd), ('Click to copy', 'c$_mutable'));
    expect(find.text('about $_mutable'), findsOneWidget, reason: 'the title');
    expect(details.shows, <String>['c$_mutable'], reason: 'one read');
    expect(details.previews, <String>[_mutable]);
    await unmount(tester);
  });

  group('Story 10.30: copying an id', () {
    final Finder copyBubble = find.byWidgetPredicate((w) => w is ZsTooltipBubble && w.message == 'Click to copy');
    final Finder copied = find.byWidgetPredicate((w) => w is ZsTooltipBubble && w.message == 'Copied');

    /// Answers the clipboard write with [onCopy] (which may throw); null restores the platform channel.
    void clipboard(WidgetTester tester, void Function(String text)? onCopy) =>
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          onCopy == null
              ? null
              : (call) async {
                  if (call.method == 'Clipboard.setData') {
                    onCopy((call.arguments as Map<Object?, Object?>)['text']! as String);
                  }
                  return null;
                },
        );

    testWidgets('a click copies the full commit id and "Copied" shows briefly; a parent copies its full id', (
      tester,
    ) async {
      final copiedTexts = <String>[];
      clipboard(tester, copiedTexts.add);
      addTearDown(() => clipboard(tester, null));
      await pump(tester);
      await tester.tap(find.byKey(const ValueKey<String>('inspector-commit-id')));
      await tester.pump();
      expect(copiedTexts, <String>['c$_mutable']);
      await tester.pump(const Duration(milliseconds: 300));
      expect(copied, findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
      expect(copied, findsNothing, reason: 'briefly');

      await tester.tap(find.byKey(const ValueKey<String>('inspector-id')));
      await tester.pump();
      expect(copiedTexts.last, _mutable);
      final Finder parent = find.byWidgetPredicate(
        (w) => w is Semantics && w.properties.identifier == 'inspector-parent-0',
      );
      await tester.tap(parent);
      await tester.pump();
      expect(copiedTexts.last, _merge, reason: "the parent's full key");
      await tester.pump(const Duration(seconds: 2));
      await unmount(tester);
    });

    testWidgets('a failing write opens a popover with the full id as selectable text until Esc or a tap outside', (
      tester,
    ) async {
      clipboard(tester, (_) => throw PlatformException(code: 'clipboard'));
      addTearDown(() => clipboard(tester, null));
      await pump(tester);
      final Finder popover = find.byWidgetPredicate(
        (w) => w is Semantics && w.properties.identifier == 'inspector-commit-id-popover',
      );
      // Another node holds focus before the click (as the graph does): Esc must still reach the popover.
      final FocusNode other = Focus.of(tester.element(find.text('about $_mutable')))..requestFocus();
      await tester.pump();
      expect(other.hasFocus, isTrue);
      await tester.tap(find.byKey(const ValueKey<String>('inspector-commit-id')));
      await tester.pump();
      await tester.pump();
      expect(popover, findsOneWidget);
      expect(find.descendant(of: popover, matching: find.byType(SelectionArea)), findsOneWidget);
      expect(find.descendant(of: popover, matching: find.text('c$_mutable')), findsOneWidget);
      expect(copied, findsNothing);
      await tester.pump(const Duration(seconds: 3));
      expect(popover, findsOneWidget, reason: 'stays until dismissed');
      await esc(tester);
      expect(popover, findsNothing);

      await tester.tap(find.byKey(const ValueKey<String>('inspector-commit-id')));
      await tester.pump();
      await tester.pump();
      expect(popover, findsOneWidget);
      await tester.tapAt(tester.getTopLeft(find.byType(GraphInspector)) + const Offset(6, 6));
      await tester.pump();
      expect(popover, findsNothing, reason: 'a tap outside');
      await unmount(tester);
    });

    /// Records every announcement's message; [tester]'s teardown restores the channel.
    List<String> announcements(WidgetTester tester) {
      final messages = <String>[];
      tester.binding.defaultBinaryMessenger.setMockDecodedMessageHandler<Object?>(SystemChannels.accessibility, (
        message,
      ) async {
        final event = message! as Map<Object?, Object?>;
        if (event['type'] == 'announce') {
          messages.add((event['data']! as Map<Object?, Object?>)['message']! as String);
        }
        return null;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockDecodedMessageHandler<Object?>(
          SystemChannels.accessibility,
          null,
        ),
      );
      return messages;
    }

    testWidgets('an id is a Tab stop: ↩ and Space copy it; the hint says it copies and the result is announced', (
      tester,
    ) async {
      final copiedTexts = <String>[];
      clipboard(tester, copiedTexts.add);
      addTearDown(() => clipboard(tester, null));
      final List<String> announced = announcements(tester);
      await pump(tester);
      expect(
        tester.getSemantics(_id('inspector-commit-id')),
        isSemantics(label: 'c$_mutable', hint: 'Copies the full id', isButton: true, isFocusable: true),
      );
      // The control core's own node (↩ / Space act only on its primary focus).
      final FocusNode id = Focus.of(
        tester.element(find.descendant(of: _id('inspector-commit-id'), matching: find.byType(Text)).first),
      )..requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(copiedTexts, <String>['c$_mutable']);
      expect(announced, <String>['Copied']);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(copiedTexts, <String>['c$_mutable', 'c$_mutable']);
      expect(announced, <String>['Copied', 'Copied']);
      await tester.pump(const Duration(seconds: 2));

      clipboard(tester, (_) => throw PlatformException(code: 'clipboard'));
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      await tester.pump();
      expect(announced, <String>['Copied', 'Copied', "Couldn't copy. Select the id to copy it."]);
      expect(id.hasFocus, isFalse, reason: 'the popover holds focus');
      await esc(tester);
      expect(id.hasPrimaryFocus, isTrue, reason: 'Esc gives focus back to the id');
      await unmount(tester);
    });

    testWidgets('a parent outside the layout copies the full id show names', (tester) async {
      const outside = 'zzzzzzzzzzzzzzzz';
      details.parents[_mutable] = <String>[outside];
      final copiedTexts = <String>[];
      clipboard(tester, copiedTexts.add);
      addTearDown(() => clipboard(tester, null));
      await pump(tester);
      expect(find.text('zzzzzzzz', findRichText: true), findsOneWidget, reason: 'cut to 8');
      await tester.tap(_id('inspector-parent-0'));
      await tester.pump();
      expect(copiedTexts, <String>[outside]);
      await tester.pump(const Duration(seconds: 2));
      await unmount(tester);
    });

    testWidgets("while stale a parent copies the layout parent's full key", (tester) async {
      final copiedTexts = <String>[];
      clipboard(tester, copiedTexts.add);
      addTearDown(() => clipboard(tester, null));
      await pump(tester);
      details.parents[_mutable] = <String>['not-what-the-layout-says'];
      source.respond = (_) => throw staleError('stale');
      await reload(tester);
      expect(graph.stale, isNotNull);
      await tester.tap(_id('inspector-parent-0'));
      await tester.pump();
      expect(copiedTexts, <String>[_merge]);
      await tester.pump(const Duration(seconds: 2));
      await unmount(tester);
    });

    testWidgets('the id tooltip goes when the pointer leaves the id for Squash into parent', (tester) async {
      await pump(tester);
      final TestGesture mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(find.byKey(const ValueKey<String>('inspector-commit-id'))));
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(milliseconds: 300));
      expect(copyBubble, findsOneWidget);
      await mouse.moveTo(tester.getCenter(_button('inspector-squash')));
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(milliseconds: 300));
      expect(copyBubble, findsNothing);
      await unmount(tester);
    });
  });

  testWidgets('a mutable change: Edit, Squash into parent, Abandon; tooltips are the commands', (tester) async {
    await pump(tester);
    expect(_tooltipOf(tester, 'inspector-edit'), 'jj edit mmmmmmmm');
    expect(tester.widget<ZsButton>(_button('inspector-edit')).variant, ZsButtonVariant.primary);
    expect(tester.widget<ZsButton>(_button('inspector-edit')).icon, ZI.workingCopyAt);
    expect(_tooltipOf(tester, 'inspector-squash'), 'jj squash -r mmmmmmmm');
    expect(tester.widget<ZsButton>(_button('inspector-squash')).onPressed, isNotNull);
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

  testWidgets('Story 11.7: the Immutable flag names the reason the scope answers', (tester) async {
    await pump(
      tester,
      select: _left,
      reasons: ImmutableReasons(
        readAlias: () async => 'trunk() | tags()',
        counts: (operation, expressions, {required cap}) async => RevsetCounts(<RevsetCount>[
          for (final String expression in expressions)
            RevsetCount(n: expression.endsWith('::(trunk())') ? 1 : 0, capped: false, error: null),
        ], const <ZanshinWarning>[]),
      ),
    );
    await tester.pump();
    final Finder flag = find.ancestor(of: find.text('Immutable'), matching: find.byType(ZsTooltip));
    expect(tester.widget<ZsTooltip>(flag.first).message, 'Immutable · trunk()');
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
    expect(meta, contains('parents \u{FFFC} + \u{FFFC}'), reason: 'each parent is a copyable id (Story 10.30)');
    final Finder metaFinder = find.byKey(const ValueKey<String>('inspector-meta'));
    expect(find.descendant(of: metaFinder, matching: find.text('pppppppp')), findsOneWidget);
    expect(find.descendant(of: metaFinder, matching: find.text('qqqqqqqq')), findsOneWidget);
    expect(meta, contains('Ada Lovelace'));
    expect(meta, contains('1h'), reason: "the card's relative date");
    expect(find.text('A merge — no changes of its own.'), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('Story 10.10: a local chip drags its bookmark; a remote chip does not', (tester) async {
    await pump(tester);
    Future<void> drag(String text) async {
      final TestGesture mouse = await tester.startGesture(
        tester.getCenter(find.text(text)),
        kind: PointerDeviceKind.mouse,
      );
      await mouse.moveBy(const Offset(30, 0));
      await tester.pump();
      await mouse.moveBy(const Offset(30, 0));
      await tester.pump();
      await mouse.up();
      await tester.pump();
    }

    await drag('main@origin');
    expect(graph.drag.payload, isNull);
    final TestGesture mouse = await tester.startGesture(
      tester.getCenter(find.text('main')),
      kind: PointerDeviceKind.mouse,
    );
    await mouse.moveBy(const Offset(30, 0));
    await tester.pump();
    expect(graph.drag.payload, isA<GraphBookmarkDrag>().having((p) => p.name, 'name', 'main'));
    await mouse.up();
    await tester.pump();
    expect(graph.drag.payload, isNull, reason: 'a release on nothing cancels');
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

    testWidgets('Viewed follows another writer of the repository\'s viewedFiles; other settings notify nothing', (
      tester,
    ) async {
      await pump(tester);
      await settle(tester);
      var notified = 0;
      void count() => notified++;
      inspector.addListener(count);
      void writeViewed(String repo, List<String> keys) => unawaited(
        settings
            .update(
              (s) => s.copyWith(
                projects: s.projects.copyWith(
                  projects: <ProjectEntry>[
                    for (final ProjectEntry p in s.projects.projects)
                      if (p.path == repo) p.copyWith(viewedFiles: keys) else p,
                  ],
                ),
              ),
            )
            .onError<FileSystemException>((_, _) {}),
      );
      writeViewed('/r/a', <String>['$_mutable:fa:src/a.dart']);
      await tester.pump();
      expect(inspector.isViewed('src/a.dart'), isTrue);
      expect(notified, 1);
      expect(find.text('1/2 viewed'), findsOneWidget);
      // The settings changed, this repository's marks did not: no notification.
      writeViewed('/r/b', <String>['x:ff:y']);
      await tester.pump();
      expect(notified, 1);
      writeViewed('/r/a', const <String>[]);
      await tester.pump();
      expect(inspector.isViewed('src/a.dart'), isFalse);
      expect(notified, 2);
      inspector.removeListener(count);
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

    testWidgets('a node keyed by its commit id (hidden, divergent) reads its own diff by that commit id', (
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
      expect(details.diffs.map((d) => d.$1).toSet(), <String>{_mutable});
      expect(find.text('+3'), findsWidgets);
      expect(find.byKey(const ValueKey<String>('inspector-diff')), findsOneWidget);
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

    testWidgets('while another file loads the previous diff stays, dimmed, so the body keeps its height', (
      tester,
    ) async {
      details.holdDiff = true;
      await pump(tester);
      await settle(tester);
      details.heldDiffs[0].$3.complete(details.diffOf(_mutable, paths: <String>['src/a.dart']));
      await settle(tester);
      double opacityOf(String text) =>
          tester.widget<Opacity>(find.ancestor(of: find.text(text), matching: find.byType(Opacity)).first).opacity;
      expect(opacityOf('old a'), 1);
      await tester.tap(find.text('src/old.dart → src/new.dart'));
      await settle(tester);
      expect(inspector.focusedPath, 'src/new.dart');
      expect(find.text('old a'), findsOneWidget, reason: 'the previous diff stays while the new one loads');
      expect(opacityOf('old a'), lessThan(1));
      details.heldDiffs[1].$3.complete(details.diffOf(_mutable, paths: <String>['src/new.dart']));
      await settle(tester);
      expect(inspector.previousDiff, isNull);
      expect(find.text('old a'), findsNothing);
      expect(opacityOf('b one'), 1);
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

  group('the composer (Story 10.25)', () {
    setUp(() {
      details.files[_at] = const <FileChange>[
        FileChange(path: 'a.txt', kind: FileChangeKind.added),
        FileChange(path: 'b.txt', kind: FileChangeKind.modified),
      ];
      details.fileDiffs[_at] = <FileDiff>[
        fileDiff('a.txt', kind: FileChangeKind.added, added: 2, fingerprint: 'fa'),
        fileDiff('b.txt', added: 1, removed: 1, fingerprint: 'fb'),
      ];
      // A fresh @: the composer starts empty, as the CLI's editor does.
      details.descriptions[_at] = '';
    });

    Finder box(String label) => find.byWidgetPredicate((w) => w is ZsCheckbox && w.label == label);
    bool? checked(WidgetTester tester, String label) => tester.widget<ZsCheckbox>(box(label)).value;
    final Finder composer = find.byKey(const ValueKey<String>('inspector-composer'));
    String shown(WidgetTester tester) =>
        tester.widget<Text>(find.byKey(const ValueKey<String>('inspector-composer-command'))).data!;
    Finder field(String identifier) => find.descendant(of: _id(identifier), matching: find.byType(EditableText));

    /// Taps [finder] and lets the composer's entrance or exit finish.
    Future<void> tap(WidgetTester tester, Finder finder) async {
      await tester.tap(finder);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }

    Future<void> type(WidgetTester tester, String identifier, String text) async {
      await tester.enterText(field(identifier), text);
      await tester.pump();
    }

    Future<void> runIt(WidgetTester tester) async {
      await tester.tap(_button('inspector-composer-run'));
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }

    testWidgets("@ opens with every file checked; the composer shows Commit and `jj commit -m ''`", (tester) async {
      await pump(tester, select: _at);
      await tester.pump(const Duration(milliseconds: 300));
      expect(checked(tester, 'a.txt'), isTrue);
      expect(checked(tester, 'b.txt'), isTrue);
      expect(checked(tester, 'Deselect all'), isTrue);
      expect(composer, findsOneWidget);
      expect(find.descendant(of: _button('inspector-composer-run'), matching: find.text('Commit')), findsOneWidget);
      expect(shown(tester), "jj commit -m ''");
      expect(_button('inspector-composer-cancel'), findsNothing, reason: 'Cancel only on split');
      expect(tester.widget<ZsTextField>(_id('inspector-composer-summary')).placeholder, 'Summary of what you did');
      for (final text in <String>['New working copy', 'empty', 'stays here to keep working', 'Selected']) {
        expect(
          find.descendant(of: composer, matching: find.text(text)),
          findsOneWidget,
          reason: text,
        );
      }
      expect(find.descendant(of: composer, matching: find.text('2 files')), findsOneWidget);
      expect(find.descendant(of: composer, matching: find.text('+3')), findsOneWidget);
      expect(find.descendant(of: composer, matching: find.text('−1')), findsOneWidget);
      expect(find.descendant(of: composer, matching: find.text('no description yet')), findsOneWidget);
      await unmount(tester);
    });

    testWidgets('commit all: one commit with both paragraphs and no paths; the draft clears', (tester) async {
      await pump(tester, select: _at);
      await type(tester, 'inspector-composer-summary', 'Fix');
      await type(tester, 'inspector-composer-details', 'Body');
      expect(shown(tester), 'jj commit -m Fix -m Body');
      expect(find.descendant(of: composer, matching: find.text('“Fix”')), findsOneWidget);
      actions.born = const <String>['nnnnnnnnnnnn'];
      await runIt(tester);
      final commit = actions.ran.single as GraphCommit;
      expect(commit.message, <String>['Fix', 'Body']);
      expect(commit.paths, isEmpty);
      expect(commit.command, 'jj commit -m Fix -m Body');
      expect(inspector.composerDraftOf(_at), isNull);
      await unmount(tester);
    });

    testWidgets('commit a subset: only the checked path, the command shows it', (tester) async {
      await pump(tester, select: _at);
      await tap(tester, box('b.txt'));
      expect(checked(tester, 'b.txt'), isFalse);
      expect(checked(tester, 'Select all'), isFalse);
      await type(tester, 'inspector-composer-summary', 'Fix');
      expect(shown(tester), 'jj commit -m Fix root:a.txt');
      expect(
        find.descendant(of: composer, matching: find.text('1 file')),
        findsNWidgets(2),
        reason: 'rest and selected',
      );
      await runIt(tester);
      expect((actions.ran.single as GraphCommit).paths, <String>['a.txt']);
      await unmount(tester);
    });

    testWidgets('nothing checked on @: the composer stays, Commit is disabled; select all checks every file', (
      tester,
    ) async {
      await pump(tester, select: _at);
      await tap(tester, box('Deselect all'));
      expect(checked(tester, 'a.txt'), isFalse);
      expect(checked(tester, 'b.txt'), isFalse);
      expect(composer, findsOneWidget);
      expect(find.descendant(of: composer, matching: find.text('nothing yet')), findsOneWidget);
      expect(tester.widget<ZsButton>(_button('inspector-composer-run')).onPressed, isNull);
      expect(shown(tester), isEmpty, reason: 'no command: a bare jj commit would take everything');
      await tap(tester, box('Select all'));
      expect(checked(tester, 'a.txt'), isTrue);
      expect(checked(tester, 'b.txt'), isTrue);
      await unmount(tester);
    });

    testWidgets('a path with `[` goes as a quoted fileset in the command and verbatim to the call', (tester) async {
      details.files[_at] = const <FileChange>[
        FileChange(path: 'a[1].txt', kind: FileChangeKind.added),
        FileChange(path: 'b.txt', kind: FileChangeKind.modified),
      ];
      await pump(tester, select: _at);
      await tap(tester, box('b.txt'));
      expect(shown(tester), 'jj commit -m \'\' \'root:"a[1].txt"\'');
      await runIt(tester);
      expect((actions.ran.single as GraphCommit).paths, <String>['a[1].txt']);
      await unmount(tester);
    });

    testWidgets('another change: none checked, no composer; one checked shows Split; it runs it by the full id', (
      tester,
    ) async {
      await pump(tester);
      await tester.pump(const Duration(milliseconds: 300));
      expect(checked(tester, 'src/a.dart'), isFalse);
      expect(checked(tester, 'src/new.dart'), isFalse);
      expect(composer, findsNothing);
      await tap(tester, box('src/a.dart'));
      expect(composer, findsOneWidget);
      expect(find.descendant(of: _button('inspector-composer-run'), matching: find.text('Split')), findsOneWidget);
      expect(_button('inspector-composer-cancel'), findsOneWidget);
      expect(
        tester.widget<ZsTextField>(_id('inspector-composer-summary')).placeholder,
        'Summary of the selected changes',
      );
      expect(find.descendant(of: composer, matching: find.text('Rest')), findsOneWidget);
      expect(find.descendant(of: composer, matching: find.text('keeps “about mmmmmmmmmmmm”')), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('inspector-composer-hint')), findsNothing);
      await type(tester, 'inspector-composer-summary', 'Part');
      final String command = shown(tester);
      expect(command, 'jj split -r mmmmmmmm -m Part root:src/a.dart');
      await runIt(tester);
      final split = actions.ran.single as GraphSplit;
      expect(split.id, _mutable);
      expect(split.paths, <String>['src/a.dart']);
      expect(split.message, <String>['Part']);
      // The preview names the short id, the run (its Undo/Redo toast) the full one.
      expect(split.command, 'jj split -r $_mutable -m Part root:src/a.dart');
      expect(graph.selected, _mutable, reason: 'the selection stays');
      expect(checked(tester, 'src/a.dart'), isFalse, reason: 'done clears the checks');
      expect(composer, findsNothing);
      await unmount(tester);
    });

    testWidgets('Cancel unchecks everything and keeps the draft; the composer fades out', (tester) async {
      await pump(tester);
      await tap(tester, box('src/a.dart'));
      await type(tester, 'inspector-composer-summary', 'Part');
      await tester.tap(_button('inspector-composer-cancel'));
      await tester.pump();
      expect(checked(tester, 'src/a.dart'), isFalse);
      expect(composer, findsOneWidget, reason: 'the exit plays');
      await tester.pump(const Duration(milliseconds: 200));
      expect(composer, findsNothing);
      expect(inspector.composerDraftOf(_mutable)?.summary, 'Part');
      await unmount(tester);
    });

    testWidgets("split with everything checked shows jj's hint and runs", (tester) async {
      await pump(tester);
      await tap(tester, box('Select all'));
      expect(
        find.text('All changes have been selected, so the original revision will become empty.'),
        findsOneWidget,
      );
      await runIt(tester);
      expect((actions.ran.single as GraphSplit).paths, <String>['src/a.dart', 'src/new.dart']);
      await unmount(tester);
    });

    testWidgets("a refusal keeps the draft and the checks; the composer shows jj's text in the warn colour", (
      tester,
    ) async {
      await pump(tester);
      await tap(tester, box('src/a.dart'));
      await type(tester, 'inspector-composer-summary', 'Part');
      actions.refuse = const ZanshinFfiException('jj.immutable', 'Commit mmmmmmmm is immutable');
      await runIt(tester);
      final Text error = tester.widget<Text>(find.byKey(const ValueKey<String>('inspector-composer-error')));
      expect(error.data, 'Commit mmmmmmmm is immutable');
      expect(error.style!.color, ZsColors.of(tester.element(composer)).warn);
      expect(checked(tester, 'src/a.dart'), isTrue);
      expect(inspector.composerDraftOf(_mutable)?.summary, 'Part');
      await tap(tester, box('src/new.dart'));
      expect(
        find.byKey(const ValueKey<String>('inspector-composer-error')),
        findsNothing,
        reason: 'a change clears it',
      );
      await unmount(tester);
    });

    testWidgets('a refusal that lands after the selection moved on shows in no composer', (tester) async {
      await pump(tester);
      await tap(tester, box('src/a.dart'));
      final hold = Completer<void>();
      actions
        ..hold = hold
        ..refuse = const ZanshinFfiException('jj.immutable', 'Commit mmmmmmmm is immutable');
      final Future<GraphActionResult?> running = inspector.runComposer();
      graph.select(_at);
      await tester.pump();
      hold.complete();
      final GraphActionResult? result = await tester.runAsync<GraphActionResult?>(() => running);
      await tester.pump();
      expect(result, isA<GraphActionRefused>());
      expect(inspector.composerError, isNull, reason: "the refusal is the toast's, not @'s composer's");
      expect(find.byKey(const ValueKey<String>('inspector-composer-error')), findsNothing);
      await unmount(tester);
    });

    testWidgets("a described @ with untouched fields commits its description's paragraphs", (tester) async {
      details.descriptions[_at] = 'Fix it\n\nBecause.\n';
      await pump(tester, select: _at);
      expect(tester.widget<EditableText>(field('inspector-composer-summary')).controller.text, 'Fix it');
      expect(shown(tester), "jj commit -m 'Fix it' -m Because.");
      await runIt(tester);
      expect((actions.ran.single as GraphCommit).message, <String>['Fix it', 'Because.']);
      await unmount(tester);
    });

    testWidgets('the draft survives a selection change and a reload; the checks reset on the change only', (
      tester,
    ) async {
      await pump(tester);
      await tap(tester, box('src/a.dart'));
      await type(tester, 'inspector-composer-summary', 'Keep');
      graph.select(_at);
      await tester.pump();
      await tester.pump();
      graph.select(_mutable);
      await tester.pump();
      await tester.pump();
      expect(checked(tester, 'src/a.dart'), isFalse, reason: 'a selection change resets the checks');
      await tap(tester, box('src/a.dart'));
      expect(tester.widget<EditableText>(field('inspector-composer-summary')).controller.text, 'Keep');
      await reload(tester);
      await tester.pump();
      expect(checked(tester, 'src/a.dart'), isTrue, reason: 'a reload keeps the still-listed checks');
      expect(tester.widget<EditableText>(field('inspector-composer-summary')).controller.text, 'Keep');
      await unmount(tester);
    });

    testWidgets('Esc in a composer field with a draft only leaves the field; the next one closes the inspector', (
      tester,
    ) async {
      await pump(tester, select: _at);
      await tester.tap(field('inspector-composer-summary'));
      await type(tester, 'inspector-composer-summary', 'x');
      expect(tester.widget<EditableText>(field('inspector-composer-summary')).focusNode.hasFocus, isTrue);
      await esc(tester);
      expect(graph.selected, _at);
      expect(tester.widget<EditableText>(field('inspector-composer-summary')).focusNode.hasFocus, isFalse);
      await esc(tester);
      expect(graph.selected, isNull);
      await unmount(tester);
    });

    double rise(WidgetTester tester) => tester
        .widget<Transform>(find.byKey(const ValueKey<String>('inspector-composer-motion')))
        .transform
        .getTranslation()
        .y;
    double opacity(WidgetTester tester) => tester
        .widget<ZsFade>(
          find.descendant(
            of: find.byKey(const ValueKey<String>('inspector-composer-motion')),
            matching: find.byType(ZsFade),
          ),
        )
        .opacity;

    testWidgets('the composer rises 12 px and fades in; under reduce motion it only fades', (tester) async {
      await pump(tester);
      await tester.tap(box('src/a.dart'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      expect(rise(tester), greaterThan(0));
      expect(rise(tester), lessThanOrEqualTo(12));
      await tester.pump(const Duration(milliseconds: 300));
      expect(rise(tester), 0);
      expect(opacity(tester), 1);
      // Out it drifts back down as it fades.
      await tester.tap(_button('inspector-composer-cancel'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 90));
      expect(rise(tester), greaterThan(0));
      expect(opacity(tester), lessThan(1));
      await tester.pump(const Duration(milliseconds: 200));
      await unmount(tester);

      await pump(tester, appearance: const ZsAppearance(reduceMotion: true));
      await tester.tap(box('src/a.dart'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      expect(rise(tester), 0, reason: 'no movement');
      expect(opacity(tester), lessThan(1), reason: 'the fade keeps its token');
      await tester.pump(const Duration(milliseconds: 300));
      await unmount(tester);
    });
  });

  group('Squash into parent (Story 10.25)', () {
    testWidgets('two descriptions: the form pre-filled with the combined text; Save sends it as editedDescription', (
      tester,
    ) async {
      details.combined = 'A\n\nB\n';
      await pump(tester);
      await tester.tap(_button('inspector-squash'));
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(details.plans, <String>[_mutable]);
      expect(
        tester
            .widget<EditableText>(find.descendant(of: _id('inspector-summary'), matching: find.byType(EditableText)))
            .controller
            .text,
        'A',
      );
      expect(
        tester
            .widget<EditableText>(find.descendant(of: _id('inspector-details'), matching: find.byType(EditableText)))
            .controller
            .text,
        'B',
      );
      expect(find.descendant(of: _button('inspector-save'), matching: find.text('Squash')), findsOneWidget);
      expect(find.text('jj squash -r mmmmmmmm'), findsOneWidget);
      expect(actions.ran, isEmpty);
      await tester.tap(_button('inspector-save'));
      await tester.pump();
      await tester.pump();
      final squash = actions.ran.single as GraphSquash;
      expect(squash.revision, _mutable);
      expect(squash.editedDescription, 'A\n\nB\n');
      expect(squash.message, isNull);
      expect(_id('inspector-summary'), findsNothing, reason: 'the form closes once it ran');
      await unmount(tester);
    });

    testWidgets('a new operation closes the squash form: its combined description may be gone', (tester) async {
      details.combined = 'A\n\nB\n';
      await pump(tester);
      await tester.tap(_button('inspector-squash'));
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(_id('inspector-summary'), findsOneWidget);
      await reload(tester);
      expect(_id('inspector-summary'), findsNothing);
      expect(inspector.squashFormOf(_mutable), isNull);
      expect(actions.ran, isEmpty);
      await unmount(tester);
    });

    testWidgets('Esc and Cancel close the squash form with no call', (tester) async {
      details.combined = 'A\n\nB\n';
      await pump(tester);
      await tester.tap(_button('inspector-squash'));
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(_id('inspector-summary'), findsOneWidget);
      await esc(tester);
      expect(_id('inspector-summary'), findsNothing);
      expect(graph.selected, _mutable);
      await tester.tap(_button('inspector-squash'));
      await tester.pump();
      await tester.pump();
      await tester.pump();
      await tester.tap(_button('inspector-cancel'));
      await tester.pump();
      expect(_id('inspector-summary'), findsNothing);
      expect(actions.ran, isEmpty);
      await unmount(tester);
    });

    testWidgets('one description: squash runs at once; a refused plan runs it too so the runner reports jj', (
      tester,
    ) async {
      await pump(tester, select: null);
      await inspector.squash(_mutable);
      await tester.pump();
      expect(graph.selected, _mutable, reason: 'squash(key) selects the change');
      expect(actions.ran.single, isA<GraphSquash>().having((a) => a.editedDescription, 'edited', isNull));
      expect((actions.ran.single as GraphSquash).revision, _mutable);
      await tester.pump();
      details.refusePlan = const ZanshinFfiException('jj.immutable', 'Commit gggggggg is immutable');
      await inspector.squash(_mutable);
      await tester.pump();
      expect(actions.ran, hasLength(2));
      expect(details.plans, <String>[_mutable, _mutable]);
      await tester.pump();
      await unmount(tester);
    });
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
