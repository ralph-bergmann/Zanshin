---
title: 'Story 11.24: Dart architecture, part 1 — dead DI out, every symbol in its layer, no import cycles between the app''s folders'
type: 'refactor'
created: '2026-11-07'
status: 'done'
baseline_revision: '85dfa1e796eba232a01f32c7bda57b256d66d9e8'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
warnings: ['multiple-goals', 'oversized']
deferred:
  - summary: >-
      The running-app witness (AC 5) was not run: the unattended run could not hold a running app for Marionette.
    evidence: |-
      The run allows foreground commands only, so `flutter run -d macos` cannot stay up beside a Marionette session; the app would also reopen the machine's last project and snapshot it. Covered instead by widget tests: menu Find through ProjectsSearchFocus (incl. the sheet), the Projects sidebar through an AppWindowActionsScope, ActiveGraph publish/clear, one ActiveGraph across HomePage/Settings/Configurations and one ProjectsSearchFocus across Projects contents in main.dart's DI graph. Unchecked by hand: a project opens and the View/Change items act on its graph, Edit › Find focuses the Projects search while Projects is key, Settings opens from the capsule and from the Projects window, jj log Configurations shows the graph's revsets, Help › jj Documentation opens the browser.
    location: >-
      app/lib/main.dart, app/lib/src/app/menu/app_menu.dart, app/lib/src/features/projects/projects_window.dart, app/lib/src/features/home/project_graph_host.dart
    severity: low
  - summary: >-
      A Recent project that is no longer a jj workspace opens nothing and says nothing (pre-existing).
    evidence: |-
      openRecentProject (moved unchanged from home_page.dart) reports only ProjectOpenFailed and a missing folder; ProjectNotARepo (a plain Git repository or folder) and ProjectInsideRepo from the capsule's Recent rows or File › Open Recent are dropped silently. Edge-case review, 2026-11-07.
    location: >-
      app/lib/src/features/projects/project_session.dart:614-624
    severity: low
    resolved: >-
      2026-11-07 — fixed (console session, commit 1e919409): openRecentProject reports ProjectNotARepo and
      ProjectInsideRepo too, so the Projects window shows its convert, init or enclosing offer; three new cases in
      home_page_test.
  - summary: >-
      The app's layer rule is written down only in its guard test, not in project-context.md or the README.
    evidence: |-
      app/test/architecture/layers_test.dart enforces "features never import lib/src/app/, feature folders import each other without a cycle"; _bmad-output/project-context.md names the other source guards but not this one, and README.md:24 says only "features under app/lib/src/features/". The fix edits an agent-context file. Blind review, 2026-11-07.
    location: >-
      _bmad-output/project-context.md, README.md:24
    severity: low
    resolved: >-
      2026-11-07 — fixed (console session, commit 1e919409): the rule is in project-context.md (File & module
      organization), and the README's app/ row names app/lib/src/app/.
---

<intent-contract>

## Intent

**Problem:** inject.dart is used half-way (a dead `@inject` on `GraphViewModel`, `ZanshinFfiModule` on no component), the graph's `SettingsStore` and the project window's graph travel by hand (`AppMenuModel.attach`, `FloatingShellViewModel.settings`, the menu as their holder), and `app/lib/src/features/` mixes the app's frame (boot, window coordinator, menu bar) into the features, with import cycles between its folders.

**Approach:** Remove the dead DI; inject the store and two new singletons, `ActiveGraph` (graph/) and `ProjectsSearchFocus` (projects/); move each misplaced symbol to the folder that owns it; move the frame to `app/lib/src/app/`; guard "features never import the frame, feature folders import each other without a cycle" with a test. No behaviour or visual change; the wiring itself stays for 11.25.

## Boundaries & Constraints

**Always:** Moves are `git mv` plus import edits; moved code keeps its text except paths, imports, the parameters epics.md 11.24 names and what the folder rule forces (Design Notes). Tests follow their code (`app/test/app/…`). inject.dart output only through `dart run build_runner build --delete-conflicting-outputs` in `app/`, never hand-edited. Relative imports inside `app/lib`; SPDX line first in new files; doc comments on new public items; new logic gets tests.

**Never:** No wiring change beyond the named parameters — `appWindowCoordinator`, the worker `Completer`, `ProjectSession.mayLeave`, `MainComponent`'s getters, `AppMenuModel.openUrl`, `IconModule`, `SettingsModule` stay (11.25). No behaviour, string, l10n or visual change in the app (the stale `v0.46.0` docs URL stays; deferred-work tracks it). No `graph/` package, no `zanshin_ui`/`zanshin_settings` decoupling. No full gate (`cargo make test`/`test-full`/`coverage`) in this run. Never run jj in this repo.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Find in Projects | Projects key, its window mounted, Edit › Find | `ProjectsSearchFocus.focus` runs: search focused, text selected | grey while a sheet shows in Projects |
| Find, no Projects content | Projects key, nothing registered | graph search as today (activates the project window) | grey without a bound graph |
| Projects window goes | its state disposes | its registration goes; another window's registration stays | — |
| Projects sidebar | no `AppWindowActionsScope` (test, catalogue without one) | Settings… disabled, no "Set identity…" | — |
| Projects sidebar | inside the coordinator's scope | Settings… → `openSettings()`; Set identity… → `openSettings(target: SettingsTarget.general)` | — |
| Project switch / close | `ProjectGraphHost` | `ActiveGraph.value` = the new binding / null; only its own binding is cleared | — |
| Guard | a feature file importing `lib/src/app/…`; two feature folders importing each other (or a longer cycle) | one violation each, naming files / folders | real `lib/src` tree: none |

</intent-contract>

## Code Map

- `packages/zanshin_core/lib/src/ffi/zanshin_version.dart` -- `ZanshinFfiModule` + typedef `ZanshinFfiVersion`; export at `lib/zanshin_core.dart:126`; comment `lib/src/ffi/diagnostics.dart:43`; callers `test/ffi/zanshin_version_test.dart:21-26`, `app/test/native_asset_smoke_test.dart:12`.
- `app/lib/main.dart:19-38,130-204` -- imports, `_startApp` (`attach(windows, coordinator, settings)` :150), `appWindowCoordinator` (`late` self-reference :165, `onSettings`/`onIdentitySettings`/`key: projectsKey` :176-178, `component.appMenu.graph` :185,199).
- `app/lib/src/features/shell/app_menu.dart` -- `jjDocumentationUrl` :42, `_openInBrowser` :44, `GraphMenuBinding` :52-81 (field `SyncModel? sync`), ctor :105, `projectsKey` :119, `graph` :122, `openUrl` :127, `attach` :134, `_zoomTo` :145, `targetName` :217 (uses `dart:math`), Find :362-372, Fetch/Push :589-603, `openRecent` :710, dispose :716-729 (disposes `graph`).
- `app/lib/src/features/home/home_page.dart:54-62,91-101,135-164,249-254` -- `HomePage` ctor (`appMenu`), `vm.settings` to `ProjectGraphHost` / `_UndoTimelineHost`, `openRecentProject`, `UndoTimelineActions` field.
- `app/lib/src/features/home/project_graph_host.dart:87-109,183,190,272,285` -- `appMenu` param, `AppMenuModel.targetName`, `GraphMenuBinding`, publish/clear.
- `app/lib/src/features/shell/floating_shell_view_model.dart:40-41` -- `settings` getter (goes).
- `app/lib/src/features/graph/graph_view_model.dart:6,10,187-188` -- inject import, `UndoTimelineActions` import, `@inject`.
- `app/lib/src/features/undo_timeline/undo_timeline_model.dart:38-58` -- `UndoTimelineActions`; users `undo_timeline_view.dart`, `home_page.dart`, `test/helpers/fake_undo_timeline.dart:255`, `test/features/undo_timeline/undo_timeline_view_test.dart`, `widgetbook/folders/undo_timeline.dart:327`.
- `app/lib/src/features/settings/immutable_heads.dart:27-36,115-152` -- `builtinImmutableHeads`, `immutableBuiltins`, `splitRevsetUnion`; users `graph/immutable_reasons.dart:6,54-57`, `immutable_page.dart`, `project_tab.dart`, `settings_view_model.dart:525,705`; test group `test/features/settings/immutable_heads_test.dart:10-20`.
- `app/lib/src/features/projects/projects_window.dart:74-101,155-260,832,841` -- ctor, `ProjectsWindowState` (`_searchFocus`, `focusSearch`), sidebar Settings…, `_IdentityFooter`; factory part `projects_window.factory.dart`.
- `app/lib/src/features/settings/settings_window.dart:26,88`, `settings_view_model.dart:16,332,777`, `graph/revset_configs/revset_configs_window.dart:15,36,67` -- read `ValueListenable<GraphMenuBinding?> graph` (type stays); `revsetReferenceUrl` from `jjDocumentationUrl`.
- `app/lib/src/features/sync/sync_model.dart:42,99-102,144,162,286` -- `SyncModel` and the five members the menu and Settings use.
- `app/lib/src/features/bootstrap/boot_window_host.dart:16-25` -- imports `../shell/app_menu.dart`, re-export of `mainWindowKey`, `mainWindowTitle`.
- `app/lib/src/features/window/app_window_coordinator.dart:16-23`, `app/lib/src/features/app/zanshin_app.dart:6-8`, `app/lib/src/features/window/zanshin_window_root.dart:9`, `app/lib/src/features/window/app_windows.dart:24-25` -- imports to move with the files; `mainWindowKey`.
- Tests that construct or import moved symbols: `app/test/features/{app,bootstrap}/*`, `features/window/{app_window_coordinator,zanshin_window_root}_test.dart`, `features/shell/app_menu_test.dart` (`AppMenuModel(tracker, session)..attach(windows, actions, store)..openUrl` :223-225), `features/home/{home_page,project_graph_host}_test.dart`, `features/projects/projects_window_test.dart` (`onSettings` :136-137, test :1998-2012, focus test :524-540, DI test :2094-2112), `features/graph/revset_configs/revset_configs_window_test.dart:15`, `helpers/settings_rig.dart:15`.
- Catalogue: `app/widgetbook/folders/windows.dart:22`, `widgetbook/folders/undo_timeline.dart:13`, `widgetbook/demo_projects_fakes.dart:358-364` (`onIdentitySettings: () {}`).
- Guard pattern to mirror: `app/test/l10n/hard_coded_strings_test.dart` (tested scanner function + `Directory('lib')` scan, run from `app/`).

## Tasks & Acceptance

**Execution:**
- `packages/zanshin_core/lib/src/ffi/zanshin_version.dart`, `lib/zanshin_core.dart`, `lib/src/ffi/diagnostics.dart`, `test/ffi/zanshin_version_test.dart`, `app/test/native_asset_smoke_test.dart` -- `String zanshinFfiVersion()` (decodes, then `zanshin_string_free`s the pointer), exported; the typedef and module go; callers follow -- item 1.
- `app/lib/src/features/graph/graph_view_model.dart` -- drop `@inject` and its import; receive `UndoTimelineActions` (from `undo_timeline_model.dart`) and the top-level `targetName(GraphViewModel model, String id)` (from `AppMenuModel`) -- items 1, 3, 6.
- `app/lib/src/features/graph/active_graph.dart` (new) -- `GraphMenuBinding` (moved), `GraphMenuSync` (interface), `@inject @singleton ActiveGraph extends ValueNotifier<GraphMenuBinding?>` -- item 3.
- `app/lib/src/features/sync/sync_model.dart` -- `implements GraphMenuSync` with `@override` on its five members -- item 3.
- `app/lib/src/features/graph/immutable_reasons.dart`, `features/settings/{immutable_heads,immutable_page,project_tab,settings_view_model}.dart` -- the three revset facts move to `immutable_reasons.dart`; settings imports them from there -- item 6.
- `app/lib/src/links.dart` (new) -- `jjDocumentationUrl` and `openInBrowser` (was `_openInBrowser`) -- item 6.
- `app/lib/src/features/projects/projects_search_focus.dart` (new), `projects_window.dart` -- `@inject @singleton ProjectsSearchFocus`; the window takes it (injected), registers `focusSearch` while mounted; Settings… / Set identity… through `AppWindowActionsScope`; `onSettings` / `onIdentitySettings` go -- items 4, 5.
- `app/lib/src/features/projects/project_session.dart` -- receives `openRecentProject` -- item 6.
- `app/lib/src/features/window/app_windows.dart`, `zanshin_app_view_model.dart` (moved from `features/app/`), `zanshin_window_root.dart` -- `mainWindowTitle` beside `mainWindowKey`; view model next to its root -- item 6.
- `app/lib/src/features/home/{home_page,project_graph_host}.dart`, `features/shell/floating_shell_view_model.dart`, `features/settings/{settings_window,settings_view_model}.dart`, `features/graph/revset_configs/revset_configs_window.dart`, `features/undo_timeline/{undo_timeline_model,undo_timeline_view}.dart` -- `HomePage` takes `SettingsStore settings` and `ActiveGraph activeGraph` (injected) instead of `appMenu`; `ProjectGraphHost` takes `activeGraph`, both hosts the page's `settings`; the `settings` getter goes; imports follow -- items 2, 3, 6.
- `git mv` `features/bootstrap/*` → `app/lib/src/app/boot/`, `features/window/app_window_coordinator.dart` → `app/lib/src/app/`, `features/app/zanshin_app.dart` (+ `.factory.dart`) → `app/lib/src/app/`, `features/shell/app_menu.dart` → `app/lib/src/app/menu/`; fix their imports; drop the boot host's `mainWindowKey` re-export -- item 7.
- `app/lib/src/app/menu/app_menu.dart` -- ctor `AppMenuModel(tracker, session, settings, graph, projectsSearch)` listening to the settings from the start; public `final ActiveGraph graph` (read, not owned: dispose only unlistens); `attach(AppWindows, AppWindowActions)`; Find via `ProjectsSearchFocus`; Fetch/Push via `GraphMenuSync`; `openUrl` defaults to `openInBrowser` -- items 2, 3, 4.
- `app/lib/main.dart`, `app/lib/main.inject.dart` + `*.factory.dart` -- imports, two-argument `attach`, `appWindowCoordinator` without the self-reference and the removed arguments (graph still `component.appMenu.graph`); regenerate -- items 2, 4, 5.
- Tests: `git mv` `test/features/app/zanshin_app_test.dart` → `test/app/`, `test/features/app/zanshin_app_view_model_test.dart` → `test/features/window/`, `test/features/bootstrap/*` → `test/app/boot/`, `test/features/window/app_window_coordinator_test.dart` → `test/app/`, `test/features/shell/app_menu_test.dart` → `test/app/menu/`; adapt imports, constructors and the I/O-matrix cases (menu Find via `ProjectsSearchFocus` incl. the sheet; window registers/unregisters; sidebar through a `FakeWindowActions` scope; `ActiveGraph` publish/clear; `splitRevsetUnion` group → `test/features/graph/immutable_reasons_test.dart`); `zanshin_app_test` asserts one `ActiveGraph` across HomePage, Settings and Configurations and one `ProjectsSearchFocus` across Projects contents.
- `app/test/architecture/layers_test.dart` (new) -- tested `layerViolations` + a scan of `lib/src` -- item 8.
- `app/widgetbook/{folders/windows.dart,folders/undo_timeline.dart,demo_projects_fakes.dart}` -- imports; the demo Projects content gets a `ProjectsSearchFocus` and a no-op `AppWindowActionsScope` instead of `onIdentitySettings` -- items 3, 5, 6.

**Acceptance Criteria:**
- Given the moved tree, when `layers_test.dart` runs, then the real `lib/src` passes, and its rule reports a planted feature → `lib/src/app/` import and a planted two-folder cycle.
- Given `app/lib` and `packages/zanshin_core/lib`, when grepped, then no `@inject` precedes `GraphViewModel`, and `ZanshinFfiModule`, `projectsKey`, `FloatingShellViewModel.settings`, `features/bootstrap`, `features/app/` and `features/shell/app_menu` occur nowhere outside `_bmad-output`/`docs/superpowers`; `HomePage` has no `appMenu` parameter; `AppMenuModel.attach` takes two parameters.
- Given the generated `main.inject.dart`, when read, then `ActiveGraph` and `ProjectsSearchFocus` are singletons shared by `AppMenuModel`, the HomePage factory and the Projects factory.
- Given `dart run build_runner build`, `dart analyze --fatal-infos --fatal-warnings`, `dart format --set-exit-if-changed` and the app's and `zanshin_core`'s affected tests, when run, then all pass with no diff in generated code.
- Given the running app (Marionette), when a project opens, then View and Change items act on its graph, Edit › Find focuses the Projects search while Projects is key, Settings opens from the capsule and from the Projects window, jj log Configurations shows the graph's revsets and Help › jj Documentation opens the browser — exactly as before the change.

## Spec Change Log

## Review Triage Log

### 2026-11-07 — Review pass
- verdicts: 31 findings — high 0, medium 0, low 19, false 12, maybe-false 0
- findings:
  - `[low]` `[patch]` (blind) `AppMenuModel` never binds a graph already published in the injected `ActiveGraph` (`_bound` stays null until the next change) — the constructor now runs `_graphChanged()` once; test "a menu made over an already published graph listens to it at once" (fails without the line, checked).
  - `[false]` `[reject]` (blind) the DI tests no longer check that the menu's Find reaches the Projects contents — within one component the menu and the contents can only diverge by losing `ProjectsSearchFocus`'s `@singleton`, which the sharing assertions in `zanshin_app_test` and the `projects_window_test` DI test catch; Find's use of it is pinned in `app_menu_test`.
  - `[low]` `[reject]` (blind) "dispose only stops listening" passes even if `dispose` keeps the graph listener — the menu is an app-lifetime singleton never disposed in the app, and pinning the `removeListener` needs a listener-counting double, more than a direct correction.
  - `[low]` `[patch]` (blind) the guard skips a file directly in `lib/src/features/`, so its frame import passes — the frame check now covers every file under `features/`; planted `lib/src/features/loose.dart` case added.
  - `[low]` `[reject]` (blind) the guard sees direct imports only; `main.dart`, `links.dart` or `l10n/` could relay a frame import or a cycle — today none of them imports a feature or the frame, and closing it needs transitive reachability over every `lib` file, more than a direct correction.
  - `[low]` `[defer]` (blind) the layer rule is written down only in the guard test (project-context.md, README.md:24) — the fix edits an agent-context file; deferred and mirrored to deferred-work.md.
  - `[low]` `[patch]` (blind) the new `didUpdateWidget` branch moving the `searchFocus` registration has no test — test "a rebuild over another search focus moves the registration there" added.
  - `[low]` `[reject]` (blind) `ProjectsSearchFocus` is a stack, not the spec sketch's single slot, untested for A/B/unregister-B order and not `Listenable` — the fix would edit this build's spec; the matrix row (its registration goes, another stays) is tested, and the key-window change refreshes Find as the old `GlobalKey` did.
  - `[false]` `[reject]` (blind) `tomlStringValue` / `effectiveConfigEntry` left in `settings/` make sync → settings a trap — no cycle exists (sync → settings only), and a future cycle is exactly what the guard reports; the story's FINAL symbol list does not name them.
  - `[low]` `[patch]` (blind) deferred-work.md:2453 places `jjDocumentationUrl` in the old `app_menu.dart`; the AC-5 deferral had no ledger entry yet — dated note added to that entry (now `lib/src/links.dart`, still `v0.46.0`); the deferrals are mirrored with this spec's commit.
  - `[low]` `[patch]` (blind) `AppWindowActionsScope`'s doc says catalogue previews have no actions, but the demo Projects content now sits in a no-op scope — reworded to "a test, most catalogue previews".
  - `[low]` `[reject]` (blind) `ProjectGraphHost.didUpdateWidget` ignores a replaced `activeGraph` — the injected singleton never changes, and the old `appMenu` parameter was not handled either; the fix adds a branch for a state the app cannot reach.
  - `[low]` `[patch]` (edge) menu constructed while `ActiveGraph` already holds a binding — same entry as the first row.
  - `[low]` `[reject]` (edge) `didUpdateWidget` with a different `ActiveGraph` — same entry as the `ProjectGraphHost` row above.
  - `[low]` `[defer]` (edge) `openRecentProject` drops `ProjectNotARepo` (git/neither) and `ProjectInsideRepo` silently — pre-existing (moved verbatim from `home_page.dart`); deferred and mirrored.
  - `[low]` `[patch]` (edge) a file directly under `lib/src/features/` importing the frame passes — same entry as the guard row above.
  - `[low]` `[reject]` (edge) a frame import or a cycle relayed through a non-feature `lib/src` file escapes — same entry as the direct-imports row above.
  - `[low]` `[reject]` (edge) conditional imports (`if (dart.library.io) 'b.dart'`) are not read — `app/lib/src` has none, and parsing them adds a branch for an unused form.
  - `[false]` `[reject]` (edge) run outside `app/`, `listSync` throws before the "run from app/" reason — it still fails loudly naming `lib/src`, as `hard_coded_strings_test` does; `flutter test` runs from the package root.
  - `[false]` `[reject]` (edge) the catalogue's demo Settings… row turns enabled — the spec asks for the scope; the app always provides one, so the catalogue now matches the running app, and the app itself is unchanged.
  - `[low]` `[patch]` (verification-gap, other) menu built over an already published graph — same entry as the first row.
  - `[false]` `[reject]` (intent) `AppMenuModel.graph` stays public and `main.dart` reads `component.appMenu.graph` — the non-goal keeps the component's getters until 11.25 (Design Notes); ownership left the menu (it never disposes the graph), and one `ActiveGraph` across HomePage, Settings and Configurations is asserted.
  - `[false]` `[reject]` (intent) `GraphMenuSync`, the downcasts and the `splitRevsetUnion` move go beyond "paths, imports and named parameters" — items 3 and 8 together force them (`sync/` imports `graph/`; `immutable_reasons.dart` imported `splitRevsetUnion` from `settings/`), recorded in Design Notes; the least rewrite that satisfies both.
  - `[false]` `[reject]` (intent) `zanshinFfiVersion()` now frees the Rust string — Rust's contract requires it (`crates/zanshin-ffi/src/lib.rs:83`); the old tear-off leaked one string per call; nothing visible changes.
  - `[false]` `[reject]` (intent) the guard's nodes are first-level feature folders only (`graph` ↔ `graph/revset_configs` unseen) — item 8 defines the rule per feature folder; a sub-folder belongs to its feature.
  - `[false]` `[reject]` (intent) the planted violations are synthetic import maps, not files — they feed the same `layerViolations` the scan calls; the implementer also planted two real files and saw both reported before reverting.
  - `[low]` `[defer]` (intent) the running-app witness (AC 5) was not exercised — already in `deferred:` from implementation; mirrored to deferred-work.md.
  - `[false]` `[reject]` (intent) `cargo make test` (witness 3) did not run — this run's gate rule moves the gate to the story loop's end; targeted checks ran (Verification below).
  - `[false]` `[reject]` (intent) the catalogue's demo Settings… row is enabled — same as the edge row above.
  - `[false]` `[reject]` (intent) the ledger mirror and the verification outcomes were not yet written — both land with this spec's commit (Auto Run Result, deferred-work.md).
  - `[low]` `[reject]` (intent) `ProjectsSearchFocus` is a stack, not the sketched slot — same entry as the blind row above.

## Design Notes

**Forced by the folder rule (Claude's proposals, beyond the story's list):** `GraphMenuBinding.sync` is a `SyncModel`, and `sync/` imports `graph/`; so the binding in `graph/` names `GraphMenuSync` (`canFetch`, `canPush`, `fetch()`, `openPush()`, `reloadRemotes()`, a `Listenable`), which `SyncModel` implements. `splitRevsetUnion` moves with the two built-in facts — `immutable_reasons.dart`'s third import from `settings/`.

**Placements:** `UndoTimelineActions` and `targetName` in `graph_view_model.dart`, the revset facts in `immutable_reasons.dart`, `openRecentProject` in `project_session.dart`. `AppMenuModel.graph` stays public (the injected `ActiveGraph`): `appWindowCoordinator` keeps reading `component.appMenu.graph`, since the component's getters stay until 11.25.

```dart
@inject
@singleton
class ProjectsSearchFocus {
  VoidCallback? _focus;
  VoidCallback? get focus => _focus;            // null while no Projects content is mounted
  void register(VoidCallback focus) => _focus = focus;
  void unregister(VoidCallback focus) { if (_focus == focus) _focus = null; }
}
```

**Guard:** a file's feature is the first segment under `lib/src/features/`; `package:zanshin/…` and relative URIs resolve to `lib/…`; any cycle between feature folders (Tarjan-free: mutual reachability) is one violation listing its folders and an importing file per edge — this covers "no two feature folders import each other" directly and through others.

## Verification

**Commands:**
- `dart run build_runner build --delete-conflicting-outputs` (in `app/`) -- expected: generated files committed, a rerun changes nothing.
- `cargo make test-app` (whole app suite, gate env) -- expected: all pass.
- `cargo make --allow-private test-dart-analyze` / `test-dart-format`, and `test-core-analyze` / `test-core-format` -- expected: clean.
- `cargo make --allow-private test-core test/ffi/zanshin_version_test.dart` -- expected: pass.
- `rg` for the removed symbols and old paths (AC 2) -- expected: none.

**Manual checks (if no CLI):**
- The running-app AC through Marionette (`flutter run -d macos` from `app/`, connect to its VM service); if the unattended run cannot hold a running app, record it as deferred for Ralph.

**Outcomes (2026-11-07):** every check this run ran and its result is listed under Auto Run Result › Verification.

## Auto Run Result

Status: done

**Summary:** the dead DI is gone (`@inject` off `GraphViewModel`; `ZanshinFfiModule` → exported `String zanshinFfiVersion()`, which now also frees the Rust string); the graph's `SettingsStore` reaches `HomePage` and `AppMenuModel` by constructor (`FloatingShellViewModel.settings` gone, `attach(windows, actions)`); the project window's graph is the `@inject @singleton ActiveGraph` in `features/graph/` (with `GraphMenuBinding` and the forced `GraphMenuSync`, which `SyncModel` implements); Edit › Find reaches the Projects search through the `@singleton ProjectsSearchFocus`; the Projects sidebar opens Settings through `AppWindowActionsScope` (callbacks and `main.dart`'s `late` self-reference gone); `mainWindowTitle`, `openRecentProject`, `ZanshinAppViewModel`, `UndoTimelineActions`, `targetName`, the built-in revset facts (+ `splitRevsetUnion`), `jjDocumentationUrl` and the opener sit in their layers; the frame lives in `app/lib/src/app/` (`boot/`, `menu/`, the coordinator, `zanshin_app.dart`), tests follow; `app/test/architecture/layers_test.dart` guards the rule (features never import `lib/src/app/`; no cycle between feature folders). No app behaviour or visual change; the wiring stays for 11.25.

**Files changed:**
- `packages/zanshin_core/lib/src/ffi/zanshin_version.dart`, `lib/zanshin_core.dart`, `lib/src/ffi/diagnostics.dart`, `test/ffi/zanshin_version_test.dart` — `zanshinFfiVersion()`, its export, a comment, the coverage-bearing test calling it.
- `app/lib/main.dart`; `app/lib/main.inject.dart`, `app/lib/src/features/projects/projects_window.factory.dart` (regenerated) — imports, two-argument `attach`, the coordinator without the removed arguments.
- New: `app/lib/src/links.dart`, `app/lib/src/features/graph/active_graph.dart`, `app/lib/src/features/projects/projects_search_focus.dart`, `app/test/architecture/layers_test.dart`.
- Moved (`git mv`): `features/bootstrap/*` → `app/lib/src/app/boot/`; `features/window/app_window_coordinator.dart`, `features/app/zanshin_app.dart` (+ factory) → `app/lib/src/app/`; `features/shell/app_menu.dart` → `app/lib/src/app/menu/` (constructor injection, Find via `ProjectsSearchFocus`, binds an already published graph); `features/app/zanshin_app_view_model.dart` → `features/window/`; tests to `app/test/app/{,boot/,menu/}` and `app/test/features/window/`.
- Edited: `features/graph/{graph_view_model,immutable_reasons,revset_configs/revset_configs_window}.dart`, `features/home/{home_page,project_graph_host}.dart`, `features/projects/{project_session,projects_window}.dart`, `features/settings/{immutable_heads,immutable_page,project_tab,settings_view_model,settings_window}.dart`, `features/shell/floating_shell_view_model.dart`, `features/sync/sync_model.dart`, `features/undo_timeline/{undo_timeline_model,undo_timeline_view}.dart`, `features/window/{app_windows,app_window_actions,zanshin_window_root}.dart`.
- Tests: `home_page_test`, `project_graph_host_test` (+ host clears only its own binding), `projects_window_test` (+ registration, move on rebuild, sidebar through a `FakeWindowActions` scope), `app_menu_test` (+ Projects Find, published-graph menu, `ActiveGraph` outlives the menu), `zanshin_app_test` (one `ActiveGraph`, one `ProjectsSearchFocus`), `immutable_reasons_test` (+ `splitRevsetUnion`), `immutable_heads_test`, `revset_configs_window_test`, `undo_timeline_view_test`, `zanshin_window_root_test`, `helpers/{fake_undo_timeline,settings_rig}.dart`, `native_asset_smoke_test`.
- Catalogue: `app/widgetbook/demo_projects_fakes.dart` (a `ProjectsSearchFocus` and a no-op `AppWindowActionsScope`: Settings… now shows enabled, as in the app), `folders/{windows,undo_timeline}.dart` (imports).
- `_bmad-output/implementation-artifacts/epic-11-context.md` (regenerated: epics.md was newer), `deferred-work.md` (Story 11.24 section; the docs-URL entry's new location).

**Review:** 31 findings — 0 high, 0 medium, 19 low, 12 false. Patched 5 low entries: the menu binds an already published graph (3 reports), the guard also covers files directly in `features/` (2), a test for the moved registration on rebuild, the scope's doc wording, the ledger's docs-URL location. Deferred 3 (mirrored to deferred-work.md): the running-app witness, `openRecentProject` swallowing a Recent project that is no longer a jj workspace (pre-existing), the layer rule not in project-context.md/README (agent-context edit). Rejected: the rest, each with its reason in the Review Triage Log (unreachable single-instance swaps, transitive/conditional-import guard extensions, the spec-sketch drift, design decisions the story forces or the run's rules settle).

**Follow-up review recommended:** false — only low entries were patched (5 low, 0 medium, 0 high).

**Verification (targeted, per the loop's gate rule — no `cargo make test`/`test-full`/`coverage`):**
- `cargo make --allow-private test-dart-analyze` (app): no issues — after implementation and again after the review patches.
- `cargo make --allow-private test-dart-format` (app): 277 files, 0 changed — both times.
- `cargo make --allow-private test-core-analyze` / `test-core-format` (zanshin_core): no issues / 167 files, 0 changed.
- `dart run build_runner build --delete-conflicting-outputs` (app), rerun twice: generated files unchanged (`IconModule`'s unused-binding warning is pre-existing; 11.25 gives it a consumer).
- `dart test test/ffi/zanshin_version_test.dart` (zanshin_core, real cdylib): 2 passed.
- `cargo make test-app` over every app test folder in two batches: 812 + 1374 = 2186 passed; after the review patches 814 + 1400 passed, `app_menu_test`'s 26 counted in both batches: 2188 tests, 2 of them new. The new menu test fails with the constructor line removed (checked, then restored).
- `rg` for `ZanshinFfiModule`, `projectsKey`, `features/bootstrap`, `features/app/`, `shell/app_menu`, `vm.settings`, `appMenu:` outside `_bmad-output` / `docs/superpowers`: none. The feature folders' import graph is acyclic (shell and window import no feature).
- Not run: the full gate (the story loop runs it), the parity oracle and Rust checks (no Rust changed), the running app through Marionette (deferred).

**Residual risks:** the coverage ratchet has not run (no Rust changed; `zanshin_ffi_version` keeps its zanshin_core test); the native menu bar, the real windows and the browser opener were not exercised in the running app; `ProjectsSearchFocus` is a stack (the spec sketched one slot) — same behaviour for the one Projects window the app has.
