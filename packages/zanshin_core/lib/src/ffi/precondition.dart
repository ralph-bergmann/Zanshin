// SPDX-License-Identifier: MIT

import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../worker/responses.dart';
import 'bindings.dart';
import 'envelope_zanshin.ffi_generated.dart' as fbs;
import 'file_ops.dart' show SnapshotStats, decodeSnapshotStatsInternal;
import 'git.dart' show GitExportFailure, GitImportResult, decodeExportFailuresInternal, decodeGitImportResultInternal;
import 'request_bytes.dart';
import 'warning.dart';
import 'workspace.dart' show StaleRecovery, decodeStaleRecoveryInternal;

// This file owns the Dart half of Story 9.26's implicit pre-verb snapshot: the
// `zanshin_snapshot` adapter (the CLI's `jj util snapshot`), the `Precondition` /
// `FinishFacts` models every envelope of a snapshotting verb carries, and their
// decoders. `dart:ffi` stays inside `ffi/` — only the worker isolate calls the
// adapter. It also holds `decodeEnvelopeErrorInternal`, the decoder every error
// envelope goes through (Story 9.35).

// ── FFI adapter ──────────────────────────────────────────────────────────────

/// Call `zanshin_snapshot` with the raw `u64` handle and return the FlatBuffers
/// `Envelope` bytes: ok with NO `data` and the report in `Envelope.precondition`.
Uint8List zanshinSnapshot(int rawHandle) => readToken(zanshin_snapshot(rawHandle));

// ── Dart models ──────────────────────────────────────────────────────────────

/// The refs the colocated Git export could not write when the jj CLI finished a
/// transaction (mirrors `zanshin_jj::FinishFacts`) — a warning there, never an
/// error; also reported as `jj.git_export_failed` warnings.
final class FinishFacts {
  const FinishFacts({
    required this.exportFailedBookmarks,
    required this.exportFailedTags,
  });

  /// Bookmarks the colocated export could not write to Git.
  final List<GitExportFailure> exportFailedBookmarks;

  /// Tags the colocated export could not write to Git.
  final List<GitExportFailure> exportFailedTags;
}

/// What the implicit pre-verb snapshot did (mirrors `zanshin_jj::Precondition`)
/// — the facts the jj CLI prints before a command runs, as typed fields.
///
/// Every envelope of a snapshotting verb carries one, on success AND on error; on
/// an error it is PARTIAL — every field up to the failing step is filled, the
/// rest keep their defaults. `RepoHandle.lastPrecondition` holds the latest.
/// The CLI's pure notes (`@` was immutable, `.jjconflict` files present, …) are
/// not fields: they are the call's warnings (Story 9.32).
final class Precondition {
  const Precondition({
    required this.wasSnapshotTaken,
    required this.snapshotStats,
    required this.gitHeadImported,
    required this.gitHeadReset,
    required this.gitHeadRebased,
    required this.snapshotRebased,
    required this.gitRefs,
    required this.gitRefsRebased,
    required this.finish,
    this.staleRecovery,
    this.warnings = const [],
  });

  /// Whether the head operation changed during the precondition — an operation
  /// was written, or the repo was reloaded at a newer working-copy operation.
  final bool wasSnapshotTaken;

  /// What the snapshot could not record — the CLI's snapshot warnings.
  final SnapshotStats snapshotStats;

  /// Whether an `import git head` operation was written (colocated only).
  final bool gitHeadImported;

  /// The head import moved `@` onto a new Git HEAD while a previous one existed
  /// (the CLI's "Reset the working copy parent to the new Git HEAD.").
  final bool gitHeadReset;

  /// Descendants rebased by the head import; saturates at 4294967295.
  final int gitHeadRebased;

  /// Descendants rebased onto the snapshotted `@`; saturates at 4294967295.
  final int snapshotRebased;

  /// The `import git refs` step's outcome. Non-null exactly when the step RAN
  /// (colocated workspaces), even when it changed nothing.
  final GitImportResult? gitRefs;

  /// Descendants rebased off commits the refs import rewrote; saturates at
  /// 4294967295.
  final int gitRefsRebased;

  /// The ref exports that failed inside the precondition; `null` when none did.
  final FinishFacts? finish;

  /// What the stale-working-copy recovery did when `snapshot.auto-update-stale
  /// = true` recovered a stale working copy before the verb ran (Story 9.23) —
  /// the facts the CLI prints ahead of the verb's own output; `null` whenever no
  /// recovery ran.
  final StaleRecovery? staleRecovery;

  /// The call's warnings (Story 9.32) when this report is the result of
  /// `RepoHandle.snapshot`, in the CLI's print order; empty when there were
  /// none, and always empty on the report `RepoHandle.lastPrecondition` holds
  /// and on a thrown `ZanshinFfiException.precondition` — a failed call's
  /// warnings are the exception's `warnings` (Story 9.35).
  final List<ZanshinWarning> warnings;
}

// ── Decoders ─────────────────────────────────────────────────────────────────

/// Rebuild a [FinishFacts]; an ABSENT table is `null` (null for absence).
FinishFacts? decodeFinishFactsInternal(fbs.FinishFacts? f) => f == null
    ? null
    : FinishFacts(
        exportFailedBookmarks: decodeExportFailuresInternal(f.exportFailedBookmarks),
        exportFailedTags: decodeExportFailuresInternal(f.exportFailedTags),
      );

/// Rebuild a [Precondition]; an ABSENT table is `null` (null for absence).
/// [warnings] are the enclosing envelope's — only `zanshin_snapshot`'s decode
/// passes any.
Precondition? decodePreconditionInternal(fbs.Precondition? p, {List<ZanshinWarning> warnings = const []}) => p == null
    ? null
    : Precondition(
        wasSnapshotTaken: p.wasSnapshotTaken,
        snapshotStats: decodeSnapshotStatsInternal(p.snapshotStats),
        gitHeadImported: p.gitHeadImported,
        gitHeadReset: p.gitHeadReset,
        gitHeadRebased: p.gitHeadRebased,
        snapshotRebased: p.snapshotRebased,
        gitRefs: switch (p.gitRefs) {
          final fbs.GitImportResult r => decodeGitImportResultInternal(r),
          null => null,
        },
        gitRefsRebased: p.gitRefsRebased,
        finish: decodeFinishFactsInternal(p.finish),
        staleRecovery: decodeStaleRecoveryInternal(p.staleRecovery),
        warnings: warnings,
      );

/// The `Envelope.precondition` of ANY envelope — ok or error — or `null` when
/// the call ran no precondition.
///
/// Exposed for decode-contract tests with synthetic buffers; production reads go
/// through `ZanshinWorker`'s single choke point.
@visibleForTesting
Precondition? decodeEnvelopePrecondition(Uint8List bytes) => decodeEnvelopePreconditionInternal(bytes);

/// Internal decoder used by production code in `isolate.dart`.
Precondition? decodeEnvelopePreconditionInternal(Uint8List bytes) =>
    decodePreconditionInternal(fbs.Envelope(bytes).precondition);

/// The creating call's report on an init/clone/convert ok envelope (Story 9.33):
/// its warnings — absent reads as `[]` — and, for convert only, the conversion's
/// snapshot report — absent reads as `null`.
///
/// Exposed for decode-contract tests with synthetic buffers; production reads go
/// through `ZanshinWorker.initRepo` / `cloneRepo` / `convert`.
@visibleForTesting
({List<ZanshinWarning> warnings, Precondition? precondition}) decodeCreationReport(Uint8List bytes) =>
    decodeCreationReportInternal(bytes);

/// Internal decoder used by production code in `isolate.dart`.
({List<ZanshinWarning> warnings, Precondition? precondition}) decodeCreationReportInternal(Uint8List bytes) {
  final env = fbs.Envelope(bytes);
  return (warnings: decodeEnvelopeWarningsInternal(env), precondition: decodePreconditionInternal(env.precondition));
}

/// Decode an error envelope (`ok == false`) into the [ZanshinFfiException] it
/// stands for — the ONE place an exception is built from an `FfiError`, which
/// every decoder's `!env.ok` branch throws (Story 9.35).
///
/// The code, context, hints and left-behind paths come from the envelope's
/// `error` (`ffi.unknown`, `null`, `[]` and `[]` when it is absent; absent
/// `hints` read as `[]`, Story 9.56, and so does an absent `left_behind`, Story
/// 9.57); the report — the PARTIAL pre-verb snapshot report and the warnings — rides
/// along exactly as on an ok envelope, `null` / empty when the envelope has
/// none.
ZanshinFfiException decodeEnvelopeErrorInternal(fbs.Envelope env) {
  final fbs.FfiError? e = env.error;
  return ZanshinFfiException.withReport(
    e?.code ?? 'ffi.unknown',
    e?.context,
    precondition: decodePreconditionInternal(env.precondition),
    warnings: decodeEnvelopeWarningsInternal(env),
    hints: decodeErrorHintsInternal(e),
    leftBehind: _decodeStrings(e?.leftBehind),
  );
}

/// Decode an `FfiError`'s `hints` (Story 9.56): absent (or `error` itself
/// absent) reads as `[]`; the list is unmodifiable and keeps the wire order
/// (the CLI's order). Shared with the drop-action refusals, whose `refusal` is
/// the same table.
List<String> decodeErrorHintsInternal(fbs.FfiError? error) => _decodeStrings(error?.hints);

/// Decode an `FfiError` `[string]` field — `hints` (Story 9.56) or
/// `left_behind` (Story 9.57): absent reads as `[]`; the list is unmodifiable
/// and keeps the wire order.
List<String> _decodeStrings(List<String>? strings) {
  if (strings == null || strings.isEmpty) {
    return const [];
  }
  return List.unmodifiable(strings);
}

/// Decode a `zanshin_snapshot` `Envelope` buffer into its [Precondition].
///
/// Exposed for decode-contract tests with synthetic buffers; production calls go
/// through `ZanshinWorker.snapshot`.
@visibleForTesting
Precondition decodeSnapshotEnvelope(Uint8List bytes) => decodeSnapshotEnvelopeInternal(bytes);

/// Internal decoder used by production code in `isolate.dart`.
Precondition decodeSnapshotEnvelopeInternal(Uint8List bytes) {
  final env = fbs.Envelope(bytes);
  if (!env.ok) {
    throw decodeEnvelopeErrorInternal(env);
  }
  // Rust always writes the report on success, so its absence is a corrupt
  // buffer — refused rather than guessed.
  return decodePreconditionInternal(env.precondition, warnings: decodeEnvelopeWarningsInternal(env)) ??
      (throw const ZanshinFfiException('ffi.unknown', 'snapshot envelope carries no precondition'));
}
