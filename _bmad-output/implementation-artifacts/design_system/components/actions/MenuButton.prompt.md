A Button that opens a Menu: the label, then a chevron. Use it where one button offers a few related jj verbs — the inspector's Squash.

~~~jsx
<MenuButton title="Squash or absorb into earlier changes" items={[
  { id: "squash", label: "Squash into parent", cmd: "jj squash -r kmnvxoqp", title: "jj squash -r kmnvxoqp" },
  { id: "absorb", label: "Absorb into ancestors", cmd: "jj absorb --from kmnvxoqp", disabled: true,
    title: "Nothing to absorb: no hunk belongs to an earlier change." },
]} onSelect={run}>Squash</MenuButton>
~~~

- The Button's look and states (variant, size, disabled with a reason); a `chevron-down` at 12px, opacity .75, 5px after the label and 8px before the right edge.
- The menu opens 4px below the button's left edge, flipped above without room, 8px inside the window. Each row carries its jj command as the mono hint (`cmd`); its tooltip is the reason it is off, else the command.
- The button's own tooltip says what the menu holds ("Squash or absorb into earlier changes"); while the graph is busy the whole button is disabled with that reason.
- Icon-only (`iconOnly`, the diff header's options, Story 10.33): `view-options` at 14px and the chevron 2px apart, no text, 26px high, padding 0 5 0 6, usually ghost; `label` is its name and tooltip and says the current values ("Diff options — Ignore all whitespace, 3 context lines"); `active` turns the glyph `--accent` while a value is off its default.

  ~~~jsx
  <MenuButton iconOnly icon="view-options" variant="ghost" active label="Diff options — Ignore all whitespace, 3 context lines" items={DIFF_OPTIONS} />
  ~~~
- Keyboard · VoiceOver · Reduce motion: a Tab stop; Space / ↩ / click open the menu with its first row highlighted; then the Menu's keys; Esc or a pick returns focus to the button · a button with its label, `aria-haspopup="menu"`, expanded while open · the menu's entrance and exit as Menu.
