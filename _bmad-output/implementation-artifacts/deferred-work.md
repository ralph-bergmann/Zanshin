# Deferred Work

_Items raised during code reviews that are real but intentionally not actioned now. Each entry links back to the originating review and includes a one-line reason for deferral._

## Deferred from: code review of 1-1-initialize-cargo-workspace-and-create-empty-crate-skeletons (2026-05-17)

- **No `NOTICE` file alongside Apache-2.0 `LICENSE`** [`LICENSE`] — release phase; no downstream redistributors during WIP.
- **No `[workspace.lints]` table for central lint enforcement** [`Cargo.toml`] — owned by Story 1.7 (lint/format config).
- **No `[profile.release]` / `[profile.dev]` customization (LTO, codegen-units, strip)** [`Cargo.toml`] — release-phase optimization.
- **`xtask` not excluded from default-members** [`Cargo.toml:3-5`] — `cargo build --workspace --release` builds xtask unnecessarily; ergonomic; revisit when Story 1.4/1.9 wires CI.

## Deferred from: code review of 1-2-initialize-flutter-macos-package-with-dart-hooks-wiring (2026-05-17)

- **`crates/zanshin-ffi/rust-toolchain.toml` symlink fragility** [`crates/zanshin-ffi/rust-toolchain.toml`] — symlink-on-Windows, broken-symlink, `cargo package` dereference behaviour all hypothetical for the macOS-only WIP scope; revisit if CI matrix expands or `cargo package` workflow lands.
- **`app/.gitignore` has unused `android/`, `ios/`, `web/` stanzas from `flutter create` template** [`app/.gitignore`] — cosmetic; macOS-only scope is enforced at `pubspec.yaml` platform level, the dead lines are inert.
- **Story 1.2 doc internal inconsistency: AC-4 vs Dev Notes on `cratePath` resolution origin** [`_bmad-output/implementation-artifacts/1-2-initialize-flutter-macos-package-with-dart-hooks-wiring.md`] — documentation only; AC-4 says "from `app/hook/`", Dev Notes § "RustBuilder 1.0.4 API quick reference" says "from package root (`app/`)". Path works for current layout either way; clean up in a doc pass.

## Deferred from: code review of 1-3-pin-rust-toolchain-and-document-flutter-dart-pins (2026-05-17)

- **Stale Flutter/Dart pins in planning artefacts** [`_bmad-output/planning-artifacts/architecture.md:76`, `_bmad-output/planning-artifacts/epics.md:625`] — both still list Flutter `3.41.9` / Dart `3.11.5` (stable). README + project-context.md + `app/pubspec.yaml` are now the live source-of-truth for `main`-channel pins. Story 1.3 § "Conflict raised + resolved" defers the planning-doc refresh to a separate doc pass (planning artefacts are not edited from implementation stories).
