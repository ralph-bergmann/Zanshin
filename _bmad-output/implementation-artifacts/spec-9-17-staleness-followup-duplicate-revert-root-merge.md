---
title: 'Staleness-run follow-up — `duplicate` / `revert` refuse a root merge after their description template'
type: 'bugfix'
created: '2026-10-25'
status: 'done'
baseline_revision: '4f6fcd1df859097c87bbf58bdc5c9026b73cf528'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/spec-9-17-staleness-run-diffedit-resolve.md'
warnings: []
deferred: []
---

<intent-contract>

## Intent

**Problem:** `plan_duplicate_ids` (`crates/zanshin-jj/src/duplicate.rs:115`) and `plan_revert` (`crates/zanshin-jj/src/revert.rs:103`) refuse a Git root merge in the plan, so with a broken `templates.duplicate_description` / `templates.revert_description` Zanshin answers with the Git backend's root-merge text where the pinned CLI names the template. Verified real at the baseline against v0.46.0: `cmd_duplicate` parses its template (`cli/src/commands/duplicate.rs:178-181`) before `duplicate_commits` writes (`:199`); `cmd_revert` parses its template (`cli/src/commands/revert.rs:132-136`) before the first `new_commit(...).write()` (`:183-187`); the backend refuses at those writes.

**Approach:** Mirror the staleness run's `new` fix (commit 66dc1cf): drop the `refuse_git_root_merge` call from both plans; each verb calls it after its description render, right before its first write; `drop_actions`' `duplicate` row and `Rows::revert` call it themselves right after the plan (previews keep refusing the root merge).

## Boundaries & Constraints

**Always:**
- Hidden-write lesson checked: neither verb renders on a hidden write — `Templates::duplicate_descriptions` / `revert_descriptions` (`template.rs:386-419`) render on existing commits (the originals / the reverted ones), as the CLI does — so the check right before the first write is the only place needed.
- `duplicate`: inside the `Some((parents, children))` arm of the `plan.location` match (`duplicate.rs:221`), before `duplicate_commits`; no location has no new parents (the originals' parents can never be a root merge). After the self-placement warnings, as the CLI.
- `revert`: after `descriptions` (`revert.rs:261-264`), before `write_reverse_commits`.
- Rows: `drop_actions.rs:434-441` (`duplicate` row: after `plan_duplicate`, from `plan.location`'s parents, before `resolve_immutable`) and `drop_actions.rs:316-331` (`Rows::revert`: after `plan_revert`, from `plan.new_parent_ids`, before `resolve_immutable`, inside the existing `Option` map — no new branch).
- Docs follow: `plan_duplicate_ids` / `plan_duplicate` and `plan_revert` rustdoc (no longer refuse the root merge; who does), `Repo::duplicate` / `Repo::revert` Errors (root merge refused before anything is written, after the template is parsed), the `docs/ffi-abi.md` revert Order bullet (~L2105-2109: root merge after the template parse). `docs/rust-error-codes.md` states no duplicate/revert root-merge order — left as is.
- Every refusal writes no operation beyond the CLI's own start-up snapshot.

**Never:** No other verb; no change to error codes, texts or the FFI/schema (no codegen); no Flutter/Dart; no MCP; no regenerated fixtures; no full gate (`cargo make test` / `test-full` / `coverage`) — targeted checks only (gate rule).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| duplicate root merge, template broken | `duplicate B -o C -o root` with `templates.duplicate_description = '"x" ++'` (alone, and with the alias broken) | refused, no op | `jj.config_error` template (= CLI) |
| duplicate root merge, template ok | same with a valid non-empty template, or only the alias broken | refused, no op | `InvalidInput` `GIT_ROOT_MERGE` |
| revert root merge, template broken | `revert -r B -o C -o root` with `templates.revert_description = '"x" ++'` (alone, and with the alias broken) | refused, no op | template `Config` (= CLI) |
| revert root merge, template ok | same with a valid template, or only the alias broken | refused, no op | `GIT_ROOT_MERGE` (existing test L262 stays) |
| rows | change dropped onto root + another change | `Duplicate` / `Revert` rows refused `GIT_ROOT_MERGE` (unchanged) | — |
| oracle | both-broken repo, `duplicate @- -o @ -o root()`, `revert -r @- -o @ -o root()` | CLI and Zanshin refuse with the template class, no op | — |

</intent-contract>

## Code Map

- `crates/zanshin-jj/src/duplicate.rs` -- `plan_duplicate_ids` L83-121 (remove L113-115 + doc L90-92; Errors of `plan_duplicate` L67-68), `duplicate` L221-235 (refuse in the `Some` arm), import stays.
- `crates/zanshin-jj/src/revert.rs` -- `plan_revert` L67-109 (remove L101-103 + doc L73-75; Errors L80-81), `revert` L261-266 (refuse before `write_reverse_commits`).
- `crates/zanshin-jj/src/drop_actions.rs` -- `revert` row L316-331, `duplicate` row L434-441; `refuse_git_root_merge` already imported (L35); the `new` row L389-391 is the pattern.
- `crates/zanshin-jj/src/mutate.rs` -- `refuse_git_root_merge` L1206 (reuse, unchanged); its doc L1202-1205 says "keeps `new`'s plan and its execution in agreement" — generalize to the rows.
- `crates/zanshin-jj/src/repo.rs` -- `Repo::duplicate` Errors L3632-3635, `Repo::revert` Errors L3679-3682.
- `crates/zanshin-jj/tests/it/duplicate.rs` -- new tests next to L193 (helpers `reconfigure`, `refused`, `assert_config_class`, `UNRESOLVABLE_ALIAS` already imported; `fx.zero` is the root).
- `crates/zanshin-jj/tests/it/revert.rs` -- new test next to L262 (`unknown_immutable_and_root_merge_locations_are_refused` stays green).
- `crates/zanshin-jj/tests/it/drop_actions.rs` L452 -- root-merge row test stays green (no edit).
- `crates/zanshin-parity/tests/oracle/refusal_order.rs` -- add `(&["revert", "-r", "@-", "-o", "@", "-o", "root()"], Class::Template)` and `(&["duplicate", "@-", "-o", "@", "-o", "root()"], Class::Template)`; `location()` already collects repeated `-o`, `id_of` knows `root()`; module doc names them.
- `docs/ffi-abi.md` ~L2105-2109 (revert Order bullet).
- Read-only: `git -C ../jj show v0.46.0:cli/src/commands/{duplicate,revert}.rs` (orders above).

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/src/{duplicate,revert,drop_actions,mutate,repo}.rs` -- move the check per Boundaries; docs.
- `crates/zanshin-jj/tests/it/{duplicate,revert}.rs` -- matrix rows 1-4 (each refusal asserts no operation via `refused`).
- `crates/zanshin-parity/tests/oracle/refusal_order.rs` -- the two witnesses.
- `docs/ffi-abi.md` -- revert order wording.
- `_bmad-output/implementation-artifacts/deferred-work.md` + `spec-9-17-staleness-run-diffedit-resolve.md` -- strike / `resolved:` (ledger commit).

**Acceptance Criteria:**
- Given a broken duplicate/revert description template, when either verb targets a root merge, then Zanshin and the pinned CLI refuse with the template class and write no operation (oracle `refusal_order::`).
- Given a valid template, when either verb targets a root merge, then it still refuses `GIT_ROOT_MERGE` with no operation, and the drop/card `Duplicate` / `Revert` rows still preview that refusal.

## Spec Change Log

## Review Triage Log

### 2026-10-25 — Review pass
- verdicts: 17 findings — high 0, medium 0, low 13, false 4, maybe-false 0
- note: edge-case hunter and verification-gap reviewer reported no findings.
- findings:
  - `[low]` `[patch]` (blind) the rows' "root merge before `resolve_immutable`" order is unpinned (a swap stays green) — `drop_actions.rs` test: unresolvable alias + drop onto `[root, D]` → `NewMerge` / `Duplicate` / `Revert` rows refuse `GIT_ROOT_MERGE`.
  - `[low]` `[reject]` (blind) the oracle never compares "valid template / alias only → root merge" with the CLI — `Class` would need a third class and a second repo setup; the order is read from `cmd_duplicate` / `cmd_revert` @ v0.46.0 and pinned in the it tests, as the staleness run did for `new`.
  - `[low]` `[reject]` (blind) the duplicate test does not assert the self-placement warnings a refused root merge now carries — they match the CLI, which prints them before the backend refuses; the item is about the refusal, and `refused` asserts no operation.
  - `[false]` `[reject]` (blind) FFI rustdoc for `zanshin_duplicate` / `zanshin_revert` not updated — they list the root-merge cause without any order, so nothing there became false.
  - `[false]` `[reject]` (blind) `docs/ffi-abi.md`'s duplicate section ("runs the duplicate plan before it writes, so the row and the verb agree") is stale — the verb still runs the shared plan, and the row and the verb still agree (both refuse after the plan); the sentence states no root-merge order.
  - `[low]` `[patch]` (blind) `docs/rust-error-codes.md` names only `zanshin_new_change` for the root-merge refusal and its order — `zanshin_duplicate` / `zanshin_revert` added to that sentence.
  - `[false]` `[reject]` (blind) the duplicate row's "always has `-o`" comment disagrees with its `if let` — the row sits in the `!location.onto.is_empty()` arm, so the plan always has a location; the comment states that invariant and the `if let` is the plain way to read the `Option`.
  - `[low]` `[reject]` (blind) no `-A`/`-B` root-merge witness — the location's parents go into the same single check as `-o`; a location with children resolves the immutable set in the plan, unchanged (staleness-run precedent for `new`).
  - `[low]` `[patch]` (blind) the new `refuse_git_root_merge` rustdoc says `new` refuses "right before that write", dropping the hidden-write case — reworded.
  - `[low]` `[reject]` (blind) the backend text is inlined in the new tests — matches the existing `revert.rs` / `new_insert.rs` style; a shared const is a refactor outside the item.
  - `[low]` `[reject]` (blind) the oracle test names say "before the finish" and the module doc keeps a short line — the `new` witness already sits in its sibling the same way; the short line predates this change.
  - `[low]` `[reject]` (intent) `-A`/`-B` forms unpinned — as the blind row above.
  - `[low]` `[reject]` (intent) the valid-template case is not CLI-compared — as the blind oracle row above.
  - `[low]` `[reject]` (intent) no FFI/Dart test — the FFI code mapping (`InvalidInput` → `jj.invalid_input`, `Config` → `jj.config_error`) is unchanged; the `zanshin-ffi` suites ran green.
  - `[low]` `[reject]` (intent) the `-A`/`-B` revert rows have no root-merge row case — the same `refuse_git_root_merge` call on the same plan field covers every location of the row.
  - `[low]` `[reject]` (intent) a refused root-merge `duplicate` now reports self-placement warnings — the CLI's own behavior (warnings printed before the failing write).
  - `[false]` `[reject]` (intent) scope reaches `mutate.rs`, `repo.rs`, `docs/ffi-abi.md` — doc-only updates the moved check would otherwise make false; no behavior change outside the item.

## Verification

**Commands:**
- `cargo fmt --all --check` -- clean
- `cargo clippy -p zanshin-jj -p zanshin-parity --all-targets -- -D warnings` -- clean
- `cargo test -p zanshin-jj --test it duplicate:: revert:: drop_actions:: new_insert::` and `cargo test -p zanshin-jj --lib duplicate revert drop_actions` -- green
- `cargo test -p zanshin-parity --test oracle` -- green, no ledger entry
- `cargo test -p zanshin-ffi --test it` duplicate/revert/drop modules -- green (dependent crate)

**Verification notes (this run; gate rule: no `cargo make test` / `test-full` / `coverage`):**
- Before review: `cargo fmt --all --check` clean; `cargo clippy -p zanshin-jj -p zanshin-parity --all-targets -- -D warnings` clean; `cargo test -p zanshin-jj --test it -- duplicate:: revert:: drop_actions:: new_insert::` 98 passed; `cargo test -p zanshin-jj --lib -- duplicate revert drop_actions` 11 passed; `cargo test -p zanshin-parity --test oracle` 443 passed (incl. both new `refusal_order::` witnesses against the pinned CLI); `cargo test -p zanshin-ffi --test it -- drop_actions_ffi:: metaedit_duplicate_fix_ffi:: revert_ffi::` 15 passed. (cargo needs the test filters after `--`.)
- After the review patches (a test and two doc edits, no oracle/FFI-relevant code): fmt clean; clippy clean; zanshin-jj it filters 99 passed (incl. `drop_actions::the_root_merge_rows_refuse_before_the_immutable_set_resolves`), lib filters 11 passed. Oracle and FFI not rerun — the patches touched no code they exercise.
- Matrix audit: duplicate/revert broken template (alone, with alias) and template ok / alias only → `duplicate::a_root_merge_is_refused_after_the_template_parse`, `revert::a_root_merge_is_refused_after_the_template_parse` (+ existing `revert::unknown_immutable_and_root_merge_locations_are_refused`); rows → `drop_actions::a_change_dropped_onto_the_root_and_another_change_refuses_the_root_merge` and the new alias row test; oracle → `refusal_order::{revert,duplicate}_parses_…` — all ran and passed.
- Hidden-write check: `duplicate_descriptions` / `revert_descriptions` render on existing commits; no write precedes the moved check.
- Coverage not measured (gate rule); every changed line runs in the tests above (both verbs' new refusal, both rows' calls).

## Auto Run Result

Status: done

**Items.**
1. `duplicate` and `revert` onto a root merge with a broken description template refuse with the Git backend's root-merge text where the CLI names the template — **fixed (67d64ecdce2f6160515c58f5fb051d2a68223cab).** Verified real against `cmd_duplicate` (template parse :178-181 before `duplicate_commits` :199) and `cmd_revert` (template parse :132-136 before the first write :183-187) @ v0.46.0. The plans no longer refuse the root merge; `duplicate` refuses it in its location arm right before `duplicate_commits` (after the self-placement warnings and the template render, as the CLI), `revert` after its descriptions right before the first reverse commit's write; the `Duplicate` / `Revert` drop/card rows refuse it right after the plan, before `resolve_immutable`. Hidden-write lesson checked: both templates render on existing commits, so no write precedes the check. Every location form reaches the one check on the resolved parents; a location with children still resolves the immutable set first, in the plan (unchanged, = CLI).

**Files changed (67d64ec).**
- `crates/zanshin-jj/src/{duplicate,revert,drop_actions}.rs` -- the moved check, rustdoc.
- `crates/zanshin-jj/src/{mutate,repo}.rs` -- `refuse_git_root_merge` / `Repo::duplicate` / `Repo::revert` docs.
- `crates/zanshin-jj/tests/it/{duplicate,revert,drop_actions}.rs` -- root merge with broken / valid template / alias only; rows with the alias broken.
- `crates/zanshin-parity/tests/oracle/refusal_order.rs` -- `duplicate @- -o @ -o root()`, `revert -r @- -o @ -o root()` → template class vs the pinned CLI.
- `docs/ffi-abi.md` (revert order), `docs/rust-error-codes.md` (`jj.invalid_input` root-merge emitters).

**Review.** 17 findings (high 0, medium 0, low 13, false 4); edge-case and verification-gap layers found none. Patched (low ×3): rows' root-merge-before-alias order pinned by a test, `refuse_git_root_merge` doc keeps `new`'s hidden-write case, `rust-error-codes.md` names `zanshin_duplicate` / `zanshin_revert`. Deferred: none. Rejected with reasons in the triage log: oracle comparison of the valid-template case (needs a new class + setup), warning assertions, `-A`/`-B` witnesses and rows (same single check), FFI/Dart tests (mapping unchanged), inline test literal, oracle test names, and four false rows (FFI docs, ffi-abi duplicate sentence, row comment, scope).

**Follow-up review recommended: false.** First pass; patched at entry verdict: high 0, medium 0, low 3.

**New deferrals.** None.

**Residual risks.** Coverage unmeasured until the orchestrator's gate.

**Commits.** 67d64ecdce2f6160515c58f5fb051d2a68223cab (code, tests, docs); the ledger commit (this spec, deferred-work.md, the staleness-run spec's `resolved:`) follows.
