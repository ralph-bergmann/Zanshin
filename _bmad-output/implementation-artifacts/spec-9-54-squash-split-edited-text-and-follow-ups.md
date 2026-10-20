---
title: 'Story 9.54 — Edited editor text for squash/split, and three follow-ups of 9.51–9.53'
type: 'feature'
created: '2026-10-20'
status: 'ready-for-dev'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-9-context.md'
warnings: ['multiple-goals', 'oversized']
deferred: []
---

<intent-contract>

## Intent

**Problem:** Four findings Ralph decided on 2026-10-20 (epics.md Story 9.54; sprint-status key `9-54-squash-split-edited-text-and-follow-ups`; deferred-work.md items I1–I3 are items 1, 3, 4). (1) The GUI can only send an edited `squash_plan` text back as `-m`, which re-applies `templates.commit_trailers` (a deleted trailer returns, an unchanged plan gains a second one); `split` has the same gap. (2) Story 9.53's "a tracked remote row with no target reads ahead" counts every tracked remote, so a read-only `upstream` matched by auto-track makes every bookmark ahead. (3) The template function `config("<name>")` sees only the jj-cli defaults `template_defaults_layer` selected, so `config("ui.color")` renders empty where the CLI renders its default. (4) `workspace add` builds no start-up environment for the new workspace: the CLI reports alias / `immutable_heads()` / short-prefixes warnings twice and renders the new workspace's trailers with the new workspace's environment; Zanshin warns once and uses the old one.

**Approach:** (1) An optional edited text on `squash` and the two edited texts on `split`, modelled as the CLI's `--editor` whose editor saves exactly that text: the description step runs as it does with the editor (templates render, errors refuse, diagnostics warn), then the edited text goes through `cleanup_description_lines` and is written with no trailers; `-m` together with an edited text refuses. (2) A new read `Repo::git_push_remotes` (9.20's default-remote resolution, shared with `git push`) reaches Dart; `trackingStatusOf` counts the null-target row only for those remotes. (3) Every layer of `jj_cli::config::default_config_layers()` goes into the stack below Zanshin's builtin layer, replacing the selected layer. (4) `workspace add` builds the new workspace's `CommandEnv` into its own collector right after `init_workspace_with_existing_repo`, as `creation.rs::workable_env` does, and renders / finishes with it.

## Boundaries & Constraints

**Always:**
- The CLI at v0.46.0 is the spec (`git -C ../jj show v0.46.0:<path>`): `cli/src/commands/squash.rs:356-400` (with `args.editor`), `cli/src/commands/split.rs:290-385` (`use_editor`), `cli/src/description_util.rs` `edit_description` `:193-204`, `parse_bulk_edit_message` (each section `cleanup_description_lines`), `cli/src/commands/git/push.rs:294-323` + `get_default_push_remotes` `:1107-1130`, `cli/src/config.rs` `default_config_layers` `:860-879`, `cli/src/commands/workspace/add.rs:165-228` (`for_workable_repo` at `:193`), `cli/src/cli_util.rs:836-847`, `:961-991`.
- Item 1, squash: `SquashOptions.edited_description: Option<String>`. Given (and something is squashed), the squashed description is `cleanup_description_lines(edited.lines())`, after the description step ran as the CLI's `--editor` runs it: single arm (`-u`, one non-empty, or empty) = set description, `add_trailers`, set it, hidden write, `Templates::editor_text` rendered and discarded; combine arm = today's path, its editor text discarded. Nothing squashed → no description written (the CLI opens no editor). `edited_description` with `message` → `MutateError::InvalidInput` "--message cannot be used with an edited description", checked with the other clap conflicts in `plan_squash` before any resolution (so `squash_plan` refuses it too); with `use_destination_message` it is allowed (the CLI allows `-u --editor`). `squash_plan` otherwise ignores the field.
- Item 1, split: `SplitOptions.edited_selected_description` and `edited_remaining_description: Option<String>`, both or neither. Given, the no-`-m` editor path of `describe_split` runs unchanged, then the first builder gets `cleanup(selected)`, the second `cleanup(remaining)`, no trailers. Refusals (InvalidInput, checked first in `prepare_split`): with `message` → "--message cannot be used with an edited description"; exactly one given → "an edited split needs both descriptions: the selected and the remaining".
- Item 1 crosses every layer: `.fbs` fields APPENDED at the end of `SquashRequest` (`edited_description: string`) and `SplitRequest` (`edited_selected_description: string`, `edited_remaining_description: string`) — never reordered; FFI read fns; `cargo make codegen` outputs committed; Dart `RepoHandle.squash({String? editedDescription})`, `RepoHandle.split({String? editedSelectedDescription, String? editedRemainingDescription})` (not on `squashPlan`), commands, isolate, interior-NUL guards extended to the new strings; `docs/ffi-abi.md` and Rust/Dart docs name the fields and refusals.
- Item 2: `Repo::git_push_remotes(&mut self) -> Result<Vec<String>, MutateError>` (through `with_verb`): exactly `resolve_remotes`' no-`--remote` arm (`git.push` name / list / pattern via `crate::config::git_push_remotes` + `union_expression`, else the single remote with no hint, else `exact("origin")`) matched against the remote names in remote order, factored into ONE helper `push.rs` and `git push` share; the `PushRemotesUnmatched` warning as push emits it; NO match → `Ok(vec![])` (the push verb keeps its "No git remotes to push to" refusal); a non-Git backend → `Ok(vec![])`; a wrong-typed `git.push` → `MutateError::Config`, a bad pattern → `InvalidInput`, as push. FFI extern `zanshin_git_push_remotes(handle)` with a new payload table (`GitPushRemotes { names: [string] }`) modelled on `zanshin_remotes` / table `Remotes`; Dart `RepoHandle.gitPushRemotes()` → `WarnedList<String>`; a real-cdylib `zanshin_core` test for the extern.
- Item 2, app: `trackingStatusOf(headRefs, bookmarks, {required Set<String> pushRemotes})` gates ONLY the `bookmark.target == null` term on `pushRemotes.contains(remoteName)`; the distance terms stay for every tracked non-`git` remote. `statusFrom` gains `required Future<Iterable<String>> Function() pushRemotes`, awaited only on the path that already awaits `bookmarks()`; `worker_project_repos.dart` passes `handle.gitPushRemotes()` and logs its warnings like the bookmarks read.
- Item 3: `load_raw` pushes every layer `jj_cli::config::default_config_layers()` returns (each `ConfigSource::Default`, built once per process like `TEMPLATE_DEFAULTS`) right after jj-lib's defaults and BEFORE `BUILTIN_CONFIG_TOML`, replacing `template_defaults_layer` / `TEMPLATE_KEYS` / `TEMPLATE_TABLES`; `BUILTIN_CONFIG_TOML` stays as it is (its `revsets.log` keeps winning). Docs that say "an unread default is a lie" for template defaults are rewritten to Ralph's 2026-10-20 decision.
- Item 4: in `workspace_add::add`, right after `init_workspace_with_existing_repo` and the in-current-directory warning (the CLI's order), `CommandEnv::load` for the NEW workspace into a fresh `Warnings`, extended into `ctx.warnings` (as `creation.rs:132-142`); the trailer render uses its immutable set, aliases and short-prefixes (`Templates::new`/`at` over it) and `finish_transaction` its immutable set; `add_trailers_for`'s own short-prefixes re-parse goes. A failure of that load refuses the call as the old workspace's would (map its `PreconditionError`); the wrong claims that the CLI repeats the parse silently (`warning.rs` `Load::ShortPrefixes` doc ~`:213-215`, `workspace_add.rs:236-238`) are corrected.
- Rust: clippy pedantic `-D warnings`, rustfmt, rustdoc where rules change; coverage never drops, new code ≥ the floor. Dart: `dart analyze` / `dart format` clean. Oracle scenarios are the acceptance criteria of the mutating changes.

**Never:**
- No change to `-m`'s trailer behaviour, to `squash_plan`'s output, or to split/squash without the new fields; no `split_plan`; no `--editor` flag on the API.
- No reordering of existing `.fbs` fields; no new error code; no MCP change; no UI widget or visual change (the composer is 10.25).
- No edit of `BUILTIN_CONFIG_TOML`'s content; no adoption of the CLI's `revsets.log = "builtin_log()"`.
- No port of `templates.commit_summary` / `op_summary` parsing for any verb; never regenerate fixtures; never lower `coverage-baseline.txt`; no edit of `epics.md` or `project-context.md`.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Squash round trip, trailer deleted | `templates.commit_trailers` set; B, C described; `squash_plan` text with its `Signed-off-by` line(s) removed → `edited_description` | squashed description = that text cleaned, no trailer; equals the CLI with an editor script deleting the same lines | — |
| Squash round trip, unchanged | same, plan text passed unchanged | exactly one trailer; equals the CLI with `ui.editor = "true"` | — |
| Squash single arm + edit | one non-empty description, or `-u`, plus `edited_description = "E\n"` | description `E\n` | — |
| Split with edits | trailers set; `split -r X <path>`, both edited texts | first = cleaned selected, second = cleaned remaining, no trailers; equals the CLI's bulk-editor script result | — |
| Conflicts | `message` + edited (squash, squash_plan, split); only one split text | refused | `jj.invalid_input` with the texts above |
| Push targets | remotes `origin`, `upstream`, no `git.push` | `git_push_remotes() == ["origin"]` | — |
| Push targets, config | `git.push = "upstream"` / `["a","b"]` / a pattern / one remote `fork` / none / native backend | the matched names / `["fork"]` / `[]` / `[]` | unmatched exact name warns `PushRemotesUnmatched` |
| Ahead rule | `main` local, tracked `origin` row no target, `origin` a push target | `ahead` | — |
| Ahead rule, non-target | tracked `upstream` row no target, push targets `["origin"]` | clean (null) | — |
| `config()` default | a template calling `config("ui.color")` | renders the CLI's value | — |
| Workspace add, bad alias | `template-aliases.'x('` = `'1'` (or diagnosed short-prefixes) | the warning appears twice, as the CLI | — |

</intent-contract>

## Code Map

- `crates/zanshin-jj/src/squash_split.rs` -- `SquashOptions` :71-90, `SplitOptions` :108-132; `plan_squash` :200 (conflict checks :206-215); `squash` :324 (calls `squashed_description` :356); `squash_plan` :398 (ignores the field); `squashed_description` :455-489 (single arm :471-477, combine :478-488 — add the edited/`--editor` handling); `prepare_split` :510 (conflicts :516-526); `describe_split` :707-738 (no-`-m` path; apply the edited texts after it); module doc :13-35.
- `crates/zanshin-jj/src/op_support.rs` -- `cleanup_description_lines` :334-352 (reuse), `complete_newline` :366.
- `crates/zanshin-jj/src/template.rs` -- `Templates::add_trailers` :306, `editor_text` :353, `Templates::at` :168 (doc mentions workspace add's own short-prefixes — update).
- `crates/zanshin-jj/src/repo.rs` -- `Repo::squash` :2187 (# Errors :2170), `squash_plan` :2209, `split` :2262 (# Errors :2244-2258); `list_remotes` :570 (shape for the new `git_push_remotes`); `with_verb` :378; `workspace_add` ~:1899-1916.
- `crates/zanshin-jj/src/push.rs` -- `resolve_remotes` :784-827 (factor the default-remote resolution out of it); `plan_push` :1219-1227 caller.
- `crates/zanshin-jj/src/config.rs` -- `BUILTIN_CONFIG_TOML` :189-246 (unchanged), `TEMPLATE_DEFAULTS` :249, `TEMPLATE_KEYS` :253, `TEMPLATE_TABLES` :265, `template_defaults_layer` :281-304, `load_raw` :935-972 (layer order), `git_push_remotes` :1575-1584; inline test of the layer :2096-2140 (rewrite).
- `crates/zanshin-jj/src/workspace_add.rs` -- `add` :134-233 (`init_workspace_with_existing_repo` :163-170, cwd warning :171-176, tx :183, `add_trailers_for` call :202, `finish_transaction` :210-220 with the OLD `ctx.immutable`); `add_trailers_for` :245-268 (old aliases + re-parsed short-prefixes); doc :236-238.
- `crates/zanshin-jj/src/creation.rs` -- `workable_env` :132-142 (fresh collector + `sink.extend(own.take())` pattern).
- `crates/zanshin-jj/src/snapshot.rs` -- `CommandEnv::load` :347-371 (load order, record-once kinds); `VerbContext` :376-411.
- `crates/zanshin-jj/src/warning.rs` -- record-once `Load` kinds :203-246 (`Load::ShortPrefixes` doc claim to correct).
- `schemas/envelope.fbs` -- `SquashRequest` :176-185 (+doc :164-175), `SplitRequest` :201-210 (+doc :187-200), `Remotes` :922 (model for the new payload table and its union entry).
- `crates/zanshin-ffi/src/squash_split.rs` -- `read_squash_request` :49-67, `read_split_request` :77-94, externs :143/:191/:247 (# Errors docs); `crates/zanshin-ffi/src/remotes.rs` :82 (model for `zanshin_git_push_remotes`); `crates/zanshin-ffi/tests/squash_split_ffi.rs` builders :162/:184.
- `packages/zanshin_core/lib/src/ffi/squash_split.dart` -- `_squashRequest` :26, `zanshinSquash` :65, `zanshinSplit` :123; `lib/src/worker/commands.dart` `SquashCommand` :1368, `SplitCommand` :1458; `lib/src/worker/isolate.dart` `squash` :1299, `split` :1379 (NUL guards :1390-1395), `_rejectSquashNuls` :1441, dispatch :2746/:2804; `lib/src/worker/handle.dart` `squash` :645, `split` :720, `bookmarks` :278, `remotes` :290; tests `test/worker/squash_split_test.dart` (:81, :157, :193), `test/ffi/squash_split_test.dart` :126; remotes worker/ffi files as the model for `gitPushRemotes`.
- `app/lib/src/features/projects/project_repos.dart` -- `statusFrom` :100-115, `trackingStatusOf` :121-146 (null-target term :136); `app/lib/src/features/projects/worker_project_repos.dart` `read` :91-121.
- `app/test/features/projects/worker_project_repos_test.dart` -- `_notCreatedYet` :24-30, null-target cases :141-151 (upstream → now clean unless a push target), guards :118-119, `statusFrom` case :188.
- `crates/zanshin-parity/tests/oracle/scenarios.rs` -- `Scenario` :46-58; `EDITOR_STEP` :291, `TRAILERS_STEP` :239-245, `TRAILERS_EDITOR` :294, `C2_EDITOR_TRAILERS` :316; `squash_plan_as_message` :1077-1095 (model for the round trip); split trailer scenarios :1806-1879; `NEW_DESCRIPTION` :282 (model for the `config()` scenario); `BAD_TEMPLATE_ALIAS_ENTRY` :269, `DIAGNOSED_SHORT_PREFIXES` :272-279; workspace add scenarios :848-895, :1748; `main.rs` `parity!` ids :38-191, count `assert_eq!(…, 158)` :211; `compare.rs:12-58` (warning counts compared).
- `crates/zanshin-jj/tests/` -- `api_stability.rs` :1089 (SquashOptions), :1104 (SplitOptions) name fields exhaustively; `squash_split.rs`, `templates.rs`, `workspace_add.rs`, `config_cmd.rs` for witnesses; a push-remotes witness file next to the push tests.
- `docs/ffi-abi.md` -- shared-table note :388-397, `SquashRequest` exception :417-423, error rows :515-517, bookmark rows ~:1436; `docs/rust-error-codes.md` only if an error list per call is documented there.

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/src/squash_split.rs` (+ `repo.rs` docs) -- item 1 fields, conflicts, editor-model description step, docs -- the round trip writes the user's text.
- `schemas/envelope.fbs`, `crates/zanshin-ffi/src/squash_split.rs`, codegen outputs, `packages/zanshin_core` (ffi builders, commands, isolate + NUL guards, handle), `docs/ffi-abi.md` -- item 1 across FFI/Dart -- 10.25 can send edits.
- `crates/zanshin-jj/src/push.rs`, `repo.rs` -- the shared default-remote helper and `Repo::git_push_remotes` -- item 2's list.
- `schemas/envelope.fbs`, `crates/zanshin-ffi/src/` (new extern), codegen outputs, `packages/zanshin_core` (command, isolate, handle, decode), `docs/ffi-abi.md` -- item 2 reaches Dart.
- `app/lib/src/features/projects/project_repos.dart`, `worker_project_repos.dart` -- item 2 rule.
- `crates/zanshin-jj/src/config.rs` -- item 3 layers + docs + rewritten inline test.
- `crates/zanshin-jj/src/workspace_add.rs`, `template.rs`, `warning.rs` docs -- item 4.
- `crates/zanshin-jj/tests/` -- Rust witnesses: squash edited (single + combine arm, empty-squash ignores it), split edited, all conflicts; `git_push_remotes` per matrix row; `config get ui.color` / a template rendering `config("ui.color")`; workspace add warns twice; update `api_stability.rs`.
- `crates/zanshin-ffi/tests/squash_split_ffi.rs` + new push-remotes FFI test; `packages/zanshin_core/test/worker/` real-cdylib tests (new fields cross; `gitPushRemotes` returns names); `test/ffi` NUL-guard cases.
- `app/test/features/projects/worker_project_repos_test.dart` -- origin-vs-upstream `trackingStatusOf` and `statusFrom` cases; existing upstream cases rewritten to the new rule.
- `crates/zanshin-parity/tests/oracle/{scenarios,main}.rs` -- scenarios: `squash_plan_edited_trailer_deleted` (CLI `ui.editor` a script deleting `Signed-off-by` lines), `squash_plan_edited_unchanged` (CLI `ui.editor = "true"`), `split_edited_trailer_deleted` and `split_edited_unchanged` (script keeps the `JJ: describe` headers; Zanshin passes literal texts), `new_description_config_ui_color`, `workspace_add_bad_template_alias`, `workspace_add_diagnosed_short_prefixes`; bump the count.
- `coverage-baseline.txt` -- commit an auto-raise if the gate makes one; never lower.

**Acceptance Criteria:**
- Given `cargo test -p zanshin-parity --test oracle`, when it runs, then every scenario including the new ones matches the pinned CLI with no new ledger entry.
- Given a Dart caller, when it calls `squash(editedDescription:)`, `split(editedSelectedDescription:, editedRemainingDescription:)` and `gitPushRemotes()` through the real cdylib, then the fields arrive and the names come back.
- Given an unchanged `git push` scenario set, when the oracle runs, then push behaviour is unchanged by the shared helper.
- Given `cargo make test` on the final tree (repo root, unpiped, synchronous), then it exits 0 and `coverage-baseline.txt` is not lowered.
- Given the end of the run, then `git status --porcelain` is clean and every commit ends with the required co-author trailer and was made with `--no-gpg-sign`.

## Spec Change Log

## Review Triage Log

## Design Notes

**Item 1 = `--editor` with a scripted editor.** The CLI writes `cleanup_description_lines(saved buffer)` in every arm where its editor opens, after rendering the draft (trailers added, `templates.draft_commit_description` rendered). Modelling the field as "the editor saved this" keeps the render's refusals and diagnostics identical to the CLI's and lets the oracle drive the stock CLI with `--editor` / `ui.editor` set to a script. Example: B = `B\n\nSOB\n`, C = `C\n`, trailers on: plan `B\n\nSOB\n\nC\n`; unchanged as `edited_description` → `B\n\nSOB\n\nC\n` (today's `-m` gives a second SOB).

**Scripted editor (oracle).** `ui.editor` as a TOML array, the path substituted for `$path`, e.g. `["sh","-c","grep -v Signed-off-by \"$1\" > \"$1.t\"; mv \"$1.t\" \"$1\"","sh","$path"]`; for split it keeps the `JJ: describe` headers, so the hidden-commit hashes need not be known.

**Item 3 overlap.** Every `BUILTIN_CONFIG_TOML` key repeats a CLI default with the same value except `revsets.log`; the jj-cli layers below it therefore change no value Zanshin reads, only what `config()` and `config get` / `config list --include-defaults` see.

## Verification

**Commands:**
- `cargo test -p zanshin-jj --test squash_split --test templates --test workspace_add --test api_stability` and the new push-remotes test -- expected: green.
- `cargo test -p zanshin-ffi` -- expected: green.
- `cargo test -p zanshin-parity --test oracle` -- expected: all pass.
- `flutter test test/features/projects/worker_project_repos_test.dart` (in `app/`) and `flutter test test/worker/squash_split_test.dart` (in `packages/zanshin_core`) -- expected: green.
- `cargo make test` (repo root, unpiped, synchronous, long timeout; PATH with `~/development/sdks/flutter/bin` and `~/development/sdks/cargo/bin`, `CARGO_HOME=~/development/sdks/cargo`, `RUSTUP_HOME` unset) -- expected: exit 0; coverage held or raised.
