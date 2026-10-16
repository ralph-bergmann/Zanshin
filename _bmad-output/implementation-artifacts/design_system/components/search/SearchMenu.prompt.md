The one menu behind the search field's pill — what the graph shows, and where a typed search looks.

~~~jsx
<SearchMenu current="c-onb" active={row}
  variants={[
    { id: "default", name: "jj log", builtin: true, desc: "Your mutable changes plus trunk context", cmd: "jj log" },        // first = the default search
    { id: "all", name: "all()", builtin: true, desc: "Every visible commit, incl. immutable history", cmd: "jj log -r 'all()'" },
    { id: "c-onb", name: "Onboarding feature", expr: 'files("lib/features/onboarding/")' },
  ]}
  onPickVariant={(id) => setRevset(id)} onPickScope={(s) => { setScope(s); focusField(); }} onEdit={openConfigurations}/>
~~~

- **Order:** the default search (tag `Default`) · the other jj log variants, built-ins and configurations (`$` glyph, name, expression) · separator · *Go to* (Change, Bookmark — "selects a change · graph stays") · *Filter by* (Author, File, Description — "redraws the graph"), each with its prefix · separator · **Edit Configurations…** (muted label).
- **A field-attached list** (rule 4): focus stays in the search field. What the graph shows carries a **check** (never the fill); the scope row of an active search shows its value instead of the description. "Any" has no row: it is the field without a scope (Backspace in an empty field, ✕).
- Picking a variant empties the field and redraws the graph; picking a scope keeps what you were typing (the value of the active search makes room for a new one) and focuses the field.
- Keyboard · VoiceOver · Reduce motion: the keys come from the field — ↑ ↓ Home End move the keyboard row (`SearchMenu.navigate`; `--accent-soft`, its glyph in accent, named by the field's `aria-activedescendant`), ↩ runs it, Esc closes and restores the field; hover is `--fl-hover` and never moves the keyboard row, a click runs the clicked row · listbox of options, the current one `aria-current` · fades in (its 4px drop × `--motion`).
