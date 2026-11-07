# Epic 11 Context: Floating app shell (Flutter UI)

<!-- Generated from planning artifacts. Regenerate with compile-epic-context if planning docs change. -->

## Goal

Build everything around the commit graph that is not the graph itself, so a user launches Zanshin, picks or adds a project and works in one window where the graph fills the space and every control floats above it on glass islands: the design-system foundation and glass material, the `zanshin_ui` package with the Zs controls and the Widgetbook catalogue, the floating overlay host, the native chrome, real windows for Projects, Settings and jj log Configurations, the menu bar, projects and switching, sync (Fetch, Push, the remote-change poll), the Undo Timeline, l10n-readiness, and follow-ups that keep the shell honest to jj. The last two stories (11.24, 11.25, from the 2026-11-07 Dart architecture review) change no behaviour: they make the inject.dart graph the app's one composition root — every symbol in its layer, no import cycles between the app's folders, one component entry point, a boot that reads top to bottom — so the app is wired through constructors instead of by hand in `main.dart`. Claude builds the UI (scope change 2026-10-14); Ralph accompanies and reviews.

## Stories

- Story 11.0: Record the scope change in the canonical rules
- Story 11.1: Design-system foundation — tokens, type, metrics, motion, theme, fonts, icons, DS parity test
- Story 11.2: Glass material primitives
- Story 11.3: Floating overlay host — top bar, rail, pinned panels, insets, calm scrolling
- Story 11.4: Window chrome for the floating layout
- Story 11.5: Projects — registry, project capsule, Project menu, switching
- Story 11.6: Projects dialog on real data (now the Projects window)
- Story 11.7: Settings window — General and Project tabs
- Story 11.8: Sync — Fetch, Push, the remote-change poll, the upstream badge
- Story 11.9: Undo Timeline panel
- Story 11.10: Retire the docked mock UI
- Story 11.11: Zs control library, Widgetbook catalogue, shared Marionette configuration
- Story 11.12: Window foundation — dialog windows, chrome kinds, frames, per-window roots
- Story 11.13: Menu bar and shortcuts
- Story 11.14: The `zanshin_ui` package
- Story 11.15: Projects window — deselect, group naming and menu, New group…, drag ghost
- Story 11.16: l10n-ready — strings into ARB files (English only)
- Story 11.17: Menu bar state — checkmarks and greyed window items via a native channel
- Story 11.18: Remote management in Settings — add, rename, remove, set URL
- Story 11.19: Edit the config file — the GUI split of `jj config edit`
- Story 11.20: Density with an effect — spacing tokens per density (plus Zoom)
- Story 11.21: Immutable commits page — untracked remote refs by tracking state
- Story 11.22: Push help for Git switchers — fix-it actions, plain explanations, post-conversion tracking hint
- Story 11.23: jj 0.47 follow-ups
- Story 11.24: Dart architecture, part 1 — dead DI out, every symbol in its layer, no import cycles between the app's folders
- Story 11.25: Dart architecture, part 2 — one composition root, a linear boot

## Requirements & Constraints

- **11.24/11.25 are pure restructuring:** no change of behaviour, visuals or splash timings, and no faster boot. 11.24 moves code without renaming or rewriting it beyond paths, imports and the parameters it names.
- **Done** = `cargo make test` green from the repo root, plus a check of the running app or catalogue through Marionette (widget tests alone don't count; UI changes are compared with the DS cards). The coverage ratchet is Rust-only, so each story's named witnesses are the Dart safety net; the ratchet credits `zanshin_ffi_version` to the `packages/zanshin_core` test that calls it, so that call stays when its wrapper becomes a top-level function.
- **CLI parity:** repo-side effects behave like the pinned jj (v0.47.0). The UI never composes jj operations; it pre-fills parameters from the effective config and passes them explicitly. A jj command in UI text is real, shown in full with the change id, shell-quoted. jj's own text stays verbatim; Zanshin's explanations hang off kinds the bridge sends over FlatBuffers, never off parsed jj text.
- **Strings** go through ARB (`app/lib/l10n/app_en.arb`, `packages/zanshin_ui/lib/l10n/zs_en.arb`; `flutter gen-l10n` after edits); jj's verbatim words are marked `// l10n-ignore: <reason>`; every window root registers `zanshinLocalizationsDelegates`.
- **Tests:** app tests never call a jj config verb for real; real-cdylib widget tests wrap worker and watcher I/O in `tester.runAsync`.
- Epic 11 surfaces carry their own VoiceOver semantics. No telemetry or analytics.

## Technical Decisions

- **Packages:** `packages/zanshin_ui` holds tokens, materials, DS icons and Zs controls and never depends on `zanshin_core`, `inject_*` or the app (its DI modules stay in the app). The app imports only `package:zanshin_ui/zanshin_ui.dart` and `package:zanshin_core/zanshin_core.dart`; a `[UI/bridge]` story adds the types it consumes to the core library's `show` list.
- **App layout (11.24):** features in `app/lib/src/features/<name>/` (graph, shell, projects, settings, sync, undo_timeline, window); the app's frame in `app/lib/src/app/`, next to the DI wiring — the boot (`boot/`), the window coordinator, the project window's content root, the menu bar (`menu/`). `features/window/` keeps the window infrastructure the features use (registry, specs, keys, roots, tracker, zoom). Nothing under `lib/src/features/` imports `lib/src/app/`, and no two feature folders import each other; a guard test in `app/test/architecture/` reads the imports and fails on either. Shared symbols sit with their owner: the active-graph binding, the undo-timeline actions and jj's built-in immutable heads in `features/graph/`; the jj docs URL and the browser opener in `lib/src/links.dart`. Features open windows through `AppWindowActionsScope`; Edit › Find reaches the Projects search through an injected `ProjectsSearchFocus`, not a `GlobalKey`. Catalogue in `app/widgetbook/`; tests mirror under `app/test/`.
- **DI by the book (11.25):** `MainComponent` (name kept) is the one composition root with one getter, `ZanshinApplication get application`; everything below arrives through constructors — no `attach()`, setters, `late` self-references or mutable function fields wired after construction. Values needed before the graph (settings store, icon registry, worker, `AppWindows`) are resolved first and enter through a module's constructor, so every entry point stays synchronous: no `@asynchronous` provider, `Completer` or `Future<ZanshinWorker>` passed through classes. One `BootModule(boot, windows)` is recommended over a module per package (design question (a): Ralph decides before the build, else the recommendation is built). Own classes take `@inject` (`@singleton` when shared); modules bind interfaces (each on its own, so a test module can replace it), third-party types, pre-graph values and the window coordinator, whose builder-closure constructor stays. Widgets with runtime parameters use assisted injection (test seams stay optional `@assisted` parameters); per-window view models come from `ViewModelFactory`. App-wide side effects (theme mirroring onto the native chrome, the quit handler) are app-level singletons, not per-window view models or provision listeners. The per-repository project scope stays built by the project hosts, and `GraphViewModel` stays hand-built.
- **Boot (11.25):** `main.dart` sets up binding, logging and zone, creates the windows and the host, then runs one boot function: load the boot values (settings ‖ login-shell environment ‖ icon decode; then the worker, which must start after the environment because Rust tracing reads the log filter, log directory and `HOME` from it) → create the component → hand the menu to the host → `start()` (zoom binding before the first window, exit handler, appearance sync, coordinator). The splash race stays: shown after 250 ms, for at least 3 s; the first window through `runWidget`; the fade; `onShown` after the first window. The failure page uses the persisted theme; neither it nor the splash uses icons. Quit: ⌘Q → close guards → worker close.
- **Tests through the graph:** a test component over the production modules plus a test module with fakes (skill `inject_annotation-write-tests`); no hand-written implementations of generated factories or `Provider<T>`. If an overridden provider still needs a worker, the test module starts a real one.
- **Windows:** one project window (another project switches it in place; min 880 × 560); Projects (the start window; closing it quits) and Settings are parentless dialog windows at normal level; jj log Configurations is its own window (min 820 × 460) floating above the project window. Each window root carries a key. Native traffic lights never move.
- **Design rules:** the DS (`_bmad-output/implementation-artifacts/design_system/`) is the reference — its tokens and CSS win over its prose and cards, and a decision recorded in the epic wins over the DS. Own Zs controls on widgets-layer primitives (text entry an undecorated `TextField`); Material types only from `package:material_ui` (its `ThemeMode` ≠ Flutter's); designed visuals are `RenderBox`es with text slots. Selection, focus and flash use the accent role (moon only under Multicolor); reduce motion by property.
- **Icons:** SVGs precompiled by `vector_graphics_compiler` into a boot-loaded `IconRegistry` (from 11.25 injected into each `ZanshinWindowRoot`, which provides `IconRegistryScope`); `ZanshinIcon` has no Material fallback; widget tests load the registry in a shared `setUpAll` (`tester.runAsync`).
- **Tooling:** Widgetbook 3.25.0 (pinned exactly) is the review catalogue; `marionette_flutter` ^0.7.0 with one shared `MarionetteConfiguration`, matching by Semantics identifier or text, never coordinates.

## UX & Interaction Patterns

- The graph fills the window; controls float on glass islands (top bar Place · View · Action, rail with hover previews and pins, pinned panels).
- ⌘W on the project window closes the project and shows Projects. Closing the project (⌘W, a switch) or quitting first brings unsaved jj log Configurations forward and asks "Discard changes?"; Cancel aborts.
- Two sheets only (ConfirmDialog, Push): a click beside one does nothing; Esc and Cancel cancel. No hover is painted in a non-key window.
- Menu bar in Title Case; the Change menu targets the selection, else @, and names it ("Abandon @"); Go, Change and project commands reach the project window from any Zanshin window; rows showing ⌘, open Settings on the tab shown last.
- Undo in three places (toast, ⌘Z for Zanshin's own latest operation while it is current, Undo Timeline); every undo ends in the toast "Undid ‹action› · Redo".

## Cross-Story Dependencies

- 11.24 follows 11.12 and 11.13 (both done) and blocks 11.25, which depends on it. Neither waits for another open story: a story landing in between wires the old way, and 11.24/11.25 take it along.
- 11.24/11.25 touch Epic 10 only at its edges: the project graph host publishes the active graph that the menu, Settings and the jj log Configurations window (10.22) read; the Undo Timeline (11.9) consumes actions the graph view model implements; the immutable reasons and Settings' Immutable commits page (11.7) share jj's built-in heads from the graph feature; the zoom binding (11.20) moves into `start()`.
- Epic 10 keeps everything graph-semantic (View capsule contents, search, Configurations content, Bookmarks panel, @ pill, inspector, minimap, toast) and plugs into 11.3's slots and 10.5's contract; backend verbs come from Epic 9.
