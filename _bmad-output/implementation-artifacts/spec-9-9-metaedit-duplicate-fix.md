---
title: 'Story 9.9: `metaedit`, `duplicate`, `fix`'
type: 'feature'
created: '2026-10-23'
status: 'done'
baseline_revision: 'daea9e2797b15296904ca0838cf728a64dd8a380'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
warnings: [multiple-goals, oversized]
deferred:
  - summary: >-
      Under a Dart host the cdylib's `wait_with_output` for a fix tool can lose its exit status (ECHILD), so `jj fix` keeps the old content without a sign in the envelope.
    evidence: |-
      Seen on about half of the `dart test` runs while implementing (Dart's exit-code handler reaps any child while one of its own processes runs); the Dart round trip therefore uses an unstartable tool, and a running tool is witnessed only in Rust processes (zanshin-jj tests, the FFI test, the oracle). jj-lib's `git` subprocesses share the hazard. Since the review a `tracing::warn!` marks the case.
    location: >-
      crates/zanshin-jj/src/fix.rs (Runner::run_tool); packages/zanshin_core/test/worker/metaedit_duplicate_fix_test.dart
    severity: medium
  - summary: >-
      `jj.fileset_diagnostic` is registered and wired but jj-lib 0.46 emits no fileset diagnostics, so no test reaches it.
    evidence: |-
      `get_tools_config` records `print_parse_diagnostics` for `fix.tools.<name>.patterns` as the CLI does; `FilesetDiagnostics` stays empty at the pin. Re-check at the next pin bump.
    location: >-
      crates/zanshin-jj/src/fix.rs (get_tools_config); docs/rust-error-codes.md
    severity: low
  - summary: >-
      `jj.config_deprecated` is emitted by the snapshotting verbs and the config verbs only; `config gc`, the non-snapshotting reads (graph, revset, log defaults) and the creation paths run the migration but drop its descriptions, where the CLI warns on every command.
    evidence: |-
      `config_cmd.rs` calls `startup(.., None)` for `config gc`; `config::load_with` / `load` discard the `Deprecations` (graph.rs, revset.rs, creation.rs, convert.rs reach config through them). Each needs a warning sink threaded through a path that has none today.
    location: >-
      crates/zanshin-jj/src/config.rs (load_with, load); crates/zanshin-jj/src/config_cmd.rs (config gc)
    severity: medium
  - summary: >-
      A configured fix tool that never exits blocks the worker for good; the GUI has no Ctrl-C and `fix` has no cancel.
    evidence: |-
      `Runner::run_tool` waits on the child without a deadline, as the CLI does; the CLI's user can interrupt the terminal, the app's cannot, and every later call on the repo queues behind it. A cancel would follow the network verbs' (Story 9.52) helper + process-group kill.
    location: >-
      crates/zanshin-jj/src/fix.rs (Runner::run_tool)
    severity: medium
  - summary: >-
      A fix tool that exits without reading stdin could raise SIGPIPE in the host process if the Flutter/Dart host does not ignore SIGPIPE.
    evidence: |-
      Unverified: `stdin.write_all` to a closed pipe raises SIGPIPE unless ignored; Rust binaries ignore it in `main`, a cdylib inherits the host's disposition. Settle by checking the Dart VM / Flutter macOS engine's SIGPIPE disposition (or a test that runs a tool that closes stdin early under `dart test`).
    location: >-
      crates/zanshin-jj/src/fix.rs (Runner::run_tool)
    severity: high (unverified)
---

<intent-contract>

## Intent

**Problem:** zanshin-jj has no `jj metaedit`, `jj duplicate` or `jj fix`. The floating client's drop menu (10.10) offers `duplicate` and previews it through 9.31's `duplicate::plan_duplicate`, which no verb calls yet; the deferred-work item "Config migration rule not ported" waits for a `fix` verb (the CLI migrates `fix.tools.<name>.line-range-arg` → `line-range-args` and warns).

**Approach:** Port `cmd_metaedit`, `cmd_duplicate` and `cmd_fix` step for step at v0.46.0 over jj-lib, end to end (`.fbs` → zanshin-jj → `extern "C"` → `zanshin_core`), as 9.16 did for rebase. `duplicate` calls `plan_duplicate` before its transaction, so preview and verb agree. `fix` ports the CLI's tool-config parsing and subprocess runner privately (jj-cli's library stays template-engine-only) and brings the config-migration rule with it.

## Boundaries & Constraints

**Always:**
- The CLI at v0.46.0 is the spec (`git -C ../jj show v0.46.0:cli/src/commands/{metaedit,duplicate,fix}.rs`): preconditions and their order, refusal and warning texts verbatim, op descriptions byte-identical (`edit commit metadata for commit <hex>`, `… <hex> and <n> more`; `duplicate <n> commit(s)`; `fixed <n> commits`), every repo effect.
- Revisions are change ids (ADR-0003); an EMPTY list is the CLI's default — `@` for metaedit and duplicate, `revsets.fix` (jj default `reachable(@, mutable())`, parsed "In revset expression" like `revsets.arrange`) for fix's `source`. `@` is resolved by commit id (a divergent `@` is not refused).
- Every verb goes through `Repo::with_verb` / `with_checked_verb`; clap's rules refuse before the snapshot (3ee3f29's `with_checked_verb`): metaedit `author` with `update_author`, `author_timestamp` with `update_author_timestamp`, an `author` that is not `Name <email>` (`parse_author`'s regex), an `author_timestamp` that is neither RFC 2822 nor RFC 3339 (`jj_lib::time_util::parse_datetime`); duplicate `onto` with `insert_after`/`insert_before` (`ONTO_WITH_INSERT`). Texts: `--author cannot be used with --update-author`, `--author-timestamp cannot be used with --update-author-timestamp`, `invalid value '<v>' for '--author <AUTHOR>': Invalid author string`, `invalid value '<v>' for '--author-timestamp <AUTHOR_TIMESTAMP>': <chrono error>`.
- A call that changes nothing writes NO operation (`new_op_id` = pre-call head): metaedit with nothing to rewrite, fix with nothing fixed (the shared "Nothing changed." gate, `no_op_result`).
- Results: metaedit and duplicate return `MutationResult` — metaedit's `new_change_ids` = the change ids `update_change_id` minted (modified order, else empty); duplicate's `new_change_ids` = the duplicates' change ids in jj-lib's `duplicated_commits` order. fix returns a new `FixResult { mutation, num_fixed_commits, num_checked_commits, tool_stderr: [FixToolStderr { path, stderr }] }` (counts saturate at `u32::MAX`; `path` as `warning::ui_path` renders it; stderr lossy UTF-8; sorted by path — the CLI's order is rayon's).
- Warnings (new kinds + codes in the registry's warning section, Dart constants, `envelope.rs` maps and their exhaustive lists): `DuplicateAsOwnDescendant` ("Duplicating commit <12 hex> as a descendant of itself."), `DuplicateAsOwnAncestor` ("… as an ancestor of itself."), `FixToolStartFailed` ("Failed to start `<name>`."), `FixToolFailed` ("Fix tool `<name>` exited with non-zero exit code for `<path>`"), `FilesetDiagnostic` (`print_parse_diagnostics` "In `fix.tools.<name>`" + the error chain), `ConfigDeprecated` ("Deprecated <source> config: <desc>", source words as `cli_util.rs:4727-4740`). Fix's per-file warnings are collected from rayon's threads and recorded sorted by message; `PathsUnmatched` for explicit `paths` absent from every fixed commit's tree.
- fix's tool config: `fix.tools` keys sorted; `RawToolConfig` deserialized exactly (`command` = `CommandNameAndArgs` string | non-empty array | `{env, command}`, `patterns` filesets parsed with the config fileset context like `wc_ops::auto_tracking_matcher`, `enabled` default true, `line-range-args`, `run-tool-if-zero-line-ranges`); refusals `MutateError::Config`: "run-tool-if-zero-line-ranges can only be set when line-range-args is set", "No `fix.tools` are configured", "At least one entry of `fix.tools` must be enabled."; a pattern that does not parse is the CLI's user error "Failed to parse fileset: <kind>" + its `Caused by:` lines and `fileset_parse_error_hint` hints (`MutateError::invalid_hinted`). Tools run with cwd = workspace root, `$path` = repo path, `$root` = workspace root, stdin = content; failures skip the tool as the CLI does; `compute_regions_to_format` ported with its CLI unit test.
- The config migration: the CLI's `default_config_migrations()` rule is applied (`jj_lib::config::migrate`) wherever `crate::config` builds the effective stack, and `Repo::start_call` records its descriptions as `ConfigDeprecated` warnings right after the fix-up warnings. Module doc of `config.rs`, `docs/rust-error-codes.md:185` and the deferred-work item (line ~924) are updated/resolved.
- `paths` (fix) are the house's prefix paths (`mutate::build_matcher`), not filesets.

**Never:**
- No `jj_cli` type or fn outside the template engine (port `CommandNameAndArgs`, `parse_author` privately); no status-line facts (`Modified N commits`, `Rebased N …`, `Duplicated X as …`) as warnings or result fields beyond `FixResult`'s two counts.
- No change to `drop_actions`' rows; no MCP tool, no UI code; never regenerate fixtures; never lower the coverage baseline or add an `exclude_prefix`.
- No cancel/progress for fix (it runs on the worker like other local verbs).

## I/O & Edge-Case Matrix

Fixture shorthand `BASE` = A (a.txt) → B (b.txt, bookmark `b-mark`) → C (c.txt) = `@`.

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| metaedit message | `revisions=[B]`, `message=["X"]` | B described "X\n", C reparented; op `edit commit metadata for commit <B hex>` | — |
| metaedit default | `message=["X"]` | `@` (C) described | — |
| metaedit author / timestamp | `author="Foo <foo@bar>"`; `author_timestamp="2000-01-23T01:23:45-08:00"`; `update_author`; `update_author_timestamp` | author fields as the CLI sets them | malformed value → `jj.invalid_input`, no op |
| metaedit new change id | `revisions=[B]`, `update_change_id` | B gets a new change id, listed in `new_change_ids`; `b-mark` follows | — |
| metaedit nothing | `message` equal to the current description, no flag | no operation | — |
| metaedit force | `force_rewrite` | rewritten (new committer timestamp) | — |
| metaedit immutable | `revisions=[root]` or an immutable head | refusal | `jj.immutable` |
| duplicate onto parents | `revisions=[B]` | B' on A, description "B"; op `duplicate 1 commit(s)` | — |
| duplicate locations | `-o root`, `-A A`, `-B C`, several revisions | as the CLI | location refusals of `plan_duplicate` |
| duplicate self-warnings | `revisions=[A]`, `onto=[C]`; `revisions=[C]`, `insert_before=[B]` | duplicated, warning `DuplicateAsOwnDescendant` / `DuplicateAsOwnAncestor` | — |
| duplicate template | `templates.duplicate_description = '"dup " ++ description'` | duplicates described "dup B\n" | template parse error → `jj.config_error` |
| duplicate root | `revisions=[root]` | "Cannot duplicate the root commit" | `jj.invalid_input`, no op |
| fix default | tool `["tr","a-z","A-Z"]` on `glob:'*.txt'`, no source | A, B, C uppercased (descendants of `reachable(@, mutable())`); op `fixed 3 commits`; counts 3/3 | — |
| fix source / paths | `source=[B]`; `paths=["b.txt"]`; a path in no tree | only those commits/paths; `PathsUnmatched` for the missing path | — |
| fix nothing / failing tool | tool already applied; tool `false` | no operation; `FixToolFailed` per file, `tool_stderr` filled when it wrote stderr | — |
| fix unstartable tool | command `["/nonexistent"]` | `FixToolStartFailed`, nothing fixed, no op | — |
| fix config | no `fix.tools`; all disabled; zero-ranges without args; bad pattern | refusal | `jj.config_error` ×3; `jj.invalid_input` with hints |
| deprecated key | `fix.tools.t.line-range-arg = "--l=$first"` in repo config | any verb warns `ConfigDeprecated` "Deprecated repo-level config: fix.tools.t.line-range-arg is updated to fix.tools.t.line-range-args = [\"--l=$first\"]"; fix uses the migrated key | — |

</intent-contract>

## Code Map

CLI anchors at `v0.46.0` (`git -C ../jj show v0.46.0:cli/src/…`); jj-lib in `~/.cargo/registry/src/index.crates.io-1949cf8c6b5b557f/jj-lib-0.46.0/src`; Zanshin at baseline `daea9e2`.

**Prior art (read-only)**
- `commands/metaedit.rs` — `MetaeditArgs` (conflicts: `author`/`update_author`, `author_timestamp`/`update_author_timestamp`; value parsers `parse_author`, `parse_datetime`), `cmd_metaedit` (target → `check_rewritable_expr` → "No revisions to modify." → tx description → `transform_descendants` closure with the author-change rule → finish).
- `commands/duplicate.rs` — `cmd_duplicate`: revset order, root refusal, `compute_commit_location`, the two `is_ancestor` warning loops, `templates.duplicate_description` per commit + `text_util::complete_newline`, `duplicate_commits` / `duplicate_commits_onto_parents`, finish `duplicate {n} commit(s)`.
- `commands/fix.rs` — `cmd_fix` (tools config first, then target, `descendants()`, matcher, `print_unmatched_explicit_paths` over the commits' trees, `fix_files`, finish `fixed {n} commits`), `fix_one_file`, `compute_regions_to_format` + its test, `run_tool`, `ToolConfig`/`RawToolConfig`/`get_tools_config`.
- `cli/src/config.rs:972-1052` (`default_config_migrations`), `:1053-1152` (`CommandNameAndArgs`, `split_name_and_args` with `shlex`, `to_command_with_variables`, `interpolate_variables`); `cli_util.rs:4646-4741` (migrate + "Deprecated … config" print); `text_util.rs:664` `parse_author`; `command_error.rs:658-666`, `:857-874` (`fileset_parse_error_hint`), `:227-235`, `:1136-1150`.
- CLI tests to mirror: `cli/tests/test_metaedit_command.rs`, `test_duplicate_command.rs`, `test_fix_command.rs` (the fake formatter's behaviours map onto `tr`/`false`/`/nonexistent`).
- jj-lib: `rewrite.rs` `duplicate_commits` `:1058`, `duplicate_commits_onto_parents` `:1204`, `DuplicateCommitsStats` `:1033`; `fix.rs` (`fix_files` `:181`, `ParallelFileFixer` `:123`, `FileToFix`, `FixError`, `compute_changed_ranges`, `compute_file_line_count`, `RegionsToFormat`, `LineRange`); `time_util.rs:129` `parse_datetime`; `commit_builder.rs` (`set_author`, `set_description`, `generate_new_change_id`, `author()`/`committer()`); `config.rs` `migrate`, `ConfigMigrationRule::custom`.

**Reuse — `crates/zanshin-jj`**
- `src/duplicate.rs` — `plan_duplicate` (drop its `#[allow(dead_code)]`; split out `plan_duplicate_ids(tx, templates, Vec<CommitId>, location)` so the verb's `@` default resolves by commit id; module doc names the verb).
- `src/rebase.rs` `check_rebase_args`/`rebase` (clap-check + verb template), `src/parallelize.rs` (`transform_descendants` + gate + finish), `src/arrange.rs` `target_expression` / `commits_of` (config-revset default; generalise to a shared helper taking the key for `revsets.fix`).
- `src/mutate.rs` — `MutationResult`, `MutateError::{invalid, invalid_hinted}`, `guard_rewritable`, `finish_verb`, `mutation_result`, `no_op_result`, `build_matcher`, `warn_unmatched`, `resolve_or_wc`, `be`/`cfg`/`res`, `flatten_chain`.
- `src/op_support.rs` — `LocationArgs`, `ONTO_WITH_INSERT`, `resolve_ordered`, `start_repo_transaction`, `join_message_paragraphs`, `complete_newline`.
- `src/template.rs` — `Templates::parse_commit`, `new_description` (pattern for a new `duplicate_description(repo, &Commit, sink)` rendering on the real commit); `src/config.rs` `templates_new_description` `:1625` (add `templates_duplicate_description`), `CLI_DEFAULTS` (`revsets.fix`, `templates.duplicate_description` already there), `load`/`load_for_workspace`/`resolve_raw` `:986-1021`, module doc `:117-128`.
- `src/wc_ops.rs:203-224` `auto_tracking_matcher` (config fileset context); `src/revset.rs` `build_aliases_map`, `parse_diagnosed`, `IN_REVSET_EXPRESSION`.
- `src/warning.rs` — `WarningKind` (+ docs), `parse_diagnostics`, `error_chain_lines`, `ui_path`, `caused_by`, `local`.
- `src/repo.rs` — `start_call` `:~409`, `with_verb` `:476`, `with_checked_verb` `:489`, facades `rebase`/`parallelize`/`arrange` `:2719-2790` (doc-block template). New facades after `arrange`.
- `src/drop_actions.rs` — the `duplicate` row (must keep passing unchanged); `tests/it/rebase.rs::every_drop_actions_rebase_row_agrees_with_the_verb` (agreement-test template).

**Extend — wire + FFI**
- `schemas/envelope.fbs` — `RequestKind` (append `Metaedit`, `Duplicate`, `Fix`), new `MetaeditRequest`, `DuplicateRequest`, `FixRequest`, `FixResult`, `FixToolStderr` after the rebase/arrange tables (`kind` field 0; absent `message` vector = no `-m`, absent string = not given).
- `crates/zanshin-ffi/src/rebase.rs` (reader + extern template) → new `crates/zanshin-ffi/src/metaedit_duplicate_fix.rs`; `lib.rs` module list; `repo.rs` `map_mutate_err`; `envelope.rs` warning-code map + its exhaustive lists, `precondition_envelope`, `ok_mutation_result` (plus an `ok_fix_result`).
- Generated (only via `cargo make codegen`): `zanshin_ffi.h`, `envelope_generated.rs`, `bindings.dart`, `envelope_zanshin.ffi_generated.dart`.
- `docs/ffi-abi.md` (symbols + request/result tables) and `crates/zanshin-ffi/tests/it/ffi_abi_doc_sync.rs` `EXPECTED_EXPORTS = 78` → 81; `docs/rust-error-codes.md` (six warning codes, "also emitted — Story 9.9" clauses, line 185 note).

**Extend — Dart (`packages/zanshin_core`)**
- `lib/src/ffi/rebase.dart` (template) → new `lib/src/ffi/metaedit_duplicate_fix.dart`; `lib/src/ffi/warning.dart` (six code constants + list); worker `commands`/`isolate`/`handle`; barrel `lib/zanshin_core.dart`; `FixResult`/`FixToolStderr` models.
- Tests: `test/ffi/rebase_test.dart`, `test/worker/rebase_test.dart` (synthetic + real-cdylib templates with the extern-fn-guard header paragraph).

**Tests / oracle**
- `crates/zanshin-jj/tests/it/main.rs` + new `metaedit.rs`, `duplicate.rs`, `fix.rs`; `api_stability.rs` (surface pin); `arg_refusals.rs` (clap-before-snapshot template).
- `crates/zanshin-ffi/tests/it/rebase_ffi.rs` → new `metaedit_duplicate_fix_ffi.rs`.
- `crates/zanshin-parity/tests/oracle/{scenarios,main}.rs` (`BASE`, `simple`, `Scenario.extra` for an author read), `state.rs` (what is compared), `ledger.rs` (only with reason + reference).
- Workspace `Cargo.toml` + `crates/zanshin-jj/Cargo.toml`: `serde` (derive), `shlex`, `regex` exact-pinned to the Cargo.lock versions (jj-cli transitives) with WHY comments; `cargo deny` stays green.

## Tasks & Acceptance

**Execution:**
- `Cargo.toml`, `crates/zanshin-jj/Cargo.toml` -- add `serde`/`shlex`/`regex` (exact, WHY) -- exact ports of `RawToolConfig`, `split_name_and_args`, `parse_author`.
- `crates/zanshin-jj/src/config.rs` (+ `repo.rs` `start_call`) -- port the migration rule, apply it where the stack is built, record `ConfigDeprecated` in `start_call`; `templates_duplicate_description`; module doc -- the deferred-work item's "port it with a fix verb".
- `crates/zanshin-jj/src/warning.rs` -- six `WarningKind`s with docs.
- `crates/zanshin-jj/src/metaedit.rs` (new) -- `MetaeditOptions { revisions, update_change_id, message: Option<Vec<String>>, update_author_timestamp, update_author, author: Option<String>, author_timestamp: Option<String>, force_rewrite }`, `check_metaedit_args`, `metaedit` verb, inline tests (author parsing, tx descriptions, clap refusals).
- `crates/zanshin-jj/src/duplicate.rs` -- `DuplicateOptions { revisions, onto, insert_after, insert_before }`, `check_duplicate_args`, `duplicate` verb over `plan_duplicate[_ids]`, warnings, template descriptions.
- `crates/zanshin-jj/src/template.rs` -- `Templates::duplicate_description`.
- `crates/zanshin-jj/src/fix.rs` (new) -- `FixOptions { source, paths, include_unchanged_files, all_lines }`, `FixResult`, `FixToolStderr`, private `CommandNameAndArgs`/`ToolConfig`/`get_tools_config`/`fix_one_file`/`run_tool`/`compute_regions_to_format`, `fix` verb; inline tests (regions test port, command splitting/interpolation, tools-config refusals).
- `crates/zanshin-jj/src/{repo,lib}.rs` -- `#[must_use]` facades `metaedit` (with_checked_verb), `duplicate` (with_checked_verb), `fix` (with_verb) with house doc blocks; modules + re-exports.
- `schemas/envelope.fbs` + `cargo make codegen` -- tables above; commit the regenerated files.
- `crates/zanshin-ffi/src/metaedit_duplicate_fix.rs` (new) + `lib.rs`/`envelope.rs`/`repo.rs` -- readers, `zanshin_metaedit`, `zanshin_duplicate`, `zanshin_fix`, warning codes; full rustdoc.
- `packages/zanshin_core/...` -- request builders, decoders, commands, worker methods, `RepoHandle.metaedit`/`duplicate`/`fix` behind the close guard with NUL rejection, warning constants.
- `crates/zanshin-jj/tests/it/{metaedit,duplicate,fix}.rs` (new) -- every matrix row against jj-lib state; duplicate: `drop_actions`' duplicate row agrees with the verb on the same head; refusals/no-ops keep the head; clap refusals on a dirty working copy write no snapshot op (as `arg_refusals.rs`).
- `crates/zanshin-ffi/tests/it/metaedit_duplicate_fix_ffi.rs` (new) -- readers (absent vs present, malformed, wrong kind), zero handle ×3, a refusal and a success envelope each, a warning code reaching the envelope.
- `packages/zanshin_core/test/{ffi,worker}/metaedit_duplicate_fix_test.dart` (new) -- synthetic + real-cdylib round trips for all three externs, every request field observed.
- `crates/zanshin-parity/tests/oracle/{scenarios,main}.rs` -- scenarios: metaedit `-m X`, `-r B -m X`, `-r B --update-change-id`, `--author`, `--author-timestamp`, `--update-author` (no-op when identity equal), `--force-rewrite`, root refused, unchanged no-op, `--author`+`--update-author` refused on a dirty wc (author compared via `extra`); duplicate default, `-r B`, `-r B -o root`, `-r C -A A`, `-r B -B C`, `-r A -o C` (warning), `-r C -B B` (warning), `-r B -r C`, root refused, `duplicate_description` template; fix default, `-s B`, path, `--include-unchanged-files`, nothing to fix (no op), failing tool (warning), no tools (refused), deprecated `line-range-arg` (warning on `fix` and on a non-fix verb).
- `crates/zanshin-jj/tests/it/api_stability.rs` -- new types field by field, three `Repo` methods as `fn` pointers.
- `docs/ffi-abi.md`, `docs/rust-error-codes.md` -- symbols, tables, codes.
- `_bmad-output/implementation-artifacts/{sprint-status.yaml,deferred-work.md}` -- 9-9 → `done` with a sibling-style summary (bump `last_updated`); resolve the "Config migration rule not ported" item and the 9.31 "Precondition-phase contract" mention for 9.9; add `## Surfaced in Story 9.9 (bmad-build-auto, 2026-10-23)` mirroring any `deferred:` entry.

**Acceptance Criteria:**
- Given the three verbs exist, when a Dart caller reaches them, then the whole chain is present (`.fbs`, zanshin-jj verb, `extern "C"`, committed codegen, adapter, `WorkerCommand`, worker method, `RepoHandle` method) and `ffi_abi_doc_sync` passes with 81 exports.
- Given every parity scenario above, when the oracle runs, then each matches the pinned CLI on every compared aspect or diverges only through a ledgered entry with reason and reference.
- Given a `drop_actions` duplicate row answered Available or Refused on a head, when the duplicate verb runs the same form on that head, then it writes an operation exactly when the row said Available and refuses with the row's refusal otherwise.
- Given any refusal or no-op, when the op head is compared before and after, then it is unchanged and `new_op_id` equals the pre-call head (zanshin-jj and FFI layers).
- Given the targeted checks of this run's gate rule, then each passes (see Verification), and `git status --porcelain` is clean at the end with every commit carrying the required co-author trailer.

## Spec Change Log

## Review Triage Log

### 2026-10-23 — Review pass
- verdicts: 35 findings — high 0, medium 11, low 20, false 3, maybe-false 1
- findings:
  - `[low]` `[reject]` (blind) fix `paths` are prefixes, the CLI takes filesets — real, but it is the house contract every paths-taking verb shares (`op_support::build_matcher` "WHY not the fileset DSL"); changing fix alone would split the contract, and a fileset surface is new parsing and API.
  - `[medium]` `[patch]` (blind) a lost tool exit status (ECHILD under the Dart host) is completely silent — fixed: `tracing::warn!` naming tool and path on the wait-failure branch; the CLI behaviour (old content kept) stays. The hazard itself is deferred (row below).
  - `[medium]` `[defer]` (blind) fix's success path never runs in its real host (Dart worker test uses an unstartable tool) — the Dart VM reaps the cdylib's child (ECHILD); pre-existing host hazard shared with jj-lib's git subprocesses. Deferred, mirrored to deferred-work.md.
  - `[low]` `[patch]` (blind) `all_lines` has no behavioural witness — fixed with the line-range tests (see the verification-gap row).
  - `[low]` `[patch]` (blind) tool-runner paths untested (chaining, run-if-zero, structured env, adopted PATH) — fixed: chaining + disabled-tool, run-tool-if-zero-line-ranges and adopted-PATH tests; the structured `env` stays covered by the `get_envs` unit test (the spawn path is the same `Command`).
  - `[medium]` `[defer]` (blind) `jj.config_deprecated` only partly emitted (`config gc`, non-snapshot reads, creation paths drop it) — real; each path needs a warning sink it lacks today. Deferred, mirrored. The non-string `line-range-arg` failing every load matches the CLI (unit-tested in `migrate`).
  - `[low]` `[reject]` (blind) `tool_stderr` cannot be attributed to a tool or commit and the sort loses chained order — the CLI prints neither (its own TODO); attribution would add wire fields for a diagnostic text, and the order across rayon threads is unspecified in the CLI too.
  - `[low]` `[patch]` (blind) subtle metaedit branches untested — fixed in part: nested targets with `update_change_id` on two revisions (two minted ids, descendant rewritten once). The unset-author branch is rejected: it needs a commit written with an empty author, a fixture this repo cannot produce through the CLI path the oracle compares, for a comment-documented port line.
  - `[low]` `[patch]` (blind) oracle misses shipped flags — fixed: metaedit several revisions, multi-paragraph `-m`, `--update-author-timestamp`, duplicate onto a merge destination. Malformed values are clap texts (house wording, nothing to compare); `fix -a` needs a line-range tool (covered by the zanshin-jj tests).
  - `[low]` `[patch]` (blind) `message = Some(vec![])` underspecified — fixed: docs (Rust, FFI, ffi-abi.md, Dart) state it joins to "" and equals `-m ""`.
  - `[low]` `[patch]` (blind) `PathsUnmatched` docs name the wrong tree set — fixed: "every source's and descendant's tree".
  - `[low]` `[reject]` (blind) the oracle's `place_keys` tie-break is not total — today's scenarios are deterministic (B carries `b-mark`, C is `@`); a future tie fails loudly as a mislabelled scenario, and a total key needs parent-label propagation.
  - `[low]` `[patch]` (edge) `fix_files` Err drops the runner's warnings — fixed: the sorted runner warnings are recorded before the error propagates.
  - `[medium]` `[defer]` (edge) a tool that never exits blocks the worker for good — the CLI waits the same way but its user can Ctrl-C; a cancel is Story 9.52-style infrastructure. Deferred, mirrored.
  - `[maybe-false]` `[defer]` (edge) a tool closing stdin early could SIGPIPE-kill the host — depends on the Dart VM / Flutter engine's SIGPIPE disposition, unchecked; high if true. Deferred (unverified), mirrored.
  - `[low]` `[patch]` (edge) `message = Some(vec![])` clears descriptions silently — same as the blind row (documented equivalence with `-m ""`).
  - `[medium]` `[defer]` (edge) non-snapshotting reads emit no `jj.config_deprecated` — same as the blind config_deprecated row.
  - `[medium]` `[defer]` (edge) `config gc` drops the deprecations — same as the blind config_deprecated row.
  - `[low]` `[reject]` (edge) a bad `templates.duplicate_description` makes the drop row say Available while the verb refuses — `drop_actions` is advisory and the verb's refusal wins (epic rule); a broken template is a config error the user meets once, and parsing it in the preview adds a template parse to every drop query.
  - `[low]` `[patch]` (verification-gap) the config verbs' `jj.config_deprecated` has no witness — fixed: `tests/it/config_cmd.rs` case asserting one `ConfigDeprecated` warning with the CLI's text.
  - `[medium]` `[patch]` (verification-gap) `revsets.fix` being the key read is unverified — fixed: `[revsets] fix = '@'` case asserting only `@` is checked and fixed.
  - `[medium]` `[patch]` (verification-gap) line-range modes unverified end to end — fixed: a modified multi-line file with a recording `line-range-args` tool (changed range vs `all_lines`), and `run-tool-if-zero-line-ranges` with `include_unchanged_files`.
  - `[low]` `[patch]` (verification-gap) multi-tool chaining and disabled tools unverified — fixed: two ordered tools plus a disabled one, final content asserted.
  - `[medium]` `[patch]` (verification-gap) `environment::apply_to_tool` has no test — fixed: `login_shell_environment.rs` `own_process!` case running a tool found only on the adopted PATH.
  - `[medium]` `[defer]` (verification-gap, other) creation paths and `config gc` discard the deprecations — same as the blind config_deprecated row.
  - `[medium]` `[defer]` (intent) fix's success path through the Dart host is not exercised — same as the blind ECHILD row.
  - `[low]` `[patch]` (intent) the config verbs' deprecation path has no test — same as the verification-gap config-verbs row.
  - `[low]` `[reject]` (intent) deliberate departures (prefix paths, stderr as data, sorted warnings, counts) — same as the blind paths row; the others are the spec's documented terminal-UX replacements.
  - `[low]` `[patch]` (intent) deferred-work items had no matching spec `deferred:` entries — fixed: the spec's `deferred:` list now carries every mirrored item.
  - `[low]` `[patch]` (intent) the fileset-diagnostic item's severity "None" is outside High|Medium|Low — fixed: "Low".
  - `[low]` `[patch]` (intent) verification outcomes not recorded in the spec — fixed: recorded under Verification at finalisation.
  - `[false]` `[reject]` (intent) ledger ahead of the spec / tree not clean — the spec's status and the finalisation commit settle both; the in-review edit was this review's own state.
  - `[false]` `[reject]` (intent) the fix config refusals are tested only at unit level — `tests/it/fix.rs::a_broken_tools_config_is_refused_before_anything` drives `Repo::fix` for the disabled, zero-ranges and bad-pattern refusals.
  - `[false]` `[reject]` (intent) the duplicate drop-row agreement is tested only in zanshin-jj — that is where the acceptance criterion puts it; the FFI and Dart layers pass the same verb through unchanged.
  - `[low]` `[defer]` (intent) `jj.fileset_diagnostic` is unreachable at the pin — jj-lib 0.46 emits no fileset diagnostics; re-check at the next pin bump. Deferred, mirrored.

### 2026-10-23 — Review pass (follow-up)
- verdicts: 25 findings — high 0, medium 8, low 16, false 1, maybe-false 0
- findings:
  - `[low]` `[reject]` (edge) `fix_files` returning Err drops the tools' collected stderr — real (the CLI had already printed it), but only a backend error reaches that path, and carrying stderr needs it on the error envelope (new surface).
  - `[medium]` `[defer]` (edge) a tool that never exits blocks the worker for good — carried: the CLI waits the same way; already deferred, mirrored.
  - `[medium]` `[defer]` (edge) `config gc` drops the deprecations — carried: same as the first pass's config_deprecated row.
  - `[medium]` `[defer]` (edge) read-only loads (`load` / `load_with`) migrate silently — carried: same config_deprecated row.
  - `[low]` `[reject]` (edge) a bad `templates.duplicate_description` makes the drop row say Available while the verb refuses — carried: `drop_actions` is advisory, the verb's refusal wins.
  - `[medium]` `[patch]` (verification-gap) the default `@` resolved by commit id (a divergent `@`) has no witness — fixed: `metaedit::divergent_wc` helper and `a_divergent_working_copy_is_the_default_revision` in `tests/it/metaedit.rs` and `tests/it/duplicate.rs` (the verb describes / duplicates `@`'s commit, not its twin).
  - `[low]` `[patch]` (verification-gap) the empty-`message` contract has no verb-level witness — fixed: `metaedit::an_empty_message_clears_the_description` and the oracle scenario `metaedit_empty_message` (`jj metaedit -r B -m ""`, matches the CLI).
  - `[medium]` `[patch]` (intent) a divergent `@` is stated behaviour witnessed at no surface — same as the verification-gap divergent-`@` row.
  - `[medium]` `[defer]` (intent) the deprecated-key warning is not on "any verb" (reads, creations) — carried: same config_deprecated row.
  - `[medium]` `[defer]` (intent) fix's running-tool outcome is untested in the Dart host (ECHILD), SIGPIPE unverified — carried: the first pass's ECHILD and SIGPIPE deferrals.
  - `[false]` `[reject]` (intent) preview-verb agreement is tested only for `-o` and the `@` default has no preview counterpart — the acceptance criterion is about `drop_actions` rows, which offer duplicate only as `-o` (the intent forbids changing them), and `plan_duplicate` delegates to `plan_duplicate_ids`, so both forms run one plan.
  - `[low]` `[patch]` (intent) duplicate's `new_change_ids` order is never asserted — fixed: `several_revisions_are_duplicated_onto_each_others_duplicates` asserts `[B', C']` (jj-lib's `duplicated_commits` order, parents first).
  - `[low]` `[defer]` (intent) `jj.fileset_diagnostic` unreachable at the pin — carried, mirrored in the first pass.
  - `[low]` `[reject]` (intent) the Rust suites assert `MutateError` variants, wire codes only for a subset — the `jj.*` code comes from `map_mutate_err` per variant, shared by every verb and pinned by its own tests; per-verb wire assertions would only repeat it.
  - `[low]` `[patch]` (blind) `MutationResult` docs still say a rewrite never mints a change id and omit metaedit / duplicate — fixed: the Rust `new_change_ids` field doc, Dart `MutationResult.newChangeIds` and the fbs header (codegen re-run, generated comments committed).
  - `[low]` `[reject]` (blind) duplicate / `--update-change-id` lose the old→new pairing and duplicate's `num_rebased` — the intent's Never excludes status-line facts ("Duplicated X as …", "Rebased N …") as result fields.
  - `[low]` `[reject]` (blind) `fix` drops `FixSummary.rewrites` — the intent's Never allows no result field beyond `FixResult`'s two counts.
  - `[low]` `[reject]` (blind) fix `paths` are prefixes, not filesets — carried: the house contract every paths verb shares.
  - `[medium]` `[defer]` (blind) a lost child exit status is invisible to the app user — carried: the first pass traced it (`tracing::warn!`) and deferred the ECHILD hazard; the code reads as that row describes.
  - `[low]` `[reject]` (blind) sorting `tool_stderr` / the per-file warnings loses the tool-chain order — carried: the intent mandates the message sort; the CLI's order is rayon's.
  - `[low]` `[patch]` (blind) `docs/ffi-abi.md` says `jj.paths_unmatched` is "a fix path in no fixed revision's tree" — fixed: "in no source's or descendant's tree", as the code and the other docs say.
  - `[low]` `[patch]` (blind) `num_checked_commits` documented as commits whose files the tools saw — jj-lib counts every commit `transform_descendants` visits (`fix.rs:365`); fixed in the Rust, fbs, Dart and ffi-abi.md docs.
  - `[low]` `[reject]` (blind) the "saturates at `u32::MAX`" promise can never trigger — the stated bound holds (an `i32` count never exceeds it) and negatives clamp to 0; at most redundant wording, no reader is misled into wrong behaviour.
  - `[low]` `[reject]` (blind) `drop_actions` offers duplicate only as `-o` — the intent's Never: no change to `drop_actions`' rows.
  - `[low]` `[reject]` (blind) the oracle lacks fix `--all-lines` / immutable `-s` / `run-tool-if-zero-line-ranges`, duplicate `-A`/`-B` with an immutable child, `--update-author` with a different identity — `-a` and run-if-zero carried (line-range tool, zanshin-jj tests); the rest are witnessed against jj-lib state in `tests/it/{fix,duplicate,metaedit}.rs`; more CLI comparisons add no fix for a defect anyone meets.

## Design Notes

- **Author/timestamp as CLI strings.** `author` and `author_timestamp` cross as the CLI's own values and are parsed Rust-side with the CLI's parsers, so the GUI gets the CLI's refusals; a date picker formats RFC 3339. Example: `author = "Foo <foo@bar.com>"` → name `Foo`, email `foo@bar.com`.
- **One plan fn for duplicate.** `plan_duplicate` already holds the root refusal, the location and the Git root-merge refusal; the verb adds only the post-plan steps (warnings, descriptions, write), so `drop_actions` and the verb cannot drift.
- **Tool stderr is data.** The CLI writes a tool's stderr to the terminal under `<path>:`; the GUI has no terminal, so `FixResult.tool_stderr` carries it (sorted by path for determinism; the CLI's interleaving is rayon's).

## Verification

Gate rule for this run: no `cargo make test` / `test-full` / `coverage`; targeted checks only.

**Commands:**
- `cargo make codegen` -- expected: regenerated files committed, a second run leaves no diff.
- `cargo test -p zanshin-jj --lib` and `cargo test -p zanshin-jj --test it -- metaedit:: duplicate:: fix:: drop_actions:: api_stability:: arg_refusals:: config::` -- expected: pass.
- `cargo test -p zanshin-ffi --lib` and `cargo test -p zanshin-ffi --test it -- metaedit_duplicate_fix_ffi:: ffi_abi_doc_sync::` -- expected: pass.
- `cargo test -p zanshin-parity --test oracle` -- expected: pass.
- `cargo clippy -p zanshin-jj -p zanshin-ffi -p zanshin-parity --all-targets -- -D warnings`, `cargo fmt --all --check`, `cargo deny check` -- expected: clean.
- `packages/zanshin_core`: `dart analyze --fatal-infos --fatal-warnings`, `dart format --set-exit-if-changed lib test`, `dart test` on the new and touched test files -- expected: pass/clean.

**Outcomes (2026-10-23, final tree after the review patches; full gate not run per the run's gate rule):**
- `cargo make codegen` -- exit 0; re-running it on the patched tree changed nothing further.
- `cargo fmt --all --check` -- clean. `cargo clippy -p zanshin-jj -p zanshin-ffi -p zanshin-parity --all-targets -- -D warnings` -- clean. `cargo deny check advisories bans` -- advisories ok, bans ok.
- `cargo test -p zanshin-jj --lib` -- 330 passed. `cargo test -p zanshin-jj --test it -- metaedit:: duplicate:: fix:: drop_actions:: api_stability:: arg_refusals:: config:: config_cmd:: login_shell_environment::` -- 128 passed.
- `cargo test -p zanshin-ffi --lib` -- 203 passed. `cargo test -p zanshin-ffi --test it -- metaedit_duplicate_fix_ffi:: ffi_abi_doc_sync::` -- 23 passed (81 exports).
- `cargo test -p zanshin-parity --test oracle` -- 279 passed (33 new Story 9.9 scenarios, no ledger entry).
- `packages/zanshin_core`: `dart analyze --fatal-infos --fatal-warnings` -- no issues; `dart format --set-exit-if-changed lib test` -- 0 changed; `dart test test/ffi/metaedit_duplicate_fix_test.dart test/worker/metaedit_duplicate_fix_test.dart test/ffi/warning_test.dart` -- 173 passed (real cdylib).
- Not run (gate rule): `cargo make test`, `test-full`, `coverage` — the story loop runs the gate once at its end.

**Outcomes of the follow-up review pass (2026-10-23; full gate not run per the run's gate rule):**
- `cargo make codegen` -- exit 0 after the fbs comment edits; the regenerated `envelope_generated.rs` / `envelope_zanshin.ffi_generated.dart` (comments only) are committed.
- `cargo fmt --all --check` -- clean. `cargo clippy -p zanshin-jj -p zanshin-ffi -p zanshin-parity --all-targets -- -D warnings` -- clean.
- `cargo test -p zanshin-jj --test it -- metaedit:: duplicate::` -- 22 passed (the four new / extended tests included).
- `cargo test -p zanshin-ffi --test it -- metaedit_duplicate_fix_ffi:: ffi_abi_doc_sync::` -- 23 passed.
- `cargo test -p zanshin-parity --test oracle` -- 279 passed with `metaedit_empty_message` matching the CLI; `every_scenario_has_a_test` then needed the count bump (265 → 266) and passes on the re-run.
- `cargo doc -p zanshin-jj --no-deps` -- the new intra-doc links in `mutate.rs` resolve (the remaining private-item warnings predate this pass).
- `packages/zanshin_core`: `dart analyze --fatal-infos --fatal-warnings` -- no issues; `dart format --set-exit-if-changed lib test` -- 0 changed; `dart test test/ffi/metaedit_duplicate_fix_test.dart test/worker/metaedit_duplicate_fix_test.dart` -- 13 passed.
- Not run (gate rule): `cargo make test`, `test-full`, `coverage`.

## Auto Run Result

Status: done

**Summary.** `jj metaedit`, `jj duplicate` and `jj fix` are ported from the CLI at v0.46.0 and wired end to end (`.fbs` → zanshin-jj → `zanshin_metaedit` / `zanshin_duplicate` / `zanshin_fix` → `RepoHandle.metaedit` / `duplicate` / `fix`, 81 exports). `Repo::metaedit` and `Repo::duplicate` refuse clap's rules before the snapshot (`with_checked_verb`); metaedit takes `--author` / `--author-timestamp` as the CLI's strings and parses them with the CLI's parsers; duplicate runs 9.31's `plan_duplicate` (split into `plan_duplicate_ids` for the `@` default), warns the two self-placement cases and renders `templates.duplicate_description`. `Repo::fix` ports the tool config (`CommandNameAndArgs`, `RawToolConfig`, refusals, fileset parse hints), the tool runner (cwd, `$path`/`$root`, line ranges, the adopted login-shell environment) and returns `FixResult` with the two counts and the tools' stderr. The CLI's `fix.tools.<name>.line-range-arg` → `line-range-args` config migration is applied wherever the stack is resolved and warned (`jj.config_deprecated`) by the snapshotting verbs and the config verbs. Six new warning codes, no new error code.

**Files changed (5e58ec3, review patches in the finalisation commit).**
- `crates/zanshin-jj/src/metaedit.rs` (new), `fix.rs` (new), `duplicate.rs` — the three verbs.
- `crates/zanshin-jj/src/{config,config_cmd,repo,warning,template,arrange,environment,lib}.rs` — migration + deprecation warnings, facades, warning kinds, `duplicate_descriptions`, shared config-revset target, `apply_to_tool`.
- `Cargo.toml`, `crates/zanshin-jj/Cargo.toml`, `Cargo.lock` — `serde`, `shlex`, `regex` exact pins.
- `schemas/envelope.fbs` + generated files — requests, `FixResult`, `FixToolStderr`, three `RequestKind`s.
- `crates/zanshin-ffi/src/metaedit_duplicate_fix.rs` (new), `envelope.rs`, `lib.rs` — readers, externs, warning codes, `ok_fix_result`.
- `packages/zanshin_core/lib/src/ffi/metaedit_duplicate_fix.dart` (new), `warning.dart`, worker `commands`/`isolate`/`handle`, barrel — Dart surface.
- Tests: `crates/zanshin-jj/tests/it/{metaedit,duplicate,fix,api_stability,arg_refusals,config_cmd,login_shell_environment}.rs`, `crates/zanshin-ffi/tests/it/metaedit_duplicate_fix_ffi.rs`, `packages/zanshin_core/test/{ffi,worker}/metaedit_duplicate_fix_test.dart`, oracle `scenarios.rs`/`main.rs`/`state.rs` (33 scenarios, a deterministic tie-break for identical duplicates).
- Docs: `docs/ffi-abi.md`, `docs/rust-error-codes.md`.
- Ledger: this spec, `sprint-status.yaml` (9-9 done), `deferred-work.md` (migration item and the 9.31 contract mention resolved; Story 9.9 section mirroring the five `deferred:` entries).

**Review findings.** 35 findings (medium 11, low 20, false 3, maybe-false 1). Patched: the silent lost exit status (medium, now traced), runner warnings kept on a `fix_files` error, the empty-`message` and `PathsUnmatched` docs, and tests for `revsets.fix`, line ranges / `all_lines` / `run-tool-if-zero-line-ranges` (medium), tool chaining + disabled tools, the adopted-PATH tool (medium), the config verbs' deprecation warning, nested `update_change_id`, four more oracle scenarios, and the deferred-work bookkeeping. Deferred (mirrored to deferred-work.md): the Dart-host ECHILD hazard (medium), `jj.config_deprecated` missing from `config gc` / non-snapshot reads / creation paths (medium), a never-exiting tool blocking the worker (medium), possible SIGPIPE in the host (high, unverified), the unreachable `jj.fileset_diagnostic` (low). Rejected: fix's prefix `paths` (house contract shared by every paths verb), stderr attribution / order (the CLI prints neither), the unset-author metaedit branch (needs a fixture the CLI path cannot make), the oracle tie-break's totality (today deterministic, a future tie fails loudly), a bad `duplicate_description` vs the advisory drop row (the verb's refusal wins), and three false findings.

**Follow-up review recommendation: true.** Patched at entry verdict: high 0, medium 4, low 9. Unverified risk: per-file coverage of the new `fix.rs` (~770 lines) and `metaedit.rs` against the 80 % floor, and the extern-fn guard for the three new externs, are unmeasured until the story loop's final gate — the wait-failure trace and the `FilesetDiagnostic` push are branches no test can reach today.

**Residual risks.** Coverage ratchet not run (gate rule). A fix tool's success path is never exercised under the Dart host (ECHILD, deferred). `jj.config_deprecated` is not yet emitted on every call path (deferred).

**Follow-up review pass (2026-10-23).** 25 findings (medium 8, low 16, false 1). Patched: the divergent-`@` default for metaedit and duplicate (medium — new tests), the empty-`message` contract (test + oracle scenario `metaedit_empty_message`), duplicate's `new_change_ids` order, and the docs of `MutationResult.new_change_ids`, `FixResult.num_checked_commits` and fix's `jj.paths_unmatched` (Rust, fbs + codegen, Dart, ffi-abi.md). Deferred: nothing new (every deferral is carried from the first pass and already mirrored). Rejected: tool stderr lost on a backend error (rare, needs error-envelope surface), old→new pairing / `num_rebased` / `rewrites` (the intent forbids status-line result fields), the `drop_actions` `-A`/`-B` row (intent forbids row changes), wire-code assertions per verb (shared mapping), the saturation wording (bound holds), extra oracle scenarios (witnessed in zanshin-jj), the `-o`-only agreement test (false), and the carried rows. Files: `crates/zanshin-jj/src/{mutate,fix}.rs` (docs), `crates/zanshin-jj/tests/it/{metaedit,duplicate}.rs`, `crates/zanshin-parity/tests/oracle/{scenarios,main}.rs`, `schemas/envelope.fbs` + generated files, `packages/zanshin_core/lib/src/ffi/{mutate,metaedit_duplicate_fix}.dart`, `docs/ffi-abi.md`.

**Follow-up review recommendation (this pass): false.** Patched at entry verdict: high 0, medium 1, low 5; a follow-up pass that patched no high has converged. Residual risks unchanged: coverage unmeasured until the loop's final gate; the carried deferrals.
