// SPDX-License-Identifier: MIT

import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:meta/meta.dart';

import '../worker/responses.dart';
import 'bindings.dart';
import 'envelope_zanshin.ffi_generated.dart' as fbs;
import 'ffi_buffer.dart';

// This file owns the Dart half of Story 9.7's two workspace READ verbs: the
// adapters (workspaceList / workspaceRoot), the list-row model, and the two
// decoders. `dart:ffi` stays inside `ffi/` — only the worker isolate calls these
// adapters.
//
// The two verbs cross the boundary DIFFERENTLY, mirroring the CLI's own argument
// arity: `workspace list` is handle-only (its lone `-T/--template` flag is
// rendering), while `workspace root` sends a FlatBuffers REQUEST buffer, because
// its `--name` must be distinguishably ABSENT — that absence is what applies the
// CLI's documented default, the current workspace.
//
// They are also asymmetric on an unusable recorded path, deliberately: a
// [WorkspaceEntry.root] degrades to `null` while [workspaceRoot] refuses. The
// CLI's own list template degrades the same way and points at
// `jj workspace root --name` for strict path diagnostics.

// ── Request-buffer helpers ───────────────────────────────────────────────────

/// Copy [bytes] into a `malloc`-allocated `Pointer<Uint8>`, invoke [fn] with the
/// pointer and byte length, and free the pointer afterward.
///
/// Same ownership discipline as `commit_views.dart`'s identical helper (AR-P-5
/// inbound rule): Rust only borrows the buffer for the duration of the call.
T _withRequestBytes<T>(Uint8List bytes, T Function(ffi.Pointer<ffi.Uint8>, int) fn) {
  final ffi.Pointer<ffi.Uint8> ptr = malloc.allocate<ffi.Uint8>(bytes.length);
  ptr.asTypedList(bytes.length).setAll(0, bytes);
  try {
    return fn(ptr, bytes.length);
  } finally {
    malloc.free(ptr);
  }
}

/// Reject an interior NUL in a caller-supplied string.
///
/// A FlatBuffers string is length-prefixed, so a NUL would survive the wire — and
/// then land in a workspace name, where it can only produce a confusing
/// downstream failure.
void _rejectInteriorNul(String? value, String name) {
  if (value != null && value.codeUnits.contains(0)) {
    throw ArgumentError.value(value, name, 'must not contain an interior NUL (U+0000)');
  }
}

/// Copy the envelope out of a returned token before freeing it.
Uint8List _readToken(ffi.Pointer<ZanshinBuf> token) {
  final buf = FfiBuffer.fromToken(token);
  try {
    return Uint8List.fromList(buf.bytes);
  } finally {
    buf.dispose();
  }
}

// ── FFI adapters ─────────────────────────────────────────────────────────────

/// Call `zanshin_workspace_list` with the raw `u64` handle and return the
/// FlatBuffers `Envelope` bytes.
///
/// Only the worker isolate calls this — raw handles never leave the worker
/// (Model A, Story 3.9). No argument: `jj workspace list` takes none, and its
/// `-T/--template` flag is rendering.
Uint8List zanshinWorkspaceList(int rawHandle) => _readToken(zanshin_workspace_list(rawHandle));

/// Call `zanshin_workspace_root` with the raw `u64` handle and a
/// `WorkspaceRootRequest` request buffer, and return the FlatBuffers `Envelope`
/// bytes.
///
/// A `null` [name] is the wire form of "the user did not supply `--name`", which
/// applies the CLI's own default — the CURRENT workspace — and reads the
/// workspace loader alone, the one path that cannot fail. A PRESENT [name], even
/// the current workspace's own, goes through the workspace store and can REFUSE:
/// the CLI's named path never shortcuts to the loader. An explicitly EMPTY [name]
/// is a VALUE, not an absence, and refuses as `jj.workspace_not_found`.
Uint8List zanshinWorkspaceRoot(int rawHandle, {String? name}) {
  _rejectInteriorNul(name, 'name');
  final Uint8List request = fbs.WorkspaceRootRequestObjectBuilder(name: name).toBytes();
  return _withRequestBytes(request, (ptr, len) => _readToken(zanshin_workspace_root(rawHandle, ptr, len)));
}

// ── Dart models ──────────────────────────────────────────────────────────────

/// One row of `jj workspace list` (mirrors `zanshin_jj::WorkspaceEntry`).
final class WorkspaceEntry {
  const WorkspaceEntry({required this.name, required this.wcCommitId, required this.root});

  /// The jj workspace name (`"default"` in a single-workspace repo).
  final String name;

  /// Hex commit id of that workspace's working-copy commit — the same value
  /// `WorkingCopy.commitId` carries for this workspace.
  final String wcCommitId;

  /// Absolute path of the workspace's root directory, or `null` when it cannot
  /// be reported: the workspace predates jj 0.38.0 and has no recorded path, the
  /// store is unreadable, or the recorded directory moved or was deleted.
  /// Null-for-absence — never a sentinel — and never a reason for the listing to
  /// fail. Use [zanshinWorkspaceRoot] for strict path diagnostics.
  final String? root;
}

// ── Decoder ──────────────────────────────────────────────────────────────────

/// Decode a `WorkspaceList` `Envelope` buffer into a `List<WorkspaceEntry>`.
///
/// Exposed for decode-contract tests with synthetic buffers; production calls go
/// through `ZanshinWorker.workspaceList`.
@visibleForTesting
List<WorkspaceEntry> decodeWorkspaceListEnvelope(Uint8List bytes) => _decodeWorkspaceListEnvelope(bytes);

/// Internal decoder used by production code in `isolate.dart`.
List<WorkspaceEntry> decodeWorkspaceListEnvelopeInternal(Uint8List bytes) => _decodeWorkspaceListEnvelope(bytes);

List<WorkspaceEntry> _decodeWorkspaceListEnvelope(Uint8List bytes) {
  final fbs.Envelope env = _okEnvelope(bytes);
  final Object? payload = env.data;
  if (payload is! fbs.WorkspaceList) {
    throw ZanshinFfiException('ffi.unknown', 'expected WorkspaceList payload, got ${env.dataType}');
  }
  return payload.entries?.map(_mapWorkspaceEntry).toList() ?? const [];
}

WorkspaceEntry _mapWorkspaceEntry(fbs.WorkspaceEntry e) => WorkspaceEntry(
  name: e.name ?? '',
  wcCommitId: e.wcCommitId ?? '',
  // Null-for-absence, not a sentinel: an absent root means the path cannot be
  // reported, which is a modelled state rather than an error.
  root: e.root,
);

/// Decode a `WorkspaceRoot` `Envelope` buffer into the absolute root path.
///
/// Exposed for decode-contract tests with synthetic buffers; production calls go
/// through `ZanshinWorker.workspaceRoot`.
@visibleForTesting
String decodeWorkspaceRootEnvelope(Uint8List bytes) => _decodeWorkspaceRootEnvelope(bytes);

/// Internal decoder used by production code in `isolate.dart`.
String decodeWorkspaceRootEnvelopeInternal(Uint8List bytes) => _decodeWorkspaceRootEnvelope(bytes);

String _decodeWorkspaceRootEnvelope(Uint8List bytes) {
  final fbs.Envelope env = _okEnvelope(bytes);
  final Object? payload = env.data;
  if (payload is! fbs.WorkspaceRoot) {
    throw ZanshinFfiException('ffi.unknown', 'expected WorkspaceRoot payload, got ${env.dataType}');
  }
  final String? root = payload.root;
  if (root == null) {
    // Unlike a list row's root, this field is ALWAYS written on success — the
    // verb refuses rather than reporting an absent path. A missing one is a
    // malformed buffer, not a modellable state.
    throw const ZanshinFfiException('ffi.unknown', 'WorkspaceRoot payload is missing its root');
  }
  return root;
}

/// Parse [bytes] as an `Envelope` and throw [ZanshinFfiException] when it is not ok.
fbs.Envelope _okEnvelope(Uint8List bytes) {
  final env = fbs.Envelope(bytes);
  if (!env.ok) {
    final fbs.FfiError? e = env.error;
    throw ZanshinFfiException(e?.code ?? 'ffi.unknown', e?.context);
  }
  return env;
}
