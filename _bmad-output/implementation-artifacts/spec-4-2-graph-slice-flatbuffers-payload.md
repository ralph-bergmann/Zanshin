---
title: 'Story 4.2: GraphSlice FlatBuffers payload (was: JSON output + graph.v1.schema.json)'
type: 'feature'
created: '2026-08-22'
status: 'done'
baseline_revision: 'ef2e0b6636e4882bd551cb233f1b73d89d44ce30'
review_loop_iteration: 0
followup_review_recommended: true
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/docs/adr/0001-ffi-data-transport-flatbuffers.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-4-context.md'
warnings: ['oversized']
deferred:
  - summary: >-
      zanshin-ffi lib.rs module doc still points at the pre-move Dart bindings path app/lib/src/ffi/bindings.dart.
    evidence: |-
      crates/zanshin-ffi/src/lib.rs lines 5-7 say the generated bindings live in `app/lib/src/ffi/bindings.dart`;
      the file this story regenerates (and ffigen.yaml's output) is `packages/zanshin_core/lib/src/ffi/bindings.dart`.
      Pre-existing doc drift from the bridge move to packages/zanshin_core, surfaced by the verification-gap reviewer;
      not caused by Story 4.2.
    location: >-
      crates/zanshin-ffi/src/lib.rs:5-7
    severity: low
---

<intent-contract>

## Intent

**Problem:** Story 4.1 emits lane rows (`zanshin_graph::Row`) as plain Rust values, but nothing can carry them across the FFI boundary yet: the epic's Story 4.2 (serde JSON + `graph.v1.schema.json` + `jsonschema`) is superseded by ADR-0001 — the graph must cross as a FlatBuffers `GraphSlice` payload in the `Envelope` `Payload` union, and the Dart side must decode it through the generated typed accessors (wire-contract parity, the FlatBuffers form of the epic's "validation on both sides").

**Approach:** Append `GraphSlice` / `GraphRow` / `GraphRowEdge` / `GraphEdgeKind` to `schemas/envelope.fbs` (shape reconciled to 4.1's `Row`/`RowEdge`), regenerate both accessor sides via `cargo make codegen`, add the Rust `Row → Envelope<GraphSlice>` builder in `crates/zanshin-ffi/src/graph.rs` (the file Story 4.6 later extends with `zanshin_graph_*` extern fns), add the Dart models + decoder in `packages/zanshin_core/lib/src/ffi/graph.dart`, and pin both sides with round-trip / decode-contract tests. No extern fn, no worker command, no revset/stream wiring (4.3/4.4/4.6).

## Boundaries & Constraints

**Always:**
- FlatBuffers only (ADR-0001): schema in `schemas/envelope.fbs` (append tables + union member **at the end** of `union Payload`, after `Progress`); no `schema_version`, no `.v1`, no JSON, no `serde`. Regenerate with `cargo make codegen` only (never hand-run `flatc`); commit schema + `envelope_generated.rs` + `envelope_zanshin.ffi_generated.dart` together.
- `zanshin-graph` stays FlatBuffers-free and dependency-light (4.1 decision): the builder lives in `zanshin-ffi` (new dep `zanshin-graph` via `[workspace.dependencies]` + `workspace = true`).
- Wire shape mirrors 4.1 exactly: `GraphEdgeKind : byte { Direct, Indirect, Missing }` in `zanshin_graph::EdgeKind` order; `GraphRowEdge { target: string; target_lane: uint; kind: GraphEdgeKind }`; `GraphRow { commit_id: string; lane: uint; color_idx: uint; edges: [GraphRowEdge] }`; `GraphSlice { rows: [GraphRow]; total_rows: uint }`. `rows` preserve input order (one per `Row`, `edges` one per `RowEdge`, same order).
- `target_lane` absence: `flatc 25.12.19` rejects optional scalars (`= null`) for Dart (verified) → presence is encoded by `kind`: `target_lane` is meaningful only when `kind != Missing` (Rust writes `target_lane.unwrap_or(0)`); the Dart model exposes `int? targetLane`, `null` iff `kind == Missing` (null-for-absence at the model level, same presence-flag pattern as `RepoDetect.suggested_kind` / `Bookmark.remote_name`). Document this on the table.
- `total_rows` = `rows.len()` (WIP return-all semantics; 4.4 windowing may pass it explicitly later — breaking changes allowed).
- Builder is infallible → no new error code, `docs/rust-error-codes.md` untouched. Every `pub` item doc-commented; SPDX first line on new `.rs`/`.dart` files; clippy pedantic refactor-not-suppress; tests read buffers via generated typed accessors + `flatbuffers::root` (Verifier).
- Coverage ratchet: new `crates/zanshin-ffi/src/graph.rs` ≥ 80 % via inline `#[cfg(test)]` tests (no extern fn ⇒ no real-cdylib `zanshin_core` test needed); commit the auto-raised `coverage-baseline.txt` with the code.
- Repo conventions: one focused commit on `main` (`feat(zanshin-ffi): add GraphSlice FlatBuffers payload + Dart decoder (Story 4.2)`), story artifacts (`spec`, `epic-4-context.md`, `sprint-status.yaml`) included; `flutter`/`dart` gate side-effect churn (`app/analysis_options.yaml`, `pubspec.lock`) reverted, not committed (4.1 precedent).

**Block If:**
- `cargo make codegen` fails or `flatc` rejects the schema in a way that forces a different wire shape than the one above.
- `cargo make test` fails for a reason outside this story (pre-existing regression, tooling absent) that cannot be fixed inside the story's scope — do not lower the baseline, do not add `exclude_prefix`.

**Never:**
- No `extern "C"` fn, no `zanshin_ffi.h`/`bindings.dart` content change expected, no `WorkerCommand`, no `isolate.dart` / `zanshin_core.dart` export change (Story 4.6).
- No revset/stream wiring, no `zanshin-jj` access, no fixtures, no perf asserts (4.3/4.4; perf deferred).
- No separate `schemas/graph.fbs` (keeps `verify-codegen`'s single-file assumption valid; all nouns live in `envelope.fbs`).
- No per-row pass-through-lane info, no metadata enrichment (change id, description, …) — anti-speculation.
- Do not touch `zanshin_graph::Row`/`RowEdge`/`lane.rs`.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Round-trip (Rust) | 3 `Row`s from a fork-then-merge shape: one row with 2 edges (`Direct` → `Some(0)`, `Indirect` → `Some(1)`), one with a `Missing` edge (`target_lane: None`), one root with no edges; one id containing non-ASCII/odd chars | `Envelope { ok: true, data_type: GraphSlice }`; Verifier passes; mapping the payload back to `Vec<Row>` (`Missing` ⇒ `None`) equals the input; `total_rows == 3`; strings verbatim (no escaping) | None |
| Empty slice (Rust) | `&[]` | `ok`, `rows` present with `len() == 0`, `total_rows == 0` | None |
| Missing edge on wire | `RowEdge { target_lane: None, kind: Missing }` | `GraphRowEdge { target_lane: 0, kind: Missing }` | None |
| Kind mapping | each `EdgeKind` variant | `Direct→Direct`, `Indirect→Indirect`, `Missing→Missing` (exhaustive match) | None |
| Decode happy (Dart) | `EnvelopeObjectBuilder(ok, dataType: GraphSlice, data: GraphSliceObjectBuilder(...))` with rows above | `GraphSlice.rows` field-by-field equal; `targetLane == null` for `Missing`, `int` otherwise; `totalRows` | None |
| Decode empty (Dart) | slice with `rows: []`, `totalRows: 0` | `rows` empty list, `totalRows 0` | None |
| Error envelope (Dart) | `ok: false, error: {code, context}` | — | throws `ZanshinFfiException(code, context)` |
| Wrong payload (Dart) | `ok: true`, `dataType: RepoHandle` | — | throws `ZanshinFfiException('ffi.unknown', …)` (discriminant guard) |

</intent-contract>

## Code Map

- `schemas/envelope.fbs` -- the ONLY schema file; append the four graph types before `union Payload` (after `Progress`, l.200-205) and `GraphSlice` as the last union member (l.207-218); update the registry comment l.38 (`Story 4-6 : GraphSlice` → `Story 4-2 : GraphSlice ✓ (FFI wrapper 4-6)`). Doc-comment style: `///` per table, `//` trailing per field.
- `crates/zanshin-graph/src/lane.rs` -- source types to serialise: `Row { commit_id, lane: u32, color_idx: u32, edges: Vec<RowEdge> }` (l.97-106), `RowEdge { target, target_lane: Option<u32>, kind }` (l.74-83, `None` iff `Missing`), `EdgeKind { Direct, Indirect, Missing }` (l.22-33). READ-ONLY.
- `crates/zanshin-ffi/src/op_log.rs` -- golden pattern for a vector-of-tables payload builder (`op_log_to_envelope`, l.33-77: children-before-parents, `b.create_vector`, `data_type: fbs::Payload::X`, `as_union_value()`, `b.finish(envelope, None)`) and its inline round-trip test (l.150-217, `flatbuffers::root as fb_root`).
- `crates/zanshin-ffi/src/change.rs` -- pattern for enum mapping into `fbs::` enums + nested tables (l.42-121); nested per-row string/vector offsets must be created before the row table.
- `crates/zanshin-ffi/src/lib.rs` -- add `pub mod graph;` to the noun module list (l.32-44); `pub use envelope_generated::zanshin::ffi as fbs;` (l.27) is the accessor alias.
- `crates/zanshin-ffi/Cargo.toml` -- `[dependencies]` l.22-31: add `zanshin-graph = { workspace = true }`; root `Cargo.toml` `[workspace.dependencies]` l.28-44: add `zanshin-graph = { path = "crates/zanshin-graph", version = "0.1.0" }` (mirror the `zanshin-jj` line l.43).
- `packages/zanshin_core/lib/src/ffi/op_log.dart` -- golden Dart decoder pattern: models (`final class`, doc comments), `@visibleForTesting decodeXEnvelope` + `decodeXEnvelopeInternal` + private `_decode…` with `!env.ok` → `ZanshinFfiException`, `payload is! fbs.X` → `'ffi.unknown'`, `?.map(...).toList() ?? const []`. `change.dart` l.181-184 shows the `switch` enum mapping. New `graph.dart` needs NO `dart:ffi`/`bindings.dart` import (no adapter fn yet).
- `packages/zanshin_core/test/ffi/change_test.dart` -- golden decode-contract test: synthetic buffers via `fbs.EnvelopeObjectBuilder(ok:, dataType: fbs.PayloadTypeId.X, data: fbs.XObjectBuilder(...)).toBytes()`; error + wrong-payload + happy cases. Nested builders for `GraphRowObjectBuilder(edges: [GraphRowEdgeObjectBuilder(...)])`.
- `packages/zanshin_core/lib/src/worker/responses.dart` -- `ZanshinFfiException(code, context)` (import path `../worker/responses.dart`).
- `Makefile.toml` l.226-281 -- `cargo make codegen` = flatc rust+dart (globbed `schemas/*.fbs`, rustfmt/dart-format applied) + cbindgen + ffigen; outputs committed; `verify-codegen` is hard-coded to the envelope files (l.295-296) — staying in `envelope.fbs` keeps it valid.
- `docs/ffi-abi.md` -- extend with a "GraphSlice payload (Story 4.2)" section in the style of "Payload schemas" (l.266-291): table shapes, `target_lane` presence rule, `total_rows` semantics, row order = stream/`jj log` order, "no extern fn yet — Story 4.6".
- `coverage-baseline.txt` -- ratchet adds `crates/zanshin-ffi/src/graph.rs = <pct>` automatically on `cargo make test`; `new_file_floor_pct = 80.00`.
- `_bmad-output/implementation-artifacts/sprint-status.yaml` -- l.85 key `4-2-json-output-graph-schema-json: backlog`; l.48 `last_updated` is the running history line (prepend the new entry, keep `PREV:` chain).
- `test-fixtures/ffi/envelope_error.bin` -- committed error-envelope fixture; appending union members/tables does not change its bytes — leave it.

## Tasks & Acceptance

**Execution:**
- `Cargo.toml` (root) + `crates/zanshin-ffi/Cargo.toml` -- add the `zanshin-graph` workspace dep and consume it in `zanshin-ffi` -- the builder needs `zanshin_graph::{Row, RowEdge, EdgeKind}`.
- `schemas/envelope.fbs` -- append `GraphEdgeKind`, `GraphRowEdge`, `GraphRow`, `GraphSlice` (doc-commented incl. the `target_lane`-meaningful-only-when-`kind != Missing` rule and `total_rows == rows.len()` in WIP) + `GraphSlice` as last `Payload` member + registry comment -- wire contract source of truth.
- run `cargo make codegen` -- regenerates `crates/zanshin-ffi/src/envelope_generated.rs` + `packages/zanshin_core/lib/src/ffi/envelope_zanshin.ffi_generated.dart` (header/bindings expected unchanged; commit whatever it emits) -- generated code is committed, never hand-edited.
- `crates/zanshin-ffi/src/graph.rs` (new) + `crates/zanshin-ffi/src/lib.rs` (`pub mod graph;`) -- SPDX + module doc; `pub fn graph_slice_to_envelope(rows: &[Row]) -> Vec<u8>` (children-before-parents; `total_rows` from `rows.len()` via `u32::try_from(...)`, no `as` casts — clamp/`unwrap_or(u32::MAX)` is acceptable since a slice > 4·10⁹ rows is impossible, document) + private `fn edge_kind(EdgeKind) -> fbs::GraphEdgeKind`; inline tests for every I/O-matrix Rust row (round-trip back to `Vec<Row>`, empty, Missing→0, exhaustive kind mapping) -- the payload producer 4.6 will call; must be `pub` (no in-crate caller yet → `dead_code` under `-D warnings` otherwise).
- `packages/zanshin_core/lib/src/ffi/graph.dart` (new) -- models `GraphEdgeKind { direct, indirect, missing }`, `GraphRowEdge { target, targetLane (int?), kind }`, `GraphRow { commitId, lane, colorIdx, edges }`, `GraphSlice { rows, totalRows }`; `@visibleForTesting decodeGraphSliceEnvelope` + `decodeGraphSliceEnvelopeInternal` + `_decodeGraphSliceEnvelope` with the ok/discriminant guards; `targetLane = kind == missing ? null : e.targetLane` -- Dart half of the wire contract.
- `packages/zanshin_core/test/ffi/graph_test.dart` (new) -- decode-contract tests for every I/O-matrix Dart row using the generated `*ObjectBuilder`s -- parity with the Rust round-trip (AR-P-7).
- `docs/ffi-abi.md` -- add the GraphSlice payload section -- implementors of 4.6 and the UI read the ABI here.
- `_bmad-output/implementation-artifacts/sprint-status.yaml` -- set `4-2-json-output-graph-schema-json` → `review` with a note "(reconciled JSON→FlatBuffers GraphSlice per ADR-0001, see last_updated)" and prepend a `last_updated` entry -- repo tracking convention (every story updates it; the orchestrator flips it to `done` at HALT).
- run `cargo make test` (unpiped) -- fix findings by refactoring; commit the raised `coverage-baseline.txt`; revert `app/analysis_options.yaml` / `pubspec.lock` churn -- the single quality gate is the definition of done.

**Acceptance Criteria:**
- Given the appended schema, when `cargo make codegen` runs, then `fbs::Payload::GraphSlice` (Rust) and `fbs.PayloadTypeId.GraphSlice` + `fbs.GraphSliceObjectBuilder` (Dart) exist, the header/bindings are unchanged (or only trivially regenerated), and the existing `envelope_error.bin` fixture test still passes.
- Given `graph_slice_to_envelope(&rows)` for any rows produced by `zanshin_graph::assign_lanes`, when the buffer is read via `flatbuffers::root::<fbs::Envelope>`, then `ok == true`, `data_type == Payload::GraphSlice`, `rows.len() == total_rows == input len`, and each `GraphRow`/`GraphRowEdge` matches the input field-by-field (`Missing` ⇒ `target_lane 0`, kind `Missing`).
- Given a Rust-shaped `GraphSlice` buffer, when `decodeGraphSliceEnvelope` runs in Dart, then the typed model equals the builder input, with `targetLane == null` exactly for `Missing` edges.
- Given the full `cargo make test` gate, when run unpiped, then it exits 0 with `crates/zanshin-ffi/src/graph.rs` ≥ 80 % (expected 100 %) and no coverage regression elsewhere.
- Given the finished tree, when `git status` is checked after the single commit, then it is clean (except deliberate reverts of gate churn).

## Spec Change Log

## Review Triage Log

### 2026-08-22 — Review pass
- intent_gap: 0
- bad_spec: 0
- patch: 8: (high 0, medium 3, low 5)
- defer: 1: (high 0, medium 0, low 1)
- reject: 11: (high 0, medium 0, low 11)
- addressed_findings:
  - `[medium]` `[patch]` Rust round-trip fixtures all had `lane == color_idx` (lanes < PALETTE_SIZE), so a lane/color_idx cross-wire in `row_offset` was undetectable (verification-gap) → added `lane_and_color_idx_are_written_to_distinct_slots` (lane 9 / color_idx 1, both slots asserted independently via the typed accessors + `rows_from_wire` equality) in `crates/zanshin-ffi/src/graph.rs`.
  - `[medium]` `[patch]` Dart decode fixtures likewise never distinguished `lane` from `colorIdx` in `_mapRow` → added `decodes lane and colorIdx into distinct fields` (lane 9 / colorIdx 1) in `packages/zanshin_core/test/ffi/graph_test.dart`.
  - `[medium]` `[patch]` `_bmad-output/planning-artifacts/epics.md` § Story 4.2 still described the payload as `change_id`/`edges_below`/`parents` + `output.rs` and "effectively merges into 4.6" → appended a dated "Delivered standalone (2026-08-22)" note with the actual commit-id-keyed merged-edge shape, file locations, and pointers to this spec + `docs/ffi-abi.md`.
  - `[low]` `[patch]` `epic-4-context.md` (new in this diff) contradicted the delivery ("effectively merged into 4.6", "4.2 collapses into 4.6", 4.6 "extend ffi-abi.md" as if from scratch) → Stories list marks 4.2 done/standalone, the 4.6 bullets point at the existing builder/decoder and the existing ffi-abi section, the cross-story dependency is reworded.
  - `[low]` `[patch]` An out-of-range `GraphEdgeKind` byte surfaces as the generated `StateError`, undocumented for this decoder → doc note on `decodeGraphSliceEnvelope` (mirrors the 3-4c `RepoKind` by-design rule in `repo_detect.dart`) + one sentence in the `docs/ffi-abi.md` decode-contract bullet.
  - `[low]` `[patch]` `docs/ffi-abi.md` did not say the Dart models/decoder are unreachable from the package API until 4.6 → added a "Reachability (until 4.6)" bullet.
  - `[low]` `[patch]` `schemas/envelope.fbs` `GraphSlice.rows` / `total_rows` lacked the trailing `//` field comments every other new field carries (the rows-always-present guarantee lived only in ffi-abi.md) → added them; `cargo make verify-codegen` confirms zero generated drift.
  - `[low]` `[patch]` `sprint-status.yaml` DEV entry ended with "Gate: see commit." instead of the inline gate evidence the history line carries by convention → gate numbers from commit `7a10417` written into the DEV entry; REVIEW DONE entry prepended with this pass's gate numbers; `4-2` key flipped review → done.

## Design Notes

- **Why `zanshin-ffi/src/graph.rs`, not `zanshin-graph/src/output.rs`:** the epic's `output.rs` was a serde module; under ADR-0001 the generated Rust accessors live only in `zanshin-ffi` (`envelope_generated.rs`), and 4.1 deliberately kept `zanshin-graph` free of FlatBuffers/codegen. Story 4.6 adds `zanshin_graph_*` extern fns to this same file (project-context module layout: one file per noun).
- **Builder sketch (mirror `op_log_to_envelope`):**
  ```rust
  for row in rows {
      let edge_offs: Vec<_> = row.edges.iter().map(|e| {
          let target = b.create_string(&e.target);
          fbs::GraphRowEdge::create(&mut b, &fbs::GraphRowEdgeArgs {
              target: Some(target), target_lane: e.target_lane.unwrap_or(0), kind: edge_kind(e.kind) })
      }).collect();
      let edges = b.create_vector(&edge_offs);
      let commit_id = b.create_string(&row.commit_id);
      row_offs.push(fbs::GraphRow::create(&mut b, &fbs::GraphRowArgs { commit_id: Some(commit_id), lane: row.lane, color_idx: row.color_idx, edges: Some(edges) }));
  }
  ```
  (Note: closure captures `&mut b` — if the borrow checker objects, use a plain `for` loop pushing into a `Vec`, as `change.rs` does.)
- **Schema reconciliation vs. epic text:** epic 4.2 note lists `change_id`/`edges_below`/`parents`; Story 4.1 (R2/R3, Ralph-accepted defaults) replaced them with `commit_id` + merged `edges[{target, target_lane, kind}]` — this spec follows 4.1 (the code truth). The epic's `< 5 MB / < 200 ms` numbers stay soft targets (no test).

## Verification

**Commands:**
- `cargo make codegen` -- expected: exit 0; `git status` shows `schemas/envelope.fbs`, `crates/zanshin-ffi/src/envelope_generated.rs`, `packages/zanshin_core/lib/src/ffi/envelope_zanshin.ffi_generated.dart` modified (header/bindings ideally untouched).
- `cargo test -p zanshin-ffi graph` -- expected: all new inline tests green (fast inner loop).
- `dart test test/ffi/graph_test.dart` (cwd `packages/zanshin_core`) -- expected: green.
- `cargo make test` (unpiped) -- expected: exit 0; coverage summary lists `crates/zanshin-ffi/src/graph.rs` ≥ 80.00, no regressions; `coverage-baseline.txt` updated → commit it.
- `git status --porcelain` after the commit -- expected: empty.

## Auto Run Result

Status: done
Blocking condition: none

**Summary of implemented change.** Story 4.2 reconciled to ADR-0001: the lane graph (Story 4.1 `zanshin_graph::Row`) now has a FlatBuffers wire form — `GraphEdgeKind` / `GraphRowEdge` / `GraphRow` / `GraphSlice` appended to `schemas/envelope.fbs` (`GraphSlice` last in `union Payload`, disc 11), both accessor sides regenerated via `cargo make codegen`, an infallible Rust builder `zanshin_ffi::graph::graph_slice_to_envelope(&[Row]) -> Vec<u8>` in the new `crates/zanshin-ffi/src/graph.rs`, Dart models + decoder in the new `packages/zanshin_core/lib/src/ffi/graph.dart`, and round-trip / decode-contract tests on both sides. `target_lane` presence rides on `kind` (Rust writes 0 for `Missing`, Dart `int?` null). No extern fn, worker command, export, or revset wiring (Story 4.6). The implementation landed as commit `7a10417` (first run, interrupted before review); this resumed run performed the review pass and applied the review patches below.

**Files changed (since baseline `ef2e0b6636e4882bd551cb233f1b73d89d44ce30`).**
- `schemas/envelope.fbs` — four graph types + `GraphSlice` union member + registry comment; review patch: trailing `//` comments on the `GraphSlice` fields.
- `crates/zanshin-ffi/src/envelope_generated.rs`, `packages/zanshin_core/lib/src/ffi/envelope_zanshin.ffi_generated.dart` — flatc output (committed; unchanged by the review pass).
- `crates/zanshin-ffi/include/zanshin_ffi.h`, `packages/zanshin_core/lib/src/ffi/bindings.dart` — generated `ENUM_*` / `*_VT_*` constants only.
- `crates/zanshin-ffi/src/graph.rs` (new) — builder + private `edge_kind` + inline tests (6 after review: + `lane_and_color_idx_are_written_to_distinct_slots`).
- `crates/zanshin-ffi/src/lib.rs` — `pub mod graph;`.
- `Cargo.toml`, `crates/zanshin-ffi/Cargo.toml`, `Cargo.lock` — `zanshin-graph` workspace dep consumed by `zanshin-ffi`.
- `packages/zanshin_core/lib/src/ffi/graph.dart` (new) — models + `decodeGraphSliceEnvelope` / `decodeGraphSliceEnvelopeInternal`; review patch: StateError-by-design doc note.
- `packages/zanshin_core/test/ffi/graph_test.dart` (new) — 6 decode-contract tests after review (+ lane/colorIdx distinct-fields test).
- `docs/ffi-abi.md` — "GraphSlice payload (Story 4.2)" section; review patch: StateError note + "Reachability (until 4.6)" bullet.
- `coverage-baseline.txt` — `crates/zanshin-ffi/src/graph.rs = 99.45` (auto-added by the ratchet).
- `_bmad-output/planning-artifacts/epics.md` — review patch: "Delivered standalone" note under Story 4.2.
- `_bmad-output/implementation-artifacts/epic-4-context.md` (new) — Epic 4 context; review patch: 4.2 standalone / 4.6 reuse wording.
- `_bmad-output/implementation-artifacts/sprint-status.yaml` — `4-2` review → done, history-line entries (DEV + REVIEW DONE).
- `_bmad-output/implementation-artifacts/spec-4-2-graph-slice-flatbuffers-payload.md` (new) — this spec.

**Review findings breakdown.** 4 layers (Blind Hunter, Edge Case Hunter, Verification Gap, Intent Alignment) → 29 raw → 20 unique: 0 intent_gap, 0 bad_spec, 8 patch (3 medium, 5 low — all applied, see Review Triage Log), 1 defer (`lib.rs` module-doc bindings path — frontmatter `deferred`), 11 reject (debug/const asserts for the contract-guaranteed None-iff-Missing invariant — 4.1 review precedent; `?? ''` string coercion per the `op_log.dart` golden pattern the contract cites; Dart-side truncated-buffer / unknown-discriminant `StateError` as the pre-existing by-design behaviour of every decoder; cross-language `.bin` fixture — the intent sanctions no real-cdylib test before 4.6; 99.45 % vs the spec's parenthetical "expected 100 %" — the only uncovered line is the unreachable wildcard arm of the test-only `kind_from_wire`; generated header/bindings constant shifts vs the "no content change expected" wording — AC-1 already allows trivial regeneration; `total_rows` clamp comment; untested one-line `Internal` alias; the in-flight uncommitted spec status flip). Zero correctness defects found in the 4.2 code.

**Follow-up review recommendation.** Patched findings: high 0, medium 3, low 5 → score 3×3 + 1×5 = 14 ≥ 5 → `followup_review_recommended: true`.

**Verification performed.**
- `cargo test -p zanshin-ffi --lib graph` — 6 passed.
- `dart test packages/zanshin_core/test/ffi/graph_test.dart` — 6 passed.
- `cargo make verify-codegen` after the `.fbs` comment edit — flatc/cbindgen/ffigen re-run, no drift in any generated file (only `pubspec.lock` resolution churn, reverted).
- `cargo make test` (unpiped, post-patches) — Build Done in 171.83 s: cargo test workspace green (98 zanshin-ffi lib unit tests incl. 6 in `graph.rs`, all integration suites), clippy pedantic / rustfmt / dart analyze / dart format / cargo deny clean, 102 `zanshin_core` dart tests green, coverage held at 98.55 % (2917/2960 lines over 27 files), `graph.rs` 99.45 % (baseline unchanged), extern-coverage OK. `app/analysis_options.yaml` / `pubspec.lock` gate churn reverted (4.1 precedent).
- `git status --porcelain` after the final commit — checked at HALT (must be empty).

**Residual risks.**
- Cross-language byte-level parity rests on the shared schema + hand-mirrored fixtures on each side; the first Rust-produced buffer decoded by Dart arrives with Story 4.6's real-cdylib test.
- `graph_slice_to_envelope` trusts the 4.1 invariant `target_lane.is_none() == (kind == Missing)`; a producer that broke it would serialise a plausible lane 0 (a guard was rejected on the 4.1 precedent).
- Out-of-range `GraphEdgeKind` / unknown `Payload` discriminant / truncated buffer crash loudly on the Dart side by design (version-skew / corruption), consistent with every other decoder.
