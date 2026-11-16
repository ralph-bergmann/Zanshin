---
title: 'Story-loop 9.60 11.28 fix-up: config.rs coverage regression (builtin layer parse error closure)'
type: 'chore'
created: '2026-11-16'
status: 'done'
baseline_revision: 'd833af6902fc76a7af8660a36bea2fa19c3faae3'
review_loop_iteration: 0
followup_review_recommended: false
context: []
warnings: []
deferred:
  - summary: >-
      `write_error`'s doc says the `set_value`/`delete_value` instantiation cannot fail because those calls only fail on a non-inline TABLE target, but jj-lib also fails `set_value` when a parent key holds a non-table value.
    evidence: |-
      jj-lib 0.47.0 `src/config.rs:432-440`: the parent walk of `ConfigLayer::set_value` returns `ConfigUpdateError::WouldOverwriteValue` when a parent key is not a table. The `as_str()` check of the two remote writers looks only at the target value, and `set_value` is also called from `env_layer` (config.rs:671) and `write_repo_presets` (config.rs:2436-2450). So the doc's reason is incomplete, and with a malformed repo config (e.g. `remotes.origin = "x"`) the `ConfigUpdateError` instantiation may be reachable. Coverage is unaffected (one shared body). Pre-existing: this run only changed the count and added the builtin parse clause. Settled by a test that writes a remote setting into a repo config whose `remotes.<name>` is a string, then correcting the doc (and adding the test) if it refuses.
    location: >-
      crates/zanshin-jj/src/config.rs:2233-2242
    severity: low
    resolved: >-
      2026-11-16 — fixed (spec-loop-9-60-11-28-leftovers, commit ca4886a4): doc corrected; a kept unit
      test pins the presets writer's refusal on a string `remotes.origin`.
---

<intent-contract>

## Intent

**Problem:** The loop's final `cargo make test` failed the coverage ratchet: `crates/zanshin-jj/src/config.rs` 99.84% < baseline 100.00%. The three uncovered lines (971-973) are the body of the `map_err` closure on `ConfigLayer::parse(ConfigSource::Default, BUILTIN_CONFIG_TOML)` in `load_raw`. Story 9.60 (23dba0c4) added `hints: Vec::new()` to `ConfigError::Load`, and rustfmt split the closure's struct literal onto its own lines. The closure only runs if the compiled-in constant fails to parse, which no test can make happen.

**Approach:** Replace the closure with the existing shared helper `write_error` (`.map_err(write_error)?`). It builds the same `ConfigError::Load { reason: describe(&err), hints: Vec::new() }` and exists for exactly this case: one shared body so unreachable call sites add no lines. Extend its doc comment to name this call site.

## Boundaries & Constraints

**Always:** The error value stays identical (same `reason` text through `describe`, empty `hints`). Every existing test expectation stays unchanged. `builtin_config_layer_is_valid_toml` keeps pinning that the constant parses.

**Never:** Touch `coverage-baseline.txt`, add an `exclude_prefix`, run the full gate (`cargo make test` / `test-full` / `coverage`), refactor `load_raw` beyond this line, or rename `write_error`.

</intent-contract>

## Code Map

- `crates/zanshin-jj/src/config.rs:970-973` -- `load_raw`: the builtin layer parse; the closure body 971-973 has 0 hits.
- `crates/zanshin-jj/src/config.rs:2234-2249` -- `write_error<E: std::error::Error + 'static>(err: E) -> ConfigError`: the shared body; its doc explains the "unreachable call sites share one body" pattern. Already used outside writes (`getrandom::fill` at line 899).
- `crates/zanshin-jj/src/config.rs:328` -- `describe`, the `source()`-chain renderer both forms use.
- `crates/zanshin-jj/src/config.rs:2638-2642` -- `builtin_config_layer_is_valid_toml`, the test that pins the constant parses.

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/src/config.rs` -- in `load_raw`, change the builtin parse to `ConfigLayer::parse(ConfigSource::Default, BUILTIN_CONFIG_TOML).map_err(write_error)?` on one line -- removes the three unexecutable lines without changing the error.
- `crates/zanshin-jj/src/config.rs` -- extend `write_error`'s doc comment so it names the builtin layer parse as another unreachable instantiation -- keeps the helper's documented purpose accurate.

**Acceptance Criteria:**
- Given the fix, when `load_raw` runs in any existing test, then the builtin parse line is executed and no line of the parse statement is left without a hit.
- Given the fix, when `cargo test -p zanshin-jj`, `cargo clippy -p zanshin-jj --all-targets -- -D warnings` and `cargo fmt --all --check` run, then all pass with no test expectation changed.

## Spec Change Log

## Review Triage Log

### 2026-11-16 — Review pass
- verdicts: 12 findings — high 0, medium 0, low 6, false 6, maybe-false 0
- findings:
  - (verification-gap layer: no gaps)
  - `[low]` `[patch]` (edge) `write_error`'s summary still says "A failure while WRITING the repo config", but the builtin parse is not a write — summary reworded to "A repo-config write failure, or one that cannot happen, rendered via its `source()` chain."
  - `[false]` `[reject]` (intent) Method diverges from "fixed by adding tests": no test added — the lines ran only if a compile-time constant failed to parse; a test could reach them only by changing production code to take another constant, against "change only what a failure needs". The unexecutable lines are removed, not hidden; baseline and `exclude_prefix` untouched.
  - `[false]` `[reject]` (intent) Coverage of the parse statement unmeasured — measured: after `cargo llvm-cov clean --workspace`, `cargo llvm-cov -p zanshin-jj --lib -- config::` gives config.rs line 970 79 hits, 971 79, no `DA` for the blank 972, and the `write_error` body 3 hits each.
  - `[low]` `[patch]` (intent) Helper name/summary say "write" for a read path — same root cause as the edge row; same patch.
  - `[low]` `[patch]` (intent) Odd line break in the edited doc paragraph — paragraph reflowed, wording unchanged.
  - `[false]` `[reject]` (intent) Commit, Auto Run Result and recorded checks missing — written at finalize, in this run's commits.
  - `[low]` `[patch]` (blind) Doc summary line still says "WRITING" — same root cause as the edge row; same patch.
  - `[false]` `[reject]` (blind) `load_raw`'s `# Errors` promises "the path is named", which the builtin parse error breaks — the builtin parse cannot fail (constant pinned by `builtin_config_layer_is_valid_toml`), so no caller ever sees that error; unchanged from before this run.
  - `[low]` `[defer]` (blind) The doc's premise that `set_value`/`delete_value` only fail on a non-inline TABLE target is incomplete (jj-lib `WouldOverwriteValue` on a non-table parent) — verified in jj-lib 0.47.0 `src/config.rs:432-440`; pre-existing text this run did not write. Deferred and mirrored into deferred-work.md.
  - `[low]` `[patch]` (blind) Ragged line in the rewrapped doc — same root cause as the intent reflow row; same patch.
  - `[false]` `[reject]` (blind) No evidence that coverage is back — measured, see the intent row above.
  - `[false]` `[reject]` (blind) The test is named in plain text and could go stale — the named test exists today; a private `#[cfg(test)]` fn cannot be an intra-doc link, and a rename is found by searching the name.

## Auto Run Result

Status: done

- **Failure 1 (coverage: config.rs 99.84% < 100.00%)** — fixed in dc9f5aec5ba259f83ab4795dc5b7cd7500eefcdd: the builtin layer parse in `load_raw` now maps its error with `.map_err(write_error)?` on one line, so the three closure lines that ran only on a malformed compiled-in constant are gone. The error value is unchanged (`ConfigError::Load { reason: describe(&err), hints: Vec::new() }`). `write_error` is the house helper for call sites that cannot fail; its doc now names this call site. No test was added: no test can make a compile-time constant fail to parse without changing production code. The `creation.rs` rise is not a failure; the ratchet raises the baseline itself.
- Files: `crates/zanshin-jj/src/config.rs` (parse line, `write_error` doc); this spec; `deferred-work.md` (one section).
- Review: 2 low patches applied (summary line of `write_error` no longer says "WRITING" only; doc paragraph reflowed). 1 low deferred (the doc's pre-existing premise about `set_value` failures is incomplete; mirrored in deferred-work.md). 6 false rejected (see the triage log). Follow-up review recommended: false (patched: high 0, medium 0, low 2).
- Verification (no full gate, per the run's rule):
  - `cargo test -p zanshin-jj` (before the doc patch): unit 459 passed, integration 1572 passed / 1 ignored, doctests 0. After the doc-only patch: `cargo test -p zanshin-jj --lib` 459 passed.
  - `cargo clippy -p zanshin-jj --all-targets -- -D warnings`: clean. `cargo fmt --all --check`: clean (both after the patch).
  - `cargo llvm-cov clean --workspace`, then `cargo llvm-cov -p zanshin-jj --lib --lcov -- config::` to a scratch file: config.rs line 970 (the parse) 79 hits, 971 79, no `DA` for the blank 972, `write_error` body 3 hits per line. A first run without the clean merged a stale object and showed 0 hits on 972-973.
  - `coverage-baseline.txt` untouched.
- Residual risk: the gate unions this with the FFI half; if that half was built before this fix, it may still carry the old line mapping until it is rebuilt.

## Verification

**Commands:**
- `cargo test -p zanshin-jj` -- expected: all pass
- `cargo clippy -p zanshin-jj --all-targets -- -D warnings` -- expected: clean
- `cargo fmt --all --check` -- expected: clean
