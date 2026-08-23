---
title: 'Story 4.6: FFI wrapper (`zanshin-ffi/src/graph.rs`) — `zanshin_graph_slice` extern fn + Dart worker command over `collect_lanes`'
type: 'feature'
created: '2026-08-23'
status: 'done'
baseline_revision: 'f80d3d176ca3e5925e239c2df210966f533893fe'
review_loop_iteration: 0
followup_review_recommended: true
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-4-context.md'
warnings: ['oversized']
deferred: []
---

<intent-contract>

## Intent

**Problem:** The lane-assigned commit graph is computed (4.1/4.3/4.4: `zanshin_graph::collect_lanes`) and its wire form exists on both sides (4.2: `zanshin_ffi::graph::graph_slice_to_envelope` + Dart `decodeGraphSliceEnvelopeInternal`), but nothing crosses FFI: there is no `extern "C"` fn, no Dart adapter, no `WorkerCommand`, no `ZanshinWorker`/`RepoHandle` method — the Flutter UI cannot fetch a graph. The epic's Story 4.6 text (`zanshin_graph_build` → `LaneCache` handle, `zanshin_graph_slice(handle, start, count)`, `zanshin_graph_close`, worker rebuilds on `OpHeadsChanged`, JSON) is superseded by ADR-0001 (FlatBuffers), ADR-0002 AC-4 (no materialized cache → nothing to build/close/rebuild) and 4.4 (return-all: no `start`/`count`).

**Approach:** Add ONE extern fn `zanshin_graph_slice(handle: u64, revset: *const c_char, prioritize: *const c_char) -> *mut ZanshinBuf` in the existing `crates/zanshin-ffi/src/graph.rs` that borrows the `RepoSession`, passes both strings through to `zanshin_graph::collect_lanes`, and returns `graph_slice_to_envelope(&rows)` (or an error envelope with new registry codes); regenerate header/bindings via `cargo make codegen`; add the Dart adapter in `graph.dart`, a `GraphSliceCommand` + worker dispatch arm, `ZanshinWorker.graphSlice` / `RepoHandle.graphSlice`; prove it with Rust integration tests (incl. the 4.4-deferred re-derive-after-external-op test at the FFI surface, via a new jj-lib write helper in `test-helpers`) and a real-cdylib `packages/zanshin_core` worker test (extern-coverage guard); reconcile the planning docs.

## Boundaries & Constraints

**Always:**
- Build on 4.4: the wrapper calls `zanshin_graph::collect_lanes(&session.repo, &revset, &prioritize)` — never `stream_lanes`/`LaneAssigner` directly, never a second walk; re-resolve per call, nothing retained Rust-side (ADR-0002; the op-heads watcher/event stream of 3.6 is the UI's re-request trigger — the worker does NOT auto-re-derive).
- Pass-through (FR-JJ-17): `revset` and `prioritize` are caller-supplied CStrings (inbound rule: Dart allocates via `toNativeUtf8` and frees via `calloc.free`; Rust borrows via `cstr_to_string`). Both required at the worker level; `RepoHandle.graphSlice` pre-fills `prioritize` with the CLI default (`present(@)`, mirrored as Dart `defaultGraphPrioritize`, documented as a mirror of `zanshin_jj::DEFAULT_GRAPH_PRIORITIZE`) exactly like `opLog({int limit = -1})` — editable, never hidden. `"none()"` is the canonical no-prioritization value (documented).
- Envelope/transport (ADR-0001): FlatBuffers `Envelope<GraphSlice>` token (`vec_into_token`), freed by Dart via `FfiBuffer.fromToken`/`zanshin_buffer_free_token`; `catch(|| …)` panic backstop; `debug!(fn_name = "zanshin_graph_slice", handle)` span (no revset text at `info`+). Wire shape unchanged — `schemas/envelope.fbs` untouched (the `GraphSlice` payload from 4.2 is reused as-is; no `graph_handle`, no `total_rows` redefinition).
- Error mapping (AR-P-4, single-emission-point in `envelope.rs`; registry `docs/rust-error-codes.md` updated in the same commit): `LaneStreamError::Revset(ParseError{reason})` → NEW `jj.revset_parse_error` (context = reason); `Revset(ResolutionError{reason})` → NEW `jj.revset_resolution_error`; `Revset(JjLibError(s))` → existing `jj.jj_lib_error`; `Graph(GraphError::DanglingEdge{target})` → NEW `graph.dangling_edge` (context = target); plus the existing `ffi.invalid_handle` (handle `0`/`None`), `ffi.null_pointer`, `ffi.utf8_error` for either string.
- Codegen discipline: after adding the extern fn run `cargo make codegen` (flatc no-op, cbindgen → `crates/zanshin-ffi/include/zanshin_ffi.h`, ffigen → `packages/zanshin_core/lib/src/ffi/bindings.dart`); commit the regenerated files with the source; never hand-edit them.
- Coverage ratchet + extern-coverage guard: the new extern fn is credited ONLY through the cdylib path → a real-cdylib `packages/zanshin_core/test/worker/graph_test.dart` calling `graphSlice` is mandatory (otherwise `extern-coverage: FAIL`); `crates/zanshin-ffi/src/graph.rs` must not drop below its 99.45 baseline (unit-test the error mapper inline; integration tests in `crates/zanshin-ffi/tests/graph_ffi.rs`); commit the auto-raised `coverage-baseline.txt`.
- Quality bar: clippy pedantic refactor-not-suppress, rustfmt, SPDX first line, `# Errors` + `# Safety` rustdoc on the extern fn (cbindgen lifts it), scenario-named tests, `JJ_CONFIG`/`GIT_CONFIG_GLOBAL` pinned (`LazyLock` pattern in Rust; `Makefile.toml` pins for `dart test`), no timing asserts, fixtures `tiny-3-commits` (+ `medium-1k-commits` for one equality test) only, `dart analyze`/`dart format` clean, no `#[ignore]`/`skip:`.
- `lane.rs` `expect()` decision (deferred-work l.182, becomes FFI-reachable here): KEEP — both conversions are infallible on the supported 64-bit target (`u32`→`usize`; `usize`→`u32` needs > 4·10⁹ concurrently open lanes) and `catch_unwind` is the backstop; record the decision as a `// WHY:` at the site (comment-only edit of `lane.rs`) and close the deferred-work item. No behavioral change to `lane.rs`.
- `test-helpers` gains `pub fn add_commit_off_root(workspace_root: &Path, description: &str) -> String` (the jj-lib write helper 4.4's deferred item asked for — moved from `crates/zanshin-jj/tests/graph.rs`, which now calls the shared one). `test-helpers` is a test-only tool crate (coverage `exclude_prefix`, dev-dep everywhere) in the same category as `xtask` — the FR-JJ-16 ACL ("only `zanshin-jj` imports `jj_lib`") concerns production/library crates; justify the dep with a `# WHY:` in its `Cargo.toml` and in the Design Notes.
- Repo conventions: ONE focused commit on `main` (`feat(zanshin-ffi): add zanshin_graph_slice FFI wrapper + worker command (Story 4.6)`) incl. story artifacts and regenerated files; `flutter`/`dart` gate churn (`app/analysis_options.yaml`, `pubspec.lock`) reverted, never committed (4.1–4.4 precedent). Edit `epic-4-context.md` AFTER every planning-artifact edit so it stays the newest file.

**Block If:**
- `cargo make test` fails for a reason outside this story that cannot be fixed in scope (never lower the baseline / add an `exclude_prefix` / add a name to `EXTERN_COV_ALLOW`).
- `cargo make codegen` is unavailable (flatc/cbindgen/ffigen missing) — the generated files must be produced by the tool, never by hand.

**Never:**
- No `zanshin_graph_build` / `zanshin_graph_close`, no graph handle, no `LaneCache`, no Rust-side memoization or op-id exposure, no `start`/`count`/`limit`/`reversed`, no automatic re-derive in the worker on `OpHeadsChangedEvent` (the UI re-requests; the event stream already exists).
- No new `.fbs` table/field, no `schema_version`, no JSON; no edits to `zanshin-graph` beyond the `lane.rs` WHY comment; no edits to `zanshin-jj/src/**`; no new public `zanshin_jj` API.
- No metadata enrichment of rows; no `large-10k` fixture; no perf assertions; no Flutter UI code; no `zanshin_core.dart` barrel export of the graph models (precedent: no noun's models — `Change`, `WorkingCopyStatus`, `Operation`, `RepoHandle` — are exported from the barrel; the `ffi-abi.md` "reachability" note is updated to "reachable via the worker command", not by exporting).
- No shelling to the `jj` CLI anywhere (the external-op test mutates via jj-lib in `test-helpers`).

## I/O & Edge-Case Matrix

Fixture facts: **tiny** = `root` ← `@` and `root` ← c1 ← c2 ← c3 → `all()` = 5 rows (`@=0→root Some(0)`, `c3=c2=c1=1`, `root=0` with `present(@)`; with `none()` the first row is c3); a **fresh `initRepo` temp repo** = `@` (lane 0, one `Direct` edge → root, target_lane 0) + `root` (lane 0, no edges) = 2 rows.

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Tiny, CLI-default prio (Rust) | `zanshin_graph_slice(h, "all()", "present(@)")` on the tiny fixture | `ok`, `Payload::GraphSlice`, 5 rows, `total_rows == 5`; rows mapped back to `Row` equal `collect_lanes(&repo, "all()", "present(@)")` on a `zanshin_jj::Repo::open` of the same fixture (oracle); row 0 lane 0; last row has no edges | none |
| Tiny, `none()` prio (Rust) | same handle, prioritize `"none()"` | `ok`, 5 rows equal to the `collect_lanes` oracle with `"none()"`; first commit id differs from the `present(@)` call | none |
| Medium equality (Rust) | medium fixture, `"all()"`, `"present(@)"` | `ok`, 1002 rows == oracle, `total_rows == 1002` | none |
| Empty revset | `"none()"` revset | `ok`, `rows` present and empty, `total_rows == 0` | none |
| Re-derive after external op (Rust, 4.4 deferral) | open tiny via `zanshin_repo_open`, slice `all()` (5), `test_helpers::add_commit_off_root(&fx.path, "external op")`, slice `all()` again on the SAME handle | second call returns 6 rows and contains the new commit id; the first did not | none |
| Parse error (either param) | revset `"bogus_function()"` / prioritize `"("` / blank prioritize `""` | `ok:false`, `error.code == "jj.revset_parse_error"`, non-empty `context` | propagated, no panic, no rows |
| Resolution error (either param) | revset `"nonexistent-bookmark-xyz"` / prioritize same | `ok:false`, `"jj.revset_resolution_error"` | propagated |
| Null string | `revset == null` or `prioritize == null` | `ok:false`, `"ffi.null_pointer"` | no deref |
| Invalid UTF-8 | a `0x80` continuation byte in `revset` | `ok:false`, `"ffi.utf8_error"` | — |
| Zero handle | `handle == 0` | `ok:false`, `"ffi.invalid_handle"` | never a crash |
| Dart worker round-trip (real cdylib) | `initRepo(temp)` → `handle.graphSlice(revset: 'all()')` | `GraphSlice` with 2 rows, `totalRows == 2`; `rows[0].commitId == (await handle.getChange(status.workingCopyChangeId)).commitId`, lane 0, one edge `{target: rows[1].commitId, targetLane: 0, kind: direct}`; `rows[1]` lane 0, no edges | none |
| Dart errors | `revset: 'bogus_function()'` / `'nonexistent-bookmark-xyz'` / closed handleId via `worker.graphSlice` / `RepoHandle` after `close()` | `ZanshinFfiException` `jj.revset_parse_error` / `jj.revset_resolution_error` / `ffi.invalid_handle`; `StateError` synchronously from the `RepoHandle` guard | — |

</intent-contract>

## Code Map

- `crates/zanshin-ffi/src/graph.rs` -- module doc l.3-9 ("No `extern "C"` fn lives here yet…" → rewrite: builder + `zanshin_graph_slice` wrapper); keep `edge_kind`/`row_offset`/`graph_slice_to_envelope` l.16-88 untouched; ADD `fn map_lane_stream_err(e: LaneStreamError) -> FfiErrorObj` (4 arms, see Intent) + `#[no_mangle] pub unsafe extern "C" fn zanshin_graph_slice(handle: u64, revset: *const c_char, prioritize: *const c_char) -> *mut ZanshinBuf` modelled 1:1 on `change.rs` l.148-166 (`debug!` → `catch` → `handle_from_raw::<RepoSession>(handle as *mut RepoSession)` with the same SAFETY comment → `cstr_to_string` both strings → `collect_lanes(&session.repo, &revset, &prioritize).map_err(map_lane_stream_err)?` → `Ok(graph_slice_to_envelope(&rows))` → `vec_into_token`); rustdoc with `# Errors` (all codes) and `# Safety` (handle origin, CString ownership, token free-once) — cbindgen lifts it. Inline tests: extend `mod tests` with `map_lane_stream_err_maps_every_variant` (ParseError/ResolutionError/JjLibError/DanglingEdge → code + context).
- `crates/zanshin-ffi/src/change.rs` l.9-20 (imports), l.24-35 (error mapper shape), l.148-166 (extern fn shape incl. SAFETY/`cstr_to_string` null→`ffi.null_pointer`, utf8→`ffi.utf8_error`) -- the precedent to copy. READ-ONLY.
- `crates/zanshin-ffi/src/envelope.rs` l.26-43 (the `JJ_*` const block) -- ADD `pub const JJ_REVSET_PARSE_ERROR: &str = "jj.revset_parse_error";`, `pub const JJ_REVSET_RESOLUTION_ERROR: &str = "jj.revset_resolution_error";`, `pub const GRAPH_DANGLING_EDGE: &str = "graph.dangling_edge";` each with the `/// AR-P-4: emitted by graph.rs …` doc line (re-exported via `pub use envelope::*` in `lib.rs`).
- `crates/zanshin-ffi/src/repo.rs` l.123-129 `pub(crate) struct RepoSession { pub(crate) repo: Repo, … }` -- the borrowed session; READ-ONLY.
- `crates/zanshin-ffi/src/ffi_strings.rs` l.45 `pub unsafe fn cstr_to_string(ptr) -> Result<String, FfiErrorObj>`, l.122 `vec_into_token`, l.107 `ZanshinBuf` -- reuse. READ-ONLY.
- `crates/zanshin-ffi/src/handle.rs` `handle_from_raw` -- reuse. READ-ONLY.
- `crates/zanshin-graph/src/slice.rs` `collect_lanes(repo, revset, prioritize) -> Result<Vec<Row>, LaneStreamError>`; `crates/zanshin-graph/src/stream.rs` l.13-22 `LaneStreamError { Revset(zanshin_jj::RevsetError), Graph(GraphError) }`; `crates/zanshin-jj/src/revset.rs` l.18-36 `RevsetError { ParseError{reason}, ResolutionError{reason}, JjLibError(String) }`; `crates/zanshin-graph/src/lane.rs` l.110-120 `GraphError::DanglingEdge{target}` -- the inputs of the mapper. READ-ONLY.
- `crates/zanshin-graph/src/lane.rs` l.274-280 (`fn index` / `fn lane_number` `expect()`s) -- ADD one `// WHY:` comment block above (infallible on 64-bit; FFI-reachable since 4.6 behind `catch_unwind`; decision recorded in deferred-work). Comment-only.
- `crates/zanshin-ffi/tests/graph_ffi.rs` (NEW) -- mirror `tests/change_ffi.rs` scaffolding (`ENV_GUARD`/`pin_env` l.26-37, `read_and_free` l.46-54, `parse_envelope` l.57-59, `cstr` l.62-64, open-fixture helper l.69-99 minus the status part) + a `rows_from_wire(fbs::GraphSlice) -> Vec<Row>` mapper (copy of `graph.rs` test helper l.154-178) and an `oracle(path, revset, prio) -> Vec<Row>` via `zanshin_jj::Repo::open(path)` + `zanshin_graph::collect_lanes`; one test per I/O-matrix Rust row (tiny default/`none()`/medium equality, empty, re-derive-after-external-op via `test_helpers::add_commit_off_root`, parse/resolution for EACH param incl. blank prioritize, null revset, null prioritize, invalid UTF-8, zero handle); every token freed; every handle closed.
- `crates/test-helpers/Cargo.toml` -- ADD `jj-lib = { workspace = true }` + `pollster = { workspace = true }` with a `# WHY:` (test-only write helper for the ADR-0002 re-derive tests; test-helpers is a tool crate like xtask, not a shipped library — FR-JJ-16 ACL unaffected); `crates/test-helpers/src/lib.rs` -- ADD `pub fn add_commit_off_root(workspace_root: &Path, description: &str) -> String` + a private `make_test_settings()` (bodies moved verbatim from `crates/zanshin-jj/tests/graph.rs` l.33-50 + l.72-98; rustdoc: external jj-lib transaction = a new operation, returns the hex commit id; `# Panics` on any jj-lib failure — test helper).
- `crates/zanshin-jj/tests/graph.rs` l.13-17 (jj_lib imports), l.33-50 (`make_test_settings`), l.72-98 (`add_commit_off_root`), l.360 (call site) -- REPLACE the local helper with `use test_helpers::{add_commit_off_root, extract_fixture};`, delete the two local fns and the now-unused `jj_lib::*`/`Path` imports (only if unused elsewhere in the file — `Path` is used only by the helper; `ObjectId as _`/`Repo as _` only by the helper). Nothing else changes.
- `packages/zanshin_core/lib/src/ffi/graph.dart` -- header comment l.10-12 (rewrite: adapter + models + decoder; `dart:ffi` stays inside `ffi/`); ADD imports (`dart:ffi as ffi`, `package:ffi/ffi.dart`, `bindings.dart`, `ffi_buffer.dart`) and `Uint8List zanshinGraphSlice(int rawHandle, String revset, String prioritize)` modelled on `change.dart` l.26-39 (two `toNativeUtf8` pointers, nested try/finally: free the buffer, then both C strings), plus `const String defaultGraphPrioritize = 'present(@)';` (doc: mirrors `zanshin_jj::DEFAULT_GRAPH_PRIORITIZE`, CLI `revsets.log-graph-prioritize` default; `'none()'` = no prioritization); decoder docs l.86-89/l.101 ("production calls go through the worker (Story 4.6)" → `ZanshinWorker.graphSlice`).
- `packages/zanshin_core/lib/src/ffi/change.dart` l.26-39 -- adapter precedent. READ-ONLY.
- `packages/zanshin_core/lib/src/worker/commands.dart` -- ADD `final class GraphSliceCommand extends WorkerCommand { handleId, revset, prioritize }` after `GetChangeCommand` (l.123-141 precedent; doc: worker looks up the raw handle, calls `zanshinGraphSlice`, replies `BufferResult` with `Envelope<GraphSlice>` bytes).
- `packages/zanshin_core/lib/src/worker/isolate.dart` -- ADD `import '../ffi/graph.dart' as repo_ffi_graph;` (l.11-30 block, alphabetical), `Future<repo_ffi_graph.GraphSlice> graphSlice(int handleId, {required String revset, required String prioritize})` after `getChange` (l.501-514 precedent: `send(GraphSliceCommand(...))` → `decodeGraphSliceEnvelopeInternal`), and a `case GraphSliceCommand(:final int handleId, :final String revset, :final String prioritize):` arm after the `GetChangeCommand` arm (l.712-727 precedent: unknown id → `ffi.invalid_handle` envelope, else `repo_ffi_graph.zanshinGraphSlice(raw, revset, prioritize)`). The sealed switch is exhaustive — the new subclass MUST get an arm or `dart analyze` fails.
- `packages/zanshin_core/lib/src/worker/handle.dart` -- ADD `import '../ffi/graph.dart' show GraphSlice, defaultGraphPrioritize;` + `Future<GraphSlice> graphSlice({required String revset, String prioritize = defaultGraphPrioritize})` after `getChange` (l.80-90 precedent: closed guard `StateError`, delegate to `_worker.graphSlice`).
- `packages/zanshin_core/test/worker/graph_test.dart` (NEW) -- mirror `test/worker/change_test.dart` (real `ZanshinWorker.start()` + `initRepo(temp, backend: 0)`): round-trip (2 rows, oracle via `status()` + `getChange(...).commitId`, edge to the root row, lane/colorIdx 0, `totalRows == 2`), `none()` revset → empty, parse error → `jj.revset_parse_error`, resolution error → `jj.revset_resolution_error`, closed handle via `worker.graphSlice` → `ffi.invalid_handle`, `RepoHandle.graphSlice` after `close()` → `StateError`.
- `packages/zanshin_core/test/ffi/graph_test.dart` (decode-contract, 4.2) -- unchanged; header comment mention of "no real cdylib" stays true for that file.
- `crates/zanshin-ffi/include/zanshin_ffi.h`, `packages/zanshin_core/lib/src/ffi/bindings.dart` -- regenerated by `cargo make codegen` ONLY (new `zanshin_graph_slice` decl / `@Native` binding); commit.
- `docs/rust-error-codes.md` l.35-53 (Code Table) -- ADD 3 rows: `jj.revset_parse_error`, `jj.revset_resolution_error` (domain `jj`, "**Emitted — Story 4.6** (`envelope.rs::…`, `graph.rs`)"; note: reusable by the Epic 9 `eval_revset` joker), `graph.dangling_edge` (domain `graph`, upstream-stream contract violation; first `graph.*` code).
- `docs/ffi-abi.md` l.333-388 "GraphSlice payload (Story 4.2)" -- REWRITE the intro paragraph ("No extern fn yet" → the exported symbol), ADD a `### zanshin_graph_slice` subsection in the style of l.67-107 (C signature, parameter semantics incl. pass-through/`none()`/CLI default, success payload pointer to the shapes below, error-code table), ADD "Dart worker integration" lines (`GraphSliceCommand`, `ZanshinWorker.graphSlice`, `RepoHandle.graphSlice` default), and REWRITE the "Reachability (until 4.6)" bullet l.385-388 (reachable via the worker command; models not barrel-exported by convention).
- `_bmad-output/planning-artifacts/epics.md` §Story 4.6 l.3002-3062 -- APPEND a dated "**Delivered (2026-08-23, Story 4.6 done):**" blockquote after the l.3004 transport note (4.2/4.3/4.4 precedent): one extern fn `zanshin_graph_slice(handle, revset, prioritize)` over `collect_lanes`; no `_build`/`_close`/graph handle/`start`/`count` (ADR-0002 AC-4 + 4.4 return-all); watcher AC superseded (UI re-requests on `OpHeadsChangedEvent`, worker holds no graph state); `GraphSliceCommand(handleId, revset, prioritize)`; tests read typed accessors + Verifier; new codes.
- `_bmad-output/planning-artifacts/architecture.md` l.459 (`graph.rs # zanshin_graph_*`) -- leave (still true); l.601 row mentions `schemas/graph.fbs` + `large-10k` (pre-existing drift, 4.2/4.3 deferred — leave).
- `_bmad-output/implementation-artifacts/deferred-work.md` l.100 ("4.6 still needs its rewrite at create-story") -- annotate **4.6 DELIVERED (2026-08-23)** (one extern fn, no handle/rebuild/close, no start/count; worker does not auto-re-derive); l.182 (`expect()` item) -- annotate **RESOLVED (Story 4.6, 2026-08-23): keep** + rationale; ADD a line under the 4.4 deferral context that the re-derive-after-external-op test now exists at the FFI surface (`crates/zanshin-ffi/tests/graph_ffi.rs`) via the new `test_helpers::add_commit_off_root`.
- `_bmad-output/implementation-artifacts/epic-4-context.md` l.16 (4.6 → done + one-line delivery), l.35 "FFI surface (4.6)" bullet (→ delivered as `zanshin_graph_slice`; `expect()` decision; codes), l.47 (4.6 dependency line: event dispatch is the UI's re-request trigger, not an auto-rebuild). EDIT LAST.
- `_bmad-output/implementation-artifacts/sprint-status.yaml` l.89 `4-6-ffi-wrapper-zanshin-ffi-src-graph-rs: backlog` → `review` (note "(delivered as zanshin_graph_slice over collect_lanes, see last_updated)"); l.48 `last_updated` history line: prepend a DEV COMPLETE entry with inline gate evidence, keep the `PREV:` chain (step-04 flips to `done`). `epic-4` stays `in-progress` (the workflow does not close the epic).
- `coverage-baseline.txt` -- the ratchet may raise `crates/zanshin-ffi/src/graph.rs` (99.45 → expect 100.00 once the wildcard arm moves or stays ≥ 99.45) and `envelope.rs`; `crates/test-helpers/` is `exclude_prefix` (l.11) — no entry; commit the updated file.

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-ffi/src/envelope.rs` -- add the three `pub const` error codes -- AR-P-4 single emission point.
- `crates/zanshin-ffi/src/graph.rs` -- add `map_lane_stream_err` + `zanshin_graph_slice` + rustdoc + inline mapper test; rewrite module doc -- the FFI surface over `collect_lanes`.
- `crates/zanshin-graph/src/lane.rs` -- `// WHY:` comment at `index`/`lane_number` -- record the FFI-reachable-`expect()` decision at the site.
- `crates/test-helpers/{Cargo.toml,src/lib.rs}` + `crates/zanshin-jj/tests/graph.rs` -- move `add_commit_off_root` (+ private `make_test_settings`) into `test-helpers`; zanshin-jj test imports it -- the jj-lib write helper the 4.4 deferral needs, no duplication.
- `crates/zanshin-ffi/tests/graph_ffi.rs` (new) -- one test per Rust I/O-matrix row incl. the re-derive-after-external-op test -- FFI-surface proof through the public extern fn + typed accessors + Verifier.
- run `cargo make codegen` -- regenerate `zanshin_ffi.h` + `bindings.dart` -- the committed generated surface must carry `zanshin_graph_slice`.
- `packages/zanshin_core/lib/src/ffi/graph.dart` -- adapter `zanshinGraphSlice` + `defaultGraphPrioritize` + doc updates -- the Dart half of the call.
- `packages/zanshin_core/lib/src/worker/{commands.dart,isolate.dart,handle.dart}` -- `GraphSliceCommand`, dispatch arm, `ZanshinWorker.graphSlice`, `RepoHandle.graphSlice` -- the worker bus path (AD-4, Model A).
- `packages/zanshin_core/test/worker/graph_test.dart` (new) -- real-cdylib round-trip + errors + guard -- extern-coverage credit + end-to-end proof.
- `docs/rust-error-codes.md`, `docs/ffi-abi.md` -- registry rows; `zanshin_graph_slice` section + worker integration + reachability -- ABI contract.
- `_bmad-output/planning-artifacts/epics.md` (§4.6 delivered note), `_bmad-output/implementation-artifacts/deferred-work.md` (l.100, l.182, 4.4-deferral note), then `epic-4-context.md` (LAST) -- doc reconciliation -- planning docs stop describing build/close/rebuild; epic-context cache stays valid.
- `_bmad-output/implementation-artifacts/sprint-status.yaml` -- `4-6` → `review` + `last_updated` DEV entry -- tracking convention.
- run `cargo make test` (unpiped, check exit code) -- fix by refactoring; commit the raised `coverage-baseline.txt`; revert gate churn; one commit -- definition of done.

**Acceptance Criteria:**
- Given an open `RepoSession` handle, when `zanshin_graph_slice(handle, revset, prioritize)` is called, then it returns a Verifier-valid `Envelope<GraphSlice>` whose rows equal `zanshin_graph::collect_lanes` for the same repo/arguments (same order, same lanes/edges, `total_rows == rows.len()`), re-derived from head on every call (an external jj-lib operation between two calls on the same handle is visible in the second), with no Rust-side graph state retained.
- Given invalid input (bad/unresolvable revset or prioritize, null/invalid-UTF-8 string, zero handle), when the wrapper is called, then it returns an error envelope with the registry code from the I/O matrix and never panics, leaks a token, or returns partial rows.
- Given a booted `ZanshinWorker` on the real cdylib, when `RepoHandle.graphSlice(revset: 'all()')` (prioritize pre-filled with `present(@)`) runs on a freshly initialised repo, then it returns the decoded 2-row `GraphSlice` with the working-copy commit first (oracle: `getChange(status.workingCopyChangeId).commitId`) and errors surface as `ZanshinFfiException` with the same codes.
- Given the finished tree, when `cargo make codegen` has run and `cargo make test` runs unpiped, then it exits 0 with `extern-coverage: OK` (the new extern fn credited by the Dart test), no per-file regression (`graph.rs` ≥ 99.45), hygiene/clippy/fmt/analyze/format/deny green; `git status` is clean after the single commit (deliberate gate-churn reverts aside).

## Spec Change Log

## Review Triage Log

### 2026-08-23 — Review pass
- intent_gap: 0
- bad_spec: 0
- patch: 14: (high 0, medium 1, low 13)
- defer: 0
- reject: 13
- addressed_findings:
  - `[medium]` `[patch]` The Dart path never proved that the caller's `prioritize` reaches Rust (every Dart error test sent a bad *revset*; a worker arm ignoring `prioritize` would have stayed green — an FR-JJ-17 pass-through regression hole at the surface the UI calls) — added two real-cdylib tests (`graphSlice_on_bogus_prioritize_surfaces_jj_revset_parse_error`, `graphSlice_on_unknown_bookmark_prioritize_surfaces_jj_revset_resolution_error`).
  - `[low]` `[patch]` `defaultGraphPrioritize` (Dart mirror of `zanshin_jj::DEFAULT_GRAPH_PRIORITIZE`) had no value pin — added `defaultGraphPrioritize_mirrors_the_rust_cli_default` (`'present(@)'`).
  - `[low]` `[patch]` `zanshinGraphSlice` allocated the `revset` C string outside the try/finally (a throwing second `toNativeUtf8` would leak it) — each allocation now freed by its own `finally`.
  - `[low]` `[patch]` An interior U+0000 in either user-typed expression would be silently truncated by `toNativeUtf8` (Rust would evaluate a shorter revset) — `zanshinGraphSlice` now throws `ArgumentError` (two guard tests); rule documented in the adapter doc and `docs/ffi-abi.md`.
  - `[low]` `[patch]` Adapter doc listed `ffi.null_pointer` "(never…)" but not `ffi.utf8_error` — replaced with a pointer to the ABI table.
  - `[low]` `[patch]` `tests/graph_ffi.rs` exercised `ffi.utf8_error` only for `revset` — added `graph_slice_invalid_utf8_prioritize_returns_ffi_utf8_error`.
  - `[low]` `[patch]` `jj.jj_lib_error` was documented for `zanshin_graph_slice` but pinned only by the inline mapper test — added `graph_slice_on_corrupt_op_heads_returns_jj_jj_lib_error` (same corruption mechanism as `crates/zanshin-jj/tests/graph.rs`).
  - `[low]` `[patch]` `assert_error` did not assert `data_type == Payload::NONE` (no partial rows at the union level) and only one parse-error test asserted a non-empty `context` although the ABI promises "reason in `context`" — `assert_error` extended + `assert_error_with_context` used by all five parse/resolution tests.
  - `[low]` `[patch]` `docs/rust-error-codes.md` `jj.jj_lib_error` row and the `envelope.rs` doc named `repo.rs` as sole emitter — now list the read wrappers incl. `graph.rs` (Story 4.6).
  - `[low]` `[patch]` `docs/ffi-abi.md` `ffi.invalid_handle` row said "not a live session" although Rust detects only `0` (liveness = the worker's handle-table lookup; stale non-zero = UB) — row reworded.
  - `[low]` `[patch]` `docs/ffi-abi.md` lacked the payload size model (whole revset materialised into one buffer, rows × edges, no cap, `total_rows` saturates, copied once into Dart; windowing deferred) — one sentence added.
  - `[low]` `[patch]` `RepoHandle.graphSlice` / `ZanshinWorker.graphSlice` docs listed a partial error-code set — pointer to the full ABI table appended.
  - `[low]` `[patch]` `project-context.md` ACL bullet still named `xtask` as the only non-`zanshin-jj` `jj_lib` importer — `test-helpers` (test-only tool crate) added to the parenthetical.
  - `[low]` `[patch]` `deferred-work.md` l.100 heading still read "need a create-story REWRITE" although the body says all three rewrites are closed — heading prefixed "RESOLVED (2026-08-23)".

## Design Notes

- **Why ONE fn named `zanshin_graph_slice`:** no cache ⇒ no `_build`/`_close`; the name keeps the epic's symbol, matches the `GraphSlice` payload and 4.4's `slice.rs`/`collect_lanes` ("slice" = the revset-selected slice of the graph), and follows the "fn name == payload name" precedent (`zanshin_op_log` → `OpLog`, `zanshin_status` → `Status`).
- **Why the worker does not auto-re-derive on `OpHeadsChangedEvent`:** ADR-0002 — the repo handle is a warm loader, reads re-resolve to head per call; the worker holds no graph to invalidate, and 3.6 already streams `OpHeadsChangedEvent` to the UI, which decides when/what to re-request (backend exposes, UI decides). Wiring an automatic re-request would bake a revset/prioritize choice into the worker.
- **Why `jj.revset_*` (not `graph.*`) for revset failures:** the registry keys the domain by originating subsystem; `RevsetError` is `zanshin-jj`'s (and the codes are reusable by Epic 9's `eval_revset` joker). `graph.dangling_edge` is the first and only `graph.*` code — an upstream-stream contract violation, unreachable with real fixtures (pinned by the inline mapper test only).
- **Why `add_commit_off_root` moves to `test-helpers`:** 4.4 deferred the "re-derive after an external op" proof to 4.6's FFI surface and named exactly this helper as the reviewed way to get a jj-lib write into a crate that (correctly) has no `jj_lib` dependency. `test-helpers` is a test-only tool crate (dev-dep of every consumer, coverage `exclude_prefix`, never shipped) — the same category as `xtask`, which project-context explicitly exempts from the FR-JJ-16 ACL. A Dart-side mutation is impossible without shelling to `jj` (banned/non-deterministic), so the Rust integration test is the surface.
- **Why `defaultGraphPrioritize` as a Dart const:** FR-JJ-17 wants the CLI default pre-filled and editable; the UI cannot read a Rust const, and an extern getter for a 10-byte literal is over-engineering. It mirrors `zanshin_jj::DEFAULT_GRAPH_PRIORITIZE` (pinned to `"present(@)"` by `api_stability`).
- **Sketch (Rust):**
  ```rust
  #[no_mangle]
  pub unsafe extern "C" fn zanshin_graph_slice(handle: u64, revset: *const c_char, prioritize: *const c_char) -> *mut ZanshinBuf {
      debug!(fn_name = "zanshin_graph_slice", handle);
      let buf = catch(|| {
          let session = unsafe { handle_from_raw::<RepoSession>(handle as *mut RepoSession) }.ok_or_else(|| invalid_handle())?;
          let revset = unsafe { cstr_to_string(revset) }?;
          let prioritize = unsafe { cstr_to_string(prioritize) }?;
          let rows = collect_lanes(&session.repo, &revset, &prioritize).map_err(map_lane_stream_err)?;
          Ok(graph_slice_to_envelope(&rows))
      });
      vec_into_token(buf)
  }
  ```

## Verification

**Commands:**
- `cargo make codegen` -- expected: `zanshin_ffi.h` gains `zanshin_graph_slice`, `bindings.dart` gains its `@Native` binding; flatc output unchanged.
- `cargo test -p zanshin-ffi --test graph_ffi` and `cargo test -p zanshin-jj --test graph` -- expected: green.
- `cargo clippy --workspace --all-targets -- -D warnings`, `cargo fmt --all --check` -- expected: clean, no new `#[allow]`.
- `dart analyze` + `dart format --set-exit-if-changed` in `packages/zanshin_core` -- expected: clean (exhaustive switch satisfied).
- `cargo make test` (unpiped) -- expected: exit 0; `extern-coverage: OK`; `coverage-check: OK`; `coverage-baseline.txt` updated → commit it.
- `git status --porcelain` after the commit -- expected: empty.

## Auto Run Result

Status: done
Blocking condition: none

**Summary of implemented change.** Story 4.6 delivered as ONE extern fn `zanshin_graph_slice(handle: u64, revset: *const c_char, prioritize: *const c_char) -> *mut ZanshinBuf` in `crates/zanshin-ffi/src/graph.rs`: borrows the `RepoSession`, passes both caller-supplied expressions through (FR-JJ-17) to `zanshin_graph::collect_lanes` (re-derived from head on every call, nothing retained — ADR-0002) and returns the 4.2 `Envelope<GraphSlice>` via `graph_slice_to_envelope` (ADR-0001; `.fbs` untouched). Errors map to three NEW registry codes (`jj.revset_parse_error`, `jj.revset_resolution_error`, `graph.dangling_edge`) plus the existing `jj.jj_lib_error` / `ffi.invalid_handle` / `ffi.null_pointer` / `ffi.utf8_error`. Dart: `zanshinGraphSlice` adapter (+ interior-NUL guard, leak-safe nested frees), `defaultGraphPrioritize` mirror of the CLI default, `GraphSliceCommand(handleId, revset, prioritize)`, `ZanshinWorker.graphSlice`, `RepoHandle.graphSlice({required revset, prioritize = defaultGraphPrioritize})`. The epic's `zanshin_graph_build`/`LaneCache` handle/`zanshin_graph_close`/`start`+`count`/worker-rebuilds-on-`OpHeadsChanged`/JSON ACs are superseded (ADR-0001 + ADR-0002 AC-4 + 4.4 return-all; the UI re-requests on the existing `OpHeadsChangedEvent`, the worker holds no graph state). The 4.4-deferred "re-derive after an external op" proof now exists at the FFI surface (`graph_slice_rederives_from_head_so_an_external_commit_appears_on_the_next_call`) via the new jj-lib write helper `test_helpers::add_commit_off_root` (moved from `crates/zanshin-jj/tests/graph.rs`). The `lane.rs` `expect()` deferral (4.1) is closed as "keep" (infallible on the supported target, `catch_unwind` backstop) with a `// WHY:` at the site.

**Files changed (since `f80d3d176ca3e5925e239c2df210966f533893fe`).**
- `crates/zanshin-ffi/src/graph.rs` — module doc, `map_lane_stream_err`, `zanshin_graph_slice` + rustdoc, inline mapper test (4.2 builder untouched).
- `crates/zanshin-ffi/src/envelope.rs` — `JJ_REVSET_PARSE_ERROR`, `JJ_REVSET_RESOLUTION_ERROR`, `GRAPH_DANGLING_EDGE`; `JJ_JJ_LIB_ERROR` doc names the read wrappers.
- `crates/zanshin-ffi/tests/graph_ffi.rs` (new, 16 tests after review) — oracle equality vs `collect_lanes` (tiny `present(@)`/`none()`, medium 1002), empty revset, re-derive after external op, parse/resolution errors for each param incl. blank prioritize (with non-empty `context`), null revset/prioritize, invalid UTF-8 revset/prioritize, zero handle, corrupt op-heads → `jj.jj_lib_error`; `assert_error` pins `Payload::NONE`.
- `crates/zanshin-ffi/include/zanshin_ffi.h`, `packages/zanshin_core/lib/src/ffi/bindings.dart` — regenerated by `cargo make codegen` (one new symbol).
- `crates/zanshin-graph/src/lane.rs` — comment-only `// WHY:` at `index`/`lane_number`.
- `crates/test-helpers/{Cargo.toml,src/lib.rs}` — `jj-lib` + `pollster` (`# WHY:`), `add_commit_off_root` + private `make_test_settings`; `crates/zanshin-jj/tests/graph.rs` — uses the shared helper, local copy + `jj_lib` imports dropped; `Cargo.lock`.
- `packages/zanshin_core/lib/src/ffi/graph.dart` — adapter, NUL guard, `defaultGraphPrioritize`, docs; `worker/commands.dart` (`GraphSliceCommand`), `worker/isolate.dart` (import, `graphSlice`, dispatch arm), `worker/handle.dart` (`RepoHandle.graphSlice`).
- `packages/zanshin_core/test/worker/graph_test.dart` (new, 11 tests after review) — round-trip (2 rows, `getChange(status.workingCopyChangeId).commitId` oracle), `none()` → empty, parse/resolution errors for revset AND prioritize, closed handle → `ffi.invalid_handle`, `RepoHandle` guard → `StateError`, `defaultGraphPrioritize` pin, two NUL-guard tests.
- `coverage-baseline.txt` — `crates/zanshin-ffi/src/graph.rs` 99.45 → 99.60.
- `docs/rust-error-codes.md` (+3 rows, `jj.jj_lib_error` emitters), `docs/ffi-abi.md` (section intro, `### zanshin_graph_slice`, worker integration, reachability, size model, NUL rule, `ffi.invalid_handle` row).
- `_bmad-output/planning-artifacts/epics.md` (§4.6 dated Delivered note), `_bmad-output/project-context.md` (ACL parenthetical names `test-helpers`), `_bmad-output/implementation-artifacts/deferred-work.md` (l.100 RESOLVED + 4.6 DELIVERED, l.182 `expect()` RESOLVED keep), `epic-4-context.md` (4.6 done, FFI-surface bullet, dependency line — touched last among planning edits), `sprint-status.yaml` (4-6 → done + `last_updated` entries), this spec.

**Review findings breakdown.** 4 layers (Blind Hunter 16, Edge Case Hunter 3, Verification Gap 2, Intent Alignment ~7 descriptive divergences) → 28 raw → 27 unique: 0 intent_gap, 0 bad_spec, 14 patch (1 medium, 13 low — all applied, see Review Triage Log), 0 defer, 13 reject. Rejected: stale non-zero handle UB (Model A by design, identical to every wrapper; documented); duplicated `rows_from_wire`/`kind_from_wire` test helpers and the duplicated `setUp`/`tearDown` group (repo test convention, mirrors `change_test.dart`; 4.4 review precedent); the untouched 4.4-spec `deferred:` entry (historical artifact — `deferred-work.md` is the live tracker and records the closure); `epic-4-context` "done" vs `sprint-status` "review" (transient within this run; both `done` now); a `project-context.md` `overrides:`/rule carve-out for the kept infallible `expect()`s (normative ruleset edit — Ralph's call; decision is recorded at the site, in `deferred-work.md` and here — see residual risks); the Intent Alignment auditor's descriptive divergences (Readings A/B — graph-handle lifecycle, windowing scalars, worker-side rebuild, `jsonschema` — are the superseded readings the repository's own artifacts had already retired; error-code domain `jj.*` for `RevsetError` is a documented decision; `test-helpers`/`lane.rs`/planning edits originate from the 4.4/4.1 deferrals named in the spec).

**Follow-up review recommendation.** Patched this pass: high 0, medium 1, low 13 → score 3 × 1 + 13 = 16 ≥ 5 → `followup_review_recommended: true`.

**Verification performed.** Implementation run: `cargo make test` exit 0 (224.95 s) — 14 `graph_ffi` + 6 Dart worker graph tests, `extern-coverage: OK`, baseline RAISED (`graph.rs` 99.45 → 99.60, overall 98.66 % = 3170/3213 over 30 files), committed as `e1f8409`. Step-03 verification by the orchestrator: full `cargo make test` (stdout redirected to a file, exit code read directly) → exit 0 in 175.24 s, `coverage-check: OK — coverage held at 98.66%`, `extern-coverage: OK`; matrix audit: every I/O-matrix row covered by a test that ran and passed. Review pass (after the 14 patches): `cargo test -p zanshin-ffi --test graph_ffi` 16/16, clippy pedantic/fmt clean, `dart analyze`/`dart format` clean, `dart test test/worker/graph_test.dart` 11/11; full `cargo make test` → exit 0 in 184.79 s: 16 `graph_ffi` (both cargo and llvm-cov runs), 113 zanshin_core Dart tests, `coverage-check: OK — coverage held at 98.66% (3170/3213 lines)` (baseline unchanged by the patches), `extern-coverage: OK`; `flutter`/`dart` gate churn (`app/analysis_options.yaml`, `pubspec.lock`) reverted, not committed.

**Residual risks.** (1) The two kept `expect()`s in `lane.rs` are FFI-reachable now; they are infallible on the supported 64-bit target and backstopped by `catch_unwind`, but `project-context.md`'s Rust rule has no explicit carve-out for infallible-by-construction conversions — whether to add one (or to convert lanes to `usize` internally) is Ralph's call. (2) `crates/test-helpers` now imports `jj_lib` (test-only tool crate, coverage `exclude_prefix`, never shipped; named in `project-context.md` next to `xtask`) — a deliberate, reviewed widening of the FR-JJ-16 ACL's tooling exemption. (3) The watcher → re-derive property is proven at the Rust FFI surface (same handle, external jj-lib op), not as an `OpHeadsChangedEvent` → `graphSlice` Dart E2E (no Dart-side mutation helper exists without shelling to `jj`); the Dart worker deliberately does not auto-re-derive — the UI re-requests. (4) `graph.rs` sits at 99.60 %: the single uncovered line is the unreachable wildcard arm of the test-only `kind_from_wire` helper (pre-existing since 4.2).
