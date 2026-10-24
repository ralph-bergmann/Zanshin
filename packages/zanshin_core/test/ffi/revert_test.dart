// SPDX-License-Identifier: MIT

// Calling-side contract test for Story 9.18's `revert` adapter: the
// interior-NUL guard fires BEFORE any FFI call, so a raw handle of 0 never
// reaches the cdylib. `revert` answers the shared `MutationResult`, whose
// decoder test/ffi/mutate_test.dart owns; the round trips through the real
// cdylib live in test/worker/revert_test.dart.
//
// Mirrors packages/zanshin_core/test/ffi/metaedit_duplicate_fix_test.dart.

import 'package:test/test.dart';
import 'package:zanshin_core/src/ffi/revert.dart';

void main() {
  const nul = 'a\u0000b';

  test('zanshinRevert refuses a NUL in every id list', () {
    expect(() => zanshinRevert(0, revisions: const [nul]), throwsArgumentError);
    expect(() => zanshinRevert(0, onto: const [nul]), throwsArgumentError);
    expect(() => zanshinRevert(0, insertAfter: const [nul]), throwsArgumentError);
    expect(() => zanshinRevert(0, insertBefore: const [nul]), throwsArgumentError);
  });
}
