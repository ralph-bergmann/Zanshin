// SPDX-License-Identifier: MIT

import 'dart:typed_data';

import '../worker/responses.dart';
import 'envelope_zanshin.ffi_generated.dart' as fbs;

/// Dart-domain classification returned by [decodeRepoDetectEnvelope].
///
/// Order mirrors `zanshin_jj::RepoKind` and `fbs.RepoKind` — do not reorder.
enum RepoKind {
  /// Path is a jj workspace (`.jj/` present).
  jj,

  /// Path is a plain Git repository (`.git/` present, no `.jj/`).
  git,

  /// Path exists but contains neither a jj nor a Git repository.
  neither,

  /// Path does not exist on disk.
  pathNotFound,
}

/// Result of a `zanshin_repo_detect` call (FR-JJ-17).
///
/// [kind] is always set.
/// [suggestedRoot] and [suggestedKind] are non-null only when [kind] is
/// [RepoKind.neither] or [RepoKind.pathNotFound] and the consent-gated
/// ancestor walk found an enclosing jj/Git repo (FR-JJ-14).
/// The UI decides whether to offer opening it — the backend never auto-opens.
class RepoDetectResult {
  const RepoDetectResult({
    required this.kind,
    this.suggestedRoot,
    this.suggestedKind,
  });

  final RepoKind kind;
  final String? suggestedRoot;
  final RepoKind? suggestedKind;
}

/// Decodes a raw `Envelope<RepoDetect>` buffer into a [RepoDetectResult].
///
/// Throws [ZanshinFfiException] on error envelopes or unexpected payloads.
///
/// A `RepoKind` byte outside `0..=3` surfaces as the generated `StateError`
/// from `RepoKind.fromValue`, not as a [ZanshinFfiException]. This is by design:
/// both sides are generated from one schema and the Rust producer only emits
/// `0..=3`, so an out-of-range byte means cdylib/bindings version-skew or memory
/// corruption — a programming error that must crash loudly, not a recoverable
/// condition. The `avoid_catching_errors` lint correctly forbids converting it.
RepoDetectResult decodeRepoDetectEnvelope(Uint8List bytes) => _decodeRepoDetectEnvelope(bytes);

/// Internal variant exposed for testing (same as [decodeRepoDetectEnvelope]).
RepoDetectResult decodeRepoDetectEnvelopeInternal(Uint8List bytes) => _decodeRepoDetectEnvelope(bytes);

RepoDetectResult _decodeRepoDetectEnvelope(Uint8List bytes) {
  final env = fbs.Envelope(bytes);
  if (!env.ok) {
    final fbs.FfiError? e = env.error;
    throw ZanshinFfiException(e?.code ?? 'ffi.unknown', e?.context);
  }
  final Object? payload = env.data;
  if (payload is! fbs.RepoDetect) {
    throw ZanshinFfiException(
      'ffi.unknown',
      'expected RepoDetect payload, got ${env.dataType}',
    );
  }
  final String? suggestedRoot = payload.suggestedRoot;
  return RepoDetectResult(
    kind: _mapRepoKind(payload.kind),
    suggestedRoot: suggestedRoot,
    suggestedKind: suggestedRoot != null ? _mapRepoKind(payload.suggestedKind) : null,
  );
}

RepoKind _mapRepoKind(fbs.RepoKind k) => switch (k) {
  fbs.RepoKind.Jj => RepoKind.jj,
  fbs.RepoKind.Git => RepoKind.git,
  fbs.RepoKind.Neither => RepoKind.neither,
  fbs.RepoKind.PathNotFound => RepoKind.pathNotFound,
};
