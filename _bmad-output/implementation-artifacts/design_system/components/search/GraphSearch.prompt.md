The top bar's graph search — the View capsule reads `[menu ▾ | query | ✕] · gap legend · count · View options`. Find a change, or change what the graph shows.

~~~jsx
<Island shape="bar">
  <GraphSearch size={GraphSearch.sizeFor(innerWidth)} view={view} scope={scope} value={text} variantName="Onboarding feature"
    onChange={setText} onScopeChange={setScope} onMenu={() => setPop(pop === "menu" ? null : "menu")} onClear={backToDefault}
    onFocus={() => setPop("sugg")} expanded={pop === "sugg"} controls="zs-gs-menu" activeDescendant={"zs-gs-menu-" + menuRow}>
    {pop === "menu" && <SearchMenu variants={variants} current={view === "search" ? null : revset} onPickVariant={show} onPickScope={setScope} onEdit={openDialog} active={menuRow}/>}
    {pop === "sugg" && <SearchPopover footer={{ text: <code>jj log -r 'author(exact:"Lena König")'</code>, verb: "Filter" }}>…</SearchPopover>}
  </GraphSearch>
  <span className="count"><b>35</b> changes</span><IslandSeparator/><IconButton icon="view-options" label="View options"/>
</Island>
~~~

- **The field holds one thing.** *Default search* (`view="default"`): empty field, calm pill (search icon, no tint), `⌘F` hint, no ✕ — you type straight away; nothing else marks it (the tooltip and the menu's first row do). *Typed search* (`"search"`): scope icon + label, the value, ✕. *Another variant* (`"variant"`): the pill shows `$`, the field shows the variant's name as a value (`--text`, 500; mono for built-ins); clicking in empties it for typing. The pill has no tint at any view (Story 10.30: a tint read as an error or focus) — it looks as at the default search.
- **✕ always returns to the default search.** Esc or leaving the field restores what was there (app logic).
- **Go to vs Filter by.** Change and Bookmark select a change and leave the graph as it is (footer "Selects the change — the graph stays as it is" · Select ↵; a change outside the view switches to `all()`). Author, File and Description redraw the graph: a typed search replaces the view and runs in `all()` — the footer shows the full `jj log -r '…'` command · Filter ↵.
- **Keys:** `⌘F` or `/` focuses the field; typed prefixes `c: b: a: f: d:` switch the scope; Backspace in an empty field returns to Any. Both lists are field-attached: focus never leaves the input — ↑ ↓ Home End move the keyboard row of the open list (named with `aria-activedescendant`), ↩ runs it, Esc closes the list (a second Esc leaves the field). The pill opens the menu and puts focus in the field.
- Keyboard · VoiceOver · Reduce motion: as above · combobox with `aria-expanded`, `aria-controls` and the active descendant; the pill is a button "Search menu" · the lists fade in (drops × `--motion`); the focus halo fades.
- **Rule:** `$` marks a variant that draws the graph — menu rows and the pill at rest on a variant. There is no Save: configurations are made and edited only in `RevsetDialog`.
- **Focus** = moon border + 3px `--accent-ring` (as the projects search). Rest = `--fl-hover` fill, radius 10, no border.
- **Width steps** (`GraphSearch.sizeFor`): input 320 · 250 at ≤1180 · pill icon-only at ≤1100 · 170, no `⌘F`, short placeholders at ≤980. The segment never shrinks below its label; only the input gives way.
