// SPDX-License-Identifier: MIT

// Worker round-trip tests for [ZanshinWorker.logDefaults] and
// [RepoHandle.logDefaults] (Story 4.9).
//
// These tests boot the REAL Isolate.spawn flow against the REAL compiled cdylib
// via @ffi.Native native assets. No mocked isolates, no mocked FFI — this is
// what credits `zanshin_log_defaults` in the extern-coverage guard.
//
// JJ_CONFIG / GIT_CONFIG_GLOBAL are pinned to "" externally by [tasks.test-core]
// in Makefile.toml (project-context "Property of every test suite"), and Dart
// cannot change process env in-process. `JJ_CONFIG=""` DISABLES user-config
// discovery, and a freshly-init'd repo has no repo/workspace config, so the
// values asserted here are exactly the builtin defaults. Config OVERRIDES are
// exercised Rust-side (crates/zanshin-jj/tests/it/config.rs,
// crates/zanshin-ffi/tests/it/log_defaults_ffi.rs) and Dart-side against synthetic
// buffers (test/ffi/log_defaults_test.dart).

import 'dart:io';

import 'package:test/test.dart';
import 'package:zanshin_core/src/ffi/graph.dart' show defaultGraphPrioritize, defaultLogRevset, defaultShortPrefixes;
import 'package:zanshin_core/src/ffi/log_defaults.dart';
import 'package:zanshin_core/src/worker/handle.dart';
import 'package:zanshin_core/src/worker/isolate.dart';
import 'package:zanshin_core/src/worker/responses.dart';

void main() {
  // ── Round-trip ────────────────────────────────────────────────────────────

  group('ZanshinWorker.logDefaults round-trip (real cdylib)', () {
    late ZanshinWorker worker;
    late Directory tempDir;

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('zanshin_log_defaults_test_');
      worker = await ZanshinWorker.start();
    });

    tearDown(() async {
      await worker.close();
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('log_defaults_on_unconfigured_repo_equals_the_builtin_constants', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);

      final LogDefaults defaults = await handle.logDefaults();

      // With no config anywhere the effective values are the builtin layer —
      // i.e. exactly the compile-time constants graph.dart pre-fills.
      expect(defaults.log, equals(defaultLogRevset));
      expect(defaults.logGraphPrioritize, equals(defaultGraphPrioritize));
      expect(
        defaults.shortPrefixes,
        equals(defaultShortPrefixes),
        reason: 'unset revsets.short-prefixes falls back to revsets.log',
      );
      expect(
        defaults.syntheticElided,
        isTrue,
        reason: "the CLI's ui.log-synthetic-elided-nodes default (the topology call takes no such parameter)",
      );

      await handle.close();
    });

    test('log_defaults_is_stable_across_two_calls_on_the_same_handle', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);

      final LogDefaults first = await handle.logDefaults();
      final LogDefaults second = await handle.logDefaults();

      // Re-read per call, so two reads of an unchanged config agree.
      expect(first.log, equals(second.log));
      expect(first.logGraphPrioritize, equals(second.logGraphPrioritize));
      expect(first.shortPrefixes, equals(second.shortPrefixes));
      expect(first.syntheticElided, equals(second.syntheticElided));

      await handle.close();
    });

    test('log_defaults_on_closed_handle_surfaces_ffi_invalid_handle', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);
      await handle.close();

      // Direct worker call with the now-unknown handleId bypasses the closed guard.
      await expectLater(
        worker.logDefaults(handle.handleId),
        throwsA(
          isA<ZanshinFfiException>().having(
            (e) => e.code,
            'code',
            'ffi.invalid_handle',
          ),
        ),
      );
    });
  });

  // ── RepoHandle.logDefaults guard ──────────────────────────────────────────

  group('RepoHandle.logDefaults closed-handle guard', () {
    late ZanshinWorker worker;
    late Directory tempDir;

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('zanshin_log_defaults_guard_test_');
      worker = await ZanshinWorker.start();
    });

    tearDown(() async {
      await worker.close();
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('log_defaults_on_explicitly_closed_handle_throws_state_error_synchronously', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);
      await handle.close();

      // RepoHandle.logDefaults() must throw StateError synchronously, before
      // the command ever reaches the worker.
      expect(
        handle.logDefaults,
        throwsA(isA<StateError>()),
      );
    });
  });
}
