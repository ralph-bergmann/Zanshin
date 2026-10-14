# Zanshin Design System

Zanshin (残心 — "the lingering mind": the calm attention that stays after an action) is a **desktop client for Jujutsu (`jj`)**, the Git-compatible version control system. Its one idea: **the change graph owns the window**. Every control floats above it on glass islands; the working copy `@` is always findable; every edit can be undone.

This design system captures the reference surface — **"JJ Desktop Client Floating"** — as tokens, fonts, brand assets, React components and a click-through UI kit. The product is being designed for a Flutter/Dart implementation (the source docs ship Dart recipes for the lane gradient, splash screen and loader), so values here are exact and platform-neutral.

## Sources

All material comes from one Claude Design project (the reader may not have access; kept for provenance):

- Project **Zanshin** — https://claude.ai/design/p/019e2585-34e0-736e-add9-dee89d97fbbd?file=JJ+Desktop+Client+Floating.html (project id `019e2585-34e0-736e-add9-dee89d97fbbd`)
- Reference file: `JJ Desktop Client Floating.html` and everything it loads — `fonts.css`, `app.css`, `graph.css`, `float.css`, `dnd.css`, `inspector.css`, `settings.css`, `search.css`, `graph-layout.jsx`, `graph-view.jsx`, `graph-dnd.jsx`, `graph-gaps.jsx`, `graph-search.jsx`, `inspector.jsx`, `settings.jsx`, `revset-config.jsx`, `app-shared.jsx`, `app-float.jsx`, `data.js`, `graph-data.js`, `graph-ops.js`, `diff-data.js`
- Project notes `CLAUDE.md`: the floating client is the reference; **Nami** (three gold waves on indigo) is the brand mark, the ensō is retired; gold = `@` + the one primary action, moon = selection, focus, controls.
- Specs (German): `assets/SPLASH-SPEC.md` (splash screen for Dart), `docs/branch-header-gradient.md` (lane gradient), `lottie/README.md` (Nami loader), `xcode-icons/README.md` (Icon Composer bundles)
- An earlier design-system draft inside the same project (tokens, components, specimen cards, `Design System.html`) — **ported and removed from the source project**. It was re-checked against the floating client while porting; drift was fixed (revset field, project menu, settings window, inspector v2, drag-and-drop, undo toast, gap markers, `@` locator arrow). This project is now the only source of the design system.
- Not used: the docked client (`JJ Desktop Client.html`), `archive/v1–v7`, studies (wordmark, splash v1, animated icon variants), screenshots.

## Sync

The app project keeps a numbered change log, `DESIGN-SYSTEM-SYNC.md` (project Zanshin, `019e2585-34e0-736e-add9-dee89d97fbbd`). Each sync works through the entries after the one named here and checks each against the floating client's code.

**Synced through #9** (2026-10-14).

- #1 Baseline — built from the floating client as archived in `archive/v8 Drop Menu & Composer/`, plus the calendar-day minimap labels and the arrow cursor.
- #2 The client self-hosts its fonts — `fonts.css` loads the same Inter and JetBrains Mono woff2 files as `assets/fonts/` (checked: same files, weights 400–700, unicode ranges). The Ubuntu note was dropped from Type.
- #3 The draft is gone from the app project — checked: no `tokens/`, `components/`, `guidelines/`, `ui_kits/`, `styles.css` or `Design System.html` there anymore. Sources updated.
- #4 Leftovers in app.css — checked: `--font-mono` is JetBrains Mono · SF Mono · Menlo; `--accent: #3b82f6` / `--hunk: #60a5fa` are labelled as the docked client's legacy blue, and `float.css` redefines both to moon for night and paper. Nothing to do — `tokens/` already use moon and a mono stack without Ubuntu Mono.
- #5 Search field replaces the revset dropdown — worked through together with #6, which reworked it two days later. What #5 introduced and #6 keeps is in the components: the 36px field (`--fl-hover`, radius 10, moon focus ring), `⌘F` / `/`, the scope pill (Go to vs Filter by, typed prefixes, Backspace → Any, moon while searching, icon-only ≤ 1100px), the suggestions (34px rows, moon highlight, match underline, dimmed folders, tabular counts, `not in view`, a footer that says what Enter does), the change and description glyphs, author initials, the top bar grid. The variant segment, `in jj log`, the hidden-variants note, Save, the save form and the flash were not ported (gone in #6). `CommandField` — the `$ jj log ▾` dropdown #5 replaced — is retired.
- #6 One search menu, default search, no Save — checked against `graph-search.jsx`, `search.css`, `revset-config.jsx`. New `components/search/`: `GraphSearch` (default search · typed search · a variant by name with `$`; ✕ back to the default; widths 320 / 250 / 170), `SearchMenu` (420px: the default search tagged `Default`, the other variants, Go to, Filter by, Edit Configurations…), `SearchPopover` with its rows (recents with counts, grouped matches), `RevsetDialog` (selectable built-ins, Default search switch row, `Default` tag, `jj log` as the locked fallback). Cards: Search field, Search menu, Search suggestions, jj log Configurations. The rule is now "`$` marks a variant that draws the graph". UI kit: the View capsule reads `[menu ▾ | query | ✕] · gap legend · count · View options`, with the client's matching, recents and the dialog.
- #7 Graph: Free layout, one line per parent, day axis — checked against `graph-layout.jsx`, `graph-view.jsx`, `graph-gaps.jsx`, `app-float.jsx`. `GraphEdge` gains bridges (`cuts`), the client's gap-mark placement (12px of line to cards; `gapAt` for shared stems) and `GraphPorts` (exits 12 → 7px → shared, entries 24 / 16 → 8px, tracks 3.5–6px, 12 × 10 bridges). New cards Graph lines — anatomy and — exit fan-out (400 / 240 / 160px), new `DayAxis`. View options: Layout **Free · Compact**, Free default, Time gone (Segmented examples updated). The UI kit runs a port of the client's layout engine.
- #8 Free and Compact share their columns, day labels on the dividers — `DayAxis` and its card put each label on the divider below that day's first commit, no gutter, the oldest day below its first commit; the UI kit computes its columns once for both layouts, and its minimap pill names the day the viewport centre is in. Graph rule: layouts share their columns — switching only changes heights.
- #9 jj log Configurations in the glass dialog — checked against `float.css` ("CONFIGURATIONS DIALOG"), `inspector.css` (shared glass field), `search.css` (`.rsd-opt`). `RevsetDialog` now uses the Settings / Projects material: blurred scrim, 18px sheet on `--fl-sheen` + `--fl-bg-solid`, `--fl-border` dividers, title 17/600, transparent sidebar with caps section labels and the selected entry in moon, glass fields, the Default search row as a settings row, the command preview as a diff-block well, 32px footer buttons with **OK as the gold-tinted primary**. The card and the UI kit pick it up through the component; the Material exception and the note from #8 are gone.

## Products / surfaces

| Surface | Where |
|---|---|
| **Desktop client** — graph workspace (Free · Compact, day axis), floating top bar with the search field, rail + panels, inspector (describe, hunks, commit/split composer), drag-to-rebase, undo toast, minimap, Projects dialog, Settings window, jj log Configurations | `ui_kits/desktop/` |
| Splash screen — always dark, 560 × 320, waves ornament, wordmark + 残心 lock-up | `assets/zanshin-splash.svg`, `assets/zanshin-splash-bg.svg` |
| App icon — Nami Indigo (+ Xcode 26 Icon Composer bundle) | `assets/app-icon/` |
| Loader — Nami waves, Lottie | `assets/motion/` |

---

## CONTENT FUNDAMENTALS

**Voice.** Quiet, exact, a little dry — a tool that trusts you. It never explains what you can already see ("nothing that explains itself"). UI copy is English; the design notes and the splash status lines are German (`Repository wird geladen…`).

**Casing.** Sentence case everywhere: *New change*, *Squash into parent*, *Move only this change*, *Detailed cards*. Section labels are written in sentence case and set in caps by CSS (`Graph view`, `Recent`, `While you scroll`). Product nouns keep their case: jj, @, revset, bookmark.

**Verbs first, jj underneath.** Labels are short verbs; the exact jj command is always one hover away — in `title`, a menu's right column, or a footer: *Move here* → `jj rebase -s ovknlmro -o vruxwmqv`; *Split* → `jj split -r plkmnvxo -i`; *Fetch — jj git fetch*. The search footer shows the full command a filter will run (`jj log -r 'author(exact:"Lena König")'` · *Filter ↵*) or says what a go-to does (*Selects the change — the graph stays as it is* · *Select ↵*). Zanshin never hides what it runs (Settings even shows the config key: `revset-aliases."immutable_heads()"`).

**Person.** Mostly impersonal; "you" only when it helps: *No changes yet — whatever you edit in your editor lands here.* · *Stays here to keep working.* No "we", no "please", no exclamation marks.

**Empty states** are one sentence, often with the command that fixes it: *No workstreams yet. Create one with `jj workstream new`.* · *No open reviews.* · *A merge — no changes of its own.* · *The root of all history.*

**Feedback** is past tense, verb first, ids in mono: *Moved ovknlmro onto vruxwmqv* · *Squashed … into …* · *Split … — the rest is now …* · *Committed … · “feat: …”* — always followed by **Undo**.

**Hints** chain with middots: *Click: details · Double-click: jj edit · Drag: onto another change · Right-click: actions*. Warnings are one word in the warn colour (*backwards*).

**Punctuation & glyphs.** Ellipsis `…` on items that open something (*Settings…*, *All Projects…*, *Describe…*); curly quotes around messages (“…”); real minus `−` in counts (`+42 −7`); `·` as separator; `‥` for stack ranges; `◆` immutable; `↑2 ↓3 ✓ ↕` sync state; `@` the working copy; `$` marks a jj log variant that draws the graph (search menu rows, the search pill at rest on a variant). Shortcuts are plain text in menus (`⌘,`), key caps only in prose.

**No emoji.** Never.

**Ids.** Change ids print with the unique prefix bold: **ov**knlmro. Short form 5 chars on cards, 8 in menus, toasts and commands.

---

## VISUAL FOUNDATIONS

**Mood.** Night indigo with warm gold — calm, deep, instrument-like. A light "paper" theme mirrors it in warm off-white and umber. Night is the brand default; the splash is always dark.

**Colour (see `tokens/colors.css`).**
- *Canvas* — two static shaders, no images: linear 165° `#1a2038 → #12162a → #0e1224` plus a flat radial indigo lift top-left (`rgba(96,120,178,.24)`). Paper: `#f7f4f0 → #f0ece7 → #e8e3dd` with a gold lift.
- *Gold* `#dca85b` is spent twice per screen at most: `@` (as saffron `oklch(78% .16 75)`) and **the one primary action** (gold-tinted glass button). Everything else is quiet.
- *Moon* `oklch(80% .07 272)` — the interactive accent derived from the canvas lift: selection rings, focus, switches, sliders, menu hover (filled, with `--accent-ink` text), checkboxes, hunk headers, "M" status, and in the search field: its focus ring, the pill while anything but the default search shows, the highlighted suggestion and the match underline. Never for primary actions; gold stays with `@`.
- *Text ladder* `#e7e9f2 / #b3b9d0 / #9299b4 / #8189a5` — every step ≥ 4.5:1 on the card surface.
- *Semantic* add `#4ade80`, remove `#f87171`, conflict/warn amber; darker on paper.

**Type (see `tokens/typography.css`).** Inter for UI; **JetBrains Mono for anything jj prints** (ids, revsets, commands, paths, diffs, counts); Shippori Mincho only for 残心. A dense desktop scale with the client's exact sizes: 9.5 · 10.5 · 11 · 11.5 · 12 · 12.5 · 13 · 15 · 17 · 18px. Base 13px; inspector title 18/600, −0.012em; caps labels 10.5/600 +0.1em. The wordmark is strokes, not a font. Client and design system self-host the same woff2 files, so both render the same faces.

**Space & layout.** One 12px rhythm for the chrome: islands sit 12px from the window edge and 12px apart; the top bar is 44px, so content starts at 68; traffic lights + rail form a 52px column, content starts at 76. Inspector 460px, pinned panel 300px, minimap 134px. Cards 240 × 62 (detailed) / 40 (compact), lanes 56px apart, rows 48px apart. The graph fills the window and pans freely; the top bar reads **Place · View · Action** on a grid of `minmax(max-content,1fr) minmax(0,max-content) minmax(max-content,1fr)` — on narrow windows the centre gives way (the search input absorbs the squeeze), the side groups keep their size. The View capsule reads `[menu ▾ | query | ✕] · gap legend · count · View options`.

**Backgrounds.** No photos, no patterns in the app. The floating client drops the docked client's 24px dot grid — the canvas is clean. The only ornament is the wave motif, large and at 5% on the splash.

**Material.** Glass islands: `--fl-bg` (66% indigo) + 46px top sheen + `blur(18px) saturate(1.4)`, 1px `--fl-border`, `--fl-shadow` (inset 1px highlight + soft drop). Stronger glass (86%, blur 22) for the inspector and minimap; solid `#1a1f35` for menus and popovers. Blur appears only on floating chrome and dialog scrims (`blur(12px)`). Every floating dialog — Projects, Settings, jj log Configurations — is the same 18px glass sheet.

**Cards.** Solid `--card-solid`, 10px radius, 1px `--border-strong`. Hover → `--card-solid-hi` + brighter border. Selected → moon border + 3px ring. `@` → saffron border, diagonal saffron wash, 1px + 4px glow. Stacks show two offset card edges beneath. Bookmarks ride the top edge as a pill; the ••• button sits on the bottom edge on hover.

**Corner radii** — 3 (kbd) · 4 (@ badge) · 6 (menu items) · 8 (rows, fields) · 9 (buttons) · 10 (cards) · 11 (rail buttons) · 12 (popovers, diff) · 13 (glass menus) · 14 (top-bar islands) · 16 (inspector, rail, panels) · 18 (dialogs) · pill.

**Borders & lines.** Hairlines at 7–14% white; graph edges 1.5px at 34% (`--edge`), 72% on hover, 10px elbows; the `@` path saffron 2.25px with a soft glow. **One line per parent → child pair:** its own exit on the parent's top edge and its own entry on the child's bottom edge (first parent: bottom centre; other parents beside it, farther = farther out). Forks turn just above the parent, merges just below the child; horizontal runs stack 3.5–6px apart and nest instead of crossing; a lane that is taken (in Free also: a card in the way) sends the line up the gutter between columns. Exit fan-out depends on the card width: 12px apart, squeezed down to 7px, then the outermost lines share one exit and split above the card. Crossings break the horizontal line (12 × 10, ≥ 12px of line to the next bend or card), else the vertical one. Hidden history = dashed edge broken by two slanted cuts that keep 12px of line to cards; end of history = dashed stub + cuts + "~ elided".

**Shadows.** Islands: inset top highlight + `0 14px 36px -12px` drop. Menus `0 24px 60px -16px`; dialogs `0 40px 100px -24px`. Paper uses umber shadows instead of black.

**Interaction states.** Hover = 7% white fill (`--fl-hover`) or a brighter border; pressed/on = 11% (`--fl-on`); no shrink on press. Focus = 2px moon outline, 2px offset. Disabled = 38% opacity. Menu hover fills moon with ink text; destructive items fill red. Danger buttons stay quiet until hover.

**Motion.** One curve, `cubic-bezier(.32,.72,0,1)` ("glide": fast out, long settle). Hovers 120ms, menus 110–160ms (fade + 4px rise / 0.97 scale), panels 200–260ms (slide 8–12px), graph re-layout 460ms FLIP with edges hidden and redrawn, new changes grow out of their parent, edits flash a moon ring. Spring only for the retired quick-action fan-out. While the graph scrolls, the floating controls step aside ("calm scrolling") and the minimap stays. `prefers-reduced-motion` turns it all off. The Nami loader: one gaussian swell runs through the waves (1.3s + 0.55s pause).

**Cursor.** On a Mac the arrow is the cursor: no pointing hands on controls (no `cursor:pointer` anywhere in the components — buttons, switches, segmented controls, cards, toggles all keep the arrow), no open hand on the canvas; the closed hand (`grabbing`) only while you hold the canvas. Links with an `href` are the one exception.

**Time in the graph.** Two layouts in View options: **Free** (default) — commits close in time stand close together across branches; gaps grow with the time between commits, log-damped and capped at 3 pitches; an edge is always at least one pitch — and **Compact** (rows = generation depth). Both share their columns: switching only moves cards up and down. Free has a **day axis** without a gutter: a dashed divider (`--border-strong`, 2 6) between two calendar days, and each day's label (mono 11 pill) on the divider below that day's first commit, at the left edge, sticky — reading upward, "this day starts here"; the oldest day's label sits below its first commit. Cards show relative age (`now`, `3h`, `2d`, `Sep 19` for older). Day labels — axis and minimap — are calendar days only: **Today**, **Yesterday**, then dates (`Sep 23` …), newest at the top, never relative values. In Free the minimap uses the axis's labels and its pill names the day the viewport centre is in; in Compact a label appears only when its day is older than the one above it.

**Where settings live.** How the graph looks lives with the graph: the **View options** popover in the top bar (Layout Free · Compact, Detailed cards, Group stacks, Card width). What the graph shows is the search field's job; jj log configurations are made and edited only in the **jj log Configurations** dialog (search menu › Edit Configurations…), which also sets the default search. Set-and-forget settings share one **Settings window** with a tab per scope — **General** (appearance, scrolling, diffs, identity; `~/.config/jj/config.toml`) and **Project** (remotes, trunk, immutable heads, project email; `.jj/repo/config.toml`) — reached with ⌘, or from the project capsule (Project Settings… / Settings…). The popover's last row leads there.

---

## ICONOGRAPHY

- **Own line set, 16px grid**: 1.3–1.6 stroke, round caps/joins, `currentColor`, no fills except a few glyphs (filled bookmark, dots). 48 SVGs in `assets/icons/ui/` (incl. the search's `change` — a node on a line — and `description` — three lines), plus glyphs the client draws inline (drop-menu and quick-action marks, the `@` locator arrow, checkbox marks, the configurations dialog's `minus` / `copy` / `chevron-up`) — all bundled in the `Icon` component as inline SVG strings. No icon font, no CDN set, no emoji.
- **Sizes follow the control**: 10–12 in rows and chips, 13–15 in buttons, 17 in top-bar icon buttons, 19 in the rail. Colour is the text ladder (`--text-dim` at rest, `--text` on hover); semantic colour only for meaning (conflict amber, viewed green).
- **Unicode as type, not icons**: `@ ◆ ↑ ↓ ✓ ↕ ‥ · −`, and the search menu's `$` row glyph (mono 600 13px, `--text-dim`, moon when selected).
- **Brand mark**: Nami — three gold waves (`#f4cf80 / #dca85b / #b58346`) on an indigo squircle (radius 58/256). Drawn heavier at chrome sizes (≤ 48px). Use `NamiMark` or `assets/app-icon/zanshin-icon-nami-indigo.svg`; never redraw it. The ensō studies (#01–#03) are retired and not shipped.
- **Wordmark**: ZANSHIN in monoline strokes, A without crossbar, wide tracking — gold gradient on night, `#26304d` ink on paper, white on black (`assets/zanshin-wordmark-*.svg`, `Wordmark`).

---

## Index

| Path | What |
|---|---|
| `styles.css` | Entry point — `@import`s only |
| `tokens/` | `fonts.css` (@font-face) · `colors.css` (night + `[data-theme="light"]` paper) · `typography.css` · `spacing.css` · `effects.css` (radii, shadows, glass, motion) |
| `components/` | React primitives by concern — see below; each has `.jsx`, `.d.ts`, `.prompt.md`; `*.card.html` specimens per folder |
| `guidelines/` | Foundation specimen cards (Colors, Type, Spacing, Brand, Motion) |
| `ui_kits/desktop/` | Click-through recreation of the floating client — see its `README.md` |
| `assets/` | `fonts/` (Inter, JetBrains Mono, Shippori Mincho subset) · `icons/ui/` (48 SVGs) · `app-icon/` (Nami SVG + Xcode 26 `.icon` bundle) · `motion/` (Lottie loaders) · wordmarks, waves, splash SVGs |
| `SKILL.md` | Agent-skill entry point |

### Components

- **brand/** — `Icon`, `NamiMark`, `Wordmark`
- **actions/** — `Button`, `IconButton`, `AtPill`
- **forms/** — `Segmented`, `Switch`, `Slider`, `Checkbox`, `TextField`, `Select`, `SearchField` (lists: Projects, bookmarks)
- **search/** — `GraphSearch` (+ `SearchScopes`, `SearchDollar`), `SearchMenu`, `SearchPopover` (+ `SearchGroup`, `SearchRow`, `SearchMatch`, `SearchTag`, `SearchAvatar`), `RevsetDialog`
- **surfaces/** — `Island`, `IslandSeparator`, `Popover`, `PopoverHeader`, `PopoverSeparator`, `OptionRow`, `OptionLink`, `Callout`, `CalloutText`, `Dialog`
- **menus/** — `Menu`, `DropMenu`, `ProjectMenu`
- **overlays/** — `Toast`, `PeekCard`, `DragGhost`
- **settings/** — `SettingsGroup`, `SettingsRow`
- **graph/** — `ChangeCard`, `StackCard`, `GraphEdge`, `GraphEnd`, `GraphPorts` (the router's port and line rules), `DayAxis` (+ `DayLabel`), `ChangeId`, `AtBadge`, `BookmarkChip`, `Flag`
- **content/** — `FileRow`, `DiffView`, `DiffHunk`, `ProjectRow`, `Kbd`
- **window/** — `TrafficLights`

### Intentional additions

None of the components above are inventions — each maps to a CSS family of the floating client (`.gcard`, `.gins-flag`, `.gck`, `.gset-row`, `.gdrop`, `.gpm`, `.gtoast`, `.gpeek`, `.gghost`, `.ghunk`, `.home-row`, `.gs-*`, `.rsd-*`, `.gtime` …). Packaging choices: `Icon` bundles the SVG set plus the client's inline glyphs; `GraphEnd` is split out of `GraphEdge`; `GraphPorts` exposes the router's constants and fan-out functions (graph-layout.jsx) so layouts can place exits, entries, tracks and bridges exactly; `OptionLink` names the view menu's "Settings…" row; the graph search is split into the field, its menu and its suggestion parts so each state can be composed.

### Not built (present only as retired variants in the source)

Quick-action fan-out and "+" add chips on cards (the client settled on the ••• button + right-click menu), the docked/column layouts.

### Retired

`CommandField` — the top bar's `$ jj log ▾` revset dropdown, replaced by the search field (sync #5, #6). The search's variant segment, Save and save form (#5) were dropped in #6 and never shipped here. The Time layout is gone (#7).
