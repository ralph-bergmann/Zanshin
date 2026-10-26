Command menu: right-click / ••• on a change, the text context menu, pull-downs, the project menu and the list of a `Select`. Each action row names the action; the right column shows the jj command or the shortcut.

~~~jsx
<Menu id="kmnvxoqp" subject="feat(onboarding): swipe gestures" autoFocus onSelect={run} onClose={close} items={[
  { id: "new", label: "New change on top", icon: "plus", cmd: "jj new" },
  { id: "edit", label: "Edit", icon: "working-copy-at", cmd: "jj edit" },
  { id: "copy", label: "Copy", icon: "copy", submenu: [{ id: "cid", label: "Change id" }, { id: "msg", label: "Description" }] },
  "sep",
  { header: "Show" },
  { id: "diff", label: "Diff stats", checked: true },
  "sep",
  { id: "revert", label: "Revert", icon: "revert", cmd: "jj revert -B @" },
  { id: "abandon", label: "Abandon", icon: "abandon", cmd: "jj abandon", danger: true },
]} />
~~~

- Highlight = solid `--accent` with `--accent-ink` (command menus: focus moves into the menu). Field-attached lists (search menu, suggestions) use the soft tint instead — focus stays in the field there.
- Danger rows are red at rest and highlight with `--danger-hover` (a red tint) — never the accent, never a solid red.
- 28px rows, 16px leading column (icon or check), right column: `cmd` (mono) and/or `shortcut` (plain text), › for submenus. Section headers in caps, aligned with the labels.
- Activation blinks the row (off `--dur-blink`, on `--dur-blink`), then `onSelect`; the parent closes it with `closing` (`--dur-exit`, `--ease-exit`, fade). Mutating items: on an immutable change the **card menu leaves them out** instead of greying them (see *Card menu*); a row that is off for a reason worth knowing is `disabled` (.4) with the reason in `title` — the row's wrapper shows it, since a disabled button takes no hover.
- **Note rows** (`{ note, icon }`): not a command — why something is missing, 11.5px `--text-dim`, wrapping, the icon (e.g. `HatchSwatch`) in the leading column. The keyboard and typeahead skip them; the menu is `aria-describedby` them.
- **Submenus:** hover opens after `--delay-submenu` (150ms; →, ↩ and a click at once). While the pointer moves toward the open submenu — inside the triangle from where it was to the submenu's near corners — other rows don't take the highlight. Leaving row and triangle closes it after `--delay-submenu-out` (300ms). It opens to the right, **flips left** when the window has no room (8px margin) and shifts up to stay 8px inside the bottom.
- Keyboard · VoiceOver · Reduce motion: focus moves into the menu · ↑ ↓ move (wrap) · Home End · typing jumps to the next row starting with the letters (letters within `--dur-typeahead`, 600ms, extend the match; rows match on `text` when the label is a node) · ↩ / Space activate · → opens a submenu, ← and Esc close it (Esc on the top level closes the menu, focus returns to its opener) · menu / menuitem / menuitemcheckbox / menuitemradio, submenu rows `aria-haspopup` + expanded · the menu fades in (its scale × `--motion`), the blink stays.
