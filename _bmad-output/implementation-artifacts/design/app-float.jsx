/* global React, ReactDOM */
// App shell for "JJ Desktop Client Floating.html" — graph fills the window, all UI floats above it.
// v4 design pass: the top bar reads Place · View · Action. Gold is reserved for @ and the one primary action;
// selection, focus and controls use the moon accent. UI that only matters sometimes (the @ locator) appears only then.
// VIEW is one search field (graph-search.jsx): scope · query · jj log variant. A search narrows the variant, which then reads "in …".
(() => {
const { useState, useEffect, useRef, useMemo } = React;

const TWEAK_DEFAULTS = /*EDITMODE-BEGIN*/{
  "theme": "system",
  "density": "compact",
  "diffMode": "inline",
  "autoHide": true
}/*EDITMODE-END*/;
// settled design decisions (formerly tweaks)
const FIXED = { hoverFocus: true, showFiles: true, bookmarkLabels: "legend", addButtons: "both", laneOrder: "optimized", crossings: "bridge", gapMarker: "break", gapCount: false };
const URLQ = new URLSearchParams(location.search);
const URL_TWEAKS = Object.fromEntries([["theme", URLQ.get("th") || URLQ.get("theme")]].filter(([, v]) => v != null));

const RAIL = [
  { id: "branches",   label: "Bookmarks",     icon: "branch" },
  { id: "reviews",    label: "Reviews",       icon: "reviews" },
  { id: "undo",       label: "Undo Timeline", icon: "undo" },
];
const OPS = [
  { cmd: 'describe -m "wip: refactor"', when: "8 min ago" },
  { cmd: "new -A @", when: "12 min ago" },
  { cmd: "git fetch", when: "2h ago" },
];
// geometry shared with float.css — one 12px rhythm: traffic lights + rail form the left column (12→64), content starts at 76
const EDGE = 12, TOP = 68, RAIL_R = 76, PANEL_W = 300, DETAIL_W = 460, MINI = 146;

const VIEW_ICON = (
  <svg width="17" height="17" viewBox="0 0 16 16" style={{ flexShrink: 0 }} aria-hidden="true">
    <g stroke="currentColor" strokeWidth="1.4" fill="none" strokeLinecap="round">
      <path d="M2.5 5h1.6M7.9 5h5.6M2.5 11h6.1M12.4 11h1.1"/>
      <circle cx="6" cy="5" r="1.9"/><circle cx="10.5" cy="11" r="1.9"/>
    </g>
  </svg>
);

// the @ locator points to where the working copy is — an arrow means "there", a chevron would mean "opens"
const ARROW = <svg width="14" height="14" viewBox="0 0 16 16" aria-hidden="true"><path d="M8 13V3.5M4 7.5l4-4 4 4" stroke="currentColor" strokeWidth="1.6" fill="none" strokeLinecap="round" strokeLinejoin="round"/></svg>;

// ============================================================
// VIEW MENU — Graph view settings: how the graph is shown (sits next to the revset, which decides what is shown).
// App-wide appearance lives in Settings (General).
// ============================================================
function ViewMenu({ api, t, setTweak, onOpenSettings }) {
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
  const sw = (on, set) => <button role="switch" aria-checked={on} className={"gtb-switch " + (on ? "on" : "")} onClick={() => set(!on)}></button>;
  return (
    <div className="fl-menu" role="dialog" aria-label="View options">
      <div className="fl-menu-h">Graph view</div>
      <div className="fl-row"><span>Layout</span>{seg(api.layout, api.setLayout, [{ v: "free", l: "Free", title: "Rows follow commit time" }, { v: "compact", l: "Compact", title: "Rows = dependency depth" }], "Layout")}</div>
      <label className="fl-row"><span>Detailed cards</span>{sw(api.detailed, api.setDetailed)}</label>
      <label className="fl-row" title="Collapse linear runs of changes into one stack card"><span>Group stacks</span>{sw(api.stacks, api.setStacks)}</label>
      <div className="fl-row">
        <span>Card width</span>
        <span className="fl-range">
          <input type="range" className="gtb-range" min="160" max="400" step="10" value={api.cardW} style={{ "--p": pct + "%" }} onChange={(e) => api.setCardW(+e.target.value)} aria-label="Card width"/>
          <span className="gtb-val">{api.cardW}px</span>
        </span>
      </div>
      <div className="fl-sep"></div>
      <button className="fl-row fl-row-link" onClick={onOpenSettings}><span>Appearance, diffs and more</span><span className="fl-row-k">Settings… <kbd>⌘,</kbd></span></button>
    </div>
  );
}

// ============================================================
// FLOAT CHROME — everything that hovers over the graph
// ============================================================
function FloatChrome({ api, t, setTweak, pinned, setPinned, project, onOpenProjects, insets, tree, activeProjectId, onPickProject, onOpenSettings, isKey }) {
  const flRef = useRef(null), viewRef = useRef(null);
  const openT = useRef(null), closeT = useRef(null);
  const [co, setCo] = useState(null);
  const [view, setView] = useState(false);
  const [pm, setPm] = useState(false);
  const lastDir = useRef("down");
  if (api.wcDir) lastDir.current = api.wcDir;
  const clear = () => { clearTimeout(openT.current); clearTimeout(closeT.current); };
  useEffect(() => clear, []);

  // Push… opens the sheet (push-dialog.jsx) instead of pushing — also ⇧⌘P while this window is key. ?push opens it on load
  // (?push=network|auth|stale: with that error). The default remote is Settings › Project › Push to (git.push).
  const [push, setPush] = useState(null);
  const openPush = (error = null) => setPush({ plan: window.pushPlan(api.all, api.wcId), error, n: Date.now() });
  const pushFns = useRef(null); pushFns.current = { openPush, isKey };
  useEffect(() => {
    const q = URLQ.get("push");
    if (q != null) openPush(["network", "auth", "stale"].includes(q) ? { kind: q } : null);
    const k = (e) => { if ((e.metaKey || e.ctrlKey) && e.shiftKey && e.key.toLowerCase() === "p" && pushFns.current.isKey) { e.preventDefault(); pushFns.current.openPush(); } };
    window.addEventListener("keydown", k);
    return () => window.removeEventListener("keydown", k);
  }, []);
  const pushRemote = () => { try { return JSON.parse(localStorage.getItem("zanshin.settings.project." + (project ? project.id : "_")) || "{}").push || "origin"; } catch { return "origin"; } };

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
    if (!view) return;
    const down = (e) => { if (viewRef.current && !viewRef.current.contains(e.target)) setView(false); };
    const key = (e) => { if (e.key === "Escape") setView(false); };
    document.addEventListener("pointerdown", down);
    window.addEventListener("keydown", key);
    return () => { document.removeEventListener("pointerdown", down); window.removeEventListener("keydown", key); };
  }, [view]);

  const bmCount = api.all.reduce((s, c) => s + c.bookmarks.length, 0);
  const status = project && window.STATUS_META[project.status];
  const coItem = co && RAIL.find(r => r.id === co.id);
  const preview = (id) => {
    if (id === "branches") return (
      <>
        <window.BookmarkList commits={api.all} visibleSet={api.visibleSet} limit={5} onPick={(cid) => { setCo(null); api.pickBookmark(cid); }} onBeginDrag={api.beginDrag}/>
        {bmCount > 5 && <div className="fl-co-more">+{bmCount - 5} more</div>}
      </>
    );
    if (id === "reviews") return <div className="fl-co-empty">No open reviews.</div>;
    return (
      <div className="fl-co-ops">
        {OPS.map(o => <div key={o.cmd} className="fl-co-op"><code>{o.cmd}</code><span>{o.when}</span></div>)}
      </div>
    );
  };
  const coCount = { branches: bmCount, undo: "142 ops" };
  const filtered = api.shown < api.total;
  // the @ locator centres itself over the part of the graph that is actually visible
  const atR = api.detailOpen ? DETAIL_W + EDGE * 2 : MINI + EDGE;

  return (
    <div className="fl" ref={flRef}>
      <div className="fl-top">
        {/* PLACE — the window, and which repository it shows */}
        <div className="fl-tl">
          <window.TrafficLights className="fl-traffic"/>
          <div className="fl-pm">
            <button className={"fl-proj fl-glass" + (pm ? " on" : "")} onClick={() => setPm(o => !o)} aria-haspopup="menu" aria-expanded={pm} title={project ? project.path : "Projects"}>
              <span className="fl-proj-mark"><window.ZanshinMark size={28}/></span>
              <span className="fl-proj-name">{project ? project.name : "—"}</span>
              {status && <span className="fl-dot" style={{ background: status.color }} title={status.label}></span>}
              <Icon name="chevronDown" size={14}/>
            </button>
            {pm && <window.ProjectMenu tree={tree} activeId={activeProjectId} onClose={() => setPm(false)}
              onPick={(p) => { setPm(false); onPickProject(p); }} onAll={() => { setPm(false); onOpenProjects(); }} onSettings={(tab) => { setPm(false); onOpenSettings(tab); }}/>}
          </div>
        </div>

        {/* VIEW — find and what is shown (the search field and its one menu), and how (view options) */}
        <div className="fl-tc fl-glass">
          <window.GraphSearch api={api}/>
          <window.GapLegend {...api.gapInfo} onShowAll={() => api.setRevset("all")}/>
          <span className="fl-n" title={`${api.shown} of ${api.total} changes shown`}>
            {filtered ? <><b>{api.shown}</b> of {api.total}</> : <><b>{api.total}</b> changes</>}
          </span>
          <span className="fl-vsep"></span>
          <div className="fl-set" ref={viewRef}>
            <button className={"fl-ib " + (view ? "on" : "")} onClick={() => setView(s => !s)} aria-expanded={view} aria-label="View options" title="View options">{VIEW_ICON}</button>
            {view && <ViewMenu api={api} t={t} setTweak={setTweak} onOpenSettings={() => { setView(false); onOpenSettings("general"); }}/>}
          </div>
        </div>

        {/* ACTION — sync, and the one thing you do most */}
        <div className="fl-tr">
          <div className="fl-group fl-glass">
            <button className="fl-ib" title="Fetch — jj git fetch" aria-label="Fetch"><Icon name="fetch" size={17}/></button>
            <button className="fl-ib" title="Push… — choose what jj git push sends" aria-label="Push…" aria-haspopup="dialog" onClick={() => openPush()}><Icon name="push" size={17}/></button>
          </div>
          <button className="fl-primary" onClick={() => api.newChange()} title="jj new — start a new change on top of @"><Icon name="plus" size={15}/><span>New change</span></button>
        </div>
      </div>

      <nav className="fl-rail fl-glass" aria-label="Panels">
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
        </div>
      )}

      {pinned && (
        <div className="fl-panel fl-glass" key={pinned}>
          {pinned === "branches"
            ? <window.SidePanel title="Bookmarks" icon="branch" onClose={() => setPinned(null)}><window.BookmarkList commits={api.all} visibleSet={api.visibleSet} onPick={api.pickBookmark} onBeginDrag={api.beginDrag}/></window.SidePanel>
            : <window.LeftPanel kind={pinned} onClose={() => setPinned(null)}/>}
        </div>
      )}

      <button className={"fl-at fl-glass dir-" + lastDir.current + (api.wcDir && !api.toastOn ? " is-on" : "")}
        style={{ left: `calc((${insets.left}px + 100% - ${atR}px) / 2)` }}
        onClick={api.onLocate} tabIndex={api.wcDir ? 0 : -1} aria-hidden={!api.wcDir} title="Scroll to the working copy">
        <span className="gat">@</span><span>Working copy</span>{ARROW}
      </button>
      {push && ReactDOM.createPortal(
        <window.PushDialog key={push.n} plan={push.plan} remotes={["origin", "upstream"]} defaultRemote={pushRemote()} error={push.error}
          onCancel={() => setPush(null)} onDone={(r) => { setPush(null); api.push(r); }}/>,
        (flRef.current && flRef.current.closest(".fwin")) || document.body)}
    </div>
  );
}

// ============================================================
// APP — the project window, and above it the windows of their own (windows.jsx): Projects (All Projects… ⇧⌘O) and Settings (⌘,).
// `stack` is the window order, front first; its head is the key window, the others are inactive. ⌘W closes the key window
// (where the browser lets it — the red button always does).
// ============================================================
const TAB_KEY = "zanshin.settings.tab";
function FloatApp() {
  const [tw, setTweak] = useTweaks({ ...TWEAK_DEFAULTS, ...URL_TWEAKS });
  const t = { ...tw, ...FIXED };
  const [homeTree, setHomeTree] = useState(() => window.HOME_TREE);
  const [activeProjectId, setActiveProjectId] = useState(window.ACTIVE_PROJECT_ID || "p_myapp");
  const [pinned, setPinned] = useState(null);
  // Projects opens on load (?embed: not) · ?settings=general|project opens Settings too
  const [wins, setWins] = useState(() => {
    const o = {};
    if (!URLQ.has("embed")) o.projects = window.placeWindow("projects", o);
    if (URLQ.has("settings")) o.settings = window.placeWindow("settings", o);
    return o;
  });
  const [stack, setStack] = useState(() => [...(URLQ.has("settings") ? ["settings"] : []), ...(URLQ.has("embed") ? [] : ["projects"]), "project"]);
  const key = stack[0];
  const [tab, setTabState] = useState(() => { const q = URLQ.get("settings"); if (q === "general" || q === "project") return q; try { return localStorage.getItem(TAB_KEY) || "general"; } catch { return "general"; } });
  const setTab = (v) => { setTabState(v); try { localStorage.setItem(TAB_KEY, v); } catch {} };
  const front = (w) => setStack(s => s[0] === w ? s : [w, ...s.filter(x => x !== w)]);
  const openWin = (w) => { setWins(o => o[w] ? o : { ...o, [w]: window.placeWindow(w, o) }); front(w); };
  const closeWin = (w) => { setWins(o => { const n = { ...o }; delete n[w]; return n; }); setStack(s => s.filter(x => x !== w)); };
  const setGeo = (w) => (g) => setWins(o => o[w] ? { ...o, [w]: g } : o);
  const zoom = (w) => setWins(o => {
    const g = o[w]; if (!g) return o;
    return { ...o, [w]: g.zoomed ? { ...g.zoomed, zoomed: null } : { x: 12, y: 12, w: window.innerWidth - 24, h: window.innerHeight - 24, zoomed: g } };
  });
  const zOf = (w) => 10 - stack.filter(x => x !== "project").indexOf(w);
  // "Settings…" and "Appearance, diffs and more" → General · "Project Settings…" → Project · ⌘, → the tab shown last, never switched
  const openSettings = (which) => { if (which === "general" || which === "project") setTab(which); openWin("settings"); };
  const fns = useRef(null); fns.current = { openSettings, openWin, closeWin, key };
  useEffect(() => {
    const k = (e) => {
      if (!(e.metaKey || e.ctrlKey) || e.altKey) return;
      const c = e.key.toLowerCase(), f = fns.current;
      if (c === "," && !e.shiftKey) { e.preventDefault(); e.stopPropagation(); f.openSettings(); }
      else if (c === "o" && e.shiftKey) { e.preventDefault(); e.stopPropagation(); f.openWin("projects"); }
      else if (c === "w" && !e.shiftKey && f.key !== "project") { e.preventDefault(); e.stopPropagation(); f.closeWin(f.key); }
    };
    const r = () => setWins(o => Object.fromEntries(Object.entries(o).map(([w, g]) => [w, window.clampWindow(g)])));
    window.addEventListener("keydown", k, true); window.addEventListener("resize", r);
    return () => { window.removeEventListener("keydown", k, true); window.removeEventListener("resize", r); };
  }, []);

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

  const project = useMemo(() => (flattenAll(homeTree).find(x => x.node.id === activeProjectId) || {}).node || null, [homeTree, activeProjectId]);
  const insets = { left: pinned ? RAIL_R + PANEL_W + EDGE : RAIL_R, right: EDGE, top: TOP, bottom: EDGE, detail: DETAIL_W + EDGE };

  return (
    <>
      <div className="fwin" data-window={key === "project" ? undefined : "inactive"} onPointerDownCapture={() => front("project")}>
        <window.GraphWorkspace t={t} setTweak={setTweak} floating floatInsets={insets}
          chrome={(api) => <FloatChrome api={api} t={t} setTweak={setTweak} pinned={pinned} setPinned={setPinned} project={project} insets={insets} isKey={key === "project"}
            onOpenProjects={() => openWin("projects")} tree={homeTree} activeProjectId={activeProjectId} onPickProject={(p) => setActiveProjectId(p.id)} onOpenSettings={openSettings}/>}/>
      </div>
      <div className="zwl">
        {wins.projects && <window.ProjectsWin tree={homeTree} setTree={setHomeTree} activeProjectId={activeProjectId} active={key === "projects"} z={zOf("projects")}
          geo={wins.projects} setGeo={setGeo("projects")} onActivate={() => front("projects")} onClose={() => closeWin("projects")} onZoom={() => zoom("projects")}
          onSettings={() => openSettings("general")} onOpenProject={(p) => { setActiveProjectId(p.id); closeWin("projects"); front("project"); }}/>}
        {wins.settings && <window.SettingsWin tab={tab} setTab={setTab} project={project} t={t} setTweak={setTweak} active={key === "settings"} z={zOf("settings")}
          geo={wins.settings} setGeo={setGeo("settings")} onActivate={() => front("settings")} onClose={() => closeWin("settings")}/>}
      </div>
    </>
  );
}

ReactDOM.createRoot(document.getElementById("root")).render(<FloatApp/>);
})();
