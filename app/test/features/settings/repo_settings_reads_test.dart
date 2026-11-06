// SPDX-License-Identifier: MIT

// RepoSettingsReads.revsetMembers on the REAL worker isolate and cdylib, over an in-test native-backend repository.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/src/features/projects/project_repos.dart';
import 'package:zanshin/src/features/projects/worker_project_repos.dart';
import 'package:zanshin/src/features/settings/immutable_heads.dart';
import 'package:zanshin/src/features/settings/settings_view_model.dart';
import 'package:zanshin_core/zanshin_core.dart';

void main() {
  test("revsetMembers maps each commit's refs, shortest change id prefix and root flag", () async {
    final ZanshinWorker worker = await ZanshinWorker.start();
    final Directory dir = Directory.systemTemp.createTempSync('zanshin_settings_reads_');
    final String path = dir.resolveSymbolicLinksSync();
    await (await worker.initRepo(path, backend: 0)).close();
    final ProjectRepo repo = await WorkerProjectRepos(Future<ZanshinWorker>.value(worker)).open(path);
    try {
      final String at = (await repo.handle.status()).workingCopyChangeId!;
      await repo.handle.bookmarkCreate(<String>['feature'], revision: at);
      final reads = RepoSettingsReads(repo);

      final RevsetMember member = (await reads.revsetMembers('@')).single;
      expect(member.refs.map((ref) => (ref.name, ref.kind, ref.remote)), <(String, TopologyRefKind, String?)>[
        ('feature', TopologyRefKind.bookmark, null),
      ]);
      expect(member.changeIdPrefix.length, inExclusiveRange(0, at.length), reason: 'the shortest prefix, not the id');
      expect(at.startsWith(member.changeIdPrefix), isTrue);
      expect(member.isRoot, isFalse);

      final RevsetMember root = (await reads.revsetMembers('root()')).single;
      expect(root.isRoot, isTrue);
      expect(headLabels(<RevsetMember>[root]), <String>['root()']);
    } finally {
      await repo.close();
      await worker.close();
      dir.deleteSync(recursive: true);
    }
  });

  test('the remote verbs add, rename, set the URL of and remove a remote; remotes() reflects each', () async {
    final ZanshinWorker worker = await ZanshinWorker.start();
    final Directory dir = Directory.systemTemp.createTempSync('zanshin_settings_remotes_');
    final String path = dir.resolveSymbolicLinksSync();
    await (await worker.initRepo(path, backend: 1, noColocate: true)).close();
    final ProjectRepo repo = await WorkerProjectRepos(Future<ZanshinWorker>.value(worker)).open(path);
    try {
      final reads = RepoSettingsReads(repo);
      List<(String, String?, String?)> rows(List<Remote> remotes) => <(String, String?, String?)>[
        for (final Remote remote in remotes) (remote.name, remote.url, remote.pushUrl),
      ];

      expect(await reads.remoteAdd(name: 'upstream', url: 'https://example.com/a.git'), isEmpty);
      expect(rows(await reads.remotes()), <(String, String?, String?)>[
        ('upstream', 'https://example.com/a.git', null),
      ]);

      final List<ZanshinWarning> duplicate = await reads.remoteAdd(name: 'twin', url: 'https://example.com/a.git');
      expect(duplicate.single.code, ZanshinWarningCode.remoteUrlDuplicate);
      await reads.remoteRemove('twin');

      await reads.remoteRename('upstream', 'fork');
      expect(rows(await reads.remotes()), <(String, String?, String?)>[('fork', 'https://example.com/a.git', null)]);

      await reads.remoteSetUrl(name: 'fork', url: 'https://example.com/b.git');
      expect(rows(await reads.remotes()), <(String, String?, String?)>[('fork', 'https://example.com/b.git', null)]);

      await expectLater(
        reads.remoteRename('fork', 'git'),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'jj.invalid_input')),
      );

      await reads.remoteRemove('fork');
      expect(await reads.remotes(), isEmpty);
    } finally {
      await repo.close();
      await worker.close();
      dir.deleteSync(recursive: true);
    }
  });
}
