---
title: 'Bookmark drop runs on release (Story 10.10 follow-up, console fix run)'
type: 'feature'
created: '2026-11-03'
status: 'done'
baseline_revision: '0e6ca5b63a0d54cc8df2bd33d077e3dd34ee3cac'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
warnings: []
deferred:
  - summary: >-
      Running-app check of both drags and the backwards-warning ghost (incl. how the ~110-character warning wraps in the 340 px words box) is not done.
    evidence: |-
      The unattended run has no app session; verified only by controller/widget tests. The memory rule asks for a Marionette check of every UI change.
    location: >-
      app/lib/src/features/graph/graph_view.dart (_GraphDragGhostLayer); packages/zanshin_ui/lib/src/controls/zs_drag_ghost.dart
    severity: medium (unverified)
  - summary: >-
      The backwards-move warning is visual only: the ghost is excluded from VoiceOver and the toast does not repeat it.
    evidence: |-
      ZsDragGhost wraps everything in ExcludeSemantics (pre-existing). Settle by a VoiceOver pass on a backwards bookmark drop and its result toast.
    location: >-
      packages/zanshin_ui/lib/src/controls/zs_drag_ghost.dart:177
    severity: medium (unverified)
---

<intent-contract>

## Intent

**Problem:** A bookmark drag in the graph opens the drop menu after 260 ms although a bookmark target has exactly one row (`jj bookmark move N --to T`), and a backwards/sideways bookmark drop does not run: it leaves the menu open after the drag (the "after-drop" mode) until a click. Ralph (2026-11-03, after using the app) wants the drop to run directly.

**Approach:** A `GraphBookmarkDrag` never arms the menu; a plain release runs its single row forward and backwards (backwards with `--allow-backwards`, the row already carries it). While the bookmark is over a backwards target the ghost's words show the command plus a WARNING line (warn colour) naming the effect: the later commits leave the bookmark, and after a push colleagues no longer see them on the branch. The after-drop mode, which existed only for this case, is removed.

## Boundaries & Constraints

**Always:** Change drags keep the menu exactly as now (260 ms rest, ↑/↓, ⌥, release runs the highlighted row). The verb passes `--allow-backwards` exactly when `outcome.allowBackwardsNeeded` (not a fast-forward), as the jj CLI requires. Toast + Undo stay as for every drop (the runner is unchanged). New strings go through `app/lib/l10n/app_en.arb` (+ regenerated localizations). The warning uses the `warn` colour token.

**Never:** No change to the ghost's command text for change drags before the menu opens (Ralph undecided). No change to the Rust verb, FFI or parity oracle. No hidden `--allow-backwards` on a fast-forward. No full gate run (story-loop gate rule).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Bookmark rests on a target | bookmark drag, target with rows, > 260 ms | no menu opens; ghost shows the row's command | none |
| Forward bookmark drop | release on a fast-forward target | runs `GraphBookmarkMove(..., allowBackwards: false)` immediately | refusal path unchanged |
| Backwards bookmark drop | release on a non-fast-forward target | runs `GraphBookmarkMove(..., allowBackwards: true)` immediately, no menu | none |
| Ghost over a backwards target | bookmark over non-ff target | words: command `jj bookmark move b --to t --allow-backwards` + warn line "Moves b back · …" | none |
| Change drag rest | change drag, target with rows, 260 ms | menu opens as before | none |

</intent-contract>

## Code Map

- `app/lib/src/features/graph/graph_drag.dart` -- `GraphDrag`: `_armMenu` (:556) arms the 260 ms menu timer → skip for `GraphBookmarkDrag`; `drop()` (:619) holds the backwards branch to remove; `_afterDrop`/`afterDrop`/`point`/`choose`/Enter in `_onKey` (:755)/`!_afterDrop` in `active`/`ghost`/alt handler → remove; `_runRow(ghost:)` param always true afterwards → drop it. `GraphDropRow.backwards` (:181) stays (the ghost's warning reads it); fix its doc.
- `app/lib/src/features/graph/graph_drop_menu.dart` -- `GraphDropMenu.onChoose`/`onPoint` (:79-97, :166-174) and `row.backwards` warn styling + `strings.dropBackwards` (:136, :157-160) → remove; the right column always shows `row.short` in `textDim`.
- `app/lib/src/features/graph/graph_canvas.dart` -- `drag.afterDrop` in the `seen` tuple (:510), `dragSource`/`dragTarget` (:1386-1388), `_dropMenuLayer` (:1593-1599) → menu always `IgnorePointer`, no TapRegion.
- `app/lib/src/features/graph/graph_view.dart` -- `_GraphDragGhostLayer` (:443): pass the warning for a bookmark ghost whose highlighted row is `backwards`.
- `packages/zanshin_ui/lib/src/controls/zs_drag_ghost.dart` -- `ZsDragGhost`: add a `warning` line (warn colour, sans `fsSm`) below the command inside the words box; test in `packages/zanshin_ui/test/controls/zs_drag_ghost_test.dart`.
- `app/lib/l10n/app_en.arb` (+ generated `app_localizations*.dart`) -- remove `dropBackwards`; add `dragBackwardsWarning(name)`.
- `app/test/features/graph/graph_drag_test.dart` -- old witnesses at :189-197 (row note — keep, still valid), :396-412 (unit: menu stays open), :951-995 (widget: Enter/click/outside) → replace.
- Bookmark drag sources (`bookmark_list_view.dart:282`, `graph_card_menu.dart:326`, `graph_inspector.dart:1849`, `graph_card_render.dart:1174`) only build `GraphBookmarkDrag`; no change needed.
- `_bmad-output/planning-artifacts/epics.md` Story 10.10 + `_bmad-output/implementation-artifacts/sprint-status.yaml` `10-10-graph-drag-and-drop` comment -- dated supersession note.

## Tasks & Acceptance

**Execution:**
- `packages/zanshin_ui/lib/src/controls/zs_drag_ghost.dart` -- add `warning` (String?) rendered under the command in `colors.warn`, hidden with the words -- the ghost's warning surface.
- `app/lib/l10n/app_en.arb` -- add `dragBackwardsWarning` ({name}), remove `dropBackwards`; regenerate with `flutter gen-l10n`.
- `app/lib/src/features/graph/graph_drag.dart` -- no menu for bookmark drags; drop runs the row; remove after-drop mode.
- `app/lib/src/features/graph/graph_drop_menu.dart` -- remove onChoose/onPoint and backwards styling.
- `app/lib/src/features/graph/graph_canvas.dart` -- remove afterDrop uses.
- `app/lib/src/features/graph/graph_view.dart` -- pass the warning.
- `app/test/features/graph/graph_drag_test.dart`, `packages/zanshin_ui/test/controls/zs_drag_ghost_test.dart` -- witnesses per the matrix.
- `epics.md`, `sprint-status.yaml` -- supersession note (2026-11-03, incl. the warn-styling change).

**Acceptance Criteria:**
- Given a bookmark drag resting on a target with a row, when 260 ms pass, then `menuOpen` stays false.
- Given a bookmark over a fast-forward target, when released, then `bookmark move` runs without `--allow-backwards` and no menu opened.
- Given a bookmark over a backwards target, when released, then `bookmark move … --allow-backwards` runs immediately and no menu opened.
- Given a bookmark over a backwards target in the widget, when the ghost renders, then it shows the `--allow-backwards` command and the warning text in the warn colour.
- Given a change drag on a target with rows, when 260 ms pass, then the menu opens (unchanged).

## Spec Change Log

- **2026-11-03, caller course corrections during step 3 (Ralph via the coordinator; the intent-contract text stays as planned, these amend it).**
  1. The backwards text in the ghost is a WARNING in warn styling (`colors.warn`), naming both facts: the later commits leave the bookmark, and after a push colleagues no longer see them on the branch. (Already planned this way; the brief's first "hint styling" was withdrawn.)
  2. CHANGE drags (supersedes "Change drags keep the menu exactly as now" and Story 10.10's "a plain drop runs the first row (rebase -s), ⌥ makes rebase -r the default"): a release on a card BEFORE the menu opens runs nothing (cancels, no verb/toast); ONCE THE MENU IS OPEN a release runs the highlighted row wherever the pointer is (default = "Move here"/rebase -s, ⌥ = rebase -r as the initial highlight; the pointer over a row or ↑/↓ moves it). The ghost shows no command for a change drag before the menu (hint or refusal stays); the menu footer names the highlighted row's command. A first version of this correction ("only a release ON a row runs") was replaced by the coordinator before completion; KEEP the final rule above.
  - Added witnesses: `graph_drag_test.dart` "a change released before the menu opens runs nothing; with the menu open the default row runs" (unit) and the widget test "a card released on another with the menu open runs the default row; no command before it; no click"; "holding lasts…" now opens the menu first.

## Review Triage Log

### 2026-11-03 — Review pass
- verdicts: 20 findings — high 0, medium 1, low 13, false 4, maybe-false 2
- findings:
  - `[low]` `[patch]` (verification-gap) the ghost warning's backwards-only condition is not pinned; a forward bookmark could show the warning unnoticed — patched: forward witness asserting the command shows and `dragBackwardsWarning` is absent.
  - `[low]` `[reject]` (blind) intent-contract Never/Always clauses contradict the shipped change-drag ghost/release rule — the fix is a spec edit; the Spec Change Log records the caller's amendment.
  - `[low]` `[reject]` (blind) I/O matrix and ACs lack the change-drag rows — spec edit; the rule and its witnesses are in the Spec Change Log.
  - `[low]` `[reject]` (blind) the "Drop on a change" hint suggests a drop works before the menu — the hint stays by Ralph's rule c); a drop with the menu open does run; no running-app evidence of confusion.
  - `[false]` `[reject]` (blind) a quick change drop now cancels silently — that is the intent's rule a) verbatim (no verb, no toast).
  - `[low]` `[reject]` (blind) ↑/↓ before the menu moves an invisible highlight — the menu then opens showing that highlight and only a release with the menu open runs anything, so nothing unseen runs; gating would add a branch for a rare key path.
  - `[maybe-false]` `[defer]` (blind) the backwards warning is visual-only (ghost excluded from VoiceOver) — pre-existing ghost semantics; if true medium (unverified); settle by a VoiceOver pass on a backwards drop and its toast.
  - `[low]` `[patch]` (blind) no negative test for the warning — same root cause as the verification-gap row; same patch.
  - `[low]` `[reject]` (blind) no witness for a bookmark released before its preview arrives — pre-existing cancel path (rows == null) unchanged by this diff; low value.
  - `[low]` `[reject]` (blind) no witness for ⌥ held then a release with the menu open — the ⌥ default test (unchanged) plus the "menu open runs the highlighted row" test cover it transitively.
  - `[low]` `[reject]` (blind) the timing test's longer wait is unexplained — cosmetic.
  - `[low]` `[reject]` (blind) spec bookkeeping / Story 10.10's old AC text beside the new dated note — spec edit; the dated epics note is the sibling style the brief asked for.
  - `[maybe-false]` `[defer]` (blind) the ~110-char warning wraps several lines in the 340 px ghost box — needs the running-app look; if true medium (unverified); grouped with the running-app check below.
  - `[low]` `[reject]` (edge) `ZsDragGhost.warning` is dropped when there are no words — unreachable from the app (warning passed only with a command); API-doc nuance only.
  - `[low]` `[reject]` (edge) spec Never clause vs ghost change — spec edit (see above).
  - `[false]` `[reject]` (intent) C2b: release in the card–menu gap — graph_canvas keeps the target in the gap (widget test "the gap between card and menu keeps the target"); off both card and menu is not "card, row or between".
  - `[low]` `[reject]` (intent) C4: ⌥ stays live after the menu opens until the highlight is moved — pre-existing, witnessed behaviour ("⌥ switches the default live"); consistent with "⌥ picks which row is highlighted".
  - `[medium]` `[defer]` (intent) verified only at controller/widget level, not in the running app (memory rule: Marionette check of UI changes) — the unattended run has no app session; follow-up: Marionette check of both drags and the warning ghost.
  - `[false]` `[reject]` (intent) toast + Undo not exercised — the runner path is unchanged by the diff; existing drop tests cover it.
  - `[false]` `[reject]` (intent) the other three bookmark drag sources untested — they only build `GraphBookmarkDrag` (unchanged) and have their own drag-start tests (bookmark_list_view_test, graph_inspector_test, graph_card_menu_test).

## Design Notes

Supersedes Story 10.10's "a backwards bookmark drop opens the menu instead of running" and the 2026-09-28 note "--allow-backwards = a visible drop-menu choice, never a hidden default". Rationale (Ralph 2026-11-03): jj's guard (`cli/src/commands/bookmark/move.rs` @ v0.46.0, "Refusing to move bookmark backwards or sideways") is a typo guard since 2021 (40a260a37); in a GUI the target is chosen by sight, nothing is destroyed (commits stay visible, Undo restores the bookmark). Ralph first asked for a hint-styled note, then (same day) for a warning in warn styling that also names the colleague effect after a push.

English: `Moves {name} back · the later commits leave the bookmark; after a push, colleagues no longer see them on the branch`.

## Verification

**Commands:**
- `flutter test test/features/graph/` (in `app/`) -- expected: pass
- `flutter test` (in `packages/zanshin_ui/`) -- expected: pass
- `dart analyze` (app, zanshin_ui) -- expected: no issues
- `dart format --set-exit-if-changed` on touched files -- expected: exit 0

**Verification notes (gate rule: no `cargo make test`/`test-full`/`coverage`; Dart + docs only, no Rust/FFI/verb change → no cargo checks, no codegen, no parity oracle):**
- `flutter test test/features/graph test/features/bookmarks test/l10n` (app) -- 942 passed (after the review patch).
- `flutter test` (packages/zanshin_ui) -- 450 passed.
- `dart analyze` (app; zanshin_ui) -- No issues found.
- `dart format --set-exit-if-changed lib test` (app; zanshin_ui) -- exit 0.
- `flutter test` (whole app) -- all pass except 5 in `test/features/projects/worker_project_repos_test.dart`, which refuse to run outside `cargo make test-app` ("XDG_CONFIG_HOME is not pinned to target/test-xdg-config"); unrelated to this diff.

## Auto Run Result

Status: done

**Summary.** A bookmark drag never opens the drop menu; a release on a target runs `jj bookmark move N --to T`, forward and backwards (backwards with `--allow-backwards`, exactly when `allowBackwardsNeeded`). Over a backwards target the ghost shows the command plus a `warn`-coloured warning ("Moves N back · the later commits leave the bookmark; after a push, colleagues no longer see them on the branch"). The after-drop menu mode is gone. Per Ralph's same-day corrections: a change drag released before the menu opens runs nothing; once the menu is open a release runs the highlighted row (default rebase -s, ⌥ rebase -r, pointer/↑↓ move it); the ghost shows no command for a change drag before the menu.

**Files.**
- `app/lib/src/features/graph/graph_drag.dart` -- no menu for bookmark drags; change release needs the open menu; after-drop mode removed.
- `app/lib/src/features/graph/graph_drop_menu.dart` -- onChoose/onPoint and the backwards warn note removed.
- `app/lib/src/features/graph/graph_canvas.dart` -- afterDrop uses removed; menu always IgnorePointer.
- `app/lib/src/features/graph/graph_view.dart` -- ghost: warning for backwards bookmarks; no command for change drags.
- `packages/zanshin_ui/lib/src/controls/zs_drag_ghost.dart` -- optional `warning` line in `--warn`.
- `app/lib/l10n/app_en.arb` + generated localizations -- `dragBackwardsWarning` added, `dropBackwards` removed.
- `app/test/features/graph/graph_drag_test.dart`, `packages/zanshin_ui/test/controls/zs_drag_ghost_test.dart` -- witnesses.
- `_bmad-output/planning-artifacts/epics.md`, `_bmad-output/implementation-artifacts/sprint-status.yaml` -- dated supersession notes; `deferred-work.md` -- two items.

**Review.** 20 findings: 1 patch (forward ghost shows no warning — witness added; low), 2 deferred (running-app/Marionette check incl. warning wrap; VoiceOver silence of the warning — both medium unverified), 17 rejected (reasons in the triage log: spec-edit fixes, intended behaviour, pre-existing paths, cosmetic).

**Follow-up review recommended:** false (patched: 0 high, 0 medium, 1 low).

**Residual risks.** Not seen in the running app; the warning text is long and may wrap to 3-4 lines in the ghost; a change drag released quickly (before debounce + 260 ms) now does nothing by design.
