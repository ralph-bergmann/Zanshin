// SPDX-License-Identifier: MIT

import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin_core/zanshin_core.dart';

/// Proves the APP aggregates and loads the `zanshin-ffi` native asset that is now
/// provided by the `zanshin_core` path dependency's build hook (the key cross-package
/// risk of the extraction). Crossing into the cdylib via the bridge's version call is
/// enough — if the asset did not load, the @Native lookup would throw.
void main() {
  test('app loads the zanshin_core native asset (cdylib) over FFI', () {
    final String value = zanshinFfiVersion();
    expect(value, isNotEmpty);
    expect(value, contains('('), reason: 'version stamp is "<version> (<sha>)"');
  });
}
