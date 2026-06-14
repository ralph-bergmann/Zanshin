# Deferred Work

_Items raised during code reviews that are real but intentionally not actioned now. Each entry links back to the originating review and includes a one-line reason for deferral._

## Deferred from: code review of 1-1-initialize-cargo-workspace-and-create-empty-crate-skeletons (2026-05-17)

- **No `NOTICE` file alongside Apache-2.0 `LICENSE`** [`LICENSE`] — release phase; no downstream redistributors during WIP.
- ~~**No `[workspace.lints]` table for central lint enforcement** [`Cargo.toml`]~~ — RESOLVED 2026-06-13 (Story 1.7): `[workspace.lints.clippy] pedantic = { level = "warn", priority = -1 }` at workspace root, all six member crates opt in via `[lints] workspace = true`; replaces the per-crate `#![warn(clippy::pedantic)]` attribute form from the original epics AC.
- **No `[profile.release]` / `[profile.dev]` customization (LTO, codegen-units, strip)** [`Cargo.toml`] — release-phase optimization.

## Deferred from: code review of 1-2-initialize-flutter-macos-package-with-dart-hooks-wiring (2026-05-17)

- **`crates/zanshin-ffi/rust-toolchain.toml` symlink fragility** [`crates/zanshin-ffi/rust-toolchain.toml`] — symlink-on-Windows, broken-symlink, `cargo package` dereference behaviour all hypothetical for the macOS-only WIP scope; revisit if CI matrix expands or `cargo package` workflow lands.
- ~~**`app/.gitignore` has unused `android/`, `ios/`, `web/` stanzas from `flutter create` template**~~ — RESOLVED 2026-05-17 (Story 1.4 review cleanup): non-macOS platform stanzas removed; remaining lines are all macOS-applicable Flutter/Dart standard ignores.
- ~~**Story 1.2 doc internal inconsistency: AC-4 vs Dev Notes on `cratePath` resolution origin**~~ — RESOLVED 2026-05-17 (Story 1.4 review cleanup): AC-4 prose (line 51) now aligns with Dev Notes § "RustBuilder 1.0.4 API quick reference" — `cratePath` is resolved relative to the package root (`app/`, where `pubspec.yaml` lives).

## Deferred from: code review of 1-3-pin-rust-toolchain-and-document-flutter-dart-pins (2026-05-17)

- ~~**Stale Flutter/Dart pins in planning artefacts**~~ — RESOLVED 2026-05-17 (Story 1.4 review cleanup, deliberately overriding Story 1.3's "no planning-artefact edits from implementation stories" process rule): `architecture.md:76`, `architecture.md:161`, `epics.md:555`, `epics.md:625`, `epics.md:630`, `epics.md:643`, `epics.md:947` updated to current `main`-channel pins (Flutter ≥ `3.44.0-1.0.pre-573`, Dart ≥ `3.13.0-104.0.dev`). Research files under `_bmad-output/planning-artifacts/research/` deliberately NOT updated — they are frozen historical research snapshots from 2026-05-15.

## Deferred from: code review of 1-4-author-makefile-toml-with-build-test-codegen-targets (2026-05-17)

- ~~**cargo-deny advisory DB auto-download + advisory churn fragility** [`Makefile.toml:114-117`]~~ — RESOLVED 2026-05-18 (Story 1.6): `deny.toml` lands with the v2 schema (`[advisories]` + `[bans]` only — `[licenses]` deferred per WIP-rework); README documents the first-run ~30s download (`cargo deny fetch db` to pre-warm) and the ignore-list operating procedure; `unused-ignored-advisory = "warn"` makes stale ignores self-surface.
- **`cwd = "app"` is relative — breaks under `cargo make --makefile /abs/path X` from non-repo-root CWD** [`Makefile.toml:51,59,65,99,...`] — Ralph's normal workflow runs from repo root where this resolves correctly. Cross-invocation from arbitrary CWD is an edge case; anchor to `${CARGO_MAKE_WORKSPACE_WORKING_DIRECTORY}` later if it becomes a real workflow.
- ~~**User uncommitted edits to `zanshin_ffi.h` / `bindings.dart` silently overwritten by verify-codegen** [`Makefile.toml:142-168`]~~ — RESOLVED 2026-05-17 (Story 1.5): added `git diff --quiet HEAD --` precondition that exits 1 with a clear refusal message before the snapshot-restore loop runs. The discipline rule (never regenerate outside `cargo make codegen`) is now mechanically enforced for `verify-codegen` invocations on dirty trees.

## Deferred from: code review of 1-5-configure-cbindgen-and-ffigen-with-committed-outputs (2026-05-17)

- **`zanshin_ffi_version()` returns `*const c_char` to static literal; no `zanshin_string_free` pairing** [`crates/zanshin-ffi/src/lib.rs`] — Story 3.2 swaps to heap-allocated `*mut c_char` via `ffi_strings::string_to_cstring` with `zanshin_string_free` as the destructor — already documented as Story 3.2's scope per spec AC-2 prose.
- **No `catch_unwind` wrapper on `extern "C" fn zanshin_ffi_version()`** [`crates/zanshin-ffi/src/lib.rs`] — Placeholder body is panic-free (single `c"..."` literal). Epic 3 / Story 3.1 owns the envelope + panic-catch infrastructure (`handle.rs` panic-catch wrapper).
- **`c"0.1.0"` hardcoded literal vs `env!("CARGO_PKG_VERSION")`** [`crates/zanshin-ffi/src/lib.rs`] — Placeholder is replaced wholesale in Story 3.2 with a `build.rs` that injects `ZANSHIN_GIT_SHA` and a heap-allocated `<version> (<git-sha>)` string; not worth fixing in the placeholder.
- **No automated consistency check for `ffigen.yaml asset-id` ↔ `bindings.dart @DefaultAsset` ↔ `build.dart assetName` ↔ `pubspec.yaml name`** [`app/ffigen.yaml`, `app/lib/src/ffi/bindings.dart`, `app/hook/build.dart`, `app/pubspec.yaml`] — All four agree today (verified manually during review). An automated cross-check (e.g., a `cargo make` task or a Dart test) could land later if drift becomes a recurring problem.

## Deferred from: code review of 1-6-add-cargo-deny-advisories-bans-security-backstop (2026-05-18)

- ~~**Story Dev Notes wrongly include `transitive` as a valid `unmaintained` value** [`_bmad-output/implementation-artifacts/1-6-add-cargo-deny-advisories-bans-security-backstop.md:418`]~~ — DISMISSED 2026-05-18: review finding was a false positive. Empirically verified with cargo-deny 0.19.6 (`unmaintained = "bogus"` → `error[unexpected-value]: expected '["all", "workspace", "transitive", "none"]'`); all four values are valid in v2. Story Dev Notes were correct; no edit needed.
- ~~**Story Dev Notes' SPDX-precedent claim is factually wrong** [`_bmad-output/implementation-artifacts/1-6-add-cargo-deny-advisories-bans-security-backstop.md:394`]~~ — RESOLVED 2026-05-18: Story 1.6 now *establishes* the SPDX-on-TOML-configs convention rather than following a non-existent precedent. Added `# SPDX-License-Identifier: Apache-2.0` on line 1 of `Makefile.toml`, `rust-toolchain.toml`, and `cbindgen.toml` (retroactively to their owning stories); Dev Notes § "SPDX on TOML config files" rewritten to reflect this. Workspace TOML configs are now consistent.

## Deferred from: code review of 2-3-implement-repo-rs-open-init-clone (2026-06-14)

- **`open()` pre-check masks permission/IO errors as `PathNotFound` and mislabels a file-path or `.jj`-as-file as `NotARepo`** [`crates/zanshin-jj/src/repo.rs:64-70`] — `exists()`/`is_dir()` map IO errors to `false`, so the ACs as written are met; tighten the error taxonomy when the FFI error-code mapping lands (Epic 3).
- **Happy-path clone test asserts only `is_ok()` + re-open — no cloned-content/ref assertion; depends on `git` ≥ 2.28 on PATH** [`crates/zanshin-jj/tests/repo.rs:138-161`] — strengthen the assertion (verify a fetched ref/commit) when the working-copy update lands (Epic 6 Story 6.4a).
- **Untested clone/init boundaries: empty url, `file://` to missing/non-git dir, init/clone into already-initialized or missing-parent dir** [`crates/zanshin-jj/src/repo.rs:90-185`] — error classification for these is unverified; the AC-13 mandatory invalid-URL path is covered.
- **`copy_dir_all` test helper ignores symlinks and file permissions** [`crates/zanshin-jj/tests/repo.rs`] — latent; only bites if a fixture ever contains a symlink inside `.jj/`.
