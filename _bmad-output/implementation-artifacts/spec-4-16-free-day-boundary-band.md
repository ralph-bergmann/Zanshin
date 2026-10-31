---
title: 'Story 4.16 — Free: no card in the band around a day divider'
type: 'feature'
created: '2026-10-31'
status: 'done'
baseline_revision: '9c10c822a49a5c6983d00f4a0d23fe9e4c3f4e33'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/docs/graph-layout.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-4-context.md'
warnings: ['oversized']
deferred: []
---

<intent-contract>

## Intent

**Problem:** In Free, y follows time, so two commits on either side of local midnight less than about 25 min apart in different columns overlap vertically; 10.2's day divider (midway between the older day's newest and the newer day's oldest card) then runs behind both cards (deferred-work.md "Day dividers can cross cards around midnight", item I1; prototype defect 45; DS SYNC #8).

**Approach:** In the engine's free walk (GLD §4.2 free step 3), a step between consecutive walk nodes whose day keys dk(T) differ is at least one pitch: step = max(gap(ΔT), U) instead of gap(ΔT). The newer day's oldest node then sits ≥ 16 units above the older day's newest node in every column; nodes above shift up with it; `rows` grows only at such boundaries. The stack pass (§4.8 (F)) sums the same steps, so grouped layouts keep the band too. Spike reference (gated on `--columns joint`, the product) and product engine change together; invariants, goldens, recordings and docs follow.

## Boundaries & Constraints

**Always:**
- The rule lives in the free model's walk only, in both the spike's Dart reference (`--columns joint` only, so Rust ≡ Dart `--columns mode` and the fuzz stay untouched) and the product engine (always joint); product ≡ spike byte for byte (`compare.mjs --core`).
- The free model is laid out with the rule in both request modes (it feeds the joint packing), so I8 holds.
- dk is the day key of the clamped T at `utc_offset_min` (`dayKey`), for every node incl. the root (root's T = tmin; see Design Notes).
- I5 (free) gains: consecutive buckets satisfy end_{k} + U ≤ start_{k+1}. Core checkers (`invariants.dart`, `stack_invariants.dart`) and the app's `checkLayoutInvariants` (UniformRows, mode free) enforce it.
- Every changed golden / recording is regenerated with the tools, never hand-edited, and listed in this spec with its reason.

**Never:** compact's rows; the painter / divider position (10.2); 10.13's time-gap variant; the Rust reference; lowering any invariant; editing generated recordings by hand.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Demo hand case | root; A 23:50 day 1 and B 00:10 day 2, both children of root (two columns) | y(B) ≥ y(A) + 16; bucket(day1).end + 16 ≤ bucket(day2).start | none |
| Already spaced | same-column chain across midnight whose step is already ≥ 16 (parent edge, or ≥ ~4.3 h apart) | y identical to the pre-4.16 walk | none |
| Same day | consecutive nodes on one day | step = gap(ΔT), unchanged | none |
| Stacks | a run spanning the boundary, collapsed / expanded / none | grouped buckets still a pitch apart; all-expanded = ungrouped output | none |
| Checker | a free layout whose buckets meet (end = start) | core and app checkers report an I5 / day-band violation | test asserts the failure |

</intent-contract>

## Code Map

**SPEC** `docs/graph-layout.md`: top note (add "Amended 2026-10-31, Story 4.16: §4.2, §6, §7.3, §9, §13"); §4.2 free step 3 `:323-340` (the day step, with joint columns / product); step 4 `:351-352` (the "ranges may meet" bullet now only without joint); §6 CLI note for `--columns joint`; §7.3 I5 `:1108-1121` amended; §9 new D12 (day band; closes the known midnight overlap); §13 product = rule always.

**Spike** `spikes/graph-layout-ab/dart/`:
- `lib/src/layout.dart` `_freeRows` `:420-467` — the walk step; `joint` field `:186`; `freeGap` `:65`; `dayKey` there too.
- `lib/src/stacks.dart` (F) `:412-425` — `x += freeGap(...)` → the same step when `layout.joint`.
- `test/layout_test.dart` — witness cases (joint free).
- tools: `goldens.mjs` (regenerate core goldens), `compare.mjs --core <bin>`, `design-layout.mjs`, `record-graph.mjs` (app recordings `app/widgetbook/graph/graph_recordings.g.dart`); `README.md` `## Status` gains 4.16.

**Product** `packages/zanshin_core/lib/src/graph_layout/`:
- `layout_engine.dart` `_freeRows` `:345-396` (walk step), `freeGap` `:56`, `dayKey` `:49`; add a shared helper (e.g. `freeStep(tPrev, t, utcOffsetMin)`) both files use.
- `stacks.dart` (F) `:476-501` — same step.

**Core tests** `packages/zanshin_core/test/graph_layout/`: `engine_test.dart` (witnesses), `invariants.dart` `_freeDayBuckets` `:258-288` (`:265` becomes end + u ≤ start), `stack_invariants.dart` `:307-345` (same for W′), goldens under `goldens/` (regenerated), `golden_test.dart` (design oracles; re-derive numbers only if they move).

**App** `app/lib/src/features/graph/layout_invariants.dart` — `LayoutInvariant` enum `:12-27` gains `dayBandClear`; `checkLayoutInvariants` `:48-109` checks consecutive buckets (`bucketLastRowOf(b-1) + unit ≤ bucketFirstRowOf(b)`) when `vertical` is not `PerNodeTops` and `layout.mode` is free; `app/test/features/graph/layout_invariants_test.dart` gains the failing case; `graph_layout.dart:238-253` bucket accessors.

**Tracking** `deferred-work.md` (I1 bullet closed), `epics.md` Story 4.16 delivered note, `sprint-status.yaml:108` → done (epic-4 back to done), `decisions-review-4-10-to-4-13.md` `### 4.16`, `epic-4-context.md`.

## Tasks & Acceptance

**Execution:**
- `docs/graph-layout.md` -- dated amendments as in the Code Map -- the GLD is the engine's contract.
- `spikes/graph-layout-ab/dart/lib/src/layout.dart`, `stacks.dart`, `test/layout_test.dart` -- the day step under `joint` + witnesses -- reference first.
- `packages/zanshin_core/lib/src/graph_layout/layout_engine.dart`, `stacks.dart` -- port byte-identically -- the product.
- `packages/zanshin_core/test/graph_layout/{engine_test,invariants,stack_invariants}.dart` -- witnesses (I/O matrix) + stricter I5 + a checker-fails case -- safety net.
- `packages/zanshin_core/test/graph_layout/goldens/**`, `app/widgetbook/graph/graph_recordings.g.dart` -- regenerate with `goldens.mjs` / `record-graph.mjs`; list changed files below -- goldens follow the engine.
- `app/lib/src/features/graph/layout_invariants.dart`, `app/test/features/graph/layout_invariants_test.dart` -- `dayBandClear` + a failing hand layout -- app checker follows.
- tracking files -- close I1, mark done.

**Acceptance Criteria:**
- Given the demo hand case, when laid out in Free (with and without stacks), then no card's y lies within one pitch of the divider band: newer day's oldest y ≥ older day's newest y + 16.
- Given any of the 1,000 seeded DAGs and every golden input, when laid out in Free, then the strengthened I5 and I1–I8 hold.
- Given a free layout whose buckets meet, when checked, then both the core and the app checker report it.
- Given the product CLI and the spike `--columns joint`, when `compare.mjs --core` runs, then outputs are byte-identical.

## Spec Change Log

## Review Triage Log

### 2026-10-31 — Review pass
- verdicts: 20 findings — high 0, medium 0, low 11, false 9, maybe-false 0
- findings:
  - `[low]` `[patch]` (blind) D12 / epic-4-context say Compact is unchanged, but compact's joint lanes/columns can move (fuzz `compact.*` hashes changed) — reworded D12 (`docs/graph-layout.md`) and epic-4-context: compact's rows unchanged, its joint lanes/columns can follow, I8 holds.
  - `[false]` `[reject]` (blind) spec `in-review` while tracking says done — Finalize sets `done` and commits spec + tracking together.
  - `[low]` `[reject]` (blind) epic-4-context rewrite drops 4.14/4.15 detail — the file is the compile-epic-context subagent's regenerated digest (workflow step 1); epics.md and the done specs keep the detail; restoring it is not a direct correction.
  - `[low]` `[reject]` (blind) the resolved deferred-work bullet still reads "Low; accepted in 10.2" / "Follow-up: none" — the strike-through + RESOLVED marker makes the state clear; the old text is history.
  - `[false]` `[reject]` (blind) no test at the ~255 min threshold — max(gap, 16) is continuous there: gap(254 min) = 15 → step 16, gap(255 min) = 16 → step 16; the early return is an equivalent shortcut, no observable edge.
  - `[false]` `[reject]` (blind) no evidence the seeded corpus exercises the rule — 23 + 6 fuzz golden hashes changed, i.e. the step fired on seeded cases.
  - `[low]` `[reject]` (blind) app `dayBandClear` negative cases (compact, PerNodeTops) untested — compact layouts have no buckets (vacuous), PerNodeTops skip is a one-line guard; adding cases is not a direct correction.
  - `[false]` `[reject]` (blind) nothing ties one pitch to the painted band / label — Ralph's rule is one card height + gap; `UniformRows` maps 16 units to exactly H + gapY, and the divider sits midway in that gap (10.2).
  - `[low]` `[patch]` (blind) literal 16 in `freeStep` — product now uses `modelUnits[1]`; spike keeps its local literal (it has no shared constant; byte-identity unaffected).
  - `[low]` `[reject]` (blind) spike joint walk has no independent random cross-check — the product runs I5/I6 (and `_walkX` for stacks) on 1,000 seeded DAGs and `compare.mjs --core` ties spike ≡ product.
  - `[low]` `[reject]` (blind) Code Map's GLD note omits §4.8 — fix would edit this spec (rejected by rule).
  - `[false]` `[reject]` (blind) witnesses never vary utcOffsetMin — the re-derived midnight test runs at UTC+2 and the invariant suite covers random offsets.
  - `[low]` `[reject]` (edge) epic-4-context drops the pass-through list's prioritize / short prefixes — same root as the rewrite finding; epics.md / project-context keep the rule.
  - `[false]` `[reject]` (intent) the rule is in the walk step, not "a new step after the walk" — epics.md leaves the exact form to Claude; Design Notes show equivalence (monotone T/y, root at tmin).
  - `[low]` `[reject]` (intent) compact columns change though compact is a non-goal — same root as the D12 wording patch; compact rows unchanged, columns are joint by 4.14's design.
  - `[low]` `[reject]` (intent) no pixel / catalogue / Marionette check of the band — engine-only change; the unit→pixel mapping (`UniformRows`) is untouched and covered by 10.1's tests.
  - `[low]` `[reject]` (intent) app checker skips PerNodeTops — deliberate (hand pixel fixtures, no engine walk), recorded in decisions-review `### 4.16`.
  - `[false]` `[reject]` (intent) no `## Auto Run Result` / commit hash yet — written at Finalize.
  - `[false]` `[reject]` (intent) witnesses only at engine/checker level — every epics.md witness exists and passes; not a defect.
  - `[false]` `[reject]` (verification-gap) no gaps found — nothing to act on.

## Design Notes

**Why max(gap, U) on the walk step suffices.** T and y never decrease along the walk, so the older day's newest node is the walk predecessor of the newer day's oldest node (roots aside). A root has T = tmin and no parents, so its y equals its predecessor's and its dk equals every earlier node's; comparing consecutive walk nodes (root included) therefore gives the same result as comparing consecutive non-root nodes. Every newer-day node is then ≥ U above every older-day node, whatever its column.

**Stacks.** (F) sums the ungrouped steps between consecutive W′ nodes; a sum that crosses a day change contains at least one step ≥ U, so consecutive W′ buckets stay a pitch apart; the ungrouped layout satisfies the new constraint, so compaction (y′ ≤ y) and "all expanded = ungrouped" hold.

**Threshold.** gap < 16 units for ΔT < ~255 min, so day boundaries closer than ~4.3 h grow; boundaries already ≥ 16 apart (or separated by a parent edge) are unchanged.

## Verification

**Commands:**
- in `spikes/graph-layout-ab/dart`: `dart test test/layout_test.dart` (or `dart run`), `dart analyze`; `dart compile exe bin/graph_layout.dart -o build/graph_layout` -- green.
- in `spikes/graph-layout-ab`: `node tools/compare.mjs --digest`, `node tools/fuzz.mjs --cases 300`, `node tools/design-layout.mjs`, `node tools/goldens.mjs` (twice, second run no diff), product CLI AOT + `node tools/compare.mjs --core <bin>`, `node tools/record-graph.mjs` -- exit 0.
- in `packages/zanshin_core`: `dart test test/graph_layout`, `dart analyze --fatal-infos --fatal-warnings`, `dart format --output=none --set-exit-if-changed .` -- green.
- in `app`: `flutter test test/features/graph`, `dart analyze`, `dart format --output=none --set-exit-if-changed lib test widgetbook` -- green.
- No full gate (story-loop gate rule).

**Notes (2026-10-31, build run):**
- spike `dart run test/layout_test.dart`: 59 passed, 0 failed (new `dayBand()` group: demo hand case, already-spaced / same-day unchanged, stacks none / collapsed / expanded; `checkInvariants(..., joint: true)` checks end + U ≤ start; `naiveJointLanes` reads the joint free model). `dart analyze`: no issues. `dart compile exe bin/graph_layout.dart -o build/graph_layout`: ok.
- `node tools/compare.mjs --digest`: 66 identical and invariant-clean, 0 differ. `node tools/fuzz.mjs --cases 300`: exit 0 (1800 agree, 0 disagree). `node tools/design-layout.mjs`: exit 0 (default 8, all 9 lanes). `node tools/goldens.mjs`: exit 0, twice — the second run leaves the same diff (deterministic). Product CLI AOT + `node tools/compare.mjs --core outputs/bin/graph_layout_core`: exit 0, 44 identical and invariant-clean. `node tools/record-graph.mjs`: exit 0, 16 recordings, `app/widgetbook/graph/graph_recordings.g.dart` unchanged.
- `packages/zanshin_core`: `dart test test/graph_layout` 194 passed; `dart analyze --fatal-infos --fatal-warnings` no issues; `dart format --output=none --set-exit-if-changed .` 0 changed.
- `app`: `flutter test test/features/graph` 279 passed; `dart analyze` no issues; `dart format --output=none --set-exit-if-changed lib test widgetbook` 0 changed.

**Regenerated goldens (by `tools/goldens.mjs`, none hand-edited):**
- `packages/zanshin_core/test/graph_layout/goldens/fuzz/expected.json` — 23 hash entries (some sizes) of seeded fuzz cases whose day boundaries lay closer than a pitch: their free rows grow by the day step, and through the joint packing their lanes / compact-mode outputs can follow.
- `packages/zanshin_core/test/graph_layout/goldens/stacks/fuzz/expected.json` — 6 hash entries, same reason with stacks ((F) sums the day-aware steps).
- No design, fixture or budget golden and no app recording changed.
- `engine_test.dart`'s hand test `two_days_less_than_a_minute_apart_across_local_midnight_*` was re-derived by hand: B now at 16 (was 0), buckets [0, 0] / [16, 16].
- After the review patches (2026-10-31): `packages/zanshin_core` `dart test test/graph_layout` 194 passed, `dart analyze --fatal-infos --fatal-warnings` no issues, format 0 changed; app `flutter test test/features/graph` 279 passed, `dart analyze` no issues, format 0 changed (re-run by the orchestrator); spike `dart run test/layout_test.dart` 59 passed.

## Auto Run Result

Status: done

**Summary.** Free's walk step across a day change is now max(gap(ΔT), U = 16) (GLD §4.2 free.3; the stack pass (F) sums the same steps), so the newer day's oldest card sits at least one pitch above the older day's newest card in every column and the band around 10.2's day divider holds no card. Spike Dart reference (under `--columns joint`, the product's mode) and product engine (always) changed together; product ≡ spike (`compare.mjs --core`). I5 (free) is now end_k + U ≤ start_{k+1} in the core checkers and the app's `checkLayoutInvariants` (`dayBandClear`, row model, Free).

**Items.**
- I1 (day dividers can cross cards around midnight): fixed — commit recorded in the run report (the feature commit `feat(graph-layout): Story 4.16 …`); deferred-work.md bullet marked RESOLVED.

**Files changed.**
- `docs/graph-layout.md` — dated 4.16 amendments: top note, §4.2 free.3/4, §4.8 (F), §6, §7.3 I5, §9 D12, §13.
- `spikes/graph-layout-ab/dart/lib/src/layout.dart`, `stacks.dart` — `freeStep` (joint only) in the walk and (F).
- `spikes/graph-layout-ab/dart/test/layout_test.dart` — `dayBand()` witnesses; joint I5 check.
- `spikes/graph-layout-ab/README.md` — Status item for 4.16.
- `packages/zanshin_core/lib/src/graph_layout/layout_engine.dart`, `stacks.dart` — `freeStep` in the walk and (F).
- `packages/zanshin_core/test/graph_layout/engine_test.dart`, `stacks_test.dart` — demo case, already-spaced / same-day, midnight stack, checker-fails grid.
- `packages/zanshin_core/test/graph_layout/invariants.dart`, `stack_invariants.dart` — strengthened I5; day-aware `_walkX`.
- `packages/zanshin_core/test/graph_layout/goldens/{fuzz,stacks/fuzz}/expected.json` — regenerated (23 + 6 hashes).
- `app/lib/src/features/graph/layout_invariants.dart`, `app/test/features/graph/layout_invariants_test.dart` — `dayBandClear` + failing/passing cases.
- Tracking: `deferred-work.md`, `epics.md` (delivered note), `sprint-status.yaml` (4-16 + epic-4 done), `decisions-review-4-10-to-4-13.md` (`### 4.16`), `epic-4-context.md` (recompiled).

**Review.** 20 findings: 2 patched (low: D12/context wording on compact's joint columns; `modelUnits[1]` instead of a literal 16 in the product's `freeStep`), 0 deferred, 18 rejected (9 false, 9 low) with reasons in the triage log. Follow-up review: not recommended (patched 0 high, 0 medium).

**Verification.** Targeted checks only (story-loop gate rule): see Verification notes — spike tests/tools, zanshin_core graph_layout tests + analyze + format, app graph tests + analyze + format, all green. Full gate / coverage not run (the loop runs it at its end).

**Residual risks.** No on-screen (Marionette) check of the divider band — engine-only change, the unit→pixel mapping is untouched. Stack witnesses check the band and "expanded = ungrouped", not hand-derived stack rows. Spike's non-joint `free` keeps the pre-4.16 walk (Rust ≡ Dart reference).
