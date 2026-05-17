# Deferred Work

_Items raised during code reviews that are real but intentionally not actioned now. Each entry links back to the originating review and includes a one-line reason for deferral._

## Deferred from: code review of 1-1-initialize-cargo-workspace-and-create-empty-crate-skeletons (2026-05-17)

- **No `NOTICE` file alongside Apache-2.0 `LICENSE`** [`LICENSE`] — release phase; no downstream redistributors during WIP.
- **No `[workspace.lints]` table for central lint enforcement** [`Cargo.toml`] — owned by Story 1.7 (lint/format config).
- **No `[profile.release]` / `[profile.dev]` customization (LTO, codegen-units, strip)** [`Cargo.toml`] — release-phase optimization.

## Deferred from: code review of 1-2-initialize-flutter-macos-package-with-dart-hooks-wiring (2026-05-17)

- **`crates/zanshin-ffi/rust-toolchain.toml` symlink fragility** [`crates/zanshin-ffi/rust-toolchain.toml`] — symlink-on-Windows, broken-symlink, `cargo package` dereference behaviour all hypothetical for the macOS-only WIP scope; revisit if CI matrix expands or `cargo package` workflow lands.
- ~~**`app/.gitignore` has unused `android/`, `ios/`, `web/` stanzas from `flutter create` template**~~ — RESOLVED 2026-05-17 (Story 1.4 review cleanup): non-macOS platform stanzas removed; remaining lines are all macOS-applicable Flutter/Dart standard ignores.
- ~~**Story 1.2 doc internal inconsistency: AC-4 vs Dev Notes on `cratePath` resolution origin**~~ — RESOLVED 2026-05-17 (Story 1.4 review cleanup): AC-4 prose (line 51) now aligns with Dev Notes § "RustBuilder 1.0.4 API quick reference" — `cratePath` is resolved relative to the package root (`app/`, where `pubspec.yaml` lives).

## Deferred from: code review of 1-3-pin-rust-toolchain-and-document-flutter-dart-pins (2026-05-17)

- ~~**Stale Flutter/Dart pins in planning artefacts**~~ — RESOLVED 2026-05-17 (Story 1.4 review cleanup, deliberately overriding Story 1.3's "no planning-artefact edits from implementation stories" process rule): `architecture.md:76`, `architecture.md:161`, `epics.md:555`, `epics.md:625`, `epics.md:630`, `epics.md:643`, `epics.md:947` updated to current `main`-channel pins (Flutter ≥ `3.44.0-1.0.pre-573`, Dart ≥ `3.13.0-104.0.dev`). Research files under `_bmad-output/planning-artifacts/research/` deliberately NOT updated — they are frozen historical research snapshots from 2026-05-15.

## Deferred from: code review of 1-4-author-makefile-toml-with-build-test-codegen-targets (2026-05-17)

- **cargo-deny advisory DB auto-download + advisory churn fragility** [`Makefile.toml:114-117`] — `cargo deny check advisories bans` does network I/O on first run (advisory DB sync) and will hard-fail when a transitive dep gets a published RUSTSEC advisory until ignored in `deny.toml`. Owned by Story 1.6 (`deny.toml` + ignore list).
- **`cwd = "app"` is relative — breaks under `cargo make --makefile /abs/path X` from non-repo-root CWD** [`Makefile.toml:51,59,65,99,...`] — Ralph's normal workflow runs from repo root where this resolves correctly. Cross-invocation from arbitrary CWD is an edge case; anchor to `${CARGO_MAKE_WORKSPACE_WORKING_DIRECTORY}` later if it becomes a real workflow.
- ~~**User uncommitted edits to `zanshin_ffi.h` / `bindings.dart` silently overwritten by verify-codegen** [`Makefile.toml:142-168`]~~ — RESOLVED 2026-05-17 (Story 1.5): added `git diff --quiet HEAD --` precondition that exits 1 with a clear refusal message before the snapshot-restore loop runs. The discipline rule (never regenerate outside `cargo make codegen`) is now mechanically enforced for `verify-codegen` invocations on dirty trees.
