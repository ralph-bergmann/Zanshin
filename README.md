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
| `flatc` | `25.12.19`                             | `docs/development-setup.md`; FlatBuffers FFI-wire compiler (ADR-0001)    |

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
- **`flatc 25.12.19`** — the FlatBuffers compiler that generates the Rust and
  Dart FFI-wire accessors (ADR-0001). It must stay on the same `25.x` line as
  the `flatbuffers` crate (`=25.12.19`) and the `flat_buffers` Dart package
  (`^25.9.23`); move all three together. See `docs/development-setup.md`.

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

# Mandatory: the app creates every window from Dart, so without this flag it
# builds but comes up with no window. Machine-global, compiled into the app.
flutter config --enable-windowing

# cargo-make (used by Story 1.4+ build/test entry points):
cargo install cargo-make

# FlatBuffers compiler — generates the Rust + Dart FFI-wire accessors (ADR-0001).
# Keep it on the same 25.x line as the flatbuffers crate + flat_buffers package:
brew install flatbuffers
flatc --version   # must print 25.12.19

# Codegen tools for the C header (cbindgen) and Dart FFI bindings (ffigen):
cargo install cbindgen
dart pub global activate ffigen
```

See `docs/development-setup.md` for the full prerequisites and version-pin table.

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

### WIP quality gate: cargo test + clippy + fmt + flutter test + dart analyze + dart format + cargo deny + cargo hygiene

```sh
cargo make test
```

### regenerate FlatBuffers accessors (flatc) + FFI C header (cbindgen) + Dart bindings (ffigen)

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
`cargo deny check advisories bans`, and a `Cargo.toml` hygiene check (every
`default-features = false` needs an inline `# WHY:`). Same checks as CI.

### The FFI wire format (ADR-0001)

Data crossing the Rust ↔ Dart boundary is shaped by its **type**, not by a
one-size envelope:

- **fixed scalar** (`int` / `bool` / `float`) → plain C value;
- **lone string** → `*mut c_char` (a `CString`; Dart frees it with
  `zanshin_string_free`);
- **composite** (table / list / nested) → a single **FlatBuffers** buffer; Dart
  releases it with `zanshin_buffer_free(ptr, len)` or, for the GC-backed
  `FfiBuffer` wrapper, the equivalent `zanshin_buffer_free_token`.

The wire schemas live in [`schemas/*.fbs`](schemas/README.md) and are the
source of truth. `flatc` generates the typed Rust and Dart accessors from them;
those accessors — like the C header and Dart bindings — are **committed** and
the build never regenerates them. (The only JSON in the project is
`zanshin-mcp`'s protocol-mandated JSON-RPC, a different boundary.) Full
rationale: [ADR-0001](docs/adr/0001-ffi-data-transport-flatbuffers.md).

### How do I change an `extern "C"` function in `zanshin-ffi`?

1. Edit the Rust source.
2. Regenerate: `cargo make codegen`.
3. Commit `crates/zanshin-ffi/include/zanshin_ffi.h` _and_
   `app/lib/src/ffi/bindings.dart` in the same PR as the Rust change.
4. Verify nothing drifted: `cargo make verify-codegen`.

### How do I change a wire schema (`.fbs`)?

1. Edit the `.fbs` in `schemas/`. (WIP: breaking changes are in-place edits — no
   `_v2` suffix, no in-wire `schema_version` field; update all callers in the
   same PR.)
2. Regenerate both sides: `cargo make codegen`. This runs `flatc --rust` +
   `flatc --dart` (normalising the output with `rustfmt` / `dart format`), then
   `cbindgen` + `ffigen`.
3. Commit the schema diff **and** the regenerated accessors
   (`crates/zanshin-ffi/src/*_generated.rs`,
   `app/lib/src/ffi/*.ffi_generated.dart`) in the same PR. The typed accessors
   turn a wrong-shape payload into a compile error, so update every caller.

Generated code is **committed** and the build never auto-regenerates it. The CI
drift-gate (`verify-codegen`) is deferred while WIP — review enforces the
discipline rule.

### How do I reset / start clean?

```sh
cargo make clean
```

Removes `target/` and `app/build/`. Committed codegen (`zanshin_ffi.h`,
`bindings.dart`, the `flatc` accessors) stays — those are source-of-truth
artefacts, not build outputs. If you _really_ want to reset codegen too, delete
the files manually and run `cargo make codegen`.

## Dependency security — cargo-deny

`cargo make test` runs `cargo deny --workspace check advisories bans` as
the security backstop. The full license-gate (`cargo deny check licenses`)
and Dart-side `pana` integration are deferred to the release phase
(see `_bmad-output/planning-artifacts/prd.md` § 5.4).

### First-run advisory database download

On a fresh machine (and on CI cache misses), the first invocation
fetches `https://github.com/rustsec/advisory-db` into
`~/.cargo/advisory-dbs/`. This is a one-time ~30–60s download.
Subsequent runs are local-only and finish in under 5s on this workspace.

To pre-warm the database without running the full check:

    cargo deny fetch db

### Advisory ignore-list workflow

When a published RUSTSEC advisory fires on a transitive dependency,
the response is **not** to ignore it silently. The procedure:

1. Investigate whether the advisory is exploitable in Zanshin's actual
   use of the affected dep.
2. Try `cargo update -p <crate>` to pick up a fixed version.
3. If neither resolves it, add an entry to `[advisories.ignore]` in
   `deny.toml` with an `id`, a non-empty `reason`, and a comment
   linking the upstream tracking issue.
4. The `unused-ignored-advisory = "warn"` setting surfaces stale
   ignores automatically — when the warn fires (advisory withdrawn,
   or dep upgraded away), drop the entry.

See `deny.toml` for the live config; every key carries an inline
comment explaining its choice.

## Project documentation

- `docs/development-setup.md` — full toolchain prerequisites (incl. `flatc`) + install commands
- `docs/adr/0001-ffi-data-transport-flatbuffers.md` — the FFI transport decision (FlatBuffers)
- `schemas/README.md` — FlatBuffers wire-contract schemas + regeneration discipline
- `_bmad-output/planning-artifacts/` — PRD + architecture + epics
- `_bmad-output/project-context.md` — the AI-agent rule set
