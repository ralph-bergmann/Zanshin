Links — two kinds, nothing else.

~~~jsx
<p>Immutable heads come from <Link onClick={openSettings}>Project settings</Link>.</p>
<Link quiet external href="https://jj-vcs.github.io/jj/latest/revsets/">Revset docs</Link>
~~~

- inline: `--accent-text`, no underline at rest, 1px underline 2px below on hover, `--text` while pressed. quiet: `--text-dim` → `--text`, never underlined (Configurations "jj docs ↗", search group "Clear").
- Focus = the 2px ring with radius 3. Cursor: arrow, except real `href` links (the one pointing hand in Zanshin).
- **Key caps** (`Kbd`) only in prose — hints, empty states, callouts — and as the one hint inside an empty search field (`/`). Menus, tooltips and buttons write shortcuts as plain text (`⌘,`).
- Keyboard · VoiceOver · Reduce motion: a Tab stop; ↩ follows it (Space too when it is a button) · link (with `href`) or button, external ones announce "opens in browser" via their ↗ · colour only.
