---
title: 'Story 9.49: `commit` — `[-m] [paths]` (the GUI-tree arm waits for 9.50)'
type: 'feature'
created: '2026-10-19'
status: 'done'
baseline_revision: 'a23d5a4363ce148defda70e10b92307c594d8602'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
warnings: [oversized]
deferred:
  - summary: >-
      The GUI-tree arm of `commit` (a tree from `select_tree` plus `left`, and its staleness refusal) waits for Story 9.50, which decides the contract and the refusal code; 9.49 ships the everything / paths arms only.
    evidence: |-
      epics.md Story 9.49 "Depends on. … 9.50 for the tree arm only"; Story 9.50 item 3 ("The verbs that take a tree id (9.15, 9.49) take `left` as well, and refuse the same way"); 9-50-hunk-selection-select-tree is backlog in sprint-status.yaml. SelectedTree::from_tree_id (crates/zanshin-jj/src/op_support.rs) stays unwired.
    location: >-
      crates/zanshin-jj/src/commit.rs (selection); Story 9.50
    severity: medium
  - summary: >-
      `templates.commit_trailers` is not applied by `commit` either: with a non-empty description the CLI renders the trailers template (commit.rs:148-153 @ v0.46.0), Zanshin writes the `-m` text alone — the existing ledgered gap, now witnessed for `commit` too.
    evidence: |-
      commit.rs:144-153 @ v0.46.0 (`add_trailers` when the description is non-empty); ledger entry `describe_commit_trailers` (crates/zanshin-parity/tests/oracle/ledger.rs) and deferred-work.md "Surfaced 2026-10-08 while analysing 'fork jj instead of re-porting the CLI'". Zanshin renders no jj templates.
    location: >-
      crates/zanshin-jj/src/commit.rs; crates/zanshin-parity/tests/oracle/ledger.rs
    severity: medium
  - summary: >-
      `jj new` (one parent, no `-A`/`-B`) advances bookmarks under `experimental-advance-branches` too (new.rs:194-204, :279-281 @ v0.46.0); Zanshin's `new_change` does not. The matcher and advance helpers this story adds are the ones `new` would reuse.
    evidence: |-
      new.rs:197-202 calls get_advanceable_bookmarks(parent.parent_ids()) and :280-281 advances to the single parent; crates/zanshin-jj/src/mutate.rs new_change has no advance step; epics.md Story 9.48 only covers "no bookmark advances when -A or -B is given".
    location: >-
      crates/zanshin-jj/src/mutate.rs new_change; Story 9.48
    severity: low
    resolved: >-
      2026-10-19 — fixed (spec-9-49-closing-new-advance-escaping-paths, commit b605329): new_change advances the bookmarks experimental-advance-branches selects for a single parent, reusing commit.rs' helpers; six oracle scenarios.
  - summary: >-
      The shared prefix matcher accepts a path that escapes the repo (`../x`) as a literal prefix, so `commit`, `restore`, `squash` and `split` warn and run where the CLI refuses "Path is not in the repo"; the I/O matrix's "Invalid path" example `../x` therefore does not refuse (`/x` does).
    evidence: |-
      op_support::parse_prefixes uses RepoPathBuf::from_internal_string, which accepts `..` components (build_matcher's doc deliberately adds no rule beyond jj's); review of Story 9.49 ran `commit(paths: ["../x"])` and it committed. `file track`/`untrack` (Story 9.22) already parse cwd-relative and refuse escaping paths (crates/zanshin-jj/tests/file_track_untrack.rs paths_normalise_like_the_cli_and_escaping_paths_are_refused).
    location: >-
      crates/zanshin-jj/src/op_support.rs build_matcher / parse_prefixes
    severity: low
    resolved: >-
      2026-10-19 — fixed (spec-9-49-closing-new-advance-escaping-paths, commit b605329): parse_prefixes resolves entries with ui_path::parse_fs_path and refuses a path outside the repo with the CLI's text; an oracle scenario per path verb.
---

<intent-contract>

## Intent

**Problem:** The inspector's composer (10.25, 10.26) commits `@`, and zanshin-jj has no `commit` verb: the GUI would have to chain `describe` and `new`, which writes two operations, never splits `@` by paths, and skips the CLI's bookmark advance.

**Approach:** Port `cmd_commit` (`../jj` v0.46.0 `cli/src/commands/commit.rs`) step for step over jj-lib as one verb, `Repo::commit(&CommitOptions { paths, message })`, wired end to end (`.fbs` → zanshin-jj → `zanshin_commit` → `WorkerCommand` → `RepoHandle.commit`). The selection is everything (no paths) or the given paths; the GUI-tree arm is 9.50's.

## Boundaries & Constraints

**Always:**
- The CLI at v0.46.0 is the spec (`git -C ../jj show v0.46.0:cli/src/commands/commit.rs`, `cli/src/cli_util.rs` `get_advanceable_bookmarks` :2678-2701 / `advance_bookmarks` :2880-2898 / `load_advance_bookmarks_matcher` :921-940): order of checks, op description byte-identical (`commit <@'s commit id, full hex, after the pre-verb snapshot>`), every on-disk effect.
- Check order: no working-copy commit for this workspace → refusal (`MutateError::NoWorkingCopy`, code `jj.no_working_copy`); then path validation (`build_matcher`); then the advance-bookmarks config (`experimental-advance-branches.enabled-branches` / `disabled-branches`, parsed as name patterns exactly like `bookmark_ops`' union helper; a bad pattern → `jj.invalid_input`, an unreadable key → `jj.config_error`); all before the transaction.
- Selection: `left` = `@`'s parent tree (commit.rs:103); selected tree = `SelectedTree::from_paths` over `left` → `@`'s tree with the shipped prefix matcher (`paths` empty = everything, `""` = root, exactly as `restore`/`squash`).
- Warning: when `paths` is non-empty and the selected tree equals `left` (tree ids), push a NEW 9.32 warning `jj.commit_paths_unmatched` with the CLI text verbatim: `The given paths do not match any file: ` + the paths joined by one space (commit.rs:128-134). The commit still runs. No other unmatched-path warning (commit.rs never calls `print_unmatched_explicit_paths`).
- Description: `message` is the CLI's `-m` paragraph list, joined by `op_support::join_message_paragraphs` (an empty list ≡ `-m ""`); it is written as is, no cleanup.
- Effect (commit.rs:136-193): `@` is rewritten in place (same change id) with the selected tree and the description; jj-lib records the rewrite, so bookmarks on the old `@` follow it and descendants of the old `@` are rebased onto it. Then a NEW commit on top of it with the old `@`'s full tree; every workspace whose `@` was the old `@` (`view.workspaces_for_wc_commit_id`) edits the new commit; advanceable bookmarks (local bookmarks on the old `@`'s parents that match the matcher) move to the committed commit via `merge_local_bookmark(old → committed)`; no other bookmark moves.
- `[experimental-advance-branches] enabled-branches = [] / disabled-branches = []` is added verbatim to `BUILTIN_CONFIG_TOML` (`cli/src/config/misc.toml:20-22`); `enabled-branches` empty = the feature off (no bookmark advances).
- Runs through `Repo::with_verb` (9.26 snapshot + 9.32 warnings) and `finish_verb`; `commit` always writes one operation, like the CLI (9.40's gate is still backlog and could never fire here).
- No rewritability guard: `commit.rs` calls no `check_rewritable`, so neither does Zanshin.

**Never:**
- No tree-id / `left` arm (deferred to 9.50), no `--interactive`, `--tool`, `--editor`; no editor arm and no empty-message hint (`message` is required — the GUI always passes `-m`).
- No trailers (the ledgered `templates.commit_trailers` gap); no hints; no MCP tool; no UI code.
- No advance step for `new_change` (deferred); no new error code (only the new warning code).
- Never regenerate fixtures; never lower the coverage baseline or add an `exclude_prefix`.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Everything | `@` = C with c.txt changed, `paths` [], `message` ["first"] | C keeps its change id, gets "first\n" and its full tree; new empty `@` on C; op `commit <C hex>`; `new_change_ids` = [new `@`] | — |
| Two of three paths | `@` adds x, y, z (and nothing else); `paths` [x, y] | committed `@`'s diff = x, y; new `@` on it has the old `@`'s full tree (its diff = z only) | — |
| Empty message | `message` [""] or [] | committed description "" | — |
| Empty `@`, empty message | `@` empty and undescribed, `message` [""] | as the CLI: `@` rewritten (not abandoned), new empty `@` on it (`test_commit_with_empty_description_from_cli`) | — |
| Unmatched path | `paths` [nope.txt] | warning `jj.commit_paths_unmatched` "The given paths do not match any file: nope.txt"; committed `@` has `left`'s tree (empty diff), new `@` holds all changes | — |
| Unchanged path | `paths` [a.txt], a.txt exists but unchanged in `@` | same warning (selected tree = left) | — |
| Bookmark on `@` | bookmark `m` on C | `m` stays on the committed C (rewrite); not on the new `@` | — |
| Advance on | `experimental-advance-branches.enabled-branches = ["*"]`, `b-mark` on B = C's parent | `b-mark` moves to the committed C; with `disabled-branches = ["b-mark"]` it stays | bad pattern → `jj.invalid_input` |
| Child of `@` | `@` = C has a child D | D rebased onto the committed C; new `@` on the committed C | — |
| Two workspaces on `@` | ws2's `@` = this `@` | both workspaces edit the one new `@` | — |
| No working copy | this workspace forgotten (no `@`) | refusal, nothing written | `jj.no_working_copy` |
| Invalid path | `paths` ["../x"] | refusal before the transaction | `jj.invalid_input` |

</intent-contract>

## Code Map

CLI anchors at `v0.46.0`; jj-lib anchors in vendored `jj-lib-0.46.0/src`; Zanshin anchors at baseline `83dafae`.

**Prior art (read-only)**
- `cli/src/commands/commit.rs` — `cmd_commit` `:83-196`: working copy `:90-93`; matcher `:94-96`; advanceable bookmarks from `@`'s parent ids `:97-98` (before the tx); `base_tree = commit.parent_tree` `:103`; non-interactive select (= `restore_tree(right, left, matcher)`) `:116-127`; unmatched warning `:128-134`; `rewrite_commit(&commit).detach()` + `set_tree` `:136-137`; description `:139-174` (the `-m` arm only); write `:175`; workspaces `:177`; new `@` with `commit.tree()` `:179-183`; advance `:186-187`; `edit` per workspace `:189-191`; op `:193`.
- `cli/src/cli_util.rs` — `load_advance_bookmarks_matcher` `:921-940` (enabled empty → `None`; matcher = enabled ∩ ¬disabled), `get_advanceable_bookmarks` `:2678-2701` (`view.local_bookmarks_for_commit(from)` filtered by the matcher), `advance_bookmarks` `:2880-2898` (`merge_local_bookmark(name, normal(old), normal(move_to))`). `cli/src/config/misc.toml:20-22` the defaults. `cli/src/description_util.rs:421-428` `join_message_paragraphs`.
- CLI tests to mirror: `cli/tests/test_commit_command.rs` `test_commit_with_description_from_cli` `:24`, `test_commit_with_empty_description_from_cli` `:105`, `test_commit_without_working_copy` `:385` (after `workspace forget`), `test_commit_paths` `:401`, `test_commit_paths_warning` `:426`, `test_commit_trailers` `:454`; `test_advance_bookmarks.rs` for the advance cases.
- jj-lib: `commit_builder.rs` `detach` `:50`, `DetachedCommitBuilder::write` `:401` (records the rewrite `:431`); `view.rs` `workspaces_for_wc_commit_id` `:73`; `repo.rs` `merge_local_bookmark` `:1882`, `edit` + `maybe_abandon_wc_commit` (step order matters: replicate the CLI's order exactly).

**Reuse — `crates/zanshin-jj`**
- `src/squash_split.rs` — the closest verb (`split` `:535-578`: `load_at_head` → `start_repo_transaction` → selection via `SelectedTree::from_paths` `:498-499` → `rebase_descendants` `:563` → `finish_verb(…, &format!("split commit {hex}"), ctx)` `:564` → `mutation_result` `:574`; workspace edit loop `:671-676`; config read `:558`; module header shape `:3-31`; `SplitOptions` derives `:103`).
- `src/mutate.rs` — `MutationResult` `:51`, `MutateError` `:107` (`NoWorkingCopy` `:288`, `InvalidInput` `:120`, `Config` `:157`), helpers `be` `:399`, `cfg` `:406`, `build_matcher` `:447`, `finish_verb` `:706`, `mutation_result` `:732`; `lock_working_copy` `:1169-1176` shows the `get_wc_commit_id(..).ok_or(MutateError::NoWorkingCopy)` idiom (`resolve_or_wc` maps a missing `@` to `Backend` — do NOT use it for this check).
- `src/op_support.rs` — `join_message_paragraphs` `:382`, `SelectedTree::from_paths` `:480` / `tree()` `:527`, `from_tree_id` `:514` stays `allow(dead_code)` (refresh its WHY to name 9.15 and 9.49), `start_repo_transaction` `:784`.
- `src/bookmark_ops.rs` — `union_expression` `:126` (the CLI's `parse_union_name_patterns`; make it `pub(crate)` and reuse it for both advance lists).
- `src/config.rs` — `BUILTIN_CONFIG_TOML` `:178` (add the table next to `[split]` `:198`, update the doc paragraph `:160-177`), accessor template `split_legacy_bookmark_behavior` `:1363`.
- `src/warning.rs` — `WarningKind` `:29` (append after `SplitNoneSelected` `:122`), `Warnings::push` `:168`.
- `src/repo.rs` — `with_verb` `:350`; facade/doc template `split` `:2031-2073` (add `commit` after `split`). `src/lib.rs` — modules `:30-60`, re-exports `:62-95`.
- `src/snapshot.rs:807-809` — the pre-verb snapshot already skips a workspace without `@`, so the verb's own check is reached.

**Extend — wire + FFI**
- `schemas/envelope.fbs` — request-tables comment `:31-49`, `RequestKind` doc `:51-73` (counts) + enum `:74-109` (append `Commit`), `SplitRequest` `:187` (template; add `CommitRequest` after it); payload = the existing `MutationResult` `:948` (no new payload).
- `crates/zanshin-ffi/src/squash_split.rs` — reader/extern template (`read_split_request` `:77`, `zanshin_split` doc `:199-239` + fn `:241`); `envelope.rs` warning consts `:283-285`, `warning_code()` `:290`, test `every_warning_kind_has_its_registered_code` `:1120` (`registered()` + `kinds`), `ok_mutation_result` `:638`, `precondition_envelope` `:434`; `repo.rs` `map_mutate_err` `:115`; `lib.rs` modules `:29-57`.
- Generated (only via `cargo make codegen`): `zanshin_ffi.h`, `envelope_generated.rs`, `bindings.dart`, `envelope_zanshin.ffi_generated.dart`.
- `docs/ffi-abi.md` — request tables `:374` (counts), `RequestKind` text `~:405`, symbol index `:453` (66 → 67, row after `:507`); `crates/zanshin-ffi/tests/ffi_abi_doc_sync.rs:37` `EXPECTED_EXPORTS` 66 → 67.
- `docs/rust-error-codes.md` — Warning Codes table `:88` (row after `:149`), checklist `:191-198`; "also emitted — Story 9.49" clauses on `jj.no_working_copy` `:47`, `jj.invalid_input`, `jj.config_error`.

**Extend — Dart (`packages/zanshin_core`)**
- `lib/src/ffi/squash_split.dart` — template for request builder + adapter (`zanshinSplit` `:123`); reuse `decodeMutationResultInternal` / the mutation envelope decoder of `lib/src/ffi/mutate.dart`, never re-spell it.
- `lib/src/worker/commands.dart` (`SplitCommand` `:1328`), `isolate.dart` (`split` `:1133-1179`, arm `:2461`), `handle.dart` (`split` `:595-627`), barrel `lib/zanshin_core.dart:35`; `lib/src/ffi/warning.dart` `ZanshinWarningCode` `:46` + `values` `:170`; `test/ffi/warning_test.dart` list `:410-412`, `hasLength(35)` → 36.

**Tests / gates**
- `crates/zanshin-jj/tests/squash_split.rs` — harness template (`wc` `:60`, `files` `:95`, `head_op` `:114`, `bookmark` `:119`, `base_with(repo_config)` `:127`, `assert_refused_without_an_operation` `:167`, two-workspace test `:815`).
- `crates/zanshin-jj/tests/api_stability.rs` — `squash_split_surface_resolves` `:1085` (template), warning pin `story_9_32_warning_surface_resolves` `:1335` (`:1381`, `:1418`).
- `crates/zanshin-ffi/tests/squash_split_ffi.rs` — FFI test template (`:301`, `:331`, `:349`).
- `packages/zanshin_core/test/{ffi,worker}/squash_split_test.dart` — synthetic + real-cdylib templates (header paragraph naming the extern-fn guard).
- `crates/zanshin-parity/tests/oracle/` — `scenarios.rs` (`BASE` `:31-39`: A a.txt → B b.txt + `b-mark` → C c.txt = `@`; `Step::{Jj, JjAt, Write}` in `driver.rs:63`; `C2` `:233`; split scenarios `:872-1026`; trailers scenario `:474-490`; second workspace `:525-541`), `main.rs` `parity!` list `:37-98` + `SCENARIO_IDS.len() == 60` `~:110`, `ledger.rs` (`describe_commit_trailers` `:111-118` = the template for the commit trailers entry). Warnings compare as a count.
- `coverage-baseline.txt` — `mutate.rs` 99.52, `op_support.rs` 99.72, `squash_split.rs` (jj) 99.75, `warning.rs` 100, ffi `envelope.rs` / `squash_split.rs` 100; new files ≥ 80.

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/src/config.rs` + `src/bookmark_ops.rs` -- add `[experimental-advance-branches] enabled-branches = []` / `disabled-branches = []` verbatim to `BUILTIN_CONFIG_TOML` (doc paragraph names Story 9.49 and misc.toml:20-22) and a `pub(crate)` accessor returning both lists (`Config` on a bad value); make `union_expression` `pub(crate)`.
- `crates/zanshin-jj/src/warning.rs` -- append `CommitPathsUnmatched` with rustdoc citing commit.rs:128-134 @ v0.46.0 and Story 9.49.
- `crates/zanshin-jj/src/commit.rs` (new) -- module doc (parity tag v0.46.0, ported anchors, deliberate divergences from **Never**); public `CommitOptions { paths: Vec<String>, message: Vec<String> }` (`Debug, Clone, Default, PartialEq, Eq`); `pub(crate) fn commit(workspace, ctx, options) -> Result<MutationResult, MutateError>` ported step for step (check order, selection, warning, rewrite, new `@`, advance, `edit` per workspace, `rebase_descendants` before `finish_verb(…, "commit <hex>")`, `mutation_result(&finish, vec![new @ change id], vec![])`); private advance helpers (matcher from the two lists, advanceable list from the old `@`'s parent ids, `merge_local_bookmark` per entry) kept separate so `new` can reuse them later; inline unit tests for the matcher (enabled empty → none, enabled ∩ ¬disabled, bad pattern → `InvalidInput`).
- `crates/zanshin-jj/src/repo.rs` + `src/lib.rs` + `src/op_support.rs` -- `#[must_use]` facade `commit(&CommitOptions) -> Result<MutationResult>` through `with_verb` with the house doc block (`# Errors` one bullet per reachable variant; the selection, warning, bookmark and workspace rules; op `commit <hex>`); module + re-export; refresh `from_tree_id`'s WHY.
- `schemas/envelope.fbs` -- `RequestKind.Commit`; `CommitRequest { kind, paths:[string], message:[string] }` (absent = empty); update the table counts in the comments; payload `MutationResult`.
- `crates/zanshin-ffi/src/commit.rs` (new) + `lib.rs` + `envelope.rs` -- owned request reader (`reject_null_request`, `expect_request_kind(…, Commit)`), `zanshin_commit` (`precondition_envelope` + `map_mutate_err` + `ok_mutation_result`), warning const `JJ_COMMIT_PATHS_UNMATCHED = "jj.commit_paths_unmatched"` + `warning_code()` arm + table test rows; full rustdoc (`# Errors`, `# Safety`).
- `cargo make codegen` -- regenerate and commit the four generated files with the schema/extern change.
- `packages/zanshin_core/lib/src/ffi/commit.dart` (new) + `worker/{commands,isolate,handle}.dart` + `lib/src/ffi/warning.dart` -- request builder + adapter decoding through the existing mutation-result decoder, `CommitCommand` before `ShutdownCommand`, worker method + dispatch arm (`_invalidHandleEnvelope`), `RepoHandle.commit({required List<String> message, List<String> paths = const []})` behind the close guard with interior-NUL rejection on the calling side; `ZanshinWarningCode.commitPathsUnmatched` (+ `values`).
- `crates/zanshin-jj/tests/commit.rs` (new) -- every matrix row against jj-lib state (op description verbatim, change ids, trees of both commits, descriptions, bookmarks, `@` of each workspace, warnings, refusals keep the op head), plus: an empty `@` with `-m ""` (old `@` not abandoned, matches the CLI order), and a directory prefix path.
- `crates/zanshin-ffi/tests/commit_ffi.rs` (new) -- reader (absent vs present vectors, malformed buffer, wrong kind), zero handle, a refusal envelope (`jj.no_working_copy` or `jj.invalid_input`), the warning on an ok envelope.
- `packages/zanshin_core/test/ffi/commit_test.dart` + `test/worker/commit_test.dart` (new) -- synthetic decode + NUL guards; real-cdylib round trip calling `zanshin_commit` (everything, paths with the warning, one refusal) with the extern-fn-guard header paragraph.
- `crates/zanshin-parity/tests/oracle/{scenarios,main}.rs` + `ledger.rs` -- scenarios: commit everything `-m`; two of three paths (setup writes x, y, z); `-m ""` on an empty `@` (after `jj new`); unmatched path (warning count 1); unchanged existing path (warning); bookmark on `@`; advance on (`enabled-branches = ["*"]`, `b-mark` moves); advance with `disabled-branches = ["b-mark"]`; `@` with a child (`jj new` then `jj edit @-`); second workspace editing the same `@` (`JjAt("../ws2", ["edit", …])`); no working copy (`workspace forget`) refused; `commit_trailers` with `templates.commit_trailers` set → a ledger entry modelled on `describe_commit_trailers` (reason + the deferred-work reference); bump the scenario count pin.
- `crates/zanshin-jj/tests/api_stability.rs` -- `commit_surface_resolves` (`CommitOptions` field by field, `Repo::commit` as a `fn` pointer); `CommitPathsUnmatched` in the 9.32 pin.
- `docs/rust-error-codes.md` + `docs/ffi-abi.md` -- the warning row, "also emitted — Story 9.49" clauses (`jj.no_working_copy` with the CLI text "This command requires a working copy"), symbol-index row, request table, counts.
- `_bmad-output/implementation-artifacts/{sprint-status.yaml,deferred-work.md}` -- at finalisation flip `9-49-commit-paths-or-gui-tree` to `done` with a sibling-style summary (bump `last_updated`); the `## Surfaced in Story 9.49 (bmad-build-auto, 2026-10-19)` section mirrors this spec's `deferred:` entries (written with this spec).

**Acceptance Criteria:**
- Given the verb exists, when a Dart caller reaches it, then the whole chain is present (`.fbs` table, zanshin-jj verb, `extern "C"`, committed codegen, adapter, `WorkerCommand`, worker method, `RepoHandle.commit`) and `ffi_abi_doc_sync` passes with 67 exports.
- Given every parity scenario above, when the oracle runs, then each matches the pinned CLI on every aspect (graph, descriptions, trees, working copies, bookmarks, ops written, op descriptions, outcome, warning count) or diverges only through the ledgered trailers entry.
- Given a commit with paths, when it finishes, then the committed `@` holds exactly the selected paths' changes over `@`'s parent tree and the new `@` holds exactly the rest (its tree = the old `@`'s tree).
- Given any refusal, when the op head is compared before and after, then it is unchanged and nothing was written (zanshin-jj and FFI layers).
- Given `cargo make test` on the final tree, then it exits 0 (clippy pedantic, fmt, doctests, Dart analyze/format/tests, cargo deny, coverage ratchet with the extern-fn guard; new files ≥ 80 %, no baseline lowered) and the raised `coverage-baseline.txt` is committed with the code.
- Given the end of the run, then `git status --porcelain` is clean and every commit ends with the required co-author trailer and was made with `--no-gpg-sign`.

## Spec Change Log

## Review Triage Log

### 2026-10-19 — Review pass
- verdicts: 26 findings — high 0, medium 4, low 16, false 6, maybe-false 0
- findings:
  - `[false]` `[reject]` (blind) spec `in-review` vs sprint-status `done` — finalisation sets the spec to `done` in this run; the yaml flip is the run's end state.
  - `[low]` `[reject]` (blind) a bad `experimental-advance-branches` pattern surfaces as `jj.invalid_input` without naming the key — the CLI's own refusal is the user error "Failed to parse name pattern: …", which does not name the key either; the spec routes CLI user errors to `jj.invalid_input`.
  - `[medium]` `[patch]` (blind) the finish rebased immutable descendants with plain `rebase_descendants` — fixed: `resolve_immutable` + `rebase_descendants_with_options` (the CLI's `rebase_mutable_descendants`); new oracle scenario `commit_immutable_wc_with_child` (fails with the old code: graph, trees, descriptions UNEXPECTED); `Repo::commit`'s `Config` bullet names the alias.
  - `[low]` `[patch]` (blind) merge `@`, conflicted bookmark and `paths: [""]` unwitnessed — fixed: `a_merge_at_advances_the_bookmarks_of_every_parent`, `a_conflicted_advanceable_bookmark_stays_conflicted`, `the_root_path_selects_everything` (crates/zanshin-jj/tests/commit.rs) and oracle `commit_advance_merge_parents`.
  - `[low]` `[patch]` (blind) no oracle refusal scenario for an invalid path or a bad advance config — fixed: `commit_path_outside_repo` (`/x`), `commit_advance_bad_pattern`, `commit_advance_not_a_list` (both sides refuse).
  - `[low]` `[reject]` (blind) the FFI suite witnesses one refusal code — every `map_mutate_err` arm is unit-tested (crates/zanshin-ffi/src/repo.rs:1400 for `NoWorkingCopy`); a no-`@` fixture in the FFI crate would need jj-lib, which that crate must not import.
  - `[low]` `[patch]` (blind) `jj.jj_lib_error` row lacks a Story 9.49 clause — fixed in docs/rust-error-codes.md.
  - `[low]` `[reject]` (blind) `NotAGitRepo` in the Rust errors but not the FFI docs — the same convention as `zanshin_squash`/`zanshin_split` (Story 9.15); not this story's to change alone.
  - `[low]` `[patch]` (blind) `union_expression`'s anchors still cite v0.44 — re-pinned to `revset_util.rs:364-384` @ v0.46.0.
  - `[low]` `[patch]` (blind) a ~170-character comment line in `from_tree_id`'s WHY — rewrapped.
  - `[low]` `[reject]` (blind) no `debug_assert!` for a non-empty `workspace_names` — a guard against a jj-lib invariant (the view's wc ids update only at the rebase) nobody meets in use.
  - `[low]` `[defer]` (blind) the matrix's "Invalid path" example `../x` is never exercised — verified: the shared `build_matcher` accepts `../x` as a literal prefix (pre-existing, also restore/squash/split), so it commits with the unmatched warning while the CLI refuses; `/x` refuses on both sides. Deferred (spec `deferred:` item 4, mirrored).
  - `[low]` `[patch]` (blind) `CommitRequest.message` doc said "required" though absent is accepted — now "optional on the wire" (schemas/envelope.fbs + regenerated code).
  - `[low]` `[patch]` (blind) the Dart paths round trip checked only the new `@` — now also the committed `@`'s description and the new `@` id.
  - `[medium]` `[patch]` (edge) immutable descendants rebased — same root as the blind rebase row; fixed there.
  - `[low]` `[reject]` (edge) a finish that mints another `@` would be missing from `new_change_ids` — needs `immutable_heads()` to cover a brand-new empty head; the same for every `@`-moving verb, never met in use.
  - `[low]` `[reject]` (edge) a malformed `ui.editor` does not refuse `commit` as the CLI's `text_editor()` does — a broken config every CLI command would trip on; the fix is a new config read and refusal branch.
  - `[low]` `[patch]` (verification-gap) conflicted bookmark / merge `@` advance untested — same group as the blind untested row; fixed there.
  - `[false]` `[reject]` (verification-gap, other) spec vs sprint-status status — same as the first row.
  - `[medium]` `[defer]` (intent) the GUI-tree arm is not built — the story's own "Depends on: 9.50 for the tree arm only"; already `deferred:` item 1 (a23d5a4), not added twice.
  - `[false]` `[reject]` (intent) paths are prefixes, not filesets — the fileset DSL is terminal input language (ADR-0003); every path verb takes prefixes.
  - `[medium]` `[defer]` (intent) trailers not applied — the open `commit_trailers` gap the story names; already `deferred:` item 2 and ledgered.
  - `[false]` `[reject]` (intent) no "no `-m`" state — the story drops the editor arm ("the GUI always passes `-m`").
  - `[false]` `[reject]` (intent) nothing tests the 9.40 gate — `commit` always writes a rewrite and a new commit; the gate cannot fire.
  - `[false]` `[reject]` (intent) status surfaces disagree — same as the first row.
  - `[low]` `[reject]` (intent) `jj.no_working_copy` not driven at FFI/Dart — same as the FFI refusal row.

## Design Notes

- **`message` is required.** The story drops the editor arm ("the GUI always passes `-m`"), so the API has no "no `-m`" state: `CommitOptions.message` is a plain `Vec<String>` (empty ≡ `-m ""`, `join_message_paragraphs(&[]) == ""`). Unlike 9.15, there is no "editor saved unchanged" fallback to define. A composer that wants to keep `@`'s description passes it back as one paragraph.
- **One code path for "everything" and "paths".** The CLI's "describe + new" is the same `cmd_commit` run with an everything matcher (selected tree = `@`'s tree). There is no separate describe/new branch: it is still one operation `commit <hex>`, and it still advances bookmarks.
- **No-working-copy code.** The condition is exactly `MutateError::NoWorkingCopy` (`jj.no_working_copy`, Story 9.22). The code is the contract. The variant's Display stays "nothing checked out in this workspace", and `docs/rust-error-codes.md` records the CLI's commit text next to it. No new error code.
- **Advance bookmarks.** They are computed from the repo the transaction starts on (after the 9.26 snapshot), before the transaction, as at commit.rs:97-98. Each one moves to the committed `@`, never to the new `@`. With the default config (`enabled-branches = []`) nothing moves. Example: `enabled-branches = ["*"]`, `b-mark` on B = `@-`. After `commit -m x`, `b-mark` is on C′ (the committed `@`), and the new `@` sits on C′.
- **9.40.** That gate is still backlog and `finish_verb` has none. `commit` always writes a rewrite and a new commit (the CLI never no-ops here), so the verb needs no gate of its own.

**Golden example** (BASE, `@` = C adds c.txt; write x.txt, y.txt, z.txt in `@`; `commit(paths: ["x.txt","y.txt"], message: ["first"])`): C keeps its change id. The selection starts from `@`'s parent tree B, so C′ = B + x.txt + y.txt (c.txt is NOT in C′: it was not selected). The new `@` = C′ + c.txt + z.txt, which is the old C tree. The op is `commit <C's commit hex after the snapshot>`.

## Verification

**Commands:**
- `cargo make codegen` -- expected: regenerated files committed, no further diff.
- `cargo test -p zanshin-jj --test commit` and `cargo test -p zanshin-parity --test oracle` -- expected: all pass.
- `cargo make test` (unpiped, synchronous, long timeout) -- expected: exit 0, coverage ratchet and extern-fn guard green.

## Auto Run Result

Status: done

**Summary.** `jj commit -m <paragraphs> [paths]` is ported step for step from `cmd_commit` at v0.46.0 and wired end to end (`.fbs` `CommitRequest` → `Repo::commit(&CommitOptions)` → `zanshin_commit` → `CommitCommand` → `RepoHandle.commit`). Checks run in the CLI's order before the transaction (no `@` → `jj.no_working_copy`, then paths, then `experimental-advance-branches`); the selection starts from `@`'s parent tree (no paths = everything); `@` is rewritten in place with the `-m` text, a new `@` holds the old `@`'s tree in every workspace on it, matching bookmarks on `@`'s parents advance to the committed `@`, and the finish rebases only mutable descendants. New warning `jj.commit_paths_unmatched` with the CLI text; `[experimental-advance-branches]` defaults added to the builtin config.

**Commits.** a23d5a4 (spec + deferrals mirrored), 121cb7c (feature), 8f20114 (review patches), plus the finalisation commit of this spec, deferred-work.md and sprint-status.yaml.

**Files changed.**
- `crates/zanshin-jj/src/commit.rs` (new) — the verb, `CommitOptions`, advance-bookmarks helpers.
- `crates/zanshin-jj/src/{config,warning,repo,lib,bookmark_ops,op_support}.rs` — builtin advance defaults + reader, `CommitPathsUnmatched`, the `Repo::commit` facade, re-export, `union_expression` shared, `from_tree_id` WHY.
- `schemas/envelope.fbs` + four generated files — `RequestKind.Commit`, `CommitRequest`.
- `crates/zanshin-ffi/src/{commit,envelope,lib}.rs` — `zanshin_commit` (67 exports), the warning code.
- `packages/zanshin_core` — `ffi/commit.dart`, worker command/method/arm, `RepoHandle.commit`, `ZanshinWarningCode.commitPathsUnmatched`.
- Tests: `crates/zanshin-jj/tests/commit.rs` (18), `crates/zanshin-ffi/tests/commit_ffi.rs` (5), `packages/zanshin_core/test/{ffi,worker}/commit_test.dart`, `api_stability.rs`, 17 parity scenarios (`commit_trailers` ledgered).
- Docs/ledgers: `docs/ffi-abi.md`, `docs/rust-error-codes.md`, `coverage-baseline.txt` (both `commit.rs` at 100), `sprint-status.yaml` (9-49 done), `deferred-work.md`.

**Review.** 26 findings (medium 4, low 16, false 6). Patched: the finish rebased immutable descendants (medium; `rebase_descendants_with_options` with the resolved immutable set, proven by `commit_immutable_wc_with_child`, which fails with the old code), plus seven low entries (merge `@` / conflicted bookmark / root-path witnesses, three oracle refusal scenarios, the `jj.jj_lib_error` clause, v0.46 anchors, a long comment line, the `CommitRequest.message` wire doc, the Dart paths assertion). Deferred: the shared prefix matcher accepting `../x` (low, new `deferred:` item 4, mirrored); the GUI-tree arm and trailers re-confirmed (items 1-2). Rejected with reasons in the triage log: the error code/context of a bad advance pattern (matches the CLI's user error), the single FFI refusal code (mapping unit-tested), `NotAGitRepo` docs (sibling convention), a `debug_assert`, a minted-`@` corner, a malformed `ui.editor`, and six false findings (status bookkeeping ×3, filesets, optional `-m`, the 9.40 gate).

**Follow-up review recommendation:** false — one medium entry patched, no high (patched counts: high 0, medium 1, low 7 entries).

**Verification.** `cargo test -p zanshin-jj --test commit` (18 pass), `cargo test -p zanshin-parity --test oracle` (86 pass; only `commit_trailers` diverges, through its ledger entry), `cargo make codegen` (committed, no further diff), clippy `-D warnings` on the touched crates clean, `cargo make test` exit 0 after the review patches (792 s; coverage ratchet and extern-fn guard green, baseline unchanged). Matrix audit: every row has a passing test except the literal `../x` example of the "Invalid path" row, which the shared matcher does not refuse — the row is covered with `/x` (refused on both sides) and the `../x` gap is deferred item 4.

**Residual risks.** The GUI-tree arm waits for 9.50; trailers and custom templates are not rendered; `jj new` does not advance bookmarks; path prefixes do not refuse `..` (all deferred). The `jj.no_working_copy` refusal is witnessed at zanshin-jj and in the oracle, not over FFI/Dart.

