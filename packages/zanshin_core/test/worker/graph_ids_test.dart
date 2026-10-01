// SPDX-License-Identifier: MIT

// Pins the graph topology's id encoding (Story 4.12, OQ 2 option (b)): Rust
// sends raw id bytes at one stride per column and [GraphTopologyView] formats
// them — commit ids as lowercase hex, change ids as jj reverse-hex. For EVERY
// node of each committed fixture, the view's formatted ids must equal the display
// strings Rust itself renders, read through `show(revset: 'all()')`.
//
// Real worker isolate + real cdylib. The fixtures are extracted with `tar`
// (fixture setup, never regenerated) into a temp directory per test.
//
// JJ_CONFIG / GIT_CONFIG_GLOBAL are pinned externally by [tasks.test-core]
// in Makefile.toml (project-context "Property of every test suite").

import 'dart:io';

import 'package:test/test.dart';
import 'package:zanshin_core/src/ffi/commit_views.dart' show ShowEntry;
import 'package:zanshin_core/src/ffi/graph.dart';
import 'package:zanshin_core/src/worker/handle.dart';
import 'package:zanshin_core/src/worker/isolate.dart';

void main() {
  late ZanshinWorker worker;
  late Directory tempDir;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('zanshin_graph_ids_test_');
    worker = await ZanshinWorker.start();
  });

  tearDown(() async {
    await worker.close();
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  for (final (String fixture, int nodes) in const [
    ('tiny-3-commits', 5),
    ('medium-1k-commits', 1002),
    ('large-10k-commits', 10002),
  ]) {
    test(
      'every_${fixture}_node_formats_the_ids_rust_displays',
      () async {
        final ProcessResult tar = await Process.run('tar', [
          '-xf',
          '../../test-fixtures/repos/$fixture.tar.zst',
          '-C',
          tempDir.path,
        ]);
        expect(tar.exitCode, 0, reason: '${tar.stderr}');
        final RepoHandle handle = await worker.openRepo(tempDir.path);

        final GraphTopologyView view = await handle.graphTopology(
          revset: 'all()',
          anchors: const [],
          withTimestamps: false,
        );
        final List<ShowEntry> shown = await handle.show(revset: 'all()');

        final Map<String, String> changeOf = {for (final s in shown) s.change.commitId: s.change.id};
        expect(view.nodeCount, nodes);
        expect(changeOf, hasLength(nodes));
        for (var i = 0; i < view.nodeCount; i++) {
          final String commitId = view.commitId(i);
          expect(changeOf.containsKey(commitId), isTrue, reason: 'node $i: $commitId is a commit Rust displays');
          expect(view.changeId(i), changeOf[commitId], reason: 'node $i: the change id of $commitId');
        }

        await handle.close();
      },
      // WHY 10 minutes: `show` diffs every commit — ~80 s for the 10k fixture's
      // loose store in the hook's release build, slower under the coverage
      // instrumentation.
      timeout: const Timeout(Duration(minutes: 10)),
    );
  }
}
