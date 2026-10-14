Modal dialog (projects, settings) on a blurred scrim; use sparingly — most UI floats in islands, not modals.

~~~jsx
<Dialog title="Projects" onClose={close} nav={[{ id: "all", label: "All projects", icon: "folder", count: 6 }]} activeNav="all"
  tools={<><SearchField placeholder="Search projects" style={{ flex: 1 }} /><Button size="md" variant="primary" icon="folder-plus">Add repository…</Button></>}>
  <ProjectRow name="MyApp" path="~/dev/myapp" open selected />
</Dialog>
~~~

- The primary action in the toolbar is gold; the scrim is `--scrim` + 12px blur.
