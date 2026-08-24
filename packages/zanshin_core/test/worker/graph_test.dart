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

      // prioritize / syntheticElided / shortPrefixes are pre-filled with the CLI defaults.
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
      expect(wcRow.activeLanes, isEmpty, reason: 'nothing crosses a two-row graph');
      expect(wcRow.syntheticElided, isFalse);
      expect(rootRow.syntheticElided, isFalse);

      await handle.close();
    });

    // ── Story 4.8: metadata rides the same call ───────────────────────────

    test('graphSlice_rows_carry_jj_log_metadata_from_the_same_snapshot', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);

      final WorkingCopyStatus status = await handle.status();
      final Change wc = await handle.getChange(status.workingCopyChangeId);

      final GraphSlice slice = await handle.graphSlice(revset: 'all()');

      final GraphRowMeta wcMeta = slice.rows[0].meta!;
      final GraphRowMeta rootMeta = slice.rows[1].meta!;

      // The change id agrees with getChange for the same commit — one snapshot.
      expect(wcMeta.changeId, equals(wc.id));
      expect(wcMeta.workingCopy, isTrue, reason: 'the @ row is this workspace’s working copy');
      expect(wcMeta.immutable, isFalse, reason: '@ is mutable');
      expect(wcMeta.empty, isTrue, reason: 'a fresh @ has no changes');
      expect(wcMeta.descriptionFirstLine, isEmpty);
      expect(wcMeta.committerTimestampMillis, greaterThan(0));
      expect(wcMeta.workingCopies, isEmpty, reason: 'single-workspace repo (CLI guard)');
      expect(wcMeta.changeIdPrefixLen, greaterThanOrEqualTo(1));
      expect(wcMeta.changeIdPrefixLen, lessThanOrEqualTo(wcMeta.changeId.length));
      expect(wcMeta.commitIdPrefixLen, greaterThanOrEqualTo(1));
      expect(wcMeta.commitIdPrefixLen, lessThanOrEqualTo(slice.rows[0].commitId.length));

      expect(rootMeta.root, isTrue, reason: 'the last row is the root commit');
      expect(rootMeta.immutable, isTrue, reason: 'root() is always immutable');
      expect(rootMeta.workingCopy, isFalse);

      await handle.close();
    });

    test('graphSlice_accepts_the_cli_default_log_revset', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);

      // Parses only because the builtin [revset-aliases] are defined Rust-side.
      final GraphSlice slice = await handle.graphSlice(revset: defaultLogRevset);

      expect(slice.rows, isNotEmpty);

      await handle.close();
    });

    test('graphSlice_with_empty_short_prefixes_disables_disambiguation', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);

      // Empty = disabled (the CLI's toggle), NOT a parse error like a blank prioritize.
      final GraphSlice slice = await handle.graphSlice(revset: 'all()', shortPrefixes: '');

      expect(slice.rows, hasLength(2));
      expect(slice.rows[0].meta!.commitIdPrefixLen, greaterThanOrEqualTo(1));

      await handle.close();
    });

    test('graphSlice_on_bogus_short_prefixes_surfaces_jj_revset_parse_error', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);

      await expectLater(
        handle.graphSlice(revset: 'all()', shortPrefixes: 'bogus_function()'),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'jj.revset_parse_error')),
      );

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
        worker.graphSlice(
          handle.handleId,
          revset: 'all()',
          prioritize: defaultGraphPrioritize,
          syntheticElided: true,
          shortPrefixes: defaultShortPrefixes,
        ),
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

    test('defaultLogRevset_and_defaultShortPrefixes_mirror_the_rust_cli_default', () {
      // Pinned Rust-side as zanshin_jj::DEFAULT_LOG_REVSET; the CLI's
      // revsets.short-prefixes falls back to revsets.log, so both hold it.
      expect(defaultLogRevset, 'present(@) | ancestors(immutable_heads().., 2) | trunk()');
      expect(defaultShortPrefixes, equals(defaultLogRevset));
    });

    test('defaultSyntheticElided_mirrors_the_cli_ui_log_synthetic_elided_nodes_default', () {
      // The CLI's ui.log-synthetic-elided-nodes default (cli/src/config/misc.toml
      // @ v0.42.0); RepoHandle.graphSlice pre-fills it.
      expect(defaultSyntheticElided, isTrue);
    });

    test('zanshinGraphSlice_rejects_interior_nul_in_revset_with_argument_error', () {
      expect(
        () => zanshinGraphSlice(
          0,
          'all()${String.fromCharCode(0)}x',
          'none()',
          syntheticElided: true,
          shortPrefixes: '',
        ),
        throwsArgumentError,
      );
    });

    test('zanshinGraphSlice_rejects_interior_nul_in_prioritize_with_argument_error', () {
      expect(
        () => zanshinGraphSlice(
          0,
          'all()',
          'none()${String.fromCharCode(0)}x',
          syntheticElided: true,
          shortPrefixes: '',
        ),
        throwsArgumentError,
      );
    });

    test('zanshinGraphSlice_rejects_interior_nul_in_short_prefixes_with_argument_error', () {
      expect(
        () => zanshinGraphSlice(
          0,
          'all()',
          'none()',
          syntheticElided: true,
          shortPrefixes: 'all()${String.fromCharCode(0)}x',
        ),
        throwsArgumentError,
      );
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
