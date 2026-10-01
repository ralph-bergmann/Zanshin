---
title: 'Story 4.13: Commit stacks in the layout engine — linear runs grouped into stack nodes, columns from the ungrouped layout, vertical compaction only'
type: 'feature'
created: '2026-10-01'
status: 'done'
baseline_revision: '40a2a58b6e3a339003e928b85cb0050f62cd8dae'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-4-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/decisions-review-4-10-to-4-13.md'
  - '{project-root}/docs/graph-layout.md'
  - '{project-root}/_bmad-output/implementation-artifacts/spec-4-11-dart-layout-engine-worker-isolate.md'
warnings: ['oversized']
deferred:
  - summary: >-
      D11: a split run's stack node reserves its column from its own card, so its parent edge may
      pass behind a lower card in that column.
    evidence: |-
      docs/graph-layout.md §4.8 step 6 and §9 D11: reserving from one pitch above the parent (§4.3)
      would let collapsing grow `rows`, which the story forbids. The 1,000-DAG invariants test
      produces 637 split runs (compact, greedy). For 10.4 / 10.17 to draw or mark; mirrored in
      deferred-work.md "Surfaced in Story 4.13".
    location: packages/zanshin_core/lib/src/graph_layout/stacks.dart (_segmentConstraints)
    severity: low
  - summary: >-
      The design sample's compaction with the `compact` order (19 → 16, 9 → 8) is measured, not
      derived by hand.
    evidence: |-
      The hand derivation (§4.8) covers `compact` mode with the greedy order (19 → 15, 9 → 8; the
      planning estimate 9 → 7 missed a binding column constraint) and golden_test.dart asserts it;
      the `compact` order's outputs are pinned by the stack goldens only. Mirrored in
      deferred-work.md.
    location: packages/zanshin_core/test/graph_layout/golden_test.dart
    severity: low
  - summary: >-
      A group of equal Y with a long δ = 0 chain against both pass directions costs quadratic
      passes in §4.8's level sweep.
    evidence: |-
      Not seen on any input (the stacks phase is 0.3–0.45 ms at 10k, ~9–11 ms at synth-100k,
      § Measurements); the passes alternate direction and an assert holds the bound in tests. A
      worklist per group would remove it. Mirrored in deferred-work.md.
    location: packages/zanshin_core/lib/src/graph_layout/stacks.dart (_rows)
    severity: low
  - summary: >-
      `tools/compare.mjs --core` still compares only stack-less outputs; the stacks path is
      checked by the committed stack goldens and the invariants.
    evidence: |-
      Stacks have no Rust reference; the product equals the spike Dart on the design sample × 3
      requests × 2 modes × 2 orders and 60 seeded fuzz cases × 4. Mirrored in deferred-work.md.
    location: spikes/graph-layout-ab/tools/compare.mjs
    severity: low
  - summary: No real-repo numbers for stacks (no repo path given).
    evidence: |-
      § Measurements uses the committed fixtures and the spike's synthetic inputs with synthetic
      facts (`node tools/stacks.mjs facts`). Mirrored in deferred-work.md.
    location: packages/zanshin_core/benchmark/graph_layout_cli.dart
    severity: low
  - summary: >-
      `cargo make test` exits 1 at `test-dart-analyze` and `test-dart-format` (app) on
      app/lib/src/shared/theme/zanshin_icons.dart, which Ralph's commit 40a2a58 ("update icon
      font") regenerated; this story may not touch `app/lib`.
    evidence: |-
      Both gate runs of this story (before and after the review patches) stop at `dart analyze
      --fatal-infos --fatal-warnings` in `app/` with 103 info-level lints, every one in
      zanshin_icons.dart (omit_obvious_property_types, avoid_redundant_argument_values, …), and
      `dart format --set-exit-if-changed` reports that one file as changed. The file is unchanged
      since the baseline 40a2a58 (this story's diff has no `app/` path). Every other gate task was
      run on its own with `cargo make --allow-private <task>` and passed: test-cargo, clippy, fmt,
      flutter test, test-core (785 tests), every analyze/format of the packages, cargo deny,
      hygiene, and coverage (`coverage-check: OK — 99.47 %`, `extern-coverage: OK`). Fixing the
      icons file (e.g. `dart fix --apply` + `dart format` on it, or excluding the generated file
      from analysis) is Ralph's call. Mirrored in deferred-work.md.
    location: app/lib/src/shared/theme/zanshin_icons.dart
    severity: medium
---

<intent-contract>

## Intent

**Problem:** The design collapses linear runs of commits into one stack card, but it re-runs the whole layout on the rewritten commit list, so every toggle re-packs the lanes and whole branches jump sideways. Ralph decided (2026-09-28) that a toggle — and the "Group stacks" switch — never changes a column and may only compact vertically. The view never computes rows, so grouping is engine work, and the 4.11 engine has none.

**Approach:** SPEC first: a dated `docs/graph-layout.md` §4.8 "Stacks" (plus §2/§3/§6/§7.3/§13 amendments) states the run rule, the request, the columns, the row constraints with a termination argument, and the output. Implement it in the spike's Dart reference (Dart-only, like the `compact` order; the Rust binary rejects `--stacks` as an unknown flag), generate goldens from the spike's Dart binary (design sample at `e243dd2` incl. the design's `groupStacks` oracle, seeded stack fuzz cases), then port the same code into `packages/zanshin_core/lib/src/graph_layout/` with the input builder's facts + key resolution, the request fields on `RepoHandle.graphLayout`, and grid format v2.

## Boundaries & Constraints

**Always:**
- **Decisions are taken** (`decisions-review-4-10-to-4-13.md` § 4.13 + the 2026-09-28 proposals): tags and other workspaces' working copies break a run, conflicts do not; runs of mutable ancestors of this workspace's `@` start expanded; in `free` a stack sits at its newest member's time; item 4 = one constraint per pair of adjacent segments in a column, following the ungrouped y order, with a termination argument; item 5 = per-node arrays stay topology-indexed, collapsed members hidden with no position, stack nodes appended after n, runs as CSR over topology indices; oracle = the 52-commit sample at `e243dd2` (the planning check passed — see Design Notes); the hand-built gap cases stay. Further decisions taken in this run are Design Notes § Taken during this run → the decisions file's new `### 4.13`.
- **Columns are the ungrouped layout's** (4.11's rows, packing, `compact`/greedy order) in every stack state; a stack takes its newest member's lane and column; `lanes` is the ungrouped value. Rows come from the grouped graph by the exact §4.8 rule of Design Notes (least solution, level sweep). Collapsing never increases any node's y nor `rows`.
- **`stacks` off ⇒ 4.11's result byte for byte:** the same grid buffer (format version 1, unchanged writer path) and the same §3 canonical JSON; every existing golden stays untouched. Grid format version 2 only when stacks are requested.
- **Same code twice:** the spike's `dart/lib/src/stacks.dart` and the product's `lib/src/graph_layout/stacks.dart` implement §4.8 identically (product == spike Dart byte for byte via goldens). Integers only, deterministic, flat typed arrays, no per-node objects or maps, NO `.sort(` (none is needed: every order comes from the ungrouped visit order / free walk), no `static`/top-level `final` tunables. The new product file is engine core: imports only `dart:typed_data`, `package:meta` and engine files.
- **Pass-through:** key strings are resolved to node indices in the worker (input builder) from the topology; the engine sees indices only. A key that names no current run (or, for keep-open, no member) is ignored. `RepoHandle.graphLayout`'s new parameters default to `stacks: false` and empty key lists; with `stacks: false` the key lists are ignored.
- **Quality bar** (as 4.11): SPDX first line on new `.dart`/`.mjs` files; `///` docs on every public member; `dart analyze --fatal-infos --fatal-warnings` + `dart format` (page width 120) clean for `packages/zanshin_core` incl. `test/` and `benchmark/`; scenario-named tests; no `skip:`; no timing assertions.
- **Repo conventions:** fixtures never regenerated; the spike's `inputs/`/`outputs/` stay gitignored (goldens are copied into `packages/zanshin_core/test/graph_layout/goldens/` and committed); no new pub/npm dependency; `sprint-status.yaml` — only the `4-13-…` status value + `last_updated` (do NOT flip `epic-4`); `epic-4-context.md` edited LAST; every deferral goes to `deferred:` AND `deferred-work.md` § "Surfaced in Story 4.13 (bmad-build-auto, 2026-10-01)".

**Never:**
- No Flutter UI (`app/` untouched); no product Rust, no extern, no `schemas/envelope.fbs` change, no coverage-baseline edit by hand; no change to the spike's Rust reference or its dumper (`rust/`, `rust-inputs/`); no type named `GraphLayout` or `GraphRef` in `packages/`; no barrel export (10.12's job).
- No grouping beyond linear runs; no narrower collapsed layout; no re-packing or column change on any toggle; no stack card/bracket/animation/persistence (10.17/10.20); no recorder tool (10.1 item 13 builds it; the spike binary's `layout --stacks` is its source).
- No read of the live design folder and no write into `_bmad-output/implementation-artifacts/design/` (always `git show <rev>:…`, via `tools/design-source.mjs`'s `designFile(name, rev)`); no edit of accepted SPEC text (dated additions / dated replacements quoting the old rule only); no edit of other stories' planning text beyond the dated notes in the Code Map.

## I/O & Edge-Case Matrix

Notation: stack facts per node = key, immutable, parent_count (real, Missing incl.), has_ref (bookmark local/remote or tag), working_copy (none / other workspace's @ / this workspace's @). EX/CO/KO = the resolved expanded/collapsed/keep-open sets.

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Stacks off | any input; `RepoHandle.graphLayout` without `stacks`; spike/product CLI without `--stacks` | grid v1 and §3 JSON identical to 4.11 (all existing goldens pass unchanged); key lists ignored | — |
| Run-rule oracle | `e243dd2` sample, revsets default + all, default request | runs (members oldest first, keys) == the design's `groupStacks(all, rev, [])`: default 6 runs (uwqmpnrk 2, mwoqxlpn 4, qmsvtlkr 3, nqxwrptl 2, pnwqxrtk 2, tqwmlnxz 2), all 7 runs (mzvwutvl 2, nvkqlxsp 2, uwqmpnrk 2, mwoqxlpn 4, qmsvtlkr 3, nqxwrptl 2, pnwqxrtk 7) | — |
| Gap cases (hand-built) | (a) B's one edge Indirect, C→B and D→C Direct, a child above D; (b) one real parent, two Indirect edges; (c) one Missing edge; (d) two runs meeting at a gap (lower newest member has one Indirect child edge); (e) a node with one Direct and one Indirect child edge; (f) collapsed stack whose newest member's child edge is Indirect | (a) B single card, C–D a stack whose parent edge (to B) is Direct; (b),(c) no member, the stack above starts one node higher; (d) two stacks, the node above the gap a single card; (e) fork, no member; (f) stack parent edge Direct, child edge keeps Indirect | — |
| Run breaks | bookmark, tag, this/other workspace's @, root, merge (parent_count 2 even with one layout parent), fork (2 children), head (0 children), immutable boundary; a conflict | each breaks the run at that node (immutable: the chain splits into two runs); a conflict never breaks | — |
| State | run of mutable ancestors of this workspace's @; CO names its oldest member; EX and CO both name it; KO names a middle member; EX names a non-oldest member; unknown key | default expanded; collapsed; expanded (EX wins); expanded (KO wins over all); ignored (default applies); ignored | — |
| Columns (I7) | every input × all collapsed / all expanded / random subsets / off; a split run (oldest member continues its parent's lane beside the parent's merge reservation) | every visible non-member keeps its ungrouped col and lane, expanded members keep theirs, a stack sits in its newest member's col/lane; `lanes` unchanged | — |
| Rows | compact: stack's parent at row r; free: a run 1 min apart vs 1 day apart; all expanded; collapse anything | compact: stack at r+1 unless a column constraint pushes it; free: stretched run compacts (descendants move down), un-stretched run keeps every other y (stack at y(m_k)); all expanded == ungrouped rows exactly; y'(v) ≤ ungrouped y for every node, `rows` never grows | — |
| Vertical compaction | `e243dd2` compact, default request (every run collapsed) | `rows` shrinks by the counts §4.8 derives by hand (expected all 19→15, default 9→7; confirm, record) | — |
| Free buckets | stacks in `free` | buckets over visible non-root nodes + stack nodes; a stack lies in the day of T(m_k); I5 holds | — |
| Output | collapsed runs present | node arrays n+S; hidden members row/lane/col −1 (JSON `null`); stack nodes appended in run order; edges reference stack nodes; runs CSR (members oldest first, state, stack node or −1/null); runs ordered by newest member index | — |
| Engine validation | StackInput arrays of wrong length; working_copy code 3; two "this"; parent_count < 0; request index out of range | — | `LayoutContractException('V5', …)` before anything is laid out |
| Spike/product JSON | `--stacks` with a node lacking a fact, a duplicate key, two `"this"`, a bad fact type; malformed request file | — | spike exit 2 (`InputError`), product `SpecInputError`/V5; Rust binary `--stacks` → exit 2 (unknown flag) |
| Builder facts | synthetic topology with flags immutable/hidden/divergent/@, refs (bookmark, remote bookmark, tag), working copies (this, other), parent counts | facts mapped as defined; keys resolve: change id → its non-hidden non-divergent node; commit id → only a hidden or divergent node; anything else ignored | — |
| Worker e2e | real cdylib, DAG run a←b←c under head x, `@` on a sibling | `stacks: false` = v1 grid; `stacks: true` default → collapsed stack (members hidden, stack node at n); `expandedKeys: [changeId(a)]` → expanded; `keepOpenKeys: [changeId(b)]` → expanded; `@` on top of the run → default expanded | — |

</intent-contract>

## Code Map

**SPEC (do first)** — `docs/graph-layout.md`
- Top note `:3-8`: add "The dated amendments of Story 4.13 are §2, §3, §4.8 (new), §6, §7.3, §9 and §13."
- §2 `:74-162`: dated amendment — optional per-node stack facts (`key` string, `immutable` bool, `parent_count` int, `has_ref` bool, `working_copy` `"this"|"other"|null`), read only with `--stacks` (then all required on every node; V5); otherwise ignored (unknown keys).
- §3 `:164-199`: dated amendment — the stacks output (Design Notes § Output).
- New §4.8 "Stacks" after §4.7 (ends `:556`): Design Notes § The rule, verbatim in substance, incl. the termination argument, the split-run limit, the hand-derived compaction counts.
- §6 `:576-604`: dated `Dart-only (2026-10-01, Story 4.13): --stacks <request.json>` in `layout` and `bench` (+ the `stacks` bench phase); Rust: unknown flag, exit 2; the product CLI has it too.
- §7.3 `:671-692`: dated I7 + "I1–I6 hold on the grouped layout" (I6 with a stack sorting as its newest member) + y' ≤ y.
- §9 `:761-797`: dated D11 (a split run's stack: its parent edge's vertical below the card is unprotected).
- §13 `:903-956`: dated amendment — `StackInput`/V5, `stacks.dart` in the engine core list, builder facts + key resolution, grid v2, the request fields.

**Spike Dart reference (`spikes/graph-layout-ab/dart/`)**
- `lib/src/layout.dart` — `_layerFree` `:344-391`: keep the walk `order` and clamped `t` as fields (e.g. `freeOrder`, `freeT`); `computeLayout` `:115-134` gains `StackInput? stacks` (after `orderLanes`, run the stack pass, then `onPhaseEnd`); `LayoutResult` `:69-110` gains nullable stack fields (stack count, nodeRun, runState, runNode, runStart, runMembers).
- `lib/src/stacks.dart` (NEW) — `StackInput` (facts + resolved index sets) and the §4.8 pass over a finished `GraphLayout` (`:137-717` fields: `lpStart`, `edgeParent`, `edgeChild`, `edgeKind`, `fp`, `chStart`/`chIdx`/`chPos`, `y`, `lane`, `col`, `visitOrder`, `laneCount`, `input.parStart/parKind`).
- `lib/src/input.dart` — `parseInput` `:66-171` gains `{bool stacks = false}` (facts required + validated per node, keys distinct, ≤ 1 `"this"`); NEW `parseStackRequest(bytes, keys)` → resolved index lists (`expanded`, `collapsed`, `keep_open` required arrays of strings).
- `lib/src/output.dart` — `encodeOutput` `:5-61`: stacks fields (hidden → `null`, `"runs"`); `digest` `:64-77`: over n+S nodes (hidden counted as −1s).
- `bin/graph_layout.dart` — `_Cli.parse` `:144-174` allowed flags `:163` gain `stacks` (a path); `_layout` `:43-53`, `_bench` `:55-128` (phase `stacks` after `ordering` when given); usage `:7-11`.
- `lib/graph_layout.dart` — export `src/stacks.dart`.
- `test/layout_test.dart` (harness `test/harness.dart`) — a `stacks` group: the six gap cases, one state case, the split run's columns, and a randomized check (all expanded == off; all collapsed: rows ≤, I7).

**Spike tools (`spikes/graph-layout-ab/tools/`)**
- `stacks.mjs` (NEW) — exports `genStackInput(r)` / `stackRequest(r, input)` (seeded, uses `rng` from `fuzz.mjs:31-44`); `node tools/stacks.mjs`: (1) the `e243dd2` gap-walk check (jj-lib 0.44 `RevsetGraphWalk` semantics vs `computeLayout`'s edges, both revsets; on failure exit 1 naming the `a399daf` fallback) — port of the planning check, Design Notes § Oracle; (2) writes `inputs/stacks-design-{default,all}.json` (`designInput` of `design-input.mjs:66-88` at `e243dd2` + facts); (3) writes `outputs/oracle/stacks-design-{default,all}.runs.json` from the design's `groupStacks` (extracted by name like `design-input.mjs:37-48`); (4) runs `dart/build/graph_layout layout --stacks` and checks its runs == the oracle; `node tools/stacks.mjs facts <in> <out>` adds deterministic synthetic facts to any §2 input (for benchmarks).
- `goldens.mjs` `:75-144` — a `stacks/` section: the two design stack inputs, request files `default` / `expanded` / `mixed`, outputs `stacks/design-<rev>.<state>.<mode>.<order>.json` (spike Dart binary for BOTH orders), the oracle runs files, `stacks/fuzz/cases.jsonl` (`{"input":…,"request":…}` per line, ≥ 60 cases, seed 413) + `stacks/fuzz/expected.json`; README text `:146-183`. Determinism as before.
- `../README.md` — `## Status` item 10 (Story 4.13), `## Run` `:76-116` gains `node tools/stacks.mjs` before `goldens.mjs`.

**Product engine (`packages/zanshin_core/lib/src/graph_layout/`)**
- `layout_input.dart` — NEW `final class StackInput` (immutable Uint8List, parentCount Int32List, hasRef Uint8List, workingCopy Uint8List codes 0/1/2, expandedNodes/collapsedNodes/keepOpenNodes Int32List) + `validateStackInput(StackInput, int n)` (V5).
- `layout_request.dart` `:38-55` — `LayoutContractException` docs: rule `V5`.
- `layout_engine.dart` — `_layerFree` `:272-324` keeps `freeOrder`/`freeT` fields; `computeGraphGrid` `:63-82` gains `StackInput? stacks` (validate V5 after V1–V4; stack pass after `orderLanes` + one more `onPhaseEnd`; v2 writer); `toGrid` `:572-601` unchanged for stacks off.
- `stacks.dart` (NEW, engine core) — the same code as the spike's `stacks.dart`.
- `graph_grid_view.dart` — v2 (Design Notes § Grid v2): header slots 33–45, five new arrays, accessors, validation; `writeGraphGrid` `:291-358` unchanged + a NEW `@internal writeStackGrid(…)` (or a v2 branch) for stacks.
- `input_builder.dart` — NEW `StackInput buildStackInput(GraphTopologyView topology, {required List<String> expandedKeys, required List<String> collapsedKeys, required List<String> keepOpenKeys})` (facts from `flags`/`isImmutable` `graph.dart:447`, `parentCounts` `:386`, `refs` `:496`, `isWorkingCopy` `:444` + `workingCopies` `:509`; keys via `indexOfCommitId` `:530` / `indicesOfChangeId` `:535` + `isHidden`/`isDivergent` `:450-453`).
- `layout_reply.dart` — `layOutTopology` `:27-43` gains `bool stacks` + the three key lists (build `StackInput` iff `stacks`).

**Worker + handle (`packages/zanshin_core/lib/src/worker/`)**
- `commands.dart` `GraphLayoutCommand` `:222-272` — fields `bool stacks`, `List<String> expandedKeys`, `collapsedKeys`, `keepOpenKeys` (required ctor params, docs).
- `isolate.dart` — `ZanshinWorker.graphLayout` `:686-748` (new required params, forwarded into the command); dispatch arm `:1940-1984` (destructure, pass to `layOutTopology` `:1971`).
- `handle.dart` `RepoHandle.graphLayout` `:175-228` — `bool stacks = false`, `List<String> expandedKeys = const []`, `collapsedKeys`, `keepOpenKeys`; doc (10.7's switch, 10.17's toggles, keep-open = selection / go-to target, keys = 10.1's key rule, off ignores the lists).

**Tests (`packages/zanshin_core/test/`)**
- `graph_layout/support/spec_json.dart` — `parseSpecInput` `:35-136` gains `{bool stacks = false}` returning the facts + keys; NEW `parseSpecStackRequest(bytes, keys)` → `StackInput`; `canonicalOutput` `:196-258` emits v2 (hidden `null`, `runs`); `specDigest` `:261-274` over n+S; a `specStackGraph(...)` helper next to `specGraph` `:288-314`.
- `graph_layout/support/topology_envelope.dart` `:15-64` — optional `flags` (extra bits per node), `parentCounts`, `refs` ((node, kind, remote?)), `workingCopies` ((node, workspace)).
- `graph_layout/stacks_test.dart` (NEW) — the matrix's hand-built rows (gap cases, breaks, state, split run columns, compact/free rows, free buckets, output shape, V5, stacks off == 4.11 grid bytes).
- `graph_layout/stack_invariants.dart` (NEW) — a naive literal §4.8 run rule + state, and `stackInvariantFailures(g, facts, ungroupedGrid, groupedGrid)`: header counts, runs == naive, hidden == collapsed members, I1–I6 over the grouped nodes/edges, I7, y' ≤ ungrouped y, rows ≤; a seeded stack-shaped generator (chains, bookmarks/tags/wcs, immutable prefixes, merges, forks, Indirect child edges, Indirect/multi-Indirect/Missing parent gaps, a deliberate split-run shape).
- `graph_layout/stacks_invariants_test.dart` (NEW) — ≥ 1,000 seeded DAGs × 2 modes × 2 orders × {all collapsed, all expanded, default, random subsets}; asserts the split case occurs ≥ 20 times; plus every stack golden input × its requests.
- `graph_layout/golden_test.dart` — a `stacks` group: design outputs (2 revs × 3 states × 2 modes × 2 orders), the oracle runs, the compaction counts, stack fuzz hashes.
- `graph_layout/input_builder_test.dart` — facts mapping + key resolution + `layOutTopology(stacks: true)`.
- `graph_layout/grid_view_test.dart` — v2 decode contract (header, counts, offsets, version 1 still read, v2 errors); existing v1 tests unchanged.
- `worker/graph_layout_test.dart` — the real-cdylib toggle (matrix row "Worker e2e"), using `buildDag` `:45-53`.

**Dev tools** — `packages/zanshin_core/benchmark/graph_layout_cli.dart`: flags `:189-226` gain `stacks <request.json>` (layout + bench; bench phase `stacks`).

**Docs, planning, tracking**
- `docs/ffi-abi.md:1044-1051` — dated note: `GraphLayoutCommand` gains the four stack fields.
- `_bmad-output/planning-artifacts/epics.md` — `> **Delivered (2026-10-01, Story 4.13 done):** …` after Story 4.13's `**Related:**` block (`:4109-4112`).
- `decisions-review-4-10-to-4-13.md` — `### 4.13` table at the end (Design Notes § Taken during this run + the oracle row).
- `deferred-work.md` — section at the end.
- `sprint-status.yaml:53` — `backlog` → `done`, comment kept; `last_updated`.
- `epic-4-context.md` — LAST: `:23` 4.13 done; a "Stacks (4.13)" technical line (grid v2, `stacks.dart`, request fields).

## Tasks & Acceptance

**Execution:**
- [x] `docs/graph-layout.md` -- §4.8 + the dated §2/§3/§6/§7.3/§9/§13 amendments from Design Notes -- SPEC first.
- [x] `spikes/graph-layout-ab/dart/{lib/src/stacks.dart,lib/src/layout.dart,lib/src/input.dart,lib/src/output.dart,lib/graph_layout.dart,bin/graph_layout.dart,test/layout_test.dart}` -- the §4.8 reference + `--stacks`; `dart compile exe bin/graph_layout.dart -o build/graph_layout`; `dart run test/layout_test.dart` green; `dart analyze` clean -- item 6.
- [x] `spikes/graph-layout-ab/tools/stacks.mjs`, `tools/goldens.mjs`, `README.md` -- the oracle check + stack inputs + facts tool; goldens incl. `stacks/`; run `node tools/stacks.mjs` (exit 0), then `node tools/goldens.mjs` twice (second run: no diff) -- goldens from the spike's Dart binary.
- [x] `packages/zanshin_core/lib/src/graph_layout/{layout_input,layout_request,layout_engine,stacks,graph_grid_view,input_builder,layout_reply}.dart` -- the port, V5, grid v2, builder facts + key resolution, glue -- item 7.
- [x] `packages/zanshin_core/lib/src/worker/{commands,isolate,handle}.dart` -- the request fields end to end.
- [x] `packages/zanshin_core/test/graph_layout/{support/spec_json,support/topology_envelope,stacks_test,stack_invariants,stacks_invariants_test,golden_test,input_builder_test,grid_view_test}.dart`, `test/worker/graph_layout_test.dart` -- the safety net (matrix rows, ≥ 1,000 DAGs, goldens, oracle, e2e).
- [x] `packages/zanshin_core/benchmark/graph_layout_cli.dart` -- `--stacks`; AOT bench (warm defaults) on fixture-medium-all, fixture-large-all, synth-10k, synth-100k with `tools/stacks.mjs facts` inputs, both modes × both orders, stacks default request vs no stacks; record in Design Notes § Measurements -- item 8 cost.
- [x] `docs/ffi-abi.md`, `epics.md`, decisions `### 4.13`, `deferred-work.md` section, `sprint-status.yaml`, `epic-4-context.md` LAST -- docs and tracking.
- [x] from `packages/zanshin_core` with the `[tasks.test-core]` env (`Makefile.toml`): the whole `dart test`, `dart analyze --fatal-infos --fatal-warnings`, `dart format --output=none --set-exit-if-changed .` -- green; do NOT run `cargo make test` (the run's verification does) and do not commit.

**Acceptance Criteria:**
- Given the finished tree, when `grep -rn "\.sort(" packages/zanshin_core/lib/src/graph_layout`, `grep -rnE "static (late )?(final|var) " packages/zanshin_core/lib/src/graph_layout` and `grep -rnE "^(late |var |final )" packages/zanshin_core/lib/src/graph_layout | grep -v ":final class "` run, then none has a hit; `stacks.dart` imports no `dart:ffi`/`dart:io`/`dart:convert`/`dart:isolate`; `grep -rnE "(class|enum|typedef|mixin) (GraphLayout|GraphRef)\b" packages/` has no hit; `lib/zanshin_core.dart` and everything under `app/`, `crates/`, `schemas/`, `spikes/graph-layout-ab/rust*/` are unchanged.
- Given the 4.11 goldens, when `git diff --stat <baseline> -- packages/zanshin_core/test/graph_layout/goldens` runs, then only files under `goldens/stacks/` and `goldens/README.md` differ.
- Given the spike, when `node tools/stacks.mjs`, `dart run test/layout_test.dart` (in `dart/`), `node tools/compare.mjs --digest` and `node tools/fuzz.mjs --cases 300` run, then each exits 0, and the Rust binary given `--stacks` exits 2.
- Given `docs/graph-layout.md`, when read, then §4.8 states the run rule, the request, the columns, the row constraints with the level-sweep procedure and its termination argument, the free and bucket rules, the output, V5, and the hand-derived `e243dd2` compaction counts that `golden_test.dart` asserts.
- Given the finished tree, when `cargo make test` runs unpiped, then it exits 0 with `extern-coverage: OK` and `coverage-check: OK`, and `git status` is clean after the finalization commit.

## Spec Change Log

## Review Triage Log

### 2026-10-01 — Review pass
- verdicts: 33 findings — high 0, medium 0, low 22, false 11, maybe-false 0
- findings:
  - `low` `patch` [blind] The run key is not in the output and `zanshin_core` has no node → key producer, so a caller must re-derive 10.1's rule to send keys back. — The key is derivable (m_1 = `runMembers[runStarts[k]]`, `keyOf` is 10.1 item 2's app-side accessor); patched the contract instead: `GraphGridView`'s run docs and `RepoHandle.graphLayout`'s doc now say a run's key is the bare 10.1 key of its first member, and the decisions file records "bare keys, no `grp:` prefix".
  - `low` `patch` [blind] Selecting a collapsed stack and sending its key as `keepOpenKeys` would expand it at once; nothing says what a selected stack contributes. — `RepoHandle.graphLayout`'s doc now says `keepOpenKeys` names nodes and a collapsed stack's own card is no node (selecting it keeps nothing open); decisions row added.
  - `low` `patch` [blind] Stack nodes break the index order (an edge into a stack node has parent < child), and no consumer is warned. — One sentence each in `GraphGridView`'s version-2 doc and the §3 / §13 amendments of `docs/graph-layout.md`.
  - `low` `reject` [blind] No accessor maps a stack node to its run. — Stack nodes are numbered in run order among the collapsed runs, so the inverse of `runNodes` is an O(R) scan; a new accessor is public surface 10.17 adds with its `GraphLayout` accessors.
  - `low` `patch` [blind] `stack_invariants.dart` "header echo" compares two List literals by identity, so only `mode` is checked. — Compared element by element (mode, order, unit).
  - `low` `reject` [blind] The spec's Design Notes item 9 / matrix still say default 9 → 7, the pass bound reads "≤ |group|", the Spec Change Log is empty. — The fix edits this build's spec (the intent-contract is read-only); the delivered count 9 → 8 is re-derived by hand in §4.8 and recorded in § Measurements and the decisions file.
  - `false` `reject` [blind] Tracking says done while the spec is in review. — The tracking edits stay uncommitted until the finalization commit, which carries them together with the spec's `done`; a blocked halt would revert them.
  - `low` `reject` [blind] The worker-side cost of a stack request (`buildStackInput`, `_resolveKey`'s id maps) is unmeasured and builds n-entry maps for any key. — Bounded by O(n) id formatting per request, small next to the ~28 ms precondition snapshot every request already pays; a scan-only-hidden/divergent optimisation is more than a direct correction for a cost no user would notice.
  - `low` `patch` [blind] The calling side's new `buildStackInput` refusal path and a V5 violation out of `layOutTopology` with stacks are untested. — Same root as the verification-gap finding below; two worker-glue tests added.
  - `low` `patch` [blind] The real-cdylib test never sends `collapsedKeys` and never runs stacks in `free`, the default mode. — The toggle test now collapses the default-expanded run under `@` by `collapsedKeys` and lays the collapsed case out in `free`.
  - `low` `reject` [blind] `writeStackGrid` duplicates `writeGraphGrid` (~100 lines), so a format change must land twice. — Both are `@internal`, read by one view whose tests decode both versions; merging them is a refactor, not a direct correction, for a drift that only a later format change could meet.
  - `low` `patch` [blind] No hand-derived test pins a stack → stack edge or a stack as a merge source ((C)'s δ₂ term). — Two hand-derived tests added to `stacks_test.dart`.
  - `low` `patch` [blind] `deferred-work.md` quotes the stacks phase as "0.3–0.45 ms at 10k", true only for fixture-large-all (synth-10k ~0.8–1.0 ms). — Corrected in `deferred-work.md` (the spec's own text is not edited).
  - `low` `patch` [blind] `tools/stacks.mjs`'s `genStackInput` can put `"this"` on a split member, and nothing checks that the stack fuzz cases contain a split run. — The generator skips split members; `tools/goldens.mjs` counts split runs over the stack fuzz cases and fails at 0; goldens regenerated.
  - `false` `reject` [edge-case] `stacks.dart` `_rows`: a positive-delta cycle inside an equal-Y group would loop forever in release (the pass bound is an `assert`). — No such cycle exists: every constraint has Y(target) ≥ Y(source) + δ (§4.8's termination argument), so inside a group only δ = 0 constraints occur and values only copy; `stack_invariants.dart` checks Y against every constraint on 1,000 DAGs × 4 modes/orders × 4 states.
  - `false` `reject` [edge-case] `stacks.dart` `_least`: a constraint whose source lies in a later Y group is skipped while unset. — Sources never lie in a later group (same argument); same-group sources are set after the first pass and the loop repeats; the harness checks y′ equals the least solution of the full constraint set.
  - `low` `patch` [edge-case] `buildStackInput` indexes refs / working copies by `node` without a range check, so a corrupt entry throws a RangeError (→ `internal.dispatch_error`) instead of the documented `ffi.unknown`. — Range-checked, `ffi.unknown` naming the entry, like `_priorities`' anchor check; covered by the new worker-glue test.
  - `false` `reject` [edge-case] `writeStackGrid` silently writes a wrong grid for arrays of mismatched lengths. — Its only caller, `StackLayout.toGrid`, passes arrays sized by construction (`n + S` node arrays, `R + 1` run starts); the view validates every count on decode.
  - `low` `patch` [edge-case] `stack_invariants.dart:112` list identity comparison. — Same patch as the blind finding above.
  - `false` `reject` [edge-case] The spike's `computeLayout` accepts `Mode.time` with stacks. — Only the spike CLI calls it with a stack request, and the CLI refuses `--stacks` with `--mode time` (exit 2); no other caller exists.
  - `low` `patch` [edge-case] `tools/stacks.mjs` writes into `inputs/` without creating it (ENOENT on a fresh checkout). — `mkdirSync(inputs, recursive)` added.
  - `low` `patch` [verification-gap] `collapsedKeys` never crosses `RepoHandle` → command → dispatch in a test, so a dropped field would pass. — The worker toggle test collapses the default-expanded run under `@` through `RepoHandle.graphLayout(collapsedKeys:)`.
  - `low` `patch` [verification-gap] The stacks error paths of `layOutTopology` / `decodeGraphLayoutReply` (a corrupt stack fact, a V5 violation) are untested. — Added `worker glue` tests: an out-of-range ref node is `(null, null)` + `ffi.unknown` on the calling side only with stacks, and two `@` flags cross as a `V5` violation.
  - `low` `patch` [verification-gap] `buildStackInput`'s out-of-range ref / working-copy node throws a RangeError, not `ffi.unknown`. — Same patch as the edge-case finding.
  - `low` `patch` [verification-gap] `stack_invariants.dart:112` dead check. — Same patch as above.
  - `low` `patch` [intent-alignment §3.1] The run key round trip: no key on the result view, no forward rule, a `grp:`-prefixed key is dropped silently. — Same root as the blind run-key finding: the docs state the bare 10.1 key of m_1, decisions row added.
  - `false` `reject` [intent-alignment §3.2] The invariants prove the code against the amended SPEC's own constraint set; D11 is invisible to the checks. — The SPEC amendment is the story's item 6 by design (the proposal "made exact"); D11 is a recorded known limit, deferred to Ralph / 10.4 (`deferred:` item 1); the header-echo part is patched above.
  - `low` `reject` [intent-alignment §3.3] The real seam misses tags, other workspaces, hidden / divergent keys, real immutable boundaries and jj's gaps. — `collapsedKeys` and `free` are now covered end to end; the remaining facts are mapped by `buildStackInput` from the same `GraphTopologyView` type the worker uses and pinned on synthetic envelopes, a real-repo setup per fact is more than a direct correction.
  - `false` `reject` [intent-alignment §3.4] "jj's edges" is a JS model of jj-lib, not jj output; `has_ref` = bookmarks only matches because the sample has no tags. — The intent asks to check the design's gap walk against jj's edge kinds; the port follows jj-lib 0.44's `RevsetGraphWalk` (incl. `remove_transitive_edges`), the sample has no tags, and tags are pinned by the builder test.
  - `false` `reject` [intent-alignment §3.5] The hand-derived compaction counts are for the greedy order, not the default `compact` order. — The story's test is "in compact" (the mode), as §7.2's design oracle is greedy; the `compact` order's grouped outputs are pinned byte for byte by the stack goldens.
  - `false` `reject` [intent-alignment §3.6] No stack recordings ship and the toggle cost on the real repo is unmeasured. — The recorder is 10.1 item 13's tool (the spec's Never); `layout --stacks` is the capability it runs; real-repo numbers need a path (`deferred:` item 5).
  - `false` `reject` [intent-alignment §3.7] Tracking says done while in review; the decisions table has more rows than the spec's list. — Tracking: as above. The decisions table is the record the intent names; the spec's list is its planning subset (fixing it would edit this spec).
  - `false` `reject` [intent-alignment §3.8] Three deferred items are engineering records, not product decisions. — They carry conditional follow-ups only ("if a real repo shows it", "if the code changes again"); the spec's `deferred:` list is append-only, so the fix would edit this build's spec.

## Design Notes

**Oracle (planning check, 2026-10-01).** A scratch port of jj-lib 0.44's `RevsetGraphWalk` (`default_index/revset_graph_iterator.rs`: Direct / closest-ancestor Indirect / one Missing per all-missing external parent / `remove_transitive_edges`) over `GRAPH_COMMITS` at `e243dd2` gave the same edges as the design's `computeLayout` gap walk on both revsets (0 differences; default: 32 Direct, 4 Indirect, 2 Missing; all: 55 Direct). So the oracle is `e243dd2` (52 commits); its default revset reaches the gap cases. `tools/stacks.mjs` re-runs this check and refuses to write the oracle otherwise.

**The rule (§4.8; `U` as §1; LP, fp, C, pos as §4.1; y, lane, col the finished ungrouped layout).**
1. *Candidates.* cand(i) ⇔ not `is_root`; `working_copy` none; `has_ref` false; `parent_count` = 1; i's §2 parent list has exactly one entry and it is `direct`; |C(i)| = 1.
2. *Links and runs.* link(i) = c (C(i) = {c}) iff cand(i), cand(c) and immutable(c) = immutable(i). A run is a maximal link chain m_1 → … → m_k with k ≥ 2 (m_1 oldest, largest index). Runs are ordered by m_k ascending; run key = key(m_1).
3. *State.* A = nodes reached from this workspace's `@` (if in the input) by walking LP parents whose immutable is false. Expanded iff a member ∈ KO, else m_1 ∈ EX, else not m_1 ∈ CO, and then (default) m_k ∈ A. Collapsed runs get stack nodes n, n+1, … in run order (S of them); their members are hidden; img(v) = v, or its run's stack node when hidden.
4. *Columns.* Visible nodes keep lane and col; a stack takes lane(m_k), col(m_k); `lanes` unchanged. A run is **split** iff col(m_1) ≠ col(m_k) (only possible as m_1 → m_2, §4.3's merge-reservation exception).
5. *Grouped graph G'.* Nodes: visible + stack nodes. Edges in §3 order (child ascending, topology nodes then stack nodes; each child's edges by position): a visible child v keeps each LP edge as (img(p), v) with its kind and pos; a stack s has one edge (img(fp(m_1)), s), `direct`, pos 0. fp′ = the first grouped parent.
6. *Rows.* Y(v) = y(v), Y(s) = y(m_k). y′ is the **least** solution with y′ ≥ 0 of: (E) y′(v) ≥ y′(p) + U per grouped edge; (F, free) with W = §4.2's walk (T asc, i desc), X(v_j) = Σ_{k≤j} gap(T(v_k) − T(v_{k−1})) (X(v_0) = 0), W′ = W minus hidden nodes with m_k replaced by its stack (X(s) = X(m_k), T(s) = T(m_k)): y′(v) ≥ y′(u) + X(v) − X(u) for consecutive u, v in W′; (C) per column, grouped nodes by Y (distinct); a **segment** = maximal consecutive run where each node's fp′ is its predecessor; for each adjacent pair (S below with top u, T above with head h): t = h, δ₁ = 2U, δ₂ = U if h is a split run's stack or has no grouped parent, else t = fp′(h), δ₁ = U, δ₂ = 0; constraints y′(t) ≥ y′(u) + δ₁ and, for every node x of S and grouped edge (x, c) with pos ≥ 1, y′(t) ≥ y′(c) + δ₂. (= §4.3's [a, b) of T starts at or above the end of S's, counting S's cards and the merges routed up its column; the cont term of a child in another column is dropped; a split stack reserves its column from its own card.)
   *Procedure + termination:* Y satisfies every constraint (it is the ungrouped layout with each stack at its newest member's y — show it per constraint kind in §4.8), so every constraint has Y(target) ≥ Y(source) + δ. Process grouped nodes in the ungrouped visit order (y, priority, i) mapped through img (hidden nodes dropped, m_k → s; ascending in Y), in groups of equal Y; per group repeat a pass (y′(v) = max of 0 and every constraint whose source is set) until no value changes. Inside a group only δ = 0 constraints exist, so a pass only copies values and the loop ends after ≤ |group| passes; values only rise from below and the least solution is unique. Hence y′ ≤ Y everywhere (rows never grow), and with nothing collapsed y′ = y (the ungrouped y is the least solution of (E)+(F) and satisfies (C)).
7. *Then* §4.4 blocked and §4.5 routes on G' with the fixed lanes (pos as above; per-lane y′ lists in column order); `free` buckets = §4.2 step 4 over W′ (roots skipped, a stack in the day of T(m_k)); rows′ = max y′ + U. I6 sorts a stack as (T(m_k), m_k).
8. *Known limit (D11).* A split stack's parent edge (a branch-off from m_1's parent) rises in the stack's column below the card without a reservation, so it may pass behind a lower card there; §4.3's start (one pitch above the parent) would let collapsing grow `rows`.
9. *Hand-derived compaction (confirm with the engine; state in §4.8):* `e243dd2` compact, every run collapsed — all: 19 → 15 (the critical chain root…vruxwmqv…qmsvtlkr-run…srkvzmop loses mzvwutvl/zsuskuln 1, nvkqlxsp/rtmswzvk 1, qmsvtlkr/wrnxqpsz/ynkplrtv 2); default: 9 → 7 (kxwsnptm via vtxnbqrs, srkvzmop via potwkszn). If a column constraint binds, re-derive by hand before changing the number.

**Formats.** §2 facts and the request file `{"expanded":[…],"collapsed":[…],"keep_open":[…]}` (all three required string arrays; keys resolve to the node whose `key` equals them, else dropped). §3 with stacks: `nodes` has n + S entries (hidden → `null`), then after `buckets` a `"runs":[{"members":[…],"state":"collapsed"|"expanded","node":<idx>|null}]`; without stacks no `runs` key. Engine V5: four fact arrays of length n, working_copy codes 0 none / 1 other / 2 this with at most one 2, parent_count ≥ 0, every request index in [0, n). JSON layer additionally: keys distinct, ≤ one `"this"`, types.

**Grid v2** (only with stacks): slots 0–32 as v1 (version = 2; node arrays have n + S entries; hidden −1), then [33] S, [34] R, [35] M, [36 + 2k, 37 + 2k] for k = 0…4: node run (int32 × n, run index or −1), run state (uint8 × R; 0 expanded, 1 collapsed), run node (int32 × R; stack node or −1), run start (int32 × R + 1), run members (int32 × M, oldest first). Header 184 bytes; arrays 8-aligned after it. `GraphGridView` reads v1 and v2 (`formatVersion` 1 stays, `stackFormatVersion` 2), exposes `hasStacks`, `stackCount`, `runCount`, `nodeRuns`, `runStates`, `runNodes`, `runStarts`, `runMembers`, `isHidden(i)`, `runCollapsed`/`runExpanded` codes; `nodeCount` stays n.

**Taken during this run** (append to the decisions file `### 4.13`): (1) the exact §4.8 row rule (least solution + level sweep; §4.3's reservation restricted to same-column and pos ≥ 1 children); (2) a split run's stack reserves its column from its own card (D11), to keep "collapsing never grows rows"; (3) `free` gaps between kept nodes are sums of the ungrouped walk's gaps and a stack's T is T(m_k) (the gap curve is not subadditive under integer rounding); (4) a key in both EX and CO → expanded; (5) runs ordered by newest member index, stack nodes numbered in that order; (6) grid v2 only with stacks, v1 byte-identical otherwise; hidden = −1 / JSON `null`; (7) the spike takes facts in the §2 input and the request via `--stacks <file>`, Rust rejects it as an unknown flag (no Rust change); (8) `stacks` defaults to false on `RepoHandle.graphLayout` (the switch's default is 10.7's); (9) keys resolve through the topology's id lookups per 10.1's key rule; (10) the default-expanded walk enters only mutable parents from this workspace's `@`; (11) `lanes` = the ungrouped value; (12) oracle `e243dd2` (check passed).

### Measurements

*(Written 2026-10-01 by the implementation run.)* Apple M4 Pro (14 cores, 24 GB), macOS 27, on AC power; Dart SDK 3.14.0-271.0.dev (macos_arm64), node v26.10.0. The product engine's CLI (`packages/zanshin_core/benchmark/graph_layout_cli.dart`, AOT via `dart compile exe`), warm defaults (W = 10, N = 31), one process per cell; inputs: the spike's `inputs/<name>.json` with `node tools/stacks.mjs facts` (key `k<i>`, the older half immutable, node 0 this workspace's `@`, one node in 17 with a ref, one in 211 another workspace's `@`); `--stacks` with the empty (default) request.

**Total, median (min); the `stacks` phase median; `rows` off → with stacks:**

| input | mode / order | n | off | stacks | `stacks` phase | rows off → on |
|---|---|---|---|---|---|---|
| fixture-medium-all | compact / greedy | 1002 | 77 µs (66 µs) | 100 µs (94 µs) | 37 µs | 869 → 92 |
| fixture-medium-all | compact / compact | 1002 | 102 µs (94 µs) | 130 µs (126 µs) | 33 µs | 869 → 92 |
| fixture-medium-all | free / greedy | 1002 | 71 µs (68 µs) | 117 µs (111 µs) | 45 µs | 16035 → 3093 |
| fixture-medium-all | free / compact | 1002 | 118 µs (112 µs) | 157 µs (154 µs) | 43 µs | 16035 → 3093 |
| fixture-large-all | compact / greedy | 10002 | 639 µs (609 µs) | 980 µs (937 µs) | 321 µs | 8681 → 800 |
| fixture-large-all | compact / compact | 10002 | 1.08 ms (1.04 ms) | 1.44 ms (1.37 ms) | 329 µs | 8681 → 800 |
| fixture-large-all | free / greedy | 10002 | 839 µs (806 µs) | 1.57 ms (1.23 ms) | 453 µs | 160035 → 29067 |
| fixture-large-all | free / compact | 10002 | 1.29 ms (1.24 ms) | 1.76 ms (1.66 ms) | 436 µs | 160035 → 29067 |
| synth-10k | compact / greedy | 9890 | 908 µs (846 µs) | 1.74 ms (1.65 ms) | 767 µs | 1745 → 1574 |
| synth-10k | compact / compact | 9890 | 30.50 ms (29.60 ms) | 30.82 ms (29.65 ms) | 827 µs | 1745 → 1576 |
| synth-10k | free / greedy | 9890 | 1.07 ms (1.00 ms) | 2.05 ms (1.97 ms) | 943 µs | 81266 → 75696 |
| synth-10k | free / compact | 9890 | 30.37 ms (29.82 ms) | 31.82 ms (31.04 ms) | 1.03 ms | 81266 → 75696 |
| synth-100k | compact / greedy | 98842 | 11.48 ms (11.07 ms) | 20.71 ms (19.95 ms) | 8.92 ms | 17585 → 15894 |
| synth-100k | compact / compact | 98842 | 53.90 ms (52.77 ms) | 62.79 ms (61.33 ms) | 8.89 ms | 17585 → 15895 |
| synth-100k | free / greedy | 98842 | 13.27 ms (12.94 ms) | 24.45 ms (23.72 ms) | 10.97 ms | 815954 → 755397 |
| synth-100k | free / compact | 98842 | 52.61 ms (50.78 ms) | 63.56 ms (62.42 ms) | 10.98 ms | 815954 → 755404 |

So a toggle costs the ungrouped layout plus the `stacks` phase: 0.3–0.45 ms at 10k (the fixtures are long linear chains, which collapse almost entirely), ~1 ms on the branchy synth-10k, ~9–11 ms at synth-100k; the `parse` phase (JSON + facts + request) is not part of it in the worker, which builds typed arrays. Item 8's other costs (the topology call, its snapshot and timestamps) are 4.10/4.11's and unchanged.

**Compaction on the design sample** (`e243dd2`, the default request: every run collapses, none lies under `@`): `compact` / greedy — all 19 → 15 (as planned), **default 9 → 8, not 9 → 7**: a column constraint binds at sxmtvqno (in zqklmwts's column the nqxwrptl stack and mrplxqwv form the segment below zqklmwts, whose first parent is sxmtvqno, so y′(sxmtvqno) ≥ y′(mrplxqwv) + 1 = 4), re-derived by hand in `docs/graph-layout.md` §4.8 and asserted by `golden_test.dart`. `compact` / `compact` order: 19 → 16, 9 → 8 (measured). `free`: all 716 → 706, default 421 → 411 (both orders).

**Oracle check** (`node tools/stacks.mjs`): jj-lib 0.44's `RevsetGraphWalk` semantics == the design's gap walk on both revsets (default 32 Direct, 4 Indirect, 2 Missing; all 55 Direct); the design's `groupStacks` finds 6 / 7 runs, equal to the spike Dart's and the product's. **Invariants:** 1,000 seeded DAGs × 2 modes × 2 orders × 4 stack states — 3,489 runs, 637 of them split (compact, greedy) — plus every stack golden. **Goldens:** 33 new files under `goldens/stacks/` (403,088 bytes after the review pass's generator fix; the whole goldens directory 1,248,010 bytes; the stack fuzz cases hold 31 split runs, compact / greedy); a second `node tools/goldens.mjs` run rewrote every golden byte-identically.

## Verification

**Commands:**
- spike (from `spikes/graph-layout-ab/`): `dart compile exe dart/bin/graph_layout.dart -o dart/build/graph_layout`, `(cd dart && dart run test/layout_test.dart)`, `node tools/stacks.mjs`, `node tools/compare.mjs --digest`, `node tools/fuzz.mjs --cases 300`, `node tools/goldens.mjs` twice -- expected: exit 0 each; the second goldens run leaves `git status --porcelain packages/zanshin_core/test/graph_layout/goldens` unchanged.
- from `packages/zanshin_core` with the `[tasks.test-core]` env: `dart test test/graph_layout test/worker/graph_layout_test.dart`, then the whole `dart test`, `dart analyze --fatal-infos --fatal-warnings`, `dart format --output=none --set-exit-if-changed .` -- expected: green, no issues.
- the AC 1 greps -- expected: no hits.
- `cargo make test` (`nohup … > <scratchpad>/gate.log 2>&1 &`, then `caffeinate -w <pid>` in the same turn; exit code from the log) -- expected: exit 0, `extern-coverage: OK`, `coverage-check: OK`.

**Manual checks:**
- `goldens/stacks/` totals well under 1 MB; no file under `spikes/graph-layout-ab/{inputs,outputs}` is tracked.
- `epic-4-context.md` is newer than every file in `_bmad-output/planning-artifacts/` and still starts with `# Epic 4 Context:`.

## Auto Run Result

Status: done
Blocking condition: none (see Residual risks: the gate's two `app/` steps are red on a file this story may not touch)

**Summary.** Commit stacks in the layout engine. `docs/graph-layout.md` gained §4.8 "Stacks" (SPEC first) plus dated §2/§3/§6/§7.3/§9/§13 amendments: the run rule (candidates, links, maximal runs ≥ 2, breaks at refs/tags, any workspace's working copy, merges, forks, gaps and the immutable boundary; conflicts never break), the state (keep-open > expanded > collapsed > the default: runs of mutable ancestors of this workspace's `@` expanded), fixed columns from the ungrouped layout (a stack takes its newest member's lane and column; `lanes` unchanged), the grouped graph, and the rows as the least solution of edge / `free`-walk / per-column segment constraints, computed by a level sweep with a termination argument (y′ ≤ y everywhere, so `rows` never grows; all expanded = the ungrouped layout exactly), `free`'s day buckets over the grouped walk, the output and V5. The spike's Dart reference implements it first (`dart/lib/src/stacks.dart`, `--stacks <request.json>`; the Rust binary rejects the flag), `tools/stacks.mjs` checks that the design's gap walk at `e243dd2` yields jj-lib 0.44's edges (it does: 0 differences on both revsets) and records the design's own `groupStacks` as the run-rule oracle (6 / 7 runs, equal to the engine's), and `tools/goldens.mjs` writes `goldens/stacks/`. The same code runs in `packages/zanshin_core/lib/src/graph_layout/stacks.dart`; `StackInput` + V5, `buildStackInput` (facts from the topology, keys by 10.1's rule), grid format version 2 only with stacks (version 1 byte for byte without), and `RepoHandle.graphLayout(stacks, expandedKeys, collapsedKeys, keepOpenKeys)` (default off). Compaction on the design sample (compact, greedy, every run collapsed): all 19 → 15, default 9 → 8 (re-derived by hand; the planning estimate 9 → 7 missed a binding column constraint at sxmtvqno).

**Files changed** (vs `40a2a58`, 73 files):
- `docs/graph-layout.md`: §4.8 (new) and the dated §2/§3/§6/§7.3/§9 (D11)/§13 amendments.
- `docs/ffi-abi.md`: dated note on `GraphLayoutCommand`'s four stack fields.
- `spikes/graph-layout-ab/dart/{lib/src/stacks.dart (new), lib/src/layout.dart, lib/src/input.dart, lib/src/output.dart, lib/graph_layout.dart, bin/graph_layout.dart, test/layout_test.dart}`: the reference, `--stacks`, 47 spike tests.
- `spikes/graph-layout-ab/tools/{stacks.mjs (new), goldens.mjs, design-input.mjs}`, `README.md`: the oracle check, stack inputs, synthetic facts, the `stacks/` goldens (+ a split-run count), `extract` exported.
- `packages/zanshin_core/lib/src/graph_layout/{stacks.dart (new), layout_input.dart, layout_engine.dart, layout_request.dart, graph_grid_view.dart, input_builder.dart, layout_reply.dart}`: the port, V5, grid v2 (`writeStackGrid`, run accessors, `isHidden`), the builder's facts and key resolution, the glue.
- `packages/zanshin_core/lib/src/worker/{commands,isolate,handle}.dart`: the request fields end to end.
- `packages/zanshin_core/test/graph_layout/{stacks_test.dart, stack_invariants.dart, stacks_invariants_test.dart (new), golden_test.dart, grid_view_test.dart, input_builder_test.dart, support/spec_json.dart, support/topology_envelope.dart}`, `test/worker/graph_layout_test.dart`: hand-built matrix rows, ≥ 1,000-DAG invariants against a literal least-solution solve, goldens + oracle + compaction, the v2 decode contract, builder facts / keys / error paths, the real-cdylib toggle (compact + free; expanded, collapsed and keep-open keys; the `@` default; a bookmark break).
- `packages/zanshin_core/test/graph_layout/goldens/stacks/` (33 files, 403,088 bytes) + `goldens/README.md`; `benchmark/graph_layout_cli.dart` (`--stacks`, the `stacks` phase).
- Tracking: `decisions-review-4-10-to-4-13.md` (`### 4.13`, 16 rows), `deferred-work.md` ("Surfaced in Story 4.13", 6 items), `sprint-status.yaml` (4-13 → done), `epics.md` (Delivered note), `epic-4-context.md` (4.13 done, the Stacks line), this spec.

**Review findings** (one pass, 33 findings: high 0, medium 0, low 22, false 11, maybe-false 0; details in § Review Triage Log):
- **Patched** (low): the invariants' header-echo check (List identity → element-wise); `buildStackInput`'s range check for ref / working-copy nodes (`ffi.unknown`, as documented); worker-glue tests for the stacks error paths (a corrupt fact → `ffi.unknown` only with stacks, two `@` → V5); `collapsedKeys` and `free` through the real worker; two hand-derived endpoint shapes (a stack → stack edge; a stack as a merge source, where (C)'s δ₂ term holds a row); docs on index order with stack nodes, on bare run keys (no `grp:`) and on what a selected stack contributes to `keepOpenKeys` (+ a decisions row); a corrected cost figure in `deferred-work.md`; `tools/stacks.mjs` creates `inputs/` and keeps `"this"` off split members; `tools/goldens.mjs` fails without a split run in the stack fuzz cases (31 present).
- **Deferred:** none from the review. The spec's six `deferred:` items are five the implementation recorded (D11; the `compact` order's compaction count measured only; the quadratic-pass worst case; `compare.mjs --core` without stacks; no real-repo numbers) and the red `app/` gate steps, added at verification.
- **Rejected:** no stack-node → run accessor (O(R) derivable; 10.17's accessors); stale spec text (would edit this spec); tracking marked done before the commit (committed together); worker-side key-resolution cost (O(n), far below the 28 ms snapshot); `writeStackGrid` duplication (a refactor for a drift only a later format change meets); the real seam's remaining facts (builder-level coverage on the same view type); and the false ones — a positive cycle in an equal-Y group and an unset later-group source (impossible by §4.8's termination argument, checked on every constraint by the harness), mismatched `writeStackGrid` arrays (sized by construction), `time` + stacks in the spike library (the CLI refuses it), the JS jj port as the oracle's ground truth, greedy compaction counts, recordings (10.1's recorder), and the deferred list's records.

**Follow-up review recommended:** false — patched entries: 11 (17 finding rows), all low; 0 medium, 0 high.

**Verification performed:**
- Spike: `dart compile exe` + `dart run test/layout_test.dart` (47 passed); `node tools/stacks.mjs` (exit 0: jj edges == the design's gap walk, default 32 Direct / 4 Indirect / 2 Missing, all 55 Direct; 6 / 7 runs == groupStacks == the Dart binary); `node tools/compare.mjs --digest` (66 identical and invariant-clean); `node tools/fuzz.mjs --cases 300` (all agree); the Rust binary with `--stacks` exits 2; `node tools/goldens.mjs` re-run after the patches — byte-identical; only `goldens/stacks/` and `goldens/README.md` differ from 4.11's goldens.
- AC greps: no `.sort(`, no static/top-level finals, `stacks.dart` imports only `dart:typed_data` and engine files, no `GraphLayout`/`GraphRef` type; `lib/zanshin_core.dart`, `app/`, `crates/`, `schemas/`, the spike's `rust*/` and `coverage-baseline.txt` unchanged; nothing under the spike's `inputs/`/`outputs/` tracked; `epic-4-context.md` newer than every planning file.
- `cargo make test`, twice (before and after the review patches; unpiped, to a log file, waited on with `caffeinate -w`): exit 1 at `test-dart-analyze` (app) — 103 lints, all in `app/lib/src/shared/theme/zanshin_icons.dart`, unchanged since `40a2a58`. Every task after it then ran on its own via `cargo make --allow-private <task>`: all exit 0 except `test-dart-format` (app, the same file); `test-core` 785 tests passed; `coverage-check: OK — coverage held at 99.47% (14553/14631 lines)`; `extern-coverage: OK`. The tasks before the failure (cargo test, clippy, fmt, flutter test) passed in the gate run itself.

**Residual risks:**
- The gate is not green as a whole until Ralph fixes or excludes the regenerated icons file (`deferred:` item 6); nothing in this story touches it.
- D11: a split run's stack can draw its parent edge behind a lower card in its column (recorded, deferred to Ralph / 10.4).
- Not done unattended: real-repo stack numbers (needs a repo path). All Epic 4 stories (4-10 … 4-13) are now done; `epic-4` stays `in-progress` for Ralph's retrospective.
