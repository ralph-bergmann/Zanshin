// SPDX-License-Identifier: MIT

// Calling-side contract tests for Story 9.16's three adapters (rebase,
// parallelize, arrange): the interior-NUL guards, which fire BEFORE any FFI
// call, so a raw handle of 0 never reaches the cdylib, and the sealed
// `ArrangeAction` model. All three answer the shared `MutationResult`, whose
// decoder test/ffi/mutate_test.dart owns; the round trips through the real
// cdylib live in test/worker/rebase_test.dart.
//
// Mirrors packages/zanshin_core/test/ffi/squash_split_test.dart.

import 'package:test/test.dart';
import 'package:zanshin_core/src/ffi/rebase.dart';

void main() {
  group('interior-NUL guards fire before the FFI call', () {
    const nul = 'a\u0000b';

    test('zanshinRebase refuses a NUL in every id list', () {
      expect(() => zanshinRebase(0, branch: const [nul]), throwsArgumentError);
      expect(() => zanshinRebase(0, source: const [nul]), throwsArgumentError);
      expect(() => zanshinRebase(0, revisions: const [nul]), throwsArgumentError);
      expect(() => zanshinRebase(0, onto: const [nul]), throwsArgumentError);
      expect(() => zanshinRebase(0, insertAfter: const [nul]), throwsArgumentError);
      expect(() => zanshinRebase(0, insertBefore: const [nul]), throwsArgumentError);
    });

    test('zanshinParallelize refuses a NUL in a change id', () {
      expect(() => zanshinParallelize(0, const [nul]), throwsArgumentError);
    });

    test('zanshinArrange refuses a NUL in a revision or an action', () {
      expect(() => zanshinArrange(0, revisions: const [nul]), throwsArgumentError);
      expect(() => zanshinArrange(0, actions: const [AbandonAction(nul)]), throwsArgumentError);
    });
  });

  test('every ArrangeAction carries its change id', () {
    const List<ArrangeAction> actions = [SwapDownAction('d'), SwapUpAction('u'), AbandonAction('a'), KeepAction('k')];
    expect(actions.map((a) => a.changeId), ['d', 'u', 'a', 'k']);
    expect(
      actions.map(
        (a) => switch (a) {
          SwapDownAction() => 'J',
          SwapUpAction() => 'K',
          AbandonAction() => 'a',
          KeepAction() => 'p',
        },
      ),
      ['J', 'K', 'a', 'p'],
    );
  });
}
