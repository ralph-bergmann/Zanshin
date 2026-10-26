---
title: 'Story 9.41 closing run: a `--when.commands` witness for every call site, scoped verbs in the oracle'
type: 'chore'
created: '2026-10-25'
status: 'done'
baseline_revision: 'acb24d8fcd08cc8fec9210de52a4784ca1249fdf'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
warnings: ['oversized']
deferred:
  - summary: >-
      `Repo::parallelize` on the root commit panics in jj-lib (`assertion failed: !old_ids.is_empty()`), as the pinned `jj parallelize 'root()'` does; over FFI it surfaces as `internal.panic`.
    evidence: |-
      Found while writing the per-verb witness: `parallelize(&[<root change id>])` hits jj-lib 0.46.0 `repo.rs:1203`. Reproduced with the parity binary (`target/debug/jj parallelize 'root()'` in a fresh non-colocated repo): the same panic. Pre-existing, an upstream bug Zanshin mirrors; the FFI's `catch_unwind` turns it into `internal.panic` instead of a typed refusal.
    location: >-
      crates/zanshin-jj/src/repo.rs (parallelize); jj-lib 0.46.0 src/repo.rs:1203
    severity: low
    resolved: >-
      2026-10-26 — fixed (spec-loop-9-25-9-46-leftover-a-prefix-gitconfig-root-native, commit b46a030): a set containing the root commit is refused as immutable before jj-lib is reached (listed as a deliberate divergence).
---

<intent-contract>

## Intent

**Problem:** Story 9.41 deferred item 1: the `cli_command.rs` audit test proves every table name is a canonical CLI command, not that each call site picks the right one — swapping `remote_changes` to `NO_COMMAND`, `convert_colocated` to `GIT_CLONE` or `squash` to another entry passes every test; and the parity oracle's verb scenarios cannot run under a user config, so no scoped verb is compared with `jj`.

**Approach:** Test-only. (a) An inline `repo.rs` test drives every `&mut self` `Repo` verb once (any arguments; the result is ignored) after resetting `Repo.command` to a sentinel, and asserts the table entry it recorded — `refresh_settings` records the command first, on every path. (b) The `&self` `log` reads `revset_counts` / `find_changes` join the existing `log`-reads witness. (c) The free `config_*` verbs get a witness through their start-up's deprecation warnings: a scope for the verb's command holding a deprecated key warns `ConfigDeprecated`, a scope for another command does not. (d) The oracle's `Scenario` gains `user_config` (as `CreationScenario` has), plus a `["describe"]`-scoped `templates.commit_trailers` describe scenario and `["git init"]`-scoped refs-step faults for `convert_colocated` / `convert_import`.

## Boundaries & Constraints

**Always:** The expected names are the ones Story 9.41's Design Notes assign (shared reads named after the CLI command whose output they replace; `select_tree` / `drop_actions` / `change_actions` / `Repo::open` = `NO_COMMAND`). A scenario with a user config runs in its own process (`own_process:` list) and installs the config only AFTER both repos are built and captured, removing it before the read-back — the CLI-built setup and the capture run under the pinned empty config.

**Never:** No production-code change (if a witness exposes a wrong mapping, fix that call site — that is a 9.41 bug, the item's point); no FFI/schema/Dart change; no change to the 9.41 deferred items about `NO_COMMAND` for `select_tree`/`drop_actions`/`change_actions` or the pin-bump checklist; no ledger entries for new scenarios (they must match).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Swapped call site | any `Repo` verb's table entry changed | the inline test fails naming that verb | — |
| Verb refuses early | e.g. `with_checked_verb` clap refusal, unknown change id | the command is still recorded (refresh runs first) | result ignored |
| Config verb scope | user file `[[--scope]] --when.commands=["config get"]` with `fix.tools.t.line-range-arg` | `config_get` warns `ConfigDeprecated`; under a `["describe"]` scope it does not | the verb's own error (e.g. unset of a missing key) does not matter |
| Scoped describe (oracle) | user config scopes `templates.commit_trailers` to `["describe"]` | Zanshin and `jj describe -m T` both add the trailer | — |
| Scoped convert (oracle) | `["git init"]`-scoped broken `remotes.origin.auto-track-bookmarks` | `convert_colocated` / `convert_import` refuse like `jj git init --colocate` / `--git-repo` | both refuse after `init_external_git` |

</intent-contract>

## Code Map

- `crates/zanshin-jj/src/cli_command.rs` -- the table (read-only reference for expected names; `NO_COMMAND`).
- `crates/zanshin-jj/src/repo.rs` -- `Repo.command` field (:219), `command()` getter (:308), `refresh_settings` records first (:344); public verbs :613-4400 (signatures listed by `grep -n "^    pub fn " repo.rs`); inline `mod tests` (:4586, `open_fixture()` = `tiny-3-commits` copy) -- add the per-verb test here. `move_working_copy`/`movement_targets` take `options.direction.cli_command()` (`Direction::Next`/`Prev`, default `Next`). `remote_changes` calls `refresh_settings(GIT_FETCH)` directly (:2000). `log_defaults`/`revset_counts`/`find_changes`/`commit_contents` are `&self` (no recording).
- Option types: `SquashOptions`, `SplitOptions`, `RebaseOptions`, `ArrangeOptions`, `MetaeditOptions`, `RevertOptions`, `CommitOptions`, `DiffeditOptions`, `OpDiffOptions`, `SelectTreeOptions`, `BookmarkListOptions`, `BookmarkMoveOptions`, `GitPushArgs`, `GitFetchArgs`, `DuplicateOptions`, `FixOptions`, `MovementOptions`, `SimplifyParentsOptions`, `ResolveListOptions` derive `Default`; `ResolveOptions { revision, paths, tool: ResolveTool::Ours }` does not; `ChangeId(String)`, `OperationId(String)`; `DropSource`/`DropLocation`/`RevisionRef` are enums (`drop_actions.rs`, `commit_views.rs`).
- `crates/zanshin-jj/tests/it/when_commands.rs` -- own-process witnesses; `isolate()` returns the user file; `the_log_reads_resolve_for_log_whatever_ran_before` (:171) -- extend with `revset_counts` / `find_changes` on `scoped_at()`; add the config-verb witness test here.
- `crates/zanshin-jj/src/config_cmd.rs` -- `config_list|get|path|set|unset|file_read|file_write|gc_list|gc_delete` (:367-503); `startup` (:569) and `startup_deprecations` (:556) extend `deprecation_warnings`; `ConfigOutcome { result, warnings }`, `ConfigSetOutcome` (check its warnings field). Deprecated key known to warn: `fix.tools.t.line-range-arg` (`tests/it/config_cmd.rs:517`).
- `crates/zanshin-parity/tests/oracle/scenarios.rs` -- `Scenario` (:78), `simple()` (:97; 229 of 238 literals spread it), `describe_commit_trailers` (:1166) as the model.
- `crates/zanshin-parity/tests/oracle/harness.rs` -- `run_scenario` (:39), `run_creation`'s `set_user_config` / reset (:97-106) -- reuse for verb scenarios.
- `crates/zanshin-parity/tests/oracle/git_scenarios.rs` -- `CREATION_SCENARIOS` (:103), `BROKEN_AUTO_TRACK` (:327), `convert_*_refs_step_config_fault` (:269-285) as the models; `Scenario` literals in `*_scenarios()` fns need the new field.
- `crates/zanshin-parity/tests/oracle/main.rs` -- `parity!` lists (own_process ids :480-488), `SCENARIO_IDS.len()` pin (:502, now 430).

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/src/repo.rs` -- inline test `every_verb_resolves_for_its_cli_command`: open the fixture, assert `Repo::open` recorded `NO_COMMAND`, then for each `&mut self` verb (snapshot, status, get_change, op_log, list_bookmarks, list_tags, list_heads, list_working_copies, list_remotes, git_push_remotes, git_fetch_remotes, file_list/show/annotate/search, walk_graph, graph_topology, eval_revset, describe, new_change, edit, abandon, op_show, op_diff, op_abandon, op_restore, op_revert, op_integrate, git_push, git_fetch, remote_changes, git_import, git_export, git_remote_add/remove/rename/set_url, show, evolog, interdiff, list_workspaces, resolve_workspace_root, workspace_update_stale, workspace_add/forget/rename/remove, bookmark_create/delete/move/advance/rename/set/forget/track/untrack, restore, absorb, squash, squash_plan, drop_actions, change_actions, split, rebase, parallelize, arrange, simplify_parents, metaedit, move_working_copy + movement_targets in both directions, duplicate, revert, fix, commit, select_tree, resolve_list, resolve, diffedit, file_track, file_untrack, file_chmod, undo, redo) reset `repo.command` to a sentinel, call it, assert the expected table entry with the verb named in the message. Prefer refusing arguments (unknown ids `zzzzzzzz`, missing remotes) so nothing slow runs; history-changing verbs last.
- `crates/zanshin-jj/tests/it/when_commands.rs` -- extend the `log`-reads test: under the `["describe"]` scope `revset_counts(op, ["scoped_at()"])` yields an error entry and `find_changes(op, "scoped_at()")` fails; under `["log"]` both resolve `@`. Add `every_config_verb_resolves_for_its_cli_command` (own_process): for each config verb, a user file scoping `fix.tools.t.line-range-arg` to its command makes its warnings contain `ConfigDeprecated`, a `["describe"]` scope does not.
- `crates/zanshin-parity/tests/oracle/scenarios.rs` -- `Scenario.user_config: Option<&'static str>` (doc as on `CreationScenario`), `None` in `simple()` and every other literal; new `describe_when_commands_trailers`.
- `crates/zanshin-parity/tests/oracle/git_scenarios.rs` -- `user_config: None` on its `Scenario` literals; creation scenarios `convert_colocated_when_commands_refs_fault`, `convert_import_when_commands_refs_fault` (`["git init"]`-scoped `BROKEN_AUTO_TRACK`).
- `crates/zanshin-parity/tests/oracle/harness.rs` -- `run_scenario` installs `user_config` after the before-capture, resets before the after-capture (as `run_creation`).
- `crates/zanshin-parity/tests/oracle/main.rs` -- the three ids under `own_process:`, the count pin 433.

**Acceptance Criteria:**
- Given any `&mut self` `Repo` verb, when its table entry is swapped for another, then `cargo test -p zanshin-jj --lib` fails naming it.
- Given a config verb whose start-up passed another command, when the witness runs, then it fails naming that verb.
- Given the three new oracle scenarios, when the oracle runs, then they match with no ledger entry; with `convert_colocated`'s command swapped to `GIT_CLONE` (or the describe call to `NEW`), the matching scenario fails.

## Verification

**Commands:**
- `cargo test -p zanshin-jj --lib repo::tests` -- expected: pass
- `cargo test -p zanshin-jj --test it when_commands::` -- expected: pass
- `cargo test -p zanshin-parity --test oracle` -- expected: pass (433 scenarios)
- `cargo clippy -p zanshin-jj -p zanshin-parity --all-targets -- -D warnings`; `cargo fmt --all --check` -- expected: clean

**Verification run (2026-10-25; the full gate is the story loop's, not run here):**
- `cargo test -p zanshin-jj --lib` -- 396 passed (incl. `repo::tests::every_verb_resolves_for_its_cli_command`)
- `cargo test -p zanshin-jj --test it when_commands::` -- 8 passed (after the review patches)
- `cargo test -p zanshin-parity --test oracle` -- 452 passed, 433 scenarios (before the review patches; those touched only doc comments in the oracle, compile-checked by clippy)
- `cargo clippy -p zanshin-jj -p zanshin-parity --all-targets -- -D warnings` -- clean; `cargo fmt --all --check` -- clean
- Mutation checks (each reverted, `git diff` clean on the production files): `remote_changes` → `NO_COMMAND` fails the inline test naming it; `config_unset`'s start-up → `CONFIG_SET` fails the config witness; convert → `GIT_CLONE` and describe → `NEW` fail the three new oracle scenarios; `check_wc_author` → `UTIL_SNAPSHOT` fails `the_config_set_author_check_snapshots_for_config_set`; `convert_colocated`'s start-up check and `convert_import`'s new-workspace settings → `GIT_CLONE` fail `the_conversions_resolve_for_git_init`.
- No FFI/schema/Dart change, so no `cargo make codegen` / Dart checks. Coverage not measured (gate rule); only tests were added.

## Review Triage Log

### 2026-10-25 — Review pass
- verdicts: 15 findings — high 0, medium 0, low 12, false 3, maybe-false 0
- findings:
  - `low` `reject` (blind-hunter) the new oracle scenarios could pass vacuously if the CLI ignored the scoped config — the mutation checks show all three diverge when Zanshin resolves for the wrong command, so the CLI side does apply the scope; a sanity assert adds code for a hand-off failure nobody has met, the same shape as 9.41's `init_when_commands_*` scenarios.
  - `low` `reject` (blind-hunter) no negative "other command" oracle scenario for describe / the conversions — scope matching is jj-lib's, and the negative halves are witnessed in `zanshin-jj` (`a_describe_scope_reaches_describe_and_no_other_verb`, the `git clone` arm of `the_conversions_resolve_for_git_init`, `init_when_commands_other_command`).
  - `low` `patch` (blind-hunter) `check_wc_author`'s `snapshot_as(CONFIG_SET)` is unwitnessed — added `the_config_set_author_check_snapshots_for_config_set` (a `["config set"]`-scoped `snapshot.max-new-file-size` reaches the author check's snapshot, a `["describe"]` one does not).
  - `low` `patch` (blind-hunter) nothing reminds a new verb to join the per-verb witness — `cli_command.rs`'s module doc and the inline test's doc now point at both witnesses.
  - `low` `patch` (blind-hunter) `main.rs` `parity!` doc and `driver.rs` `command` doc still say only creation scenarios carry a user config — both now name operation scenarios (Story 9.41).
  - `low` `reject` (blind-hunter) `run_scenario` creates an unused temp dir per scenario — one empty dir beside two CLI-built repos per scenario is noise; avoiding it needs `Option` plumbing.
  - `low` `patch` (blind-hunter) the inline test's comment claims only refusing arguments — rewritten: names the calls that act on the fixture and why that is harmless (only the recorded command is asserted).
  - `low` `patch` (blind-hunter) the `log`-reads negative accepts any error — `find_changes` must now fail `RevsetSearchError::Revset`; `revset_counts`' entry is already a per-expression revset error.
  - `low` `patch` (edge-case-hunter) `op_log` ran between `describe` and the `log` reads, so the negative half no longer followed a describe — the op id is taken before the describe.
  - `low` `patch` (edge-case-hunter) `find_changes` negative accepts any error variant — same root as the blind-hunter row; same fix.
  - `low` `patch` (verification-gap) `config set`'s author-check snapshot has no witness — same root as the blind-hunter row; same test.
  - `false` `reject` (intent-alignment) the per-verb test checks the recorded field, not the scoped resolution — the field is what every load of the call resolves for (`start_command` → `config::load_migrated(self)`), one shared path already witnessed end to end by the describe / fetch / push / log / clone tests; a swap at a call site changes exactly the recorded field.
  - `false` `reject` (intent-alignment) the expected names come from 9.41's Design Notes, not the CLI — the item is swap detection; each name is the CLI command the verb replaces (9.41's reviewed mapping, audited against the clap tree); no wrong name was identified.
  - `low` `patch` (intent-alignment) the conversions are witnessed per function, a swap at the start-up check or the new-workspace settings would pass — added `the_conversions_resolve_for_git_init` (a `["git init"]`-scoped fault refuses `Config` before the path checks; a `["git init"]`-scoped operation user signs both conversions); the refs step stays the oracle's.
  - `false` `reject` (intent-alignment) the Auto Run Result and ledger are not in the reviewed diff, and the epic-context edit is unrelated — the ledger is this run's finalization commit; the epic-context refresh is step-01's mandatory recompile (epics.md was newer), committed on its own.

## Auto Run Result

Status: done

**Summary.** Test-only closing run for Story 9.41's deferred item 1; no production code changed — every call site already picked the right table entry. Every `&mut self` `Repo` verb is pinned to the CLI command it records; the free config verbs, `config set`'s author-check snapshot, the conversions' start-up and new-workspace settings, and the `log`-pinned `&self` reads (`revset_counts`, `find_changes`) get scoped-config witnesses; the parity oracle's operation scenarios take a `user_config`, with a `["describe"]`-scoped trailer scenario and `["git init"]`-scoped refs-step faults for both conversions — all match the stock CLI with no ledger entry.

**Items:**
- 1 (most verbs' command choice has no `--when.commands` witness; the oracle compares only creation scenarios with a user config) -- fixed (4fddf6e504375fe92c0b016542705ec1b4ec6b5c).

**Files changed (code commit 4fddf6e):**
- `crates/zanshin-jj/src/repo.rs` -- inline `every_verb_resolves_for_its_cli_command` (sentinel reset, one line per verb, both movement directions, both `resolve_workspace_root` arms, `Repo::open` = `NO_COMMAND`).
- `crates/zanshin-jj/src/cli_command.rs` -- module doc points at the two per-site witnesses.
- `crates/zanshin-jj/tests/it/when_commands.rs` -- `revset_counts` / `find_changes` in the `log`-reads witness; `every_config_verb_resolves_for_its_cli_command`; `the_config_set_author_check_snapshots_for_config_set`; `the_conversions_resolve_for_git_init`.
- `crates/zanshin-parity/tests/oracle/{scenarios,harness,git_scenarios,main,driver}.rs` -- `Scenario.user_config` (installed around the operation only), `describe_when_commands_trailers`, `convert_colocated_when_commands_refs_fault`, `convert_import_when_commands_refs_fault`, count pin 433, docs.
- Epic context refresh (65eac3f): `_bmad-output/implementation-artifacts/epic-9-context.md`.

**Review:** 15 findings (high 0, medium 0, low 12, false 3). Patched (all low, 6 entries): `config set` author-snapshot witness, conversion per-site witness, the `log`-reads negative ordering and error variant, stale oracle docs, the inline test's comment, pointers for new verbs. Rejected: vacuous-oracle sanity asserts (mutation checks show discrimination), negative oracle pairs (witnessed in `zanshin-jj`), the per-scenario temp dir (negligible), field-vs-resolution surface (one shared path, witnessed), names from 9.41's mapping (no wrong name), ledger not in the diff (finalization). Deferred (new, mirrored to deferred-work.md): `parallelize` on the root commit panics in jj-lib, as the pinned CLI does.

**Follow-up review recommended:** false — no high or medium entry was patched (patched: 6 low entries).

**Residual risks:** a verb added later is witnessed only if its author adds its line (the docs now say so; no enumeration guard); `Repo::init`/`clone`'s individual config sites keep 9.41's function-level witnesses (not in this item's evidence); the full gate (incl. the coverage ratchet) runs at the end of the story loop.
