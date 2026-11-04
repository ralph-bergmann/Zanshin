// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/src/features/sync/push_sheet_model.dart';
import 'package:zanshin/src/features/sync/remote_sync.dart';
import 'package:zanshin_core/zanshin_core.dart';

import '../../helpers/fake_remote_sync.dart';

const ({PushRefKind kind, String name}) _main = (kind: PushRefKind.bookmark, name: 'main');
const ({PushRefKind kind, String name}) _wip = (kind: PushRefKind.bookmark, name: 'wip');
const ({PushRefKind kind, String name}) _feature = (kind: PushRefKind.bookmark, name: 'feature');
const ({PushRefKind kind, String name}) _v1 = (kind: PushRefKind.tag, name: 'v1');

/// The plans of a repository with `main` to push, `wip` skipped for its empty description, `feature` new (only `--all`,
/// and refused when named: tracked nowhere is fine, here it is tracked elsewhere) and the tag `v1`.
GitPushResult _plans(PushRequest request) {
  final List<String> remotes = request.remotes ?? const <String>['origin'];
  List<PushRef> rows(String remote) {
    final upstream = remote == 'upstream';
    return switch (request.mode) {
      PushMode.bare => <PushRef>[
        pushRef('main'),
        pushRef(
          'wip',
          path: PushPath.skip,
          rejection: rejected(<PushRejectReason>[PushRejectReason.noDescription]),
        ),
        pushRef('v1', kind: PushRefKind.tag, action: 'add to dddddddddddd'),
        if (upstream)
          pushRef(
            'feature',
            path: PushPath.skip,
            refusal: const PushRefusal(
              kind: PushRefusalKind.newRemote,
              message: 'Refusing to create new remote bookmark feature@upstream',
              hint: 'Run `jj bookmark track feature@upstream` and try again.',
            ),
          ),
      ],
      PushMode.tracked => <PushRef>[pushRef('main')],
      PushMode.all => <PushRef>[
        pushRef('main'),
        pushRef(
          'feature',
          action: 'add to eeeeeeeeeeee',
          explicitRefusal: const PushRefusal(
            kind: PushRefusalKind.newRemote,
            message: 'Refusing to create new remote bookmark feature@origin',
            hint: 'Run `jj bookmark track feature@origin` and try again.',
          ),
        ),
      ],
      PushMode.deleted => const <PushRef>[],
      PushMode.custom => <PushRef>[
        if (request.changes.isNotEmpty || request.named.isNotEmpty)
          pushRef(
            'push-ovknlmro',
            action: 'add to ffffffffffff',
            path: request.allowEmptyDescription ? PushPath.push : PushPath.abort,
            rejection: rejected(<PushRejectReason>[PushRejectReason.noDescription], workingCopy: true),
          ),
        for (final String name in request.bookmarks) pushRef(name),
        for (final String name in request.tags) pushRef(name, kind: PushRefKind.tag),
      ],
    };
  }

  return pushResult(
    <String, List<PushRef>>{for (final String remote in remotes) remote: rows(remote)},
    created: <PushCreatedBookmark>[
      if (request.changes.isNotEmpty) const PushCreatedBookmark(name: 'push-ovknlmro', changeId: 'ovknlmro'),
    ],
  );
}

/// The sheet over a fake port answering [_plans], with @ as its change row.
Future<(PushSheetModel, FakeRemoteSync, List<GitPushResult>)> _sheet({
  void Function(FakeRemoteSync sync)? configure,
}) async {
  final sync = FakeRemoteSync()..pushAnswer = _plans;
  configure?.call(sync);
  final pushed = <GitPushResult>[];
  final model = PushSheetModel(sync: sync, change: (id: 'ovknlmro', rev: '@'), onPushed: pushed.add);
  addTearDown(model.dispose);
  await model.load();
  await pumpEventQueue();
  return (model, sync, pushed);
}

void main() {
  test(
    'opening plans with dry runs only; the preselection is the bare plan, a skipped ref keeps `jj git push`',
    () async {
      final (PushSheetModel model, FakeRemoteSync sync, _) = await _sheet();

      expect(sync.pushes, isEmpty, reason: 'nothing pushes before Push');
      expect(sync.log, everyElement(endsWith('--dry-run')));
      expect(model.rows, containsAll(<PushRowKey>[_main, _wip, _v1, _feature]));
      expect(model.sent(_main), isTrue);
      expect(model.sent(_v1), isTrue, reason: 'a tag row');
      expect(model.sent(_wip), isFalse);
      expect(model.skippedOn(_wip, 'origin'), isNull, reason: 'a commit-check skip carries no refusal');
      expect(model.rejectionOf(_wip)?.reasonKinds, <PushRejectReason>[PushRejectReason.noDescription]);
      expect(model.request.command, 'jj git push');
      expect(model.canPush, isTrue, reason: 'the dry run of the command passed');
    },
  );

  test('a hand-picked refused row cannot be ticked', () async {
    final (PushSheetModel model, _, _) = await _sheet();
    expect(model.tickable(_feature), isFalse);
    model.toggle(_feature);
    expect(model.mode, PushMode.bare);
    expect(model.sent(_feature), isFalse);
  });

  test('an allowed reason adds its flag, also on the bare command, and sends the skipped ref', () async {
    final (PushSheetModel model, _, _) = await _sheet();
    model.setAllow(PushAllow.emptyDescription, true);
    expect(model.sent(_wip), isTrue);
    expect(model.mode, PushMode.bare);
    expect(model.request.command, 'jj git push --allow-empty-description');
  });

  test('a hand-pick makes "As jj git push" inactive and names the refs; a bulk flag waits for its dry run', () async {
    final (PushSheetModel model, FakeRemoteSync sync, _) = await _sheet();
    model.toggle(_main);
    expect(model.mode, PushMode.custom);
    expect(model.request.command, 'jj git push --tag v1', reason: 'main unticked, v1 still named');
    model.toggle(_main);
    expect(model.request.command, 'jj git push --bookmark main --tag v1');

    final gate = Completer<void>();
    sync.pushAnswer = (request) {
      unawaited(gate.future);
      return _plans(request);
    };
    model.setMode(PushMode.tracked);
    expect(model.request.command, 'jj git push --tracked');
    expect(model.canPush, isFalse, reason: 'its dry run is still out');
    await pumpEventQueue();
    expect(sync.log.last, 'jj git push --tracked --dry-run');
    expect(model.canPush, isTrue);
  });

  test('two remotes: one line each; a skip on one remote marks only its line', () async {
    final (PushSheetModel model, FakeRemoteSync sync, _) = await _sheet(
      configure: (sync) => sync.names = <String>['origin', 'upstream'],
    );
    expect(model.chosen, <String>['origin']);
    model.toggleRemote('upstream');
    await pumpEventQueue();
    expect(model.chosen, <String>['origin', 'upstream']);
    expect(model.request.command, 'jj git push --remote origin --remote upstream');
    expect(model.refOn(_main, 'origin'), isNotNull);
    expect(model.refOn(_main, 'upstream'), isNotNull);
    expect(model.skippedOn(_feature, 'upstream'), isNotNull);
    expect(model.skippedOn(_feature, 'origin'), isNull);
    expect(sync.log, contains('jj git push --remote origin --remote upstream --dry-run'));
  });

  test('several remotes where one gets nothing: the sheet names it, Push stays enabled (I4)', () async {
    final (PushSheetModel model, FakeRemoteSync sync, _) = await _sheet(
      configure: (sync) => sync.names = <String>['origin', 'upstream'],
    );
    expect(model.emptyRemotes, isEmpty, reason: 'one remote warns nothing');
    sync.pushAnswer = (request) => request.mode == PushMode.tracked && (request.remotes?.length ?? 1) > 1
        ? pushResult(<String, List<PushRef>>{
            'origin': <PushRef>[pushRef('main')],
            'upstream': const <PushRef>[],
          })
        : _plans(request);
    model.toggleRemote('upstream');
    await pumpEventQueue();
    model.setMode(PushMode.tracked);
    await pumpEventQueue();
    expect(model.emptyRemotes, <String>['upstream']);
    expect(model.canPush, isTrue, reason: 'the verb keeps the CLI behaviour; the sheet only warns');
  });

  test('an undescribed change is refused with an Allow; the flag joins once it is ticked', () async {
    final (PushSheetModel model, _, _) = await _sheet();
    expect(model.generatedName, 'push-ovknlmro');
    expect(model.changeRejection?.reasons, <String>['has no description']);
    expect(model.changeTickable, isFalse);
    model.setChange(true);
    expect(model.changeOn, isFalse);

    model.setAllow(PushAllow.emptyDescription, true);
    expect(model.changeTickable, isTrue);
    model.setMode(PushMode.tracked);
    expect(model.request.command, 'jj git push --tracked', reason: 'no sent ref needs the flag yet');
    model.setChange(true);
    expect(model.mode, PushMode.custom, reason: 'the change is named, so the refs are too');
    expect(model.request.command, 'jj git push --bookmark main --change @ --allow-empty-description');

    model.setName('mine');
    expect(model.request.command, 'jj git push --bookmark main --named mine=@ --allow-empty-description');
    model.setName('push-ovknlmro');
    expect(model.named, isFalse, reason: 'the generated name typed back stays generated');
    expect(model.request.command, 'jj git push --bookmark main --change @ --allow-empty-description');
  });

  test('Push runs the command once; a full success finishes and reports', () async {
    final (PushSheetModel model, FakeRemoteSync sync, List<GitPushResult> pushed) = await _sheet();
    sync
      ..pushAnswer = ((request) => request.dryRun
          ? _plans(request)
          : pushResult(<String, List<PushRef>>{
              'origin': <PushRef>[pushRef('main', status: PushRefStatus.pushed)],
            }, recorded: true))
      ..pushGate = Completer<void>();
    final Future<void> push = model.push();
    await pumpEventQueue();
    expect(model.phase, PushSheetPhase.pushing);
    model.cancel();
    expect(model.closing, isFalse, reason: 'Esc and Cancel are inert while pushing');
    sync.pushGate!.complete();
    await push;
    expect(sync.pushes, <String>['jj git push']);
    expect(pushed.single.recorded, isTrue);
    expect(model.closing, isTrue);
  });

  test('a partial push stays as done until Done; nothing recorded is reported as such', () async {
    final (PushSheetModel model, FakeRemoteSync sync, List<GitPushResult> pushed) = await _sheet(
      configure: (sync) => sync.names = <String>['origin', 'upstream'],
    );
    sync.pushAnswer = (request) => request.dryRun
        ? _plans(request)
        : pushResult(
            <String, List<PushRef>>{
              'origin': <PushRef>[pushRef('main', status: PushRefStatus.pushed)],
              'upstream': <PushRef>[pushRef('main')],
            },
            failure: const PushFailure(kind: PushFailureKind.pushError, message: 'Failed to push some bookmarks'),
            errors: <String, String>{'upstream': 'Could not resolve host'},
            finished: <String>{'origin'},
          );
    await model.push();
    expect(model.phase, PushSheetPhase.done);
    expect(model.result?.recorded, isFalse);
    expect(pushed, isEmpty);
    model.done();
    expect(pushed, hasLength(1));
    expect(model.closing, isTrue);
  });

  test('a refusal before the network keeps the sheet ready with jj\'s text', () async {
    final (PushSheetModel model, FakeRemoteSync sync, _) = await _sheet();
    sync.pushAnswer = (request) => request.dryRun
        ? _plans(request)
        : throw const ZanshinFfiException('jj.push_commit_rejected', "Won't push commit cccccccccccc");
    await model.push();
    expect(model.phase, PushSheetPhase.ready);
    expect(model.pushError?.code, 'jj.push_commit_rejected');
  });

  test("a default remote no remote carries passes no --remote and shows jj's refusal", () async {
    final (PushSheetModel model, FakeRemoteSync sync, _) = await _sheet(
      configure: (sync) => sync
        ..names = <String>['upstream']
        ..pushAnswer = (request) => request.remotes == null
            ? throw const ZanshinFfiException('jj.invalid_input', 'No git remote named \'origin\'')
            : _plans(request),
    );
    expect(model.chosen, <String>['origin']);
    expect(sync.log, isNotEmpty);
    expect(sync.log, everyElement(isNot(contains('--remote'))), reason: 'no explicit --remote list');
    expect(model.planError?.context, "No git remote named 'origin'");
    expect(model.canPush, isFalse);
  });

  group('Story 11.22 fix-its', () {
    const untracked = PushRefusal(
      kind: PushRefusalKind.remoteUntracked,
      message: 'Non-tracking remote bookmark main@origin exists',
      hint: 'Run `jj bookmark track main@origin` to import the remote bookmark.',
    );

    /// A Git switcher's repository: `main` skipped beside an untracked `main@origin` until it is tracked.
    GitPushResult Function(PushRequest) switcher(bool Function() tracked) =>
        (request) => pushResult(
          <String, List<PushRef>>{
            'origin': <PushRef>[
              if (tracked())
                pushRef('main')
              else
                pushRef('main', action: null, path: PushPath.skip, refusal: untracked, explicitRefusal: untracked),
            ],
          },
        );

    test('Track runs jj bookmark track on the refusal\'s remote, then re-plans', () async {
      late FakeRemoteSync fake;
      final (PushSheetModel model, FakeRemoteSync sync, _) = await _sheet(
        configure: (sync) => (fake = sync).pushAnswer = switcher(() => fake.log.contains('track main@origin')),
      );
      expect(model.explicitRefusalOf(_main), (refusal: untracked, remote: 'origin'));
      expect(model.sent(_main), isFalse);

      await model.track(_main, 'main@origin');
      expect(sync.log, contains('track main@origin'));
      expect(model.sent(_main), isTrue);
      expect(model.refOn(_main, 'origin')?.action, 'move forward from aaaaaaaaaaaa to bbbbbbbbbbbb');
      expect(model.explicitRefusalOf(_main), isNull);
    });

    test('a failed Track keeps the sheet ready with jj\'s text on the row', () async {
      final (PushSheetModel model, FakeRemoteSync sync, _) = await _sheet(
        configure: (sync) => sync
          ..pushAnswer = switcher(() => false)
          ..trackError = const ZanshinFfiException('jj.invalid_input', 'No such remote bookmark'),
      );
      final int plans = sync.log.length;
      await model.track(_main, 'main@origin');
      expect(model.phase, PushSheetPhase.ready);
      expect(model.fixing, isNull);
      expect(model.fixErrorOf(_main), 'No such remote bookmark');
      expect(sync.log.length, plans + 1, reason: 'no re-plan after a failed fix-it');
    });

    test(
      'while a Track runs the sheet is busy: no Push, a second Track is ignored; a re-plan clears an old error',
      () async {
        final (PushSheetModel model, FakeRemoteSync sync, _) = await _sheet(
          configure: (sync) => sync
            ..names = <String>['origin', 'upstream']
            ..pushAnswer = switcher(() => false)
            ..trackError = const ZanshinFfiException('jj.invalid_input', 'refused'),
        );
        await model.track(_main, 'main@origin');
        expect(model.fixErrorOf(_main), 'refused');
        model.toggleRemote('upstream');
        await pumpEventQueue();
        expect(model.fixErrorOf(_main), isNull, reason: 'the plans changed');
        model.toggleRemote('upstream');
        await pumpEventQueue();

        sync
          ..trackError = null
          ..trackGate = Completer<void>();
        final Future<void> first = model.track(_main, 'main@origin');
        await pumpEventQueue();
        expect(model.fixing, _main);
        expect(model.canPush, isFalse);
        await model.track(_main, 'main@origin');
        expect(sync.log.where((entry) => entry.startsWith('track')), hasLength(2), reason: 'the second is ignored');
        sync.trackGate!.complete();
        await first;
        expect(model.fixing, isNull);
        expect(model.fixErrorOf(_main), isNull);
      },
    );

    test('a non-FFI failure of a fix-it does not leave the sheet busy', () async {
      final (PushSheetModel model, FakeRemoteSync sync, _) = await _sheet(
        configure: (sync) => sync.pushAnswer = switcher(() => false),
      );
      sync.fetchAnswer = () => throw StateError('closed');
      await expectLater(model.fetchAndReplan(_main), throwsStateError);
      expect(model.fixing, isNull);
    });

    test('Fetch fetches, then re-plans', () async {
      final (PushSheetModel model, FakeRemoteSync sync, _) = await _sheet();
      final int before = sync.log.length;
      await model.fetchAndReplan(_main);
      expect(sync.log[before], 'fetch');
      expect(sync.log.skip(before + 1), contains(endsWith('--dry-run')));
      expect(model.phase, PushSheetPhase.ready);
    });

    test('Allow is chosen by the reason kind, not by jj\'s text', () {
      expect(PushAllow.of(PushRejectReason.noDescription), PushAllow.emptyDescription);
      expect(PushAllow.of(PushRejectReason.private), PushAllow.private);
      expect(PushAllow.of(PushRejectReason.conflicts), PushAllow.conflicts);
      expect(PushAllow.of(PushRejectReason.noAuthor), isNull);
    });
  });

  test('a failing dry run of the composed command keeps Push disabled with its text', () async {
    final (PushSheetModel model, FakeRemoteSync sync, _) = await _sheet();
    sync.pushAnswer = (request) => request.mode == PushMode.custom
        ? throw const ZanshinFfiException('jj.invalid_input', 'bad pattern')
        : _plans(request);
    model.toggle(_main);
    await pumpEventQueue();
    expect(model.canPush, isFalse);
    expect(model.checkError, 'bad pattern');

    sync.pushAnswer = (request) => request.mode == PushMode.tracked
        ? pushResult(
            <String, List<PushRef>>{
              'origin': <PushRef>[pushRef('main', path: PushPath.abort)],
            },
            failure: const PushFailure(kind: PushFailureKind.refRefused, message: 'refused', hint: 'a hint'),
          )
        : _plans(request);
    model.setMode(PushMode.tracked);
    await pumpEventQueue();
    expect(model.canPush, isFalse);
    expect(model.checkError, 'refused\na hint');
  });
}
