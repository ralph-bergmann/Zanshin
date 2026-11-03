// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/src/features/graph/graph_ports.dart';
import 'package:zanshin/src/features/graph/graph_view_model.dart';
import 'package:zanshin/src/features/shell/shell_toast.dart';
import 'package:zanshin/src/features/sync/push_sheet_model.dart';
import 'package:zanshin/src/features/sync/sync_model.dart';
import 'package:zanshin_core/zanshin_core.dart';
import 'package:zanshin_settings/zanshin_settings.dart' show RemotePollSetting;
import 'package:zanshin_ui/zanshin_ui.dart';

import '../../helpers/fake_remote_sync.dart';
import '../../helpers/icon_registry.dart';
import '../../helpers/scripted_graph_source.dart';
import '../../helpers/shell_host.dart';

/// A sync model over a fake port, a graph view model and a toast queue; [setting] is the project's poll interval.
class _Rig {
  _Rig({RemotePollSetting setting = RemotePollSetting.fiveMinutes, void Function(FakeRemoteSync sync)? configure})
    : setting = ValueNotifier(setting) {
    configure?.call(sync);
    _rigs.add(this);
    model = SyncModel(
      sync: sync,
      graph: graph,
      toasts: toasts,
      pollSetting: () => this.setting.value,
      pollChanged: this.setting,
      syncing: <T>(run) async {
        syncs++;
        try {
          return await run();
        } finally {
          syncs--;
        }
      },
    );
  }

  final sync = FakeRemoteSync();
  final graph = _Graph();
  final toasts = ShellToasts();
  final ValueNotifier<RemotePollSetting> setting;
  late final SyncModel model;

  /// The runs inside the syncing dot.
  var syncs = 0;

  void dispose() {
    model.dispose();
    graph.dispose();
    toasts.dispose();
    setting.dispose();
  }
}

/// A graph view model whose `undoOperation` is recorded and answers [undoAnswer].
class _Graph extends GraphViewModel {
  final undos = <(String, GraphLoggedOperation)>[];
  GraphActionResult undoAnswer = const GraphActionRefused(ZanshinFfiException('jj.demo'));

  @override
  Future<GraphActionResult> undoOperation(String head, GraphLoggedOperation of) async {
    undos.add((head, of));
    return undoAnswer;
  }
}

final _rigs = <_Rig>[];

/// A widget test whose rigs are disposed at its end, before the pending-timer check.
void _rigTest(String description, Future<void> Function(WidgetTester tester) body) =>
    testWidgets(description, (tester) async {
      try {
        await body(tester);
      } finally {
        for (final _Rig rig in _rigs) {
          rig.dispose();
        }
        _rigs.clear();
      }
    });

/// The toast showing, built into [tester]'s tree; returns its text.
Future<String> _toastText(WidgetTester tester, ShellToasts toasts) async {
  await tester.pumpWidget(shellHost(Builder(builder: (context) => toasts.current!.build(context, () {}))));
  return tester
      .widget<RichText>(find.descendant(of: find.byType(ZsToast), matching: find.byType(RichText)).first)
      .text
      .toPlainText();
}

RemoteRefChange _change(String name, {RemoteRefKind kind = RemoteRefKind.bookmark}) => RemoteRefChange(
  kind: kind,
  name: name,
  change: RemoteRefChangeKind.moved,
  oldCommitIds: const <String>['a'],
  newCommitId: 'b',
);

void main() {
  setUpIconRegistry();

  group('fetch', () {
    _rigTest('runs once with the default remotes; busy and syncing until the result; then the toast', (
      tester,
    ) async {
      final rig = _Rig();
      await tester.pump();
      expect(rig.model.canFetch, isTrue);
      rig.sync
        ..fetchGate = Completer<void>()
        ..fetchAnswer = () => fetchResult(bookmarks: <String>['main', 'x']);

      final Future<void> fetch = rig.model.fetch();
      await tester.pump();
      expect(rig.sync.log, <String>['fetch'], reason: 'one call, no remote passed (DefaultFetchRemotes)');
      expect(rig.model.fetching, isTrue);
      expect(rig.syncs, 1, reason: 'the dot reads syncing');
      rig.sync.emitProgress(const ProgressEvent(1, 'fetch', 0.4, ''));
      await tester.pump();
      expect(rig.model.fetchProgress, 0.4);

      rig.sync.fetchGate!.complete();
      await fetch;
      expect(rig.model.fetching, isFalse);
      expect(rig.syncs, 0);
      expect(rig.toasts.current?.tone, ZsToastTone.success);
      expect(await _toastText(tester, rig.toasts), 'Fetched from origin · 2 bookmarks changed');
    });

    _rigTest("a fetch that changed nothing says jj's \"Nothing changed.\"", (tester) async {
      final rig = _Rig();
      await tester.pump();
      await rig.model.fetch();
      expect(await _toastText(tester, rig.toasts), 'Nothing changed.');
    });

    _rigTest("a failure shows jj's text with Retry, keeps the badge; Retry fetches again", (tester) async {
      final rig = _Rig();
      await tester.pump();
      rig.sync.changes['origin'] = <RemoteRefChange>[_change('main')];
      await rig.model.poll();
      expect(rig.model.badge, 1);
      rig.sync.fetchAnswer = () => throw const ZanshinFfiException('jj.network_error', 'Could not resolve host');

      await rig.model.fetch();
      expect(rig.toasts.current?.tone, ZsToastTone.error);
      expect(rig.model.badge, 1, reason: 'nothing else changes');
      expect(await _toastText(tester, rig.toasts), 'Could not resolve host');
      rig.sync.fetchAnswer = fetchResult;
      await tester.tap(find.bySemanticsIdentifier('sync-toast-retry'));
      await tester.pump();
      await tester.pump();
      expect(rig.sync.log.where((call) => call == 'fetch'), hasLength(2));
      expect(rig.model.badge, isNull, reason: 'a successful fetch clears the badge');
    });

    _rigTest('no remote disables Fetch and Push; a stale working copy disables both', (tester) async {
      final rig = _Rig();
      rig.sync
        ..fetchRemoteNames = <String>[]
        ..names = <String>[];
      await rig.model.reloadRemotes();
      expect(rig.model.canFetch, isFalse);
      expect(rig.model.canPush, isFalse);

      final stale = _Rig();
      final source = ScriptedGraphSource()..respond = (_) => throw staleError('stale');
      stale.graph.init(source);
      await tester.pump();
      await tester.pump();
      expect(stale.graph.stale, isNotNull);
      expect(stale.model.stale, isTrue);
      expect(stale.model.canFetch, isFalse);
      expect(stale.model.canPush, isFalse);
    });
  });

  group('poll', () {
    _rigTest('ticks at the interval: remoteChanges per fetch remote, never a mutating call; the badge counts '
        'bookmarks, not tags', (tester) async {
      final rig = _Rig(
        configure: (sync) => sync
          ..fetchRemoteNames = <String>['origin', 'upstream']
          ..changes['origin'] = <RemoteRefChange>[
            _change('main'),
            _change('x'),
            _change('v1', kind: RemoteRefKind.tag),
          ],
      );
      await tester.pump();
      expect(rig.sync.log, isEmpty);

      await tester.pump(const Duration(minutes: 5));
      await tester.pump();
      expect(rig.sync.log, <String>['changes origin', 'changes upstream']);
      expect(rig.model.badge, 2);
      expect(rig.model.remoteChanges, <String, List<String>>{
        'origin': <String>['main', 'x'],
      });
      expect(rig.sync.pushes, isEmpty);
      expect(rig.sync.log.where((call) => call == 'fetch'), isEmpty);
    });

    _rigTest('Off runs no tick, not even on resume', (tester) async {
      final rig = _Rig(setting: RemotePollSetting.off);
      await tester.pump(const Duration(hours: 1));
      await rig.model.poll();
      expect(rig.sync.log, isEmpty);

      // An earlier poll's findings go with the setting.
      final on = _Rig(configure: (sync) => sync.changes['origin'] = <RemoteRefChange>[_change('main')]);
      await on.model.poll();
      expect(on.model.badge, 1);
      on.setting.value = RemotePollSetting.off;
      expect(on.model.badge, isNull);
      expect(on.model.remoteChanges, isEmpty);
    });

    _rigTest('a poll that began before a fetch drops its result; the badge stays clear', (tester) async {
      final rig = _Rig(configure: (sync) => sync.changes['origin'] = <RemoteRefChange>[_change('main')]);
      await tester.pump();
      rig.sync.changesGate = Completer<void>();
      final Future<void> poll = rig.model.poll();
      await tester.pump();
      await rig.model.fetch();
      rig.sync.changesGate!.complete();
      await poll;
      expect(rig.model.badge, isNull);
    });

    _rigTest('a failing tick is silent and leaves the badge; the next tick runs', (tester) async {
      final rig = _Rig();
      rig.sync.changes['origin'] = <RemoteRefChange>[_change('main')];
      await tester.pump(const Duration(minutes: 5));
      await tester.pump();
      expect(rig.model.badge, 1);

      rig.sync.changesError = const ZanshinFfiException('jj.network_error', 'offline');
      await tester.pump(const Duration(minutes: 5));
      await tester.pump();
      expect(rig.toasts.current, isNull);
      expect(rig.model.badge, 1);

      rig.sync.changesError = null;
      rig.sync.changes['origin'] = <RemoteRefChange>[];
      await tester.pump(const Duration(minutes: 5));
      await tester.pump();
      expect(rig.sync.log.where((call) => call == 'changes origin'), hasLength(3));
      expect(rig.model.badge, isNull);
    });

    _rigTest('a tick while one runs is skipped', (tester) async {
      final rig = _Rig();
      await tester.pump();
      rig.sync.changesGate = Completer<void>();
      unawaited(rig.model.poll());
      await tester.pump();
      await rig.model.poll();
      await tester.pump(const Duration(minutes: 5));
      expect(rig.sync.log, <String>['changes origin']);
      rig.sync.changesGate!.complete();
      await tester.pump();
    });

    _rigTest('a stale working copy runs no tick and hides the badge', (tester) async {
      final rig = _Rig();
      rig.sync.changes['origin'] = <RemoteRefChange>[_change('main')];
      await rig.model.poll();
      expect(rig.model.badge, 1);
      final source = ScriptedGraphSource()..respond = (_) => throw staleError('stale');
      rig.graph.init(source);
      await tester.pump();
      await tester.pump();
      expect(rig.model.badge, isNull);
      rig.sync.log.clear();
      await tester.pump(const Duration(minutes: 5));
      expect(rig.sync.log, isEmpty);
    });

    _rigTest('a changed interval reschedules', (tester) async {
      final rig = _Rig(setting: RemotePollSetting.fifteenMinutes);
      await tester.pump(const Duration(minutes: 5));
      expect(rig.sync.log, isEmpty);
      rig.setting.value = RemotePollSetting.fiveMinutes;
      await tester.pump(const Duration(minutes: 5));
      await tester.pump();
      expect(rig.sync.log, <String>['changes origin']);
    });
  });

  _rigTest('a fetch refused for a stale working copy shows no toast and ends not fetching', (tester) async {
    final rig = _Rig();
    await tester.pump();
    rig.sync.fetchAnswer = () => throw staleError('stale');
    await rig.model.fetch();
    expect(rig.toasts.current, isNull);
    expect(rig.model.fetching, isFalse);
  });

  group('push', () {
    /// Opens the sheet over a plan pushing `main`, pushes, and answers the real push with [result].
    Future<void> push(WidgetTester tester, _Rig rig, GitPushResult result) async {
      rig.sync.pushAnswer = (request) => request.dryRun
          ? pushResult(<String, List<PushRef>>{
              'origin': <PushRef>[pushRef('main')],
            })
          : result;
      await tester.pump();
      rig.model.openPush();
      for (var i = 0; i < 5; i++) {
        await tester.pump();
      }
      expect(rig.model.pushSheet!.canPush, isTrue);
      await rig.model.pushSheet!.push();
      final PushSheetModel sheet = rig.model.pushSheet!;
      if (sheet.phase == PushSheetPhase.done) {
        sheet.done();
      }
    }

    _rigTest('the pushed toast names the refs and remotes; Undo while recorded runs undoOperation at the push', (
      tester,
    ) async {
      final rig = _Rig();
      await push(
        tester,
        rig,
        pushResult(<String, List<PushRef>>{
          'origin': <PushRef>[pushRef('main', status: PushRefStatus.pushed)],
        }, recorded: true),
      );
      expect(rig.toasts.current?.tone, ZsToastTone.success);
      expect(await _toastText(tester, rig.toasts), 'Pushed main to origin');
      await tester.tap(find.bySemanticsIdentifier('sync-toast-undo'));
      await tester.pump();
      expect(rig.graph.undos.single.$1, 'pushop');
      expect(rig.graph.undos.single.$2.id, 'pushop');
    });

    _rigTest('an unrecorded push offers no Undo', (tester) async {
      final rig = _Rig();
      await push(
        tester,
        rig,
        pushResult(<String, List<PushRef>>{
          'origin': <PushRef>[pushRef('main', status: PushRefStatus.pushed)],
        }),
      );
      await _toastText(tester, rig.toasts);
      expect(find.bySemanticsIdentifier('sync-toast-undo'), findsNothing);
    });

    _rigTest('a failed push that recorded nothing shows no toast', (tester) async {
      final rig = _Rig();
      await push(
        tester,
        rig,
        pushResult(
          <String, List<PushRef>>{
            'origin': <PushRef>[pushRef('main')],
          },
          failure: const PushFailure(kind: PushFailureKind.pushError, message: 'Could not resolve host'),
        ),
      );
      expect(rig.toasts.current, isNull);
    });

    _rigTest('Undo after a foreign operation shows "nothing undone"', (tester) async {
      final rig = _Rig();
      rig.graph.undoAnswer = const GraphActionDisabled(GraphDisabledReason.foreignOperation);
      await push(
        tester,
        rig,
        pushResult(<String, List<PushRef>>{
          'origin': <PushRef>[pushRef('main', status: PushRefStatus.pushed)],
        }, recorded: true),
      );
      await _toastText(tester, rig.toasts);
      await tester.tap(find.bySemanticsIdentifier('sync-toast-undo'));
      await tester.pump();
      expect(rig.toasts.current?.tone, ZsToastTone.warn);
      expect(await _toastText(tester, rig.toasts), 'Nothing undone — another operation came after it');
    });
  });
}
