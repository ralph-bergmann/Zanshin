A repository (or group) in the Projects dialog tree.

~~~jsx
<ProjectRow kind="group" name="Mobile" expanded count={3} depth={1}/>
<ProjectRow depth={2} name="MyApp" path="~/code/work/mobile/myapp" branch="feature/new-ui" status="dirty" ahead={6} lastOpened="now" open selected/>
<ProjectRow depth={2} name="design-kit" path="~/code/work/mobile/design-kit" branch="main" status="behind" behind={3} lastOpened="5d ago"/>
~~~

- Status dot leads (STATUS_META colours: dirty yellow, ahead green, behind blue, diverged orange, conflict red, missing grey).
- `open` = the repository in this window: a saffron **OPEN** caps marker, never a filled pill.
- Selection = `--accent-soft` fill. Click selects, double-click / ↩ opens.
- `missing` strikes the name and path through.
