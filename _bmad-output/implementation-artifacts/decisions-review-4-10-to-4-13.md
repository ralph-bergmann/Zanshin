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
