/* global React, ReactDOM */
const { useState, useEffect } = React;

// ============================================================
// Reused Icon set (kept in sync with app.jsx)
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
};
const Icon = ({ name, size = 16, className = "", style = {} }) => (
  <svg width={size} height={size} viewBox="0 0 16 16" className={className} style={{ flexShrink: 0, ...style }}>
    {I[name]}
  </svg>
);

// ============================================================
// TOKENS
// ============================================================
const CANVAS = [
  { name: "canvas · night", token: "--canvas", role: "window",
    value: "radial-gradient(115% 85% at 10% -12%, rgba(96,120,178,0.24), rgba(96,120,178,0) 62%), linear-gradient(165deg,#1a2038,#12162a 68%,#0e1224)" },
  { name: "canvas · day", token: "--canvas", role: "window",
    value: "radial-gradient(115% 85% at 10% -12%, rgba(220,168,91,0.20), rgba(220,168,91,0) 62%), linear-gradient(165deg,#f7f4f0,#f0ece7 68%,#e8e3dd)" },
];
const SURFACES = [
  { name: "background",  token: "--bg",          dark: "#08090d", light: "#cbc7c2", role: "desktop" },
  { name: "window tint", token: "--bg-window",   dark: "rgba(255,255,255,0.03)", light: "rgba(255,253,250,0.55)", role: "chrome" },
  { name: "sidebar",     token: "--bg-sidebar",  dark: "rgba(255,255,255,0.03)", light: "rgba(255,253,250,0.58)", role: "rail" },
  { name: "card",        token: "--bg-card",     dark: "rgba(255,255,255,0.045)", light: "rgba(255,253,250,0.72)", role: "card" },
  { name: "card-2",      token: "--bg-card-2",   dark: "rgba(255,255,255,0.075)", light: "rgba(58,46,34,0.06)", role: "hover" },
  { name: "elevated",    token: "--bg-elevated", dark: "#1c2138", light: "#fffdfa", role: "modal" },
  { name: "history",     token: "--bg-history",  dark: "rgba(255,255,255,0.015)", light: "rgba(255,253,250,0.30)", role: "canvas" },
];
const BORDERS = [
  { name: "border",        token: "--border",        dark: "rgba(255,255,255,0.07)", light: "rgba(58,46,34,0.10)", role: "subtle" },
  { name: "border-strong", token: "--border-strong", dark: "rgba(255,255,255,0.14)", light: "rgba(58,46,34,0.20)", role: "strong" },
];
const TEXT_COLORS = [
  { name: "text",       token: "--text",       dark: "#e7e9f2", light: "#2c2a33", role: "primary" },
  { name: "text-muted", token: "--text-muted", dark: "#a4abc4", light: "#5f5a55", role: "secondary" },
  { name: "text-dim",   token: "--text-dim",   dark: "#7e86a1", light: "#7a736c", role: "tertiary" },
  { name: "text-faint", token: "--text-faint", dark: "#5c6480", light: "#a49c94", role: "labels" },
];
const SEMANTIC = [
  { name: "accent",  token: "--accent",  hex: "#3b82f6", role: "interactive" },
  { name: "gold",    token: "--gold",    hex: "#dca85b", role: "status / brand" },
  { name: "add",     token: "--add",     hex: "#4ade80", role: "diff add"      },
  { name: "add-bg",  token: "--add-bg",  hex: "rgba(74,222,128,0.13)", role: "diff add bg" },
  { name: "rem",     token: "--rem",     hex: "#f87171", role: "diff remove"   },
  { name: "rem-bg",  token: "--rem-bg",  hex: "rgba(248,113,113,0.13)", role: "diff remove bg" },
  { name: "hunk",    token: "--hunk",    hex: "#60a5fa", role: "hunk header"   },
];
const BRANCH_LANES = [
  { name: "main",            hex: "#3b82f6" },
  { name: "develop",         hex: "#22c55e" },
  { name: "feature/new-ui",  hex: "#a855f7" },
  { name: "fix/ios-keyboard",hex: "#f59e0b" },
  { name: "exp/riverpod-3",  hex: "#06b6d4" },
];

const TYPE_SCALE = [
  { name: "Display",      size: 36,   weight: 700, use: "page hero" },
  { name: "Section H2",   size: 22,   weight: 600, use: "section titles" },
  { name: "Heading H3",   size: 14,   weight: 600, use: "panel headers" },
  { name: "Body",         size: 13,   weight: 400, use: "default UI text" },
  { name: "Body small",   size: 12.5, weight: 400, use: "rows, branches" },
  { name: "Caption",      size: 12,   weight: 400, use: "secondary meta" },
  { name: "Label small",  size: 11,   weight: 500, use: "pills, tags" },
  { name: "Eyebrow",      size: 10,   weight: 600, use: "uppercase labels" },
  { name: "Mono",         size: 11,   weight: 400, use: "change-ids, hashes", mono: true },
  { name: "Mono small",   size: 10.5, weight: 400, use: "metadata", mono: true },
];

const SPACING = [
  { name: "1",  px: 2 },  { name: "2", px: 4 },
  { name: "3",  px: 6 },  { name: "4", px: 8 },
  { name: "5",  px: 10 }, { name: "6", px: 12 },
  { name: "7",  px: 14 }, { name: "8", px: 16 },
  { name: "9",  px: 18 }, { name: "10", px: 22 },
  { name: "11", px: 28 }, { name: "12", px: 36 },
];
const RADII = [
  { name: "xs",  px: 3 },
  { name: "sm",  px: 5 },
  { name: "md",  px: 6 },
  { name: "lg",  px: 8 },
  { name: "xl",  px: 10 },
  { name: "2xl", px: 12 },
  { name: "pill",px: 999, label: "999 / pill" },
];

const DENSITIES = [
  { id: "compact",  rowPad: "8px 11px",  gap: "4px",  font: "12.5px", commitPad: "8px" },
  { id: "balanced", rowPad: "11px 13px", gap: "7px",  font: "13px",   commitPad: "11px" },
  { id: "comfy",    rowPad: "14px 15px", gap: "11px", font: "13.5px", commitPad: "14px" },
];

const MOTION = [
  { name: "Standard transition", val: "120ms",                       use: "color, background, opacity changes" },
  { name: "Slide-in",            val: "240ms cubic-bezier(.32,.72,0,1)", use: "detail panel reveal" },
  { name: "Auto-scroll",         val: "smooth",                      use: "history → selected commit" },
];

const SHADOWS = [
  { name: "Flyout",   val: "0 12px 40px rgba(0,0,0,0.5)", use: "popovers, command palette" },
  { name: "Inset hairline", val: "inset 0 0 0 1px rgba(255,255,255,0.04)", use: "elevated card edge" },
];

// ============================================================
// Sidebar nav
// ============================================================
const SECTIONS = [
  { id: "foundations", label: "Foundations", group: true },
  { id: "colors",      label: "Colors" },
  { id: "typography",  label: "Typography" },
  { id: "spacing",     label: "Spacing & sizing" },
  { id: "radii",       label: "Radii" },
  { id: "elevation",   label: "Elevation & motion" },
  { id: "density",     label: "Density" },
  { id: "themes",      label: "Themes" },

  { id: "components",  label: "Components", group: true },
  { id: "buttons",     label: "Buttons" },
  { id: "rail",        label: "Activity rail" },
  { id: "branches",    label: "Branches" },
  { id: "tags",        label: "Tags & badges" },
  { id: "inputs",      label: "Inputs" },
  { id: "kbd",         label: "Keyboard" },
  { id: "diff",        label: "Diff view" },
  { id: "commit",      label: "Commit card" },
  { id: "status",      label: "Status bar" },

  { id: "assets",      label: "Assets", group: true },
  { id: "iconography", label: "Iconography" },
];

function DSNav({ active }) {
  return (
    <aside className="ds-nav">
      <div className="ds-nav-brand">
        <span className="ds-nav-brand-mark">Z</span>
        <span>
          Zanshin
          <span className="ds-nav-brand-sub">Design system v0.1</span>
        </span>
      </div>
      <ul>
        {SECTIONS.map(s => {
          if (s.group) {
            return <li key={s.id} className="ds-nav-group">{s.label}</li>;
          }
          return (
            <li key={s.id}>
              <a href={"#" + s.id} className={active === s.id ? "active" : ""}>{s.label}</a>
            </li>
          );
        })}
      </ul>
    </aside>
  );
}

// ============================================================
// Reusable bits
// ============================================================
function SectionHead({ id, title, sub }) {
  return (
    <>
      <div className="ds-section-h">
        <h2>{title}</h2>
        <a className="ds-anchor" href={"#" + id}>#{id}</a>
      </div>
      {sub && <p className="ds-section-sub">{sub}</p>}
    </>
  );
}

function SwatchCard({ name, role, token, value }) {
  const isTransparent = typeof value === "string" && value.startsWith("rgba");
  return (
    <div className="ds-swatch">
      <div
        className={"ds-swatch-chip " + (isTransparent ? "ds-checker" : "")}
        style={{ "--chip": value }}
      />
      <div className="ds-swatch-body">
        <div className="ds-swatch-name">
          <span>{name}</span>
          {role && <span className="ds-role">{role}</span>}
        </div>
        <div className="ds-swatch-token">{token}</div>
        <div className="ds-swatch-value">{value}</div>
      </div>
    </div>
  );
}

// ============================================================
// SECTIONS
// ============================================================
function ColorsSection() {
  return (
    <section id="colors" className="ds-section">
      <SectionHead
        id="colors"
        title="Colors"
        sub="A near-monochrome dark base lets branch colors and diff signals carry meaning. Light mode flips the surface stack but keeps semantic and lane colors identical."
      />

      <div className="ds-sub-h">Window canvas — 2 statische Shader, kein Blur</div>
      <div className="ds-swatch-grid">
        {CANVAS.map(c => <SwatchCard key={c.name} name={c.name} role={c.role} token={c.token} value={c.value}/>)}
      </div>

      <div className="ds-sub-h">Surfaces (dark)</div>
      <div className="ds-swatch-grid">
        {SURFACES.map(c => <SwatchCard key={c.token} {...c} value={c.dark}/>)}
      </div>

      <div className="ds-sub-h">Surfaces (light)</div>
      <div className="ds-swatch-grid">
        {SURFACES.map(c => <SwatchCard key={c.token + "_l"} {...c} value={c.light}/>)}
      </div>

      <div className="ds-sub-h">Borders</div>
      <div className="ds-swatch-grid">
        {BORDERS.map(c => <SwatchCard key={c.token} {...c} value={c.dark}/>)}
      </div>

      <div className="ds-sub-h">Text</div>
      <div className="ds-swatch-grid">
        {TEXT_COLORS.map(c => <SwatchCard key={c.token} {...c} value={c.dark}/>)}
      </div>

      <div className="ds-sub-h">Semantic & diff</div>
      <div className="ds-swatch-grid">
        {SEMANTIC.map(c => <SwatchCard key={c.token} name={c.name} role={c.role} token={c.token} value={c.hex}/>)}
      </div>

      <div className="ds-sub-h">Branch lane palette</div>
      <p className="ds-section-sub" style={{ marginBottom: 14 }}>
        Each open branch is assigned a fixed hue used for its lane in the graph, header band, pill, and selection rings. Limit to 5–6 simultaneous lanes.
      </p>
      <div className="ds-lanes">
        {BRANCH_LANES.map(l => (
          <div key={l.name} className="ds-lane" style={{ "--lane": l.hex }}>
            <div className="ds-lane-name">{l.name}</div>
            <div className="ds-lane-hex">{l.hex}</div>
          </div>
        ))}
      </div>

      <div className="ds-callout">
        Branch colors are tinted to soft backgrounds via <span className="ds-inline-code">softTint(hex, alpha)</span> (typically 0.08–0.18) for surfaces; the raw hex is reserved for graph nodes, dots and headers.
      </div>
    </section>
  );
}

function TypographySection() {
  return (
    <section id="typography" className="ds-section">
      <SectionHead
        id="typography"
        title="Typography"
        sub="A tight two-family stack: Inter for UI, JetBrains Mono for any identifier you might copy-paste — change-ids, file paths, diff content, keyboard shortcuts."
      />

      <div className="ds-font-cards">
        <div className="ds-font-card">
          <div className="label">Sans · UI</div>
          <div className="name">Inter</div>
          <div className="specimen">Aa Bb 1234</div>
          <div className="stack">--font-sans · "Inter", -apple-system, "Segoe UI", system-ui, sans-serif</div>
        </div>
        <div className="ds-font-card">
          <div className="label">Mono · Identifiers</div>
          <div className="name mono">JetBrains Mono</div>
          <div className="specimen mono">Aa 0o &lt;/&gt;</div>
          <div className="stack">--font-mono · "JetBrains Mono", "SF Mono", "Menlo", "Ubuntu Mono", monospace</div>
        </div>
      </div>

      <div className="ds-sub-h">Type scale</div>
      <div className="ds-type-table">
        <div className="ds-type-row head">
          <div>Size</div><div>Weight</div><div>Name</div><div>Use</div><div>Sample</div>
        </div>
        {TYPE_SCALE.map(t => (
          <div key={t.name} className="ds-type-row">
            <div className="col-size">{t.size}px</div>
            <div className="col-weight">{t.weight}</div>
            <div className="col-name">{t.name}</div>
            <div className="col-use">{t.use}</div>
            <div
              className={"col-sample " + (t.mono ? "mono" : "")}
              style={{ "--smp": t.size + "px", "--w": t.weight }}
            >
              {t.mono ? "feat/new-ui · k7xq9p2m" : "The quick brown fox"}
            </div>
          </div>
        ))}
      </div>
    </section>
  );
}

function SpacingSection() {
  return (
    <section id="spacing" className="ds-section">
      <SectionHead
        id="spacing"
        title="Spacing & sizing"
        sub="Spacing follows a 2-px micro-step scale up to 14, then 22 / 28 / 36 for layout. Most internal padding lands between 6 and 14."
      />

      <div className="ds-sub-h">Spacing scale</div>
      <div className="ds-token-grid">
        {SPACING.map(s => (
          <div key={s.name} className="ds-token">
            <div className="ds-token-vis">
              <div className="bar" style={{ "--w": s.px + "px" }}/>
            </div>
            <div>
              <div className="ds-token-name">space-{s.name}</div>
              <div className="ds-token-value">{s.px}px</div>
            </div>
          </div>
        ))}
      </div>

      <div className="ds-sub-h">Common sizes</div>
      <div className="ds-token-grid">
        {[
          { name: "Window header",  v: "44px",  note: "fixed" },
          { name: "Activity item",  v: "48px",  note: "rail row height" },
          { name: "Activity rail",  v: "64px",  note: "rail width" },
          { name: "Toolbar button", v: "26px",  note: "header / theme" },
          { name: "Column tab",     v: "36×30", note: "icon tab" },
          { name: "Branch column",  v: "340px", note: "default" },
          { name: "History column", v: "420px", note: "default" },
          { name: "Detail side",    v: "460px", note: "fly-in" },
        ].map(x => (
          <div key={x.name} className="ds-token">
            <div className="ds-token-vis">
              <div className="box" style={{ "--w": (Math.min(48, parseInt(x.v)) || 36) + "px" }}/>
            </div>
            <div>
              <div className="ds-token-name">{x.name}</div>
              <div className="ds-token-value">{x.v} · {x.note}</div>
            </div>
          </div>
        ))}
      </div>
    </section>
  );
}

function RadiiSection() {
  return (
    <section id="radii" className="ds-section">
      <SectionHead
        id="radii"
        title="Radii"
        sub="Small, consistent. 6–8 px for interactive controls. 10–12 px for cards and panels. Circular for status dots, window controls, and pills."
      />
      <div className="ds-token-grid">
        {RADII.map(r => (
          <div key={r.name} className="ds-token">
            <div className="ds-token-vis">
              <div className="radius-box" style={{ "--r": r.px + "px" }}/>
            </div>
            <div>
              <div className="ds-token-name">radius-{r.name}</div>
              <div className="ds-token-value">{r.label || r.px + "px"}</div>
            </div>
          </div>
        ))}
      </div>
    </section>
  );
}

function ElevationSection() {
  return (
    <section id="elevation" className="ds-section">
      <SectionHead
        id="elevation"
        title="Elevation & motion"
        sub="Most surfaces are flat — depth comes from borders, not shadows. Drop shadows are reserved for overlays."
      />

      <div className="ds-sub-h">Shadows</div>
      <div className="ds-shadow-grid">
        {SHADOWS.map(s => (
          <div key={s.name} className="ds-shadow-card">
            <div className="ds-shadow-cube" style={{ boxShadow: s.val }}/>
            <div className="ds-shadow-meta">
              <div className="nm">{s.name}</div>
              <div className="val">{s.val}</div>
            </div>
          </div>
        ))}
      </div>

      <div className="ds-sub-h">Motion</div>
      <div className="ds-motion">
        <div className="head">Token</div>
        <div className="head">Value</div>
        <div className="head">Use</div>
        {MOTION.map(m => (
          <React.Fragment key={m.name}>
            <div className="nm">{m.name}</div>
            <div className="val">{m.val}</div>
            <div>{m.use}</div>
          </React.Fragment>
        ))}
      </div>

      <div className="ds-callout">
        Hover transitions are kept short (120 ms) to feel responsive in a developer tool. Reserve longer easings (240 ms+) for spatial moves where direction conveys meaning.
      </div>
    </section>
  );
}

function DensitySection() {
  return (
    <section id="density" className="ds-section">
      <SectionHead
        id="density"
        title="Density modes"
        sub="Three preset densities controlled by [data-density] on the root. Affects row padding, vertical gap, and base font size."
      />
      <div className="ds-density-grid">
        {DENSITIES.map(d => (
          <div key={d.id} className="ds-density-card" data-density={d.id}>
            <header>
              <span className="title">{d.id}</span>
              <span className="val">{d.font}</span>
            </header>
            <div className="body" style={{ padding: d.rowPad }}>
              <div style={{
                fontSize: d.font, color: "var(--text)", padding: d.rowPad,
                borderBottom: "1px solid var(--border)"
              }}>k7xq9p2m  ·  feat: hero search</div>
              <div style={{
                fontSize: d.font, color: "var(--text-muted)", padding: d.rowPad,
                borderBottom: "1px solid var(--border)"
              }}>m3n8r4t1  ·  fix: keyboard insets</div>
              <div style={{
                fontSize: d.font, color: "var(--text-muted)", padding: d.rowPad,
              }}>b5y2w7q9  ·  chore: bump deps</div>
            </div>
            <div style={{
              padding: "10px 14px",
              fontSize: 10.5, fontFamily: "var(--font-mono)",
              color: "var(--text-dim)",
              borderTop: "1px solid var(--border)",
              background: "var(--bg-card-2)",
            }}>
              gap {d.gap}  ·  pad {d.rowPad}
            </div>
          </div>
        ))}
      </div>
    </section>
  );
}

function ThemesSection({ theme, setTheme }) {
  return (
    <section id="themes" className="ds-section">
      <SectionHead
        id="themes"
        title="Themes"
        sub="Light + dark are inversions of the surface stack. Both inherit the same semantic and branch palettes."
      />
      <div className="ds-theme-toolbar">
        <span style={{ fontSize: 12, color: "var(--text-muted)" }}>Preview theme:</span>
        {["dark", "light"].map(t => (
          <button
            key={t}
            className={"ds-toolbtn " + (theme === t ? "active" : "")}
            onClick={() => setTheme(t)}
          >
            <Icon name={t === "light" ? "sun" : "moon"} size={13}/>
            {t}
          </button>
        ))}
      </div>
      <div className="ds-callout">
        Switch the toolbar above to flip every demo on the page in place. The Tweaks panel in the main app exposes <span className="ds-inline-code">theme: light | dark | system</span>.
      </div>
    </section>
  );
}

// ============================================================
// COMPONENT SECTIONS
// ============================================================
function ButtonsSection() {
  return (
    <section id="buttons" className="ds-section">
      <SectionHead
        id="buttons"
        title="Buttons"
        sub="A small, opinionated set. Most actions live as quiet header buttons or segmented switches; primary action color is reserved for the editor's main affordance per panel."
      />

      <div className="ds-comp">
        <header><span className="name">Header button</span><span className="css">.header-btn</span></header>
        <div className="canvas">
          <button className="header-btn"><Icon name="fetch" size={13}/>Fetch</button>
          <button className="header-btn"><Icon name="pull" size={13}/>Pull</button>
          <button className="header-btn"><Icon name="push" size={13}/>Push</button>
          <div className="header-divider"/>
          <button className="header-btn"><Icon name="plus" size={13}/>New</button>
        </div>
      </div>

      <div className="ds-comp">
        <header><span className="name">Action button (in commit detail)</span><span className="css">.action-btn / .action-btn.primary</span></header>
        <div className="canvas">
          <button className="action-btn primary">Edit</button>
          <button className="action-btn">Squash</button>
          <button className="action-btn">Abandon</button>
          <button className="action-btn">Rebase…</button>
        </div>
      </div>

      <div className="ds-comp">
        <header><span className="name">Segmented (theme switch)</span><span className="css">.theme-switch &gt; .theme-btn</span></header>
        <div className="canvas">
          <div className="theme-switch">
            <button className="theme-btn active"><Icon name="sun" size={14}/></button>
            <button className="theme-btn"><Icon name="moon" size={13}/></button>
            <button className="theme-btn"><Icon name="auto" size={14}/></button>
          </div>
          <div className="diff-mode-toggle">
            <button className="seg active"><Icon name="splitInline" size={11}/>Inline</button>
            <button className="seg"><Icon name="splitSide" size={11}/>Split</button>
          </div>
        </div>
      </div>

      <div className="ds-comp">
        <header><span className="name">Window controls</span><span className="css">.win-ctrl</span></header>
        <div className="canvas">
          <div className="window-controls">
            <button className="win-ctrl win-close"/>
            <button className="win-ctrl win-min"/>
            <button className="win-ctrl win-max"/>
          </div>
        </div>
      </div>
    </section>
  );
}

function RailSection() {
  const [active, setActive] = useState("history");
  const items = [
    { id: "history",    label: "History",       icon: "history" },
    { id: "branches",   label: "Branches",      icon: "branch" },
    { id: "workstream", label: "Workstreams",   icon: "workstream" },
    { id: "reviews",    label: "Reviews",       icon: "reviews" },
    { id: "undo",       label: "Undo Timeline", icon: "undo" },
  ];
  return (
    <section id="rail" className="ds-section">
      <SectionHead
        id="rail"
        title="Activity rail"
        sub="Vertical rail anchored to the window edge. Icon-only at 64 px wide. Left-edge accent stripe marks the active item. Settings docked at the bottom."
      />
      <div className="ds-comp">
        <header><span className="name">Activity rail</span><span className="css">.nav-rail &gt; .nav-activity</span></header>
        <div className="ds-rail-demo">
          <nav className="nav-rail" aria-label="Activity">
            {items.map(it => (
              <button
                key={it.id}
                className={"nav-activity " + (active === it.id ? "active" : "")}
                onClick={() => setActive(it.id)}
                title={it.label}
              >
                <Icon name={it.icon} size={22}/>
              </button>
            ))}
            <div className="nav-bottom">
              <button className="nav-activity" title="Settings"><Icon name="settings" size={20}/></button>
            </div>
          </nav>
          <div className="ds-pane">
            <span>active: <span className="ds-inline-code">{active}</span></span>
          </div>
        </div>
      </div>
    </section>
  );
}

function BranchesCompSection() {
  return (
    <section id="branches" className="ds-section">
      <SectionHead
        id="branches"
        title="Branches"
        sub="Branch chrome — column headers, pills, and lane caps. All derive their hue from window.BRANCH_COLORS[name]."
      />

      <div className="ds-comp">
        <header><span className="name">Branch column header</span><span className="css">.branch-col-header</span></header>
        <div className="canvas col" style={{ gap: 14 }}>
          {[
            { name: "main",            color: "#3b82f6", ahead: 0, current: false },
            { name: "feature/new-ui",  color: "#a855f7", ahead: 4, current: true  },
            { name: "fix/ios-keyboard",color: "#f59e0b", ahead: 2, current: false },
          ].map(b => (
            <section
              key={b.name}
              className="branch-col"
              style={{ "--branch-color": b.color, flex: "0 0 auto", margin: 0, width: 320 }}
            >
              <header className="branch-col-header">
                <div className="branch-col-header-name">
                  <Icon name="branch" size={13}/>
                  <span>{b.name}</span>
                </div>
                <div className="branch-col-header-meta">
                  {b.ahead > 0 && <span className="branch-col-header-pill">↑{b.ahead}</span>}
                  {b.current && <span className="branch-col-header-pill">@</span>}
                  <button className="branch-col-close"><Icon name="close" size={11}/></button>
                </div>
              </header>
            </section>
          ))}
        </div>
      </div>

      <div className="ds-comp">
        <header><span className="name">Branch pill</span><span className="css">.branch-pill</span></header>
        <div className="canvas">
          {[
            { name: "main",            color: "#3b82f6", ahead: 0, behind: 0, open: false },
            { name: "develop",         color: "#22c55e", ahead: 2, behind: 0, open: true  },
            { name: "feature/new-ui",  color: "#a855f7", ahead: 4, behind: 0, open: true  },
            { name: "exp/riverpod-3",  color: "#06b6d4", ahead: 1, behind: 3, open: false },
          ].map(b => (
            <button
              key={b.name}
              className={"branch-pill " + (b.open ? "open" : "")}
              style={{
                "--pill-bg":     `${b.color}22`,
                "--pill-border": `${b.color}55`,
                "--pill-fg":     b.color,
                width: "auto"
              }}
            >
              <Icon name="branch" size={13} className="branch-pill-icon"/>
              <span className="branch-pill-name">{b.name}</span>
              {b.ahead  > 0 && <span className="branch-pill-meta">↑{b.ahead}</span>}
              {b.behind > 0 && <span className="branch-pill-meta">↓{b.behind}</span>}
            </button>
          ))}
        </div>
      </div>
    </section>
  );
}

function TagsSection() {
  return (
    <section id="tags" className="ds-section">
      <SectionHead
        id="tags"
        title="Tags & badges"
        sub="Compact, monochrome by default. Color is added only when the tag describes a typed state (conflict, working-copy, merge)."
      />
      <div className="ds-comp">
        <header><span className="name">Commit tags</span><span className="css">.tag, .tag.wc, .tag.empty…</span></header>
        <div className="canvas">
          <span className="tag wc">@</span>
          <span className="tag empty">empty</span>
          <span className="tag merge">merge</span>
          <span className="tag version">v1.0.0</span>
          <span className="tag conflict"><Icon name="conflict" size={10}/>conflict</span>
          <span className="tag bookmark">feat/new-ui</span>
        </div>
      </div>

      <div className="ds-comp">
        <header><span className="name">Stat counter</span><span className="css">.stat, .stat-add, .stat-rem</span></header>
        <div className="canvas">
          <span className="stat">
            <span className="stat-add">+128</span>
            <span className="stat-rem">−47</span>
          </span>
        </div>
      </div>
    </section>
  );
}

function InputsSection() {
  return (
    <section id="inputs" className="ds-section">
      <SectionHead
        id="inputs"
        title="Inputs"
        sub="Inputs sit inside their container — single 1-px border, no inner shadow."
      />
      <div className="ds-comp">
        <header><span className="name">Filter input</span><span className="css">.flyout-search input / .lp-search input</span></header>
        <div className="canvas col" style={{ gap: 10, maxWidth: 360 }}>
          <div className="flyout-search" style={{ borderBottom: 0, padding: 0 }}>
            <input placeholder="Filter…" />
          </div>
        </div>
      </div>
    </section>
  );
}

function KbdSection() {
  return (
    <section id="kbd" className="ds-section">
      <SectionHead
        id="kbd"
        title="Keyboard shortcuts"
        sub="Keyboard glyphs use the mono stack at 10 px on a card-2 chip."
      />
      <div className="ds-comp">
        <header><span className="name">Kbd chip</span><span className="css">kbd</span></header>
        <div className="canvas">
          <div className="ds-row">
            <span style={{ fontSize: 12, color: "var(--text-muted)" }}>Command palette</span>
            <kbd>⌘K</kbd>
          </div>
          <div className="ds-row">
            <span style={{ fontSize: 12, color: "var(--text-muted)" }}>Close detail</span>
            <kbd>Esc</kbd>
          </div>
          <div className="ds-row">
            <span style={{ fontSize: 12, color: "var(--text-muted)" }}>Navigate slot</span>
            <kbd>⌥</kbd><kbd>←</kbd><kbd>→</kbd>
          </div>
        </div>
      </div>
    </section>
  );
}

function DiffSection() {
  const lines = [
    { type: "hunk",    text: "@@ -42,7 +42,9 @@ class HomeScreen" },
    { type: "context", text: "  Widget build(BuildContext context) {" },
    { type: "context", text: "    return Scaffold(" },
    { type: "remove",  text: "      body: HomeBody()," },
    { type: "add",     text: "      body: HomeBody(searchEnabled: true)," },
    { type: "context", text: "      appBar: HeroAppBar()," },
    { type: "add",     text: "      floatingActionButton: SearchFab()," },
    { type: "context", text: "    );" },
  ];
  return (
    <section id="diff" className="ds-section">
      <SectionHead
        id="diff"
        title="Diff view"
        sub="Code-like presentation: monospaced text, left-margin sigil, soft tinted line backgrounds. Hunks use the accent blue."
      />
      <div className="ds-comp">
        <header><span className="name">Inline diff</span><span className="css">.diff-body &gt; .diff-line</span></header>
        <div className="canvas col" style={{ padding: 0 }}>
          <div className="diff-block" style={{ margin: 0, borderRadius: 0, border: 0 }}>
            <div className="diff-body">
              {lines.map((l, i) => {
                if (l.type === "hunk") return <div key={i} className="diff-hunk">{l.text}</div>;
                const sigil = l.type === "add" ? "+" : l.type === "remove" ? "−" : " ";
                return (
                  <div key={i} className={"diff-line " + l.type}>
                    <span className="sigil">{sigil}</span>
                    <span className="txt">{l.text}</span>
                  </div>
                );
              })}
            </div>
          </div>
        </div>
      </div>
    </section>
  );
}

function CommitSection() {
  return (
    <section id="commit" className="ds-section">
      <SectionHead
        id="commit"
        title="Commit card"
        sub="The primary unit inside any branch column. Selected / hover / working-copy states all use background tints rather than borders."
      />
      <div className="ds-comp">
        <header><span className="name">Commit card states</span><span className="css">.commit-card · .wc · .selected · .soft-highlight</span></header>
        <div className="canvas">
          <div className="ds-mock-cards">
            {[
              { sub: "feat: hero search bar with keyboard nav", state: "", tags: [] },
              { sub: "wip: refactor onboarding flow",            state: "wc",               tags: [{ cls: "wc", text: "@" }] },
              { sub: "fix: address-form validation regression",  state: "selected",         tags: [{ cls: "conflict", text: "conflict", icon: "conflict" }] },
              { sub: "chore(deps): bump riverpod to 3.0",        state: "soft-highlight",   tags: [{ cls: "empty", text: "empty" }] },
            ].map((c, i) => (
              <div key={i} className={"commit-card " + c.state}>
                <div className="ccard-head">
                  {c.tags.length > 0 && (
                    <div className="commit-tags">
                      {c.tags.map((t, j) => (
                        <span key={j} className={"tag " + t.cls}>
                          {t.icon && <Icon name={t.icon} size={10}/>}
                          {t.text}
                        </span>
                      ))}
                    </div>
                  )}
                  <div className="commit-subject">{c.sub}</div>
                  <div className="commit-foot">
                    <span className="item changeid">k7xq9p2m</span>
                    <span className="item"><Icon name="user" size={11}/>alex</span>
                    <span className="item"><Icon name="calendar" size={11}/>2m ago</span>
                  </div>
                </div>
              </div>
            ))}
          </div>
        </div>
      </div>
    </section>
  );
}

function StatusSection() {
  return (
    <section id="status" className="ds-section">
      <SectionHead
        id="status"
        title="Status bar"
        sub="A single-line strip pinned to the bottom of the window. Read-only metadata, plus shortcut hints on the right."
      />
      <div className="ds-comp">
        <header><span className="name">Status bar</span><span className="css">.status-bar</span></header>
        <div className="canvas" style={{ padding: 0 }}>
          <footer className="status-bar" style={{ width: "100%" }}>
            <div className="status-left">
              <span className="status-item"><strong>@</strong> feat/new-ui</span>
              <span className="status-item"><span className="status-dot ok"/>repo clean</span>
              <span className="status-item">142 ops</span>
              <span className="status-item">3 columns open</span>
            </div>
            <div className="status-right">
              <span className="status-item">jj 0.24.0</span>
              <span className="status-item">flutter 3.27.1</span>
              <span className="status-item"><kbd>⌘K</kbd> palette</span>
            </div>
          </footer>
        </div>
      </div>
    </section>
  );
}

function IconographySection() {
  const all = Object.keys(I);
  return (
    <section id="iconography" className="ds-section">
      <SectionHead
        id="iconography"
        title="Iconography"
        sub={`${all.length} icons, all on a 16×16 grid with 1.4–1.5 px strokes and currentColor fills. Designed for legibility at 13–22 px.`}
      />
      <div className="ds-icon-grid">
        {all.map(n => (
          <div key={n} className="ds-icon-cell" title={n}>
            <div className="glyph"><Icon name={n} size={22}/></div>
            <div className="nm">{n}</div>
          </div>
        ))}
      </div>
    </section>
  );
}

// ============================================================
// APP
// ============================================================
function App() {
  const [theme, setTheme] = useState("dark");
  const [active, setActive] = useState("colors");

  useEffect(() => {
    document.documentElement.dataset.theme = theme;
  }, [theme]);

  // Scroll-spy
  useEffect(() => {
    const ids = SECTIONS.filter(s => !s.group).map(s => s.id);
    const onScroll = () => {
      let curr = ids[0];
      for (const id of ids) {
        const el = document.getElementById(id);
        if (!el) continue;
        const top = el.getBoundingClientRect().top;
        if (top < 140) curr = id;
      }
      setActive(curr);
    };
    onScroll();
    window.addEventListener("scroll", onScroll, { passive: true });
    return () => window.removeEventListener("scroll", onScroll);
  }, []);

  return (
    <div className="ds-shell">
      <DSNav active={active}/>
      <main className="ds-main">
        <header className="ds-header">
          <span className="ds-tag">v0.1 · in progress</span>
          <h1>Zanshin Design System</h1>
          <p>Tokens, components and patterns powering the Zanshin desktop client. Pulls the live <span className="ds-inline-code">styles.css</span> so every swatch and component on this page is rendered with the same CSS the app ships.</p>
          <div className="ds-header-toolbar">
            <div className="ds-theme-toolbar">
              {["dark", "light"].map(t => (
                <button
                  key={t}
                  className={"ds-toolbtn " + (theme === t ? "active" : "")}
                  onClick={() => setTheme(t)}
                >
                  <Icon name={t === "light" ? "sun" : "moon"} size={13}/>{t}
                </button>
              ))}
            </div>
            <a className="ds-toolbtn" href="JJ Desktop Client.html"><Icon name="arrowLeft" size={13}/>Back to app</a>
          </div>
        </header>

        <ColorsSection/>
        <TypographySection/>
        <SpacingSection/>
        <RadiiSection/>
        <ElevationSection/>
        <DensitySection/>
        <ThemesSection theme={theme} setTheme={setTheme}/>

        <ButtonsSection/>
        <RailSection/>
        <BranchesCompSection/>
        <TagsSection/>
        <InputsSection/>
        <KbdSection/>
        <DiffSection/>
        <CommitSection/>
        <StatusSection/>

        <IconographySection/>
      </main>
    </div>
  );
}

ReactDOM.createRoot(document.getElementById("root")).render(<App/>);
