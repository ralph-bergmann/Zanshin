---
title: 'Story 10.45 — Tags on the cards; the card menu opens by right-click only'
type: 'feature'
created: '2026-11-16'
status: 'done'
baseline_revision: '4b388ff3c1f2b7cb3040bd8b4d2766f9531ba4b8'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/.claude/skills/design-artifacts/SKILL.md'
warnings: ['oversized']
deferred: []
---

<intent-contract>

## Intent

**Problem:** The graph drops tags (only bookmark refs become `GraphRef`s), so cards, the inspector and the peek never show them and a change cannot get a tag from the graph; and every card still carries a ••• button although a right-click opens the same menu.

**Approach:** Build section 1 of the approved `design/Refs Study.html`: the layout keeps tag refs, a calmer tag pill hangs on the card's bottom edge, right, and opens a tag popover (the bookmark popover's pattern, with 10.44's delete flow); the ••• button goes, the card menu opens by right-click, the context-menu key, ⇧F10 and a VoiceOver "Show menu" action, and it ends with "Create bookmark here…" / "Create tag here…". DS synced through #26 plus the Refs Study.

## Boundaries & Constraints

**Always:**
- **Layout:** `GraphLayout` gets `List<GraphRef> tagsOf(int node) => const <GraphRef>[]` (default body); `BackendGraphLayout.tagsOf` keeps `TopologyRefKind.tag` refs exactly as `refsOf` keeps bookmarks (stack nodes: none); `RecordedGraphLayout` takes an optional `tags` list like `refs` (constructor and `fromSpec`). `refsOf` stays bookmarks only, so every bookmark consumer (bookmark legend and popover, drag, inspector bookmark chips, settings) is unchanged. `GraphCardData` gains `tags` from `tagsOf`.
- **Tag legend** (`graph_card_render.dart`): on a non-root card with tags, the bookmark legend's pill mirrored to the bottom edge — hangs `_affordOut` below the card's bottom, right-aligned `_affordRight` in, `_pillH` high, the same `graphLegendParts` of the **first tag in jj's order**, the same shrink order and the same max width (`card.width/2 − 34`, so it stays right of the centre and the parent line is free), and `+N`. Calmer than the bookmark pill: `ZI.tag` glyph, every text `cardTextDim` at weight 400 (no bold main or sigil), fill `cardFill` (hover `cardFillHover`), border always `cardBorder`. New slot `GraphCardSlot.tagLegend` (+ `debugTagLegendTexts`), area `tags`, hover part `GraphCardHoverPart.tags` with tooltip `cardTags(names)` ("Tags: {names}", each `GraphRef.display`). A press on it starts no drag. Detailed and compact cards both show it; immutable cards too.
- **Tag popover** opens like the bookmark popover — a click (tap up) on the tag pill and a VoiceOver custom action "Tags: …" open it, while `actionsEnabled`. `GraphCardController` gets `tagsOpen` / `tagsAnchor` / `openTags(key, anchor)`; `openMenu`, `openBookmarks` and `openTags` close each other, `closeMenus` and `dispose` cover it. A `GraphTagMenuHost` (beside `GraphBookmarkMenuHost` in `graph_view.dart`, same `_MenuHost`, identifier `tag-menu`, label "Tags") shows `graphTagMenuEntries`, a pure function over the layout:
  - per local tag: a mono row `name` with its state in the right plain-text column (`ZsMenuItem.shortcut`): "on <remotes>" (comma-joined remotes, not `git`, that hold the name with a target in jj's `--all-remotes` tag rows) or "local only"; "Reading tags…" disabled-state text while the read is null, the read failure text when it failed. Its submenu: "Delete…" (danger, cmd `jj tag delete <name>`) through the `deleteTag` callback (10.44's flow decides dialog or not), disabled while the read failed; without a callback it runs `GraphTagDelete([name])`.
  - per remote tag ref on the card (not `git`): `name@remote` with Track / Untrack (`GraphTagTrack` / `GraphTagUntrack`) as the read says, like the bookmark popover's remote rows.
  - separator, then "Create tag here…" (`jj tag set <name> -r <id>`) and "Move existing here…" (`jj tag set <name> -r <id> --allow-move`), both through the name sheet (10.46 replaces the move field with a picker later).
  - every row disabled with `blocked` while the runner is busy or stale.
- **Tag reads and delete wiring** (the architecture test forbids `graph` → `bookmarks`): `GraphView` gets `tags` (`Future<List<Bookmark>> Function()?`, rows shaped like `tagRow`) and `deleteTag` (`GraphDeleteBookmark?`, same `(name, rows)` shape); `ProjectScope.remoteTags()` maps `_repo.handle.tags()` through `tagRow`; `project_graph_host.dart` passes `deleteTag: (name, rows) => scope.refDelete.delete(RefDeleteRequest.of(RefKind.tag, name, rows))`, as 10.44 wired bookmarks.
- **New verb** `GraphTagSet(names, {revision, allowMove})` in `graph_ports.dart`: command `jj tag set <names as revset symbols> [-r <revision>] [--allow-move]`, `pendingKeys` `{?revision}`, dispatched to `handle.tagSet(names, revision:, allowMove:)`; texts in `graph_toasts.dart` `_text` ("Set tag … on …") and `AppMenuModel.actionName`.
- **No •••:** remove the ••• affordance everywhere in the card (`GraphCardSlot.more`, `_Area.more`, `GraphCardHoverPart.more`, `_more`, `_pointerOnMore`, `GraphCardIcons.more`, `cardActionsTooltip`); the reveal animation stays for the add-bookmark circle. Right-click keeps opening the card menu at the pointer.
- **Keyboard:** in `GraphView._onKey`, `LogicalKeyboardKey.contextMenu` and ⇧F10 open the focused card's menu anchored at the card's global rect (a new `GraphCardController.cardRect` lookup the canvas sets from a new `GraphViewportController.globalCardRectOf(key)`); a stack card or no focused card ignores the key; a pointer focus is cleared first, as Enter does.
- **VoiceOver:** the card's custom action reads "Show menu" (new `cardShowMenu`; replaces the "Actions" label there) and anchors at the card rect; `cardActions` stays the menu's own semantic label.
- **Card menu group:** every non-root card menu (mutable and immutable) ends with a separator, "Create bookmark here…" (`ZI.bookmark`, `jj bookmark create <name> -r <id>`, `GraphBookmarkCreate`) and "Create tag here…" (`ZI.tag`, `jj tag set <name> -r <id>`, `GraphTagSet`), identifiers `card-menu-create-bookmark` / `card-menu-create-tag`, disabled with `blocked`, each through the name sheet. `GraphCardMenuHost` therefore hosts the name sheet too: share the bookmark host's sheet overlay (`OverlayPortal` + `GraphNameSheet`) as one private widget used by all three hosts — no copy.
- **Tags elsewhere:** the inspector header shows tag chips after the bookmark chips (same chip, `ZI.tag` glyph, name or `name@remote`, no state word, right-click Copy name, not draggable); the peek card shows a row of the change's tags (tag glyph + mono names, `textDim`, wrapping) above the meta line, only when there are tags.
- Strings via `app_en.arb` + `flutter gen-l10n` (output committed): `cardTags`, `cardShowMenu`, `cardMenuCreateBookmark`, `cardMenuCreateTag`, `tagMenuLabel`, `tagMenuOnRemotes`, `tagMenuLocalOnly`, `tagMenuReading`, `tagMenuReadFailed`, name-sheet titles for tag create/move, toast and menu-name texts; drop `cardActionsTooltip`. jj's words and commands stay literals marked `// l10n-ignore`. Zs controls and DS tokens only. Tests never touch Ralph's settings or jj config; jj only in temp dirs tests create.
- **DS** via `design-artifacts` (modes C/E, then F's sync line), no publish: `ChangeCard` loses the ••• (`onMenu`, `menuOpen` docs, `zs-card-more`) and gains `tags` (the bottom-right tag legend, calmer, in `graph.css`) in `.jsx` / `.d.ts` / `.prompt.md`; `graph.card.html` shows a card with a bookmark and two tags, an immutable card with a tag, and the open tag popover; `components/menus/card-menu.card.html` gets the new group; `_ds_bundle.js` blocks + `sourceHashes`; readme Sync line (Refs Study section 1 with Story 10.45); one dated line `- 2026-11-16 (Story 10.45) — …` at the end of `design/DESIGN-SYSTEM-SYNC.md`. Do not touch the study files.

**Never:**
- Dragging tags; the name-field rules and the move picker (10.46); tag search hits (10.47); a hover "+" for tags; bookmark rows in the card menu besides "Create bookmark here…".
- A hover-opened popover (10.15's rule: a focus-taking menu never opens on hover).
- Rust, FFI or schema changes (9.59 already carries every tag verb and the topology's tag refs).
- Publishing the DS, syncing a canvas, the Marionette check (the console session's).
- The full gate (`cargo make test` / `test-full` / `coverage`) — this run uses targeted checks only.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Bookmark + two tags | refs `[release/1.5.x]`, tags `[v1.5.0-rc1, v1.5.0-rc2]` | bookmark pill top-right; tag pill bottom-right `v1.5.0-rc1 +1`, right of centre | — |
| Long tag name | tag `nightly/2026-11-14-very-long` on a 160-wide card | prefix shrinks first, pill ≤ W/2 − 34 | — |
| Tag popover | tags `v1` (tracked on origin), `v2` (local) | rows `v1` "on origin", `v2` "local only"; then Create tag here…, Move existing here… | read pending → "Reading tags…"; failed → Delete… disabled with the reason |
| Delete… on `v1` | tracked on origin | 10.44's sheet with the three tag choices | refusal → refusal toast |
| Delete… on `v2` | local only | `jj tag delete v2` at once, toast Undo | — |
| Create tag here… | card without refs, name `v9` | `jj tag set v9 -r <id>`; the pill appears after the reload | existing name → jj's refusal toast with its hint (`--allow-move`) |
| Move existing here… | `v1` elsewhere | `jj tag set v1 -r <id> --allow-move` | — |
| Keyboard | focused card, ⇧F10 / context-menu key | card menu anchored at the card | stack card / no focus → ignored |
| Right-click | any card | card menu at the pointer; no ••• anywhere | — |

</intent-contract>

## Code Map

- `app/lib/src/features/graph/graph_layout.dart` -- `GraphRef` `:61`, `GraphLayout.refsOf` `:281` (add `tagsOf` beside it with a default body; only `BackendGraphLayout` and `RecordedGraphLayout` extend `GraphLayout`).
- `app/lib/src/features/graph/backend_graph_layout.dart:218-225` -- `refsOf` filters `TopologyRefKind.bookmark`; add `tagsOf` filtering `.tag`.
- `app/lib/src/features/graph/recorded_graph_layout.dart:44,58,83,118,265,350` -- `refs` plumbing to mirror for `tags`.
- `app/lib/src/features/graph/graph_card.dart` -- `GraphCardHoverPart` (~`:20-36`; drop `more`, add `tags`), `GraphCardController` `:49` (`menuOpen` `:84`, `menuAnchor` `:175`, `bookmarksOpen`/`bookmarksAnchor` `:178-181`, `openMenu` `:184`, `openBookmarks` `:195`, `closeMenus` `:206`, `dispose` `:219`; add `tagsOpen`/`tagsAnchor`/`openTags`/`cardRect`), `GraphCardData` `:263-315` (add `tags`), `graphLegendParts` `:480`, `GraphCardIcons` `:554` (drop `more`, add `tag`), icon lookup `:719-725`, reveal animation `:636-694`.
- `app/lib/src/features/graph/graph_card_render.dart` -- slots `:57-64`, `_Area` `:69`, geometry `:108-115`, `_moreRevealed`/`_addRevealed` `:330-332`, `debugSlots`/`debugLegendTexts` `:504-515`, `performLayout` `:553-566` (`_more` `:565`), `_layoutBookmarkControl` `:765-830` (factor the pill layout so the tag pill reuses it with its own anchor edge and styles), legend paint `:936-966`, affordance paint `:968-986`, `_areaAt` `:1086`, hover `:1119-1158`, `_dragPayloadAt` `:1164`, `_onTapUp` `:1182`, `_onSecondaryTapUp` `:1200`, semantics `:1229-1265` (`_semanticMenu` anchors at `_more` today).
- `app/lib/src/features/graph/graph_canvas.dart:442-467` -- `_listen`/`_unlisten` set controller callbacks (set/clear `cards.cardRect` here); `_syncPeek` `:690-728` treats every non-body hover part generically (tooltip, no peek) — the `tags` part needs nothing extra.
- `app/lib/src/features/graph/graph_viewport_render.dart:164` -- `cardRectOf` (viewport coordinates); add `globalCardRectOf` via the viewport's `getTransformTo(null)`.
- `app/lib/src/features/graph/graph_view.dart` -- params `:48-72` (add `tags`, `deleteTag`), `_onKey` `:250-310` (add the menu keys), hosts `:402-410` (add `GraphTagMenuHost`).
- `app/lib/src/features/graph/graph_card_menu.dart` -- `GraphDeleteBookmark` `:37`, `graphCardMenuEntries` `:109-263` (root `:152`, immutable `:175-190`, mutable `:193-262`: append the group), `graphBookmarkMenuEntries` `:271-446` (pattern for `graphTagMenuEntries`), `_MenuHost` `:488-647`, `GraphCardMenuHost` `:652-700`, `GraphBookmarkMenuHost` `:707-856` (read `_load`, `_delete`, sheet overlay `_askFor`/`_close`/`_closed` + `OverlayPortal` `:812-833` — extract it for all three hosts), `GraphNameSheet` `:861`.
- `app/lib/src/features/graph/graph_ports.dart` -- `GraphBookmarkCreate` `:503-523` (pattern for `GraphTagSet`), tag verbs `:657-715`, `RepoGraphActions.run` switch `:1019-1053`; `RepoHandle.tagSet(names, {revision, allowMove})` (`packages/zanshin_core/lib/src/worker/handle.dart:2787`).
- `app/lib/src/features/graph/graph_toasts.dart:325-354` -- `_text` cases; `app/lib/src/app/menu/app_menu.dart:212-226` -- `actionName` cases.
- `app/lib/src/features/graph/graph_inspector.dart:1371-1372` (header `_Chips`), `:2346-2420` (`_Chips`: add tag chips, no drag).
- `app/lib/src/features/graph/graph_peek.dart:150-219` -- the peek's column; tags row before the meta `Wrap`.
- `app/lib/src/features/home/project_scope.dart:323-324` (`remoteBookmarks`; add `remoteTags`), `app/lib/src/features/home/project_graph_host.dart:189-201` (GraphView wiring), `app/lib/src/features/bookmarks/bookmark_list_model.dart` `tagRow` (Tag → Bookmark row), `app/lib/src/features/bookmarks/ref_delete.dart:21-50` (`RefDeleteRequest.of`).
- Icons: `ZI.tag` exists (10.44), `packages/zanshin_ui/lib/src/icons/zanshin_icon.dart`.
- `app/lib/l10n/app_en.arb:332-356` -- card strings (`cardActions`, `cardBookmarks`, `cardActionsTooltip`, peek hints).
- Tests that break with •••'s removal (rewrite to right-click / the new semantics label, never just delete their witness): `test/features/graph/graph_card_test.dart` (`RecordingController` `:80-86`; :689, :854, :880-985, :1011-1050, :1130-1244, :1364-1400), `graph_view_test.dart:1128-1145`; still valid: `graph_card_menu_test.dart` right-click `:579-593`, `openMenu` direct calls `:597-618`, `:705`. Other tests to extend: `graph_card_menu_test.dart` (entries, hosts), `graph_ports_test.dart` (command texts `:1355-1420`; real-repo verbs `:1100-1160`), `graph_toasts_test.dart:400-420`, `test/app/menu/app_menu_test.dart:655-662`, `backend_graph_layout_test.dart`, `recorded_graph_layout_test.dart`, `graph_inspector_test.dart`, `graph_peek_test.dart`, `test/features/home/project_graph_host_test.dart` (wiring asserts, as 10.44 added), `test/architecture/layers_test.dart` (must stay green).
- Widgetbook: `app/widgetbook/folders/graph.dart` (`Card` folder `:358`, legend use cases `:1508-1575`, `_single(refs:)` `:1473`): add tag use cases (bookmark + two tags, immutable with a tag, long tag), the tag popover open, the card menu with the new group.
- DS: `_bmad-output/implementation-artifacts/design_system/components/graph/{ChangeCard.jsx,ChangeCard.d.ts,ChangeCard.prompt.md,graph.css,graph.card.html}` (••• at `ChangeCard.jsx:9-10,60,67-69`, `.d.ts:39-41`), `components/menus/card-menu.card.html`, `_ds_bundle.js` (header `sourceHashes`), `readme.md:22`; `design/DESIGN-SYSTEM-SYNC.md` (append). Reference only: `design/refs-study.jsx:70-165` (cards, `RefPill`, menu group), `design/refs-study.css:29-36` (`.rs-tg`: bottom −11 px, max `50% − 14px`, dim text, plain border).

## Tasks & Acceptance

**Execution:**
- `app/lib/src/features/graph/graph_layout.dart`, `backend_graph_layout.dart`, `recorded_graph_layout.dart` -- `tagsOf` + recorded `tags` -- unit tests: backend keeps tags out of `refsOf` and in `tagsOf`; recorded passes them through.
- `app/lib/src/features/graph/graph_ports.dart`, `graph_toasts.dart`, `app/lib/src/app/menu/app_menu.dart` -- `GraphTagSet` -- tests: command texts (create, `-r`, `--allow-move`, quoted name), toast and menu names, a real temp-repo run (create, then a refused second create, then `allowMove`).
- `app/lib/src/features/graph/graph_card.dart`, `graph_card_render.dart`, `graph_canvas.dart`, `graph_viewport_render.dart` -- tag legend, tag hover/tap/semantics, ••• removal, "Show menu", `cardRect` -- widget tests per witness (pill texts and rect bottom-right right of centre, calm styles, compact and immutable cards, tap opens `openTags`, no drag from it, no `more` slot, right-click opens the menu, semantics labels `['Show menu', 'Bookmarks: …', 'Tags: …']`).
- `app/lib/src/features/graph/graph_card_menu.dart`, `graph_view.dart` -- shared name-sheet overlay, `graphTagMenuEntries`, `GraphTagMenuHost`, card-menu group, menu keys -- tests: tag popover rows/states/actions (reading, failed, on origin, local only, Track/Untrack), Delete… through `deleteTag`, Create/Move tag and Create bookmark through the sheet, the card menu's last group on mutable and immutable cards (none on root), ⇧F10 and the context-menu key open the menu at the card, ignored on a stack card.
- `app/lib/src/features/graph/graph_inspector.dart`, `graph_peek.dart` -- tag chips and the peek's tag row -- widget tests.
- `app/lib/src/features/home/{project_scope,project_graph_host}.dart` -- `remoteTags`, `tags`/`deleteTag` wiring -- extend `project_graph_host_test.dart`.
- `app/lib/l10n/app_en.arb` + `flutter gen-l10n`; widgetbook use cases above.
- DS per Boundaries and the DESIGN-SYSTEM-SYNC line.

**Acceptance Criteria:**
- Given a card with a bookmark and two tags, when it shows, then the bookmark pill sits top-right and the tag pill bottom-right shows the first tag and `+1`, right of the card's centre; an immutable card shows its tag the same way.
- Given the tag pill, when it is clicked (or VoiceOver's "Tags: …" action runs), then the tag popover lists both tags with "on origin" or "local only" and offers Create tag here…, Move existing here… and each tag's Delete…, which goes through 10.44's delete flow.
- Given any card, when it shows or is hovered, then no ••• appears; right-click, the context-menu key and ⇧F10 on the focused card open the same card menu, and VoiceOver lists "Show menu".
- Given a card without refs, when "Create tag here…" is confirmed with a name, then `jj tag set <name> -r <id>` runs and, after the reload, the tag pill shows.
- Given a selected change with tags, when the inspector and the peek show it, then both show the change's tags.
- Given the architecture test, when it runs, then `graph` still imports nothing from `bookmarks`.

## Spec Change Log

## Review Triage Log

### 2026-11-16 — Review pass
- verdicts: 26 findings — high 0, medium 1, low 18, false 5, maybe-false 2
- findings:
  - `[false]` `[reject]` (intent) The tag popover opens on a click, the story says "on hovering" — the same sentence says "like the bookmark popover (10.15)", which opens on a click by 10.15's recorded rule (a focus-taking menu never opens on hover); recorded in Design Notes.
  - `[false]` `[reject]` (intent) "Move existing here…" works now through a free-text sheet although its picker is 10.46 — the story lists the row in the popover and only the picker in 10.46; 10.46 replaces the field.
  - `[false]` `[reject]` (intent) The popover also lists remote tags with Track / Untrack — the bookmark popover's pattern the story points to; it adds to, does not contradict, "lists the card's tags".
  - `[false]` `[reject]` (intent) deferred-work.md unchanged — the extra rule mirrors only `deferred:` items, and this pass defers nothing.
  - `[low]` `[reject]` (intent) "Create tag here… and the pill appears" has no end-to-end test — the parts are covered (real-repo `GraphTagSet` run, `BackendGraphLayout.tagsOf` over a real tag, the pill widget tests); an app-level reload test adds a rig for one witness; the Marionette run of the console session covers it.
  - `[medium]` `[patch]` (verification) The tag sheet and popover commands never reach the card-menu fixture and the parity oracle, and the fixture test skips `<name>` lines — patched with the two rows below: the create rows show no placeholder command, the skip is gone, the tag sheet commands are in `card-menu.txt` and the oracle ran them.
  - `[low]` `[patch]` (verification) `ProjectScope.remoteTags` is untested — it now delegates to `RepoTagListSource(_repo).bookmarks()`, covered against a real repo.
  - `[low]` `[patch]` (verification, other) `remoteTags` copies `RepoTagListSource.bookmarks()` — same fix as the row above.
  - `[low]` `[patch]` (verification, other) The card menu's Create bookmark request duplicates the popover's — one `_createBookmarkRequest` helper.
  - `[maybe-false]` `[reject]` (edge) The context-menu key / ⇧F10 on a focused card scrolled out of view anchors the menu off screen — whether `ZsMenuAnchor` clamps the panel into the window was not checked; if true it is low (a keyboard user who scrolled away from the selection), and the fix adds a reveal path from the view to the canvas.
  - `[low]` `[reject]` (edge) A selected member of a collapsed stack opens its own menu at the stack card — it is the selected change, and Enter treats the same focus key the same way; ignoring it adds a branch.
  - `[low]` `[patch]` (blind) The DS caps the tag pill at half the card less 14px, the app at W/2 − 34 — the DS CSS and docs now use the app's rule.
  - `[low]` `[reject]` (blind) The tag pill can cover fanned parent lines right of the centre on a merge card — the approved design places it there, as the bookmark pill on the top edge; the centre line stays free.
  - `[low]` `[reject]` (blind) "on origin" shows for a tag whose remote copy points elsewhere — the tag is on origin; a diverged state is a new state word the design does not have.
  - `[low]` `[reject]` (blind) Keyboard-only users cannot open the tag popover — the bookmark popover has the same path today, and the Tags view (10.44) offers Delete…, Track and Untrack by keyboard; not in the story.
  - `[low]` `[reject]` (blind) "Move existing here…" creates the tag when the name is new — `jj tag set --allow-move` does the same in the CLI; 10.46's picker replaces the field.
  - `[low]` `[patch]` (blind) `remoteTags` repeats existing code — grouped with the verification rows above.
  - `[low]` `[patch]` (blind) `@cardActions`'s ARB description is stale — reworded; `flutter gen-l10n` rerun.
  - `[low]` `[patch]` (blind) Stale ••• references in the DS docs and tokens comments — reworded (readme Cards, kit README, `motion.css`, `contrast.css`); the readme's historical note stays. Checking this also showed the bundle's `ui_kits/desktop/graph.jsx` block still passing `onMenu` with the baseline hash — block and hash re-synced.
  - `[low]` `[reject]` (blind) The DS kit graph shows no tags and no new menu group — the kit is a demo; the components and their cards show both; a kit edit needs a bundle block re-sync for a catalogue nobody ships.
  - `[low]` `[patch]` (blind) The DS tag legend is a `role="button"` span without a tab stop, also when nothing handles it — role and `tabIndex` only with `onTags`.
  - `[low]` `[reject]` (blind) The DS tag legend splits only on `/`, unlike the app's `graphLegendParts` — the DS bookmark legend shortens the same way; cosmetic.
  - `[low]` `[reject]` (blind) The peek's tag row has no `+N` limit — many tags on one change are rare, and folding adds a branch.
  - `[false]` `[reject]` (blind) The card menu's Create rows can be disabled without a reason — only when `ask` is null, which production never passes (`GraphCardMenuHost` always passes it).
  - `[low]` `[reject]` (blind) ⌘⇧F10, ⌥⇧F10 and ⌃⇧F10 also open the menu — harmless, and the guard adds conditions for chords nobody presses.
  - `[maybe-false]` `[reject]` (blind) The keyboard menu may open off screen — same claim as the edge row above, same verdict.

## Design Notes

- **Click, not hover, opens the tag popover:** the story says "on hovering … like the bookmark popover (10.15)", and the bookmark popover opens on a click by 10.15's recorded rule ("a menu that takes focus must not open on hover", spec-10-15 Never + deferred). The tag popover follows the existing popover; hovering the pill shows the "Tags: …" tooltip.
- **First tag in jj's order:** the pill shows `tagsOf(node).first` — jj's `tags()` order (by name). The story's `v1.5.0-rc1 +1` example pairs it with `release/2026-11`, which sorts first in jj; the witness tests use a pair whose jj order puts the named tag first.
- **Separate `tagsOf`, not a kind on `GraphRef`:** the epic says tags become `GraphRef`s; keeping them in their own list leaves every bookmark consumer (legend, popover, drag, chips, settings) untouched instead of adding a kind filter at each.
- **Root:** the root card has no ref controls today (`_layoutBookmarkControl` returns on root) and gets no create group; its menu stays "New change on top" (Claude's proposal, consistent with 10.15's root menu).
- **Tag state wording:** "on <remotes>" counts any non-`git` remote row with a target (tracked or not: the tag exists there); the delete flow still asks only for tracked remotes (10.44's rule).
- **Marionette and DS publish** against `design/Refs Study.html` section 1 are left to the console session.

## Verification

**Commands:**
- `flutter gen-l10n` (in `app/`) -- output committed; `dart run build_runner build --delete-conflicting-outputs` (in `app/`) only if an inject.dart graph changes.
- `flutter test test/features/graph test/features/home test/features/bookmarks test/app/menu test/architecture test/l10n` in `app/` -- expected: pass (the env-pinned `remote_sync_test` case needs `cargo make test-app` and may fail outside it).
- `dart analyze` and `dart format --set-exit-if-changed .` in `app/` -- expected: clean.
- `node --check _bmad-output/implementation-artifacts/design_system/_ds_bundle.js` -- expected: passes.
- No Rust, FFI or jj-verb backend change: no cargo checks, codegen or parity oracle.

**Manual checks:**
- Marionette against `design/Refs Study.html` section 1 and the DS publish — by the console session, not this run.

**Verification notes (2026-11-16, targeted checks per the story loop's gate rule):**
- `flutter gen-l10n` in `app/` — output committed.
- `flutter test test/features/graph test/features/home test/features/bookmarks test/app/menu test/architecture test/l10n test/widgetbook` in `app/` — 1735 pass (after the review patches).
- `flutter test test/design` in `packages/zanshin_ui` — 76 pass (token CSS comments changed).
- `dart analyze` in `app/` — no issues; `dart format --set-exit-if-changed .` in `app/` — 0 changed.
- `cargo test -p zanshin-parity --test oracle card_menu` — passes: the pinned jj accepts every line of `test-fixtures/commands/card-menu.txt`, including the two new `jj tag set` lines.
- `node --check _ds_bundle.js` — passes; the ChangeCard and kit `graph.jsx` `sourceHashes` match the sha256-12 of the files.
- Not run (gate rule): `cargo make test` / `test-full` / `coverage`. No Rust, FFI or schema change, so no clippy, rustfmt or codegen.

## Auto Run Result

Status: done

**Summary.** The graph keeps tags (`GraphLayout.tagsOf`; `refsOf` stays bookmarks). A calm tag pill hangs on the card's bottom-right edge (first tag in jj's order + `+N`, dim regular text, plain border, max W/2 − 34, also on compact and immutable cards). A click or VoiceOver's "Tags: …" opens the tag popover: each local tag with "on <remotes>" / "local only", Delete… through 10.44's delete flow (a `deleteTag` callback wired in `project_graph_host.dart`), remote tags with Track / Untrack, then Create tag here… and Move existing here… (`jj tag set … [--allow-move]`, new `GraphTagSet`). The ••• button is gone; right-click, the context-menu key, ⇧F10 and VoiceOver's "Show menu" open the card menu, which ends with Create bookmark here… and Create tag here…. The inspector header and the peek show the change's tags. DS: `ChangeCard` with `tags`, no •••, the cards and the card-menu group; not published.

**Files changed.**
- `app/lib/src/features/graph/graph_layout.dart`, `backend_graph_layout.dart`, `recorded_graph_layout.dart` — `tagsOf`, recorded `tags`.
- `app/lib/src/features/graph/graph_card.dart` — `GraphCardData.tags`, controller `tagsOpen`/`openTags`/`cardRect`, hover part `tags`, no `more`.
- `app/lib/src/features/graph/graph_card_render.dart` — shared pill layout and paint, tag pill, tag hover/tap/semantics, ••• removed, "Show menu".
- `app/lib/src/features/graph/graph_canvas.dart`, `graph_viewport_render.dart` — `globalCardRectOf` for the keyboard anchor.
- `app/lib/src/features/graph/graph_view.dart` — menu keys, `tags`/`deleteTag`, `GraphTagMenuHost`.
- `app/lib/src/features/graph/graph_card_menu.dart` — shared name-sheet host, shared ref-popover host, `graphTagMenuEntries`, `GraphTagMenuHost`, the card menu's create group.
- `app/lib/src/features/graph/graph_ports.dart`, `graph_toasts.dart`, `app/lib/src/app/menu/app_menu.dart` — `GraphTagSet` and its texts.
- `app/lib/src/features/graph/graph_inspector.dart`, `graph_peek.dart` — tag chips, tag row.
- `app/lib/src/features/home/project_scope.dart`, `project_graph_host.dart` — `remoteTags`, wiring.
- `app/lib/l10n/*` — strings; `app/widgetbook/folders/graph.dart` — tag cards, card menu, tag popover.
- `test-fixtures/commands/card-menu.txt` — two `jj tag set` lines.
- Tests: `graph_card_test`, `graph_card_menu_test`, `graph_view_test`, `graph_stacks_test`, `graph_drag_test`, `graph_inspector_test`, `graph_peek_test`, `graph_ports_test` (real-repo `jj tag set`), `graph_toasts_test`, `backend_graph_layout_test`, `recorded_graph_layout_test`, `project_graph_host_test`, `app_menu_test`, `graph_harness`.
- DS (`design_system/`): `ChangeCard.{jsx,d.ts,prompt.md}`, `graph.css`, `graph.card.html`, `immutable.card.html`, `card-menu.card.html`, kit `graph.jsx` + README, `_ds_bundle.js` + hashes, `_adherence.oxlintrc.json`, `_ds_manifest.json`, `readme.md`, token comments; `design/DESIGN-SYSTEM-SYNC.md` line.

**Review.** 26 findings. Patched (1 medium, 7 low entries): tag sheet commands into the fixture and the oracle with the create rows' placeholder commands removed (medium); `remoteTags` delegates to `RepoTagListSource`; one `_createBookmarkRequest`; `@cardActions` description; the DS tag pill width rule; the DS tag legend's button role only with `onTags`; stale ••• wording in DS docs and token comments; the stale kit `graph.jsx` bundle block and hash. Deferred: none. Rejected: hover-vs-click (false, 10.15's rule), interim move field (false, 10.46), remote tag rows (false, the bookmark popover's pattern), deferred-work unchanged (false, nothing deferred), no app-level "pill appears" test (low, parts covered, console Marionette), off-screen keyboard menu (maybe-false ×2, low if true, needs a reveal path), selected stack member's menu (low, same as Enter), pill over fanned merge lines (low, approved design), "on origin" for a diverged remote (low, no such state word), keyboard path to the tag popover (low, Tags view covers it, not in the story), Move creates a new tag (low, CLI behaviour, 10.46), DS kit without tags (low, demo), DS legend `/`-only split (low, cosmetic), peek without `+N` (low, rare), Create disabled without reason (false, production passes `ask`), extra ⇧F10 modifiers (low, harmless).

**Follow-up review:** not recommended — this pass patched 0 high and 1 medium entry.

**Deviation / notes.** The tag popover opens on a click (10.15's rule), not on hover. The card menu's create rows show no command (the name sheet shows the live one), because the epic forbids placeholder commands. `backend_graph_layout_test` sets a tag, which makes that commit immutable under jj's default `immutable_heads()`; the suite passes.

**Residual risks.** No visual check against the Refs Study and the DS cards (Marionette and DS publish belong to the console session). The keyboard-opened menu on a card scrolled out of view was not checked in the running app. The full gate (incl. coverage) runs at the end of the story loop.
