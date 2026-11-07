---
title: 'Story 11.25: Dart architecture, part 2 — one composition root: the DI graph wires the app, the boot runs top to bottom'
type: 'refactor'
created: '2026-11-07'
status: 'done'
baseline_revision: '671eea2fec7246f5e5cd6cd72eb1babf9828659c'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
warnings: ['multiple-goals', 'oversized']
deferred:
  - summary: >-
      The running-app witness (Marionette) was not run: the unattended run could not hold a running app safely.
    evidence: |-
      The run allows foreground commands only, so `flutter run -d macos` cannot stay up beside a Marionette session, and the app would reopen this machine's last project (a jj snapshot of a real repository). Widget tests cover the wiring through the test component: the four window contents over one session, store and graph; ⌘Q through the close guards; the stored zoom; the theme mirror. Unchecked by hand: start + reopen, "Discard changes?" on a switch and on ⌘Q, a theme switch restyling every window's chrome (the mirror now runs once at start(), then per theme change), a window opened while Zanshin is in the background taking the persisted theme's chrome (the plugin applies it when the window becomes key; review 2026-11-07), View › Zoom In growing the window minimums.
    location: >-
      app/lib/main.dart, app/lib/src/app/zanshin_application.dart, app/lib/src/features/window/window_appearance_sync.dart
    severity: low
  - summary: >-
      jj log Configurations takes its browser opener as an assisted argument, not injected.
    evidence: |-
      inject_generator 1.2.1 synthesizes a provider for a typedef'd function type that an assisted factory's class injects (the ViewModelFactory pattern); for `OpenUrl` it built a `Future(computation)` provider that clashed with AppModule's `OpenUrl` binding ("Duplicate binding" + "Function type is not supported"). So `RevsetConfigsWindow.openUrl` is `@assisted required` and `AppModule.coordinator` passes the graph's `OpenUrl`; non-null, one binding.
    location: >-
      app/lib/src/features/graph/revset_configs/revset_configs_window.dart:63-65, app/lib/src/app/app_module.dart:37-48
    severity: low
  - summary: >-
      A boot that fails in ZanshinApplication.start() shows the failure page under the app's full menus, whose window items then wait forever (pre-existing).
    evidence: |-
      main.dart hands the menu to the host before `app.start()`, as `_startApp` set `menu.value` before `coordinator.start()` at the baseline. Settings…, Projects… and Edit Configurations… await `AppWindowCoordinator._ready`, which only the first window's `onShown` completes, so on the failure page they do nothing. Edge-case review, 2026-11-07.
    location: >-
      app/lib/main.dart:82-83, app/lib/src/app/app_window_coordinator.dart:123,129,142
    severity: low
---

<intent-contract>

## Intent

**Problem:** `MainComponent` works as a service locator: eight getters feed hand wiring in `main.dart` (`_startApp`, `appWindowCoordinator`). Values that exist before the graph take detours: the worker goes through an `@asynchronous` provider, a `Completer` and a `Future<ZanshinWorker>` in two classes, and `AppWindows` is outside the graph. Objects are wired after construction (`ProjectSession.mayLeave =`, `AppMenuModel.attach`, the mutable `openUrl`). A second, hand-built `ZanshinAppViewModel` mirrors the theme. The quit hides in a provision listener. The boot passes 14 functions through five files. Tests re-implement generated factories.

**Approach:** One `loadBootValues` loads the pre-graph values: settings, login-shell environment and icons in parallel, then the worker. One `BootModule(boot, windows)` hands them to the graph (design question (a): the recommendation; Ralph gave no other answer). Modules and `@inject` classes wire everything by constructor:
- the coordinator in `AppModule`;
- the window contents by assisted injection;
- `WindowAppearanceSync`, `AppExitHandler` and `ZanshinApplication`.

`MainComponent` gets one getter. `ZanshinBootSequence.run` takes one boot function. Tests go through a test component. Nothing visible changes.

## Boundaries & Constraints

**Always:**
- Behaviour, strings, visuals and splash timings stay as they are:
  - the splash shows after 250 ms and stays at least 3 s;
  - the first window goes through `runWidget`;
  - the fade;
  - `onShown` runs after the first window;
  - the failure page shows the persisted theme;
  - the worker starts after the login-shell environment.
- inject.dart output comes only from `dart run build_runner build` in `app/`, never edited by hand. Commit the generated files.
- These stay unchanged:
  - `AppWindowCoordinator`'s constructor;
  - its 22 tests, except the one line in L375 that set `session.mayLeave` (it becomes a rig option);
  - `answerExitRequest` and its two tests.
- The sequence's 24 tests are adapted, not dropped. New logic gets tests.
- House rules: relative imports inside `app/lib`, the SPDX line first in new files, `///` docs on new public items. The layer guard `app/test/architecture/layers_test.dart` must hold.

**Never:**
- No project-scope object and no subcomponent. `GraphViewModel` and the per-repository wiring in the project hosts stay hand-built.
- No `@asynchronous` provider, no `Completer`, no `Future<ZanshinWorker>` passed through classes, and no wiring by setter or `attach()` after `create()`.
- No faster boot. No `graph/` package. No `zanshin_ui`/`zanshin_settings` decoupling. No renames beyond this spec.
- No full gate in this run: no `cargo make test`, `test-full` or `coverage`.
- Never run jj in a real repository. The running app would reopen the machine's last project.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Fast boot | boot function returns before 250 ms | the first window opens with no splash; `onShown` runs after it | — |
| Slow boot | boot outlasts 250 ms | splash for at least 3 s, then the first window, the fade, `onShown` | — |
| Late failure | the boot sets `persistedTheme = dark`, then throws | the failure page in the project window, dark | SEVERE logged |
| Early failure | the boot throws before any theme is set | the failure page follows the system | SEVERE logged |
| Shell slower than settings | `loadBootValues`: settings done while the shell read is pending | lines in order: Loading settings… → Reading the shell environment… → Starting Zanshin…; the worker starts last | — |
| Shell or icons fail | the shell adoption or `IconRegistry.load` throws | `loadBootValues` throws; the worker never starts; the theme was already reported | the boot's failure page |
| Theme row | Settings › Theme → light | the store is written; `setWindowAppearance:light` is sent once; every window root restyles | — |
| Other setting changes | zoom or density changes | no `setWindowAppearance` call | — |
| Switch blocked by a guard | a project is open, a close guard refuses, another project is opened | `ProjectSwitchCancelled`; the open project stays | — |
| ⌘Q | `handleRequestAppExit` after `start()` | the guards are asked once. Refused: cancel, worker untouched. Allowed: the worker closes once, then exit | — |

</intent-contract>

## Code Map

**Production code:**
- `app/lib/main.dart` — the parts that change:
  - the boot, :87-96 (`icons`/`menu` notifiers and four callbacks);
  - `_adoptShellEnvironment`, :108-117;
  - `_startApp`, :119-152 (`Completer` :135, `mayLeave =` :145, zoom :148, `attach` :149);
  - `appWindowCoordinator`, :154-197 (second `ZanshinAppViewModel` :165, hand-built window contents :174-195);
  - `MainComponent`, :199-244 (six modules, eight getters).
  - `main.inject.dart` is regenerated.
- `app/lib/src/app/boot/zanshin_bootstrap.dart`:
  - `BootFirstWindow` :40-55; its docs name `startApp`.
  - The constructor callbacks :104-132.
  - `_persistedMode` :150-152.
  - `run`/`_boot` :175-198.
  - `_load` :207-224: the status lines and the shell-pending rule move to `loadBootValues`.
- `app/lib/src/app/boot/boot_window_host.dart` — the constructor :32-44 takes `icons` and `menu`; the `runWidget` tree :129-147 builds the menu and `IconRegistryScope`.
- `app/lib/src/app/boot/icon_module.dart` — goes.
- `app/lib/src/app/worker_lifecycle_module.dart` — `answerExitRequest` :36-45 is kept verbatim; the module and `_WorkerLifecycleListener` go.
- `app/lib/src/app/app_window_coordinator.dart` — read-only. Constructor :55-64. `start()` returns `BootFirstWindow`; implements `AppWindowActions`.
- `app/lib/src/app/menu/app_menu.dart`:
  - the constructor :55-69;
  - the nullable `_windows`/`_actions` :79-80;
  - the `openUrl` field :86-88 and `attach` :93-98;
  - their null branches :133-141, 259-260, 313, 322, 331-347, 453, 589, 640-653;
  - Help › jj Documentation :606.
- `app/lib/src/features/projects/`:
  - `projects_module.dart` — constructor `worker` future; registry, session and environment providers.
  - `project_registry.dart:43-45` — `ProjectRegistry(this._store)`.
  - `project_session.dart` — doc ref :112, constructor :142-145, the public mutable `mayLeave` :162-170.
  - `worker_project_repos.dart:24-38,69-70` and `projects_environment.dart:116-119,147-190` — `Future<ZanshinWorker> _worker` and its `await` sites.
- `app/lib/src/features/window/`:
  - `zanshin_window_root.dart:36-61` — assisted constructor and build.
  - `zanshin_app_view_model.dart` — docs :15-17; `init()` mirrors :89-96; `setThemeMode` :98-108; `_onMacOS` :118; `_mirrorWindowAppearance` :130-141.
  - `window_zoom.dart:61` — `bindWindowZoom(store, windows)`.
  - `app_windows.dart:276-278` — `AppWindows.zoom`, plus `mayClose`.
- `app/lib/src/features/settings/`:
  - `settings_window.dart:56-109` — constructor; `setThemeMode` :63/:90-91; `windowKey` default :64; the raw function type `readsOf` :93-94; the view model :102-109.
  - `settings_view_model.dart:50,312-338` — `SettingsRepoReads`; the `setThemeMode` field :319/:336.
  - `general_tab.dart:92` — `vm.setThemeMode`; its signature is kept.
- `app/lib/src/features/graph/revset_configs/revset_configs_window.dart` — imports :15-17; constructor :53-84 (nullable `openUrl`, `windowKey` default); the disabled-link branch :1117-1130.
- `app/lib/src/features/graph/active_graph.dart:68-70` — `ActiveGraph extends ValueNotifier<GraphMenuBinding?>`.
- `app/lib/src/links.dart` — `openInBrowser`.
- `packages/zanshin_core/`:
  - `lib/src/worker/worker_module.dart` and its export at `lib/zanshin_core.dart:152` — go.
  - `lib/src/ffi/diagnostics.dart:37,47-54` — `GetDiagnostics` already binds a function typedef.
- `packages/zanshin_settings/` — `lib/src/settings_module.dart`, its export `lib/zanshin_settings.dart:13`, `test/settings_module_test.dart`, and `pubspec.yaml:15` (`inject_annotation`, used only by the module).
- `packages/zanshin_shell_macos/macos/zanshin_shell_macos/Sources/zanshin_shell_macos/ZanshinShellPlugin.swift:96-104,128-134,281-295` — read-only. The last appearance choice is applied to each titled app window that becomes key, and to all of them when set. The splash is not an app window.

**Tests:**
- `app/test/app/boot/zanshin_bootstrap_test.dart` — `startSequence` L177 and `startWith` L221 feed the four callbacks.
  - These stay sequence tests: L203, L237, L253, L277, L298, L331, L346, L374, L394, L407, L418, L436, and L473's "status keeps the last line".
  - These move to `loadBootValues`: L501, L557, L587, L473's exact line list, and L394's "mode read from settings".
  - L616-L758 are unaffected.
- `app/test/app/boot/boot_window_host_test.dart:46-61,75,97-102` — the icon and menu notifiers and the icon assertions.
- `app/test/app/zanshin_app_test.dart` — the parts that go or change:
  - imports `main.dart` (:10);
  - the hand-written `_HomePageFactory`/`_RootFactory`/`_Provider<T>`/`_viewModels` (:42-109) and `pumpApp` (:138-168);
  - `mainComponent()` with a never-completed `Completer` (:171-182);
  - the hand-wiring tests L184, L212, L230, L246.
- `app/test/features/home/home_page_test.dart` — `_ViewModels`/`_factory` (:67-92); `pumpHome` (:104-134), which takes `repos`, `before(session)`, `ActiveGraph()` and disposes at :116/:121.
- `app/test/features/window/zanshin_window_root_test.dart`:
  - `_Provider<T>`/`_viewModels` (:44-69);
  - `pumpTwoWindows` (:126-170): an outer `IconRegistryScope` :156 and the view-model capture;
  - the theme test L257 (`setThemeMode` :271, `setWindowAppearance:light` :276);
  - `pumpContentSized` (:281-307).
- `app/test/features/projects/projects_window_test.dart:2149-2168` — the DI test over `MainComponent` with `Completer<ZanshinWorker>().future`; :2165 asserts `isA<DesktopProjectsEnvironment>`.
- `app/test/app/worker_lifecycle_module_test.dart` — the `_Worker` stand-in :10-18; the `answerExitRequest` tests :21-46; the module test :48-61.
- `app/test/features/window/zanshin_app_view_model_test.dart` — the `RecordingShell` set-up :26-37; init expects `setWindowAppearance:dark` :48-54; the `setThemeMode` tests :68-80; `vm.setThemeMode` in :82-91 and :130-155.
- `app/test/app/menu/app_menu_test.dart`:
  - rig :187-194, 211-261, with `..attach(windows, actions)..openUrl = …` at :227-229;
  - `urls` asserted at :517;
  - bare constructions :833 and :849.
- `app/test/helpers/settings_rig.dart` — :8, :49-50 (`graph` notifier, `themes`), :95 (`setThemeMode`). `app/test/features/settings/settings_window_test.dart:57` reads `themes`.
- `app/test/features/graph/revset_configs/revset_configs_window_test.dart:78,121-126` — a `graph` notifier and `openUrl`.
- `app/test/app/app_window_coordinator_test.dart` — the rig builds the session (:85) before the windows (:87); `launched` :242; the one `mayLeave =` :377 in L375.
- The 14 `Future<ZanshinWorker>.value(worker)` sites:
  - `projects_environment_test.dart:91,107,129,150,182,191,203`;
  - `worker_project_repos_test.dart:289`;
  - `graph_ports_test.dart:68`;
  - `repo_settings_reads_test.dart:20,49`;
  - `graph_real_repo_test.dart:53`;
  - `repo_graph_source_test.dart:31,137`.
- Helpers to reuse, in `app/test/helpers/`: `FakeProjectRepos()` `fake_projects.dart:14`, `FakeProjectsEnvironment()` `fake_projects_environment.dart:11`, `FakeWindowFactory()` `fake_windows.dart:15`, `setUpIconRegistry()`/`testIconRegistry` `icon_registry.dart:7-15`, `FakeWindowActions()` `fake_window_actions.dart:6`, `RecordingShell()` `recording_shell.dart:16`.
- The real-worker pattern is in `app/test/features/graph/graph_ports_test.dart:66-71`.

**Catalogue:** `app/widgetbook/folders/windows.dart` — `ValueNotifier<GraphMenuBinding?>` at :709 and :811; `setThemeMode:` at :765; `openUrl:` at :924.

## Tasks & Acceptance

**Execution:**

Packages:
- `packages/zanshin_core/lib/src/worker/worker_module.dart` and `lib/zanshin_core.dart` — delete the module and its export (item 1).
- `packages/zanshin_settings/lib/src/settings_module.dart`, `lib/zanshin_settings.dart`, `test/settings_module_test.dart`, `pubspec.yaml` — remove `SettingsModule`, its export, its test and the now unused `inject_annotation` dependency (item 1).

Projects:
- `app/lib/src/features/projects/worker_project_repos.dart` and `projects_environment.dart` — take a `ZanshinWorker`, not a future (item 2).
- `app/lib/src/features/projects/project_session.dart` — `mayLeave` becomes an optional, final constructor parameter (item 3).
- `app/lib/src/features/projects/project_registry.dart` — `@inject @singleton` (item 3).
- `app/lib/src/features/projects/projects_module.dart` — a module with no constructor arguments:
  - `@singleton ProjectRepos projectRepos(ZanshinWorker)` → `WorkerProjectRepos`, bound on its own;
  - `@singleton ProjectSession projectSession(ProjectRegistry, ProjectRepos, AppWindows)` with `mayLeave: windows.mayClose`;
  - `@singleton ProjectsEnvironment projectsEnvironment(ZanshinWorker, GetDiagnostics)`;
  - the registry provider goes (item 3).

Links and window:
- `app/lib/src/links.dart` — add `typedef OpenUrl = Future<void> Function(Uri url);` (item 4).
- `app/lib/src/features/window/zanshin_window_root.dart` — inject `IconRegistry`; wrap the root's build in `IconRegistryScope` (item 11).
- `app/lib/src/features/window/zanshin_app_view_model.dart` — drop `setThemeMode`, the mirroring in `init()` and `_mirrorWindowAppearance`; update the docs (item 7).
- `app/lib/src/features/window/window_appearance_sync.dart` (new) — `@inject @singleton WindowAppearanceSync(SettingsStore)`. On macOS only (`!kIsWeb && Platform.isMacOS`), `start()` mirrors the persisted `themeMode`, then mirrors every later change of it and nothing else (item 7).

Window contents:
- `app/lib/src/features/settings/settings_window.dart` — `@assistedInject` with part `settings_window.factory.dart` (items 4, 7):
  - injected: `windows`, `store`, `environment`, `session`, and `graph` typed `ActiveGraph`;
  - assisted: required `state`; `String? windowKey`, defaulted in the initializer to `windowKey ?? settingsWindowKey`; `SettingsReadsOf? readsOf`; `key`;
  - `setThemeMode` goes.
- `app/lib/src/features/settings/settings_view_model.dart`:
  - add `typedef SettingsReadsOf = SettingsRepoReads Function(ProjectRepo repo);`;
  - `setThemeMode` becomes a method that writes `appearance.themeMode` to the store, so `general_tab.dart` stays as it is.
- `app/lib/src/features/graph/revset_configs/revset_configs_window.dart` — `@assistedInject` with its part (item 4):
  - injected: `settings`, `graph` typed `ActiveGraph`, `windows`, and a non-null `OpenUrl openUrl`;
  - assisted: `String? windowKey` (→ `?? revsetConfigsWindowKey`), `key`;
  - the null-opener branch goes.

App frame:
- `app/lib/src/app/menu/app_menu.dart` (item 6):
  - the constructor becomes `(tracker, session, settings, graph, projectsSearch, windows, actions, openUrl)`, every field final;
  - `attach()` and the `openUrl` field go;
  - the null-windows and null-actions branches collapse.
- `git mv app/lib/src/app/worker_lifecycle_module.dart app/lib/src/app/app_exit_handler.dart` (item 8):
  - `answerExitRequest` is unchanged;
  - new `@inject @singleton AppExitHandler(AppWindows, ZanshinWorker)`. Its `start()` registers one `AppLifecycleListener` whose `onExitRequested` runs `answerExitRequest(mayQuit: windows.mayClose, closeWorker: worker.close)`; a second `start()` registers nothing.
- `app/lib/src/app/boot/zanshin_bootstrap.dart` (item 11):
  - new `BootProgress`: `log(String)` and a `ThemeMode persistedTheme` property;
  - `ZanshinBootSequence({required host})` implements it;
  - `run(Future<BootFirstWindow> Function(BootProgress progress) boot)`;
  - the four callbacks and `_load` go.
- `app/lib/src/app/boot/boot_module.dart` (new; delete `icon_module.dart`) (item 1):
  - `typedef BootValues = ({SettingsStore settings, IconRegistry icons, ZanshinWorker worker})`;
  - `loadBootValues(progress, {openSettings, adoptShellEnvironment, loadIcons, startWorker})`, defaulting to `SettingsStore.open`, the moved `_adoptShellEnvironment`, `IconRegistry.load` and `ZanshinWorker.start`. It keeps `_load`'s lines, order and persisted-theme report, then logs `bootStarting` and starts the worker;
  - `@module BootModule(this.boot, this.windows)` provides `SettingsStore`, `IconRegistry`, `ZanshinWorker` and `AppWindows` as singletons.
- `app/lib/src/app/boot/boot_window_host.dart` — `ZanshinWindowHost({required windows})` (item 11):
  - it owns a `ValueNotifier<AppMenuModel?>` and gets `showMenu(AppMenuModel)`;
  - the icon builder goes.
- `app/lib/src/app/app_module.dart` (new) — `@module AppModule` (items 4, 5):
  - `@singleton AppWindowCoordinator`, built from `AppWindows`, `ProjectSession` and the factories `ZanshinAppFactory`, `ZanshinWindowRootFactory`, `ProjectsWindowFactory`, `RevsetConfigsWindowFactory`, `SettingsWindowFactory`. It is today's `appWindowCoordinator` code, without `@visibleForTesting`;
  - `AppWindowActions` → the coordinator;
  - `OpenUrl` → `openInBrowser`.
- `app/lib/src/app/zanshin_application.dart` (new) — `@inject @singleton ZanshinApplication(coordinator, menu, settings, windows, exitHandler, appearance)`. `BootFirstWindow start()` runs, in this order: `bindWindowZoom`, `exitHandler.start()`, `appearance.start()`, `coordinator.start()` (item 9).
- `app/lib/main.dart` and the regenerated `main.inject.dart` and factories (items 10, 11):
  - binding, logging and zone set-up stay as they are;
  - then the Design Notes boot;
  - `@Component([ZanshinDiagnosticsModule, BootModule, ProjectsModule, AppModule])` with one getter, `ZanshinApplication get application`.

Test component:
- `app/test/helpers/test_component.dart` (new, plus the generated `test_component.inject.dart`) (item 12):
  - `@module TestModule({repos, environment})` provides `@singleton` `ProjectRepos` and `ProjectsEnvironment`;
  - `@Component([ZanshinDiagnosticsModule, BootModule, ProjectsModule, AppModule, TestModule])` exposes the coordinator, factories, session, settings, active graph, registry, environment, search focus, tracker and application;
  - a helper builds `BootValues` (a temp-dir store, `testIconRegistry`, the file's real worker started in `setUpAll`) and `AppWindows` over `FakeWindowFactory`.

Tests to adapt:
- `app/test/app/boot/zanshin_bootstrap_test.dart` — the (a) tests drive `run` with fake boot functions: the fast/slow boot and late/early failure rows of the matrix.
- `app/test/app/boot/boot_window_host_test.dart` — no icons or menu arguments; the icon assertions go.
- `app/test/app/zanshin_app_test.dart` — through the test component:
  - `pumpApp` via `ZanshinAppFactory`;
  - L184/L212/L230/L246 become "the graph builds …" tests over the coordinator's builders;
  - add the witness: the four contents over one session, one store and one active graph;
  - add the "switch blocked by a guard" row: the component's session asks the windows' close guards.
- `app/test/features/home/home_page_test.dart` — `pumpHome` via the component, with `TestModule(repos:)`, `before(component.session)` and `component.activeGraph`.
- `app/test/features/window/zanshin_window_root_test.dart` — roots via the component's factory; no outer `IconRegistryScope`. Add: the root provides the injected registry. The theme switch uses `store.update`.
- `app/test/features/projects/projects_window_test.dart` DI test — through the component; add `isA` checks on `ProjectsModule().projectRepos(worker)` and `.projectsEnvironment(worker, …)`.
- `app/test/features/window/zanshin_app_view_model_test.dart` — init expects `['getTheme']`; the `setThemeMode` test goes; the rest use `store.update`.
- `app/test/app/menu/app_menu_test.dart` — the new constructor with a recording opener.
- `app/test/helpers/settings_rig.dart` and `app/test/features/settings/settings_window_test.dart:57` — `ActiveGraph()`; the Theme test reads the store.
- `app/test/features/graph/revset_configs/revset_configs_window_test.dart` — `ActiveGraph()`.
- `app/test/app/app_window_coordinator_test.dart` — the rig gets a `mayLeave` option, and L375 uses it.
- The 14 future sites listed in the Code Map pass the worker itself.

New tests:
- `app/test/app/boot/boot_module_test.dart` — `loadBootValues`, over a recording `BootProgress` and fake seams: the "shell slower than settings" and "shell or icons fail" rows; no shell line when the shell finished first; the persisted theme is reported.
- `app/test/features/window/window_appearance_sync_test.dart` — the "theme row" and "other setting changes" rows over `RecordingShell`.
- `app/test/app/app_exit_handler_test.dart` — a `git mv` of `worker_lifecycle_module_test.dart`. Add the ⌘Q row with `start()` called twice: one listener, using the existing `_Worker` stand-in.
- `app/test/app/zanshin_application_test.dart` — `start()` through the component: a stored 125 % zoom gives `windows.zoom` 1.25, the appearance is mirrored, a refusing guard is asked once on exit, and the Projects first window is returned.

Catalogue:
- `app/widgetbook/folders/windows.dart` — use `ActiveGraph()` and remove `setThemeMode:` (item 4).

**Acceptance Criteria:**
- Given `main.dart`, when read:
  - `MainComponent` lists exactly `ZanshinDiagnosticsModule`, `BootModule`, `ProjectsModule` and `AppModule`, with the one getter `ZanshinApplication get application`;
  - after `create()`, nothing in it is a `ValueNotifier`, a `Completer`, a setter or `attach()`.
- Given `app/lib` and `packages/*/lib` (excluding `_bmad-output`/`docs/superpowers`), when grepped:
  - these names are gone: `SettingsModule`, `WorkerModule`, `IconModule`, `WorkerLifecycleModule`, `appWindowCoordinator`, `attach(windows`, `openUrl =`, `mayLeave =`, `Future<ZanshinWorker>`;
  - `ZanshinAppViewModel` has no `setThemeMode`, and `SettingsWindow` no `setThemeMode` parameter;
  - only generated code constructs `ZanshinAppViewModel`.
- Given `app/test`, when grepped:
  - no class implements `HomePageFactory`, `ZanshinWindowRootFactory` or `Provider<`;
  - nothing creates `MainComponent` or a worker `Completer`.
- Given the test component, when the coordinator builds the project, Projects, Settings and jj log Configurations contents, then all four use one `ProjectSession`, one `SettingsStore` and one `ActiveGraph`, and Settings sits content-sized under `window:settings`.
- Given the test component's `ZanshinApplication` and a stored zoom, when `start()` runs:
  - the windows carry the stored zoom;
  - the exit handler's listener and the appearance mirror are in place, each once;
  - the coordinator's first window is returned.
- Given `zanshin_application.dart`, when read, then `start()` runs the zoom binding, the exit handler, the appearance sync and `coordinator.start()` in that order.
- Given `dart run build_runner build`, `dart analyze --fatal-infos --fatal-warnings`, `dart format --set-exit-if-changed` and the touched packages' tests, when run:
  - all pass;
  - a rerun of the generator changes nothing.
- Given the running app (Marionette):
  - it starts and reopens the last project;
  - a project switch with unsaved jj log Configurations asks "Discard changes?";
  - so does ⌘Q, which then cancels or quits;
  - a theme switch in Settings restyles every open window's chrome;
  - View › Zoom In grows the window minimums as before.

## Spec Change Log

## Review Triage Log

### 2026-11-07 — Review pass
- verdicts: 34 findings — high 0, medium 3, low 20, false 8, maybe-false 3
- findings:
  - `[medium]` `[patch]` (blind) `ZanshinWindowHost.showMenu` has no test; nothing checks that the app's menus replace the boot's two system menus — test added to `boot_window_host_test.dart`: after the first window, `showMenu(model)` turns `['Zanshin', 'Window']` into the eight top menus.
  - `[low]` `[patch]` (blind) `loadBootValues` lost the settings-failure test the old `_load` had, and a failing worker start has none — two cases added to `boot_module_test.dart`: a settings failure throws with no worker, the theme stays system and the pending shell/icon failures go unheard; a worker failure throws after the theme and "Starting Zanshin…".
  - `[low]` `[reject]` (blind) the test component starts a real worker no test reaches; a stand-in would do — the story's item 12 chooses a real worker for exactly this case ("the test module starts a real one"); one isolate per test file in a suite that needs the cdylib anyway.
  - `[low]` `[patch]` (blind) `SettingsViewModel.setThemeMode` returns the write future its only caller (`ZsSegmented.onChanged`) drops, so a failed write is an unhandled zone error — now `void` through `updatePreferences`, like every other row on the tab; the store still logs a failure.
  - `[false]` `[reject]` (blind) `_openRecent` keeps the null branch the spec said to collapse — no null-actions path remains (`_actions` is final); the call site passes null only while a sheet shows in the project window, which greys Open Recent as before, and the parameter doc says exactly that.
  - `[maybe-false]` `[reject]` (blind) without the per-window mirror, a window that never becomes key keeps the system's chrome — depends on AppKit: the plugin applies the last choice when an app window becomes key (`ZanshinShellPlugin.swift:96-104,128-134`), and a window opened while Zanshin is in the background may become key only on activation. Settle it in the running app (persisted theme opposite the system's); added to the deferred Marionette check. If true, low: cosmetic until the window is focused, and item 7 prescribes the change.
  - `[low]` `[reject]` (blind) the ⌘Q hook is registered later than before — between `loadBootValues` and `start()`'s second statement only code that throws on bugs runs (`MainComponent.create`, the singletons' constructors, `showMenu`, `bindWindowZoom`); ⌘Q still exits, only the worker's graceful close is lost; the fix reorders `start()` against item 9 or adds a catch to main.dart.
  - `[false]` `[reject]` (blind) "once" is witnessed only for the exit handler; `WindowAppearanceSync.start()`/`ZanshinApplication.start()` are unguarded — a doubled sync listener would still send one appearance per change (`_mirrored`), and `start()` runs once: main.dart's boot function runs once per `ZanshinBootSequence.run`, which main calls once.
  - `[false]` `[reject]` (blind) sprint-status.yaml not updated — the story loop records the story's state after the run (11.24's `done` landed in its own commit 671eea2f); the build-auto workflow has no sprint-status step.
  - `[low]` `[patch]` (blind) `_footer` was rewritten as an arrow body, re-indenting ~40 unchanged lines — block body restored with its local (now `OpenUrl`); against the baseline `_footer` differs in two lines.
  - `[low]` `[reject]` (blind) `testComponent` leaves disposal to each caller; `AppExitHandler`'s listener stays registered — no test leaks into another today (each exit listener sits in the last test of its file); a self-disposing helper and a `stop()` the app never calls add surface.
  - `[low]` `[patch]` (blind) `IconRegistryScope`'s docs describe the removed boot phase (above the window manager, null until loaded) — reworded: the window roots each provide the boot-loaded registry; null provides none.
  - `[low]` `[defer]` (edge) `app.start()` throwing after `showMenu` leaves the failure page under the app's menus, whose window items await `_ready` forever — pre-existing (`_startApp` set the menu before `coordinator.start()` too); deferred and mirrored to deferred-work.md.
  - `[low]` `[patch]` (edge) `setThemeMode`'s dropped write future — same entry as the blind row above.
  - `[low]` `[reject]` (edge) a throwing `openInBrowser` behind the Revset reference link is unhandled — pre-existing (the old window made the same `unawaited` call); `/usr/bin/open` exists on every Mac; a catch adds a branch.
  - `[low]` `[reject]` (edge) a failing `setWindowAppearance` is an uncaught zone error and the mode is not re-sent — the same `unawaited` call as the old `_mirrorWindowAppearance`; the plugin is always registered in the app; a catch and a reset add branches for a failure it cannot reach.
  - `[false]` `[reject]` (edge) a second `ZanshinApplication.start()` binds the zoom twice and restarts the coordinator — unreachable: main.dart's boot function calls it once.
  - `[false]` `[reject]` (edge) a throwing `ZanshinWorker.start()` in `setUpTestWorker` is buried under a `LateInitializationError` — the runner reports the `setUpAll` failure itself, the tear-down error comes on top; the same pattern as `graph_ports_test.dart:66-71`.
  - `[low]` `[reject]` (edge) the exit hook is registered later — same entry as the blind row above.
  - `[maybe-false]` `[reject]` (edge) a window that never becomes key misses the persisted theme — same entry as the blind row above.
  - `[low]` `[reject]` (edge) the spec says `RevsetConfigsWindow` injects `OpenUrl`, the code takes it assisted — forced by inject_generator 1.2.1 (a typedef'd function type in an assisted factory's class gets its own provider) and recorded in `deferred:`; the opener still comes from the graph through `AppModule.coordinator`; the fix would edit this build's spec.
  - `[low]` `[reject]` (edge) the AC greps hit `Future<ZanshinWorker>` (zanshin_core's own `ZanshinWorker.start`, the spec's `startWorker` seam), generated `appWindowCoordinator$Provider` names and the generated test component's `Provider<` classes — none is hand wiring, which is what the AC targets; the fix would edit this build's spec.
  - `[medium]` `[patch]` (verification-gap) the menu hand-over (`showMenu`) has no automated check — same entry as the first blind row.
  - `[low]` `[reject]` (verification-gap, other) the ⌘Q listener is registered after the worker started — same entry as the blind row above.
  - `[false]` `[reject]` (intent) the production `MainComponent` is verified only by compilation, every graph test runs `TestComponent` — inject_generator validates every `MainComponent` binding at build time; `TestComponent` lists the same four modules and the two bindings it replaces are called directly in `projects_window_test`; main.dart's closure is the deferred running-app check.
  - `[low]` `[patch]` (intent) no test runs the sequence over `loadBootValues`, the join main.dart makes (grouped with the blind `loadBootValues` row) — test added to `zanshin_bootstrap_test.dart`: over `loadBootValues` with a dark store and a failing shell the splash status saw the real lines, no worker started, and the failure page is dark.
  - `[medium]` `[patch]` (intent) no test calls `showMenu` — same entry as the first blind row.
  - `[low]` `[defer]` (intent) the running-app witnesses are covered only below the app (reopen through the graph, the Configurations "Discard changes?", the allowed ⌘Q path, the native chrome, the zoom minimums) — already the deferred Marionette check in `deferred:`.
  - `[maybe-false]` `[reject]` (intent) the theme mirror's new timing against "no behaviour change" — same entry as the blind never-key row; item 7 prescribes it.
  - `[low]` `[reject]` (intent) on a boot that fails after the worker started, ⌘Q finds no listener — same entry as the blind row above.
  - `[low]` `[patch]` (intent) the spec's verification notes record no outcomes — Verification now points to the outcomes, and Auto Run Result › Verification lists every check with its result.
  - `[low]` `[patch]` (intent) the plan runs no `zanshin_core` tests although that package changed — `cargo make --allow-private test-core` run: 1205 passed.
  - `[false]` `[reject]` (intent) `settings_rig`, `revset_configs_window_test`, `projects_window_test` and the catalogue still build these widgets by hand — item 12 targets the hand-written factories, providers and components, all gone; calling a widget's constructor with fakes is a plain constructor call (the skill's style 1).
  - `[false]` `[reject]` (intent) the spec-planned deviations (21 + 4 boot tests, the rig's `mayLeave` option, `showMenu`, the seams, the `ActiveGraph` type) are not recorded as deferrals — each is the spec's planned resolution (Boundaries, Design Notes), not deferred work, and the 24 sequence tests survive (21 in the sequence file, the three `_load` ones as `loadBootValues` cases).

## Design Notes

**inject_generator 1.2.1 (probe 2026-11-07, scratchpad `inject_probe/`):**
- Override: a later module's binding wins over an earlier module's. But every provider of every listed module is still validated. So a test component that lists `ProjectsModule` must bind `ZanshinWorker`. The story's fallback applies: one real worker per test file, passed in through `BootValues`.
- Defaults: `@assisted` parameters lose their default value, and raw function types lose their import prefix. So the seams are nullable, the default is applied in the initializer, and `readsOf` uses a typedef.
- Nullable injected parameters need a class or typedef type.
- Cycles: an assisted factory's dependencies count as cycle edges. No window content may take `AppMenuModel`.

**Choices:**
- `graph` as `ActiveGraph`: a drop-in for the notifiers the tests and catalogue pass. `SettingsViewModel` keeps its `ValueListenable`.
- `ProjectRepos` is `@singleton`: one `WorkerProjectRepos`, as before.
- `WindowAppearanceSync` sits in `features/window/`, next to the view model it leaves. `AppModule`, `ZanshinApplication`, `AppExitHandler` and `boot_module.dart` sit in the frame.
- The theme now reaches the native chrome at `start()`, before the first app window. The plugin applies the last choice to each app window as it becomes key, which the engine makes it on its first frame.
- The menu is handed over by a method, not a setter, because the witness bans setters after `create()`. If `use_setters_to_change_properties` reports it, suppress the lint with a one-line WHY.

```dart
final windows = AppWindows();
final host = ZanshinWindowHost(windows: windows);
await ZanshinBootSequence(host: host).run((progress) async {
  final BootValues boot = await loadBootValues(progress);
  final ZanshinApplication app = MainComponent.create(bootModule: BootModule(boot, windows)).application;
  host.showMenu(app.menu);
  return app.start();
});
```

## Verification

**Commands:**
- `dart run build_runner build` (in `app/`) — expected: the generated files are committed, and a rerun changes nothing.
- `cargo make --allow-private test-dart-analyze` and `test-dart-format` (app) — expected: clean.
- `test-core-analyze` and `test-core-format` (zanshin_core) — expected: clean.
- `test-settings-analyze`, `test-settings-format` and `test-settings` (zanshin_settings) — expected: clean.
- `cargo make test-app <touched test files>`, then the whole app suite in batches — expected: everything passes.
- `rg` for each Acceptance Criteria grep — expected: no hits.
- `cargo make --allow-private test-core` (zanshin_core lost a module) and `test-ui-analyze` / `test-ui-format` / `test-ui` (zanshin_ui's docs changed in review) — expected: pass.

**Outcomes (2026-11-07):** every check this run ran and its result is listed under Auto Run Result › Verification.

**Manual checks (if no CLI):**
- The running-app AC through Marionette. If the unattended run cannot hold a running app safely, record it as deferred for Ralph. The app reopens the machine's last project, which would snapshot a real repository.

## Auto Run Result

Status: done

**Summary:** the DI graph is the app's one composition root.
- `MainComponent` lists `ZanshinDiagnosticsModule`, `BootModule`, `ProjectsModule` and `AppModule` and has one getter, `ZanshinApplication get application`.
- main.dart keeps the binding, logging and zone set-up, then runs windows → host → `ZanshinBootSequence(host:).run(boot)`. The boot function loads the boot values, creates the component, hands its menu to the host (`showMenu`) and returns `app.start()`.
- `loadBootValues` keeps `_load`'s lines, order and persisted-theme report (settings ‖ shell environment ‖ icons, then the worker). `BootModule(boot, windows)` hands the settings, icons, worker and windows to the graph.
- `SettingsModule`, `IconModule`, `WorkerModule`, `WorkerLifecycleModule` and the worker `Completer` are gone. `WorkerProjectRepos` and `DesktopProjectsEnvironment` take the worker itself.
- `ProjectsModule` binds `ProjectRepos` on its own and builds `ProjectSession` with `mayLeave: windows.mayClose`. `ProjectRegistry` is `@inject @singleton`.
- `SettingsWindow` and `RevsetConfigsWindow` use `@assistedInject`, with `graph` typed `ActiveGraph`. The `windowKey`/`readsOf` seams are nullable assisted parameters, because inject_generator drops defaults. `RevsetConfigsWindow.openUrl` is assisted: `AppModule` passes the graph's `OpenUrl` (generator limitation; deferred).
- `AppModule` provides the coordinator from injected factories, `AppWindowActions` and `OpenUrl`.
- `AppMenuModel` is wired by its constructor alone.
- `WindowAppearanceSync` mirrors the theme at `start()` and on every theme change. `ZanshinAppViewModel` lost `setThemeMode` and the mirror; the Settings Theme row writes the store.
- `AppExitHandler` (with `answerExitRequest` verbatim) registers the ⌘Q listener once.
- `ZanshinApplication.start()` runs the zoom binding, the exit handler, the appearance sync and `coordinator.start()`, in that order.
- `ZanshinWindowRoot` provides the injected `IconRegistry`. The host's icon notifier is gone.
- Tests go through `TestComponent`: the production modules plus a `TestModule` with fake repositories and a fake Projects environment. Every file using it starts one real worker, because inject_generator validates the overridden providers.
- No behaviour, string or visual change. The theme mirror's timing changed as item 7 asks.

**Files changed:**
- Packages:
  - `packages/zanshin_core`: `lib/src/worker/worker_module.dart` deleted, its export gone from `lib/zanshin_core.dart`.
  - `packages/zanshin_settings`: `lib/src/settings_module.dart` and `test/settings_module_test.dart` deleted, the export gone from `lib/zanshin_settings.dart`, `inject_annotation` gone from `pubspec.yaml`.
  - `packages/zanshin_ui/lib/src/icons/icon_registry.dart`: the `IconRegistryScope` docs (review).
- Composition root:
  - `app/lib/main.dart`: the linear boot and the one-getter component.
  - Regenerated: `app/lib/main.inject.dart`, `features/settings/settings_window.factory.dart`, `features/graph/revset_configs/revset_configs_window.factory.dart` (the last two are new).
- New: `app/lib/src/app/app_module.dart`, `app/lib/src/app/zanshin_application.dart`, `app/lib/src/app/boot/boot_module.dart`, `app/lib/src/features/window/window_appearance_sync.dart`.
- Moved and deleted:
  - `app/lib/src/app/worker_lifecycle_module.dart` → `app_exit_handler.dart`.
  - `app/lib/src/app/boot/icon_module.dart` deleted.
- Edited:
  - `app/lib/src/app/boot/{zanshin_bootstrap,boot_window_host}.dart`, `app/lib/src/app/menu/app_menu.dart`;
  - `app/lib/src/features/projects/{projects_module,project_registry,project_session,worker_project_repos,projects_environment}.dart`;
  - `app/lib/src/features/settings/{settings_window,settings_view_model}.dart`;
  - `app/lib/src/features/graph/revset_configs/revset_configs_window.dart`;
  - `app/lib/src/features/window/{zanshin_window_root,zanshin_app_view_model}.dart`;
  - `app/lib/src/links.dart` (`OpenUrl`).
- Tests:
  - New: `app/test/helpers/test_component.dart` (+ generated `test_component.inject.dart`), `app/test/app/boot/boot_module_test.dart`, `app/test/app/zanshin_application_test.dart`, `app/test/features/window/window_appearance_sync_test.dart`.
  - Moved: `app/test/app/worker_lifecycle_module_test.dart` → `app_exit_handler_test.dart`, with a new "started twice: one listener" ⌘Q test.
  - Adapted:
    - `zanshin_bootstrap_test` (21 sequence tests, plus one over `loadBootValues`), `boot_window_host_test` (plus the `showMenu` test);
    - `zanshin_app_test` (the four "graph builds" tests, plus one "four contents, one session/store/graph" test, plus one "switch asks the close guards" test);
    - `app_menu_test`, `app_window_coordinator_test` (the rig's `mayLeave` option, one line in L375), `home_page_test`, `zanshin_window_root_test` (plus "each root provides the registry"), `zanshin_app_view_model_test`, `projects_window_test`, `helpers/settings_rig`, `settings_window_test`, `revset_configs_window_test`;
    - the 14 sites that passed a future of the worker.
- Catalogue: `app/widgetbook/folders/windows.dart` (`ActiveGraph()`, no `setThemeMode:`).
- Ledger: `deferred-work.md` (section "Surfaced in Story 11.25").

**Review:** 34 findings: 0 high, 3 medium, 20 low, 8 false, 3 maybe-false.
- **Patched (7 entries: 1 medium, 6 low):**
  - the `showMenu` hand-over test (medium: blind, verification-gap and intent);
  - two `loadBootValues` failure cases and one test of the sequence over `loadBootValues`;
  - `SettingsViewModel.setThemeMode` is now `void` through `updatePreferences`;
  - `_footer` restored to its block body;
  - the `IconRegistryScope` docs;
  - the verification outcomes recorded here;
  - the zanshin_core suite run.
- **Deferred** (3 items in `deferred:`, all mirrored to deferred-work.md):
  - the Marionette witness, extended in review with a window opened while Zanshin is in the background;
  - the assisted `openUrl`;
  - the failure page keeping the app's menus (pre-existing).
- **Rejected:** each with its reason in the Review Triage Log:
  - the real worker in the test component (item 12 chooses it);
  - the late ⌘Q hook on a failed boot (only bug paths; the fix fights item 9's order);
  - the never-key window's chrome (maybe-false; added to the Marionette check);
  - test teardown and an exit-listener `stop()` (no leak today, new surface);
  - the pre-existing unhandled `openInBrowser`/`setWindowAppearance` failures;
  - the spec-wording claims (the `OpenUrl` wiring, the literal AC greps);
  - eight false findings.

**Follow-up review recommended:** false. The patched entries were 1 medium and 6 low, with no high, and fewer than two medium entries were patched.

**Verification** (targeted, per the loop's gate rule; no `cargo make test`/`test-full`/`coverage`):
- `dart run build_runner build` (app), after implementation and again after the review patches: the generated files are byte-identical (git shows no diff).
- `cargo make --allow-private test-dart-analyze` (app): no issues, both times. `test-dart-format`: 287 files, 0 changed, both times.
- `test-core-analyze`: no issues. `test-core-format`: 166 files, 0 changed. `cargo make --allow-private test-core`: 1205 passed.
- `test-settings-analyze`: no issues. `test-settings-format`: 23 files, 0 changed. `test-settings`: 43 passed, both times.
- After the review: `test-ui-analyze` no issues, `test-ui-format` 112 files with 0 changed, `test-ui` 459 passed.
- `cargo make test-app` over every app test folder in three batches:
  - before the review: 157 + 1611 + 426 = 2194 passed;
  - after the patches: 161 + 1611 + 426 = 2198 passed.
- Acceptance greps (`app/lib`, `packages/*/lib`, hand-written `app/test`):
  - Gone: `SettingsModule`, `WorkerModule`, `IconModule`, `WorkerLifecycleModule`, `attach(windows`, `mayLeave =` and the mutable `openUrl =`. The one remaining `openUrl =` hit is `_footer`'s local.
  - `Future<ZanshinWorker>` appears only in the `startWorker` seam type and zanshin_core's own `ZanshinWorker.start`. `appWindowCoordinator` appears only as generated provider names.
  - `ZanshinAppViewModel(` appears only as its declaration and in generated code.
  - Hand-written tests contain no factory or `Provider<` implementation, no `MainComponent` and no worker `Completer`. main.dart holds no `ValueNotifier`, `Completer` or `attach(`.
- Not run:
  - the full gate (the story loop runs it);
  - Rust checks and the parity oracle (no Rust or jj verb changed);
  - the running app through Marionette (deferred).

**Residual risks:**
- The production `MainComponent` and main.dart's boot closure are checked by the generator, the analyzer and `TestComponent` (the same modules), not by a running app.
- The native chrome now takes the theme from `start()` and from the plugin's key-window hook. A window opened while Zanshin is in the background is unverified.
- On a boot that fails after the worker started but before `start()` registers the exit handler, ⌘Q exits without closing the worker (rejected, low).
- The test files using `TestComponent` each start a real worker, so they need the cdylib.
- The coverage ratchet has not run. No Rust changed.
