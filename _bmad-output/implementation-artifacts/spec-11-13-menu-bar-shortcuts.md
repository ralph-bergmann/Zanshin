---
title: 'Story 11.13 — Menu bar and shortcuts'
type: 'feature'
created: '2026-11-01'
status: 'done'
baseline_revision: 'fca42c4b1381d9816cb4ba1854f529084789182b'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-11-context.md'
warnings: ['oversized']
deferred:
  - summary: >-
      No project window publishes its graph to the menu bar yet, so the graph-bound items stay grey in the app.
    evidence: |-
      AppMenuModel.graph is written only by app_menu_test.dart; GraphView is not in HomePage until 10.12, which binds GraphMenuBinding and retires GraphSearchShortcuts' own Cmd-F.
    location: >-
      app/lib/src/features/shell/app_menu.dart
    severity: medium
    resolved: >-
      2026-11-01 — fixed (spec-10-12-adopt-backend-layout, commit 6b9feacb): the mounted graph is published as appMenu.graph (GraphMenuBinding) and cleared on unmount; GraphSearchShortcuts' own Cmd-F is retired.
  - summary: >-
      Toggles carry no checkmark and Minimize, Zoom, Enter Full Screen are not greyed for dialog windows.
    evidence: |-
      PlatformMenuItem has no checked state; FlutterMenuPlugin.mm returns the copied system item before applying enabled.
    location: >-
      app/lib/src/features/shell/app_menu.dart
    severity: low
  - summary: >-
      The Window menu may not list the open windows.
    evidence: |-
      The engine sets a fresh NSApp.mainMenu and never NSApp.windowsMenu; unverified in the running app.
    severity: low
  - summary: >-
      Help > jj Documentation's URL carries the jj version separately from the jj-lib pin.
    evidence: |-
      jjDocumentationUrl hard-codes v0.46.0; the pin-bump checklist (agent context) does not name it.
    location: >-
      app/lib/src/features/shell/app_menu.dart
    severity: low
---

<intent-contract>

## Intent

**Problem:** The menu bar is the runner's stock `MainMenu.xib`: "Preferences…" without an action, no File menu, no Close ⌘W, a Find submenu that claims ⌘F and ⌘J, and none of the DS menus (DS readme.md:196–209). Nothing reaches Reload ⌘R (I1, I2), ⇧⌘O / ⌘, (I4) or ⌘W (I5), commands could act behind an open sheet (I3), and the menu's strings are outside the ARB (I6).

**Approach:** Design question (a)'s recommendation: the menu is built in Dart — one `PlatformMenuBar` above the `WindowManager`, its labels from `app_en.arb`, the system items as `PlatformProvidedMenuItem`s — over an `AppMenuModel` that follows the key window, the open project, the sheets and (once a project window publishes it) the graph. Every item runs its handler or is grey when none is reachable.

## Boundaries & Constraints

**Always:**
- Menus and order as epics.md Story 11.13 scope 1 (Title Case, "…" for items that open a window or sheet); no two items share a key equivalent; the xib's Preferences… item and Find submenu go.
- Routing: ⌘W = the key window's red-button path (`AppWindows.requestClose`; the project window's close handler asks the close guards, then closes the project and shows Projects). ⇧⌘O and Window › Projects = `openProjects`. File › Open Recent = the capsule's Recent behaviour. View › Reload ⌘R = `ProjectSession.refresh()` plus the bound graph's `reload()`.
- Change items target the selection, else @ (`GraphViewModel.actionTarget`), pass the change id in full and name the target ("Abandon @", "Abandon kmnvxoqp": max(prefix, 8) characters). Edit and Revert are grey while the target is @. Change, Go, View-graph, Find (project window) and Undo/Redo are grey while no graph is bound, while the runner is busy or the working copy stale (`actionsEnabled`).
- Undo/Redo: a focused text field's undo/redo first; else the bound graph's `undoLast`/`redoLast`, enabled only while `undoable`/`redoable`, labelled "Undo ‹verb› ‹target›". Cut/Copy/Paste/Select All dispatch the text intents to the primary focus.
- While a `ZsSheet` shows in the project window, every item acting on the project window (Close Window there, Open Recent, Reload, Find there, Undo/Redo, View-graph, Change, Go) is grey (I3); while one shows in the key window, Close Window is grey.
- An item whose handler story has not landed is grey: Settings… ⌘,, Project Settings… (11.7), Edit Configurations… ⌥⌘L (10.22), Show Minimap (10.16), Describe… (10.15), Fetch, Push… ⇧⌘P (11.8), Zanshin Help (non-goal).
- Every label is an ARB string (`platformStrings()`); jj's words stay `// l10n-ignore`.

**Never:** no Dart key handler duplicating a menu shortcut (key equivalents reach Flutter first and bubble to the menu only when unhandled — the engine's `performKeyEquivalent`); no About window, Help content, context menus or Project-menu changes; no native method channel (the xib fallback is not needed); no CFBundleLocalizations while the app is English only.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| ⌘W project window | key = main | close guards, then `closeProject()`, Projects shows | a refusing guard keeps everything |
| ⌘W other window | key = projects | the window closes (exit rule as the red button) | — |
| No key window | before the first focus event | Close Window grey | — |
| Sheet open | a ZsSheet in the project window | project items grey; Settings-side items unaffected | — |
| No selection | graph bound, @ = `wc` | "Abandon @" runs `jj abandon <wc id>`; Edit, Revert grey | — |
| Selection | selected `kmnvxoqp…` | "Abandon kmnvxoqp", Go › Selection enabled | — |
| Stale / busy | `actionsEnabled` false | Change and Undo/Redo grey | — |
| Undo | own op still head | "Undo Abandon kmnvxoqp" → `undoLast` | foreign head → runner's refusal |

</intent-contract>

## Code Map

- `app/lib/src/features/bootstrap/boot_window_host.dart:129-141` -- `_present` runs the one `runWidget` around `WindowManager`; the `PlatformMenuBar` wraps it there, its tree shape fixed from the first frame (a boot menu until the model arrives).
- `app/lib/main.dart:120-145` -- `_startApp` builds the component and coordinator; the place to attach the menu model (windows, coordinator, Projects' GlobalKey).
- `app/lib/src/features/window/app_windows.dart:409-420` -- `_closeRequested` (the red button); `requestClose(key)` reuses it. Window lookup by view id is new here.
- `app/lib/src/features/window/app_window_coordinator.dart:175-189` -- the project window's close handler (guards, `closeProject`).
- `app/lib/src/features/window/active_window_tracker.dart:28` -- `_keyView` private; the menu needs it.
- `app/lib/src/features/home/home_page.dart:50-105` -- focus refresh (`projects.refresh`) and `_openRecent` (failed open → Projects notice); the menu reuses the latter.
- `app/lib/src/features/graph/graph_view_model.dart:366-535` -- `actionTarget`, `actionsEnabled`, `hasActions`, `run`, `undoLast`/`redoLast`, `undoable`/`redoable`, `select`, `revealKey`, `scrollToSelection`, `scrollToWorkingCopy`, `reload`.
- `app/lib/src/features/graph/graph_ports.dart:178-451` -- `GraphEdit`, `GraphNew`, `GraphAbandon`, `GraphRevert`, `GraphSquash`, bookmarks, `GraphUndo`/`GraphRedo`.
- `app/lib/src/features/graph/graph_preferences.dart:81-89` -- View › Free/Compact/Detailed Cards/Group Stacks setters.
- `app/lib/src/features/projects/projects_window.dart:155` -- `_searchFocus` for ⌘F while Projects is key.
- `packages/zanshin_ui/lib/src/materials/zs_sheet.dart:88-130` -- the sheet's state; it publishes the views showing one.
- `app/macos/Runner/Base.lproj/MainMenu.xib:35,116-152` -- Preferences… and the Find submenu; the remaining items are the sources the engine copies `PlatformProvidedMenuItem`s from (`FlutterMenuPlugin.mm` `findProvidedMenuItem`), so they stay.
- `app/lib/l10n/app_en.arb` -- new `menu*` keys; `flutter gen-l10n` regenerates `app_localizations*.dart`.
- Read-only: `GraphView` is not in `HomePage` until 10.12, so in the running app no graph is bound yet.

## Tasks & Acceptance

**Execution:**
- `packages/zanshin_ui/lib/src/materials/zs_sheet.dart` -- `ZsSheet.openViews` (`ValueListenable<Set<int>>`): the view ids showing a sheet, added on mount, removed on dispose; test in the package -- I3's modal flag.
- `app/lib/src/features/window/active_window_tracker.dart` -- public `keyView` -- the menu's key window.
- `app/lib/src/features/window/app_windows.dart` -- `requestClose(key)` (the red button's path) and `keyOfView(viewId)` / `viewIdOf(key)`; tests -- ⌘W and the key window.
- `app/lib/src/features/home/home_page.dart` -- extract `_openRecent` to a top-level `openRecentProject(session, actions, path)` -- shared with File › Open Recent.
- `app/lib/src/features/projects/projects_window.dart` -- `ProjectsWindowState.focusSearch()` -- ⌘F while Projects is key.
- `app/lib/src/features/shell/app_menu.dart` (new) -- `GraphMenuBinding` (model, preferences, focusSearch), `AppMenuModel` (`@inject @singleton`, tracker + session; `attach(windows, actions, projects)`; `graph` slot; listens to tracker, session, sheets, the bound graph) and `menus(strings)` building the `PlatformMenu` tree; `AppMenuBar` widget -- the menu bar.
- `app/lib/main.dart` -- `MainComponent.appMenu`, attach after the coordinator, Projects' `GlobalKey`; host gets the model's slot; regenerate `main.inject.dart` -- wiring.
- `app/lib/l10n/app_en.arb` + gen-l10n -- menu strings -- I6.
- `app/macos/Runner/Base.lproj/MainMenu.xib` -- drop Preferences… and the Find submenu -- the stock ⌘F/⌘J.
- `app/test/features/shell/app_menu_test.dart` (new) -- the witnesses below over fake windows, a fake session and a real `GraphViewModel` on scripted ports.

**Acceptance Criteria:**
- Given the menus, when collected, then the eight top menus appear in order with the DS items and no key equivalent repeats.
- Given each item with a handler, when selected, then it calls exactly that handler; items without one are grey (`onSelected == null`).
- Given the project window key, when Close Window is selected, then the close guards are asked and the project closes; with Projects key, Projects closes.
- Given a graph bound with no selection, then Change items read "… @" and act on @'s full id, Edit and Revert are grey; given a selection, they name its id and Go › Selection/Parent/Child are enabled.
- Given Go › Selection or Working Copy, when selected, then the scroll is requested and the selection is unchanged.
- Given an own undoable operation, then Undo reads "Undo ‹verb› ‹target›" and runs `undoLast`; after a foreign/none it is grey.
- Given a sheet open in the project window, then the project items are grey.
- Given View › Reload, when selected, then `ProjectSession.refresh` runs once and the bound graph reloads.

### 2026-11-01 — Review pass
- verdicts: 30 findings — high 0, medium 4, low 15, false 6, maybe-false 5
- findings:
  - verification-gap: `[medium]` `[patch]` Text-field-first Undo/Redo and the text intents never exercised — added a test with a focused EditableText: plain "Undo", no GraphUndo, Select All/Copy enabled only in the field.
  - verification-gap: `[low]` `[patch]` Find → Projects' `focusSearch` never reaches a real `ProjectsWindowState` — added a test calling the real state's `focusSearch()` (focus + full selection).
  - verification-gap: `[low]` `[patch]` `AppMenuBar` tested only with a null model — added a widget test: model menus, rebuild on a key-window change.
  - verification-gap: `[low]` `[reject]` `main.dart`'s `menu.value = appMenu` untested — one line in an entry point no test boots; a fix needs a boot harness.
  - verification-gap (other): `[low]` `[patch]` `_intent` enables Cut/Copy/Paste/Select All on any focus — now built from `_textField`.
  - blind: `[medium]` `[defer]` No production code publishes `graph`, so the graph items stay grey in the app — by design until 10.12 mounts the graph; mirrored to deferred-work.md.
  - blind: `[false]` `[reject]` ⌘⌫ Abandon fires inside a text field — the engine sends key equivalents to the Flutter view first (`FlutterViewController.mm` `performKeyEquivalent`); EditableText handles ⌘⌫, the menu sees it only when unhandled.
  - blind: `[low]` `[patch]` Cut/Copy/Paste/Select All enabled without a text field — same fix as above.
  - blind: `[low]` `[patch]` text paths untested — same test as above.
  - blind: `[low]` `[patch]` Find on Projects not greyed behind a Projects sheet — now requires no sheet there.
  - blind: `[low]` `[patch]` `focusSearch` bool unread — now a `VoidCallback?`.
  - blind: `[false]` `[reject]` Reload not gated on busy — `reload()` only queues a layout request (`_requestLayout` coalesces via `_queued`), harmless during a run.
  - blind: `[maybe-false]` `[reject]` Go/View greyed while busy is over-greying — the spec chose it; scrolling while busy is a nicety, not a defect; settling it is a spec choice.
  - blind: `[low]` `[patch]` `openViews` notifies mid-frame, undocumented — documented on `openViews`.
  - blind: `[low]` `[reject]` the static per-view counter is fragile on reparenting — no sheet moves between windows; a fix adds branches for an unshown case.
  - blind: `[low]` `[reject]` Help › jj Documentation ignores `open`'s exit code — `/usr/bin/open` on a URL does not fail in practice; logging adds code for no seen case.
  - blind: `[low]` `[defer]` the documentation URL's version is separate from the pin — mirrored (agent-context edit to the pin-bump checklist).
  - blind: `[maybe-false]` `[reject]` callbacks capture build-time state — rebuilds land a microtask later and the runner rechecks busy/stale itself (`_execute` → `_disabled`); a stale target would need a click inside that microtask.
  - blind: `[false]` `[reject]` the xib edit is half-done — the remaining items are the sources the engine copies the system items from by selector; the Edit stock items show only before the first `Menu.setMenus`.
  - blind: `[maybe-false]` `[reject]` View test uses a real-time wait — the test passed in every run; a flake would show in the gate.
  - blind: `[low]` `[patch]` `AppMenuBar` switch untested — same test as above.
  - edge: `[medium]` `[patch]` Go › Parent/Child can select a collapsed stack's synthetic key — a stack node now counts as none.
  - edge: `[false]` `[reject]` `actionTarget` absent from the layout — `GraphViewModel.selected` is null when a landed layout lacks it (`graph_view_model.dart:246`).
  - edge: `[false]` `[reject]` ⌘⌫ in the search field — as above, Flutter handles it first.
  - edge: `[low]` `[patch]` `_intent` on any focus — fixed as above.
  - edge: `[low]` `[patch]` Find behind a Projects sheet — fixed as above.
  - edge: `[maybe-false]` `[reject]` sheet reparenting — as above.
  - edge: `[medium]` `[defer]` graph never bound — as the blind finding.
  - edge: `[false]` `[reject]` `attach` signature differs from the spec's task line — Projects is reached through `projectsKey`; the fix would edit this spec.
  - intent: `[maybe-false]` `[reject]` I3 covers menu items, not in-window Dart shortcuts — no window-level `Shortcuts` sits above a sheet in `app/lib` today (sheet keys stay in its `FocusScope`); the graph's own ones are not mounted until 10.12.

## Design Notes

The menu model is pure Dart over listenables, so tests read `menus(strings)` and call `onSelected` without a platform channel. `PlatformMenuBar` replaces `NSApp.mainMenu`; the provided items are copied from the xib by selector, so their titles stay the xib's English ones (I6: settled for English-only). Toggles (Detailed Cards, Group Stacks, Show Minimap) carry no checkmark: `PlatformMenuItem` has no state, and `PlatformProvidedMenuItem.enabled` is ignored natively — both recorded as deferred.

## Verification

**Commands:**
- `flutter test` in `app/` and `packages/zanshin_ui/` -- all pass
- `dart analyze --fatal-infos --fatal-warnings` in `app/` and `packages/zanshin_ui/` -- clean
- `dart format --set-exit-if-changed` on the touched packages -- clean
- `flutter build macos --debug` in `app/` -- builds (the xib edit and the Dart menu compile)

**Manual checks (if no CLI):**
- The running app's menu bar: not reachable by Marionette (native); noted under verification notes.

## Auto Run Result

Status: done. Code commit `0d7811d4635d3df022447839322ccfbc82b8551d`.

**Summary.** The menu bar is built in Dart (`PlatformMenuBar` above the `WindowManager`, labels from `app_en.arb`, system items as `PlatformProvidedMenuItem`s copied from the xib) over `AppMenuModel`, which follows the key window, the session, the sheets (`ZsSheet.openViews`), the focused text field and a graph slot (`GraphMenuBinding`) the project window fills once 10.12 mounts the graph.

**Files.**
- `app/lib/src/features/shell/app_menu.dart` (new) — `GraphMenuBinding`, `AppMenuModel` (menus, routing, greying), `AppMenuBar`.
- `app/lib/main.dart`, `app/lib/main.inject.dart` — `MainComponent.appMenu`, attached after the coordinator; Projects keyed by `appMenu.projectsKey`.
- `app/lib/src/features/bootstrap/boot_window_host.dart` — `AppMenuBar` wraps the `WindowManager` from the first frame.
- `app/lib/src/features/window/app_windows.dart` — `requestClose`, `viewIdOf`, `keyOfView`.
- `app/lib/src/features/window/active_window_tracker.dart` — public `keyView`.
- `app/lib/src/features/home/home_page.dart` — `openRecentProject` shared with File › Open Recent.
- `app/lib/src/features/projects/projects_window.dart` — `focusSearch()` for ⌘F.
- `packages/zanshin_ui/lib/src/materials/zs_sheet.dart` — `ZsSheet.openViews`.
- `app/lib/l10n/app_en.arb` + generated — the `menu*` strings.
- `app/macos/Runner/Base.lproj/MainMenu.xib` — Preferences… and the Find submenu removed.
- Tests: `app_menu_test.dart` (new, 12 cases), `app_windows_test.dart`, `active_window_tracker_test.dart`, `zanshin_app_test.dart`, `projects_window_test.dart`, `boot_window_host_test.dart`, `zs_sheet_test.dart`.

**Deferred-work items (I1–I6).**
- I1 — partly done (`0d7811d4`): View › Reload ⌘R runs `ProjectSession.refresh()` and a bound graph's `reload()`; the graph half is live once 10.12 publishes its graph (deferred above; the in-window button is 10.12's).
- I2 — fixed (`0d7811d4`): Reload ⌘R runs `ProjectSession.refresh()`, the window-focus trigger's call, so the dot refreshes on demand.
- I3 — fixed (`0d7811d4`): `ZsSheet.openViews` is the modal flag; while a sheet shows in the project window every item acting on it (Close Window there, Open Recent, Reload, Find, Undo/Redo, View-graph, Change, Go) is grey, and Close Window and Find are grey behind a sheet in the key window. Key equivalents of a grey item do nothing; no window-level Dart shortcut sits above a sheet today.
- I4 — fixed (`0d7811d4`): ⇧⌘O (File › All Projects…, and Window › Projects) opens or brings forward Projects; Settings… ⌘, and Project Settings… are disabled items until 11.7 passes their action.
- I5 — fixed (`0d7811d4`): Close Window ⌘W runs the key window's red-button path (`AppWindows.requestClose`): on the project window the close guards, then `closeProject()` and Projects; 10.22 still registers its "Discard changes?" guard.
- I6 — fixed (`0d7811d4`): every Dart menu label is an ARB string; the system items keep the xib's English titles, and no `CFBundleLocalizations` is added while the app is English only (the item's own rule).

**Review.** One pass, 30 findings (medium 4, low 15, false 6, maybe-false 5): 8 patch groups applied (text items need a focused field, stack nodes are no Go target, Find behind a Projects sheet, `focusSearch` a `VoidCallback`, `openViews` doc, tests for text-first Undo, `focusSearch()`, the `AppMenuBar` rebuild); 4 deferred (graph not yet published, no checkmarks / native greying, Window list, the docs URL vs the pin — all mirrored to deferred-work.md); the rest rejected with reasons in the triage log. Follow-up review recommended: false (patched: medium 2, low 6; no high).

**Verification notes** (gate rule of this run: no `cargo make test`).
- `flutter test` in `app/`: 1417 passed, 6 failed — all six in `worker_project_repos_test.dart` ("XDG_CONFIG_HOME is not pinned … run via cargo make"), the gate's environment, untouched by this change.
- `flutter test` in `packages/zanshin_ui/`: 438 passed.
- `dart analyze --fatal-infos --fatal-warnings` and `dart format --set-exit-if-changed` clean in both packages.
- `flutter build macos --debug`: built.
- Not checked: the running app's native menu bar (Marionette cannot reach it) — the key-equivalent precedence (text fields first) rests on the engine's `performKeyEquivalent` source, not on a run.

**Residual risks.** Until 10.12 binds the graph, Change, Go, graph View, Undo/Redo and the project window's Find are grey in the app; the menu bar itself is unseen in a running app.
