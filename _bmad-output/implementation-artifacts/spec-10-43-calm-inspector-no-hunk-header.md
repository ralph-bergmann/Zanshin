---
title: 'Story 10.43 — Calm inspector, part 2: no hunk header, one checkbox per part, context opens in the gaps'
type: 'feature'
created: '2026-11-15'
status: 'done'
baseline_revision: '3ced4808dc576278da3918182c8567b70a406d7d'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/.claude/skills/design-artifacts/SKILL.md'
warnings: ['oversized']
deferred:
  - summary: >-
      A gap read uses the view model's current commit and whitespace mode, not those of the diff on screen, so a
      commit switch that keeps the same file, the same fingerprint and the same hunk ranges could open lines of the
      other commit in a gap.
    evidence: |-
      InspectorViewModel.diffLines (app/lib/src/features/graph/graph_inspector.dart:464) reads `_commitId` and
      `_whitespace` at call time; `previousDiff` withholds `readLines` only on a file switch. Settle by selecting two
      commits with identical changes to one file but different unchanged lines and opening a gap after the switch.
    location: >-
      app/lib/src/features/graph/graph_inspector.dart:464
    severity: medium (unverified)
---

<intent-contract>

## Intent

**Problem:** The inspector's code pane repeats itself: every hunk has a header row (`@@ −a,b +c,d @@`, symbol, "N parts" pill, ± counts, a hunk box) on top of the part boxes, and the hidden unchanged lines between hunks cannot be opened at all.

**Approach:** Build sections 1 and 2 (code pane) of the approved `design/Calm Inspector Study.html` (`calm-study.jsx:252-388`, `calm-study.css:41-65`): drop the hunk header, put one box per pickable part on its first changed row, draw the pick bar while a part's box is hovered, and turn every hidden unchanged run into a quiet gap row whose controls (↑ / ↓ 20, ↕ N, Show all) open lines that Rust reads on demand. 10.41's whitespace gap row takes the same shape. DS synced through #26 (plus the Calm Inspector Study).

## Boundaries & Constraints

**Always:**
- **No hunk header** (both layouts, inspector and operation view): no row with the range, `Hunk.symbol`, the parts pill, ± counts or the hunk box; its accent band goes. `DiffPin` pins only the gutter + number columns (and the gap rows' gutter + arrow columns in unified). Hunks follow each other with today's 1 px `flBorder` between them; where a gap row sits, the gap row is the separator.
- **One box per part.** Every pickable part — an exact section, or a tied / merged part of a `DiffBlock` (10.41) — gets its box on its first shown row, also when a hunk has one part (drop the `_partCount > 1` rule). The box takes every section of its part (today's `_togglePart`), so Ralph's boxed `-w` hunk has one box that equals the old header box. A whitespace-only part's box stays on its fold row (that row is its first row). The **mode box** (executable-bit pick) stays — it picks the mode change, not a hunk. Boxes stay inside `InspectorCheck` (10.42 reveal). Labels: `inspectorPartPick` / `inspectorPartUnpick` as today.
- **Pick bar on hover.** While the pointer is on a part's box, every row of that part — its fold / whitespace gap row and the revealed whitespace lines included — draws the picked bar (2 px `accentLine` on the row's left edge, on the pinned gutter group as today). Picked and hovered look the same; leaving the box removes the hover bar.
- **Unchanged gap rows.** Walk the rows the code pane builds for the file in order (exact hunks; while whitespace is ignored, each block's rows plus its hidden listed lines); every run of left line numbers that no row holds is one gap: before the first row (top), between two rows that are not left-adjacent (between hunks or blocks, and inside a block), and after the last row up to the file's last left line (bottom, from the new `FileDiff.leftLineCount`). Rows without a left number (added lines) are skipped in the walk; a pure-addition hunk anchors at `Hunk.before.start`. Files with no left side (added) or no hunks get no gap rows. Each gap row: "N unchanged lines" (ICU plural) always; while the code pane is revealed (`InspectorCheckReveal`) its controls show — N ≤ 20: one ↕ `ZI.updown` "Show N lines" opening all; N > 20: ↓ `ZI.chevronDown` "Show 20 lines below" (not on the top gap), ↑ `ZI.chevronUp` "Show 20 lines above" (not on the bottom gap), "Show all". ↓ opens the gap's first 20 lines (below the row above), ↑ its last 20 (above the row below). The count then shrinks; a fully opened gap's row disappears and the lines join. Revealed lines are plain context rows (both numbers, no part, no box).
- **Read on open.** The first control used on a gap reads that gap's whole left range once through a new Rust read (below) and caches it; nothing is read with the diff. While the read runs, the row stays and its controls are inert; a failed read leaves the gap closed and logs nothing user-visible beyond today's error handling for diff reads (no toast).
- **Gap state** (opened lines and cache) lives per gap in `_DiffBodyState`, for the session; it resets with the file, the whitespace mode, and a new diff for the same file (its `fingerprint` changes).
- **Whitespace gap row (10.41)** — plain and fold — takes the gap row's shape (26 px band, empty gutter except a fold's part box, empty arrow columns, text, then the button); its Show / Hide shows only while the code pane is revealed. Texts stay `inspectorGapClosed` / `inspectorGapOpen` / `inspectorFoldText` (fold keeps its hatch).
- **Rust read.** zanshin-jj: `FileDiff` gains `left_line_count: u32` (lines of the left side, `split_inclusive('\n')` like `whitespace_lines`; 0 when binary / absent). A new read returns the lines a `jj diff` with the same revision form (`DiffRevisions`, all four), whitespace mode and path would print as context (both numbers, segments as the diff gives them), whose left number − 1 lies in a 0-based half-open left range — e.g. by reusing `hunks::diff` for that one path with unlimited context and keeping its `Context` lines in range; a rename reads the left side at its source as the diff does. FFI: append-only schema (new `RequestKind`, request table, `Payload` member, `FileDiff.left_line_count`), extern `zanshin_diff_lines`, `cargo make codegen` outputs committed, `docs/ffi-abi.md` (symbol index + counts 115 → 116, payload / extern sections, `FileDiff` field). zanshin_core: `zanshinDiffLines` + decode, `FileDiff.leftLineCount`, worker `DiffLinesCommand`, `RepoHandle.diffLines(...)` (mirroring `RepoHandle.diff`'s parameters plus `start`/`end`), exported.
- **App ports.** `GraphDetails.diffLines(commitId, path, whitespace, start, end)` (inspector reads `-r commitId` as its `diff` does) and `OperationChangesSource.diffLines(...)` with the same revision form the operation view's `_diffOf` chose for that file; `InspectorDiffView` gains an optional `Future<List<HunkLine>> Function(int start, int end)? readLines` — without it, gap rows show their count but no controls.
- **Operation view** (`operation_changes.dart`): no header, gap rows, the whitespace row shape, both layouts; no boxes (as today). Its gap controls show while the pointer / focus is in its diff (wrap each embedded file diff in `InspectorCheckReveal`).
- **Side by side:** no header; the part box in the leading 22 px gutter (today's `lead()`); gap rows span both sides with the arrows over the left cell's numbers.
- Strings via `app_en.arb` + `flutter gen-l10n` (output committed); drop `inspectorHunkCheck`, `inspectorHunkParts` and `hunkHeader()` once unused. Zs controls and DS tokens only; tests never touch Ralph's settings or jj config; `jj` only in temp dirs the tests create.
- **DS** via `design-artifacts` C / E, no publish: `DiffHunk.{jsx,d.ts,prompt.md}` (no header / `range` / hunk box / grip; part box in the gutter; hover bar; gap row with ↑ / ↓ / ↕ / Show all and the whitespace row shape), `content.css` (header rules `.zs-hunk-hd`, `.zs-hunk-range`, `.zs-hunk-ctx`, `.zs-hunk-stat`, `.zs-hunk-grip`, `.zs-hunk-parts`, `.is-sel/.is-some .zs-hunk-hd` gone; gap row as `calm-study.css` `.cs-gap`), `content.card.html`, `DiffView.{d.ts,prompt.md}` where they cite the header, `_ds_bundle.js` blocks + `sourceHashes`, readme Sync line, kit `ui_kits/desktop/inspector.jsx` if it draws the header; one dated line `- 2026-11-15 (Story 10.43) — …` appended at the end of `design/DESIGN-SYSTEM-SYNC.md`. Do not touch the study files.

**Never:**
- Changing which lines form a part; the symbol in the gap row; changing the file options menu (Whitespace, Context lines stay).
- Reading unchanged lines with every diff, or comparing lines in Dart (Rust stays the only place that compares lines).
- Publishing the DS, syncing a canvas, the Marionette check (the console session's).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Two hunks, exact | file 120 lines; hunks cover left 1–8 and 16–24 | no `@@` row; gap "7 unchanged lines" between, bottom gap "96 unchanged lines"; no top gap | — |
| Two parts in one hunk | hunk with sections at lines 1 and 6 | a box on line 1's row and on line 6's row; no other box | — |
| ↓ on 31 | gap of 31, ↓ | 20 lines below the upper hunk, row says "11 unchanged lines" with one ↕ | read fails: gap stays closed |
| ↕ / Show all | gap ≤ 20 ↕, gap > 20 Show all | gap row gone, lines joined | — |
| Top / bottom | top gap 40, bottom gap 40 | top: ↑ + Show all; bottom: ↓ + Show all | — |
| Reset | open gaps, switch file or whitespace mode, or the diff reloads changed | every gap closed again | — |
| Pointer outside code pane | — | gap counts show, arrows / Show all / ws Show-Hide hidden; inside → shown | — |
| `-w` tied part | exact hunk old 32–63 / new 46–91 whose runs whitespace lines tie | one box on its first changed row; hovering draws the bar to its last row, across the ws gap row; checking picks the same sections the old header box picked (Split commits the same file) | — |
| Rust read | `-r`, from/to, interdiff, created; rename; `-w`; range past EOF | context lines with both numbers in range; renamed file read at source; range clipped to the file | unknown revision → today's diff error |
| Operation view | file diff | no header, gap rows, no boxes | — |

</intent-contract>

## Code Map

- `crates/zanshin-jj/src/hunks.rs` -- `FileDiff` `:107` (+ `left_line_count`), `DiffRevisions` `:175`, `DiffOptions`, `hunks::diff` `:362` (tree / copy match `:417-468`), `DiffReader::{new,files,file}` `:582-671`, `diff_content` `:743`, `whitespace_lines` `:817` (line counting), `hunks_of` `:925`. New range read beside `diff`.
- `crates/zanshin-jj/src/repo.rs:4491` -- `Repo::diff` via `with_verb(cli_command::DIFF, …)`; add `Repo::diff_lines` the same way. Re-exports `lib.rs:119`.
- `crates/zanshin-ffi/src/diff.rs` -- `read_diff_request` `:44`, `zanshin_diff` `:139-150`, `diff_to_envelope` `:157`, `line_offset` `:227` (reuse for the lines payload). `schemas/envelope.fbs`: `RequestKind` `:162` (comment count `:153`), `DiffRequest` `:388`, `HunkLine` `:3212`, `FileDiff` `:3271`, `Payload` `:3302` — append only.
- `docs/ffi-abi.md` -- counts `:40`, `:342`, `:606`; symbol index `:604`/`:681`; `Diff` payload `:2474`; `zanshin_diff` `:2573`.
- `crates/zanshin-ffi/tests/it/{diff_ffi.rs,ffi_abi_doc_sync.rs}` (`EXPECTED_EXPORTS` `:37` → 116); `crates/zanshin-jj/tests/it/{diff.rs,api_stability.rs:1818-1901}`.
- `packages/zanshin_core/lib/src/ffi/diff.dart` -- `zanshinDiff` `:295`, decode `:339-342`, `FileDiff` `:167`, `HunkLine`; worker `handle.dart:1660` (`RepoHandle.diff`), `isolate.dart:1807` + `:4667`, `commands.dart:2320` (`DiffCommand`); export `lib/zanshin_core.dart:35`. Tests `test/worker/diff_test.dart` (real cdylib — one per extern fn for the ratchet), `test/ffi/diff_test.dart`.
- `app/lib/src/features/graph/graph_ports.dart` -- `GraphDetails` `:1036`, `RepoGraphDetails` `:1064`. Fakes: `test/features/graph/graph_inspector_test.dart:83`, `test/features/graph/graph_card_menu_test.dart:203`, `integration_test/glass_profile.dart:244`, `widgetbook/folders/graph.dart:1053`.
- `app/lib/src/features/undo_timeline/operation_changes.dart` -- `OperationChangesSource` `:32`, `RepoOperationChangesSource` `:65`, `_diffOf` `:400`, `InspectorDiffView` uses `:840` (description, no `readLines`) and `:866`. Fakes: `test/helpers/fake_undo_timeline.dart:113`, `widgetbook/folders/undo_timeline.dart:149`.
- `app/lib/src/features/graph/graph_inspector.dart` -- `InspectorDiffView` wiring `:3138-3176` (pass `readLines`), `toggleHunk` `:684` (drop if unused), `_loadFocus` `:463-500`.
- `app/lib/src/features/graph/inspector_diff.dart` -- `hunkHeader` `:24`; `DiffRow` / `DiffLineRow` / `DiffGapRow` `:636-679`; `diffBlockRows` `:692`; `DiffPin` `:823`, `_Pinned` `:841`; `InspectorDiffView` `:881` (header pin `:1709-1716`, body key `:1053`); `_DiffBody` `:1313` (`_opened`/`_toggleGap` `:1366`, hunk list `:1398-1468`); `InspectorDiffHunk` `:1535` (`_parts` `:1645`, header `:1648-1735`, `_partBox` `:1742`, `_edged` `:1774`, `_foldBox` `:1810`, `_foldText` `:1829`, `_gapText` `:1863`, `_unified` `:1917` row pin `:1922-1978`, part placement `:2014-2038`, `_sideBySide` `:2050`, `lead()` `:2112`).
- `app/lib/src/features/graph/inspector_check_reveal.dart` -- add a public `InspectorCheckReveal.revealedOf(context)` (`scope?.revealed ?? true`, like `InspectorCheck`).
- `app/lib/l10n/app_en.arb` -- `:801`, `:806` go; new gap strings near `:872`.
- `app/widgetbook/folders/graph.dart` -- 'Inspector diff' `:282` use cases (`_HunkSelection` `:1787`, `_ThreeParts` `:1857`, `_WhitespaceIgnored` `:1938`, `_PinnedNumbers` `:2131`): demo `readLines`, gap rows shown via `InspectorChecksShown`.
- Tests: `app/test/features/graph/inspector_diff_test.dart` (header tests `:254`, `:573`, `:696`, `:852`, `:951`, `:958`, `:1119`, `:1519`, `:1599`, `:1632`, `:1708`, `:1739` → rewrite to the new look); `graph_inspector_test.dart` (10.42 hover test `:3087`/`:3116` hovers the header → hover a diff row; `:1509-1524`, `headerColor` `:2754`, `:4517`, parts group `:3433`); `test/features/undo_timeline/operation_changes_test.dart:388`.
- DS: `_bmad-output/implementation-artifacts/design_system/components/content/{DiffHunk.jsx,DiffHunk.d.ts,DiffHunk.prompt.md,DiffView.d.ts,DiffView.prompt.md,content.css,content.card.html}`, `_ds_bundle.js`, `readme.md`, `_adherence.oxlintrc.json`, `ui_kits/desktop/inspector.jsx`; `design/DESIGN-SYSTEM-SYNC.md` (append). Reference: `design/calm-study.css:41-65` (`.cs-gut`, `.cs-gap`, `.cs-gnums`, `.cs-gbtn`, `.cs-gall`, `.is-pick`, `.is-hot`), `calm-study.jsx:252-388`.

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/src/hunks.rs`, `repo.rs`, `lib.rs` -- `left_line_count` and the range read -- backend item 7.
- `schemas/envelope.fbs`, `crates/zanshin-ffi/src/diff.rs` (+ `cargo make codegen`, commit outputs), `docs/ffi-abi.md` -- the extern, payload and field.
- `crates/zanshin-jj/tests/it/diff.rs`, `api_stability.rs`, `crates/zanshin-ffi/tests/it/diff_ffi.rs`, `ffi_abi_doc_sync.rs` -- tests: the four revision forms, rename, `-w`, a range past EOF, line counts; the read's lines equal the context lines of a full-context `Repo::diff`.
- `packages/zanshin_core` -- adapter, model field, worker command, handle method, export; cdylib + decode tests.
- `app/lib/src/features/graph/graph_ports.dart`, `operation_changes.dart` + every fake -- `diffLines`.
- `app/lib/src/features/graph/inspector_check_reveal.dart` -- `revealedOf`.
- `app/lib/src/features/graph/inspector_diff.dart` -- header out, box per part, hover bar, gap rows (pure function computing gaps from rows + `leftLineCount` + open state, unit-tested), whitespace row shape, both layouts.
- `app/lib/src/features/graph/graph_inspector.dart` -- pass `readLines`; drop dead hunk-toggle wiring.
- `app/lib/l10n/app_en.arb` + `flutter gen-l10n`; `app/widgetbook/folders/graph.dart`.
- App tests per matrix row (rewrite the header tests; hover gestures with `PointerDeviceKind.mouse`).
- DS per Boundaries and the DESIGN-SYSTEM-SYNC line.

**Acceptance Criteria:**
- Given a mutable change whose file diff has hunks, when the inspector shows it in either layout, then no row shows `@@`, a symbol, a parts pill or ± counts, and each part has exactly one box on its first changed row.
- Given a gap row and the pointer in the code pane, when ↓, ↑, ↕ or Show all is clicked, then the lines come from one Rust read for that gap, show as context with both numbers, and the count matches the rows still hidden.
- Given the Undo Timeline's operation view, when a file diff shows, then it has no header, offers gap rows, and has no boxes.
- Given a part's box, when the pointer rests on it, then every row of that part shows the 2 px bar, and none does after the pointer leaves an unpicked part.

## Spec Change Log

## Review Triage Log

### 2026-11-15 — Review pass
- verdicts: 41 findings — high 0, medium 10, low 23, false 7, maybe-false 1
- findings:
  - `[medium]` `[patch]` (blind) opened gaps keep stale cached lines after a same-fingerprint reload (Context lines change, rebase): the fingerprint keeps shifted numbers, the top gap's key 0 always collides, so ↓/↑ shrink the count while `shown()` finds no lines — `didUpdateWidget` now also resets on a changed `leftLineCount` or hunk range.
  - `[low]` `[patch]` (blind) `_expand` catches only `ZanshinFfiException`; any other error leaves `gap.key` in `_reading` and the controls inert — `_reading` is cleared for every error.
  - `[low]` `[reject]` (blind) a refused read gives no feedback — the spec decides "a failed read leaves the gap closed (no toast)"; changing it edits the spec.
  - `[low]` `[reject]` (blind) a read in flight has no visible state — reads of one file are short; a busy look adds states for a sub-second wait.
  - `[low]` `[patch]` (blind) `_hot` is never reset; `MouseRegion.onExit` does not fire when the box unmounts, so a reload or picks going away leaves a hover bar — cleared with the gap reset and when `partPicked` becomes null.
  - `[low]` `[reject]` (blind) `DiffUnchangedRow` has no `owner`, so a part's bar breaks at an unchanged hole inside a block — needs a part spanning two ignoring hunks inside one exact hunk (the merged-move case); rare, and the fix adds owner tracking.
  - `[low]` `[patch]` (blind) `OperationChangesModel.diffLines` copies `_diffOf`'s revision-form choice by hand, its abandoned / created branches untested — same root as the verification-gap row below; tests added for both branches.
  - `[medium]` `[patch]` (blind) missing tests: ↑ tap, in-flight read dropped on a new fingerprint, retry after refusal, abandoned / created branches, refusal logging, non-FFI error — ↑, the `Completer` in-flight / retry cases and both branches added (logging is a `_log.warning` line, not asserted).
  - `[low]` `[patch]` (blind) DS hides gap controls with `visibility:hidden`, which drops them from Tab order, against DiffHunk.prompt.md and 10.42's opacity rule — switched to opacity.
  - `[low]` `[reject]` (blind) "N unchanged lines" and Show all scroll sideways out of view in unified — the epic pins "the number columns only"; the pinned arrows stay reachable.
  - `[low]` `[reject]` (blind) each gap's first read diffs the whole file with unlimited context — one read per opened gap, not per diff, as item 7 asks; a per-file cache is more code for a rare cost.
  - `[low]` `[reject]` (blind) `DiffLines` decode drops the call's warnings — the same warnings come with the file's own diff read, which shows them.
  - `[low]` `[reject]` (blind) orphans: `ZsColors.hunk/hunkBg`, `Hunk.symbol` over FFI, `DiffBlock` hunk counts — tokens belong to the DS layer, the symbol stays in the API (the epic's non-goal says it can come back); no user-facing harm.
  - `[low]` `[reject]` (blind) DS card's expand only lowers a number; the kit drops the hunk drag grip — the card is a static preview; the grip goes with the header by the intent (see residual risks for Story 10.27).
  - `[medium]` `[patch]` (edge) same-fingerprint reload with shifted gaps reuses stale `_gaps` — same root as the first blind row; fixed there.
  - `[medium]` `[patch]` (edge) a reused gap key whose cache does not cover the new range shrinks the count with no rows shown — same root; fixed there.
  - `[low]` `[patch]` (edge) a non-FFI throw leaves the gap inert and an unhandled async error — same root as the blind `_expand` row; fixed there.
  - `[low]` `[reject]` (edge) a read returning fewer lines than the gap (model returns `[]` with no commit) opens the gap empty — the model has a commit whenever a diff shows; a length guard guards undemonstrated state.
  - `[maybe-false]` `[defer]` (edge) the read uses the model's current commit / mode, not the shown diff's, mid-reload — `previousDiff` withholds `readLines` on a file switch; a commit switch with the same path and fingerprint would need a run to settle; if true, medium (wrong lines in a gap).
  - `[low]` `[patch]` (edge) `_hot` survives an unmounted box or a reload — same root as the blind `_hot` row; fixed there.
  - `[false]` `[reject]` (edge) the bottom gap of a last hunk with empty rows is marked `top` — every hunk or block has at least one row (`diffBlocks` drops empty blocks, `inspector_diff.dart:555`), so `rows.isEmpty` holds only for a one-hunk file without a top gap, where the bottom gap is indeed the first row.
  - `[low]` `[reject]` (edge) an empty `path` string diffs the whole repo, then returns nothing — no caller sends one; the fix is a new guard.
  - `[medium]` `[patch]` (edge) "the count matches the rows still hidden" fails after a same-fingerprint reload — same root as the first blind row; fixed there.
  - `[low]` `[patch]` (edge) the hover bar stays after the pointer leaves when the box unmounts — same root as the blind `_hot` row; fixed there.
  - `[false]` `[reject]` (edge) the hunk's symbol is no longer visible — the intent removes it (item 1, non-goal "the function/symbol context in the gap row (dropped)").
  - `[medium]` `[patch]` (verification-gap) the gap read's whitespace mode is never asserted in either view model — the fake records `whitespace`; both views assert `ignoreAllSpace` after switching.
  - `[medium]` `[patch]` (verification-gap) the abandoned and created branches of `OperationChangesModel.diffLines` are untested — both added.
  - `[low]` `[patch]` (verification-gap) gap controls while `previousDiff` shows are unchecked — test added: no controls, no reads.
  - `[medium]` `[patch]` (verification-gap) the in-flight guards in `_expand` are unverified — `Completer`-backed test added (one read for two taps, stale read dropped).
  - `[low]` `[patch]` (verification-gap) the number column's width from `leftLineCount` is not pinned — assertion added.
  - `[false]` `[reject]` (intent) the witnesses run on synthetic fixtures, not Ralph's file — the real-repo and Marionette checks are the console session's by the story's own witness list.
  - `[low]` `[reject]` (intent) "checking it equals the old header box" is tested at section level, not through Split — the box toggles the same `HunkKey` sections the header box did; the Split path is unchanged.
  - `[false]` `[reject]` (intent) reset on a file / mode switch is untested — a widget test switching path and whitespace was added during verification.
  - `[medium]` `[patch]` (intent) the whitespace gap row's on-demand Show / Hide is untested — test added (opacity 0 outside, 1 inside).
  - `[low]` `[reject]` (intent) hovering a box while its whitespace gap is open is untested — the opened lines take the same `partOf(listed: true)` path the closed-gap hover test covers.
  - `[false]` `[reject]` (intent) gap rows for holes inside a hunk or block go beyond "between hunks" — under `-w` such holes lie between the ignoring read's hunks, and the spec's row walk covers them by design.
  - `[medium]` `[patch]` (intent) the fold row's "· Show" always shows, against item 5 and the spec ("plain and fold … Show / Hide shows only while revealed") — the fold text loses "· Show" and gets the on-demand Show button.
  - `[false]` `[reject]` (intent) `left_line_count` is computed with every diff — the bottom gap's count needs it before any read; item 7 limits the lines, not the count.
  - `[low]` `[reject]` (intent) the number column now sizes for `leftLineCount` on every file — intended, so opened lines fit; a column a digit wider at most.
  - `[low]` `[patch]` (intent) gap expansion is tested in unified only — a side-by-side ↕ test added.
  - `[false]` `[reject]` (intent) the process rules (deferred mirror, verification notes) cannot be judged from the diff — the spec and deferred-work.md are committed with this run.

### 2026-11-15 — Review pass (follow-up)
- verdicts: 27 findings — high 0, medium 2, low 20, false 3, maybe-false 2
- findings:
  - `[low]` `[patch]` (blind) `left_line_count` counts the text's lines under `diff.color-words.conflict = "pair"` on a conflicted side, whose hunks number conflict-term lines, so the bottom gap's count is off — `hunks.rs` sets 0 when `paired` (as `whitespace_lines` already does); doc comment, schema, `docs/ffi-abi.md`, `zanshin_core` doc and codegen follow; `a_paired_conflict_lists_no_whitespace_lines` asserts 5 materialized, 0 paired.
  - `[low]` `[reject]` (blind) the description block shows "N unchanged lines" rows with no controls — the spec says "without `readLines`, gap rows show their count but no controls"; the count is accurate (now pinned by tests, see the verification-gap row).
  - `[low]` `[reject]` (blind) a non-FFI error in `_expand` still escapes `unawaited` as a zone error — the controls are freed (`finally`); the only such error is a closed handle, rare, and the zone handler logs it; a catch-all would hide programming errors.
  - `[false]` `[reject]` (blind) the operation view can fill an open gap with another commit's lines after a selection switch — `_read` sets `_files` and `_focusedDiff` to null synchronously (`operation_changes.dart:503-508`), so the old diff unmounts and `_expand`'s `!mounted` drops the read.
  - `[maybe-false]` `[defer]` (blind) carried — the inspector's gap read uses the current commit / mode, not the shown diff's; same claim and code as the first pass's deferred row; not deferred again.
  - `[low]` `[patch]` (blind) carried — `OperationChangesModel.diffLines` copies `_diffOf`'s revision-form choice by hand; the code reads as logged, both branches tested in the first pass; no new action.
  - `[low]` `[reject]` (blind) the hover bar follows the pointer only, not keyboard focus — the intent says "While the pointer is on a part's box".
  - `[low]` `[reject]` (blind) "Show all" has no count in its VoiceOver label and no tooltip — the row's "N unchanged lines" text sits beside it and is read first; a counted label needs a new plural string for a small gain.
  - `[low]` `[patch]` (blind) the DS prompt example's `parts={[null, 0]}` puts the checkbox on the context line 58 — `DiffHunk.prompt.md` now passes `parts={[null, null, 0]}` (the gap row, line 58, line 59).
  - `[low]` `[reject]` (blind) no Rust test for a last line without `\n`, an empty left side or summary mode in `left_line_count` — `line_count` is one `split_inclusive` count; summary mode is checked end to end by the `zanshin_core` worker test through the cdylib.
  - `[low]` `[patch]` (blind) `@inspectorFoldShowTooltip` still describes a folded row as a button; `inspectorFoldText` keeps its "⋯" — the ARB description now names the Show button (`flutter gen-l10n` rerun); the "⋯" stays, as the intent keeps `inspectorFoldText`'s text.
  - `[low]` `[patch]` (edge) paired conflicts: `left_line_count` against conflict-term numbers — same root as the first blind row; fixed there.
  - `[low]` `[reject]` (edge) carried — a read returning fewer lines than the gap opens it empty; same claim as the first pass's row for the no-commit case. The real short-read cause found in this pass is the whitespace-only row below.
  - `[low]` `[reject]` (edge) carried — the view models return `[]` with no commit / selection; same claim and code as the first pass's row.
  - `[low]` `[reject]` (edge) `_expand` lets a non-FFI error escape — same as the third blind row.
  - `[false]` `[reject]` (edge) carried — the bottom gap of a last hunk with no rows is marked `top`; refuted in the first pass (blocks never come empty).
  - `[medium]` `[patch]` (edge) the count is arithmetic, the rows are whatever the read returned — a short read shows fewer rows than the count opened; real for the whitespace-only case below (same root), fixed there.
  - `[low]` `[patch]` (verification-gap) the description block's `left_line_count` and its count-only gap rows are unpinned — `an_interdiff_shows_a_changed_description` asserts 1, `a_created_commit_…` asserts 0; `operation_changes_test.dart` pins "11 unchanged lines" in the description block, no controls, no read.
  - `[low]` `[patch]` (verification-gap) the `_hot` reset on a reload is untested — new `inspector_diff_test.dart` test hovers part 2, reloads with other parts and a new fingerprint, and asserts the new part 2 is not edged; it fails with the reset removed.
  - `[low]` `[reject]` (verification-gap) the description block's count-only rows need an intent decision — same as the second blind row.
  - `[low]` `[reject]` (intent) the app's whitespace Show / Hide keeps the 10.41 pill while the DS sync line calls it a flat button — "then the button" admits both; the console session's DS comparison settles the look.
  - `[low]` `[reject]` (intent) only the focused file diff gets the reveal wrapper; the description block has no controls — same as the second blind row.
  - `[low]` `[reject]` (intent) carried — the `-w` tied-part pick is tested at callback level, not through Split; same claim as the first pass's row.
  - `[medium]` `[patch]` (intent) a file whose only change is whitespace, at `-w`: the ignoring read has no hunk, so `jj diff -w` prints no context and `diff_lines` returns nothing; opening its gap removed the row and showed no lines — `_DiffBody.build` passes `leftLineCount: 0` when the ignoring read has no hunk (no gaps, as "no hunks get no gap rows"); Rust test `diff_lines_of_a_whitespace_only_change_at_w_are_empty` demonstrates the empty read, widget test asserts no gap at `-w` and the 7-line gap exact.
  - `[maybe-false]` `[defer]` (intent) carried — a commit switch that keeps the same file diff; same as the first pass's deferred row; not deferred again.
  - `[low]` `[reject]` (intent) a non-FFI read error escapes — same as the third blind row.
  - `[false]` `[reject]` (intent) extra changes (number width from `leftLineCount`, 4 px spacer, two DS files) — the width is the first pass's carried reject; the spacer keeps the scroll bar off the last row (its comment); the DS files follow the prop changes; no harm named.

## Design Notes

- Gaps from the row walk, not from hunk ranges: under `-w` the rows are the ignoring read's (10.41), so holes appear inside blocks too; one rule covers exact hunks, blocks and their insides. The read returns what `jj diff -w` with more context prints there, so the opened lines stay "exactly as the CLI prints them".
- Counts use left numbers: an unchanged run maps line for line; the read supplies both numbers, Dart only draws.
- The mode box stays: "no other box" in the epic replaces the hunk box with part boxes; dropping the mode pick would lose a change Split can take.

## Verification

**Commands:**
- `cargo test -p zanshin-jj --test it diff::` and `--test it api_stability::`, `cargo test -p zanshin-ffi --test it diff_ffi::` and `ffi_abi_doc_sync::` -- expected: pass.
- `cargo clippy -p zanshin-jj -p zanshin-ffi --all-targets -- -D warnings`, `cargo fmt --all --check` -- expected: clean.
- `cargo make codegen` then `git status` -- generated files committed, no drift.
- `flutter test` / `dart analyze` / `dart format --set-exit-if-changed` in `packages/zanshin_core` (worker + ffi diff tests) and `app/` (graph inspector, inspector diff, undo timeline, widgetbook, l10n tests) -- expected: pass / no issues / 0 changed.
- No full gate (`cargo make test` / `test-full` / `coverage`): the story loop runs it at its end.

**Manual checks (if no CLI):**
- Marionette against the study: the console session's.

**Verification notes (this run, 2026-11-15; gate rule: no full gate):**
- `cargo fmt --all --check` -- clean. `cargo clippy -p zanshin-jj -p zanshin-ffi --all-targets -- -D warnings` -- clean.
- `cargo test -p zanshin-jj --test it diff::` -- 51 passed; `--test it api_stability::` -- 40 passed; `cargo test -p zanshin-jj --lib -- repo::tests hunks::` -- 33 passed.
- `cargo test -p zanshin-ffi --test it -- diff_ffi:: ffi_abi_doc_sync::` -- 25 passed.
- `cargo make codegen` -- exit 0, no drift against the working tree (same 48 changed files before and after).
- `packages/zanshin_core`: `dart analyze` -- no issues; `dart format --set-exit-if-changed lib test` -- 0 changed; `flutter test test/ffi/diff_test.dart test/worker/diff_test.dart` -- 28 passed.
- `app/`: `dart analyze` -- no issues; `dart format --set-exit-if-changed lib test widgetbook integration_test` -- 0 changed; `flutter test test/features/graph test/features/undo_timeline test/widgetbook test/l10n` -- 1600 passed; the added reset test (file / whitespace switch) -- passed.
- After the review patches: `app/` `dart analyze` -- no issues; `dart format --set-exit-if-changed lib test widgetbook integration_test` -- 0 changed; `flutter test test/features/graph test/features/undo_timeline test/widgetbook test/l10n` -- 1612 passed; `node --check design_system/_ds_bundle.js` -- OK. The patches touched no Rust or `zanshin_core` code.
- Not run: the full gate and the coverage ratchet (the story loop runs them at its end); Marionette (console session); the parity oracle (no jj verb changed: the new read is `jj diff` with more context).

**Verification notes (follow-up review pass, 2026-11-15; gate rule: no full gate):**
- `cargo fmt --all --check` -- clean. `cargo clippy -p zanshin-jj -p zanshin-ffi --all-targets -- -D warnings` -- clean.
- `cargo test -p zanshin-jj --test it -- diff:: hunks:: api_stability::` -- 111 passed (the new `diff_lines_of_a_whitespace_only_change_at_w_are_empty` and the paired / description `left_line_count` assertions included).
- `cargo test -p zanshin-ffi --test it -- diff_ffi:: ffi_abi_doc_sync::` -- 25 passed.
- `cargo make codegen` -- exit 0; `envelope_generated.rs` and `envelope_zanshin.ffi_generated.dart` carry the schema comment change, committed.
- `packages/zanshin_core`: `dart analyze` -- no issues; `dart format --set-exit-if-changed lib test` -- 0 changed; `flutter test test/ffi/diff_test.dart test/worker/diff_test.dart` -- 28 passed.
- `app/`: `flutter gen-l10n` rerun; `dart analyze` -- no issues; `dart format --set-exit-if-changed lib test widgetbook integration_test` -- 0 changed; `flutter test test/features/graph test/features/undo_timeline test/widgetbook test/l10n` -- 1615 passed. The new hover-reload test fails with the `_hot` reset commented out (checked, then restored).
- Not run: the full gate, the coverage ratchet, Marionette, the parity oracle (no jj verb changed).

## Auto Run Result

**Status:** done (2026-11-15).

**Summary.** The inspector's code pane follows sections 1 and 2 of `design/Calm Inspector Study.html`: the hunk header is gone (range, symbol, parts pill, ± counts, hunk box); every pickable part, tied `-w` parts included, has one box on its first row; hovering a box draws the 2 px pick bar on every row of its part; each hidden run of unchanged lines is a quiet "N unchanged lines" row whose ↑ / ↓ 20, ↕ N and Show all open lines that one Rust read per gap returns (`Repo::diff_lines` → `zanshin_diff_lines` → `RepoHandle.diffLines`), with the bottom gap sized by the new `FileDiff.left_line_count`. The whitespace gap and fold rows take the same shape with on-demand Show / Hide. The Undo Timeline's operation view gets the same diff (no boxes). Both layouts.

**Files changed.**
- `crates/zanshin-jj/src/{hunks.rs,repo.rs,lib.rs}` -- `FileDiff.left_line_count`, `DiffLinesOptions`, `Repo::diff_lines` (unlimited-context diff of one path, context lines in a left range).
- `schemas/envelope.fbs`, `crates/zanshin-ffi/src/diff.rs`, generated `envelope_generated.rs` / `include/zanshin_ffi.h` -- `DiffLinesRequest`, `DiffLines` payload, `zanshin_diff_lines`, the new field.
- `docs/ffi-abi.md` -- the extern, payload and field; 116 symbols.
- `packages/zanshin_core/lib/src/{ffi/diff.dart,ffi/bindings.dart,ffi/envelope_zanshin.ffi_generated.dart,worker/*.dart}` -- `FileDiff.leftLineCount`, `zanshinDiffLines`, `DiffLinesCommand`, `RepoHandle.diffLines`.
- `app/lib/src/features/graph/inspector_diff.dart` -- header out, box per part, hover bar, `diffUnchangedRows` / `DiffUnchangedRow` / `DiffGapOpen`, gap reads and their reset, whitespace and fold rows in the gap shape.
- `app/lib/src/features/graph/{graph_inspector.dart,graph_ports.dart,inspector_check_reveal.dart}` -- `GraphDetails.diffLines`, `readLines` wiring, hunk-pick API removed, `InspectorCheckReveal.revealedOf`.
- `app/lib/src/features/undo_timeline/operation_changes.dart` -- `OperationChangesSource.diffLines`, gap reads in the view's revision form, reveal scope.
- `app/lib/l10n/app_en.arb` (+ generated) -- gap strings in, `inspectorHunkCheck` / `inspectorHunkParts` out, fold text without "· Show".
- `app/widgetbook/folders/{graph.dart,undo_timeline.dart}`, `app/integration_test/glass_profile.dart` -- demo / fake `diffLines`.
- Tests: zanshin-jj `tests/it/{diff.rs,api_stability.rs}`, zanshin-ffi `tests/it/{diff_ffi.rs,ffi_abi_doc_sync.rs}`, zanshin_core `test/{ffi,worker}/diff_test.dart`, app `inspector_diff_test.dart`, `graph_inspector_test.dart`, `graph_card_menu_test.dart`, `operation_changes_test.dart`, `helpers/fake_undo_timeline.dart`.
- DS (C / E, not published): `DiffHunk.{jsx,d.ts,prompt.md}`, `DiffView.prompt.md`, `content.css`, `content.card.html`, `guidelines/colors-accents.html`, `ui_kits/desktop/inspector.jsx`, `_ds_bundle.js` (+ hashes), `_adherence.oxlintrc.json`, `readme.md`; dated line in `design/DESIGN-SYSTEM-SYNC.md`.
- `sprint-status.yaml` (10.43 done), `deferred-work.md` (one entry).

**Review findings.** 41 findings (medium 10, low 23, false 7, maybe-false 1). Patched 20 rows in 12 entries: gap-cache reset on moved hunks or a new line count (with `_hot`), `_reading` cleared on every error, fold row with an on-demand Show, DS gap controls hidden by opacity, and tests for the read's whitespace mode in both views, the operation view's abandoned / created forms, no reads under a dimmed previous diff, in-flight / retry / ↑ cases, the three-digit number column, side-by-side expand and the whitespace row's on-demand Show. Deferred 1 (maybe-false, medium if true): a gap read after a commit switch that keeps the same file diff. Rejected 20: 7 false (intent removes the symbol; bottom gap never mis-marked since blocks never come empty; witnesses on fixtures by the story's own list; reset now tested; holes inside blocks are by design; `left_line_count` needed for the bottom gap; process rules met in this commit) and 13 low not worth the cost or settled by the spec (refusal toast, busy look, owner on unchanged holes, pinned gap text, per-file read cache, `DiffLines` warnings, orphan tokens / symbol, DS card preview, short read guard, empty-path guard, open-gap hover test, header-box-through-Split test, column width). Details in the Review Triage Log.

**Follow-up review recommendation:** true. Patched: 0 high, 6 medium entries, 6 low. Unverified risk: the patched gap-cache reset (`_DiffBodyState.didUpdateWidget`, by hunk ranges) and the reworked fold row (`_foldText` via `_gapText`) had no review pass after patching.

**Verification.** See Verification notes above: targeted Rust, codegen, `zanshin_core` and app checks all pass.

**Residual risks.**
- Marionette against the study and the DS publish wait for the console session; the full gate and coverage ratchet run at the end of the story loop (new Rust lines in `hunks.rs`, `repo.rs`, `diff.rs` are tested but not measured here).
- Each gap's first read diffs the whole file with unlimited context: fine for normal files, slower on very large ones.
- The DS kit lost the hunk header's drag grip; Story 10.27 (drag files and hunks onto a change) must choose a hunk drag handle.
- Conflict "pair" mode counts conflict terms in line numbers, so gap counts there may be off (edge case, not handled). The follow-up pass removed the bottom gap there (`left_line_count` 0); gaps between hunks still use the paired numbers, which the read uses too.

### Follow-up review pass (2026-11-15)

**Summary.** A second review of the finished story (baseline `3ced4808…` to `e95e3651…`). It found one real user-facing defect and closed it: a file whose only change is whitespace, viewed at `-w`, offered gap rows whose read returns nothing (`jj diff -w` prints no context for it), so opening one dropped the row and showed no lines. Such a file now gets no gap rows. Smaller fixes: `left_line_count` is 0 under paired conflicts, the DS prompt example's part index, an ARB description, and tests for the description block's count and the hover reset on reload.

**Files changed.**
- `crates/zanshin-jj/src/hunks.rs` -- `left_line_count` 0 under `diff.color-words.conflict = "pair"`; doc comment.
- `schemas/envelope.fbs`, `docs/ffi-abi.md`, `packages/zanshin_core/lib/src/ffi/diff.dart`, generated `envelope_generated.rs` / `envelope_zanshin.ffi_generated.dart` -- the same rule in the docs.
- `crates/zanshin-jj/tests/it/{diff.rs,hunks.rs}` -- whitespace-only `-w` read is empty; description and paired `left_line_count`.
- `app/lib/src/features/graph/inspector_diff.dart` -- no gap rows when the ignoring read has no hunk.
- `app/lib/l10n/app_en.arb` (+ `app_localizations.dart`) -- `@inspectorFoldShowTooltip` description.
- `app/test/features/graph/inspector_diff_test.dart` -- whitespace-only `-w` file has no gap; hover reset on reload.
- `app/test/features/undo_timeline/operation_changes_test.dart` -- description block count-only row.
- `_bmad-output/implementation-artifacts/design_system/components/content/DiffHunk.prompt.md` -- example `parts={[null, null, 0]}`.

**Review findings.** 27 findings (medium 2, low 20, false 3, maybe-false 2). Patched 6 entries: whitespace-only `-w` gaps (medium, with the short-read row), paired `left_line_count` (low, blind + edge), DS prompt part index, ARB description, and the two test gaps (description count, hover reset). Carried 7 rows from the first pass unchanged (the commit-switch deferral twice, the duplicated revision form, the short read, the empty no-commit read, the bottom-gap `top` false, the tied-part Split test). Rejected: 3 false (operation view clears its diff on a switch; bottom gap never mis-marked; extra changes with no harm) and 10 low (description count-only rows per the spec ×3, non-FFI read error ×3, keyboard hover by intent, "Show all" label, `left_line_count` edge tests, pill vs flat button). No new deferral.

**Follow-up review recommendation:** false. A follow-up pass patched no high finding (medium 1 entry, low 5 entries).

**Verification.** See the follow-up verification notes above: targeted Rust, codegen, `zanshin_core` and app checks pass.
