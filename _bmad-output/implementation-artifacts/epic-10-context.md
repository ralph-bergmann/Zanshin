# Epic 10 Context: Commit-Graph View (Flutter UI)

<!-- Generated from planning artifacts. Regenerate with compile-epic-context if planning docs change. -->

## Goal

Build Zanshin's main view: a commit graph that owns the window, with cards at data-computed positions (Free by default, Compact as the alternative), lines behind them, the gold lineage of @, hover focus paths, and smooth scrolling and panning over 10k–100k commits. Around it float the design system's controls: top bar, search and its jj log Configurations window, Bookmarks rail, minimap, card menus, an inspector (describe, diff, composer, hunk selection), drag-and-drop, motion and an operation toast with Undo. Every action runs a real jj verb through the shipped `zanshin_core` bridge and behaves like the jj CLI. Claude builds it; Ralph reviews every story.

## Stories

- Story 10.0: Record the Epic 10 scope exception (done)
- Story 10.1: Graph viewport, two-axis virtualized canvas (done)
- Story 10.2: Canvas and Free's day axis (done)
- Story 10.3: Commit cards (done)
- Story 10.4: Graph edges (done)
- Story 10.5: Graph view model and repository wiring (done)
- Story 10.6: Selection, hover focus, callout, @ locator, keyboard (done)
- Story 10.7: Graph controls in the floating top bar (done)
- Story 10.8: Inspector (done)
- Story 10.9: Action runner (done)
- Story 10.10: Drag-and-drop on the graph (done)
- Story 10.11: Content paging (done)
- Story 10.12: Adopt the backend layout (done)
- Story 10.13: Time-layout lab, experiment (done, outcome decided)
- Story 10.14: Bookmarks in the floating rail (done)
- Story 10.15: Card action menu and bookmark popover (done)
- Story 10.16: Minimap (done)
- Story 10.17: Commit stacks (done)
- Story 10.18: AI titles for commit stacks (declined)
- Story 10.19: Hidden history (done)
- Story 10.20: Graph animations (done)
- Story 10.21: Graph search (done)
- Story 10.22: jj log Configurations window (done)
- Story 10.23: Operation toast (done)
- Story 10.24: Inspector diff view (done)
- Story 10.25: Commit/split composer, file level (done)
- Story 10.26: Hunk selection through a GUI tree (done)
- Story 10.27: Drag files and hunks onto a change (backlog)
- Story 10.28: Raw revset rule in the Configurations window (done)
- Story 10.29: Operation diff view in the Undo Timeline (done)
- Story 10.30: Review findings 2026-11-02 (done)
- Story 10.31: Time axis and minimap for long histories (done)
- Story 10.32: Word marks in the inspector diff (done)
- Story 10.33: Ignore whitespace in the inspector diff (backlog)
- Story 10.34: Word marks differ in lightness, removed darker, added lighter (backlog)

## Requirements & Constraints

- **Behave like the jj CLI.** What the view shows and every verb must be CLI-exact; only the layered layout is presentation. Refusals show jj's own text, in the UI as one short sentence (kind, column, what jj expected), never jj's terminal rendering. Where the design does not fit jj, the owning story follows jj (Claude's proposal).
- **Every command is real.** A jj command in UI text must exist in jj exactly as written (the rule names v0.46.0; the pin is v0.47.0 since 2026-11-04): in full, with the change id, shell-quoted, `exact:` where a pattern needs it. The UI never composes a sequence of commands.
- **Scale.** The whole revset's geometry comes once per operation; card content loads lazily per visible page. Extents come from data, never from measured widgets. A card-size change never costs a layout request. Refresh happens on window focus and on an explicit reload (⌘R), coalesced; no timer, no file watcher.
- **Decisions that stay:** crossing bridges always on; the go-to pulse; a stack toggle never moves a column; mutable ancestors of @ start expanded; hidden history as `//` markers with no counts; an immutable change is a 135° hatch with no colour or glyph, and its menus drop exactly the rows jj refuses.
- VoiceOver semantics for the epic's own surfaces. English only, l10n-ready.
- **Done** = `cargo make test` green plus a Marionette check in the Widgetbook catalogue or the app against full-size DS card renders (a hover-only surface gets an "open" use case). Coverage is Rust-only, so each story's named witnesses are the safety net.

## Technical Decisions

- **The view never lays out the graph.** It reads `GraphLayout` through accessors and maps columns to x and nodes to y. The engine is in `packages/zanshin_core` (Dart, worker isolate; contract `docs/graph-layout.md`). Since 2026-11-10 each mode picks its own columns by branch (a mode switch re-centres on @, no transition), and lines follow the layout lab's rules instead of router B; a polyline has up to 8 points. In Free, card-free stretches taller than 3 pitches shrink to 1½ pitches; canvas, day axis, gap markers, scroll math and minimap share that one mapping.
- **Ports:** `GraphSource`, `GraphActions`, `GraphDetails`, `drop_actions`; tests run on fakes. Every verb runs through 10.9's runner (pending state, anchored reload, refusals, warnings, undo guard); outcomes go to 10.23's toast and 10.20's motion; the selection follows `MutationResult`.
- **Backend boundary (ADR-0003):** the UI never composes jj operations; it pre-fills every parameter from the effective config and passes it explicitly. Partial selections pass a tree id from `select_tree` (9.50), never `-i`; a hunk selection is a set of 9.50 keys, re-mapped after every reload. Revset text comes from `zanshin_core`'s builders, verbatim.
- **Diff data:** Rust computes, Dart draws. Since Story 5.10 (2026-11-12) the diff is `jj diff`'s default `:color-words` format: a `HunkLine` has a kind (context, removed, added, changed, conflict header), optional left and right line numbers, and `segments` (`Equal` / `Added` / `Removed`). A changed line holds removed and added words side by side. Settings come from the effective `diff.color-words.*` config. Story 5.9's line pairing is gone. No syntax colours, no own word-mark rules, no underline or strikethrough.
- **Code** in `app/lib/src/features/graph/`, tests mirrored under `app/test/features/graph/`. The app imports only `package:zanshin_core/zanshin_core.dart`; a `[UI/bridge]` story adds what it consumes to its `show` list. No import cycles between feature folders, and nothing under `lib/src/features/` imports `lib/src/app/` (guard test).
- **Controls** are the Zs library (`packages/zanshin_ui`), never Material or Yaru; text entry is an undecorated `TextField`. Designed visuals are a `RenderBox` with text slots, not nested `Column`/`Row`.
- **Theme:** tokens from `_bmad-output/implementation-artifacts/design_system/` (tokens and CSS win over prose), via `GraphTheme` (night, paper). Selection, focus, drop targets and the flash use the accent role (`--accent*`, `--focus-ring`; `--accent-live-*` where it must stay lit in an inactive window). Gold = @ and the one primary action. Data colours (`--hunk`, `--hunk-bg`, `--status-m`, `--remote`) stay fixed. A new token goes into DS `tokens/colors.css` and `ZsColors` together; the DS parity test fails the gate until both match.
- **Design sources** are edited in place (`design/`, `design_system/`) with a numbered entry in `design/DESIGN-SYSTEM-SYNC.md`, so no deviation is tracked (the header's older "re-download only" rule predates this). Claude republishes the DS with the `design-artifacts` skill. Each story records "DS synced through #N".
- **Strings** go through the ARB files (run `flutter gen-l10n`, commit the output); jj's words, the product name and symbols are literals marked `// l10n-ignore: <reason>`.
- **Tests:** scroll physics under `TargetPlatformVariant.only(TargetPlatform.macOS)`; no golden tests; real-cdylib tests wrap I/O in `tester.runAsync`; app tests never call a jj config verb for real; icon tests load the `IconRegistry` in a shared `setUpAll`.

## UX & Interaction Patterns

- Floating glass chrome over the graph: top bar (Place · View · Action), rail (Bookmarks, Undo Timeline), the @ pill, the minimap. The design is inspiration, not a 1:1 template: small gaps get a marked Claude proposal; NEEDS DESIGN is for architecture or scope.
- Cards: 40 / 62 px at the default density, width 160–400, ••• and right-click menu, a peek callout that stays shut while a menu is open or during pans and drags. One roving focus node; Esc is scoped, never window-level. Motion: FLIP on every operation; reduce motion zeroes movement only.
- **Inspector diff** (the Undo Timeline's operation view reuses the widget): unified rows show left number, right number, text. A removed or added line has the faint `--rem-bg` / `--add-bg` fill and its changed words on `--rem-word-bg` / `--add-word-bg` (full line height, under the text, glyphs in `--text`); a line whose unchanged text has no visible character keeps only the fill. A changed line has no fill, both numbers in colour, removed words on `--rem-word-bg`, added words on `--add-word-bg`. Hunk header on `--hunk-bg` / `--hunk`; a selected hunk on `--accent-soft-hi` with a 2 px `--accent-line` edge. Selecting read-only text paints only the highlight. Mode changes and conflict sections are selectable like hunks, as in jj's builtin diff editor.
- **Word-mark colour is the only cue** (Ralph, 2026-11-12): no underline, strikethrough or icon. Changed 2026-11-12 after Story 5.10: Story 10.34 changes only the values of the two word tokens so the removed and added fills differ in lightness (added lighter, removed darker, both themes), because on a changed line they differed by hue only. Rules, composited as drawn (word fill over `--code-bg` on `--fl-bg-solid`, plus the line fill on its own line): the two fills differ by at least 12 CIE L* on a changed line; `--text` keeps at least 4.5:1 on every fill; each fill differs by at least 8 L* from the surface under it. One test computes these from `ZsColors`. Exact values are Claude's inside the rules; Ralph reviews them in the catalogue.
- **Drag engine (10.10; 10.27 reuses it):** starts after 5 px; targets are cards only (stacks inert, no edge targets); the drop menu opens after a 260 ms rest and lists only available `drop_actions` rows, its footer naming the highlighted row's command. Previews are debounced and cached per operation; reloads wait until the drag ends; resize edges are inert; Esc cancels with no call. Since 2026-11-03 a change drag released before the menu opens runs nothing; once it is open, release runs the highlighted row (default first; with ⌥ `rebase -r`). A bookmark drag never opens the menu: release moves it, with `--allow-backwards` exactly when the move is not a fast-forward and a `--warn` line on the ghost.

## Cross-Story Dependencies

- **10.27** builds on 10.10, 10.23, 10.24, 10.26 and backend 9.15, 9.31 (selection payload) and 9.50, all done. Its text (2026-10-14/16) still says a plain drop runs the default row with the command under the ghost; 10.10's 2026-11-03 change for change drags came later, so decide which rule file and hunk drags follow.
- **10.33** builds on 10.24 and 10.32 (done); the backend's `-b` / `-w` support is done (`DiffWhitespace` in `zanshinDiff`), so it is UI and settings only.
- **10.34** builds on 10.32 and 5.10 (both done). It changes `--rem-word-bg` / `--add-word-bg` values in DS `tokens/colors.css` and `ZsColors` together (DS parity test), updates the DS diff prompts and readme, and republishes the DS with the `design-artifacts` skill.
