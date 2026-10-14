The one menu behind the search field's pill — what the graph shows, and where a typed search looks.

~~~jsx
<SearchMenu current="c-onb" autoFocus
  variants={[
    { id: "default", name: "jj log", builtin: true, desc: "Your mutable changes plus trunk context", cmd: "jj log" },        // first = the default search
    { id: "all", name: "all()", builtin: true, desc: "Every visible commit, incl. immutable history", cmd: "jj log -r 'all()'" },
    { id: "c-onb", name: "Onboarding feature", expr: 'files("lib/features/onboarding/")' },
  ]}
  onPickVariant={(id) => setRevset(id)} onPickScope={(s) => { setScope(s); focusField(); }} onEdit={openConfigurations}/>
~~~

- **Order:** the default search (tag `Default`) · the other jj log variants, built-ins and configurations (`$` glyph, name, expression) · separator · *Go to* (Change, Bookmark — "selects a change · graph stays") · *Filter by* (Author, File, Description — "redraws the graph"), each with its prefix · separator · **Edit Configurations…** (muted label).
- The row of what the graph shows is selected (`--accent-soft`, glyph in `--accent`); the scope row of an active search shows its value instead of the description. "Any" has no row: it is the field without a scope (Backspace in an empty field, ✕).
- Picking a variant empties the field and redraws the graph; picking a scope keeps what you were typing (the value of the active search makes room for a new one) and focuses the field.
- Arrow keys move between rows; Esc closes and restores the field.
