---
title: 'Story 4.15: Line router B — one line per parent → child pair, as a `zanshin_core` library'
type: 'feature'
created: '2026-10-27'
status: 'done'
baseline_revision: 'add5e1ad6c914d9f4cd86452798301fb1f0a022d'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-4-context.md'
  - '{project-root}/docs/graph-layout.md'
warnings: ['oversized']
deferred:
  - summary: >-
      Gutter routes have no parity check against the export: GL's own grids in the router oracle hold
      no gutter line.
    evidence: |-
      The oracle's corpus is the one Story 4.15 names (the design sample and the Lines Study's
      PRESETS x FAN); GL's optimizer avoids every gutter there, so the gutter x, its +-6 px steps,
      gutter exit/entry ordering and deep placement on a gutter's lower run rest only on the
      hand-built router_test.dart cases and the scale checks. Mirrored in deferred-work.md
      "Surfaced in Story 4.15".
    location: >-
      spikes/graph-layout-ab/tools/router-oracle.mjs (cases)
    severity: low
---

<intent-contract>

## Intent

**Problem:** The engine emits only symbolic routes (`route`, `blocked`, GLD §4.5); the view would have to invent line geometry, and the shipped routing has prototype defect 2 / D9 (a lane-blocked merge climbs the child's column behind its cards) and D8 (Free runs behind cards). Decision (a1) adopts the floating-client export's router B (`graph-layout.jsx` = GL at `e74ced3`, `routeLines` GL:148-299, bridges GL:57-82): one line per parent → child pair with own exit and entry ports, nesting tracks, gutter routes, Free detours and clearance-keeping bridges. Three ledger items name this story: I1 (router cost on the UI isolate unknown), I2 (Free detours by a unit rule vs GL's pixel test), I3 (gutter overflow > 9 lines).

**Approach:** SPEC first (a dated GLD "Routing" section), then a pure-Dart router in `zanshin_core`'s engine core with two stages — a **class stage** per layout in units (no W/H) and a **geometry stage** per metrics with typed-array output and a per-window bridge query — exported from the barrel. A benchmark CLI and a spike oracle tool check it against GL's own `routeAll` on GL's own grids, measure it at large-10k / synth-100k (setting the synchronous-vs-`Isolate.run` threshold, item 4) and count lines behind cards.

## Boundaries & Constraints

**Always:**
- **Home & imports.** `packages/zanshin_core/lib/src/graph_layout/router.dart`, engine core: imports only `dart:typed_data`, `package:meta` and engine files (no isolate, no `dart:io`). Exported from `lib/zanshin_core.dart` with `show` of the router's public API only (no `GraphGridView`, no other engine type).
- **Input** = raw typed arrays, as `GraphGridView` exposes them, so the caller passes `grid.nodeRows`, `grid.nodeCols`, `grid.unit`, mode, `grid.edgeFroms/edgeTos/edgeKinds` plus the topology's `parentCounts` (4.10). Edges are in §3's order (child ascending, then the parent's position; the child's first edge is its first parent, `i = 0`). A node with row −1 (a hidden stack member) is skipped; a node index ≥ `parentCounts.length` (a stack node) counts as not single-parent.
- **Class stage** (per layout, W/H-free; GL:178-197): per edge kind `straight` / `fork` / `merge-adjacent` / `merge-up` / `gutter` exactly as GL (`colFree` = no visible node of that column strictly between the two rows; same column → `straight` iff first parent and free, else `gutter` on the right; first parent → `fork` iff the child's column is free; non-first → `merge-adjacent` iff the child is exactly one pitch U above, else `merge-up` iff the parent's column is free, else `gutter`). **Free detour unit rule** (free mode only): a horizontal run is blocked iff a visible node in a column strictly between its two ends (gutters count as half positions) sits 1–12 units above the parent (a run in the band above the parent) or 1–12 units below the child (a run in the band below the child). A `fork`/`merge-adjacent` checks its run above the parent, a `merge-up` its run below the child; if blocked, or for every `gutter`, the gutter is the first one, nearest the child, whose two runs are free; a `gutter` with none takes the nearest; a blocked direct kind with none stays direct and is **reported** (direct fallback). Gutter lines step ±6 px per extra line on one gutter (GL:193-197), counted in edge order; gutters with more than 9 lines are **reported** (I3). **Shared entries:** an Indirect edge into a node with `parentCount == 1` that has ≥ 2 Indirect edges shares that node's one entry slot and is `deep` (its cluster sits far from the child, GL:117); every other edge has its own slot.
- **Geometry stage** (per `RouteMetrics`: W, H, gapX 56, gapY 48, pad 56): node x = pad + col·(W + gapX), y = pad + (maxRow − row)/U · (H + gapY); entries (GL:206-221: first parent's slot at the centre; other slots per side ordered by |approach − cx| then parent row, `fan(m, 24, 16, 8, W/2 − 18)`), exits (GL:222-250, variant B only: straight at the centre, merge-up innermost then by |turn − cx|, `exitFan`), runs and tracks (GL:251-290: per run the band's room 12 px off the cards — in Free minus every card within 10 px over the run's x-range ± 4 — clusters of runs whose bands overlap and x-ranges come within 10 px, `assignTracks` + `placeTracks` incl. the unavoidable-cycle removal and the overfull fallback, which is **reported**), polylines (2 / 4 / 6 points, GL:291-297). Same formulas and evaluation order as GL in doubles; deterministic; output only in typed arrays (polyline CSR, per-node entry-port CSR, vertical runs sorted by x, horizontal runs sorted by y — the polylines' points are the bends).
- **Bridges** (GL:57-82): a query `bridges(x0, y0, x1, y1)` over the run indexes returns every crossing whose point lies in [x0, x1) × [y0, y1), only between edges that share no node, strict by 1 px; the horizontal breaks 12 × 10 unless its room (min distance to its ends − 6) is < 12 and the vertical's room is larger, then the vertical breaks 10 × 12. No all-pairs pass; the result does not depend on the window beyond the filter.
- **Engine unchanged:** `route`, `blocked`, the grid format and every golden stay byte-identical.
- **Guardrails** (as 4.11–4.14): flat typed arrays for per-node and per-edge data, no `.sort(` in `lib/src/graph_layout` (hand-written sorts; `sort.dart` gains a double-key sibling if needed), no static/top-level `final` tunables (`const`), SPDX first line on new `.dart`/`.mjs` files, `///` docs on every public member, `dart analyze --fatal-infos --fatal-warnings` + `dart format` (page width 120) clean, scenario-named tests, no `skip:`, no timing assertions.
- **Repo conventions:** fixtures and goldens never regenerated; the spike's `inputs/`/`outputs/` stay untracked; no new pub/npm dependency; `sprint-status.yaml` — only the `4-15-…` value (+ a DONE prefix to its comment) and `last_updated`; `epic-4-context.md` edited last; decisions → `decisions-review-4-10-to-4-13.md` `### 4.15`; every deferral → the spec's `deferred:` AND `deferred-work.md` § "Surfaced in Story 4.15 (bmad-build-auto, 2026-10-27)"; I1–I3 get dated notes in their existing ledger entries (no re-mirroring).
- **Gate rule of this run:** no `cargo make test`/`test-full`/`coverage`; the targeted checks in § Verification, recorded.

**Never:**
- No painting, dashes, rounded corners, hover/lineage styles (10.4); no gap markers or end stubs (10.19); no change to lanes, columns, rows, stacks or the worker; no study variants A / C (`reroute`, bus); no bridges between edges that share a node.
- No Rust, FFI, schema, `coverage-baseline.txt`, spike Rust or `app/` change; no type named `GraphLayout` or `GraphRef` in `packages/`; no read of the live design folder (always `git show e74ced3:…` via `tools/design-source.mjs` / `design-layout.mjs`); no edit of accepted GLD text (dated amendments only); no `jj` in this repo.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Kinds | hand-built grids: same column free; fork; non-first one pitch below; merge-up with a free parent column | `straight` / `fork` / `merge-adjacent` / `merge-up`; polylines of 2 / 4 / 4 / 4 points | — |
| Lane-blocked merge (defect 2) | non-first parent whose column holds a node between the rows | `gutter`, nearest the child; 6 points; no vertical inside a card | — |
| Same-column blocked | first parent in the child's column with a node between | `gutter` on the right (+½ column) | — |
| Free unit rule | a card in a column between, 12 / 13 / 0 units above the parent | 12 → detour (gutter); 13 and 0 → direct | — |
| Direct fallback | blocked direct run, every gutter blocked | stays direct; `directFallbacks` counts it | — |
| Gutter overflow (I3) | 10 lines on one gutter | x steps 0, +6, −6, +12, … ; `overfullGutters` = 1 | — |
| Shared entry | `parentCount` 1, 2 Indirect edges in | one entry port, both `deep`; with `parentCount` 2: two ports | — |
| Fan-out | 9 lines out of one side | 12 px apart at W 400, 10.5 at 240, 7 at 160 with the outer three on one exit | — |
| Entries | m other parents on one side | 24 + 16·k px, squeezed to 8 px min | — |
| Tracks | a band with nested runs; an overfull band | 3.5–6 px apart inside the free part, nesting without crossing; overfull: spacing kept, centred, `overfullClusters` counted | — |
| Bridges | hand-built crossings; random windows | orientation rule; per-window result = all-pairs oracle filtered to the window | — |
| Stability | same classes, W 160 → 400 | class stage untouched, geometry recomputed; two runs identical | — |
| Hidden members / stack nodes | grid v4 with collapsed runs | rows −1 skipped; stack nodes never share entries | — |
| Bad input | array lengths disagree, unit ≤ 0, an edge index out of range | — | `ArgumentError` |

</intent-contract>

## Code Map

**SPEC** — `docs/graph-layout.md`:
- Top note `:3-15`: Story 4.15's amendments (§4.5, §7.2, §12, new §14).
- §4.5 `:445-475`: dated amendment — the "Symbolic geometry for the painter" text and D9 are superseded by §14; `route` / `blocked` stay as output.
- §7.2 `:960-1031`: the router oracle (`tools/router-oracle.mjs`).
- §12 `:1264-1288`: dated note — the planned top-centre exit is replaced by §14's exits.
- NEW §14 "Routing (Story 4.15)" after §13 (`:1397`): the two stages and every rule of Boundaries, constants, the unit rule and its derivation from GL's pixel test, output arrays, the bridge query, where it runs (item 4) with the measured threshold, the reports, differences from GL.

**Design source** (read-only, `git show e74ced3:_bmad-output/implementation-artifacts/design/…`): `graph-layout.jsx` — `segsOf`/`analyzeEdges`/`placeCuts` :47-82, `assignTracks` :87-112, `placeTracks` :115-132, `routeLines` :151-299 (kinds :178-192, gutter step :193-197, `fan` :199-205, entries :208-221, exits :224-250, runs :252-273, room/clusters :163-171/:274-290, polylines :291-297), `routeAll` :408-426 (edges carry `pts`, `cuts`), `computeLayout` :428-611 (nodes: `col`, `u`, `uF`, `uC`, `x`, `y`, `cx`, `parents[{id, skipped, via}]`, `c.parents`). `graph-lines-study.jsx` :7-22 — `PRESETS` (TARGET `tzkvmrls`, extra parents) and `FAN` (8 extra children of TRUNK `vruxwmqv`), used as `groupStacks(commits, "default", []).list` → `computeLayout(list, "default", w, 62, mode, {optimize: true})`.

**Product** (`packages/zanshin_core/`):
- `lib/src/graph_layout/router.dart` (NEW) — `RouteClasses` (class stage; per-edge kind, side, gutter position in doubled column units, gutter step, slot, deep, first-parent; per-column node lists sorted by row; reports `directFallbacks`, `overfullGutters`), `RouteMetrics`, `RouteGeometry` (geometry stage; polyline CSR `pointStarts`/`points`, `portStarts`/`portXs`, vertical/horizontal run arrays, `overfullClusters`, `unavoidableCrossings`, `bridges(...)` → `RouteBridges` typed arrays), kind constants, `routeSyncNodeLimit` (item 4).
- `lib/src/graph_layout/sort.dart` — a double-key stable index sort if the router needs one (same style as `sortIndicesStable`).
- `lib/src/graph_layout/graph_grid_view.dart:330-350` — edge-kind codes (`edgeKindIndirect` = 1) the router reads; unchanged.
- `lib/zanshin_core.dart:59` — add the router export next to the graph export.
- `benchmark/router_cli.dart` (NEW, outside the gate, like `graph_layout_cli.dart`, which shows the spec-input parsing via `test/graph_layout/support/spec_json.dart` `parseSpecInput`) — `oracle <cases.json> <out.json>` (GL-grid cases → per edge kind/points/cuts, per node ports, reports), `check --mode --order --width --height <input.json>` (lays out with `computeGraphGrid`, routes, prints counts: kinds, fallbacks, overfull gutters/clusters, segments inside a non-endpoint card split by mode and by blocked-merge edges), `bench … [--runs N] [--warmup W] <input.json>` (one JSON line: class, geometry and one 1200 × 800 bridge-window medians). parentCounts from the input's parents (`parStart` span) — a `shortcut:` comment if the input's stack facts are not used.
- `test/graph_layout/router_test.dart` (NEW) — the I/O matrix, fan-out/entry witnesses, tracks, bridges vs an all-pairs oracle on seeded random grids and windows, stability, and the Compact gate: for every recording input (`goldens/stacks/design-{default,all}.json`, `goldens/design/design-default.json`, `goldens/fixtures/medium-narrow.input.json`) × both orders laid out in compact at W ∈ {160, 240, 400} × H 40, no polyline segment passes through a non-endpoint card, except on a reported overfull gutter; in Free the same scan counts and every hit belongs to a reported case (direct fallback, overfull cluster or gutter).

**Spike** (`spikes/graph-layout-ab/`):
- `tools/router-oracle.mjs` (NEW) — reuses `loadLayout` (`tools/design-layout.mjs:43`; extend it only by checked substitutions: GL's `routeLines` output gains `kind: e.kind`; LS's `PRESETS`/`FAN` text evaluated in the same context); cases = the sample (`default`, `all`; `optimize: false`) + LS PRESETS 1/2/3 × FAN 0/4/8 (`optimize: true`) × W 160/240/400 × H 40/62 × free/compact; feeds GL's grid (node order, col, row = u in free (U 16) / u/16 in compact (U 1), parents in order with kind, `parentCount` = `c.parents.length`) to the Dart router CLI; compares per edge kind, exit and entry offsets, polylines (±1e-6) and cuts; per case either equal, or every kind/slot difference explained (unit rule — listed with the card's unit distance; shared-entry grouping by `via` vs `parentCount`) with the remaining geometry differences consequential; writes `outputs/oracle/router-*.json`; exit 1 on an unexplained difference.
- `README.md` — `## Status` item for Story 4.15; `## Run` gains the router oracle.

**Docs, planning, tracking** — `epics.md` Delivered note after Story 4.15's `**Related:**` (`:4367`); `decisions-review-4-10-to-4-13.md` NEW `### 4.15`; `deferred-work.md` dated notes on I1–I3 (`:953-958`, `:966-968`) + "Surfaced in Story 4.15" only if anything is deferred; `sprint-status.yaml:117`; `epic-4-context.md` last.

## Tasks & Acceptance

**Execution:**
- [x] `docs/graph-layout.md` -- the §14 Routing section and the dated notes in §4.5, §7.2, §12 and the top note -- SPEC first.
- [x] `packages/zanshin_core/lib/src/graph_layout/router.dart` (+ `sort.dart` helper if needed), `lib/zanshin_core.dart` -- the router and its export.
- [x] `packages/zanshin_core/test/graph_layout/router_test.dart` -- the I/O matrix, witnesses and the Compact gate.
- [x] `packages/zanshin_core/benchmark/router_cli.dart` -- oracle / check / bench.
- [x] `spikes/graph-layout-ab/tools/router-oracle.mjs` (+ `design-layout.mjs` exports if needed), `README.md` -- the oracle; run it, fix the router until every difference is explained (I2: the listed unit-rule cases).
- [x] Measurements: `check` on `synth-10k` compact greedy (the blocked merges: no vertical behind a card) and on the scale inputs; `bench` (AOT) at `fixture-large-all` and `synth-100k`, both modes, W 240 / H 62 and H 40; set `routeSyncNodeLimit` and write § Measurements, GLD §14 and the I1–I3 outcomes.
- [x] `epics.md`, decisions `### 4.15`, `deferred-work.md`, `sprint-status.yaml`, `epic-4-context.md` LAST -- tracking.

**Acceptance Criteria:**
- Given the finished tree, when the AC greps run (`\.sort(` in `lib/src/graph_layout`, static/top-level `final` there, `GraphLayout`/`GraphRef` types in `packages/`, engine-core imports incl. `router.dart`), then none has a hit; `crates/`, `schemas/`, `app/`, the spike's `rust*/`, every golden and `coverage-baseline.txt` are unchanged.
- Given `packages/zanshin_core`, when `dart test` runs with the `test-core` env, then every test passes, including the existing golden and invariant suites (the engine is untouched) and `router_test.dart`.
- Given the oracle, when `node tools/router-oracle.mjs` runs, then it exits 0 and § Measurements lists, per category, the cases that differ from GL with their explanation (I2's unit-rule cases among them).
- Given § Measurements, when read, then it states the class and geometry stage timings at large-10k and synth-100k (AOT, warm), the chosen `routeSyncNodeLimit`, the synth-10k blocked-merge result, and the counts of direct fallbacks, overfull gutters and overfull clusters on the scale inputs.
- Given a `RouteClasses`, when its geometry is computed for W 160 and then W 400, then the class arrays are unchanged and nothing re-lays out (the API takes no W/H in the class stage).
- Given `## Auto Run Result`, when read, then I1, I2, I3 each have an outcome (fixed with commit hash, rejected, partly done or not done).

## Spec Change Log

- 2026-10-27 — **Per-edge report flags.** Besides the counts, `RouteClasses.fallbackEdges` (per edge: a direct fallback) and `RouteGeometry.overfullEdges` (per edge: a run in an overfull cluster), so the Free gate and `router_cli check` attribute every card hit to a reported case. GLD §14.2 / §14.3 name them.
- 2026-10-27 (review) — **`fallbackEdges` also flags a Free `gutter` line with no free gutter** (it takes j = 0 and may pass behind a card); `directFallbacks` still counts only the blocked direct kinds. Also from the review: the unit rule's H bound (13·(H + gapY)/16 ≥ H + 22) in GLD §14.2 and `RouteMetrics`' doc; the bridge query's tile inflation (6 px), its real cost (the window's x-strip over the whole height, `shortcut:`) in GLD §14.4 and its doc; eight more pins in `router_test.dart`.
- 2026-10-27 — **Card-hit scan as shared test support.** GL's `throughCards` (GL:303-310) lives in `test/graph_layout/support/router_scan.dart` (`cardHits`, `overfullGutterEdges`), used by `router_test.dart` and by `router_cli.dart check` (the CLI already imports test support for `parseSpecInput`); not in the Code Map.
- 2026-10-27 — **`RouteBridges` shape.** Per crossing: x, y, the horizontal edge, the vertical edge and which one breaks (`verticalBreaks`), not only the broken edge — the painter needs the side, the oracle both edges. GLD §14.4.
- 2026-10-27 — **An entry approach exactly at the child's centre** counts as the right side (GL puts it on neither side and gives it no port). Only a gutter line whose ±6 px steps reach the centre can hit it. GLD §14.6.
- 2026-10-27 — **The oracle also lists run verdicts.** Per direct run in `free`, the unit rule's and GL's pixel verdicts are compared even when the class ends up equal (a run both block stays a fallback), so I2's listing cannot come out empty by construction; on the 132 cases there are none.
- 2026-10-27 — **`bench`'s bridge window** is 1200 × 800 at the plane's left edge, vertically centred (where the trunk's lines run); the plane's centre is empty on the synth inputs.

## Review Triage Log

### 2026-10-27 — Review pass
- verdicts: 38 findings — high 0, medium 2, low 25, false 9, maybe-false 2
- findings:
  - `false` `reject` [blind] The spec has no `## Auto Run Result`. — Finalization writes it (this pass); the AC is judged on the finished spec.
  - `false` `reject` [blind] Tracking says done while the spec is in review. — The tracking lands in the same finalization commit as `status: done`.
  - `low` `patch` [blind] The unit rule's "never direct where GL blocks" holds only for H ≤ ~90 px. — GLD §14.2 and `RouteMetrics`' doc now state the bound 13·(H + gapY)/16 ≥ H + 22.
  - `low` `reject` [blind] `RouteMetrics` is not validated (NaN, W < 72, gapY < 24). — Caller-supplied design constants (W 160–400, H 40/62); a guard is more than a direct correction for inputs no caller produces.
  - `low` `defer` [blind] The oracle never checks gutter routes against GL (GL's grids hold none). — Real; the story fixes the oracle's corpus (sample + Lines Study), so extra gutter cases lie outside the intent; frontmatter `deferred`, mirrored in deferred-work.md.
  - `low` `reject` [blind] The oracle's per-case "explained" status is too coarse. — Latent: all 132 cases are equal, none is "explained"; dev tool outside the gate.
  - `medium` `patch` [blind] The bridge query is indexed only by x, so its cost grows with the plane's height. — Doc and GLD §14.4/§14.5 now state the cost honestly, with a `shortcut:` naming the upgrade (per-x runs sorted by y); measured cost stays recorded.
  - `low` `patch` [blind] Cut rectangles straddling a tile edge are lost. — `bridges` doc and GLD §14.4: a tiling caller inflates its window by 6 px and drops repeats.
  - `low` `reject` [blind] `routeSyncNodeLimit` is derived thinly. — A recorded decision with its basis and an "If overruled" column (decisions `### 4.15`); 10.4 wires it and may re-measure.
  - `low` `reject` [blind] `router_cli oracle` exits 255 on an `ArgumentError`. — Dev tool outside the gate; only hand-broken input files reach it; still a visible failure.
  - `low` `patch` [blind] Tests miss merge-up's below-the-child check and the H 62 gate. — Added the Free merge-up 12/13/0 rows and ran both route gates at H 40 and 62.
  - `low` `reject` [blind] The gates exempt whole flagged edges, not the offending segment. — Test precision only; every exempted edge is a reported case, which is the gate's contract.
  - `false` `reject` [blind] Known shortcuts are not mirrored as deferrals. — `shortcut:` comments are the repo's convention for measured, harmless limits; the real-repo measurement is ledger I3 (no re-mirroring); gutter parity is deferred above.
  - `low` `reject` [blind] Spec and GLD state the derivation inequality as strict vs non-strict. — Same integers at H 40/62; fixing it would edit this build's spec.
  - `medium` `patch` [edge-case] A Free `gutter` line with every gutter blocked takes j = 0 unflagged. — `fallbackEdges[k] = 1` for it (`directFallbacks` unchanged), doc + GLD §14.2 + test `a_free_gutter_line_with_every_gutter_blocked_takes_the_nearest_and_is_flagged`.
  - `low` `reject` [edge-case] A run with no room sits mid-band through a card unreported. — With the gutter flag above, no unflagged route reaches it at H ≤ 90 (the unit rule leaves room for every direct run); a further guard is not a direct correction.
  - `low` `patch` [edge-case] Heights above ~90 px break the unit rule's claim. — Same patch as the blind H-bound row.
  - `low` `reject` [edge-case] `RouteMetrics` accepts NaN, tiny W or gapY. — Same as the blind row.
  - `false` `reject` [edge-case] Edges not running upward or self-edges draw downward. — The input is `GraphGridView`'s, whose engine guarantees one pitch upward per edge (I1/I2); `ArgumentError` guards cover what a caller can mis-wire.
  - `low` `reject` [edge-case] `free` with a unit other than 16 misreads the 12-unit rule. — `GraphGridView.fromBytes` refuses a unit that is not its mode's; a guard adds surface for no reachable input.
  - `false` `reject` [edge-case] The spec has no `## Auto Run Result`. — Written at finalization.
  - `low` `patch` [verification-gap] Merge-up exit ordering is not pinned. — Test (a): mixed side 55.2 / 67.2 / 79.2 px.
  - `low` `patch` [verification-gap] Deep run placement is untested. — Test (b): far end of the free part vs band middle.
  - `low` `patch` [verification-gap] Free room "nearest the middle" is unobservable. — Test (c): split band, run at 165.625 in the nearest interval.
  - `low` `patch` [verification-gap] The below-the-child unit-rule boundary is untested. — Test (d), grouped with the blind tests row.
  - `low` `patch` [verification-gap] `overfullGutters` is not pinned at 9 lines. — Test (e): 9 lines → 0.
  - `low` `patch` [verification-gap] Unavoidable-crossing removal has no positive test. — Test (f): count 1, tracks 6 px apart.
  - `low` `patch` [verification-gap] The bridge output order is unasserted. — Test (g): every random window compared unsorted with the documented order.
  - `low` `patch` [verification-gap, other] The docs claim a per-edge overfull-gutter flag the library lacks. — "+ per-edge" replaced in deferred-work.md, decisions and epics.md (derivable from `gutters` + `gutterSteps`).
  - `low` `reject` [verification-gap, other] `sortIndicesStableByDouble` has no direct test. — Exercised by every router test and the 132-case oracle; a dedicated test adds little.
  - `false` `reject` [intent-alignment] Item 4's threshold has no consumer (R2a vs R2b). — I1 asks the timings to set the threshold; the library must stay isolate-free; 10.4 wires the switch (recorded as I1's leftover).
  - `low` `reject` [intent-alignment] I2's "no cases" describes the corpus, not the rule. — True and stated: the oracle covers the story's corpus and its run-verdict listing is non-empty by construction; the Design Notes' derivation names the H-dependent cases; the ledger follow-up ("tune if they show") is answered.
  - `false` `reject` [intent-alignment] I3 was not measured on a real repo. — Matches the ledger's own follow-up; outcome recorded as partly done.
  - `low` `defer` [intent-alignment] Oracle equality says nothing about gutters. — Same entry as the blind gutter-parity row.
  - `false` `reject` [intent-alignment] The synth-10k blocked-merge witness is only a CLI check. — The input is untracked spike data (never committed); the CLI result is recorded in § Measurements.
  - `low` `patch` [intent-alignment] The Compact gate runs only at H 40. — Grouped with the blind tests row: now H 40 and 62.
  - `false` `reject` [intent-alignment] Stability is witnessed only at the API level. — The view and worker are out of this story (Never); the API takes no W/H in the class stage, as the witness requires.
  - `maybe-false` `reject` [intent-alignment] Item 4 was resolved although the epic marks it NEEDS DESIGN. — I1 hands the threshold to this story and decision (g) recommends exactly this placement; recorded with an "If overruled" column. Would be settled by Ralph overruling it (low if true).
  - `maybe-false` `reject` [intent-alignment] "large-10k" may not be fixture-large-all. — The epic and 4.14 use fixture-large-all (10,002 nodes) as large-10k; low if wrong (synth-10k is measured too).

## Design Notes

**Unit rule (I2) vs GL's pixel test.** GL blocks a run when the band's inner part [band + 12, band − 12] has no room left after removing each card's [y − 10, y + H + 10] over the run's x-range. For a card d units above the parent (pitch P = H + 48): room below the card iff d·P/16 > H + 22, room above iff d·P/16 < 26. H 62: GL blocks d ∈ 4…12; H 40: d ∈ 5…11. The unit rule blocks 1…12, so it detours more for d ∈ 1…3 (H 62), 1…4 and 12 (H 40); it never runs direct where GL blocks. The oracle lists these cases; the rule is tuned only if they show it wrong (e.g. visible gutters where GL's line sits cleanly above a card).

**Doubled column positions.** Column c's centre = 2c, the gutter between c and c + 1 = 2c + 1. A run between positions A and B is checked against columns with 2c strictly between them; the end columns are safe by construction (nodes of one column are ≥ one pitch apart; `fork`/`merge-up` need the column free). Gutter j of an edge (j = 0 nearest the child) = 2·col(child) − side·(2j + 1); same column: 2·col + 1.

**Item 4 (where it runs).** Decision (g)'s recommendation, adopted: both stages on the UI side, class once per layout, geometry per metrics; synchronous up to `routeSyncNodeLimit` nodes, `Isolate.run` above (10.4 wires it; the library has no isolate dependency); never a worker request. The limit = the largest n whose measured class + geometry time stays ≤ 8 ms (one frame), linear between the measured sizes, rounded down to a thousand.

**Bridge query.** Vertical runs sorted by x, horizontal runs by y; a window takes the horizontals with y in range (binary search) and the verticals with x in range that overlap the window's y-range, and tests those pairs. Output order: by horizontal run index, then vertical run index.

**Taken during this run** (→ decisions `### 4.15`): raw-array input (no `GraphGridView` in the export); bends = polyline points; the half-open window filter; the unit rule (I2) unless the oracle shows otherwise; gutter overflow reported, budget not widened (I3); the item-4 threshold rule; the oracle's difference categories.

### Measurements

*(2026-10-27, the implementation run. `benchmark/router_cli.dart` compiled AOT, Apple M4 Pro, macOS;
W 240; the input laid out by the product engine with the `compact` order unless stated; medians of
15 runs after 5 warm-ups (≤ 10k nodes) or 7 after 3 (50k, 100k). The layout itself is untimed.)*

**Timings (I1)** — class stage / geometry stage / sum, ms; one 1200 × 800 bridge window, µs:

| input | nodes | mode | H 62 | H 40 | window |
|---|---|---|---|---|---|
| fixture-medium-all | 1,002 | C | 0.08 / 0.07 / 0.15 | 0.08 / 0.06 / 0.14 | 0.1 |
| | | F | 0.07 / 0.06 / 0.13 | 0.07 / 0.06 / 0.12 | 0.1 |
| fixture-large-all | 10,002 | C | 0.94 / 0.60 / 1.54 | 0.92 / 0.58 / 1.50 | 0.2 |
| | | F | 0.94 / 0.67 / 1.61 | 0.90 / 0.62 / 1.51 | 0.2 |
| synth-10k | 9,890 | C | 1.00 / 1.38 / 2.37 | 1.00 / 1.40 / 2.40 | 1.9 |
| | | F | 1.65 / 2.14 / 3.79 | 1.62 / 2.00 / 3.63 | 0.5–2.0 |
| synth-50k | 49,442 | C | 6.58 / 8.68 / 15.27 | 5.93 / 7.73 / 13.66 | 8–10 |
| | | F | 8.63 / 10.83 / 19.46 | 8.60 / 10.81 / 19.41 | 8 |
| synth-100k | 98,842 | C | 12.20 / 15.66 / 27.87 | 12.26 / 15.47 / 27.74 | 13–17 |
| | | F | 18.11 / 22.56 / 40.68 | 18.14 / 22.59 / 40.73 | 14 |

**`routeSyncNodeLimit` = 20,000.** The slowest series is Free on the synth inputs (the default
mode): 3.79 ms at 9,890 nodes, 19.46 ms at 49,442; linear between them, 8 ms falls at
9,890 + (8 − 3.79) / (19.46 − 3.79) × 39,552 ≈ 20,516 nodes → 20,000 (Compact's series alone would
give 27,000). A card-width change re-runs only the geometry stage (≈ 55 % of the sum). The bridge
query stays ≤ 20 µs per window at every size, so 10.4 can run it per frame. Clusters stayed small:
the quadratic track assignment (GL:87-112, `shortcut:` in `_placeTracks`) never shows in the
timings, which grow linearly from 10k to 100k.

**Route checks** (`router_cli check`, W 240; C = compact, F = free; hits = segments inside a
non-endpoint card, every one explained = on a direct fallback, an overfull cluster or an overfull
gutter; none unexplained anywhere):

| input | mode, H | gutter lines | direct fallbacks | overfull gutters | overfull clusters | unavoidable crossings | card hits |
|---|---|---|---|---|---|---|---|
| fixture-large-all | C 62 / 40 | 0 | 0 | 0 | 0 | 0 | 0 |
| | F 62 / 40 | 0 | 0 | 0 | 0 | 0 | 0 |
| synth-10k | C 62 / 40 | 26 | 0 | 0 | 2 | 239 | 0 |
| | F 62 | 263 | 141 | 8 | 38 | 54 | 207 |
| | F 40 | 263 | 141 | 8 | 47 | 66 | 164 |
| synth-100k | C 62 / 40 | 281 | 0 | 14 | 2 | 2,407 | 975 (all vertical, on the 14 overfull gutters) |
| | F 62 | 2,481 | 1,500 | 28 | 358 | 492 | 8,324 |
| | F 40 | 2,481 | 1,500 | 28 | 390 | 589 | 7,855 |

**Blocked merges (defect 2).** synth-10k, compact, **greedy**, W 240 / H 62: the engine's 229 blocked
merges (4.11 item 8) route as 26 gutter lines and 203 merge-up / merge-adjacent lines (the engine's
`blocked` counts a node at the child's own row, the router's column test only nodes strictly between;
a merge-adjacent line needs no column); **0 segments behind a card**, vertical or not (the whole
layout has 0 card hits; 2 overfull clusters, 252 unavoidable crossings).

**Oracle** (`node tools/router-oracle.mjs`, 132 cases: the sample `default` / `all` and the Lines
Study's PRESETS 1–3 × FAN 0/4/8, each at W 160 / 240 / 400 × H 40 / 62 × free / compact): **all 132
equal** to GL's `routeAll` — kinds, gutters, polylines (exits, entries, tracks) to ±1e-6 and bridges
(4,692 edges, 198 bridges, all horizontal breaks; 72 overfull clusters and 6 direct fallbacks that GL
routes identically; shared slots in 120 cases). Per category (sample/study × mode × H): sample 6
equal each, study 27 equal each; no explained or unexplained case. GL's own grids contain **no**
gutter line (its lane optimizer, `optimize: true` on the Study, avoids them, and the sample has no
lane-blocked merge), so gutter routes and gutter steps are witnessed by the hand-built tests and the
scale checks only.

**I2 (unit rule).** The oracle lists no unit-rule case: on every free case, no direct run is judged
differently by the unit rule and by GL's pixel test (the "run verdicts" column, including the six
fallbacks both block). The rule is not tuned. On the scale inputs its effect cannot be compared to
GL (GL does not run there); it detours 263 / 2,481 lines and leaves 141 / 1,500 direct fallbacks on
synth-10k / synth-100k, all reported.

**I3 (gutter overflow).** No gutter carries more than 9 lines on the fixtures, the design sample or
the Study. Overfull gutters appear only on the synthetic inputs: 8 (synth-10k, free), 14 and 28
(synth-100k, compact and free); in Compact their outer lines are the only segments behind cards
(975 at 100k). Reported (`overfullGutters`, `overfullGutterEdges`), the budget is not widened.

### Verification record

*(2026-10-27, the implementation run; every command exited 0 unless stated.)*
- `packages/zanshin_core` with the `test-core` env (Makefile.toml `[tasks.test-core]`; the build
  hook built the cdylib): `dart test` — 1152 passed (the whole suite, worker tests on the real cdylib
  included; `router_test.dart` 20 tests); `dart analyze --fatal-infos --fatal-warnings` — no issues;
  `dart format --output=none --set-exit-if-changed .` — 0 changed.
- `dart compile exe benchmark/router_cli.dart -o spikes/graph-layout-ab/outputs/bin/router_cli`;
  `router_cli check` on synth-10k (compact greedy, H 62) and on fixture-large-all / synth-10k /
  synth-100k × both modes × H 62 / 40 (`compact` order); `router_cli bench` on fixture-medium-all,
  fixture-large-all, synth-10k, synth-50k and synth-100k × both modes × H 62 / 40 — numbers in
  § Measurements.
- From `spikes/graph-layout-ab`: `node tools/router-oracle.mjs` — ok, 132 cases equal;
  `node tools/design-layout.mjs` (touched: `loadLayout` options) — ok, default 8 / 8 / 8, all 9 / 9 / 9.
- AC greps: no `.sort(` and no static / top-level `final` in `lib/src/graph_layout` (only `final class`
  declarations); no `GraphLayout` / `GraphRef` type in `packages/`; the engine core incl. `router.dart`
  imports only `dart:typed_data`, `package:meta` and engine files (`router.dart`: `dart:typed_data`,
  `graph_grid_view.dart`, `sort.dart`). `git status`: `crates/`, `schemas/`, `app/`, the spike's
  `rust/` and `rust-inputs/`, every golden and `coverage-baseline.txt` unchanged; changed:
  `docs/graph-layout.md`, `sort.dart`, `lib/zanshin_core.dart`, the spike's `README.md` and
  `tools/design-layout.mjs`; new: `router.dart`, `router_test.dart`, `support/router_scan.dart`,
  `benchmark/router_cli.dart`, `tools/router-oracle.mjs`; plus the tracking files.
- Not run (gate rule of this run): `cargo make test` / `test-full` / `coverage`.
- After the review patches (orchestrator, 2026-10-27): `cargo make --allow-private test-core` — 1159
  passed (`router_test.dart` 27); `test-core-analyze` — no issues; `test-core-format` — 0 changed;
  `node tools/router-oracle.mjs` — ok, 132 cases equal; AC greps clean; `epic-4-context.md` newer
  than `epics.md`.

## Verification

**Commands:**
- from `packages/zanshin_core` with the `test-core` env (Makefile.toml `[tasks.test-core]`): `dart test`, `dart analyze --fatal-infos --fatal-warnings`, `dart format --output=none --set-exit-if-changed .` -- expected: green / no issues / clean.
- `dart compile exe benchmark/router_cli.dart -o <scratch>/router_cli`; `check` and `bench` on the spike inputs listed in Tasks -- expected: exit 0, numbers recorded.
- from `spikes/graph-layout-ab`: `node tools/router-oracle.mjs` -- expected: exit 0; `node tools/design-layout.mjs` -- expected: still ok (if touched).
- AC greps and `git status` -- expected: no hits; only the listed paths changed.

**Manual checks:**
- `epic-4-context.md` is newer than every file in `_bmad-output/planning-artifacts/` and still starts with `# Epic 4 Context:`.

## Auto Run Result

Status: done
Blocking condition: none
Commits: `33cd76da71b03a54591e3d9708c3d44f9d79f2d9` (router, tests, CLI, oracle, GLD §14); the follow-up docs commit carries this spec, `epics.md`, decisions, `deferred-work.md`, `sprint-status.yaml` and `epic-4-context.md`.

**Summary.** Router B as a pure-Dart `zanshin_core` library, SPEC first: GLD §14 "Routing" (dated
notes in §4.5, §7.2, §12); `router.dart` with a class stage per layout (`RouteClasses`: kinds,
gutters, ±6 px steps, the 1–12 unit rule for Free detours, shared deep entries at single-parent
hidden merges; reports `directFallbacks`, `fallbackEdges`, `overfullGutters`) and a geometry stage
per card size (`RouteGeometry` for `RouteMetrics`: exits, entries, tracks, polylines, entry ports,
run indexes in typed arrays, `bridges(x0, y0, x1, y1)` per window; reports `overfullClusters`,
`overfullEdges`, `unavoidableCrossings`), exported from the barrel with `routeSyncNodeLimit` =
20,000. The engine, its grid and every golden are unchanged. The router oracle runs GL's own
`routeAll` on GL's own grids (sample + Lines Study, W 160/240/400 × H 40/62 × both modes): all 132
cases equal.

**Ledger items:**
- **I1 — fixed** (`33cd76da71b03a54591e3d9708c3d44f9d79f2d9`): class + geometry measured AOT (1.5 ms at
  fixture-large-all, 3.8 ms at synth-10k, 40.7 ms free / 27.9 ms compact at synth-100k; a bridge window
  ≤ 20 µs on the measured inputs); `routeSyncNodeLimit` = 20,000 (synchronous up to it, `Isolate.run`
  above, GLD §14.5). Wiring the switch is Story 10.4's (its view code), not open work here.
- **I2 — rejected** (no change needed): the oracle lists no case — on all 132 cases no direct run is
  judged differently by the unit rule and GL's pixel test (the listing compares both verdicts per run),
  so there is nothing to tune; the rule stays (its H ≤ ~90 px bound is now stated in GLD §14.2).
- **I3 — partly done** (`33cd76da71b03a54591e3d9708c3d44f9d79f2d9`): overflow is reported
  (`overfullGutters`), the 9-line budget is not widened; none on the fixtures, the design sample or the
  Lines Study, 8 on synth-10k (free) and 14 / 28 on synth-100k (compact / free). **Left:** a real repo —
  none was measured (no dump reachable, as in 4.14); widening waits on that.

**Files:**
- `docs/graph-layout.md`: §14 Routing + dated notes.
- `packages/zanshin_core/lib/src/graph_layout/router.dart` (new): both stages and the bridge query.
- `packages/zanshin_core/lib/src/graph_layout/sort.dart`: `sortIndicesStableByDouble`.
- `packages/zanshin_core/lib/zanshin_core.dart`: the router export.
- `packages/zanshin_core/test/graph_layout/router_test.dart` (new, 27 tests), `support/router_scan.dart` (new): the matrix, witnesses, route gates.
- `packages/zanshin_core/benchmark/router_cli.dart` (new): `oracle`, `check`, `bench`.
- `spikes/graph-layout-ab/tools/router-oracle.mjs` (new), `tools/design-layout.mjs` (`kinds` / `study` options), `README.md`.
- Tracking: `epics.md` (Delivered note), decisions `### 4.15`, `deferred-work.md` (I1–I3 notes + "Surfaced in Story 4.15"), `sprint-status.yaml`, `epic-4-context.md`.

**Review findings** (one pass, 38 findings: high 0, medium 2, low 25, false 9, maybe-false 2; § Review Triage Log):
- **Patched:** the unflagged Free gutter fallback (medium); the bridge query's real cost stated with a `shortcut:` (medium); the unit rule's H bound; the 6 px tile inflation; eight test pins (merge-up exit order, deep placement, Free room choice, merge-up unit-rule boundary, 9-line gutter, unavoidable crossing, bridge order, H 62 gates); the "+ per-edge" overstatement in three docs.
- **Deferred:** gutter routes have no GL parity in the oracle (low; frontmatter + deferred-work.md "Surfaced in Story 4.15").
- **Rejected:** metrics validation, `router_cli` exit codes, the oracle's coarse "explained" status, whole-edge gate exemptions, the double-sort test, the input guards (unit vs mode, upward edges) and the no-room guard (unreachable at product sizes or caller contracts), the sync limit's thin basis (a recorded decision), the inequality wording (would edit this spec); false: the Auto Run Result / tracking timing, shortcut mirroring, item 4's consumer, the real-repo measurement, the CLI-only synth witness, API-level stability; maybe-false: item 4's NEEDS DESIGN status, the large-10k input name.

**Follow-up review recommended:** false — patched entries: 2 medium (separate root causes), 0 high. By the rule two patched mediums would recommend one, but both were doc/flag-level fixes verified by tests and the oracle; no unverified risk can be named, so `false`.

**Verification:** `cargo make --allow-private test-core` 1159 passed; `test-core-analyze` no issues; `test-core-format` 0 changed; `node tools/router-oracle.mjs` 132 cases equal (before and after the patches); `router_cli check` / `bench` (AOT) numbers in § Measurements; AC greps clean; `crates/`, `schemas/`, `app/`, spike `rust*/`, goldens and `coverage-baseline.txt` unchanged. Not run (gate rule): `cargo make test` / `test-full` / `coverage`.

**Residual risks:** gutter routes are checked only by hand-built tests and scale checks (no GL parity); the bridge query scans a whole x-strip (slow on very long linear histories); track assignment is quadratic per cluster (small up to 100k); the real repo is unmeasured.
