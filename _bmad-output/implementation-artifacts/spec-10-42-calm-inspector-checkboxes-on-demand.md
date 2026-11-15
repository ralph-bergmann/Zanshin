---
title: 'Story 10.42 — Calm inspector, part 1: folders without chevrons, checkboxes on demand, no counts, no status letter'
type: 'feature'
created: '2026-11-15'
status: 'done'
baseline_revision: 'f6e97b1bcbf50ebd853f5be913ebf65accd3fb37'
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

**Problem:** Ralph finds the inspector overloaded: every folder row carries a chevron and a count pill, every row a status letter and ± counts, and every checkbox shows all the time. The UI should show nothing twice and show controls only when they are needed.

**Approach:** Build sections 1 (inspector) and 3 (Projects window) of the approved `design/Calm Inspector Study.html` (`calm-study.jsx/.css`, Ralph 2026-11-15 "Passt so"): folders show open / closed through their icon only, checkboxes in the files pane and the code pane show only while the pointer or keyboard focus is in that pane (picked / half-picked always), the ± counts and the "M" badge go, added / deleted / renamed files get a quiet word. DS synced through #26 (plus the Calm Inspector Study).

## Boundaries & Constraints

**Always:**
- **Folders without chevrons.** Inspector tree folder row (`InspectorFolderRow`): no chevron, the glyph is `ZI.folderOpen` while `folder.open`, else `ZI.folder`; no file-count pill; no summed ±. Projects window (`projects_tree.dart`): the `_Chevron` goes everywhere (group rows, the empty slot of project rows and the naming field) — the group's open / closed folder icon already exists; everything else (count, caps name, •••, keys) unchanged. Click, ←, →, ↩ keep working in both trees.
- **Checkboxes on demand.** A small reveal pair in a new file `app/lib/src/features/graph/inspector_check_reveal.dart`: `InspectorCheckReveal` (wraps a pane: `MouseRegion` enter / exit + a non-focusable, non-traversable `Focus` whose `onFocusChange` reports focus anywhere inside; publishes `revealed = hovered || focusInside` through an `InheritedWidget`) and `InspectorCheck` (wraps one checkbox: opacity 1 when revealed or its value is not `false`, else 0; `AnimatedOpacity` on `ZsMotion.durHover`; outside any reveal scope it always shows, so the operation view, the catalogue and other hosts are unchanged). A hidden box keeps its size, focusability, semantics and hit target (only its opacity changes), so nothing shifts. An `InspectorChecksShown` `InheritedWidget` forces every scope revealed (for the catalogue: Marionette cannot hover).
  - The files pane (the whole `filesPane` column, header's "pick all" included) is one `InspectorCheckReveal`; the code pane (`InspectorDiffView` in `_ChangesState.build`) is another. So hovering one pane reveals only its boxes; Tab into the file list (its roving `_focus`) reveals the file boxes.
  - Wrap every pick checkbox: files header "pick all", folder rows, file rows; in `inspector_diff.dart` the hunk-header box, part boxes (`_partBox`), fold boxes (`_foldBox`) and the mode box. Not the Viewed toggle (a labelled toggle, not a pick box).
- **Reserved checkbox column (design `.cs-gut`).** When `pickable`, file and folder rows start with a 22 px gutter holding the centred checkbox at the row's left edge (not indented); the indent follows the gutter: folder 14 × depth, file in the tree 14 × depth + 20 (the folder glyph 14 + gap 6, so names align), flat file none. Inside the indent the glyph / name / word sit 6 apart. Not pickable (immutable change, operation view): no gutter, left padding 8 as today. Row height, radius, current / ring / Viewed look unchanged.
- **No counts.** Remove the files header's `+N −M` (the file count stays), the file rows' and folder rows' ±. `InspectorViewModel.totals` and `InspectorFileRow.summary` go if nothing else uses them (the composer's counts and the hunk header's counts stay).
- **No status letter.** `_StatusBadge` goes. After the name: added → "new" (`--add`), removed → "deleted" (`--rem`), both 10.5 px sans at .85 opacity (design `.cs-new`); renamed / copied → "from <old>" in `--text-faint` 10.5 px sans, `<old>` = the old path's file name when the folder is unchanged, else the whole old path. Modified: nothing. (`FileChangeKind` has no mode / type kind; nothing to keep there.) The word follows the name in both tree and flat (flat: before the folder) — `InspectorPathLabel` gains an optional `note` span appended to its name part (it gives way with the name). Strings through `app_en.arb` (+ `flutter gen-l10n`), e.g. `inspectorFileNew`, `inspectorFileDeleted`, `inspectorFileFrom(old)`. The row tooltip stays (`old → new`).
- **Operation view** (`operation_changes.dart`) reuses `InspectorFileRow`: it follows the badge / count / word changes automatically; drop its `summary:` argument. It has no checkboxes and no tree.
- Zs controls and DS tokens only; tests never touch Ralph's settings or jj config.
- **DS** through `design-artifacts` C / E, no publish: `FileRow.{jsx,d.ts,prompt.md}` (no `status` badge for M, the quiet word / `from`, no counts, folder row: open / closed glyph, no chevron, no count; the 22 px reserved check gutter), `ProjectRow.{jsx,prompt.md}` (no chevron / chevron slot), `content.css` (drop `.zs-file-status`, `.zs-file-chev`, `.zs-file-count`, `.zs-file-stat`, `.zs-proj-chev` rules or their use; add the quiet word and the on-demand rule: unchecked boxes at opacity 0 unless the pane is hovered / has focus-within), card `content.card.html`, `_ds_bundle.js` blocks for both components (+ `sourceHashes`), readme Sync line, and a dated line `- 2026-11-15 (Story 10.42) — …` appended at the end of `design/DESIGN-SYSTEM-SYNC.md`. Do not touch the study files.

**Never:**
- The hunk header, part-box placement, gap / context rows, the pick bar on hover (all Story 10.43); changing the file options menu.
- Other trees or lists of the app; the composer's counts.
- Removing a hidden box from layout or semantics (it would shift rows / break keyboard picks); hiding boxes on an immutable change differently from today (none).
- Publishing the DS artifact, syncing a canvas, the Marionette check (the console session's).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Folder open / closed | tree, folder `lib/` expanded, then ← | open glyph, no chevron, no count; ← → closed glyph; ↩ / click toggle | — |
| Pointer outside panes | mutable change, file `a` picked whole, folder half-picked, others unpicked | `a`'s and the folder's boxes at opacity 1, every unchecked box at 0, rows at the same x as with the pointer inside | — |
| Hover files pane | mouse enters the files list | its unchecked boxes 1, the code pane's unchecked boxes stay 0 | — |
| Hover code pane | mouse enters the diff | its hunk / part boxes 1, the files pane's stay 0 | — |
| Keyboard | Tab / focus into the file list | file boxes 1 while focus is inside; leaving → 0 | — |
| Immutable | change not selectable | no boxes, no gutter (as today) | — |
| Quiet word | added, removed, modified, renamed `a/x.dart`→`a/y.dart`, renamed `a/x.dart`→`b/x.dart` | "new", "deleted", nothing, "from x.dart", "from a/x.dart"; no letter badge, no ± | — |
| Header | 3 files with summary | "3 files", no `+N −M` | refused summary: unchanged note |
| Operation view | file rows | no badge, no ±, quiet words; no boxes | — |
| Projects window | groups, one collapsed | no chevron, folder-open / folder glyph, click / → / ← toggle | — |
| Catalogue | `InspectorChecksShown` above the inspector | every box at opacity 1 | — |

</intent-contract>

## Code Map

- `app/lib/src/features/graph/graph_inspector.dart` -- `_ChangesState._row` `:2919-2951` (drop `added`/`removed`/`summary`), `build` files header `:2989-3042` (drop totals spans; wrap `ZsCheckbox` "pick all" `:3003`), filesPane `:2994` and diffPane `InspectorDiffView` `:3156` (wrap each in `InspectorCheckReveal`); `InspectorFileRow` `:3262-3403` (gutter layout, `InspectorCheck`, quiet word, drop badge, ±, `summary`); `_StatusBadge` `:3405-3430` (delete); `InspectorFolderRow` `:3432-3549` (gutter, open/closed glyph, drop chevron, pill, ±, `added`/`removed`); `InspectorViewModel.totals` `:172-182` (delete if unused); doc `:1179` mentions totals. Keep `pickedStat` / composer `:3843-3861`.
- `app/lib/src/features/graph/inspector_path_label.dart:24-53` -- optional `note` `InlineSpan` appended to the name part.
- `app/lib/src/features/graph/inspector_diff.dart` -- wrap pick boxes in `InspectorCheck`: mode `:1026`, hunk header `:1667`, `_partBox` `:1749`, `_foldBox` `:1803`. Do not touch the Viewed toggle `:1218` or the hunk header's text/counts.
- `app/lib/src/features/graph/inspector_check_reveal.dart` -- new: `InspectorCheckReveal`, `InspectorCheck`, `InspectorChecksShown`.
- `app/lib/src/features/projects/projects_tree.dart` -- `_Chevron` `:1252-1277` and its uses `:1313`, `:1391`, `:1579` go; library doc `:23`, `:42` reworded.
- `app/lib/src/features/undo_timeline/operation_changes.dart:907-912` -- drop `summary:`.
- `app/lib/l10n/app_en.arb` (near `inspectorFileCount` `:676`) -- new strings; `flutter gen-l10n`, commit the output.
- `app/widgetbook/folders/graph.dart:321-335` -- `Inspector` use cases (`_InspectorAt`): a `checkboxes shown` boolean knob on Wide and Tree wrapping in `InspectorChecksShown`.
- Tests: `app/test/features/graph/graph_inspector_test.dart` (`:1209` 'D' badge, `:1492-1508` meta and row counts, `:2062-2087` refused summary, folder-row / chevron / pill tests — update to the new look), new tests for reveal (mouse gesture `PointerDeviceKind.mouse` per pane, focus, no x-shift, picked always shown), quiet words, open/closed glyph; `app/test/features/undo_timeline/operation_changes_test.dart` (row counts if asserted); `app/test/features/projects/` tree tests (no `ZI.chevronRight`, folder glyph toggles); `inspector_diff_test.dart` hunk counts `:710`, `:1523` stay.
- DS: `_bmad-output/implementation-artifacts/design_system/components/content/{FileRow,ProjectRow}.{jsx,d.ts,prompt.md}`, `content.css:2-25,145-149`, `content.card.html`, `_ds_bundle.js` blocks `:276` (ProjectRow) and `:1841` (FileRow), `readme.md:18-22` Sync; `design/DESIGN-SYSTEM-SYNC.md` (append). Reference look: `design/calm-study.css` (`.cs-gut`, `.cs-row`, `.cs-ind`, `.cs-new`, `.cs-group`), `calm-study.jsx:206-249, 401-428`.

## Tasks & Acceptance

**Execution:**
- `app/lib/src/features/graph/inspector_check_reveal.dart` -- create the reveal scope, the per-box wrapper and the forcing widget -- one mechanism for both panes.
- `app/lib/src/features/graph/inspector_path_label.dart` -- `note` span on the name part -- the quiet word gives way with the name.
- `app/lib/src/features/graph/graph_inspector.dart` -- rows, header, panes as in the Code Map -- items 1–4.
- `app/lib/src/features/graph/inspector_diff.dart` -- wrap the four pick boxes -- item 2 in the code pane.
- `app/lib/src/features/projects/projects_tree.dart` -- remove `_Chevron` -- item 1 in the Projects window.
- `app/lib/src/features/undo_timeline/operation_changes.dart` -- drop `summary:` -- item 5.
- `app/lib/l10n/app_en.arb` + `flutter gen-l10n` -- the quiet words.
- `app/widgetbook/folders/graph.dart` -- the knob -- hover-only surface visible in the catalogue.
- Tests per matrix row (widget tests; the reveal tests hover with a mouse gesture and read the `AnimatedOpacity` above each `ZsCheckbox`).
- DS per Boundaries (C / E, no publish) and the DESIGN-SYSTEM-SYNC dated line.

**Acceptance Criteria:**
- Given a mutable change with a tree of files in the inspector and no pointer over it, when nothing is hovered or focused, then no unchecked box is visible, picked / half-picked boxes are, and hovering either pane reveals only that pane's boxes without moving any row.
- Given the inspector's files pane, when it renders, then no row or header shows `+N` / `−M`, no row shows a status letter, an added file reads "new" after its name, and a folder row shows the open glyph while expanded and the closed glyph while collapsed with no chevron and no count.
- Given the Projects window, when groups render, then none shows a chevron and clicking or ← / → toggles the folder glyph.
- Given the Undo Timeline's operation view, when its file rows render, then they show no badge, no ± and the quiet words.

## Spec Change Log

## Review Triage Log

### 2026-11-15 — Review pass
- verdicts: 30 findings — high 0, medium 6, low 14, false 6, maybe-false 4
- findings:
  - `[low]` `[patch]` (verification-gap) the 22 px check column and the tree indents have no geometry test — added a tree-mode test: box centre = row left + 11 for folder and file rows; a file's name x = the name x of a sibling folder at the same depth (a file sits one level below its parent folder, as the spec's 14 × depth + 20 and `calm-study.jsx:192-197` give), one level deeper is 14 px further in.
  - `[medium]` `[patch]` (verification-gap) part / fold / mode boxes are wrapped in `InspectorCheck` but never asserted hidden or revealed — added a part-box test: opacity 0 with the pointer outside, 1 while the code pane is hovered.
  - `[low]` `[patch]` (verification-gap) "a hidden box keeps its semantics" passes on the row's own `Semantics(label: path)` — the test now asserts the checkbox's own semantics node.
  - `[medium]` `[patch]` (edge-case) DS `content.css:33-34`: the reveal rule (0,3,0) loses to the hide rule (0,4,0), so unchecked DS boxes never reappear — reveal selector made at least as specific.
  - `[maybe-false]` `[reject]` (edge-case) the row's context menu could take focus out of the reveal scope and fade the boxes — `_openMenu` requests the list focus and the anchor's overlay sits under the pane's element (focus) tree; would need a run with the menu open to settle; if true only cosmetic (low).
  - `[low]` `[patch]` (edge-case) test `pump` ignores `checksShown` when `windowActions` is set — that branch is wrapped too.
  - `[medium]` `[patch]` (edge-case) the DS kit `ui_kits/desktop/inspector.jsx:326,340,345` still passes `count`/`added`/`removed` (stray DOM attributes) and shows header totals; `density.card.html:45-47` too — props and totals dropped, kit bundle block and hash updated.
  - `[false]` `[reject]` (edge-case) `InspectorViewModel.summaryOf` is dead after the rows lost ± — the composer still calls it (`graph_inspector.dart:3821`). Its stale doc at `:504` ("rows without ±") is real: `[low]` `[patch]` — reworded (counted in this row).
  - `[medium]` `[patch]` (blind) same root cause as the DS CSS specificity row above — fixed there.
  - `[low]` `[patch]` (blind) the DS `.is-revealed` force class is undocumented — one line in `FileRow.prompt.md`.
  - `[false]` `[reject]` (blind) the reveal "sticks" after a click because pointer focus counts — the approved study does the same: `.cs-files` / `.cs-code` are `tabIndex={-1}` panes (`calm-study.jsx:212`), so a click focuses the pane and `:focus-within` keeps its boxes; the epic's "keyboard focus inside it" is where key events go, which a click sets. Noted under residual risks for Ralph.
  - `[low]` `[patch]` (blind) the "keyboard focus" test reaches focus by a tap, not the keyboard — a Tab-driven test added, plus focus inside the code pane.
  - `[medium]` `[patch]` (blind) most wrapped boxes have no reveal test — same root cause as the part-box row; covered there.
  - `[low]` `[patch]` (blind) gutter / indent geometry untested — same root cause as the first row; covered there.
  - `[low]` `[reject]` (blind) a cross-folder rename's long "from <old path>" keeps the name part long, so the new folder gives way first on a narrow pane — rare (cross-folder rename at narrow width), the tooltip shows `old → new`, and the fix needs a new give-way order in `InspectorPathLabel` (more than a direct correction).
  - `[low]` `[patch]` (blind) copies and source-less renames are untested — a copied file and a rename without `fromPath` added to the quiet-words fixtures.
  - `[medium]` `[patch]` (blind) DS kit and density card still use the removed props — same root cause as the edge-case kit row; fixed there.
  - `[low]` `[patch]` (blind) `_adherence.oxlintrc.json:190-191` lists removed FileRow props and lacks `from` — set to FileRow's current props.
  - `[low]` `[patch]` (blind) DS `FileRow.jsx` decides "same folder" from the `folder` display prop — now derives the folder from `path`.
  - `[low]` `[reject]` (blind) `epic-10-context.md` says 10.42 is open and carries 10.43 material — it is compiled from epics.md at this run's start (10.43's rules are epic-wide constraints), and is regenerated whenever planning changes; nothing in the code reads it.
  - `[maybe-false]` `[reject]` (blind) the Projects window has no click-toggle test and no test that project rows lost the empty chevron slot — click toggling code is untouched by this diff (only `_Chevron` went); would need the existing projects tests' click coverage checked; if true only low.
  - `[low]` `[patch]` (intent) the "Tab into the file list" witness is tested through a tap — same root cause as the blind keyboard row; covered there.
  - `[low]` `[patch]` (intent) keyboard focus inside the code pane is untested — covered by the same added test.
  - `[maybe-false]` `[reject]` (intent) the code-pane hover test hovers `inspector-hunk-header`, which Story 10.43 removes — 10.43 must rewrite that test with the header; no defect in this story.
  - `[low]` `[reject]` (intent) the widgetbook "checkboxes shown" knob is on Wide and Tree, not Narrow — Narrow shows the same rows; the two use cases cover both layouts for Marionette.
  - `[false]` `[reject]` (intent) DS sources edited by hand against the epic-context line "nothing under design_system/ is edited by hand" — that line means "through the design-artifacts skill", whose C / E steps edit `design_system/` in place (`.claude/skills/design-artifacts/SKILL.md:35,43`).
  - `[false]` `[reject]` (intent) "deleted" and "from …" go beyond the study, which draws only "new" — the epic text (Story 10.42 item 4) asks for all three.
  - `[false]` `[reject]` (intent) the check column is reserved only on pickable rows, while the study draws it on every row — the epic's purpose is "nothing moves when boxes appear"; an immutable change never shows boxes ("as today"), so nothing moves.
  - `[maybe-false]` `[reject]` (intent) out-of-story 10.43 content in `epic-10-context.md` and the DS readme note — both describe planning already in epics.md; whether it belongs to this commit is bookkeeping, no behaviour.
  - `[false]` `[reject]` (intent) the intent's "deferred mirror" rule is not exercised — this pass defers nothing, so `deferred: []` and deferred-work.md stay unchanged, as the rule requires.

## Design Notes

- Opacity (not `Visibility`) keeps a hidden box in layout, semantics, focus order and hit testing, like the study's CSS `opacity:0`; a click lands only where the pointer already revealed the box, and VoiceOver / Tab still reach every pick.
- The reveal is per pane, not per row: the study's rule is `.cs-files:hover .gck` / `:focus-within`.
- Rename wording: "from <old name>" per the epic; the full old path only when the folder changed, else the name says nothing new about where it came from.

## Verification

**Commands:**
- `flutter test` in `app/` (targeted: `test/features/graph/graph_inspector_test.dart`, `test/features/graph/inspector_diff_test.dart`, `test/features/undo_timeline/`, `test/features/projects/`) -- expected: all pass.
- `dart analyze` in `app/` -- expected: no issues.
- `dart format --set-exit-if-changed` on `app/lib app/test app/widgetbook` -- expected: exit 0.
- No Rust, FFI or `zanshin_core` change: no cargo checks needed beyond none; the full gate runs at the end of the story loop.

**Manual checks (if no CLI):**
- Marionette against the study: the console session's (not this run).

**Verification notes (this run, 2026-11-15; gate rule: no full gate):**
- `flutter test test/features/graph/graph_inspector_test.dart test/features/graph/inspector_diff_test.dart test/features/undo_timeline test/features/projects/projects_window_test.dart test/features/projects/projects_tree_test.dart test/widgetbook test/l10n` (in `app/`, after the review patches) -- 825 passed.
- The other `test/features/projects/*` files except `worker_project_repos_test.dart` (+ `test/widgetbook`, `test/l10n`), before the patches -- 583 passed. `worker_project_repos_test.dart` needs the pinned environment of `cargo make test-app` (the implementer ran it there: pass).
- `dart analyze` in `app/` -- No issues found.
- `dart format --set-exit-if-changed lib test widgetbook` in `app/` -- 0 changed.
- `node --check design_system/_ds_bundle.js` -- OK; `jq empty _adherence.oxlintrc.json` -- OK (implementer).
- No Rust, FFI, schema or `zanshin_core` change: no cargo, codegen or parity checks apply.

## Auto Run Result

**Status:** done (2026-11-15).

**Summary.** The inspector got calmer, after sections 1 and 3 of `design/Calm Inspector Study.html`: folder rows show open / closed through their glyph only (no chevron, no count pill, no ±), pick boxes in the files pane and in the code pane show only while the pointer or the focus is in that pane (picked / half-picked always; a reserved 22 px check column, so nothing moves), the ± counts and the status letter are gone, and added / deleted / renamed / copied files carry a quiet word ("new", "deleted", "from …"). The Projects window lost its chevrons; the Undo Timeline's operation view follows the file-row changes.

**Files changed.**
- `app/lib/src/features/graph/inspector_check_reveal.dart` -- new: `InspectorCheckReveal` (pane scope: hover + focus inside), `InspectorCheck` (opacity-only box wrapper), `InspectorChecksShown` (catalogue force).
- `app/lib/src/features/graph/graph_inspector.dart` -- rows with the check column, quiet words, open/closed folder glyph; no totals, badge, ±, pill; both panes wrapped.
- `app/lib/src/features/graph/inspector_path_label.dart` -- optional `note` span after the name.
- `app/lib/src/features/graph/inspector_diff.dart` -- mode, hunk, part and fold boxes wrapped in `InspectorCheck`.
- `app/lib/src/features/projects/projects_tree.dart` -- `_Chevron` removed.
- `app/lib/src/features/undo_timeline/operation_changes.dart` -- drops `summary:`.
- `app/lib/l10n/app_en.arb` (+ generated `app_localizations*.dart`) -- `inspectorFileNew`, `inspectorFileDeleted`, `inspectorFileFrom`.
- `app/widgetbook/folders/graph.dart` -- "checkboxes shown" knob on Inspector Wide and Tree.
- Tests: `graph_inspector_test.dart`, `projects_window_test.dart`, `operation_changes_test.dart`.
- DS (C / E, not published): `FileRow.{jsx,d.ts,prompt.md}`, `ProjectRow.{jsx,prompt.md}`, `content.css`, `content.card.html`, `density.card.html`, `guidelines/colors-accents.html`, `ui_kits/desktop/inspector.jsx`, `_ds_bundle.js` (+ hashes), `_adherence.oxlintrc.json`, `readme.md`; dated line in `design/DESIGN-SYSTEM-SYNC.md`.
- `epic-10-context.md` -- recompiled at run start (epics.md had gained 10.42 / 10.43).

**Review findings.** 30 findings: 18 rows patched (medium 6, low 12, several sharing a root cause: DS CSS specificity, kit/density stale props, adherence rule, DS same-folder check, `.is-revealed` doc, stale doc line, test `pump` combination, and tests for geometry, part boxes, Tab focus into both panes, the checkbox's own semantics, copies and source-less renames); 0 deferred; 12 rejected — 6 false (summaryOf still used by the composer; sticky reveal after a click matches the approved study's `tabIndex={-1}` + `:focus-within`; DS edits go through the skill's C / E; "deleted"/"from" are in the epic; no column on immutable rows because no box ever appears there; nothing to mirror), 4 maybe-false (menu focus, Projects click test, 10.43-bound hover test, epic-context bookkeeping) and 2 low not worth the complexity (long cross-folder "from" path on a narrow pane; Narrow use case without the knob). Details in the Review Triage Log.

**Follow-up review recommendation:** false. First pass, no `high` patched; the medium patches were a CSS selector, DS prop clean-ups and added tests, all verified by the targeted run (825 tests pass) — no named unverified risk remains.

**Residual risks.**
- Visual check against the study (Marionette) and the DS publish / canvas sync wait for the console session; the full gate runs at the end of the story loop.
- After a click inside a pane, its boxes stay shown until focus leaves the pane (as in the approved study). If Ralph wants only keyboard-highlight focus to reveal, that is a one-line change in `InspectorCheckReveal`.
- The code-pane hover test hovers the hunk header, which Story 10.43 removes; 10.43 must move it.
