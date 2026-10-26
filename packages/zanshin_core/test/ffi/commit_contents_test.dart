// SPDX-License-Identifier: MIT

// Decode-contract tests for Story 4.10's CommitContents decoder, using synthetic
// FlatBuffers buffers built via the generated `*ObjectBuilder`s. No real cdylib
// required - these tests exercise the Dart-side decode logic in isolation and
// mirror the Rust round-trips in crates/zanshin-ffi/src/commit_contents.rs
// (AR-P-7 parity).
//
// Also covers the adapter's interior-NUL guards, which fire BEFORE any FFI call,
// so a raw handle of 0 never reaches the cdylib.
//
// Mirrors packages/zanshin_core/test/ffi/workspace_test.dart.

import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zanshin_core/src/ffi/commit_contents.dart';
import 'package:zanshin_core/src/ffi/envelope_zanshin.ffi_generated.dart' as fbs;
import 'package:zanshin_core/src/ffi/warning.dart';
import 'package:zanshin_core/src/worker/responses.dart';

/// An error envelope carrying [code].
Uint8List errorEnvelope(String code, String context) => fbs.EnvelopeObjectBuilder(
  ok: false,
  error: fbs.FfiErrorObjectBuilder(code: code, context: context),
).toBytes();

/// An ok envelope whose union variant is deliberately the WRONG one.
Uint8List wrongPayload() => fbs.EnvelopeObjectBuilder(
  ok: true,
  dataType: fbs.PayloadTypeId.RepoHandle,
  data: fbs.RepoHandleObjectBuilder(handle: 0),
).toBytes();

Uint8List contentsEnvelope(List<fbs.CommitContentObjectBuilder> contents) => fbs.EnvelopeObjectBuilder(
  ok: true,
  dataType: fbs.PayloadTypeId.CommitContents,
  data: fbs.CommitContentsObjectBuilder(contents: contents),
).toBytes();

/// A complete entry; [omit] names the ONE string field to leave absent.
fbs.CommitContentObjectBuilder entry(
  String commitId, {
  String? omit,
  bool empty = false,
  bool? emptyUnknown,
}) => fbs.CommitContentObjectBuilder(
  commitId: omit == 'commit_id' ? null : commitId,
  authorName: omit == 'author_name' ? null : 'Ada',
  authorEmail: omit == 'author_email' ? null : '',
  committerTimestampMillis: 1700000000123,
  committerTzOffsetMinutes: -120,
  description: omit == 'description' ? null : 'Subject\n\nBody\n',
  conflict: true,
  empty: empty,
  emptyUnknown: emptyUnknown,
);

void main() {
  group('decodeCommitContentsEnvelope decode contract', () {
    test('throws ZanshinFfiException on an error envelope', () {
      expect(
        () => decodeCommitContentsEnvelope(errorEnvelope('jj.operation_not_found', 'No operation ID matching "ab"')),
        throwsA(
          isA<ZanshinFfiException>()
              .having((e) => e.code, 'code', 'jj.operation_not_found')
              .having((e) => e.context, 'context', 'No operation ID matching "ab"'),
        ),
      );
    });

    test('throws ffi.unknown on an ok envelope with a non-CommitContents payload', () {
      expect(
        () => decodeCommitContentsEnvelope(wrongPayload()),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'ffi.unknown')),
      );
    });

    test('decodes every field in wire order, and absent warnings as an empty list', () {
      final WarnedList<CommitContent> contents = decodeCommitContentsEnvelope(
        contentsEnvelope([entry('bb'), entry('aa')]),
      );

      expect(contents, hasLength(2));
      final CommitContent first = contents[0];
      expect(first.commitId, 'bb');
      expect(first.authorName, 'Ada');
      expect(first.authorEmail, '', reason: 'an empty email is a value, not an absence');
      expect(first.committerTimestampMillis, 1700000000123);
      expect(first.committerTzOffsetMinutes, -120);
      expect(first.description, 'Subject\n\nBody\n', reason: 'the FULL description');
      expect(first.conflict, isTrue);
      expect(first.empty, isFalse);
      expect(contents[1].commitId, 'aa', reason: 'request order is wire order');
      expect(contents.warnings, isEmpty);
    });

    test('empty_unknown decodes as a null empty; without it (an old buffer) empty is the flag', () {
      final WarnedList<CommitContent> contents = decodeCommitContentsEnvelope(
        contentsEnvelope([
          entry('aa', emptyUnknown: true),
          entry('bb', empty: true, emptyUnknown: false),
          entry('cc', empty: true),
        ]),
      );

      expect(contents.map((c) => c.empty), [null, true, true]);
    });

    test('an empty list decodes to an empty list, not an error', () {
      expect(decodeCommitContentsEnvelope(contentsEnvelope(const [])), isEmpty);
    });

    test('throws ffi.unknown when the payload is missing its contents vector (no ?? coercion)', () {
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.CommitContents,
        data: fbs.CommitContentsObjectBuilder(),
      ).toBytes();

      expect(
        () => decodeCommitContentsEnvelope(bytes),
        throwsA(
          isA<ZanshinFfiException>()
              .having((e) => e.code, 'code', 'ffi.unknown')
              .having((e) => e.context, 'context', 'CommitContents is missing its contents'),
        ),
      );
    });

    for (final field in const ['commit_id', 'author_name', 'author_email', 'description']) {
      test('throws ffi.unknown when an entry is missing its $field (no ?? coercion)', () {
        expect(
          () => decodeCommitContentsEnvelope(contentsEnvelope([entry('aa', omit: field)])),
          throwsA(
            isA<ZanshinFfiException>()
                .having((e) => e.code, 'code', 'ffi.unknown')
                .having((e) => e.context, 'context', 'CommitContent is missing its $field'),
          ),
        );
      });
    }
  });

  group('adapter guards', () {
    final nul = String.fromCharCode(0);

    test('zanshinCommitContents rejects an interior NUL in the operation id before any FFI call', () {
      // A raw handle of 0 would be `ffi.invalid_handle` if the call went through -
      // it must not, so the guard has to fire first.
      expect(() => zanshinCommitContents(0, operationId: 'ab${nul}cd', commitIds: const []), throwsArgumentError);
    });

    test('zanshinCommitContents rejects an interior NUL in a commit id before any FFI call', () {
      expect(() => zanshinCommitContents(0, operationId: 'abcd', commitIds: ['ok', 'a${nul}b']), throwsArgumentError);
    });

    test('zanshinCommitContents rejects an interior NUL in an extra operation id before any FFI call', () {
      expect(
        () => zanshinCommitContents(0, operationId: 'abcd', extraOperationIds: ['a${nul}b'], commitIds: const []),
        throwsArgumentError,
      );
    });
  });
}
