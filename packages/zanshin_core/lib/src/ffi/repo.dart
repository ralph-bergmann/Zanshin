// SPDX-License-Identifier: MIT

import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'bindings.dart';
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

/// Initialises a new jj repository at [path].
///
/// [backend]: `0` = native/simple, `1` = Git.
///
/// Errors: `jj.path_not_found`, `jj.jj_lib_error`, `ffi.invalid_argument`.
Uint8List zanshinRepoInit(String path, int backend) {
  final ffi.Pointer<Utf8> p = path.toNativeUtf8();
  try {
    return readToken(zanshin_repo_init(p.cast(), backend));
  } finally {
    calloc.free(p);
  }
}

/// Clones a remote repository from [url] into [targetPath].
///
/// Errors: `jj.clone_failed`, `jj.jj_lib_error`.
Uint8List zanshinRepoClone(String url, String targetPath) {
  final ffi.Pointer<Utf8> urlP = url.toNativeUtf8();
  final ffi.Pointer<Utf8> targetP = targetPath.toNativeUtf8();
  try {
    return readToken(zanshin_repo_clone(urlP.cast(), targetP.cast()));
  } finally {
    calloc
      ..free(urlP)
      ..free(targetP);
  }
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
