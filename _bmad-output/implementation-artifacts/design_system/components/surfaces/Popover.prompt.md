Popover sheet for view/settings options that hang off an island button; compose with PopoverHeader, OptionRow and PopoverSeparator.

~~~jsx
<Popover>
  <PopoverHeader>Graph</PopoverHeader>
  <OptionRow label="Layout"><Segmented options={[{ value: "free", label: "Free" }, { value: "compact", label: "Compact" }]} value="free" /></OptionRow>
  <OptionRow label="Detailed cards"><Switch checked /></OptionRow>
  <PopoverSeparator />
  <PopoverHeader>Appearance</PopoverHeader>
</Popover>
~~~

- Opens 14px below its island, right-aligned; enters with `--dur-pop` (160ms) on `--ease-glide` (translateY −4px, scale .98); leaves with `.is-closing` (`--dur-exit`, `--ease-exit`) — keep it mounted with `Presence`.
- The last row is an `OptionLink` "Appearance, diffs and more · Settings…" → Settings › **General**. It picks a tab, so it shows **no ⌘,** — a row that shows a shortcut does exactly what the shortcut does, and ⌘, opens the tab shown last. It takes focus inside its row (−2px) like every list row.
- Keyboard · VoiceOver · Reduce motion: opens from its island button with ↩ / Space (`aria-expanded`); focus moves to its first control; Tab moves through it, and leaving it — Tab past the end, a click outside, Esc — closes it and returns focus to the button (non-modal: no trap, no scrim) · a non-modal dialog labelled by its header · fades in (its 4px drop × `--motion`).
