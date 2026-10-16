Inset text field for settings, the describe title, the composer and the Push sheet's bookmark name; `mono` for revsets and config values.

~~~jsx
<TextField size="lg" placeholder="Summary" defaultValue="feat(onboarding): swipe gestures" />
<TextField mono value={revset} onChange={…} error="Unknown function “autor”. Did you mean author()?" />
<TextField value="~/.config/jj/config.toml" readOnly />
~~~

- States: hover → `--border-strong` edge · focus (any, not only keyboard) → `--accent-line` edge + 3px `--accent-ring` halo · error → `--error` edge (+ `--error-ring` halo when focused) and a message line (11px, red, alert icon) · read-only → transparent, dashed edge, `--text-muted`, still selectable · disabled .4 · inactive window: at rest, no halo, no caret.
- Placeholder `--text-faint`. **Text selection is the macOS highlight** (`NSColor.selectedTextBackgroundColor`, resolved in Zanshin's theme's appearance; unemphasized grey when the field or window isn't focused) with the selected glyphs drawn in `--text`. `--accent-select` is only the fallback where no system value exists.
- Text context menu: a `Menu` with Undo · Redo — Cut · Copy · Paste — Select all, shortcuts in the right column.
- Keyboard · VoiceOver · Reduce motion: a Tab stop; the system's text keys (⌥← word, ⌘← line, ⇧ to select …) · text field labelled by its row; the error is its description · the halo fades (`--dur-hover`), nothing moves.
