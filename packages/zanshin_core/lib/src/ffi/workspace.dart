// SPDX-License-Identifier: MIT

import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../worker/responses.dart';
import 'bindings.dart';
import 'envelope_zanshin.ffi_generated.dart' as fbs;
import 'precondition.dart' show decodeEnvelopeErrorInternal;
import 'request_bytes.dart';
import 'warning.dart';

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
// They are also asymmetric when no path can be reported, deliberately: a
// [WorkspaceEntry.root] degrades to `null` while [workspaceRoot] refuses. The
// CLI's own list template degrades the same way. A recorded directory that no
// longer exists is reported by both (jj 0.46); [workspaceRoot] adds a warning.

// ── FFI adapters ─────────────────────────────────────────────────────────────

/// Call `zanshin_workspace_list` with the raw `u64` handle and return the
/// FlatBuffers `Envelope` bytes.
///
/// Only the worker isolate calls this — raw handles never leave the worker
/// (Model A, Story 3.9). No argument: `jj workspace list` takes none, and its
/// `-T/--template` flag is rendering.
Uint8List zanshinWorkspaceList(int rawHandle) => readToken(zanshin_workspace_list(rawHandle));

/// Call `zanshin_workspace_root` with the raw `u64` handle and a
/// `WorkspaceRootRequest` request buffer, and return the FlatBuffers `Envelope`
/// bytes.
///
/// A `null` [name] is the wire form of "the user did not supply `--name`", which
/// applies the CLI's own default — the CURRENT workspace — and reads the
/// workspace loader alone, the one path that cannot fail. A PRESENT [name], even
/// the current workspace's own, goes through the workspace store and can REFUSE
/// or WARN: the CLI's named path never shortcuts to the loader. An explicitly EMPTY [name]
/// is a VALUE, not an absence, and refuses as `jj.workspace_not_found`.
Uint8List zanshinWorkspaceRoot(int rawHandle, {String? name}) {
  rejectInteriorNul(name, 'name');
  final Uint8List request = fbs.WorkspaceRootRequestObjectBuilder(
    kind: fbs.RequestKind.WorkspaceRoot,
    name: name,
  ).toBytes();
  return withRequestBytes(request, (ptr, len) => readToken(zanshin_workspace_root(rawHandle, ptr, len)));
}

// ── Dart models ──────────────────────────────────────────────────────────────

/// One row of `jj workspace list` (mirrors `zanshin_jj::WorkspaceEntry`).
final class WorkspaceEntry {
  const WorkspaceEntry({required this.name, required this.wcCommitId, required this.root});

  /// The jj workspace name (`"default"` in a single-workspace repo).
  final String name;

  /// Hex commit id of that workspace's working-copy commit — the entry jj's
  /// `View::wc_commit_ids()` holds for this workspace name. For the CURRENT
  /// workspace it is the commit whose change id `status.dart`'s
  /// `WorkingCopyStatus.workingCopyChangeId` reports.
  final String wcCommitId;

  /// Absolute RECORDED path of the workspace's root directory — reported even
  /// when that directory moved or was deleted (jj 0.46) — or `null` when no path
  /// can be reported: the workspace predates jj 0.38.0 and has no recorded path,
  /// or the store is unreadable. Null-for-absence — never a sentinel — and never
  /// a reason for the listing to fail.
  final String? root;
}

/// The result of `workspaceRoot` (Story 9.32): the absolute root path plus the
/// call's warnings.
final class WorkspaceRootResult {
  const WorkspaceRootResult({required this.path, this.warnings = const []});

  /// Absolute path of the named workspace's root directory.
  final String path;

  /// The call's warnings, in the CLI's print order; empty when there were none.
  final List<ZanshinWarning> warnings;
}

// ── Decoder ──────────────────────────────────────────────────────────────────

/// Decode a `WorkspaceList` `Envelope` buffer into a `List<WorkspaceEntry>` that
/// also carries the call's warnings.
///
/// Exposed for decode-contract tests with synthetic buffers; production calls go
/// through `ZanshinWorker.workspaceList`.
@visibleForTesting
WarnedList<WorkspaceEntry> decodeWorkspaceListEnvelope(Uint8List bytes) => _decodeWorkspaceListEnvelope(bytes);

/// Internal decoder used by production code in `isolate.dart`.
WarnedList<WorkspaceEntry> decodeWorkspaceListEnvelopeInternal(Uint8List bytes) => _decodeWorkspaceListEnvelope(bytes);

WarnedList<WorkspaceEntry> _decodeWorkspaceListEnvelope(Uint8List bytes) {
  final fbs.Envelope env = _okEnvelope(bytes);
  final Object? payload = env.data;
  if (payload is! fbs.WorkspaceList) {
    throw ZanshinFfiException('ffi.unknown', 'expected WorkspaceList payload, got ${env.dataType}');
  }
  return WarnedList(
    payload.entries?.map(_mapWorkspaceEntry).toList() ?? const [],
    decodeEnvelopeWarningsInternal(env),
  );
}

WorkspaceEntry _mapWorkspaceEntry(fbs.WorkspaceEntry e) => WorkspaceEntry(
  name: e.name ?? '',
  wcCommitId: e.wcCommitId ?? '',
  // Null-for-absence, not a sentinel: an absent root means the path cannot be
  // reported, which is a modelled state rather than an error.
  root: e.root,
);

/// Decode a `WorkspaceRoot` `Envelope` buffer into the absolute root path and
/// the call's warnings.
///
/// Exposed for decode-contract tests with synthetic buffers; production calls go
/// through `ZanshinWorker.workspaceRoot`.
@visibleForTesting
WorkspaceRootResult decodeWorkspaceRootEnvelope(Uint8List bytes) => _decodeWorkspaceRootEnvelope(bytes);

/// Internal decoder used by production code in `isolate.dart`.
WorkspaceRootResult decodeWorkspaceRootEnvelopeInternal(Uint8List bytes) => _decodeWorkspaceRootEnvelope(bytes);

WorkspaceRootResult _decodeWorkspaceRootEnvelope(Uint8List bytes) {
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
  return WorkspaceRootResult(path: root, warnings: decodeEnvelopeWarningsInternal(env));
}

/// Parse [bytes] as an `Envelope` and throw [ZanshinFfiException] when it is not ok.
fbs.Envelope _okEnvelope(Uint8List bytes) {
  final env = fbs.Envelope(bytes);
  if (!env.ok) {
    throw decodeEnvelopeErrorInternal(env);
  }
  return env;
}
