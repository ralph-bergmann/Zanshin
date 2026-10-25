---
title: 'Story 9.41: `--when.commands` config scopes apply per verb'
type: 'bugfix'
created: '2026-10-25'
status: 'done'
baseline_revision: '3ac22d761898700dcee46392994c6d4498331e11'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
warnings: ['oversized']
deferred:
  - summary: >-
      `select_tree`, `drop_actions` and `change_actions` still resolve with no CLI command, so a scope for the verb they serve (`["split"]`, `["rebase"]`, …) does not reach their snapshot, tree or preview rows.
    evidence: |-
      Pre-existing (every call resolved with `command: None` before Story 9.41); the story left these three on `NO_COMMAND` because one call serves several verbs. In the CLI the builtin diff editor runs inside `jj split -i`/`squash -i`/`commit -i`/`restore -i`, under that verb's settings, and each drop row's verb resolves its own scopes. Closing it needs the target verb passed in (`SelectTreeOptions` / a per-row resolution) — an FFI-visible input.
    location: >-
      crates/zanshin-jj/src/repo.rs (select_tree, drop_actions, change_actions); crates/zanshin-jj/src/cli_command.rs NO_COMMAND
    severity: low
  - summary: >-
      Most verbs' command choice has no `--when.commands` witness; only describe, new, status, git fetch/push remotes, log reads, init and clone do, and the oracle compares only creation scenarios with a user config.
    evidence: |-
      The audit test proves each table name is a canonical CLI command, not that each call site uses the right one: swapping e.g. `remote_changes` to `NO_COMMAND`, `convert_colocated` to `GIT_CLONE` or `squash` to `SPLIT` passes every test. The oracle's verb scenarios have no `user_config` field, so no scoped verb runs against the stock CLI.
    location: >-
      crates/zanshin-jj/src/repo.rs call starts; crates/zanshin-parity/tests/oracle/scenarios.rs
    severity: low
    resolved: >-
      2026-10-25 — fixed (spec-9-41-closing-when-commands-witness-per-call-site, commit 4fddf6e): an inline test asserts the command every `Repo` verb and `Repo::open` records, scoped witnesses cover the `config_*` verbs, the author-check snapshot, both conversions and the `log` reads, and the oracle runs `describe`/`convert_*` scenarios under a scoped user config (all call sites were already right).
  - summary: >-
      project-context.md's jj pin-bump checklist does not name the new CLI command table.
    evidence: |-
      `crates/zanshin-jj/src/cli_command.rs`'s audit test catches a renamed or removed command at a pin bump, but not a new CLI verb or a changed verb-to-command mapping; the checklist in project-context.md § zanshin-jj is an agent-context file, so the edit is deferred.
    location: >-
      _bmad-output/project-context.md § zanshin-jj (pin-bump steps)
    severity: low
---

<intent-contract>

## Intent

**Problem:** A jj config table scoped with `[[--scope]] --when.commands = [...]` never applies in Zanshin outside the `config_*` verbs: every verb, creation path and named read resolves the stack with `command: None` (`config.rs::load_with_migrated` → `resolve_raw(.., None)`), while the CLI names the command before its final start-up resolution (`config_env.set_command_name(command_name(&matches))`, `cli/src/cli_util.rs:4701` @ v0.46.0) and `settings_for_new_workspace` clones that env (`:378-394`). So a `["describe"]`-scoped identity, a `["git init"]`-scoped `git.colocate`, a `["git"]`-scoped `git.fetch` are ignored and Zanshin writes what the CLI would not. (deferred-work I1, I2.)

**Approach:** One table of CLI command names (`crates/zanshin-jj/src/cli_command.rs`), audited against the pinned jj-cli's clap tree by a unit test; every verb passes its name into the call's start (`with_verb*`, `start_call`/`start_command`, `refuse_before_snapshot`, `refresh_settings`), the creation checks and named reads, so `resolve_raw` gets `context.command`. The per-verb refresh reloads the `Workspace` when the fingerprint changed OR the stack resolved for this call's command differs from the one the settings were built from — no command scopes → identical resolution → no reload.

## Boundaries & Constraints

**Always:**
- Names are the CLI's canonical clap subcommand chains joined by spaces (`command_name`, `cli_util.rs:4358-4368` @ v0.46.0), e.g. `"git clone"`, `"bookmark create"`, `"util snapshot"`.
- Matching is jj-lib's own (`config_resolver.rs::matches_command`): prefix by whole words; a scope with `--when.commands` never matches a call with no name.
- Creation paths: `init`/`convert_colocated`/`convert_import` = `"git init"`, `clone` = `"git clone"` — for `check_startup_stack`, `user_settings_for_new_workspace` and every `load_for_workspace` of the creation.
- The 9.28 config verbs use the same table instead of string literals.
- Calls no CLI command corresponds to resolve with no name (`NO_COMMAND`, the state the CLI resolves in before a subcommand is known): `Repo::open`/`open_with_report`, `select_tree` (the builtin editor of several verbs), `drop_actions`/`change_actions` (rows of several verbs). Reads that replace one CLI command's output take that command (see Design Notes).

**Never:** No `[aliases]` expansion, no `--config`/`--config-file` layer, no FFI/schema/Dart change (no API change), no change to the fingerprint itself, no unconditional per-verb reload.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Scoped describe | user config `[[--scope]] --when.commands=["describe"]` sets `user.email`, `operation.username` (identity env vars removed) | `describe` writes committer email + op username from the scope; a following `new_change` writes the base identity | — |
| Prefix | scope `["git"]` sets `git.fetch = "upstream"`, remotes origin+upstream | `git_fetch_remotes` → `[upstream]`; a `["git push"]` scope does not reach `git_fetch_remotes` | — |
| Scoped init | scope `["git init"]` sets `git.colocate = false` | `Repo::init` (colocate unset) creates a non-colocated repo, as `jj git init`; a `["git clone"]` scope leaves init colocated | — |
| Scoped clone | scope `["git clone"]` sets `operation.username` | the clone's head operation carries it | — |
| No scopes | two different verbs in a row, unchanged stack | no workspace reload | — |
| Bad scoped value | scope for the call's command with a wrong-typed `user.name` | that verb refuses `Config` as the CLI's start-up does; other verbs unaffected | `MutateError::Config` / `RepoError::Config` |

</intent-contract>

## Code Map

- `crates/zanshin-jj/src/config.rs` -- `load_with`/`load_with_migrated` (:885-895) resolve with `None`; `resolve_raw` (:1000) already takes `command`; `load`/`load_migrated` (:1140-1161), `user_settings_for` (:1209), `check_startup_stack` (:1238), `user_settings_for_new_workspace` (:1259), `load_for_workspace` (:1425); `fix_up_secure_config` (:960) already builds the raw stack and drops it. Module doc :125-129 documents `command: None` — rewrite. Inline tests call `load_with(&env, ..)` (~:3094-3300).
- `crates/zanshin-jj/src/repo.rs` -- `Repo` fields (:194-208, add the call's command next to `trunk_fallback`); `load_effective` (:247); `refresh_settings` (:314, fingerprint-only reload); `start_call`/`start_command` (:404-436); `with_verb`/`with_checked_verb`/`refuse_before_snapshot`/`with_verb_stats` (:491-550); ~86 verb call sites; `remote_changes` (:1903) calls `refresh_settings` directly; `log_defaults` (:836), `revset_counts`/`find_changes` (:1207/:1238, `&self`, op-pinned) load config outside a call.
- `crates/zanshin-jj/src/revset_search.rs` -- `config::load(repo)` at :197/:240 (`&self` reads) → explicit `"log"`.
- `crates/zanshin-jj/src/creation.rs` -- `workable_env` (:132), `init_steps` (:249/:261), `init_native` (:302), `clone_steps` (:381), `clone_into_workspace` (:490), `fetch_new_remote` (:628).
- `crates/zanshin-jj/src/convert.rs` -- `check_startup_stack` (:226/:331), `user_settings_for_new_workspace` (:241/:625), `load_for_workspace` (:662, `init_over_git_dir`, shared with init → `"git init"`).
- `crates/zanshin-jj/src/config_cmd.rs` -- literals `"config list|get|path|set|unset|gc|edit"` (:558, :847-1115); `startup(.., command: &str, ..)` (:568).
- `crates/zanshin-jj/src/lib.rs` -- module list (add `mod cli_command;`).
- jj-cli 0.46.0 (`~/.cargo/registry/src/*/jj-cli-0.46.0`): `commands::default_app()` (pub, `commands/mod.rs:170`) — the clap tree the audit test walks; `cli_util.rs:4646-4760` start-up order.
- `crates/zanshin-jj/tests/it/config_identity.rs` -- own-process pattern for identity witnesses (env removal, `JJ_CONFIG` repoint, `head_facts`).
- `crates/zanshin-parity/tests/oracle/git_scenarios.rs` -- `CREATION_SCENARIOS` with `user_config` (:96-300); `main.rs` `parity!` `own_process:` list.

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/src/cli_command.rs` (new) -- `pub(crate) type CliCommand = Option<&'static str>`; one macro-built table of `pub(crate) const NAME: CliCommand = Some("...")` (comment per entry: the Zanshin verbs it serves, and why for shared reads) plus `NO_COMMAND`, and a `#[cfg(test)]` list of all names; unit test walks `jj_cli::commands::default_app()` and asserts each name is a canonical subcommand path -- the one audited table.
- `crates/zanshin-jj/src/config.rs` -- thread `command: CliCommand` through `load_with`/`load_with_migrated`, `user_settings_for`, `check_startup_stack`, `user_settings_for_new_workspace`, `load_for_workspace`; `load_migrated(repo)` uses the repo's current command; add `load_for(repo, command)` for `&self` reads; `fix_up_secure_config` returns the raw stack; add a `same_resolution(a, b)` comparison (layer count, then per layer `Arc::ptr_eq` or equal source+path+`data.to_string()`); update module doc and inline tests; unit-test `same_resolution` and a command-scoped resolution.
- `crates/zanshin-jj/src/repo.rs` -- `Repo.command` field; `load_effective(root, command, ..)`; `refresh_settings(command, warnings)` reloads when the fingerprint changed or `!same_resolution(resolved-for-command, self.settings.config())`, else records the command; every call start takes its table name; `log_defaults` → `load_for(.., LOG)`; `move_working_copy`/`movement_targets` pick `NEXT`/`PREV` from the direction; doc the rule on `Repo`; inline test: no scopes → the store `Arc` is unchanged across two different verbs, a matching scope → reloaded.
- `crates/zanshin-jj/src/revset_search.rs`, `creation.rs`, `convert.rs`, `config_cmd.rs` -- pass the table names listed above.
- `crates/zanshin-jj/tests/it/when_commands.rs` (new, `own_process!`, registered in `tests/it/main.rs`) -- witnesses: describe/new identity + op username, `["git"]` prefix vs `["git push"]` on `git_fetch_remotes`, `["git clone"]` op username on a local clone, a wrong-typed scoped value refusing only its verb.
- `crates/zanshin-parity/tests/oracle/git_scenarios.rs` + `main.rs` -- two creation scenarios (own process): `init_when_commands_no_colocate` (`["git init"]` scope `git.colocate = false`) and `init_when_commands_other_command` (`["git clone"]` scope, init stays colocated).

**Acceptance Criteria:**
- Given any public `Repo` verb, creation path or config verb, when it resolves the config, then it uses exactly the name the table gives it (compile-enforced: every call start takes a `CliCommand`).
- Given the pinned jj-cli, when the audit test runs, then every table name is a canonical subcommand path of `default_app()` — a pin bump that renames a command fails it.
- Given the two new oracle scenarios, when the oracle runs, then Zanshin and `jj git init` agree (before this story the first diverges).
- Given no `--when.commands` in the stack, when verbs alternate, then the workspace is not reloaded and the per-verb cost stays within noise on `large-10k` (measured, recorded in Verification).

## Review Triage Log

### 2026-10-25 — Review pass
- verdicts: 26 findings (15 blind-hunter, 4 edge-case-hunter, 3 verification-gap, 4 intent-alignment divergences) — high 0, medium 0, low 22, false 4, maybe-false 0
- findings:
  - (blind-hunter) `low` `patch` `check_wc_author` snapshots under `util snapshot`, not `config set` — the CLI's check runs inside `jj config set`; fixed: `Repo::snapshot_as(command)`, `check_wc_author` passes `CONFIG_SET`.
  - (blind-hunter) `low` `patch` `docs/ffi-abi.md:1444` still says `resolve` runs with `command: None` — sentence rewritten for the per-call command.
  - (blind-hunter) `low` `patch` `same_resolution` doc overstates the pointer fast path (builtin + env layers are rebuilt per load) — doc corrected; no code change.
  - (blind-hunter) `low` `reject` the refresh's resolution is computed then a second load/resolve runs in `start_command` — measured 16 µs per verb on `large-10k` (Verification); removing it needs new plumbing between refresh and start, not worth it.
  - (blind-hunter) `low` `reject` reload cost with a real command scope unmeasured — a reload is one `Workspace::load` (0.3–1 ms, ADR-0002) only when a command scope actually changes the resolution, the same per-invocation cost the CLI pays; no mitigation warranted.
  - (blind-hunter) `false` `reject` `refresh_settings` records the command before it can fail — on failure the call returns before any config load, the settings stay the previous ones as documented, and the next call records its own command; no read observes the stale value.
  - (blind-hunter) `low` `patch` the `git_push_remotes == ["origin"]` assertion proves nothing and `git push` scoping has no positive witness — replaced with a `["git push"]` `git.push` scope reaching `git_push_remotes` and not `git_fetch_remotes`.
  - (blind-hunter) `low` `patch` the named `&self` reads pinned to `log` have no witness — added: after `describe`, a `["describe"]`-scoped `revsets.log` is absent from `log_defaults()`, a `["log"]` one present.
  - (blind-hunter) `low` `defer` convert paths, the refusal path and `remote_changes` untested under a scope — grouped with the per-site witness gap (deferred).
  - (blind-hunter) `low` `defer` the oracle covers creation only; no scoped verb scenario — same group (deferred).
  - (blind-hunter) `low` `defer` `NO_COMMAND` for `select_tree` / `drop_actions` / `change_actions` is a parity gap — pre-existing (they resolved with none before this story); deferred (needs the target verb as an FFI input).
  - (blind-hunter) `false` `reject` the ledger (sprint-status, deferred-work) is not in the diff — the ledger is updated in this run's finalization commit.
  - (blind-hunter) `low` `defer` the pin-bump checklist does not mention the table — edit of an agent-context file (project-context.md); deferred.
  - (blind-hunter) `low` `reject` `Direction::cli_command` duplicates `Direction::cmd` — the table stays the one audited source of names; a two-arm match beside `cmd` cannot drift unnoticed (now unit-tested).
  - (blind-hunter) `low` `reject` `when_commands.rs` copies helpers from `config_identity.rs` — test-only, matches the house pattern of self-contained own-process test files.
  - (edge-case-hunter) `low` `patch` `check_wc_author` snapshot under the wrong command — same root as the first row; same fix.
  - (edge-case-hunter) `low` `defer` `select_tree` snapshot resolves with no command — same group as the `NO_COMMAND` row (deferred).
  - (edge-case-hunter) `low` `patch` claim "every config verb resolves with exactly its table name" broken by `check_wc_author` — same root; fixed with it.
  - (edge-case-hunter) `low` `patch` `same_resolution` doc claim — same root as the doc row; corrected.
  - (verification-gap) `low` `patch` `Direction::cli_command` unverified — inline unit test added in `movement.rs`.
  - (verification-gap) `low` `patch` `&self` reads pinned to `log` untested — same root as the blind-hunter row; witness added.
  - (verification-gap) `low` `defer` most call sites' command choice has no witness — deferred as filed (breadth of per-verb tests).
  - (intent-alignment) `low` `reject` the `["git clone"]` witness checks only the head operation — the clone's operations all sign with the same `user_settings_for_new_workspace` settings the witness observes; extra assertions add nothing.
  - (intent-alignment) `false` `reject` "no reload" is witnessed on private `refresh_settings`, not public verbs — the inline test drives the exact call start every public verb runs; the observable (store `Arc` identity) is only reachable inline.
  - (intent-alignment) `false` `reject` the `large-10k` cost pin is a recorded measurement, not committed code — 9.27 pinned its cost the same way (a recorded measurement); benches are optional scaffolding.
  - (intent-alignment) `low` `defer` no oracle comparison for the scoped describe — part of the deferred oracle/per-site witness group.

## Design Notes

Shared reads, named after the CLI command whose output they replace: `walk_graph`, `graph_topology`, `eval_revset`, `log_defaults`, `revset_counts`, `find_changes`, `list_heads` → `log`; `get_change` → `show`; `list_working_copies` → `workspace list`; `resolve_list` → `resolve` (`--list`); `squash_plan` → `squash`; `movement_targets` → `next`/`prev`; `git_fetch_remotes` and `remote_changes` (the Fetch button's poll) → `git fetch`; `git_push_remotes` → `git push`. `commit_contents` resolves no config (unchanged).

Reload rule (scope 3): the CLI derives settings per invocation from the stack resolved for its command. Comparing the resolved stacks is exact — jj-lib's `resolve` reuses the original layer `Arc` for unscoped layers (the static `CLI_DEFAULTS` stay pointer-equal), so the text comparison only touches the small per-file layers. The fix-up's raw stack is reused, so no extra file parse per verb.

## Verification

**Commands:**
- `cargo test -p zanshin-jj --lib` -- expected: pass (audit + inline tests)
- `cargo test -p zanshin-jj --test it` -- expected: pass (all modules; every verb's call start changed)
- `cargo test -p zanshin-ffi --test it` -- expected: pass (dependent)
- `cargo test -p zanshin-parity --test oracle` -- expected: pass incl. the two new scenarios
- `cargo clippy -p zanshin-jj -p zanshin-parity --all-targets -- -D warnings`; `cargo fmt --all --check` -- expected: clean

**Measured (2026-10-25, release build, `large-10k-commits`, no command scopes, 40 alternating `status` / `list_heads` calls):** no reload (store `Arc` unchanged); a verb costs 5.76 ms, the added per-verb work (resolve the fix-up's raw stack for the call's command + `same_resolution`) 16 µs (~0.3 %), the whole `refresh_settings` 127 µs — within noise. Throwaway timing test, not committed.

**Verification run (2026-10-25, after the review patches; the full gate is the story loop's, not run here):**
- `cargo fmt --all --check` -- clean
- `cargo clippy -p zanshin-jj -p zanshin-parity --all-targets -- -D warnings` -- clean
- `cargo test -p zanshin-jj --lib` -- 395 passed
- `cargo test -p zanshin-jj --test it` -- 1399 passed, 1 ignored (pre-existing)
- `cargo test -p zanshin-ffi --test it` -- 384 passed
- `cargo test -p zanshin-parity --test oracle` -- 449 passed (incl. `init_when_commands_no_colocate`, `init_when_commands_other_command`; the first fails with the fix reverted: "UNEXPECTED colocated (.git dir)")
- No FFI/schema/Dart change, so no `cargo make codegen` / Dart checks. Coverage not measured (gate rule); `cli_command.rs` is new and covered by its two unit tests.

## Auto Run Result

Status: done

**Summary.** Every Zanshin call now resolves the jj config stack for the CLI command it plays, so `[[--scope]] --when.commands` tables apply per verb as in `jj` @ v0.46.0. One table (`crates/zanshin-jj/src/cli_command.rs`) holds the names, audited against the pinned jj-cli's clap tree; every call start in `Repo` takes an entry (a missing name does not compile); creation paths pass `git init` / `git clone` to the start-up check, `settings_for_new_workspace` and every later load; the config verbs use the table. The per-verb refresh reloads the workspace when the fingerprint changed or the stack resolved for this command differs from the one the settings were built from — without command scopes nothing reloads (measured +16 µs per verb on `large-10k`).

**Files changed (code commit 0c00652):**
- `crates/zanshin-jj/src/cli_command.rs` -- new: the command table, `NO_COMMAND`, the clap-tree audit test.
- `crates/zanshin-jj/src/config.rs` -- command threaded through every load; `load_for`; `fix_up_secure_config` returns the raw stack; `same_resolution`; module doc; unit tests.
- `crates/zanshin-jj/src/repo.rs` -- `Repo.command`; every call start takes its name; resolution-aware `refresh_settings`; `snapshot_as`; inline reload test.
- `crates/zanshin-jj/src/{creation,convert,config_cmd,revset,revset_search,movement,lib}.rs` -- pass the table names; `Direction::cli_command` + test.
- `crates/zanshin-jj/tests/it/when_commands.rs` (+ `main.rs`) -- five own-process witnesses (describe vs new, git fetch/push scopes, clone, wrong-typed scoped value, log reads).
- `crates/zanshin-parity/tests/oracle/{git_scenarios,main}.rs` -- two scoped `git init` creation scenarios.
- `docs/ffi-abi.md` -- the config-stack section names the per-call command.

**Items:**
- I1 (`--when.commands` scopes never apply outside the config verbs) -- fixed (0c00652).
- I2 (`--when.commands` scopes per verb: one mapping table, reload only when the resolved settings differ) -- fixed (0c00652).

**Review:** 26 findings (high 0, medium 0, low 22, false 4). Patched (all low): `config set`'s author-check snapshot now runs as `config set` (`Repo::snapshot_as`); `docs/ffi-abi.md` stale sentence; `same_resolution` doc; `Direction::cli_command` unit test; witnesses for the `log`-pinned `&self` reads and a positive `["git push"]` scope (replacing a vacuous assertion). Deferred (mirrored to deferred-work.md "Surfaced in Story 9.41"): `select_tree`/`drop_actions`/`change_actions` resolve with no command (pre-existing; needs the target verb as an FFI input); per-site witness breadth and no scoped verb oracle scenario; pin-bump checklist entry for the table (agent-context file). Rejected: the double load/resolve per verb (16 µs measured), the reload cost under a real command scope (one `Workspace::load`, the CLI's own per-invocation cost), the command recorded before a failed refresh (no read observes it), the ledger not in the reviewed diff (this commit), `Direction::cli_command` duplicating `cmd` (the table stays the one audited source), copied test helpers (house pattern), clone witness only on the head op (all clone ops share the observed settings), the private no-reload test surface and the recorded (not committed) cost pin (as 9.27).

**Follow-up review recommended:** false — no high and no medium entry was patched (patched: 7 low rows in 5 entries).

**Residual risks:** a scoped config fault in a verb refuses as `MutateError::Precondition(PreconditionError::Config)` — the shape every start-up config fault already has (FFI `jj.config_error`), the matrix's "`MutateError::Config`" read as that; `Repo.command` keeps the last call's name after the call (every read outside a call names its own); the full gate (incl. the coverage ratchet for the new file) runs at the end of the story loop.
