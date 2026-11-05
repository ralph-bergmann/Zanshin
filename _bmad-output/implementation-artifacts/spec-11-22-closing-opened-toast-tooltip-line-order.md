---
title: 'Story 11.22 closing run — pin the Opened toast tooltip line order (linked-worktree warning after the trackable hint)'
type: 'chore'
created: '2026-11-05'
status: 'done'
baseline_revision: '86a285f5f6e66ef62259f24b593ec9a29ba46a34'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
warnings: []
deferred: []
---

<intent-contract>

## Intent

**Problem:** Item 1 of Story 11.22's deferred list: the Opened toast's tooltip puts a `colocatedInGitWorktree` warning after jj's trackable-bookmark hint (as `jj git init` prints it, `init.rs:285`), but the only test checks the tooltip `contains` the hint, so dropping the `afterHint` split stays green.

**Approach:** Test-only: in `home_page_test.dart`, a conversion whose report carries an ordinary warning, a `colocatedInGitWorktree` warning and a trackable list; assert the whole tooltip string, so the order (other warning → hint block → linked-worktree warning) is pinned.

## Boundaries & Constraints

**Always:** exact-equality assertion on `ZsToast.tooltip`; reuse `FakeProjectRepos.creationWarnings` / `creationTrackable`; SPDX/width 120, analyze and format clean.

**Never:** no production code change (the order is already right); no Rust/FFI/schema change; no change to the existing 11.22 test's expectations.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Both warnings + trackable | `/r/wt`: warnings [identityMissing, colocatedInGitWorktree], trackable [main@origin] | tooltip = identity message, hint lines, `  main@origin`, run-command hint, `  jj bookmark track main@origin`, help text, worktree message — in that order | — |

</intent-contract>

## Code Map

- `app/lib/src/features/home/home_page.dart:207-248` -- read-only: `afterHint` and the tooltip list.
- `app/test/features/home/home_page_test.dart:348-380` -- existing 11.22 toast test; add the new test after it.
- `app/test/helpers/fake_projects.dart:31-34,142-143` -- `creationWarnings` / `creationTrackable` feed the report for `convert`.
- `strings.toastUntrackedHelp` -- read its English text from the app's l10n (`app/lib/l10n/*.arb`) or `AppLocalizations` in the test.

## Tasks & Acceptance

**Execution:**
- `app/test/features/home/home_page_test.dart` -- add test "Story 11.22 closing: the linked-worktree warning follows jj's trackable hint in the tooltip" per the matrix -- closes item 1.

**Acceptance Criteria:**
- Given the matrix row, when the test runs, then the tooltip equals the expected joined lines; given `afterHint` removed (worktree warning first), then the test fails.
- Given `app/`, when `flutter test`, `dart analyze --fatal-infos --fatal-warnings`, `dart format --output=none --set-exit-if-changed .` run, then all pass.

## Spec Change Log

## Review Triage Log

### 2026-11-05 — Review pass
- verdicts: 9 findings — high 0, medium 0, low 8, false 1, maybe-false 0
- findings:
  - `[low]` `[reject]` (blind 1) The help line is an English literal, not `AppLocalizations.toastUntrackedHelp` — every toast test in this file asserts English literals (e.g. :338, :360); a reworded string fails loudly and is a one-line update.
  - `[low]` `[patch]` (blind 2) The test name escapes an apostrophe where the file uses double quotes — name switched to double quotes; analyze was already clean (lint not enabled).
  - `[low]` `[reject]` (blind 3) The test checks neither the visible message nor the tone — not this item (tooltip order); message and tone of warnings and of the untracked clause are pinned by the 11.22 tests at :326 and :348.
  - `[low]` `[reject]` (blind 4) No assertion that the toast is dismissed — the trailing pumps only drain timers; dismissal is pinned at :345.
  - `[false]` `[reject]` (blind 5) The parentheses around the help literal are unneeded — they are required: without them `dart analyze --fatal-infos` reports `no_adjacent_strings_in_list` (seen during implementation).
  - `[low]` `[reject]` (blind 6) No case with only the worktree warning — `afterHint` is a per-warning filter with no count branch; the pinned multi-warning case already fails when the split is dropped (checked by forcing `afterHint` to false).
  - `[low]` `[reject]` (intent 1) A sibling test instead of extending the existing one — extending it would change that test's message expectations (warnings render in the message); same behavior pinned.
  - `[low]` `[reject]` (intent 2) Exact equality pins hint text and help copy beyond order — that text is jj's (parity) and the app's own copy; exact equality is what makes the order fail loudly.
  - `[low]` `[reject]` (intent 3) Identity-before-hint order pinned beyond the item — the CLI prints other conversion warnings before the hint (`init.rs`), the order `home_page.dart:207` states; pinning it is in-scope.
  - verification-gap: no gaps reported. edge-case hunter: no findings.

## Verification

**Commands (gate rule of this run: no `cargo make test` / `test-full` / `coverage`):**
- `flutter test test/features/home/home_page_test.dart` (in `app/`) -- expected: pass.
- `dart analyze --fatal-infos --fatal-warnings` and `dart format --output=none --set-exit-if-changed .` (in `app/`) -- expected: exit 0.

**Outcomes (2026-11-05, gate rule of this run):**
- `flutter test test/features/home/home_page_test.dart`: 26 passed (before and after the review patch). With `afterHint` forced to `false` the new test failed, so it pins the order; the line was restored.
- `dart analyze --fatal-infos --fatal-warnings` (`app/`): no issues. `dart format --output=none --set-exit-if-changed .`: 0 changed.
- No Rust, FFI, schema or production Dart change: no cargo test/clippy/fmt/codegen/parity run needed.

## Auto Run Result

Status: done (2026-11-05). Blocking condition: none.

**Items.**
1. No test pins the linked-worktree warning after jj's trackable hint in the Opened toast tooltip — **fixed** (commit `23c562a7c209c64bc09d4d07f95bb6a6d7f505db`). Verified real first: the only tooltip check was a `contains`; the code order already matches jj v0.46.0 `init.rs` (trackable hint before the worktree warning), so the change is test-only.

**Summary.** New widget test in `home_page_test.dart`: a conversion with an identity warning, a `colocatedInGitWorktree` warning and `main@origin` trackable; the tooltip is asserted by exact equality — identity message, jj's hint block and command, the help text, then the worktree message.

**Files changed.**
- `app/test/features/home/home_page_test.dart` -- test "Story 11.22 closing: the linked-worktree warning follows jj's trackable hint in the tooltip".
- Tracking: this spec. No new deferrals, so no `deferred-work.md` section.

**Review findings.** 9 findings (high 0, medium 0, low 8, false 1). Patched: 1 low (double-quoted test name). Deferred: none. Rejected with reasons in the triage log: English literal for the help text, missing message/tone and dismissal checks, worktree-only case, sibling vs extended test, over-pinning, identity-before-hint pinning (low); parentheses unneeded (false).

**Follow-up review recommendation:** false — patched: low 1.

**Verification.** See Verification › Outcomes.

**Residual risks.** Rewording `toastUntrackedHelp` in `app_en.arb` needs this test's literal updated. The full gate runs at the end of the story loop.
