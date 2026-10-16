Search field for lists (Projects, bookmarks) — not the graph search (that is `GraphSearch`).

~~~jsx
<SearchField placeholder="Search projects, paths…" value={q} onChange={setQ} shortcut="/" />
~~~

- 30px (`--control-md`). **A named exception to text entry:** at rest a quiet fill (`--fl-hover`; hover `--fl-on`) instead of the inset well and its edge — it sits in toolbars and list headers, as NSSearchField does. Focus is text entry's: `--accent-line` edge + 3px `--accent-ring` halo.
- With a query a 20px clear button (✕, `--text-faint` → `--text`, pressed `--fl-press`) replaces the key cap.
- The `shortcut` key cap is the one key cap outside prose: it shows only while the field is empty and unfocused.
- Keyboard · VoiceOver · Reduce motion: `shortcut` focuses it · Esc clears; Esc on an empty field leaves it (in the Projects window it never closes the window) · ↓ moves into the list it filters · search field labelled by its placeholder; the ✕ is "Clear" · the halo fades, nothing moves.
