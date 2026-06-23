# Story 3.4b — `zanshin_change` FFI wrapper + Dart change seam (change slice)

---
baseline_commit: 884b518
---

Status: done

<!-- Note: Validation is optional. Run validate-create-story for quality check before dev-story. -->

> **This is the `change` slice of Story 3.4b.** Per the 2026-06-15 WIP re-sequencing
> (sprint-status.yaml:103-114), Story 3.4b lands one thin read-path wrapper **per finished Epic-2
> noun**, each made "aus Flutter testbar" the moment its jj-lib noun is `done`:
>
> | Epic-2 noun (source) | 3.4b slice            | gate |
> |----------------------|-----------------------|------|
> | 2.4 `status` ✅ done   | `zanshin_status` ✅ done | shipped |
> | **2.6 `change`**      | **`zanshin_change` (THIS story)** | ⛔ **gated on 2.6** |
> | 2.7 `op_log`         | `zanshin_op_log`      | 2.7 backlog |
> | 2.8 `bookmarks`      | `zanshin_bookmarks`   | 2.8 backlog |
> | 2.9 `remotes`        | `zanshin_remotes`     | 2.9 backlog |
>
> **Stay in this slice** — do **not** build `op_log`/`bookmarks`/`remotes` or `zanshin_revset_resolve`.

> ## ⛔ HARD GATE — Story 2.6 must be `done` first
>
> This wrapper only **exposes** `zanshin_jj::Repo::get_change`; it never adds it. As of this story's
> creation `crates/zanshin-jj/src/change.rs` does **not** exist (sprint-status.yaml:70 — 2.6 is
> `backlog`/`ready-for-dev`). **Do not start the Rust side until Story 2.6 is `done`.** Before writing
> `map_change_err` / the `Change` FlatBuffers table, **read the real `crates/zanshin-jj/src/change.rs`**
> and confirm the actual public shape — the `Change` field set, the `ChangeError` variants, the timestamp
> representation, and the `is_signed`/`divergent` decisions are all subject to 2.6's resolved Open
> Questions (2.6 OQ2/OQ3/OQ4/OQ5). The shapes below assume 2.6's **recommended defaults**; reconcile if
> Ralph overrode them. [verified: sprint-status.yaml:70-71; 2-6-implement-change-rs-change-metadata-read.md]

---

## ⚠️ CRITICAL — Read this before writing any code (spec reconciliation)

The Story 3.4b acceptance criteria in `epics.md` (lines 2147-2249) are **stale on four axes** and are
superseded here. Treat the ACs in *this* file as the binding contract, not the epic prose:

1. **Transport is FlatBuffers, not JSON (ADR-0001).** The epic says `zanshin_change(handle, change_id_json)`
   takes `change_id_json = "{\"id\":\"<hex>\"}"` and "returns a JSON envelope with `data = Change`",
   routing bad input through `internal.serialization_failed`. **All superseded.** Composite FFI data
   crosses as a FlatBuffers `Envelope` token (`*mut ZanshinBuf`); there is no JSON, no `serde::Serialize`
   on `Change`, no `jsonschema`. This slice **adds one `Payload` member** (`Change`) and consumes the
   existing 3-0…3-4a/3.4b-status infrastructure. [Source: docs/adr/0001; project-context.md `overrides:`]
2. **The `change_id` is a lone CString, not JSON (ADR-0001).** Per the lone-string transport rule, the
   change id crosses as `*const c_char` (a single string), decoded via `cstr_to_string` — **not** a
   `{"id": …}` JSON wrapper. Bad input maps to `ffi.null_pointer` / `ffi.utf8_error`, **not**
   `internal.serialization_failed` (which is retired). [Source: schemas/envelope.fbs:5-8; epics.md:2151]
3. **The `zanshin_repo_*` ACs in the epic are owned by Story 3.4a (`done`).** Ignore the epic's 3.4b
   `zanshin_repo_open/init/clone/close` signatures entirely. This slice adds **one new function**:
   `zanshin_change`.
4. **Handle is a `u64` integer, not `*mut c_void`.** Per the committed 3.4a/3.4b-status ABI, handles cross
   as a `ulong`; `zanshin_change` takes that `u64` back and **borrows** the `Repo` (it does *not*
   consume/close it). Null handle (`0`) → `ffi.invalid_handle`.

The **done** sibling **Story 3.4b-status** (`3-4b-zanshin-status-ffi-wrapper.md`) is the authoritative
pattern for everything here — Rust wrapper, builder, error mapping, codegen discipline, and the full Dart
seam. **Mirror it exactly.** The one structural difference: `zanshin_change` takes a **lone-string arg**
(`change_id`), so it borrows the C-string crossing from **Story 3.4a** (`zanshin_repo_open`'s
`cstr_to_string` + the Dart `toNativeUtf8()`/`calloc.free` marshalling) — no existing read wrapper does
this, because `status` takes only a handle.

---

## Scope (read once, then never widen)

**IN scope — the full Dart↔Rust bridge for `change`** (the bridge is in scope per
`feedback-scope-bridge-is-claudes-ui-is-ralphs`; only the Flutter UI is out):

- **Rust:** extend `schemas/envelope.fbs` (`Signature`/`ConflictState`/`Change` tables + `Payload` union);
  new `extern "C" zanshin_change(handle: u64, change_id: *const c_char) -> *mut ZanshinBuf` in a new
  `crates/zanshin-ffi/src/change.rs`; map `zanshin_jj::Change` → FlatBuffers; map `ChangeError` →
  `error.code`; one new error code `jj.change_not_found`; regenerate + commit all five codegen artifacts;
  Rust unit + integration tests.
- **Dart:** `GetChangeCommand` (worker command, carries `handleId` + `changeId`); the worker-isolate
  dispatch case; the `zanshinChange(int, String)` FFI adapter; main-side decode into a Dart `Change`
  model; `ZanshinWorker.getChange()` + `RepoHandle.getChange()`; Dart worker round-trip test against the
  **real cdylib** + a decode-contract unit test.

**OUT of scope:**

- Any Flutter widget / screen that *displays* a change (Ralph's separate work).
- The other 3.4b nouns (`op_log`, `bookmarks`, `remotes`) and `zanshin_revset_resolve`.
- The watcher (Stories 3.5/3.6) — `change` is a one-shot read; ADR-0002 re-resolves to head per call.
- Any `zanshin-jj` change — `Repo::get_change()` ships in **Story 2.6**. This slice only *exposes* it.
  (If 2.6 isn't `done` yet, see the HARD GATE above — do not implement 2.6 here.)
- Cryptographic-signature **validation / signer identity** — `Change.is_signed` is presence-only (2.6 D3).

---

## Story

As the Dart worker isolate (and, behind it, Ralph's future Flutter UI),
I want an `extern "C" zanshin_change(handle, change_id)` wrapper that calls `zanshin_jj::Repo::get_change()`
and returns the change metadata as a FlatBuffers `Envelope`, plus the Dart command/adapter/decode seam that
turns it into a typed `Change`,
so that the second read-path noun is callable end-to-end from Dart against a real repo — exercising the
first FFI read wrapper that takes a **lone-string argument** (the change id) alongside a handle.

---

## Acceptance Criteria

Grouped by deliverable. Each item is a checkable contract.

### AC-1 — wire schema: `Change` payload (`schemas/envelope.fbs`)

1. `schemas/envelope.fbs` gains, in `snake_case` (flatc emits `lowerCamelCase` getters):
   ```fbs
   /// A commit signature: who authored/committed + when (raw jj timestamp).
   table Signature {
     name: string;
     email: string;
     timestamp_millis: long;       // millis since the Unix epoch
     tz_offset_minutes: int;       // timezone offset, minutes east of UTC
   }

   /// Whether a change is conflict-free. `conflicted_paths` is populated only when Conflicted.
   enum ConflictState : byte { Clean, Conflicted }

   /// Full metadata for one change (FR-JJ-6). Authored/committed times live on the
   /// author/committer signatures (authored_at == author.timestamp_millis, etc.).
   table Change {
     id: string;                  // ChangeId reverse-hex (stable across rebases)
     commit_id: string;           // CommitId hex (Git SHA; changes on rebase)
     parents: [string];           // parent ChangeIds reverse-hex; empty for the root change
     description: string;         // always present, may be empty
     author: Signature;
     committer: Signature;
     is_signed: bool;             // cryptographic signature present (presence-only; 2.6 D3)
     conflict: ConflictState;
     conflicted_paths: [string];  // populated only when conflict == Conflicted
     is_anonymous: bool;
     divergent: bool;             // change id resolved to >1 visible commit (2.6 D4)
   }
   ```
   and `Change` is **appended** to the union (never reorder — union tags are positional):
   `union Payload { RepoHandle, Diagnostics, Status, Change }`.
2. The payload-roadmap comment (`schemas/envelope.fbs:36`) is updated to mark `change` ✓.
3. The `Change` table mirrors the **actual** `zanshin_jj::Change` shipped by Story 2.6 — if Ralph
   overrode 2.6's OQ2 (raw timestamps), OQ3 (`is_signed` presence-only), or OQ4 (`divergent`), reconcile
   this table to match the real struct before coding (HARD GATE).

### AC-2 — `zanshin_jj::Change` → FlatBuffers mapping

4. A builder `change_to_envelope(&zanshin_jj::Change) -> Vec<u8>` (in `crates/zanshin-ffi/src/change.rs`)
   maps every field:
   - `id` / `commit_id` → the inner `String` (`.0`); `parents` → a `[string]` vector of each `ChangeId.0`;
   - `description` → `create_string` (always present, may be empty);
   - `author` / `committer` → nested `Signature` tables (`name`, `email`, `timestamp.millis_since_epoch`,
     `timestamp.tz_offset_minutes`);
   - `is_signed` / `is_anonymous` / `divergent` → bools;
   - `conflict` → `ConflictState::Clean` with `conflicted_paths` **unset**, or `ConflictState::Conflicted`
     with `conflicted_paths` = each `PathBuf::to_string_lossy()`.
5. The builder follows FlatBuffers "children before parents": create both `Signature` tables (their strings
   first), the `parents` vector, the `conflicted_paths` vector (if any), and the `id`/`commit_id`/
   `description` strings, **then** the `Change` table, **then** the `Envelope`; finish with plain
   `b.finish(...)` (NOT size-prefixed — length rides in `ZanshinBuf.len`, matching `status_to_envelope`).

### AC-3 — `zanshin_change` extern function

6. `crates/zanshin-ffi/src/change.rs` is created, declared `pub mod change;` in `lib.rs`, and defines
   ```rust
   #[no_mangle]
   pub unsafe extern "C" fn zanshin_change(handle: u64, change_id: *const c_char) -> *mut ZanshinBuf
   ```
   wrapped in `envelope::catch(|| { … })` so no panic crosses the C ABI, with a `debug!(fn_name =
   "zanshin_change", handle)` span.
7. On a valid, non-zero `handle`, it **borrows** the `Repo` via `handle::handle_from_raw::<Repo>(handle as
   *mut Repo)` (does **not** drop/consume it), decodes `change_id` via `ffi_strings::cstr_to_string`,
   calls `repo.get_change(&ChangeId(id))`, and returns the `Change` payload envelope from AC-2 with
   `ok == true`.
8. `change_id` handling: a **null** pointer → `error.code == "ffi.null_pointer"`; **invalid UTF-8** →
   `"ffi.utf8_error"` (both via `cstr_to_string`, inside the `catch` closure). The string is allocated and
   freed by **Dart** (Rust only borrows for the call — AR-P-5 inbound rule).
9. `handle == 0` (and any case where `handle_from_raw` yields `None`) returns `ok:false` with
   `error.code == "ffi.invalid_handle"` — never a crash, never NULL. (Same AD-2 contract as
   `zanshin_status`: the only *detectable* invalid handle; a stale non-zero handle is UB the Rust layer
   must not detect; the Dart worker's Model-A table makes a stale handle unreachable anyway.)
10. The returned `*mut ZanshinBuf` is produced by `ffi_strings::vec_into_token(buf)` and is freed by Dart
    exactly once via `zanshin_buffer_free_token` (the `FfiBuffer.fromToken` path).

### AC-4 — `ChangeError` → `error.code` mapping + registry

11. A `map_change_err(ChangeError) -> FfiErrorObj` (in `change.rs`) maps:
    - `ChangeError::NotFound { id }` → **new** code `jj.change_not_found` (context `Some(id)` — the id is
      user data and goes in `context`, **never** in `code`);
    - `ChangeError::Backend(s)` → existing `jj.jj_lib_error` (context `Some(s)`).
    (Reconcile against 2.6's actual `ChangeError` variants per the HARD GATE.)
12. `crates/zanshin-ffi/src/envelope.rs` gains `pub const JJ_CHANGE_NOT_FOUND: &str =
    "jj.change_not_found";` (auto-re-exported at the crate root via `pub use envelope::*`) — the
    single-emission-point rule (AR-P-4): no `error.code` literal appears outside `envelope.rs`.
13. `docs/rust-error-codes.md` adds a row: `jj.change_not_found | jj | No change found for the given id. |
    Emitted — Story 3.4b (change) (envelope.rs::JJ_CHANGE_NOT_FOUND, change.rs)`. `change` also reuses the
    existing `ffi.invalid_handle`, `ffi.null_pointer`, `ffi.utf8_error`, `jj.jj_lib_error`,
    `internal.panic` — no new consts for those.

### AC-5 — codegen committed

14. `cargo make codegen` is run and **all five** regenerated artifacts are committed in the same PR:
    `schemas/envelope.fbs` (source), `crates/zanshin-ffi/src/envelope_generated.rs`,
    `app/lib/src/ffi/envelope_zanshin.ffi_generated.dart`, `crates/zanshin-ffi/include/zanshin_ffi.h`,
    `app/lib/src/ffi/bindings.dart`. The header/bindings contain `zanshin_change` (a **new** binding
    shape: `ffi.Uint64` + `ffi.Pointer<ffi.Char>` — not present today); both generated accessor files
    expose `Change`, `Signature`, `ConflictState`, and `Payload::Change` / `data_as_change()`. **Never
    hand-edit generated files.** Run codegen **twice** (after the schema edit, then after the new
    `extern "C"` symbol).

### AC-6 — Rust tests

15. **Builder unit test** (in `change.rs` `#[cfg(test)]`): construct a `zanshin_jj::Change` exercising
    **every** field — non-empty `parents` (≥2), a populated `author` and `committer` (distinct
    name/email/timestamp), `is_signed == true`, `ConflictState::Conflicted { paths }` with ≥1 path,
    `is_anonymous == true`, `divergent == true`, and a non-empty `description`; build the envelope, parse
    it through the generated typed accessors + the FlatBuffers `Verifier`, and assert: `ok == true`,
    `data_type == Payload::Change`, and every field round-trips (incl. nested signatures, the parents
    vector, the conflicted-paths vector, and all three bools). Add a second case with
    `ConflictState::Clean` (empty description, `divergent == false`) asserting `conflicted_paths` is
    empty/`None`.
16. **`map_change_err` unit test** covering **both** arms — `NotFound { id } → jj.change_not_found`
    (context `Some(id)`) and `Backend(s) → jj.jj_lib_error` (context `Some(s)`). (The status slice's code
    review added exactly this test for `map_status_err`; the new `jj.change_not_found` code is otherwise
    exercised by no test, so a mapping regression would pass CI.)
17. **Integration tests** in `crates/zanshin-ffi/tests/change_ffi.rs` (mirror `tests/status_ffi.rs`'s
    `pin_env` / `read_and_free` / `parse_envelope` / `cstr` / `extract_fixture` harness; free every token;
    pin `JJ_CONFIG`/`GIT_CONFIG_GLOBAL`):
    - **valid round-trip:** `zanshin_repo_open` the `tiny-3-commits` fixture → read `RepoHandle.handle`
      → obtain a real change id (e.g. `zanshin_status(handle)` → `working_copy_change_id`) →
      `zanshin_change(handle, cstr(id).as_ptr())` → assert `ok`, `data_type == Change`, `id()` matches,
      `parents()` present, `description()` decodable → `zanshin_repo_close(handle)`.
    - **not found:** `zanshin_change(handle, cstr("nonexistentchangeid").as_ptr())` → `ok:false`,
      `error.code == "jj.change_not_found"`, `context` = the passed id.
    - **null change_id:** `zanshin_change(handle, std::ptr::null())` → `"ffi.null_pointer"`.
    - **invalid handle:** `zanshin_change(0, cstr(id).as_ptr())` → `"ffi.invalid_handle"`.
18. No `jsonschema`, no hand-parsing of bytes; a wrong-shape payload must be a **compile** error. Do not
    duplicate the jj-lib metadata computation already covered by `zanshin-jj/tests/change.rs` (Story 2.6) —
    AC-15 covers the *mapping*, AC-17 covers the *FFI round-trip*.

### AC-7 — Dart bridge (the seam Story 3.9 reserved for 3.4b read commands)

19. `app/lib/src/worker/commands.dart` gains a `final class GetChangeCommand extends WorkerCommand {
    const GetChangeCommand({required super.commandId, required this.handleId, required this.changeId});
    final int handleId; final String changeId; }` (only `int`/`String` fields — sendable across the
    isolate port).
20. The worker dispatch `switch (msg)` in `app/lib/src/worker/isolate.dart` gains a
    `case GetChangeCommand(:final int handleId, :final String changeId):` that **looks up**
    `handles[handleId]` (read — **never** `handles.remove`), calls
    `repo_ffi_change.zanshinChange(raw, changeId)`, and replies `BufferResult(bytes)`; an unknown
    `handleId` replies an `ffi.invalid_handle` envelope (reuse the `EnvelopeObjectBuilder` pattern the
    status case uses). The sealed switch stays exhaustive (compile-time enforced — adding the command
    forces this arm).
21. `app/lib/src/ffi/change.dart` (NEW) defines:
    - `Uint8List zanshinChange(int rawHandle, String changeId)` — the FFI adapter. It marshals `changeId`
      via `changeId.toNativeUtf8()`, passes `.cast()` to `zanshin_change(rawHandle, ptr)`, wraps the
      returned token via `FfiBuffer.fromToken`, copies to a heap `Uint8List`, and frees the C string with
      `calloc.free(ptr)` in an **outer** `finally` (the buffer is disposed in an **inner** `finally`) —
      the `ffi/repo.dart` `zanshinRepoOpen` marshalling combined with the `ffi/status.dart` token read.
    - Dart models: `Change`, `Signature`, `enum ConflictState { clean, conflicted }`, mirroring the
      generated accessors (`authoredAt`/`committedAt` derived from the author/committer signature
      timestamps).
    - `@visibleForTesting Change decodeChangeEnvelope(Uint8List)` + `Change decodeChangeEnvelopeInternal(
      Uint8List)`, both delegating to a private `_decodeChangeEnvelope` — throws `ZanshinFfiException(code,
      context)` on `!ok`; throws `ZanshinFfiException('ffi.unknown', …)` when the payload is not a `Change`
      (guard `payload is! fbs.Change` before the cast); otherwise maps `fbs.Change` → `Change`.
22. `app/lib/src/worker/isolate.dart` gains a main-side `Future<Change> getChange(int handleId, String
    changeId)` that sends `GetChangeCommand(commandId: _correlator.allocateId(), handleId: handleId,
    changeId: changeId)` via the existing public `send(...)` and returns `decodeChangeEnvelopeInternal(
    bytes)`; add the `import '../ffi/change.dart' as repo_ffi_change;` alias. `app/lib/src/worker/
    handle.dart` gains `Future<Change> getChange(String changeId)` (throwing `StateError` if the
    `RepoHandle` is already `_closed`, mirroring `status()`); extend its `show` import to include the
    `Change` model.
23. No `dart:ffi` import leaks outside `app/lib/src/ffi/`; no Flutter widget code; the worker still owns
    every raw handle (Model A) — `zanshinChange(int, String)` is called **only** from the worker isolate.

### AC-8 — Dart tests

24. `app/test/worker/change_test.dart` (NEW, mirror `status_test.dart`) adds a **real-cdylib** round-trip
    (boots `ZanshinWorker.start()`, no mocks): `initRepo(tempDir, backend: 0)` → read a real change id
    (e.g. via `handle.status()` → `workingCopyChangeId`) → `handle.getChange(id)` → assert the model's
    `id` matches and fields decode; a **not-found** id surfaces `ZanshinFfiException(code:
    'jj.change_not_found')`; and `getChange` on a **closed** handle surfaces `ffi.invalid_handle` (close
    the handle, call `worker.getChange(handle.handleId, id)` directly, bypassing the `RepoHandle` guard,
    as the status test does), plus the `RepoHandle.getChange` synchronous closed-guard → `StateError`.
25. A decode-contract unit test `app/test/ffi/change_test.dart` (mirror `status_test.dart`/
    `diagnostics_test.dart`) exercises `decodeChangeEnvelope` with synthetic FlatBuffers built via the
    generated `EnvelopeObjectBuilder` / `ChangeObjectBuilder` / `SignatureObjectBuilder`: an error
    envelope → throws `ZanshinFfiException` with the right `code`; a non-`Change` payload → `ffi.unknown`;
    a fully-populated `Change` (both conflict states, ≥2 parents, all bools) → correct mapping.

### AC-9 — quality gate green

26. `cargo make test` passes end-to-end: `cargo clippy --workspace --all-targets -- -D warnings`
    (pedantic, **refactor — don't `#[allow]`**; any unavoidable suppression carries a `// WHY:`),
    `cargo fmt --all --check` (`max_width = 120`), all Rust unit + integration tests, `cargo deny check
    advisories bans`, and the cargo-hygiene gate. The Dart suite (`flutter test`) is green, including the
    new worker + decode tests; `dart analyze --fatal-infos --fatal-warnings` and `dart format` are clean.
27. Every new hand-written `.rs`/`.dart` file starts with `// SPDX-License-Identifier: MIT` (generated
    files exempt). No `unsafe` outside the documented `extern "C"` seam; every `unsafe` block carries a
    `// SAFETY:` and every `unsafe fn` a `# Safety` doc section. No new crate, no `Cargo.toml` dependency
    change (`zanshin-ffi` already depends on `zanshin-jj` + the `tempfile`/`test-helpers` dev-deps).

---

## Tasks / Subtasks

- [x] **T0 — Confirm the 2.6 gate** (HARD GATE)
  - [x] Verified Story 2.6 is `review` (done-pending-review) and read `change.rs`. Actual shapes match 2.6 recommended defaults exactly — no reconciliation needed.
- [x] **T1 — Extend the wire schema** (AC: 1, 2, 3, 14)
  - [x] Edited `schemas/envelope.fbs`: added `table Signature`, `enum ConflictState`, `table Change`; appended `Change` to `union Payload`; ticked roadmap comment.
  - [x] Ran `cargo make codegen`. Generated `envelope_generated.rs` + Dart `*.ffi_generated.dart` expose all expected accessors and ObjectBuilders.
- [x] **T2 — New error code** (AC: 12, 13)
  - [x] Added `pub const JJ_CHANGE_NOT_FOUND: &str = "jj.change_not_found"` to `envelope.rs`. Added registry row to `docs/rust-error-codes.md`.
- [x] **T3 — `change.rs`: mapping + wrapper + error mapping** (AC: 2, 4, 5, 6, 7, 8, 9, 10, 11)
  - [x] Created `crates/zanshin-ffi/src/change.rs` (SPDX `MIT`). Added `pub mod change;` to `lib.rs`.
  - [x] Implemented `change_to_envelope` builder (children-before-parents; nested `Signature` tables; `parents`/`conflicted_paths` vectors before the `Change` table).
  - [x] Implemented `map_change_err` and `zanshin_change` (catch-wrapped; `handle_from_raw` borrow; `cstr_to_string` for the id; `handle == 0`/`None` → `ffi.invalid_handle`; `debug!` span).
- [x] **T4 — Regenerate the FFI surface** (AC: 14)
  - [x] Ran `cargo make codegen` again after the new `extern "C"` symbol. Confirmed `zanshin_change` is in `zanshin_ffi.h` + `bindings.dart` (new `uint64_t handle + const char* change_id` shape). All five artifacts committed.
- [x] **T5 — Rust tests** (AC: 15, 16, 17, 18)
  - [x] Builder unit tests (Conflicted + Clean, all fields) + `map_change_err` both-arms test in `change.rs`. 63 unit tests total (including all pre-existing tests) green.
  - [x] `crates/zanshin-ffi/tests/change_ffi.rs`: 4 tests — valid round-trip (tiny fixture via status→changeId) + `jj.change_not_found` + null `change_id` + `zanshin_change(0, …)`.
- [x] **T6 — Dart bridge** (AC: 19, 20, 21, 22, 23)
  - [x] `GetChangeCommand` in `commands.dart`.
  - [x] Worker dispatch case (lookup, not remove) + unknown-handle error reply in `isolate.dart` + `repo_ffi_change` import alias.
  - [x] `app/lib/src/ffi/change.dart`: `zanshinChange(int, String)` (toNativeUtf8/calloc.free + token read), `Change`/`Signature`/`ConflictState` models, `decodeChangeEnvelope` + `decodeChangeEnvelopeInternal`.
  - [x] `ZanshinWorker.getChange()` (`isolate.dart`) + `RepoHandle.getChange()` (`handle.dart`).
- [x] **T7 — Dart tests** (AC: 24, 25)
  - [x] Worker round-trip + not-found + closed-handle + `RepoHandle.getChange` guard test (real cdylib) in `app/test/worker/change_test.dart`.
  - [x] `decodeChangeEnvelope` synthetic-buffer decode-contract unit test (error, non-Change payload, Conflicted, Clean) in `app/test/ffi/change_test.dart`.
- [x] **T8 — Gate** (AC: 26, 27)
  - [x] `cargo make test` green (Rust + Dart). Clippy pedantic clean. fmt/format clean. cargo deny clean. `dart analyze --fatal-infos --fatal-warnings` clean (0 issues). SPDX on all new hand-written files. Generated diffs reviewed.

---

## Dev Notes

### What you build on — exact, verified signatures

**`zanshin_jj::Change` (Story 2.6; `crates/zanshin-jj/src/change.rs`, re-exported from `lib.rs`) — assuming 2.6's recommended defaults:**
```rust
pub struct Change {
    pub id: ChangeId, pub commit_id: CommitId, pub parents: Vec<ChangeId>,
    pub description: String, pub author: Signature, pub committer: Signature,
    pub timestamps: Timestamps, pub is_signed: bool, pub conflict: ConflictState,
    pub is_anonymous: bool, pub divergent: bool,
}
pub struct CommitId(pub String);                                   // Git SHA hex; inner field `.0`
pub struct Signature { pub name: String, pub email: String, pub timestamp: Timestamp }
pub struct Timestamp { pub millis_since_epoch: i64, pub tz_offset_minutes: i32 }
pub struct Timestamps { pub authored_at: Timestamp, pub committed_at: Timestamp }
pub enum ConflictState { Clean, Conflicted { paths: Vec<PathBuf> } }
pub enum ChangeError { NotFound { id: String }, Backend(String) }  // thiserror
pub struct ChangeId(pub String);                                   // reverse-hex; reused from status.rs

impl Repo { pub fn get_change(&self, id: &ChangeId) -> Result<Change, ChangeError>; }   // &self — borrow
```
`Repo::get_change()` re-resolves to head per call (ADR-0002) and is read-only. The metadata computation
(parents, conflict, anonymity, divergence) is fully tested in `zanshin-jj/tests/change.rs` — this slice
exposes it; it does **not** re-test the computation. **NOTE:** `Change` does **not** carry an
`Option<Signature>` (signer identity) — only `is_signed: bool` (2.6 D3); the wire `Change` table follows.

**`zanshin-ffi` infrastructure to reuse (do NOT reinvent — shipped 3-0…3-4a, 3-8, 3.4b-status):**
```rust
// envelope.rs
pub fn catch<F: FnOnce() -> Result<Vec<u8>, FfiErrorObj> + UnwindSafe>(f: F) -> Vec<u8>;
pub struct FfiErrorObj { pub code: String, pub context: Option<String> }
pub const FFI_INVALID_HANDLE; FFI_NULL_POINTER; FFI_UTF8_ERROR; JJ_JJ_LIB_ERROR;   // (+ add JJ_CHANGE_NOT_FOUND)

// handle.rs
pub unsafe fn handle_from_raw<'a, T>(ptr: *mut T) -> Option<&'a mut T>;            // null → None; USE for the borrow

// ffi_strings.rs
pub unsafe fn cstr_to_string(ptr: *const c_char) -> Result<String, FfiErrorObj>;  // null→ffi.null_pointer, bad utf8→ffi.utf8_error
pub fn vec_into_token(buf: Vec<u8>) -> *mut ZanshinBuf;                            // USE for the return value
#[repr(C)] pub struct ZanshinBuf { pub ptr: *mut u8, pub len: usize }
pub unsafe extern "C" fn zanshin_buffer_free_token(token: *mut ZanshinBuf);

// lib.rs — `pub use envelope::*;` re-exports every const at the crate root;
//          `pub use envelope_generated::zanshin::ffi as fbs;` is the typed-accessor alias.
```
`cstr_to_string` is the one piece `status` did **not** use — it comes from the `zanshin_repo_open`/`init`
wrappers (Story 3.4a). Match `repo.rs`'s exact `c_char` import.

### The `zanshin_change` wrapper (sketch — mirror `zanshin_status` + `zanshin_repo_open`)

```rust
// crates/zanshin-ffi/src/change.rs
use std::ffi::c_char;                  // match repo.rs's exact import
use tracing::debug;
use zanshin_jj::{Change, ChangeError, ChangeId, ConflictState, Repo};
use crate::envelope::{catch, FfiErrorObj, FFI_INVALID_HANDLE, JJ_CHANGE_NOT_FOUND, JJ_JJ_LIB_ERROR};
use crate::ffi_strings::{cstr_to_string, vec_into_token, ZanshinBuf};
use crate::handle::handle_from_raw;

fn map_change_err(e: ChangeError) -> FfiErrorObj {
    match e {
        ChangeError::NotFound { id } => FfiErrorObj { code: JJ_CHANGE_NOT_FOUND.to_owned(), context: Some(id) },
        ChangeError::Backend(reason) => FfiErrorObj { code: JJ_JJ_LIB_ERROR.to_owned(), context: Some(reason) },
    }
}

/// Read full metadata for the change identified by `change_id` (jj reverse-hex form).
/// # Safety
/// `handle` must be a live value from `zanshin_repo_open/init/clone`; `0` → `ffi.invalid_handle`.
/// `change_id` is a NUL-terminated UTF-8 C string owned by the caller (Dart allocates + frees).
/// The returned token must be freed exactly once via `zanshin_buffer_free_token`.
#[no_mangle]
pub unsafe extern "C" fn zanshin_change(handle: u64, change_id: *const c_char) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_change", handle);
    let buf = catch(|| {
        // SAFETY: non-zero handle originated from handle_into_raw (Box<Repo>); single isolate (AD-2).
        let repo = unsafe { handle_from_raw::<Repo>(handle as *mut Repo) }
            .ok_or_else(|| FfiErrorObj { code: FFI_INVALID_HANDLE.to_owned(), context: None })?;
        // SAFETY: change_id is a caller-owned NUL-terminated C string (Dart allocates + frees).
        let id = unsafe { cstr_to_string(change_id) }?;   // null → ffi.null_pointer; bad utf8 → ffi.utf8_error
        let change = repo.get_change(&ChangeId(id)).map_err(map_change_err)?;
        Ok(change_to_envelope(&change))
    });
    vec_into_token(buf)
}
```
**Borrow only** — there is no `handle_drop` here. The `change_id` check happens *after* the handle check,
so a `(0, null)` call reports `ffi.invalid_handle` (handle is validated first) — fine; both are errors.

### The `Change` builder (sketch — children before parents; plain `b.finish`)

```rust
use crate::fbs;
use flatbuffers::{FlatBufferBuilder, WIPOffset};
use zanshin_jj::{Change, ConflictState, Signature};

fn signature_offset<'a>(b: &mut FlatBufferBuilder<'a>, sig: &Signature) -> WIPOffset<fbs::Signature<'a>> {
    let name = b.create_string(&sig.name);
    let email = b.create_string(&sig.email);
    fbs::Signature::create(b, &fbs::SignatureArgs {
        name: Some(name), email: Some(email),
        timestamp_millis: sig.timestamp.millis_since_epoch,
        tz_offset_minutes: sig.timestamp.tz_offset_minutes,
    })
}

fn change_to_envelope(change: &Change) -> Vec<u8> {
    let mut b = FlatBufferBuilder::with_capacity(1024);
    // 1) children: both signatures, parents vector, conflict paths, id strings — all BEFORE the Change table.
    let author_off = signature_offset(&mut b, &change.author);
    let committer_off = signature_offset(&mut b, &change.committer);
    let parent_offs: Vec<_> = change.parents.iter().map(|p| b.create_string(&p.0)).collect();
    let parents_vec = b.create_vector(&parent_offs);
    let (conflict, conflicted_paths) = match &change.conflict {
        ConflictState::Clean => (fbs::ConflictState::Clean, None),
        ConflictState::Conflicted { paths } => {
            let offs: Vec<_> = paths.iter().map(|p| b.create_string(&p.to_string_lossy())).collect();
            (fbs::ConflictState::Conflicted, Some(b.create_vector(&offs)))
        }
    };
    let id_off = b.create_string(&change.id.0);
    let commit_id_off = b.create_string(&change.commit_id.0);
    let desc_off = b.create_string(&change.description);
    // 2) the Change table.
    let change_off = fbs::Change::create(&mut b, &fbs::ChangeArgs {
        id: Some(id_off), commit_id: Some(commit_id_off), parents: Some(parents_vec),
        description: Some(desc_off), author: Some(author_off), committer: Some(committer_off),
        is_signed: change.is_signed, conflict, conflicted_paths,
        is_anonymous: change.is_anonymous, divergent: change.divergent,
    });
    // 3) Envelope.
    let env = fbs::Envelope::create(&mut b, &fbs::EnvelopeArgs {
        ok: true, error: None, data_type: fbs::Payload::Change, data: Some(change_off.as_union_value()),
    });
    b.finish(env, None);          // plain finish — length rides in ZanshinBuf.len
    b.finished_data().to_vec()
}
```
**FlatBuffers gotcha:** every child (the two `Signature` tables, both string vectors, the three strings)
is created *before* `fbs::Change::create` starts — you may not create a string/vector while the `Change`
table is open. Generated `fbs::ConflictState::*` lives in the same `fbs` alias; it does **not** collide
with `zanshin_jj::ConflictState`.

### Where the mapping lives — `change.rs`, not `envelope.rs` (same call as the status slice)

Keep the domain mapping in the **noun module** (`change.rs`), exactly as the status slice put it in
`status.rs`. `envelope.rs`'s builders take only primitives / `FfiErrorObj` and never import a `zanshin-jj`
domain type. `change.rs` builds the full envelope using `crate::fbs` + `FlatBufferBuilder` directly. (This
was status's OQ#2, resolved "keep in the noun module" — follow it.)

### Dart seam — the lone-string arg is the only new wrinkle

Mirror the status seam, but the FFI adapter must marshal a C string. Sketches:

```dart
// worker/commands.dart
final class GetChangeCommand extends WorkerCommand {
  const GetChangeCommand({required super.commandId, required this.handleId, required this.changeId});
  final int handleId;      // worker-side dense id (NOT the raw pointer)
  final String changeId;   // jj reverse-hex change id (sendable across the port)
}

// worker/isolate.dart — inside the dispatch switch (LOOKUP, never remove):
case GetChangeCommand(:final int handleId, :final String changeId):
  final int? raw = handles[handleId];
  if (raw == null) {
    final Uint8List errorBytes = fbs.EnvelopeObjectBuilder(
      ok: false,
      error: fbs.FfiErrorObjectBuilder(code: 'ffi.invalid_handle', context: 'unknown or closed handleId: $handleId'),
    ).toBytes();
    responseSP.send((commandId, BufferResult(errorBytes)));
  } else {
    responseSP.send((commandId, BufferResult(repo_ffi_change.zanshinChange(raw, changeId))));
  }

// worker/isolate.dart — main side, next to status():
Future<Change> getChange(int handleId, String changeId) async {
  final Uint8List bytes = await send(
    GetChangeCommand(commandId: _correlator.allocateId(), handleId: handleId, changeId: changeId),
  );
  return decodeChangeEnvelopeInternal(bytes);
}
```

```dart
// ffi/change.dart — combine repo.dart's toNativeUtf8/calloc.free with status.dart's token read.
Uint8List zanshinChange(int rawHandle, String changeId) {
  final ffi.Pointer<Utf8> p = changeId.toNativeUtf8();
  try {
    final ffi.Pointer<ZanshinBuf> token = zanshin_change(rawHandle, p.cast());
    final buf = FfiBuffer.fromToken(token);
    try {
      return Uint8List.fromList(buf.bytes);
    } finally {
      buf.dispose();          // inner: free the returned buffer
    }
  } finally {
    calloc.free(p);           // outer: free the C string we allocated (AR-P-5 inbound)
  }
}

@visibleForTesting
Change decodeChangeEnvelope(Uint8List bytes) => _decodeChangeEnvelope(bytes);
Change decodeChangeEnvelopeInternal(Uint8List bytes) => _decodeChangeEnvelope(bytes);

Change _decodeChangeEnvelope(Uint8List bytes) {
  final env = fbs.Envelope(bytes);
  if (!env.ok) {
    final fbs.FfiError? e = env.error;
    throw ZanshinFfiException(e?.code ?? 'ffi.unknown', e?.context);
  }
  final Object? payload = env.data;
  if (payload is! fbs.Change) {
    throw ZanshinFfiException('ffi.unknown', 'expected Change payload, got ${env.dataType}');
  }
  return Change(/* map payload.id / .commitId / .parents / .description / .author / .committer /
                   .isSigned / .conflict / .conflictedPaths / .isAnonymous / .divergent */);
}
```
Decode runs on the **main** isolate (the worker forwards raw bytes), exactly like `Status`/`Diagnostics`.
**Import naming:** alias `ffi/change.dart` as `repo_ffi_change` in `isolate.dart` (which already aliases
`ffi/repo.dart` as `repo_ffi` and `ffi/status.dart` as `repo_ffi_status`). `RepoHandle.getChange(String
changeId)` mirrors `RepoHandle.status()` (guard `_closed` → `StateError`, then `_worker.getChange(
_handleId, changeId)`); extend `handle.dart`'s `show` import to include the `Change` model.

### Testing standards (project-context Testing Rules)

- **Rust integration:** copy the `tests/status_ffi.rs` harness top (`ENV_GUARD`/`pin_env`, `read_and_free`,
  `parse_envelope`, `cstr`, `extract_fixture`). Get a real change id from the fixture by calling
  `zanshin_status(handle)` and reading `working_copy_change_id` (avoids hard-coding a fixture id). Free
  every token (`zanshin_buffer_free_token`). No network. Pin `JJ_CONFIG`/`GIT_CONFIG_GLOBAL`.
- **Dart:** the worker suite boots the **real** `Isolate.spawn` + real cdylib (never mocked) —
  `app/test/worker/status_test.dart` is the template. `cargo make test` builds the cdylib before
  `flutter test`; env vars are pinned by `[tasks.test-flutter]` in `Makefile.toml`.
- **Decode-contract:** `app/test/ffi/status_test.dart` (and `diagnostics_test.dart`) is the template for
  synthetic-buffer `decodeChangeEnvelope` tests (build inputs with the generated `EnvelopeObjectBuilder` /
  `ChangeObjectBuilder` / `SignatureObjectBuilder`).

### Hard guardrails (reject-on-sight — project-context Critical Don't-Miss)

- **No JSON on the FFI wire.** No `serde_json`, no `jsonschema`, no `*mut c_char` envelope, no
  `serde::Serialize` on `Change`. FlatBuffers only. The epic's `change_id_json` and
  `internal.serialization_failed` are **not** used.
- **No `extern "C"` outside `crates/zanshin-ffi/`** — `zanshin_change` lives in `zanshin-ffi/src/change.rs`.
- **No `zanshin-jj` change** — `Repo::get_change()` is Story 2.6; don't touch it, don't add `Serialize`.
- **No `Arc<Mutex>`/`RwLock`** around the handle (single-isolate, AD-2). `change` **borrows**, never drops.
- **C-string ownership:** Dart allocates + frees the `change_id`; Rust only borrows it for the call
  (AR-P-5 inbound). Never `free` it on the Rust side.
- **No regenerating `*_generated.*` / `zanshin_ffi.h` / `bindings.dart` outside `cargo make codegen`**;
  commit the generated diffs in the same PR. **Never hand-edit them.**
- **No `dart:ffi` outside `app/lib/src/ffi/`**; **no Flutter UI**; raw handles never leave the worker
  (Model A) — `zanshinChange(int, String)` is worker-only.
- **SPDX `MIT` first line** on every new hand-written `.rs`/`.dart` (`change.rs`, `change_ffi.rs`,
  `ffi/change.dart`, the two new test files). Generated files exempt.
- **Clippy pedantic `-D warnings`** — fix, don't `#[allow]`; any `#[allow]`/`unsafe`/`default-features =
  false` needs a `// WHY:`/`// SAFETY:`. `cargo fmt --check` (`max_width = 120` — the real value; the
  docs' "100" is a tracked drift).

### Project Structure Notes

- New files: `crates/zanshin-ffi/src/change.rs`, `crates/zanshin-ffi/tests/change_ffi.rs`,
  `app/lib/src/ffi/change.dart`, `app/test/worker/change_test.dart`, `app/test/ffi/change_test.dart`.
- Modified: `crates/zanshin-ffi/src/lib.rs` (`pub mod change;`), `crates/zanshin-ffi/src/envelope.rs`
  (`JJ_CHANGE_NOT_FOUND`), `schemas/envelope.fbs`, `docs/rust-error-codes.md`,
  `app/lib/src/worker/{commands.dart,isolate.dart,handle.dart}`, and the five committed codegen outputs.
- **Module-by-noun:** the wrapper goes in a new `change.rs` (mirrors `status.rs`; keeps `repo.rs`
  lifecycle-only). The literal epic AC text ("Given `crates/zanshin-ffi/src/repo.rs` … defines
  `zanshin_change`") is the pre-split monolithic 3.4 phrasing — superseded.
- **No `Cargo.toml` change:** `zanshin-ffi` already has `zanshin-jj` + the `tempfile`/`test-helpers`
  dev-deps (Story 3.4a). `flatbuffers` is already a dep.

### References

- [Source: _bmad-output/implementation-artifacts/3-4b-zanshin-status-ffi-wrapper.md] — **the authoritative
  pattern**: Rust wrapper/builder/error-mapping, codegen discipline, env-pinned integration harness, the
  full Dart seam (command/dispatch/adapter/decode/RepoHandle), the both-arms `map_*_err` test.
- [Source: _bmad-output/implementation-artifacts/2-6-implement-change-rs-change-metadata-read.md] — the
  upstream `Change`/`ChangeError`/`Signature`/`Timestamp`/`ConflictState`/`CommitId` shapes + decisions
  D1-D7 (read the **shipped** code, not just this story, per the HARD GATE).
- [Source: _bmad-output/implementation-artifacts/3-4a-repo-ffi-wrappers-…md] — the `cstr_to_string` C-string
  arg pattern + Dart `toNativeUtf8()`/`calloc.free` marshalling (the one structural deviation from status).
- [Source: docs/adr/0001-ffi-data-transport-flatbuffers.md] — FlatBuffers transport; lone string → CString.
- [Source: docs/adr/0002-repository-state-model-warm-loader-reload-per-operation.md] — `get_change` re-resolves to head per call.
- [Source: _bmad-output/project-context.md] — §FFI boundary (transport/ownership/Envelope), §Testing, §Critical Don't-Miss, §Logging.
- [Source: _bmad-output/planning-artifacts/epics.md#Story 3.4b (lines 2147-2249, JSON/`change_id_json` phrasing superseded)]; [#Story 2.6 (1292-1361)].
- [Source: crates/zanshin-ffi/src/{status.rs, repo.rs, envelope.rs, handle.rs, ffi_strings.rs, lib.rs}; schemas/envelope.fbs; crates/zanshin-ffi/tests/status_ffi.rs] — exact code to mirror.
- [Source: app/lib/src/ffi/{status.dart, repo.dart, ffi_buffer.dart}; app/lib/src/worker/{commands.dart, responses.dart, isolate.dart, handle.dart}; app/test/worker/status_test.dart; app/test/ffi/status_test.dart] — exact Dart to mirror.
- [Source: docs/rust-error-codes.md] — registry; add `jj.change_not_found`.

---

## Dev Agent Record

### Agent Model Used

Claude Sonnet 4.6 (1M context)

### Debug Log References

- `dart analyze --fatal-infos` caught 13 issues: comment_references on `[toNativeUtf8]`/`[calloc.free]`/compound-field references; `directives_ordering` (change.dart alphabetically before envelope_zanshin in isolate.dart); `avoid_redundant_argument_values` in tests; `specify_nonobvious_local_variable_types` in worker tests. All fixed.
- `codegen` run twice: once after schema edit (adds Change/Signature/ConflictState to generated files), then after new `extern "C"` symbol (adds `zanshin_change` to header + bindings.dart).

### Completion Notes List

- `schemas/envelope.fbs` — UPDATED: `table Signature`, `enum ConflictState`, `table Change` added; `Change` appended to `union Payload`; roadmap comment updated.
- `crates/zanshin-ffi/src/envelope.rs` — UPDATED: `JJ_CHANGE_NOT_FOUND` constant.
- `crates/zanshin-ffi/src/change.rs` — NEW: `map_change_err`, `signature_offset`, `change_to_envelope`, `zanshin_change` extern, unit tests.
- `crates/zanshin-ffi/src/lib.rs` — UPDATED: `pub mod change;`.
- `crates/zanshin-ffi/tests/change_ffi.rs` — NEW: 4 integration tests (round-trip, not-found, null ptr, zero handle).
- `docs/rust-error-codes.md` — UPDATED: `jj.change_not_found` row.
- `app/lib/src/ffi/change.dart` — NEW: `zanshinChange`, `Change`/`Signature`/`ConflictState` models, `decodeChangeEnvelope`/`decodeChangeEnvelopeInternal`.
- `app/lib/src/worker/commands.dart` — UPDATED: `GetChangeCommand`.
- `app/lib/src/worker/isolate.dart` — UPDATED: `repo_ffi_change` import, `GetChangeCommand` dispatch, `getChange()` method.
- `app/lib/src/worker/handle.dart` — UPDATED: `getChange()` method.
- `app/test/ffi/change_test.dart` — NEW: 4 decode-contract tests.
- `app/test/worker/change_test.dart` — NEW: 4 worker round-trip + guard tests.
- Generated (committed, never hand-edited): `envelope_generated.rs`, `envelope_zanshin.ffi_generated.dart`, `zanshin_ffi.h`, `bindings.dart`.
- `cargo make test` green end-to-end (Rust 63 unit + 4 change_ffi + 11 change jj + other suites; Dart 35 tests incl. 4 new change tests; dart analyze 0 issues).

### File List

- `schemas/envelope.fbs` (UPDATED)
- `crates/zanshin-ffi/src/envelope_generated.rs` (GENERATED)
- `crates/zanshin-ffi/src/envelope.rs` (UPDATED)
- `crates/zanshin-ffi/src/change.rs` (NEW)
- `crates/zanshin-ffi/src/lib.rs` (UPDATED)
- `crates/zanshin-ffi/include/zanshin_ffi.h` (GENERATED)
- `crates/zanshin-ffi/tests/change_ffi.rs` (NEW)
- `docs/rust-error-codes.md` (UPDATED)
- `app/lib/src/ffi/envelope_zanshin.ffi_generated.dart` (GENERATED)
- `app/lib/src/ffi/bindings.dart` (GENERATED)
- `app/lib/src/ffi/change.dart` (NEW)
- `app/lib/src/worker/commands.dart` (UPDATED)
- `app/lib/src/worker/isolate.dart` (UPDATED)
- `app/lib/src/worker/handle.dart` (UPDATED)
- `app/test/ffi/change_test.dart` (NEW)
- `app/test/worker/change_test.dart` (NEW)

### Change Log

| Date | Change |
|------|--------|
| 2026-06-23 | Story created (ready-for-dev) — `change` slice of 3.4b. Mirrors the done `status` slice; the one deviation is the lone-string `change_id` arg (cstr_to_string + Dart toNativeUtf8/calloc.free, borrowed from 3.4a). **Gated on Story 2.6 being `done`** (it exposes `Repo::get_change`, never adds it). `Change` FlatBuffers table + `jj.change_not_found` derived from 2.6's recommended defaults (is_signed presence-only, raw timestamps, divergent flag). |
| 2026-06-23 | Story 3.4b (change slice) implementiert (dev-story): FlatBuffers-Schema + Codegen + FFI-Wrapper + Dart-Bridge vollständig. cargo make test grün (Rust + Dart, 0 regressions). Status → review. |
| 2026-06-23 | Wire shape LOCKED — Ralph confirmed 2.6's defaults (is_signed presence-only, raw timestamps, divergent flag), so the `Change` table/builder above are final (re-check only if the shipped 2.6 code diverges). |

---

## Open Questions for Ralph (non-blocking — defaults chosen, override before dev if desired)

1. **Gate ordering.** This story is `ready-for-dev` but **hard-gated on Story 2.6 being `done`** (it only
   exposes `Repo::get_change`). I created both now because you asked for both. **Recommended:** dev 2.6
   first, then this. OK, or should this stay `backlog` until 2.6 lands?

2. **`Change` wire shape follows 2.6's decisions.** — ✅ **Locked 2026-06-23:** Ralph confirmed 2.6's
   defaults — `is_signed: bool` (presence-only), raw `timestamp_millis` + `tz_offset_minutes`, and
   `divergent: bool`. The `Change` table (AC-1) and builder (AC-2) above already reflect them; no
   reconciliation needed unless the shipped 2.6 code diverges (re-check at T0).

3. **`Signature` as a nested table vs. flattened fields.** I model `author`/`committer` as nested
   `Signature` tables (name/email/timestamp). The alternative is flattening
   (`author_name`/`author_email`/… on `Change`). **Recommended:** nested table (reusable, matches the
   domain struct, lets `op_log`/future nouns reuse `Signature`). Keep nested?

4. **Decode-time `divergent` surfacing.** The Dart `Change` model carries `divergent`/`isAnonymous`/
   `isSigned` straight through. The UI is out of scope, but the seam exposes them so Ralph's UI can act.
   **Recommended:** expose all three on the Dart model. OK?

---

## Review Findings — Code Review (2026-06-23)

_FFI/Dart items from the combined 2.6 + 3.4b adversarial review (61 agents; full method in the 2.6 story file). The `zanshin-jj` items — including the empty-`change_id` panic that surfaces **here** as `internal.panic` instead of the contracted `jj.change_not_found` — are in the 2.6 story file (the fix lives in `get_change`)._

### Patch

- [x] [Review][Patch] Dart worker real-cdylib round-trip asserts only presence, not value [app/test/worker/change_test.dart:51-59] — only `change.id` is value-checked; `description`/`author.name`/`committer.name` use `isNotNull` on **non-nullable** `String` (vacuously true). Violates the "assert EQUALITY vs an oracle" rule. **Fix:** assert `parents.first == status.parentChangeId`, `description == ''`, `isAnonymous == true`, and `author.name`/`email` == the env-pinned deterministic test user for the fresh-init WC commit.
- [x] [Review][Patch] `ffi.utf8_error` path of `zanshin_change` has no wrapper-level test [crates/zanshin-ffi/tests/change_ffi.rs] — the null-pointer arm IS tested, the invalid-UTF-8 arm is not (asymmetric); project rule is "cover ALL public error variants". **Fix:** add `change_invalid_utf8_change_id_returns_ffi_utf8_error` (CString with a lone `0x80`), mirroring `repo_ffi.rs:130`. _(Borderline: one verifier refuted it as covered by the shared `cstr_to_string` tests; the test is cheap and closes the asymmetry with the existing null test.)_
- [x] [Review][Patch] (optional — AC-18 tension) FFI real-wire round-trip never value-checks `conflict`/`divergent`/`is_signed`/`is_anonymous` [crates/zanshin-ffi/tests/change_ffi.rs:126-140] — these 4 fields are value-checked only on synthetic buffers / the domain struct, never on the real `get_change`→serializer→wire path. **AC-18 says "don't duplicate" the jj-lib computation**, so this is a judgment call. **Fix (if desired):** assert `conflict() == Clean`, `!divergent()`, `!is_signed()`, `is_anonymous()` on the fresh tiny-fixture WC payload.
- [x] [Review][Patch] (nit) Worker `getChange`/`status` doc says "Throws StateError **synchronously**" but the `async` method delivers it via the Future [app/lib/src/worker/isolate.dart:365] — pre-existing convention copied from `status()`. `RepoHandle.getChange` (handle.dart) genuinely throws synchronously and its doc is correct. **Fix:** reword the worker-level docs to "Completes with a [StateError] after [close]." (optionally `status()` too, for consistency).

### Defer

- [x] [Review][Defer] `ConflictState.fromValue` throws raw `StateError` (not `ZanshinFfiException`) on an out-of-range conflict byte [app/lib/src/ffi/change.dart] — deferred, **pre-existing**: identical to `status.dart`'s `ChangeKind.fromValue` / `PayloadTypeId.fromValue`; the path is unreachable in-process (Rust only writes 0/1) and the getter lives in committed generated code. Consistent-by-design.
