---
title: 'Story 9.15: `squash`, `split` (partial-file) + the squash plan phase'
type: 'feature'
created: '2026-10-19'
status: 'in-progress'
baseline_revision: '6575d9ec7512b0ce4bca561aa4bd36c6db54ba00'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
warnings: [oversized]
deferred:
  - summary: >-
      The tree arm of squash and split (a GUI-selected tree plus `left`, its staleness refusal, and split's interactive default with no paths) waits for Story 9.50, which decides the contract and the refusal code; 9.15 ships the paths arm only and refuses a split without paths.
    evidence: |-
      epics.md Story 9.50 item 3 ("The verbs that take a tree id (9.15, 9.49) take `left` as well, and refuse the same way. This story decides the refusal code"); epic-9-context.md "9.50 → tree arms of 9.15/9.17/9.49"; split.rs:218 @ v0.46.0 makes no-paths interactive. SelectedTree::from_tree_id (op_support.rs:430) stays unwired.
    location: >-
      crates/zanshin-jj/src/squash_split.rs (selection), crates/zanshin-jj/src/op_support.rs SelectedTree::from_tree_id; Story 9.50
    severity: medium
  - summary: >-
      `jj squash -o/-A/-B` (experimental at v0.46.0: the squashed changes go into a NEW commit at that location) is not ported; no design row needs it (the drops "Into a new change after/before" are split -A/-B).
    evidence: |-
      squash.rs:113-146 and :274-326 @ v0.46.0 (marked experimental); epics.md Story 9.15 note lists only -r, --from/--into, -m/-u/-k for squash.
    location: >-
      crates/zanshin-jj/src/squash_split.rs
    severity: low
---

<intent-contract>

## Intent

**Problem:** The floating client's inspector and drops (10.8, 10.25, 10.27) need `jj squash` and `jj split`, and zanshin-jj has neither. The CLI decides the combined description of a squash inside the command and opens `$EDITOR` (squash.rs:383-399 @ v0.46.0), so the GUI cannot ask the user first (deferred-work I1).

**Approach:** Port `cmd_squash` (`-r`, `--from/--into`, paths, `-m`, `-u`, `-k`) and `cmd_split` (`-r`, paths, `-m`, `--parallel`, `-o/-A/-B`, `split.legacy-bookmark-behavior`) step for step at v0.46.0 over jj-lib, end to end (`.fbs` → zanshin-jj → `extern "C"` → `zanshin_core`). One shared squash preparation function serves both the verb and a read-only `squash_plan` call that returns the combined text whenever the CLI would open its editor; the split preparation is one function too, ready for 9.31.

## Boundaries & Constraints

**Always:**
- The CLI at v0.46.0 is the spec (`git -C ../jj show v0.46.0:cli/src/commands/{squash,split}.rs`, `cli/src/description_util.rs`): preconditions and their order, refusal texts verbatim, op descriptions byte-identical (`squash commits into <dest full hex>`, `split commit <target full hex>`), bookmark and `@` effects, abandonment.
- Paths are repo-relative PREFIXES through the shipped `build_matcher` (an empty list = everything, `""` = root), exactly as `Repo::restore`; the fileset DSL is terminal input language (ADR-0003). Unmatched explicit paths warn `jj.paths_unmatched` (squash: over the selected sources' trees; split: over `[parent_tree, tree]`).
- `message` is the CLI's `-m` paragraph list joined by `join_message_paragraphs` (move the private port from `workspace_add.rs:97-99` into `op_support.rs` §3). `None` = no `-m`.
- **No `-m` where the CLI opens its editor = the editor saved unchanged:** squash's combined case uses `cleanup_description_lines(combine_messages_for_editing(…))` (the `JJ:` lines dropped, leading/trailing newlines trimmed, one final `\n`); split without `-m` keeps the original description on both commits. The parity oracle proves both with `ui.editor = true` on the CLI side.
- `squash_plan` and `squash` share ONE preparation function (resolution, refusals, selection, `squash_commits`, description decision); the plan drops its transaction and writes no operation of its own (only the implicit snapshot's, like every read through `with_verb`).
- Every verb goes through `Repo::with_verb` (Story 9.26 snapshot + warnings, 9.32); refusals reuse registered codes (`jj.invalid_input`, `jj.immutable`, `jj.change_not_found`, `jj.config_error`, `jj.jj_lib_error`, precondition codes) — no new error code.
- Split's two selection warnings become new 9.32 warning codes `jj.split_all_selected` / `jj.split_none_selected` with the CLI texts verbatim (split.rs:585-594); full selection wins when both hold.
- `split.legacy-bookmark-behavior = true` is added verbatim to `BUILTIN_CONFIG_TOML` (`cli/src/config/misc.toml:67-68`) and read from the effective config.

**Never:**
- No tree-id / interactive arm, no `left`, no `--tool`, no `--editor` flag (deferred to 9.50 / terminal UX); `split` with an empty `paths` list refuses `jj.invalid_input` (the CLI would open its diff editor).
- No `squash -o/-A/-B` (deferred, experimental CLI flag); no hints; no trailers (`templates.commit_trailers` is the existing ledgered gap); squash's "is being interpreted as a fileset expression" warning (terminal argv parsing) is not ported.
- No split plan over FFI (9.31's diff source owns that preview); no MCP tool; no UI code.
- Never regenerate fixtures; never lower the coverage baseline or add an `exclude_prefix`.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Squash into parent | `revision` = C (or none = `@`), parent B, both described | C abandoned, B gets C's diff, description = B+C combined text; `@` abandoned → new empty `@` on B; op `squash commits into <B's commit hex before the squash>` | — |
| Merge or root | `revision` = a merge (or root) | refusal "Cannot squash merge commits without a specified destination" (squash.rs:241-246) | `jj.invalid_input`, no op |
| from/into | `from` = [C], `into` = A | C's changes in A, B and C rebased; `from` empty = `@`; `into` none = `@`; destination silently dropped from `from` | `revision` with `from`/`into` → `jj.invalid_input` |
| Into itself | `into` = `@`, `from` empty | nothing squashed → no operation, `new_op_id` = pre-call head | — |
| Partial | `paths` = [c.txt], C has c.txt + c2.txt | only c.txt moves; C kept (not abandoned) → only the destination's description counts → no editor case | — |
| Flags | `-m`, `-u`, `-k` | `-m` wins; `-u` = destination description; `-k` keeps an emptied source (empty commit) | `-u` with `-m` → `jj.invalid_input` |
| Plan | same args | `combined_description` = the text the verb would write when ≥2 of {abandoned sources, destination} are non-empty and no `-m`/`-u`; otherwise null; same refusals as the verb | as verb |
| Immutable | source or destination immutable | refusal | `jj.immutable` |
| Split serial | `revision` C, `paths` [c.txt], `-m` "first" | selected (c.txt, "first", keeps C's change id) → remaining (new change id, C's description, c2.txt); bookmarks and `@` on remaining (legacy true); descendants rebased; op `split commit <C hex>` | — |
| Split legacy false | config `split.legacy-bookmark-behavior=false` | bookmarks stay on the selected commit; `@` still on remaining | — |
| Split parallel | `parallel` | both commits on C's parents; descendants get both as parents | `parallel` with `-o/-A/-B` → `jj.invalid_input` |
| Split -o/-A/-B | `insert_before` [A] | selected part = new change at that location; remaining keeps C's change id, bookmarks, `@` | loop/immutable child refusals from `compute_commit_location` |
| Split all / none selected | paths cover everything / match nothing | warning `jj.split_all_selected` / (`jj.paths_unmatched` +) `jj.split_none_selected`; split still runs | — |
| Split no paths | `paths` = [] | refused (interactive arm is 9.50's) | `jj.invalid_input` |

</intent-contract>

## Code Map

CLI anchors at `v0.46.0`; jj-lib anchors in vendored `jj-lib-0.46.0/src`; Zanshin anchors at baseline `6575d9e`.

**Prior art (read-only)**
- `cli/src/commands/squash.rs` — args `:88-181`; `cmd_squash` `:184-458`: source/destination resolution `:197-248` (destination filtered out of `--from` `:213`, sources reversed `:219`, merge/root refusal `:241-246`); `check_rewritable(sources ∪ destination)` `:251-253`; tx description `:257-267`; `select_diff` `:485-533` (left = `source.parent_tree`); `print_unmatched_explicit_paths`; `squash_commits(…, keep_emptied)` `:349-355`; description decision `:357-399` + `SquashedDescription::from_args` `:460-483` (Combine uses ONLY `squashed.abandoned_commits`); empty description with no `--editor` stays empty `:367`; nothing selected → no-op `:424-455`.
- `cli/src/commands/split.rs` — args `:106-196`; `resolve` `:201-257` (check_rewritable, `compute_commit_location(…, "split-out commit")`, unmatched paths over `[parent_tree, tree]`); `select_diff` `:546-598` (left `:567`, warnings `:585-594`); `cmd_split` `:271-421` (first/selected `:293-319`, second/remaining `:322-355` incl. parallel tree = target minus inverted selected diff, editor path `:357-385`, writes `:387-393`, tx description `:418`); `rewrite_descendants` `:495-542` (legacy `set_rewritten_commit(target, second)` `:507`, parent replacement per mode, `edit(ws, second)` for every workspace on target `:535-539`); `move_first_commit` `:423-493` (`move_commits` with `EmptyBehavior::Keep`, `delete_abandoned_bookmarks: false`, `simplify_ancestor_merge: false`).
- `cli/src/description_util.rs` — `try_combine_messages` `:356-368`, `combine_messages_for_editing` `:374-415` (trailers block is the ledgered gap — skip it), `cleanup_description_lines` `:164-183`, `join_message_paragraphs` `:421-428`. `cli/src/config/misc.toml:67-68` `[split] legacy-bookmark-behavior = true`.
- CLI tests to mirror: `test_squash_command.rs` `test_squash` `:25` (merge refusal `:126-130`), `test_squash_partial` `:165`, `test_squash_keep_emptied` `:449`, `test_squash_from_to` `:502` (`--into @` = "Nothing changed." `:564-570`), `test_squash_description` `:1317` (editor text `:1385-1400`), `test_squash_use_destination_message` `:1713`; `test_split_command.rs` `test_split_by_paths` `:50`, `test_split_with_message` `:1313`, `test_split_parallel_*` `:541-890`, `test_split_move_first_commit` `:1371`, `test_split_with_bookmarks` `:1637-1757`, `test_split_with_multiple_workspaces_same_working_copy` `:1115`.

**jj-lib 0.46.0** — `rewrite.rs`: `restore_tree` `:181`, `merge_commit_trees` `:61`, `CommitRewriter::replace_parent` `:316`/`rebase` `:448`, `EmptyBehavior` `:540`, `RebaseOptions` `:561`, `RewriteRefsOptions` `:571`, `MoveCommitsLocation`/`MoveCommitsTarget` `:596-603`, `move_commits` `:656`, `CommitWithSelection` `:1307` (`is_full_selection`, `is_empty_selection`), `SquashedCommit` `:1358`, `squash_commits` `:1368` (returns an UNWRITTEN builder; abandon = `!keep_emptied && is_full_selection`). `repo.rs`: `rewrite_commit` `:1098`, `set_rewritten_commit` `:1115`, `transform_descendants` `:1494`, `rebase_descendants` `:1619`, `edit` `:1722`, `update_wc_commits` `:1335-1383` (abandoned `@` → new empty `@`).

**Reuse — `crates/zanshin-jj`**
- `src/op_support.rs` — `check_rewritable` `:136`; `compute_commit_location` `:199` (unwired; wire it, drop its `allow(dead_code)` and `ensure_no_commit_loop`'s `:272`); `try_combine_messages` `:304` (wire; refresh its `:299` anchor to v0.46.0 `:356`); `SelectedTree::from_paths` `:397`, `tree` `:443`, `into_commit_selection` `:452` (wire, drop its allow); `from_tree_id` `:430` STAYS unwired (update its WHY to name 9.50); `resolve_or_wc` `:599`, `resolve_commit` `:498`, `build_matcher` `:641`. Add `combine_messages_for_editing` + `cleanup_description_lines` ports and the moved `join_message_paragraphs` to §3.
- `src/mutate.rs` — `MutationResult` `:51`, `MutateError` `:104`, helpers `be` `:396`/`cfg` `:403`/`res` `:427`/`build_matcher` wrapper `:444`/`warn_unmatched` `:455`/`resolve_or_wc` `:467`/`guard_rewritable` `:495`, `finish_verb` `:703`, `mutation_result` `:729`, `no_op_result` `:1000`, `finish_or_no_op_at` `:1107`; `AbsorbResult` `:340` = the nesting template for `SplitResult`; `restore` `:1284-1352` = the closest verb body (tree work, `rebase_descendants` before commit — `tx.commit` panics on pending rewrites).
- `src/repo.rs` — `with_verb` `:350`; facades `restore` `:1875`, `absorb` `:1944` (doc-block template). New facades go after `absorb`.
- `src/warning.rs` — `WarningKind` `:29` (append two variants), `Warnings::push` `:161`.
- `src/config.rs` — `BUILTIN_CONFIG_TOML` `:176-218` (add the `[split]` table).
- `src/workspace_add.rs:97-99` — private `join_message_paragraphs` to move.
- `src/lib.rs` — module list (alphabetical) and re-exports `:61-93`.

**Extend — wire + FFI**
- `schemas/envelope.fbs` — `RequestKind` `:70-102` (append `Squash`, `Split`), request tables after `AbsorbRequest` `:141` (field order = wire contract, `kind` field 0), `MutationResult` `:896`, `AbsorbResult` `:947` (nesting template), `union Payload` `:1493-1533` (append `SquashPlan`, `SplitResult`), ledger comment `:574-603`.
- `crates/zanshin-ffi/src/repo.rs` — `map_mutate_err` `:115`, `read_absorb_request` `:251` (reader template; `into` field read as `fbs::X::into(&req)` `:238`), `zanshin_absorb` `:1204` + rustdoc `:1106-1137` (extern template).
- `crates/zanshin-ffi/src/envelope.rs` — warning consts `:206-281` + `warning_code()` `:286` + test `every_warning_kind_has_its_registered_code` `:1099-1134`; `precondition_envelope` `:428`, `ok_mutation_result` `:632`, `build_mutation_result` `:602`, `ok_absorb_result` `:653` (custom payload template).
- Generated (only via `cargo make codegen`): `zanshin_ffi.h`, `envelope_generated.rs`, `bindings.dart`, `envelope_zanshin.ffi_generated.dart`.
- `docs/ffi-abi.md` — symbol index `:448` (rows `:498-499`), request tables `:374`; guard `crates/zanshin-ffi/tests/ffi_abi_doc_sync.rs` `EXPECTED_EXPORTS = 63` `:35` → 66.
- `docs/rust-error-codes.md` — Warning Codes `:88` (absorb row `:133`), checklist `:182-195`; "also emitted — Story 9.15" clauses on reused rows.

**Extend — Dart (`packages/zanshin_core`)**
- `lib/src/ffi/mutate.dart` — `zanshinAbsorb` `:148`, `decodeAbsorbResultEnvelope` `:320-325`, `decodeMutationResultInternal` `:219` (reuse, never re-spell); `lib/src/ffi/commit_views.dart` `:171-377` = non-mutation payload decoder template; `lib/src/ffi/warning.dart` `ZanshinWarningCode` (+ `.values`) and `test/ffi/warning_test.dart` pin.
- `lib/src/worker/commands.dart` `AbsorbCommand` `:492`; `isolate.dart` `absorb` `:1033` + arm `:2241`; `handle.dart` `absorb` `:507`; barrel `lib/zanshin_core.dart`.

**Tests / gates**
- `crates/test-helpers/src/lib.rs` — `add_commit_with_files` `:281`, `tree_hex` `:366`, `describe_commit` `:385`, `set_local_bookmark` `:531`, `add_workspace` `:630`; helpers never move `@` (use `Repo::edit`/`new_change`).
- `crates/zanshin-jj/tests/content_ops.rs` (restore/absorb harness), `tests/api_stability.rs` (`workspace_add_update_stale_surface_resolves` `:1014` template; warning pin `story_9_32_warning_surface_resolves` `:1267`).
- `crates/zanshin-ffi/tests/repo_write_ffi.rs` (FFI harness); `packages/zanshin_core/test/{ffi,worker}/mutate_test.dart` (synthetic + real-cdylib templates; every new extern needs a real-cdylib zanshin_core test or the coverage extern-fn guard fails).
- `crates/zanshin-parity/tests/oracle/scenarios.rs` (`BASE` `:29`: A a.txt → B b.txt + `b-mark` → C c.txt = `@`; `restore_from` `:445`, `absorb` `:468` with `files`), `main.rs` `parity!` list `:22-75`, `ledger.rs`. The CLI side has no editor configured: editor cases need setup `Step::Jj(&["config","set","--repo","ui.editor","true"])`.
- `coverage-baseline.txt` (`mutate.rs` 99.52, `op_support.rs` 99.59, ffi `repo.rs`/`envelope.rs` 100.00; new files ≥ 80).

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/src/op_support.rs` + `src/workspace_add.rs` -- move `join_message_paragraphs` into §3 (workspace_add calls it from there); add ports of `combine_messages_for_editing` (no trailers block) and `cleanup_description_lines` and a `combined_editor_text(abandoned, destination) -> String` that returns the editor-saved-unchanged result; wire `compute_commit_location`, `try_combine_messages`, `into_commit_selection` (drop their `allow(dead_code)`, refresh stale v0.44 anchors); inline unit tests for the cleanup rules (JJ: lines, `JJ: ignore-rest`, trims, single final newline, an empty source description included).
- `crates/zanshin-jj/src/config.rs` -- add `[split] legacy-bookmark-behavior = true` verbatim to `BUILTIN_CONFIG_TOML`.
- `crates/zanshin-jj/src/warning.rs` -- append `SplitAllSelected` and `SplitNoneSelected` with rustdoc citing split.rs:585-594.
- `crates/zanshin-jj/src/squash_split.rs` (new) -- module doc (parity tag v0.46.0, ported files, divergences from **Never**); public `SquashOptions { revision, from, into, paths, message: Option<Vec<String>>, use_destination_message, keep_emptied }`, `SquashPlan { combined_description: Option<String> }`, `SplitOptions { revision, paths, message, parallel, onto, insert_after, insert_before: Option<Vec<ChangeId>> }`, `SplitResult { mutation, selected_change_id, remaining_change_id }`; `pub(crate)` `prepare_squash` (shared by `squash` and `squash_plan`), `squash`, `squash_plan`, `prepare_split`, `split` -- the step-for-step ports of the Code Map's CLI anchors; flag conflicts refuse `InvalidInput` naming the flags (clap's own text is terminal UX).
- `crates/zanshin-jj/src/repo.rs` + `src/lib.rs` -- `#[must_use]` facades `squash(&SquashOptions) -> Result<MutationResult>`, `squash_plan(&SquashOptions) -> Result<SquashPlan>`, `split(&SplitOptions) -> Result<SplitResult>` through `with_verb`, house doc blocks (`# Errors` one bullet per reachable variant, the no-`-m` editor rule, paths-as-prefixes, empty-paths split refusal); module declaration + re-exports.
- `schemas/envelope.fbs` -- `RequestKind.Squash`/`Split`; `SquashRequest { kind, revision, from:[string], into, paths:[string], message:[string] (absent = no -m), use_destination_message, keep_emptied }` (used by BOTH `zanshin_squash` and `zanshin_squash_plan`); `SplitRequest { kind, revision, paths, message, parallel, onto, insert_after, insert_before }` (an absent location vector = flag not given, present-empty = given empty); payload tables `SquashPlan { combined_description: string }` and `SplitResult { mutation: MutationResult, selected_change_id, remaining_change_id }` appended to `union Payload`; ledger line.
- `crates/zanshin-ffi/src/squash_split.rs` (new) + `lib.rs` + `envelope.rs` -- owned request readers, `zanshin_squash`, `zanshin_squash_plan`, `zanshin_split` (`precondition_envelope`; `ok_mutation_result` / new `ok_squash_plan` / `ok_split_result` built on `build_mutation_result`), two warning consts + `warning_code()` arms + table test; full rustdoc (`# Errors`, `# Safety`).
- `cargo make codegen` -- regenerate and commit the four generated files with the schema/extern change.
- `packages/zanshin_core/lib/src/ffi/squash_split.dart` (new) + `worker/{commands,isolate,handle}.dart` + `lib/src/ffi/warning.dart` + barrel -- request builders, adapters, `SquashPlan`/`SplitResult` models + decoders (reuse `decodeMutationResultInternal`), `SquashCommand`/`SquashPlanCommand`/`SplitCommand` before `ShutdownCommand`, worker methods + dispatch arms (`_invalidHandleEnvelope`), `RepoHandle.squash`/`squashPlan`/`split` behind the close guard with interior-NUL rejection on the calling side; two `ZanshinWarningCode` constants.
- `crates/zanshin-jj/tests/squash_split.rs` (new) -- every jj-level matrix row against jj-lib state: op descriptions verbatim, abandoned `@` → new `@`, `-k` empty source, partial paths, combined text = `combined_editor_text`, plan ≡ verb (the plan's text is what the verb writes without `-m`; plan with `-m`/`-u` or one non-empty description → null), plan writes no operation beyond the snapshot, refusals keep the head, legacy true/false bookmark placement, two workspaces on the split target, parallel, `-o`/`-A`/`-B`, both warnings, empty-paths refusal.
- `crates/zanshin-ffi/tests/squash_split_ffi.rs` (new) -- readers (absent vs present-empty vectors, malformed buffer, wrong kind), zero-handle for all three externs, a refusal envelope carrying `jj.invalid_input`, warnings on the split envelope.
- `packages/zanshin_core/test/ffi/squash_split_test.dart` + `test/worker/squash_split_test.dart` (new) -- synthetic decode + NUL guards; real-cdylib round trips calling all three externs (plan → squash with the plan text, split with paths, one refusal), with the extern-fn-guard header paragraph.
- `crates/zanshin-parity/tests/oracle/{scenarios,main}.rs` (+ `ledger.rs` only with reason + reference) -- scenarios: squash `@` into parent (editor), `-r B`, merge refused, `--from C --into A`, `--into @` no-op, partial path with `-r`, `-k`, `-u`, `-m`, plan text passed as `-m` vs CLI editor; split with paths + `-m`, without `-m` (editor), all selected, none selected, `--parallel`, `-A`, `-B`, `-o`, legacy false with a bookmark on the target.
- `crates/zanshin-jj/tests/api_stability.rs` -- `squash_split_surface_resolves`: the new types field by field, the three `Repo` methods as `fn` pointers, the two warning kinds in the 9.32 pin; header type count updated.
- `docs/rust-error-codes.md` + `docs/ffi-abi.md` -- two warning rows, "also emitted — Story 9.15" clauses, symbol-index rows, request/payload tables.
- `_bmad-output/implementation-artifacts/{sprint-status.yaml,deferred-work.md}` -- flip `9-15-squash-split-partial-file` to `done` with a summary comment in sibling style (bump `last_updated`); mark item I1 ("The combined description must be known before squash runs") resolved with the commit; add the `## Surfaced in Story 9.15 (bmad-build-auto, 2026-10-19)` section mirroring this spec's `deferred:` entries.

**Acceptance Criteria:**
- Given the three calls exist, when a Dart caller reaches them, then the whole chain is present (`.fbs` tables, zanshin-jj verb, `extern "C"`, committed codegen, adapter, `WorkerCommand`, worker method, `RepoHandle` method) and `ffi_abi_doc_sync` passes with 66 exports.
- Given every parity scenario listed above, when the oracle runs, then each matches the pinned CLI on every aspect (graph, descriptions, trees, empties, working copies, bookmarks, ops written, op descriptions, outcome, warning count) or diverges only through a ledgered entry with reason and reference.
- Given a squash whose abandoned sources and destination carry two or more non-empty descriptions and no `-m`/`-u`, when `squash_plan` is called and its text is passed back as `-m`, then the result is byte-identical to the CLI run whose editor saves the buffer unchanged, and `squash_plan` wrote no operation besides a possible snapshot.
- Given any refusal or the into-itself no-op, when the op head is compared before and after, then it is unchanged and `new_op_id` equals the pre-call head (zanshin-jj and FFI layers).
- Given `cargo make test` on the final tree, then it exits 0 (clippy pedantic, fmt, doctests, Dart analyze/format/tests, cargo deny, coverage ratchet with the extern-fn guard; new files ≥ 80 %, no baseline lowered) and the raised `coverage-baseline.txt` is committed with the code.
- Given the end of the run, then `git status --porcelain` is clean and every commit ends with the required co-author trailer.

## Spec Change Log

## Review Triage Log

## Design Notes

- **Why one preparation function, plan included (9.31 contract).** `prepare_squash` opens the transaction, resolves, refuses, selects, runs `squash_commits` and decides the description; `squash` writes and finishes, `squash_plan` drops the transaction. The plan therefore sees the exact `abandoned_commits` jj-lib computes (abandonment depends on the selection and `-k`), so plan and verb cannot disagree. Rewritten-source commits the plan writes to the store are unreferenced objects, not operations.
- **No `-m` in the editor case.** The GUI asks first (10.8/10.25 pre-fill the plan text); a caller that runs without asking gets the CLI's result for an editor saved unchanged, which keeps the verb total and parity-testable (`ui.editor = true`). Example: destination `"B\n"`, abandoned source `"C\n"` → `"B\n\nC\n"`.
- **Squash scope.** `revision` conflicts with `from`/`into`; `from = []` means `@`; the destination is silently removed from the sources (no error), so `into = @` with source `@` is the CLI's "Nothing changed." no-op through `finish_or_no_op_at`.
- **Split ids.** Serial/parallel: selected keeps the target's change id, remaining gets a new one; with `-o/-A/-B` it is the reverse. `@` always ends on the remaining commit; `SplitResult` names both so the toast needs no guessing.

## Verification

**Commands:**
- `cargo make codegen` -- expected: regenerated files committed, no further diff.
- `cargo test -p zanshin-jj --test squash_split` and `cargo test -p zanshin-parity --test oracle` -- expected: all pass.
- `cargo make test` (unpiped) -- expected: exit 0, coverage ratchet green.
