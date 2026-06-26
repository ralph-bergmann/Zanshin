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

**Test placement.** Rust **unit tests** for a module's private items go **inline**
(`#[cfg(test)] mod tests` at the bottom of that `src/` module) — they run and **do**
count toward coverage. **Integration tests** (need a real repo fixture, or exercise
only the public API) go in the crate's `tests/` directory. **Intentionally-uncovered,
non-running scaffolding** (benchmarks, perf harnesses) goes in `benches/` (or `tests/`)
and **never** inline in `src/`, where dead/ignored code drags per-file coverage.
Moving a *running* unit test out of `src/` gains nothing for coverage — never do it to
dodge the ratchet. Production code that truly can't be unit-tested gets a deliberate,
reviewed `exclude_prefix` in the baseline.

Details and knobs: `docs/coverage.md`. **Never lower the baseline or add an
`exclude_prefix` to dodge an untested file you could test** — that is a
review-blocking change.


## Think Before Coding

**Don't assume. Don't hide confusion. Surface tradeoffs.**

Before implementing:
- State your assumptions explicitly. If uncertain, ask.
- If multiple interpretations exist, present them - don't pick silently.
- If a simpler approach exists, say so. Push back when warranted.
- If something is unclear, stop. Name what's confusing. Ask.

## Simplicity First

**Minimum code that solves the problem. Nothing speculative.**

- No features beyond what was asked.
- No abstractions for single-use code.
- No "flexibility" or "configurability" that wasn't requested.
- No error handling for impossible scenarios.
- If you write 200 lines and it could be 50, rewrite it.

Ask yourself: "Would a senior engineer say this is overcomplicated?" If yes, simplify.

## Surgical Changes

**Touch only what you must. Clean up only your own mess.**

When editing existing code:
- Don't "improve" adjacent code, comments, or formatting.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- If you notice unrelated dead code, mention it - don't delete it.

When your changes create orphans:
- Remove imports/variables/functions that YOUR changes made unused.
- Don't remove pre-existing dead code unless asked.

The test: Every changed line should trace directly to the user's request.
