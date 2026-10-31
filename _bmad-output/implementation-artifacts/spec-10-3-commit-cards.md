---
title: "Story 10.3 — Commit cards: the detailed and compact card as one RenderBox, its states, bookmark legend, hover affordances and HatchSwatch"
type: 'feature'
created: '2026-10-30'
status: 'done'
baseline_revision: 'fd0a5499c43d46198c6bbf6a9d10b958fed462c5'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-10-context.md'
warnings: ['oversized']
deferred:
  - summary: >-
      The card's affordances carry no tooltips: the `+N` workspace tag does not list the folded names on hover, and ••• lacks its title "Actions (or right-click the card)".
    evidence: |-
      The 2026-10-16 note asks for a `+N` tooltip listing the rest, the 2026-10-14 note for •••'s title (GV:320). The card is one leaf RenderBox; a tooltip needs the overlay host and the hover-delay machinery that 10.6's commit callout builds. The names reach VoiceOver through the card's label meanwhile.
    location: >-
      app/lib/src/features/graph/graph_card_render.dart
    severity: low
  - summary: >-
      The commit cards were not checked visually (Marionette) in the running catalogue against the DS cards.
    evidence: |-
      The unattended loop cannot hold a `flutter run -d macos -t widgetbook/main.dart` session. Widget tests cover layout, yield order, rings, hatch, hit areas, input and semantics; the smoke test pumps `graph/card/states` and the viewport use cases.
    location: >-
      app/widgetbook/folders/graph.dart
    severity: low
    resolved: >-
      2026-10-31 — fixed (console session, Marionette): `graph/card/states` in night and paper matches graph.card.html; the change id stays jj's (no gap, shortest(8)/(5)) by Ralph's decision; the click slop became the 4 px drag threshold (spec-fix-10-2-10-5-review, commit 20b5b0d).
---

<intent-contract>

## Intent

**Problem:** The graph viewport (10.1, 10.2) shows `GraphPlaceholderCard`, a box with the node's key. Nothing renders a jj change: subject, id, author, date, flags, bookmarks, the @/selected/immutable states, or the card's hover affordances. Deferred item I1 (deferred-work.md, "Surfaced in Story 10.2") also needs the card's VoiceOver label to carry the commit's date, because the day axis adds no semantics.

**Approach:** Build the card that `_bmad-output/planning-artifacts/epics.md:8778-8983` specifies, as amended by its dated notes. The notes win over items 1–13, the later notes over the earlier ones: 2026-09-28, 2026-10-14 (the fan and the "+" chips are retired), 2026-10-16 (IconRegistry, jj's id prefix, `name@`, accent role, inactive window, motion), 2026-10-26 (the hatch, no ◆). The card is one leaf `RenderBox` that paints everything with `TextPainter`s and icon pictures. Its data comes through new `GraphLayout` accessors, and its interaction states through one `GraphCardController` of `ValueNotifier`s, so hover, selection and the minute tick build no card. The open design questions are settled below as Claude's proposals, along jj where jj decides.

## Boundaries & Constraints

**Always:**
- **Geometry.** The viewport lays every card child out at the card rect inflated by `graphCardOverhang` (now **11**, was 4) on all sides, at `cardRect.topLeft − (11, 11)`. `cardRect`, extents, the anchor, reveals and `isOnCard` keep the un-inflated rect. The card derives W from `size.width − 22` and Detailed vs Compact from `size.height − 22` (≥ `ZsMetrics.cardHDetailed` → detailed). A W or Detailed change is a pixel remap: it relayouts and builds no card.
- **Hit testing.** The card's `hitTest` accepts only these areas, and everything else in the inflated box returns false (empty margin reaches the viewport's pan and the edges):
  - the card's rounded rect;
  - the legend pill, when shown;
  - the add-bookmark circle and the ••• circle, only while revealed.
- **Hover is paint-only.** The `RenderBox` is a `MouseTrackerAnnotation`; its cursor is `MouseCursor.defer`, so the viewport's arrow and grabbing cursors stay.
  - `onEnter` sets `controller.hovered` to its key. `onExit` clears it, only if it is still its key.
  - Hover, selection, focus, menu-open, `actionsEnabled` and the clock reach the card by listeners, never by a rebuild.
  - Selecting A, then B, and a hover each build **0** cards.
- **Layout** (DS components/graph/graph.css:1-24, :33-46, :87-96 win over the epic's older colour values):
  - **Detailed (H 62).** Padding x is `cardPadX` 12. Two lines are centred vertically with a gap of 5.
    - Line 1 is the subject (`ZsType.cardSubject`), ellipsized.
    - Line 2 is the meta line: 11 px (`fsSm`) sans in `--text-dim`, gap 8. In order: the @ slots; the id; the author's first name; the relative date; "empty" (italic, `--text-faint`); the conflict icon (in `--conflict`); the merge icon (in `--text-dim`). Both icons are `sm` 12.
  - **Compact (H 40).** One centred line, gap 7: the @ slots, the id, the subject (it takes the remaining width), the flags.
  - **The id.** One paragraph with no gap between its spans:
    - the bold prefix, in `--text` at 700;
    - the rest, in `--text-faint`, under `ZsType.id`;
    - `/N` in `--text-faint` when `changeOffsetOf` is non-null. This is jj's `format_change_offset`, templates.toml @ v0.46.0.
    - The shown length is max(prefix, 8) on a detailed non-@ card, and max(prefix, 5) on @ and on every compact card. That is jj's `shortest(n)`: commit_templater.rs:2295-2302 @ v0.46.0.
  - **The subject:**
    - an empty description shows "(no description set)" in italic 400 `--text-dim` (jj's `description_placeholder`);
    - the root shows "root()" in mono, not italic;
    - immutable cards (the root included) use `--text-muted`.
  - **The @ badge** (wc only): `--co` fill, `--co-ink` text, mono 700 11, height 16, padding 0 5, radius `radiusXs`.
- **`name@` slots.** They appear only when `workingCopiesOf(node)` is non-empty. jj's `extract_working_copies` returns none with ≤ 1 workspace (commit_templater.rs:1491-1503 @ v0.46.0).
  - Ours is the @ badge reading `<symbol>@` (at most 96 px). Every other name is a quiet tag: mono 600 11, `--text-muted`, a 1 px `--border-strong` inset, height 16, at most 96 px.
  - The order: ours first, then up to two others by name, then `+N` (400, `--text-dim`).
  - Names print as jj's `format_symbol`: plain when they match revset `identifier` (revset.pest:24-29 @ v0.46.0), otherwise double-quoted with jj's escapes (core/src/symbol_util.rs @ v0.46.0).
- **Yield order.** Text never overflows `W − 24`.
  - Detailed: the author shrinks first (ellipsized; dropped below one character), then further tags fold into `+N`, then names shorten below 96 (to a 24 px minimum), then the date goes.
  - Compact: the subject ellipsizes first (down to 0), then tags fold, then names shorten.
  - The id and the flags never yield.
- **States** (paint only; tokens via `GraphTheme` and `ZsElevation`; radius `radiusCard` 10):
  - base: `--card-solid`, 1 px `--border-strong`;
  - hover and menu-open: `--card-solid-hi`, `--edge-hov`;
  - selected: `--accent-line` border plus `ringSelect`;
  - @: `--co` border, a 135° `--co-soft` → transparent 70 % tint over `--card-solid`, and `ringWc`;
  - @ and selected: `ringWcSelect`;
  - immutable (the root included): a 135° hatch, 1 px every 6 px in `--hatch`, over the fill and under the content, in every state;
  - keyboard focus: a 2 px `--focus-ring` outline at offset `focusOffsetCard` 3. It shows only when `controller.focused == key` and `FocusManager.instance.highlightMode == traditional`.
  - **Inactive window** (`ZsAppearance.inactive`): no hover look, no hover reveal, no focus ring. The selected colours go neutral through the resolved tokens. Gold and the data colours stay.
- **Bookmark control** (on the top border, right 10, top −11, height 20). It is not built on the root.
  - **Legend pill** when `refsOf` is non-empty. It is always visible and at most **W/2 − 34**. It shows `bookmark-filled` (`--text-dim`) and the first ref (jj's order), shortened. The render order is prefix · main · @remote · sigil · rest · +N (epics.md:8909):
    - A JIRA key `[A-Z][A-Z0-9]+-\d+` leads in bold 600, and the rest (with its `_-/.` lead trimmed) is dim.
    - Otherwise the dim prefix path (at most 4ch, shrinking first) leads, and the bold last segment follows.
    - `@remote` is dim. jj's sigil is `??` when conflicted, else `*` for an unsynced local ref.
    - `+N` counts the further refs.
    - Fill `--card-solid` (hover: `--card-solid-hi` + `--edge-hov`); border `--border-strong`, `--accent-line` when selected, `--co` on @.
  - **Add-bookmark circle** (20 px, `bookmark`, `--text-faint`) when there are no refs. It is revealed on hover or focus.
- **•••** (20 px circle, right 10, bottom −11, `more`): revealed on hover, focus or menu-open. A pointer over it, or an open menu, colours it `--text`.
  - Both affordances fade over `durHover` and scale `1 − .15·motion·(1 − t)` (`easeGlide`). Under reduce motion they only fade.
  - While `controller.actionsEnabled` is false they paint at `disabledOpacity` .4 and ignore taps.
- **Input.**
  - A primary tap on ••• → `controller.openMenu(key, its global rect)`.
  - A tap on the pill or the add-bookmark circle → `controller.openBookmarks(key, rect)`.
  - Elsewhere on the card → `controller.select(key)`.
  - A secondary tap anywhere hit → `openMenu(key, zero-size rect at the pointer)`.
  - The root keeps ••• and has no bookmark control.
- **Semantics.** One node per card, with:
  - the button role, `isSelected`, `identifier: 'graph-card-<key>'`, tap → select;
  - custom actions "Actions" (openMenu) and, except on the root, "Bookmarks: <names as jj prints them>" or "Add bookmark" (openBookmarks);
  - the card rect as its rect.
  - The label: `[Working copy[ of <ours>], ][working copy of <others joined by ", ">, ][Immutable, ]<subject | "no description">, <id as shown>, <author>, <date>[, empty][, conflict][, merge][, hidden | , divergent]`.
    - "Immutable, " is left out on the root.
    - With null content, the subject and author parts are left out.
    - The date part is `<relative>, <day label>` (the day label is `graphDayLabel` of the commit's local day). It is just the date when the relative text already is that day label. **This settles I1.**
- **Relative date** (design question (h), Claude's proposal): the committer time, as `jj log` shows it. Against `controller.now`:
  - under 60 s, and the future → "now";
  - under 60 min → "Nm";
  - under 24 h → "Nh";
  - under 7 days → "Nd";
  - else "MMM d", plus ", yyyy" in another year (the day axis's format at the layout's offset).
  - A tick that changes the text relayouts that card only; an unchanged one does nothing.
- Colours come only from `GraphTheme` (new roles derived in `fromColors`) and `ZsElevation`; the app imports `zanshin_ui` only through its barrel. Icons come from `IconRegistryScope`.

**Never:**
- A `Column`/`Row`/`Text` tree inside the card.
- A per-card `setState` for hover or selection.
- Per-build callback closures.
- The quick-action fan, the "+" chips, the ◆, tags on the card, a tooltip, the Bookmark labels option.
- Dimming on an empty *change* (prototype defect 14), or the export's `calc(100% − 20px)` legend.
- Selection/hover/keyboard logic (10.6), the popover and menu (10.15), verbs (10.9), drag sources (10.10), skeletons (10.11), live data (10.12), the pending state (10.9), the drop/flash/drag paints (10.10/10.20).
- Golden tests.
- Touching `graph_poc/`, `main2/3/4.dart` or `features/commits/`.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Prefix 3 | change id `kxwsnptm…`, prefix length 3, detailed, not @ | bold `kxw`, dim `snptm`, one paragraph, no gap | — |
| Short prefix on @ | prefix 2, @ | bold 2 + dim 3 (length 5) | — |
| Long prefix | prefix 10, detailed | all 10 bold, no rest | — |
| Divergent | `changeOffsetOf` = 1 | id followed by `/1`; the label ends "…, divergent" | — |
| Empty description | content subject '' | "(no description set)" in italic dim | — |
| Content not loaded | `contentOf` null | no subject, no author; id, date and flags shown | no exception |
| Missing merge parent | `parentCountOf` 2, one parent Missing | the merge glyph shows | — |
| 500-char subject, long author | detailed 240 | both ellipsize; size stays 240 × 62 | — |
| Legend JIRA | `feature/ZAN-412_onboarding-swipe` | **ZAN-412** · onboarding-swipe | — |
| Legend path + remote | `release/1.5.x` @ `origin` | release/ · **1.5.x** · @origin | — |
| Legend more | `riverpod` + 2 | **riverpod** · +2 | — |
| Ref sigils | conflicted local `main`; unsynced local `dev` | `main??`; `dev*` | — |
| Workspaces 1 | `workingCopiesOf` empty | the plain @ badge only | — |
| Workspaces 2 | ours `default`, other `ci` | `default@` saffron, `ci@` tag | — |
| Workspaces 5 | ours + 4 others | ours, 2 names, `+2` | — |
| Quoted name | `my ws` | `"my ws"@` | — |
| Yield 240 | detailed, 4 workspaces, long author | author → tags → names → date; nothing overflows | — |
| Yield 160 compact | 3 workspaces | the subject goes first; ours and the full id stay; nothing overflows | — |
| Root | `rootIndex` node | "root()" mono, hatched, ••• only, no bookmark control, no "Immutable, " | — |
| Inactive window | `ZsAppearance.inactive`, hovered + selected | no hover paint; neutral selected ring | — |
| Reduce motion | `disableAnimations` | ••• at full scale, fades only | — |
| Relative date | ts now−30 s, −40 min, −20 h, −3 d, −9 d, previous year | now, 40m, 20h, 3d, Sep 19, Dec 29, 2025 | the future → now |

</intent-contract>

## Code Map

- `_bmad-output/planning-artifacts/epics.md:8778-8983` -- Story 10.3, with its notes (:8781-8857). Witnesses at :8972-8983, :8813-8818, :8843-8850, :8857. The non-goals are at :8947-8952.
- **Design** (inspiration; DS tokens/CSS win over prose):
  - `_bmad-output/implementation-artifacts/design_system/components/graph/ChangeCard.jsx` -- slots, label, quiet subject.
  - `…/graph/graph.css:1-24, :33-53, :80-96, :106-110` -- every card, id, @, tag, bookmark, affordance and hatch value.
  - `…/graph/BookmarkChip.jsx:5-12` -- the `zsSplitBookmark` split.
  - `…/graph/HatchSwatch.prompt.md` -- the swatch.
  - `…/graph/ChangeCard.prompt.md` -- immutable rules.
- **jj @ v0.46.0** (`git -C ../jj show v0.46.0:<path>`):
  - `cli/src/config/templates.toml` -- `format_short_change_id_with_change_offset`, `format_commit_labels`, `description_placeholder`, `commit_timestamp` = committer.
  - `cli/src/commit_templater.rs:1491-1503` -- working copies empty with ≤ 1 workspace.
  - `:1865-1868` -- `name.as_symbol()@`.
  - `:2295-2321` -- shortest prefix and rest.
  - `lib/src/revset.pest:24-29`, `lib/src/revset_parser.rs:676-710`, `core/src/symbol_util.rs` -- `format_symbol`, `format_string` escapes (`\"` `\\` `\t` `\r` `\n` `\0`, other ASCII control → `\xHH`).
  - Ref sigils: jj's `CommitRef` template prints `name[@remote]`, then `??` if conflicted, else `*` if local and not synced.
- **The viewport:**
  - `app/lib/src/features/graph/graph_viewport_render.dart:17-19` -- `graphCardOverhang` (→ 11, with its doc).
  - `:422-436` -- `_layoutNode`: `BoxConstraints.tight(size)` and `layoutOffset` become the inflated rect.
  - `:528-549` -- z-order (hovered/pinned 3, selected 2, @ 1).
  - `:595-608` -- reverse hit test.
  - `:620-636` -- `isOnCard` and the pan stay on the card rect.
- `app/lib/src/features/graph/graph_child_delegate.dart:31-44` -- each card sits in `KeyedSubtree` → `KeepAlive` → `RepaintBoundary`. This is why the child box itself must be inflated: a proxy rejects positions outside its size.
- `app/lib/src/features/graph/graph_layout.dart:51-157` -- `GraphLayout` ("consumers add accessors").
  - `:159-202` -- `GraphViewOptions`, which stays as is: the Bookmark labels option is gone.
- `app/lib/src/features/graph/recorded_graph_layout.dart:14-177` -- the constructor and `fromSpec`.
  - The §2 input carries per node `immutable` (bool) and `is_root`.
  - No content, refs or workspace names are recorded.
- `app/lib/src/features/graph/day_axis.dart:19-32` -- `graphDayLabel`; reuse it, and its month table, for the date's day form.
- `app/lib/src/features/bootstrap/splash_card_render.dart:188+` -- the house RenderBox pattern: tickers, `TextPainter`s, painting.
- `packages/zanshin_ui/lib/src/design/graph_theme.dart:15-111` -- add the card roles here, in all six places plus `graph_theme_test.dart`.
- **Tokens and icons in `zanshin_ui`:**
  - `packages/zanshin_ui/lib/src/design/zs_colors.dart:777-1065` -- `cardSolid`, `cardSolidHi`, `hatch`, `hatchMark`, `border`, `borderStrong`, `text`, `textMuted`, `textDim`, `textFaint`, `edgeHov`, `co`, `coSoft`, `coDeep`, `coInk`, `accentLine`, `conflict`, `focusRing`.
  - `zs_elevation.dart:29-31, :56-61` -- `ringSelect`, `ringWc`, `ringWcSelect` (resolved for the accent and the inactive window). Its `ZsShadowStack.boxShadows` are front-first; paint them reversed, each as `rrect.shift(offset).inflate(spread)` with `BoxShadow.toPaint()`.
  - `zs_values.dart` `ZsLinearGradient(angle: 135, stops)` → `createShader(rect)` -- the CSS @ tint.
  - `zs_metrics.dart:203-217` -- `cardW`, `cardHCompact`, `cardHDetailed`, `cardPadX`, `radiusKbd`, `radiusXs`, `radiusCard`, `radiusPill`; also `focusW`, `focusOffsetCard`, `disabledOpacity`.
  - `zs_motion.dart` -- `ZsMotion.of(context)`: `durHover`, `easeGlide`, `easeState`, `motion` (0 under reduce motion).
  - `zs_type.dart` -- `cardSubject`, `id`, `fsSm`, `fsXs`, `monoFamily`, weights.
  - `icons/zanshin_icon.dart:18-63, :127-143` -- `IconRegistryScope.maybeOf(context)?[name]` → `PictureInfo`. Paint it as `RenderZanshinIcon.paint` does. The names are `ZI.bookmark`, `ZI.bookmarkFilled`, `ZI.more`, `ZI.conflict`, `ZI.merge`.
  - `ZsAppearance.maybeOf(context)?.inactive` -- the inactive window.
- **The catalogue:**
  - `app/widgetbook/folders/graph.dart:20-218` -- the Graph folder.
    - `_GraphDemo` gets the card and the controller.
    - The `_fixture` cache and `recordedLayout`.
  - `app/widgetbook/graph/placeholder_card.dart` -- delete it; it is replaced.
  - `app/widgetbook/graph/synthetic_layout.dart:17-159` -- give its nodes fake content and refs too.
- **Tests:**
  - `app/test/features/graph/graph_harness.dart:93-126, :157-161` -- `TestCard` and `cardBuilder`. Wrap TestCard in `Padding(EdgeInsets.all(graphCardOverhang))`, so every 10.1/10.2 witness keeps its card rect.
  - `handLayout` gains the new facts.
  - `app/test/helpers/icon_registry.dart` -- `setUpIconRegistry()`.
  - `app/test/widgetbook/catalogue_extension_test.dart:88-101` -- it expects `GraphPlaceholderCard` → expect `GraphCard`.
  - `app/test/widgetbook/catalogue_smoke_test.dart` -- every Graph use case; it expects a `ZsCanvas` under `graph/`.

## Tasks & Acceptance

**Execution:**
- `app/lib/src/features/graph/graph_layout.dart`:
  - Add `GraphRef` (immutable: `name`, `remote?`, `synced` default true, `conflicted` default false; `display` = jj's text with the sigil).
  - Add `GraphCommitContent` (immutable: `subject` = the description's first line, `''` when the description is empty; `authorName`; `authorEmail`; `empty`; `conflict`).
  - Add abstract accessors:
    - `String changeIdOf(int)`, `int changeIdPrefixLengthOf(int)`, `int? changeOffsetOf(int)` (non-null only when hidden or divergent);
    - `bool isImmutable(int)`, `isHidden(int)`, `isDivergent(int)`;
    - `List<GraphRef> refsOf(int)` (bookmarks in jj's order);
    - `List<String> workingCopiesOf(int)` (jj's `working_copies()` names);
    - `String? get workspaceName` (ours);
    - `GraphCommitContent? contentOf(int)` (null until loaded).
  - Document each with its jj source.
- `app/lib/src/features/graph/recorded_graph_layout.dart`:
  - Optional constructor lists for each fact: `changeIds`, `changeIdPrefixLengths`, `changeOffsets`, a `flags` `Uint8List` with static bits immutable/hidden/divergent, `refs`, `workingCopies`, `contents`, plus `workspaceName`.
  - Defaults: change id = key; prefix = the in-layout shortest unique prefix of the change ids (a fixture stand-in for jj's `changeIdPrefixLen`, computed once by sorting); no offset; flags 0; empty lists; null content.
  - `fromSpec` reads `immutable` into the flags, and takes optional `content` and `refs` callbacks `(int node, String key)`.
- `app/lib/src/features/graph/graph_viewport_render.dart` -- `graphCardOverhang = 11`, with its doc: affordances at ±11 plus the rings; the drop glow may paint beyond it, unclipped. `_layoutNode` lays out and offsets the inflated rect.
- `packages/zanshin_ui/lib/src/design/graph_theme.dart`:
  - Card roles from `ZsColors`: `cardFill`, `cardFillHover`, `cardBorder`, `cardBorderHover`, `cardSelectedBorder`, `workingCopyLine` (co), `workingCopyTint` (coSoft), `atBadgeFill` (co), `atBadgeText` (coInk), `cardText`, `cardTextMuted`, `cardTextDim`, `cardTextFaint`, `conflict`, `hatch`, `hatchMark`, `focusRing`.
  - Add them to the ctor, `fromColors`, `copyWith`, `lerp`, `==` and `hashCode` (`Object.hashAll`).
  - Extend `test/design/graph_theme_test.dart`.
- `app/lib/src/features/graph/graph_card.dart` (new):
  - `GraphCardController`:
    - `ValueNotifier<String?>` `hovered`, `selected`, `focused`, `menuOpen`; `ValueNotifier<int>` `now` (required initial); `ValueNotifier<bool>` `actionsEnabled` (default true);
    - overridable `select(key)` (sets selected, clears menuOpen), `openMenu(key, Rect)` (toggles menuOpen), `openBookmarks(key, Rect)` (no-op);
    - `dispose()`.
  - `GraphCardData.of(GraphLayout, int node)`: the immutable per-card facts, built in `build`.
  - Pure helpers, top-level and tested: `graphRelativeDate(tsMs, {nowMs, utcOffsetMinutes})`, `graphLegendParts(GraphRef)` (prefix / main / remote / sigil / rest), `jjRevsetSymbol(String)`, `graphCardLabel(GraphCardData, {nowMs})`.
  - `GraphCard` (StatefulWidget: layout, node, controller):
    - its State owns one `AnimationController` (`durHover`) for the affordance reveal;
    - it listens to hovered/focused/menuOpen to forward or reverse it;
    - it builds `_GraphCardLeaf` (a `LeafRenderObjectWidget`) with the data, theme, elevation, metrics, motion, inactive, icon pictures, the controller and the reveal animation.
- `app/lib/src/features/graph/graph_card_render.dart` (new) -- `RenderGraphCard extends RenderBox implements MouseTrackerAnnotation`:
  - Layout: the text painters and the yield order of the Always rules.
  - Paint: rings → fill + tint → hatch (clipped) → border → content → focus ring → legend or add-bookmark → •••.
  - The `hitTest` override.
  - `handleEvent`: tap recognizers for the primary and secondary button; hover position for •••'s own colour.
  - `describeSemanticsConfiguration`; `semanticBounds` = the card rect.
  - Listeners attached in `attach`, removed in `detach`.
  - A `@visibleForTesting` list of laid-out slots (kind, rect) for the yield witnesses.
- `app/lib/src/features/graph/hatch_swatch.dart` (new):
  - `paintGraphHatch(Canvas, RRect, {period, color})`: 135° lines `x + y = √2·(period − .5 + period·k)` from the rect's top-left, 1 px, clipped. The card uses period 6.
  - `HatchSwatch({String? label})`: 12 × 12, radius `radiusKbd`, 1 px `--border-strong`, `--card-solid`, the hatch with period 3 in `--hatch-mark`. Excluded from semantics without a label; an image with the label otherwise.
- `app/widgetbook/graph/fake_content.dart` (new): deterministic fake content and refs per node index, using the design's subjects, authors (graph-data.js) and the legend cases; about every 4th node gets refs; some contents are empty.
- `app/widgetbook/folders/graph.dart`:
  - `_GraphDemo` owns a `GraphCardController` (`now` = the sample's now) and a `Timer.periodic(1 min)` that advances `now` by 60000.
  - Its card builder returns `GraphCard`.
  - `selectedKey`, `hoveredKey` and `pinnedKeys` (the menu-open key) are fed to the viewport through one `ListenableBuilder`.
  - Recordings and synthetic layouts get the fake content.
  - Add the component "Card", use case "States", over `ZsCanvas`: a hand layout with one card per state of the matrix, each in its own inflated box with its own controller, forced hover/selected/menu/focus included. Its knobs are width, detailed and our workspace name (default `default`).
  - It also shows the four legend cases and a `HatchSwatch`.
- `app/widgetbook/graph/placeholder_card.dart` -- delete; update `catalogue_extension_test.dart` to `GraphCard`.
- `app/test/features/graph/graph_harness.dart` -- TestCard padded by the overhang; `handLayout` gains optional facts (refs, contents, flags, prefix lengths, offsets, workspaces, workspaceName, parentCounts).
- `app/test/features/graph/graph_card_test.dart` (new) -- the matrix and the ACs below.
  - Icons load in `setUpIconRegistry()`.
  - 800 × 600 at dpr 1, with the default test font (1 em per glyph).
  - Scroll and hover under `TargetPlatformVariant.only(TargetPlatform.macOS)`.

**Acceptance Criteria:**
- **Builds.** Given a viewport of `GraphCard`s:
  - when a mouse hovers A, then B, then **0** cards build, and A and B repaint;
  - when `selected` goes A → B, then 0 cards build;
  - when `now` advances 60 s, then 0 cards build, and only cards whose date text changed need layout.
- **Affordances.** Given a card, when the mouse hovers it, then ••• and (without refs) the add-bookmark circle reveal and are hit in the overhang, and the pointer stays "hovered" while on them. When it is not hovered, then a tap there misses the card.
- **Pan.** Given a mouse drag that starts 5 px above a card (not on its pill), when it moves, then the canvas pans.
- **Input.** Given a card, when it is right-clicked, then `openMenu` is called with the pointer rect; when ••• is tapped, then `openMenu` is called with •••'s rect; when the body is tapped, then `select` is called.
- **Legend width.** Given every legend case, when laid out at W 160/240/400, then the pill's width is ≤ W/2 − 34, and it paints after the card's content (`paints` order).
- **Rings.** Given selected and @-selected cards, when painted in night and paper, then the ring rrects and colours equal `ZsElevation` `ringSelect` / `ringWcSelect` and the `--accent-line` / `--co` borders.
- **Hatch.** Given an immutable card and the root, when painted in base, hover, selected and menu-open states, then the hatch lines paint in every state and no card paints a ◆. When `HatchSwatch` paints, then its lines have period 3 at 12 px.
- **Labels.** Given cards of the matrix, when their semantics are read, then:
  - it starts "Immutable, " on an immutable non-root card;
  - it names the workspaces ("Working copy of default, working copy of ci, …");
  - it carries the date with its day label (**I1**);
  - the custom actions are "Actions" and "Bookmarks: …" / "Add bookmark".
- **Window states.** Given `ZsAppearance.inactive`, when a card is hovered, then it paints no hover look and no affordance. Given `disableAnimations`, when a card is hovered, then ••• appears at scale 1 and fades in.
- **Catalogue.** Given the catalogue, when every Graph use case is pumped (smoke test), then none throws, and `graph/viewport/*` shows `GraphCard`s.

## Spec Change Log

## Review Triage Log

### 2026-10-30 — Review pass
- verdicts: 40 findings — high 0, medium 6, low 30, false 4, maybe-false 0 (blind 14, edge 11, verification-gap 4, intent-alignment 11)
- findings:
  - `[low]` `[patch]` (blind #1, grouped with edge #4) The "Bookmarks" custom semantics action works while `actionsEnabled` is false, though a pointer tap on the pill or the add circle is ignored then. `_semanticBookmarks` now returns early when disabled. "Actions" stays: it is the right-click menu, which the spec keeps.
  - `[medium]` `[patch]` (blind #2, grouped with edge #1) A hovered card that detaches (a reload drops its node) gets no onExit (`validForMouseTracker` is false), so `controller.hovered` keeps a stale key and a remounted card shows hover. `detach` now clears it in a post-frame callback when it is still this card's key. The callback first checks the new `GraphCardController.isDisposed`: the smoke test's States use case disposed its controllers before the callback ran.
  - `[medium]` `[patch]` (blind #3) The VoiceOver label read the visual abbreviations ("40m", "3d"). The label now carries a spoken relative date ("40 minutes ago"); the visible text stays abbreviated.
  - `[low]` `[reject]` (blind #4) A `GraphCard` rebuild relayouts its card because `GraphCardData` has no value equality. Rebuilds come only from a theme/appearance change (which relayouts anyway: the text painters carry the colours) or new data; hover, selection and the tick build nothing.
  - `[low]` `[reject]` (blind #5, grouped with edge #8) The flags are clipped when the non-yielding items alone exceed W − 24. At 160 px that needs a named badge, folded tags at their 24 px minimum, a long prefix and both flags at once; another yield branch costs more than the case.
  - `[low]` `[reject]` (blind #6) At narrow widths the legend drops the sigil and `+N`. W/2 − 34 is the design's cap (about 18 px of text at W 160), and the "Bookmarks: …" semantics action names every ref with its sigil.
  - `[low]` `[reject]` (blind #7, grouped with edge #9) The fixture prefix stand-in gives two equal (divergent) change ids the full length. No recording or synthetic layout has equal ids, the catalogue's divergent case passes its prefix, and real data brings jj's `changeIdPrefixLen` (10.12).
  - `[low]` `[patch]` (blind #8) The local-midnight arithmetic was written twice. `graphLocalDay` is now the one helper, used by the label and the render box.
  - `[low]` `[patch]` (blind #9) The minute tick marked compact cards for layout, though they show no date. Layout is now marked only on detailed cards; the semantics still update.
  - `[low]` `[reject]` (blind #10) Right-clicking a card whose menu is open closes it (the default `openMenu` toggles). The controller's methods are placeholders that 10.15 overrides; the card passes the pointer rect, which is all it owns.
  - `[false]` `[reject]` (blind #11) "The legend pill ignores the menu-open state." DS graph.css styles the pill only under `.zs-card:hover>.zs-bm` (:22); `.is-menu` (:85) changes the card's own border and background, not the pill's. The code matches the CSS.
  - `[low]` `[patch]` (blind #12) The add-bookmark circle had no pointer-over state, but graph.css:96 colours it `--text` on hover. It now tracks the pointer as ••• does.
  - `[low]` `[reject]` (blind #13) Most tests do not dispose their controller. No leak tracker runs in this suite; the notifiers die with the test.
  - `[low]` `[reject]` (blind #14) No test swaps the controller or reuses a card for another key. The delegate keys cards by node key, so a card never changes key, and no host swaps the controller.
  - `[medium]` `[patch]` (edge #1) Grouped with blind #2; patched there.
  - `[low]` `[patch]` (edge #2) `_onTapUp` used `_legend ?? _add!`, which throws if a relayout between down and up removed both. It now falls back to the card rect.
  - `[false]` `[reject]` (edge #3) "A right-click opens the menu while actions are disabled." The spec disables only the ••• and add-bookmark affordances; the right-click menu stays, and 10.15 shows its rows disabled.
  - `[low]` `[patch]` (edge #4) Grouped with blind #1; patched there.
  - `[low]` `[patch]` (edge #5) After the fade-out fix at Verify, closing a menu that was opened without hover faded out an add-bookmark circle that was never shown. The add circle's fade-out is now latched to whether it was revealed.
  - `[false]` `[reject]` (edge #6) The pill ignores the menu-open look. Same refutation as blind #11.
  - `[low]` `[reject]` (edge #7) With working-copy names but no `workspaceName`, ours shows as a tag beside the plain @. Without the name nobody can tell which is ours; the layout contract has the source (10.5) carry it.
  - `[low]` `[reject]` (edge #8) Grouped with blind #5.
  - `[low]` `[reject]` (edge #9) Grouped with blind #7.
  - `[medium]` `[patch]` (edge #10) Workspace names were quoted by revset `format_symbol`, but jj prints `name@` through `WorkspaceName.as_symbol()`, whose Display is `is_safe_identifier` (core/src/ref_name.rs @ v0.46.0: ASCII only). So `ünïcode_ws` or `a--b` showed unquoted where jj quotes them. `jjRefSymbol` now implements it for the badge and the tags. The spec's citation of `format_symbol` for workspaces was wrong; CLI parity decides.
  - `[low]` `[patch]` (edge #11) `GraphRef.display` wrote raw names, but jj's `CommitRef` writes name and remote as `RefSymbolBuf`, whose Display is `revset::format_symbol` (commit_templater.rs:1815-1831, :2132-2136 @ v0.46.0). `display` now quotes both; the symbol helpers moved to graph_layout.dart.
  - `[medium]` `[patch]` (verification-gap #1) No test checked a `GraphCard` laid out by the viewport: reverting the inflated child box would pass every witness. Added a viewport test of the card's size, its card rect on screen, and a hover + ••• tap through the viewport.
  - `[low]` `[patch]` (verification-gap #2) The minute tick's semantics refresh was unpinned. Added a test of the label after a tick and across local midnight.
  - `[low]` `[patch]` (verification-gap #3) `select` clearing the menu and `openMenu`'s toggle had no assertion. Added a controller test.
  - `[medium]` `[patch]` (verification-gap other) A press on the overhang half of •••, the pill or the add circle armed the viewport pan, so a 2 px wobble panned instead of opening. The viewport now records whether a card child claimed the pointer-down and arms the pan only when none did; empty margin and canvas still pan. Added a press-move-release test on •••: a 3 px move no longer scrolls, and a 1 px move still opens the menu (Flutter's mouse tap slop is 1 px, `kPrecisePointerHitSlop`, so a 3 px move cancels the tap either way).
  - `[low]` `[reject]` (intent #1, I1-c) The label's day is the commit's own local day, while the axis shows the bucket's day, which differs for a clamped child. The label states the commit's own committer date, the truthful reading; the clamp is a layout artifact the axis shows.
  - `[low]` `[reject]` (intent #2) No test reads the label in a viewport or after a tick. The tick part is patched (verification-gap #2); the label does not depend on the host.
  - `[low]` `[reject]` (intent #3) There are no slot children. Settled in Design Notes: a `Text` slot would build on the tick, and the house rule's intent (a RenderBox, no Column/Row tree) holds.
  - `[low]` `[reject]` (intent #4) The tick relayouts the whole leaf, not "only the date slot". A leaf relayout of one card is cheap, and it happens only when the text changes.
  - `[low]` `[defer]` (intent #5, grouped with intent #6) The `+N` tag has no tooltip listing the rest. A tooltip from a leaf RenderBox needs the overlay host and hover-delay machinery that 10.6's callout builds; the names are in the VoiceOver label meanwhile.
  - `[low]` `[defer]` (intent #6) ••• has no "Actions (or right-click the card)" title. Same root cause as intent #5.
  - `[low]` `[reject]` (intent #7) Raising the hovered and menu-open card is wired only in the catalogue. The viewport takes `hoveredKey`/`pinnedKeys` (10.1); the product wiring is 10.5/10.6's.
  - `[low]` `[reject]` (intent #8) "The legend paints above an exit" is tested only within the card. Edges arrive in 10.4, and cards paint above the edges layer by 10.1's paint order.
  - `[low]` `[reject]` (intent #9) Hover is not cleared on resignKey, only not painted. Clearing the hover state is 10.6's (the controller's owner).
  - `[low]` `[reject]` (intent #10) The anchor-under-W-change, State-across-reload and both-themes witnesses run on `TestCard`. Those are viewport mechanisms (10.1) the card does not change; the rings are tested in both themes.
  - `[false]` `[reject]` (intent #11) The Auto Run Result and the deferred-work mirror are missing. They are written at finalize, in the spec's commit.

### 2026-10-30 — Review pass (follow-up)
- verdicts: 37 findings — high 0, medium 0, low 30, false 6, maybe-false 1 (intent 12, verification-gap 4, blind 16, edge 5); 7 of them carried from the first pass.
- findings:
  - `[low]` `[reject]` (intent #1) The label speaks "40 minutes ago" where the intent's `<relative>` could mean the card's "40m". The spoken form is the screen-reader rendering of the same date (VoiceOver reads "40m" as metres); it was the first pass's medium patch, and the day-label rule is unchanged.
  - `[low]` `[patch]` carried (intent #2) Workspace `name@` slots use `jjRefSymbol` (jj's `is_safe_identifier`), not revset `format_symbol`. The first pass's edge #10 patch; CLI parity decides. Not patched again.
  - `[false]` `[reject]` (intent #3) Compact cards omit the "empty" word. DS ChangeCard.jsx:47 shows `empty` only in the detailed meta line; the compact line's flags are the icons. The label keeps "empty".
  - `[false]` `[reject]` (intent #4) The menu-open look beats the @ fill and border. graph.css:84 `.zs-card.is-menu` comes after :5 `.zs-card.is-wc` at the same specificity, so the CSS does the same; `openMenu` toggling is carried from blind #10 (reject).
  - `[false]` `[reject]` (intent #5) The `+N` workspace tag is drawn as a bordered tag, not plain text. graph.css:44 `.zs-ws.is-more` is a `.zs-ws` (the inset border) with 400 `--text-dim`, which is what the code paints.
  - `[low]` `[reject]` (intent #6) The root with null content still reads "root()". "root()" is the root's name, not loaded content; the null-content rule drops the description and author, which the root has none of.
  - `[false]` `[reject]` (intent #7) "The catalogue's `ListenableBuilder` rebuilds the viewport on hover and selection, so cards may build." `GraphChildDelegate.shouldRebuild` (graph_child_delegate.dart:46-49) compares the layout version, the builder and the pinned keys; the catalogue passes the tear-off `_card` (graph.dart:254), which is equal across builds, so hover and selection build no card.
  - `[low]` `[reject]` carried (intent #8) No live-viewport test of a W / Detailed remap. Same as the first pass's intent #10: a 10.1 viewport mechanism tested on `TestCard`.
  - `[low]` `[defer]` carried (intent #9) Pixels are proven with the test font and against the derived tokens, not the DS with Inter / JetBrains Mono. The first pass's deferred Marionette check; not deferred again.
  - `[low]` `[reject]` (intent #10) The inactive window's neutral selected border is not asserted. The border is `GraphTheme.cardSelectedBorder`, resolved from the same inactive tokens the asserted `ringSelect` uses; an extra assertion adds no behaviour.
  - `[low]` `[reject]` (intent #11) Only `RecordedGraphLayout` implements the new accessors and fixture prefixes stand in for jj's. Live data is 10.12's (the intent's Never list).
  - `[low]` `[patch]` carried (intent #12) The pan gate moved from `isOnCard` to "a child claimed the press". The first pass's verification-gap patch, with its tests.
  - `[low]` `[patch]` (verification-gap #1) Nothing tested the hover hand-back of a hovered card that unmounts (`RenderGraphCard.detach`). Added "a hovered card that leaves the viewport gives its hover back" (graph_card_test.dart, in the viewport): hover by the controller, scroll the card out, expect `hovered` null.
  - `[low]` `[patch]` (verification-gap #2) No root case without the immutable flag, so `GraphCardData.of`'s `isRoot ||` was unpinned. Added the "root without flag" case to the hatch test.
  - `[low]` `[patch]` (verification-gap other #1) `syntheticLayout` reported its root as mutable, against `GraphLayout.isImmutable`'s contract ("the root included"). It now passes a `flags` list with the root's immutable bit (synthetic_layout.dart).
  - `[low]` `[reject]` (verification-gap other #2, grouped with blind #13 and edge #5) `RenderGraphViewport.isOnCard` has no production caller since the pan gate moved. It is the card-rect geometry probe the 10.1 viewport tests use to pick press points; deleting it means rewriting six of those tests, and nothing diverges meanwhile.
  - `[low]` `[patch]` (blind #1) The conflict and merge flags hold their glyph from layout, but the `icons` setter only repainted, so a registry that arrives after the first layout left them blank. The setter now marks layout.
  - `[low]` `[reject]` carried (blind #2) `GraphCardData` has no value equality, so every `GraphCard` rebuild relayouts. Same as the first pass's blind #4: rebuilds come from theme / appearance changes (which relayout anyway) or new data.
  - `[false]` `[reject]` carried (blind #3) "A right-click or the VoiceOver Actions action opens the menu while actions are disabled." Same as the first pass's edge #3: the spec disables only ••• and the add-bookmark circle.
  - `[low]` `[reject]` carried (blind #4) A second right-click closes the open menu, and a right-click does not select. The first pass's blind #10: the controller methods are placeholders that 10.15 overrides; selection on right-click is 10.6's.
  - `[low]` `[reject]` (blind #5) `openMenu` / `openBookmarks` drop the anchor and `openBookmarks` is empty. The spec makes them overridable placeholders (10.15 builds the menu and the popover); the catalogue has no popover to open.
  - `[low]` `[patch]` (blind #6, grouped with edge #3) The legend pill printed raw names while jj's `CommitRef` and `GraphRef.display` quote them (`"my bm"@"up stream"`). `graphLegendParts` now runs the name and the remote through `jjRevsetSymbol`; test added.
  - `[low]` `[patch]` (blind #7) The ticket regex matched inside words (`fix/iOS17-2-crash` → `S17-2`, `fix/iO` dropped). It now needs a word start (`(?<![A-Za-z0-9])`); test added. Lowercase keys stay unmatched, as the DS's regex.
  - `[low]` `[reject]` (blind #8) `paint` writes `_addWasRevealed`. The latch reads the state painted on screen, which is what the fade-out must follow; moving it into three listeners adds branches for no observed defect.
  - `[false]` `[reject]` (blind #9) "A Detailed ↔ Compact remap keeps the old id in the label." A test that remaps one widget instance from 40 to 62 px (no build) read the new 8-character id without any change to the code: the relayout refreshes the semantics node.
  - `[low]` `[reject]` (blind #10) Compact yield leaves the space freed by folding tags empty instead of regrowing the subject. It takes three or more workspaces on a narrow compact card, and the recompute adds a yield branch; the spec's order (the subject first) holds.
  - `[low]` `[reject]` (blind #11) The pill shows no disabled look and no menu-open fill. The spec disables only ••• and the add circle; the menu-open part is carried from the first pass's blind #11 (false, graph.css:22 / :85).
  - `[low]` `[reject]` (blind #12) The reveal rule exists in the State and in the render box. Both read the same controller and `inactive`; the State only drives the animation, and the tests cover both through the hit and paint witnesses.
  - `[low]` `[reject]` (blind #13) Grouped with verification-gap other #2.
  - `[low]` `[reject]` (blind #14) `_CardStates._matrix` recreates the catalogue's controllers in `build` on a knob change. Catalogue-only; the old controllers are swapped in the same frame, `removeListener` after dispose is allowed, and the smoke test pumps the use case.
  - `[low]` `[reject]` (blind #15) The name-shortening loop steps 1 px and `_paintIcon` opens a `saveLayer` per glyph. The loop runs only for named workspaces too wide for the line; the layer per glyph is `RenderZanshinIcon`'s own way to tint a picture.
  - `[low]` `[patch]` (blind #16) Missing tests for new render paths. Added the detach hand-back (verification-gap #1) and the quoted pill (blind #6); the icons setter change is one line; disabled secondary and Actions are by design (blind #3).
  - `[low]` `[reject]` (edge #1) `paintGraphHatch` loops forever for `period <= 0`. Its only callers pass 6 and 3 (constants).
  - `[maybe-false]` `[reject]` (edge #2) A re-attached card would keep a stale repaint layer for state changed while detached. The viewport drops unlaid cards (they are disposed, not re-attached; pinned ones stay laid out, graph_viewport_render.dart:410-436); only a reparented ancestor could re-attach one, which nothing does. If true it would be low.
  - `[low]` `[patch]` (edge #3) Grouped with blind #6.
  - `[low]` `[reject]` (edge #4) Each distinct bookmark set registers a new `CustomSemanticsAction` label in its static table. The spec mandates "Bookmarks: <names>"; the table grows by short strings per distinct set.
  - `[low]` `[reject]` (edge #5) Grouped with verification-gap other #2.

## Design Notes

- **Why a leaf `RenderBox`, not text slots.** A `Text` slot would rebuild on the minute tick, and hover and selection must build nothing. The splash card already paints its texts with `TextPainter`s. One node with custom semantics actions is also better VoiceOver than three nested buttons.
- **Why the inflated child.** `RepaintBoundary` (10.1's delegate) hit-tests only inside its size, so the affordances at ±11 must be inside the child. The epic's item 8 intends exactly this. The harness pads `TestCard` by the overhang, so 10.1/10.2's witnesses keep their rects.
- **Claude's proposals** (design questions):
  - (d) The author is the first word of the name, else the email's local part (what `jj log` shows), else nothing.
  - (e) Hidden and divergent: jj's `/offset` on the id, and the word in the label. Conflicted and unsynced refs: jj's `??` / `*` on the legend. Other workspaces: per the 2026-10-16 note. Pending: 10.9.
  - (f) Tags are not shown: the design shows none, and the inspector (10.8) lists them.
  - (g) The legend leads with jj's first ref.
  - (h) The relative date as in Always.
  - Selection is paint-only: 0 builds, stricter than the epic's "exactly 2".
- **The root's menu** offering only New change on top is 10.15's; the card only shows •••.

## Verification

Gate rule for this run: no `cargo make test` / `test-full` / `coverage`.

**Commands:**
- `(builtin cd /Users/ralph.bergmann/development/projects/privat/Zanshin/app && flutter test test/features/graph test/widgetbook)` -- expected: all pass.
- `(builtin cd /Users/ralph.bergmann/development/projects/privat/Zanshin/packages/zanshin_ui && flutter test test/design)` -- expected: all pass.
- `dart analyze --fatal-infos app packages/zanshin_ui` -- expected: no issues.
- `dart format --set-exit-if-changed app packages/zanshin_ui` -- expected: exit 0.

**Manual checks (if no CLI):**
- Best-effort Marionette check of `graph/card/states` and `graph/viewport/recording`. Record the outcome, or why it could not run.

**Verification notes (2026-10-30, after the review patches):**
- `flutter test --reporter=failures-only test/features/graph test/widgetbook` (app): 466 passed. The first run after the patches failed 3 smoke cases (a deferred hover reset wrote to a disposed controller); fixed with `GraphCardController.isDisposed`, then green.
- `flutter test --reporter=failures-only test/design` (packages/zanshin_ui): 74 passed.
- `dart analyze --fatal-infos app packages/zanshin_ui`: no issues.
- `dart format --set-exit-if-changed app packages/zanshin_ui`: 0 changed.
- Marionette check: not run. The unattended synchronous run cannot hold `flutter run -d macos -t widgetbook/main.dart`. Deferred (frontmatter, deferred-work.md "Surfaced in Story 10.3").
- No Rust, FFI, schema or jj verb changed, so no cargo, clippy, codegen or parity check applies. The full gate is left to the story loop's end, per this run's gate rule.

**Verification notes (2026-10-30, follow-up review pass, after its patches):**
- `flutter test --reporter=failures-only test/features/graph test/widgetbook` (app): 467 passed.
- `flutter test --reporter=failures-only test/design` (packages/zanshin_ui): 74 passed.
- `dart analyze --fatal-infos app packages/zanshin_ui`: no issues.
- `dart format --set-exit-if-changed app packages/zanshin_ui`: 0 changed.
- Blind #9 was refuted by experiment: a remap test of one widget instance (40 → 62 px, no build) read the new id with the code unchanged; the test was not kept.
- No Rust, FFI, schema or jj verb changed: no cargo, clippy, codegen or parity check. No full gate, per this run's gate rule.

## Auto Run Result

Status: done. Code commit `ecfa75e8856ae0f2c809bddbe608aa680878d6fc`, plus the follow-up commit that carries this spec, `deferred-work.md` and `sprint-status.yaml`.

**Items from the dispatch:**
- **I1** (the card's semantics label must carry its date): **fixed** in `ecfa75e8856ae0f2c809bddbe608aa680878d6fc`. `graphCardLabel` ends its date part with the spoken relative time and the axis's day label ("40 minutes ago, Today"), and the label refreshes on the minute tick and across midnight (tests in `graph_card_test.dart`). The deferred-work.md entry is marked resolved.

**Summary.** The commit card of Story 10.3, with its 2026-09-28 to 2026-10-26 notes:
- `GraphCard` / `RenderGraphCard`: one leaf RenderBox for the detailed (62) and compact (40) card, painting with `TextPainter`s and registry glyphs.
  - Detailed: the subject over the meta line (@ / `name@` slots, the id as jj's `shortest(n)` plus `/offset`, the author's first name, the relative date, "empty", conflict, merge). Compact: one line. Both yield orders, with nothing past W − 24.
  - States: hover and menu-open, selected (`ringSelect`), @ (`ringWc`, the tint) and @-selected (`ringWcSelect`), the 135° hatch on immutable cards and the root, the keyboard focus ring, the inactive window, disabled affordances at .4.
  - The bookmark legend (≤ W/2 − 34; ticket key or last segment, `@remote`, jj's `??` / `*`, `+N`) or the hover add-bookmark circle; the hover ••• with fade and `--motion` scale, fading out too.
  - Hits only the card and its revealed affordances; one semantics node with "Actions" and "Bookmarks: …" / "Add bookmark" custom actions.
- `GraphCardController`: notifiers for hovered, selected, focused, menu-open, now and actionsEnabled, plus overridable `select` / `openMenu` / `openBookmarks`. Hover, selection and the tick build no card.
- `HatchSwatch` and `paintGraphHatch`.
- `GraphLayout` gains the change id, its prefix length and offset, immutable/hidden/divergent, refs (`GraphRef`, printed as jj prints them), working copies, `workspaceName` and content (`GraphCommitContent`). `RecordedGraphLayout` stores them, and `fromSpec` reads `immutable`.
- The viewport lays each card out with an 11 px overhang and arms its pan only when no card claimed the press. `GraphTheme` gains 17 card roles.
- The catalogue: `graph/card/states` (27 cases plus the swatch), and fake content in the viewport use cases. The placeholder card is gone.

**Files:**
- `app/lib/src/features/graph/graph_card.dart` (new): the controller, `GraphCardData`, the date, legend and label helpers, the widget.
- `app/lib/src/features/graph/graph_card_render.dart` (new): `RenderGraphCard`.
- `app/lib/src/features/graph/hatch_swatch.dart` (new): the hatch painter and `HatchSwatch`.
- `app/lib/src/features/graph/graph_layout.dart`: `GraphRef`, `GraphCommitContent`, `jjRevsetSymbol`, `jjRefSymbol`, the new accessors.
- `app/lib/src/features/graph/recorded_graph_layout.dart`: the fact lists, flag bits, the fixture prefix stand-in, `fromSpec` callbacks.
- `app/lib/src/features/graph/graph_viewport_render.dart`: overhang 11, the inflated child box, the inflated semantics clip, the `_childHit` pan gate.
- `packages/zanshin_ui/lib/src/design/graph_theme.dart` and its test: the card roles. `packages/zanshin_ui/lib/zanshin_ui.dart`: exports `ZsGradientStop`, `ZsLinearGradient`, `ZsShadowStack`.
- `app/widgetbook/folders/graph.dart`, `app/widgetbook/graph/fake_content.dart` (new), `synthetic_layout.dart`; `placeholder_card.dart` deleted.
- `app/test/features/graph/graph_card_test.dart` (new), `graph_harness.dart`, `app/test/widgetbook/catalogue_extension_test.dart`, `catalogue_smoke_test.dart`.

**Review.** 40 findings: 0 high, 6 medium, 30 low, 4 false.
- Patched, 16 rows in 14 entries (5 medium, 9 low):
  - the stale hover key after a detach (medium);
  - the spoken date in the label (medium);
  - workspace names quoted by jj's `is_safe_identifier`, not `format_symbol` (medium);
  - a test of the card inside the viewport (medium);
  - the pan gate for presses on overhang affordances (medium);
  - the low ones: the semantics bookmarks action honours `actionsEnabled`; one `graphLocalDay`; no layout for compact cards on the tick; the add circle's pointer-over glyph; the tap fallback rect; the latched fade-out of the add circle; `GraphRef.display` quoting; tests for the tick's label and the controller's menu toggle.
- Deferred, 2, mirrored to deferred-work.md:
  - the `+N` and ••• tooltips (10.6);
  - the Marionette check.
- Rejected, 22 rows, each with its reason in the Review Triage Log. Among them:
  - value equality on the card data;
  - the flags' clip in an extreme narrow case;
  - the legend's narrow-width yield (the design's cap);
  - the fixture prefix for equal ids;
  - right-click toggling (10.15's);
  - test hygiene;
  - the intent-alignment divergences: slot children, per-slot layout, z-order wiring, edges, resignKey, the 10.1 witnesses;
  - 4 false.
- Follow-up review recommended: **true**. This was the first pass, and five medium entries were patched. The specific risk no reviewer has seen: the viewport's new `_childHit` pan gate, which now decides pan arming for every press (only targeted tests cover it), and the deferred hover reset in `RenderGraphCard.detach`.

**Residual risks:**
- Nobody has looked at the cards on screen yet. Pixel offsets of badges, pills and the hatch against the DS cards are unverified, and the test font is not Inter or JetBrains Mono.
- With the 1 px mouse tap slop, a click that wobbles 2 px on an affordance neither opens it nor pans (as on any Flutter control).
- The fixture prefix stand-in (shortest prefix among the layout's own ids) is not jj's index-wide `shortest()`; real prefixes arrive with 10.12.

### Follow-up review pass (2026-10-30)

Status: done. Four review layers (blind, edge case, verification gap, intent alignment) over the code diff since `fd0a5499c43d46198c6bbf6a9d10b958fed462c5`.

**Changes:**
- `app/lib/src/features/graph/graph_card.dart`: `graphLegendParts` prints the name and remote as jj's revset symbols (quoted when not an identifier, as `GraphRef.display`), and a ticket key must start a word.
- `app/lib/src/features/graph/graph_card_render.dart`: the `icons` setter marks layout, since the flag items hold their glyph from layout.
- `app/widgetbook/graph/synthetic_layout.dart`: the root carries the immutable flag, as `GraphLayout.isImmutable` documents.
- `app/test/features/graph/graph_card_test.dart`: tests for the quoted pill and the word-start ticket, a root without the flag, and the hover hand-back of a card that leaves the viewport.

**Review.** 37 findings: 0 high, 0 medium, 30 low, 6 false, 1 maybe-false; 7 carried from the first pass.
- Patched, 7 entries, all low: the pill's quoting; the ticket regex; the icons setter; the synthetic root flag; the detach hand-back test; the flagless-root test; the missing-tests entry (covered by those).
- Deferred: none new (the carried Marionette item stays deferred), so `deferred-work.md` gains no entry.
- Rejected, each with its reason in the triage log: the spoken date (intent #1), the root's "root()" with null content, the inactive border assertion, the fixture data seam, `isOnCard` (kept as the 10.1 tests' geometry probe), the anchors and empty `openBookmarks` (10.15's), the paint-time latch, the compact subject regrow, the pill's disabled look, the duplicated reveal rule, the catalogue matrix in `build`, the yield loop and glyph layers, `paintGraphHatch` with period ≤ 0, the semantics action table, the re-attach staleness (maybe-false: no re-attach path exists), and 6 false (compact "empty", menu-over-@ precedence, the `+N` tag's border, catalogue builds, the remap label, disabled right-click).
- Follow-up review recommended: **false**. This follow-up pass patched no high finding (0 high, 0 medium, 7 low patched); the work has converged.

**Residual risks:** unchanged from the first pass; the cards are still not checked on screen against the DS (the deferred Marionette item).
