// SPDX-License-Identifier: MIT

// Release-path tests for the FlatBuffers buffer ABI against the REAL compiled
// cdylib (`docs/ffi-abi.md` § buffer ownership).
//
// The buffer ABI has two halves that reclaim the identical Rust allocation:
// the NativeFinalizer token path (`zanshin_buffer_free_token`, what `FfiBuffer`
// and therefore all production Dart code uses) and the synchronous
// `zanshin_buffer_free(ptr, len)` path. Only the first had cdylib-side
// coverage; a `#[no_mangle]` extern fn is not reliably credited to the Rust
// cargo tests that call it (see Makefile.toml § coverage, step 5), so the
// synchronous half needs a real cdylib caller to be provably exercised.

import 'dart:ffi' as ffi;

import 'package:test/test.dart';
import 'package:zanshin_core/src/ffi/bindings.dart';

void main() {
  group('FlatBuffers buffer release ABI (real cdylib)', () {
    test('zanshin_buffer_free releases a buffer through the synchronous (ptr, len) path', () {
      // zanshin_diagnostics is infallible and needs no repo handle.
      final ffi.Pointer<ZanshinBuf> token = zanshin_diagnostics();
      expect(token, isNot(equals(ffi.nullptr)));
      final ffi.Pointer<ffi.Uint8> ptr = token.ref.ptr;
      final int len = token.ref.len;
      expect(len, greaterThan(0), reason: 'the envelope buffer is non-empty');
      expect(ptr, isNot(equals(ffi.nullptr)));

      // Detach the payload from the token so exactly ONE owner frees it: the
      // synchronous call takes the buffer, and the token call then reclaims only
      // the token struct (it skips a null / zero-length payload). Without the
      // detach the two paths would double-free the same allocation.
      token.ref
        ..ptr = ffi.nullptr
        ..len = 0;
      zanshin_buffer_free(ptr, len);
      zanshin_buffer_free_token(token);
    });

    test('both release paths are no-ops on a null argument', () {
      zanshin_buffer_free(ffi.nullptr, 0);
      zanshin_buffer_free_token(ffi.nullptr);

      // A bad free would have aborted the process; the cdylib is still healthy.
      final ffi.Pointer<ZanshinBuf> token = zanshin_diagnostics();
      expect(token, isNot(equals(ffi.nullptr)));
      zanshin_buffer_free_token(token);
    });
  });
}
