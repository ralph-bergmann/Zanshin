---
title: 'Story 10.14 — Bookmarks in the floating rail: hover preview and pinned panel, every bookmark, dimmed outside the view, pick to reveal'
type: 'feature'
created: '2026-11-01'
status: 'done'
baseline_revision: '90be0e5f21c125b6505d58547ef8cc8a21b3c621'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-10-context.md'
warnings: ['oversized']
deferred:
  - summary: >-
      A bookmark row in the rail starts no drag yet: dragging a local row onto a change (and its stale/remote/@ refusals) waits for 10.10's drop side.
    evidence: |-
      epics.md Story 10.14, 2026-10-14 note "Drag (GV:416)" and witness "a remote row starts no drag"; bookmark_list_view.dart has no drag source; 10-10-graph-drag-and-drop is backlog, so there is no drop target to drag onto.
    location: >-
      app/lib/src/features/bookmarks/bookmark_list_view.dart
    severity: medium
  - summary: >-
      The Bookmarks preview and panel are not yet checked visually in the catalogue against the DS rows (chrome.jsx ZKBookmarkList, kit.css .zk-bl).
    evidence: |-
      Widget tests cover structure, text, opacity and colours only; the Marionette check of bookmarks/bookmarks/{preview,panel,empty,stale} did not run in the unattended loop (no long-lived flutter run).
    location: >-
      app/widgetbook/folders/bookmarks.dart
    severity: low
---

<intent-contract>

## Intent

**Problem:** The rail has only the Undo Timeline; the design's Bookmarks item (preview + pinned panel listing every bookmark, dimmed when outside the view, pick to reveal) is missing, and 9.29's untracked / `(deleted)` / `(not created yet)` rows, synced / conflicted flags and ahead/behind distances (deferred-work I1) and 9.11's track/untrack verbs (I2) have no surface.

**Approach:** A `BookmarkListModel` (per open repository, beside the Undo Timeline's host) reads `bookmarks(allRemotes: true)` whenever the graph's landed layout moves to a new operation, resolves each row's target against the layout, fetches subjects of hidden targets through `findChanges` + `content` at that operation, and feeds a `bookmarksRailItem` (preview + panel). A pick goes through the graph search's `goTo` (visible → select/reveal/pulse; hidden → `all()` shown in the search field, persisted). Track/untrack run as two new `GraphAction`s through `GraphViewModel.run`.

## Boundaries & Constraints

**Always:**
- Rows in `jj bookmark list --all-remotes` order (the CLI's `ui.bookmark-list-sort-keys`, default name); the `git` remote's rows are left out (jj's mirror of the colocated Git refs, not a remote; the CLI's own `--tracked` leaves it out too). Rows keyed by (name, remote).
- Row: `ZI.bookmarkFilled` glyph (`--text-dim`), the name (`name@remote` for a remote row; mono 12), sub-line "id · subject" — id = jj's shortest prefix bold, max(prefix, 8) chars, one `Text.rich` (decision 16.35); subject or "(no description set)" (jj's words) — and the state (DS kit.css:73-81, graph.css:56-57). Rows whose target is not in the layout at opacity .55.
- State column (from 9.29's fields only, never by pairing targets): local row — `conflicted` → conflict mark; no tracked non-`git` remote row of that name → "local"; `synced` → "✓"; else from the first tracked remote row's distances: remote `behind`>0 (local has more) only → "↑N", `ahead`>0 only → "↓N", both → "↕" (diverged). Remote row — untracked → "remote"; tracked & `synced` → "✓"; tracked otherwise → arrows from the remote's own view: `ahead`>0 only → "↑N", `behind`>0 only → "↓N", both → "↕". `target == null`: local → "deleted", remote → "not created yet". A divergent target reads "divergent". The long form (ZK_BM_STATE style, "in sync with origin" …) is the row's semantics label/tooltip text. N = `lower` (`upper` null → "N+").
- Pick: target change id → first layout node whose `changeIdOf` equals it (divergent: first such node in index order; conflicted: 9.29's first added target) → `GraphSearchController.goTo(key, bookmark: display, recent: false)`; not in the layout → `goTo(changeId, commitId: <first found commitId>, recent: false)` (switches to `all()`, shown as `$ all()` in the field and persisted — 10.21). A pick needing `all()` while the graph is stale is disabled with "Working copy is stale". Rows with `target == null` are not pickable.
- Preview: header "Bookmarks" + row count (11.3's `RailPreview`), first 5 rows, "+N more" (`.zk-co-more`) which pins the panel (`ShellScope.maybeOf(context)?.activate('bookmarks')`); a row click closes the preview (`closePreview`) then picks. Panel: the full list as a lazy `ListView(primary: true)` (`scrolls: true`), stays pinned after a pick.
- Empty: "No bookmarks yet. Create one with `jj bookmark create <name>`." (decision 16.44). Stale (`jj.stale_working_copy` from `bookmarks()`): keep the last rows, show "Working copy is stale" above them. Inactive window: no hover paint, no focus ring (`ZsAppearance.of(context).inactive`).
- Track / untrack (I2): a row shows on hover or keyboard focus one Zs button — untracked remote row → "Track" (`jj bookmark track <name>@<remote>`), tracked remote row → "Untrack" (`jj bookmark untrack <name>@<remote>`); never on local rows or `git` rows. Tooltip = the command; disabled with a reason while `!actionsEnabled` (busy / stale). Result toast: "Started tracking ‹name@remote›" / "Stopped tracking ‹name@remote›"; app menu Undo/Redo names "Track/Untrack ‹name@remote›".
- Strings through `app_en.arb` (+ `flutter gen-l10n`); jj's words and commands marked `// l10n-ignore: <reason>`.

**Never:** No row drag (10.10 owns bookmark drags; no drag source here). No list search/filter. No bookmark create/delete/move/rename surface (10.15). No `synced` derived by comparing a local and a remote target. No edits to `design/` or `design_system/`. No new Rust/FFI — the bridge already exports `Bookmark`, `BookmarkKind`, `LocalBookmark`, `RemoteBookmark`, `RefDistance` and `bookmarkTrack` / `bookmarkUntrack`.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Visible pick | row target in layout | selects + centres + pulses its card, no request, panel stays pinned | — |
| Hidden pick | untracked `release/1.5.x@origin`, target not in default view | one `all()` request; field shows `$ all()`; target selected + revealed (not @); a later Card-width change keeps the anchor | — |
| Divergent | target change has 2 commits in layout | row "divergent"; pick selects the first node of that change | — |
| Deleted / not created | `target == null` | row shows "deleted" / "not created yet", not pickable, dimmed (no target in the layout) | — |
| Stale | `bookmarks()` throws `jj.stale_working_copy` | last rows kept + "Working copy is stale"; visible pick works; hidden pick + Track/Untrack disabled with reason | model sets `stale`, keeps rows |
| Read failure | other `ZanshinFfiException` | last rows kept, a one-line failure note | logged, retried on next operation |
| External create | an op adds a bookmark | after the graph reloads, the new row appears | — |
| Track | untracked remote row, Track | `GraphViewModel.run(GraphBookmarkTrack)` → `bookmarkTrack(['name@remote'])`; toast; row turns tracked after reload | refusal published as the outcome (toast) |

</intent-contract>

## Code Map

- `app/lib/src/features/home/home_page.dart:209-271` -- `_UndoTimelineHost`: per-repo model lifecycle + rail item list; extend it (or a sibling host) to also create the `BookmarkListModel` and add `bookmarksRailItem` FIRST (rail order Bookmarks, Undo; shell_controller.dart:11). It needs the graph slots (`graph.model`, `graph.search`) — pass them like `actions: graph.model` at :89-91.
- `app/lib/src/features/undo_timeline/undo_timeline_view.dart` / `undo_timeline_model.dart` -- the sibling template: rail item factory, preview, lazy panel, `_Note`, hover/focus row actions, `_action` (ZsTooltip + ZsButton + disabledReason), stale handling via `isStale(error)`.
- `app/lib/src/features/shell/shell_controller.dart:14-47` -- `ShellRailItem` (id `bookmarks`, label, icon `ZI.branch` per DS chrome.jsx:8, count, preview, panel, `scrolls`); `activate`, `closePreview` at :218-242.
- `app/lib/src/features/shell/shell_scope.dart:46` -- `ShellScope.maybeOf` for the preview's "+N more" and row-click close.
- `app/lib/src/features/graph/graph_search_controller.dart:96-105` -- `goTo(key, {bookmark, commitId})`; add `bool recent = true` (a rail pick does not enter Recent).
- `app/lib/src/features/graph/graph_view_model.dart:403-414, 859-905` -- `goToHidden` + `_land`'s commit-id rekeying (hidden/divergent in `all()`); `layout`, `content`, `stale`, `actionsEnabled`, `logDefaults.shortPrefixes`, `run`.
- `app/lib/src/features/graph/graph_layout.dart:182-296` -- `indexOfKey`, `changeIdOf`, `commitIdOf`, `changeIdPrefixLengthOf`, `isDivergent`, `contentOf`, `operationId`, `nodeCount`.
- `app/lib/src/features/graph/graph_content.dart` -- `GraphContent.of(layout, node)` for visible subjects.
- `app/lib/src/features/graph/graph_ports.dart:337-430, 654-693, 831-895` -- add `GraphBookmarkTrack(name, remote)` / `GraphBookmarkUntrack(name, remote)` (command `jj bookmark track <sym>@<sym>` via `_revsetSymbol`; `pendingKeys` empty) and their `RepoGraphActions.run` arms (`handle.bookmarkTrack([symbol])` / `bookmarkUntrack`). `GraphSearchSource.findChanges`/`content` are the hidden-subject reads.
- `app/lib/src/features/graph/graph_toasts.dart:245-288` -- exhaustive switch: add track/untrack cases.
- `app/lib/src/features/shell/app_menu.dart:183-206` -- exhaustive `actionName`: add track/untrack.
- `packages/zanshin_core/lib/src/ffi/bookmarks.dart:102-185` -- `Bookmark` (target nullable, conflicted, synced, kind), `RemoteBookmark(tracked, ahead, behind)`, `RefDistance(lower, upper)`.
- `packages/zanshin_core/lib/src/worker/handle.dart:305-345, 2625-2665` -- `bookmarks({allRemotes})`, `bookmarkTrack` / `bookmarkUntrack` (names = `BOOKMARK@REMOTE` symbols).
- `_bmad-output/implementation-artifacts/design_system/ui_kits/desktop/chrome.jsx:13-14,112-131` + `kit.css:68,73-81` + `components/graph/graph.css:56-57` -- row look, state glyphs and colours (`--add` ahead, `--rem` behind, `--remote` remote).
- `app/lib/l10n/app_en.arb` -- `staleTitle` exists (:271); add the bookmarks strings.

## Tasks & Acceptance

**Execution:**
- `app/lib/src/features/graph/graph_ports.dart` -- add `GraphBookmarkTrack` / `GraphBookmarkUntrack` + their `RepoGraphActions` arms -- I2 routed like the graph's other verbs.
- `app/lib/src/features/graph/graph_toasts.dart`, `app/lib/src/features/shell/app_menu.dart` -- handle the two new actions in the exhaustive switches -- compile + toast/menu text.
- `app/lib/src/features/graph/graph_search_controller.dart` -- `goTo(..., {bool recent = true})` -- a rail pick skips Recent.
- `app/lib/src/features/bookmarks/bookmark_list_model.dart` (new) -- `BookmarkListSource` port (`bookmarks()`, `findChanges`, `content`) with a `RepoBookmarkListSource`; `BookmarkListModel` listening to the `GraphViewModel`: re-reads when `layout.operationId` changes (and when stale clears), at most one read plus one queued; builds `BookmarkRow`s (bookmark, display name, key-in-layout or null, commitId for a hidden target, prefix length, subject, state enum + distance, divergent, pickable); `stale`, `error`, `rows`; `pick(row)` and `trackAction(row)` helpers -- the data, testable without widgets.
- `app/lib/src/features/bookmarks/bookmark_list_view.dart` (new) -- `bookmarksRailItem(strings, model, search, actions)`, `BookmarkListPreview`, `BookmarkListPanel`, the row widget (hover/focus Track/Untrack button) -- the UI.
- `app/lib/src/features/home/home_page.dart` -- host the model per repository and put the Bookmarks item first in the rail -- mounting (e).
- `app/lib/l10n/app_en.arb` (+ `flutter gen-l10n`) -- title, count, "+{n} more", empty sentence, states (short + long), Track/Untrack, toasts, menu names, failure note.
- `app/test/features/bookmarks/bookmark_list_model_test.dart`, `app/test/features/bookmarks/bookmark_list_view_test.dart` (new), `app/test/features/graph/graph_ports_test.dart` (+ commands of the new actions), `app/test/features/graph/graph_toasts_test.dart` (+ track toast), `app/test/features/graph/graph_search_controller_test.dart` (+ `recent: false`) -- witnesses below, fake ports.

**Acceptance Criteria:**
- Given local, tracked-remote, untracked-remote and `git` rows, when the panel shows, then every non-`git` row appears in the source's order, each keyed by (name, remote), and a row whose target is outside the layout has opacity .55.
- Given rows whose targets differ (local rewritten, both share a change id) with `synced == false`, when the state shows, then it comes from 9.29's flags/distances only (↑/↓/↕), never "✓" by pairing.
- Given more than 5 rows, when the preview opens, then its header shows the total, 5 rows show, and "+N more" pins the panel; a row click closes the preview and picks; after a pick in the pinned panel it stays pinned.
- Given a hidden target, when picked, then the search field shows `all()`, the target (not @) is selected and revealed in the layout that request lands, and a following Card-width change does not jump to @; reopening the repository restores `all()`.
- Given an empty repository, when the panel shows, then it shows the DS empty sentence.
- Given the stale state, when a visible row is picked it selects and reveals; a hidden row's pick and Track/Untrack are disabled and show "Working copy is stale".
- Given an untracked remote row, when Track is pressed, then `GraphViewModel.run` receives `GraphBookmarkTrack` whose command is `jj bookmark track <name>@<remote>` and the handle gets `['<name>@<remote>']`; the toast reads "Started tracking ‹…›".
- Given an external `jj bookmark create`, when the graph reloads after the op-heads change, then the row appears.

## Spec Change Log

## Review Triage Log

### 2026-11-01 — Review pass
- verdicts: 35 findings — high 0, medium 6, low 24, false 5, maybe-false 0 (intent-audit divergences counted as findings)
- findings:
  - verification-gap
    - `[medium]` `[patch]` RepoGraphActions' track/untrack arms never run against a real handle — added a real-repo test (in-test remote + remote bookmark; Track then Untrack flip `tracked`).
    - `[medium]` `[patch]` RepoBookmarkListSource (`allRemotes: true`, content keyed by commit id) never run — covered by the same real-repo test.
    - `[low]` `[reject]` no test of a hidden divergent pick passing the commit id — narrow (hidden and divergent at once); the commit-id landing is pinned by graph_view_model_test.dart:495; adding it needs a commit-id-keyed fake layout.
    - `[medium]` `[patch]` read storm: with the list stale and the graph not, every graph notify re-reads (same root cause as blind #1 / edge #2) — `_graphChanged` re-reads only on a new operation or the graph's stale → not-stale transition.
    - `[low]` `[reject]` the busy disabled reason of Track is untested — a one-word string choice on an already-tested branch shape.
  - blind-hunter
    - `[medium]` `[patch]` read storm (grouped above).
    - `[low]` `[patch]` `_targets` catches only `ZanshinFfiException`, so a non-FFI error drops a good read (same as edge #4/#9) — catches any error, logs, leaves subjects empty.
    - `[low]` `[reject]` `FoundChanges.truncated` ignored beyond 1000 targets — marked shortcut in code; a repository with >1000 bookmark targets is not everyday use; the fix is paging.
    - `[low]` `[patch]` row keys collide for a local name `x@origin` vs the remote row `x@origin` (same as edge #1) — rows keyed by the (name, remote) pair.
    - `[low]` `[reject]` toast/menu show `name@remote` unquoted while the command quotes — human-facing label; the tooltip shows the exact command; only names needing quoting differ.
    - `[low]` `[patch]` test gap for the RepoGraphActions arms (grouped with verification-gap #1).
    - `[low]` `[reject]` whole shell rebuilds on each list notify — as often as the graph already rebuilds it (once per landed layout); no measured cost.
    - `[low]` `[patch]` failure note may span lines — `_Note` ellipsizes to one line.
    - `[low]` `[reject]` "↕" shown when jj gave no distances — only reachable for an unsynced tracked pair without counts (an absent target is handled separately); recorded as a choice in the verification notes.
    - `[low]` `[reject]` fallback prefix 2 is a magic number — the same fallback the toasts and the search use (`graph_toasts.dart` `_prefix`); only when the lookup failed.
    - `[low]` `[reject]` untested: "(no description set)", lookup-failure subjects, conflict icon in the view, inactive focus ring, real reopen — each a single-branch rendering detail or covered at the store level; no defect found.
    - `[low]` `[reject]` `_BookmarksHost` lifecycle untested — mirrors `_UndoTimelineHost`; the home-page test covers presence and removal on close.
  - edge-case-hunter
    - `[low]` `[patch]` ValueKey collision (grouped with blind #4).
    - `[medium]` `[patch]` read storm (grouped).
    - `[low]` `[reject]` hidden divergent pick with a null commit id (lookup failed / >1000) misses its landing — only after a failed lookup; the pick still switches to `all()`.
    - `[low]` `[patch]` non-FFI error in `_targets` (grouped with blind #2).
    - `[low]` `[reject]` an unsynced row with both distances 0/null reads diverged (grouped with blind #9).
    - `[false]` `[reject]` repo and search could change in different rebuilds on a project switch — both are read in the same `ProjectGraphHost` builder run, which rebuilds on the same session notification that changes `projects.repo` (`project_graph_host.dart` `_sync` → `setState`).
    - `[false]` `[reject]` an untracked conflicted/divergent remote shows the conflict mark, not "remote" — the spec's state rules put conflicted first for every row; the Track button still marks it untracked.
    - `[false]` `[reject]` the preview offers no Track/Untrack — I2 asks for the row action in the panel; the preview is hover-only and not announced.
    - `[low]` `[patch]` `_targets` claim (grouped with blind #2).
  - intent-alignment
    - `[medium]` `[defer]` the 2026-10-14 note's drag wiring (a local row drags its bookmark onto a change; remote rows and names with `@` do not; stale disables drags) is not shipped — the drop side is 10.10 (backlog), so the drag source belongs with it.
    - `[false]` `[reject]` `## Auto Run Result` missing — written at finalize.
    - `[false]` `[reject]` resize/collapse/flyout witnesses untested here — 11.3's shell owns and tests them (`shell_layout`, `pinned_panel` tests); the panel body is the same widget in both places.
    - `[low]` `[reject]` Card-width witness tested via a reload — Card width issues no request at all (Story 10.5), so a reload is the strictly harder case.
    - `[low]` `[reject]` bold prefix not asserted on the span — the model tests pin the prefix lengths and the view uses the one shared rendering of decision 16.35.
    - `[low]` `[reject]` sort not proven on unsorted input — the order is jj's (`ui.bookmark-list-sort-keys`, default name), as `jj bookmark list`; the view does not sort.
    - `[low]` `[reject]` `@git` rows left out although `--all-remotes` lists them — jj's mirror of the colocated Git refs would duplicate every local bookmark; documented in the code.
    - `[low]` `[reject]` hidden subjects read at the shown layout's operation, not the `all()` one — the list re-reads when the `all()` layout lands (new operation id), so they agree.
    - `[low]` `[defer]` Marionette visual check not run in the unattended loop — mirrored to deferred-work.md.

## Design Notes

- Reload trigger = the graph's landed layout operation id: subjects of hidden targets are fetched "by commit id at the returned operation" (design answer (b)), and the list stays coherent with what is dimmed. Hidden subjects: one `findChanges(op, 'change_id(<a>) | change_id(<b>) …', limit: 1000, shortPrefixes: defaults.shortPrefixes)` (also yields the commit id for `goToHidden` and the prefix length), then one `content(op, commitIds)`; a failure leaves those subjects null (the row shows the id only) and is logged.
- The rail's mechanics (hover intent, pin, collapse/flyout, resize 240–440, insets) are 11.3's and already shipped; this story supplies only the item.
- DS synced through the DS export in `design_system/` as of 2026-10-29 (record the DS change-log number found in `design_system/readme.md` in the verification notes).

## Verification

**Commands (gate rule for this run: no `cargo make test`/`test-full`/`coverage`):**
- `cd app && flutter gen-l10n` -- expected: regenerates `app_localizations*.dart` (commit them)
- `flutter test` in `app/` (at least `test/features/bookmarks/ test/features/graph/ test/features/home/ test/features/shell/`, then the whole suite) -- expected: all pass
- `dart analyze --fatal-infos app` -- expected: no issues
- `dart format --set-exit-if-changed app` -- expected: exit 0

**Manual checks:**
- Marionette in the Widgetbook catalogue / running app if available: the preview and the pinned panel against DS chrome.jsx's rows; record outcome (or why it was not possible) in the verification notes.

## Verification Notes

- DS synced through #15 (`design_system/readme.md`, 2026-10-29).
- `flutter gen-l10n`, `dart analyze --fatal-infos app` (no issues), `dart format --set-exit-if-changed app` (0 changed).
- `flutter test` in `app/`: all pass (1546); `worker_project_repos_test.dart`'s 5 real-worker tests need the gate's pinned `XDG_CONFIG_HOME` and pass with it (unrelated to this story).
- Marionette not run: the catalogue needs a long-running `flutter run`, which this unattended run may not start. A catalogue folder `bookmarks/bookmarks/{preview,panel,empty,stale}` was added for that check (`zanshinCatalogue.open path=bookmarks/bookmarks/panel`).
- Implementation choices: the one `findChanges` looks up every row's target (not only the hidden ones) — the same single call, and it also gives the divergence count and the commit id a later hidden pick needs; `bookmarksRailItem(strings, model)` takes only the model (the model holds the search, whose `model` is the graph runner); Track/Untrack show in the pinned panel only (the preview is hover-only and not announced); a local row whose tracked remote is "not created yet" reads "↑" ("not on ‹remote› yet"), and distances jj leaves null on an unsynced row read "↕".
- Re-verification after the review patches (parent run, 2026-11-01):
  - `flutter gen-l10n`: clean, no diff.
  - `dart analyze --fatal-infos` in `app/`: no issues.
  - `dart format --set-exit-if-changed` in `app/`: 0 files changed.
  - `flutter test` in `app/` with `XDG_CONFIG_HOME=target/test-xdg-config`: 1546 pass, 1 fails. The failure is `repo_graph_source_test.dart` (an empty authorName); that file is untouched and passes without the XDG dir.
  - `flutter test` in `app/` without that XDG dir: 1542 pass, 5 fail. The failures are the `worker_project_repos_test.dart` real-worker tests; that file is untouched and passes with the XDG dir.
  - Every bookmarks, graph, shell and home test passes in both environments.
  - No Rust or FFI code changed, so no cargo checks apply.

## Auto Run Result

Status: done. Code commit `e1f773091695a3bcd19c1484df44f8fda0f79b0a`.

**Summary.** The rail now holds a Bookmarks item, placed before the Undo Timeline.
- A `BookmarkListModel`, one per open repository, reads `bookmarks(allRemotes: true)` each time the graph's landed layout moves to a new operation. Rows of the `git` remote are left out.
- Each row resolves its target against the layout. One `findChanges` call and one `content` call fetch the targets' commit ids, prefixes and subjects at that operation.
- States come from 9.29's flags and distances only.
- Picking a row goes through `GraphSearchController.goTo(…, recent: false)`. A visible target is selected, revealed and pulsed. A hidden target switches the view to `all()`, which the search field shows and which persists.
- `GraphBookmarkTrack` and `GraphBookmarkUntrack` run through `GraphViewModel.run`, with a toast and Undo/Redo names in the menu.
- The rail item has a preview (5 rows, "+N more" pins the panel) and a pinned panel (a lazy list, Track/Untrack on hover or focus). It also covers the empty, stale, failed-read and inactive-window states.

**Files.**
- `app/lib/src/features/bookmarks/bookmark_list_model.dart`: new. The read port, the model, the rows and the row states.
- `app/lib/src/features/bookmarks/bookmark_list_view.dart`: new. The rail item, the preview, the panel and the row tile.
- `app/lib/src/features/graph/graph_ports.dart`: the Track and Untrack actions, `remoteBookmarkSymbol`, and the `RepoGraphActions` arms.
- `graph_toasts.dart` and `shell/app_menu.dart`: toast text and menu names for the new actions.
- `graph_search_controller.dart`: `goTo(recent:)`.
- `home/home_page.dart`: `_BookmarksHost`, which mounts the item first in the rail.
- `l10n/app_en.arb` and the generated localizations: the strings.
- `widgetbook/folders/bookmarks.dart` and `catalogue.dart`: catalogue cases.
- Tests:
  - new: `test/features/bookmarks/*` and `graph_search_controller_test.dart`, plus the helper `helpers/fake_bookmark_list.dart`;
  - extended: `graph_ports_test` (now with a real-repo Track/Untrack test), `graph_toasts_test`, `app_menu_test`, `home_page_test`, `catalogue_smoke_test` and `graph_harness`.

**Review.** One pass found 35 findings: 6 medium, 24 low, 5 false.
- Patched: 5 entries (3 medium, 2 low).
  - The read storm while only the list is stale.
  - The real-repo test of Track, Untrack and `RepoBookmarkListSource`.
  - The catch-all in `_targets`.
  - Row keys made from the (name, remote) pair.
  - A one-line failure note.
- Deferred: 2 items, mirrored to deferred-work.md.
  - The row drag source goes with 10.10's drop side.
  - The Marionette visual check.
- Rejected: every other finding, each with its reason in the Review Triage Log.

**Follow-up review:** not recommended. The pass patched 3 medium entries but no high ones, and the patched risks are now covered by the new tests. Patched counts by verdict: 3 medium, 2 low.

**Open items:**
- I1: fixed (`e1f773091695a3bcd19c1484df44f8fda0f79b0a`). The panel shows 9.29's untracked-remote, `(deleted)` and `(not created yet)` rows. It also shows the synced and conflicted flags and the ↑N/↓N/↕ distances, all taken from the bridge's fields and never derived by pairing targets.
- I2: fixed (`e1f773091695a3bcd19c1484df44f8fda0f79b0a`). An untracked remote row in the panel offers Track (`jj bookmark track <name>@<remote>`), and a tracked one offers Untrack. Both go through the existing `bookmarkTrack` and `bookmarkUntrack` bridge verbs and run through `GraphViewModel.run`, like the graph's other actions. The menu entry is still 10.15's.

**Residual risks:**
- Bookmark targets beyond 1000 commits get no subject or commit id. This is a shortcut marked in the code.
- The Marionette check has not run.
- The row drag waits for 10.10.
