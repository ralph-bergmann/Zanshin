// SPDX-License-Identifier: MIT

// Story 4.11: worker occupancy. One worker isolate serves every handle, so a layout blocks the
// commands queued behind it head-of-line (epic-4-context, "Worker occupancy"). This measures the
// latency of one 60-id `commitContents` page — the card content of a visible page — on its own,
// queued behind a `graphLayout(free, compact)`, and queued behind a timestamped `graphTopology`
// (what a layout costs on the worker beyond its topology call), on the large-10k fixture's loose
// store and on a `git gc`-packed copy of it.
//
// Prints numbers only (min / median µs of 7 runs after 1 warm-up run, each measured from issuing
// the page to its reply); asserts nothing. Real worker isolate + real cdylib. Run from
// `packages/zanshin_core` with the env of `Makefile.toml`'s `[tasks.test-core]` (plus
// `ZANSHIN_LOG=error`):
//
// ```sh
// dart run benchmark/graph_layout_occupancy.dart
// ```

import 'dart:io';

import 'package:zanshin_core/src/ffi/graph.dart';
import 'package:zanshin_core/src/worker/handle.dart';
import 'package:zanshin_core/src/worker/isolate.dart';

const _warmup = 1;
const _runs = 7;
const _page = 60;

Future<void> main() async {
  final Directory temp = Directory.systemTemp.createTempSync('zanshin_graph_layout_occupancy_');
  try {
    for (final packed in const [false, true]) {
      final dir = Directory('${temp.path}/${packed ? 'packed' : 'loose'}')..createSync();
      final ProcessResult tar = await Process.run('tar', [
        '-xf',
        '../../test-fixtures/repos/large-10k-commits.tar.zst',
        '-C',
        dir.path,
      ]);
      if (tar.exitCode != 0) {
        throw StateError('tar: ${tar.stderr}');
      }
      if (packed) {
        final ProcessResult gc = await Process.run('git', [
          '--git-dir=${dir.path}/.jj/repo/store/git',
          '-c',
          'gc.pruneExpire=never',
          'gc',
          '--quiet',
        ]);
        if (gc.exitCode != 0) {
          throw StateError('git gc: ${gc.stderr}');
        }
      }
      await _bench(dir.path, packed ? 'large-10k packed' : 'large-10k loose');
    }
  } finally {
    temp.deleteSync(recursive: true);
  }
}

Future<void> _bench(String path, String store) async {
  final ZanshinWorker worker = await ZanshinWorker.start();
  try {
    final RepoHandle handle = await worker.openRepo(path);
    final GraphTopologyView topology = await handle.graphTopology(
      revset: 'all()',
      anchors: defaultGraphAnchors,
      withTimestamps: false,
    );
    final List<String> ids = [for (var i = 0; i < _page; i++) topology.commitId(i)];
    final String op = topology.operationId;
    Future<void> page() => handle.commitContents(operationId: op, commitIds: ids);

    _report(store, 'content page alone', await _measure(() async => page(), null));
    _report(
      store,
      'content page behind graphLayout(free, compact)',
      await _measure(
        () async => page(),
        () => handle.graphLayout(revset: 'all()', anchors: defaultGraphAnchors, utcOffsetMin: 120),
      ),
    );
    _report(
      store,
      'content page behind graphTopology(withTimestamps: true)',
      await _measure(
        () async => page(),
        () => handle.graphTopology(revset: 'all()', anchors: defaultGraphAnchors, withTimestamps: true),
      ),
    );
    await handle.close();
  } finally {
    await worker.close();
  }
}

/// `(min, median)` µs from issuing [measured] — right after issuing [ahead], when given — to its
/// reply; [ahead] is awaited after each run.
Future<(int, int)> _measure(Future<void> Function() measured, Future<Object?> Function()? ahead) async {
  final samples = <int>[];
  for (var r = 0; r < _warmup + _runs; r++) {
    final Future<Object?>? blocker = ahead?.call();
    final sw = Stopwatch()..start();
    await measured();
    final int us = sw.elapsedMicroseconds;
    await blocker;
    if (r >= _warmup) {
      samples.add(us);
    }
  }
  samples.sort();
  return (samples.first, samples[samples.length ~/ 2]);
}

void _report(String store, String what, (int, int) t) {
  final (int min, int median) = t;
  print('[$store] $what: min $min µs / med $median µs');
}
