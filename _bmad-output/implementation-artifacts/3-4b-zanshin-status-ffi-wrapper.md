# Story 3.4b — `zanshin_status` FFI wrapper + Dart status seam (status slice)

---
baseline_commit: 48a0c5194a4de931f8794d2e6d48f6f4ce2543bb
---

Status: done

<!-- Note: Validation is optional. Run validate-create-story for quality check before dev-story. -->

> **This is the `status` slice of Story 3.4b.** Per the 2026-06-15 WIP re-sequencing
> (sprint-status.yaml:122-131), Story 3.4b is not one monolith — it lands one thin read-path
> wrapper **per finished Epic-2 noun**, each made "aus Flutter testbar" the moment its jj-lib
> noun is `done`:
>
> | Epic-2 noun (source) | 3.4b slice            | gate |
> |----------------------|-----------------------|------|
> | **2.4 `status` ✅ done** | **`zanshin_status` (THIS story)** | unblocked now |
> | 2.6 `change`         | `zanshin_change`      | 2.6 backlog |
> | 2.7 `op_log`         | `zanshin_op_log`      | 2.7 backlog |
> | 2.8 `bookmarks`      | `zanshin_bookmarks`   | 2.8 backlog |
> | 2.9 `remotes`        | `zanshin_remotes`     | 2.9 backlog |
>
> Only `status` is buildable today (2.4 is `done`; 2.6-2.9 are `backlog`). **Stay in this slice** —
> do **not** pre-build the other four nouns.

---

## ⚠️ CRITICAL — Read this before writing any code (spec reconciliation)

The Story 3.4b acceptance criteria in `epics.md` (lines 2147-2249) are **stale on three axes** and are
superseded here. Treat the ACs in *this* file as the binding contract, not the epic prose:

1. **Transport is FlatBuffers, not JSON (ADR-0001).** The epic text says `zanshin_status` "returns a
   JSON envelope with `data = Status` serialized" and routes errors through
   `internal.serialization_failed`. **All superseded.** Composite FFI data crosses as a FlatBuffers
   `Envelope` token (`*mut ZanshinBuf`); there is no JSON, no `serde::Serialize` on `Status`, no
   `jsonschema`. The committed code (Stories 3-0…3-4a, 3-8) already implements the FlatBuffers
   `Envelope`; this slice **adds one `Payload` member** and consumes the existing infrastructure.
   [Source: docs/adr/0001; project-context.md `overrides:`; the committed `schemas/envelope.fbs`]

2. **The `zanshin_repo_*` ACs in the epic are owned by Story 3.4a (`done`).** The epic's 3.4b text still
   carries `zanshin_repo_open/init/clone/close` signatures — ignore them entirely; 3.4a shipped those.
   This slice adds **one new function**: `zanshin_status`.

3. **Handle is a `u64` integer, not a `*mut c_void`.** Per the committed 3.4a ABI, handles cross as a
   `ulong` (`RepoHandle.handle`); `zanshin_status` takes that `u64` back and **borrows** the `Repo`
   (it does *not* consume/close it). Null handle (`0`) → `ffi.invalid_handle`.

The newer sibling **Story 3.4a** (`3-4a-repo-ffi-wrappers-…md`, `done`) is the authoritative pattern for
the Rust side; **Story 3.8** (`zanshin_diagnostics`) is the authoritative pattern for a payload-returning
read; **Story 3.9** (`done`) pre-built the Dart worker seam *specifically for this story* (see the Dart
notes). Mirror them exactly.

---

## Scope (read once, then never widen)

**IN scope — the full Dart↔Rust bridge for `status`** (the bridge is in scope per
`feedback-scope-bridge-is-claudes-ui-is-ralphs`; only the Flutter UI is out):

- **Rust:** extend `schemas/envelope.fbs` (`Status`/`FileChange`/`ChangeKind` + `Payload` union); new
  `extern "C" zanshin_status(handle: u64) -> *mut ZanshinBuf` in a new `crates/zanshin-ffi/src/status.rs`;
  map `zanshin_jj::Status` → FlatBuffers; map `StatusError` → `error.code`; one new error code
  `jj.no_working_copy`; regenerate + commit all five codegen artifacts; Rust unit + integration tests.
- **Dart:** `StatusCommand` (worker command); the worker-isolate dispatch case; the `zanshinStatus`
  FFI adapter; main-side decode into a Dart `WorkingCopyStatus` model; `ZanshinWorker.status()` +
  `RepoHandle.status()`; Dart worker round-trip test against the **real cdylib** + a decode-contract
  unit test.

**OUT of scope:**

- Any Flutter widget / screen that *displays* status (Ralph's separate work).
- The other four 3.4b nouns (`change`, `op_log`, `bookmarks`, `remotes`) and `zanshin_revset_resolve`.
- The watcher (Stories 3.5/3.6) — `status` is a one-shot read; ADR-0002 re-resolves to head per call.
- Any `zanshin-jj` change — `Repo::status()` shipped in Story 2.4 (`done`). This slice only *exposes* it.

---

## Story

As the Dart worker isolate (and, behind it, Ralph's future Flutter UI),
I want an `extern "C" zanshin_status(handle)` wrapper that calls `zanshin_jj::Repo::status()` and returns
the working-copy status as a FlatBuffers `Envelope`, plus the Dart command/adapter/decode seam that turns
it into a typed `WorkingCopyStatus`,
so that the first read-path noun is callable end-to-end from Dart against a real repo — exercising the FFI
scaffolding (envelope, handle, token, worker bus) with real structured data.

---

## Acceptance Criteria

Grouped by deliverable. Each item is a checkable contract.

### AC-1 — wire schema: `Status` payload (`schemas/envelope.fbs`)

1. `schemas/envelope.fbs` gains, in `snake_case` (flatc emits `lowerCamelCase` getters):
   ```fbs
   /// How a working-copy file changed between @- and @.
   enum ChangeKind : byte { Added, Modified, Removed, Renamed, Copied }

   /// One changed file. `from_path` is set ONLY for Renamed/Copied (the source
   /// path); it is absent for Added/Modified/Removed.
   table FileChange {
     path: string;
     kind: ChangeKind;
     from_path: string;
   }

   /// Working-copy status: files changed between @ and @-, plus both change ids
   /// in jj's reverse-hex display form.
   table Status {
     files: [FileChange];
     working_copy_change_id: string;
     parent_change_id: string;
   }
   ```
   and `Status` is appended to the union: `union Payload { RepoHandle, Diagnostics, Status }`.
2. The `Status :` line in the schema's payload-roadmap comment (`schemas/envelope.fbs:36`) is updated to
   mark `status` ✓.

### AC-2 — `zanshin_jj::Status` → FlatBuffers mapping

3. A builder maps a `&zanshin_jj::Status` to a finished `Status`-payload `Envelope` `Vec<u8>`
   (recommended location `crates/zanshin-ffi/src/status.rs`; see Dev Notes "Where the mapping lives"):
   - each `FileChange.path` → `path` via `PathBuf::to_string_lossy()` (jj guarantees UTF-8, so lossless);
   - `ChangeKind` maps `Added/Modified/Removed/Renamed/Copied` → `fbs::ChangeKind::*`;
   - `from_path` is set **only** for `Renamed { from }` / `Copied { from }` (to `from.to_string_lossy()`);
     left **unset** (→ Dart `null`) otherwise;
   - `working_copy_change_id` / `parent_change_id` → the inner `ChangeId(String)` (`.0`).
4. The builder follows FlatBuffers "children before parents": create each `FileChange` (its strings, then
   the table) and collect offsets, **then** `create_vector`, **then** the two id strings, **then** the
   `Status` table, **then** the `Envelope`; finish with plain `b.finish(...)` (NOT size-prefixed — the
   length rides in `ZanshinBuf.len`, matching `ok_empty`/`ok_repo_handle`/`ok_diagnostics`).

### AC-3 — `zanshin_status` extern function

5. `crates/zanshin-ffi/src/status.rs` is created, declared `pub mod status;` in `lib.rs`, and defines
   ```rust
   #[no_mangle]
   pub unsafe extern "C" fn zanshin_status(handle: u64) -> *mut ZanshinBuf
   ```
   wrapped in `envelope::catch(|| { … })` so no panic crosses the C ABI, with a `debug!(fn_name =
   "zanshin_status", handle)` span.
6. On a valid, non-zero `handle`, it **borrows** the `Repo` via `handle::handle_from_raw::<Repo>(handle
   as *mut Repo)` (it does **not** drop/consume it), calls `repo.status()`, and returns the `Status`
   payload envelope from AC-2 with `ok == true`.
7. `handle == 0` (and any other case where `handle_from_raw` yields `None`) returns `ok:false` with
   `error.code == "ffi.invalid_handle"` — never a crash, never NULL. (This is the only *detectable*
   invalid handle; a stale non-zero handle is UB the Rust layer must not attempt to detect — AD-2, same
   contract as `zanshin_repo_close` AC-10. The Dart worker's Model-A table makes a stale handle
   unreachable anyway: it looks the id up, never re-passing a freed pointer.)
8. The returned `*mut ZanshinBuf` is produced by `ffi_strings::vec_into_token(buf)` and is freed by Dart
   exactly once via `zanshin_buffer_free_token` (the `FfiBuffer.fromToken` path).

### AC-4 — `StatusError` → `error.code` mapping + registry

9. A `map_status_err(StatusError) -> FfiErrorObj` (in `status.rs`) maps:
   - `StatusError::NoWorkingCopy` → **new** code `jj.no_working_copy` (context `None`);
   - `StatusError::Backend(s)` → existing `jj.jj_lib_error` (context `Some(s)`).
10. `crates/zanshin-ffi/src/envelope.rs` gains `pub const JJ_NO_WORKING_COPY: &str = "jj.no_working_copy";`
    (auto-re-exported at the crate root via `pub use envelope::*`) — the single-emission-point rule
    (AR-P-4): no `error.code` literal appears outside `envelope.rs`.
11. `docs/rust-error-codes.md` adds a row: `jj.no_working_copy | jj | The workspace has no working-copy
    commit (@). | Emitted — Story 3.4b (status) (envelope.rs::JJ_NO_WORKING_COPY, status.rs)`.

### AC-5 — codegen committed

12. `cargo make codegen` is run and **all five** regenerated artifacts are committed in the same PR:
    `schemas/envelope.fbs` (source), `crates/zanshin-ffi/src/envelope_generated.rs`,
    `app/lib/src/ffi/envelope_zanshin.ffi_generated.dart`, `crates/zanshin-ffi/include/zanshin_ffi.h`,
    `app/lib/src/ffi/bindings.dart`. The header/bindings contain `zanshin_status`; both generated
    accessor files expose `Status`, `FileChange`, `ChangeKind`. **Never hand-edit generated files.**

### AC-6 — Rust tests

13. **Builder unit test** (in `status.rs` `#[cfg(test)]`): construct a `zanshin_jj::Status` carrying one
    `FileChange` of **each** `ChangeKind` (Added, Modified, Removed, Renamed{from}, Copied{from}), build
    the envelope, parse it through the generated typed accessors + the FlatBuffers `Verifier`, and assert:
    `ok == true`, `data_type == Payload::Status`, `files().len() == 5`, each entry's `kind()` is correct,
    `from_path()` is `Some(src)` for Renamed/Copied and `None` for the others, and both change-id strings
    round-trip.
14. **Integration tests** in `crates/zanshin-ffi/tests/status_ffi.rs` (mirror `tests/repo_ffi.rs`'s
    `pin_env` / `read_and_free` / `parse_envelope` / `extract_fixture` harness; free every token; pin
    `JJ_CONFIG`/`GIT_CONFIG_GLOBAL`):
    - **clean round-trip:** `zanshin_repo_open` the `tiny-3-commits` fixture → read the `RepoHandle.handle`
      → `zanshin_status(handle)` → assert `ok`, `data_type == Status`, `files()` empty (len 0 / `None`),
      both change ids non-empty → `zanshin_repo_close(handle)`.
    - **invalid handle:** `zanshin_status(0)` → `ok:false`, `error.code == "ffi.invalid_handle"`.
15. No `jsonschema`, no hand-parsing of bytes; a wrong-shape payload must be a **compile** error, not a
    runtime assert. (Exhaustive Added/Modified/Removed/Renamed real-data computation is already covered by
    `zanshin-jj/tests/status.rs` — do not duplicate the jj-lib setup here; AC-13 covers the mapping.)

### AC-7 — Dart bridge (the seam Story 3.9 reserved for this story)

16. `app/lib/src/worker/commands.dart` gains a handle-taking `final class StatusCommand extends
    WorkerCommand { …; final int handleId; }` (carries only `commandId` + `handleId` — sendable).
17. The worker dispatch `switch (msg)` in `app/lib/src/worker/isolate.dart` gains a
    `case StatusCommand(:final int handleId):` that **looks up** `handles[handleId]` (read — **never**
    `handles.remove`), calls `repo_ffi.zanshinStatus(raw)`, and replies `BufferResult(bytes)`; an unknown
    `handleId` replies an `ffi.invalid_handle` envelope (reuse the `EnvelopeObjectBuilder` pattern already
    used by `CloseRepoCommand`). The sealed switch stays exhaustive (compile-time enforced).
18. `app/lib/src/ffi/status.dart` (NEW) defines:
    - `Uint8List zanshinStatus(int rawHandle)` — the FFI adapter, mirroring `zanshinRepoClose` (passes the
      raw `int` straight to `zanshin_status`; materialises no Dart `Pointer`); decodes the token via
      `FfiBuffer.fromToken`, copies to a heap `Uint8List`, disposes the buffer.
    - Dart models `WorkingCopyStatus { List<FileChange> files; String workingCopyChangeId; String
      parentChangeId; }`, `FileChange { String path; FileChangeKind kind; String? fromPath; }`,
      `enum FileChangeKind { added, modified, removed, renamed, copied }`.
    - `@visibleForTesting WorkingCopyStatus decodeStatusEnvelope(Uint8List bytes)` — mirrors
      `decodeDiagnosticsEnvelope`: throws `ZanshinFfiException(code, context)` on `!ok`; throws
      `ZanshinFfiException('ffi.unknown', …)` when the payload is not a `Status` (guard `dataType`/
      `data is! fbs.Status` before the cast); otherwise maps `fbs.Status` → `WorkingCopyStatus`.
19. `app/lib/src/worker/isolate.dart` gains a main-side `Future<WorkingCopyStatus> status(int handleId)`
    that sends `StatusCommand(commandId: _correlator.allocateId(), handleId: handleId)` via the existing
    public `send(...)` and returns `decodeStatusEnvelope(bytes)`. `app/lib/src/worker/handle.dart` gains
    `Future<WorkingCopyStatus> status() => _worker.status(_handleId);` (throwing `StateError` if the
    `RepoHandle` is already `_closed`, mirroring its `close()` guard intent).
20. No `dart:ffi` import leaks outside `app/lib/src/ffi/`; no Flutter widget code; the worker still owns
    every raw handle (Model A) — `status.dart`'s `zanshinStatus(int)` is called **only** from the worker
    isolate, exactly like `zanshinRepoClose`.

### AC-8 — Dart tests

21. `app/test/worker/zanshin_worker_test.dart` (or a new `app/test/worker/status_test.dart`) adds a
    **real-cdylib** round-trip (boots `ZanshinWorker.start()`, no mocks):
    - `initRepo(tempDir, backend: 0)` → `handle.status()` → assert `files` is empty and both change ids
      are non-empty;
    - status on a **closed** handle surfaces `ffi.invalid_handle`: close the handle, then call
      `worker.status(handle.handleId)` directly (bypassing the `RepoHandle` guard, the way the existing
      `worker_close_unknown_handle_id_returns_invalid_handle` test does) and expect
      `ZanshinFfiException(code: 'ffi.invalid_handle')`.
22. A decode-contract unit test (mirror `app/test/ffi/diagnostics_test.dart`) exercises
    `decodeStatusEnvelope` with synthetic FlatBuffers buffers built via the generated `*ObjectBuilder`s:
    an error envelope → throws `ZanshinFfiException`; a non-`Status` payload → `ffi.unknown`; a `Status`
    envelope with one of each `ChangeKind` → correct `FileChangeKind` + `fromPath` mapping.

### AC-9 — quality gate green

23. `cargo make test` passes end-to-end: `cargo clippy --workspace --all-targets -- -D warnings`
    (pedantic, **refactor — don't `#[allow]`**; any unavoidable suppression carries a `// WHY:`),
    `cargo fmt --all --check`, all Rust unit + integration tests, `cargo deny check advisories bans`,
    and the cargo-hygiene gate. The Dart suite (`flutter test`, invoked by `cargo make test`) is green,
    including the new worker + decode tests; `dart analyze` (`--fatal-infos --fatal-warnings`) and
    `dart format` are clean.
24. Every new hand-written `.rs`/`.dart` file starts with `// SPDX-License-Identifier: MIT` (generated
    files are exempt). No `unsafe` outside the documented `extern "C"` seam; every `unsafe` block carries
    a `// SAFETY:` and every `unsafe fn` a `# Safety` doc section. No new crate, no `Cargo.toml` dependency
    change (zanshin-ffi already depends on `zanshin-jj` + the `tempfile`/`test-helpers` dev-deps from 3.4a).

---

## Tasks / Subtasks

- [x] **T1 — Extend the wire schema** (AC: 1, 2, 12)
  - [x] Edit `schemas/envelope.fbs`: add `enum ChangeKind`, `table FileChange`, `table Status`; append
        `Status` to `union Payload`; tick the roadmap comment.
  - [x] Run `cargo make codegen`. Verify `envelope_generated.rs` exposes `Status`, `StatusArgs`,
        `FileChange`, `FileChangeArgs`, `ChangeKind`, `Payload::Status`, `Envelope::data_as_status()`; and
        the Dart `*.ffi_generated.dart` exposes the mirror accessors + `*ObjectBuilder`s.

- [x] **T2 — New error code** (AC: 10, 11)
  - [x] Add `pub const JJ_NO_WORKING_COPY` to `envelope.rs`. Add the registry row to
        `docs/rust-error-codes.md`.

- [x] **T3 — `status.rs`: mapping + wrapper + error mapping** (AC: 2, 3, 4, 5, 6, 7, 8, 9)
  - [x] Create `crates/zanshin-ffi/src/status.rs` (SPDX `MIT`). Add `pub mod status;` to `lib.rs`.
  - [x] Implement the `&zanshin_jj::Status → Vec<u8>` builder (children-before-parents).
  - [x] Implement `map_status_err` and `zanshin_status` (catch-wrapped; `handle_from_raw` borrow;
        `handle == 0`/`None` → `ffi.invalid_handle`; `debug!` span).

- [x] **T4 — Regenerate the FFI surface** (AC: 12)
  - [x] Run `cargo make codegen` again after the new `extern "C"` symbol. Confirm `zanshin_status` is in
        `zanshin_ffi.h` + `bindings.dart`. Commit all five artifacts in this PR.

- [x] **T5 — Rust tests** (AC: 13, 14, 15)
  - [x] Builder unit test (all five `ChangeKind`s) in `status.rs`.
  - [x] `crates/zanshin-ffi/tests/status_ffi.rs`: clean round-trip (tiny fixture) + `zanshin_status(0)`.

- [x] **T6 — Dart bridge** (AC: 16, 17, 18, 19, 20)
  - [x] `StatusCommand` in `commands.dart`.
  - [x] Worker dispatch case (lookup, not remove) + unknown-handle error reply in `isolate.dart`.
  - [x] `app/lib/src/ffi/status.dart`: `zanshinStatus`, models, `decodeStatusEnvelope`.
  - [x] `ZanshinWorker.status()` (`isolate.dart`) + `RepoHandle.status()` (`handle.dart`).

- [x] **T7 — Dart tests** (AC: 21, 22)
  - [x] Worker round-trip + closed-handle test (real cdylib).
  - [x] `decodeStatusEnvelope` synthetic-buffer unit test.

- [x] **T8 — Gate** (AC: 23, 24)
  - [x] `cargo make test` green (Rust + Dart). Clippy pedantic clean. fmt/format clean. cargo deny clean.
        SPDX on new files. Generated diffs reviewed.

---

## Dev Notes

### What you build on — exact, verified signatures

**`zanshin_jj::Status` (Story 2.4, `done`; `crates/zanshin-jj/src/status.rs`, re-exported from `lib.rs`):**
```rust
pub struct Status { pub files: Vec<FileChange>, pub working_copy_change_id: ChangeId, pub parent_change_id: ChangeId }
pub struct FileChange { pub path: PathBuf, pub kind: ChangeKind }
pub enum ChangeKind { Added, Modified, Removed, Renamed { from: PathBuf }, Copied { from: PathBuf } }
pub struct ChangeId(pub String);   // jj reverse-hex display form (`qpvuntsm`-style); inner field is `.0`
pub enum StatusError { NoWorkingCopy, Backend(String) }   // thiserror; Display = human reason

impl Repo { pub fn status(&self) -> Result<Status, StatusError>; }   // &self — borrow, do NOT consume
```
`Repo::status()` re-resolves to head per call (ADR-0002) and is read-only (no snapshot). All five
`ChangeKind` variants and both error variants are already tested in `zanshin-jj/tests/status.rs` — this
slice exposes them; it does **not** re-test the computation.

**`zanshin-ffi` infrastructure to reuse (do NOT reinvent — all shipped 3-0…3-4a, 3-8):**
```rust
// envelope.rs  — generic builders, all return finished Vec<u8>; plain b.finish (NOT size-prefixed)
pub fn ok_empty() -> Vec<u8>;
pub fn err(code: &str, context: Option<&str>) -> Vec<u8>;
pub fn catch<F: FnOnce() -> Result<Vec<u8>, FfiErrorObj> + UnwindSafe>(f: F) -> Vec<u8>;
pub struct FfiErrorObj { pub code: String, pub context: Option<String> }
pub const FFI_INVALID_HANDLE; JJ_JJ_LIB_ERROR;  // &str consts (+ add JJ_NO_WORKING_COPY here)

// handle.rs  — AD-2 raw-Box helpers
pub unsafe fn handle_from_raw<'a, T>(ptr: *mut T) -> Option<&'a mut T>;   // null → None; USE for the borrow
//  (handle_drop is for close only — NOT here; status borrows, never drops)

// ffi_strings.rs
pub fn vec_into_token(buf: Vec<u8>) -> *mut ZanshinBuf;                   // USE for the return value
#[repr(C)] pub struct ZanshinBuf { pub ptr: *mut u8, pub len: usize }
pub unsafe extern "C" fn zanshin_buffer_free_token(token: *mut ZanshinBuf);

// lib.rs — `pub use envelope::*;` auto-re-exports every const + builder at the crate root.
//          `pub use envelope_generated::zanshin::ffi as fbs;` is the typed-accessor alias.
```

### The `zanshin_status` wrapper (sketch — mirror `zanshin_repo_close` + `zanshin_diagnostics`)

```rust
// crates/zanshin-ffi/src/status.rs
use tracing::debug;
use zanshin_jj::{Repo, StatusError};
use crate::envelope::{catch, FfiErrorObj, FFI_INVALID_HANDLE, JJ_JJ_LIB_ERROR, JJ_NO_WORKING_COPY};
use crate::ffi_strings::{vec_into_token, ZanshinBuf};
use crate::handle::handle_from_raw;

fn map_status_err(e: StatusError) -> FfiErrorObj {
    match e {
        StatusError::NoWorkingCopy => FfiErrorObj { code: JJ_NO_WORKING_COPY.to_owned(), context: None },
        StatusError::Backend(reason) => FfiErrorObj { code: JJ_JJ_LIB_ERROR.to_owned(), context: Some(reason) },
    }
}

/// Read the working-copy status of the repo identified by `handle`.
/// # Safety
/// `handle` must be a value returned by a successful `zanshin_repo_open/init/clone`
/// that has not been closed. `0` is detected and returned as `ffi.invalid_handle`.
/// The returned token must be freed exactly once via `zanshin_buffer_free_token`.
#[no_mangle]
pub unsafe extern "C" fn zanshin_status(handle: u64) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_status", handle);
    let buf = catch(|| {
        // SAFETY: non-zero handle originated from handle_into_raw (Box<Repo>); single isolate (AD-2).
        let repo = unsafe { handle_from_raw::<Repo>(handle as *mut Repo) }
            .ok_or_else(|| FfiErrorObj { code: FFI_INVALID_HANDLE.to_owned(), context: None })?;
        let status = repo.status().map_err(map_status_err)?;
        Ok(status_to_envelope(&status))
    });
    vec_into_token(buf)
}
```
`handle_from_raw(0 as *mut Repo)` is `None` (null → None), so the `handle == 0` case falls straight into
`ffi.invalid_handle` — no separate guard needed (but an explicit `if handle == 0` mirroring
`zanshin_repo_close` is equally acceptable). **Borrow only** — there is no `handle_drop` here.

### The `Status` builder (sketch — children before parents; plain `b.finish`)

```rust
use crate::fbs;
use flatbuffers::FlatBufferBuilder;
use zanshin_jj::{ChangeKind, Status};

fn status_to_envelope(status: &Status) -> Vec<u8> {
    let mut b = FlatBufferBuilder::with_capacity(1024);

    // 1) Build each FileChange table (strings first, then the table); collect offsets.
    let mut file_offsets = Vec::with_capacity(status.files.len());
    for fc in &status.files {
        let path_off = b.create_string(&fc.path.to_string_lossy());
        let (kind, from_off) = match &fc.kind {
            ChangeKind::Added    => (fbs::ChangeKind::Added,    None),
            ChangeKind::Modified => (fbs::ChangeKind::Modified, None),
            ChangeKind::Removed  => (fbs::ChangeKind::Removed,  None),
            ChangeKind::Renamed { from } => (fbs::ChangeKind::Renamed, Some(b.create_string(&from.to_string_lossy()))),
            ChangeKind::Copied  { from } => (fbs::ChangeKind::Copied,  Some(b.create_string(&from.to_string_lossy()))),
        };
        let fc_off = fbs::FileChange::create(&mut b, &fbs::FileChangeArgs {
            path: Some(path_off), kind, from_path: from_off,
        });
        file_offsets.push(fc_off);
    }
    // 2) Vector, 3) the two id strings, 4) the Status table — all AFTER the children above.
    let files_vec = b.create_vector(&file_offsets);
    let wc_off = b.create_string(&status.working_copy_change_id.0);
    let parent_off = b.create_string(&status.parent_change_id.0);
    let status_off = fbs::Status::create(&mut b, &fbs::StatusArgs {
        files: Some(files_vec),
        working_copy_change_id: Some(wc_off),
        parent_change_id: Some(parent_off),
    });
    // 5) Envelope.
    let env = fbs::Envelope::create(&mut b, &fbs::EnvelopeArgs {
        ok: true, error: None, data_type: fbs::Payload::Status, data: Some(status_off.as_union_value()),
    });
    b.finish(env, None);             // plain finish — length rides in ZanshinBuf.len
    b.finished_data().to_vec()
}
```
**FlatBuffers gotcha:** you may not start the `Status` table (or the `files` vector) while a child table is
still "open". The loop above closes each `FileChange` before pushing its offset, and builds the vector +
ids only after the loop — correct. Generated `fbs::ChangeKind::Added` etc. live in the same `fbs` alias;
they do **not** collide with `zanshin_jj::ChangeKind` (different paths).

### Where the mapping lives — `status.rs`, not `envelope.rs` (decided; see OQ#2)

`envelope.rs`'s builders (`ok_empty`, `ok_repo_handle(u64)`, `ok_diagnostics(&str,&str,&str)`, `err`) all
take **primitives / `FfiErrorObj`** — `envelope.rs` has never imported a `zanshin-jj` domain type. The
`Status` mapping is genuinely domain-aware (nested list, enum-with-data), and the four remaining 3.4b nouns
will each bring their own domain types. Keeping each noun's mapping in its **noun module** (`status.rs`,
later `change.rs`, …) scales; threading every domain type through `envelope.rs` does not. So `status.rs`
builds the full envelope using `crate::fbs` + `FlatBufferBuilder` directly. (Symmetry-with-`ok_diagnostics`
is the counter-argument — flagged as OQ#2, non-blocking.)

### Dart seam — Story 3.9 reserved this exact slot

The worker (`done`, Story 3.9) was built **anticipating this story**. Use the seams as-is:
- `responses.dart` `BufferResult` is documented "for read-payload responses from **Story-3.4b read
  commands**." Read replies use it verbatim.
- `isolate.dart` already has the public `Future<Uint8List> send(WorkerCommand cmd)` — "Generic path for
  **read commands (Story 3.4b)**." `ZanshinWorker.status()` calls it.
- `handle.dart`'s `RepoHandle` doc literally names the target: "3.4b read commands pass this to
  `ZanshinWorker.send` … e.g. `StatusCommand(commandId: id, handleId: handleId)`."

Sketches (mirror the diagnostics decode + the close dispatch):

```dart
// worker/commands.dart
final class StatusCommand extends WorkerCommand {
  const StatusCommand({required super.commandId, required this.handleId});
  final int handleId;   // worker-side dense id (NOT the raw pointer)
}

// worker/isolate.dart — inside the dispatch switch (LOOKUP, never remove):
case StatusCommand(:final int handleId):
  final int? raw = handles[handleId];
  if (raw == null) {
    final Uint8List errorBytes = fbs.EnvelopeObjectBuilder(
      ok: false,
      error: fbs.FfiErrorObjectBuilder(code: 'ffi.invalid_handle', context: 'unknown or closed handleId: $handleId'),
    ).toBytes();
    responseSP.send((commandId, BufferResult(errorBytes)));
  } else {
    responseSP.send((commandId, BufferResult(repo_ffi_status.zanshinStatus(raw))));
  }

// worker/isolate.dart — main side, next to openRepo/closeRepo:
Future<WorkingCopyStatus> status(int handleId) async {
  final Uint8List bytes = await send(StatusCommand(commandId: _correlator.allocateId(), handleId: handleId));
  return decodeStatusEnvelope(bytes);
}
```

```dart
// ffi/status.dart  (mirror ffi/repo.dart's zanshinRepoClose + ffi/diagnostics.dart's decode)
Uint8List zanshinStatus(int rawHandle) {
  final ffi.Pointer<ZanshinBuf> token = zanshin_status(rawHandle);
  final buf = FfiBuffer.fromToken(token);
  try { return Uint8List.fromList(buf.bytes); } finally { buf.dispose(); }
}

@visibleForTesting
WorkingCopyStatus decodeStatusEnvelope(Uint8List bytes) {
  final env = fbs.Envelope(bytes);
  if (!env.ok) {
    final fbs.FfiError? e = env.error;
    throw ZanshinFfiException(e?.code ?? 'ffi.unknown', e?.context);
  }
  final Object? payload = env.data;
  if (payload is! fbs.Status) {
    throw ZanshinFfiException('ffi.unknown', 'expected Status payload, got ${env.dataType}');
  }
  return WorkingCopyStatus(/* map payload.files / .workingCopyChangeId / .parentChangeId */);
}
```
Map generated `fbs.ChangeKind` → `FileChangeKind`; generated `FileChange.fromPath` is `null` when unset
(Added/Modified/Removed). Decode runs on the **main** isolate (the worker forwards raw bytes), exactly like
`Diagnostics`. **Import naming:** alias the `ffi/status.dart` import in `isolate.dart` (e.g.
`repo_ffi_status`) — `isolate.dart` already aliases `ffi/repo.dart` as `repo_ffi`.

### Testing standards (project-context Testing Rules)

- **Rust integration:** copy the `tests/repo_ffi.rs` harness top (the `ENV_GUARD`/`pin_env`,
  `read_and_free`, `parse_envelope`, `cstr`, `extract_fixture` helpers). The `tiny-3-commits` fixture's
  `@` is on the **root commit** (Story 2.3 AC-22) → diff vs `@-` is empty → `files` is empty but both
  change ids populate. Free every token (`zanshin_buffer_free_token`). No network.
- **Dart:** the worker suite boots the **real** `Isolate.spawn` + real cdylib (never mocked) —
  `app/test/worker/zanshin_worker_test.dart` is the template (`ZanshinWorker.start()`, temp-dir
  `initRepo`, `tearDown` closes the worker). `cargo make test` builds the cdylib before `flutter test`;
  `JJ_CONFIG`/`GIT_CONFIG_GLOBAL` are pinned by `[tasks.test-flutter]` in `Makefile.toml`.
- **Decode-contract:** `app/test/ffi/diagnostics_test.dart` is the template for synthetic-buffer
  `decodeStatusEnvelope` tests (build inputs with the generated `EnvelopeObjectBuilder` /
  `StatusObjectBuilder` / `FileChangeObjectBuilder`).

### Hard guardrails (reject-on-sight — project-context Critical Don't-Miss)

- **No JSON on the FFI wire.** No `serde_json`, no `jsonschema`, no `*mut c_char` envelope, no
  `serde::Serialize` on `Status`. FlatBuffers only. The epic's `internal.serialization_failed` is **not**
  used (FlatBuffers in-memory build does not fail that way).
- **No `extern "C"` outside `crates/zanshin-ffi/`** — `zanshin_status` lives in `zanshin-ffi/src/status.rs`.
- **No `zanshin-jj` change** — `Repo::status()` already exists; don't touch it, don't add `Serialize`.
- **No `Arc<Mutex>`/`RwLock`** around the handle (single-isolate, AD-2). `status` **borrows**, never drops.
- **No regenerating `*_generated.*` / `zanshin_ffi.h` / `bindings.dart` outside `cargo make codegen`**;
  commit the generated diffs in the same PR. **Never hand-edit them.**
- **No `dart:ffi` outside `app/lib/src/ffi/`**; **no Flutter UI**; raw handles never leave the worker
  (Model A) — `zanshinStatus(int)` is worker-only, like `zanshinRepoClose`.
- **SPDX `MIT` first line** on every new hand-written `.rs`/`.dart` (`status.rs`, `status_ffi.rs`,
  `ffi/status.dart`, any new test file). Generated files exempt.
- **Clippy pedantic `-D warnings`** — fix, don't `#[allow]`; any `#[allow]`/`unsafe`/`default-features=
  false` needs a `// WHY:`/`// SAFETY:`.

### Project Structure Notes

- New files: `crates/zanshin-ffi/src/status.rs`, `crates/zanshin-ffi/tests/status_ffi.rs`,
  `app/lib/src/ffi/status.dart`, optionally `app/test/worker/status_test.dart` +
  `app/test/ffi/status_test.dart`.
- Modified: `crates/zanshin-ffi/src/lib.rs` (`pub mod status;`), `crates/zanshin-ffi/src/envelope.rs`
  (`JJ_NO_WORKING_COPY`), `schemas/envelope.fbs`, `docs/rust-error-codes.md`,
  `app/lib/src/worker/{commands.dart,isolate.dart,handle.dart}`, and the five committed codegen outputs.
- **Module-by-noun:** the wrapper goes in a new `status.rs` (mirrors `zanshin-jj`'s noun layout; keeps
  `repo.rs` lifecycle-only; sets the pattern for `change`/`op_log`/`bookmarks`/`remotes`). The literal
  epic AC text ("Given `crates/zanshin-ffi/src/repo.rs` … defines `zanshin_status`") is the pre-split
  monolithic 3.4 phrasing — superseded; see OQ#1.
- **No `Cargo.toml` change:** `zanshin-ffi` already has `zanshin-jj` + the `tempfile`/`test-helpers`
  dev-deps (Story 3.4a).

### References

- [Source: docs/adr/0001-ffi-data-transport-flatbuffers.md] — FlatBuffers transport (supersedes JSON envelope).
- [Source: docs/adr/0002-repository-state-model-warm-loader-reload-per-operation.md] — `status()` re-resolves to head per call.
- [Source: _bmad-output/project-context.md] — §FFI boundary (transport/ownership/Envelope), §Testing, §Critical Don't-Miss, §Logging.
- [Source: _bmad-output/planning-artifacts/epics.md#Story 3.4b (lines 2147-2249, JSON/`*mut c_void` phrasing superseded)] and [#Story 2.4 (1159-1221)] and [#Story 3.4a (2029-2098, the authoritative Rust pattern)].
- [Source: _bmad-output/implementation-artifacts/3-4a-repo-ffi-wrappers-…md] — token ABI, `catch` wrapper, codegen discipline, env-pinned integration-test harness, AD-2 handle contract.
- [Source: _bmad-output/implementation-artifacts/2-4-implement-status-rs-working-copy-status.md] — `Status`/`FileChange`/`ChangeKind`/`ChangeId`/`StatusError` shapes + `Repo::status()`.
- [Source: _bmad-output/implementation-artifacts/3-8-diagnostics-api-wip-minimal.md] — payload-returning read + Dart decode-with-discriminant-guard pattern.
- [Source: _bmad-output/implementation-artifacts/3-9-dart-worker-isolate-bootstrap-…md] — worker bus, Model-A handle table, the `send()`/`BufferResult` seam reserved for 3.4b.
- [Source: crates/zanshin-ffi/src/{repo.rs, diagnostics.rs, envelope.rs, handle.rs, ffi_strings.rs, lib.rs}; schemas/envelope.fbs; crates/zanshin-ffi/tests/repo_ffi.rs] — exact code to mirror.
- [Source: app/lib/src/ffi/{repo.dart, diagnostics.dart, ffi_buffer.dart}; app/lib/src/worker/{commands.dart, responses.dart, isolate.dart, handle.dart}; app/test/worker/zanshin_worker_test.dart; app/test/ffi/diagnostics_test.dart] — exact Dart to mirror.
- [Source: docs/rust-error-codes.md] — registry; add `jj.no_working_copy`.

---

## Dev Agent Record

### Agent Model Used

Claude Sonnet 4.6 (1M context)

### Debug Log References

_None — implementation proceeded cleanly from spec._

### Completion Notes List

- T1: Extended `schemas/envelope.fbs` with `ChangeKind` enum, `FileChange` table, `Status` table, appended `Status` to `union Payload`, ticked roadmap comment. Ran `cargo make codegen`; all five artifacts regenerated.
- T2: Added `pub const JJ_NO_WORKING_COPY: &str = "jj.no_working_copy"` to `envelope.rs`; added registry row to `docs/rust-error-codes.md`.
- T3: Created `crates/zanshin-ffi/src/status.rs` with `status_to_envelope` builder (children-before-parents FlatBuffers order), `map_status_err`, and `unsafe extern "C" fn zanshin_status`. Declared `pub mod status;` in `lib.rs`.
- T4: Confirmed codegen artifacts — `zanshin_ffi.h` has `zanshin_status`, `bindings.dart` has `zanshin_status`, generated Rust+Dart expose `Status`/`FileChange`/`ChangeKind`.
- T5: Builder unit test covers all 5 ChangeKinds + change-id round-trip. Integration tests: clean round-trip (tiny fixture, empty files, non-empty ids) + `zanshin_status(0)` → `ffi.invalid_handle`. All 2 integration tests green.
- T6: `StatusCommand` added to `commands.dart`. Worker dispatch case added to `_workerEntry` in `isolate.dart` (lookup, never remove). `ZanshinWorker.status()` method added. `app/lib/src/ffi/status.dart` created with `zanshinStatus` adapter, `WorkingCopyStatus`/`FileChange`/`FileChangeKind` models, `decodeStatusEnvelope` (`@visibleForTesting`) + `decodeStatusEnvelopeInternal` (production). `RepoHandle.status()` added to `handle.dart`.
- T7: `app/test/worker/status_test.dart`: round-trip (fresh init → empty files, non-empty ids) + closed-handle → `ffi.invalid_handle` + RepoHandle closed guard → `StateError`. `app/test/ffi/status_test.dart`: error envelope → throws, non-Status payload → `ffi.unknown`, all-5-ChangeKinds decode → correct mapping + fromPath.
- T8: `cargo make test` green — 59 Rust unit + 17+2 integration + 8 zanshin-jj status tests + 27 Flutter tests (including 6 new). Clippy pedantic, fmt/format, cargo deny, dart analyze all clean.

### File List

New files:
- `schemas/envelope.fbs` (modified — ChangeKind, FileChange, Status, Payload union)
- `crates/zanshin-ffi/src/status.rs` (NEW — status wrapper, builder, tests)
- `crates/zanshin-ffi/tests/status_ffi.rs` (NEW — integration tests)
- `app/lib/src/ffi/status.dart` (NEW — FFI adapter, models, decoder)
- `app/test/worker/status_test.dart` (NEW — worker round-trip + guard tests)
- `app/test/ffi/status_test.dart` (NEW — decode-contract tests)

Modified files:
- `schemas/envelope.fbs`
- `crates/zanshin-ffi/src/envelope.rs` (added `JJ_NO_WORKING_COPY` const)
- `crates/zanshin-ffi/src/envelope_generated.rs` (codegen — added Status/FileChange/ChangeKind)
- `crates/zanshin-ffi/src/lib.rs` (added `pub mod status;`)
- `crates/zanshin-ffi/include/zanshin_ffi.h` (codegen — added `zanshin_status`)
- `app/lib/src/ffi/bindings.dart` (codegen — added `zanshin_status`)
- `app/lib/src/ffi/envelope_zanshin.ffi_generated.dart` (codegen — added Status/FileChange/ChangeKind)
- `app/lib/src/worker/commands.dart` (added `StatusCommand`)
- `app/lib/src/worker/isolate.dart` (added dispatch case + `status()` method + import)
- `app/lib/src/worker/handle.dart` (added `status()` method + import)
- `docs/rust-error-codes.md` (added `jj.no_working_copy` row)
- `_bmad-output/implementation-artifacts/sprint-status.yaml` (status update)

### Change Log

| Date | Change |
|------|--------|
| 2026-06-22 | Story created (ready-for-dev) — `status` slice of 3.4b |
| 2026-06-22 | Implemented all tasks (T1–T8); `cargo make test` green (Rust + Dart); status → review |
| 2026-06-22 | Code review passed (`bmad-code-review`: adversarial 3-layer + dedup + 3-lens verify; 19 raw → 17 deduped → 1 confirmed; all 24 ACs PASS; 16 dismissed). 1 LOW patch applied = `map_status_err` both-arms unit test. status → done |

---

## Open Questions for Ralph (non-blocking — defaults chosen, override before dev if desired)

1. **Wrapper module location.** I put `zanshin_status` in a **new `status.rs`** (noun module; mirrors
   `zanshin-jj`; sets the pattern for the four remaining read nouns), not in the existing `repo.rs`.
   The superseded epic text literally said `repo.rs`. **Recommended: `status.rs`.** Keep, or co-locate
   read wrappers in `repo.rs`?

2. **`Status` builder placement.** I keep the `zanshin_jj::Status → FlatBuffers` mapping in `status.rs`,
   leaving `envelope.rs` free of domain types (it only has primitive/`FfiErrorObj` builders today).
   The alternative is symmetry with `ok_repo_handle`/`ok_diagnostics` (all in `envelope.rs`).
   **Recommended: keep domain mapping in the noun module** (scales to change/op_log/bookmarks/remotes). OK?

3. **Sprint-status key shape.** The single umbrella key
   `3-4b-read-path-ffi-wrappers-zanshin-status-…-remotes` no longer matches the per-noun delivery. I plan
   to **split it into five per-noun keys** (`3-4b-zanshin-status-ffi-wrapper: ready-for-dev` + four
   `backlog`), faithfully reflecting the documented slicing. **Recommended: split.** Prefer I keep one
   umbrella key instead?

4. **Non-empty FFI integration test.** The Rust integration test asserts the clean (empty-`files`)
   round-trip + invalid handle; exhaustive `ChangeKind` mapping is covered by the **builder unit test**
   (synthetic `Status`), and real Added/Modified/Removed/Renamed computation is already covered in
   `zanshin-jj/tests/status.rs`. I did **not** duplicate the jj snapshot recipe in the ffi crate.
   **Recommended: as-is.** Want a real modified-file round-trip at the FFI layer too (heavier setup)?

---

## Review Findings

_Code review 2026-06-22 — `bmad-code-review` (adversarial 3-layer: Blind Hunter / Edge Case Hunter / Acceptance Auditor, Opus 4.8) + cross-layer dedup + 3-lens adversarial verification (code-reality / spec-and-rules / materiality). 19 raw → 17 deduped → 1 confirmed. Acceptance Auditor: all 24 ACs PASS. Outcome: 0 decision-needed, 1 patch, 0 defer, 16 dismissed as noise (incl. the original HIGH UAF claim — refuted: `handle_from_raw` returns `Option<&mut T>`, a borrow, never consumes/drops the `Repo`)._

### Patch

- [x] [Review][Patch] Add a `map_status_err` unit test covering both error arms — `StatusError::NoWorkingCopy → jj.no_working_copy` (context `None`) and `StatusError::Backend(s) → jj.jj_lib_error` (context `Some(s)`); the new `jj.no_working_copy` code is currently exercised by no test, so a mapping regression would pass CI. [crates/zanshin-ffi/src/status.rs:20-31] — ✅ applied 2026-06-22 (`status::tests::map_status_err_maps_both_variants`; clippy pedantic + fmt + `cargo test -p zanshin-ffi` green)
