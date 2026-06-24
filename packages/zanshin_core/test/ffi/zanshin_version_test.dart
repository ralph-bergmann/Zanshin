// SPDX-License-Identifier: MIT

// Smoke tests for the `zanshin_ffi_version` + `zanshin_string_free` FFI seam
// against the REAL compiled cdylib via @ffi.Native native assets.
//
// WHY this lives here: both are `#[no_mangle] extern "C"` fns. cargo-llvm-cov does
// NOT credit a call to a no_mangle extern fn (release-cdylib vs debug-cargo hash
// split), so their ONLY coverage source in `cargo make coverage` is a
// packages/zanshin_core dart test that calls them through the cdylib. The `app/`
// native-asset smoke test also exercises the version fn, but the app package is not
// part of the coverage run. Without these tests both read as uncovered — which is
// exactly how the ratchet baseline for crates/zanshin-ffi/src/lib.rs drifted to a
// non-reproducible 100% (auto-raised on a transient cargo attribution) and went
// latently red. See memory project-coverage-extern-fn-needs-zanshin-core-test.

import 'dart:ffi' as ffi;

import 'package:ffi/ffi.dart';
import 'package:test/test.dart';
import 'package:zanshin_core/src/ffi/bindings.dart' as bindings;
import 'package:zanshin_core/src/ffi/zanshin_version.dart';

void main() {
  group('zanshin_ffi_version FFI seam (real cdylib)', () {
    test('production wrapper returns a non-empty "<version> (<sha>)" build stamp', () {
      final ZanshinFfiVersion getVersion = ZanshinFfiModule().zanshinFfiVersion();
      final String version = getVersion();

      // A String CAN be empty, so isNotEmpty is a real (non-vacuous) check.
      expect(version, isNotEmpty, reason: 'version build-stamp must be non-empty');
      // Shape mirrors the Rust contract: "<crate version> (<git sha>)".
      expect(version, contains(' ('), reason: 'version must contain " (" before the sha');
      expect(version, endsWith(')'), reason: 'version must end with ")"');
    });

    test('version pointer round-trips and is freed via zanshin_string_free', () {
      // Raw path: exercises zanshin_ffi_version AND zanshin_string_free through the
      // cdylib, freeing the heap pointer per its ownership contract (no leak).
      final ffi.Pointer<ffi.Char> ptr = bindings.zanshin_ffi_version();
      expect(ptr, isNot(equals(ffi.nullptr)), reason: 'version pointer must not be null');

      final String version = ptr.cast<Utf8>().toDartString();
      expect(version, isNotEmpty, reason: 'decoded version must be non-empty');

      // Free the heap pointer via the canonical free function (Rust owns the alloc).
      bindings.zanshin_string_free(ptr);
    });
  });
}
