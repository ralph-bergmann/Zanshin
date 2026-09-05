// SPDX-License-Identifier: MIT

// Worker round-trip tests for Story 9.7's two workspace READ verbs: workspace
// list / workspace root, on both [ZanshinWorker] and [RepoHandle].
//
// These tests boot the REAL Isolate.spawn flow against the REAL compiled cdylib
// via @ffi.Native native assets. No mocked isolates, no mocked FFI
// (project-context: "Worker / isolate testing"). Mirrors
// test/worker/commit_views_test.dart. They are also what credits each
// zanshin_workspace_list / zanshin_workspace_root extern "C" function in the
// coverage ratchet's extern-fn guard
// (mem:project-coverage-extern-fn-needs-zanshin-core-test).
//
// SCOPE NOTE - why only one workspace here. No shipped verb creates a SECOND
// workspace (`jj workspace add` is Story 9.13), so a repo reachable from Dart
// alone always has exactly the `default` one. The MULTI-workspace rows of the
// I/O matrix therefore live in the Rust suites, which can build a sibling
// workspace directly: crates/zanshin-jj/tests/workspace.rs (behaviour) and
// crates/zanshin-ffi/tests/workspace_ffi.rs (payload bytes across the FFI).
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
import 'package:zanshin_core/src/ffi/workspace.dart';
import 'package:zanshin_core/src/worker/handle.dart';
import 'package:zanshin_core/src/worker/isolate.dart';
import 'package:zanshin_core/src/worker/responses.dart';

void main() {
  group('ZanshinWorker workspace round-trips (real cdylib)', () {
    late ZanshinWorker worker;
    late Directory tempDir;

    /// The repo root, with symlinks resolved.
    ///
    /// WHY: jj-lib records a workspace's root in the store RELATIVE to the
    /// `.jj/repo` path it was handed at init time, while every read joins it onto
    /// the canonicalized one. On macOS `Directory.systemTemp` is
    /// `/var/folders/…`, a symlink to `/private/var/folders/…`, so initialising
    /// through the raw temp path records one `..` too few and the recorded root
    /// never resolves. A real repo path from a folder picker has no such symlink
    /// in it; resolving here reproduces the ordinary case instead of the macOS
    /// temp-dir artifact.
    late String repoPath;

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('zanshin_workspace_test_');
      repoPath = tempDir.resolveSymbolicLinksSync();
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
        repoPath,
        reason: 'both sides resolved: on macOS /var is a symlink to /private/var',
      );

      await handle.close();
    });

    test('workspace_root_defaults_to_the_current_workspace', () async {
      final RepoHandle handle = await worker.initRepo(repoPath, backend: 0);

      final String root = await handle.workspaceRoot();

      expect(
        Directory(root).resolveSymbolicLinksSync(),
        repoPath,
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
        await handle.workspaceRoot(name: 'default'),
        await handle.workspaceRoot(),
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

      // (b) the named path refuses instead - the CLI's own asymmetry - with the
      // code that says "nothing to repair", not the stale-path one.
      await expectLater(
        handle.workspaceRoot(name: 'default'),
        throwsA(
          isA<ZanshinFfiException>()
              .having((e) => e.code, 'code', 'jj.workspace_no_recorded_path')
              .having((e) => e.context, 'context', 'default'),
        ),
      );

      // (c) the no-name path reads the loader alone, so it still answers.
      expect(await handle.workspaceRoot(), isNotEmpty);

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
}
