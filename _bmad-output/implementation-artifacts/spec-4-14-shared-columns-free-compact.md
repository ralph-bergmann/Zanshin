---
title: 'Story 4.14: Shared columns — one lane packing and column order for Free and Compact'
type: 'feature'
created: '2026-10-27'
status: 'done'
baseline_revision: '569037fd07dde7bcdc2ab61bbe4188926834c4fe'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-4-context.md'
  - '{project-root}/docs/graph-layout.md'
  - '{project-root}/_bmad-output/implementation-artifacts/spec-4-13-commit-stacks-layout-engine.md'
warnings: ['oversized']
deferred:
  - summary: >-
      The node day key is the day of the clamped T, not of the commit's own timestamp, which the
      design's Compact label reads.
    evidence: |-
      nodeDays = dk(T(i)), T(i) = max(own ts, parents' T), matching Free's day buckets (GLD §4.2
      free); a non-root node without a ts gets tmin's day. The design's Compact label uses the raw
      Date.parse(c.ts) and shows nothing without a ts (graph-view.jsx@e74ced3:440-446). They differ
      for a commit older than an ancestor and for a node without a ts. Story 10.16 decides which it
      labels. Mirrored in deferred-work.md "Surfaced in Story 4.14".
    location: >-
      packages/zanshin_core/lib/src/graph_layout/layout_engine.dart (nodeDays)
    severity: low
---

<intent-contract>

## Intent

**Problem:** The layout engine packs lanes and orders columns per mode (§4.3 visits by the requested mode's y, §4.7 exchanges on that mode's rows), so every Free ↔ Compact switch can change the graph's width and column order. The design export `e74ced3` shares one set of columns between both layouts (SYNC #8; GL:463-575): a switch only moves cards up and down. Three ledger items name this story: I1 (the spike's design-input tool cannot read `e74ced3`), I2 (the joint packing may widen the graph — unmeasured), I3 (Compact's minimap labels need a local day per node).

**Approach:** SPEC first (dated GLD amendments), then the spike's Dart reference behind a Dart-only `--columns joint` flag, its tools (a loader that evaluates `graph-layout.jsx` whole, the design oracle, joint goldens, the recorder), then the product engine: every request lays out both vertical models, packs lanes once for both (a lane is shared only when its intervals are disjoint in both models), runs the lane orders on that joint packing, and outputs the requested mode's rows with identical lanes and columns. The worker loads timestamps for every request; the grid gains a per-node local day key.

## Boundaries & Constraints

**Always:**
- **Joint packing (§4.3, amended).** Every request computes compact y (U = 1) and free y (U = 16). A node's §4.3 interval [a, b) is computed in each model in that model's units (cont, Ey, the one-pitch buffer as today). A node fits lane ℓ iff, in each model, its interval is disjoint from every interval in ℓ except the excluded owner; the continuation rule is unchanged (cont(fp(i)) = i and it fits lane(fp(i)) excepting fp's own intervals). First fit = the least lane fitting in both models (an unused lane always fits). Pack twice — visiting by (y_c, priority, i) and by (y_f, priority, i) — and keep the packing with fewer lanes; compact wins a tie. The packing does not depend on the requested mode.
- **Lane orders on the joint packing.** greedy: col = lane. `compact` (§4.7, amended): segments = straight chains of the joint packing, a reservation per model; windows = connected components of the two columns' segments under "reservations overlap in either model", visited by their least compact reservation start; an exchange stays iff the joint cost falls; joint cost = 16·cost_compact + cost_free (each the §4.7 cost with its own U, tick model, routes and `blocked`: the per-pitch sum, scaled to stay integer); κ, reach, rounds, budget unchanged; the skip test runs per model (a window is skipped only if its span meets no kept exchange in either model); trunk column fixed; empty columns dropped. The work units are defined in §4.7's amendment and are the same in the spike and the product.
- **Output.** Rows, `blocked`, routes and buckets are the requested mode's; `lane`, `col` and `lanes` are identical in both modes (I8). Stacks (§4.8) run unchanged on the joint ungrouped columns with the requested mode's rows; the `free`-only constraint (F) and the day buckets stay `free`-only.
- **Day key per node (I3).** dk(i) = §4.2 free step 4's day key of the clamped T(i) at `utc_offset_min`, for every non-root node in both modes; the root has none; a stack node has its newest member's. It is a product-grid field (a new int64 node array, grid format versions 3 / 4), not part of §3's JSON, so no golden carries it.
- **Same code twice.** The spike's Dart reference (with `--columns joint`) and the product engine produce the same §3 output byte for byte; the product goldens are all regenerated from the spike's Dart binary with `--columns joint`, both orders. The spike's per-mode behaviour stays the default (`--columns mode`), so Rust ≡ Dart, `fuzz.mjs`, `bench.mjs`, `js_oracle.mjs` keep working unchanged.
- **Engine guardrails** (as 4.11/4.13): integers only, deterministic, flat typed arrays, no per-node objects or maps on hot paths, no `.sort(` in `lib/src/graph_layout`, no static/top-level `final` tunables; engine-core imports only `dart:typed_data`, `package:meta` and engine files. Contract violations stay V1–V5.
- **Quality bar:** SPDX first line on new `.dart`/`.mjs` files; `///` docs on every public member; `dart analyze --fatal-infos --fatal-warnings` + `dart format` (page width 120) clean in every touched Dart package; scenario-named tests; no `skip:`; no timing assertions.
- **Repo conventions:** fixtures never regenerated; the spike's `inputs/`/`outputs/` stay untracked; no new pub/npm dependency; `sprint-status.yaml` — only the `4-14-…` status value + `last_updated`; `epic-4-context.md` edited last; every deferral goes to the spec's `deferred:` AND `deferred-work.md` § "Surfaced in Story 4.14 (bmad-build-auto, 2026-10-27)" (the extra rule of this run).
- **Gate rule of this run:** no `cargo make test`/`test-full`/`coverage`; verify with the targeted checks in § Verification and record them.

**Never:**
- No port of the export's whole-lane optimizer, exact colouring or router-judged packing choice — except exact colouring, and only if § Measurements meets the threshold in Design Notes (I2).
- No route geometry (4.15); no lane-order control; no change to the spike's Rust reference or its dumper; no Rust, FFI, schema or `coverage-baseline.txt` change; no `lib/zanshin_core.dart` barrel export; no type named `GraphLayout` or `GraphRef` in `packages/`; no UI code (the recorder's generated `app/widgetbook/graph/graph_recordings.g.dart` is the only `app/` file that may change).
- No read of the live design folder (always `git show <rev>:…` via `tools/design-source.mjs`); no edit of accepted SPEC text (dated amendments only); no `jj` in this repo or any existing repo.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Columns across modes (I8) | any input × order × stacks off / any stack state | `lane`, `col`, `lanes`, hidden −1 positions identical in the compact and the free output | — |
| Joint conflict | two chains disjoint in compact y but overlapping in free y (or the reverse) | they get different lanes, in both outputs | — |
| Visit-order choice | input where free-order packing needs fewer lanes than compact-order packing; and a tie | the fewer-lane packing; on a tie the compact-order one | — |
| Single model reduction | input whose compact and free intervals nest identically (one chain) | same lanes as per-mode greedy | — |
| Compact order | any input | joint cost (16·c_c + c_f) ≤ joint greedy's; trunk column fixed; no empty column; routes per mode = what §4.4/§4.5 give on the new lanes | — |
| No timestamps | compact request, every `hasTs` 0 | free model = tmin clamp only (one pitch per edge); still valid, I8 holds | — |
| Day key | non-root node / root / stack node / hidden member | dk(T(i)) / `GraphGridView.noDay` / dk(T(m_k)) / its own dk(T(i)) — same in both modes | — |
| Grid decode | version 3 / 4 buffer; version 1, 2 or 5 | read with `nodeDays`; anything else `FormatException` | `FormatException` |
| Worker | real cdylib, compact and free request on one repo | identical lane and col arrays; `topology.hasTimestamps` true for both | — |
| Spike CLI | `--columns joint` / `mode` / absent / bad value; Rust binary with `--columns` | joint / per-mode / per-mode / exit 2; exit 2 (unknown flag) | exit 2 |
| Design loader (I1) | `node tools/design-input.mjs --rev e74ced3` | writes `inputs/design-e74ced3-{default,all}.json`, byte-identical to the `e243dd2` inputs (GD unchanged) | throws if a substitution target is missing |
| Design oracle | `e243dd2` sample, both revsets | joint greedy lanes = the fewer of GL's two greedy candidates (GL with exact colouring disabled); on a mismatch re-derive by hand before changing code | `tools/design-layout.mjs` exits 1 on a mismatch |

</intent-contract>

## Code Map

**SPEC** — `docs/graph-layout.md` (dated amendments, "Amended 2026-10-27, Story 4.14"):
- Top note `:3-11`: list Story 4.14's amendments (§2, §3, §4.2, §4.3, §4.7, §4.8, §6, §7.2, §7.3, §13).
- §2 `:85-92`: `ts_ms` and `utc_offset_min` are read by both models with joint columns (`--columns joint`; the product always).
- §3 `:204-226`: `lane`/`col`/`lanes` with joint columns are mode-independent; the per-node day key is a product-grid field only.
- §4.2 step 4 `:322-335`: dk per node in both modes (product grid).
- §4.3 `:337-379`: Design Notes § Joint packing (rule, visit-order choice, bound, why the visited model still needs only the max-b test).
- §4.7 `:509-601`: Design Notes § Joint `compact` order.
- §4.8 `:603-772`: runs on the joint ungrouped columns; termination argument's "disjoint reservations" holds per model; recount the `e243dd2` hand-derived compaction if it changes (re-derive by hand).
- §6 `:792-830`: Dart-only `--columns mode|joint` (layout + bench; default `mode`); Rust: unknown flag.
- §7.2 `:848-895`: the `e74ced3` loader + the joint design oracle.
- §7.3 `:897-929`: I8; I1–I7 in both modes on the joint columns.
- §13 `:1147-1229`: product = joint always; timestamps for every request; grid v3/v4 with `node day`; `GraphGridView.noDay`.

**Spike Dart reference** (`spikes/graph-layout-ab/dart/`):
- `lib/src/layout.dart` — `computeLayout` `:141-164` gains `bool joint = false`; `GraphLayout` `:167-753`: with joint, also lay out the other model (compact y via `_layerCompact` logic, free y/T via `_layerFree` logic) without touching `freeOrder`/`freeT`/buckets of the requested mode; `packLanes` `:468-562` → joint packing (two passes, per-lane ordered interval lists for the non-visited model, segment-tree "least lane ≥ start with max b ≤ a"); `markBlocked`/`route` `:588-628` also for the other model (kept for the compact order); `orderLanes` `:630` passes both models to `compactColumns`. Without joint: unchanged.
- `lib/src/compact_order.dart` — a per-model geometry (`_segments` `:143`, `_geometry` `:193`, `localCost` `:367`, `mAt`), joint windows/cost/skip/`_place` (`_swapRound` `:418`, `_place` `:486`); with one model it must stay the current algorithm byte for byte (the per-mode default).
- `lib/src/output.dart` — unchanged (no day in JSON).
- `bin/graph_layout.dart` — `--columns` in `_Cli.parse` allowed set `:180`, ctor/fields `:159`/`:203-213`, both `computeLayout` calls `:50`/`:91`, usage `:7-12`; `bench` echoes `"columns"` only with joint.
- `test/layout_test.dart` — a `joint` group: a literal two-model interval scan == the packing on random graphs, I8 on random graphs × orders, the hand-built conflict case, `--columns mode` == today.

**Spike tools** (`spikes/graph-layout-ab/tools/`):
- `design-layout.mjs` (NEW, I1) — `loadLayout(commit, {exact = true})`: evaluates `graph-data.js` + `graph-layout.jsx` whole in a `vm` context (`window = globalThis`, TZ=UTC; `window.revsetMatch` = LSH:54's stub `(id) => id === "all" ? () => true : (c) => !!c.inDefault`; `window.placeGapMarkers = () => []`); `exact: false` replaces the one `exact()` candidate line (GL:525) by a checked string substitution (throws if absent). CLI `node tools/design-layout.mjs [--rev e74ced3]`: per revset GL's lane count without exact (= the fewer greedy candidate) and with exact, vs the Dart binary's `layout --columns joint --order greedy` lanes on `inputs/design-e243dd2-<rev>.json`; writes `outputs/oracle/joint-design-<rev>.lanes.json`; exit 1 on a mismatch.
- `design-input.mjs` `:52-64` — `loadDesign`: if `graph-view.jsx` has no top-level `function computeLayout(`, take `computeLayout` from `loadLayout(commit)` (so `--rev e74ced3` works; I1).
- `goldens.mjs` — every product output from the Dart binary with `--columns joint` (both orders; `layout()` `:77`, BIN `:28`); copy the two `joint-design-*.lanes.json` into `design/oracle/`; README text `:221-271` rewritten for joint.
- `compare.mjs` `--core` `:277-320` — reference = Dart `--columns joint` for both orders.
- `record-graph.mjs` — re-run only (it uses the product CLI, which is now joint); its output `app/widgetbook/graph/graph_recordings.g.dart` is committed.
- `../README.md` — `## Status` item 11 (Story 4.14), `## Run` gains `node tools/design-layout.mjs` before `goldens.mjs`.

**Product engine** (`packages/zanshin_core/lib/src/graph_layout/`):
- `layout_engine.dart` — `LayoutEngine` `:102-626`: lay out both models (requested `y`, plus `yCompact`/`yFree` or an "other" y; `freeOrder`/`freeT` stay null in `compact`, so `stacks.dart`'s (F) and buckets stay `free`-only); keep the clamped T for the day key; `packLanes` `:393-498` = the joint packing (port of the spike); per-model `blocked`/`routes` for the compact order; `visitOrder`/`laneYs` stay the requested mode's; `toGrid` `:596` passes `nodeDays`.
- `compact_order.dart` — the joint search (port of the spike).
- `stacks.dart` — `toGrid` `:721-743`: `nodeDays` with n + S entries (stack node = m_k's).
- `graph_grid_view.dart` — format versions 3 (35 header slots, 13 arrays, 13th = node day int64 × (n + S)) and 4 (48 slots: v3's + stacks at 35–47); `noDay` = −2^63; `nodeDays` accessor; docs `:87-128`; `writeGraphGrid` `:439`/`writeStackGrid` `:513` take `nodeDays`; `fromBytes` accepts only 3 and 4.
- `input_builder.dart` `:13`, `layout_input.dart` `:38` — docs: timestamps every request; `utcOffsetMin` read by both modes.

**Worker** — `worker/isolate.dart:3814` `withTimestamps: true`; docs at `isolate.dart:842-843`, `commands.dart:339`/`:379`, `handle.dart:178-179`/`:210-221`; `docs/ffi-abi.md:1373-1378`.

**Tests** (`packages/zanshin_core/test/`):
- `graph_layout/engine_test.dart` — `naiveLanes` `:36` → a literal two-model scan (both visit orders, fewer lanes, tie compact); `lane_packing_equals_…` `:428`; hand-built joint conflict + visit-order choice cases; the compact-order cost tests `:471-560` re-based on the joint search (re-derive the hand trace numbers if they move); day-key tests (both modes, root, null ts); `compact_emits_no_bucket…` `:308` stays.
- `graph_layout/invariants.dart` — `greedyEngine` `:284` joint; `naiveCompactCost` `:377` = 16·c_c + c_f over both models; `invariantFailures` `:164` gains a day-key check; NEW `i8Failures(compactGrid, freeGrid)`.
- `graph_layout/invariants_test.dart` `:41` — I8 on the 1,000 seeded DAGs × 2 orders, and on every golden input.
- `graph_layout/stacks_invariants_test.dart` `:44` — I8 across modes for each stack state; `stack_invariants.dart` day key of stack nodes.
- `graph_layout/golden_test.dart` — the 57f259c oracle `:49-53` compares rows and edges only (lanes now joint); NEW: joint greedy lanes == `design/oracle/joint-design-<rev>.lanes.json`'s GL minimum on `stacks/design-{default,all}.json`; `:68-76` and `:172` numbers re-derived if they move.
- `graph_layout/grid_view_test.dart` — versions 3/4, `nodeDays`, v1/v2/v5 refused.
- `graph_layout/input_builder_test.dart` `:178` — wording only if needed.
- `worker/graph_layout_test.dart` `:515` — timestamps for both modes; NEW: compact and free on one repo return identical lane/col arrays; `:80` stays.

**Docs, planning, tracking** — `epics.md` Delivered note after Story 4.14's `**Related:**` (`:4259`); `decisions-review-4-10-to-4-13.md` NEW `### 4.14` table; `deferred-work.md` § "Surfaced in Story 4.14 (bmad-build-auto, 2026-10-27)" (only if anything is deferred); `sprint-status.yaml:116` → `done`, `last_updated`; `epic-4-context.md` last (4.14 done).

## Tasks & Acceptance

**Execution:**
- [x] `docs/graph-layout.md` -- the dated amendments above, from Design Notes -- SPEC first.
- [x] `spikes/graph-layout-ab/dart/{lib/src/layout.dart,lib/src/compact_order.dart,bin/graph_layout.dart,test/layout_test.dart}` -- `--columns joint`; `dart compile exe bin/graph_layout.dart -o build/graph_layout`; `dart run test/layout_test.dart` green; `dart analyze` clean -- the reference.
- [x] `spikes/graph-layout-ab/tools/{design-layout.mjs,design-input.mjs,goldens.mjs,compare.mjs}`, `README.md` -- I1 loader, design oracle, joint goldens; run `node tools/design-input.mjs --rev e74ced3` (== e243dd2 inputs), `node tools/design-layout.mjs`, `node tools/goldens.mjs` twice (no diff the second time).
- [x] `packages/zanshin_core/lib/src/graph_layout/{layout_engine,compact_order,stacks,graph_grid_view,input_builder,layout_input}.dart` -- the port, grid v3/v4, day key.
- [x] `packages/zanshin_core/lib/src/worker/{isolate,commands,handle}.dart`, `docs/ffi-abi.md` -- timestamps for every request + docs.
- [x] `packages/zanshin_core/test/graph_layout/*`, `test/worker/graph_layout_test.dart` -- the safety net above.
- [x] `spikes/graph-layout-ab/tools/record-graph.mjs` (run) -> `app/widgetbook/graph/graph_recordings.g.dart`; `flutter test test/features/graph` in `app/` -- recordings on joint columns.
- [x] Measurements (I2): `tools/lane-metrics.mjs` on `--columns mode` vs `--columns joint` outputs (both modes × both orders) for `design-e243dd2-{default,all}`, `fixture-medium-all`, `fixture-large-all`, `synth-10k`, `synth-100k`; spike Dart AOT `bench` mode vs joint (layout time); record in § Measurements; apply the exact-colouring rule of Design Notes.
- [x] `epics.md`, decisions `### 4.14`, `deferred-work.md` (if anything is deferred), `sprint-status.yaml`, `epic-4-context.md` LAST -- tracking.

**Acceptance Criteria:**
- Given the finished tree, when the AC greps of 4.13 run (`\.sort(`, static/top-level finals, `GraphLayout`/`GraphRef` types, engine-core imports), then none has a hit, and `crates/`, `schemas/`, the spike's `rust*/`, `lib/zanshin_core.dart` and `coverage-baseline.txt` are unchanged; under `app/` only `widgetbook/graph/graph_recordings.g.dart` changed.
- Given the spike, when `node tools/compare.mjs --digest` and `node tools/fuzz.mjs --cases 300` run (per-mode default), then both exit 0 (the reference without the flag is unchanged); and `node tools/compare.mjs --core <product AOT binary>` exits 0 against Dart `--columns joint`.
- Given `packages/zanshin_core`, when `dart test` runs with the `test-core` env, then every test passes, including I8 on every golden and on ≥ 1,000 seeded DAGs × 2 orders (and × stack states), and the design-oracle lane count.
- Given § Measurements, when read, then it states mean width, holes and crossings per mode for per-mode vs joint packing on every listed input, the layout time, whether the real 1.4k-commit repo was measured, and the exact-colouring decision.
- Given `## Auto Run Result`, when read, then I1, I2, I3 each have an outcome (fixed with commit hash, rejected, partly done or not done).

## Spec Change Log

- 2026-10-27 (implementation run) — **Work units of an exchange.** Design Notes charged "per model, the
  length of each of the two rebuilt lists", which contradicts their own "with a single model every
  rule reduces to today's §4.7 byte for byte" (today charges the shifted tail). Implemented and
  written into GLD §4.7 (amended): per model and per column, the list's length before the rebuild
  minus the index of its first changed entry — equal to today's charge with one model (the spike
  test runs `JointCompactOrder(single: true)` against `CompactOrder` at budgets 0 … 2,000,000), and
  the rebuild only touches the list from that index. Same in spike and product.
- 2026-10-27 — **`--columns joint` scope.** The flag takes only `--mode compact|free` with
  `--order greedy|compact` (joint columns are defined for those two models and the shipped orders);
  anything else is exit 2. Added to GLD §6.
- 2026-10-27 — **Budget-cut goldens.** With joint columns `design-all`'s `compact` search ends inside
  its first window at every budget, so the three cut goldens became two on `design-default`
  (compact N = 20, free N = 10); the cut is the same in both modes (the search is mode-independent).

## Review Triage Log

### 2026-10-27 — Review pass
*(The review diff excluded the regenerated golden JSON files and `app/widgetbook/graph/graph_recordings.g.dart` for size; both are tool outputs whose determinism and equality to the reference were checked by `goldens.mjs` reruns, `compare.mjs --core` and the recorder rerun.)*
- verdicts: 24 findings — high 0, medium 4, low 15, false 5, maybe-false 0
- findings:
  - `medium` `patch` [blind] `epics.md` lost the `### Story 4.15` heading under the 4.14 Delivered block. — Delivered block's last bullet ended, heading restored verbatim (epics.md:4269).
  - `low` `patch` [blind] The 4-14 `sprint-status.yaml` comment is the backlog text and says "Grid format unchanged". — DONE summary prefixed; "grid format v3/v4 (node day key, I3)".
  - `low` `patch` [blind] The width growth is quoted as +18 %, +28 % and 2.77 → 3.54 in three places. — Every figure now names its basis ("+28 % vs per-mode compact, +18–20 % vs the larger per-mode width") in decisions, epic-4-context, epics.md and the spec.
  - `low` `patch` [blind] The regenerated `epic-4-context.md` lost the `GraphLayout`/`GraphRef`, barrel and decisions-file rules a 4.15 run needs. — A "Standing rules" line restores them.
  - `false` `reject` [blind] Deferrals (real-repo measurement, exact-colouring threshold, the `LaneIntervals` shortcut) are not in `deferred-work.md`. — The real-repo measurement is ledger item I2, already in deferred-work.md (the dispatch forbids re-mirroring it); crossings are measured (§ Measurements "cross"); the shortcut was measured harmless up to 100k and is a code comment, not open work.
  - `low` `patch` [blind] The 57f259c oracle test claims "rows and edges only" but compares lane-dependent `route`/`blocked`. — Renamed `…_rows_and_edges_incl_routes_match_the_per_mode_design_oracle`, comment states route/blocked are lane-dependent and expected to match on this sample.
  - `low` `reject` [blind] The joint oracle compares only a lane count; `joint_greedy_lanes` is not asserted. — The epic's witness is the count; per-node lanes are pinned by the spike-generated goldens and the Dart value by `design-layout.mjs` (exit 1 on mismatch).
  - `low` `patch` [blind] No test proves the joint search is mode-independent under a budget cut. — Added `a_budget_cut_joint_search_gives_the_same_lanes_and_cols_in_both_modes` (40 graphs × budgets 0/10/40/200/1000).
  - `low` `reject` [blind] `_components` (sweeps, union-find) is not charged to the budget. — By design: §4.7 leaves walking the windows uncharged (O(R·D·n), R·D fixed); the new per-pair work is the same order.
  - `low` `reject` [blind] Hot-path allocations (`List<int>` per exchange, `sublist` in `rebuild`). — The single-model search already allocated per window (`sublist`, member lists); measured cost is recorded; a rewrite is more than a direct correction.
  - `low` `reject` [blind] `LaneIntervals` / `leastLaneFrom` have no direct unit tests. — Exercised against the literal two-model scan on 300 random graphs (both visit-order outcomes asserted) and byte-identical to the reference up to synth-100k; targeted cases add little.
  - `low` `reject` [blind] `compare.mjs --core` throws on its I8 check when the compact cell failed. — Dev tool outside the gate; a throw is still a visible failure.
  - `low` `reject` [blind] Unrelated reformatting in `spikes/graph-layout-ab/dart/test/layout_test.dart`. — Cosmetic; reverting would fight `dart format`, which the spike check runs.
  - `low` `patch` [blind] GLD §4.8's `default` 9 → 7 derivation is ambiguous about whose row 4 is. — Reworded: every number is one named commit's row.
  - `false` `reject` [blind] Several changed files are not in the review diff. — Excluded for size by the triage (generated data); the spec is the claims file.
  - `medium` `patch` [edge-case] epics.md 4.15 heading. — Same as the blind finding above.
  - `false` `reject` [edge-case] `leastLaneFrom` can climb past the root when no leaf ≥ s fits. — A lane the other model rejects holds intervals, so it is used; unused lanes (value −∞, no intervals) always fit, and the tree has ≥ n leaves while at most n − 1 nodes are placed, so an unused lane ≥ s always exists.
  - `low` `reject` [intent-alignment] I2: the not-port decision rests on the design samples only; small real default revsets (≤ 40 chain heads) were not measured. — Exact colouring (GL:495) cannot run on the inputs that widened (> 40 heads), and on the ≤ 40-head inputs measured it saves no lane; the real repo's default revset is part of the real-repo measurement that I2 hands to Ralph (Auto Run Result).
  - `low` `defer` [intent-alignment] I3: `nodeDays` is the clamped T's day; the design's Compact label reads the raw ts. — Deferred to Story 10.16 (frontmatter `deferred`, mirrored in deferred-work.md).
  - `false` `reject` [intent-alignment] Story text says "grid format unchanged". — Superseded by ledger item I3, which this dispatch assigns to 4.14; recorded in decisions `### 4.14` and GLD §13; the sprint-status comment is patched above.
  - `false` `reject` [intent-alignment] Auto Run Result lacks hashes and labels I2 with a non-standard outcome. — Finalization rewrites it with the commit hash and the four-outcome labels.
  - `medium` `patch` [intent-alignment] epics.md: the Delivered block swallowed the Story 4.15 heading. — Same patch as the blind row.
  - `medium` `patch` [verification-gap, other] epics.md 4.15 heading. — Same patch as the blind row.
  - `low` `patch` [verification-gap, other] The done 4-14 sprint-status line still says "Grid format unchanged". — Same patch as the blind row. (The layer found no verification gaps.)

## Design Notes

**Joint packing (§4.3).** Notation: models k ∈ {c, f} with U_c = 1, U_f = 16; y_k, cont, Ey per model; interval [a_k, b_k) exactly §4.3's in y_k. fits(ℓ, i, x) ⇔ for k = c and f, no interval of ℓ other than x's overlaps [a_k(i), b_k(i)) (overlap = a′ < b ∧ a < b′). Packing P_k: visit by (y_k, priority, i); continuation as §4.3; else the least ℓ with fits(ℓ, i, none). In the visited model every stored interval has a′ ≤ y_k(m) ≤ y_k(i) < b, so the overlap there reduces to a < b′ (§4.3's per-lane top-two b′ + segment tree still answer it; first fit walks "least lane ≥ s with max b′ ≤ a" and re-checks the other model, s = ℓ + 1 on a reject). The other model needs a general test: per lane its intervals in that model, disjoint, kept ordered by start; [a, b) overlaps one iff the last interval starting before b ends after a (skipping x's own: then the one before it). Result: P = P_c if L(P_c) ≤ L(P_f) else P_f. Bound: O(n log n) per visit for the visited model plus O(log n) per probe of the other model, times the first-fit probes per node (≤ L); the ordered lists may be sorted arrays with insertion (O(lane size) shift) — measured in § Measurements; a comment `shortcut: …` names the upgrade (an array-backed balanced tree) if a measurement shows it. The one-pitch buffer, the merge-children term and the stub exception stay as §4.3 states them.

**Joint `compact` order (§4.7).** Segments = maximal straight chains of P (lane(fp(i)) = lane(i)); R_k(s) = the union of its nodes' intervals in model k; per model the tick geometry of §4.7 with that model's y, U, routes and blocked (D9's clip at 10·a_k − 3U_k). Columns are disjoint per model (P guarantees it, exchanges keep it). Per column one list per model, ascending by a_k (the two orders may differ). Windows of the column pair (c, c + d): the union of both columns' segments, joined when their reservations overlap in either model (per model the sweep of §4.7 — "grows while the next starts before the window's largest b" — gives the unions; a union-find merges both); a window is a connected component; components are disjoint in both models and do not depend on which column a segment sits in, so they are computed once per pair visit and visited ascending by their least a_c. Exchange = every member moves to the other column; each column's per-model list is rebuilt keeping its order. cost(W) = 16·localCost_c(W) + localCost_f(W). Work units (identical in the spike and the product): each model's `localCost` charges as §4.7; the skip test charges, per model, half the length of each span list it scans; an exchange (and its undo) charges, per model and per rebuilt list, its length before the rebuild minus the index of its first changed entry (see Spec Change Log). "If spent > budget: stop the search" is checked before each window, as now. Skip: per model k a window's span [min lo_k, 10·max b_k); kept spans recorded per model; skip after the first round iff in BOTH models the span meets no span kept since the previous round began. With a single model (the spike's per-mode default) every rule above reduces to today's §4.7 byte for byte.

**Day key.** After both layerings: dk(i) = dayKey(T(i), utc_offset_min) for non-root i (T = §4.2 free's clamped T, which the free model computes anyway); `noDay` = −2^63 for the root. Free day buckets keep their definition (= dk of their members). Grid v3 = v1 + `node day` (array 12, int64 × (n + S)), header 35 slots (140 B, arrays from 144); v4 = v3's 35 slots + S, R, M at 35–37 + five stack arrays at 38–47 (48 slots, 192 B). Versions 1/2 are retired (no grid is ever persisted).

**Exact colouring (I2).** Port it only if, on an input where it applies (≤ 40 chain heads: the design samples), the joint greedy packing has more lanes than GL with exact colouring, AND on some measured input the joint mean width exceeds the larger per-mode mean width by more than 10 %. Otherwise record the numbers and do not port.

**Taken during this run** (→ decisions `### 4.14`): (1) joint packing via two visits, fewer lanes, compact on a tie (Claude's proposal, adopted); (2) the `compact` order's joint feasibility (components in either model), cost 16·c_c + c_f, per-model skip; (3) the spike flag `--columns mode|joint`, default `mode`, so the per-mode reference and its tools stay; (4) product goldens all from the Dart binary with `--columns joint`; (5) day key per node as a grid field, root `noDay`, stack node = m_k, hidden member its own; (6) grid versions 3/4; (7) the 57f259c oracle keeps checking rows and edges, lanes move to the joint oracle; (8) the exact-colouring threshold above.

### Measurements

*(2026-10-27, the implementation run. Spike Dart AOT, M4 Pro, macOS; `--columns mode` = per-mode
packing and order, `--columns joint` = this story. `tools/lane-metrics.mjs` at the viewer's
defaults; cross = drawn crossings (side-exit drawing, GLD §12), meanW = mean per-row width,
holes in column × pitch.)*

**Lane metrics** — lanes / meanW / holes / holes% / cross, per mode (C = compact, F = free) and order:

| input | mode, order | per-mode | joint |
|---|---|---|---|
| design-e243dd2-default | C greedy | 7 / 5.000 / 7 / 15.6 % / 4 | 8 / 5.111 / 8 / 17.4 % / 6 |
| | F greedy | 7 / 6.456 / 21.5 / 13.1 % / 2 | 8 / 6.303 / 17.6 / 11.0 % / 5 |
| | C compact | 7 / 5.111 / 8 / 17.4 % / 0 | 8 / 5.333 / 10 / 20.8 % / 0 |
| | F compact | 7 / 6.020 / 10.4 / 6.8 % / 0 | 8 / 6.648 / 26.4 / 15.6 % / 0 |
| design-e243dd2-all | C greedy | 9 / 4.895 / 32 / 34.4 % / 13 | 9 / 4.895 / 32 / 34.4 % / 13 |
| | F greedy | 8 / 5.843 / 49.4 / 19.3 % / 8 | 9 / 5.816 / 48.3 / 18.9 % / 13 |
| | C compact | 9 / 6.263 / 58 / 48.7 % / 1 | 9 / 6.263 / 58 / 48.7 % / 1 |
| | F compact | 8 / 6.384 / 73.1 / 26.1 % / 5 | 9 / 7.394 / 117.4 / 36.2 % / 1 |
| fixture-medium-all (1k) | C greedy | 3 / 2.768 / 1403 / 58.3 % / 0 | 4 / 3.536 / 2071 / 67.4 % / 0 |
| | F greedy | 4 / 2.991 / 601.1 / 20.1 % / 0 | 4 / 3.592 / 1202.1 / 33.4 % / 0 |
| | C compact | 3 / 2.305 / 1001 / 50.0 % / 0 | 4 / 2.381 / 1067 / 51.6 % / 0 |
| | F compact | 4 / 2.591 / 200 / 7.7 % / 0 | 4 / 2.591 / 200 / 7.7 % / 0 |
| fixture-large-all (10k) | C greedy | 3 / 2.769 / 14039 / 58.4 % / 0 | 4 / 3.539 / 20719 / 67.4 % / 0 |
| | F greedy | 4 / 2.997 / 6019.1 / 20.1 % / 0 | 4 / 3.599 / 12038.1 / 33.4 % / 0 |
| | C compact | 3 / 2.306 / 10019 / 50.0 % / 0 | 4 / 2.382 / 10679 / 51.6 % / 0 |
| | F compact | 4 / 2.595 / 2000 / 7.7 % / 0 | 4 / 2.595 / 2000 / 7.7 % / 0 |
| synth-10k | C greedy | 134 / 50.19 / 32943 / 37.6 % / 23355 | 168 / 57.90 / 46347 / 45.9 % / 24548 |
| | F greedy | 168 / 60.93 / 117696 / 38.0 % / 29251 | 168 / 58.91 / 107432 / 35.9 % / 30111 |
| | C compact | 134 / 52.97 / 37788 / 40.9 % / 15105 | 168 / 57.77 / 46091 / 45.7 % / 20228 |
| | F compact | 168 / 60.10 / 113447 / 37.2 % / 21705 | 168 / 58.83 / 106993 / 35.8 % / 24635 |
| synth-100k | C greedy | 147 / 34.17 / 120516 / 20.1 % / 177548 | 173 / 40.23 / 226783 / 32.1 % / 161781 |
| | F greedy | 173 / 98.65 / 3344515 / 66.5 % / 191147 | 173 / 42.88 / 500578 / 22.9 % / 194735 |
| | C compact | 147 / 34.18 / 120551 / 20.1 % / 169567 | 173 / 40.23 / 226834 / 32.1 % / 156268 |
| | F compact | 173 / 98.65 / 3344511 / 66.5 % / 186238 | 173 / 42.88 / 500570 / 22.9 % / 188759 |

Reading: the joint packing is never narrower than the per-mode `compact` packing in lanes (it
honours both models) and equals the per-mode `free` packing's lane count on every measured input
except the design samples (+1). Mean width rises in Compact (vs per-mode compact) where the free model forces more lanes
(fixtures +28 %, synth-10k +15 %, synth-100k +18 %) and falls sharply in Free on synth-100k (98.6 →
42.9: the compact visit order packs the long-lived free intervals far better there). Crossings move
both ways.

**Layout time** — spike Dart AOT `bench`, medians in ms (layering / lanes / ordering / total;
fixtures and synth-10k 15 runs, synth-100k 7, warm-up 3):

| input | mode, order | per-mode | joint |
|---|---|---|---|
| fixture-medium-all | C greedy | 0.01 / 0.07 / 0.00 / 0.08 | 0.04 / 0.21 / 0.00 / 0.26 |
| | F compact | 0.05 / 0.06 / 0.11 / 0.22 | 0.05 / 0.21 / 0.22 / 0.48 |
| fixture-large-all | C greedy | 0.07 / 0.78 / 0.00 / 0.87 | 0.50 / 2.42 / 0.00 / 2.93 |
| | F greedy | 0.51 / 0.70 / 0.00 / 1.22 | 0.52 / 2.43 / 0.00 / 3.01 |
| | C compact | 0.07 / 0.79 / 1.19 / 2.07 | 0.51 / 2.41 / 2.34 / 5.36 |
| | F compact | 0.52 / 0.69 / 1.20 / 2.43 | 0.54 / 2.42 / 2.32 / 5.43 |
| synth-10k | C greedy | 0.10 / 1.69 / 0.00 / 1.90 | 0.74 / 4.10 / 0.00 / 4.92 |
| | F compact | 0.61 / 0.87 / 29.45 / 31.04 | 0.62 / 3.30 / 34.20 / 38.28 |
| synth-100k | C greedy | 1.05 / 15.14 / 0.02 / 17.35 | 6.77 / 43.34 / 0.02 / 51.55 |
| | F greedy | 6.86 / 9.81 / 0.02 / 17.84 | 7.31 / 43.37 / 0.03 / 51.72 |
| | C compact | 1.05 / 15.14 / 52.76 / 70.58 | 6.74 / 43.07 / 87.45 / 138.33 |
| | F compact | 6.82 / 9.86 / 49.26 / 66.91 | 7.15 / 44.95 / 87.32 / 139.06 |

(All 32 combinations were run; the table keeps the representative ones, the rest lie between.) The
joint layout costs 2–3× the per-mode one; at 100k the default request (Free, `compact` order) is
139 ms instead of 67 ms, the `compact` order hitting the 2,000,000 budget sooner because every
exchange is charged in both models. The other model's sorted-array insert (`shortcut:` in
`LaneIntervals`) shows no pathological case — `lanes` stays ~3× the per-mode phase at every scale
— so the balanced-tree upgrade is not needed.

**The real 1.4k-commit repo** was **not** measured: the spike has no dump of it in `inputs/` (the
dumper `rust-inputs/` reads the committed fixtures only) and this run had no access to the repo.

**Exact colouring (I2) — not ported.** The rule needs (a) an input where it applies (≤ 40 chain
heads: the design samples) on which the joint greedy packing has more lanes than GL with exact
colouring, AND (b) an input whose joint mean width exceeds the larger per-mode mean width by more
than 10 %. (a) fails: `tools/design-layout.mjs` measured GL greedy 8 / exact 8 / joint 8 (default)
and 9 / 9 / 9 (all). (b) holds (fixture-medium-all greedy: joint 3.536 / 3.592 vs max(2.768, 2.991)
= 2.991, +18–20 %; fixture-large-all the same), but exact colouring cannot apply there (far more than
40 chain heads). Decision: record, do not port.

### Verification record

*(2026-10-27, the implementation run; every command exited 0 unless stated.)*
- Spike: `dart compile exe dart/bin/graph_layout.dart -o dart/build/graph_layout`;
  `dart run test/layout_test.dart` (in `dart/`) — 56 passed, 0 failed (the 47 per-mode tests
  unchanged, 9 new joint ones incl. the literal two-model scan, I8, the single-model reduction at
  budgets 0 / 40 / 300 / 3000 / default, skip ≡ no skip); `dart analyze` (in `dart/`) — no issues;
  `dart format` (page width 120) clean.
- `node tools/design-input.mjs --rev e74ced3` then `cmp` against `inputs/design-e243dd2-{default,all}.json`
  — identical; `node tools/design-input.mjs --rev e243dd2` — inputs unchanged.
- `node tools/design-layout.mjs` — ok: default 8 / 8 / 8, all 9 / 9 / 9.
- `node tools/compare.mjs --digest --core <product AOT>` — 66 per-mode Rust ≡ Dart combinations
  identical and invariant-clean (bench digests checked); core: 44 identical and invariant-clean
  (I8 included) against Dart `--columns joint`, every input incl. synth-50k / synth-100k.
- `node tools/fuzz.mjs --cases 300` — exit 0.
- `node tools/goldens.mjs` three times; the second and third runs `diff -r`-identical.
- CLI matrix: `--columns joint` / `mode` / absent → 0 (`mode` ≡ absent byte for byte); `--columns both`,
  `--mode time --columns joint`, `--order optimized --columns joint` → 2; the Rust binary with
  `--columns joint` → 2; `bench --columns joint` echoes `"columns":"joint"`.
- `packages/zanshin_core` with the `test-core` env: `dart test` — all tests passed (incl. the worker
  suite on the real cdylib); `dart analyze --fatal-infos --fatal-warnings` — no issues;
  `dart format --output=none --set-exit-if-changed .` — clean. `dart compile exe
  benchmark/graph_layout_cli.dart` — built (used by `compare.mjs --core`).
- `node spikes/graph-layout-ab/tools/record-graph.mjs` twice — second run `cmp`-identical; in `app/`:
  `flutter test test/features/graph` — 90 passed; `dart analyze` — no issues;
  `dart format --output=none --set-exit-if-changed widgetbook/graph` — clean.
- AC greps: no `.sort(` in `lib/src/graph_layout`; no static / top-level `final` there (only `final
  class` declarations); no `GraphLayout` / `GraphRef` type in `packages/`; engine-core imports only
  `dart:typed_data`, `package:meta` and engine files. `git status`: `crates/`, `schemas/`, the spike's
  `rust/` and `rust-inputs/`, `lib/zanshin_core.dart` and `coverage-baseline.txt` unchanged; under
  `app/` only `widgetbook/graph/graph_recordings.g.dart`.
- Not run (gate rule of this run): `cargo make test` / `test-full` / `coverage`.

## Verification

**Commands:**
- spike (from `spikes/graph-layout-ab/`): `dart compile exe dart/bin/graph_layout.dart -o dart/build/graph_layout`; `dart run test/layout_test.dart` (in `dart/`); `dart analyze` (in `dart/`); `node tools/design-input.mjs --rev e74ced3` then `cmp` against the e243dd2 inputs; `node tools/design-layout.mjs`; `node tools/compare.mjs --digest`; `node tools/fuzz.mjs --cases 300`; `node tools/goldens.mjs` twice -- expected: exit 0 each, second goldens run leaves `git status --porcelain packages/zanshin_core/test/graph_layout/goldens` unchanged.
- from `packages/zanshin_core` with the `test-core` env (Makefile.toml `[tasks.test-core]`): `dart test`, `dart analyze --fatal-infos --fatal-warnings`, `dart format --output=none --set-exit-if-changed .` -- expected: green / no issues.
- product CLI AOT (`dart compile exe benchmark/graph_layout_cli.dart`) then `node tools/compare.mjs --core <bin>` -- expected: exit 0.
- `node spikes/graph-layout-ab/tools/record-graph.mjs` twice; in `app/`: `flutter test test/features/graph`, `dart analyze`, `dart format --output=none --set-exit-if-changed widgetbook/graph` -- expected: green, second recorder run no diff.
- AC greps -- expected: no hits.

**Manual checks:**
- `epic-4-context.md` is newer than every file in `_bmad-output/planning-artifacts/` and still starts with `# Epic 4 Context:`.

## Auto Run Result

Status: done
Blocking condition: none
Commits: `3739e9a0d72b7d125ffbd3faaa103937be5dca87` (code, docs, goldens, recordings); the follow-up docs commit carries this spec, `epics.md`, decisions, `deferred-work.md`, `sprint-status.yaml` and `epic-4-context.md`.

**Summary.** Joint columns, SPEC first: dated GLD amendments (§2, §3, §4.2, §4.3, §4.7, §4.8, §6,
§7.2, §7.3, §13); the spike's Dart reference with `--columns joint` (the default `mode` stays the
per-mode reference); the `e74ced3` loader and the joint design oracle; every product golden from
the Dart binary with `--columns joint`; the product engine always joint and byte-identical to it
(every input up to synth-100k, both orders); grid format versions 3 / 4 with a per-node day key;
timestamps for every worker request; recordings regenerated.

**Ledger items:**
- **I1 — fixed** (`3739e9a0d72b7d125ffbd3faaa103937be5dca87`): `tools/design-layout.mjs` evaluates `graph-layout.jsx` whole;
  `design-input.mjs --rev e74ced3` uses it and writes inputs byte-identical to `e243dd2`'s; the joint
  oracle (GL greedy 8 / 9 lanes) matches the engine and is a product golden test.
- **I2 — partly done** (`3739e9a0d72b7d125ffbd3faaa103937be5dca87`): measured on the fixtures, the
  scale inputs and the design samples and recorded; exact colouring not ported. **Left:** the real
  1.4k-commit repo (outside this repo, no dump reachable) — not measured, it goes to Ralph (already in
  deferred-work.md). Exact colouring is rejected by the Design Notes rule (§ Measurements): the joint
  packing widens fixture-medium/large `all()` (3 → 4 lanes, Compact mean width +28 % vs per-mode
  compact, +18–20 % vs the larger per-mode width) and synth inputs
  in Compact, narrows synth-100k in Free (98.6 → 42.9), and costs 2–3× the per-mode layout time; GL's
  exact colouring saves no lane on the design samples, the only inputs it applies to. The real
  1.4k-commit repo was not measured (no dump available).
- **I3 — fixed** (`3739e9a0d72b7d125ffbd3faaa103937be5dca87`): `GraphGridView.nodeDays` in both modes
  (root `noDay`, stack node = newest member's, hidden member its own), grid versions 3 / 4. Its day is
  the clamped T's (as Free's buckets); whether 10.16 wants the raw-ts day is deferred (frontmatter
  `deferred`, deferred-work.md "Surfaced in Story 4.14").

**Files:**
- `docs/graph-layout.md`, `docs/ffi-abi.md`: the amendments.
- `spikes/graph-layout-ab/dart/{lib/src/layout.dart, lib/src/compact_order.dart, bin/graph_layout.dart, test/layout_test.dart}`:
  joint packing (`LaneIntervals`, `leastLaneFrom`), `JointCompactOrder` / `CompactModel`, `--columns`, 9 tests.
- `spikes/graph-layout-ab/tools/{design-layout.mjs (new), design-input.mjs, goldens.mjs, compare.mjs}`, `README.md`.
- `packages/zanshin_core/lib/src/graph_layout/{layout_engine, compact_order, stacks, graph_grid_view, input_builder, layout_input}.dart`.
- `packages/zanshin_core/lib/src/worker/{isolate, commands, handle}.dart`.
- `packages/zanshin_core/test/graph_layout/{engine_test, golden_test, grid_view_test, invariants, invariants_test, stack_invariants, stacks_invariants_test}.dart`,
  `test/worker/graph_layout_test.dart`, the regenerated `goldens/`.
- `app/widgetbook/graph/graph_recordings.g.dart` (regenerated).
- Tracking: `epics.md` (Delivered note), `decisions-review-4-10-to-4-13.md` (`### 4.14`), `sprint-status.yaml`, `deferred-work.md` ("Surfaced in Story 4.14", one item), `epic-4-context.md`.

**Review findings** (one pass, 24 findings: high 0, medium 4, low 15, false 5; § Review Triage Log):
- **Patched:** the Story 4.15 heading in `epics.md` that the Delivered block had swallowed (medium; reported by four layers); the stale 4-14 sprint-status comment; the width percentages now name their basis everywhere; the standing naming/barrel/decisions rules back in `epic-4-context.md`; the 57f259c oracle test's name states that it compares lane-dependent routes; a new test that the joint search is mode-independent under budget cuts; GLD §4.8's 9 → 7 derivation reworded.
- **Deferred:** the node day key uses the clamped T, the design's Compact label the raw ts — 10.16 decides (low).
- **Rejected:** the oracle comparing only a count (the epic's witness), uncharged per-pair window work (by §4.7's design), per-exchange allocations and missing direct `LaneIntervals` tests (more than a direct correction; covered by the literal scan and `--core`), `compare.mjs`'s throw on a failed cell (a visible failure), spike test reformatting (cosmetic), I2's evidence on small inputs (exact colouring cannot run where the width grew); false: deferral mirroring, files absent from the review diff, `leastLaneFrom` termination, "grid format unchanged", the outcome labels.

**Follow-up review recommended:** false — patched entries: 1 medium (the heading, grouped), 6 low; no high.

**Verification:** § Verification record, re-run by the orchestrator after the implementation and again after the review patches: spike build, `dart run test/layout_test.dart`, `dart analyze`, `dart format` (clean); `design-input.mjs --rev e74ced3` == e243dd2 inputs (`cmp`); `design-layout.mjs` (default 8/8/8, all 9/9/9); `compare.mjs --digest --core <product AOT>` (66 + 44 identical and invariant-clean); `fuzz.mjs --cases 300` (exit 0); `goldens.mjs` rerun (same files); `zanshin_core` `dart test` with the test-core env (exit 0), `dart analyze --fatal-infos --fatal-warnings`, `dart format` (clean); recorder rerun (same 24-line diff), `app` `flutter test test/features/graph` (exit 0), analyze/format of `widgetbook/graph` clean; `--columns` exit codes (bogus 2, time+joint 2, Rust 2, mode 0); AC greps clean. Not run (gate rule): `cargo make test` / `test-full` / `coverage`.

**Residual risks:** the joint layout costs 2–3× the per-mode one (100k default request 139 ms vs 67 ms); Compact gets wider on linear-history repos (fixtures 3 → 4 lanes); the real-repo numbers are open (Ralph).
