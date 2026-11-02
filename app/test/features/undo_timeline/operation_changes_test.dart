// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/src/features/graph/inspector_diff.dart';
import 'package:zanshin/src/features/shell/pinned_panel.dart';
import 'package:zanshin/src/features/shell/shell_controller.dart';
import 'package:zanshin/src/features/undo_timeline/operation_changes.dart';
import 'package:zanshin/src/features/undo_timeline/undo_timeline_model.dart';
import 'package:zanshin/src/features/undo_timeline/undo_timeline_view.dart';
import 'package:zanshin/src/l10n/strings.dart';
import 'package:zanshin_core/zanshin_core.dart';
import 'package:zanshin_settings/zanshin_settings.dart' show DiffLayoutSetting, SettingsStore;
import 'package:zanshin_ui/zanshin_ui.dart';

import '../../helpers/fake_undo_timeline.dart';
import '../../helpers/icon_registry.dart';
import '../../helpers/shell_host.dart';

final _now = DateTime(2026, 11, 1, 12);

/// A commit id: [c] repeated to 40 hex digits.
String _commit(String c) => c * 40;

final String _x = _commit('a');
final String _p = _commit('b');
final String _abandoned = _commit('c');

const _rewrite = 'rewrite';

OpChangedCommit _rewritten() =>
    OpChangedCommit(commitId: _x, abandoned: false, addedCommitIds: <String>[_x], removedCommitIds: <String>[_p]);

OpChangedCommit _abandonedChange() => OpChangedCommit(
  commitId: _abandoned,
  abandoned: true,
  addedCommitIds: const <String>[],
  removedCommitIds: <String>[_abandoned],
);

Finder _id(String identifier) => find.bySemanticsIdentifier(identifier);

Finder _button(String identifier) => find.byWidgetPredicate((w) => w is ZsButton && w.identifier == identifier);

void main() {
  setUpIconRegistry();
  final AppLocalizations strings = platformStrings();
  late Directory dir;
  late SettingsStore settings;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('zanshin_operation_changes');
    settings = await SettingsStore.load(File('${dir.path}/settings.json'));
  });

  tearDown(() => dir.deleteSync(recursive: true));

  /// Pumps the pinned Undo Timeline over a 3-operation log reading [changes], opens row [row]'s Show changes, runs
  /// [body], then tears everything down.
  Future<void> withView(
    WidgetTester tester,
    FakeOperationChangesSource changes,
    Future<void> Function() body, {
    int row = 1,
  }) async {
    useShellWindow(tester);
    final model = UndoTimelineModel(
      FakeTimelineSource(<Operation>[for (var i = 0; i < 3; i++) testOperation(i, now: _now)]),
      clock: () => _now,
    );
    final ShellRailItem item = undoTimelineRailItem(
      strings,
      model,
      changes: changes,
      settings: settings,
      actions: FakeTimelineActions(),
    );
    await tester.pumpWidget(
      shellHost(
        Center(
          child: SizedBox(
            width: 400,
            height: 700,
            child: PinnedPanel(item: item, onClose: () {}),
          ),
        ),
      ),
    );
    await tester.pump();
    if (row > 0) {
      final TestGesture gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(gesture.removePointer);
      await gesture.addPointer(location: Offset.zero);
      await gesture.moveTo(tester.getCenter(find.text('operation $row')));
      await tester.pump();
    }
    await tester.tap(_button('undo-timeline-show-$row'));
    await tester.pump();
    await tester.pump();
    await tester.pump();
    await body();
    await tester.pumpWidget(const SizedBox.shrink());
    model.dispose();
  }

  FakeOperationChangesSource rewriteSource() => FakeOperationChangesSource(
    testOpShow(testOperation(1, now: _now, description: _rewrite), <OpChangedCommit>[_rewritten()]),
    entries: <ShowEntry>[testShowEntry('kxyz' * 8, _x, 'New\nbody'), testShowEntry('kxyz' * 8, _p, '')],
    diff: (call) => testDiff(call.paths.isEmpty ? const <String>['a.txt', 'b.txt'] : call.paths),
  );

  testWidgets('Show changes opens the view; the source saw exactly one opShow of the 12-hex id', (tester) async {
    final FakeOperationChangesSource changes = rewriteSource();
    await withView(tester, changes, () async {
      expect(changes.opShows, <String>[shortOperationId(opId(1))]);
      expect(find.text('jj op show ${shortOperationId(opId(1))}'), findsOneWidget);
      expect(find.text('operation 1'), findsOneWidget, reason: "the operation's first line");
      expect(find.text('Changed commits:'), findsOneWidget);
      expect(find.text('operation 2'), findsNothing, reason: 'the list is swapped out');
      expect(changes.shows, <String>['$_x | $_p'], reason: 'one show of every referenced commit');
    });
  });

  testWidgets('the newest row has Show changes too', (tester) async {
    final FakeOperationChangesSource changes = rewriteSource();
    await withView(tester, changes, row: 0, () async {
      expect(changes.opShows, <String>[shortOperationId(opId(0))]);
    });
  });

  testWidgets('a rewritten commit: + new, − predecessor; files and focused diff come from interdiff reads', (
    tester,
  ) async {
    final FakeOperationChangesSource changes = rewriteSource();
    await withView(tester, changes, () async {
      expect(find.textContaining('kxyzkxyz aaaaaaaa New', findRichText: true), findsOneWidget);
      expect(find.textContaining('kxyzkxyz bbbbbbbb (no description set)', findRichText: true), findsOneWidget);
      final DiffCall files = changes.diffs.first;
      expect((files.from, files.to, files.revision, files.interdiff, files.summary), (_p, _x, null, true, true));
      expect(files.paths, isEmpty);
      expect(changes.diffs[1].paths, <String>['a.txt']);
      expect(changes.diffs[1].interdiff, isTrue);
      final InspectorDiffView view = tester.widget(find.byType(InspectorDiffView));
      expect(view.path, 'a.txt');
      expect(view.diff, isNotNull);
      expect(view.onViewedChanged, isNull);
      expect(view.layout, settings.value.general.diffLayout);
      expect(_id('inspector-viewed'), findsNothing, reason: 'no Viewed');
      expect(find.byType(InspectorDiffHunk), findsOneWidget);

      await tester.tap(_id('operation-changes-file-1'));
      await tester.pump();
      await tester.pump();
      expect(tester.widget<InspectorDiffView>(find.byType(InspectorDiffView)).path, 'b.txt');
    });
  });

  testWidgets('an abandoned commit: − row; its files are diff(revision: A)', (tester) async {
    final changes = FakeOperationChangesSource(
      testOpShow(testOperation(1, now: _now), <OpChangedCommit>[_abandonedChange()]),
      diff: (call) => testDiff(const <String>['gone.txt']),
    );
    await withView(tester, changes, () async {
      expect(find.textContaining('− $_abandoned', findRichText: true), findsOneWidget, reason: 'show gave no summary');
      expect(changes.diffs.first.revision, _abandoned);
      expect(changes.diffs.first.interdiff, isFalse);
      expect(find.text('gone.txt'), findsNWidgets(2), reason: 'its row and its diff');
    });
  });

  testWidgets('selecting another commit reads its files', (tester) async {
    final changes = FakeOperationChangesSource(
      testOpShow(testOperation(1, now: _now), <OpChangedCommit>[_rewritten(), _abandonedChange()]),
      diff: (call) => testDiff(call.revision == null ? const <String>['x.txt'] : const <String>['gone.txt']),
    );
    await withView(tester, changes, () async {
      expect(find.text('x.txt'), findsNWidgets(2));
      await tester.tap(_id('operation-changes-commit-1'));
      await tester.pump();
      await tester.pump();
      expect(find.text('gone.txt'), findsNWidgets(2));
      expect(find.text('x.txt'), findsNothing);
    });
  });

  testWidgets('a merge operation explains that jj shows no changes', (tester) async {
    final changes = FakeOperationChangesSource(OpShow(operation: testOperation(1, now: _now)));
    await withView(tester, changes, () async {
      expect(find.text(strings.operationChangesMerge), findsOneWidget);
      expect(changes.diffs, isEmpty);
    });
  });

  testWidgets('an unresolved changes-in shows the warnings verbatim; ref sections still show', (tester) async {
    const warning = ZanshinWarning(
      code: ZanshinWarningCode.opDiffChangesUnresolved,
      message: 'Could not resolve revset expression for elision: x',
    );
    final changes = FakeOperationChangesSource(
      OpShow(
        operation: testOperation(1, now: _now),
        warnings: const <ZanshinWarning>[warning],
        diff: OpDiff(
          commits: null,
          workingCopies: const <OpWorkingCopyChange>[],
          localBookmarks: <OpRefChange>[
            OpRefChange(
              name: 'main',
              from: const OpRefTarget(adds: <String>[], removes: <String>[], conflicted: false),
              to: OpRefTarget(adds: <String>[_x], removes: const <String>[], conflicted: false),
            ),
          ],
          localTags: const <OpRefChange>[],
          remoteBookmarks: const <OpRemoteRefChange>[],
          remoteTags: const <OpRemoteRefChange>[],
        ),
      ),
    );
    await withView(tester, changes, () async {
      expect(find.text(warning.message), findsOneWidget);
      expect(find.text('Changed commits:'), findsNothing);
      expect(find.text('Changed local bookmarks:'), findsOneWidget);
      expect(find.text('main:'), findsOneWidget);
      expect(find.textContaining('+ $_x', findRichText: true), findsOneWidget);
      expect(find.textContaining('− (absent)', findRichText: true), findsOneWidget);
    });
  });

  testWidgets("a refused opShow shows jj's text in place of the view", (tester) async {
    final changes = FakeOperationChangesSource(OpShow(operation: testOperation(1, now: _now)))
      ..refuseOpShow = const ZanshinFfiException('jj.operation_not_found', 'No operation ID matching "x"');
    await withView(tester, changes, () async {
      expect(find.text('No operation ID matching "x"'), findsOneWidget);
      expect(_button('operation-changes-back'), findsOneWidget, reason: 'Back stays');
    });
  });

  testWidgets("a refused commit diff shows jj's text in place of the files", (tester) async {
    final FakeOperationChangesSource changes = rewriteSource()
      ..refuseDiff = const ZanshinFfiException('jj.jj_lib_error');
    await withView(tester, changes, () async {
      expect(find.byKey(const ValueKey<String>('operation-changes-files-error')), findsOneWidget);
      expect(find.text('jj.jj_lib_error'), findsOneWidget);
      expect(find.byType(InspectorDiffView), findsNothing);
    });
  });

  testWidgets('Esc returns to the list, focus back in the panel', (tester) async {
    await withView(tester, rewriteSource(), () async {
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      await tester.pump();
      expect(find.text('operation 2'), findsOneWidget);
      expect(find.text('Changed commits:'), findsNothing);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'undo timeline list');
    });
  });

  testWidgets('Back returns to the list', (tester) async {
    await withView(tester, rewriteSource(), () async {
      await tester.tap(_button('operation-changes-back'));
      await tester.pump();
      expect(find.text('operation 2'), findsOneWidget);
    });
  });

  testWidgets('a created commit: one + line; its files are diff(revision: X), no interdiff', (tester) async {
    final changes = FakeOperationChangesSource(
      testOpShow(testOperation(1, now: _now), <OpChangedCommit>[
        OpChangedCommit(commitId: _x, abandoned: false, addedCommitIds: <String>[_x], removedCommitIds: const []),
      ]),
      diff: (call) => testDiff(const <String>['new.txt']),
    );
    await withView(tester, changes, () async {
      expect(changes.diffs, isNotEmpty);
      expect(changes.diffs.every((call) => call.revision == _x && !call.interdiff && call.from == null), isTrue);
      expect(find.textContaining('+ $_x', findRichText: true), findsOneWidget);
      expect(find.textContaining('− ', findRichText: true), findsNothing);
    });
  });

  testWidgets('a new model and source for the rail item closes the open view (another repository)', (tester) async {
    useShellWindow(tester);
    UndoTimelineModel timeline() => UndoTimelineModel(
      FakeTimelineSource(<Operation>[for (var i = 0; i < 3; i++) testOperation(i, now: _now)]),
      clock: () => _now,
    );
    Widget host(UndoTimelineModel model, FakeOperationChangesSource changes) => shellHost(
      Center(
        child: SizedBox(
          width: 400,
          height: 700,
          child: PinnedPanel(
            item: undoTimelineRailItem(strings, model, changes: changes, settings: settings),
            onClose: () {},
          ),
        ),
      ),
    );
    final UndoTimelineModel first = timeline();
    final UndoTimelineModel second = timeline();
    await tester.pumpWidget(host(first, rewriteSource()));
    await tester.pump();
    await tester.tap(_button('undo-timeline-show-0'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Changed commits:'), findsOneWidget);
    await tester.pumpWidget(host(second, rewriteSource()));
    await tester.pump();
    expect(find.text('Changed commits:'), findsNothing);
    expect(find.text('operation 2'), findsOneWidget, reason: 'the list is back');
    await tester.pumpWidget(const SizedBox.shrink());
    first.dispose();
    second.dispose();
  });

  testWidgets('the working copy, a remote bookmark and a conflicted bookmark render as jj writes them', (tester) async {
    OpRefTarget one(String id) => OpRefTarget(adds: <String>[id], removes: const <String>[], conflicted: false);
    final changes = FakeOperationChangesSource(
      OpShow(
        operation: testOperation(1, now: _now),
        diff: OpDiff(
          commits: null,
          workingCopies: <OpWorkingCopyChange>[OpWorkingCopyChange(workspace: 'default', from: _p, to: _x)],
          localBookmarks: <OpRefChange>[
            OpRefChange(
              name: 'main',
              from: one(_p),
              to: OpRefTarget(adds: <String>[_x, _abandoned], removes: <String>[_p], conflicted: true),
            ),
          ],
          localTags: const <OpRefChange>[],
          remoteBookmarks: <OpRemoteRefChange>[
            OpRemoteRefChange(
              name: 'main',
              remote: 'origin',
              from: one(_p),
              fromTracked: false,
              to: one(_x),
              toTracked: true,
            ),
          ],
          remoteTags: const <OpRemoteRefChange>[],
        ),
      ),
    );
    await withView(tester, changes, () async {
      expect(find.text('Changed working copy default@:'), findsOneWidget);
      expect(find.text('Changed remote bookmarks:'), findsOneWidget);
      expect(find.text('main@origin:'), findsOneWidget);
      expect(find.textContaining('+ tracked $_x', findRichText: true), findsOneWidget);
      expect(find.textContaining('− untracked $_p', findRichText: true), findsOneWidget);
      expect(find.textContaining('+ (added) $_x', findRichText: true), findsOneWidget);
      expect(find.textContaining('+ (added) $_abandoned', findRichText: true), findsOneWidget);
      expect(find.textContaining('+ (removed) $_p', findRichText: true), findsOneWidget);
    });
  });

  test('disposing the model while the summary read is pending starts no further diff read', () async {
    final FakeOperationChangesSource changes = rewriteSource()..diffGate = Completer<void>();
    final model = OperationChangesModel(changes, operation: opId(1), settings: settings);
    await pumpEventQueue();
    expect(changes.diffs, hasLength(1), reason: 'the summary read is pending');
    model.dispose();
    changes.diffGate!.complete();
    await pumpEventQueue();
    expect(changes.diffs, hasLength(1), reason: 'no focused-file read after dispose');
  });

  test('the elided line is jj\'s: exact, bounded and unknown counts, nothing when none', () {
    OpCommitsDiff elided(RefDistance visible, RefDistance hidden) =>
        OpCommitsDiff(changes: const <OpChangedCommit>[], elidedNewlyVisible: visible, elidedNewlyHidden: hidden);
    const none = RefDistance(lower: 0, upper: 0);
    expect(elidedLine(elided(none, none)), isNull);
    expect(elidedLine(elided(const RefDistance(lower: 3, upper: 3), none)), '(Elided 3 newly added revisions)');
    expect(
      elidedLine(elided(const RefDistance(lower: 0), const RefDistance(lower: 2, upper: 5))),
      '(Elided some newly added and 2+ newly removed revisions)',
    );
  });

  test('summaries: change id, commit id, first line; the commit id alone after a refused show', () async {
    final FakeOperationChangesSource changes = rewriteSource();
    final model = OperationChangesModel(changes, operation: opId(1), settings: settings);
    await pumpEventQueue();
    expect(model.summaryOf(_x), 'kxyzkxyz aaaaaaaa New');
    model.dispose();

    final FakeOperationChangesSource refused = rewriteSource()
      ..refuseShow = const ZanshinFfiException('jj.jj_lib_error');
    final fallback = OperationChangesModel(refused, operation: opId(1), settings: settings);
    await pumpEventQueue();
    expect(fallback.summaryOf(_x), _x);
    fallback.dispose();
  });

  test('the layout is general.diffLayout: written and followed', () async {
    final model = OperationChangesModel(rewriteSource(), operation: opId(1), settings: settings);
    expect(model.layout, DiffLayoutSetting.unified);
    model.setLayout(DiffLayoutSetting.sideBySide);
    await pumpEventQueue();
    expect(settings.value.general.diffLayout, DiffLayoutSetting.sideBySide);
    expect(model.layout, DiffLayoutSetting.sideBySide);
    await settings.update((s) => s.copyWith(general: s.general.copyWith(diffLayout: DiffLayoutSetting.unified)));
    expect(model.layout, DiffLayoutSetting.unified);
    model.dispose();
  });
}
