Text button for commands; use `primary` for exactly one action per view (gold), the quiet default for the rest.

~~~jsx
<Button variant="primary" size="lg" icon="plus" title="jj new — start a new change on top of @">New change</Button>
<Button icon="describe">Describe…</Button>
<Button variant="danger" icon="abandon">Abandon</Button>
<Button variant="destructive" size="md">Clear history</Button>   {/* only inside a ConfirmDialog */}
<Button size="md" busy>Fetching…</Button>
<Button icon="copy" label="Copy command" />                  {/* icon-only, square */}
~~~

- Labels are verbs in sentence case; put the jj command in `title` (tooltip), not in the label.
- States: hover = one fill step (`--fl-hover` → `--fl-on`), pressed = one more (`--fl-press`, instant, no shrink), focus = the 2px ring, disabled = .4. Primary and destructive step fill and ring together (`--primary-*`, `--destructive-*`).
- `danger` stays quiet until hover, then a red tint with red text. `destructive` is the filled red button and only appears as the one primary of a confirmation (gold steps aside there).
- Busy keeps the label and width; the spinner replaces the icon.
- Keyboard · VoiceOver · Reduce motion: a Tab stop; Space / ↩ press it (the pressed fill shows while held) · button, its label (icon-only: `label`); busy reads "busy"; disabled with a reason reads "dimmed" + the reason · colour only — nothing moves.
