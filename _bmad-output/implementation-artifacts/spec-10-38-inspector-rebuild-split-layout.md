---
title: 'Story 10.38 — Inspector rebuild, part 1: files beside or above the diff, a draggable split, a wider inspector, Finder keys, parts of a hunk'
type: 'feature'
created: '2026-11-14'
status: 'done'
baseline_revision: 'a475f18685dc7e437057d02bbf6a6a968832a4a1'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/.claude/skills/design-artifacts/SKILL.md'
warnings: ['oversized']
deferred:
  - summary: >-
      The design-system changes of Story 10.38 are in the repo but not published: the Design System artifact and canvas 6sAzL5mDcVpWXevbTcempu still show the state before the story.
    evidence: |-
      The design-artifacts skill's step A (one publish to https://claude.ai/artifact/J5iSiy8cS6Q1EXa44g945d) was refused in this unattended run by the auto-mode permission check ("Unsanctioned Communication"); step B (canvas sync) depends on it. The built output with lastChange set is in the session scratchpad (ds/project/…), which a later session cannot rely on; rebuilding it with build_ds.py is quick.
    location: >-
      _bmad-output/implementation-artifacts/design_system/ (republish via .claude/skills/design-artifacts/SKILL.md A and B)
    severity: medium
  - summary: >-
      Both inspector layouts, the divider, the parts and the pinned numbers were not checked through Marionette against the mock-up and the DS cards.
    evidence: |-
      The epic's done rule asks for a Marionette check of every UI change; this unattended run had no catalogue session. Widget tests cover the behaviour; the catalogue has the use cases Inspector › Wide / Narrow, Inspector diff › Three parts / Pinned numbers scrolled right, Controls › Split divider.
    location: >-
      app/widgetbook/folders/graph.dart, app/widgetbook/folders/controls.dart
    severity: low
  - summary: >-
      A large file's unified diff may scroll sideways slowly: every line has its own listener on the file's horizontal scroll, and IntrinsicWidth now runs over the whole file.
    evidence: |-
      Unverified (no measurement). inspector_diff.dart `_Pinned` wraps each line's pinned numbers and each hunk header in an AnimatedBuilder on the file's horizontal controller, so a scroll tick rebuilds one Transform per line; `_DiffBody` lays out all hunks in one IntrinsicWidth inside a non-lazy scroll view. Settle it by scrolling a diff of a few thousand lines in the real app (profile build) and watching the frame times.
    location: >-
      app/lib/src/features/graph/inspector_diff.dart (_DiffBody, _Pinned)
    severity: medium (unverified)
  - summary: >-
      Dragging the split divider or the inspector's edge over a large diff may stutter: every frame that changes the diff pane's width lays out the whole file again.
    evidence: |-
      Unverified (no measurement). In the wide layout a divider or edge drag changes the diff pane's width each frame; `_DiffBody`'s LayoutBuilder then measures the number digits again and runs IntrinsicWidth over every line of the non-lazy file. Settle it with the sideways-scroll item above: in a profile build, drag the divider and the inspector edge with a diff of a few thousand lines open and watch the frame times.
    location: >-
      app/lib/src/features/graph/inspector_diff.dart (_DiffBody)
    severity: medium (unverified)
---

<intent-contract>

## Intent

**Problem:** The inspector is one scroll view (`graph_inspector.dart:1080-1128`): with many files the user scrolls up and down between the file list and the diff. It stops at 720 points (the pinned panel at 440). ↑ ↓ only move a highlight and ↩ loads the diff. A hunk can only be picked whole, though at context 3 it can hold several runs of changes. In the unified diff the line numbers scroll away with the text (deferred-work.md I1).

**Approach:** Rebuild the inspector body as the approved mock-up (`design/Inspector Study.html`, DESIGN-SYSTEM-SYNC #25, #26): a top part at natural height (max 48 %), then a split of files and diff that each scroll on their own, side by side from 780 points wide and stacked below 740 (hysteresis), with a draggable divider whose ratio per layout is an app-wide setting. Drop the fixed maximum widths. Finder keys in the file list. One horizontal scroll unit per file diff with pinned line numbers and hunk headers. A hunk's parts (jj's builtin diff-editor sections) get their own checkboxes. DS parts of #25 / #26 for 10.38 go through the `design-artifacts` skill. DS synced through #26.

## Boundaries & Constraints

**Always:**
- **Layout by width.** Wide (files left, diff right) once the inspector is ≥ 780 points wide; narrow (files above, diff below) once it is < 740; between the two the last layout stays. The first build picks wide iff ≥ 780. Header fixed; the top part (title or describe/squash form, meta, chips, actions) keeps its natural height up to 48 % of the space below the header, then scrolls; the split fills the rest; the composer stays at the bottom.
- **Divider** between files and diff in both layouts: 12 px band, a 4 px grip in `--fl-border` (centred, 10 % of the band's length), on hover and while dragging a full-length 2 px `--accent` line; cursor `resizeColumn` (wide) / `resizeRow` (narrow). Drag follows the pointer; double-click (and ↩) resets to the default. Minimums: files 110 / 220, diff 140 / 320 (narrow / wide); when both cannot fit, the diff's minimum wins. The files' share is remembered per layout in `LayoutSettings` (app-wide, defaults 0.38 narrow / 0.34 wide), written when a drag ends or on reset — never per move.
- **Divider keys and VoiceOver** (Claude's proposal, mirroring `ZsResizeEdge`): a Tab stop with the focus ring; ← → (wide) or ↑ ↓ (narrow) move 10 px, with ⇧ 50 px; ↩ resets; VoiceOver: an adjustable slider named "Files and diff", its value in percent.
- **No fixed maximum width:** `ZsMetrics.inspectorWMax` / `panelWMax` and the DS tokens `--inspector-w-max` / `--panel-w-max` go. Remembered widths clamp only to their minimums; the edges stop where `--graph-min-w` (320) of graph remains; the window-width rules of `ShellLayout` stay otherwise as they are.
- **Description clamp:** the description body under the subject shows at most 3 lines; "Show more" (12 px, weight 500, `--accent`) under it only while it is cut; when open, "Show less". Reset to closed when the selection changes.
- **Finder keys** in the file list (one Tab stop): ↑ ↓ move the current row and show its diff at once (`model.focus`); while a key repeats (`KeyRepeatEvent`) the row moves at once and the diff loads after an 80 ms pause without further repeats. Space toggles the current file's pick on a mutable change (`togglePick`); `V` (no modifier) toggles its Viewed mark; ↩ focuses the current row (no harm). The current row is the focused file's row (`--fl-on`); while the list has focus it also carries a 1.5 px `--accent` ring. The current row is scrolled into view. A click selects and focuses, as today.
- **Pinned numbers (settles I1).** A file's unified diff scrolls sideways as one unit (all its hunks), every line as wide as the widest line of the file. The two number columns (and the part gutter) stay at the visible left edge while the text scrolls under them, painted over the text on an opaque backing (the diff well colour plus the line's fill); the hunk header is as wide as the visible area and stays in view sideways. This holds for short lines when scrolled fully right. In the inspector the diff pane scrolls both ways in one `ZsScrollArea`; where the view has unbounded height (the Undo Timeline's operation view, the catalogue) it keeps the height of its content and scrolls only sideways.
- **Parts of a hunk** (#26). A part = one entry of `Hunk.sections`; its lines = the hunk's non-context lines whose left number − 1 lies in `[oldStart, oldStart + oldCount)` or right number − 1 in `[newStart, newStart + newCount)`. A selectable hunk with more than one part shows a pill "N parts" (10.5 px, `--fl-hover`, `--text-dim`) in its header, and every line of it a 22 px gutter before the numbers holding a 13 px checkbox on each part's first line; the hunk checkbox is three-state (header `--accent-soft-hi` when all, `--accent` at 12 % when some); each picked part's lines carry the 2 px `--accent-line` edge. Both layouts (side by side: the gutter leads the row). The smallest pick is a part, never a line. A part toggles through the model like a hunk (only keys still in the file's current sections; full partial → whole pick).
- Strings through the ARB with ICU plurals; `flutter gen-l10n` output committed. Zs controls only; tokens from the DS layer. Tests in temp dirs; never Ralph's settings.

**Never:**
- The file rows' new content (name first, folder, tree/flat, menus, copy, Open/Reveal) — Story 10.39. ← → in the list, ⌘C — 10.39.
- The diff options menu and whitespace modes, and the folded "N lines changed whitespace only" row of #26 (app and DS) — they only exist while whitespace is ignored, which Story 10.33 builds.
- Picking single lines; a full-screen inspector; a new FFI call or Rust change.
- Writing the ratio or the width per pointer move.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Grow across threshold | narrow at 760, dragged to 790 | wide once; back to 760 stays wide; to 730 narrow once | — |
| Ratio remembered | wide divider dragged, released | `settings.json` `layout` holds the new wide share; narrow share unchanged; a reloaded store and a new inspector use it | write failure swallowed, value kept in memory |
| Divider minimums | wide split 600 px, drag files to 50 | files 220; drag toward the right edge stops at extent − 12 − 320 | — |
| Tiny split | narrow split extent 200 | diff keeps 140, files get the rest (≥ 0) | — |
| Description long | 10-line body | 3 lines + "Show more"; tap → all + "Show less"; selecting another change → closed | short body: no button |
| Inspector width | window 2000 wide, no pinned panel | inspector edge drags to 2000 − 76 − 24 − 320; remembered width above 720 survives a reload | — |
| Arrow walk | 40 files, list focused, ↓ ×20 | current row 21 is visible, its diff shows, diff pane stays in view | — |
| Key repeat | ↓ down + 5 repeats within 80 ms | current row moves 6, one diff read for the last row after the pause | stale replies dropped (`_focusSerial`) |
| Space / V | mutable change, current row | Space flips the file's pick; V flips Viewed | immutable: Space does nothing |
| Three parts | hunk with 3 sections, pick 2nd part | composer action selects only `sections[1]`; hunk checkbox mixed; edge only on the 2nd part's lines | — |
| One part | hunk with 1 section | no pill, no gutter; hunk checkbox as today | — |
| Pinned short line | long and short lines, scrolled fully right | short line's numbers and part checkbox at the body's left edge; hunk header in view | — |
| Operation view | `InspectorDiffView` in an unbounded column | renders at content height, scrolls sideways only | — |

</intent-contract>

## Code Map

- `app/lib/src/features/graph/graph_inspector.dart:1051-1155` -- `_GraphInspectorState._panel`: today header + one `SingleChildScrollView` (`_scroll`, identifier `inspector-body`) holding forms/title, `_Meta`, `_Chips`, `_Actions`, `_Changes`, then the composer `ZsPresence`. Rebuild here: top part + split; keep the hysteresis bool in this state.
- `graph_inspector.dart:1551-1645` -- `_Title`: subject + body (`texts.body`, `:1597-1601`) inside a `ZsControlCore` that opens the form; the clamp and Show more/less go on the body (the button must not open the form).
- `graph_inspector.dart:2235-2479` -- `_Changes`/`_ChangesState`: header row (select all, "Changes", count/totals, viewed counter), the list (`Focus` + `_onKey` `:2271-2294`, `_highlight`), then the diff (`InspectorDiffView` `:2450-2473`, previous-diff dimming). Split this into a files pane (header + own scroll list) and a diff pane; keep the empty / stale / error notes.
- `graph_inspector.dart:2484-2605` -- `InspectorFileRow` (`focused`, `highlighted`): keep its content (10.39 changes it); the current-row look + ring.
- `graph_inspector.dart:53-929` -- `InspectorViewModel`: `focus` `:166`, `focusedPath`, `isViewed`/`setViewed`, `selectable`, `togglePick` `:476`, `hunkState` `:463`, `toggleHunk` `:488`, `_partialOf`/`_setPartial`/`_normalize` `:511-560`, `settings` (a `SettingsStore`; `setLayout` `:225` is the write pattern). Add part state/toggle beside the hunk ones; ratio getters/setters on `settings.value.layout`.
- `graph_inspector.dart:931-952` -- the inspector's doc comment; update it.
- `app/lib/src/features/graph/inspector_diff.dart:276-486` -- `InspectorDiffView` (bar, bodies, hunks loop `:398-411`); `:623-883` `InspectorDiffHunk` (`_unified` `:766` with its own horizontal `ZsScrollArea` per hunk, `_sideBySide` `:826`, header `:683-717`, edge `:718-729`, `_number`, `_digits`). Move the horizontal scroll to the file level; add the part gutter, pill, per-part edge; a pure helper mapping a line to its part (test it).
- `app/lib/src/features/undo_timeline/operation_changes.dart:700-741` -- reuses `InspectorDiffView` in an unbounded column; must keep working (no picks there).
- `app/widgetbook/folders/graph.dart:276-293` -- "Inspector diff" use cases (`_HunkSelection` `:1698-1830`, `_WordMarks`); `:810-900` the floating-shell demo with an inspector. Add use cases: the inspector wide and narrow (fixed widths, e.g. 900 and 460), a hunk with three parts, pinned numbers scrolled right.
- `app/lib/src/features/shell/shell_layout.dart:14-30, 60-61, 109-113` -- clamps and limits with `inspectorWMax`/`panelWMax`; `floating_shell.dart:64` doc; `shell_controller.dart` (key End = max). Tests `app/test/features/shell/shell_layout_test.dart`, `floating_shell_test.dart`, `shell_controller_test.dart`.
- `packages/zanshin_ui/lib/src/design/zs_metrics.dart:87,90,214,217,393-403,554,557,635,638,730,733,816,819,899,902` -- remove `inspectorWMax`/`panelWMax`; parity with DS `tokens/spacing.css:42` is checked by `packages/zanshin_ui/test/design/ds_parity_test.dart`.
- `packages/zanshin_ui/lib/src/controls/zs_resize_edge.dart` -- the pattern for the new divider control (drag, double-click reset, cursor overlay while dragging, keys, slider semantics); `zs_scroll_area.dart` takes `controller` + `horizontalController` (overlay bars on the area's edges, so nest vertical > horizontal scroll views).
- `packages/zanshin_settings/lib/src/model/layout_settings.dart` -- add the two shares; regenerate `.freezed.dart`/`.g.dart` with build_runner (`build.yaml` header rule).
- `packages/zanshin_core/lib/src/ffi/diff.dart:97-164` -- `HunkLine.left/right` (1-based), `Hunk.sections`; `ffi/select_tree.dart:30-57` `HunkKey` (0-based starts, counts).
- Mock-up: `_bmad-output/implementation-artifacts/design/inspector-study.jsx:270-365` (diff pane, gutter, pill), `:380-464` (files pane, keys), `:495-608` (inspector, split, divider drag `:536-544`, clamp `:506-562`), `:611-632` (thresholds); `inspector-study.css:40, 60-62, 73-85, 103-109, 142-172`.
- DS (`_bmad-output/implementation-artifacts/design_system/`): the max tokens appear in `tokens/spacing.css:42`, `_adherence.oxlintrc.json:829,851,1291,1294`, `_ds_manifest.json`, `readme.md:110` ("380–720 · 240–440"), `ui_kits/desktop/app.jsx`, `components/surfaces/ResizeEdge.prompt.md:4,6,11`, `ResizeEdge.d.ts`, `resize.card.html` — all drop the maximum. `components/content/DiffHunk.*`, `DiffView.*`, `content.css`, `content.card.html`; `components/surfaces/` (ResizeEdge as pattern, `surfaces.css`); `ui_kits/desktop/inspector.jsx`, `kit.css`; `_ds_bundle.js`; `readme.md` (change log, "Synced through"). `design/DESIGN-SYSTEM-SYNC.md` #25/#26: add a dated "2026-11-14 (Story 10.38)" line under each, as 10.35/10.36 did.
- Tests: `app/test/features/graph/graph_inspector_test.dart` (fake details; `pump(tester, width:)`), `inspector_diff_test.dart`, `graph_ports_test.dart:365-420` (real repo, `threeHunkRepo`, `addedLines`).

## Tasks & Acceptance

**Execution:**
- `packages/zanshin_ui/lib/src/design/zs_metrics.dart` + DS `tokens/spacing.css` -- remove the two maximum tokens -- no fixed maximum width.
- `packages/zanshin_ui/lib/src/controls/zs_split_divider.dart` (new, exported) -- `ZsSplitDivider` (axis, value in px, min, max, default, `onChanged`, `onChangeEnd`, label, identifier) with the look, drag, reset, keys and semantics above -- the divider in both layouts. Widget tests in `packages/zanshin_ui/test/controls/`.
- `packages/zanshin_settings/lib/src/model/layout_settings.dart` + generated -- `inspectorFilesNarrow` (0.38), `inspectorFilesWide` (0.34) -- the remembered shares. Settings test: defaults, round trip.
- `app/lib/src/features/shell/shell_layout.dart`, `shell_controller.dart`, `floating_shell.dart` (docs) + tests -- clamp to minimums only; limits keep 320 of graph.
- `app/lib/src/features/graph/inspector_diff.dart` -- file-level horizontal scroll unit with pinned numbers and hunk headers; bounded mode (both axes, for the inspector) and unbounded mode (content height); part helper, gutter, pill, per-part edge, part checkboxes (`partPicked`, `onPartToggled` callbacks beside `hunkPicked`/`onHunkToggled`).
- `app/lib/src/features/graph/graph_inspector.dart` -- top part + split (hysteresis, divider, ratios from/to `settings`), files pane with its own scroll, Finder keys (80 ms repeat pause, Space, V, ring, scroll into view), description clamp, part state/toggle in the model, doc comment.
- `app/lib/l10n/app_en.arb` (+ `flutter gen-l10n`) -- "Show more", "Show less", "{count} parts" (ICU), part checkbox labels ("Pick these lines" / "Unpick these lines"), divider label "Files and diff" and tooltip "Drag to resize · double-click to reset".
- `app/widgetbook/folders/graph.dart` -- the use cases named in the Code Map.
- `app/test/features/graph/graph_inspector_test.dart`, `inspector_diff_test.dart`, `graph_ports_test.dart` -- one test per I/O matrix row (the real-repo row: one hunk with three sections at context 3, `FileSelection.hunks` of `sections[1]` commits only that part's lines).
- DS via `design-artifacts` (C, E, then A and B): tokens; `DiffHunk` pinned numbers, part gutter + checkbox, parts pill, per-part edge (jsx, d.ts, prompt.md, `content.css`, Content card); a `SplitDivider` in `components/surfaces/` (jsx, d.ts, prompt.md, css, card); the kit inspector: top part, split with divider by width (780/740), clamped description, picks by part; `_ds_bundle.js` blocks; readme change log + "Synced through"; republish the DS and sync canvas `6sAzL5mDcVpWXevbTcempu`; dated lines under DESIGN-SYSTEM-SYNC #25 and #26 (also: the folded whitespace row moves to 10.33).

**Acceptance Criteria:**
- Given an open inspector, when the user drags its edge from 700 to 800 and back to 760, then the files move beside the diff once and stay there; at 730 they move above.
- Given a dragged divider in each layout, when the app restarts (a new `SettingsStore` on the same file), then each layout shows its own remembered share.
- Given a window 2000 points wide, when the user drags the inspector's edge, then it widens until 320 points of graph remain, beyond 720.
- Given the file list has focus on a mutable change, when the user presses ↓, Space and V, then the next file's diff shows, its checkbox flips and its Viewed mark flips.
- Given a hunk with three parts, when the user picks the second part's checkbox, then the composer's action selects only that section, the hunk checkbox shows mixed, and (real repo) committing it leaves the other two parts in the change.
- Given a unified diff with a short line below a long one, when it is scrolled fully right, then the short line's numbers and part checkbox stay at the left edge (I1 settled).

## Spec Change Log

## Review Triage Log

### 2026-11-14 — Review pass
- verdicts: 34 findings — high 0, medium 5, low 26, false 1, maybe-false 2
- findings:
  - `[low]` `[reject]` (intent) the layout-switch witness is tested by rebuilding the host at fixed widths, not by dragging the shell's edge — the same `LayoutBuilder` width drives both; a shell drag only adds the existing, tested edge.
  - `[low]` `[reject]` (intent) the restart test checks the stored share and the view model, not the divider's place — the place follows from `filesShare` through `InspectorSplit`, which has its own test; the patched "follows another writer" test now checks the divider value.
  - `[low]` `[reject]` (intent) the real-repo three-parts test builds the `GraphCommit` by hand instead of going through the composer — the widget test proves the composer emits exactly `sections[1]`; together the two halves cover the path.
  - `[low]` `[defer]` (intent) no Marionette comparison of both layouts — needs a catalogue session; deferred (mirrored in deferred-work.md).
  - `[medium]` `[defer]` (intent) the DS republish and canvas sync are not done — the auto-mode permission check refused the artifact publish; needs the console session (mirrored in deferred-work.md).
  - `[false]` `[reject]` (intent) spec, Auto Run Result and commits are not in the diff — they are written at finalize, after review.
  - `[low]` `[reject]` (intent) the collapsed flyout's new cap is not stated in the epic — without a maximum a remembered 900 would cover a narrow window; the cap keeps the old protection and is documented.
  - `[low]` `[patch]` (verification) no test that the split follows another settings writer — added in graph_inspector_test.dart.
  - `[low]` `[patch]` (verification) no test that the inspector divider's reset writes the layout's default share — added (wide 0.34, narrow 0.38).
  - `[low]` `[patch]` (verification) no test that a whole-picked file shows every part checked — added (whole → toggle one part → others checked, hunk mixed).
  - `[low]` `[patch]` (verification) a unified conflict header now sits behind blank number columns; its test checks only the colour — header rows render without the pinned group again; a position assertion added.
  - `[low]` `[patch]` (verification, other) the unified conflict header also carries the per-line edge — same fix as the row above.
  - `[low]` `[patch]` (blind) kit divider reset goes to the last dragged share — defaults kept in a separate constant (inspector.jsx + bundle block).
  - `[low]` `[patch]` (blind) kit Select all ignores part picks and Deselect all never clears them — header toggle clears and counts part picks.
  - `[low]` `[reject]` (blind) kit composer moves a partly picked hunk whole — the kit has no tree-level selection; modelling it adds complexity to a demo, the app is exact.
  - `[low]` `[reject]` (blind) kit `ZKDesc` does not re-measure on width change — a demo-only glitch; a ResizeObserver adds code for little gain.
  - `[low]` `[patch]` (blind) DS `DiffHunk`: `selected` and `parts` contradict — with parts shown and no `picked`, `selected` means all parts.
  - `[maybe-false]` `[defer]` (blind) per-line `AnimatedBuilder` and whole-file `IntrinsicWidth` may make large diffs scroll slowly — unmeasured; settle by scrolling a few-thousand-line diff in a profile build (deferred as medium, unverified).
  - `[medium]` `[patch]` (blind) every part checkbox has the same VoiceOver name — the label now carries the part's line range.
  - `[low]` `[patch]` (blind) the flyout comment and test promise 320 of graph beside it, but the open inspector is not subtracted — comment, doc and test name reworded to what the code does.
  - `[low]` `[patch]` (blind) a held arrow key stores a row index; a reload in the pause shows another file — the pending path is stored instead.
  - `[low]` `[patch]` (blind) `ZsSplitDivider._reset` reports a change at the default — returns early when nothing changes; test extended.
  - `[low]` `[patch]` (blind) the new panes have no identifiers; the top part keeps `inspector-body` — identifiers `inspector-files-list` and `inspector-diff-body` added; the doubled VoiceOver name on the top part is rejected as cosmetic.
  - `[low]` `[patch]` (blind) missing tests (togglePart on a whole file, reset, other writer, …) — the reset, other-writer and whole-file cases are added; ↑ at the first row, Show less again, all parts one by one, side-by-side edge and divider keys at the limits are rejected as low-value additions to already covered branches.
  - `[medium]` `[patch]` (edge) the pinned group's `foregroundDecoration` toggles null, so Space on a part checkbox rebuilds it and focus is lost — the decoration is always built, border null when off.
  - `[medium]` `[patch]` (edge) side by side adds or removes a `DecoratedBox` per toggle, same focus loss — same fix (grouped with the row above).
  - `[medium]` `[patch]` (edge) the file row's ring toggles `foregroundDecoration`, so focus entering the row's checkbox rebuilds it — the decoration is always built.
  - `[low]` `[patch]` (edge) a new selection keeps the old file-list scroll offset — the list jumps to the top on a change of key.
  - `[low]` `[reject]` (edge) a `_dragShare` left over when the split is replaced mid-drag — needs a reload to land during a divider drag; the value is overwritten by the next drag or rebuild of the state; a guard adds code for a rare case.
  - `[low]` `[reject]` (edge) the axis changes mid-drag — only a window resize during a divider drag can do it; rare, and the next drag resets the state.
  - `[maybe-false]` `[reject]` (edge) RenderFlex overflow in a very short inspector — the shell keeps a minimum window height; if real only a debug stripe (low).
  - `[low]` `[reject]` (edge) the cut description cannot be opened while the graph is stale — stale is short-lived and the title is disabled on purpose; moving the button out of the control restructures the title.
  - `[low]` `[patch]` (edge) another change with the same focused path keeps the old diff scroll — the inspector keys its diff view by the change.
  - `[low]` `[patch]` (edge) conflict header indented behind blank number columns — grouped with the verification row above.

### 2026-11-14 — Review pass (follow-up)
- verdicts: 43 findings — high 0, medium 1, low 37, false 2, maybe-false 3
- findings:
  - `[false]` `[reject]` (intent) a held ↓ reads two diffs (key down + after the pause), not one — the rule "↑ ↓ show its diff at once" covers the key down; the matrix's "one diff read … after the pause" is the one read the repeats add. Both hold.
  - `[low]` `[reject]` (intent) divider key steps and VoiceOver steps each write the share — the intent forbids writes per pointer move only; each step is a finished change, and the writes are queued in order by `SettingsStore` (grouped with the blind row on a held arrow key).
  - `[low]` `[reject]` (intent) the 48 % base is the space between the header and the composer, not the header and the island's bottom — the composer is not shown until something is picked; while it shows, the top part giving way to it is the sensible reading.
  - `[low]` `[reject]` (intent) carried — the collapsed flyout's new cap is not in the epic; the cap keeps the old protection and is documented.
  - `[low]` `[reject]` (intent) a reset whose clamped default equals the current length writes nothing — grouped with the blind row on the reset in a small inspector.
  - `[low]` `[reject]` (intent) divider minimums and the tiny split are tested on `InspectorSplit` only — the divider's `min`/`max` come straight from it (checked at 900 wide in the drag test); a widget drag to each limit adds nothing.
  - `[low]` `[reject]` (intent) no settings reload of an inspector width above 720 — no clamp to 720 is left anywhere (`ShellLayout` uses a remembered 1000 as is, the settings model has no maximum).
  - `[low]` `[reject]` (intent) the write-failure path of `setFilesShare` is untested — the same `onError<FileSystemException>` as `setLayout`.
  - `[low]` `[reject]` (intent) the divider's keys and VoiceOver are tested on `ZsSplitDivider` alone, not inside the inspector — the inspector passes the same callbacks the drag and reset tests exercise.
  - `[low]` `[reject]` (intent) the `resizeColumn`/`resizeRow` cursors are not asserted — a constant per axis; cosmetic.
  - `[low]` `[patch]` (intent) the 1.5 px ring on the current row is not asserted — grouped with the verification row on the ring below.
  - `[low]` `[reject]` (intent) the arrow walk only checks that the diff's top is above 840 — the split keeps the diff pane in view by construction; the row's visibility is what moved.
  - `[low]` `[reject]` (intent) carried — the real-repo three-parts test builds the commit by hand; the widget test proves the composer emits only `sections[1]`.
  - `[low]` `[reject]` (intent) the pinned short line is tested on `InspectorDiffView` alone, not inside the split — the split only sizes the view; the pinning lives in the view.
  - `[low]` `[reject]` (intent) the operation view is tested in a synthetic unbounded host — the unbounded height is the only property the operation view adds.
  - `[low]` `[defer]` (intent) carried — no Marionette comparison of both layouts.
  - `[medium]` `[defer]` (intent) carried — the DS republish and canvas sync are not done.
  - `[low]` `[patch]` (verification) no test that a new file starts its diff at the top left and another change its list at the top — added in graph_inspector_test.dart (both diff scrolls and the list read 0 after ↓ and after another change with the same path).
  - `[low]` `[patch]` (verification) no test for a held key's file that goes in a reload during the pause — added: the gone file is neither focused nor read, the row falls back.
  - `[low]` `[patch]` (verification) no test that a held Space or V flips once — the Space/V test now holds each with two repeats.
  - `[low]` `[patch]` (verification) no test of the current row's 1.5 px accent ring — the ↓ ×20 test asserts it on the current row only, and gone once the list loses focus.
  - `[low]` `[patch]` (verification) no test of the top part's 48 % cap — added: an 80-line description opened takes at most 48 % and scrolls; the divider stays in view.
  - `[low]` `[patch]` (verification) side by side's per-part edge and part taps are untested — the three-parts test now checks each row's edge (an added-only row takes its right line's part), taps parts 2 and 3, and the whole-hunk edge without parts on and off.
  - `[low]` `[reject]` (blind) a reset in a small inspector stores the clamped share, or nothing when it is already there — only in a narrow split under about 290 points; the share heals at the next reset in a larger window, where the default no longer clamps; a fix needs a reset signal on the divider.
  - `[low]` `[reject]` (blind) carried — a `_dragShare` left over when the divider leaves the tree mid-drag; needs a reload during a divider drag.
  - `[low]` `[reject]` (blind) a held arrow key on the divider writes `settings.json` per repeat — `SettingsStore.update` queues the writes in order, so the last value wins; a few small writes per second while a key is held do no harm.
  - `[low]` `[reject]` (blind) a collapsed panel with a large remembered width returns only once its full width fits — that is the window rule the intent keeps ("rules stay otherwise as they are"); the flyout has its resize edge, and dragging it narrower lowers the threshold.
  - `[low]` `[reject]` (blind) carried — the flyout's cap does not subtract the open inspector; the docs were reworded in the first pass.
  - `[low]` `[patch]` (blind) no test taps a part checkbox while the diff is scrolled sideways — the pinned-numbers test now taps the pinned box after scrolling fully right and gets its section.
  - `[maybe-false]` `[defer]` (blind) the deferred performance note misses divider and edge drags, which lay out the whole file each frame — settle by dragging both over a few-thousand-line diff in a profile build (deferred as medium, unverified; mirrored in deferred-work.md).
  - `[low]` `[reject]` (blind) the DS `ResizeEdge`'s End goes to `Infinity` without `limit` — every consumer (the kit's two edges) passes `limit`; a guard adds a branch to a demo component.
  - `[low]` `[reject]` (blind) the DS has no ring or Finder keys on `FileRow`, and its part labels lack the line range — the DS kit is a demo; the ring and keys would add kit behaviour, the range labels need line numbers in the DS props.
  - `[low]` `[patch]` (blind) the DS readme's "Synced through #26" names only 10.33's open row — it now also names #25's file rows waiting for Story 10.39.
  - `[false]` `[reject]` (blind) the "Inspector" VoiceOver label now covers only the top part — the whole inspector is a `Semantics` container labelled `inspectorLabel` (graph_inspector.dart, `_GraphInspectorState.build`); the file list has its own "Changes" label.
  - `[low]` `[reject]` (blind) `setFilesShare` catches only `FileSystemException` — the same as `setLayout`; a failed write is a `FileSystemException`.
  - `[low]` `[patch]` (edge) a divider drag that ends back at its start leaves `_dragShare` set, so later setting changes and a layout switch show a stale share — `ZsSplitDivider` now reports the end of any drag that moved it; test added in zs_split_divider_test.dart.
  - `[low]` `[patch]` (edge) the one `GlobalKey` that follows the current row carries a row's element (and its checkbox state) to another file — every row now has its own key per path; test: both rows keep their elements across ↓.
  - `[low]` `[reject]` (edge) a reset where the default is outside min … max — grouped with the blind row on the reset in a small inspector.
  - `[maybe-false]` `[reject]` (edge) a section with no non-context line in its hunk gets no checkbox though the pill counts it — needs a jj section whose changed lines fall outside its own ranges, which jj's line diff does not produce; if real only low (the part is still picked through the hunk checkbox).
  - `[maybe-false]` `[reject]` (edge) a side-by-side row can pair a left line of one section with a right line of another — rows pair only within one contiguous run of changes, which is one jj section; if real only low (the right side's part keeps its unified checkbox).
  - `[low]` `[reject]` (edge) a picked hunk's edge has a gap at a conflict header row — the first pass took conflict headers out of the per-line edge on purpose; a header is not a picked line.
  - `[low]` `[reject]` (edge) the DS `ResizeEdge` End can reach `Infinity` — grouped with the blind row above.
  - `[low]` `[reject]` (edge, claim) the DS `ResizeEdge` prompt still promises End = maximum while `max` is optional — grouped with the blind row above.

## Design Notes

- **Why one horizontal unit per file:** the mock-up scrolls the whole diff body both ways (`.isd-dbody{overflow:auto}`); one bar per file, and "every line as wide as the file's widest line" is then literal. Pinning in Flutter: the number cells move by the horizontal offset (listen to the controller) and must paint after the text — e.g. a `Stack` per row with the pinned cells last, or a small `RenderBox` that paints them on top. The hunk header sits outside the row content, sized to the viewport width and moved by the same offset.
- **Why a new `ZsSplitDivider` and not `ZsResizeEdge`:** the edge is a horizontal island edge with a 10 px strip and a neutral line; the divider is a band between two panes, vertical or horizontal, with a grip that turns into an accent line (#25). Same interaction rules, so copy its drag/keys/semantics pattern.
- **Parts and existing picks:** a part key is a `HunkKey`, the same unit `_partial` stores, so `toggleHunk` and the new part toggle share `_partialOf`/`_setPartial`/`_normalize`; nothing in the composer changes.
- **The folded whitespace row** (#26) is assigned to 10.38's DS part, but it can only appear while whitespace is ignored; Story 10.33 builds that mode and its picks, so the row (app and DS) goes there. Recorded as a dated line under #26.
- **Hysteresis state** lives in the inspector's widget state, not in settings: it is a function of the current width plus the last layout.

## Verification

**Commands:**
- `dart run build_runner build -d` in `packages/zanshin_settings` -- generated files updated and committed.
- `flutter gen-l10n` in `app` -- output committed.
- `flutter test` in `packages/zanshin_ui`, `packages/zanshin_settings` -- pass.
- `cargo make test-app test/features/graph test/features/shell test/features/undo_timeline test/widgetbook` (or `flutter test` with those paths in `app`) -- pass.
- `dart analyze app packages/zanshin_ui packages/zanshin_settings` -- no issues.
- `dart format --set-exit-if-changed` on the touched Dart directories -- 0 changed.
- Not run (gate rule of the story loop): `cargo make test`, `test-full`, `coverage`. No Rust changes, so no cargo checks.

**Manual checks:**
- DS republished (artifact version noted) and canvas synced, per the skill's A and B.
- Marionette check of both layouts in the catalogue vs the mock-up: left to the console session, as in 10.35–10.37.

**Verification notes (2026-11-14, gate rule of the story loop: no full gate):**
- `dart run build_runner build -d` in `packages/zanshin_settings` (implementation run) -- `layout_settings.freezed.dart` / `.g.dart` regenerated.
- `flutter gen-l10n` in `app` and `packages/zanshin_ui` -- re-run after the review patches; output unchanged (up to date).
- `dart analyze app packages/zanshin_ui packages/zanshin_settings` -- No issues found (after implementation and after review patches).
- `dart format --set-exit-if-changed -o none` on `app/lib`, `app/test`, `app/widgetbook`, both packages' `lib` and `test` -- 0 changed.
- `flutter test` in `packages/zanshin_ui` -- 470 passed; in `packages/zanshin_settings` -- 56 passed (after review patches).
- `cargo make test-app test/features/graph test/features/shell test/features/undo_timeline test/widgetbook test/l10n test/architecture` -- first run: 1 failure (`ds_manifest_parity_test.dart`: `SplitDivider` had no catalogue use case; fixed with Controls › Split divider); after that 1575 passed; after the review patches 1578 passed.
- `node --check design_system/_ds_bundle.js` -- passes.
- DS cards (split card, Content card, kit inspector) opened in the Browser pane by the implementation run: render with no errors (before the review's kit fixes; not re-checked after).
- Not run: `cargo make test` / `test-full` / `coverage` (the loop's gate rule); no Rust changed, so no cargo checks. A full-app `flutter test` outside `cargo make test-app` fails 6 tests in `worker_project_repos_test.dart` and `remote_sync_test.dart` (they need the environment `cargo make test-app` pins; unrelated to this change).
- Not done: DS publish and canvas sync (refused by the permission check) and the Marionette check — both deferred.

**Verification notes (2026-11-14, follow-up review pass; gate rule of the story loop: no full gate):**
- `cargo make test-app test/features/graph test/features/shell test/features/undo_timeline test/widgetbook` -- 1573 passed (after the patches).
- `cargo make test-app test/features/graph/graph_inspector_test.dart test/features/graph/inspector_diff_test.dart` -- first run: 1 failure in the new row-key test (it looked up the renamed row by its path; fixed to the row's shown text); after the fix and after formatting, 156 passed.
- `flutter test` in `packages/zanshin_ui` -- 471 passed.
- `dart analyze app packages/zanshin_ui` -- one `omit_obvious_local_variable_types` hint in a new test, fixed; then No issues found.
- `dart format --set-exit-if-changed -o none` on `app/lib`, `app/test`, `app/widgetbook`, `packages/zanshin_ui/lib`, `packages/zanshin_ui/test` -- 2 files reformatted, then 0 changed.
- Not run: `cargo make test` / `test-full` / `coverage` (the loop's gate rule); no Rust, FFI, settings model or l10n changed in this pass, so no cargo checks, codegen, build_runner or gen-l10n. DS publish and the Marionette check stay deferred.

## Auto Run Result

Status: done

**Summary.** The inspector body is a top part (natural height, at most 48 %, then it scrolls) over a split of files and diff that scroll on their own: side by side from 780 points, stacked below 740, the last layout in between. A new `ZsSplitDivider` sets the files' share (minimums 220/110 files, 320/140 diff), remembered per layout in `LayoutSettings` (0.34 / 0.38), written on drag end or reset. The inspector and the pinned panel have no maximum width; 320 points of graph stay. The description is clamped to 3 lines with Show more / Show less. The file list takes Finder keys: ↑ ↓ show the diff at once (80 ms pause while a key repeats), Space picks, V marks Viewed, the current row has the accent ring and stays in view. A unified diff scrolls sideways as one unit per file; line numbers, the part gutter and hunk headers stay at the left edge. A hunk of several parts shows "N parts" and a checkbox per part; picks go through the model as sections. DS: `SplitDivider`, `DiffHunk` parts and pinned numbers, the kit inspector split, tokens without the maximum widths. DS synced through #26 (folded whitespace row moved to Story 10.33).

**Commits.** `ce0b31de08dd19466f7a83e5c2378711b5f3304a` (code, tests, DS); the docs commit (this spec, sprint status, epic 10 context, deferred work) follows it.

**Files changed.**
- `app/lib/src/features/graph/graph_inspector.dart` -- top part + split with hysteresis, `InspectorSplit`, files pane with Finder keys, `_Description` clamp, `partPicked` / `togglePart`, `filesShare` / `setFilesShare`.
- `app/lib/src/features/graph/inspector_diff.dart` -- `_DiffBody` (one scroll unit per file, bounded and unbounded modes), `_Pinned`, `DiffPin`, `hunkPartOf` / `hunkLineParts`, parts pill, gutter and per-part edge.
- `app/lib/src/features/shell/shell_layout.dart`, `pinned_panel.dart` -- clamps to minimums only; the collapsed flyout leaves 320 of the window.
- `packages/zanshin_ui/lib/src/controls/zs_split_divider.dart` (new), `zs_metrics.dart`, `zanshin_ui.dart`, `l10n/zs_*` -- the divider; the two maximum tokens removed.
- `packages/zanshin_settings/lib/src/model/layout_settings.dart` (+ generated) -- the two shares.
- `app/lib/l10n/*` -- Show more/less, parts pill, part labels with line ranges, divider label and tooltip.
- `app/widgetbook/folders/graph.dart`, `controls.dart` -- Inspector › Wide / Narrow, Inspector diff › Three parts / Pinned numbers scrolled right, Controls › Split divider.
- Tests: `graph_inspector_test.dart`, `inspector_diff_test.dart`, `graph_ports_test.dart` (real repo, three parts), `zs_split_divider_test.dart`, settings tests, shell / pinned panel / floating shell / undo timeline / widgetbook parity tests adjusted.
- DS: `tokens/spacing.css`, `_adherence.oxlintrc.json`, `_ds_manifest.json`, `readme.md`, `components/surfaces/SplitDivider.*`, `split.card.html`, `surfaces.css`, `ResizeEdge.*`, `resize.card.html`, `components/content/DiffHunk.*`, `DiffView.jsx`, `content.css`, `content.card.html`, `ui_kits/desktop/inspector.jsx`, `app.jsx`, `data.js`, `kit.css`, `_ds_bundle.js`; `design/DESIGN-SYSTEM-SYNC.md` dated lines under #25 and #26.

**Review findings.** 34 findings: 22 patch rows in 15 entries (3 medium entries: part checkbox names; focus lost when a part's or a row's decoration toggled — grouped; 12 low), 3 deferred (DS publish — medium; Marionette check — low; large-diff scroll cost — medium, unverified), 8 rejected low with reasons in the triage log, 1 false.

**Follow-up review recommendation: true.** Patched this pass: high 0, medium 3, low 12. The named unverified risk: the focus fix (decorations always built so a toggle keeps the subtree) has no test that toggles a part or enters a row checkbox by keyboard and asserts the focus stays.

**Deferred-work items.**
- **I1** (line numbers scroll away in the unified layout) -- fixed (`ce0b31de08dd19466f7a83e5c2378711b5f3304a`): one horizontal scroll unit per file; numbers, part gutter and hunk headers pinned at the left edge, also on short lines scrolled fully right (test in `inspector_diff_test.dart`).
- **I2** (inspector too narrow, files above the diff) -- partly done (`ce0b31de08dd19466f7a83e5c2378711b5f3304a`): no maximum width, files beside the diff from 780 points, a divider, pinned numbers. Left: the file rows (name first, folder, tree/flat), copy and Open/Reveal actions — Story 10.39.

**Residual risks.**
- The DS artifact and canvas are not republished (deferred).
- Large diffs may scroll sideways slowly (deferred, unverified).
- Not checked visually through Marionette (deferred); the kit fixes from review were not re-opened in a browser.
- The settings-writer tests do not await the settings write (the value applies at once; the file write settles at teardown).

### Follow-up review pass (2026-11-14)

**Summary.** A fresh four-layer review of the whole change since `a475f18685dc7e437057d02bbf6a6a968832a4a1`. Two code fixes: a divider drag that ends back at its start now reports its end, so the inspector drops its drag-time share (before, a later layout switch or another settings writer showed a stale share); and each file row has its own key per path, so moving the current row no longer carries one row's element and checkbox state to another file. Missing tests added for the earlier patches and rules: scroll reset per file and per change, a held key's file gone in a reload, held Space / V, the current row's ring, the top part's 48 % cap, side by side's per-part edge and taps, and a tap on a pinned part checkbox while scrolled right. The DS readme's sync line now names #25's file rows as waiting for Story 10.39.

**Files changed.**
- `packages/zanshin_ui/lib/src/controls/zs_split_divider.dart` -- `_moved`: `onChangeEnd` runs after any drag that moved the value, also back at its start.
- `packages/zanshin_ui/test/controls/zs_split_divider_test.dart` -- test for a drag that ends at its start.
- `app/lib/src/features/graph/graph_inspector.dart` -- `_rows` / `_rowKey`: one `GlobalKey` per file path; `_reveal` takes the path.
- `app/test/features/graph/graph_inspector_test.dart` -- ring, row keys, scroll reset, gone pending file, 48 % cap, held Space / V.
- `app/test/features/graph/inspector_diff_test.dart` -- side-by-side edges and part taps, the whole-hunk edge, a tap on the pinned part checkbox.
- `_bmad-output/implementation-artifacts/design_system/readme.md` -- sync line names 10.39's open part of #25.

**Review findings.** 43 findings: 11 patch rows in 10 entries (all low), 1 new deferred item (divider / edge drags relayout a large diff — medium, unverified), 2 carried deferrals (DS publish, Marionette), 27 rejected rows (low, maybe-false or carried) with reasons in the triage log, 2 false.

**Follow-up review recommendation: false.** Patched this pass: high 0, medium 0, low 10 entries. A follow-up pass recommends another only after a high patch; none.

**Residual risks.** Unchanged from above: DS not republished, the Marionette check not done, large-diff scrolling and resizing unmeasured. Not re-checked in a browser: nothing in the DS changed except the readme line.

**Commits.** `16c11245ce725ce1baa2b67366ecd328d48049fe` (code, tests, DS readme); the docs commit (this spec, deferred work) follows it.
