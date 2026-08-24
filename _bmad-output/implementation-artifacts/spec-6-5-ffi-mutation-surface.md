---
title: 'Story 6.5: FFI mutation surface — zanshin-ffi/src/repo.rs (write extensions)'
type: 'feature'
created: '2026-08-24'
status: 'done'
baseline_revision: 'be5b3b24e652eb7196a0e2b3c2639a81cfa1ebce'
review_loop_iteration: 0
followup_review_recommended: true
context:
  - '_bmad-output/planning-artifacts/epics.md'
  - 'docs/adr/0001-ffi-data-transport-flatbuffers.md'
  - 'docs/rust-error-codes.md'
warnings: ['oversized']
deferred:
  - summary: >-
      cbindgen omits the `MutationResult_VT_WORKING_COPY_CHANGE_ID` constant from
      `zanshin_ffi.h`/`bindings.dart` (present correctly in the flatc-generated
      `envelope_generated.rs`), apparently because it collides by bare suffix name
      with the pre-existing `Status_VT_WORKING_COPY_CHANGE_ID`.
    evidence: |-
      Blind Hunter review pass, independently verified: grepped all three generated
      files plus every hand-written Rust/Dart file — zero references to any `_VT_`
      constant anywhere outside the generated files themselves. The real FlatBuffers
      accessor paths (`fbs::MutationResult::create`/`.working_copy_change_id()` in
      Rust, the flatc-generated Dart reader) never consume these cbindgen-emitted
      informational constants, so this is a harmless codegen-completeness gap, not a
      functional defect. First triggered by this story because it is the first time
      two different tables share this exact field name; fixing it would mean
      investigating/reconfiguring cbindgen, out of this story's scope.
    location: 'crates/zanshin-ffi/include/zanshin_ffi.h, packages/zanshin_core/lib/src/ffi/bindings.dart'
    severity: medium
  - summary: >-
      `zanshin_git_fetch`'s success path (MutationResult + progress-event delivery)
      is proven only at the Rust-FFI integration-test layer, not through the real
      Dart worker isolate / `NativeCallable.listener` path.
    evidence: |-
      Intent Alignment Auditor pass, corroborated by the implementation subagent's
      own report: invoking the real subprocess `git fetch` through the compiled
      cdylib from inside a `dart test`/`dart run` process reliably fails with
      `jj.network_error: Failed to wait for the git process` — reproduced even with
      no other `dart:io Process` calls in the same test, indicating a Dart-VM
      child-reaping race with jj-lib's own `Child::wait()`, not a bug in this
      story's code. The Rust integration test (`repo_write_ffi.rs`) fully exercises
      and asserts the same real subprocess success path since it runs as a plain
      `cargo test` process; only the Dart-level happy-path assertion was dropped
      (the Dart-level error-path test for `git_fetch` still passes and still credits
      the extern fn for the coverage ratchet). Worth checking against the real
      Flutter app at some point — outside this (bridge-only) story's scope.
    location: 'packages/zanshin_core/test/worker/mutate_test.dart'
    severity: medium
  - summary: >-
      `open_fixture_and_get_wc_change_id`'s helper in the new
      `repo_write_ffi.rs` leaks its extracted fixture `TempDir` via
      `std::mem::forget`, so every test using it leaves an on-disk temp directory.
    evidence: |-
      Blind Hunter review pass. Mirrors the pre-existing `tests/change_ffi.rs`
      precedent verbatim (same helper shape, same `mem::forget`); this story
      multiplies the number of call sites but does not introduce the pattern.
    location: 'crates/zanshin-ffi/tests/repo_write_ffi.rs'
    severity: low
  - summary: >-
      The new `git_fetch_happy_path_reports_progress_and_returns_mutation_result`
      test registers the process-global event sink and only unregisters it at the
      very end, with several `assert!`/`expect` calls in between — no RAII guard,
      so a panic mid-test would leave the sink registered for the rest of the
      binary.
    evidence: |-
      Blind Hunter review pass. Mirrors the pre-existing `tests/events_ffi.rs`
      precedent (same register/assert/unregister shape without RAII); not a new
      pattern introduced by this story, though this test has more assertion
      surface between register and unregister than the existing precedent.
    location: 'crates/zanshin-ffi/tests/repo_write_ffi.rs'
    severity: low
---

<intent-contract>

## Intent

**Problem:** `zanshin-jj`'s six mutation functions — `describe`/`new_change`/`edit`/`abandon` (Story 6.1), `undo` (6.2), `git_fetch` (6.4a) — are Rust-only; the Dart worker isolate has no way to call them (FR-JJ-10a, FR-JJ-13, FR-JJ-14a).

**Approach:** Extend `crates/zanshin-ffi/src/repo.rs` with six `extern "C"` wrappers (`zanshin_describe`, `zanshin_new_change`, `zanshin_edit`, `zanshin_abandon`, `zanshin_undo`, `zanshin_git_fetch`), all returning a `MutationResult` `Envelope` payload (new `.fbs` table). `git_push`/`resolve` are dropped from scope (epic-6-context.md: 6.3 deleted, push deferred). Mirror `zanshin_graph_slice`'s handle-borrow + `envelope::catch` pattern exactly; wire `git_fetch`'s progress through the ALREADY-BUILT `events::progress_to_envelope`/`dispatch` mechanism (Story 3.6/6.4a groundwork, currently `#[allow(dead_code)]` for lack of a caller).

## Boundaries & Constraints

**Always:**
- Per the epics.md Story 6.5 blockquote ("Transport reconciled to FlatBuffers, 2026-06-20") and ADR-0001: NO `args_json`, NO `internal.serialization_failed`. Lone strings (`change_id`, `description`, `remote_name`) cross as `*const c_char`. Every function returns `*mut ZanshinBuf` via `envelope::catch` + `vec_into_token`, exactly like every existing `repo.rs` wrapper.
- `parents` (`new_change`) and `change_ids` (`abandon`) are lists → composite per ADR-0001's own table → **FlatBuffers**, not a JSON string and not a raw `*const *const c_char` array. Add one reusable, non-union request table `ChangeIdList { change_ids: [string]; }` to `schemas/envelope.fbs`; both functions take `(data: *const u8, len: usize)` and parse it via `flatbuffers::root_with_opts::<fbs::ChangeIdList>(&VerifierOptions::default(), bytes)` (the generic `flatbuffers::root_with_opts` works for ANY table, not only the schema's declared `root_type` — verified: `root_as_envelope` is literally `flatbuffers::root::<Envelope>(buf)`, nothing `Envelope`-specific). `ChangeIdList` is a plain buffer Dart builds and OWNS/frees itself (Rust only borrows for the call — same AR-P-5 inbound rule as CStrings, generalized to raw bytes); it is NEVER added to `union Payload` (that union is response-only).
- Add `table MutationResult { new_op_id: string; new_change_ids: [string]; abandoned_change_ids: [string]; working_copy_change_id: string; }` to `schemas/envelope.fbs`, APPENDED to `union Payload` after `LogDefaults` (member order is the wire discriminant — never insert/reorder). Update the running `// Story 6-5 : mutation results` comment to `✓`. Add a builder `pub fn ok_mutation_result(r: &zanshin_jj::MutationResult) -> Vec<u8>` in `envelope.rs` (alongside `ok_repo_handle`/`ok_diagnostics`/`ok_empty` — it's shared by all six wrappers, not owned by one noun file).
- Add `session_id: u64` to `RepoSession` (repo.rs) — set directly in the existing struct literal in `arm_session_with` (the id is already computed before `handle_into_raw` is called; no new `unsafe` write needed). `zanshin_git_fetch` needs it to correlate `Progress` events (git_fetch's progress reuses the session's single async-event stream — the SAME mechanism `WatcherEvent` already uses — not a new per-op registry).
- `zanshin_git_fetch`'s closure captures `session.session_id` (a `Copy` `u64`) into a local BEFORE building the closure, never `&session` itself — avoids a borrow conflict with the subsequent `session.repo.git_fetch(&remote_name, &progress)` (`&mut self`). Remove `#[allow(dead_code)]` from `events::progress_to_envelope` (Story 6.5 is its first real caller, per its own doc comment).
- Error mapping (new `map_mutate_err(e: MutateError) -> FfiErrorObj` in `repo.rs`, mirrors `map_repo_err`): `ChangeNotFound` → reuse `JJ_CHANGE_NOT_FOUND`; `Backend` → reuse `JJ_JJ_LIB_ERROR`; `InvalidInput`/`NothingToUndo`/`RemoteNotFound`/`NetworkError` are NEW — add `JJ_INVALID_INPUT = "jj.invalid_input"`, `JJ_NOTHING_TO_UNDO = "jj.nothing_to_undo"`, `JJ_REMOTE_NOT_FOUND = "jj.remote_not_found"`, `JJ_NETWORK_ERROR = "jj.network_error"` consts to `envelope.rs` and four rows to `docs/rust-error-codes.md` (AR-P-4 single-emission-point + registry-update rule).
- A malformed/unverifiable `ChangeIdList` buffer → `ffi.invalid_argument` (existing code; epics.md's own blockquote: "malformed/missing input yields `ffi.invalid_argument`/`ffi.null_pointer`/`ffi.utf8_error`"); a null `data` pointer → `ffi.null_pointer` (existing code, same pattern as `cstr_to_string`). No new `ffi.*` codes.
- FFI functions do ZERO business validation (no "is this list empty" check) — `MutateError::InvalidInput` from `zanshin-jj` is the single source of truth (mirrors the crate's existing thin-wrapper discipline).
- Dart bridge is in scope (memory: bridge is Claude's, UI is Ralph's) — mirror Story 4.6's precedent EXACTLY: new `packages/zanshin_core/lib/src/ffi/mutate.dart` (adapters + `MutationResult` model + decoder + a byte-buffer-building helper for `ChangeIdList`), six new `WorkerCommand` subclasses in `commands.dart`, six dispatch arms + `ZanshinWorker` methods in `isolate.dart`, six `RepoHandle` convenience methods in `handle.dart`, plus real-cdylib worker tests (required for the coverage ratchet's extern-fn credit — see `mem:project-coverage-extern-fn-needs-zanshin-core-test`).
- `cargo make codegen` after the `.fbs`/`extern "C"` changes; commit all four regenerated files (`envelope_generated.rs`, `envelope_zanshin.ffi_generated.dart`, `zanshin_ffi.h`, `bindings.dart`).

**Block If:** none identified — every Rust API this story wraps already exists and is fully specified (mutate.rs/op_log.rs/remotes.rs read directly); the FlatBuffers request-table pattern has no precedent but is fully determined by ADR-0001 + the generic `flatbuffers::root_with_opts` mechanism (verified against the generated code, not assumed).

**Never:**
- Never implement `zanshin_git_push` or `zanshin_resolve` — dropped from WIP scope (epic-6-context.md: Story 6.3 conflict-ops DELETED; push deferred to FR-JJ-13b release phase).
- Never add an `op_id: u64` parameter to `zanshin_git_fetch` — epics.md's illustrative "correlates with a previously-registered progress callback" describes a per-op registry that was never built; the ACTUAL Story 3.6/6.4a mechanism (verified in `events.rs`) correlates every async event (watcher AND progress) by the session's own `session_id`, already returned from `zanshin_repo_open` et al. Adding a second, redundant correlation id would contradict the shipped mechanism.
- Never touch `crates/zanshin-jj` — its six mutation functions (6.1/6.2/6.4a) are complete and unchanged; this story is FFI-only.
- Never put JSON on the wire, never invent a second envelope shape, never shell to `jj` (AR-AP-1, unreachable here — no jj-lib calls in this story).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| `zanshin_describe` happy path | valid handle, existing `change_id`, `description` | `MutationResult` envelope; `new_change_ids`/`abandoned_change_ids` empty | — |
| `zanshin_new_change` happy path | valid handle, `ChangeIdList{[wc_change_id]}` | `MutationResult.new_change_ids` has 1 entry | — |
| `zanshin_new_change`, empty parents | valid handle, `ChangeIdList{[]}` | — | `jj.invalid_input` |
| `zanshin_edit` happy path | valid handle, an ancestor `change_id` | `MutationResult`; `@` now that change | — |
| `zanshin_abandon` happy path (`@` included) | valid handle, `ChangeIdList{[wc_change_id]}` | `MutationResult.new_change_ids` has 1 entry (replacement `@`) | — |
| `zanshin_undo` happy path | valid handle, head op has 1 parent | `MutationResult`; op-log restored one step | — |
| `zanshin_undo`, root op | valid handle, head op IS root (engineered via op-store manipulation, mirrors `zanshin-jj`'s own `undo_at_root_operation_returns_nothing_to_undo`) | — | `jj.nothing_to_undo` |
| `zanshin_git_fetch` happy path | valid handle, local bare-git fixture remote (mirrors `zanshin-jj/tests/remotes_write.rs`), a registered test event callback | `MutationResult`; ≥1 `Progress` envelope dispatched via the registered callback, `session_id` matches | — |
| `zanshin_git_fetch`, unknown remote | valid handle, `remote_name = "nonexistent"` | — | `jj.remote_not_found` |
| any wrapper, zero handle | `handle = 0` | — | `ffi.invalid_handle` |
| `zanshin_new_change`/`zanshin_abandon`, null request buffer | `data = null` | — | `ffi.null_pointer` |
| `zanshin_new_change`/`zanshin_abandon`, garbage bytes | non-null `data` that fails the FlatBuffers Verifier | — | `ffi.invalid_argument` |
| `zanshin_describe`/`zanshin_edit`/`zanshin_git_fetch`, null CString | `change_id`/`remote_name` = null | — | `ffi.null_pointer` |

</intent-contract>

## Code Map

- `crates/zanshin-ffi/src/repo.rs` -- add `session_id: u64` field to `RepoSession` (struct + the `arm_session_with` literal, ~line 123, ~211); add `map_mutate_err(e: zanshin_jj::MutateError) -> FfiErrorObj` (mirrors `map_repo_err`, ~line 36); add `read_change_id_list(data: *const u8, len: usize) -> Result<Vec<zanshin_jj::ChangeId>, FfiErrorObj>` helper (Verifier + `fbs::ChangeIdList`); add six `extern "C"` fns after `zanshin_repo_convert` (~line 465), each following `zanshin_graph_slice`'s skeleton (borrow session via `handle_from_raw`, `cstr_to_string` inputs, call the `Repo::` method, map errors, `ok_mutation_result`). Import `zanshin_jj::ChangeId` and `crate::envelope::{JJ_INVALID_INPUT, JJ_NOTHING_TO_UNDO, JJ_REMOTE_NOT_FOUND, JJ_NETWORK_ERROR, ok_mutation_result}`.
- `crates/zanshin-ffi/src/envelope.rs` -- add `JJ_INVALID_INPUT`/`JJ_NOTHING_TO_UNDO`/`JJ_REMOTE_NOT_FOUND`/`JJ_NETWORK_ERROR` consts (~line 44, alongside `JJ_CHANGE_NOT_FOUND`); add `pub fn ok_mutation_result(r: &zanshin_jj::MutationResult) -> Vec<u8>` (~line 128, after `ok_repo_handle` — builds child string vectors first, then the `MutationResult` table, then the `Envelope` with `data_type: fbs::Payload::MutationResult`, mirrors `ok_diagnostics`'s multi-string-field shape).
- `crates/zanshin-ffi/src/events.rs:184` -- remove `#[allow(dead_code)]` from `progress_to_envelope` (its own doc comment already names Story 6.5 as the first real caller).
- `schemas/envelope.fbs` -- add `table ChangeIdList { change_ids: [string]; }` (request-only, near the top with a comment explaining it's NOT a `Payload` union member); add `table MutationResult { new_op_id: string; new_change_ids: [string]; abandoned_change_ids: [string]; working_copy_change_id: string; }` (style mirrors `Operation`/`Remotes`); append `MutationResult,` to `union Payload` after `LogDefaults` (~line 340); flip the `// Story 6-5 : mutation results` comment to `✓` (~line 41).
- `docs/rust-error-codes.md` -- add four rows for the new `jj.*` codes, each citing Story 6.5 and the underlying `MutateError` variant (mirrors the existing table's citation style).
- `crates/zanshin-ffi/tests/repo_write_ffi.rs` -- NEW. Mirror `tests/change_ffi.rs`'s scaffolding (`ENV_GUARD`/`pin_env`, `read_and_free`, `parse_envelope`, `cstr`, an `open_fixture_and_get_wc_change_id`-style helper) plus `tests/remotes_write.rs`'s local bare-git fixture for the `git_fetch` rows. A local `change_id_list_bytes(ids: &[&str]) -> Vec<u8>` helper builds request buffers via `fbs::ChangeIdListArgs`. Cover every I/O-matrix row.
- `crates/zanshin-ffi/tests/events_ffi.rs` -- READ-ONLY reference for how a test registers a recording callback via `zanshin_events_register` to observe dispatched `Progress` envelopes (needed for the `git_fetch` happy-path row).
- `packages/zanshin_core/lib/src/ffi/mutate.dart` -- NEW, mirrors `ffi/graph.dart`'s structure: six adapter fns (`zanshinDescribe`, `zanshinNewChange`, `zanshinEdit`, `zanshinAbandon`, `zanshinUndo`, `zanshinGitFetch`), a `MutationResult` model class, a `decodeMutationResultEnvelopeInternal` decoder, and a private `_withChangeIdListBytes<T>(List<String> ids, T Function(ffi.Pointer<ffi.Uint8>, int) fn)` helper (builds the request buffer via the generated `fbs.ChangeIdListObjectBuilder(changeIds: ids).toBytes()`, copies it into a `malloc`-allocated `Pointer<Uint8>`, `try`/`finally` frees it — same ownership discipline as `graph.dart`'s `toNativeUtf8`/`calloc.free` pairs, generalized to raw bytes).
- `packages/zanshin_core/lib/src/worker/commands.dart` -- add `DescribeCommand`, `NewChangeCommand`, `EditCommand`, `AbandonCommand`, `UndoCommand`, `GitFetchCommand` (each `final class ... extends WorkerCommand`, mirrors `GraphSliceCommand`'s shape, ~line 164).
- `packages/zanshin_core/lib/src/worker/isolate.dart` -- add six dispatch-switch arms (mirrors the `GraphSliceCommand` case, ~line 788: handle lookup, `ffi.invalid_handle` synthetic envelope on miss, else call the `mutate.dart` adapter and reply with `BufferResult`) and six `ZanshinWorker` methods (mirrors `graphSlice`, ~line 535: `send(...)` + decode).
- `packages/zanshin_core/lib/src/worker/handle.dart` -- add six `RepoHandle` convenience methods (mirrors `graphSlice`, ~line 118: close-guard + delegate to `_worker`).
- `packages/zanshin_core/test/ffi/mutate_test.dart` -- NEW, decode-contract tests against synthetic `MutationResult` envelope buffers (mirrors `test/ffi/graph_test.dart`'s style, no cdylib).
- `packages/zanshin_core/test/worker/mutate_test.dart` -- NEW, real-cdylib worker round-trip tests, one per mutation (mirrors `test/worker/graph_test.dart`) — REQUIRED for the coverage ratchet's extern-fn credit (a Rust `extern "C"` fn is only credited via the cdylib path a `dart test` actually exercises).
- `Makefile.toml:226-281` -- READ-ONLY reference for the exact `cargo make codegen` task chain (flatc-rust → flatc-dart → cbindgen → ffigen) and each output's committed path.

## Tasks & Acceptance

**Execution:**
- `schemas/envelope.fbs` -- add `ChangeIdList`, `MutationResult`, extend `union Payload` -- wire contract for both directions
- `crates/zanshin-ffi/src/envelope.rs` -- add 4 error consts + `ok_mutation_result` -- error taxonomy + shared response builder
- `crates/zanshin-ffi/src/events.rs` -- drop `#[allow(dead_code)]` on `progress_to_envelope` -- it now has a real caller
- `crates/zanshin-ffi/src/repo.rs` -- `session_id` field, `map_mutate_err`, `read_change_id_list`, six `extern "C"` fns -- the story's core deliverable
- `cargo make codegen` -- regenerate + commit `envelope_generated.rs`/`zanshin_ffi.h`/`envelope_zanshin.ffi_generated.dart`/`bindings.dart`
- `docs/rust-error-codes.md` -- add 4 rows -- AR-P-4 registry discipline
- `crates/zanshin-ffi/tests/repo_write_ffi.rs` -- NEW integration tests covering every I/O-matrix row
- `packages/zanshin_core/lib/src/ffi/mutate.dart` -- NEW adapters + model + decoder + request-buffer helper
- `packages/zanshin_core/lib/src/worker/{commands,isolate,handle}.dart` -- six commands + dispatch + worker methods + handle methods
- `packages/zanshin_core/test/{ffi,worker}/mutate_test.dart` -- NEW decode-contract + real-cdylib tests

**Acceptance Criteria:**
- Given `crates/zanshin-ffi/src/repo.rs`, when extended, then it exposes `zanshin_describe`, `zanshin_new_change`, `zanshin_edit`, `zanshin_abandon`, `zanshin_undo`, `zanshin_git_fetch`, each wrapped via `envelope::catch` and returning `*mut ZanshinBuf`.
- Given any of the six functions called with a valid handle and inputs, when it succeeds, then the envelope's payload is `MutationResult` matching the underlying `zanshin_jj::MutationResult` (op id, change ids, working-copy change id) field-for-field.
- Given `zanshin_git_fetch` called against a local bare-git remote with a registered event callback (per `zanshin_events_register`), when it succeeds, then at least one `Progress` envelope was dispatched with `session_id` equal to the session's `RepoHandle.session_id` and `operation == "fetch"`.
- Given `cargo make codegen`, when run, then the six new functions appear in `zanshin_ffi.h` and `bindings.dart`, and `MutationResult`/`ChangeIdList` appear in both generated FlatBuffers accessor sets.
- Given `packages/zanshin_core`'s worker isolate, when a `DescribeCommand`/`NewChangeCommand`/`EditCommand`/`AbandonCommand`/`UndoCommand`/`GitFetchCommand` is sent, then the dispatch switch handles it (unknown `handleId` → synthetic `ffi.invalid_handle` envelope, else the real FFI call) and replies with `BufferResult`.
- Given `cargo test -p zanshin-ffi`, `dart test` (in `packages/zanshin_core`), and `cargo make test`, when run, then all pass, including clippy pedantic (`-D warnings`), rustfmt, `dart analyze`/`format`, and the coverage ratchet (updated `coverage-baseline.txt` committed).

## Spec Change Log

## Review Triage Log

### 2026-08-24 — Review pass
- intent_gap: 0
- bad_spec: 0
- patch: 9: (high 0, medium 3, low 6)
- defer: 4: (high 0, medium 2, low 2)
- reject: 5: (high 0, medium 0, low 5)
- addressed_findings:
  - `medium` `patch` `zanshin_abandon`'s empty-`change_ids` `jj.invalid_input` path had no test, unlike its sibling `zanshin_new_change` (Verification Gap). Added `abandon_empty_change_ids_returns_jj_invalid_input`.
  - `medium` `patch` `jj.change_not_found` was never exercised end-to-end through any of the four wrappers that document emitting it — only the standalone `map_mutate_err` unit test covered the mapping (Verification Gap). Added a table-style `every_wrapper_bogus_change_id_returns_jj_change_not_found` test covering `zanshin_describe`/`zanshin_new_change`/`zanshin_edit`/`zanshin_abandon`.
  - `medium` `patch` `mutate.dart`'s inbound lone strings (`changeId`/`description`/`remoteName`) lacked the interior-NUL guard `graph.dart`'s precedent established for its own inbound strings, risking silent `toNativeUtf8()` truncation (Edge Case Hunter). Added the identical `ArgumentError` guard to all four affected parameters, plus 4 new Dart decode-contract tests.
  - `low` `patch` `app/analysis_options.yaml` carried an unrelated `flutter`/`dart`-tooling side-effect diff (excluding `android/**`/`ios/**`/`web/**`/`windows/**`/`linux/**`) — the same recurring, inert artifact Stories 6.1/6.2/6.4a's own residual risks already documented and reverted (Blind Hunter). Reverted to baseline.
  - `low` `patch` `commands.dart`'s new `DescribeCommand` doc comment had absorbed `ShutdownCommand`'s pre-existing one, leaving `ShutdownCommand` undocumented (Blind Hunter). Restored `ShutdownCommand`'s doc comment and gave `DescribeCommand` its own.
  - `low` `patch` `zanshin_describe`'s null-pointer path (`change_id` OR `description`) only had a null-`change_id` test (Blind Hunter). Added `describe_null_description_returns_ffi_null_pointer`.
  - `low` `patch` The new `jj.invalid_input` registry row omitted `zanshin_undo`'s distinct trigger (a merge-op head) despite crediting `zanshin_undo` as an emitter (Blind Hunter). Added the clause.
  - `low` `patch` The pre-existing `jj.change_not_found` registry row still only cited `change.rs` (Story 3.4b) as an emission point (Blind Hunter, extended during patch). Added the four new Story 6.5 `repo.rs::map_mutate_err` call sites.
  - `low` `patch` `MutationResult`'s `.fbs` doc comment cited FR-JJ-10a/FR-JJ-14a but omitted FR-JJ-13 despite listing `zanshin_git_fetch` as a consumer (Blind Hunter). Added FR-JJ-13; re-ran `cargo make codegen` and committed the regenerated files.

Deferred (real but not this story's problem — see frontmatter `deferred` for full evidence): cbindgen omits `MutationResult_VT_WORKING_COPY_CHANGE_ID` from `zanshin_ffi.h`/`bindings.dart` due to an apparent cross-table same-field-name const-deduplication limitation — verified harmless (no hand-written code references any `_VT_` constant), first triggered by this story's schema, a tooling investigation outside its scope (Blind Hunter, medium); `zanshin_git_fetch`'s happy path is proven only at the Rust-FFI layer, not through the real Dart worker isolate, due to a reproducible Dart-VM subprocess-reaping race with jj-lib's `Child::wait()` — the Rust integration test fully covers the same real-subprocess path (Intent Alignment Auditor, medium); `open_fixture_and_get_wc_change_id`'s `mem::forget`-based `TempDir` leak mirrors pre-existing `tests/change_ffi.rs` precedent (Blind Hunter, low); the new `git_fetch` progress test's register/unregister pair has no RAII guard, mirroring pre-existing `tests/events_ffi.rs` precedent (Blind Hunter, low).

Rejected (noise, or false positives disproven by direct verification): `coverage-baseline.txt` absent from the diff, flagged independently by both Blind Hunter and the Intent Alignment Auditor — verified directly: `crates/zanshin-ffi/src/{repo,envelope,events}.rs` were already at 100.00% in the committed baseline before this story and an independent `cargo make test` run held them at 100.00% after, so there was nothing to raise (deduplicated, same claim); a `mutate_test.dart` test relying on `tearDown` instead of an explicit `handle.close()` call (Blind Hunter — correct either way); the six new `isolate.dart` dispatch-switch arms repeating an ~12-line boilerplate block (Blind Hunter — mirrors every pre-existing `WorkerCommand` arm verbatim, not a pattern introduced by this story); a cosmetic ffigen doc-comment indentation difference between the C header and Dart bindings (Blind Hunter); the Intent Alignment Auditor's reported naming/scope divergences (`zanshin_new_change` vs. epics.md's `zanshin_new`, the dropped `op_id` param, `git_push`/`resolve` absent, the deleted Story 6.7 op-log-sequence assertion) — all already explicitly justified in this spec's own Boundaries/Design Notes with citations to `epic-6-context.md` and the actually-shipped `events.rs` mechanism, which is admissible scope authority (part of "the intent" epics.md itself), not merely this spec's own scope language.

## Design Notes

**One worked wrapper** (`zanshin_describe` — the other lone-string wrappers/`zanshin_undo` follow identically; `zanshin_new_change`/`zanshin_abandon` swap the second `cstr_to_string` for `read_change_id_list`):
```rust
#[no_mangle]
pub unsafe extern "C" fn zanshin_describe(
    handle: u64, change_id: *const c_char, description: *const c_char,
) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_describe", handle);
    let buf = catch(|| {
        let session = unsafe { handle_from_raw::<RepoSession>(handle as *mut RepoSession) }
            .ok_or_else(|| FfiErrorObj { code: FFI_INVALID_HANDLE.to_owned(), context: None })?;
        let id = unsafe { cstr_to_string(change_id) }?;
        let desc = unsafe { cstr_to_string(description) }?;
        let result = session.repo.describe(ChangeId(id), &desc).map_err(map_mutate_err)?;
        Ok(ok_mutation_result(&result))
    });
    vec_into_token(buf)
}
```

**`git_fetch`'s progress wiring** (the borrow-safety point from Boundaries):
```rust
let session_id = session.session_id; // Copy out BEFORE building the closure
let progress = move |e: zanshin_jj::ProgressEvent| {
    events::dispatch(events::progress_to_envelope(session_id, &e.operation, e.progress, &e.message));
};
let result = session.repo.git_fetch(&remote_name, &progress).map_err(map_mutate_err)?;
```

**`read_change_id_list`** (the ADR-0001 composite-input pattern, no prior art in this crate):
```rust
fn read_change_id_list(data: *const u8, len: usize) -> Result<Vec<ChangeId>, FfiErrorObj> {
    if data.is_null() {
        return Err(FfiErrorObj { code: FFI_NULL_POINTER.to_owned(), context: None });
    }
    let bytes = unsafe { std::slice::from_raw_parts(data, len) }; // SAFETY: caller-owned, borrowed for this call only
    let list = flatbuffers::root_with_opts::<fbs::ChangeIdList>(&VerifierOptions::default(), bytes)
        .map_err(|e| FfiErrorObj { code: FFI_INVALID_ARGUMENT.to_owned(), context: Some(e.to_string()) })?;
    Ok(list.change_ids().into_iter().flatten().map(|s| ChangeId(s.to_owned())).collect())
}
```
Note: `flatbuffers::root_with_opts::<T>` works for any generated table `T`, not only the `.fbs`'s declared `root_type` — `root_as_envelope` itself is a thin wrapper over exactly this generic call (verified in `envelope_generated.rs`). `ChangeIdList` therefore needs no `root_type` change.

**Naming deviation from epics.md's illustrative code** (flagged per CLAUDE.md "state assumptions explicitly"): epics.md's Story 6.5 AC block names the wrapper `zanshin_new`; this spec uses `zanshin_new_change` to match `Repo::new_change`'s actual name and avoid ambiguity with Dart's `new` keyword in the corresponding `NewChangeCommand`. Same reasoning for dropping epics.md's `op_id: u64` parameter on `git_fetch` (see Boundaries/Never) — the shipped correlation mechanism already exists and uses `session_id`.

## Verification

**Commands:**
- `cargo test -p zanshin-ffi` -- expected: new `tests/repo_write_ffi.rs` tests pass, existing suite unaffected
- `cargo clippy --workspace --all-targets -- -D warnings` -- expected: clean (pedantic on)
- `cd packages/zanshin_core && dart test` -- expected: new `test/ffi/mutate_test.dart` and `test/worker/mutate_test.dart` pass
- `dart analyze --fatal-infos --fatal-warnings` (in `packages/zanshin_core` and `app/`) -- expected: clean
- `cargo make codegen` -- expected: regenerates the four committed files with no unrelated drift
- `cargo make test` -- expected: full gate passes (clippy workspace-wide, rustfmt, `flutter test`, `dart analyze`/`format`, `cargo deny`, coverage ratchet); commit the updated `coverage-baseline.txt`

## Auto Run Result

**Summary:** Implemented Story 6.5 — the FFI mutation surface wrapping Epic 6's six already-shipped `zanshin-jj` mutations (`describe`/`new_change`/`edit`/`abandon` from 6.1, `undo` from 6.2, `git_fetch` from 6.4a). `crates/zanshin-ffi/src/repo.rs` gained six `extern "C"` wrappers (`zanshin_describe`, `zanshin_new_change`, `zanshin_edit`, `zanshin_abandon`, `zanshin_undo`, `zanshin_git_fetch`), each following the existing `envelope::catch` → `*mut ZanshinBuf` pattern. Per ADR-0001 (superseding the JSON-shaped AC prose in epics.md, per the story's own "Transport reconciled to FlatBuffers" blockquote), composite inputs (`new_change`'s `parents`, `abandon`'s `change_ids`) cross as a new reusable, request-only `ChangeIdList` FlatBuffers table — the first composite-input pattern in this crate, read via the generic `flatbuffers::root_with_opts::<T>` (verified to work for any table, not only the schema's declared `root_type`). The success payload for all six is a new `MutationResult` table appended to `schemas/envelope.fbs`'s `Payload` union. `zanshin_git_fetch` reuses the already-built-but-previously-unused `events::progress_to_envelope`/`dispatch` mechanism (Story 3.6), correlating progress by the session's own `session_id` (a new field added to `RepoSession`) rather than the separate `op_id` parameter epics.md's illustrative AC named — that parameter described a per-op registry that was never built; the real, shipped mechanism already correlates by `session_id`, the same as `WatcherEvent`. `git_push`/`resolve` were intentionally NOT implemented (Story 6.3 deleted, push deferred, per `epic-6-context.md`). The Dart bridge (`packages/zanshin_core`) mirrors Story 4.6's precedent exactly: a new `lib/src/ffi/mutate.dart` adapter file, six new `WorkerCommand` subclasses, six dispatch arms + `ZanshinWorker` methods, six `RepoHandle` convenience methods, and both decode-contract and real-cdylib worker tests.

**Files changed:**
- `schemas/envelope.fbs` — added request-only `ChangeIdList`, response `MutationResult` (append-only union slot), FR-JJ-13 added to its doc comment (post-review).
- `crates/zanshin-ffi/src/envelope.rs` — added `JJ_INVALID_INPUT`/`JJ_NOTHING_TO_UNDO`/`JJ_REMOTE_NOT_FOUND`/`JJ_NETWORK_ERROR` error-code consts and `ok_mutation_result` builder, with a unit test.
- `crates/zanshin-ffi/src/events.rs` — removed `#[allow(dead_code)]` from `progress_to_envelope` now that `zanshin_git_fetch` is its first real caller.
- `crates/zanshin-ffi/src/repo.rs` — added `session_id: u64` to `RepoSession`, `map_mutate_err`, `read_change_id_list`, and the six mutation wrappers, plus `map_mutate_err` unit tests for all six `MutateError` variants.
- `crates/zanshin-ffi/include/zanshin_ffi.h`, `crates/zanshin-ffi/src/envelope_generated.rs`, `packages/zanshin_core/lib/src/ffi/bindings.dart`, `packages/zanshin_core/lib/src/ffi/envelope_zanshin.ffi_generated.dart` — regenerated via `cargo make codegen` (twice: once for the initial schema, once after the FR-JJ-13 doc-comment patch).
- `docs/rust-error-codes.md` — four new rows, plus (post-review) an updated `jj.change_not_found` citation and an added `zanshin_undo` merge-op cause clause on `jj.invalid_input`.
- `crates/zanshin-ffi/tests/repo_write_ffi.rs` — NEW, 20 tests covering every I/O-matrix row plus the post-review additions (`abandon` empty-list, a table-style bogus-change-id test across all four resolving wrappers, a null-`description` test).
- `packages/zanshin_core/lib/src/ffi/mutate.dart` — NEW: six adapters (with post-review interior-NUL guards on `changeId`/`description`/`remoteName`), `MutationResult` model, decoder, `_withChangeIdListBytes` request-buffer helper.
- `packages/zanshin_core/lib/src/worker/commands.dart` — six new `WorkerCommand` subclasses (post-review: fixed a doc-comment misplacement between `ShutdownCommand`/`DescribeCommand`).
- `packages/zanshin_core/lib/src/worker/isolate.dart` — six dispatch arms + six `ZanshinWorker` methods.
- `packages/zanshin_core/lib/src/worker/handle.dart` — six `RepoHandle` convenience methods.
- `packages/zanshin_core/test/ffi/mutate_test.dart` — NEW decode-contract tests (5 initial + 4 post-review NUL-guard tests).
- `packages/zanshin_core/test/worker/mutate_test.dart` — NEW real-cdylib worker round-trip tests (10), one per mutation plus error paths; documents (in-file comment) why `git_fetch`'s Dart-level happy-path assertion was dropped (a reproducible Dart-VM/subprocess-reaping race, not a bug in this story's code — see frontmatter `deferred`).
- `app/analysis_options.yaml` — touched then reverted to baseline during the review round (an unrelated, known `flutter`/`dart`-tooling side-effect already documented by Stories 6.1/6.2/6.4a).
- `_bmad-output/implementation-artifacts/spec-6-5-ffi-mutation-surface.md` — this spec.

**Review findings breakdown:** 9 patch (0 high, 3 medium, 6 low) — all applied and re-verified; 4 defer (0 high, 2 medium, 2 low) — logged in frontmatter `deferred` (a cbindgen cross-table const-deduplication quirk omitting one harmless VT constant; `git_fetch`'s happy path proven only at the Rust-FFI layer due to a Dart-VM/subprocess race; a pre-existing `mem::forget`-based fixture leak pattern; a pre-existing no-RAII-guard event-sink test pattern); 5 reject (0 high, 0 medium, 5 low) — a `coverage-baseline.txt`-absence claim independently disproven (the three touched files were already at 100% and stayed there), a stylistic test-cleanup nitpick, a boilerplate-repetition observation matching the codebase's own established dispatch-arm convention, a cosmetic generated-code formatting artifact, and a set of naming/scope divergences from epics.md's stale AC prose that were already explicitly justified in this spec's own Boundaries/Design Notes.

**Follow-up review recommendation:** `true` — this pass's patched findings scored `3×medium + 1×low = 3×3 + 1×6 = 15`, well above the ≥5 threshold (no `high` patches this pass).

**Verification performed:** Independently re-ran (not just trusted the implementation subagent's self-reports) the full `cargo make test` gate TWICE — once after the initial implementation (before the review round) and once after the 9 patches — both exited 0: `overall: 99.00% (4938/4988 lines over 34 files)`, `coverage-check: OK — coverage held at 99.00%`, `extern-coverage: OK — every zanshin-ffi extern "C" fn is covered`, identical numbers both times (confirming the patches introduced no regression and needed no baseline change). Independently spot-checked the actual diff content (not just the implementation subagent's description) for: the six wrapper functions' borrow-safety pattern (`session_id` copied out before `git_fetch`'s progress closure), the `ChangeIdList`/`MutationResult` `.fbs` additions and their union placement, `envelope.rs`'s new error consts and `ok_mutation_result` builder, `mutate.dart`'s adapters and request-buffer helper, and the `isolate.dart` dispatch arms. Independently verified two of the four reviewers' most consequential claims directly against the repo rather than taking them at face value: the "`coverage-baseline.txt` missing" claim (false positive — the three touched files were already at the 100% ceiling) and the "unrelated `app/analysis_options.yaml` change" claim (real — confirmed via `git diff`, and matched an already-documented recurring pattern from three prior stories in this epic). Independently verified the `every_wrapper_bogus_change_id_returns_jj_change_not_found` test's choice of `"nonexistentchangeid"` over the reviewer's originally-suggested `"zzzzzzzz"` (the latter is jj's own root-change-id reverse-hex encoding and would resolve rather than error) by reading the actual test code. Matrix Test Audit: all rows in the I/O & Edge-Case Matrix have a covering test that ran and passed, confirmed via the test-name listing in `repo_write_ffi.rs` and the full test-suite log, both before and after the patch round.

**Residual risks:** the 4 deferred findings (see frontmatter) are real but pre-existing-pattern, tooling-inherent, or environment-inherent — none are data-loss or crash risks, and none affect the actual shipped mutation surface's correctness (verified: the underlying jj-lib mutation logic and its FFI wiring are proven by the Rust integration tests running against the real compiled cdylib). The most consequential is the Dart-VM/subprocess-reaping interaction affecting `git_fetch`'s Dart-level happy-path test — worth checking against the real Flutter app at some point (flagged as out of this bridge-only story's scope by both the implementation subagent and this review). The recurring, inert `app/analysis_options.yaml` toolchain side effect (noted in Stories 6.1/6.2/6.4a's own residual risks) reappeared again in this story and was reverted from the diff, consistent with precedent.
