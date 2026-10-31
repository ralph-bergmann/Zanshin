# Epic 10 Context: Commit-Graph View (Flutter UI)

<!-- Generated from planning artifacts. Regenerate with compile-epic-context if planning docs change. -->

## Goal

Build Zanshin's main view: a commit graph that owns the window, with commit cards at data-computed positions (several cards per row), routed edges behind them, the gold lineage of @, hover focus paths, and two-axis virtualized scrolling and pan-by-drag over 10k–100k commits. Around it float the graph's controls, an inspector for the selected change, bookmarks, search, an operation toast, and drag-and-drop, all driving the shipped `zanshin_core` bridge. Claude builds it (scope exception, later widened to the whole UI); Ralph reviews every story.

## Stories

- Story 10.0: Record the Epic 10 scope exception (done)
- Story 10.1: Graph viewport, two-axis virtualized canvas (done)
- Story 10.2: Canvas and Free's day axis (done)
- Story 10.3: Commit cards (done)
- Story 10.4: Graph edges, router B (done)
- Story 10.5: Graph view model and repository wiring (done)
- Story 10.6: Selection, hover focus, callout, @ locator, keyboard (done)
- Story 10.7: Graph controls in the floating top bar
- Story 10.8: Inspector
- Story 10.9: Action runner (done)
- Story 10.10: Drag-and-drop on the graph
- Story 10.11: Content paging (done)
- Story 10.12: Adopt the backend layout (real `GraphSource`)
- Story 10.13: Time-layout lab, experiment (decided)
- Story 10.14: Bookmarks in the floating rail
- Story 10.15: Card action menu and bookmark popover
- Story 10.16: Minimap
- Story 10.17: Commit stacks
- Story 10.18: AI stack titles (declined)
- Story 10.19: Hidden history (gap markers, end stubs, gap callout)
- Story 10.20: Graph animations
- Story 10.21: Graph search
- Story 10.22: jj log Configurations window
- Story 10.23: Operation toast
- Story 10.24: Inspector diff view
- Story 10.25: Commit/split composer, file level
- Story 10.26: Hunk selection
- Story 10.27: Drag files and hunks onto a change

## Requirements & Constraints

- Scale: 10k–100k commits; extents and scrollbars exact before the first card is built; nothing measured from widgets.
- Layout modes: Free (default, y from compressed commit time, each child at least one pitch above its parents) and Compact (row = longest-path depth). Time modes are dropped. Lane order `compact` by default, greedy as alternative; no `optimized`, no user lane-order control.
- Intended deviations from the design that stay: crossing bridges always on; go-to-change pulse; a stack toggle never moves a column (columns from the ungrouped layout); runs of mutable ancestors of @ start expanded.
- Hidden history: marker family "Break" (`//`) on gaps and ends, no counts anywhere; markers keep 12 px of line to every card; a hidden merge gets one shared marker.
- Immutable changes: 135° hatch (`--hatch`), no glyph or colour; the ◆ is retired; menus offer only rows that leave the change untouched.
- Every jj command shown in UI text exists in jj v0.46.0 exactly as written, in full with the change id, shell-quoted. The UI never composes a sequence of commands.
- The design export is inspiration, not a 1:1 template: small gaps get a Claude proposal Ralph can overrule; NEEDS DESIGN questions are reserved for architecture or scope choices and are answered before building. A decision recorded in the epic wins over the export, except where Ralph ruled the floating client's explicit change wins. Where the design does not fit jj, resolve it along jj's behaviour in the owning story.
- Prototype defects listed in the epic are never copied; each names its owning story.
- Done = `cargo make test` green (flutter test, `dart analyze --fatal-infos`, format, …) plus a Marionette visual check in the Widgetbook catalogue against DS cards. Coverage is Rust-only, so each story's named widget tests are the safety net.

## Technical Decisions

- **The view never lays out the graph.** It consumes an abstract `GraphLayout` via accessors (node key, column, row in 1/U pitch units, view facts, lazy content; edges child/parent/kind/shape; @; counts; op id) and only maps to pixels. `GraphMetrics` maps columns to x (no gutter, offX 0); a `VerticalLayout` (`UniformRows`, `PerNodeTops` for fixtures) maps nodes to y. Visible sets come from a y-sorted index and an interval index over edges.
- Rows and columns are independent of card size, so a layout is requested once per operation, never on resize. Router B's pixel geometry (one line per parent→child pair, fan-out exits, tracks, gutter detours) comes from `zanshin_core`'s router per card size (Story 4.15).
- Viewport: `TwoDimensionalScrollView` with a custom `RenderTwoDimensionalViewport`; the viewport paints background and edges; cards are lazy widgets whose body is a `RenderBox` with text slots (no nested Column/Row for designed visuals).
- Ports: the view model declares `GraphSource` (layout) and `GraphActions` (runner); unfinished backends are wired as fakes until their story lands. 10.10 runs on a fake `drop_actions` port.
- Scroll precedence: explicit reveal (bookmark pick, locate @, go-to) beats re-centre on @ after a revset/layout switch, which beats the anchor. Panels float over the graph; reveals centre in the area the chrome leaves free.
- Backend boundary (ADR-0003): the UI never composes jj operations; it pre-fills every API parameter from the effective config and passes it explicitly. Missing CLI parameters are backend gaps. Interactive verbs take a GUI-supplied `TreeId` (`select_tree`).
- Code in `app/lib/src/features/graph/`, tests mirrored in `app/test/features/graph/`. The app imports only `package:zanshin_core/zanshin_core.dart`; a `[UI/bridge]` story adds the types it consumes to that library's `show` list.
- Controls come from the Zs library (`packages/zanshin_ui`), never Material/Yaru; remaining Material types only from `package:material_ui`. Text entry is an undecorated `TextField`.
- Theme: tokens from the design system (`_bmad-output/implementation-artifacts/design_system/`, tokens and CSS win over its prose). `GraphTheme` is a `ThemeExtension` (night, paper) deriving from the token layer; `GraphTheme.of` falls back to night. Selection, focus, drop targets, pulse and flash use the accent role (`--accent*`, `--focus-ring`); gold = @ and the one primary action. Each story records "DS synced through #N"; nothing under `design/` or `design_system/` is edited by stories.
- Strings go through the ARB (`app/lib/l10n/app_en.arb`, `packages/zanshin_ui/lib/l10n/zs_en.arb`); jj's own words, the product name and symbols are literals marked `// l10n-ignore: <reason>`.
- Tests: scroll physics under `TargetPlatformVariant.only(TargetPlatform.macOS)`; no golden tests; real-cdylib widget tests wrap worker/watcher I/O in `tester.runAsync`; app tests never call a jj config verb for real; icon-painting tests load the `IconRegistry` in a shared `setUpAll`.

## UX & Interaction Patterns

- Floating chrome on glass islands: top bar (Place · View · Action: project capsule, search field, gap legend, count, View options with Layout / Detailed cards / Group stacks / Card width, Fetch, Push, gold "New change"); rail with Bookmarks (Workstreams dropped, Reviews hidden); @ "Working copy" pill when @ is off-screen; minimap; calm scrolling.
- Cards: detailed (62 px) and compact (40 px), width 160–400; ••• and right-click menu (last group Revert · Abandon); peek callout after a hover delay, flipping against the unobscured area, suppressed while any menu is open or during pans and drags. Bookmark legend pill at most W/2 − 34 px, painted above edges.
- Keyboard: one roving focus node, not a tab stop per card; Esc is scoped, never a window-level listener.
- Motion (FLIP): moved cards glide 460 ms with the operation's anchor still; a born change grows from its anchor (540 ms); edges hide and fade back in 260 ms; the changed card flashes an accent ring for 2.4 s. Reduce motion works by property: movement goes to 0, colour/opacity fades keep their tokens.
- Inspector: 460 px glass island, describe in place (saves the CLI's `-m` paragraphs, draft per change for the session), file list, diff, composer. Drag-and-drop: menu after a 260 ms rest on a card target, plain drop runs the default row (its command shown under the ghost), ⌥ makes `rebase -r` the default, only applicable rows listed.
- Search replaces the revset dropdown: one menu with jj log variants, Go to, Filter by, async capped counts (zero rows dimmed), Recent per repository; the `jj log` built-in is always the effective `revsets.log`, never written by the UI.

## Cross-Story Dependencies

- Backend: 10.12 needs 4.10 (topology, view facts, timestamps), 4.11 (layout), 4.12 (wire and lazy view), 4.13 (stacks), 4.14 (shared columns), 4.15 (router B). Search needs 9.25; inspector needs Epic 5's line-level diff and 9.15, 9.49, 9.50; drag-and-drop rows need 9.31, 9.16, 9.9, 9.19, 9.48; 10.14's full rows need 9.29.
- Epic 11: 11.1 (tokens) and 11.2 (glass) precede floating surfaces; 11.11 (Zs controls, Widgetbook) precedes 10.7 and every later control user; 11.12 (window foundation) precedes 10.22; 11.13 (menu bar) follows 10.9 and 10.23 and binds the shortcuts of 10.6, 10.7, 10.9; 11.3 gives 10.23 its slot.
- Within the epic: 10.7 after 10.2/10.3/10.5/10.6; 10.8 after 10.5/10.6; 10.15 after 10.8/10.9; 10.10 after 10.9/10.15; 10.14 after 10.5/10.6/10.7; 10.16 after 10.1/10.4–10.6; 10.17 after 10.1/10.3/10.5/10.6; 10.19 after 10.4–10.7; 10.20 after 10.1/10.3/10.4/10.5/10.17; 10.21 after 10.5/10.6/10.11; 10.22 after 10.21/11.12/11.11; 10.23 after 10.9; 10.24 after 10.8 + Epic 5; 10.25 after 10.8/10.9/9.15/9.49; 10.26 after 10.24/10.25/9.50; 10.27 after 10.10/10.26.
