# Epic 10 Context: Commit-Graph View (Flutter UI)

<!-- Generated from planning artifacts. Regenerate with compile-epic-context if planning docs change. -->

## Goal

Build Zanshin's main view: the commit graph that owns the project window, with every control floating above it, built from the floating-client design export and its design system. A user opens a repository and sees the commits of their effective `jj log` revset (or `all()`, or a search), laid out in Free (default) or Compact mode. They pan and scroll smoothly over 10k–100k commits, hover for ancestry and callouts, select a change into the inspector, and run jj verbs from cards, menus, the inspector, the bookmark and tag views, the search and drag-and-drop. After every operation, Zanshin's own or an external `jj`, the view reloads and stays anchored. It is the product's core surface, so it must behave exactly like the jj CLI while replacing its terminal UX.

## Stories

- Story 10.0: Record the Epic 10 scope exception in the canonical rules
- Story 10.1: Graph viewport — two-axis virtualized canvas over positioned nodes
- Story 10.2: Canvas and Free's day axis
- Story 10.3: Commit cards — detailed and compact, states, bookmark slots
- Story 10.4: Graph edges
- Story 10.5: Graph view model and repository wiring
- Story 10.6: Selection, hover focus path, callout, @ locator, go-to, keyboard
- Story 10.7: Graph controls in the floating top bar
- Story 10.8: Inspector — floating panel, describe, meta, actions, file list
- Story 10.9: Action runner — one path from every affordance to a verb
- Story 10.10: Drag-and-drop of changes and bookmarks
- Story 10.11: Content paging — skeleton cards and visible-range loads
- Story 10.12: Adopt the backend layout (real `GraphSource`)
- Story 10.13: Time-layout lab (experiment)
- Story 10.14: Bookmarks in the floating rail
- Story 10.15: Card action menu and the thin bookmark popover
- Story 10.16: Minimap
- Story 10.17: Commit stacks
- Story 10.18: AI titles for commit stacks (declined)
- Story 10.19: Hidden history — gap markers, end stubs, gap callout, legend
- Story 10.20: Graph animations
- Story 10.21: Graph search
- Story 10.22: jj log Configurations window
- Story 10.23: Operation toast
- Story 10.24: Inspector diff view
- Story 10.25: Commit/split composer and Squash into parent
- Story 10.26: Hunk selection through a GUI tree
- Story 10.27: Drag files and hunks onto a change
- Story 10.28: A raw revset rule in the Configurations window
- Story 10.29: Operation diff view in the Undo Timeline
- Story 10.30: Review findings 2026-11-02
- Story 10.31: Time axis and minimap for long histories
- Story 10.32: Word marks in the inspector diff
- Story 10.33: Ignore whitespace in the inspector diff
- Story 10.34: Word marks differ in lightness
- Story 10.35: Inspector fixes — title form, parent ids, jump to parent, Split
- Story 10.36: jj absorb — Squash menu, card menu and Change menu rows
- Story 10.37: View state in a file per project
- Story 10.38: Inspector rebuild, part 1 — split layout, divider, Finder keys
- Story 10.39: Inspector rebuild, part 2 — file rows, tree or flat, copy, Reveal, Open in Editor
- Story 10.40: Inspector follow-ups from Ralph's first use of 10.33–10.39
- Story 10.41: The ignoring diff shows exactly `jj diff -w`
- Story 10.42: Calm inspector, part 1 — folders without chevrons, checkboxes on demand
- Story 10.43: Calm inspector, part 2 — no hunk header, one checkbox per part, gap rows
- Story 10.44: The Bookmarks and Tags views — rail button, filter, tree, row buttons, delete dialog
- Story 10.45: Tags on the cards; the card menu opens by right-click only
- Story 10.46: Names and pickers — refused characters become `_`, "Move existing here…" picks from a list
- Story 10.47: Search — tags, and actions on bookmark and tag hits

## Requirements & Constraints

- **Behave like the CLI.** Every verb, precondition, refusal, default and op-log effect matches the stock jj CLI at the pinned version (v0.47.0). Pass CLI parameters through, pre-filled from the effective config; never bake in defaults. CLI parameters the API lacks are backend gaps, not UI work. Where the design does not fit jj, build along jj's behaviour; that is not a question for Ralph. Recorded deliberate deviations stay (e.g. 10.46's ref-name rules are stricter than the CLI).
- **The UI never composes jj operations** or command sequences of its own. Rows that depend on jj state (drop actions, absorb, squash availability) come from backend previews.
- **Commands shown in UI text are real:** they exist in the pinned jj exactly as written, shown in full with the change id or ref name, shell-quoted, `exact:` where a pattern needs it. jj 0.47 has no `tag forget` and no `tag move` (`jj tag set --allow-move` moves a tag).
- **Scale:** the geometry is complete and exact before the first frame (extents and scrollbars from data, no widget measured); content loads lazily per visible page. The view never computes rows, columns, route classes, buckets or a free y.
- **Strings** go through the ARB (`app/lib/l10n/app_en.arb`, `packages/zanshin_ui/lib/l10n/zs_en.arb`), with ICU plurals; jj's own words stay literals marked `// l10n-ignore: <reason>`. Run `flutter gen-l10n` after an ARB edit and commit the output.
- **Definition of done:** `cargo make test` passes (inside a `/story-loop`, targeted checks per run and the full gate once at the end). The coverage ratchet measures Rust only, so each story's named widget-test witnesses are the safety net. Before a UI change counts as done, the catalogue or the app is driven through Marionette and compared with the DS cards and the story's design study.
- No golden tests. Scroll-physics tests run under `TargetPlatformVariant.only(TargetPlatform.macOS)`. Real-cdylib widget tests wrap worker and watcher I/O in `tester.runAsync`. App tests never call a jj config verb for real.

## Technical Decisions

- **Code** lives in `app/lib/src/features/graph/` (bookmark views in `features/bookmarks/`), tests mirror it under `app/test/features/`. Shared controls are the Zs library in `packages/zanshin_ui`; no visible control is Material or Yaru. Remaining Material types (`MaterialApp`, `ThemeData`) come only from `package:material_ui`.
- **Bridge:** the app imports only `package:zanshin_core/zanshin_core.dart`; a `[UI/bridge]` story adds the types it consumes to that library's exports. A new backend read or preview goes Rust → FFI schema → codegen → `docs/ffi-abi.md` → `zanshin_core`.
- **Ports:** the view model declares `GraphSource` (layout) and `GraphActions` (verbs). Every affordance runs through the one action runner: pending state, anchored reload, refusals, warnings, undo, the operation toast and the flash.
- **Layout** comes from the engine on `zanshin_core`'s worker isolate. Free and Compact each choose their own columns, and lines follow the graph-layout lab's rules (`docs/graph-layout.md`). A mode switch may move cards sideways and re-centres on @.
- **Scroll precedence:** an explicit reveal (go-to, bookmark or tag pick, locate @) beats the re-centre on @ after a revset or layout switch, which beats the anchor. Floating panels never resize the viewport; reveals centre in the area the chrome leaves free.
- **Visuals** are `RenderBox`es with text slots, not nested `Column`/`Row` trees.
- **Theme:** every colour and size comes from the design-system token layer; `GraphTheme` derives the graph roles from it and falls back to night. Selection, focus, drop targets, the go-to pulse and the flash use the accent role (`--accent*`, `--focus-ring`); gold is only @ and the one primary action. Immutable changes carry the hatch, not a glyph.
- **Motion** is the FLIP model: moved cards glide 460 ms, births grow from their anchor, changed cards flash 2.4 s. Under reduce motion, movement goes to 0 but colour and opacity fades stay.
- **Settings vs state:** global preferences (diff layout, whitespace mode, file list tree/flat, split ratios, editor) live in the settings package; context lines write jj's `diff.color-words.context` at user scope while the menu shows the effective value. Per-project view state (Viewed marks, stack toggles) lives in `projects/<stateId>.json` beside `settings.json` (`SettingsStore.projectStates`), never in the repo or `.jj/`.
- **Diff and hunk selection:** whole files pass paths; partial selections pass the `TreeId` from `select_tree`, never `-i`. A hunk's parts are jj's builtin diff-editor sections; the smallest pick is a part. Rust is the only place that compares lines; Dart only draws. While whitespace is ignored, rows are exactly `jj diff -w` / `-b`; picks still map to exact parts (tied where one whitespace pair spans several). Hidden unchanged lines come from Rust (`diff_lines`), read only when a gap opens.
- **Refs:** tags come from Story 9.59's tag list and become `GraphRef`s like bookmarks (`TopologyRefKind.tag`). The Bookmarks view keeps `jj bookmark list --all-remotes` rows (no `@git`). Tags cannot be dragged.

## UX & Interaction Patterns

- The design export (`design/`: `JJ Desktop Client Floating.html`, `Inspector Study.html`, `Whitespace Study.html`, `Calm Inspector Study.html`, `Refs Study.html`) and the design system (`design_system/`) are inspiration, not a 1:1 template. Tokens and CSS win over DS prose; a decision recorded in the epic wins over the export. Small gaps get a marked Claude proposal; NEEDS DESIGN questions are for architecture or scope only.
- Each story records the DS sync it was built against ("DS synced through #N"; #26 is current). Nothing under `design/` or `design_system/` is edited by hand; DS changes go through the `design-artifacts` skill, and their publish waits for a console session.
- **Calm UI (10.42 onward):** show nothing twice and controls only when needed. Folder rows (inspector, Projects window, bookmark and tag trees) show open/closed by their icon, no chevron. Checkboxes, gap-row controls and row buttons show only on hover or keyboard focus in their pane or row; picked boxes always show; reserved space keeps rows from shifting or changing height. No +/− counts, no "M" badge; added, deleted and renamed files get a quiet word. A part's checkbox hover draws the pick bar (2 px `--accent-line`, left edge).
- The inspector is a floating glass panel with no fixed maximum width; at least 320 points of graph stay visible. It switches files above vs beside the diff by width.
- **Refs (10.44–10.47):** Bookmarks and Tags each have a rail button and a pinned tree view with a filter. Deleting a ref with no remote happens at once with toast Undo; with a remote, a sheet offers "Only here", "Here, and on origin when you push" (default) and "Here and on origin now" (danger), each with its commands. Cards show the bookmark pill top-right and the tag pill bottom-right, both right of centre. The card's ••• button goes; the card menu opens by right-click, the context-menu key, ⇧F10 and a VoiceOver "Show menu" action. Search actions show on the active row only.
- Esc, ⌘F and `/` are scoped to their surface, never window-global. Keyboard focus is one roving node, not a tab stop per card. Shortcuts are bound in the menu bar (11.13).
- Hover-only surfaces need a catalogue use case that shows them open, because Marionette cannot hover.

## Cross-Story Dependencies

- Done: every story through 10.47 except 10.27 (backlog) and 10.18 (declined). Open: 10.27.
- 10.47: the search's ref hits are `GraphBookmarkRow`s with a `GraphSearchRef` (`tag`, `newAction`, `trackAction`); `GraphSearchSource.bookmarks()` reads `--all-remotes`, `tags()` is new; the index drops `@git`, synced remote rows and repeats; one row shows the buttons (hovered, else keyboard row), ⌘↩ runs New.
- 10.46: the name rules live in `graph_ref_name.dart`; `GraphNameRequest.refName` (false only for Move to…); "Move existing here…" asks a `GraphMoveRequest` and shows `GraphMoveSheet` (rows from the popover's read, `graphBookmarkMoveCheck` over `dropActions`).
- 10.45: tags are `GraphLayout.tagsOf` (not a kind on `GraphRef`; `refsOf` stays bookmarks); the tag popover opens on a click like the bookmark popover; the card menu has no ••• and ends with Create bookmark here… / Create tag here… (no shown command; the name sheet shows it). "Move existing here…" for tags is a free-text name sheet (`jj tag set … --allow-move`) until 10.46's picker.
- 10.44 → 10.45 → 10.46, and 10.44 → 10.47. 10.44's delete dialog serves the card bookmark popover (10.15) and 10.45's tag popover; 10.46's name field and move picker serve 10.45's "Create tag here…" and tag popover. All four need backend 9.59 (done). 10.44's delete note points at the Push sheet's offer to push deletions (11.22). Open design questions with defaults: tree order (folders first) in 10.44; `@` inside names (allowed, only `@{` and a lone `@` refused) in 10.46.
- 10.27 builds on 10.10's drag engine, 10.24–10.26, 10.23, and backend 9.15, 9.31 (diff source) and 9.50.
- 10.42/10.43's calm rules also reach the Projects window tree (`projects_tree.dart`) and the Undo Timeline's operation view (`operation_changes.dart`, which reuses the inspector diff and has no checkboxes). Since 10.40 every `ZsMenuAnchor` closes on any click outside its panel, and the click is consumed.
- 10.39's editor detection reuses 9.36's login-shell PATH; 10.37 touches the project registry and Settings › Project (Epic 11).
