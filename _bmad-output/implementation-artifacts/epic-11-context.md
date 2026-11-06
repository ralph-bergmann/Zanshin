# Epic 11 Context: Floating app shell (Flutter UI)

<!-- Generated from planning artifacts. Regenerate with compile-epic-context if planning docs change. -->

## Goal

Build everything around the commit graph that is not the graph itself: the design-system foundation, the glass material, the Zs control library and its Widgetbook catalogue, the floating overlay host (top bar Place · View · Action, rail, pinned panels, calm scrolling), the native window chrome, real windows for Projects / Settings / jj log Configurations, the menu bar, projects and switching, sync (Fetch, Push, remote-change poll), the Undo Timeline, the retirement of the docked mock UI, and the follow-ups that keep the shell honest to jj (remote management, config file editing, density tokens, push help for Git switchers, jj 0.47 parity gaps). The user launches Zanshin, picks or adds a project, and works in one window where the graph fills the space and every control floats above it on glass islands. Claude builds the UI (scope change 2026-10-14); Ralph accompanies and reviews.

## Stories

- Story 11.0: Record the scope change in the canonical rules
- Story 11.1: Design-system foundation (tokens, type, metrics, motion, theme, fonts, icons, DS parity test)
- Story 11.2: Glass material primitives
- Story 11.3: Floating overlay host
- Story 11.4: Window chrome for the floating layout
- Story 11.5: Projects — registry, capsule, Project menu, switching
- Story 11.6: Projects dialog (window) on real data
- Story 11.7: Settings window — General and Project tabs
- Story 11.8: Sync — Fetch, Push, remote-change poll, upstream badge
- Story 11.9: Undo Timeline panel
- Story 11.10: Retire the docked mock UI
- Story 11.11: Zs control library, Widgetbook catalogue, shared Marionette configuration
- Story 11.12: Window foundation — dialog windows, chrome kinds, frames, per-window roots
- Story 11.13: Menu bar and shortcuts
- Story 11.14: The `zanshin_ui` package
- Story 11.15: Projects window — deselect, group naming/menu, New group…, drag ghost
- Story 11.16: l10n-ready — strings into ARB files (English only)
- Story 11.17: Menu bar state via a native channel
- Story 11.18: Remote management in Settings — add, rename, remove, set URL
- Story 11.19: Edit the config file — GUI split of `jj config edit`
- Story 11.20: Density with an effect — spacing tokens per density, plus Zoom
- Story 11.21: Immutable commits page — untracked remote refs by tracking state
- Story 11.22: Push help for Git switchers — fix-it actions, plain explanations, post-conversion tracking hint
- Story 11.23: jj 0.47 follow-ups — workspace configs in config gc, binary files in file search, dead wire values, stale title draft

## Requirements & Constraints

- **CLI parity:** every repo-side effect behaves like the pinned jj (now **v0.47.0**; read the CLI at that tag in `../jj`). The UI never composes jj operations; it pre-fills parameters from the effective config and passes them explicitly. Missing CLI parameters are backend gaps, not UI work. CLI hints/outcomes Zanshin's verbs omit (e.g. the post-`git init` trackable-bookmarks list) are parity gaps to close.
- **Commands shown are real:** any jj command in UI text exists in the pinned jj exactly as written, shown in full with the change id, shell-quoted (`jj new -A kmnvxoqp`, `jj bookmark track main@origin`, `exact:` patterns). DS empty-state copy is used where it exists.
- **jj's own text stays verbatim.** Explanations for Git switchers sit beside jj's message/hint, keyed by a kind the bridge sends over FlatBuffers — never derived by parsing jj's text. The same goes for ids (change ids come from the bridge, not from jj's strings).
- **Remote poll** is read-only (ls-remote semantics): no op-log entry, no working-copy change, no commit count. Silent failure on a tick, no overlap, next tick retries; no special auth handling.
- **Push** follows the CLI per mode: bare/`-r`/bulk modes skip refused refs with jj's reason verbatim; explicitly named refs abort the whole push. `--allow-*` flags passed where allowed. Tags pushed and listed; classification per remote. Why a row cannot be ticked is visible in every mode.
- **Undo:** three places only (toast, ⌘Z/Edit menu for Zanshin's own latest op while current, Undo Timeline). Every undo ends in the toast "Undid ‹action› · Redo".
- **Strings:** all user-facing text through ARB (`app/lib/l10n/app_en.arb`, `packages/zanshin_ui/lib/l10n/zs_en.arb`; `flutter gen-l10n` after edits); jj's verbatim words marked `// l10n-ignore: <reason>`. Every window root registers `zanshinLocalizationsDelegates`.
- **Accessibility:** Epic 11 surfaces carry their own VoiceOver semantics (e.g. resize edges as adjustable values, not a splitter role).
- **No telemetry / analytics SDKs.**
- **Done = `cargo make test` green** (from the repo root), plus a Marionette check of the running catalogue/app compared to the DS cards; widget tests alone do not count. Coverage ratchet is Rust-only, so named witnesses are the Dart safety net. Bridge changes (new fields/kinds) go through the FlatBuffers schema + `cargo make codegen`, and update `docs/ffi-abi.md` / `docs/rust-error-codes.md` where wire values change.
- **Design rounds are done** for 11.18/11.19 (sync #20: DS `RemotesGroup`, `ConfigFilePage`, card "Settings — Remotes and config file", prototypes `design/remotes.jsx`, `design/config-file.jsx`) and 11.20 (sync #21: readme "Density and zoom", `components/density.css`, cards Density + Settings) — build to the DS, no new round.
- **Remotes (11.18):** rows call the existing remote verbs (add/rename/remove/set-url) with the full shell-quoted command and jj's refusal verbatim; Remove confirms via a ConfirmDialog sheet on the Settings window; a credential in a URL never shows (gix `to_bstring`, never `Display`). Fetch/push selects, the poll and the Push sheet re-read remotes after a change.
- **Config file (11.19):** reads/writes go through the existing configFileRead/Write (CLI scopes and paths, jj's validation); a rejected write leaves the file unchanged and shows jj's message (parse error marked from jj's span); other open windows re-read after a save. The Settings window becomes resizable (min 620 × 420, zoom enabled; height follows the tab until resized).
- **Density (11.20) is air only:** rows +0/+3/+6 px, graph cards 40/62 · 44/68 · 48/74, gaps 56×48 · 62×54 · 68×60; text, controls, chrome, radii, window sizes stay; the 12.5/13/13.5 text scale goes. **Zoom** (90·100·110·125·150 %, Settings › General + View › Zoom In ⌘+ / Zoom Out ⌘− / Actual Size ⌘0) scales everything in every window, live, remembered app-wide, multiplied with density; window minimums scale, traffic lights never. Needs a settings field `appearance.zoom`. Non-goals: per-window density, a custom scale.

## Technical Decisions

- **Design source:** the design system `_bmad-output/implementation-artifacts/design_system/` (tokens and CSS win over its prose and cards) and the floating-client prototype under `design/`. Design is inspiration; where DS and prototype differ, the DS wins. A DS re-download that changes an icon turns the gate red (icon parity check).
- **Code locations:** `packages/zanshin_ui` holds tokens (`lib/src/design/`), materials (`lib/src/materials/`), DS icons (`lib/src/icons/`) and Zs controls (`lib/src/controls/`); the app imports only `package:zanshin_ui/zanshin_ui.dart`. App features: `app/lib/src/features/{shell,projects,settings,sync,undo_timeline,window}/`; menu bar in `shell/`; catalogue `app/widgetbook/`; tests mirror under `app/test/`.
- **Bridge:** the app imports only `package:zanshin_core/zanshin_core.dart`; a `[UI/bridge]` story adds the types it consumes to the export `show` list.
- **Controls:** own Zs library on Flutter widgets-layer primitives; no visible Material/Yaru control; text entry is an undecorated `TextField`. Material types (`MaterialApp`, `ThemeData`) only from `package:material_ui` (its `ThemeMode` ≠ Flutter's). Control heights 22 · 26 · 30 · 36 · 44.
- **Visuals** are `RenderBox`es with text slots, not nested Column/Row trees.
- **Accent:** Multicolor = moon (Zanshin's); a named macOS accent recolours only the accent role (`--accent*`, `--focus-ring`); gold, brand and data colours stay fixed. "Moon" in older story text means the accent role for selection/focus/flash; moon as data (`--status-m`, `--hunk`, `--remote`) stays fixed. Picked data rows use `--accent-soft`, navigation `--fl-on`. Themes: night and paper (`light` alias).
- **Motion:** reduce motion by property — colour/opacity keep their tokens, movement/size/position go to 0. One exit for transient surfaces: fade + mirrored drift, 180 ms, `--ease-exit`. Calm scrolling returns after one 650 ms wait.
- **Icons:** SVG via `vector_graphics_compiler` asset transformer; boot-time `IconRegistry` (parallel to settings in `ZanshinBootSequence`, injected via a module with a required ctor param); `ZanshinIcon` leaf RenderBox in six sizes; no Material fallback. Widget tests load the registry in a shared `setUpAll` (`tester.runAsync`).
- **Windows:** one project window (opening another project switches it in place; minimum 880 × 560). Settings and Projects are parentless dialog windows at normal level; Projects is the start window, closing it quits; ⌘W on the project window closes the project and shows Projects. jj log Configurations is its own floating window (min 820 × 460) that asks "Discard changes?" on close/quit. Only two sheets: ConfirmDialog and Push. Native traffic lights are never moved; the bar derives from their measured block.
- **Resize edges:** inspector 380–720 (default 460), left panels 240–440 (default 300); collapse rule keeps ≥ 320 px of graph; dragged widths persist in an AppSettings `layout` sub-model.
- **Density** (11.7) is a text scale today; 11.20 replaces it with per-density token sets in `zanshin_ui` (`ZsMetrics`), switched live in every window, graph card metrics following (router geometry stage only); the DS parity reader learns `data-density` and the token block moves from `components/density.css` into `tokens/spacing.css`.
- **Tooling:** Widgetbook 3.25.0 pinned exactly is the one review catalogue; `marionette_flutter` ^0.7.0 with one shared `MarionetteConfiguration`; match by Semantics identifier or text, never coordinates; each window root carries a key. App tests never call a jj config verb for real.

## UX & Interaction Patterns

- Graph fills the window; controls float on glass islands. Top bar grid Place (project capsule) · View · Action (Fetch, Push…); rail with hover previews and pins.
- Menu bar items in Title Case; the Change menu targets the selection, else @, and names its target ("Abandon @"). Go/Change/project commands target the project window from any Zanshin window.
- Rows showing ⌘, open/bring forward Settings on the tab shown last; only "Project Settings…" and "Appearance, diffs and more" pick a tab. Settings has pages (a row opens a page; ⌘[ goes back). ⌘J scrolls to the selection, ⇧⌘J to @ (scroll only). Fetch has no shortcut; Push… is ⇧⌘P.
- A click beside a sheet does nothing; Esc and Cancel cancel. No hover painted in a non-key window.
- Workstreams and Reviews are dropped; no Workspaces section in the Project menu. Workspaces show as `name@` on cards plus a project-level stale-working-copy state with jj's text and no Retry.
- Change ids: one `Text.rich`, bold shortest-unique prefix, no gap. Where a commit is named, the change id comes first and the commit id dimmed after it, as in the inspector.
- Help for Git switchers: one or two plain sentences naming the Git term next to the jj one; a fix-it action wherever jj's hint names a command (it runs the verb, shows the command, then refreshes the preview).

## Cross-Story Dependencies

- Build order of the core shell: 11.0, 11.1 → 11.2 → 11.14 → 11.11 → 11.3 onward; 11.12 before 11.5–11.7 and 10.22; 11.13 before 11.5–11.8 (unwired menu items stay grey). 11.7, 11.8, 11.21, 11.22 and 11.23 are done; 11.18, 11.19 and 11.20 are backlog (designs ready).
- 11.18 needs 9.5 (remote verbs), 11.7, 11.8; 11.19 needs 9.28 (configFileRead/Write) and 11.7; 11.20 needs 11.7 and 11.14 — all done. 11.18 and 11.19 share the Settings window (11.19 makes it resizable).
- 11.22 builds on 11.8's Push sheet, 9.11's track verb, 9.57's conversion (`crates/zanshin-jj/src/convert.rs`) and 10.14's Bookmarks panel track action; it adds a refusal kind to `PushRefusal` and change ids to `PushRef` over FlatBuffers.
- 11.23 follows the jj 0.47 pin bump (done) and touches 9.28's config gc (`MissingRepoConfig` gains a kind), 9.4's file search (binary mode), wire values removed across schema/Rust/zanshin_core/Push sheet/l10n/docs, and the 10.24/10.25 inspector describe form + composer drafts.
- Epic 10 keeps everything graph-semantic (View capsule contents, search, Configurations content, Bookmarks panel, @ pill, inspector, minimap, toast) and plugs into 11.3's slots and 10.5's contract (insets into the graph; calm and the chrome-facing api out of it).
- Backend verbs from Epic 9: push (9.20), remote poll (9.24), fetch parity (9.30), op-log/redo (9.21), config surface (9.27/9.28), remotes (9.5), bookmark track (9.11), conversion (9.57).
