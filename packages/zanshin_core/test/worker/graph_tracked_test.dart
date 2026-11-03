// SPDX-License-Identifier: MIT

// Story 11.21 witness: `TopologyRef.tracked` reaches Dart through the REAL
// Isolate.spawn flow against the REAL compiled cdylib.
//
// The workspace is a colocated jj init over a `git clone` of a local bare
// remote (the `remote_changes_test` recipe), so its view holds `main@origin`
// and `x@origin`; local main is one commit ahead, `main@origin` is then
// tracked, `x@origin` stays untracked.
//
// JJ_CONFIG="" and XDG_CONFIG_HOME (a throwaway dir under target/) are pinned
// externally by Makefile.toml.

import 'dart:io';

import 'package:test/test.dart';
import 'package:zanshin_core/src/ffi/graph.dart';
import 'package:zanshin_core/src/worker/handle.dart';
import 'package:zanshin_core/src/worker/isolate.dart';

Future<void> git(List<String> args, String dir) async {
  final ProcessResult result = await Process.run('git', ['-C', dir, ...args]);
  if (result.exitCode != 0) {
    throw StateError('git ${args.join(' ')} failed: ${result.stderr}');
  }
}

void main() {
  late ZanshinWorker worker;
  late Directory tempDir;

  setUpAll(() {
    Platform.environment['XDG_CONFIG_HOME'] ?? fail('XDG_CONFIG_HOME is not pinned — run via cargo make');
  });

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('zanshin_graph_tracked_test_');
    worker = await ZanshinWorker.start();
  });

  tearDown(() async {
    await worker.close();
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  test('a tracked remote ref reads tracked, an untracked one and the local entry do not (real cdylib)', () async {
    final String base = tempDir.resolveSymbolicLinksSync();
    final source = '$base/src';
    Directory(source).createSync();
    await git(['init', '-b', 'main'], source);
    await git(['config', 'user.email', 'test@test.invalid'], source);
    await git(['config', 'user.name', 'Test'], source);
    File('$source/README.md').writeAsStringSync('hello\n');
    await git(['add', '.'], source);
    await git(['commit', '-m', 'initial', '--no-gpg-sign'], source);
    await git(['branch', 'x'], source);
    final bare = '$base/remote.git';
    await git(['clone', '--bare', source, bare], base);
    final root = '$base/ws';
    await git(['clone', bare, root], base);
    // Local main ahead of main@origin: a synced remote entry is folded into the local one, so it would not show.
    await git(['config', 'user.email', 'test@test.invalid'], root);
    await git(['config', 'user.name', 'Test'], root);
    File('$root/ahead.md').writeAsStringSync('ahead\n');
    await git(['add', '.'], root);
    await git(['commit', '-m', 'ahead', '--no-gpg-sign'], root);

    final RepoHandle repo = await worker.initRepo(root, backend: 1, colocate: true);
    Future<Map<String, bool>> trackedRefs() async {
      final GraphTopologyView view = await repo.graphTopology(
        revset: 'all()',
        anchors: const [],
        withTimestamps: false,
      );
      return {
        for (final TopologyRef ref in view.refs)
          if (ref.kind == TopologyRefKind.bookmark)
            '${ref.name}${ref.remote == null ? '' : '@${ref.remote}'}': ref.tracked,
      };
    }

    expect(await trackedRefs(), containsPair('main@origin', false), reason: 'init leaves it untracked');
    await repo.bookmarkTrack(['main@origin']);
    final Map<String, bool> tracked = await trackedRefs();
    expect(tracked, containsPair('main@origin', true));
    expect(tracked, containsPair('x@origin', false));
    expect(tracked, containsPair('main', false));
  });
}
