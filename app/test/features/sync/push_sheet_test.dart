// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/src/features/graph/graph_view_model.dart';
import 'package:zanshin/src/features/shell/floating_shell.dart';
import 'package:zanshin/src/features/shell/shell_controller.dart';
import 'package:zanshin/src/features/shell/shell_toast.dart';
import 'package:zanshin/src/features/sync/push_sheet.dart';
import 'package:zanshin/src/features/sync/remote_sync.dart';
import 'package:zanshin/src/features/sync/sync_island.dart';
import 'package:zanshin/src/features/sync/sync_model.dart';
import 'package:zanshin_core/zanshin_core.dart';
import 'package:zanshin_settings/zanshin_settings.dart' show RemotePollSetting;
import 'package:zanshin_ui/zanshin_ui.dart';

import '../../helpers/fake_remote_sync.dart';
import '../../helpers/icon_registry.dart';
import '../../helpers/scripted_graph_source.dart';
import '../../helpers/shell_host.dart';

/// Story 11.8's island and sheet in a floating shell over a fake port.
class _Rig {
  _Rig({void Function(FakeRemoteSync sync)? configure}) {
    configure?.call(sync);
    model = SyncModel(
      sync: sync,
      graph: graph,
      toasts: toasts,
      pollSetting: () => RemotePollSetting.off,
      changeTarget: () => (id: 'ovknlmro', rev: '@'),
    );
  }

  final sync = FakeRemoteSync();
  final graph = GraphViewModel();
  final toasts = ShellToasts();
  final shell = ShellController();
  late final SyncModel model;

  Widget host() => shellHost(
    FloatingShell(
      controller: shell,
      graph: PushSheetHost(sync: model, child: const SizedBox.expand()),
      syncGroup: SyncIsland(onReload: () {}, sync: model),
    ),
  );

  void dispose() {
    model.dispose();
    graph.dispose();
    toasts.dispose();
    shell.dispose();
  }
}

GitPushResult _bare(PushRequest request) => pushResult(<String, List<PushRef>>{
  for (final String remote in request.remotes ?? const <String>['origin'])
    remote: <PushRef>[if (request.mode != PushMode.deleted) pushRef('main')],
});

Finder _id(String identifier) => find.bySemanticsIdentifier(identifier);

void main() {
  setUpIconRegistry();

  Future<_Rig> open(WidgetTester tester, {void Function(FakeRemoteSync sync)? configure}) async {
    useShellWindow(tester);
    final rig = _Rig(
      configure: (sync) {
        sync.pushAnswer = _bare;
        configure?.call(sync);
      },
    );
    await tester.pumpWidget(rig.host());
    await tester.pump();
    await tester.tap(_id('sync-push'));
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    return rig;
  }

  testWidgets('Push opens the sheet, which holds calm; Esc while pushing and a scrim click do nothing', (tester) async {
    final SemanticsHandle semantics = tester.ensureSemantics();
    final _Rig rig = await open(tester);
    expect(_id('push-sheet'), findsOneWidget);
    expect(rig.sync.pushes, isEmpty, reason: 'nothing pushes before the sheet\'s Push');
    expect(rig.shell.calm.held, isTrue);
    expect(find.text('jj git push'), findsOneWidget);

    rig.sync
      ..pushGate = Completer<void>()
      ..pushAnswer = (request) => request.dryRun
          ? _bare(request)
          : pushResult(<String, List<PushRef>>{
              'origin': <PushRef>[pushRef('main', status: PushRefStatus.pushed)],
            }, recorded: true);
    await tester.tap(_id('push-submit'));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.tapAt(const Offset(20, 880));
    await tester.pump();
    expect(rig.model.pushSheet?.closing, isFalse);
    expect(_id('push-sheet'), findsOneWidget);

    rig.sync.pushGate!.complete();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(_id('push-sheet'), findsNothing);
    expect(rig.shell.calm.held, isFalse, reason: 'the hold ends with the sheet');
    expect(rig.toasts.current, isNotNull, reason: 'the result toast');
    rig.dispose();
    semantics.dispose();
  });

  testWidgets('Cancel closes it and releases calm; a scrim click before does nothing', (tester) async {
    final _Rig rig = await open(tester);
    await tester.tapAt(const Offset(20, 880));
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(PushSheet), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(PushSheet), findsNothing);
    expect(rig.shell.calm.held, isFalse);
    rig.dispose();
  });

  testWidgets('a partial push with nothing exported shows no Undo sentence and names the remote that stopped it', (
    tester,
  ) async {
    final _Rig rig = await open(tester, configure: (sync) => sync.names = <String>['origin', 'upstream']);
    await tester.tap(_id('push-remote-upstream'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    rig.sync.pushAnswer = (request) => request.dryRun
        ? _bare(request)
        : pushResult(
            <String, List<PushRef>>{
              'origin': <PushRef>[pushRef('main', status: PushRefStatus.pushed)],
              'upstream': <PushRef>[pushRef('main')],
            },
            failure: const PushFailure(kind: PushFailureKind.pushError, message: 'Failed to push to upstream'),
            errors: <String, String>{'upstream': 'Could not resolve host'},
            finished: <String>{'origin'},
          );
    await tester.tap(_id('push-submit'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    final String note = tester
        .widget<Text>(
          find.descendant(of: _id('push-done-note'), matching: find.byType(Text)),
        )
        .data!;
    expect(note, contains('The push stopped at upstream. origin already got their refs.'));
    expect(note, contains('Nothing was recorded.'));
    expect(note, isNot(contains('Undo')));
    expect(find.text('Done'), findsOneWidget);
    rig.dispose();
  });

  testWidgets('a recorded partial push says Undo works', (tester) async {
    final _Rig rig = await open(tester);
    rig.sync.pushAnswer = (request) => request.dryRun
        ? _bare(request)
        : pushResult(
            <String, List<PushRef>>{
              'origin': <PushRef>[
                pushRef('main', status: PushRefStatus.leaseRejected, statusReason: 'stale info'),
              ],
            },
            recorded: true,
            failure: const PushFailure(
              kind: PushFailureKind.someRefsFailed,
              message: 'Failed to push some bookmarks',
              hint:
                  'Try fetching from the remote, then make the bookmark point to where you want it to be, and '
                  'push again.',
            ),
          );
    await tester.tap(_id('push-submit'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    final String note = tester
        .widget<Text>(
          find.descendant(of: _id('push-done-note'), matching: find.byType(Text)),
        )
        .data!;
    expect(note, contains('The push is recorded, so Undo works as usual.'));
    expect(find.text('moved on origin'), findsOneWidget);
    rig.dispose();
  });

  testWidgets('focus starts on Push; ↩ pushes, but not from the name field', (tester) async {
    final _Rig rig = await open(tester);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'Push');

    // The change row ticked, its name field focused: ↩ there does not push.
    await tester.tap(_id('push-change-check'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.descendant(of: _id('push-change-name'), matching: find.byType(EditableText)));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(rig.sync.pushes, isEmpty);

    // Back on Push: ↩ pushes.
    tester
        .widget<ZsButton>(find.ancestor(of: _id('push-submit'), matching: find.byType(ZsButton)).first)
        .focusNode!
        .requestFocus();
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'Push');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(rig.sync.pushes, hasLength(1));
    rig.dispose();
  });

  testWidgets('two reasons on the change show the chip row', (tester) async {
    final _Rig rig = await open(
      tester,
      configure: (sync) => sync.pushAnswer = (request) => request.changes.isEmpty
          ? _bare(request)
          : pushResult(
              <String, List<PushRef>>{
                'origin': <PushRef>[
                  pushRef(
                    'push-ovknlmro',
                    path: PushPath.abort,
                    rejection: rejected(<String>['has no description', 'has conflicts']),
                  ),
                ],
              },
              created: const <PushCreatedBookmark>[PushCreatedBookmark(name: 'push-ovknlmro', changeId: 'ovknlmro')],
            ),
    );
    expect(_id('push-allow-emptyDescription'), findsOneWidget);
    expect(_id('push-allow-conflicts'), findsOneWidget);
    expect(find.text('Allow empty descriptions'), findsOneWidget);
    expect(find.text('Allow'), findsNothing, reason: 'no short inline chip with two reasons');
    expect(find.text('push-ovknlmro'), findsOneWidget, reason: 'the name field stays below');
    rig.dispose();
  });

  testWidgets('the Fetch tooltip has no shortcut; a stale working copy disables both with its reason', (tester) async {
    final SemanticsHandle semantics = tester.ensureSemantics();
    useShellWindow(tester);
    final rig = _Rig();
    await tester.pumpWidget(rig.host());
    await tester.pump();
    final ZsTooltip fetch = tester.widget<ZsTooltip>(
      find.ancestor(of: _id('sync-fetch'), matching: find.byType(ZsTooltip)).first,
    );
    expect(fetch.shortcut, isNull);
    expect(fetch.cmd, 'jj git fetch');
    expect(tester.getSemantics(_id('sync-fetch')), isSemantics(isEnabled: true));

    rig.graph.init(ScriptedGraphSource()..respond = (_) => throw staleError('stale'));
    await tester.pump();
    await tester.pump();
    expect(rig.model.stale, isTrue);
    for (final id in <String>['sync-fetch', 'sync-push']) {
      final ZsIconButton button = tester.widget<ZsIconButton>(
        find.ancestor(of: _id(id), matching: find.byType(ZsIconButton)).first,
      );
      expect(button.onPressed, isNull, reason: id);
      expect(button.disabledReason, 'Working copy is stale', reason: id);
    }
    rig.dispose();
    semantics.dispose();
  });
}
