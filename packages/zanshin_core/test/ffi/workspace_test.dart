// SPDX-License-Identifier: MIT

// Decode-contract tests for Story 9.7's two workspace decoders and Story 9.23's
// two (workspace add / update-stale, plus the `Precondition.staleRecovery` they
// share), using synthetic
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
import 'package:zanshin_core/src/ffi/precondition.dart' show decodeEnvelopePrecondition;
import 'package:zanshin_core/src/ffi/warning.dart';
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
    test('throws ZanshinFfiException on each of the two named refusals', () {
      for (final code in const [
        'jj.workspace_not_found',
        'jj.workspace_no_recorded_path',
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

      expect(decodeWorkspaceRootEnvelope(bytes).path, '/repos/second');
    });

    test('decodes a stale root together with its inaccessible-path warning', () {
      // Since jj 0.46 a recorded directory that is gone is reported, not
      // refused: the path comes back and the warning rides along.
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.WorkspaceRoot,
        data: fbs.WorkspaceRootObjectBuilder(root: '/gone/second'),
        warnings: [
          fbs.WarningObjectBuilder(
            code: ZanshinWarningCode.workspacePathInaccessible,
            message: 'Cannot access workspace path: /gone/second',
          ),
        ],
      ).toBytes();

      final WorkspaceRootResult root = decodeWorkspaceRootEnvelope(bytes);

      expect(root.path, '/gone/second');
      expect(root.warnings, hasLength(1));
      expect(root.warnings.single.code, ZanshinWarningCode.workspacePathInaccessible);
      expect(root.warnings.single.message, 'Cannot access workspace path: /gone/second');
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

  group('decodeWorkspaceAddEnvelope decode contract (Story 9.23)', () {
    test('every field crosses the wire', () {
      final WorkspaceAddResult r = decodeWorkspaceAddEnvelope(
        fbs.EnvelopeObjectBuilder(
          ok: true,
          dataType: fbs.PayloadTypeId.WorkspaceAddResult,
          data: fbs.WorkspaceAddResultObjectBuilder(
            mutation: fbs.MutationResultObjectBuilder(
              newOpId: 'op',
              newChangeIds: const ['w'],
              abandonedChangeIds: const [],
              workingCopyChangeId: 'w',
            ),
            workspaceName: 'ws2',
            workspaceRoot: '/tmp/ws2',
            gitWorktreeCreated: true,
            checkout: fbs.CheckoutStatsObjectBuilder(added: 1, updated: 2, removed: 3, skipped: 4),
          ),
          warnings: [fbs.WarningObjectBuilder(code: 'jj.workspace_in_current_directory', message: 'm')],
        ).toBytes(),
      );

      expect(r.workspaceName, 'ws2');
      expect(r.workspaceRoot, '/tmp/ws2');
      expect(r.gitWorktreeCreated, isTrue);
      expect(r.mutation.workingCopyChangeId, 'w');
      expect([r.checkout.added, r.checkout.updated, r.checkout.removed, r.checkout.skipped], [1, 2, 3, 4]);
      expect(r.warnings.single.code, ZanshinWarningCode.workspaceInCurrentDirectory);
    });

    test('a missing required field is refused, not defaulted', () {
      Uint8List without({bool name = true, bool root = true, bool checkout = true}) => fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.WorkspaceAddResult,
        data: fbs.WorkspaceAddResultObjectBuilder(
          workspaceName: name ? 'ws2' : null,
          workspaceRoot: root ? '/ws2' : null,
          checkout: checkout ? fbs.CheckoutStatsObjectBuilder() : null,
        ),
      ).toBytes();
      final Matcher unknown = throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'ffi.unknown'));

      expect(decodeWorkspaceAddEnvelope(without()).workspaceName, 'ws2');
      expect(() => decodeWorkspaceAddEnvelope(without(name: false)), unknown);
      expect(() => decodeWorkspaceAddEnvelope(without(root: false)), unknown);
      expect(() => decodeWorkspaceAddEnvelope(without(checkout: false)), unknown);
      expect(
        () => decodeStaleRecoveryEnvelope(
          fbs.EnvelopeObjectBuilder(
            ok: true,
            dataType: fbs.PayloadTypeId.StaleRecovery,
            data: fbs.StaleRecoveryObjectBuilder(),
          ).toBytes(),
        ),
        unknown,
      );
    });

    test('an error envelope and a wrong payload throw', () {
      expect(
        () => decodeWorkspaceAddEnvelope(errorEnvelope('jj.workspace_exists', 'ws2')),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'jj.workspace_exists')),
      );
      expect(
        () => decodeWorkspaceAddEnvelope(wrongPayload()),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'ffi.unknown')),
      );
    });
  });

  group('decodeStaleRecoveryEnvelope decode contract (Story 9.23)', () {
    Uint8List recoveryEnvelope(fbs.StaleRecoveryObjectBuilder r) =>
        fbs.EnvelopeObjectBuilder(ok: true, dataType: fbs.PayloadTypeId.StaleRecovery, data: r).toBytes();

    test('an updated recovery carries every field', () {
      final StaleRecovery r = decodeStaleRecoveryEnvelope(
        recoveryEnvelope(
          fbs.StaleRecoveryObjectBuilder(
            outcome: fbs.StaleRecoveryOutcome.Updated,
            commitId: 'c0ffee',
            checkout: fbs.CheckoutStatsObjectBuilder(added: 0, updated: 1, removed: 2, skipped: 0),
            gitHeadResetOpId: 'reset',
            snapshotStats: fbs.SnapshotStatsObjectBuilder(untracked: const [], invalidUtf8Paths: const ['x']),
            opId: 'head',
          ),
        ),
      );

      expect(r.outcome, StaleRecoveryOutcome.updated);
      expect(r.commitId, 'c0ffee');
      expect(r.checkout?.removed, 2);
      expect(r.gitHeadResetOpId, 'reset');
      expect(r.snapshotStats.invalidUtf8Paths, ['x']);
      expect(r.opId, 'head');
    });

    test('absent optionals decode as null, and every outcome maps', () {
      for (final (wire, dart) in [
        (fbs.StaleRecoveryOutcome.NotStale, StaleRecoveryOutcome.notStale),
        (fbs.StaleRecoveryOutcome.Recovered, StaleRecoveryOutcome.recovered),
      ]) {
        final StaleRecovery r = decodeStaleRecoveryEnvelope(
          recoveryEnvelope(fbs.StaleRecoveryObjectBuilder(outcome: wire, opId: 'head')),
        );
        expect(r.outcome, dart);
        expect(r.commitId, isNull);
        expect(r.checkout, isNull);
        expect(r.gitHeadResetOpId, isNull);
      }
    });

    test('an error envelope and a wrong payload throw', () {
      expect(
        () => decodeStaleRecoveryEnvelope(errorEnvelope('jj.concurrent_working_copy', '')),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'jj.concurrent_working_copy')),
      );
      expect(
        () => decodeStaleRecoveryEnvelope(wrongPayload()),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'ffi.unknown')),
      );
    });

    test('a precondition carries the auto arm recovery', () {
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: true,
        precondition: fbs.PreconditionObjectBuilder(
          staleRecovery: fbs.StaleRecoveryObjectBuilder(outcome: fbs.StaleRecoveryOutcome.Updated, opId: 'h'),
        ),
      ).toBytes();

      expect(decodeEnvelopePrecondition(bytes)?.staleRecovery?.outcome, StaleRecoveryOutcome.updated);
      expect(
        decodeEnvelopePrecondition(
          fbs.EnvelopeObjectBuilder(ok: true, precondition: fbs.PreconditionObjectBuilder()).toBytes(),
        )?.staleRecovery,
        isNull,
      );
    });
  });

  group('adapter guards', () {
    test('zanshinWorkspaceAdd rejects an interior NUL before any FFI call', () {
      expect(() => zanshinWorkspaceAdd(0, destination: 'w${String.fromCharCode(0)}s'), throwsArgumentError);
      expect(
        () => zanshinWorkspaceAdd(0, destination: 'ws', revisions: ['@${String.fromCharCode(0)}']),
        throwsArgumentError,
      );
    });

    test('zanshinWorkspaceRoot rejects an interior NUL before any FFI call', () {
      // A raw handle of 0 would be `ffi.invalid_handle` if the call went through -
      // it must not, so the guard has to fire first.
      expect(() => zanshinWorkspaceRoot(0, name: 'se${String.fromCharCode(0)}cond'), throwsArgumentError);
    });
  });
}
