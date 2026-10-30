// SPDX-License-Identifier: MIT

// RepoGraphSource against the REAL worker isolate and cdylib (project-context "Worker / isolate testing"): temp
// repositories with the native backend; JJ_CONFIG, GIT_CONFIG_GLOBAL and XDG_CONFIG_HOME are pinned by Makefile.toml's
// test-flutter. The layout stays a counting fake until 10.12.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/src/features/graph/graph_ports.dart';
import 'package:zanshin/src/features/graph/graph_view_model.dart';
import 'package:zanshin/src/features/projects/project_repos.dart';
import 'package:zanshin/src/features/projects/worker_project_repos.dart';
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
    ).updateStale();
    expect(recovery.outcome, StaleRecoveryOutcome.notStale);
  });
}
