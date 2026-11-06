---
title: 'Story 10.31 closing: pin the home page handing the minimap card width to the shell'
type: 'chore'
created: '2026-11-06'
status: 'done'
baseline_revision: '59801732e0acb74f702354787db1278f7f34e5ef'
review_loop_iteration: 0
followup_review_recommended: false
context: []
warnings: []
deferred: []
---

<intent-contract>

## Intent

**Problem:** Story 10.31's run deferred item 1: `HomePage` passes `minimapWidth: graph.model?.minimapSource.cardWidth` to `FloatingShell` (`app/lib/src/features/home/home_page.dart:116`), but no test pins it — the shell and minimap tests wire their own notifier, so dropping the argument would freeze the card at 134 px unnoticed.

**Approach:** Add one `home_page_test` case: with a project open, the shell's `minimapWidth` is the very listenable the open graph's `minimapSource.cardWidth` exposes (identity). The shell following that listenable's value is already pinned in `floating_shell_test.dart` ("rig.minimapWidth.value = 234").

## Boundaries & Constraints

**Always:** test-only change in `app/test/features/home/home_page_test.dart`; reuse `pumpHome` and the existing open-project pattern (`session.open('/r/zanshin')`, `appMenu.graph.value!.model`).

**Never:** no production code change; no new fake graph data or repo fixture — the fake repos have no worker handle, so a real multi-column graph through the home page would need FFI fixtures (out of proportion for a wiring pin; the value-following half is already tested in the shell test).

</intent-contract>

## Code Map

- `app/lib/src/features/home/home_page.dart:116` -- the wiring under test (`minimapWidth: graph.model?.minimapSource.cardWidth`).
- `app/lib/src/features/graph/graph_minimap.dart:154` -- `GraphMinimapSource.cardWidth`, a `ValueListenable<double>` owned by `GraphViewModel.minimapSource` (`graph_view_model.dart:386`).
- `app/lib/src/features/shell/floating_shell.dart:124,307,323` -- `FloatingShell.minimapWidth` listened to and used as the card width.
- `app/test/features/home/home_page_test.dart:293-324` -- sibling test reading `tester.widget<FloatingShell>` and `appMenu.graph.value!.model` after opening `/r/zanshin`; mirror it.
- `app/test/features/shell/floating_shell_test.dart:577-606` -- already pins the shell's card following the listenable's value (134 → 234).

## Tasks & Acceptance

**Execution:**
- `app/test/features/home/home_page_test.dart` -- add a testWidgets case: pump home, open `/r/zanshin`, pump; expect `tester.widget<FloatingShell>(find.byType(FloatingShell)).minimapWidth` to be `same(appMenu.graph.value!.model!.minimapSource.cardWidth)` -- pins the hand-over.

**Acceptance Criteria:**
- Given a project open on the home page, when the shell is built, then its `minimapWidth` is identical to the open graph model's `minimapSource.cardWidth` (removing the argument at `home_page.dart:116` makes the test fail).

## Spec Change Log

## Review Triage Log

### 2026-11-06 — Review pass
- verdicts: 8 findings — high 0, medium 0, low 8, false 0, maybe-false 0 (verification-gap layer reported no gaps)
- findings:
  - `[low]` `[patch]` (edge-case) a project switch is unpinned; a stale listenable from the disposed model would go unnoticed — added a second open (`/r/jj`) asserting `same` the new model's `cardWidth` and `isNot(same)` the first.
  - `[low]` `[patch]` (edge-case) the no-project branch (`graph.model?.` null) is unpinned — added `expect(minimapWidth, isNull)` before the open.
  - `[low]` `[patch]` (blind) no-project state unchecked — same root cause and fix as the row above.
  - `[low]` `[patch]` (blind) model swap uncovered — same root cause and fix as the switch row above.
  - `[low]` `[patch]` (blind) the test does not show a minimap is shown, so the width could be inert (`floating_shell.dart:323` ignores it while `minimap` is null) — added `expect(minimap, isNotNull)`; it holds in the rig (Show Minimap defaults on).
  - `[low]` `[reject]` (blind) spec Execution line says `model!` but `GraphMenuBinding.model` is non-nullable — the fix is a spec edit; the code is correct.
  - `[low]` `[reject]` (blind) test name long — cosmetic; it names the exact wiring it pins, siblings vary in style.
  - `[low]` `[reject]` (intent-alignment) the diff pins the hand-over by identity, not a multi-column value through the home page as the ledger's wording suggests — the fake repos have no worker handle, so a real multi-column graph needs FFI fixtures; the value half (listenable → insets → card width 134→234) is pinned in `floating_shell_test.dart:577-606`; together they cover the chain, and the named regression (argument dropped) now fails (mutation-checked).

## Verification

**Commands:**
- `flutter test test/features/home/home_page_test.dart` (in `app/`) -- expected: all pass.
- `dart analyze` and `dart format --set-exit-if-changed .` on the touched file -- expected: clean.

## Auto Run Result

Status: done

**Items:**
1. fixed (59d281f50cb1a99c53834312775c325dd07cdbd9) — real: no test pinned `home_page.dart:116`. A `home_page_test` case now pins the hand-over: no project → `minimapWidth` null; project open → minimap shown and `minimapWidth` identical to the open graph's `minimapSource.cardWidth`; switching project → the new model's listenable, not the disposed one. Deviation from the ledger wording: identity instead of a multi-column value, because the fake repos have no worker handle (a real multi-column graph through the home page needs FFI fixtures); the value-following half is already pinned in `floating_shell_test.dart:577-606`.

**Files changed:**
- `app/test/features/home/home_page_test.dart` — the new test case and a `ValueListenable` import.

**Review:** 5 low findings patched (no-project state, project switch, minimap shown — duplicates across two layers), 3 low rejected (spec-wording `model!`, test-name style, intent-alignment value-vs-identity divergence; reasons in the triage log). Nothing deferred, so nothing mirrored into deferred-work.md. Follow-up review: false (patched: 0 high, 0 medium, 5 low).

**Verification (targeted, per the run's gate rule; no `cargo make test`):**
- `flutter test test/features/home/home_page_test.dart` — 27 passed (before and after the review patches).
- Mutation check: with `minimapWidth:` removed from `home_page.dart:116` the new test failed; the line was restored verbatim.
- `dart analyze --fatal-infos test/features/home/home_page_test.dart` — no issues.
- `dart format --set-exit-if-changed test/features/home/home_page_test.dart` — 0 changed.

**Residual risk:** none beyond the identity-vs-value choice above.
