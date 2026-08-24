---
title: 'Story 6.6: MutationResult FFI schema — verify already-complete via 3.4b/6.5'
type: 'chore'
created: '2026-08-24'
status: 'done'
baseline_revision: '0f5be4c522e0eadff9123ee29463c75452c141ec'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '_bmad-output/planning-artifacts/epics.md'
  - 'docs/adr/0001-ffi-data-transport-flatbuffers.md'
  - '_bmad-output/project-context.md'
  - '_bmad-output/implementation-artifacts/epic-6-context.md'
warnings: []
deferred:
  - summary: >-
      `docs/ffi-abi.md` (the canonical FFI ABI reference, which documents prior FFI
      surfaces per-story) has no section for `MutationResult` or the six mutation
      wrappers (`zanshin_describe`/`_new_change`/`_edit`/`_abandon`/`_undo`/`_git_fetch`).
    evidence: |-
      Blind Hunter review pass. Verified: the doc has sections for 3.4c
      (repo_detect/convert), 3.6 (async events), 4.2/4.6/4.8 (GraphSlice), and 4.9
      (LogDefaults), but none for Story 6.5's mutation wrappers or 6.6's schema. The
      gap predates this story (Story 6.5's own spec Code Map never listed
      `docs/ffi-abi.md` either, and other wrapper stories like 3.4a/3.4b also lack
      sections there), and Story 6.6's actual scope — the wire schema itself, not the
      ABI narrative doc — does not cover it.
    location: 'docs/ffi-abi.md'
    severity: medium
  - summary: >-
      `schemas/README.md`'s codegen-output-path claim is stale: it says generated Dart
      accessors land in `app/lib/src/ffi/`, but they actually land in
      `packages/zanshin_core/lib/src/ffi/` (confirmed against `Makefile.toml`'s
      `codegen-flatc-dart` task).
    evidence: |-
      Blind Hunter review pass, independently confirmed by reading
      `Makefile.toml:255` (`codegen-flatc-dart` writes to
      `packages/zanshin_core/lib/src/ffi/`). Predates this story — the path went stale
      when the Dart bridge moved to `packages/zanshin_core` (see project memory
      `3-4b template Dart paths are stale`) — and this story's dropped versioning AC
      is the only `schemas/README.md` item in its scope, not general path accuracy.
    location: 'schemas/README.md:13'
    severity: medium
  - summary: >-
      `_bmad-output/planning-artifacts/sprint-status.yaml` is not updated to reflect
      Epic 6's closure now that its last story (6.6) is done.
    evidence: |-
      Blind Hunter review pass. The most recent repo commit
      ("docs(sprint-status): close Epic 4 — Stories 4.8 and 4.9 done") shows this is
      normally a distinct follow-up step, owned by a different skill
      (`bmad-sprint-planning`) — this workflow's own steps (step-01 through step-04)
      never reference `sprint-status.yaml`, so updating it is outside bmad-build-auto's
      process, not this story's code/schema scope.
    location: '_bmad-output/planning-artifacts/sprint-status.yaml'
    severity: low
---

<intent-contract>

## Intent

**Problem:** Story 6.6 (epics.md) asks for `schemas/change.v1.schema.json` to be extended with a `MutationResult` shape so mutation responses are schema-validated. Its own "Transport reconciled to FlatBuffers (2026-06-20)" blockquote recasts this entirely: `Change`/`MutationResult` become FlatBuffers tables in `schemas/*.fbs`, and it explicitly drops every versioning AC (`schema_version`, `.v1`/`.v2` filenames, `_v2` suffixes, minor-bump rules, and the `schemas/README.md` inventory AC, which cites the deleted Story 1.8).

**Approach:** Investigate before writing code, per this run's directive. Story 3.4b already added a `Change` table and Story 6.5 already added a `MutationResult` table, both in the single `schemas/envelope.fbs` file, both independently referenced by FFI functions, both field-for-field verified against their Rust source types, both covered by Rust + Dart tests that decode via generated typed accessors. Every reinterpreted (non-dropped) AC of 6.6 is already satisfied. This spec is the confirmation record; land it with zero source diff.

## Boundaries & Constraints

**Always:** Treat `docs/adr/0001-ffi-data-transport-flatbuffers.md` + `_bmad-output/project-context.md` as authoritative over epics.md's stale JSON-Schema AC prose. Verify field-for-field parity between `envelope.fbs`'s `MutationResult`/`Change` tables and their Rust source types by reading the code directly, not by trusting Story 6.5's spec claims alone. Confirm Rust + Dart tests decode `MutationResult` via generated typed accessors (not raw byte inspection) by citing the actual test file + test name.

**Block If:** none identified — scope is fully determined by epics.md's own blockquote plus `epic-6-context.md`'s Technical Decisions/Cross-Story Dependencies, cross-checked directly against `schemas/envelope.fbs`, `crates/zanshin-jj/src/mutate.rs`, `crates/zanshin-ffi/src/envelope.rs`, and Story 6.5's tests.

**Never:** Never resurrect the dropped versioning ACs (`schema_version`, `.v1`/`.v2` filenames, `_v2` suffixes, the `schemas/README.md` Story-1.8 inventory reference) — the blockquote explicitly drops them. Never create a separate `schemas/change.fbs`/`mutation_result.fbs` file — the "decision" AC (reinterpreted) keeps `Change` and `MutationResult` in the single `envelope.fbs`, the shipped pattern for every payload type to date. Never touch `crates/zanshin-jj`, `crates/zanshin-ffi/src/repo.rs`'s wrapper bodies, or the Dart worker/handle layers — that is Story 6.5's delivered, tested surface; this story is verification-only.

</intent-contract>

## Code Map

- `schemas/envelope.fbs:107-119` -- existing `Change` table (Story 3.4b/Epic 2), doc-commented, field-for-field matches `zanshin_jj`'s change metadata.
- `schemas/envelope.fbs:338-348` -- existing `MutationResult` table (Story 6.5): `new_op_id`, `new_change_ids`, `abandoned_change_ids`, `working_copy_change_id`. Appended to `union Payload` (line 364) after `LogDefaults`, per the WIP no-reorder rule.
- `crates/zanshin-jj/src/mutate.rs:24-47` -- `MutationResult` Rust source struct. Verified field-for-field parity with the `.fbs` table: all four fields present, no gaps.
- `crates/zanshin-ffi/src/envelope.rs:150-178` -- `ok_mutation_result` builder. Verified it populates all four `MutationResult` fields correctly, bottom-up FlatBuffers construction order.
- `packages/zanshin_core/lib/src/ffi/mutate.dart:152-208` -- `MutationResult` Dart model + `decodeMutationResultEnvelopeInternal`. Verified field-for-field parity via generated typed accessors (`fbs.MutationResult`).
- `crates/zanshin-ffi/tests/repo_write_ffi.rs` -- Rust integration tests exercising every mutation wrapper's `MutationResult` payload via generated Rust accessors (Story 6.5).
- `packages/zanshin_core/test/ffi/mutate_test.dart`, `test/worker/mutate_test.dart` -- Dart decode-contract + real-cdylib tests validating `MutationResult` via generated Dart typed accessors (Story 6.5).
- `schemas/README.md` -- registry doc; its versioning-inventory AC is explicitly dropped by epics.md's own blockquote (cites the deleted Story 1.8) -- read-only, no change needed.
- `_bmad-output/planning-artifacts/epics.md:4048-4088` -- Story 6.6's ACs + the "Transport reconciled to FlatBuffers" blockquote that supersedes them.
- `_bmad-output/implementation-artifacts/epic-6-context.md` -- Cross-Story Dependencies: "6.1's `MutationResult` shape is what 6.5 returns over FFI and what 6.6's `.fbs` tables encode."

## Tasks & Acceptance

**Execution:**
- `schemas/envelope.fbs` -- verify, no edit: `Change` (3.4b) and `MutationResult` (6.5) both exist in this single file, field-for-field complete, independently referenced by FFI functions -- confirms Story 6.6's "one file" decision AC is already satisfied
- `crates/zanshin-jj/src/mutate.rs`, `crates/zanshin-ffi/src/envelope.rs`, `packages/zanshin_core/lib/src/ffi/mutate.dart` -- verify, no edit: `MutationResult`'s four fields round-trip correctly Rust struct → `.fbs` table → Dart model -- confirms no schema/source drift
- `crates/zanshin-ffi/tests/repo_write_ffi.rs`, `packages/zanshin_core/test/{ffi,worker}/mutate_test.dart` -- verify, no edit: both already decode `MutationResult` via generated typed accessors -- confirms the reinterpreted "Rust + Dart tests both validate" AC is already satisfied
- `_bmad-output/implementation-artifacts/spec-6-6-mutation-result-schema.md` -- write this spec as the confirmation record -- the story's actual deliverable, since no source diff is needed

**Acceptance Criteria:**
- Given `schemas/envelope.fbs`, when inspected, then it contains both a `Change` table (Story 3.4b) and a `MutationResult` table (Story 6.5) in the single file, each independently referenced by at least one `extern "C"` FFI function.
- Given `zanshin_jj::MutationResult` (`crates/zanshin-jj/src/mutate.rs`) and the `MutationResult` `.fbs` table, when compared field-for-field, then all four fields (`new_op_id`, `new_change_ids`, `abandoned_change_ids`, `working_copy_change_id`) match with no gaps.
- Given `crates/zanshin-ffi/tests/repo_write_ffi.rs` and `packages/zanshin_core/test/{ffi,worker}/mutate_test.dart`, when read, then both Rust and Dart sides decode `MutationResult` via generated typed accessors, not raw byte inspection.
- Given the dropped versioning ACs (`schema_version`, `.v1`/`.v2` filenames, the `schemas/README.md` Story-1.8 reference), when checked against epics.md's own blockquote, then none are implemented and none are required.
- Given `cargo make test`, when run, then it passes with no regressions, confirming this verification-only story introduces no risk and needs no `coverage-baseline.txt` change.

## Spec Change Log

## Review Triage Log

### 2026-08-24 — Review pass
- intent_gap: 0
- bad_spec: 0
- patch: 4: (high 0, medium 0, low 4)
- defer: 3: (high 0, medium 2, low 1)
- reject: 1: (high 0, medium 0, low 1)
- addressed_findings:
  - `low` `patch` Code Map cited `mutate.rs:21-46`/`envelope.rs:141-177`, off by a few lines from the actual symbol locations (Blind Hunter + Verification Gap Reviewer, same claim). Corrected to `mutate.rs:24-47`/`envelope.rs:150-178`, matching the already-accurate Auto Run Result citations.
  - `low` `patch` Frontmatter `context:` omitted `_bmad-output/project-context.md` and `epic-6-context.md` despite both being relied on in Boundaries/Intent (Blind Hunter). Added both.
  - `low` `patch` Frontmatter `status` (`in-review`) disagreed with the body's "status → `done`" note, an artifact of the implementation subagent writing `done` before the review pass ran (Blind Hunter). Resolved: frontmatter is now the single source of truth, updated to `done` only at Finalize below, after this review pass — Auto Run Result rewritten to match.
  - `low` `patch` The "grepped confirmed-absent" versioning-AC claims and the "no schema/source drift" claim cited no reproducible commands (Blind Hunter, partially overlapping the Verification Gap Reviewer's independent re-verification). Ran `cargo make verify-codegen` (clean, zero regenerated-file diff) as additional independent evidence beyond `cargo make test`; Auto Run Result below now cites the exact grep patterns used and the `extern-coverage: OK` sub-gate line verbatim, not just the `overall:` coverage figure.

Deferred (real but not this story's problem — see frontmatter `deferred` for full evidence): `docs/ffi-abi.md` has no section for `MutationResult`/the six mutation wrappers — a pre-existing gap from Story 6.5, outside this story's wire-schema-only scope (Blind Hunter, medium); `schemas/README.md`'s codegen-output-path claim (`app/lib/src/ffi/`) is stale versus the actual `packages/zanshin_core/lib/src/ffi/` path — predates this story, and only the dropped versioning-inventory AC touches `schemas/README.md` within this story's scope (Blind Hunter, medium); `sprint-status.yaml` is not updated to reflect Epic 6's closure — owned by a different skill (`bmad-sprint-planning`), not referenced anywhere in bmad-build-auto's own workflow steps (Blind Hunter, low).

Rejected (noise): the spec's `type: 'chore'` classification was questioned with no clearly better alternative offered among the template's four allowed types (`feature`/`bugfix`/`refactor`/`chore`) for a zero-diff verification record (Blind Hunter, low).

The Intent Alignment Auditor's pass was descriptive-only (no findings to triage): it confirmed this diff implements "Reading B" — honoring epics.md Story 6.6's own superseding "Transport reconciled to FlatBuffers" blockquote over its un-struck original JSON-Schema ACs — which is exactly the reading this run's own invocation explicitly directed (not a spec-derived scope claim). Edge Case Hunter returned zero findings.

## Design Notes

No code changes are made by this story. Its entire remaining (non-dropped) scope — a `MutationResult` FlatBuffers table living alongside `Change` in the single `schemas/envelope.fbs`, independently referenced by FFI functions, field-for-field correct, and validated by typed-accessor tests on both sides of the FFI boundary — was already fully delivered by Story 3.4b (`Change`) and Story 6.5 (`MutationResult`, its builder, its Dart decoder, and its Rust+Dart tests). The epics.md blockquote for this story additionally drops every versioning AC outright, including the one asking for a `schemas/README.md` inventory update (it names the deleted Story 1.8). There is nothing left to build; this spec is the audit trail proving that.

## Verification

**Commands:**
- `cargo make test` -- expected: full gate passes unchanged (no baseline diff, since no source changed).
- `cargo make verify-codegen` -- expected: clean (zero diff between committed generated accessors and a fresh `cargo make codegen` run), confirming `envelope.fbs` and its generated Rust/Dart accessors have not drifted.

## Auto Run Result

**Summary:** Story 6.6 (reinterpreted per epics.md's own "Transport reconciled to FlatBuffers" blockquote, which drops every JSON-Schema/versioning AC) asks for the wire schema to carry a `MutationResult` shape alongside `Change`, in one file, independently referenced by FFI functions, validated by typed-accessor tests on both sides. Investigation found every one of those (non-dropped) requirements already satisfied by prior work: Story 3.4b added `Change` and Story 6.5 added `MutationResult`, both as tables in the single `schemas/envelope.fbs` (`Change` at lines 107-119, `MutationResult` at lines 343-348, appended last in the `Payload` union after `LogDefaults`, per the append-only rule). `Change` is referenced by `crates/zanshin-ffi/src/change.rs`'s `change_to_envelope`; `MutationResult` by six `extern "C"` wrappers in `crates/zanshin-ffi/src/repo.rs` (`zanshin_describe`, `zanshin_new_change`, `zanshin_edit`, `zanshin_abandon`, `zanshin_undo`, `zanshin_git_fetch`) via `envelope::ok_mutation_result`. Field-for-field parity confirmed: `zanshin_jj::MutationResult` (`crates/zanshin-jj/src/mutate.rs:24-47`) has exactly the four fields the `.fbs` table has (`new_op_id`, `new_change_ids`, `abandoned_change_ids`, `working_copy_change_id`); `ok_mutation_result` (`crates/zanshin-ffi/src/envelope.rs:150-178`) populates all four bottom-up; the Dart `MutationResult` model (`packages/zanshin_core/lib/src/ffi/mutate.dart:152-208`) mirrors all four and decodes via generated `fbs.MutationResult` typed accessors, not raw bytes. Typed-accessor decoding confirmed on both test sides: Rust's `crates/zanshin-ffi/tests/repo_write_ffi.rs` decodes via `.data_as_mutation_result()` in 6 tests (e.g. `describe_valid_round_trip_returns_ok_mutation_result`, `git_fetch_happy_path_reports_progress_and_returns_mutation_result`); Dart's `packages/zanshin_core/test/ffi/mutate_test.dart` (decode-contract, synthetic buffers) and `test/worker/mutate_test.dart` (real-cdylib) both go through `decodeMutationResultEnvelope`/`handle.describe|newChange|edit|abandon|undo`. Grepped (`rg -n "schema_version|\.v1\.schema|\.v2\.schema|_v2\b"` across `schemas/`, `crates/`, `packages/zanshin_core/`) confirmed-absent: no `schema_version` in-wire field, no `change.v1`/`.v2` schema files, no `_v2`-suffixed FFI/Dart functions anywhere — the dropped versioning ACs are genuinely not implemented, as the epics.md blockquote requires. Result: zero source diff; this spec is the audit trail.

**Files changed:** none (source). `_bmad-output/implementation-artifacts/spec-6-6-mutation-result-schema.md` — this confirmation record.

**Review findings breakdown:** 4 patch (0 high, 0 medium, 4 low) — all applied and re-verified (Code Map line-number citations corrected; `context:` frontmatter completed; frontmatter/body `status` inconsistency resolved; verification narrative extended with `cargo make verify-codegen` evidence and exact grep patterns); 3 defer (0 high, 2 medium, 1 low) — logged in frontmatter `deferred` (`docs/ffi-abi.md` missing a `MutationResult`/mutation-wrapper section, a pre-existing Story 6.5 gap; `schemas/README.md`'s stale codegen-output-path claim, predating this story; `sprint-status.yaml` not reflecting Epic 6's closure, owned by a different skill); 1 reject (0 high, 0 medium, 1 low) — the `type: 'chore'` classification questioned with no better alternative among the template's four allowed types.

**Follow-up review recommendation:** `false` — this pass's patched findings scored `3×medium + 1×low = 3×0 + 1×4 = 4`, below the ≥5 threshold (no `high` patches).

**Verification performed:** Independently re-ran (not just trusted the implementation subagent's self-reports) `cargo make test` to completion (full gate: `cargo test` workspace + clippy pedantic `-D warnings` + rustfmt + `flutter test` + `dart analyze`/`format` + `cargo deny` + coverage ratchet). Result: clean — `test result: ok. 27 passed; 0 failed; 1 ignored` / `test result: ok. 8 passed; 0 failed`, `overall: 99.00% (4938/4988 lines over 34 files)`, `coverage-check: OK — coverage held at 99.00%`, `extern-coverage: OK — every zanshin-ffi extern "C" fn is covered (allow: zanshin_buffer_free)` — identical to Story 6.5's landed numbers, no regression, `coverage-baseline.txt` has zero diff, no baseline bump needed. Additionally ran `cargo make verify-codegen` (re-runs `flatc`/`cbindgen`/`ffigen` and diffs against the committed generated accessors) to completion with zero drift, directly substantiating the "no schema/source drift" claim beyond manual code reading. `git status --short` after both runs showed only this spec file as untracked — no modified files. During the `cargo make test` run, `app/analysis_options.yaml` picked up the same recurring, inert Flutter/dart-tooling side-effect diff (`android/**`/`ios/**`/`web/**`/`windows/**`/`linux/**` added to the analyzer excludes, none of those directories exist) that Story 6.5's own Review Triage Log already documented; reverted to baseline the same way, restoring a genuinely clean `git status`. Four review layers ran in parallel (Blind Hunter, Edge Case Hunter, Verification Gap Reviewer, Intent Alignment Auditor); all four independently re-verified the spec's core claims against source rather than trusting its prose, and none found a defect in the underlying "no work needed" conclusion — only documentation-polish and pre-existing, out-of-scope gaps (see Review Triage Log).

**Residual risks:** none functional — this story makes no source changes. The 3 deferred findings (see frontmatter `deferred`) are real documentation gaps but pre-existing (not introduced by this story) and outside its wire-schema-only scope: `docs/ffi-abi.md` lacking a mutation-surface section (worth a future doc pass alongside or after Epic 9's operation-surface build-out), `schemas/README.md`'s stale Dart-output-path claim (a one-line fix whenever someone next touches that file), and `sprint-status.yaml` not yet reflecting Epic 6's closure (a `bmad-sprint-planning` follow-up, now that 6.6 — the epic's last story — is done).
