---
title: 'Staleness run — `diffedit` / `resolve` staleness tokens, absent conflict sides, `new` root-merge order'
type: 'bugfix'
created: '2026-10-25'
status: 'done'
baseline_revision: '761f5ad664b559bb593c41b55bc196a955a2c306'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-9-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/spec-9-17-resolve-diffedit-gui-editor.md'
warnings: ['multiple-goals', 'oversized']
deferred:
  - summary: >-
      `duplicate` and `revert` onto a root merge with a broken description template refuse with the Git backend's root-merge text where the CLI names the template — item 4's gap in the two sibling verbs.
    evidence: |-
      `plan_duplicate_ids` (crates/zanshin-jj/src/duplicate.rs:115) and `plan_revert` (crates/zanshin-jj/src/revert.rs:103) call `refuse_git_root_merge` in the plan; `cmd_duplicate` @ v0.46.0 parses `templates.duplicate_description` (cli/src/commands/duplicate.rs:178-181) before `duplicate_commits` writes (:199), `cmd_revert` parses `templates.revert_description` (cli/src/commands/revert.rs:132-136) before the first write (:183-187), where the backend refuses. Both refuse with no operation; only the `context` text differs. Found while planning this run; outside its items.
    location: >-
      crates/zanshin-jj/src/duplicate.rs:115 (plan_duplicate_ids), crates/zanshin-jj/src/revert.rs:103 (plan_revert)
    severity: low
    resolved: >-
      2026-10-25 — fixed (spec-9-17-staleness-followup-duplicate-revert-root-merge, commit 67d64ec): the plans no longer refuse the root merge; `duplicate` / `revert` refuse it after their template render, right before the first write, the `Duplicate` / `Revert` rows right after the plan; oracle `refusal_order.rs` witnesses both against the pinned CLI.
  - summary: >-
      `diffedit`'s `right` comes from a separate `show` read, so a GUI that re-reads `show` between `select_tree` and `diffedit` can pick up an autosave the selection never saw and lose it again.
    evidence: |-
      `select_tree` returns only the selected tree (`SelectedTreeId`), not the target's tree it selected in; the decided source of `right` is `ShowEntry.tree_ids` (Ralph, 2026-10-25). The natural flow — diff, `left` and `right` all from the one `show` the GUI displayed — is safe; only a re-read in between reopens the gap. Review pass 2026-10-25 (blind hunter).
    location: >-
      crates/zanshin-jj/src/diffedit.rs (DiffeditOptions.right), crates/zanshin-jj/src/select_tree.rs (SelectedTreeId)
    severity: low
---

<intent-contract>

## Intent

**Problem:** Four ledger items Ralph decided on 2026-10-25 / 2026-10-23 (deferred-work.md "Surfaced in Story 9.17 …" and "Surfaced in the `new` refusal-order fix …"): (1) `diffedit` only checks the selection's `left`, then replaces the target's whole tree, so an edit the target received after `select_tree` (folded in by the pre-verb snapshot) is lost; (2) `resolve` with GUI files checks only "still a conflict", so a conflict that changed since `resolve_list` gets content composed from old sides; (3) `resolve_list` cannot tell an absent side from an empty file; (4) a `new` root merge with a broken `templates.new_description` refuses with the Git backend's text where the CLI names the template. All four verified real against the code at the baseline.

**Approach:** (1) `DiffeditOptions.right` = the target tree ids the GUI saw (`ShowEntry.tree_ids`), required; after the snapshot, the rewritable guard and the `left` check, a target tree ≠ `right` refuses `jj.stale_selection` with no operation. (2)+(3) `ConflictedFile.term_ids` = jj-lib's simplified `MaterializedFileConflictValue.ids` per term in `Merge` order (hex, `None` = no file, i.e. an absent/deleted term), required back on every `ResolvedFile`; a mismatch refuses `jj.stale_selection` with no operation. (4) `new` refuses the root merge after the template parse, right before its write; the `new` drop/card rows refuse it themselves after the plan.

## Boundaries & Constraints

**Always:**
- **Required, not optional** (both tokens): an optional token would let any caller silently opt out of the protection the decision exists for, and the GUI always has the value (`show`'s `tree_ids`, `resolve_list`'s `term_ids`). Missing is refused `jj.invalid_input` before the snapshot: `right` through `parse_tree_ids(&right, "right")` (empty / even count / non-hex), each `ResolvedFile.term_ids` empty → "resolved file {path} needs the term ids resolve_list reported".
- **diffedit order:** args → snapshot → target/base → `guard_rewritable` → `check_left` → `right` check (`target.tree_ids() != parse_tree_ids(right)` → `StaleSelection { reason: "The target's tree changed since the selection was made: re-read it and select again" }`) → "Nothing changed." no-op → write.
- **resolve order (Files):** `merge_tool_file`: not a conflict / path not found (CLI texts, stale) → term-ids check (current materialized file conflict's `ids` as `Vec<Option<String>>` hex ≠ sent, or the conflict is no longer a file conflict → `StaleSelection { reason: "The conflict at {path:?} changed since it was listed: re-read it and resolve again" }`) → `ConflictNotResolvable`. `Ours`/`Theirs` take no token (they act on the current conflict, as the CLI). Ids compared as hex strings exactly as `resolve_list` emitted them.
- `ConflictedFile.term_ids` is empty for a non-file conflict (no materialized file), else one entry per term of the simplified conflict (same count and order as `labels` when labelled, and as a conflicting hunk's `terms`).
- **new (item 4):** `plan_new` drops both `refuse_git_root_merge` calls; `new_change` calls it after the description/trailer template block, before `builder.write`; `drop_actions`' `Rows::new_change` calls it after `plan_new` and before its `resolve_immutable` (rows keep refusing the root merge in their previews; the existing root-merge drop test stays green). Docs of `plan_new` / `new_change` follow.
- Chain for 1–3: `schemas/envelope.fbs` append-only (`DiffeditRequest.right: [string]`; new `table ConflictTermId { id: string; }` — absent `id` = no file; `ConflictedFile.term_ids` and `ResolvedFile.term_ids: [ConflictTermId]`) → `zanshin-jj` → FFI readers/writer + `cargo make codegen` (commit output) → Dart `ConflictedFile.termIds` / `ResolvedFile.termIds` (`List<String?>`, required) and `RepoHandle.diffedit(right:)` (required) → `docs/ffi-abi.md` (request/payload rows, § Story 9.17) → `docs/rust-error-codes.md` (`jj.stale_selection` emitter row: diffedit's `right`, resolve's term ids; `jj.invalid_input` if it lists per-verb triggers). Export count unchanged (no new extern).
- Every refusal writes no operation beyond the CLI's own start-up snapshot.

**Never:** No other verb changed (sibling `duplicate`/`revert` root-merge order is deferred, see frontmatter); no change to existing codes or CLI texts; no Flutter app UI code; no MCP; no regenerated fixtures; no full gate (`cargo make test` / `test-full` / `coverage`) — targeted checks only (gate rule).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| diffedit fresh | `right` = `show(@).tree_ids`, tree from `select_tree` | as today (Story 9.17 rows unchanged) | — |
| diffedit target edited | `select_tree` on `@`, then a file in `@` is written on disk (snapshot folds it in), `right` = old ids | `@` keeps the disk edit, no operation | `jj.stale_selection` |
| diffedit no right | `right` empty / malformed | — | `jj.invalid_input` before the snapshot, no op |
| list ids | 2-sided `c.txt`, base absent | `term_ids` = `[Some(side1), None, Some(side2)]` | — |
| list modify/delete | one side deletes `m.txt` | a `None` side term id, a `Some` base and other side | — |
| resolve fresh | `Files` with `term_ids` from `resolve_list` | as today | — |
| resolve stale | list, then a side changes (rewrite the parent commit so `@`'s conflict changes but stays a 2-sided file conflict), resolve with the old ids | nothing written | `jj.stale_selection` |
| resolve no ids | a `ResolvedFile` with empty `term_ids` | — | `jj.invalid_input` before the snapshot |
| new root merge | `new @ root()` with `templates.new_description = '"x" ++'` (alias too) | refused, no op | `jj.config_error` template text (= CLI) |
| new root merge, template ok | `new @ root()` | refused, no op | `jj.invalid_input` `GIT_ROOT_MERGE` (unchanged) |
| rows | drop onto root + another change | `NewMerge` row refused `GIT_ROOT_MERGE` (unchanged) | — |

</intent-contract>

## Code Map

- `crates/zanshin-jj/src/diffedit.rs` -- `DiffeditOptions` (add `right: Vec<String>` + doc: from `crate::ShowEntry::tree_ids` of the target, required), `check_diffedit_args` (L55: `parse_tree_ids(&options.right, "right")?`), `diffedit` (L92-94: after `check_left`, the `right` check), module doc (staleness), unit test L136 (add `right` to `ok`, a missing-`right` refusal).
- `crates/zanshin-jj/src/select_tree.rs` -- `parse_tree_ids` (L211, `pub(crate)`), `check_left` (L246), `STALE_LEFT` (L174, pattern for a new `STALE_RIGHT` const); module doc L35-38 "own content is not stale" — add: except diffedit, whose target keeps nothing (`right`).
- `crates/zanshin-jj/src/resolve.rs` -- `ConflictedFile` (L65: add `term_ids: Vec<Option<String>>`), `ResolvedFile` (L118: add `term_ids`), `check_resolve_args` (L132; empty `term_ids` refusal), `resolve_list` (L251-268: `file.ids.iter().map(|id| id.as_ref().map(ObjectId::hex))`), `merge_tool_file` (L291: take the expected ids `Option<&[Option<String>]>`; check after the not-a-conflict arms, before the resolvability refusal), `resolved_tree` (L363-377: pass `files[i].term_ids` for `Files`, `None` for `Ours`/`Theirs`); unit tests L441 (`file()` helper gets ids; empty-ids refusal).
- `crates/zanshin-jj/src/repo.rs` -- rustdoc of `resolve_list` / `resolve` (~L3915 stale bullet) / `diffedit` (~L3954): add the new stale and invalid-input causes.
- `crates/zanshin-jj/src/mutate.rs` -- `plan_new` (L1175-1197: remove both `refuse_git_root_merge`; docs L1152-1155 and Errors L1162-1163), `new_change` (L1285-1294: call `refuse_git_root_merge(tx.repo().store(), &location.parents)?` after the template block, before `builder.write`; Errors doc L1243).
- `crates/zanshin-jj/src/drop_actions.rs` -- `Rows::new_change` (L387-393: `let location = plan_new(...)?; refuse_git_root_merge(tx.repo().store(), &location.parents)?;` then `resolve_immutable`; import `refuse_git_root_merge` from `crate::mutate`).
- `crates/zanshin-jj/tests/it/diffedit.rs`, `resolve.rs` -- every existing call gets `right` / `term_ids` (from `show`'s `tree_ids` / `resolve_list`); new tests per matrix rows (diffedit target edited on disk → stale, no op, disk edit kept; list term ids incl. modify/delete `None`; resolve stale after the conflict changed; empty ids/right invalid). Build conflicts in-test as the existing tests do.
- `crates/zanshin-jj/tests/it/new_insert.rs` -- new test: `new_change([c, root])` with a broken `templates.new_description` refuses the template `Config`; existing root-merge test L486 stays green. `tests/it/drop_actions.rs` L452 root-merge row test stays green. `tests/it/api_stability.rs` -- pin the new fields.
- `schemas/envelope.fbs` -- `ResolvedFile` (L436), `DiffeditRequest` (L466), `ConflictTerm` area (L2800, new `ConflictTermId` next to it), `ConflictedFile` (L2823): append fields + doc lines. Then `cargo make codegen` (regenerates `crates/zanshin-ffi/src/envelope_generated.rs`, Dart `envelope_zanshin.ffi_generated.dart`, possibly `include/zanshin_ffi.h`).
- `crates/zanshin-ffi/src/diffedit.rs` (reader L43-49 + doc + unit test L110-159), `resolve.rs` (reader L70-81: `term_ids` from `file.term_ids()` → `Vec<Option<String>>`; doc; unit tests L227-298), `envelope.rs` `ok_resolve_list` (L943-990: write `term_ids`; its unit test). FFI it-tests: `crates/zanshin-ffi/tests/it/resolve_ffi.rs`, `select_tree_ffi.rs` (diffedit round trip) — add the fields.
- `crates/zanshin-parity/tests/oracle/scenarios.rs` -- `resolve_tool_files` (~L5335: term ids from `repo.resolve_list` first), diffedit helper ~L5420-5530 (`right` = target's `show` `tree_ids`); all 11 Story 9.17 scenarios must stay green with no ledger entry. `refusal_order.rs` -- `Ids` gains `root` (`change(&mut repo, "root()")`), `id_of("root()")`, and a witness `new @ root()` → `Class::Template` (Zanshin `new_change(&[c, root], &[], &[])`); module doc names it.
- `packages/zanshin_core/lib/src/ffi/resolve.dart` -- `ConflictedFile.termIds`, `ResolvedFile.termIds` (required, `List<String?>`), builder `fbs.ConflictTermIdObjectBuilder(id: …)`, decoder (L187-205). `ffi/diffedit.dart` -- `right` required (+ `rejectInteriorNuls(right, 'right')`). `worker/commands.dart` `DiffeditCommand` (~L2199) + `isolate.dart` client ~L1862 / dispatcher ~L4453 + `handle.dart` `diffedit` ~L1584: thread `right`. Tests `test/worker/resolve_test.dart`, `diffedit_test.dart` (real cdylib): `termIds` incl. a `null` on a modify/delete conflict, a stale resolve and a stale diffedit refusing `jj.stale_selection`, existing calls passing the tokens. Check `app/` for callers of `diffedit(` / `ResolvedFile(` (none expected; `dart analyze app` proves it).
- `docs/ffi-abi.md` -- L627-629 rows (error lists unchanged unless a new cause), § L2049ff (`DiffeditRequest.right`, `ConflictedFile.term_ids`, `ResolvedFile.term_ids`, `ConflictTermId`); `docs/rust-error-codes.md` L92 (`jj.stale_selection` emitters + the diffedit "own content" exception).
- Read-only: `jj-lib-0.46.0/src/conflicts.rs:187-204,265-287` (`ids` are the simplified ids, matching `labels`/`contents`).

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/src/{diffedit,resolve,select_tree,mutate,drop_actions,repo}.rs` -- implement per Boundaries; inline unit tests for the new arg refusals.
- `crates/zanshin-jj/tests/it/{diffedit,resolve,new_insert,api_stability}.rs` -- matrix rows; update existing calls.
- `schemas/envelope.fbs`, `crates/zanshin-ffi/**`, `cargo make codegen` -- wire the fields; FFI unit tests read/write them; commit generated files.
- `crates/zanshin-parity/tests/oracle/{scenarios,refusal_order}.rs` -- tokens in the 9.17 scenarios; the `new` root-merge witness.
- `packages/zanshin_core/**` -- Dart fields/params + real-cdylib tests.
- `docs/ffi-abi.md`, `docs/rust-error-codes.md` -- per Code Map.
- `_bmad-output/implementation-artifacts/deferred-work.md` -- strike items 1–4 (RESOLVED form from the dispatch), add the "Surfaced in the staleness run" section with the frontmatter deferral; Story 9.17 spec's three deferred items and the 9.18 follow-up spec's one get `resolved: >-`.

**Acceptance Criteria:**
- Given a GUI that read `show(@).tree_ids` and built a tree with `select_tree`, when `@` changes on disk before `diffedit` runs, then `diffedit` refuses `jj.stale_selection`, writes no operation, and `@` keeps the disk edit.
- Given `resolve_list` reported a file's `term_ids`, when that conflict's sides change before `resolve` with `Files`, then `resolve` refuses `jj.stale_selection` and writes nothing; unchanged ids resolve as before.
- Given a modify/delete conflict, when `resolve_list` runs (Rust, FFI, Dart), then the deleted side's term id is absent (`None` / `null`) and the other terms are present.
- Given both `templates.new_description` and the alias broken, when `new @ root()` runs, then Zanshin and the pinned CLI refuse with the template class and no operation (oracle `refusal_order::`); with a valid template it still refuses `GIT_ROOT_MERGE`, and the drop/card `new` rows still preview the root-merge refusal.
- Given the Dart `RepoHandle`, when `resolveList`, `resolve` and `diffedit` run through the real cdylib, then they carry and honor the tokens above.

## Spec Change Log

## Review Triage Log

### 2026-10-25 — Review pass
- verdicts: 26 findings — high 0, medium 3, low 22, false 1, maybe-false 0
- note: the review diff left out the two codegen outputs (`envelope_generated.rs`, `envelope_zanshin.ffi_generated.dart`) and the `_bmad-output/` bookkeeping; `cargo make codegen` reproduced the generated files with no diff.
- findings:
  - `[low]` `[patch]` (verification-gap) `Files` on an unresolvable conflict: "term ids before `ConflictNotResolvable`" is unpinned — `tests/it/resolve.rs`: 3-sided with listed ids → `ConflictNotResolvable`, with one id replaced → `StaleSelection`.
  - `[low]` `[patch]` (verification-gap, other) a non-file conflict can no longer reach `jj.conflict_not_resolvable` through `Files` (empty token `jj.invalid_input`, any other stale), undocumented — grouped "non-file contract": documented in `docs/ffi-abi.md`, `Repo::resolve`, `zanshin_resolve`, `RepoHandle.resolve`; code kept (the GUI never offers `Files` for an entry with `unresolvable` set, and a stale reply is correct for a token that names no file conflict).
  - `[medium]` `[patch]` (edge) a root merge with a valid non-empty `templates.new_description` hit the Git backend at `new_description`'s hidden write → `MutateError::Backend` instead of `GIT_ROOT_MERGE` — `Templates::new_description` now calls `refuse_git_root_merge` after the parse, before `write_hidden`; test with a valid template and with only the alias broken (`new_insert.rs`).
  - `[low]` `[patch]` (edge) a never-file conflict sent with a token says "changed since it was listed" — grouped "non-file contract" (docs).
  - `[low]` `[patch]` (edge) an echoed empty token for a non-file conflict gets "needs the term ids resolve_list reported" — grouped "non-file contract" (docs).
  - `[low]` `[reject]` (edge) Dart does not reject an interior NUL in `termIds` — the ids come from `resolve_list` (hex); a NUL only makes the comparison fail (stale), no harm; adding a guard is new code for a case that never arises.
  - `[medium]` `[patch]` (edge, claim) the AC "with a valid template it still refuses GIT_ROOT_MERGE" held only for the empty template — grouped with the hidden-write row.
  - `[medium]` `[patch]` (blind) the root-merge refusal sat after the template render, past the hidden write — grouped with the hidden-write row.
  - `[low]` `[patch]` (blind) no test for a valid template / alias alone with a root merge — grouped with the hidden-write row (both cases tested).
  - `[low]` `[patch]` (blind) "refused up front" wording left in `zanshin_new_change`, `Repo::new_change` and the Story 9.31 sentence of `rust-error-codes.md` — reworded (refused before anything is written, after the template is parsed; rows still preview it); header/bindings regenerated.
  - `[low]` `[reject]` (blind) `term_ids` are only checked non-empty, a malformed one is stale rather than invalid — the GUI sends back what `resolve_list` produced; either refusal writes nothing; parsing would add a branch for a case the honest flow never reaches.
  - `[low]` `[reject]` (blind) Dart NUL guard for `termIds` — same as the edge row above.
  - `[low]` `[patch]` (blind) the non-file refusal is documented in only two places — grouped "non-file contract".
  - `[low]` `[patch]` (blind) `RepoHandle.resolve`'s docs do not mention the token or its refusals — added.
  - `[low]` `[defer]` (blind) `right` comes from a separate `show`, so a re-read after `select_tree` reopens the loss — the intent fixes the source as `ShowEntry.tree_ids`; recorded in `deferred:` and deferred-work.md for the UI story / Ralph.
  - `[low]` `[reject]` (blind) stale `right` tested only in the `-r` form — both forms reach the one `target` comparison; a per-form copy adds nothing.
  - `[low]` `[reject]` (blind) the FFI resolve test does not assert "no operation" — the jj-level and Dart tests assert it; the FFI layer only maps the code (9.17/9.50 precedent).
  - `[low]` `[patch]` (blind) doc paragraphs left with early line breaks (`zanshin_diffedit`, `Repo::diffedit`) — reflowed, codegen rerun.
  - `[low]` `[reject]` (blind) `right` parsed twice, the second `?` unreachable — one line, no harm; the arg check must run before the snapshot and the comparison needs the parsed `Merge`.
  - `[low]` `[reject]` (intent) `left`-before-`right` precedence not witnessed — both refuse `jj.stale_selection` with no operation; only the context text differs.
  - `[low]` `[patch]` (intent) the "no longer a file conflict → stale" branch is untested — grouped with the first verification-gap row: a `Files` resolve of the symlink conflict with a token refuses `StaleSelection`.
  - `[low]` `[patch]` (intent) nothing shows that an empty-file term has an id (only absent → `None`) — `an_empty_file_side_has_a_term_id_and_an_absent_base_none` (`resolve.rs`).
  - `[low]` `[patch]` (intent) the ledger said modify/delete was witnessed in FFI too — reworded in deferred-work.md and the 9.17 spec's `resolved:` (Rust and Dart; FFI an absent base).
  - `[low]` `[reject]` (intent) `-A`/`-B`-computed root merges with a broken template have no witness — they take the same `location.parents` into the same check as the positional form.
  - `[false]` `[reject]` (intent) rows covered only by existing tests — `drop_actions::a_change_dropped_onto_the_root_and_another_change_refuses_the_root_merge` ran and passed with the moved check; nothing is missing.
  - `[low]` `[patch]` (intent) `rust-error-codes.md` / `ffi-abi.md` keep the 9.31 "refused before anything is written" text — grouped with the "up front" wording row.

## Design Notes

- Term ids are the SIMPLIFIED ids (`MaterializedFileConflictValue.ids`), the same terms `labels` and `hunks` describe — a change that simplifies away (e.g. the unsimplified conflict gains a canceling pair) leaves the composed content valid, so it is correctly not stale.
- diffedit's check is the target's tree, not a per-path diff: `diffedit` writes the whole tree, so any change to the target invalidates the selection (Ralph's 2026-10-25 decision).
- Example: list on `c.txt` (base absent) → `term_ids: [Some("ab12…"), None, Some("cd34…")]`; resolve sends the same three back.

## Verification

**Commands:**
- `cargo fmt --all --check` -- clean
- `cargo clippy -p zanshin-jj -p zanshin-ffi -p zanshin-parity --all-targets -- -D warnings` -- clean
- `cargo test -p zanshin-jj` (lib + `--test it diffedit:: resolve:: new_insert:: drop_actions:: api_stability:: select_tree::`) -- green
- `cargo test -p zanshin-ffi` -- green
- `cargo make codegen` -- output committed, no further diff
- `cargo test -p zanshin-parity --test oracle` -- green, no ledger entry
- `packages/zanshin_core` (Makefile `test-core` env): `dart test test/worker/resolve_test.dart test/worker/diffedit_test.dart test/ffi`; `dart analyze --fatal-infos`; `dart format --set-exit-if-changed .` -- green
- `dart analyze app` -- clean

**Verification notes (this run; gate rule: no `cargo make test` / `test-full` / `coverage`):**
- Before review: `cargo fmt --all --check` clean; `cargo clippy -p zanshin-jj -p zanshin-ffi -p zanshin-parity --all-targets -- -D warnings` clean; `cargo test -p zanshin-jj` 379 lib + 1361 it passed (1 pre-existing ignore); `cargo test -p zanshin-ffi` 223 + 380 passed; `cargo make codegen` exit 0, no further diff; `cargo test -p zanshin-parity --test oracle` 443 passed incl. `refusal_order::new_parses_…` with the `new @ root()` case; `packages/zanshin_core` (`cargo make --allow-private test-core`, real cdylib) 1087 passed, `test-core-analyze` no issues, `test-core-format` 0 changed; `dart analyze app` no issues.
- After the review patches (all re-run): fmt clean; clippy clean; `cargo test -p zanshin-jj` 379 + 1363 passed; `cargo test -p zanshin-ffi` 223 + 380 passed; codegen rerun with no diff; oracle 443 passed; `test-core` 1087 passed, analyze no issues, format 0 changed; `dart analyze app` no issues.
- The implementer saw `cancel::tests::kill_group_signals_a_whole_group_and_never_ours` (`crates/zanshin-jj/src/cancel.rs`, untouched) fail once in four `--lib` runs; it passed in both of my full runs — a pre-existing flake, not this change.
- Matrix audit: diffedit fresh (every updated 9.17 test), target edited (`diffedit::a_target_edited_after_the_selection_is_stale_and_keeps_the_edit`, Dart), no right (`diffedit::a_missing_or_malformed_right_refuses_before_the_snapshot`, unit test, FFI, Dart); list ids (`resolve::list_reports_the_term_ids_with_an_absent_base`, FFI, Dart), modify/delete (`resolve.rs` deleting-side test, Dart), resolve fresh/stale (`resolve::a_conflict_changed_since_the_list_is_stale`, FFI, Dart), no ids (unit test, Dart); new root merge with broken template (`new_insert::a_broken_template_refuses_a_root_merge_before_the_git_backend`, oracle), template ok (`new_insert.rs` root-merge tests incl. the valid-template one), rows (`drop_actions.rs` root-merge row test) — all ran and passed.
- Coverage not measured (gate rule); every new branch has a test (stale/fresh/non-file/3-sided token paths, both root-merge call sites, the empty-token and malformed-`right` refusals).

## Auto Run Result

Status: done

**Items.**
1. `diffedit` loses edits the target received after `select_tree` — **fixed (66dc1cf4b2e246982024f85be199d92fa7566147).** Verified real: only `check_left` ran, then `set_tree` replaced the whole tree. `DiffeditOptions.right` (wire `DiffeditRequest.right`, Dart `diffedit(right:)`) is REQUIRED — an optional token would let any caller opt out of the protection silently, and the GUI always has `show`'s `tree_ids`; missing/malformed → `jj.invalid_input` before the snapshot. After the guard and the `left` check a target tree ≠ `right` refuses `jj.stale_selection`; only the snapshot's operation exists and the edit stays in the target.
2. `resolve` with GUI files has no staleness token — **fixed (66dc1cf).** Verified real: `merge_tool_file` only checked "still a conflict". `ConflictedFile.term_ids` (jj-lib's simplified `MaterializedFileConflictValue.ids`, hex, `Merge` order; wire `[ConflictTermId { id }]`, absent `id` = no file) come back, required, on every `ResolvedFile`; a mismatch — or a conflict that is no longer a file conflict — refuses `jj.stale_selection` before `jj.conflict_not_resolvable`, nothing written. `:ours`/`:theirs` take no token.
3. `resolve_list` cannot tell an absent side from an empty file — **fixed (66dc1cf)** by item 2's ids: an absent/deleted term has `None` (Dart `null`), an empty file an id; tested on a modify/delete conflict (Rust, Dart), an absent base (Rust, FFI, Dart) and an empty-file side (Rust).
4. `new` root merge with a broken `templates.new_description` names the backend, not the template — **fixed (66dc1cf).** Verified real against `cmd_new` @ v0.46.0 (template parse :217-221 before the hidden/commit write where the backend refuses). `plan_new` no longer refuses the root merge; `Templates::new_description` refuses it after the parse, before its hidden write, and `new_change` before the commit write (empty template); `Rows::new_change` keeps previewing it after the plan. Oracle `refusal_order.rs` witnesses `new @ root()` → template class against the pinned CLI.

**Summary.** Two staleness tokens close the GUI-editor data-loss windows of 9.17's `diffedit` and `resolve` (Ralph's 2026-10-25 rule), the term ids also expose absent conflict sides, and `new` refuses a root merge in the CLI's order. Full chain: `.fbs` append-only (new table `ConflictTermId`), zanshin-jj, FFI readers/writer + committed codegen, Dart models/wrappers + real-cdylib tests, `docs/ffi-abi.md`, `docs/rust-error-codes.md`, oracle.

**Files changed (66dc1cf).**
- `crates/zanshin-jj/src/{diffedit,resolve,mutate,template,drop_actions,select_tree,repo}.rs` -- tokens, checks, root-merge order, docs.
- `crates/zanshin-jj/tests/it/{diffedit,resolve,new_insert,api_stability}.rs` -- matrix rows, review rows.
- `schemas/envelope.fbs`, `crates/zanshin-ffi/src/{diffedit,resolve,envelope,select_tree,repo}.rs`, generated `envelope_generated.rs` / `zanshin_ffi.h` / Dart `envelope_zanshin.ffi_generated.dart` / `bindings.dart`, `crates/zanshin-ffi/tests/it/{resolve_ffi,select_tree_ffi}.rs` -- wire + FFI tests.
- `crates/zanshin-parity/tests/oracle/{scenarios,refusal_order}.rs` -- tokens in the 9.17 scenarios, `new @ root()` witness.
- `packages/zanshin_core/lib/src/{ffi/resolve.dart,ffi/diffedit.dart,worker/commands.dart,worker/isolate.dart,worker/handle.dart}`, `test/worker/{resolve,diffedit}_test.dart` -- Dart surface + real-cdylib tests.
- `docs/ffi-abi.md`, `docs/rust-error-codes.md` -- fields, refusal orders, `jj.stale_selection` / `jj.invalid_input` causes, the 9.31 root-merge order.

**Review.** 26 findings (high 0, medium 3, low 22, false 1). Patched: medium 1 entry — the root-merge refusal moved before `new_description`'s hidden write (a valid template returned `Backend`), with tests; low 7 entries — `Files` refusal order pinned (3-sided, symlink), empty-file term id witnessed, the non-file `Files` contract documented, `RepoHandle.resolve` docs, "up front" wording, doc reflow, ledger wording. Deferred: `right` from a separate `show` read (low, frontmatter + deferred-work.md). Rejected with reasons in the triage log: Dart NUL guard for `termIds` (×2), malformed `term_ids` as invalid, per-form/per-layer test copies (×2), the double parse of `right`, `left`/`right` precedence, `-A`/`-B` root-merge witness, and one false row.

**Follow-up review recommended: false.** First pass; patched at entry verdict: high 0, medium 1, low 7 — below the two-medium threshold.

**New deferrals (also in deferred-work.md "Surfaced in the staleness run").** `duplicate`/`revert` have item 4's root-merge order gap (low, found at planning); `right` from a separate `show` (low, review).

**Residual risks.** Coverage unmeasured until the orchestrator's gate; the `cancel.rs` kill-group unit test flaked once for the implementer (untouched code).

**Commits.** 66dc1cf4b2e246982024f85be199d92fa7566147 (code, schema, generated files, docs, tests); the ledger commit (this spec, epic-9 context, deferred-work.md, the 9.17 and 9.18-follow-up specs' `resolved:`) follows.
