// SPDX-License-Identifier: MIT

import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'bindings.dart';
import 'envelope_zanshin.ffi_generated.dart' as fbs;
import 'request_bytes.dart';

/// Opens an existing jj repository at [path].
///
/// Returns the raw FlatBuffers `Envelope` bytes. The worker isolate decodes
/// them via the generated accessors.
///
/// Ownership: Dart allocates and frees the input C string (AR-P-5 inbound
/// rule); Rust borrows for the call. The returned [Uint8List] is a heap copy
/// safe to send across isolate ports and use after the buffer is freed.
///
/// Errors: `jj.path_not_found`, `jj.repo_not_found`.
Uint8List zanshinRepoOpen(String path) {
  final ffi.Pointer<Utf8> p = path.toNativeUtf8();
  try {
    return readToken(zanshin_repo_open(p.cast()));
  } finally {
    calloc.free(p);
  }
}

/// The object hash of a new Git repository — the CLI's `--object-hash`
/// (Story 9.20). `null` where a parameter takes it means the flag was not
/// given: the `git.object-hash` config decides.
enum ObjectHash {
  /// SHA-1, Git's classic format (the builtin `git.object-hash`).
  sha1,

  /// SHA-256.
  sha256,
}

fbs.ObjectHash _objectHash(ObjectHash? hash) => switch (hash) {
  null => fbs.ObjectHash.Unspecified,
  ObjectHash.sha1 => fbs.ObjectHash.Sha1,
  ObjectHash.sha256 => fbs.ObjectHash.Sha256,
};

/// Creates a new jj repository at [path] — the CLI's `jj git init` for
/// [backend] `1`, a workspace on jj's native backend for `0` (Story 9.20).
///
/// [colocate] / [noColocate] are the CLI's two flags (both set →
/// `jj.invalid_input`); neither = the `git.colocate` config. [objectHash] is
/// `--object-hash`. A Git init creates a missing [path] (one level).
///
/// Errors: `jj.invalid_input`, `jj.jj_lib_error`, `jj.git_repo_exists`,
/// `jj.already_jj_repo`, `jj.convert_failed`, `jj.config_error`,
/// `ffi.invalid_argument`.
Uint8List zanshinRepoInit(
  String path, {
  required int backend,
  bool colocate = false,
  bool noColocate = false,
  ObjectHash? objectHash,
}) {
  rejectInteriorNul(path, 'path');
  final fbs.InitBackend wireBackend = switch (backend) {
    0 => fbs.InitBackend.Native,
    1 => fbs.InitBackend.Git,
    _ => throw ArgumentError.value(backend, 'backend', 'must be 0 (native) or 1 (git)'),
  };
  final Uint8List request = fbs.RepoInitRequestObjectBuilder(
    kind: fbs.RequestKind.RepoInit,
    path: path,
    backend: wireBackend,
    colocate: colocate,
    noColocate: noColocate,
    objectHash: _objectHash(objectHash),
  ).toBytes();
  return callWithRequest(request, zanshin_repo_init);
}

/// Clones the Git repository at [source] into [destination] — the CLI's
/// `jj git clone` (Story 9.20).
///
/// [destination] must be missing or an empty directory (created with its
/// parents). [remoteName] is `--remote` (`null` = `origin`); [colocate] /
/// [noColocate] the CLI's two flags; [depth] `--depth` (`null` = the whole
/// history); [branches] / [tags] the `-b` / `-t` patterns (`null` = the flag
/// not given, an empty list = given with nothing); [objectHash]
/// `--object-hash`. Progress rides the event sink as `operation: "clone"`,
/// tagged with the session id the new handle gets.
///
/// Errors: `jj.invalid_input`, `jj.destination_not_empty`, `jj.jj_lib_error`,
/// `jj.config_error`, `ffi.invalid_argument`.
Uint8List zanshinRepoClone({
  required String source,
  required String destination,
  String? remoteName,
  bool colocate = false,
  bool noColocate = false,
  int? depth,
  List<String>? branches,
  List<String>? tags,
  ObjectHash? objectHash,
}) {
  rejectInteriorNul(source, 'source');
  rejectInteriorNul(destination, 'destination');
  rejectInteriorNul(remoteName, 'remoteName');
  rejectInteriorNuls(branches ?? const [], 'branches');
  rejectInteriorNuls(tags ?? const [], 'tags');
  if (depth != null && depth <= 0) {
    throw ArgumentError.value(depth, 'depth', 'must be positive');
  }
  final Uint8List request = fbs.RepoCloneRequestObjectBuilder(
    kind: fbs.RequestKind.RepoClone,
    source: source,
    destination: destination,
    remoteName: remoteName,
    colocate: colocate,
    noColocate: noColocate,
    depth: depth ?? 0,
    branches: branches,
    tags: tags,
    objectHash: _objectHash(objectHash),
  ).toBytes();
  return callWithRequest(request, zanshin_repo_clone);
}

/// Closes the repository identified by [rawHandle] (the raw `u64` pointer
/// value).
///
/// Only the worker isolate calls this — raw handles never leave the worker
/// (Model A, Story 3.9). The [int] is passed directly to Rust, which
/// reconstructs the pointer; no Dart-side `Pointer` is materialised.
///
/// Errors: `ffi.invalid_handle` (handle is `0` / already closed).
Uint8List zanshinRepoClose(int rawHandle) => readToken(zanshin_repo_close(rawHandle));

/// Detects the repository kind at [path].
///
/// Returns the raw FlatBuffers `Envelope<RepoDetect>` bytes. Decode with
/// `decodeRepoDetectEnvelope` from `repo_detect.dart`.
///
/// Success values: `RepoKind.Jj`, `.Git`, `.Neither`, `.PathNotFound`.
/// Errors: `jj.detect_failed` (filesystem I/O failure only).
Uint8List zanshinRepoDetect(String path) {
  final ffi.Pointer<Utf8> p = path.toNativeUtf8();
  try {
    return readToken(zanshin_repo_detect(p.cast()));
  } finally {
    calloc.free(p);
  }
}

/// Converts the Git repository at [path] to a colocated jj workspace.
///
/// Returns the raw FlatBuffers `Envelope<RepoHandle>` bytes.
///
/// Errors: `jj.already_jj_repo`, `jj.not_a_git_repo`, `jj.convert_failed`.
Uint8List zanshinRepoConvert(String path) {
  final ffi.Pointer<Utf8> p = path.toNativeUtf8();
  try {
    return readToken(zanshin_repo_convert(p.cast()));
  } finally {
    calloc.free(p);
  }
}
