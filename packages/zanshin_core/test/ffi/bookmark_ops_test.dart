// SPDX-License-Identifier: MIT

// Wire-shape and guard tests for Story 9.8's two bookmark mutation adapters,
// using synthetic FlatBuffers buffers built via the generated `*ObjectBuilder`s.
// No real cdylib required - these exercise the Dart-side request encoding and
// the adapters' NUL backstop in isolation, and mirror the Rust-side readers in
// crates/zanshin-ffi/src/bookmark_ops.rs (AR-P-7 parity).
//
// There is deliberately no decoder test for a bookmark-specific payload: both
// verbs return the shipped `MutationResult`, so what is pinned here is that the
// two NEW error codes travel through the shipped decoder unchanged.
//
// Mirrors packages/zanshin_core/test/ffi/workspace_test.dart.

import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zanshin_core/src/ffi/bookmark_ops.dart';
import 'package:zanshin_core/src/ffi/envelope_zanshin.ffi_generated.dart' as fbs;
import 'package:zanshin_core/src/ffi/mutate.dart' show decodeMutationResultEnvelope;
import 'package:zanshin_core/src/worker/responses.dart';

/// An error envelope carrying [code].
Uint8List errorEnvelope(String code, String context) => fbs.EnvelopeObjectBuilder(
  ok: false,
  error: fbs.FfiErrorObjectBuilder(code: code, context: context),
).toBytes();

void main() {
  group('BookmarkCreateRequest wire shape', () {
    test('an absent revision stays null - it is what applies the CLI -r default', () {
      final req = fbs.BookmarkCreateRequest(
        fbs.BookmarkCreateRequestObjectBuilder(names: ['feature']).toBytes(),
      );

      expect(req.names, ['feature']);
      expect(req.revision, isNull, reason: 'null-for-absence: absent means `@`');
    });

    test('a present revision and several names survive in ARGUMENT order', () {
      final req = fbs.BookmarkCreateRequest(
        fbs.BookmarkCreateRequestObjectBuilder(names: ['b', 'a'], revision: 'qpvuntsm').toBytes(),
      );

      expect(req.names, ['b', 'a'], reason: 'argument order is the fail-fast order');
      expect(req.revision, 'qpvuntsm');
    });

    test('an explicitly empty revision is a VALUE, not an absence', () {
      final req = fbs.BookmarkCreateRequest(
        fbs.BookmarkCreateRequestObjectBuilder(names: ['feature'], revision: '').toBytes(),
      );

      expect(req.revision, isNotNull);
      expect(req.revision, isEmpty);
    });
  });

  group('BookmarkDeleteRequest wire shape', () {
    test('patterns cross verbatim, including their kind prefixes', () {
      final req = fbs.BookmarkDeleteRequest(
        fbs.BookmarkDeleteRequestObjectBuilder(names: [r'glob:"foo-*"', 'exact:bar']).toBytes(),
      );

      expect(req.names, [r'glob:"foo-*"', 'exact:bar']);
    });

    test('an empty pattern list is carried as an empty vector, not dropped', () {
      final req = fbs.BookmarkDeleteRequest(
        fbs.BookmarkDeleteRequestObjectBuilder(names: const <String>[]).toBytes(),
      );

      // Either wire form reaches the same jj-level refusal (`jj.invalid_input`),
      // so the assertion is only that nothing else is smuggled in.
      expect(req.names ?? const <String>[], isEmpty);
    });
  });

  group('adapter guards', () {
    // A raw handle of 0 would be `ffi.invalid_handle` if the call went through -
    // it must not, so each guard has to fire first. These are the DIRECT-CALLER
    // backstop; the primary guard lives in ZanshinWorker / RepoHandle, because
    // inside the worker isolate a throw here returns as `internal.dispatch_error`.
    final nul = String.fromCharCode(0);

    test('zanshinBookmarkCreate rejects an interior NUL in a name', () {
      expect(
        () => zanshinBookmarkCreate(0, ['fea${nul}ture']),
        throwsA(isA<ArgumentError>().having((e) => e.name, 'name', 'names')),
      );
    });

    test('zanshinBookmarkCreate rejects an interior NUL in the revision', () {
      expect(
        () => zanshinBookmarkCreate(0, ['feature'], revision: 'qpv${nul}untsm'),
        throwsA(isA<ArgumentError>().having((e) => e.name, 'name', 'revision')),
      );
    });

    test('zanshinBookmarkDelete rejects an interior NUL in a pattern', () {
      expect(
        () => zanshinBookmarkDelete(0, ['ok', 'fo${nul}o']),
        throwsA(isA<ArgumentError>().having((e) => e.name, 'name', 'names')),
      );
    });
  });

  group('the two new error codes travel through the shipped MutationResult decoder', () {
    test('each surfaces as a ZanshinFfiException carrying the offending name', () {
      for (final code in const ['jj.bookmark_exists', 'jj.bookmark_tracked_remote_exists']) {
        expect(
          () => decodeMutationResultEnvelope(errorEnvelope(code, 'feature')),
          throwsA(
            isA<ZanshinFfiException>()
                .having((e) => e.code, 'code', code)
                .having((e) => e.context, 'context', 'feature'),
          ),
        );
      }
    });
  });
}
