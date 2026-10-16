The suggestions under the graph search: recent searches while the field is empty, grouped matches while typing.

~~~jsx
<SearchPopover footer={{ text: <code>jj log -r 'files("lib/features/settings/")'</code>, verb: "Filter" }}>
  <SearchGroup label="Changes"/>
  <SearchRow icon="change" before={<ChangeId id="qmsvtlkr" length={8}/>} label={<SearchMatch text="feat(settings): section-based layout" match="set"/>}
    meta={<><SearchTag>not in view</SearchTag><span>Lena · 2d</span></>}/>
  <SearchGroup label="Files"/>
  <SearchRow icon="folder" mono active id="zs-gs-pop-3" label={<SearchMatch text="lib/features/settings/" match="set" split={13}/>} meta="7 changes"/>
  <SearchRow more label="4 more in Files"/>
</SearchPopover>
~~~

- **Empty field:** "Recent" (or "Recent authors" with a scope picked) with a **Clear** action — go-tos and filters, filter rows with their change count. A recent search whose expression became a configuration is hidden (it lives in the menu).
- **Typing in Any:** groups ordered by their best match — Changes (3), Bookmarks (2), Authors (2), Files (3), Descriptions (1), each with "N more in …". With a scope, only that scope; nothing there → a note and the matches found elsewhere.
- **Rows** are 34px; the **keyboard row** (`active`) is `--accent-soft` with its icon in accent — focus stays in the field, whose `aria-activedescendant` names the row; hover is `--fl-hover`, pressed `--fl-on`, and hover never moves the keyboard row (↩ and the footer stay with it; a click runs the clicked row). The match is underlined in `--accent` (`SearchMatch`); paths dim their folder part; counts use tabular numerals; changes outside the view carry a `not in view` tag; authors show an initial (`SearchAvatar`), you get `you · mine()`.
- **Footer** = what Enter does: the full `jj log -r '…'` command with **Filter ↵**, or "Selects the change — the graph stays as it is" with **Select ↵** ("Not in this view — switches to `all()` and selects it" · **Show ↵**).
- Material: the one menu material (`--fl-sheen` + `--fl-bg-solid`, radius 13), the `--dur-pop` entrance, 12px under the field.
- Keyboard · VoiceOver · Reduce motion: ↑ ↓ from the field move the keyboard row, ↩ runs it, Esc closes · listbox; the footer is the row's description · fades in (its drop × `--motion`).
