---
title: 'Story 9.9 closing run — `jj.config_deprecated` on `config gc` and the creation paths; SIGPIPE disposition settled'
type: 'bugfix'
created: '2026-10-23'
status: 'done'
baseline_revision: 'ae89dd97d708b021d1745db929216af5364b74a8'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-9-context.md'
warnings: [multiple-goals, oversized]
deferred:
  - summary: >-
      `Repo::resolve_workspace_root` (the CLI's `jj workspace root --name`) loads no config stack, so it neither warns `jj.config_deprecated` nor refuses a broken config as the CLI's start-up does.
    evidence: |-
      `crates/zanshin-jj/src/repo.rs` `resolve_workspace_root` calls `workspace::resolve_root` only; the CLI's `run_internal` (`cli_util.rs:4630-4740` @ v0.46.0) resolves, migrates and warns for every command, `jj workspace root` included. Outside the two items of this closing run.
    location: >-
      crates/zanshin-jj/src/repo.rs (resolve_workspace_root)
    severity: low
  - summary: >-
      The `jj config edit` halves (`config_file_read` / `config_file_write`) load no config stack, so they never warn `jj.config_deprecated`, where the CLI's `jj config edit` warns whenever its start-up stack loads.
    evidence: |-
      `crates/zanshin-jj/src/config_cmd.rs` `file_read_with` / `file_write_with` run only the secure-config fix-up (Story 9.37: no stack load, so a broken config stays repairable); pre-existing since Story 9.28. Surfaced by this run's review (blind + edge layers).
    location: >-
      crates/zanshin-jj/src/config_cmd.rs (file_read_with, file_write_with)
    severity: low
---

<intent-contract>

## Intent

**Problem:** Story 9.9's deferred items, verified at `ae89dd9`. **Item 1:** the CLI prints "Deprecated <source> config: …" at the start of EVERY command (`run_internal`, `cli_util.rs:4646-4740` @ v0.46.0, after its last resolution, before the command body); Zanshin records them only in `Repo::start_call` and in the config verbs' `startup`. `config gc` (both halves) calls `startup(env, None, "config gc", None)` and drops them; the creation paths' start-up check `config::check_startup_stack` (init, clone, `convert_colocated`, `convert_import`) migrates and drops them. The graph/revset reads are NOT affected: `walk_graph`, `graph_topology` and `eval_revset` run `with_verb` → `start_call`, which records them once; their own later `config::load` is the same call. `log_defaults` is the config half of the `jj log` whose walk/topology call already warns. **Item 2:** probed 2026-10-23 with `sigaction(SIGPIPE, NULL, &old)` via Dart FFI: the standalone Dart VM (`dart run`, = `dart test`), `flutter_tester` (`flutter test`) and the Flutter macOS embedder (a `flutter build macos --debug` app, Dart `main`) all report `SIG_IGN` — the cdylib is only ever called after the host's VM is up, so a tool closing stdin early yields `EPIPE` (discarded, as in the CLI), never a signal.

**Approach:** Thread the existing warning sinks into the two start-ups: `check_startup_stack` records the deprecations into the creation path's sink (first, before `settings_from` can refuse, as the CLI prints them before building `UserSettings`); `config_gc_list` / `config_gc_delete` become `ConfigOutcome<…>` like every other config verb, their `startup` gets the sink, and the FFI wraps them with `outcome_to_envelope`. Item 2 is rejected (false) with the probe as evidence; no code.

## Boundaries & Constraints

**Always:** Deprecation warnings come first in each call's list (before the delete-failure / creation warnings), once per migrated layer, text from `config::deprecation_warnings` (unchanged); on a failed call they stay on the error side (`ConfigOutcome.warnings`, `CreationOutcome.warnings`); no `.fbs` change (the gc envelopes already have the warning vector; Dart's decoders already read it on ok and error).

**Never:** No change to `start_call`, the graph/revset/log-defaults paths, `resolve_workspace_root`, `fix.rs`, Story 9.9's verbs or spec; no SIGPIPE handling code; no new warning kind or code; no duplicate deprecation warning on a creation path (the conversions' snapshot loads via `load_for_workspace` and must stay silent).

## I/O & Edge-Case Matrix

User config (via `JJ_CONFIG`) holds `fix.tools.t.line-range-arg = "--l"`; `D` = "Deprecated user-level config: fix.tools.t.line-range-arg is updated to fix.tools.t.line-range-args = [\"--l\"]".

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| init ok | `Repo::init` into an empty temp dir (Git, non-colocated) | `Ok`, warnings `[D]` | — |
| init refused | `Repo::init` Git into `<tmp>/missing/dest` (parent absent) | `Err(InitFailed "Failed to create workspace: …")`, warnings `[D]` | warning kept on the error |
| clone / conversions | `Repo::clone` of a local `file://` source; `convert_colocated`; `convert_import` | exactly one `ConfigDeprecated` = `D`, first in the list | — |
| gc list | `config_gc_list()` | `result` `Ok`, `warnings == [D]` | — |
| gc delete | `config_gc_delete(&[])` | `result` `Ok`, `warnings == [D]` | — |
| graph read | repo-level deprecated key, `walk_graph` / `eval_revset` | exactly one `ConfigDeprecated` per call | — |
| no deprecated key | any of the above with a clean config | no `ConfigDeprecated` | — |

</intent-contract>

## Code Map

- `crates/zanshin-jj/src/config.rs:1214-1231` -- `check_startup_stack()`: today `load_with(&env, None)` → `settings_from` → stack. Change to take `sink: &mut crate::warning::Warnings`, use `load_with_migrated` (`:889`), `sink.extend(deprecation_warnings(..))` BEFORE `settings_from`; doc: the CLI's print point. Module doc `:41` mentions it — re-read and adjust if it says the creation checks warn nothing.
- `crates/zanshin-jj/src/creation.rs:249` (`init_steps`, has `sink: &mut Warnings`), `:381` (`clone_steps`, `sink`) -- pass the sink.
- `crates/zanshin-jj/src/convert.rs:223` (`convert_colocated_steps`), `:328` (`convert_import_steps`) -- pass `&mut report.warnings` (`ConversionReport.warnings: Warnings`, `:141`).
- `crates/zanshin-jj/src/config_cmd.rs:476-492` -- `config_gc_list` / `config_gc_delete`: return `ConfigOutcome<Vec<MissingRepoConfig>>` / `ConfigOutcome<ConfigGcResult>` via `outcome(|warnings| …)` (`:217`), `#[must_use = "the outcome carries the result and the warnings"]` like the siblings; docs. `:1082-1089` `gc_root(env)` → `gc_root(env, warnings)` passing `Some(warnings)` to `startup` (`:543`); `gc_list_with` / `gc_delete_with` (`:1121+`) take the sink; `gc_delete_with` pushes its `jj.config_gc_delete_failed` warnings into the same sink after the deprecations (drop its local `Warned`). Module doc `:42` if it describes the return types.
- `crates/zanshin-ffi/src/config.rs:409` `gc_list_to_envelope(missing)` → add `report: &CallReport` and put its warnings on the envelope as `gc_result_to_envelope` (`:435`) does; `:737-771` the two externs → `outcome_to_envelope(zanshin_jj::config_gc_list(), |m, r| gc_list_to_envelope(m, r))` etc.; extern docs: warns `jj.config_deprecated`. Inline tests `:900-940` call both builders — update, and assert a warning reaches the gc-list envelope.
- `crates/zanshin-jj/tests/it/api_stability.rs:1516-1517` -- pin the new signatures (`fn() -> zanshin_jj::ConfigOutcome<Vec<…>>`, `fn(&[PathBuf]) -> zanshin_jj::ConfigOutcome<…>`).
- `crates/zanshin-jj/tests/it/config_cmd.rs:485-502` -- `gc_lists_and_deletes_the_config_of_a_deleted_repo`: adapt to `.result` / `.warnings`.
- `crates/zanshin-jj/tests/it/config_cmd_user.rs` -- own-process file that repoints `JJ_CONFIG` (never unset; `set_env`/`set_jj_config` helpers); home for the gc-deprecation test (or a new `own_process!` test in `config_cmd.rs` following `a_deprecated_line_range_arg_warns_on_the_config_verbs` `:504`).
- `crates/zanshin-jj/tests/it/creation_warnings.rs` -- ONE own-process `#[test]` walking phases (`:114-161`); `JJ_CONFIG` repointed per phase and reset to `""` (pattern `a_bad_alias_entry_warns_between_the_two_imports` `:478`); add a phase for the creation rows of the matrix; helpers `warnings()`, `git_with_commit`, `file_url`.
- `crates/zanshin-jj/tests/it/fix.rs:196-232` -- the existing deprecation witness (`configured`, `fx.repo.snapshot()`); add the graph-read witness next to it (`walk_graph(DEFAULT_LOG_REVSET-like args, …)` + `eval_revset`, count `ConfigDeprecated` == 1 each).
- `crates/zanshin-ffi/tests/it/config_ffi.rs:410-430` -- gc ffi round trip; still green (warnings empty under the pinned env).
- `docs/rust-error-codes.md:180` -- `jj.config_deprecated` emitter clause: drop "but the `gc` pair", add the creation paths (`zanshin_init`, `zanshin_clone`, `zanshin_convert_colocated`, `zanshin_convert_import`) "first, at their start-up check". `docs/ffi-abi.md:157-160` same; `:624-625` gc rows unchanged (no new error code).
- `packages/zanshin_core` -- READ-ONLY: `decodeConfigGcListEnvelopeInternal` / `decodeConfigGcResultEnvelopeInternal` already decode envelope warnings; errors carry them (Story 9.35). No Dart change.
- `_bmad-output/implementation-artifacts/deferred-work.md:1908-1916` -- the two Story 9.9 entries → RESOLVED (item 1, fix commit) / REJECTED (item 2, the probe); add `## Surfaced in the closing run of Story 9.9 (bmad-build-auto, 2026-10-23)` mirroring this spec's `deferred:` entry. `sprint-status.yaml:192` -- append a closing-run note to the `9-9-…` comment (bump `last_updated`).

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/src/config.rs`, `creation.rs`, `convert.rs` -- `check_startup_stack(sink)` records the deprecations; the four creation paths pass their sink -- item 1, creation paths.
- `crates/zanshin-jj/src/config_cmd.rs` -- gc pair → `ConfigOutcome`, `startup` with the sink -- item 1, `config gc`.
- `crates/zanshin-ffi/src/config.rs` -- gc externs via `outcome_to_envelope`, gc-list envelope carries warnings, docs, inline test -- item 1 wire.
- `crates/zanshin-jj/tests/it/{creation_warnings,config_cmd,config_cmd_user or config_cmd,fix,api_stability}.rs` -- the matrix rows (creation ok + refused + clone/conversions; gc list + delete; graph read) and the signature pins -- witnesses.
- `docs/rust-error-codes.md`, `docs/ffi-abi.md` -- emitter clauses.
- `_bmad-output/implementation-artifacts/deferred-work.md`, `sprint-status.yaml` -- ledger (spec commit).

**Acceptance Criteria:**
- Given a user config with the deprecated key, when each creation path or `config gc` half runs, then its outcome's warnings start with exactly one `jj.config_deprecated` carrying the CLI's text — on success and on a start-up-passing refusal.
- Given the FFI, when `zanshin_config_gc_list` / `_delete` run, then the envelope (ok or error) carries the call's warnings.
- Given the targeted checks below, then each passes and the tree is clean at the end.

## Spec Change Log

## Review Triage Log

### 2026-10-23 — Review pass
- verdicts: 27 findings — high 0, medium 3, low 19, false 5, maybe-false 0
- findings:
  - `[medium]` `[patch]` (verification-gap) a deprecation kept on a refusal INSIDE `check_startup_stack` (`settings_from`) had no witness; swapping the two lines would pass every test — added a `creation_warnings` step: deprecated key + `user.name = 1`, Git init → `Err(RepoError::Config)` naming `user.name`, warnings `[D]`, commit 65a0ac3.
  - `[false]` `[reject]` (intent) the fix does not live in `config::load_with` / `load` as the item located it — the graph/revset reads run `with_verb` → `start_call`, which records once per call; `walk_graph` / `graph_topology` / `eval_revset` witnesses show exactly one warning each.
  - `[low]` `[reject]` (intent) `log_defaults` stays silent though the item lists it — it has no warning channel (`&self`, bare `Result`) and is the config half of the `jj log` whose walk/topology call already warns once; a second sink would print the CLI's one line twice and add API surface.
  - `[low]` `[patch]` (intent) `graph_topology` claimed covered without a witness; FFI externs not run with a deprecated key — `graph_topology` added to `fix::a_deprecated_line_range_arg_warns_once_per_graph_read` (65a0ac3); the extern part is rejected: `outcome_to_envelope` is the shared mapping every config verb uses and is pinned by its own tests plus the gc-list builder test.
  - `[medium]` `[patch]` (intent) refusal inside `check_startup_stack` untested — same as the verification-gap row, commit 65a0ac3.
  - `[false]` `[reject]` (intent) the gc pair's public signatures changed although it is not Story 9.9 code — the item names `config gc` explicitly; carrying warnings on the error side needs `ConfigOutcome`, the sibling config verbs' type, and `api_stability` pins it.
  - `[false]` `[reject]` (intent) docs claim beyond tests (editor halves load no stack; deprecation first in clone/convert) — `file_read_with` / `file_write_with` call only `fix_up`, no `startup`; the creation phase asserts `warnings.first()` is the deprecation for clone and both conversions.
  - `[low]` `[reject]` (intent) item 2's probe leaves no repo artifact and the macOS probe was a debug build — the probe and its results are recorded in this spec and the ledger; the intent offered the disposition check as the settling option; release and debug share the VM's `Platform::Initialize`.
  - `[false]` `[reject]` (intent) `## Auto Run Result` missing — written at finalize (this pass).
  - `[medium]` `[patch]` (blind) the `check_startup_stack` doc promise (kept on a `settings_from` refusal) is untested — same as the verification-gap row, commit 65a0ac3.
  - `[false]` `[reject]` (blind) colocated / native init and colocated clone may duplicate the warning — their extra loads go through the silent `config::load_for_workspace` (`creation.rs:137`, `:628`, `convert.rs:659`), never `start_call` or `check_startup_stack`, so no second warning can arise.
  - `[low]` `[patch]` (blind) graph witness lacks `graph_topology`; no negative `log_defaults` test — `graph_topology` added (65a0ac3); `log_defaults` returns no warnings at all, so a negative test has nothing to observe.
  - `[low]` `[reject]` (blind) FFI acceptance only half tested (gc error envelope, delete order on the wire, creation envelopes) — same as the intent row: shared `outcome_to_envelope` / creation-envelope mapping, pinned by their own tests; zanshin-jj tests pin the order.
  - `[low]` `[defer]` (blind) the `jj config edit` halves never warn `jj.config_deprecated` though the CLI does when its stack loads — real, pre-existing since Story 9.28 (the halves deliberately load no stack, Story 9.37); deferred, mirrored to deferred-work.md.
  - `[low]` `[patch]` (blind) `startup`'s `Option` sink dead and `fix_ups` misnamed after every caller passes a sink — now `warnings: &mut Vec<Warning>`, commit 65a0ac3.
  - `[low]` `[reject]` (blind) CLI citation ranges differ across files — each range contains the print loop (`cli_util.rs` ~4720-4738 @ v0.46.0); the `check_startup_stack` doc deliberately spans to `UserSettings` (4750); a pure citation-unification adds nothing a reader needs.
  - `[low]` `[patch]` (blind) the sprint-status note runs into the truncated earlier sentence — separated as "NOTE 2026-10-23 (closing run, …)" (spec commit).
  - `[low]` `[reject]` (blind) Spec Change Log empty while the implementation departed from the Code Map — the fix is an edit of this build's spec; the departures (real FFI symbol names, editor-halves wording) are recorded in the verification notes.
  - `[low]` `[patch]` (blind) clone `# Warnings` doc line ~150 chars, convert doc stub line — reflowed in `zanshin-ffi/src/repo.rs`, codegen re-run (header + bindings comments), commit 65a0ac3.
  - `[low]` `[patch]` (blind) the missing-parent init row reused the directory holding the previous row's repo — fresh `TempDir`, commit 65a0ac3.
  - `[low]` `[reject]` (blind) Dart docs for `configGcList` / `configGcDelete` do not name the new warning — both return types already carry the call's warnings (`WarnedList`, `ConfigGcResult.warnings`); no Dart code changed and no per-code list exists there to extend.
  - `[low]` `[patch]` (blind) closed deferred-work entries keep live severities ("High if true.", "Medium.") — dropped (spec commit).
  - `[low]` `[reject]` (edge) list + delete each warn, so one CLI `jj config gc` surfaces the line twice — the fix contradicts this spec's matrix row "gc delete → `[D]`"; each half is its own start-up that can refuse on its own.
  - `[low]` `[patch]` (edge) `Repo::init` / `Repo::clone` docs omit the leading `jj.config_deprecated` and say the internal/native arms warn nothing — docs updated, commit 65a0ac3.
  - `[low]` `[patch]` (edge) `convert.rs` module doc's print-order list omits the leading warning — item 1 added, commit 65a0ac3.
  - `[low]` `[reject]` (edge) `check_startup_stack` resolves with command `None`, so a deprecated key inside a `--when.commands = ["git"]` scope warns in the CLI only — pre-existing for every Zanshin start-up but the config verbs and tracked by Story 9.41 (`9-41-when-commands-config-scopes-per-verb`, backlog).
  - `[low]` `[defer]` (edge) the editor halves' parity gap while the ledger calls the every-command item resolved — same as the blind editor-halves row; deferred, mirrored.

## Design Notes

- **Why not `log_defaults`.** The CLI's one `jj log` = one warning; the GUI's `jj log` is `log_defaults` (offers) + `walk_graph`/`graph_topology`, and the latter already warns via `start_call`. Warning in both would print the CLI's single line twice.
- **Why reject item 2 without a guard test.** The question was the hosts' disposition; all three hosts the cdylib runs in ignore SIGPIPE (Dart VM's `Platform::Initialize`, inherited by flutter_tester and the macOS embedder). A `dart test` guard would cover only the standalone VM, which the probe already settled.

## Verification

**Commands (targeted; the story loop runs the full gate — no `cargo make test` / `test-full` / `coverage`):**
- `cargo test -p zanshin-jj --lib` -- expected: pass.
- `cargo test -p zanshin-jj --test it -- creation_warnings:: config_cmd:: config_cmd_user:: fix:: api_stability:: clone_init:: convert::` -- expected: pass.
- `cargo test -p zanshin-ffi --lib` and `cargo test -p zanshin-ffi --test it -- config_ffi:: repo_ffi::` -- expected: pass.
- `cargo test -p zanshin-parity --test oracle` -- expected: pass (creation verbs' start-up changed; oracle counts `Warning:` lines on init/clone/convert scenarios).
- `cargo clippy -p zanshin-jj -p zanshin-ffi --all-targets -- -D warnings`, `cargo fmt --all --check` -- expected: clean.
- `packages/zanshin_core`: `dart test test/worker/warnings_test.dart test/ffi/config_test.dart` (whichever exist for config gc) -- expected: pass (no Dart change; envelope shape unchanged).

**Verification notes (implementation run 2026-10-23, code commit 9629c9e; no `cargo make test` / `test-full` / `coverage` per the loop's gate rule):**
- `cargo test -p zanshin-jj --lib` — 331 passed (incl. the new inline `config_cmd::tests::gc_warns_a_deprecated_key_at_its_start_up`: list ok, delete with a failure = `[ConfigDeprecated, ConfigGcDeleteFailed]`, `NoConfigPath` refusal keeps the warning).
- `cargo test -p zanshin-jj --test it -- creation_warnings:: config_cmd:: config_cmd_user:: fix:: api_stability:: clone_init:: convert::` — 128 passed (new: `creation_warnings` phase `a_deprecated_user_key_warns_once_first_on_every_creation_path` — init ok `[D]`, init into `<tmp>/missing/dest` `InitFailed` + `[D]`, clone / `convert_colocated` / `convert_import` exactly one `D`, first; `config_cmd::a_deprecated_user_key_warns_on_config_gc`; `fix::a_deprecated_line_range_arg_warns_once_per_graph_read`).
- `cargo test -p zanshin-ffi --lib` — 203 passed (gc-list envelope carries `jj.config_deprecated`); `cargo test -p zanshin-ffi --test it -- config_ffi:: repo_ffi::` — 54 passed.
- `cargo test -p zanshin-parity --test oracle` — 280 passed (no ledger change).
- `cargo clippy -p zanshin-jj -p zanshin-ffi --all-targets -- -D warnings`, `cargo fmt --all --check` — clean.
- `packages/zanshin_core`: `dart test test/worker/warnings_test.dart test/ffi/config_test.dart` (with the gate's pinned env: `JJ_CONFIG=""`, `XDG_CONFIG_HOME=target/test-xdg-config`, …) — 24 passed.
- `cargo make codegen` — header + `bindings.dart` changed in doc comments only (the gc externs and the `zanshin_repo_init` / `_clone` / `_convert` `# Warnings` sections now name `jj.config_deprecated`).
- Deviation from the Code Map: the FFI creation symbols are `zanshin_repo_init` / `zanshin_repo_clone` / `zanshin_repo_convert` (`convert_import` has no FFI symbol); the docs name those. The registry/ABI emitter clause also now excludes the two `config_file_*` editor halves (they load no stack, so they never warned it) instead of the `gc` pair.

**Verification notes (review pass 2026-10-23, after the patch commit 65a0ac3; no `cargo make test` / `test-full` / `coverage`):**
- `cargo test -p zanshin-jj --lib` — 331 passed. `cargo test -p zanshin-jj --test it -- creation_warnings:: config_cmd:: config_cmd_user:: fix:: api_stability:: clone_init:: convert::` — 128 passed (incl. the new start-up-refusal step and `graph_topology`).
- `cargo test -p zanshin-ffi --lib` — 203 passed; `cargo test -p zanshin-ffi --test it -- config_ffi:: repo_ffi:: ffi_abi_doc_sync::` — 71 passed.
- `cargo test -p zanshin-parity --test oracle` — 280 passed (run on 9629c9e; 65a0ac3 changed docs/tests/`startup`'s parameter type only).
- `cargo clippy -p zanshin-jj -p zanshin-ffi --all-targets -- -D warnings`, `cargo fmt --all --check` — clean. `cargo make codegen` — no drift after 65a0ac3.
- `packages/zanshin_core`: `dart analyze --fatal-infos --fatal-warnings` — no issues; `dart format --set-exit-if-changed lib test` — 0 changed (only doc comments in `bindings.dart` changed).
- Matrix audit: init ok / init refused / clone + conversions — `creation_warnings::creation_paths_report_what_the_cli_prints` (phase `a_deprecated_user_key_warns_once_first_on_every_creation_path`); gc list + delete — `config_cmd::a_deprecated_user_key_warns_on_config_gc` and inline `gc_warns_a_deprecated_key_at_its_start_up`; graph read — `fix::a_deprecated_line_range_arg_warns_once_per_graph_read`; no deprecated key — `creation_warnings` `init_reports_nothing`, `config_cmd::gc_lists_and_deletes_the_config_of_a_deleted_repo` (warnings empty). All ran and passed.

## Auto Run Result

Status: done

**Items:**
- **1 — fixed (9629c9efb0e64d74c465554907fdff5ab8bbdcda; review patches 65a0ac38ccc3f970c90a028e6a002c3165283598).** Verified partly real at `ae89dd9`: `config gc` (`startup(.., None)`) and the creation paths' `check_startup_stack` migrated and dropped the descriptions. Now `check_startup_stack(sink)` records them first in `init` / `clone` / `convert_colocated` / `convert_import` (before `settings_from`, so a start-up refusal keeps them), and `config_gc_list` / `config_gc_delete` return `ConfigOutcome` with their start-up recording into it; the FFI gc externs carry them on the ok and error envelope. The graph/revset part was false: `walk_graph` / `graph_topology` / `eval_revset` already record once per call via `start_call` (now witnessed); `log_defaults` is the config half of the same `jj log` and stays silent (no warning channel; warning there would print the CLI's one line twice).
- **2 — rejected (false).** Probed `sigaction(SIGPIPE, NULL, &old)` through Dart FFI: the standalone Dart VM (`dart run` / `dart test`), `flutter_tester` and the Flutter macOS embedder (`flutter build macos --debug` app) all report `SIG_IGN`; the cdylib runs only inside those hosts after their VM is up, so an early-closed stdin yields `EPIPE` (discarded, as the CLI does). No code.

**New findings (deferred, mirrored to deferred-work.md "Surfaced in the closing run of Story 9.9"):** `resolve_workspace_root` loads no start-up stack (low); the `jj config edit` halves never warn `jj.config_deprecated` (low).

**Files changed:**
- `crates/zanshin-jj/src/config.rs` — `check_startup_stack(sink)` records the deprecations.
- `crates/zanshin-jj/src/creation.rs`, `convert.rs` — pass the creation sink; convert module doc's print order.
- `crates/zanshin-jj/src/config_cmd.rs` — gc pair → `ConfigOutcome`; `startup` takes the warning list.
- `crates/zanshin-jj/src/repo.rs` — `Repo::init` / `Repo::clone` warning docs.
- `crates/zanshin-ffi/src/config.rs`, `repo.rs` — gc externs via `outcome_to_envelope`, gc-list envelope carries warnings, docs; `zanshin_ffi.h`, `bindings.dart` regenerated (comments).
- Tests: `crates/zanshin-jj/tests/it/{creation_warnings,config_cmd,fix,api_stability}.rs`, inline `config_cmd` + `zanshin-ffi` config tests.
- Docs: `docs/rust-error-codes.md`, `docs/ffi-abi.md`.
- Ledger: `deferred-work.md` (item 1 RESOLVED, item 2 REJECTED, two surfaced lows), `sprint-status.yaml` (9-9 closing note), this spec.

**Review:** 27 findings (medium 3, low 19, false 5). Patched: the start-up-refusal witness (medium, three layers), `graph_topology` witness, `startup`'s dead `Option`, `Repo::init`/`clone` and convert warning-order docs, FFI doc reflow, fresh dir for the refused-init row, sprint-status note, closed-entry severities. Deferred: the `jj config edit` halves' missing deprecation warning (low, pre-existing). Rejected: `log_defaults` silence (no channel, would duplicate), extern-level FFI tests (shared mapping), probe artifact/release build, citation ranges, spec Change Log edit, Dart docs, gc list+delete double warning (contradicts the spec matrix; each half its own start-up), `--when.commands` for creation start-ups (Story 9.41); false: loader location, colocated/native duplicates, gc API change, docs claims, missing Auto Run Result.

**Follow-up review recommended:** false — patched at entry verdict: high 0, medium 1 (one grouped entry), low 9.

**Residual risks:** coverage not measured (gate rule; new lines are exercised by the new tests); the full gate runs at the loop's end; a `--when.commands` scoped deprecated key stays unwarned on creation paths until Story 9.41.
