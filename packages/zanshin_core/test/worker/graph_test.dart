// SPDX-License-Identifier: MIT

// Worker round-trip tests for [ZanshinWorker.graphSlice] and [RepoHandle.graphSlice]
// (Story 4.6).
//
// These tests boot the REAL Isolate.spawn flow against the REAL compiled cdylib
// via @ffi.Native native assets. No mocked isolates, no mocked FFI
// (project-context: "Worker / isolate testing"). Mirrors test/worker/change_test.dart.
// They are also what credits `zanshin_graph_slice` in the extern-coverage guard.
//
// JJ_CONFIG / GIT_CONFIG_GLOBAL are pinned externally by [tasks.test-flutter]
// in Makefile.toml (project-context "Property of every test suite").

import 'dart:io';

import 'package:test/test.dart';
import 'package:zanshin_core/src/ffi/change.dart' show Change;
import 'package:zanshin_core/src/ffi/graph.dart';
import 'package:zanshin_core/src/ffi/status.dart' show WorkingCopyStatus;
import 'package:zanshin_core/src/worker/handle.dart';
import 'package:zanshin_core/src/worker/isolate.dart';
import 'package:zanshin_core/src/worker/responses.dart';

void main() {
  // ── Round-trip ────────────────────────────────────────────────────────────

  group('ZanshinWorker.graphSlice round-trip (real cdylib)', () {
    late ZanshinWorker worker;
    late Directory tempDir;

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('zanshin_graph_test_');
      worker = await ZanshinWorker.start();
    });

    tearDown(() async {
      await worker.close();
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('graphSlice_on_fresh_init_returns_wc_row_then_root_row', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);

      // Oracle for the first row: the working-copy commit id via status + getChange
      // (not hard-coding any id).
      final WorkingCopyStatus status = await handle.status();
      final Change wc = await handle.getChange(status.workingCopyChangeId);

      // prioritize is pre-filled with the CLI default (present(@)).
      final GraphSlice slice = await handle.graphSlice(revset: 'all()');

      expect(slice.rows, hasLength(2), reason: 'fresh init = @ + root');
      expect(slice.totalRows, equals(2), reason: 'totalRows == rows.length (return-all)');

      final GraphRow wcRow = slice.rows[0];
      final GraphRow rootRow = slice.rows[1];
      expect(wcRow.commitId, equals(wc.commitId), reason: 'the working-copy commit leads');
      expect(wcRow.lane, equals(0));
      expect(wcRow.colorIdx, equals(0));
      expect(wcRow.edges, hasLength(1), reason: '@ has exactly one parent edge');
      final GraphRowEdge edge = wcRow.edges.single;
      expect(edge.target, equals(rootRow.commitId), reason: '@ → root');
      expect(edge.targetLane, equals(0));
      expect(edge.kind, equals(GraphEdgeKind.direct));
      expect(rootRow.lane, equals(0));
      expect(rootRow.edges, isEmpty, reason: 'root has no parents');

      await handle.close();
    });

    test('graphSlice_with_none_revset_returns_empty_slice', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);

      final GraphSlice slice = await handle.graphSlice(revset: 'none()', prioritize: 'none()');

      expect(slice.rows, isEmpty);
      expect(slice.totalRows, equals(0));

      await handle.close();
    });

    test('graphSlice_on_bogus_revset_surfaces_jj_revset_parse_error', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);

      await expectLater(
        handle.graphSlice(revset: 'bogus_function()'),
        throwsA(
          isA<ZanshinFfiException>().having(
            (e) => e.code,
            'code',
            'jj.revset_parse_error',
          ),
        ),
      );

      await handle.close();
    });

    test('graphSlice_on_unknown_bookmark_surfaces_jj_revset_resolution_error', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);

      await expectLater(
        handle.graphSlice(revset: 'nonexistent-bookmark-xyz'),
        throwsA(
          isA<ZanshinFfiException>().having(
            (e) => e.code,
            'code',
            'jj.revset_resolution_error',
          ),
        ),
      );

      await handle.close();
    });

    // The prioritize argument must reach Rust too — a valid revset with a bad
    // prioritize proves the second string is passed through, not ignored.
    test('graphSlice_on_bogus_prioritize_surfaces_jj_revset_parse_error', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);

      await expectLater(
        handle.graphSlice(revset: 'all()', prioritize: 'bogus_function()'),
        throwsA(
          isA<ZanshinFfiException>().having(
            (e) => e.code,
            'code',
            'jj.revset_parse_error',
          ),
        ),
      );

      await handle.close();
    });

    test('graphSlice_on_unknown_bookmark_prioritize_surfaces_jj_revset_resolution_error', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);

      await expectLater(
        handle.graphSlice(revset: 'all()', prioritize: 'nonexistent-bookmark-xyz'),
        throwsA(
          isA<ZanshinFfiException>().having(
            (e) => e.code,
            'code',
            'jj.revset_resolution_error',
          ),
        ),
      );

      await handle.close();
    });

    test('graphSlice_on_closed_handle_surfaces_ffi_invalid_handle', () async {
      // Close the handle, then bypass the RepoHandle guard and call the worker
      // directly — mirrors the closed-handle test in change_test.dart.
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);
      await handle.close();

      await expectLater(
        worker.graphSlice(handle.handleId, revset: 'all()', prioritize: defaultGraphPrioritize),
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

  // ── Adapter guards (no cdylib call) ──────────────────────────────────────

  group('zanshinGraphSlice argument guards', () {
    test('defaultGraphPrioritize_mirrors_the_rust_cli_default', () {
      // Pinned Rust-side as zanshin_jj::DEFAULT_GRAPH_PRIORITIZE in
      // crates/zanshin-jj/tests/api_stability.rs; this is the Dart mirror's pin.
      expect(defaultGraphPrioritize, 'present(@)');
    });

    test('zanshinGraphSlice_rejects_interior_nul_in_revset_with_argument_error', () {
      expect(() => zanshinGraphSlice(0, 'all()${String.fromCharCode(0)}x', 'none()'), throwsArgumentError);
    });

    test('zanshinGraphSlice_rejects_interior_nul_in_prioritize_with_argument_error', () {
      expect(() => zanshinGraphSlice(0, 'all()', 'none()${String.fromCharCode(0)}x'), throwsArgumentError);
    });
  });

  // ── RepoHandle.graphSlice guard ───────────────────────────────────────────

  group('RepoHandle.graphSlice closed-handle guard', () {
    late ZanshinWorker worker;
    late Directory tempDir;

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('zanshin_graph_guard_test_');
      worker = await ZanshinWorker.start();
    });

    tearDown(() async {
      await worker.close();
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('graphSlice_on_explicitly_closed_handle_throws_state_error', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);
      await handle.close();

      // RepoHandle.graphSlice() must throw StateError before reaching the worker.
      expect(
        () => handle.graphSlice(revset: 'all()'),
        throwsA(isA<StateError>()),
      );
    });
  });
}
