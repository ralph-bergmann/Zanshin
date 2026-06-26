---
baseline_commit: 989c0f1
---

# Story 3.4b — `zanshin_remotes` FFI wrapper + Dart remotes seam (remotes slice)

Status: done

<!-- Note: Validation is optional. Run validate-create-story for quality check before dev-story. -->

> **This is the `remotes` slice of Story 3.4b — the LAST read-path wrapper.** Per the 2026-06-15 WIP
> re-sequencing (sprint-status.yaml:91-114), Story 3.4b lands one thin read-path wrapper **per finished
> Epic-2 noun**, each made "aus Flutter testbar" the moment its jj-lib noun is `done`:
>
> | Epic-2 noun (source) | 3.4b slice            | gate |
> |----------------------|-----------------------|------|
> | 2.4 `status` ✅ done   | `zanshin_status` ✅ done | shipped |
> | 2.6 `change` ✅ done   | `zanshin_change` ✅ done | shipped |
> | 2.7 `op_log` ✅ done   | `zanshin_op_log` ✅ done | shipped |
> | 2.8 `bookmarks` ✅ done | `zanshin_bookmarks` ✅ done | shipped |
> | **2.9 `remotes`**    | **`zanshin_remotes` (THIS story)** | ⛔ **gated on 2.9** |
>
> This completes the read-path FFI wrappers. `zanshin_revset_resolve` (2.5) "flows into the others" and is
> **not** a 3.4b slice (epics.md:2156 lists it, but 2.5 is a pure-Rust helper; no dedicated wrapper is
> planned in this story). **Stay in this slice** — `remotes` only.

> ## ⛔ HARD GATE — Story 2.9 must be `done` first
>
> This wrapper only **exposes** `zanshin_jj::Repo::list_remotes()`; it never adds it. As of this story's
> creation `crates/zanshin-jj/src/remotes.rs` does **not** exist (sprint-status.yaml:79 — 2.9 is
> `backlog`/`ready-for-dev`). **Do not start the Rust side until Story 2.9 is `done`.** Before writing
> `map_remotes_err` / the `Remote`/`Remotes` FlatBuffers tables, **read the real
> `crates/zanshin-jj/src/remotes.rs`** and confirm the actual public shape — the `Remote` field set
> (`name`, `url`), the `RemoteError` variants, and the fallible-`Result`/push-URL decisions are subject to
> 2.9's resolved Open Questions (2.9 OQ2/OQ4). The shapes below assume 2.9's **recommended defaults**
> (`Remote { name, url }`, single `Backend(String)` error, fetch URL only); reconcile if Ralph overrode them.
> [verified: sprint-status.yaml:79-80; 2-9-implement-remotes-rs-list-remotes-read-only.md]

---

## ⚠️ CRITICAL — Read this before writing any code (spec reconciliation)

The Story 3.4b acceptance criteria in `epics.md` (lines 2147-2249) are **stale** and are superseded here.
Treat the ACs in *this* file as the binding contract, not the epic prose:

1. **Transport is FlatBuffers, not JSON (ADR-0001).** The epic says `zanshin_remotes(handle)` "returns an
   envelope with `data` as the corresponding array" routed through a JSON envelope (epics.md:2209-2211).
   **Superseded.** Composite FFI data crosses as a FlatBuffers `Envelope` token (`*mut ZanshinBuf`); there is
   no JSON, no `serde::Serialize` on `Remote`, no `jsonschema`. This slice **adds one `Payload` member**
   (`Remotes`) and consumes the existing 3-0…3-4a / 3.4b-status/change/op_log/bookmarks infrastructure.
   [Source: docs/adr/0001; project-context.md `overrides:`; epics.md:2151,2209-2211]
2. **`remotes` is HANDLE-ONLY — no scalar, no string argument.** Like `status` and `bookmarks` (and unlike
   `op_log`'s scalar `limit` / `change`'s lone-string `change_id`), `zanshin_remotes` takes **only** the
   handle — the simplest **status/bookmarks** marshalling shape. So there is **no** `cstr_to_string`, **no**
   `ffi.null_pointer` / `ffi.utf8_error` error arm, **no** `std::ffi::c_char` import, and **no** null/utf8
   tests. The function is named **`zanshin_remotes`** (AR-P-1: `zanshin_<noun>_<verb>`; noun = `remotes`,
   verb elided as the bare list read, exactly like `zanshin_status` / `zanshin_bookmarks`).
   [Source: epics.md:2151,2156; crates/zanshin-ffi/src/{status.rs,bookmarks.rs}]
3. **The `zanshin_repo_*` ACs in the epic are owned by Story 3.4a (`done`).** Ignore the epic's 3.4b
   `zanshin_repo_open/init/clone/close` signatures entirely. This slice adds **one new function**:
   `zanshin_remotes`.
4. **Handle is a `u64` integer, not `*mut c_void`.** Per the committed 3.4a/status/change/op_log/bookmarks
   ABI, handles cross as a `u64`; `zanshin_remotes` takes that `u64` back and **borrows** the `Repo` (it does
   *not* consume/close it). Null handle (`0`) → `ffi.invalid_handle`.

The **done** sibling **Story 3.4b-bookmarks** (`3-4b-zanshin-bookmarks-ffi-wrapper.md`) is the authoritative
pattern for everything here — handle-only marshalling, the list-of-tables builder, error mapping, codegen
discipline, and the full Dart seam. **Mirror it exactly.** `remotes` is structurally **simpler than
bookmarks**: a `Remote` is just two strings (`name`, `url`) — there is **no sum-type `kind`**, so **no flatc
`enum`, no sealed Dart class, no `_mapKind`**. The wire `Remote` table is the plainest two-string shape
(closer to `Diagnostics` than to `Bookmark`), and the builder mirrors `bookmarks_to_envelope`'s
vector-of-tables loop **minus** the kind match.

> ### ⚠️ PATH CORRECTION — the Dart bridge lives in `packages/zanshin_core`
> The pure-Dart bridge is the `zanshin_core` package (the older `app/lib/src/...` template paths are STALE —
> verified against the live tree). Use these CURRENT paths throughout:
> | Layer | CURRENT path |
> |---|---|
> | FFI adapter + model + decode | `packages/zanshin_core/lib/src/ffi/remotes.dart` |
> | Worker command / dispatch / handle | `packages/zanshin_core/lib/src/worker/{commands,isolate,handle}.dart` |
> | Generated (codegen) | `packages/zanshin_core/lib/src/ffi/{bindings,envelope_zanshin.ffi_generated}.dart` |
> | Dart tests | `packages/zanshin_core/test/{worker,ffi}/remotes_test.dart` |
> Tests import via package URIs (`import 'package:zanshin_core/src/ffi/remotes.dart';`); inside the package
> use relative imports (`import '../ffi/remotes.dart' as repo_ffi_remotes;`). The **Rust** paths are
> unchanged (`crates/zanshin-ffi/src/`, `schemas/envelope.fbs`, `crates/zanshin-ffi/include/zanshin_ffi.h`).
> [verified: `[[project-3-4b-template-dart-paths-stale]]`; packages/zanshin_core/lib/src/ffi/bookmarks.dart]

---

## Scope (read once, then never widen)

**IN scope — the full Dart↔Rust bridge for `remotes`** (the bridge is in scope per
`[[feedback-scope-bridge-is-claudes-ui-is-ralphs]]`; only the Flutter UI is out):

- **Rust:** extend `schemas/envelope.fbs` (`Remote` + `Remotes` tables; append `Remotes` to `Payload`); new
  `extern "C" zanshin_remotes(handle: u64) -> *mut ZanshinBuf` in a new `crates/zanshin-ffi/src/remotes.rs`;
  map `&[zanshin_jj::Remote]` → FlatBuffers `Remotes`; map `RemoteError` → `error.code` (**reuses
  `jj.jj_lib_error` — no new code**); regenerate + commit all five codegen artifacts; Rust unit +
  integration tests.
- **Dart:** `RemotesCommand` (worker command, carries `handleId`); the worker-isolate dispatch case; the
  `zanshinRemotes(int)` FFI adapter; main-side decode into a Dart `List<Remote>`; `ZanshinWorker.remotes()`
  + `RepoHandle.remotes()`; a Dart worker round-trip test against the **real cdylib** + a decode-contract
  unit test.

**OUT of scope:**

- Any Flutter widget / screen that *displays* remotes (Ralph's separate work).
- `zanshin_revset_resolve` (2.5 is a pure-Rust helper, no dedicated wrapper).
- The watcher (Stories 3.5/3.6) — `remotes` is a one-shot read; ADR-0002 re-resolves to head per call.
- Any `zanshin-jj` change — `Repo::list_remotes()` ships in **Story 2.9**. This slice only *exposes* it.
  (If 2.9 isn't `done`, see the HARD GATE above — do not implement 2.9 here.)
- Remote **CRUD / fetch / push** — FR-JJ-13 fetch/push is Epic 6 (Story 6.4a); this is read-only.
- Credential scrubbing / SSH→HTTPS rewriting — `Remote.url` is verbatim from 2.9 (the wire carries it as-is).

---

## Story

As the Dart worker isolate (and, behind it, Ralph's future Flutter UI),
I want an `extern "C" zanshin_remotes(handle)` wrapper that calls `zanshin_jj::Repo::list_remotes()` and
returns the remote list as a FlatBuffers `Envelope`, plus the Dart command/adapter/decode seam that turns it
into a typed `List<Remote>`,
so that the remotes read-path noun is callable end-to-end from Dart against a real repo — completing the
read wrappers for the open-project flow (status / change / op_log / bookmarks / **remotes**).

---

## Acceptance Criteria

Grouped by deliverable. Each item is a checkable contract. The 9-group structure mirrors the `done`
`bookmarks`/`status` slices; remotes-specific divergences are flagged inline.

### AC-1 — wire schema: `Remote` + `Remotes` payload (`schemas/envelope.fbs`)

1. `schemas/envelope.fbs` gains, in `snake_case` (flatc emits `lowerCamelCase` getters), the plainest
   two-string table (no enum, no companion field — simpler than `Bookmark`):
   ```fbs
   /// One configured git remote (FR-JJ-9). `url` is the fetch URL, verbatim —
   /// credentials are NOT scrubbed and SSH is NOT rewritten to HTTPS.
   table Remote {
     name: string;   // remote name, e.g. "origin" (UTF-8)
     url: string;    // fetch URL, verbatim
   }

   /// The remote list: configured git remotes, sorted by name.
   table Remotes {
     remotes: [Remote];
   }
   ```
2. The new `Remotes` table is **appended** to the `Payload` union — never reordered (union tags are
   positional; reordering breaks the wire for `RepoHandle`/`Diagnostics`/`Status`/`Change`/`OpLog`/`Bookmarks`):
   ```fbs
   union Payload { RepoHandle, Diagnostics, Status, Change, OpLog, Bookmarks, Remotes }
   ```
   (`Remotes` becomes discriminant **7**, after `Bookmarks = 6`.)
3. The schema roadmap comment (envelope.fbs:36) is ticked: `Story 3-4b : status ✓, change ✓, op_log ✓, bookmarks ✓, remotes ✓`.
4. **Reconcile to the shipped 2.9 struct (HARD GATE).** The `Remote` table fields match the real
   `zanshin_jj::Remote` shape from Story 2.9 (`name`, `url`). If 2.9 added `push_url` (2.9 OQ4), add a
   `push_url: string` field to match — the wire mirrors the domain type, not this draft.

### AC-2 — `&[zanshin_jj::Remote]` → FlatBuffers mapping

5. A builder `fn remotes_to_envelope(remotes: &[Remote]) -> Vec<u8>` in `crates/zanshin-ffi/src/remotes.rs`
   serialises the slice into a finished `Envelope<Remotes>` buffer. It builds **children before parents**
   (FlatBuffers requirement): for each `Remote`, create its `name` / `url` strings, then the `Remote` table;
   collect the offsets; then `create_vector` + the `Remotes` table; then the `Envelope` with
   `data_type = Payload::Remotes`.
6. Field-by-field mapping with no recomputation: `name → r.name`; `url → r.url`. `b.finish(envelope, None)`
   — **plain finish, NOT size-prefixed** (length rides in `ZanshinBuf.len`, exactly as `bookmarks_to_envelope`).

### AC-3 — `zanshin_remotes` extern function

7. `crates/zanshin-ffi/src/remotes.rs` defines `#[no_mangle] pub unsafe extern "C" fn zanshin_remotes(handle: u64) -> *mut ZanshinBuf`, with a `# Safety` doc block (mirroring `zanshin_bookmarks`) and a `# Errors` doc block; `crates/zanshin-ffi/src/lib.rs` adds `pub mod remotes;`.
8. The body is wrapped in `envelope::catch(|| { … })` (panic backstop → `internal.panic`); emits a `debug!(fn_name = "zanshin_remotes", handle)` span (handle-only, exactly like `zanshin_bookmarks` — no extra scalar field).
9. The repo is **borrowed** (not consumed): `handle_from_raw::<Repo>(handle as *mut Repo)`; `None`/`handle == 0` → `FfiErrorObj { code: FFI_INVALID_HANDLE, context: None }` (`ffi.invalid_handle`). The call is `repo.list_remotes().map_err(map_remotes_err)?`, then `Ok(remotes_to_envelope(&rems))`. The returned `*mut ZanshinBuf` is produced by `vec_into_token(buf)` and freed exactly once by Dart.

### AC-4 — `RemoteError` → `error.code` mapping (NO new code)

10. `fn map_remotes_err(e: RemoteError) -> FfiErrorObj` maps the single variant `RemoteError::Backend(reason)` → `FfiErrorObj { code: JJ_JJ_LIB_ERROR.to_owned(), context: Some(reason) }` (`jj.jj_lib_error`, the existing catch-all).
11. **No new error code is introduced.** Remote listing has no "not found" failure (listing never misses), so — exactly like `op_log`/`bookmarks` (and unlike `status`'s `jj.no_working_copy` / `change`'s `jj.change_not_found`) — there is **no** new `pub const` in `envelope.rs` and **no** new row in `docs/rust-error-codes.md`. If 2.9 shipped a non-`Backend` `RemoteError` variant (it should not — 2.9 D3), add the code per the registry's 4-step process; otherwise leave `envelope.rs` and the registry untouched. [Source: docs/rust-error-codes.md:44; 2.9 AC-8; 3-4b-bookmarks AC-4]

### AC-5 — codegen committed

12. `cargo make codegen` is run and **all five** generated artifacts are committed; generated files are **never** hand-edited. Run codegen **TWICE**: once after the `schemas/envelope.fbs` edit (regenerates the FlatBuffers accessors), and again after the new `zanshin_remotes` extern symbol exists (regenerates the C header + ffigen bindings). The artifacts:
    - `crates/zanshin-ffi/src/envelope_generated.rs` (gains `Remote`/`Remotes` + builders + `Remotes` in the `Payload` union; `data_as_remotes()` accessor),
    - `packages/zanshin_core/lib/src/ffi/envelope_zanshin.ffi_generated.dart` (gains `Remote`/`RemoteObjectBuilder`, `Remotes`/`RemotesObjectBuilder`, `Remotes` in `PayloadTypeId`),
    - `crates/zanshin-ffi/include/zanshin_ffi.h` (gains `ZanshinBuf *zanshin_remotes(uint64_t handle);`),
    - `packages/zanshin_core/lib/src/ffi/bindings.dart` (gains the `external` `zanshin_remotes` binding — `@ffi.Native<ffi.Pointer<ZanshinBuf> Function(ffi.Uint64)>()`),
    - `schemas/envelope.fbs` (the hand-edited source, AC-1).

### AC-6 — Rust tests

13. **Builder unit test** in `remotes.rs` `#[cfg(test)]`: construct a `Vec<zanshin_jj::Remote>` with **≥2 entries with DISTINCT `name`/`url`** (e.g. `origin`=https + `upstream`=ssh, **including one with embedded credentials** to assert no scrubbing happens on the wire). Serialise via `remotes_to_envelope`, parse with `flatbuffers::root::<fbs::Envelope>` (runs the `Verifier`), assert `ok`, `data_type == Payload::Remotes`, `remotes().len()`, and that **every field round-trips by equality per index**: `name` and `url` for each entry (distinct values catch a cross-wired-offset builder bug). Mirror the `bookmarks_to_envelope_roundtrips_both_kinds` test. Also an **empty** builder test (`remotes_to_envelope(&[])` → `ok`, `data_type == Remotes`, `remotes().map_or(0, |r| r.len()) == 0`).
14. **`map_remotes_err` unit test**: `map_remotes_err(RemoteError::Backend("boom".into()))` → `code == JJ_JJ_LIB_ERROR`, `context == Some("boom")`. (Single arm — `RemoteError` has only `Backend`; mirror `bookmarks.rs` / `op_log.rs:214-217`.)
15. **Integration tests** `crates/zanshin-ffi/tests/remotes_ffi.rs` (NEW), mirroring `tests/bookmarks_ffi.rs` harness (`ENV_GUARD`/`pin_env`, `read_and_free(token)`, `parse_envelope(bytes)`, an `open_fixture()` helper returning the handle):
    - **empty round-trip:** open `tiny-3-commits` → `zanshin_remotes(handle)` → `ok`, `data_type == Remotes`, `remotes().map_or(0, |r| r.len()) == 0` → `zanshin_repo_close`.
    - **empty on a large real repo:** open `medium-1k-commits` → `ok`, `data_type == Remotes`, `remotes().map_or(0, |r| r.len()) == 0` → close. (Both fixtures are remote-free — unlike `bookmarks` where medium had 29 local; there is **no** populated-from-fixture remotes assertion possible. Add a one-line comment noting the fixtures have zero remotes.)
    - **invalid handle:** `zanshin_remotes(0)` → `ok == false`, `error.code == ffi.invalid_handle`.
    - (**No null/utf8 tests** — remotes has no CString arg; this asymmetry vs. `change` is deliberate — add a one-line comment noting it, exactly like the bookmarks slice.)
16. Buffers are read **only** through the generated typed accessors + `Verifier` — no `jsonschema`, no hand-parsing. Every token is freed; env is pinned; no network. (The **populated** round trip through the real extern is NOT exercised live — the committed fixtures have no remotes and the FFI test layer cannot import `jj_lib`/`gix` to construct one; populated coverage is piecewise: 2.9's zanshin-jj integration test + this builder unit test + the Dart synthetic decode test. See AC-9 coverage note + the deferred item.)

### AC-7 — Dart bridge (paths = `packages/zanshin_core/...`)

17. `packages/zanshin_core/lib/src/worker/commands.dart` gains `final class RemotesCommand extends WorkerCommand { const RemotesCommand({required super.commandId, required this.handleId}); final int handleId; }` (handle-only, mirror `BookmarksCommand`/`StatusCommand`). Adding the sealed subclass forces the worker `switch` to handle it (compile-time exhaustiveness).
18. `packages/zanshin_core/lib/src/worker/isolate.dart`: add the import alias `import '../ffi/remotes.dart' as repo_ffi_remotes;` in **correct alphabetical position** (`directives_ordering` lint — every prior slice hit this); add the worker dispatch `case RemotesCommand(:final int handleId):` that **looks up** `handles[handleId]` (never removes), sends an `ffi.invalid_handle` `EnvelopeObjectBuilder` error envelope for an unknown handle, else `responseSP.send((commandId, BufferResult(repo_ffi_remotes.zanshinRemotes(raw))))`; add the main-side `Future<List<Remote>> remotes(int handleId)` that `send`s `RemotesCommand` and returns `repo_ffi_remotes.decodeRemotesEnvelopeInternal(bytes)`.
19. `packages/zanshin_core/lib/src/ffi/remotes.dart` (NEW): the `Uint8List zanshinRemotes(int rawHandle)` adapter (mirror `bookmarks.dart` — pass the handle straight through, read the token via `FfiBuffer.fromToken`, dispose in `finally`; **no** `toNativeUtf8`/`calloc.free`); a Dart `Remote` model (see AC-21); and the decode pair `@visibleForTesting List<Remote> decodeRemotesEnvelope(Uint8List)` + `List<Remote> decodeRemotesEnvelopeInternal(Uint8List)` delegating to a private `_decodeRemotesEnvelope` (throws `ZanshinFfiException(code, context)` on `!ok`; guards `payload is! fbs.Remotes` → `ZanshinFfiException('ffi.unknown', 'expected Remotes payload, got ${env.dataType}')`; maps `payload.remotes` → `List<Remote>`, `?? const []`).
20. `packages/zanshin_core/lib/src/worker/handle.dart`: add `import '../ffi/remotes.dart' show Remote;` and a `Future<List<Remote>> remotes()` method with the synchronous `if (_closed) { throw StateError('RepoHandle is already closed'); }` guard, delegating to `_worker.remotes(_handleId)`.
21. The Dart `Remote` is a plain immutable value (NO sealed class — there is no sum type here, unlike `bookmarks`):
    ```dart
    final class Remote {
      const Remote({required this.name, required this.url});
      final String name;
      final String url; // fetch URL, verbatim (credentials not scrubbed)
    }
    // _mapRemote(fbs.Remote r) => Remote(name: r.name ?? '', url: r.url ?? '');
    ```
    Mirror the 2.9 domain type (name, url) — do NOT add fields the wire doesn't carry. (`?? ''` is correct here: both fields are legitimately nullable strings that collapse to `''`, exactly like `Diagnostics`/`Operation` plain-string fields — there is no "corruption ≠ null" case as there was for the `Bookmark` remote_name identity field. See OQ3.)
22. No `dart:ffi` type leaks out of `packages/zanshin_core/lib/src/ffi/`; the worker command/response protocol and `CommandCorrelator` are reused unchanged (`remotes` replies as the existing `BufferResult` — no new `WorkerResponse` type). `responses.dart` and `zanshin_core.dart` (public export) are **unchanged** (the op_log/bookmarks precedent keeps per-noun models un-exported from the barrel — see OQ4).

### AC-8 — Dart tests (paths = `packages/zanshin_core/test/...`)

23. `packages/zanshin_core/test/worker/remotes_test.dart` (NEW), real cdylib (no mocks), mirroring `test/worker/bookmarks_test.dart`: `ZanshinWorker.start()` + `initRepo(tempDir.path, backend: 1)` → `handle.remotes()` round-trip. A freshly-`init`-ed jj repo has **no** remotes, so assert the concrete expected shape — `remotes` **`isEmpty`** (NOT a vacuous `isNotNull`; F20 rule). Plus: an oracle-equality cross-call (`remotes()` twice → element-wise equal by name/url); closed-handle → `ffi.invalid_handle` (close the handle, then call `worker.remotes(handle.handleId)` directly, bypassing the guard, expect `ZanshinFfiException` with `code == 'ffi.invalid_handle'`); `RepoHandle.remotes` on a closed handle → synchronous `StateError`. **This worker round-trip is the cross-FFI coverage driver for `crates/zanshin-ffi/src/remotes.rs`** (see AC-9). (`backend: 1` = Git — the only backend; 2.9's `list_remotes` needs a git-backed store to return remotes, though here the fresh repo has none.)
24. `packages/zanshin_core/test/ffi/remotes_test.dart` (NEW), decode-contract via synthetic buffers (generated `EnvelopeObjectBuilder` / `RemotesObjectBuilder` / `RemoteObjectBuilder`), mirroring `test/ffi/bookmarks_test.dart`: error envelope → `ZanshinFfiException` (code + context asserted); `ok == true` with a **non-`Remotes`** payload (e.g. `RepoHandle`) → `ffi.unknown`; a fully-populated `Remotes` (≥2 entries with distinct name/url, **including an embedded-credential url**) → every decoded field equals the builder input (EQUALITY), incl. the credential url surviving verbatim; an **empty** `Remotes` → `isEmpty`. (This synthetic test is where the **populated decode** is exercised, since the live fixtures have no remotes.)

### AC-9 — quality gate green (incl. coverage ratchet)

25. `cargo make test` passes end-to-end: `cargo clippy --workspace --all-targets -- -D warnings` (pedantic — **refactor, don't `#[allow]`**; any unavoidable suppression carries a `// WHY:`), `cargo fmt --all --check`, all Rust unit + integration tests, `cargo deny check advisories bans`, the cargo-hygiene gate, the Dart suite (`flutter test`, incl. the new worker + decode tests), `dart analyze --fatal-infos --fatal-warnings`, and `dart format` — all clean. **Plus the coverage ratchet** (`cargo make coverage`): the new `crates/zanshin-ffi/src/remotes.rs` reaches the per-file floor (≥ 80 %; aim for **100 %** like the `bookmarks.rs`/`status.rs` wrappers). **Coverage attribution (the known trap):** the `remotes_to_envelope` builder + `map_remotes_err` are covered by the cargo **unit** tests (regular fns, attributed); the `#[no_mangle] zanshin_remotes` entry + the `ffi.invalid_handle` branch are covered by the **Dart worker round-trip** through the real cdylib (a cargo test's call to the `#[no_mangle]` symbol is NOT attributed to the coverage union — this is exactly the gap the op-log/bookmarks slices closed; MEMORY: `[[project-coverage-extern-fn-needs-zanshin-core-test]]`). The auto-raised `coverage-baseline.txt` is committed. `crates/zanshin-ffi/src/envelope.rs` stays 100 % (no new executable line). **Never lower the baseline or add an `exclude_prefix`.** [Source: CLAUDE.md; coverage-baseline.txt; 3-4b-bookmarks Review §coverage]
26. Every new hand-written `.rs`/`.dart` file starts with `// SPDX-License-Identifier: MIT` (generated files exempt). No `unsafe` outside the documented `extern "C"` seam; the `extern "C"` fn carries a `# Safety` doc section and every `unsafe` block a `// SAFETY:` comment. No new crate, no `Cargo.toml` dependency change.

## Tasks / Subtasks

- [x] **T0 — Confirm the 2.9 gate** (HARD GATE)
  - [x] Verify Story 2.9 is `done` in sprint-status.yaml. Read the shipped `crates/zanshin-jj/src/remotes.rs`; confirm `Remote` fields (`name`, `url`), `RemoteError` variants, and whether 2.9 added `push_url` (2.9 OQ4). Reconcile AC-1/AC-4 if Ralph overrode 2.9 defaults.
- [x] **T1 — Extend the wire schema** (AC: 1, 2, 3, 12)
  - [x] Edit `schemas/envelope.fbs`: add the `Remote` + `Remotes` tables; **append** `Remotes` to `union Payload` (discriminant 7); tick the roadmap comment. Run `cargo make codegen` (pass 1).
- [x] **T2 — `remotes.rs`: builder + wrapper + error mapping** (AC: 5, 6, 7, 8, 9, 10, 11)
  - [x] Create `crates/zanshin-ffi/src/remotes.rs` (SPDX MIT line 1) + add `pub mod remotes;` to `lib.rs`. Implement `remotes_to_envelope` (list-of-tables, **no kind match** — mirror `bookmarks_to_envelope` minus the enum), `map_remotes_err` (single arm → `jj.jj_lib_error`), and `zanshin_remotes` (catch-wrapped, borrow handle, handle-only). **No `envelope.rs` / `docs/rust-error-codes.md` change** (AC-11).
- [x] **T3 — Regenerate the FFI surface** (AC: 12)
  - [x] Run `cargo make codegen` (pass 2) after the new extern symbol; confirm `zanshin_remotes` in `zanshin_ffi.h` + `bindings.dart`; commit all five artifacts. Never hand-edit generated files.
- [x] **T4 — Rust tests** (AC: 13, 14, 15, 16)
  - [x] Builder unit test (≥2 distinct entries incl. embedded-credential url; field equality per index) + empty builder test + `map_remotes_err` test in `remotes.rs`; `crates/zanshin-ffi/tests/remotes_ffi.rs` (empty on tiny, empty on medium, invalid handle; no null/utf8 tests).
- [x] **T5 — Dart bridge** (AC: 17, 18, 19, 20, 21, 22)
  - [x] `RemotesCommand` in `commands.dart`; dispatch `case` + `remotes()` main-side method + import alias (alphabetical!) in `isolate.dart`; `ffi/remotes.dart` (adapter + plain `Remote` model + decode pair, **no sealed class**); `RepoHandle.remotes()` + `show Remote` import in `handle.dart`. All under `packages/zanshin_core/`.
- [x] **T6 — Dart tests** (AC: 23, 24)
  - [x] `test/worker/remotes_test.dart` (real-cdylib round-trip, empty-isEmpty, oracle equality, closed-handle ffi.invalid_handle, StateError) + `test/ffi/remotes_test.dart` (decode-contract synthetic incl. credential url verbatim). Under `packages/zanshin_core/test/`.
- [x] **T7 — Coverage** (AC: 25)
  - [x] Confirm `remotes.rs` (ffi) clears the floor (target 100 %): builder+map unit tests (cargo) + the Dart worker round-trip (cdylib) for the extern entry + invalid-handle branch. Commit the auto-raised `coverage-baseline.txt`.
- [x] **T8 — Gate** (AC: 25, 26)
  - [x] `cargo make test` green end-to-end (Rust + Dart + deny + coverage); clippy pedantic; fmt; `dart analyze`/`format` clean; SPDX on new files.

## Dev Notes

### What you build on — exact, verified signatures (reuse, do not re-add)

From `crates/zanshin-ffi/src/` (all `done`, verified live against the bookmarks slice):
- `envelope::catch<F: FnOnce() -> Result<Vec<u8>, FfiErrorObj>>(f) -> Vec<u8>` (envelope.rs:180) — the panic backstop wrapping every wrapper body (→ `internal.panic` on panic).
- `envelope::FfiErrorObj { pub code: String, pub context: Option<String> }` (envelope.rs:53); consts `FFI_INVALID_HANDLE` (`ffi.invalid_handle`, envelope.rs:18), `JJ_JJ_LIB_ERROR` (`jj.jj_lib_error`, envelope.rs:31) — both re-exported at the crate root via `pub use envelope::*;`.
- `handle::handle_from_raw::<Repo>(ptr: *mut Repo) -> Option<&mut Repo>` (handle.rs) — borrows (does NOT drop) the boxed `Repo`.
- `ffi_strings::{vec_into_token(Vec<u8>) -> *mut ZanshinBuf, ZanshinBuf, zanshin_buffer_free_token}` (ffi_strings.rs:122).
- `crate::fbs` = `pub use envelope_generated::zanshin::ffi as fbs;` (lib.rs:27) — the alias every wrapper uses for generated types.
- The handle-only + list-of-tables template is **`crates/zanshin-ffi/src/bookmarks.rs`** — `remotes` is the same minus the per-entry kind match (a `Remote` is just two strings).

### The `zanshin_remotes` wrapper (sketch — mirror `zanshin_bookmarks`, drop the kind match)

```rust
// SPDX-License-Identifier: MIT

//! `zanshin_remotes` — remote-list read FFI wrapper (Story 3.4b, remotes slice).
//!
//! Calls `zanshin_jj::Repo::list_remotes()` and serialises the result into a
//! `FlatBuffers` `Envelope` carrying a `Remotes` payload. The handle is borrowed
//! (not consumed). `url` crosses the wire verbatim (no credential scrubbing).

use flatbuffers::FlatBufferBuilder;
use tracing::debug;
use zanshin_jj::{Remote, RemoteError, Repo};

use crate::envelope::{catch, FfiErrorObj, FFI_INVALID_HANDLE, JJ_JJ_LIB_ERROR};
use crate::fbs;
use crate::ffi_strings::{vec_into_token, ZanshinBuf};
use crate::handle::handle_from_raw;

fn map_remotes_err(e: RemoteError) -> FfiErrorObj {
    match e {
        RemoteError::Backend(reason) => FfiErrorObj {
            code: JJ_JJ_LIB_ERROR.to_owned(),
            context: Some(reason),
        },
    }
}

/// Serialise `&[Remote]` into a finished `Envelope<Remotes>` buffer.
/// Children before parents: each `Remote`'s strings are built before its table;
/// the `remotes` vector + `Remotes` table come after the loop.
fn remotes_to_envelope(remotes: &[Remote]) -> Vec<u8> {
    let mut b = FlatBufferBuilder::with_capacity(1024);
    let mut offsets = Vec::with_capacity(remotes.len());
    for r in remotes {
        let name_off = b.create_string(&r.name);
        let url_off = b.create_string(&r.url);
        let r_off = fbs::Remote::create(
            &mut b,
            &fbs::RemoteArgs {
                name: Some(name_off),
                url: Some(url_off),
            },
        );
        offsets.push(r_off);
    }
    let vec = b.create_vector(&offsets);
    let rems_off = fbs::Remotes::create(&mut b, &fbs::RemotesArgs { remotes: Some(vec) });
    let envelope = fbs::Envelope::create(
        &mut b,
        &fbs::EnvelopeArgs {
            ok: true,
            error: None,
            data_type: fbs::Payload::Remotes,
            data: Some(rems_off.as_union_value()),
        },
    );
    b.finish(envelope, None);
    b.finished_data().to_vec()
}

/// List the configured git remotes of the repo identified by `handle`.
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
pub unsafe extern "C" fn zanshin_remotes(handle: u64) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_remotes", handle);
    let buf = catch(|| {
        // SAFETY: non-zero handle originated from handle_into_raw (Box<Repo>);
        // single-isolate model (AD-2) guarantees no concurrent access.
        let repo = unsafe { handle_from_raw::<Repo>(handle as *mut Repo) }.ok_or_else(|| FfiErrorObj {
            code: FFI_INVALID_HANDLE.to_owned(),
            context: None,
        })?;
        let rems = repo.list_remotes().map_err(map_remotes_err)?;
        Ok(remotes_to_envelope(&rems))
    });
    vec_into_token(buf)
}
```

### Where the mapping lives — `remotes.rs`, not `envelope.rs`

Keep the domain mapping in the **noun module** (`crates/zanshin-ffi/src/remotes.rs`), exactly as the
`status`/`op_log`/`bookmarks` slices put it in their noun modules. `envelope.rs`'s builders take only
primitives / `FfiErrorObj` and never import a `zanshin-jj` domain type. So this slice adds **no** function to
`envelope.rs`, and (per AC-11) **no** new error const.

### Dart seam — mirror the `bookmarks` seam, minus the sealed-kind machinery (paths = `packages/zanshin_core/...`)

- **Command** (`worker/commands.dart`): mirror `BookmarksCommand` (handle-only):
  ```dart
  final class RemotesCommand extends WorkerCommand {
    const RemotesCommand({required super.commandId, required this.handleId});
    final int handleId; // opaque dense id (NOT a raw pointer)
  }
  ```
- **Worker dispatch** (`worker/isolate.dart`): mirror the `BookmarksCommand` case — `final int? raw = handles[handleId];` (**lookup, never remove**); unknown → `fbs.EnvelopeObjectBuilder(ok: false, error: fbs.FfiErrorObjectBuilder(code: 'ffi.invalid_handle', context: 'unknown or closed handleId: $handleId')).toBytes()`; else `responseSP.send((commandId, BufferResult(repo_ffi_remotes.zanshinRemotes(raw))))`. Add `import '../ffi/remotes.dart' as repo_ffi_remotes;` in **alphabetical** position (the prior slices recorded a `directives_ordering` fix here — `remotes` sorts after `op_log`/`bookmarks`/`change`, before `status`).
- **Main-side `ZanshinWorker.remotes`** (`worker/isolate.dart`, mirror `bookmarks`):
  ```dart
  Future<List<Remote>> remotes(int handleId) async {
    final Uint8List bytes = await send(
      RemotesCommand(commandId: _correlator.allocateId(), handleId: handleId),
    );
    return repo_ffi_remotes.decodeRemotesEnvelopeInternal(bytes);
  }
  ```
  The close-guard `StateError` is delivered **synchronously by `RepoHandle.remotes`**, not by this `async` method.
- **FFI adapter + decode** (`ffi/remotes.dart`, NEW — mirror `bookmarks.dart`, no CString marshalling, no `_mapKind`):
  ```dart
  Uint8List zanshinRemotes(int rawHandle) {
    final ffi.Pointer<ZanshinBuf> token = zanshin_remotes(rawHandle);
    final buf = FfiBuffer.fromToken(token);
    try {
      return Uint8List.fromList(buf.bytes);
    } finally {
      buf.dispose();
    }
  }

  List<Remote> _decodeRemotesEnvelope(Uint8List bytes) {
    final env = fbs.Envelope(bytes);
    if (!env.ok) {
      final fbs.FfiError? e = env.error;
      throw ZanshinFfiException(e?.code ?? 'ffi.unknown', e?.context);
    }
    final Object? payload = env.data;
    if (payload is! fbs.Remotes) {
      throw ZanshinFfiException('ffi.unknown', 'expected Remotes payload, got ${env.dataType}');
    }
    return payload.remotes?.map(_mapRemote).toList() ?? const [];
  }

  Remote _mapRemote(fbs.Remote r) => Remote(name: r.name ?? '', url: r.url ?? '');
  ```
  `ZanshinFfiException` comes from `'../worker/responses.dart'`; `@visibleForTesting` from `package:meta/meta.dart`.
- **`RepoHandle.remotes`** (`worker/handle.dart`, mirror `bookmarks`'s synchronous `_closed` guard):
  ```dart
  Future<List<Remote>> remotes() {
    if (_closed) {
      throw StateError('RepoHandle is already closed');
    }
    return _worker.remotes(_handleId);
  }
  ```
  Add `import '../ffi/remotes.dart' show Remote;`.
- **Model-A handle map** (`isolate.dart`, `final Map<int, int> handles`): remotes does a **lookup** only, never `handles.remove`. No change to the map.

### Why `?? ''` is right for `Remote` (but was wrong for `Bookmark.remoteName`)

The bookmarks slice rejected `?? ''` for `remote_name` because that field is the **identity** of a `Remote`
bookmark (a null there is corruption, not a legitimate empty — `[[feedback-null-for-absence]]`). `Remote`'s
`name`/`url` are plain nullable strings with no such identity invariant — a null collapses to `''` exactly
like every other plain string field (`Diagnostics.appVersion`, `Operation.user`, `Bookmark.name`). So
`_mapRemote` uses `?? ''` and does **not** throw on a null field. (If 2.9/Ralph decide an empty `url` is
itself corruption worth rejecting, that becomes OQ3 — default keeps the plain `?? ''`.)

### Testing standards (project-context Testing Rules) — the F20 oracle-equality rule

**The most important learning to carry forward** (op-log Review-Patch F20 / bookmarks Review-Patch B): the
Dart worker round-trip must assert **EQUALITY** / a **concrete expected shape**, **never**
`isNotNull`/`isNotEmpty` on non-nullable fields (vacuously true). A freshly-`init`-ed jj repo has no remotes,
so the worker test asserts `remotes` **`isEmpty`** (the real expected shape), plus an element-wise equality
across two calls; the decode-contract test value-checks every decoded field (incl. the credential url
surviving verbatim) against the synthetic-builder input. Cross-FFI coverage: `cargo make coverage` unions the
instrumented cdylib path (exercised by the Dart worker round-trip) with cargo tests — the live `remotes.rs`
`#[no_mangle]` entry reached through `flutter test` is what earns the per-file floor for that symbol (the
cargo integration test alone does NOT attribute it — `[[project-coverage-extern-fn-needs-zanshin-core-test]]`).

### Populated-remotes live round-trip — same architectural deferral as bookmarks

The committed fixtures have **zero** remotes, and the FFI test layer cannot import `jj_lib` (`zanshin-jj` is
the only crate allowed to) to construct one via `git::add_remote`. So — exactly as the bookmarks slice
deferred the `Remote`-kind live round-trip (`[[deferred-work]]` 2026-06-25) — the **populated** `zanshin_remotes`
round-trip is not exercised end-to-end through the live cdylib; it is covered **piecewise**: 2.9's zanshin-jj
integration test (real remotes via `git::add_remote`, incl. the credential/SSH edges), this slice's builder
unit test (≥2 distinct entries incl. a credential url), and the Dart synthetic decode-contract test. This is
sufficient for 100 % line coverage of `remotes.rs` (builder by cargo unit test, extern entry + invalid-handle
by the Dart empty round-trip). **A cleaner live populated round-trip is possible for remotes** (unlike
bookmarks) because a remote can be constructed via **gix** (not `jj_lib`) — but that requires a `gix`
dev-dependency in `zanshin-ffi`; default = mirror bookmarks (no new dev-dep, piecewise coverage), raised as
OQ2.

### Hard guardrails (reject-on-sight at review)

- **NO JSON on the FFI wire**, no alternative envelope shape — composite data is the FlatBuffers `Envelope`; remotes is handle-only (no scalar, no string arg).
- **NEVER reorder the `Payload` union** — append `Remotes` only (positional tags; it becomes discriminant 7).
- **NEVER hand-edit generated files**; regenerate via `cargo make codegen` (twice) and commit all five.
- **NO new `extern "C"` outside `zanshin-ffi`**; the repo handle is borrowed, single-threaded (AD-2) — no `Arc<Mutex<T>>`.
- **NO new error code** unless 2.9 ships a non-`Backend` `RemoteError` variant (it should not).
- **NO credential scrubbing on the wire** — `url` crosses verbatim (the scrub/no-scrub policy was settled in 2.9; the wire is a faithful mirror).
- **SPDX line 1** on every new `.rs`/`.dart`; every `unsafe` block a `// SAFETY:`; the `extern "C"` fn a `# Safety` doc.
- **NO coverage-baseline lowering / no `exclude_prefix`** to dodge testing — add the cdylib round-trip test.
- **Dart paths are `packages/zanshin_core/...`**, NOT `app/lib/src/...` (see PATH CORRECTION).

### Project Structure Notes

The remotes FFI wrapper is a per-noun module `crates/zanshin-ffi/src/remotes.rs` (mirroring the live
`bookmarks.rs`/`status.rs`), wired via `pub mod remotes;` in `lib.rs`. The Dart seam lives entirely in
`packages/zanshin_core/` (the pure-Dart bridge under coverage per CLAUDE.md), not `app/`. The schema is the
single combined `schemas/envelope.fbs` (NOT a separate `remotes.fbs`).

### References

- [Source: epics.md#Story 3.4b (lines 2147-2249)] — superseded JSON prose; the FlatBuffers reconciliation banners at lines 2151,2153 are binding; the remotes line is 2209-2211.
- [Source: docs/adr/0001-ffi-data-transport-flatbuffers.md] — FlatBuffers transport; `remotes` listed in the schema-inventory expansion (epics.md:220 / AR-G-4).
- [Source: docs/adr/0002-…-reload-per-operation.md] — re-resolve to head per call (inside `Repo::list_remotes`).
- [Source: docs/rust-error-codes.md:44] — the code registry; `jj.jj_lib_error` is the reused catch-all (NOT modified here — AC-11).
- [Source: schemas/envelope.fbs:31-39,120-145] — roadmap comment, the `Bookmark`/`Bookmarks` precedent, the `Payload` union (currently ends at `Bookmarks`) + `Envelope` to extend.
- [Source: crates/zanshin-ffi/src/bookmarks.rs] — the binding handle-only + list-of-tables wrapper template (drop the kind match).
- [Source: crates/zanshin-ffi/tests/bookmarks_ffi.rs] — the handle-only integration-test harness to mirror (empty + invalid-handle; no null/utf8).
- [Source: packages/zanshin_core/lib/src/{ffi/bookmarks.dart, worker/{commands,isolate,handle,responses}.dart}] — the Dart seam to mirror (drop the sealed-class kind).
- [Source: packages/zanshin_core/test/{worker,ffi}/bookmarks_test.dart] — the two Dart test templates (F20 real-assert pattern).
- [Source: 3-4b-zanshin-bookmarks-ffi-wrapper.md] — the binding `done` slice template (the closest analog; remotes is simpler).
- [Source: 2-9-implement-remotes-rs-list-remotes-read-only.md] — the upstream domain type (`Remote`, `RemoteError`) this wrapper exposes.
- [Source: coverage-baseline.txt] — `new_file_floor_pct = 80.00`; sibling `bookmarks.rs = 100.00`, `op_log.rs = 100.00`, `status.rs = 100.00`, `envelope.rs = 100.00`.
- [Source: memory `[[project-3-4b-template-dart-paths-stale]]`, `[[project-coverage-extern-fn-needs-zanshin-core-test]]`, `[[project-fixtures-no-remote-bookmarks]]`] — Dart path translation, the cross-FFI coverage trap, the no-remotes-in-fixtures reality.

## Dev Agent Record

### Agent Model Used

claude-sonnet-4-6

### Debug Log References

- rustfmt: two multi-line `assert!` macro calls in `crates/zanshin-ffi/tests/remotes_ffi.rs` collapsed to single-line (rustfmt style for short arg lists).

### Completion Notes List

- OQ1 (no new error code): confirmed — `RemoteError` has only `Backend(String)` → reuses `jj.jj_lib_error` unchanged.
- OQ3 (Dart model): `Remote` is a plain `final class` with `name`/`url`; `?? ''` on decode (no identity invariant).
- OQ4 (barrel export): unchanged — `Remote` not exported from `zanshin_core.dart` (matches op_log/bookmarks precedent).
- OQ5 (`push_url`): 2.9 did NOT add push_url; wire has only `name`/`url` — schema matches exactly.
- Coverage: `crates/zanshin-ffi/src/remotes.rs` reached **100.00%**; baseline auto-raised + committed.
- `cargo make test` passed end-to-end (149 s); `extern-coverage` confirmed `zanshin_remotes` covered.

### File List

**New files:**
- `crates/zanshin-jj/src/remotes.rs`
- `crates/zanshin-jj/tests/remotes.rs`
- `crates/zanshin-ffi/src/remotes.rs`
- `crates/zanshin-ffi/tests/remotes_ffi.rs`
- `packages/zanshin_core/lib/src/ffi/remotes.dart`
- `packages/zanshin_core/test/ffi/remotes_test.dart`
- `packages/zanshin_core/test/worker/remotes_test.dart`

**Modified files:**
- `schemas/envelope.fbs` — Remote + Remotes tables; Remotes appended to Payload union
- `crates/zanshin-ffi/src/envelope_generated.rs` — codegen pass 1
- `crates/zanshin-ffi/src/lib.rs` — `pub mod remotes;`
- `crates/zanshin-ffi/include/zanshin_ffi.h` — codegen pass 2
- `crates/zanshin-jj/src/lib.rs` — pub use remotes
- `crates/zanshin-jj/src/repo.rs` — Repo::list_remotes()
- `packages/zanshin_core/lib/src/ffi/envelope_zanshin.ffi_generated.dart` — codegen pass 1
- `packages/zanshin_core/lib/src/ffi/bindings.dart` — codegen pass 2
- `packages/zanshin_core/lib/src/worker/commands.dart` — RemotesCommand
- `packages/zanshin_core/lib/src/worker/isolate.dart` — import + dispatch + remotes()
- `packages/zanshin_core/lib/src/worker/handle.dart` — remotes() + show Remote import
- `coverage-baseline.txt` — auto-raised (remotes.rs: 100.00%)
- `_bmad-output/implementation-artifacts/2-9-implement-remotes-rs-list-remotes-read-only.md` — story 2.9
- `_bmad-output/implementation-artifacts/sprint-status.yaml` — 2.9 → review, 3.4b → review

### Change Log

| Datum | Änderung |
|-------|----------|
| 2026-06-25 | create-story: comprehensive context engineered (mirrors the done bookmarks slice; handle-only marshalling, plain two-string `Remote` table — NO sum-type kind, no sealed class — `Remotes` appended at Payload discriminant 7, no-new-code `jj.jj_lib_error`, the cross-FFI coverage trap, the populated-live-round-trip deferral inherited from bookmarks, and `packages/zanshin_core` paths). Status → ready-for-dev (HARD-GATED on 2.9 `done`). |
| 2026-06-25 | dev: implemented Stories 2.9 + 3.4b (remotes slice). Rust: Remote struct + RemoteError + Repo::list_remotes() + remotes_to_envelope + zanshin_remotes extern + unit + integration tests. Dart: RemotesCommand + worker dispatch + ffi/remotes.dart adapter + decode + handle.dart guard + worker + ffi decode-contract tests. cargo make test green; remotes.rs 100% coverage; baseline raised. Status → review. |

## Code Review Findings (2026-06-26)

Combined 2.9 + 3.4b adversarial multi-layer review + independent `cargo make test` gate run. **Verdict: no blockers; gate green, `crates/zanshin-ffi/src/remotes.rs` 100 % coverage, `zanshin_remotes` extern-coverage OK.** 1 nit patch applied (zanshin-ffi scope):

- [x] [Review][Patch] Fix the self-contradictory comment in the `remotes_to_envelope` unit test — it labelled index 0 as "creds" while the assertion checks "origin", and falsely implied the FFI builder sorts (sorting lives upstream in `zanshin-jj::list_remotes`; the builder preserves insertion order) [crates/zanshin-ffi/src/remotes.rs:122]

No FFI- or Dart-side defects found: credential-verbatim wire, `Payload` union append-only (`Remotes` = discriminant 7), handle borrowed-not-consumed, `# Safety` / `# Errors` docs, and cross-FFI coverage attribution (the `#[no_mangle]` symbol earns its floor via the Dart worker round-trip) all verified correct. 4 false positives dropped during verification (incl. "worker test uses backend: 0 vs AC-mandated 1" and "remotes not added in one transaction" — both zero behavioural/coverage impact).

## Open Questions for Ralph (non-blocking — defaults chosen, override before dev if desired)

1. **OQ1 — No new error code (default = reuse `jj.jj_lib_error`).** Remote listing can't "not find"; its only failure is `RemoteError::Backend` → `jj.jj_lib_error`. Override only if 2.9 ships a distinct `RemoteError` variant warranting a new `jj.*` code (then add the `envelope.rs` const + registry row).
2. **OQ2 — Live populated FFI round-trip (default = defer, mirror bookmarks).** The fixtures have no remotes and the FFI test can't use `jj_lib` to add one; populated coverage is piecewise (2.9 integration test + builder unit test + Dart synthetic decode). Unlike bookmarks, a remote CAN be built via **gix** (not jj_lib), so a `gix` dev-dependency in `zanshin-ffi` would unlock a live populated `remotes_ffi.rs` round-trip. Override to add that dev-dep if you want the end-to-end populated path exercised through the real cdylib (stronger than the bookmarks slice got; costs one dev-dep).
3. **OQ3 — Dart `Remote` model (default = plain `final class Remote { name; url }`, `?? ''` on decode).** No sealed class (no sum type). `name`/`url` collapse a null to `''` like every other plain-string field. Override to reject a null/empty `url` as `ffi.unknown` corruption if an empty url should never occur (not recommended — 2.9 already skips remotes with no fetch URL, so an empty url won't be produced).
4. **OQ4 — Public barrel export (default = unchanged).** The op_log/bookmarks precedent keeps per-noun model classes un-exported from `zanshin_core.dart`; they reach the app only via `RepoHandle` return types. Default mirrors that (no `export` for `Remote`). Override to export it if the app needs to name `Remote` directly.
5. **OQ5 — `push_url` on the wire (default = omit, tracks 2.9 OQ4).** If 2.9 adds `push_url` to `Remote`, add a matching `push_url: string` field to the `Remote` table (the wire mirrors the domain type).
