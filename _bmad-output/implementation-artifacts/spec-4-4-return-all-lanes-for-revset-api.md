---
title: 'Story 4.4: Return-all-lanes-for-revset API (`slice.rs`) — collect-all over the lazy lane stream'
type: 'feature'
created: '2026-08-23'
status: 'done'
baseline_revision: '28f52275382c6c18cadd3c3399e46469fabbe319'
review_loop_iteration: 0
followup_review_recommended: true
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-4-context.md'
warnings: ['oversized']
deferred:
  - summary: >-
      The "re-derived from head on every call, nothing retained" contract of `collect_lanes`
      is pinned only by a same-state equality assertion (two calls, unchanged repo), which a
      memoising implementation would also satisfy; no test advances the repo between two
      `collect_lanes` calls on the same handle.
    evidence: |-
      `crates/zanshin-graph/tests/slice.rs` (medium determinism test) asserts `rows == rows_again`
      on an unchanged fixture. The only re-derive-after-external-op test lives at the stateful
      layer: `walk_graph_rederives_from_head_so_an_external_commit_appears_on_the_next_call`
      in `crates/zanshin-jj/tests/graph.rs` (jj-lib transaction). `collect_lanes` is a stateless
      free function over that layer, and `zanshin-graph` deliberately has no `jj-lib` (not even
      dev) dependency while `crates/test-helpers` exposes only `extract_fixture` — mirroring the
      test here needs a jj-lib write helper in `test-helpers` (a reviewed, deliberate addition)
      or Story 4.6's real-cdylib op-heads re-derive test, which is the surface where staleness
      would actually bite.
    location: >-
      crates/zanshin-graph/tests/slice.rs (collect_lanes_medium_all_satisfies_structural_invariants_and_is_deterministic)
    severity: low
  - summary: >-
      `docs/adr/0002-…md` line 94 still says "Still open for the graph only: `zanshin-graph`'s
      lane-build + render-slice cost at 10k (Epic 4) — that decides materialize-vs-stream",
      although AC-4 (line 89) records that decision as resolved and Stories 4.3/4.4 delivered the
      stream + collect-all.
    evidence: |-
      `docs/adr/0002-repository-state-model-warm-loader-reload-per-operation.md:94` (benchmark
      bullet, "Still open for the graph only") vs. `:89` ("superseded (AC-4 resolved
      2026-06-22)"). Pre-existing stale sentence surfaced by the Blind Hunter while reviewing the
      4.4 doc reconciliation; not caused by 4.4 (4.3 left it untouched too).
    location: >-
      docs/adr/0002-repository-state-model-warm-loader-reload-per-operation.md:94
    severity: low
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

### 2026-08-23 — Review pass
- intent_gap: 0
- bad_spec: 0
- patch: 12: (high 0, medium 0, low 12)
- defer: 2: (high 0, medium 0, low 2)
- reject: 12
- addressed_findings:
  - `[low]` `[patch]` `schemas/envelope.fbs` `GraphSlice` table doc (and thus `envelope_generated.rs` / `envelope_zanshin.ffi_generated.dart`) still said "Story 4.4 windowing may set total_rows > rows.length later (breaking change allowed in WIP)" while `graph.rs`/`ffi-abi.md` were reconciled — doc comment reworded to "Return-all semantics (Story 4.4)… windowing deferred past WIP", `cargo make codegen` re-run (comment-only drift in both generated accessors; header/bindings unchanged).
  - `[low]` `[patch]` `epic-4-context.md` "FFI surface (4.6)" bullet still said "`start`/`count` stay plain `u32`", contradicting the new slice-semantics / "4.6 calls `collect_lanes`" lines (also flagged by the intent auditor) — reworded: the wrapper passes `revset` + `prioritize` through, no `start`/`count` scalars; the epic's `zanshin_graph_slice(handle, start, count)` text is stale until windowing returns.
  - `[low]` `[patch]` `epic-4-context.md` "Slice semantics" still ended with an unconditional "out-of-range start / oversized count clamp rather than panic" for parameters this story removed — made explicitly conditional ("if paging ever returns … today no such parameters exist").
  - `[low]` `[patch]` `project-context.md` `overrides:` audit trail had no entry for FR-GR-4 / NFR-P-2 / Story 4.4 although the body gotcha was rewritten — added the override entry (render-slice over a row range → `collect_lanes` return-all; windowing deferred past WIP).
  - `[low]` `[patch]` `prd.md` FR-GR-4 / NFR-P-2 rows still read as row-range render-slice with no pointer to the rework (also flagged by the intent auditor) — inline dated annotations added (FR-GR-2/ADR-0001 precedent), no requirement text deleted.
  - `[low]` `[patch]` `docs/ffi-abi.md` `total_rows` bullet was self-contradictory ("deferred past WIP … allowed in WIP") — reworded to "an in-place wire change — edit the `.fbs`, regenerate, update all callers".
  - `[low]` `[patch]` Blank/empty `prioritize` → `ParseError` and unresolvable `prioritize` → `ResolutionError` (documented on `stream_lanes`, tested there) had no `collect_lanes` counterpart and the rustdoc omitted the blank rule — added `collect_lanes_blank_prioritize_returns_revset_parse_error` (`""`, `"   "`) and `collect_lanes_unresolvable_prioritize_returns_revset_resolution_error`; rustdoc sentence added.
  - `[low]` `[patch]` The deliberate non-pass-through of `jj log --limit`/`--reversed` (an FR-JJ-17 deviation) lived only in the spec's Design Notes — recorded in the `epics.md` §4.4 Delivered note, `deferred-work.md` (4.4 DELIVERED sentence) and `epic-4-context.md` (slice semantics) with the re-evaluation trigger (windowing returns).
  - `[low]` `[patch]` `deferred-work.md` follow-up text still instructed "re-author … 4.4 (`slice.rs` → stream page)" — amended (4.3 DONE, 4.4 delivered as collect-all DONE, 4.6 pending with "no `start`/`count` scalars — the 4.4 API has none").
  - `[low]` `[patch]` `collect_lanes_tiny_all_without_prioritize_honours_the_parameter` never compared the `none()` collection against the `stream_lanes` oracle — equality with `collect_rows(&repo, "all()", "none()")` added.
  - `[low]` `[patch]` Medium invariants dropped the 4.3 mirror's "all edges `Direct`" assertion — added.
  - `[low]` `[patch]` `slice.rs` module doc called the module "the source of the FFI `GraphSlice` wire payload" although nothing consumes it before 4.6 — now "the intended source … (wired in Story 4.6)".

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

## Auto Run Result

Status: done
Blocking condition: none

**Summary of implemented change.** Story 4.4 delivered as the return-all API over the 4.3 lazy lane stream: `crates/zanshin-graph/src/slice.rs` ships `pub fn collect_lanes(repo: &zanshin_jj::Repo, revset: &str, prioritize: &str) -> Result<Vec<Row>, LaneStreamError>` — a collecting sink over the public `stream_lanes` (re-resolve to head per call, `prioritize ∩ revset` CLI prioritisation pass-through, `jj log` order, `finish()` on the exhausted stream, nothing retained). No `LaneCache`/`render_slice`, no `start`/`count`/`limit`/`reversed`, no paging struct, no `total_rows` field (the FFI `GraphSlice` builder derives `total_rows == rows.len()`), no new error type/code, no FFI/.fbs-shape/codegen/Dart/worker changes. The epic's `render_slice(cache, start, count)` ACs are superseded (WIP-rework 2026-05-17 + ADR-0002 AC-4) and the planning docs were reconciled accordingly.

**Files changed (since `28f52275382c6c18cadd3c3399e46469fabbe319`).**
- `crates/zanshin-graph/src/slice.rs` (new) — `collect_lanes` + module/rustdoc (why `slice.rs`, why no windowing, blank-prioritize rule, `# Errors`).
- `crates/zanshin-graph/src/lib.rs` — `mod slice;`, `pub use slice::collect_lanes;`, crate-doc sentence.
- `crates/zanshin-graph/tests/slice.rs` (new, 9 tests after review) — tiny exact hand-traced rows + equality with a `stream_lanes` collection (both prioritize values), `none()` honoured, medium invariants (1002 rows, `@` first, one 3-edge row, all `Direct`, max lane 3, `color_idx`, children-before-parents) + determinism, empty revset, ParseError (bogus revset, `"("` prioritize, blank prioritize), ResolutionError (revset, prioritize).
- `schemas/envelope.fbs`, `crates/zanshin-ffi/src/envelope_generated.rs`, `packages/zanshin_core/lib/src/ffi/envelope_zanshin.ffi_generated.dart` — `GraphSlice` table doc comment reconciled (review patch; comment-only regeneration via `cargo make codegen`, header/bindings unchanged).
- `crates/zanshin-ffi/src/graph.rs` (rustdoc phrase), `docs/ffi-abi.md` (`total_rows` bullet) — "4.4 delivered return-all; windowing deferred past WIP".
- `coverage-baseline.txt` — `crates/zanshin-graph/src/slice.rs = 100.00` (auto-added by the ratchet).
- `_bmad-output/planning-artifacts/epics.md` (§4.4 dated Delivered note incl. the `--limit`/`--reversed` decision), `architecture.md:445`, `prd.md` FR-GR-4 / NFR-P-2 inline annotations (review patch), `_bmad-output/project-context.md` (render-slice-over-cache gotcha rewritten, `overrides:` entry, `last_revised`/Last Updated), `_bmad-output/implementation-artifacts/deferred-work.md` (4.4 DELIVERED, follow-up text amended), `epic-4-context.md` (4.4 done, slice semantics, 4.6 calls `collect_lanes`, no `start`/`count` scalars — touched last), `sprint-status.yaml` (4-4 → done + `last_updated` entries), this spec.

**Review findings breakdown.** 4 layers (Blind Hunter 20, Edge Case Hunter 2, Verification Gap 1, Intent Alignment ~6 descriptive divergences) → 29 raw → 26 unique: 0 intent_gap, 0 bad_spec, 12 patch (all low — applied, see Review Triage Log), 2 defer (frontmatter `deferred`: re-derive-after-external-op test at the `collect_lanes` surface needs a jj-lib write helper; ADR-0002:94 stale "still open" sentence), 12 reject. Rejected: the `LaneStreamError::Graph`/"finish ran" path is not observable through `collect_lanes` with real fixtures — the intent-contract mandates calling the public `stream_lanes` (whose `finish()` path is pinned by its inline synthetic-walk test) and the propagation is the single `?` shared with the tested `Revset` path; a silently discarded `Break` (impossible — the sink never breaks; the comment says so; `debug_assert` rejected per the 4.1 precedent); `total_rows` saturation at `u32::MAX` (documented on the builder, unreachable); mid-stream `JjLibError`/"no partial rows" at this surface (type-level `Result` guarantee; mid-stream failure pinned at `walk_graph`); `ffi-abi.md` naming a Rust producer fn (the section already names `graph_slice_to_envelope`); the single-line `sprint-status.yaml` history (Ralph's tracking convention); `warnings: ['oversized']` / empty log headers (workflow format); epic-context mtime vs the spec file (validity rule concerns `planning-artifacts` only); `prioritize` not named in the epic text (FR-JJ-17 + 4.3 precedent); tests restating `stream.rs` facts (descriptive); the `epics.md` 4.6 `zanshin_graph_slice(handle, start, count)` text (4.6's create-story rewrite, tracked in deferred-work and now annotated in epic-4-context); the 1002-row comment derivation. Zero correctness defects in the 4.4 code.

**Follow-up review recommendation.** Patched this pass: high 0, medium 0, low 12 → score 0 × 3 + 12 = 12 ≥ 5 → `followup_review_recommended: true`.

**Verification performed.** Implementation run: `cargo make test` exit 0 (209 s), coverage RAISED (`slice.rs = 100.00` new, overall 98.64 % = 3112/3155 over 30 files, 0 regressions), committed as `5367bb5`. Review pass: `cargo test -p zanshin-graph --test slice` 9/9 green; `cargo fmt --all --check` clean; `cargo clippy --workspace --all-targets -- -D warnings` clean (no new `#[allow]`); `cargo make codegen` after the `.fbs` comment edit → comment-only drift in the two generated accessor files, `zanshin_ffi.h`/`bindings.dart` unchanged; full gate `cargo make test` unpiped (stdout redirected to a file, exit code read directly) → **exit 0** in 212.9 s: cargo test workspace (incl. 9 `tests/slice.rs`, 12 `tests/stream.rs`, 20 `tests/lane.rs`), clippy pedantic, rustfmt, flutter test, dart analyze/format, cargo deny, jj-adapter hygiene, coverage ratchet `coverage-check: OK — coverage held at 98.64% (3112/3155 lines)`, `coverage-baseline.txt` unchanged by the review pass, `extern-coverage: OK`; `flutter`/`dart` gate churn (`app/analysis_options.yaml`, `pubspec.lock`) reverted, not committed.

**Residual risks.** (1) "Nothing retained across calls" at the `collect_lanes` surface is guaranteed structurally (stateless free function over `walk_graph`, which IS tested for re-derive after an external op) but not by a test at this surface (deferred). (2) The `--limit`/`--reversed` non-pass-through is a deliberate FR-JJ-17 deviation tied to the WIP windowing deferral; it must be re-evaluated when windowing returns (recorded in epics/deferred-work/epic-context). (3) `epics.md` §4.6 still describes `zanshin_graph_slice(handle, start, count)`; 4.6's create-story rewrite (tracked) must drop the paging scalars — `epic-4-context.md` already says so.
