# Zanshin — agent guide

Zanshin is a macOS Flutter GUI for the Jujutsu (jj) VCS. This repo is the
**Rust workspace + FFI + MCP server + the pure-Dart bridge** (`packages/zanshin_core`)
+ a minimal Dart bootstrap. The **Flutter UI is out of scope** (separate work).

## Canonical rules

`_bmad-output/project-context.md` is the authoritative ruleset for implementing
code here (tech stack, FFI transport, error taxonomy, testing, anti-patterns).
**Read it before writing code.** When a rule there conflicts with an older doc,
project-context.md wins.

## The quality gate is the definition of done

`cargo make test` is the single local quality gate (there is no CI — GitHub is
code storage only). Run it — and make it pass — before considering any code
change complete. It runs: `cargo test` + clippy (pedantic, `-D warnings`) +
rustfmt + `flutter test` + `dart analyze`/`format` (app + `packages/zanshin_core`)
+ `cargo deny` + the **coverage ratchet**.

## Coverage ratchet (always check coverage after tests)

`cargo make test` ends with `cargo make coverage`, which gates **per-file Rust
line coverage** against the committed `coverage-baseline.txt`:

- Coverage may **rise but never drop**; a regression fails the gate. The fix is
  to **add tests**, never to lower the baseline.
- A **new** source file must reach the floor (default 80%).
- When coverage rises, the baseline is **raised automatically** — commit the
  updated `coverage-baseline.txt` together with the code that earned it.
- Coverage is **Rust-only** (the cdylib FFI path unioned with cargo tests);
  Dart-side lines are not measured.

Intentionally-uncovered code (benchmarks, test scaffolding) belongs in `benches/`
or `tests/` (out of scope), **not** inline in `src/`. Production code that truly
can't be unit-tested gets a deliberate, reviewed `exclude_prefix` in the baseline.

Details and knobs: `docs/coverage.md`. **Never lower the baseline or add an
`exclude_prefix` to dodge an untested file you could test** — that is a
review-blocking change.
