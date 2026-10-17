# Epic 11 Context: Floating app shell (Flutter UI)

<!-- Generated from planning artifacts. Regenerate with compile-epic-context if planning docs change. -->

## Goal

Build the macOS app around the commit graph. The graph fills the one project window, and every control floats above it on glass islands. The epic builds the design-system foundation and the glass materials, moves them into their own `zanshin_ui` package, then builds Zanshin's own control library there with its review catalogue, the overlay host, the native chrome, projects, the Settings and Projects windows, the menu bar, sync, the Undo Timeline, and the retirement of the old docked mock UI. Claude builds it and Ralph reviews every story. Epic 10 keeps everything graph-semantic and plugs it into this epic's slots.

## Stories

- Story 11.0: Record the scope change in the canonical rules (done)
- Story 11.1: Design-system foundation (tokens, type, motion, accent, icons, DS parity test) (done)
- Story 11.2: Glass material primitives (done)
- Story 11.3: Floating overlay host
- Story 11.4: Window chrome for the floating layout
- Story 11.5: Projects (registry, capsule, Project menu, switching)
- Story 11.6: Projects window on real data
- Story 11.7: Settings window
- Story 11.8: Sync (Fetch, Push, remote-change poll, badge)
- Story 11.9: Undo Timeline panel
- Story 11.10: Retire the docked mock UI
- Story 11.11: Zs control library, Widgetbook catalogue, Marionette configuration
- Story 11.12: Window foundation
- Story 11.13: Menu bar and shortcuts
- Story 11.14: The `zanshin_ui` package (tokens, materials and DS icons leave `app/`) (done)

## Requirements & Constraints

- **Design input.** The reference is the DS in `_bmad-output/implementation-artifacts/design_system/` (downloaded 2026-10-16, "synced through #9").
  - Precedence: decisions recorded in epics.md win over the DS. Within the DS, tokens and CSS win over its prose and cards. The DS wins over the floating client (`design/`).
  - The design is inspiration. A small gap gets a marked "Claude's proposal". A NEEDS DESIGN question is answered before the story is built, never guessed.
  - Never edit `design/` or `design_system/`.
- **Done** means `cargo make test` passes. Dart lines are not measured by the coverage ratchet, so the witnesses each story names are the safety net. There are no golden tests, and app tests use fake ports.
- **Moves are moves.** 11.14 relocates code without changing behaviour, public names, doc comments or visuals; only import, asset and font paths change, and doc comments that name a moved location follow it.
- **CLI parity.**
  - The UI never composes jj operations. It pre-fills parameters from the effective config and passes them explicitly.
  - Every jj command shown in the UI is real in v0.46.0 and is shown in full, shell-quoted, with the change id.
  - Refusals and hints are shown verbatim from the backend.
  - The word is "bookmark", never "branch". "Stale" refers only to the working copy.
- **Accessibility.** Every surface has VoiceOver semantics (macOS reads semantics flags) and a keyboard path. Focus rings show only for keyboard focus.
- **System settings apply live; the app offers no in-app switch for them.**
  - Reduce motion works by property: movement, size, rotation and stroke drawing go to 0, while fades keep their durations and the spinner keeps turning.
  - Under reduce transparency or increased contrast, glass paints solid.
  - In an inactive window, no hover or focus ring is painted and the accent goes neutral, except its live copies: progress, the flash, drop targets and links.
- **Undo** lives in three places: ⌘Z (only Zanshin's own latest operation, while it is still current), the toast, and the Undo Timeline. Every undo ends in the toast "Undid ‹action› · Redo".
- **A stale working copy** is a project-level state without Retry. Fetch, Push, the Change items and the op log are disabled with the reason "Working copy is stale".

## Technical Decisions

- **Code locations.**
  - `packages/zanshin_ui` (a Flutter package in the pub workspace): tokens in `lib/src/design/`, materials in `lib/src/materials/`, DS icons in `lib/src/icons/`, Zs controls in `lib/src/controls/`; tests in `packages/zanshin_ui/test/`, mirroring `lib/src/` (11.14 moved the tokens and materials out of `app/lib/src/shared/`).
  - The app imports only `package:zanshin_ui/zanshin_ui.dart`, never `src/`. The export list grows with what the app consumes.
  - The package depends directly only on `flutter`, `material_ui`, `vector_graphics`, `zanshin_settings` and `zanshin_shell` — never on `zanshin_core`, `inject_*`, `marionette_flutter` or the app (`inject_annotation` still arrives transitively through `zanshin_settings`).
  - Under `app/lib/src/features/`: `shell/` (the host and the menu bar), `projects/`, `settings/`, `sync/`, `undo_timeline/`, `window/` (`AppWindows`). Tests mirror them under `app/test/`.
  - The Widgetbook catalogue stays in the app (`app/widgetbook/main.dart`), because its Windows and Graph folders need the app's windows and features. The shared Marionette configuration lives in the app too.
  - The gate is change-aware (`cargo xtask gate-plan`); a test that reads a file outside its own package needs that path in the gate-plan rules.
- **Bridge.** The app imports only `package:zanshin_core/zanshin_core.dart`, and each `[UI/bridge]` story adds the types it uses to its `show` list. Repository handles stay on the worker isolate.
- **No Material or Yaru look.** The Zs controls sit on Flutter's widgets-layer primitives, with one shared state core. Text entry is an undecorated `TextField`.
  - The remaining Material types (`MaterialApp`, `ThemeData`) come only from `package:material_ui`, whose `ThemeMode` is not Flutter's.
  - Designed visuals are a `RenderBox` with text slots, not `Column`/`Row` trees.
  - Yaru, `flutter_svg` and the icon font leave by 11.10.
- **Tokens.**
  - `Zs*` `ThemeExtension`s span theme (night or paper; `light` is an alias of paper) × accent family. Contrast, inactive, transparency and motion are deltas on top.
  - `of(context)` falls back to night and never force-unwraps.
  - Values are fixed hex or rgba.
  - A DS parity test in the gate checks the tokens and the icons.
- **The accent role** (`--accent*`, `--focus-ring`) marks selection, focus, controls and menu highlights.
  - It follows the macOS accent, unless Settings says "Zanshin"; it is moon only under Multicolor.
  - Gold stays with @ and the one primary action, and moon as data stays fixed.
  - A selected data row is `--accent-soft`; navigation is `--fl-on`.
- **Icons and fonts.** The DS SVGs are precompiled with `vector_graphics_compiler`.
  - An `IconRegistry` loads them during the boot sequence. Its inject module (a required constructor parameter) stays in the app beside the boot wiring, so the package needs no DI; the registry is provided above all windows.
  - `ZanshinIcon` is a leaf `RenderBox` with six size tokens.
  - The fonts and SVGs are `zanshin_ui` assets: fonts register as `packages/zanshin_ui/<family>` (the `ZsType` family constants carry that prefix; an app test pins them against the bundle's `FontManifest.json`) and icons load with `packageName: 'zanshin_ui'`.
  - Tests load the registry in `setUpAll` or `tester.runAsync`.
- **`zanshin_shell`** reports reduce motion, reduce transparency, increased contrast, the accent, the key status and the measured traffic-light block. The macOS embedder never reports reduce motion, so the window roots override `MediaQuery.disableAnimations` themselves.
- **Materials.**
  - Glass islands share one `BackdropGroup` per window.
  - Menus, popovers and callouts share one menu material.
  - There are only two sheets, ConfirmDialog and Push. Both are drawn in Flutter, and a click on the scrim does nothing.
  - Separate windows get an opaque fill.
- **Windows.**
  - Settings, Projects and jj log Configurations are parentless dialog windows, one per key, opened through `AppWindows.openOrActivate`.
  - There is one project window; opening another project switches it in place.
  - The app quits when Projects closes while no project is open.
  - Every window sets `isRestorable = false`.
  - Each window root installs the ambient defaults and carries a key.
- **Geometry.** The traffic lights are measured, never moved, and the top bar derives from them. The project window's minimum is 880 × 560, and the graph keeps at least 320 px.
- **Preferences** are defaulted fields in `packages/zanshin_settings`, with no migration.
- **Tooling.**
  - Widgetbook 3.25.0, pinned exactly; Widgetbook 4.x is out.
  - `marionette_flutter` ^0.7.0 with one shared configuration. It matches by `Semantics(identifier:)` or by text, never by coordinates. Zs controls take only an optional identifier.
  - The native chrome is checked only by the CGWindowList probe.

## UX & Interaction Patterns

- **Top bar** (Place · View · Action): its centre gives way first when the window narrows.
- **Rail:** Bookmarks and Undo Timeline. Workstreams are dropped, and Reviews stay hidden.
- **Calm scrolling:** while the user scrolls, the chrome steps aside. It is gated by "Hide controls" in Settings.
- **⌘,** opens Settings on the tab shown last and never toggles it.
- **⌘W** on the project window closes the project and shows Projects.
- **⌘J and ⇧⌘J** only scroll; the selection stays.
- **Esc** closes the topmost surface, in its own window only.
- **The Change menu** acts on the selection, else on @, and each item names its target.
- **Menu-bar labels** are in Title Case; all other UI text is in sentence case.
- **Cursor:** the arrow everywhere, with these exceptions:
  - the I-beam over text entry;
  - `progress` while busy;
  - `grabbing` while the canvas is held;
  - the resize cursor on resize edges.
- **Change ids** show the bold shortest unique prefix, with no gap before the rest.

## Cross-Story Dependencies

- **Order within the epic:**
  - 11.1 → 11.2 → 11.14 → 11.11 → 11.3 (11.1 and 11.2 are done).
  - 11.4 runs in parallel with 11.2.
  - 11.12 follows 11.4 and comes before 11.5–11.7 and before 10.22.
  - 11.13 follows 11.12, 10.9 and 10.23, and comes before 11.5–11.8. Each menu item stays grey until its handler story lands.
  - 11.5 follows 11.3. 11.6 and 11.8 follow 11.5.
  - 11.7 follows 11.3; its Project tab needs 11.5.
  - 11.9 follows 11.3, 10.9 and 10.23.
  - 11.10 comes last, after 11.11 as well.
- **Epic 10:**
  - 11.1 and 11.14 precede 10.1, whose `GraphTheme` derives from the tokens.
  - 11.11 precedes 10.7 and every later story that draws a control.
  - Epic 10's widgets fill 11.3's slots through 10.5's contract: insets go in, and the calm signal and the chrome API come out.
  - Until 10.12, the graph runs on recorded layouts.
- **Backend:**
  - Shipped: open, detect and clone, status, remotes, fetch, the op log, undo, and the config surface.
  - Backlog: push with a dry-run plan (9.20), redo (9.21), `update-stale` (9.23), the poll (9.24), ahead/behind (9.29), fetch defaults (9.30), op restore (9.12).
  - Until its verb lands, a UI element stays disabled or absent.
