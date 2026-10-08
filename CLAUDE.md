# Zanshin — agent guide

Zanshin is a macOS Flutter GUI for the Jujutsu (jj) VCS. This repo is the
**Rust workspace + FFI + MCP server + the pure-Dart bridge** (`packages/zanshin_core`)
+ a minimal Dart bootstrap. The **Flutter UI is out of scope** (separate work).
Exception 2026-09-26 (Ralph): Epic 10, the commit-graph view (epics.md), is built
by Claude at Ralph's request; the rest of the Flutter UI stays Ralph's.

## Canonical rules

`_bmad-output/project-context.md` is the authoritative ruleset for implementing
code here (tech stack, FFI transport, error taxonomy, testing, anti-patterns).
**Read it before writing code.** When a rule there conflicts with an older doc,
project-context.md wins.

## jj source reference (local, read-only)

A checkout of the upstream **jj** monorepo lives at `../jj` (sibling of this repo).
It contains **both** crates: `../jj/lib/` (jj-lib) and `../jj/cli/` (the jj CLI) — plus,
since 0.45, `../jj/core/` (jj-core: `merge`, `backend`, `op_store`, `repo_path`, … which
jj-lib re-exports under their old paths). The
CLI (`cli/`, `cli_util`) is the high-value part — it is **not** a cargo dependency and
is the prior-art for the operation API (ADR-0003 / Epic 9). `../jj` already caught a
wrong jj-lib entry-point guess once.

**Replicate the CLI's _observable behavior_** (verbs, preconditions, refusals, op-log
effect, default resolution) — **not** its terminal UX (the GUI replaces the TUI/`$EDITOR`/
pager; interactive verbs take a GUI-supplied `TreeId`) — and pass CLI parameters through
rather than baking in defaults. See project-context.md § zanshin-jj for the canonical rules.

- **Read at the pinned tag, not the working tree:** `git -C ../jj show vX.Y.Z:<path>`
  (currently `v0.46.0`, matching the `jj-lib =0.46.0` pin in the root `Cargo.toml`) — e.g.
  `git -C ../jj show v0.46.0:lib/src/workspace.rs` or `:cli/src/commands/git/init.rs`.
  The working tree may sit on `main`, ahead of the pin — those APIs need not match what
  we build against. Bump the reference tag in lockstep when the `jj-lib` / `jj-cli` pin
  moves (the parity oracle, `crates/zanshin-parity`, runs the stock CLI at that pin; the
  pin-bump steps are in project-context.md § zanshin-jj).
- **jj-lib shortcut:** the same crate is also vendored version-exact at
  `~/.cargo/registry/src/*/jj-lib-<version>/src/…` (and `jj-core-<version>`) — literally the released code cargo
  compiles, so `Read` it directly (no `git show`, no tag-drift risk). Handy for library
  reads; the **CLI** exists *only* in `../jj`.
- **Optional convenience only** — the build never depends on `../jj`. If absent, fall
  back to the vendored crate + the jj source on GitHub at the tag.

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
