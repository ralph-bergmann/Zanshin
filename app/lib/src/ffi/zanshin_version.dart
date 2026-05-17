// SPDX-License-Identifier: Apache-2.0

import 'package:ffi/ffi.dart';

import 'bindings.dart' as bindings;

/// Returns the version string from the Zanshin Rust core.
String zanshinFfiVersion() => bindings.zanshin_ffi_version().cast<Utf8>().toDartString();
