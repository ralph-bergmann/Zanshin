# Coverage ratchet

Zanshin gates code coverage with a **ratchet**: per-file Rust line coverage may
never drop, but may rise. The goal is that no untested code is added — a change
that lowers a file's coverage (or adds a new, under-tested file) fails the gate.

It is **local-only** (no CI/CD; GitHub is code storage). The gate runs as part of
`cargo make test` and standalone via `cargo make coverage`.

Inside `cargo make test` the coverage step is also where the Rust test suites and
the `packages/zanshin_core` suite run (since 2026-10-17 there is no separate
`cargo test` / `dart test` step; `test-cargo-doc` keeps the doctests, which
cargo-llvm-cov skips). `cargo make test` runs it only when Rust,
`packages/zanshin_core`, test fixtures or root config changed since the last green
run (`cargo xtask gate-plan`); `cargo make test-full` always runs it.

## What is measured

Coverage here is **Rust-only**. It is the *union* of two separate measurements
(see `Makefile.toml [tasks.coverage]` and `crates/xtask/src/tasks/lcov_union.rs`):

1. **FFI-path** — the `zanshin-ffi` cdylib is rebuilt with LLVM source-based
   instrumentation (`-C instrument-coverage`) and exercised by the
   `packages/zanshin_core` `dart test` suite through the real worker isolate. This
   captures the Rust lines reached *across the FFI boundary*.
2. **cargo tests** — `cargo-llvm-cov` over the workspace test binaries (unit +
   integration), which captures everything the Rust test suites reach.

A source line counts as covered if it is covered in **either** measurement (max
hit count per line). The two halves are different instrumented binaries with
different function hashes, so they are unioned at the *source* level, not merged
as raw profiles.

> Dart-side line coverage is **not** measured by this gate. The heavy logic lives
> in Rust; the Dart layer is a thin bridge and the Flutter UI is out of scope.
> Adding Dart coverage would be a separate build step.

## How instrumentation is triggered

The Dart hooks-runner scrubs the build-hook environment, so a marker **file** is
the trigger: `cargo make coverage` writes `packages/zanshin_core/coverage.on`,
and `hook/build.dart` builds the cdylib with instrumentation while that file
exists. `build.dart` declares `coverage.on` as a build dependency, so toggling
the marker forces the hooks-runner to re-run the hook (otherwise a cached
non-instrumented dylib would be reused and the FFI path would measure nothing).
`packages/zanshin_core` resolves via a Dart pub **workspace** (`resolution: workspace` in its
`pubspec.yaml`), which hoists `.dart_tool` to the **workspace root** rather than nesting it
under the package. The instrumented cdylib lands at the repo root's
`.dart_tool/lib/libzanshin_ffi.dylib` (per the repo root's `.dart_tool/native_assets.yaml`) —
not `packages/zanshin_core/.dart_tool/...`. The marker is removed on exit and is git-ignored.

## The baseline

`coverage-baseline.txt` (repo root, **committed**) records the per-file floor.
Format is a small hand-rolled text file:

```
epsilon_pct = 0.10            # tolerance (percentage points) absorbing jitter
new_file_floor_pct = 80.00    # minimum coverage a brand-new file must reach
exclude_prefix = crates/xtask/        # build tooling — not product code
exclude_prefix = crates/test-helpers/ # test-only helper crate
crates/zanshin-ffi/src/repo.rs = 100.00
...
```

Scope is workspace source under `crates/`, minus the `exclude_prefix` entries.
Non-workspace paths (stdlib, the cargo registry) are dropped automatically.

The gate (`cargo xtask coverage-check`, run by `cargo make coverage`):

- **regression** — a tracked file dropping more than `epsilon_pct` below its
  baseline fails the run (exit 1).
- **new file** — a file not in the baseline must reach `new_file_floor_pct`, else
  it fails.
- **improvement** — a file rising more than `epsilon_pct` above its baseline
  **raises the baseline in place** (the ratchet only tightens). Commit the
  updated `coverage-baseline.txt` together with the code that earned it.
- **jitter** — a change within ±`epsilon_pct` neither fails nor rewrites the
  baseline.
- **removed file** — dropped from the baseline (not a failure).
- **first run** — if the baseline is missing it is *seeded* from the current
  measurement (no floor enforced); the ratchet tightens upward from there.

## Responding to a failure

```
REGRESSION  crates/zanshin-jj/src/repo.rs: 72.10% < baseline 80.40% (add tests or revert)
BELOW FLOOR crates/zanshin-jj/src/new_thing.rs: new file at 41.00% < required 80.00%
```

Add tests until coverage is back at or above the baseline. **Do not lower the
baseline to make the gate pass** — that defeats the ratchet. Lowering
`new_file_floor_pct` or adding an `exclude_prefix` is a deliberate, reviewed
change to `coverage-baseline.txt`, not a routine fix.

## Intentionally-uncovered code (the escape hatches)

Some code legitimately can't or shouldn't be covered. Put it where the ratchet
won't fail you — deliberately, never by lowering the floor:

- **Benchmarks → `benches/`.** Bench code is not run by `cargo make coverage` and
  is dropped by the scope filter, so it never counts. (Example:
  `crates/zanshin-jj/benches/graph_blueprint.rs`.) Do **not** put `#[ignore]`
  benchmarks inline in `src/` — they drag the file's coverage down, or in a new
  file trip the floor. (This is exactly why the graph blueprint lives in
  `benches/` and not in `repo.rs`.)
- **Test scaffolding → `tests/`.** Integration tests and test-only helpers under
  `tests/` are excluded by the scope filter.
- **Generated code** (`*_generated.rs`, `bindings.dart`, …) is excluded automatically.
- **Production code that genuinely can't be unit-tested** (a thin binary `main.rs`
  entrypoint, FFI glue exercised only via integration): add a deliberate, reviewed
  `exclude_prefix` to `coverage-baseline.txt`. That is a visible line in the diff,
  not a silent dodge — and it should be rare.

The floor never *blocks* low-coverage code; it forces you to choose one of the
above consciously instead of letting an untested file slip in unnoticed.

## Toolchain prerequisites

macOS + the rust-toolchain `llvm-tools` component + `cargo-llvm-cov`
(`brew install cargo-llvm-cov`). `cargo make coverage` checks for these and
prints install guidance if missing.

## Build-profile pitfall: keep full dev debug info on our own crates

`-C instrument-coverage`'s source-line attribution for **our own crates** depends
on their full DWARF debug info. Setting the *profile-level*
`[profile.dev] debug = "line-tables-only"` was verified by hand (2026-08-13) to
silently drop cargo-side line coverage on unchanged code
(`crates/zanshin-ffi/src/ffi_strings.rs`: 115/116 → 102/116), which the ratchet
then reports as a false regression. The root `Cargo.toml` therefore trims debug
info only for **dependencies** via `[profile.dev.package."*"]` — which excludes
workspace members by definition — and says so in its `# WHY:` comment. If the
ratchet ever regresses on a file you did not touch, check the profiles first.
