/* global React */
// WINDOWS — Settings and Projects are macOS windows of their own (design system › Windows, round G). No scrim, no 18px radius,
// no entrance, no ✕ in the content: the red button closes them. The system draws corners, shadow and appearing — here a mock does.
// One key window at a time (the project window, Settings or Projects); the others are inactive (windows.css › INACTIVE).
// Short modal tasks stay sheets on the project window: jj log Configurations, Push.
(() => {
const { useState, useEffect, useLayoutEffect, useRef, useMemo } = React;
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
// the screen in the windows' own units — Zoom (sync #21) scales the page, so the screen holds fewer of them
const vw = () => window.innerWidth / (window.__zsZoom || 1), vh = () => window.innerHeight / (window.__zsZoom || 1);
function placeWindow(kind, open) {
  const W = vw(), H = vh();
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
  const W = vw(), H = vh();
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
      const dx = ev.clientX - x0, dy = ev.clientY - y0, W = vw(), H = vh();
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
// tab up to 740 — until you resize it (sync #20: resizable, minimum 620 × 420, zoom active; long URLs and long config lines get the
// room). The window title is the tab's or the page's name; the tabs sit centred in the header. No Esc, no ✕: changes apply at once —
// except in the config file, which saves on Save and asks before unsaved edits go.
// ------------------------------------------------------------
// page: a page inside a tab — "immutable" (Project, immutable.jsx) or "config" (either tab, config-file.jsx). Back returns to the tab.
function SettingsWin({ tab, setTab, page, setPage, project, t, setTweak, active, geo, setGeo, z, onActivate, onClose, onZoom }) {
  const shown = tab === "project" && !project ? "general" : tab;
  const sub = page === "config" && window.ConfigFilePage ? "config" : shown === "project" && page === "immutable" && window.ImmutablePage ? "immutable" : null;
  const path = shown === "general" ? "~/.config/jj/config.toml" : project && project.path ? project.path + "/.jj/repo/config.toml" : ".jj/repo/config.toml";
  // unsaved edits in the config file: leaving asks first (ConfirmDialog as a sheet on this window)
  const guard = useRef(null);
  const [ask, setAsk] = useState(null);
  const leave = (fn) => () => { if (guard.current) setAsk({ name: guard.current, fn }); else fn(); };
  const toTab = (v) => leave(() => { setTab(v); setPage(null); });
  const edit = sub !== "config" && window.ConfigFilePage && <> · <button className="gset-link" onClick={() => setPage("config")} title={shown === "general" ? "jj config edit --user" : "jj config edit --repo"}>Edit…</button></>;
  const tabs = (
    <div className="gtb-seg gset-tabs" role="tablist" aria-label="Settings">
      <button role="tab" aria-selected={shown === "general"} className={shown === "general" ? "on" : ""} onClick={toTab("general")}><Ic name="settings" size={13}/>General</button>
      {project
        ? <button role="tab" aria-selected={shown === "project"} className={shown === "project" ? "on" : ""} onClick={toTab("project")}><span className="gset-mark"><window.ZanshinMark size={14}/></span>{project.name}</button>
        : <span className="zsw-off" title="Open a project first"><button role="tab" aria-selected="false" aria-disabled="true" disabled><Ic name="folder" size={13}/>Project</button></span>}
    </div>
  );
  const title = sub === "config" ? "Config file" : sub === "immutable" ? "Immutable commits" : shown === "general" ? "General" : "Project";
  return (
    <WindowFrame title={title} titleHidden center active={active} buttons={{ close: true, zoom: true }} onClose={leave(onClose)} onZoom={onZoom}
      header={tabs} geo={geo} setGeo={setGeo} z={z} resizable minW={620} minH={420} maxH={geo.h ? undefined : Math.min(740, vh() - geo.y - EDGE)} onActivate={onActivate} className="zsw">
      <div className="gset-scope">
        {shown === "general"
          ? <>For Zanshin on this Mac · jj settings go to <code>{path}</code>{edit}</>
          : <>For {project.name} only · <code>{path}</code>{edit}</>}
      </div>
      <div className={"gset-bd" + (sub === "config" ? " is-fill" : "")}>{sub === "config"
        ? <window.ConfigFilePage key={shown} scope={shown === "general" ? "user" : "repo"} project={project} path={path} back={shown === "general" ? "General" : project.name} onBack={leave(() => setPage(null))} guard={guard}/>
        : shown === "general" ? <window.GeneralPane t={t} setTweak={setTweak}/>
        : sub === "immutable" ? <window.ImmutablePage project={project} onBack={() => setPage(null)}/>
        : <window.ProjectPane key={project.id} project={project} onPage={setPage}/>}</div>
      <footer className="gset-ft">How the graph looks lives with the graph: <b>View options</b> in the toolbar.</footer>
      {ask && window.ConfirmSheet && (
        <window.ConfirmSheet title={"Discard your edits to " + ask.name + "?"} confirmLabel="Discard edits" onCancel={() => setAsk(null)} onConfirm={() => { const fn = ask.fn; guard.current = null; setAsk(null); fn(); }}>
          The file stays as you last saved it.
        </window.ConfirmSheet>
      )}
    </WindowFrame>
  );
}

// ------------------------------------------------------------
// PROJECTS — "All Projects…" (⇧⌘O). 900 × 640, resizable down to 680 × 440, close and zoom active. The sidebar begins under the
// traffic lights, the brand block below the header row. Esc clears the search and never closes; ↩ or a double-click opens the
// selected project, which closes Projects. Settings in the sidebar opens the Settings window beside it.
// A click on the empty list clears the selection; New group goes into the selected group, beside the selected project, or to the
// top level when nothing is selected — first as a name field in that place (↩ creates it; Esc, an empty name or a click elsewhere
// cancels). Rows move by drag (not while searching): a line between rows, a ring on the group it goes into, below the last row the
// top level; a group never into itself; Esc cancels. ••• or a right-click opens the row's menu — a project: Open · Reveal in Finder ·
// Move to group › · Remove from list (Open and Reveal off for a missing project, Remove for the open one); a group: Rename… (the
// name field in its row; ↩ or a click elsewhere keeps the name, Esc cancels) · Move to group › · Delete group (its projects and
// groups move up into its place). Move to group ›: Top level and every group by its path, ✓ where it is now, then New group…, which
// asks for a name where the row is now and moves the row into the new group.
// ------------------------------------------------------------
// move a node: before / after another one, into a group (as its last child), or to the end of the top level
function moveTreeNode(tree, id, ref, where) {
  let moving = null;
  const cut = (ns) => ns.filter(n => n.id === id ? ((moving = n), false) : true).map(n => n.children ? { ...n, children: cut(n.children) } : n);
  const put = (ns) => {
    const i = ns.findIndex(n => n.id === ref);
    if (i >= 0 && where !== "into") { const at = i + (where === "after" ? 1 : 0); return [...ns.slice(0, at), moving, ...ns.slice(at)]; }
    return ns.map(n => n.id === ref ? { ...n, expanded: true, children: [...(n.children || []), moving] } : n.children ? { ...n, children: put(n.children) } : n);
  };
  const rest = cut(tree);
  return !moving ? tree : where === "end" ? [...rest, moving] : put(rest);
}
const NAMING = "__naming"; // the id of a new group's name field among the rows
// replace a node by what f returns: [] removes it, its children ungroup it
function spliceTreeNode(tree, id, f) {
  return tree.flatMap(n => n.id === id ? f(n) : [n.children ? { ...n, children: spliceTreeNode(n.children, id, f) } : n]);
}

// RowMenu — a Projects row's menu in the card menu's look: items { label, onSelect, disabled, checked, submenu } or "sep". A submenu
// opens beside its row on hover or click (to the left at the screen's edge); a click outside, Esc, a resize or leaving the app closes it.
function RowMenu({ x, y, items, onClose }) {
  const [sub, setSub] = useState(null); // { i, rect }
  useEffect(() => {
    const down = (e) => { if (!e.target.closest(".zpw-menu")) onClose(); };
    const key = (e) => { if (e.key === "Escape") { e.preventDefault(); e.stopImmediatePropagation(); onClose(); } };
    window.addEventListener("pointerdown", down, true); window.addEventListener("keydown", key, true);
    window.addEventListener("resize", onClose); window.addEventListener("blur", onClose);
    return () => {
      window.removeEventListener("pointerdown", down, true); window.removeEventListener("keydown", key, true);
      window.removeEventListener("resize", onClose); window.removeEventListener("blur", onClose);
    };
  }, []);
  return <>
    <MenuPanel x={x} y={y} items={items} sub={sub} onSub={setSub} onClose={onClose}/>
    {sub && <MenuPanel anchor={sub.rect} items={items[sub.i].submenu} onClose={onClose}/>}
  </>;
}
function MenuPanel({ x, y, anchor, items, sub, onSub, onClose }) {
  const ref = useRef(null);
  const [pos, setPos] = useState(null);
  useLayoutEffect(() => {
    const w = ref.current.offsetWidth, h = ref.current.offsetHeight, W = vw(), H = vh();
    let left = anchor ? anchor.right + 2 : x;
    if (left + w > W - 6) left = anchor ? anchor.left - w - 2 : W - w - 6;
    setPos({ left: Math.max(6, left), top: Math.max(6, Math.min(anchor ? anchor.top - 6 : y, H - h - 6)) });
  }, [x, y, anchor]);
  return (
    <div ref={ref} className="gmenu zpw-menu" role="menu" style={{ left: pos ? pos.left : 0, top: pos ? pos.top : 0, visibility: pos ? "visible" : "hidden" }} onContextMenu={(e) => e.preventDefault()}>
      {items.map((it, i) => it === "sep" ? <div key={"sep" + i} className="gmenu-sep"></div> : (
        <button key={it.label} type="button" role={it.checked != null ? "menuitemradio" : "menuitem"} aria-checked={it.checked} aria-haspopup={it.submenu ? "menu" : undefined}
          className={"gmenu-item" + (sub && sub.i === i ? " is-open" : "")} disabled={it.disabled}
          onMouseEnter={(e) => onSub && onSub(it.submenu ? { i, rect: e.currentTarget.getBoundingClientRect() } : null)}
          onClick={(e) => { if (it.submenu) onSub({ i, rect: e.currentTarget.getBoundingClientRect() }); else { onClose(); it.onSelect(); } }}>
          <span className="zpw-menu-check">{it.checked && <Ic name="check" size={12}/>}</span>
          <span>{it.label}</span>
          <span className="gmenu-cmd">{it.submenu && <Ic name="chevronRight" size={12}/>}</span>
        </button>
      ))}
    </div>
  );
}

function ProjectsWin({ tree, setTree, activeProjectId, onOpenProject, onSettings, active, geo, setGeo, z, onActivate, onClose, onZoom }) {
  const [query, setQuery] = useState("");
  const [selectedId, setSelectedId] = useState(activeProjectId);
  const [dragOver, setDragOver] = useState(false);
  const [move, setMove] = useState(null); // a row in hand: { node, x, y, target: { ref, where, label } | null }
  const [naming, setNaming] = useState(null); // a group's name being typed: { parent, moveId } for a new one, { id } to rename
  const [menu, setMenu] = useState(null); // { node, x, y }
  const q = query.trim().toLowerCase();
  const visible = useMemo(() => {
    if (q) return window.flattenAll(tree).filter(({ node }) => node.name.toLowerCase().includes(q) || (node.kind === "project" && (node.path || "").toLowerCase().includes(q)));
    // a new group's name field stands where the group will be: the last row of its parent
    const field = { id: NAMING, kind: "naming" };
    const shown = !naming || naming.id ? tree : naming.parent ? window.updateTreeNode(tree, naming.parent, n => ({ ...n, children: [...(n.children || []), field] })) : [...tree, field];
    return window.flattenTree(shown);
  }, [tree, q, naming]);
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
  const startNaming = (parent, moveId) => {
    setQuery("");
    if (parent) setTree(tr => window.updateTreeNode(tr, parent, n => ({ ...n, expanded: true })));
    setNaming({ parent, moveId });
  };
  const newGroup = () => {
    const sel = selectedId && window.flattenAll(tree).find(x => x.node.id === selectedId);
    startNaming(sel ? (sel.node.kind === "group" ? sel.node.id : sel.path[sel.path.length - 2] || null) : null);
  };
  const commitName = (value) => {
    const name = value.trim(), n = naming;
    setNaming(null);
    if (!n || !name) return;
    if (n.id) { setTree(tr => window.updateTreeNode(tr, n.id, g => ({ ...g, name }))); return; }
    const g = { id: "g_" + Date.now(), kind: "group", name, expanded: true, children: [] };
    setTree(tr => {
      const added = n.parent ? window.updateTreeNode(tr, n.parent, p => ({ ...p, children: [...(p.children || []), g] })) : [...tr, g];
      return n.moveId ? moveTreeNode(added, n.moveId, g.id, "into") : added;
    });
    setSelectedId(n.moveId || g.id);
  };
  // the row menu: Move to group › lists Top level and every group by its path (not the row itself or what is inside it)
  const menuFor = (node) => {
    const all = window.flattenAll(tree), hit = all.find(x => x.node.id === node.id), parent = hit.path[hit.path.length - 2] || null;
    const names = new Map(all.map(x => [x.node.id, x.node.name]));
    const block = new Set([node.id, ...window.flattenAll(node.children || []).map(x => x.node.id)]);
    const groups = all.filter(x => x.node.kind === "group" && !block.has(x.node.id))
      .map(x => ({ id: x.node.id, label: x.path.map(id => names.get(id)).join(" / ") }))
      .sort((a, b) => a.label.toLowerCase().localeCompare(b.label.toLowerCase()));
    const moveTo = (gid) => { if (gid !== parent) setTree(tr => moveTreeNode(tr, node.id, gid, gid ? "into" : "end")); setSelectedId(node.id); };
    const moveMenu = { label: "Move to group", submenu: [
      { label: "Top level", checked: parent === null, onSelect: () => moveTo(null) },
      ...groups.map(g => ({ label: g.label, checked: parent === g.id, onSelect: () => moveTo(g.id) })),
      "sep",
      { label: "New group…", onSelect: () => startNaming(parent, node.id) },
    ] };
    if (node.kind === "group") return [
      { label: "Rename…", onSelect: () => setNaming({ id: node.id }) },
      moveMenu,
      "sep",
      { label: "Delete group", onSelect: () => { setTree(tr => spliceTreeNode(tr, node.id, g => g.children || [])); setSelectedId(null); } },
    ];
    const missing = node.status === "missing";
    return [
      { label: "Open", disabled: missing, onSelect: () => open(node) },
      { label: "Reveal in Finder", disabled: missing, onSelect: () => {} },
      moveMenu,
      "sep",
      { label: "Remove from list", disabled: node.id === activeProjectId, onSelect: () => { setTree(tr => spliceTreeNode(tr, node.id, () => [])); setSelectedId(null); } },
    ];
  };
  // ••• opens it below the button, a right-click at the pointer; either selects the row
  const openMenu = (e, node, below) => {
    e.preventDefault(); e.stopPropagation();
    setSelectedId(node.id);
    const r = below && e.currentTarget.getBoundingClientRect();
    setMenu({ node, x: r ? r.right - 200 : e.clientX, y: r ? r.bottom + 4 : e.clientY });
  };
  // a group's name typed in place: a new one (↩ creates it; Esc, an empty name or a click elsewhere cancels) or Rename… (↩ or a click
  // elsewhere keeps it, Esc cancels)
  const nameRow = (key, depth, value) => (
    <div key={key} className="home-row group naming" style={{ "--depth": depth }}>
      <span className="home-row-chev"></span>
      <Ic name="folder" size={14} className="home-row-icon"/>
      <input className="zpw-name" defaultValue={value} placeholder="Group name" aria-label={value != null ? "Rename group" : "New group"}
        ref={(el) => { if (el && !el.dataset.ready) { el.dataset.ready = "1"; el.focus(); el.select(); } }}
        onKeyDown={(e) => {
          e.stopPropagation();
          if (e.key !== "Enter" && e.key !== "Escape") return;
          e.currentTarget.dataset.done = "1"; // the blur of the field going away must not decide again
          if (e.key === "Enter") commitName(e.currentTarget.value); else setNaming(null);
        }}
        onBlur={(e) => { if (e.target.dataset.done) return; if (value != null) commitName(e.target.value); else setNaming(null); }}/>
    </div>
  );
  // moving a row: pointer drag past 4px; the target follows the pointer's row (top / bottom half, a group's middle = into it)
  const startMove = (e, node) => {
    if (e.button !== 0 || q || e.target.closest("button,input")) return;
    const byId = new Map(window.flattenAll(tree).map(x => [x.node.id, x]));
    const block = new Set([node.id, ...window.flattenAll(node.children || []).map(x => x.node.id)]);
    const x0 = e.clientX, y0 = e.clientY;
    let live = false, target = null;
    const targetAt = (x, y) => {
      const el = document.elementFromPoint(x, y), list = el && el.closest(".zpw .home-list");
      if (!list) return null;
      const row = [...list.querySelectorAll(".home-row[data-id]")].find(r => y < r.getBoundingClientRect().bottom + 1);
      if (!row) return { where: "end", label: "To the top level" };
      const hit = byId.get(row.dataset.id);
      if (!hit || block.has(hit.node.id)) return null;
      const r = row.getBoundingClientRect(), f = (y - r.top) / r.height, n = hit.node;
      const where = n.kind !== "group" ? (f < .5 ? "before" : "after")
        : f < .25 ? "before" : f < .75 || (n.expanded && n.children && n.children.length) ? "into" : "after";
      const parent = where === "into" ? n : (byId.get(hit.path[hit.path.length - 2]) || {}).node;
      return { ref: n.id, where, label: parent ? "Into " + parent.name : "To the top level" };
    };
    const onMove = (ev) => {
      if (!live && Math.hypot(ev.clientX - x0, ev.clientY - y0) < 4) return;
      live = true; target = targetAt(ev.clientX, ev.clientY);
      setMove({ node, x: ev.clientX, y: ev.clientY, target });
    };
    const end = (drop) => {
      window.removeEventListener("pointermove", onMove); window.removeEventListener("pointerup", onUp);
      window.removeEventListener("pointercancel", onCancel); window.removeEventListener("keydown", onKey, true);
      if (!live) return;
      setMove(null);
      // the click that ends a drag must neither toggle a group nor clear the selection
      const swallow = (ev) => { ev.stopPropagation(); ev.preventDefault(); };
      window.addEventListener("click", swallow, true); setTimeout(() => window.removeEventListener("click", swallow, true), 0);
      if (drop && target) { setTree(tr => moveTreeNode(tr, node.id, target.ref, target.where)); setSelectedId(node.id); }
    };
    const onUp = () => end(true), onCancel = () => end(false);
    const onKey = (ev) => { if (ev.key === "Escape" && live) { ev.preventDefault(); ev.stopPropagation(); end(false); } };
    window.addEventListener("pointermove", onMove); window.addEventListener("pointerup", onUp);
    window.addEventListener("pointercancel", onCancel); window.addEventListener("keydown", onKey, true);
  };
  const dropCls = (id) => move && move.target && move.target.ref === id ? " drop-" + move.target.where : "";
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
        <button className="home-action ghost" title="New group" aria-label="New group" onClick={newGroup}><Ic name="folderPlus" size={13}/></button>
      </>}>
      <div className={"home-list" + (move && move.target && move.target.where === "end" ? " drop-end" : "")} role="tree" aria-label="Projects"
        onClick={(e) => { if (e.target === e.currentTarget) setSelectedId(null); }}>
        {visible.length === 0 && <div className="home-empty">No projects match “{query}”</div>}
        {visible.map(({ node, depth }) => {
          if (node.kind === "naming") return nameRow(NAMING, depth);
          if (naming && naming.id === node.id) return nameRow(node.id, depth, node.name);
          const moving = move && move.node.id === node.id ? "drag-from " : "";
          if (node.kind === "group") {
            const count = (node.children || []).filter(c => c.kind === "project").length, sub = (node.children || []).filter(c => c.kind === "group").length;
            return (
              <div key={node.id} data-id={node.id} className={"home-row group " + (node.expanded ? "expanded " : "") + (selectedId === node.id ? "selected " : "") + moving + dropCls(node.id)} style={{ "--depth": depth }}
                onPointerDown={(e) => startMove(e, node)} onClick={() => { setSelectedId(node.id); toggleGroup(node.id); }} onContextMenu={(e) => openMenu(e, node)} role="treeitem" aria-expanded={!!node.expanded}>
                <span className="home-row-indent" aria-hidden="true"></span>
                <span className={"home-row-chev " + (node.expanded ? "open" : "")}><Ic name="chevronRight" size={12}/></span>
                <Ic name={node.expanded ? "folderOpen" : "folder"} size={14} className="home-row-icon"/>
                <span className="home-row-name">{node.name}</span>
                <span className="home-row-count">{count}{sub > 0 && ` · ${sub} group${sub === 1 ? "" : "s"}`}</span>
                <button className="home-row-more" onClick={(e) => openMenu(e, node, true)} title="More…" aria-label="More…" aria-haspopup="menu"><Ic name="more" size={13}/></button>
              </div>
            );
          }
          const s = STATUS[node.status] || STATUS.clean, isOpen = activeProjectId === node.id;
          return (
            <div key={node.id} data-id={node.id} className={"home-row project " + (selectedId === node.id ? "selected " : "") + (isOpen ? "active-project " : "") + (node.status === "missing" ? "missing " : "") + moving + dropCls(node.id)}
              style={{ "--depth": depth }} onPointerDown={(e) => startMove(e, node)} onClick={() => setSelectedId(node.id)} onContextMenu={(e) => openMenu(e, node)} onDoubleClick={() => open(node)} role="treeitem" aria-selected={selectedId === node.id} title={node.path}>
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
              <button className="home-row-more" onClick={(e) => openMenu(e, node, true)} title="More…" aria-label="More…" aria-haspopup="menu"><Ic name="more" size={13}/></button>
            </div>
          );
        })}
      </div>
      <div className={"home-drop-hint " + (dragOver ? "active" : "")}><Ic name="download" size={13}/><span>Drop to add directory</span></div>
      {move && (
        <div className="gghost" style={{ position: "fixed", left: move.x, top: move.y }} aria-hidden="true">
          <div className="gghost-card">
            {move.node.kind === "group" ? <Ic name="folder" size={13}/> : <span className="home-row-status" style={{ background: (STATUS[move.node.status] || STATUS.clean).color }}></span>}
            <span className="gghost-subj">{move.node.name}</span>
          </div>
          <div className={"gghost-cmd" + (move.target ? " on" : "")}><span className="gghost-alt">{move.target ? move.target.label : "Drop between rows or on a group"}</span></div>
        </div>
      )}
      {menu && <RowMenu x={menu.x} y={menu.y} items={menuFor(menu.node)} onClose={() => setMenu(null)}/>}
    </WindowFrame>
  );
}

Object.assign(window, { TrafficLights, WindowFrame, SettingsWin, ProjectsWin, RowMenu, placeWindow, clampWindow });
})();
