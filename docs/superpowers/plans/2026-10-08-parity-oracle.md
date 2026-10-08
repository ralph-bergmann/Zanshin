# Differential Parity Oracle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run every shipped mutating `zanshin-jj` verb and the stock jj CLI at the pinned tag on identical repos inside `cargo make test`, and fail on any divergence that the ledger does not explain.

**Architecture:**
- A new test-only workspace crate `crates/zanshin-parity` builds a bin `jj`: upstream's entry point over crates.io `jj-cli`, pinned with `jj-lib`.
- Its integration tests (`tests/oracle/`) build two identical repos per scenario through that binary, run the operation through `zanshin-jj` (repo A) and through the binary (repo B), and capture both repos' semantic state through jj-lib.
- Each aspect is compared, and the result is checked against a ledger of expected divergences.

**Tech Stack:** Rust 1.97.1 (workspace toolchain); `jj-cli =0.46.0` and `jj-lib =0.46.0` (crates.io); `test-helpers` (`TEST_ENV`, `pin_test_env`); `tempfile`; `pollster`; cargo-make gate.

**Spec:** `_bmad-output/planning-artifacts/epics.md` Story 9.47 (line 6853). Mirror: `_bmad-output/implementation-artifacts/sprint-status.yaml` key `9-47-differential-parity-oracle-in-gate`.

**Reference implementation (throwaway POC, deleted branch, still in the object DB until `git gc`):**
- `git show 3d77108:spikes/jj-cli-reuse/poc/tests/parity_zanshin.rs`. A copy is in this session's scratchpad `poc-keep/poc/tests/parity_zanshin.rs`.
- Its state capture, labelling, id normalization and scenario table are proven. **Port them; do not reinvent them.**
- Drop:
  - the embedded-fork and installed-jj drivers;
  - the `KNOWN` print-only classification (replaced by the failing ledger);
  - the warning-text heuristic (replaced by a count);
  - the timing table.

## Global Constraints

**Pin and dependency**
- `jj-cli = "=0.46.0"` in root `[workspace.dependencies]`, next to `jj-lib = "=0.46.0"`, with the CLI's DEFAULT features (stock behavior). Inline `# WHY:` says both are bumped together.
- No `[patch.crates-io]` (crates/README.md).

**The crate**
- `crates/zanshin-parity`: `publish = false`.
- NOT added to root `default-members` (no release build).
- `[lints] workspace = true`.
- Every `[package]` field `*.workspace = true`, no standalone `version` (crates/README.md AR-AD-7).

**Coverage**
- `coverage-baseline.txt` gains `exclude_prefix = crates/zanshin-parity/` with a comment matching the `test-helpers` line.

**Gate plumbing**
- `Makefile.toml` `test-cargo-hygiene`: count `7` → `8`, and the comment "root + six crates" → "root + seven crates".

**Hermetic environment**
- Every test calls `test_helpers::pin_test_env()` first.
- Every `jj` subprocess gets these values explicitly via `Command::env`:
  - every `test_helpers::TEST_ENV` pair;
  - `XDG_CONFIG_HOME` = the value `pin_test_env` set in the process env;
  - `LLVM_PROFILE_FILE=/dev/null`, so the coverage run's instrumented `jj` never writes `.profraw` files (they would land in the repo cwd or flood `target/`);
  - `stdin` null.
- Nothing may touch `~/.config/jj` or the developer's git config.

**Comparison**
- Aspects never contain ids (commit / change / op). Ids are replaced by labels as in the POC.
- Tree ids are compared raw (the Git tree hash, equal for equal content).
- **Global exclusion:** the op `args` attribute is NOT captured. Write the reason as a doc comment at the aspect list: "Zanshin has no argv, ADR-0003; deliberate".
- Warnings are compared as a COUNT (`warnings = n`; CLI side counts stderr lines starting with `Warning: `). Refusal is compared as `outcome = ok|refused`.

**Ledger**
- A scenario test fails on a divergence not in `LEDGER`, or on a `LEDGER` entry for that scenario that did not diverge (stale).
- Failure messages print scenario id, aspect, Zanshin value and CLI value.

**Quality gate**
- `cargo clippy --workspace --all-targets -- -D warnings` (pedantic) and `cargo fmt --all --check` must pass for the new code.
- Comment density and `// WHY:` style match `crates/zanshin-jj/tests/*.rs`.

**Commits:** `git commit --no-gpg-sign`. The message ends with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

**Gate runs:** run `cargo make test` from the main session, never from a subagent (they get killed). Check `df -h /Users/ralph.bergmann` before builds. The disk is near-full; the coverage step builds a second, instrumented target.

## Review Focus

1. **A ledger entry with a typo'd scenario id or aspect name is never checked**, so it silently masks nothing and the "stale" rule never fires.
   → Task 3 test `ledger_names_only_known_scenarios_and_aspects`.
2. **The coverage run** (`cargo llvm-cov --workspace`) runs an instrumented `jj` hundreds of times. Each exit would merge a large profile into `target/` (slow, and the disk is near-full). That only shows up in the coverage run, never in a plain `cargo test`.
   → Task 1 test `pinned_jj_command_carries_the_hermetic_env` asserts on `Command::get_envs()` that the driver sets `LLVM_PROFILE_FILE=/dev/null` (plus every `TEST_ENV` pair and `XDG_CONFIG_HOME`).
3. **The developer's real jj config leaks in**, or the CLI writes its secure per-repo config into `~/.config/jj/repos`.
   → Task 1 test `pinned_jj_keeps_its_secure_config_in_the_test_xdg_dir`.
4. **Setup drift:** the two CLI-built repos differ before the operation (e.g. a scenario step that is not deterministic). Every divergence would then be blamed on Zanshin.
   → Task 3 `run` panics with "setup differs" when `before_a` and `before_b` aspects differ. Task 2 test `identical_cli_built_repos_capture_equal` pins the BASE history.
5. **Parallel scenario tests share one process env and one `XDG_CONFIG_HOME`.**
   → Secure-config dirs are keyed by a random config id, so this is safe. No test may mutate the process env after `pin_test_env`; `pin_test_env` is a `LazyLock`, so this holds by construction. Task 3's `run` must not call `set_var`.

---

### Task 1: Crate scaffold, pinned `jj` binary, gate plumbing, hermetic driver

**Files:**
- Modify:
  - `Cargo.toml` (`[workspace.dependencies]`: add `jj-cli`);
  - `Makefile.toml` (`test-cargo-hygiene` count + comment);
  - `coverage-baseline.txt` (exclude);
  - `crates/README.md` (crate table row: `zanshin-parity` | bin (test-only) | stock jj at the pin for the parity oracle, Story 9.47).
- Create:
  - `crates/zanshin-parity/Cargo.toml`;
  - `crates/zanshin-parity/src/main.rs`;
  - `crates/zanshin-parity/tests/oracle/main.rs`;
  - `crates/zanshin-parity/tests/oracle/driver.rs`.

**Interfaces:**
- Produces (`tests/oracle/driver.rs`):
  - `pub struct CliRun { pub success: bool, pub stdout: String, pub stderr: String }`, with `#[track_caller] pub fn ok(self) -> Self`, which panics with stderr when `!success`.
  - `pub fn command(cwd: &Path, args: &[&str]) -> std::process::Command`: builds the `env!("CARGO_BIN_EXE_jj")` invocation with the hermetic env from Global Constraints, `current_dir(cwd)` and `stdin(Stdio::null())`.
  - `pub fn jj(cwd: &Path, args: &[&str]) -> CliRun`: runs `command(cwd, args).output()`.
  - `pub enum Step { Jj(&'static [&'static str]), JjAt(&'static str, &'static [&'static str]), Write(&'static str, &'static str) }`. `JjAt` takes a dir relative to the repo root.
  - `pub fn fresh_repo(init: &[&str], steps: &[&[Step]]) -> (tempfile::TempDir, PathBuf)`: creates `<temp>/repo`, runs `jj <init>` there, then the steps. Every `jj` call is `.ok()`.

- [ ] **Step 1: Scaffold the crate and the dependency**

  `crates/zanshin-parity/Cargo.toml`:
  - `[package] name = "zanshin-parity"`, the workspace-inherited fields like `crates/test-helpers/Cargo.toml`, `publish = false`.
  - `[[bin]] name = "jj", path = "src/main.rs"`.
  - `[dependencies] jj-cli = { workspace = true }`.
  - `[dev-dependencies]`: `zanshin-jj`, `jj-lib`, `test-helpers` (path, like other consumers), `tempfile`, `pollster` (workspace).
  - A `# WHY:` comment block above `[dependencies]`, in `test-helpers`' style: test-only tool crate, exempt from the FR-JJ-16 ACL, coverage excluded, never shipped.

  `src/main.rs` body: `jj_cli::cli_util::CliRunner::init().run().into()` in `fn main() -> std::process::ExitCode`, plus a module doc that says:
  - it is upstream's `cli/src/main.rs` entry point @ v0.46.0, minus the mimalloc global allocator and the build-time version string;
  - the parity oracle's CLI side;
  - why not the `jj` on `PATH`: not the pinned version.

- [ ] **Step 2: Write the failing tests** in `tests/oracle/main.rs` (`mod driver;`)

```rust
#[test]
fn pinned_jj_builds_a_repo_zanshin_opens() {
    test_helpers::pin_test_env();
    let (_dir, root) = driver::fresh_repo(&["git", "init"], &[]);
    zanshin_jj::Repo::open(&root).expect("Zanshin opens a repo the pinned jj created");
}

#[test]
fn pinned_jj_keeps_its_secure_config_in_the_test_xdg_dir() {
    test_helpers::pin_test_env();
    let (_dir, root) = driver::fresh_repo(&["git", "init"], &[]);
    let id = std::fs::read_to_string(root.join(".jj/repo/config-id")).expect("config-id");
    let xdg = std::env::var_os("XDG_CONFIG_HOME").expect("pinned");
    assert!(Path::new(&xdg).join("jj/repos").join(id.trim()).is_dir());
}

#[test]
fn pinned_jj_command_carries_the_hermetic_env() {
    test_helpers::pin_test_env();
    let command = driver::command(Path::new("/"), &["log"]);
    let envs: BTreeMap<_, _> = command.get_envs().collect();
    let get = |name: &str| envs.get(OsStr::new(name)).copied().flatten();
    assert_eq!(get("LLVM_PROFILE_FILE"), Some(OsStr::new("/dev/null")));
    assert_eq!(get("XDG_CONFIG_HOME"), std::env::var_os("XDG_CONFIG_HOME").as_deref());
    for (name, value) in test_helpers::TEST_ENV {
        assert_eq!(get(name), Some(OsStr::new(value)), "{name}");
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

  Run: `cargo test -p zanshin-parity`
  Expected: compile errors (no `driver` module / no `jj` bin yet), or failing assertions.

- [ ] **Step 4: Implement `driver.rs`.** Port `Cli::Binary` + `CliRun` + `Step` + `fresh_repo` from the POC, minus the `--config user.*` flags: identity comes from `TEST_ENV` (`JJ_USER` / `JJ_EMAIL`).

- [ ] **Step 5: Run tests to verify they pass**

  Run: `cargo test -p zanshin-parity`
  Expected: 3 passed.

- [ ] **Step 6: Gate plumbing**
  - hygiene count 8 + comment;
  - the coverage exclude line;
  - the `crates/README.md` row.

  Run: `cargo make --allow-private test-cargo-hygiene`. Expected: exit 0.
  Run: `cargo deny --workspace check advisories bans`. Expected: `advisories ok, bans ok`. If an advisory fires in jj-cli's tree, STOP and report it to Ralph; do not add an ignore unasked.

- [ ] **Step 7: Clippy and fmt**

  Run: `cargo clippy -p zanshin-parity --all-targets -- -D warnings`, then `cargo fmt --all --check`.
  Expected: clean.

- [ ] **Step 8: Commit.** `feat(zanshin-parity): pinned stock jj binary + hermetic CLI driver (Story 9.47)`.

---

### Task 2: Semantic state capture and per-aspect comparison

**Files:**
- Create:
  - `crates/zanshin-parity/tests/oracle/state.rs`;
  - `crates/zanshin-parity/tests/oracle/compare.rs`.
- Modify: `tests/oracle/main.rs` (`mod state; mod compare;` and the tests).

**Interfaces:**
- Consumes: `driver::{jj, fresh_repo, Step, CliRun}`.
- Produces (`state.rs`):
  - `pub struct State { pub aspects: BTreeMap<&'static str, String>, /* POC's private label maps, wc_label, op_head, op_chain */ }`, with:
    - `pub fn change(&self, label: &str) -> zanshin_jj::ChangeId`, where `"@"` = the working-copy commit;
    - `pub fn change_arg(&self, label: &str) -> String`.
  - `pub fn capture(root: &Path, before: Option<&State>) -> State`.
  - `pub const STATE_ASPECTS: &[&str]`: every key `capture` inserts, in one list, with the `args` exclusion doc comment right above it.
- Produces (`compare.rs`):
  - `pub struct Divergence { pub aspect: String, pub zanshin: String, pub cli: String }`.
  - `pub fn compare(a: &BTreeMap<&'static str, String>, b: &BTreeMap<&'static str, String>) -> Vec<Divergence>`.
  - `pub struct Outcome { pub refused: bool, pub warnings: usize }`.
  - `pub fn zanshin_outcome<T, E>(repo: &mut zanshin_jj::Repo, result: Result<T, E>) -> Outcome`: `warnings` = `repo.take_warnings().len()`.
  - `pub fn config_outcome(outcome: zanshin_jj::ConfigSetOutcome) -> Outcome`.
  - `pub fn init_outcome(outcome: &zanshin_jj::CreationOutcome) -> Outcome`.
  - `pub fn cli_outcome(run: &CliRun) -> Outcome`: `warnings` = stderr lines starting with `"Warning: "`.
  - `pub fn outcome_aspects(outcome: &Outcome) -> BTreeMap<&'static str, String>`: keys `"outcome"` (`ok` / `refused`) and `"warnings"` (count).
  - `pub const OUTCOME_ASPECTS: &[&str] = &["outcome", "warnings", "extra"]`.

- [ ] **Step 1: Write the failing tests**

```rust
#[test]
fn identical_cli_built_repos_capture_equal() {
    test_helpers::pin_test_env();
    let (_a, a) = driver::fresh_repo(&["git", "init"], &[scenarios::BASE]);
    let (_b, b) = driver::fresh_repo(&["git", "init"], &[scenarios::BASE]);
    let found = compare::compare(&state::capture(&a, None).aspects, &state::capture(&b, None).aspects);
    assert!(found.is_empty(), "{:?}", found.iter().map(|d| &d.aspect).collect::<Vec<_>>());
}

#[test]
fn a_description_difference_shows_in_descriptions_without_ids() {
    test_helpers::pin_test_env();
    let (_a, a) = driver::fresh_repo(&["git", "init"], &[scenarios::BASE]);
    let (_b, b) = driver::fresh_repo(&["git", "init"], &[scenarios::BASE]);
    let before_a = state::capture(&a, None);
    let before_b = state::capture(&b, None);
    driver::jj(&a, &["describe", "-m", "C one"]).ok();
    driver::jj(&b, &["describe", "-m", "C two"]).ok();
    let found = compare::compare(&state::capture(&a, Some(&before_a)).aspects, &state::capture(&b, Some(&before_b)).aspects);
    // The label changes too, so graph/trees/etc. differ only by label text: assert the
    // description aspect is among them and no aspect leaks a 40-hex commit id.
    assert!(found.iter().any(|d| d.aspect == "descriptions"));
    let has_commit_id = |s: &str| s.split(|c: char| !c.is_ascii_hexdigit()).any(|t| t.len() == 40);
    assert!(found.iter().all(|d| !has_commit_id(&d.zanshin) && !has_commit_id(&d.cli)));
}

#[test]
fn every_captured_aspect_is_listed() {
    test_helpers::pin_test_env();
    let (_a, a) = driver::fresh_repo(&["git", "init"], &[scenarios::BASE]);
    let keys: Vec<_> = state::capture(&a, None).aspects.into_keys().collect();
    assert_eq!(keys.iter().copied().collect::<BTreeSet<_>>(), state::STATE_ASPECTS.iter().copied().collect());
}
```

  `scenarios::BASE` is created here as the POC's `BASE` constant (in `scenarios.rs`, `mod scenarios;`). Task 3 fills the rest of that file.

- [ ] **Step 2: Run tests to verify they fail**

  Run: `cargo test -p zanshin-parity --test oracle`
  Expected: compile errors (missing modules).

- [ ] **Step 3: Implement `state.rs` and `compare.rs`**
  - Port POC `capture_async` / labels / `normalize` / `normalize_short_ids` / `disk_files` / `target_labels` / `tree_text`, without the `"op args attribute (CLI argv)"` aspect.
  - The repo loader comes from jj-lib directly in the test: `RepoLoader::init_from_file_system(&test_helpers::test_settings(), &root.join(".jj").join("repo"), &default_backend_factories())`, then `load_at_head()`.
  - Port `compare` from the POC, returning the `Vec`.
  - The outcome helpers per the Interfaces above.

- [ ] **Step 4: Run tests to verify they pass**

  Run: `cargo test -p zanshin-parity --test oracle`
  Expected: all pass (Task 1's 3 + these 3).

- [ ] **Step 5: Clippy, fmt, commit**

  Clippy and fmt as in Task 1, Step 7. Commit: `test(zanshin-parity): semantic repo-state capture + aspect comparison (Story 9.47)`.

---

### Task 3: Scenarios, ledger, one test per scenario

**Files:**
- Create:
  - `crates/zanshin-parity/tests/oracle/scenarios.rs` (completes Task 2's file);
  - `crates/zanshin-parity/tests/oracle/ledger.rs`;
  - `crates/zanshin-parity/tests/oracle/harness.rs`.
- Modify: `tests/oracle/main.rs` (`mod ledger; mod harness;` plus the scenario tests).

**Interfaces:**
- Consumes: `driver`, `state::{capture, State, STATE_ASPECTS}`, `compare::*`.
- Produces:
  - `scenarios.rs`:
    - `pub struct Scenario { pub id: &'static str, pub init: &'static [&'static str], pub setup: &'static [Step], pub files: &'static [(&'static str, &'static str)], pub zanshin: fn(&mut zanshin_jj::Repo, &Path, &State) -> Outcome, pub cli: fn(&State) -> Vec<String>, pub extra: Option<fn(&Path) -> String> }`;
    - `pub fn scenarios() -> Vec<Scenario>`;
    - `pub const INIT_SCENARIOS: &[(&str, &[&str])]`.
  - `harness.rs`: `pub fn run(id: &str) -> Vec<Divergence>`. It runs a mutating scenario or an init scenario by id. It panics on an unknown id, and on setup drift with "setup differs in <aspect>".
  - `ledger.rs`:
    - `pub struct Expected { pub scenario: &'static str, pub aspect: &'static str, pub reason: &'static str, pub reference: &'static str }`;
    - `pub const LEDGER: &[Expected]`;
    - `pub fn assert_matches_ledger(scenario: &str, found: &[Divergence])`.

- [ ] **Step 1: Port the scenario table** from the POC `scenarios()`. Assign these stable ids, in the POC's order:

  | # | id |
  |---|---|
  | 1 | `describe_gui_text` |
  | 2 | `describe_cli_text` |
  | 3 | `new_on_wc` |
  | 4 | `new_merge` |
  | 5 | `new_conflicting_merge` |
  | 6 | `abandon_middle` |
  | 7 | `abandon_wc` |
  | 8 | `edit_parent` |
  | 9 | `undo_after_describe` |
  | 10 | `bookmark_create` |
  | 11 | `bookmark_create_existing` |
  | 12 | `bookmark_delete` |
  | 13 | `config_set_repo` |
  | 14 | `config_set_with_dirty_wc` |
  | 15 | `snapshot_modified_file` |
  | 16 | `snapshot_then_describe` |
  | 17 | `describe_immutable` |
  | 18 | `describe_root` |
  | 19 | `describe_no_change` |
  | 20 | `describe_commit_trailers` |
  | 21 | `restore_from` |
  | 22 | `restore_no_args` |
  | 23 | `absorb` |
  | 24 | `undo_cross_workspace` |

  `INIT_SCENARIOS`:
  - `("init_colocated", &["git", "init"])`;
  - `("init_no_colocate", &["git", "init", "--no-colocate"])`.

  Keep each scenario's POC setup, files, Zanshin call and CLI argv unchanged. `config_set_repo`'s `extra` reads back through `driver::jj` (`config get`, `config path --repo`, the file's text).

- [ ] **Step 2: Write `ledger.rs` LEDGER** with exactly these entries:

  | scenario | aspect | reason | reference |
  |---|---|---|---|
  | `describe_gui_text` | `descriptions` | Repo::describe stores the caller's text verbatim; the CLI's `-m` ends it with a newline | Story 10.15 design question (c) |
  | `describe_no_change` | `ops written` | finish_verb has no `has_changes()` gate | Story 9.40 |
  | `describe_no_change` | `op descriptions` | same | Story 9.40 |
  | `describe_no_change` | `op attributes (except args)` | same | Story 9.40 |
  | `describe_no_change` | `op is_snapshot/workspace_name` | same | Story 9.40 |
  | `describe_commit_trailers` | `descriptions` | `templates.commit_trailers` never applied | deferred-work.md "Surfaced 2026-10-08 while analysing …" |
  | `new_conflicting_merge` | `warnings` | the CLI's "There are unresolved conflicts" status line has no Zanshin warning code | docs/rust-error-codes.md |
  | `init_colocated` | `colocated (.git dir)` | Repo::init(Git) never colocates; `jj git init` does by default | Story 9.20 |

  If an aspect name was renamed in Task 2, use the Task 2 name. The ledger names aspects exactly as `STATE_ASPECTS` / `OUTCOME_ASPECTS` do.

- [ ] **Step 3: Write the failing tests** in `main.rs`

```rust
#[test]
fn ledger_names_only_known_scenarios_and_aspects() {
    let ids: BTreeSet<&str> = scenarios::scenarios().iter().map(|s| s.id)
        .chain(scenarios::INIT_SCENARIOS.iter().map(|(id, _)| *id)).collect();
    let aspects: BTreeSet<&str> = state::STATE_ASPECTS.iter().chain(compare::OUTCOME_ASPECTS).copied().collect();
    for e in ledger::LEDGER {
        assert!(ids.contains(e.scenario), "ledger names unknown scenario {}", e.scenario);
        assert!(aspects.contains(e.aspect), "ledger names unknown aspect {}", e.aspect);
    }
}

/// One `#[test]` per scenario id, so they run in parallel and fail individually. The same id
/// list also yields `SCENARIO_IDS`, so a table entry without a test cannot slip through.
macro_rules! parity { ($($id:ident),* $(,)?) => {
    const SCENARIO_IDS: &[&str] = &[$(stringify!($id)),*];
    $(
        #[test] fn $id() {
            test_helpers::pin_test_env();
            let found = harness::run(stringify!($id));
            ledger::assert_matches_ledger(stringify!($id), &found);
        }
    )*
} }
parity!(describe_gui_text, describe_cli_text, /* … all 24 table ids in table order … */ undo_cross_workspace, init_colocated, init_no_colocate);

#[test]
fn every_scenario_has_a_test() {
    let ids: BTreeSet<&str> = scenarios::scenarios().iter().map(|s| s.id)
        .chain(scenarios::INIT_SCENARIOS.iter().map(|(id, _)| *id)).collect();
    assert_eq!(SCENARIO_IDS.iter().copied().collect::<BTreeSet<_>>(), ids);
    assert_eq!(SCENARIO_IDS.len(), 26);
}
```

- [ ] **Step 4: Run tests to verify they fail**

  Run: `cargo test -p zanshin-parity --test oracle`
  Expected: compile errors (`harness`, `ledger` missing).

- [ ] **Step 5: Implement `harness::run` and `ledger::assert_matches_ledger`**

  `harness::run` ports the POC's `run_scenario` / `run_init_scenario`:
  - Two `fresh_repo`s with `[BASE, setup]`, then `Repo::open(root_a)`.
  - Capture before. On setup drift, panic.
  - Write the `files` into both repos.
  - The Zanshin op on A, the CLI argv on B.
  - Capture after; extend with `outcome_aspects`; insert `extra` on both sides if set.
  - `compare`.
  - Run the body on a 16 MiB scoped thread (POC's `on_big_stack`), because debug-build jj-lib call trees exceed libtest's 2 MiB.

  `assert_matches_ledger` collects two lists:
  - **unexpected:** found aspects without a ledger entry for this scenario;
  - **stale:** ledger entries for this scenario with no matching divergence.

  It panics if either is non-empty. The message is a block per item: `UNEXPECTED <aspect>\n  zanshin: …\n  cli    : …` / `STALE <aspect> (<reference>): no longer diverges — remove it from LEDGER`.

- [ ] **Step 6: Run tests to verify they pass**

  Run: `cargo test -p zanshin-parity --test oracle`
  Expected: all pass (26 scenario tests + ledger + coverage-of-ids + the Task 1/2 tests).

  If a divergence appears that is not in the POC's 27-row table, STOP. Report it with its aspect diff; it is either a regression since the POC or a capture bug. Do not ledger it without Ralph.

- [ ] **Step 7: Prove the gate bites (dev-time, NOT committed)**
  - (a) Change `describe_cli_text`'s argv to `-m "C described!"`. Expect that test to fail with `UNEXPECTED descriptions`.
  - (b) Comment out the `describe_commit_trailers` ledger entry. Expect `UNEXPECTED descriptions`.
  - (c) Re-add it under `describe_cli_text` instead. Expect `STALE descriptions`.
  - Revert all three, then `git diff --stat crates/zanshin-parity` shows only intended changes.

- [ ] **Step 8: Clippy, fmt, commit**

  Clippy and fmt as before. Commit: `test(zanshin-parity): parity scenarios + failing ledger (Story 9.47)`.

---

### Task 4: Rules, docs, gate run, story close-out

**Files:**
- Modify:
  - `_bmad-output/project-context.md` (lines ~168-176 § zanshin-jj rule + test-only importer list, ~592 Anti-Patterns line, plus a new "Pin bump" bullet in § zanshin-jj);
  - `CLAUDE.md:35` (reference-tag sentence: also `jj-cli`);
  - `_bmad-output/planning-artifacts/epics.md` (Story 9.47: append "Implementation notes (as built)" with the measured gate cost);
  - `_bmad-output/implementation-artifacts/sprint-status.yaml` (9-47 → `done` with a DONE summary; `last_updated`).

- [ ] **Step 1: project-context.md edits** (exact wording)
  - Rule at ~168: keep the production ban. Add: "Tests may also run `crates/zanshin-parity`'s pinned `jj` (stock CLI built from crates.io `jj-cli` at the `jj-lib` pin) — the parity oracle, Story 9.47."
  - Importer list at ~171-176: add `crates/zanshin-parity` (test-only; coverage `exclude_prefix`), next to `xtask` and `test-helpers`.
  - New bullet "**Pin bump (jj-lib).**" with these steps:
    1. Bump `jj-lib` and `jj-cli` together in `[workspace.dependencies]`.
    2. Bump the `../jj` reference tag (CLAUDE.md).
    3. Run `cargo make test`.
    4. Triage every parity-oracle failure: port the change, ledger it with a reason and reference, or open a story. A STALE entry means a gap closed; remove it.
    5. Hand-audit what the oracle cannot see: read verbs, refusal and warning codes, network and interactive verbs.
  - Anti-Patterns line ~592: same test exception, one clause.

- [ ] **Step 2: CLAUDE.md:35** — "Bump the reference tag in lockstep when the `jj-lib` pin moves" → "… when the `jj-lib` / `jj-cli` pin moves (the parity oracle runs the stock CLI at that pin)."

- [ ] **Step 3: Full gate from the main session**
  - Run `df -h /Users/ralph.bergmann` first. Expected: enough free space (≥ 6 GiB). If not, stop and tell Ralph.
  - Run: `cargo make test` (unpiped, so the exit code is real).
  - Expected: exit 0, including coverage (`coverage-check: OK`), `test-cargo-hygiene`, `test-cargo-deny`.
  - Then check that `~/.config/jj/repos` and `~/.config/jj/workspaces` have no entry newer than the gate start (`ls -l --sort=modified … | tail -3`).

- [ ] **Step 4: Measure and record the gate cost**
  - Cold: `cargo build -p zanshin-parity --tests` after `cargo clean -p jj-cli` (time it).
  - Warm: `cargo test -p zanshin-parity` (time it).
  - Write both numbers into Story 9.47's "Implementation notes (as built)" and the sprint-status DONE summary. Also write in any deviation from this plan.

- [ ] **Step 5: Commit**

  `docs(project-context): test exception + pin-bump procedure for the parity oracle; close Story 9.47`.

  Include `coverage-baseline.txt` if the gate rewrote it. Check `git status` first.
