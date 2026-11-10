---
title: 'Story 4.17: Columns by branch, per mode — the lab''s column rules replace the lane packing and the lane order'
type: 'feature'
created: '2026-11-10'
status: 'done'
baseline_revision: '57e8043a7d637fd85912c82192ad32db91f8ba27'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-4-context.md'
  - '{project-root}/docs/graph-layout.md'
  - '{project-root}/spikes/graph-layout-lab/README.md'
  - '{project-root}/spikes/graph-layout-lab/lib/columns.dart'
warnings: ['oversized']
deferred:
  - summary: >-
      Router B can draw a merge between adjacent rows of one column as a line that steps back over itself, and no check looks at that shape.
    evidence: |-
      `_placeTracks` sets no order between the two runs when the two ends share one x, because `inside` is false for both (router.dart:1625). 13 of 1,737 same-column merge polylines on seeded graphs step downward; the lab repositories, fixtures and recordings have 0 such edges. Story 4.18's line gate must run on an input with this shape (a `goldens/fuzz` case has it) and assert that the polyline climbs without retracing.
    location: >-
      packages/zanshin_core/lib/src/graph_layout/router.dart:1625
    severity: low
---

<intent-contract>

## Intent

**Problem:** The engine's columns grew rule by rule (the joint packing of 4.14, the `compact` order of 4.11, the short-piece return D13, the closing pass D14), and real repositories still show outliers: the main branch drifts right, a branch changes its column, a card sits far from its lines. Ralph approved the lab's column rules on 2026-11-10 and decided that Free and Compact each choose their own columns (I8 goes).

**Approach:** Dated GLD amendments first. Then one engine phase, `chooseColumns`, places every branch by the rule below on the requested mode's rows; the packing, the short-piece return and `compact_order.dart` go; `LaneOrder`, `order` and `budget` go all the way from `GraphViewModel` to `computeGraphGrid`; §4.8's constraint (C) is restated for branch columns; goldens and recordings are recorded again with the product CLI; the lab checks that the product's columns equal its own.

## Boundaries & Constraints

**Always:**
- **The rule** (GLD §4.3, amended; reference `spikes/graph-layout-lab/lib/columns.dart`, `chooseColumns` with `reserveToMerge`, `shortFirst`, `endsFirst`, `dockToParent` on and `sameColumns`, `fewestSkipped` off). All rows are the requested mode's; U is one pitch in that mode's units.
  - **Branch:** a first-parent chain. A node continues its first parent's branch iff it is that parent's continuation child (`continuations()`); else it starts a branch.
  - **Main branch:** the branch of the node with the least (priority, row); of several such nodes, the one with the highest index. It is in column 0, and no other branch is.
  - **Reserved rows:** a branch takes the rows [lo, hi] of its column, from its bottom card to its top card. lo reaches down to one pitch above its fork (the bottom card's first parent). hi reaches up to one pitch below the child of each of its merge edges (an edge from one of its cards that is not the child's first-parent edge).
  - **Free:** a column is free for a branch iff every branch o in it keeps one pitch from it: lo(o) ≥ hi + U or lo ≥ hi(o) + U.
  - **Dock:** a branch docks to the main branch (column 0) if it forks from the main branch (a branch with no parent counts as forking from it), or if it merges into a branch other than the one it forks from; its depth is 1. Every other branch docks to the column of the branch it forks from; its depth is that branch's depth + 1.
  - **Order:** the main branch first; then by depth; then the branch that ends first (the lower hi), then the shorter one (hi − lo), then the one with the older bottom card (row, priority, index).
  - **Place:** a branch takes the free column nearest to its dock: for d = 0, 1, 2, … first dock − d (never below column 1), then dock + d (d > 0).
- **Per mode.** Free and Compact each run the rule on their own rows. A card may change its column on a mode switch. `col` = `lane` for every node. The grid's `lanes` is max lane + 1, and no column is empty.
- **Rows do not change:** §4.2 (both models' rules, the day keys in both modes, 4.16's day band) and timestamps for every request.
- **Stacks (§4.8):** the columns come from the requested mode's ungrouped layout; a stack toggle and "Group stacks" never move a column (I7). A run is a piece of one branch, so its members share a column: no run is ever split. (C) is restated in Design Notes: Y (the ungrouped rows) satisfies it, so y′ ≤ Y and a layout with every run expanded equals the ungrouped one.
- **Invariants (GLD §7.3, amended):** I1, I5, I6, I7 hold as before. I2 is restated: in one column, consecutive cards keep at least U, and two branches keep one pitch between their reserved rows. I3 is restated: `straight` ⇔ lane(p) = lane(i) (a merge child may sit in its merge parent's column); `merge` ⇒ pos ≥ 1 and not blocked; blocked ⇒ lanes differ. I4 is restated: col = lane; the main branch is alone in column 0; a branch has one column. I8 is removed. These hold on every golden input and on ≥ 1,000 seeded DAGs × both modes × the stack states collapsed, expanded, default, random.
- **Grid format stays versions 3 / 4.** Header slot 2 holds 0 (`greedy`'s value) and `GraphGridView.fromBytes` refuses any other value. `GraphGridView.order` goes. §3's canonical JSON has no `order` key.
- **Engine guardrails:** integers only, deterministic (same input, same bytes); flat typed arrays and CSR; no per-node objects or maps on hot paths; no `.sort(` in `lib/src/graph_layout`; no static or top-level `final` tunables; engine-core files import only `dart:typed_data`, `package:meta` and engine files. Contract violations stay V1–V5. The placement uses one interval structure per column (`LaneIntervals`), and the SPEC states its bound.
- **Every changed golden and recording** is regenerated with the tools (goldens with the product CLI `packages/zanshin_core/benchmark/graph_layout_cli.dart`), never edited by hand, and listed with its reason in this spec.
- **Quality bar:** SPDX first line on new `.dart` / `.mjs` files; `///` docs on every public member; `dart analyze --fatal-infos --fatal-warnings` and `dart format` (page width 120) clean in every touched Dart package; scenario-named tests; no `skip:`; no timing assertions. New comments explain the why in plain language and name GLD sections, not story or ticket numbers.
- **Repo conventions:** fixtures are never regenerated; the spike's `inputs/`, `outputs/` and the lab's `data/` stay untracked; no new pub or npm dependency; `sprint-status.yaml` changes only the `4-17-…` status value and `last_updated`; `epic-4-context.md` is edited last; every deferral goes to the spec's `deferred:` AND `deferred-work.md` § "Surfaced in Story 4.17 (bmad-build-auto, 2026-11-10)" in the shape the dispatch prescribes.
- **Gate rule of this run:** no `cargo make test`, `test-full` or `coverage`; verify with the targeted checks in § Verification and record every outcome.
- **Environment:** absolute paths in every command and never a bare `cd` (zoxide can jump to another project); file edits with the Edit and Write tools, never `sed`, `perl`, `python` or heredocs through Bash; run every check to the end in the foreground; no `git commit` or other history edit (staging a deletion is fine: the run that started this work commits).

**Never:**
- No change to lines (Story 4.18: router B draws on the new columns until then), to the painter, or to the view's mode-switch behaviour (no animation).
- No switch or request parameter that chooses between column rules; no `same-columns` or `fewest-skipped` variant in the product; no branches on both sides of the main branch; no port of the rule into the A/B spike's Dart or Rust reference.
- No Rust, FFI, schema or `coverage-baseline.txt` change; no new engine-type export in `lib/zanshin_core.dart` (the `LaneOrder` exports go); no type named `GraphLayout` or `GraphRef` in `packages/`.
- No edit of accepted GLD text: dated amendments only.
- No `jj` in this repository or any existing repository: only in temp directories this run created. No opening of Ralph's own projects in the app: only `CFFIXED_USER_HOME` temp homes with a replica repository.

## I/O & Edge-Case Matrix

Hand cases list nodes children-first, as `index:name→parents`; columns are per node index. Without timestamps Free's rows are 16 × Compact's, so both modes agree unless the row says otherwise.

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| A nested branch sits nearer | `engine_test.dart`'s `nested` input (trunk, S nested inside L, X after L) | col `[0,1,0,0,0,2,0,2,1,0,2,0,2,0,0]`: S col 1 < L col 2, X back in col 1 | none |
| Partial overlap: ends first sits nearer | `0:T5→[T4,B1] 1:B1→T2 2:T4→[T3,A1] 3:A1→R 4:T3→T2 5:T2→T1 6:T1→R 7:R`, priority `[0,2,0,2,0,0,0,0]` | col `[0,2,0,1,0,0,0,0]`: A ends first and sits nearer, although it is longer | none |
| Side branch back into its branch | `0:M5→[M4,F3] 1:M4→M3 2:F3→[F2,G1] 3:M3→M2 4:F2→F1 5:G1→F1 6:M2→M1 7:F1→M1 8:M1→R 9:R`, priority `[0,0,2,0,2,2,0,2,0,0]` | col `[0,0,1,0,1,2,0,1,0,0]`: G docks to F, placed after it | none |
| Side branch into the main branch | the same with `1:M4→[M3,H1] 2:F3→F2 5:H1→F1` | col `[0,0,2,0,2,1,0,2,0,0]`: H docks to main and ends first | none |
| Column used again one pitch after a merge | `0:M5→[M4,T1] 1:T1→M2 2:M4→M3 3:M3→[M2,F1] 4:M2→M1 5:F1→R 6:M1→R 7:R`, priority `[0,2,0,0,0,2,0,0]` | col `[0,1,0,0,0,1,0,0]`; with `1:T1→M1` instead: col `[0,2,0,0,0,1,0,0]` | none |
| Columns per mode (I8 is gone; a column free in its mode) | `engine_test.dart`'s `xy` input (X and Y disjoint in Compact, overlapping in Free) | Compact col `[1,0,1,0,0,0,0]`, Free col `[2,0,1,0,0,0,0]` | none |
| A merge child in its parent's column | `0:M2→M1 1:i→[M1,F1] 2:M1→R 3:F1→R 4:R`, priority `[0,2,0,2,0]` | col `[0,1,0,1,0]`, edge F1→i: `straight`, not blocked, position 1; restated I1–I4 hold; router B classes it `gutter` | none |
| Main-branch tie | two parentless nodes of equal (priority, row) | col `[1,0]`: the higher index is the main branch | none |
| Empty input | n = 0 | `rows` 0, `lanes` 0, both modes | none |
| Runs are never split | any stack request, every generated stack graph | every run's members share one column | test asserts it |
| Every run expanded | any input with stack facts, every run in `keep_open` | nodes, edges, buckets and `rows` equal the ungrouped output | none |
| (C) needs a second sweep | the 21-node input in Design Notes, Compact, every run collapsed | `StackLayout.sweeps` = 2; y′ as listed there; y′ is the checker's least solution | none |
| Grid decode | a version 3 / 4 buffer with slot 2 = 0; slot 2 = 1 | the first reads; the second `FormatException` | `FormatException` |
| CLI | `graph_layout_cli layout --order greedy …`, `router_cli … --order greedy` | exit 2, unknown flag | exit 2 |
| Worker | real cdylib, a repository laid out in Free and in Compact without `order` / `budget` | each grid equals the engine's output for that mode; `topology.hasTimestamps` true for both | none |
| Determinism | the same input twice | identical bytes | none |

</intent-contract>

## Code Map

**SPEC** `docs/graph-layout.md`, dated "Amended 2026-11-10, Story 4.17" notes (never rewrite accepted text):
- a top note in the style of `:21-22`, listing §2, §3, §4.2, §4.3, §4.7, §4.8, §6, §7.2, §7.3, §8.2, §9, §12, §13.
- §2 and §3 `:88`, `:207-248`: the request has no `order` / `budget`; §3's output has no `order`; the joint-columns note of §3 no longer holds.
- §4.2 `:345-378`: the day step's "feeds the joint packing, so I8 holds" no longer applies; the step stays.
- §4.3 `:380-475`: a **Branch columns** subsection (the rule; I2's restatement; the bound: O(n + E) for the spans, O(C log C) for the order, ≤ K + 1 binary-searched probes per branch of the K columns, and an insert that shifts the column's tail); the joint packing and "Short pieces return" are superseded.
- §4.6 / §4.7 `:524`, `:611`: a note that §4.7 is removed from the product (the text stays as history), `col` = `lane`.
- §4.8 `:774-967`: step 4 (no run is split, D11 gone); (C) restated per Design Notes; "Termination" re-derived; the hand-derived `all` 19 → 15 and `default` 9 → 7 stay and are re-checked by `golden_test.dart` (re-derive by hand before changing a number).
- §6 `:987-1034`: the product CLI has neither `--order` nor `--budget`.
- §7.2 `:1101-1122`: the joint oracle retires. §7.3 `:1174-1219`: I2–I4 restated, I8 removed, branch invariants added.
- §8.2 `:1242`: the product CLI times layering, lanes, blocked, routing (and stacks), no `ordering`.
- §9 `:1306`, `:1346`, `:1351`, `:1325`: D5, D13, D14 superseded; D11 no longer applies (no split runs); a new **D15**: columns by branch and per mode come from the lab, not the design (SYNC #8 no longer followed).
- §12 and §13 `:1420-1427`, `:1471-1483`, `:1547-1574`: the shipped scope has no lane orders and no budget; `compact_order` is gone; columns per mode; the goldens are the product CLI's; `tools/compare.mjs --core` no longer applies; the reference for columns is the lab.

**Engine** `packages/zanshin_core/lib/src/graph_layout/`:
- `layout_engine.dart`: `computeGraphGrid` `:95-123` drops `order` / `budget` and the ordering phase. `layering` `:239-255` is unchanged (it keeps both models, Design Notes). `packLanes` `:460-481` becomes `chooseColumns()`. Goes: `_returnShortPieces`, `_mergeParentIn`, `_intervals`, `_packVisit`, `routesOf`, `modelVisit`, `orderLanes`, `leastLaneFrom`, `_maxReturnedPiece`, `_negInf`, the `compact_order` import. `col` becomes `late Int32List` (the lab replaces it). `toGrid` `:796` loses its parameter. `LaneIntervals` `:854-928` is reduced to what disjoint intervals need (`overlaps(lane, a, b)`, `insert(lane, a, b)`; no owner, no prefix maxima). The file's header comment is rewritten, and every doc comment here and in the other engine files that states joint columns, I8 or a lane order follows (`modelUnits`, `modelY`, `graph_grid_view.dart:105-107`, `input_builder.dart`, `layout_input.dart`).
- `compact_order.dart`: deleted.
- `stacks.dart`: `split` goes (`:106-107`, `:396-404`, `:416`, `:586`); `_segmentConstraints` `:576-602` takes the restated δs; `_rows` `:503-531` sweeps until every (C) constraint holds and records `sweeps`; `toGrid` `:721` loses its parameter.
- `graph_grid_view.dart`: `order` goes from the class, `fromBytes` `:202-205` (slot 2 must be 0), `writeGraphGrid` `:460`, `writeStackGrid` `:540` (write 0 at `_slotOrder`); the format doc `:94-114` follows.
- `layout_request.dart`: `LaneOrder`, `defaultLaneOrder`, `defaultLayoutBudget` go. `layout_reply.dart` `:29-37`, `:52`: `order` / `budget` go. `input_builder.dart` only if a comment states the old guarantee.

**Worker and barrel** `packages/zanshin_core/lib/`: `src/worker/commands.dart:19,355-357,385,391`; `src/worker/isolate.dart:64,863,875-877,890,899-901,3860-3862,3893-3895`; `src/worker/handle.dart:50,226-228,251,263-264,280-282`; `zanshin_core.dart:129`; `docs/ffi-abi.md:1392`.

**Benchmarks** `packages/zanshin_core/benchmark/`: `graph_layout_cli.dart` (usage, `_layout`, `_bench`, the `ordering` phase, the `order` flag and the bench JSON's `"order"`); `router_cli.dart:9-10,43-44,165,240,321,348,363,378-380,394,398`. `graph_layout_occupancy.dart` and `graph_content_page.dart` pass no order (only comments may mention it).

**Core tests** `packages/zanshin_core/test/`:
- `graph_layout/invariants.dart`: restate I2–I4 in `invariantFailures` `:214-233`; delete `compactAgainstGreedy`, `i8Failures`, `naiveSegments`, `naiveCompactCost`, `naiveModelCost`, `reservationFailures`, `tickCrossings`, `greedyEngine`; add `naiveBranchColumns(g, y, u, cont)` (the rule read literally: plain lists, library sorts, every candidate column scanned) and `branchFailures` (main alone in column 0; one column per branch; two branches of one column keep a pitch).
- `graph_layout/invariants_test.dart`: per mode only; on every input and golden input the engine's columns equal `naiveBranchColumns`, plus `branchFailures`.
- `graph_layout/engine_test.dart`: delete the `naiveJointLanes` helper, the `compact lane order` and `joint columns` groups and the short-piece tests; add a `branch columns` group with the matrix's hand cases; the `lane packing` cases that remain re-derive their columns by hand; the determinism case.
- `graph_layout/stack_invariants.dart` `:216-256` and `:296-302`: the restated (C) (no split), I2 with need = u, branch checks over the grouped rows; `splitRuns` asserts 0 in `stacks_invariants_test.dart:81,88` (the split generator stays as a shape); `:112` drops the `order` echo.
- `graph_layout/stacks_invariants_test.dart`, `stacks_test.dart:30-43,305-324,630-633,659,698-699` (the split-run test becomes "a run's members share a column"; rows re-derived where columns moved), `golden_test.dart` (per mode; the joint oracle test `:88-105` and the budget-cut tests `:107-118` go; the 57f259c oracle compares rows and edge endpoints and kinds only; `:78` keeps the rows and drops the lane count), `grid_view_test.dart:19,42,101,151,170,196`, `input_builder_test.dart:43,386-388,424-426,442`, `router_test.dart:194-240,806`, `support/spec_json.dart:321-322`, `worker/graph_layout_test.dart` (`:97`, `:129-131`, `:226-271` delete the budget test, `:377-392`, `:407-439`, `:503-539`: the fixture parity per mode, delete the shared-lanes test).

**Goldens** `packages/zanshin_core/test/graph_layout/goldens/`: outputs renamed `<input>.<mode>.json`, regenerated; `design/design-*.budget-*.json` and `design/oracle/joint-design-*.lanes.json` deleted; `fuzz/expected.json`, `stacks/fuzz/expected.json`, `fixtures/hashes.json` keyed by `<mode>`.

**Tools** `spikes/graph-layout-ab/tools/goldens.mjs` (rewritten: Design Notes), `tools/record-graph.mjs` (`COMBOS`, `layoutOf`, the generated doc comments), `spikes/graph-layout-ab/README.md` `## Status` (a 4.17 item: the product no longer matches the reference; `compare.mjs --core` and the old goldens flow are history).

**App** `app/`: `lib/src/features/graph/graph_layout.dart:16-23,415,424,433-436,446,451`; `graph_ports.dart:26,40,72,86,98,1079-1082`; `graph_view_model.dart:256,363,645-652,1096`; `widgetbook/folders/graph.dart:128,167,219,307-319,338,382,412,640,741`; `widgetbook/folders/windows.dart:877`; `widgetbook/graph/graph_recordings.g.dart` and `graph_stack_recordings.g.dart` (regenerated); tests: `test/features/graph/` `backend_graph_layout_test.dart:164-186` (no column equality, keep the rest), `day_axis_test.dart:299-326` (only Free paints the axis; the width may differ), `graph_view_model_test.dart:48,345-347,1501`, `graph_metrics_test.dart:40`, `repo_graph_source_test.dart:57,87-95`, recording names everywhere `<input> <mode> <order>` → `<input> <mode>` (`graph_card_test`, `graph_controls_test`, `graph_gaps_test`, `graph_density_test`, `vertical_layout_test`, `day_axis_test`, `graph_viewport_test`, `recorded_graph_layout_test`, `graph_edges_test`, `graph_stacks_test:48`, `graph_anchor_test`), tests that pin a column re-derived from the new recordings.

**Lab** `spikes/graph-layout-lab/`: `lib/engine.dart` (`appGrid` and `labGrid` against the changed engine: `labGrid` calls `chooseColumns()` first for the visit order, then replaces lanes and `col`; a `labGridOf(input, stacks, …)` so golden inputs need no sidecar); `bin/lab_check.dart` (a product-equals-lab column check on every data set, both modes, with and without stacks; an optional second argument, the goldens directory, runs it on every golden input with and without its stack requests); `README.md` (one line for the new check). `lib/columns.dart` stays.

**Planning and tracking:** `epics.md` (dated notes: Story 4.14 `:4209` region I8, Epic 10 header `:8240`, 10.1 `:8614` and 10.12 `:10444` I8 notes, the `:8890`/`:8624` "same width / rows only" statements; a Delivered note under Story 4.17), `decisions-review-4-10-to-4-13.md` new `### 4.17`, `deferred-work.md` (only if anything is deferred), `sprint-status.yaml:75` (status value and `last_updated` only), `epic-4-context.md` last.

## Tasks & Acceptance

**Execution:**
- `docs/graph-layout.md` -- the dated amendments of the Code Map, from Design Notes and the rule above -- SPEC first.
- `packages/zanshin_core/lib/src/graph_layout/layout_engine.dart` -- `chooseColumns()` (the rule, typed arrays, `sortIndicesStable`, `LaneIntervals`), the removals of the Code Map -- the engine.
- `packages/zanshin_core/lib/src/graph_layout/compact_order.dart` -- delete -- it goes with the lane orders.
- `packages/zanshin_core/lib/src/graph_layout/stacks.dart` -- no split runs; the restated (C); sweep until (C) holds; `sweeps` -- stacks keep their guarantees on branch columns.
- `packages/zanshin_core/lib/src/graph_layout/{graph_grid_view,layout_request,layout_reply}.dart`, `packages/zanshin_core/lib/src/worker/{commands,isolate,handle}.dart`, `packages/zanshin_core/lib/zanshin_core.dart`, `docs/ffi-abi.md` -- remove `order` and `budget` -- the request has one column rule.
- `packages/zanshin_core/benchmark/{graph_layout_cli,router_cli}.dart` -- drop `--order`, the `ordering` phase and the JSON field -- the CLI records the goldens.
- `packages/zanshin_core/test/**` -- the Code Map's test changes and the matrix's cases -- the safety net; invariants and the naive column oracle run on every golden input and ≥ 1,000 seeded DAGs × both modes (and × stack states).
- `spikes/graph-layout-ab/tools/goldens.mjs`, `packages/zanshin_core/test/graph_layout/goldens/**` -- rewrite the tool per Design Notes, delete the retired files once, regenerate -- goldens from the product CLI.
- `spikes/graph-layout-ab/tools/record-graph.mjs`, `app/widgetbook/graph/graph_recordings.g.dart`, `app/widgetbook/graph/graph_stack_recordings.g.dart` -- recordings per mode, recorded again -- the view's fixtures.
- `app/lib/src/features/graph/{graph_layout,graph_ports,graph_view_model}.dart`, `app/widgetbook/folders/{graph,windows}.dart`, `app/test/**` -- remove the lane order; recording names; the two I8 tests; re-derive pinned columns -- the app follows.
- `spikes/graph-layout-lab/{lib/engine.dart,bin/lab_check.dart,README.md}` -- the lab builds and gains the product-equals-lab check -- the reference stays honest.
- `spikes/graph-layout-ab/README.md`, `_bmad-output/planning-artifacts/epics.md`, `_bmad-output/implementation-artifacts/{decisions-review-4-10-to-4-13.md,sprint-status.yaml,deferred-work.md,epic-4-context.md}` -- history, dated notes, decisions, tracking; `epic-4-context.md` last -- the documents stay true.
- Measurements and sightings per § Verification, recorded in this spec.

**Acceptance Criteria:**
- Given the finished tree, when `node spikes/graph-layout-ab/tools/goldens.mjs` and `record-graph.mjs` each run twice, then the second run changes nothing, and every golden test passes.
- Given `packages/zanshin_core`, when its tests run with the pinned environment, then every test passes, including the invariants and the naive column oracle on every golden input and ≥ 1,000 seeded DAGs × both modes and on the stack states.
- Given the app, when `flutter test` runs, then it is green and no code under `app/lib`, `app/widgetbook` or `packages/zanshin_core/lib` names `LaneOrder`, `laneOrder`, `GraphLaneOrder`, `defaultLaneOrder` or `defaultLayoutBudget`.
- Given `bin/lab_check.dart` with the lab's data and the goldens directory, when it runs, then the product's columns equal `chooseColumns`' on all three data sets and every golden input, both modes, with and without stacks, and it exits 0; the run is recorded here.
- Given the finished tree, when the AC greps run (`\.sort(` and static or top-level `final` in `lib/src/graph_layout`, types named `GraphLayout` / `GraphRef` in `packages/`, engine-core imports), then none has a hit, and `crates/`, `schemas/`, `coverage-baseline.txt` and the barrel's engine-type surface are unchanged apart from the removed `LaneOrder` exports.
- Given the catalogue and the real app on a replica of jj at `mnxzqvtl`, when the graph is shown in both modes, then the columns are the lab's for that repository, seen through Marionette.
- Given § Measurements, when read, then it holds the columns per input and the `lanes` phase time at large-10k and synth-100k against 4.14's 43 ms.

## Spec Change Log

## Review Triage Log

### 2026-11-10 — Review pass
- verdicts: 32 findings — high 0, medium 1, low 25, false 6, maybe-false 0
- findings:
  - `[low]` `[patch]` `handle.dart:212-213` still says the columns are joint and a mode switch moves only rows — rewritten: each mode chooses its own columns, so a switch can move a card sideways.
  - `[low]` `[patch]` "Lane order" wording survives in the app's view model and canvas, the catalogue, the stack recordings, the lab's `columns.dart`, the engine test group `lane packing` and the local `orderCode` — all reworded; the group is now `lanes and routes` and the local `retired`.
  - `[low]` `[patch]` The A/B spike README's Run section still shows `--order`, `compare.mjs --core` and the old golden steps — replaced by the new flow; `compare.mjs --core` is marked as history.
  - `[low]` `[patch]` "At most 2" sweeps reads as a bound, and the `stacks_test` header claims every expectation was derived by hand — GLD §4.8 and the decisions row now give the bound (n + 1) and the measurements (one to five sweeps); the header names the case a search found.
  - `[low]` `[patch]` `chooseColumns` is quadratic in the number of columns on very wide inputs (a star of 40,000 branches takes 2.47 s under the JIT, confirmed) — a `shortcut:` comment and a dated GLD §5 note; the algorithm stays, real histories take 6 ms at 100k nodes.
  - `[low]` `[patch]` A `straight` edge can pass cards, and a card on the merge child's row blocks a merge — both written down in GLD §4.3, Consequences.
  - `[false]` `[reject]` A redundant parent makes a branch change columns — the code equals the reference (`chainOf[child] != from[c]`, `lab_check` passes) and jj prunes transitive parents (D2); the misleading comment on `naiveBranchColumns` was corrected.
  - `[low]` `[patch]` The rewritten `epic-4-context.md` lost two standing rules (the barrel's exception for the router's types, the decisions-file rule) — restored.
  - `[low]` `[patch]` PRD FR-GR-1 and epics.md's lane-order statements still state the old behavior — dated notes added.
  - `[false]` `[reject]` Tracking says `done` before there is evidence — finalize sets the spec to `done` in the same commit, and the gate belongs to the loop by rule of this run; the basis in the decisions row was reworded.
  - `[low]` `[reject]` Test helpers have parameters that never vary — cosmetic; a refactor is more than a direct correction and no harm can be named.
  - `[low]` `[patch]` `layering()` computes the other mode's model, and GLD §2 gives the wrong reason — the §2 sentence is corrected; the second model stays, per Design Notes and the decisions table.
  - `[low]` `[patch]` Story numbers in comments this change rewrote — removed from `isolate.dart`, `engine_test.dart`, `golden_test.dart` and `invariants.dart`.
  - `[low]` `[patch]` `lab_check`: its doc says it stops at the first failure, a failure message shows only columns, and the count misses the stack layouts — doc, message and count fixed.
  - `[medium]` `[patch]` The row sweeps never end on columns that are not branch columns (the lab's reserve-to-merge-off variant with stacks; a probe showed `twms`, `dart-intellij` and `jj` in `free` still running after 12 s) — `_rows` now throws `StateError` when a value exceeds Y.
  - `[low]` `[patch]` `chPos` in the engine is dead — removed.
  - `[low]` `[patch]` `sortInt64Range` and `_mergeSortInt64` are dead — removed.
  - `[low]` `[patch]` The `handle.dart` doc (same root as the first row) — fixed there.
  - `[low]` `[patch]` Lane-order comments (same root as the second row) — fixed there.
  - `[low]` `[patch]` The spike README (same root as the third row) — fixed there.
  - `[low]` `[patch]` The deferred-work bullet on `compact`'s weaknesses is moot — marked RESOLVED.
  - `[low]` `[patch]` GLD says "Rows do not change", but grouped rows can, because (C) is restated — reworded.
  - `[low]` `[patch]` The naive column oracle does not run on stack-shaped DAGs — added to `_checkAll` in `stacks_invariants_test.dart`.
  - `[low]` `[defer]` The adjacent same-column merge is checked only as a router class, never as a line — the router is this story's non-goal; deferred to 4.18's line gate, the layer's filed disposition.
  - `[low]` `[defer]` Router B can double a line back over itself on that shape (13 of 1,737 same-column merge polylines step downward on seeded graphs, 0 in real inputs) — same root as the previous row; recorded in `deferred:` and `deferred-work.md`.
  - `[low]` `[reject]` Router B draws worse on the new columns until 4.18 (`twms` crossings 204 / 137 against 128 / 95 before, overlaps 4 / 24 unrecorded) — the story's non-goal, 4.18 follows in this loop, and the fix would edit this spec; the numbers are in the residual risks.
  - `[false]` `[reject]` No gate test runs on a real many-branch history — the story places `lab_check` outside the gate, and the lab's data must stay uncommitted.
  - `[false]` `[reject]` The goldens are self-produced — the story orders it; the hand cases, the naive oracle and `lab_check` are the independent witnesses.
  - `[false]` `[reject]` The mode switch is tested only with fakes — `setMode` is unchanged by this story (item 8).
  - `[low]` `[patch]` Grouped rows can change (same root as "Rows do not change") — fixed there.
  - `[low]` `[patch]` Prose leftovers on the lane order, layering and GLD §2 (same roots as above) — fixed there; `epic-10-context.md:47` stays, it is compiled again when stale.
  - `[false]` `[reject]` Tracking and the wide `epic-4-context.md` rewrite — the same claim as above on tracking; step-01 of this workflow compiles that file.
- notes: the review diff left out the golden JSON and JSONL files, the two `.g.dart` recordings, the deleted `compact_order.dart` and this spec (the spec went to the edge-case layer alone). The implementation subagent could not be re-engaged and awaited in the same turn, so this run applied the patches itself.

## Design Notes

**`chooseColumns()` in the engine.** Port of the lab's function at its defaults, in typed arrays: per branch `lo`, `hi`, `from`, `depth`, `elsewhere`, and the bottom card. A descending index scan numbers the branches (a parent's branch comes first, so `depth[from]` is known when computed). The order is three stable sorts of the branch numbers, least significant first, starting ascending by bottom card index: (y(bottom), priority(bottom)), then hi − lo, then hi, then depth (only the main branch has depth 0, so it comes first with no special key). Placement: `LaneIntervals(branches + 1)`; a branch's interval is the half-open [lo, hi + U): free ⇔ no overlap. Column 0 is reserved: the scan never returns it for another branch. `visitOrder` is computed here (`_visitOrder(y)`) and `_adoptLanes` builds the per-lane y lists; then `col = lane`. `chooseColumns` has no empty column and needs no renumbering: a new column index never exceeds the highest used so far + 1.

**`layering()` keeps both models.** The story lists what goes, and the second model is not on that list: the lab's `chooseColumns` reads `modelY` and `requestedModel` (its `same-columns` variant) and must keep working unchanged. The cost is one O(E) pass (Free) or one walk with its sort (Compact), a few ms at 100k.

**(C) restated.** Let S be below T in one column, u the top node of S, h the lowest of T. The rule gives lo(T) ≥ hi(S) + U with lo(T) = y(fp(h)) + U (or y(h) if h has no parent) and hi(S) = max(y(u), y(c) − U over S's merge edges to c). So on the grouped rows:
- h has a grouped parent t = fp′(h): y′(t) ≥ y′(u) (δ₁ = 0) and y′(t) ≥ y′(c) − U (δ₂ = −U).
- h has none: y′(h) ≥ y′(u) + U (δ₁ = U) and y′(h) ≥ y′(c) (δ₂ = 0).

(The old values were one pitch more: 2U / U and U / 0.) Y satisfies these, because Y(t) + U = lo(T) ≥ hi(S) + U; so y′ ≤ Y and the all-expanded layout equals the ungrouped one. A probe confirmed it on 24,012 layouts (the lab's columns on seeded stack graphs × states × modes, every run expanded and collapsed) and on the lab's three repositories: no failure of y′ ≤ Y, all expanded = ungrouped, or the one-pitch rule on the grouped rows.

δ₂ = −U can have its source above its target (Y(c) ≤ Y(t) + U), which the level-by-level sweep cannot honour in one pass. So `_rows` sweeps until every (C) constraint holds: `do { the groups loop } while (a (C) constraint is unmet)`; the groups loop is today's. Values only rise and stay ≤ Y, so it ends; the first sweep ignores unset sources exactly as today. Measured in the probe: mean 1.0004 sweeps, at most 2. `StackLayout.sweeps` exposes the count for the test.

**The (C) second-sweep case** (found by a search): `specStackGraph` with parents `[[Ind(1)], [Ind(2)], [null], [4], [7], [6, 9], [9], [8], [9], [10], [11], [17], [13], [Ind(14), Ind(17), 18], [15, 18], [16], [17], [null], [19], [Ind(20)], []]`, priority `[1,1,2,0,0,1,2,0,0,2,2,2,0,0,2,1,1,0,1,2,1]`, ts `[1790490087000, 1790490086000, 1790490086000, 1790490026000, 1790418026000, 1790418025000, 1790346025000, 1790346024000, 1790259624000, 1790014824000, 1790187204000, 1790187203000, 1790183603000, 1790097203000, 1790093603000, 1790090003000, 1790090002000, 1790090001000, 1790003601000, 1790003600000, null]`, counts `{13: 2}`, refs `{0, 16}`, self `4`, immutable `{15, …, 20}`, offset 120; request `collapsed` = every node. Compact: y `[2,1,0,7,6,5,4,5,4,3,2,1,5,4,3,2,1,0,2,1,0]`, col `[1,1,1,3,3,2,2,3,3,3,3,3,0,0,0,0,0,0,2,2,2]`; grouped rows `[2,1,0,6,5,5,4,-1,-1,3,-1,-1,5,4,3,2,1,0,2,1,0,4,1]`, sweeps 2.

**A merge child can share its parent's column** (the matrix row): the reservation ends one pitch below the child, so a branch starting at that child may take the column. The edge gets `route` = `straight` (lane(p) = lane(i)), which is what I3's restatement says. Router B does not read `route` (§14) and classes such an edge `gutter` by its column-free test (§14.2, s = 0, not the first parent).

**No run is split:** a run's links are node → its only child, which continues it (`cont`), so a run lies on one branch and its members share a column. `split`, its (C) case and D11 go.

**`goldens.mjs`** (rewritten): `dart compile exe packages/zanshin_core/benchmark/graph_layout_cli.dart -o spikes/graph-layout-ab/outputs/bin/graph_layout_core` once, then every output from that binary over the **committed** inputs (`design/design-<rev>.json`, `fixtures/{tiny-all,medium-narrow}.input.json`, `fuzz/cases.jsonl`, `stacks/design-<rev>.json`, `stacks/request-*.json`, `stacks/fuzz/cases.jsonl`), per mode, written as `<input>.<mode>.json`; `fixtures/hashes.json` keeps its input digest and metadata and holds per-`<mode>` digests of `medium-all` / `large-all`, whose inputs are the spike's `inputs/fixture-medium-all.json` and `fixture-large-all.json` (fail with a clear message when absent). It no longer deletes or rewrites inputs or oracles and no longer needs `fuzz.mjs`, `stacks.mjs`, `js_oracle.mjs` or `design-layout.mjs`. It writes `README.md` with the new steps. The retired output names and the budget and joint-oracle files are deleted once by hand (`git rm`).

**Verified on the lab's columns before implementing** (probes, not committed): the matrix's column arrays; router B on the recording inputs: `compact_lines_pass_behind_no_card…` and `free_lines_pass_behind_a_card_only_where_it_is_reported` conditions hold (no hits) and no collinear overlap on the ungrouped recordings.

## Verification

**Commands:**
- From the repository root: `cargo make --allow-private test-core` -- expected: every `packages/zanshin_core` test passes. In `packages/zanshin_core`: `dart analyze --fatal-infos --fatal-warnings`, `dart format --output=none --set-exit-if-changed .` -- expected: no issues, 0 changed.
- From the repository root: `cargo make test-app` (the app's whole suite) -- expected: pass. In `app/`: `dart analyze` and `dart format --output=none --set-exit-if-changed lib test widgetbook` -- expected: no issues, 0 changed.
- `node spikes/graph-layout-ab/tools/goldens.mjs` and `node spikes/graph-layout-ab/tools/record-graph.mjs`, each twice -- expected: exit 0, second run leaves `git status` unchanged.
- `dart --packages=.dart_tool/package_config.json run spikes/graph-layout-lab/bin/lab_check.dart spikes/graph-layout-lab/data packages/zanshin_core/test/graph_layout/goldens`, and `lab_metrics.dart spikes/graph-layout-lab/data` -- expected: exit 0; the column check passes on every data set and golden input; metrics recorded.
- Product CLI bench (`dart compile exe benchmark/graph_layout_cli.dart`, then `bench --mode free` and `--mode compact` on `spikes/graph-layout-ab/inputs/{fixture-medium-all,fixture-large-all,synth-10k,synth-100k}.json` and the lab's data sets) -- expected: per input the `lanes` count and the `lanes` phase time, recorded under § Measurements below.
- AC greps from the acceptance criteria -- expected: no hits; `git diff --stat crates/ schemas/ coverage-baseline.txt` empty.
- No `cargo make test`, `test-full`, `coverage` or `codegen` (gate rule of this run; no FFI change).

**Manual checks:**
- Catalogue through Marionette (`flutter run -d macos -t widgetbook/main.dart` from an absolute path in `app/`): the Graph use cases in Free and Compact with their columns as recorded, no "lane order" knob, no layout invariant failure.
- Real app on a temp home (`CFFIXED_USER_HOME=<temp>`, settings with `openProject` set to a replica of `../jj` built inside the scratchpad with the lab's `tools/make_replica.py` + `git fast-import` + `jj git init --colocate`, `JJ_CONFIG=spikes/graph-layout-lab/tools/jjconfig.toml`): at `mnxzqvtl` in both modes the columns are the lab's for that repository (compare with `lab_layout.dart` / `lab_check`'s data). Never open Ralph's own projects; press no config write in Settings.

**Record in this spec, at the end of this section:** a `### Measurements` heading (the columns per input and the `lanes` phase times against 4.14's 43 ms) and a `### Verification notes` heading (every command with its outcome, the sightings, and every regenerated golden and recording with its reason).

### Measurements

Product CLI compiled with `dart compile exe` (Dart 3.15.0-118.1.beta), `bench --mode free` and `--mode compact`, 31 runs after 10 warm-up runs (the defaults), median of the `lanes` phase. That phase is now `chooseColumns` alone.

| Input | Nodes | Columns Free | Columns Compact | `lanes` Free (ms) | `lanes` Compact (ms) |
|---|---|---|---|---|---|
| fixture-medium-all | 1,002 | 4 | 4 | 0.03 | 0.03 |
| fixture-large-all (large-10k) | 10,002 | 4 | 4 | 0.30 | 0.31 |
| synth-10k | 9,890 | 176 | 140 | 0.58 | 0.72 |
| synth-100k | 98,842 | 202 | 168 | 6.24 | 7.53 |
| lab `dart-intellij` | 4,672 | 11 | 11 | 0.20 | 0.19 |
| lab `jj` | 15,988 | 11 | 12 | 0.60 | 0.54 |
| lab `twms` | 1,622 | 11 | 10 | 0.07 | 0.07 |

At synth-100k the phase takes 6.24 ms (Free) and 7.53 ms (Compact). 4.14's joint packing took 43 ms there, so the phase is 5.7 to 6.9 times faster.

`lab_metrics.dart spikes/graph-layout-lab/data`, as it prints them:

| Data set | Mode | Stacks | Columns | Bends | Crossings | Siblings | Overlaps | Sideways | Behind | Nearer |
|---|---|---|---|---|---|---|---|---|---|---|
| `dart-intellij` | compact | yes | 11 | 1338 | 113 | 0 | 0 | 1119 | 0 | 48 |
| `dart-intellij` | free | yes | 11 | 1336 | 112 | 0 | 0 | 1168 | 0 | 99 |
| `dart-intellij` | compact | no | 11 | 1340 | 113 | 0 | 0 | 1119 | 0 | 31 |
| `dart-intellij` | free | no | 11 | 1338 | 112 | 0 | 0 | 1168 | 0 | 68 |
| `jj` | compact | yes | 12 | 544 | 2 | 0 | 0 | 407 | 0 | 0 |
| `jj` | free | yes | 11 | 544 | 22 | 0 | 0 | 418 | 0 | 28 |
| `jj` | compact | no | 12 | 544 | 10 | 0 | 0 | 407 | 0 | 0 |
| `jj` | free | no | 11 | 544 | 22 | 0 | 0 | 418 | 0 | 28 |
| `twms` | compact | yes | 10 | 690 | 154 | 0 | 0 | 770 | 0 | 21 |
| `twms` | free | yes | 11 | 702 | 166 | 0 | 0 | 826 | 0 | 37 |
| `twms` | compact | no | 10 | 704 | 158 | 0 | 1 | 770 | 0 | 6 |
| `twms` | free | no | 11 | 702 | 166 | 0 | 0 | 826 | 0 | 13 |

### Verification notes

**Commands, on the finished tree:**

| Command | Outcome |
|---|---|
| `cargo make --allow-private test-core` | exit 0, `+1176: All tests passed!`, including the invariants and the naive column oracle on every golden input, on ≥ 1,000 seeded DAGs × both modes, and on the stack states collapsed, expanded, default, random |
| in `packages/zanshin_core`: `dart analyze --fatal-infos --fatal-warnings` | no issues |
| in `packages/zanshin_core`: `dart format --output=none --set-exit-if-changed .` | 165 files, 0 changed |
| `cargo make test-app` | exit 0, `+2162: All tests passed!` |
| in `app/`: `dart analyze` | no issues |
| in `app/`: `dart format --output=none --set-exit-if-changed lib test widgetbook` | 287 files, 0 changed |
| in `spikes/graph-layout-lab`: `dart analyze`, `dart format` | no issues, 0 changed |
| `node spikes/graph-layout-ab/tools/goldens.mjs`, twice | exit 0; the second run left the checksums and `git status` unchanged |
| `node spikes/graph-layout-ab/tools/record-graph.mjs`, twice | exit 0; the second run left the checksums and `git status` unchanged |
| `lab_check.dart spikes/graph-layout-lab/data packages/zanshin_core/test/graph_layout/goldens` | exit 0; `dart-intellij`, `jj`, `twms` ok in both modes with and without stacks; `goldens: 332 layouts: ok` |
| `lab_metrics.dart spikes/graph-layout-lab/data` | exit 0; values under § Measurements |
| `.sort(` in `lib/src/graph_layout` | no hit |
| static or top-level `final` in `lib/src/graph_layout` | only `final class` declarations |
| types named `GraphLayout` / `GraphRef` in `packages/` | no hit |
| imports of the engine-core files | only `dart:typed_data`, `package:meta` and engine files |
| `LaneOrder`, `laneOrder`, `GraphLaneOrder`, `defaultLaneOrder`, `defaultLayoutBudget` under `app/lib`, `app/widgetbook`, `packages/zanshin_core/lib` | no hit |
| `git diff --stat crates/ schemas/ coverage-baseline.txt` | empty |
| `git diff packages/zanshin_core/lib/zanshin_core.dart` | only `LaneOrder`, `defaultLaneOrder` and `defaultLayoutBudget` leave the export list |
| `graph_layout_core layout --mode free --order greedy …` | exit 2, unknown flag `--order` |
| `router_cli check … --order greedy` | exit 2, unknown flag |
| goldens at `57e8043a` against the new ones (design-default, design-all, tiny-all, medium-narrow × both modes: rows, node rows, edge endpoints and kinds, buckets) | 32 comparisons, 0 differences: rows did not change |

`cargo make test`, `test-full`, `coverage` and `codegen` did not run (the gate rule of this run).

**After the review patches, on the finished tree, one command at a time:**

| Command | Outcome |
|---|---|
| `cargo make --allow-private test-core` | exit 0, `+1176: All tests passed!` (285 s); the naive column oracle now also runs on the stack-shaped DAGs |
| in `packages/zanshin_core`: `dart analyze --fatal-infos --fatal-warnings`, `dart format --output=none --set-exit-if-changed .` | no issues; 165 files, 0 changed |
| `cargo make test-app` | exit 0, `+2162: All tests passed!` (127 s) |
| in `app/`: `dart analyze`, `dart format --output=none --set-exit-if-changed lib test widgetbook` | no issues; 287 files, 0 changed |
| in `spikes/graph-layout-lab`: `dart analyze --fatal-infos --fatal-warnings`, `dart format` on `bin` and `lib` | no issues; 10 files, 0 changed |
| `goldens.mjs` and `record-graph.mjs`, each twice | exit 0; the checksums of all goldens and both recordings did not change, nor did `git status`, against the tree before the runs |
| `lab_check.dart spikes/graph-layout-lab/data packages/zanshin_core/test/graph_layout/goldens` | exit 0; all three data sets ok in both modes; `goldens: 464 layouts: ok` (the count now includes every stack request) |
| `lab_metrics.dart spikes/graph-layout-lab/data` | exit 0; the values under § Measurements |
| Product CLI bench, every input × both modes | the column counts under § Measurements; `lanes` within noise of them (synth-100k: 6.02 ms Free, 7.41 ms Compact) |
| AC greps: the lane-order names, `.sort(`, static or top-level `final`, `GraphLayout` / `GraphRef`, engine-core imports | no hit: `final class` declarations and one static method only; imports only `dart:typed_data` and engine files |
| `git diff --stat 57e8043a -- crates schemas coverage-baseline.txt` | empty |
| probe, not committed: seeded stack graphs of 600–3,600 nodes, every run collapsed, and the three lab repositories | 14,318 layouts took one to five sweeps; the stack invariants held on the 25 checked with three or more sweeps; the lab repositories took one; the guard in `_rows` never fired |

The manual checks were not repeated: the patches leave every golden and recording byte-identical, so the catalogue and the real app show what the sightings below show.

`app/test/features/window/window_zoom_test.dart` failed once while `dart analyze` and `dart format` ran alongside `cargo make test-app`, and passed on its own and in the quiet full run. This change does not touch it.

**Sightings through Marionette:**

- Catalogue, `graph/viewport/recording` and `graph/viewport/view-model`: no lane-order knob. Free and Compact on design-default show the recorded columns (Free: `ovknlmro` 0, `tnrkslqw` 1, `plkmnvxo` 0; Compact: `mrplxqwv` 2, `tzkvmrls` 2, `nqxwrptl` 2, `wlmpxokt` 1). No assertion or exception in the log.
- Real app on a temp home (`CFFIXED_USER_HOME` in the scratchpad, a colocated replica of `../jj` built there, `JJ_CONFIG=spikes/graph-layout-lab/tools/jjconfig.toml`), revset `all()`, at `mnxzqvtl` (`b7517027`). One column is 296 logical pixels. No exception in the log; no config write pressed; no other project opened.

| Change | Free in the app | Free in the lab | Compact in the app | Compact in the lab |
|---|---|---|---|---|
| `mnxzqvtl` | 0 | 0 | 0 | 0 |
| `qukptyss` | 0 | 0 | 0 | 0 |
| `xmqxqmxu` | 1 | 1 | 3 | 3 |
| `zpqkkquk` | 2 | 2 | 4 | 4 |
| `umtumsmo` | 3 | 3 | 5 | 5 |
| `yrkqpnxy` | 4 | 4 | 9 | 9 |
| stack `oxqwxxsw` | 5 | 5 | 11 | 11 |
| `ltoonrxz` | not read | 0 | 0 | 0 |
| `oloxsrzn` | not read | 6 | 2 | 2 |
| `@` (replica: `msspsluy`, lab data: `nuxplkws`) | not read | 10 | 1 | 1 |

**Goldens**, all under `packages/zanshin_core/test/graph_layout/goldens/` and written by `goldens.mjs` with the product CLI:

| Files | Change | Reason |
|---|---|---|
| `design/design-{default,all}.{free,compact}.json`, `fixtures/{tiny-all,medium-narrow}.{free,compact}.json`, `stacks/design-{default,all}.{default,expanded,mixed}.{free,compact}.json` (20) | new | columns by branch per mode, the new name `<input>.<mode>.json`, no `order` key; rows unchanged |
| `design/design-{default,all}.{free,compact}.{greedy,compact}.json`, `fixtures/{tiny-all,medium-narrow}.{free,compact}.{greedy,compact}.json`, `stacks/design-{default,all}.{default,expanded,mixed}.{free,compact}.{greedy,compact}.json` (40) | deleted once with `git rm` | the lane orders are gone |
| `design/design-default.compact.compact.budget-20.json`, `design/design-default.free.compact.budget-10.json` (2) | deleted once with `git rm` | the budget is gone |
| `design/oracle/joint-design-{all,default}.lanes.json` (2) | deleted once with `git rm` | the joint oracle retired |
| `fixtures/hashes.json` | regenerated | digests per mode on the new columns |
| `fuzz/expected.json`, `stacks/fuzz/expected.json` | regenerated | keyed by mode, on the new columns |
| `README.md` | regenerated | the new steps |

**Recordings**, written by `record-graph.mjs`: `app/widgetbook/graph/graph_recordings.g.dart` (8 recordings) and `app/widgetbook/graph/graph_stack_recordings.g.dart` (34). Reason: the new columns, and the names are `<input> <mode>` now that the lane order is gone.

**Tests with values derived again by hand:** `stacks_test.dart`, `compact_a_stack_sits…` (rows `[1, 3, 4, 4, 5]`: δ₁ = 0, so y′(t) ≥ y′(u) = 3) and `a_run_whose_newest_member…` (rows and the route: its stack head now shares a row with the child, so the edge is blocked). In `graph_edges_test.dart` the bridge case now picks a crossing of two solid edges with no other cut within 12 px, because the new columns move the crossings the old finder relied on.

One review finding was deferred: see `deferred:` in the frontmatter and `deferred-work.md` § "Surfaced in Story 4.17".

## Auto Run Result

**Summary.** The lab's column rule replaces the joint lane packing, the short-piece return, the closing pass and the lane orders in the product. A branch is a first-parent chain. The main branch is alone in column 0, a branch keeps one column for its whole life, and Free and Compact each choose their own columns, so invariant I8 is gone. `LaneOrder`, `order` and `budget` are gone from the engine to the view model; the grid format stays at versions 3 and 4 with header slot 2 always 0. Stacks keep their guarantees on branch columns: no run is split, §4.8's (C) is restated, and the row sweeps repeat until (C) holds. The goldens are written by the product CLI, the catalogue's recordings are recorded again, and `lab_check` proves the product equals the lab on its three repositories and every golden input.

**Files changed:**

| File | Change |
|---|---|
| `packages/zanshin_core/lib/src/graph_layout/layout_engine.dart` | `chooseColumns()` replaces the packing, the short-piece return and the orders |
| `packages/zanshin_core/lib/src/graph_layout/compact_order.dart` | deleted with the lane orders |
| `packages/zanshin_core/lib/src/graph_layout/stacks.dart` | no split runs, restated (C), sweeps until (C) holds, `StateError` above Y |
| `packages/zanshin_core/lib/src/graph_layout/sort.dart` | the unused `Int64` sort removed |
| `packages/zanshin_core/lib/src/graph_layout/{graph_grid_view,layout_input,layout_reply,layout_request}.dart` | `LaneOrder`, `order` and `budget` removed; header slot 2 must be 0 |
| `packages/zanshin_core/lib/src/worker/{commands,handle,isolate}.dart`, `packages/zanshin_core/lib/zanshin_core.dart` | the layout request has no lane order; the barrel follows |
| `packages/zanshin_core/benchmark/{graph_layout_cli,router_cli}.dart` | no `--order`, no `ordering` phase, no `order` field |
| `packages/zanshin_core/test/graph_layout/**`, `packages/zanshin_core/test/worker/graph_layout_test.dart` | hand cases, the naive column oracle, invariants restated for branch columns, regenerated goldens (68 files) |
| `app/lib/src/features/graph/{graph_canvas,graph_layout,graph_ports,graph_view_model}.dart` | the lane order leaves the view |
| `app/test/features/graph/**` | re-derived columns, the two I8 tests changed |
| `app/widgetbook/folders/{graph,windows}.dart`, `app/widgetbook/graph/**` | no lane-order knob, recordings per mode, recorded again |
| `docs/graph-layout.md`, `docs/ffi-abi.md` | the dated amendments of Story 4.17, new D15; no `order` in the request |
| `spikes/graph-layout-ab/tools/{goldens,record-graph}.mjs`, `spikes/graph-layout-ab/README.md` | goldens and recordings from the product CLI; the old references are history |
| `spikes/graph-layout-lab/{bin/lab_check.dart,lib/engine.dart,lib/columns.dart,README.md}` | the lab builds against the new engine; the product-equals-lab check |
| `_bmad-output/planning-artifacts/{epics,prd}.md`, `_bmad-output/implementation-artifacts/{decisions-review-4-10-to-4-13,deferred-work,epic-4-context}.md`, `sprint-status.yaml` | dated notes, decisions, tracking |

**Review findings.** 32 findings: high 0, medium 1, low 25, false 6, maybe-false 0.

- **Patched (22 rows, 17 entries):**
  - The row sweeps could run forever on columns that are not branch columns; `_rows` now throws above Y (medium).
  - Dead `chPos` and the unused `Int64` sort removed.
  - The naive column oracle now runs on stack-shaped DAGs.
  - Prose that stayed wrong: the `handle.dart` doc, lane-order wording in comments, the spike README, "at most 2" sweeps and the `stacks_test` header, "Rows do not change", GLD §2's reason, `straight` and `blocked` in GLD §4.3, the deferred-work bullet on `compact`, PRD FR-GR-1 and epics.md's notes, `epic-4-context.md`'s standing rules, story numbers in comments, the `lab_check` doc, message and count.
  - `chooseColumns` on very wide inputs: a `shortcut:` comment and a GLD §5 note, no algorithm change.
- **Deferred (2 rows, 1 entry):** router B can draw an adjacent same-column merge as a line that steps back over itself, and only 4.18's line gate would see it.
- **Rejected (8 rows):**
  - A redundant parent changes columns (`false`): the code equals the reference, and jj prunes transitive parents.
  - Tracking is `done` before evidence (`false`, twice, together with the wide `epic-4-context.md` rewrite): finalize sets it in the same commit, the gate is the loop's, and step-01 compiles that file.
  - Helpers with non-varying parameters (`low`): cosmetic, a refactor beyond a direct correction.
  - Router B on the new columns (`low`): the story's non-goal, 4.18 follows, and the fix would edit this spec.
  - No gate test on a real many-branch history (`false`): the story places `lab_check` outside the gate.
  - Self-produced goldens (`false`): the story orders them; the hand cases, the naive oracle and `lab_check` are the independent witnesses.
  - The mode switch is tested only with fakes (`false`): `setMode` is unchanged.

**Follow-up review recommendation:** `false`. Patched entries by verdict: high 0, medium 1, low 16. One medium is below the threshold of two.

**Verification.** See § Verification notes: both Dart suites, analyze and format for every touched package, goldens and recordings twice with unchanged checksums, `lab_check`, `lab_metrics`, the CLI bench, the AC greps, and the catalogue and the real app on a replica of jj through Marionette. `cargo make test`, `test-full`, `coverage` and `codegen` did not run, by the gate rule of this run.

**Residual risks:**

- Router B draws on the new columns until 4.18 lands. On `twms` it crosses 204 (Free) and 137 (Compact) times against 128 and 95 before, and lines overlap 4 and 24 times.
- The column phase is quadratic in the columns on very wide inputs (2.5 s under the JIT on an artificial star of 40,000 parallel branches; 6 ms on synth-100k).
- The full gate and the coverage ratchet have not run on this change; the story loop runs them at its end.
- `window_zoom_test.dart` is sensitive to parallel load (not caused by this change).
