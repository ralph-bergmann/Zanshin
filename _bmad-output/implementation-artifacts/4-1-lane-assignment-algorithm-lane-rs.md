# Story 4.1: Lane-assignment algorithm (`lane.rs`)

---
baseline_commit: cdde0d9d5f3e79094668ac907c52a46c5b0b6c55
---

Status: done

<!-- Note: Validation is optional. Run validate-create-story for quality check before dev-story. -->

## Story

As a Rust developer building the commit-graph render backend,
I want `crates/zanshin-graph/src/lane.rs` implementing a **streaming** "straight branches" (pvigier-style) lane-assignment algorithm over topologically-ordered graph nodes,
so that each commit gets a stable lane, deterministic color index, and per-parent edge routing for GitKraken/SourceTree-style rendering (FR-GR-1) — emitted **row-by-row as nodes arrive**, ready for the ADR-0002 lazy-revset-stream wiring in Stories 4.3/4.4.

## ⚠️ Read this first — scope + the reconciliations baked in

This is the **first story of Epic 4** and the first real code in `crates/zanshin-graph` (currently a placeholder `lib.rs` only). Three load-bearing reconciliations shape everything below — the epic's Story 4.1 ACs (epics.md:2687–2755) predate both ADR-0002 and the ACL enforcement, and are **stale as written**:

1. **The input is a topo-ordered node stream, NOT `&Repo` (ADR-0002).** The epic's `assign_lanes(repo: &Repo)` + "jj-lib `dag_walk::dfs_ok` / `DefaultReadonlyIndex`" AC is superseded twice over: (a) ADR-0002 AC-4 (resolved 2026-06-22) decided the graph is derived from a **lazy revset stream** (`stream_graph` + `TopoGroupedGraph`, GG model — full 10k derive ~3.1 ms, first-100 page ~27 µs; Story 3.11); (b) `zanshin-jj` is the **only** production crate allowed to import `jj_lib` (FR-JJ-16, mechanically enforced) — `zanshin-graph` can never call `dag_walk`/`default_index` itself. This story therefore implements lane assignment as a **pure algorithm over crate-owned input types** that mirror the stream's node shape. The jj-lib stream wiring is Story 4.3's job. See [R1](#r1--input-model-repo--dag_walk--topo-ordered-node-stream-adr-0002).

2. **This crate stays dependency-light and fixture-free.** No `jj_lib`, no `zanshin-jj`, no fixtures, no FFI, no FlatBuffers, no codegen, no Dart. The only new dependency is `thiserror` (already a workspace dep). Tests build DAGs in-memory — which is precisely what makes the epic's full test matrix (octopus, many roots, nested forks, ~100 nodes) cheap and deterministic.

3. **The graph is keyed by commit id, not change id.** The stream yields commit ids, and divergent changes (two commits sharing one change id) make change ids ambiguous as DAG keys. See [R2](#r2--row-identity-change_id--commit_id).

Unless Ralph overrides the [Open Questions](#open-questions-recommended-defaults-baked-in), implement the recommended defaults as written.

## Acceptance Criteria

> Reconciled from epics.md Story 4.1 (lines 2687–2755). Stale items are corrected inline and mapped in [Dev Notes › Reconciliations](#reconciliations-stale-epic-acs-corrected).

1. **Module exists.** `crates/zanshin-graph/src/lane.rs` is created and declared in `lib.rs` (module-by-noun; `lib.rs` = re-exports + crate docs only). SPDX-License-Identifier on line 1 of every new file. `#![deny(missing_docs)]` at crate root (zanshin-jj precedent, Story 2-10); every `pub` item doc-commented.

2. **Crate-owned input types** mirror the jj-lib revset-graph stream shape (semantics documented on the types, citing the stream contract — see [Dev Notes › Input contract](#the-input-contract-what-the-stream-guarantees)):

   ```rust
   pub struct GraphNode {
       pub id: String,               // hex commit id (zanshin_jj::CommitId.0 upstream)
       pub parents: Vec<GraphEdge>,  // parent edges, first-parent first
   }
   pub struct GraphEdge { pub target: String, pub kind: EdgeKind }
   pub enum EdgeKind { Direct, Indirect, Missing }
   ```

3. **`Row` output struct** (reconciled — [R3](#r3--row-shape-parallel-arrays-edges_below--parents--merged-rowedge)):

   ```rust
   pub struct Row {
       pub commit_id: String,
       pub lane: u32,
       pub color_idx: u32,
       pub edges: Vec<RowEdge>,      // one per input parent edge, same order
   }
   pub struct RowEdge {
       pub target: String,           // parent commit id
       pub target_lane: Option<u32>, // None ⟺ kind == Missing (no lane to land in)
       pub kind: EdgeKind,
   }
   ```

   `RowEdge` merges the epic's parallel `edges_below: Vec<u32>` + `parents: Vec<ChangeId>` arrays into one aligned struct and carries the edge kind (needed later for dashed elided-edge rendering). `target_lane: None` for `Missing` follows the null-for-absence rule.

4. **Streaming core + collect convenience.** The algorithm is exposed as an incremental assigner **and** a one-shot wrapper:

   ```rust
   pub struct LaneAssigner { /* lanes, reservations */ }
   impl LaneAssigner {
       pub fn new() -> Self;
       pub fn push(&mut self, node: GraphNode) -> Row;          // Row is FINAL at emit
       pub fn finish(self) -> Result<(), GraphError>;           // dangling-edge check
   }
   pub fn assign_lanes(
       nodes: impl IntoIterator<Item = GraphNode>,
   ) -> Result<Vec<Row>, GraphError>;
   ```

   `push` never buffers the graph (O(1) amortized state transition per node; memory = active lanes + open reservations, not O(n)). This is what lets 4.3/4.4 stream the first render page without materializing the graph (ADR-0002). Rows are emitted in input order, exactly one per input node.

5. **Algorithm = "straight branches" (pvigier-style), streaming form.** Normative rules (full spec + worked example in [Dev Notes › The algorithm](#the-algorithm-straight-branches-in-streaming-form)):
   - **Node placement:** a node with ≥1 lane reserved for it takes the **leftmost** reserved lane and all its other reserved lanes are freed at this row (the visual crossover happens at this row). A node with no reservation (a head / new root) takes the leftmost free lane, else appends a new lane.
   - **First-parent continuation (the "straight" rule):** for the node's **first** non-`Missing` parent edge, reserve the node's **own lane** for that parent — even if the parent already holds a reservation elsewhere. A branch's first-parent chain thus stays in its lane until the fork commit; convergence happens at the fork commit's row, never mid-branch.
   - **Non-first parent edges (merge edges):** if the parent already has a reservation, the edge targets the **leftmost existing** reserved lane (no new lane); otherwise reserve the leftmost free lane (else append) for it.
   - **`Missing` edges never reserve a lane** (their target never arrives in the stream); the edge is still recorded in `Row.edges` with `target_lane: None`.
   - **`Indirect` edges are treated exactly like `Direct` for lane purposes** (target IS in the stream and will arrive); `kind` is preserved on the `RowEdge` for the renderer.
   - **`RowEdge.target_lane`** = the lane reserved/targeted for that parent **at this node's emit time** (`Some(node's own lane)` for the first-parent edge). This is final — see [Dev Notes › Row finality](#why-rows-are-final-at-emit-time).

6. **Linear DAG (3 commits)** → all three rows on lane 0; each non-root row has exactly one edge with `target_lane: Some(0)`, kind `Direct`. (Epic AC "edges_below contains [0]".)

7. **Fork-then-merge** (`M{A,B} → A{F}, B{F} → F`): `M` lane 0 with edges targeting lanes 0 and 1; `A` lane 0; `B` lane 1 staying in lane 1 (edge target `Some(1)` — straight); `F` lane 0, lane 1 freed at `F`'s row. Lane count returns to 1 below `F`.

8. **Straight branches:** a branch with many sequential commits before its fork point keeps a single lane for the whole first-parent chain; lanes are never reassigned mid-branch.

9. **Deterministic colors:** `color_idx = lane % PALETTE_SIZE` with `pub const PALETTE_SIZE: u32 = 8`. Same input → identical `color_idx` on every run; same lane always maps to the same color. ([OQ-3](#oq-3-color-assignment--recommend-color_idx--lane--8))

10. **Every input node yields exactly one `Row`, in input order** — this subsumes the epic's "anonymous changes are included" and "working-copy commits are included" ACs: the input model is id + edges, so there is nothing to special-case ([R4](#r4--anonymouswworking-copy-commit-acs--upstream-properties)). Document this on `LaneAssigner`.

11. **Octopus merges (3+ parents):** all parent edges are recorded in `Row.edges` (first-parent rule for edge 0, merge rule for the rest); no panic; lanes remain consistent.

12. **Many roots / disjoint subgraphs:** each new head (node arriving with no reservation) opens its own lane; output well-formed; lanes freed by ended branches are reused (leftmost-free allocation).

13. **Determinism:** `assign_lanes` is a pure function of the input sequence — running it twice over the same input yields identical output (asserted in a test). (Lane stability *across repo mutations* is inherently input-dependent and NOT asserted — see [R5](#r5--stable-across-lane-cache-rebuilds--deterministic-function-of-input).)

14. **`GraphError`** (`thiserror`): a single `DanglingEdge { target: String }` variant, returned by `finish()` when a non-`Missing` reservation was never consumed (the input violated the children-before-parents / target-in-set contract). No other variants — the algorithm itself cannot fail on contract-conforming input. Empty input is valid: zero rows, `finish()` → `Ok`.

15. **Tests** (`crates/zanshin-graph/tests/lane.rs` for the public API + inline `#[cfg(test)] mod tests` in `lane.rs` for private helpers — both count toward coverage):
    - Exact-expectation tests: linear (AC-6), two heads converging ("simple fork"), fork-then-merge (AC-7), nested forks, multiple parallel branches, octopus (AC-11), many roots (AC-12), `Missing` edge (`target_lane: None`, no reservation, no dangling error), `Indirect` edge (lane like Direct, kind preserved), dangling `Direct` edge → `Err(DanglingEdge)`, empty input, color stability (AC-9), determinism double-run (AC-13).
    - **~100-node algorithmic-correctness sub-test** (the WIP replacement for the deleted Story 4.5 perf test): a deterministically-generated ~100-node DAG mixing linear runs, forks, merges, an octopus, and ≥2 roots; asserts structural invariants — one row per node in order; every `target_lane` within the lane vector's bounds; no two open reservations share a lane at any point; every non-`Missing` edge's target eventually emitted; first-parent chains hold their lane; double-run equality. **Correctness, not timing** (no perf assertion — WIP posture).
    - Test names describe scenarios (`fork_then_merge_reclaims_temporary_lane`, not `test_lanes_2`).

16. **`cargo make test` green** (the single quality gate): cargo tests, clippy pedantic `-D warnings` (refactor, don't suppress), rustfmt, `dart` gates untouched, `cargo deny`, **coverage ratchet**. `lane.rs` is a new file → must reach `new_file_floor_pct = 80.00`; commit the auto-raised `coverage-baseline.txt` together with the code. No extern fn ⇒ **no** cross-FFI `zanshin_core` test needed (same as Story 3.5).

## Tasks / Subtasks

- [x] **Confirm the decisions** (AC: all) — read [Open Questions](#open-questions-recommended-defaults-baked-in). If Ralph hasn't weighed in, implement the recommended defaults and note the choices in the Dev Agent Record.
- [x] **Wire the crate** (AC: 1, 14)
  - [x] `crates/zanshin-graph/Cargo.toml`: add `thiserror = { workspace = true }` under `[dependencies]` (workspace dep exists; no version pin needed here). No other deps, no dev-deps.
  - [x] Rewrite `src/lib.rs`: SPDX line 1, `#![deny(missing_docs)]`, crate-level docs (one paragraph: streaming straight-branches lane assignment, ADR-0002 stream model, input contract pointer), `mod lane;` + `pub use lane::{…}`. No logic in `lib.rs`.
- [x] **Implement `lane.rs`** (AC: 2–5, 9–12, 14)
  - [x] Input types `GraphNode` / `GraphEdge` / `EdgeKind` with doc comments citing the stream contract (children-before-parents; Direct/Indirect targets arrive later; Missing never arrives — see Dev Notes for the jj-lib source citations to quote).
  - [x] Output types `Row` / `RowEdge`, `PALETTE_SIZE`, `GraphError` (thiserror, `DanglingEdge`).
  - [x] `LaneAssigner`: `lanes: Vec<Option<String>>` (slot = pending parent id; `None` = free — clear, never remove, so occupied lane indices stay stable) + a reservation lookup (e.g. `HashMap<String, Vec<u32>>` id → reserved lanes, kept sorted so "leftmost" is O(1)). `push` implements the AC-5 rules; `finish` errors on leftover non-Missing reservations.
  - [x] Keep helpers (`alloc_lane`, reservation bookkeeping) as small private fns — unit-testable without building whole DAGs, and the natural clippy-pedantic decomposition.
  - [x] `assign_lanes` convenience wrapper (push-all + finish).
  - [x] Inline `#[cfg(test)] mod tests` for the private helpers (leftmost-free vs append allocation, reservation insert/consume ordering, Missing-edge non-reservation).
- [x] **Implement `tests/lane.rs`** (AC: 6–8, 10–15) — the scenario matrix from AC-15. A tiny local `node(id, &[(target, kind)])` builder keeps cases readable. The ~100-node DAG is generated by a deterministic in-test function (fixed pattern or seeded LCG — NO randomness without a fixed seed, NO fixtures, NO `zanshin-jj`).
- [x] **Run the gate** (AC: 16) — `cargo make test` (unpiped — trust the exit code, per memory); fix clippy/fmt findings by refactoring; verify `lane.rs` coverage ≥ 80 % and commit the raised `coverage-baseline.txt` in the same commit as the code.
- [x] **No registry/docs side-effects** — no new `error.code` (GraphError never crosses FFI in this story → `docs/rust-error-codes.md` untouched); no `.fbs`/codegen; no `docs/ffi-abi.md` change. If any of these seem needed, scope has crept — stop.

### Review Findings

_bmad-code-review 2026-08-22 (4 layers: Blind Hunter + Edge Case Hunter + Verification Gap + Acceptance Auditor; per-finding code read before rating). 30 raw → 16 unique → 2 decision-needed + 13 patch + 1 defer + 8 dismissed. No correctness defect on contract-conforming input; all AC-6..AC-14 exact-expectation tests match hand traces._

- [x] [Review][Decision] **First-parent rule when edge 0 is `Missing` is unpinned** — `push` rustdoc (`lane.rs:157-160`) and AC-5 say "the first **non-`Missing`** edge reserves the node's own lane"; the code routes `index == 0` only (`lane.rs:168`, `route_edge(lane, index == 0, …)`), matching the Dev Notes ("if the first parent is `Missing`, `c`'s lane is simply freed" — stub). For `[Missing, Direct(p)]` the two rules diverge (own lane vs. `p`'s existing reservation / leftmost free lane); no test covers a `Missing` first edge followed by a non-`Missing` one, so either "fix" ships silently. Spec is self-contradictory (AC-5 vs Dev Notes) → decide the semantics, align doc+code+story, add the pinning test. [blind-hunter+edge-case-hunter+verification-gap+acceptance-auditor; severity medium] → **resolved (Ralph, 2026-08-22): the first non-`Missing` edge continues the node's own lane** — AC-5 + rustdoc wording wins; `push` now tracks `own_lane_unclaimed` (a `Missing` edge at index 0 does not consume the continuation; all-`Missing` ends the lane as a stub); Dev Notes step 2 amended; pinned by `missing_first_edge_lets_the_next_edge_continue_the_lane` and the `[Missing, Direct]` sideline merge in the ~100-node DAG.
- [x] [Review][Decision] **Root `Cargo.toml` `[profile.dev.package."*"] debug = false` — undocumented and trade-off only half-considered** — bundled into this change set, listed nowhere (File List, Addendum, sprint-status "Makefile.toml + docs/coverage.md only"), contradicts Dev Notes "no root `Cargo.toml` change". Substantively: it strips file:line from dependency frames (jj-lib/gix) in every test-failure backtrace; the WHY comment rejects only the *profile-level* `debug = "line-tables-only"` (which broke our own crates' `-C instrument-coverage` attribution) and never considers the per-package form `[profile.dev.package."*"] debug = "line-tables-only"` — which by definition excludes workspace members (so our coverage attribution is untouched) while keeping dep backtraces usable. Options: keep as-is / switch to per-package `line-tables-only` (verify via `cargo make coverage`) / drop the change. [blind-hunter; severity medium] [Cargo.toml:52-63] → **resolved (Ralph, 2026-08-22): per-package `debug = "line-tables-only"`** — `cargo make test` verified end-to-end afterwards (coverage held at 98.48 %, no ratchet regression); WHY comment rewritten; pitfall recorded in `docs/coverage.md`; listed in the File List below as infra in the same tree.
- [x] [Review][Patch] Dev Agent Record out of sync with the working tree: File List lacks root `Cargo.toml`, `Makefile.toml`, `docs/coverage.md` (infra changes in the same tree; "Nothing else — no root Cargo.toml change" is now false); Change Log 2026-08-13 still says the cross-FFI coverage step is blocked although the Addendum says the full gate exits 0 → AC-16 status reads ambiguous [_bmad-output/implementation-artifacts/4-1-lane-assignment-algorithm-lane-rs.md:226,293-300,307]
- [x] [Review][Patch] `GraphNode`/`parents` contract doc over-promises "one edge per parent, first-parent first": jj-lib splices an elided parent's edge list in (0..n `Indirect` edges per parent, `known_ancestors` dedup, `remove_transitive_edges` — verified in jj-lib 0.42.0 `revset_graph_iterator.rs:155-282`); reword to "edges in stream order; edge 0 is the continuation edge" so Story 4.3 inherits no false 1:1 assumption [crates/zanshin-graph/src/lane.rs:50-71]
- [x] [Review][Patch] `LaneAssigner` doc claims "O(1) amortized" per `push`; `alloc_lane` is an O(active lanes) scan (the story's own Dev Notes say O(L)) — fix the wording [crates/zanshin-graph/src/lane.rs:120-121]
- [x] [Review][Patch] Module doc calls gitamine a "`jj log`-style" renderer; `jj log` uses Sapling's renderdag and the story says CLI graphlog is terminal UX we replace — say "GUI commit-graph renderers such as gitamine" [crates/zanshin-graph/src/lane.rs:7-8]
- [x] [Review][Patch] Crate doc pre-decides that `zanshin-jj` "owns mapping the real stream into these types (Story 4.3)" — the story explicitly leaves the mapping owner (zanshin-graph→zanshin-jj dep vs. aggregator in zanshin-ffi) to 4.3; soften [crates/zanshin-graph/src/lib.rs:13-14]
- [x] [Review][Patch] AC-10 asks that the one-row-per-input-node / input-order / nothing-special-cased guarantee be documented **on `LaneAssigner`**; it lives only on the crate doc + `assign_lanes` [crates/zanshin-graph/src/lane.rs:118-126]
- [x] [Review][Patch] The public streaming API is never exercised directly: `tests/lane.rs` doesn't import `LaneAssigner`; `push`/`finish` are reached only via `assign_lanes` — add an incremental push→assert→push→finish test (AC-4's primary API) [crates/zanshin-graph/tests/lane.rs]
- [x] [Review][Patch] ~100-node checker never asserts its own end state (`id_promised_lanes`/`lane_promised_to` empty) — AC-15's "every non-`Missing` target eventually emitted" is enforced only by the unit-under-test's `finish()` [crates/zanshin-graph/tests/lane.rs:385-443]
- [x] [Review][Patch] ~100-node checker bound `lane <= max_lane` derives `max_lane` from row lanes only; a merge-edge lane that never hosts a row (`M{X,P}, X{P}, P{}` → lane 1 is a target_lane but no row's lane) false-fails on valid DAGs — replace with a sound bound or drop (the promised-lane check already covers AC-15's intent) [crates/zanshin-graph/tests/lane.rs:396,431]
- [x] [Review][Patch] ~100-node DAG uses `Direct` edges only (no `Indirect`/`Missing` at scale), never asserts `dag.len() >= 100`, and the builder doc ("forks that merge back a few commits later") doesn't match the five long-lived branches merged sequentially at the tip [crates/zanshin-graph/tests/lane.rs:348-382]
- [x] [Review][Patch] Missing contract-edge tests: dangling `Indirect` → `DanglingEdge`; parent-before-child input surfaces as `DanglingEdge` (pin it); `Missing` first edge followed by a new head proves the lane is freed and reused (write after the Decision above) [crates/zanshin-graph/tests/lane.rs]
- [x] [Review][Patch] `parallel_branches_hold_their_lane_when_interleaved` (AC-8) asserts lanes + two edges instead of full rows — assert complete rows to lock in straight-branch routing [crates/zanshin-graph/tests/lane.rs:151-165]
- [x] [Review][Patch] The coverage pitfall "`[profile.dev] debug = "line-tables-only"` breaks `-C instrument-coverage` line attribution for our own crates → false ratchet regressions" exists only as a `Cargo.toml` comment; record it in `docs/coverage.md` (only if the Decision above keeps a profile tweak) [docs/coverage.md]
- [x] [Review][Defer] `expect()` in `LaneAssigner::index`/`lane_number` becomes FFI-reachable once Story 4.6 wraps `assign_lanes` (project rule: no `expect` on FFI-reachable library paths); infallible in practice (u32→usize on 64-bit; >4·10⁹ lanes impossible) [crates/zanshin-graph/src/lane.rs:256-262] — deferred, not FFI-reachable until 4.6

_Dismissed (8): `debug_assert!`s in `reserve`/`place` (invariant holds by construction — impossible-scenario guard); 2 `String` clones per non-Missing edge (ADR-0002 budget trivially met; premature); Makefile `rm -rf` now wipes the workspace-root native-assets dir (intended belt-and-suspenders; concurrent coverage + `flutter run` is not a supported workflow); asserting `GraphError`'s Display text (tests thiserror); `row`/`node` helper names shadowed by loop vars (cosmetic); `DuplicateNode`/`OutOfOrder`/`MissingTargetArrived` error variants + a `seen` set (AC-14 pins the single variant; a seen-set breaks AC-4's O(active) memory; contract is the upstream stream's; out-of-order already surfaces via `finish()`)._

## Dev Notes

### What this story is, in one paragraph

A pure, dependency-light algorithm module: given the commit graph as a topologically-ordered sequence of `(commit id, parent edges)` nodes — exactly the shape jj-lib's `TopoGroupedGraph` stream yields — assign each node a lane, a palette color index, and per-parent edge targets, emitting one final `Row` per node **as it arrives**. No repo access, no jj-lib, no FFI, no fixtures. The jj-lib stream that feeds it (Story 4.3), the FlatBuffers payload (4.2/4.6), and the revset/`prioritize_branch` parameters (4.3/4.4, FR-JJ-17 pass-through) are all downstream.

### Why the epic's `assign_lanes(repo: &Repo)` signature is unbuildable as written

- **ACL:** `zanshin-jj` is the sole `jj_lib` importer (FR-JJ-16; `test-jj-adapter-hygiene` gate). The epic's "iterates via jj-lib's `dag_walk::dfs_ok`… uses `jj_lib::default_index::DefaultReadonlyIndex`" would require `zanshin-graph` to import `jj_lib` — hard-banned.
- **ADR-0002 AC-4 (resolved 2026-06-22):** the graph is **streamed** from a lazy revset (`stream_graph` + `TopoGroupedGraph`, GG model), re-derived on op-id advance, **no materialized cache**. `dag_walk`/`default_index` was the pre-ADR plan. The measured numbers: full 10k derive ~3.1 ms, first-100 page ~27 µs — lane assignment must add only O(1)/node to keep those properties (ADR-0002: "lane-number assignment adds O(1)/node, expected negligible").
- Consequence: 4.1 = pure algorithm over crate-owned types; 4.3 = the jj-lib stream (inside `zanshin-jj`) + the mapping into these types. Who owns the mapping (zanshin-graph depending on zanshin-jj vs. the aggregator mapping in `zanshin-ffi`) is **4.3's create-story decision, not 4.1's** — nothing in this story precludes either.

### The input contract (what the stream guarantees)

The runnable blueprint is `crates/zanshin-jj/benches/graph_blueprint.rs` (Story 3.11) — read it before implementing. The pipeline is `ResolvedRevsetExpression::…evaluate(repo)?.stream_graph()` wrapped in `TopoGroupedGraph::new(…)`, yielding `GraphNode<CommitId> = (CommitId, Vec<GraphEdge<CommitId>>)` per node ([graph_blueprint.rs:125-128]). Contract properties this algorithm may rely on (document them on the input types):

1. **Topological order, children before parents.** `TopoGroupedGraph` is a DFS from the heads that groups branches: "At fork point, the other descendant branches will be visited. At merge point, the second (or the last) ancestor branch will be visited first" — practically the same ordering as Git's `git log --topo-order` [Source: jj-lib 0.42.0 `src/graph.rs:120-131` (vendored at `~/.cargo/registry/src/*/jj-lib-0.42.0/`)].
2. **Edge kinds** [Source: jj-lib 0.42.0 `src/default_index/revset_graph_iterator.rs:38-69`]:
   - `Direct` — the parent is in the revset; it WILL arrive later in the stream.
   - `Indirect` — the direct parent is elided (filtered out of the revset); the edge points at the **closest ancestor that is in the set**, which WILL arrive later. Renderers draw these dashed; for lanes, identical to `Direct`.
   - `Missing` — the edge leads **outside** the set; the target will **never** arrive. No lane may be reserved for it.
3. **No duplicate nodes** — each commit is emitted exactly once.
4. **This is the same pipeline `jj log` uses** (`../jj` @ v0.42.0, `cli/src/commands/log.rs:225`: `TopoGroupedGraph::new(revset.stream_graph(), |id| id)`), so Zanshin's row *order* inherits `jj log`'s observable order — the behavioral-parity part (NFR-R-2). The lane *drawing* itself is GUI UX and explicitly NOT a CLI-parity concern (the CLI's `graphlog`/renderdag ASCII style is terminal UX we replace).
5. **Branch prioritization is upstream.** `jj log` seeds the order via the `revsets.log-graph-prioritize` config (`log.rs:186,229` → `topo_order.prioritize_branch(…)`) — a CLI-applied, user-editable default. Which branch lands in lane 0 is therefore decided by the input order that 4.3/4.4 produce (pass the parameter through per FR-JJ-17); this algorithm just assigns lane 0 to the first branch it sees.

Violations of (1)/(2) (a `Direct`/`Indirect` target that never arrives) are what `finish()`'s `DanglingEdge` catches — cheap (leftover-reservation check), honest (surfaces a broken upstream filter instead of silently mis-rendering), and the only failure mode the epic's `Result` return actually has.

### The algorithm ("straight branches" in streaming form)

Reference: pvigier, *Drawing Commit Graphs* (<https://pvigier.github.io/2019/05/06/commit-graph-drawing-algorithms.html>) — the epic's named strategy; implemented in gitamine. Adapted here to single-pass streaming (no look-ahead, no J(c) forbidden-lane refinement — see [R6](#r6--pvigiers-jc-forbidden-lanes-refinement-dropped-for-wip)).

**State:**

- `lanes: Vec<Option<String>>` — index = lane number. `Some(id)` = lane reserved for pending node `id` (an edge is running down this lane toward `id`); `None` = free. Slots are cleared, never removed (removing would shift every lane to the right — pvigier's nil-slot rule).
- A reservation index (id → sorted lane list) so "does this parent already have a lane / leftmost reservation" is O(1)–O(log k).

**Per node `c` (streaming, in input order):**

1. **Place `c`:** if lanes are reserved for `c.id` → `c.lane` = leftmost such lane; free ALL other lanes reserved for `c.id` (they converge into `c` — the crossover renders at `c`'s row). Else (head/new root) → `c.lane` = leftmost `None` slot, else `lanes.push(...)`.
2. **Route edges** (in `c.parents` order, producing `Row.edges` aligned 1:1):
   - The **first non-`Missing`** edge (review decision 2026-08-22: a `Missing` edge at index 0 does not consume the continuation — AC-5 wording wins): reserve `c`'s own lane for the target (overwrite the slot `c` just vacated-by-occupying — the branch continues straight down). `target_lane = Some(c.lane)`.
   - Every later non-`Missing` edge: target already reserved → `target_lane = Some(leftmost existing reservation)`; not reserved → allocate (leftmost free, else append), reserve, `target_lane = Some(new lane)`.
   - Kind = `Missing` (any position): record `target_lane = None`; reserve nothing. If **every** edge is `Missing`, `c`'s lane is simply freed (no continuation) — the branch visually ends in a stub.
3. **Emit** `Row { commit_id, lane, color_idx: lane % PALETTE_SIZE, edges }`. The row is final (below).

**`finish()`:** any remaining `Some(id)` reservation ⇒ `Err(GraphError::DanglingEdge { target: id })` (report one; which one is unspecified). All-`None` ⇒ `Ok(())`.

**Worked example — fork-then-merge (AC-7), stream order `M, A, B, F`** (`M` merges `A` + `B`; both branch off `F`):

| node | reservations before | placement | edges emitted | reservations after |
|------|--------------------|-----------|---------------|--------------------|
| `M{A,B}` | — | no reservation → lane 0 | `A`: first parent → reserve lane 0 → `Some(0)`; `B`: merge edge, unreserved → alloc lane 1 → `Some(1)` | 0→A, 1→B |
| `A{F}` | 0→A | takes lane 0 | `F`: first parent → reserve lane 0 → `Some(0)` | 0→F, 1→B |
| `B{F}` | 0→F, 1→B | takes lane 1 | `F`: first parent → reserve **own** lane 1 (straight rule — even though F already holds lane 0) → `Some(1)` | 0→F, 1→F |
| `F{…}` | 0→F, 1→F | leftmost → lane 0; lane 1 freed **here** | … | 0→…, 1 free |

Branch `B` stays visibly in lane 1 all the way down to `F`'s row; the two edges converge AT `F` (the epic's "merge point closes the temporary lane and returns to lane 0" — note the epic phrases it bottom-up/chronologically; in stream order the temporary lane opens at the *merge commit* and closes at the *fork commit*).

**Complexity:** O(n + m) amortized (n nodes, m edges); worst-case O(L) per node for leftmost-free scans (L = concurrently active lanes, small in practice). No full-graph rescans, no O(n²) — the ~100-node test guards gross correctness, ADR-0002's numbers guard the budget (soft, no perf assert in WIP).

### Why rows are final at emit time

Every `target_lane` is knowable when the child is emitted: first-parent edges target the child's own lane (just decided); merge edges target an existing or freshly-allocated reservation (decided now). A reserved lane cannot be reassigned until its pending node arrives (reservations occupy slots), and when a parent with multiple reservations picks the leftmost, the "losing" lanes still carried their edges down to the parent's row — exactly what was emitted. There is no back-patching, which is what makes the assigner genuinely streaming (ADR-0002's first-page-in-µs property survives).

### Reconciliations (stale epic ACs, corrected)

| # | Epic AC (epics.md:2687–2755) | This story | Why |
|---|------------------------------|-----------|-----|
| R1 | `assign_lanes(repo: &Repo)`; walk via `dag_walk::dfs_ok`; `DefaultReadonlyIndex` | `LaneAssigner::push(GraphNode)` / `assign_lanes(impl IntoIterator<Item = GraphNode>)` over crate-owned types | ADR-0002 AC-4 (lazy revset stream) + FR-JJ-16 ACL (only `zanshin-jj` imports `jj_lib`). See [Read-this-first #1](#️-read-this-first--scope--the-reconciliations-baked-in). |
| R2 | `Row.change_id: ChangeId`, `parents: Vec<ChangeId>` | `Row.commit_id: String`, edge targets = commit ids | The stream yields **commit ids** (`GraphNode<CommitId>`); divergent changes share a change id → ambiguous DAG key. Change-id display data joins later (4.2/4.4 metadata enrichment, via 2-6's `Change`). [OQ-2](#oq-2-row-identity-field--recommend-commit_id-string) |
| R3 | `edges_below: Vec<u32>` + `parents: Vec<ChangeId>` (parallel arrays) | `edges: Vec<RowEdge { target, target_lane: Option<u32>, kind }>` | Same information, one aligned struct instead of an index-parallel invariant; carries `EdgeKind` (Indirect ⇒ dashed rendering; Missing ⇒ stub with `None` — null-for-absence). Story 4.2's `.fbs` note ("rows with change_id, lane, edges_below, color_idx, parents") reconciles to this shape when 4.2 is created. [OQ-1](#oq-1-row-edge-shape--recommend-merged-rowedge) |
| R4 | "anonymous changes … are still placed on a lane"; "working-copy commits … appear in the output (because we use jj's default_index, not gix-commitgraph)" | Subsumed by AC-10 (one row per input node) | The pure input model has no notion of description/bookmark/WC — membership is decided by the upstream revset. The gix-commitgraph contrast is moot (never an option under the ACL). |
| R5 | "the same lane always gets the same color across multiple lane-cache rebuilds" | Determinism AC-13 + AC-9: same **input** → same output | There is no lane cache to rebuild (ADR-0002). Across an op-id advance the input sequence itself may change (new commits reorder branches) — lane stability across mutations is impossible to guarantee at this layer and not promised. |
| R6 | "pvigier-style" (implies the J(c) forbidden-lane refinement) | Leftmost-reservation / leftmost-free rules only | J(c) is a look-ahead-dependent visual-crossing optimization for a specific rendering convention; it conflicts with single-pass streaming and buys nothing until the real UI renders. Revisit with UI feedback (don't pre-compute for hypothetical UI demands — project-context performance-gotcha). |
| R7 | Story-4.5-style perf assertions; "millions of commits" edge case | ~100-node correctness sub-test only | Perf-gate deferred in WIP (Story 4.5 DELETED); the sub-test is the sanctioned replacement (project-context › Testing Rules "One WIP exception"). The "millions of commits" AC documents a characterization, not a test. |

### Out of scope (forward pointers — do NOT build these here)

- **jj-lib stream wiring** (`stream_graph` + `TopoGroupedGraph` inside `zanshin-jj`, mapping into `GraphNode`, revset parameter + `prioritize_branch` pass-through per FR-JJ-17): **Story 4.3/4.4.** The blueprint bench stays where it is.
- **FlatBuffers `GraphSlice` payload + `.fbs` + codegen:** Stories 4.2/4.6 (ADR-0001 shape; no JSON — the epic 4.2 JSON/`jsonschema` ACs are already superseded by the 2026-06-20 note).
- **FFI (`zanshin_graph_*` extern fns, handles):** Story 4.6.
- **Row metadata enrichment** (change id, description, author, bookmarks, WC/conflict markers): later slice/payload stories, joined per-page from 2-6's `Change` — the lane algorithm never needs it.
- **Per-row pass-through-lane info** (which lanes continue vertically across a row — some renderers want it for O(viewport) drawing): deliberately NOT emitted. WIP returns all rows (4.4), so the consumer can reconstruct incrementally; add only when Ralph's UI actually asks (anti-speculation rule).
- **Persistent/materialized lane cache:** never — ADR-0002. If you find yourself storing rows inside the assigner beyond the current node, stop.

### Testing standards for this story

- **No fixtures, no env pinning.** Unlike every Epic-2/3 story: no `extract_fixture`, no `JJ_CONFIG`/`GIT_CONFIG_GLOBAL` (nothing touches a repo or config). Tests are plain, fast, parallel-safe.
- **Placement per CLAUDE.md:** private-helper unit tests inline (`#[cfg(test)] mod tests` in `lane.rs`); public-API scenario tests in `crates/zanshin-graph/tests/lane.rs`. Both count toward the per-file ratchet (source-line coverage from any test kind). Benches would NOT count — there are none here.
- **No `insta`.** It is in the project's planned stack but not yet a workspace dep; exact-expectation `assert_eq!` on small hand-built cases + invariant checks on the ~100-node DAG need no snapshot machinery. Don't add the dep for this.
- **Coverage:** `coverage-baseline.txt` currently has no `zanshin-graph` rows. New files must reach the 80.00 floor; the ratchet auto-raises — commit the updated baseline with the code. `lib.rs` stays re-export-only (typically no executable lines → no ratchet row; if the tool does track it, exports are exercised by the tests anyway).
- **No `#[ignore]`, no timing asserts, no randomness without a fixed literal seed.**

### Project structure notes

- `crates/zanshin-graph/` exists as a scaffold: `Cargo.toml` (workspace-inherited package fields, `[lints] workspace = true` — clippy pedantic already applies) + placeholder `src/lib.rs`. The crate is already in workspace `default-members`, so `cargo make test`/clippy/fmt pick it up without Makefile changes.
- Files touched: `crates/zanshin-graph/Cargo.toml` (+thiserror), `crates/zanshin-graph/src/lib.rs` (rewrite), `crates/zanshin-graph/src/lane.rs` (new), `crates/zanshin-graph/tests/lane.rs` (new), `coverage-baseline.txt` (ratchet auto-raise). **Nothing else** — no root `Cargo.toml` change (thiserror already a workspace dep), no schemas/, no zanshin-ffi/, no Dart, no docs registry.
- Naming: organize by noun (`lane.rs`), no `mod.rs`, `snake_case` fns / `PascalCase` types, SPDX first line, doc comments on all `pub` items.
- Later epic-4 files (`cache.rs`→stream, `slice.rs`, `output.rs`→`.fbs` work per architecture.md:439-446) are siblings added by their own stories.

### Previous-story intelligence (Epic 3 → this story)

- 4.1 is the first Epic-4 story; the nearest relevant predecessors are 3.11 (the decision + blueprint this story builds on) and 3.5 (the "standalone module, no FFI, no codegen" story shape — this story mirrors that cut).
- Recurring review findings to preempt (from 3.4c/3.5/3.6/3.10 reviews): keep the File List in the Dev Agent Record exact (reviews flagged phantom/missing entries); don't move running unit tests out of `src/` to dodge the ratchet; clippy pedantic wants small extracted helpers over `#[allow]` — design for that from the start (the private-fn decomposition in Tasks is deliberate).
- Git pattern: one story = one focused commit (`feat(zanshin-graph): add streaming lane assignment (Story 4.1)`), coverage baseline included in the same commit when it changes.

### References

- [Source: _bmad-output/planning-artifacts/epics.md:2683-2757 — Epic 4 intro + Story 4.1 ACs (reconciled above)]
- [Source: docs/adr/0002-repository-state-model-warm-loader-reload-per-operation.md — Decision §4 + AC-4 (stream, no materialized cache; ~3.1 ms full derive @ 10k)]
- [Source: _bmad-output/implementation-artifacts/3-11-adopt-repo-state-model-warm-loader-reload-per-operation.md — AC-4 graph-derive benchmark + T3 decision record]
- [Source: crates/zanshin-jj/benches/graph_blueprint.rs — runnable stream blueprint (the exact upstream pipeline)]
- [Source: jj-lib 0.42.0 (vendored, `~/.cargo/registry/src/*/jj-lib-0.42.0/`) `src/graph.rs:30-36,81-85,120-133` — GraphNode/GraphEdge/GraphEdgeType + TopoGroupedGraph ordering; `src/default_index/revset_graph_iterator.rs:38-69` — Direct/Indirect/Missing semantics]
- [Source: ../jj @ v0.42.0 `cli/src/commands/log.rs:186,225-233` — jj log uses the same pipeline + `revsets.log-graph-prioritize`]
- [Source: pvigier — Drawing Commit Graphs, https://pvigier.github.io/2019/05/06/commit-graph-drawing-algorithms.html — the "straight branches" strategy (gitamine)]
- [Source: _bmad-output/project-context.md — ACL rule, test placement, coverage ratchet, anti-speculation gotcha, FR-GR-3/FR-GR-5 override entry]
- [Source: _bmad-output/planning-artifacts/prd.md §4.3 — FR-GR-1/2/3/4/5 (FR-GR-3/5 superseded per project-context overrides); NFR-P-2]
- [Source: _bmad-output/planning-artifacts/architecture.md:439-446,601 — zanshin-graph module map]

## Open Questions (recommended defaults baked in)

The ACs above implement these defaults; flag in the Dev Agent Record if Ralph overrides any.

### OQ-1: Row edge shape — recommend merged `RowEdge`

Epic says parallel arrays `edges_below: Vec<u32>` + `parents: Vec<ChangeId>`. Recommended: one `edges: Vec<RowEdge { target, target_lane: Option<u32>, kind }>` — same data, no index-parallel invariant, carries the edge kind the renderer needs for dashed/stub edges, `Option` for Missing follows null-for-absence. Cost: Story 4.2's `.fbs` sketch reconciles to this shape (a one-line note there, normal per-story reconciliation). Alternative: keep the epic's parallel arrays literally (then `Missing` needs a sentinel lane value — worse).

### OQ-2: Row identity field — recommend `commit_id: String`

The stream is keyed by commit ids; change ids are ambiguous under divergence. Alternative: name the field neutrally (`id`) or carry both — carrying `change_id` here would force a per-node repo lookup into a pure algorithm (wrong layer; enrichment joins later).

### OQ-3: Color assignment — recommend `color_idx = lane % 8`

Literal, minimal reading of the epic AC (deterministic, same-lane-same-color, palette 0..7). Alternative considered: per-branch-occupancy counter (`nth lane-opening % 8`) — distinguishes successive occupants of the same lane, looks nicer in some UIs, but is speculative until Ralph's UI renders; trivial to swap later (one line + tests).

### OQ-4: Input id type — recommend concrete `String`

`zanshin_jj::CommitId` is `pub struct CommitId(pub String)` — upstream mapping is a zero-cost move of the inner `String`. Alternative: generic `N: Eq + Hash + Clone` (jj-lib's own style) — slightly more flexible, measurably noisier under `missing_docs`/pedantic, and there is exactly one intended instantiation. Concrete wins until a second consumer exists.

## Dev Agent Record

### Agent Model Used

Claude Sonnet 5 (`claude-sonnet-5`)

### Debug Log References

- Full `cargo make test` (unpiped, final clean run): `cargo test --workspace` green, `cargo clippy --workspace --all-targets -- -D warnings` clean, `cargo fmt --all --check` clean, `cargo deny check advisories bans` → `advisories ok, bans ok`. Only the pre-existing `cargo make coverage` cross-FFI step fails (see below).
- `cargo llvm-cov -p zanshin-graph --lcov --ignore-filename-regex='(_generated\.rs$|/tests/|/benches/)'`: `lane.rs` LF:144 LH:144 → 100.00% (floor was 80.00%). `lib.rs` produces no lcov record at all (no executable lines), as anticipated in Dev Notes.
- `git stash --include-untracked` + rerun, twice: independently confirmed both non-story failures below pre-exist on baseline commit `cdde0d9`.

### Completion Notes List

- **Open Questions**: Ralph did not override any; implemented all 4 recommended defaults as-is — OQ-1 merged `RowEdge`, OQ-2 `commit_id: String`, OQ-3 `color_idx = lane % 8`, OQ-4 concrete `String` ids.
- **Implementation**: `LaneAssigner` (`lanes: Vec<Option<String>>` + `reservations: HashMap<String, Vec<u32>>`, kept sorted via `binary_search`+insert so "leftmost" is O(1)) implements the AC-5 placement/routing rules; hand-traced against the dev-notes fork-then-merge worked example before and after writing the code — matches exactly, including the multi-reservation convergence case (a target held at two lanes at once, both freed on arrival).
- **Tests**: 23 total — 8 inline `#[cfg(test)]` unit tests in `lane.rs` for the private helpers (`alloc_lane`, `place`, `route_edge`, `reserve`, `leftmost_reservation`), 15 scenario/contract tests in `tests/lane.rs` (the full AC-15 matrix, incl. a `merge_edge_reuses_an_existing_reservation_for_its_target` test added after coverage analysis showed that AC-5 branch — "a merge edge whose target already has a reservation reuses it" — had no test, and the deterministic ~100-node correctness sub-test). `lane.rs` line coverage: 100.00%.
- **Bug caught during test-writing (in the test, not the algorithm)**: the ~100-node sub-test's own independent invariant-checker initially flagged a false "lane double-promised" failure. Root cause: when a node with *multiple* reservations arrives, `place()` frees *all* of them, not just the leftmost lane it's placed on (exactly the `f`-held-at-two-lanes pattern from the worked example) — my checker only released the arrival's own `row.lane` and left the other lane's promise stale. Fixed the checker to track all lanes promised per id (`id_promised_lanes`), not just the arrival lane; the algorithm itself was correct throughout (verified by hand-tracing the exact failing case before touching any code).
- **Two pre-existing issues surfaced by the gate, neither caused by this story (both confirmed via `git stash` against baseline `cdde0d9`)**:
  1. `cargo deny check advisories bans` failed on RUSTSEC-2026-0204 (crossbeam-epoch 0.9.18, transitive via `jj-lib → rayon → rayon-core → crossbeam-deque`; `zanshin-graph` has no dependency anywhere near this). Applied cargo-deny's own recommended fix, `cargo update -p crossbeam-epoch` (0.9.18→0.9.20) — Cargo.lock-only, zero source changes — so the gate reflects this story's actual state instead of an unrelated advisory. Included in the File List below.
  2. `cargo make coverage`'s cross-FFI step fails: `coverage: instrumented cdylib not found at packages/zanshin_core/.dart_tool/lib/libzanshin_ffi.dylib` — the Dart Hook's build output isn't landing where `Makefile.toml`'s `coverage` task expects it (the dylib was found instead at `packages/zanshin_core/build/native_assets/macos/`). This blocks the *last* step of `cargo make test` right now for every story, not only this one, and is Dart/Flutter build tooling — out of scope for a Rust-only lane-assignment story to chase down. Worked around by measuring `zanshin-graph`'s own coverage directly (see Debug Log References) — authoritative for this crate since it has zero FFI surface, so the cross-FFI step could never have contributed to its coverage anyway — and hand-added the `coverage-baseline.txt` entry using the exact `round2(100 * hit / found)` formula `coverage_check.rs` uses. **Not fixed here**; flagged as a separate follow-up task for Ralph.
  **Addendum (same session, follow-up task):** Ralph dispatched the follow-up immediately. Root cause: `packages/zanshin_core` resolves via a Dart pub *workspace* (`resolution: workspace`), which hoists `.dart_tool` to the workspace root — the instrumented dylib was landing at `$ROOT/.dart_tool/lib/libzanshin_ffi.dylib` all along, not `packages/zanshin_core/.dart_tool/lib/...` as `Makefile.toml`/`docs/coverage.md` assumed. Confirmed by deleting every candidate `.dylib` and rerunning `dart test` under the coverage marker, then checking mtimes. Fixed in `Makefile.toml`'s `[tasks.coverage]` (path + cache-bust) and documented in `docs/coverage.md`; `cargo make coverage` and the full `cargo make test` both now exit 0 (coverage held at 98.48%, my manually-added `lane.rs = 100.00` entry confirmed unchanged by the real ratchet). See sprint-status.yaml's history for the dedicated log entry — this was infrastructure work, not part of Story 4.1's own File List.
- Running `flutter test`/`dart test` during gate runs repeatedly regenerated `app/analysis_options.yaml` (new platform-build-output excludes) and `pubspec.lock` (minor transitive version bumps) as a side effect on this machine. Reverted both each time — unrelated to this story's Rust-only scope, not part of the File List or the commit.

### File List

- `crates/zanshin-graph/Cargo.toml` (modified — `+thiserror = { workspace = true }`)
- `crates/zanshin-graph/src/lib.rs` (modified — rewritten: SPDX line 1, `#![deny(missing_docs)]`, crate-level docs, `mod lane;` + `pub use lane::{...}`)
- `crates/zanshin-graph/src/lane.rs` (new — `GraphNode`/`GraphEdge`/`EdgeKind`/`Row`/`RowEdge`/`PALETTE_SIZE`/`GraphError`/`LaneAssigner`/`assign_lanes` + 8 inline unit tests; review 2026-08-22: first-non-`Missing` continuation rule, doc fixes)
- `crates/zanshin-graph/tests/lane.rs` (new — 20 scenario/contract tests incl. the ~100-node (104) correctness sub-test; review 2026-08-22: +5 tests, stronger invariants)
- `coverage-baseline.txt` (modified — `+crates/zanshin-graph/src/lane.rs = 100.00`)
- `Cargo.lock` (modified — `crossbeam-epoch` 0.9.18→0.9.20; pre-existing RUSTSEC-2026-0204 fix, unrelated to this story's feature work, see Completion Notes)

Infra changes that landed in the same working tree (same session; not story-4.1 feature work — suited to their own commit; listed here so the record matches the tree, per the 2026-08-22 review):

- `Makefile.toml` (modified — `[tasks.coverage]` instrumented-dylib path `$CORE/.dart_tool` → `$ROOT/.dart_tool` + cache-bust; the coverage-gate fix from the Addendum)
- `docs/coverage.md` (modified — pub-workspace `.dart_tool` hoisting explained; review 2026-08-22: build-profile pitfall section)
- `Cargo.toml` (root; modified — `[profile.dev.package."*"] debug = "line-tables-only"` with `# WHY:`; originally `debug = false`, switched during the 2026-08-22 review — see Review Findings decision 2; the Dev Notes "no root `Cargo.toml` change" was the plan for the *story's* scope, which still holds)

## Change Log

| Date | Change |
|------|--------|
| 2026-07-04 | Story created (create-story): epic ACs reconciled to ADR-0002 stream model (R1–R7); pure crate-owned input types (no jj-lib/zanshin-jj dep, ACL); streaming `LaneAssigner` + `assign_lanes` wrapper; commit-id keying; merged `RowEdge` with `Option<u32>` target lane; `lane % 8` colors; ~100-node correctness sub-test replaces deleted 4.5 perf test; 4 OQs with recommended defaults baked in. |
| 2026-08-13 | Story implemented (dev-story): `LaneAssigner`/`assign_lanes` shipped in new `crates/zanshin-graph/src/lane.rs`; 23 tests (8 inline + 15 in `tests/lane.rs`), `lane.rs` coverage 100.00% (floor 80%); all 4 OQs implemented as recommended. Incidental fix: `cargo update -p crossbeam-epoch` (RUSTSEC-2026-0204, pre-existing, proven via `git stash` against baseline) so `cargo deny` passes. `cargo make coverage`'s cross-FFI step remains blocked by a separate pre-existing Dart/Flutter native-asset path issue (also proven pre-existing via `git stash`) — flagged as a follow-up, not fixed here; `lane.rs`'s own coverage verified independently via `cargo llvm-cov -p zanshin-graph`. Status → review. (Superseded the same day by the Addendum: the coverage-gate path fix landed as infra and the full `cargo make test` exits 0 — AC-16 satisfied.) |
| 2026-08-22 | Code review (bmad-code-review, 4 layers): 30 raw → 16 unique → 2 decisions + 13 patches + 1 defer + 8 dismissed; no correctness defect on contract-conforming input. Decisions (Ralph): first-non-`Missing` continuation rule (code aligned to AC-5/rustdoc, Dev Notes amended); root `Cargo.toml` dev-profile → per-package `line-tables-only`. Patches: doc accuracy (`GraphNode` contract vs jj-lib edge splicing, O(active-lanes) wording, gitamine/jj-log, 4.3 mapping ownership, AC-10 on `LaneAssigner`), +5 tests (streaming `push`/`finish`, fresh `finish`, dangling `Indirect`, parent-before-child, `Missing`-first continuation), Missing stub frees lane, full-row asserts for interleaved branches, ~100-node DAG → 104 nodes with `Indirect`+`Missing` edges, size assert, dense-lane invariant replacing the fragile `max_lane` bound, end-state emptiness asserts; File List/Change Log reconciled. Defer: `expect()` FFI-reachability → 4.6 (deferred-work.md). `cargo make test` green end-to-end after patches (28 zanshin-graph tests; coverage held 98.48%, `lane.rs` 100%, baseline unchanged). Status → done. |
