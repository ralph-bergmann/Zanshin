---
title: 'Story 4.4: Return-all-lanes-for-revset API (`slice.rs`) — collect-all over the lazy lane stream'
type: 'feature'
created: '2026-08-23'
status: 'in-progress'
baseline_revision: '28f52275382c6c18cadd3c3399e46469fabbe319'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-4-context.md'
warnings: ['oversized']
deferred: []
---

<intent-contract>

## Intent

**Problem:** Story 4.3 delivers lanes only as a push stream (`stream_lanes(repo, revset, prioritize, sink)`); there is no one-call "give me all lane rows of this revset" API for Story 4.6's FFI wrapper (and any other consumer) to call, and the epic's Story 4.4 text (`LaneCache::render_slice(start, count)` over a held `Vec`, `tests/slice.rs` paging cases) is superseded twice over — by the WIP-rework (2026-05-17: "drop the windowing/pagination ACs; return all lanes for the resolved revset in one call") and by ADR-0002 AC-4 (no materialized cache to slice).

**Approach:** Add `crates/zanshin-graph/src/slice.rs` with one public function, `collect_lanes(repo, revset, prioritize) -> Result<Vec<Row>, LaneStreamError>`, that drives `stream_lanes` with a collecting sink and returns every row of the revset in `jj log` order (whole revset, no `start`/`count`/`limit`/`reversed` — windowing is deferred past WIP; a future page composes as an early-exit sink on the stream, never as a scan over a held cache). Reconcile the planning docs that still describe the render-slice-over-cache model.

## Boundaries & Constraints

**Always:**
- Build on 4.3, do not bypass it: `collect_lanes` calls the public `stream_lanes` (re-resolve to head per call, `prioritize ∩ revset` CLI prioritisation, `jj log` order, `finish()` on the exhausted stream); no second walk, no `drive_lanes` exposure, no retained state.
- Both `revset` and `prioritize` stay caller pass-throughs (FR-JJ-17); `zanshin_jj::DEFAULT_GRAPH_PRIORITIZE` is the documented pre-fill, never applied silently.
- Errors: reuse `LaneStreamError` (`Revset` for parse/resolution/jj-lib failures of either expression, `Graph` for a dangling edge on `finish()`); no new error type, no new `error.code` (nothing crosses FFI in this story) → `docs/rust-error-codes.md` untouched. Rows handed to the sink before an `Err` are dropped with the `Err` (nothing partial is returned).
- `Vec<Row>` is the return type: with return-all semantics `total_rows == rows.len()` by construction, so a Rust `GraphSlice { rows, total_rows }` struct would carry a redundant field; the FlatBuffers `GraphSlice` (4.2) stays the wire name and `zanshin_ffi::graph::graph_slice_to_envelope(&rows)` already derives `total_rows` from the length.
- ACL (FR-JJ-16): `zanshin-graph` keeps no `jj-lib` dependency and no `jj_lib` import; `lane.rs`/`stream.rs` semantics and the `Row`/`RowEdge` shapes stay unchanged.
- Quality bar: clippy pedantic refactor-not-suppress, rustfmt, `#![deny(missing_docs)]` (doc the `pub` fn incl. `# Errors`), SPDX first line, no `unwrap`/`expect`/`panic!` in the library path, scenario-named tests, `JJ_CONFIG`/`GIT_CONFIG_GLOBAL` pinned via the `LazyLock` pattern, no timing asserts, fixtures `tiny-3-commits` + `medium-1k-commits` only.
- Coverage ratchet: new `crates/zanshin-graph/src/slice.rs` ≥ 80 % (expected 100 % via `tests/slice.rs`); no regression elsewhere; commit the auto-raised `coverage-baseline.txt` with the code.
- Repo conventions: ONE focused commit on `main` (`feat(zanshin-graph): add return-all-lanes slice API (Story 4.4)`) incl. story artifacts; `flutter`/`dart` gate churn (`app/analysis_options.yaml`, `pubspec.lock`) reverted, never committed (4.1–4.3 precedent). Edit `epic-4-context.md` AFTER every planning-artifact edit so it stays the newest file (validity rule of the epic-context cache).

**Block If:**
- `cargo make test` fails for a reason outside this story that cannot be fixed in scope (do not lower the baseline / add `exclude_prefix`).

**Never:**
- No `start`/`count`/`limit`/`reversed` parameters, no paging struct, no `total_rows` field, no `LaneCache`/held rows/memoization across calls (ADR-0002 AC-4; WIP-rework of 4.4). CLI `--limit`/`--reversed` are presentation/paging knobs deferred with windowing — a caller that wants fewer rows uses `stream_lanes` with an early `Break`.
- No `extern "C"` fn, `.fbs`, codegen, Dart, `WorkerCommand`, op-heads/watcher wiring, op-id exposure (Story 4.6 decides its wrapper signature against this API).
- No metadata enrichment (change id, description, bookmarks…) on rows — anti-speculation; no `large-10k` fixture, no perf assertions, no `#[ignore]`.
- No edits to `lane.rs`, `stream.rs` bodies, `crates/zanshin-jj/**`, or `crates/zanshin-ffi/src/graph.rs` beyond the single stale rustdoc phrase named in the Code Map.

## I/O & Edge-Case Matrix

Fixture facts (see spec-4-3): **tiny** = `root` ← `@` and `root` ← c1 ← c2 ← c3 → `all()` = 5 nodes; **medium** = root ← `@` plus 200 linear → 3 branches × 66 → octopus merge → 601 linear → `all()` = 1002 nodes.

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Tiny, CLI-default prio | `collect_lanes(tiny, "all()", DEFAULT_GRAPH_PRIORITIZE)` | `Ok(rows)`, 5 rows in order `@, c3, c2, c1, root` with the 4.3 hand-traced lanes/edges (`@=0→root Some(0)`, `c3=c2=c1=1`, `root=0`); identical to collecting `stream_lanes` into a `Vec` | none |
| Tiny, no prio | same, prioritize `"none()"` | same 5 rows as a set; first row is `c3` (parameter honoured) | none |
| Medium invariants | medium, `"all()"`, `DEFAULT_GRAPH_PRIORITIZE` | 1002 rows; row 0 is `@`; exactly one row with 3 edges; max lane 3; `color_idx == lane % PALETTE_SIZE`; every edge target appears in a LATER row; second call returns an equal `Vec` (determinism, no retained state) | none |
| Empty revset | `"none()"` | `Ok(vec![])` | none |
| Parse error (either param) | revset `"bogus_function()"` or prioritize `"("` | `Err(LaneStreamError::Revset(RevsetError::ParseError { .. }))` | propagated, no panic, no rows |
| Resolution error | revset `"nonexistent-bookmark-xyz"` | `Err(LaneStreamError::Revset(RevsetError::ResolutionError { .. }))` | propagated |

</intent-contract>

## Code Map

- `crates/zanshin-graph/src/stream.rs` -- `stream_lanes(repo: &zanshin_jj::Repo, revset: &str, prioritize: &str, sink: impl FnMut(Row) -> ControlFlow<()>) -> Result<ControlFlow<()>, LaneStreamError>` l.70-77 (the API to wrap; rustdoc l.50-69 states the contracts `collect_lanes` inherits: re-resolve per call, `none()` canonical no-prio, blank prioritize = ParseError, rows before an `Err` are not retracted); `LaneStreamError` l.13-22 (reuse). READ-ONLY except nothing — do not touch.
- `crates/zanshin-graph/src/lane.rs` -- `Row` l.89-105 (`commit_id`, `lane`, `color_idx`, `edges: Vec<RowEdge>`), `assign_lanes` (the existing collect-wrapper precedent over `LaneAssigner`: same "collect into `Vec<Row>`" shape). READ-ONLY.
- `crates/zanshin-graph/src/lib.rs` -- crate doc l.5-17 (append one sentence: `collect_lanes` is the return-all API, Story 4.4, windowing deferred); module list l.19-20 (`mod slice;`); re-exports l.22-23 (`pub use slice::collect_lanes;`).
- `crates/zanshin-graph/src/slice.rs` (NEW) -- SPDX + module doc (why `slice.rs`: the revset-selected slice of the commit graph = the `GraphSlice` wire payload's source; why no windowing: WIP-rework + ADR-0002; a future page = early-exit sink on `stream_lanes`, never a scan over held rows); `pub fn collect_lanes(repo: &zanshin_jj::Repo, revset: &str, prioritize: &str) -> Result<Vec<Row>, LaneStreamError>` = `Vec::new()` + `stream_lanes(.., |row| { rows.push(row); ControlFlow::Continue(()) })?` + `Ok(rows)`; the sink never breaks, so the returned flow is always `Continue` — bind it to `let _exhausted` with a one-line WHY (no `debug_assert`, 4.1 review precedent). Rustdoc: `jj log` order, pass-through params + `DEFAULT_GRAPH_PRIORITIZE` pre-fill, `total_rows` on the wire == `len()`, `# Errors` (both `LaneStreamError` variants). No inline tests needed (no private items; `tests/slice.rs` covers every line).
- `crates/zanshin-graph/tests/stream.rs` -- golden test scaffolding to mirror in the new `tests/slice.rs`: `ENV_GUARD`/`pin_env` l.15-25, `commit_id_of` l.44-48 (commit ids via `resolve_revset` + `Repo::get_change`), `row(..)` builder l.51-65, hand-traced tiny expectation l.82-91, medium invariant block l.177-214, error matchers l.254-336. `collect_rows` l.28-41 is the `stream_lanes` collector to compare against (re-declare locally; tests are separate crates).
- `crates/zanshin-graph/tests/slice.rs` (NEW) -- one test per I/O-matrix row naming `collect_lanes` (tiny exact rows + equality with the `stream_lanes` collection, `none()` → c3 first, medium invariants + determinism, empty, parse error either param, resolution error).
- `crates/zanshin-graph/Cargo.toml` -- deps already complete (`thiserror`, `zanshin-jj`; dev `test-helpers`) — no change expected.
- `crates/zanshin-ffi/src/graph.rs` -- rustdoc l.59-61 "`total_rows == rows.len()` (WIP return-all semantics; Story 4.4 windowing may decouple it)" → reword to "Story 4.4 delivered return-all; windowing is deferred past WIP and may decouple it later" (doc only; code untouched).
- `docs/ffi-abi.md` -- l.372-374 `total_rows` bullet: same reconciliation (4.4 = return-all via `zanshin_graph::collect_lanes`; windowing deferred past WIP).
- `_bmad-output/planning-artifacts/epics.md` -- §Story 4.4 l.2878-2933 (stale `render_slice(cache, start, count)` ACs; WIP-rework note l.2880): APPEND a dated "Delivered (2026-08-23)" note after l.2880 (4.2/4.3 precedent) naming `collect_lanes`, `Vec<Row>`, no windowing/limit/reversed, tests file.
- `_bmad-output/planning-artifacts/architecture.md` -- l.445 `slice.rs # FR-GR-4 render-slice API` → `# FR-GR-4 → return-all lanes for a revset (\`collect_lanes\`, Story 4.4; windowing deferred past WIP)`. (l.446 stale `output.rs` line is a 4.3 deferred item — leave it.)
- `_bmad-output/project-context.md` -- Performance gotcha l.673-675 ("render-slice is O(slice-size), not O(full-cache) … Use the slice API") still assumes a cache: reword to the current truth (slice API = `collect_lanes` collect-all over the lazy stream; a future page composes as an early-exit sink on `stream_lanes`, never a held cache to iterate) and bump `last_revised`/"Last Updated" line minimally (one dated sentence).
- `_bmad-output/implementation-artifacts/deferred-work.md` -- l.100 ("4.4 / 4.6 still need their rewrite at create-story"): annotate **4.4 DELIVERED (2026-08-23)** as `collect_lanes` (no paging); 4.6 still pending.
- `_bmad-output/implementation-artifacts/epic-4-context.md` -- l.14 (4.4 → done + one-line delivery), l.26 (slice semantics: delivered as `collect_lanes`), l.33 ("4.4's `slice.rs` and 4.6's FFI wrapper call `stream_lanes`" → 4.6 calls `collect_lanes`). EDIT LAST.
- `_bmad-output/implementation-artifacts/sprint-status.yaml` -- l.87 `4-4-return-all-lanes-for-revset-api-slice-rs: backlog` → `review` (note "(delivered as collect_lanes over the 4.3 stream, see last_updated)"); l.48 `last_updated` history line: prepend a DEV COMPLETE entry with inline gate evidence, keep the `PREV:` chain (step-04 flips to `done`).
- `coverage-baseline.txt` -- the ratchet adds `crates/zanshin-graph/src/slice.rs` on `cargo make test`; `stream.rs`/`lane.rs` stay 100.00.

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-graph/src/slice.rs` (new) + `crates/zanshin-graph/src/lib.rs` (`mod slice;`, `pub use slice::collect_lanes;`, crate-doc sentence) -- implement `collect_lanes` as the collecting wrapper over `stream_lanes` -- the one-call return-all API 4.6 serialises via `graph_slice_to_envelope`.
- `crates/zanshin-graph/tests/slice.rs` (new) -- fixture tests for every I/O-matrix row (tiny exact + equality with a `stream_lanes` collection, `none()` honoured, medium invariants + determinism, empty, parse/resolution errors) -- end-to-end proof through the public API only.
- `crates/zanshin-ffi/src/graph.rs` (rustdoc phrase), `docs/ffi-abi.md` (`total_rows` bullet) -- reconcile the "4.4 windowing may…" wording -- the ABI doc must not promise what 4.4 decided against for WIP.
- `_bmad-output/planning-artifacts/epics.md` (§4.4 delivered note), `_bmad-output/planning-artifacts/architecture.md:445`, `_bmad-output/project-context.md` (render-slice gotcha), `_bmad-output/implementation-artifacts/deferred-work.md:100`, then `epic-4-context.md` (LAST) -- doc reconciliation -- planning docs stop describing the retired cache-slice; the epic-context cache stays valid.
- `_bmad-output/implementation-artifacts/sprint-status.yaml` -- `4-4` → `review` + `last_updated` DEV entry -- tracking convention.
- run `cargo make test` (unpiped, check exit code) -- fix by refactoring; commit the raised `coverage-baseline.txt`; revert gate churn; one commit -- definition of done.

**Acceptance Criteria:**
- Given a `zanshin_jj::Repo` on a fixture, when `zanshin_graph::collect_lanes(&repo, revset, prioritize)` runs, then it returns `Ok(Vec<Row>)` holding exactly the rows `stream_lanes` would push for the same arguments, in the same (`jj log`) order, with `LaneAssigner::finish()` having run, and a second call on the same handle returns an equal `Vec` (no retained state).
- Given an invalid or unresolvable `revset` or `prioritize`, when `collect_lanes` runs, then it returns the corresponding `LaneStreamError::Revset` and never panics or returns partial rows.
- Given the finished tree, when `cargo make test` runs unpiped, then it exits 0 with `crates/zanshin-graph/src/slice.rs` ≥ 80 % in the coverage summary, no regression elsewhere, hygiene gates green; `git status` is clean after the single commit (deliberate gate-churn reverts aside).

## Spec Change Log

## Review Triage Log

## Design Notes

- **Why `collect_lanes` in `slice.rs` (not `render_slice`, not a `GraphSlice` struct):** the file name follows the epic/architecture tree and the 4.2 wire payload (`GraphSlice` = the revset-selected slice of the graph); the function name joins the crate's verb family `assign_lanes` / `stream_lanes` / `collect_lanes` and says what it returns. A one-field `GraphSlice { rows }` Rust struct is an abstraction for single-use code; `total_rows` is redundant under return-all (the FFI builder derives it).
- **Why no `limit` / `reversed` pass-through despite FR-JJ-17:** both are `jj log` presentation/paging knobs (`take(limit)` on the output stream, `--reversed` on the printed order — `cli/src/commands/log.rs` @ v0.42.0 l.235); the WIP-rework of this story explicitly dropped windowing/pagination, and the GUI can reverse/limit its own list. The streaming API (`stream_lanes` + `Break`) already gives a consumer a prefix in O(prefix). Re-evaluate when windowing returns (release phase, once UI scroll patterns are known).
- **Why no op-id in the result:** coherency is the op-heads watcher's job (ADR-0002); exposing the derived-at op id was rejected in the 4.3 review as speculative until 4.6 shows a need.
- **Sketch:**
  ```rust
  pub fn collect_lanes(repo: &zanshin_jj::Repo, revset: &str, prioritize: &str) -> Result<Vec<Row>, LaneStreamError> {
      let mut rows = Vec::new();
      // The sink never breaks, so the stream is always exhausted (finish() ran).
      let _exhausted = stream_lanes(repo, revset, prioritize, |row| { rows.push(row); ControlFlow::Continue(()) })?;
      Ok(rows)
  }
  ```

## Verification

**Commands:**
- `cargo test -p zanshin-graph` -- expected: green (`tests/lane.rs` + `tests/stream.rs` untouched, new `tests/slice.rs` green).
- `cargo clippy --workspace --all-targets -- -D warnings` and `cargo fmt --all --check` -- expected: clean without any new `#[allow]`.
- `cargo make test` (unpiped) -- expected: exit 0; coverage summary lists `crates/zanshin-graph/src/slice.rs` ≥ 80.00, no regressions; `coverage-baseline.txt` updated → commit it.
- `git status --porcelain` after the commit -- expected: empty.
