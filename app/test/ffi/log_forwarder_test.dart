// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:zanshin/src/ffi/log_forwarder.dart';

/// Unit-tests the pure `package:logging` → FFI level mapping (the side that needs
/// no cdylib). The full forward path (`zanshin_log` → Rust `tracing`) is exercised
/// Rust-side in `crates/zanshin-ffi/src/logging.rs`.
void main() {
  group('ffiLogLevel', () {
    test('SEVERE and SHOUT map to error (1)', () {
      expect(ffiLogLevel(Level.SEVERE), 1);
      expect(ffiLogLevel(Level.SHOUT), 1);
    });

    test('WARNING maps to warn (2)', () {
      expect(ffiLogLevel(Level.WARNING), 2);
    });

    test('INFO and CONFIG map to info (3)', () {
      expect(ffiLogLevel(Level.INFO), 3);
      expect(ffiLogLevel(Level.CONFIG), 3);
    });

    test('FINE maps to debug (4)', () {
      expect(ffiLogLevel(Level.FINE), 4);
    });

    test('FINER and FINEST map to trace (5)', () {
      expect(ffiLogLevel(Level.FINER), 5);
      expect(ffiLogLevel(Level.FINEST), 5);
    });

    test('a custom level between named ones buckets by threshold', () {
      // 850 sits between INFO (800) and WARNING (900) → still "info".
      expect(ffiLogLevel(const Level('CUSTOM', 850)), 3);
    });
  });
}
