A macOS window of its own — **Settings**, **Projects** and **jj log Configurations** (`RevsetDialog`). (Short modal tasks — ConfirmDialog and Push, the only two sheets — stay sheets on the project window: `Dialog` and friends.)

~~~jsx
<Window title="General" titleHidden buttons={{ close: true }} headerAlign="center"
  header={<Segmented variant="tabs" options={[{ value: "general", label: "General" }, { value: "project", label: "MyApp" }]} … />}>
  …settings groups…
</Window>
<Window title="Projects" buttons={{ close: true, zoom: true }} sidebar={<…brand, sections, signed in…/>}
  header={<><span className="zs-win-grow" /><SearchField … /><Button variant="primary">Add directory</Button></>}>
  …tree…
</Window>
~~~

- **The system's, not ours:** corners, shadow, appearing and closing, the title in the Window menu and Mission Control, full-screen ordering (both float above the project window, also in full screen). Technically closable, not minimisable. No scrim, no 18px radius, no `--shadow-dialog`, no entrance animation, **no ✕ in the content** — the red button and ⌘W close it.
- **Fill:** borderless and opaque, `--fl-sheen` over `--fl-bg-solid`. No vibrancy, not even in the Projects sidebar: the canvas is Zanshin's own indigo, a wallpaper bleeding through would break the calm and every contrast here is measured on solid surfaces. Reduce transparency changes nothing; increased contrast takes the solid values it already has.
- **Header:** 52pt, one row with the traffic lights. The title (13/600) starts at **block end + 12** (x 91 with the macOS 27 reference block 19–79) and everything in the row centres on the block's centre line (y 26). Controls follow at 12px gaps; actions go to the right edge, 12 in. Empty header space drags the window (Flutter: `performWindowDrag` on the header's background). A hairline under it.
- **Traffic lights:** grey rings at rest for every button — also the greyed ones (Settings: only close is active · Projects: close and zoom); hover shows the system's buttons.
- **Inactive** (not the key window — the normal case while Settings or Projects is key): the accent role goes neutral (`tokens/inactive.css`), nothing shows focus, the title dims to `--text-dim`. Gold, data colours and progress stay.
- Keyboard · VoiceOver · Reduce motion: ⌘W closes (also via File › Close Window) · Tab moves through the content, the header's controls first · VoiceOver: a window with the title · nothing animates (the system's own window animation follows its settings).

**Settings window** — one window for "Settings…" (⌘,), "Project Settings…" and "Appearance, diffs and more". Width 620, height follows the tab up to 740, not resizable. Tabs `[General | Project]` as the tabs Segmented, centred in the header; the window title is the tab's name. ⌘, opens or brings forward the window with the tab shown last and never switches it — and so does **every row that shows ⌘,** (Zanshin › Settings…, the project menu's Settings…, Settings… in the Projects sidebar): on the Mac a row that shows a shortcut does exactly what the shortcut does. Only two rows pick a tab, and they show no ⌘,: "Project Settings…" (Project) and "Appearance, diffs and more" (General). No project open and Project shown last → ⌘, shows General. The Project tab always shows the project in the (one) project window. Without an open project the Project tab is disabled (reason: "Open a project first"); with one it shows the project's mark and name. No Esc, no ✕: changes apply at once.

**Projects window** — "All Projects…" (⇧⌘O). Default 900 × 640, resizable, minimum **680 × 440** (sidebar 200 + a tree row with its path and status, the header's search at 200 with the primary). The sidebar begins under the traffic lights; the brand block sits below the header row. Esc clears the search, never closes. With no project open it is the app's only window and closing it quits; opening a project closes Projects and opens the project window. Settings in the sidebar opens the Settings window beside it.

**The floating client** (sync #10) follows this: Settings and Projects are windows of their own there too (`windows.jsx › WindowFrame`: the 52pt header at the reference geometry, one key window at a time, the others `data-window="inactive"`, grey rings). Two differences remain on its side: jj log Configurations is still the 18px glass sheet (D7 not adopted), and its project window keeps the pre-A2 traffic-light geometry (TrafficLights).
