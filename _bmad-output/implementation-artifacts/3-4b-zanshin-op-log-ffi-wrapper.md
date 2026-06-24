# Story 3.4b — `zanshin_op_log` FFI wrapper + Dart op-log seam (op_log slice)

---
baseline_commit: 485e289
---

Status: review

<!-- Note: Validation is optional. Run validate-create-story for quality check before dev-story. -->

> **This is the `op_log` slice of Story 3.4b.** Per the 2026-06-15 WIP re-sequencing
> (sprint-status.yaml:103-114), Story 3.4b lands one thin read-path wrapper **per finished Epic-2
> noun**, each made "aus Flutter testbar" the moment its jj-lib noun is `done`:
>
> | Epic-2 noun (source) | 3.4b slice            | gate |
> |----------------------|-----------------------|------|
> | 2.4 `status` ✅ done   | `zanshin_status` ✅ done | shipped |
> | 2.6 `change` ✅ done   | `zanshin_change` ✅ done | shipped |
> | **2.7 `op_log`**     | **`zanshin_op_log` (THIS story)** | ⛔ **gated on 2.7** |
> | 2.8 `bookmarks`      | `zanshin_bookmarks`   | 2.8 backlog |
> | 2.9 `remotes`        | `zanshin_remotes`     | 2.9 backlog |
>
> **Stay in this slice** — do **not** build `bookmarks`/`remotes` or `zanshin_revset_resolve`.

> ## ⛔ HARD GATE — Story 2.7 must be `done` first
>
> This wrapper only **exposes** `zanshin_jj::Repo::op_log`; it never adds it. As of this story's
> creation `crates/zanshin-jj/src/op_log.rs` does **not** exist (sprint-status.yaml:73 — 2.7 is
> `backlog`/`ready-for-dev`). **Do not start the Rust side until Story 2.7 is `done`.** Before writing
> `map_op_log_err` / the `Operation`/`OpLog` FlatBuffers tables, **read the real
> `crates/zanshin-jj/src/op_log.rs`** and confirm the actual public shape — the `Operation` field set,
> the `OperationId` newtype, the `OpLogError` variants, the timestamp representation, and the
> `is_snapshot`/fallible-`Result` decisions are all subject to 2.7's resolved Open Questions
> (2.7 OQ1/OQ2/OQ4). The shapes below assume 2.7's **recommended defaults**; reconcile if Ralph
> overrode them. [verified: sprint-status.yaml:73-74; 2-7-implement-op-log-rs-operation-log-read.md]

---

## ⚠️ CRITICAL — Read this before writing any code (spec reconciliation)

The Story 3.4b acceptance criteria in `epics.md` (lines 2147-2249) are **stale on four axes** and are
superseded here. Treat the ACs in *this* file as the binding contract, not the epic prose:

1. **Transport is FlatBuffers, not JSON (ADR-0001).** The epic says `zanshin_log(handle, limit_json)`
   takes `limit_json = "{\"limit\": 100}"` and "returns a JSON envelope with `data` as the array of
   Operations", routing bad input through `internal.serialization_failed`. **All superseded.** Composite
   FFI data crosses as a FlatBuffers `Envelope` token (`*mut ZanshinBuf`); there is no JSON, no
   `serde::Serialize` on `Operation`, no `jsonschema`. This slice **adds one `Payload` member** (`OpLog`)
   and consumes the existing 3-0…3-4a / 3.4b-status / 3.4b-change infrastructure. [Source: docs/adr/0001; project-context.md `overrides:`; epics.md:2151,2201-2223]
2. **`limit` is a PLAIN SCALAR, and op_log has NO string argument (ADR-0001).** Per the fixed-scalar
   transport rule, `limit` crosses as a plain `i64` — **not** a `{"limit": …}` JSON wrapper. Unlike
   `change` (which takes a lone-string `change_id`), `op_log` takes **no** CString — so there is **no**
   `cstr_to_string`, **no** `ffi.null_pointer` / `ffi.utf8_error` error arm, and **no** `std::ffi::c_char`
   import. Marshalling is the simpler **status** shape (handle straight through) plus one scalar. The
   function is named **`zanshin_op_log`** (per the 3.4b header + Epic-3 work order), **NOT** the epic
   body's `zanshin_log` (AR-P-1: `zanshin_<noun>_<verb>`; noun = `op_log`). [Source: epics.md:2151,2156; schemas/envelope.fbs:5-8]
3. **The `zanshin_repo_*` ACs in the epic are owned by Story 3.4a (`done`).** Ignore the epic's 3.4b
   `zanshin_repo_open/init/clone/close` signatures entirely. This slice adds **one new function**:
   `zanshin_op_log`.
4. **Handle is a `u64` integer, not `*mut c_void`.** Per the committed 3.4a/3.4b-status/3.4b-change ABI,
   handles cross as a `ulong`; `zanshin_op_log` takes that `u64` back and **borrows** the `Repo` (it does
   *not* consume/close it). Null handle (`0`) → `ffi.invalid_handle`.

The **done** sibling **Story 3.4b-status** (`3-4b-zanshin-status-ffi-wrapper.md`) is the authoritative
pattern for everything here — handle-only marshalling, the list-of-tables builder, error mapping, codegen
discipline, and the full Dart seam. **Mirror it exactly.** `op_log` differs from `status` only by carrying
one extra scalar (`limit`) and by returning a **list** payload (`[Operation]`) — so the builder mirrors
`status_to_envelope`'s vector-of-tables shape (status.rs:40-92), not `change`'s single-table shape.

> ### ⚠️ PATH CORRECTION — the Dart bridge moved
> The `status`/`change` template stories cite `app/lib/src/...` and `app/test/...`. **Those paths are
> STALE.** The pure-Dart bridge now lives in the `zanshin_core` package. Use these CURRENT paths
> throughout (verified against the live tree):
> | Template says (STALE) | Use this (CURRENT) |
> |---|---|
> | `app/lib/src/ffi/<noun>.dart` | `packages/zanshin_core/lib/src/ffi/op_log.dart` |
> | `app/lib/src/worker/{commands,isolate,handle}.dart` | `packages/zanshin_core/lib/src/worker/{commands,isolate,handle}.dart` |
> | `app/lib/src/ffi/{bindings,envelope_zanshin.ffi_generated}.dart` | `packages/zanshin_core/lib/src/ffi/{bindings,envelope_zanshin.ffi_generated}.dart` |
> | `app/test/{worker,ffi}/<noun>_test.dart` | `packages/zanshin_core/test/{worker,ffi}/op_log_test.dart` |
> Dart imports use package URIs in tests (`import 'package:zanshin_core/src/ffi/op_log.dart';`) and
> relative imports inside the package (`import '../ffi/op_log.dart' as repo_ffi_op_log;`). The **Rust**
> paths are unchanged (`crates/zanshin-ffi/src/`, `schemas/envelope.fbs`, `docs/rust-error-codes.md`,
> `crates/zanshin-ffi/include/zanshin_ffi.h`).

---

## Scope (read once, then never widen)

**IN scope — the full Dart↔Rust bridge for `op_log`** (the bridge is in scope per
`feedback-scope-bridge-is-claudes-ui-is-ralphs`; only the Flutter UI is out):

- **Rust:** extend `schemas/envelope.fbs` (`Operation` + `OpLog` tables; append `OpLog` to `Payload`);
  new `extern "C" zanshin_op_log(handle: u64, limit: i64) -> *mut ZanshinBuf` in a new
  `crates/zanshin-ffi/src/op_log.rs`; map `&[zanshin_jj::Operation]` → FlatBuffers `OpLog`; map
  `OpLogError` → `error.code` (**reuses `jj.jj_lib_error` — no new code**); regenerate + commit all five
  codegen artifacts; Rust unit + integration tests.
- **Dart:** `OpLogCommand` (worker command, carries `handleId` + `limit`); the worker-isolate dispatch
  case; the `zanshinOpLog(int, int)` FFI adapter; main-side decode into a Dart `List<Operation>`;
  `ZanshinWorker.opLog()` + `RepoHandle.opLog()`; a Dart worker round-trip test against the **real cdylib**
  + a decode-contract unit test.

**OUT of scope:**

- Any Flutter widget / screen that *displays* the op-log (Ralph's separate work).
- The other 3.4b nouns (`bookmarks`, `remotes`) and `zanshin_revset_resolve`.
- The watcher (Stories 3.5/3.6) — `op_log` is a one-shot read; ADR-0002 re-resolves to head per call.
- Any `zanshin-jj` change — `Repo::op_log()` ships in **Story 2.7**. This slice only *exposes* it.
  (If 2.7 isn't `done` yet, see the HARD GATE above — do not implement 2.7 here.)
- Op-log **mutation / undo** — that is Story 6.2 (`op-log-undo-p0`); this is read-only.

---

## Story

As the Dart worker isolate (and, behind it, Ralph's future Flutter UI),
I want an `extern "C" zanshin_op_log(handle, limit)` wrapper that calls `zanshin_jj::Repo::op_log()` and
returns the operation list as a FlatBuffers `Envelope`, plus the Dart command/adapter/decode seam that
turns it into a typed `List<Operation>`,
so that the op-log read-path noun is callable end-to-end from Dart against a real repo — exercising the
first FFI read wrapper that takes a **fixed scalar argument** (the `limit`) alongside a handle.

---

## Acceptance Criteria

Grouped by deliverable. Each item is a checkable contract. The 9-group structure mirrors the `done`
`status`/`change` slices; op-log-specific divergences are flagged inline.

### AC-1 — wire schema: `Operation` + `OpLog` payload (`schemas/envelope.fbs`)

1. `schemas/envelope.fbs` gains, in `snake_case` (flatc emits `lowerCamelCase` getters), mirroring the
   existing `Signature` timestamp-field convention (envelope.fbs:76-81):
   ```fbs
   /// One entry in jj's operation log (FR-JJ-7).
   table Operation {
     id: string;                  // op id, plain forward hex (NOT reverse-hex)
     parent_ids: [string];        // parent op ids; empty for the root op; >1 for a DAG fork
     timestamp_millis: long;      // op end-time, millis since the Unix epoch
     tz_offset_minutes: int;      // timezone offset, minutes east of UTC
     user: string;                // metadata.username; may be empty
     host: string;                // metadata.hostname; may be empty
     description: string;         // jj's user-friendly summary; always present, may be empty
     root_op: bool;               // true iff the op-store root operation
     is_snapshot: bool;           // pure working-copy-snapshot op (2.7 D6)
   }

   /// The operation log: reverse-chronological (head op first, root op last).
   table OpLog {
     operations: [Operation];
   }
   ```
2. The new `OpLog` table is **appended** to the `Payload` union — never reordered (union tags are
   positional; reordering breaks the wire for `RepoHandle`/`Diagnostics`/`Status`/`Change`):
   ```fbs
   union Payload { RepoHandle, Diagnostics, Status, Change, OpLog }
   ```
3. The schema roadmap comment (envelope.fbs:36) is ticked: `Story 3-4b : status ✓, change ✓, op_log ✓, bookmarks, remotes`.
4. **Reconcile to the shipped 2.7 struct (HARD GATE).** The `Operation` table fields match the real
   `zanshin_jj::Operation` shape from Story 2.7 (id forward-hex, raw `timestamp` end-time as
   `millis_since_epoch`+`tz_offset_minutes`, `user`/`host`, `description`, `root_op`, `is_snapshot`). If
   Ralph dropped `is_snapshot` (2.7 OQ4) or changed the timestamp choice (2.7 OQ1), update the table to
   match — the wire mirrors the domain type, not this draft.

### AC-2 — `&[zanshin_jj::Operation]` → FlatBuffers mapping

5. A builder `fn op_log_to_envelope(ops: &[Operation]) -> Vec<u8>` in `crates/zanshin-ffi/src/op_log.rs`
   serialises the slice into a finished `Envelope<OpLog>` buffer. It builds **children before parents**
   (FlatBuffers requirement): for each `Operation`, create its `id`/`user`/`host`/`description` strings
   and the `parent_ids` `[string]` sub-vector, then the `Operation` table; collect the `Operation`
   offsets; then `create_vector` + the `OpLog` table; then the `Envelope` with `data_type = Payload::OpLog`.
6. Field-by-field mapping with no recomputation of jj-lib state: `id → op.id.0`; `parent_ids → op.parent_ids[*].0`;
   `timestamp_millis → op.timestamp.millis_since_epoch`; `tz_offset_minutes → op.timestamp.tz_offset_minutes`;
   `user/host/description` verbatim; `root_op`/`is_snapshot` verbatim. `b.finish(envelope, None)` — **plain
   finish, NOT size-prefixed** (length rides in `ZanshinBuf.len`, exactly as `status_to_envelope`).

### AC-3 — `zanshin_op_log` extern function

7. `crates/zanshin-ffi/src/op_log.rs` defines `#[no_mangle] pub unsafe extern "C" fn zanshin_op_log(handle: u64, limit: i64) -> *mut ZanshinBuf`, with a `# Safety` doc block (mirroring `zanshin_status`) and a `# Errors` doc block; `crates/zanshin-ffi/src/lib.rs` adds `pub mod op_log;`.
8. The body is wrapped in `envelope::catch(|| { … })` (panic backstop → `internal.panic`); emits a `debug!(fn_name = "zanshin_op_log", handle, limit)` span (the `limit` field is an intentional addition to the span vs. the `zanshin_status` template, which logs only `fn_name` + `handle`).
9. The repo is **borrowed** (not consumed): `handle_from_raw::<Repo>(handle as *mut Repo)`; `None`/`handle == 0` → `FfiErrorObj { code: FFI_INVALID_HANDLE, context: None }` (`ffi.invalid_handle`).
10. The `limit` scalar maps to `Option<usize>` via the **negative-sentinel** rule: `usize::try_from(limit).ok()` — a negative `limit` (canonically `-1`) → `None` ("all"); `0` → `Some(0)` (empty); `n > 0` → `Some(n)`. This is clippy-clean (no `as` cast) and covers the whole `Option<usize>` domain. The call is `repo.op_log(usize::try_from(limit).ok()).map_err(map_op_log_err)?`, then `Ok(op_log_to_envelope(&ops))`. The returned `*mut ZanshinBuf` is produced by `vec_into_token(buf)` and freed exactly once by Dart.

### AC-4 — `OpLogError` → `error.code` mapping (NO new code)

11. `fn map_op_log_err(e: OpLogError) -> FfiErrorObj` maps the single variant `OpLogError::Backend(reason)` → `FfiErrorObj { code: JJ_JJ_LIB_ERROR.to_owned(), context: Some(reason) }` (`jj.jj_lib_error`, the existing catch-all).
12. **No new error code is introduced.** op_log has no "not found" failure (listing the log never misses — the head/root op always exist), so — unlike `status` (`jj.no_working_copy`) and `change` (`jj.change_not_found`) — there is **no** new `pub const` in `envelope.rs` and **no** new row in `docs/rust-error-codes.md`. If 2.7 shipped a non-`Backend` `OpLogError` variant (it should not — 2.7 D4), add the code per the registry's 4-step process; otherwise leave `envelope.rs` and the registry untouched. [Source: docs/rust-error-codes.md; 2.7 AC-7]

### AC-5 — codegen committed

13. `cargo make codegen` is run and **all five** generated artifacts are committed; generated files are **never** hand-edited. Run codegen **TWICE**: once after the `schemas/envelope.fbs` edit (regenerates the FlatBuffers accessors), and again after the new `zanshin_op_log` extern symbol exists (regenerates the C header + ffigen bindings). The artifacts:
    - `crates/zanshin-ffi/src/envelope_generated.rs` (gains `Operation`/`OpLog` + builders + `OpLog` in the `Payload` union; `data_as_op_log()` accessor),
    - `packages/zanshin_core/lib/src/ffi/envelope_zanshin.ffi_generated.dart` (gains `Operation`/`OperationObjectBuilder`, `OpLog`/`OpLogObjectBuilder`, `OpLog` in `PayloadTypeId`),
    - `crates/zanshin-ffi/include/zanshin_ffi.h` (gains `ZanshinBuf *zanshin_op_log(uint64_t handle, int64_t limit);`),
    - `packages/zanshin_core/lib/src/ffi/bindings.dart` (gains the `external` `zanshin_op_log` binding),
    - `schemas/envelope.fbs` (the hand-edited source, AC-1).

### AC-6 — Rust tests

14. **Builder unit test** in `op_log.rs` `#[cfg(test)]`: construct a `Vec<zanshin_jj::Operation>` exercising **every field** with ≥2 ops — a **root op** (`root_op == true`, `parent_ids` empty) **and** a non-root op (single parent), plus a **multi-parent** op (`parent_ids.len() >= 2`, the DAG-fork case); distinct `user`/`host`/`description`/`timestamp`/`is_snapshot`. Serialise via `op_log_to_envelope`, parse with `flatbuffers::root::<fbs::Envelope>` (runs the `Verifier`), assert `ok`, `data_type == Payload::OpLog`, `operations().len()`, and that **every field round-trips by equality** (incl. the `parent_ids` sub-vector, `root_op`, `is_snapshot`, timestamp). Mirror `status.rs:146-224`.
15. **`map_op_log_err` unit test**: `map_op_log_err(OpLogError::Backend("boom".into()))` → `code == JJ_JJ_LIB_ERROR`, `context == Some("boom")`. (Single arm — `OpLogError` has only `Backend`; this is the only test exercising the mapping, so a regression would otherwise pass CI. Mirror `status.rs:229-244`, adapted to one arm.)
16. **Integration tests** `crates/zanshin-ffi/tests/op_log_ffi.rs` (NEW), mirroring `tests/change_ffi.rs` / `tests/status_ffi.rs` harness (`ENV_GUARD`/`pin_env`, `read_and_free(token)`, `parse_envelope(bytes)`, an `open_fixture()` helper returning the handle):
    - **valid round-trip:** open `tiny-3-commits` → `zanshin_op_log(handle, -1)` → assert `ok`, `data_type == OpLog`, `operations().len() >= 1`, the **last** element is the root op (`root_op == true`, empty `parent_ids`), reverse-chronological (head first) → `zanshin_repo_close`.
    - **limit round-trip:** `zanshin_op_log(handle, 1)` → exactly 1 operation (the most recent).
    - **invalid handle:** `zanshin_op_log(0, -1)` → `ok == false`, `error.code == ffi.invalid_handle`.
    - (**No null/utf8 tests** — op_log has no CString arg; this asymmetry vs. `change` is deliberate — add a one-line comment noting it.)
17. Buffers are read **only** through the generated typed accessors + `Verifier` — no `jsonschema`, no hand-parsing. Every token is freed; env is pinned; no network.

### AC-7 — Dart bridge (the seam Story 3.9 reserved; paths = `packages/zanshin_core/...`)

18. `packages/zanshin_core/lib/src/worker/commands.dart` gains `final class OpLogCommand extends WorkerCommand { const OpLogCommand({required super.commandId, required this.handleId, required this.limit}); final int handleId; final int limit; }` (only `int`/`String` fields cross the port). Adding the sealed subclass forces the worker `switch` to handle it (compile-time exhaustiveness).
19. `packages/zanshin_core/lib/src/worker/isolate.dart`: add the import alias `import '../ffi/op_log.dart' as repo_ffi_op_log;` in **correct alphabetical position** (`directives_ordering` lint — the change slice hit this exact gotcha); add the worker dispatch `case OpLogCommand(:final int handleId, :final int limit):` that **looks up** `handles[handleId]` (never removes), sends an `ffi.invalid_handle` `EnvelopeObjectBuilder` error envelope for an unknown handle, else `responseSP.send((commandId, BufferResult(repo_ffi_op_log.zanshinOpLog(raw, limit))))`; add the main-side `Future<List<Operation>> opLog(int handleId, int limit)` that `send`s `OpLogCommand` and returns `repo_ffi_op_log.decodeOpLogEnvelopeInternal(bytes)`.
20. `packages/zanshin_core/lib/src/ffi/op_log.dart` (NEW): the `Uint8List zanshinOpLog(int rawHandle, int limit)` adapter (mirror `status.dart` — pass the scalar straight through, read the token via `FfiBuffer.fromToken`, dispose in `finally`; **no** `toNativeUtf8`/`calloc.free`); a `final class Operation { … }` model (`id`, `List<String> parentIds`, `int timestampMillis`, `int tzOffsetMinutes`, `user`, `host`, `description`, `bool rootOp`, `bool isSnapshot`); and the decode pair `@visibleForTesting List<Operation> decodeOpLogEnvelope(Uint8List)` + `List<Operation> decodeOpLogEnvelopeInternal(Uint8List)` delegating to a private `_decodeOpLogEnvelope` (throws `ZanshinFfiException(code, context)` on `!ok`; guards `payload is! fbs.OpLog` → `ZanshinFfiException('ffi.unknown', 'expected OpLog payload, got ${env.dataType}')`; maps `payload.operations` → `List<Operation>`, `?? const []`).
21. `packages/zanshin_core/lib/src/worker/handle.dart`: add `import '../ffi/op_log.dart' show Operation;` and a `Future<List<Operation>> opLog({int limit = -1})` method with the synchronous `if (_closed) { throw StateError('RepoHandle is already closed'); }` guard, delegating to `_worker.opLog(_handleId, limit)`.
22. No `dart:ffi` type leaks out of `packages/zanshin_core/lib/src/ffi/`; the worker command/response protocol and `CommandCorrelator` are reused unchanged (`op_log` replies as the existing `BufferResult` — no new `WorkerResponse` type). `responses.dart` and `zanshin_core.dart` (public export) are **unchanged**.

### AC-8 — Dart tests (paths = `packages/zanshin_core/test/...`)

23. `packages/zanshin_core/test/worker/op_log_test.dart` (NEW), real cdylib (no mocks), mirroring `test/worker/change_test.dart`: `ZanshinWorker.start()` + `initRepo(tempDir.path, backend: 0)` → `handle.opLog()` round-trip asserting **by EQUALITY against an oracle** (F20 — never `isNotNull`/`isNotEmpty` on non-nullable fields): the root op's `parentIds` is **`isEmpty`** AND `rootOp == true`; ops are in reverse-chronological order; `user`/`host` are non-empty AND equal across the head op and an independent jj-lib oracle read of the same op (do **NOT** hard-code a literal identity string — derive it from the oracle, matching `change_test.dart`'s author/committer cross-check, change_test.dart:71-75); `handle.opLog(limit: 1)` → `length == 1`. Plus: closed-handle → `ffi.invalid_handle` (close the handle, then call `worker.opLog(handle.handleId, -1)` directly, bypassing the guard, expect `ZanshinFfiException` with `code == 'ffi.invalid_handle'`); `RepoHandle.opLog` on a closed handle → synchronous `StateError`.
24. `packages/zanshin_core/test/ffi/op_log_test.dart` (NEW), decode-contract via synthetic buffers (generated `EnvelopeObjectBuilder` / `OpLogObjectBuilder` / `OperationObjectBuilder`), mirroring `test/ffi/change_test.dart`: error envelope → `ZanshinFfiException` (code + context asserted); `ok == true` with a **non-`OpLog`** payload (e.g. `RepoHandle`) → `ffi.unknown`; a fully-populated `OpLog` (≥2 ops incl. a root op with empty `parentIds`+`rootOp:true` and a multi-parent op) → every decoded field equals the builder input (EQUALITY).

### AC-9 — quality gate green (incl. coverage ratchet)

25. `cargo make test` passes end-to-end: `cargo clippy --workspace --all-targets -- -D warnings` (pedantic — **refactor, don't `#[allow]`**; any unavoidable suppression carries a `// WHY:`), `cargo fmt --all --check`, all Rust unit + integration tests, `cargo deny check advisories bans`, the cargo-hygiene gate, the Dart suite (`flutter test`, incl. the new worker + decode tests), `dart analyze --fatal-infos --fatal-warnings`, and `dart format` — all clean. **Plus the coverage ratchet** (`cargo make coverage`): the new `crates/zanshin-ffi/src/op_log.rs` reaches the per-file floor (≥ 80 %; aim for **100 %** like the `change.rs`/`status.rs` wrappers, via the builder unit test + `map_op_log_err` test + the cross-FFI integration path); the auto-raised `coverage-baseline.txt` is committed. `crates/zanshin-ffi/src/envelope.rs` stays 100 % (no new executable line). **Never lower the baseline or add an `exclude_prefix`.** [Source: CLAUDE.md; coverage-baseline.txt]
26. Every new hand-written `.rs`/`.dart` file starts with `// SPDX-License-Identifier: MIT` (generated files exempt). No `unsafe` outside the documented `extern "C"` seam; the `extern "C"` fn carries a `# Safety` doc section and every `unsafe` block a `// SAFETY:` comment. No new crate, no `Cargo.toml` dependency change.

## Tasks / Subtasks

- [x] **T0 — Confirm the 2.7 gate** (HARD GATE)
  - [x] Verify Story 2.7 is `done` in sprint-status.yaml. Read the shipped `crates/zanshin-jj/src/op_log.rs`; confirm `Operation` fields, `OperationId`, `OpLogError` variants, the timestamp choice, and `is_snapshot`. Reconcile AC-1/AC-4 if Ralph overrode 2.7 defaults (2.7 OQ1/OQ2/OQ4).
- [x] **T1 — Extend the wire schema** (AC: 1, 2, 3-schema, 13)
  - [x] Edit `schemas/envelope.fbs`: add `Operation` + `OpLog` tables; **append** `OpLog` to `union Payload`; tick the roadmap comment (line 36). Run `cargo make codegen` (pass 1).
- [x] **T2 — `op_log.rs`: builder + wrapper + error mapping** (AC: 5, 6, 7, 8, 9, 10, 11, 12)
  - [x] Create `crates/zanshin-ffi/src/op_log.rs` (SPDX MIT line 1) + add `pub mod op_log;` to `lib.rs`. Implement `op_log_to_envelope` (list-of-tables, mirror `status_to_envelope`), `map_op_log_err` (single arm → `jj.jj_lib_error`), and `zanshin_op_log` (catch-wrapped, borrow handle, `usize::try_from(limit).ok()` sentinel). **No `envelope.rs` / `docs/rust-error-codes.md` change** (AC-12).
- [x] **T3 — Regenerate the FFI surface** (AC: 13)
  - [x] Run `cargo make codegen` (pass 2) after the new extern symbol; confirm `zanshin_op_log` in `zanshin_ffi.h` + `bindings.dart`; commit all five artifacts. Never hand-edit generated files.
- [x] **T4 — Rust tests** (AC: 14, 15, 16, 17)
  - [x] Builder unit test (every field; root + non-root + multi-parent ops) + `map_op_log_err` test in `op_log.rs`; `crates/zanshin-ffi/tests/op_log_ffi.rs` (valid round-trip, limit, invalid handle; no null/utf8 tests).
- [x] **T5 — Dart bridge** (AC: 18, 19, 20, 21, 22)
  - [x] `OpLogCommand` in `commands.dart`; dispatch `case` + `opLog()` main-side method + import alias (alphabetical!) in `isolate.dart`; `ffi/op_log.dart` (adapter + `Operation` model + decode pair); `RepoHandle.opLog()` + `show Operation` import in `handle.dart`. All under `packages/zanshin_core/`.
- [x] **T6 — Dart tests** (AC: 23, 24)
  - [x] `test/worker/op_log_test.dart` (real-cdylib round-trip, oracle EQUALITY, closed-handle, StateError) + `test/ffi/op_log_test.dart` (decode-contract synthetic). Under `packages/zanshin_core/test/`.
- [x] **T7 — Coverage** (AC: 25)
  - [x] Confirm `op_log.rs` (ffi) clears the floor (target 100 %); commit the auto-raised `coverage-baseline.txt`.
- [x] **T8 — Gate** (AC: 25, 26)
  - [x] `cargo make test` green end-to-end (Rust + Dart + deny + coverage); clippy pedantic; fmt; `dart analyze`/`format` clean; SPDX on new files.

## Dev Notes

### What you build on — exact, verified signatures (reuse, do not re-add)

From `crates/zanshin-ffi/src/` (all `done`, verified live):
- `envelope::catch<F: FnOnce() -> Result<Vec<u8>, FfiErrorObj>>(f) -> Vec<u8>` — the panic backstop wrapping every wrapper body (→ `internal.panic` on panic).
- `envelope::FfiErrorObj { pub code: String, pub context: Option<String> }`; consts `FFI_INVALID_HANDLE` (`ffi.invalid_handle`), `JJ_JJ_LIB_ERROR` (`jj.jj_lib_error`) — both re-exported at the crate root via `pub use envelope::*;` (lib.rs:29-30).
- `handle::handle_from_raw::<Repo>(ptr: *mut Repo) -> Option<&mut Repo>` — borrows (does NOT drop) the boxed `Repo`.
- `ffi_strings::{vec_into_token(Vec<u8>) -> *mut ZanshinBuf, ZanshinBuf, zanshin_buffer_free_token}`.
- `crate::fbs` = `pub use envelope_generated::zanshin::ffi as fbs;` (lib.rs:27) — the alias every wrapper uses for generated types.
- The list-of-tables builder template is **`status.rs:40-92`** (`status_to_envelope`, builds a `[FileChange]` vector) — op_log's `[Operation]` builder mirrors it exactly.

### The `zanshin_op_log` wrapper (sketch — mirror `zanshin_status`, status.rs:112-126)

```rust
// SPDX-License-Identifier: MIT

//! `zanshin_op_log` — operation-log read FFI wrapper (Story 3.4b, op_log slice).
//!
//! Calls `zanshin_jj::Repo::op_log(limit)` and serialises the result into a
//! `FlatBuffers` `Envelope` carrying an `OpLog` payload. The handle is borrowed
//! (not consumed). `limit` is a fixed scalar (negative ⇒ all).

use flatbuffers::FlatBufferBuilder;
use tracing::debug;
use zanshin_jj::{OpLogError, Operation, Repo};

use crate::envelope::{catch, FfiErrorObj, FFI_INVALID_HANDLE, JJ_JJ_LIB_ERROR};
use crate::fbs;
use crate::ffi_strings::{vec_into_token, ZanshinBuf};
use crate::handle::handle_from_raw;

fn map_op_log_err(e: OpLogError) -> FfiErrorObj {
    match e {
        OpLogError::Backend(reason) => FfiErrorObj {
            code: JJ_JJ_LIB_ERROR.to_owned(),
            context: Some(reason),
        },
    }
}

/// Serialise `&[Operation]` into a finished `Envelope<OpLog>` buffer.
/// Children before parents: each `Operation`'s strings + `parent_ids` vector are
/// built before its table; the `operations` vector + `OpLog` table come after the loop.
fn op_log_to_envelope(ops: &[Operation]) -> Vec<u8> {
    let mut b = FlatBufferBuilder::with_capacity(1024);
    let mut op_offsets = Vec::with_capacity(ops.len());
    for op in ops {
        let id_off = b.create_string(&op.id.0);
        let parent_offs: Vec<_> = op.parent_ids.iter().map(|p| b.create_string(&p.0)).collect();
        let parents_vec = b.create_vector(&parent_offs);
        let user_off = b.create_string(&op.user);
        let host_off = b.create_string(&op.host);
        let desc_off = b.create_string(&op.description);
        let op_off = fbs::Operation::create(
            &mut b,
            &fbs::OperationArgs {
                id: Some(id_off),
                parent_ids: Some(parents_vec),
                timestamp_millis: op.timestamp.millis_since_epoch,
                tz_offset_minutes: op.timestamp.tz_offset_minutes,
                user: Some(user_off),
                host: Some(host_off),
                description: Some(desc_off),
                root_op: op.root_op,
                is_snapshot: op.is_snapshot,
            },
        );
        op_offsets.push(op_off);
    }
    let ops_vec = b.create_vector(&op_offsets);
    let oplog_off = fbs::OpLog::create(&mut b, &fbs::OpLogArgs { operations: Some(ops_vec) });
    let envelope = fbs::Envelope::create(
        &mut b,
        &fbs::EnvelopeArgs {
            ok: true,
            error: None,
            data_type: fbs::Payload::OpLog,
            data: Some(oplog_off.as_union_value()),
        },
    );
    b.finish(envelope, None);
    b.finished_data().to_vec()
}

/// Read the operation log of the repo identified by `handle`.
///
/// `limit < 0` ⇒ all; `limit >= 0` ⇒ at most `limit` most-recent ops.
///
/// # Errors
/// - `ffi.invalid_handle` — `handle` is `0` or the borrow yields `None`.
/// - `jj.jj_lib_error` — an unclassified jj-lib error; detail in `context`.
///
/// # Safety
/// `handle` must be a value returned by a successful `zanshin_repo_open`/`_init`/`_clone`
/// that has not been closed. `0` is detected and returned as `ffi.invalid_handle`.
/// The returned token must be freed exactly once via `zanshin_buffer_free_token`.
#[no_mangle]
pub unsafe extern "C" fn zanshin_op_log(handle: u64, limit: i64) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_op_log", handle, limit);
    let buf = catch(|| {
        // SAFETY: non-zero handle originated from handle_into_raw (Box<Repo>);
        // single-isolate model (AD-2) guarantees no concurrent access.
        let repo = unsafe { handle_from_raw::<Repo>(handle as *mut Repo) }.ok_or_else(|| FfiErrorObj {
            code: FFI_INVALID_HANDLE.to_owned(),
            context: None,
        })?;
        // limit < 0 ⇒ None (all); 0 ⇒ Some(0); n ⇒ Some(n). No `as` cast (clippy-clean).
        let ops = repo.op_log(usize::try_from(limit).ok()).map_err(map_op_log_err)?;
        Ok(op_log_to_envelope(&ops))
    });
    vec_into_token(buf)
}
```

### Where the mapping lives — `op_log.rs`, not `envelope.rs`

Keep the domain mapping in the **noun module** (`crates/zanshin-ffi/src/op_log.rs`), exactly as the
`status`/`change` slices put it in their noun modules (status OQ#2 resolved). `envelope.rs`'s builders take
only primitives / `FfiErrorObj` and never import a `zanshin-jj` domain type. So this slice adds **no**
function to `envelope.rs`, and (per AC-12) **no** new error const.

### Dart seam — VERIFIED live source (paths = `packages/zanshin_core/...`)

- **Command** (`worker/commands.dart`): mirror `GetChangeCommand` but with `int limit` instead of `String changeId`:
  ```dart
  final class OpLogCommand extends WorkerCommand {
    const OpLogCommand({required super.commandId, required this.handleId, required this.limit});
    final int handleId; // opaque dense id (NOT a raw pointer)
    final int limit;    // < 0 = all; otherwise max ops (most recent)
  }
  ```
- **Worker dispatch** (`worker/isolate.dart`): mirror the `GetChangeCommand` case — `final int? raw = handles[handleId];` (**lookup, never remove**); unknown → `fbs.EnvelopeObjectBuilder(ok: false, error: fbs.FfiErrorObjectBuilder(code: 'ffi.invalid_handle', context: 'unknown or closed handleId: $handleId')).toBytes()`; else `responseSP.send((commandId, BufferResult(repo_ffi_op_log.zanshinOpLog(raw, limit))))`. Add `import '../ffi/op_log.dart' as repo_ffi_op_log;` in **alphabetical** position (the change slice's Debug Log recorded a `directives_ordering` fix here).
- **Main-side `ZanshinWorker.opLog`** (`worker/isolate.dart`, mirror `getChange`):
  ```dart
  Future<List<Operation>> opLog(int handleId, int limit) async {
    final Uint8List bytes = await send(
      OpLogCommand(commandId: _correlator.allocateId(), handleId: handleId, limit: limit),
    );
    return repo_ffi_op_log.decodeOpLogEnvelopeInternal(bytes);
  }
  ```
  Doc-note: the close-guard `StateError` is delivered **synchronously by `RepoHandle.opLog`**, not by this `async` method (change-Patch#4 wording learning).
- **FFI adapter + decode** (`ffi/op_log.dart`, NEW — mirror `status.dart`, no CString marshalling):
  ```dart
  Uint8List zanshinOpLog(int rawHandle, int limit) {
    final ffi.Pointer<ZanshinBuf> token = zanshin_op_log(rawHandle, limit);
    final buf = FfiBuffer.fromToken(token);
    try {
      return Uint8List.fromList(buf.bytes);
    } finally {
      buf.dispose();
    }
  }

  List<Operation> _decodeOpLogEnvelope(Uint8List bytes) {
    final env = fbs.Envelope(bytes);
    if (!env.ok) {
      final fbs.FfiError? e = env.error;
      throw ZanshinFfiException(e?.code ?? 'ffi.unknown', e?.context);
    }
    final Object? payload = env.data;
    if (payload is! fbs.OpLog) {
      throw ZanshinFfiException('ffi.unknown', 'expected OpLog payload, got ${env.dataType}');
    }
    return payload.operations?.map(_mapOperation).toList() ?? const [];
  }
  ```
  `ZanshinFfiException` comes from `'../worker/responses.dart'`; `@visibleForTesting` from `package:meta/meta.dart`. `_mapOperation(fbs.Operation o)` builds the Dart `Operation` model.
- **`RepoHandle.opLog`** (`worker/handle.dart`, mirror `getChange`'s synchronous `_closed` guard):
  ```dart
  Future<List<Operation>> opLog({int limit = -1}) {
    if (_closed) {
      throw StateError('RepoHandle is already closed');
    }
    return _worker.opLog(_handleId, limit);
  }
  ```
  Add `import '../ffi/op_log.dart' show Operation;`.
- **Model-A handle map** (`isolate.dart`, `final Map<int, int> handles`): op_log does a **lookup** only, never `handles.remove`. No change to the map.

### Testing standards (project-context Testing Rules) — the F20 oracle-equality rule

**The most important learning to carry forward** (change Review-Patch #1): the Dart worker round-trip must
assert **EQUALITY against an oracle**, **never** `isNotNull`/`isNotEmpty` on non-nullable fields (vacuously
true). For op_log: the root op's `parentIds` is **`isEmpty`** AND `rootOp == true` (not merely "present");
`operations.length == 1` for `limit: 1`; the first op's `user`/`host` are non-empty and equal an
independent jj-lib oracle read (NOT a hard-coded literal); ops are in reverse-chronological order (compare
timestamps). The decode-
contract test value-checks every decoded field against the synthetic-builder input. Cross-FFI coverage:
`cargo make coverage` unions the instrumented cdylib path (exercised by the Dart worker round-trip) with
cargo tests — the live `op_log.rs` reached through `flutter test` counts toward the per-file floor.

### Hard guardrails (reject-on-sight at review)

- **NO JSON on the FFI wire**, no alternative envelope shape — composite data is the FlatBuffers `Envelope`; `limit` is a plain scalar; there is no string arg.
- **NEVER reorder the `Payload` union** — append only (positional tags).
- **NEVER hand-edit generated files**; regenerate via `cargo make codegen` (twice) and commit.
- **NO new `extern "C"` outside `zanshin-ffi`**; the repo handle is borrowed, single-threaded (AD-2) — no `Arc<Mutex<T>>`.
- **NO new error code** unless 2.7 ships a non-`Backend` `OpLogError` variant (it should not).
- **SPDX line 1** on every new `.rs`/`.dart`; every `unsafe` block a `// SAFETY:`; the `extern "C"` fn a `# Safety` doc.
- **NO coverage-baseline lowering / no `exclude_prefix`** to dodge testing.
- **Dart paths are `packages/zanshin_core/...`**, NOT `app/lib/src/...` (see PATH CORRECTION).

### Project Structure Notes

The op_log FFI wrapper is a per-noun module `crates/zanshin-ffi/src/op_log.rs` (mirroring the live
`status.rs`/`change.rs`), wired via `pub mod op_log;` in `lib.rs`. The Dart seam lives entirely in
`packages/zanshin_core/` (the pure-Dart bridge under coverage per CLAUDE.md), not `app/`. The schema is the
single combined `schemas/envelope.fbs` (NOT a separate `op_log.fbs`, despite architecture.md:526 listing
one — the live tree uses one combined file).

### References

- [Source: epics.md#Story 3.4b (lines 2147-2249)] — superseded JSON prose; the two FlatBuffers reconciliation banners at lines 2151,2153 are binding.
- [Source: docs/adr/0001-ffi-data-transport-flatbuffers.md] — FlatBuffers transport; `OpLog` listed as a Payload member (line 37).
- [Source: docs/adr/0002-…-reload-per-operation.md] — re-resolve to head per call.
- [Source: docs/rust-error-codes.md:33-58] — the code registry + "Adding a New Code" process (NOT triggered here — AC-12).
- [Source: schemas/envelope.fbs:32-39,76-81,102-128] — roadmap comment, `Signature` timestamp convention, the `Payload` union + `Envelope` to extend.
- [Source: crates/zanshin-ffi/src/status.rs:40-126,146-244] — the handle-only wrapper + list-of-tables builder + `map_*_err` test template.
- [Source: crates/zanshin-ffi/src/change.rs] — the lone-string-arg variant (NOT mirrored; op_log has no string arg) + the children-before-parents nested build.
- [Source: crates/zanshin-ffi/tests/change_ffi.rs] — the integration-test harness to mirror.
- [Source: packages/zanshin_core/lib/src/{ffi/{change,status}.dart, worker/{commands,isolate,handle,responses}.dart}] — the Dart seam to mirror.
- [Source: packages/zanshin_core/test/{worker,ffi}/change_test.dart] — the two Dart test templates.
- [Source: 3-4b-zanshin-status-ffi-wrapper.md, 3-4b-zanshin-change-ffi-wrapper.md] — the binding `done` slice templates (translate their `app/lib/...` paths → `packages/zanshin_core/...`).
- [Source: 2-7-implement-op-log-rs-operation-log-read.md] — the upstream domain type (`Operation`, `OperationId`, `OpLogError`) this wrapper exposes.
- [Source: coverage-baseline.txt] — `new_file_floor_pct = 80.00`; sibling `change.rs = 100.00`, `status.rs = 100.00`, `envelope.rs = 100.00`.

## Dev Agent Record

### Agent Model Used

claude-sonnet-4-6

### Debug Log References

- `TempDir` lifetime: initial FFI integration test helper returned `(u64, Vec<u8>)` dropping the `TempDir` early, corrupting the on-disk fixture. Fixed by binding `fixture` as a named local in each test scope.
- `directives_ordering` lint in `isolate.dart`: `import '../ffi/op_log.dart' as repo_ffi_op_log;` must be alphabetically between `log_forwarder.dart` and `repo.dart`.
- Clippy `doc_markdown`: `op_log` and `FlatBuffers` in module-level `//!` comments needed backtick-wrapping; `CString` too.
- Clippy `too_many_arguments` on the 9-argument `make_op` test helper in `op_log.rs` unit tests — suppressed with `#[allow(clippy::too_many_arguments)]` (test-only scaffolding).
- `rustfmt` moved `pub mod op_log;` in `lib.rs` to alphabetical position (after `handle`/`logging`).

### Completion Notes List

- `op_log_to_envelope_roundtrips_all_fields` exercises root + non-root + multi-parent ops with every field asserted by equality.
- FFI integration tests: 3 tests — valid round-trip (all ops), limit-1, zero-handle. No null/UTF-8 tests (no `CString` arg).
- Dart decode-contract tests: 4 tests — error envelope, wrong-payload type, 2-op log, 3-op log with multi-parent + snapshot. Every field equality-asserted.
- Dart worker round-trip tests: 5 tests — full log (root-op-last, non-root assertions), limit-1, oracle equality (head id stable across two calls), reverse-chronological ordering, closed-handle ffi.invalid_handle.
- Dart closed-handle guard: 1 test — `StateError` thrown synchronously before reaching the worker.
- Coverage: `crates/zanshin-ffi/src/op_log.rs` raised from 90.98% → **100%** by the Dart cdylib round-trip tests. Baseline auto-raised and committed.

### File List

- `schemas/envelope.fbs` (MODIFIED — added `Operation`, `OpLog` tables; appended `OpLog` to `Payload` union)
- `crates/zanshin-ffi/src/op_log.rs` (NEW)
- `crates/zanshin-ffi/src/lib.rs` (MODIFIED)
- `crates/zanshin-ffi/tests/op_log_ffi.rs` (NEW)
- `crates/zanshin-ffi/include/zanshin_ffi.h` (MODIFIED — codegen)
- `crates/zanshin-ffi/src/envelope_generated.rs` (MODIFIED — codegen)
- `packages/zanshin_core/lib/src/ffi/envelope_zanshin.ffi_generated.dart` (MODIFIED — codegen)
- `packages/zanshin_core/lib/src/ffi/bindings.dart` (MODIFIED — codegen)
- `packages/zanshin_core/lib/src/ffi/op_log.dart` (NEW)
- `packages/zanshin_core/lib/src/worker/commands.dart` (MODIFIED)
- `packages/zanshin_core/lib/src/worker/isolate.dart` (MODIFIED)
- `packages/zanshin_core/lib/src/worker/handle.dart` (MODIFIED)
- `packages/zanshin_core/test/ffi/op_log_test.dart` (NEW)
- `packages/zanshin_core/test/worker/op_log_test.dart` (NEW)
- `coverage-baseline.txt` (MODIFIED — auto-raised)

### Change Log

| Datum | Änderung |
|-------|----------|
| 2026-06-24 | create-story: comprehensive context engineered (mirrors the done status/change slices; scalar-`limit` + no-new-code + `packages/zanshin_core` path reconciliations; FlatBuffers wire derived from the 2.7 domain type). Status → ready-for-dev (HARD-GATED on 2.7 `done`). |
| 2026-06-24 | dev-story: FlatBuffers schema extended; `zanshin_op_log` FFI wrapper; full Dart bridge (`OpLogCommand`, `ZanshinWorker.opLog`, `RepoHandle.opLog`, `ffi/op_log.dart`); Dart + Rust tests (13 tests total). `cargo make test` green; `op_log.rs` ffi coverage 100%. Status → review. |

## Open Questions for Ralph (non-blocking — defaults chosen, override before dev if desired)

1. **OQ1 — `limit` sentinel (default = `i64`, `< 0` ⇒ all).** Maps the whole `Option<usize>` domain via `usize::try_from(limit).ok()`: `-1` (any negative) ⇒ `None`/all; `0` ⇒ `Some(0)`/empty; `n` ⇒ `Some(n)`. The Dart `RepoHandle.opLog` defaults `limit = -1`. Override to a `u64`-with-`0`-means-all encoding if you prefer (loses the legitimate "0 ops" request).
2. **OQ2 — No new error code (default = reuse `jj.jj_lib_error`).** op_log can't "not find"; its only failure is `OpLogError::Backend` → `jj.jj_lib_error`. Override only if 2.7 ships a distinct `OpLogError` variant warranting a new `jj.*` code (then add the `envelope.rs` const + registry row).
3. **OQ3 — `OpLog` payload table name (default = `OpLog { operations: [Operation] }`).** A wrapping list table (not `Operation` directly in the union — the payload is the list). Confirm the name `OpLog` vs. `Operations`.
4. **OQ4 — Dart return type (default = `List<Operation>`).** `RepoHandle.opLog()` returns `Future<List<Operation>>` directly (no `OpLog` Dart wrapper class). Override if you want a wrapper carrying e.g. a `truncated` flag.
5. **OQ5 — `is_snapshot` on the wire (default = include, tracks 2.7 OQ4).** If 2.7 drops `is_snapshot`, drop the `Operation.is_snapshot` field here too (the wire mirrors the domain type).
