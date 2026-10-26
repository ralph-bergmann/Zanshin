/* global React */
// WINDOWS — Settings and Projects are macOS windows of their own (design system › Windows, round G). No scrim, no 18px radius,
// no entrance, no ✕ in the content: the red button closes them. The system draws corners, shadow and appearing — here a mock does.
// One key window at a time (the project window, Settings or Projects); the others are inactive (windows.css › INACTIVE).
// Short modal tasks stay sheets on the project window: jj log Configurations, Push.
(() => {
const { useState, useEffect, useRef, useMemo } = React;
const Ic = (p) => <window.Icon {...p}/>;

// a mock of the system's buttons: grey rings at rest (Zanshin's deviation, also for greyed buttons), the system's own on hover
function TrafficLights({ buttons = { close: true, minimize: true, zoom: true }, onClose, onMinimize, onZoom, className = "" }) {
  return (
    <div className={"ztl " + className} role="group" aria-label="Window">
      <button type="button" className="c" aria-label="Close" disabled={!buttons.close} onClick={onClose}></button>
      <button type="button" className="m" aria-label="Minimize" disabled={!buttons.minimize} onClick={onMinimize}></button>
      <button type="button" className="z" aria-label="Zoom" disabled={!buttons.zoom} onClick={onZoom}></button>
    </div>
  );
}

// where a window opens: centred, or beside the other one (Settings from the Projects sidebar opens beside it)
const GAP = 16, EDGE = 12;
function placeWindow(kind, open) {
  const W = window.innerWidth, H = window.innerHeight;
  if (kind === "projects") {
    const w = Math.min(900, W - 2 * EDGE), h = Math.min(640, H - 2 * EDGE), s = open.settings;
    let x = Math.round((W - w) / 2), y = Math.max(EDGE, Math.round((H - h) * .4));
    if (s && s.x - GAP - w >= EDGE) { x = s.x - GAP - w; y = s.y; }
    else if (s && s.x + s.w + GAP + w <= W - EDGE) { x = s.x + s.w + GAP; y = s.y; }
    return { x: Math.max(EDGE, x), y, w, h };
  }
  const w = Math.min(620, W - 2 * EDGE), p = open.projects;
  let x = Math.round((W - w) / 2), y = Math.max(EDGE, Math.round(H * .08));
  if (p && p.x + p.w + GAP + w <= W - EDGE) { x = p.x + p.w + GAP; y = p.y; }
  else if (p && p.x - GAP - w >= EDGE) { x = p.x - GAP - w; y = p.y; }
  else if (p) { x = W - w - 2 * EDGE; y = Math.min(p.y + 40, H - 200); }
  return { x: Math.max(EDGE, x), y: Math.max(EDGE, y), w };
}
// keep a window reachable when the screen shrinks: its header stays on screen, a sized window never exceeds it
function clampWindow(g) {
  const W = window.innerWidth, H = window.innerHeight;
  const w = g.h ? Math.min(g.w, W - 2 * EDGE) : g.w, h = g.h ? Math.min(g.h, H - 2 * EDGE) : g.h;
  return { ...g, w, h, x: Math.min(Math.max(g.x, 80 - w), W - 80), y: Math.min(Math.max(g.y, 0), H - 52) };
}

// WindowFrame — the scaffold: a 52pt header that shares its row with the traffic lights (title at block end + 12, everything centred
// on the block's centre line), a hairline below. Empty header space drags the window; with resizable the edges resize it.
function WindowFrame({ title, titleHidden = false, active, buttons = { close: true }, onClose, onZoom, header, center = false, sidebar, sideW = 200,
  geo, setGeo, z = 1, resizable = false, minW = 0, minH = 0, maxH, onActivate, onKeyDown, className = "", children, ...rest }) {
  const ref = useRef(null);
  // becoming key brings the keyboard along (focus is kept inside if it already is)
  useEffect(() => { const el = ref.current; if (active && el && !el.contains(document.activeElement)) el.focus({ preventScroll: true }); }, [active]);
  const drag = (e, mode) => {
    if (e.button !== 0) return;
    if (mode === "move" && e.target.closest("button,input,textarea,select,a,[role=tab],.ztl")) return;
    e.preventDefault();
    const el = ref.current, g0 = { ...geo, h: geo.h || el.offsetHeight }, x0 = e.clientX, y0 = e.clientY;
    const move = (ev) => {
      const dx = ev.clientX - x0, dy = ev.clientY - y0, W = window.innerWidth, H = window.innerHeight;
      if (mode === "move") { setGeo({ ...geo, x: Math.min(Math.max(g0.x + dx, 80 - g0.w), W - 80), y: Math.min(Math.max(g0.y + dy, 0), H - 52) }); return; }
      let { x, w, h } = g0;
      if (mode.includes("e")) w = Math.max(minW, Math.min(g0.w + dx, W - g0.x));
      if (mode.includes("w")) { w = Math.max(minW, Math.min(g0.w - dx, g0.x + g0.w)); x = g0.x + g0.w - w; }
      if (mode.includes("s")) h = Math.max(minH, Math.min(g0.h + dy, H - g0.y));
      setGeo({ ...geo, x, w, h, zoomed: null });
    };
    const up = () => { window.removeEventListener("pointermove", move); window.removeEventListener("pointerup", up); };
    window.addEventListener("pointermove", move); window.addEventListener("pointerup", up);
  };
  const lights = <TrafficLights buttons={buttons} onClose={onClose} onZoom={onZoom}/>;
  const hd = (
    <header className={"zw-hd" + (center ? " is-center" : "")} onPointerDown={(e) => drag(e, "move")}
      onDoubleClick={(e) => { if (buttons.zoom && onZoom && !e.target.closest("button,input")) onZoom(); }}>
      {!sidebar && lights}
      {!titleHidden && <h1 className="zw-title">{title}</h1>}
      {header}
    </header>
  );
  return (
    <div ref={ref} className={"zw " + className + (sidebar ? " has-side" : "") + (active ? "" : " is-inactive")} role="dialog" aria-label={title} tabIndex={-1}
      data-window={active ? undefined : "inactive"} style={{ left: geo.x, top: geo.y, width: geo.w, height: geo.h, maxHeight: maxH, zIndex: z }}
      onPointerDownCapture={onActivate} onKeyDown={(e) => { if (onKeyDown) onKeyDown(e); e.stopPropagation(); }} {...rest}>
      {sidebar ? <>
        {lights}
        <aside className="zw-side" style={{ width: sideW }}><div className="zw-side-drag" onPointerDown={(e) => drag(e, "move")}></div>{sidebar}</aside>
        <div className="zw-col">{hd}<div className="zw-main">{children}</div></div>
      </> : <>{hd}<div className="zw-main">{children}</div></>}
      {resizable && ["e", "w", "s", "se", "sw"].map(m => <div key={m} className={"zw-rz " + m} onPointerDown={(e) => drag(e, m)}></div>)}
    </div>
  );
}

// ------------------------------------------------------------
// SETTINGS — one window for "Settings…" (⌘,), "Project Settings…" and "Appearance, diffs and more". 620 wide, the height follows the
// tab up to 740, not resizable; only close is active. The window title is the tab's name; the tabs sit centred in the header.
// No Esc, no ✕: changes apply at once.
// ------------------------------------------------------------
// page: a page inside the Project tab ("immutable" = Immutable commits, immutable.jsx) — Back returns to the tab
function SettingsWin({ tab, setTab, page, setPage, project, t, setTweak, active, geo, setGeo, z, onActivate, onClose }) {
  const shown = tab === "project" && !project ? "general" : tab;
  const sub = shown === "project" && page === "immutable" && window.ImmutablePage;
  const tabs = (
    <div className="gtb-seg gset-tabs" role="tablist" aria-label="Settings">
      <button role="tab" aria-selected={shown === "general"} className={shown === "general" ? "on" : ""} onClick={() => setTab("general")}><Ic name="settings" size={13}/>General</button>
      {project
        ? <button role="tab" aria-selected={shown === "project"} className={shown === "project" ? "on" : ""} onClick={() => setTab("project")}><span className="gset-mark"><window.ZanshinMark size={14}/></span>{project.name}</button>
        : <span className="zsw-off" title="Open a project first"><button role="tab" aria-selected="false" aria-disabled="true" disabled><Ic name="folder" size={13}/>Project</button></span>}
    </div>
  );
  return (
    <WindowFrame title={shown === "general" ? "General" : sub ? "Immutable commits" : "Project"} titleHidden center active={active} buttons={{ close: true }} onClose={onClose}
      header={tabs} geo={geo} setGeo={setGeo} z={z} maxH={Math.min(740, window.innerHeight - geo.y - EDGE)} onActivate={onActivate} className="zsw">
      <div className="gset-scope">
        {shown === "general"
          ? <>For Zanshin on this Mac · jj settings go to <code>~/.config/jj/config.toml</code></>
          : <>For {project.name} only{project.path ? <> · <code>{project.path}/.jj/repo/config.toml</code></> : null}</>}
      </div>
      <div className="gset-bd">{shown === "general" ? <window.GeneralPane t={t} setTweak={setTweak}/> : sub ? <window.ImmutablePage project={project} onBack={() => setPage(null)}/> : <window.ProjectPane key={project.id} project={project} onPage={setPage}/>}</div>
      <footer className="gset-ft">How the graph looks lives with the graph: <b>View options</b> in the toolbar.</footer>
    </WindowFrame>
  );
}

// ------------------------------------------------------------
// PROJECTS — "All Projects…" (⇧⌘O). 900 × 640, resizable down to 680 × 440, close and zoom active. The sidebar begins under the
// traffic lights, the brand block below the header row. Esc clears the search and never closes; ↩ or a double-click opens the
// selected project, which closes Projects. Settings in the sidebar opens the Settings window beside it.
// ------------------------------------------------------------
function ProjectsWin({ tree, setTree, activeProjectId, onOpenProject, onSettings, active, geo, setGeo, z, onActivate, onClose, onZoom }) {
  const [query, setQuery] = useState("");
  const [selectedId, setSelectedId] = useState(activeProjectId);
  const [dragOver, setDragOver] = useState(false);
  const q = query.trim().toLowerCase();
  const visible = useMemo(() => q
    ? window.flattenAll(tree).filter(({ node }) => node.name.toLowerCase().includes(q) || (node.kind === "project" && (node.path || "").toLowerCase().includes(q)))
    : window.flattenTree(tree), [tree, q]);
  const toggleGroup = (id) => setTree(tr => window.updateTreeNode(tr, id, n => ({ ...n, expanded: !n.expanded })));
  const open = (node) => { if (node && node.kind === "project" && node.status !== "missing") onOpenProject(node); };
  const onKeyDown = (e) => {
    if (e.key === "Escape") { if (query) { e.preventDefault(); setQuery(""); } return; }
    if (e.key === "Enter" && selectedId && !e.target.closest("button")) { const s = window.flattenAll(tree).find(x => x.node.id === selectedId); if (s) open(s.node); }
  };
  // a folder dropped on the window becomes a project (demo: the host would resolve the path)
  const onDragOver = (e) => { if ([...(e.dataTransfer.types || [])].includes("Files")) { e.preventDefault(); setDragOver(true); } };
  const onDragLeave = (e) => { if (!e.currentTarget.contains(e.relatedTarget)) setDragOver(false); };
  const onDrop = (e) => {
    e.preventDefault(); setDragOver(false);
    const name = "imported-" + Math.floor(Math.random() * 1000);
    setTree(tr => [...tr, { id: "p_" + name, kind: "project", name, path: "~/code/" + name, status: "clean", branch: "main", ahead: 0, behind: 0, lastOpened: "just added" }]);
  };
  const narrow = geo.w < 800;
  const STATUS = window.STATUS_META;
  return (
    <WindowFrame title="Projects" active={active} buttons={{ close: true, zoom: true }} onClose={onClose} onZoom={onZoom} geo={geo} setGeo={setGeo} z={z}
      resizable minW={680} minH={440} onActivate={onActivate} onKeyDown={onKeyDown} className={"zpw" + (dragOver ? " drag-over" : "")} sideW={200}
      onDragOver={onDragOver} onDragLeave={onDragLeave} onDrop={onDrop}
      sidebar={<>
        <div className="home-side-brand">
          <window.ZanshinMark size={32}/>
          <div><div className="home-side-brand-name">Zanshin</div><div className="home-side-brand-sub">jj client · v0.24.0</div></div>
        </div>
        <nav className="home-side-nav" aria-label="Sections">
          <button className="home-side-item active" aria-current="page"><Ic name="folderOpen" size={14}/>Projects</button>
          <button className="home-side-item"><Ic name="cloud" size={14}/>Remotes</button>
          <button className="home-side-item" onClick={onSettings} title="Opens the Settings window — ⌘,"><Ic name="settings" size={14}/>Settings…</button>
        </nav>
        <div className="home-side-foot">
          <div className="home-side-foot-label">Signed in</div>
          <div className="home-side-foot-user"><span className="home-side-avatar">A</span><div><div>Alice Sralph</div><div className="home-side-foot-mail">alice@dasralph.de</div></div></div>
        </div>
      </>}
      header={<>
        <span className="zw-grow"></span>
        <div className="home-search zpw-search">
          <Ic name="search" size={13}/>
          <input placeholder="Search projects, paths…" value={query} onChange={(e) => setQuery(e.target.value)} autoFocus aria-label="Search projects"/>
          {query && <button className="home-search-clear" onClick={() => setQuery("")} aria-label="Clear search"><Ic name="close" size={10}/></button>}
        </div>
        <button className="home-action primary"><Ic name="plus" size={12}/>Add directory</button>
        <button className="home-action" title="Clone…" aria-label="Clone…"><Ic name="cloud" size={13}/>{!narrow && <span>Clone…</span>}</button>
        <button className="home-action ghost" title="New group" aria-label="New group"><Ic name="folderPlus" size={13}/></button>
      </>}>
      <div className="home-list" role="tree" aria-label="Projects">
        {visible.length === 0 && <div className="home-empty">No projects match “{query}”</div>}
        {visible.map(({ node, depth }) => {
          if (node.kind === "group") {
            const count = (node.children || []).filter(c => c.kind === "project").length, sub = (node.children || []).filter(c => c.kind === "group").length;
            return (
              <div key={node.id} className={"home-row group " + (node.expanded ? "expanded " : "") + (selectedId === node.id ? "selected " : "")} style={{ "--depth": depth }}
                onClick={() => { setSelectedId(node.id); toggleGroup(node.id); }} role="treeitem" aria-expanded={!!node.expanded}>
                <span className="home-row-indent" aria-hidden="true"></span>
                <span className={"home-row-chev " + (node.expanded ? "open" : "")}><Ic name="chevronRight" size={12}/></span>
                <Ic name={node.expanded ? "folderOpen" : "folder"} size={14} className="home-row-icon"/>
                <span className="home-row-name">{node.name}</span>
                <span className="home-row-count">{count}{sub > 0 && ` · ${sub} group${sub === 1 ? "" : "s"}`}</span>
              </div>
            );
          }
          const s = STATUS[node.status] || STATUS.clean, isOpen = activeProjectId === node.id;
          return (
            <div key={node.id} className={"home-row project " + (selectedId === node.id ? "selected " : "") + (isOpen ? "active-project " : "") + (node.status === "missing" ? "missing " : "")}
              style={{ "--depth": depth }} onClick={() => setSelectedId(node.id)} onDoubleClick={() => open(node)} role="treeitem" aria-selected={selectedId === node.id} title={node.path}>
              <span className="home-row-indent" aria-hidden="true"></span>
              <span className="home-row-chev"></span>
              <span className="home-row-status" style={{ background: s.color }} title={s.label}></span>
              <div className="home-row-text">
                <div className="home-row-line1">
                  <span className="home-row-name">{node.name}</span>
                  {isOpen && <span className="home-row-pill open">open</span>}
                  {node.branch && node.branch !== "—" && <span className="home-row-branch"><Ic name="branch" size={10}/>{node.branch}</span>}
                  {node.ahead > 0 && <span className="home-row-meta ahead">↑{node.ahead}</span>}
                  {node.behind > 0 && <span className="home-row-meta behind">↓{node.behind}</span>}
                </div>
                <div className="home-row-line2"><span className="home-row-path">{node.path}</span><span className="home-row-sep">·</span><span className="home-row-when">{node.lastOpened}</span></div>
              </div>
              <button className="home-row-more" onClick={(e) => e.stopPropagation()} title="More…" aria-label="More…"><Ic name="more" size={13}/></button>
            </div>
          );
        })}
      </div>
      <div className={"home-drop-hint " + (dragOver ? "active" : "")}><Ic name="download" size={13}/><span>Drop to add directory</span></div>
    </WindowFrame>
  );
}

Object.assign(window, { TrafficLights, WindowFrame, SettingsWin, ProjectsWin, placeWindow, clampWindow });
})();
