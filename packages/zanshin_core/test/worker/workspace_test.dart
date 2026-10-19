// SPDX-License-Identifier: MIT

// Worker round-trip tests for Story 9.7's two workspace READ verbs: workspace
// list / workspace root, on both [ZanshinWorker] and [RepoHandle] — and for
// Story 9.23's two workspace MUTATIONS, workspace add / workspace update-stale.
//
// These tests boot the REAL Isolate.spawn flow against the REAL compiled cdylib
// via @ffi.Native native assets. No mocked isolates, no mocked FFI
// (project-context: "Worker / isolate testing"). Mirrors
// test/worker/commit_views_test.dart. They are also what credits each
// zanshin_workspace_list / zanshin_workspace_root / zanshin_workspace_add /
// zanshin_workspace_update_stale extern "C" function in the coverage ratchet's
// extern-fn guard (mem:project-coverage-extern-fn-needs-zanshin-core-test).
//
// SCOPE NOTE - the Story 9.7 group below uses one workspace: it predates
// `workspaceAdd` (Story 9.23), and its MULTI-workspace rows live in the Rust
// suites (crates/zanshin-jj/tests/workspace.rs, crates/zanshin-ffi/tests/
// workspace_ffi.rs). The Story 9.23 group creates the second workspace through
// `workspaceAdd` itself.
// The DEGRADED-path rows are reachable from here, though - deleting
// `.jj/repo/workspace_store` needs nothing but dart:io - so the null-root decode
// and the no-recorded-path refusal are witnessed end-to-end below.
// What these tests own is the DART half of the chain - that the request field is
// built and crosses the buffer, that both envelopes decode (root present AND
// absent), and that each error code surfaces as a ZanshinFfiException.
//
// JJ_CONFIG / GIT_CONFIG_GLOBAL are pinned externally by [tasks.test-core]
// in Makefile.toml (project-context "Property of every test suite").

import 'dart:io';

import 'package:test/test.dart';
import 'package:zanshin_core/src/ffi/config.dart' show ConfigScope, ConfigScopeTarget;
import 'package:zanshin_core/src/ffi/status.dart' show WorkingCopyStatus;
import 'package:zanshin_core/src/ffi/workspace.dart';
import 'package:zanshin_core/src/worker/handle.dart';
import 'package:zanshin_core/src/worker/isolate.dart';
import 'package:zanshin_core/src/worker/responses.dart';

void main() {
  group('ZanshinWorker workspace round-trips (real cdylib)', () {
    late ZanshinWorker worker;
    late Directory tempDir;

    /// The repo root, exactly as the caller supplies it - RAW, symlinks and all.
    ///
    /// On macOS `Directory.systemTemp` is `/var/folders/…`, a symlink to
    /// `/private/var/folders/…`, so this is the end-to-end witness that a repo
    /// initialised through a symlinked path can still resolve its own root:
    /// `Repo::init` canonicalizes its destination as the CLI does, and the
    /// handle it returns reads the workspace store from that canonical base.
    late String repoPath;

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('zanshin_workspace_test_');
      repoPath = tempDir.path;
      worker = await ZanshinWorker.start();
    });

    tearDown(() async {
      await worker.close();
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('workspaces_lists_the_default_workspace_with_its_root', () async {
      final RepoHandle handle = await worker.initRepo(repoPath, backend: 0);

      final List<WorkspaceEntry> entries = await handle.workspaces();

      expect(entries, hasLength(1), reason: 'a fresh repo has exactly the default workspace');
      expect(entries.single.name, 'default');
      expect(entries.single.wcCommitId, isNotEmpty);
      final String? root = entries.single.root;
      expect(root, isNotNull, reason: 'a just-created workspace records a path that resolves');
      expect(
        Directory(root!).resolveSymbolicLinksSync(),
        tempDir.resolveSymbolicLinksSync(),
        reason: 'both sides resolved: on macOS /var is a symlink to /private/var',
      );

      await handle.close();
    });

    test('workspace_root_defaults_to_the_current_workspace', () async {
      final RepoHandle handle = await worker.initRepo(repoPath, backend: 0);

      final WorkspaceRootResult root = await handle.workspaceRoot();

      expect(root.warnings, isEmpty, reason: 'nothing to warn about on a fresh repo');

      expect(
        Directory(root.path).resolveSymbolicLinksSync(),
        tempDir.resolveSymbolicLinksSync(),
      );

      await handle.close();
    });

    test('workspace_root_carries_the_name_through_the_request_buffer', () async {
      final RepoHandle handle = await worker.initRepo(repoPath, backend: 0);

      // An unknown name can only be refused if `name` actually reached Rust - a
      // reader that dropped the field would apply the current-workspace default
      // and succeed.
      await expectLater(
        handle.workspaceRoot(name: 'nosuch'),
        throwsA(
          isA<ZanshinFfiException>()
              .having((e) => e.code, 'code', 'jj.workspace_not_found')
              .having((e) => e.context, 'context', 'nosuch'),
        ),
      );

      // An explicitly EMPTY name is a VALUE, not an absence: it must NOT fall
      // back to the current workspace, which the call above still would.
      await expectLater(
        handle.workspaceRoot(name: ''),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'jj.workspace_not_found')),
      );

      // The current workspace's OWN name goes through the store, so it succeeds
      // here (the path was just recorded) - the name still had to cross.
      expect(
        (await handle.workspaceRoot(name: 'default')).path,
        (await handle.workspaceRoot()).path,
        reason: 'the named and default paths agree when the recorded path resolves',
      );

      await handle.close();
    });

    test('workspace_root_rejects_an_interior_nul_on_the_calling_side', () async {
      final RepoHandle handle = await worker.initRepo(repoPath, backend: 0);

      // The guard has to fire BEFORE the command reaches the worker isolate:
      // thrown inside it, the adapter's own guard would come back as
      // `internal.dispatch_error`, not as the documented ArgumentError.
      await expectLater(
        handle.workspaceRoot(name: 'de${String.fromCharCode(0)}fault'),
        throwsA(isA<ArgumentError>().having((e) => e.name, 'name', 'name')),
      );

      await handle.close();
    });

    // -- The degraded-path rows, end to end through the real cdylib ------------

    test('a_wiped_store_yields_a_null_root_and_the_no_recorded_path_refusal', () async {
      final RepoHandle handle = await worker.initRepo(repoPath, backend: 0);
      // With no store directory, jj-lib recreates it EMPTY on the next load, so
      // no workspace has a recorded path any more. This is the pre-jj-0.38.0
      // state a GUI can actually meet.
      Directory('$repoPath/.jj/repo/workspace_store').deleteSync(recursive: true);

      // (a) the listing still succeeds - a path failure never fails it - and the
      // absent root decodes as null rather than an empty string.
      final List<WorkspaceEntry> entries = await handle.workspaces();
      expect(entries, hasLength(1));
      expect(entries.single.name, 'default');
      expect(entries.single.wcCommitId, isNotEmpty, reason: 'the view half is still reported');
      expect(entries.single.root, isNull, reason: 'null-for-absence, never an empty string');

      // (b) the named path refuses instead - the CLI's own asymmetry - since there
      // is no path to report (a stale one would come back with a warning).
      await expectLater(
        handle.workspaceRoot(name: 'default'),
        throwsA(
          isA<ZanshinFfiException>()
              .having((e) => e.code, 'code', 'jj.workspace_no_recorded_path')
              .having((e) => e.context, 'context', 'default'),
        ),
      );

      // (c) the no-name path reads the loader alone, so it still answers.
      expect((await handle.workspaceRoot()).path, isNotEmpty);

      await handle.close();
    });

    // -- RepoHandle closed-handle guards (synchronous StateError) ---------------

    test('closed_handle_refuses_both_workspace_reads_synchronously', () async {
      final RepoHandle handle = await worker.initRepo(repoPath, backend: 0);
      await handle.close();

      // Non-async guards: the StateError is thrown synchronously, before any
      // command reaches the worker.
      expect(handle.workspaces, throwsA(isA<StateError>()));
      expect(handle.workspaceRoot, throwsA(isA<StateError>()));
    });

    // -- Worker-level unknown handle (the synthesized ffi.invalid_handle) -------

    test('unknown_handle_id_surfaces_ffi_invalid_handle_for_both_workspace_reads', () async {
      const unknown = 9999;

      await expectLater(
        worker.workspaces(unknown),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'ffi.invalid_handle')),
      );
      await expectLater(
        worker.workspaceRoot(unknown),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'ffi.invalid_handle')),
      );
    });
  });

  group('ZanshinWorker workspace add / update-stale round-trips (real cdylib)', () {
    late ZanshinWorker worker;
    late Directory tempDir;

    /// The main workspace at `<tmp>/main`, so `../ws2` lands next to it.
    late String mainPath;

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('zanshin_workspace_add_test_');
      mainPath = '${tempDir.path}/main';
      Directory(mainPath).createSync();
      worker = await ZanshinWorker.start();
    });

    tearDown(() async {
      await worker.close();
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('workspace_add_then_a_stale_working_copy_is_updated', () async {
      final RepoHandle a = await worker.initRepo(mainPath, backend: 0);
      File('$mainPath/f.txt').writeAsStringSync('f');
      final String aChange = (await a.status()).workingCopyChangeId;

      final WorkspaceAddResult added = await a.workspaceAdd(
        destination: '../ws2',
        messageParagraphs: const ['T'],
        sparse: SparseInheritance.full,
      );

      expect(added.workspaceName, 'ws2');
      expect(added.gitWorktreeCreated, isFalse);
      expect(added.warnings.map((w) => w.code), isNot(contains('jj.workspace_in_current_directory')));
      expect(added.mutation.newChangeIds, hasLength(1));
      expect(added.mutation.workingCopyChangeId, added.mutation.newChangeIds.single);
      expect(
        Directory(added.workspaceRoot).resolveSymbolicLinksSync(),
        Directory('${tempDir.path}/ws2').resolveSymbolicLinksSync(),
      );

      // From ws2, restore ws2's `@` (which lacks f.txt) INTO a's `@`: a is stale.
      final RepoHandle b = await worker.openRepo(added.workspaceRoot);
      await b.restore(into: aChange);
      await expectLater(
        a.status(),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'jj.stale_working_copy')),
      );

      final StaleRecovery recovery = await a.workspaceUpdateStale();

      expect(recovery.outcome, StaleRecoveryOutcome.updated);
      expect(recovery.commitId, isNotNull);
      expect(recovery.checkout?.removed, 1);
      expect(recovery.gitHeadResetOpId, isNull);
      expect(recovery.opId, isNotEmpty);
      expect(a.lastPrecondition, isNotNull, reason: 'the trailing snapshot report is recorded');
      expect(File('$mainPath/f.txt').existsSync(), isFalse);
      await a.status();

      await b.close();
      await a.close();
    });

    test('workspace_update_stale_on_a_fresh_working_copy_is_not_stale', () async {
      final RepoHandle a = await worker.initRepo(mainPath, backend: 0);

      final StaleRecovery recovery = await a.workspaceUpdateStale();

      expect(recovery.outcome, StaleRecoveryOutcome.notStale);
      expect(recovery.commitId, isNull);
      expect(recovery.checkout, isNull);
      expect(recovery.snapshotStats.untracked, isEmpty);

      await a.close();
    });

    test('workspace_add_refusals_surface_their_codes', () async {
      final RepoHandle a = await worker.initRepo(mainPath, backend: 0);

      await expectLater(
        a.workspaceAdd(destination: '../ws2', name: 'default'),
        throwsA(
          isA<ZanshinFfiException>()
              .having((e) => e.code, 'code', 'jj.workspace_exists')
              .having((e) => e.context, 'context', 'default'),
        ),
      );
      await expectLater(
        a.workspaceAdd(destination: '../ws2', revisions: const ['none()']),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'jj.invalid_input')),
      );
      final WorkspaceAddResult inside = await a.workspaceAdd(destination: 'inside', colocate: false);
      expect(inside.warnings.map((w) => w.code), contains('jj.workspace_in_current_directory'));

      await a.close();
    });

    test('workspace_add_carries_the_colocate_tri_state_through_the_request', () async {
      // `colocate: true` reaches Rust only if the flag crossed: on a native-backend repo it is
      // refused before any `git` runs (`null` would add a plain workspace). WHY not a Git-backed
      // repo with `gitWorktreeCreated == true`: creating the worktree spawns `git`, whose
      // `Child::wait()` fails inside any `dart test` process — the Dart VM reaps its children
      // (creation_test.dart's clone note). The worktree itself is witnessed by the Rust suites
      // (crates/zanshin-jj/tests/workspace_add.rs, crates/zanshin-ffi/tests/workspace_ffi.rs).
      final RepoHandle native = await worker.initRepo(mainPath, backend: 0);
      await expectLater(
        native.workspaceAdd(destination: '../forced', colocate: true),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'jj.git_worktree_failed')),
      );
      await native.close();

      // `colocate: false` on a colocated repo: no worktree only if `--no-colocate` crossed.
      final colocatedPath = '${tempDir.path}/colocated';
      Directory(colocatedPath).createSync();
      final ProcessResult init = Process.runSync('git', [
        'init',
        '--initial-branch=main',
      ], workingDirectory: colocatedPath);
      expect(init.exitCode, 0, reason: '${init.stderr}');
      final RepoHandle colocated = await worker.convert(colocatedPath);
      final WorkspaceAddResult refused = await colocated.workspaceAdd(destination: '../plain', colocate: false);
      expect(refused.gitWorktreeCreated, isFalse);
      expect(File('${tempDir.path}/plain/.git').existsSync(), isFalse);
      await colocated.close();
    });

    test('workspace_add_carries_the_sparse_mode_through_the_request', () async {
      final RepoHandle a = await worker.initRepo(mainPath, backend: 0);
      File('$mainPath/f.txt').writeAsStringSync('f');
      final WorkingCopyStatus status = await a.status();
      await a.newChange(<String>[status.workingCopyChangeId]); // f.txt now lives in @-

      final WorkspaceAddResult empty = await a.workspaceAdd(destination: '../empty', sparse: SparseInheritance.empty);
      final WorkspaceAddResult full = await a.workspaceAdd(destination: '../full', sparse: SparseInheritance.full);

      expect(File('${empty.workspaceRoot}/f.txt').existsSync(), isFalse, reason: 'empty sparse patterns');
      expect(File('${full.workspaceRoot}/f.txt').existsSync(), isTrue, reason: 'full sparse patterns');
      await a.close();
    });

    test('auto_update_stale_recovers_in_front_of_a_verb_and_reports_it', () async {
      // The Makefile's XDG_CONFIG_HOME pin keeps the repo-scope config write out of ~/.config/jj.
      Platform.environment['XDG_CONFIG_HOME'] ?? fail('XDG_CONFIG_HOME is not pinned — run via cargo make');
      final RepoHandle a = await worker.initRepo(mainPath, backend: 0);
      File('$mainPath/f.txt').writeAsStringSync('f');
      final String aChange = (await a.status()).workingCopyChangeId;
      await worker.configSet(
        const ConfigScopeTarget(ConfigScope.repo),
        'snapshot.auto-update-stale',
        'true',
        workspaceRoot: Directory(mainPath).resolveSymbolicLinksSync(),
      );
      final WorkspaceAddResult added = await a.workspaceAdd(destination: '../ws2');
      final RepoHandle b = await worker.openRepo(added.workspaceRoot);
      await b.restore(into: aChange);

      await a.status();

      expect(a.lastPrecondition?.staleRecovery?.outcome, StaleRecoveryOutcome.updated);
      expect(File('$mainPath/f.txt').existsSync(), isFalse);
      await b.close();
      await a.close();
    });

    test('closed_handle_refuses_both_workspace_mutations_synchronously', () async {
      final RepoHandle a = await worker.initRepo(mainPath, backend: 0);
      await a.close();

      expect(() => a.workspaceAdd(destination: '../ws2'), throwsA(isA<StateError>()));
      expect(a.workspaceUpdateStale, throwsA(isA<StateError>()));
    });

    test('unknown_handle_id_surfaces_ffi_invalid_handle_for_both_workspace_mutations', () async {
      const unknown = 9999;

      await expectLater(
        worker.workspaceAdd(unknown, destination: '../ws2'),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'ffi.invalid_handle')),
      );
      await expectLater(
        worker.workspaceUpdateStale(unknown),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'ffi.invalid_handle')),
      );
    });
  });
}
