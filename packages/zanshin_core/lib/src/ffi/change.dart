// SPDX-License-Identifier: MIT

import 'dart:ffi' as ffi;
import 'dart:typed_data'; // ignore: unnecessary_import — explicit for Uint8List clarity

import 'package:ffi/ffi.dart';
import 'package:meta/meta.dart';

import '../worker/responses.dart';
import 'bindings.dart';
import 'envelope_zanshin.ffi_generated.dart' as fbs;
import 'ffi_buffer.dart';

// ── FFI adapter ───────────────────────────────────────────────────────────────

/// Call `zanshin_change` with the raw `u64` handle and a jj reverse-hex
/// [changeId] string, and return the FlatBuffers `Envelope` bytes.
///
/// Only the worker isolate calls this — raw handles never leave the worker
/// (Model A, Story 3.9). The C string for [changeId] is allocated by Dart
/// via `toNativeUtf8` and freed by Dart via `calloc.free` (AR-P-5 inbound
/// rule — Rust only borrows it for the duration of the call).
///
/// Errors: `ffi.null_pointer` (never — we always pass a valid pointer),
/// `ffi.invalid_handle`, `jj.change_not_found`, `jj.jj_lib_error`.
Uint8List zanshinChange(int rawHandle, String changeId) {
  final ffi.Pointer<Utf8> p = changeId.toNativeUtf8();
  try {
    final ffi.Pointer<ZanshinBuf> token = zanshin_change(rawHandle, p.cast());
    final buf = FfiBuffer.fromToken(token);
    try {
      return Uint8List.fromList(buf.bytes);
    } finally {
      buf.dispose(); // inner: free the returned buffer
    }
  } finally {
    calloc.free(p); // outer: free the C string we allocated
  }
}

// ── Dart models ───────────────────────────────────────────────────────────────

/// Whether a change is conflict-free.
enum ConflictState {
  clean,
  conflicted,
}

/// Who authored or committed a change, and when.
final class Signature {
  const Signature({
    required this.name,
    required this.email,
    required this.timestampMillis,
    required this.tzOffsetMinutes,
  });

  /// Author/committer name (jj allows empty).
  final String name;

  /// Author/committer email (jj allows empty).
  final String email;

  /// Milliseconds since the Unix epoch (raw jj timestamp).
  final int timestampMillis;

  /// Timezone offset in minutes east of UTC (raw jj convention).
  final int tzOffsetMinutes;
}

/// Full metadata for one jj change (FR-JJ-6).
///
/// [id] is the stable reverse-hex change identifier (e.g. `"qpvuntsm…"`);
/// [commitId] is the Git-backend SHA that changes on every rebase.
final class Change {
  const Change({
    required this.id,
    required this.commitId,
    required this.parents,
    required this.description,
    required this.author,
    required this.committer,
    required this.isSigned,
    required this.conflict,
    required this.conflictedPaths,
    required this.isAnonymous,
    required this.divergent,
  });

  /// Stable jj change identifier in reverse-hex form (e.g. `"qpvuntsm…"`).
  final String id;

  /// Git-backend commit hash in hex form (changes on rebase).
  final String commitId;

  /// Parent change ids in jj order; empty list for the root change.
  final List<String> parents;

  /// Commit description; always present but may be empty (jj convention).
  final String description;

  final Signature author;
  final Signature committer;

  /// Milliseconds since the Unix epoch when the change was authored.
  /// Derived from `author.timestampMillis`.
  int get authoredAt => author.timestampMillis;

  /// Milliseconds since the Unix epoch when the change was committed.
  /// Derived from `committer.timestampMillis`.
  int get committedAt => committer.timestampMillis;

  /// `true` if a cryptographic (GPG/SSH) signature is present (presence-only).
  final bool isSigned;

  /// Whether the change has merge conflicts.
  final ConflictState conflict;

  /// Conflicted file paths; empty when [conflict] is [ConflictState.clean].
  final List<String> conflictedPaths;

  /// `true` when the description is empty and no local bookmark targets this commit.
  final bool isAnonymous;

  /// `true` when this change id resolves to more than one visible commit.
  final bool divergent;
}

// ── Decoder ───────────────────────────────────────────────────────────────────

/// Decode a `Change` `Envelope` buffer into a [Change].
///
/// Throws [ZanshinFfiException] on `!ok`, or when the payload is not a
/// `Change` table — guarding the union discriminant before the cast (same
/// discipline as `decodeStatusEnvelope`). A non-`Change` payload yields the
/// `ffi.unknown` sentinel rather than a raw `TypeError`.
///
/// Exposed for decode-contract tests with synthetic buffers; production calls
/// go through `ZanshinWorker.getChange`.
@visibleForTesting
Change decodeChangeEnvelope(Uint8List bytes) => _decodeChangeEnvelope(bytes);

/// Internal decoder used by production code in `isolate.dart`.
Change decodeChangeEnvelopeInternal(Uint8List bytes) => _decodeChangeEnvelope(bytes);

Change _decodeChangeEnvelope(Uint8List bytes) {
  final env = fbs.Envelope(bytes);
  if (!env.ok) {
    final fbs.FfiError? e = env.error;
    throw ZanshinFfiException(e?.code ?? 'ffi.unknown', e?.context);
  }
  final Object? payload = env.data;
  if (payload is! fbs.Change) {
    throw ZanshinFfiException(
      'ffi.unknown',
      'expected Change payload, got ${env.dataType}',
    );
  }
  return Change(
    id: payload.id ?? '',
    commitId: payload.commitId ?? '',
    parents: payload.parents?.toList() ?? const [],
    description: payload.description ?? '',
    author: _mapSignature(payload.author),
    committer: _mapSignature(payload.committer),
    isSigned: payload.isSigned,
    conflict: _mapConflictState(payload.conflict),
    conflictedPaths: payload.conflictedPaths?.toList() ?? const [],
    isAnonymous: payload.isAnonymous,
    divergent: payload.divergent,
  );
}

Signature _mapSignature(fbs.Signature? sig) => Signature(
  name: sig?.name ?? '',
  email: sig?.email ?? '',
  timestampMillis: sig?.timestampMillis ?? 0,
  tzOffsetMinutes: sig?.tzOffsetMinutes ?? 0,
);

ConflictState _mapConflictState(fbs.ConflictState state) => switch (state) {
  fbs.ConflictState.Clean => ConflictState.clean,
  fbs.ConflictState.Conflicted => ConflictState.conflicted,
};
