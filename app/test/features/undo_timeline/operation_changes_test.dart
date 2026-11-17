// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/src/features/graph/file_masks.dart';
import 'package:zanshin/src/features/graph/graph_inspector.dart' show InspectorFileRow;
import 'package:zanshin/src/features/graph/inspector_diff.dart';
import 'package:zanshin/src/features/shell/pinned_panel.dart';
import 'package:zanshin/src/features/shell/shell_controller.dart';
import 'package:zanshin/src/features/undo_timeline/operation_changes.dart';
import 'package:zanshin/src/features/undo_timeline/undo_timeline_model.dart';
import 'package:zanshin/src/features/undo_timeline/undo_timeline_view.dart';
import 'package:zanshin/src/l10n/strings.dart';
import 'package:zanshin_core/zanshin_core.dart';
import 'package:zanshin_settings/zanshin_settings.dart' show DiffLayoutSetting, DiffWhitespaceSetting, SettingsStore;
import 'package:zanshin_ui/zanshin_ui.dart';

import '../../helpers/fake_undo_timeline.dart';
import '../../helpers/icon_registry.dart';
import '../../helpers/settle_settings.dart';
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
      changes: operationChangesOver(changes, settings),
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
      expect(view.wordMarks, isTrue, reason: 'the default setting');
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
      expect(changes.diffs, isNotEmpty);
      expect(
        changes.diffs.every(
          (call) => call.revision == _abandoned && !call.interdiff && call.from == null && call.to == null,
        ),
        isTrue,
      );
      expect(find.text('gone.txt'), findsNWidgets(2), reason: 'its row and its diff');
    });
  });

  testWidgets('Story 10.42: file rows show the quiet word, no status letter, no ±, no checkbox', (tester) async {
    final changes = FakeOperationChangesSource(
      testOpShow(testOperation(1, now: _now), <OpChangedCommit>[_abandonedChange()]),
      diff: (call) => Diff(
        files: <FileDiff>[
          testFileDiff('gone.txt', kind: FileChangeKind.removed),
          testFileDiff('born.txt', kind: FileChangeKind.added),
        ],
        operationId: 'op',
        commitIds: const <String>[],
      ),
    );
    await withView(tester, changes, () async {
      String row(int i) => tester
          .widget<Text>(find.descendant(of: _id('operation-changes-file-$i'), matching: find.byType(Text)).first)
          .textSpan!
          .toPlainText();
      expect(row(0), endsWith('deleted'));
      expect(row(1), endsWith('new'));
      for (final i in <int>[0, 1]) {
        for (final gone in <String>['D', 'A', '+1', '−1']) {
          expect(find.descendant(of: _id('operation-changes-file-$i'), matching: find.text(gone)), findsNothing);
        }
        expect(find.descendant(of: _id('operation-changes-file-$i'), matching: find.byType(ZsCheckbox)), findsNothing);
      }
    });
  });

  testWidgets('Story 10.39: with the workspace root the diff header copies the absolute path', (tester) async {
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied.add((call.arguments as Map<Object?, Object?>)['text']! as String);
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    final changes = FakeOperationChangesSource(
      testOpShow(testOperation(1, now: _now), <OpChangedCommit>[_abandonedChange()]),
      diff: (call) => testDiff(const <String>['gone.txt']),
    )..root = '/r/repo';
    await withView(tester, changes, () async {
      await tester.tap(_id('inspector-diff-path'));
      await tester.pump();
      expect(copied, <String>['/r/repo/gone.txt']);
      expect(find.byKey(const ValueKey<String>('inspector-diff-path-copied')), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
    });
  });

  testWidgets('Story 10.49: a masked file is not listed; the hint has no box; Show lists it dimmed; Masks… opens the '
      'popover', (tester) async {
    addTearDown(() => settleSettingsWrites(tester, settings));
    settings.addFileMask('*.g.dart');
    final changes = FakeOperationChangesSource(
      testOpShow(testOperation(1, now: _now), <OpChangedCommit>[_rewritten()]),
      diff: (call) => testDiff(call.paths.isEmpty ? const <String>['a.g.dart', 'b.txt'] : call.paths),
    );
    await withView(tester, changes, () async {
      expect(find.textContaining('a.g.dart', findRichText: true), findsNothing);
      expect(tester.widget<InspectorDiffView>(find.byType(InspectorDiffView)).path, 'b.txt', reason: 'first shown');
      expect(_id('inspector-masked-hint'), findsOneWidget);
      expect(_id('inspector-masked-check'), findsNothing);
      expect(
        tester.widget<Text>(find.byKey(const ValueKey<String>('inspector-masked-text'))).data,
        '1 file hidden',
        reason: 'no pick part',
      );
      await tester.tap(_id('inspector-masked-show'));
      await tester.pump();
      final InspectorFileRow row = tester.widget<InspectorFileRow>(
        find.descendant(of: _id('operation-changes-file-0'), matching: find.byType(InspectorFileRow)),
      );
      expect((row.file.path, row.masked), ('a.g.dart', true));
      await tester.tap(_id('inspector-masked-masks'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(_id('file-masks-popover'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(_id('file-masks-popover'), findsNothing);
    });
  });

  testWidgets('Story 10.49: unticking the last hiding mask in the popover keeps it open; the hint goes', (
    tester,
  ) async {
    addTearDown(() => settleSettingsWrites(tester, settings));
    settings.addFileMask('*.g.dart');
    final changes = FakeOperationChangesSource(
      testOpShow(testOperation(1, now: _now), <OpChangedCommit>[_rewritten()]),
      diff: (call) => testDiff(call.paths.isEmpty ? const <String>['a.g.dart', 'b.txt'] : call.paths),
    );
    await withView(tester, changes, () async {
      await tester.tap(_id('inspector-masked-masks'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(_id('file-masks-popover'), findsOneWidget);
      await tester.tap(_id('file-mask-0'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(settings.value.general.fileMasks.first.active, isFalse);
      expect(_id('inspector-masked-hint'), findsNothing);
      expect(_id('file-masks-popover'), findsOneWidget, reason: 'the popover survives');
      expect(find.text('a.g.dart'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    });
  });

  testWidgets('Story 10.49: Hide moves the focus off the shown hidden file to the next shown one', (tester) async {
    addTearDown(() => settleSettingsWrites(tester, settings));
    settings.addFileMask('*.g.dart');
    final changes = FakeOperationChangesSource(
      testOpShow(testOperation(1, now: _now), <OpChangedCommit>[_rewritten()]),
      diff: (call) => testDiff(call.paths.isEmpty ? const <String>['a.txt', 'b.g.dart', 'c.txt'] : call.paths),
    );
    await withView(tester, changes, () async {
      await tester.tap(_id('inspector-masked-show'));
      await tester.pump();
      await tester.tap(_id('operation-changes-file-1'), warnIfMissed: false);
      await tester.pump();
      await tester.pump();
      expect(tester.widget<InspectorDiffView>(find.byType(InspectorDiffView)).path, 'b.g.dart');
      await tester.tap(_id('inspector-masked-show'));
      await tester.pump();
      await tester.pump();
      expect(tester.widget<InspectorDiffView>(find.byType(InspectorDiffView)).path, 'c.txt');
      expect(find.textContaining('b.g.dart', findRichText: true), findsNothing);
    });
  });

  testWidgets('Story 10.49: Show is per commit: another commit starts with its masked file hidden', (tester) async {
    addTearDown(() => settleSettingsWrites(tester, settings));
    settings.addFileMask('*.g.dart');
    final changes = FakeOperationChangesSource(
      testOpShow(testOperation(1, now: _now), <OpChangedCommit>[_rewritten(), _abandonedChange()]),
      diff: (call) => testDiff(
        call.paths.isNotEmpty
            ? call.paths
            : call.revision == null
            ? const <String>['a.g.dart', 'b.txt']
            : const <String>['c.g.dart', 'd.txt'],
      ),
    );
    await withView(tester, changes, () async {
      expect(
        tester.widget<Text>(find.byKey(const ValueKey<String>('inspector-masked-text'))).data,
        '1 file hidden',
      );
      await tester.tap(_id('inspector-masked-show'));
      await tester.pump();
      // The shown hidden row carries the eye-off glyph inside its text.
      expect(find.textContaining('a.g.dart', findRichText: true), findsOneWidget);
      await tester.tap(_id('operation-changes-commit-1'));
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('c.g.dart', findRichText: true), findsNothing);
      expect(
        tester.widget<Text>(find.byKey(const ValueKey<String>('inspector-masked-text'))).data,
        '1 file hidden',
      );
    });
  });

  testWidgets('Story 10.49: a newly masked focused file gives the focus to the next shown one', (tester) async {
    addTearDown(() => settleSettingsWrites(tester, settings));
    final changes = FakeOperationChangesSource(
      testOpShow(testOperation(1, now: _now), <OpChangedCommit>[_rewritten()]),
      diff: (call) => testDiff(call.paths.isEmpty ? const <String>['a.txt', 'b.txt'] : call.paths),
    );
    await withView(tester, changes, () async {
      expect(tester.widget<InspectorDiffView>(find.byType(InspectorDiffView)).path, 'a.txt');
      settings.addFileMask('a.txt');
      await tester.pump();
      await tester.pump();
      expect(tester.widget<InspectorDiffView>(find.byType(InspectorDiffView)).path, 'b.txt');
      settings.addFileMask('b.txt');
      await tester.pump();
      expect(find.byType(InspectorDiffView), findsNothing, reason: 'every file hidden: no diff');
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

  testWidgets('a created commit: one + line; its files are diff(revision: X, interdiff: true), no from/to', (
    tester,
  ) async {
    final changes = FakeOperationChangesSource(
      testOpShow(testOperation(1, now: _now), <OpChangedCommit>[
        OpChangedCommit(commitId: _x, abandoned: false, addedCommitIds: <String>[_x], removedCommitIds: const []),
      ]),
      diff: (call) => testDiff(const <String>['new.txt'], description: true),
    );
    await withView(tester, changes, () async {
      expect(changes.diffs, isNotEmpty);
      expect(
        changes.diffs.every((call) => call.revision == _x && call.interdiff && call.from == null && call.to == null),
        isTrue,
      );
      expect(find.textContaining('+ $_x', findRichText: true), findsOneWidget);
      expect(find.textContaining('− ', findRichText: true), findsNothing);
      final Finder block = find.byKey(const ValueKey<String>('operation-changes-description'));
      expect(block, findsOneWidget);
      expect(
        tester.getTopLeft(block).dy,
        lessThan(tester.getTopLeft(_id('operation-changes-file-0')).dy),
        reason: 'above the files',
      );
      final InspectorDiffView view = tester.widget(
        find.descendant(of: block, matching: find.byType(InspectorDiffView)),
      );
      expect(view.path, 'JJ-COMMIT-DESCRIPTION');
      expect(view.wordMarks, isTrue, reason: 'the description block follows the switch too');
    });
  });

  testWidgets('Changed words off reaches the description block and the focused file (Story 5.14)', (tester) async {
    final changes = FakeOperationChangesSource(
      testOpShow(testOperation(1, now: _now), <OpChangedCommit>[
        OpChangedCommit(commitId: _x, abandoned: false, addedCommitIds: <String>[_x], removedCommitIds: const []),
      ]),
      diff: (call) => testDiff(const <String>['new.txt'], description: true),
    );
    await withView(tester, changes, () async {
      final int reads = changes.diffs.length;
      unawaited(
        settings
            .update((s) => s.copyWith(general: s.general.copyWith(diffWordMarks: false)))
            .onError<FileSystemException>((_, _) {}),
      );
      await tester.pump();
      final Finder block = find.byKey(const ValueKey<String>('operation-changes-description'));
      final InspectorDiffView description = tester.widget(
        find.descendant(of: block, matching: find.byType(InspectorDiffView)),
      );
      expect(description.wordMarks, isFalse);
      final InspectorDiffView focused = tester.widget(
        find.byWidgetPredicate((w) => w is InspectorDiffView && w.path == 'new.txt'),
      );
      expect(focused.wordMarks, isFalse);
      expect(changes.diffs, hasLength(reads), reason: 'the switch reloads nothing');
    });
  });

  group('Story 10.43: gap rows in the operation view', () {
    /// A source whose files have 40 left lines (a bottom gap of 39) and whose gap reads answer lines 2-40.
    FakeOperationChangesSource gapSource(OpChangedCommit change) =>
        FakeOperationChangesSource(
            testOpShow(testOperation(1, now: _now, description: _rewrite), <OpChangedCommit>[change]),
            entries: <ShowEntry>[
              testShowEntry('kxyz' * 8, _x, 'New\nbody'),
              testShowEntry('kxyz' * 8, _p, ''),
              testShowEntry('kabc' * 8, _abandoned, 'Gone\n'),
            ],
            diff: (call) => Diff(
              files: <FileDiff>[
                for (final String path in call.paths.isEmpty ? const <String>['a.txt'] : call.paths)
                  testFileDiff(path, leftLineCount: 40),
              ],
              operationId: 'op',
              commitIds: const <String>[],
            ),
          )
          ..lines = <HunkLine>[
            for (var n = 2; n <= 40; n++)
              HunkLine(
                kind: HunkLineKind.context,
                text: 'line $n\n',
                left: n,
                right: n,
                segments: <Segment>[Segment(kind: SegmentKind.equal, text: 'line $n\n')],
              ),
          ];

    /// Opens the focused file's bottom gap whole with Show all.
    Future<void> showAll(WidgetTester tester) async {
      final Finder all = find.bySemanticsIdentifier('inspector-unchanged-all');
      await tester.ensureVisible(all);
      await tester.pump();
      await tester.tap(all);
      await tester.pump();
      await tester.pump();
    }

    testWidgets('the description block shows its unchanged lines as a count only: no controls, no read', (
      tester,
    ) async {
      final changes = FakeOperationChangesSource(
        testOpShow(testOperation(1, now: _now), <OpChangedCommit>[
          OpChangedCommit(commitId: _x, abandoned: false, addedCommitIds: <String>[_x], removedCommitIds: const []),
        ]),
        diff: (call) => Diff(
          files: <FileDiff>[testFileDiff('a.txt')],
          operationId: 'op',
          commitIds: const <String>[],
          description: testFileDiff('JJ-COMMIT-DESCRIPTION', leftLineCount: 12),
        ),
      );
      await withView(tester, changes, () async {
        final Finder block = find.byKey(const ValueKey<String>('operation-changes-description'));
        expect(find.descendant(of: block, matching: find.text('11 unchanged lines')), findsOneWidget);
        for (final control in <String>['show', 'down', 'up', 'all']) {
          expect(
            find.descendant(of: block, matching: find.bySemanticsIdentifier('inspector-unchanged-$control')),
            findsNothing,
            reason: control,
          );
        }
        expect(changes.lineReads, isEmpty);
      });
    });

    testWidgets('a file diff has no hunk header and no boxes; its gap row reads its lines in the rewritten '
        "commit's interdiff form", (tester) async {
      final FakeOperationChangesSource changes = gapSource(_rewritten());
      await withView(tester, changes, () async {
        expect(find.textContaining('@@'), findsNothing, reason: 'no hunk header');
        expect(find.byWidgetPredicate((w) => w is ZsCheckbox), findsNothing, reason: 'no boxes');
        expect(find.text('39 unchanged lines'), findsOneWidget, reason: 'the bottom gap');
        await showAll(tester);
        final LineReadCall read = changes.lineReads.single;
        expect(
          (read.revision, read.from, read.to, read.interdiff, read.path, read.start, read.end, read.whitespace),
          (null, _p, _x, true, 'a.txt', 1, 40, DiffWhitespace.exact),
          reason: 'from the first predecessor to the commit, as its diff',
        );
        expect(find.text('39 unchanged lines'), findsNothing);
        expect(find.text('line 40'), findsOneWidget);
      });
    });

    testWidgets("an abandoned commit's gap reads `-r` the commit, no interdiff", (tester) async {
      final FakeOperationChangesSource changes = gapSource(_abandonedChange());
      await withView(tester, changes, () async {
        await showAll(tester);
        final LineReadCall read = changes.lineReads.single;
        expect(
          (read.revision, read.from, read.to, read.interdiff),
          (_abandoned, null, null, false),
          reason: 'show_patch, as its diff',
        );
      });
    });

    testWidgets("a created commit's gap reads the commit as an interdiff with no predecessor", (tester) async {
      final FakeOperationChangesSource changes = gapSource(
        OpChangedCommit(commitId: _x, abandoned: false, addedCommitIds: <String>[_x], removedCommitIds: const []),
      );
      await withView(tester, changes, () async {
        await showAll(tester);
        final LineReadCall read = changes.lineReads.single;
        expect((read.revision, read.from, read.to, read.interdiff), (_x, null, null, true));
      });
    });

    testWidgets('after "Ignore all whitespace" the gap reads at -w', (tester) async {
      final FakeOperationChangesSource changes = gapSource(_rewritten());
      await withView(tester, changes, () async {
        final ZsMenuItem ignoreAll = tester
            .widget<ZsMenuButton>(
              find.byWidgetPredicate((w) => w is ZsMenuButton && w.identifier == 'inspector-diff-options'),
            )
            .entries
            .whereType<ZsMenuItem>()
            .singleWhere((i) => i.identifier == 'diff-options-whitespace-ignoreAll');
        ignoreAll.onSelected!();
        await tester.pump();
        await tester.pump();
        await showAll(tester);
        expect(changes.lineReads.single.whitespace, DiffWhitespace.ignoreAllSpace);
      });
    });
  });

  testWidgets('Story 10.33: the focused file has the diff options menu, the description block none; the whitespace '
      'mode reloads the file exact and at -w; a context pick writes the config and reloads', (tester) async {
    final changes = FakeOperationChangesSource(
      testOpShow(testOperation(1, now: _now), <OpChangedCommit>[
        OpChangedCommit(commitId: _x, abandoned: false, addedCommitIds: <String>[_x], removedCommitIds: const []),
      ]),
      // Story 10.41: at -w the file's one line changed only in whitespace.
      diff: (call) => call.whitespace == DiffWhitespace.exact
          ? testDiff(const <String>['new.txt'], description: true)
          : const Diff(
              files: <FileDiff>[
                FileDiff(
                  path: 'new.txt',
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
                      text: 'new \n',
                      segments: <Segment>[
                        Segment(kind: SegmentKind.equal, text: 'new'),
                        Segment(kind: SegmentKind.added, text: ' '),
                        Segment(kind: SegmentKind.equal, text: '\n'),
                      ],
                      left: 1,
                      right: 1,
                    ),
                  ],
                ),
              ],
              operationId: 'op',
              commitIds: <String>[],
            ),
    );
    await withView(tester, changes, () async {
      final Finder menus = find.byWidgetPredicate(
        (w) => w is ZsMenuButton && w.identifier == 'inspector-diff-options',
      );
      expect(menus, findsOneWidget, reason: 'the focused file only');
      final Finder block = find.byKey(const ValueKey<String>('operation-changes-description'));
      expect(find.descendant(of: block, matching: menus), findsNothing);
      ZsMenuItem row(String identifier) => tester
          .widget<ZsMenuButton>(menus)
          .entries
          .whereType<ZsMenuItem>()
          .singleWhere((i) => i.identifier == identifier);

      final int reads = changes.diffs.length;
      row('diff-options-whitespace-ignoreAll').onSelected!();
      await tester.pump();
      await tester.pump();
      expect(
        changes.diffs.skip(reads).map((call) => (call.summary, call.paths.join(','), call.whitespace)),
        unorderedEquals(<(bool, String, DiffWhitespace)>[
          (false, 'new.txt', DiffWhitespace.exact),
          (false, 'new.txt', DiffWhitespace.ignoreAllSpace),
        ]),
        reason: 'the focused file twice, the summary not again',
      );
      final InspectorDiffView focused = tester.widget(
        find.byWidgetPredicate((w) => w is InspectorDiffView && w.path == 'new.txt'),
      );
      expect(focused.whitespace, DiffWhitespaceSetting.ignoreAll);
      expect(focused.ignoring, isNotNull);
      expect(row('diff-options-whitespace-ignoreAll').checked, isTrue);
      // The rows come from the ignoring read: here only a gap row for the whitespace-only line.
      expect(find.text('1 more line with only whitespace changes'), findsOneWidget);
      await tester.ensureVisible(find.bySemanticsIdentifier('inspector-gap-show'));
      await tester.pump();
      await tester.tap(find.bySemanticsIdentifier('inspector-gap-show'));
      await tester.pump();
      expect(find.text('1 line with only whitespace changes'), findsOneWidget);
      expect(find.text('new '), findsOneWidget);

      final int before = changes.diffs.length;
      row('diff-options-context-5').onSelected!();
      await tester.pump();
      await tester.pump();
      expect(changes.contextWrites, <int>[5]);
      expect(row('diff-options-context-5').checked, isTrue);
      expect(changes.diffs.length, greaterThan(before), reason: 'the config write reloads');
    });
  });

  testWidgets('Story 10.40: a repo-set context is checked with the note that it wins; a pick still writes the user '
      'config', (tester) async {
    final changes =
        FakeOperationChangesSource(
            testOpShow(testOperation(1, now: _now), <OpChangedCommit>[
              OpChangedCommit(commitId: _x, abandoned: false, addedCommitIds: <String>[_x], removedCommitIds: const []),
            ]),
            diff: (call) => testDiff(const <String>['new.txt']),
          )
          ..context = 7
          ..contextFromRepo = true;
    await withView(tester, changes, () async {
      final Finder menu = find.byWidgetPredicate((w) => w is ZsMenuButton && w.identifier == 'inspector-diff-options');
      List<ZsMenuEntry> entries() => tester.widget<ZsMenuButton>(menu).entries;
      expect(
        entries().whereType<ZsMenuItem>().singleWhere((i) => i.identifier == 'diff-options-context-7').checked,
        isTrue,
      );
      expect(
        entries().whereType<ZsMenuNote>().map((note) => note.label),
        contains("Set in this repository's config, which wins"),
      );
      entries().whereType<ZsMenuItem>().singleWhere((i) => i.identifier == 'diff-options-context-5').onSelected!();
      await tester.pump();
      expect(changes.contextWrites, <int>[5]);
    });
  });

  testWidgets('a body-only describe: the description block above the no-file-changes note', (tester) async {
    final changes = FakeOperationChangesSource(
      testOpShow(testOperation(1, now: _now), <OpChangedCommit>[_rewritten()]),
      diff: (call) => testDiff(const <String>[], description: true),
    );
    await withView(tester, changes, () async {
      final Finder block = find.byKey(const ValueKey<String>('operation-changes-description'));
      expect(block, findsOneWidget);
      final Finder note = find.text(strings.operationChangesNoFiles);
      expect(note, findsOneWidget);
      expect(tester.getTopLeft(block).dy, lessThan(tester.getTopLeft(note).dy));
    });
  });

  testWidgets('equal descriptions render no description block', (tester) async {
    await withView(tester, rewriteSource(), () async {
      expect(find.byKey(const ValueKey<String>('operation-changes-description')), findsNothing);
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
            item: undoTimelineRailItem(strings, model, changes: operationChangesOver(changes, settings)),
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

  test('flipping general.diffWordMarks notifies and calls diff zero times, keeping the focused file', () async {
    final FakeOperationChangesSource changes = rewriteSource();
    final model = OperationChangesModel(changes, operation: opId(1), settings: settings);
    await pumpEventQueue();
    model.focus('b.txt');
    await pumpEventQueue();
    expect(model.wordMarks, isTrue, reason: 'on by default');
    final int before = changes.diffs.length;
    var notified = 0;
    model.addListener(() => notified++);
    await settings.update((s) => s.copyWith(general: s.general.copyWith(diffWordMarks: false)));
    await pumpEventQueue();
    expect(model.wordMarks, isFalse);
    expect(notified, 1);
    await settings.update((s) => s.copyWith(general: s.general.copyWith(diffWordMarks: true)));
    await pumpEventQueue();
    expect(model.wordMarks, isTrue);
    expect(notified, 2);
    expect(changes.diffs, hasLength(before), reason: 'the switch reloads nothing');
    expect(model.focusedPath, 'b.txt');
    expect(model.focusedDiff, isNotNull, reason: 'the loaded diff stays');
    model.dispose();
  });

  test('a jj config write reads the selection once again, keeping the focused file (Story 5.12)', () async {
    final FakeOperationChangesSource changes = rewriteSource();
    final model = OperationChangesModel(changes, operation: opId(1), settings: settings);
    await pumpEventQueue();
    model.focus('b.txt');
    await pumpEventQueue();
    final int before = changes.diffs.length;
    changes.configWrites.fire();
    await pumpEventQueue();
    expect(changes.diffs.skip(before).map((call) => (call.summary, call.paths.join(','))), <(bool, String)>[
      (true, ''),
      (false, 'b.txt'),
    ]);
    expect(model.focusedPath, 'b.txt');
    model.dispose();
    changes.configWrites.fire();
    await pumpEventQueue();
    expect(changes.diffs, hasLength(before + 2), reason: 'a disposed view stops listening');
  });
}
