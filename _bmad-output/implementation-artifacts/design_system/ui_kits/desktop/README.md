# Desktop client — UI kit

Click-through recreation of **`JJ Desktop Client Floating.html`** from the Zanshin project: the change graph fills the window and every control floats above it. Built only from this design system's components (`window.ZanshinDesignSystem_a33847`) plus `kit.css`, which places them and styles the few product-only pieces.

## Files

| File | What |
|---|---|
| `index.html` | Entry. `?projects` opens the Projects dialog on load (as the client does), `?settings=general|project|immutable` opens Settings (`immutable`: the Project tab's Immutable commits page), `?theme=paper|system` (`light` still works), `?accent=blue|purple|pink|red|orange|yellow|green|graphite` simulates the macOS accent choice (Settings › General › Accent colour: Follow macOS · Zanshin) |
| `data.js` | The client's sample repo (MyApp, default `jj log` view; trunk `main` with the tag `v1.0.0`), the Projects tree (`HOME_TREE`), built-in revsets, the client's three jj log configurations (rule-based), op log. Hunks for files without hand-written diffs are generated deterministically |
| `immutable.js` | The client's mock of `immutable_heads()`: evaluates Settings › Project › Immutable commits over the repo — heads, each change's reason ("trunk() · main", "below trunk() · main", "tag v1.0.0", "below a change by Bob" …), the heads by name, custom terms it can't preview. The cards re-hatch at once |
| `layout.js` | The client's layout engine (graph-layout.jsx), ported: **Free** rows (default — gaps follow commit time, log-damped, capped at 3 pitches, an edge ≥ 1 pitch) and **Compact** rows (generation depth); columns shared by both layouts; one line per parent → child pair with own exits/entries (`GraphPorts`), nested tracks, gutter detours and bridges; the Free day axis |
| `graph.jsx` | Stack folding (linear runs, never across a gap), the plane (cards, the router's lines, gap marks, end stubs, `DayAxis`, peek, stack popover), minimap (Free: the day axis's labels; Compact: one label per row) |
| `search.jsx` | The View capsule's search field — `GraphSearch` + the one `SearchMenu` + `SearchPopover` suggestions with the client's matching, recent searches, go-to vs filter, typed prefixes; the kit's revset evaluation (configurations, typed searches in `all()`) |
| `chrome.jsx` | Top bar — Place (traffic lights, project capsule → `ProjectMenu`) · View (search field, gap legend, count, View options: Layout Free · Compact) · Action (fetch/push, **New change**); rail with hover callouts and pinned panels |
| `inspector.jsx` | Inspector: header flags, title-as-describe-field, meta, bookmarks (draggable), actions, Changes (checkboxes, viewed), diff with selectable/draggable hunks, commit/split composer |
| `dialogs.jsx` | Projects dialog (tree, search, open marker) and the Settings window (General · Project; History › Immutable commits opens `ImmutablePage` inside the Project tab) |
| `app.jsx` | Repo state + jj operations (Revert: `jj revert -r … -B @`, the inverse diff slotted in under @), revsets (default search, configurations, `RevsetDialog`), go-to, drag-and-drop with the drop menu, undo toast, calm scrolling, keyboard |

## Control states

The kit picks up the control library through the components: pressed states and the one focus ring everywhere, the gold primary in one recipe (top bar, inspector, dialogs), the custom pop-up `Select` in Settings › Project, the Fetch badge, the accent setting. Try `?accent=green&settings=general`.

## Try

- Click a card → inspector; double-click → `jj edit`; right-click or ••• → context menu. ⌘J scrolls to the selected change, ⇧⌘J to @.
- **Revert** (card menu, last group with Abandon): on a change below @ — e.g. the immutable *Release v1.0.0* — a new change with the inverse diff is born under @, toast *Reverted … — … undoes it* with Undo. Off, with the reason as tooltip, on @ itself, on changes not below @ and on empty ones.
- **Immutable changes are hatched** (no ◆, no colour). Hover one: the peek's eyebrow says IMMUTABLE and why; its menu keeps New change on top, Insert after, Revert, then the reason and **Immutable commits…**, which opens Settings › Project on that page. Switch *Other people's changes* on or add a bookmark there and watch the graph re-hatch; ‹ MyApp goes back (⌘[ too).
- Drag the inspector's left edge or a pinned panel's right edge to resize it (double-click: the default width; remembered in the browser). ⌘W on the graph shows Projects (the kit keeps the graph behind it).
- `⌘F` or `/` → the search field: recent searches; type `set`, `lena`, `f:lib/` or a change id. Enter on a file/author/description filters the graph (`jj log -r '…'` in the footer, runs in `all()`); Enter on a change selects it and leaves the graph alone. ✕ returns to the default search.
- The pill opens the one menu: the default search, `all()`, the configurations, Go to · Filter by, **Edit Configurations…** / ⌥⌘L (the `jj log Configurations` **window** — floats over the graph, drag it by its header, click the graph and it goes inactive; make any entry the default search; Esc / ⌘W ask first when something is unsaved).
- View options → Layout **Free · Compact**: switching only moves cards up and down; in Free the day labels sit on the dashed dividers at the left edge.
- Drag a card onto another, rest a moment → drop menu (Move here · Move only this change · Insert after/before · Squash · New merge · Duplicate). Release → toast with **Undo** (also ⌘Z).
- Drag a bookmark chip, a file row or a hunk header from the inspector onto a change.
- Select hunks on a non-@ change → **Split** composer; on @ → **Commit**.
- Click the capsule → Recent / All Projects… / Project Settings… / Settings… (⌘,).
- Scroll the canvas: the controls step aside (the search capsule stays while you use it), the minimap stays.

## Deliberate simplifications

One repository's data regardless of the picked project; the built-ins `jj log` and `all()` both show the whole sample repo; Remotes, Fetch and Push are inert. Layout: the data's lanes are kept as columns while they hold in both layouts (otherwise greedy packing) — the client's column-order optimiser is not ported; dashed lines through the same hidden parent are not grouped onto one entry (the kit doesn't track which hidden commit a gap runs through), and gap marks place themselves per line.
