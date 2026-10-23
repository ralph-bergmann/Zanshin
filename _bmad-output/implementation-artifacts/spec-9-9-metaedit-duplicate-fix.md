---
title: 'Story 9.9: `metaedit`, `duplicate`, `fix`'
type: 'feature'
created: '2026-10-23'
status: 'in-progress'
baseline_revision: 'daea9e2797b15296904ca0838cf728a64dd8a380'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
warnings: [multiple-goals, oversized]
deferred: []
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
