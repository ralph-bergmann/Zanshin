// SPDX-License-Identifier: MIT

import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'bindings.dart';
import 'ffi_buffer.dart';

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
    final ffi.Pointer<ZanshinBuf> token = zanshin_repo_open(p.cast());
    final buf = FfiBuffer.fromToken(token);
    try {
      return Uint8List.fromList(buf.bytes);
    } finally {
      buf.dispose();
    }
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
    final ffi.Pointer<ZanshinBuf> token = zanshin_repo_init(p.cast(), backend);
    final buf = FfiBuffer.fromToken(token);
    try {
      return Uint8List.fromList(buf.bytes);
    } finally {
      buf.dispose();
    }
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
    final ffi.Pointer<ZanshinBuf> token = zanshin_repo_clone(urlP.cast(), targetP.cast());
    final buf = FfiBuffer.fromToken(token);
    try {
      return Uint8List.fromList(buf.bytes);
    } finally {
      buf.dispose();
    }
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
Uint8List zanshinRepoClose(int rawHandle) {
  final ffi.Pointer<ZanshinBuf> token = zanshin_repo_close(rawHandle);
  final buf = FfiBuffer.fromToken(token);
  try {
    return Uint8List.fromList(buf.bytes);
  } finally {
    buf.dispose();
  }
}
