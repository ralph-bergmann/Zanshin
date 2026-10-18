---
title: 'Story 11.12 closing run — Projects on the window scaffold, the native window plan a test pins'
type: 'refactor'
created: '2026-10-19'
status: 'done'
baseline_revision: '86863e8672d1fc94a1e839196f1bd709fa335470'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-11-context.md'
warnings: ['multiple-goals', 'oversized']
deferred:
  - summary: >-
      The remembered controllers' create glue (the plan's values into the *MacOS constructors, runnerArguments into the restore call, and createRememberedWindow's dispatch) runs in no test; only a running app's DEBUG zanshin.window lines check it.
    evidence: |-
      planNativeWindow is pinned (app_windows_test.dart, boot_window_host_test.dart), but RememberedWindowController.create and RememberedDialogWindowController.create cast the owner to WindowingOwnerMacOS and call FFI, so no widget test reaches them; every window test injects FakeWindowFactory (app/test/helpers/fake_windows.dart:33-56). The closing run's catalogue showed widgetbook as titled|closable|miniaturizable|resizable|fullSizeContentView and widgetbook-projects-window as titled|closable|resizable|fullSizeContentView with fullScreenAuxiliary, both restorable false, level 0.
    location: >-
      app/lib/src/features/window/remembered_window_controller.dart (RememberedWindowController.create); app/lib/src/features/window/remembered_dialog_window_controller.dart (create); app/lib/src/features/window/app_windows.dart (createRememberedWindow)
    severity: low
---

<intent-contract>

## Intent

**Problem:** Two ledger items Story 11.12's run deferred, both verified against the current code. (1) `ProjectsWindowState._header` lays its `Row` into the 52 pt `SizedBox` with no shift, so its title and controls centre on y 26 whatever the measured traffic-light block says, while `ZsWindowScaffold._header` centres on `--tl-mid-y` (`shift = tlMidY − windowHdH/2`, window.css:29); at the macOS 27 reference block both give 26, at any other block Projects sits off the buttons' line. (2) The engine-bound creation paths run in no test: `createRememberedWindow` maps an `AppWindowRequest` (a `DialogWindowSpec`'s size, constraints, resizable, frame, level; the chrome kind) onto `RememberedWindowController`/`RememberedDialogWindowController`, which cast the owner to `WindowingOwnerMacOS`; `ZanshinWindowHost.openProjects` is "not unit-tested"; only `restoreArguments` is pinned.

**Approach:** (1) As the ledger's follow-up proposes: the Projects content lays itself out on `ZsWindowScaffold`'s sidebar form (title "Projects", the search and buttons as header controls, the sidebar, the rest of the main column as body), so it takes the scaffold's `--tl-mid-y` centring, header, hairlines and fill instead of its own copy. (2) The ledger's seam: a pure function `planNativeWindow(AppWindowRequest)` returns a sealed `NativeWindowPlan` — `ProjectWindowPlan` or `DialogWindowPlan` — holding the controller's arguments and the runner's `restore` arguments; the two controllers only carry a plan out; tests pin every request kind's plan, and a host test runs `ZanshinWindowHost.openProjects` over the fake factory (its request, `runWidget`, the registry path).

## Boundaries & Constraints

**Always:**
- Item 1: at the reference block the Projects window looks and behaves as today — title at sidebar + 12 (x 212), search 230 (120 below 800 wide), Add directory, Clone…, New group, header 52 with its `--fl-border` hairline, the 200 sidebar with its right hairline and empty 52 pt top, both dragging the window; the title `--text-dim` while inactive; the focus order main column (header, then body) before the sidebar; the search's ↓ into the tree; identifiers and `projects-window` root key/semantics unchanged; the offer sheet still covers the whole content. The window class doc describes the scaffold form instead of its own header.
- Item 2: the native behaviour is unchanged — the same controller classes with the same constructor values, and the same `restore` map (`restoreArguments`' output and the runner's names untouched). `createRememberedWindow` stays `AppWindows`' default factory; the controllers' `create` takes the plan (and the delegate); the plan decides the chrome kind (project → `main`, dialog → `secondary`) and, for a project window, frame `full` and level `normal`.
- Dart: SPDX first line, page width 120, `dart analyze --fatal-infos --fatal-warnings` and `dart format` clean; windowing `// ignore_for_file` as in the sibling files; docs on every public item; tests set `isWindowingEnabled = true` as `app_windows_test.dart` does.

**Never:**
- No change to `ZsWindowScaffold` (zanshin_ui), Swift, the channel or its argument names, `AppWindows`' registry/exit/close logic, the coordinator, or any other ledger item of Story 11.12 (its deferrals 1, 2, 3, 5 stay as they are).
- No golden tests; no edits under `design/` or `design_system/`; no change to existing deferred-work.md bullets, `epics.md`, `epic-11-context.md`, `sprint-status.yaml`, `project-context.md` or Story 11.12's spec; never lower `coverage-baseline.txt`.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Reference block | Projects at 900 × 640, default appearance | title x 212; title, search and Add directory centred on y 26 | — |
| Measured block | `trafficLights: Rect.fromLTWH(20, 20, 60, 14)` (centre y 27) | title, search and Add directory centred on y 27; title still x 212; header still 52 | — |
| Project request | `create(key: main)` without size | `ProjectWindowPlan`: size 1200 × 800, constraints min 880 × 560, title; `restore {window, key main, chrome main, frame full, level normal}` | — |
| Projects request | `dialog: projectsWindowSpec` | `DialogWindowPlan`: size 900 × 640, min 680 × 440, resizable; `restore {…, projects, secondary, full, normal}` | — |
| Content-sized dialog | spec without size, max 620 × 740, not resizable, frame position | size null, constraints as given, not resizable; `restore {…, secondary, position, normal}` | — |
| Floating dialog | spec 880 × 580, min 820 × 460, level floatingWhileActive | resizable; `restore {…, secondary, full, floating}` | — |
| Boot: Projects first | `ZanshinWindowHost.openProjects(content)` over a fake factory | the factory gets key `projects`, title "Projects", spec `projectsWindowSpec`; the content renders through `runWidget`; a later `openMain` registers its window beside it | — |

</intent-contract>

## Code Map

- `app/lib/src/features/projects/projects_window.dart` -- class doc :26-61 ("paints [ZsWindowFill], and draws its own 52 pt header row and the sidebar's empty 52 pt top"); `build` :590-647 (`Semantics` → `KeyedSubtree` → `ZsWindowFill` → `FolderDropTarget` → `LayoutBuilder` (`narrow` from `maxWidth`) → `Stack[Positioned.fill(FocusTraversalGroup(OrderedTraversalPolicy, Row[FocusTraversalOrder(2) sidebar, Expanded(FocusTraversalOrder(1) main)])), sheet]`); `_sidebar` :649-695 (own right-hairline `DecoratedBox`, a 52 pt `WindowDragArea` box, brand, nav, `Spacer`, identity footer); `_main` :697-748 (`_header`, notice, clone form, `Expanded` tree, drop hint); `_header` :750-847 (the drift: `Row` in `SizedBox(height: windowHdH)`, padding symmetric `chromeInset`, title `ZsType.cardSubject` 600/1.2 in a `WindowDragArea`, search with the ↓ `Focus`, three `ZsButton`s). `package:zanshin_shell` stays imported (`FolderDropTarget`).
- `packages/zanshin_ui/lib/src/materials/zs_window_scaffold.dart` (read-only) -- `ZsWindowScaffold({title, body, header, align, titleHidden, sidebar})`: fill; sidebar form = sidebar's right hairline, `padding-top: windowHdH` + a drag area there; header `Row(spacing: 12, [Expanded(title), ...header])`, padding symmetric `chromeInset` with a sidebar, shift `tlMidY − windowHdH/2` (:178-190), drag area behind the row, title `IgnorePointer` + `Semantics(header: true)`, own title style (sans 600 13/1.2 = Projects' `cardSubject` override); body in `Flexible` of a `Column(mainAxisSize: min)` (a sized window gives a filling body the rest). Header controls are plain widgets: several can be one `Row(mainAxisSize: min, spacing: 12)` inside a `FocusTraversalOrder`.
- Focus: `OrderedTraversalPolicy` puts ordered members first (merge-sorted by order), unordered after — so header group, body group and sidebar group each need an explicit order (1, 2, 3) to keep today's main-before-sidebar order.
- `app/test/features/projects/projects_window_test.dart` -- `_Rig.pump(appearance:)` :92-135 (`shellHost`); layout test :195-240 (title x 212, search centre dy 26, `find.text('Projects').last` = the title); Tab test :340-369; inactive title :1117-1124. Measured-block pattern: `packages/zanshin_ui/test/materials/zs_window_scaffold_test.dart:37-65`.
- `app/lib/src/features/window/remembered_window_controller.dart` -- enums :12-38, `restoreArguments` :43-58 (pinned, unchanged), `RememberedWindowController._` :74-80 (`resizable: true`), `create` :89-114 (hard-coded `main`/`full`/`normal`). Put the plan classes here, beside the args they produce (the dialog controller already imports this file; no import cycle).
- `app/lib/src/features/window/remembered_dialog_window_controller.dart` -- `create` :36-65 (chrome `secondary` hard-coded; frame/level/resizable passed in).
- `app/lib/src/features/window/app_windows.dart` -- `DialogWindowSpec` :53-82, `projectsWindowSpec` :89-93, `AppWindowRequest` :97-126 (its `delegate` is an `AppWindowLifecycle` with a private constructor → tests get requests from `FakeWindowFactory.requests`), `AppWindowFactory` doc :128-133, `createRememberedWindow` :135-158 (the mapping to move into `planNativeWindow`).
- `app/lib/src/features/bootstrap/boot_window_host.dart` -- class doc :28-33 ("Not unit-tested …"), `openProjects` :76-83, `openMain` :72-73, `_present` :127-140 (first window through `runWidget(ValueListenableBuilder → IconRegistryScope → WindowManager)`, later ones `windows.register`).
- Test infrastructure: `app/test/helpers/fake_windows.dart` (`FakeWindowFactory`: `requests`, `delegates`, test-owner controllers); `app/test/features/window/app_windows_test.dart:31-61` (`isWindowingEnabled` pin, `newWindows()`, `_settings`/`_configurations` specs :19-29, teardown destroys controllers); `app/test/features/window/remembered_window_args_test.dart` (restore map + Swift names; unchanged). flutter_test supports `runWidget` (`debugCheckZone` true, `scheduleAttachRootWidget` attaches at once, binding.dart:1314, :2391); test-owner controllers' `rootView` is a `_TestFlutterView` added to the test platform dispatcher (binding.dart:165-174, :466-490), so `WindowManager` renders them.
- Catalogue: Projects › Projects window › Tree (`projects/projects-window/tree`, `app/widgetbook/folders/projects.dart:32`), Windows › Projects window (`app/widgetbook/folders/windows.dart:144`, :433-446, a real `projects` dialog window). DS: `design_system/components/window/window.css:20-43`, `window.card.html`.

## Tasks & Acceptance

**Execution:**
- `app/lib/src/features/projects/projects_window.dart` -- `build` puts `ZsWindowScaffold(title: 'Projects', sidebar: …, header: [one ordered group: search, Add directory, Clone…, New group], body: …)` inside the `Positioned.fill` traversal group (orders: header 1, body 2, sidebar 3), drops its own `ZsWindowFill`; `_sidebar` keeps only the 200 column (brand, nav, spacer, footer) — the scaffold draws its hairline and 52 pt drag top; `_header` becomes the header controls only; `_main` the body column (notice, clone form, tree, drop hint); class doc updated -- item 1.
- `app/test/features/projects/projects_window_test.dart` -- the layout test also asserts the title's and Add directory's centre at y 26; a new test pumps the measured block (centre y 27) and asserts title, search and Add directory centred on 27 with the title at x 212 -- item 1's witnesses (existing tests stay green unchanged).
- `app/lib/src/features/window/remembered_window_controller.dart` -- sealed `NativeWindowPlan` (key, title, constraints, chrome, frame, level; `runnerArguments({required int window})` = `restoreArguments` of its fields), `ProjectWindowPlan` (size; main/full/normal), `DialogWindowPlan` (size?, resizable, frame, level; secondary); `RememberedWindowController.create(ProjectWindowPlan plan, {delegate})` builds from the plan and restores with `plan.runnerArguments` -- item 2.
- `app/lib/src/features/window/remembered_dialog_window_controller.dart` -- `create(DialogWindowPlan plan, {required delegate})` likewise -- item 2.
- `app/lib/src/features/window/app_windows.dart` -- `planNativeWindow(AppWindowRequest)` (pure: project → `ProjectWindowPlan(size: request.size ?? defaultWindowSize, constraints: request.constraints)`, dialog → `DialogWindowPlan` from the spec); `createRememberedWindow` switches on it; docs say the plan is the tested part -- item 2.
- `app/test/features/window/app_windows_test.dart` -- one test opening main, Projects, a content-sized and a floating dialog over the fake factory and pinning `planNativeWindow` of each request (type, size, constraints, resizable, `runnerArguments`) -- the matrix's request rows.
- `app/test/features/bootstrap/boot_window_host_test.dart` (new) -- `ZanshinWindowHost` over `AppWindows(createController: FakeWindowFactory)`: `openProjects` as the first window (request key/title/spec identical to `projectsWindowSpec`, its plan, content found after a pump), then `openMain` registers beside it; controllers destroyed in teardown -- the boot row.
- `app/lib/src/features/bootstrap/boot_window_host.dart` -- class doc: the requests and both presentation paths are tested over a fake factory; the splash and the native controllers need the engine -- item 2.

**Acceptance Criteria:**
- Given the Projects content at a measured traffic-light block whose centre is y 27, when it lays out, then its title and every header control centre on y 27, as `ZsWindowScaffold`'s do.
- Given every window kind's request, when `planNativeWindow` maps it, then the plan names the controller kind, the size, constraints and resizability the controller is built with, and the exact `restore` map the runner gets.
- Given the running catalogue, when `projects/projects-window/tree` is opened in night and paper and Windows › Projects window is opened, then the Projects window looks as before (header, rings' line, hairlines, fill, sidebar) and the DEBUG `zanshin.window projects` line shows Titled | Closable | Resizable | FullSizeContentView, restorable false, level 0 (Claude's check, compared with the DS window card).
- Given the change, when `cargo make test` runs unpiped from the repo root, then it exits 0 with `coverage-baseline.txt` unchanged.

## Spec Change Log

## Review Triage Log

### 2026-10-19 — Review pass
- verdicts: 29 findings — high 0, medium 2, low 19, false 8, maybe-false 0
- findings:
  - `[low]` `[patch]` (blind 1) The plan test opened the project window with the defaults, so a `planNativeWindow` that ignored the request's size and constraints would pass — patched: the test opens `main` at 1000 × 700 within min 900 × 600 and the project plan must carry both.
  - `[low]` `[reject]` (blind 2) `request.size ?? defaultWindowSize` in `planNativeWindow` cannot run (`AppWindows.create` always passes a project window's size) — the fallback moved verbatim from the old `createRememberedWindow`; `AppWindowRequest.size` is nullable for content-sized dialogs, and swapping the fallback for `!` trades it for a throw on a path nothing takes.
  - `[low]` `[patch]` (blind 3) `ProjectWindowPlan`'s doc says "resizable" but the value was hard-coded in `RememberedWindowController._`, outside the tested plan — patched: `resizable` is a `NativeWindowPlan` field (`true` for a project window), the controller is built from `plan.resizable`, and the plan test pins it.
  - `[low]` `[patch]` (blind 4) Nothing holds that `createRememberedWindow` stays `AppWindows`' default factory, the only production path to the plan — patched: the plan test asserts `AppWindows().createController` is `createRememberedWindow`.
  - `[low]` `[reject]` (blind 5) `FakeWindowFactory` maps requests itself instead of through `planNativeWindow` — it agrees with the plan today (`AppWindows.create` sets a dialog request's constraints from its spec), its mapping shapes only test doubles, and no assertion depends on it any more (blind 6); routing it through the plan rewrites the shared helper for no production effect.
  - `[low]` `[patch]` (blind 6) The host test asserted controller types the fake decides and repeated the Projects plan checks `app_windows_test.dart` makes — patched: those assertions are gone; the host's part is the request (key, title, `same(projectsWindowSpec)`), the presentation and the registry.
  - `[low]` `[patch]` (blind 7) The host test never checked the `IconRegistryScope` wiring `_present` puts above every window (`icons` stayed null) — patched: it asserts no registry before one arrives, then sets `icons.value` and finds the same registry from both windows' content.
  - `[medium]` `[patch]` (blind 8) Nothing pins the new three-group focus order end to end — same root cause as verification-gap 1; patched there.
  - `[low]` `[reject]` (blind 9) No Projects test covers the drag areas, whose header extent changed — Projects' drag areas were never tested before this change; they are now the scaffold's, whose header drag (empty space and title drag, a control keeps its press) is pinned in `zs_window_scaffold_test.dart`; the wider extent is the DS behaviour (Design Notes); a Projects-level hit-test harness adds a test for the scaffold's behaviour twice.
  - `[false]` `[reject]` (blind 10) The measured-block test's header finder could silently pick another hairline via `.first` — a wrong match fails the `Rect.fromLTWH(200, 0, 700, 52)` assertion loudly (the sidebar comes first in tree order); the finder mirrors `zs_window_scaffold_test.dart`'s `_header`.
  - `[low]` `[reject]` (blind 11) "Projects" is written in the content and in `projectsWindowTitle` — pre-existing (the old `_header` had the same literal); the content is window-agnostic by design (Story 11.6) and does not read the window's spec.
  - `[false]` `[reject]` (blind 12) The offer sheet now sits outside the window fill, so the content might not stay blocked — the sheet is still the later sibling in one container (the outer `Semantics(container: true)`), so `ZsSheet`'s `BlockSemantics` (zs_sheet.dart:221) drops the fill's node as it dropped the content before; the sheet brings its own `ZsSurface` (text colour) and scrim `MouseRegion`, and the fill's cursor region defers to its children.
  - `[low]` `[defer]` (blind 13) The work that stays untested has no ledger entry while the item closes — grouped with verification-gap 2; deferred there.
  - `[low]` `[patch]` (blind 14) The "what stays untested" sentence was in both the `NativeWindowPlan` and the `createRememberedWindow` docs — patched: it stays on `createRememberedWindow`; the plan's doc points there.
  - `[false]` `[reject]` (blind 15) The plan types lack `@immutable` and `WindowChromeKind` is not exported — the plans are `sealed`/`final` classes with final fields that nothing outside the library can subclass, so the annotation would check nothing; the chrome reaches tests and the runner through `runnerArguments`, which the tests pin.
  - `[low]` `[patch]` (blind 16) `RememberedWindowController.create` kept an optional delegate with a `WindowControllerDelegate()` fallback — patched: the delegate is required, as the dialog controller's is, so a dropped delegate no longer compiles.
  - `[low]` `[patch]` (edge 1) A dropped delegate would never unregister the window, breaking the exit rule, with every test green — same root cause as blind 16; patched there (the dispatch itself is type-safe: each arm's `create` takes its own plan type).
  - `[low]` `[patch]` (edge 2) The project plan does not name its resizability — same root cause as blind 3; patched there.
  - `[medium]` `[patch]` (verification-gap 1) The three-group Tab order (header 1, body 2, sidebar 3) is unchecked: the only Tab test pumps without callbacks, so the sidebar has no Tab stop and swapped orders pass — patched: "Tab runs through the header, then the tree, then the sidebar" (callbacks on) Tabs from New group into the tree's first row and out of it onto Settings…; with orders 2 and 3 swapped it fails, restored.
  - `[low]` `[defer]` (verification-gap 2) The controllers' `create(plan)` glue is only checked by hand — needs the engine (the controllers cast the owner to `WindowingOwnerMacOS` and call FFI); deferred (frontmatter, mirrored in deferred-work.md); this run's catalogue checked it live (Verification).
  - `[false]` `[reject]` (intent 1) Item 1's change re-hosts the whole window frame, beyond "only as far as an item needs" — the intent's item 1 names this as its follow-up ("move the Projects content onto `ZsWindowScaffold` (its sidebar form) when it is next touched"); the restructured lines are Story 11.6's, and the item needs them.
  - `[false]` `[reject]` (intent 2) The full-screen path (`tlMidY` 34) now shifts the Projects header, untested — the Projects window is a dialog (FullScreenAuxiliary, never full screen); a catalogue panel inside a full-screen catalogue window takes the scaffold's designed full-screen line, as every scaffold use case does.
  - `[false]` `[reject]` (intent 3) The title style and the drag extent are not pinned — the styles are value-identical (`ZsType.cardSubject`, sans 13, even leading, letter-spacing 0, with 600/1.2 = the scaffold's `_titleStyle`), and the visual check compared the title; the drag extent is blind 9.
  - `[low]` `[defer]` (intent 4) `createRememberedWindow` and the controllers' `create` still run in no test, so "fixed" fits the ledger's first follow-up, not a literal reading — grouped with verification-gap 2; deferred there.
  - `[low]` `[patch]` (intent 5) `ProjectWindowPlan`'s doc says resizable without a field — same root cause as blind 3; patched there.
  - `[low]` `[patch]` (intent 6) The host test's plan checks are computed by the test and repeat `app_windows_test.dart`; the fake is a third mapping — same root cause as blind 6; patched there.
  - `[low]` `[patch]` (intent 7) The host doc says the native controllers are "covered by the runtime smoke check", which names no artifact — patched: it names the check, a running app's DEBUG `zanshin.window` restore lines and the CGWindowList probe.
  - `[false]` `[reject]` (intent 8) Both controllers' `create` signatures change and `app_windows.dart` exports the plan types — the spec's tasks ask for `create` to take the plan; `planNativeWindow` returns the plan types, so its callers need them; `createRememberedWindow` is the only caller of `create`.
  - `[false]` `[reject]` (intent 9) No Auto Run Result, untracked spec — a mid-run state; finalize writes the result and commits the spec.

## Design Notes

**Why the scaffold, not a copied shift.** Three lines of `(tlMidY − hd/2)·2` padding in `_header` would fix item 1 too, but would keep the second copy of the header (padding, hairline, title style, drag area) that drifted here; `ZsWindowScaffold` was built as the DS Window scaffold for Settings, Projects and Configurations, and its doc already names Projects' sidebar form. Moving onto it is the ledger's own follow-up and leaves one header implementation. Visible differences at the reference block: none intended — the title style is the same (sans 600 13/1.2), and the drag area now also covers the 12 pt gaps between the header controls (the DS: "the header's empty space drags the window").

**Plan shape** (Claude's proposal):

```dart
sealed class NativeWindowPlan { key; title; constraints; chrome; frame; level;
  Map<String, Object> runnerArguments({required int window}) => restoreArguments(...); }
final class ProjectWindowPlan extends NativeWindowPlan { Size size; }        // main, full, normal
final class DialogWindowPlan extends NativeWindowPlan { Size? size; bool resizable; } // secondary
NativeWindowPlan planNativeWindow(AppWindowRequest request);                 // app_windows.dart
```

What stays untested is the controllers' constructor call with the plan's values and the channel call with `runnerArguments` — glue the run's DEBUG `zanshin.window` lines check live.

## Verification

**Commands:**
- `dart analyze --fatal-infos --fatal-warnings` and `dart format --output=none --set-exit-if-changed .` in `app/` -- expected: clean.
- `flutter test test/features/projects/projects_window_test.dart test/features/window test/features/bootstrap` in `app/` -- expected: all pass.
- `cargo make test` (repo root, unpiped; `PATH` with `~/development/sdks/flutter/bin` and `~/development/sdks/cargo/bin`, `CARGO_HOME=~/development/sdks/cargo`, `RUSTUP_HOME` unset) -- expected: exit 0, `coverage-baseline.txt` unchanged.

**Manual checks (if no CLI):**
- Claude's check: run the catalogue (`flutter run -d macos -t widgetbook/main.dart` in `app/`), connect Marionette, open `projects/projects-window/tree` in night and paper and Windows › Projects window; screenshot; read the DEBUG `zanshin.window` lines from the run log; compare with the DS window card (`design-system-preview`, Playwright `scale: "device"`). Record what was and was not seen in the Auto Run Result.

## Auto Run Result

Status: done (2026-10-19). Blocking condition: none. Code commits: 630f3f5f73688cc11dc35a397ef31cfe87e3098e (item 1), 076c75ee794ecdf574d1ed918f36f93779479618 (item 2).

**Items handed to this closing run.**
1. **Projects' header centres on the row's middle, not on `--tl-mid-y` — fixed** (commit `630f3f5f73688cc11dc35a397ef31cfe87e3098e`).
   - Verified first: `ProjectsWindowState._header` laid its `Row` into the 52 pt `SizedBox` with no shift, while `ZsWindowScaffold._header` shifts by `(tlMidY − windowHdH/2)·2` (window.css:29); `ZsMetrics` takes a measured block's centre as `tlMidY`, so any block other than macOS 27's reference put Projects off the buttons' line.
   - As the ledger's follow-up proposes: the Projects content lays itself out on `ZsWindowScaffold`'s sidebar form (title, header controls, sidebar, body), so the header, its hairline, the sidebar's hairline and empty top, the fill and the drag areas are the scaffold's. Witness: at a block centred on y 27 the title, search, Add directory, Clone… and New group centre on 27 (at the reference, 26 as before). Only Story 11.6's layout code (`build`, `_sidebar`, `_main`, `_header`) changed.
2. **The engine-bound window creation paths run in no test — fixed by the ledger's seam** (commit `076c75ee794ecdf574d1ed918f36f93779479618`).
   - Verified first: `createRememberedWindow` mapped a request onto the two `*MacOS` controllers (chrome kind hard-coded in each `create`), the host's `openProjects` ran in no test, and only `restoreArguments` was pinned.
   - `planNativeWindow(AppWindowRequest)` is now a pure function returning a sealed `NativeWindowPlan` (`ProjectWindowPlan` / `DialogWindowPlan`: size, constraints, resizability, title, and the runner's chrome, frame and level); the controllers only carry the plan out. Tests pin every window kind's plan (project, Projects, content-sized, floating) and that `createRememberedWindow` is the default factory, and `ZanshinWindowHost.openProjects` runs over a fake factory (its request, `runWidget`, the registry, the icon registry). What still needs the engine — the constructor call with the plan's values and the channel call — is a new low deferral (mirrored), checked live in this run.

**Summary.** Projects now sits on the one DS window scaffold and follows the measured traffic-light line; the native window creation is decided by a tested pure plan, so a wrong size, constraint, resizability, chrome, frame or level fails a test instead of showing only in a running app.

**Files changed:**
- `app/lib/src/features/projects/projects_window.dart` — content on `ZsWindowScaffold` (header controls, body, sidebar column; focus orders 1, 2, 3); class doc.
- `app/lib/src/features/window/remembered_window_controller.dart` — `NativeWindowPlan`, `ProjectWindowPlan`, `DialogWindowPlan` (`runnerArguments`); `RememberedWindowController.create(plan, delegate:)` with a required delegate, resizability from the plan.
- `app/lib/src/features/window/remembered_dialog_window_controller.dart` — `create(plan, delegate:)`.
- `app/lib/src/features/window/app_windows.dart` — `planNativeWindow`; `createRememberedWindow` switches on it; exports the plan types.
- `app/lib/src/features/bootstrap/boot_window_host.dart` — class doc: what is tested, what the live check is.
- `app/test/features/projects/projects_window_test.dart` — the header on the block line (26 and 27); Tab header → tree → Settings….
- `app/test/features/window/app_windows_test.dart` — the plan of every window kind and the default factory.
- `app/test/features/bootstrap/boot_window_host_test.dart` (new) — the host over a fake factory.
- Tracking: this spec; `deferred-work.md` ("Surfaced in the closing run of Story 11.12": 1 item).

**Review findings.** 29 findings (high 0, medium 2, low 19, false 8).
- **Patched, 9 entries (1 medium, 8 low):** the three-group Tab order is pinned with the sidebar's Settings… as a Tab stop (verification-gap 1 + blind 8; swapping orders 2 and 3 fails it); the project plan test uses a non-default size and constraints (blind 1); resizability is a plan field for both kinds (blind 3 + edge 2 + intent 5); the default factory is asserted (blind 4); the host test drops fake-decided controller types and duplicate plan checks (blind 6 + intent 6) and checks the icon registry above both windows (blind 7); one copy of the "what stays untested" doc sentence (blind 14); the project controller's delegate is required (blind 16 + edge 1); the host doc names the live check (intent 7). The implementation subagent was not re-engaged (a resumed agent reports asynchronously, which this unattended run cannot wait for); the parent applied the patches.
- **Deferred (new, mirrored in deferred-work.md):** the controllers' `create(plan)` glue runs in no test (verification-gap 2 + blind 13 + intent 4; low; needs the engine).
- **Rejected, low:** the dead `?? defaultWindowSize` fallback (blind 2), the fake's own mapping (blind 5), no Projects-level drag-area test (blind 9), the "Projects" literal in two places (blind 11, pre-existing) — reasons in the triage log.
- **False, 8:** the header finder (blind 10), the sheet outside the fill (blind 12), `@immutable` and the chrome export (blind 15), the scope of item 1 (intent 1), full screen (intent 2), title style and drag extent (intent 3), the signature and export changes (intent 8), the mid-run state (intent 9).

**Follow-up review recommendation:** false — this first pass patched 1 medium and 8 low entries, no high.

**Verification:**
- Implementation run: `dart analyze --fatal-infos --fatal-warnings` and `dart format` clean in `app/`; targeted `flutter test` 121 passed; `cargo make test` (unpiped, `CARGO_HOME=~/development/sdks/cargo`) exit 0 — 3 app steps (flutter test 728, analyze, format), no coverage step (no Rust or `zanshin_core` change).
- After the review patches: analyze and format clean; targeted `flutter test` 122 passed (incl. "Tab runs through the header, then the tree, then the sidebar", "planNativeWindow names each request's controller…", "Projects first: …"); `cargo make test` exit 0 — app flutter test 729, analyze, format; `coverage-baseline.txt` unchanged.
- Deliberate break: body and sidebar orders swapped (2 ↔ 3) failed the new Tab test; restored.
- Matrix audit: reference and measured block (`projects_window_test.dart` layout group), the four request kinds (`app_windows_test.dart` plan test), boot Projects first (`boot_window_host_test.dart`) — each ran and passed.
- Visual (implementation run; catalogue, Marionette 0.7, DS `components/window/window.card.html` via Playwright `scale: "device"`): `projects/projects-window/tree` in night, paper and night-inactive — header 52 with its hairline, title at sidebar + 12, controls on one line, the sidebar's hairline and empty top, the fill; the title dims while inactive; Windows › Projects window renders the same in a real dialog window.
- Native (after the patches, catalogue run log): `zanshin.window widgetbook: styleMask titled|closable|miniaturizable|resizable|fullSizeContentView … restorable false level 0` (project kind) and `zanshin.window widgetbook-projects-window: styleMask titled|closable|resizable|fullSizeContentView collection fullScreenAuxiliary restorable false level 0` (Projects' spec); a screenshot of that dialog window matched the panel.
- Not seen: a non-reference traffic-light block on screen (this Mac's block is the reference; the widget test is the witness); the native traffic lights against the header (Flutter layer only, no CGWindowList probe this run); the app's own `zanshin.window projects` line (the catalogue's key was used); the red button and the Dock (Story 11.12's deferral 3, unchanged).

**Residual risks:**
- The controllers' constructor and channel glue is checked only live (deferred).
- `boot_window_host_test.dart` is the first test to run `runWidget` with a `WindowManager` under `flutter_test`; a Flutter `main` change to the test windowing owner could break it.
