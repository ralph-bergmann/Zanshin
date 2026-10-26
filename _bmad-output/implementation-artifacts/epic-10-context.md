# Epic 10 Context: Commit-Graph View (Flutter UI)

<!-- Generated from planning artifacts. Regenerate with compile-epic-context if planning docs change. -->

## Goal

Build the app's main view: the commit graph that owns the window, with every other control floating above it. Commit cards sit at positions computed from data (several per row), rounded orthogonal edges run behind them, and the canvas scrolls and pans smoothly on both axes over 10k–100k commits. On top come selection, hover focus path, the @ lineage, the inspector, card menus, search, drag-and-drop and animations. The view stays anchored on the same commit when jj re-derives the graph after any operation. It is the user's primary way to read and edit a jj repository.

## Stories

- Story 10.0: Record the scope exception (done)
- Story 10.1: Graph viewport — 2D virtualized canvas, `GraphLayout` contract, extents from data, pan-by-drag
- Story 10.2: Window canvas and Free's day axis
- Story 10.3: Commit cards (detailed / compact)
- Story 10.4: Graph edges (router B lines, dashed, bridges, @ lineage)
- Story 10.5: Graph view model and repository wiring
- Story 10.6: Selection, hover focus, callout, @ locator, go-to, keyboard
- Story 10.7: Graph controls in the floating top bar
- Story 10.8: Inspector panel
- Story 10.9: Action runner
- Story 10.10: Drag-and-drop on the graph
- Story 10.11: Content paging
- Story 10.12: Adopt the backend layout
- Story 10.13: Time-layout lab (experiment, decided)
- Story 10.14: Bookmarks in the floating rail
- Story 10.15: Card action menu and bookmark popover
- Story 10.16: Minimap
- Story 10.17: Commit stacks in the view
- Story 10.18: AI stack titles (declined)
- Story 10.19: Hidden history (gap markers, end stubs)
- Story 10.20: Graph animations
- Story 10.21: Graph search
- Story 10.22: jj log Configurations window
- Story 10.23: Operation toast
- Story 10.24: Inspector diff view
- Story 10.25: Commit/split composer, file level
- Story 10.26: Hunk selection
- Story 10.27: Drag files and hunks onto a change

## Requirements & Constraints

- **Scale:** two-axis scrolling and pan over 10k–100k commits; extents exact before any card is built; only visible cards (± `scrollCacheExtent`, default 250 px) are mounted.
- **The view never lays out the graph.** Rows, lanes, columns, route classes, day buckets and every y come from the source (recorded layouts now, the 4.11 engine via 10.12 later). A hard-invariant failure on engine output is an engine bug to report, never patched in the view.
- **CLI-exact semantics:** which commits/edges, @, bookmarks and every verb follow jj; the layered layout is presentation only. The UI never composes jj operations; it pre-fills CLI parameters from the effective config and passes them explicitly. Any jj command shown in UI text exists in jj v0.46.0 exactly as written, shown in full with the change id and shell-quoted.
- **Layout modes (decided):** Free (default; y from compressed commit time, U = 16) and Compact (dependency depth, U = 1). Time, Time+gaps and `optimized` lane order are dropped. Lane order: `compact` default, greedy alternative — a request knob and catalogue option, not a user control.
- **Accessibility:** VoiceOver semantics are part of the view; cache-extent cards must report hidden. Reduce motion works by property: movement/size/position go to 0 (an animated reveal jumps), colour and opacity keep their tokens.
- **Definition of done:** `cargo make test` green (flutter test, `dart analyze --fatal-infos`, format). Dart lines are not coverage-measured, so each story's named witnesses are the only safety net. Before "done", Claude visually checks the change in the Widgetbook catalogue via Marionette and compares with the DS cards.

## Technical Decisions

- **Hosts (decision (e) of 2026-10-14, answered by decisions 16.29/16.30):** no demo-host `main*.dart`. The fake-data demo host for all Epic 10 visual review is the **"Graph" folder of the one Widgetbook 3.25.0 catalogue** (`app/widgetbook/main.dart`, pinned exactly; already exists from 11.11). Every `GraphViewOptions` field is a knob of its use cases; slow motion = Widgetbook's TimeDilation addon with an explicit `// ignore: experimental_member_use` plus a `// WHY:` line. The catalogue's `appBuilder` is the app's root-scope widget, so the Graph folder gets the app theme. The Graph folder must pump every use case without exception (part of the catalogue smoke test). Use cases are opened by agents through `zanshinCatalogue.open` (`path=graph/...`).
- **Code homes:** `app/lib/src/features/graph/`, tests mirrored in `app/test/features/graph/`. The POC (`app/lib/src/features/graph_poc/`, `app/lib/main4.dart`) is reference only, untouched. The app imports only `package:zanshin_core/zanshin_core.dart` (add consumed types to its `show` list = `[UI/bridge]`); Zs controls and the token layer come from `package:zanshin_ui/zanshin_ui.dart` (`packages/zanshin_ui/lib/src/design/`).
- **No Material/Yaru visible controls.** Remaining Material types (`MaterialApp`, `ThemeData`) come from `package:material_ui` only (its `ThemeMode` is not Flutter's). Designed visuals are a `RenderBox` with text slots, not nested `Column`/`Row`.
- **Theme:** `GraphTheme` `ThemeExtension` (`night`/`paper`) holds only graph roles, derived from the token layer (no colour typed twice); registered once through the app theme; `GraphTheme.of(context)` falls back to `night`, never force-unwraps. Canvas = window-fixed `--canvas` (flat fallback `--canvas-base`), no dot grid. Selection/focus/pulse/flash use the accent role (`--accent*`, `--focus-ring`); gold = @ and the one primary action; never legacy blue #3b82f6. DS tokens/CSS win over DS prose and cards; a decision recorded in the epic wins over the DS/export.
- **`GraphLayout` contract:** app-side abstract immutable interface, one per layout, read only through accessors (10.12 swaps the backing store). Mode/`unit`/`rows` (= max row + U)/`colCount`; per node key, col, row in 1/U pitch units (row 0 = oldest, at the bottom; newest at the top), nullable timestamp, view facts (incl. app-side `GraphRef`, `parentCountOf` = real parent count incl. Missing), nullable content; per edge child, parent, kind (direct | indirect), shape; CSR ranges; elided flag; buckets; `workingCopyIndex`; counts; nullable `operationId`. Node key = change id, or commit id when hidden/divergent; no synthetic keys. Consumers may add accessors, never backing objects.
- **Pixels:** `GraphMetrics` (x): W 160–400 (default 240), H 62 detailed / 40 compact, gapX 56, gapY 48, pad 56, radius 10; offX = 0 in both modes (no gutter); width = 2·pad + colCount·(W+gapX) − gapX. `VerticalLayout` (y): `UniformRows` top = pad + (rows − U − row)·(H+gapY)/U, plus `PerNodeTops` for hand fixtures; visible query via a sorted top index + binary search (no row arithmetic). W/H never change rows or columns, so a resize is an O(n) remap, never a layout request (router geometry re-runs only once 4.15 lands).
- **Viewport mechanics:** `TwoDimensionalScrollView` + custom `RenderTwoDimensionalViewport` overriding `layoutChildSequence` only; custom `TwoDimensionalChildDelegate` (key on outermost widget, `KeepAlive(RepaintBoundary(card))` for pinning, versioned `shouldRebuild`, no per-build closures); own clip layer and paint order background → edges → cards (z: base, @, selected, hovered) → overlay; reverse-paint-order hit testing; `DiagonalDragBehavior.weightedEvent`; canvas-only primary-mouse pan; no scrollbars (the minimap is the scroll indicator); arrow cursor everywhere, `grabbing` only while panning. Anchor (key + viewport offset, both axes) re-applied via `correctBy` on reloads, card-size changes and live inset changes (a left-inset change shifts the offset in the same frame, so no card moves; flyouts change no inset). Reveal key beats re-centre on @ beats anchor. Viewport must later support 10.20's FLIP: per-key x/y paint parameters, previous-layout nodes kept mounted, hideable edge layer.
- **Fake data:** recorded layouts from the A/B spike (`spikes/graph-layout-ab`, tools under `tools/`), never an engine in the view. Sources: the design sample (`inputs/design-e243dd2-{default,all}.json`, 52 commits, plus a CLI-faithful 13-commit variant), scale dumps (medium-1k, large-10k) and synthetic 10k/50k/100k, and `free` outputs (U = 16). Only small records/excerpts are committed; large ones are generated locally/in test setup. A test/debug invariant checker gates every fixture: unique keys, no dangling edge, no duplicate (child, parent), child ≥ parent + U, no overlapping cards in a column.
- **Backend facts (Epic 4, done):** 4.10 `graph_topology` = index-only whole-revset topology with jj's Direct/Indirect/Missing edges, real parent counts, optional committer timestamps (needed by Free, i.e. every default layout), the loaded operation id; `commitContents` = lazy, op-pinned content by commit id. 4.11 = Dart layout engine on the worker isolate (`packages/zanshin_core/lib/src/graph_layout/`, modes free | compact, orders greedy | compact; spec in `docs/graph-layout.md`, output §3: rows in 1/U units, Missing edges not in output, `free` emits day buckets in 1/U units), via `RepoHandle.graphLayout` (not yet exported from the barrel). 4.12 = topology wire + lazy `GraphTopologyView` with id → index lookups, one copy across isolates. 4.13 = stacks in the engine (grid v2 with `runs`; columns from the ungrouped layout, vertical compaction only).
- **Ports:** 10.5 declares `GraphSource` and `GraphActions`; stories ahead of their real implementation wire fakes.
- **Tests:** explicit 800×600 surface at dpr 1, reset in tearDown; scroll physics under `TargetPlatformVariant.only(TargetPlatform.macOS)`; no golden tests; paint order via the `paints` matcher; agents drive UI by Semantics identifier or text, never coordinates; icon-painting widget tests load `IconRegistry` in a shared `setUpAll` (`tester.runAsync`); app tests never call a jj config verb for real.

## UX & Interaction Patterns

- Floating chrome (top bar, rail with pinnable panels, inspector, minimap, @ pill) floats over the graph; the plane gets margins from live, resizable insets so every card can scroll clear of it. Reveals centre in the unobscured area.
- Free's day axis: labels on dashed dividers at the left edge, horizontally sticky; no gutter, no fade.
- Edges: router B (one line per parent → child pair), dashed indirect edges with `//` gap markers (no counts), crossing bridges always on, gold @ lineage.
- A stack toggle never moves a column. The design is inspiration, not a 1:1 template: small gaps get a marked Claude proposal; NEEDS DESIGN only for architecture/scope choices. Points where the design does not fit jj are resolved along jj in the owning story.
- Esc and shortcuts are scoped (no window-global listeners); shortcuts are bound in 11.13.

## Cross-Story Dependencies

- 10.1 comes first (viewport, `GraphLayout`, `VerticalLayout`, recordings, Graph catalogue folder); 11.1 (tokens) and 11.11 (catalogue, controls) are already done.
- 10.2, 10.3, 10.4 run in parallel on recordings; 10.5 any time after 10.1; 10.6 after 10.3 + 10.4; 10.7 after 10.2/10.3/10.5/10.6; 10.8 after 10.5/10.6; 10.9 after 10.3/10.5; 10.15 after 10.8/10.9; 10.10 after 10.9/10.15 on a fake `drop_actions` port.
- 4.14 (shared Free/Compact columns, adds invariant I8) and 4.15 (router B library) precede 10.4's real geometry and 10.12; 10.12 adopts 4.10–4.13 for real data.
- 10.17 needs 4.13 recordings; 10.19 and 10.20 follow 10.4/10.5 (+10.17 for 10.20); 10.21/10.22 need 9.25; 10.22 needs 11.12 (own window); 10.23 follows 10.9; 10.24–10.27 need Epic 5 diff and 9.15/9.49/9.50/9.31.
