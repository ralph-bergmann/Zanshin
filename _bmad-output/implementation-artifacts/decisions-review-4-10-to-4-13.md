# Decisions taken for Stories 4.10–4.13 — for Ralph's review

*(Created 2026-09-30, console session. Ralph asked for Stories 4-10 to 4-13 to be built unattended, one
`bmad-build-auto` subagent per story, and chose: "Empfehlungen übernehmen" — take the recommended option for
every open question marked "(Ralph)"; where a question has no recommendation, keep the status quo. Every
answer below can be overruled at review. Source: `_bmad-output/planning-artifacts/epics.md`, each story's
"Open questions (Ralph)" and the inline "until Ralph decides / confirms" markers.)*

**Build order:** 4-10 → 4-12 → 4-11 → 4-13, by dependency: 4.12 needs 4.10; 4.11's layout command (item 9)
needs 4.10 + 4.12 and its dumper switch (item 10) needs 4.10; 4.13 needs 4.11 + 4.10.

**How to read the tables:** *Basis* is `recommended` (the story recommends it), `proposal` (the story or the
sprint-status entry proposes it), `status quo` (no recommendation; the current state is kept), or `measured`
(the story decides it by a measurement the run makes). *If overruled* names what would change.

## Story 4.10 — graph topology + op-pinned content

| # | Question | Answer taken | Basis | If overruled |
|---|---|---|---|---|
| OQ 1 | Timestamps: flag loaded per call (b), always on (a), per-handle Rust cache (c), Dart cache (d), small revsets only (e)? | **(b)** `with_timestamps` flag, loaded per call; no Rust state on the handle. (c)'s trigger (a first timestamped call > ~50 ms on a packed store, or accumulating loose commits) is recorded with the bench numbers. | recommended | (c) adds handle state, an ADR-0002 Addendum clause, a bound decision and a cache witness. |
| OQ 2 | Committer or author timestamp? | **Committer** (what `jj log` shows, what the spike's inputs use). | status quo | A field switch in `graph_topology`, the dumper and the goldens. |
| OQ 3 | Content-call framing: continuation of the topology call's `jj log`, or its own `jj --at-op` command? | **Continuation of `jj log`:** no precondition, snapshot, import, config load or 9.37 fix-up; no operation or op head written; no precondition/warnings on its envelope. | recommended | `--at-op` framing would add start-up config resolution + secure-config fix-ups per page. |
| OQ 4 | ADR-0002 Addendum for the pinned read — agreed? | **Yes**, the pinned read only (no cache clause, since OQ 1 = (b)). Placed next to `## Addendum 2026-09-23`, accepted text not rewritten. | proposal | — |
| OQ 5 | Vanished operation: new `jj.operation_not_found` or a reused code? | **New `jj.operation_not_found`**, CLI text `No operation ID matching "<id>"`. | proposal (sprint-status 4-10) | Reusing a code removes one row from `docs/rust-error-codes.md` + one `envelope.rs` constant. |
| OQ 6 | Anchors: required pass-through list, pre-fill `["trunk()", "present(@)"]` exported by zanshin_core? | **Yes**, a required parameter, no Rust default; the pre-fill is a documented zanshin_core constant. | recommended (follows 4.11 OQ 1) | — |

## Story 4.12 — topology wire + lazy Dart view

| # | Question | Answer taken | Basis | If overruled |
|---|---|---|---|---|
| OQ 1a | The old lane path: remove the slice extern + `zanshin-graph` crate, keep the crate without FFI (b), or keep all (c)? | **Remove** `zanshin_graph_slice`, `graph_slice_to_envelope`, the `GraphSlice`/`GraphRow`/… tables, the Dart slice models + `graphSlice`, and the `zanshin-graph` crate. `GraphTopology` takes `GraphSlice`'s union slot. `EXPECTED_EXPORTS` stays 61. | recommended | Recoverable from git history; (b)/(c) keep a second graph contract alive. |
| OQ 1b | Does `Repo::walk_graph` stay as zanshin-jj's `jj log`-faithful read once nothing calls it? | **Keep it** (with its tests and the `graph_blueprint` bench). | status quo | Removing it is a small follow-up delete. |
| OQ 2 | Ids: display strings (a) or fixed-stride bytes + Dart formatting (b)? | **Decided by the run's measurement** (payload bytes, Rust build, Dart first access); (b) expected. The numbers and the choice are appended below by the 4-12 run. | measured | — |
| OQ 3 | Missing edge target: drop the commit id, or keep it? | **Drop** it (the CLI never prints it; the layout ignores it). | recommended | One optional string vector more on the wire. |

## Story 4.11 — Dart layout engine on the worker isolate

Already decided before this run (2026-09-27): modes `free` (default) + `compact`; orders `compact` (default)
+ greedy; `time`, Time+gaps and `optimized` dropped and not ported; `nowMs` goes.

| # | Question | Answer taken | Basis | If overruled |
|---|---|---|---|---|
| OQ 1 | Priority source: the anchors rule, `jj log` order only, `log-graph-prioritize`, or bookmarks? | **Anchors rule** (item 6): class 0 = anchor 0 + first-parent chains, class 1 = anchor 1 + chains up to class 0, class 2 = the rest; ties by `jj log` order. Dated SPEC §11.2 amendment. | recommended | A SPEC amendment + regenerated goldens; the design's hand-set ranks stay unreproducible either way. |
| OQ 2 | Repeated targets: kept edge `direct` if any duplicate is direct, or first occurrence unchanged? | **`direct` if any is direct**, one layout edge per (child, target) at the first position. Dated SPEC §2 amendment; V3 stays. | recommended | Builder + dumper rule + goldens. |
| OQ 3 / 8 (stability) | Lane-order stability hint (item 7; for `compact` now): build a seeded rule, or ship without? | **Ship without.** Item 7's hint is not built; 10.12 records column changes across reloads instead of gating them. | status quo ("until Ralph confirms") | Build item 7's hint as a later story (SPEC §11.5 amendment + typed-data hint transport). |
| OQ 4 | Blocked-merge routing (D9) and free-mode buses (D8): keep unchanged? | **Unchanged.** | status quo ("until Ralph decides") | A fix is a SPEC amendment + goldens in the engine. |
| OQ 5 | SPEC's home: `docs/graph-layout.md`, or stay in the spike? | **`docs/graph-layout.md`**; the spike's `SPEC.md` becomes a pointer. | proposal | Move it back; one SPEC either way. |
| OQ 6 | Day boundaries: fixed offset per layout (D7), or DST-exact local midnights? | **Fixed offset per layout (D7).** | status quo | A SPEC amendment in the spike's Dart + Rust reference, goldens. |
| OQ 7 | Exact lane-order search for L ≤ 8? | **Moot** (`optimized` dropped). | — | — |
| OQ 8 (budget) | 10k+: a larger/time-based budget, or greedy painted first and `compact` swapped in? | **Neither in this story:** the 2,000,000 budget stays a request parameter (default unchanged); no greedy-first pair. 10.5 can add it. | status quo | A second request per layout above a threshold (10.5 item 2). |
| OQ 9 | Free's day buckets: engine emits one `day` bucket per local day of T in `free`, or the worker returns (row, day) pairs? | **The engine emits them.** `utcOffsetMin` stays a `free` input; dated SPEC §2/§3/§7.3 I5 amendments, implemented in the spike's `dart/` **and** its Rust reference before the goldens. | recommended | Revert the amendments; the worker returns sorted (row, day) pairs instead. |

**Not done unattended (open for Ralph):** item "Manual check, once" — `flutter run` on Zanshin, edit the gap
function and one tunable constant, hot reload, confirm the relayout uses the new code. The 4-11 run records it
as open in its spec. The optional local real-repo numbers (4.10 item 8, 4.11 dev tools, 4.12 item 1) need a
path to one of your repos; the runs skip them unless a path is given.

## Story 4.13 — commit stacks

The story lists no blocking question; its proposals were accepted on 2026-09-28 (tags and other workspaces'
working copies break a run, conflicts do not; runs of mutable ancestors of @ start expanded; in `free` a stack
sits at its newest member's time).

| # | Question | Answer taken | Basis | If overruled |
|---|---|---|---|---|
| Item 4 | Row constraints | **The proposal:** one longest-path constraint per pair of adjacent segments in a column, following the ungrouped y order; the SPEC amendment states the rule with a termination argument. | proposal | — |
| Item 5 | Output shape | **The proposal:** per-node arrays stay topology-indexed; collapsed members flagged hidden, no position; stack nodes appended after n. | proposal | A different result-view layout (10.17 reads it). |
| Tests | Run-rule oracle sample | **The 52-commit sample at `e243dd2`** (reaches the gap cases), after checking that the design's gap walk yields jj's edges there; the hand-built gap cases stay. Fallback if the check fails: the 36-commit sample at `a399daf` + the hand-built cases. | proposal (2026-09-30 note) | — |

## Taken during the runs

*(Each run appends here any further decision it had to take — a question it met that this file does not
answer — with the option taken and its basis, under its story's heading.)*

### 4.10

| Question | Answer taken | Basis | If overruled |
|---|---|---|---|
| Error text for a hex id that is not full length (the CLI resolves prefixes, so it has no such text) | Zanshin's own `Operation ID "<x>" is not a full operation ID` / `Commit ID "<x>" is not a full commit ID` (both `jj.invalid_input`); the CLI's `Operation ID "<x>" is not a valid hexadecimal prefix` stays for an empty/non-hex operation id, and an empty/non-hex commit id gets the same wording, `Commit ID "<x>" is not a valid hexadecimal prefix`. | status quo (no prefix resolution, per the story) | Change the strings in `crates/zanshin-jj/src/commit_content.rs`. |
| How the topology reports a Direct/Indirect target outside its node set | A new public `RevsetError::DanglingEdge { target }`; `zanshin-ffi`'s `map_lane_stream_err` maps it to `graph.dangling_edge`, the two other exhaustive mappers (`commit_views.rs`, `mutate.rs`) to their `Backend`. Unreachable through jj-lib; pinned by unit tests. | the story's "`graph.dangling_edge`, as in `walk_graph`" | Fold it into `JjLibError` and drop the three arms. |
| Option (c)'s trigger | Measured, not acted on: the FIRST timestamped topology call on a fresh handle is 53 ms (median) at 10k packed (> ~50 ms), ~1.04 s on the loose fixture. Recorded in `deferred-work.md` ("Surfaced in Story 4.10") for Ralph; nothing built. | measured | Build (c) or (d) as a follow-up story. |
| Memoising the pinned repo (the Non-goals' "only if `load_operation` + `load_at` dominates a page") | Measured, not decided: the pinned load is ~45 % of a 60-id page at 10k packed (~51 % with a changed-path index), ~28 % loose, ~8 % at 1k. Whether that "dominates" is left to Ralph (`deferred-work.md`); nothing built. | measured | Memoise the pinned `ReadonlyRepo` per operation id (handle state + an ADR-0002 Addendum clause). |

### 4.12

| Question | Answer taken | Basis | If overruled |
|---|---|---|---|
| OQ 2 — ids as display strings `[string]` (a) or fixed-stride raw bytes `[ubyte]` + Dart formatting (b)? Rule: (b) unless (a) wins two of {payload bytes, Rust build, Dart first access} by > 10 % at 10k packed. | **(b).** At large-10k packed (medians, release, M4 Pro): id bytes 360,112 (b) vs 960,224 (a) — 36 vs 96 B/node; Rust build 146 µs (b) vs 175 µs (a); Dart first access (every id read as a `String`) 553 µs (b) vs 565 µs (a, generated `StringReader`; 671 µs ASCII-optimised). (a) wins none; medium and large loose agree. Full tables in spec-4-12 § Measurements. | measured | Switch both id columns to `[string]`, drop the strides, `TopologyIds::encode` and `graph_ids_test.dart`; the view reads strings. |
| Flags — one packed `[ubyte]` or six `[bool]` vectors? Same rule. | **One packed `[ubyte]`** (bit 0 working copy … 5 has_change_offset). At 10k packed: 10,028 vs 60,096 B; Rust build 8.3 vs 46.8 µs; Dart first access 25 vs 46 µs — the six vectors win none. | measured | Six `[bool]` vectors and a presence `[bool]` for the change offset. |
| `RepoHandle.graphTopology`'s Dart signature | `prioritize` / `shortPrefixes` keep `graphSlice`'s builtin pre-fills as defaults; `anchors` and `withTimestamps` are **required** (no default); `defaultSyntheticElided` is removed (it only pre-filled `graphSlice`; the topology call takes no such parameter). | the spec's Design Notes ("Taken during this run"); 4.10: the anchors pre-fill "is not applied by anything", the timestamp cost is the layout mode's call | Give `anchors` the `defaultGraphAnchors` default and `withTimestamps` a `false` default in `packages/zanshin_core/lib/src/worker/handle.dart`. |
| How far `GraphTopologyView` validates a buffer (review finding, 2026-10-01) | **Presence, length and bounds** of every vector (plus `operation_id`, `refs`, `working_copies`) at construction → `ffi.unknown`; an unknown edge-kind byte → `ffi.unknown` on access. **Not checked** (the Rust builder guarantees them; the cdylib ships with the bridge): CSR monotonicity, `edge_start[0] == 0`, target / anchor node ranges, the refs' node order, an unknown `TopologyRefKind` byte (the generated reader throws `StateError`). `GraphTopologyView.bytes` is exposed read-only. | review triage: guards for a buffer only a broken producer can write were rejected | Add O(n + E) value checks in `GraphTopologyView.fromEnvelope` if 4.11's input builder wants a validated buffer. |

### 4.11

| Question | Answer taken | Basis | If overruled |
|---|---|---|---|
| Anchor lists of any length, not just item 6's two | The generalised rule (docs/graph-layout.md §11.2): with A anchors every node starts in class A; anchor k (ascending) and its first-parent chains take class k up to the first node of a class ≤ k; with `[trunk(), present(@)]` it is exactly item 6 (0 trunk chain, 1 @ chain, 2 the rest); no anchor → every node class 0. | the spec's Design Notes ("Taken during this run" 1) | Restrict `anchors` to two entries and reject others. |
| Free day-bucket membership | Every non-`is_root` node by its clamped T (a null-ts non-root node counts by its T); the root is in no bucket; ranges are the members' min/max y and may meet (end = next start). | the spec's Design Notes (2); the spike viewer's reading | Change step 4 of §4.2 free + both references + the goldens. |
| Names and the request's defaults | `GraphGridView` (result view), `GraphLayoutCommand` / `GraphLayoutResult` (worker-internal), `LayoutContractException`, `LayoutMode` / `LaneOrder`; `RepoHandle.graphLayout` returns `({topology, grid})`; `mode` / `order` / `budget` default to the pre-fills (free, compact, 2,000,000), `utcOffsetMin` is required. None is exported from the barrel (10.12 does). | the spec's Design Notes (3) | Rename in `lib/src/graph_layout/` + `worker/`. |
| How a contract violation crosses | As the `LayoutContractException` object in `GraphLayoutResult` (no new error code); the topology's own error comes first. | the spec's Design Notes (4) | A `graph.layout_contract` error code in `docs/rust-error-codes.md`-style registry. |
| Golden hash | FNV-1a 64, hand-written in `tools/goldens.mjs` (BigInt) and the test support (no new dependency); 100 seeded fuzz cases (`genInput(rng(411 · 1,000,003 + k))`). | the spec's Design Notes (5) | A SHA hash via a new dev dependency. |
| Corrupt topology values the input builder meets (an edge-kind byte other than 0/1/2, an anchor node ≥ n) | `ffi.unknown` `ZanshinFfiException`, as `GraphTopologyView` treats corrupt buffers; in the worker such a reply carries no grid and no violation, and the caller's decode re-runs the builder on the same bytes to raise the same error (no new reply field). Out-of-range edge targets are copied verbatim and named by the engine's V1/V2. | taken during this run (the spec names only the edge-kind case) | Ignore an out-of-range anchor node, or add an error field to `GraphLayoutResult`. |
| `decodeGraphLayoutReply` is `@visibleForTesting` but production needs it | The codebase's convention: the `@visibleForTesting` wrapper for tests, `decodeGraphLayoutReplyInternal` for `isolate.dart` (a `@visibleForTesting` member may not be called from another `lib/` library). | taken during this run (precedent: `decodeEnvelopePrecondition` / `…Internal`) | Drop the annotation. |
| How far `GraphGridView.fromBytes` validates | The header (version, mode / order codes, the unit matching the mode, non-negative counts) and every array's count, 8-alignment and bounds (no array inside the header); never the values (enum codes), like `GraphTopologyView`. `copied` is a `@visibleForTesting` field. | taken during this run | Add O(n + E) value checks. |
| The product CLI's bench phases | `parse` = JSON parse + V1–V4 (as the spike's); the engine's own V1–V4 pass then runs inside `layering`. | taken during this run (the engine entry validates first, per the spec) | Time the engine without its validation (a second, unvalidated entry). |
| Goldens for the budget's "stop the search" at a non-default budget | The spike's Dart CLI takes `--budget B` (docs/graph-layout.md §6, dated 2026-10-01; `computeLayout` / `orderLanes` / `compactColumns` take it, default unchanged; the Rust binary has none). `tools/goldens.mjs` writes three `design/<input>.<mode>.compact.budget-<N>.json` goldens (`design-all` compact N = 20, `design-all` free N = 90, `design-default` free N = 40), each checked to differ from the default budget's and from greedy's output; `golden_test.dart` lays them out with the product engine at those budgets. The committed fixtures cannot serve: their search ends inside the first window, which even budget 0 evaluates. | taken during this run; recorded by its review pass (2026-10-01) | Drop the three goldens and `--budget`; a non-default budget then rests on the worker test's budget-0 case alone. |
| Review pass (2026-10-01): what the closing run fixed, deferred or rejected | Fixed: tests for a non-default `anchors` pass-through, a `graphLayout` after the worker closes, an anchor chain into an out-of-range target, two out-of-range edges to one target, an unknown parent kind; the product CLI names an unknown command before parsing flags; `writeGraphGrid` is `@internal`; §6 documents `--budget`. Deferred (deferred-work.md "Surfaced in Story 4.11"): the barrel-export hand-off to 10.12, engine rules in project-context.md. Rejected with reasons: the spec's Review Triage Log. | the review pass's triage (spec § Review Triage Log) | — |

### 4.13

| Question | Answer taken | Basis | If overruled |
|---|---|---|---|
| The run-rule oracle sample | **`e243dd2`** (52 commits): a port of jj-lib 0.44's `RevsetGraphWalk` semantics gives the design gap walk's edges on both revsets (default 32 Direct, 4 Indirect, 2 Missing; all 55 Direct); its `groupStacks` finds 6 / 7 runs, equal to the engine's. `tools/stacks.mjs` re-runs the check and refuses to write the oracle otherwise (fallback `a399daf`). | the 2026-09-30 proposal; check passed | Fall back to the 36-commit sample at `a399daf` + the hand-built gap cases. |
| The exact row rule (item 4) | The least solution of (E) edges, (F) `free`'s walk gaps and (C) one constraint pair per two adjacent segments of a column, computed by a level sweep in the ungrouped visit order; §4.3's reservation restricted to the segment's cards and its merges (pos ≥ 1); the continuation child in another column is dropped (docs/graph-layout.md §4.8 step 6, with the termination argument). | the item 4 proposal, made exact | Another constraint set; the invariants test checks the least solution literally. |
| A split run's stack node | Reserves its column from its own card (D11), so that collapsing never grows `rows`; its parent edge may pass behind a lower card. | taken during this run | Reserve from one pitch above the parent (§4.3) and accept a growing `rows`. |
| `free` between kept nodes | The sums of the ungrouped walk's gaps (X), a stack node at T(m_k) and X(m_k): the gap curve is not subadditive under integer rounding, so recomputing gaps over the kept nodes could lift nodes above y. | taken during this run | Recompute the gaps over W′ (then y′ ≤ y no longer holds). |
| A key in both `expanded` and `collapsed` | Expanded (EX wins); `keep_open` wins over both; a key naming no run's oldest member (no member for `keep_open`) changes nothing. | taken during this run | Swap the precedence in §4.8 step 3. |
| Runs' order and the stack nodes' numbers | By newest member index ascending; stack nodes n, n + 1, … in that order. | the item 5 proposal, made exact | Another order (10.17 reads it). |
| The output shape | Grid format version 2 only with a stack request, version 1 byte-identical otherwise; a hidden member is −1 in the node arrays and `null` in JSON; the run arrays are a CSR over topology indices; `GraphGridView`'s run arrays are `null` without stacks (null for absence), its counts 0. | the item 5 proposal + Ralph's null-for-absence rule | One format for both (every grid version 2). |
| The spike's interface | Facts in the §2 input (read only with `--stacks`), the request via `--stacks <file>`; the Rust binary rejects the flag (exit 2), no Rust change; `--stacks` with `--mode time` is a usage error (no stack rule for `time`). | taken during this run | Stacks in the Rust reference too. |
| `stacks` on `RepoHandle.graphLayout` | Defaults to `false`, the key lists to empty: the "Group stacks" switch's own default is 10.7's. | taken during this run | Default `true`. |
| Key resolution | Through the topology's id lookups by 10.1's key rule: a change id names its non-hidden, non-divergent node; a commit id names its node only when that node is hidden or divergent. | 10.1 item 2 | — |
| The default-expanded walk | From this workspace's `@` through layout parents whose `immutable` is false (other workspaces' working copies do not count). | the 2026-09-28 proposal, made exact | Walk from every workspace's working copy. |
| `lanes` with stacks | The ungrouped value. | Ralph 2026-09-28 (columns never change) | — |
| The design sample's compaction count (`compact`, greedy, every run collapsed) | all 19 → 15 (as planned); **default 9 → 8**, not the planning estimate 9 → 7: a column constraint binds at sxmtvqno (zqklmwts's reservation must start above mrplxqwv's), re-derived by hand in §4.8. With the `compact` order the counts are 19 → 16 and 9 → 8 (measured only). | re-derived by hand, as the spec asked | — |
| Passes inside a group of equal Y | Alternate their direction (it changes the number of passes, never the least solution); an `assert` holds the bound of the group's size + 1 passes in tests. | taken during this run | Always forward (quadratic for long δ = 0 chains against the visit order). |
| The benchmark inputs' facts | `node tools/stacks.mjs facts <in> <out>`: key `k<i>`, the older half immutable, parent_count = the parent entries, has_ref for one node in 17, node 0 this workspace's `@`, one in 211 another's. | taken during this run | Other synthetic facts. |
| Run keys on the request | Bare key(m_1) by 10.1's rule, no `grp:` prefix (a caller reads it as the key of `runMembers[runStarts[k]]`); a selected collapsed stack contributes no keep-open key (its card is no node). | taken during this run's review pass | Prefix the run keys and strip the prefix in the resolver. |

### 4.14

| Question | Answer taken | Basis | If overruled |
|---|---|---|---|
| The joint packing's visit order | Pack twice, by (y_c, priority, i) and by (y_f, priority, i), keep the packing with fewer lanes, `compact`'s on a tie (docs/graph-layout.md §4.3, amended 2026-10-27). It matches the export `e74ced3`'s greedy candidates (default 8, all 9 lanes on the `e243dd2` sample). | Claude's proposal (epics.md Story 4.14 item 1), adopted | Pack once in one model's order (another width on some inputs; the oracle check changes). |
| The `compact` order on the joint packing | Windows = connected components of the two columns' segments under "reservations overlap in either model", visited by their least compact start; an exchange stays iff 16·cost_c + cost_f falls; skip a window only if its span meets no kept span in both models; work units per model (§4.7, amended). With one model it is §4.7's order, work units included (spike test). | Claude's proposal (item 2), made exact | Another feasibility or cost (e.g. the compact model only): one SPEC paragraph, the spike, the port, the goldens. |
| How the spike keeps both behaviours | `--columns mode` or `--columns joint` (Dart-only, default `mode`): the per-mode reference stays, so Rust ≡ Dart, `fuzz.mjs`, `bench.mjs` and `js_oracle.mjs` run unchanged; `joint` takes the modes compact and free and the orders greedy and compact only (exit 2 otherwise). | taken during this run | Make joint the spike's default (the Rust comparison then needs the flag off). |
| Where the product goldens come from | All from the spike's Dart binary with `--columns joint`, both orders (the Rust reference packs per mode). The 57f259c design oracle now checks rows and edges only; the lanes moved to the joint oracle (`design/oracle/joint-design-<rev>.lanes.json`). The budget-cut goldens became `design-default` compact N = 20 and free N = 10: with joint columns `design-all`'s search ends inside its first window. | taken during this run | Keep greedy goldens from Rust (impossible: Rust packs per mode). |
| The day key | Per node in both modes, dk of the free model's clamped T at `utc_offset_min`; the root `GraphGridView.noDay` (−2^63); a stack node its newest member's, a hidden member its own. A grid field, not §3 JSON. | taken during this run (I3) | Null-for-absence via a separate presence array, or day keys only in `free`. |
| The grid format | Versions 3 (35-slot header, node day as the 13th array) and 4 (48 slots: v3's + stacks at 35–47); versions 1 and 2 retired and refused (no grid is persisted). | taken during this run | Keep reading 1 / 2 (no reader needs them). |
| Exact colouring (I2) | **Not ported.** The rule (spec Design Notes) needs both: the joint greedy packing wider than GL with exact colouring on a design sample — it is not (8 = 8, 9 = 9) — and a joint mean width > 10 % above the larger per-mode one on some input — true (fixture-medium/large `all()`, greedy: +18–20 % vs the larger per-mode width; +28 % vs per-mode compact in Compact). The first fails. | measured (spec-4-14 § Measurements) | Port GL's exact colouring for ≤ 40 chain heads (it would not change the design samples). |
| The other model's interval test | Per lane a sorted array with prefix maxima; an insert shifts the tail, O(lane size), marked `shortcut:` in the code with its upgrade (an array-backed balanced tree). Measured: the `lanes` phase 43 ms at synth-100k (per-mode 10–15 ms), no pathological case. | taken during this run, measured | Build the balanced tree. |

### 4.15

| Question | Answer taken | Basis | If overruled |
|---|---|---|---|
| The router's input | Raw typed arrays as `GraphGridView` exposes them (rows, cols, U, free, edge from / to / kind) + the topology's `parentCount`; no `GraphGridView` or other engine type in the barrel export. | the spec (Boundaries) | Take a `GraphGridView` (it would join the barrel). |
| Bends and run indexes | The polylines' points are the bends; verticals sorted by x and horizontals by y, zero-length segments dropped, ties in polyline order. | taken during this run | A separate bend array. |
| The bridge window | Half-open [x0, x1) × [y0, y1) on the crossing point; results by horizontal run index, then vertical run index; per crossing both edges and which one breaks. | taken during this run | Closed windows (a crossing on a tile edge would appear twice). |
| Free detours (I2) | §14.2's unit rule (1–12 units off the band blocks a run): the oracle found no run on the 132 design cases that it judges differently from GL's pixel test, so it is not tuned. | the oracle (spec § Measurements) | GL's pixel test in the geometry stage (the class stage would then depend on H). |
| Gutter overflow (I3) | Reported (`overfullGutters`; the edges are derivable from `gutters` + `gutterSteps`), the 9-line budget is not widened: overfull gutters occur only on the synthetic inputs. | measured | Widen the gutter's budget (e.g. a smaller step past 9 lines). |
| Where it runs (item 4) | Decision (g)'s recommendation: both stages on the UI side, class once per layout, geometry per metrics; synchronous up to `routeSyncNodeLimit` = 20,000 visible nodes (the 8 ms point of the slowest measured series, Free on the synth inputs, rounded down to a thousand), `Isolate.run` above; never a worker request. The library has no isolate dependency (10.4 wires it). | the spec's rule, measured | Another frame budget, or always `Isolate.run`. |
| The oracle's difference categories | Equal; or every class / slot difference explained — unit rule (GL's decision vs the same decision under the unit rule, with the cards' unit distances) or shared-entry grouping (`via` vs `parentCount`) — with the remaining geometry differences of that case consequential. Also listed: direct runs the two tests judge differently even when the class ends equal. | taken during this run | Stricter: no consequential differences allowed. |
| Reports per edge | Besides the counts, `fallbackEdges` and `overfullEdges` flag the edges, so the Free gate attributes every card hit (spec Change Log). | taken during this run | Counts only (the gate could not attribute hits). |
| An entry approach at the child's centre | Counts as the right side (GL leaves it without a port); only a heavily stepped gutter line can reach it. | taken during this run | Leave it portless like GL (NaN geometry). |
