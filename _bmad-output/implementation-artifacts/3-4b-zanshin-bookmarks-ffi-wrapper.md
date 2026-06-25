# Story 3.4b — `zanshin_bookmarks` FFI wrapper + Dart bookmarks seam (bookmarks slice)

---
baseline_commit: 66a7503
---

Status: done

<!-- Note: Validation is optional. Run validate-create-story for quality check before dev-story. -->

> **This is the `bookmarks` slice of Story 3.4b.** Per the 2026-06-15 WIP re-sequencing
> (sprint-status.yaml:103-114), Story 3.4b lands one thin read-path wrapper **per finished Epic-2
> noun**, each made "aus Flutter testbar" the moment its jj-lib noun is `done`:
>
> | Epic-2 noun (source) | 3.4b slice            | gate |
> |----------------------|-----------------------|------|
> | 2.4 `status` ✅ done   | `zanshin_status` ✅ done | shipped |
> | 2.6 `change` ✅ done   | `zanshin_change` ✅ done | shipped |
> | 2.7 `op_log` ✅ done   | `zanshin_op_log` ✅ done | shipped |
> | **2.8 `bookmarks`**  | **`zanshin_bookmarks` (THIS story)** | ⛔ **gated on 2.8** |
> | 2.9 `remotes`        | `zanshin_remotes`     | 2.9 backlog |
>
> **Stay in this slice** — do **not** build `remotes` or `zanshin_revset_resolve`.

> ## ⛔ HARD GATE — Story 2.8 must be `done` first
>
> This wrapper only **exposes** `zanshin_jj::Repo::list_bookmarks()`; it never adds it. As of this story's
> creation `crates/zanshin-jj/src/bookmarks.rs` does **not** exist (sprint-status.yaml:76 — 2.8 is
> `backlog`/`ready-for-dev`). **Do not start the Rust side until Story 2.8 is `done`.** Before writing
> `map_bookmarks_err` / the `Bookmark`/`Bookmarks` FlatBuffers tables, **read the real
> `crates/zanshin-jj/src/bookmarks.rs`** and confirm the actual public shape — the `Bookmark` field set,
> the `BookmarkKind` variants, the `BookmarkError` variants, and the fallible-`Result`/remote-scope
> decisions are all subject to 2.8's resolved Open Questions (2.8 OQ2/OQ3/OQ4). The shapes below assume
> 2.8's **recommended defaults**; reconcile if Ralph overrode them. [verified: sprint-status.yaml:76-77;
> 2-8-implement-bookmarks-rs-list-bookmarks-read-only.md]

---

## ⚠️ CRITICAL — Read this before writing any code (spec reconciliation)

The Story 3.4b acceptance criteria in `epics.md` (lines 2147-2249) are **stale** and are superseded here.
Treat the ACs in *this* file as the binding contract, not the epic prose:

1. **Transport is FlatBuffers, not JSON (ADR-0001).** The epic says `zanshin_bookmarks(handle)` "returns an
   envelope with `data` as the corresponding array" routed through a JSON envelope (epics.md:2209-2211).
   **Superseded.** Composite FFI data crosses as a FlatBuffers `Envelope` token (`*mut ZanshinBuf`); there is
   no JSON, no `serde::Serialize` on `Bookmark`, no `jsonschema`. This slice **adds one `Payload` member**
   (`Bookmarks`) and consumes the existing 3-0…3-4a / 3.4b-status/change/op_log infrastructure. [Source: docs/adr/0001; project-context.md `overrides:`; epics.md:2151,2209-2211]
2. **`bookmarks` is HANDLE-ONLY — no scalar, no string argument.** Unlike `op_log` (which carries a scalar
   `limit`) or `change` (which carries a lone-string `change_id`), `zanshin_bookmarks` takes **only** the
   handle — the simplest **status** marshalling shape. So there is **no** `cstr_to_string`, **no**
   `ffi.null_pointer` / `ffi.utf8_error` error arm, **no** `std::ffi::c_char` import, and **no** null/utf8
   tests. The function is named **`zanshin_bookmarks`** (AR-P-1: `zanshin_<noun>_<verb>`; noun = `bookmarks`,
   verb elided as the bare list read, exactly like `zanshin_status`). [Source: epics.md:2151,2156; crates/zanshin-ffi/src/status.rs]
3. **The `zanshin_repo_*` ACs in the epic are owned by Story 3.4a (`done`).** Ignore the epic's 3.4b
   `zanshin_repo_open/init/clone/close` signatures entirely. This slice adds **one new function**:
   `zanshin_bookmarks`.
4. **Handle is a `u64` integer, not `*mut c_void`.** Per the committed 3.4a/status/change/op_log ABI, handles
   cross as a `ulong`; `zanshin_bookmarks` takes that `u64` back and **borrows** the `Repo` (it does *not*
   consume/close it). Null handle (`0`) → `ffi.invalid_handle`.

The **done** sibling **Story 3.4b-status** (`3-4b-zanshin-status-ffi-wrapper.md`) is the authoritative pattern
for everything here — handle-only marshalling, the list-of-tables builder, error mapping, codegen discipline,
and the full Dart seam. The **done** `op_log` slice (`3-4b-zanshin-op-log-ffi-wrapper.md`) is the closest
*list-returning* analog. **Mirror them exactly.** `bookmarks` is structurally **simpler** than `op_log`
(handle-only, no scalar) and returns a **list** payload (`[Bookmark]`) — so the builder mirrors
`status_to_envelope` / `op_log_to_envelope`'s vector-of-tables shape, not `change`'s single-table shape. The
one wrinkle vs. `op_log`: each `Bookmark` carries a **sum-type `kind`** (`Local` vs `Remote { remote_name }`),
modeled on the wire as a flatc `enum` + a `remote_name` string (mirrors how `ConflictState` was modeled).

> ### ⚠️ PATH CORRECTION — the Dart bridge lives in `packages/zanshin_core`
> The pure-Dart bridge is the `zanshin_core` package (the older `app/lib/src/...` template paths are STALE —
> verified against the live tree). Use these CURRENT paths throughout:
> | Layer | CURRENT path |
> |---|---|
> | FFI adapter + model + decode | `packages/zanshin_core/lib/src/ffi/bookmarks.dart` |
> | Worker command / dispatch / handle | `packages/zanshin_core/lib/src/worker/{commands,isolate,handle}.dart` |
> | Generated (codegen) | `packages/zanshin_core/lib/src/ffi/{bindings,envelope_zanshin.ffi_generated}.dart` |
> | Dart tests | `packages/zanshin_core/test/{worker,ffi}/bookmarks_test.dart` |
> Tests import via package URIs (`import 'package:zanshin_core/src/ffi/bookmarks.dart';`); inside the package
> use relative imports (`import '../ffi/bookmarks.dart' as repo_ffi_bookmarks;`). The **Rust** paths are
> unchanged (`crates/zanshin-ffi/src/`, `schemas/envelope.fbs`, `crates/zanshin-ffi/include/zanshin_ffi.h`).

---

## Scope (read once, then never widen)

**IN scope — the full Dart↔Rust bridge for `bookmarks`** (the bridge is in scope per
`[[feedback-scope-bridge-is-claudes-ui-is-ralphs]]`; only the Flutter UI is out):

- **Rust:** extend `schemas/envelope.fbs` (`BookmarkKind` enum + `Bookmark` + `Bookmarks` tables; append
  `Bookmarks` to `Payload`); new `extern "C" zanshin_bookmarks(handle: u64) -> *mut ZanshinBuf` in a new
  `crates/zanshin-ffi/src/bookmarks.rs`; map `&[zanshin_jj::Bookmark]` → FlatBuffers `Bookmarks`; map
  `BookmarkError` → `error.code` (**reuses `jj.jj_lib_error` — no new code**); regenerate + commit all five
  codegen artifacts; Rust unit + integration tests.
- **Dart:** `BookmarksCommand` (worker command, carries `handleId`); the worker-isolate dispatch case; the
  `zanshinBookmarks(int)` FFI adapter; main-side decode into a Dart `List<Bookmark>`;
  `ZanshinWorker.bookmarks()` + `RepoHandle.bookmarks()`; a Dart worker round-trip test against the **real
  cdylib** + a decode-contract unit test.

**OUT of scope:**

- Any Flutter widget / screen that *displays* bookmarks (Ralph's separate work).
- The other 3.4b nouns (`remotes`) and `zanshin_revset_resolve`.
- The watcher (Stories 3.5/3.6) — `bookmarks` is a one-shot read; ADR-0002 re-resolves to head per call.
- Any `zanshin-jj` change — `Repo::list_bookmarks()` ships in **Story 2.8**. This slice only *exposes* it.
  (If 2.8 isn't `done`, see the HARD GATE above — do not implement 2.8 here.)
- Bookmark **CRUD / mutation** (create/move/delete/track/untrack/forget) — FR-JJ-11, deferred to 0.2 (epics.md:4060-4082). This is read-only.

---

## Story

As the Dart worker isolate (and, behind it, Ralph's future Flutter UI),
I want an `extern "C" zanshin_bookmarks(handle)` wrapper that calls `zanshin_jj::Repo::list_bookmarks()` and
returns the bookmark list as a FlatBuffers `Envelope`, plus the Dart command/adapter/decode seam that turns
it into a typed `List<Bookmark>`,
so that the bookmarks read-path noun is callable end-to-end from Dart against a real repo — completing the
read wrappers for the open-project flow (status / change / op_log / **bookmarks**).

---

## Acceptance Criteria

Grouped by deliverable. Each item is a checkable contract. The 9-group structure mirrors the `done`
`status`/`op_log` slices; bookmarks-specific divergences are flagged inline.

### AC-1 — wire schema: `BookmarkKind` + `Bookmark` + `Bookmarks` payload (`schemas/envelope.fbs`)

1. `schemas/envelope.fbs` gains, in `snake_case` (flatc emits `lowerCamelCase` getters), modeling the
   sum-type `kind` as a scalar `enum` + an optional `remote_name` string (the same shape used for
   `ChangeKind`/`ConflictState` enums + companion string fields):
   ```fbs
   /// Whether a bookmark is local-only or a tracked remote bookmark.
   /// `remote_name` is populated ONLY when kind == Remote (empty for Local).
   enum BookmarkKind : byte { Local, Remote }

   /// One jj bookmark (FR-JJ-8). A bookmark that is both local and remote-tracked
   /// appears as TWO entries: one Local, one Remote.
   table Bookmark {
     name: string;          // bookmark name (UTF-8)
     target: string;        // target ChangeId, reverse-hex (stable across rebases)
     kind: BookmarkKind;
     remote_name: string;   // populated only when kind == Remote; empty for Local
   }

   /// The bookmark list: local + tracked-remote entries, sorted by name then kind.
   table Bookmarks {
     bookmarks: [Bookmark];
   }
   ```
2. The new `Bookmarks` table is **appended** to the `Payload` union — never reordered (union tags are
   positional; reordering breaks the wire for `RepoHandle`/`Diagnostics`/`Status`/`Change`/`OpLog`):
   ```fbs
   union Payload { RepoHandle, Diagnostics, Status, Change, OpLog, Bookmarks }
   ```
   (`Bookmarks` becomes discriminant 6, after `OpLog = 5`.)
3. The schema roadmap comment (envelope.fbs:32-39) is ticked: `Story 3-4b : status ✓, change ✓, op_log ✓, bookmarks ✓, remotes`.
4. **Reconcile to the shipped 2.8 struct (HARD GATE).** The `Bookmark` table fields match the real
   `zanshin_jj::Bookmark` shape from Story 2.8 (`name`, `target: ChangeId` reverse-hex, `kind: BookmarkKind`
   {Local | Remote{remote_name}}). If 2.8 added an `is_conflicted` field (2.8 OQ4) or changed remote scope
   (2.8 OQ2), update the table to match — the wire mirrors the domain type, not this draft.

### AC-2 — `&[zanshin_jj::Bookmark]` → FlatBuffers mapping

5. A builder `fn bookmarks_to_envelope(bookmarks: &[Bookmark]) -> Vec<u8>` in
   `crates/zanshin-ffi/src/bookmarks.rs` serialises the slice into a finished `Envelope<Bookmarks>` buffer. It
   builds **children before parents** (FlatBuffers requirement): for each `Bookmark`, create its `name` /
   `target` strings and (Remote-only) `remote_name` string, then the `Bookmark` table; collect the offsets;
   then `create_vector` + the `Bookmarks` table; then the `Envelope` with `data_type = Payload::Bookmarks`.
6. Field-by-field mapping with no recomputation: `name → bm.name`; `target → bm.target.0` (the `ChangeId`
   newtype's inner reverse-hex `String`); `kind`/`remote_name` derived from `bm.kind` by matching
   `BookmarkKind::Local => (fbs::BookmarkKind::Local, None)` and `BookmarkKind::Remote { remote_name } =>
   (fbs::BookmarkKind::Remote, Some(create_string(remote_name)))`. `b.finish(envelope, None)` — **plain finish,
   NOT size-prefixed** (length rides in `ZanshinBuf.len`, exactly as `status_to_envelope` / `op_log_to_envelope`).

### AC-3 — `zanshin_bookmarks` extern function

7. `crates/zanshin-ffi/src/bookmarks.rs` defines `#[no_mangle] pub unsafe extern "C" fn zanshin_bookmarks(handle: u64) -> *mut ZanshinBuf`, with a `# Safety` doc block (mirroring `zanshin_status`) and a `# Errors` doc block; `crates/zanshin-ffi/src/lib.rs` adds `pub mod bookmarks;`.
8. The body is wrapped in `envelope::catch(|| { … })` (panic backstop → `internal.panic`); emits a `debug!(fn_name = "zanshin_bookmarks", handle)` span (handle-only, exactly like `zanshin_status` — no extra scalar field).
9. The repo is **borrowed** (not consumed): `handle_from_raw::<Repo>(handle as *mut Repo)`; `None`/`handle == 0` → `FfiErrorObj { code: FFI_INVALID_HANDLE, context: None }` (`ffi.invalid_handle`). The call is `repo.list_bookmarks().map_err(map_bookmarks_err)?`, then `Ok(bookmarks_to_envelope(&bms))`. The returned `*mut ZanshinBuf` is produced by `vec_into_token(buf)` and freed exactly once by Dart.

### AC-4 — `BookmarkError` → `error.code` mapping (NO new code)

10. `fn map_bookmarks_err(e: BookmarkError) -> FfiErrorObj` maps the single variant `BookmarkError::Backend(reason)` → `FfiErrorObj { code: JJ_JJ_LIB_ERROR.to_owned(), context: Some(reason) }` (`jj.jj_lib_error`, the existing catch-all).
11. **No new error code is introduced.** Bookmark listing has no "not found" failure (listing never misses), so — exactly like `op_log` (and unlike `status`'s `jj.no_working_copy` / `change`'s `jj.change_not_found`) — there is **no** new `pub const` in `envelope.rs` and **no** new row in `docs/rust-error-codes.md`. If 2.8 shipped a non-`Backend` `BookmarkError` variant (it should not — 2.8 D4), add the code per the registry's 4-step process; otherwise leave `envelope.rs` and the registry untouched. [Source: docs/rust-error-codes.md; 2.8 AC-7; 3-4b-op-log AC-4]

### AC-5 — codegen committed

12. `cargo make codegen` is run and **all five** generated artifacts are committed; generated files are **never** hand-edited. Run codegen **TWICE**: once after the `schemas/envelope.fbs` edit (regenerates the FlatBuffers accessors), and again after the new `zanshin_bookmarks` extern symbol exists (regenerates the C header + ffigen bindings). The artifacts:
    - `crates/zanshin-ffi/src/envelope_generated.rs` (gains `Bookmark`/`Bookmarks`/`BookmarkKind` + builders + `Bookmarks` in the `Payload` union; `data_as_bookmarks()` accessor),
    - `packages/zanshin_core/lib/src/ffi/envelope_zanshin.ffi_generated.dart` (gains `Bookmark`/`BookmarkObjectBuilder`, `Bookmarks`/`BookmarksObjectBuilder`, `BookmarkKind`, `Bookmarks` in `PayloadTypeId`),
    - `crates/zanshin-ffi/include/zanshin_ffi.h` (gains `ZanshinBuf *zanshin_bookmarks(uint64_t handle);`),
    - `packages/zanshin_core/lib/src/ffi/bindings.dart` (gains the `external` `zanshin_bookmarks` binding — `@ffi.Native<ffi.Pointer<ZanshinBuf> Function(ffi.Uint64)>()`),
    - `schemas/envelope.fbs` (the hand-edited source, AC-1).

### AC-6 — Rust tests

13. **Builder unit test** in `bookmarks.rs` `#[cfg(test)]`: construct a `Vec<zanshin_jj::Bookmark>` exercising **both** `BookmarkKind` arms — a `Local` entry **and** a `Remote { remote_name: "origin" }` entry — with distinct `name`/`target`. Serialise via `bookmarks_to_envelope`, parse with `flatbuffers::root::<fbs::Envelope>` (runs the `Verifier`), assert `ok`, `data_type == Payload::Bookmarks`, `bookmarks().len()`, and that **every field round-trips by equality**: `name`, `target`, `kind` (both `Local` and `Remote` discriminants), and `remote_name` (present + correct on the `Remote` entry, empty/absent on the `Local` entry). Mirror `op_log.rs` / `status.rs` builder tests.
14. **`map_bookmarks_err` unit test**: `map_bookmarks_err(BookmarkError::Backend("boom".into()))` → `code == JJ_JJ_LIB_ERROR`, `context == Some("boom")`. (Single arm — `BookmarkError` has only `Backend`; mirror `op_log.rs:214-217`.)
15. **Integration tests** `crates/zanshin-ffi/tests/bookmarks_ffi.rs` (NEW), mirroring `tests/status_ffi.rs` / `tests/op_log_ffi.rs` harness (`ENV_GUARD`/`pin_env`, `read_and_free(token)`, `parse_envelope(bytes)`, an `open_fixture()` helper returning the handle):
    - **empty round-trip:** open `tiny-3-commits` → `zanshin_bookmarks(handle)` → `ok`, `data_type == Bookmarks`, `bookmarks().map_or(0, |b| b.len()) == 0` → `zanshin_repo_close`.
    - **populated round-trip:** open `medium-1k-commits` → assert `ok`, `data_type == Bookmarks`, `bookmarks().len() == 29` (all `kind == BookmarkKind::Local` on the fixture — it has no remote bookmarks; verify a spot entry's `name` + `target` non-empty + `remote_name` empty), → close.
    - **invalid handle:** `zanshin_bookmarks(0)` → `ok == false`, `error.code == ffi.invalid_handle`.
    - (**No null/utf8 tests** — bookmarks has no CString arg; this asymmetry vs. `change` is deliberate — add a one-line comment noting it.)
16. Buffers are read **only** through the generated typed accessors + `Verifier` — no `jsonschema`, no hand-parsing. Every token is freed; env is pinned; no network. (The `Remote`-arm round trip through the real extern is exercised on the Dart side / by the builder unit test — the committed fixtures have no remote bookmarks; see the coverage note.)

### AC-7 — Dart bridge (paths = `packages/zanshin_core/...`)

17. `packages/zanshin_core/lib/src/worker/commands.dart` gains `final class BookmarksCommand extends WorkerCommand { const BookmarksCommand({required super.commandId, required this.handleId}); final int handleId; }` (handle-only, mirror `StatusCommand`). Adding the sealed subclass forces the worker `switch` to handle it (compile-time exhaustiveness).
18. `packages/zanshin_core/lib/src/worker/isolate.dart`: add the import alias `import '../ffi/bookmarks.dart' as repo_ffi_bookmarks;` in **correct alphabetical position** (`directives_ordering` lint — every prior slice hit this); add the worker dispatch `case BookmarksCommand(:final int handleId):` that **looks up** `handles[handleId]` (never removes), sends an `ffi.invalid_handle` `EnvelopeObjectBuilder` error envelope for an unknown handle, else `responseSP.send((commandId, BufferResult(repo_ffi_bookmarks.zanshinBookmarks(raw))))`; add the main-side `Future<List<Bookmark>> bookmarks(int handleId)` that `send`s `BookmarksCommand` and returns `repo_ffi_bookmarks.decodeBookmarksEnvelopeInternal(bytes)`.
19. `packages/zanshin_core/lib/src/ffi/bookmarks.dart` (NEW): the `Uint8List zanshinBookmarks(int rawHandle)` adapter (mirror `status.dart` — pass the handle straight through, read the token via `FfiBuffer.fromToken`, dispose in `finally`; **no** `toNativeUtf8`/`calloc.free`); a Dart model for the bookmark + its kind (see AC-21); and the decode pair `@visibleForTesting List<Bookmark> decodeBookmarksEnvelope(Uint8List)` + `List<Bookmark> decodeBookmarksEnvelopeInternal(Uint8List)` delegating to a private `_decodeBookmarksEnvelope` (throws `ZanshinFfiException(code, context)` on `!ok`; guards `payload is! fbs.Bookmarks` → `ZanshinFfiException('ffi.unknown', 'expected Bookmarks payload, got ${env.dataType}')`; maps `payload.bookmarks` → `List<Bookmark>`, `?? const []`).
20. `packages/zanshin_core/lib/src/worker/handle.dart`: add `import '../ffi/bookmarks.dart' show Bookmark;` and a `Future<List<Bookmark>> bookmarks()` method with the synchronous `if (_closed) { throw StateError('RepoHandle is already closed'); }` guard, delegating to `_worker.bookmarks(_handleId)`.
21. The Dart `BookmarkKind` is modeled as a **sealed class** so an illegal state (a `Remote` kind with no remote name) is unrepresentable — mapping the wire's `enum BookmarkKind` + `remote_name` string via an exhaustive `switch`:
    ```dart
    sealed class BookmarkKind { const BookmarkKind(); }
    final class LocalBookmark extends BookmarkKind { const LocalBookmark(); }
    final class RemoteBookmark extends BookmarkKind { const RemoteBookmark(this.remoteName); final String remoteName; }
    // _mapKind(fbs.BookmarkKind, String? remoteName) => switch (kind) {
    //   fbs.BookmarkKind.Local  => const LocalBookmark(),
    //   fbs.BookmarkKind.Remote => RemoteBookmark(remoteName ?? ''),
    // };
    ```
    The Dart `final class Bookmark { final String name; final String target; final BookmarkKind kind; }` mirrors the 2.8 domain type (name, target change id, kind) — do NOT add fields the wire doesn't carry. (This sealed-class shape is a deliberate upgrade over the flat `enum` used by `FileChangeKind`/`ConflictState`, because the `Remote` arm carries data; flag as OQ4 if you'd prefer a flat enum + nullable `remoteName`.)
22. No `dart:ffi` type leaks out of `packages/zanshin_core/lib/src/ffi/`; the worker command/response protocol and `CommandCorrelator` are reused unchanged (`bookmarks` replies as the existing `BufferResult` — no new `WorkerResponse` type). `responses.dart` and `zanshin_core.dart` (public export) are **unchanged** (the op-log precedent keeps per-noun models un-exported from the barrel — see OQ3).

### AC-8 — Dart tests (paths = `packages/zanshin_core/test/...`)

23. `packages/zanshin_core/test/worker/bookmarks_test.dart` (NEW), real cdylib (no mocks), mirroring `test/worker/op_log_test.dart`: `ZanshinWorker.start()` + `initRepo(tempDir.path, backend: 0)` → `handle.bookmarks()` round-trip. A freshly-`init`-ed jj repo has **no** bookmarks, so assert the concrete expected shape — `bookmarks` **`isEmpty`** (NOT a vacuous `isNotNull`; F20 rule). Plus: an oracle-equality cross-call (`bookmarks()` twice → element-wise equal by name/kind/target); closed-handle → `ffi.invalid_handle` (close the handle, then call `worker.bookmarks(handle.handleId)` directly, bypassing the guard, expect `ZanshinFfiException` with `code == 'ffi.invalid_handle'`); `RepoHandle.bookmarks` on a closed handle → synchronous `StateError`. **This worker round-trip is the cross-FFI coverage driver for `crates/zanshin-ffi/src/bookmarks.rs`** (see AC-9).
24. `packages/zanshin_core/test/ffi/bookmarks_test.dart` (NEW), decode-contract via synthetic buffers (generated `EnvelopeObjectBuilder` / `BookmarksObjectBuilder` / `BookmarkObjectBuilder`), mirroring `test/ffi/op_log_test.dart`: error envelope → `ZanshinFfiException` (code + context asserted); `ok == true` with a **non-`Bookmarks`** payload (e.g. `RepoHandle`) → `ffi.unknown`; a fully-populated `Bookmarks` (≥2 entries: a `Local` and a `Remote { remoteName: 'origin' }`) → every decoded field equals the builder input (EQUALITY), incl. `kind is RemoteBookmark` with the right `remoteName` and `kind is LocalBookmark` for the local entry; an **empty** `Bookmarks` → `isEmpty`. (This synthetic test is where the **`Remote`-arm decode** is exercised, since the live fixtures have no remotes.)

### AC-9 — quality gate green (incl. coverage ratchet)

25. `cargo make test` passes end-to-end: `cargo clippy --workspace --all-targets -- -D warnings` (pedantic — **refactor, don't `#[allow]`**; any unavoidable suppression carries a `// WHY:`), `cargo fmt --all --check`, all Rust unit + integration tests, `cargo deny check advisories bans`, the cargo-hygiene gate, the Dart suite (`flutter test`, incl. the new worker + decode tests), `dart analyze --fatal-infos --fatal-warnings`, and `dart format` — all clean. **Plus the coverage ratchet** (`cargo make coverage`): the new `crates/zanshin-ffi/src/bookmarks.rs` reaches the per-file floor (≥ 80 %; aim for **100 %** like the `status.rs`/`op_log.rs` wrappers). **Coverage attribution (the known trap):** the `bookmarks_to_envelope` builder + `map_bookmarks_err` are covered by the cargo **unit** tests (regular fns, attributed); the `#[no_mangle] zanshin_bookmarks` entry + the `ffi.invalid_handle` branch are covered by the **Dart worker round-trip** through the real cdylib (a cargo test's call to the `#[no_mangle]` symbol is NOT attributed to the coverage union — this is exactly the gap the op-log slice closed; MEMORY: `[[project-coverage-extern-fn-needs-zanshin-core-test]]`). The auto-raised `coverage-baseline.txt` is committed. `crates/zanshin-ffi/src/envelope.rs` stays 100 % (no new executable line). **Never lower the baseline or add an `exclude_prefix`.** [Source: CLAUDE.md; coverage-baseline.txt; 3-4b-op-log Review §coverage]
26. Every new hand-written `.rs`/`.dart` file starts with `// SPDX-License-Identifier: MIT` (generated files exempt). No `unsafe` outside the documented `extern "C"` seam; the `extern "C"` fn carries a `# Safety` doc section and every `unsafe` block a `// SAFETY:` comment. No new crate, no `Cargo.toml` dependency change.

## Tasks / Subtasks

- [x] **T0 — Confirm the 2.8 gate** (HARD GATE)
  - [x] Verify Story 2.8 is `done` in sprint-status.yaml. Read the shipped `crates/zanshin-jj/src/bookmarks.rs`; confirm `Bookmark` fields, `BookmarkKind` variants, `BookmarkError` variants, the remote scope (tracked-only?) and any `is_conflicted` decision. Reconcile AC-1/AC-4 if Ralph overrode 2.8 defaults (2.8 OQ2/OQ3/OQ4).
- [x] **T1 — Extend the wire schema** (AC: 1, 2, 3, 12)
  - [x] Edit `schemas/envelope.fbs`: add the `BookmarkKind` enum + `Bookmark` + `Bookmarks` tables; **append** `Bookmarks` to `union Payload`; tick the roadmap comment. Run `cargo make codegen` (pass 1).
- [x] **T2 — `bookmarks.rs`: builder + wrapper + error mapping** (AC: 5, 6, 7, 8, 9, 10, 11)
  - [x] Create `crates/zanshin-ffi/src/bookmarks.rs` (SPDX MIT line 1) + add `pub mod bookmarks;` to `lib.rs`. Implement `bookmarks_to_envelope` (list-of-tables w/ the kind match, mirror `op_log_to_envelope`), `map_bookmarks_err` (single arm → `jj.jj_lib_error`), and `zanshin_bookmarks` (catch-wrapped, borrow handle, handle-only). **No `envelope.rs` / `docs/rust-error-codes.md` change** (AC-11).
- [x] **T3 — Regenerate the FFI surface** (AC: 12)
  - [x] Run `cargo make codegen` (pass 2) after the new extern symbol; confirm `zanshin_bookmarks` in `zanshin_ffi.h` + `bindings.dart`; commit all five artifacts. Never hand-edit generated files.
- [x] **T4 — Rust tests** (AC: 13, 14, 15, 16)
  - [x] Builder unit test (both kind arms; every field equality) + `map_bookmarks_err` test in `bookmarks.rs`; `crates/zanshin-ffi/tests/bookmarks_ffi.rs` (empty on tiny, 29 local on medium, invalid handle; no null/utf8 tests).
- [x] **T5 — Dart bridge** (AC: 17, 18, 19, 20, 21, 22)
  - [x] `BookmarksCommand` in `commands.dart`; dispatch `case` + `bookmarks()` main-side method + import alias (alphabetical!) in `isolate.dart`; `ffi/bookmarks.dart` (adapter + sealed `BookmarkKind` + `Bookmark` model + decode pair); `RepoHandle.bookmarks()` + `show Bookmark` import in `handle.dart`. All under `packages/zanshin_core/`.
- [x] **T6 — Dart tests** (AC: 23, 24)
  - [x] `test/worker/bookmarks_test.dart` (real-cdylib round-trip, empty-isEmpty, oracle equality, closed-handle ffi.invalid_handle, StateError) + `test/ffi/bookmarks_test.dart` (decode-contract synthetic incl. the `Remote` arm). Under `packages/zanshin_core/test/`.
- [x] **T7 — Coverage** (AC: 25)
  - [x] Confirm `bookmarks.rs` (ffi) clears the floor (target 100 %): builder+map unit tests (cargo) + the Dart worker round-trip (cdylib) for the extern entry + invalid-handle branch. Commit the auto-raised `coverage-baseline.txt`.
- [x] **T8 — Gate** (AC: 25, 26)
  - [x] `cargo make test` green end-to-end (Rust + Dart + deny + coverage); clippy pedantic; fmt; `dart analyze`/`format` clean; SPDX on new files.

## Review Findings

_Code review 2026-06-25 — bmad-code-review: 6 parallel adversarial finder layers (Opus 4.8) + 6-agent adversarial verification + completeness critic. **Verdict: 24 ACs PASS, 2 PARTIAL, 0 FAIL**; FlatBuffers wire / codegen drift CLEAN (Bookmarks appended at Payload discriminant 6, no reorder, all 5 artifacts consistent, no hand-edit); `cargo make test` independently re-run green (`crates/zanshin-ffi/src/bookmarks.rs` = 100%, coverage-baseline only raised). No correctness / safety / wire / AC-functional defects. Items below are optional hardening + small doc nits — none block `done`._

- [x] [Review][Patch] Empty/missing `remote_name` — drop `?? ''`, throw on corrupt, align docs (DECISION RESOLVED 2026-06-25 by Ralph: keep the flat model; do NOT coerce null→'') [packages/zanshin_core/lib/src/ffi/bookmarks.dart:51-53,107-110; crates/zanshin-jj/src/bookmarks.rs:23-24; schemas/envelope.fbs:130] — Today the Rust/schema docs say `remote_name` CAN be `""` while the Dart doc says "never empty", and `_mapKind` coerces a missing wire value via `remoteName ?? ''`, materializing `RemoteBookmark('')`. RESOLUTION: Dart `_mapKind` drops `remoteName ?? ''` → `RemoteBookmark(remoteName)`; a `Remote` entry whose `remote_name` is null/absent (only reachable via a malformed/foreign buffer — the Rust builder always writes it) throws `ZanshinFfiException('ffi.unknown', 'Remote bookmark missing remote_name')` (corruption ≠ a legitimate null, per [[feedback-null-for-absence]]); align Rust + schema + Dart docs to "`remote_name` is always present for a `Remote` entry".
- [x] [Review][Patch] Vacuous worker "oracle equality" test — loop never runs on an empty fresh repo [packages/zanshin_core/test/worker/bookmarks_test.dart:53-77] — AC-8 #23. A populated round-trip is NOT achievable Dart-side (no bookmark-mutation FFI; read-only story). Fix: delete the test (it duplicates `bookmarks_on_fresh_init_returns_empty_list` with false "oracle" framing — the populated Remote-arm decode is already covered synthetically in test/ffi/bookmarks_test.dart and Rust-side), OR keep it but drop the per-element framing and add a comment that the loop is dormant pending a mutation FFI.
- [x] [Review][Defer] Remote-kind entry never crosses the live FFI boundary [crates/zanshin-ffi/tests/bookmarks_ffi.rs] — DEFERRED 2026-06-25 (architectural): the clean fix requires importing `jj_lib` into `zanshin-ffi` or `test-helpers`, violating the "`zanshin-jj` is the ONLY crate importing `jj_lib`" invariant; the only other route is a new committed remote-bearing fixture (a separate, reviewed change). The `Remote` arm is already covered piecewise — zanshin-jj integration test (`bookmarks_local_and_remote_tracking_yields_two_entries`), the zanshin-ffi builder unit test (`bookmarks_to_envelope_roundtrips_both_kinds`), and the Dart synthetic decode-contract test. Reopen only if accepting the jj_lib-importer cost or adding a new fixture.
- [x] [Review][Patch] Builder unit test uses identical name+target for both kind arms [crates/zanshin-ffi/src/bookmarks.rs (tests::bookmarks_to_envelope_roundtrips_both_kinds)] — AC-6 #13 ("distinct name/target"). Both entries use name "main"/target "zxqpvuts", so a cross-wired-offset builder bug would not be caught. Fix: give the two entries distinct name+target and assert per-index.
- [x] [Review][Patch] Missing AC-mandated "no null/utf8 tests" asymmetry comment [crates/zanshin-ffi/tests/bookmarks_ffi.rs] — AC-6 #15. Add a one-line comment noting null/utf8 tests are omitted because `zanshin_bookmarks` is handle-only (no CString arg) — the deliberate asymmetry vs change_ffi.rs.
- [x] [Review][Patch] Loosen-able Rust roundtrip assertion [crates/zanshin-ffi/src/bookmarks.rs (tests)] — The Local-arm assertion `remote_name().is_none() || == Some("")` has a dead disjunct (the builder always passes None for Local). Tighten to `assert_eq!(fbs_local.remote_name(), None)` to assert the exact invariant.
- [x] [Review][Patch] Test header cites the wrong cargo-make task [packages/zanshin_core/test/worker/bookmarks_test.dart:11-12] — Comment says env is pinned by `[tasks.test-flutter]`; this suite runs under `[tasks.test-core]`. Doc-only fix.

_Dismissed in triage:_
- _Decode message "expected Bookmarks payload, got Bookmarks" when an ok envelope has `dataType==Bookmarks` but a null data slot → cosmetic; only reachable via a malformed/foreign buffer the Rust producer never emits; behavior (throws `ffi.unknown`) is correct._
- _Dual decode entry points (`decodeBookmarksEnvelope` @visibleForTesting vs `decodeBookmarksEnvelopeInternal`) → intentional cross-noun symmetry, matches the op_log/change/status slices._

## Dev Notes

### What you build on — exact, verified signatures (reuse, do not re-add)

From `crates/zanshin-ffi/src/` (all `done`, verified live):
- `envelope::catch<F: FnOnce() -> Result<Vec<u8>, FfiErrorObj>>(f) -> Vec<u8>` (envelope.rs:180) — the panic backstop wrapping every wrapper body (→ `internal.panic` on panic).
- `envelope::FfiErrorObj { pub code: String, pub context: Option<String> }` (envelope.rs:53); consts `FFI_INVALID_HANDLE` (`ffi.invalid_handle`, envelope.rs:18), `JJ_JJ_LIB_ERROR` (`jj.jj_lib_error`, envelope.rs:31) — both re-exported at the crate root via `pub use envelope::*;`.
- `handle::handle_from_raw::<Repo>(ptr: *mut Repo) -> Option<&mut Repo>` (handle.rs) — borrows (does NOT drop) the boxed `Repo`.
- `ffi_strings::{vec_into_token(Vec<u8>) -> *mut ZanshinBuf, ZanshinBuf, zanshin_buffer_free_token}` (ffi_strings.rs:122).
- `crate::fbs` = `pub use envelope_generated::zanshin::ffi as fbs;` (lib.rs:27) — the alias every wrapper uses for generated types.
- The handle-only wrapper template is **`status.rs`** (no scalar, no CString); the list-of-tables builder template is **`op_log.rs:291-330`** (`op_log_to_envelope`) — bookmarks' `[Bookmark]` builder mirrors it, adding the per-entry `kind` match.

### The `zanshin_bookmarks` wrapper (sketch — mirror `zanshin_status` + `op_log_to_envelope`)

```rust
// SPDX-License-Identifier: MIT

//! `zanshin_bookmarks` — bookmark-list read FFI wrapper (Story 3.4b, bookmarks slice).
//!
//! Calls `zanshin_jj::Repo::list_bookmarks()` and serialises the result into a
//! `FlatBuffers` `Envelope` carrying a `Bookmarks` payload. The handle is borrowed
//! (not consumed).

use flatbuffers::FlatBufferBuilder;
use tracing::debug;
use zanshin_jj::{Bookmark, BookmarkError, BookmarkKind, Repo};

use crate::envelope::{catch, FfiErrorObj, FFI_INVALID_HANDLE, JJ_JJ_LIB_ERROR};
use crate::fbs;
use crate::ffi_strings::{vec_into_token, ZanshinBuf};
use crate::handle::handle_from_raw;

fn map_bookmarks_err(e: BookmarkError) -> FfiErrorObj {
    match e {
        BookmarkError::Backend(reason) => FfiErrorObj {
            code: JJ_JJ_LIB_ERROR.to_owned(),
            context: Some(reason),
        },
    }
}

/// Serialise `&[Bookmark]` into a finished `Envelope<Bookmarks>` buffer.
/// Children before parents: each `Bookmark`'s strings are built before its table;
/// the `bookmarks` vector + `Bookmarks` table come after the loop.
fn bookmarks_to_envelope(bookmarks: &[Bookmark]) -> Vec<u8> {
    let mut b = FlatBufferBuilder::with_capacity(1024);
    let mut offsets = Vec::with_capacity(bookmarks.len());
    for bm in bookmarks {
        let name_off = b.create_string(&bm.name);
        let target_off = b.create_string(&bm.target.0); // ChangeId reverse-hex
        let (kind, remote_off) = match &bm.kind {
            BookmarkKind::Local => (fbs::BookmarkKind::Local, None),
            BookmarkKind::Remote { remote_name } => {
                (fbs::BookmarkKind::Remote, Some(b.create_string(remote_name)))
            }
        };
        let bm_off = fbs::Bookmark::create(
            &mut b,
            &fbs::BookmarkArgs {
                name: Some(name_off),
                target: Some(target_off),
                kind,
                remote_name: remote_off,
            },
        );
        offsets.push(bm_off);
    }
    let vec = b.create_vector(&offsets);
    let bms_off = fbs::Bookmarks::create(&mut b, &fbs::BookmarksArgs { bookmarks: Some(vec) });
    let envelope = fbs::Envelope::create(
        &mut b,
        &fbs::EnvelopeArgs {
            ok: true,
            error: None,
            data_type: fbs::Payload::Bookmarks,
            data: Some(bms_off.as_union_value()),
        },
    );
    b.finish(envelope, None);
    b.finished_data().to_vec()
}

/// List local + tracked-remote bookmarks of the repo identified by `handle`.
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
pub unsafe extern "C" fn zanshin_bookmarks(handle: u64) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_bookmarks", handle);
    let buf = catch(|| {
        // SAFETY: non-zero handle originated from handle_into_raw (Box<Repo>);
        // single-isolate model (AD-2) guarantees no concurrent access.
        let repo = unsafe { handle_from_raw::<Repo>(handle as *mut Repo) }.ok_or_else(|| FfiErrorObj {
            code: FFI_INVALID_HANDLE.to_owned(),
            context: None,
        })?;
        let bms = repo.list_bookmarks().map_err(map_bookmarks_err)?;
        Ok(bookmarks_to_envelope(&bms))
    });
    vec_into_token(buf)
}
```

### Where the mapping lives — `bookmarks.rs`, not `envelope.rs`

Keep the domain mapping in the **noun module** (`crates/zanshin-ffi/src/bookmarks.rs`), exactly as the
`status`/`op_log` slices put it in their noun modules. `envelope.rs`'s builders take only primitives /
`FfiErrorObj` and never import a `zanshin-jj` domain type. So this slice adds **no** function to
`envelope.rs`, and (per AC-11) **no** new error const.

### Dart seam — mirror the `op_log` seam (paths = `packages/zanshin_core/...`)

- **Command** (`worker/commands.dart`): mirror `StatusCommand` (handle-only):
  ```dart
  final class BookmarksCommand extends WorkerCommand {
    const BookmarksCommand({required super.commandId, required this.handleId});
    final int handleId; // opaque dense id (NOT a raw pointer)
  }
  ```
- **Worker dispatch** (`worker/isolate.dart`): mirror the `StatusCommand`/`OpLogCommand` case — `final int? raw = handles[handleId];` (**lookup, never remove**); unknown → `fbs.EnvelopeObjectBuilder(ok: false, error: fbs.FfiErrorObjectBuilder(code: 'ffi.invalid_handle', context: 'unknown or closed handleId: $handleId')).toBytes()`; else `responseSP.send((commandId, BufferResult(repo_ffi_bookmarks.zanshinBookmarks(raw))))`. Add `import '../ffi/bookmarks.dart' as repo_ffi_bookmarks;` in **alphabetical** position (before `change`/after the alphabetically-prior import — the prior slices recorded a `directives_ordering` fix here).
- **Main-side `ZanshinWorker.bookmarks`** (`worker/isolate.dart`, mirror `status`):
  ```dart
  Future<List<Bookmark>> bookmarks(int handleId) async {
    final Uint8List bytes = await send(
      BookmarksCommand(commandId: _correlator.allocateId(), handleId: handleId),
    );
    return repo_ffi_bookmarks.decodeBookmarksEnvelopeInternal(bytes);
  }
  ```
  The close-guard `StateError` is delivered **synchronously by `RepoHandle.bookmarks`**, not by this `async` method.
- **FFI adapter + decode** (`ffi/bookmarks.dart`, NEW — mirror `status.dart`, no CString marshalling):
  ```dart
  Uint8List zanshinBookmarks(int rawHandle) {
    final ffi.Pointer<ZanshinBuf> token = zanshin_bookmarks(rawHandle);
    final buf = FfiBuffer.fromToken(token);
    try {
      return Uint8List.fromList(buf.bytes);
    } finally {
      buf.dispose();
    }
  }

  List<Bookmark> _decodeBookmarksEnvelope(Uint8List bytes) {
    final env = fbs.Envelope(bytes);
    if (!env.ok) {
      final fbs.FfiError? e = env.error;
      throw ZanshinFfiException(e?.code ?? 'ffi.unknown', e?.context);
    }
    final Object? payload = env.data;
    if (payload is! fbs.Bookmarks) {
      throw ZanshinFfiException('ffi.unknown', 'expected Bookmarks payload, got ${env.dataType}');
    }
    return payload.bookmarks?.map(_mapBookmark).toList() ?? const [];
  }

  Bookmark _mapBookmark(fbs.Bookmark b) => Bookmark(
        name: b.name ?? '',
        target: b.target ?? '',
        kind: _mapKind(b.kind, b.remoteName),
      );
  ```
  `ZanshinFfiException` comes from `'../worker/responses.dart'`; `@visibleForTesting` from `package:meta/meta.dart`.
- **`RepoHandle.bookmarks`** (`worker/handle.dart`, mirror `status`'s synchronous `_closed` guard):
  ```dart
  Future<List<Bookmark>> bookmarks() {
    if (_closed) {
      throw StateError('RepoHandle is already closed');
    }
    return _worker.bookmarks(_handleId);
  }
  ```
  Add `import '../ffi/bookmarks.dart' show Bookmark;`.
- **Model-A handle map** (`isolate.dart`, `final Map<int, int> handles`): bookmarks does a **lookup** only, never `handles.remove`. No change to the map.

### Testing standards (project-context Testing Rules) — the F20 oracle-equality rule

**The most important learning to carry forward** (op-log Review-Patch F20 / change Review-Patch #1): the Dart
worker round-trip must assert **EQUALITY** / a **concrete expected shape**, **never** `isNotNull`/`isNotEmpty`
on non-nullable fields (vacuously true). A freshly-`init`-ed jj repo has no bookmarks, so the worker test
asserts `bookmarks` **`isEmpty`** (the real expected shape), plus an element-wise equality across two calls;
the decode-contract test value-checks every decoded field (incl. the `Remote` arm: `kind is RemoteBookmark`
with the right `remoteName`) against the synthetic-builder input. Cross-FFI coverage: `cargo make coverage`
unions the instrumented cdylib path (exercised by the Dart worker round-trip) with cargo tests — the live
`bookmarks.rs` `#[no_mangle]` entry reached through `flutter test` is what earns the per-file floor for that
symbol (the cargo integration test alone does NOT attribute it — `[[project-coverage-extern-fn-needs-zanshin-core-test]]`).

### Hard guardrails (reject-on-sight at review)

- **NO JSON on the FFI wire**, no alternative envelope shape — composite data is the FlatBuffers `Envelope`; bookmarks is handle-only (no scalar, no string arg).
- **NEVER reorder the `Payload` union** — append `Bookmarks` only (positional tags).
- **NEVER hand-edit generated files**; regenerate via `cargo make codegen` (twice) and commit all five.
- **NO new `extern "C"` outside `zanshin-ffi`**; the repo handle is borrowed, single-threaded (AD-2) — no `Arc<Mutex<T>>`.
- **NO new error code** unless 2.8 ships a non-`Backend` `BookmarkError` variant (it should not).
- **SPDX line 1** on every new `.rs`/`.dart`; every `unsafe` block a `// SAFETY:`; the `extern "C"` fn a `# Safety` doc.
- **NO coverage-baseline lowering / no `exclude_prefix`** to dodge testing — add the cdylib round-trip test.
- **Dart paths are `packages/zanshin_core/...`**, NOT `app/lib/src/...` (see PATH CORRECTION).

### Project Structure Notes

The bookmarks FFI wrapper is a per-noun module `crates/zanshin-ffi/src/bookmarks.rs` (mirroring the live
`status.rs`/`op_log.rs`), wired via `pub mod bookmarks;` in `lib.rs`. The Dart seam lives entirely in
`packages/zanshin_core/` (the pure-Dart bridge under coverage per CLAUDE.md), not `app/`. The schema is the
single combined `schemas/envelope.fbs` (NOT a separate `bookmarks.fbs`).

### References

- [Source: epics.md#Story 3.4b (lines 2147-2249)] — superseded JSON prose; the two FlatBuffers reconciliation banners at lines 2151,2153 are binding; the bookmarks line is 2209-2211.
- [Source: docs/adr/0001-ffi-data-transport-flatbuffers.md] — FlatBuffers transport; `bookmarks` listed in the schema-inventory expansion (epics.md:220 / AR-G-4).
- [Source: docs/adr/0002-…-reload-per-operation.md] — re-resolve to head per call (inside `Repo::list_bookmarks`).
- [Source: docs/rust-error-codes.md:42-47] — the code registry; `jj.jj_lib_error` is the reused catch-all (NOT modified here — AC-11).
- [Source: schemas/envelope.fbs:32-39,57-70,116-126] — roadmap comment, the `enum`+companion-string convention (ChangeKind/ConflictState), the `Payload` union + `Envelope` to extend.
- [Source: crates/zanshin-ffi/src/status.rs] — the handle-only wrapper template (no scalar, no CString) + `map_*_err` test.
- [Source: crates/zanshin-ffi/src/op_log.rs:18-25,91-105,291-330] — the list-of-tables builder + single-arm `map_*_err` + the extern-fn shape to mirror.
- [Source: crates/zanshin-ffi/tests/{status_ffi.rs, op_log_ffi.rs}] — the handle-only integration-test harness to mirror.
- [Source: packages/zanshin_core/lib/src/{ffi/{op_log,status}.dart, worker/{commands,isolate,handle,responses}.dart}] — the Dart seam to mirror.
- [Source: packages/zanshin_core/test/{worker,ffi}/op_log_test.dart] — the two Dart test templates (corrected F20 real-assert pattern).
- [Source: 3-4b-zanshin-status-ffi-wrapper.md, 3-4b-zanshin-op-log-ffi-wrapper.md] — the binding `done` slice templates.
- [Source: 2-8-implement-bookmarks-rs-list-bookmarks-read-only.md] — the upstream domain type (`Bookmark`, `BookmarkKind`, `BookmarkError`) this wrapper exposes.
- [Source: coverage-baseline.txt] — `new_file_floor_pct = 80.00`; sibling `op_log.rs = 100.00`, `status.rs = 100.00`, `envelope.rs = 100.00`.

## Dev Agent Record

### Agent Model Used

claude-sonnet-4-6

### Debug Log References

- `cargo fmt --all` required after initial write of `bookmarks.rs` + `bookmarks_ffi.rs` (rustfmt max_width=120 reformatted multi-line match arms and assert! calls).
- `dart analyze --fatal-infos` caught `avoid_redundant_argument_values` + `omit_obvious_local_variable_types` in `test/ffi/bookmarks_test.dart`; fixed by removing redundant named args and using `var`-inferred local.
- `dart format` reformatted `lib/src/ffi/bookmarks.dart` (trailing-comma style on `_mapBookmark` and `_mapKind` function literals).

### Completion Notes List

- `crates/zanshin-ffi/src/bookmarks.rs` hit **100 %** line coverage — unit tests cover builder + `map_bookmarks_err`; the Dart worker round-trip through the real cdylib covers `zanshin_bookmarks` extern entry + `ffi.invalid_handle` branch.
- `cargo make codegen` run twice (pass 1 after schema, pass 2 after extern symbol); all 5 generated artefacts committed.
- `BookmarkKind` modeled as sealed class (`LocalBookmark` / `RemoteBookmark(remoteName)`) — illegal state (Remote with no name) is unrepresentable at compile time.
- No new error code added; `BookmarkError::Backend` maps to existing `jj.jj_lib_error`.
- `coverage-baseline.txt` auto-raised: `crates/zanshin-ffi/src/bookmarks.rs = 100.00` added.

### File List

- `schemas/envelope.fbs` (modified — `BookmarkKind` enum + `Bookmark` + `Bookmarks` tables + `Bookmarks` in `Payload` union)
- `crates/zanshin-ffi/src/bookmarks.rs` (new)
- `crates/zanshin-ffi/src/lib.rs` (modified — `pub mod bookmarks;`)
- `crates/zanshin-ffi/tests/bookmarks_ffi.rs` (new)
- `crates/zanshin-ffi/src/envelope_generated.rs` (generated — re-gen)
- `crates/zanshin-ffi/include/zanshin_ffi.h` (generated — re-gen)
- `packages/zanshin_core/lib/src/ffi/envelope_zanshin.ffi_generated.dart` (generated — re-gen)
- `packages/zanshin_core/lib/src/ffi/bindings.dart` (generated — re-gen)
- `packages/zanshin_core/lib/src/ffi/bookmarks.dart` (new)
- `packages/zanshin_core/lib/src/worker/commands.dart` (modified — `BookmarksCommand`)
- `packages/zanshin_core/lib/src/worker/isolate.dart` (modified — import alias + dispatch case + `bookmarks()` method)
- `packages/zanshin_core/lib/src/worker/handle.dart` (modified — `RepoHandle.bookmarks()`)
- `packages/zanshin_core/test/ffi/bookmarks_test.dart` (new)
- `packages/zanshin_core/test/worker/bookmarks_test.dart` (new)
- `coverage-baseline.txt` (modified — new entry + auto-raise)

### Change Log

| Datum | Änderung |
|-------|----------|
| 2026-06-25 | create-story: comprehensive context engineered (mirrors the done status/op_log slices; handle-only marshalling, sum-type `kind` modeled as flatc enum + `remote_name`, no-new-code `jj.jj_lib_error`, the cross-FFI coverage trap, and `packages/zanshin_core` paths). Status → ready-for-dev (HARD-GATED on 2.8 `done`). |
| 2026-06-25 | Implementation complete: all 8 tasks done; `cargo make test` green; `crates/zanshin-ffi/src/bookmarks.rs` = 100 % coverage; `coverage-baseline.txt` auto-raised; status → review. |

## Open Questions for Ralph (non-blocking — defaults chosen, override before dev if desired)

1. **OQ1 — No new error code (default = reuse `jj.jj_lib_error`).** Bookmark listing can't "not find"; its only failure is `BookmarkError::Backend` → `jj.jj_lib_error`. Override only if 2.8 ships a distinct `BookmarkError` variant warranting a new `jj.*` code (then add the `envelope.rs` const + registry row).
2. **OQ2 — `kind` wire shape (default = `enum BookmarkKind {Local, Remote}` + `remote_name: string`).** Mirrors how `ConflictState` was modeled (scalar enum + companion string). Override to a single tagged-union table if you prefer (heavier; not the codebase idiom).
3. **OQ3 — Public barrel export (default = unchanged).** The op-log precedent keeps per-noun model classes (`Operation`/`Change`) un-exported from `zanshin_core.dart`; they reach the app only via `RepoHandle` return types. Default mirrors that (no `export` for `Bookmark`/`BookmarkKind`). Override to export them if the app needs to name them directly.
4. **OQ4 — Dart `BookmarkKind` shape (default = sealed class).** `LocalBookmark` / `RemoteBookmark{remoteName}` makes "Remote with no remote name" unrepresentable. Override to a flat `enum BookmarkKind {local, remote}` + nullable `remoteName` if you prefer consistency with `FileChangeKind`/`ConflictState` (at the cost of an observable illegal state).
5. **OQ5 — `is_conflicted` on the wire (default = omit, tracks 2.8 OQ4).** If 2.8 adds `is_conflicted` to `Bookmark`, add the matching `is_conflicted: bool` field to the `Bookmark` table (the wire mirrors the domain type).
