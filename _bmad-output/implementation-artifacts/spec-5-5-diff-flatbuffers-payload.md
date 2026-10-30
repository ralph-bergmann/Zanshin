---
title: 'Story 5.5 — Diff output schema (FlatBuffers `Diff` payload, line-level)'
type: 'feature'
created: '2026-10-30'
status: 'done'
baseline_revision: '63132829945ebae58362bf246516233073637ad8'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-5-context.md'
warnings: ['oversized']
deferred: []
---

<intent-contract>

## Intent

**Problem:** Story 5.1's `Repo::compute_hunks` returns `Vec<zanshin_jj::FileDiff>` as Rust values only; nothing can carry a diff — its hunks, lines, counts, symbols, each file's and each hunk's `HunkKey` sections and the `mode_change` toggle — across the FFI. epics.md Story 5.5's serde-JSON / `diff.v1.schema.json` premise is superseded by ADR-0001 (its own blockquote): the diff crosses as a FlatBuffers `Diff` payload. Deferred items I1/I2 hand 5.5 the schema half of their wire gap.

**Approach:** Append a line-level `Diff` payload (`Diff` → `FileDiff` → `Hunk` → `HunkLine`, reusing the existing `HunkKey` table) to `schemas/envelope.fbs`, regenerate the accessors, add the Rust builder `zanshin_ffi::diff::diff_to_envelope(&[FileDiff], &CallReport)` (the file Story 5.8 extends with its extern) and the Dart models + decoder in `packages/zanshin_core/lib/src/ffi/diff.dart`, pinned by round-trip / decode-contract tests on both sides. This is the Story 4.2 pattern (payload first, extern in the wrapper story).

## Boundaries & Constraints

**Always:**
- FlatBuffers only (ADR-0001): no `schema_version`, no `.v1`, no JSON, no `serde`/`jsonschema`/`json_schema`. Tables are appended before `union Payload`; `Diff` is appended as the LAST `Payload` member (append-only discriminants). One file, `schemas/envelope.fbs`. Regenerate only with `cargo make codegen`; commit the generated Rust + Dart (+ header/bindings if they change).
- The wire mirrors `zanshin_jj::FileDiff` / `Hunk` / `HunkLine` field for field, in order: `FileDiff { path, binary, mode_change, sections: [HunkKey], hunks: [Hunk] }`, `Hunk { before_start, before_end, after_start, after_end, symbol, sections: [HunkKey], removed, added, lines: [HunkLine] }`, `HunkLine { kind: HunkLineKind, text }`, `enum HunkLineKind : ubyte { Context, Removed, Added }`, `Diff { files: [FileDiff] }`. Keys are copied verbatim from `compute_hunks` (the existing `HunkKey` table, so a key read is the key `SelectTreeRequest` takes). `symbol` absent = `None`. Vectors are always written (empty, not absent). Files, hunks, lines and sections keep their input order. Ranges are 0-based half-open (`before_end` = `Range::end`).
- The builder is infallible (no new error code), ends through `envelope::finish_envelope` with the caller's `CallReport` (warnings/precondition ride as on every envelope), and is `pub` in a `pub mod diff` (no in-crate caller until 5.8 → `dead_code` otherwise).
- Dart: `final class` models with doc comments; `HunkKey` is reused from `select_tree.dart`; `symbol` is `String?`; ranges are `({int start, int end})` records; `Diff.warnings` via `decodeEnvelopeWarningsInternal`; the decoder follows `decodeSelectedTreeEnvelopeInternal` (error envelope → `decodeEnvelopeErrorInternal`, wrong payload → `ZanshinFfiException('ffi.unknown', …)`, absent vectors → empty).
- Every `pub` item doc-commented, SPDX first line on new files, clippy pedantic refactor-not-suppress, Rust tests read buffers via generated accessors + the Verifier; new `diff.rs` ≥ 80 % by inline tests.

**Never:**
- No `extern "C"` fn, no `WorkerCommand`, no `RepoHandle` method, no export from `zanshin_core.dart`, no `ShowEntry` labels on the wire (all Story 5.8).
- No file kind / `from_path` / per-file counts / summary mode / pinning (Story 5.6 adds them to this table), no word segments / `syntax_class` / `language` (5.2–5.4).
- No change to `zanshin_jj` types or `compute_hunks`; no separate `.fbs` file.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Round trip (Rust) | 2 files: `a.rs` with 2 hunks (one with `symbol: Some("fn main() {")`, one `None`; sections with distinct non-zero `old_start/old_count/new_start/new_count`; Context/Removed/Added lines, a last line without `\n`), file sections ≠ hunk sections; `bin.dat` `binary: true`, no hunks; a mode-only file `mode_change: true` | Verifier passes; `data_type == Diff`; mapping the payload back yields the input `Vec<FileDiff>` exactly | — |
| Empty diff (Rust) | `&[]` | `ok`, `files` present and empty | — |
| Report rides (Rust) | a `CallReport` with one warning | the envelope carries it | — |
| Real keys (Rust) | `compute_hunks` output from a real repo (a modified file) | the wire's file/hunk `HunkKey`s equal `compute_hunks`' | — |
| Decode happy (Dart) | `EnvelopeObjectBuilder(ok, dataType: Diff, data: DiffObjectBuilder(...))` with the shape above | models equal field by field; `symbol == null` where absent; line kinds mapped; keys equal `HunkKey`s | — |
| Decode empty (Dart) | `files` absent | `Diff.files` empty | — |
| Error envelope (Dart) | `ok: false, error {code, context}` | — | throws `ZanshinFfiException(code, context)` |
| Wrong payload (Dart) | `ok: true, dataType: SelectedTree` | — | throws `ZanshinFfiException('ffi.unknown', …)` |

</intent-contract>

## Code Map

- `crates/zanshin-jj/src/hunks.rs:71-123` -- source types `FileDiff`, `Hunk` (`before_range`/`after_range: Range<u32>`, `symbol: Option<String>`, `sections`, `removed`, `added`, `lines`), `HunkLine { Context, Removed, Added }(String)`; re-exported from `zanshin_jj`. READ-ONLY.
- `crates/zanshin-jj/src/select_tree.rs:90-100` -- `HunkKey { old_start, old_count, new_start, new_count }` (all `u32`, pub). READ-ONLY.
- `schemas/envelope.fbs:289-294` -- existing `table HunkKey` (Story 9.50) to reuse; `:3073-3136` `union Payload` — append `Diff` after `GitColocationResult`; put the new tables right before the union (after `GitColocationResult`, l.3067-3071). Doc style: `///` per table, field meanings in the table doc.
- `crates/zanshin-ffi/src/envelope.rs:938-957` `ok_selected_tree` -- builder pattern (vectors before the table, `finish_envelope(b, fbs::Payload::X, Some(t.as_union_value()), report)`); `:1345` `finish_envelope`; `:536` `CallReport` (pub, `Default`); test helper pattern `verified_envelope` (`:1609`, `flatbuffers::root_with_opts`).
- `crates/zanshin-ffi/src/commit_views.rs:200-231` `show_view_to_envelope` -- nested-vector builder pattern (children before parents).
- `crates/zanshin-ffi/src/lib.rs` -- noun module list; add `pub mod diff;` (alphabetical, after `diagnostics`); `fbs` alias = `envelope_generated::zanshin::ffi`.
- `crates/zanshin-ffi/tests/it/main.rs` + `tests/it/select_tree_ffi.rs:70-110` (`base()`) -- the crate's single integration binary (one module per file, declared in `main.rs`); `base()` is the fixture model: `test_helpers::pin_test_env()`, `zanshin_jj::Repo::init` (Git, non-colocated) in a `tempfile::TempDir`, write `f.txt` `a..e`, describe + `new_change`, rewrite to `A b C d E`, `repo.show(None, None)` for `parent_tree_ids`/`parent_tree_labels`/`tree_ids`/`tree_labels`. The new `tests/it/diff_ffi.rs` copies that setup (helpers are module-private), calls `repo.compute_hunks(&HunksOptions { from: SelectedTreeId { tree_ids, labels }, to: …, context: None, whitespace: Whitespace::Exact })` and feeds the result to `diff_to_envelope`. jj runs only in that temp dir.
- `packages/zanshin_core/lib/src/ffi/select_tree.dart:30-58,254-276` -- `HunkKey` model (reuse) and the decoder pattern; `precondition.dart` `decodeEnvelopeErrorInternal`; `warning.dart` `decodeEnvelopeWarningsInternal`.
- `packages/zanshin_core/test/ffi/` -- decode-contract test pattern (`fbs.EnvelopeObjectBuilder(...).toBytes()`), e.g. `commit_test.dart`, `graph_test.dart`.
- `Makefile.toml` -- `cargo make codegen` regenerates `crates/zanshin-ffi/src/envelope_generated.rs` and `packages/zanshin_core/lib/src/ffi/envelope_zanshin.ffi_generated.dart`.
- `docs/ffi-abi.md` -- append a "`Diff` payload (Story 5.5)" section at the end (shapes, key contract = `SelectTreeRequest`'s `HunkKey`, `symbol` absence, vectors always present, "no extern yet — Story 5.8").
- `_bmad-output/planning-artifacts/epics.md:4684-4686` -- Story 5.5 blockquote; append a dated "Delivered 2026-10-30" reconciliation note.
- `_bmad-output/implementation-artifacts/sprint-status.yaml:117` -- `5-5-json-output-diff-schema-json`; `:91` `last_updated`.

## Tasks & Acceptance

**Execution:**
- `schemas/envelope.fbs` -- add `enum HunkLineKind`, `table HunkLine`, `table Hunk`, `table FileDiff`, `table Diff` (doc-commented, Story 5.5) before the union; append `Diff` to `Payload` -- the wire contract.
- run `cargo make codegen` -- regenerate both accessor sides; commit what it emits.
- `crates/zanshin-ffi/src/diff.rs` (new) + `crates/zanshin-ffi/src/lib.rs` -- SPDX + module doc; `pub fn diff_to_envelope(files: &[zanshin_jj::FileDiff], report: &CallReport) -> Vec<u8>` with private helpers for keys/hunks/lines; inline tests for the Rust matrix rows (round trip back into `Vec<FileDiff>`, empty, report).
- `crates/zanshin-ffi/tests/it/diff_ffi.rs` (new) + `tests/it/main.rs` -- the real-keys row: `compute_hunks` on the temp repo, then assert the payload's file/hunk keys, flags and line texts equal its output -- I1/I2's "keys exactly as `compute_hunks` emits them".
- `packages/zanshin_core/lib/src/ffi/diff.dart` (new) -- models `Diff`, `FileDiff`, `Hunk`, `HunkLine`, `HunkLineKind`; `@visibleForTesting decodeDiffEnvelope` + `decodeDiffEnvelopeInternal`.
- `packages/zanshin_core/test/ffi/diff_test.dart` (new) -- the Dart matrix rows.
- `docs/ffi-abi.md`, `epics.md` Story 5.5 note, `sprint-status.yaml` (5-5 → done at finalize, `last_updated`) -- docs and ledgers.

**Acceptance Criteria:**
- Given the appended schema, when `cargo make codegen` runs, then `fbs::Payload::Diff` (Rust) and `fbs.PayloadTypeId.Diff` / `fbs.DiffObjectBuilder` (Dart) exist and every existing Rust/Dart test that reads envelopes still passes.
- Given `compute_hunks`' output for any repo, when `diff_to_envelope` serialises it and the buffer is read back through the generated accessors, then every file's and every hunk's `sections` equal `compute_hunks`' keys and `mode_change` / `binary` equal its flags (I1/I2's schema part).
- Given a Rust-built `Diff` buffer shape, when `decodeDiffEnvelope` decodes it in Dart, then the models equal the builder input.

## Spec Change Log

## Review Triage Log

### 2026-10-30 — Review pass
- verdicts: 23 findings — high 0, medium 3, low 14, false 6, maybe-false 0
- findings:
  - `[low]` `patch` (blind) An out-of-range `HunkLineKind` byte escapes the Dart decoder as the generated `StateError`. — Real for a skewed buffer; the codebase's rule (Story 4.2's `GraphEdgeKind`, 3.4c's `RepoKind`) documents this by design rather than adding a guard. Doc sentence added on `decodeDiffEnvelope`.
  - `[low]` `reject` (blind) An absent `path` / `text` decodes as `''` instead of failing. — Only a corrupt buffer reaches it (the builder always writes both, `diff.rs` `file_offset`/`line_offset`); the fix is a new guard branch per field for a case no producer can create. Same `?? ''` pattern as the sibling decoders.
  - `[low]` `patch` (blind) `Hunk.sections`' `-w` / `-b` caveat (a partly shown section, or none) is lost on the wire docs. — Added to the `table Hunk` doc (codegen rerun), Dart `Hunk.sections` and the ffi-abi "Keys" bullet.
  - `[low]` `patch` (blind) "empty sections → only whole" is wrong for a `mode_change` file, which can also be selected by its mode. — Docs now say "whole, or by its mode when `mode_change`" (fbs `FileDiff`, Dart `FileDiff.sections`, ffi-abi).
  - `[medium]` `patch` (blind) The real-repo test compares only line texts, never `kind` or the four range scalars. — `diff_ffi.rs` now compares `(kind, text)` per line and `before_start/end`, `after_start/end`.
  - `[low]` `reject` (blind) The Dart models have no `==`/`hashCode`. — No consumer compares them yet (10.24/10.26 are UI stories); adding equality adds public surface the spec does not ask for; the tests assert field by field.
  - `[low]` `reject` (blind) The wire↔`HunkKey` mapping exists in several places. — Two of the copies are test helpers and one is the read side of a different table; a shared helper is a refactor with no named divergence today.
  - `[low]` `patch` (blind) sprint-status' 5-8 entry does not say what 5.5 hands it. — Trailing comment added to `5-8-ffi-wrapper-zanshin-ffi-src-diff-rs` (builder + decoder ready; extern, worker command, `RepoHandle` method, export, `ShowEntry` labels left).
  - `[false]` `reject` (blind) deferred-work.md is not in the diff. — This story defers nothing (`deferred: []`); the I1/I2 outcomes are recorded under `## Auto Run Result`, and the ledger lines are the loop's closing run's.
  - `[false]` `reject` (blind) The spec and generated files are missing from the diff. — Excluded from the review diff on purpose (the spec is the claims file; the generated files come from `cargo make codegen`, rerun in step-03 with no hand edit).
  - `[low]` `reject` (blind) Story 5.5 keeps its JSON-era heading, user story and sprint key. — The 2026-06-20 blockquote and the new "Delivered" note sit directly under the heading; sprint keys are hand-curated and referenced elsewhere, so renaming them buys nothing.
  - `[low]` `patch` (edge) Unknown `HunkLineKind` → `StateError`. — Same root cause as the first blind row; same doc patch.
  - `[low]` `reject` (edge) Absent `FileDiff.path` becomes `''`. — Same as the blind `?? ''` row.
  - `[low]` `reject` (edge) A diff over 2 GiB panics the `FlatBufferBuilder`. — Every payload builder in the crate shares this limit (e.g. `FileContents`); a 2 GiB line diff is not met in use, and the guard would be new error surface.
  - `[medium]` `patch` (edge) The real-repo test never checks kinds or ranges. — Same as the blind test row; same patch.
  - `[low]` `reject` (intent a) No test feeds wire keys into `select_tree`. — The wire keys are proven equal to `compute_hunks`' (`diff_ffi.rs`), which Story 5.1's test feeds through `select_tree`; the wire round trip end to end needs 5.8's extern.
  - `[low]` `patch` (intent b) No `mode_change` / `binary` file comes from `compute_hunks` in the real-repo test. — Fixture gains a mode-only file and a binary file; the test asserts both flags arrive with no hunks. (A conflicted file adds nothing at this layer: the builder copies keys verbatim, and 5.1 tests the conflicted cut.)
  - `[medium]` `patch` (intent c) Line kinds unchecked in the integration test. — Same as the blind test row.
  - `[low]` `reject` (intent d) No test decodes Rust-produced bytes in Dart. — That needs the cdylib extern (Story 5.8, which brings a `zanshin_core` real-cdylib test); both sides are generated from the one `.fbs` (Story 4.2 precedent).
  - `[false]` `reject` (intent e) Absent values default silently. — Documented choice ("vectors always present"); covered by the `?? ''` rejection above.
  - `[false]` `reject` (intent f) No Auto Run Result / recorded verification yet. — Written at finalize, as in every run.
  - `[false]` `reject` (intent g) epic-5-context.md rewrite is scope spillover. — Step-01 recompiles the epic context whenever a planning artifact is newer (epics.md was); that is the workflow, not this story's choice.
  - `[false]` `reject` (intent h) `language`, segments, `syntax_class` and size/latency ACs unaddressed. — Superseded or later by the story's own blockquote and decision (g) (Stories 5.2–5.4); the empty-files and round-trip ACs are covered.
  - Verification-gap layer: no gap findings (it confirmed the round trip catches dropped fields, swapped ranges, kind mapping and absent vectors).

## Design Notes

Why `zanshin-ffi/src/diff.rs`, not `zanshin-diff/src/output.rs`: the generated accessors live only in `zanshin-ffi`, and `zanshin-diff` stays a skeleton (5.1). Story 5.8 adds `zanshin_diff_*` externs to the same file (one file per noun). Four scalar range fields instead of a nested range struct keep the wire free of presence questions (a scalar has a default; an absent struct would need a corruption rule); the Dart model regroups them into records.

## Verification

**Commands:**
- `cargo make codegen` -- expected: succeeds; generated files updated
- `cargo test -p zanshin-ffi --lib diff` and `cargo test -p zanshin-ffi --test it diff_ffi::` -- expected: pass
- No full gate (`cargo make test`/`test-full`/`coverage`): the story loop's gate rule runs it once at the loop's end.
- `cargo test -p zanshin-ffi --lib` -- expected: pass (envelope fixtures unchanged)
- `cargo clippy -p zanshin-ffi --all-targets -- -D warnings` -- expected: clean
- `cargo fmt --all --check` -- expected: clean
- `flutter test test/ffi/diff_test.dart` (in `packages/zanshin_core`), then the package's `flutter test`, `dart analyze`, `dart format --set-exit-if-changed .` -- expected: pass/clean

**Verification notes (run on 2026-10-30; full gate deferred to the story loop by its gate rule):**
- `cargo make codegen` -- succeeded (run three times: implementation, review patch, doc rewrap); only `envelope_generated.rs` and `envelope_zanshin.ffi_generated.dart` changed; header and `bindings.dart` unchanged.
- `cargo test -p zanshin-ffi --lib` -- 235 passed (incl. the 3 new `diff::tests`), before and after the review patches.
- `cargo test -p zanshin-ffi --test it diff_ffi::` -- 1 passed, before and after the review patches (the patched test also checks kinds, ranges, a mode-only and a binary file).
- `cargo clippy -p zanshin-ffi --all-targets -- -D warnings` -- clean. `cargo fmt --all --check` -- clean.
- `cargo make --allow-private test-core` (the `packages/zanshin_core` suite in its pinned environment) -- 1163 passed, after the first implementation pass; the review patches changed only Dart doc comments and generated doc comments afterwards.
- `flutter test packages/zanshin_core/test/ffi/diff_test.dart` -- 4 passed, after the review patches. A plain `flutter test packages/zanshin_core/test/ffi/` outside `cargo make` fails 10 real-cdylib tests with "No available native assets" — the environment, not this change (green under `test-core`).
- `dart analyze --fatal-infos --fatal-warnings packages/zanshin_core` -- no issues. `dart format --set-exit-if-changed packages/zanshin_core` -- 0 changed.
- Not run: the parity oracle (no jj verb changed), `zanshin-jj` tests (untouched), coverage (story-loop gate).

## Auto Run Result

Status: done. Code commit `f8c2be7cb614f5c0e2e9c1874e81e0af43869468`.

**Summary.** The line-level diff now has its wire shape. `schemas/envelope.fbs` gains `enum HunkLineKind`, `table HunkLine`, `table Hunk`, `table FileDiff` and `table Diff`, which mirror `zanshin_jj::FileDiff` / `Hunk` / `HunkLine` field for field and reuse Story 9.50's `HunkKey` for the file and hunk `sections`. `Diff` is appended as the last `Payload` member. The Rust builder is `zanshin_ffi::diff::diff_to_envelope(&[FileDiff], &CallReport)`. The Dart models and decoder are in `packages/zanshin_core/lib/src/ffi/diff.dart`. Following the Story 4.2 pattern, Story 5.8 adds the extern, worker command, `RepoHandle` method and export. epics.md's JSON / `diff.v1.schema.json` premise is superseded by its own FlatBuffers blockquote. Segments, `language` and `syntax_class` wait for Stories 5.2–5.4, and file kinds / `from_path` / counts / summary / pinning for 5.6.

**Files changed.**
- `schemas/envelope.fbs` -- the five new types and the `Diff` union member.
- `crates/zanshin-ffi/src/envelope_generated.rs`, `packages/zanshin_core/lib/src/ffi/envelope_zanshin.ffi_generated.dart` -- regenerated by `cargo make codegen`.
- `crates/zanshin-ffi/src/diff.rs` (new) -- the builder and 3 inline tests (round trip, empty, report).
- `crates/zanshin-ffi/src/lib.rs` -- `pub mod diff;`.
- `crates/zanshin-ffi/tests/it/diff_ffi.rs` (new) + `tests/it/main.rs` -- `compute_hunks` on a temp repo through the wire: keys, flags, symbols, counts, ranges, line kinds and texts; a mode-only and a binary file.
- `packages/zanshin_core/lib/src/ffi/diff.dart` (new) -- `Diff`, `FileDiff`, `Hunk`, `HunkLine`, `HunkLineKind`, `decodeDiffEnvelope(Internal)`.
- `packages/zanshin_core/test/ffi/diff_test.dart` (new) -- the four Dart matrix rows.
- `docs/ffi-abi.md` -- "`Diff` payload (Story 5.5)" section.
- `_bmad-output/planning-artifacts/epics.md` -- Story 5.5 "Delivered 2026-10-30" note.
- `_bmad-output/implementation-artifacts/sprint-status.yaml` -- 5-5 done; 5-8 notes what 5.5 hands it.
- `_bmad-output/implementation-artifacts/epic-5-context.md` -- recompiled in step-01 (epics.md was newer).

**Review.** 23 findings: 0 high, 3 medium, 14 low, 6 false. The patched entries:
- 1 medium: the real-repo test now checks kinds and ranges (three layers reported it).
- 5 low: the `-w` / `-b` caveat on the wire docs; mode-only selection in the "empty sections" docs; the `StateError` doc note (two layers); the 5-8 sprint-status note; the mode-only and binary files in the real-repo test.

Nothing was deferred. Rejected, with reasons in the Review Triage Log:
- the `?? ''` defaulting of a corrupt buffer (two layers);
- Dart value equality;
- a shared `HunkKey` mapper;
- JSON-era names;
- the 2 GiB builder limit;
- a wire → `select_tree` test before 5.8;
- Rust bytes decoded in Dart before 5.8.

Rejected as false: the deferred-work.md and spec/generated-diff claims, and the intent auditor's notes on absent defaults, the Auto Run Result, the epic-context rewrite and the superseded ACs.

**Deferred items handed to this story:**
- **I1** (no read yields sections/`HunkKey`s): partly done, in `f8c2be7cb614f5c0e2e9c1874e81e0af43869468`. Done: the `Diff` payload carries every file's and every hunk's `HunkKey`s exactly as `compute_hunks` emits them, as the `HunkKey` table `SelectTreeRequest` takes. `tests/it/diff_ffi.rs` proves wire keys == `compute_hunks` keys on a real repo, and Story 5.1's test proves those keys round-trip through `select_tree`. Left: the FFI read (`zanshin_diff_*`, worker command, `RepoHandle` method), which is Story 5.8, already planned. Not mirrored again.
- **I2** (no read yields `select_tree`'s inputs from trees): partly done, in `f8c2be7cb614f5c0e2e9c1874e81e0af43869468`. Done: the payload carries each file's `sections` (cut over the materialized conflict text by `compute_hunks`) and the `mode_change` toggle flag, both tested from real `compute_hunks` output; the hunk lines carry the materialized text. Left: the same FFI read, plus `ShowEntry.parent_tree_labels` / `tree_labels` on the FFI `ShowView`. Both are Story 5.8's (deferred-work "Surfaced in Story 5.1"); not mirrored again.

**Follow-up review recommended: false.** This first pass patched 0 high entries and 1 medium entry (plus 5 low), below the threshold.

**Verification.** See the verification notes above; every targeted command passed.

**Residual risks.**
- Per-file coverage of the new `crates/zanshin-ffi/src/diff.rs` is measured only by the story loop's final gate. Its inline tests reach every arm.
- Rust-written bytes are first decoded in Dart once 5.8's extern and its real-cdylib test land. Until then both sides rest on the one `.fbs` and its generated code.
