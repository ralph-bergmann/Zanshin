// SPDX-License-Identifier: MIT

import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'bindings.dart' as bindings;

/// The version string from the Zanshin Rust core, `"<version> (<git sha>)"`. The string Rust allocated is freed with
/// `zanshin_string_free` once it is decoded.
String zanshinFfiVersion() {
  final Pointer<Char> version = bindings.zanshin_ffi_version();
  try {
    return version.cast<Utf8>().toDartString();
  } finally {
    bindings.zanshin_string_free(version);
  }
}
