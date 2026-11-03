---
title: 'Drag leftovers — ⌥ picks only the starting row, backwards warning announced, drop-menu entrance like the command menus, tracked over the real cdylib'
type: 'bugfix'
created: '2026-11-03'
status: 'done'
baseline_revision: 'f5a6645ea7a4f40b0cfd5d5d204f6bc053d9752b'
review_loop_iteration: 0
followup_review_recommended: false
context: []
warnings: []
deferred:
  - summary: >-
      The backwards-bookmark announcement is checked only at the Flutter accessibility channel; no VoiceOver pass on a Mac, and its chattiness is unjudged.
    evidence: |-
      Unattended run; the witness mocks SystemChannels.accessibility (graph_drag_test.dart). Mirrored in deferred-work.md "Surfaced in the drag leftovers run (bmad-build-auto, 2026-11-03)".
    location: >-
      app/lib/src/features/graph/graph_canvas.dart _announceBackwards
    severity: medium
  - summary: >-
      The drop menu fades its glass through an Opacity ancestor, so the backdrop blur turns sharp during the entrance, unlike the command menus that fade through ZsFade.
    evidence: |-
      Pre-existing (Opacity around ZsMenuMaterial already at baseline f5a6645e); the 11.3 ledger rule makes ZsFade the one way to fade glass. Mirrored in deferred-work.md "Surfaced in the follow-up review of the drag leftovers run (bmad-build-auto, 2026-11-03)".
    location: >-
      app/lib/src/features/graph/graph_drop_menu.dart:204
    severity: medium
    resolved: >-
      2026-11-03 — fixed (console session, commit 6cf017db): the entrance fades through ZsFade.
---

<intent-contract>

## Intent

**Problem:** Four console-session leftovers after the 10.10/10.26/11.21 loop (Ralph decided each on 2026-11-03): (1) ⌥ still re-defaults the change-drag drop menu's highlight live after the menu opened; (2) the backwards-bookmark warning lives only in the drag ghost, which is excluded from semantics, so VoiceOver never hears it; (3) the drop menu enters from scale .96 on `--ease-state`, not like the command menus; (4) no real-cdylib test shows `TopologyRef.tracked` (Story 11.21) reaching Dart.

**Approach:** (1) ⌥ re-defaults the highlight only while the menu is closed; the menu's opening picks the row from ⌥'s state then. (2) `GraphDrag` fires an `onBackwards` callback once per target when a bookmark drag's highlighted row is backwards; the canvas announces `dragBackwardsWarning` through `SemanticsService.sendAnnouncement` (the inspector's house pattern). (3) The drop menu's entrance uses the `ZsSurfaceMotion.menu` values: `--dur-menu`, glide curve, scale `1 - .03 * motion`. (4) A zanshin_core worker test over a git clone (main@origin tracked via `bookmarkTrack`, x@origin untracked) reads `graphTopology` and asserts `tracked`.

## Boundaries & Constraints

**Always:** ⌥ may change the default freely before the menu opens. The ghost stays under `ExcludeSemantics`. The announcement fires once per backwards target (a new target resets it), never for a forward one, never for a change drag. Run git/jj only inside test temp dirs.

**Never:** No edit under `_bmad-output/implementation-artifacts/design_system/` (the console session owns it; its uncommitted edits there are left unstaged). No full gate. No change to the drop-menu origin (above/below anchoring stays).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Menu opens without ⌥ | change drag rests on a target, ⌥ up | highlight on `rebase -s` (moveHere); pressing ⌥ keeps it | none |
| Menu opens with ⌥ | ⌥ held when the menu opens | highlight on `rebase -r` (moveOnly); releasing ⌥ keeps it | none |
| ⌥ before the menu | ⌥ toggled while closed | default follows ⌥ live (existing test) | none |
| Backwards bookmark target | bookmark drag over a target whose row is backwards | one announcement of `dragBackwardsWarning`; staying on it adds none; moving to another backwards target announces again | none |
| Forward bookmark target | row not backwards | no announcement | none |
| tracked over FFI | git clone, `main@origin` tracked, `x@origin` untracked | remote refs: main tracked true, x tracked false; local main tracked false | none |

</intent-contract>

## Code Map

- `app/lib/src/features/graph/graph_drag.dart` -- `GraphDrag._onKey` (~:697-704, `alt != _alt` re-defaults `_highlight` unless `_arrowed`); `_armMenu` (~:551-561) sets `_highlight = _arrowed ? _highlight : defaultIndex` at open; `_setTarget` (~:519-538) and `_fetch` (~:600-606) are where a target's preview (and so its highlighted row) becomes known; class doc ~:345-346 describes ⌥.
- `app/lib/src/features/graph/graph_canvas.dart` -- `_attachDrag` / `_detachDrag` (~:457-468) wire the canvas into `GraphDrag` (pattern for `onBackwards`).
- `app/lib/src/features/graph/graph_inspector.dart:1221-1222` -- house announcement: `SemanticsService.sendAnnouncement(View.of(context), message, Directionality.of(context))`.
- `app/lib/src/features/graph/graph_view.dart:~496-502` -- the ghost's warning condition (`command != null && drag.highlightedRow?.backwards`).
- `app/lib/src/features/graph/graph_drop_menu.dart:~199-212` -- entrance: `motion.easeState`, `scale: 1 - .04 * motion.motion * (1 - t)`; duration already `motion.durMenu` (:101).
- `packages/zanshin_ui/lib/src/materials/zs_surface_transition.dart:14,22-23,51` -- `menu` = `--dur-menu`, glide, scale `1 - .03 * m`; doc says the DS gives the drop menu its own keyframe (now stale).
- `app/test/features/graph/graph_drag_test.dart` -- `GraphDrag` group (:303-543, ⌥ test :525), bookmark-ghost widget tests (:980-1030); `graph_inspector_test.dart:580-598` captures announcements via `SystemChannels.accessibility`.
- `packages/zanshin_core/test/worker/remote_changes_test.dart:46-90` -- recipe: git source → bare → clone, `worker.initRepo(root, backend: 1, colocate: true)` gives `main@origin`, `x@origin`.
- `packages/zanshin_core/lib/src/worker/handle.dart:191` `graphTopology`, `:2661` `bookmarkTrack`; `packages/zanshin_core/lib/src/ffi/graph.dart:137-170` `TopologyRef` (`tracked`).

## Tasks & Acceptance

**Execution:**
- `app/lib/src/features/graph/graph_drag.dart` -- `_onKey`: re-default only when `!_arrowed && !_menu`; update class doc; add `void Function()? onBackwards` plus a per-target flag, fired after a bookmark target's preview is set (cached in `_setTarget`, fetched in `_fetch`) when `highlightedRow?.backwards`; reset on target change -- items 1, 2.
- `app/lib/src/features/graph/graph_canvas.dart` -- set/clear `onBackwards` in `_attachDrag`/`_detachDrag`; announce `context.l10n.dragBackwardsWarning` via `SemanticsService.sendAnnouncement` -- item 2.
- `app/lib/src/features/graph/graph_drop_menu.dart` -- entrance curve `motion.easeGlide`, scale `1 - .03 * motion.motion * (1 - t)` -- item 3.
- `packages/zanshin_ui/lib/src/materials/zs_surface_transition.dart` -- drop the stale "DS gives it a keyframe of its own" sentence -- item 3.
- `app/test/features/graph/graph_drag_test.dart` -- ⌥ after the menu opened keeps the highlight (both directions); announcement once per backwards target, none for forward (widget test in the graph) -- items 1, 2.
- `packages/zanshin_core/test/worker/graph_tracked_test.dart` -- new real-cdylib test -- item 4.
- `_bmad-output/implementation-artifacts/deferred-work.md` -- strike the two ledger bullets (items 2, 3) -- ledger.

**Acceptance Criteria:**
- Given a change drag whose menu opened without ⌥, when ⌥ is pressed, then `highlightedRow.kind` stays `moveHere`; given it opened with ⌥, when ⌥ is released, then it stays `moveOnly`.
- Given a bookmark drag in the graph, when it rests on a backwards target, then exactly one `announce` message equal to `dragBackwardsWarning` reaches `SystemChannels.accessibility`; for a forward target none.
- Given the real cdylib and a colocated repo with one tracked and one untracked remote bookmark, when `graphTopology(revset: 'all()')` is read, then the tracked remote ref reads `tracked: true` and the untracked one `tracked: false`.

## Spec Change Log

## Review Triage Log

### 2026-11-03 — Review pass
- verdicts: 22 findings — high 0, medium 5, low 8, false 8, maybe-false 1
- findings:
  - `[low]` `[reject]` Blind: drop menu copies the menu entrance values instead of using `ZsSurfaceMotion.menu` — `_Pose`/`_from` are private and `ZsSurfaceTransition` anchors top-left while the drop menu anchors top/bottom centre; reuse needs new public surface in zanshin_ui; the equal literal is what item 3 allows ("otherwise .03").
  - `[false]` `[reject]` Blind: exit not aligned — `GraphDropMenu` has no exit animation at all (no reverse/closing in `graph_drop_menu.dart`); item 3 asks for the entrance only.
  - `[medium]` `[patch]` Blind: item 3 has no test — added an entrance test pinning glide + .97 (grouped with the verification-gap entrance finding).
  - `[low]` `[reject]` Blind: struck ledger bullets keep their old Follow-up sub-bullets — the ledger convention keeps history under a struck title; the RESOLVED line states the outcome.
  - `[medium]` `[defer]` Blind: no VoiceOver device pass of the new announcement — deferred (frontmatter + deferred-work "drag leftovers" section).
  - `[false]` `[reject]` Blind: "staying adds none" untested while moving inside the target — `hover` calls `_setTarget` only when `key != _target`, so moves inside one card never reach `_warnBackwards`.
  - `[low]` `[reject]` Blind: change drag never announces is untested — the guard is one `is GraphBookmarkDrag` check; every change-drag test runs with the canvas wired and none announces would need a channel mock in each; not worth it.
  - `[false]` `[reject]` Blind: ⌥ test never releases to show the kept row runs — `drop()` runs `rows[_highlight]`, the same index `highlightedRow` reads; existing release tests cover that path.
  - `[low]` `[reject]` Blind: a failing ⌥ test leaves ⌥ held — only affects the failure message of an already failing test.
  - `[false]` `[reject]` Blind: tracked test reads the host git config — Makefile.toml test-core pins `GIT_CONFIG_GLOBAL=""` for the suite, the same as `remote_changes_test`.
  - `[medium]` `[patch]` Blind: tracked test does not check its precondition — added a read before `bookmarkTrack` asserting `main@origin` untracked.
  - `[medium]` `[patch]` VerifGap: the cached-target announcement is never asserted — added the third-announcement assertion after the return to `c` (grouped with the Blind "third announcement" note).
  - `[medium]` `[patch]` VerifGap: drop-menu entrance not pinned — same entry as the Blind item-3 test.
  - `[low]` `[reject]` VerifGap: clearing `onBackwards` on detach untested — mirrors the untested `toViewport` detach; the drag lives in the view model owned by the same view, a swap is not reachable in everyday use.
  - `[low]` `[reject]` EdgeCase: leaving a backwards target for a gap and re-entering re-announces — the intent resets on a new target; a gap is no target, so re-entering is a new arrival (reading 2a); a guard adds state for a rare path.
  - `[false]` `[reject]` EdgeCase: no per-target flag, a future second preview write would re-announce — speculative; today the preview is set exactly once per target (cache hit or fetch answer).
  - `[low]` `[reject]` Intent: item 1 is tested on the controller, not the rendered menu — the menu renders from `GraphDrag.highlight`; same value.
  - `[low]` `[reject]` Intent: item 2 is verified at the accessibility channel, not VoiceOver — a device pass is deferred above.
  - `[maybe-false]` `[reject]` Intent: returning to a visited target announces again (2a vs 2b) — the intent says "on a new target … not again while it stays on that target"; 2a is the reading of that text; would only be low.
  - `[false]` `[reject]` Intent: item 3 duplicates the literal — see the first row; the intent allows .03 when no shared expression is reachable.
  - `[false]` `[reject]` Intent: `CommitRef.tracked` untested over the cdylib — `CommitRef` is the Rust struct; Dart reads it only as `TopologyRef`, which the test reads.
  - `[false]` `[reject]` Intent: ledger strikes lack `commit <hash>` — added at commit time (the strike names the fix commit, committed with the spec).

### 2026-11-03 — Review pass (follow-up)
- verdicts: 18 findings — high 0, medium 1, low 4, false 3, maybe-false 0 (10 carried)
- findings:
  - `[low]` `[reject]` Blind: drop menu hand-rolls the entrance instead of `ZsSurfaceTransition` — carried: private pose, top-left origin; the equal literal is what item 3 allows.
  - `[medium]` `[defer]` Blind: entrance fades glass through an `Opacity` ancestor (`graph_drop_menu.dart:204`) — pre-existing (present at baseline f5a6645e), not caused by this change; deferred (frontmatter + deferred-work follow-up-review section).
  - `[low]` `[reject]` Blind: entrance test checks scale only (no opacity, reduced motion, pinned `ZsMotion.full`) — item 3 changed curve and scale, both pinned; extra assertions guard code this run did not touch.
  - `[low]` `[patch]` Blind: `onBackwards` / `_warnBackwards` docs say "once per target" while a revisit re-announces — docs now say "each time the pointer settles on a target" / "once per arrival on a target".
  - `[low]` `[reject]` Blind: struck ledger entries keep their old Follow-up sub-bullets — carried: ledger keeps history under a struck title.
  - `[low]` `[patch]` Blind: open ledger entry still says "~110-character warning" — the arb text is 80 characters since 12a379b8; figure corrected in deferred-work.md.
  - `[false]` `[reject]` Blind: `_announceBackwards` uses `context` without a `mounted` guard after a fetch — `dispose` calls `_detachDrag`, which nulls `onBackwards` before the element is gone, so a late fetch finds no callback.
  - `[low]` `[reject]` Blind: a failing ⌥ test leaves ⌥ held — carried: affects only an already failing test's messages.
  - `[false]` `[reject]` Blind: `_alt` still flips while the menu is open, so UI reading `alt` can disagree with the row — nothing in `app/lib` reads `drag.alt`; `defaultIndex` is read only when the menu opens or the target changes.
  - `[false]` `[reject]` Blind: tracked test uses the host git config — carried: test-core pins `GIT_CONFIG_GLOBAL=""`.
  - `[low]` `[reject]` Blind: tracked test does not assert `x@origin` exists before tracking; `setUpIconRegistry` at group level uncommented — the `containsPair` on `x@origin` fails loudly if it is missing; the registry setup is harmless for controller tests.
  - `[low]` `[patch]` Blind: `_announceBackwards` doc reads badly — reworded to "reaches VoiceOver only as an announcement".
  - `[false]` `[reject]` EdgeCase: no per-target flag; a second preview write would re-announce — carried: speculative, the preview is set once per arrival.
  - `[low]` `[reject]` VerifGap: clearing `onBackwards` on detach is untested — carried: mirrors the untested `toViewport` detach; not reachable in everyday use.
  - `[low]` `[reject]` Intent: item 1 tested on the controller, not the rendered menu — carried.
  - `[low]` `[reject]` Intent: item 2 verified at the accessibility channel, not VoiceOver — carried; device pass deferred.
  - `[low]` `[reject]` Intent: "never for a change drag" untested — carried: one type check.
  - `[false]` `[reject]` Intent: item 3 duplicates values instead of the component — carried.

## Verification

**Commands:**
- `flutter test test/features/graph/graph_drag_test.dart` (in `app/`) -- expected: pass
- `flutter test` + `dart analyze` + `dart format --set-exit-if-changed .` in `app/` and `packages/zanshin_ui/` -- expected: clean
- `dart test test/worker/graph_tracked_test.dart` (in `packages/zanshin_core/`, env as `Makefile.toml` `test-core` pins it) + `dart analyze` + `dart format --set-exit-if-changed .` -- expected: pass/clean

**Verification notes (run 2026-11-03, no full gate per the run's gate rule):**
- `flutter test test/features/graph` (app/) — 917 passed.
- `dart analyze` (app/) — no issues; `dart format --set-exit-if-changed lib test` — 0 changed.
- `flutter test` (packages/zanshin_ui/) — 450 passed; `dart analyze` no issues; `dart format` 0 changed.
- `dart test test/worker/graph_tracked_test.dart` (packages/zanshin_core/, test-core env) — passed; `dart analyze --fatal-infos --fatal-warnings` no issues; `dart format` 0 changed.
- Full `flutter test` in app/ outside the Makefile env fails 6 tests in `worker_project_repos_test.dart`; with the test-core env that file passes 34/34 — environment, not this change.
- No Rust touched: no cargo checks, no codegen, no parity oracle. Not checked in the running app (no Marionette, no VoiceOver).

## Auto Run Result

Status: done. Fix commit `ebc3f36995e60b08fdce5760dc3a0b12eafd4e8c`; spec + ledger in the following commit.

1. **⌥ picks only the starting row — fixed** (ebc3f36995e60b08fdce5760dc3a0b12eafd4e8c). `GraphDrag._onKey` re-defaults only while the menu is closed; the menu's opening takes the row from ⌥'s state then. Tests: menu opened without ⌥ keeps -s on ⌥ down; opened with ⌥ keeps -r on ⌥ up.
2. **VoiceOver hears the backwards warning — fixed** (ebc3f36995e60b08fdce5760dc3a0b12eafd4e8c). `GraphDrag.onBackwards` fires when a bookmark target's preview (cached or fetched) has a backwards row; the canvas announces `dragBackwardsWarning` via `SemanticsService.sendAnnouncement` (the inspector's pattern). Ghost stays excluded from semantics. Test: once per backwards target (incl. a revisited one), none while staying, none for forward. Ledger bullet struck.
3. **Drop-menu entrance like the command menus — fixed** (ebc3f36995e60b08fdce5760dc3a0b12eafd4e8c). `--dur-menu` (as before), glide curve, scale `1 - .03 * motion` (the `ZsSurfaceMotion.menu` values; the private pose is not reusable and its top-left origin does not fit). Stale DS-keyframe sentence removed from `zs_surface_transition.dart`. Entrance test added. Ledger bullet struck; design_system/ untouched.
4. **`tracked` over the real cdylib — fixed** (ebc3f36995e60b08fdce5760dc3a0b12eafd4e8c). New `packages/zanshin_core/test/worker/graph_tracked_test.dart`: git source → bare → clone with local main one ahead, colocated `initRepo`; `main@origin` reads untracked, then after `bookmarkTrack(['main@origin'])` tracked: true, `x@origin` false, local `main` false. (Local main sits ahead because a remote entry on the local bookmark's commit is folded into it.)

**Files:** `graph_drag.dart` (⌥ rule, `onBackwards`), `graph_canvas.dart` (announcement wiring), `graph_drop_menu.dart` (entrance), `zs_surface_transition.dart` (doc), `graph_drag_test.dart` (tests), `graph_tracked_test.dart` (new), `deferred-work.md` (2 strikes, 1 new section).

**Review:** 22 findings — 3 patch entries (5 medium rows: cached-target assertion, entrance test, tracked precondition), 1 deferred (no VoiceOver device pass, medium), the rest rejected with reasons in the triage log. Patched entries by verdict: high 0, medium 3. Follow-up review recommended: true (≥2 medium patched) — the named unverified risk: the three patches were test additions written after review, and the announcement path is witnessed only through a mocked accessibility channel, never in the running app.

**Residual risks:** not checked in the running app or with VoiceOver; the announcement repeats when the pointer returns to a target after leaving it.

### Follow-up review pass (2026-11-03)

- **Change:** doc-comment wording only — `GraphDrag.onBackwards` and `_warnBackwards` now say the callback fires per arrival on a target (`app/lib/src/features/graph/graph_drag.dart`); `_announceBackwards` doc reworded (`app/lib/src/features/graph/graph_canvas.dart`); the open bookmark-drop ledger entry's stale "~110-character" figure corrected to ~80 (`deferred-work.md`).
- **Findings:** 18 (10 carried) — 3 low patched (docs, ledger figure), 1 medium deferred (pre-existing `Opacity` over the drop menu's glass; mirrored in deferred-work.md), the rest rejected with reasons in the triage log.
- **Follow-up review recommended:** false — follow-up pass, no high patched (patched: high 0, medium 0, low 3).
- **Verification (no full gate per the run's gate rule):** `dart format --set-exit-if-changed` on the two touched files — 0 changed; `dart analyze lib/src/features/graph` (app/) — no issues; `flutter test test/features/graph/graph_drag_test.dart` — 39 passed. No Rust, schema or zanshin_core code touched.
- **Residual risks:** unchanged from above; the drop menu's glass still sharpens during its entrance until the deferred `ZsFade` fix lands.
