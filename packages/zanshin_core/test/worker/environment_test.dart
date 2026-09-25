// SPDX-License-Identifier: MIT

// Worker round-trip tests for Story 9.36's `adoptLoginShellEnvironment` on
// [ZanshinWorker].
//
// These boot the REAL Isolate.spawn flow against the REAL compiled cdylib and
// call `zanshin_environment_adopt` — which is what credits it in the coverage
// ratchet's extern-fn guard
// (mem:project-coverage-extern-fn-needs-zanshin-core-test).
//
// NEVER a successful adoption here: dart_test.yaml runs every zanshin_core test
// file in ONE process against ONE cdylib, so a success would replace the
// environment every later file reads — the pinned JJ_CONFIG and XDG_CONFIG_HOME
// included. Every call below names a shell that cannot deliver; the success row
// lives in its own cargo test process
// (crates/zanshin-jj/tests/login_shell_environment.rs).

import 'dart:io';

import 'package:test/test.dart';
import 'package:zanshin_core/src/ffi/environment.dart';
import 'package:zanshin_core/src/ffi/warning.dart';
import 'package:zanshin_core/src/worker/isolate.dart';

/// A shell that cannot even start — every call here names one unless it names
/// a script that is guaranteed to fail.
const _missingShell = '/nonexistent/zanshin-shell';

void main() {
  group('ZanshinWorker.adoptLoginShellEnvironment (real cdylib)', () {
    late ZanshinWorker worker;
    late Directory tempDir;

    // The Makefile's XDG_CONFIG_HOME pin: this file shares its process with the
    // config tests, whose environment it must never replace — refuse to run
    // outside the pinned gate.
    setUpAll(() {
      Platform.environment['XDG_CONFIG_HOME'] ?? fail('XDG_CONFIG_HOME is not pinned — run via cargo make');
    });

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('zanshin_environment_test_');
      worker = await ZanshinWorker.start();
    });

    tearDown(() async {
      await worker.close();
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    /// The single `env.login_shell_unresolved` warning of [result].
    ZanshinWarning onlyWarning(LoginShellEnvironmentResult result) {
      expect(result.warnings, hasLength(1));
      final ZanshinWarning warning = result.warnings.single;
      expect(warning.code, ZanshinWarningCode.loginShellUnresolved);
      expect(warning.message, startsWith('Could not read the login-shell environment from '));
      return warning;
    }

    test('a_shell_that_cannot_start_falls_back_with_one_warning', () async {
      final LoginShellEnvironmentResult result = await worker.adoptLoginShellEnvironment(shell: _missingShell);

      expect(onlyWarning(result).message, contains('$_missingShell: could not start it: '));
    });

    test('a_shell_that_outlives_the_timeout_falls_back_with_one_warning', () async {
      final script = File('${tempDir.path}/sleeper')..writeAsStringSync('#!/bin/sh\nexec sleep 30\n');
      expect(Process.runSync('chmod', ['755', script.path]).exitCode, 0);
      final watch = Stopwatch()..start();

      final LoginShellEnvironmentResult result = await worker.adoptLoginShellEnvironment(
        shell: script.path,
        timeout: const Duration(milliseconds: 200),
      );

      expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
      expect(onlyWarning(result).message, contains('${script.path}: timed out after 200 ms'));
    });

    // The DEFAULT 10 s timeout: a shell that takes a second and then fails is waited for, not
    // timed out. Its exit status is only USUALLY known: while one of the VM's own `Process`es
    // runs (always under `dart test`, whose compiler is one) the VM `wait()`s for every child of
    // the process, so the shell's status is gone before Rust asks — and the reason is then the
    // one certain fact, that no environment was printed.
    test('the_default_timeout_waits_for_a_slow_shell', () async {
      final script = File('${tempDir.path}/slow-failure')..writeAsStringSync('#!/bin/sh\nsleep 1\nexit 3\n');
      expect(Process.runSync('chmod', ['755', script.path]).exitCode, 0);

      final LoginShellEnvironmentResult result = await worker.adoptLoginShellEnvironment(shell: script.path);

      expect(
        onlyWarning(result).message,
        anyOf(
          contains('${script.path}: it exited with exit status: 3'),
          contains('${script.path}: it printed no environment'),
        ),
      );
    });

    test('bad_arguments_are_refused_on_the_calling_side', () async {
      await expectLater(worker.adoptLoginShellEnvironment(shell: 'a\u0000'), throwsArgumentError);
      await expectLater(
        worker.adoptLoginShellEnvironment(shell: _missingShell, timeout: const Duration(milliseconds: -1)),
        throwsArgumentError,
      );
      await expectLater(
        worker.adoptLoginShellEnvironment(shell: _missingShell, timeout: const Duration(microseconds: -500)),
        throwsArgumentError,
      );
      await expectLater(
        worker.adoptLoginShellEnvironment(shell: _missingShell, timeout: const Duration(milliseconds: 0x100000000)),
        throwsArgumentError,
      );
    });
  });
}
