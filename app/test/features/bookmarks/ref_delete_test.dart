// SPDX-License-Identifier: MIT

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/src/features/bookmarks/bookmark_list_model.dart';
import 'package:zanshin/src/features/bookmarks/ref_delete.dart';
import 'package:zanshin/src/features/graph/graph_ports.dart';
import 'package:zanshin/src/features/sync/remote_sync.dart';
import 'package:zanshin_core/zanshin_core.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

import '../../helpers/fake_bookmark_list.dart';
import '../../helpers/icon_registry.dart';
import '../../helpers/shell_host.dart';

List<String> _commands(RefDeleteRequest request, RefDeleteChoice choice) =>
    refDeleteCommands(refDeleteSteps(request, choice));

void main() {
  setUpIconRegistry();

  group('the request', () {
    test('"has a remote" means a tracked remote of that name, never git', () {
      final request = RefDeleteRequest.of(RefKind.bookmark, 'feat', <Bookmark>[
        localRow('feat', 'k1'),
        remoteRow('feat', 'origin', 'k1'),
        remoteRow('feat', 'git', 'k1'),
        remoteRow('feat', 'fork', 'k1', tracked: false),
        remoteRow('other', 'upstream', 'k1'),
      ]);
      expect(request.remotes, <String>['origin']);
      expect(request.asks, isTrue);
      expect(RefDeleteRequest.of(RefKind.bookmark, 'wip', <Bookmark>[localRow('wip', 'k1')]).asks, isFalse);
    });
  });

  group('the steps', () {
    const bookmark = RefDeleteRequest(kind: RefKind.bookmark, name: 'feature/auth-flow', remotes: <String>['origin']);
    const tag = RefDeleteRequest(kind: RefKind.tag, name: 'v1.5.0-rc1', remotes: <String>['origin', 'upstream']);

    test('a bookmark: forget; delete; delete and push', () {
      expect(_commands(bookmark, RefDeleteChoice.onlyHere), <String>['jj bookmark forget feature/auth-flow']);
      expect(_commands(bookmark, RefDeleteChoice.onPush), <String>['jj bookmark delete feature/auth-flow']);
      expect(_commands(bookmark, RefDeleteChoice.now), <String>[
        'jj bookmark delete feature/auth-flow',
        'jj git push --remote origin --bookmark feature/auth-flow',
      ]);
      expect(refDeleteSteps(bookmark, RefDeleteChoice.now).push?.mode, PushMode.custom);
    });

    test('a tag on two remotes: untrack each, then delete; delete; delete and one push to both', () {
      expect(_commands(tag, RefDeleteChoice.onlyHere), <String>[
        'jj tag untrack v1.5.0-rc1@origin',
        'jj tag untrack v1.5.0-rc1@upstream',
        'jj tag delete v1.5.0-rc1',
      ]);
      expect(_commands(tag, RefDeleteChoice.onPush), <String>['jj tag delete v1.5.0-rc1']);
      expect(_commands(tag, RefDeleteChoice.now), <String>[
        'jj tag delete v1.5.0-rc1',
        'jj git push --remote origin --remote upstream --tag v1.5.0-rc1',
      ]);
    });

    test('a glob-like name goes as an exact pattern', () {
      const glob = RefDeleteRequest(kind: RefKind.bookmark, name: 'fix*', remotes: <String>['origin']);
      expect(_commands(glob, RefDeleteChoice.onlyHere), <String>['jj bookmark forget \'exact:"fix*"\'']);
    });
  });

  group('the runner', () {
    test('runs every step in order; a refused step stops the rest, the push included', () async {
      final rig = BookmarkRig(FakeBookmarkListSource(const <Bookmark>[]));
      addTearDown(rig.dispose);
      await pumpEventQueue();
      const tag = RefDeleteRequest(kind: RefKind.tag, name: 'v1', remotes: <String>['origin', 'upstream']);
      expect(await rig.deletes.run(tag, RefDeleteChoice.onlyHere), isTrue);
      expect(rig.actions.ran.map((a) => a.command), <String>[
        'jj tag untrack v1@origin',
        'jj tag untrack v1@upstream',
        'jj tag delete v1',
      ]);

      rig.actions.ran.clear();
      rig.actions.refuse.add('jj tag untrack v1@origin');
      expect(await rig.deletes.run(tag, RefDeleteChoice.onlyHere), isFalse);
      expect(rig.actions.ran.map((a) => a.command), <String>['jj tag untrack v1@origin']);

      rig.actions.ran.clear();
      rig.actions.refuse.add('jj tag delete v1');
      expect(await rig.deletes.run(tag, RefDeleteChoice.now), isFalse);
      expect(rig.pushes, isEmpty, reason: 'the delete was refused: nothing pushes');
    });

    test('a failed push reports false; without a push port the push step fails', () async {
      final ran = <String>[];
      Future<GraphActionResult> run(GraphAction action) async {
        ran.add(action.command);
        return const GraphActionDone(GraphOutcome(GraphNew()));
      }

      final RefDeleteSteps steps = refDeleteSteps(
        const RefDeleteRequest(kind: RefKind.bookmark, name: 'x', remotes: <String>['origin']),
        RefDeleteChoice.now,
      );
      expect(await runRefDeleteSteps(steps, run: run, push: (_) async => false), isFalse);
      expect(await runRefDeleteSteps(steps, run: run), isFalse);
      expect(ran, <String>['jj bookmark delete x', 'jj bookmark delete x']);
    });

    test('the flow asks only with a tracked remote; Cancel runs nothing', () async {
      final rig = BookmarkRig(FakeBookmarkListSource(const <Bookmark>[]));
      addTearDown(rig.dispose);
      await pumpEventQueue();
      const asked = RefDeleteRequest(kind: RefKind.bookmark, name: 'feat', remotes: <String>['origin']);
      rig.deletes.delete(asked);
      expect(rig.deletes.pending, same(asked));
      rig.deletes.cancel();
      expect(rig.deletes.pending, isNull);
      rig.deletes.delete(asked);
      rig.deletes.confirm(RefDeleteChoice.onlyHere);
      await pumpEventQueue();
      expect(rig.actions.ran.map((a) => a.command), <String>['jj bookmark forget feat']);
    });
  });

  testWidgets('the sheet: title, body, three choices with commands and notes, the middle one chosen; ⌘↩ confirms', (
    tester,
  ) async {
    useShellWindow(tester);
    final chosen = <RefDeleteChoice>[];
    await tester.pumpWidget(
      shellHost(
        RefDeleteSheet(
          request: const RefDeleteRequest(
            kind: RefKind.tag,
            name: 'v1.5.0-rc1',
            remotes: <String>['origin', 'upstream'],
          ),
          onConfirm: chosen.add,
          onCancel: () {},
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Delete v1.5.0-rc1?'), findsOneWidget);
    expect(find.text('The tag is also on origin, upstream. Where should it go?'), findsOneWidget);
    expect(find.text('Only here — keep it on origin, upstream', findRichText: true), findsOneWidget);
    expect(
      find.text('Here, and on origin, upstream when you push the deletion  default', findRichText: true),
      findsOneWidget,
    );
    expect(find.text('Here and on origin, upstream now', findRichText: true), findsOneWidget);
    expect(find.text('Can\'t be undone: origin, upstream loses the tag.'), findsOneWidget);
    expect(
      find.text('jj tag delete v1.5.0-rc1\njj git push --remote origin --remote upstream --tag v1.5.0-rc1'),
      findsOneWidget,
    );
    // The "now" choice in the danger tone.
    final Text now = tester.widget<Text>(
      find.ancestor(of: find.text('Here and on origin, upstream now', findRichText: true), matching: find.byType(Text)),
    );
    expect(now.style?.color, ZsColors.night.rem);
    expect(tester.widget<ZsConfirmDialog>(find.byType(ZsConfirmDialog)).tone, ZsConfirmTone.destructive);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.meta);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.meta);
    expect(chosen, <RefDeleteChoice>[RefDeleteChoice.onPush]);

    await tester.tap(find.text('Only here — keep it on origin, upstream', findRichText: true));
    await tester.pump();
    await tester.tap(find.widgetWithText(ZsButton, 'Delete'));
    await tester.pump();
    expect(chosen.last, RefDeleteChoice.onlyHere);
  });
}
