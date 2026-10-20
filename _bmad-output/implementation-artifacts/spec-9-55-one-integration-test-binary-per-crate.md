---
title: 'Story 9.55 — One integration-test binary per crate'
type: 'chore'
created: '2026-10-20'
status: 'ready-for-dev'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-9-context.md'
warnings: ['oversized']
deferred: []
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

**Commands:**
- `cargo test -p zanshin-jj --tests -- --list` and `cargo test -p zanshin-ffi --tests -- --list` -- expected: baseline counts.
- `cargo test -p zanshin-jj --test it` and `cargo test -p zanshin-ffi --test it` -- expected: green.
- `cargo make test-full` three times in a row (repo root, unpiped, synchronous, long timeout; PATH with `~/development/sdks/flutter/bin` and `~/development/sdks/cargo/bin`, `CARGO_HOME=~/development/sdks/cargo`; if coverage reports a missing `llvm-profdata`, rerun `RUSTUP_HOME=$HOME/.rustup cargo make --allow-private coverage` then `cargo make --allow-private gate-stamp`) -- expected: exit 0 each time; coverage held or raised.
- `ls target/debug/deps | grep -E '^it-'` and `du -sh target target/debug/deps target/llvm-cov-target` -- expected: two `it-<hash>` executables; sizes recorded.
