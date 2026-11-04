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
  _Rig({void Function(FakeRemoteSync sync)? configure, RemotePollSetting poll = RemotePollSetting.off}) {
    configure?.call(sync);
    model = SyncModel(
      sync: sync,
      graph: graph,
      toasts: toasts,
      pollSetting: () => poll,
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
    expect(
      tester.widget<ZsCheckbox>(find.byType(ZsCheckbox).first).value,
      isTrue,
      reason: 'a sent row stays ticked in the done state (DS PushDialog.jsx:158)',
    );
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
                    rejection: rejected(<PushRejectReason>[
                      PushRejectReason.noDescription,
                      PushRejectReason.conflicts,
                    ]),
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

  group('Story 11.22 help for Git switchers', () {
    const untracked = PushRefusal(
      kind: PushRefusalKind.remoteUntracked,
      message: 'Non-tracking remote bookmark main@origin exists',
      hint: 'Run `jj bookmark track main@origin` to import the remote bookmark.',
    );
    const fresh = PushRefusal(
      kind: PushRefusalKind.newRemote,
      message: 'Refusing to create new remote bookmark fresh@origin',
      hint: 'Run `jj bookmark track fresh@origin` and try again.',
    );
    String text(WidgetTester tester, String id) =>
        tester.widget<Text>(find.descendant(of: _id(id), matching: find.byType(Text)).first).data!;

    /// Ralph's repository: `fresh` new (the bare push skips it, naming it pushes it) and `main` beside an untracked
    /// `main@origin` (refused named, too) — tracked once the fake saw the Track.
    GitPushResult Function(PushRequest) ralph(FakeRemoteSync sync) => (request) {
      final bool tracked = sync.log.contains('track main@origin');
      return pushResult(<String, List<PushRef>>{
        'origin': <PushRef>[
          if (request.mode == PushMode.bare)
            pushRef('fresh', action: 'add to 2d0dbb65bad8', path: PushPath.skip, refusal: fresh)
          else if (request.mode != PushMode.deleted)
            pushRef('fresh', action: 'add to 2d0dbb65bad8'),
          if (tracked)
            pushRef('main')
          else if (request.mode == PushMode.all)
            pushRef('main', action: null, path: PushPath.skip, refusal: untracked, explicitRefusal: untracked),
        ],
      });
    };

    testWidgets('a non-tracking remote: jj\'s text, the explanation and Track; Track re-plans to a forward move', (
      tester,
    ) async {
      final SemanticsHandle semantics = tester.ensureSemantics();
      late FakeRemoteSync fake;
      final _Rig rig = await open(tester, configure: (sync) => sync.pushAnswer = ralph(fake = sync));
      expect(
        text(tester, 'push-row-bookmark-main-refused'),
        'Non-tracking remote bookmark main@origin exists\n'
        'Run `jj bookmark track main@origin` to import the remote bookmark.',
      );
      expect(text(tester, 'push-row-bookmark-main-refused-help'), startsWith('In Git, main would follow origin/main.'));
      expect(find.text('Track main@origin'), findsOneWidget);
      final ZsTooltip tip = tester.widget<ZsTooltip>(
        find.ancestor(of: _id('push-fix-bookmark-main'), matching: find.byType(ZsTooltip)).first,
      );
      expect(tip.cmd, 'jj bookmark track main@origin');

      await tester.tap(find.text('Track main@origin'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(fake.log, contains('track main@origin'));
      expect(_id('push-row-bookmark-main-refused'), findsNothing);
      expect(find.text('move forward from aaaaaaaaaaaa to bbbbbbbbbbbb'), findsWidgets);
      rig.dispose();
      semantics.dispose();
    });

    testWidgets('as jj git push: the refusal shows at once, and ticking the new bookmark leaves it as it was', (
      tester,
    ) async {
      final SemanticsHandle semantics = tester.ensureSemantics();
      final _Rig rig = await open(tester, configure: (sync) => sync.pushAnswer = ralph(sync));
      expect(rig.model.pushSheet!.mode, PushMode.bare);
      final String refused = text(tester, 'push-row-bookmark-main-refused');
      expect(refused, startsWith('Non-tracking remote bookmark main@origin exists'));
      expect(
        text(tester, 'push-row-bookmark-fresh-skipped'),
        'Refusing to create new remote bookmark fresh@origin — tick it to push it anyway\n'
        'Run `jj bookmark track fresh@origin` and try again.',
      );
      expect(_id('push-fix-bookmark-fresh'), findsOneWidget, reason: 'Track for a new remote bookmark');

      await tester.tap(_id('push-row-bookmark-fresh-check'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(rig.model.pushSheet!.mode, PushMode.custom);
      expect(text(tester, 'push-row-bookmark-main-refused'), refused);
      rig.dispose();
      semantics.dispose();
    });

    testWidgets('an action names the change id before the dimmed commit id', (tester) async {
      final _Rig rig = await open(
        tester,
        configure: (sync) => sync.pushAnswer = (request) => pushResult(<String, List<PushRef>>{
          'origin': <PushRef>[
            pushRef(
              'main',
              action: 'add to 2d0dbb65bad8',
              after: '2d0dbb65bad8${'0' * 28}',
              afterChangeId: 'ksxypqwmzz',
            ),
          ],
        }),
      );
      expect(find.text('add to ksxypqwm 2d0dbb65bad8'), findsOneWidget);
      rig.dispose();
    });

    testWidgets('a forward move names both change ids, their prefixes bold, before the dimmed commit ids', (
      tester,
    ) async {
      final _Rig rig = await open(
        tester,
        configure: (sync) => sync.pushAnswer = (request) => pushResult(<String, List<PushRef>>{
          'origin': <PushRef>[
            pushRef(
              'main',
              before: 'a' * 40,
              after: 'b' * 40,
              beforeChangeId: 'qpvuntsmwlqt',
              afterChangeId: 'ksxypqwmzzzz',
              changePrefixLen: 2,
            ),
          ],
        }),
      );
      const line = 'move forward from qpvuntsm aaaaaaaaaaaa to ksxypqwm bbbbbbbbbbbb';
      expect(find.text(line), findsOneWidget);
      final Text text = tester.widget<Text>(find.text(line));
      final List<TextSpan> spans = (text.textSpan! as TextSpan).children!.cast<TextSpan>();
      final ZsColors colors = ZsColors.of(tester.element(find.text(line)));
      TextSpan span(String s) => spans.singleWhere((span) => span.text == s);
      for (final prefix in <String>['qp', 'ks']) {
        expect(span(prefix).style?.fontWeight, FontWeight.w600, reason: prefix);
      }
      for (final commit in <String>['a' * 12, 'b' * 12]) {
        expect(span(commit).style?.color, colors.textDim, reason: commit);
      }
      expect(spans.indexOf(span('qp')), lessThan(spans.indexOf(span('a' * 12))));
      expect(spans.indexOf(span('ks')), lessThan(spans.indexOf(span('b' * 12))));
      rig.dispose();
    });

    testWidgets('the git.sign-on-push note explains signing in Git terms', (tester) async {
      final SemanticsHandle semantics = tester.ensureSemantics();
      final _Rig rig = await open(tester, configure: (sync) => sync.config = const PushConfig(signOnPush: true));
      expect(find.textContaining('Like git commit -S, but at push time'), findsOneWidget);
      rig.dispose();
      semantics.dispose();
    });

    /// One refused row per refusal kind and one rejected row per reason kind: each shows its explanation.
    final cases = <(String, PushRef, String)>[
      (
        'local conflicted',
        pushRef(
          'main',
          action: null,
          path: PushPath.skip,
          refusal: const PushRefusal(kind: PushRefusalKind.localConflicted, message: 'Bookmark main is conflicted'),
        ),
        'Your main points at more than one commit',
      ),
      (
        'remote conflicted',
        pushRef(
          'main',
          action: null,
          path: PushPath.skip,
          refusal: const PushRefusal(
            kind: PushRefusalKind.remoteConflicted,
            message: 'Bookmark main@origin is conflicted',
          ),
        ),
        "origin's main moved two ways since your last fetch.",
      ),
      (
        'remote untracked',
        pushRef('main', action: null, path: PushPath.skip, refusal: untracked),
        'In Git, main would follow origin/main.',
      ),
      ('new remote', pushRef('fresh', path: PushPath.skip, refusal: fresh), 'Like a Git branch without an upstream'),
      (
        'deleted',
        pushRef(
          'old',
          action: 'delete from aaaaaaaaaaaa',
          path: PushPath.skip,
          refusal: const PushRefusal(kind: PushRefusalKind.deleted, message: 'Refusing to push deleted bookmark old'),
        ),
        'You deleted old here.',
      ),
      (
        'no description',
        pushRef('wip', path: PushPath.skip, rejection: rejected(<PushRejectReason>[PushRejectReason.noDescription])),
        'Describe it first, or allow it.',
      ),
      (
        'no description on @',
        pushRef(
          'wip',
          path: PushPath.skip,
          rejection: rejected(<PushRejectReason>[PushRejectReason.noDescription], workingCopy: true),
        ),
        '@ is your working copy',
      ),
      (
        'no author',
        pushRef('wip', path: PushPath.skip, rejection: rejected(<PushRejectReason>[PushRejectReason.noAuthor])),
        'Git would take your name from user.name and user.email',
      ),
      (
        'conflicts',
        pushRef('wip', path: PushPath.skip, rejection: rejected(<PushRejectReason>[PushRejectReason.conflicts])),
        'jj keeps conflicts inside commits',
      ),
      (
        'private',
        pushRef('wip', path: PushPath.skip, rejection: rejected(<PushRejectReason>[PushRejectReason.private])),
        'Your git.private-commits setting keeps this commit off remotes.',
      ),
    ];
    for (final (String name, PushRef row, String help) in cases) {
      testWidgets('$name: the explanation shows', (tester) async {
        final _Rig rig = await open(
          tester,
          configure: (sync) => sync.pushAnswer = (request) => pushResult(<String, List<PushRef>>{
            'origin': <PushRef>[if (request.mode == PushMode.bare) row],
          }),
        );
        expect(find.textContaining(help), findsOneWidget);
        rig.dispose();
      });
    }

    testWidgets('a conflicted remote fetches; a deleted bookmark offers --deleted', (tester) async {
      final SemanticsHandle semantics = tester.ensureSemantics();
      late FakeRemoteSync fake;
      final _Rig rig = await open(
        tester,
        configure: (sync) => (fake = sync).pushAnswer = (request) => pushResult(<String, List<PushRef>>{
          'origin': <PushRef>[
            if (request.mode == PushMode.bare) ...<PushRef>[
              pushRef(
                'main',
                action: null,
                path: PushPath.skip,
                refusal: const PushRefusal(
                  kind: PushRefusalKind.remoteConflicted,
                  message: 'Bookmark main@origin is conflicted',
                ),
              ),
              pushRef(
                'old',
                action: 'delete from aaaaaaaaaaaa',
                path: PushPath.skip,
                refusal: const PushRefusal(
                  kind: PushRefusalKind.deleted,
                  message: 'Refusing to push deleted bookmark old',
                ),
              ),
            ],
          ],
        }),
      );
      expect(find.text('Fetch'), findsOneWidget);
      await tester.tap(_id('push-fix-bookmark-main'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(fake.log, contains('fetch'));
      expect(find.text('Push with --deleted'), findsOneWidget);
      await tester.tap(_id('push-fix-bookmark-old'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(rig.model.pushSheet!.mode, PushMode.deleted);
      rig.dispose();
      semantics.dispose();
    });
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

  testWidgets('the island shows the poll badge, the changes per remote, the fetch progress, and "No remote"', (
    tester,
  ) async {
    useShellWindow(tester);
    ZsIconButton button(String id) =>
        tester.widget<ZsIconButton>(find.ancestor(of: _id(id), matching: find.byType(ZsIconButton)).first);
    ZsTooltip tip(String id) =>
        tester.widget<ZsTooltip>(find.ancestor(of: _id(id), matching: find.byType(ZsTooltip)).first);
    RemoteRefChange moved(String name) => RemoteRefChange(
      kind: RemoteRefKind.bookmark,
      name: name,
      change: RemoteRefChangeKind.moved,
      oldCommitIds: const <String>['a'],
      newCommitId: 'b',
    );
    final rig = _Rig(
      poll: RemotePollSetting.fiveMinutes,
      configure: (sync) => sync.changes['origin'] = <RemoteRefChange>[moved('main'), moved('x')],
    );
    await tester.pumpWidget(rig.host());
    await tester.pump();
    await rig.model.poll();
    await tester.pump();
    expect(button('sync-fetch').badge, 2);
    expect(tip('sync-fetch').message, 'Fetch from origin\nmain, x changed on origin');

    rig.sync.fetchGate = Completer<void>();
    final Future<void> fetch = rig.model.fetch();
    await tester.pump();
    rig.sync.emitProgress(const ProgressEvent(1, 'fetch', 0.4, ''));
    await tester.pump();
    expect(button('sync-fetch').busy, isTrue);
    expect(tip('sync-fetch').message, 'Fetching… 40%');
    rig.sync.fetchGate!.complete();
    await fetch;
    await tester.pump();
    expect(button('sync-fetch').busy, isFalse);
    rig.dispose();
    await tester.pumpWidget(const SizedBox());

    final none = _Rig(
      configure: (sync) => sync
        ..fetchRemoteNames = <String>[]
        ..pushRemoteNames = <String>[]
        ..names = <String>[],
    );
    await tester.pumpWidget(none.host());
    await tester.pump();
    for (final id in <String>['sync-fetch', 'sync-push']) {
      expect(button(id).onPressed, isNull, reason: id);
      expect(button(id).disabledReason, 'No remote', reason: id);
    }
    none.dispose();
  });
}
