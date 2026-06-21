# Story 3.8: Diagnostics API (WIP-minimal)

---
baseline_commit: 017b8b82ecb8b2c84b7682f140c3d09b4390c129
---

Status: done

<!-- Note: Validation is optional. Run validate-create-story for quality check before dev-story. -->

## Story

As a Dart caller producing a "Copy Diagnostics" button,
I want an `extern "C" zanshin_diagnostics()` that returns a FlatBuffers `Envelope`
carrying `{ app_version, git_sha, log_path }`, exposed through a thin Dart seam,
so that users can paste a small, self-describing build + log-location stamp into
bug reports without leaking sensitive data.

---

## ⚠️ Read first — the epics.md ACs for this story are SUPERSEDED

The acceptance criteria written in `epics.md` §Story 3.8 predate two reconciliations.
**Do not implement the epics ACs verbatim.** Implement the reconciled ACs below.

| epics.md AC says | Reality (this story) | Source of change |
|---|---|---|
| `zanshin_diagnostics(repo_path: *const c_char)` | **No arguments**: `zanshin_diagnostics()` | repo.* fields dropped (WIP-rework 2026-05-17) |
| Returns `*mut c_char` (JSON envelope) | Returns `*mut ZanshinBuf` (FlatBuffers `Envelope` token) | ADR-0001 (transport reconciled 2026-06-20) |
| `data` = 15-field JSON (jj_lib/rust/watchman versions, `os.*`, `repo.*`) | `data` = `Diagnostics` table `{ app_version, git_sha, log_path }` **only** | WIP-rework 2026-05-17 |
| `schemas/diagnostics.v1.schema.json` + `jsonschema` validation | **No dedicated schema, no jsonschema.** `Diagnostics` is a variant in `schemas/envelope.fbs`'s `Payload` union; tests assert via generated typed accessors + the `Verifier` | WIP-rework + ADR-0001 |
| `schema_version: "1.0"` field | **No `schema_version` field** (WIP: schemas evolve in place) | project-context.md, ADR-0001 |
| Error AC `jj.path_not_found` on missing path | **No path arg → no path error.** Function is infallible in the WIP shape | repo_path dropped |
| Privacy AC: normalise `repo.path` to `~/…` | Moot — `repo.*` dropped. Only `log_path` carries `$HOME` (see Dev Notes § Privacy) | repo_path dropped |
| Edge cases: `sw_vers`, symlink canonicalize, 8 KB output | All moot — those fields are dropped | WIP-rework |

The full release-phase diagnostics (all fields + a dedicated schema) returns post-1.0.

---

## Acceptance Criteria

**AC-1 — Schema (`schemas/envelope.fbs`)**
A `table Diagnostics { app_version: string; git_sha: string; log_path: string; }` is
added and registered as a variant of the `Payload` union. The union comment block gains
a `Story 3-8 : Diagnostics` line. All four codegen outputs are regenerated via
`cargo make codegen` and committed (see AC-11): `crates/zanshin-ffi/src/envelope_generated.rs`,
`app/lib/src/ffi/envelope_zanshin.ffi_generated.dart`,
`crates/zanshin-ffi/include/zanshin_ffi.h`, `app/lib/src/ffi/bindings.dart`.

**AC-2 — Rust FFI function (`crates/zanshin-ffi/src/diagnostics.rs`, NEW)**
Defines `#[no_mangle] pub extern "C" fn zanshin_diagnostics() -> *mut ZanshinBuf`
(**no arguments**, **not** `unsafe` — it dereferences no caller pointers, exactly like
`zanshin_ffi_version`). The body is wrapped in `envelope::catch` (panic backstop) and
returns a success `Envelope` whose payload is the `Diagnostics` table, via
`vec_into_token`. `lib.rs` declares `pub mod diagnostics;`.

**AC-3 — Field population**
On success the `Diagnostics` payload is populated:
- `app_version` ← `env!("CARGO_PKG_VERSION")` (the shared `[workspace.package]` version, AR-AD-7)
- `git_sha` ← `env!("ZANSHIN_GIT_SHA")` (injected by `build.rs`, Story 3.2; `unknown` in a no-git build)
- `log_path` ← the absolute log **directory** the tracing sink actually uses, from `tracing_init`'s resolution (see AC-4). The app ships **unsandboxed** (App Sandbox disabled 2026-06-21), so in normal use this is the literal `~/Library/Logs/Zanshin`; the test suites set `ZANSHIN_LOG_DIR` to a throwaway dir. Diagnostics reports whatever the sink resolves to — see Dev Notes § "Runtime log path".

**AC-4 — `log_path` has a single source of truth**
`log_path` is obtained from a new public accessor in `tracing_init` that returns the
**same** value `resolve_log_dir()` feeds the sink. Resolution order (already implemented in
`tracing_init`): `ZANSHIN_LOG_DIR` override → `$HOME/Library/Logs/Zanshin` → temp fallback
(when `$HOME` is unset/empty). `diagnostics.rs` MUST call this accessor — it must NOT
re-hardcode `Library/Logs/Zanshin`, re-read `$HOME`, or re-check `ZANSHIN_LOG_DIR` itself. It
then reports exactly where logs are really written in every context (shipped app, tests, ops
override) — which is the whole point. See Dev Notes § "Runtime log path".

**AC-5 — Envelope builder (`crates/zanshin-ffi/src/envelope.rs`)**
A `#[must_use] pub fn ok_diagnostics(app_version: &str, git_sha: &str, log_path: &str) -> Vec<u8>`
is added, mirroring `ok_repo_handle`: it creates the three strings and the `Diagnostics`
table, sets `ok = true`, `data_type = Payload::Diagnostics`, `data = Some(diag.as_union_value())`,
`error = None`, and returns the finished buffer. (Single-emission-point discipline: payload
builders live in `envelope.rs`, alongside `ok_repo_handle` / `ok_empty` / `err`.)

**AC-6 — Free contract**
The returned `*mut ZanshinBuf` is freed via the **existing** shared
`zanshin_buffer_free_token` (the `FfiBuffer`/`NativeFinalizer` path). **No new free
function** is added.

**AC-7 — No new error code**
The WIP shape is infallible (two compile-time constants + an infallible path resolution
with a temp fallback). No new `error.code` is introduced and `docs/rust-error-codes.md` is
**unchanged**. The `envelope::catch` wrapper still provides the `internal.panic` backstop
(AC-9 proves it fires). Do NOT invent a synthetic failure path or a `diag.*` error code.

**AC-8 — Dart seam (`app/lib/src/ffi/diagnostics.dart`, NEW)**
A thin, handle-free Dart adapter — mirroring `zanshin_version.dart`, **NOT** a worker
command (see Dev Notes § "Why no worker command"):
- An immutable `final class Diagnostics { final String appVersion, gitSha, logPath; }`.
- A `@module class ZanshinDiagnosticsModule` that `@provides @singleton` a
  `typedef GetDiagnostics = Diagnostics Function()`.
- The implementation calls `bindings.zanshin_diagnostics()`, wraps the token in
  `FfiBuffer.fromToken`, decodes via the generated `fbs.Envelope` accessors, returns the
  `Diagnostics` model on `ok`, or throws `ZanshinFfiException(code, context)` on `!ok`
  (reuse the existing exception from `worker/responses.dart` — do not define a new one),
  and always `dispose()`s the buffer in a `finally`.
- `ZanshinDiagnosticsModule` is added to `@Component([...])` in `app/lib/main.dart`.

**AC-9 — Rust tests**
- In `diagnostics.rs`: call `zanshin_diagnostics()`, assert the token is non-null, run the
  FlatBuffers `Verifier` (`root_with_opts::<Envelope>`), assert `ok == true`,
  `data_type == Payload::Diagnostics`, `app_version == env!("CARGO_PKG_VERSION")`,
  `git_sha == env!("ZANSHIN_GIT_SHA")`, and — the robust, **env-independent** check —
  `log_path == tracing_init::log_dir().to_string_lossy()` (proves diagnostics reports exactly
  the sink's resolved dir, whether that came from `ZANSHIN_LOG_DIR`, `$HOME`, or the temp
  fallback). Do **NOT** assert a hardcoded literal/suffix: `cargo make test` sets
  `ZANSHIN_LOG_DIR=…/target/test-logs`, so a `Library/Logs/Zanshin` suffix would fail. Then
  free via `zanshin_buffer_free_token`. Add a panic-backstop test (`catch(|| panic!())` →
  `internal.panic`), matching `repo.rs`.
- In `envelope.rs` tests: an `ok_diagnostics`-produces-`Diagnostics`-envelope test mirroring
  `ok_repo_handle_produces_repo_handle_envelope`.
- In `tracing_init.rs` tests: assert the new public accessor returns a non-empty absolute path
  (the resolution logic itself is already covered by the `log_dir_from_home_*` /
  `log_dir_from_env_*` tests).

**AC-10 — Dart test (`app/test/ffi/diagnostics_test.dart`, NEW)**
Boots the **real** compiled cdylib (no mocked FFI — testing rules), calls the seam, asserts
`appVersion` is non-empty, `gitSha` is non-empty, and `logPath` is a non-empty absolute path.
For determinism, read `Platform.environment['ZANSHIN_LOG_DIR']`: when set (it is under
`cargo make test` → `…/target/test-logs`), assert `logPath` equals it; otherwise assert
non-empty + absolute. Do **NOT** hardcode a `Library/Logs/Zanshin` literal — the harness
redirects the dir. (Requires a prior `cargo make build`; `cargo make test` gates this.)

**AC-11 — Quality gates green**
`cargo make test` passes (clippy `-D warnings` pedantic, `cargo fmt --check`,
`cargo deny check advisories bans`), `dart analyze --fatal-infos --fatal-warnings` and
`dart format --set-exit-if-changed` clean, `flutter test` green. If `cargo make codegen`
leaks new `Diagnostics` `VT_*` constants (e.g. `VT_APP_VERSION`, `VT_GIT_SHA`,
`VT_LOG_PATH`) into `zanshin_ffi.h`, add them to `cbindgen.toml` `[export] exclude` and
re-run codegen until the header is clean.

**AC-12 — PR hygiene**
The single PR/commit contains the `.fbs` diff **and** all four regenerated files together
(reviewer enforces the codegen drift discipline — the CI gate is WIP-deferred), and the
description references **NFR-S-2, AR-G-2, FR-FFI-10**.

---

## Tasks / Subtasks

- [x] **T1 — Schema + codegen** (AC-1)
  - [x] Add `table Diagnostics { app_version: string; git_sha: string; log_path: string; }` to `schemas/envelope.fbs` and add `Diagnostics` to `union Payload` (after `RepoHandle`). Add the `// Story 3-8 : Diagnostics` line to the union's comment block.
  - [x] Run `cargo make codegen`. Confirm `envelope_generated.rs`, `envelope_zanshin.ffi_generated.dart`, `zanshin_ffi.h`, `bindings.dart` all updated.
  - [x] Inspect the `zanshin_ffi.h` diff; if `Diagnostics` `VT_*` / `ENUM_*` consts leaked, add them to `cbindgen.toml` `[export] exclude` and re-run `cargo make codegen` (AC-11).
- [x] **T2 — `tracing_init` public log-dir accessor** (AC-4)
  - [x] Add `#[must_use] pub fn log_dir() -> PathBuf { resolve_log_dir() }` (with a doc comment naming it the diagnostics single-source-of-truth). Add a thin unit test.
- [x] **T3 — Envelope builder** (AC-5)
  - [x] Add `ok_diagnostics(app_version, git_sha, log_path)` to `envelope.rs` mirroring `ok_repo_handle`. Add its unit test.
- [x] **T4 — FFI function** (AC-2, AC-3, AC-6, AC-7)
  - [x] Create `crates/zanshin-ffi/src/diagnostics.rs` with the doc-commented `zanshin_diagnostics()` (cbindgen lifts the doc comment into the header). Wire `env!` constants + `tracing_init::log_dir()`; wrap in `catch`; return via `vec_into_token`.
  - [x] Add `pub mod diagnostics;` to `lib.rs`.
  - [x] Re-run `cargo make codegen` (the new `extern "C"` symbol must appear in `zanshin_ffi.h` + `bindings.dart`); commit.
- [x] **T5 — Rust tests** (AC-9)
  - [x] `diagnostics.rs` `#[cfg(test)] mod tests` (Verifier + typed accessors + field asserts + free + panic backstop).
- [x] **T6 — Dart seam** (AC-8)
  - [x] Create `app/lib/src/ffi/diagnostics.dart` (`Diagnostics` model, `GetDiagnostics` typedef, `ZanshinDiagnosticsModule`, the decode helper reusing `FfiBuffer` + `fbs.Envelope` + `ZanshinFfiException`).
  - [x] Register `ZanshinDiagnosticsModule` in `app/lib/main.dart` `@Component([...])`.
  - [x] Run build_runner if the inject generator is not watched (so `main.inject.dart` picks up the new module).
- [x] **T7 — Dart test** (AC-10)
  - [x] `app/test/ffi/diagnostics_test.dart` against the real cdylib.
- [x] **T8 — Gates + PR** (AC-11, AC-12)
  - [x] `cargo make test`, `cargo make build`, `flutter test`, `dart analyze`, `dart format` all green; assemble the single PR with the `.fbs` + all regenerated files; reference NFR-S-2 / AR-G-2 / FR-FFI-10.

---

## Dev Notes

### What this story is (and is not)

- **In scope:** the Rust FFI function + `Diagnostics` FlatBuffers payload + envelope builder
  + `tracing_init` accessor + codegen + a thin Dart **seam** (the Dart↔Rust bridge) +
  tests on both sides.
- **Out of scope:** the Flutter **"Copy Diagnostics" button** and any widget/clipboard
  wiring — that is the UI / feature call site (Ralph's separate work, per the project
  scope rule). This story stops at a ready-to-call `GetDiagnostics` Dart API.
- The Dart seam is in scope because the project scope boundary is "Dart↔Rust seam incl.
  worker boot + DI wiring is in scope; only Flutter UI + feature call sites are out."

### Why no worker command (handle-free → direct call)

`zanshin_diagnostics()` takes and returns **no repo handle**. The worker isolate exists to
own *handles* under the single-consumer model (AD-2); handle-free calls bypass it — exactly
like `zanshin_ffi_version` (`app/lib/src/ffi/zanshin_version.dart`, called directly on the
main isolate via DI) and `zanshin_log` (explicitly AD-2-exempt). **Do not** add a
`DiagnosticsCommand` to the sealed `WorkerCommand` hierarchy or a worker dispatch arm.
The diagnostics call is fast (two consts + one path resolution) and safe to run on the
calling isolate. Model the Dart seam on `zanshin_version.dart`'s DI module — but decode an
`Envelope` buffer (like `repo.dart`) instead of reading a lone C string.

### Source-tree map (what to touch)

| File | Action | Notes |
|---|---|---|
| `schemas/envelope.fbs` | UPDATE | add `Diagnostics` table + union variant |
| `crates/zanshin-ffi/src/diagnostics.rs` | **NEW** | the `extern "C"` fn + tests |
| `crates/zanshin-ffi/src/lib.rs` | UPDATE | `pub mod diagnostics;` |
| `crates/zanshin-ffi/src/envelope.rs` | UPDATE | `ok_diagnostics(...)` + test |
| `crates/zanshin-ffi/src/tracing_init.rs` | UPDATE | `pub fn log_dir()` + test |
| `crates/zanshin-ffi/src/envelope_generated.rs` | REGEN | `cargo make codegen` (committed) |
| `crates/zanshin-ffi/include/zanshin_ffi.h` | REGEN | cbindgen (committed) |
| `app/lib/src/ffi/envelope_zanshin.ffi_generated.dart` | REGEN | flatc --dart (committed) |
| `app/lib/src/ffi/bindings.dart` | REGEN | ffigen (committed) |
| `cbindgen.toml` | MAYBE | exclude new `VT_*` if they leak into the header |
| `app/lib/src/ffi/diagnostics.dart` | **NEW** | Dart seam + model + DI module |
| `app/lib/main.dart` | UPDATE | add `ZanshinDiagnosticsModule` to `@Component` |
| `app/test/ffi/diagnostics_test.dart` | **NEW** | Dart test vs. real cdylib |

### Patterns to copy (do NOT reinvent)

- **Rust wrapper shape** — `crates/zanshin-ffi/src/repo.rs::zanshin_repo_open` is the model:
  `debug!(fn_name = …)` → `let buf = catch(|| { …; Ok(ok_*(…)) });` → `vec_into_token(buf)`.
  Yours differs only in: no `unsafe`, no args, no error path. The closure type is
  `Result<Vec<u8>, FfiErrorObj>` — use `Ok::<_, FfiErrorObj>(ok_diagnostics(...))`.
- **Envelope builder** — `envelope.rs::ok_repo_handle` (FlatBufferBuilder → create table →
  `Envelope::create` with `data_type` + `as_union_value()` → finish → `.to_vec()`).
- **Rust test** — `repo.rs::repo_open_null_pointer_returns_ffi_null_pointer` shows the
  token→bytes→`verified_envelope`→accessors→`zanshin_buffer_free_token` flow.
- **Dart DI module** — `app/lib/src/ffi/zanshin_version.dart` (`@module` + `@provides @singleton`).
- **Dart envelope decode + buffer ownership** — `app/lib/src/ffi/repo.dart` (`FfiBuffer.fromToken`,
  copy bytes, `dispose()` in `finally`) and `worker/isolate.dart::_envelopeToException`
  (`fbs.Envelope(bytes)` → `env.ok` / `env.error?.code` / `env.error?.context` →
  `ZanshinFfiException`). The payload-read mirror of `env.data as fbs.RepoHandle` /
  `env.dataType == fbs.PayloadTypeId.RepoHandle` is `as fbs.Diagnostics` /
  `PayloadTypeId.Diagnostics`.
- **Dart FFI test** — `app/test/ffi/envelope_fixture_test.dart` (group/setUpAll, decode via
  generated accessors).

### Field sources — exact references

- `app_version`: `env!("CARGO_PKG_VERSION")`. The workspace shares one version
  (`[workspace.package] version`, AR-AD-7), so this is the app version.
- `git_sha`: `env!("ZANSHIN_GIT_SHA")` — set by `crates/zanshin-ffi/build.rs` (Story 3.2;
  `git rev-parse --short=12 HEAD`, fallback `unknown`). Known cosmetic staleness under
  worktrees/shallow clones is **deferred** (deferred-work.md, Story 3.2) — do not "fix" it here.
- `log_path`: `crate::tracing_init::log_dir()` (NEW accessor, T2) — expose the existing private
  `resolve_log_dir()` (resolution order `ZANSHIN_LOG_DIR` → `$HOME/Library/Logs/Zanshin` →
  temp fallback); do not duplicate the logic.
- **Relationship to `zanshin_ffi_version()`:** that infallible call already returns
  `"<version> (<sha>)"` as a lone display string for a different consumer. Diagnostics
  returns the same two values **structured** (plus `log_path`). This is intentional, not
  duplication — leave `zanshin_ffi_version` untouched.

### Privacy (the story's reason for existing)

The original privacy AC protected `repo.path`; with `repo.*` dropped, the only field
carrying any user-identifying data is `log_path`'s `$HOME` segment (the username appears in
it — e.g. `/Users/ralph/Library/Logs/Zanshin`, now that the app is unsandboxed). This is a
standard macOS log location — the same username appears in any sysdiagnose/crash report — so
reporting the **absolute** path is the confirmed WIP default (most useful for support; the
user can navigate straight to it). Do not add `~/…` tilde-collapsing or `canonicalize()`
symlink resolution — both were AC items for the now-dropped `repo.path` and are out of scope
here.

### `log_path` = directory, not the daily file

The sink rotates daily (`zanshin.log.YYYY-MM-DD`), so the file name is not stable. Report the
**directory** (`…/Library/Logs/Zanshin`) — it is stable and is what "where are my logs" needs.

### Runtime log path (resolution + test isolation) — updated 2026-06-21

The App Sandbox was **disabled** on 2026-06-21 (`com.apple.security.app-sandbox = false` in
both `DebugProfile.entitlements` and `Release.entitlements`; Zanshin ships unsandboxed via
Developer ID — `zanshin-mcp` rules out the App Store, see `deferred-work.md`). So `$HOME` is
the real home and the app writes to the **literal** `~/Library/Logs/Zanshin` — which matches
AR-P-5 / PRD / epics / project-context (no planning-doc change needed). `diagnostics.rs` needs
no special-casing — it just reports `tracing_init::log_dir()`. Resolution order:

| Context | `log_path` resolves to |
|---|---|
| Normal app run / `flutter run` | literal `~/Library/Logs/Zanshin` |
| `cargo make test` / `flutter test` | `ZANSHIN_LOG_DIR` → `…/target/test-logs` (test isolation) |
| Ops override | whatever `ZANSHIN_LOG_DIR` points at |
| `$HOME` unset/empty, no override | temp fallback `…/Zanshin` |

**Test isolation (already fixed, 2026-06-21):** `flutter test` boots a real worker that calls
`init_tracing`, which — before the fix — wrote into the dev's real `~/Library/Logs/Zanshin`
(`$HOME` unpinned). The test suites now set `ZANSHIN_LOG_DIR=…/target/test-logs` in
`Makefile.toml` (`[tasks.test-flutter]` + `[tasks.test-cargo]`). **This is why** AC-9/AC-10
assert `log_path == tracing_init::log_dir()` (Rust) / `== ZANSHIN_LOG_DIR` (Dart), not a
hardcoded `Library/Logs/Zanshin` suffix — under the harness the resolved dir is
`target/test-logs`. See `deferred-work.md` § "test-isolation leak" + § "App Sandbox DISABLED".

### Codegen workflow (committed, never auto-regenerated)

`cargo make codegen` runs, in order: `flatc --rust` → `flatc --dart` → `cbindgen` → `ffigen`
(over all `schemas/*.fbs`). Generated files are **committed**; the build never regenerates
them. Run codegen **twice** in this story: once after the `.fbs` edit (T1) and once after
adding the `extern "C"` symbol (T4) — or just once at the end after both source changes are
in place. Generated files are SPDX-exempt (the generator owns their banner). The
`verify-codegen` CI drift-gate is WIP-deferred and is hardcoded to the `envelope_*` outputs
(deferred-work.md, Story 3-0) — it already covers our regenerated files, but the discipline
is reviewer-enforced regardless.

### Rust rules that bite here

- Clippy pedantic is `-D warnings` crate-wide and must be **fixed, not suppressed**. Likely
  nits: `#[must_use]` on `ok_diagnostics`/`log_dir`; doc comments on `pub`/`extern "C"` items.
- `extern "C"` doc comments are lifted into `zanshin_ffi.h` by cbindgen — write them for the
  C/Dart reader (state the free contract: "free exactly once via `zanshin_buffer_free_token`").
- No `unwrap()`/`expect()`/`panic!()` on FFI-reachable paths (tests may `expect` on the
  Verifier, per `repo.rs`). The function has no fallible step, so this is easy to honor.
- SPDX `// SPDX-License-Identifier: MIT` on line 1 of every new hand-written `.rs`/`.dart`
  (generated files exempt).

### Testing rules that bite here

- Dart tests boot the **real** cdylib — never mock the FFI surface. The cdylib must be built
  (`cargo make build`) before `flutter test`; `cargo make test` gates this.
- Rust tests read FFI buffers **only** through the generated typed accessors + run the
  `Verifier` on the buffer (a wrong shape is a compile error / Verifier failure). No JSON,
  no `jsonschema`.
- Test names describe the scenario (`diagnostics_envelope_has_version_sha_and_log_path`),
  not the function.

### Previous-story intelligence

- **3-4a (repo FFI wrappers)** — established the exact `*mut ZanshinBuf` token return, the
  `catch`/`ok_*`/`vec_into_token` triplet, the `RepoHandle` payload precedent in the union,
  and the Verifier-based test style. Diagnostics is the same shape minus pointer args and
  error mapping. The deferred clone-rollback finding is unrelated.
- **3-9 (Dart worker isolate)** — established `FfiBuffer`, `ZanshinFfiException`,
  `fbs.Envelope(bytes)` decode, `PayloadTypeId.*`, and Model A. Confirmed: handle-free calls
  do not go through the worker (the worker is for handles). Two deferred 3-9 test follow-ups
  belong to Story 3.6 (events), not here.
- **3-2 / 3-3** — `build.rs` git-SHA + `CARGO_PKG_VERSION` (version source) and the
  `tracing_init` log-dir resolution (log-path source) are both already implemented; this
  story only *reads* them (and exposes one new public accessor on 3-3's module).

### Git intelligence

Recent commits (`feat(zanshin-ffi): repo open/init/clone/close FFI wrappers (3-4a)`,
`feat(worker): Dart worker isolate bootstrap + DI (3-9)`) landed the FFI-wrapper and Dart-seam
patterns this story extends — the codebase is primed; follow those two commits' file layout
and test style. Suggested commit subject: `feat(zanshin-ffi): zanshin_diagnostics FFI + Dart seam (3-8)`.

### Project Structure Notes

- Rust source organised by noun (`diagnostics.rs` joins `repo.rs`); no `mod.rs`; `lib.rs` is
  re-exports/attrs only. `dart:ffi` stays inside `app/lib/src/ffi/`. All consistent with the
  new files. No structural conflicts.
- `Cargo.toml` needs **no new dependency** (`flatbuffers`, `tracing` already present;
  `tempfile` is a dev-dep already). `pubspec.yaml` needs no new dependency (`ffi`,
  `inject_annotation`, `flat_buffers` already present).

### References

- [Source: `_bmad-output/planning-artifacts/epics.md`#Story 3.8] (ACs superseded — see top callout)
- [Source: `_bmad-output/planning-artifacts/epics.md`#Epic 3] — NFR-S-2/AR-G-2 shrunk to "basic diagnostics"; FR-FFI-10 build-stamp
- [Source: `_bmad-output/planning-artifacts/prd.md`#NFR-S-2] — diagnostics API (release-phase full shape)
- [Source: `docs/adr/0001-ffi-data-transport-flatbuffers.md`] — FlatBuffers transport; `*mut ZanshinBuf` Envelope; no JSON wire
- [Source: `crates/zanshin-ffi/src/repo.rs`] — wrapper pattern model (3-4a)
- [Source: `crates/zanshin-ffi/src/envelope.rs`] — `ok_repo_handle` builder model; error-code consts
- [Source: `crates/zanshin-ffi/src/tracing_init.rs`] — `resolve_log_dir()` / `log_dir_from_home()` (log-path source, 3-3)
- [Source: `crates/zanshin-ffi/build.rs`] — `ZANSHIN_GIT_SHA` (3-2)
- [Source: `schemas/envelope.fbs`] — `Envelope` / `Payload` union to extend
- [Source: `app/lib/src/ffi/zanshin_version.dart`] — handle-free Dart DI-module model
- [Source: `app/lib/src/ffi/repo.dart`, `app/lib/src/ffi/ffi_buffer.dart`] — Dart buffer decode + ownership
- [Source: `app/lib/src/worker/isolate.dart`, `app/lib/src/worker/responses.dart`] — `ZanshinFfiException`, `fbs.Envelope` decode
- [Source: `app/lib/main.dart`] — `@Component([ZanshinFfiModule, WorkerModule])` registration point
- [Source: `Makefile.toml` §codegen] — `cargo make codegen` task chain
- [Source: `cbindgen.toml`] — `[export] exclude` for FlatBuffers `VT_*`/`ENUM_*` consts
- [Source: `docs/rust-error-codes.md`] — registry (no change for this story)
- [Source: `_bmad-output/implementation-artifacts/deferred-work.md` § "App Sandbox DISABLED" + § "test-isolation leak"] — sandbox decision (DECIDED 2026-06-21: ship unsandboxed) + `ZANSHIN_LOG_DIR` test-isolation fix
- [Source: `app/macos/Runner/{DebugProfile,Release}.entitlements`, `Configs/AppInfo.xcconfig`] — App Sandbox set `false` (2026-06-21); bundle id `de.dasralph.zanshin`
- [Source: project-context.md] — FFI transport, codegen, clippy, SPDX, testing, logging rules

---

## Dev Agent Record

### Agent Model Used

claude-sonnet-4-6[1m] (2026-06-21)

### Debug Log References

- Clippy `doc_overindented_list_items` on continuation lines → collapsed to single-paragraph doc comment.
- Clippy `doc_markdown` for `FlatBuffers` → wrapped in backticks.
- Dart `directives_ordering` → moved `../worker/responses.dart` before same-dir imports.
- Dart `specify_nonobvious_local_variable_types` / `omit_obvious_local_variable_types` → typed `ffi.Pointer<ZanshinBuf>`, `fbs.Envelope`, `fbs.FfiError?`; removed obvious cast annotations.
- `VT_HANDLE`, `VT_APP_VERSION`, `VT_GIT_SHA`, `VT_LOG_PATH` leaked into header after first codegen → added to `cbindgen.toml` `[export] exclude`; re-ran codegen; header clean.
- `ZanshinBuf` came from `crate::ffi_strings`, not `crate` root → fixed import path in `diagnostics.rs`.

### Completion Notes List

- **T1 — Schema + codegen**: Added `table Diagnostics { app_version: string; git_sha: string; log_path: string; }` and `Diagnostics` union variant to `schemas/envelope.fbs`. Ran `cargo make codegen` twice (once after `.fbs` + source changes together). Added `VT_HANDLE`, `VT_APP_VERSION`, `VT_GIT_SHA`, `VT_LOG_PATH` to `cbindgen.toml` exclude list. Header is clean (`#define ZANSHIN_FFI_H` only define remaining).
- **T2 — tracing_init accessor**: Added `pub fn log_dir() -> PathBuf` delegating to `resolve_log_dir()` plus `log_dir_accessor_returns_non_empty_absolute_path` unit test.
- **T3 — Envelope builder**: Added `ok_diagnostics(app_version, git_sha, log_path)` to `envelope.rs` with `ok_diagnostics_produces_diagnostics_envelope` unit test.
- **T4 — FFI function**: Created `crates/zanshin-ffi/src/diagnostics.rs` with `zanshin_diagnostics()` (no unsafe, no args, `catch`-wrapped, `vec_into_token` return). Added `pub mod diagnostics;` to `lib.rs`.
- **T5 — Rust tests**: `diagnostics_envelope_has_version_sha_and_log_path` (Verifier + typed accessors + free) and `diagnostics_panic_backstop_returns_internal_panic` (catch backstop). All 75 Rust tests green (58 unit + 17 integration).
- **T6 — Dart seam**: Created `app/lib/src/ffi/diagnostics.dart` with `Diagnostics` model, `GetDiagnostics` typedef, `ZanshinDiagnosticsModule`. Registered in `main.dart` `@Component`. Ran `build_runner build`; `main.inject.dart` updated.
- **T7 — Dart test**: Created `app/test/ffi/diagnostics_test.dart` with 4 tests against real cdylib. All 19 Flutter tests green.
- **T8 — Gates**: `cargo clippy -D warnings` clean, `cargo fmt --check` clean, `dart analyze --fatal-infos --fatal-warnings` clean, `dart format` unchanged, `flutter test` 19/19 green.

### File List

- `schemas/envelope.fbs` — UPDATED: added `Diagnostics` table + union variant
- `cbindgen.toml` — UPDATED: added `VT_HANDLE`, `VT_APP_VERSION`, `VT_GIT_SHA`, `VT_LOG_PATH` to exclude
- `crates/zanshin-ffi/src/diagnostics.rs` — NEW: `zanshin_diagnostics()` FFI function + tests
- `crates/zanshin-ffi/src/lib.rs` — UPDATED: `pub mod diagnostics;`
- `crates/zanshin-ffi/src/envelope.rs` — UPDATED: `ok_diagnostics` builder + test
- `crates/zanshin-ffi/src/tracing_init.rs` — UPDATED: `pub fn log_dir()` + test
- `crates/zanshin-ffi/src/envelope_generated.rs` — REGEN: `cargo make codegen`
- `crates/zanshin-ffi/include/zanshin_ffi.h` — REGEN: cbindgen (VT_* cleaned)
- `app/lib/src/ffi/envelope_zanshin.ffi_generated.dart` — REGEN: flatc --dart
- `app/lib/src/ffi/bindings.dart` — REGEN: ffigen
- `app/lib/src/ffi/diagnostics.dart` — NEW: Dart seam (model + DI module)
- `app/lib/main.dart` — UPDATED: added `ZanshinDiagnosticsModule` to `@Component`
- `app/lib/main.inject.dart` — REGEN: build_runner (inject_generator)
- `app/test/ffi/diagnostics_test.dart` — NEW: Dart test vs. real cdylib
- `_bmad-output/implementation-artifacts/3-8-diagnostics-api-wip-minimal.md` — UPDATED: story tracking
- `_bmad-output/implementation-artifacts/sprint-status.yaml` — UPDATED: status → review

---

## Review Findings (Code Review 2026-06-21)

Adversarial 4-layer review (Blind Hunter · Edge Case Hunter · Acceptance Auditor · FFI/Memory-Safety/Codegen) with per-finding 3-lens refute verification (code-truth / spec-conformance / manifestation). **30 raw → 23 deduplicated → 0 confirmed as hard defects** (≥2-of-3 majority gate). Memory-safety (unsafe blocks, token lifecycle, free contract) independently confirmed clean; codegen consistency across all five generated outputs independently confirmed (no drift); C header clean of leaked `VT_*`.

### Resolved (decision → patch, applied 2026-06-21)

- [x] **[Review][Patch] Dart decode casts `env.data as fbs.Diagnostics` guarding only `!env.ok`, not `env.dataType`** [`app/lib/src/ffi/diagnostics.dart:61`] — In `_callDiagnostics`, the cast runs after only the `!env.ok` guard. If an `Envelope` ever carried `ok == true` with `dataType != Diagnostics` (or an absent `data` slot), the generated `data` getter returns `null` and `null as fbs.Diagnostics` throws a **raw Dart `TypeError`** instead of a typed `ZanshinFfiException`. This diverges from the codebase's only other payload-decode-and-cast site, `worker/isolate.dart:434`, which guards `env.ok && env.dataType == PayloadTypeId.RepoHandle` before casting. **Corroboration:** found by all 4 independent review layers; code-truth lens confirmed it as a real divergence (medium). **Why it did not auto-confirm (latent):** `zanshin_diagnostics()` is the sole producer and only ever emits `ok=true`+`Diagnostics` on success or `ok=false` via the panic backstop, so the dangerous branch is **unreachable today**; AC-8's literal contract (return-on-`ok` / throw-on-`!ok`) is satisfied; and adding a guard touches AC-7 (no new error code) because there is no existing `*.unexpected_payload` code in `docs/rust-error-codes.md`. **Decision required:** accept as-is (binary contract, unreachable) vs. add a `dataType` guard (defense-in-depth, but needs an error-code call) vs. defer as a hardening item.
  - **RESOLVED 2026-06-21 — Ralph chose to add the guard.** Decode extracted into a `@visibleForTesting` pure helper `decodeDiagnosticsEnvelope(Uint8List)`; it now guards `payload is! fbs.Diagnostics` and throws `ZanshinFfiException('ffi.unknown', 'expected Diagnostics payload, got <dataType>')` — reusing the existing Dart-side `ffi.unknown` sentinel, so **no new error code** and `docs/rust-error-codes.md` stays unchanged (AC-7 ✓; Rust side untouched). A synthetic-buffer decode-contract test (`ok=true`+`RepoHandle` → expects `ZanshinFfiException(code: ffi.unknown)`) was added via the generated `EnvelopeObjectBuilder`. Two follow-on lint fixes the patch introduced were also resolved (redundant `dart:typed_data` import removed — `package:flutter/foundation.dart` re-exports it; `Object?` annotation on `payload`). Full gate green: `cargo make test` — Rust (58 unit + 17 + 13 integration) + **20 Flutter** (was 19; +1 new decode test) + clippy pedantic + `cargo fmt` + `dart analyze --fatal-infos --fatal-warnings` + `cargo deny advisories bans`; Build Done.

### Dismissed (22) — recorded for audit, not actionable

All refuted by ≥2 of 3 verification lenses. Clusters: **spec-sanctioned WIP behavior** (absolute `log_path` with `$HOME`; `?? ''` string fallbacks mirroring the decode pattern; no Dart-side Verifier — mirrors `repo.dart`; `log_dir()` thin wrapper IS the AC-4 single-source-of-truth design; "infallible" + `catch` backstop is the intended shape per AC-7; `@singleton` memoizes the factory not the value per AC-8 "call on demand"; no `option_env!` fallback — `build.rs` already provides one); **generated-code noise** (`RepoHandle_VT_HANDLE` removal is the correct cbindgen exclude; `PayloadTypeId.fromValue` throw is flatc-generated); **test-thoroughness nits** (no `gitSha == 'unknown'` assertion; no empty/long/non-ASCII `ok_diagnostics` case; "tautological" tests in fact use the required `Verifier`); **platform-correct / trivial nits** (`startsWith('/')` is fine on the macOS-only target; `Uint8List.fromList` copy mirrors `repo.dart`; `Diagnostics` lacks `==`/`hashCode` — UI is out of scope; `ZanshinDiagnosticsModule` has no consumer yet — the UI call site is Ralph's out-of-scope work).
