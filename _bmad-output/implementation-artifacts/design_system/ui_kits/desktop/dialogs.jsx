// Windows — Projects (the project picker, the start window) and Settings (General · Project). Both are macOS windows of their own
// (components/window: Window) above the project window: no scrim, no ✕ — the red button and ⌘W close them; the system draws the frame.
(() => {
const { Window, SearchField, Button, ProjectRow, DragGhost, Menu, NamiMark, Icon, Segmented, Switch, Select, TextField, SettingsGroup, SettingsRow, HatchSwatch, ImmutablePage } = window.ZanshinDesignSystem_a33847;
const Swatch = HatchSwatch || (() => null);

function zkFlatten(nodes, depth = 0, all = false, out = [], parent = null) {
  nodes.forEach((n) => { out.push({ node: n, depth, parent }); if (n.kind === "group" && (all || n.expanded)) zkFlatten(n.children || [], depth + 1, all, out, n); });
  return out;
}
// move a node: before / after another one, into a group (as its last child), or to the end of the top level
function zkMove(nodes, id, ref, where) {
  let moving = null;
  const cut = (ns) => ns.filter((n) => n.id === id ? ((moving = n), false) : true).map((n) => n.children ? { ...n, children: cut(n.children) } : n);
  const put = (ns) => {
    const i = ns.findIndex((n) => n.id === ref);
    if (i >= 0 && where !== "into") { const at = i + (where === "after" ? 1 : 0); return [...ns.slice(0, at), moving, ...ns.slice(at)]; }
    return ns.map((n) => n.id === ref ? { ...n, expanded: true, children: [...(n.children || []), moving] } : n.children ? { ...n, children: put(n.children) } : n);
  };
  const rest = cut(nodes);
  return !moving ? nodes : where === "end" ? [...rest, moving] : put(rest);
}
// change one node: f returns what stands in its place — [] removes it, its children ungroup it
function zkEdit(nodes, id, f) {
  return nodes.flatMap((n) => n.id === id ? f(n) : [n.children ? { ...n, children: zkEdit(n.children, id, f) } : n]);
}
const ZK_NAMING = "__naming"; // a new group's name field among the rows

// A click on the empty tree clears the selection (then the first row is the Tab stop). New group asks for the name where the group will
// be: in the selected group, beside the selected project, or at the top level (ProjectRow editing). Rows move by drag (not while
// searching): ProjectRow drop / dragging + DragGhost; Esc cancels. ••• or a right-click opens the row's Menu — a project: Open · Reveal in
// Finder · Move to group › · Remove from list; a group: Rename… · Move to group › · Delete group (its contents move up). Move to group ›:
// Top level and every group by its path, the current one checked, then New group…, which names a group where the row is and moves it in.
function ZKProjects({ tree, setTree, activeId, onOpen, onClose, onSettings, active = true, onFocus, style }) {
  const [q, setQ] = React.useState("");
  const [sel, setSel] = React.useState(activeId);
  const [move, setMove] = React.useState(null); // a row in hand: { node, x, y, target: { i, ref, where, label } | null }
  const [naming, setNaming] = React.useState(null); // a group's name being typed: { parent, moveId } for a new one, { id } to rename
  const [menu, setMenu] = React.useState(null); // { node, x, y }
  const query = q.trim().toLowerCase();
  const field = { id: ZK_NAMING, kind: "naming" };
  const shown = !naming || naming.id ? tree : naming.parent ? zkEdit(tree, naming.parent, (n) => [{ ...n, children: [...(n.children || []), field] }]) : [...tree, field];
  const rows = query
    ? zkFlatten(tree, 0, true).filter(({ node }) => (node.name + " " + (node.path || "")).toLowerCase().includes(query))
    : zkFlatten(shown);
  const toggle = (id) => {
    const up = (ns) => ns.map((n) => n.id === id ? { ...n, expanded: !n.expanded } : n.children ? { ...n, children: up(n.children) } : n);
    setTree(up(tree));
  };
  // keys while this window is key: ↩ opens the selected project · Esc clears the search — it never closes the window
  React.useEffect(() => {
    if (!active) return undefined;
    const k = (e) => {
      if (e.key === "Enter" && sel && !e.defaultPrevented) { const r = zkFlatten(tree, 0, true).find((x) => x.node.id === sel); if (r && r.node.kind === "project") onOpen(r.node.id); }
      if (e.key === "Escape" && q) { e.preventDefault(); setQ(""); }
    };
    window.addEventListener("keydown", k); return () => window.removeEventListener("keydown", k);
  }, [sel, tree, q, active]);
  const startNaming = (parent, moveId) => {
    setQ("");
    if (parent) setTree(zkEdit(tree, parent, (n) => [{ ...n, expanded: true }]));
    setNaming({ parent, moveId });
  };
  const newGroup = () => {
    const s = sel && zkFlatten(tree, 0, true).find((x) => x.node.id === sel);
    startNaming(s ? (s.node.kind === "group" ? s.node.id : s.parent && s.parent.id) : null);
  };
  const commitName = (name) => {
    const n = naming;
    setNaming(null);
    if (n.id) { setTree(zkEdit(tree, n.id, (g) => [{ ...g, name }])); return; }
    const g = { id: "g-" + Date.now(), kind: "group", name, expanded: true, children: [] };
    const added = n.parent ? zkEdit(tree, n.parent, (p) => [{ ...p, children: [...(p.children || []), g] }]) : [...tree, g];
    setTree(n.moveId ? zkMove(added, n.moveId, g.id, "into") : added); setSel(n.moveId || g.id);
  };
  // the row's Menu: Move to group › lists Top level and every group by its path — never the row itself or what is inside it
  const menuFor = (node) => {
    const all = zkFlatten(tree, 0, true), byId = new Map(all.map((x) => [x.node.id, x]));
    const parent = byId.get(node.id).parent ? byId.get(node.id).parent.id : null;
    const pathOf = (id) => { const out = []; for (let x = byId.get(id); x; x = x.parent && byId.get(x.parent.id)) out.unshift(x.node.name); return out.join(" / "); };
    const block = new Set([node.id, ...zkFlatten(node.children || [], 0, true).map((x) => x.node.id)]);
    const groups = all.filter((x) => x.node.kind === "group" && !block.has(x.node.id)).map((x) => ({ id: x.node.id, label: pathOf(x.node.id) }))
      .sort((a, b) => a.label.toLowerCase().localeCompare(b.label.toLowerCase()));
    const moveTo = (gid) => { if (gid !== parent) setTree(zkMove(tree, node.id, gid, gid ? "into" : "end")); setSel(node.id); };
    const moveMenu = { id: "move", label: "Move to group", submenu: [
      { id: "top", label: "Top level", checked: parent === null, radio: true, run: () => moveTo(null) },
      ...groups.map((g) => ({ id: "g:" + g.id, label: g.label, checked: parent === g.id, radio: true, run: () => moveTo(g.id) })),
      "sep",
      { id: "new", label: "New group…", run: () => startNaming(parent, node.id) },
    ] };
    if (node.kind === "group") return [
      { id: "rename", label: "Rename…", run: () => setNaming({ id: node.id }) },
      moveMenu,
      "sep",
      { id: "delete", label: "Delete group", run: () => { setTree(zkEdit(tree, node.id, (g) => g.children || [])); setSel(null); } },
    ];
    const missing = node.status === "missing";
    return [
      { id: "open", label: "Open", disabled: missing, run: () => onOpen(node.id) },
      { id: "reveal", label: "Reveal in Finder", disabled: missing, run: () => {} },
      moveMenu,
      "sep",
      { id: "remove", label: "Remove from list", disabled: node.id === activeId, run: () => { setTree(zkEdit(tree, node.id, () => [])); setSel(null); } },
    ];
  };
  // ••• opens it below the button, a right-click at the pointer; either selects the row. A click outside closes it, Esc / ← too (Menu).
  const openMenu = (e, node, below) => {
    e.preventDefault(); e.stopPropagation(); setSel(node.id);
    const r = below && e.currentTarget.getBoundingClientRect();
    setMenu({ node, x: Math.max(8, Math.min(r ? r.right - 220 : e.clientX, window.innerWidth - 240)), y: Math.min(r ? r.bottom + 4 : e.clientY, window.innerHeight - 220) });
  };
  React.useEffect(() => {
    if (!menu) return undefined;
    const down = (e) => { if (!e.target.closest(".zk-menu")) setMenu(null); };
    window.addEventListener("pointerdown", down, true); return () => window.removeEventListener("pointerdown", down, true);
  }, [menu]);
  // moving a row: a pointer drag past 4px; the row under the pointer decides — top / bottom half, a group's middle = into it
  const startMove = (e, node) => {
    if (e.button !== 0 || query || naming || e.target.closest("button,input")) return;
    const list = rows, el = e.currentTarget.closest('[role="tree"]'), x0 = e.clientX, y0 = e.clientY;
    const block = new Set([node.id, ...zkFlatten(node.children || [], 0, true).map((x) => x.node.id)]);
    let live = false, target = null;
    const targetAt = (x, y) => {
      const r = el.getBoundingClientRect();
      if (x < r.left || x > r.right || y < r.top || y > r.bottom) return null;
      const items = [...el.querySelectorAll('[role="treeitem"]')], i = items.findIndex((it) => y < it.getBoundingClientRect().bottom + 1);
      if (i < 0) return { i: items.length - 1, where: "end", label: "To the top level" };
      const hit = list[i], n = hit.node;
      if (block.has(n.id)) return null;
      const b = items[i].getBoundingClientRect(), f = (y - b.top) / b.height;
      const where = n.kind !== "group" ? (f < .5 ? "before" : "after")
        : f < .25 ? "before" : f < .75 || (n.expanded && (n.children || []).length) ? "into" : "after";
      const parent = where === "into" ? n : hit.parent;
      return { i, ref: n.id, where, label: parent ? "Into " + parent.name : "To the top level" };
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
      // the click that ends a drag neither toggles a group nor clears the selection
      const swallow = (ev) => { ev.stopPropagation(); ev.preventDefault(); };
      window.addEventListener("click", swallow, true); setTimeout(() => window.removeEventListener("click", swallow, true), 0);
      if (drop && target) { setTree(zkMove(tree, node.id, target.ref, target.where)); setSel(node.id); }
    };
    const onUp = () => end(true), onCancel = () => end(false);
    const onKey = (ev) => { if (ev.key === "Escape" && live) { ev.preventDefault(); ev.stopPropagation(); end(false); } };
    window.addEventListener("pointermove", onMove); window.addEventListener("pointerup", onUp);
    window.addEventListener("pointercancel", onCancel); window.addEventListener("keydown", onKey, true);
  };
  const dropAt = (i) => move && move.target && move.target.i === i ? move.target.where : undefined;
  return (
    <div onMouseDown={onFocus} style={style}>
      <Window title="Projects" active={active} buttons={{ close: true, zoom: true }} onClose={onClose} width={900} height={640} sidebarWidth={210}
        sidebar={<>
          <div className="zk-brand"><NamiMark size={32} chip/><div><div className="zk-brand-n">Zanshin</div><div className="zk-brand-s">jj client · v0.24.0</div></div></div>
          <nav className="zk-side-nav" aria-label="Sections">
            <button type="button" className="zs-dialog-navitem is-on" aria-current="page"><Icon name="folder-open" size="md"/><span>Projects</span></button>
            <button type="button" className="zs-dialog-navitem"><Icon name="cloud" size="md"/><span>Remotes</span></button>
            <button type="button" className="zs-dialog-navitem" onClick={onSettings} title="Settings — ⌘, (the tab shown last)"><Icon name="settings" size="md"/><span>Settings…</span></button>
          </nav>
          <div className="zk-signed"><div className="zk-signed-l">Signed in</div><div className="zk-signed-u"><span className="zk-avatar">A</span><div><div>Alice Sralph</div><div className="zk-signed-m">alice@dasralph.de</div></div></div></div>
        </>}
        header={<>
          <span className="zs-win-grow"></span>
          <SearchField placeholder="Search projects, paths…" value={q} onChange={setQ} autoFocus style={{ width: 230 }}/>
          <Button size="md" variant="primary" icon="plus" iconSize="sm">Add directory</Button>
          <Button size="md" icon="cloud">Clone…</Button>
          <Button size="md" variant="ghost" icon="folder-plus" label="New group" title="New group" onClick={newGroup}/>
        </>}>
        <div className="zk-tree" role="tree" aria-label="Projects" onClick={(e) => { if (e.target === e.currentTarget) setSel(null); }}>
          {!rows.length && <div className="zk-empty">No projects match “{q}”</div>}
          {rows.map(({ node, depth }, i) => node.kind === "naming" || (naming && naming.id === node.id) ? (
            <ProjectRow key={node.id} kind="group" editing name={node.kind === "naming" ? "" : node.name} depth={depth} onCommit={commitName} onCancel={() => setNaming(null)}/>
          ) : node.kind === "group" ? (
            <ProjectRow key={node.id} kind="group" name={node.name} depth={depth} expanded={!!node.expanded || !!query} selected={sel === node.id}
              count={(node.children || []).filter((c) => c.kind === "project").length} groups={(node.children || []).filter((c) => c.kind === "group").length}
              dragging={!!move && move.node.id === node.id} drop={dropAt(i)} tabIndex={sel == null && i === 0 ? 0 : undefined} onPointerDown={(e) => startMove(e, node)}
              onMore={(e) => openMenu(e, node, true)} onContextMenu={(e) => openMenu(e, node)}
              onClick={() => { setSel(node.id); toggle(node.id); }} onToggle={() => toggle(node.id)} onSelect={() => setSel(node.id)}/>
          ) : (
            <ProjectRow key={node.id} {...node} kind="project" depth={depth} open={node.id === activeId} selected={sel === node.id}
              dragging={!!move && move.node.id === node.id} drop={dropAt(i)} tabIndex={sel == null && i === 0 ? 0 : undefined} onPointerDown={(e) => startMove(e, node)}
              onMore={(e) => openMenu(e, node, true)} onContextMenu={(e) => openMenu(e, node)}
              onClick={() => setSel(node.id)} onSelect={() => setSel(node.id)} onDoubleClick={() => node.status !== "missing" && onOpen(node.id)}/>
          ))}
        </div>
        {menu && <div className="zk-menu" style={{ left: menu.x, top: menu.y }} onContextMenu={(e) => e.preventDefault()}>
          <Menu aria-label={menu.node.name} items={menuFor(menu.node)} autoFocus onClose={() => setMenu(null)} onSelect={(id, item) => { setMenu(null); if (item && item.run) item.run(); }}/>
        </div>}
        {move && <div className="zk-ghost" style={{ left: move.x, top: move.y }}>
          <DragGhost kind={move.node.kind} status={move.node.status} label={move.node.name} target={move.target ? move.target.label : undefined} hint="Drop between rows or on a group"/>
        </div>}
      </Window>
    </div>
  );
}

// page "immutable": Settings › Project › Immutable commits (ImmutablePage) — a page inside the Project tab, reached from History's navigation row
// or the card menu of an immutable change; the window's title becomes the page's name, ‹ MyApp returns to the tab.
function ZKSettings({ tab, setTab, page, setPage, imm, setImm, trunk, setTrunk, immInfo = {}, onClose, prefs, setPref, project, active = true, onFocus, style }) {
  const [g, setG] = React.useState({ name: "Ralph Stein", email: "ralph@dasralph.de" });
  const [p, setP] = React.useState({ fetch: "origin", push: "origin", auto: "15", own: false, email: "ralph@work.example" });
  const sub = tab === "project" && page === "immutable" && ImmutablePage;
  const setp = (k, v) => setP((o) => ({ ...o, [k]: v }));
  // the window title is the tab's name (Window menu, Mission Control); no Esc, no ✕ — changes apply at once
  return (
    <div onMouseDown={onFocus} style={style}>
      <Window title={tab === "general" ? "General" : sub ? "Immutable commits" : "Project"} titleHidden active={active} buttons={{ close: true }} onClose={onClose} width={620} headerAlign="center" style={{ maxHeight: 740 }}
        header={<Segmented variant="tabs" label="Settings" value={tab} onChange={setTab} options={[{ value: "general", label: "General", icon: "settings" },
          project ? { value: "project", label: project.name, icon: <span className="zk-set-mark"><NamiMark size={14}/></span> } : { value: "project", label: "Project", icon: "folder", disabled: true, title: "Open a project first" }]}/>}>
        <div className="zk-set-scope">
          {tab === "general" ? <>For Zanshin on this Mac · jj settings go to <code>~/.config/jj/config.toml</code></> : <>For {project.name} only · <code>{project.path}/.jj/repo/config.toml</code></>}
        </div>
        <div className="zk-set-bd">
          {tab === "general" ? <>
            <SettingsGroup title="Appearance">
              <SettingsRow label="Theme"><Segmented variant="inset" label="Theme" value={prefs.theme} onChange={(v) => setPref("theme", v)} options={[{ value: "paper", label: "Paper", icon: "sun" }, { value: "night", label: "Night", icon: "moon" }, { value: "system", label: "Auto", icon: "auto" }]}/></SettingsRow>
              <SettingsRow label="Density"><Segmented variant="inset" label="Density" value={prefs.density} onChange={(v) => setPref("density", v)} options={[{ value: "compact", label: "Compact" }, { value: "balanced", label: "Balanced" }, { value: "comfy", label: "Comfy" }]}/></SettingsRow>
              <SettingsRow label="Accent colour" hint="Selection, focus and controls take the colour from System Settings › Appearance. Gold stays with @ and the primary action."><Segmented variant="inset" label="Accent colour" value={prefs.accent || "macos"} onChange={(v) => setPref("accent", v)} options={[{ value: "macos", label: "Follow macOS" }, { value: "zanshin", label: "Zanshin" }]}/></SettingsRow>
            </SettingsGroup>
            <SettingsGroup title="While you scroll">
              <SettingsRow label="Hide controls" hint="Toolbars and panels step aside while you scroll the graph. The minimap stays."><Switch label="Hide controls while scrolling" checked={prefs.autoHide} onChange={(v) => setPref("autoHide", v)}/></SettingsRow>
            </SettingsGroup>
            <SettingsGroup title="Diffs">
              <SettingsRow label="Layout"><Segmented variant="inset" label="Diff layout" value={prefs.diffMode} onChange={(v) => setPref("diffMode", v)} options={[{ value: "unified", label: "Unified" }, { value: "split", label: "Side by side" }]}/></SettingsRow>
            </SettingsGroup>
            <SettingsGroup title="Identity">
              <SettingsRow label="Name" configKey="user.name"><TextField value={g.name} onChange={(e) => setG({ ...g, name: e.target.value })} aria-label="Name"/></SettingsRow>
              <SettingsRow label="Email" configKey="user.email"><TextField value={g.email} onChange={(e) => setG({ ...g, email: e.target.value })} aria-label="Email"/></SettingsRow>
            </SettingsGroup>
          </> : sub ? <ImmutablePage config={imm} onChange={setImm} project={project.name} trunkName={trunk} onBack={() => setPage(null)} {...immInfo}/> : <>
            <SettingsGroup title="Remotes">
              <SettingsRow label="Fetch from" configKey="git.fetch"><Select label="Fetch from" value={p.fetch} onChange={(v) => setp("fetch", v)} options={["origin", "upstream"]}/></SettingsRow>
              <SettingsRow label="Push to" configKey="git.push"><Select label="Push to" value={p.push} onChange={(v) => setp("push", v)} options={["origin", "upstream"]}/></SettingsRow>
              <SettingsRow label="Fetch automatically"><Segmented variant="inset" label="Fetch automatically" value={p.auto} onChange={(v) => setp("auto", v)} options={[{ value: "off", label: "Off" }, { value: "5", label: "5 min" }, { value: "15", label: "15 min" }]}/></SettingsRow>
            </SettingsGroup>
            <SettingsGroup title="History">
              <SettingsRow label="Trunk" configKey={'revset-aliases."trunk()"'}><Select label="Trunk" value={trunk} onChange={setTrunk} options={["main", "develop", "release/1.5.x@origin"]}/></SettingsRow>
              {ImmutablePage && (
                <SettingsRow label="Immutable commits" hint={ImmutablePage.summary(imm)} configKey={'revset-aliases."immutable_heads()"'} onOpen={() => setPage("immutable")}>
                  <span className="zs-setrow-count" title={immInfo.count + " immutable changes"}><Swatch/>{immInfo.count}</span>
                </SettingsRow>
              )}
            </SettingsGroup>
            <SettingsGroup title="Identity">
              <SettingsRow label="Use a different email here" hint="For work repositories with their own address."><Switch label="Use a different email" checked={p.own} onChange={(v) => setp("own", v)}/></SettingsRow>
              {p.own && <SettingsRow label="Email" configKey="user.email"><TextField value={p.email} onChange={(e) => setp("email", e.target.value)} aria-label="Project email"/></SettingsRow>}
            </SettingsGroup>
          </>}
        </div>
        <footer className="zk-set-ft">How the graph looks lives with the graph: <b>View options</b> in the toolbar.</footer>
      </Window>
    </div>
  );
}

Object.assign(window, { ZKProjects, ZKSettings, zkFlatten });
})();
