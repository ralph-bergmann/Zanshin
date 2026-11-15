---
title: 'Story 10.41 closing run — an exact section that no row touches joins the hunk pick'
type: 'bugfix'
created: '2026-11-15'
status: 'done'
baseline_revision: 'fd7ccc9ef971b8d0631e7490cbdeaf9ed3976bec'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
warnings: []
deferred:
  - summary: >-
      A move whose halves lie in two different exact hunks may leave one hunk's block with no row at all, so that block is dropped and a pick of the other hunk commits half the move.
    evidence: |-
      Unverified (maybe-false). diffBlocks drops a block with no ignoring line and no listed line, and the new merge works per block only. For the block to be dropped, every line in that hunk's range must stay matched under -w while the alignment crosses the exact context between the hunks; the crossed context lines usually turn into -w changed lines that land in the first block (which then merges its sections). A real-repo fixture where `diffBlocks` returns fewer blocks than the exact hunks while the -w read still differs would settle it.
    location: >-
      app/lib/src/features/graph/inspector_diff.dart diffBlocks (the `lines[b].isEmpty && spaces[b].isEmpty` skip)
    severity: high (unverified)
---

<intent-contract>

## Intent

**Problem:** While whitespace is ignored, `diffBlocks` builds a block's parts only from the exact sections that its ignoring changed lines and listed whitespace lines touch. Item 1 of Story 10.41's deferred list asked whether a section can be touched by no row. It can (verified in a real repo, see Design Notes): the `-w` read may match an exact section's lines byte for byte with lines elsewhere, outside any whitespace pair, so that section gets no row. The hunk checkbox then reads "all" while a commit skips the section, and the committed file holds a line twice.

**Approach:** When a block has an exact section that no row touches, all its exact sections form ONE part. So the hunk pick (and that part) always holds every exact section of the hunk, and a pick never commits half of a move the `-w` view shows as unchanged.

## Boundaries & Constraints

**Always:**
- Only `diffBlocks` in `app/lib/src/features/graph/inspector_diff.dart` changes (plus its doc comments on `DiffBlock.parts` / `DiffBlock.hunk`). A block whose sections are all touched keeps its parts exactly as Story 10.41 builds them (tied groups).
- The rule also covers a block that touches no section at all (only changed lines outside every section): its one part is all its exact sections.
- `foldParts` keeps its rule (a part with no section an ignoring changed line touches).
- A `shortcut:` code comment names the limit: finer picks in such a block need the exact view; tying each untouched section to the section of its `-w` partner would keep them.
- Tests: a real-repo test with the verified fixture (pick the block's sections, commit, the committed file equals the new text) and a pure `diffBlocks` test.

**Never:**
- A backend change (`whitespace_lines` stays as it is); joining an untouched section to the "nearest" part (it can still split a move across two parts and break a commit); a change to the exact view.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Untouched section (real repo, -w) | old `lll ppp q1 q2 q3`, new `ppp lll ␣␣q1 ␣␣q2 ␣␣q3` | exact: one hunk, 2 sections (A: old 1 removed; B: old 3–5 → new 2–5); block parts `[[A, B]]`, `hunk.sections == [A, B]`; committing them gives the new text | — |
| All sections touched | text_field fixture, -w | unchanged: one part of both sections | — |
| No section touched | a block whose ignoring changed lines lie in no section and no listed line | one part holding every exact section | — |
| Exact mode | whitespace Show all | unchanged (`diffBlocks` not used) | — |

</intent-contract>

## Code Map

- `app/lib/src/features/graph/inspector_diff.dart:519-617` -- `diffBlocks`: `touched` (`:564`), the union-find `tie` / `root` (`:562-572`), `groups` (`:573-579`). Add the rule after the listed-lines loop. Doc comments: `DiffBlock.parts` `:493-496`, `DiffBlock.hunk` `:481-483`, `diffBlocks` `:515-518`.
- `app/test/features/graph/graph_ports_test.dart:585-823` -- real-repo whitespace tests; reuse `rewriteRepo` `:586`, `shown` `:601`, the text_field commit pattern `:695-709`.
- `app/test/features/graph/inspector_diff_test.dart` -- pure `diffBlocks` tests (find the existing ones by `diffBlocks(`); add one for the untouched section.
- Fixture (verified with stock `jj 0.47.1` in a temp repo): old `lll\nppp\nq1\nq2\nq3\n`, new `ppp\nlll\n  q1\n  q2\n  q3\n`. Exact anchors on `ppp`; `-w` anchors on `lll` (old 1 = new 2, byte-identical, first line of its matched run, so not listed) and reads `ppp` as moved.

## Tasks & Acceptance

**Execution:**
- `app/lib/src/features/graph/inspector_diff.dart` -- in `diffBlocks`, when `touched` misses any of the block's exact sections, tie all sections into one part and mark all touched; update the three doc comments -- the fix.
- `app/test/features/graph/graph_ports_test.dart` -- real-repo test with the fixture at -w: `exact.sections` has 2 entries, `block.parts == [exact.sections]`, `block.hunk.sections == exact.sections`, committing `block.hunk.sections` yields exactly the new text -- proves the bug is real and fixed.
- `app/test/features/graph/inspector_diff_test.dart` -- pure `diffBlocks` test: a hunk with two sections, ignoring lines touching only the second -> one part with both; and one with no touched section -> one part with both -- pins the rule without a repo.

**Acceptance Criteria:**
- Given the fixture in a real repo read at `-w`, when the inspector builds its blocks, then the block's one part and its hunk hold both exact sections, and a commit of that pick holds the new file whole (`lll` once).
- Given a block whose sections are all touched (text_field), when the blocks are built, then its parts are as before.

## Spec Change Log

## Review Triage Log

### 2026-11-15 — Review pass
- verdicts: 16 findings — high 0, medium 0, low 9, false 4, maybe-false 3
- findings:
  - `[maybe-false]` `[defer]` (blind) A move split across two exact hunks may drop one hunk's block entirely, so picking the other commits half the move — needs every line in the dropped hunk's range to stay matched while the -w alignment crosses the context between the hunks; a fixture where `diffBlocks` returns fewer blocks than exact hunks would settle it. High if true; deferred (unverified).
  - `[low]` `[patch]` (blind) The `foldParts` doc ("listed lines do") is wrong for a merged part — grouped with the edge rows: a merged block now has no fold part, so the doc holds unchanged.
  - `[low]` `[patch]` (blind) The no-section-touched test pinned an odd state (a block with a changed row whose only part is a fold) — grouped with the edge rows; the test now expects `foldParts` empty.
  - `[low]` `[reject]` (blind) The merged pick commits an untouched section that has no row — the commit's effect is what the -w rows show (in the fixture, `ppp` moved); the exact lines are one switch away in the exact view; the pick never reads "all" while skipping a section any more.
  - `[low]` `[reject]` (blind) The merge removes the hatched fold row and its own checkbox for whitespace-only parts in such a block — the coarser picks are the named shortcut (finer picks in the exact view); rare block shape.
  - `[false]` `[reject]` (blind) No test for the merge meeting existing ties; order may break — after the loop every section has one root and `groups` is filled in ascending section order, so there is one part in section order whatever the earlier ties.
  - `[low]` `[patch]` (blind) The comment says "-w read" and its `shortcut:` line has no upgrade point — reworded to "ignoring read" / "its partner in the ignoring read"; ends "Upgrade when part picks in such blocks matter."
  - `[false]` `[reject]` (blind) The real-repo test commits `hunk.sections`, not `parts[0]` — the test asserts `block.parts == [exact.sections]` and `block.hunk.sections == exact.sections`, so both paths commit the same list.
  - `[low]` `[patch]` (edge) A merged part with no section an ignoring changed line touches landed in `foldParts`, so its gap row read "lines changed whitespace only" while its pick commits a moved line (the fixture itself: `+ppp` / `-ppp` lie in no section) — `foldParts` now requires `!merged`; the real-repo test asserts `foldParts` empty.
  - `[low]` `[patch]` (edge) The fold text of such a part reads "whitespace only" while it carries moved lines — same root cause and fix as the row above.
  - `[low]` `[reject]` (intent) One untouched section collapses every part of its block into one, beyond "the nearest part" — the nearest part can still split a move across two parts and break a commit (Design Notes); the item's goal, a truthful hunk pick, holds; finer picks stay in the exact view.
  - `[maybe-false]` `[reject]` (intent) The no-section-touched case has only a synthetic test — it is the same branch as the real-repo case (`touched.length < all.length`); whether a real read reaches it is open, but the rule is right either way. Low if true.
  - `[low]` `[reject]` (intent) Gap rows of a merged block change grouping (no fold part) — grouped with the blind fold-row reject above; intended by the patch.
  - `[maybe-false]` `[reject]` (intent) No widget test ticks the hunk checkbox on a merged block — the verification-gap layer traced `toggleHunk` / `hunkState` (`graph_inspector.dart:670-707`) using `hunk.sections` as-is, which the tests pin. Low if true.
  - `[false]` `[reject]` (intent) The spec has no Auto Run Result yet and the ledger entry is unchanged — written at finalize, the ledger entry is marked resolved in the same commit.
  - `[false]` `[reject]` (intent) Scope reaches beyond the item — the code change stays inside `diffBlocks` and its doc comments.

## Design Notes

- **Why the case is real:** a section is untouched only when every one of its lines is, under `-w`, matched byte for byte and unlisted, so the `-w` read aligns them differently from the exact read (a move the exact diff anchors across). The fixture shows it: exact keeps `ppp` and makes section A (remove `lll` at the top) and section B (re-indent `q`, add `lll`); `-w` keeps `lll` and the re-indented `q`s and reads `ppp` as moved. `-ppp` (old 2) and `+ppp` (new 1) lie in no exact section, the `q` pairs touch only B. Picking B alone commits `lll ppp lll ␣␣q1…`.
- **Why one part, not the nearest:** the untouched section's partner can sit in any section of the hunk; only the partner's section keeps the commit whole. One part is always whole; tying to the `-w` partner would need the `-w` old-to-new number map in Dart (shortcut comment).

## Verification

**Commands:**
- `cargo make test-app test/features/graph/inspector_diff_test.dart test/features/graph/graph_ports_test.dart` -- pass.
- `dart analyze --fatal-infos` in `app` -- no issues.
- `dart format --set-exit-if-changed -o none` on the touched files -- 0 changed.
- Not run (the loop's gate rule): `cargo make test` / `test-full` / `coverage`. No Rust, FFI or jj verb changes -> no cargo checks, codegen or parity oracle.
- Operating rules: absolute paths, never a bare `cd`; `jj` only in temp directories this run creates; `git commit --no-gpg-sign`.

**Verification notes (2026-11-15, gate rule of the story loop: no full gate):**
- Fixture found with stock `jj 0.47.1` in a scratchpad temp repo (`jj diff --git` vs `jj diff --git -w`): exact keeps `ppp`, `-w` keeps `lll`.
- With the rule switched off, all three new tests failed (real repo: sections `-0,1 +0,0` and `-2,3 +1,4`, the block's only part the second) — the bug is real.
- `cargo make test-app test/features/graph/inspector_diff_test.dart test/features/graph/graph_ports_test.dart` -- 119 passed (before and after the review patches).
- `dart analyze --fatal-infos` in `app` -- no issues (both times).
- `dart format --set-exit-if-changed -o none` on the three touched files -- 0 changed (both times).
- Not run: `cargo make test` / `test-full` / `coverage` (the loop's gate rule); no Rust, FFI, schema or jj verb change, so no cargo checks, codegen or parity oracle; Marionette (no visual change beyond which parts a block offers).

## Auto Run Result

Status: done

**Items.**
1. **Fixed** (`e4c02980a01d2b6a560ff14606edad40a90b3056`). Real: a real-repo fixture (old `lll ppp q1 q2 q3`, new `ppp lll ␣␣q1 ␣␣q2 ␣␣q3`) gives an exact hunk of two sections where no `-w` row touches the first, so the hunk pick skipped it and a commit kept `lll` twice. Now a block with an untouched section picks all its exact sections as one part (never a fold part); the commit equals the new file. Not "the nearest part": that can still split a move across two parts.

**Summary.** `diffBlocks` ties every exact section of a block into one part when any section is touched by no row, and gives such a block no fold part. Blocks whose sections are all touched keep Story 10.41's tied parts.

**Files changed.**
- `app/lib/src/features/graph/inspector_diff.dart` -- the merge rule in `diffBlocks` (with a `shortcut:` comment), `foldParts` only for unmerged blocks, doc comments on `DiffBlock.hunk`, `DiffBlock.parts`, `diffBlocks`.
- `app/test/features/graph/graph_ports_test.dart` -- real-repo test: the fixture at `-w`, one part of both sections, no fold part, the commit equals the new text.
- `app/test/features/graph/inspector_diff_test.dart` -- two pure `diffBlocks` tests (one section untouched; no section touched).

**Review findings.** 16 findings (high 0, medium 0, low 9, false 4, maybe-false 3). Patched 5 low rows (one root cause: a merged part counted as a fold part, plus the comment wording). Deferred 1 (maybe-false, high if true): a move split across two exact hunks may drop one hunk's block — mirrored into `deferred-work.md`. Rejected 10, each with its reason in the triage log (the coarser picks are the named shortcut; false claims on ordering, test paths and scope; process rows done at finalize).

**Follow-up review recommendation: false** -- this pass patched only low entries (5 low, 0 medium, 0 high).

**Verification.** All targeted checks pass (notes above). Not run: the full gate and coverage (the loop's gate rule).

**Residual risks.** The deferred cross-hunk case; in a block with an untouched section the user loses per-part picks under `-w` (exact view keeps them); no visual check in the running app.

**Commits.** `e4c02980a01d2b6a560ff14606edad40a90b3056` (code and tests), then the planning commit (this spec, `deferred-work.md`, `epic-10-context.md`).
