# Epic 10 Context: Commit-Graph View (Flutter UI)

<!-- Generated from planning artifacts. Regenerate with compile-epic-context if planning docs change. -->

## Goal

Build Zanshin's main view: a commit graph that owns the window, with commit cards at data-computed positions (several cards per row), routed edges behind them, the gold lineage of @, hover focus paths, and two-axis virtualized scrolling and pan-by-drag over 10k–100k commits. Around it float the graph's controls, an inspector for the selected change (describe, diff, composer), bookmarks, search and its jj log Configurations window, an operation toast, a minimap and drag-and-drop, all driving the shipped `zanshin_core` bridge. Claude builds it (scope exception, later widened to the whole UI); Ralph reviews every story.

## Stories

- Story 10.0: Record the Epic 10 scope exception (done)
- Story 10.1: Graph viewport, two-axis virtualized canvas (done)
- Story 10.2: Canvas and Free's day axis (done)
- Story 10.3: Commit cards (done)
- Story 10.4: Graph edges, router B (done)
- Story 10.5: Graph view model and repository wiring (done)
- Story 10.6: Selection, hover focus, callout, @ locator, keyboard (done)
- Story 10.7: Graph controls in the floating top bar (done)
- Story 10.8: Inspector (done)
- Story 10.9: Action runner (done)
- Story 10.10: Drag-and-drop on the graph (backlog)
- Story 10.11: Content paging (done)
- Story 10.12: Adopt the backend layout, reload button (done)
- Story 10.13: Time-layout lab, experiment (done, outcome decided)
- Story 10.14: Bookmarks in the floating rail (done)
- Story 10.15: Card action menu and bookmark popover (done)
- Story 10.16: Minimap (backlog)
- Story 10.17: Commit stacks (done)
- Story 10.18: AI stack titles (declined)
- Story 10.19: Hidden history (done)
- Story 10.20: Graph animations (done)
- Story 10.21: Graph search (done)
- Story 10.22: jj log Configurations window (done)
- Story 10.23: Operation toast (done)
- Story 10.24: Inspector diff view (done)
- Story 10.25: Commit/split composer, file level (done)
- Story 10.26: Hunk selection through a GUI tree (backlog)
- Story 10.27: Drag files and hunks onto a change (backlog)
- Story 10.28: Raw revset rule in the jj log Configurations window (backlog)
- Story 10.29: Operation diff view, Show changes in the Undo Timeline (backlog)

## Requirements & Constraints

- Scale: 10k–100k commits; extents and scrollbars exact before the first card is built; nothing measured from widgets.
- Layout modes: Free (default; y from compressed commit time, each child at least one pitch above its parents) and Compact (row = longest-path depth). Lane order `compact` by default, greedy as alternative; no `optimized`, no user lane-order control.
- Intended deviations from the design that stay: crossing bridges always on; go-to-change pulse; a stack toggle never moves a column; runs of mutable ancestors of @ start expanded.
- Hidden history: marker family "Break" (`//`), no counts anywhere; markers keep 12 px of line to every card; a hidden merge gets one shared marker.
- Immutable changes: 135° hatch (`--hatch`), no glyph or colour; menus offer only rows that leave the change untouched (exactly the verbs jj refuses are left out).
- Every jj command shown in UI text exists in jj v0.46.0 exactly as written, in full with the change id, shell-quoted. The UI never composes a sequence of commands.
- Behave like the CLI: parse, resolve and refuse as jj does; show jj's own error text (e.g. `jj.revset_parse_error`, `jj.revset_resolution_error`, `jj.jj_lib_error`) in place. Where the design does not fit jj, resolve it along jj's behaviour in the owning story (Claude's proposal, no question to Ralph).
- Hunk selection offers everything the CLI's builtin diff editor offers: mode changes get their own row, conflicted files get per-section checkboxes.
- Refresh: window focus plus an explicit reload button (and View › Reload ⌘R), both coalesced; no timer, no file watcher.
- Workstreams dropped; Reviews hidden. The app is English but l10n-ready.
- The design export is inspiration, not a 1:1 template: small gaps get a Claude proposal Ralph can overrule; NEEDS DESIGN questions are only for architecture or scope. A decision recorded in the epic wins over the export, except where Ralph ruled the floating client's explicit change wins. Prototype defects listed in the epic are never copied.
- Done = `cargo make test` green (flutter test, `dart analyze --fatal-infos`, format, …) plus a Marionette visual check in the Widgetbook catalogue against full-size DS card renders (Marionette cannot hover, so hover-only surfaces need an "open" use case). Coverage is Rust-only; each story's named widget tests are the safety net.

## Technical Decisions

- **The view never lays out the graph.** It consumes `GraphLayout` via accessors (node key, column, row in 1/U units, view facts, lazy content, edges with kind/shape, @, counts, op id) and only maps to pixels: `GraphMetrics` for x (no gutter, offX 0), a `VerticalLayout` for y. Router B's pixel geometry comes from `zanshin_core`'s router per card size. A layout is requested once per operation, never on resize.
- View preferences persist through `GraphPreferences` over `AppSettings.graph`.
- Viewport: `TwoDimensionalScrollView` with a custom `RenderTwoDimensionalViewport`; designed visuals are a `RenderBox` with text slots, not nested Column/Row.
- Ports: `GraphSource` (layout), `GraphActions` (runner), `GraphDetails` (inspector: `show` + `changeActions`). Unlanded backends are fakes; 10.10 runs on a fake `drop_actions` port.
- Scroll precedence: explicit reveal beats re-centre on @ after a revset/layout switch, which beats the anchor. Panels float; reveals centre in the area the chrome leaves free.
- Backend boundary: the UI never composes jj operations; it pre-fills every API parameter from the effective config and passes it explicitly. Missing CLI parameters are backend gaps. Interactive verbs take a GUI-supplied `TreeId` (`select_tree`). Diff read: `RepoHandle.diff` (`Diff` → `FileDiff` → `Hunk` → `HunkLine`, per-file `fingerprint`); operation contents: `RepoHandle.opShow`. Revset text comes from `zanshin_core`'s builders (join / not), passed verbatim.
- Code in `app/lib/src/features/graph/`, tests mirrored in `app/test/features/graph/`. The app imports only `package:zanshin_core/zanshin_core.dart`; a `[UI/bridge]` story adds the types it consumes to that library's `show` list. The old POC is removed (read it at `8bd1c34b` if needed).
- Controls come from the Zs library (`packages/zanshin_ui`), never Material/Yaru; remaining Material types only from `package:material_ui`. Text entry is an undecorated `TextField`.
- Theme: tokens from the design system (`_bmad-output/implementation-artifacts/design_system/`; tokens and CSS win over its prose). `GraphTheme` (`ThemeExtension`, night/paper) derives from the token layer and falls back to night. Selection, focus, drop targets, pulse and flash use the accent role (`--accent*`, `--focus-ring`); gold = @ and the one primary action; moon as data (`--hunk`, `--status-m`, `--remote`) stays fixed. Each story records "DS synced through #N"; stories never edit `design/` or `design_system/`.
- Strings go through the ARB (`app/lib/l10n/app_en.arb`, `packages/zanshin_ui/lib/l10n/zs_en.arb`; run `flutter gen-l10n` after an edit and commit the generated files); jj's own words, the product name and symbols are literals marked `// l10n-ignore: <reason>`.
- Tests: scroll physics under `TargetPlatformVariant.only(TargetPlatform.macOS)`; no golden tests; real-cdylib widget tests wrap worker/watcher I/O in `tester.runAsync`; app tests never call a jj config verb for real; icon-painting tests load the `IconRegistry` in a shared `setUpAll`.

## UX & Interaction Patterns

- Floating chrome on glass islands: top bar (Place · View · Action: project capsule, search field, gap legend, count, View options, Fetch, Push, reload, gold "New change"); rail with Bookmarks and Undo Timeline; @ "Working copy" pill when @ is off-screen; minimap (134 px glass card on the right, dots with day labels, current-day pill, viewport band, click-and-drag); calm scrolling.
- Cards: detailed (62 px) and compact (40 px), width 160–400; ••• and right-click menu; peek callout after a hover delay, flipping against the unobscured area, suppressed while any menu is open or during pans and drags.
- Keyboard: one roving focus node, not a tab stop per card; Esc is scoped, never a window-level listener.
- Motion (FLIP): moved cards glide 460 ms with the anchor still; born change grows from its anchor (540 ms); edges fade back in 260 ms; flash 2.4 s. Reduce motion zeroes movement only; colour/opacity fades keep their tokens.
- Inspector: 460 px glass island; describe in place; file list; diff (±, Unified / Side by side, Viewed per repository keyed by fingerprint); composer. Selected hunks use `--accent-soft-hi` plus a 2 px `--accent-line` edge; unselected headers stay `--hunk-bg`; hunk checkboxes are the Zs Checkbox with the mixed dash, the hunk is a Tab stop and Space toggles it.
- Drag-and-drop: menu after a 260 ms rest on a card target, a plain drop runs the default row (its command shown under the ghost), ⌥ makes `rebase -r` the default, only applicable rows listed.
- Search: one menu with jj log variants, Go to, Filter by, async capped counts (zero rows dimmed), Recent per repository; the `jj log` built-in is always the effective `revsets.log`, never written by the UI. Configurations window: structured rules plus (10.28) a raw "Revset" rule mixed in via the same builder, errors and "did you mean" candidates shown at the rule's row, the raw text verbatim in the command preview.
- Operation diff (10.29): Show changes in the Undo Timeline opens `jj op show <id>`'s changed commits with before/after and a per-commit diff reusing 10.24's view, without Viewed marks; Esc returns to the list; refusals show jj's text in place of the diff.

## Cross-Story Dependencies

- Open stories: 10.10 after 10.9/10.15, real rows from 9.31, 9.16, 9.9, 9.19, 9.48. 10.16 after 10.1/10.4–10.6 and 11.13; its raster path needs no backend story. 10.26 after 10.24/10.25, 9.50 and 11.11. 10.27 after 10.10/10.26 (a `diff` source in 9.31). 10.28 after 10.22 and 9.25 (its `NoSuchFunction` candidates); related to 10.21. 10.29 after 11.9, 10.24 and 9.21 (`op_diff`); related to 10.23.
- Epic 11: 11.11 (Zs controls, Widgetbook) precedes every control user; 11.13 (menu bar) binds this epic's shortcuts and View › Reload; 11.9 owns the Undo Timeline that 10.29 extends.
