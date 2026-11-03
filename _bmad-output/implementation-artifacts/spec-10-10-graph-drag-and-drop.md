---
title: 'Story 10.10 — Graph drag-and-drop'
type: 'feature'
created: '2026-11-03'
status: 'done'
baseline_revision: '8d6c2ceb88ce3154111e0b9ffd281440f9e2ed36'
review_loop_iteration: 0
followup_review_recommended: true
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-10-context.md'
warnings: [oversized]
deferred:
  - summary: >-
      Nothing tells a jj-lib pin bump to re-diff the ported move planner in rebase.rs against jj-lib's rewrite.rs.
    evidence: |-
      rebase_is_no_op now answers from planned_parents / TargetGraph / new_children / children_parents, a read-only copy of jj-lib 0.46.0 rewrite.rs:667-957 (+ private helpers :1259, :1285); the inline dry-run comparison only catches drift on the shapes it builds. The pin-bump steps in project-context.md § zanshin-jj do not mention it; the fix edits that agent-context file.
    location: >-
      crates/zanshin-jj/src/rebase.rs (planned_parents)
    severity: medium
  - summary: >-
      The running app was not checked visually (ghost, target, menu above/below, toast) with Marionette/Playwright.
    evidence: |-
      The spec's Verification lists the manual check; this unattended run verified with widget tests only (gate rule: targeted checks). The "verify UI with Marionette" rule makes it part of done for UI changes.
    location: >-
      app/lib/src/features/graph/graph_canvas.dart, graph_drop_menu.dart, packages/zanshin_ui/lib/src/controls/zs_drag_ghost.dart
    severity: medium
---

<intent-contract>

## Intent

**Problem:** The graph cannot be driven by drag-and-drop: no card or bookmark drags, no `drop_actions` preview in the app, no drop menu, and the runner has no rebase or duplicate actions (deferred I3, I4, I5). The backend's hover query is also too costly to sit on a hover path: measured with the new bench `drop_actions_depth` (one target, `-o`/`-A`/`-B`, a 200-change stack above the target), one query takes **1.5–4.6 s** and leaves **226–664 `refs/jj/keep/*`** per call, because each rebase row's no-op check applies jj-lib's whole move (I1, I2 — it bites).

**Approach:** Make the rebase rows' no-op check write-free (port jj-lib 0.46.0's move planner's parent computation, compare planned parents with current ones), then build the design's drag-and-drop (epics.md Story 10.10, the 2026-10-14 and 2026-10-16 notes = decision (a4)): change cards and local bookmarks are drag sources, cards with at least one Available row are targets, a 260 ms rest opens the drop menu, a plain drop runs the default row through the runner (10.9), toasts (10.23) and a glide from the ghost (10.20) follow.

## Boundaries & Constraints

**Always:**
- Rows come only from `RepoHandle.dropActions` (one query per target: locations `-o T`, `-A T`, `-B T`); only Available rows of these eight show, in this order, hairlines between groups: move — Move here `jj rebase -s S -o T` (default), Move only this change `jj rebase -r S -o T`; place — Insert after `jj rebase -r S -A T`, Insert before `jj rebase -r S -B T`; combine — Squash into this change `jj squash --from S --into T`, New merge change `jj new T S`; copy — Duplicate here `jj duplicate S -o T`; bookmark — Move N here `jj bookmark move N --to T` (+ ` --allow-backwards` and the warn note "backwards" when `allowBackwardsNeeded`; the name as `exact:<name>`, shell-quoted, when it holds a glob character `*?[]{}`). Ids: 8 characters (`max(prefix, 8)` of the change id). Commands are shell-quoted through the existing `_jj` helper.
- Sources: every change card except the root and stack cards (immutable ones included); bookmarks: the card's legend pill (its FIRST ref), the bookmark popover's per-bookmark rows, the Bookmarks panel's rows (panel and rail callout), the inspector's chips. A remote bookmark, or a name containing `@`, never drags. Nothing drags while `actionsEnabled` is false (stale or busy); the panel row then keeps its "Working copy is stale" tooltip.
- A drag starts after 5 px of travel from a press on the card body / pill / row (the 4 px tap slop already swallows the click). Drag start: callouts, peek, gap callout, card menu and popovers close, a pending click-select is cancelled, hover is off (focus path pauses), `ShellController.startItemDrag()` is held (resize edges inert, calm waits) until the drag ends. The source shows at .35; source and target stay pinned (10.1 item 9).
- Targets: cards only (not stacks, not the source, not the root unless it has an Available row); a card is highlighted (`accentLiveLine` border, `cardSolidHi` fill, `ringDrop`) only once its rows are known and at least one is Available. The pointer over the open menu keeps the target.
- Preview: debounced (60 ms after the target changes), at most one query in flight, cached per (source, target) keyed by the layout's `operationId` (cache cleared when it changes). While a drag runs and until the drop's verb finishes, `GraphViewModel` holds reloads (at most one queued) and applies the held one after.
- Drop menu: opens after a 260 ms rest on a target, 12 px above the card when it fits under the top inset, else below; centred and clamped to the visible graph (`GraphViewportController.unobscured`); above the card the list runs bottom-up. Each row: glyph, label, mono short verb or warn note; footer = highlighted row's full command. Highlight = solid `accent` + `accentInk`; it follows the pointer over rows, ↑/↓ move it; it starts on the default row. The menu fades in (scale × `motion`) and scrolls with its card.
- Default row: the first row; ⌥ held (live) makes "Move only this change" the default when Available. A release over the card or a row runs the highlighted row (else the default). A bookmark row with the "backwards" note never runs on a plain drop: the drop leaves the menu open after the drag (click a row to run it; Esc or a click outside closes it). A drop on nothing, on a non-target, or before the rows arrived cancels. Esc cancels; neither runs anything.
- Ghost (`ZsDragGhost`, extended): a change shows `@` badge (working copy), the id (shortest prefix bold, `max(prefix, 8)` chars, one `Text.rich`) and the subject; a bookmark its name. It sits at pointer + (14, 12) on the top-most overlay (`Overlay.of(context, rootOverlay: true)`), above islands. Its words line: the default row's full command (mono, `accentLine` border) on a target; else "Drop on a change" / "Drop on the change it should point to"; on a card with no Available row but a Refused one, the first refusal's `context ?? code`. The words hide while the menu is open and the chip fades to .3 over the menu. After a drop the ghost stays at the drop point until the verb finishes, then disappears.
- Auto-scroll: a 56 px zone inside `unobscured` (live insets), `ceil((56 − d) / 4)` px per frame per axis, still active up to 24 px outside; armed only once the pointer has been more than 56 px inside on all sides.
- Execution through `GraphViewModel.run` with new `GraphRebase` / `GraphDuplicate` actions (existing `GraphSquash`, `GraphNew(parents: [T, S])`, `GraphBookmarkMove` for the rest). Toasts: Moved S onto T · Inserted S after T · Inserted S before T · Squashed S into T (exists) · Merged S and T in a new change · Duplicated S onto T · Moved N to T (exists). The dropped change (rebase) glides from the ghost's rect; a duplicate's born change grows from it.
- Rebase no-op stays exact: same answers as the dry run for every existing test; no git object, commit or ref is written by the rebase rows' check.

**Never:** edge targets or gap zones; files/hunks (10.27); several cards at once; a keyboard/VoiceOver drag path; rows for `-b`, revert, restore, absorb, interdiff, split; a hidden default (`--allow-backwards` only via the visible row); a new FFI entry or schema change; changing the `drop_actions` FFI contract; Material widgets.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Plain drop | card S dragged onto T, rows [move, …] | `jj rebase -s S -o T` runs; toast "Moved S onto T"; S glides from the ghost | refusal → warn toast (10.23), ghost disappears |
| ⌥ drop | ⌥ held at release | `jj rebase -r S -o T` | — |
| Menu row | rest 260 ms, release on "Insert before" | `jj rebase -r S -B T` | — |
| Only NoOp rows | S dropped on its own parent | no highlight, words "Drop on a change", drop cancels | — |
| Refused target | all rows Refused (immutable T) | no highlight, words = first refusal's context | — |
| Backwards bookmark | bookmark drop, only row has allowBackwards | menu stays open after release, nothing runs | Esc/outside closes |
| Glob bookmark | name `feat*` | row command `jj bookmark move 'exact:feat*' --to T` | — |
| Esc / nothing | Esc, or release on canvas | no call, ghost gone, held reload applied | — |
| Op during drag | OpHeadsChangedEvent while dragging | layout not reloaded until drop/cancel (+ the verb); next hover re-queries (op id changed) | — |
| Preview fails | dropActions throws | target not highlighted, words keep the hint | swallowed |

</intent-contract>

## Code Map

- `crates/zanshin-jj/src/rebase.rs:260` -- `rebase_is_no_op` (dry `apply_move` on the row's transaction) → replace with a read-only planner; `apply_move` :304 keeps the verb path; `target_ids` :269.
- `~/.cargo/registry/src/*/jj-lib-0.46.0/src/rewrite.rs:667-957` -- `compute_move_commits` (port its `commit_new_parents_map` computation); helpers `compute_internal_parents_within` :1259, `compute_commits_heads` :1285 (private: copy); `apply_move_commits` :961 rewrites a commit only when `rewriter.parents_changed()` or it is in `to_abandon` → no-op ⇔ every visited commit's planned parents equal its own AND `find_duplicate_divergent_commits` is empty. `MutableRepo::find_descendants_for_rebase` (repo.rs:1415) is public. The Git backend refuses a commit with ≥2 parents including the root (`git_backend.rs`, "merge commits with the root commit as one of the parents") — the dry run surfaced it as `InvalidInput`; keep that refusal by checking planned parents.
- `crates/zanshin-jj/benches/drop_actions_depth.rs` (new, done in planning) + `Cargo.toml` `[[bench]]` -- the I1/I2 measurement.
- `crates/zanshin-jj/src/drop_actions.rs` -- row planning (calls `rebase_is_no_op`); unchanged contract.
- `packages/zanshin_core/lib/src/ffi/drop_actions.dart` -- `DropSource`/`ChangeDropSource`/`BookmarkDropSource`, `DropLocation`, `DropVerb`, `ActionStatus`, `ActionOutcome{refusal, allowBackwardsNeeded}`, `DropAction{verb, location, outcome}`; `RepoHandle.dropActions` (handle.dart:1077), `rebase` :1211 (`source/revisions/onto/insertAfter/insertBefore`), `duplicate` :1448 (`revisions/onto`).
- `app/lib/src/features/graph/graph_ports.dart` -- `GraphAction` :174 (`_jj` quoting, `pendingKeys`), `GraphSquash` :287, `GraphNew` :227, `GraphBookmarkMove` :433; `RepoGraphActions.run` :760 (exhaustive switch); `GraphDetails`/`RepoGraphDetails` :836/:852.
- `app/lib/src/features/graph/graph_view_model.dart` -- `init` :255, `run` :667, `_execute` :711, `_plan` :770, `_succeeded` :801, `_onEvent` :903, `_requestLayout` :951 (`_inFlight`/`_queued`), `_land` :1018 (builds `GraphTransition` from `_landing`).
- `app/lib/src/features/graph/graph_viewport_render.dart` -- `GraphTransition` :73 (add a drop origin; `.continued` copies it); effects :620-680 (`was`/`now` are viewport-local); `GraphViewportController` :140 (`cardRectOf` :153, `jumpTo`, `unobscured`); `paintOrder` :882, `hitTestChildren` :956, `isOnCard` :994 → add a top-most key lookup.
- `app/lib/src/features/graph/graph_card_render.dart` -- `graphDragThreshold` :22, `_tap` :145, `_areaAt` :1054, `handleEvent` :1079, `_legend` (first ref) :468; `graph_card.dart` `GraphCardController` :47 (add drag callbacks and a `dropTarget` notifier the card paints).
- `app/lib/src/features/graph/graph_canvas.dart` -- `pinnedKeys` :1311, `opacityOf` :1312, layers :1366-1384 (`_peekLayer` pattern re-reads `cardRectOf` each frame), `_closeGap` :780, `_userPanned` :1000, `_planeShift` :718.
- `app/lib/src/features/graph/graph_view.dart` -- `_hoverGate` :186, menu hosts :362, insets :316, `closeMenus` :332.
- `app/lib/src/features/shell/shell_controller.dart:280` -- `startItemDrag()` → `CalmHold`.
- `app/lib/src/features/graph/graph_card_menu.dart:263` -- `graphBookmarkMenuEntries` (per-local-bookmark row); `packages/zanshin_ui/lib/src/controls/zs_menu.dart:29` `ZsMenuItem` (add a row `wrap` builder).
- `app/lib/src/features/bookmarks/bookmark_list_view.dart:199` -- `BookmarkRowTile` (`row.bookmark.kind` Local/Remote, stale tooltip :264); `graph_inspector.dart:1661` `_Chips` (`GraphRef.remote`).
- `packages/zanshin_ui/lib/src/controls/zs_drag_ghost.dart:40` -- `ZsDragGhost` (kinds project/group; add change + bookmark, a mono command line).
- `app/lib/src/features/graph/graph_toasts.dart:251` `_text`, `:157` silent New; `app/l10n/app_en.arb` (`toastSquashed` :723, `toastBookmarkMoved` :758; regenerate with `flutter gen-l10n`); `app/lib/src/features/shell/app_menu.dart:~217` undo labels switch.
- `app/lib/src/features/home/project_graph_host.dart:145` + `graph_preferences.dart` `init` -- wire `RepoGraphDrops(repo)`.
- `crates/zanshin-parity/tests/oracle/card_menu_commands.rs` + `test-fixtures/commands/card-menu.txt` -- pattern for a drop-menu command file run through the pinned jj.
- Tests: `app/test/features/graph/graph_view_model_test.dart` (`_Actions` :1598), `graph_harness.dart` (`GraphHarness` :226), `graph_view_test.dart`, `graph_toasts_test.dart`, `graph_card_menu_test.dart`, `graph_transition_test.dart`, `app/test/helpers/fake_bookmark_list.dart` (`RecordingGraphActions` :147), `bookmark_list_view_test.dart`, `graph_inspector_test.dart`, `app_menu_test.dart`.
- DS: `_bmad-output/implementation-artifacts/design_system/components/menus/DropMenu.prompt.md`, `components/overlays/DragGhost.prompt.md`, `overlays.css:40-60`, `graph.css:8`.

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/src/rebase.rs` -- replace the dry run in `rebase_is_no_op` with a read-only port of jj-lib 0.46.0's planned-parents computation (cite rewrite.rs lines); no-op ⇔ no visited commit's planned parents differ and no divergent duplicate would be abandoned; keep the root-merge refusal; inline unit tests for any branch the existing rebase/drop-actions tests miss -- I1/I2.
- `crates/zanshin-jj/benches/drop_actions_depth.rs` -- rerun after the fix; record both measurements in Design Notes.
- `app/lib/src/features/graph/graph_ports.dart` -- add `GraphRebase({source, revisions, onto, insertAfter, insertBefore})` and `GraphDuplicate({revisions, onto})` (command, pendingKeys = all named ids), their `RepoGraphActions` mapping, and a `GraphDrops` port (`dropActions(DropSource, List<DropLocation>)`) with `RepoGraphDrops` -- I3.
- `app/lib/src/features/graph/graph_drag.dart` (new) -- payloads (change: key, changeId, prefix, subject, workingCopy; bookmark: name), `GraphDropRow` (group, glyph, label, short, note, command, action), `graphDropRows(payload, target, DropActions)`, and `GraphDrag` (ChangeNotifier): start/move/target/drop/cancel, debounce + one-in-flight + op-keyed cache, 260 ms menu timer, ⌥ live, ↑/↓, Esc (HardwareKeyboard handler while active), the after-drop open menu, `running` until the verb's future completes.
- `app/lib/src/features/graph/graph_view_model.dart` -- own `drag`; `init(drops:)`; hold reloads while a drag or its verb runs; `_plan`/`_succeeded` for `GraphRebase` (anchor T, flash S, selection kept) and `GraphDuplicate` (anchor T, reveal + born like `GraphNew`, selection kept); carry the drop origin rect into `_landing` → `GraphTransition` -- I3, I5.
- `app/lib/src/features/graph/graph_viewport_render.dart` -- `GraphTransition.dropped ({String key, Rect rect})?` (viewport-local; continued copies it): that key's card glides from the rect, a born key grows from its centre; `GraphViewportController.keyAt(Offset global)` (top-most laid-out card, honouring the transition transforms) -- I5.
- `app/lib/src/features/graph/graph_card.dart`, `graph_card_render.dart` -- drag start/move/end/cancel from body (non-root) and pill (first ref local, no `@`) past 5 px; paint the drop-target look from a `dropTarget` notifier.
- `app/lib/src/features/graph/graph_canvas.dart`, `graph_view.dart`, `graph_drop_menu.dart` (new) -- target resolution, pins, .35 source, auto-scroll ticker, drop menu layer, ghost overlay entry, closing callouts, hover gate, `startItemDrag` hold, wiring.
- `packages/zanshin_ui/lib/src/controls/zs_drag_ghost.dart`, `zs_menu.dart` -- ghost kinds change/bookmark + mono command words; `ZsMenuItem.wrap`; widget tests in `packages/zanshin_ui/test`.
- `app/lib/src/features/graph/graph_card_menu.dart`, `app/lib/src/features/bookmarks/bookmark_list_view.dart`, `app/lib/src/features/graph/graph_inspector.dart` -- wrap local bookmark sources in a shared `GraphDragSource` (Listener, 5 px start, forwards to `model.drag`) -- I4.
- `app/lib/src/features/graph/graph_toasts.dart`, `app/lib/l10n/app_en.arb` (+ generated), `app/lib/src/features/shell/app_menu.dart` -- toast texts and undo labels for rebase (onto / after / before), duplicate, merge-new.
- `app/lib/src/features/home/project_graph_host.dart`, `graph_preferences.dart` -- pass `RepoGraphDrops(repo)`.
- `test-fixtures/commands/drop-menu.txt` + `crates/zanshin-parity/tests/oracle/drop_menu_commands.rs` (module in `main.rs`) -- every drop row's command (incl. `--allow-backwards` and `exact:`) runs with the pinned jj; the app test asserts the file line for line.
- Tests (app): row mapping/order/filtering, default + ⌥, backwards, glob, debounce/in-flight/cache, reload hold, cancel paths, drag from card/pill/panel row/chip/popover row, stacks/root/remote inert, click after drag swallowed, menu placement above/below + bottom-up, auto-scroll arming, ghost words, toasts, `_plan`/`_succeeded`, transition from the ghost rect.

**Acceptance Criteria:**
- Given a card S and a card T with Available rows, when S is dragged onto T and released before 260 ms, then the runner runs `jj rebase -s S -o T` and the ghost's words showed that exact command.
- Given the pointer rests 260 ms on T, then the menu shows only Available rows in the fixed order, bottom-up above the card or top-down below it, and a release on a row runs that row.
- Given ⌥ is pressed during the drag, then the default (ghost words, plain-drop action) switches live to `jj rebase -r S -o T`.
- Given a stack card, then it neither starts a drag nor becomes a target; given a remote bookmark or a name with `@`, then it does not drag.
- Given a drag, when an op-heads event arrives, then no layout loads until the drop's verb finished or the drag was cancelled, then one reload runs.
- Given a 200-change stack above T, when `drop_actions_depth` runs after the fix, then the keep-ref growth per query is 0 from the rebase rows and the query time is reported in Design Notes.
- Given a drag runs, then no resize edge shows its line or cursor, and the auto-scroll zone follows a resized panel's inset.

## Spec Change Log

## Review Triage Log

### 2026-11-03 — Review pass
- verdicts: 39 findings — high 0, medium 11, low 25, false 3, maybe-false 0 (the intent audit's divergences logged as 4 findings)
- findings:
  - `[medium]` `[patch]` Blind: preview cache keyed by the held layout's op id serves rows from before an outside op — cache keyed on an op-heads counter the model bumps on every event; test added.
  - `[medium]` `[patch]` Blind: canvas `setState` on every pointer move rebuilds the whole canvas — rebuild only when what the build reads changes.
  - `[low]` `[patch]` Blind: `_ghostRect` measures chip + words, so the origin width is the words' — measure the chip.
  - `[low]` `[reject]` Blind: global pointer route not filtered by pointer id / view — one mouse; macOS routes a held-button drag to the originating window; a filter adds guards for a case not met in use.
  - `[low]` `[patch]` Blind: non-`ZanshinFfiException` preview errors escape the Timer — catch all (grouped with Edge #2).
  - `[medium]` `[patch]` Blind: Rust exactness test covers only linear history — merge (and divergent) history added to the dry-run comparison (grouped with VG #1).
  - `[medium]` `[defer]` Blind: no note tells a jj-lib pin bump to re-diff the ported planner (`rebase.rs` vs `rewrite.rs:667-957`) — the fix edits agent-context rules (project-context.md § zanshin-jj pin-bump steps); deferred.
  - `[medium]` `[patch]` Blind: tests the spec lists are missing (sources, inert rules, held reload after the verb, menu rows) — added (grouped with VG #2-#6).
  - `[false]` `[reject]` Blind: glob command `'exact:"feat*"'` differs from the spec's `'exact:feat*'` — the code reuses `GraphBookmarkMove`'s tested quoting, both forms are valid jj (oracle runs it); the fix would edit this spec.
  - `[low]` `[patch]` Blind: planning artifacts (deferred-work I1–I5, sprint-status 10.10) not updated — updated at finalize.
  - `[low]` `[patch]` Blind: `graphChangeDragOf` duplicates `graphShortId` — reuses it (grouped with VG other).
  - `[low]` `[patch]` Blind: hover gate uses `drag.active`, so peeks return over the after-drop menu — gated on `holding`.
  - `[low]` `[patch]` Blind: `_menuRect` written during build, stale for a frame — grouped with Edge #4.
  - `[medium]` `[defer]` Blind: the running-app Marionette/Playwright check is not recorded — needs the running app; left to the story loop's visual-check run (unattended runs here use targeted checks only).
  - `[low]` `[patch]` Blind: merge drop's undo label has no ids — label names S and T.
  - `[low]` `[patch]` Edge: drag ending with a preview in flight leaves the next drag's first target unqueried — refetch on the payload-mismatch return; test added.
  - `[low]` `[patch]` Edge: non-Ffi preview error uncaught, preview never refetched — catch all (grouped with Blind #5).
  - `[low]` `[reject]` Edge: a layout load already in flight at drag start lands during the drag — a millisecond window before the hold; holding a landing adds state for a case not met in use.
  - `[low]` `[patch]` Edge: stale menu rect hit-tests after the menu reopens on another target — rect cleared while the menu is closed.
  - `[low]` `[reject]` Edge: release over the open menu between rows with a backwards row highlighted runs it — a release over the open menu with that row highlighted is a menu choice, not a plain drop.
  - `[low]` `[reject]` Edge: unobscured area under 112 px never arms auto-scroll — the window's minimum size leaves more; guard not worth it.
  - `[low]` `[patch]` Edge: ghost rect width — grouped with Blind #3.
  - `[medium]` `[patch]` Edge: drag-source wrapper appears/disappears when `actionsEnabled` flips (every run), remounting the row and dropping keyboard focus — tree shape kept constant.
  - `[low]` `[reject]` Edge: stale `_dropping` when `_execute` throws before reading it — only reachable without `GraphActions`, which the app always passes.
  - `[low]` `[reject]` Edge: actions disabled mid-drag make the drop silently do nothing — the stale state shows its own notice; a toast path adds branches for a rare case.
  - `[low]` `[patch]` Edge: the below-placed menu is not clamped vertically — top clamped into the area; test extended.
  - `[low]` `[patch]` Edge: after-drop menu highlight does not follow the pointer — hover sets it.
  - `[false]` `[reject]` Edge: refusal order differs from the dry run (root-merge vs duplicates errors) — the dry run also computed the move (and so met the root-merge write) before any duplicate error could matter only on backend failure; no observable difference for a reachable input.
  - `[medium]` `[patch]` VG: no dry-run comparison on a merge history — grouped with Blind #6.
  - `[medium]` `[patch]` VG: `RepoGraphActions` rebase/duplicate mapping untested — real-repo tests added.
  - `[low]` `[patch]` VG: drop origin never asserted to reach `GraphTransition.dropped` — asserted in the in-graph drop test.
  - `[low]` `[patch]` VG: held reload after the verb only tested via cancel — asserted after a drop's verb.
  - `[medium]` `[patch]` VG: menu-row resolution in the canvas untested — in-graph test through a menu above the card.
  - `[medium]` `[patch]` VG: drag sources and stack/root/remote inert rules untested — widget tests added.
  - `[low]` `[patch]` VG other: duplicated short-id rule — grouped with Blind #11.
  - `[low]` `[patch]` Intent: I2's follow-on (git objects from restore/absorb/squash/duplicate rows) unmeasured — bench prints loose-object growth too.
  - `[low]` `[patch]` Intent: bookkeeping not updated — grouped with Blind #10.
  - `[false]` `[reject]` Intent: tests exercise only model level — duplicate of the VG test findings, handled there.
  - `[low]` `[defer]` Intent: running-app check absent — grouped with Blind #14.

## Design Notes

**Measurement before the fix (planning, 2026-11-03, release build, `tiny-3-commits` + 200-change stack, 10 queries each):** drop_actions at 1/10/50/100/199 descendants: med 1.55 / 1.62 / 2.18 / 3.01 / 4.65 s; keep refs +2266 / +2465 / +3356 / +4457 / +6644 per 10 queries; `Repo::status` floor 2.9 ms. Even one descendant costs 1.5 s because `-A T` / `-B T` move every descendant of T. Ralph's 2026-10-21 note offers "query once per drop target" (built in: one cached query per target and operation) or "compute the no-op from the parents without writing" (this story) — both are taken.

**Measurement after the fix (2026-11-03, same bench, release build, 10 queries each):** drop_actions at 1/10/50/100/199 descendants: med 29.1 / 25.8 / 26.1 / 32.0 / 42.4 ms (min 26.0 / 25.1 / 25.1 / 30.6 / 40.7 ms); keep refs **+0** at every depth; `Repo::status` floor 2.5 ms. The rebase rows' check now reads jj-lib's planned parents (`rebase.rs` `planned_parents`, a port of `compute_move_commits`' parent computation) and writes nothing; the remaining ~25 ms are the other rows' plans and the per-call head load. The inline test `rebase_is_no_op_answers_what_the_dry_run_answers` compares the check with the old dry run for every `-r`/`-s` × `-o`/`-A`/`-B` plan over the fixture's commits, singly and in pairs (refusals included).

**Rerun with loose objects (review, 2026-11-03, machine under load — `Repo::status` floor 9.2 ms med):** med 49.8 / 47.1 / 41.6 / 52.5 / 70.7 ms; **+0 keep refs and +0 loose git objects** over 11 queries at every depth. The equivalence test now also runs over a merge (M of Commit 2 and @, a child D on M), root-merge refusals included.

**Why the port is exact:** `apply_move_commits` rewrites a visited commit only when `rewriter.parents_changed()` (its mapped planned parents differ) or it is in `to_abandon`; with no planned change nothing is rewritten, and a change at any visited commit means a write. So comparing jj-lib's own planned parents (ported verbatim) with the current ones gives the dry run's answer without writing.

**Drag event routing:** a card's `RenderGraphCard` keeps receiving its pointer's moves/up after the drag starts (hit-test path fixed at pointer-down; the pin keeps it attached), so the card forwards them; Flutter-widget sources use a `Listener` the same way. The canvas resolves the target from the global position (`keyAt`) and the menu rect.

## Verification

**Commands (gate rule of this run — no `cargo make test`/`test-full`/`coverage`):**
- `cargo test -p zanshin-jj --lib rebase` and `cargo test -p zanshin-jj --test it rebase:: drop_actions::` -- pass
- `cargo clippy -p zanshin-jj --all-targets -- -D warnings`; `cargo fmt --all --check` -- clean
- `cargo bench -p zanshin-jj --bench drop_actions_depth` -- 0 keep refs from rebase rows; times recorded
- `cargo test -p zanshin-parity --test oracle` -- pass
- `flutter test` + `dart analyze` + `dart format --set-exit-if-changed .` in `app/` and `packages/zanshin_ui/` -- pass/clean

**Manual checks:**
- Marionette/Playwright check of the running app per the "verify UI" memory: ghost, target, menu above/below, toast.

**Verification notes (2026-11-03, this run — gate rule: no `cargo make test`/`test-full`/`coverage`):**
- `cargo test -p zanshin-jj` (lib 438, `it` 1515 + 1 ignored) -- pass (after the review patches)
- `cargo test -p zanshin-jj --lib rebase` (7, incl. the dry-run equivalence over a merge) -- pass
- `cargo clippy -p zanshin-jj -p zanshin-parity --all-targets -- -D warnings` -- clean; `cargo fmt --all --check` -- clean
- `cargo test -p zanshin-parity --test oracle` -- 507 pass (before the patches); `-- drop_menu card_menu` -- 2 pass (after)
- `cargo bench -p zanshin-jj --bench drop_actions_depth` -- before 1.5–4.6 s / +226–664 keep refs per query; after 26–71 ms, +0 keep refs, +0 loose objects (Design Notes)
- `app/`: `flutter test test/features/graph test/features/bookmarks test/features/shell test/features/home` -- 1061 pass; `dart analyze --fatal-infos` -- clean; `dart format --set-exit-if-changed lib test` -- clean. (The implementer ran `test/features/sync` and `projects` via `cargo make test-app`: 279 pass — they need the pinned env.)
- `packages/zanshin_ui/`: `flutter test` -- 449 pass; analyze/format -- clean
- Not run: the running-app visual check (deferred).

## Auto Run Result

Status: done

**Summary.** Drag-and-drop on the graph per decision (a4) and the 2026-10-16 note: change cards (not root, not stacks) and local bookmarks (card pill, popover rows, Bookmarks panel/rail rows, inspector chips) drag past 5 px; cards with an Available row are targets; one cached `drop_actions` preview per target (60 ms debounce, one in flight, keyed by operation + op-heads counter); the drop menu after 260 ms (above bottom-up / below, clamped, footer command, ⌥ live default, ↑/↓, Esc); a plain drop runs the default row via the runner; backwards bookmark rows open the menu instead; auto-scroll with arming; reloads held during the drag and its verb; toasts, undo labels and a glide from the ghost. The rebase rows' preview no-op is now write-free (a read-only port of jj-lib's planned parents).

**Files.** `crates/zanshin-jj/src/rebase.rs` (write-free no-op + equivalence test), `benches/drop_actions_depth.rs` (I1/I2 bench), `drop_actions.rs` (doc); `crates/zanshin-parity/tests/oracle/drop_menu_commands.rs` + `test-fixtures/commands/drop-menu.txt` (every drop command through the pinned jj); `app/lib/src/features/graph/graph_drag.dart` (new: rows, controller, `GraphDragSource`), `graph_drop_menu.dart` (new: menu + geometry), `graph_ports.dart` (`GraphRebase`, `GraphDuplicate`, `GraphDrops`), `graph_view_model.dart` (drag, hold, `_plan`/`_succeeded`, drop origin), `graph_viewport_render.dart` (`GraphTransition.dropped`, `keyAt`), `graph_card*.dart` (drag start, target look), `graph_canvas.dart` / `graph_view.dart` (targets, pins, auto-scroll, menu, ghost, gates), `graph_card_menu.dart` / `graph_inspector.dart` / `bookmarks/bookmark_list_view.dart` (bookmark sources), `graph_toasts.dart`, `shell/app_menu.dart`, l10n, `graph_preferences.dart`, `home/project_graph_host.dart`; `packages/zanshin_ui` `zs_drag_ghost.dart` (change/bookmark kinds, command words, `chipKey`), `zs_menu.dart` (`ZsMenuItem.wrap`), `graph_theme.dart`; tests.

**Review.** 39 findings: 28 rows patched (9 medium incl. the op-keyed cache, per-move rebuilds, the merge equivalence test, the focus-losing wrapper and the missing source/menu/port tests; 19 low), 2 deferred (pin-bump note → agent-context file; running-app visual check), 9 rejected (6 unlikely lows whose fixes add guards; 3 false, one of them the glob command, which keeps `GraphBookmarkMove`'s tested `'exact:"feat*"'` quoting). Patched by verdict: medium 9, low 19.

**Follow-up review recommended: true** — two or more medium entries were patched; the unverified risk is the canvas's new rebuild gating and menu-rect clearing, checked only by widget tests, never in the running app (a missed rebuild would leave a stale target highlight or menu).

**Deferred items I1–I5:**
- I1 — fixed: measured (1.5–4.6 s per hover query on a 200-deep stack — it bites) and settled with both of Ralph's remedies: one cached query per target, and a write-free no-op (26–71 ms after). Fixed (commit c5d42306).
- I2 — fixed: the rebase rows write nothing (+0 keep refs, +0 loose objects per query at every depth, all rows of the query included). Fixed (commit c5d42306).
- I3 — fixed: `GraphRebase` / `GraphDuplicate`, `RepoGraphActions` mapping (real-repo tests), `_plan`/`_succeeded` rules. Fixed (commit c5d42306).
- I4 — fixed: the panel/rail row drags (local, no `@`; inert while stale/busy, keeps its stale tooltip). Fixed (commit c5d42306).
- I5 — fixed: the ghost's chip rect reaches `GraphTransition.dropped` (glide / born growth), rebase/insert/duplicate anchor/flash/born mappings. Fixed (commit c5d42306).

Commits: c5d42306 (story), plus the bookkeeping commit after it.

**Residual risks.** No visual check in the running app; divergent duplicates are not in the dry-run equivalence test; the ported planner must be re-diffed on a jj-lib bump (deferred).
