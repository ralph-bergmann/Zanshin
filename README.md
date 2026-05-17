# Zanshin

Zanshin is a macOS-native Flutter GUI for
the [Jujutsu (jj)](https://www.jj-vcs.dev/latest/) VCS, with a Rust backend
exposed via Dart Hooks + ffigen-generated FFI. macOS-only. Pre-1.0; WIP.

## Toolchain

All toolchains are installed system-wide. **No FVM, no per-project rustup
overrides.**

| Tool    | Pin                                    | Source-of-truth                                                          |
|---------|----------------------------------------|--------------------------------------------------------------------------|
| Rust    | `1.95.0`                               | `rust-toolchain.toml` (auto-applied by `rustup` on `cargo` invocation)   |
| Flutter | `main` channel, ≥ `3.44.0-1.0.pre-573` | `app/pubspec.yaml` → `environment.flutter`; this README is the human pin |
| Dart    | `main` channel, ≥ `3.13.0-104.0.dev`   | `app/pubspec.yaml` → `environment.sdk`; bundled with Flutter `main`      |

**Why these versions:**

- **Rust `1.95.0`** — pinned exactly to make CI and developer machines
  byte-equivalent
  in compiler output. Bumps are explicit PRs with a `# WHY:` rationale; the
  release-phase
  reproducibility CI (FR-BO-8) re-validates artefacts on every bump.
- **Flutter `main` channel** — the Flutter UI work (Ralph's separate scope, not
  in this
  repo) targets multi-window APIs that are not in any stable channel release.
  Stable
  pins are not viable until multi-window support ships on a stable Flutter.
  Revisit then.
- **Dart `main` channel** — bundled with Flutter `main`; tracks in lockstep. No
  independent Dart pin.

**One-time install (per machine):**

```sh
# Rust — rustup auto-installs 1.95.0 the first time you cd into the repo and run cargo,
# but you can pre-install:
rustup install 1.95.0
# https://rustup.rs

# Flutter main channel (manual; no FVM):
#   https://flutter.dev/docs/get-started/install
# Then switch to main and pin via:
flutter channel main
flutter upgrade

# cargo-make (used by Story 1.4+ build/test entry points):
cargo install cargo-make
```

**CI note:** GitHub Actions workflow (Story 1.9) reads `rust-toolchain.toml` via
`dtolnay/rust-toolchain@master` (or equivalent action that respects the file) —
no hardcoded Rust version in YAML. Flutter setup in CI uses
`subosito/flutter-action@v2` with `channel: 'master'` (the action's name for
Flutter's `main` channel) and the exact `flutter-version` from
`app/pubspec.yaml`.

## Build & development

`cargo-make` is the single entry point for all build, test, and codegen tasks.

### list all available tasks

```sh
cargo make           
```

### build Rust workspace (release) + Flutter macOS shell → unsigned .app

```sh 
cargo make build     
```

### run Flutter app in debug mode (Hot-Reload, local only)

```sh 
cargo make run       
```

### run Flutter app in release mode (local-optimized, no Hot-Reload)

```sh 
cargo make run-release  
```

### WIP quality gate: cargo test + clippy + fmt + flutter test + dart analyze + dart format + cargo deny

```sh 
cargo make test      
```

### regenerate FFI C header (cbindgen) and Dart bindings (ffigen)

```sh 
cargo make codegen  
```

### check for codegen drift against committed files (manual discipline tool)

```sh 
cargo make verify-codegen  
```

### remove all build outputs (cargo + flutter); committed codegen stays

```sh 
cargo make clean     
```

## How do I … ?

### How the build chains together

`app/hook/build.dart` is a Dart Hook that uses `native_toolchain_rust` to build
`crates/zanshin-ffi` (the cdylib) automatically whenever Flutter touches the app
— `flutter run`, `flutter build macos`, `flutter test` all trigger it.

**You don't need to run `cargo build` manually before `flutter run`.** The hook
handles it. The Rust workspace gets compiled in the same mode Flutter is in
(debug → debug, release → release).

`cargo make build` exists for the release path because it _also_ builds the
non-FFI Rust artefacts (e.g. the `zanshin-mcp` binary), which the Flutter hook
does not touch.

### How do I run the app locally (Hot-Reload)?

```sh
cargo make run
```

The Dart Hook compiles `zanshin-ffi` in debug mode and links it into the app
bundle. Change Rust code → stop the app → re-run. (Hot-Reload only covers Dart;
Rust changes need a re-run.)

### How do I run the app locally (release-optimized)?

```sh
cargo make run-release
```

Same as above but with `--release` on both sides. Useful when debugging
perceived performance issues — Rust debug builds can be orders of magnitude
slower than release.

### How do I build a release artefact (unsigned `.app`)?

```sh
cargo make build
```

Produces `app/build/macos/Build/Products/Release/Zanshin.app`. Recommended
to run `cargo make test` first so you don't ship a broken artefact.

**Note:** the `.app` is unsigned and unnotarized. Codesigning, notarization,
Sparkle auto-update and GitHub Releases automation are deferred to the release
phase (see `_bmad-output/planning-artifacts/prd.md` § 4.7). For local use the
unsigned bundle is fine; macOS will warn on first launch.

### How do I run the quality gate before pushing?

```sh
cargo make test
```

Runs the WIP-minimal gate: `cargo test --workspace`, `cargo clippy -D warnings`,
`cargo fmt --check`, `flutter test`, `dart analyze`, `dart format --check`,
`cargo deny check advisories bans`. Same checks as CI.

### How do I change an `extern "C"` function in `zanshin-ffi`?

1. Edit the Rust source.
2. Regenerate the bindings:
   ```sh
   cargo make codegen
   ```
3. Commit `crates/zanshin-ffi/include/zanshin_ffi.h` _and_
   `app/lib/src/ffi/bindings.dart` in the same PR as the Rust change.
4. Verify nothing drifted:
   ```sh
   cargo make verify-codegen
   ```

Generated code is **committed** and the build never auto-regenerates it. The
CI drift-gate is deferred while WIP — review enforces the discipline rule.

### How do I reset / start clean?

```sh
cargo make clean
```

Removes `target/` and `app/build/`. Committed codegen (`zanshin_ffi.h`,
`bindings.dart`) stays — those are source-of-truth artefacts, not build
outputs. If you _really_ want to reset codegen too, delete the files manually
and run `cargo make codegen`.

## Project documentation

See `_bmad-output/planning-artifacts/` for PRD + architecture + epics;
`_bmad-output/project-context.md` is the AI-agent rule set.
