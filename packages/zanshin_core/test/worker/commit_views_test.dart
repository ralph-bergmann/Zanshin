// SPDX-License-Identifier: MIT

// Worker round-trip tests for Story 9.6's three commit READ views: show /
// evolog / interdiff, on both [ZanshinWorker] and [RepoHandle].
//
// These tests boot the REAL Isolate.spawn flow against the REAL compiled cdylib
// via @ffi.Native native assets. No mocked isolates, no mocked FFI
// (project-context: "Worker / isolate testing"). Mirrors
// test/worker/file_test.dart and test/worker/mutate_test.dart. They are also
// what credits each zanshin_show / zanshin_evolog / zanshin_interdiff extern "C"
// function in the coverage ratchet's extern-fn guard
// (mem:project-coverage-extern-fn-needs-zanshin-core-test).
//
// SCOPE NOTE - why no committed file content here. Zanshin never snapshots the
// working copy (D2), and no shipped verb writes file content into a tree, so a
// repo reachable from Dart alone has only EMPTY trees - and no verb rewrites a
// commit, so no evolution chain either. Every content-carrying and
// multi-version row of the I/O matrix therefore lives in the Rust suites, which
// can build trees and operations directly:
// crates/zanshin-jj/tests/commit_views.rs (behaviour) and
// crates/zanshin-ffi/tests/commit_views_ffi.rs (payload bytes across the FFI).
// What these tests own is the DART half of the chain - that every request field
// is built and crosses the buffer, that the three envelopes decode, and that
// each error code surfaces as a ZanshinFfiException.
//
// JJ_CONFIG / GIT_CONFIG_GLOBAL are pinned externally by [tasks.test-core]
// in Makefile.toml (project-context "Property of every test suite").

import 'dart:io';

import 'package:test/test.dart';
import 'package:zanshin_core/src/ffi/commit_views.dart';
import 'package:zanshin_core/src/ffi/status.dart' show WorkingCopyStatus;
import 'package:zanshin_core/src/worker/handle.dart';
import 'package:zanshin_core/src/worker/isolate.dart';
import 'package:zanshin_core/src/worker/responses.dart';

void main() {
  group('ZanshinWorker commit-view round-trips (real cdylib)', () {
    late ZanshinWorker worker;
    late Directory tempDir;

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('zanshin_commit_views_test_');
      worker = await ZanshinWorker.start();
    });

    tearDown(() async {
      await worker.close();
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('show_defaults_to_the_working_copy_and_decodes_the_nested_change', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);
      final WorkingCopyStatus status = await handle.status();

      final List<ShowEntry> entries = await handle.show();

      expect(entries, hasLength(1), reason: 'an omitted revset is `@`, one commit');
      expect(entries.single.change.id, status.workingCopyChangeId);
      expect(
        entries.single.fileChanges,
        isEmpty,
        reason: "a fresh repo's @ has an empty tree and an empty root parent tree",
      );
      await handle.close();
    });

    test('show_carries_the_revset_through_the_request_buffer', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);

      // A malformed revset can only be refused if `revset` actually reached Rust -
      // a reader that dropped the field would apply the `@` default and succeed.
      await expectLater(
        handle.show(revset: '::('),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'jj.revset_parse_error')),
      );

      // An empty revset is a SUCCESS with no entries, not an error.
      expect(await handle.show(revset: 'none()'), isEmpty);
      await handle.close();
    });

    test('show_honours_an_explicit_zero_limit_and_saturates_an_over_large_one', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);

      // `0` is a MEANINGFUL value carried by the presence pair: a reader that
      // collapsed it to "no limit" would return the single `@` entry instead.
      expect(await handle.show(limit: 0), isEmpty);
      // A positive limit at or above the set size is not an error.
      expect(await handle.show(limit: 1), hasLength(1));
      expect(await handle.show(limit: 5), hasLength(1));

      // Above the wire field's `uint` ceiling the adapter SATURATES. Dart ints are
      // 64-bit, so without the clamp 2^32 is written as `0` and comes back as an
      // EMPTY result - the most misleading possible answer to "give me everything".
      expect(
        await handle.show(limit: 0x100000000),
        hasLength(1),
        reason: 'an over-large limit must mean "everything", not wrap to zero',
      );

      // The negative-limit guard is documented on this method, so it must be
      // rejected on the CALLING side: thrown inside the worker isolate it would
      // come back as `internal.dispatch_error`, not as an ArgumentError.
      await expectLater(handle.show(limit: -1), throwsArgumentError);
      await handle.close();
    });

    test('evolog_defaults_to_the_working_copy_and_honours_an_explicit_zero_limit', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);
      final WorkingCopyStatus status = await handle.status();

      final List<EvologEntry> entries = await handle.evolog();
      expect(entries, hasLength(1), reason: 'a never-rewritten @ has exactly one version');
      expect(entries.single.change.id, status.workingCopyChangeId);
      expect(entries.single.predecessorCommitIds, isEmpty);

      // `0` is a MEANINGFUL value carried by the presence pair: a reader that
      // collapsed it to "no limit" would return the entry above instead.
      expect(await handle.evolog(limit: 0), isEmpty);
      // A limit above the walk length is not an error either.
      expect(await handle.evolog(limit: 5), hasLength(1));

      // Above the wire field's `uint` ceiling the adapter SATURATES. Dart ints are
      // 64-bit, so without the clamp 2^32 is written as `0` and comes back as an
      // EMPTY evolog - the most misleading possible answer to "give me everything".
      expect(
        await handle.evolog(limit: 0x100000000),
        hasLength(1),
        reason: 'an over-large limit must mean "everything", not wrap to zero',
      );

      // The negative-limit guard is documented on this method, so it must be
      // rejected on the CALLING side: thrown inside the worker isolate it would
      // come back as `internal.dispatch_error`, not as an ArgumentError.
      await expectLater(handle.evolog(limit: -1), throwsArgumentError);
      await handle.close();
    });

    test('evolog_carries_the_revset_through_the_request_buffer', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);

      await expectLater(
        handle.evolog(revset: 'nosuchbookmark'),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'jj.revset_resolution_error')),
      );

      await handle.close();
    });

    test('interdiff_needs_at_least_one_side_and_decodes_an_empty_change_list', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);
      final WorkingCopyStatus status = await handle.status();

      // Omitting BOTH sides is the CLI's own refusal (`ArgGroup … required(true)`).
      await expectLater(
        handle.interdiff(),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'jj.invalid_input')),
      );

      // One side is enough; the other defaults to `@`. Comparing `@` with itself is
      // trivially empty — which is exactly the empty-payload decode path.
      final InterdiffView view = await handle.interdiff(from: status.workingCopyChangeId);
      expect(view.fileChanges, isEmpty);
      // The fast path returns `from`'s own tree — here `@`, which is clean — so
      // nothing is conflicted. This
      // is the `false` arm reaching Dart through the REAL cdylib; the `true` arm needs
      // committed trees, which no verb reachable from Dart can write (see the scope
      // note above), so it lives in the two Rust suites.
      expect(view.baseHasConflicts, isFalse);

      await handle.close();
    });

    test('interdiff_carries_the_revisions_and_paths_through_the_request_buffer', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);

      // A revision that does not resolve can only be refused if `from` reached Rust.
      await expectLater(
        handle.interdiff(from: 'nonexistentchangeid'),
        throwsA(
          isA<ZanshinFfiException>()
              .having((e) => e.code, 'code', 'jj.change_not_found')
              .having((e) => e.context, 'context', 'nonexistentchangeid'),
        ),
      );

      // A malformed prefix proves `paths` crossed too.
      await expectLater(
        handle.interdiff(to: 'nonexistentchangeid', paths: ['/absolute.txt']),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'jj.invalid_input')),
      );

      await handle.close();
    });

    // -- RepoHandle closed-handle guards (synchronous StateError) ---------------

    test('closed_handle_refuses_every_commit_view_synchronously', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);
      await handle.close();

      // Non-async guards: the StateError is thrown synchronously, before any
      // command reaches the worker.
      expect(handle.show, throwsA(isA<StateError>()));
      expect(handle.evolog, throwsA(isA<StateError>()));
      expect(() => handle.interdiff(from: 'qpvuntsm'), throwsA(isA<StateError>()));
    });

    // -- Worker-level unknown handle (the synthesized ffi.invalid_handle) -------

    test('unknown_handle_id_surfaces_ffi_invalid_handle_for_every_commit_view', () async {
      const unknown = 9999;

      await expectLater(
        worker.show(unknown),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'ffi.invalid_handle')),
      );
      await expectLater(
        worker.evolog(unknown),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'ffi.invalid_handle')),
      );
      await expectLater(
        worker.interdiff(unknown, from: 'qpvuntsm'),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'ffi.invalid_handle')),
      );
    });
  });
}
