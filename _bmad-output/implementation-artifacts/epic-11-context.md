# Epic 11 Context: Floating app shell (Flutter UI)

<!-- Generated from planning artifacts. Regenerate with compile-epic-context if planning docs change. -->

## Goal

Build everything around the commit graph that is not the graph itself, so a user launches Zanshin, picks or adds a project and works in one window where the graph fills the space and every control floats above it on glass islands: the design-system foundation and glass material, the `zanshin_ui` package with the Zs controls and the Widgetbook catalogue, the floating overlay host, the native chrome, real windows for Projects, Settings and jj log Configurations, the menu bar, projects and switching, sync (Fetch, Push, the remote-change poll), the Undo Timeline, l10n-readiness, and follow-ups that keep the shell honest to jj. Stories 11.24 and 11.25 change no behaviour: they make the inject.dart graph the app's one composition root with a boot that reads top to bottom. The newest story, 11.26, fixes the chrome geometry so the top bar keeps the same 12 pt to the window edge as every other side, which means moving the native traffic lights for the first time. Claude builds the UI (scope change 2026-10-14); Ralph accompanies and reviews.

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
- Story 11.26: The top bar keeps 12 pt to the window edge, like every other side

## Requirements & Constraints

- **Done** = `cargo make test` green from the repo root, plus a check of the running app or catalogue through Marionette (widget tests alone don't count; UI changes are compared with the DS cards). Native chrome changes also need a native screenshot (the CGWindowList probe), since Marionette screenshots show only the Flutter layer. The coverage ratchet is Rust-only, so each story's named witnesses are the Dart and native safety net; the ratchet credits `zanshin_ffi_version` to the `packages/zanshin_core` test that calls it, so that call stays. The native XCTests (`app/macos/RunnerTests`) run in no gate step: run `xcodebuild test -workspace Runner.xcworkspace -scheme Runner -only-testing:RunnerTests` in `app/macos` by hand when `app/macos/` changes.
- **CLI parity:** repo-side effects behave like the pinned jj (v0.47.0). The UI never composes jj operations; it pre-fills parameters from the effective config and passes them explicitly. A jj command in UI text is real, shown in full with the change id, shell-quoted. jj's own text stays verbatim; Zanshin's explanations hang off kinds the bridge sends over FlatBuffers, never off parsed jj text.
- **Strings** go through ARB (`app/lib/l10n/app_en.arb`, `packages/zanshin_ui/lib/l10n/zs_en.arb`; `flutter gen-l10n` after edits); jj's verbatim words are marked `// l10n-ignore: <reason>`; every window root registers `zanshinLocalizationsDelegates`.
- **Tests:** app tests never call a jj config verb for real; real-cdylib widget tests wrap worker and watcher I/O in `tester.runAsync`.
- Epic 11 surfaces carry their own VoiceOver semantics. No telemetry or analytics.

## Technical Decisions

- **Packages:** `packages/zanshin_ui` holds tokens, materials, DS icons and Zs controls and never depends on `zanshin_core`, `inject_*` or the app. The app imports only `package:zanshin_ui/zanshin_ui.dart` and `package:zanshin_core/zanshin_core.dart`; a `[UI/bridge]` story adds the types it consumes to the core library's `show` list.
- **App layout:** features in `app/lib/src/features/<name>/` (graph, shell, projects, settings, sync, undo_timeline, window); the app's frame (boot, window coordinator, project window content root, menu bar) in `app/lib/src/app/`, next to the DI wiring. Nothing under `features/` imports `app/`, and no two feature folders import each other (guard test in `app/test/architecture/`). Features open windows through `AppWindowActionsScope`. Catalogue in `app/widgetbook/`; tests mirror under `app/test/`.
- **DI:** `MainComponent` is the one composition root (`ZanshinApplication get application`); everything below arrives through constructors — no `attach()`, setters or late wiring. Pre-graph values (settings store, icon registry, worker, `AppWindows`) enter through a module constructor, so every entry point stays synchronous (no `@asynchronous`). Own classes take `@inject`; modules bind interfaces, third-party types and pre-graph values; runtime parameters use assisted injection; per-window view models come from `ViewModelFactory`. Tests use a test component over the production modules plus a test module with fakes.
- **Boot:** settings ‖ login-shell environment ‖ icon decode, then the worker (Rust tracing reads the environment), then the component, the menu, `start()`. Splash shown after 250 ms, for at least 3 s.
- **Windows:** one project window (min 880 × 560; another project switches it in place); Projects (start window; closing it quits) and Settings are parentless dialog windows at normal level; jj log Configurations is its own window (min 820 × 460) floating above the project window. Each window root carries a key.
- **Chrome geometry (11.26 supersedes "native buttons are never moved"):** in the project window the top bar sits 12 pt from the top, as in full screen, and content starts at 68; the traffic lights move down to stay centred on the bar (centre y 34). Today the bar is derived from the lights (`chromeBarY = tlMidY − 22`, `tlMidY` 26 in a window, 34 in full screen; `zs_metrics.dart`, `floating_shell.dart`), and the Swift side only measures the buttons (`WindowChromeHost.swift` in `packages/zanshin_shell_macos`; `app/macos/Runner/MainWindowChrome.swift` places them through an empty `NSToolbar` and a titlebar accessory). The new position must hold through resize, full screen in/out, a theme change and the window becoming key; the measured block is still reported to Dart, and the hover rings (`TrafficLightOverlayView`, grey per-theme `--tl-ring`) follow. Settings and Projects keep their lights at 19/19; full screen is unchanged.
- **Design rules:** the DS (`_bmad-output/implementation-artifacts/design_system/`) is the reference — its tokens and CSS win over its prose and cards, and a decision recorded in the epic wins over the DS. A geometry or token change updates the DS too (here `--tl-mid-y` 34, `--chrome-bar-y` 12, `--chrome-top` 68 and the readme's chrome geometry) with a DESIGN-SYSTEM-SYNC entry; publishing waits for a console session. Own Zs controls on widgets-layer primitives; Material types only from `package:material_ui`; designed visuals are `RenderBox`es with text slots. Selection, focus and flash use the accent role; reduce motion by property.
- **Icons:** SVGs precompiled into a boot-loaded `IconRegistry`, provided per window root through `IconRegistryScope`; `ZanshinIcon` has no Material fallback; widget tests load the registry in a shared `setUpAll` (`tester.runAsync`).
- **Tooling:** Widgetbook 3.25.0 (pinned exactly); `marionette_flutter` ^0.7.0 with one shared `MarionetteConfiguration`, matching by Semantics identifier or text, never coordinates.

## UX & Interaction Patterns

- The graph fills the window; controls float on glass islands (top bar Place · View · Action, rail with hover previews and pins, pinned panels), each 12 pt from the window edge on every side.
- ⌘W on the project window closes the project and shows Projects. Closing the project or quitting first brings unsaved jj log Configurations forward and asks "Discard changes?"; Cancel aborts.
- Two sheets only (ConfirmDialog, Push): a click beside one does nothing; Esc and Cancel cancel. No hover is painted in a non-key window.
- Menu bar in Title Case; the Change menu targets the selection, else @, and names it ("Abandon @"); Go, Change and project commands reach the project window from any Zanshin window; rows showing ⌘, open Settings on the tab shown last.
- Undo in three places (toast, ⌘Z for Zanshin's own latest operation while it is current, Undo Timeline); every undo ends in the toast "Undid ‹action› · Redo".

## Cross-Story Dependencies

- 11.26 is the only open Epic 11 story in the sprint status. It depends on 11.4 (window chrome) and 11.12 (chrome kinds, per-window frames), both done, and relates to 11.20 (density and zoom). Its witnesses: a window screenshot shows 12 pt from the top edge to the bar, the same as to the rail, the inspector and the bottom, with the lights centred on the bar; resize, full screen and a theme switch keep them in place; the drag region and window buttons still work.
- Epic 10 keeps everything graph-semantic (View capsule contents, search, Configurations content, Bookmarks panel, @ pill, inspector, minimap, toast) and plugs into 11.3's slots and 10.5's contract; the graph's top inset follows the chrome geometry. Backend verbs come from Epic 9.
