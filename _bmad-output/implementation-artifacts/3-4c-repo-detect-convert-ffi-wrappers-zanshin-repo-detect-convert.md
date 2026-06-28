# Story 3.4c: Repo detect + convert FFI wrappers — `zanshin_repo_detect` / `zanshin_repo_convert`

---
baseline_commit: f7509d8a619cfe4eab0501abe835cf9eb3ce1a51
---

Status: done

<!-- Note: Validation is optional. Run validate-create-story for quality check before dev-story. -->

## Story

As a **Dart caller (the worker isolate) powering the open-project dialog**,
I want **`extern "C"` wrappers exposing `zanshin-jj`'s `detect_repo` + `find_repo_root` (classification, with a consent-gated enclosing-repo suggestion) and `convert_colocated` (Git → colocated jj) across the FlatBuffers FFI boundary**,
so that **Flutter can classify any user-picked path and, on the user's confirmation, convert a plain Git project to colocated jj — all through the one FlatBuffers `Envelope` carrier (FR-JJ-17, FR-JJ-18a)**.

This is a **thin FFI-wrapper story**. The hard work (detection, ancestor walk-up, colocated conversion, no-data-loss rollback) is **already implemented and tested** in `zanshin-jj` by Stories 2.11 / 2.12 / 2.14. 3.4c only crosses it over the C ABI as two new `extern "C"` symbols on the existing `repo.rs`, adds the wire schema, regenerates bindings, and wires the Dart seam. **No new jj logic.**

**Explicitly OUT of scope:** `convert_import` (external-git import, FR-JJ-18b / Story 2.13) — its FFI wrapper ships in the 0.2 fast-follow, **not here**.

## Context & Dependencies

| Dep | What it gives 3.4c | Status |
|-----|--------------------|--------|
| **2.11** `detect_repo(&Path) -> Result<RepoKind, DetectError>` + `enum RepoKind { Jj, Git, Neither, PathNotFound }` | the classifier 3.4c wraps | **done** |
| **2.12** `convert_colocated(&Path) -> Result<Repo, RepoError>` + `RepoError::{AlreadyJjRepo, NotAGitRepo, ConvertFailed}` | the converter 3.4c wraps | **done** |
| **2.14** `find_repo_root(&Path) -> Result<Option<RepoRoot>, DetectError>` + `struct RepoRoot { root: PathBuf, kind: RepoKind }` | the consent-gated enclosing-repo suggestion | **done** |
| **3.1** `envelope::catch`, `err`, `FfiErrorObj`, error-code consts | the panic backstop + error envelope | **done** |
| **3.4a** `repo.rs` module, `map_repo_err`, `ok_repo_handle`, `vec_into_token`, `tests/repo_ffi.rs` harness | the exact pattern 3.4c extends in place | **done** |
| **3.9** worker isolate + sealed `WorkerCommand` + Model-A handle table | where the Dart-side commands plug in | **done** |

All three wrapped functions are re-exported from `crates/zanshin-jj/src/lib.rs`:
```rust
pub use convert::{convert_colocated, convert_import};
pub use detect::{detect_repo, find_repo_root, DetectError, RepoKind, RepoRoot};
pub use repo::{Backend, Repo, RepoError};
```

## Acceptance Criteria

Reconciled from epics.md Story 3.4c (ACs 1–8) to the **FlatBuffers reality** (ADR-0001) and the **2.14 consent-gated extension** (sprint-status line 70). Epic AC numbers in parentheses.

1. **(AC-1) Two extern fns on the existing `repo.rs`.** `crates/zanshin-ffi/src/repo.rs` gains `zanshin_repo_detect(path: *const c_char) -> *mut ZanshinBuf` and `zanshin_repo_convert(path: *const c_char) -> *mut ZanshinBuf`, both `#[no_mangle] pub unsafe extern "C"`, each wrapped in `envelope::catch(|| { … })` and returning the owned `*mut ZanshinBuf` token via `vec_into_token` (never NULL, never out-of-band errors — everything inside the `Envelope`). Path is parsed with `cstr_to_string(path)?` (yields `ffi.null_pointer` / `ffi.utf8_error`).

2. **(AC-2) Wire schema extended (FlatBuffers, committed codegen).** `schemas/envelope.fbs` gains `enum RepoKind : byte { Jj, Git, Neither, PathNotFound }` (mirrors `zanshin_jj::RepoKind` order) and one new payload table `RepoDetect`, appended to `union Payload`. **Convert reuses the existing `RepoHandle` payload** (its success value *is* a freshly-opened repo handle — see Decision D1). `cargo make codegen` regenerates the Rust + Dart accessors, `zanshin_ffi.h`, and `bindings.dart`; **all regenerated artifacts are committed in the same PR.**

3. **(AC-3) `zanshin_repo_detect` — classification is not failure.** For any path (existing, missing, or garbage) it returns a **success** `Envelope` whose `RepoDetect.kind` carries the `RepoKind`. `Neither` and `PathNotFound` are **normal results, not errors**. Only a genuine I/O failure (`DetectError::Io`, e.g. `EACCES`/`ENOTDIR` while stat-ing) yields an **error** envelope `jj.detect_failed`.

4. **(AC-3 ext / 2.14) Consent-gated enclosing-repo suggestion.** When `detect_repo(path)` is `Ok(Neither)` or `Ok(PathNotFound)`, the wrapper calls `find_repo_root(path)`. On `Ok(Some(RepoRoot { root, kind }))` it populates `RepoDetect.suggested_root` (the root's path string) and `RepoDetect.suggested_kind` (`Jj` or `Git`). On `Ok(None)` it leaves both unset. The backend **never auto-opens** — it only reports the suggestion for the UI to surface ("this folder is inside a {jj|Git} repo at `<root>` — open it?"). `suggested_root` being absent (null string) is the "no suggestion" flag; `suggested_kind` is read **only** when `suggested_root` is present.

5. **(AC-4) `zanshin_repo_convert` happy path.** On a `RepoKind::Git` path it performs the colocated conversion and returns a **success** `Envelope` whose `RepoHandle.handle` is the freshly-opened, now-colocated `Repo` handle (so the UI proceeds straight in — no second `open` call).

6. **(AC-5) `zanshin_repo_convert` error cases.** Precondition/failure surfaces map to dedicated codes: `jj.already_jj_repo` (path already jj), `jj.not_a_git_repo` (neither / missing), `jj.convert_failed` (jj-lib failure or a `detect_repo` I/O error during convert; detail in `context`). Never a crash, never NULL.

7. **(AC-6) Panic backstop.** A forced panic inside either wrapper returns an `internal.panic` error envelope via `envelope::catch` (Story 3.1 backstop).

8. **(new) Error codes registered + emitted.** `crates/zanshin-ffi/src/envelope.rs` defines four `pub const` codes — `JJ_DETECT_FAILED = "jj.detect_failed"` (new), `JJ_ALREADY_JJ_REPO = "jj.already_jj_repo"`, `JJ_NOT_A_GIT_REPO = "jj.not_a_git_repo"`, `JJ_CONVERT_FAILED = "jj.convert_failed"` (the latter three were *Reserved* by 2.12, now first **emitted** here). `map_repo_err` in `repo.rs` is updated to route `AlreadyJjRepo`/`NotAGitRepo`/`ConvertFailed` to their dedicated codes (replacing the temporary `jj.jj_lib_error` stub). `docs/rust-error-codes.md` flips the three Reserved rows to **Emitted — Story 3.4c** and adds a new row for `jj.detect_failed`.

9. **(AC-7) Rust integration tests** in `crates/zanshin-ffi/tests/repo_ffi.rs` (extend the existing 3.4a suite; detect/convert are repo-noun siblings). Every buffer is read through the generated typed accessors + `flatbuffers::root` Verifier (wrong shape = compile error; no hand-parsing). Assert: detect on `tiny-3-commits` → `Jj`; on a `git init` dir → `Git`; on an empty tmpdir → `Neither`; on a nonexistent path → `PathNotFound`; on a path under a regular file (`ENOTDIR`) → error `jj.detect_failed`; convert on a `git init` dir → success handle, **then detect on the same path → `Jj`**; convert on a jj repo → `jj.already_jj_repo`; convert on an empty tmpdir → `jj.not_a_git_repo`. Plus a suggestion test: detect on an empty subdir nested inside a jj repo → `Neither` with `suggested_root` set to the enclosing root and `suggested_kind == Jj`.

10. **(new — coverage-mandated) Dart `zanshin_core` real-cdylib exercise.** Each new `#[no_mangle] extern "C"` fn is exercised by a `packages/zanshin_core` Dart test that calls the **real compiled cdylib** (`@ffi.Native` native assets). This is **non-negotiable**: `cargo-llvm-cov` does not credit a no_mangle extern fn body from cargo tests, so without these tests the two new fn bodies read as uncovered and the coverage ratchet fails (see `[[project-coverage-extern-fn-needs-zanshin-core-test]]`). Includes the Dart FFI adapters (`zanshinRepoDetect`/`zanshinRepoConvert` in `repo.dart`), the `RepoDetect` decode (model + `decodeRepoDetectEnvelope`, guarding the union discriminant), and the worker-command layer (`DetectRepoCommand`/`ConvertRepoCommand` + public `worker.detect`/`worker.convert`) mirroring the 3.4a/3.4b seam.

11. **(AC-8) ABI documented in `docs/ffi-abi.md`.** **Create `docs/ffi-abi.md`** (it does not yet exist; this story starts it — Ralph 2026-06-28) and document `zanshin_repo_detect` / `zanshin_repo_convert`: signature, the `RepoKind` enum mapping, the consent-gated `suggested_root`/`suggested_kind` semantics, the success payloads (`RepoDetect` for detect, reused `RepoHandle` for convert), and every `# Errors` code. Seed the file with a short intro on the `Envelope` + `*mut ZanshinBuf` token / free contract (ADR-0001) so later FFI stories (4-6, 5-8, 6-5, Epic 9) **extend** it rather than recreate it. The extern-fn rustdoc (lifted into `zanshin_ffi.h` by cbindgen) + the error-registry rows remain the per-symbol source of truth; `ffi-abi.md` is the human-facing ABI overview.

12. **(gate) `cargo make test` is green.** Rust tests + clippy (pedantic, `-D warnings`) + rustfmt + `dart analyze`/`format` (app + `packages/zanshin_core`) + `cargo deny` + the **coverage ratchet** all pass. New/changed lines in `repo.rs` reach the per-file floor; the baseline is raised (commit the updated `coverage-baseline.txt`).

## Tasks / Subtasks

- [x] **Task 1 — Extend the wire schema** (AC: 2, 4)
  - [x] In `schemas/envelope.fbs` add `enum RepoKind : byte { Jj, Git, Neither, PathNotFound }` (same order as `zanshin_jj::RepoKind`).
  - [x] Add `table RepoDetect { kind: RepoKind; suggested_root: string; suggested_kind: RepoKind; }` with a doc comment noting `suggested_root` absent ⇒ no suggestion and `suggested_kind` meaningful only when `suggested_root` is present.
  - [x] Append `RepoDetect` to `union Payload` **at the end** (after `Remotes`) so existing discriminants don't shift. **Do not** add a `RepoConvert` table — convert reuses `RepoHandle` (D1).
- [x] **Task 2 — Error-code constants + registry** (AC: 6, 8)
  - [x] In `crates/zanshin-ffi/src/envelope.rs` add four `pub const`: `JJ_DETECT_FAILED`, `JJ_ALREADY_JJ_REPO`, `JJ_NOT_A_GIT_REPO`, `JJ_CONVERT_FAILED` (dotted lowercase values per the registry), each with an AR-P-4 doc comment.
  - [x] In `docs/rust-error-codes.md`: flip the `jj.already_jj_repo` / `jj.not_a_git_repo` / `jj.convert_failed` rows' Status to **Emitted — Story 3.4c** (`envelope.rs`, `repo.rs`), keeping the existing "also produced by `convert_import` (Story 2.13) … 0.2 fast-follow" notes. Add a new row: `jj.detect_failed` | `jj` | "A filesystem I/O error (permission denied, a non-directory path component, …) prevented repo-kind classification." | **Emitted — Story 3.4c** (`envelope.rs::JJ_DETECT_FAILED`, `repo.rs`).
- [x] **Task 3 — Update `map_repo_err` + add the detect-payload builder** (AC: 5, 6, 8)
  - [x] In `repo.rs::map_repo_err`, split the temporary combined `AlreadyJjRepo | NotAGitRepo => JJ_JJ_LIB_ERROR` arm into dedicated arms: `AlreadyJjRepo { path }` → `JJ_ALREADY_JJ_REPO` (context = path), `NotAGitRepo { path }` → `JJ_NOT_A_GIT_REPO` (context = path), and move `ConvertFailed { reason }` out of the `jj.jj_lib_error` group to `JJ_CONVERT_FAILED` (context = reason). Delete the "// AlreadyJjRepo + NotAGitRepo get dedicated codes in Story 3.4c …" comment. `InitFailed`/`CloneFailed`/`Backend` stay on `JJ_JJ_LIB_ERROR`.
  - [x] Add `fn repo_kind_to_fbs(k: RepoKind) -> fbs::RepoKind` (private; maps `Jj→Jj, Git→Git, Neither→Neither, PathNotFound→PathNotFound`).
  - [x] Add `fn ok_repo_detect(kind: RepoKind, suggestion: Option<RepoRoot>) -> Vec<u8>` (private builder in `repo.rs`, mirroring `status.rs`'s noun-module builder convention — keeps the `zanshin_jj`→`fbs` mapping local, off `envelope.rs`). Builds a `RepoDetect` table: always sets `kind`; sets `suggested_root` (string) + `suggested_kind` (mapped) **only** when `suggestion` is `Some`. Uses `FlatBufferBuilder` + `b.finish(env, None)`.
- [x] **Task 4 — `zanshin_repo_detect`** (AC: 1, 3, 4)
  - [x] `#[no_mangle] pub unsafe extern "C" fn zanshin_repo_detect(path: *const c_char) -> *mut ZanshinBuf`, `debug!(fn_name = "zanshin_repo_detect")`, body wrapped in `catch`.
  - [x] `let p = unsafe { cstr_to_string(path) }?;` then `let kind = detect_repo(Path::new(&p)).map_err(map_detect_err)?;`
  - [x] Suggestion: `let suggestion = match kind { RepoKind::Neither | RepoKind::PathNotFound => find_repo_root(Path::new(&p)).map_err(map_detect_err)?, _ => None };` (D2: a `find_repo_root` I/O error maps to `jj.detect_failed` too — consistent + essentially unreachable after detect on the same path already succeeded).
  - [x] `Ok(ok_repo_detect(kind, suggestion))`. Add `fn map_detect_err(e: &DetectError) -> FfiErrorObj` → `{ code: JJ_DETECT_FAILED, context: Some(e.to_string()) }`.
  - [x] `# Safety` + `# Errors` rustdoc (codes: `jj.detect_failed`, `ffi.null_pointer`, `ffi.utf8_error`).
- [x] **Task 5 — `zanshin_repo_convert`** (AC: 1, 5, 6)
  - [x] `#[no_mangle] pub unsafe extern "C" fn zanshin_repo_convert(path: *const c_char) -> *mut ZanshinBuf`, `debug!(fn_name = "zanshin_repo_convert")`, body wrapped in `catch`.
  - [x] `let p = unsafe { cstr_to_string(path) }?;` then `let repo = convert_colocated(Path::new(&p)).map_err(map_repo_err)?;` then `Ok(ok_repo_handle(handle_into_raw(repo) as u64))` (reuse the existing `ok_repo_handle` + `handle_into_raw` — identical to `zanshin_repo_open`).
  - [x] `# Safety` + `# Errors` rustdoc (codes: `jj.already_jj_repo`, `jj.not_a_git_repo`, `jj.convert_failed`, `ffi.null_pointer`, `ffi.utf8_error`). Note: the close pairing — the returned handle is closed via `zanshin_repo_close` (no `_convert`-specific destructor).
  - [x] Update imports at the top of `repo.rs`: add `detect_repo, find_repo_root, convert_colocated, DetectError, RepoKind, RepoRoot` to the `zanshin_jj` use; add `JJ_DETECT_FAILED, JJ_ALREADY_JJ_REPO, JJ_NOT_A_GIT_REPO, JJ_CONVERT_FAILED` to the `crate::envelope` use; add `crate::fbs` (or `crate::envelope_generated::zanshin::ffi as fbs`) for the builder.
- [x] **Task 6 — Codegen** (AC: 2)
  - [x] Run `cargo make codegen` after Tasks 1 + 4 + 5 (schema **and** the new extern symbols both feed codegen). Commit the regenerated `crates/zanshin-ffi/src/envelope_generated.rs`, `packages/zanshin_core/lib/src/ffi/envelope_zanshin.ffi_generated.dart`, `crates/zanshin-ffi/include/zanshin_ffi.h`, and `packages/zanshin_core/lib/src/ffi/bindings.dart` (+ `app/` bindings if codegen emits there) — **never hand-edit generated files** (`[[project-coverage-ratchet]]` discipline; CLAUDE.md anti-pattern).
- [x] **Task 7 — Rust integration tests** (AC: 3, 4, 5, 7, 9)
  - [x] Extend `crates/zanshin-ffi/tests/repo_ffi.rs` (reuse `pin_env`, `read_and_free`, `parse_envelope`, `cstr`, `git`, `extract_fixture`). Import the two new symbols + the four new codes from `zanshin_ffi`.
  - [x] Detect: `tiny-3-commits` → `RepoDetect.kind == Jj`; `git init` tmpdir → `Git`; empty tmpdir → `Neither`; nonexistent path → `PathNotFound`; path = `<file>/sub` under a regular file → error `jj.detect_failed`.
  - [x] Suggestion: empty subdir created inside a jj-init'd tmpdir → `Neither` with `suggested_root` == enclosing root and `suggested_kind == Jj`. (macOS `TempDir` resolves under `$TMPDIR` = `/var/folders/…`, which is **outside** `$HOME`, so the `$HOME` ceiling does not interfere — the enclosing jj root is found normally. The ceiling would only bite a test that deliberately sets `$HOME` to an ancestor of `start`.)
  - [x] Convert happy: `git init` tmpdir (with one commit) → success `RepoHandle`, non-zero handle; **re-detect same path → `Jj`**; close the handle.
  - [x] Convert errors: convert a jj repo (`tiny` fixture or a `zanshin_repo_init`'d dir) → `jj.already_jj_repo`; convert an empty tmpdir → `jj.not_a_git_repo`.
- [x] **Task 8 — Dart FFI adapter + decode + worker layer** (AC: 10)
  - [x] `packages/zanshin_core/lib/src/ffi/repo.dart`: add `Uint8List zanshinRepoDetect(String path)` and `Uint8List zanshinRepoConvert(String path)` mirroring `zanshinRepoOpen` exactly (`toNativeUtf8` → call → `FfiBuffer.fromToken` → `Uint8List.fromList(buf.bytes)` → `buf.dispose()` → `calloc.free(p)` in `finally`).
  - [x] Add a `RepoKind` Dart enum + `RepoDetectResult { RepoKind kind; String? suggestedRoot; RepoKind? suggestedKind }` model + `decodeRepoDetectEnvelope(Uint8List)` in `ffi/repo_detect.dart` — throw `ZanshinFfiException(code, context)` on `!ok`; guard `payload is! fbs.RepoDetect` → `ffi.unknown`; read `suggestedRoot` as the suggestion-present flag. **Convert reuses the existing RepoHandle decode** (same as open — returns the raw handle int to the worker's Model-A table).
  - [x] Worker: add `final class DetectRepoCommand(path)` + `final class ConvertRepoCommand(path)` to `worker/commands.dart`; handle them in the worker loop (path-in, handle-free — same shape as `OpenRepoCommand`; convert stores the new handle in the Model-A table just like open); add public `Future<RepoDetectResult> detect(String path)` and `Future<RepoHandle> convert(String path)` on the worker/`ZanshinWorker`.
- [x] **Task 9 — Dart tests** (AC: 10, 12)
  - [x] `packages/zanshin_core/test/ffi/repo_detect_test.dart`: decode-contract tests with synthetic buffers (`EnvelopeObjectBuilder` + `RepoDetectObjectBuilder`): error envelope → throws; non-`RepoDetect` payload → `ffi.unknown`; each `RepoKind` round-trips; suggestion present vs. absent (D4).
  - [x] `packages/zanshin_core/test/worker/detect_test.dart`: round-trip tests booting the real `Isolate.spawn` + cdylib — `worker.detect(path)` over four kinds (jj, neither, path-not-found, suggestion); `worker.convert(gitDir)` → handle, then `worker.detect(sameDir)` → `Jj`; `worker.convert(jjDir)` → `ZanshinFfiException('jj.already_jj_repo')`; `worker.convert(emptyDir)` → `ZanshinFfiException('jj.not_a_git_repo')`.
- [x] **Task 10 — Gate** (AC: 11, 12)
  - [x] Created `docs/ffi-abi.md` documenting detect/convert + `RepoKind` enum + suggestion semantics + payloads + error codes, with `Envelope`/token-contract intro (Ralph 2026-06-28). Clippy fix: `map_detect_err` takes `&DetectError` (needless_pass_by_value). `cargo fmt` reformatted `repo.rs` + `repo_ffi.rs`.
  - [x] `cargo make test` green: all Rust + Dart tests pass, coverage 98.33% (2175/2212 lines), extern-coverage OK (both new fn bodies covered).

## Dev Notes

### What is already done (do NOT reimplement)

`zanshin-jj` ships the full behavior. 3.4c is a **translation layer only**.

- **`detect_repo`** (`crates/zanshin-jj/src/detect.rs:65`): stat-only, `jj_lib`-free, never panics. `.jj` must be a **directory** (`is_dir()` — a regular `.jj` file is corruption → `Neither`); `.git` may be a dir or file (`exists()` — covers worktree `gitdir:` pointers). Symlinks followed (`stat`, not `lstat`). `Ok(false)` from `try_exists` → `PathNotFound`; `Err` (EACCES/ENOTDIR) → `DetectError::Io`.
- **`find_repo_root`** (`detect.rs:112`): walks `start` then ancestors via `detect_repo`, returns the first `Jj`/`Git` as `RepoRoot`. Bounded by the **`$HOME` ceiling** (never climbs to `$HOME` or above) — except `start` itself is always classified. Propagates `DetectError::Io` **fail-fast** (per its contract, an Io error can only occur on `start`, which 3.4c already stat'd successfully via `detect_repo`, so it's effectively unreachable here).
- **`convert_colocated`** (`crates/zanshin-jj/src/convert.rs:60`): gates on `detect_repo` internally (`Jj`→`AlreadyJjRepo`, `Git`→proceed, `Neither`/`PathNotFound`→`NotAGitRepo`, `Io`→`ConvertFailed`), then `Workspace::init_external_git(settings, path, path/.git)` + `import_refs` + `import_head` + `tx.commit`, and **`Repo::open(path)`** on success. **No working-copy I/O** (no `check_out`/snapshot/`@`-reparent) — that is the no-data-loss invariant (D3). On failure it rolls back **only `.jj/`**, never `.git/` (D4). So 3.4c's convert wrapper is literally: parse path → `convert_colocated` → `ok_repo_handle(handle_into_raw(repo))`.

### The central FFI pattern (copy 3.4a verbatim)

`zanshin_repo_detect`/`convert` are structural twins of `zanshin_repo_open` (`crates/zanshin-ffi/src/repo.rs:71`). The skeleton:

```rust
#[no_mangle]
pub unsafe extern "C" fn zanshin_repo_detect(path: *const c_char) -> *mut ZanshinBuf {
    debug!(fn_name = "zanshin_repo_detect");
    // SAFETY: caller guarantees path is null or a valid NUL-terminated C string.
    let buf = catch(|| {
        let p = unsafe { cstr_to_string(path) }?;
        let kind = detect_repo(Path::new(&p)).map_err(map_detect_err)?;
        let suggestion = match kind {
            RepoKind::Neither | RepoKind::PathNotFound => {
                find_repo_root(Path::new(&p)).map_err(map_detect_err)?
            }
            RepoKind::Jj | RepoKind::Git => None,
        };
        Ok(ok_repo_detect(kind, suggestion))
    });
    vec_into_token(buf)
}
```

- `catch` returns the finished `Vec<u8>` (success buffer from the closure, or an error/panic envelope). `vec_into_token` wraps it as the `*mut ZanshinBuf` token Dart's `NativeFinalizer` needs. **Never return NULL.** (`crates/zanshin-ffi/src/envelope.rs:180`, `ffi_strings.rs:122`).
- `ok_repo_handle` (`envelope.rs:84`) and `handle_into_raw` are already used by open/init/clone — **reuse, don't clone**.
- The `RepoDetect` builder follows `ok_diagnostics` (`envelope.rs:106`): create strings first, then the table, then the `Envelope`, then `b.finish(env, None)`. Place it in `repo.rs` (not `envelope.rs`) because it needs the `zanshin_jj::RepoKind → fbs::RepoKind` map, and the noun-module owns its domain mapping (the 3.4b convention).

### Decisions baked into this story (with rationale)

- **D1 — Convert reuses `RepoHandle`; no `RepoConvert` table.** Epic AC-2 said "detect/convert payload **tables**", but convert's success value is *literally a freshly-opened repo handle*, identical to `open`/`init`/`clone`. Adding a one-field `RepoConvert { handle }` clone of `RepoHandle` is speculative duplication (CLAUDE.md "Simplicity First / no abstractions for single-use"). Reuse `RepoHandle`. This is a deliberate reconciliation of an epic AC written before the FlatBuffers payload set existed (`[[project-epics-ffi-acs-predate-flatbuffers]]`).
- **D2 — A `find_repo_root` I/O error during detect → `jj.detect_failed`** (same as a `detect_repo` Io error), mapped via `?`. It's consistent ("any I/O failure during the detect operation surfaces as `jj.detect_failed`"), fail-fast (matches 2.14's contract and the project's no-silent-swallow posture), and unreachable in practice (detect on the same `start` already succeeded). The alternative — best-effort swallow to `None` — is rejected as it hides an I/O fault behind a "no suggestion" that looks identical to a clean walk. (See **OQ-1** to confirm.)
- **D3 — Detect classification is never an FFI error** except `DetectError::Io`. `Neither`/`PathNotFound` ride in the **success** payload (`RepoKind`). This is the whole point of FR-JJ-17 + `[[feedback-null-for-absence]]`: absence is a normal classification the UI decides on, not an exception.
- **D4 — `suggested_root` string-presence is the suggestion flag.** FlatBuffers byte enums have no "absent" state (`suggested_kind` defaults to `Jj=0` when unset), so Dart must gate on `suggestedRoot != null` before reading `suggestedKind`. This mirrors the `Bookmark.remote_name`/`FileChange.from_path` convention already in the schema (`schemas/envelope.fbs:61,126`).
- **D5 — Convert handle is closed via `zanshin_repo_close`.** No `_convert`-specific destructor; the noun-pairing rule (`_open`↔`_close`) covers it because convert returns the same `RepoHandle`.

### `map_repo_err` — exact change

Current `repo.rs:36-48` lumps `ConvertFailed` with the `jj_lib_error` group and stubs `AlreadyJjRepo | NotAGitRepo` onto `JJ_JJ_LIB_ERROR` with a "until 3.4c" comment. After 3.4c:

```rust
RepoError::InitFailed { reason } | RepoError::CloneFailed { reason } | RepoError::Backend(reason) => {
    FfiErrorObj { code: JJ_JJ_LIB_ERROR.to_owned(), context: Some(reason) }
}
RepoError::ConvertFailed { reason } => {
    FfiErrorObj { code: JJ_CONVERT_FAILED.to_owned(), context: Some(reason) }
}
RepoError::AlreadyJjRepo { path } => {
    FfiErrorObj { code: JJ_ALREADY_JJ_REPO.to_owned(), context: Some(path.display().to_string()) }
}
RepoError::NotAGitRepo { path } => {
    FfiErrorObj { code: JJ_NOT_A_GIT_REPO.to_owned(), context: Some(path.display().to_string()) }
}
```

There are existing unit tests in `repo.rs` (`map_repo_err_convert_failed_maps_to_jj_lib_error`, `map_repo_err_already_jj_repo_maps_to_jj_lib_error`, `map_repo_err_not_a_git_repo_maps_to_jj_lib_error`) that assert the **old** `JJ_JJ_LIB_ERROR` mapping — **update those three assertions** to the new dedicated codes (they are your regression guard, not obstacles).

### Coverage ratchet — the trap to avoid

`cargo make test` ends with the per-file Rust coverage gate (`[[project-coverage-ratchet]]`). Two facts to internalize:

1. **`repo.rs` is already near-100%** (3.4a). New lines (the two extern fns, `ok_repo_detect`, `repo_kind_to_fbs`, `map_detect_err`, the new `map_repo_err` arms) must be covered or the file regresses → gate fails. The Rust integration tests (Task 7) cover most; the new `map_repo_err` arms are covered by the updated unit tests.
2. **The two new `#[no_mangle] extern "C"` fn bodies need a `packages/zanshin_core` real-cdylib test** (`[[project-coverage-extern-fn-needs-zanshin-core-test]]`). `cargo-llvm-cov` does **not** credit a no_mangle extern fn called from a cargo integration test toward the cdylib union (release-cdylib vs debug-cargo hash split). The Task 9 Dart tests (calling through `@ffi.Native` native assets) are the **only** coverage source for those two fn bodies. Skipping them = latent ratchet failure. If you suspect a baseline is already stale, `git stash` to prove a regression is pre-existing before touching the baseline — and **never lower the baseline** to pass.

The cdylib must be built (`cargo make build`) before the Dart suite runs; `cargo make test` orchestrates this.

### Dart seam — match 3.4a/3.4b exactly

- Adapter (`repo.dart`): `String path → toNativeUtf8() → zanshin_repo_detect(p.cast()) → FfiBuffer.fromToken(token) → Uint8List.fromList(buf.bytes)` in a `try`, `buf.dispose()` + `calloc.free(p)` in `finally`. **Dart owns the inbound CString** (AR-P-5 inbound rule — reverse of the outbound rule).
- Decode guards the union discriminant (`payload is! fbs.RepoDetect → ffi.unknown`), exactly like `decodeStatusEnvelope`. Throw `ZanshinFfiException(code, context)` on `!ok`.
- Worker: `DetectRepoCommand`/`ConvertRepoCommand` are path-in, handle-free — same shape as `OpenRepoCommand`. Convert stores the returned handle in the worker's Model-A `Map<int,int>` (id→rawHandle) just like open; raw handles never leave the worker. Public `worker.detect(path)`/`worker.convert(path)`.
- **No Flutter UI / call sites** — those are Ralph's separate scope (`[[feedback-scope-bridge-is-claudes-ui-is-ralphs]]`). The seam (adapter + decode + worker command + DI) is in scope; the dialog that *calls* it is not.

### Anti-patterns to avoid (CLAUDE.md / project-context.md)

- **No new jj logic, no shelling to `jj`, no `jj_lib` import in `zanshin-ffi`.** All jj behavior already lives in `zanshin-jj`; 3.4c only calls its typed API.
- **No JSON on the FFI wire.** FlatBuffers `Envelope` only (ADR-0001).
- **No hand-editing generated files.** Only `cargo make codegen` produces them; commit the diff.
- **No `RepoConvert` table** (D1). **No `convert_import` FFI** (0.2 fast-follow).
- **No `unwrap`/`expect`/`panic!`** on the FFI-reachable path; the `catch` backstop exists but the goal is to never reach it.
- Every `unsafe` block carries `// SAFETY:`; every `unsafe fn` carries a `# Safety` rustdoc section. SPDX is already on `repo.rs` (extending, not creating).

### Resolved Decisions (Ralph, 2026-06-28)

- **OQ-1 (D2) → RESOLVED: `jj.detect_failed`.** A `find_repo_root` I/O error during a detect call maps to `jj.detect_failed` (fail-fast, consistent with a `detect_repo` Io error; unreachable in practice). Already reflected in Task 4.
- **OQ-2 (Dart worker scope) → RESOLVED: full worker layer in scope.** `DetectRepoCommand`/`ConvertRepoCommand` + public `worker.detect`/`worker.convert` + worker round-trip tests are part of 3.4c (Tasks 8–9), matching the 3.4a/3.4b seam.
- **OQ-3 (AC-8 / `docs/ffi-abi.md`) → RESOLVED: create the doc now.** 3.4c creates `docs/ffi-abi.md` (Tasks 10 / AC-11). Future FFI stories extend it rather than recreate it.

### Project Structure Notes

- New code lands in **existing** files — no new modules: `crates/zanshin-ffi/src/repo.rs` (two extern fns + 3 helpers), `crates/zanshin-ffi/src/envelope.rs` (4 consts), `schemas/envelope.fbs` (1 enum + 1 table + union entry), `crates/zanshin-ffi/tests/repo_ffi.rs` (tests). `pub mod repo;` is already declared in `lib.rs` — the new symbols are re-exported automatically. Error codes obey the single-emission-point rule (consts only in `envelope.rs`; `repo.rs` references them).
- Dart additions: `packages/zanshin_core/lib/src/ffi/repo.dart` (+ a `RepoDetectResult`/`RepoKind` model, inline or a small `repo_detect.dart`), `worker/commands.dart`, the worker loop, and tests under `test/ffi/` + `test/worker/`. Generated `bindings.dart` + `envelope_zanshin.ffi_generated.dart` are regenerated, not hand-written.

### References

- [Source: _bmad-output/planning-artifacts/epics.md#Story-3.4c] — ACs 1–8 (reconciled above to FlatBuffers + the 2.14 extension).
- [Source: _bmad-output/implementation-artifacts/sprint-status.yaml:70] — the 2026-06-26 extension binding 3.4c to `find_repo_root` (consent-gated suggestion; "backend never auto-opens"); 2.13 import explicitly NOT here.
- [Source: crates/zanshin-jj/src/detect.rs:65,112] — `detect_repo`, `find_repo_root`, `RepoKind`, `DetectError`, `RepoRoot`.
- [Source: crates/zanshin-jj/src/convert.rs:60] — `convert_colocated` (signature, gating, rollback, no-working-copy-I/O invariant). `convert_import` (line 104) is OUT of scope.
- [Source: crates/zanshin-ffi/src/repo.rs:26,71] — `map_repo_err` (with the "until 3.4c" stub) + the `zanshin_repo_open` pattern to copy.
- [Source: crates/zanshin-ffi/src/envelope.rs:15-35,84,106,180] — error-code consts, `ok_repo_handle`, `ok_diagnostics` (builder pattern), `catch`.
- [Source: crates/zanshin-ffi/src/ffi_strings.rs:45,122] — `cstr_to_string`, `vec_into_token`, `ZanshinBuf`.
- [Source: schemas/envelope.fbs:57,84,122,150] — enum/table/union conventions; the absent-string-as-presence-flag pattern (`from_path`, `remote_name`).
- [Source: crates/zanshin-ffi/tests/repo_ffi.rs:25-66] — `pin_env`/`read_and_free`/`parse_envelope`/`cstr`/`git` harness to reuse.
- [Source: docs/rust-error-codes.md:48-50] — the three Reserved convert codes (flip to Emitted; add `jj.detect_failed`).
- [Source: _bmad-output/project-context.md § Framework-Specific Rules / Critical Don't-Miss] — FFI boundary rules, FlatBuffers transport, coverage ratchet, no-shell-to-jj.
- [Source: docs/adr/0001-ffi-data-transport-flatbuffers.md] — the FlatBuffers `Envelope` transport this story extends.
- [Source: ../jj @ v0.42.0 — cli/src/commands/git/init.rs] — colocated-init prior art (already mirrored by `convert_colocated`; read-only reference, not re-implemented here).

## Dev Agent Record

### Agent Model Used

claude-sonnet-4-6

### Debug Log References

- Clippy `needless_pass_by_value` on `map_detect_err`: changed `e: DetectError` → `e: &DetectError`; call sites updated to `.map_err(|e| map_detect_err(&e))`.
- Clippy `doc_markdown` in `repo_ffi.rs`: added backticks around `convert_colocated` in `git_with_commit` doc comment.
- `cargo fmt` reformatted `crates/zanshin-ffi/src/repo.rs` (import line wrapping) and `crates/zanshin-ffi/tests/repo_ffi.rs` (assert! macros, import alignment).
- Dart `directives_ordering` in `repo_detect.dart`: reordered imports alphabetically (`responses.dart` before `envelope_zanshin.ffi_generated.dart`).
- Dart `comment_references` in `commands.dart` + `isolate.dart`: changed `[HandleResult]`/`[kind]` to backtick form.
- Dart formatting failures in `repo_detect_test.dart` and `detect_test.dart`: fixed via `dart format`.
- Dart lint in `detect_test.dart`: `specify_nonobvious_local_variable_types` → `final ProcessResult result`; `omit_obvious_local_variable_types` → `final missing` / `final subdir`.

### Completion Notes List

- Story 3.4c is a pure translation layer — no new jj logic. All behavioral correctness lives in zanshin-jj (Stories 2.11/2.12/2.14).
- D1 confirmed: convert reuses `RepoHandle` payload (no `RepoConvert` table); convert's success value is literally a freshly-opened repo handle.
- D4 confirmed: `suggested_root` string-presence is the suggestion flag; `suggested_kind` is only read when `suggested_root` is non-null (FlatBuffers byte enums default to 0=Jj when absent).
- Coverage attribution: the two new `#[no_mangle] extern "C"` fn bodies are covered exclusively by the Dart cdylib tests in `test/worker/detect_test.dart` (cargo integration tests do not credit no_mangle bodies per the release-cdylib vs debug-cargo hash split). Gate confirmed via `extern-coverage: OK` in `cargo make test` output.
- Final gate output: `overall: 98.33% (2175/2212 lines over 23 files)`, `coverage-check: OK`, `extern-coverage: OK`. Build time: ~133s.

### File List

**Modified:**
- `schemas/envelope.fbs` — added `enum RepoKind`, `table RepoDetect`, union entry
- `crates/zanshin-ffi/src/envelope.rs` — 4 new error-code consts
- `crates/zanshin-ffi/src/repo.rs` — `map_detect_err`, `repo_kind_to_fbs`, `ok_repo_detect`, `zanshin_repo_detect`, `zanshin_repo_convert`; `map_repo_err` split for dedicated codes; unit tests updated
- `crates/zanshin-ffi/tests/repo_ffi.rs` — 11 integration tests (9 + 2 review-patch: git-enclosing & PathNotFound suggestions) + `git_with_commit` helper
- `docs/rust-error-codes.md` — 3 Reserved rows flipped to Emitted-3.4c; new `jj.detect_failed` row
- `packages/zanshin_core/lib/src/ffi/repo.dart` — `zanshinRepoDetect`, `zanshinRepoConvert`
- `packages/zanshin_core/lib/src/worker/commands.dart` — `DetectRepoCommand`, `ConvertRepoCommand`
- `packages/zanshin_core/lib/src/worker/isolate.dart` — switch cases + `detect`/`convert` public methods

**Generated (by `cargo make codegen`, do not hand-edit):**
- `crates/zanshin-ffi/src/envelope_generated.rs`
- `crates/zanshin-ffi/include/zanshin_ffi.h`
- `packages/zanshin_core/lib/src/ffi/envelope_zanshin.ffi_generated.dart`
- `packages/zanshin_core/lib/src/ffi/bindings.dart`

**Created:**
- `packages/zanshin_core/lib/src/ffi/repo_detect.dart` — `RepoKind` enum, `RepoDetectResult`, `decodeRepoDetectEnvelope`
- `packages/zanshin_core/test/ffi/repo_detect_test.dart` — decode-contract tests (synthetic buffers)
- `packages/zanshin_core/test/worker/detect_test.dart` — real-cdylib round-trip tests (coverage attribution)
- `docs/ffi-abi.md` — FFI ABI reference (token contract, envelope format, RepoKind, both symbols)

### Change Log

- Added `enum RepoKind : byte { Jj, Git, Neither, PathNotFound }` and `table RepoDetect` to wire schema
- Added `zanshin_repo_detect` and `zanshin_repo_convert` extern "C" symbols to `repo.rs`
- Split `map_repo_err` to emit dedicated codes for `AlreadyJjRepo`/`NotAGitRepo`/`ConvertFailed` (previously stubbed to `jj.jj_lib_error` with a "until 3.4c" comment)
- Registered `jj.detect_failed` as a new error code (first emission here); flipped 3 Reserved codes to Emitted
- Wired full Dart seam: FFI adapter → decode model → worker commands → public API
- Created `docs/ffi-abi.md` as the seed ABI reference for future FFI stories
- `cargo make test` gate: 98.33% coverage, extern-coverage OK

## Review Findings

_Code review 2026-06-28 — `bmad-code-review` (ultracode multi-agent: 3 prescribed layers [Blind Hunter + Edge Case Hunter + Acceptance Auditor] + 3 domain lenses [Rust-FFI/FlatBuffers, Dart-seam/worker, anti-pattern-compliance] → dedup → per-finding adversarial verification → completeness critic; 24 agents). **ZERO production correctness / memory-safety / data-integrity defects.** All three domain lenses returned clean (no findings); no banned anti-pattern triggered; the FFI ownership, FlatBuffers wire contract, error taxonomy, and worker seam all verified sound. No blockers, no high-severity. Outcome: 1 decision-needed, 6 patch, 5 deferred, 4 dismissed as verified false-positives._

**Applied 2026-06-28 (option 1 — apply every patch):** all 7 patches (the resolved decision + 6) applied; `cargo make test` re-run green. **Correction on the convert-handle assertion (f10):** `handleId` is a 0-based dense worker id (the very first handle is `0`), so the literal suggestion (`!= 0` / `> 0`) would have *broken* the test — the verifier had mistaken the Dart dense id for the Rust raw pointer. Instead the test now proves the handle is live and registered by requiring `handle.close()` to complete (a bogus/unregistered handle throws `ffi.invalid_handle`). **Correction on the enum-range guard (f2):** the chosen option 1 (catch-and-rethrow) trips the project's `avoid_catching_errors` lint — catching `StateError` (an `Error` subclass) is banned, and the no-suppression policy rules out `// ignore`. Resolved instead as the project-idiomatic option 2: the out-of-range `StateError` propagates by design (it signals cdylib/bindings version-skew or corruption — a bug that must crash loudly, not be swallowed), now documented on `decodeRepoDetectEnvelope`.

**Decision needed**

- [x] [Review][Decision → documented by-design] Out-of-range `RepoKind` byte throws an unguarded `StateError` instead of `ZanshinFfiException` — `_decodeRepoDetectEnvelope` reads `payload.kind` / `payload.suggestedKind`; the generated `RepoKind.fromValue` throws raw `StateError` on a byte > 3, bypassing the seam's structured `ffi.unknown` error model. Reachable ONLY under cdylib/bindings version-skew or memory corruption (both sides are generated from one schema; the Rust producer only emits 0..=3). Options: **(a)** wrap the two enum reads and rethrow as `ZanshinFfiException('ffi.unknown', …)` — consistent with the existing `payload is! RepoDetect → ffi.unknown` guard; **(b)** accept `StateError`-by-design for version-skew and document it. [packages/zanshin_core/lib/src/ffi/repo_detect.dart:67-69]

**Patch**

- [x] [Review][Patch] Story File List: `coverage-baseline.txt` is listed under "Modified / raised" but is byte-identical to HEAD (last touched pre-3.4c, commit d01d507); reconcile the self-contradictory "raised from prior baseline" vs "coverage held at 98.33%" — per-file floors were already at ceiling and did not move, so no raise was needed [this story: File List / Task 10 / Completion Notes]
- [x] [Review][Patch] Story File List: drop the phantom generated artifact `app/lib/src/ffi/bindings.dart` — no such file exists and codegen does not emit into `app/` (Task 6 itself hedged it conditionally) [this story: File List → Generated]
- [x] [Review][Patch] Add a Git-enclosing-suggestion test (symmetric twin of the existing Jj test): empty subdir inside a `git init` repo → `kind == Neither`, `suggested_root == git root`, `suggested_kind == Git`. The `Git` suggestion value is currently never observed crossing the wire in any test (the only end-to-end suggestion tests assert `Jj`; the lone Git value is a hand-built buffer that deliberately nulls it out) [crates/zanshin-ffi/tests/repo_ffi.rs; packages/zanshin_core/test/worker/detect_test.dart]
- [x] [Review][Patch] Add a PathNotFound+suggestion test: nonexistent child inside a jj repo → `kind == PathNotFound`, `suggested_root` set, `suggested_kind == Jj`. The documented `PathNotFound` half of the `Neither | PathNotFound => find_repo_root(...)` branch is untested (only the `Neither` half is) [crates/zanshin-ffi/tests/repo_ffi.rs]
- [x] [Review][Patch] Make the Dart convert-handle assertion meaningful: `greaterThanOrEqualTo(0)` is vacuous for an unsigned pointer id (0 is the reserved invalid sentinel); align with the Rust suite's `assert_ne!(handle, 0)` [packages/zanshin_core/test/worker/detect_test.dart:133]
- [x] [Review][Patch] Document the `$HOME` ceiling on the enclosing-repo suggestion in `docs/ffi-abi.md` (and ideally the `zanshin_repo_detect` rustdoc cbindgen lifts into the header): a repo at or above `$HOME` is intentionally not surfaced as `suggested_root`. The ceiling is documented on `find_repo_root` but not at the FFI boundary the UI/MCP consumer reads [docs/ffi-abi.md; crates/zanshin-ffi/src/repo.rs]

**Deferred** (pre-existing / by-design / out-of-scope for 3.4c)

- [x] [Review][Defer] `decodeRepoDetectEnvelope` + `…Internal` twin is the established repo-wide convention (`status.dart` / `bookmarks.dart` / `remotes.dart` all define the identical public + `Internal` + private trio); 3.4c correctly matches it per the "copy 3.4a verbatim" mandate — eliminating the twin is a separate repo-wide refactor [packages/zanshin_core/lib/src/ffi/repo_detect.dart:47-50] — deferred, pre-existing convention
- [x] [Review][Defer] `RepoDetect.kind` / `suggested_kind` are not `(required)` → an absent field reads as `Jj`; this is inherent FlatBuffers enum-default semantics shared by every enum field in the schema, and the trusted in-repo Rust producer always writes `kind` [schemas/envelope.fbs] — deferred, schema-wide convention
- [x] [Review][Defer] detect runs `detect_repo` then `find_repo_root` from the same path (~3 extra syscalls on the no-repo-here path); this is the intentional single-dir vs walk-up API split, not redundancy to collapse [crates/zanshin-ffi/src/repo.rs] — deferred, by-design
- [x] [Review][Defer] `toNativeUtf8()` (default `malloc`) is freed with `calloc.free`; functionally identical (both delegate to C `free`) and already consistent with the file's existing `calloc.free` usage [packages/zanshin_core/lib/src/ffi/repo.dart] — deferred, cosmetic
- [x] [Review][Defer] No null-pointer / invalid-UTF-8 test for the two new extern fns; the shared `cstr_to_string` helper is already unit-tested for both error paths and the wiring is byte-identical to the tested `zanshin_repo_open` [crates/zanshin-ffi/tests/repo_ffi.rs] — deferred, low-value (helper already covered)

**Dismissed** (verified false-positives — refuted against the real code)

- `ffi.null_pointer` / `ffi.utf8_error` "missing from registry/imports" — FALSE: the constants exist in `envelope.rs`, `cstr_to_string` emits them, and both rows are in `rust-error-codes.md` (Story 3.2); they propagate via `?`.
- Positive suggestion test "uses the FlatBuffers default so can't detect a broken round-trip" — FALSE: the generated builder writes value 0 to the wire (no `def` arg), so the round-trip is real; the negative test also uses `Git`.
- `find_repo_root` "invoked unconditionally despite being consent-gated" — FALSE: the walk is stat-only and harmless; the consent gate is on the *open* action, which the backend never performs.
- Production decode "runs no FlatBuffers Verifier" — FALSE: matches the established un-verified pattern of every sibling decoder; bytes always come from the trusted same-process Rust side.
