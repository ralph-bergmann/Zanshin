---
baseline_commit: 11c9621ca05dea369ad184e4dcf2acebb867401c
---

# Story 3.4a: Repo FFI wrappers — `zanshin_repo_open/init/clone/close`

Status: done

<!-- Note: Validation is optional. Run validate-create-story for quality check before dev-story. -->

## Story

As a Dart caller (the worker isolate),
I want `extern "C"` functions wrapping the Epic 2 `repo` path (open, init, clone, close) that return the FlatBuffers `Envelope` (ADR-0001),
so that I can open / init / clone a repository from Flutter as soon as the FFI infrastructure is in place — without waiting for the rest of the read path or the watcher.

---

## ⚠️ CRITICAL — Read this before writing any code (transport reconciliation)

The Story 3.4a acceptance criteria in `epics.md` (lines 2037–2079) were written **before ADR-0001** and describe the *old* JSON transport: a `*mut c_char` JSON envelope, `data = { "handle": "<hex ptr>" }`, and `jsonschema`-crate validation against `schemas/*.schema.json`. **All of that is superseded.** The authoritative transport is:

- **ADR-0001** (`docs/adr/0001-ffi-data-transport-flatbuffers.md`) — composite FFI data crosses as a **FlatBuffers** buffer, never JSON.
- **`project-context.md` `overrides:`** — explicitly retires "epics.md AR-AD-1/AR-AD-3 (JSON envelope + JSON Schemas as the FFI wire)".
- The **actual code** (Stories 3-0/3-1/3-2/3-3) already implements the FlatBuffers `Envelope`, the `catch` panic backstop, handle helpers, and the buffer-ownership token. Story 3.4a is the **first story that returns a composite payload across `extern "C"`** — it consumes that infrastructure; it does not reinvent it.

The newer **Story 3.4c** (added 2026-06-20, epics.md line 2083) already states the FlatBuffers-native shape and is the correct sibling model to follow. **Do NOT add `jsonschema`, do NOT emit `*mut c_char` JSON, do NOT invent a new envelope.** The reconciled, binding ACs are below.

Two phrasings even in the newer text are loose and are corrected here from the committed code:
- Return type is **`*mut ZanshinBuf`** (an owned token carrying `ptr`+`len`), **not** `*mut u8`. The Dart consumer is the existing `FfiBuffer.fromToken(Pointer<ZanshinBuf>)` (`app/lib/src/ffi/ffi_buffer.dart`), which attaches a `NativeFinalizer` → `zanshin_buffer_free_token`.
- Buffers are built with plain `b.finish(...)` (**not** size-prefixed) — the length travels in `ZanshinBuf.len`. Match the existing `ok_empty()` / `err()` builders exactly.

---

## Acceptance Criteria

1. **New module.** `crates/zanshin-ffi/src/repo.rs` is created and declared `pub mod repo;` in `lib.rs`. It defines `zanshin_repo_open`, `zanshin_repo_init`, `zanshin_repo_clone`, `zanshin_repo_close` as `#[no_mangle] pub unsafe extern "C"` functions. Each function body is wrapped in `envelope::catch(|| { ... })` (Story 3.1) so no panic crosses the C ABI.

2. **`zanshin-jj` dependency wired.** `crates/zanshin-ffi/Cargo.toml` gains `zanshin-jj = { workspace = true }` (the crate currently has **no** dependency on it). This is the only crate besides the `zanshin-mcp` binary allowed to consume `zanshin-jj`.

3. **Return ABI (all four functions).** Each function returns `*mut ZanshinBuf` produced by `ffi_strings::vec_into_token(buf)`, where `buf` is a finished FlatBuffers `Envelope` `Vec<u8>`. On the success path the returned envelope is `ok == true`; on the error path `ok == false` with `error.code` + `error.context`. **No NULL-plus-out-of-band-error pattern** — every outcome is a well-formed envelope token (a panic in token construction is impossible because `catch` returns the `Vec<u8>` before `vec_into_token` runs; if `vec_into_token` itself ever returns a null token that is an allocation abort, not a recoverable path).

4. **Handle payload in the schema.** `schemas/envelope.fbs` gains a payload table carrying the repo handle and adds it to the `Payload` union; the `Empty` placeholder table is removed (its doc comment already says "Remove when the first real Payload member is added (Story 3-4a)"). Recommended shape:
   ```fbs
   /// Opaque handle to an open Repo. `handle` is the Rust `*mut Repo` reinterpreted
   /// as an unsigned integer; Dart passes it back verbatim to zanshin_repo_close.
   table RepoHandle { handle: ulong; }
   union Payload { RepoHandle }
   ```

5. **`zanshin_repo_open(path: *const c_char) -> *mut ZanshinBuf`.** With a valid jj repo path it returns a success envelope whose `Payload` is `RepoHandle { handle }`, where `handle = handle::handle_into_raw(repo) as u64`. The watcher is **NOT** armed (see AC-11).

6. **`zanshin_repo_open` error paths.** Invalid / non-repo / missing path returns `ok:false` with a defined code — never a crash, never NULL:
   - path does not exist on disk → `jj.path_not_found`
   - path exists but is not a jj repo → `jj.repo_not_found`
   - null/invalid-UTF-8 `path` pointer → `ffi.null_pointer` / `ffi.utf8_error` (from `cstr_to_string`)

7. **`zanshin_repo_init(path: *const c_char, backend: i32) -> *mut ZanshinBuf`.** In an empty directory it initializes a repo and returns a `RepoHandle` envelope. `backend` maps: `0 → None` (jj native/simple backend), `1 → Some(Backend::Git)`. Calling `init` again at the same location returns a defined error code (`jj.jj_lib_error`, reason in `context`) — **no panic**. An out-of-range `backend` value returns `ffi.invalid_argument` (new code — add to the registry, AC-12) rather than silently defaulting. **(Decided 2026-06-20.)**

8. **`zanshin_repo_clone(url: *const c_char, target_path: *const c_char) -> *mut ZanshinBuf`.** Called with a local `file://` source fixture into a temp target, it returns a `RepoHandle` envelope. A clone failure returns `jj.jj_lib_error` (reason in `context`) and leaves no usable partial workspace (the rollback is already implemented inside `zanshin-jj::Repo::clone`). **No network access in tests.**

9. **`zanshin_repo_close(handle: u64) -> *mut ZanshinBuf`.** Takes the raw handle integer, reconstructs the pointer, and drops the `Box<Repo>` via `handle::handle_drop` (Story 3.2). Returns a no-payload success envelope (`ok_empty()`) on success.

10. **`zanshin_repo_close` invalid handle.** A `handle` of `0` (null) returns `ffi.invalid_handle` (no panic). **Scope note:** `handle == 0` is the *only* defined-detectable invalid handle — there is no handle table (AD-2: raw `Box` pointers, single isolate). Double-close of the *same non-zero* value is a use-after-free that the Rust layer cannot and must not try to detect; that contract is owned by the Dart side (null the local handle after `close`; `NativeFinalizer` fires at most once). The integration test for "close twice / unknown handle" therefore asserts on `close(0)` and never re-passes a freed non-zero pointer. **(Decided 2026-06-20: scope to `close(0)`; double-free protection is the Dart contract — no handle table.)**

11. **Watcher NOT armed.** `zanshin_repo_open` does not start a filesystem watcher. Watcher arming lands later in Story 3.5 as an internal-only change to `repo_open`'s body — the `extern "C"` signature is unchanged, so no codegen / caller rework results. (Load-bearing assumption of the 2026-06-15 re-sequencing.)

12. **Error registry updated.** `docs/rust-error-codes.md` flips `jj.repo_not_found`, `jj.path_not_found`, `jj.jj_lib_error` from `Reserved — Story 3.4a` to `Emitted — Story 3.4a`, annotated with the emitting module (`repo.rs`). Any new code introduced (e.g. `ffi.invalid_argument` for AC-7) is added to the registry in the same PR.

13. **Codegen committed.** `cargo make codegen` is run and the regenerated files are committed in the **same PR**: `schemas/envelope.fbs` (source), `crates/zanshin-ffi/src/envelope_generated.rs`, `app/lib/src/ffi/envelope_zanshin.ffi_generated.dart`, `crates/zanshin-ffi/include/zanshin_ffi.h`, and `app/lib/src/ffi/bindings.dart`. The header/bindings contain the four `zanshin_repo_*` functions. **Never hand-edit generated files.**

14. **Integration tests** in `crates/zanshin-ffi/tests/repo_ffi.rs`: for each of open/init/clone/close, a success case and an error case. Each test reads the returned buffer **through the generated typed accessors** (`fbs::Envelope`, `env.data_as_repo_handle()`) and runs the **FlatBuffers `Verifier`** (`flatbuffers::root::<fbs::Envelope>` / `root_with_opts`). **No `jsonschema`. No hand-parsing of bytes.** A wrong-shape payload must be a compile error, not a runtime assert.

15. **Panic backstop proven.** A forced panic inside a wrapper body (triggered in a test, e.g. via a test-only seam) returns `ok:false, error.code == "internal.panic"` — proving no panic crosses the boundary.

16. **Quality gate green.** `cargo make test` passes: `clippy --pedantic -D warnings`, `cargo fmt --check`, all Rust unit + integration tests, `cargo deny check advisories bans`. Every `unsafe` block carries a `// SAFETY:` comment; every `unsafe fn` carries a `# Safety` doc section; no `#[allow]` without a `// WHY:`.

---

## Tasks / Subtasks

- [x] **T1 — Wire the dependency** (AC: 2)
  - [x] Add `zanshin-jj = { workspace = true }` to `crates/zanshin-ffi/Cargo.toml` `[dependencies]`. Added `zanshin-jj = { path = "crates/zanshin-jj", version = "0.1.0" }` to `[workspace.dependencies]` first.
  - [x] Add `[dev-dependencies]` to `crates/zanshin-ffi/Cargo.toml`: `tempfile = { workspace = true }` and `test-helpers = { path = "../test-helpers" }` (fixture extraction — mirror `crates/zanshin-jj/Cargo.toml`).

- [x] **T2 — Extend the wire schema** (AC: 4, 13)
  - [x] Edit `schemas/envelope.fbs`: add `table RepoHandle { handle: ulong; }`, set `union Payload { RepoHandle }`, delete the `Empty` placeholder table.
  - [x] Run `cargo make codegen`. Verified `envelope_generated.rs` exposes `RepoHandle`, `RepoHandleArgs`, `Payload::RepoHandle`, and `Envelope::data_as_repo_handle()`.

- [x] **T3 — Success-payload builder** (AC: 3, 5)
  - [x] Added `pub fn ok_repo_handle(handle: u64) -> Vec<u8>` to `envelope.rs` + new error-code constants (`JJ_PATH_NOT_FOUND`, `JJ_REPO_NOT_FOUND`, `JJ_JJ_LIB_ERROR`, `FFI_INVALID_ARGUMENT`). Added `ok_repo_handle_produces_repo_handle_envelope` test.

- [x] **T4 — Error mapping helper** (AC: 6, 7, 8, 12)
  - [x] Added private `fn map_repo_err(e: RepoError) -> FfiErrorObj` in `repo.rs`.
  - [x] Flipped `jj.repo_not_found`, `jj.path_not_found`, `jj.jj_lib_error` in `docs/rust-error-codes.md` to Emitted — Story 3.4a. Added `ffi.invalid_argument`.

- [x] **T5 — The four `extern "C"` functions** (AC: 1, 3, 5, 6, 7, 8, 9, 10, 11)
  - [x] `zanshin_repo_open`, `zanshin_repo_init`, `zanshin_repo_clone`, `zanshin_repo_close` implemented in `crates/zanshin-ffi/src/repo.rs`. Added `pub mod repo;` to `lib.rs`. All wrapped in `catch`. `debug!` spans per call.

- [x] **T6 — Regenerate the FFI surface** (AC: 13)
  - [x] Ran `cargo make codegen` twice (after schema change, after extern "C" symbols). All five artifacts regenerated: `envelope_generated.rs`, `envelope_zanshin.ffi_generated.dart`, `zanshin_ffi.h`, `bindings.dart`.

- [x] **T7 — Integration tests** (AC: 14, 15)
  - [x] Created `crates/zanshin-ffi/tests/repo_ffi.rs` with `LazyLock` env-pin, `read_and_free`/`parse_envelope` helpers.
  - [x] open: success (tiny fixture), path-not-found, repo-not-found, null-pointer.
  - [x] init: native+open round-trip, git+open round-trip, init-twice error, invalid-backend error.
  - [x] clone: local file:// success, invalid URL error.
  - [x] close: valid handle success (NONE payload), close(0) → ffi.invalid_handle.
  - [x] panic: `catch_panic_in_envelope_catch_returns_internal_panic` proves `internal.panic` via seam.

- [x] **T8 — Gate** (AC: 16)
  - [x] `cargo make test` green: 52 unit tests + 13 integration tests + clippy pedantic -D warnings + cargo fmt --check + cargo deny advisories bans.

---

## Dev Notes

### What you are building on (exact, verified signatures)

**`zanshin-jj` public API** (`crates/zanshin-jj/src/repo.rs`, re-exported from `lib.rs` as `Backend, Repo, RepoError`):
```rust
impl Repo {
    pub fn open(path: &Path) -> Result<Self, RepoError>;
    pub fn init(path: &Path, backend: Option<Backend>) -> Result<Self, RepoError>;
    pub fn clone(url: &str, target_path: &Path) -> Result<Self, RepoError>;
    pub fn workspace_root(&self) -> &Path;
}
pub enum Backend { Git }                 // Some(Git) = git backend; None = jj native/simple
pub enum RepoError {                      // thiserror; Display is the human reason
    PathNotFound { path: PathBuf },
    NotARepo     { path: PathBuf },
    InitFailed   { reason: String },
    CloneFailed  { reason: String },
    Backend(String),                     // flattened jj-lib error
}
```
- `Repo::clone` already rolls back partial state on failure (deletes the dir it created, or just `.jj/` if the target pre-existed). The FFI layer does **not** add rollback.
- `Repo` has no custom `Drop`; dropping the `Box<Repo>` releases the jj `Workspace`. Confirmed leak-free over 100 open/drop cycles by `zanshin-jj`'s existing test.

**`zanshin-ffi` infrastructure you MUST reuse (do not reinvent):**
```rust
// envelope.rs  (Story 3-0/3-1) — all return finished Vec<u8>; build with plain b.finish (NOT size-prefixed)
pub fn ok_empty() -> Vec<u8>;
pub fn err(code: &str, context: Option<&str>) -> Vec<u8>;
pub fn catch<F: FnOnce() -> Result<Vec<u8>, FfiErrorObj> + UnwindSafe>(f: F) -> Vec<u8>;
pub struct FfiErrorObj { pub code: String, pub context: Option<String> }
pub const INTERNAL_PANIC; FFI_INVALID_HANDLE; FFI_NULL_POINTER; FFI_UTF8_ERROR;  // &str consts

// handle.rs  (Story 3-2)
pub fn handle_into_raw<T>(value: T) -> *mut T;                      // Box::into_raw — leaks to Dart
pub unsafe fn handle_from_raw<'a, T>(ptr: *mut T) -> Option<&'a mut T>;
pub unsafe fn handle_drop<T>(ptr: *mut T);                          // null-guarded; reclaims + drops Box
pub fn validate_handle<T>(ptr: *mut c_void) -> Result<*mut T, FfiErrorObj>;  // NULL-only check

// ffi_strings.rs  (Story 3-2/3-0)
pub unsafe fn cstr_to_string(ptr: *const c_char) -> Result<String, FfiErrorObj>;  // null→ffi.null_pointer, bad utf8→ffi.utf8_error
pub fn vec_into_token(buf: Vec<u8>) -> *mut ZanshinBuf;             // <-- USE THIS for the return value
#[repr(C)] pub struct ZanshinBuf { pub ptr: *mut u8, pub len: usize }
pub unsafe extern "C" fn zanshin_buffer_free_token(token: *mut ZanshinBuf);   // the matching free (Dart side)
pub fn vec_into_ffi_buf(buf: Vec<u8>) -> (*mut u8, usize);         // alt ptr+len path (used in unit tests/free-by-len)
pub unsafe extern "C" fn zanshin_buffer_free(ptr: *mut u8, len: usize);
```

**The exact success-builder to add** (T3), modeled on the committed `ok_empty()`:
```rust
#[must_use]
pub fn ok_repo_handle(handle: u64) -> Vec<u8> {
    let mut b = FlatBufferBuilder::with_capacity(128);
    let h = fbs::RepoHandle::create(&mut b, &fbs::RepoHandleArgs { handle });
    let envelope = fbs::Envelope::create(&mut b, &fbs::EnvelopeArgs {
        ok: true,
        error: None,
        data_type: fbs::Payload::RepoHandle,
        data: Some(h.as_union_value()),
    });
    b.finish(envelope, None);          // plain finish — length carried by ZanshinBuf.len
    b.finished_data().to_vec()
}
```

### The handle is an integer across the wire (not a pointer arg, not a hex string)

The old AC said `data = { "handle": "<hex ptr>" }` (a JSON string). With FlatBuffers the handle is a `ulong` field = `handle_into_raw(repo) as u64`. `zanshin_repo_close` takes that same `u64` back (`handle: u64`, reconstruct via `handle as *mut Repo`). This keeps the success path inside the envelope (AC-3: no NULL-plus-out-of-band-error) and keeps `close`'s signature a plain scalar in / envelope out. Dart stores the int, passes it back, and nulls its copy after `close`.

### Why `close` cannot detect double-close (AD-2) — and what the test must do

`validate_handle` only null-checks; there is **no handle table** by architecture (AD-2: raw `Box` pointers, single worker isolate). Therefore:
- `close(0)` → `ffi.invalid_handle` ✅ detectable.
- `close(<stale non-zero>)` → **undefined behavior** (use-after-free). The Rust layer must not attempt to detect it (a table would violate AD-2 and the single-isolate concurrency model). Protection is the Dart contract: null the handle after `close`, and `NativeFinalizer` fires at most once.
- The "close twice / unknown handle" AC (AC-10) is satisfied by testing `close(0)`. **Never write a Rust test that re-passes a freed non-zero pointer** — it would be UB and may pass or crash nondeterministically (this is exactly the kind of test the project bans: "either deterministic or deleted").

This was confirmed spec-mandated in the Story 3.2 review (the "`validate_handle` only null-checks" finding was dismissed as AD-2 by-design). See Open Questions Q2 if you believe a stronger guarantee is wanted.

### Panic-seam pattern (AC-15)

`catch` already converts panics to `internal.panic`; you just need a deterministic way to trigger one inside a wrapper from a test. Cleanest: a `#[cfg(test)]`-gated env/`thread_local` check, or factor the wrapper body into an inner `fn repo_open_inner(p: &str) -> Result<Vec<u8>, FfiErrorObj>` and add a `#[cfg(test)] pub` thin wrapper that `panic!()`s, then assert `catch(|| panic!("x"))`-style at the boundary. Mirror the existing `catch_panic_macro_captures_str_message` test in `envelope.rs` for the assertion shape (`error.code == INTERNAL_PANIC`). Do not ship a production code path that can panic just to test the backstop.

### Tracing / logging

- Add a `tracing` span or `debug!` per FFI call (`fn_name`, and later `handle_id`) per the Logging discipline. These are no-ops until tracing is initialized.
- **Do NOT call `init_tracing()` from `repo_open`.** Tracing init is owned by `zanshin_logging_init()` (already an `extern "C"` in `logging.rs`, idempotent via `Once`) and the Story 3.9 worker bootstrap. Coupling repo-open to tracing-init is the wrong layer. (The Story 3-3 note "3-9/3-4a call it" predates the dedicated `zanshin_logging_init` entry point; that entry point is now the answer.) **(Decided 2026-06-20: no tracing-init in repo_open; spans only.)**

### Testing standards (project-context Testing Rules)

- Integration tests in `crates/zanshin-ffi/tests/repo_ffi.rs` (this crate's `tests/` dir; `use zanshin_ffi::...`).
- **Pin `JJ_CONFIG` and `GIT_CONFIG_GLOBAL`** to empty (copy the `LazyLock` `ENV_GUARD` + `pin_env()` from `crates/zanshin-jj/tests/repo.rs`) so results are identical on CI and locally.
- Fixtures: `test-helpers::extract_fixture("tiny-3-commits")` → `FixtureHandle { path, _temp }`. Use `tiny-3-commits` (open). For clone, create a `file://` local git source the way `zanshin-jj/tests/repo.rs::repo_clone_from_local_git_source_returns_ok` does (fixture-setup scripts may shell out to `git`; **production code may not**). No network, ever.
- Read every buffer through generated typed accessors + the FlatBuffers `Verifier`. `flatbuffers::root::<fbs::Envelope>(bytes)` runs verification and returns `Result`; `.expect(...)` it in tests. `env.data_as_repo_handle()` returns `Option<RepoHandle>`. Test naming describes the scenario: `repo_open_with_invalid_path_returns_repo_not_found`.
- Free every token you create in a test (`zanshin_buffer_free_token`) so the suite is leak-clean.

### Hard guardrails (reject-on-sight — from project-context Critical Don't-Miss)

- **No JSON on the FFI wire.** No `serde_json`, no `jsonschema`, no `*mut c_char` envelope. FlatBuffers only.
- **No `extern "C"` outside `crates/zanshin-ffi/`.** This story's symbols live in `zanshin-ffi/src/repo.rs` only.
- **No shelling to `jj`** in production code (test fixture setup may shell to `git`).
- **No `Arc<Mutex>`/`RwLock`** around handles (single-isolate, AD-2).
- **No regenerating `bindings.dart`/`zanshin_ffi.h`/`*_generated.*` outside `cargo make codegen`.** Commit generated diffs in the same PR.
- **No Flutter UI / hand-written Dart wrapper logic.** Scope = Rust `extern "C"` + regenerated bindings. `FfiBuffer` already exists; the worker isolate that calls these is Story 3.9.
- **SPDX first line** (`// SPDX-License-Identifier: MIT`) on every new hand-written `.rs` (`repo.rs`, `repo_ffi.rs`). Generated files are exempt.
- Clippy `pedantic` is crate-wide and `-D warnings`. **Fix, don't `#[allow]`** (and any `#[allow]`/`unsafe`/`default-features=false` needs a `// WHY:`/`// SAFETY:` comment).

### Project Structure Notes

- New files: `crates/zanshin-ffi/src/repo.rs`, `crates/zanshin-ffi/tests/repo_ffi.rs`. Modified: `crates/zanshin-ffi/src/lib.rs` (`pub mod repo;`), `crates/zanshin-ffi/src/envelope.rs` (`ok_repo_handle`), `crates/zanshin-ffi/Cargo.toml`, `schemas/envelope.fbs`, `docs/rust-error-codes.md`, and the five committed codegen outputs.
- Module-by-noun convention holds: the repo wrappers go in `repo.rs` (not `ffi.rs`/`api.rs`). Matches `architecture.md` FFI module layout (`lib.rs`, `envelope.rs`, `handle.rs`, `ffi_strings.rs`, then one file per noun).
- Naming: `zanshin_<noun>_<verb>` snake_case; every `_open`/`_init`/`_clone` has the matching `_close`.

### References

- [Source: docs/adr/0001-ffi-data-transport-flatbuffers.md] — FlatBuffers transport; supersedes the JSON envelope (AD-1/AD-3/AD-4).
- [Source: _bmad-output/project-context.md#FFI boundary] — transport rule, ownership, Envelope shape, codegen-committed discipline, `overrides:` retiring AR-AD-1/AR-AD-3.
- [Source: _bmad-output/planning-artifacts/epics.md#Story 3.4a] (lines 2029–2079, JSON phrasing superseded) and [#Story 3.4c] (lines 2083–2127, correct FlatBuffers-native sibling model).
- [Source: crates/zanshin-ffi/src/envelope.rs] — `ok_empty`/`err`/`catch`/`FfiErrorObj`/consts (builder pattern to copy).
- [Source: crates/zanshin-ffi/src/handle.rs] — `handle_into_raw`/`handle_from_raw`/`handle_drop`/`validate_handle`.
- [Source: crates/zanshin-ffi/src/ffi_strings.rs] — `cstr_to_string`/`vec_into_token`/`ZanshinBuf`/`zanshin_buffer_free_token`.
- [Source: schemas/envelope.fbs] — `Envelope`/`FfiError`/`Payload` union (extend with `RepoHandle`; remove `Empty`).
- [Source: crates/zanshin-jj/src/repo.rs] — `Repo::open/init/clone`, `Backend`, `RepoError`.
- [Source: crates/zanshin-jj/tests/repo.rs] — env-pinning + fixture + `file://` clone test patterns to mirror.
- [Source: docs/rust-error-codes.md] — `jj.repo_not_found`/`jj.path_not_found`/`jj.jj_lib_error` (Reserved → flip to Emitted).
- [Source: Makefile.toml#tasks.codegen] — `cargo make codegen` = flatc-rust + flatc-dart + cbindgen + ffigen (one command regenerates all five outputs).
- [Source: app/lib/src/ffi/ffi_buffer.dart] — `FfiBuffer.fromToken(Pointer<ZanshinBuf>)` consumer (confirms the token return ABI).
- Previous-story learnings: [3-1] full panic-backstop hardening + registry; [3-2] handle helpers, build.rs, `const char* → char*` codegen churn is normal; [3-3] `init_tracing` idempotent, unwired.

---

## Dev Agent Record

### Agent Model Used

claude-sonnet-4-6

### Debug Log References

1. **Unused import `err`** — removed from the `envelope::` use statement in `repo.rs`; the `err()` builder is not called directly in the four wrappers (only via `FfiErrorObj` + `catch`).
2. **Integration tests "cannot find crate `zanshin_ffi`"** — Cargo 1.95 does not produce an implicit rlib when `crate-type = ["staticlib", "cdylib"]`. Fixed by adding `"lib"` to the list and adding `pub use envelope_generated::zanshin::ffi as fbs;` to `lib.rs` for test access.
3. **UB in first `consume_token` helper** — original returned `fbs::Envelope<'static>` that borrowed from freed memory (called `zanshin_buffer_free_token` then returned the `Envelope`). Fixed by splitting into `read_and_free() -> Vec<u8>` (copies bytes, frees token) + `parse_envelope(&[u8]) -> fbs::Envelope<'_>` (caller holds Vec for lifetime).
4. **`doc_markdown` clippy errors** — "FlatBuffers" must be in backticks in doc comments. Fixed in `lib.rs` (1), `repo.rs` (1), `tests/repo_ffi.rs` (2).
5. **`cargo fmt --check` failure** — `cargo fmt --all` applied to format `repo.rs` and `tests/repo_ffi.rs`.
6. **`cargo deny` wildcard/unresolved-workspace-dependency** — `zanshin-jj` workspace dep had no `version`. Fixed by adding `version = "0.1.0"` to root `Cargo.toml`.

### Completion Notes List

- All 16 ACs satisfied. `cargo make test` green: 52 unit tests + 13 integration tests, clippy pedantic `-D warnings`, `cargo fmt --check`, `cargo deny check advisories bans`.
- `schemas/envelope.fbs`: replaced `Empty` placeholder with `RepoHandle { handle: ulong }` union member. `codegen` run twice (after schema change, after extern "C" symbols added).
- Every `extern "C"` body wrapped in `envelope::catch`; every `unsafe` block carries `// SAFETY:` and every `unsafe fn` carries `# Safety` doc section.
- Error constants follow AR-P-4 single-emission-point rule: all live in `envelope.rs`, referenced by name in `repo.rs`.
- `crate-type = ["lib", "staticlib", "cdylib"]` — "lib" required for integration tests; documented with `// WHY:` comment.
- `verify-codegen` deferred to CI gate; run locally to confirm no drift before this review.

### File List

**New files:**
- `crates/zanshin-ffi/src/repo.rs`
- `crates/zanshin-ffi/tests/repo_ffi.rs`

**Modified files:**
- `Cargo.toml` — added `zanshin-jj = { path = "crates/zanshin-jj", version = "0.1.0" }` to `[workspace.dependencies]`
- `crates/zanshin-ffi/Cargo.toml` — `crate-type` + `zanshin-jj` dep + `[dev-dependencies]`
- `crates/zanshin-ffi/src/lib.rs` — `pub mod repo;`, `pub use envelope_generated::zanshin::ffi as fbs;`
- `crates/zanshin-ffi/src/envelope.rs` — `ok_repo_handle` builder + 4 new error-code constants + test
- `schemas/envelope.fbs` — `RepoHandle` table, `union Payload { RepoHandle }`, removed `Empty`
- `docs/rust-error-codes.md` — 3 rows flipped to Emitted, `ffi.invalid_argument` added

**Regenerated (committed, not hand-edited):**
- `crates/zanshin-ffi/src/envelope_generated.rs`
- `crates/zanshin-ffi/include/zanshin_ffi.h`
- `app/lib/src/ffi/bindings.dart`
- `app/lib/src/ffi/envelope_zanshin.ffi_generated.dart`

### Change Log

| Date | Change |
|------|--------|
| 2026-06-20 | Story created (ready-for-dev) |
| 2026-06-20 | Implementation started (in-progress), baseline_commit: 11c9621 |
| 2026-06-21 | All tasks T1–T8 complete, cargo make test green (65 tests), status → review |

---

## Review Findings

### Code Review (2026-06-21)

3 review layers (Blind Hunter / Edge Case Hunter / Acceptance Auditor). All 16 ACs PASS by inspection (AC-16 gate re-run separately). 2 patch, 1 defer, 15 dismissed.

**Patch (action items — hardening beyond the AC-14 minimum, which is met):**

- [x] [Review][Patch] Add null-pointer tests for `zanshin_repo_init` and `zanshin_repo_clone` — only `zanshin_repo_open(null)` is tested. `clone` has *two* independent `cstr_to_string` checks; the `target_path`-null branch only triggers when `url` is valid, so it needs `(valid url, null target)` to be exercised. [crates/zanshin-ffi/tests/repo_ffi.rs] — **fixed** (added `repo_init_null_pointer_*`, `repo_clone_null_url_*`, `repo_clone_null_target_*`).
- [x] [Review][Patch] Add an invalid-UTF-8 input test for at least one wrapper — each of `open`/`init`/`clone` docstrings promises `ffi.utf8_error`, but no wrapper-level test feeds a non-UTF-8 C string (only `ffi_strings.rs` unit-tests `cstr_to_string` directly). [crates/zanshin-ffi/tests/repo_ffi.rs] — **fixed** (added `repo_open_invalid_utf8_path_returns_utf8_error`).

**Deferred (pre-existing / out of scope for this diff):**

- [x] [Review][Defer] Clone rollback may delete a pre-existing `target/.jj` on failure when the target dir already existed → potential data loss [crates/zanshin-jj/src/repo.rs] — deferred, pre-existing. Rollback is owned by `zanshin-jj::Repo::clone` per AC-8 ("FFI layer does not add rollback"); not in this diff. `created_dir = !target_path.exists()` keys on whole-dir pre-existence, not `.jj` pre-existence, so a failed clone into an existing repo could remove its `.jj`. Verify in `zanshin-jj` and add a "clone into populated/existing target" test.

**Notes (dismissed, but worth recording):**

- The `cargo make codegen` run swept a *pre-existing* logging-doc delta ("…rotating file plus the always-on console layer") into the regenerated `zanshin_ffi.h` / `bindings.dart`. Not drift: source (`logging.rs:79`, `tracing_init.rs`) was already at HEAD; only its committed bindings were stale. Generated now matches source. Unrelated to story 3.4a — bundled because codegen regenerates wholesale. No action (solo-project, direct-to-main).
- 32-bit handle truncation (`handle as *mut Repo`): N/A — project is macOS-only (64-bit only).
- `close` cannot detect stale/double-close of a non-zero handle: by design (AD-2, AC-10); spec explicitly forbids both detection and a re-pass-freed-pointer test.
