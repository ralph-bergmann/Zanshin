The project capsule's menu — the capsule names the place, so it holds everything about the place.

~~~jsx
<ProjectMenu activeId="p_myapp" recent={[
  { id: "p_myapp", name: "MyApp", branch: "feature/new-ui", status: "dirty" },
  { id: "p_api", name: "api-server", branch: "develop", status: "ahead" },
]} onAll={openProjects} onProjectSettings={() => openSettings("project")} onSettings={() => openSettings("general")}/>
~~~

- Glass-solid sheet, 300px, 13px radius; items 30px with a 14px check column. Hover = moon fill + `--accent-ink`.
- Order is fixed: Recent (open project first, ✓) · All Projects… · Project Settings… · Settings… `⌘,`.
- Menu items that open a window end in an ellipsis; shortcuts are plain text, not key caps.
