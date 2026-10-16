Pop-up button for settings with a handful of fixed choices (remotes, trunk bookmark; the Configurations dialog's function and match pickers). Custom-drawn — no native `<select>` anywhere.

~~~jsx
<SettingsRow label="Fetch from" configKey="git.fetch">
  <Select label="Fetch from" value={fetch} onChange={setFetch} options={["origin", "upstream"]}/>
</SettingsRow>
<Select label="Trunk" mono value={trunk} onChange={setTrunk} onCustom={askRevset}
  options={[{ header: "Bookmarks" }, "main", "develop", { value: "release/1.5.x@origin", disabled: true }, "sep", { value: "__custom", label: "Custom…" }]}/>
~~~

- Trigger: 30px, 12.5px, min-width 170, the `--field-bg` well, `--fl-border` edge (hover/open `--border-strong`, pressed adds `--fl-hover`), double chevron `--text-dim`; focus = the 2px ring (it is a button, not text entry).
- **Placement (macOS pop-up button):** the list is a `Menu` that opens OVER the trigger — the **chosen row lies centred on the trigger** and its **text starts at the trigger's text x** (list left = trigger left − 29: border 1 + inset 5 + row padding 8 + check column 16 + gap 10, less the trigger's 11). **Width = trigger + 40, at most 360.** Clamped **8px** inside the window (shifted down or up as a whole).
- **Long lists:** at most the window height − 16; taller lists scroll inside the menu with the chosen row brought into view at the trigger.
- It **grows out of the chosen row** (transform-origin there), `--dur-menu` on glide; choosing blinks the row, then the list fades (`--dur-exit`).
- Pointer: a click opens it and it stays open; **press – drag – release** picks the row under the pointer in one gesture (a release after the pointer moved, or after a held press, activates that row).
- The chosen row carries the check; keyboard highlight starts there; disabled rows .4 and skipped; "Custom…" sits last after a separator. 2–3 short options → prefer `Segmented`; long or open-ended lists → `Select`.
- Keyboard · VoiceOver · Reduce motion: Space / ↩ / ↑ / ↓ open it; then the Menu's keys — ↑ ↓ Home End, **typeahead on `text`** (so `mono` options rendered as `<code>` still match; pass `text` for any node label), ↩ picks, Esc closes and focus returns to the trigger · a button with `aria-haspopup`, its label "Fetch from: origin"; the list is a menu of menuitemradio · the list only fades (its scale × `--motion`).
