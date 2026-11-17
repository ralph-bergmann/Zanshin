A button with two parts: the label runs its command, the divided chevron opens the alternatives. Use it where one verb is the usual pick and others sit next to it — the composer's Split ▾ Commit, the inspector's Squash ▾ (Squash into parent · Absorb into ancestors).

~~~jsx
<SplitButton variant="primary" label="Split" title="jj split -r qkynoyuu -m 'x' root:a root:b" onRun={split} onSelect={run} items={[
  { id: "split", label: "Split", cmd: "jj split -r qkynoyuu", note: "feature moves to the new working copy", noteIcon: "bookmark" },
  { id: "commit", label: "Commit", cmd: "jj commit", note: "feature stays on this change, with the selected part", noteIcon: "bookmark" },
]} />
~~~

- **The rule.** Buttons that look the same work the same. A split button runs its label; only its chevron opens the alternatives. A menu button (one part, no divider) only opens a menu — after Story 10.48 only the icon-only diff options. The label always names the command that runs.
- One shape with the variant's rest fill and ring — `default` (`--fl-hover`) or `primary` (the gold of the one primary action); no other variant. A 1px divider inset 7px top and bottom (`--fl-border`; the primary's gold at 45%).
- Each part is its own button: Tab stop, hover, pressed, focus ring inside, disabled (.4) with its own reason. The label disabled (jj refuses, e.g. a merge's squash) leaves the chevron working; while the graph is busy both parts are off with that reason. The parts paint their half's step: default `--fl-on` / `--fl-press`, primary gold 16% / 28%.
- The chevron (`chevron-down` 12px, .8; gold on the primary) opens a Menu 4px below the button's left edge. Rows carry their jj command (`cmd`); a row's `note` says what the label cannot (where the bookmarks land), and only when the alternatives differ in it. A preview may follow the highlighted row (`onHighlight`) and returns to the label's verb when the highlight leaves or the menu closes.
- Sizes: md 30 (padding 0 12, the chevron 0 7, `--radius-btn`, `--type-control`) · sm 26 (0 10 / 0 6, radius 8, 12px).
- Keyboard · VoiceOver · Reduce motion: two Tab stops, the label then the chevron · Space / ↩ run the label, open the menu on the chevron; then the Menu's keys; Esc or a pick returns focus to the chevron · the label is a button named by it, the chevron a button "More ‹label› actions" with `aria-haspopup="menu"`, expanded while open · the menu's entrance and exit as Menu.
