// SPDX-License-Identifier: MIT

// Tests for the Story 3.6 event-sink surface: worker E2E event round-trip,
// graceful shutdown, and the two Story 3.9 regression tests (pre-handshake
// failure / uncaught async worker error) that this story's pre-handshake
// event-sink registration and shutdown protocol organically re-enable.
//
// These boot the REAL Isolate.spawn flow against the REAL compiled cdylib —
// no mocked isolates, no mocked FFI (project-context: "Worker / isolate
// testing"). See test/worker/zanshin_worker_test.dart for the JJ_CONFIG /
// GIT_CONFIG_GLOBAL pinning rationale (handled externally by Makefile.toml).

import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:zanshin_core/src/worker/events.dart';
import 'package:zanshin_core/src/worker/handle.dart';
import 'package:zanshin_core/src/worker/isolate.dart';

// Generous timeout so these tests aren't flaky on a loaded CI host — arrival
// is what's asserted, never a tight latency bound (R7).
const _eventTimeout = Duration(seconds: 10);

void main() {
  // ── E2E event round-trip ───────────────────────────────────────────────────

  group('ZanshinWorker events E2E (real cdylib)', () {
    late ZanshinWorker worker;
    late Directory tempDir;

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('zanshin_events_test_');
      worker = await ZanshinWorker.start();
    });

    tearDown(() async {
      await worker.close();
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('op_heads_changed event arrives with the repo handleId', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);

      final Future<RepoEvent> firstMatch = worker.events.firstWhere(
        (e) => e.handleId == handle.handleId && e is OpHeadsChangedEvent,
      );

      File('${tempDir.path}/.jj/repo/op_heads/heads/test_event').writeAsBytesSync(const []);

      final RepoEvent event = await firstMatch.timeout(_eventTimeout);
      expect(event, isA<OpHeadsChangedEvent>());
      expect(event.handleId, handle.handleId);

      await handle.close();
    });

    test('working_copy_heartbeat event arrives with the repo handleId', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);

      final Future<RepoEvent> firstMatch = worker.events.firstWhere(
        (e) => e.handleId == handle.handleId && e is WorkingCopyHeartbeatEvent,
      );

      // Re-write the checkout file (same bytes) to trigger a modify event —
      // mirrors crates/zanshin-ffi/tests/watcher.rs's heartbeat test.
      final checkout = File('${tempDir.path}/.jj/working_copy/checkout');
      checkout.writeAsBytesSync(checkout.readAsBytesSync());

      final RepoEvent event = await firstMatch.timeout(_eventTimeout);
      expect(event, isA<WorkingCopyHeartbeatEvent>());
      expect(event.handleId, handle.handleId);

      await handle.close();
    });

    test('two repos open — touching one dispatches only its handleId', () async {
      final Directory tempDirB = Directory.systemTemp.createTempSync('zanshin_events_test_b_');
      addTearDown(() {
        if (tempDirB.existsSync()) {
          tempDirB.deleteSync(recursive: true);
        }
      });

      final RepoHandle handleA = await worker.initRepo(tempDir.path, backend: 0);
      final RepoHandle handleB = await worker.initRepo(tempDirB.path, backend: 0);

      final List<RepoEvent> observed = [];
      final StreamSubscription<RepoEvent> sub = worker.events.listen(observed.add);
      addTearDown(sub.cancel);

      File('${tempDir.path}/.jj/repo/op_heads/heads/test_event').writeAsBytesSync(const []);

      await worker.events
          .firstWhere((e) => e.handleId == handleA.handleId && e is OpHeadsChangedEvent)
          .timeout(_eventTimeout);
      // Give a stray repo-B event a little extra time to (not) show up.
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(
        observed.any((e) => e.handleId == handleB.handleId),
        isFalse,
        reason: 'repo B was never touched — no event should carry its handleId',
      );

      await handleA.close();
      await handleB.close();
    });
  });

  // ── Shutdown ──────────────────────────────────────────────────────────────

  group('ZanshinWorker events shutdown', () {
    test('close() completes the events stream and rejects further commands', () async {
      final Directory tempDir = Directory.systemTemp.createTempSync('zanshin_events_shutdown_');
      addTearDown(() {
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      });
      final ZanshinWorker worker = await ZanshinWorker.start();
      // A real open repo makes the no-events-after-close assertion below
      // non-vacuous (AC 15): its watcher is live until close() tears it down.
      await worker.initRepo(tempDir.path, backend: 0);

      final List<RepoEvent> observed = [];
      final doneCompleter = Completer<void>();
      final StreamSubscription<RepoEvent> sub = worker.events.listen(observed.add, onDone: doneCompleter.complete);

      await worker.close();
      await doneCompleter.future.timeout(const Duration(seconds: 5));

      // AC 15: "the isolate is gone" — observed via the exit event, not
      // inferred from the closed flag (review patch, 2026-07-03).
      await worker.workerExited.timeout(const Duration(seconds: 5));

      // AC 15: no further events after close() — touch the now-unwatched
      // op_heads dir and give a stray event time to (not) show up. Mirrors the
      // Rust close_stops_further_dispatch negative window (debounce is 50 ms,
      // so 300 ms is a comfortable bound, not a tight latency assert — R7).
      File('${tempDir.path}/.jj/repo/op_heads/heads/after_close').writeAsBytesSync(const []);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await sub.cancel();
      expect(observed, isEmpty, reason: 'no event may be delivered after close() returns');

      await expectLater(
        worker.openRepo('/tmp/any'),
        throwsA(isA<StateError>().having((e) => e.message, 'message', 'Worker is closed')),
      );
    });
  });

  // ── Story 3.9 regressions ──────────────────────────────────────────────────

  group('ZanshinWorker Story 3.9 regressions', () {
    test('pre-handshake failure completes start() with an error, not a hang (AC 15a)', () async {
      // Must resolve via the death/timeout race, well under the 10s handshake
      // timeout — proves the failure is detected as an early worker death
      // rather than silently hanging until the generic timeout fires. The
      // organic hook is this story's registerEventSink call, which now runs
      // before the handshake send.
      await expectLater(
        ZanshinWorker.start(failBeforeHandshake: true).timeout(const Duration(seconds: 3)),
        throwsA(isA<Object>()),
      );
    });

    test('uncaught async error after handshake fails pending commands and kills the worker (AC 15b)', () async {
      final ZanshinWorker worker = await ZanshinWorker.start(throwAsyncErrorAfterHandshake: true);

      // A command in flight when the async error hits must not hang — either
      // the worker answers it first (FIFO) or _onWorkerDeath's failAll does.
      final Future<RepoHandle> inFlight = worker.openRepo('/tmp/any');
      await expectLater(inFlight, throwsA(isA<Object>()));

      // _onWorkerDeath has now run (failAll only fires from there or from
      // close()) and marked the worker closed — proving the isolate was
      // detected as dead and killed, not left running silently.
      await expectLater(
        worker.openRepo('/tmp/any'),
        throwsA(isA<StateError>().having((e) => e.message, 'message', 'Worker is closed')),
      );

      // AC 15b: "the isolate is no longer alive" — observe the exit event
      // produced by _onWorkerDeath's kill, not just the closed flag (review
      // patch, 2026-07-03).
      await worker.workerExited.timeout(const Duration(seconds: 5));
    });
  });
}
