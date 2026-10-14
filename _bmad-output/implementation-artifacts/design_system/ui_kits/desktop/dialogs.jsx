// Dialogs — Projects (the IntelliJ-style project picker) and the Settings window (General · Project).
(() => {
const { Dialog, SearchField, Button, ProjectRow, NamiMark, Icon, IconButton, Segmented, Switch, Select, TextField, SettingsGroup, SettingsRow } = window.ZanshinDesignSystem_a33847;

function zkFlatten(nodes, depth = 0, all = false, out = []) {
  nodes.forEach((n) => { out.push({ node: n, depth }); if (n.kind === "group" && (all || n.expanded)) zkFlatten(n.children || [], depth + 1, all, out); });
  return out;
}

function ZKProjects({ tree, setTree, activeId, onOpen, onClose }) {
  const [q, setQ] = React.useState("");
  const [sel, setSel] = React.useState(activeId);
  const query = q.trim().toLowerCase();
  const rows = query
    ? zkFlatten(tree, 0, true).filter(({ node }) => (node.name + " " + (node.path || "")).toLowerCase().includes(query))
    : zkFlatten(tree);
  const toggle = (id) => {
    const up = (ns) => ns.map((n) => n.id === id ? { ...n, expanded: !n.expanded } : n.children ? { ...n, children: up(n.children) } : n);
    setTree(up(tree));
  };
  React.useEffect(() => {
    const k = (e) => {
      if (e.key === "Enter" && sel) { const r = zkFlatten(tree, 0, true).find((x) => x.node.id === sel); if (r && r.node.kind === "project") onOpen(r.node.id); }
      if (e.key === "Escape") onClose();
    };
    window.addEventListener("keydown", k); return () => window.removeEventListener("keydown", k);
  }, [sel, tree]);
  return (
    <Dialog title="Projects" onClose={onClose} width="min(900px, 92%)" height="min(640px, 88%)" activeNav="projects"
      navHeader={<div className="zk-brand"><NamiMark size={32} chip/><div><div className="zk-brand-n">Zanshin</div><div className="zk-brand-s">jj client · v0.24.0</div></div></div>}
      nav={[{ id: "projects", label: "Projects", icon: "folder-open" }, { id: "remotes", label: "Remotes", icon: "cloud" }, { id: "settings", label: "Settings", icon: "settings" }]}
      navFooter={<div className="zk-signed"><div className="zk-signed-l">Signed in</div><div className="zk-signed-u"><span className="zk-avatar">A</span><div><div>Alice Sralph</div><div className="zk-signed-m">alice@dasralph.de</div></div></div></div>}
      tools={<>
        <SearchField placeholder="Search projects, paths…" value={q} onChange={setQ} autoFocus style={{ flex: 1 }}/>
        <Button size="md" variant="primary" icon="plus" iconSize={12}>Add directory</Button>
        <Button size="md" icon="cloud">Clone from remote</Button>
        <Button size="md" variant="ghost" icon="folder-plus">New group</Button>
      </>}>
      <div className="zk-tree" role="tree">
        {!rows.length && <div className="zk-empty">No projects match “{q}”</div>}
        {rows.map(({ node, depth }) => node.kind === "group" ? (
          <ProjectRow key={node.id} kind="group" name={node.name} depth={depth} expanded={!!node.expanded || !!query} selected={sel === node.id}
            count={(node.children || []).filter((c) => c.kind === "project").length} groups={(node.children || []).filter((c) => c.kind === "group").length}
            onClick={() => { setSel(node.id); toggle(node.id); }}/>
        ) : (
          <ProjectRow key={node.id} {...node} kind="project" depth={depth} open={node.id === activeId} selected={sel === node.id}
            onClick={() => setSel(node.id)} onDoubleClick={() => node.status !== "missing" && onOpen(node.id)}/>
        ))}
      </div>
    </Dialog>
  );
}

function ZKSettings({ tab, setTab, onClose, prefs, setPref, project }) {
  const [g, setG] = React.useState({ name: "Ralph Stein", email: "ralph@dasralph.de" });
  const [p, setP] = React.useState({ fetch: "origin", push: "origin", auto: "15", trunk: "main", immutable: "builtin_immutable_heads()", own: false, email: "ralph@work.example" });
  const setp = (k, v) => setP((o) => ({ ...o, [k]: v }));
  React.useEffect(() => {
    const k = (e) => { if (e.key === "Escape") { e.stopPropagation(); onClose(); } };
    window.addEventListener("keydown", k, true); return () => window.removeEventListener("keydown", k, true);
  }, []);
  return (
    <div className="zs-scrim zk-set-ov" onMouseDown={(e) => { if (e.target === e.currentTarget) onClose(); }}>
      <div className="zk-set" role="dialog" aria-label="Settings">
        <header className="zk-set-hd">
          <Segmented variant="tabs" label="Scope" value={tab} onChange={setTab} options={[{ value: "general", label: "General", icon: "settings" }, { value: "project", label: project.name, icon: <span className="zk-set-mark"><NamiMark size={14}/></span> }]}/>
          <IconButton className="zk-set-x" icon="close" iconSize={12} size="sm" label="Close" title="Close (Esc)" onClick={onClose}/>
        </header>
        <div className="zk-set-scope">
          {tab === "general" ? <>For Zanshin on this Mac · jj settings go to <code>~/.config/jj/config.toml</code></> : <>For {project.name} only · <code>{project.path}/.jj/repo/config.toml</code></>}
        </div>
        <div className="zk-set-bd">
          {tab === "general" ? <>
            <SettingsGroup title="Appearance">
              <SettingsRow label="Theme"><Segmented variant="inset" label="Theme" value={prefs.theme} onChange={(v) => setPref("theme", v)} options={[{ value: "light", label: "Light", icon: "sun" }, { value: "dark", label: "Dark", icon: "moon" }, { value: "system", label: "Auto", icon: "auto" }]}/></SettingsRow>
              <SettingsRow label="Density"><Segmented variant="inset" label="Density" value={prefs.density} onChange={(v) => setPref("density", v)} options={[{ value: "compact", label: "Compact" }, { value: "balanced", label: "Balanced" }, { value: "comfy", label: "Comfy" }]}/></SettingsRow>
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
          </> : <>
            <SettingsGroup title="Remotes">
              <SettingsRow label="Fetch from" configKey="git.fetch"><Select label="Fetch from" value={p.fetch} onChange={(v) => setp("fetch", v)} options={["origin", "upstream"]}/></SettingsRow>
              <SettingsRow label="Push to" configKey="git.push"><Select label="Push to" value={p.push} onChange={(v) => setp("push", v)} options={["origin", "upstream"]}/></SettingsRow>
              <SettingsRow label="Fetch automatically"><Segmented variant="inset" label="Fetch automatically" value={p.auto} onChange={(v) => setp("auto", v)} options={[{ value: "off", label: "Off" }, { value: "5", label: "5 min" }, { value: "15", label: "15 min" }]}/></SettingsRow>
            </SettingsGroup>
            <SettingsGroup title="History">
              <SettingsRow label="Trunk" configKey={'revset-aliases."trunk()"'}><Select label="Trunk" value={p.trunk} onChange={(v) => setp("trunk", v)} options={["main", "develop", "release/1.5.x@origin"]}/></SettingsRow>
              <SettingsRow label="Immutable heads" hint="Changes at or below these can’t be rewritten." configKey={'revset-aliases."immutable_heads()"'} stack>
                <TextField mono value={p.immutable} onChange={(e) => setp("immutable", e.target.value)} spellCheck={false} aria-label="Immutable heads revset"/>
              </SettingsRow>
            </SettingsGroup>
            <SettingsGroup title="Identity">
              <SettingsRow label="Use a different email here" hint="For work repositories with their own address."><Switch label="Use a different email" checked={p.own} onChange={(v) => setp("own", v)}/></SettingsRow>
              {p.own && <SettingsRow label="Email" configKey="user.email"><TextField value={p.email} onChange={(e) => setp("email", e.target.value)} aria-label="Project email"/></SettingsRow>}
            </SettingsGroup>
          </>}
        </div>
        <footer className="zk-set-ft">How the graph looks lives with the graph: <b>View options</b> in the toolbar.</footer>
      </div>
    </div>
  );
}

Object.assign(window, { ZKProjects, ZKSettings, zkFlatten });
})();
