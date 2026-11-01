---
title: 'Story 10.19 closing run — gap legend kept inside the window, member keys for Show in all(), vertical runs indexed by y'
type: 'bugfix'
created: '2026-11-01'
status: 'done'
baseline_revision: 'a9e6790235549e63c28f5e9d7ef45cf8c7d250b9'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-10-context.md'
warnings: []
deferred: []
---

<intent-contract>

## Intent

**Problem:** Story 10.19's run deferred three items (its spec's `deferred:`), verified against the current code in this planning run: (1) the gap legend popover (`graph_gap_legend.dart:180`, a `CompositedTransformFollower` at the chip's bottom-left) has no clamp, so a chip within 328 px of the window's right edge clips it — in the floating shell at 1041 px the chip sits in the centred VIEW island and fits, but nothing keeps it so; (2) `_showGap` (`graph_canvas.dart:717-729`) sends `stack:<oldest>` keys for a folded child or target, and `_gapLanding` (`graph_view_model.dart:419`) looks targets up by `indexOfKey` — when `all()` folds the target's run under another oldest member (or the key lands on a folded member, which has no edges), the back-trace starts nowhere and the flash is empty; (3) marker placement scans every vertical run of the x strip (`graph_gaps.dart:656-664, 679-685`) — measured: one lane of dashed edges, 1 000 / 5 000 / 20 000 nodes → 24 / 83 / 885 ms, quadratic.

**Approach:** (1) Shift the popover left by what it would pass `window width − 8`, like View options (`graph_controls.dart:397-415`); (2) send member keys — a stack child's oldest member, a stack target's newest member (where an edge enters a run) — and resolve targets with `placeOfKey`; (3) index router B's vertical runs per x by top with a running maximum of bottoms, so a lookup costs its hits.

## Boundaries & Constraints

**Always:** the legend keeps its 6 px drop below the chip and its left alignment whenever it fits; `GraphGapTarget.child/targets` never hold a stack key; placement output is identical to the scan's (the `bad` intervals are sorted afterwards, so lookup order is irrelevant); new lines get tests; gate rule of this run: targeted checks only (`flutter test`, `dart analyze`, `dart format --set-exit-if-changed` in `app/`), no `cargo make test` / `test-full` / `coverage`.

**Never:** a change to Story 10.19's spec, `epics.md`, `sprint-status.yaml`, `design/`, `design_system/`, Rust, FFI or schemas; re-mirroring these three items into deferred-work.md; a timing assertion in a test.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Legend in the shell | floating shell, 1041 px, design-default recording | popover left = chip left, top = chip bottom + 6, right ≤ 1033 | — |
| Legend at the right edge | chip right-aligned in a 1041 px window | popover right = 1033, top = chip bottom + 6 | — |
| Gap between stacks | folded child stack [m0, m1] --dashed--> folded target stack [a0, a1] | `GraphGapTarget(child: 'm0', commitId: m0's, targets: ['a1'])` | — |
| Target refolded in all() | target `a1`; `all()` folds [z, a0, a1] as `stack:z` | reveal `h1`, flash `{h1}` | — |
| Long one-lane history | 3 000 nodes, every edge dashed, adjacent rows | 2 999 markers, none fallback, each mid row gap | — |

</intent-contract>

## Code Map

- `app/lib/src/features/graph/graph_gap_legend.dart:175-195` -- the overlay follower; `_LegendPopover` `SizedBox(width: 320)` → shared const `graphGapLegendWidth`; `_shift` reads the chip's `RenderBox` (the state's `context`) and `MediaQuery.sizeOf(overlay)`.
- `app/lib/src/features/graph/graph_controls.dart:397-415` -- `_PopoverLayout`: View options' "kept 8 inside the window" (read only, the reference).
- `app/lib/src/features/graph/graph_canvas.dart:717-729` -- `_showGap`; `graphGapCommitNode` (`graph_gap_callout.dart:62`) = a stack's oldest member; `GraphLayout.runMembersOf` is oldest-first, so `.last` is the newest.
- `app/lib/src/features/graph/graph_view_model.dart:112-127` (`GraphGapTarget` docs), `:394-433` (`_gapLanding`; `placeOfKey` at `graph_layout.dart:332`). Grid edges of a grouped layout end at stack nodes; folded members carry none (`zanshin_core/.../graph_grid_view.dart:122-126`).
- `app/lib/src/features/graph/graph_gaps.dart:381-735` -- `_Placer`, `_segment`'s two vertical lookups, `_lowerBound`; router B's `verticalXs/Tops/Bottoms/Edges` sorted by x (`packages/zanshin_core/lib/src/graph_layout/router.dart:546-640`, read only).
- Tests: `app/test/features/graph/graph_controls_test.dart` (gap legend group, `_Rig` = the real `FloatingShell`), `graph_gaps_test.dart` (placement group; canvas group's stack `Show in all()` test), `graph_view_model_test.dart` ("Story 10.19: Show in all()" group, `gapModel`).

## Tasks & Acceptance

**Execution:**
- [x] `app/lib/src/features/graph/graph_gap_legend.dart` -- `graphGapLegendWidth`, `_shift`, the follower offset `Offset(_shift(overlay), 6)` -- item 1.
- [x] `app/lib/src/features/graph/graph_canvas.dart` -- member keys in `_showGap` -- item 2.
- [x] `app/lib/src/features/graph/graph_view_model.dart` -- `placeOfKey` for targets, `GraphGapTarget` docs -- item 2.
- [x] `app/lib/src/features/graph/graph_gaps.dart` -- `GraphVerticalRuns`, `@visibleForTesting` since the review (per-x groups by top, running max bottom, `overlapping(x0, x1, y0, y1)`), both vertical lookups through it, the shortcut comment replaced -- item 3.
- [x] tests for every matrix row (see Code Map).

**Acceptance Criteria:**
- Given the three items, when this run ends, then `## Auto Run Result` lists each by number with fixed (commit) / rejected (reason) / deferred.
- Given the finished tree, when `git status` is read, then only the files in the Code Map and this run's spec changed.

## Spec Change Log

## Review Triage Log

### 2026-11-01 — Review pass
- verdicts: 20 findings — high 0, medium 0, low 11, false 9, maybe-false 0
- findings:
  - `low` `patch` [blind] The 3 000-node lane test passes with the old scan or a broken index. — Probed: an index that returns nothing still passed every gaps test (recordings' brute-force oracle and a 2 000-node synthetic layout included); added a differential test of the index against a scan of every run on a 3 000-node synthetic geometry (2 000 random ranges, inclusive x/y boundaries); it fails with `<` for `<=` in the binary search. The class became `@visibleForTesting GraphVerticalRuns`.
  - `low` `patch` [blind] Nothing tests `overlapping` directly (overlapping runs, skipped runs, several x groups, boundaries). — Same patch as the row above.
  - `low` `reject` [blind] The hit order changed and nothing says callers must not depend on it. — Its only caller sorts `bad`; a note was added to the walk's comment with the next patch anyway, at no cost.
  - `low` `patch` [blind] The walk's comment names `k` before it exists. — Reworded ("end before lo"), plus the order note.
  - `false` `reject` [blind] `_shift` clamps only the right edge; a narrow window pushes the left edge out. — The chip is not built at or below 1040 px (`graph_controls.dart:131`), so the window is ≥ 1041 > 336 and a negative shift never passes the left edge; the doc now says so.
  - `low` `reject` [blind] The shift is read at build from the chip's last position, stale if the chip moves while open. — Needs the popover open while the island relayouts without a rebuild of the legend (the legend rebuilds on every model change); everyday use does not meet it, and a layout-time clamp is more than a direct correction.
  - `low` `reject` [blind] The clamp is not shared with View options. — View options clamps an anchor rect in a `CustomSingleChildLayout` under `RawMenuAnchor`; the legend follows a leader layer; sharing one `min` needs a new abstraction.
  - `false` `reject` [blind] Window coordinates, overlay width and follower space may differ in a nested overlay. — `localToGlobal` and `MediaQuery.sizeOf` are both window-relative, and the follower offset is applied relative to the leader, unscaled in the shell; an inset overlay moves neither.
  - `false` `reject` [blind] A Missing gap's member-key child folded in all() may not reveal. — Reveals resolve keys with `placeOfKey` (`graph_viewport_render.dart:512-548`), so a folded member reveals its stack card; before, the stack key could miss entirely.
  - `false` `reject` [blind] `entry` relies on an undocumented member order; `runOf(node)!` may crash. — `runMembersOf` is documented oldest first (`graph_layout.dart:309`); `isStackNode` is true only when `runOf` is non-null.
  - `low` `reject` [blind] No assert that `GraphGapTarget` keys are never stack keys. — A new guard on a const constructor for a contract with one producer; not worth the added check.
  - `low` `reject` [blind] The view-model test does not combine a stacked child with a refolded target end to end. — Each seam is pinned (canvas emits member keys, view model resolves them by place); combining adds no new branch.
  - `false` `reject` [blind] The canvas test's multi-line signature is reformatting noise. — `dart format` output for the title's length; the gate requires it.
  - `false` `reject` [edge-case] Shift has no lower bound in a narrow window. — Same refutation as the blind left-edge row.
  - `low` `reject` [edge-case] The shift goes stale when the chip moves while open. — Same as the blind stale-position row.
  - `low` `patch` [edge-case] The doc claims "8 inside the window like View options" though only the right edge is clamped. — Doc now names the right edge and why the others are unreachable.
  - `low` `patch` [verification-gap] The new one-lane test does not check what `overlapping` returns. — Same patch as the first blind row.
  - `false` `reject` [intent-alignment] Item 1 shipped a clamp although the 1041 px check found no clip. — The ledger asks to check and clamp if it clips; the real VIEW island also holds the search field and the count, which the rig lacks, so "fits in the rig" does not prove "never clips"; the unconditional clamp is View options' rule.
  - `false` `reject` [intent-alignment] Item 2 also changed the child key beyond the ledger's targets. — The item's title names "child or target"; the child's stack key feeds the reveal fallback the same way.
  - `false` `reject` [intent-alignment] Auto Run Result lacks commit hashes. — Written at finalization.

## Design Notes

Item 3 measured with a throw-away probe test (one lane, every edge dashed, rows 2 apart): 24 / 83 / 885 ms before, 17 / 33 / 30 ms after at 1 000 / 5 000 / 20 000 nodes. The running-maximum walk stays linear in the hits while one x's runs do not nest; a long run early in a group would make it scan down to that run (shortcut comment in the code) — runs of one x rarely overlap, since they would share a line.

Item 1: the rig's floating shell at 1041 px puts the chip in the centred VIEW island with room to spare (no clip there); the clamp is unconditional anyway, so a wider search field or capsule cannot push it out.

## Verification

**Commands (from `app/`):**
- `flutter test test/features/graph` -- expected: all pass.
- `dart analyze` -- expected: no issues.
- `dart format --set-exit-if-changed lib test widgetbook` -- expected: exit 0.

## Verification Notes

2026-11-01, from `app/`: `flutter test test/features/graph` — 668 passed; `dart analyze` — no issues; `dart format --set-exit-if-changed lib test widgetbook` — 0 changed. Matrix rows → tests: legend in the shell / at the right edge (`graph_controls_test.dart`, gap legend group), gap between stacks (`graph_gaps_test.dart`, canvas group), target refolded in all() (`graph_view_model_test.dart`, "Story 10.19: Show in all()"), long one-lane history (`graph_gaps_test.dart`, placement group). `git status`: only the Code Map files and this spec changed.

After the review patches (2026-11-01, from `app/`): `flutter test test/features/graph` — 669 passed; `dart analyze` — no issues; `dart format --set-exit-if-changed lib test widgetbook` — exit 0. The new index test fails with the binary search's `<=` turned into `<` (checked, reverted). Full `flutter test` in `app/`: the graph suites pass; 5 `worker_project_repos_test.dart` (real worker) cases fail identically on the clean baseline (`git stash` check) — unrelated to this change. Not run (gate rule of this run): `cargo make test` / `test-full` / `coverage`; no Rust, FFI or `packages/` file changed.

## Auto Run Result

Status: done
Blocking condition: none

**Items:**
- **1 — fixed** (`34ffbba13972e33fd71204ef1912541150786766`): checked in the real `FloatingShell` at 1041 px (widget rig) — the chip sits in the centred VIEW island and the popover fits there, but the app's island also holds the search field and nothing kept it inside; the popover now shifts left so its right edge stays 8 inside the window, View options' rule, and keeps its 6 px drop and left alignment when it fits.
- **2 — fixed** (`34ffbba13972e33fd71204ef1912541150786766`): real — with all() folding the target's run under another oldest member, the stack key missed, and a member key would land on a folded node without edges; Show in all() now sends member keys (a stacked child's oldest, a stacked target's newest — where an edge enters a run) and the view model resolves targets with `placeOfKey`; the ledger's view-model case (stack:a0 → stack:z) reveals `h1` and flashes it.
- **3 — fixed** (`34ffbba13972e33fd71204ef1912541150786766`): real — one lane, every edge dashed: 24 / 83 / 885 ms at 1 000 / 5 000 / 20 000 nodes (quadratic); indexed per x by top with a running maximum of bottoms: 17 / 33 / 30 ms; same placement (the blocked intervals are sorted afterwards).

**Files:**
- `app/lib/src/features/graph/graph_gap_legend.dart`: `graphGapLegendWidth`, `_shift`, the follower offset.
- `app/lib/src/features/graph/graph_canvas.dart`: member keys in `_showGap`.
- `app/lib/src/features/graph/graph_view_model.dart`: `placeOfKey` for targets; `GraphGapTarget` docs.
- `app/lib/src/features/graph/graph_gaps.dart`: `GraphVerticalRuns` (`@visibleForTesting`) and both lookups through it.
- `app/test/features/graph/graph_controls_test.dart`, `graph_gaps_test.dart`, `graph_view_model_test.dart`: the matrix rows and the index's differential test.

**Review findings** (one pass, 20 findings: high 0, medium 0, low 11, false 9; § Review Triage Log):
- **Patched (all low):** a differential test of the vertical-run index against a full scan (an index answering nothing had passed every gaps test, the recordings' oracle included); the walk's comment; the legend doc names the right edge only.
- **Deferred:** none.
- **Rejected:** hit-order note (its one caller sorts); stale shift while open (needs a relayout without a rebuild, layout-time clamp more than a correction); shared clamp with View options (different anchoring); a stack-key assert; a combined end-to-end case (both seams pinned); false: left-edge overflow (chip absent ≤ 1040 px), coordinate spaces, Missing reveal of a folded member (reveals use `placeOfKey`), member order (documented oldest first), test formatting, the unconditional clamp, the child key, the missing hashes.

**Follow-up review recommended:** false — patched: 0 high, 0 medium, 3 low entries.

**Residual risks:** the legend's shift is computed at build from the chip's last layout, so it can trail a relayout while the popover is open; no Marionette check of the running app (widget tests on the real floating shell only); the index's walk degrades to a scan down to one long early run of an x (shortcut comment).
