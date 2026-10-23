---
title: 'Story 9.40 closing run — the undo git-refs witness asserts a written view again'
type: 'chore'
created: '2026-10-23'
status: 'done'
baseline_revision: 'd666ad9427b5068c155d021a4b331d99d4ce336e'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-9-context.md'
warnings: []
deferred: []
---

<intent-contract>

## Intent

**Problem:** Story 9.40's deferred item 1, verified at `d666ad9`: `undo_preserves_current_git_head_and_git_refs_not_targets` (`crates/zanshin-jj/tests/it/op_log.rs:773-848`) builds op A and op B that change only `git_refs`/`git_head`. `op_log::undo` (`src/op_log.rs:159-215`) restores op A's view but keeps the current `git_refs`/`git_heads` (`restored_view`, `:252`), so the restored view equals the current one and `mutate::finish_verb` (`src/mutate.rs:849`) takes its no-change arm — nothing is written, and the test's "kept current `git_refs`/`git_head`" assertions hold trivially on the unchanged view. The CLI's default `jj undo` likewise keeps `git_refs`/`git_head` (`view_with_desired_portions_restored`, `cli/src/commands/operation/mod.rs` @ v0.46.0), so the production behavior is right; only the witness lost its teeth.

**Approach:** Op B additionally moves a repo-portion field the undo DOES restore — a local bookmark created at Commit 3 — so the restored view differs from the current one and the undo writes an operation. The test then asserts the undo wrote (new head op ≠ op B, description "undo: restore to operation <op A>"), the bookmark is gone (the repo portion came from the target), and `git_refs`/`git_head` still sit at Commit 3 (kept from the current view) — all on the written view.

## Boundaries & Constraints

**Always:** Test-only change in `crates/zanshin-jj/tests/it/op_log.rs`; the existing `git_head`/`git_refs` assertions stay (now on a written view); the new assertions prove the undo wrote and restored the repo portion.

**Never:** No production code change (`op_log.rs`, `mutate.rs`), no fixture regeneration, no change to Story 9.40's spec, `epics.md` or `epic-9-context.md`; no new oracle scenario (the oracle's `undo_no_change` keeps pinning the no-change arm).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Undo of a git-ref move plus a bookmark creation | op A: git ref/head at Commit 1; op B: git ref/head at Commit 3 + local bookmark at Commit 3; `undo(false)` | `Ok`; `new_op_id` ≠ op B's id; head op description = "undo: restore to operation " + op A's hex; bookmark absent; `git_head` = [Commit 3]; `git_refs` contain Commit 3, not Commit 1 | No error expected |

</intent-contract>

## Code Map

- `crates/zanshin-jj/tests/it/op_log.rs:773-848` -- the test to strengthen. Op B is built at :798-805 through a raw jj-lib transaction (`tx2.repo_mut()`); `repo_a` (op A's `Arc<ReadonlyRepo>`) gives op A's id via `.operation().id()`. Imports at :3-19 (`RefTarget`, `ObjectId`, `jj_lib::repo::Repo as _` already present).
- `crates/zanshin-jj/tests/it/bookmarks.rs:112` -- reuse pattern: `mr.set_local_bookmark_target("feature".as_ref(), RefTarget::normal(id))`; read back with `view.get_local_bookmark(..)` / `view.local_bookmarks()`.
- `crates/zanshin-jj/src/op_log.rs:207-213,252-260` -- READ-ONLY: `undo` builds `restored_view` (bookmarks/heads/wc from target, `git_refs`/`git_heads` from current), description `UNDO_OP_DESC_PREFIX` + target parent hex (:212, prefix "undo: restore to operation " :220).
- `crates/zanshin-jj/src/mutate.rs:59-68,849-864` -- READ-ONLY: `MutationResult::new_op_id` is the pre-call head when `finish_verb` takes the no-change arm.
- `_bmad-output/implementation-artifacts/deferred-work.md:1867-1869` -- strike the item, `RESOLVED 2026-10-23 (spec-9-40-closing-undo-keeps-git-refs-witness, commit …)`.

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/tests/it/op_log.rs` -- op B also creates a local bookmark at Commit 3; keep op A's / op B's ids; assert the undo wrote (new id ≠ op B; head op description names op A), the bookmark is absent afterwards, and the existing git_head/git_refs assertions; update the test's comments to say why the bookmark is there -- item 1.
- `_bmad-output/implementation-artifacts/deferred-work.md` -- resolve the item (spec commit).

**Acceptance Criteria:**
- Given op B moves Git refs and creates a local bookmark, when `undo(false)` runs, then it writes a new operation whose view lacks the bookmark and keeps `git_refs`/`git_head` at Commit 3.
- Given the pre-change code, when the strengthened test runs, then it passes (production behavior already matches the CLI); a regression copying `git_refs` or `git_heads` from the target would now fail on a written view.

## Spec Change Log

## Review Triage Log

### 2026-10-23 — Review pass
- verdicts: 13 findings — high 0, medium 0, low 9, false 4, maybe-false 0
- findings:
  - `[low]` `[reject]` (blind) the spec's AC 2 / rationale overclaim: a `restored_view` copying `git_refs`/`git_heads` from the target would already have made the old test write and fail; what the old test really missed is an undo that restores nothing — true for the swap regression (the implementer's temporary swap fails both old and new test); the test comment itself is accurate ("the git assertions below would hold trivially on the unchanged view"), and the remaining fix edits this build's spec; recorded under Residual risks.
  - `[low]` `[patch]` (blind) the RESOLVED ledger line carries no commit hash — added `commit 873ccfe` at finalize.
  - `[low]` `[patch]` (blind) the resolved item's `**Follow-up:**` bullet still reads as open work — now "Done (spec-9-40-closing-undo-keeps-git-refs-witness)."
  - `[low]` `[reject]` (blind) Story 9.40's second deferred item (Story 9.38's stale tracking text) is not handled — the intent limits this run to item 1 ("exactly these items … nothing else").
  - `[low]` `[patch]` (blind) sprint-status.yaml `9-40-…` still says "Deferred: a now-trivial undo git_refs test" — the note now records the resolution with commit 873ccfe.
  - `[low]` `[reject]` (blind) no `parent_ids == [op_b]` assertion — whether an op lies between op B and the undo does not affect the item's claim (git_refs kept on a written view); the new-id + description + bookmark assertions already prove the undo wrote.
  - `[low]` `[reject]` (blind) no positive control that the bookmark exists before the undo — the bookmark is created by op B's committed transaction in-test; an extra pre-read adds nothing the commit does not already establish.
  - `[false]` `[reject]` (blind) the test silently depends on a non-colocated fixture, else `finish_transaction`'s HEAD reset / ref export would confound the git assertions — `tiny-3-commits.tar.zst` has no `.git/` (0 entries), so finish never touches Git; the implementer's swap experiment shows the git_head assertion fails on a regression, so it is not confounded.
  - `[low]` `[patch]` (blind) the opening comment's "(Story 2.8's bookmarks are read-only)" reads stale next to the new bookmark write — reworded: git_refs/git_head have no public mutation and op B's bookmark must land in the same operation as its Git-ref move.
  - `[false]` `[reject]` (blind) the spec's Code Map line refs / `.operation().id()` drifted from the built code — Code Map is the pre-implementation investigation map; fixing it edits this build's spec.
  - `[low]` `[patch]` (edge) ledger RESOLVED text lacks the commit hash — same entry as the blind hash row; patched at finalize.
  - `[false]` `[reject]` (intent) the fix lives at the integration-test surface, not the parity oracle — the item's ledger follow-up names the test explicitly; the oracle compares the CLI's undo with Zanshin's, and `undo_no_change` keeps its no-change role; no divergence from the item.
  - `[false]` `[reject]` (intent) `## Auto Run Result`, verification results and the ledger hash are missing — written at finalize (this pass).

## Verification

**Commands (targeted; the story loop runs the full gate — do NOT run `cargo make test`, `cargo make test-full` or `cargo make coverage`):**
- `cargo test -p zanshin-jj --test it op_log::` -- expected: green.
- `cargo clippy -p zanshin-jj --all-targets -- -D warnings`, `cargo fmt --all --check` -- expected: clean.

**Verification notes (run 2026-10-23, after the review patches; no `cargo make test` / `test-full` / `coverage` per the loop's gate rule):**
- `cargo test -p zanshin-jj --test it op_log::` — 25 passed (incl. `undo_preserves_current_git_head_and_git_refs_not_targets`); re-run of `op_log::undo_preserves` after the comment rewrap — 1 passed.
- `cargo clippy -p zanshin-jj --all-targets -- -D warnings` — clean.
- `cargo fmt --all --check` — clean.
- Regression probe (implementer, reverted): `restored_view` taking `git_refs`/`git_heads` from the target makes the strengthened test fail on its `git_head` assertion; `src/op_log.rs` unchanged afterwards.
- No `cargo make codegen` (no FFI / schema change), no parity oracle (no verb changed), no Dart package touched; no dependent crate affected (test-only change in `zanshin-jj`'s `it` binary).
- Matrix audit: the single row is covered by `op_log::undo_preserves_current_git_head_and_git_refs_not_targets`, which ran and passed.

## Auto Run Result

Status: done

**Items:**
- **1 — fixed (873ccfe2d2a8083e7fdd827f539bdc49cfd37a8d).** Verified real at `d666ad9`: op A and op B changed only `git_refs`/`git_head`; `op_log::undo`'s `restored_view` keeps the current Git state, so the restored view equalled op B's and `mutate::finish_verb`'s Story 9.40 gate wrote nothing — the git assertions held on the unchanged view. Production behavior already matches the CLI's default `jj undo` (`view_with_desired_portions_restored`, DEFAULT_REVERT_WHAT), so only the witness changed: op B also creates a local bookmark at Commit 3; the test asserts the undo wrote (new id ≠ op B, = op-log head, description "undo: restore to operation <op A>"), the bookmark is gone, and `git_head`/`git_refs` stay at Commit 3 on the written view.

**New findings:** none (`deferred: []`; nothing mirrored into deferred-work.md).

**Files changed:**
- `crates/zanshin-jj/tests/it/op_log.rs` (873ccfe) — op B creates a bookmark; written-op, bookmark-absence assertions; comments.
- `_bmad-output/implementation-artifacts/deferred-work.md` — item resolved (commit 873ccfe), follow-up marked done (spec commit).
- `_bmad-output/implementation-artifacts/sprint-status.yaml` — `9-40-…` note records the resolution (spec commit).

**Review:** 13 findings (low 9, false 4). Patched (low): ledger commit hash (blind + edge), ledger follow-up bullet, sprint-status note, stale opening comment. Rejected: the AC-2 overclaim (the swap regression was already caught by the old test; the honest residual is below), Story 9.38's text (outside this run's one item), `parent_ids` assertion and bookmark positive control (add nothing to the item's claim), plus the false rows (non-colocated fixture, Code Map drift, oracle surface, finalize-time bookkeeping).

**Follow-up review recommended:** false — patched counts high 0, medium 0, low 5 rows (4 entries).

**Residual risks:** the strengthened test's new teeth are against an undo that restores nothing (writes no op) — a `restored_view` swap of the Git portions was already caught by the old test, so the spec's AC 2 overstates the regression the old version missed; coverage not measured (test-only change, loop gate at the end).

