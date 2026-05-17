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

## Project documentation

See `_bmad-output/planning-artifacts/` for PRD + architecture + epics;
`_bmad-output/project-context.md` is the AI-agent rule set.
