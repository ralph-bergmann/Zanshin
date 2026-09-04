// SPDX-License-Identifier: MIT

// Decode-contract tests for Story 9.7's two workspace decoders, using synthetic
// FlatBuffers buffers built via the generated `*ObjectBuilder`s. No real cdylib
// required - these tests exercise the Dart-side decode logic in isolation and
// mirror the Rust round-trips in crates/zanshin-ffi/src/workspace.rs (AR-P-7
// parity).
//
// Also covers the root adapter's interior-NUL guard, which fires BEFORE any FFI
// call, so a raw handle of 0 never reaches the cdylib.
//
// Mirrors packages/zanshin_core/test/ffi/commit_views_test.dart.

import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zanshin_core/src/ffi/envelope_zanshin.ffi_generated.dart' as fbs;
import 'package:zanshin_core/src/ffi/workspace.dart';
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

Uint8List listEnvelope(List<fbs.WorkspaceEntryObjectBuilder> entries) => fbs.EnvelopeObjectBuilder(
  ok: true,
  dataType: fbs.PayloadTypeId.WorkspaceList,
  data: fbs.WorkspaceListObjectBuilder(entries: entries),
).toBytes();

void main() {
  group('decodeWorkspaceListEnvelope decode contract', () {
    test('throws ZanshinFfiException on an error envelope', () {
      expect(
        () => decodeWorkspaceListEnvelope(errorEnvelope('jj.jj_lib_error', 'boom')),
        throwsA(
          isA<ZanshinFfiException>()
              .having((e) => e.code, 'code', 'jj.jj_lib_error')
              .having((e) => e.context, 'context', 'boom'),
        ),
      );
    });

    test('throws ffi.unknown on an ok envelope with a non-WorkspaceList payload', () {
      expect(
        () => decodeWorkspaceListEnvelope(wrongPayload()),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'ffi.unknown')),
      );
    });

    test('decodes a present root and an absent one, preserving wire order', () {
      final List<WorkspaceEntry> entries = decodeWorkspaceListEnvelope(
        listEnvelope([
          fbs.WorkspaceEntryObjectBuilder(name: 'default', wcCommitId: 'abc123', root: '/repos/main'),
          // No `root` at all - null-for-absence, the wire form of "this
          // workspace's path cannot be reported". Never an empty string.
          fbs.WorkspaceEntryObjectBuilder(name: 'second', wcCommitId: 'def456'),
        ]),
      );

      expect(entries, hasLength(2));
      expect(entries[0].name, 'default');
      expect(entries[0].wcCommitId, 'abc123');
      expect(entries[0].root, '/repos/main');
      expect(entries[1].name, 'second');
      expect(entries[1].wcCommitId, 'def456');
      expect(entries[1].root, isNull, reason: 'root is null-for-absence');
    });

    test('an empty entry list decodes to an empty list, not an error', () {
      expect(decodeWorkspaceListEnvelope(listEnvelope(const [])), isEmpty);
    });
  });

  group('decodeWorkspaceRootEnvelope decode contract', () {
    test('throws ZanshinFfiException on each of the three named refusals', () {
      for (final code in const [
        'jj.workspace_not_found',
        'jj.workspace_no_recorded_path',
        'jj.workspace_path_unresolved',
      ]) {
        expect(
          () => decodeWorkspaceRootEnvelope(errorEnvelope(code, 'second')),
          throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', code)),
        );
      }
    });

    test('throws ffi.unknown on an ok envelope with a non-WorkspaceRoot payload', () {
      expect(
        () => decodeWorkspaceRootEnvelope(wrongPayload()),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'ffi.unknown')),
      );
    });

    test('decodes the absolute root path', () {
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.WorkspaceRoot,
        data: fbs.WorkspaceRootObjectBuilder(root: '/repos/second'),
      ).toBytes();

      expect(decodeWorkspaceRootEnvelope(bytes), '/repos/second');
    });

    test('throws ffi.unknown when the payload carries no root', () {
      // Unlike a list row's root, this field is ALWAYS written on success - the
      // verb refuses rather than reporting an absent path, so a missing one is a
      // malformed buffer rather than a modellable state.
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.WorkspaceRoot,
        data: fbs.WorkspaceRootObjectBuilder(),
      ).toBytes();

      expect(
        () => decodeWorkspaceRootEnvelope(bytes),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'ffi.unknown')),
      );
    });
  });

  group('adapter guards', () {
    test('zanshinWorkspaceRoot rejects an interior NUL before any FFI call', () {
      // A raw handle of 0 would be `ffi.invalid_handle` if the call went through -
      // it must not, so the guard has to fire first.
      expect(() => zanshinWorkspaceRoot(0, name: 'se${String.fromCharCode(0)}cond'), throwsArgumentError);
    });
  });
}
