---
title: 'Story 10.41 — The ignoring diff shows exactly `jj diff -w`: rows from the ignoring read, whitespace-only lines from the backend, gap rows with Show / Hide'
type: 'bugfix'
created: '2026-11-15'
status: 'blocked'
baseline_revision: '4420e6b9700e17dabc3988ee4a6b122a098bf924'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/.claude/skills/design-artifacts/SKILL.md'
warnings: ['oversized']
deferred: []
---

<intent-contract>

## Intent

**Problem:** While whitespace is ignored, Story 10.33 shows the EXACT read's lines and dims, folds or swaps them by line numbers from the `-b` / `-w` read (`IgnoredLines`, `whitespaceRows`). The two reads can align differently: in `text_field.dart` (a `TextField` wrapped in `Semantics(`) the exact diff anchors on the identical `      ),` (old 25 = new 35), so the fields read as added above and removed below, while `jj diff -w` aligns every field as re-indented. The merge shows neither diff.

**Approach:** While ignoring, every hunk's rows are the ignoring read's lines, exactly as `jj diff -w` / `-b` prints them (color-words, effective context, its marks). The backend adds to each ignoring read's file every line that changed only in whitespace (also outside the context), with jj's word segments. Hidden whitespace-only lines become gap rows with Show / Hide. Picks stay on the exact parts. Built after the approved `design/Whitespace Study.html` as changed by Ralph twice on 2026-11-15 (Design Notes). DS synced through #26.

## Boundaries & Constraints

**Always:**
- **Backend (Rust stays the only place that compares lines).** `zanshin_jj::FileDiff` gains `whitespace_lines: Vec<HunkLine>`: at `-w` / `-b`, every line pair the ignoring line diff matches whose bytes differ, in file order, kind `Context`, both numbers, segments = jj-lib's word diff of that one pair (`Equal` runs, `Added` / `Removed` whitespace) — the CLI's marks for an in-context line. Empty at `Exact`, in summary mode, for binary sides and under `diff.color-words.conflict = "pair"` on a conflicted side. Also on `RevisionDiff::description`. Wire: `FileDiff.whitespace_lines: [HunkLine]` appended to `schemas/envelope.fbs`, always written; `cargo make codegen`; `docs/ffi-abi.md`; `zanshin_core` `FileDiff.whitespaceLines` (default `const []`).
- **Blocks.** While ignoring (`ignoring` FileDiff passed), each exact hunk is one block: its header keeps the exact range (`hunkHeader`) and symbol; its `+N −M` count the ignoring rows' distinct right / left numbers on changed lines (design: `@@ −73,34 +77,37 @@ … +4 −1`). An ignoring line and a whitespace line belong to the last exact hunk starting at or before it (by left number, else right; before the first → the first). A block with no line and no whitespace line goes; no block left → the note "Only whitespace changed in this file.".
- **Rows of a block** (a pure, tested function): the block's ignoring lines in order — whitespace-only lines inside the context are among them, always shown with their marks, no row or button of their own. The block's other whitespace lines (none of its ignoring lines has the same left and right number) are hidden; each run of hidden lines that sits between two shown rows (or before the first / after the last) is one **gap row** at its place. A run splits where a whitespace-only part's lines start or end.
- **Gap row** (design `.wss-gap`, `--fl-hover` band, `⋯` in both number columns, text `--text-faint` 11.5 px sans, a pill button `isd-wstag`): closed "N more lines with only whitespace changes" + **Show**; open, it stays in place ABOVE its revealed lines, "N lines with only whitespace changes" + **Hide**. Revealed lines show at their place with both numbers and their marks. Open gaps are session state keyed by the run's first left number, reset with the file and the mode (as 10.33's opened parts). ICU plurals.
- **Whitespace-only part** (an exact section that no ignoring changed line maps to, but whitespace lines do — design footnote): its hidden run is a gap row carrying the part's checkbox in the gutter, hatched, closed text 10.33's "⋯ N lines changed whitespace only · Show" (`inspectorFoldText`, the text is the Show button); open, the same open row as any gap (with Hide), still hatched with the checkbox.
- **Picks** stay on jj's exact parts (`jj split` has no `-w`). A row's part: a changed line by its left number, else its right (10.38's `hunkPartOf`); a whitespace line by either, the first section in order that holds one (so all 27 `text_field.dart` lines map to the first section). The block offers the parts its rows touch (ignoring changed lines + whitespace lines): its header checkbox is three-state over them (the view passes `onHunkToggled` / `hunkPicked` a copy of the exact hunk whose `sections` are those parts), "N parts" and the gutter as 10.38 when more than one; a part's checkbox on its first shown row. Any picked exact section of the block (or the file whole) opens all its gaps, without a Hide button (a pick never takes a line you did not see). The per-line "whitespace only" pill of 10.33 goes.
- **Side by side:** the same rows; a whitespace-only line is a pair (`pairSideBySide` context cells) with its marks; gap rows full width, led by the gutter when the block shows parts.
- **Marks, no dimming:** every shown whitespace-only line carries jj's segments (added indentation in `--add-word-bg`, removed in `--rem-word-bg`, Story 10.32) in the default view too; no text is dimmed anywhere.
- Zs controls only, DS tokens; strings through the ARB (`flutter gen-l10n` committed); tests never touch Ralph's settings or jj config. Exact (Show all whitespace) view unchanged. DS via `design-artifacts` C/E (no publish): `DiffHunk` gap row (closed / open) and marked whitespace line, `_ds_bundle.js` blocks, readme change log, a dated "2026-11-15 (Story 10.41)" line in `design/DESIGN-SYSTEM-SYNC.md`. The study files (`Whitespace Study.html`, `whitespace-study.jsx/.css`) are not touched.

**Never:**
- A header pill or hunk-level Show / Hide (Ralph's second change); dimmed text; lines of the exact read mixed into the rows; a whitespace-only line count computed by comparing texts in Dart.
- `-w` for Split, single-line picks, refusing picks while ignoring; a change to the exact view.
- Publishing the DS artifact or syncing a canvas (A, B); the Marionette check (the console session's).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| text_field, -w | scratchpad `ws2` old.dart → new.dart, context 3 | one block, header exact range, +4 −1; rows = the ignoring read's lines (old 6–8 / new 8–10 and old 30–32 / new 32–34 marked), one gap row "21 more lines with only whitespace changes · Show" between; nothing removed below `buildCounter`; one checkbox | — |
| Show / Hide | Show on that gap | row "21 lines with only whitespace changes · Hide" above old 9–29 / new 11–31, marked; Hide closes | — |
| Backend count | same texts at -w and -b | `whitespace_lines` = 27 pairs, first (6, 8) segments `      ` eq / `  ` added / rest eq, last (32, 34) | Exact → empty |
| Mixed part | a part with a real change + re-indented lines far from it | rows = ignoring lines; hidden re-indents in a gap row; header +/− of the ignoring rows | — |
| Whitespace-only part | `a b` → `a  b` far from any change | hatched fold row with checkbox "⋯ 1 line changed whitespace only · Show"; pick → open, commit holds its lines (real repo) | — |
| Pick opens | text_field, hunk checkbox ticked | gaps open, no Hide; the pick is the first section only; Split takes it whole | — |
| Side by side | text_field after Show | ws lines as pairs, right cell marks the two spaces | — |
| No sections | op view, ws-only file | gap rows with Show / Hide, no checkboxes | — |
| Exact mode | whitespace Show all | rows as before (`ignoring` null) | — |
| Ignoring read refused | second read throws | the diff's refusal (unchanged) | — |

</intent-contract>

## Code Map

- `crates/zanshin-jj/src/hunks.rs` -- `FileDiff` `:107-142` (add the field + doc), `DiffReader::file` `:646-706` and `description` `:621-644` (fill it), `resolved_hunks` `:1008-1043` / `diff_lines` `:1111-1183` / `segments` `:1335` (reuse for one pair: a scratch `Walk` with `max_inline_alternation: None`, `context: true`), `diff_by_line` + `DiffHunkKind::Matching` as in `fingerprint` `:754-782`, `line_compare_mode` `:1357`. Inline tests `mod tests` `:1369+` (`diff`, `options` helpers `:1460-1495`): add the text_field texts and assert the list.
- `crates/zanshin-jj/tests/it/api_stability.rs:1840`, `tests/it/diff.rs:187,801` -- `FileDiff` literals gain the field.
- `crates/zanshin-ffi/src/diff.rs:179-201` -- `file_offset` writes `whitespace_lines` (reuse `line_offset` `:224`); test literals `:386,434,449,521,525` and the round-trip assertions `:680-700` (assert the new vector).
- `schemas/envelope.fbs:3242-3272` -- append `whitespace_lines: [HunkLine];` to `FileDiff` with its doc. `cargo make codegen` regenerates `crates/zanshin-ffi/src/envelope_generated.rs` and the Dart `packages/zanshin_core/lib/src/ffi/generated/…`.
- `docs/ffi-abi.md:2495-2545` -- the Diff section: a bullet for `whitespace_lines`.
- `packages/zanshin_core/lib/src/ffi/diff.dart:166-224, 352-363` -- `FileDiff.whitespaceLines` + decode via `_line`. Tests: `packages/zanshin_core/test/ffi/diff_test.dart` (decode), `test/worker/diff_test.dart:159` (real read at -w lists the pairs).
- `app/lib/src/features/graph/inspector_diff.dart` -- replace `IgnoredLines` `:448-483`, `DiffFoldRow`, `whitespaceRows` `:485-561` with the block builder and row builder (`DiffLineRow`, a gap row type with lines / part / open); `hunkPartOf` `:421` (factor a numbers-only variant for whitespace lines); `InspectorDiffView.ignored` `:697,720` → `FileDiff? ignoring`; `_DiffBody` `:1101-1293` (blocks, `_opened` → open gap keys, derived hunk for checkbox, `_digits` over shown lines); `InspectorDiffHunk` `:1315-1891` (`_unified`, `_sideBySide`: gap rows, fold hatch, no `_dimmed`/`_tag`; counts from the block).
- `app/lib/src/features/graph/graph_inspector.dart:124-198, 474-510, 3171-3175` -- `_focusedIgnored` / `_previousIgnored` become the ignoring `FileDiff?` (an absent file → an empty one with the path), pane passes `ignoring:`.
- `app/lib/src/features/undo_timeline/operation_changes.dart:155, 206, 493` + its view -- the same.
- `app/lib/l10n/app_en.arb:832-880` -- add gap closed / open texts (ICU), Show / Hide labels and tooltips; drop `inspectorWhitespaceOnly`, `inspectorWhitespaceOnlyTooltip`, `inspectorWhitespaceOnlyHide`, `inspectorWhitespaceHideTooltip` if unused; keep `inspectorFoldText`, `inspectorFoldShowTooltip`, `inspectorFoldPick`, `inspectorDiffOnlyWhitespace`.
- `app/widgetbook/folders/graph.dart:1961-2040` -- the Whitespace ignored use case on `FileDiff` + `whitespaceLines` (the text_field case).
- Tests: `app/test/features/graph/inspector_diff_test.dart:930-1160` (row builder per matrix row, widget Show/Hide, side by side, pick opens, one checkbox), `graph_inspector_test.dart:1931` (prev ignoring kept), `graph_ports_test.dart:546-560` + real-repo whitespace tests (text_field fixture under -w; folded part pick commits), `app/test/features/undo_timeline/operation_changes_test.dart:382-400`.
- DS: `_bmad-output/implementation-artifacts/design_system/components/content/DiffHunk.{jsx,d.ts,prompt.md}`, `content.css`, `content.card.html`, `_ds_bundle.js` (+ `sourceHashes` line), `readme.md`; `design/DESIGN-SYSTEM-SYNC.md` (dated line under the last entry). Reference look: `design/whitespace-study.css` (`.wss-gap`, `.wss-gaptxt`, `.wss-gapbtn`, `.wss-wsmark`).

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/src/hunks.rs` (+ literals in tests) -- `whitespace_lines` and its unit tests (text_field at -w and -b, Exact empty, a pair at a skipped range, conflict pair empty) -- the backend half of item 7.
- `schemas/envelope.fbs`, `crates/zanshin-ffi/src/diff.rs` (+ tests), `cargo make codegen`, `docs/ffi-abi.md` -- the wire.
- `packages/zanshin_core/lib/src/ffi/diff.dart` (+ tests) -- the Dart field.
- `app/lib/src/features/graph/inspector_diff.dart` -- blocks, rows, gap rows, picks, both layouts.
- `app/lib/src/features/graph/graph_inspector.dart`, `app/lib/src/features/undo_timeline/operation_changes.dart` -- pass the ignoring file.
- `app/lib/l10n/app_en.arb` (+ `flutter gen-l10n`) -- the strings.
- `app/widgetbook/folders/graph.dart` -- the use case.
- Tests listed in the Code Map, one per matrix row.
- DS through `design-artifacts` C / E.

**Acceptance Criteria:**
- Given the text_field fixture in a real repo read at `-w`, when the inspector shows it, then the block's line rows equal the ignoring read's lines in order, one gap row says 21, the header shows `+4 −1`, and no removed row has a left number above 25.
- Given that view, when the user taps Show, then the gap row reads "21 lines with only whitespace changes" with Hide and old 9–29 / new 11–31 follow it with both numbers; Hide restores the first state.
- Given that view with picks, when the user ticks the hunk checkbox, then exactly one section is picked and the gaps open without Hide.
- Given a whitespace-only part in a real repo at `-w`, when the user ticks its fold row and commits, then the commit holds its lines.
- Given the operation view at `-w`, when a file shows, then its rows come from the ignoring read with gap rows.

## Spec Change Log

## Review Triage Log

### 2026-11-15 — Review pass
- verdicts: 29 findings — high 3, medium 0, low 25, false 1, maybe-false 0
- attempted change saved at `spec-10-41-attempt-1.patch` (this folder; `git apply` re-applies it on `4420e6b9`), code reverted.
- findings:
  - `[high]` `[intent_gap]` (blind) Ticking text_field's one box commits a broken file: whitespace pairs (old 26–32, new 28–34) have their left side in exact section 2 (old 26–32 removed) and their right side in section 1; `partAt` maps them to section 1 only, so the block offers only section 1 and the commit keeps old 26–32 next to the re-indented copies (`onChanged` … `buildCounter` twice, unbalanced `),`). Confirmed in the real-repo test: `block.hunk.sections == [exact.sections.first]` while the exact file has more sections; the test checks only `containsAll` on added lines. The rule and the matrix row "the pick is the first section only" are inside the intent-contract.
  - `[low]` `[patch]` (blind) With `max-inline-alternation = 0` (or a context block over the limit) the CLI path writes in-context whitespace pairs as left-only and right-only lines; `diffBlockRows` dedupes by `(left, right)`, so such a pair also lands in a gap — fix: dedupe by left number or right number. Moot under the intent gap; carry into the resumed run.
  - `[low]` `[patch]` (blind) Docs say the per-pair marks are "the CLI's marks for an in-context line"; the CLI diffs a context run as one block under the alternation limit, so they can differ — fix: reword the docs (`hunks.rs`, `envelope.fbs`, `ffi-abi.md`, `diff.dart`). Moot; carry.
  - `[low]` `[patch]` (blind) `DiffBlock.hunk.lines` keeps the exact lines while the rows are the ignoring read's: `diffNewLineOf` and the side-by-side `source` lookup resolve a removed ignoring row against an exact line — fix: the block hunk's `lines` = the block's ignoring lines. Moot; carry.
  - `[low]` `[patch]` (blind) Planning text still names the dropped header pill: the new `epic-10-context.md` bullet (fixed in this run), Story 10.41 in `epics.md` and its `sprint-status.yaml` entry (left for the resumed run / console session).
  - `[low]` `[reject]` (blind) No test for the automation_overview_page.dart witness — the file is Ralph's and not in the repo; the synthetic "mixed part" test covers its shape (a real change plus re-indents far from it).
  - `[low]` `[patch]` (blind) Summary mode clears `whitespace_lines` on files only, not on the description block, against the docs — fix: clear the description's too. Moot; carry.
  - `[low]` `[reject]` (blind) A second `diff_by_line` per file at `-w` / `-b` — only the focused file is read at the mode (the summary stays exact), so one extra line diff of one file; not worth a shared pass.
  - `[low]` `[reject]` (blind) Open gaps survive a context-lines change (key = first left number) — worst case a gap closes, or one starting at the same line stays open; harmless.
  - `[low]` `[patch]` (blind) The gap button's VoiceOver name is only "Show" / "Hide" — fix: ICU labels with the count ("Show 21 lines with only whitespace changes"). Moot; carry.
  - `[low]` `[patch]` (blind) `hunkLineParts` lost its last production caller (`whitespaceRows`) — fix: delete it and move its tests to `exactRows`. Moot; carry.
  - `[low]` `[reject]` (blind) Untested: a final-newline-only change at `-w`, a removed/added half of one ignoring change landing in different blocks at an exact-hunk boundary, CRLF at `-b` — each needs an unusual edit; exact hunks are more than 2 × context apart, so a split pair is not reachable in practice.
  - `[low]` `[reject]` (edge) Two ignoring hunks inside one exact hunk with no whitespace line between get no "..." row — an exact hunk holds at most 2 × context unchanged lines in a row, so an ignoring skip inside it always holds whitespace-only lines and gets a gap row.
  - `[low]` `[intent_gap]` (edge) A gap run joins hidden lines across identical lines (a blank line inside a re-indented block): after Show the numbers jump and the blank line is missing, so the code reads as changed. Whether Show also reveals the identical lines between (the backend listing them) is a Show-semantics choice the intent-contract does not settle — question 2.
  - `[low]` `[reject]` (edge) Open gaps keyed by the first left number go stale on a reload — grouped with the blind row above.
  - `[false]` `[reject]` (edge) An ignoring changed line in no exact section (new 35 `),`) has no checkbox and the hunk pick skips it — the exact read has that line unchanged, so no pick needs it; the commit is the same.
  - `[low]` `[patch]` (edge) Summary mode keeps the description's `whitespace_lines` — grouped with the blind row above. Moot; carry.
  - `[low]` `[reject]` (edge, claim) "Exactly as jj prints them" vs no "..." between ignoring hunks in one block — grouped with the edge row above.
  - `[low]` `[patch]` (verification) `diffBlocks` places an added-only line by its right number and a header by the line before; no test has exact hunks whose old and new starts differ — add one. Moot; carry.
  - `[low]` `[patch]` (verification) Side by side, a shown whitespace line's part comes from `partByLeft` / `partByRight`; no ignoring-mode side-by-side test with two parts — add one. Moot; carry.
  - `[high]` `[intent_gap]` (verification, other) Picking the text_field hunk commits duplicate lines — grouped with the first blind row.
  - `[low]` `[reject]` (intent) "Rows equal jj diff -w" is checked against Zanshin's own read, not the stock CLI — the color-words read is jj's walk (Story 5.10) and the fixture was cross-checked against `jj diff -w` by hand; no jj verb changed, so no oracle run.
  - `[high]` `[intent_gap]` (intent) Split takes only section 1 for text_field, and the test checks too loosely — grouped with the first blind row.
  - `[low]` `[reject]` (intent) No separator for an ignoring skip inside one block — grouped with the edge row above.
  - `[low]` `[intent_gap]` (intent) Show leaves holes where identical lines sit between whitespace lines — grouped with the edge row above (question 2).
  - `[low]` `[reject]` (intent) The automation_overview_page.dart witness is synthetic — grouped with the blind row above.
  - `[low]` `[reject]` (intent) The real-repo tests commit instead of splitting — `GraphCommit` and Split both build the tree through `select_tree` from the same `HunkChoice`.
  - `[low]` `[defer]` (intent) No Marionette check against the study — the intent gives it to the console session; moot under the intent gap (nothing deferred this pass).
  - `[low]` `[patch]` (intent) `epic-10-context.md` names the dropped header pill — grouped with the blind planning row; fixed in this run.

## Design Notes

- **Ralph's design changes of 2026-11-15** (after the epic text, in `whitespace-study.jsx/.css`, they win over items 2–4): (1) every shown whitespace-only line carries jj's marks always, in the default `-w` view too, and no text is dimmed; (2) the gap row that stands for hidden whitespace-only lines reads "N more lines with only whitespace changes"; (3) no pill in the hunk header — Show / Hide sit on the gap row, which stays above its lines when open and then reads "N lines with only whitespace changes"; whitespace-only lines inside the context have no row or button, they are always shown.
- **Why exact hunks frame the blocks:** `jj diff -w` splits `text_field.dart` into two hunks ("..." between); the design shows one hunk with the exact range and a gap row for that skip, and a pick needs the exact part's hunk. So the block is the exact hunk; its rows are only the ignoring read's lines; the gap rows stand where jj prints "...". A skip that holds no whitespace-only line gets no row (rare: inside one exact hunk a skip of more than 2 × context lines is almost always re-indentation).
- **Part of a whitespace line by either number, first section first:** in `text_field.dart` the second exact section (old 26–32 removed) holds only lines the ignoring read pairs with new 28–34, which lie in the first section — so one checkbox, as the witness asks; the second section stays reachable through a whole-file pick.
- **Backend per pair:** the CLI never prints skipped lines, so their marks come from the same word diff the CLI runs for an in-context pair, one pair at a time, always inlined.

## Verification

**Commands:**
- `cargo test -p zanshin-jj --lib hunks::`, `cargo test -p zanshin-jj --test it hunks:: diff:: api_stability::` -- pass.
- `cargo test -p zanshin-ffi` (diff tests) -- pass.
- `cargo clippy -p zanshin-jj -p zanshin-ffi --all-targets -- -D warnings`, `cargo fmt --all --check` -- clean.
- `cargo make codegen` -- generated files committed.
- `flutter test` in `packages/zanshin_core` (diff tests) -- pass.
- `cargo make test-app test/features/graph test/features/undo_timeline test/widgetbook test/l10n test/architecture` -- pass.
- `dart analyze app packages/zanshin_core`, `dart format --set-exit-if-changed -o none` on touched dirs -- clean.
- `node --check design_system/_ds_bundle.js` -- passes.
- Not run (the loop's gate rule): `cargo make test` / `test-full` / `coverage`. No jj verb changes → no parity oracle.

**Manual checks:**
- Marionette against `design/Whitespace Study.html`: left to the console session.

**Verification notes (2026-11-15, gate rule of the story loop: no full gate), run on the attempt before it was reverted:**
- `cargo test -p zanshin-jj --lib hunks::` -- 19 passed.
- `cargo test -p zanshin-jj --test it -- hunks:: diff:: api_stability::` -- 103 passed.
- `cargo test -p zanshin-ffi` -- 240 + 406 passed.
- `cargo clippy -p zanshin-jj -p zanshin-ffi --all-targets -- -D warnings` -- clean; `cargo fmt --all --check` -- clean; `cargo check --workspace --all-targets` -- clean.
- `cargo make codegen` -- idempotent (no further change).
- `dart test test/ffi/diff_test.dart test/worker/diff_test.dart` in `packages/zanshin_core` with the gate's environment -- 22 passed; `dart analyze --fatal-infos --fatal-warnings` and `dart format --set-exit-if-changed` there -- clean.
- `cargo make test-app test/features/graph test/features/undo_timeline test/widgetbook test/l10n test/architecture` -- 1568 passed.
- `dart analyze --fatal-infos` in `app` -- no issues; `dart format --set-exit-if-changed` on `app/lib`, `test`, `widgetbook`, `integration_test` -- 0 changed.
- `node --check design_system/_ds_bundle.js` -- passes.
- Not run: `cargo make test` / `test-full` / `coverage` (the loop's gate rule); the parity oracle (no jj verb changed).

## Auto Run Result

Status: blocked
Blocking condition: intent gap — the review found that the intent-contract's pick rule commits a broken file in Ralph's own text_field.dart case.

**What was built (saved, reverted).** The whole story as specified, in `spec-10-41-attempt-1.patch` (this folder; `git apply _bmad-output/implementation-artifacts/spec-10-41-attempt-1.patch` re-applies it on `4420e6b9`): backend `FileDiff.whitespace_lines` (Rust, FlatBuffers, `docs/ffi-abi.md`, `zanshin_core`), the block and row builders with gap rows (Show / Hide on the row, no header pill, no dimming — Ralph's two design changes of 2026-11-15), fold rows for whitespace-only parts, picks on the exact parts, both layouts, the operation view, strings, the widgetbook case, the DS `DiffHunk` gap row, and tests. All targeted checks passed (Verification notes).

**Unanswered questions (for Ralph):**
1. **Coupled sections in text_field.dart.** jj's builtin diff editor cuts the exact change into two sections: section 1 = old 5–24 removed / new 5–34 added, section 2 = old 26–32 removed (the old `onChanged` … `buildCounter`). Under `-w` those seven lines are the left halves of re-indented pairs whose right halves (new 28–34) lie in section 1. The spec's rule ("a whitespace line's part by either number, the first section first"; matrix: "the pick is the first section only") offers only section 1, so the one checkbox commits the file with those seven fields twice and an unbalanced `),` — and reads fully checked. Options:
   - (a) **Tie** the sections a whitespace pair spans into one pickable part: one box picks sections 1 and 2 together, so Split takes the whole change and the commit is valid. Recommended: it keeps "one box" and "a pick never takes a line you did not see".
   - (b) Offer every section a pair touches as its own part: two boxes, section 2 needs its own row (it has none under `-w`), and picking section 1 alone still breaks the file.
   - (c) Keep first-section-only (the attempt): one box, broken commit possible.
2. **What Show reveals.** Show brings back only lines that changed in whitespace; identical lines between them (a blank line inside a re-indented block) stay hidden, so after Show the numbers jump and the block reads as if blank lines were deleted. Options: (a) the backend also lists the identical lines between two whitespace pairs of one matched run, Show reveals them as plain context and the count stays the whitespace-only lines (recommended); (b) keep it as is.

**On resume (with the answers):** re-apply the patch, change the pick rule (and the matrix row) per question 1 and Show per question 2, then also apply the patch-level rows of the triage log (dedupe split context lines by either number; block hunk `lines` = its ignoring lines; reword the per-pair marks docs; clear the description's `whitespace_lines` in summary mode; count-bearing VoiceOver names on Show / Hide; drop `hunkLineParts`; tests for differing old/new hunk starts and a two-part side-by-side ignoring case; tighten the text_field commit test to the whole committed file), and update Story 10.41 in `epics.md` / its `sprint-status.yaml` entry for the design changes.

**Review findings.** 29 findings: 3 high (one root cause: coupled sections, intent gap), 25 low (1 more intent gap — Show semantics; 11 patch-level rows moot under the intent gap and carried; 12 rejected with reasons), 1 false. Nothing deferred (the deferred list stays empty; nothing mirrored to deferred-work.md).

**Follow-up review recommendation: false** (blocked before patching; nothing patched this pass).

**Commits.** The spec, the saved patch and the epic 10 context are committed; no code is committed.

**Residual risks.** The attempt was never checked visually (Marionette is the console session's); the DS card was not opened in a browser.
