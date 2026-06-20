// SPDX-License-Identifier: MIT

import 'package:ffi/ffi.dart';
import 'package:inject_annotation/inject_annotation.dart';

import 'bindings.dart' as bindings;

typedef ZanshinFfiVersion = String Function();

@module
class ZanshinFfiModule {
  /// Returns the version string from the Zanshin Rust core.
  @provides
  @singleton
  ZanshinFfiVersion zanshinFfiVersion() => bindings.zanshin_ffi_version().cast<Utf8>().toDartString;
}
