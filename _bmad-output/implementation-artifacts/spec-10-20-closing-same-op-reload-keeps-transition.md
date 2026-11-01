---
title: 'Story 10.20 closing run — a same-op reload keeps the running transition; an early end still reveals the born card'
type: 'bugfix'
created: '2026-11-01'
status: 'done'
baseline_revision: '4f0e203330570121741544cd1124d822734ab663'
review_loop_iteration: 0
followup_review_recommended: true
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-10-context.md'
warnings: []
deferred: []
---

<intent-contract>

## Intent

**Problem:** Story 10.20's run deferred one item (its spec's `deferred:`, third entry), verified against the current code: (1) every land sets `_transition = null` (`graph_view_model.dart:1010`) and builds one only for a new op id, so a same-op layout — the watcher's `OpHeadsChangedEvent` reload after Zanshin's own verb (`:890-894`) — lands without one; the canvas's "a layout without a transition ends the running one" branch (`graph_canvas.dart:334-341`) then stops the ticker (glide and edge fade snap to their end) and drops `_bornReveal`, while the model already took the born key out of `reveal` (`:1067-1070`), so a covered born card is never revealed. Real whatever the event's timing.

**Approach:** The model carries the last transition onto a same-op layout no switch asked for (`GraphTransition.continued`, sharing the landing's identity); the canvas keeps a running transition going on a continuation (no restart, no second flash; born edges recomputed for the new layout); the viewport carries each running effect to the new layout by key, keeping its origin and retargeting to the new rect. An early end by a layout without a transition reveals a pending covered born card after that frame, unless the layout brings a reveal of its own.

## Boundaries & Constraints

**Always:** a continuation never starts a transition (one that finished stays finished); a revset/mode/lane-order switch (`_recentre`) still lands no transition; the explicit reveal of a born key is suppressed only for a fresh transition; witnesses are widget/unit tests with a fake source; gate rule of this run: targeted checks only (`flutter test`, `dart analyze --fatal-infos`, `dart format --set-exit-if-changed` in `app/`), no `cargo make test` / `test-full` / `coverage`.

**Never:** a change to Story 10.20's spec, `epics.md`, `sprint-status.yaml`, `design/`, `design_system/`, Rust, FFI or schemas; re-mirroring the item into deferred-work.md; running the app (the timing log is Ralph's manual check).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Watcher reload after own verb | `jj new` lands op1; an `OpHeadsChangedEvent` reload lands op1 again | `model.transition` is a continuation of the first (same anchor/born/flash), `reveal` stays null | — |
| Same-op layout mid-glide | viewport at 200 ms; continuation onto an equal layout | cards keep their painted rects; glide ends at 460 ms | — |
| Same-op layout mid-transition (canvas) | canvas at 300 ms gets a continuation | ticker keeps running, edge layer still fading, born card revealed after the glide | — |
| Continuation after the end | transition completed; a continuation lands | nothing animates | — |
| Early end | canvas mid-run gets a layout without transition, no new reveal | covered born card revealed | — |
| Switch mid-transition | revset switch lands same op | no transition (`_recentre`) | — |

</intent-contract>

## Code Map

- `app/lib/src/features/graph/graph_viewport_render.dart:66-110` -- `GraphTransition`: add `.continued(running, to)`, private landing token `_run`, `isContinued`, `continues(other)`. `_syncTransition` (~:600): on `t.continues(_applied)` with `_last.layout == _applied.to`, remap `_effects` by key, `delta + was(old) − now(node)`; a carried glide not laid out goes to `_glideOut`.
- `app/lib/src/features/graph/graph_canvas.dart:331-341` -- `didUpdateWidget`: start only when `!transition.isContinued` (review: `_started` dropped); continue when `continues(_moving)`; end branch reveals the pending born key post-frame when `widget.reveal` is null or unchanged and no transition started since. Born-edge set into `_bornEdgesOf`; `_revealBorn` compares by `continues`.
- `app/lib/src/features/graph/graph_view_model.dart:1005-1070` -- `_land`: continuation when `last != null && op == was && !_recentre`; born suppression only for a fresh transition. Class doc (Story 10.20 bullet).
- Tests: `app/test/features/graph/graph_transition_test.dart` (viewport `land`/`at` helpers, canvas `bornOperation`; the existing "layout without a transition mid-run ... no reveal" test flips to "revealed"), `graph_view_model_test.dart` ("Story 10.20: the transition" group; same-op reload / stack toggle expectations become continuations; `heads(async)` fires an `OpHeadsChangedEvent`).

## Tasks & Acceptance

**Execution:**
- [x] `app/lib/src/features/graph/graph_viewport_render.dart` -- continuation constructor + effect carry -- item 1 (drafted in the working tree during planning; check it).
- [x] `app/lib/src/features/graph/graph_canvas.dart` -- continue/start/end branches, early-end born reveal -- item 1 (drafted, check it).
- [x] `app/lib/src/features/graph/graph_view_model.dart` -- continuation in `_land` -- item 1 (drafted, check it).
- [x] tests for every matrix row (see Code Map).

**Acceptance Criteria:**
- Given the one item, when this run ends, then `## Auto Run Result` lists it by number with fixed (commit) / rejected (reason) / deferred.
- Given the finished tree, when `git status` is read, then only the Code Map files and this run's spec changed.

## Spec Change Log

## Review Triage Log

### 2026-11-01 — Review pass
- verdicts: 32 findings — high 0, medium 2, low 20, false 10, maybe-false 0
- findings:
  - `medium` `patch` [blind] The early-end guard `identical(oldWidget.reveal, widget.reveal)` drops the born reveal when the reveal goes non-null → null. — Real: the model rebuilds `_reveal` per land; guard is now `widget.reveal == null || identical(...)`, witnessed both ways.
  - `low` `patch` [blind] The early end's post-frame reveal has no staleness guard. — A transition started before that frame would be scrolled away; the callback now also needs `_moving == null` (one condition, same patch as above).
  - `low` `reject` [blind] A born key can be revealed twice on a continuation (layout reveal plus after-glide reveal). — Needs an explicit reveal of the new change within the 720 ms; the second scroll lands on the same card; suppressing needs the model to know the canvas is running.
  - `low` `reject` [blind] The carry only retargets cards that already had an effect; at-rest cards that moved and new cards in the continuation snap. — Only a same-op layout that moves cards (a stack toggle mid-glide) meets it, which snapped everything before; the watcher's reload is an equal layout.
  - `low` `reject` [blind] A carried arrival on a moved card snaps; folded places overwrite each other. — Same group as the row above: needs a same-op layout that moves or folds cards mid-run.
  - `low` `reject` [blind] The model never retires a transition, keeping `from` alive. — At most one extra layout (a continuation shares `from`, the token stops chains); the replay risk it carries is patched in the canvas (row "fresh canvas state" below).
  - `low` `reject` [blind] The model condition also continues stack toggles and expands. — Covered by the Design Notes (a stack toggle mid-glide); continuing a running glide never starts an animation, so 10.20's "a stack toggle never animates" holds.
  - `low` `patch` [blind] Missing witnesses: switch mid-transition with its own reveal, early end with a reveal. — Two canvas tests added (a new reveal wins; reveal → null still reveals the born card); the model-level switch row is pinned in the view-model test.
  - `low` `reject` [blind] No viewport test for a continuation onto a layout that moves cards. — Behaviour accepted in Design Notes; not the reported defect.
  - `low` `reject` [blind] No test that a continuation does not re-run the flash. — The continue branch never touches `_flash`; a test would pin a missing call.
  - `low` `reject` [blind] No test for the double-reveal case. — Rejected above.
  - `low` `reject` [blind] The changed early-end test restores the scroll by hand before comparing strokes. — Intentional: strokes are compared at the scroll they were taken at; the reveal target is checked separately.
  - `false` `reject` [blind] The spec is incomplete for a finished run. — Status, results and Auto Run Result are written at finalization.
  - `false` `reject` [blind] Nothing closes Story 10.20's deferred entry in the ledger. — The loop closes ledgers in its own commit (`8cc81ae1` pattern); this run is told not to touch that entry.
  - `low` `reject` [blind] Code Map line numbers point at the old code. — Fix is editing this build's spec.
  - `medium` `patch` [edge-case] A fresh canvas State (`_started` null) given a continuation starts it, replaying flash and born reveal. — Real after a remount at the same op (the model keeps its continuation); the start branch now requires `!transition.isContinued`, witnessed by a fresh-canvas test.
  - `false` `reject` [edge-case] Early-end guard: same finding as the blind row. — Duplicate of the patched medium row (kept as its own row: patched with it).
  - `low` `reject` [edge-case] The model keeps old `from` and a remounted canvas can replay. — Memory part as the blind row; replay patched in the canvas.
  - `low` `reject` [edge-case] Continuation with an explicit reveal equal to the born key reveals twice. — As the blind double-reveal row.
  - `low` `reject` [edge-case] A continuation onto a moved layout or after a user scroll jumps by (now − was)·progress. — Accepted in Design Notes; an equal layout without scroll in between (the watcher's reload, ~50 ms) is exact.
  - `low` `reject` [edge-case] A card scrolled into view in the continuation that moved snaps. — Same group as the carry rows.
  - `false` `reject` [edge-case] `continues(running)` while `last.layout` is not `running.to` rebuilds deltas mid-run. — The canvas passes a transition only while it runs; any layout landing in between without one ends it (`_moving` null), so no continuation reaches the viewport after another layout pass.
  - `false` `reject` [edge-case] Claim "no restart" fails on a remount. — Same as the patched medium row.
  - `false` `reject` [edge-case] Claim "unless the layout brings a reveal" fails for reveal → null. — Same as the patched guard row.
  - `low` `patch` [verification-gap] The early end's reveal guard is never exercised. — Same patch as the guard row: two canvas tests with `canvasOf(reveal:)`.
  - `low` `patch` [verification-gap] The continuation's `glideOut.add` is unwitnessed. — Added a continuation variant of the glide-out test.
  - `low` `patch` [verification-gap] Nothing pins that a same-op reveal of the born key reaches `model.reveal`. — Added a view-model test, proven by removing `!isContinued`.
  - `false` `reject` [verification-gap] A new canvas state could replay a continuation. — Duplicate of the patched medium row.
  - `low` `reject` [intent-alignment] No single test runs the model's continuation into a running canvas. — Both seams are pinned (the model emits a continuation on the watcher's reload; the canvas keeps it running); joining them adds no branch.
  - `false` `reject` [intent-alignment] The model emits continuations outside the running window. — By design: the canvas decides; after the patch a continuation never starts an animation.
  - `false` `reject` [intent-alignment] "No snap" is witnessed only for an equal layout. — The intent's case is the watcher's same-op reload, an equal layout.
  - `false` `reject` [intent-alignment] No Auto Run Result / commit hash yet. — Written at finalization.

## Design Notes

A continuation keeps each effect's origin (`was + delta` of the old pass) and retargets to the new rect; for an equal layout (the watcher's reload) that is exact, for a same-op layout that moved cards (a stack toggle mid-glide) the card jumps by the retarget's progress share — preferred over snapping, simpler than a velocity-preserving blend. A token object instead of a `continues` back-reference keeps continuations from chaining layouts in memory. The alternative "skip a reload whose head equals the shown op" was not taken: it still snaps every other same-op landing and adds a head read per event.

## Verification

**Commands (from `app/`):**
- `flutter test test/features/graph` -- expected: all pass.
- `dart analyze --fatal-infos .` -- expected: no issues.
- `dart format --set-exit-if-changed lib test widgetbook` -- expected: exit 0.

## Verification Notes

2026-11-01, from `app/` (gate rule of this run: no `cargo make test` / `test-full` / `coverage`; no Rust, FFI, schema or `packages/` file changed, so no cargo, codegen or oracle checks apply):
- Before review: `flutter test test/features/graph` — 700 passed; `dart analyze --fatal-infos .` — no issues; `dart format --set-exit-if-changed lib test widgetbook` — 0 changed. The two pre-existing tests that pinned the snap ("no reveal" on early end; `transition` null on a same-op reload / stack toggle) failed as expected before they were updated.
- After the review patches: `flutter test test/features/graph` — 705 passed; `dart analyze --fatal-infos .` — no issues; `dart format --set-exit-if-changed lib test widgetbook` — 0 changed. Mutation runs (implementer): removing `!isContinued` from the model's suppression, the old reveal guard without `_moving == null`, and the old start condition each turn their new test red; restored.
- Matrix → tests: watcher reload after own verb (`graph_view_model_test.dart`, "the watcher's reload … continues its transition"); same-op layout mid-glide and its glide-out variant (`graph_transition_test.dart`, viewport group); same-op layout mid-transition, continuation after the end, fresh canvas given a continuation, early end (with no reveal, with another key's reveal, with reveal → null) (canvas group); switch mid-transition (view-model switches test: `setRevset` at the same op lands no transition).
- Not run: the app (the timing log of the watcher's reload is Ralph's manual check).

## Auto Run Result

Status: done
Blocking condition: none

**Items:**
- **1 — fixed** (`c45796355055efe765563d04286ee728522d639c`): real whatever the event's timing — every land cleared `_transition`, so a same-op layout ended the running transition and dropped the born reveal. Now the model carries the last transition onto a same-op layout no switch asked for (`GraphTransition.continued`, sharing the landing's token); the canvas keeps a running one going (no restart, no second flash, born edges recomputed) and never starts a continuation; the viewport carries each effect by key, keeping its origin. A layout without a transition still ends the run but reveals the covered born card after that frame, unless it brings a reveal of its own. The timing log in the running app stays Ralph's manual check (it now decides nothing).

**Files:**
- `app/lib/src/features/graph/graph_viewport_render.dart`: `GraphTransition.continued`, `isContinued`, `continues`; effect carry in `_syncTransition`.
- `app/lib/src/features/graph/graph_canvas.dart`: start/continue/end branches, early-end born reveal, `_bornEdgesOf`.
- `app/lib/src/features/graph/graph_view_model.dart`: continuation in `_land`; born suppression only for a fresh transition; class doc.
- `app/test/features/graph/graph_transition_test.dart`, `graph_view_model_test.dart`: the matrix rows and the review's witnesses.

**Review findings** (one pass, 32: high 0, medium 2, low 20, false 10; § Review Triage Log):
- **Patched:** medium — a remounted canvas replayed a continuation (start now needs a fresh transition); medium — the early-end guard dropped the born reveal when the reveal went to null (now `null || identical`), plus a `_moving == null` staleness check; low — witnesses for the guard, the continuation's glide-out and the born reveal at the same op.
- **Deferred:** none.
- **Rejected:** double reveal of the born key within 720 ms; partial carry for a same-op layout that moves cards (accepted in Design Notes); one retained `from` layout; stack toggles continuing a glide; no end-to-end model→canvas test (both seams pinned); flash/moved-layout tests; manual scroll reset in a test; stale spec line numbers; false: spec/Auto Run Result incomplete, ledger close (the loop's job), deltas rebuilt mid-run (unreachable), duplicates of the patched rows.

**Follow-up review recommended:** true — two medium entries were patched (the remount replay and the reveal guard); the unverified risk is the continuation path in the running app, witnessed only by widget tests with hand-built continuations and a fake source.

**Residual risks:** a same-op layout that moves cards mid-glide (a stack toggle) retargets with a jump of the done share; the model keeps a continuation (and one old `from` layout) until the next switch or op; not checked in the running app.
