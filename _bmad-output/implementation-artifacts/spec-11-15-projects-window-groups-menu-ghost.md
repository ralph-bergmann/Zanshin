---
title: 'Story 11.15 — Projects window: deselect, naming and renaming groups, the group menu, Move to group › New group…, the drag ghost'
type: 'feature'
created: '2026-10-29'
status: 'done'
baseline_revision: '80800815ac021380169e68f5a16eb0cd10bda16d'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-11-context.md'
warnings: ['multiple-goals', 'oversized']
deferred:
  - summary: >-
      Keyboard focus is not given back after the name field closes (↩ / Esc on Rename… or New group…) or after Delete group removes the focused row.
    evidence: |-
      The field leaves the tree and nothing refocuses a row; Delete group disposes the focused row. 11.6's New group already behaved so (pre-existing pattern); New group selects only after addGroup returns, so focusing the Tab stop at once would re-select the old row — the fix needs the async selection to settle first.
    location: >-
      app/lib/src/features/projects/projects_tree.dart (didUpdateWidget, _startField); app/lib/src/features/projects/projects_window.dart (_deleteGroup)
    severity: low
    resolved: >-
      2026-10-29 — fixed (spec-11-15-closing-focus-back-after-naming-and-delete, commit 934bb72): the tree hands focus back to its Tab stop without selecting it and follows the selection while it stays there.
---

<intent-contract>

## Intent

**Problem:** In 11.6's Projects window a selection can never be cleared (so New group never lands on the top level), New group ignores a selected project's group, groups cannot be renamed, deleted or moved by menu, and a row drag shows only a plain name chip with 11.6's drop look instead of DS #14/#15's rules.

**Approach:** Extend 11.6's tree, window state and registry (`app/lib/src/features/projects/`) with deselect, the group row menu (Rename… · Move to group › · — · Delete group), Move to group › New group… for both kinds, the remaining drag rules and DS drop look, and build the DS `DragGhost` as `ZsDragGhost` (kinds `project`, `group`) in `packages/zanshin_ui`; raise `dsSyncedThrough` to 15.

## Boundaries & Constraints

**Always:**
- epics.md Story 11.15 (:13488-13566) is the requirement; DS sources: `components/content/ProjectRow.prompt.md:11-21`, `content.css:71-82`, `components/overlays/DragGhost.{prompt.md,jsx}`, `overlays.css:41-60`, readme.md:196; the prototype `design/windows.jsx:137-432` (`ProjectsWin`) only where the DS is silent. Precedence: epics decisions > DS tokens/CSS > DS prose > prototype. Open defaults are marked "Claude's proposal" in code docs; DS literals cite `DS <file>:<line>`.
- Selection ids stay 11.6's (`group:<id>`, `project:<path>`). Every registry edit goes through `ProjectRegistry` (one `_update` each, persisted, siblings renumbered 0..n).
- The name field is 11.6's `_NewGroupField` look (TextField sm, chevron slot + folder, row 34 high) for both New group and Rename… (one field at a time; starting one ends the other). Blur rule: a rename keeps what was typed, a new group cancels (also New group…); ↩ commits; Esc cancels; an empty name cancels a new group and keeps a rename's old name. Blur while the app is not resumed decides nothing (11.6's lifecycle guard).
- Move to group › (both kinds): "Top level", then every group by its path ("Work / Mobile") sorted case-insensitively, radio-checked where the row is now; a group's submenu never lists itself or a group inside it; choosing the current place changes nothing; then `ZsMenuSeparator` and "New group…". The moved row ends selected.
- `ZsDragGhost` depends only on what `zanshin_ui` already depends on; every colour/size is a token: chip 34 high, padding 0 12, gap 8, `--radius-card`, `--card-solid-hi`, 1 px `--accent-line` border, `--shadow-drag` (holds the 3 px `--accent-ring`), `--fs-control` 500 `--text`, max width 280, tilted −1.5° × `ZsMotion.motion` (0 under Reduce motion); below it, 8 apart, the words box: padding 7 10, `--radius-chip`, `--tooltip-bg`, `--shadow-tooltip`, `--fs-sm` sans; with a target the border is `--accent-line` and the text `--text`, the hint `--tooltip-border` and `--text-dim`; max width 340. Hidden from semantics; ignores the pointer.
- App and package rules of project-context.md: SPDX first line, width 120, `dart analyze --fatal-infos --fatal-warnings` clean, no Material/Yaru control, no golden tests, app imports only package barrels.

**Never:**
- No undo for list edits, no keyboard moving, no multi-selection, no `change`/`bookmark`/`diff` ghost kinds (10.10), no confirmation for Delete group.
- No change to Add directory / Clone / Finder-drop placement (`_targetGroup` keeps its meaning; item 2 changes only New group's parent).
- No change to `tree_drop.dart`'s public functions; no Rust/FFI/schema change; no edits under `design/` or `design_system/`; no new pub dependency.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Deselect | a row selected; click on the empty tree below the last row | selection null; the Tab stop is the first row; New group's field then sits last at the top level | — |
| New group beside a project | `project:<p>` selected, p in group Mobile | field last inside Mobile (expanded); ↩ "X" → `addGroup('X', parent: Mobile)`, selected | — |
| Rename | group Work, Rename… | field in Work's row, text "Work" all selected; ↩ / blur with "Clients" → `renameGroup(g1,'Clients')`; Esc or "  " → name stays "Work" | — |
| Delete group | Work holds [Mobile(group), api-server] and sits at top-level index 0 before top, gone | top level becomes [Mobile, api-server, top, gone] orders 0..3, Work gone, same project set, selection null | — |
| Move group by menu | Mobile › Move to group | lists "Top level" (unchecked) and "Work" (checked); never "Work / Mobile" | current place → no write |
| New group… on a project | top (top level) › Move to group › New group… | field last at top level; Esc → registry unchanged; ↩ "Mobile2" → group at top level last, `top` inside it at index 0, `project:<top>` selected | — |
| Drag while searching | query non-empty | no drag starts (`maxSimultaneousDrags: 0`) | — |
| Esc during a drag | drag in progress, Esc pressed, then release over a valid target | registry unchanged, ghost and drop look gone; the Esc does not reach other handlers | — |
| Drop below the last row | drag a row into the end zone | moved last at the top level; while hovering, the after-line under the last visible row at indent 0; ghost "To the top level" | — |
| Into an expanded group | pointer anywhere in the lower ¾ of an expanded group with children | placement inside (its last child), fill `--accent-soft` + 1 px `--accent-live-line` border; ghost "Into <name>" | — |
| Over the dragged group's subtree | drag Work over MyApp (inside Work) | no drop look; ghost hint "Drop between rows or on a group"; release changes nothing | — |
| End of a drag | a drag released on a group row | the group is not toggled, the moved row is selected | — |

</intent-contract>

## Code Map

- `_bmad-output/planning-artifacts/epics.md:13488-13566` -- Story 11.15 (scope 1–10, non-goals, witnesses).
- `app/lib/src/features/projects/projects_tree.dart` -- 11.6's tree: ctor callbacks :50-71/:97-128; `_newGroupFocusChanged`/`_commitNewGroup` :262-283 (listener removed around commit); `_tapped` :287; `_placementIn` :460 (quarters/halves via `treeDropPlacement`); `_landing` :468 (refuses self and a group into itself; `registryPlacement`); `_showHover`/`_leave` :484-499; `build` :507 (`_rows` excludes the new-group field; `_tabStop`); `_endTarget` :564 (accepts, shows nothing, min 24 high); `_row` :576; `_itemRow` :594 (focus, semantics, `ZsMenuAnchor` + `onSecondaryTapUp` only for projects :658-673, row `DragTarget` :676-700, `FolderDropTarget` :701); `_draggable` :724 (`pointerDragAnchorStrategy`, `_DragFeedback`, opacity .5); `_openMenu` :739; `_menuEntries` :748 (group path labels, radio items; reuse for groups); `_RowBox` :823 (fill by status — add the into fill/border); `_GroupFace` :888 (add `more`); `_MoreButton` :1083; `_NewGroupField` :1140; `_DragFeedback` :1194 (replace); `_DropPainter` :1216 (into = ring + border today; lines inside the row, full width).
- `app/lib/src/features/projects/projects_tree_model.dart:64-77` -- `ProjectsNewGroupItem(parent)` (add the row being moved for New group…); `projectsTree` :106 places the field last in its parent; `registryMembers` :180; `registryPlacement` :194.
- `app/lib/src/features/projects/tree_drop.dart:23-31` -- `treeDropPlacement` (generic, unchanged); `treeInsertionPoint` :66 (`after` on an expanded parent = its first child — unreachable for groups once the lower part is "into").
- `app/lib/src/features/projects/projects_window.dart` -- `_selected` :146, `_collapsed` :147, `_newGroup` :148; `_targetGroup` :288 (selected group only; also used by Add directory :225 and clone :578/:587 — leave it); `_startNewGroup` :474; `_commitNewGroup` :485; `_end` :498; `_moveItem` :500 (does not select); tree wiring :699-732 (`onMoveToGroup` moves to `_end` even to the current group; `onRemove`).
- `app/lib/src/features/projects/project_registry.dart` -- `addGroup` :161 (last in parent, returns `g<n>`), `move` :184, `moveGroup` :196, `remove` :137 (renumber pattern), `_update` :241, `_place` :248, `_siblings` :284, `_Member` :319.
- `app/lib/src/features/projects/project_status_style.dart` -- `ProjectStatus.colorIn(colors)` for the ghost's dot.
- `packages/zanshin_ui/lib/zanshin_ui.dart:11-61` -- barrel (add `ZsDragGhost`, `ZsDragGhostKind`); new file `packages/zanshin_ui/lib/src/controls/zs_drag_ghost.dart`. Reuse: `ZsColors` (`cardSolidHi`, `accentLine`, `tooltipBg`, `tooltipBorder`, `text`, `textDim`), `ZsElevation` (`shadowDrag` :52-55 = 3 px `accentRing` + drop shadow; `shadowTooltip`), `ZsMetrics` (`radiusCard` 10, `radiusChip` 7), `ZsMotion.motion` (zs_motion.dart:177), `ZsType`, `ZanshinIcon(ZI.folder, ZsIconSize.md)`, `ZsShadowStack.boxShadows` (zs_values.dart:120); `ZsTooltip`'s box (zs_tooltip.dart:295-298) shows the tooltip build.
- `packages/zanshin_ui/lib/src/design/zs_appearance.dart:11-13` and `packages/zanshin_ui/test/design/zs_tokens_test.dart:355-357` -- `dsSyncedThrough` 13 → 15 (DS readme.md:22 "Synced through #15").
- `packages/zanshin_ui/lib/src/controls/zs_menu.dart:29-46` -- `ZsMenuItem` (`checked`, `radio`, `submenu`, `danger`, `identifier`); `ZsMenuAnchor` :172 (`builder(anchor, menu)`, `menu.open(position:)`).
- Tests: `app/test/features/projects/projects_window_test.dart` (`_Rig` :76-194: `pump`, `settle`, `row(name)`, `id(identifier)`; demo :38-73 = Work › (Mobile › MyApp, design-kit), api-server · top · gone; drag pattern `tester.timedDragFrom` :723-825; menu helpers `openMenu`/`choose` :829-840; New group :916-969), `project_registry_test.dart` (temp-dir store pattern), `packages/zanshin_ui/test/controls/` (pattern e.g. `zs_badge_test.dart`; `test/helpers/zs_host.dart`).
- Catalogue: `app/widgetbook/folders/projects.dart:29-82` (`DemoProjectsWindow(setup: (state, home) …)` over `demo_projects_fakes.dart:20-27` groups Work › (Mobile, Backend), Personal), `app/widgetbook/folders/materials.dart` (component pattern for the ghost), `app/test/widgetbook/catalogue_smoke_test.dart:46-59` (required paths list).

## Tasks & Acceptance

**Execution:**
- `packages/zanshin_ui/lib/src/controls/zs_drag_ghost.dart` + barrel export -- `enum ZsDragGhostKind { project, group }`; `ZsDragGhost({required kind, required label, Color? dot, String? target, String? hint})`: the chip (project: the 7 px dot when `dot` is non-null; group: md folder glyph `--text-dim`) and, when `target` or `hint` is non-null, the words box (Boundaries) -- the DS ghost, built by its first user.
- `packages/zanshin_ui/test/controls/zs_drag_ghost_test.dart` -- chip height 34 and width ≤ 280, folder vs dot, target text with the `accentLine` border vs hint with `tooltipBorder`, no words box without either, rotation −1.5° at full motion and none under `ZsMotion` with motion 0, excluded from semantics.
- `packages/zanshin_ui/lib/src/design/zs_appearance.dart`, `packages/zanshin_ui/test/design/zs_tokens_test.dart` -- `dsSyncedThrough = 15`, doc "downloaded 2026-10-29 … synced through #15 … rises when the DS records #16".
- `app/lib/src/features/projects/project_registry.dart` -- `renameGroup(String id, String name)` (unknown id or same name: no write) and `deleteGroup(String id)`: the group's members (its `_siblings`) replace it among its parent's siblings in their order, each re-parented to its parent, renumbered 0..n; the group removed; projects untouched otherwise.
- `app/test/features/projects/project_registry_test.dart` -- rename persists across a reload; delete of a group holding a project and a subgroup splices both at its place in order, renumbers, keeps every project; unknown ids change nothing.
- `app/lib/src/features/projects/projects_tree_model.dart` -- `ProjectsNewGroupItem(parent, {this.moving})` (the row New group… moves into the new group).
- `app/lib/src/features/projects/projects_tree.dart` -- (a) `_endTarget`: a tap clears the selection (`onDeselect`); as a `DragTarget` it shows the end hover — the after-line of the last visible row at depth 0 — and ghost "To the top level"; (b) group rows get `ZsMenuAnchor`, right-click (selects + opens at the pointer) and the ••• (`_MoreButton`, visible on hover / row or button focus, Tab-reachable from the selected row) with entries Rename… · Move to group › · — · Delete group (identifiers `projects-menu-rename`, `-move`, `-delete`); (c) both kinds' Move to group › per Boundaries plus "New group…" (`projects-menu-move-new`), via `onMoveToGroup(ProjectsItem, String?)` and `onNewGroupFor(ProjectsItem)`; (d) `renaming` (group id): that group's row becomes the name field (identifier `projects-rename-group-name`, label "Rename group", text selected, 34 high) sharing one controller/focus with the new-group field, blur per Boundaries, `onRenameCommit(group, name)` / `onRenameCancel`; (e) drag rules: `maxSimultaneousDrags` 0 while searching; while dragging a `HardwareKeyboard` handler takes Esc and marks the drag cancelled (no hover, ghost hidden, accept ignored); dragged row opacity .4; an expanded group with children: top quarter before, the rest inside; (f) feedback = `ZsDragGhost` under a listenable of the current landing's words ("Into <group name>" / "To the top level"; null → hint "Drop between rows or on a group"), offset 14 / 12 from the pointer; (g) look: inside = `_RowBox` fill `accentSoft` + 1 px `accentLiveLine` border (no ring); before/after/end = 2 px `accentLiveLine` line, radius 1, from 8 + 16·depth to 8 from the right, 2 px above the row (before) or 2 px below it (after/end) (DS content.css:75-79); (h) `@visibleForTesting` getter of the current hover (row id, placement, depth) for tests.
- `app/lib/src/features/projects/projects_window.dart` -- New group's parent: a selected group, else a selected project's group, else the top level (new helper; `_targetGroup` unchanged); `onDeselect`; rename state (`_renaming`; starting rename or new group ends the other); `renameGroup`/`deleteGroup` (selection cleared, id dropped from `_collapsed`); Move to group (no-op for the current place; `move`/`moveGroup` to `_end`; select the row); New group… (field with `moving`; commit: `addGroup(name, parent)` then move the row into it at 0, select the row; group-in-progress cancelled on blur/Esc); `_moveItem` selects the moved row; public `renameGroup(String id)` hook for the catalogue state.
- `app/test/features/projects/projects_window_test.dart` -- a test per matrix row and AC (drags with `tester.startGesture`/`moveTo` to read the ghost text mid-drag and `sendKeyEvent(escape)` before `up`).
- `app/widgetbook/folders/projects.dart` (+ smoke-test paths) -- Projects window use cases "Rename group" (setup `state.renameGroup('g1')`) and "Moving" (after the first frame dispatch a mouse `PointerDownEvent` on row "workers" and `PointerMoveEvent`s to the middle of "PERSONAL", never released, so the ghost and the into-look show); `app/widgetbook/folders/materials.dart` component "Drag ghost" use case "Kinds" (project with target, group with target, project with hint).
- Tracking (finalize): `deferred-work.md` mirror, `epic-11-context.md` (11.15 done), `sprint-status.yaml` (11-15).

**Acceptance Criteria:**
- Given the Projects window, when a group row is hovered or the row or its ••• has focus, then its ••• shows; Tab from the selected group row reaches it; a right-click on a group row selects it and opens the same menu at the pointer.
- Given a drag over Work's middle (expanded, with children), between `top` and `gone`, below the last row, and over the dragged group's own subtree, then the ghost reads "Into Work", "To the top level", "To the top level" and "Drop between rows or on a group" respectively, and only the valid ones show a drop look.
- Given `ZsDragGhost`, when rendered in night and paper, then its chip, words and hint follow the DS `DragGhost` (Boundaries), and under Reduce motion it is upright.
- Given the changed packages, when `flutter test`, `dart analyze --fatal-infos --fatal-warnings` and `dart format --output=none --set-exit-if-changed .` run in `packages/zanshin_ui` and `app/`, then all pass (the DS parity test included, confirming #14/#15 add no tokens).
- Given the catalogue, when Projects › Projects window › Tree (group menu via right-click, its Move to group submenu), › Rename group and › Moving, and Materials › Drag ghost are opened via Marionette in night and paper, then the screenshots match the DS cards Content and Overlays (Claude's visual check; what could not be seen is recorded).

## Spec Change Log

## Review Triage Log

### 2026-10-29 — Review pass
- verdicts: 34 findings — high 0, medium 2, low 21, false 11, maybe-false 0
- findings:
  - `[false]` `[reject]` (intent 1) Reading B, the Marionette visual check, is not done — done by the run after the implementation: Materials › Drag ghost › Kinds, Projects window › Moving (held drag, "Into Personal", fill + live-line border), the group menu with its Move to group submenu (right-click on BACKEND) and Rename group (paper) were screenshotted; see Verification.
  - `[low]` `[patch]` (intent 2) The deferred-work section uses another heading/shape than the run's mirror rule, and the spec records no check outcomes — rewritten at finalize under "## Surfaced in Story 11.15 (bmad-build-auto, 2026-10-29)" mirroring `deferred:`; outcomes recorded in Auto Run Result.
  - `[false]` `[reject]` (intent 3) Item 10's DS parity test not shown to run — it runs in `cargo make test-ui` (421 tests, all passed, ds_parity_test included).
  - `[low]` `[patch]` (blind 1 / intent) Starting New group while renaming drops the typed rename (the header button takes no focus, so no blur commits) — the tree commits the captured text post-frame when the field switches from a rename to a new group.
  - `[low]` `[patch]` (blind 2) `deleteGroup` reads the group's parent outside the `_update` closure — the lookup moved inside the closure; a gone group returns the registry unchanged.
  - `[low]` `[patch]` (blind 3 / intent) After Esc the dragged row stays at 40 % until release — the opacity drops back once the drag is cancelled; the Esc test asserts it.
  - `[false]` `[reject]` (blind 4 / intent) Arrow cursor during a drag has no code — no Zs or tree widget sets another cursor: `ZsControlCore` defaults to `SystemMouseCursors.basic`, the feedback is `IgnorePointer`, `DragTarget` sets none; nothing to change.
  - `[low]` `[defer]` (blind 5) Focus not returned after naming/deleting — pre-existing with 11.6's New group; the fix waits for the async selection; deferred and mirrored.
  - `[low]` `[reject]` (blind 6) A click below the rows leaves focus on the old row — focus stays in the list as in Finder; arrows continue from there; changing it adds focus routing for no named harm.
  - `[low]` `[reject]` (blind 7) The after-line overlaps the next row by 1 px — only a selected next row's translucent fill can cover one of the line's two pixels; the held-drag screenshot shows the line fine; fix would move painting to the tree.
  - `[low]` `[reject]` (blind 8) The registry accepts empty/duplicate group names — the UI trims and refuses empty names; duplicates are not excluded by the intent (11.6's addGroup behaves the same); adding a guard adds a rule nobody asked for.
  - `[low]` `[patch]` (blind 9) Untested paths: New group… on a group, top quarter of an expanded group — tests added (with VG 1); offset/shadow/fill asserts left to the visual check.
  - `[low]` `[reject]` (blind 10) The catalogue's Moving use case is fragile / releases the held pointer post-frame — catalogue-only; the app suite and smoke test pass after it; the visual check shows it works.
  - `[false]` `[reject]` (blind 11 / intent) epic-11-context.md rewritten beyond 11.15 — step-01 of this workflow recompiled the stale context from the planning artifacts (epics.md was newer), as the workflow requires; not an implementation edit.
  - `[false]` `[reject]` (blind 12) sprint-status `last_updated` not bumped — it already reads 2026-10-29.
  - `[low]` `[reject]` (blind 13) `newGroupHeight` now also sizes the rename row; ghost listed under Materials — naming churn only; doc says what it is.
  - `[medium]` `[patch]` (edge 1) `_dragEnded` hangs off `onDragEnd`, which Flutter skips when the Draggable unmounted mid-drag, leaving Esc swallowed window-wide — `_dragEnded` now runs from `onDragCompleted` and `onDraggableCanceled`, which fire regardless.
  - `[low]` `[reject]` (edge 2) Typing a search during a drag — keyboard input while a mouse drag is held; the drop then lands at the filtered placement 11.6's `registryPlacement` already supports.
  - `[low]` `[patch]` (edge 3) `_startField`'s post-frame callback touches `_nameFocus` before checking `mounted` — the `mounted` check comes first.
  - `[medium]` `[patch]` (edge 4) A row moved into a collapsed group ends selected but invisible; DS says a drop into a group expands it — `_moveItem` expands the destination and its ancestors; test added.
  - `[low]` `[reject]` (edge 5) A rename's text is lost if the window closes mid-rename — committing from `dispose` would call the parent during unmount; rare.
  - `[low]` `[reject]` (edge 6) A drag while a group is being renamed has no drop target on that row — the field row is transient and the user is typing; rare.
  - `[low]` `[patch]` (edge 7) A project ghost without a dot keeps an 8 px gap — collection-if; test asserts the 12 px inset.
  - `[false]` `[reject]` (edge 8) The Esc mechanism differs from the spec's wording — behaviour matches the matrix; a plain HardwareKeyboard handler cannot stop the Esc reaching the focus tree (Design notes record the early handler).
  - `[low]` `[patch]` (VG 1) The top quarter of an expanded group with children is untested — test: `gone` dropped on WORK's top edge shows "before"/"To the top level" and lands at top-level order 0.
  - `[low]` `[reject]` (VG 2) Esc with no primary focus is untested — `FocusManager` keeps a primary focus (an unfocus parks it on the scope), so `_hardwareKey`'s branch is near-unreachable; a test would need to fake that state.
  - `[low]` `[reject]` (VG other) The ghost's dot and the into fill not asserted through the tree — seen in the held-drag screenshot; the fill is `_RowBox`'s single branch.
  - `[low]` `[reject]` (intent) ••• focus visibility of group rows not asserted — the shared `_MoreButton` (11.6, tested for project rows) shows on `focusVisible`/focus; Tab reaching it is tested.
  - `[low]` `[patch]` (intent) New group… inside an existing group / on a group row untested — covered by the new group-row test (MOBILE › New group… inside Work).
  - `[false]` `[reject]` (intent) The witness "Into Backend" is not in the app fixture — the tests read the same rule as "Into Work"/"Into Mobile"; the catalogue shows Backend.
  - `[false]` `[reject]` (intent) The hint box border is not moon — DS `.zs-ghost-cmd` takes `--accent-line` only with `.is-on` (a target); the hint keeps `--tooltip-border`.
  - `[false]` `[reject]` (intent) "Esc cancels" might mean the drag really ends — Flutter's Draggable cannot be ended from outside; observably the drag is cancelled (no ghost, look or drop), the 40 % now also returns.
  - `[false]` `[reject]` (intent) The 28 px field — Design note "Field size": DS TextField sm (30) wins over the prototype.
  - `[false]` `[reject]` (intent) Static tilt vs "no tilt animation" — the DS tilt is static (`rotate:-1.5deg`); scaling it by `--motion` is the token layer's rule for rotation under Reduce motion.

## Design Notes

**Field size.** epics.md item 4 says "the 28 px field" (the prototype's `.zpw-name`); the DS says TextField sm (ProjectRow.prompt.md:17), which is 30 in the DS and in `ZsTextFieldSize.sm`. Precedence DS > prototype, and 11.6's new-group field already uses sm in a 34 row, so rename uses the same row (Claude's reading).

**Esc during a drag.** Flutter's `Draggable` cannot be cancelled from outside; Esc marks the drag cancelled: drop looks and the ghost vanish and the drop is ignored, while the (invisible) drag lasts until the button is released — observably the same as the DS's "Esc cancels".

**Ghost words.** The landing's registry parent names it: inside / before / after a row → its parent group ("Into <name>", the stored name, not caps) or "To the top level" (prototype windows.jsx:320-321).

**Drag threshold.** The DS's 4 px threshold is not in item 7's list; `Draggable`'s recognizer starts a mouse drag after 1 px (Flutter `kPrecisePointerHitSlop`), as 11.6 shipped — left as is.

## Verification

**Commands (gate rule of this run: no `cargo make test`):**
- `flutter test` in `packages/zanshin_ui` and `app/` (PATH incl. `~/development/sdks/flutter/bin`) -- expected: all pass.
- `dart analyze --fatal-infos --fatal-warnings` and `dart format --output=none --set-exit-if-changed .` in `packages/zanshin_ui` and `app/` -- expected: clean.

**Manual checks:**
- Claude's visual check: `flutter run -d macos -t widgetbook/main.dart` in `app/` (detached, log to the scratchpad), Marionette connect, open the use cases of the last AC (and Windows › Projects window), screenshot night/paper, compare with the DS cards Content and Overlays rendered over `design-system-preview`; record seen / not seen in the Auto Run Result.

**Outcomes (2026-10-29, gate rule of this run — no `cargo make test`/`test-full`/`coverage`):**
- `cargo make --allow-private test-ui` (flutter test in `packages/zanshin_ui`, DS parity test included): exit 0, 421 tests passed.
- `cargo make --allow-private test-ui-analyze` / `test-ui-format`: exit 0 / exit 0.
- `cargo make --allow-private test-flutter` (flutter test in `app/`, the gate's pinned env): exit 0, 878 tests passed (after the review patches; 875 before).
- `cargo make --allow-private test-dart-analyze` / `test-dart-format` (`app/`): exit 0 / exit 0 (one `specify_nonobvious_local_variable_types` info in the catalogue fixed on the way).
- No Rust, FFI or schema change: no cargo test/clippy/fmt/codegen/parity run needed.
- Visual check (Marionette 0.7 on the catalogue): Materials › Drag ghost › Kinds (night): project chip with dot + "Into Backend", group chip with folder + "To the top level", project + hint — chip, tilt, moon/accent border and the tooltip-built words box as DS overlays.css:41-60. Projects › Projects window › Moving (night): the held drag of "workers…" over PERSONAL — row in hand at 40 %, PERSONAL with the `--accent-soft` fill and live-line border, ghost "Into Personal". Tree (night): right-click on BACKEND selects it and opens Rename… · Move to group › · Delete group; the submenu lists Top level, Personal, Work (checked), Work / Mobile, — · New group… (no "Work / Backend"). Rename group (paper): Work's row is the field with "Work" selected. Compared against the DS CSS values cited in code (content.css:66-82, overlays.css:41-60), not against side-by-side renders of the DS cards. Not seen: the ghost in the real Windows › Projects window (Marionette taps reach the catalogue view only), the cursor during a drag (no API).

## Auto Run Result

Status: done (2026-10-29). Blocking condition: none.

**Summary.** The Projects window now matches DS #14/#15: a click below the rows clears the selection; New group goes into a selected group, else beside a selected project (its group), else at the end of the top level; group rows get ••• (hover / focus, Tab from the selected row) and right-click with Rename… · Move to group › · — · Delete group; Rename… puts the shared name field (TextField sm, 34 row) in the group's row with the name selected (↩ / blur keep, Esc / empty keep the old name; starting New group mid-rename commits the typed name); Delete group splices its members into its place; Move to group › works for both kinds (path labels, current place checked and a no-op, never the group itself or its subtree) and ends with New group…, which creates the group where the row is and moves the row in, selected. Dragging: none while searching, Esc cancels (ghost, look and drop gone, row back to full opacity), the row in hand at 40 %, an expanded group with children takes its lower ¾ as "into", a drop into a group expands it (and its ancestors), below the last row is the end of the top level (line at indent 0), every move selects the moved row; "into" is `--accent-soft` + 1 px live-line border, lines 2 px above/below at the target indent. The pointer carries the new `ZsDragGhost` (zanshin_ui, kinds project/group) with "Into ‹group›" / "To the top level" / the hint. `ProjectRegistry` gains `renameGroup` / `deleteGroup`; `dsSyncedThrough` is 15.

**Files changed.**
- `packages/zanshin_ui/lib/src/controls/zs_drag_ghost.dart` (new) + `lib/zanshin_ui.dart` export -- `ZsDragGhost`, `ZsDragGhostKind`.
- `packages/zanshin_ui/test/controls/zs_drag_ghost_test.dart` (new) -- chip, words/hint, tilt × motion, semantics, inset without a dot.
- `packages/zanshin_ui/lib/src/design/zs_appearance.dart`, `test/design/zs_tokens_test.dart` -- `dsSyncedThrough` 15.
- `app/lib/src/features/projects/project_registry.dart` -- `renameGroup`, `deleteGroup` (lookup inside the update).
- `app/lib/src/features/projects/projects_tree_model.dart` -- `ProjectsNewGroupItem.moving`.
- `app/lib/src/features/projects/projects_tree.dart` -- deselect/end target, group menu and •••, Move to group › New group…, rename field, drag rules, Esc cancel, ghost feedback, DS drop look; focus listener selects only on arrival.
- `app/lib/src/features/projects/projects_window.dart` -- New group's parent, rename/delete wiring, Move to group (no-op at the current place), New group… commit, moves select and expand the destination, `renameGroup(id)` hook.
- `app/test/features/projects/{project_registry_test,projects_window_test}.dart` -- Story 11.15 groups (every matrix row, the review's added cases); three 11.6 expectations updated (Tab reaches a group's •••, the into look, the field's focus label).
- `app/widgetbook/folders/{projects,materials}.dart`, `app/test/widgetbook/catalogue_smoke_test.dart` -- Projects window › Rename group / Moving, Materials › Drag ghost › Kinds.
- Tracking: this spec, `deferred-work.md` ("Surfaced in Story 11.15 (bmad-build-auto, 2026-10-29)": 1 item), `epic-11-context.md` (recompiled at step 1 from the newer epics.md; 11.15 done), `sprint-status.yaml` (11-15 done).

**Review findings.** 34 findings (high 0, medium 2, low 21, false 11). Patched 11 entries (2 medium: drag cleanup skipped when the row unmounts mid-drag; a move into a collapsed group leaving the row invisible — 9 low: rename dropped by New group, `deleteGroup` lookup, opacity after Esc, `_startField` mounted check, ghost gap without a dot, the mirror heading, three test gaps). Deferred 1 (low, mirrored): keyboard focus not returned after naming / Delete group. Rejected, with reasons in the triage log: focus left on the old row after deselect, the 1 px line overlap, name validation in the registry, the catalogue's held pointer, typing a search mid-drag, losing a rename when the window closes, dropping on a rename row, the null-focus Esc branch, untested dot/fill (seen visually), group ••• focus visibility (shared code), the naming churn, and the 11 false findings (visual check and parity test were run; cursor stays basic; the context recompile is the workflow's; `last_updated` already current; mechanism, field size, tilt, hint border and fixture names as designed).

**Follow-up review recommendation:** false — first pass, no high patched; the two medium patches each have a direct witness (the onDragCompleted/onDraggableCanceled wiring is Flutter-documented; the collapsed-group move has a test), so no specific unverified risk remains to name.

**Verification.** See Verification › Outcomes: zanshin_ui 421 tests and app 878 tests pass, analyze and format clean in both; Marionette visual check done on the catalogue.

**Residual risks.** Esc cannot end Flutter's drag itself: after Esc the invisible drag lasts until the button is released. The DS's 4 px drag threshold is Flutter's 1 px for a mouse (Design note). The full gate (coverage step included) runs at the end of the story loop.
