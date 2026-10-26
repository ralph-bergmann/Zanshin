/* global React */
// SETTINGS — three scopes, three places. Graph view lives at the graph (View popover). Project and General are
// set-and-forget, so they share one window with a tab per scope, reached from the project capsule or ⌘,.
(() => {
const { useState, useEffect, useMemo, useRef } = React;
const Ic = (p) => <window.Icon {...p}/>;

function useLocal(key, init) {
  const [v, setV] = useState(() => { try { const s = localStorage.getItem(key); return s == null ? init : { ...init, ...JSON.parse(s) }; } catch { return init; } });
  useEffect(() => { try { localStorage.setItem(key, JSON.stringify(v)); } catch {} }, [key, v]);
  return [v, (k, val) => setV(o => ({ ...o, [k]: val }))];
}
const AGE = (s) => { if (!s) return 1e9; if (/now|just/.test(s)) return 0; const m = s.match(/(\d+)\s*(h|d)/); if (m) return +m[1] * (m[2] === "h" ? 60 : 1440); if (/yesterday/.test(s)) return 1440; return 1e8; };

// ------------------------------------------------------------
// PROJECT MENU — the capsule names the place, so it holds everything about the place
// ------------------------------------------------------------
function ProjectMenu({ tree, activeId, onPick, onAll, onSettings, onClose }) {
  const ref = useRef(null);
  const recent = useMemo(() => window.flattenAll(tree).map(x => x.node).filter(n => n.kind === "project" && n.status !== "missing")
    .sort((a, b) => (a.id === activeId ? -1 : b.id === activeId ? 1 : AGE(a.lastOpened) - AGE(b.lastOpened))).slice(0, 5), [tree, activeId]);
  useEffect(() => {
    const down = (e) => { if (ref.current && !ref.current.contains(e.target) && !e.target.closest(".fl-proj")) onClose(); };
    const key = (e) => { if (e.key === "Escape") { e.stopPropagation(); onClose(); } };
    document.addEventListener("pointerdown", down, true); window.addEventListener("keydown", key, true);
    return () => { document.removeEventListener("pointerdown", down, true); window.removeEventListener("keydown", key, true); };
  }, []);
  return (
    <div className="gpm" ref={ref} role="menu" aria-label="Project">
      <div className="gpm-h">Recent</div>
      {recent.map(p => {
        const s = window.STATUS_META[p.status] || window.STATUS_META.clean;
        return (
          <button key={p.id} role="menuitemradio" aria-checked={p.id === activeId} className={"gpm-item" + (p.id === activeId ? " is-on" : "")} onClick={() => onPick(p)} title={p.path}>
            <span className="gpm-chk">{p.id === activeId && <Ic name="check" size={12}/>}</span>
            <span className="gpm-name">{p.name}</span>
            <span className="gpm-dot" style={{ background: s.color }} title={s.label}></span>
            <span className="gpm-sub">{p.branch}</span>
          </button>
        );
      })}
      <div className="gpm-sep"></div>
      <button className="gpm-item" role="menuitem" onClick={onAll}><span className="gpm-chk"></span><span className="gpm-name">All Projects…</span></button>
      <div className="gpm-sep"></div>
      <button className="gpm-item" role="menuitem" onClick={() => onSettings("project")}><span className="gpm-chk"></span><span className="gpm-name">Project Settings…</span></button>
      <button className="gpm-item" role="menuitem" onClick={() => onSettings("general")}><span className="gpm-chk"></span><span className="gpm-name">Settings…</span><kbd className="gpm-kbd">⌘,</kbd></button>
    </div>
  );
}

// ------------------------------------------------------------
// SETTINGS WINDOW
// ------------------------------------------------------------
const Seg = ({ value, onChange, opts, label }) => (
  <div className="gtb-seg" role="radiogroup" aria-label={label}>
    {opts.map(o => <button key={o.v} role="radio" aria-checked={value === o.v} className={value === o.v ? "on" : ""} onClick={() => onChange(o.v)}>{o.icon && <Ic name={o.icon} size={12}/>}{o.l}</button>)}
  </div>
);
const Switch = ({ on, set, label }) => <button role="switch" aria-checked={on} aria-label={label} className={"gtb-switch " + (on ? "on" : "")} onClick={() => set(!on)}></button>;
function Row({ label, hint, cfg, children, stack }) {
  return (
    <div className={"gset-row" + (stack ? " is-stack" : "")}>
      <div className="gset-lbl">
        <span>{label}</span>
        {hint && <span className="gset-hint">{hint}</span>}
        {cfg && <code className="gset-cfg">{cfg}</code>}
      </div>
      <div className="gset-ctl">{children}</div>
    </div>
  );
}
const Group = ({ title, children }) => <section className="gset-grp"><h3>{title}</h3><div className="gset-box">{children}</div></section>;

function GeneralPane({ t, setTweak }) {
  const [g, set] = useLocal("zanshin.settings.general", { name: "Ralph Stein", email: "ralph@dasralph.de" });
  return <>
    <Group title="Appearance">
      <Row label="Theme"><Seg value={t.theme} onChange={v => setTweak("theme", v)} label="Theme" opts={[{ v: "light", l: "Light", icon: "sun" }, { v: "dark", l: "Dark", icon: "moon" }, { v: "system", l: "Auto", icon: "auto" }]}/></Row>
      <Row label="Density"><Seg value={t.density} onChange={v => setTweak("density", v)} label="Density" opts={[{ v: "compact", l: "Compact" }, { v: "balanced", l: "Balanced" }, { v: "comfy", l: "Comfy" }]}/></Row>
    </Group>
    <Group title="While you scroll">
      <Row label="Hide controls" hint="Toolbars and panels step aside while you scroll the graph. The minimap stays."><Switch on={t.autoHide !== false} set={v => setTweak("autoHide", v)} label="Hide controls while scrolling"/></Row>
    </Group>
    <Group title="Diffs">
      <Row label="Layout"><Seg value={t.diffMode === "split" ? "split" : "inline"} onChange={v => setTweak("diffMode", v)} label="Diff layout" opts={[{ v: "inline", l: "Unified" }, { v: "split", l: "Side by side" }]}/></Row>
    </Group>
    <Group title="Identity">
      <Row label="Name" cfg="user.name"><input className="gset-in" value={g.name} onChange={e => set("name", e.target.value)} aria-label="Name"/></Row>
      <Row label="Email" cfg="user.email"><input className="gset-in" value={g.email} onChange={e => set("email", e.target.value)} aria-label="Email"/></Row>
    </Group>
  </>;
}

// Immutable commits has a page of its own (immutable.jsx); this row leads there
function ImmutableNav({ onOpen }) {
  const c = window.useImmutable();
  const n = useMemo(() => window.immutableCount(window.GRAPH_COMMITS || [], c), [c]);
  return (
    <button className="gset-row gset-nav" onClick={onOpen}>
      <div className="gset-lbl"><span>Immutable commits</span><span className="gset-hint">{window.immutableSummary(c)}</span><code className="gset-cfg">{'revset-aliases."immutable_heads()"'}</code></div>
      <div className="gset-ctl"><span className="gset-count" title={n + " immutable changes"}><span className="ghatch"></span>{n}</span><Ic name="chevronRight" size={12}/></div>
    </button>
  );
}

function ProjectPane({ project, onPage }) {
  const [p, set] = useLocal("zanshin.settings.project." + (project ? project.id : "_"), { fetch: "origin", push: "origin", auto: "15", trunk: "main", immutable: "builtin_immutable_heads()", own: false, email: "ralph@work.example" });
  const remotes = ["origin", "upstream"];
  const imm = window.useImmutable ? window.useImmutable() : null;   // trunk() and immutable_heads() live in immutable.jsx where it is loaded
  return <>
    <Group title="Remotes">
      <Row label="Fetch from" cfg="git.fetch"><select className="gset-sel" value={p.fetch} onChange={e => set("fetch", e.target.value)}>{remotes.map(r => <option key={r}>{r}</option>)}</select></Row>
      <Row label="Push to" cfg="git.push"><select className="gset-sel" value={p.push} onChange={e => set("push", e.target.value)}>{remotes.map(r => <option key={r}>{r}</option>)}</select></Row>
      <Row label="Fetch automatically"><Seg value={p.auto} onChange={v => set("auto", v)} label="Fetch automatically" opts={[{ v: "off", l: "Off" }, { v: "5", l: "5 min" }, { v: "15", l: "15 min" }]}/></Row>
    </Group>
    <Group title="History">
      <Row label="Trunk" cfg={'revset-aliases."trunk()"'}><select className="gset-sel" value={imm ? imm.trunkName : p.trunk} onChange={e => imm ? window.setImmutable({ trunkName: e.target.value }) : set("trunk", e.target.value)}>{["main", "develop", "release/1.5.x@origin"].map(r => <option key={r}>{r}</option>)}</select></Row>
      {imm && onPage ? <ImmutableNav onOpen={() => onPage("immutable")}/> : (
        <Row label="Immutable heads" hint="Changes at or below these can’t be rewritten." cfg={'revset-aliases."immutable_heads()"'} stack>
          <input className="gset-in is-code" value={p.immutable} onChange={e => set("immutable", e.target.value)} spellCheck={false} aria-label="Immutable heads revset"/>
        </Row>
      )}
    </Group>
    <Group title="Identity">
      <Row label="Use a different email here" hint="For work repositories with their own address."><Switch on={p.own} set={v => set("own", v)} label="Use a different email"/></Row>
      {p.own && <Row label="Email" cfg="user.email"><input className="gset-in" value={p.email} onChange={e => set("email", e.target.value)} aria-label="Project email"/></Row>}
    </Group>
  </>;
}

function SettingsWindow({ tab, setTab, onClose, t, setTweak, project }) {
  useEffect(() => {
    const k = (e) => { if (e.key === "Escape") { e.stopPropagation(); onClose(); } };
    window.addEventListener("keydown", k, true);
    return () => window.removeEventListener("keydown", k, true);
  }, []);
  const name = project ? project.name : "Project";
  return (
    <div className="gset-ov" onMouseDown={e => { if (e.target === e.currentTarget) onClose(); }}>
      <div className="gset" role="dialog" aria-label="Settings">
        <header className="gset-hd">
          <div className="gtb-seg gset-tabs" role="tablist" aria-label="Scope">
            <button role="tab" aria-selected={tab === "general"} className={tab === "general" ? "on" : ""} onClick={() => setTab("general")}><Ic name="settings" size={13}/>General</button>
            <button role="tab" aria-selected={tab === "project"} className={tab === "project" ? "on" : ""} onClick={() => setTab("project")}><span className="gset-mark"><window.ZanshinMark size={14}/></span>{name}</button>
          </div>
          <button className="bcd-close gset-x" onClick={onClose} aria-label="Close" title="Close (Esc)"><Ic name="close" size={12}/></button>
        </header>
        <div className="gset-scope">
          {tab === "general"
            ? <>For Zanshin on this Mac · jj settings go to <code>~/.config/jj/config.toml</code></>
            : <>For {name} only{project && project.path ? <> · <code>{project.path}/.jj/repo/config.toml</code></> : null}</>}
        </div>
        <div className="gset-bd">{tab === "general" ? <GeneralPane t={t} setTweak={setTweak}/> : <ProjectPane project={project}/>}</div>
        <footer className="gset-ft">How the graph looks lives with the graph: <b>View options</b> in the toolbar.</footer>
      </div>
    </div>
  );
}

// the panes also fill the Settings window of the floating client (windows.jsx); SettingsWindow stays for the studies
Object.assign(window, { ProjectMenu, SettingsWindow, GeneralPane, ProjectPane, SettingsKit: { Row, Group, Switch, Seg } });
})();
