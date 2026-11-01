// SPDX-License-Identifier: MIT

// RepoGraphSource against the REAL worker isolate and cdylib (project-context "Worker / isolate testing"): temp
// repositories with the native backend; JJ_CONFIG, GIT_CONFIG_GLOBAL and XDG_CONFIG_HOME are pinned by Makefile.toml's
// test-flutter. The layout stays a counting fake until 10.12.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/src/features/graph/graph_layout.dart' show GraphCommitContent;
import 'package:zanshin/src/features/graph/graph_ports.dart';
import 'package:zanshin/src/features/graph/graph_view_model.dart';
import 'package:zanshin/src/features/projects/project_repos.dart';
import 'package:zanshin/src/features/projects/worker_project_repos.dart';
import 'package:zanshin/src/features/undo_timeline/undo_timeline_model.dart';
import 'package:zanshin_core/zanshin_core.dart';

import '../../helpers/scripted_graph_source.dart';

/// Waits (real time) until [done] holds, at most 10 s.
Future<void> until(bool Function() done) async {
  for (var i = 0; i < 500 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  expect(done(), isTrue);
}

/// Lets the watcher's debounced events of what just ran arrive.
Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 600));

/// The content port until 10.12 adopts `commitContents`: these tests read no content.
Future<Map<String, GraphCommitContent>> _noContent(String? operationId, List<String> commitIds) async =>
    const <String, GraphCommitContent>{};

void main() {
  late ZanshinWorker worker;
  late WorkerProjectRepos repos;
  late Directory temp;

  setUpAll(() async {
    worker = await ZanshinWorker.start();
    repos = WorkerProjectRepos(Future<ZanshinWorker>.value(worker));
  });

  tearDownAll(() => worker.close());

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('graph_ports_test');
  });

  tearDown(() => temp.delete(recursive: true));

  String pathOf(String name) => '${temp.resolveSymbolicLinksSync()}/$name';

  /// A new native-backend repository [name], open through the project adapter.
  Future<ProjectRepo> openRepo(String name) async {
    final String path = pathOf(name);
    await Directory(path).create();
    await (await worker.initRepo(path, backend: 0)).close();
    final ProjectRepo repo = await repos.open(path);
    addTearDown(repo.close);
    return repo;
  }

  Future<void> describeAt(ProjectRepo repo, String description) async {
    final WorkingCopyStatus status = await repo.handle.status();
    await repo.handle.describe(changeId: status.workingCopyChangeId!, description: description);
  }

  test('a describe through the handle fires exactly one more layout request', () async {
    final ProjectRepo repo = await openRepo('describe');
    final requests = <GraphRequest>[];
    final source = RepoGraphSource(
      repo,
      layout: (request) async {
        requests.add(request);
        return GraphLoad(keysLayout(<String>['x'], at: 'x'));
      },
      content: _noContent,
    );
    final model = GraphViewModel()..init(source);
    addTearDown(model.dispose);
    await until(() => model.layout != null);
    final LogDefaults defaults = await repo.handle.logDefaults();
    expect(requests.first.revset, defaults.log, reason: 'the effective revsets.log, read through the handle');
    await settle();
    final int before = requests.length;

    await describeAt(repo, 'from the graph test');
    await settle();
    expect(requests, hasLength(before + 1));
  });

  test("the source's events are its own handle's, every kind", () async {
    final ProjectRepo a = await openRepo('a');
    final ProjectRepo b = await openRepo('b');
    final events = <RepoEvent>[];
    final StreamSubscription<RepoEvent> subscription = RepoGraphSource(
      a,
      layout: (_) => throw UnimplementedError(),
      content: _noContent,
    ).events.listen(events.add);
    addTearDown(subscription.cancel);

    await describeAt(b, 'in b');
    await settle();
    expect(events, isEmpty);

    await describeAt(a, 'in a');
    await settle();
    expect(events.whereType<OpHeadsChangedEvent>(), isNotEmpty);

    // A heartbeat (the stale state's exit) comes through too: re-write the checkout file with the same bytes, the
    // recipe of worker_project_repos_test.dart's heartbeat test.
    events.clear();
    final checkout = File('${pathOf('a')}/.jj/working_copy/checkout');
    checkout.writeAsBytesSync(checkout.readAsBytesSync());
    await until(() => events.whereType<WorkingCopyHeartbeatEvent>().isNotEmpty);
    expect(events.every((event) => event.handleId == a.handle.handleId), isTrue);
  });

  test('updateStale passes through: a fresh working copy is not stale', () async {
    final ProjectRepo repo = await openRepo('fresh');
    final StaleRecovery recovery = await RepoGraphSource(
      repo,
      layout: (_) => throw UnimplementedError(),
      content: _noContent,
    ).updateStale();
    expect(recovery.outcome, StaleRecoveryOutcome.notStale);
  });

  // Story 10.9: RepoGraphActions over the opened handle, through GraphViewModel.run, then the reload. `RepoHandle` is a
  // final class with no fake, so the mapping is witnessed here.
  test(
    'GraphEdit through RepoGraphActions and the model moves @, then requests a layout; its undo moves it back',
    () async {
      final ProjectRepo repo = await openRepo('action');
      final String first = (await repo.handle.status()).workingCopyChangeId!;
      final String second = (await repo.handle.newChange(<String>[first])).newChangeIds.single;
      final requests = <GraphRequest>[];
      final model = GraphViewModel()
        ..init(
          RepoGraphSource(
            repo,
            layout: (request) async {
              requests.add(request);
              return GraphLoad(keysLayout(<String>[second, first], at: second));
            },
            content: _noContent,
          ),
          actions: RepoGraphActions(repo),
        );
      addTearDown(model.dispose);
      await until(() => model.layout != null);
      await settle();
      final int before = requests.length;

      expect(await model.run(GraphEdit(first)), isA<GraphActionDone>());
      expect((await repo.handle.status()).workingCopyChangeId, first);
      await until(() => requests.length > before);

      expect(model.undoable?.action, isA<GraphEdit>());
      expect(await model.undoLast(), isA<GraphActionDone>());
      expect((await repo.handle.status()).workingCopyChangeId, second);
      expect(await model.redoLast(), isA<GraphActionDone>());
      expect((await repo.handle.status()).workingCopyChangeId, first);
    },
  );

  group('RepoGraphActions maps each verb to its handle call (real repo)', () {
    /// A repo with `first` (holding a file) under @ `second`, and a model running actions on it.
    Future<(ProjectRepo, GraphViewModel, String, String)> setUpRepo(String name) async {
      final ProjectRepo repo = await openRepo(name);
      File('${pathOf(name)}/a.txt').writeAsStringSync('a\n');
      final String first = (await repo.handle.status()).workingCopyChangeId!;
      final String second = (await repo.handle.newChange(<String>[first])).newChangeIds.single;
      final model = GraphViewModel()
        ..init(
          RepoGraphSource(
            repo,
            layout: (_) async => GraphLoad(keysLayout(<String>[second, first], at: second)),
            content: _noContent,
          ),
          actions: RepoGraphActions(repo),
        );
      addTearDown(model.dispose);
      await until(() => model.layout != null);
      return (repo, model, first, second);
    }

    test('bookmark delete of a glob-like name deletes only that name', () async {
      final (ProjectRepo repo, GraphViewModel model, String first, _) = await setUpRepo('delete');
      await repo.handle.bookmarkCreate(<String>['f*', 'foo'], revision: first);
      expect(await model.run(const GraphBookmarkDelete(<String>['f*'])), isA<GraphActionDone>());
      expect((await repo.handle.bookmarks()).map((b) => b.name), <String>['foo']);
    });

    test("revert lands the new change as @'s parent", () async {
      final (ProjectRepo repo, GraphViewModel model, String first, _) = await setUpRepo('revert');
      final GraphActionResult result = await model.run(GraphRevert(first));
      final String born = (result as GraphActionDone).outcome.born.single;
      expect((await repo.handle.status()).parentChangeId, born);
    });

    Future<String> descriptionOf(ProjectRepo repo, String id) async =>
        (await repo.handle.show(revset: id)).single.change.description.trim();

    Future<Map<String, String?>> bookmarksOf(ProjectRepo repo) async => <String, String?>{
      for (final Bookmark bookmark in await repo.handle.bookmarks()) bookmark.name: bookmark.target,
    };

    test('describe sets the description of its change', () async {
      final (ProjectRepo repo, GraphViewModel model, String first, _) = await setUpRepo('describe-action');
      expect(await model.run(GraphDescribe(first, 'from the runner')), isA<GraphActionDone>());
      expect(await descriptionOf(repo, first), 'from the runner');
    });

    test('abandon removes its change', () async {
      final (ProjectRepo repo, GraphViewModel model, String first, _) = await setUpRepo('abandon');
      expect(await model.run(GraphAbandon(<String>[first])), isA<GraphActionDone>());
      expect((await repo.handle.status()).parentChangeId, isNot(first));
    });

    test('squash -r -m -k: the message lands on the destination and the emptied source stays', () async {
      final (ProjectRepo repo, GraphViewModel model, String first, String second) = await setUpRepo('squash');
      // jj squashes nothing (and sets no message) from an empty source kept with -k: give @ a file.
      File('${pathOf('squash')}/b.txt').writeAsStringSync('b\n');
      final GraphActionResult result = await model.run(
        GraphSquash(revision: second, message: const <String>['squashed'], keepEmptied: true),
      );
      expect(result, isA<GraphActionDone>());
      expect(await descriptionOf(repo, first), 'squashed');
      expect((await repo.handle.status()).workingCopyChangeId, second);
    });

    test('new with no target sits on @ (the CLI default)', () async {
      final (ProjectRepo repo, GraphViewModel model, _, String second) = await setUpRepo('new-at');
      final GraphActionResult result = await model.run(const GraphNew());
      final WorkingCopyStatus status = await repo.handle.status();
      expect(status.workingCopyChangeId, (result as GraphActionDone).outcome.born.single);
      expect(status.parentChangeId, second);
    });

    test('bookmark create -r, move of a glob-like name, rename', () async {
      final (ProjectRepo repo, GraphViewModel model, String first, String second) = await setUpRepo('bookmarks');
      expect(
        await model.run(GraphBookmarkCreate(const <String>['f*', 'foo'], revision: first)),
        isA<GraphActionDone>(),
      );
      expect(await bookmarksOf(repo), <String, String?>{'f*': first, 'foo': first});

      expect(await model.run(GraphBookmarkMove(const <String>['f*'], to: second)), isA<GraphActionDone>());
      expect(await bookmarksOf(repo), <String, String?>{'f*': second, 'foo': first});

      expect(await model.run(const GraphBookmarkRename('foo', 'bar')), isA<GraphActionDone>());
      expect(await bookmarksOf(repo), <String, String?>{'bar': first, 'f*': second});
    });

    for (final (String name, GraphAction Function(String first, String second) action)
        in <(String, GraphAction Function(String, String))>[
          ('-A', (first, _) => GraphNew(insertAfter: <String>[first])),
          ('-B', (_, second) => GraphNew(insertBefore: <String>[second])),
        ]) {
      test('new $name inserts the new @ between first and second', () async {
        final (ProjectRepo repo, GraphViewModel model, String first, String second) = await setUpRepo('new$name');
        final GraphActionResult result = await model.run(action(first, second));
        final String born = (result as GraphActionDone).outcome.born.single;
        final WorkingCopyStatus status = await repo.handle.status();
        expect(status.workingCopyChangeId, born);
        expect(status.parentChangeId, first);
      });
    }

    test(
      'the Undo Timeline: undoOperation undoes the logged head, restoreOperation restores by the short id',
      () async {
        final (ProjectRepo repo, GraphViewModel model, String first, _) = await setUpRepo('timeline');
        final source = RepoUndoTimelineSource(repo);
        final Operation before = (await source.opLog(limit: 1)).single;
        expect(await model.run(GraphDescribe(first, 'described')), isA<GraphActionDone>());
        final Operation head = (await source.opLog(limit: 1)).single;
        expect(await model.undoOperation(head.id, loggedOperation(head)), isA<GraphActionDone>());
        expect(await descriptionOf(repo, first), isEmpty);

        expect(await model.run(GraphDescribe(first, 'again')), isA<GraphActionDone>());
        expect(await model.restoreOperation(shortOperationId(before.id)), isA<GraphActionDone>());
        expect(await descriptionOf(repo, first), isEmpty);
        expect(
          () => RepoGraphActions(repo).run(const GraphLoggedOperation('ff', 'x')),
          throwsArgumentError,
          reason: 'an op-log entry is not a verb',
        );
      },
    );
  });

  group('Story 10.9: each action is one jj v0.46.0 command, its ids POSIX shell-quoted', () {
    test('the verbs', () {
      expect(const GraphEdit('kmnvxoqp').command, 'jj edit kmnvxoqp');
      expect(const GraphDescribe('kmnvxoqp', 'fix: x').command, "jj describe kmnvxoqp -m 'fix: x'");
      expect(const GraphNew(parents: <String>['aaa', 'bbb']).command, 'jj new aaa bbb');
      expect(
        const GraphNew(insertAfter: <String>['aaa'], insertBefore: <String>['bbb', 'ccc']).command,
        'jj new -A aaa -B bbb -B ccc',
      );
      expect(const GraphAbandon(<String>['aaa', 'bbb']).command, 'jj abandon aaa bbb');
      expect(const GraphRevert('rrr').command, 'jj revert -r rrr -B @');
      expect(const GraphSquash(revision: 'sss').command, 'jj squash -r sss');
      expect(const GraphSquash().command, 'jj squash');
      expect(
        const GraphSquash(
          from: <String>['s1', 's2'],
          into: 'ttt',
          paths: <String>['src/a.dart', 'my file', r'q"\'],
          message: <String>['one', 'two'],
          keepEmptied: true,
          editedDescription: 'not shown',
        ).command,
        'jj squash --from s1 --from s2 --into ttt -m one -m two -k root:src/a.dart \'root:"my file"\' '
        r"""'root:"q\"\\"'""",
      );
      expect(const GraphSquash(into: 'ttt', useDestinationMessage: true).command, 'jj squash --into ttt -u');
      expect(
        const GraphBookmarkCreate(<String>['main', 'my topic'], revision: 'kkk').command,
        'jj bookmark create main \'"my topic"\' -r kkk',
      );
      expect(const GraphBookmarkCreate(<String>['main']).command, 'jj bookmark create main');
      expect(
        const GraphBookmarkRename('old', 'new', overwriteExisting: true).command,
        'jj bookmark rename old new --overwrite-existing',
      );
      expect(const GraphUndo(GraphEdit('k')).command, 'jj undo');
      expect(const GraphRedo(GraphEdit('k')).command, 'jj redo');
      expect(const GraphOpRestore('1a2b3c4d5e6f').command, 'jj op restore 1a2b3c4d5e6f');
      expect(jjOpShowCommand('1a2b3c4d5e6f'), 'jj op show 1a2b3c4d5e6f');
      expect(const GraphLoggedOperation('ff', 'new empty commit', args: 'jj new main').command, 'jj new main');
      expect(const GraphLoggedOperation('ff', 'new empty commit').command, 'new empty commit');
      expect(const GraphUndo(GraphLoggedOperation('ff', 'x')).command, 'jj undo');
    });

    test('a bookmark name with glob characters is exact: in the command and in the patterns jj gets', () {
      const delete = GraphBookmarkDelete(<String>['feat*', 'v[1]', 'what?', 'main']);
      expect(delete.patterns, <String>['exact:"feat*"', 'exact:"v[1]"', 'exact:"what?"', 'main']);
      expect(delete.command, 'jj bookmark delete \'exact:"feat*"\' \'exact:"v[1]"\' \'exact:"what?"\' main');
      expect(
        const GraphBookmarkMove(<String>['feat*'], from: <String>['fff'], to: 'kkk', allowBackwards: true).command,
        'jj bookmark move \'exact:"feat*"\' --from fff --to kkk --allow-backwards',
      );
      expect(const GraphBookmarkMove(<String>['main']).command, 'jj bookmark move main');
      // jj-core's is_glob_char also counts `]`, `{`, `}`: `{a,b}` bare would delete `a` and `b`.
      expect(const GraphBookmarkDelete(<String>['{a,b}', 'x]']).patterns, <String>['exact:"{a,b}"', 'exact:"x]"']);
    });

    test('shell quoting: a single quote, a leading dash, an empty text, a newline', () {
      expect(const GraphDescribe('k', "it's").command, r"jj describe k -m 'it'\''s'");
      expect(const GraphDescribe('k', '-x').command, 'jj describe k --message=-x');
      expect(const GraphDescribe('k', '').command, "jj describe k -m ''");
      expect(const GraphDescribe('k', '=x').command, "jj describe k -m '=x'", reason: "zsh's EQUALS expansion");
      expect(const GraphDescribe('k', 'a=x').command, 'jj describe k -m a=x');
      expect(const GraphDescribe('k', 'a\nb').command, "jj describe k -m 'a\nb'");
      expect(const GraphBookmarkCreate(<String>['-x']).command, 'jj bookmark create \'"-x"\'');
    });

    test("describe paragraphs: the CLI's join_message_paragraphs and one -m per paragraph (Story 10.8)", () {
      expect(joinMessageParagraphs(<String>['S', 'D']), 'S\n\nD\n');
      expect(joinMessageParagraphs(<String>['S']), 'S\n');
      expect(joinMessageParagraphs(<String>['S\n', 'D']), 'S\n\nD\n', reason: 'a paragraph ending in \\n keeps one');
      expect(joinMessageParagraphs(<String>['']), '');
      final describe = GraphDescribe.fromParagraphs('k', const <String>['S', 'two words']);
      expect(describe.description, 'S\n\ntwo words\n');
      expect(describe.command, "jj describe k -m S -m 'two words'");
      // The exact text the parity oracle's `describe_gui_text` scenario
      // (crates/zanshin-parity/tests/oracle/scenarios.rs) sends against `jj describe -m 'C described' -m Details`.
      expect(
        GraphDescribe.fromParagraphs('k', const <String>['C described', 'Details']).description,
        'C described\n\nDetails\n',
      );
    });

    test('pending keys are the changes the action names', () {
      expect(const GraphEdit('a').pendingKeys, <String>{'a'});
      expect(const GraphNew(parents: <String>['a'], insertBefore: <String>['b']).pendingKeys, <String>{'a', 'b'});
      expect(const GraphAbandon(<String>['a', 'b']).pendingKeys, <String>{'a', 'b'});
      expect(const GraphSquash(from: <String>['s'], into: 't').pendingKeys, <String>{'s', 't'});
      expect(const GraphSquash().pendingKeys, isEmpty);
      expect(const GraphBookmarkMove(<String>['m'], to: 'k').pendingKeys, <String>{'k'});
      expect(const GraphUndo(GraphEdit('a')).pendingKeys, isEmpty);
    });
  });
}
