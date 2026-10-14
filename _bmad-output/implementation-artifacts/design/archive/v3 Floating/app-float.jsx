/* global React, ReactDOM */
// App shell for "JJ Desktop Client Floating.html" — graph fills the window, all UI floats above it.
(() => {
const { useState, useEffect, useRef, useMemo } = React;

const TWEAK_DEFAULTS = /*EDITMODE-BEGIN*/{
  "theme": "system",
  "density": "compact",
  "diffMode": "inline",
  "showFiles": true,
  "bookmarkLabels": "legend",
  "addButtons": "menu",
  "laneOrder": "optimized",
  "crossings": "bridge",
  "hoverFocus": true,
  "gapMarker": "break",
  "gapCount": false,
  "railPos": "center",
  "material": "glass"
}/*EDITMODE-END*/;
const URLQ = new URLSearchParams(location.search);
const URL_TWEAKS = Object.fromEntries([["theme", URLQ.get("th") || URLQ.get("theme")]].filter(([, v]) => v != null));

const RAIL = [
  { id: "branches",   label: "Bookmarks",     icon: "branch" },
  { id: "workstream", label: "Workstreams",   icon: "workstream" },
  { id: "reviews",    label: "Reviews",       icon: "reviews" },
  { id: "undo",       label: "Undo Timeline", icon: "undo" },
];
const OPS = [
  { cmd: 'describe -m "wip: refactor"', when: "8 min ago" },
  { cmd: "new -A @", when: "12 min ago" },
  { cmd: "git fetch", when: "2h ago" },
];
// geometry shared with float.css
const EDGE = 12, TOP = 64, RAIL_R = 74, PANEL_W = 300, DETAIL_W = 460;

// ============================================================
// SETTINGS MENU — UI config moved out of the toolbar
// ============================================================
function SettingsMenu({ api, t, setTweak }) {
  const pct = ((api.cardW - 160) / (400 - 160)) * 100;
  const seg = (value, onChange, opts, label) => (
    <div className="gtb-seg" role="radiogroup" aria-label={label}>
      {opts.map(o => (
        <button key={o.v} role="radio" aria-checked={value === o.v} className={value === o.v ? "on" : ""} onClick={() => onChange(o.v)} title={o.title || o.l}>
          {o.icon && <Icon name={o.icon} size={12}/>}{o.l}
        </button>
      ))}
    </div>
  );
  const sw = (on, set) => <button role="switch" aria-checked={on} className={"gtb-switch " + (on ? "on" : "")} onClick={() => set(!on)}/>;
  return (
    <div className="fl-menu" role="dialog" aria-label="Settings">
      <div className="fl-menu-h">Appearance</div>
      <div className="fl-row"><span>Theme</span>{seg(t.theme, v => setTweak("theme", v), [{ v: "light", l: "Light", icon: "sun" }, { v: "dark", l: "Dark", icon: "moon" }, { v: "system", l: "Auto", icon: "auto", title: "Follow system" }], "Theme")}</div>
      <div className="fl-row"><span>Density</span>{seg(t.density, v => setTweak("density", v), [{ v: "compact", l: "Compact" }, { v: "balanced", l: "Balanced" }, { v: "comfy", l: "Comfy" }], "Density")}</div>
      <div className="fl-sep"/>
      <div className="fl-menu-h">Graph</div>
      <div className="fl-row"><span>Layout</span>{seg(api.layout, api.setLayout, [{ v: "compact", l: "Compact", title: "Rows = dependency depth" }, { v: "time", l: "Time", title: "Rows = rounded commit time" }], "Layout")}</div>
      <label className="fl-row"><span>Detailed cards</span>{sw(api.detailed, api.setDetailed)}</label>
      <label className="fl-row" title="Collapse linear runs of changes into one stack card"><span>Group stacks</span>{sw(api.stacks, api.setStacks)}</label>
      <div className="fl-row">
        <span>Card width</span>
        <span className="fl-range">
          <input type="range" className="gtb-range" min="160" max="400" step="10" value={api.cardW} style={{ "--p": pct + "%" }} onChange={(e) => api.setCardW(+e.target.value)} aria-label="Card width"/>
          <span className="gtb-val">{api.cardW}px</span>
        </span>
      </div>
    </div>
  );
}

// ============================================================
// FLOAT CHROME — everything that hovers over the graph
// ============================================================
function FloatChrome({ api, t, setTweak, pinned, setPinned, project, onOpenHome }) {
  const flRef = useRef(null), setRef = useRef(null);
  const openT = useRef(null), closeT = useRef(null);
  const [co, setCo] = useState(null);
  const [settings, setSettings] = useState(false);
  const clear = () => { clearTimeout(openT.current); clearTimeout(closeT.current); };
  useEffect(() => clear, []);

  const enter = (id, e) => {
    clear();
    if (pinned === id) { setCo(null); return; }
    const r = e.currentTarget.getBoundingClientRect(), o = flRef.current.getBoundingClientRect();
    const next = { id, top: r.top - o.top + r.height / 2, left: r.right - o.left + 14 };
    if (co) setCo(next); else openT.current = setTimeout(() => setCo(next), 90);
  };
  const leave = () => { clear(); closeT.current = setTimeout(() => setCo(null), 200); };
  const click = (id) => { clear(); setCo(null); setPinned(pinned === id ? null : id); };

  useEffect(() => {
    if (!settings) return;
    const down = (e) => { if (setRef.current && !setRef.current.contains(e.target)) setSettings(false); };
    const key = (e) => { if (e.key === "Escape") setSettings(false); };
    document.addEventListener("pointerdown", down);
    window.addEventListener("keydown", key);
    return () => { document.removeEventListener("pointerdown", down); window.removeEventListener("keydown", key); };
  }, [settings]);

  const bmCount = api.all.reduce((s, c) => s + c.bookmarks.length, 0);
  const status = project && window.STATUS_META[project.status];
  const coItem = co && RAIL.find(r => r.id === co.id);
  const preview = (id) => {
    if (id === "branches") return (
      <>
        <window.BookmarkList commits={api.all} visibleSet={api.visibleSet} limit={5} onPick={(cid) => { setCo(null); api.pickBookmark(cid); }}/>
        {bmCount > 5 && <div className="fl-co-more">+{bmCount - 5} more</div>}
      </>
    );
    if (id === "workstream") return <div className="fl-co-empty">No workstreams yet. Create one with <code>jj workstream new</code>.</div>;
    if (id === "reviews") return <div className="fl-co-empty">No open reviews.</div>;
    return (
      <div className="fl-co-ops">
        {OPS.map(o => <div key={o.cmd} className="fl-co-op"><code>{o.cmd}</code><span>{o.when}</span></div>)}
      </div>
    );
  };
  const coCount = { branches: bmCount, undo: "142 ops" };

  return (
    <div className="fl" ref={flRef}>
      <div className="fl-top">
        <div className="fl-tl fl-glass">
          <div className="window-controls">
            <button className="win-ctrl win-close" aria-label="Close window"/>
            <button className="win-ctrl win-min" aria-label="Minimize"/>
            <button className="win-ctrl win-max" aria-label="Zoom"/>
          </div>
          <span className="fl-vsep"/>
          <button className="fl-proj" onClick={onOpenHome} title="Switch project">
            <window.ZanshinMark size={28}/>
            <span className="fl-proj-txt">
              <span className="fl-proj-name">
                {project ? project.name : "—"}
                {status && <span className="fl-dot" style={{ background: status.color }} title={status.label}/>}
              </span>
              {project && <span className="fl-proj-path">{project.path}</span>}
            </span>
            <Icon name="chevronDown" size={14}/>
          </button>
        </div>

        <div className="fl-tc fl-glass">
          <window.RevsetSelect value={api.revset} onChange={api.setRevset}/>
          <window.GapLegend {...api.gapInfo} onShowAll={() => api.setRevset("all")}/>
        </div>

        <div className="fl-tr">
          <div className="fl-group fl-glass">
            <button className="fl-ib" title="Fetch — jj git fetch" aria-label="Fetch"><Icon name="fetch" size={17}/></button>
            <button className="fl-ib" title="Push — jj git push" aria-label="Push"><Icon name="push" size={17}/></button>
          </div>
          <button className="fl-primary" title="jj new — start a new change on top of @"><Icon name="plus" size={15}/><span>New change</span></button>
          <div className="fl-set" ref={setRef}>
            <button className={"fl-ib fl-solo fl-glass " + (settings ? "on" : "")} onClick={() => setSettings(s => !s)} aria-expanded={settings} aria-label="Settings" title="Settings"><Icon name="settings" size={17}/></button>
            {settings && <SettingsMenu api={api} t={t} setTweak={setTweak}/>}
          </div>
        </div>
      </div>

      <nav className={"fl-rail fl-glass " + (t.railPos === "top" ? "at-top" : "")} aria-label="Panels">
        {RAIL.map(it => (
          <button key={it.id}
            className={"fl-rail-btn " + (pinned === it.id ? "on " : "") + (co && co.id === it.id ? "hov" : "")}
            onMouseEnter={(e) => enter(it.id, e)} onMouseLeave={leave} onClick={() => click(it.id)}
            aria-label={it.label} aria-pressed={pinned === it.id}>
            <Icon name={it.icon} size={19}/>
          </button>
        ))}
      </nav>

      {coItem && (
        <div className="fl-callout" style={{ top: co.top, left: co.left }} onMouseEnter={clear} onMouseLeave={leave} role="tooltip">
          <div className="fl-co-hd">
            <Icon name={coItem.icon} size={14}/>
            <span>{coItem.label}</span>
            {coCount[coItem.id] != null && <span className="fl-co-n">{coCount[coItem.id]}</span>}
          </div>
          <div className="fl-co-bd">{preview(coItem.id)}</div>
          <div className="fl-co-ft">Click the icon to keep it open</div>
        </div>
      )}

      {pinned && (
        <div className="fl-panel fl-glass" key={pinned}>
          {pinned === "branches"
            ? <window.SidePanel title="Bookmarks" icon="branch" onClose={() => setPinned(null)}><window.BookmarkList commits={api.all} visibleSet={api.visibleSet} onPick={api.pickBookmark}/></window.SidePanel>
            : <window.LeftPanel kind={pinned} onClose={() => setPinned(null)}/>}
        </div>
      )}

      <div className="fl-br fl-glass" style={{ right: api.detailOpen ? EDGE + DETAIL_W + 12 : EDGE }}>
        <span className="fl-count"><b>{api.shown}</b> / {api.total} commits</span>
        <span className="fl-vsep"/>
        <button className="fl-locate" onClick={api.onLocate} title="Scroll to working copy"><b>@</b>Working copy</button>
      </div>
    </div>
  );
}

// ============================================================
// APP
// ============================================================
function FloatApp() {
  const [t, setTweak] = useTweaks({ ...TWEAK_DEFAULTS, ...URL_TWEAKS });
  const [homeTree, setHomeTree] = useState(() => window.HOME_TREE);
  const [homeOpen, setHomeOpen] = useState(!URLQ.has("embed"));
  const [activeProjectId, setActiveProjectId] = useState(window.ACTIVE_PROJECT_ID || "p_myapp");
  const [pinned, setPinned] = useState(null);

  useEffect(() => {
    if (t.theme === "system") {
      const mql = window.matchMedia("(prefers-color-scheme: dark)");
      const apply = () => { document.documentElement.dataset.theme = mql.matches ? "dark" : "light"; };
      apply();
      mql.addEventListener("change", apply);
      return () => mql.removeEventListener("change", apply);
    }
    document.documentElement.dataset.theme = t.theme;
  }, [t.theme]);
  useEffect(() => { document.documentElement.dataset.density = t.density; }, [t.density]);
  useEffect(() => { document.documentElement.dataset.material = t.material; }, [t.material]);

  const project = useMemo(() => (flattenAll(homeTree).find(x => x.node.id === activeProjectId) || {}).node || null, [homeTree, activeProjectId]);
  const insets = { left: pinned ? RAIL_R + PANEL_W + EDGE : RAIL_R, right: EDGE, top: TOP, bottom: EDGE, detail: DETAIL_W + EDGE };

  return (
    <div className="fwin">
      <window.GraphWorkspace t={t} setTweak={setTweak} floating floatInsets={insets}
        chrome={(api) => <FloatChrome api={api} t={t} setTweak={setTweak} pinned={pinned} setPinned={setPinned} project={project} onOpenHome={() => setHomeOpen(true)}/>}/>

      <TweaksPanel title="Tweaks">
        <TweakSection label="Floating UI"/>
        <TweakRadio label="Nav rail" value={t.railPos} onChange={v => setTweak("railPos", v)}
          options={[{ value: "center", label: "Centered" }, { value: "top", label: "Top" }]}/>
        <TweakRadio label="Material" value={t.material} onChange={v => setTweak("material", v)}
          options={[{ value: "glass", label: "Glass" }, { value: "solid", label: "Solid" }]}/>
        <TweakSection label="Graph"/>
        <TweakRadio label="Bookmark labels" value={t.bookmarkLabels} onChange={v => setTweak("bookmarkLabels", v)}
          options={[{ value: "legend", label: "Always" }, { value: "hover", label: "On hover" }]}/>
        <TweakSelect label="New change" value={t.addButtons} onChange={v => setTweak("addButtons", v)}
          options={[{ value: "menu", label: "More button — icon fan" }, { value: "edges", label: "+ on card edges" }, { value: "context", label: "Right-click only" }, { value: "both", label: "More button + right-click" }]}/>
        <TweakRadio label="Lane order" value={t.laneOrder} onChange={v => setTweak("laneOrder", v)}
          options={[{ value: "optimized", label: "Min. crossings" }, { value: "greedy", label: "Greedy" }]}/>
        <TweakRadio label="Crossings" value={t.crossings} onChange={v => setTweak("crossings", v)}
          options={[{ value: "bridge", label: "Bridge gap" }, { value: "plain", label: "Plain" }]}/>
        <TweakToggle label="Hover: focus path" value={t.hoverFocus} onChange={v => setTweak("hoverFocus", v)}/>
        <TweakSection label="Hidden history"/>
        <TweakRadio label="Gap marker" value={t.gapMarker} onChange={v => setTweak("gapMarker", v)}
          options={[{ value: "dots", label: "Dots" }, { value: "break", label: "Break" }, { value: "pill", label: "Pill" }]}/>
        <TweakToggle label="Show hidden count" value={t.gapCount} onChange={v => setTweak("gapCount", v)}/>
        <TweakSection label="Diff"/>
        <TweakRadio label="Default mode" value={t.diffMode} onChange={v => setTweak("diffMode", v)}
          options={[{ value: "inline", label: "Inline" }, { value: "split", label: "Split" }]}/>
        <TweakToggle label="Show changed files" value={t.showFiles} onChange={v => setTweak("showFiles", v)}/>
      </TweaksPanel>

      {homeOpen && (
        <HomeDialog tree={homeTree} setTree={setHomeTree} activeProjectId={activeProjectId}
          onOpenProject={(p) => { setActiveProjectId(p.id); setHomeOpen(false); }}
          onClose={() => setHomeOpen(false)} canClose={true}/>
      )}
    </div>
  );
}

ReactDOM.createRoot(document.getElementById("root")).render(<FloatApp/>);
})();
