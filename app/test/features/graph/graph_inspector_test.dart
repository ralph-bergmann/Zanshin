// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart' show PointerDeviceKind, kSecondaryButton;
import 'package:flutter/rendering.dart' show RenderParagraph;
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
import 'package:zanshin/src/features/graph/inspector_diff.dart'
    show DiffWordMarks, InspectorDiffHunk, InspectorDiffView, diffNewLineAt;
import 'package:zanshin/src/features/graph/inspector_viewed_store.dart';
import 'package:zanshin/src/features/graph/project_files.dart';
import 'package:zanshin/src/features/graph/recorded_graph_layout.dart';
import 'package:zanshin/src/features/projects/projects_environment.dart' show DiffContext;
import 'package:zanshin/src/features/shell/shell_toast.dart';
import 'package:zanshin/src/features/window/app_window_actions.dart';
import 'package:zanshin_core/zanshin_core.dart';
import 'package:zanshin_settings/zanshin_settings.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

import '../../helpers/fake_window_actions.dart';
import '../../helpers/icon_registry.dart';
import '../../helpers/scripted_graph_source.dart';
import '../../helpers/settle_settings.dart';
import '../../helpers/shell_host.dart';
import '../../helpers/word_marks.dart';
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
  ActionOutcome absorb = _available;
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
      parentTreeIds: <String>['t$key-'],
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
      absorb: absorb,
    );
  }

  /// Every `diff` call's whitespace mode, in call order.
  final modes = <DiffWhitespace>[];

  /// The reads at `-b` / `-w` per key; a key without an entry answers its exact files.
  final ignoredDiffs = <String, List<FileDiff>>{};

  /// The refusal of the reads at `-b` / `-w`.
  ZanshinFfiException? refuseIgnored;

  /// What `diffContext` answers; [refuseContextWrite] refuses `setDiffContext`, which records in [contextWrites] and
  /// then runs [afterContextWrite] (the environment's config write).
  int? context = 3;
  var contextFromRepo = false;
  ZanshinFfiException? refuseContextWrite;
  final contextWrites = <int>[];
  void Function()? afterContextWrite;

  @override
  Future<DiffContext> diffContext() async => (lines: context, fromRepo: contextFromRepo);

  @override
  Future<void> setDiffContext(int lines) async {
    if (refuseContextWrite case final error?) {
      throw error;
    }
    contextWrites.add(lines);
    context = lines;
    afterContextWrite?.call();
  }

  @override
  Future<Diff> diff(
    String commitId, {
    List<String> paths = const [],
    bool summary = false,
    DiffWhitespace whitespace = DiffWhitespace.exact,
  }) async {
    // Keyed by commit id as [show]: `c<key>`.
    final String changeId = commitId.substring(1);
    modes.add(whitespace);
    if (whitespace != DiffWhitespace.exact) {
      if (refuseIgnored case final error?) {
        throw error;
      }
      final Diff exact = diffOf(changeId, paths: paths);
      final List<FileDiff>? ignored = ignoredDiffs[changeId];
      return ignored == null
          ? exact
          : Diff(
              files: <FileDiff>[
                for (final FileDiff file in ignored)
                  if (paths.isEmpty || paths.contains(file.path)) file,
              ],
              operationId: exact.operationId,
              commitIds: exact.commitIds,
            );
    }
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
                modeChange: file.modeChange,
                sections: file.sections,
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
  List<HunkKey> sections = const <HunkKey>[],
}) => FileDiff(
  path: path,
  kind: kind,
  fromPath: null,
  binary: binary,
  modeChange: modeChange,
  sections: sections,
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
  List<HunkKey> sections = const <HunkKey>[],
}) => Hunk(
  before: before,
  after: after,
  symbol: symbol,
  sections: sections,
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
      committed: true,
      newChangeIds: born,
      abandonedChangeIds: const <String>[],
      workingCopyChangeId: null,
      finish: null,
    );
  }

  @override
  Future<AbsorbResult> absorb(String from) async => AbsorbResult(
    mutation: await run(GraphAbsorb(from)),
    rewrittenChangeIds: const <String>['a'],
    sourceChangeId: from,
    numRebased: 0,
    skippedPaths: const <SkippedPath>[],
  );
}

Finder _id(String identifier) => find.byWidgetPredicate(
  (widget) => switch (widget) {
    final ZsControl control => control.identifier == identifier,
    final ZsControlCore core => core.identifier == identifier,
    _ => false,
  },
);

/// The inspector's row of the file at [path] (Story 10.39: the row shows the name first, not the path).
Finder _fileRow(String path) => find.byKey(ValueKey<String>('inspector-file $path'));

Finder _button(String identifier) =>
    find.byWidgetPredicate((widget) => widget is ZsButton && widget.identifier == identifier);

String _tooltipOf(WidgetTester tester, String identifier) =>
    tester.widget<ZsTooltip>(find.ancestor(of: _button(identifier), matching: find.byType(ZsTooltip)).first).message;

/// The Squash menu button (Story 10.36).
Finder get _squashMenu =>
    find.byWidgetPredicate((widget) => widget is ZsMenuButton && widget.identifier == 'inspector-squash-menu');

/// The Squash menu's row [identifier] (`inspector-squash`, `inspector-absorb`).
ZsMenuItem _squashRow(WidgetTester tester, String identifier) => tester
    .widget<ZsMenuButton>(_squashMenu)
    .entries
    .whereType<ZsMenuItem>()
    .singleWhere((item) => item.identifier == identifier);

/// Opens the Squash menu and chooses the row labelled [label]; its command runs after the row's blink.
Future<void> _chooseFromSquashMenu(WidgetTester tester, String label) async {
  await tester.tap(_button('inspector-squash-menu'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
  await tester.tap(find.text(label));
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
  await tester.pump(const Duration(seconds: 1));
}

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
    // The test font draws every glyph 1 em wide: a full command needs a wider inspector than the app's.
    double width = 460,
    ProjectFiles? files,
    AppWindowActions? windowActions,
  }) async {
    // The group's tearDown deletes the folder after postTest; the writes must be done before then.
    addTearDown(() => settleSettingsWrites(tester, settings));
    useShellWindow(tester);
    graph = GraphViewModel()..init(source, actions: actions, clock: () => DateTime.utc(2026, 10, 30, 12));
    inspector = InspectorViewModel(
      graph: graph,
      details: details,
      viewed: ProjectViewedStore(settings, repo),
      settings: settings,
      files: files,
    );
    await tester.pumpWidget(
      shellHost(
        ImmutableReasonScope(
          reasons: reasons,
          child: Align(
            alignment: Alignment.topRight,
            child: SizedBox(
              width: width,
              height: 840,
              child: windowActions == null
                  ? GraphInspector(model: inspector)
                  : AppWindowActionsScope(
                      actions: windowActions,
                      child: GraphInspector(model: inspector),
                    ),
            ),
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

    testWidgets('the id tooltip goes when the pointer leaves the id for the Squash menu', (tester) async {
      await pump(tester);
      final TestGesture mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(find.byKey(const ValueKey<String>('inspector-commit-id'))));
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(milliseconds: 300));
      expect(copyBubble, findsOneWidget);
      await mouse.moveTo(tester.getCenter(_button('inspector-squash-menu')));
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(milliseconds: 300));
      expect(copyBubble, findsNothing);
      await unmount(tester);
    });
  });

  testWidgets('a mutable change: Edit, the Squash menu, Abandon; tooltips are the commands', (tester) async {
    await pump(tester);
    expect(_tooltipOf(tester, 'inspector-edit'), 'jj edit mmmmmmmm');
    expect(tester.widget<ZsButton>(_button('inspector-edit')).variant, ZsButtonVariant.primary);
    expect(tester.widget<ZsButton>(_button('inspector-edit')).icon, ZI.workingCopyAt);
    expect(_tooltipOf(tester, 'inspector-squash-menu'), 'Squash or absorb into earlier changes');
    expect(tester.widget<ZsButton>(_button('inspector-squash-menu')).onPressed, isNotNull);
    expect(find.descendant(of: _squashMenu, matching: find.text('Squash')), findsOneWidget);
    final ZsMenuItem squash = _squashRow(tester, 'inspector-squash');
    expect(
      (squash.label, squash.cmd, squash.tooltip, squash.enabled),
      (
        'Squash into parent',
        'jj squash -r mmmmmmmm',
        'jj squash -r mmmmmmmm',
        true,
      ),
    );
    final ZsMenuItem absorb = _squashRow(tester, 'inspector-absorb');
    expect(
      (absorb.label, absorb.cmd, absorb.tooltip, absorb.enabled),
      (
        'Absorb into ancestors',
        'jj absorb --from mmmmmmmm',
        'jj absorb --from mmmmmmmm',
        true,
      ),
    );
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
    final ZsMenuItem squash = _squashRow(tester, 'inspector-squash');
    expect((squash.enabled, squash.tooltip), (false, 'Commit gggggggg is immutable'));
    expect(_squashRow(tester, 'inspector-absorb').enabled, isTrue, reason: 'each row has its own preview');
    await unmount(tester);
  });

  group('Absorb into ancestors (Story 10.36)', () {
    testWidgets('nothing absorbable: disabled with the reason, the command still its hint', (tester) async {
      details.absorb = const ActionOutcome(
        status: ActionStatus.noOp,
        refusal: null,
        combinedDescriptionNeeded: false,
        allowBackwardsNeeded: false,
      );
      await pump(tester);
      final ZsMenuItem absorb = _squashRow(tester, 'inspector-absorb');
      expect(
        (absorb.enabled, absorb.tooltip, absorb.cmd),
        (
          false,
          'Nothing to absorb: no hunk belongs to an earlier change.',
          'jj absorb --from mmmmmmmm',
        ),
      );
      expect(_squashRow(tester, 'inspector-squash').enabled, isTrue);
      await unmount(tester);
    });

    testWidgets("refused: disabled with jj's text", (tester) async {
      details.absorb = const ActionOutcome(
        status: ActionStatus.refused,
        refusal: ActionRefusal('jj.change_not_found', 'Revision `mmmmmmmm` doesn\'t exist'),
        combinedDescriptionNeeded: false,
        allowBackwardsNeeded: false,
      );
      await pump(tester);
      final ZsMenuItem absorb = _squashRow(tester, 'inspector-absorb');
      expect((absorb.enabled, absorb.tooltip), (false, "Revision `mmmmmmmm` doesn't exist"));
      await unmount(tester);
    });

    testWidgets('the menu opens under the button; choosing Absorb runs jj absorb --from through the runner', (
      tester,
    ) async {
      await pump(tester);
      await tester.tap(_button('inspector-squash-menu'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      final Rect button = tester.getRect(_squashMenu);
      // The exact placement (4 below the left edge) is ZsMenuButton's own test.
      final Rect row = tester.getRect(find.text('Squash into parent'));
      expect(row.top, greaterThan(button.bottom));
      expect(row.left, greaterThan(button.left));
      expect(find.text('jj squash -r mmmmmmmm'), findsOneWidget);
      expect(find.text('jj absorb --from mmmmmmmm'), findsOneWidget);
      await tester.tap(find.text('Absorb into ancestors'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      expect(actions.ran.single, isA<GraphAbsorb>().having((a) => a.id, 'id', _mutable));
      expect(details.plans, isEmpty, reason: 'absorb asks no squash plan');
      await unmount(tester);
    });

    testWidgets('busy: the menu button is disabled with the reason', (tester) async {
      await pump(tester);
      actions.hold = Completer<void>();
      unawaited(graph.run(const GraphEdit(_mutable)));
      await tester.pump();
      final ZsButton menu = tester.widget<ZsButton>(_button('inspector-squash-menu'));
      expect(menu.onPressed, isNull);
      expect(menu.disabledReason, isNotNull);
      actions.hold!.complete();
      await tester.pump();
      await tester.pump();
      await unmount(tester);
    });
  });

  testWidgets('@ with no files: the flag, the empty text, New change / Squash / Abandon', (tester) async {
    await pump(tester, select: _at);
    expect(find.text('@ Working copy'), findsOneWidget);
    expect(find.text('Empty'), findsOneWidget);
    expect(find.text('No changes yet — whatever you edit in your editor lands here.'), findsOneWidget);
    expect(find.descendant(of: _button('inspector-new'), matching: find.text('New change')), findsOneWidget);
    expect(_tooltipOf(tester, 'inspector-new'), 'jj new wwwwwwww');
    expect(_button('inspector-squash-menu'), findsOneWidget);
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
    expect(
      meta,
      contains('parents \u{FFFC}\u{FFFC} + \u{FFFC}\u{FFFC}'),
      reason: 'each parent is a copyable id (Story 10.30) and its jump (Story 10.35)',
    );
    final Finder metaFinder = find.byKey(const ValueKey<String>('inspector-meta'));
    expect(find.descendant(of: metaFinder, matching: find.text('pppppppp')), findsOneWidget);
    expect(find.descendant(of: metaFinder, matching: find.text('qqqqqqqq')), findsOneWidget);
    // Story 10.35: jj's prefix bold in --text, as the header's change id.
    final ZsColors colors = ZsColors.of(tester.element(metaFinder));
    for (final i in <int>[0, 1]) {
      final prefix =
          (tester
                          .widget<Text>(
                            find.descendant(of: _id('inspector-parent-$i'), matching: find.byType(Text)).first,
                          )
                          .textSpan!
                      as TextSpan)
                  .children!
                  .first
              as TextSpan;
      expect(
        (prefix.text, prefix.style!.fontWeight, prefix.style!.color),
        (i == 0 ? 'pp' : 'qq', FontWeight.w600, colors.text),
      );
      expect(tester.widget<ZsControlCore>(_id('inspector-parent-jump-$i')).disabledReason, isNull);
    }
    expect(meta, contains('Ada Lovelace'));
    expect(meta, contains('1h'), reason: "the card's relative date");
    expect(find.text('A merge — no changes of its own.'), findsOneWidget);
    await unmount(tester);
  });

  group("Story 10.35: a parent's jump", () {
    String tooltipOf(WidgetTester tester, String identifier) =>
        tester.widget<ZsTooltip>(find.ancestor(of: _id(identifier), matching: find.byType(ZsTooltip)).first).message;

    testWidgets('selects the parent and reveals it (goTo)', (tester) async {
      await pump(tester);
      expect(tester.widget<ZsControlCore>(_id('inspector-parent-jump-0')).disabledReason, isNull);
      expect(tooltipOf(tester, 'inspector-parent-jump-0'), 'Select parent gggggggg');
      expect(
        tester.getSemantics(_id('inspector-parent-jump-0')),
        isSemantics(label: 'Select parent gggggggg', isButton: true, isEnabled: true),
      );
      await tester.tap(_id('inspector-parent-jump-0'));
      await tester.pump();
      await tester.pump();
      expect(graph.selected, _merge);
      expect(graph.reveal?.key, _merge);
      expect(graph.layout!.placeOfKey(_merge), isNotNull);
      await unmount(tester);
    });

    testWidgets('a parent outside the layout: a plain id, the jump disabled with the reason', (tester) async {
      details.parents[_mutable] = <String>['zzzzzzzzzzzzzzzz'];
      await pump(tester);
      final ZsControlCore jump = tester.widget<ZsControlCore>(_id('inspector-parent-jump-0'));
      expect(jump.disabledReason, 'Parent zzzzzzzz is not in the shown graph');
      expect(jump.onActivate, isNull);
      final List<InlineSpan> spans =
          (tester
                      .widget<Text>(find.descendant(of: _id('inspector-parent-0'), matching: find.byType(Text)).first)
                      .textSpan!
                  as TextSpan)
              .children!;
      expect(spans.whereType<TextSpan>().map((s) => s.style?.fontWeight), isNot(contains(FontWeight.w600)));
      await unmount(tester);
    });

    testWidgets("a parent keyed by its commit id takes the commit id's prefix, not the change id's", (tester) async {
      source.respond = (_) => _layout(
        'op0',
        changeIds: <String>[
          for (final String key in _keys)
            if (key == _merge) 'dddddddddddd' else key,
        ],
      );
      await pump(tester);
      final List<InlineSpan> spans =
          (tester
                      .widget<Text>(find.descendant(of: _id('inspector-parent-0'), matching: find.byType(Text)).first)
                      .textSpan!
                  as TextSpan)
              .children!;
      // The recorded layout has no commit prefixes, so nothing is bold; the change id's would bold 2 characters.
      expect(spans.whereType<TextSpan>().map((s) => s.style?.fontWeight), isNot(contains(FontWeight.w600)));
      expect(tester.widget<ZsControlCore>(_id('inspector-parent-jump-0')).disabledReason, isNull);
      await unmount(tester);
    });

    testWidgets('a parent folded into a stack: the jump is enabled and asks the graph to open the stack', (
      tester,
    ) async {
      source.respond = (_) => hugeStackLayout(4);
      // The harness reads `show` by the key's tail; hugeStackLayout's commit ids are its keys.
      details.descriptions['ead'] = 'head\n';
      details.parents['ead'] = <String>['m2'];
      details.descriptions['2'] = 'm2\n';
      details.parents['2'] = <String>['m1'];
      await pump(tester, select: 'head');
      expect(tester.widget<ZsControlCore>(_id('inspector-parent-jump-0')).disabledReason, isNull);
      await tester.tap(_id('inspector-parent-jump-0'));
      await tester.pump();
      expect(graph.selected, 'm2');
      expect(source.requests.last.keepOpenKeys, contains('m2'));
      await unmount(tester);
    });
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

  testWidgets('the chips and the files: ✓ / local / remote, the count, a rename, ↑ ↓ show the next file', (
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
    // Story 10.39: a rename shows its new name first, its folder after it, `old → new` as the tooltip.
    expect(find.descendant(of: _fileRow('src/new.dart'), matching: find.text('new.dart')), findsOneWidget);
    expect(find.descendant(of: _fileRow('src/new.dart'), matching: find.text('src/')), findsOneWidget);
    expect(
      tester
          .widget<ZsTooltip>(find.descendant(of: _fileRow('src/new.dart'), matching: find.byType(ZsTooltip)).first)
          .message,
      'src/old.dart → src/new.dart',
    );
    final ZsColors colors = ZsColors.of(tester.element(_fileRow('src/a.dart')));
    expect(
      tester.widget<Text>(find.descendant(of: _fileRow('src/new.dart'), matching: find.text('new.dart'))).style!.color,
      colors.text,
      reason: 'the name in --text',
    );
    expect(
      tester.widget<Text>(find.descendant(of: _fileRow('src/new.dart'), matching: find.text('src/'))).style!.color,
      colors.textFaint,
      reason: 'the folder in --text-faint',
    );
    bool current(String path) => tester.widget<InspectorFileRow>(_fileRow(path)).focused;
    expect(current('src/new.dart'), isFalse);
    await tester.tap(_fileRow('src/a.dart'));
    await tester.pump();
    expect(current('src/a.dart'), isTrue, reason: 'the clicked row is focused');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.pump();
    expect(current('src/new.dart'), isTrue, reason: 'the current row');
    expect(inspector.focusedPath, 'src/new.dart', reason: '↓ shows the next file at once (Finder)');
    expect(details.focusReads.last.$2, <String>['src/new.dart']);
    final int reads = details.focusReads.length;
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(inspector.focusedPath, 'src/new.dart', reason: '↩ keeps the current row');
    expect(details.focusReads.length, reads, reason: 'no harm: nothing new to read');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(current('src/a.dart'), isTrue);
    expect(inspector.focusedPath, 'src/a.dart');
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

  group('Story 10.35: a form the selection leaves stays open only with a changed draft', () {
    Future<void> leaveAndReturn(WidgetTester tester, String? other) async {
      graph.select(other);
      await tester.pump();
      await tester.pump();
      graph.select(_mutable);
      await tester.pump();
      await tester.pump();
    }

    testWidgets('untouched, then the selection clears: the title label comes back', (tester) async {
      await pump(tester);
      await openForm(tester);
      expect(_id('inspector-summary'), findsOneWidget);
      await leaveAndReturn(tester, null);
      expect(_id('inspector-summary'), findsNothing);
      expect(_id('inspector-title'), findsOneWidget);
      await unmount(tester);
    });

    testWidgets('typed and reverted to the description: the title label comes back', (tester) async {
      await pump(tester);
      await openForm(tester);
      final Finder summary = find.descendant(of: _id('inspector-summary'), matching: find.byType(EditableText));
      await tester.enterText(summary, 'about ${_mutable}x');
      await tester.enterText(summary, 'about $_mutable');
      await leaveAndReturn(tester, _at);
      expect(_id('inspector-summary'), findsNothing);
      expect(_id('inspector-title'), findsOneWidget);
      await unmount(tester);
    });
  });

  testWidgets('Story 11.23: a stale untouched draft is dropped; a typed one stays with the "changed meanwhile" note', (
    tester,
  ) async {
    await pump(tester);
    final Finder summary = find.descendant(of: _id('inspector-summary'), matching: find.byType(EditableText));
    String shown() => tester.widget<EditableText>(summary).controller.text;
    const note = 'The description changed meanwhile.';

    await openForm(tester);
    await tester.enterText(summary, 'about $_mutable');
    inspector.closeForm(_mutable);
    details.descriptions[_mutable] = 'new\n';
    await reload(tester);
    await openForm(tester);
    expect(shown(), 'new', reason: 'the draft still held the old prefill: the new description prefills');
    expect(find.text(note), findsNothing);
    expect(inspector.draftOf(_mutable), isNull);

    await tester.enterText(summary, 'my text');
    inspector.closeForm(_mutable);
    details.descriptions[_mutable] = 'newer\n';
    await reload(tester);
    await openForm(tester);
    expect(shown(), 'my text', reason: 'a typed draft survives');
    expect(find.text(note), findsOneWidget);
    expect(inspector.describedMeanwhile(_mutable), isTrue);
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

    testWidgets("Story 10.32: the focused file's word segments, read through the diff port, paint their marks", (
      tester,
    ) async {
      HunkLine line(HunkLineKind kind, List<(SegmentKind, String)> runs) => HunkLine(
        kind: kind,
        text: runs.map((run) => run.$2).join(),
        segments: <Segment>[for (final (SegmentKind run, String text) in runs) Segment(kind: run, text: text)],
      );
      details.fileDiffs[_mutable] = <FileDiff>[
        fileDiff(
          'src/a.dart',
          added: 2,
          removed: 1,
          fingerprint: 'fa',
          hunks: <Hunk>[
            hunk(
              before: (start: 1, end: 3),
              after: (start: 1, end: 4),
              lines: <HunkLine>[
                line(HunkLineKind.context, <(SegmentKind, String)>[(SegmentKind.equal, 'keep\n')]),
                line(HunkLineKind.removed, <(SegmentKind, String)>[
                  (SegmentKind.removed, 'old'),
                  (SegmentKind.equal, ' a\n'),
                ]),
                line(HunkLineKind.added, <(SegmentKind, String)>[
                  (SegmentKind.added, 'new'),
                  (SegmentKind.equal, ' a\n'),
                ]),
                line(HunkLineKind.added, <(SegmentKind, String)>[(SegmentKind.added, 'new b\n')]),
              ],
            ),
          ],
        ),
        details.fileDiffs[_mutable]![1],
      ];
      await pump(tester);
      await settle(tester);
      expect(inspector.focusedPath, 'src/a.dart');
      expect(find.text('new b'), findsOneWidget, reason: 'an inserted line, unmarked');
      expect(
        paintedWordMarks(tester, ZsColors.of(tester.element(find.byType(DiffWordMarks).first))),
        <String, List<String>>{
          'old a': <String>['-old'],
          'new a': <String>['+new'],
        },
      );
      await unmount(tester);
    });

    testWidgets('a click on another file reads only that file', (tester) async {
      await pump(tester);
      await settle(tester);
      await tester.tap(_fileRow('src/new.dart'));
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
      expect(settings.projectStates.of('/r/a')!.value.viewedFiles, <String>['$_mutable:fa:src/a.dart']);
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
      expect(settings.projectStates.of('/r/a')!.value.viewedFiles, isEmpty);
      await unmount(tester);
    });

    testWidgets('a reload keeps Viewed for the same fingerprint and the focus; a changed one resets it', (
      tester,
    ) async {
      await pump(tester);
      await settle(tester);
      await tester.tap(_fileRow('src/new.dart'));
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

    group('Story 10.37: a read drops the change\'s marks it no longer shows', () {
      const stale = <String>[
        '$_mutable:fa:src/a.dart',
        '$_mutable:00:src/a.dart',
        '$_mutable:fb:src/gone.dart',
        'kkkkkkkkkkkk:ff:x',
      ];
      List<String> stored() => settings.projectStates.of('/r/a')!.value.viewedFiles;

      testWidgets('an old fingerprint and an unlisted file go; other changes and current marks stay', (tester) async {
        unawaited(settings.projectStates.of('/r/a')!.update((s) => s.copyWith(viewedFiles: stale)));
        await pump(tester);
        await settle(tester);
        expect(stored(), <String>['$_mutable:fa:src/a.dart', 'kkkkkkkkkkkk:ff:x']);
        expect(inspector.isViewed('src/a.dart'), isTrue);
        await unmount(tester);
      });

      testWidgets('a refused summary drops nothing', (tester) async {
        details.refuseSummary = const ZanshinFfiException('jj.internal', 'no');
        unawaited(settings.projectStates.of('/r/a')!.update((s) => s.copyWith(viewedFiles: stale)));
        await pump(tester);
        await settle(tester);
        expect(stored(), stale);
        await unmount(tester);
      });

      testWidgets('a node keyed by its commit id (hidden, divergent) drops nothing', (tester) async {
        source.respond = (_) => _layout(
          'op${ops++}',
          changeIds: <String>[
            for (final String key in _keys)
              if (key == _mutable) 'dddddddddddd' else key,
          ],
        );
        const divergent = <String>['dddddddddddd:00:src/a.dart'];
        unawaited(settings.projectStates.of('/r/a')!.update((s) => s.copyWith(viewedFiles: divergent)));
        await pump(tester);
        await settle(tester);
        expect(stored(), divergent);
        await unmount(tester);
      });
    });

    testWidgets('a reload without the focused path focuses the first file', (tester) async {
      await pump(tester);
      await settle(tester);
      await tester.tap(_fileRow('src/new.dart'));
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

    testWidgets('Viewed follows another writer of the repository\'s view state; another one\'s notifies nothing', (
      tester,
    ) async {
      await pump(tester);
      await settle(tester);
      var notified = 0;
      void count() => notified++;
      inspector.addListener(count);
      void writeViewed(String repo, List<String> keys) =>
          unawaited(settings.projectStates.of(repo)!.update((s) => s.copyWith(viewedFiles: keys)));
      writeViewed('/r/a', <String>['$_mutable:fa:src/a.dart']);
      await tester.pump();
      expect(inspector.isViewed('src/a.dart'), isTrue);
      expect(notified, 1);
      expect(find.text('1/2 viewed'), findsOneWidget);
      // Another repository's marks changed, this one's did not: no notification.
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

    testWidgets('Changed words: flipping general.diffWordMarks repaints the open diff and calls diff zero times', (
      tester,
    ) async {
      details.fileDiffs[_mutable] = <FileDiff>[
        fileDiff(
          'src/a.dart',
          added: 1,
          removed: 1,
          fingerprint: 'fa',
          hunks: <Hunk>[
            hunk(
              before: (start: 0, end: 1),
              after: (start: 0, end: 1),
              lines: const <HunkLine>[
                HunkLine(
                  kind: HunkLineKind.changed,
                  text: 'oldnew a\n',
                  segments: <Segment>[
                    Segment(kind: SegmentKind.removed, text: 'old'),
                    Segment(kind: SegmentKind.added, text: 'new'),
                    Segment(kind: SegmentKind.equal, text: ' a\n'),
                  ],
                ),
              ],
            ),
          ],
        ),
        details.fileDiffs[_mutable]![1],
      ];
      await pump(tester);
      await settle(tester);
      final int reads = details.diffs.length;
      expect(inspector.wordMarks, isTrue, reason: 'on by default');
      expect(tester.widget<InspectorDiffView>(find.byType(InspectorDiffView)).wordMarks, isTrue);
      expect(find.byType(DiffWordMarks), findsOneWidget);
      Future<void> flip(bool on) async {
        unawaited(
          settings
              .update((s) => s.copyWith(general: s.general.copyWith(diffWordMarks: on)))
              .onError<FileSystemException>((_, _) {}),
        );
        await tester.pump();
        await tester.pump();
      }

      await flip(false);
      expect(inspector.wordMarks, isFalse);
      expect(tester.widget<InspectorDiffView>(find.byType(InspectorDiffView)).wordMarks, isFalse);
      expect(find.byType(DiffWordMarks), findsNothing, reason: 'repainted without fills');
      expect(find.text('oldnew a', findRichText: true), findsOneWidget, reason: 'the loaded diff stays');
      expect(inspector.focusedPath, 'src/a.dart');
      await flip(true);
      expect(find.byType(DiffWordMarks), findsOneWidget);
      expect(details.diffs, hasLength(reads), reason: 'the switch reloads nothing');
      await unmount(tester);
    });

    testWidgets('a jj config write reloads the focused diff once, the diff staying meanwhile (Story 5.12)', (
      tester,
    ) async {
      await pump(tester);
      await settle(tester);
      expect(details.focusReads, hasLength(1));
      inspector.configChanged();
      await tester.pump();
      expect(find.byType(InspectorDiffView), findsOneWidget, reason: 'the old diff stays while it loads');
      await tester.pump();
      expect(details.focusReads, hasLength(2));
      expect(details.focusReads.last.$2, <String>['src/a.dart'], reason: 'the focused path stays');
      expect(inspector.focusedDiff, isNotNull);
      await unmount(tester);
    });

    // Story 10.33: the diff options menu.
    Finder optionsMenu() =>
        find.byWidgetPredicate((widget) => widget is ZsMenuButton && widget.identifier == 'inspector-diff-options');
    ZsMenuItem optionsRow(WidgetTester tester, String identifier) => tester
        .widget<ZsMenuButton>(optionsMenu())
        .entries
        .whereType<ZsMenuItem>()
        .singleWhere((item) => item.identifier == identifier);

    testWidgets('Story 10.33: Ignore all whitespace reloads the focused file exact and at -w, the summary stays exact, '
        'the glyph turns accent', (tester) async {
      await pump(tester);
      await settle(tester);
      expect(tester.widget<ZsMenuButton>(optionsMenu()).active, isFalse);
      expect(optionsRow(tester, 'diff-options-whitespace-showAll').checked, isTrue);
      final int reads = details.modes.length;
      final int summaries = details.diffs.where((d) => d.$3).length;
      optionsRow(tester, 'diff-options-whitespace-ignoreAll').onSelected!();
      await settle(tester);
      expect(settings.value.general.diffWhitespace, DiffWhitespaceSetting.ignoreAll);
      expect(inspector.whitespace, DiffWhitespaceSetting.ignoreAll);
      expect(
        details.modes.skip(reads),
        unorderedEquals(<DiffWhitespace>[DiffWhitespace.exact, DiffWhitespace.ignoreAllSpace]),
      );
      expect(details.diffs.where((d) => d.$3), hasLength(summaries), reason: 'the summary is not read again');
      expect(inspector.focusedIgnoring, isNotNull);
      final InspectorDiffView view = tester.widget(find.byType(InspectorDiffView));
      expect(view.whitespace, DiffWhitespaceSetting.ignoreAll);
      expect(view.ignoring, same(inspector.focusedIgnoring));
      expect(tester.widget<ZsMenuButton>(optionsMenu()).active, isTrue);
      expect(optionsRow(tester, 'diff-options-whitespace-ignoreAll').checked, isTrue);

      // Back to show all: one exact read, no ignoring side.
      final int again = details.modes.length;
      inspector.setWhitespace(DiffWhitespaceSetting.showAll);
      await settle(tester);
      expect(details.modes.skip(again), <DiffWhitespace>[DiffWhitespace.exact]);
      expect(inspector.focusedIgnoring, isNull);
      await unmount(tester);
    });

    testWidgets('Story 10.33: a stored -b reads at -b from the first load', (tester) async {
      await tester.runAsync(
        () => settings.update(
          (s) => s.copyWith(general: s.general.copyWith(diffWhitespace: DiffWhitespaceSetting.ignoreChangesInAmount)),
        ),
      );
      await pump(tester);
      await settle(tester);
      expect(details.modes, contains(DiffWhitespace.ignoreSpaceChange));
      expect(optionsRow(tester, 'diff-options-whitespace-ignoreChangesInAmount').checked, isTrue);
      await unmount(tester);
    });

    testWidgets(
      'Story 10.41: a file picked whole without part picks opens its whitespace gaps, without Hide',
      (
        tester,
      ) async {
        // The ignoring read lists no changed line, only one that changed in whitespace.
        details.ignoredDiffs[_mutable] = <FileDiff>[
          const FileDiff(
            path: 'src/a.dart',
            kind: FileChangeKind.modified,
            fromPath: null,
            binary: false,
            modeChange: false,
            sections: <HunkKey>[],
            hunks: <Hunk>[],
            removed: 0,
            added: 0,
            fingerprint: 'w',
            whitespaceLines: <HunkLine>[
              HunkLine(
                kind: HunkLineKind.context,
                text: '  keep\n',
                segments: <Segment>[
                  Segment(kind: SegmentKind.added, text: '  '),
                  Segment(kind: SegmentKind.equal, text: 'keep\n'),
                ],
                left: 2,
                right: 2,
              ),
            ],
          ),
        ];
        await tester.runAsync(
          () => settings.update(
            (s) => s.copyWith(general: s.general.copyWith(diffWhitespace: DiffWhitespaceSetting.ignoreAll)),
          ),
        );
        await pump(tester);
        await settle(tester);
        expect(inspector.hunkable('src/a.dart'), isFalse, reason: 'no sections: it takes no part picks');
        expect(find.text('1 more line with only whitespace changes'), findsOneWidget);
        expect(find.text('  keep'), findsNothing);
        inspector.togglePick('src/a.dart');
        await settle(tester);
        expect(tester.widget<InspectorDiffView>(find.byType(InspectorDiffView)).revealAll, isTrue);
        expect(find.text('1 line with only whitespace changes'), findsOneWidget);
        expect(find.text('  keep'), findsOneWidget, reason: 'the whole pick takes every line, so every line shows');
        expect(find.bySemanticsIdentifier('inspector-gap-hide'), findsNothing);
        await unmount(tester);
      },
    );

    testWidgets('Story 10.33: while a reload is held, the view keeps the previous read\'s ignoring side', (
      tester,
    ) async {
      await tester.runAsync(
        () => settings.update(
          (s) => s.copyWith(general: s.general.copyWith(diffWhitespace: DiffWhitespaceSetting.ignoreAll)),
        ),
      );
      await pump(tester);
      await settle(tester);
      final FileDiff? before = tester.widget<InspectorDiffView>(find.byType(InspectorDiffView)).ignoring;
      expect(before, isNotNull);
      details.holdDiff = true;
      inspector.configChanged();
      await settle(tester);
      expect(details.heldDiffs, hasLength(1));
      expect(inspector.focusedDiff, isNull);
      expect(inspector.previousDiff, isNotNull);
      expect(tester.widget<InspectorDiffView>(find.byType(InspectorDiffView)).ignoring, same(before));
      final (String key, List<String> paths, Completer<Diff> held) = details.heldDiffs.single;
      held.complete(details.diffOf(key, paths: paths));
      await settle(tester);
      expect(inspector.focusedIgnoring, isNotNull);
      await unmount(tester);
    });

    testWidgets('Story 10.33: a refusal of the read at -w is the diff\'s refusal', (tester) async {
      await tester.runAsync(
        () => settings.update(
          (s) => s.copyWith(general: s.general.copyWith(diffWhitespace: DiffWhitespaceSetting.ignoreAll)),
        ),
      );
      details.refuseIgnored = const ZanshinFfiException('jj.jj_lib_error', 'no -w');
      await pump(tester);
      await settle(tester);
      expect(inspector.focusError?.code, 'jj.jj_lib_error');
      expect(inspector.focusedDiff, isNull);
      expect(find.text('no -w'), findsOneWidget);
      await unmount(tester);
    });

    testWidgets('Story 10.33: the menu checks the user config\'s context; a pick writes it and the diff reloads; a '
        'refused write keeps the value', (tester) async {
      details.context = 5;
      await pump(tester);
      await settle(tester);
      expect(inspector.contextLines, 5);
      expect(optionsRow(tester, 'diff-options-context-5').checked, isTrue);
      expect(tester.widget<ZsMenuButton>(optionsMenu()).label, 'Diff options — Show all whitespace, 5 context lines');
      details.afterContextWrite = inspector.configChanged;
      final int reads = details.focusReads.length;
      optionsRow(tester, 'diff-options-context-10').onSelected!();
      await settle(tester);
      expect(details.contextWrites, <int>[10]);
      expect(inspector.contextLines, 10);
      expect(details.focusReads, hasLength(reads + 1), reason: 'the config write reloads the diff');

      details.refuseContextWrite = const ZanshinFfiException('jj.config_error', 'read-only');
      optionsRow(tester, 'diff-options-context-20').onSelected!();
      await settle(tester);
      expect(inspector.contextLines, 10, reason: 'the value kept');
      expect(details.contextWrites, <int>[10]);

      // An off-list value shows in order; an unreadable one checks nothing.
      details.context = 7;
      inspector.configChanged();
      await settle(tester);
      expect(
        tester.widget<ZsMenuButton>(optionsMenu()).entries.whereType<ZsMenuItem>().skip(3).map((item) => item.label),
        <String>['0', '1', '2', '3', '5', '7', '10', '20'],
      );
      details.context = null;
      inspector.configChanged();
      await settle(tester);
      expect(
        tester.widget<ZsMenuButton>(optionsMenu()).entries.whereType<ZsMenuItem>().skip(3).where((i) => i.checked!),
        isEmpty,
      );
      await unmount(tester);
    });

    testWidgets(
      'Story 10.40: a repo-set context is checked with the note that it wins; a pick writes the user config',
      (
        tester,
      ) async {
        details
          ..context = 7
          ..contextFromRepo = true;
        await pump(tester);
        await settle(tester);
        expect(inspector.contextFromRepo, isTrue);
        expect(optionsRow(tester, 'diff-options-context-7').checked, isTrue);
        const note = "Set in this repository's config, which wins";
        expect(
          tester.widget<ZsMenuButton>(optionsMenu()).entries.whereType<ZsMenuNote>().map((n) => n.label),
          contains(note),
        );
        optionsRow(tester, 'diff-options-context-5').onSelected!();
        await settle(tester);
        expect(details.contextWrites, <int>[5]);
        details.contextFromRepo = false;
        inspector.configChanged();
        await settle(tester);
        expect(
          tester.widget<ZsMenuButton>(optionsMenu()).entries.whereType<ZsMenuNote>().map((n) => n.label),
          isNot(contains(note)),
        );
        await unmount(tester);
      },
    );

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
      await tester.tap(_fileRow('src/new.dart'));
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
      await tester.tap(_fileRow('src/new.dart'));
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

    testWidgets('Story 11.23: a title draft typed and deleted, then a commit with a message: the title prefills it', (
      tester,
    ) async {
      await pump(tester, select: _at);
      await openForm(tester);
      await type(tester, 'inspector-summary', 'x');
      await type(tester, 'inspector-summary', '');
      inspector.closeForm(_at);
      await tester.pump();
      expect(inspector.draftOf(_at), (summary: '', details: ''), reason: 'the emptied draft is kept');
      await type(tester, 'inspector-composer-summary', 'Fix');
      details.descriptions[_at] = 'Fix\n';
      await runIt(tester);
      await reload(tester);
      expect(inspector.draftOf(_at), isNull, reason: 'the commit described the change: its title draft goes');
      await openForm(tester);
      expect(tester.widget<EditableText>(field('inspector-summary')).controller.text, 'Fix');
      await unmount(tester);
    });

    testWidgets('Story 11.23: a typed title draft goes when the composer commits with a message', (tester) async {
      await pump(tester, select: _at);
      await openForm(tester);
      await type(tester, 'inspector-summary', 'abc');
      inspector.closeForm(_at);
      await tester.pump();
      await type(tester, 'inspector-composer-summary', 'Fix');
      details.descriptions[_at] = 'Fix\n';
      await runIt(tester);
      await reload(tester);
      expect(inspector.draftOf(_at), isNull, reason: 'a typed draft survives draftOf, so runComposer drops it');
      await openForm(tester);
      expect(tester.widget<EditableText>(field('inspector-summary')).controller.text, 'Fix');
      await unmount(tester);
    });

    testWidgets('commit a subset: only the checked path, the command shows it', (tester) async {
      await pump(tester, select: _at);
      await tap(tester, box('b.txt'));
      expect(checked(tester, 'b.txt'), isFalse);
      expect(checked(tester, 'Select all'), isNull, reason: 'some files checked: mixed (Story 10.26)');
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
      await pump(tester, width: 1000);
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

    testWidgets('Story 10.40: split with everything picked shows only the hint and Cancel, keeps the draft, and runs '
        'nothing; one file less brings the fields back as typed', (tester) async {
      await pump(tester);
      await tap(tester, box('src/a.dart'));
      await type(tester, 'inspector-composer-summary', 'Part');
      await type(tester, 'inspector-composer-details', 'More');
      await tap(tester, box('Select all'));
      expect(inspector.splitsEverything, isTrue);
      expect(
        find.text(
          'Every change is picked — Split needs something left behind. To describe this change, click its title.',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('will become empty'), findsNothing, reason: "the hint replaces jj's note");
      expect(find.descendant(of: composer, matching: find.byType(ZsTextField)), findsNothing);
      expect(_button('inspector-composer-run'), findsNothing);
      expect(find.byKey(const ValueKey<String>('inspector-composer-command')), findsNothing);
      expect(find.byKey(const ValueKey<String>('inspector-composer-result')), findsNothing);
      expect(_button('inspector-composer-cancel'), findsOneWidget);
      expect(await inspector.runComposer(), isNull);
      expect(actions.ran, isEmpty);
      expect(
        (inspector.composerAction! as GraphSplit).paths,
        <String>['src/a.dart', 'src/new.dart', 'src/old.dart'],
        reason: "a rename picked whole takes its source's removal (deferred I1)",
      );

      await tap(tester, box('src/a.dart'));
      expect(inspector.splitsEverything, isFalse);
      expect(tester.widget<ZsButton>(_button('inspector-composer-run')).onPressed, isNotNull);
      expect(find.byKey(const ValueKey<String>('inspector-composer-hint')), findsNothing);
      expect(tester.widget<ZsTextField>(_id('inspector-composer-summary')).controller!.text, 'Part');
      expect(tester.widget<ZsTextField>(_id('inspector-composer-details')).controller!.text, 'More');
      await unmount(tester);
    });

    testWidgets('Story 10.35: a long message is cut inside its quotes; the change id and both paths stay', (
      tester,
    ) async {
      await pump(tester, width: 1000);
      await tap(tester, box('src/new.dart'));
      await type(tester, 'inspector-composer-summary', 'x' * 200);
      final String full = inspector.composerCommand!;
      expect(full, "jj split -r mmmmmmmm -m ${'x' * 200} root:src/new.dart root:src/old.dart");
      final String line = shown(tester);
      expect(line, startsWith("jj split -r mmmmmmmm -m 'x"));
      expect(line, endsWith("…' root:src/new.dart root:src/old.dart"));
      expect(line.length, lessThan(full.length));
      final RenderParagraph paragraph = tester.renderObject<RenderParagraph>(
        find.descendant(
          of: find.byKey(const ValueKey<String>('inspector-composer-command')),
          matching: find.byType(RichText),
        ),
      );
      expect(paragraph.didExceedMaxLines, isFalse, reason: 'the cut line fits without an end ellipsis');
      expect(_tooltipOf(tester, 'inspector-composer-run'), full, reason: 'the tooltip keeps the full command');
      await unmount(tester);
    });

    testWidgets('Story 10.35: an untouched title form on @ closes after a commit once the selection leaves', (
      tester,
    ) async {
      await pump(tester, select: _at);
      await openForm(tester);
      expect(_id('inspector-summary'), findsOneWidget);
      await type(tester, 'inspector-composer-summary', 'Fix');
      details.descriptions[_at] = 'Fix\n';
      await runIt(tester);
      graph.select(_mutable);
      await tester.pump();
      await tester.pump();
      graph.select(_at);
      await tester.pump();
      await tester.pump();
      expect(_id('inspector-summary'), findsNothing);
      expect(_id('inspector-title'), findsOneWidget);
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
      await pump(tester, select: _at, width: 1000);
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

  group('hunk selection (Story 10.26)', () {
    const k1 = HunkKey(oldStart: 0, oldCount: 1, newStart: 0, newCount: 1);
    const k2 = HunkKey(oldStart: 5, oldCount: 0, newStart: 5, newCount: 2);
    const k3 = HunkKey(oldStart: 10, oldCount: 1, newStart: 12, newCount: 0);
    const k4 = HunkKey(oldStart: 2, oldCount: 1, newStart: 2, newCount: 1);

    /// a.txt: three hunks, one section each (k1 ±1/1, k2 +2, k3 −1).
    FileDiff threeHunks(String path, {List<HunkKey> sections = const <HunkKey>[k1, k2, k3]}) => fileDiff(
      path,
      added: 3,
      removed: 2,
      fingerprint: 'f$path',
      sections: sections,
      hunks: <Hunk>[
        hunk(
          before: (start: 0, end: 1),
          after: (start: 0, end: 1),
          sections: const <HunkKey>[k1],
          lines: const <HunkLine>[
            HunkLine(kind: HunkLineKind.removed, text: 'a0\n'),
            HunkLine(kind: HunkLineKind.added, text: 'A0\n'),
          ],
        ),
        hunk(
          before: (start: 5, end: 5),
          after: (start: 5, end: 7),
          sections: const <HunkKey>[k2],
          lines: const <HunkLine>[
            HunkLine(kind: HunkLineKind.added, text: 'n1\n'),
            HunkLine(kind: HunkLineKind.added, text: 'n2\n'),
          ],
        ),
        hunk(
          before: (start: 10, end: 11),
          after: (start: 12, end: 12),
          sections: const <HunkKey>[k3],
          lines: const <HunkLine>[HunkLine(kind: HunkLineKind.removed, text: 'gone\n')],
        ),
      ],
    );

    setUp(() {
      details.files[_at] = const <FileChange>[
        FileChange(path: 'a.txt', kind: FileChangeKind.modified),
        FileChange(path: 'b.sh', kind: FileChangeKind.modified),
        FileChange(path: 'd.txt', kind: FileChangeKind.added),
        FileChange(path: 'new.txt', kind: FileChangeKind.renamed, fromPath: 'old.txt'),
      ];
      details.fileDiffs[_at] = <FileDiff>[
        threeHunks('a.txt'),
        fileDiff(
          'b.sh',
          added: 1,
          removed: 1,
          fingerprint: 'fbsh',
          modeChange: true,
          sections: const <HunkKey>[k4],
          hunks: <Hunk>[
            hunk(
              before: (start: 2, end: 3),
              after: (start: 2, end: 3),
              sections: const <HunkKey>[k4],
              lines: const <HunkLine>[
                HunkLine(kind: HunkLineKind.removed, text: 'echo a\n'),
                HunkLine(kind: HunkLineKind.added, text: 'echo b\n'),
              ],
            ),
          ],
        ),
        fileDiff(
          'd.txt',
          kind: FileChangeKind.added,
          added: 2,
          fingerprint: 'fd',
          hunks: <Hunk>[
            hunk(
              before: (start: 0, end: 0),
              after: (start: 0, end: 2),
              lines: const <HunkLine>[
                HunkLine(kind: HunkLineKind.added, text: 'd1\n'),
                HunkLine(kind: HunkLineKind.added, text: 'd2\n'),
              ],
            ),
          ],
        ),
        fileDiff('new.txt', kind: FileChangeKind.renamed, fingerprint: 'fn'),
      ];
      details.descriptions[_at] = '';
      details.files[_mutable] = const <FileChange>[FileChange(path: 'm.txt', kind: FileChangeKind.modified)];
      details.fileDiffs[_mutable] = <FileDiff>[threeHunks('m.txt')];
    });

    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 3; i++) {
        await tester.pump();
      }
      await tester.pump(const Duration(milliseconds: 300));
    }

    Finder checkbox(String identifier) => find.byWidgetPredicate((w) => w is ZsCheckbox && w.identifier == identifier);
    Finder hunkBox(int i) => checkbox('inspector-hunk-check').at(i);
    Finder fileBox(String label) => find.byWidgetPredicate((w) => w is ZsCheckbox && w.label == label);
    bool? state(WidgetTester tester, Finder box) => tester.widget<ZsCheckbox>(box).value;
    bool? selectAll(WidgetTester tester) => state(tester, checkbox('inspector-select-all'));
    String shown(WidgetTester tester) =>
        tester.widget<Text>(find.byKey(const ValueKey<String>('inspector-composer-command'))).data!;
    final Finder composer = find.byKey(const ValueKey<String>('inspector-composer'));

    Future<void> tap(WidgetTester tester, Finder finder) async {
      await tester.ensureVisible(finder);
      await tester.pump();
      await tester.tap(finder);
      await settle(tester);
    }

    Future<void> focusFile(WidgetTester tester, String path) async {
      // The row (the diff bar names the focused path too); the list scrolls on its own.
      await tester.ensureVisible(_fileRow(path));
      await tester.pump();
      await tester.tap(_fileRow(path));
      await settle(tester);
    }

    Future<void> runIt(WidgetTester tester) async {
      await tester.ensureVisible(_button('inspector-composer-run'));
      await tester.tap(_button('inspector-composer-run'));
      await settle(tester);
    }

    Color headerColor(WidgetTester tester, int i) =>
        tester.widget<Container>(find.byKey(const ValueKey<String>('inspector-hunk-header')).at(i)).color!;
    // The unified lines draw the edge on their pinned numbers (Story 10.38): the hunk's first line's.
    Border? edgeOf(WidgetTester tester, int i) =>
        (tester
                        .widget<Container>(
                          find
                              .descendant(
                                of: find.byType(InspectorDiffHunk).at(i),
                                matching: find.byKey(const ValueKey<String>('inspector-line-pin')),
                              )
                              .first,
                        )
                        .foregroundDecoration
                    as BoxDecoration?)
                ?.border
            as Border?;

    // A unified header's band on the opaque pin base (Story 10.40).
    Color pinned(ZsColors colors, Color band) =>
        Color.alphaBlend(band, Color.alphaBlend(colors.codeBg, colors.flBgSolid));

    String filesOf(HunkChoice? hunks) => <String>[
      for (final FileSelection f in hunks!.files)
        '${f.path}:${f.whole ? 'whole' : '${f.mode ? 'mode+' : ''}${f.hunks.map((k) => k.oldStart).join(',')}'}',
    ].join(' ');

    testWidgets('@ opens with every file and hunk checked; the selected look is on every hunk', (tester) async {
      await pump(tester, select: _at);
      await settle(tester);
      expect(inspector.focusedPath, 'a.txt');
      expect(state(tester, fileBox('a.txt')), isTrue);
      expect(selectAll(tester), isTrue);
      expect(hunkBox(0), findsOneWidget);
      expect(checkbox('inspector-hunk-check'), findsNWidgets(3));
      for (var i = 0; i < 3; i++) {
        expect(state(tester, hunkBox(i)), isTrue);
        expect(tester.widget<ZsCheckbox>(hunkBox(i)).tristate, isTrue);
      }
      final ZsColors colors = ZsColors.of(tester.element(composer));
      expect(headerColor(tester, 0), pinned(colors, colors.accentSoftHi));
      expect(edgeOf(tester, 0)!.left, BorderSide(color: colors.accentLine, width: 2));
      await unmount(tester);
    });

    testWidgets('uncheck hunk 2: file and select-all mixed, `-i` in the preview, one tree-arm commit; recheck: '
        'paths arm again', (tester) async {
      await pump(tester, select: _at);
      await settle(tester);
      await tap(tester, hunkBox(1));
      expect(state(tester, hunkBox(1)), isFalse);
      expect(state(tester, hunkBox(0)), isTrue);
      expect(state(tester, fileBox('a.txt')), isNull, reason: 'mixed');
      expect(selectAll(tester), isNull, reason: 'mixed');
      final ZsColors colors = ZsColors.of(tester.element(composer));
      expect(headerColor(tester, 1), pinned(colors, colors.hunkBg), reason: 'an unselected header stays the hunk band');
      expect(edgeOf(tester, 1), isNull);
      expect(headerColor(tester, 0), pinned(colors, colors.accentSoftHi));
      expect(shown(tester), "jj commit -i -m ''");
      // Selected: every file has a pick (a.txt k1+k3: +1 −2, b.sh ±1, d.txt +2); Rest: a.txt's k2 (+2).
      expect(find.descendant(of: composer, matching: find.text('4 files')), findsOneWidget);
      expect(find.descendant(of: composer, matching: find.text('+4')), findsOneWidget);
      expect(find.descendant(of: composer, matching: find.text('−3')), findsOneWidget);
      expect(find.descendant(of: composer, matching: find.text('1 file')), findsOneWidget);
      expect(find.descendant(of: composer, matching: find.text('+2')), findsOneWidget);

      final commit = inspector.composerAction! as GraphCommit;
      expect(commit.paths, isEmpty);
      expect(commit.hunks!.left, <String>['t$_at-'], reason: "the entry's parentTreeIds");
      expect(
        filesOf(commit.hunks),
        'a.txt:0,10 b.sh:whole d.txt:whole new.txt:whole old.txt:whole',
        reason: "keys in section order; a rename whole takes its source's removal",
      );
      expect(commit.command, "jj commit -i -m ''");

      await tap(tester, hunkBox(1));
      expect(state(tester, fileBox('a.txt')), isTrue, reason: 'full again: whole');
      expect(selectAll(tester), isTrue);
      expect(shown(tester), "jj commit -m ''", reason: 'no -i for an all-whole selection');
      expect((inspector.composerAction! as GraphCommit).hunks, isNull);
      await runIt(tester);
      final ran = actions.ran.single as GraphCommit;
      expect(ran.hunks, isNull);
      expect(ran.paths, isEmpty);
      await unmount(tester);
    });

    testWidgets('mode only: unchecking the content hunk keeps the mode → modeAndHunks(b.sh, [])', (tester) async {
      await pump(tester, select: _at);
      await settle(tester);
      await focusFile(tester, 'b.sh');
      expect(inspector.focusedPath, 'b.sh');
      expect(state(tester, checkbox('inspector-mode-check')), isTrue);
      await tap(tester, hunkBox(0));
      expect(state(tester, fileBox('b.sh')), isNull);
      expect(state(tester, checkbox('inspector-mode-check')), isTrue);
      expect(filesOf((inspector.composerAction! as GraphCommit).hunks), contains('b.sh:mode+'));
      final FileSelection bsh = (inspector.composerAction! as GraphCommit).hunks!.files.firstWhere(
        (f) => f.path == 'b.sh',
      );
      expect((bsh.mode, bsh.whole), (true, false));
      expect(bsh.hunks, isEmpty);
      // The mode off too: nothing of the file is left, its pick goes.
      await tap(tester, checkbox('inspector-mode-check'));
      expect(state(tester, fileBox('b.sh')), isFalse);
      expect(inspector.hasPick('b.sh'), isFalse);
      await unmount(tester);
    });

    testWidgets('a whole-only file and an immutable change take no hunk checkboxes', (tester) async {
      await pump(tester, select: _at);
      await settle(tester);
      await focusFile(tester, 'd.txt');
      expect(find.text('d1'), findsOneWidget, reason: 'its hunk shows');
      expect(checkbox('inspector-hunk-check'), findsNothing);
      expect(checkbox('inspector-mode-check'), findsNothing);
      await unmount(tester);

      details.files[_left] = const <FileChange>[FileChange(path: 'm.txt', kind: FileChangeKind.modified)];
      details.fileDiffs[_left] = <FileDiff>[threeHunks('m.txt')];
      await pump(tester, select: _left);
      await settle(tester);
      expect(find.text('gone'), findsOneWidget, reason: 'the diff shows');
      expect(checkbox('inspector-hunk-check'), findsNothing);
      expect(checkbox('inspector-file-check'), findsNothing, reason: 'no file box either');
      expect(checkbox('inspector-select-all'), findsNothing);
      await unmount(tester);
    });

    testWidgets("the dimmed previous file's diff takes no hunk or mode checkboxes", (tester) async {
      await pump(tester, select: _at);
      await settle(tester);
      expect(checkbox('inspector-hunk-check'), findsNWidgets(3));
      details.holdDiff = true;
      await focusFile(tester, 'b.sh');
      expect(inspector.previousDiff, isNotNull);
      expect(checkbox('inspector-hunk-check'), findsNothing);
      expect(checkbox('inspector-mode-check'), findsNothing);
      details.heldDiffs.single.$3.complete(details.diffOf(_at, paths: <String>['b.sh']));
      await settle(tester);
      expect(inspector.previousDiff, isNull);
      expect(checkbox('inspector-mode-check'), findsOneWidget);
      expect(checkbox('inspector-hunk-check'), findsOneWidget);
      await unmount(tester);
    });

    testWidgets('a renamed file with a mode change stays whole-only; a binary one shows its mode row', (tester) async {
      details.files[_at] = <FileChange>[
        ...details.files[_at]!,
        const FileChange(path: 'bin.dat', kind: FileChangeKind.modified),
      ];
      details.fileDiffs[_at] = <FileDiff>[
        for (final FileDiff file in details.fileDiffs[_at]!)
          if (file.path == 'new.txt')
            fileDiff('new.txt', kind: FileChangeKind.renamed, fingerprint: 'fn', modeChange: true)
          else
            file,
        fileDiff('bin.dat', binary: true, modeChange: true, fingerprint: 'fbin'),
      ];
      await pump(tester, select: _at);
      await settle(tester);
      await focusFile(tester, 'new.txt');
      expect(inspector.focusedPath, 'new.txt');
      expect(inspector.hunkable('new.txt'), isFalse);
      expect(checkbox('inspector-mode-check'), findsNothing);
      await focusFile(tester, 'bin.dat');
      expect(find.text('Binary file'), findsOneWidget);
      expect(state(tester, checkbox('inspector-mode-check')), isTrue);
      await tap(tester, checkbox('inspector-mode-check'));
      expect(state(tester, fileBox('bin.dat')), isFalse, reason: 'nothing of it is left picked');
      await unmount(tester);
    });

    testWidgets('a toggle on a diff shown from before a reload adds only keys of the current sections', (
      tester,
    ) async {
      await pump(tester);
      await settle(tester);
      await tap(tester, hunkBox(0));
      // A reload drops k2's section while the shown diff (held) still has it.
      const k5 = HunkKey(oldStart: 20, oldCount: 1, newStart: 20, newCount: 1);
      details
        ..fileDiffs[_mutable] = <FileDiff>[
          threeHunks('m.txt', sections: const <HunkKey>[k1, k3, k5]),
        ]
        ..holdDiff = true;
      await reload(tester);
      await settle(tester);
      await tap(tester, hunkBox(1));
      expect(state(tester, hunkBox(1)), isFalse, reason: 'the stale k2 is not added, so it does not show checked');
      expect(filesOf((inspector.composerAction! as GraphSplit).hunks), 'm.txt:0');
      await unmount(tester);
    });

    testWidgets('another change: one hunk checked shows Split with `-i`; it runs with the tree', (tester) async {
      await pump(tester, width: 1000);
      await settle(tester);
      expect(composer, findsNothing);
      expect(state(tester, hunkBox(0)), isFalse);
      await tap(tester, hunkBox(0));
      expect(state(tester, fileBox('m.txt')), isNull);
      expect(composer, findsOneWidget);
      expect(shown(tester), "jj split -r mmmmmmmm -i -m 'about mmmmmmmmmmmm'");
      expect(find.byKey(const ValueKey<String>('inspector-composer-hint')), findsNothing);
      await runIt(tester);
      final split = actions.ran.single as GraphSplit;
      expect(split.id, _mutable);
      expect(split.paths, isEmpty);
      expect(filesOf(split.hunks), 'm.txt:0');
      expect(split.hunks!.left, <String>['t$_mutable-']);
      expect(split.command, "jj split -r $_mutable -i -m 'about mmmmmmmmmmmm'");
      expect(inspector.pickedCount, 0, reason: 'done clears the picks');
      await unmount(tester);
    });

    testWidgets('a rename picked whole in the paths arm: both paths, in the command too', (tester) async {
      await pump(tester, select: _at);
      await settle(tester);
      await tap(tester, fileBox('d.txt'));
      final commit = inspector.composerAction! as GraphCommit;
      expect(commit.hunks, isNull);
      expect(commit.paths, <String>['a.txt', 'b.sh', 'new.txt', 'old.txt']);
      expect(shown(tester), "jj commit -m '' root:a.txt root:b.sh root:new.txt root:old.txt");
      await unmount(tester);
    });

    testWidgets('the three states: a file toggle from mixed takes it whole, select-all from mixed takes every file '
        'whole, from all clears', (tester) async {
      await pump(tester, select: _at);
      await settle(tester);
      await tap(tester, hunkBox(2));
      expect(state(tester, fileBox('a.txt')), isNull);
      await tap(tester, fileBox('a.txt'));
      expect(state(tester, fileBox('a.txt')), isTrue);
      expect(state(tester, hunkBox(2)), isTrue);
      await tap(tester, fileBox('a.txt'));
      expect(state(tester, fileBox('a.txt')), isFalse);
      expect(state(tester, hunkBox(0)), isFalse);
      expect(selectAll(tester), isNull, reason: 'some files whole, one not');
      await tap(tester, hunkBox(0));
      await tap(tester, checkbox('inspector-select-all'));
      expect(selectAll(tester), isTrue);
      expect(state(tester, fileBox('a.txt')), isTrue);
      await tap(tester, checkbox('inspector-select-all'));
      expect(selectAll(tester), isFalse);
      expect(inspector.pickedCount, 0);
      await unmount(tester);
    });

    testWidgets('Space on a focused hunk checkbox toggles it', (tester) async {
      await pump(tester, select: _at);
      await settle(tester);
      await tester.ensureVisible(hunkBox(1));
      // The box's own focus node: the nearest one above its innermost widget.
      final FocusNode node = Focus.of(
        tester.element(find.descendant(of: hunkBox(1), matching: find.byWidgetPredicate((_) => true)).last),
      );
      expect(node.skipTraversal, isFalse, reason: 'the hunk checkbox is a Tab stop');
      node.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await settle(tester);
      expect(state(tester, hunkBox(1)), isFalse);
      await unmount(tester);
    });

    testWidgets('a reload re-maps a partial pick by key: a kept key stays picked, a dropped one goes', (tester) async {
      await pump(tester);
      await settle(tester);
      await tap(tester, hunkBox(0));
      await tap(tester, hunkBox(1));
      expect(filesOf((inspector.composerAction! as GraphSplit).hunks), 'm.txt:0,5');
      // m.txt was edited elsewhere: k2's section is gone, a new one came.
      const k5 = HunkKey(oldStart: 20, oldCount: 1, newStart: 20, newCount: 1);
      details.fileDiffs[_mutable] = <FileDiff>[
        threeHunks('m.txt', sections: const <HunkKey>[k1, k3, k5]),
      ];
      await reload(tester);
      await settle(tester);
      expect(filesOf((inspector.composerAction! as GraphSplit).hunks), 'm.txt:0', reason: 'k1 stays, k2 went');
      expect(state(tester, fileBox('m.txt')), isNull);
      await unmount(tester);
    });

    testWidgets("a stale refusal shows jj's text; draft and picks stay", (tester) async {
      await pump(tester);
      await settle(tester);
      await tap(tester, hunkBox(0));
      actions.refuse = const ZanshinFfiException('jj.stale_selection', 'The selection was made against another tree');
      await runIt(tester);
      expect(
        tester.widget<Text>(find.byKey(const ValueKey<String>('inspector-composer-error'))).data,
        'The selection was made against another tree',
      );
      expect(state(tester, fileBox('m.txt')), isNull, reason: 'the picks stay');
      expect(state(tester, hunkBox(0)), isTrue);
      await tap(tester, hunkBox(1));
      expect(find.byKey(const ValueKey<String>('inspector-composer-error')), findsNothing, reason: 'an edit clears it');
      await unmount(tester);
    });

    testWidgets('Esc on another change with picks clears them and keeps the panel; the next Esc closes it', (
      tester,
    ) async {
      await pump(tester);
      await settle(tester);
      await tap(tester, hunkBox(0));
      expect(inspector.pickedCount, 1);
      // The keyboard in the inspector: the file list.
      await focusFile(tester, 'm.txt');
      await esc(tester);
      expect(inspector.pickedCount, 0);
      expect(graph.selected, _mutable);
      await esc(tester);
      expect(graph.selected, isNull);
      await unmount(tester);
    });
  });

  group('Squash into parent (Story 10.25)', () {
    testWidgets('two descriptions: the form pre-filled with the combined text; Save sends it as editedDescription', (
      tester,
    ) async {
      details.combined = 'A\n\nB\n';
      await pump(tester);
      await _chooseFromSquashMenu(tester, 'Squash into parent');
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
      await _chooseFromSquashMenu(tester, 'Squash into parent');
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
      await _chooseFromSquashMenu(tester, 'Squash into parent');
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(_id('inspector-summary'), findsOneWidget);
      await esc(tester);
      expect(_id('inspector-summary'), findsNothing);
      expect(graph.selected, _mutable);
      await _chooseFromSquashMenu(tester, 'Squash into parent');
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

  group('Story 10.38: the split, Finder keys, the description, parts', () {
    Finder divider() => find.byType(ZsSplitDivider);
    Axis axis(WidgetTester tester) => tester.widget<ZsSplitDivider>(divider()).axis;

    /// Pumps the same tree as `pump` at [width], so the inspector keeps its state.
    Future<void> resize(WidgetTester tester, double width) async {
      await tester.pumpWidget(
        shellHost(
          ImmutableReasonScope(
            reasons: null,
            child: Align(
              alignment: Alignment.topRight,
              child: SizedBox(
                width: width,
                height: 840,
                child: GraphInspector(model: inspector),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 3; i++) {
        await tester.pump();
      }
    }

    test('the split clamps the files: wide 600 → 220 … 268; a narrow 200 keeps the diff 140, the files 48', () {
      const wide = InspectorSplit(wide: true, extent: 600);
      expect(wide.files(50 / 588), 220, reason: 'the files\' minimum');
      expect(wide.files(1), 600 - 12 - 320, reason: 'the diff keeps 320');
      expect(const InspectorSplit(wide: true, extent: 900).files(.34), closeTo(.34 * 888, 1e-9));
      const tiny = InspectorSplit(wide: false, extent: 200);
      expect(tiny.files(.38), 200 - 12 - 140, reason: 'the diff\'s minimum wins');
      expect(const InspectorSplit(wide: false, extent: 100).files(.38), 0, reason: 'never below 0');
    });

    testWidgets('the layout follows the width with hysteresis: 760 narrow, 790 wide, 760 wide, 730 narrow', (
      tester,
    ) async {
      await pump(tester, width: 760);
      await settle(tester);
      expect(axis(tester), Axis.vertical, reason: 'the first build: wide only from 780');
      await resize(tester, 790);
      expect(axis(tester), Axis.horizontal);
      await resize(tester, 760);
      expect(axis(tester), Axis.horizontal, reason: 'between 740 and 780 the last layout stays');
      await resize(tester, 730);
      expect(axis(tester), Axis.vertical);
      await unmount(tester);
    });

    testWidgets('a dragged divider writes its layout\'s share once, on release; a restart reads it back', (
      tester,
    ) async {
      await pump(tester, width: 900);
      await settle(tester);
      expect(axis(tester), Axis.horizontal);
      final ZsSplitDivider before = tester.widget(divider());
      expect(before.min, 220);
      expect(before.max, before.total - 320);
      final AppSettings stored = settings.value;
      final TestGesture drag = await tester.startGesture(tester.getCenter(divider()), kind: PointerDeviceKind.mouse);
      await drag.moveBy(const Offset(40, 0));
      await tester.pump();
      final double dragged = (before.value + 40).roundToDouble();
      expect(tester.widget<ZsSplitDivider>(divider()).value, dragged, reason: 'it follows the pointer');
      expect(settings.value, stored, reason: 'nothing is written per move');
      await drag.up();
      await tester.pump(const Duration(milliseconds: 500));
      final double share = dragged / before.total;
      expect(settings.value.layout.inspectorFilesWide, closeTo(share, 1e-9));
      expect(settings.value.layout.inspectorFilesNarrow, 0.38, reason: 'the other layout keeps its share');
      await unmount(tester);
      await settleSettingsWrites(tester, settings);
      final SettingsStore restarted = (await tester.runAsync(
        () => SettingsStore.load(File('${dir.path}/settings.json')),
      ))!;
      final second = InspectorViewModel(
        graph: GraphViewModel(),
        details: _Details(),
        viewed: ProjectViewedStore(restarted, '/r/a'),
        settings: restarted,
      );
      expect(second.filesShare(wide: true), closeTo(share, 1e-9));
      expect(second.filesShare(wide: false), 0.38);
      second
        ..graph.dispose()
        ..dispose();
    });

    testWidgets('the split follows another settings writer', (tester) async {
      await pump(tester, width: 900);
      await settle(tester);
      final double total = tester.widget<ZsSplitDivider>(divider()).total;
      // The value changes at once; the write itself settles at teardown (it cannot finish in the fake zone).
      unawaited(settings.update((s) => s.copyWith(layout: s.layout.copyWith(inspectorFilesWide: .5))));
      await settle(tester);
      expect(tester.widget<ZsSplitDivider>(divider()).value, closeTo(.5 * total, 1e-9));
      await unmount(tester);
    });

    testWidgets('a double-click on the divider writes the layout\'s default share: .34 wide, .38 narrow', (
      tester,
    ) async {
      for (final (double width, bool wide, double share) in const <(double, bool, double)>[
        (900, true, .34),
        (460, false, .38),
      ]) {
        unawaited(
          settings.update(
            (s) => s.copyWith(layout: s.layout.copyWith(inspectorFilesWide: .5, inspectorFilesNarrow: .5)),
          ),
        );
        await pump(tester, width: width);
        await settle(tester);
        expect(axis(tester), wide ? Axis.horizontal : Axis.vertical);
        await tester.tap(divider());
        await tester.pump(const Duration(milliseconds: 50));
        await tester.tap(divider());
        await settle(tester);
        final LayoutSettings layout = settings.value.layout;
        expect(wide ? layout.inspectorFilesWide : layout.inspectorFilesNarrow, closeTo(share, 1e-9));
        expect(wide ? layout.inspectorFilesNarrow : layout.inspectorFilesWide, .5, reason: 'the other layout stays');
        await tester.pump(const Duration(milliseconds: 500));
        await unmount(tester);
      }
    });

    testWidgets(
      'a long description shows 3 lines and Show more; open shows all and Show less; a new selection closes it',
      (
        tester,
      ) async {
        final String body = <String>[for (var i = 1; i <= 10; i++) 'line $i'].join('\n');
        details.descriptions[_mutable] = 'Subject\n\n$body\n';
        details.descriptions[_left] = 'Other\n\n$body\n';
        await pump(tester);
        await settle(tester);
        Text text() => tester.widget<Text>(find.text(body));
        expect(text().maxLines, 3);
        expect(find.text('Show more'), findsOneWidget);
        await tester.tap(find.text('Show more'));
        await tester.pump();
        expect(text().maxLines, isNull);
        expect(find.text('Show less'), findsOneWidget);
        expect(inspector.isOpen(_mutable), isFalse, reason: 'the button does not open the describe form');
        graph.select(_left);
        await settle(tester);
        expect(text().maxLines, 3, reason: 'another selection starts closed');
        expect(find.text('Show more'), findsOneWidget);
        details.descriptions[_mutable] = 'Subject\n\nshort\n';
        graph.select(_mutable);
        await settle(tester);
        expect(find.text('short'), findsOneWidget);
        expect(find.text('Show more'), findsNothing, reason: 'a short body has no button');
        await unmount(tester);
      },
    );

    /// 40 files f0.txt … f39.txt on the mutable change.
    void fortyFiles() {
      details
        ..files[_mutable] = <FileChange>[
          for (var i = 0; i < 40; i++) FileChange(path: 'f$i.txt', kind: FileChangeKind.modified),
        ]
        ..fileDiffs[_mutable] = <FileDiff>[
          for (var i = 0; i < 40; i++)
            fileDiff(
              'f$i.txt',
              added: 1,
              fingerprint: 'f$i',
              hunks: <Hunk>[
                hunk(
                  before: (start: 0, end: 0),
                  after: (start: 0, end: 1),
                  lines: <HunkLine>[HunkLine(kind: HunkLineKind.added, text: 'body $i\n', right: 1)],
                ),
              ],
            ),
        ];
    }

    Future<void> focusList(WidgetTester tester) async {
      await tester.tap(find.text('f0.txt').first);
      await settle(tester);
    }

    testWidgets('↓ ×20 in a 40-file list: row 21 is current, in view, and its diff shows', (tester) async {
      fortyFiles();
      await pump(tester);
      await settle(tester);
      await focusList(tester);
      for (var i = 0; i < 20; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump();
      }
      await settle(tester);
      expect(inspector.focusedPath, 'f20.txt');
      expect(find.text('body 20'), findsOneWidget, reason: 'its diff shows');
      final Finder row = find.text('f20.txt').first;
      final Rect list = tester.getRect(find.ancestor(of: row, matching: find.byType(Scrollable)).first);
      final Rect rect = tester.getRect(row);
      expect(rect.top >= list.top - 0.5 && rect.bottom <= list.bottom + 0.5, isTrue, reason: '$rect in $list');
      expect(tester.getRect(find.byKey(const ValueKey<String>('inspector-diff'))).top, lessThan(840));
      // The current row carries the 1.5 px accent ring while the list has focus, and only then.
      Border? ringOf(String path) {
        final Finder container = find
            .descendant(
              of: find.ancestor(of: find.text(path).first, matching: find.byType(InspectorFileRow)),
              matching: find.byType(Container),
            )
            .first;
        return (tester.widget<Container>(container).foregroundDecoration! as BoxDecoration).border as Border?;
      }

      final ZsColors colors = ZsColors.of(tester.element(row));
      expect(ringOf('f20.txt'), Border.all(color: colors.accent, width: 1.5));
      expect(ringOf('f19.txt'), isNull);
      FocusManager.instance.primaryFocus?.unfocus();
      await settle(tester);
      expect(ringOf('f20.txt'), isNull, reason: 'no ring once the list loses focus');
      await unmount(tester);
    });

    testWidgets('a row keeps its own state when the current row moves (one key per file, not per current row)', (
      tester,
    ) async {
      await pump(tester);
      await settle(tester);
      Element rowOf(String path) => tester.element(_fileRow(path));
      await tester.tap(_fileRow('src/a.dart'));
      await settle(tester);
      final Element a = rowOf('src/a.dart');
      const renamed = 'src/new.dart';
      final Element next = rowOf(renamed);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await settle(tester);
      expect(inspector.focusedPath, 'src/new.dart');
      expect(identical(rowOf('src/a.dart'), a), isTrue, reason: 'the old current row keeps its element');
      expect(identical(rowOf(renamed), next), isTrue, reason: 'the new current row keeps its element');
      await unmount(tester);
    });

    testWidgets('a new file starts its diff at the top and the left; another change starts its list at the top', (
      tester,
    ) async {
      FileDiff long(String path) => fileDiff(
        path,
        added: 80,
        fingerprint: path,
        hunks: <Hunk>[
          hunk(
            before: (start: 0, end: 0),
            after: (start: 0, end: 80),
            lines: <HunkLine>[
              for (var i = 0; i < 80; i++)
                HunkLine(kind: HunkLineKind.added, text: '${'x' * 160} $path $i\n', right: i + 1),
            ],
          ),
        ],
      );
      details
        ..files[_mutable] = <FileChange>[
          for (var i = 0; i < 40; i++) FileChange(path: 'f$i.txt', kind: FileChangeKind.modified),
        ]
        ..fileDiffs[_mutable] = <FileDiff>[for (var i = 0; i < 40; i++) long('f$i.txt')]
        ..files[_left] = const <FileChange>[FileChange(path: 'f1.txt', kind: FileChangeKind.modified)]
        ..fileDiffs[_left] = <FileDiff>[long('f1.txt')];
      await pump(tester, width: 1000);
      await settle(tester);
      await tester.tap(find.text('f1.txt').first);
      await settle(tester);
      List<ScrollPosition> diffScrolls() => tester
          .stateList<ScrollableState>(
            find.descendant(of: find.byType(InspectorDiffView), matching: find.byType(Scrollable)),
          )
          .map((s) => s.position)
          .toList();
      Future<void> scrollDiff() async {
        for (final ScrollPosition p in diffScrolls()) {
          p.jumpTo(p.maxScrollExtent);
        }
        await tester.pump();
        expect(diffScrolls().where((p) => p.pixels > 0), hasLength(2), reason: 'down and right');
      }

      await scrollDiff();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await settle(tester);
      expect(inspector.focusedPath, 'f2.txt');
      expect(diffScrolls().map((p) => p.pixels), everyElement(0), reason: 'another file starts at the top left');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await settle(tester);
      expect(inspector.focusedPath, 'f1.txt');
      await scrollDiff();
      final ScrollPosition list = tester
          .state<ScrollableState>(
            find.ancestor(of: find.text('f0.txt').first, matching: find.byType(Scrollable)).first,
          )
          .position;
      list.jumpTo(list.maxScrollExtent);
      await tester.pump();
      expect(list.pixels, greaterThan(0));
      graph.select(_left);
      await settle(tester);
      expect(inspector.focusedPath, 'f1.txt', reason: 'the same path on another change');
      expect(diffScrolls().map((p) => p.pixels), everyElement(0), reason: 'another change starts at the top left');
      expect(
        tester
            .state<ScrollableState>(
              find.ancestor(of: find.text('f1.txt').first, matching: find.byType(Scrollable)).first,
            )
            .position
            .pixels,
        0,
        reason: 'another change\'s list starts at its top',
      );
      await unmount(tester);
    });

    testWidgets('a held key\'s file that goes in a reload during the pause is not read; the row falls back', (
      tester,
    ) async {
      fortyFiles();
      await pump(tester);
      await settle(tester);
      await focusList(tester);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump(const Duration(milliseconds: 10));
      expect(inspector.focusedPath, 'f1.txt');
      details
        ..files[_mutable] = details.files[_mutable]!.where((f) => f.path != 'f3.txt').toList()
        ..fileDiffs[_mutable] = details.fileDiffs[_mutable]!.where((f) => f.path != 'f3.txt').toList();
      await reload(tester);
      final int reads = details.focusReads.length;
      await tester.pump(const Duration(milliseconds: 100));
      await settle(tester);
      expect(inspector.focusedPath, 'f1.txt', reason: 'the gone file is not focused');
      expect(details.focusReads.length, reads, reason: 'and not read');
      final ZsColors colors = ZsColors.of(tester.element(find.text('f1.txt').first));
      expect(tester.widget<Text>(find.text('f1.txt').first).style!.color, colors.text, reason: 'the current row');
      await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowDown);
      await unmount(tester);
    });

    testWidgets('the top part takes at most 48 % of the body and scrolls; the split keeps the rest', (tester) async {
      final String body = <String>[for (var i = 1; i <= 80; i++) 'line $i'].join('\n');
      details.descriptions[_mutable] = 'Subject\n\n$body\n';
      await pump(tester);
      await settle(tester);
      await tester.tap(find.text('Show more'));
      await settle(tester);
      final Finder top = find.byWidgetPredicate((w) => w is ZsScrollArea && w.identifier == 'inspector-body');
      final Rect area = tester.getRect(top);
      final double bottom = tester.getRect(find.byType(GraphInspector)).bottom;
      expect(area.height, lessThanOrEqualTo((bottom - area.top) * .48 + .5));
      final ScrollPosition scroll = tester
          .state<ScrollableState>(find.descendant(of: top, matching: find.byType(Scrollable)).first)
          .position;
      expect(scroll.maxScrollExtent, greaterThan(0), reason: 'the top part scrolls');
      expect(tester.getRect(find.byType(ZsSplitDivider)).bottom, lessThan(bottom), reason: 'the split stays in view');
      await unmount(tester);
    });

    testWidgets('a held ↓: the row moves at once, one diff read for the last row after an 80 ms pause', (
      tester,
    ) async {
      fortyFiles();
      await pump(tester);
      await settle(tester);
      await focusList(tester);
      final int reads = details.focusReads.length;
      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowDown);
      for (var i = 0; i < 5; i++) {
        await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump(const Duration(milliseconds: 10));
      }
      final ZsColors colors = ZsColors.of(tester.element(find.text('f0.txt').first));
      expect(tester.widget<Text>(find.text('f6.txt').first).style!.color, colors.text, reason: 'the current row');
      expect(details.focusReads.length, reads + 1, reason: 'the key down read f1 only');
      expect(inspector.focusedPath, 'f1.txt');
      await tester.pump(const Duration(milliseconds: 100));
      await settle(tester);
      expect(inspector.focusedPath, 'f6.txt');
      expect(details.focusReads.length, reads + 2);
      expect(details.focusReads.last.$2, <String>['f6.txt']);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowDown);
      await unmount(tester);
    });

    testWidgets('Space flips the current file\'s pick, V its Viewed mark; on an immutable change Space does nothing', (
      tester,
    ) async {
      await pump(tester);
      await settle(tester);
      await tester.tap(_fileRow('src/a.dart'));
      await settle(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await settle(tester);
      expect(inspector.focusedPath, 'src/new.dart');
      expect(inspector.fileState('src/new.dart'), isFalse);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(inspector.fileState('src/new.dart'), isTrue);
      expect(inspector.isViewed('src/new.dart'), isFalse);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
      await tester.pump();
      expect(inspector.isViewed('src/new.dart'), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
      await tester.pump();
      expect(inspector.isViewed('src/new.dart'), isFalse);
      // A held Space or V flips once, not per repeat.
      for (final key in <LogicalKeyboardKey>[LogicalKeyboardKey.space, LogicalKeyboardKey.keyV]) {
        await tester.sendKeyDownEvent(key);
        await tester.sendKeyRepeatEvent(key);
        await tester.sendKeyRepeatEvent(key);
        await tester.sendKeyUpEvent(key);
        await tester.pump();
      }
      expect(inspector.fileState('src/new.dart'), isFalse);
      expect(inspector.isViewed('src/new.dart'), isTrue);
      await unmount(tester);

      details
        ..files[_left] = const <FileChange>[FileChange(path: 'l.txt', kind: FileChangeKind.modified)]
        ..fileDiffs[_left] = <FileDiff>[fileDiff('l.txt', fingerprint: 'fl')];
      await pump(tester, select: _left);
      await settle(tester);
      await tester.tap(find.text('l.txt').first);
      await settle(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(inspector.hasPick('l.txt'), isFalse);
      await unmount(tester);
    });

    const s1 = HunkKey(oldStart: 1, oldCount: 1, newStart: 1, newCount: 1);
    const s2 = HunkKey(oldStart: 5, oldCount: 1, newStart: 5, newCount: 1);
    const s3 = HunkKey(oldStart: 9, oldCount: 1, newStart: 9, newCount: 1);
    Finder partBox(int i) =>
        find.byWidgetPredicate((w) => w is ZsCheckbox && w.identifier == 'inspector-part-check').at(i);
    final Finder hunkBox = find.byWidgetPredicate((w) => w is ZsCheckbox && w.identifier == 'inspector-hunk-check');

    /// The mutable change's one file `p.txt`: one hunk of three parts (sections s1, s2, s3).
    void threeParts() {
      HunkLine line(HunkLineKind kind, String text, {int? left, int? right}) =>
          HunkLine(kind: kind, text: '$text\n', left: left, right: right);
      details
        ..files[_mutable] = const <FileChange>[FileChange(path: 'p.txt', kind: FileChangeKind.modified)]
        ..fileDiffs[_mutable] = <FileDiff>[
          fileDiff(
            'p.txt',
            added: 3,
            removed: 3,
            fingerprint: 'fp',
            sections: const <HunkKey>[s1, s2, s3],
            hunks: <Hunk>[
              hunk(
                before: (start: 0, end: 11),
                after: (start: 0, end: 11),
                sections: const <HunkKey>[s1, s2, s3],
                lines: <HunkLine>[
                  line(HunkLineKind.context, 'c1', left: 1, right: 1),
                  line(HunkLineKind.removed, 'old 2', left: 2),
                  line(HunkLineKind.added, 'new 2', right: 2),
                  line(HunkLineKind.context, 'c3', left: 3, right: 3),
                  line(HunkLineKind.removed, 'old 6', left: 6),
                  line(HunkLineKind.added, 'new 6', right: 6),
                  line(HunkLineKind.context, 'c7', left: 7, right: 7),
                  line(HunkLineKind.removed, 'old 10', left: 10),
                  line(HunkLineKind.added, 'new 10', right: 10),
                ],
              ),
            ],
          ),
        ];
    }

    testWidgets(
      'a file picked whole shows every part checked; toggling one leaves the others checked, the hunk mixed',
      (
        tester,
      ) async {
        threeParts();
        await pump(tester, width: 1000);
        await settle(tester);
        inspector.togglePick('p.txt');
        await settle(tester);
        expect(
          <bool?>[for (var i = 0; i < 3; i++) tester.widget<ZsCheckbox>(partBox(i)).value],
          <bool?>[
            true,
            true,
            true,
          ],
        );
        expect(tester.widget<ZsCheckbox>(hunkBox).value, isTrue);
        await tester.ensureVisible(partBox(0));
        await tester.pump();
        await tester.tap(partBox(0));
        await settle(tester);
        expect(
          <bool?>[for (var i = 0; i < 3; i++) tester.widget<ZsCheckbox>(partBox(i)).value],
          <bool?>[
            false,
            true,
            true,
          ],
        );
        expect(tester.widget<ZsCheckbox>(hunkBox).value, isNull, reason: 'mixed');
        expect(tester.widget<ZsCheckbox>(partBox(0)).label, 'Pick line 2', reason: 'the part names its lines');
        await unmount(tester);
      },
    );

    testWidgets('a hunk of three parts: the second part alone selects only its section; the hunk shows mixed', (
      tester,
    ) async {
      threeParts();
      await pump(tester, width: 1000);
      await settle(tester);
      expect(
        find.byWidgetPredicate((w) => w is ZsCheckbox && w.identifier == 'inspector-part-check'),
        findsNWidgets(3),
      );
      expect(find.text('3 parts'), findsOneWidget);
      await tester.ensureVisible(partBox(1));
      await tester.pump();
      await tester.tap(partBox(1));
      await settle(tester);
      expect(tester.widget<ZsCheckbox>(partBox(1)).value, isTrue);
      expect(tester.widget<ZsCheckbox>(partBox(0)).value, isFalse);
      expect(tester.widget<ZsCheckbox>(hunkBox).value, isNull, reason: 'mixed');
      final split = inspector.composerAction! as GraphSplit;
      expect(split.hunks!.files.single.hunks, <HunkKey>[s2]);
      // The edge marks only the second part's lines.
      bool edged(String text) =>
          (tester
                      .widget<Container>(
                        find
                            .descendant(
                              of: find.ancestor(of: find.text(text), matching: find.byType(Stack)).first,
                              matching: find.byKey(const ValueKey<String>('inspector-line-pin')),
                            )
                            .first,
                      )
                      .foregroundDecoration!
                  as BoxDecoration)
              .border !=
          null;
      expect(
        <bool>[
          for (final t in <String>['old 2', 'new 2', 'c3', 'old 6', 'new 6', 'c7', 'old 10']) edged(t),
        ],
        <bool>[
          false,
          false,
          false,
          true,
          true,
          false,
          false,
        ],
      );
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

  test('Story 10.33: the whitespace mode persists in the settings file and opens from it after a restart', () async {
    final model = GraphViewModel();
    final first = InspectorViewModel(
      graph: model,
      details: _Details(),
      viewed: ProjectViewedStore(settings, '/r/a'),
      settings: settings,
    )..setWhitespace(DiffWhitespaceSetting.ignoreAll);
    // Writes run in order: awaiting a later one awaits the mode's.
    await settings.update((s) => s.copyWith(general: s.general.copyWith(hideControls: false)));
    final SettingsStore restarted = await SettingsStore.load(File('${dir.path}/settings.json'));
    final second = InspectorViewModel(
      graph: model,
      details: _Details(),
      viewed: ProjectViewedStore(restarted, '/r/a'),
      settings: restarted,
    );
    expect(second.whitespace, DiffWhitespaceSetting.ignoreAll);
    first.dispose();
    second.dispose();
    model.dispose();
  });

  test('ProjectViewedStore: a path outside the registry keeps its marks in memory; the newest 2000 stay', () {
    addTearDown(() => settings.settled);
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

  test('Story 10.37: a Viewed mark writes the project\'s state file, never settings.json', () async {
    final store = ProjectViewedStore(settings, '/r/a');
    // The first open gives the entry its state id: that is the one settings write.
    expect(store.load(), isEmpty);
    await Future<void>.delayed(Duration.zero);
    await settings.settled;
    final file = File('${dir.path}/settings.json');
    final String before = file.readAsStringSync();
    final String id = settings.value.projects.projects.first.stateId!;
    store.save(<String>{'k1', 'k2'});
    await settings.settled;
    expect(file.readAsStringSync(), before);
    expect(
      ProjectState.fromJson(
        jsonDecode(File('${dir.path}/projects/$id.json').readAsStringSync()) as Map<String, Object?>,
      ).viewedFiles,
      <String>['k1', 'k2'],
    );
  });

  group('Story 10.39: name-first rows, tree or flat, copy, Reveal, Open in Editor', () {
    late Directory work;
    late String root;
    late String bin;
    late ShellToasts toasts;
    // Each start as the program followed by its arguments.
    late List<List<String>> started;
    late List<String> copied;

    setUp(() {
      work = Directory.systemTemp.createTempSync('zanshin_files');
      root = '${work.path}/repo';
      bin = '${work.path}/bin';
      Directory('$root/src').createSync(recursive: true);
      File('$root/src/a.dart').writeAsStringSync('a');
      Directory(bin).createSync();
      final idea = File('$bin/idea')..writeAsStringSync('#!/bin/sh\nexit 1\n');
      Process.runSync('chmod', <String>['+x', idea.path]);
      toasts = ShellToasts();
      started = <List<String>>[];
      copied = <String>[];
    });

    tearDown(() {
      toasts.dispose();
      work.deleteSync(recursive: true);
    });

    ProjectFiles files() => ProjectFiles(
      root: root,
      settings: settings,
      toasts: toasts,
      environment: () => <String, String>{'PATH': bin},
      start: (executable, arguments, environment) async => started.add(<String>[executable, ...arguments]),
    );

    /// Records clipboard writes in [copied] until the test ends.
    void recordClipboard(WidgetTester tester) {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map<Object?, Object?>)['text']! as String);
        }
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    }

    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 3; i++) {
        await tester.pump();
      }
      await tester.pump(const Duration(milliseconds: 300));
    }

    /// Right-clicks [finder] and lets the menu come in.
    Future<void> rightClick(WidgetTester tester, Finder finder) async {
      await tester.tap(finder, buttons: kSecondaryButton);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
    }

    /// Chooses the open menu's row labelled [label]; it runs after the row's blink.
    Future<void> choose(WidgetTester tester, String label) async {
      await tester.tap(find.text(label));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
    }

    ZsMenuItem item(WidgetTester tester, String identifier) => tester
        .widgetList<ZsMenuAnchor>(find.byType(ZsMenuAnchor))
        .expand((anchor) => anchor.entries)
        .whereType<ZsMenuItem>()
        .firstWhere((item) => item.identifier == identifier);

    testWidgets('a long path at 460 points keeps the whole name; the folder is cut in its head', (tester) async {
      const long = 'packages/logic_designer/lib/src/presentation/widgets/automation_overview_page.dart';
      details.files[_left] = const <FileChange>[FileChange(path: long, kind: FileChangeKind.modified)];
      await pump(tester, select: _left);
      await settle(tester);
      RenderParagraph paragraph(String text) =>
          tester.renderObject<RenderParagraph>(find.descendant(of: _fileRow(long), matching: find.text(text)));
      final RenderParagraph name = paragraph('automation_overview_page.dart');
      expect(name.size.width, name.getMaxIntrinsicWidth(double.infinity), reason: 'the name whole');
      expect(name.didExceedMaxLines, isFalse);
      final RenderParagraph head = paragraph('packages/logic_designer/lib/src/presentation/');
      expect(head.size.width, lessThan(head.getMaxIntrinsicWidth(double.infinity)), reason: 'the head gives way');
      await unmount(tester);
    });

    testWidgets('the Changes header switches to the tree; after a restart the list is a tree of the same files', (
      tester,
    ) async {
      details.files[_mutable] = const <FileChange>[
        FileChange(path: 'src/a.dart', kind: FileChangeKind.modified),
        FileChange(path: 'src/new.dart', kind: FileChangeKind.renamed, fromPath: 'src/old.dart'),
        FileChange(path: 'top.txt', kind: FileChangeKind.added),
      ];
      await pump(tester);
      await settle(tester);
      expect(find.byKey(const ValueKey<String>('inspector-folder src')), findsNothing, reason: 'flat by default');
      await tester.tap(find.bySemanticsLabel('Tree'));
      await settle(tester);
      expect(settings.value.general.diffFileList, DiffFileListSetting.tree);
      expect(find.byKey(const ValueKey<String>('inspector-folder src')), findsOneWidget);
      await unmount(tester);
      await settleSettingsWrites(tester, settings);

      // A new store on the same file: the app's restart.
      settings = (await tester.runAsync(() => SettingsStore.load(File('${dir.path}/settings.json'))))!;
      await pump(tester);
      await settle(tester);
      expect(inspector.fileList, DiffFileListSetting.tree);
      expect(find.byKey(const ValueKey<String>('inspector-folder src')), findsOneWidget);
      for (final path in <String>['src/a.dart', 'src/new.dart', 'top.txt']) {
        expect(_fileRow(path), findsOneWidget, reason: path);
        expect(tester.widget<InspectorFileRow>(_fileRow(path)).tree, isTrue);
      }
      await unmount(tester);
    });

    testWidgets('tree keys: ← goes to the folder, ← again collapses, → expands; a folder picks its files', (
      tester,
    ) async {
      unawaited(settings.update((s) => s.copyWith.general(diffFileList: DiffFileListSetting.tree)));
      details.files[_mutable] = const <FileChange>[
        FileChange(path: 'src/a.dart', kind: FileChangeKind.modified),
        FileChange(path: 'src/b.dart', kind: FileChangeKind.modified),
        FileChange(path: 'src/c.dart', kind: FileChangeKind.modified),
      ];
      // Viewed needs each file's summary fingerprint.
      details.fileDiffs[_mutable] = <FileDiff>[
        for (final String name in <String>['a', 'b', 'c']) fileDiff('src/$name.dart', added: 1, fingerprint: 'f$name'),
      ];
      await pump(tester);
      await settle(tester);
      final Finder folder = find.byKey(const ValueKey<String>('inspector-folder src'));
      expect(tester.widget<InspectorFolderRow>(folder).added, 3, reason: "the files' summed ±");
      InspectorFolderRow row() => tester.widget<InspectorFolderRow>(folder);
      expect(row().folder.files, hasLength(3));
      // Mixed with one of three picked; a click picks all, the next none.
      inspector.togglePick('src/b.dart');
      await tester.pump();
      expect(row().picked, isNull);
      await tester.tap(find.descendant(of: folder, matching: find.byType(ZsCheckbox)));
      await tester.pump();
      expect(
        <bool?>[
          for (final p in <String>['src/a.dart', 'src/b.dart', 'src/c.dart']) inspector.fileState(p),
        ],
        <bool?>[
          true,
          true,
          true,
        ],
      );
      await tester.tap(find.descendant(of: folder, matching: find.byType(ZsCheckbox)));
      await tester.pump();
      expect(row().picked, isFalse);

      await tester.tap(_fileRow('src/b.dart'));
      await settle(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await settle(tester);
      expect(row().current, isTrue, reason: '← on a file: its folder is current');
      expect(inspector.focusedPath, 'src/b.dart', reason: 'a folder only becomes current');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await settle(tester);
      expect(inspector.collapsed, <String>{'src'});
      expect(_fileRow('src/a.dart'), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await settle(tester);
      expect(inspector.collapsed, isEmpty);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await settle(tester);
      expect(inspector.focusedPath, 'src/a.dart', reason: '→ on an open folder: its first child');
      // Space on the folder picks all of it; V marks all Viewed; ↩ toggles it.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await settle(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(inspector.picksState(<String>['src/a.dart', 'src/b.dart', 'src/c.dart']), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
      await tester.pump();
      expect(inspector.viewedCount, 3);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await settle(tester);
      expect(inspector.collapsed, <String>{'src'});
      await unmount(tester);
    });

    testWidgets('⌘C and the row menu copy paths; Open in IntelliJ IDEA and Reveal run on the absolute path', (
      tester,
    ) async {
      recordClipboard(tester);
      unawaited(settings.update((s) => s.copyWith.general(editor: 'idea')));
      await pump(tester, files: files());
      await settle(tester);
      await tester.tap(_fileRow('src/a.dart'));
      await settle(tester);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pump();
      expect(copied, <String>['$root/src/a.dart']);

      await rightClick(tester, _fileRow('src/a.dart'));
      expect(item(tester, 'files-open').label, 'Open in IntelliJ IDEA');
      expect(item(tester, 'files-open').cmd, 'idea');
      expect(item(tester, 'files-copy-path').shortcut, '⌘C');
      expect(
        find.text("Opens the file on disk — @'s version; a later change may have moved its lines."),
        findsOneWidget,
      );
      await choose(tester, 'Copy relative path');
      expect(copied.last, 'src/a.dart');
      await rightClick(tester, _fileRow('src/a.dart'));
      await choose(tester, 'Copy path');
      expect(copied.last, '$root/src/a.dart');
      await rightClick(tester, _fileRow('src/a.dart'));
      await choose(tester, 'Open in IntelliJ IDEA');
      expect(started.last, <String>['$bin/idea', '$root/src/a.dart']);
      await rightClick(tester, _fileRow('src/a.dart'));
      await choose(tester, 'Reveal in Finder');
      expect(started.last, <String>['/usr/bin/open', '-R', '$root/src/a.dart']);

      // The renamed file is not on disk: Open and Reveal are disabled with the reason.
      await rightClick(tester, _fileRow('src/new.dart'));
      expect(item(tester, 'files-open').enabled, isFalse);
      expect(item(tester, 'files-reveal').tooltip, 'src/new.dart is not in the working copy.');
      expect(inspector.focusedPath, 'src/new.dart', reason: 'a right-click makes the row current');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
      await unmount(tester);
    });

    testWidgets('without an editor the first row reads Choose editor…, disabled outside a window; @ has no note', (
      tester,
    ) async {
      details.files[_at] = const <FileChange>[FileChange(path: 'src/a.dart', kind: FileChangeKind.modified)];
      await pump(tester, select: _at, files: files());
      await settle(tester);
      await rightClick(tester, _fileRow('src/a.dart'));
      final ZsMenuItem open = item(tester, 'files-open');
      expect((open.label, open.cmd, open.enabled), ('Choose editor…', 'Settings › General › Editor', false));
      expect(find.textContaining("@'s version"), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
      await unmount(tester);
    });

    testWidgets('a diff line opens at its new line; a removed line copies the next new line', (tester) async {
      recordClipboard(tester);
      unawaited(settings.update((s) => s.copyWith.general(editor: 'idea')));
      details.fileDiffs[_mutable] = <FileDiff>[
        fileDiff(
          'src/a.dart',
          removed: 1,
          fingerprint: 'fa',
          hunks: <Hunk>[
            hunk(
              before: (start: 10, end: 14),
              after: (start: 10, end: 13),
              lines: const <HunkLine>[
                HunkLine(kind: HunkLineKind.context, text: 'eleven\n', left: 11, right: 11),
                HunkLine(kind: HunkLineKind.context, text: 'twelve\n', left: 12, right: 12),
                HunkLine(kind: HunkLineKind.removed, text: 'gone\n', left: 13),
                HunkLine(kind: HunkLineKind.context, text: 'next\n', left: 14, right: 13),
              ],
            ),
          ],
        ),
      ];
      // The file on disk holds line 12 (Story 10.40: a line past its end opens at the start).
      File('$root/src/a.dart').writeAsStringSync(List<String>.generate(50, (i) => 'line ${i + 1}\n').join());
      await pump(tester, files: files());
      await settle(tester);
      await rightClick(tester, find.textContaining('twelve', findRichText: true));
      expect(find.textContaining('is not in the file on disk'), findsNothing);
      await choose(tester, 'Open in IntelliJ IDEA at line 12');
      expect(started.last, <String>['$bin/idea', '--line', '12', '$root/src/a.dart']);
      await rightClick(tester, find.textContaining('gone', findRichText: true));
      expect(find.textContaining("@'s version"), findsOneWidget, reason: 'not @');
      await choose(tester, 'Copy path:line');
      expect(copied.last, '$root/src/a.dart:13');
      expect(diffNewLineAt(details.fileDiffs[_mutable]!.single.hunks.single, 2), 13);
      await unmount(tester);
    });

    /// One hunk of `src/a.dart` at [line], its line reading `forty`.
    List<FileDiff> lineAt(int line) => <FileDiff>[
      fileDiff(
        'src/a.dart',
        added: 1,
        fingerprint: 'fa',
        hunks: <Hunk>[
          hunk(
            before: (start: line - 1, end: line - 1),
            after: (start: line - 1, end: line),
            lines: <HunkLine>[HunkLine(kind: HunkLineKind.added, text: 'forty\n', right: line)],
          ),
        ],
      ),
    ];

    testWidgets('Story 10.40: a line the file on disk lacks opens the file at its start, a note says so', (
      tester,
    ) async {
      unawaited(settings.update((s) => s.copyWith.general(editor: 'idea')));
      File('$root/src/a.dart').writeAsStringSync(List<String>.generate(10, (i) => 'line ${i + 1}\n').join());
      details.fileDiffs[_mutable] = lineAt(40);
      await pump(tester, files: files());
      await settle(tester);
      await rightClick(tester, find.textContaining('forty', findRichText: true));
      expect(item(tester, 'files-open').label, 'Open in IntelliJ IDEA');
      expect(item(tester, 'files-open').cmd, 'idea');
      expect(find.text('Line 40 is not in the file on disk — opens at its start'), findsOneWidget);
      await choose(tester, 'Open in IntelliJ IDEA');
      expect(started.last, <String>['$bin/idea', '$root/src/a.dart']);
      await unmount(tester);
    });

    testWidgets('Story 10.40: the line right after the end (a removed last line) opens at the last line, no note', (
      tester,
    ) async {
      unawaited(settings.update((s) => s.copyWith.general(editor: 'idea')));
      File('$root/src/a.dart').writeAsStringSync(List<String>.generate(10, (i) => 'line ${i + 1}\n').join());
      details.fileDiffs[_mutable] = lineAt(11);
      await pump(tester, files: files());
      await settle(tester);
      await rightClick(tester, find.textContaining('forty', findRichText: true));
      expect(find.textContaining('is not in the file on disk'), findsNothing);
      await choose(tester, 'Open in IntelliJ IDEA at line 10');
      expect(started.last, <String>['$bin/idea', '--line', '10', '$root/src/a.dart']);
      await unmount(tester);
    });

    testWidgets('Story 10.40: a click beside an open menu closes it: on another file row (the current row stays), on '
        'another diff line', (tester) async {
      unawaited(settings.update((s) => s.copyWith.general(editor: 'idea')));
      await pump(tester, files: files());
      await settle(tester);
      // The menu opens down from the lower row, so the row above stays clear of it.
      await rightClick(tester, _fileRow('src/new.dart'));
      expect(find.text('Copy relative path'), findsOneWidget);
      await tester.tap(_fileRow('src/a.dart'));
      await settle(tester);
      expect(find.text('Copy relative path'), findsNothing, reason: 'the menu closed');
      expect(inspector.focusedPath, 'src/new.dart', reason: 'the closing click picks no row');
      await unmount(tester);

      details.fileDiffs[_mutable] = <FileDiff>[
        fileDiff(
          'src/a.dart',
          added: 2,
          fingerprint: 'fa',
          hunks: <Hunk>[
            hunk(
              before: (start: 0, end: 0),
              after: (start: 0, end: 2),
              lines: const <HunkLine>[
                HunkLine(kind: HunkLineKind.added, text: 'first\n', right: 1),
                HunkLine(kind: HunkLineKind.added, text: 'second\n', right: 2),
              ],
            ),
          ],
        ),
      ];
      await pump(tester, files: files());
      await settle(tester);
      await rightClick(tester, find.textContaining('second', findRichText: true));
      expect(find.text('Copy path:line'), findsOneWidget);
      await tester.tap(find.textContaining('first', findRichText: true));
      await settle(tester);
      expect(find.text('Copy path:line'), findsNothing);
      await unmount(tester);
    });

    testWidgets('Story 10.40: a right-click no line answers (the hunk header) throws nothing and opens nothing', (
      tester,
    ) async {
      details.fileDiffs[_mutable] = lineAt(3);
      await pump(tester, files: files());
      await settle(tester);
      await rightClick(tester, find.byKey(const ValueKey<String>('inspector-hunk-header')));
      expect(tester.takeException(), isNull);
      expect(find.text('Copy path:line'), findsNothing);
      await unmount(tester);
    });

    testWidgets('side by side: a removed left cell copies the next new line, a right cell its own', (tester) async {
      recordClipboard(tester);
      unawaited(settings.update((s) => s.copyWith.general(diffLayout: DiffLayoutSetting.sideBySide)));
      details.fileDiffs[_mutable] = <FileDiff>[
        fileDiff(
          'src/a.dart',
          removed: 1,
          fingerprint: 'fa',
          hunks: <Hunk>[
            hunk(
              before: (start: 10, end: 14),
              after: (start: 10, end: 13),
              // Side by side rebuilds each cell from the line's runs.
              lines: const <HunkLine>[
                HunkLine(
                  kind: HunkLineKind.context,
                  text: 'eleven\n',
                  segments: <Segment>[Segment(kind: SegmentKind.equal, text: 'eleven\n')],
                  left: 11,
                  right: 11,
                ),
                HunkLine(
                  kind: HunkLineKind.context,
                  text: 'twelve\n',
                  segments: <Segment>[Segment(kind: SegmentKind.equal, text: 'twelve\n')],
                  left: 12,
                  right: 12,
                ),
                HunkLine(
                  kind: HunkLineKind.removed,
                  text: 'gone\n',
                  segments: <Segment>[Segment(kind: SegmentKind.removed, text: 'gone\n')],
                  left: 13,
                ),
                HunkLine(
                  kind: HunkLineKind.context,
                  text: 'next\n',
                  segments: <Segment>[Segment(kind: SegmentKind.equal, text: 'next\n')],
                  left: 14,
                  right: 13,
                ),
              ],
            ),
          ],
        ),
      ];
      await pump(tester, files: files());
      await settle(tester);
      expect(find.byKey(const ValueKey<String>('inspector-diff-split')), findsOneWidget);
      await rightClick(tester, find.textContaining('gone', findRichText: true));
      await choose(tester, 'Copy path:line');
      expect(copied.last, '$root/src/a.dart:13', reason: 'where the removed line stood');
      // A context line shows in both cells; the right one is the second.
      await rightClick(tester, find.textContaining('twelve', findRichText: true).last);
      await choose(tester, 'Copy path:line');
      expect(copied.last, '$root/src/a.dart:12');
      await unmount(tester);
    });

    testWidgets('a folder menu has no Open row and no note; Reveal and ⌘C take the folder', (tester) async {
      recordClipboard(tester);
      unawaited(settings.update((s) => s.copyWith.general(diffFileList: DiffFileListSetting.tree, editor: 'idea')));
      details.files[_mutable] = const <FileChange>[FileChange(path: 'src/a.dart', kind: FileChangeKind.modified)];
      await pump(tester, files: files());
      await settle(tester);
      final Finder folder = find.byKey(const ValueKey<String>('inspector-folder src'));
      await rightClick(tester, folder);
      expect(find.text('Open in IntelliJ IDEA'), findsNothing);
      expect(find.textContaining("@'s version"), findsNothing, reason: 'the note is a file\'s');
      await choose(tester, 'Reveal in Finder');
      expect(started.last, <String>['/usr/bin/open', '-R', '$root/src']);
      expect(tester.widget<InspectorFolderRow>(folder).current, isTrue, reason: 'the right-click made it current');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pump();
      expect(copied.last, '$root/src');
      await unmount(tester);
    });

    testWidgets('Choose editor… opens Settings on the General tab', (tester) async {
      final windows = FakeWindowActions();
      await pump(tester, files: files(), windowActions: windows);
      await settle(tester);
      await rightClick(tester, _fileRow('src/a.dart'));
      expect(item(tester, 'files-open').enabled, isTrue);
      await choose(tester, 'Choose editor…');
      expect(windows.settings, <SettingsTarget?>[SettingsTarget.general]);
      await unmount(tester);
    });

    testWidgets('a click on the diff header copies the absolute path and shows Copied', (tester) async {
      recordClipboard(tester);
      await pump(tester, files: files());
      await settle(tester);
      final Finder path = _id('inspector-diff-path');
      expect(
        tester.widget<ZsTooltip>(find.ancestor(of: path, matching: find.byType(ZsTooltip)).first).message,
        'Click to copy $root/src/a.dart',
      );
      await tester.tap(path);
      await tester.pump();
      expect(copied, <String>['$root/src/a.dart']);
      expect(find.byKey(const ValueKey<String>('inspector-diff-path-copied')), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 1400));
      expect(find.byKey(const ValueKey<String>('inspector-diff-path-copied')), findsNothing);
      await unmount(tester);
    });

    testWidgets('without files the header path is plain text and rows have no menu', (tester) async {
      await pump(tester);
      await settle(tester);
      expect(_id('inspector-diff-path'), findsNothing);
      await rightClick(tester, _fileRow('src/a.dart'));
      expect(find.text('Copy path'), findsNothing);
      await unmount(tester);
    });

    testWidgets('a bookmark chip copies its name as shown', (tester) async {
      recordClipboard(tester);
      await pump(tester);
      await settle(tester);
      await rightClick(tester, find.text('main@origin'));
      await choose(tester, 'Copy name');
      expect(copied, <String>['main@origin']);
      await unmount(tester);
    });
  });

  test('draftFrom splits the first line from the rest after the blank line', () {
    expect(InspectorViewModel.draftFrom('S\n\nD\n'), (summary: 'S', details: 'D'));
    expect(InspectorViewModel.draftFrom('S\n'), (summary: 'S', details: ''));
    expect(InspectorViewModel.draftFrom(''), (summary: '', details: ''));
    expect(InspectorViewModel.draftFrom('S\n\nA\n\nB\n'), (summary: 'S', details: 'A\n\nB'));
  });
}
