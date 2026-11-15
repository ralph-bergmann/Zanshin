# Epic 10 Context: Commit-Graph View (Flutter UI)

<!-- Generated from planning artifacts. Regenerate with compile-epic-context if planning docs change. -->

## Goal

Build Zanshin's main view: the commit graph that owns the project window, with every control floating above it, built from the floating-client design export and its design system. A user opens a repository and sees the commits of their effective `jj log` revset (or `all()`, or a search), laid out in Free (default) or Compact mode. They pan and scroll smoothly over 10k–100k commits, hover for ancestry and callouts, select a change into the inspector, and run jj verbs from cards, menus, the inspector and drag-and-drop. After every operation, Zanshin's own or an external `jj`, the view reloads and stays anchored. It is the product's core surface, so it must behave exactly like the jj CLI while replacing its terminal UX.

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
- Story 10.33: Ignore whitespace in the inspector diff (diff options menu)
- Story 10.34: Word marks differ in lightness
- Story 10.35: Inspector fixes — title form, parent ids, jump to parent, Split
- Story 10.36: jj absorb — Squash menu, card menu and Change menu rows
- Story 10.37: View state in a file per project
- Story 10.38: Inspector rebuild, part 1 — split layout, divider, Finder keys, hunk parts
- Story 10.39: Inspector rebuild, part 2 — file rows, tree or flat, copy, Reveal, Open in Editor
- Story 10.40: Inspector follow-ups from Ralph's first use of 10.33–10.39

## Requirements & Constraints

- **Behave like the CLI.** Every verb, precondition, refusal, default and op-log effect matches the stock jj CLI at the pinned version (currently v0.47.0). Pass CLI parameters through, pre-filled from the effective config; never bake in defaults. CLI parameters the API lacks are backend gaps, not UI work.
- **The UI never composes jj operations** or command sequences of its own. Rows that depend on jj state (drop actions, absorb, squash availability) come from backend previews.
- **Commands shown in UI text are real:** they exist in the pinned jj exactly as written, shown in full with the change id, shell-quoted, `exact:` where a pattern needs it.
- **Scale:** the geometry is complete and exact before the first frame (extents and scrollbars from data, no widget measured); content loads lazily per visible page. The view never computes rows, columns, route classes, buckets or a free y.
- **Strings** go through the ARB (`app/lib/l10n/app_en.arb`, `packages/zanshin_ui/lib/l10n/zs_en.arb`), with ICU plurals; jj's own words stay literals marked `// l10n-ignore: <reason>`. Run `flutter gen-l10n` after an ARB edit and commit the output.
- **Definition of done:** `cargo make test` passes. The coverage ratchet measures Rust only, so each story's named widget-test witnesses are the safety net. Before a UI change counts as done, Claude drives the catalogue or the app through Marionette and compares screenshots with the DS cards; widget tests do not replace this.
- No golden tests. Scroll-physics tests run under `TargetPlatformVariant.only(TargetPlatform.macOS)`. Real-cdylib widget tests wrap worker and watcher I/O in `tester.runAsync`. App tests never call a jj config verb for real.

## Technical Decisions

- **Code** lives in `app/lib/src/features/graph/`, tests mirror it in `app/test/features/graph/`. Shared controls are the Zs library in `packages/zanshin_ui`; no visible control is Material or Yaru. Remaining Material types (`MaterialApp`, `ThemeData`) come only from `package:material_ui`.
- **Bridge:** the app imports only `package:zanshin_core/zanshin_core.dart`; a `[UI/bridge]` story adds the types it consumes to that library's exports. A new backend preview (e.g. `ChangeActions.absorb`) goes Rust → FFI schema → codegen → `docs/ffi-abi.md` → `zanshin_core`.
- **Ports:** the view model declares `GraphSource` (layout) and `GraphActions` (verbs). Every affordance runs through the one action runner: pending state, anchored reload, refusals, warnings, undo, the operation toast and the flash.
- **Layout** comes from the engine on `zanshin_core`'s worker isolate. Free and Compact each choose their own columns, and lines follow the graph-layout lab's rules (`docs/graph-layout.md`). A mode switch may move cards sideways and re-centres on @.
- **Scroll precedence:** an explicit reveal (go-to, bookmark pick, locate @) beats the re-centre on @ after a revset or layout switch, which beats the anchor. Floating panels never resize the viewport; reveals centre in the area the chrome leaves free.
- **Visuals** are `RenderBox`es with text slots, not nested `Column`/`Row` trees.
- **Theme:** every colour and size comes from the design-system token layer; `GraphTheme` derives the graph roles from it and falls back to night. Selection, focus, drop targets, the go-to pulse and the flash use the accent role (`--accent*`, `--focus-ring`); gold is only @ and the one primary action. Immutable changes carry the hatch, not a glyph.
- **Motion** is the FLIP model: moved cards glide 460 ms, births grow from their anchor, changed cards flash 2.4 s. Under reduce motion, movement goes to 0 but colour and opacity fades stay.
- **Settings vs state:** global preferences (diff layout, whitespace mode, file list tree/flat, split ratios per layout, editor) live in the settings package; context lines write jj's own `diff.color-words.context` at user scope, while the menu shows the effective value (repo config included), like the CLI. Per-project view state (Viewed marks, stack toggles) lives in a state file per project, `projects/<stateId>.json` beside `settings.json` (`SettingsStore.projectStates`, 10.37), never in the repo or `.jj/`.
- **Diff and hunk selection:** whole files pass paths; partial selections pass the `TreeId` from the `select_tree` call, never `-i`. A hunk's parts are jj's builtin diff-editor sections (`Hunk.sections`); the smallest pick is a part, never single lines. Rust computes word segments; Dart only draws them.

## UX & Interaction Patterns

- The design export (`design/`, `JJ Desktop Client Floating.html`, `Inspector Study.html`) and the design system (`design_system/`) are the reference, as inspiration, not a 1:1 template. Tokens and CSS win over DS prose. A decision recorded in the epic wins over the export. Small gaps get a marked Claude proposal; NEEDS DESIGN questions are for architecture or scope only.
- Where the design does not fit jj, build along jj's behaviour; that is not a question for Ralph.
- Each story records the DS sync it was built against ("DS synced through #N"; #26 is current). A re-download with a higher N: the next visual story reads the new sync entries, adds dated notes and updates the token layer in the same change. Nothing under `design/` or `design_system/` is edited by hand; DS changes (e.g. a new `MenuButton`) go through the `design-artifacts` skill.
- The inspector is a floating glass panel. After 10.38 it has no fixed maximum width; at least 320 points of graph must stay visible. Its layout switches by width (files above vs beside the diff, with hysteresis), and the unified diff's line numbers stay pinned at the left edge while text scrolls sideways.
- Esc, ⌘F and `/` are scoped to their surface, never window-global. Keyboard focus is one roving node, not a tab stop per card. Shortcuts are bound in the menu bar (11.13).
- Hover-only surfaces need a catalogue use case that shows them open, because Marionette cannot hover.

## Cross-Story Dependencies

- Done: every story except 10.27 (open) and 10.18 (declined).
- 10.40 (done) is UI-only and fixed what 10.33, 10.35, 10.38 and 10.39 built: opaque pinned diff backings, context menus that close on any outside click (`ZsMenuAnchor` in `packages/zanshin_ui`), a right-click without a line menu that opens nothing, the Split composer when every change is picked, Open in Editor at a line past the file's end on disk, and the effective context-lines value. Its DS `MenuButton` change goes through the `design-artifacts` skill; the publish waits for a console session.
- Since 10.40 every `ZsMenuAnchor` closes on any click outside its panel, the anchor's own area included; the click is consumed (a second right-click opens the next context menu), and a click in the anchor area returns focus to the opener.
- 10.33 reuses 10.36's menu button and its grouped, checked menu, and picks whole parts from 10.38.
- 10.27 builds on 10.10's drag engine, 10.24–10.26, 10.23, and backend 9.15, 9.31 (diff source) and 9.50.
- 10.39's editor detection reuses 9.36's login-shell PATH; 10.37 touches the project registry and Settings › Project (Epic 11).
- The Undo Timeline's operation view (10.29) reuses the inspector diff widget, so diff-header changes (10.33's options menu, 10.39's path copy) appear there too.
