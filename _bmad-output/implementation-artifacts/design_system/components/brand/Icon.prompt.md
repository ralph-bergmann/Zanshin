Zanshin's own line icons: **58 glyphs**, one file each in `assets/icons/ui/` (the source; `assets/icons/glyphs.json` lists the names and the retired aliases). `Icon` is generated from those files.

~~~jsx
<Icon name="squash" size="md" />          {/* menu row, button */}
<Icon name="conflict" size="sm" />        {/* card flag */}
<Icon name="fetch" size="bar" />          {/* top-bar icon button */}
~~~

- **Colour:** `currentColor`, nothing else — the glyph takes the colour of the control it sits in (the text ladder: `--text-dim` at rest, `--text` on hover; semantic colour only for meaning: conflict amber, viewed green). One colour per glyph: the app tints the whole glyph, a second colour would be lost.
- **Sizes are the six `--icon-*` tokens** — pass the name: `xs` 10 (the ✕ inside chips and fields) · `sm` 12 (rows, chips, flags, card meta, close buttons) · `md` 14 (buttons, menu and list rows) · `lg` 16 (panel headers, the primary action — the drawing grid 1:1) · `bar` 17 (top-bar icon buttons) · `rail` 19 (rail). Nothing in between; `Icon.sizes` maps the names to px.
- **No icon font.** The Flutter app renders the SVG sources themselves — precompiled at build time (`vector_graphics_compiler`) and tinted in one colour at runtime. Whatever a file says is what ships.
- **Grammar** (readme › Iconography): 16 × 16, live area 1–15 including strokes and caps, one 1.5 stroke, round caps and joins, solids only where meaning needs one (filled bookmark, the half-filled Auto, dots r 1.25), 1 unit of air between separate parts. The `!` is one drawing in `alert` and `conflict`: a 2.25 bar, 1 unit of air, a dot r .85.
- **File rules** (the build compiler silently drops what it doesn't know — a `<style>` block would turn every stroke into a black area): the root exactly `<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16">` holding exactly one `<g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">`; inside only `path`, `circle`, `rect`, `line`, `polyline`, `polygon`, `ellipse`; areas `fill="currentColor"` with `stroke="none"` where there is no outline; presentation attributes only — no `<style>`, `class` or `style=""`; no `id`, `transform`, `opacity`, `mask`, `clipPath`, `filter`, gradients, `<use>`, `<symbol>`, `<defs>`, `<image>`, `<text>`, `<title>`, `<desc>`, comments; `currentColor` is the only colour, never hex; coordinates with at most 2 decimals; no metadata.
- **Names are file names.** Adding, renaming or removing a glyph means the file, `glyphs.json` (names; aliases old → current) and `Icon` together — the app checks its icon list against `glyphs.json`.
- Keyboard · VoiceOver · Reduce motion: not focusable · decorative by default (`aria-hidden`); give `title` only when the icon is the only label (an icon-only button labels the button instead) · static.
