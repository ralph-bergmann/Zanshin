Tooltip for controls — "verbs first, jj underneath". Use instead of the HTML `title`.

~~~jsx
<Tooltip label="New change" shortcut="⌘N" cmd="jj new">
  <Button variant="primary" size="lg" icon="plus">New change</Button>
</Tooltip>
<Tooltip placement="right" label="Bookmarks"><IconButton size="lg" icon="bookmark" label="Bookmarks" /></Tooltip>
~~~

- Material: solid `--tooltip-bg`, 1px `--tooltip-border`, radius 7, `--shadow-tooltip`; 5 × 8px padding, max 300px. Label 11.5/500 `--text`, shortcut plain text in `--text-dim` (faint steps up on the tooltip: 4.8:1), command mono 11 `--text-dim`.
- Placement: 8px from the control — below for the top bar, right for the rail, above near the window's bottom edge. **Flip and clamp:** if the preferred side would leave the window it flips to the opposite side, then it shifts along its axis to stay 8px inside the window edges; it never covers its control.
- Timing: `--delay-tooltip` (700ms) of rest; at once while warm (`--dur-tooltip-warm`, 600ms since the last one closed). In: fade + 2px on `--ease-glide` (`--dur-hover`); out: fade (`--dur-exit`). Pressing the control hides it.
- A control disabled with a reason keeps its tooltip: wrap it — the anchor takes the hover while the control takes none.
- `mono`: the label is jj's own text, verbatim — an error toast's full refusal with its `Caused by:` caret diagram and hints. Mono 11 `--text`, lines and spaces kept (`white-space:pre-wrap`), so the caret sits under the column it points at; still max 300px, longer lines wrap.
- Keyboard · VoiceOver · Reduce motion: keyboard focus shows it after the same delay; Esc hides it · it describes the control (`aria-describedby`) while shown — VoiceOver users get the reason as the control's help · fades only (the 2px drift × `--motion`).
