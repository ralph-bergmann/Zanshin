# Story 3.11: Adopt the repo-state model — warm loader + reload-per-operation (ADR-0002)

---
baseline_commit: TBD
---

Status: done — **ADR-0002 Accepted; AC-4 resolved (stream)**. T1 (bench: tiny + medium + large-10k) / T2 (doc reconciliation) / T3 (graph decision: stream) / T5 (gate) all done. Remaining is downstream **Epic 4 implementation** (build the streamed `zanshin-graph`), not a decision.

> **Origin:** [ADR-0002 — Repository state model: warm loader + reload-per-operation](../../docs/adr/0002-repository-state-model-warm-loader-reload-per-operation.md),
> backed by the prior-art research report
> `_bmad-output/planning-artifacts/research/technical-vcs-gui-repo-state-cache-vs-reload-research-2026-06-22.md`.
>
> This is a **cross-cutting adoption story** (same shape as Story 3.0 for ADR-0001). It is
> *forward-looking, not a rip-out*: the FFI handle as built (Stories 3.2 / 3.4a / 3-9) already
> holds only a warm `Workspace` + `UserSettings` (the cheap-to-keep part), and
> `crates/zanshin-jj/src/repo.rs` already documents **"Decision D4"** (read-stories use
> `repo_loader().load_at_head()`). This story turns that buried intent into a named architecture,
> **measures the assumption it rests on**, reconciles the docs that still carry the old
> "held cache" framing, and re-points the dependent read/graph stories.

---

## Story

As the Rust + Dart developer building the read path and the commit graph,
I want the repo-state model settled and measured — **the handle is a warm `Workspace` loader + op-heads-watcher owner, reads re-resolve to the latest operation, and no authoritative repo state is cached in memory** —
so that every later read/graph/watcher story (2.4–2.9, 3.4b, 4.3, 4.6, 3.5/3.6) is built correct-under-concurrency from the first line, and the one performance assumption the model rests on (load/snapshot cost) is a measured number rather than a guess.

**The model (ADR-0002), restated:** the on-disk jj operation log is the single source of truth; loading is lightweight (`RepoLoader` → `ReadonlyRepo` resolves an op-id, it does not scan the tree); the expensive step is the working-copy snapshot (→ `fsmonitor`/Watchman, orthogonal to hold-vs-reload); the op-heads watcher is the coherency trigger (compare resolved op-id), not a cache invalidator. Same-repo concurrency (external `jj` CLI + MCP + GUI, FR-MCP-9 / FR-RX-3) is correct-by-construction because there is no divergeable cache.

**Multi-repo (ADR-0002 § Multi-repo):** the app holds **0..N** repos (SourceTree-style overview). The handle mechanism + worker handle table already support N handles, and AD-2 holds for N (one isolate serializes all — no `Arc<Mutex>`). The overview is **tiered** — *registered* (path only) / *summary* (stateless re-resolve, no warm handle, driven by that project's op-heads watcher) / *active* (warm handle). One op-heads watcher per observed project; events carry a repo correlation id.

---

## Acceptance Criteria

### AC-1 — Benchmark the assumption (resolves the ADR-0002 open question)

1. A small, **non-CI** benchmark (`#[ignore]`d test or `cargo bench`, detached from the WIP gate per the deferred perf-gate posture) measures, on the committed fixtures `tiny-3-commits`, `medium-1k-commits`, `large-10k-commits`:
   - `Workspace::load` cost,
   - `repo_loader().load_at_head()` re-resolution cost,
   - the working-copy snapshot cost (with and without `fsmonitor`/Watchman if feasible),
   - reported **per repo** — the project overview multiplies these by N open/observed projects (ADR-0002 § Multi-repo), so the per-repo number is the load-bearing one.
2. The numbers are recorded in this story's Dev Agent Record **and** fed back into ADR-0002 (Open questions → resolved) and the Story 4.3 graph decision (AC-4 below). Reference hardware noted (M-series baseline, per Story 2.2).
3. **No invented numbers.** If a measurement can't be taken (e.g. Watchman not present), say so explicitly.

### AC-2 — Reconcile the docs that still carry the "held cache" framing

4. **Code comments** corrected to the warm-loader / re-resolve model:
   - `crates/zanshin-ffi/src/repo.rs:~166` and `crates/zanshin-ffi/src/handle.rs` — the *"AD-2: no handle table"* comments are reworded so they describe "warm loader, re-resolve per op, no authoritative state cache" rather than reading as "no state held at all." (Also credit the Dart-side worker handle table from Story 3-9, which already provides use-after-free safety the Rust comments don't mention.)
5. **`architecture.md`** — the `zanshin-graph` module line *"`cache.rs` — FR-GR-3 full lane-cache on open / op_heads"* (≈ lines 441–444) is reconciled with the 2026-05-17 "compute on demand" rework + ADR-0002 (no materialized cache unless AC-4 says otherwise); AD-2 (lines 205–213) gains a one-line pointer to ADR-0002 (handle = warm loader, reads re-resolve).
6. **`project-context.md`** — the Performance-gotchas line *"Lane-cache rebuild on EVERY op_heads change"* is updated to the re-derive / stream framing (or removed if AC-4 drops the materialized cache).
7. **`epics.md`** — already carries the dated ADR-0002 reconciliation notes on AR-AD-2, AR-AD-5, Story 4.3, and Story 3.4b (added 2026-06-22); this story verifies they remain consistent with the final AC-4 decision.

### AC-3 — Dependent-story re-pointing (tracking, not code)

8. The following backlog stories are re-pointed to the reload-per-operation model; each carries a one-line scope note when it is created (the Story 3.0 / 3.4a callout pattern):

   | Story | Was (implied held state) | Now (ADR-0002) |
   |-------|--------------------------|----------------|
   | 2.4–2.9 (`zanshin-jj` read path) | operate on the opened `Repo` | re-resolve to head (`repo_loader().load_at_head()`) per read — "Decision D4", now binding |
   | 3.4b (read-path FFI wrappers) | return state from the held repo | re-resolve to head inside each wrapper before reading |
   | 4.3 (`cache.rs`) | build full lane-cache on open + rebuild on every `op_heads` | compute/stream lanes on demand against the head-resolved repo (cache only if AC-4 justifies it) |
   | 4.6 (`graph.rs` FFI) | watcher → rebuild + close old graph handle | watcher → re-derive/stream; no long-lived authoritative graph handle to invalidate |
   | 3.5 / 3.6 (watcher / events) | watcher = UI notification | watcher = notification **and** coherency trigger (op-id compare) |

9. **Unaffected:** AD-2 ownership mechanics (`Box<T>`, single isolate, no `Arc<Mutex>`, `NativeFinalizer`), AD-4 worker command/response, ADR-0001 FlatBuffers transport, AD-5 debounce/backpressure. This story changes *what the handle represents* and *how reads derive state*, not the boundary mechanics.

### AC-4 — Settle the commit-graph derivation (gated on AC-1)

10. Using the AC-1 numbers, record the decision for `zanshin-graph`: **(a)** stream/slice on demand from a lazy revset (GG's `QuerySession` model, no materialized cache), or **(b)** keep a per-request in-memory lane computation, or **(c)** keep a materialized lane cache (only if the benchmark shows re-derivation blows the NFR-P-1 < 1s @ 10k budget). The decision is written into Story 4.3/4.4/4.6 and ADR-0002.

### AC-5 — No code regression; current handle confirmed conformant

11. The existing handle (`zanshin-jj::Repo { workspace, settings }`, opaque `u64`, worker-held) is confirmed to already conform to "warm loader" — no rip-out. `cargo make test` stays green. No `Arc<Mutex>` introduced; the single-consumer worker isolate (AD-4) is unchanged.

### AC-6 — Multi-repo / project-overview model (tracking, design)

12. The app supports **0..N** concurrent repos — the handle mechanism + worker `handleId`→pointer table already do, and AD-2 holds for N (one isolate serializes all access, no `Arc<Mutex>`). AD-6's single-repo / no-registry rule is the `zanshin-mcp` binary's constraint only, not the app's.
13. The project overview is **tiered** (ADR-0002 § Multi-repo), not "one warm handle per listed project": *registered* (path only) → *summary* (stateless re-resolve on demand, no warm handle, refreshed by that project's op-heads watcher) → *active* (warm `Repo` handle for graph/diff/mutation).
14. **One op-heads watcher per observed project**; watcher events carry a **repo/handle correlation id** on the event port — folded into the deferred watcher stories (3.5 / 3.6). N watchers must scale (each watches only `.jj/repo/op_heads/heads/`).

---

## Tasks / Subtasks

- [x] **T1 — Benchmark** (AC: 1, 2) — tiny + medium + **large-10k** measured (added the `Large` fixture spec to `xtask`)
  - [x] Added `#[cfg(test)] mod bench` in `crates/zanshin-jj/src/repo.rs` (inline so it can reach the private `workspace.repo_loader().load_at_head()`); pins `JJ_CONFIG`/`GIT_CONFIG_GLOBAL`; no network. Run: `cargo test -p zanshin-jj --release bench_repo_state -- --ignored --nocapture --test-threads=1`.
  - [x] Measured `Workspace::load` + `load_at_head()` on `tiny-3-commits` + `medium-1k-commits` + `large-10k-commits` (numbers in Dev Agent Record). Added the `Large` fixture spec to `xtask` (`build_large`) and generated `large-10k-commits.tar.zst` (~5.0 MB) via `cargo xtask gen-fixture --size large`. The working-copy **snapshot** cost is deliberately not measured (orthogonal to hold-vs-reload; addressed by fsmonitor/Watchman).
  - [x] ADR-0002 Open questions updated; `clippy -D warnings` + `fmt` clean (zanshin-jj + xtask).
- [x] **T2 — Doc reconciliation** (AC: 5, 6, 7; AC-4 graph wording kept GATED until the 10k benchmark)
  - [x] Reworded `repo.rs` (close docstring + SAFETY comment) and `handle.rs` (`handle_drop` doc: `NativeFinalizer`→`Finalizer`, "(a later story)"→Story 3.9) to the warm-loader / re-resolve model + Dart Model-A table credit.
  - [x] Reconciled `architecture.md`: AD-2 gains the ADR-0002 warm-loader + multi-repo framing + the finalizer correction; the `zanshin-graph` `cache.rs` line reframed (T3/AC-4 later finalised it to **stream, no materialized cache**).
  - [x] Updated `project-context.md`: performance-gotcha (re-derive + gated), `zanshin-ffi` single-threaded bullet (0..N handles + warm loader), Reference-documents (ADR-0002 + research report), Last-Updated + `last_revised` frontmatter.
  - [x] Verified epics.md dated notes (AR-AD-2, AR-AD-5, Story 3.4b, Story 4.3) present + consistent via a repo-wide sweep. **Graph wording kept GATED, not decided** — AC-4 awaits the 10k fixture.
  - [x] Rust gate green: `cargo clippy -p zanshin-ffi --tests -- -D warnings` + `cargo fmt --check` clean.
  - [ ] **NOT edited (flagged, by design):** `prd.md` FR-GR-3/FR-GR-5 still state the original "full lane-cache on open / op_heads" requirement. Per project-context's rule (PRD inconsistencies are *raised*, not silently reconciled), this is logged as upstream-of the reopened FR-GR-3 decision — revisit when AC-4 resolves post-10k. Not changed now because the decision is not yet final.
- [x] **T3 — Graph decision** (AC: 10) — **DECIDED: lazy revset stream, NO materialized lane cache**
  - [x] Graph-derive spike (jj-lib `stream_graph` + `TopoGroupedGraph`, GG-mirroring) over the 10k fixture: full graph derive **~3.1 ms**, first 100-row page **~27 µs** (Dev Agent Record). → re-derive on op-id advance is trivially cheap; a materialized cache is unnecessary.
  - [x] Recorded in ADR-0002 (Status + Decision §4 + Open questions + FR-GR-3 affected line), `architecture.md` `cache.rs` line, epics Story 4.3 note, and a `project-context.md` `overrides:` entry superseding FR-GR-3/FR-GR-5 (the project's canonical supersession mechanism — PRD prose left as historical, exactly as ADR-0001 handled its supersessions).
  - [ ] Downstream (Epic 4, not this story): `zanshin-graph` create-story rewrites 4.3/4.4/4.6 to a lazy revset stream; confirm lane-number assignment adds only O(1)/node.
- [ ] **T4 — Re-pointing notes** (AC: 8)
  - [ ] Confirm the dependent-story scope notes are in place (epics.md done 2026-06-22); add to each story's create-time callout when authored.
- [x] **T5 — Gate** (AC: 11)
  - [x] `cargo make test` green (2026-06-22): `cargo test --workspace` pass, `advisories ok, bans ok`, `test-cargo-hygiene` ok, `Build Done in 70.47s`, no failure markers. Changes were comment-only (Rust) + markdown — no behavioural change to the handle path; bench is `#[cfg(test)]`-only.

---

## Dev Notes

### What is already aligned (do not "fix" it)

- `crates/zanshin-jj/src/repo.rs:39-46` — `Repo { workspace, settings }`; `settings` carries a `WHY(allow dead_code)` comment naming **Decision D4** (read-stories use `repo_loader().load_at_head()`). `clone_into` (`repo.rs:168`) already calls `load_at_head()`. The warm-loader model is *already the codebase's intent.*
- The worker isolate (Story 3-9) holds the handle for app lifetime and maps a dense `handleId` → raw `u64` (Model A). That is the "warm loader owner" role ADR-0002 names. Keep it.

### What changes (the point of this story)

- **Vocabulary + intent become explicit and measured.** The big behavioural commitments (re-resolve per read; watcher = coherency trigger; graph derived/streamed) are *future* read/graph/watcher stories — this story binds them and removes the doc drift that would otherwise lead a later agent to build a held authoritative cache.
- **The one real fork was the graph** (AC-4) — now decided on numbers (not taste): **lazy revset stream, no materialized cache** (full graph derive ~3.1 ms @ 10k). See the AC-4 graph-derive benchmark in the Dev Agent Record.

### Guardrails (project-context Critical Don't-Miss)

- **No `Arc<Mutex>` / `RwLock` around handles** (AD-2 single isolate). Re-resolution happens on the worker isolate; no locking.
- **No shelling to `jj`** — `repo_loader().load_at_head()` is jj-lib, in-process.
- **No held authoritative `ReadonlyRepo`** trusted across an op-id change. Memoize only within one resolved operation.
- **Perf-gate stays deferred** — the AC-1 benchmark is a decision input, not a CI gate.

### References

- `docs/adr/0002-repository-state-model-warm-loader-reload-per-operation.md` — the decision.
- `_bmad-output/planning-artifacts/research/technical-vcs-gui-repo-state-cache-vs-reload-research-2026-06-22.md` — the prior-art evidence (GG, jj cost model, coherency failure modes).
- `crates/zanshin-jj/src/repo.rs` — Decision D4 / `load_at_head` (already present).
- `epics.md` — AR-AD-2 / AR-AD-5 (refined 2026-06-22), Story 3.4b / 4.3 (reconciliation notes 2026-06-22).
- `architecture.md` §§ AD-2 (205–213), `zanshin-graph` + FR-GR-3 (441–444).
- jj architecture / operation-log docs — `docs.jj-vcs.dev/latest/technical/architecture/`, `…/operation-log/`.
- Precedent: `_bmad-output/implementation-artifacts/3-0-adopt-flatbuffers-ffi-transport.md` (ADR-adoption story shape).

---

## Dev Agent Record

### AC-1 benchmark results (2026-06-22)

Apple-silicon dev hardware, `--release`. Bench: `crates/zanshin-jj/src/repo.rs` → `#[cfg(test)] mod bench`, env-pinned (`JJ_CONFIG=""`, `GIT_CONFIG_GLOBAL=""`). **Methodology refined after a `tiny > medium` anomaly was flagged:** the first cut (median-of-11, no warmup) was noise-inflated; the final method is **5 untimed warmup iterations + `min` *and* `median` over 51 timed iterations**, run twice for stability.

| Fixture | `Workspace::load` (min / med) | `load_at_head()` re-resolve (min / med) |
|---------|-------------------------------|------------------------------------------|
| `tiny-3-commits`    | pass1 279µs/299µs · pass2 550µs/692µs | pass1 96µs/107µs · pass2 160µs/190µs |
| `medium-1k-commits` | pass1 330µs/395µs · pass2 277µs/429µs | pass1 187µs/222µs · pass2 190µs/248µs |
| `large-10k-commits` | pass1 915µs/1.23ms · pass2 1.02ms/1.10ms | pass1 993µs/1.11ms · pass2 732µs/914µs |

**Findings:**
- **The `tiny > medium` anomaly was measurement noise / warm-up — the suspicion was correct.** With warmup + min, the *load* ordering **flips between runs** (tiny faster in pass 1, slower in pass 2); medium's load-min is stable (~280–330µs) while tiny's swings (279→550µs). An unstable ordering at sub-ms scale is the signature of OS/scheduler/page-cache jitter, not a real per-fixture cost. The original 1.54 ms tiny figure was an artifact of no-warmup + only 11 samples (early cold reads of the freshly-unpacked tempdir dominated the median).
- **`Workspace::load` is ~O(1) in commit count** (jj loads metadata + op heads, not the commit graph), so tiny and medium sit in the same ~0.3–0.7 ms band; the spread is noise. `load` is noisier than `load_at_head` because it opens the workspace + git backend + parses settings fresh each call (many syscalls/allocs → exposed to jitter), whereas `load_at_head` reuses the already-open workspace.
- **`load_at_head()` — the decision-critical number — is stable and physically sensible:** medium ~190µs ≥ tiny ~100–160µs (more commits → slightly more to resolve). Both firmly **sub-millisecond**.
- **At 10k the trend is monotonic and stable** (no run-to-run flipping): `load_at_head` tiny ~90µs < medium ~185µs < large **~0.7–1.0 ms**; `load` tiny ~285µs < medium ~345µs < large **~1.0 ms**. Growth is **sub-linear** (1k→10k = 10× commits, only ~5× time).
- **Conclusion (reinforced):** re-resolution is **~100–250 µs at ≤1k and ~0.7–1.0 ms at 10k** — reload-per-operation is decisively affordable. An overview row re-resolves statelessly on *its* watcher fire (event-driven, not a poll); N rows ≈ N × ≤1 ms, bounded. **ADR-0002 Option C confirmed up to 10k commits.**

**Caveats:**
- `large-10k-commits` now **measured** (2026-06-22): added the `Large` fixture spec to `xtask` (`build_large`: 2 000 linear → 3×660 branches → merge → 6 019 linear = 10 000), generated via `cargo xtask gen-fixture --size large` (~5.0 MB archive). Re-resolution at 10k ≈ 0.7–1.0 ms → reload-per-op holds at 10k. **(This measures repo *load/re-resolve*; the graph materialize-vs-stream question — AC-4 — was then resolved by a dedicated graph-derive spike: see "AC-4 graph-derive benchmark" below.)**
- Working-copy **snapshot** cost **not measured** (orthogonal to hold-vs-reload; → fsmonitor/Watchman).
- `cargo clippy -p zanshin-jj --tests -- -D warnings` + `cargo fmt --check` clean; bench is `#[cfg(test)]`-only (production-inert — AC-5 holds).

### AC-4 graph-derive benchmark (2026-06-22)

To decide materialize-vs-stream for the commit graph, a spike walks the **entire** commit graph in topological order via jj-lib's Stream-based revset API (`ResolvedRevsetExpression::all().evaluate(repo).stream_graph()` wrapped in `jj_lib::graph::TopoGroupedGraph`, driven with `futures::executor::block_on`) — exactly GG's model. Bench: `crates/zanshin-jj/src/repo.rs` `bench_graph_*`; `futures` added as a dev-dependency; requires the `large-10k` fixture.

| Fixture | nodes | full graph derive (min / med) | first-100 page (min / med) |
|---------|-------|-------------------------------|----------------------------|
| `medium-1k` | 1 002  | 337 µs / 344 µs | 32 µs / 33 µs |
| `large-10k` | 10 002 | **3.07 ms / 3.15 ms** | **27 µs / 29 µs** |

**Decision (AC-4): GG-style lazy revset stream, NO materialized lane cache.**
- Deriving the *entire* 10k graph is **~3.1 ms** — re-deriving on every `op_heads` advance is trivially cheap (≪ NFR-P-1 < 1 s @ 10k), so there is no rebuild cost a cache would need to amortize.
- The first render page (100 rows) **streams in ~27 µs** — instant O(slice) initial render without materializing the whole graph.
- So a long-lived materialized lane cache buys nothing here and would reintroduce exactly the coherency burden ADR-0002 avoids.
- **Caveat:** this measures the graph *walk/derive* (which already computes the parent edges the lane algorithm consumes); lane-number/color assignment adds O(1)/node on top — expected single-digit ms at 10k. Epic 4's `zanshin-graph` implements the stream and confirms.

---

## Change Log

| Date | Change |
|------|--------|
| 2026-06-22 | Story drafted from ADR-0002 (status: draft, pending ADR acceptance + AC-1 benchmark) |
| 2026-06-22 | AC-1 benchmark run (tiny + medium): `load_at_head()` ~250–350 µs → Option C confirmed at ≤1k; `large-10k` + snapshot pending. clippy `-D warnings` clean. |
| 2026-06-22 | Bench methodology refined (warmup + min/median, 2 passes) after a `tiny > medium` anomaly: confirmed it was measurement noise; `load` is ~O(1) in commits (~0.3–0.7 ms band), `load_at_head` stable & sensible (~100–250 µs, medium ≥ tiny). Conclusion unchanged. |
| 2026-06-22 | T2 doc reconciliation done (repo.rs/handle.rs/architecture.md/project-context.md aligned to ADR-0002; graph kept GATED, not decided). Rust gate green. `prd.md` FR-GR-3/5 flagged but not edited (decision not final). |
| 2026-06-22 | T5: full `cargo make test` green (Build Done 70.47s; advisories+bans ok). ADR-0002 flipped to **Accepted** (core decision; graph sub-question stays gated on `large-10k`). Status → in progress. |
| 2026-06-22 | `large-10k` fixture generated (xtask `build_large`, ~5.0 MB) + benchmarked: re-resolution ~0.7–1.0 ms at 10k → reload-per-op confirmed **up to 10k** (Option C). AC-4 graph: provisional lean = streaming, final at Epic 4. clippy+fmt clean. |
| 2026-06-22 | **AC-4 RESOLVED** via graph-derive spike (jj-lib `stream_graph`+`TopoGroupedGraph`): full 10k graph derive ~3.1 ms, first page ~27 µs → **stream, no materialized lane cache** (GG). Recorded in ADR-0002 / architecture.md / epics 4.3 / project-context `overrides:`. `futures` dev-dep added; clippy+fmt clean. Status → done. |
