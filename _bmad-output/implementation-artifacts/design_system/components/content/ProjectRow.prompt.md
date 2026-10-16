A repository (or group) in the Projects window's tree.

~~~jsx
<ProjectRow kind="group" name="Mobile" expanded count={3} depth={1} onToggle={toggle} onSelect={select}/>
<ProjectRow depth={2} name="MyApp" path="~/code/work/mobile/myapp" branch="feature/new-ui" status="dirty" ahead={6} lastOpened="now" open selected onSelect={select} onDoubleClick={openIt}/>
~~~

- Status dot leads (dirty yellow, ahead green, behind blue, diverged orange, conflict red, missing grey — the `--proj-*` tokens).
- `open` = the repository in the project window: a saffron **OPEN** caps marker, never a filled pill.
- Selection = `--accent-soft` (pressed: `--accent-soft-hi`). Hover `--fl-hover`, pressed `--fl-on`. Click selects, double-click / ↩ opens. `missing` strikes the name and path through. The ••• button shows on hover and whenever the row or the button has focus.
- Keyboard · VoiceOver · Reduce motion: the tree is **one Tab stop** — the selected row (`tabIndex`); ↑ ↓ move and select · Home End · → expands a group or steps into it · ← collapses or steps to the parent · ↩ opens a project (a group: toggles) · Tab from a row reaches its ••• · treeitem with level, expanded / collapsed, selected; the dot reads as its status · the chevron turns on `--dur-expand` (→ 0 under Reduce motion).
