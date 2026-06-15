# Story 3.2: Handle module + `ffi_strings` (input direction) + `zanshin_ffi_version`

---
baseline_commit: 5d7577e
---

Status: done

> **⚠️ Scope-correction (binding — [ADR-0001](../../docs/adr/0001-ffi-data-transport-flatbuffers.md) + the 3-0/3-1 re-sequencing, 2026-06-15):**
> The epic's Story 3.2 text (`epics.md:1699`) predates ADR-0001 and Stories **3-0/3-1**. Three of its
> deliverables **already exist** and must **not** be re-created:
> - **`crates/zanshin-ffi/src/ffi_strings.rs` already exists** (landed in 3-0). It already contains
>   `string_to_cstring`, `zanshin_string_free`, and the whole `FlatBuffers` buffer-ownership contract
>   (`vec_into_ffi_buf`, `vec_into_token`, `ZanshinBuf`, `zanshin_buffer_free`,
>   `zanshin_buffer_free_token`) — all tested. **3.2 only ADDS the input-direction helper
>   `cstr_to_string`** to that file. Do **not** touch the existing functions.
> - **`crates/zanshin-ffi/src/envelope.rs` already exists** (landed in 3-1) with `FfiErrorObj`,
>   `ok_empty`, `err`, `catch`, and `INTERNAL_PANIC`. The epic's `ErrorObj` is this **`FfiErrorObj`**.
> - **`docs/rust-error-codes.md` already exists** (landed in 3-1) with the three `ffi.*` codes already
>   listed as *"Reserved — Story 3.2"*. 3.2 **flips them to "Emitted — Story 3.2"**; it does not create
>   the registry.
>
> What 3.2 actually delivers: **(1)** the net-new `handle.rs` (`Box<T> ↔ *mut T` helpers +
> `validate_handle`); **(2)** `ffi_strings::cstr_to_string` (C-string → `String`, the input direction);
> **(3)** the three `ffi.*` error-code `pub const`s in `envelope.rs` (AR-P-4 single-emission-point);
> **(4)** the real `zanshin_ffi_version()` (heap `*mut c_char` = `"<version> (<git-sha>)"`) plus a
> `build.rs` that injects `ZANSHIN_GIT_SHA`; **(5)** the registry flip; **(6)** the regenerated,
> committed `zanshin_ffi.h` + `bindings.dart` — because the version-symbol signature changes.

---

## Story

As a Rust developer implementing the FFI surface,
I want `crates/zanshin-ffi/src/handle.rs` (`Box<T> ↔ *mut T` helpers + a `validate_handle` guard), an
input-direction `cstr_to_string` helper in the existing `ffi_strings.rs`, and a real
`zanshin_ffi_version()` build-stamp entry point backed by a `build.rs` git-SHA injection,
so that the first handle-owning FFI wrappers (Story **3.4a** `zanshin_repo_open`/`_close`) have clean,
safe, single-source handle and string-marshalling helpers, and Dart has a working version handshake
(FR-FFI-10, AR-AD-2).

**This story sits on top of Stories 3-0 and 3-1.** Read
`_bmad-output/implementation-artifacts/3-0-adopt-flatbuffers-ffi-transport.md` and
`_bmad-output/implementation-artifacts/3-1-ffi-core-envelope-error-codes-panic-catch.md` first — they
built `ffi_strings.rs`, `envelope.rs`, and the error-code registry this story extends.

---

## Acceptance Criteria

> These criteria **reconcile** the epic's Story 3.2 GWT (`epics.md:1699`) with the post-3-0/3-1 reality.
> Where the epic names a JSON-era type (`ErrorObj`) or a file as "create" that already exists, the
> reconciled wording below is binding. The behavioural requirements (FR-FFI-10 version handshake,
> structured `ffi.*` errors, `Box` handle ownership per AR-AD-2) are unchanged from the epic.

### AC-1 — `handle.rs` (new) — `Box<T> ↔ *mut T` helpers + `validate_handle`

1. `crates/zanshin-ffi/src/handle.rs` is **created**, starts with `// SPDX-License-Identifier: Apache-2.0` on the **first line**, and is declared `pub mod handle;` in `lib.rs` (AR-P-3 module layout).
2. It provides `#[must_use] pub fn handle_into_raw<T>(value: T) -> *mut T` = `Box::into_raw(Box::new(value))` (boxes the value and leaks it as a raw pointer; this is the `zanshin_X_open` half of AD-2's lifecycle pair).
3. It provides `pub unsafe fn handle_from_raw<'a, T>(ptr: *mut T) -> Option<&'a mut T>` returning `Some(&mut T)` for a non-null `ptr` and `None` for null. Implement it as `unsafe { ptr.as_mut() }` (idiomatic, null-checked) — **not** the epic's literal `&'static mut`; an unbounded-but-call-scoped lifetime is correct and avoids minting a bogus `'static`. A `# Safety` doc-comment states the invariant: caller must pass a pointer from `handle_into_raw` (or null), and must not create two live `&mut` to the same handle at once (the single-threaded worker isolate guarantees this — AD-2).
4. It provides `pub unsafe fn handle_drop<T>(ptr: *mut T)` that reconstructs the `Box` (`Box::from_raw`) and drops it (the `zanshin_X_close` half). It is a **no-op on null** (`if ptr.is_null() { return; }`), and its `# Safety` doc states that a non-null pointer must come from `handle_into_raw` and must not be double-dropped (double-drop is UB at the C ABI; Dart's `NativeFinalizer` detach-then-close pattern in a later story prevents it from Dart).
5. It provides `pub fn validate_handle<T>(ptr: *mut c_void) -> Result<*mut T, FfiErrorObj>`: returns `Err(FfiErrorObj { code: FFI_INVALID_HANDLE.to_owned(), context: None })` when `ptr` is null, otherwise `Ok(ptr.cast::<T>())`. This is a **safe** fn (cast only, no deref); typestate (which `T`) comes from the API surface, not from runtime. `FfiErrorObj`, `FFI_INVALID_HANDLE` are imported from `crate::envelope`.

### AC-2 — `ffi_strings::cstr_to_string` (input direction) added — existing functions untouched

6. The **existing** `crates/zanshin-ffi/src/ffi_strings.rs` gains `pub unsafe fn cstr_to_string(ptr: *const c_char) -> Result<String, FfiErrorObj>` that:
   - returns `Err(FfiErrorObj { code: FFI_NULL_POINTER.to_owned(), context: None })` on null;
   - returns `Err(FfiErrorObj { code: FFI_UTF8_ERROR.to_owned(), context: None })` on invalid UTF-8;
   - otherwise returns `Ok(String)` (an owned copy of the C string's contents).
   Implement via `CStr::from_ptr(ptr)` + `.to_str()`; a `# Safety` doc states `ptr` must be null or a valid NUL-terminated C string that stays valid for the call.
7. The pre-existing `string_to_cstring`, `zanshin_string_free`, `vec_into_ffi_buf`, `vec_into_token`, `ZanshinBuf`, `zanshin_buffer_free`, `zanshin_buffer_free_token` (all from 3-0) are **not modified** — same signatures, same bodies, same tests. `cstr_to_string` is the only addition to this file. Add `use crate::envelope::{FfiErrorObj, FFI_NULL_POINTER, FFI_UTF8_ERROR};` (and `CStr` to the existing `std::ffi` import).

### AC-3 — `ffi.*` error-code constants emitted from `envelope.rs` (AR-P-4 single-emission-point)

8. `crates/zanshin-ffi/src/envelope.rs` gains three `pub const`s alongside the existing `INTERNAL_PANIC`:
   ```rust
   pub const FFI_INVALID_HANDLE: &str = "ffi.invalid_handle";
   pub const FFI_NULL_POINTER:   &str = "ffi.null_pointer";
   pub const FFI_UTF8_ERROR:     &str = "ffi.utf8_error";
   ```
9. `handle.rs` and `ffi_strings.rs` reference these **constants**, never bare `"ffi.*"` string literals — this satisfies AR-P-4 / `docs/rust-error-codes.md`'s rule that every `error.code` string lives in `envelope.rs` only (`architecture.md:641`). (`envelope.rs` re-exports via `lib.rs`'s `pub use envelope::*;`, so `crate::FFI_NULL_POINTER` also resolves — either path is fine; be consistent.)

### AC-4 — Real `zanshin_ffi_version()` + `build.rs` git-SHA injection (FR-FFI-10)

10. `crates/zanshin-ffi/src/lib.rs`'s `zanshin_ffi_version` placeholder is **replaced** with:
    ```rust
    #[no_mangle]
    pub extern "C" fn zanshin_ffi_version() -> *mut c_char {
        let version = format!("{} ({})", env!("CARGO_PKG_VERSION"), env!("ZANSHIN_GIT_SHA"));
        ffi_strings::string_to_cstring(version)
    }
    ```
    The return type changes from `*const c_char` (placeholder, `'static` literal) to **`*mut c_char`** (heap-allocated). The doc-comment is updated to state the caller **MUST free** the returned pointer via `zanshin_string_free` (it is no longer a `'static` literal). The function stays non-`unsafe` (no pointer is dereferenced inbound). `string_to_cstring` takes an **owned `String`** — pass `version` directly (matches the existing 3-0 signature; do **not** change `string_to_cstring`).
11. `crates/zanshin-ffi/build.rs` is **created** (SPDX first line — it is hand-written). At compile time it runs `git rev-parse` and emits `cargo:rustc-env=ZANSHIN_GIT_SHA=<sha>`. If git is unavailable or fails (e.g. a source-tarball build outside a checkout), it falls back to the literal `unknown` so `env!("ZANSHIN_GIT_SHA")` **always** resolves (never a compile error). It emits a `cargo:rerun-if-changed` for the repo's `HEAD`-movement marker so the stamp refreshes on new commits (see Dev Notes for the exact path + the workspace-relative gotcha).
12. The lib.rs module-doc no longer describes `zanshin_ffi_version` as a WIP placeholder; it reflects the real `<version> (<git-sha>)` build-stamp.

### AC-5 — Error-code registry flipped to "Emitted — Story 3.2"

13. `docs/rust-error-codes.md` is updated: the three rows `ffi.invalid_handle`, `ffi.null_pointer`, `ffi.utf8_error` change Status from `Reserved — Story 3.2` to **`Emitted — Story 3.2`**, each annotated with the emitting const (`envelope.rs::FFI_INVALID_HANDLE`, etc.). No other rows change. (Project-context § Error code taxonomy: any PR that emits an `error.code` updates the registry in the same PR.)

### AC-6 — Codegen regenerated + committed (the version signature changed)

14. Because `zanshin_ffi_version`'s **signature and doc-comment change**, run `cargo make codegen` and **commit** the regenerated `crates/zanshin-ffi/include/zanshin_ffi.h` and `app/lib/src/ffi/bindings.dart` in the same change. In the header, `const char *zanshin_ffi_version(void);` becomes `char *zanshin_ffi_version(void);` and the lifted doc-comment updates to the "caller frees via `zanshin_string_free`" wording.
15. `handle.rs`, `cstr_to_string`, the `envelope.rs` consts, and `build.rs` add **no new `extern "C"` symbol** (they are internal `pub fn` / `pub unsafe fn` / a build script). Therefore the **only** delta in the regenerated header/bindings is the `zanshin_ffi_version` signature+doc change — no spurious churn. Do **not** hand-edit either generated file; regenerate only via `cargo make codegen`.

### AC-7 — Tests (inline, per project-context testing rule)

16. `handle.rs` has an inline `#[cfg(test)] mod tests` covering, with a small local dummy type (e.g. `struct Dummy { value: i32 }`):
    - `handle_into_raw(Dummy{..})` → non-null; `handle_from_raw` returns `Some`; mutate through the `&mut`; then `handle_drop` reclaims it (no leak/UB);
    - `handle_from_raw::<Dummy>(null)` → `None`;
    - `validate_handle::<Dummy>(null)` → `Err` with `code == "ffi.invalid_handle"`;
    - `validate_handle::<Dummy>(non_null)` → `Ok(ptr)` with the same address (cast only). Free any handle the test created via `handle_drop` so the test is leak-clean.
17. `ffi_strings.rs`'s inline test module gains:
    - `cstr_to_string` over a valid C string → `Ok(expected)`;
    - `cstr_to_string(null)` → `Err` with `code == "ffi.null_pointer"`;
    - `cstr_to_string` over invalid UTF-8 (e.g. a `CString`-incompatible byte slice built with an interior `0xFF`, exposed as `*const c_char`) → `Err` with `code == "ffi.utf8_error"`.
18. `lib.rs` gains an inline test for `zanshin_ffi_version`: call it, reconstruct the owned string (`CStr::from_ptr` / `CString::from_raw`), assert it **starts with** `env!("CARGO_PKG_VERSION")` and matches the `"<version> (<sha>)"` shape (contains `" ("` and ends with `")"`), then free via `zanshin_string_free`. Assert the **format/structure**, not an exact SHA (the SHA is build-dependent).

### AC-8 — Quality gate

19. `cargo make test` passes fully green (workspace tests, `clippy --pedantic -D warnings`, `cargo fmt --check`, `flutter test`, `dart analyze`, `dart format`, `cargo deny advisories+bans`, cargo hygiene). Every `unsafe` block carries a `// SAFETY:` comment; every `unsafe fn` carries a `# Safety` doc. No `#[allow(...)]` without an inline `// WHY:` justification.

### Edge cases (carried from the epic, reconciled)

- **Interior NUL in the version string:** `string_to_cstring` already returns `null` on an interior NUL byte (3-0, documented). The version string `"<semver> (<hex-sha>)"` cannot contain a NUL, so this path is unreachable for `zanshin_ffi_version`; no new handling is required. Do not add a redundant guard.
- **`zanshin_string_free(NULL)`** is already a documented no-op (3-0). No change.
- **Double-free / double-close** of a handle or C string is UB at the C ABI; the `# Safety` docs warn against it. Dart's `NativeFinalizer` (a later story) is the belt-and-suspenders against accidental double-free from Dart — out of scope here.

---

## Tasks / Subtasks

- [x] **T1 — AC-3: Add the three `ffi.*` constants to `envelope.rs`** (do this first; `handle.rs` and `cstr_to_string` depend on them)
  - [x] T1.1 Add `pub const FFI_INVALID_HANDLE`, `FFI_NULL_POINTER`, `FFI_UTF8_ERROR` next to `INTERNAL_PANIC`, each with a one-line `///` doc. No other change to `envelope.rs`.
- [x] **T2 — AC-1/7: Create `crates/zanshin-ffi/src/handle.rs`**
  - [x] T2.1 SPDX first line + module doc (state: AD-2 `Box<T>` handle ownership; the `_open`/`_close` lifecycle pair; single-threaded worker invariant).
  - [x] T2.2 `use std::ffi::c_void;` and `use crate::envelope::{FfiErrorObj, FFI_INVALID_HANDLE};`.
  - [x] T2.3 `handle_into_raw`, `handle_from_raw` (`ptr.as_mut()`), `handle_drop` (null-guarded), `validate_handle`. `# Safety` doc on both `unsafe fn`s; `#[must_use]` on the value-returning fns; backtick `Box`, `CString`, etc. in docs (clippy::doc_markdown).
  - [x] T2.4 Inline `#[cfg(test)] mod tests` — the four cases in AC-7.16. Use a local `Dummy` struct. `// SAFETY:` on every `unsafe` test block.
- [x] **T3 — AC-2/7: Add `cstr_to_string` to `ffi_strings.rs`**
  - [x] T3.1 Extend the `std::ffi` import to include `CStr`; add `use crate::envelope::{FfiErrorObj, FFI_NULL_POINTER, FFI_UTF8_ERROR};`.
  - [x] T3.2 `pub unsafe fn cstr_to_string(ptr: *const c_char) -> Result<String, FfiErrorObj>` with `# Safety` doc; null → `FFI_NULL_POINTER`, bad UTF-8 → `FFI_UTF8_ERROR`, else `Ok(owned)`.
  - [x] T3.3 Add the three inline tests (AC-7.17) to the existing `mod tests`. Build an invalid-UTF-8 C string for the `ffi.utf8_error` case. **Do not modify any existing function or test.**
- [x] **T4 — AC-4: `build.rs` + real `zanshin_ffi_version`**
  - [x] T4.1 Create `crates/zanshin-ffi/build.rs` (SPDX first line): `git rev-parse` → `cargo:rustc-env=ZANSHIN_GIT_SHA=<sha>`, fallback `unknown`; emit the `rerun-if-changed` marker (Dev Notes § build.rs).
  - [x] T4.2 Replace the `zanshin_ffi_version` body in `lib.rs` (AC-4.10); update its doc-comment (caller frees via `zanshin_string_free`); update the lib.rs module-doc (AC-4.12). Keep `use core::ffi::c_char;`.
  - [x] T4.3 Add the inline version round-trip test (AC-7.18) to `lib.rs`.
- [x] **T5 — AC-5: Flip the registry** — `docs/rust-error-codes.md`: three `ffi.*` rows → `Emitted — Story 3.2` + emitting-const annotation.
- [x] **T6 — AC-6/8: Codegen + validate**
  - [x] T6.1 `cargo make codegen`; confirm the **only** generated-file delta is `zanshin_ffi_version`'s signature+doc in `zanshin_ffi.h` and `bindings.dart`. Commit both.
  - [x] T6.2 `cargo make test` to full green. Confirm no `#[allow]` without `// WHY:`, every `unsafe` has `// SAFETY:`, every `unsafe fn` has `# Safety`.

---

## Dev Notes

### What already exists — reuse, do not recreate

- **`crates/zanshin-ffi/src/ffi_strings.rs` (3-0, tested):**
  - `#[must_use] pub fn string_to_cstring(s: String) -> *mut c_char` — owned-`String` in, heap C-string out, `null` on interior NUL. **The version impl calls this with the `format!` result.** Note the param is **owned `String`**, not `&str` (the epic's `&str` is superseded).
  - `pub unsafe extern "C" fn zanshin_string_free(ptr: *mut c_char)` — null-safe free; the canonical free for any `zanshin-ffi` C string (and for the new version return).
  - Buffer-ownership contract: `vec_into_ffi_buf`, `vec_into_token`, `ZanshinBuf`, `zanshin_buffer_free`, `zanshin_buffer_free_token` — **not relevant to 3.2; leave untouched.**
- **`crates/zanshin-ffi/src/envelope.rs` (3-1, tested):** `pub struct FfiErrorObj { pub code: String, pub context: Option<String> }`, `ok_empty`, `err`, `catch`, `pub const INTERNAL_PANIC`. The epic's `ErrorObj` **is** `FfiErrorObj`. 3.2 adds three sibling `pub const`s here (T1).
- **`crates/zanshin-ffi/src/lib.rs`:** declares `pub mod envelope; pub use envelope::*; pub mod ffi_strings;` and the **placeholder** `zanshin_ffi_version() -> *const c_char { c"0.1.0".as_ptr() }`. 3.2 adds `pub mod handle;` and replaces the version body.
- **`docs/rust-error-codes.md` (3-1):** the three `ffi.*` rows already exist marked *Reserved — Story 3.2*. T5 flips them.

### `handle.rs` — recommended shape (why this seam)

```rust
// SPDX-License-Identifier: Apache-2.0
//! AD-2 opaque-handle helpers: Rust owns every handle as `Box<T>`; Dart holds the raw
//! `*mut c_void`. `zanshin_X_open` leaks a `Box` via [`handle_into_raw`]; `zanshin_X_close`
//! reclaims it via [`handle_drop`]. Single-threaded worker-isolate access (AD-2) — no locking.

use crate::envelope::{FfiErrorObj, FFI_INVALID_HANDLE};
use std::ffi::c_void;

#[must_use]
pub fn handle_into_raw<T>(value: T) -> *mut T {
    Box::into_raw(Box::new(value))
}

/// # Safety
/// `ptr` must be null or a pointer returned by [`handle_into_raw`] that is still live.
/// The caller must not hold two `&mut` to the same handle simultaneously (AD-2 guarantees
/// this: the single worker isolate serialises all handle access).
pub unsafe fn handle_from_raw<'a, T>(ptr: *mut T) -> Option<&'a mut T> {
    // SAFETY: null yields None; otherwise the caller's invariant makes the deref sound.
    unsafe { ptr.as_mut() }
}

/// # Safety
/// `ptr` must be null or a live pointer from [`handle_into_raw`]; it must not be dropped twice.
pub unsafe fn handle_drop<T>(ptr: *mut T) {
    if ptr.is_null() {
        return;
    }
    // SAFETY: ptr came from Box::into_raw(Box::new(_)) in handle_into_raw; reclaiming as
    // Box<T> is the exact inverse, and the caller guarantees a single drop.
    drop(unsafe { Box::from_raw(ptr) });
}

/// Null-check a Dart-supplied handle and return it typed. Safe: casts only, never derefs.
pub fn validate_handle<T>(ptr: *mut c_void) -> Result<*mut T, FfiErrorObj> {
    if ptr.is_null() {
        return Err(FfiErrorObj { code: FFI_INVALID_HANDLE.to_owned(), context: None });
    }
    Ok(ptr.cast::<T>())
}
```

**Why `ptr.as_mut()` not `&'static mut`:** the epic's literal `-> Option<&'static mut T>` mints a
`'static` lifetime that outlives the actual `Box` (which lives only until `handle_drop`). `ptr.as_mut()`
gives a null-checked `Option<&mut T>` whose lifetime is inferred at the call site — same ergonomics,
no lifetime lie. **Why `validate_handle` is separate from `handle_from_raw`:** 3.4a's wrappers receive
`*mut c_void` from Dart; `validate_handle` does the null→`ffi.invalid_handle` translation and the
`c_void → T` cast in one safe step, then the wrapper derefs via `handle_from_raw` only where it needs
`&mut`. Splitting them keeps the unsafe deref at exactly one site per call.

**No FFI consumer yet:** no `extern "C"` function uses these helpers in 3.2 — the first is `zanshin_repo_open`/`_close` in 3.4a. That is expected: 3.2 lands and unit-tests the infrastructure in isolation so 3.4a is a thin wrapper. Do **not** add an `extern "C"` handle function here.

### `cstr_to_string` — recommended shape

```rust
use std::ffi::{c_char, CStr, CString}; // CStr is the new import; CString already present
use crate::envelope::{FfiErrorObj, FFI_NULL_POINTER, FFI_UTF8_ERROR};

/// # Safety
/// `ptr` must be null or a valid NUL-terminated C string that stays valid for this call.
pub unsafe fn cstr_to_string(ptr: *const c_char) -> Result<String, FfiErrorObj> {
    if ptr.is_null() {
        return Err(FfiErrorObj { code: FFI_NULL_POINTER.to_owned(), context: None });
    }
    // SAFETY: caller guarantees ptr is a valid NUL-terminated C string for the call.
    let cstr = unsafe { CStr::from_ptr(ptr) };
    cstr.to_str()
        .map(ToOwned::to_owned)
        .map_err(|_| FfiErrorObj { code: FFI_UTF8_ERROR.to_owned(), context: None })
}
```

For the **invalid-UTF-8 test**, build the bytes yourself rather than via `CString::new` (which forbids
interior NUL but allows arbitrary non-UTF-8): e.g. `let raw = [0xFFu8, 0xFE, 0x00];` then
`cstr_to_string(raw.as_ptr().cast::<c_char>())` — the `0x00` terminates it, `0xFF 0xFE` is invalid
UTF-8 → `ffi.utf8_error`. Keep the byte buffer alive for the call's duration.

### `build.rs` — recommended shape + the workspace gotcha

```rust
// SPDX-License-Identifier: Apache-2.0
use std::process::Command;

fn main() {
    let sha = Command::new("git")
        .args(["rev-parse", "--short=12", "HEAD"])
        .output()
        .ok()
        .filter(|o| o.status.success())
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .map(|s| s.trim().to_owned())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "unknown".to_owned());
    println!("cargo:rustc-env=ZANSHIN_GIT_SHA={sha}");

    // Refresh the stamp when HEAD moves. The crate root is crates/zanshin-ffi/, the repo .git is
    // two levels up. `.git/logs/HEAD` (the reflog) appends on every commit / checkout / reset, so
    // it is a single reliable trigger — unlike `.git/HEAD`, which does NOT change on a new commit
    // to the same branch. Path is package-root-relative.
    println!("cargo:rerun-if-changed=../../.git/logs/HEAD");
}
```

- **`env!` vs `option_env!`:** the version impl uses `env!("ZANSHIN_GIT_SHA")` (compile error if unset),
  so `build.rs` **must always** emit the var — hence the `unwrap_or_else("unknown")`. This is the WIP
  contract: a source-tarball build with no git still compiles and stamps `unknown`.
- **`--short=12`** keeps the stamp readable; full `HEAD` is also acceptable (FR-FFI-10 says "git SHA",
  length unspecified). Pick one and be consistent.
- **No new dependency.** Do **not** add `vergen`/`git2`/`build-data` — a `std::process::Command` call is
  the deliberate, dependency-free choice (project-context: eyeball every new dep; prefer none).
- **Stale-stamp caveat (acceptable in WIP):** if `.git/logs/HEAD` is absent (e.g. a shallow/exported
  tree), the `rerun-if-changed` simply never fires and the stamp reflects the last full build. That is
  fine for a build-stamp; do not over-engineer ref-walking.

### `lib.rs` version impl — exact change

Replace the placeholder body (currently `c"0.1.0".as_ptr()` returning `*const c_char`) with the AC-4.10
form returning `*mut c_char`. Update the doc-comment to drop the "WIP-placeholder / `'static` / MUST NOT
free" wording and state: *returns a heap-allocated `"<crate version> (<git sha>)"`; the caller MUST free
it via `zanshin_string_free`.* `string_to_cstring` consumes the owned `String` — pass `version` by value.
This doc-comment is what cbindgen lifts into `zanshin_ffi.h`, so write it as the header's contract.

### Hard guardrails (reject-at-review for this story)

- **Do not recreate `ffi_strings.rs`** or rewrite any function in it — only **add** `cstr_to_string` + its tests. (It is a 3-0 deliverable, already code-reviewed.)
- **Do not change `string_to_cstring`'s signature** to `&str`. It takes owned `String`; the version impl already produces an owned `String`. The epic's `&str` predates the implementation.
- **Error-code strings live only in `envelope.rs`** (AR-P-4 single-emission-point). `handle.rs`/`ffi_strings.rs` reference the `pub const`s, never bare `"ffi.invalid_handle"` literals.
- **`unsafe` is allowed only in `handle.rs` and `ffi_strings.rs`** (project-context). Every `unsafe` block needs `// SAFETY:`; every `unsafe fn` needs a `# Safety` doc. `validate_handle` and `handle_into_raw` are **safe** fns (no deref) — do not mark them `unsafe`.
- **`zanshin_ffi_version` is the only codegen-driving change.** Run `cargo make codegen` and commit the regenerated `zanshin_ffi.h` + `bindings.dart`. Never hand-edit them, and never regenerate them outside `cargo make codegen`.
- **No new `extern "C"` symbol** beyond the (re-signatured) `zanshin_ffi_version`. `handle.rs`, `cstr_to_string`, and `build.rs` are internal — they must not appear in the header.
- **No new crate dependency.** `format!`, `env!`, `CStr`, `c_void`, `Box`, `std::process::Command` are all std.
- **SPDX `// SPDX-License-Identifier: Apache-2.0` on the first line** of `handle.rs` and `build.rs` (both hand-written). Generated files are exempt (the generator owns their banner).
- **Update `docs/rust-error-codes.md` in the same change** — emitting a code without updating the registry is a review-block (project-context § Error code taxonomy).

### Clippy / fmt carry-overs (bit 3-0 and 3-1; will bite again)

- `clippy::doc_markdown` flags bare `FlatBuffers`, `CString`, `CStr`, `Box`, `NativeFinalizer` in doc comments → backtick them.
- `#[must_use]` on functions returning an owned value the caller must use (`handle_into_raw`; `validate_handle` returns a `Result`, which is already `#[must_use]` by type).
- Prefer `ptr.cast::<T>()` over `ptr as *mut T` (clippy::ptr_as_ptr).
- The crate's effective `max_width` is governed by the repo `rustfmt.toml` (**120**, despite project-context saying 100 — a known pre-existing divergence). Format with the repo config; do not hand-wrap to 100.
- `rustfmt.toml` `ignore` entries are nightly-only and irrelevant here (no hand-written file should be excluded from fmt).

### Testing standards (project-context § Testing Rules)

- Rust unit tests **inline** at the bottom of the module they test (`handle.rs`, `ffi_strings.rs`, `lib.rs`). **Not** a `tests/` integration file — the epic's "integration test" line for the version round-trip is superseded by the inline pattern 3-1 already established (an inline `#[cfg(test)]` test can call the `extern "C"` fn directly and free the result).
- Test names describe the scenario: `validate_handle_null_returns_invalid_handle`, `cstr_to_string_invalid_utf8_returns_utf8_error`, `ffi_version_has_version_and_sha_format`.
- No `#[ignore]`/`skip:`; no network; no dependence on the developer's global jj/git config (N/A — no repo access in this story; the only `git` call is `build.rs`'s, which is fine and not a test).
- Tests must be **leak-clean**: every `handle_into_raw` is matched by a `handle_drop`; every `string_to_cstring`/version pointer is freed via `zanshin_string_free`.

### Project Structure Notes

- `handle.rs` lands at `crates/zanshin-ffi/src/handle.rs` — matches AR-P-3 (`architecture.md:311`, `:453`) and project-context § module layout exactly. No `mod.rs`; `lib.rs` stays re-exports + `zanshin_ffi_version` only (the version fn is the one piece of "logic" AR-P-3 explicitly keeps in `lib.rs`, `architecture.md:306/451`).
- `build.rs` at the crate root (`crates/zanshin-ffi/build.rs`) — Cargo auto-detects it; no `[package] build = …` key needed (default `build.rs` discovery). No change to `Cargo.toml` is required (no new dep, no `[build-dependencies]`).
- No Dart-side hand-written work: `bindings.dart` is regenerated by ffigen, not authored. The Dart wrapper that calls `zanshinFfiVersion()` + frees the pointer is a later (UI-scope-adjacent) concern, out of scope here.

## References

- `_bmad-output/planning-artifacts/epics.md` § Story 3.2 (`:1699`) — the GWT this story reconciles. Behavioural requirements (handle helpers, `cstr_to_string` errors, version handshake, `build.rs` fallback, edge cases) are binding; the `ErrorObj` name and "create ffi_strings.rs" / `&str` / `tests/` wording are superseded (see the scope-correction callout).
- `_bmad-output/implementation-artifacts/3-0-adopt-flatbuffers-ffi-transport.md` — built `ffi_strings.rs` (the existing string/buffer helpers), the `root_with_opts` verify pattern, and the clippy/fmt findings.
- `_bmad-output/implementation-artifacts/3-1-ffi-core-envelope-error-codes-panic-catch.md` — built `envelope.rs` (`FfiErrorObj`, `err`, `catch`, `INTERNAL_PANIC`) and `docs/rust-error-codes.md` (the registry this story flips); confirms the inline-test pattern and the codegen-not-run discipline (3.2 reverses that — it **does** run codegen).
- `crates/zanshin-ffi/src/ffi_strings.rs` — existing functions to leave untouched; the `mod tests` to extend.
- `crates/zanshin-ffi/src/envelope.rs` — where the three `ffi.*` consts go (next to `INTERNAL_PANIC`).
- `crates/zanshin-ffi/src/lib.rs` — the placeholder `zanshin_ffi_version` to replace; `pub mod handle;` to add.
- `crates/zanshin-ffi/include/zanshin_ffi.h` — current generated header (shows the placeholder `const char *zanshin_ffi_version(void);` that becomes `char *…`).
- `docs/rust-error-codes.md` — AR-P-4 registry; the three `ffi.*` rows to flip to *Emitted — Story 3.2*.
- `_bmad-output/project-context.md` § FFI boundary, § Error code taxonomy, § Critical Implementation Rules (`unsafe` only in `handle`/`ffi_strings`; SPDX first line; codegen discipline; no new deps), § Testing Rules.
- `_bmad-output/planning-artifacts/architecture.md` — AD-2 handle lifetime/ownership (`:205`–`:213`), module layout (`:306`/`:311`/`:451`/`:453`), AR-P-4 single-emission-point (`:641`).
- `_bmad-output/planning-artifacts/prd.md` — FR-FFI-10 (`:246`, version + git SHA, no compatibility negotiation), FR-FFI-9 (`:245`, no panic crossings — the `catch` backstop already lands in 3-1).
- `docs/adr/0001-ffi-data-transport-flatbuffers.md` — lone strings cross as `CString`; composite data is FlatBuffers (context for why `cstr_to_string`/`string_to_cstring` are the string-marshalling surface).

## Dev Agent Record

### Agent Model Used

claude-sonnet-4-6

### Debug Log References

- Clippy caught two issues: `missing_errors_doc` on `cstr_to_string` and `validate_handle`, and `double_must_use` on `validate_handle` (Result is already `#[must_use]`). Fixed by adding `# Errors` sections and removing the redundant `#[must_use]` from `validate_handle`.
- `rustfmt` required multi-line struct literal expansion for `FfiErrorObj { ... }` in `cstr_to_string` and `validate_handle`. Fixed via `cargo fmt --all`.

### Completion Notes List

- **T1 (AC-3):** Added `FFI_INVALID_HANDLE`, `FFI_NULL_POINTER`, `FFI_UTF8_ERROR` constants to `envelope.rs` next to `INTERNAL_PANIC`. All three carry one-line `///` docs.
- **T2 (AC-1/7):** Created `crates/zanshin-ffi/src/handle.rs` with `handle_into_raw` (must_use), `handle_from_raw` (unsafe, lifetime `'a`), `handle_drop` (unsafe, null-guarded), and `validate_handle` (safe, cast-only). Declared `pub mod handle;` in `lib.rs`. Four-case inline test suite with `Dummy` struct; all `unsafe` blocks carry `// SAFETY:` comments.
- **T3 (AC-2/7):** Added `cstr_to_string` to `ffi_strings.rs` using `CStr::from_ptr` + `.to_str()`. Three new tests in the existing `mod tests`: valid C string → Ok, null → FFI_NULL_POINTER, invalid UTF-8 bytes → FFI_UTF8_ERROR. Existing functions and tests untouched.
- **T4 (AC-4):** Created `crates/zanshin-ffi/build.rs` (SPDX first line) with `git rev-parse --short=12 HEAD` + `unknown` fallback; emits `rerun-if-changed=../../.git/logs/HEAD`. Replaced `zanshin_ffi_version` placeholder (`*const c_char` static literal) with real impl returning `*mut c_char` heap allocation via `string_to_cstring`. Updated module-doc. Added version round-trip inline test.
- **T5 (AC-5):** Flipped three `ffi.*` rows in `docs/rust-error-codes.md` from `Reserved — Story 3.2` to `Emitted — Story 3.2` with emitting-const annotation.
- **T6 (AC-6/8):** `cargo make codegen` ran cleanly. Header delta: `const char *` → `char *` for `zanshin_ffi_version`. `cargo make test` passed 29/29 zanshin-ffi tests + all workspace tests. No `#[allow]` without `// WHY:`, all `unsafe` blocks carry `// SAFETY:`, all `unsafe fn`s carry `# Safety` docs.

### File List

- `crates/zanshin-ffi/src/envelope.rs` — added three `ffi.*` pub const strings
- `crates/zanshin-ffi/src/handle.rs` — new file: Box↔raw handle helpers + validate_handle + inline tests
- `crates/zanshin-ffi/src/ffi_strings.rs` — added `cstr_to_string` + three inline tests; extended imports
- `crates/zanshin-ffi/src/lib.rs` — added `pub mod handle;`; replaced `zanshin_ffi_version` placeholder; updated module-doc; added version round-trip test
- `crates/zanshin-ffi/build.rs` — new file: git SHA injection + rerun-if-changed
- `docs/rust-error-codes.md` — flipped three ffi.* rows to Emitted — Story 3.2
- `crates/zanshin-ffi/include/zanshin_ffi.h` — regenerated: `const char *` → `char *` + doc update
- `app/lib/src/ffi/bindings.dart` — regenerated: Dart binding reflects updated signature + doc
- `_bmad-output/implementation-artifacts/sprint-status.yaml` — status: ready-for-dev → review

### Change Log

- 2026-06-15: Story 3.2 implemented — handle.rs (Box↔raw + validate_handle), ffi_strings::cstr_to_string (input direction), three ffi.* constants in envelope.rs, real zanshin_ffi_version with build.rs git-SHA injection, registry flipped to Emitted, codegen re-run (const char* → char*). 29/29 tests green, cargo make test full green.

---

### Review Findings

_Code review (`bmad-code-review`) — 2026-06-15, baseline `5d7577e`. Layers: Blind Hunter (diff-only), Edge Case Hunter (diff + project), Acceptance Auditor (diff + spec). **Acceptance Auditor verdict: spec-conformant — AC-1…AC-8 and all hard guardrails satisfied** (one benign codegen-doc-churn note under AC-6: the regenerated `zanshin_ffi.h`/`bindings.dart` also updated the `ZanshinBuf`/`zanshin_buffer_free` doc-comments because the baseline generated files were stale relative to baseline source — not a hand-edit, correct as-is). Triage: **0 decision-needed · 0 patch · 2 defer (LOW) · 13 dismissed**._

#### Deferred (LOW — `build.rs` robustness, WIP)

- [x] [Review][Defer] `build.rs` git-SHA stamp goes stale under git worktrees / shallow clones [`crates/zanshin-ffi/build.rs:20`] — `cargo:rerun-if-changed=../../.git/logs/HEAD` assumes `.git` is a directory two levels up; in a linked worktree/submodule `.git` is a *file* (reflog under the common dir) and shallow/fresh clones may lack the reflog, so the trigger watches a nonexistent path and the stamp never refreshes. Spec Dev Notes consciously chose simplicity ("do not over-engineer ref-walking"). Deferred to release phase. (blind+edge)
- [x] [Review][Defer] `build.rs` embeds an unrelated parent-repo SHA instead of `unknown` [`crates/zanshin-ffi/build.rs:5`] — when the source tree has no own `.git` but sits inside another git checkout, `git rev-parse HEAD` succeeds against the enclosing repo. Contrived; low impact for a WIP build-stamp. (edge)

#### Dismissed (deliberate / spec-mandated design — recorded so future reviews don't re-raise)

- `handle_from_raw` hands out `&'a mut T` with an unbounded lifetime → aliasing/UAF footgun (blind+edge) — **spec-mandated** (AC-1.3: `ptr.as_mut()`, idiomatic null-checked); aliasing prevented by the AD-2 single-isolate invariant, documented in `# Safety`.
- `validate_handle` only null-checks, never proves liveness despite its name (blind+edge) — **spec-mandated** (AC-1.5: safe, cast-only); there is no handle table by architecture (AD-2 raw `Box` pointers), so liveness validation is out of scope by design.
- `cstr_to_string` reads OOB on a non-NUL-terminated pointer (blind+edge) — inherent to C-string FFI / `CStr::from_ptr`; correctly documented in `# Safety`; matches the spec's recommended shape. Dart always passes `CString`-allocated, NUL-terminated strings.
- `zanshin_ffi_version` can return null on interior-NUL SHA; null path untested (blind+edge) — spec Edge-cases: unreachable by construction (hex short-SHA + semver contain no NUL); "do not add a redundant guard."
- `cstr_to_string` UTF-8 error drops `Utf8Error` detail (`context: None`) (blind) — **spec-mandated** (AC-2.6 specifies `context: None`).
- `const char *` → `char *` signature is an ABI/source break (blind) — **spec-mandated** (AC-4.10/AC-6.14); WIP allows breaking changes; the placeholder was never published.
- "Emitted — Story 3.2" overstated since helpers aren't wired into an `extern "C"` symbol yet (blind) — **spec-mandated** (AC-5); the consts are returned by `validate_handle`/`cstr_to_string`; the `extern "C"` wiring lands in 3.4a by design.
- No runtime double-free guard; `pub` primitive (blind) — spec Edge-cases explicitly accepts; `# Safety` documents the single-drop contract; Dart `NativeFinalizer` is the later belt-and-suspenders.
- `string_to_cstring`/`zanshin_string_free` allocator-pairing "unverifiable" (blind) — false positive from diff-only view; the 3-0 pair is tested and correct (confirmed by the other layers).
- `build.rs` silently collapses git failures to `unknown` without `cargo:warning` (blind) — **spec-mandated** (AC-4.11 silent `unknown` fallback).
- AC-6 extra codegen doc-churn on `ZanshinBuf`/`zanshin_buffer_free` (auditor) — verified benign: regeneration caught up a stale baseline; correct as-is.
- Misleading test SAFETY comment + no empty-string `cstr_to_string` test (blind) — comment is acceptable shorthand; empty-string is not a spec-required test and the happy path is covered.
- `docs/rust-error-codes.md` `ffi.invalid_handle` description ("not in the live handle table") doesn't match the null-only emission (blind) — the description is intent-conveying and pre-existing; AC-5 scoped the change to the Status column only, and registry reasons/descriptions are treated as stable.
