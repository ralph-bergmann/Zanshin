// SPDX-License-Identifier: MIT

// Story 3.10: the two E2E gaps Story 3.6 didn't cover — the openRepo
// producer path (3.6's Dart E2E only exercised initRepo) and the Dart-side
// pipeline's behaviour under a burst of filesystem mutations. See
// test/worker/events_test.dart for the sibling initRepo-path E2E coverage
// (round-trip, heartbeat, two-repo isolation, close-negative) this story
// does not duplicate.
//
// These boot the REAL Isolate.spawn flow against the REAL compiled cdylib —
// no mocked isolates, no mocked FFI (project-context: "Worker / isolate
// testing").

import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:zanshin_core/src/worker/events.dart';
import 'package:zanshin_core/src/worker/handle.dart';
import 'package:zanshin_core/src/worker/isolate.dart';

// Generous timeout so these tests aren't flaky on a loaded host — arrival is
// what's asserted, never a tight latency bound (R7).
const _eventTimeout = Duration(seconds: 10);

void main() {
  group('ZanshinWorker watcher E2E via openRepo (real cdylib)', () {
    late ZanshinWorker worker;
    late Directory tempDir;

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('zanshin_watcher_e2e_test_');
      worker = await ZanshinWorker.start();
    });

    tearDown(() async {
      await worker.close();
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('op_heads_changed event carries the openRepo handleId and a matching path', () async {
      final RepoHandle initHandle = await worker.initRepo(tempDir.path, backend: 0);
      await initHandle.close();

      final RepoHandle handle = await worker.openRepo(tempDir.path);

      final Future<RepoEvent> firstMatch = worker.events.firstWhere(
        (e) => e.handleId == handle.handleId && e is OpHeadsChangedEvent,
      );

      File('${tempDir.path}/.jj/repo/op_heads/heads/test_event_open').writeAsBytesSync(const []);

      final RepoEvent event = await firstMatch.timeout(_eventTimeout);
      expect(event, isA<OpHeadsChangedEvent>());
      expect(event.handleId, handle.handleId);

      final List<String> paths = (event as OpHeadsChangedEvent).paths;
      expect(
        paths.any((p) => p.endsWith('test_event_open')),
        isTrue,
        reason: 'expected a path ending in test_event_open, got: $paths',
      );

      await handle.close();
    });
  });

  group('ZanshinWorker watcher-storm E2E (real cdylib)', () {
    late ZanshinWorker worker;
    late Directory tempDir;

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('zanshin_watcher_storm_test_');
      worker = await ZanshinWorker.start();
    });

    tearDown(() async {
      await worker.close();
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test(
      'a 50-file burst coalesces to fewer OpHeadsChangedEvents, no WatchErrorEvent, pipeline stays live',
      () async {
        final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);
        final headsDir = Directory('${tempDir.path}/.jj/repo/op_heads/heads');

        final Future<List<RepoEvent>> collected = _collectUntilQuiet(worker.events, handle.handleId);

        for (var i = 0; i < 50; i++) {
          File('${headsDir.path}/burst_$i').writeAsBytesSync(const []);
        }

        final List<RepoEvent> observed = await collected;

        final List<OpHeadsChangedEvent> opHeadsEvents = observed.whereType<OpHeadsChangedEvent>().toList();
        expect(opHeadsEvents.length, greaterThanOrEqualTo(1));
        expect(opHeadsEvents.length, lessThan(50));
        expect(observed.whereType<WatchErrorEvent>(), isEmpty);

        // Path-filtered so a late burst straggler can't satisfy the liveness
        // check before the watcher has seen the after_quiet write.
        final Future<RepoEvent> nextMatch = worker.events.firstWhere(
          (e) =>
              e.handleId == handle.handleId &&
              e is OpHeadsChangedEvent &&
              e.paths.any((p) => p.endsWith('after_quiet')),
        );
        File('${headsDir.path}/after_quiet').writeAsBytesSync(const []);
        await nextMatch.timeout(_eventTimeout);

        await handle.close();
      },
    );
  });
}

/// Collects events for [handleId] from [events] until 500 ms pass without a
/// new one, bounded by an overall 10 s hard cap (AC-2 — never assert an
/// exact count; FSEvents may legitimately split a burst across debounce
/// windows, 3.5-R6).
///
/// The quiet window only starts counting once the FIRST event has arrived —
/// otherwise it would act as a hidden 500 ms first-arrival deadline, i.e.
/// exactly the latency assert this story bans (AC-4.1 / trap 9). First
/// arrival is bounded solely by the 10 s hard cap.
Future<List<RepoEvent>> _collectUntilQuiet(Stream<RepoEvent> events, int handleId) async {
  const quietWindow = Duration(milliseconds: 500);
  const hardCap = Duration(seconds: 10);

  final List<RepoEvent> observed = [];
  final quietCompleter = Completer<void>();
  Timer? idleTimer;
  void resetIdleTimer() {
    idleTimer?.cancel();
    idleTimer = Timer(quietWindow, () {
      if (observed.isNotEmpty && !quietCompleter.isCompleted) {
        quietCompleter.complete();
      }
    });
  }

  final StreamSubscription<RepoEvent> sub = events.where((e) => e.handleId == handleId).listen((e) {
    observed.add(e);
    resetIdleTimer();
  });
  resetIdleTimer();

  try {
    await quietCompleter.future.timeout(hardCap);
  } on TimeoutException {
    // Hard cap hit — fall through with whatever was collected so far.
  } finally {
    idleTimer?.cancel();
    await sub.cancel();
  }
  return observed;
}
