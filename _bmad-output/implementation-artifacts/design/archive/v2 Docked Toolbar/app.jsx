/* global React, ReactDOM */
const { useState, useEffect, useRef, useMemo, useCallback } = React;

// ============================================================
// TWEAK DEFAULTS
// ============================================================
const TWEAK_DEFAULTS = /*EDITMODE-BEGIN*/{
  "theme": "system",
  "diffMode": "inline",
  "density": "compact",
  "showFiles": true,
  "bookmarkLabels": "legend",
  "addButtons": "menu",
  "laneOrder": "optimized",
  "crossings": "bridge",
  "hoverFocus": true,
  "gapMarker": "break",
  "gapCount": false
}/*EDITMODE-END*/;
const URLQ = new URLSearchParams(location.search);
const URL_TWEAKS = Object.fromEntries([["theme", URLQ.get("th") || URLQ.get("theme")], ["gapMarker", URLQ.get("gap")], ["gapCount", URLQ.has("count") ? URLQ.get("count") === "1" : null]].filter(([, v]) => v != null));

// ============================================================
// ICONS
// ============================================================
const I = {
  folder: <path d="M3 5.5h4.5l1.5 1.5h6V14H3V5.5z" stroke="currentColor" strokeWidth="1.4" fill="none" strokeLinejoin="round"/>,
  branch: <g stroke="currentColor" strokeWidth="1.5" fill="none"><circle cx="4" cy="4" r="1.8"/><circle cx="4" cy="12" r="1.8"/><circle cx="12" cy="8" r="1.8"/><path d="M4 5.8v4.4M5.6 4q3 0 5 2.5"/></g>,
  workstream: <g stroke="currentColor" strokeWidth="1.4" fill="none"><circle cx="3.5" cy="4" r="1.5"/><circle cx="3.5" cy="12" r="1.5"/><circle cx="12.5" cy="4" r="1.5"/><circle cx="12.5" cy="12" r="1.5"/><path d="M3.5 5.5v5M12.5 5.5v5M5 4h6M5 12h6"/></g>,
  reviews: <g stroke="currentColor" strokeWidth="1.4" fill="none" strokeLinecap="round"><path d="M3 11.5V4a1 1 0 0 1 1-1h7l3 3v5.5a1 1 0 0 1-1 1H6L3 14v-2.5z"/></g>,
  history: <g stroke="currentColor" strokeWidth="1.4" fill="none" strokeLinecap="round"><circle cx="8" cy="8" r="5.5"/><path d="M8 4.5V8l2.2 2.2"/></g>,
  undo: <g stroke="currentColor" strokeWidth="1.4" fill="none" strokeLinecap="round"><path d="M3.5 6.5H10a3.5 3.5 0 1 1 0 7H6"/><path d="M5.5 4L3 6.5 5.5 9"/></g>,
  chevronDown: <path d="M4.5 6.5l3.5 3.5 3.5-3.5" stroke="currentColor" strokeWidth="1.5" fill="none" strokeLinecap="round" strokeLinejoin="round"/>,
  plus: <path d="M8 3v10M3 8h10" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round"/>,
  settings: <g stroke="currentColor" strokeWidth="1.3" fill="none"><circle cx="8" cy="8" r="2.2"/><path d="M8 1.5v1.6M8 12.9v1.6M14.5 8h-1.6M3.1 8H1.5M12.6 3.4l-1.1 1.1M4.5 11.5l-1.1 1.1M12.6 12.6l-1.1-1.1M4.5 4.5L3.4 3.4"/></g>,
  close: <path d="M3.5 3.5l9 9M12.5 3.5l-9 9" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round"/>,
  user: <g stroke="currentColor" strokeWidth="1.4" fill="none"><circle cx="8" cy="6" r="2.5"/><path d="M3 14c0-2.5 2.2-4.5 5-4.5s5 2 5 4.5"/></g>,
  calendar: <g stroke="currentColor" strokeWidth="1.4" fill="none"><rect x="2.5" y="3.5" width="11" height="10" rx="1"/><path d="M2.5 6.5h11M5.5 2v3M10.5 2v3"/></g>,
  hash: <g stroke="currentColor" strokeWidth="1.4" fill="none" strokeLinecap="round"><path d="M6 2l-1 12M11 2l-1 12M2.5 5.5h11M2 10.5h11"/></g>,
  arrowLeft: <path d="M9.5 4L5.5 8l4 4" stroke="currentColor" strokeWidth="1.5" fill="none" strokeLinecap="round" strokeLinejoin="round"/>,
  file: <path d="M4 2h5l3 3v9H4V2z" stroke="currentColor" strokeWidth="1.4" fill="none" strokeLinejoin="round"/>,
  fileText: <g stroke="currentColor" strokeWidth="1.3" fill="none" strokeLinejoin="round"><path d="M4 2h5l3 3v9H4V2z"/><path d="M9 2v3h3M6 8.5h4M6 11h3" strokeLinecap="round"/></g>,
  merge: <g stroke="currentColor" strokeWidth="1.4" fill="none" strokeLinecap="round"><path d="M5 3v6a3 3 0 0 0 3 3h3"/><circle cx="5" cy="3" r="1.5"/><circle cx="11" cy="12" r="1.5"/></g>,
  conflict: <g stroke="currentColor" strokeWidth="1.4" fill="none" strokeLinecap="round" strokeLinejoin="round"><path d="M8 1.5L1.5 13.5h13L8 1.5z"/><path d="M8 6v3.5M8 11v0.4"/></g>,
  splitInline: <g stroke="currentColor" strokeWidth="1.3" fill="none"><rect x="2" y="3" width="12" height="10" rx="1.2"/><path d="M2 8h12"/></g>,
  splitSide:   <g stroke="currentColor" strokeWidth="1.3" fill="none"><rect x="2" y="3" width="12" height="10" rx="1.2"/><path d="M8 3v10"/></g>,
  sun: <g stroke="currentColor" strokeWidth="1.5" fill="none" strokeLinecap="round"><circle cx="8" cy="8" r="2.8"/><path d="M8 1.5V3M8 13v1.5M14.5 8H13M3 8H1.5M12.4 3.6l-1.1 1.1M4.7 11.3l-1.1 1.1M12.4 12.4l-1.1-1.1M4.7 4.7L3.6 3.6"/></g>,
  moon: <path d="M12.5 8.5A5.5 5.5 0 1 1 7.5 3.5a4.5 4.5 0 0 0 5 5z" stroke="currentColor" strokeWidth="1.5" fill="none" strokeLinejoin="round"/>,
  auto: <g stroke="currentColor" strokeWidth="1.4" fill="none"><circle cx="8" cy="8" r="5.5"/><path d="M8 2.5v11" stroke="currentColor" strokeWidth="1.4"/><path d="M8 2.5a5.5 5.5 0 0 0 0 11" fill="currentColor" stroke="none"/></g>,
  fetch: <g stroke="currentColor" strokeWidth="1.4" fill="none" strokeLinecap="round"><path d="M8 2v8"/><path d="M5 7l3 3 3-3"/><path d="M3 13h10"/></g>,
  push:  <g stroke="currentColor" strokeWidth="1.4" fill="none" strokeLinecap="round"><path d="M8 13V5"/><path d="M5 8l3-3 3 3"/><path d="M3 2h10"/></g>,
  pull:  <g stroke="currentColor" strokeWidth="1.4" fill="none" strokeLinecap="round"><path d="M8 2v6"/><path d="M5 5l3 3 3-3"/><circle cx="8" cy="12" r="1.5"/></g>,
  grip:  <g fill="currentColor"><circle cx="6" cy="4" r="1.1"/><circle cx="10" cy="4" r="1.1"/><circle cx="6" cy="8" r="1.1"/><circle cx="10" cy="8" r="1.1"/><circle cx="6" cy="12" r="1.1"/><circle cx="10" cy="12" r="1.1"/></g>,
  home: <path d="M2.5 7.5L8 2.5l5.5 5M4 7v6.5h8V7" stroke="currentColor" strokeWidth="1.4" fill="none" strokeLinejoin="round" strokeLinecap="round"/>,
  chevronRight: <path d="M6 4l4 4-4 4" stroke="currentColor" strokeWidth="1.5" fill="none" strokeLinecap="round" strokeLinejoin="round"/>,
  search: <g stroke="currentColor" strokeWidth="1.5" fill="none" strokeLinecap="round"><circle cx="7" cy="7" r="4"/><path d="M10 10l3.5 3.5"/></g>,
  cloud: <path d="M4.5 12.5h7a2.5 2.5 0 0 0 .3-4.98A3.5 3.5 0 0 0 5 6.5 2.75 2.75 0 0 0 4.5 12.5z" stroke="currentColor" strokeWidth="1.3" fill="none" strokeLinejoin="round"/>,
  folderOpen: <path d="M2.5 13V5h4l1.5 1.5h5.5V8M2.5 13l1.8-5h11l-1.8 5h-11z" stroke="currentColor" strokeWidth="1.3" fill="none" strokeLinejoin="round" strokeLinecap="round"/>,
  folderPlus: <g stroke="currentColor" strokeWidth="1.3" fill="none" strokeLinejoin="round"><path d="M2.5 13V4.5h4L8 6h5.5V13H2.5z"/><path d="M8 8.5v3M6.5 10h3" strokeLinecap="round"/></g>,
  more: <g fill="currentColor"><circle cx="3.5" cy="8" r="1.1"/><circle cx="8" cy="8" r="1.1"/><circle cx="12.5" cy="8" r="1.1"/></g>,
  download: <g stroke="currentColor" strokeWidth="1.4" fill="none" strokeLinecap="round" strokeLinejoin="round"><path d="M8 2v8M5 7l3 3 3-3"/><path d="M3 13h10"/></g>,
  edit: <g stroke="currentColor" strokeWidth="1.4" fill="none" strokeLinecap="round" strokeLinejoin="round"><path d="M3 13l1-3 7-7 2 2-7 7-3 1z"/><path d="M10 3.5l2 2"/></g>,
  check: <path d="M3 8.5l3 3 7-7" stroke="currentColor" strokeWidth="1.6" fill="none" strokeLinecap="round" strokeLinejoin="round"/>,
};
const Icon = ({ name, size = 16, className = "", style = {} }) => (
  <svg width={size} height={size} viewBox="0 0 16 16" className={className} style={{ flexShrink: 0, ...style }}>
    {I[name]}
  </svg>
);

// ============================================================
// REVIEW STATE — per-commit "viewed" tracking, persisted to localStorage
// ============================================================
function useReviewState(changeId) {
  const key = "jj.reviewed." + (changeId || "_");
  const [state, setState] = useState(() => {
    try { return JSON.parse(localStorage.getItem(key) || "{}"); }
    catch { return {}; }
  });
  useEffect(() => {
    try { localStorage.setItem(key, JSON.stringify(state)); } catch {}
  }, [state, key]);
  const setViewed = useCallback((path, v) => {
    setState(s => ({ ...s, [path]: v }));
  }, []);
  const setMany = useCallback((paths, v) => {
    setState(s => {
      const next = { ...s };
      paths.forEach(p => { if (v) next[p] = true; else delete next[p]; });
      return next;
    });
  }, []);
  return [state, setViewed, setMany];
}

function softTint(hex, alpha = 0.12) {
  const h = hex.replace("#", "");
  const r = parseInt(h.substring(0,2), 16);
  const g = parseInt(h.substring(2,4), 16);
  const b = parseInt(h.substring(4,6), 16);
  return `rgba(${r}, ${g}, ${b}, ${alpha})`;
}

// Lane-Gradient: Hell-/Dunkelstop werden AUS der Lane-Farbe abgeleitet (kein Weiss-Schleier).
// Der Lift skaliert mit (1 - L), damit helle Basisfarben (Blau) nicht auswaschen.
// Doku + Dart-Port: docs/branch-header-gradient.md
function hexToHsl(hex) {
  const h = hex.replace("#", "");
  const r = parseInt(h.substring(0,2),16)/255, g = parseInt(h.substring(2,4),16)/255, b = parseInt(h.substring(4,6),16)/255;
  const max = Math.max(r,g,b), min = Math.min(r,g,b), d = max - min;
  let hue = 0;
  if (d) {
    if (max === r) hue = ((g - b) / d) % 6;
    else if (max === g) hue = (b - r) / d + 2;
    else hue = (r - g) / d + 4;
    hue *= 60; if (hue < 0) hue += 360;
  }
  const l = (max + min) / 2;
  const s = d ? d / (1 - Math.abs(2 * l - 1)) : 0;
  return { h: hue, s, l };
}
const clamp01 = v => Math.min(1, Math.max(0, v));
function laneShade(hex) {
  const { h, s, l } = hexToHsl(hex);
  // heller Stop oben links
  const lift = 0.17 * Math.pow(1 - l, 1.25);          // helle Basis -> kaum Lift
  const hiS  = clamp01(s * (0.90 + 0.14 * l));         // Saettigung halten, nicht neon
  // dunkler Stop unten rechts
  const drop = 0.09 + 0.07 * l;                        // helle Basis -> etwas mehr Tiefe
  const loS  = clamp01(s * 1.04);
  return {
    "--branch-hi": `hsl(${h.toFixed(1)} ${(hiS*100).toFixed(1)}% ${(clamp01(l + lift)*100).toFixed(1)}%)`,
    "--branch-lo": `hsl(${h.toFixed(1)} ${(loS*100).toFixed(1)}% ${(clamp01(l - drop)*100).toFixed(1)}%)`,
  };
}

// ============================================================
// WINDOW CHROME
// ============================================================
function WindowChrome({ children, theme, onSetTheme }) {
  return (
    <div className="window">
      <div className="window-header">
        <div className="window-header-left">
          <div className="window-controls">
            <button className="win-ctrl win-close"/>
            <button className="win-ctrl win-min"/>
            <button className="win-ctrl win-max"/>
          </div>
          <div className="window-title">JJ Client — myapp</div>
        </div>
        <div className="window-header-center">
          <button className="header-btn"><Icon name="fetch" size={13}/>Fetch</button>
          <button className="header-btn"><Icon name="pull" size={13}/>Pull</button>
          <button className="header-btn"><Icon name="push" size={13}/>Push</button>
          <div className="header-divider"/>
          <button className="header-btn"><Icon name="plus" size={13}/>New</button>
        </div>
        <div className="window-header-right">
          <ThemeSwitch value={theme} onChange={onSetTheme}/>
        </div>
      </div>
      <div className="window-body">{children}</div>
    </div>
  );
}

function ThemeSwitch({ value, onChange }) {
  return (
    <div className="theme-switch" role="radiogroup" aria-label="Theme">
      <button className={"theme-btn " + (value === "light" ? "active" : "")}  onClick={() => onChange("light")}  title="Light"><Icon name="sun"  size={14}/></button>
      <button className={"theme-btn " + (value === "dark"  ? "active" : "")} onClick={() => onChange("dark")}   title="Dark"><Icon name="moon" size={13}/></button>
      <button className={"theme-btn " + (value === "system"? "active" : "")} onClick={() => onChange("system")} title="System"><Icon name="auto" size={14}/></button>
    </div>
  );
}

// ============================================================
// FUNCTION RAIL — narrow icon rail with hover/click flyouts
// ============================================================
function FunctionRail({ active, onSet }) {
  const items = [
    { id: "branches",   label: "Branches",      icon: "branch" },
    { id: "workstream", label: "Workstreams",   icon: "workstream" },
    { id: "reviews",    label: "Reviews",       icon: "reviews" },
    { id: "undo",       label: "Undo Timeline", icon: "undo" },
  ];
  return (
    <nav className="function-rail">
      {items.map(it => (
        <button
          key={it.id}
          className={"fn-btn " + (active === it.id ? "active" : "")}
          title={it.label}
          onMouseEnter={() => onSet(it.id, "hover")}
          onClick={() => onSet(it.id, "click")}
        >
          <Icon name={it.icon} size={17}/>
        </button>
      ))}
      <div className="fn-rail-bottom">
        <button className="fn-btn" title="Settings"><Icon name="settings" size={16}/></button>
      </div>
    </nav>
  );
}

// ============================================================
// FLYOUT shells
// ============================================================
function Flyout({ top, onClose, children, onMouseEnter, onMouseLeave }) {
  return (
    <>
      <div className="flyout-backdrop" onClick={onClose}/>
      <div
        className="flyout"
        style={{ top }}
        onMouseEnter={onMouseEnter}
        onMouseLeave={onMouseLeave}
      >
        {children}
      </div>
    </>
  );
}

function BranchesFlyout({ openColumns, onToggle, onClose }) {
  const [q, setQ] = useState("");
  const matches = (n) => !q || n.toLowerCase().includes(q.toLowerCase());
  const local = window.BOOKMARKS.filter(b => matches(b.name));
  const remote = window.REMOTE_BRANCHES.filter(b => matches(b.name));

  return (
    <>
      <div className="flyout-header">
        <Icon name="branch" size={14}/>
        <h3>Branches</h3>
        <button className="pin" onClick={onClose} title="Close"><Icon name="close" size={11}/></button>
      </div>
      <div className="flyout-search">
        <input placeholder="Filter…" value={q} onChange={(e) => setQ(e.target.value)} autoFocus/>
      </div>
      <div className="flyout-body">
        <div className="flyout-section-h">
          <span>Local</span>
          <span className="count">{local.length}</span>
        </div>
        {local.length === 0 && <div className="flyout-empty">no match</div>}
        {local.map(b => {
          const color = window.BRANCH_COLORS[b.name] || "#3b82f6";
          const open = openColumns.includes(b.name);
          return (
            <div
              key={b.name}
              className={"flyout-row " + (open ? "open" : "")}
              style={{
                "--row-color": color,
                "--row-bg": softTint(color, 0.1),
              }}
              draggable
              onDragStart={(e) => e.dataTransfer.setData("text/plain", b.name)}
              onClick={() => onToggle(b.name)}
              title={open ? `Close ${b.name}` : `Open ${b.name}`}
            >
              <span className="dot"/>
              <span className="name">{b.name}{b.current && " @"}</span>
              <span className="meta">
                {b.ahead  > 0 && <span className="ahead">↑{b.ahead}</span>}
                {b.behind > 0 && <span className="behind">↓{b.behind}</span>}
              </span>
            </div>
          );
        })}

        <div className="flyout-section-h" style={{ marginTop: 6 }}>
          <span>Remote</span>
          <span className="count">{remote.length}</span>
        </div>
        {remote.length === 0 && <div className="flyout-empty">no match</div>}
        {remote.map(b => {
          const trackingColor = b.trackedBy ? window.BRANCH_COLORS[b.trackedBy] || "#6b7280" : "#6b7280";
          return (
            <div
              key={b.name}
              className="flyout-row"
              style={{ "--row-color": trackingColor }}
              title={b.trackedBy ? `Tracked by ${b.trackedBy}` : "Untracked remote"}
            >
              <span className="dot" style={{ opacity: b.trackedBy ? 1 : 0.4 }}/>
              <span className="name" style={{ opacity: b.trackedBy ? 1 : 0.7 }}>{b.name}</span>
              <span className="meta">
                {b.aheadOfLocal > 0 && <span className="ahead">↑{b.aheadOfLocal}</span>}
                {b.behindLocal > 0 && <span className="behind">↓{b.behindLocal}</span>}
              </span>
            </div>
          );
        })}
      </div>
    </>
  );
}

function PlaceholderFlyout({ title, onClose }) {
  return (
    <>
      <div className="flyout-header">
        <h3>{title}</h3>
        <button className="pin" onClick={onClose}><Icon name="close" size={11}/></button>
      </div>
      <div className="flyout-empty">Coming soon</div>
    </>
  );
}

// ============================================================
// NAV RAIL — VS Code-style activity bar
// ============================================================
function NavRail({ activePanel, onSelectPanel, onOpenHome, homeOpen, activeProjectName }) {
  const items = [
    { id: "history",    label: "Log",           icon: "history" },
    { id: "branches",   label: "Branches",      icon: "branch" },
    { id: "workstream", label: "Workstreams",   icon: "workstream" },
    { id: "reviews",    label: "Reviews",       icon: "reviews" },
    { id: "undo",       label: "Undo Timeline", icon: "undo" },
  ];
  return (
    <nav className="nav-rail" aria-label="Activity">
      <button
        className={"nav-activity nav-home " + (homeOpen ? "active" : "")}
        onClick={onOpenHome}
        title={`Projects — ${activeProjectName || ""}`}
        aria-label="Projects"
        aria-pressed={homeOpen}
      >
        <ZanshinMark size={26}/>
      </button>
      <div className="nav-divider"/>
      {items.map(it => (
        <button
          key={it.id}
          className={"nav-activity " + (activePanel === it.id ? "active" : "")}
          onClick={() => onSelectPanel(it.id)}
          title={it.label}
          aria-label={it.label}
          aria-pressed={activePanel === it.id}
        >
          <Icon name={it.icon} size={22}/>
        </button>
      ))}
      <div className="nav-bottom">
        <button className="nav-activity" title="Settings" aria-label="Settings"><Icon name="settings" size={20}/></button>
      </div>
    </nav>
  );
}

// ============================================================
// SIDEBAR
// ============================================================
function Sidebar({ openColumns, onToggle }) {
  const [activeNav, setActiveNav] = useState("branches");
  const items = [
    { id: "branches",   label: "Branches",     icon: "branch" },
    { id: "workstream", label: "Workstreams",  icon: "workstream" },
    { id: "reviews",    label: "Reviews",      icon: "reviews" },
    { id: "history",    label: "History",      icon: "history" },
    { id: "undo",       label: "Undo Timeline",icon: "undo" },
  ];
  return (
    <aside className="sidebar">
      <div className="sb-section">
        <div className="sb-section-label">Navigation</div>
        <div className="nav-list">
          {items.map(n => (
            <button key={n.id}
              className={"nav-list-item " + (activeNav === n.id ? "active" : "")}
              onClick={() => setActiveNav(n.id)}
            >
              <Icon name={n.icon} size={15}/><span>{n.label}</span>
            </button>
          ))}
        </div>
      </div>
      <div className="sb-section">
        <div className="sb-section-label">Active Branches</div>
        <div className="branch-pills">
          {window.BOOKMARKS.map(b => {
            const color = window.BRANCH_COLORS[b.name] || "#3b82f6";
            const open = openColumns.includes(b.name);
            return (
              <button key={b.name}
                className={"branch-pill " + (open ? "open" : "")}
                style={{
                  "--pill-bg":     softTint(color, 0.13),
                  "--pill-border": softTint(color, 0.35),
                  "--pill-fg":     color,
                }}
                onClick={() => onToggle(b.name)}
                title={open ? `Close ${b.name}` : `Open ${b.name}`}
              >
                <Icon name="branch" size={13} className="branch-pill-icon"/>
                <span className="branch-pill-name">{b.name}</span>
                {b.ahead  > 0 && <span className="branch-pill-meta">↑{b.ahead}</span>}
                {b.behind > 0 && <span className="branch-pill-meta">↓{b.behind}</span>}
              </button>
            );
          })}
        </div>
      </div>
    </aside>
  );
}

// ============================================================
// BRANCH HEADS — top of history, draggable for merge/rebase
// ============================================================
function BranchHeads() {
  const [dragging, setDragging] = useState(null);
  const [dropOn, setDropOn] = useState(null);

  // Only show branches that have a lane in the visible history graph
  const knownLanes = window.LANES.map(l => l.name);
  const heads = window.BOOKMARKS.filter(b => knownLanes.includes(b.name));

  const onDragStart = (e, name) => {
    e.dataTransfer.setData("text/plain", "head:" + name);
    e.dataTransfer.effectAllowed = "move";
    setDragging(name);
  };
  const onDragOver = (e, name) => {
    if (!dragging || dragging === name) return;
    e.preventDefault();
    e.dataTransfer.dropEffect = "move";
    setDropOn(name);
  };
  const onDragEnd = () => { setDragging(null); setDropOn(null); };
  const onDrop = (e, name) => {
    e.preventDefault();
    if (dragging && dragging !== name) {
      // would be: jj rebase -b <dragging> -d <name>
      // for the demo we just flash and reset
      console.log(`[demo] rebase ${dragging} onto ${name}`);
    }
    onDragEnd();
  };

  return (
    <div className="branch-heads">
      <div className="branch-heads-title">
        <span>Branch heads</span>
        <span className="hint">drag onto another to merge/rebase</span>
      </div>
      {heads.map(b => {
        const laneIdx = knownLanes.indexOf(b.name);
        const color = window.BRANCH_COLORS[b.name];
        const isDragging = dragging === b.name;
        const isDrop = dropOn === b.name;
        return (
          <div
            key={b.name}
            className={"branch-head-row " + (isDragging ? "dragging " : "") + (isDrop ? "drop-target " : "")}
            style={{
              "--lane-color": color,
              "--row-color": color,
              "--row-bg": softTint(color, 0.1),
              "--head-row-bg": softTint(color, 0.06),
            }}
            draggable
            onDragStart={(e) => onDragStart(e, b.name)}
            onDragOver={(e) => onDragOver(e, b.name)}
            onDragEnd={onDragEnd}
            onDrop={(e) => onDrop(e, b.name)}
          >
            <div className="branch-head-rail">
              <span
                className={"lane-cap " + (b.current ? "wc" : "")}
                style={{ left: laneIdx * LANE_W + 6 }}
              />
            </div>
            <div className="branch-head-info">
              <span className={"branch-head-name " + (b.current ? "current" : "")}>
                {b.name}
              </span>
              <span className="head-hash">{b.head}</span>
            </div>
            <div className="branch-head-meta">
              {b.ahead  > 0 && <span style={{ color: "var(--add)" }}>↑{b.ahead}</span>}
              {b.behind > 0 && <span style={{ color: "var(--rem)" }}>↓{b.behind}</span>}
            </div>
          </div>
        );
      })}
    </div>
  );
}

// ============================================================
// HISTORY COLUMN (jj log graph, always first)
// ============================================================
const LANE_W = 18;
function HistoryColumn({ selected, checkedOut, hoveredId, onCommitClick, onCheckout, onHover }) {
  const rows = window.HISTORY;
  const railWidth = window.LANES.length * LANE_W + 8;
  const listRef = useRef(null);
  const rowRefs = useRef({});
  const clickT = useRef(null);
  const handleClick = (data) => {
    if (clickT.current) return;
    clickT.current = setTimeout(() => { clickT.current = null; onCommitClick(data); }, 220);
  };
  const handleDoubleClick = (data) => {
    if (clickT.current) { clearTimeout(clickT.current); clickT.current = null; }
    onCheckout(data);
  };
  useEffect(() => () => { if (clickT.current) clearTimeout(clickT.current); }, []);

  // Precompute line metadata: for each row × lane → drawTop / drawBot
  const lineMeta = useMemo(() => rows.map((row, i) => (
    window.LANES.map((_, lane) => {
      if (!row.lanes.includes(lane)) return null;
      const prevHas = i > 0 && rows[i-1].lanes.includes(lane);
      const nextHas = i < rows.length - 1 && rows[i+1].lanes.includes(lane);
      let drawTop = prevHas;
      let drawBot = nextHas;
      if (row.branchOff === lane) drawBot = false;
      return { drawTop, drawBot };
    })
  )), [rows]);

  // Auto-scroll to selected
  useEffect(() => {
    if (!selected) return;
    const el = rowRefs.current[selected.changeId];
    if (el && listRef.current) {
      const elRect = el.getBoundingClientRect();
      const listRect = listRef.current.getBoundingClientRect();
      if (elRect.top < listRect.top + 30 || elRect.bottom > listRect.bottom - 30) {
        el.scrollIntoView({ block: "nearest", behavior: "smooth" });
      }
    }
  }, [selected?.changeId]);

  return (
    <section className="history-col" data-screen-label="History">
      <header className="history-header">
        <Icon name="history" size={13}/>
        <span className="history-header-title">History</span>
        <span className="history-header-meta">{rows.length} commits</span>
      </header>
      <div className="history-legend">
        {window.LANES.map(L => (
          <span className="legend-item" key={L.name}>
            <span className="legend-dot" style={{ background: L.color }}/>
            <span>{L.name}</span>
          </span>
        ))}
      </div>
      <div className="history-list" ref={listRef} style={{ "--lane-rail-width": railWidth + "px" }}>
        <BranchHeads/>
        {rows.map((row, i) => {
          const commit = row.commit;
          const isSelected = selected?.changeId === commit.changeId;
          const isHover = hoveredId === commit.changeId && !isSelected;
          const isCheckedOut = checkedOut?.changeId === commit.changeId;
          const laneColor = window.LANES[row.node].color;
          return (
            <div
              key={commit.changeId + "_" + i}
              ref={(el) => { rowRefs.current[commit.changeId] = el; }}
              className={"history-row " + (isSelected ? "highlight " : "") + (isHover ? "highlight-soft " : "") + (isCheckedOut ? "checked-out " : "")}
              onClick={() => handleClick({ source: "history", changeId: commit.changeId, commit })}
              onDoubleClick={() => handleDoubleClick({ source: "history", changeId: commit.changeId, commit })}
              onMouseEnter={() => onHover(commit.changeId)}
              onMouseLeave={() => onHover(null)}
              title={isCheckedOut ? "Working copy is here" : "Double-click to check out"}
            >
              <div className="lane-rail">
                {lineMeta[i].map((m, lane) => {
                  if (!m) return null;
                  return (
                    <span key={"line_" + lane}
                      className="lane-line"
                      style={{
                        left: lane * LANE_W + 11,
                        top:    m.drawTop ? 0 : "50%",
                        bottom: m.drawBot ? 0 : "50%",
                        background: window.LANES[lane].color,
                      }}
                    />
                  );
                })}
                <span
                  className={
                    "lane-node " +
                    (commit.isWorkingCopy ? "wc " : "") +
                    (commit.hasConflict ? "conflict " : "") +
                    (commit.isMerge ? "merge " : "")
                  }
                  style={{ left: row.node * LANE_W + 6, "--lane-color": laneColor }}
                />
              </div>
              <span className="history-changeid">{commit.changeId}</span>
              <span className="history-subject">
                {commit.isEmpty && <span className="empty">(empty) </span>}
                {commit.isMerge && <span className="empty">⤿ </span>}
                <span style={{ flex: 1, overflow: "hidden", textOverflow: "ellipsis" }}>
                  {commit.subject}
                </span>
                {isCheckedOut && (
                  <span className="history-checkout-badge" title="Working copy is here — code changes go to this commit">
                    <span className="history-checkout-at">@</span>
                    <span>checked out</span>
                  </span>
                )}
                {row.head && (
                  <span
                    className="history-head-badge"
                    style={{
                      "--head-bg":     softTint(laneColor, 0.18),
                      "--head-fg":     laneColor,
                      "--head-border": softTint(laneColor, 0.45),
                    }}
                  >
                    {row.head}
                  </span>
                )}
              </span>
            </div>
          );
        })}
      </div>
    </section>
  );
}

// ============================================================
// BRANCH COLUMN
// ============================================================
function BranchColumn({
  branchName, selected, hoveredId, onCommitClick, onHover, onClose,
  onDragStart, onDragOver, onDragEnd, onDrop, isDragging, dragSide,
  diffMode, onSetDiffMode, showFiles,
}) {
  const commits = window.COMMITS_BY_BRANCH[branchName] || [];
  const color = window.BRANCH_COLORS[branchName] || "#3b82f6";
  const bookmark = window.BOOKMARKS.find(b => b.name === branchName);

  return (
    <section
      className={"branch-col " + (isDragging ? "dragging " : "")}
      style={{
        "--branch-color": color,
        ...laneShade(color),
        "--branch-color-soft": softTint(color, 0.08),
      }}
      data-screen-label={`Branch ${branchName}`}
    >
      <header
        className="branch-col-header"
        draggable
        onDragStart={(e) => onDragStart(e, branchName)}
        onDragOver={(e) => onDragOver(e, branchName)}
        onDragEnd={onDragEnd}
        onDrop={(e) => onDrop(e, branchName)}
      >
        <div className="branch-col-header-name">
          <Icon name="branch" size={13}/>
          <span>{branchName}</span>
        </div>
        <div className="branch-col-header-meta">
          {bookmark?.ahead > 0 && <span className="branch-col-header-pill">↑{bookmark.ahead}</span>}
          {bookmark?.current && <span className="branch-col-header-pill">@</span>}
          <button className="branch-col-close" onClick={(e) => { e.stopPropagation(); onClose(branchName); }} title="Close column">
            <Icon name="close" size={11}/>
          </button>
        </div>
      </header>

      <div className="branch-col-body">
        {commits.map((commit, idx) => {
          const isExpanded = selected?.source === branchName && selected?.changeId === commit.changeId;
          const isHighlight = selected?.changeId === commit.changeId && !isExpanded;
          const isHover = hoveredId === commit.changeId && !isExpanded && !isHighlight;
          return (
            <div
              key={branchName + "_" + commit.changeId + "_" + idx}
              className={
                "commit-card " +
                (isExpanded ? "expanded " : "") +
                (isHighlight ? "selected " : "") +
                (isHover ? "soft-highlight " : "") +
                (commit.isWorkingCopy ? "wc " : "")
              }
              onMouseEnter={() => onHover(commit.changeId)}
              onMouseLeave={() => onHover(null)}
              onClick={() => onCommitClick({ source: branchName, changeId: commit.changeId, commit })}
            >
              <div className="ccard-head">
                {Boolean(
                  commit.isWorkingCopy || commit.isEmpty || commit.isMerge ||
                  commit.version || commit.hasConflict ||
                  (commit.bookmarks && commit.bookmarks.length > 0)
                ) && (
                  <div className="commit-tags">
                    {commit.isWorkingCopy && <span className="tag wc">@</span>}
                    {commit.isEmpty && <span className="tag empty">empty</span>}
                    {commit.isMerge && <span className="tag merge">merge</span>}
                    {commit.version && <span className="tag version">{commit.version}</span>}
                    {commit.hasConflict && <span className="tag conflict"><Icon name="conflict" size={10}/>conflict</span>}
                    {commit.bookmarks?.map(b => <span key={b} className="tag bookmark">{b}</span>)}
                  </div>
                )}
                <div className="commit-subject">{commit.subject}</div>
                <div className="commit-foot">
                  <span className="item changeid">{commit.changeId}</span>
                  <span className="item"><Icon name="user" size={11}/>{commit.author.split(" ")[0]}</span>
                  <span className="item"><Icon name="calendar" size={11}/>{commit.date}</span>
                </div>
              </div>
              {isExpanded && (
                <CommitDetail
                  commit={commit}
                  branchColor={color}
                  diffMode={diffMode}
                  onSetDiffMode={onSetDiffMode}
                  showFiles={showFiles}
                />
              )}
            </div>
          );
        })}
      </div>
    </section>
  );
}

// ============================================================
// COMMIT DETAIL (inline, inside the expanded card)
// ============================================================
function CommitDetail({ commit, branchColor, diffMode, onSetDiffMode, showFiles }) {
  const [selectedFile, setSelectedFile] = useState(commit.files?.[0]?.path);
  useEffect(() => { setSelectedFile(commit.files?.[0]?.path); }, [commit.changeId]);
  const files = commit.files || [];
  const [reviewed, setViewed, setMany] = useReviewState(commit.changeId);

  const paths = useMemo(() => files.map(f => f.path), [files]);
  const viewedCount = paths.filter(p => reviewed[p]).length;
  const total = paths.length;
  const allViewed = total > 0 && viewedCount === total;
  const currentFileViewed = !!reviewed[selectedFile];

  // Auto-advance to the next unreviewed file when marking the current one viewed
  const handleToggleCurrent = () => {
    const nextVal = !currentFileViewed;
    setViewed(selectedFile, nextVal);
    if (nextVal) {
      const idx = paths.indexOf(selectedFile);
      const next = paths.slice(idx + 1).find(p => !reviewed[p]) ||
                   paths.slice(0, idx).find(p => !reviewed[p]);
      if (next) setSelectedFile(next);
    }
  };

  return (
    <div className="commit-detail">
      <div className="detail-meta-card">
        <div className="detail-meta-row"><Icon name="user" size={11}/><span>{commit.author}</span></div>
        <div className="detail-meta-row"><Icon name="calendar" size={11}/><span>{commit.date === "now" ? "just now" : commit.date}</span></div>
        <div className="detail-meta-row"><Icon name="hash" size={11}/><span className="mono">{commit.changeId}</span></div>
        <div className="detail-meta-row"><Icon name="arrowLeft" size={11}/><span className="lbl">parent</span><span className="mono">{commit.parents?.[0] || "c3d4e5f"}</span></div>
      </div>

      {commit.description && (
        <div style={{
          fontSize: "11.5px", color: "var(--text-muted)",
          padding: "8px 10px", background: "rgba(255,255,255,0.018)",
          borderLeft: "2px solid var(--border-strong)", borderRadius: "0 4px 4px 0",
          whiteSpace: "pre-line"
        }}>{commit.description}</div>
      )}

      {showFiles && files.length > 0 && (
        <>
          <div className="detail-section-h">
            <Icon name="fileText" size={12}/>
            <span>Changed files ({files.length})</span>
            <span className="review-meter" title={`${viewedCount} of ${total} files reviewed`}>
              <span className="review-meter-track">
                <span
                  className={"review-meter-fill " + (allViewed ? "complete " : "")}
                  style={{ width: total ? (viewedCount / total) * 100 + "%" : 0 }}
                />
              </span>
              <span className={"review-meter-text " + (allViewed ? "complete " : "")}>
                {allViewed ? (
                  <><Icon name="check" size={10}/>all reviewed</>
                ) : (
                  <>{viewedCount} / {total} viewed</>
                )}
              </span>
              <button
                className="review-meter-action"
                onClick={(e) => { e.stopPropagation(); setMany(paths, !allViewed); }}
                title={allViewed ? "Reset review state" : "Mark all files as viewed"}
              >
                {allViewed ? "Reset" : "Mark all"}
              </button>
            </span>
            <span className="stat">
              <span className="stat-add">+{commit.stats.added}</span>
              <span className="stat-rem">−{commit.stats.removed}</span>
            </span>
          </div>
          <div className="detail-files">
            {files.map(f => {
              const isViewed = !!reviewed[f.path];
              return (
                <div key={f.path}
                  className={
                    "file-row " +
                    (f.path === selectedFile ? "selected " : "") +
                    (isViewed ? "viewed " : "")
                  }
                  onClick={(e) => { e.stopPropagation(); setSelectedFile(f.path); }}
                  role="button"
                  tabIndex={0}
                >
                  <button
                    className={"file-check " + (isViewed ? "checked " : "")}
                    onClick={(e) => { e.stopPropagation(); setViewed(f.path, !isViewed); }}
                    role="checkbox"
                    aria-checked={isViewed}
                    aria-label={isViewed ? "Mark as not viewed" : "Mark as viewed"}
                    title={isViewed ? "Mark as not viewed" : "Mark as viewed"}
                  >
                    {isViewed && <Icon name="check" size={10}/>}
                  </button>
                  <span className={"file-status status-" + f.status}>{f.status}</span>
                  <span className="file-path"><span className="file-path-inner">{f.path}</span></span>
                  <span className="file-stat">
                    <span className="stat-add">+{f.added}</span>
                    <span className="stat-rem">−{f.removed}</span>
                  </span>
                </div>
              );
            })}
          </div>
        </>
      )}

      <DiffBlock
        mode={diffMode}
        onSetMode={onSetDiffMode}
        filePath={selectedFile}
        viewed={currentFileViewed}
        onToggleViewed={handleToggleCurrent}
      />

      <div className="detail-actions">
        <button className="action-btn primary" onClick={(e) => e.stopPropagation()}>Edit</button>
        <button className="action-btn" onClick={(e) => e.stopPropagation()}>Squash</button>
        <button className="action-btn" onClick={(e) => e.stopPropagation()}>Abandon</button>
        <button className="action-btn" onClick={(e) => e.stopPropagation()}>Rebase…</button>
      </div>
    </div>
  );
}

function DiffBlock({ mode, onSetMode, filePath, viewed, onToggleViewed }) {
  const lines = window.SAMPLE_DIFF.default;

  let body;
  if (mode === "split") {
    const rows = [];
    let i = 0;
    while (i < lines.length) {
      const l = lines[i];
      if (l.type === "hunk") { rows.push({ type: "hunk", text: l.text }); i++; continue; }
      if (l.type === "remove") {
        const next = lines[i+1];
        if (next && next.type === "add") { rows.push({ type: "change", left: l, right: next }); i += 2; continue; }
        rows.push({ type: "change", left: l, right: null }); i++; continue;
      }
      if (l.type === "add")    { rows.push({ type: "change", left: null, right: l }); i++; continue; }
      rows.push({ type: "context", left: l, right: l }); i++;
    }
    body = (
      <div className="diff-body split">
        {rows.map((r, idx) => {
          if (r.type === "hunk") return <div key={idx} className="diff-hunk">{r.text}</div>;
          return (
            <div key={idx} className="diff-row">
              <div className={"side " + (r.left ? r.left.type : "empty")}><span className="txt">{r.left ? r.left.text : ""}</span></div>
              <div className={"side " + (r.right ? r.right.type : "empty")}><span className="txt">{r.right ? r.right.text : ""}</span></div>
            </div>
          );
        })}
      </div>
    );
  } else {
    body = (
      <div className="diff-body">
        {lines.map((l, idx) => {
          if (l.type === "hunk") return <div key={idx} className="diff-hunk">{l.text}</div>;
          const sigil = l.type === "add" ? "+" : l.type === "remove" ? "−" : " ";
          return (
            <div key={idx} className={"diff-line " + l.type}>
              <span className="sigil">{sigil}</span>
              <span className="txt">{l.text}</span>
            </div>
          );
        })}
      </div>
    );
  }

  return (
    <div className={"diff-block " + (viewed ? "viewed " : "")} onClick={(e) => e.stopPropagation()}>
      <div className="diff-toolbar">
        {filePath ? (
          <span className="diff-toolbar-file" title={filePath}>{filePath}</span>
        ) : (
          <span>Diff preview</span>
        )}
        <div className="diff-mode-toggle">
          <button className={mode === "inline" ? "seg active" : "seg"} onClick={() => onSetMode("inline")}><Icon name="splitInline" size={11}/>Inline</button>
          <button className={mode === "split"  ? "seg active" : "seg"} onClick={() => onSetMode("split")}><Icon name="splitSide" size={11}/>Split</button>
        </div>
        {onToggleViewed && (
          <button
            className={"diff-viewed-toggle " + (viewed ? "viewed " : "")}
            onClick={(e) => { e.stopPropagation(); onToggleViewed(); }}
            role="checkbox"
            aria-checked={!!viewed}
            title={viewed ? "Mark as not viewed" : "Mark as viewed (V)"}
          >
            <span className={"diff-viewed-box " + (viewed ? "checked " : "")}>
              {viewed && <Icon name="check" size={10}/>}
            </span>
            <span>Viewed</span>
          </button>
        )}
      </div>
      {viewed ? (
        <button
          className="diff-collapsed"
          onClick={(e) => { e.stopPropagation(); onToggleViewed && onToggleViewed(); }}
          title="Click to expand and mark as not viewed"
        >
          <Icon name="check" size={11}/>
          <span>Reviewed — diff hidden. Click to expand.</span>
        </button>
      ) : body}
    </div>
  );
}

// ============================================================
// STATUS BAR
// ============================================================
function StatusBar({ openCount }) {
  const current = window.BOOKMARKS.find(b => b.current);
  return (
    <footer className="status-bar">
      <div className="status-left">
        <span className="status-item"><strong>@</strong> {current?.name}</span>
        <span className="status-item"><span className="status-dot ok"/>repo clean</span>
        <span className="status-item">142 ops</span>
      </div>
      <div className="status-right">
        <span className="status-item">jj 0.24.0</span>
        <span className="status-item">flutter 3.27.1</span>
        <span className="status-item"><kbd>⌘K</kbd> palette</span>
      </div>
    </footer>
  );
}

// ============================================================
// COL WRAP — handles drag-over visual
// ============================================================
function ColWrap({ width, dragSide, isDragging, onResizeStart, children, resizable = true }) {
  return (
    <div
      className={
        "col-wrap " +
        (isDragging ? "is-dragging " : "") +
        (dragSide === "left" ? "dragover-left " : "") +
        (dragSide === "right" ? "dragover-right " : "")
      }
      style={{ width }}
    >
      {children}
      {resizable && (
        <div className="col-resize" onPointerDown={onResizeStart}/>
      )}
    </div>
  );
}

// ============================================================
// HEADER ICON ROW — horizontal row in main-header (replaces function-rail)
// ============================================================
function HeaderIconRow({ leftPanel, onSet, onHover, flyout }) {
  const items = [
    { id: "history",    label: "History",       icon: "history" },
    { id: "branches",   label: "Branches",      icon: "branch" },
    { id: "workstream", label: "Workstreams",   icon: "workstream" },
    { id: "reviews",    label: "Reviews",       icon: "reviews" },
    { id: "undo",       label: "Undo Timeline", icon: "undo" },
  ];
  return (
    <div className="col-tabs" role="tablist" aria-label="Left column view">
      {items.map(it => {
        const isActive = leftPanel === it.id;
        const isHovered = flyout === it.id;
        return (
          <button
            key={it.id}
            role="tab"
            aria-selected={isActive}
            aria-label={it.label}
            className={"col-tab " + (isActive ? "active " : "") + (isHovered ? "hovered " : "")}
            title={it.label}
            onMouseEnter={() => onHover(it.id, "hover")}
            onClick={() => onSet(it.id)}
          >
            <Icon name={it.icon} size={15}/>
          </button>
        );
      })}
    </div>
  );
}

// ============================================================
// LEFT PANEL — renders the leftmost column based on `kind`
// ============================================================
function LeftPanel({ kind, onClose, selected, checkedOut, hoveredId, onCommitClick, onCheckout, onHover, openColumns, onToggleBranch }) {
  if (kind === "history") {
    return (
      <HistoryColumn
        selected={selected}
        checkedOut={checkedOut}
        hoveredId={hoveredId}
        onCommitClick={onCommitClick}
        onCheckout={onCheckout}
        onHover={onHover}
      />
    );
  }
  if (kind === "branches") {
    return (
      <SidePanel title="Branches" icon="branch" onClose={onClose}>
        <BranchesPanelBody openColumns={openColumns} onToggle={onToggleBranch}/>
      </SidePanel>
    );
  }
  if (kind === "workstream") {
    return (
      <SidePanel title="Workstreams" icon="workstream" onClose={onClose}>
        <div className="side-empty">No workstreams yet.<br/>Create one with <code>jj workstream new</code>.</div>
      </SidePanel>
    );
  }
  if (kind === "reviews") {
    return (
      <SidePanel title="Reviews" icon="reviews" onClose={onClose}>
        <div className="side-empty">No open reviews.</div>
      </SidePanel>
    );
  }
  if (kind === "undo") {
    return (
      <SidePanel title="Undo Timeline" icon="undo" onClose={onClose}>
        <div className="side-list">
          <div className="side-row active"><span className="side-dot active"/><div><div className="side-row-title">describe -m "wip: refactor"</div><div className="side-row-sub">8 min ago</div></div></div>
          <div className="side-row"><span className="side-dot"/><div><div className="side-row-title">new -A @</div><div className="side-row-sub">12 min ago</div></div></div>
          <div className="side-row"><span className="side-dot"/><div><div className="side-row-title">git fetch</div><div className="side-row-sub">2h ago</div></div></div>
          <div className="side-row"><span className="side-dot"/><div><div className="side-row-title">rebase -d main</div><div className="side-row-sub">3h ago</div></div></div>
          <div className="side-row"><span className="side-dot"/><div><div className="side-row-title">bookmark create feat/onboarding</div><div className="side-row-sub">yesterday</div></div></div>
        </div>
      </SidePanel>
    );
  }
  return null;
}

function SidePanel({ title, icon, onClose, children }) {
  return (
    <section className="left-panel" data-screen-label={title}>
      <header className="left-panel-header">
        <Icon name={icon} size={13}/>
        <h3>{title}</h3>
        {onClose && (
          <button className="lp-close" onClick={onClose} title="Back to History">
            <Icon name="close" size={11}/>
          </button>
        )}
      </header>
      <div className="left-panel-body">{children}</div>
    </section>
  );
}

function BranchesPanelBody({ openColumns, onToggle }) {
  const [q, setQ] = useState("");
  const matches = (n) => !q || n.toLowerCase().includes(q.toLowerCase());
  const local = window.BOOKMARKS.filter(b => matches(b.name));
  const remote = window.REMOTE_BRANCHES.filter(b => matches(b.name));
  return (
    <>
      <div className="lp-search">
        <Icon name="branch" size={12}/>
        <input placeholder="Filter…" value={q} onChange={(e) => setQ(e.target.value)}/>
      </div>
      <div className="flyout-section-h"><span>Local</span><span className="count">{local.length}</span></div>
      {local.map(b => {
        const color = window.BRANCH_COLORS[b.name] || "#3b82f6";
        const open = openColumns.includes(b.name);
        return (
          <div
            key={b.name}
            className={"flyout-row " + (open ? "open" : "")}
            style={{ "--row-color": color, "--row-bg": softTint(color, 0.1) }}
            draggable
            onDragStart={(e) => e.dataTransfer.setData("text/plain", b.name)}
            onClick={() => onToggle(b.name)}
            title={open ? `Close ${b.name}` : `Open ${b.name}`}
          >
            <span className="dot"/>
            <span className="name">{b.name}{b.current && " @"}</span>
            <span className="meta">
              {b.ahead  > 0 && <span className="ahead">↑{b.ahead}</span>}
              {b.behind > 0 && <span className="behind">↓{b.behind}</span>}
            </span>
          </div>
        );
      })}
      <div className="flyout-section-h" style={{ marginTop: 6 }}><span>Remote</span><span className="count">{remote.length}</span></div>
      {remote.map(b => {
        const trackingColor = b.trackedBy ? window.BRANCH_COLORS[b.trackedBy] || "#6b7280" : "#6b7280";
        return (
          <div
            key={b.name}
            className="flyout-row"
            style={{ "--row-color": trackingColor }}
            title={b.trackedBy ? `Tracked by ${b.trackedBy}` : "Untracked remote"}
          >
            <span className="dot" style={{ opacity: b.trackedBy ? 1 : 0.4 }}/>
            <span className="name" style={{ opacity: b.trackedBy ? 1 : 0.7 }}>{b.name}</span>
            <span className="meta">
              {b.aheadOfLocal > 0 && <span className="ahead">↑{b.aheadOfLocal}</span>}
              {b.behindLocal  > 0 && <span className="behind">↓{b.behindLocal}</span>}
            </span>
          </div>
        );
      })}
    </>
  );
}

// ============================================================
// DETAIL SIDE PANEL — slides in to the right of selected branch
// ============================================================
function DetailSidePanel({ data, onClose, diffMode, onSetDiffMode, showFiles }) {
  const { commit, source } = data;
  const branchColor = window.BRANCH_COLORS[source] || "#3b82f6";

  return (
    <section
      className="detail-side-panel"
      style={{
        "--branch-color": branchColor,
        ...laneShade(branchColor),
        "--branch-color-soft": softTint(branchColor, 0.1),
      }}
      data-screen-label={`Detail ${commit.changeId}`}
    >
      <header className="dsp-header">
        <div className="dsp-tags">
          {commit.isWorkingCopy && <span className="tag wc">@</span>}
          {commit.isEmpty && <span className="tag empty">empty</span>}
          {commit.isMerge && <span className="tag merge">merge</span>}
          {commit.version && <span className="tag version">{commit.version}</span>}
          {commit.hasConflict && <span className="tag conflict"><Icon name="conflict" size={10}/>conflict</span>}
          <span className="dsp-source">in <strong>{source}</strong></span>
        </div>
        <button className="dsp-close" onClick={onClose} title="Close (Esc)"><Icon name="close" size={12}/></button>
      </header>
      <h2 className="dsp-subject">
        {commit.isEmpty && <span style={{ color: "var(--text-dim)", fontStyle: "italic", marginRight: 4 }}>(empty)</span>}
        {commit.subject}
      </h2>
      <div className="dsp-body">
        <CommitDetail
          commit={commit}
          branchColor={branchColor}
          diffMode={diffMode}
          onSetDiffMode={onSetDiffMode}
          showFiles={showFiles}
        />
      </div>
    </section>
  );
}

// ============================================================
// SLOT — holds 1+ branches stacked vertically
// ============================================================
function Slot({
  slot, slotIndexInAll, width, onResizeStart,
  selected, checkedOut, editMeta, hoveredId, onCommitClick, onCheckout, onStartEditMeta, onCancelEditMeta, onHover,
  onCloseBranch, onSlotHeaderDragStart, isSlotDragged,
  onBranchDragStart, onDropOver, onDropTarget, dropTarget, dragActive,
  diffMode, onSetDiffMode, showFiles,
  onToggleMergeRight, canMergeRight, mergedRight,
  onCloseDetail,
}) {
  const isStack = slot.branches.length > 1;
  const detailOpen = !!selected && slot.branches.includes(selected.source);
  const totalWidth = detailOpen ? width + 460 : width;
  return (
    <div
      className={"col-wrap slot-wrap " + (isSlotDragged ? "is-dragging " : "") + (isStack ? "is-stack " : "") + (detailOpen ? "with-detail " : "")}
      style={{ width: totalWidth }}
    >
      <div className={"slot " + (isStack ? "is-stack " : "")}>
        {/* Drop target above the top branch (also a "stack on top" target) */}
        <DropZone
          label={isStack ? "drop to add to stack" : "drop to stack above"}
          active={dragActive}
          isOver={dropTarget?.kind === "slot-top" && dropTarget.slotId === slot.id}
          onOver={(e) => onDropOver(e, { kind: "slot-top", slotId: slot.id })}
          onLeave={() => {}}
          onDrop={(e) => onDropTarget(e, { kind: "slot-top", slotId: slot.id })}
        />
        {slot.branches.map((branchName, bi) => {
          const isLast = bi === slot.branches.length - 1;
          return (
            <React.Fragment key={branchName}>
              <BranchPanel
                branchName={branchName}
                slotId={slot.id}
                selected={selected}
                checkedOut={checkedOut}
                editMeta={editMeta}
                hoveredId={hoveredId}
                onCommitClick={onCommitClick}
                onCheckout={onCheckout}
                onStartEditMeta={onStartEditMeta}
                onCancelEditMeta={onCancelEditMeta}
                onHover={onHover}
                onClose={onCloseBranch}
                onSlotHeaderDragStart={onSlotHeaderDragStart}
                onBranchDragStart={onBranchDragStart}
                diffMode={diffMode}
                onSetDiffMode={onSetDiffMode}
                showFiles={showFiles}
                stackedRole={!isStack ? null : (bi === 0 ? "tip" : (bi === slot.branches.length - 1 ? "base" : "stacked"))}
                onToggleMergeRight={onToggleMergeRight}
                canMergeRight={bi === 0 ? canMergeRight : false}
                mergedRight={bi === 0 ? mergedRight : false}
                detailData={selected && selected.source === branchName ? selected : null}
                onCloseDetail={onCloseDetail}
              />
              {/* Between or bottom drop zone */}
              <DropZone
                label={isLast ? "drop to stack below" : "drop between"}
                active={dragActive}
                isOver={dropTarget?.kind === (isLast ? "slot-bot" : "slot-between") &&
                  dropTarget.slotId === slot.id &&
                  (isLast ? true : dropTarget.idx === bi + 1)}
                onOver={(e) => onDropOver(e, isLast ? { kind: "slot-bot", slotId: slot.id } : { kind: "slot-between", slotId: slot.id, idx: bi + 1 })}
                onLeave={() => {}}
                onDrop={(e) => onDropTarget(e, isLast ? { kind: "slot-bot", slotId: slot.id } : { kind: "slot-between", slotId: slot.id, idx: bi + 1 })}
              />
            </React.Fragment>
          );
        })}
      </div>
      <div className="col-resize" onPointerDown={onResizeStart}/>
    </div>
  );
}

// Drop zone — visible during drag, becomes prominent on hover
function DropZone({ label, active, isOver, onOver, onLeave, onDrop }) {
  if (!active) return null;
  return (
    <div
      className={"drop-zone " + (isOver ? "over" : "")}
      onDragOver={onOver}
      onDragLeave={onLeave}
      onDrop={onDrop}
    >
      <span>{label}</span>
    </div>
  );
}

// Slot edge drop — for inserting a new slot between clusters
function SlotEdgeDrop({ active, isOver, onOver, onLeave, onDrop }) {
  if (!active) return null;
  return (
    <div
      className={"slot-edge-drop " + (isOver ? "over" : "")}
      onDragOver={onOver}
      onDragLeave={onLeave}
      onDrop={onDrop}
    />
  );
}

// ============================================================
// EDIT PANEL — inline editor that takes over a commit card in edit mode
// ============================================================
function EditPanel({ commit, color, onDone, onDiscard }) {
  const [subject, setSubject] = useState(commit.subject);
  const [desc, setDesc] = useState(commit.description || "");
  const subjRef = useRef(null);
  useEffect(() => {
    setSubject(commit.subject);
    setDesc(commit.description || "");
    const t = setTimeout(() => { if (subjRef.current) { subjRef.current.focus(); subjRef.current.select(); } }, 30);
    return () => clearTimeout(t);
  }, [commit.changeId]);
  const stop = (e) => e.stopPropagation();
  const dirty = subject !== commit.subject || desc !== (commit.description || "");
  return (
    <div className="edit-panel" onClick={stop} onDoubleClick={stop}>
      <div className="edit-field">
        <label className="edit-label">Commit message</label>
        <input
          ref={subjRef}
          className="edit-input edit-subject"
          value={subject}
          onChange={(e) => setSubject(e.target.value)}
          placeholder="Subject…"
          onKeyDown={(e) => { if (e.key === "Enter") { e.preventDefault(); onDone(); } if (e.key === "Escape") { e.preventDefault(); onDiscard(); } }}
        />
        <textarea
          className="edit-input edit-desc"
          value={desc}
          onChange={(e) => setDesc(e.target.value)}
          placeholder="Describe this change in more detail…"
          rows={3}
        />
      </div>
      <div className="edit-hint">
        <code>jj edit {commit.changeId}</code>
        <span>Working copy moved here. New file changes will be amended into this revision.</span>
      </div>
      <div className="edit-status">
        <span className={"edit-dot " + (dirty ? "dirty" : "")}/>
        <span className="edit-status-txt">
          {dirty ? <>Unsaved changes — <code>describe</code> will run on done</> : <>No pending edits to message</>}
        </span>
        <span className="edit-files-mini">
          <Icon name="fileText" size={11}/>
          <span>{commit.files?.length || 0} file{(commit.files?.length || 0) === 1 ? "" : "s"} · </span>
          <span className="stat-add">+{commit.stats?.added ?? 0}</span>
          <span className="stat-rem">−{commit.stats?.removed ?? 0}</span>
        </span>
      </div>
      <div className="edit-actions">
        <button className="action-btn" onClick={onDiscard}>Discard</button>
        <button className="action-btn primary edit-primary" onClick={onDone}>
          <Icon name="check" size={12}/> Done editing
        </button>
      </div>
    </div>
  );
}

// ============================================================
// BRANCH PANEL — single branch inside a slot (was BranchColumn)
// Renders the same column UI but accepts slot context
// ============================================================
function BranchPanel({
  branchName, slotId, selected, checkedOut, editMeta, hoveredId, onCommitClick, onCheckout, onStartEditMeta, onCancelEditMeta, onHover, onClose,
  onSlotHeaderDragStart, onBranchDragStart,
  diffMode, onSetDiffMode, showFiles,
  stackedRole, onToggleMergeRight, canMergeRight, mergedRight,
  detailData, onCloseDetail,
}) {
  const commits = window.COMMITS_BY_BRANCH[branchName] || [];
  const color = window.BRANCH_COLORS[branchName] || "#3b82f6";
  const bookmark = window.BOOKMARKS.find(b => b.name === branchName);
  const detailOpen = !!detailData;
  const clickT = useRef(null);
  const bodyRef = useRef(null);
  const cardRefs = useRef({});
  const handleClick = (data) => {
    if (clickT.current) return;
    clickT.current = setTimeout(() => { clickT.current = null; onCommitClick(data); }, 220);
  };
  const handleDoubleClick = (data) => {
    if (clickT.current) { clearTimeout(clickT.current); clickT.current = null; }
    onCheckout(data);
  };
  useEffect(() => () => { if (clickT.current) clearTimeout(clickT.current); }, []);

  // Is the checked-out commit somewhere in this branch?
  const branchHasCheckout = !!(checkedOut && commits.some(c => c.changeId === checkedOut.changeId));
  // Track whether the checked-out card is currently visible inside the scroll area
  const [checkoutOffscreen, setCheckoutOffscreen] = useState(false);
  const [offscreenDir, setOffscreenDir] = useState(null); // 'up' | 'down'

  useEffect(() => {
    if (!branchHasCheckout) { setCheckoutOffscreen(false); return; }
    const body = bodyRef.current;
    const card = cardRefs.current[checkedOut.changeId];
    if (!body || !card) return;
    const compute = () => {
      const bRect = body.getBoundingClientRect();
      const cRect = card.getBoundingClientRect();
      const above = cRect.bottom < bRect.top + 8;
      const below = cRect.top > bRect.bottom - 8;
      const off = above || below;
      setCheckoutOffscreen(off);
      setOffscreenDir(above ? "up" : below ? "down" : null);
    };
    compute();
    body.addEventListener("scroll", compute, { passive: true });
    const ro = new ResizeObserver(compute);
    ro.observe(body);
    return () => {
      body.removeEventListener("scroll", compute);
      ro.disconnect();
    };
  }, [branchHasCheckout, checkedOut?.changeId, commits.length, detailOpen]);

  const scrollToCheckout = () => {
    const body = bodyRef.current;
    const card = cardRefs.current[checkedOut?.changeId];
    if (!body || !card) return;
    const bRect = body.getBoundingClientRect();
    const cRect = card.getBoundingClientRect();
    const delta = (cRect.top - bRect.top) - (bRect.height / 2 - cRect.height / 2);
    body.scrollBy({ top: delta, behavior: "smooth" });
  };

  return (
    <section
      className={"branch-col " + (detailOpen ? "with-detail " : "") + (branchHasCheckout ? "has-checkout " : "")}
      style={{
        "--branch-color": color,
        ...laneShade(color),
        "--branch-color-soft": softTint(color, 0.08),
        "--branch-color-deep": softTint(color, 0.55),
        "--branch-color-glow": softTint(color, 0.30),
        "--branch-color-glow-soft": softTint(color, 0.16),
      }}
      data-screen-label={`Branch ${branchName}`}
    >
      <header
        className="branch-col-header"
        draggable
        onDragStart={(e) => {
          // Top-most branch in slot = drag the WHOLE slot. Others = drag this branch.
          if (stackedRole === "tip" || stackedRole === null) {
            onSlotHeaderDragStart(e, slotId);
          } else {
            onBranchDragStart(e, branchName);
          }
        }}
      >
        {stackedRole && (
          <span className="role-badge">{stackedRole}</span>
        )}
        <div className="branch-col-header-name">
          <Icon name="branch" size={13}/>
          <span>{branchName}</span>
          {branchHasCheckout && (
            <button
              className={"branch-checkout-pill " + (checkoutOffscreen ? "is-offscreen " : "")}
              onClick={(e) => { e.stopPropagation(); scrollToCheckout(); }}
              title={checkoutOffscreen
                ? `Working copy ${offscreenDir === "up" ? "above" : "below"} — click to scroll into view`
                : "Working copy is in this branch"}
            >
              <span className="branch-checkout-pill-dot"/>
              <span className="branch-checkout-pill-at">@</span>
              {checkoutOffscreen && offscreenDir === "up"   && <span className="branch-checkout-pill-arrow" aria-hidden="true">▲</span>}
              {checkoutOffscreen && offscreenDir === "down" && <span className="branch-checkout-pill-arrow" aria-hidden="true">▼</span>}
            </button>
          )}
        </div>
        <div className="branch-col-header-meta">
          {bookmark?.ahead > 0 && <span className="branch-col-header-pill">↑{bookmark.ahead}</span>}
          {bookmark?.current && <span className="branch-col-header-pill">@</span>}
          {canMergeRight && (
            <button
              className={"branch-col-merge-btn " + (mergedRight ? "active" : "")}
              onClick={(e) => { e.stopPropagation(); onToggleMergeRight && onToggleMergeRight(); }}
              title={mergedRight ? "Break merge with right neighbor" : "Virtually merge with right neighbor"}
            >
              <Icon name="merge" size={12}/>
            </button>
          )}
          <button
            className="branch-col-close"
            onClick={(e) => { e.stopPropagation(); onClose(branchName); }}
            title="Close branch"
          >
            <Icon name="close" size={11}/>
          </button>
        </div>
      </header>

      <div className="branch-col-split">
        <div className="branch-col-body" ref={bodyRef}>
        {commits.map((commit, idx) => {
          const isSelected = selected?.source === branchName && selected?.changeId === commit.changeId;
          const isHighlight = selected?.changeId === commit.changeId && !isSelected;
          const isHover = hoveredId === commit.changeId && !isSelected && !isHighlight;
          const isCheckedOut = checkedOut?.changeId === commit.changeId;
          // The original data may still mark this commit as the working copy; suppress that visual
          // when the user has checked something else out.
          const wasWorkingCopy = commit.isWorkingCopy && !isCheckedOut && checkedOut && checkedOut.changeId !== commit.changeId;
          return (
            <div
              key={branchName + "_" + commit.changeId + "_" + idx}
              ref={(el) => { cardRefs.current[commit.changeId] = el; }}
              className={
                "commit-card " +
                (isSelected ? "is-selected " : "") +
                (isHighlight ? "selected " : "") +
                (isHover ? "soft-highlight " : "") +
                ((commit.isWorkingCopy && isCheckedOut) || isCheckedOut ? "wc " : "") +
                (isCheckedOut ? "checked-out " : "") +
                (wasWorkingCopy ? "was-wc " : "")
              }
              onMouseEnter={() => onHover(commit.changeId)}
              onMouseLeave={() => onHover(null)}
              onClick={() => handleClick({ source: branchName, changeId: commit.changeId, commit })}
              onDoubleClick={() => handleDoubleClick({ source: branchName, changeId: commit.changeId, commit })}
              title={isCheckedOut ? "Working copy is here" : "Double-click to check out"}
            >
              {isCheckedOut && (
                <div className="checkout-ribbon" onClick={(e) => e.stopPropagation()}>
                  <span className="checkout-ribbon-dot"/>
                  <span className="checkout-ribbon-at">@</span>
                  <span className="checkout-ribbon-label">Checked out</span>
                  <span className="checkout-ribbon-meta">code changes go here</span>
                </div>
              )}
              <div className="ccard-head">
                {Boolean(
                  isCheckedOut || wasWorkingCopy || commit.isEmpty || commit.isMerge ||
                  commit.version || commit.hasConflict ||
                  (commit.bookmarks && commit.bookmarks.length > 0)
                ) && (
                  <div className="commit-tags">
                    {isCheckedOut && <span className="tag wc checkout-tag">@ working copy</span>}
                    {wasWorkingCopy && <span className="tag wc-was" title="Working copy moved away from this commit">@ was here</span>}
                    {commit.isEmpty && <span className="tag empty">empty</span>}
                    {commit.isMerge && <span className="tag merge">merge</span>}
                    {commit.version && <span className="tag version">{commit.version}</span>}
                    {commit.hasConflict && <span className="tag conflict"><Icon name="conflict" size={10}/>conflict</span>}
                    {commit.bookmarks?.map(b => <span key={b} className="tag bookmark">{b}</span>)}
                  </div>
                )}
                <div className="commit-subject">{commit.subject}</div>
                <div className="commit-foot">
                  <span className="item changeid">{commit.changeId}</span>
                  <span className="item"><Icon name="user" size={11}/>{commit.author.split(" ")[0]}</span>
                  <span className="item"><Icon name="calendar" size={11}/>{commit.date}</span>
                </div>
              </div>
            </div>
          );
        })}
        </div>
        {detailOpen && (
          <div className="branch-col-detail">
            <div className="bcd-header">
              <div className="commit-tags">
                {detailData.commit.isWorkingCopy && <span className="tag wc">@</span>}
                {detailData.commit.isEmpty && <span className="tag empty">empty</span>}
                {detailData.commit.isMerge && <span className="tag merge">merge</span>}
                {detailData.commit.version && <span className="tag version">{detailData.commit.version}</span>}
                {detailData.commit.hasConflict && <span className="tag conflict"><Icon name="conflict" size={10}/>conflict</span>}
              </div>
              {!editMeta && (
                <button
                  className="bcd-edit-btn"
                  onClick={onStartEditMeta}
                  title="Edit commit message and description"
                >
                  <Icon name="edit" size={11}/>
                  <span>Edit</span>
                </button>
              )}
              <button className="bcd-close" onClick={onCloseDetail} title="Close details (Esc)">
                <Icon name="close" size={12}/>
              </button>
            </div>
            <h2 className="bcd-subject">{detailData.commit.subject}</h2>
            <div className="bcd-body">
              {editMeta ? (
                <EditPanel
                  commit={detailData.commit}
                  color={color}
                  onDone={onCancelEditMeta}
                  onDiscard={onCancelEditMeta}
                />
              ) : (
                <CommitDetail
                  commit={detailData.commit}
                  branchColor={color}
                  diffMode={diffMode}
                  onSetDiffMode={onSetDiffMode}
                  showFiles={showFiles}
                />
              )}
            </div>
          </div>
        )}
      </div>
    </section>
  );
}

// ============================================================
// MERGE BAR — header bar above merged slots
// ============================================================
function MergeBar({ slots, colors, onRemoveFromMerge, active, isOver, onOver, onLeave, onDrop }) {
  const totalBranches = slots.reduce((s, slot) => s + slot.branches.length, 0);
  const totalCommits = slots.reduce((s, slot) =>
    s + slot.branches.reduce((sb, b) => sb + (window.COMMITS_BY_BRANCH[b]?.length || 0), 0), 0);
  const conflicts = slots.some(slot =>
    slot.branches.some(b => (window.COMMITS_BY_BRANCH[b] || []).some(c => c.hasConflict))
  ) ? 1 : 0;

  return (
    <div
      className={"merge-bar " + (isOver ? "over " : "")}
      style={{
        "--mc1": colors[0] || "#3b82f6",
        "--mc2": colors[Math.floor(colors.length / 2)] || "#22c55e",
        "--mc3": colors[colors.length - 1] || "#a855f7",
      }}
      onDragOver={onOver}
      onDragLeave={onLeave}
      onDrop={onDrop}
    >
      <div className="merge-bar-title">
        <Icon name="merge" size={13}/>
        <span>Virtual merge</span>
        <span className="merge-bar-meta">{slots.length} slots · {totalBranches} branches · {totalCommits} commits {conflicts > 0 && (<>· <span style={{ color: "#fbbf24" }}>{conflicts} conflict</span></>)}</span>
      </div>
      {active && (
        <span className="merge-bar-drop-hint">drop branch to add</span>
      )}
    </div>
  );
}

// ============================================================
// STACK VIEW (legacy, unused but kept for reference) — branches as full-width horizontal strips
// ============================================================
function StackView({
  columns, selected, hoveredId, onCommitClick, onHover,
  diffMode, onSetDiffMode, showFiles,
  historyWidth, onResizeHistory,
}) {
  // Stack reads top → bottom: tip first, base last.
  // Convention: lanes-view order is base-first (left), so reverse for stack.
  const stackOrder = [...columns].reverse();
  return (
    <div className="stacked-wrap">
      <ColWrap width={historyWidth} onResizeStart={onResizeHistory}>
        <HistoryColumn
          selected={selected}
          hoveredId={hoveredId}
          onCommitClick={onCommitClick}
          onHover={onHover}
        />
      </ColWrap>
      <div className="stacked-strips">
        {stackOrder.map((name, i) => {
          const color = window.BRANCH_COLORS[name] || "#3b82f6";
          const commits = window.COMMITS_BY_BRANCH[name] || [];
          const role = i === 0 ? "tip" : (i === stackOrder.length - 1 ? "base" : "stacked");
          return (
            <React.Fragment key={name}>
              <StackStrip
                branchName={name}
                color={color}
                commits={commits}
                role={role}
                selected={selected}
                hoveredId={hoveredId}
                onCommitClick={onCommitClick}
                onHover={onHover}
                diffMode={diffMode}
                onSetDiffMode={onSetDiffMode}
                showFiles={showFiles}
              />
              {i < stackOrder.length - 1 && (
                <div className="stack-arrow">
                  <svg width="12" height="14" viewBox="0 0 12 14">
                    <path d="M6 2v9M3 5l3-3 3 3" stroke="currentColor" strokeWidth="1.5" fill="none" strokeLinecap="round" strokeLinejoin="round"/>
                  </svg>
                  <span>stacked on</span>
                </div>
              )}
            </React.Fragment>
          );
        })}
      </div>
    </div>
  );
}

function StackStrip({ branchName, color, commits, role, selected, hoveredId, onCommitClick, onHover, diffMode, onSetDiffMode, showFiles }) {
  const bookmark = window.BOOKMARKS.find(b => b.name === branchName);
  const expandedCommit = selected?.source === branchName ? selected : null;
  return (
    <section
      className="stack-strip"
      style={{
        "--branch-color": color,
        ...laneShade(color),
        "--branch-color-soft": softTint(color, 0.08),
      }}
      data-screen-label={`Stack ${branchName}`}
    >
      <header className="stack-strip-header">
        <span className="role">{role}</span>
        <Icon name="branch" size={13}/>
        <span className="name">{branchName}</span>
        <div className="meta">
          {bookmark?.ahead  > 0 && <span className="pill">↑{bookmark.ahead}</span>}
          {bookmark?.current && <span className="pill">@</span>}
          <span className="pill">{commits.length} commits</span>
        </div>
      </header>
      <div className={"stack-strip-body " + (expandedCommit ? "expanded" : "")}>
        {commits.map((commit, idx) => {
          const isExpanded = expandedCommit?.changeId === commit.changeId;
          const isHighlight = selected?.changeId === commit.changeId && !isExpanded;
          const isHover = hoveredId === commit.changeId && !isHighlight && !isExpanded;
          return (
            <div
              key={branchName + "_" + commit.changeId + "_" + idx}
              className={
                "commit-card " +
                (isExpanded ? "expanded " : "") +
                (isHighlight ? "selected " : "") +
                (isHover ? "soft-highlight " : "") +
                (commit.isWorkingCopy ? "wc " : "")
              }
              onMouseEnter={() => onHover(commit.changeId)}
              onMouseLeave={() => onHover(null)}
              onClick={() => onCommitClick({ source: branchName, changeId: commit.changeId, commit })}
            >
              <div className="ccard-head">
                {Boolean(commit.isWorkingCopy || commit.isEmpty || commit.isMerge || commit.version || commit.hasConflict) && (
                  <div className="commit-tags">
                    {commit.isWorkingCopy && <span className="tag wc">@</span>}
                    {commit.isEmpty && <span className="tag empty">empty</span>}
                    {commit.isMerge && <span className="tag merge">merge</span>}
                    {commit.version && <span className="tag version">{commit.version}</span>}
                    {commit.hasConflict && <span className="tag conflict"><Icon name="conflict" size={10}/>conflict</span>}
                  </div>
                )}
                <div className="commit-subject">{commit.subject}</div>
                <div className="commit-foot">
                  <span className="item changeid">{commit.changeId}</span>
                  <span className="item"><Icon name="user" size={11}/>{commit.author.split(" ")[0]}</span>
                  <span className="item"><Icon name="calendar" size={11}/>{commit.date}</span>
                </div>
              </div>
              {isExpanded && (
                <CommitDetail
                  commit={commit}
                  branchColor={color}
                  diffMode={diffMode}
                  onSetDiffMode={onSetDiffMode}
                  showFiles={showFiles}
                />
              )}
            </div>
          );
        })}
      </div>
    </section>
  );
}

// ============================================================
// MERGE VIEW — branches side-by-side + bridge bar on top
// ============================================================
function MergeView({
  mergeBranches, setMergeBranches, dropOver, setDropOver,
  selected, hoveredId, onCommitClick, onHover, onClose,
  diffMode, onSetDiffMode, showFiles,
}) {
  const colors = mergeBranches.map(n => window.BRANCH_COLORS[n] || "#3b82f6");
  const bridgeStyle = {
    "--c1": colors[0] || "#3b82f6",
    "--c2": colors[1] || colors[0] || "#22c55e",
    "--c3": colors[2] || colors[1] || colors[0] || "#a855f7",
  };

  // Simulated "merge analysis" stats
  const totalCommits = mergeBranches.reduce((s, n) => s + (window.COMMITS_BY_BRANCH[n]?.length || 0), 0);
  const conflictCount = mergeBranches.some(n =>
    (window.COMMITS_BY_BRANCH[n] || []).some(c => c.hasConflict)
  ) ? 1 : 0;

  // Allow dragging in another branch from the BOOKMARKS
  const onBridgeDragOver = (e) => {
    e.preventDefault();
    setDropOver(true);
  };
  const onBridgeDragLeave = () => setDropOver(false);
  const onBridgeDrop = (e) => {
    e.preventDefault();
    const name = e.dataTransfer.getData("text/plain");
    setDropOver(false);
    if (name && !mergeBranches.includes(name) && window.BOOKMARKS.find(b => b.name === name)) {
      setMergeBranches(b => [...b, name]);
    }
  };

  return (
    <div style={{ flex: 1, display: "flex", flexDirection: "column", minHeight: 0, overflow: "hidden" }}>
      <div className="merge-bridge" style={bridgeStyle}>
        <div className="merge-bridge-title">
          <Icon name="merge" size={14}/>
          <span>Virtual merge</span>
        </div>
        <div className="merge-chips" onDragOver={onBridgeDragOver} onDragLeave={onBridgeDragLeave} onDrop={onBridgeDrop}>
          {mergeBranches.map(name => {
            const c = window.BRANCH_COLORS[name];
            return (
              <span
                key={name}
                className="merge-chip"
                style={{
                  "--chip-bg":     softTint(c, 0.15),
                  "--chip-border": softTint(c, 0.4),
                  "--chip-fg":     c,
                }}
              >
                <span style={{ width: 6, height: 6, borderRadius: "50%", background: c }}/>
                {name}
                <button className="x" onClick={() => onClose(name)} title="Remove from merge">×</button>
              </span>
            );
          })}
          <span
            className={"merge-drop " + (dropOver ? "over" : "")}
            onDragOver={onBridgeDragOver}
            onDragLeave={onBridgeDragLeave}
            onDrop={onBridgeDrop}
          >
            drop branch to add
          </span>
        </div>
        <div className="merge-stats">
          <div className="merge-stat">
            <span className={"v " + (conflictCount > 0 ? "warn" : "ok")}>{conflictCount}</span>
            <span>conflicts predicted</span>
          </div>
          <div className="merge-stat">
            <span className="v">{totalCommits}</span>
            <span>commits combined</span>
          </div>
          <div className="merge-stat">
            <span className="v">{mergeBranches.length}</span>
            <span>branches</span>
          </div>
        </div>
      </div>
      <div className="merge-columns-wrap">
        {mergeBranches.map(name => (
          <div key={name} className="col-wrap" style={{ width: 360 }}>
            <BranchColumn
              branchName={name}
              selected={selected}
              hoveredId={hoveredId}
              onCommitClick={onCommitClick}
              onHover={onHover}
              onClose={onClose}
              onDragStart={() => {}}
              onDragOver={() => {}}
              onDragEnd={() => {}}
              onDrop={() => {}}
              isDragging={false}
              diffMode={diffMode}
              onSetDiffMode={onSetDiffMode}
              showFiles={showFiles}
            />
          </div>
        ))}
      </div>
    </div>
  );
}

// ============================================================
// HOME DIALOG — IntelliJ-style project picker
// ============================================================
const STATUS_META = {
  clean:    { color: "#9ca3af", label: "clean" },
  dirty:    { color: "#facc15", label: "uncommitted changes" },
  ahead:    { color: "#4ade80", label: "ahead of remote" },
  behind:   { color: "#60a5fa", label: "behind remote" },
  diverged: { color: "#fb923c", label: "diverged" },
  conflict: { color: "#f87171", label: "conflict" },
  missing:  { color: "#71717a", label: "path missing" },
  syncing:  { color: "#a78bfa", label: "syncing" },
};

function flattenTree(nodes, parentPath = []) {
  // Return flat list of {node, depth, path:[ids]}
  const out = [];
  for (const n of nodes) {
    out.push({ node: n, depth: parentPath.length, path: [...parentPath, n.id] });
    if (n.kind === "group" && n.expanded && n.children) {
      out.push(...flattenTree(n.children, [...parentPath, n.id]));
    }
  }
  return out;
}
function flattenAll(nodes, parentPath = []) {
  // Same as flatten but ignores expanded state — used for search
  const out = [];
  for (const n of nodes) {
    out.push({ node: n, depth: parentPath.length, path: [...parentPath, n.id] });
    if (n.kind === "group" && n.children) {
      out.push(...flattenAll(n.children, [...parentPath, n.id]));
    }
  }
  return out;
}
function updateTreeNode(nodes, id, updater) {
  return nodes.map(n => {
    if (n.id === id) return updater(n);
    if (n.kind === "group" && n.children) {
      return { ...n, children: updateTreeNode(n.children, id, updater) };
    }
    return n;
  });
}

// Brand mark — Dry Brush enso (from Zanshin App Icon study #03)
function ZanshinMark({ size = 26 }) {
  return (
    <svg width={size} height={size} viewBox="0 0 256 256" aria-label="Zanshin">
      <defs>
        <linearGradient id="zm-paper" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stopColor="#f5ecd6"/>
          <stop offset="1" stopColor="#e6d7b2"/>
        </linearGradient>
        <radialGradient id="zm-vig" cx="0.5" cy="0.45" r="0.7">
          <stop offset="0.6" stopColor="#000" stopOpacity="0"/>
          <stop offset="1" stopColor="#7a623a" stopOpacity="0.2"/>
        </radialGradient>
      </defs>
      <rect width="256" height="256" rx="58" fill="url(#zm-paper)"/>
      <rect width="256" height="256" rx="58" fill="url(#zm-vig)"/>
      <ellipse cx="148" cy="53" rx="10" ry="8" fill="#1a1413" transform="rotate(60 148 53)"/>
      <path d="M 148 53 A 78 78 0 0 1 196 89"   stroke="#1a1413" strokeWidth="14" strokeLinecap="round" fill="none"/>
      <path d="M 196 89 A 78 78 0 0 1 203 148"  stroke="#1a1413" strokeWidth="12" strokeLinecap="round" fill="none"/>
      <path d="M 203 148 A 78 78 0 0 1 167 196" stroke="#1a1413" strokeWidth="10" strokeLinecap="round" fill="none"/>
      <path d="M 167 196 A 78 78 0 0 1 89 196"  stroke="#1a1413" strokeWidth="8"  strokeLinecap="round" fill="none"/>
      <path d="M 89 196 A 78 78 0 0 1 50 128"   stroke="#1a1413" strokeWidth="6"  strokeLinecap="round" fill="none"/>
      <path d="M 50 128 A 78 78 0 0 1 61 89"    stroke="#1a1413" strokeWidth="3.5" strokeLinecap="round" fill="none" opacity="0.85"/>
      <path d="M 61 89 A 78 78 0 0 1 92 60"     stroke="#1a1413" strokeWidth="2"  strokeLinecap="round" fill="none" opacity="0.6"/>
      <ellipse cx="98"  cy="57" rx="2"   ry="0.9" fill="#1a1413" transform="rotate(115 98 57)" opacity="0.7"/>
      <ellipse cx="108" cy="53" rx="1.6" ry="0.7" fill="#1a1413" transform="rotate(108 108 53)" opacity="0.5"/>
      <circle  cx="103" cy="55" r="0.9" fill="#1a1413" opacity="0.6"/>
      <ellipse cx="116" cy="51" rx="1.3" ry="0.6" fill="#1a1413" transform="rotate(102 116 51)" opacity="0.4"/>
      <circle  cx="112" cy="52" r="0.6" fill="#1a1413" opacity="0.3"/>
      <circle  cx="121" cy="50" r="0.5" fill="#1a1413" opacity="0.25"/>
      <circle cx="124" cy="44" r="9.5" fill="#bf2c2a"/>
      <circle cx="124" cy="44" r="9.5" fill="#000" opacity="0.15"/>
    </svg>
  );
}

function HomeDialog({ tree, setTree, activeProjectId, onOpenProject, onClose, canClose }) {
  const [query, setQuery] = useState("");
  const [selectedId, setSelectedId] = useState(activeProjectId);
  const [dragOver, setDragOver] = useState(false);

  const q = query.trim().toLowerCase();
  const visible = useMemo(() => {
    if (!q) return flattenTree(tree);
    // search: show all projects + groups whose name OR path matches
    return flattenAll(tree).filter(({ node }) => {
      if (node.kind === "project") {
        return node.name.toLowerCase().includes(q) || (node.path || "").toLowerCase().includes(q);
      }
      return node.name.toLowerCase().includes(q);
    });
  }, [tree, q]);

  const toggleGroup = (id) => {
    setTree(t => updateTreeNode(t, id, (n) => ({ ...n, expanded: !n.expanded })));
  };

  // ── Drag-drop directory adoption ────────────────────────────
  const onDragOver = (e) => {
    if ([...(e.dataTransfer.types || [])].includes("Files")) {
      e.preventDefault();
      setDragOver(true);
    }
  };
  const onDragLeave = (e) => {
    if (e.currentTarget === e.target) setDragOver(false);
  };
  const onDrop = (e) => {
    e.preventDefault();
    setDragOver(false);
    // Demo: would resolve dropped paths via the host. We fake-add an entry.
    const fakeName = "imported-" + Math.floor(Math.random() * 1000);
    const newProj = {
      id: "p_" + fakeName, kind: "project", name: fakeName,
      path: "~/code/" + fakeName, status: "clean", branch: "main",
      ahead: 0, behind: 0, lastOpened: "just added",
    };
    setTree(t => [...t, newProj]);
  };

  // Keyboard: enter to open
  const onKeyDown = (e) => {
    if (e.key === "Enter" && selectedId) {
      const all = flattenAll(tree);
      const sel = all.find(x => x.node.id === selectedId);
      if (sel && sel.node.kind === "project") onOpenProject(sel.node);
    }
    if (e.key === "Escape" && canClose) onClose();
  };

  return (
    <div className="home-overlay" onMouseDown={(e) => { if (e.target === e.currentTarget && canClose) onClose(); }}>
      <div
        className={"home-dialog " + (dragOver ? "drag-over " : "")}
        onKeyDown={onKeyDown}
        tabIndex={-1}
        onDragOver={onDragOver}
        onDragLeave={onDragLeave}
        onDrop={onDrop}
      >
        {/* Side panel — IntelliJ-style nav */}
        <aside className="home-side">
          <div className="home-side-brand">
            <ZanshinMark size={32}/>
            <div>
              <div className="home-side-brand-name">Zanshin</div>
              <div className="home-side-brand-sub">jj client · v0.24.0</div>
            </div>
          </div>
          <nav className="home-side-nav">
            <button className="home-side-item active"><Icon name="folderOpen" size={14}/>Projects</button>
            <button className="home-side-item"><Icon name="cloud" size={14}/>Remotes</button>
            <button className="home-side-item"><Icon name="settings" size={14}/>Settings</button>
          </nav>
          <div className="home-side-foot">
            <div className="home-side-foot-label">Signed in</div>
            <div className="home-side-foot-user">
              <span className="home-side-avatar">A</span>
              <div>
                <div>Alice Sralph</div>
                <div className="home-side-foot-mail">alice@dasralph.de</div>
              </div>
            </div>
          </div>
        </aside>

        {/* Main pane */}
        <div className="home-main">
          <header className="home-header">
            <h2>Projects</h2>
            {canClose && (
              <button className="home-close" onClick={onClose} title="Close (Esc)">
                <Icon name="close" size={12}/>
              </button>
            )}
          </header>

          <div className="home-toolbar">
            <div className="home-search">
              <Icon name="search" size={13}/>
              <input
                placeholder="Search projects, paths…"
                value={query}
                onChange={(e) => setQuery(e.target.value)}
                autoFocus
              />
              {query && <button className="home-search-clear" onClick={() => setQuery("")}><Icon name="close" size={10}/></button>}
            </div>
            <div className="home-toolbar-actions">
              <button className="home-action primary"><Icon name="plus" size={12}/>Add directory</button>
              <button className="home-action"><Icon name="cloud" size={13}/>Clone from remote</button>
              <button className="home-action ghost"><Icon name="folderPlus" size={13}/>New group</button>
            </div>
          </div>

          <div className="home-list" role="tree">
            {visible.length === 0 && (
              <div className="home-empty">No projects match "{query}"</div>
            )}
            {visible.map(({ node, depth }) => {
              if (node.kind === "group") {
                const count = (node.children || []).filter(c => c.kind === "project").length;
                const subCount = (node.children || []).filter(c => c.kind === "group").length;
                return (
                  <div
                    key={node.id}
                    className={"home-row group " + (node.expanded ? "expanded " : "") + (selectedId === node.id ? "selected " : "")}
                    style={{ "--depth": depth }}
                    onClick={() => { setSelectedId(node.id); toggleGroup(node.id); }}
                    role="treeitem"
                    aria-expanded={node.expanded}
                  >
                    <span className="home-row-indent" aria-hidden="true"/>
                    <span className={"home-row-chev " + (node.expanded ? "open" : "")}>
                      <Icon name="chevronRight" size={12}/>
                    </span>
                    <Icon name={node.expanded ? "folderOpen" : "folder"} size={14} className="home-row-icon"/>
                    <span className="home-row-name">{node.name}</span>
                    <span className="home-row-count">{count}{subCount > 0 && ` · ${subCount} group${subCount === 1 ? "" : "s"}`}</span>
                  </div>
                );
              }
              // project
              const s = STATUS_META[node.status] || STATUS_META.clean;
              const isActive = activeProjectId === node.id;
              return (
                <div
                  key={node.id}
                  className={"home-row project " + (selectedId === node.id ? "selected " : "") + (isActive ? "active-project " : "") + (node.status === "missing" ? "missing " : "")}
                  style={{ "--depth": depth }}
                  onClick={() => setSelectedId(node.id)}
                  onDoubleClick={() => onOpenProject(node)}
                  role="treeitem"
                  title={node.path}
                >
                  <span className="home-row-indent" aria-hidden="true"/>
                  <span className="home-row-chev"/>
                  <span className="home-row-status" style={{ background: s.color }} title={s.label}/>
                  <div className="home-row-text">
                    <div className="home-row-line1">
                      <span className="home-row-name">{node.name}</span>
                      {isActive && <span className="home-row-pill open">open</span>}
                      {node.branch && node.branch !== "—" && (
                        <span className="home-row-branch"><Icon name="branch" size={10}/>{node.branch}</span>
                      )}
                      {node.ahead > 0 && <span className="home-row-meta ahead">↑{node.ahead}</span>}
                      {node.behind > 0 && <span className="home-row-meta behind">↓{node.behind}</span>}
                    </div>
                    <div className="home-row-line2">
                      <span className="home-row-path">{node.path}</span>
                      <span className="home-row-sep">·</span>
                      <span className="home-row-when">{node.lastOpened}</span>
                    </div>
                  </div>
                  <button className="home-row-more" onClick={(e) => e.stopPropagation()} title="More…">
                    <Icon name="more" size={13}/>
                  </button>
                </div>
              );
            })}
          </div>

          {/* Drop hint banner — always visible at the bottom */}
          <div className={"home-drop-hint " + (dragOver ? "active " : "")}>
            <Icon name="download" size={13}/>
            <span>{dragOver ? "Drop to add directory" : "Drop a folder here to add it as a project"}</span>
          </div>
        </div>
      </div>
    </div>
  );
}

// ============================================================
// APP
// ============================================================
const DEFAULT_WIDTHS = {
  __history__: 420,
  "main": 340,
  "develop": 340,
  "feature/new-ui": 340,
  "fix/ios-keyboard": 320,
  "exp/riverpod-3": 320,
};

function App() {
  const [t, setTweak] = useTweaks({ ...TWEAK_DEFAULTS, ...URL_TWEAKS });
  const [activeProject, setActiveProject] = useState("flutter-app");
  const [homeTree, setHomeTree] = useState(() => window.HOME_TREE);
  const [homeOpen, setHomeOpen] = useState(!URLQ.has("embed")); // opens automatically on app start
  const [activeProjectId, setActiveProjectId] = useState(window.ACTIVE_PROJECT_ID || "p_myapp");
  // Slot-based model: each slot holds 1+ branches (stacked vertically).
  // mergeGroup ID groups adjacent slots into a virtual merge cluster.
  const [slots, setSlots] = useState(() =>
    window.OPEN_COLUMNS.map((b, i) => ({ id: "s" + (i + 1), branches: [b], mergeGroup: null }))
  );
  const [columnWidths, setColumnWidths] = useState({ ...DEFAULT_WIDTHS });
  const [selected, setSelected] = useState(null);
  // checkedOut: which commit is the active working copy (`@`). Initialized from data.
  const initialCheckedOut = useMemo(() => {
    for (const b of (window.BOOKMARKS || [])) {
      const list = window.COMMITS_BY_BRANCH[b.name] || [];
      const c = list.find(x => x.isWorkingCopy);
      if (c) return { source: b.name, changeId: c.changeId, commit: c };
    }
    return null;
  }, []);
  const [checkedOut, setCheckedOut] = useState(initialCheckedOut);
  // editMeta: when true, the open detail panel renders the EditPanel (subject/desc editor).
  const [editMeta, setEditMeta] = useState(false);
  const [hoveredId, setHoveredId] = useState(null);
  const [dragName, setDragName] = useState(null);     // branch being dragged
  const [dragSlot, setDragSlot] = useState(null);     // slot being reordered
  const [dropTarget, setDropTarget] = useState(null); // { kind: 'slot-top'|'slot-bot'|'slot-between'|'slot-edge'|'merge', slotId?, idx?, side? }
  const [flyout, setFlyout] = useState(null);
  const flyoutTimer = useRef(null);
  const [leftPanel, setLeftPanel] = useState("history"); // history | branches | workstream | reviews | undo

  // Flatten branches for sidebar "open" highlighting + tags
  const openBranches = useMemo(() => slots.flatMap(s => s.branches), [slots]);

  // hover/click handler for flyout
  const handleFlyoutSet = (id, source) => {
    if (flyoutTimer.current) { clearTimeout(flyoutTimer.current); flyoutTimer.current = null; }
    if (source === "click") {
      setFlyout(prev => prev === id ? null : id);
    } else {
      setFlyout(id);
    }
  };
  const onFlyoutLeave = () => {
    if (flyoutTimer.current) clearTimeout(flyoutTimer.current);
    flyoutTimer.current = setTimeout(() => setFlyout(null), 600);
  };
  const onFlyoutEnter = () => {
    if (flyoutTimer.current) { clearTimeout(flyoutTimer.current); flyoutTimer.current = null; }
  };

  // Theme (light / dark / system)
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

  // When the selected commit changes, exit metadata edit mode.
  useEffect(() => { setEditMeta(false); }, [selected?.changeId]);

  // Esc: exits metadata edit first, then closes the detail panel.
  useEffect(() => {
    const h = (e) => {
      if (e.key !== "Escape") return;
      if (editMeta) { setEditMeta(false); return; }
      if (selected) setSelected(null);
    };
    window.addEventListener("keydown", h);
    return () => window.removeEventListener("keydown", h);
  }, [selected, editMeta]);

  // jj edit <change> — move the working copy to this commit.
  const onCheckout = useCallback((data) => {
    setCheckedOut(data);
  }, []);
  const onStartEditMeta = useCallback(() => setEditMeta(true), []);
  const onCancelEditMeta = useCallback(() => setEditMeta(false), []);

  const toggleColumn = (name) => {
    setSlots(prev => {
      const isOpen = prev.some(s => s.branches.includes(name));
      if (isOpen) {
        if (selected?.source === name) setSelected(null);
        // Remove from wherever it lives; drop now-empty slots.
        return prev.flatMap(slot => {
          const next = slot.branches.filter(b => b !== name);
          return next.length ? [{ ...slot, branches: next }] : [];
        });
      }
      // Add as new slot at the end.
      return [...prev, { id: "s_" + name + "_" + Date.now(), branches: [name], mergeGroup: null }];
    });
  };

  const closeBranch = (name) => {
    setSlots(prev => prev.flatMap(slot => {
      const next = slot.branches.filter(b => b !== name);
      return next.length ? [{ ...slot, branches: next }] : [];
    }));
    if (selected?.source === name) setSelected(null);
  };

  // Insert a branch into an existing slot at a position (top/bottom/index)
  const addBranchToSlot = (slotId, branchName, position = "bottom") => {
    setSlots(prev => {
      const cleaned = prev.flatMap(slot => {
        const next = slot.branches.filter(b => b !== branchName);
        return next.length ? [{ ...slot, branches: next }] : [];
      });
      return cleaned.map(slot => {
        if (slot.id !== slotId) return slot;
        const idx = position === "top" ? 0 :
                    position === "bottom" ? slot.branches.length :
                    typeof position === "number" ? position : slot.branches.length;
        return { ...slot, branches: [...slot.branches.slice(0, idx), branchName, ...slot.branches.slice(idx)] };
      });
    });
  };

  // Insert a NEW slot at index, possibly with a branch
  const insertSlotAt = (index, branchName) => {
    setSlots(prev => {
      const cleaned = prev.flatMap(slot => {
        const next = slot.branches.filter(b => b !== branchName);
        return next.length ? [{ ...slot, branches: next }] : [];
      });
      const newSlot = { id: "s_" + branchName + "_" + Date.now(), branches: [branchName], mergeGroup: null };
      return [...cleaned.slice(0, index), newSlot, ...cleaned.slice(index)];
    });
  };

  // Move slot (drag-reorder)
  const moveSlot = (fromId, toIdx) => {
    setSlots(prev => {
      const fromIdx = prev.findIndex(s => s.id === fromId);
      if (fromIdx === -1) return prev;
      const item = prev[fromIdx];
      const without = prev.filter((_, i) => i !== fromIdx);
      const adjustedIdx = toIdx > fromIdx ? toIdx - 1 : toIdx;
      return [...without.slice(0, adjustedIdx), item, ...without.slice(adjustedIdx)];
    });
  };

  // Toggle merge with right neighbor: assign both slots the same mergeGroup
  const toggleMergeWithRight = (slotId) => {
    setSlots(prev => {
      const idx = prev.findIndex(s => s.id === slotId);
      if (idx === -1 || idx >= prev.length - 1) return prev;
      const me = prev[idx];
      const right = prev[idx + 1];
      // If they share a group, break me out of it
      if (me.mergeGroup && me.mergeGroup === right.mergeGroup) {
        return prev.map((s, i) => i === idx ? { ...s, mergeGroup: null } : s);
      }
      // Otherwise: merge them into one group
      const group = me.mergeGroup || right.mergeGroup || ("m_" + Date.now());
      return prev.map((s, i) => {
        if (i === idx || i === idx + 1) return { ...s, mergeGroup: group };
        return s;
      });
    });
  };

  // ── Resize ────────────────────────────────
  const startResize = (e, key) => {
    e.preventDefault();
    const startX = e.clientX;
    const startW = columnWidths[key] || 360;
    const onMove = (ev) => {
      const newW = Math.max(240, Math.min(900, startW + ev.clientX - startX));
      setColumnWidths(w => ({ ...w, [key]: newW }));
    };
    const onUp = () => {
      window.removeEventListener("pointermove", onMove);
      window.removeEventListener("pointerup", onUp);
    };
    window.addEventListener("pointermove", onMove);
    window.addEventListener("pointerup", onUp);
  };

  // Build clusters (consecutive slots with same mergeGroup get rendered together)
  const clusters = useMemo(() => {
    const out = [];
    let i = 0;
    while (i < slots.length) {
      const s = slots[i];
      if (s.mergeGroup) {
        const grp = [];
        while (i < slots.length && slots[i].mergeGroup === s.mergeGroup) {
          grp.push(slots[i]);
          i++;
        }
        out.push({ kind: "merge", group: s.mergeGroup, slots: grp });
      } else {
        out.push({ kind: "solo", slots: [s] });
        i++;
      }
    }
    return out;
  }, [slots]);

  const onBranchDragStart = (e, name) => {
    e.dataTransfer.setData("text/plain", name);
    e.dataTransfer.effectAllowed = "move";
    setDragName(name);
  };

  const onSlotHeaderDragStart = (e, slotId) => {
    e.dataTransfer.setData("application/x-slot", slotId);
    e.dataTransfer.effectAllowed = "move";
    setDragSlot(slotId);
  };

  const onDropTarget = (e, target) => {
    e.preventDefault();
    setDropTarget(null);
    setDragName(null);
    setDragSlot(null);

    const name = e.dataTransfer.getData("text/plain");
    const slotId = e.dataTransfer.getData("application/x-slot");

    if (slotId) {
      // Slot reorder
      if (target.kind === "slot-edge") {
        moveSlot(slotId, target.idx);
      }
      return;
    }

    if (name && window.BOOKMARKS.find(b => b.name === name)) {
      if (target.kind === "slot-top")      addBranchToSlot(target.slotId, name, "top");
      else if (target.kind === "slot-bot") addBranchToSlot(target.slotId, name, "bottom");
      else if (target.kind === "slot-between") addBranchToSlot(target.slotId, name, target.idx);
      else if (target.kind === "slot-edge") insertSlotAt(target.idx, name);
      else if (target.kind === "merge")   {
        // Add to merge group as a new slot
        const groupSlots = slots.filter(s => s.mergeGroup === target.group);
        const lastIdxInGroup = slots.findIndex(s => s === groupSlots[groupSlots.length - 1]);
        // Insert after the last slot in this merge group
        setSlots(prev => {
          const cleaned = prev.flatMap(slot => {
            const next = slot.branches.filter(b => b !== name);
            return next.length ? [{ ...slot, branches: next }] : [];
          });
          const insertIdx = cleaned.findIndex(s => s.mergeGroup === target.group) + groupSlots.length;
          const newSlot = { id: "s_" + name + "_" + Date.now(), branches: [name], mergeGroup: target.group };
          return [...cleaned.slice(0, insertIdx), newSlot, ...cleaned.slice(insertIdx)];
        });
      }
    }
  };
  const onDropOver = (e, target) => {
    e.preventDefault();
    e.dataTransfer.dropEffect = "move";
    setDropTarget(target);
  };
  const onDragLeaveAny = () => setDropTarget(null);
  const onDragEnd = () => {
    setDragName(null);
    setDragSlot(null);
    setDropTarget(null);
  };

  const dragActive = !!(dragName || dragSlot);

  const activeProjectNode = useMemo(() => {
    const all = flattenAll(homeTree);
    return all.find(x => x.node.id === activeProjectId)?.node || null;
  }, [homeTree, activeProjectId]);

  return (
    <WindowChrome theme={t.theme} onSetTheme={(v) => setTweak("theme", v)}>
      <div className="app-grid" onMouseLeave={() => { if (flyout) onFlyoutLeave(); }}>
        <NavRail
          activePanel={leftPanel}
          onSelectPanel={setLeftPanel}
          onOpenHome={() => setHomeOpen(true)}
          homeOpen={homeOpen}
          activeProjectName={activeProjectNode?.name}
        />
        <main className="main-area">
          <GraphWorkspace t={t} setTweak={setTweak} leftPanel={leftPanel} onCloseLeft={() => setLeftPanel("history")}/>
        </main>
      </div>
      <StatusBar openCount={slots.length}/>
      <button className="help-fab" title="Help">?</button>

      {flyout && (
        <Flyout
          top={82}
          onClose={() => setFlyout(null)}
          onMouseEnter={onFlyoutEnter}
          onMouseLeave={onFlyoutLeave}
        >
          {flyout === "branches" && (
            <BranchesFlyout
              openColumns={openBranches}
              onToggle={(name) => { toggleColumn(name); }}
              onClose={() => setFlyout(null)}
            />
          )}
          {flyout === "workstream" && <PlaceholderFlyout title="Workstreams" onClose={() => setFlyout(null)}/>}
          {flyout === "reviews"    && <PlaceholderFlyout title="Reviews"     onClose={() => setFlyout(null)}/>}
          {flyout === "undo"       && <PlaceholderFlyout title="Undo Timeline" onClose={() => setFlyout(null)}/>}
        </Flyout>
      )}

      <TweaksPanel title="Tweaks">
        <TweakSection label="Display"/>
        <TweakRadio
          label="Density" value={t.density}
          onChange={v => setTweak("density", v)}
          options={[
            { value: "compact",  label: "Compact" },
            { value: "balanced", label: "Balanced" },
            { value: "comfy",    label: "Comfy" },
          ]}
        />
        <TweakSection label="Graph"/>
        <TweakRadio
          label="Bookmark labels" value={t.bookmarkLabels}
          onChange={v => setTweak("bookmarkLabels", v)}
          options={[{ value: "legend", label: "Always" }, { value: "hover", label: "On hover" }]}
        />
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
        <TweakRadio
          label="Default mode" value={t.diffMode}
          onChange={v => setTweak("diffMode", v)}
          options={[{ value: "inline", label: "Inline" }, { value: "split", label: "Split" }]}
        />
        <TweakToggle label="Show changed files" value={t.showFiles} onChange={v => setTweak("showFiles", v)}/>
      </TweaksPanel>

      {homeOpen && (
        <HomeDialog
          tree={homeTree}
          setTree={setHomeTree}
          activeProjectId={activeProjectId}
          onOpenProject={(p) => { setActiveProjectId(p.id); setHomeOpen(false); }}
          onClose={() => setHomeOpen(false)}
          canClose={true}
        />
      )}
    </WindowChrome>
  );
}

Object.assign(window, { Icon, CommitDetail, EditPanel, SidePanel, LeftPanel });
ReactDOM.createRoot(document.getElementById("root")).render(<App/>);
