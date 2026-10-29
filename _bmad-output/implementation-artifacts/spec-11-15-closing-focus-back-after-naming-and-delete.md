---
title: 'Story 11.15 closing run — keyboard focus returns to the tree after the name field closes and after Delete group'
type: 'bugfix'
created: '2026-10-29'
status: 'done'
baseline_revision: 'bb70ac73686b5dabc3948a5582793157290488c3'
review_loop_iteration: 0
followup_review_recommended: true
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-11-context.md'
warnings: []
deferred: []
---

<intent-contract>

## Intent

**Problem:** Item 1 of Story 11.15's deferred list: in the Projects window, after ↩ / Esc on the name field (Rename…, New group, New group…) or after Delete group removes the row that held focus, nothing in the tree has keyboard focus — Flutter hands it to the scope's previously focused node (the search, or an older row whose arrival then selects it), so a keyboard user has to Tab back in.

**Approach:** Inside `ProjectsTreeState` only: when the name field (↩ / Esc) or a row holding focus leaves the tree, give focus to the Tab stop after that frame without changing the selection; while focus stays on that handed-back row, it follows the selection, so New group's async `addGroup` (which selects the new group later) ends with focus on the new group's row.

## Boundaries & Constraints

**Always:**
- The selection is never changed by the hand-back: a row focused this way does not select itself (Delete group still clears the selection, epics.md Story 11.15 item 5; New group's Esc with no selection keeps none). Focus that the user moves (arrows, Tab, click) still selects as in 11.6.
- Only focus that was *in* what left is handed back: a blur (click elsewhere) that closes the field keeps focus where the user put it; a Delete group chosen from a menu opened elsewhere (right-click while the search had focus) leaves focus with that opener.
- The hand-back runs after the frame that removed the field / row, so it overrides Flutter's own fallback focus request of that frame (no other row gets focus and selects itself on the way).
- Follow: while the handed-back row still has primary focus, a later selection change moves focus to the newly selected row (once it is built); any user keyboard move or a new name field ends following.
- App rules of project-context.md: SPDX first line, width 120, `dart analyze --fatal-infos --fatal-warnings` clean, no golden tests.

**Never:**
- No change to `projects_window.dart`'s callbacks or state, to `ProjectRegistry`, to the menu (`zanshin_ui`), or to any other 11.15 behaviour (deselect, blur rules, drag).
- No Rust/FFI/schema change; no edits under `design/` or `design_system/`.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Rename ↩ | Work renamed by keyboard, ↩ "Clients" | focus `projects row group:g1`, selection `group:g1` | — |
| Rename Esc | Rename… on Work, Esc | focus on Work's row, name "Work" | — |
| New group ↩ | MyApp selected, New group, ↩ "X" | once `addGroup` lands: focus and selection on X's row | — |
| New group Esc, no selection | click below the rows, New group, Esc | focus on the first row (Work), selection still null | — |
| New group… ↩ | `top` › Move to group › New group…, ↩ "Mobile2" | focus and selection on `top` inside Mobile2 | — |
| Delete group by keyboard | Work selected, Tab to its •••, ↩ opens the menu, Delete group chosen; rows arrowed through before | focus on the first row (Mobile), selection null; no other row selected on the way | — |
| Blur | New group field, then a click into the search | focus stays in the search | — |

</intent-contract>

## Code Map

- `app/lib/src/features/projects/projects_tree.dart` -- all changes. `_focusFor` :309 (the arrival listener selects; add the quiet case); `_prune` :325 (rows leaving: check `_rowFocus[id]`/`_moreFocus[id]` `hasFocus` before removing them — the menu's opener refocus (zs_menu.dart:161-163) has run by that build); `didUpdateWidget` :262 (field closing: `_fieldOf(oldWidget) != null && _fieldOf(widget) == null && _nameFocus.hasFocus`; selection change while following); `_startField` :360 (ends following); `focusTabStop` :300 / `_go` :540 (user moves end following; `_go` selects); `_tabStop` computed in `build` :733; `_reveal` :561; `_indexOf`.
- `packages/zanshin_ui/lib/src/controls/zs_menu.dart:160-163` -- read-only: activation refocuses the opener in a microtask, then runs `onSelected`.
- `app/lib/src/features/projects/projects_window.dart` -- read-only: `_commitNewGroup` :514 (selects only after `addGroup`; with `moving`, `_moveItem` :534 selects the row before the registry move), `_commitRename` :564, `_deleteGroup` :570 (selection null, then `registry.deleteGroup`), tree wiring :770-809.
- `app/test/features/projects/projects_window_test.dart` -- `_Rig` :77 (`focused` :189 = primary focus debugLabel; `key` :191; `settle` :156; `row`, `id`); Story 11.15 group :974 (`openMenu`, `openSubmenu`, `choose`, `selected`, `tree`); keyboard patterns in group 'keys' :305-414 (Tab to the •••); Rename test :1097, Delete test :1148, New group… test :1196. Focus labels: `projects row <id>`, `projects more <id>`, `projects group name`, `projects search`.

## Tasks & Acceptance

**Execution:**
- `app/lib/src/features/projects/projects_tree.dart` -- add the hand-back: a `_handBack()` that after the frame focuses the Tab stop (reveal it), quietly when it is not the selected row, and remembers it as the row following the selection; call it from `_prune` when a leaving row or its ••• has focus and from `didUpdateWidget` when the field closes while it has focus; follow the selection in `didUpdateWidget` while that row keeps primary focus; `_go` and `_startField` end following; the arrival listener skips the select for the quiet request only; update the class doc's **Keys** paragraph -- closes deferred item 1 inside the tree, where focus and selection are already tied.
- `app/test/features/projects/projects_window_test.dart` -- a `group('Story 11.15 closing — focus')` with one test per matrix row (focus label via `rig.focused`, selection via semantics); the Delete test reaches the menu by keyboard after arrowing through rows.

**Acceptance Criteria:**
- Given the matrix rows, when each runs in the widget test, then focus and selection end as stated.
- Given `app/`, when `flutter test`, `dart analyze --fatal-infos --fatal-warnings` and `dart format --output=none --set-exit-if-changed .` run, then all pass.

## Spec Change Log

## Review Triage Log

### 2026-10-29 — Review pass
- verdicts: 24 findings — high 0, medium 5, low 15, false 4, maybe-false 0
- findings:
  - `[medium]` `[patch]` (blind 1) `_quiet` is cleared by a microtask before a deferred request to an off-screen Tab stop arrives, so the hand-back selects that row — Flutter defers `requestFocus` on a node without a parent until it is built; `_quiet` now clears on that id's arrival (and in `_go`); test with the tree scrolled.
  - `[false]` `[reject]` (blind 2) `_fieldKeyed` stays set if ↩ does not close the field — every ↩/Esc path closes it synchronously: `_commitNewGroup`/`_commitRename` call commit or cancel, and the window's handlers clear `_newGroup`/`_renaming` in the same `setState`.
  - `[medium]` `[patch]` (blind 3) The slot-move hand-back in `build` can override `_startField`'s focus request when a field opens the same frame a held row shifts (New group… by keyboard while a search is active — `_startNewGroup` clears the search) — the hand-back is skipped while a name field is open.
  - `[low]` `[patch]` (blind 4) The ↩ tests never assert the field had focus before `enterText` — assertions added.
  - `[low]` `[reject]` (blind 5) A slot change starts following for any focused row — focus then only moves between rows inside the tree, onto the row the window selected, matching the tree's focus = selection rule; splitting the hand-back's follow by cause adds a parameter for no named harm.
  - `[false]` `[reject]` (blind 6) A focused row hidden by a mouse collapse sends focus to the first row — a click on a group selects it before it toggles, so the Tab stop is that group; ← collapses through `_go`; ↩ toggles the focused group itself.
  - `[low]` `[reject]` (blind 7) Focus held on a row's ••• comes back on the row after a slot move — before this run it was lost entirely; the row is the tree's Tab stop and selected; a separate ••• branch adds code for a rare keyboard Move to group.
  - `[low]` `[reject]` (blind 8) Tests missing for "a menu opened elsewhere keeps its opener", "a user move ends following", a slot-shift hand-back — the follow guard gets a test (verification-gap 1); the opener case is the menu's own refocus (zanshin_ui tested), the rest is covered by the New group… ↩ test (slot shift) and `_go`'s one-line reset.
  - `[low]` `[patch]` (blind 9) `expectNothingSelected` can pass checking nothing — it now expects at least one row checked; "on the way" is caught at the end because a stray select sticks in the window's `_selected`.
  - `[low]` `[reject]` (blind 10) The New group ↩ test hard-codes `g3` and hand-calls a matcher — the same pattern as 11.15's New group test (projects_window_test.dart:1062); the demo fixture fixes the ids.
  - `[low]` `[reject]` (blind 11) Focus side effects are scheduled from `build` and `_held` scans every row — `_prune` already schedules post-frame work from `build`; slot identity is only known once `build` computes the rows; the scan is over visible rows only.
  - `[low]` `[reject]` (blind 12) The implementation drifted from the spec's `_prune` hook and test-group name — the fix is editing this spec; the reason (a moved row loses focus too) is recorded in Auto Run Result.
  - `[medium]` `[patch]` (edge 1) Same as blind 1 (deferred attach after `_quiet` cleared) — same fix.
  - `[low]` `[reject]` (edge 2) Same as blind 7 (••• focus returns on the row).
  - `[medium]` `[patch]` (edge 3) Same as blind 3 (field opening the same frame) — same fix.
  - `[medium]` `[patch]` (edge 4, claim) "The hand-back never changes the selection" breaks for an unbuilt row — same root cause as blind 1; same fix.
  - `[low]` `[patch]` (edge 5, claim) "Only focus that was in what left" — keyboard New group… on a filtered tree loses the field's focus — same root cause as blind 3; same fix.
  - `[low]` `[patch]` (verification-gap 1) The follow guard (`hasPrimaryFocus` of the handed-back row) is untested — test: hand-back, click into the search, a window-driven selection change, focus stays in the search.
  - `[low]` `[reject]` (intent 1) The trigger surface is wider than the intent (any focused row that leaves or moves slot) — the New group… ↩ case needs it (the moved row's element builds another row and focus is lost); documented in the class doc.
  - `[low]` `[reject]` (intent 2) Rename / New group tests open the field by mouse — the hand-back keys on the field's ↩ / Esc, not on how it opened; the Delete test takes the keyboard Tab → ••• path.
  - `[low]` `[reject]` (intent 3) Boundaries without a test (opener elsewhere, following ending) — as blind 8.
  - `[low]` `[reject]` (intent 4) The Delete test checks selection only at the end — as blind 9.
  - `[false]` `[reject]` (intent 5) No `## Auto Run Result` and uncommitted — written and committed at finalize.
  - `[false]` `[reject]` (intent 6) The window's `_deleteGroup` named by the ledger is unchanged — the effect is reached in the tree (Design note "Why in the tree"); the Delete test passes through the window.

## Design Notes

**Why in the tree, not the window.** The ledger points at `_deleteGroup` too, but the window knows neither whether focus was in the field (↩ / Esc vs blur) nor where the menu returned focus; the tree knows both. Following the selection covers the async New group without the window calling back.

**Why after the frame.** A focused node that unmounts asks Flutter to focus the scope's previously focused child in a microtask; a request from a post-frame callback replaces that pending target before the microtask applies it, so no stale row gets focus (and selects itself).

**Quiet focus.** A focused row without a selection already exists after a click below the rows (11.15 review, rejected blind 6); the hand-back uses the same state instead of selecting the first row, which would contradict "Delete group … the selection clears".

## Verification

**Commands (gate rule of this run: no `cargo make test` / `test-full` / `coverage`):**
- `cargo make --allow-private test-flutter` (flutter test in `app/`) -- expected: exit 0.
- `cargo make --allow-private test-dart-analyze` / `test-dart-format` (`app/`) -- expected: exit 0.

**Outcomes (2026-10-29, gate rule of this run — no `cargo make test` / `test-full` / `coverage`):**
- `cargo make --allow-private test-flutter`: exit 0, 888 tests passed after the review patches (885 before them; 878 at Story 11.15's end).
- `cargo make --allow-private test-dart-analyze`: exit 0, no issues. `test-dart-format`: exit 0, 0 files changed.
- No Rust, FFI, schema or `zanshin_ui` change: no cargo test/clippy/fmt/codegen/parity or `test-ui` run needed.
- No Marionette visual check: the change is focus-only and paints nothing new; the widget tests read the primary focus's label and the selection semantics.

## Auto Run Result

Status: done (2026-10-29). Blocking condition: none.

**Items.**
1. Keyboard focus not given back after the name field closes or after Delete group — **fixed** (commit `934bb724121d267f59c2062cb68512db9962f18e`).

**Summary.** `ProjectsTreeState` hands keyboard focus back to the tree: after ↩ / Esc on the name field (Rename…, New group, New group…), and when the row (or its •••) holding focus leaves the tree (Delete group) or moves to another slot (a row moved into a new group), focus goes to the Tab stop — or the moved row — after the frame, overriding Flutter's fallback to an older focused node, without selecting it; while focus stays there it follows the selection, so New group ↩ ends on the new group once `addGroup` has selected it. A click elsewhere closing the field leaves focus where it went; the hand-back is skipped while a name field opens. `projects_window.dart` is unchanged.

**Deviations from the Code Map.** ↩ needs a flag (`_fieldKeyed`): the text field gives up focus on the done action before the tree rebuilds, so `_nameFocus.hasFocus` is already false. The leaving-row check sits in `build` (the focused row's slot before and after), not in `_prune`: in New group… ↩ the moved row's old element builds another row and focus was lost, which `_prune` cannot see.

**Files changed.**
- `app/lib/src/features/projects/projects_tree.dart` -- `_handBack`, quiet arrival (`_quiet`), selection following (`_following`), `_fieldKeyed`, the held-row slot check in `build`, Keys doc.
- `app/test/features/projects/projects_window_test.dart` -- group `Story 11.15 closing — focus`: the 7 matrix rows, an off-screen hand-back, New group… by keyboard during a search, the follow guard.
- Tracking: this spec; `deferred-work.md` (the 11.15 item annotated as fixed; no new deferrals, so no new section).

**Review findings.** 24 findings (high 0, medium 5, low 15, false 4). Patched: 2 medium entries (a deferred focus arrival on an unbuilt row selected it — `_quiet` now clears on arrival; the slot-move hand-back could steal focus from a field opening the same frame — skipped while a field is open) and 3 low (field focus asserted before typing, `expectNothingSelected` must check a row, the follow-guard test). Deferred: none. Rejected with reasons in the triage log: `_fieldKeyed` staleness, focus after a mouse collapse and the intent auditor's Auto Run Result / window-location notes (false); following started by any slot move, ••• focus returning on the row, missing tests for the menu-opener case, the hard-coded `g3`, side effects scheduled from `build`, the spec drift, mouse-opened fields in tests, the end-state-only selection check (low).

**Follow-up review recommendation:** true — two medium entries were patched on a first pass. Specific unverified risk: `_quiet` now lives until its row's focus arrives; when a hand-back request is superseded and never lands, a later Tab arrival on that row does not select it until the next arrow-key move (a click still selects).

**Verification.** See Verification › Outcomes: 888 app tests pass, analyze and format clean.

**Residual risks.** The superseded-hand-back case above. Following continues if the user Tabs away and back before the next selection change. After ↩ the field's blur handler still runs, so a rename commits twice with the same name (pre-existing, harmless). The full gate runs at the end of the story loop.
