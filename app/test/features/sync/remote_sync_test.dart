// SPDX-License-Identifier: MIT

// RepoRemoteSync against the REAL worker isolate and cdylib (project-context "Worker / isolate testing"): a colocated
// repository with a bare `file://` remote. Dry runs plan without the network, so no git child runs. JJ_CONFIG,
// GIT_CONFIG_GLOBAL and XDG_CONFIG_HOME are pinned by Makefile.toml's test-flutter; the config test writes repo-scope
// jj config, which jj keeps under XDG_CONFIG_HOME, so it fails before any write when that is not pinned.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/src/features/settings/immutable_heads.dart' show effectiveConfigEntry;
import 'package:zanshin/src/features/sync/remote_sync.dart';
import 'package:zanshin_core/zanshin_core.dart';

void main() {
  late ZanshinWorker worker;
  late Directory temp;

  setUpAll(() async => worker = await ZanshinWorker.start());
  tearDownAll(() => worker.close());
  setUp(() async => temp = await Directory.systemTemp.createTemp('remote_sync_test'));
  tearDown(() => temp.delete(recursive: true));

  Future<void> git(String path, List<String> args) async {
    final ProcessResult result = await Process.run('git', <String>['-C', path, ...args]);
    if (result.exitCode != 0) {
      fail('git ${args.join(' ')} failed: ${result.stderr}');
    }
  }

  /// A colocated repository with one described commit on `main` and the bare remote `origin`, and its sync.
  Future<(String, RepoHandle, RemoteSync)> repo() async {
    final String root = temp.resolveSymbolicLinksSync();
    final path = '$root/repo';
    await Directory(path).create();
    await git(root, <String>['init', '--bare', '-b', 'main', 'origin.git']);
    await git(path, <String>['init', '-b', 'main']);
    await git(path, <String>['config', 'user.email', 'test@test.invalid']);
    await git(path, <String>['config', 'user.name', 'Test']);
    File('$path/README.md').writeAsStringSync('hello');
    await git(path, <String>['add', '.']);
    await git(path, <String>['commit', '-m', 'init', '--no-gpg-sign']);
    await git(path, <String>['remote', 'add', 'origin', 'file://$root/origin.git']);
    final RepoHandle handle = await worker.convert(path);
    addTearDown(handle.close);
    final sync = RepoRemoteSync(
      () => handle,
      config: (name) async => effectiveConfigEntry(
        await worker.configList(name: name, workspaceRoot: path, includeOverridden: true),
      )?.value,
    );
    return (path, handle, sync);
  }

  List<String> pushed(GitPushResult plan) => <String>[
    for (final PushRemote remote in plan.remotes)
      for (final PushRef ref in remote.refs)
        if (ref.path == PushPath.push) '${ref.kind.name} ${ref.name}',
  ];

  test('each mode reaches gitPush: the bare push sends no untracked bookmark, --all sends them', () async {
    final (_, RepoHandle handle, RemoteSync sync) = await repo();
    final WorkingCopyStatus status = await handle.status();
    await handle.bookmarkCreate(<String>['feature'], revision: status.parentChangeId);

    expect(await sync.remoteNames(), <String>['origin']);
    expect(await sync.pushRemotes(), <String>['origin']);
    expect(await sync.fetchRemotes(), <String>['origin']);

    final GitPushResult bare = await sync.push(const PushRequest(dryRun: true)).result;
    expect(pushed(bare), isEmpty);
    expect(bare.nothingChanged, isTrue);
    final GitPushResult all = await sync.push(const PushRequest(mode: PushMode.all, dryRun: true)).result;
    expect(pushed(all), containsAll(<String>['bookmark feature', 'bookmark main']));
    final GitPushResult tracked = await sync.push(const PushRequest(mode: PushMode.tracked, dryRun: true)).result;
    expect(pushed(tracked), isEmpty);
    final GitPushResult deleted = await sync.push(const PushRequest(mode: PushMode.deleted, dryRun: true)).result;
    expect(pushed(deleted), isEmpty);
  });

  test('a named bookmark goes as an exact pattern: a glob-like name matches only itself', () async {
    final (_, RepoHandle handle, RemoteSync sync) = await repo();
    final WorkingCopyStatus status = await handle.status();
    await handle.bookmarkCreate(<String>['f*'], revision: status.parentChangeId);
    await handle.bookmarkCreate(<String>['fun'], revision: status.parentChangeId);

    const request = PushRequest(mode: PushMode.custom, bookmarks: <String>['f*'], dryRun: true);
    expect(request.command, '''jj git push --bookmark 'exact:"f*"\'''');
    expect(request.bookmarkPatterns, <String>['exact:"f*"']);
    final GitPushResult plan = await sync.push(request).result;
    expect(pushed(plan), <String>['bookmark f*']);
  });

  test('pushConfig reads git.sign-on-push', () async {
    final String? xdg = Platform.environment['XDG_CONFIG_HOME'];
    if (xdg == null || !xdg.endsWith('/target/test-xdg-config')) {
      fail('XDG_CONFIG_HOME is not pinned to target/test-xdg-config — run via cargo make');
    }
    final (String path, _, RemoteSync sync) = await repo();
    expect((await sync.pushConfig()).signOnPush, isFalse);
    await worker.configSet(const ConfigScopeTarget(ConfigScope.repo), 'git.sign-on-push', 'true', workspaceRoot: path);
    expect((await sync.pushConfig()).signOnPush, isTrue);
  });
}
