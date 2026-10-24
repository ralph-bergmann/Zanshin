// SPDX-License-Identifier: MIT

import 'dart:typed_data'; // explicit for Uint8List clarity

import 'package:meta/meta.dart';

import '../worker/responses.dart';
import 'bindings.dart';
import 'envelope_zanshin.ffi_generated.dart' as fbs;
import 'precondition.dart' show decodeEnvelopeErrorInternal;
import 'request_bytes.dart';
import 'warning.dart';

// ── FFI adapter ───────────────────────────────────────────────────────────────

/// Call `zanshin_status` with the raw `u64` handle and return the
/// FlatBuffers `Envelope` bytes.
///
/// Only the worker isolate calls this — raw handles never leave the worker
/// (Model A, Story 3.9). The [int] is passed directly to Rust; no Dart-side
/// `Pointer` is materialised. Mirrors `zanshinRepoClose` in `repo.dart`.
Uint8List zanshinStatus(int rawHandle) => readToken(zanshin_status(rawHandle));

// ── Dart models ───────────────────────────────────────────────────────────────

/// Working-copy status: changed files between @ and @-; without @ in this
/// workspace (the CLI's "No working copy.") no files and both ids `null`.
final class WorkingCopyStatus {
  const WorkingCopyStatus({
    required this.files,
    required this.workingCopyChangeId,
    required this.parentChangeId,
    this.warnings = const [],
  });

  /// Files changed between the working copy (@) and its parent (@-); empty
  /// when this workspace has no @.
  final List<FileChange> files;

  /// Change id of the working-copy commit in jj reverse-hex display form;
  /// `null` exactly when this workspace has no @ (the CLI's "No working
  /// copy."), and [files] is then empty.
  final String? workingCopyChangeId;

  /// Change id of the parent commit in jj reverse-hex display form; `null`
  /// together with [workingCopyChangeId].
  final String? parentChangeId;

  /// The call's warnings (Story 9.32), in the CLI's print order; empty when
  /// there were none.
  final List<ZanshinWarning> warnings;
}

/// A single file changed between @ and @-.
final class FileChange {
  const FileChange({
    required this.path,
    required this.kind,
    this.fromPath,
  });

  /// Repo-relative path of the file.
  final String path;

  /// How the file changed.
  final FileChangeKind kind;

  /// Source path for [FileChangeKind.renamed] and [FileChangeKind.copied];
  /// `null` for all other kinds.
  final String? fromPath;
}

/// How a working-copy file changed between @- and @.
enum FileChangeKind {
  added,
  modified,
  removed,
  renamed,
  copied,
}

// ── Decoder ───────────────────────────────────────────────────────────────────

/// Decode a `Status` `Envelope` buffer into a [WorkingCopyStatus].
///
/// Throws [ZanshinFfiException] on `!ok`, or when the payload is not a
/// `Status` table — guarding the union discriminant before the cast, the same
/// way `decodeDiagnosticsEnvelope` guards `dataType` before the Diagnostics
/// cast. A non-`Status` or absent payload yields the `ffi.unknown` sentinel
/// rather than a raw `TypeError`.
///
/// Exposed for decode-contract tests with synthetic buffers; production calls
/// go through `ZanshinWorker.status`.
@visibleForTesting
WorkingCopyStatus decodeStatusEnvelope(Uint8List bytes) => _decodeStatusEnvelope(bytes);

/// Internal decoder used by production code in `isolate.dart`.
WorkingCopyStatus decodeStatusEnvelopeInternal(Uint8List bytes) => _decodeStatusEnvelope(bytes);

WorkingCopyStatus _decodeStatusEnvelope(Uint8List bytes) {
  final env = fbs.Envelope(bytes);
  if (!env.ok) {
    throw decodeEnvelopeErrorInternal(env);
  }
  final Object? payload = env.data;
  if (payload is! fbs.Status) {
    throw ZanshinFfiException(
      'ffi.unknown',
      'expected Status payload, got ${env.dataType}',
    );
  }
  return WorkingCopyStatus(
    files: _mapFiles(payload),
    workingCopyChangeId: payload.workingCopyChangeId,
    parentChangeId: payload.parentChangeId,
    warnings: decodeEnvelopeWarningsInternal(env),
  );
}

List<FileChange> _mapFiles(fbs.Status payload) {
  final List<fbs.FileChange>? fbFiles = payload.files;
  if (fbFiles == null) {
    return const [];
  }
  return List.generate(fbFiles.length, (i) => mapFileChangeTable(fbFiles[i]));
}

/// Map a generated `FileChange` TABLE into the Dart model.
///
/// Library-internal: the `FileChange` table is the shipped per-path change
/// vocabulary, carried by `Status` and — since Story 9.6 — by `ShowEntry` and
/// `InterdiffView`. Every decoder goes through this one mapper, so a field added
/// to `FileChange` cannot be wired into one decoder only.
FileChange mapFileChangeTable(fbs.FileChange f) =>
    FileChange(path: f.path ?? '', kind: _mapChangeKind(f.kind), fromPath: f.fromPath);

FileChangeKind _mapChangeKind(fbs.ChangeKind kind) => switch (kind) {
  fbs.ChangeKind.Added => FileChangeKind.added,
  fbs.ChangeKind.Modified => FileChangeKind.modified,
  fbs.ChangeKind.Removed => FileChangeKind.removed,
  fbs.ChangeKind.Renamed => FileChangeKind.renamed,
  fbs.ChangeKind.Copied => FileChangeKind.copied,
};
