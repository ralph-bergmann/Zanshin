Zanshin's line-icon set (45 glyphs, 16px grid, currentColor) — use it for every glyph in the UI; never emoji or icon fonts.

~~~jsx
<Icon name="branch" size={18} />
<Icon name="conflict" size={12} style={{ color: "var(--conflict)" }} />
~~~

- Colour comes from `color`; default ink is the surrounding text colour.
- Sizes in use: 11–12 (inline flags), 13–15 (buttons, menus), 17 (island buttons), 18 (rail).
- `Icon.names` lists all glyphs; the same set exists as SVG files in `icons/ui/` (exported in #000 for design tools).
