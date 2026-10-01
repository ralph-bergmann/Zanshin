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
