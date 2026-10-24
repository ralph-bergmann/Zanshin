---
title: 'Story 9.18 — `revert` (reverse merge, no lib helper)'
type: 'feature'
created: '2026-10-24'
status: 'done'
baseline_revision: '320d1f74dc8c9a8b27bee3da03815b885da05e17'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-9-context.md'
warnings: ['oversized']
deferred:
  - summary: >-
      With `-o` and both a broken `templates.revert_description` and an unresolvable `immutable_heads()` alias, Zanshin refuses with the immutable-set `jj.config_error` text where the CLI reports the template parse error.
    evidence: |-
      `plan_revert` (Story 9.31) resolves the immutable set at the end of the plan for a non-insert location; the verb parses the template after the plan, as the intent requires. The CLI parses the template first and resolves the immutable set only in `tx.finish`. Both refusals are `jj.config_error` with no operation; only the `context` text differs, and only when both settings are broken at once. `duplicate`'s plan has the same order. A fix moves the non-insert `resolve_immutable` out of the shared plan fns into the verbs' finish path (drop_actions keeps its own call).
    location: >-
      crates/zanshin-jj/src/revert.rs (plan_revert), crates/zanshin-jj/src/duplicate.rs (plan_duplicate_ids)
    severity: low
    resolved: >-
      2026-10-24 — fixed (spec-9-18-closing-revert-duplicate-template-before-immutable, commit 3aba05a): compute_commit_location resolves the immutable set only for a location with children, as the CLI does; plan_revert / plan_duplicate_ids no longer resolve it, so the template parse comes first; oracle refusal_order.rs witnesses both verbs.
---

<intent-contract>

## Intent

**Problem:** Zanshin has no `jj revert`. Its plan phase already exists (`revert::plan_revert`, Story 9.31 follow-on) and feeds `drop_actions`' Revert rows, but nothing executes a revert, so the drop menu's Revert row has no verb behind it.

**Approach:** Port `cmd_revert` (`cli/src/commands/revert.rs` @ v0.46.0) as `Repo::revert(&RevertOptions)`: the verb calls `plan_revert` (so preview and execution agree), then renders `templates.revert_description` on each reverted commit, then in one transaction writes each reverse commit — a 3-way `MergedTree::merge` of (destination tree, reverted tree, reverted commit's parent tree) with the CLI's conflict labels — chained one after another, rebases the location's children onto the last one, and finishes with the CLI's op description. Full chain per the epic's "done per verb".

## Boundaries & Constraints

**Always:**
- **CLI order and texts @ v0.46.0.** Clap first, before the snapshot (`with_checked_verb`, `jj.invalid_input`): empty `revisions` → `revert requires at least one revision` (clap's `required = true`); `onto` with `insert_after`/`insert_before` → `ONTO_WITH_INSERT`; none of the three → `NO_LOCATION` (clap's required `location` group). Then `plan_revert` (revisions in reverse topo order → `None` = "No revisions to revert." → house no-op result; location `"reverted commits"`; immutable set; Git root-merge refusal) → `templates.revert_description` parsed over the base repo and rendered per commit (`format_plain_text`, lossy UTF-8, **no** `complete_newline` — unlike duplicate) → transaction.
- **Algorithm (revert.rs:149-232):** `new_parents` = the plan's parent commits; `new_base_tree = merge_commit_trees(repo, &new_parents)`; `parent_labels = conflict_label_for_commits(&new_parents)`. Per commit in `to_revert` order: `new_tree = MergedTree::merge(Merge::from_vec([(new_base_tree, "{parent_labels} (revert destination)"), (commit.tree(), "{commit.conflict_label()} (reverted revision)"), (commit.parent_tree(repo), "{conflict_label_for_commits(&commit.parents())} (parents of reverted revision)")]))`; `new_commit(parent_ids, new_tree).set_description(desc).write()`; then `parent_ids = [new.id]`, `parent_labels = new.conflict_label()`, `new_base_tree = new_tree`. Then `transform_descendants(new_child_ids)`: for a commit in `new_child_ids`, its parents that are among the ORIGINAL location parents are replaced by the head ids, then the head ids are appended if absent (IndexSet order); every visited commit `rebase().write()`.
- **Op description:** `revert commit <full hex>` (one) / `revert commit <first full hex> and <n-1> more`; first = `to_revert[0]`. Finish through `finish_verb`.
- **Result:** the existing `MutationResult`; `new_change_ids` = the reverse commits' change ids in creation order. The CLI's status lines ("Reverted N commits as follows:", "Rebased N descendant commits.") are terminal UX, dropped as duplicate drops its own (documented divergence).
- `RevertPlan`'s `#[allow(dead_code)]` goes (its fields now have a reader).
- Chain: `RevertOptions { revisions, onto, insert_after, insert_before }` (as `DuplicateOptions`) → `.fbs` append `RequestKind::Revert` + `table RevertRequest { kind; revisions; onto; insert_after; insert_before }` → `extern "C" zanshin_revert` (new `crates/zanshin-ffi/src/revert.rs`, `MutationResult` envelope, `map_mutate_err`) + committed `cargo make codegen` → `RevertCommand` / `RepoHandle.revert` (Dart) → `docs/ffi-abi.md` (106 → 107 exports) → a real-cdylib `zanshin_core` test → parity-oracle scenarios.
- No new error or warning code: every refusal reuses `jj.invalid_input`, `jj.change_not_found`, `jj.revset_resolution_error`, `jj.immutable`, `jj.config_error`, `jj.not_a_git_repo`, `jj.jj_lib_error`.

**Never:** status-line text in the result; a revset language for `revisions` (change ids only, ADR-0003); MCP tools; Flutter/app UI; regenerating fixtures; shelling out to `jj` outside the oracle; running the full gate (`cargo make test` / `test-full` / `coverage`) — story-loop gate rule, targeted checks only.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| onto @ | revert B `-o @` | one new commit on `@`, tree = `@` minus B's change, description `Revert "B"\n\nThis reverts commit <hex>.\n`; op `revert commit <hex>` | — |
| two revisions | revert B, C `-o @` | C's reverse first (reverse topo), then B's on top; op `… and 1 more` | — |
| insert after / before | B `-A C` / `-B C` | reverse inserted, C's descendants (or C) rebased onto it | — |
| conflicting reverse | revert a change a later commit overwrote | reverse commit holds a conflict with the three labels | — |
| template | `templates.revert_description` set | descriptions rendered from it | broken template: `jj.config_error`, no op |
| args | empty `revisions`; no location; `-o` with `-A` | — | `jj.invalid_input` before the snapshot, no op |
| refusals | unknown id; `-B` an immutable child; `-o` root + X (Git) | — | `jj.change_not_found` / `jj.immutable` / `jj.invalid_input`, no op beyond the snapshot |
| empty plan | `plan_revert` returns `None` (direct call, empty revisions) | house no-op result, pre-call head | — |

</intent-contract>

## Code Map

- `../jj` @ v0.46.0 (read-only): `cli/src/commands/revert.rs` (whole; algorithm L149-232), `cli/src/config/templates.toml:37-43` (`revert_description` default: `Revert "<first line>"`, blank, `This reverts commit <hex>.`).
- `crates/zanshin-jj/src/revert.rs` -- has `RevertPlan` + `plan_revert` (L22-87); ADD `RevertOptions`, `check_revert_args`, `revert(workspace, ctx, options)`; drop `#[allow(dead_code)]`; module doc: verb + status-line divergence. Pattern: `duplicate.rs` (whole file: options, check args, plan call, templates, `finish_verb`, `mutation_result`); no-op: `simplify_parents.rs:115-123` (`no_op_result`); `transform_descendants` closure: `squash_split.rs:940-955`; `merge_commit_trees`: `diffedit.rs:92`; labels: `mutate.rs:31,1818` (`conflict_label_for_commits`).
- `crates/zanshin-jj/src/template.rs:375-394` -- ADD `revert_descriptions` beside `duplicate_descriptions` (no newline completion); `crates/zanshin-jj/src/config.rs:1835-1846` -- ADD `templates_revert_description` (CLI default via `CLI_DEFAULTS`).
- `crates/zanshin-jj/src/repo.rs:3610-3655` -- ADD `pub fn revert` after `duplicate` (via `with_checked_verb`), rustdoc + errors list as siblings.
- `crates/zanshin-jj/src/lib.rs` -- re-export `RevertOptions`; `tests/it/api_stability.rs` -- pin it; NEW `tests/it/revert.rs` + `mod revert;` in `tests/it/main.rs` (pattern `tests/it/duplicate.rs`).
- `crates/zanshin-jj/src/drop_actions.rs:316` -- existing `plan_revert` caller; unchanged.
- `schemas/envelope.fbs` -- `RequestKind` (L94-163) append `Revert`; new `RevertRequest` after `DuplicateRequest` (L508).
- `crates/zanshin-ffi/src/revert.rs` (new) -- reader + `zanshin_revert`; pattern `metaedit_duplicate_fix.rs:30-94,170-230` (`change_ids`, `root`, `read_duplicate_request`, `zanshin_duplicate`) and its reader unit test (L372-401); `lib.rs` module line; `tests/it/ffi_abi_doc_sync.rs` count 106 → 107; an FFI it round trip (pattern any `tests/it/*_ffi.rs`).
- `packages/zanshin_core` -- `lib/src/ffi/metaedit_duplicate_fix.dart:60-86` pattern for a new `lib/src/ffi/revert.dart` (`zanshinRevert`); `lib/src/worker/commands.dart:2493` (`DuplicateCommand`) → `RevertCommand`; `isolate.dart:2158-2190` client + `:4155-4175` dispatcher; `handle.dart:1328-1360` → `RepoHandle.revert`; real-cdylib test `test/worker/revert_test.dart` (pattern the duplicate worker test); NUL-guard test in `test/ffi/` (pattern `test/ffi/metaedit_duplicate_fix_test.dart`).
- `crates/zanshin-parity/tests/oracle/scenarios.rs:3933-4260` (duplicate scenarios, `dup` helper, `DUPLICATE_DESCRIPTION` setup) + `main.rs:423-433` `parity!` list -- revert scenarios.
- `docs/ffi-abi.md` -- symbol index + counts.

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/src/{revert,template,config,repo,lib}.rs` -- the verb per Boundaries; inline unit tests: `check_revert_args` refusals, the verb's `None` plan → no-op (direct call with empty revisions), the op-description shape.
- `crates/zanshin-jj/tests/it/revert.rs` (new) + `main.rs`, `api_stability.rs` -- every matrix row: tree content and descriptions, chaining order, `-A`/`-B` child rebase, conflict labels on a conflicting reverse, template, refusals write no op beyond the snapshot.
- `schemas/envelope.fbs`, `crates/zanshin-ffi/**`, then `cargo make codegen` -- wire + generated files; reader unit test (every field, wrong kind); FFI round trip.
- `packages/zanshin_core/**` -- Dart surface, barrel if needed, real-cdylib test (revert onto `@` yields one new change; `-o` with `-A` refuses `jj.invalid_input`), NUL guard test.
- `crates/zanshin-parity/tests/oracle/{scenarios,main}.rs` -- `revert_onto_wc`, `revert_two_revisions`, `revert_insert_after`, `revert_insert_before`, `revert_onto_two_parents`, `revert_conflict`, `revert_description_template`, `revert_root_merge_refused` — matching the stock CLI with no ledger entry.
- `docs/ffi-abi.md` -- rows, counts. `sprint-status.yaml` 9-18 status at finalize.

**Acceptance Criteria:**
- Given a repo, when `revert` runs any matrix scenario, then the repo state equals the stock CLI's `jj revert` with the same arguments (oracle, no ledger entry).
- Given `drop_actions` previews a Revert row as Available, when the GUI runs `revert` with the same source and location on an unchanged repo, then it succeeds; when the row is Refused, `revert` refuses with the same error.
- Given any refusal, when `revert` returns, then no operation is written beyond the start-up snapshot.
- Given the Dart `RepoHandle`, when `revert` runs through the real cdylib, then it returns the new change ids and the new op id.

## Spec Change Log

## Review Triage Log

### 2026-10-24 — Review pass
- verdicts: 24 findings — high 0, medium 4, low 13, false 7, maybe-false 0
- findings:
  - `[medium]` `[patch]` (verification-gap) `-A`/`-B` merge-child branch of `rebase_new_children` (kept outside parent, dedup) never runs — patched: oracle scenario `revert_insert_after_merge_child` (M = merge(C, B), `-r A -A C`).
  - `[low]` `[reject]` (verification-gap) no test that `templates.revert_description` diagnostics become one `jj.template_diagnostic` warning — the warning travels the shared, tested `parse_commit` path with the same `&mut ctx.warnings` as `duplicate`; a per-verb test needs a diagnostic-producing config for no new code path.
  - `[low]` `[patch]` (blind) the `-A`/`-B` description is never checked to name the pre-call (pre-rebase) hex; the oracle maps both B hexes to one label — patched: the insert test asserts the default description with B's hex read before the call.
  - `[medium]` `[patch]` (blind) several revisions with `-A`/`-B` (children onto the LAST reverse) and repeated `-A` unwitnessed — patched: oracle scenario with two revisions and an insert flag.
  - `[medium]` `[patch]` (blind) no witness reverts a merge commit (multi-parent parent tree and label) — patched: oracle scenario reverting the merge commit.
  - `[low]` `[reject]` (blind) template diagnostic row and the "not a string" arm of `templates_revert_description` untested — same as the verification-gap row; the getter is the shape of its tested siblings.
  - `[low]` `[defer]` (blind) with `-o`, a broken template plus an unresolvable `immutable_heads()` reports the immutable text first, the CLI the template's — real, both `jj.config_error`; the order lives in the shared plan fns (9.31, `duplicate` too) and the intent puts the plan before the template parse; deferred (frontmatter + deferred-work.md "Surfaced in Story 9.18").
  - `[low]` `[patch]` (blind) multi-element id lists never cross the FFI — patched: the reader unit test carries two revisions in order.
  - `[low]` `[patch]` (blind) the Dart worker test name says "onto" but covers all three locations — patched: renamed/split.
  - `[false]` `[reject]` (blind) `coverage-baseline.txt` missing — the story-loop gate rule forbids coverage in this run; the loop's final gate raises and commits it.
  - `[low]` `[patch]` (blind) `head_ids` rebuilt from `reverted.last()` instead of the CLI's final `parent_ids` — patched: `write_reverse_commits` returns the final parent ids, used as the heads.
  - `[low]` `[reject]` (blind) the test helper's expected op hex depends on argument order — every caller names the newest first and the comment says so; the verb's own order is witnessed by the oracle's `revert_two_revisions` (B, C order).
  - `[low]` `[patch]` (blind) root-merge refusal assertion accepts any `InvalidInput`; confusing comment — patched: asserts the backend's text, comment reworded.
  - `[false]` `[reject]` (blind) the spec is not in the reviewed diff — it is the claims file, handed to the edge-case layer separately, and is committed with the ledger.
  - `[low]` `[patch]` (edge) clap checks conflicts before required args, so empty revisions with `-o`+insert must refuse `ONTO_WITH_INSERT` — patched: conflict check first, combined case in the unit test.
  - `[low]` `[patch]` (edge) the unit test doc claims the wrong clap order — patched with the row above.
  - `[false]` `[reject]` (edge) `op_description` underflows on an empty list — its only caller passes `plan.to_revert`, which `plan_revert` returns non-empty (`None` otherwise).
  - `[low]` `[patch]` (edge) empty `reverted` would drop the children's location parents — unreachable today; grouped with the `head_ids` row (the CLI's carry-over keeps them).
  - `[false]` `[reject]` (intent) the transaction is opened before `plan_revert` — `plan_revert`'s 9.31 signature takes `&Transaction`; nothing is written before the plan, so the order is unobservable and the intent's "before the transaction" (before any write) holds.
  - `[low]` `[reject]` (intent) conflict-label text is not compared by the oracle — `a_reverse_a_later_change_overwrote_is_a_labelled_conflict` asserts the three exact strings ported from revert.rs:163-182; the oracle compares the tree ids.
  - `[medium]` `[patch]` (intent) merge-child branch uncovered — grouped with the first verification-gap row.
  - `[false]` `[reject]` (intent) `state.rs` changes the descriptions aspect for every scenario — ids are named per repo by label, so a description naming a different commit still differs; all 437 scenarios pass unchanged.
  - `[false]` `[reject]` (intent) `-A` is not in the drop-actions agreement test — `drop_actions`' revert rows only produce `-o` and `-B`.
  - `[false]` `[reject]` (intent) sprint-status still `backlog` — updated at finalize.

## Design Notes

- **Empty `revisions` refuses rather than no-ops:** the CLI's `-r` is `required = true`; a change-id list cannot express an empty revset (every id resolves or refuses), so "No revisions to revert." is reachable only through `plan_revert` directly. The verb still maps `None` to the house no-op result (tested inline).
- **Why `MutationResult`:** `revert` creates commits and rebases children like `duplicate`, which already answers `MutationResult`; the status-line counts are not facts the UI needs (the new change ids are).

## Verification

**Commands:**
- `cargo fmt --all --check` -- clean
- `cargo clippy -p zanshin-jj -p zanshin-ffi -p zanshin-parity --all-targets -- -D warnings` -- clean
- `cargo test -p zanshin-jj` (incl. `--test it revert:: drop_actions:: duplicate::`) -- green
- `cargo test -p zanshin-ffi` -- green (incl. `ffi_abi_doc_sync`)
- `cargo make codegen` -- generated files committed, no further diff
- `cargo test -p zanshin-parity --test oracle` -- green, new scenarios with no ledger entry
- `packages/zanshin_core` (Makefile `test-core` env): `dart test test/worker/revert_test.dart test/ffi`, `dart analyze --fatal-infos`, `dart format --set-exit-if-changed .` -- green
- `dart analyze app` -- clean

**Verification notes (this run; full gate deliberately NOT run — story-loop gate rule):**
- `cargo fmt --all --check` -- clean (before and after the review patches).
- `cargo clippy -p zanshin-jj -p zanshin-ffi -p zanshin-parity --all-targets -- -D warnings` -- clean (before and after).
- `cargo test -p zanshin-jj -p zanshin-ffi` -- after the patches: zanshin-jj 378 lib + 1351 it (1 pre-existing `#[ignore]` benchmark), zanshin-ffi 223 lib + 379 it (incl. `ffi_abi_doc_sync`, 107 exports). The implementer saw `cancel::tests::kill_group_signals_a_whole_group_and_never_ours` fail once under parallel load in an earlier run (passed alone and in every later full run; `cancel.rs` untouched).
- `cargo make codegen` -- exit 0; a second run left the generated files unchanged; the schema did not change in the review patches.
- `cargo test -p zanshin-parity --test oracle` -- 440 passed after the patches, incl. the 11 revert scenarios (`revert_onto_wc`, `revert_two_revisions`, `revert_insert_after`, `revert_insert_before`, `revert_onto_two_parents`, `revert_conflict`, `revert_description_template`, `revert_root_merge_refused`, `revert_two_revisions_insert_before`, `revert_insert_after_merge_child`, `revert_merge_commit`), no ledger entry.
- `packages/zanshin_core` (`cargo make --allow-private test-core`, the Makefile env): 1084 passed before the review patches; after them the implementer re-ran `test/worker/revert_test.dart` (only a test rename changed); `test-core-analyze` (`--fatal-infos --fatal-warnings`) -- no issues; `test-core-format` -- 0 changed.
- `dart analyze app` -- no issues.
- Coverage not measured (the loop's final gate runs it); both new source files are exercised by unit, integration and real-cdylib tests.

## Auto Run Result

Status: done

**Summary.** `jj revert` @ v0.46.0 is ported end to end. `Repo::revert(&RevertOptions)` refuses clap's cases before the snapshot (in clap's order: `-o` with an insert, no revision, no location), then calls the existing `revert::plan_revert` (shared with `drop_actions`' Revert rows; `None` = the house no-op), renders `templates.revert_description` on each reverted commit (not newline-completed), writes the chained reverse 3-way merges with the CLI's three conflict labels, rebases the `-A`/`-B` children onto the loop's final parent ids (the CLI's `IndexSet` rule), and finishes with `revert commit <hex>[ and <n> more]`. Result: the shared `MutationResult` (`new_change_ids` = the reverses in creation order); the CLI's status lines are not ported (documented). FFI `zanshin_revert` (`RevertRequest`, `RequestKind::Revert`), Dart `RepoHandle.revert`, 11 oracle scenarios. No new error or warning code.

**Files changed.**
- `crates/zanshin-jj/src/revert.rs` -- the verb, arg check, writer, child rebase, unit tests; `#[allow(dead_code)]` dropped.
- `crates/zanshin-jj/src/{config,template,repo,lib}.rs` -- `templates_revert_description`, `revert_descriptions`, `Repo::revert`, re-export.
- `crates/zanshin-jj/tests/it/{revert.rs (new),main.rs,api_stability.rs}` -- every matrix row + `drop_actions` agreement.
- `schemas/envelope.fbs`, `crates/zanshin-ffi/src/{revert.rs (new),lib.rs}`, generated files -- wire + extern; `crates/zanshin-ffi/tests/it/{revert_ffi.rs (new),main.rs,ffi_abi_doc_sync.rs}` -- round trip, 107 exports.
- `packages/zanshin_core/lib/src/{ffi/revert.dart (new),worker/commands.dart,worker/isolate.dart,worker/handle.dart}`, `test/{worker,ffi}/revert_test.dart` (new) -- Dart surface + tests.
- `crates/zanshin-parity/tests/oracle/{scenarios,main,state}.rs` -- 11 scenarios; `state.rs` names commit/change ids inside descriptions by label (needed for "This reverts commit <hex>.").
- `docs/ffi-abi.md`, `docs/rust-error-codes.md` -- symbol section, counts, `jj.template_diagnostic` emitter.

**Review.** 24 findings (high 0, medium 4, low 13, false 7). Patched: medium -- the merge-child `-A` branch, several revisions with an insert flag, reverting a merge commit (3 oracle scenarios); low -- description names the pre-call hex under `-A`, head ids carried as the CLI does, clap's conflict-before-required order (+ doc), two ids across the FFI reader, Dart test name, exact root-merge refusal text. Deferred (frontmatter + deferred-work.md "Surfaced in Story 9.18"): `-o` with both a broken template and an unresolvable `immutable_heads()` names the immutable fault first (low; shared plan-fn order, `duplicate` too). Rejected: template-diagnostic per-verb test and the getter's non-string arm (shared tested path), argument-order-dependent test helper, oracle not comparing label text (exact strings asserted in Rust); false: coverage baseline (gate rule), spec not in diff, `op_description` underflow (unreachable), tx-before-plan order (unobservable), `state.rs` affecting other scenarios (440 pass), `-A` absent from the agreement test (rows only produce `-o`/`-B`), sprint-status.

**Follow-up review recommended: false.** Patched at entry verdict: high 0, medium 3 entries, low 6. The two-medium threshold is met, but all three medium patches are oracle scenarios that match the stock CLI, and the two code changes (head-id carry-over, refusal order) are covered by the re-run suites; no specific unverified risk can be named.

**Residual risks.** Coverage unmeasured until the loop's final gate; the deferred low ordering divergence.
