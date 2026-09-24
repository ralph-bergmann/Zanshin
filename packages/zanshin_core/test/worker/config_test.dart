// SPDX-License-Identifier: MIT

// Worker round-trip tests for Story 9.28's config surface on [ZanshinWorker].
//
// These boot the REAL Isolate.spawn flow against the REAL compiled cdylib and
// call EVERY one of the nine `zanshin_config_*` externs at least once — which is
// what credits them in the coverage ratchet's extern-fn guard
// (mem:project-coverage-extern-fn-needs-zanshin-core-test).
//
// JJ_CONFIG="" and XDG_CONFIG_HOME (a throwaway dir under target/) are pinned
// externally by Makefile.toml, so the repo-scope files land there and the user
// scope has no path at all — never the developer's real ~/.config/jj.

import 'dart:io';

import 'package:test/test.dart';
import 'package:zanshin_core/src/ffi/config.dart';
import 'package:zanshin_core/src/worker/handle.dart';
import 'package:zanshin_core/src/worker/isolate.dart';
import 'package:zanshin_core/src/worker/responses.dart';

Matcher ffiError(String code) => throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', code));

void main() {
  group('ZanshinWorker config surface (real cdylib)', () {
    late ZanshinWorker worker;
    late Directory tempDir;
    late String root;
    late String xdg;

    // The Makefile's XDG_CONFIG_HOME pin: without it the repo-scope calls below would create
    // secure config under the developer's real ~/.config/jj — refuse before the first call.
    setUpAll(() {
      xdg = Platform.environment['XDG_CONFIG_HOME'] ?? fail('XDG_CONFIG_HOME is not pinned — run via cargo make');
    });

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('zanshin_config_test_');
      worker = await ZanshinWorker.start();
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);
      await handle.close();
      root = tempDir.resolveSymbolicLinksSync();
    });

    tearDown(() async {
      await worker.close();
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('repo_scope_round_trip_through_every_extern', () async {
      final List<String> paths = await worker.configPath(ConfigScope.repo, workspaceRoot: root);
      expect(paths, hasLength(1));
      final String file = paths.single;
      expect(file, startsWith('$xdg/jj/repos/'));

      final ConfigSetResult plain = await worker.configSet(ConfigScope.repo, 'revsets.log', '@', workspaceRoot: root);
      expect(plain.path, file);
      expect(plain.precondition, isNull, reason: 'only an identity write snapshots');
      expect(plain.workingCopyAuthor, isNull);

      // The optional path crosses the worker: a stray one is refused, the candidate accepted.
      await expectLater(
        worker.configSet(ConfigScope.repo, 'revsets.log', '@', workspaceRoot: root, path: '/stray.toml'),
        ffiError('jj.config_ambiguous_file'),
      );
      final ConfigSetResult chosen = await worker.configSet(
        ConfigScope.repo,
        'revsets.log',
        '@',
        workspaceRoot: root,
        path: file,
      );
      expect(chosen.path, file);
      expect((await worker.configFileRead(ConfigScope.repo, workspaceRoot: root, path: file)).path, file);

      // The list filters cross the worker.
      final List<ConfigEntry> prefixed = await worker.configList(workspaceRoot: root, name: 'revsets');
      expect(prefixed.map((r) => r.name), ['revsets.log']);
      final List<ConfigEntry> withDefaults = await worker.configList(workspaceRoot: root, includeDefaults: true);
      expect(withDefaults.any((r) => r.source == ConfigValueSource.defaults), isTrue);

      final ConfigSetResult identity = await worker.configSet(
        ConfigScope.repo,
        'user.name',
        'Somebody Else',
        workspaceRoot: root,
      );
      expect(identity.precondition, isNotNull, reason: 'the CLI check_wc_author snapshot');
      expect(identity.workingCopyAuthor?.name, 'Zanshin');

      expect((await worker.configGet('revsets.log', workspaceRoot: root)).value, '@');
      // `user.name` is shadowed by the pinned `JJ_USER` (EnvOverrides), hence includeOverridden.
      final List<ConfigEntry> rows = await worker.configList(
        workspaceRoot: root,
        scope: ConfigScope.repo,
        includeOverridden: true,
      );
      expect(rows.map((r) => r.name), containsAll(['revsets.log', 'user.name']));
      expect(rows.every((r) => r.source == ConfigValueSource.repo && r.path == file), isTrue);

      expect((await worker.configUnset(ConfigScope.repo, 'revsets.log', workspaceRoot: root, path: file)).path, file);
      await expectLater(
        worker.configUnset(ConfigScope.repo, 'nope', workspaceRoot: root),
        ffiError('jj.config_not_found'),
      );

      final ConfigFileText text = await worker.configFileRead(ConfigScope.repo, workspaceRoot: root);
      expect(text.path, file);
      expect(text.text, contains('Somebody Else'));
      await expectLater(
        worker.configFileWrite(file, '[user\nname = ', workspaceRoot: root),
        ffiError('jj.config_parse_error'),
      );
      final ConfigFileWriteResult written = await worker.configFileWrite(
        file,
        "revsets.log = 'root()'\n",
        workspaceRoot: root,
      );
      expect(written.warnings, isEmpty);
      expect((await worker.configGet('revsets.log', workspaceRoot: root)).value, 'root()');
    });

    test('user_scope_has_no_path_under_the_pinned_env', () async {
      await expectLater(worker.configPath(ConfigScope.user), ffiError('jj.config_path_not_found'));
    });

    test('gc_lists_and_refuses_what_is_not_a_missing_repo_config', () async {
      final List<MissingRepoConfig> missing = await worker.configGcList();
      expect(missing.map((m) => m.configDir), isNot(contains('/not-a-config-dir')));
      final ConfigGcResult result = await worker.configGcDelete(['/not-a-config-dir']);
      expect(result.deleted, isEmpty);
      expect(result.failed.single.reason, 'not a missing repo config directory');
    });

    test('an_interior_NUL_is_refused_on_the_calling_side', () {
      expect(() => worker.configGet('a\u0000'), throwsArgumentError);
    });
  });
}
