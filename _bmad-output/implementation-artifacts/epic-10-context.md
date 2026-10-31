# Epic 10 Context: Commit-Graph View (Flutter UI)

<!-- Generated from planning artifacts. Regenerate with compile-epic-context if planning docs change. -->

## Goal

Build the app's main view: the commit graph that owns the window, with every other control floating above it. Commit cards sit at positions computed from data (several per row), rounded orthogonal edges run behind them, and the canvas scrolls and pans smoothly on both axes over 10k–100k commits. On top come selection, hover focus path, the @ lineage, the inspector, card menus, search, drag-and-drop and animations. The view stays anchored on the same commit when jj re-derives the graph after any operation. It is the user's primary way to read and edit a jj repository.

## Stories

- Story 10.0: Record the scope exception (done)
- Story 10.1: Graph viewport — 2D virtualized canvas, `GraphLayout` contract, extents from data, pan-by-drag (done)
- Story 10.2: Window canvas and Free's day axis (done)
- Story 10.3: Commit cards (detailed / compact) (done)
- Story 10.4: Graph edges (router B lines, dashed, bridges, @ lineage) (done)
- Story 10.5: Graph view model and repository wiring (done)
- Story 10.6: Selection, hover focus, callout, @ locator, go-to, keyboard (done)
- Story 10.7: Graph controls in the floating top bar
- Story 10.8: Inspector panel
- Story 10.9: Action runner (done)
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
- **The view never lays out the graph.** Rows, lanes, columns, route classes, day buckets and every y come from the source (recorded layouts now, the engine via 10.12). Pixel route geometry comes from `zanshin_core`'s router, never from view code. A hard-invariant failure on engine output is an engine bug to report, never patched in the view.
- **CLI-exact semantics:** which commits/edges, @, bookmarks, immutability and every verb follow jj; the layered layout is presentation only. The UI never composes jj operations or command sequences; it pre-fills CLI parameters from the effective config and passes them explicitly. Any jj command shown in UI text exists in jj v0.46.0 exactly as written, shown in full with the change id and shell-quoted. Where the design does not fit jj, the owning story resolves it along jj as Claude's proposal.
- **Layout modes (decided):** Free (default; y from compressed commit time, U = 16) and Compact (dependency depth, U = 1), sharing one set of columns. Time, Time+gaps and `optimized` lane order are dropped. Lane order: `compact` default, greedy alternative — a request knob and catalogue option, not a user control.
- **Strings:** no hard-coded UI text. App strings go in `app/lib/l10n/app_en.arb` (`context.l10n`, or `platformStrings()` without a context), `zanshin_ui`'s in `packages/zanshin_ui/lib/l10n/zs_en.arb`; every entry has a key and description, ICU for plurals/placeholders, dates via `intl`. After an ARB edit run `flutter gen-l10n` in that package and commit the generated files. jj's own words (commands, errors, hints), the product name and pure symbols stay literals marked `// l10n-ignore: <reason>`; `app/test/l10n/hard_coded_strings_test.dart` fails on unmarked ones.
- **Accessibility:** VoiceOver semantics are part of the view; cache-extent cards report hidden. Reduce motion works by property: movement/size/position go to 0 (an animated reveal jumps), colour and opacity keep their tokens. Focus rings show for keyboard input only (app-wide `zsRingFollowsInput`; a pointer press hides them).
- **Definition of done:** `cargo make test` green (flutter test, `dart analyze --fatal-infos`, format). Dart lines are not coverage-measured, so each story's named witnesses are the only safety net. Before "done", Claude checks the change in the Widgetbook catalogue via Marionette and compares with the DS cards; surfaces shown only on hover get a use case that shows them open.

## Technical Decisions

- **Hosts:** no demo-host `main*.dart`. Visual review happens in the **"Graph" folder of the one Widgetbook 3.25.0 catalogue** (`app/widgetbook/main.dart`, pinned exactly). Every `GraphViewOptions` field is a knob; slow motion = Widgetbook's TimeDilation addon (explicit `// ignore: experimental_member_use` plus a `// WHY:` line). The catalogue's `appBuilder` is the app's root-scope widget; the Graph folder must pump every use case (catalogue smoke test). Agents open use cases via `zanshinCatalogue.open` (`path=graph/...`).
- **Code homes:** `app/lib/src/features/graph/`, tests mirrored in `app/test/features/graph/`. The POC was removed in 11.10; read it at revision `8bd1c34b8e3c048eab8b53a2d4ea4ef79ca38072` if needed. The app imports only `package:zanshin_core/zanshin_core.dart` (adding consumed types to its `show` list = `[UI/bridge]`); Zs controls, the token layer and `GraphTheme` come from `package:zanshin_ui/zanshin_ui.dart`.
- **No Material/Yaru visible controls.** Remaining Material types come from `package:material_ui` only (its `ThemeMode` is not Flutter's). Designed visuals are a `RenderBox` with text slots, not nested `Column`/`Row`.
- **Theme:** `GraphTheme` `ThemeExtension` (`night`/`paper`) holds only graph roles, derived from the token layer (no colour typed twice); `GraphTheme.of(context)` falls back to `night`. Canvas = window-fixed `--canvas`, no dot grid. Selection/focus/pulse/flash use the accent role (`--accent*`, `--focus-ring`; live-in-inactive-window things use `--accent-live-*`); gold = @ and the one primary action; never legacy blue. DS tokens/CSS win over DS prose and cards; a decision recorded in the epic wins over the DS/export. DS is synced through #15; a re-download with a higher number gets dated notes and token-layer updates in the next visual story.
- **Immutable commits:** no colour or glyph (the ◆ is retired); the card carries a 135° hatch (`--hatch`) in every state, stacks follow; `HatchSwatch` names it in peek, inspector, card menu. The immutable flag is `GraphLayout.isImmutable`; the reason is computed on demand with one `revsetCounts` call (cap 1) per term.
- **`GraphLayout` contract (shipped in 10.1):** abstract immutable interface read only through accessors (10.12 swaps the backing store). Node key = change id, or commit id when hidden/divergent; rows in 1/U pitch units, row 0 = oldest at the bottom. Consumers may add accessors, never backing objects. `GraphMetrics` (x: W 160–400 default 240, H 62/40, gapX 56, gapY 48, pad 56, radius 10, offX 0, no gutter) and `VerticalLayout` (`UniformRows`, `PerNodeTops` for hand fixtures; visible set via sorted tops + binary search). W/H never change rows or columns: a resize is an O(n) remap plus a router geometry re-run, never a layout request.
- **Viewport mechanics:** `TwoDimensionalScrollView` + custom `RenderTwoDimensionalViewport` (only `layoutChildSequence`); paint order background → edges → cards (z: base, @, selected, hovered) → overlay; reverse-paint-order hit testing; canvas-only primary-mouse pan; no scrollbars (the minimap is the indicator); arrow cursor, `grabbing` only while panning. Anchor (key + offset) re-applied via `correctBy` on reloads, card-size and inset changes. Scroll precedence: explicit reveal beats re-centre on @ beats anchor; reveals centre in the area the floating chrome leaves free. Must support 10.20's FLIP (per-key paint offsets, previous-layout nodes kept mounted, hideable edge layer).
- **Fake data:** recorded layouts from the A/B spike (`spikes/graph-layout-ab`, `tools/record-graph.mjs`) plus a synthetic scale generator; only small records are committed. A test/debug invariant checker gates every fixture.
- **Backend (Epic 4, done):** 4.10 index-only topology (Direct/Indirect/Missing edges, real parent counts, timestamps, operation id) + lazy op-pinned `commitContents`; 4.11 Dart layout engine on the worker isolate (`RepoHandle.graphLayout`); 4.12 topology wire + lazy `GraphTopologyView`; 4.13 stacks in the engine (columns from the ungrouped layout); 4.14 joint columns — a compact and a free request return the same lanes, columns and per-node day keys, timestamps load for every request; 4.15 router B library exported from the barrel (`RouteClasses` per layout without W/H, `RouteGeometry` per `RouteMetrics` in typed arrays, `RouteBridges` per window, counted reports for fallbacks/overfull gutters/clusters). Run it synchronously up to `routeSyncNodeLimit` (20,000 nodes), in `Isolate.run` above — never as a worker request.
- **Ports (shipped in 10.5):** `GraphSource` and `GraphActions`; stories ahead of their real implementation wire fakes (10.6 and 10.8 before 10.9; everything before 10.12; 10.10 on a fake `drop_actions` port).
- **Tests:** explicit 800×600 surface at dpr 1, reset in tearDown; scroll physics under `TargetPlatformVariant.only(TargetPlatform.macOS)`; no golden tests; paint order via the `paints` matcher; agents drive UI by Semantics identifier or text, never coordinates; icon-painting tests load `IconRegistry` in a shared `setUpAll` (`tester.runAsync`); real-cdylib widget tests wrap worker/watcher I/O in `tester.runAsync`; app tests never call a jj config verb for real.

## UX & Interaction Patterns

- Floating chrome (top bar, rail with pinnable panels, inspector, minimap, @ pill) floats over the graph; live, resizable insets give the plane margins so every card can scroll clear; pinning a panel shifts the offset by the inset change so no card moves.
- Free's day axis: labels on dashed dividers at the left edge, horizontally sticky; no gutter, no fade.
- Edges: router B (one line per parent → child pair), dashed indirect edges with `//` gap markers (no counts, 12 px of line to every card), crossing bridges always on, gold @ lineage.
- Motion: client FLIP on every operation (460 ms glide, 540 ms birth from the anchor, edges hide and fade back in 260 ms, accent flash 2.4 s).
- Card menu ends Revert · Abandon (Revert = `jj revert -r <change> -B @`); an immutable change's menu keeps only rows that leave it untouched.
- Drag ghost: `ZsDragGhost` already exists in `zanshin_ui` (kinds `project`, `group`); 10.10 adds `change`, `bookmark` and `diff`.
- A stack toggle never moves a column. The design is inspiration, not a 1:1 template: small gaps get a marked Claude proposal; NEEDS DESIGN only for architecture/scope choices.
- Esc and shortcuts are scoped (no window-global listeners); shortcuts are bound in 11.13.

## Cross-Story Dependencies

- Done and available: 10.1–10.6, 4.10–4.16 (4.16: Free keeps the band around a day divider card-free), 11.1 (tokens), 11.10 (POC removed), 11.11 (catalogue, controls), 11.15 (`ZsDragGhost`), 11.16 (ARB strings); 5.1 (line-level hunks, Rust `compute_hunks`) for the diff stories.
- 10.6 shipped selection (220 ms double-click window; double-click = `GraphViewModel.edit` on mutable cards), hover intent + `graphFocusSet` focus path, scoped Esc, the one-Tab-stop graph, the @ pill (`GraphView.atPill`), `GraphPeek` callout, public `ZsTooltipBubble`, and `GraphViewModel.goTo` (select, reveal centred, pulse; reveals beyond 3 viewports jump). Handed on: immutable-reason `revsetCounts` (11.7); peek description/commit id/loading (10.11/10.12); stack popover (10.17); gap callout and flash (10.19); search calling `goTo` (10.21); arrow keys and ⌘J/⇧⌘J (11.13); drag/hunk/describe Esc steps (10.10/10.26/10.8); inspector's covered-selection scroll (10.8); card/context menu content and the "Drag"/"Right-click" hint parts (10.15/10.10).
- 10.7 next, after 10.6 and 11.11; 10.8 after 10.5/10.6; 10.9 after 10.3/10.5; 10.15 after 10.8/10.9; 10.10 after 10.9/10.15; 10.11 after 10.3/10.5; 10.14 after 10.5/10.6/10.7 (full rows need 9.29); 10.16 after 10.6 and 11.13.
- 10.12 adopts 4.10–4.15 for real data; 10.17 needs 4.13 recordings; 10.19 follows 10.4–10.7; 10.20 follows 10.4/10.5/10.17; 10.21 after 10.5/10.6/10.11 and needs 9.25; 10.22 after 10.21, 11.11 and 11.12; 10.23 after 10.9; 11.13 follows 10.9 and 10.23; 10.24–10.27 need Epic 5's diff and 9.15/9.49/9.50/9.31.
