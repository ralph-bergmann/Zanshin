// SPDX-License-Identifier: MIT

// Worker round-trip witness for Story 9.37: the jj CLI's start-up secure-config
// fix-up reaches Dart. A legacy `.jj/repo/config.toml` is migrated by
// [ZanshinWorker.openRepo] — reported on the [OpenedRepoHandle] — and by a
// root-taking config command that then REFUSES, whose thrown
// [ZanshinFfiException] still carries the notice. Drives the REAL Isolate.spawn
// flow against the REAL compiled cdylib; the Rust witnesses are
// crates/zanshin-jj/tests/it/secure_config_fixups.rs and
// crates/zanshin-ffi/tests/it/secure_config_ffi.rs.
//
// JJ_CONFIG="" and XDG_CONFIG_HOME (a throwaway dir under target/) are pinned
// externally by Makefile.toml, so the migrated files land there — never in the
// developer's real ~/.config/jj.

import 'dart:io';

import 'package:test/test.dart';
import 'package:zanshin_core/src/ffi/warning.dart';
import 'package:zanshin_core/src/worker/handle.dart';
import 'package:zanshin_core/src/worker/isolate.dart';
import 'package:zanshin_core/src/worker/responses.dart';

void main() {
  group('Story 9.37 secure-config fix-up (real cdylib)', () {
    late ZanshinWorker worker;
    late Directory tempDir;
    late String root;

    // The Makefile's XDG_CONFIG_HOME pin: without it the migrations below would create
    // secure config under the developer's real ~/.config/jj — refuse before the first call.
    setUpAll(() {
      Platform.environment['XDG_CONFIG_HOME'] ?? fail('XDG_CONFIG_HOME is not pinned — run via cargo make');
    });

    /// A fresh workspace (Zanshin's init writes no `config-id`) with a legacy
    /// repo config.
    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('zanshin_secure_config_test_');
      worker = await ZanshinWorker.start();
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);
      await handle.close();
      root = tempDir.resolveSymbolicLinksSync();
      File('$root/.jj/repo/config.toml').writeAsStringSync('[test]\nmarker = "legacy"\n');
    });

    tearDown(() async {
      await worker.close();
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('open_reports_the_migration_on_the_opened_handle', () async {
      final OpenedRepoHandle handle = await worker.openRepo(root);
      expect(handle.warnings, hasLength(1));
      expect(handle.warnings.single.code, ZanshinWarningCode.configMigrated);
      expect(handle.warnings.single.message, startsWith('Your config file has been migrated from '));
      await handle.close();
    });

    test('a_refused_config_get_still_reports_the_migration', () async {
      try {
        await worker.configGet('no.such', workspaceRoot: root);
        fail('an unset key must refuse');
      } on ZanshinFfiException catch (e) {
        expect(e.code, 'jj.config_not_found');
        expect([for (final ZanshinWarning w in e.warnings) w.code], [ZanshinWarningCode.configMigrated]);
      }
    });
  });
}
