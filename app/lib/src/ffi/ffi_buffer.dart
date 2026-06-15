// SPDX-License-Identifier: Apache-2.0

import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'bindings.dart';

/// Dart-side owner of a FlatBuffers buffer that crossed the FFI boundary.
///
/// Rust allocates the buffer and returns a `Pointer<ZanshinBuf>` token via
/// `vec_into_token`.  This class holds the token, exposes the bytes as a
/// [Uint8List] for the FlatBuffers typed-accessor layer, and ensures the buffer
/// is freed exactly once via [zanshin_buffer_free_token].
///
/// **Lifecycle:**
/// - **Create:** [FfiBuffer.fromToken] wraps a token returned by a `zanshin_*`
///   FFI call and immediately registers the [ffi.NativeFinalizer].
/// - **Read:** [bytes] → pass to the generated FlatBuffers accessors.
/// - **Free:** call [dispose] when done. The [ffi.NativeFinalizer] is the
///   belt-and-suspenders backstop (AD-2) if [dispose] is forgotten during
///   development.
///
/// **Contract:** do NOT call [dispose] more than once. After the first call the
/// token is invalid. The finalizer is cancelled automatically inside [dispose].
///
/// Implements [ffi.Finalizable] so it can be passed to [ffi.NativeFinalizer.attach];
/// this also keeps the instance reachable for the duration of any native call
/// that receives a pointer derived from it.
final class FfiBuffer implements ffi.Finalizable {
  FfiBuffer._(this._token) {
    // Attach the NativeFinalizer BEFORE any code can lose the reference
    // (e.g. if the constructor throws later). The finalizer callback
    // zanshin_buffer_free_token is a single-arg C function that frees both
    // the FlatBuffers buffer and the ZanshinBuf token struct. AD-2.
    _finalizer.attach(this, _token.cast(), detach: this);
  }

  /// Wrap a `Pointer<ZanshinBuf>` token produced by a `zanshin_*` FFI call.
  /// Takes exclusive ownership; the caller must not free the token independently.
  factory FfiBuffer.fromToken(ffi.Pointer<ZanshinBuf> token) {
    // A real runtime check, not assert(): asserts are stripped from Flutter
    // release/profile builds, where a null token would otherwise reach
    // _token.ref and segfault.
    if (token == ffi.nullptr) {
      throw ArgumentError.value(token, 'token', 'must not be null');
    }
    return FfiBuffer._(token);
  }

  final ffi.Pointer<ZanshinBuf> _token;
  var _freed = false;

  /// A view of the FlatBuffers bytes. Only valid while this [FfiBuffer] is
  /// alive and [dispose] has not been called.
  ///
  /// Throws [StateError] if accessed after [dispose] — the underlying Rust
  /// buffer is freed there, so the returned view would alias freed memory
  /// (read-after-free). The guard runs in all build modes.
  Uint8List get bytes {
    if (_freed) {
      throw StateError('FfiBuffer.bytes accessed after dispose()');
    }
    return _token.ref.ptr.asTypedList(_token.ref.len);
  }

  /// Free the underlying Rust allocation immediately.
  ///
  /// After this call [bytes] must not be accessed. Idempotent: subsequent
  /// calls are silently ignored (matching the NativeFinalizer cancel pattern).
  void dispose() {
    if (_freed) {
      return;
    }
    _freed = true;
    _finalizer.detach(this);
    zanshin_buffer_free_token(_token);
  }

  // ── NativeFinalizer ───────────────────────────────────────────────────────

  // One finalizer instance per isolate (static). The token passed to
  // attach() is the raw Pointer<Void> (cast from Pointer<ZanshinBuf>), which
  // is passed as-is to zanshin_buffer_free_token when the GC fires.
  //
  // WHY NativeFinalizer over Dart Finalizer: NativeFinalizer is guaranteed to
  // run even during isolate shutdown, preventing resource leaks at app exit.
  // The callback must be a C function pointer taking a single Pointer<Void>.
  // zanshin_buffer_free_token satisfies this (it takes Pointer<ZanshinBuf>,
  // which has the same ABI as Pointer<Void> on all supported platforms).
  static final _finalizer = ffi.NativeFinalizer(_freeTokenFnPtr.cast());

  // Function pointer for zanshin_buffer_free_token, looked up once at class
  // load time.  The @ffi.Native annotation on the function declaration in
  // bindings.dart makes its address available via the .addressOf getter.
  // We use ffi.Native.addressOf to retrieve it without instantiating a
  // DynamicLibrary.
  static final ffi.Pointer<ffi.NativeFunction<ffi.Void Function(ffi.Pointer<ZanshinBuf>)>> _freeTokenFnPtr =
      ffi.Native.addressOf(zanshin_buffer_free_token);
}
