---
title: 'Fix-up after the story loop 9.40 9.16 — cargo deny advisory RUSTSEC-2026-0385 (ctutils)'
type: 'chore'
created: '2026-10-23'
status: 'done'
baseline_revision: 'b4d89bfcb1716f82eeab349eb6600ac9fbc6800a'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/docs/coverage.md'
warnings: []
deferred: []
---

<intent-contract>

## Intent

**Problem:** The loop's final `cargo make test` at b4d89bf fails in `cargo deny` (failure 1): advisory RUSTSEC-2026-0385 (non-constant-time mask generation / `u128` comparisons) hits `ctutils 0.4.3`, a transitive dependency of jj-lib (`jj-core 0.46.0 → blake2 0.11.0 → digest 0.11.3 → ctutils`); the fix is `>=0.4.4`. The coverage ratchet never ran, so the loop's new code (Stories 9.40, 9.16: `arrange.rs`, `parallelize.rs`, `zanshin-ffi/src/rebase.rs`, three new C exports) has not yet met it.

**Approach:** Bump `ctutils` in `Cargo.lock` with `cargo update -p ctutils` (resolves to 0.4.5, semver-compatible, lockfile-only — no manifest change). Then run the full gate; if the coverage ratchet reports a regression or a new file below the 80% floor, close each gap by adding tests at the reported file, and commit the gate-raised `coverage-baseline.txt` with the fix.

## Boundaries & Constraints

**Always:** Lockfile-only dependency change, exactly the `ctutils` entry; fix every further red step at its cause; a coverage gap is closed by tests (inline `#[cfg(test)]` for private items, `tests/it/` for integration, a `packages/zanshin_core` cdylib test per uncovered `extern fn`); commit the auto-raised baseline with the fix.

**Never:** No `deny.toml` ignore/exemption for the advisory, no `cargo update` of other packages, no `Cargo.toml` edits, no lowered baseline entry, no `exclude_prefix`, no production-behavior change.

</intent-contract>

## Code Map

- `Cargo.lock:601-604` -- `ctutils 0.4.3` entry; `cargo update -p ctutils --dry-run` → `v0.4.3 -> v0.4.5`, 1 package, nothing else moves.
- `deny.toml` -- advisories config; read-only (no ignore added).
- `coverage-baseline.txt` -- per-file floors; new files default 80%.
- `crates/zanshin-jj/src/arrange.rs`, `crates/zanshin-jj/src/parallelize.rs`, `crates/zanshin-ffi/src/rebase.rs` -- the loop's new files, first time under the ratchet; test locations if a gap is reported (zanshin-jj/zanshin-ffi integration tests live in the single binary `tests/it/main.rs`).
- `packages/zanshin_core/test/` -- cdylib tests; every new `extern fn` needs a hit here for the cross-FFI coverage union.

## Tasks & Acceptance

**Execution:**
- `Cargo.lock` -- `cargo update -p ctutils` -- clears RUSTSEC-2026-0385 at its cause.
- Gate-reported coverage gaps (only if `cargo make test` reports REGRESSION / BELOW FLOOR) -- add tests at the named file -- the ratchet's sanctioned fix.
- `coverage-baseline.txt` -- commit the gate's auto-raise -- ratchet rule.

**Acceptance Criteria:**
- Given the bumped lockfile, when `cargo deny check` runs, then advisories pass with no new ignore.
- Given the change, when `cargo make test` runs, then every step passes (coverage without REGRESSION / BELOW FLOOR), and the gate-stamp is written.

## Spec Change Log

## Review Triage Log

## Verification

**Commands:**
- `cargo deny check` -- expected: advisories ok, bans ok, licenses ok, sources ok
- `cargo make test` -- expected: exit 0

## Auto Run Result

Done 2026-10-23, commit cc5e816. `cargo update -p ctutils` moved only `ctutils` 0.4.3 → 0.4.5 in
`Cargo.lock`. The gate's own deny step (`cargo deny --workspace check advisories bans`): advisories
ok, bans ok. A bare `cargo deny check` reports `licenses FAILED` (461 rejections): `deny.toml`
has no `[licenses]` allow-list yet (deferred to the release phase) and says to run only
`advisories bans`, so the Verification line's "licenses ok" was a spec slip, not a regression. The full
`cargo make test` (every step planned: lockfile is a root manifest) exited 0 and wrote the
gate-stamp. The ratchet reported no REGRESSION / BELOW FLOOR; new files `zanshin-ffi/src/rebase.rs`
100.00%, `zanshin-jj/src/arrange.rs` 99.50%, `zanshin-jj/src/parallelize.rs` 95.95%;
extern-coverage OK. No tests needed; the auto-raised `coverage-baseline.txt` is committed with the bump.
