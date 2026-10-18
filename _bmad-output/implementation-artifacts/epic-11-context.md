# Epic 11 Context: Floating app shell (Flutter UI)

<!-- Generated from planning artifacts. Regenerate with compile-epic-context if planning docs change. -->

## Goal

Build the macOS app around the commit graph: one project window in which the graph fills the space and every control floats above it on glass islands. A user picks or adds a project, switches projects from the capsule, changes settings in one window, fetches and pushes from the top bar, and steps back through the operation log. The epic owns everything that is not graph-semantic — the design-system foundation, glass materials and Zs control library (package `zanshin_ui`, with the Widgetbook catalogue and Marionette setup), the overlay host, native chrome and window foundation, projects, Settings, the menu bar, sync, the Undo Timeline, and retiring the old docked mock UI. Claude builds it and Ralph reviews every story; Epic 10 plugs its graph-semantic parts into this epic's slots.

## Stories

- Story 11.0: Record the scope change in the canonical rules (done)
- Story 11.1: Design-system foundation (done)
- Story 11.2: Glass material primitives (done)
- Story 11.3: Floating overlay host
- Story 11.4: Window chrome for the floating layout
- Story 11.5: Projects (registry, capsule, Project menu, switching)
- Story 11.6: Projects window on real data
- Story 11.7: Settings window
- Story 11.8: Sync (Fetch, Push, remote-change poll, badge)
- Story 11.9: Undo Timeline panel
- Story 11.10: Retire the docked mock UI
- Story 11.11: Zs control library, Widgetbook catalogue, Marionette configuration (done)
- Story 11.12: Window foundation
- Story 11.13: Menu bar and shortcuts
- Story 11.14: The `zanshin_ui` package (done)

## Requirements & Constraints

- **Design input.** The DS in `_bmad-output/implementation-artifacts/design_system/` (downloaded 2026-10-16, synced through #9) is the reference. Precedence: decisions recorded in epics.md > DS tokens and CSS > DS prose and cards > the floating client (`design/`). The design is inspiration: small gaps get a marked "Claude's proposal"; NEEDS DESIGN questions are answered before building, never guessed. Never edit `design/` or `design_system/`; a re-download that changes a token or icon turns the gate red.
- **Done** = `cargo make test` passes and Claude has checked the change visually: open the affected use cases in the catalogue (or the app) via Marionette's `zanshinCatalogue.open`, screenshot, and compare with the DS cards rendered full size. Hover-only surfaces need a use case showing them open. No golden tests; app tests use fake ports and never call jj config verbs for real; Dart lines are not coverage-measured, so the named witnesses are the safety net. Native chrome is checked only by the CGWindowList probe.
- **CLI parity.** The UI never composes jj operations; it pre-fills parameters from the effective config and passes them explicitly. Every jj command shown is real in v0.46.0, in full, shell-quoted, with the change id. Refusals and hints are verbatim. Say "bookmark", never "branch"; "stale" means only the working copy.
- **Accessibility.** VoiceOver semantics on every surface (macOS reads roles from semantics flags only) and a keyboard path; focus rings only for keyboard focus.
- **System settings apply live, with no in-app switch.** Reduce motion by property (movement, size, rotation, stroke drawing → 0; fades keep durations; the spinner turns). Reduce transparency or increased contrast paints glass solid. An inactive window paints no hover or focus ring and neutralises the accent except its live copies (progress, flash, drop targets, links).
- **Undo** lives in three places: ⌘Z (only Zanshin's own latest operation while current), the toast, the Undo Timeline. Every undo ends in the toast "Undid ‹action› · Redo".
- **Stale working copy** is a project-level state without Retry; Fetch, Push, Change items and the op log are disabled with "Working copy is stale".

## Technical Decisions

- **Code locations.** `packages/zanshin_ui/lib/src/` holds `design/` (tokens), `materials/`, `icons/`, `controls/`; tests mirror under its `test/`. The app imports only `package:zanshin_ui/zanshin_ui.dart`; the package never depends on `zanshin_core`, `inject_*`, `marionette_flutter` or the app. App features: `app/lib/src/features/{shell (host, menu bar), projects, settings, sync, undo_timeline, window}/`, tests mirrored under `app/test/`. The catalogue (`app/widgetbook/`) and the shared Marionette configuration stay in the app. The gate is change-aware: a test reading a file outside its package needs that path in the gate-plan rules.
- **Bridge.** The app imports only `package:zanshin_core/zanshin_core.dart`; each `[UI/bridge]` story adds its types to the `show` list.
- **No Material or Yaru look.** Every control is a Zs control on the shared state core; text entry is an undecorated `TextField`. `MaterialApp`/`ThemeData` come only from `package:material_ui` (its `ThemeMode` is not Flutter's). Designed visuals are a `RenderBox` with text slots, not `Column`/`Row` trees.
- **Tokens and accent.** `Zs*` `ThemeExtension`s over theme (night/paper) × accent family, with contrast/inactive/transparency/motion deltas; `of(context)` falls back to night. The accent role (`--accent*`, `--focus-ring`) marks selection, focus, controls, menu highlights, drop targets and the flash; it follows the macOS accent unless Settings says "Zanshin", moon only under Multicolor ("moon" in older story text means this role). Gold stays with @ and the one primary action; data colours stay fixed. Selected data row `--accent-soft`, navigation `--fl-on`.
- **Icons and fonts** are `zanshin_ui` assets; SVGs are precompiled and loaded by the boot-time `IconRegistry` (tests load it in `setUpAll`/`tester.runAsync`).
- **`zanshin_shell`** reports reduce motion/transparency, contrast, accent, key status and the measured traffic-light block; window roots override `disableAnimations` themselves (the embedder never reports reduce motion).
- **Materials.** One `BackdropGroup` per window; one menu material for menus, popovers, callouts. Only two sheets, ConfirmDialog and Push, Flutter-drawn; a scrim click does nothing. Separate windows get an opaque fill.
- **Windows.** Settings, Projects and jj log Configurations are parentless dialog windows, one per key, via `AppWindows.openOrActivate`, each with its own minimum. One project window (one frame key) that switches projects in place. The app quits only when Projects closes with no project open. Every window sets `isRestorable = false`; each root installs the ambient defaults over the shared DI and carries a key (Marionette `ancestor_keys`). Window content stays window-agnostic; each window story adds a Widgetbook "Windows" use case opening the real window.
- **Geometry.** Traffic lights are measured, never moved: the bar centres on the block, the first island at block end + 12, content top 60 (68 full screen). Project-window minimum 880 × 560; the graph keeps ≥ 320 px. Inspector 380–720 (460), left panels 240–440 (300); the remembered width persists (AppSettings `layout`), never the effective one; when space runs out the inspector shrinks, then the panel, then the pinned panel collapses keeping its pin.
- **Preferences** are defaulted fields in `packages/zanshin_settings`, no migration.
- **Tooling.** Widgetbook 3.25.0 pinned exactly (no 4.x). `marionette_flutter` ^0.7.0, one shared configuration; match by `Semantics(identifier:)` or text, never coordinates. `@experimental`/`@Deprecated` APIs only with an explicit `// ignore:` plus `// WHY:`; `dart analyze --fatal-infos --fatal-warnings` stays clean.

## UX & Interaction Patterns

- **Top bar** Place · View · Action; the centre gives way first when narrowing.
- **Rail:** Bookmarks and Undo Timeline only (Workstreams dropped, Reviews hidden). Previews are hover-only; the keyboard path is the rail button (↩ pins).
- **Calm scrolling:** user scrolling moves the chrome aside, gated by "Hide controls", back after one 650 ms wait; only this window's menus, popovers and sheets block it.
- Transient surfaces share one exit (fade + mirrored drift × motion). **Esc** closes the topmost surface, in its own window only.
- **Shortcuts:** ⌘, opens Settings on the last tab, never toggles. ⌘W on the project window closes the project and shows Projects. ⌘J/⇧⌘J only scroll. Fetch has no shortcut; Push… is ⇧⌘P. Text shortcuts win inside fields. Project commands reach the project window from any Zanshin window.
- **Change menu** acts on the selection, else @, and names its target ("Abandon @").
- **Text:** menu bar Title Case, everything else sentence case, English. **Cursor:** arrow, except I-beam on text entry, `progress` while busy, `grabbing` on a held canvas, resize cursors on edges. **Change ids:** bold shortest unique prefix, no gap.

## Cross-Story Dependencies

- **Order:** 11.0–11.6, 11.11 and 11.14 done (11.5 and 11.6 ran ahead of 11.12 and 11.13; their window and shortcut parts wait in deferred-work.md and for 11.12/11.13); 11.12 next. 11.12 after 11.4, before 11.6, 11.7 and 10.22 (and 11.5's deferred window parts). 11.13 after 11.12, 10.9, 10.23, before 11.6–11.8 and 10.16 (and 11.5's shortcuts; items stay grey until their handler story lands). 11.5 after 11.3; 11.6 and 11.8 after 11.5; 11.7 after 11.3 (Project tab needs 11.5); 11.9 after 11.3, 10.9, 10.23; 11.10 last. Until 11.12 lands, the project window counts as key.
- **Epic 10:** 11.11 precedes 10.7 and every later control-drawing story. Epic 10 fills 11.3's slots through 10.5's contract (insets in; calm signal and chrome API out); 10.8 puts the inspector on 11.3's `ZsResizeEdge`. Until 10.12 the graph runs on recorded layouts behind fake ports. 10.1 adds the catalogue's Graph folder.
- **Hand-offs from done stories:** 11.3 settled its own (glass fades only through `ZsFade`, which 10.16 and 10.23 use too; the glass nesting check stays on the element tree, so glass never mounts through an `OverlayPortal` inside other glass; the rail callout needs no other arrow side). Still open: another arrow side for 10.6's and 10.19's callouts, and the glass cost, measured once 10.1 exists. 11.4 settled its own (the AccentColor asset ships, so a Multicolor Mac can resolve to moon — the exact-match check is still pending on a Multicolor Mac, deferred-work.md, Story 11.1 section; the window root drives full screen and the traffic-light block from the shell's chrome report through `WindowChromeBuilder`, which 11.12's per-window roots reuse). 11.5 settled its own (the registry is `AppSettings.projects`; `ProjectSession` detects, opens, switches and closes, and writes the open project's dot and bookmark label into its entry; the capsule holds calm while its menu is open). Still open from 11.5: 11.12 shows Projects when `reopenLast` opens nothing and after `closeProject` and passes All Projects… (11.6 settled the offers: the Git conversion, `jj git init` and the enclosing repository run from `ProjectSession`'s outcomes in the Projects content); 11.7 passes Project Settings… and Settings…; 11.12 routes the red button to `closeProject`; 11.13 binds ⌘W, ⇧⌘O and ⌘,; 10.22 checks before a switch, a close and quitting; 10.5 reads `ProjectSession.repo.handle`; 9.29 and 11.8 add ahead, behind, diverged and syncing to `ProjectStatus`. 11.6 settled its own (the Projects window's content is `ProjectsWindow`, window-agnostic, built through `MainComponent.projectsWindowFactory` over the singleton `ProjectRegistry`/`ProjectSession` and a `ProjectsEnvironment`; `ProjectSession` registers canonical paths, adds without opening, converts, inits and clones with the CLI's destination rules; `zanshin_shell` has `chooseDirectory` and `revealInFinder`). Still open from 11.6: 11.12 hosts it in the `projects` dialog window (900 × 640, minimum 680 × 440, title "Projects"), closes it from `onOpened` and shows that outcome's warnings elsewhere, and passes Settings… and Set identity… once 11.7 exists; 11.13 binds ⇧⌘O, ⌘W and ⌘F to it. 11.12 — the per-window inactive delta. 11.13 — an open sheet must block window shortcuts and menu items. 11.10 — Yaru, the icon font, `flutter_svg`, the workstream glyph, the `main2/3/4.dart` hosts.
- **Backend:** shipped — open/init/clone, detect/convert, status, bookmarks, remotes, fetch of one named remote with progress, op log, undo, config surface. Backlog — push + dry-run plan (9.20), redo/op surface (9.21), `update-stale` (9.23), remote poll (9.24), ahead/behind (9.29), fetch defaults (9.30), op restore (9.12). Until its verb lands, a UI element stays disabled or absent.
