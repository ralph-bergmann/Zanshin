---
title: 'Story 4.18: Lines by the lab''s rules — a line bends at its card, the lines of a card keep the order of their columns, no two lines lie on top of each other'
type: 'feature'
created: '2026-11-10'
status: 'in-review'
baseline_revision: '2459cc42435b8ff251bae28c597b555cd448c1c4'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-4-context.md'
  - '{project-root}/docs/graph-layout.md'
  - '{project-root}/spikes/graph-layout-lab/README.md'
  - '{project-root}/spikes/graph-layout-lab/lib/lines.dart'
warnings: ['oversized']
deferred: []
---

<intent-contract>

## Intent

**Problem:** Router B (4.15) follows the design export with later fixes. On real repositories it still draws lines on top of each other, two lines of one card that cross, lines behind a card in Free, and lines that leave a card in another order than their columns. Ralph approved the lab's line rules on 2026-11-10; the lines of a card turn in the order of their columns always, and an accepted exception is a lone line off the centre after the tie-break.

**Approach:** Dated GLD amendments first. Then the geometry stage of `router.dart` is rewritten as a port of `labLines` (`spikes/graph-layout-lab/lib/lines.dart`, every switch on) with indexes instead of the lab's scans. Router B's classes, gutter budget, unit rule and hooks go. `RouteMetrics`, `RouteGeometry.compute` and its arrays, `bridges()`, `routeSyncNodeLimit`, shared entries and the reports stay. The lab then checks the product's lines with its own rules.

## Boundaries & Constraints

**Always:**
- **The rules** are `labLines` with every switch on, plus the deviations in Design Notes (each deviation is needed by this story). Constants: lift = 0.4·gapY, clear = 8, track = 6.
  - A line runs in its branch's column: a fork line (to a first parent) turns right above its parent and climbs the child's column; a merge line climbs its parent's column and turns right below its child.
  - No line behind a card: before a card in its way it turns into the gutter next to that column and stays there up to its child. Lines that share a gutter over one stretch sit 6 px apart (0, +6, −6, …).
  - A free level: a horizontal run sits on a level that passes no card, as near to its usual place as it can, at least `clear` from every card.
  - Shared room: runs that pass side by side between the same cards take the order in which they do not cross, and share that room evenly.
  - Bend at the parent, no lines on top of each other, fewer crossings, column order always, a tight fan: as the lab's rule log.
  - Ports stay as GLD §14.3 has them since 10.30, with the full column tie-break (a loser at a fan slot moves one slot further out).
- **What stays:** `RouteMetrics`; `RouteGeometry.compute` and its arrays `pointStarts`, `points`, `portStarts`, `portXs`, the run indexes (`vertical…`, `horizontal…`); `bridges()` and `RouteBridges` (§14.4); `routeSyncNodeLimit` and where the router runs (§14.5); shared entries for hidden merges; the per-layout stage keeps the name `RouteClasses`, because a card-size change must not redo it (recorded by measurement).
- **What goes from router B:** `kinds`, `sides`, `gutters`, `gutterSteps`, `hookRows`, `directFallbacks`, `fallbackEdges`, `overfullGutters`, `overfullClusters`, `overfullEdges`, the unit rule, hooks, the budget of 9, the `free` parameter of `RouteClasses.compute`, and `router_cli oracle`.
- **The reports** (counted, never hidden): `behindCards` and `behindEdges` (a line that still passes behind a card), `sharedStretches` and `sharedEdges` (two lines that share a stretch of more than 1 px on one x or one y, not counting lines of one slot and lines on one fan-overflow port), `tightFans` (a fan with less than 2 px between its lines), `unsettledPorts`, `unavoidableCrossings`.
- A polyline has 2, 4, 6 or 8 points; every consumer reads the CSR. It starts on the parent's top edge and ends on the child's bottom edge; its y never rises (climbs without retracing).
- **Determinism and guardrails:** the result depends only on the inputs and the metrics, not on the window; flat typed arrays and CSR, no per-node objects or maps on hot paths; hand-written or `sort.dart` sorts with total keys, no `.sort(` in `lib/src/graph_layout`; no static or top-level `final` tunables; engine-core files import only `dart:typed_data`, `package:meta` and engine files.
- **Docs:** dated amendments of GLD (§14 rewritten as the story orders it); dated notes at Story 4.15 and at Epic 10's decision (a1); a `### 4.18` table in `decisions-review-4-10-to-4-13.md`.
- **Quality bar:** SPDX first line on new `.dart` / `.mjs` files; `///` docs on every public member; `dart analyze --fatal-infos --fatal-warnings` and `dart format` (page width 120) clean in every touched Dart package; scenario-named tests; no `skip:`; no timing assertions. New comments explain the why in plain language and name GLD sections, not story or ticket numbers.
- **Repo conventions:** fixtures are never regenerated; the spike's `inputs/`, `outputs/` and the lab's `data/` stay untracked; no new pub or npm dependency; `sprint-status.yaml` changes only the `4-18-…` and `epic-4` status values and `last_updated`; `epic-4-context.md` is edited last; every deferral goes to the spec's `deferred:` AND `deferred-work.md` § "Surfaced in Story 4.18 (bmad-build-auto, 2026-11-10)" in the shape the dispatch prescribes.
- **Gate rule of this run:** no `cargo make test`, `test-full` or `coverage`; verify with the targeted checks in § Verification and record every outcome.
- **Environment:** absolute paths in every command and never a bare `cd`; file edits with the Edit and Write tools, never `sed`, `perl`, `python` or heredocs through Bash; run every check to the end in the foreground; `jj` only in temp directories this run created; never open Ralph's own projects in the app (only `CFFIXED_USER_HOME` temp homes with replica repositories, and press no config write in Settings).

**Never:**
- No change to the painter's rules (yellow @ line, dashes, gap markers, end stubs, bridges, hover, dim), to columns or rows (4.17, 4.11), or to the bridge rule (§14.4).
- No other idea for the tight fan; no lines on both sides of the main branch; no bundles of lines in a gutter; no parity with GL's router (`router-oracle.mjs` stays in the spike as history).
- No Rust, FFI, schema or `coverage-baseline.txt` change; no type named `GraphLayout` or `GraphRef` in `packages/`; no new engine-type export in `lib/zanshin_core.dart` beyond the router's existing ones.
- No `git commit` by an implementation subagent unless the workflow's step orders it.

## I/O & Edge-Case Matrix

All values at W 240, H 62, gapX 56, gapY 48, pad 56, with unit 1 unless the row says otherwise; they follow from the rules above and were checked against `labLines` except where a row says "product only". Column centre cx(c) = 176 + 296·c; the gutter right of column c is at 324 + 296·c. Inputs are `rows`, `cols`, edges as (parent, child) in §3's order. A polyline is listed from the parent's end.

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| A line in a free column, also a non-first parent one row below its child (item I1) | `[1,0,0]`, `[0,1,0]`, `[(1,0),(2,0)]` | edge 1 has 2 points `(176,166)(176,118)`; edge 0 is `(472,166)(472,146.8)(200,146.8)(200,118)` | none |
| A card in the way (the gutter) | `[2,0,1]`, `[0,0,0]`, `[(1,0)]` | `(176,276)(176,247.2)(324,247.2)(324,137.2)(176,137.2)(176,118)` | none |
| A level that moves off a card (unit 16) | `[32,0,3]`, `[2,0,1]`, `[(1,0)]` | `(176,276)(176,236.175)(768,236.175)(768,118)` | none |
| Three runs that nest | `[1,1,1,0]`, `[1,2,3,0]`, `[(3,0),(3,1),(3,2)]` | exits 200 / 216 / 232, levels 146.8 / 152.8 / 158.8, ends at 472 / 768 / 1064, no crossing | none |
| A merge line that bends at its parent | `[3,2,1,0]`, `[0,1,2,0]`, `[(3,0),(2,1),(3,1)]` | edge 2 `(200,386)(200,366.8)(472,366.8)(472,228)`; edge 1 `(768,276)(768,256.8)(496,256.8)(496,228)`; edge 0 straight | none |
| An X between two neighbouring rows | `[1,1,0,0]`, `[0,1,1,0]`, `[(2,0),(3,1)]` | edge 0 `(448,166)(448,146.8)(176,146.8)(176,118)` (a lone line off the centre); edge 1 `(176,166)(176,152.8)(472,152.8)(472,118)`; one crossing, no shared stretch | none |
| The detour that saves a crossing | `[5,4,2,0,2,3]`, `[1,3,3,1,2,0]`, `[(3,0),(2,1),(3,1),(4,5)]` | edge 2 has 6 points `(496,606)(496,586.8)(916,586.8)(916,247.2)(1040,247.2)(1040,228)` | none |
| The detour that saves nothing | `[5,4,2,0]`, `[1,3,3,1]`, `[(3,0),(2,1),(3,1)]` | edge 2 keeps 4 points `(496,606)(496,247.2)(1040,247.2)(1040,228)` | none |
| The detour for the column order | `[5,4,2,0,1]`, `[1,3,3,1,2]`, `[(3,0),(2,1),(3,1),(3,4)]` | edge 2 `(512,606)(512,592.8)(916,592.8)(916,247.2)(1040,247.2)(1040,228)`; edge 3 `(496,606)(496,586.8)(768,586.8)(768,558)` | none |
| A fan of ten lines in one row gap | ten children in columns 1…10, row 1, one parent in column 0, row 0 | levels 120 + 4.6·k (k = 0…9), exits 200 + 26/3·k, `tightFans` 0 | none |
| A fan too tight for 2 px | 24 children likewise | `tightFans` 1; levels 1.9166… px apart; exits overflow onto 272 | none |
| A hidden merge's shared entry (product only) | `[2,0,1]`, `[0,1,2]`, `[(1,0),(2,0)]`, both Indirect, parentCounts `[1,0,0]` | slots `[0,0]`, deep `[1,1]`, one port at 176; edge 1 `(768,166)(768,154)(176,154)(176,118)`; edge 0 `(472,276)(472,256.8)(176,256.8)(176,118)` | none |
| The same without sharing (product only) | as above, parentCounts `[2,0,0]` | slots `[0,1]`, deep `[0,0]`, two ports; edge 1 `(768,166)(768,137.2)(200,137.2)(200,118)` | none |
| The full tie-break at a fan slot (product only) | `[5,5,4,2]`, `[0,1,1,0]`, `[(3,0),(2,0),(2,1),(3,1)]` | edge 1 `(448,166)(448,146.8)(216,146.8)(216,118)` (one slot further out); edge 3 `(200,386)(200,137.2)(448,137.2)(448,118)`; `unsettledPorts` 0 | none |
| A fork that dodges a card inside its child's column (8 points) | `[3,0,1]`, `[1,0,1]`, `[(1,0)]` | `(176,386)(176,366.8)(472,366.8)(472,357.2)(324,357.2)(324,137.2)(472,137.2)(472,118)` | none |
| A stretch the rules cannot avoid is reported (product only) | `[3,0,1,0]`, `[1,0,1,1]`, `[(1,0),(3,2)]` | edge 0 as in the row above; `sharedStretches` 1, `sharedEdges` `[1,1]` | none |
| A line behind a card is reported (unit 16; product only) | `[16,0,9]`, `[2,0,1]`, `[(1,0)]` | `(176,166)(176,146.8)(768,146.8)(768,118)`, `behindCards` 1, `behindEdges` `[1]` | none |
| Bad input | array lengths that disagree, unit ≤ 0, an edge out of range or at a hidden node, a visible node with a negative column | `ArgumentError`, as today | `ArgumentError` |
| An empty layout | n = 0 | empty arrays, all reports 0 | none |
| A card-width change | one `RouteClasses`, geometry at W 160 then W 400 | `identical` classes; the same arrays on a second run; different x's between the widths | none |

</intent-contract>

## Code Map

**SPEC** `docs/graph-layout.md`, dated "Amended 2026-11-10, Story 4.18" notes:
- a top note in the style of `:24-28`, listing §4.3, §4.8, §7.2, §9, §12, §14.
- §4.3 Consequences `:537-538`: a dated note that the router of §14 no longer classes such an edge (a free same-column line is straight).
- §4.8 `:1049-1053` and §9 D11 `:1496-1502`: a dated note that the kinds, `overfullGutters` and `fallbackEdges` these sentences name went with router B (the D11 case itself no longer applies since 4.17).
- §7.2 `:1268-1316`: a dated note that the router oracle retires (`router_cli oracle` is gone; `tools/router-oracle.mjs` stays as history); the reference is the lab.
- §12 `:1633-1635`: a dated note (§14's exits are now the lab's).
- §14 `:1772`: dated note at the top; §14.1 amended (no `free`, the per-layout stage); §14.2 and §14.3 rewritten from Design Notes (the story orders the rewrite; the previous text stays in git history); §14.4 unchanged; §14.5 new measurements and the new limit; §14.6 rewritten: the router no longer follows GL, and its differences from the lab are listed.

**Router** `packages/zanshin_core/lib/src/graph_layout/router.dart`:
- Header comment `:8-12` rewritten; constants `:19-65` reduced to what stays (`_entryFirst/Step/Min/Inset`, `_settlePasses`, `_crossMargin`, `_cutHalf`, `_clear` for bridges; new: `_lift` as a factor, `_cardClear = 8`, `_track = 6`).
- `RouteClasses` `:77-480`: keep the factory's validation `:126-188`, the column CSR and the in/out CSR `:167-208`, shared entries `:321-353`; remove the classifier call and its loop `:210-319`, `_Classifier` `:483-563` and the fields of § What goes; add `goesOn` (per node: a first-parent child sits in its column) and `columnPos` (per node: its index in `columnNodes`).
- `RouteMetrics` `:573-591` stays; its doc loses the unit-rule paragraph.
- `RouteGeometry` `:597-750`: doc (up to 8 points); the reports of § Always; `bridges` unchanged.
- `RouteBridges`, `_BridgeBuffer` `:755-811` unchanged.
- `_GeometryBuilder` `:814-1320`: keep `_positions` (`:881`), `_fan`, `_portFan`, `_place` `:974`, `_entries`, `_exits`, `_banCollisions` (adapted), `_ports` `:1142`, `_runIndexes` `:1215`; replace `_gutterXs`, `_reaches`, `_aboveY`, `build`, `_finish` per Design Notes.
- `_Runs` `:1323-1780`: replaced by the shape, detour and track phases of Design Notes.

**Benchmark** `packages/zanshin_core/benchmark/router_cli.dart`: the `oracle` command `:83-157` and `_kindNames` go; `_classes` `:176-185` loses `free`; `_check` `:187-261` prints point-count histogram and the new reports; `_bench` keeps its phases (`class` is the per-layout stage); the usage and header comment follow.

**Core tests** `packages/zanshin_core/test/graph_layout/`:
- `router_test.dart`: `_grid` loses `free` (it takes `unit`); `_trackY` stays; the `class stage` group becomes per-layout tests (`rejects_bad_input`, shared entries, `goesOn`); the `geometry stage` group gets the matrix's hand cases, and the kept tests re-derived by the rules (`nine_exits_…`, `story_10_30_…`, `ports_by_local_direction_…`, `entries_sit_…`, `a_mixed_side_…`, bridges, `per_window_bridges_…`, `a_card_size_change_…`, `hidden_members_…`); the `route gate` group becomes the line gate of Design Notes.
- `support/router_scan.dart`: `cardHits` stays; `overfullGutterEdges` goes; add `lineFailures(RouteGeometry g)` (the gate's checks, one message per failure) and `sharedStretchOracle(g)`.

**App** `app/lib/src/features/graph/`:
- `graph_edges.dart`: `_RouteInput` and `_routeInput`, `_classesOf` `:32-84` drop `free`; doc comments `:17`, `:88-93`, `:280-286` say "the router" (not "router B").
- `layout_invariants.dart` `:128-358`: `RouteReport` holds `behindCard`, `behindCardExplained`, `collinear`, `behindLines`, `sharedStretches`, `tightFans`, `gate`; `checkRouteLines` gains `reportedOverlaps` (per edge) and treats two lines reaching one child at one entry point as shared; `checkRoutes` reads `behindEdges` and `sharedEdges` instead of the gutter budget.
- `graph_gaps.dart:15,:193,:392,:737`, `graph_canvas.dart:79,:83`, `graph_minimap.dart:99`: "router B" wording only where it misleads.
- `app/test/features/graph/`: `layout_invariants_test.dart:144-240` follows the report (the `kindMergeUp` assertion and the fallback counts go); `graph_edges_test.dart`, `graph_gaps_test.dart`, `graph_view_test.dart`, `minimap_raster_test.dart`, `backend_graph_layout_test.dart`, `graph_real_repo_test.dart`: only where a pinned route changes.
- `app/widgetbook/graph/*.g.dart`: recorded again with `record-graph.mjs` (recordings hold no routes: expected no change).

**Lab** `spikes/graph-layout-lab/`: `lib/scene.dart` (`_appLines` → public `appLines`, no `free`; `LabLine` gets an optional `slot`), `bin/lab_check.dart` (`_lineFails` splits into a check over `(cards, lines)`, run on the lab's lines and on `appLines`; lines of one slot may share a port), `bin/lab_metrics.dart` (also prints the product's metrics), `README.md` (a Step 14 note: the rules live in the product; `App today` is that router; the leftover of step 13 is fixed).

**Spike history** `spikes/graph-layout-ab/README.md:93-96,:155-162` and the header of `tools/router-oracle.mjs`: one dated sentence each: the oracle retired with router B.

**Planning and tracking:** `epics.md` (a dated Delivered note under Story 4.15 `:4281` and Story 4.18 `:4515`; a dated note at decision (a1) `:8108`), `decisions-review-4-10-to-4-13.md` `### 4.18`, `deferred-work.md` (only if anything is deferred), `sprint-status.yaml:74,:76` (status values and `last_updated`), `epic-4-context.md` last.

## Tasks & Acceptance

**Execution:**
- `docs/graph-layout.md` -- the dated amendments of the Code Map, §14.2 and §14.3 written from Design Notes -- SPEC first.
- `packages/zanshin_core/lib/src/graph_layout/router.dart` -- trim `RouteClasses`, rewrite the geometry stage per Design Notes, new reports -- the rules.
- `packages/zanshin_core/benchmark/router_cli.dart` -- drop `oracle`, new `check` output -- the tool follows the reports.
- `packages/zanshin_core/test/graph_layout/{router_test.dart,support/router_scan.dart}` -- the matrix's hand cases, the re-derived tests, the line gate on every recording × W 160/240/400 × H 40/62 × both modes, and the climb check on `goldens/fuzz` (cases 0, 4, 18, 54 have the adjacent same-column merge in Compact) -- the safety net.
- `app/lib/src/features/graph/{graph_edges,layout_invariants}.dart`, wording in `graph_gaps`, `graph_canvas`, `graph_minimap` -- `free` goes, the report follows -- callers.
- `app/test/features/graph/*` -- `layout_invariants_test` and every pinned route, re-derived by hand -- the app's tests.
- `spikes/graph-layout-ab/tools/record-graph.mjs`, run -- expected to change nothing; a change is explained in the spec.
- `spikes/graph-layout-lab/{lib/scene.dart,bin/lab_check.dart,bin/lab_metrics.dart,README.md}` -- the product's lines through the lab's checks and metrics -- the reference stays honest.
- `packages/zanshin_core/lib/src/graph_layout/router.dart` -- `routeSyncNodeLimit` set from the timings; `docs/graph-layout.md` §14.5 and the spec's Measurements hold them -- the rule of §14.5.
- `spikes/graph-layout-ab/README.md`, `spikes/graph-layout-ab/tools/router-oracle.mjs` -- history notes.
- `_bmad-output/planning-artifacts/epics.md`, `_bmad-output/implementation-artifacts/{decisions-review-4-10-to-4-13.md,sprint-status.yaml,deferred-work.md,epic-4-context.md}` -- notes, decisions, tracking; `epic-4-context.md` last -- the documents stay true.
- Measurements and sightings per § Verification, recorded in this spec.

**Acceptance Criteria:**
- Given `packages/zanshin_core`, when its tests run with the pinned environment, then every test passes, including every matrix row and the line gate on every recording × W 160/240/400 × H 40/62 × both modes.
- Given the line gate, when it runs on a fuzz input with a merge between adjacent rows of one column, then every polyline climbs without retracing.
- Given per-window bridges on random grids, when compared with the all-pairs oracle, then they are equal, as today.
- Given the app, when `flutter test` runs, then it is green, and no code under `app/lib`, `app/widgetbook` or `packages/zanshin_core/lib` names `kindGutter`, `kindFork`, `kindMergeUp`, `kindStraight`, `kindMergeAdjacent`, `directFallbacks`, `fallbackEdges`, `overfullGutters`, `overfullClusters`, `overfullEdges`, `hookRows`, `gutterSteps` or `free:` on `RouteClasses.compute`.
- Given `bin/lab_check.dart` with the lab's data and the goldens directory, when it runs, then it exits 0 and its line rules pass on the product's lines on all three data sets, both modes, with and without stacks.
- Given `bin/lab_metrics.dart` with the product's lines, when it runs, then on the three data sets there are no lines on top of each other, none behind a card, no crossing of two lines of one card, and no more crossings than the lab's table below; a difference is explained in the spec.
- Given the AC greps (`\.sort(`, static or top-level `final`, `GraphLayout` / `GraphRef`, engine-core imports, `LaneOrder`), when run on the finished tree, then none has a hit; `crates/`, `schemas/`, `coverage-baseline.txt` are unchanged.
- Given § Measurements, when read, then it holds the bench per input and mode, the per-layout share, the derived `routeSyncNodeLimit` and every changed test value's reason.
- Given the catalogue (W 160 / 240 / 400, both modes) and the real app on lab replicas, when viewed through Marionette at jj's `pznposwy` and `mnxzqvtl` and at dart-intellij's `regexp: fix tests`, then the lines match the lab's page, and no exception is logged.

## Spec Change Log

## Review Triage Log

### 2026-11-10 — Review pass
- verdicts: 41 findings — high 0, medium 7, low 27, false 7, maybe-false 0
- findings:
  - `[medium]` `[patch]` The line gate cannot fail on a line behind a card: `lineFailures` only asks that a hit is flagged, and `_behind` flags every hit — confirmed by the layer's mutation evidence (rows 18, 22); the gate now also asserts `behindCards == 0` on every recording × size × mode.
  - `[low]` `[patch]` GLD §14.3's "Everything else the router cannot avoid is counted" promises more than the reports do — replaced by a *Limits* paragraph: the reports count what they name; the port order and same-card crossings are checked, not counted, and can break on dense random graphs.
  - `[low]` `[patch]` The tie-break text and the doc of `unsettledPorts` overclaim: only stretches at card edges are claimed — reworded in the code and in §14.3.
  - `[low]` `[patch]` The 6-point "fork that cannot enter" branch and `shapeRuns`' 8-point case run in no test — hand cases `a_fork_that_cannot_enter…` and `a_detour_counts_the_crossings_of_an_8_point_line`, both derived by hand (the second would tie without the 8-point case).
  - `[low]` `[patch]` No test exercises the monotone pass — hand case `a_line_the_tracks_leave_out_of_order_still_climbs` (the reduced grid of row 26); the child-side walk stays: the spec orders it, and a band of at most 4 px takes no clamp, so pushes can reach past the child.
  - `[low]` `[patch]` Two guards cannot fire (`q--` in `_belowRun`, the downward own-card loop in `_band`) — both deleted; the empty clause "not the parent" left §14.3's *under*.
  - `[low]` `[patch]` `routeSyncNodeLimit` bounds the wrong quantity for wide graphs — confirmed: 1,000 children of one parent cost 48 ms and 3,000 cost 431 ms (JIT), quadratic in the cluster; §14.5 and the `shortcut:` now say the limit assumes small clusters; a second limit is more than the story asks, which derives the limit by node count.
  - `[low]` `[patch]` The synthetic report test can barely fail — it now asserts `behindCard == 0`.
  - `[low]` `[patch]` The gate sweeps one density only — it now runs all six card height / gap pairs of the three densities.
  - `[low]` `[patch]` `router_scan.dart` cites a line gate §14.3 does not define — its comments now point at the `line gate` group of `router_test.dart`.
  - `[low]` `[patch]` §14.5's numbers do not match the measurement (7 % against 7–8 % and 24 %; "≤ 50 µs" and fixture-medium) — corrected.
  - `[low]` `[patch]` Old wording survived (`graph_gaps.dart:190-191`, `graph_edges.dart:103`, the lab README's "To carry over", the Story number in `router-oracle.mjs`) — all four fixed.
  - `[low]` `[patch]` `atChild` misleads at a line that bends at its parent — renamed `endsAtChild`.
  - `[low]` `[reject]` The new limit sends cheap real repositories (jj `all()`, 16k nodes, 3.8–4.5 ms) off the UI isolate — the limit is what the story's rule gives on its slowest series; a cost-based decision is more than a direct correction; recorded as a residual risk.
  - `[medium]` `[patch]` A straight non-owner of a shared slot: the owner lost the centre to it, so a hidden merge entered at two x's and `portXs` omitted one — reproduced with a hand case (ends at 448 and 472, ports [448]); a slot with a 2-point line now makes no entry claim; test `a_hidden_merge_with_a_straight_line…`.
  - `[low]` `[patch]` A non-owner of a shared slot never claims its stretch, so a long line's overlap goes unsettled — reproduced with a hand case (the shared stretch stays without the fix); every bending line of a slot now claims its stretch and a loss moves the owner; test `every_line_of_a_shared_slot…`.
  - `[low]` `[patch]` A wide layout under 7,000 nodes blocks the UI isolate — same root as the limit finding above; documented, the proposed column limit is not added.
  - `[medium]` `[patch]` A Compact line behind a card passes every test since the old gates went — same root as row 1; fixed there.
  - `[medium]` `[patch]` `i → [Ind(M1), Ind(F1)]` with parentCount 1 ends at 448 and 472 with ports [448] — same root as the straight non-owner above; fixed there.
  - `[low]` `[reject]` "Always" is not universal: `_place` has no column key and detours look only at a parent's top edge (10,550 card edges on 6,000 seeded geometries) — true, but the reference breaks it the same way (lab README step 12 states the limit), no real repository in the lab's data shows it and the gate holds on every recording; a fix would be a new rule, not a direct correction; §14.3's Limits now states it and the fuzz test pins how many.
  - `[false]` `[reject]` `deferred-work.md` keeps the open Story 4.18 follow-up — the dispatch forbids editing these bullets: the loop annotates them from `## Auto Run Result`.
  - `[medium]` `[patch]` The line gate cannot fail on a line behind a card — same root as row 1; fixed there.
  - `[medium]` `[patch]` The gate's inputs hold no gutter, detour or 8-point line — the fuzz test now pins ceilings at W 240 × H 62 (134 shared stretches, 30 behind a card, 152 column-order and 403 crossing messages; every other kind of failure 0).
  - `[low]` `[patch]` The app report exempts every overlap the router reports — pinned: `sharedStretches ≤ 435` (the synthetic layout) and `== 1` (the fork).
  - `[low]` `[patch]` The detour crossing count is only partly pinned — the fuzz ceiling catches the three mutations (134 → 139–144); `a_detour_counts_the_crossings_of_an_8_point_line` pins the 8-point path.
  - `[low]` `[patch]` Removing the monotone phase fails no test — same root as the monotone finding above; fixed there.
  - `[low]` `[patch]` Gutter slot reuse is no longer pinned — hand case `a_line_reuses_a_gutter_slot…`.
  - `[low]` `[patch]` Several §14.3 rule branches have no test — hand cases for the 6-point fork, a merge's run at its parent moving off a card, the zigzag guard and a detour's run moving off a card; `_above` at column centres and the ports of gutter lines are held by the fuzz ceilings.
  - `[low]` `[reject]` The router does not meet the "always" rules on the fuzz cases — same root as the "always" finding above.
  - `[low]` `[patch]` `syntheticLayout(10000)` has 435 shared stretches — same root as the app report finding; pinned there.
  - `[low]` `[patch]` Test titles "> 20k" and "≤ 20k" are stale — renamed to the sync limit.
  - `[false]` `[reject]` Real repositories are checked only by hand-run lab tools — the story places `lab_check` outside the gate, and the lab's data must stay uncommitted.
  - `[medium]` `[patch]` The gate's inputs lack the rules' shapes — same root as the fuzz ceilings row; fixed there.
  - `[low]` `[reject]` "Column order, always" is not universal and not reported — same root as the "always" finding above.
  - `[false]` `[reject]` "A line bends at its card" has no gate check — the story's gate lists none; `a_merge_line_bends_at_its_parent…` pins the rule.
  - `[false]` `[reject]` The exemption is "one port of one card edge", wider than the spec's "fan-overflow port" — two lines of one card edge share a port only on the fan's overflow (`_fan`) or in one slot, so the two sets are the same.
  - `[low]` `[patch]` The fuzz test does not assert that the corpus holds the adjacent same-column merge — it now counts such edges and expects at least one.
  - `[false]` `[reject]` No 8-point line reaches the painter, gaps or minimap in a test — they read the CSR with no fixed count (read in the diff, paths unchanged); no bad outcome.
  - `[low]` `[patch]` The 7,000 limit changes behaviour between 7k and 20k and the cache tests say 20k — the titles are renamed; the behaviour is the story's rule (see the limit rows above).
  - `[false]` `[reject]` The product compares with what the lab prints today, not README step 13's table — the story allows a difference explained in the spec, and the spec explains it.
  - `[false]` `[reject]` Status and `## Auto Run Result` are missing, the sightings are prose only — finalize writes them; the catalogue and real-app checks are manual by the story's witnesses.
- notes: the review diff left out this spec (it went to the edge-case layer alone). The implementation subagent could not be re-engaged and awaited in the same turn, so this run applied the patches itself. The router patches change no polyline on the recordings, the fuzz cases or the lab's data (672 geometries compared before and after).

## Design Notes

Reference: `labLines` with every switch on. Port its logic in the order it runs. Everything below is either a place the lab is silent or a deviation.

**Positions.** A doubled column position q is 2c for column c's centre and 2c + 1 for the gutter right of column c. Before ports every x is such a position. The track rules compare positions as integers. `gutter(col, side)` of the lab is 2·col + side.

**Phases of the geometry stage** (`_GeometryBuilder.build`):
1. Positions (x, y, cx per node).
2. Shapes: per edge its shape and levels, the lab's first loop. The runs of a shape are recorded per the table below. A merge line that has a detour also records that detour (edge, `at`, band, gutter).
3. Detours: taken when they save crossings, then for the column order (the lab's two passes, in edge order).
4. Tracks: runs of the final shapes; clusters, order, share, tight fan, pushes (the lab's `spread` block, literally, including `share[k] = min(tight[k], share[k])`, so two runs that are not of one fan keep at most 6 px).
5. Monotone levels (below).
6. Reaches, then ports: `_place` and `_banCollisions` until stable (at most 8 passes).
7. Gutter slots from the final levels.
8. Entry ports, polylines, run indexes, reports.

**The shapes and their runs.** ax, ay parent's exit x and top; bx, by child's centre x and bottom; xo, xi the ports; gx the gutter's x. `below` = by + lift. Every run takes part in the tracks.

| Points | Polyline | Runs (from the parent's end): band | merge | down → up |
|---|---|---|---|---|
| 2 | (xo,ay)(xo,by) | none | — | — |
| 4, fork | (xo,ay)(xo,L)(xi,L)(xi,by) | L: `band(c0,c1,L,upper,ay)` (no free level: around `above`) | false | ax → bx |
| 4, merge at child | same | L: `band(c0,c1,L,upper,lower)` | true | ax → bx |
| 4, merge at parent | same | L: `band(c0,c1,L,upper,lower)` | false | ax → bx |
| 4, merge fallback (no level, no card) | same | L = below: `band(c0,c1,below,by,lower)` | true | ax → bx |
| 6, same column or merge with a card in the parent's column | (xo,ay)(xo,T)(gx,T)(gx,B)(xi,B)(xi,by) | T: [card.y + h, ay]; B: `band(c0,c1,below,by,hi)` | true, true | ax → gx; gx → bx |
| 6, fork that cannot enter the child's column | (xo,ay)(xo,L)(gx,L)(gx,B)(xi,B)(xi,by) | L: as the fork's; B: as above | false, true | ax → gx; gx → bx |
| 6, detour | (xo,ay)(xo,at)(gx,at)(gx,B)(xi,B)(xi,by) | at: the lab's [lo, hi]; B: as above | false, true | ax → gx; gx → bx |
| 8, fork that dodges a card in its child's column | (xo,ay)(xo,L)(bx,L)(bx,T)(gx,T)(gx,B)(xi,B)(xi,by) | L: as the fork's; T: [card.y + h, ay]; B: as above | false, true, true | ax → bx; bx → gx; gx → bx |

`B`'s `hi` = the smallest of `under.y` (the next card below the child in its column, not the parent), `card.y + h` when the shape has a blocking card, and ay. `c0..c1` for a below-run are the columns strictly between the gutter and the child. T keeps the lab's turn when alone: T = card.y + h + lift.

**Deviations from `labLines`.**
1. **Every run is a track run** (the table above). The lab tracks only runs with a free level; that leaves `turn` and `below` runs on fixed levels (the leftover of README step 13 and a shared stretch wherever a below-run meets a merge run).
2. **`above(a, b)`** for two runs of different lines is the lab's, with `a.up == b.down` only when that position is even (a column centre): gutters are separated by slots, not by levels. Two runs of one line: the run nearer to the child lies above.
3. **Deep runs** (edges with `deep[k]`, the run that ends at the child): wish = max(lo + (hi − lo)/2, min(hi, lo + gapY) − 12), so a shared stem keeps its length; the lab has no shared entries. `unavoidableCrossings` counts pairs with `above(a, b) && above(b, a)`.
4. **Ports:** the engine's `_place` and `_banCollisions`, fed by the final levels. `reach` at an edge is the exact distance from the card edge to the line's first bend at that edge (infinite for 2 points). `toward` at the exit is the x of the third point (its usual target, `xi` for 4 points), at the entry the x of the point before the last vertical. The tie-break's stretches are exact: from the card edge to that first bend. The old exemption for two lines that both turn at their edges goes: an X between two neighbouring rows needs it gone. Bans and extra slots only accumulate, as today.
5. **Gutter slots** after tracks: the intervals are the final (upper level, lower level); sorted by gutter, then top, then edge index; a run takes the first slot free over its interval (only the last interval of a slot can overlap); slot s is at (s odd ? +6 : −6)·⌈s/2⌉ px from the gutter centre.
6. **Monotone levels:** after tracks, walk each line's levels from the parent's end (level = min(level, previous), starting at ay) and from the child's end (level = max(level, next), starting at by). So the line climbs without retracing, whatever pushes did. This settles item I1 of the dispatch: a line in a free column has 2 points, and the gate checks every polyline.
7. **Reports** as § Always. `behindEdges`: a final scan with the column CSR; a vertical run inside a card's x-range (inset 0.5) or a horizontal run across a card's y-range (inset 0.5), the card being neither end of the line. `sharedStretches`: the run indexes sorted by (x, top) and (y, left), adjacent overlaps > 1 px of different edges, not one slot and not one overflow port of one card edge; `sharedEdges` flags both lines. `tightFans` counts fans (siblings on one side of one card edge) with `tight < 2`, once per fan per cluster.

**Indexes instead of the lab's scans.**
- `blocker`, `under`, `seek`, `band`: binary search in the column's CSR (`columnNodes` by ascending row is descending y), plus `columnPos` for a card's own column. Own cards are skipped by stepping to the neighbour.
- Clusters: a sweep by band top with an active list (as router B's `_clusters`): the run joins every active run whose band still reaches it and whose x-range and level satisfy the lab's test. Within a cluster the lab's all-pairs loops stay; cluster sizes are ≤ 17 on synth-100k (measured with the lab's code), and a `shortcut:` comment names the upgrade.
- Detour crossings: per doubled position the sorted y's of the horizontal runs that strictly pass it and the sorted tops and bottoms of the vertical runs on it, built once from the first shapes; a query counts by binary search, and the taken detours (few) are applied as an overlay (`+` new shape, `−` old shape). The query subtracts the line's own runs. Measured with the lab's code on synth-100k: 316–668 candidates, of 107k lines, 2.3–4.1 s for all-pairs in the JIT.

**Per-layout stage.** Whether it remains is decided by measurement: `RouteClasses` keeps the inputs, the CSRs, slots, `goesOn`. A card-size change re-runs only the geometry (W scales x, H changes the room), so it stays, and the share of the per-layout stage is recorded under § Measurements.

**The line gate** (`lineFailures` in `support/router_scan.dart`), per geometry:
- Every polyline has right angles, starts on its parent's top edge and ends on its child's bottom edge, each at least 18 px from the card's corners, and its y never rises.
- Every `cardHits` hit is on a line with `behindEdges` set.
- At one card edge, two lines share a port only on the fan's overflow or as one shared entry.
- Two lines that both turn within gapY of one card edge never cross.
- The ports of a card edge, other than the centre, in x order go to non-decreasing columns.
- `sharedStretchOracle(g)` (all pairs, the report's definition) equals `g.sharedStretches`, and the recordings have 0.

The gate runs on `_recordings(mode)` × W 160/240/400 × H 40/62 × both modes. The fuzz cases (`goldens/fuzz/cases.jsonl`, all 100, both modes, W 240 H 62) run the right-angle, ends and climb checks.

**The lab's numbers to compare with** (`lab_metrics.dart`, 2026-11-10, per mode with and without stacks):

| Data set | compact, stacks | free, stacks | compact, no stacks | free, no stacks |
|---|---|---|---|---|
| dart-intellij crossings / siblings / overlaps / behind | 113 / 0 / 0 / 0 | 112 / 0 / 0 / 0 | 113 / 0 / 0 / 0 | 112 / 0 / 0 / 0 |
| jj | 2 / 0 / 0 / 0 | 22 / 0 / 0 / 0 | 10 / 0 / 0 / 0 | 22 / 0 / 0 / 0 |
| twms | 154 / 0 / 0 / 0 | 166 / 0 / 0 / 0 | 158 / 0 / 1 / 0 | 166 / 0 / 0 / 0 |

The product must not have more crossings than these, and 0 overlaps (the lab's leftover on `twms`), or the spec explains the difference. README step 13's own table (Free 112 / 22 / 166, Compact 113 / 1 / 152, Compact without stacks 113 / 10 / 158 + 1) predates the product's stack rules of 4.17; the table above is what the lab's code prints today.

## Verification

**Commands:**
- From the repository root: `cargo make --allow-private test-core` -- expected: every `packages/zanshin_core` test passes. In `packages/zanshin_core`: `dart analyze --fatal-infos --fatal-warnings`, `dart format --output=none --set-exit-if-changed .` -- expected: no issues, 0 changed.
- From the repository root: `cargo make test-app` -- expected: pass. In `app/`: `dart analyze` and `dart format --output=none --set-exit-if-changed lib test widgetbook` -- expected: no issues, 0 changed.
- In `spikes/graph-layout-lab`: `dart analyze --fatal-infos --fatal-warnings` and `dart format --output=none --set-exit-if-changed bin lib` -- expected: no issues, 0 changed.
- `dart --packages=.dart_tool/package_config.json run spikes/graph-layout-lab/bin/lab_check.dart spikes/graph-layout-lab/data packages/zanshin_core/test/graph_layout/goldens` and `lab_metrics.dart spikes/graph-layout-lab/data` -- expected: exit 0; the product passes the lab's line rules; metrics recorded.
- `node spikes/graph-layout-ab/tools/record-graph.mjs` -- expected: exit 0, `git status` shows the recordings unchanged.
- `dart compile exe packages/zanshin_core/benchmark/router_cli.dart -o <scratchpad>/router_cli`, then `bench --mode free` and `--mode compact --width 240 --height 62` on `spikes/graph-layout-ab/inputs/{fixture-large-all,synth-10k,synth-50k,synth-100k}.json` -- expected: per input the `class` and `geometry` medians, recorded under § Measurements; `routeSyncNodeLimit` = the largest n whose sum stays ≤ 8 ms, linear between sizes, rounded down to a thousand.
- AC greps from the acceptance criteria -- expected: no hits; `git diff --stat crates/ schemas/ coverage-baseline.txt` empty.
- No `cargo make test`, `test-full`, `coverage` or `codegen` (gate rule of this run; no FFI change).

**Manual checks:**
- Catalogue through Marionette (`flutter run -d macos -t widgetbook/main.dart` from an absolute path in `app/`), `graph/viewport/recording` at W 160 / 240 / 400 (the `card width` knob) in Free and Compact: lines end on their cards, no line behind a card, no exception in the log.
- Real app on a temp home (`CFFIXED_USER_HOME=<temp>`, settings with `openProject` set to a replica built with the lab's `tools/make_replica.py` + `git fast-import` + `jj git init --colocate` inside the scratchpad, `JJ_CONFIG=spikes/graph-layout-lab/tools/jjconfig.toml`): at jj's `pznposwy`, `mnxzqvtl` and at dart-intellij's `regexp: fix tests`, compared with the lab's page (`spikes/graph-layout-lab/bin/lab_server.dart`). Never open Ralph's own projects; press no config write in Settings.

**Record in this spec, at the end of this section:** a `### Measurements` heading (the bench per input and mode, the per-layout share, the derived limit against the old 20,000, the lab's numbers against the product's) and a `### Verification notes` heading (every command with its outcome, the sightings, every test value changed with its reason).

### Measurements

Bench of `packages/zanshin_core/benchmark/router_cli.dart`, AOT, warm (5 warm-up runs, 15 measured runs, medians), M4 Pro, W 240, H 62, 2026-11-10:

| Input | Mode | Nodes | Per-layout ms | Geometry ms | Sum ms | Per-layout share |
|---|---|---|---|---|---|---|
| fixture-large-all | free | 10,002 | 0.68 | 2.13 | 2.81 | 24 % |
| fixture-large-all | compact | 10,002 | 0.68 | 2.15 | 2.83 | 24 % |
| synth-10k | free | 9,890 | 0.79 | 10.03 | 10.82 | 7 % |
| synth-10k | compact | 9,890 | 0.78 | 9.10 | 9.88 | 8 % |
| synth-50k | free | 49,442 | 4.10 | 50.09 | 54.18 | 8 % |
| synth-50k | compact | 49,442 | 4.16 | 46.39 | 50.55 | 8 % |
| synth-100k | free | 98,842 | 8.83 | 111.26 | 120.09 | 7 % |
| synth-100k | compact | 98,842 | 9.17 | 98.87 | 108.04 | 8 % |

- **The per-layout stage stays.** It is 7–8 % of the sum on the synth inputs and 24 % on a mostly linear history; a card-size change keeps it and costs no layout request.
- **`routeSyncNodeLimit` = 7,000** (it was 20,000). The rule of GLD §14.5 on the slowest series, `free` on the synth inputs: 9,890 nodes cost 10.82 ms, so the largest n within 8 ms is 9,890 × 8 / 10.82 ≈ 7,310, rounded down to a thousand. Real shapes are cheaper: fixture-large-all costs 2.8 ms at 10k. The geometry rose because the rules now search columns and count detour crossings (a phase split on synth-10k: shapes 2.9 ms, detours 1.3, ports 2.5, reports and run indexes 2.5, tracks 0.2).
- A 1200 × 800 bridge window: at most 42 µs on these inputs.

The lab's numbers against the product's (`bin/lab_metrics.dart`, crossings / siblings / overlaps / behind, per data set and mode):

| Data set | | compact, stacks | free, stacks | compact, no stacks | free, no stacks |
|---|---|---|---|---|---|
| dart-intellij | lab | 113 / 0 / 0 / 0 | 112 / 0 / 0 / 0 | 113 / 0 / 0 / 0 | 112 / 0 / 0 / 0 |
| dart-intellij | product | 113 / 0 / 0 / 0 | 112 / 0 / 0 / 0 | 113 / 0 / 0 / 0 | 112 / 0 / 0 / 0 |
| jj | lab | 2 / 0 / 0 / 0 | 22 / 0 / 0 / 0 | 10 / 0 / 0 / 0 | 22 / 0 / 0 / 0 |
| jj | product | 2 / 0 / 0 / 0 | 22 / 0 / 0 / 0 | 10 / 0 / 0 / 0 | 22 / 0 / 0 / 0 |
| twms | lab | 154 / 0 / 0 / 0 | 166 / 0 / 0 / 0 | 158 / 0 / 1 / 0 | 166 / 0 / 0 / 0 |
| twms | product | 154 / 0 / 0 / 0 | 166 / 0 / 0 / 0 | 159 / 0 / 0 / 0 | 166 / 0 / 0 / 0 |

Bends, columns and the sideways count are equal too. The only difference is TWMS in Compact without stacks: the product has 159 crossings and no overlap, where the lab has 158 crossings and one overlap. That is the lab's step 13 leftover, a shared stretch that hides a crossing (README step 7); every run takes part in the tracks now, so the two lines cross.

### Verification notes

Commands, 2026-11-10 (pinned environment through the cargo-make tasks, absolute paths with `env -C`):

| Command | Outcome |
|---|---|
| `cargo make --allow-private test-core` | 1,174 tests, all pass |
| `dart analyze --fatal-infos --fatal-warnings` in `packages/zanshin_core`; `dart format --output=none --set-exit-if-changed .` | no issues, 0 changed |
| `cargo make test-app` | 2,164 tests, all pass |
| `dart analyze` in `app/`; `dart format --output=none --set-exit-if-changed lib test widgetbook` | no issues, 0 changed |
| `dart analyze --fatal-infos --fatal-warnings` and `dart format --output=none --set-exit-if-changed bin lib` in `spikes/graph-layout-lab` | no issues, 0 changed |
| `lab_check.dart spikes/graph-layout-lab/data packages/zanshin_core/test/graph_layout/goldens` | exit 0; product and lab lines pass the line rules on all three data sets, both modes, with and without stacks; goldens: 464 layouts ok |
| `lab_metrics.dart spikes/graph-layout-lab/data` | table above |
| `node spikes/graph-layout-ab/tools/record-graph.mjs` | exit 0, the recordings unchanged (`git status` clean for `app/widgetbook`) |
| `dart compile exe benchmark/router_cli.dart`, `bench` | table above; `check` on synth-10k free: 0 shared stretches, 0 unsettled ports, 95 lines behind a card, all 104 card hits reported (lanes wider than a mode can keep free on the synthetic input) |
| AC greps (`\.sort(` in `lib/src/graph_layout`, static or top-level `final` tunables, `GraphLayout`/`GraphRef` in `packages/`, engine-core imports, `LaneOrder`, the old router names, `free:` on `RouteClasses.compute`) | no hits; `git diff --stat crates/ schemas/ coverage-baseline.txt` empty |
| `cargo make test`, `test-full`, `coverage`, `codegen` | not run (gate rule of this run) |

Manual checks:

- **Catalogue** through Marionette under a temp home: `graph/viewport/recording`, recordings `design-all` and `design-default`, W 160, 240 and 400 in Free and Compact. Lines end on their cards, none passes behind a card, nested runs read in order. No exception in the log.
- **Real app** on replicas in the scratchpad under a temp home (`CFFIXED_USER_HOME`, `JJ_CONFIG` = the lab's `jjconfig.toml`; jj ran only in the two replicas; the source repositories were only read with `git log` and `git for-each-ref`; no config write in Settings): jj in Free at `pznposwy` and `mnxzqvtl` (`all()`, 15,991 changes, routed on another isolate above the new limit), dart-intellij in Compact at `regexp: fix tests`. In all three the fan leaves the card in column order, every line on its own track, and the picture matches the lab's page at the same card (Lab mode, its own defaults). The only exceptions in the app log are service-extension errors of Marionette calls that found no focused field or a window key that did not exist, none from the app.

Test values changed, each with its reason:

- `router_test.dart`: the class stage's kinds, gutters, unit rule, hooks and overfull reports went with router B (GLD §14.2 rewritten), so those tests are gone or became shape tests. Every matrix row has a hand case. Kept tests with the same expected values: nine exits, the 10.30 ports (renamed for the scenario), the entries fan, the mixed side, the tie-break at a fan slot, the crossings and bridges, the window test. A same-column second parent right below its child is now straight (2 points, centre; the first parent dodges through the gutter with 8 points, at +24): a merge line in a free column is straight, item I1. The deep run of a hidden merge is now 154 (it was the far end of a free part): GLD §14.3's wish. The fan-too-tight case pins the 2 px band clamp of the outermost run, so its first gap is 1.83 px and the other 22 gaps 46/24, as the matrix says "1.9166… px apart".
- `engine_test.dart`: the merge child's edge in its merge parent's column is now straight (2 points); it was a gutter line (GLD §4.3, amended).
- `app/test/features/graph/layout_invariants_test.dart`: the report's fields follow (`behindLines`, `sharedStretches`, `tightFans` instead of the fallback and overfull counts); a line pushed behind a card replaces the 9-line budget case; an overlap reported for both lines passes, for one line it fails; two lines reaching one child at one entry point are shared; the fork over a lower card keeps its check without the `kindMergeUp` assertion.
- `graph_edges_test.dart`, `graph_gaps_test.dart`, `layout_invariants_test.dart`: their sync helpers compute both stages directly, because a 10k synthetic layout is above the new limit (these tests look at the lines, not at where they are computed). No pinned route in the app's tests changed.

### Verification after the review patches

The same commands, re-run on the patched tree, one at a time (no `cargo make test`, `test-full`, `coverage` or `codegen`, by the gate rule of this run):

| Command | Outcome |
|---|---|
| `cargo make --allow-private test-core` | 1,183 tests, all pass (nine new hand cases; the gate with the densities and the fuzz ceilings) |
| `dart analyze --fatal-infos --fatal-warnings` and `dart format --output=none --set-exit-if-changed .` in `packages/zanshin_core` | no issues; 165 files, 0 changed |
| `cargo make test-app` | 2,164 tests, all pass |
| `dart analyze` and `dart format --output=none --set-exit-if-changed lib test widgetbook` in `app/` | no issues; 287 files, 0 changed |
| `dart analyze --fatal-infos --fatal-warnings` and `dart format --output=none --set-exit-if-changed bin lib` in `spikes/graph-layout-lab` | no issues; 10 files, 0 changed |
| `lab_check.dart spikes/graph-layout-lab/data packages/zanshin_core/test/graph_layout/goldens` | exit 0; product and lab pass on all three data sets, both modes, with and without stacks; goldens: 464 layouts ok |
| `lab_metrics.dart spikes/graph-layout-lab/data` | exit 0; the product's numbers are the table under § Measurements |
| `node spikes/graph-layout-ab/tools/record-graph.mjs` | exit 0; the recordings unchanged |
| `router_cli bench`, compiled again | synth-10k free 10.4 ms, fixture-large-all free 2.6 ms: the limit stays 7,000 |
| AC greps | no hits; `git diff --stat` of `crates/`, `schemas/`, `coverage-baseline.txt` and the barrel is empty |
| Before and after the review patches, the router's polylines on the recordings, the 100 fuzz cases and the lab's three data sets × both modes × W 160 / 240 / 400 | 672 geometries, 0 differences (2,090 Indirect edges among them): the patches change only the shared-slot cases their hand cases pin |

The manual checks were not repeated: the patches leave the lines of every recording and repository byte-identical, so the catalogue and the real app show what the sightings above show.
