The project capsule's menu — the capsule names the place, so it holds everything about the place. It is a `Menu`: one highlight, the keys, typeahead, the blink and the `closing` exit come with it.

~~~jsx
<ProjectMenu activeId="p_myapp" autoFocus onClose={close} recent={[
  { id: "p_myapp", name: "MyApp", branch: "feature/new-ui", status: "dirty" },
  { id: "p_api", name: "api-server", branch: "develop", status: "ahead" },
]} onAll={openProjects} onProjectSettings={() => openSettings("project")} onSettings={() => openSettings()}/>
~~~

- The one menu material, 300px, 28px rows like every command menu, the check column for the open project; the status dot follows the name, the branch sits in the mono command column. Highlight = solid accent + ink.
- Order is fixed: Recent (open project first, ✓) · All Projects… ⇧⌘O · Project Settings… (disabled without a project) · Settings… ⌘,. **A row that shows a shortcut does exactly what the shortcut does:** Settings… ⌘, opens or brings forward Settings with the tab shown last, as ⌘, does; only Project Settings… picks a tab (Project) — and it shows no ⌘,. Items that open a window end in an ellipsis; shortcuts are plain text.
- Keyboard · VoiceOver · Reduce motion: opens from the capsule with ↩ / Space / ↓, focus moves in; ↑ ↓ Home End, typing jumps to a project by name (`--dur-typeahead`), ↩ opens, Esc closes and returns focus to the capsule · menu; recent projects are menuitemradio, the open one checked · fades in (scale × `--motion`), the blink stays.
