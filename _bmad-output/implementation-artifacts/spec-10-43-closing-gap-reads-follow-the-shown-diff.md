---
title: 'Story 10.43 closing run — gap reads follow the diff on screen'
type: 'bugfix'
created: '2026-11-15'
status: 'done'
baseline_revision: '26e0cd12f384befe8d23eaf279b64f3cd822ec74'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
warnings:
  - oversized
deferred: []
---

<intent-contract>

## Intent

**Problem:** Item 1 of Story 10.43's deferred list. A gap row's read (`InspectorViewModel.diffLines`) uses the view model's current commit and whitespace mode, not those of the diff on screen. Both halves are real (verified in the code, see Design Notes): (a) after an operation rewrites the selected change, `_fetch` sets the new `_commitId` while the old diff still shows (no `previousDiff`, so `readLines` stays wired), and a gap opened then reads the new commit; (b) when the new diff arrives with the same fingerprint, hunk ranges and `leftLineCount` (the fingerprint keys changed lines only), `_DiffBodyState` keeps its open gaps with the old commit's lines — e.g. after a rebase onto a parent that edited an unchanged line in place.

**Approach:** The view model records the commit and whitespace mode the shown diff was read at and reads gaps at those. The diff view gets that revision as a value; when it changes while the fingerprint and ranges stay, every open gap reads its lines again and stays as far open as it was.

## Boundaries & Constraints

**Always:**
- `InspectorViewModel` keeps `focusedRevision` (`({String commitId, DiffWhitespace whitespace})?`), set with `_focusedDiff` in `_loadFocus`, cleared in `_clearDiff`; `diffLines` reads at it (no read without it).
- `InspectorDiffView` gains an optional `linesRevision` (`Object?`), passed to `_DiffBody`. The inspector passes `model.focusedRevision`. The Undo Timeline's operation view passes nothing: it nulls its diff on every selection or mode switch, so its body unmounts and the gaps reset.
- In `_DiffBodyState.didUpdateWidget`: a new fingerprint, `leftLineCount` or hunk range still clears the gaps (unchanged). Otherwise a new `linesRevision` bumps `_generation` (reads in flight are dropped) and re-reads each open gap over its range (its end is its last line's left number); meanwhile its old lines show and its controls are inert (`_reading`). The new lines keep `down` / `up`; a refusal or an empty gap closes it.
- Tests: a real view-model widget test in `graph_inspector_test.dart` (a rewrite with the same file diff: a gap opened while the new diff loads reads the shown commit; after it arrives the gap shows the new commit's lines, still open whole) and one for the refusal (the gap closes).

**Never:**
- Closing the gaps on every rewrite (an @ snapshot of another file would close them), dimming the diff during an op reload, a backend change, a change to the operation view's reads.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Gap opened during reload | same key rewritten (`c…` → `d…`), the new focus read held | the gap reads `c…` (the shown diff's commit) | — |
| New diff, same changes | the held read completes, same fingerprint and ranges | the open gap reads `d…` and shows its lines, as far open as before | — |
| Re-read refused | `diffLines` throws `ZanshinFfiException` | the gap closes ("N unchanged lines" again) | logged by the view model |
| Same commit, new op | the change was not rewritten | no re-read | — |
| Changed file | new fingerprint or ranges | gaps cleared as before | — |

</intent-contract>

## Code Map

- `app/lib/src/features/graph/graph_inspector.dart` -- fields `:119-128` (add `_focusedRevision`), getters `:176-188`, `diffLines` `:462-481` (read at `_focusedRevision`), `_loadFocus` `:485-523` (set it with `_focusedDiff`, `:504`), `_clearDiff` `:1035-1046`, `_fetch` `:1048-1092` (same key, new `_commitId`, keeps `_focusedDiff`), `InspectorDiffView` wiring `:3135-3176` (`readLines` `:3168`; add `linesRevision`).
- `app/lib/src/features/graph/inspector_diff.dart` -- `InspectorDiffView` ctor/fields `:1013-1110` (`readLines` doc `:1071-1073`), `_DiffBody(` `:1179-1193` (key `(path, whitespace)`), `_DiffBody` `:1440-1470`, `_DiffBodyState` gap state `:1496-1500`, `didUpdateWidget` `:1505-1527`, `_expand` `:1531-1562` (reuse its read/refusal pattern).
- `app/lib/src/features/undo_timeline/operation_changes.dart` -- `_read` `:502-531` and `focus` `:534-570` null `_focusedDiff` synchronously (read-only evidence: no change there).
- `crates/zanshin-jj/src/hunks.rs:133-141` -- the fingerprint covers changed lines only (read-only evidence).
- `app/test/features/graph/graph_inspector_test.dart` -- `_layout` `:54-80` (`commitIds` `:64`, add a commit-id prefix), `setUp` `:499-519` (`respond` `:501`), `reload` `:576-580`, fake `diffLines` `:299-313` (add a refusal), `holdDiff` / `heldDiffs` `:144-146`, `gappedParts` `:4076-4097`, `showAll` `:4099-4105`, gap tests `:4107-4159`.

## Tasks & Acceptance

**Execution:**
- `app/lib/src/features/graph/graph_inspector.dart` -- add `_focusedRevision` + `focusedRevision`, set/clear it, read gaps at it, pass `linesRevision: model.focusedRevision` -- half (a).
- `app/lib/src/features/graph/inspector_diff.dart` -- `linesRevision` on `InspectorDiffView` / `_DiffBody`; re-read open gaps on a new revision in `didUpdateWidget` -- half (b).
- `app/test/features/graph/graph_inspector_test.dart` -- a `commit` prefix for `_layout` (reset in `setUp`), `refuseLines` on the fake; the two tests from the I/O matrix -- reproduce both halves, pin the fix.

**Acceptance Criteria:**
- Given the inspector shows `p.txt` of the selected change and an operation rewrites that change with the same changes to `p.txt`, when a gap opens before the new diff arrives, then it reads the commit on screen; when the new diff arrives, then an open gap shows the new commit's lines and stays as far open.
- Given a re-read is refused, then that gap closes and the others stay.

## Spec Change Log

## Review Triage Log

### 2026-11-15 — Review pass
- verdicts: 20 findings — high 0, medium 0, low 13, false 5, maybe-false 2
- findings:
  - `[low]` `[patch]` (blind) `focusedRevision`'s doc says "null whenever focusedDiff is", but `_keepPrevious` and `_fetch`'s focus-moved branch keep it — no read uses it there (`readLines` is null while a previous diff shows; no body without a diff); clearing it in `_keepPrevious` would hand the dimmed previous diff a null `linesRevision` and close its gaps. Doc reworded: the revision of the last focused read, kept while a previous diff shows.
  - `[low]` `[reject]` (blind) a gap clicked during the reload is dropped when the new diff arrives — its read is at the old revision, so its lines would be stale; dropping it is correct, the click is lost only when the read is still in flight as the new diff lands (tens of ms); re-issuing needs a new branch.
  - `[low]` `[reject]` (blind) the AC "the others stay" has no test with two gaps and one refusal — each `_reread` touches only its own key (`inspector_diff.dart` `_reread`); a per-range refusal in the fake adds test machinery for a structural fact.
  - `[low]` `[reject]` (blind) keeping a partly open extent is tested only for a whole-open gap — `_reread` copies `open.down` / `open.up` unchanged; nothing to branch on.
  - `[false]` `[reject]` (blind) the whitespace half of the revision is never tested — the existing "after Ignore all whitespace a gap reads at -w" test reads through `revision.whitespace`; a mode switch goes through `_keepPrevious`, so no read can see a mode other than the shown one.
  - `[low]` `[patch]` (blind) `inspector_diff_test.dart` has no test for `linesRevision` (stale re-read, inert controls) — grouped with the verification-gap row below; test added.
  - `[low]` `[patch]` (blind) the rewrite test checks only `lineReads.last` — now asserts the whole list (one `c…` read, one `d…` read).
  - `[low]` `[reject]` (blind) the `_commit` prefix also rewrites immutable commits — the tests select `_mutable` only; the other ids change nothing they assert.
  - `[low]` `[reject]` (blind) the record type is written out three times — a mismatch is a compile error at the assignments; a typedef adds a public name for one file.
  - `[false]` `[reject]` (blind) the deferred-work entry is not closed and names a selection switch — the ledger entry is marked resolved at finalize; a selection switch runs `_clearDiff` (`graph_inspector.dart` `_graphChanged`, `key != _key`), so the diff goes null and the body unmounts with its gaps: only a rewrite of the same change reaches the bug (Design Notes).
  - `[low]` `[reject]` (edge) a first-open read in flight is dropped when the revision changes — same as the blind row above.
  - `[maybe-false]` `[reject]` (edge) a first read with fewer lines than the gap, or a last line without a left number, makes the re-read shorter or close — `diff_lines` returns context lines with both numbers over the whole range; a short read would already render short (rows filter by left number). Low if true.
  - `[low]` `[patch]` (edge) the `focusedRevision` doc claim — same as the first row.
  - `[low]` `[patch]` (verification-gap) a re-read still in flight is untested: the inert controls and the stale-generation guard — test added in `inspector_diff_test.dart` (held re-read, a tap reads nothing, a new fingerprint before it lands keeps the gap closed).
  - `[low]` `[patch]` (verification-gap, other) the `focusedRevision` doc claim — same as the first row.
  - `[low]` `[reject]` (intent) the fix re-reads instead of the ledger's reset — the item asks for a fix, the reset was offered as one option; a reset would close open gaps on every @ snapshot of another file (Design Notes).
  - `[false]` `[reject]` (intent) the tests model a rewrite, not the item's selection switch — a selection switch clears the diff and unmounts the body (`_graphChanged` → `_clearDiff`); the rewrite is the reachable form of the bug.
  - `[false]` `[reject]` (intent) the whitespace half is untested — same as the blind row.
  - `[maybe-false]` `[reject]` (intent) verified only with a fake `GraphDetails`, not a real repo — a real rebase fixture would show the same view-model path; the widget test fails without either half (checked). Low if true.
  - `[false]` `[reject]` (intent) Auto Run Result, verification notes and ledger mirroring are missing — written at finalize.

## Design Notes

- **Why (a) is real:** `_fetch` (`graph_inspector.dart:1065`) sets `_commitId` and calls `_loadFocus` without `_keepPrevious`, so the old diff shows undimmed with `readLines` wired until the new read arrives.
- **Why (b) is real:** `didUpdateWidget` resets on fingerprint, `leftLineCount` and hunk ranges only; the fingerprint keys changed lines (`hunks.rs:133-141`). A rebase onto a parent that changed an unchanged line in place keeps all three.
- **A selection switch is safe already:** `_graphChanged` runs `_clearDiff` when the key changes, so the diff goes null and the body unmounts with its gaps. The item's "commit switch" is reachable only as a rewrite of the selected change (same key, new commit id).
- **Why re-read, not reset:** every save in the working copy rewrites @; a reset would close the user's open gaps on @ whenever another file is saved.

## Verification

**Commands:**
- `cargo make test-app test/features/graph/graph_inspector_test.dart test/features/graph/inspector_diff_test.dart` -- expected: pass.
- `dart analyze --fatal-infos` in `app` -- expected: no issues.
- `dart format --set-exit-if-changed -o none` on the touched files -- expected: 0 changed.
- Not run (the loop's gate rule): `cargo make test` / `test-full` / `coverage`. No Rust, FFI or jj verb change -> no cargo checks, codegen or parity oracle.
- Operating rules: absolute paths, never a bare `cd`; `jj` only in temp directories this run creates; `git commit --no-gpg-sign`.

**Verification notes (2026-11-15, gate rule of the story loop: no full gate):**
- `cargo make test-app test/features/graph/graph_inspector_test.dart test/features/graph/inspector_diff_test.dart` -- 251 passed after implementation; 253 after the review patches (plus the "same commit" test).
- With `linesRevision: model.focusedRevision` removed, the rewrite test failed (`lineReads` ended with a `c…` read where a `d…` re-read was expected): the cached-lines half is real and caught.
- `dart analyze --fatal-infos` in `app` -- no issues (both times).
- `dart format --set-exit-if-changed -o none` on the four touched files -- 0 changed.
- Not run: `cargo make test` / `test-full` / `coverage` (the loop's gate rule); no Rust, FFI, schema or jj verb change, so no cargo checks, codegen or parity oracle; no Marionette check (no visual change).

## Auto Run Result

Status: done

**Items.**
1. **Fixed** (`4efc881ae6843e385d2c269c8328cff414352add`). Real, in the form of a rewrite of the selected change (an operation gives it a new commit id with the same changes to the shown file, e.g. a rebase onto a parent that edited an unchanged line): a gap opened while the new diff loaded read the new commit, and once it arrived the open gaps kept the old commit's lines. A selection switch was already safe (`_clearDiff` unmounts the diff). Gap reads now use the commit and whitespace mode the shown diff was read at; a new revision with the same fingerprint and ranges re-reads every open gap and keeps how far it is open (a reset would close the gaps on every @ snapshot of another file).

**Summary.** `InspectorViewModel.focusedRevision` records where the shown diff was read; `diffLines` reads there. `InspectorDiffView.linesRevision` carries it to the diff body, whose `_reread` re-reads open gaps on a new revision (old lines meanwhile, controls inert, refusal closes the gap, stale results dropped).

**Files changed.**
- `app/lib/src/features/graph/graph_inspector.dart` -- `focusedRevision`, gap reads at it, passed as `linesRevision`.
- `app/lib/src/features/graph/inspector_diff.dart` -- `linesRevision` on `InspectorDiffView` / `_DiffBody`; `_reread` in `didUpdateWidget`.
- `app/test/features/graph/graph_inspector_test.dart` -- commit-id prefix for `_layout`, `refuseLines`; tests: rewrite (shown commit, then re-read), refused re-read, same commit reads nothing.
- `app/test/features/graph/inspector_diff_test.dart` -- `gapView(linesRevision:)`; test for a re-read in flight (inert controls, stale result dropped).

**Review findings.** 20 findings (high 0, medium 0, low 13, false 5, maybe-false 2). Patched 3 entries, all low: the `focusedRevision` doc (kept while a previous diff shows, on purpose), a test for an in-flight re-read, the rewrite test's full `lineReads` check. Deferred 0. Rejected 12 (reasons in the triage log): a first-open read in flight dropped on a revision change (its lines would be stale; tens-of-ms window), per-gap refusal and partial-extent tests (structural pass-through), immutable ids in the test prefix, a typedef, re-read vs reset (intended, Design Notes), selection-switch scenario (already safe), and false claims on whitespace coverage and process outputs.

**Follow-up review recommendation: false** -- this pass patched only low entries (3 low, 0 medium, 0 high).

**Verification.** All targeted checks pass (notes above). Not run: the full gate and coverage (the loop's gate rule).

**Residual risks.** A gap clicked while the new diff lands may stay closed (click again); during a re-read the old lines show briefly; no real-repo or running-app check.

**Commits.** `4efc881ae6843e385d2c269c8328cff414352add` (code and tests), then the planning commit (this spec, `deferred-work.md`).
