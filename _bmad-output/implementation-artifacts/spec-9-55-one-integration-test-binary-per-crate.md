---
title: 'Story 9.55 — One integration-test binary per crate'
type: 'chore'
created: '2026-10-20'
status: 'done'
baseline_revision: 'bb62aca89958acbe2b86fda8fadfcc1bb427084d'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-9-context.md'
warnings: ['oversized']
deferred:
  - summary: >-
      The three places that state the new test-environment rule disagree on who must pin:
      CLAUDE.md says every test that does not use `own_process!` calls `pin_test_env()`, while
      project-context.md and both `tests/it/main.rs` docs say only tests that read the environment
      through jj.
    evidence: |-
      CLAUDE.md test-placement paragraph ("every other test pins it with test_helpers::pin_test_env()")
      vs _bmad-output/project-context.md Test layout and crates/zanshin-{jj,ffi}/tests/it/main.rs
      ("called first by every test that reads the environment through jj"); detect, find_repo_root,
      api_stability and ffi_abi_doc_sync do not pin. Written by this story; the fix edits an
      agent-context file, so it is deferred rather than patched.
    location: >-
      CLAUDE.md (Test placement paragraph)
    severity: low
  - summary: >-
      The `.claude/skills/story-loop/SKILL.md` gate-rule sentence this story amended reads
      ambiguously ("`zanshin-jj`/`zanshin-ffi` have one, `--test it <module>::`").
    evidence: |-
      .claude/skills/story-loop/SKILL.md:79 — the edit (outside the spec's file list) means "each of
      the two crates has a single integration-test target `it`, filtered by module path", but does
      not say so. Agent-context file, so deferred rather than patched.
    location: >-
      .claude/skills/story-loop/SKILL.md:79
    severity: low
---

<intent-contract>

## Intent

**Problem:** Every `crates/zanshin-jj/tests/*.rs` (56) and `crates/zanshin-ffi/tests/*.rs` (29) file is its own test binary that links jj-lib + jj-cli, so `target/debug/deps` and `target/llvm-cov-target` hold ~170 executables of 60–80 MB each (12 GB in `target/debug/deps` measured 2026-10-20) plus their link time on every gate. The files rely on being alone in their process: 40-odd once-per-binary env pins each point `$XDG_CONFIG_HOME` at a different dir, a dozen files mutate the environment per test without restoring it, two install a write-once process environment (`adopt_environment`), three guard the single FFI event sink with three different mutexes, and two re-run the test binary with module-less name filters.

**Approach:** One binary per crate: `tests/it/main.rs` declaring one module per former file (`git mv`, names kept). The process environment is pinned once by ONE shared lock in `test-helpers` (`pin_test_env`, also returning the pinned `$XDG_CONFIG_HOME`); every test that must change the environment, adopt an environment, or own the event sink re-runs itself as the only test of a child process of the same binary (a new `test-helpers` helper generalising `clone_init.rs`'s existing pattern), so the shared process environment never changes after the pin. Everything that names a test file follows.

## Boundaries & Constraints

**Always:**
- Per crate, `cargo test -p <crate> --tests -- --list` lists the same number of tests before and after (record both counts per crate in the spec's Auto Run Result).
- Test bodies and assertions are unchanged except: the env-pin call (shared helper instead of the module's own `ENV_GUARD`), the one-line own-process prologue, child-process filter strings gaining the module prefix, and path strings in comments.
- After the pin, no test mutates the parent process environment; a test that did (`set_var`/`remove_var`/`adopt_environment` per test, or a module pin that sets other variables or values than the shared one) runs in its own child process.
- The child process inherits the pinned environment: the helper calls `pin_test_env()` before spawning, so a child's starting environment is deterministic.
- `coverage-baseline.txt` is never lowered and gets no new `exclude_prefix`; an auto-raise is committed.
- `zanshin-parity` (oracle + `driver_pins_env`, which needs its own process) and `test-helpers`' own test stay as they are.
- `git mv` for every moved file, so history follows.

**Never:**
- No `[[test]]`/`harness = false` entries, no `serial_test`-style new dependency, no `--test-threads=1` for the whole binary.
- No change to any production `src/` code beyond doc comments naming test paths.
- Never parallelise or touch the `zanshin_core` Dart suite (branch `claude/distracted-greider-3e8ed3`); never edit historical specs under `_bmad-output/` to rename paths.
- No `#[ignore]`/skips to get the merged binary green.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Own-process test, parent run | `cargo test` runs `config_identity::x` normally | parent spawns `current_exe() config_identity::x --exact --nocapture --test-threads=1` with the marker variable = that full name, asserts exit success and `1 passed` in stdout, returns | on failure the assertion message carries the child's stdout and stderr |
| Own-process test, child run | marker variable equals this test's full name | the body runs as before and may mutate the environment freely | — |
| Wrong name passed to the helper | literal does not match the libtest name | child prints `0 passed` → parent fails deterministically | never a silent pass |
| `clone_init` / `network_cancel` re-runs | filters `<name>` / `sleeper_child` | filters become `clone_init::<name>` / `network_cancel::sleeper_child` | — |
| Module first touched mid-run | another module's tests already running | no env change visible to them (the pin happens once, through one `LazyLock`) | — |

</intent-contract>

## Code Map

- `crates/test-helpers/src/lib.rs` -- `TEST_ENV` :67-82, `leaked_xdg_config_home` :94, `pin_test_env` :106-118 (the ONE pin: make it return `&'static Path` = the pinned XDG dir; docs :84-105 say "integration-test binaries keep their own ENV_GUARDs" → rewrite), add the own-process helper next to it. Existing callers: zanshin-jj inline tests, `clone_init.rs`, `network_cancel.rs`, `push.rs`, `push_remotes.rs`, `push_ffi.rs` (ignore the return value).
- `crates/zanshin-jj/tests/*.rs`, `crates/zanshin-ffi/tests/*.rs` -- move to `tests/it/`. No file has inner attributes, `mod`, `#[path]`, `include_*!`, `macro_rules!`, `fn main` or `file!()`; all start with `//!` docs (fine as module docs). Only `env!` is `ffi_abi_doc_sync.rs:43` (`CARGO_MANIFEST_DIR`, root-relative reads — unaffected).
- **Shared-pin modules (replace the module's `static ENV_GUARD`/`pin_env` body with `test_helpers::pin_test_env()`; a module whose guard returned the XDG `PathBuf` uses the returned path):**
  - jj, `TEST_ENV`/6-var + leaked XDG: `commit` :24, `new_insert` :23, `snapshot_colocated` :31, `snapshot_precondition` :30, `squash_split` :22, `templates` :29, `warnings` :32, `workspace_add` :24, `workspace_update_stale` :28, `bookmark_ops` :31, `commit_contents` :18, `commit_views` :42, `config` :22, `content_ops` :36, `file_reads` :38, `graph` :27, `graph_topology` :25, `op_support` :29, `remotes_write` :22, `revset` :16, `git_sync` :29, `op_workspace_name` :51; XDG-returning: `convert` :28-52 (uses at :1017, :1236-1340), `git_remotes` :39-57 (:942-946), `secure_config_fixups` :26-40 (:77, :82).
  - jj identity-only guards (now also get the shared XDG): `bookmarks` :21, `change` :21, `concurrent_writes` :32, `mutate` :15, `op_log` :22, `remotes` :16, `repo` :15, `status` :17, `view` :23, `workspace` :29.
  - ffi: `bookmark_ops_ffi` :36, `commit_contents_ffi` :29, `commit_ffi` :24, `file_ffi` :34, `git_ffi` :40, `graph_ffi` :45, `log_defaults_ffi` :33, `repo_write_ffi` :42, `push_remotes_ffi` :23, `squash_split_ffi` :27, `repo_ffi` :29, `file_ops_ffi` :36, `snapshot_ffi` :54; identity-only: `bookmarks_ffi` :36, `change_ffi` :26, `commit_views_ffi` :37, `op_log_ffi` :28, `remotes_ffi` :38, `status_ffi` :25, `watcher` :10, `workspace_ffi` :36; XDG-returning: `config_ffi` :30-44 (:349, :648), `secure_config_ffi` :29-45.
  - already on `pin_test_env`: jj `clone_init`, `network_cancel`, `push`, `push_remotes`; ffi `push_ffi`.
  - no pin: jj `api_stability`, `detect`, `find_repo_root`; ffi `ffi_abi_doc_sync` — unchanged.
- **Own-process tests (every `#[test]` of the file gets the prologue; its module pin/helpers stay as they are, they now run only in the child):**
  - per-test env mutation, no restore: jj `clone_cancel` :36-40 (`JJ_CONFIG` → a git wrapper sleeping 30 s), `clone_config` :51-54 (broken `JJ_CONFIG`), `config_cmd_user` :26-62, `config_identity` :38-356 (removes identity, broken `JJ_CONFIG`), `creation_warnings` :36-657 (broken XDG, `JJ_CONFIG=""`), `config_user_layer` :44-47, `convert_alias_write_failure` :44-53 (unusable XDG), `file_track_home_git_ignore` :54-61 (`XDG_CONFIG_HOME=""`, `HOME`), `secure_config_fixups_user` :18-40; ffi `repo_config_ffi` :24-118.
  - write-once process environment (`crates/zanshin-jj/src/environment.rs:44,62-95` `ADOPTED: OnceLock`): jj `login_shell_environment` :73-81 (adopts a `PATH` led by a failing fake `git`); ffi `environment_ffi` :112-140.
  - module pin with different variables: jj `config_cmd` :31-48 (REMOVES `JJ_USER`/`JJ_EMAIL`, 11 tests), `snapshot_watchman` :25-43 (`WATCHMAN_SOCK`).
  - FFI event sink (`crates/zanshin-ffi/src/events.rs:37,59-115` — one slot, every session's watcher/progress events): ffi `events_ffi` (all; `close_stops_further_dispatch` :257-286 asserts silence), `repo_write_ffi` sink tests :805, :890 (fetch progress :826-879 asserts only its own session). `push_ffi` :247-386 filters by session id and stays in the parent under its `SINK_GUARD`.
- `crates/zanshin-jj/tests/file_track_untrack.rs` :31-58 -- guard sets `HOME` too and writes `$XDG/git/ignore` = `*.xdgignored`: move to the shared pin, write that ignore file into the shared XDG once (module-local `LazyLock` after the pin; pattern unique to this module), and run only `base_ignores_expands_a_home_relative_core_excludes_file` (:1153-, uses `pin_env()`'s `HOME` at :1155) in its own process with `HOME` set there.
- `crates/zanshin-jj/tests/clone_init.rs` :582-591 (`with_user_config` filter; names at :611, :650, :694, :739, :781) and `network_cancel.rs` :457-458 (`sleeper_child`) -- prefix the module.
- `Makefile.toml` :699-702, :761-762 -- comments naming per-file binaries (`revset-<hash>`, `*_ffi-<hash>`); the `/tests/` ignore regex :767 still matches `tests/it/`. `crates/xtask/src/tasks/lcov_union.rs` :9-11 -- same doc. `crates/xtask/src/tasks/gate_plan.rs` -- rules are crate-prefix based (`crates/zanshin-jj/`, `crates/zanshin-ffi/`) so `tests/it/` maps unchanged; no edit unless a rule names a test file.
- Path references to update (`tests/<stem>.rs` → `tests/it/<stem>.rs`): `docs/ffi-abi.md:469`, `docs/rust-error-codes.md:208`, `docs/coverage.md:108-109`; src doc comments `zanshin-jj/src/revset.rs:435,445`, `config.rs:3102,3215,3339,3551`, `warning.rs:705`, `creation.rs:701`, `remotes.rs:426`, `lib.rs:27`, `op_support.rs:794`, `zanshin-ffi/src/repo.rs:1776,1780`; Dart comments under `packages/zanshin_core/test/worker/*.dart` (≈24) and `test/ffi/environment_test.dart:11`; ≈90 sibling references inside the moved tests (e.g. "the `tests/convert.rs` pattern"); `CLAUDE.md` test-placement paragraph (integration tests → `tests/it/`, one module per file); `_bmad-output/project-context.md:328`.

## Tasks & Acceptance

**Execution:**
- Baseline (before any edit, at HEAD) -- record per crate `cargo test -p zanshin-jj --tests -- --list` / `-p zanshin-ffi` totals (count lines ending `: test`), `du -sh target target/debug/deps target/llvm-cov-target`, the number of zanshin-jj/zanshin-ffi integration-test executables in `target/debug/deps`, and the wall time of one `cargo make test-full` run after `cargo clean -p zanshin-jj -p zanshin-ffi` plus the same with `--target-dir target/llvm-cov-target` (identical procedure after the change, so stale per-file binaries do not inflate either side) -- the witnesses need before/after numbers.
  - **DONE by the parent session at `bb62aca`, 2026-10-21 — do not redo:** `--list` totals zanshin-jj **1180** (lib 273 + integration 907), zanshin-ffi **479** (lib 186 + integration 293). After both `cargo clean -p` calls: `cargo make test-full` green in **1034 s**; then `target` 16G, `target/debug/deps` 5.3G (4 executables — the gate builds no debug test binaries), `target/llvm-cov-target` 9.3G (94 executables under `deps`). Then `cargo test -p zanshin-jj -p zanshin-ffi --no-run`: `target/debug/deps` 11G, 89 executables totalling 6.3 GB.
- `crates/test-helpers/src/lib.rs` -- `pin_test_env() -> &'static Path`; new own-process helper (function + `#[macro_export]` macro, see Design Notes); rewrite the pin docs -- the ONE env lock and the child mechanism.
- `crates/zanshin-jj/tests/it/main.rs`, `crates/zanshin-ffi/tests/it/main.rs` (new) + `git mv` of every file -- `//!` doc stating the layout and the env rule, `mod` per file alphabetically -- one binary per crate.
- Shared-pin modules (Code Map list) -- swap the module guard for `pin_test_env()`; keep each module's `pin_env()` wrapper only where it returns the XDG path the tests use -- one pin per process.
- Own-process files (Code Map list) + `file_track_untrack.rs` -- prologue on each listed test -- isolation a fresh process used to give.
- `clone_init.rs`, `network_cancel.rs` -- module-prefixed filters.
- `Makefile.toml`, `lcov_union.rs`, docs, src doc comments, Dart comments, in-test sibling references, `CLAUDE.md`, `project-context.md` -- name `tests/it/`.
- `coverage-baseline.txt` -- commit an auto-raise if one happens; never lower.

**Acceptance Criteria:**
- Given the change, when `cargo test -p zanshin-jj --tests -- --list` and the same for zanshin-ffi run, then each crate lists exactly its baseline count and the integration tests come from one `it` binary per crate.
- Given a clean build of the two crates, when `target/debug/deps` is listed, then zanshin-jj and zanshin-ffi each have one integration-test executable (plus the lib unit-test binary), and the spec records target sizes and gate time before/after.
- Given three consecutive `cargo make test-full` runs on the final tree (repo root, unpiped, synchronous), then all three exit 0 and `coverage-baseline.txt` is not lowered.
- Given the moved tests, when grepping `crates/zanshin-jj/tests/it` and `crates/zanshin-ffi/tests/it` for `set_var`/`remove_var`/`adopt_environment`/`zanshin_events_register`, then every hit outside `pin_test_env` is in a test (or helper only it calls) that starts with the own-process prologue, or in `push_ffi`'s session-filtered sink tests.
- Given the end of the run, then `git status --porcelain` is clean and every commit was made with `--no-gpg-sign` and ends with the co-author trailer.

## Spec Change Log

## Review Triage Log

### 2026-10-21 — Review pass
- verdicts: 30 findings — high 0, medium 0, low 25, false 4, maybe-false 1
- findings:
  - `[low]` `[patch]` blind 1: `workspace_test.dart` line-wrapped `crates/zanshin-ffi/tests/` + `workspace_ffi.rs` missed by the rewrite — rewrapped to `tests/it/workspace_ffi.rs`.
  - `[low]` `[patch]` blind 2: `zanshin-ffi/src/repo.rs` inline guard comment "mirrors tests/it/repo_ffi.rs / watcher.rs" points at deleted guards, and `pin_test_env`'s doc claimed "every test process" — comment reworded; doc narrowed to zanshin-jj's inline tests + the two `it` binaries (the ffi lib guard is a separate process, unchanged).
  - `[low]` `[patch]` blind 3: duplicate `ENV_GUARD`s in own-process modules (`events_ffi`, `clone_config`, `config_user_layer`) with a false "mirrors" comment — comment corrected; the guards stay as the spec directs (they run only in the one-test child).
  - `[low]` `[patch]` blind 4: `events_ffi` module doc / `TEST_GUARD` / poison comments still describe a binary shared by every test — wording corrected, guards kept (spec: module helpers unchanged).
  - `[low]` `[patch]` blind 5: garbled dangling fragment in `repo_write_ffi.rs` sink comment — rewritten as one sentence.
  - `[low]` `[reject]` blind 6: `clone_init` keeps its own child mechanism with hard-coded `clone_init::` prefixes — the spec keeps it deliberately (prefix only); migrating means restructuring five tests' config-file plumbing, and a module rename fails the parent loudly ("0 passed"), never silently.
  - `[low]` `[patch]` blind 7: `zanshin-ffi/tests/it/main.rs` doc says every sink owner uses `own_process!`, but `push_ffi`'s two session-filtered sink tests stay in the parent — the exception is now stated.
  - `[low]` `[reject]` blind 8: an `own_process!` literal naming an existing sibling test would run the sibling and skip the caller's body — needs a copy-paste mistake within one of 15 files; the fix (deriving the name from a nested fn's `type_name`) changes the macro's interface; not worth the complexity now.
  - `[low]` `[reject]` blind 9: helper has no timeout, discards child output on success, and no test of a failing child — a hung in-process test hangs libtest the same way; a failing child exits non-zero and hits the same assertion the "0 passed" test covers; a should_panic witness of child failure is not constructible (the child's should_panic would pass).
  - `[low]` `[reject]` blind 10: a new module that forgets `pin_test_env()` passes by accident when another module pinned first — before the change, a forgotten pin silently read the developer's config every run, so nothing is lost; enforcement would need a new mechanism.
  - `[low]` `[reject]` blind 11: `file_track_untrack` writes `$XDG/git/ignore` (`*.xdgignored`) into the shared XDG mid-run — the spec's chosen design; the pattern is unique and no other test creates such a file; 3 green full gates.
  - `[low]` `[reject]` blind 12: `environment_ffi`'s two refusal tests are wrapped although they read no environment — the spec wraps every test of the file; a regression that installed on refusal would otherwise poison the shared process; cost is two process starts.
  - `[low]` `[defer]` blind 13: CLAUDE.md vs project-context.md / `main.rs` disagree on who must pin — agent-context file edit, deferred (frontmatter + deferred-work.md).
  - `[low]` `[patch]` blind 14: coverage of child-run bodies undocumented — one sentence added to `docs/coverage.md` (cargo-llvm-cov's `%p` profiles); coverage held over 3 full gates confirms it.
  - `[low]` `[defer]` blind 15: `.claude/skills/story-loop/SKILL.md` sentence ambiguous — agent-context file, deferred.
  - `[low]` `[reject]` edge 1: no timeout on the child run — same as blind 9.
  - `[low]` `[reject]` edge 2: `own_process!` in an `#[ignore]` test run with `--ignored` would run 0 tests in the child — no such test exists (the only ignored test, `revset_large_fixture_fully_materialized`, has no prologue); a loud failure, not a silent pass.
  - `[low]` `[reject]` edge 3: `own_process!` in a `#[should_panic]` test flips the outcome — no such test exists; it would fail loudly in the parent.
  - `[low]` `[reject]` edge 4: shared XDG git ignore written lazily — same as blind 11.
  - `[maybe-false]` `[reject]` edge 5: 39 `file_track_untrack` tests now read the real `$HOME` (only the one test that needs it pins one) — would need a system git config with a `~/`-relative `core.excludesFile` on the machine to matter; every other module already ran with the real `$HOME`; if true, low.
  - `[low]` `[reject]` edge 6: `clone_init`'s `set_var`/`remove_var` in `with_user_config` sit behind its own child mechanism, not `own_process!`, so the grep AC fails as worded — the spec itself keeps that mechanism (Code Map: prefix only); the effect is child-only; the only fix is editing this spec's AC or an out-of-spec refactor.
  - `[low]` `[patch]` edge 7: `push_ffi` sink tests in the parent contradict `main.rs`'s rule — same entry as blind 7.
  - `[low]` `[patch]` edge 8: zanshin-ffi lib's own inline env guard vs "ONE lock" doc — same entry as blind 2.
  - `[low]` `[patch]` edge 9: `workspace_test.dart` stale path — same entry as blind 1.
  - `[low]` `[reject]` intent 1: no restore-under-a-mutex as the epic's wording suggests; children instead — deliberate and documented (Design Notes "Why children, not a lock"): a restoring mutex cannot protect concurrent readers, and `adopt_environment` is write-once.
  - `[false]` `[reject]` intent 2: non-env process globals not audited — the planning audit covered them: cancel `REGISTRY` uses disjoint token ranges, tracing `INIT` is never called by tests, `CLI_DEFAULTS` is static; the FFI sink and `ADOPTED` are the two that mattered and both moved to children.
  - `[false]` `[reject]` intent 3: `gate_plan.rs` / coverage tooling changed only in comments — `gate_plan` rules are crate prefixes (`crates/zanshin-jj/`, `crates/zanshin-ffi/`) that already cover `tests/it/`, and the coverage ignore regex `/tests/` matches `tests/it/`; nothing names a test target.
  - `[false]` `[reject]` intent 4: witnesses absent — recorded under Auto Run Result (counts, sizes, gate times, 3 green runs); not part of a code diff.
  - `[low]` `[reject]` intent 5: starting environments changed (identity-only modules now get the shared XDG; `HOME` pinned for one test only) — sanctioned by the spec; assertions unchanged; all green.
  - `[false]` `[reject]` intent 6: `test-helpers` / `zanshin-parity` not merged — the epic says "only if it pays"; parity's `driver_pins_env` needs its own process.

## Design Notes

**Why children, not a lock.** A mutex around `set_var` does not protect readers: every other test reads the environment through jj (config, identity, XDG secure config) at arbitrary times, so a test that points `JJ_CONFIG` at a broken file breaks concurrent tests even if it restores afterwards, and `adopt_environment` cannot be undone. Re-running such a test as the only test of a child process of the SAME binary is exactly the isolation it had as its own binary, costs a process start instead of a link, and keeps one binary. The process environment then has exactly one writer: `pin_test_env`'s `LazyLock` — the story's "one shared lock".

**Helper shape** (names may differ; behaviour may not):
```rust
pub fn reran_in_own_process(module_path: &str, test: &str) -> bool // true = parent: child ran it
#[macro_export] macro_rules! own_process { ($test:literal) => {
    if $crate::reran_in_own_process(module_path!(), $test) { return; } } }
// in a test:  test_helpers::own_process!("config_get_reads_the_user_layer");
```
Full libtest name = `module_path!()` minus its first segment (`it::config_cmd` → `config_cmd`) + `::` + `test`. Marker variable e.g. `ZANSHIN_TEST_OWN_PROCESS`; child args as in `clone_init.rs:582-591`. `cargo llvm-cov` names profiles with `%p`, so children's coverage is counted (as `clone_init`'s already is).

## Verification

The parent session runs the three `cargo make test-full` runs and the after-measurement (same procedure as the baseline task); the implementer runs the targeted `cargo test` commands, `cargo make test-clippy`/`test-fmt`, and leaves the tree uncommitted.

**Commands:**
- `cargo test -p zanshin-jj --tests -- --list` and `cargo test -p zanshin-ffi --tests -- --list` -- expected: baseline counts.
- `cargo test -p zanshin-jj --test it` and `cargo test -p zanshin-ffi --test it` -- expected: green.
- `cargo make test-full` three times in a row (repo root, unpiped, synchronous, long timeout; PATH with `~/development/sdks/flutter/bin` and `~/development/sdks/cargo/bin`, `CARGO_HOME=~/development/sdks/cargo`; if coverage reports a missing `llvm-profdata`, rerun `RUSTUP_HOME=$HOME/.rustup cargo make --allow-private coverage` then `cargo make --allow-private gate-stamp`) -- expected: exit 0 each time; coverage held or raised.
- `ls target/debug/deps | grep -E '^it-'` and `du -sh target target/debug/deps target/llvm-cov-target` -- expected: two `it-<hash>` executables; sizes recorded.

## Auto Run Result

Status: done (2026-10-21). Blocking condition: none. Commits: spec + recompiled Epic 9 context bb62aca89958acbe2b86fda8fadfcc1bb427084d; code + review patches dba535ac45b59c3b33ac7c47c8aac15509d46516; plus the finalisation commit of this spec, deferred-work.md and sprint-status.yaml.

**Summary.** `zanshin-jj` and `zanshin-ffi` each build ONE integration-test binary, `tests/it/main.rs`, with every former `tests/<name>.rs` as module `<name>` (`git mv`, 56 + 29 files). `test_helpers::pin_test_env()` (now returning the pinned `$XDG_CONFIG_HOME`) is the one writer of the process environment and replaces 59 per-file `ENV_GUARD`s. Tests that changed the environment per test, adopted a login-shell environment (`ADOPTED` OnceLock), pinned different variables (`config_cmd`, `snapshot_watchman`, `file_track_untrack`'s `$HOME` test) or own the FFI event sink (`events_ffi`, two `repo_write_ffi` fetch tests) start with the new `test_helpers::own_process!("<fn>")` and run alone in a child process of the same binary (`reran_in_own_process`, marker `ZANSHIN_TEST_OWN_PROCESS`). `clone_init`/`network_cancel` re-run filters gained the module prefix. Docs, src doc comments, Dart test comments, Makefile/lcov-union comments, CLAUDE.md and project-context.md name `tests/it/`.

**Witnesses (before at `bb62aca` / after at `dba535a`).**
- `cargo test -p <crate> --tests -- --list`: zanshin-jj 1180 / 1180 (lib 273 + integration 907 / `it` 907); zanshin-ffi 479 / 479 (lib 186 + integration 293 / `it` 293).
- `cargo make test-full` after `cargo clean -p zanshin-jj -p zanshin-ffi` (both target dirs): 1034 s before; 843 s after; then two more consecutive green runs 782 s and 770 s (3 in a row green). A patched-comments `cargo make test` afterwards: green, 766 s. `coverage-baseline.txt` unchanged (held, not lowered, no auto-raise).
- `target/llvm-cov-target`: 94 test executables, 9.3G before → 13 test executables (0.64 GB) after; 3.6G once the stale per-file binaries of the deleted targets were removed (cargo clean -p cannot see targets that no longer exist; 5275 stale files in both `deps` dirs deleted by hand).
- `target/debug/deps` after `cargo test -p zanshin-jj -p zanshin-ffi --no-run`: 89 executables, 6.3 GB, dir 11G before → 11 executables, 0.75 GB, dir 5.8G after. `target` 16G (post-gate) before → 12G after.

**Files changed:**
- `crates/test-helpers/src/lib.rs` — `pin_test_env() -> &'static Path`, `OWN_PROCESS_VAR`, `reran_in_own_process`, `own_process!`, two inline tests (child runs the body; a wrong name fails with "0 passed").
- `crates/zanshin-{jj,ffi}/tests/it/main.rs` (new) + all moved test files — module list; shared pin; own-process prologues; prefixed filters; comment paths.
- `crates/zanshin-jj/src/*.rs`, `crates/zanshin-ffi/src/repo.rs` — doc comments naming test paths only.
- `docs/coverage.md`, `docs/ffi-abi.md`, `docs/rust-error-codes.md`, `Makefile.toml` (comments), `crates/xtask/src/tasks/lcov_union.rs` (doc), `packages/zanshin_core/test/**` (comments), `CLAUDE.md`, `_bmad-output/project-context.md`, `.claude/skills/story-loop/SKILL.md` (one sentence, outside the spec's list).

**Review findings.** 30 findings (high 0, medium 0, low 25, false 4, maybe-false 1).
- **Patched, 6 entries (all low):** stale wrapped Dart path (blind 1, edge 9); "mirrors" comments + `pin_test_env` "every test process" overclaim (blind 2, blind 3, edge 8); `events_ffi` docs/poison comments (blind 4); garbled `repo_write_ffi` comment (blind 5); `main.rs` push_ffi sink exception (blind 7, edge 7); `docs/coverage.md` child-coverage sentence (blind 14). Comment/doc edits only.
- **Deferred, 2 (low, agent-context files):** CLAUDE.md vs project-context.md/`main.rs` wording on who must pin (blind 13); ambiguous SKILL.md sentence (blind 15). Mirrored in deferred-work.md "Surfaced in Story 9.55".
- **Rejected:** blind 6 / edge 6 (clone_init's own child mechanism kept by the spec; AC wording); blind 8 (sibling-name copy-paste); blind 9 / edge 1 (no timeout, output, failing-child test); blind 10 (forgotten pin); blind 11 / edge 4 (shared XDG git ignore); blind 12 (refusal tests wrapped); edge 2 (`--ignored`); edge 3 (`should_panic`); edge 5 (maybe-false, real `$HOME`); intent 1 (children instead of restore — documented design); intent 5 (sanctioned precondition changes). False: intent 2, 3, 4, 6. Reasons in the triage log.
- **Follow-up review recommended:** false (no high patched; 0 medium).

**Verification.** `--list` counts above; `cargo test -p zanshin-jj -p zanshin-ffi -p test-helpers` green (implementer); `cargo test -p test-helpers --lib` 2 passed; three consecutive `cargo make test-full` green; final `cargo make test` green after the comment patches. Matrix audit: own-process parent/child rows — every prologued test plus `own_process_runs_the_body_in_a_child_of_the_pinned_environment`; wrong name — `a_name_that_is_not_the_callers_fails_the_parent`; re-run filters — `clone_init`'s five config tests and `network_cancel::a_readable_process_spawned_after_the_cancel_is_killed_by_its_token`; mid-run module touch — the whole merged suite green three times.

**Residual risks.** An `own_process!` literal that names an existing sibling test would silently skip the caller's body (rejected, low). Stale per-file test binaries from before this change stay in other checkouts' `target/` until `gate-sweep` or a manual clean removes them. All modules now share one `$XDG_CONFIG_HOME` store (repo configs keyed by random id).
