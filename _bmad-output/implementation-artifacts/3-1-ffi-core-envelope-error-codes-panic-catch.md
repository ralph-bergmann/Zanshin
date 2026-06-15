# Story 3.1: FFI core — envelope builders, error codes, panic catch

---
baseline_commit: 80ce5c0
---

Status: done

> **⚠️ Scope-correction (binding — [ADR-0001](../../docs/adr/0001-ffi-data-transport-flatbuffers.md), 2026-06-15):**
> The envelope is **FlatBuffers**, not JSON. Story **3-0** already landed the schema
> (`schemas/envelope.fbs`), the committed `flatc` accessors (`envelope_generated.rs`), and the
> buffer-ownership contract (`ffi_strings.rs`). This story does **not** re-land any of that. It adds the
> ergonomic Rust layer on top: `crates/zanshin-ffi/src/envelope.rs` with `ok`/`err`/`catch`-style
> builders that produce a finished `Envelope` **byte buffer** (`Vec<u8>`), the AR-P-4 error-code
> registry (`docs/rust-error-codes.md`), and the `catch_unwind` panic backstop (FR-FFI-9 / NFR-R-3).
> **The detailed JSON GWT in `epics.md` § Story 3.1 is superseded** — there is no Rust
> `Envelope<T: Serialize>` struct, no `serde_json`, no `schema_version` field, no `message` field.

---

## Story

As a Rust developer implementing the FFI surface,
I want `crates/zanshin-ffi/src/envelope.rs` with FlatBuffers `Envelope` builder helpers, the AR-P-4
error-code registry, and a `catch_unwind` panic-catch wrapper,
so that every fallible FFI function in later stories (3.4a repo, 3.4b read-path, 4.6 graph, 5.8 diff,
6.5 mutations, 3.8 diagnostics) builds the canonical envelope from one place — no duplication, no
divergent shapes, and no panic ever crosses the C ABI.

**This story sits directly on top of Story 3-0.** Read `_bmad-output/implementation-artifacts/3-0-adopt-flatbuffers-ffi-transport.md` first — it built the schema, the generated accessors, and the buffer-ownership contract this story consumes.

---

## Acceptance Criteria

> These criteria **replace** the JSON GWT in `epics.md` § Story 3.1. The error-code **taxonomy**
> (AR-P-4) and **panic-catch behaviour** (FR-FFI-9) are unchanged from the epic; only the carrier
> (FlatBuffers, not JSON) and the API shape changed.

### AC-1 — `envelope.rs` exists with the error type and builders

1. `crates/zanshin-ffi/src/envelope.rs` exists, starts with `// SPDX-License-Identifier: Apache-2.0`, and is declared in `lib.rs` per AR-P-3.
2. It defines the Rust-side error mirror of the FlatBuffers `FfiError`:
   ```rust
   pub struct FfiErrorObj { pub code: String, pub context: Option<String> }
   ```
   **Exactly `code` + `context`** — matching `schemas/envelope.fbs` (committed, code-reviewed in 3-0). **No `message` field** (the human-readable detail lives in `context`); **no `schema_version`** field anywhere.
3. It provides `pub fn ok_empty() -> Vec<u8>` that builds and finishes a success `Envelope` with `ok = true`, `error = None`, `data_type = Payload::NONE`, and returns the finished buffer bytes.
4. It provides `pub fn err(code: &str, context: Option<&str>) -> Vec<u8>` that builds and finishes an error `Envelope` with `ok = false`, `error = FfiError { code, context }`, `data_type = Payload::NONE`.

### AC-2 — Panic-catch wrapper (FR-FFI-9 / NFR-R-3)

5. It provides `pub fn catch<F>(f: F) -> Vec<u8> where F: FnOnce() -> Result<Vec<u8>, FfiErrorObj> + std::panic::UnwindSafe`, wrapping `f` in `std::panic::catch_unwind`:
   - `Ok(Ok(buf))` → returns `buf` (the success envelope the closure built — `ok_empty()` now, `ok(payload)` once payloads land in 3.4a);
   - `Ok(Err(e))` → returns `err(&e.code, e.context.as_deref())`;
   - `Err(panic)` → returns `err("internal.panic", Some(<panic msg>))`.
6. The panic message is extracted by downcasting the payload to `&str`, then `String`; if neither matches it becomes the literal `"<unknown panic payload>"`.
7. The success envelope is built **outside** the `catch_unwind` (the closure returns an already-finished `Vec<u8>`), so `catch` constrains only `f` with `UnwindSafe` — the `FlatBufferBuilder` is never carried across the unwind boundary.
8. **No panic can escape `catch`**: any `panic!`, `unwrap`, `expect`, slice OOB, etc. inside `f` is converted to the `internal.panic` envelope. This is the FR-FFI-9 backstop; the design goal remains *never to reach it*.

### AC-3 — Error code is `internal.panic` (dotted), single emission point

9. The panic code emitted is the dotted-lowercase `"internal.panic"` (AR-P-4 / project-context), **not** `internal_panic`. *(Note: `architecture.md:203` writes `internal_panic` with an underscore — that is a typo; `project-context.md` and `architecture.md` P-4:328 are authoritative with the dot.)*
10. Error-code string constants emitted by this layer (at minimum `pub const INTERNAL_PANIC: &str = "internal.panic";`) live in `envelope.rs`, satisfying P-4's "codes emitted from a single `envelope.rs` location" (`architecture.md:641`).

### AC-4 — Error-code registry `docs/rust-error-codes.md`

11. `docs/rust-error-codes.md` is **created** (it does not exist yet) as the canonical AR-P-4 registry. It documents the dotted `<domain>.<reason>` convention, the domain list (`jj`, `diff`, `graph`, `ffi`, `watcher`, `mcp`, `internal`), the "user data goes in `context`, never in `code`" rule, and the "reasons never change after release" rule.
12. It seeds (at minimum) the codes named in the epic, each with domain, meaning, and status (emitted-now vs reserved-for-story):
    `internal.panic`, `internal.serialization_failed`, `ffi.invalid_handle`, `ffi.null_pointer`,
    `ffi.utf8_error`, `jj.repo_not_found`, `jj.path_not_found`, `jj.jj_lib_error`,
    `watcher.io_error`, `watcher.watchman_not_configured`.
13. `internal.panic` is marked **emitted by this story**. The `ffi.*` codes are marked reserved for Story 3.2, the `jj.*` for 3.4a, the `watcher.*` for the deferred watcher stories. `internal.serialization_failed` is marked **reserved/legacy**: it was a JSON-era failure mode; the FlatBuffers in-memory builder does not fail the way `serde_json::to_string` did, so this layer does not currently emit it (documented as such — do not invent a synthetic failure path to "use" it).

### AC-5 — Tests (inline, typed-accessor verified)

14. `envelope.rs` has an inline `#[cfg(test)] mod tests` (per project-context testing rule — **not** a `tests/envelope.rs` integration file as the superseded epic GWT said) covering:
    - `ok_empty()` → `ok == true`, `error` absent, `data_type == Payload::NONE`;
    - `err(code, Some(ctx))` → `ok == false`, `error.code()` and `error.context()` read back correctly;
    - `err(code, None)` → `error.context()` is `None`;
    - `catch(|| Ok(ok_empty()))` → a valid `ok` envelope;
    - `catch(|| Err(FfiErrorObj{...}))` → an error envelope carrying that code/context;
    - `catch(|| panic!("boom"))` → `error.code() == "internal.panic"`, message captured in `context`;
    - `catch` with a `&str` panic payload and with a non-string panic payload (e.g. `std::panic::panic_any(42u8)`) → the non-string case yields `"<unknown panic payload>"`.
15. Every test reads the produced buffer back through the **generated typed accessors** and the FlatBuffers **`Verifier`** via `flatbuffers::root_with_opts::<fbs::Envelope>(&opts, bytes)` (the verify-and-read path 3-0 settled on — *not* `run_verifier`). A wrong-shape buffer must be a compile error; an invalid buffer must fail the verifier.

### AC-6 — No new FFI surface, no codegen, no duplication

16. This story adds **no new `extern "C"` function** (the first fallible extern "C" lands in 3.4a). Therefore `cargo make codegen` is **not** run, and `zanshin_ffi.h` / `bindings.dart` / the generated FlatBuffers accessors are **unchanged**. The diff touches no generated file.
17. `envelope.rs` returns `Vec<u8>`; it does **not** re-implement buffer ownership. Conversion to the FFI `(*mut u8, len)` / `*mut ZanshinBuf` token happens later at the extern "C" call site (3.4a) via the existing `ffi_strings` helpers (`vec_into_ffi_buf` / `vec_into_token`). Do not duplicate `zanshin_buffer_free`, `string_to_cstring`, etc.

### AC-7 — Quality gate

18. `cargo make test` passes fully green (workspace tests, `clippy --pedantic -D warnings`, `cargo fmt --check`, `flutter test`, `dart analyze`, `dart format`, `cargo deny advisories+bans`, cargo hygiene). No `#[allow(...)]` added without a `// WHY:` justification.

---

## Tasks / Subtasks

- [x] **T1 — AC-1/2/3: Create `crates/zanshin-ffi/src/envelope.rs`**
  - [x] T1.1 SPDX header + module docs (state: builders return finished `Vec<u8>`; ownership handoff is `ffi_strings`' job at the extern "C" site).
  - [x] T1.2 `pub struct FfiErrorObj { code: String, context: Option<String> }` (+ a small constructor if it reads cleaner). Plain struct — **do not** add `thiserror` to `zanshin-ffi`.
  - [x] T1.3 `pub const INTERNAL_PANIC: &str = "internal.panic";` (single-emission-point per P-4).
  - [x] T1.4 `pub fn ok_empty() -> Vec<u8>` — build `Envelope { ok:true, error:None, data_type:NONE, data:None }`, `finish`, return `finished_data().to_vec()`.
  - [x] T1.5 `pub fn err(code: &str, context: Option<&str>) -> Vec<u8>` — `create_string` for code, `context.map(|c| b.create_string(c))`, build `FfiError`, then `Envelope { ok:false, error:Some(..), data_type:NONE }`.
  - [x] T1.6 `pub fn catch<F>(f) -> Vec<u8>` — `catch_unwind(f)`, three-arm match (AC-2). Build success **after** the catch.
  - [x] T1.7 private `fn panic_message(payload: &(dyn std::any::Any + Send)) -> String` — downcast `&str` → `String` → `"<unknown panic payload>"`. *(Use `&(dyn Any + Send)`, not `&Box<dyn Any>`, to dodge the `clippy::borrowed_box` lint.)*
  - [x] T1.8 `///` doc-comments on every `pub` item; backtick `FlatBuffers`, `CString`, `Envelope` in docs (3-0 hit `clippy::doc_markdown` on these); `#[must_use]` on the `Vec`-returning fns.
- [x] **T2 — AC-1/6: Wire into `lib.rs` + de-duplicate the existing envelope tests**
  - [x] T2.1 Add `mod envelope;` (+ `pub use envelope::*;` if it matches the AR-P-3 re-export shape) to `lib.rs`.
  - [x] T2.2 The 3 envelope tests currently inline in `lib.rs` (`envelope_ok_roundtrip`, `envelope_error_roundtrip`, `envelope_buffer_ffi_roundtrip`) hand-build envelopes with the raw generated API. Move/rewrite the envelope-shape assertions into `envelope.rs`'s test module **using the new `ok_empty()` / `err()` helpers** (reuse, don't duplicate the builder boilerplate). Keep the buffer-FFI-roundtrip coverage (the `vec_into_ffi_buf` → read → `zanshin_buffer_free` path) — that exercises the 3-0 ownership contract and is still valuable; it may stay in `lib.rs` or move alongside, but it should consume `err()`/`ok_empty()` rather than re-hand-building the buffer.
- [x] **T3 — AC-4: Create `docs/rust-error-codes.md`**
  - [x] T3.1 Header: convention (`<domain>.<reason>`), domain list, "no user data in code", "reasons never change after release".
  - [x] T3.2 Table of the AC-4 codes with `code | domain | meaning | status (emitted-by / reserved)`; mark `internal.panic` emitted-by-3.1, others reserved (3.2 / 3.4a / watcher), `internal.serialization_failed` reserved/legacy.
- [x] **T4 — AC-5: Inline tests in `envelope.rs`** — the 8 cases in AC-5.14, each read back via `root_with_opts::<fbs::Envelope>` + typed accessors. Use `std::panic::panic_any(...)` for the non-string-payload case.
- [x] **T5 — AC-6/7: Validate** — confirm **no** generated file changed and `cargo make codegen` was **not** run; run `cargo make test` to full green.

---

## Dev Notes

### What 3-0 already built (do not redo — build on it)

`zanshin-ffi` after Story 3-0 already contains the foundation. Reuse it directly:

- **`schemas/envelope.fbs`** — `table FfiError { code: string; context: string; }`, `union Payload { Empty }` (placeholder; first real member `RepoOpenResult` lands in 3.4a), `table Envelope { ok: bool; error: FfiError; data: Payload; }`, `root_type Envelope`. **Do not edit the schema in this story** — no new payload member is needed for 3.1, and editing `.fbs` forces a `flatc` regen + caller updates you don't want here.
- **`crates/zanshin-ffi/src/envelope_generated.rs`** — committed `flatc --rust` accessors. **Never hand-edit.** The API you call:
  ```rust
  use crate::envelope_generated::zanshin::ffi as fbs;
  // success:
  let env = fbs::Envelope::create(&mut b, &fbs::EnvelopeArgs {
      ok: true, error: None, data_type: fbs::Payload::NONE, data: None });
  // error:
  let code = b.create_string("internal.panic");
  let e = fbs::FfiError::create(&mut b, &fbs::FfiErrorArgs { code: Some(code), context: None });
  let env = fbs::Envelope::create(&mut b, &fbs::EnvelopeArgs {
      ok: false, error: Some(e), data_type: fbs::Payload::NONE, data: None });
  b.finish(env, None);
  let bytes: Vec<u8> = b.finished_data().to_vec();
  // verify + read:
  let opts = flatbuffers::VerifierOptions::default();
  let env = flatbuffers::root_with_opts::<fbs::Envelope>(&opts, &bytes)?;
  ```
  (All of this is demonstrated in the current `lib.rs` `#[cfg(test)] mod tests` — lift the patterns.)
- **`crates/zanshin-ffi/src/ffi_strings.rs`** — the full buffer/string ownership contract: `string_to_cstring`, `zanshin_string_free`, `vec_into_ffi_buf` → `zanshin_buffer_free(ptr,len)`, and `ZanshinBuf` / `vec_into_token` → `zanshin_buffer_free_token(token)` (the `NativeFinalizer` single-arg path). **`envelope.rs` does not touch any of this** — it returns `Vec<u8>` and the extern "C" wrapper in 3.4a does the handoff.
- **`Cargo.toml`** — `flatbuffers = { workspace = true }` is already a dep. You need **no new dependency** for this story.

### Recommended `envelope.rs` shape (why this seam)

```rust
// SPDX-License-Identifier: Apache-2.0
//! FlatBuffers `Envelope` builders + AR-P-4 error-code emission + the panic backstop.

use crate::envelope_generated::zanshin::ffi as fbs;
use flatbuffers::FlatBufferBuilder;
use std::any::Any;
use std::panic::{catch_unwind, UnwindSafe};

pub const INTERNAL_PANIC: &str = "internal.panic";

#[derive(Debug, Clone)]
pub struct FfiErrorObj { pub code: String, pub context: Option<String> }

#[must_use] pub fn ok_empty() -> Vec<u8> { /* ok:true, NONE */ }
#[must_use] pub fn err(code: &str, context: Option<&str>) -> Vec<u8> { /* ok:false, FfiError */ }

#[must_use]
pub fn catch<F>(f: F) -> Vec<u8>
where F: FnOnce() -> Result<Vec<u8>, FfiErrorObj> + UnwindSafe {
    match catch_unwind(f) {
        Ok(Ok(buf)) => buf,
        Ok(Err(e))  => err(&e.code, e.context.as_deref()),
        Err(panic)  => err(INTERNAL_PANIC, Some(&panic_message(panic.as_ref()))),
    }
}

fn panic_message(p: &(dyn Any + Send)) -> String { /* &str → String → "<unknown panic payload>" */ }
```

**Why `catch` takes a closure returning `Result<Vec<u8>, FfiErrorObj>`** (success buffer built *by the closure*): it makes the `catch` signature **final now** and **zero-rewrite for 3.4a**. When the first real payload (`RepoOpenResult`) lands, 3.4a adds an `ok<P>(payload) -> Vec<u8>` builder and the wrapper closure simply returns `Ok(ok(payload))`; `catch` is untouched. This is the entire point of sequencing 3-0 → 3-1 → 3.4a (write once). Do **not** hardcode `catch` to `Result<(), _>` — that forces a rewrite.

**Why build the success buffer outside `catch_unwind`:** `FlatBufferBuilder` is not `UnwindSafe`. Keeping it inside the closure (which produces a plain `Vec<u8>`, which *is* `UnwindSafe`) means only the user closure must satisfy `UnwindSafe` — no `AssertUnwindSafe` gymnastics.

**Why no `ok(payload)` / `IntoPayload` trait in 3.1:** the `Payload` union has only the `Empty` placeholder today; there is no real payload to be generic over. Per the 3-0 dev-note discipline ("don't reach for an abstraction until a second noun proves the shape"), `ok_empty()` is all 3.1 needs; the generic `ok` arrives with the first payload in 3.4a.

### Hard guardrails (reject-at-review anti-patterns for this story)

- **No JSON, no `serde`/`serde_json`** on the FFI wire. There is **no** Rust `Envelope<T: Serialize>` struct. The `Envelope` is the generated FlatBuffers type; `envelope.rs` only *builds buffers*. (project-context § FFI boundary; ADR-0001.)
- **No `message` field** on `FfiError`/`FfiErrorObj`. The committed, reviewed `.fbs` is `{ code, context }`. Human-readable detail goes in `context`.
- **No `schema_version`** field anywhere (in-wire or in the Rust types). WIP posture: schemas evolve in place; callers update. (project-context "edge cases agents typically miss".)
- **No new `extern "C"` symbol, no `cargo make codegen`.** 3.1 is pure internal Rust. Running codegen here would be wrong and would dirty generated files. The first fallible `extern "C"` is 3.4a.
- **Do not edit generated files** (`envelope_generated.rs`, `envelope_zanshin.ffi_generated.dart`) — they are `flatc` output.
- **Do not duplicate ownership helpers** — they exist in `ffi_strings.rs`. `envelope.rs` returns `Vec<u8>`, nothing more.
- **Do not add `thiserror` to `zanshin-ffi`.** `FfiErrorObj` is a plain struct — it is the *translation target* for the domain crates' (`zanshin-jj`) `thiserror` errors, not itself a `thiserror` enum.
- **Do not set `panic = "abort"`** in any profile. `catch_unwind` only catches unwinding panics; the workspace currently has no `panic` key (→ default `unwind`), which is correct — leave it.
- Error code is **`internal.panic`** (dotted), never `internal_panic`.
- **Tests inline** in `envelope.rs` (`#[cfg(test)] mod tests`), not a `tests/envelope.rs` file (project-context testing rule; the epic's `tests/envelope.rs` line is from the superseded JSON GWT).
- SPDX `// SPDX-License-Identifier: Apache-2.0` on the **first line** of `envelope.rs` (it is hand-written, not generated).

### Clippy / fmt notes from Story 3-0 (will bite again otherwise)

- `clippy::doc_markdown` flags bare `FlatBuffers`, `CString`, etc. in doc comments → backtick them.
- `#[must_use]` is expected on functions returning an owned value the caller must use (`ok_empty`, `err`, `catch`).
- `clippy::borrowed_box` → take `&(dyn Any + Send)`, not `&Box<dyn Any + Send>`, in `panic_message`.
- `rustfmt.toml` `ignore` entries are nightly-only and **do not** work on the pinned stable toolchain — irrelevant here (no generated file is touched), but don't rely on `ignore` for any hand-written file.
- The crate's `max_width` is governed by `rustfmt.toml` (120 in the repo, despite project-context saying 100 — a known pre-existing divergence; format with the repo's `rustfmt.toml`, do not hand-wrap to 100).

### Testing standards (project-context § Testing Rules)

- Rust unit tests inline at the bottom of the module they test. ✅ envelope.rs.
- Every test that produces/consumes an FFI buffer reads it through the **generated typed accessors** and runs the **`Verifier`** (`root_with_opts`). No `jsonschema`/`json_schema`. A test that reads a buffer without the typed accessors is incomplete.
- Test names describe the scenario (`catch_panic_returns_internal_panic_envelope`), not the function (`test_catch_2`).
- No `#[ignore]`/`skip:`. No network. Tests don't read the developer's global jj/git config (N/A here — no repo access in this story).

### Project Structure Notes

- File lands at `crates/zanshin-ffi/src/envelope.rs` — matches AR-P-3 (`architecture.md:310`, `:452`) exactly. Module organised by noun, no `mod.rs`, `lib.rs` stays re-exports + docs + `zanshin_ffi_version` only (project-context § File & module organization).
- `docs/rust-error-codes.md` is a planned doc per AR-P-3 (`architecture.md:541`) and project-context § Documentation. This story is the first to create it; every later PR that adds an `error.code` updates it (project-context § Error code taxonomy).
- No Dart-side work in this story. The Dart envelope reader (`app/lib/src/ffi/envelope.dart`) is a later concern; 3-0 already shipped the generated Dart accessors + `FfiBuffer`.

## References

- `_bmad-output/implementation-artifacts/3-0-adopt-flatbuffers-ffi-transport.md` — the foundation this story builds on (schema, generated accessors, buffer-ownership contract, the `root_with_opts` verify-and-read pattern, the clippy/fmt findings).
- `schemas/envelope.fbs` — the committed wire contract (`FfiError { code, context }`, `Payload` union, `Envelope`). Source of truth for the envelope shape.
- `crates/zanshin-ffi/src/lib.rs` — current envelope build/verify test patterns to lift; the `zanshin_ffi_version` placeholder (full impl is Story 3.2, not this one).
- `crates/zanshin-ffi/src/ffi_strings.rs` — the existing ownership helpers (`vec_into_ffi_buf`, `zanshin_buffer_free`, `ZanshinBuf`, `vec_into_token`, `zanshin_buffer_free_token`, `string_to_cstring`, `zanshin_string_free`).
- `docs/adr/0001-ffi-data-transport-flatbuffers.md` — the FlatBuffers decision; the `Envelope`/`FfiError` shape (lines 39–46); "the `catch_unwind` → `internal.panic` rule stands (error becomes an `FfiError`)" (line 104).
- `_bmad-output/project-context.md` § FFI boundary, § Error code taxonomy, § Testing Rules, § Critical Don't-Miss Rules — the binding transport/error/test rules.
- `_bmad-output/planning-artifacts/architecture.md` AD-1 (amended, `:185`), P-3 (`:301`), P-4 (`:325`), and `:641` ("codes emitted from a single `envelope.rs` location"). *(Note `:203` `internal_panic` is a typo — use `internal.panic`.)*
- `_bmad-output/planning-artifacts/epics.md` § Story 3.1 (`:1609`) — the scope-correction callout (`:1611`) is binding; the JSON GWT below it is superseded. FR-FFI-9 (no panic crosses FFI) and NFR-R-3 are the unchanged behavioural requirements.

## Dev Agent Record

### Agent Model Used

claude-sonnet-4-6

### Debug Log References

- One `clippy::map_unwrap_or` lint in test: replaced `.map(|c| c.contains("boom")).unwrap_or(false)` with `.is_some_and(|c| c.contains("boom"))`.
- Two `rustfmt` violations in tests (multi-line closures that fit within `max_width=120`): collapsed both to single-line form.

### Completion Notes List

- Created `crates/zanshin-ffi/src/envelope.rs` with `INTERNAL_PANIC` const, `FfiErrorObj` struct, `ok_empty()`, `err()`, `catch()` builders, private `panic_message()` helper, and 7 inline test functions covering all 8 AC-5.14 cases (panic!("boom") covers the `&str` path; `panic_any(String::from(...))` covers the `String` path; `panic_any(42u8)` covers the `"<unknown panic payload>"` path).
- Updated `crates/zanshin-ffi/src/lib.rs`: added `pub mod envelope; pub use envelope::*;`, removed the two hand-built ok/error roundtrip tests (now in `envelope.rs`), simplified `envelope_buffer_ffi_roundtrip` to use `crate::err()`.
- Created `docs/rust-error-codes.md` as the AR-P-4 canonical registry with convention header, domain list, and all 10 AC-4 codes with status.
- No generated files modified. `cargo make codegen` not run. `cargo make test` fully green (18 zanshin-ffi tests + 13 repo tests + all other suite members).

### File List

- `crates/zanshin-ffi/src/envelope.rs` (new)
- `crates/zanshin-ffi/src/lib.rs` (modified)
- `docs/rust-error-codes.md` (new)
- `_bmad-output/implementation-artifacts/sprint-status.yaml` (modified — status tracking)

### Change Log

- 2026-06-15 (Story 3.1 implementation): Created `envelope.rs` with `FlatBuffers` envelope builders (`ok_empty`, `err`, `catch`), AR-P-4 `INTERNAL_PANIC` constant, `FfiErrorObj` struct, `panic_message` helper, and 7 inline tests covering all 8 AC-5 scenarios. Updated `lib.rs` to declare and re-export the new module; simplified existing `envelope_buffer_ffi_roundtrip` test to use `err()`. Created `docs/rust-error-codes.md` AR-P-4 registry.

## Review Findings

_Code review 2026-06-15 — adversarial 3-layer (Blind Hunter + Edge Case Hunter + Acceptance Auditor). Acceptance Auditor verdict: 17/18 ACs PASS, AC-7.18 PARTIAL (quality gate not executed during the review). No guardrail violations. 13 findings dismissed as by-design / spec-sanctioned / false-positive._

- [x] [Review][Patch] Full panic-backstop hardening (resolved 2026-06-15 from a decision-needed finding; chosen: harden fully) — ✅ APPLIED 2026-06-15 — `catch`'s error/panic arms call `err()` *outside* `catch_unwind` (`envelope.rs:96-97`), so a panic inside `err()`/`panic_message` would unwind past the future FFI boundary. Harden so `catch` can never unwind across the C ABI: wrap the error-envelope build in a nested `catch_unwind` and fall back to a `const` pre-serialized `internal.panic` envelope buffer (kept honest by a test asserting `err(INTERNAL_PANIC, None) == const`); add a doc-note on `catch` that it relies on `panic = "unwind"`. [crates/zanshin-ffi/src/envelope.rs]
- [x] [Review][Patch] Use the re-exported `crate::INTERNAL_PANIC` constant instead of the bare `"internal.panic"` string literal in the FFI-roundtrip test (build call + assertion) [crates/zanshin-ffi/src/lib.rs:57,69] — ✅ APPLIED 2026-06-15

_Patches applied 2026-06-15. New tests: `panic_fallback_const_matches_builder`, `panic_fallback_const_is_a_valid_error_envelope`, `err_never_unwind_matches_err_on_normal_input` (envelope.rs). Verified: `cargo fmt` clean, `cargo clippy -p zanshin-ffi --all-targets -- -D warnings` clean (pedantic via workspace lints), `cargo test -p zanshin-ffi` → 21/21 pass._
- [x] [Review][Defer] `FlatBuffers` verifier does not enforce `ok==false ⇒ error present` (schema marks no field `required`) [schemas/envelope.fbs] — deferred, pre-existing (3-0 schema; 3-1 builders always populate `error` on the error path, so this is a defense-in-depth gap, not a 3-1 defect)
