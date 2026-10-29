A repository (or group) in the Projects window's tree.

~~~jsx
<ProjectRow kind="group" name="Mobile" expanded count={3} depth={1} onToggle={toggle} onSelect={select}/>
<ProjectRow depth={2} name="MyApp" path="~/code/work/mobile/myapp" branch="feature/new-ui" status="dirty" ahead={6} lastOpened="now" open selected onSelect={select} onDoubleClick={openIt}/>
~~~

- Status dot leads (dirty yellow, ahead green, behind blue, diverged orange, conflict red, missing grey — the `--proj-*` tokens).
- `open` = the repository in the project window: a saffron **OPEN** caps marker, never a filled pill.
- Selection = `--accent-soft` (pressed: `--accent-soft-hi`). Hover `--fl-hover`, pressed `--fl-on`. Click selects, double-click / ↩ opens. `missing` strikes the name and path through. The ••• button shows on hover and whenever the row or the button has focus.
- **Moving** (Projects window): every row drags (4px threshold; not while searching — the results are flat). The row in hand gets `dragging` (40%, in place). The row under the pointer gets `drop`: a project's top / bottom half = `before` / `after`; a group's top quarter `before`, middle `into` (as its last child; it expands), bottom quarter `after` — an expanded group with children takes its whole lower part as `into`; below the last row = `end` on that row (the end of the top level). A group never into itself or below itself; Esc cancels; the moved row ends selected; the click that ends a drag neither toggles nor deselects. Lines and border in `--accent-live-line`. The pointer carries a `DragGhost` (`kind="project"` / `"group"`, `target` in words: "Into Backend", "To the top level").
  ~~~jsx
  <ProjectRow kind="group" name="Backend" count={2} drop="into"/>
  <ProjectRow depth={1} name="dotfiles" path="~/dotfiles" status="clean" dragging/>
  ~~~
- A click on the empty tree below the rows clears the selection (Finder).
- **Naming a group** — `editing` turns a group row into its name field (TextField sm, focused, the text selected; chevron slot and folder stay). **New group** (header button) puts a field with no name where the group will be: the last row of the selected group, of the selected project's group, or of the top level. **Rename…** puts the field in the group's own row. ↩ commits, Esc cancels; a click elsewhere cancels a new group and keeps a rename; an empty name cancels (a rename keeps the old one).
  ~~~jsx
  <ProjectRow kind="group" depth={1} editing name="" onCommit={create} onCancel={stop}/>
  ~~~
- **The row menu** — ••• (`onMore`, below the button) or a right-click (at the pointer) selects the row and opens a `Menu`. A project: Open · Reveal in Finder · Move to group › · — · Remove from list (Open and Reveal disabled for a missing project, Remove for the open one; Remove takes it off the list, the folder stays). A group: Rename… · Move to group › · — · Delete group (its projects and groups move up into its place; nothing leaves the list). **Move to group ›**: Top level, then every group by its path ("Work / Mobile"), sorted, the current one checked (radio) — never the row itself or what is inside it — · — · **New group…**: a name field where the row is now; ↩ creates the group there and moves the row into it (Finder's New Folder with Selection).
- Keyboard · VoiceOver · Reduce motion: the tree is **one Tab stop** — the selected row (`tabIndex`); ↑ ↓ move and select · Home End · → expands a group or steps into it · ← collapses or steps to the parent · ↩ opens a project (a group: toggles) · Tab from a row reaches its ••• · treeitem with level, expanded / collapsed, selected; the dot reads as its status · the chevron turns on `--dur-expand` (→ 0 under Reduce motion).
