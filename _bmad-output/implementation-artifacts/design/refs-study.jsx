/* global React, ReactDOM */
// REFS STUDY (2026-11-15): tags join bookmarks. A tag legend on the cards (bottom edge, calmer than the bookmark
// legend), no ⋯ button (right-click opens the card menu), a Tags view in the rail, both views as filterable trees with
// row buttons, and the sheets to delete, name and move a ref. Everything is a proposal; nothing is approved yet.
(() => {
const { useState } = React;

// ------------------------------------------------------------ icons (paths from app-shared.jsx, graph-view.jsx, calm-study.jsx)
const QA = { stroke: "currentColor", strokeWidth: 1.4, fill: "none", strokeLinecap: "round", strokeLinejoin: "round" };
const P = {
  branch: <g stroke="currentColor" strokeWidth="1.5" fill="none"><circle cx="4" cy="4" r="1.8"/><circle cx="4" cy="12" r="1.8"/><circle cx="12" cy="8" r="1.8"/><path d="M4 5.8v4.4M5.6 4q3 0 5 2.5"/></g>,
  reviews: <g stroke="currentColor" strokeWidth="1.4" fill="none" strokeLinecap="round"><path d="M3 11.5V4a1 1 0 0 1 1-1h7l3 3v5.5a1 1 0 0 1-1 1H6L3 14v-2.5z"/></g>,
  undo: <g stroke="currentColor" strokeWidth="1.4" fill="none" strokeLinecap="round"><path d="M3.5 6.5H10a3.5 3.5 0 1 1 0 7H6"/><path d="M5.5 4L3 6.5 5.5 9"/></g>,
  close: <path d="M3.5 3.5l9 9M12.5 3.5l-9 9" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round"/>,
  search: <g stroke="currentColor" strokeWidth="1.5" fill="none" strokeLinecap="round"><circle cx="7" cy="7" r="4"/><path d="M10 10l3.5 3.5"/></g>,
  plus: <path d="M8 3v10M3 8h10" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round"/>,
  conflict: <g stroke="currentColor" strokeWidth="1.4" fill="none" strokeLinecap="round" strokeLinejoin="round"><path d="M8 1.5L1.5 13.5h13L8 1.5z"/><path d="M8 6v3.5M8 11v0.4"/></g>,
  folder: <path d="M2.5 4.5h4l1.5 1.5h5.5v6.5h-11V4.5z" stroke="currentColor" strokeWidth="1.3" fill="none" strokeLinejoin="round"/>,
  folderOpen: <g stroke="currentColor" strokeWidth="1.3" fill="none" strokeLinejoin="round"><path d="M2.5 12.5v-8h4l1.5 1.5h4.5v1.5"/><path d="M2.5 12.5l1.8-5h10l-1.8 5z"/></g>,
  // the DS icon set has no tag: an outline price tag, hole top-left, same stroke as the others
  tag: <g {...QA}><path d="M2.5 3.2v4.3c0 .3.1.6.35.8l5.6 5.6c.45.45 1.15.45 1.6 0l3.75-3.75c.45-.45.45-1.15 0-1.6l-5.6-5.6A1.1 1.1 0 0 0 7.4 2.5H3.2a.7.7 0 0 0-.7.7z"/><circle cx="5.4" cy="5.4" r="1.05"/></g>,
  new: <g {...QA}><rect x="2.5" y="10" width="11" height="4" rx="1.2"/><path d="M8 1.75v5.5M5.25 4.5h5.5"/></g>,
  after: <g {...QA}><path d="M3.5 1.75h9"/><path d="M8 4v4.5M5.75 6.25h4.5"/><rect x="2.5" y="10.5" width="11" height="3.75" rx="1.2"/></g>,
  before: <g {...QA}><rect x="2.5" y="1.75" width="11" height="3.75" rx="1.2"/><path d="M8 7.5v4.5M5.75 9.75h4.5"/><path d="M3.5 14.25h9"/></g>,
  edit: <text x="8" y="12" textAnchor="middle" fontSize="11" fontWeight="700" fill="currentColor" fontFamily="ui-monospace,monospace">@</text>,
  describe: <path d="M3 13l.6-2.6L10.5 3.5l2 2-6.9 6.9L3 13zM9.3 4.7l2 2" stroke="currentColor" strokeWidth="1.4" fill="none" strokeLinejoin="round"/>,
  squash: <g stroke="currentColor" strokeWidth="1.5" fill="none" strokeLinecap="round" strokeLinejoin="round"><path d="M8 2v7M5 6l3 3 3-3"/><path d="M3 13h10"/></g>,
  revert: <g {...QA}><path d="M2.2 3.2v3.6h3.6"/><path d="M3.7 9.8A5.4 5.4 0 1 0 5 4.2L2.2 6.8"/></g>,
  trash: <g {...QA}><path d="M3 4.5h10M6.5 4.5V3h3v1.5M4.5 4.5l.6 8.5h5.8l.6-8.5"/></g>,
};
const Ic = ({ n, s = 14 }) => <svg width={s} height={s} viewBox="0 0 16 16" aria-hidden="true" style={{ flexShrink: 0 }}>{P[n]}</svg>;
const BmGlyph = ({ filled, s = 14 }) => (
  <svg width={s} height={s} viewBox="0 0 16 16" aria-hidden="true" style={{ flexShrink: 0 }}>
    <path d="M4.6 2.2h6.8c.47 0 .85.38.85.85v10.4c0 .35-.4.55-.68.34L8 11.1l-3.57 2.69a.43.43 0 0 1-.68-.34V3.05c0-.47.38-.85.85-.85z"
      fill={filled ? "currentColor" : "none"} stroke="currentColor" strokeWidth="1.4" strokeLinejoin="round"/>
  </svg>
);
const Cid = ({ id, n = 8 }) => <span className="gcid"><b>{id.slice(0, 2)}</b>{id.slice(2, n)}</span>;
// The match inside one row's own text (a query across a "/" lights nothing). shortcut: fine for the study's data.
const Hl = ({ t, q }) => {
  const i = q ? t.toLowerCase().indexOf(q.toLowerCase()) : -1;
  return i < 0 ? t : <>{t.slice(0, i)}<span className="gs-m">{t.slice(i, i + q.length)}</span>{t.slice(i + q.length)}</>;
};
// release/1.5.x → { prefix: "release/", main: "1.5.x" } (graph-view.jsx › shortBookmark, without the ticket rule)
const shortRef = (name) => { const seg = name.split("/"); return seg.length > 1 ? { prefix: seg.slice(0, -1).join("/") + "/", main: seg[seg.length - 1] } : { main: name }; };
const stop = (e) => e.stopPropagation();

// ------------------------------------------------------------ data
const BOOKMARKS = [
  { name: "main", at: "pzoqtwuv", subj: "Merge pull request #212 from feature/queue", state: "synced", tracked: true },
  { name: "feature/onboarding/swipe", at: "kxqtvwnm", subj: "feat(onboarding): swipe between steps", state: "local" },
  { name: "feature/onboarding/pager", at: "lmnuoyrw", subj: "feat(onboarding): page indicator", state: "local" },
  { name: "feature/auth-flow", at: "kmwnqzlt", subj: "feat(auth): login form validation", state: "ahead", ahead: 2, tracked: true },
  { name: "fix/queue-retries-after-a-dropped-connection", at: "vruxwmqz", subj: "fix: retry the queue after a dropped connection", state: "deleted", tracked: true },
  { name: "release/1.5.x", at: "tnoyqlsv", subj: "release: 1.5.0-rc1", state: "local" },
  { name: "release/1.4.x", remote: "origin", at: "ypwulmnr", subj: "fix: crash when the queue is empty", state: "untracked" },
  { name: "ralph/spike-graph", at: "qyxnrkpt", subj: "spike: graph layout experiments", state: "conflict", sub: "conflicted: qyxnrkpt or wqzrtsko" },
];
const TAGS = [
  { name: "v1.5.0-rc1", at: "tnoyqlsv", subj: "release: 1.5.0-rc1", origin: true },
  { name: "release/2026-11", at: "tnoyqlsv", subj: "release: 1.5.0-rc1" },
  { name: "nightly/2026-11-14", at: "wzpmrkoy", subj: "chore: bump build number to 1412" },
  { name: "nightly/2026-11-13", at: "xvlmquzo", subj: "chore: bump build number to 1411" },
  { name: "v1.4.2", at: "ypwulmnr", subj: "fix: crash when the queue is empty", origin: true },
  { name: "v1.4.1", at: "nwrsxkpo", subj: "fix: keep the session on rotate", origin: true },
  { name: "v1.4.0", at: "uqmzlrvy", subj: "release: 1.4.0", origin: true },
];
const FULL = (r) => r.name + (r.remote ? "@" + r.remote : "");

// ------------------------------------------------------------ 1 · cards
const W = 260, H = 62; // graph-layout.jsx: hDetailed 62
const CARDS = {
  a: { id: "kxqtvwnm", subject: "feat(onboarding): swipe between steps", author: "Ralph", date: "Nov 13", bms: [{ name: "feature/onboarding/swipe", label: "local only" }], tags: [] },
  b: { id: "wzpmrkoy", subject: "chore: bump build number to 1412", author: "Ralph", date: "Nov 14", bms: [], tags: [{ name: "nightly/2026-11-14", label: "local only" }] },
  c: { id: "tnoyqlsv", subject: "release: 1.5.0-rc1", author: "Ralph", date: "Nov 14", bms: [{ name: "release/1.5.x", label: "local only" }],
    tags: [{ name: "v1.5.0-rc1", label: "on origin" }, { name: "release/2026-11", label: "local only" }] },
  d: { id: "ypwulmnr", subject: "fix: crash when the queue is empty", author: "Anna", date: "Oct 30", imm: true, bms: [], tags: [{ name: "v1.4.2", label: "on origin" }] },
  e: { id: "srkvzmop", subject: "docs: auth flow sequence diagrams", author: "Ralph", date: "Nov 15", bms: [], tags: [] },
};

// The bookmark legend as today (top edge, right) and the tag legend: the same pill on the bottom edge, calmer.
function RefPill({ kind, items, open }) {
  const tag = kind === "tag", has = items.length > 0, s = has && shortRef(items[0].name);
  const glyph = (size) => (tag ? <Ic n="tag" s={size}/> : <BmGlyph filled s={size}/>);
  return (
    <div className={"gbm " + (has ? "is-legend has" : "is-btn") + (tag ? " rs-tg" : "") + (open ? " is-open" : "")} onClick={stop}>
      <button className="gbm-trigger" aria-label={has ? (tag ? "Tags: " : "Bookmarks: ") + items.map((b) => b.name).join(", ") : "Add bookmark"}>
        {tag ? <Ic n="tag" s={11}/> : <BmGlyph filled={has} s={has ? 11 : 14}/>}
        {has && <>
          {s.prefix && <span className="gbm-rest gbm-prefix" title={s.prefix}>{s.prefix}</span>}
          <span className="gbm-main">{s.main}</span>
          {items.length > 1 && <span className="gbm-more">+{items.length - 1}</span>}
        </>}
      </button>
      <div className="gbm-pop">
        <div className="gbm-pop-inner">
          {has ? items.map((b) => (
            <div key={b.name} className="gbm-item">{glyph(12)}<span className="gbm-name">{b.name}</span><span className="gbm-state">{b.label}</span></div>
          )) : <div className="gbm-none">No bookmark on this change</div>}
          <div className="gbm-actions">
            {tag ? <><button>Create tag here…</button><button>Move existing here…</button><button className="danger">Delete</button></>
              : has ? <><button>Rename…</button><button>Move to…</button><button className="danger">Delete</button></>
                : <><button>Create bookmark here…</button><button>Move existing here…</button></>}
          </div>
        </div>
      </div>
    </div>
  );
}

function Card({ c, x, y, ctx, tagOpen }) {
  return (
    <div className={"gcard is-detailed add-menu" + (c.bms.length ? " has-legend" : "") + (c.imm ? " immutable" : "") + (ctx ? " ctx" : "")}
      style={{ left: x, top: y, width: W, height: H }} tabIndex={0} role="button" aria-label={(c.imm ? "Immutable, " : "") + c.subject}
      onContextMenu={(e) => e.preventDefault()}>
      <div className="gline"><span className="gsubj">{c.subject}</span></div>
      <div className="gline gmeta"><Cid id={c.id}/><span className="gmeta-t au">{c.author}</span><span className="gmeta-t">{c.date}</span></div>
      <RefPill kind="bookmark" items={c.bms}/>
      {c.tags.length > 0 && <RefPill kind="tag" items={c.tags} open={tagOpen}/>}
    </div>
  );
}

// Today's groups (graph-view.jsx › MENU_GROUPS) plus a last group, so a change without refs can get a tag.
const MENU = [
  [["new", "New change on top", "jj new"], ["after", "Insert after", "jj new -A"], ["before", "Insert before", "jj new -B"]],
  [["edit", "Edit", "jj edit"], ["describe", "Describe…", "jj describe"], ["squash", "Squash into parent", "jj squash"]],
  [["revert", "Revert", "jj revert -B @"], ["trash", "Abandon", "jj abandon", true]],
  [["bm", "Create bookmark here…", "jj bookmark create"], ["tag", "Create tag here…", "jj tag set"]],
];
function CardMenu({ c, x, y }) {
  return (
    <div className="gmenu" role="menu" style={{ left: x, top: y }}>
      <div className="gmenu-head"><Cid id={c.id}/><span className="gmenu-subj">{c.subject}</span></div>
      {MENU.map((g, gi) => (
        <React.Fragment key={gi}>
          {gi > 0 && <div className="gmenu-sep"></div>}
          {g.map(([id, label, cmd, danger]) => (
            <button key={id} role="menuitem" className={"gmenu-item" + (danger ? " danger" : "")}>
              {id === "bm" ? <BmGlyph s={14}/> : <Ic n={id} s={14}/>}<span>{label}</span><span className="gmenu-cmd">{cmd}</span>
            </button>
          ))}
        </React.Fragment>
      ))}
    </div>
  );
}

function CardsScene() {
  const col = (i) => 24 + i * (W + 22);
  const cap = (x, y, t) => <div key={t} className="rs-cap rs-abs" style={{ left: x, top: y }}>{t}</div>;
  return (
    <div className="gws rs-graph" data-imm="hatched">
      <div className="gplane rs-plane" style={{ width: col(5) + 2, height: 620 }}>
        {["a", "b", "c", "d", "e"].map((k, i) => <Card key={k} c={CARDS[k]} x={col(i)} y={34}/>)}
        {[["a", "bookmark"], ["b", "tag"], ["c", "bookmark and two tags"], ["d", "immutable, tag"], ["e", "no refs"]].map(([k, t], i) => cap(col(i), 116, `(${k}) ${t}`))}
        {cap(col(0), 140, "(c) pointer on the tag legend")}
        <Card c={CARDS.c} x={col(0)} y={170} tagOpen/>
        {cap(680, 140, "(e) right-click")}
        <Card c={CARDS.e} x={680} y={170} ctx/>
        <CardMenu c={CARDS.e} x={840} y={208}/>
      </div>
    </div>
  );
}

// ------------------------------------------------------------ 2 · rail
function RailScene() {
  const shown = TAGS.slice(0, 5);
  return (
    <div className="rs-stage">
      <nav className="fl-rail fl-glass rs-rail" aria-label="Panels">
        <button className="fl-rail-btn" aria-label="Bookmarks"><Ic n="branch" s={19}/></button>
        <button className="fl-rail-btn hov" aria-label="Tags"><Ic n="tag" s={19}/></button>
        <button className="fl-rail-btn" aria-label="Reviews"><Ic n="reviews" s={19}/></button>
        <button className="fl-rail-btn" aria-label="Undo Timeline"><Ic n="undo" s={19}/></button>
      </nav>
      <div className="fl-callout" style={{ top: 90, left: 78 }} role="tooltip">
        <div className="fl-co-hd"><Ic n="tag" s={14}/><span>Tags</span><span className="fl-co-n">{TAGS.length}</span></div>
        <div className="fl-co-bd">
          <div className="gbl">
            {shown.map((t) => (
              <button key={t.name} className="gbl-row" title={t.name}>
                <Ic n="tag" s={12}/>
                <span className="gbl-text"><span className="gbl-name">{t.name}</span><span className="gbl-sub"><b>{t.at.slice(0, 2)}</b>{t.at.slice(2, 8)} · {t.subj}</span></span>
                <span/>
              </button>
            ))}
          </div>
          <div className="fl-co-more">+{TAGS.length - shown.length} more</div>
        </div>
      </div>
    </div>
  );
}

// ------------------------------------------------------------ 3 + 4 · the views: filterable trees with row buttons
function treeRows(items, q, closed) {
  const root = { dirs: new Map(), leaves: [] };
  for (const it of items) {
    const seg = it.name.split("/");
    let d = root, path = "";
    for (const s of seg.slice(0, -1)) {
      path += s + "/";
      if (!d.dirs.has(s)) d.dirs.set(s, { name: s + "/", path, dirs: new Map(), leaves: [] });
      d = d.dirs.get(s);
    }
    d.leaves.push({ ...it, leaf: seg[seg.length - 1] });
  }
  const hit = (r) => !q || FULL(r).toLowerCase().includes(q.toLowerCase());
  const any = (d) => d.leaves.some(hit) || [...d.dirs.values()].some(any);
  const out = [];
  const walk = (d, depth) => {
    for (const c of [...d.dirs.values()].sort((a, b) => a.name.localeCompare(b.name))) {
      if (!any(c)) continue;
      const open = !!q || !closed.has(c.path); // a filter opens every folder it keeps
      out.push({ dir: true, path: c.path, name: c.name, depth, open });
      if (open) walk(c, depth + 1);
    }
    for (const l of d.leaves.filter(hit).sort((a, b) => a.leaf.localeCompare(b.leaf))) out.push({ ...l, depth });
  };
  walk(root, 0);
  return out;
}

const Btn = ({ icon, label, title, danger }) => icon
  ? <button className={"rs-ib" + (danger ? " danger" : "")} title={title} aria-label={label} onClick={stop}><Ic n={icon} s={13}/></button>
  : <button className="rs-tb" title={title} onClick={stop}>{label}</button>;

function rowButtons(kind, r) {
  const name = FULL(r), ref = kind === "tag" ? "tag" : "bookmark";
  const nw = <Btn key="new" icon="plus" label="New change here" title={`New change here — jj new ${name}`}/>;
  const del = <Btn key="del" icon="trash" label="Delete…" title={`Delete… — jj ${ref} delete ${r.name}`} danger/>;
  if (kind === "tag") return [nw, del];
  if (r.state === "untracked") return [<Btn key="tr" label="Track" title={`jj bookmark track ${name}`}/>, nw];
  const untrack = <Btn key="un" label="Untrack" title={`jj bookmark untrack ${r.name}@origin`}/>;
  if (r.state === "deleted") return [untrack, nw];
  return r.tracked ? [untrack, nw, del] : [nw, del];
}

const STATE = {
  synced: <span className="gbm-state" title="in sync with origin">✓</span>,
  ahead: (r) => <span className="gbm-state s-ahead" title="ahead of origin">↑{r.ahead}</span>,
  deleted: <span className="gbm-state" title="deleted here, still on origin">deleted</span>,
  conflict: <span className="gflag conflict" title="conflicted: points to two changes"><Ic n="conflict" s={13}/></span>,
};

function RefPanel({ title, icon, kind, items, initialQ = "", fhov = [], height }) {
  const [q, setQ] = useState(initialQ);
  const [closed, setClosed] = useState(() => new Set());
  const rows = treeRows(items, q, closed);
  const toggle = (p) => setClosed((c) => { const n = new Set(c); n.has(p) ? n.delete(p) : n.add(p); return n; });
  return (
    <div className="fl-panel fl-glass rs-panel" style={{ height }}>
      <section className="left-panel">
        <header className="left-panel-header">
          <Ic n={icon} s={13}/><h3>{title}</h3>
          <button className="lp-close" title="Close" aria-label="Close"><Ic n="close" s={11}/></button>
        </header>
        <div className="lp-search rs-filter">
          <Ic n="search" s={12}/>
          <input placeholder={"Filter " + title.toLowerCase()} value={q} onChange={(e) => setQ(e.target.value)} spellCheck="false" aria-label={"Filter " + title.toLowerCase()}/>
          {q && <button className="rs-clear" title="Clear" aria-label="Clear" onClick={() => setQ("")}><Ic n="close" s={10}/></button>}
        </div>
        <div className="left-panel-body rs-tree" role="tree">
          {rows.map((r) => r.dir ? (
            <div key={r.path} role="treeitem" aria-expanded={r.open} tabIndex={0} className="rs-row rs-dir" style={{ paddingLeft: 8 + r.depth * 14 }}
              onClick={() => toggle(r.path)} onKeyDown={(e) => { if (e.key === "Enter" || e.key === " ") { e.preventDefault(); toggle(r.path); } }}>
              <span className="rs-ficon"><Ic n={r.open ? "folderOpen" : "folder"} s={14}/></span><span className="rs-dname"><Hl t={r.name} q={q}/></span>
            </div>
          ) : (
            <div key={FULL(r)} role="treeitem" tabIndex={0} title={FULL(r)}
              className={"rs-row rs-leaf" + (r.state === "untracked" ? " is-untracked" : "") + (fhov.includes(FULL(r)) ? " is-fhov" : "")}
              style={{ paddingLeft: 8 + r.depth * 14 + 20 }}>
              <span className="gbl-text">
                <span className="gbl-name"><Hl t={r.leaf} q={q}/>{r.remote && <span className="rs-remote">@{r.remote}</span>}</span>
                <span className="gbl-sub">{r.sub || <><b>{r.at.slice(0, 2)}</b>{r.at.slice(2, 8)} · {r.subj}</>}</span>
              </span>
              <span className="rs-state">{typeof STATE[r.state] === "function" ? STATE[r.state](r) : STATE[r.state]}</span>
              <span className="rs-acts">{rowButtons(kind, r)}</span>
            </div>
          ))}
          {!rows.length && <div className="fl-co-empty">No {kind} matches “{q}”.</div>}
        </div>
      </section>
    </div>
  );
}

// ------------------------------------------------------------ 5 · delete sheets
const BM_DELETE = [
  { id: "forget", label: "Only here — keep it on origin", cmd: ["jj bookmark forget feature/auth-flow"], note: "Undo works. origin keeps it; the next fetch shows it again as untracked." },
  { id: "delete", label: "Here, and on origin when you push the deletion", cmd: ["jj bookmark delete feature/auth-flow"], note: "Undo works until you push. A plain push skips deletions; the Push sheet offers to push them." },
  { id: "now", label: "Here and on origin now", cmd: ["jj bookmark delete feature/auth-flow", "jj git push --remote origin -b feature/auth-flow"], note: "Can't be undone: origin loses the bookmark.", danger: true },
];
const TAG_DELETE = [
  { id: "here", label: "Only here — keep it on origin", cmd: ["jj tag untrack v1.5.0-rc1@origin", "jj tag delete v1.5.0-rc1"], note: "Undo works. origin keeps the tag; jj has no tag forget, so it is untracked first." },
  { id: "delete", label: "Here, and on origin when you push the deletion", cmd: ["jj tag delete v1.5.0-rc1"], note: "Undo works until you push. A plain push skips deletions; the Push sheet offers to push them." },
  { id: "now", label: "Here and on origin now", cmd: ["jj tag delete v1.5.0-rc1", "jj git push --remote origin -t v1.5.0-rc1"], note: "Can't be undone: origin loses the tag.", danger: true },
];
function DeleteSheet({ name, what, choices, init, width }) {
  const [v, setV] = useState(init);
  return (
    <div className="rs-sheetbox" style={{ width: width + 48 }}>
      <div className="gconf-scrim">
        <div className="gconf" role="alertdialog" aria-modal="true" aria-label={`Delete ${name}?`} style={{ width }}>
          <h2 className="gconf-title">Delete <span className="rs-mono">{name}</span>?</h2>
          <div className="gconf-body">The {what} is also on origin. Where should it go?</div>
          <div className="rs-choices" role="radiogroup" aria-label="Where to delete">
            {choices.map((ch) => (
              <button key={ch.id} type="button" role="radio" aria-checked={v === ch.id} className={"rs-choice" + (ch.danger ? " is-danger" : "") + (v === ch.id ? " on" : "")} onClick={() => setV(ch.id)}>
                <span className={"rs-radio" + (v === ch.id ? " is-on" : "")}><span className="rs-radio-dot"/></span>
                <span className="rs-choice-t">
                  <span className="rs-choice-l">{ch.label}{ch.id === init && <span className="rs-default">default</span>}</span>
                  <code className="rs-ccmd">{ch.cmd.join("\n")}</code>
                  <span className="rs-choice-n">{ch.note}</span>
                </span>
              </button>
            ))}
          </div>
          <div className="gconf-ft">
            <span className="gconf-key">⌘↩ confirms</span>
            <button className="rsd-btn">Cancel</button>
            <button className="rsd-btn danger" title="⌘↩">Delete</button>
          </div>
        </div>
      </div>
    </div>
  );
}

// ------------------------------------------------------------ 6 · name field
// Characters git refuses in a ref name become "_" while typing and on paste (git check-ref-format).
const cleanName = (s) => s.replace(/[\s~^:?*[\\\x00-\x1f\x7f]/g, "_");
// Whole-name rules: replacing these while typing would fight the user, so they show an error instead.
const RULES = [
  [(s) => s.startsWith("/"), "Must not start with “/”"],
  [(s) => s.endsWith("/"), "Must not end with “/”"],
  [(s) => s.startsWith("."), "Must not start with “.”"],
  [(s) => s.endsWith(".lock"), "Must not end with “.lock”"],
  [(s) => s.endsWith("."), "Must not end with “.”"],
  [(s) => s.includes(".."), "Must not contain “..”"],
  [(s) => s.includes("//"), "Must not contain “//”"],
  [(s) => s.includes("@{"), "Must not contain “@{”"],
];
const nameError = (s) => (s && (RULES.find(([bad]) => bad(s)) || [])[1]) || null;
console.assert(cleanName("feature/my new:idea?") === "feature/my_new_idea_", "cleanName: typed");
console.assert(cleanName("fix/login ~ crash") === "fix/login___crash", "cleanName: pasted");
console.assert(nameError("release/1.5.") === "Must not end with “.”" && nameError("feature/ok") === null, "nameError");

function NameSheet({ init }) {
  const [v, setV] = useState(() => cleanName(init));
  const [fixed, setFixed] = useState(() => cleanName(init) !== init);
  const err = nameError(v);
  return (
    <div className="rs-sheetbox is-name">
      <div className="gconf-scrim">
        <div className="gconf" role="dialog" aria-modal="true" aria-label="Create bookmark here" style={{ width: 340 }}>
          <h2 className="gconf-title">Create bookmark here</h2>
          <div className="gconf-body">On <Cid id="srkvzmop"/> docs: auth flow sequence diagrams</div>
          <div className="rs-field">
            <input className={"rsd-in rs-in" + (err ? " is-err" : "")} value={v} spellCheck="false" aria-label="Bookmark name" aria-invalid={!!err}
              onChange={(e) => { const n = cleanName(e.target.value); setFixed((f) => (f || n !== e.target.value) && n !== ""); setV(n); }}/>
            {err ? <span className="rs-ferr" role="alert">{err}</span> : fixed && <span className="rs-fnote">Spaces and ~ ^ : ? * [ \ become _</span>}
          </div>
          <code className="gconf-cmd">jj bookmark create {v || "…"} -r srkvzmop</code>
          <div className="gconf-ft">
            <button className="rsd-btn">Cancel</button>
            <button className="rsd-btn primary" disabled={!!err || !v}>Create</button>
          </div>
        </div>
      </div>
    </div>
  );
}

// ------------------------------------------------------------ 7 · move existing here (picker)
const MOVE_BM = [
  { name: "feature/auth-flow", at: "kmwnqzlt", short: "login form validation" },
  { name: "feature/onboarding/pager", at: "lmnuoyrw", short: "page indicator", dir: "backwards" },
  { name: "feature/onboarding/swipe", at: "kxqtvwnm", short: "swipe between steps", dir: "sideways" },
  { name: "release/1.5.x", at: "tnoyqlsv", short: "1.5.0-rc1", dir: "backwards" },
];
const MOVE_TAG = TAGS.map((t) => ({ name: t.name, at: t.at, origin: t.origin, short: t.subj.replace(/^[a-z]+(\([^)]*\))?: /, "") }));

function MovePicker({ kind, init }) {
  const tag = kind === "tag", all = tag ? MOVE_TAG : MOVE_BM;
  const [q, setQ] = useState(init);
  const [hi, setHi] = useState(0);
  const [allow, setAllow] = useState(false);
  const rows = all.filter((r) => r.name.toLowerCase().includes(q.toLowerCase()));
  const pick = rows[Math.min(hi, rows.length - 1)];
  const blocked = !tag && pick && pick.dir && !allow;
  const cmd = !pick ? "" : tag ? `jj tag set ${pick.name} -r srkvzmop --allow-move`
    : `jj bookmark move ${pick.name} --to srkvzmop${pick.dir && allow ? " --allow-backwards" : ""}`;
  return (
    <div className="rs-sheetbox is-move">
      <div className="gconf-scrim">
        <div className="gconf" role="dialog" aria-modal="true" aria-label={`Move a ${kind} to srkvzmop`} style={{ width: 500 }}>
          <h2 className="gconf-title">Move a {kind} to <Cid id="srkvzmop"/></h2>
          <input className="rsd-in rs-in" value={q} onChange={(e) => { setQ(e.target.value); setHi(0); }} spellCheck="false" aria-label={tag ? "Tag" : "Bookmark"}
            placeholder={tag ? "Tag name" : "Bookmark name"}/>
          <div className="gs-list rs-plist" role="listbox">
            {rows.map((r, i) => (
              <div key={r.name} role="option" aria-selected={r === pick} className={"gs-row" + (r === pick ? " on" : "")} onMouseMove={() => setHi(i)} onClick={() => setHi(i)}>
                <span className="gs-ic">{tag ? <Ic n="tag" s={14}/> : <BmGlyph s={14}/>}</span>
                <span className="gs-main"><span className="gs-nm rs-mono"><Hl t={r.name} q={q}/></span></span>
                <span className="gs-meta">
                  {r.dir && <span className="gs-tag rs-warn" title="Moving it there needs --allow-backwards">{r.dir}</span>}
                  <span className="rs-now">now on <Cid id={r.at}/> {r.short}</span>
                </span>
              </div>
            ))}
            {!rows.length && <div className="gs-empty">No {kind} matches “{q}”.</div>}
          </div>
          {!tag && (
            <label className="rs-allow">
              <button role="switch" aria-checked={allow} className={"gtb-switch" + (allow ? " on" : "")} onClick={() => setAllow(!allow)}/>
              <span>Allow moving backwards or sideways <code>--allow-backwards</code></span>
            </label>
          )}
          {tag && (pick && pick.origin
            ? <div className="rs-fnote rs-warn-t"><code>{pick.name}</code> is on origin — moving it changes a published tag. Anyone who fetched it keeps the old one; your next push of the tag moves it on origin too.</div>
            : <div className="rs-fnote">A tag that already exists moves only with <code>--allow-move</code>.</div>)}
          <code className="gconf-cmd">{cmd || "—"}</code>
          <div className="gconf-ft">
            {blocked && <span className="gconf-key rs-warn-t">This move goes {pick.dir}: turn on the switch to allow it.</span>}
            <button className="rsd-btn">Cancel</button>
            <button className="rsd-btn primary" disabled={!pick || blocked}>Move</button>
          </div>
        </div>
      </div>
    </div>
  );
}

// ------------------------------------------------------------ 8 · top search rows
function SearchDemo({ query, rows }) {
  const [hi, setHi] = useState(rows.findIndex((r) => r.on));
  const hq = query.replace(/^b:/, "");
  return (
    <div className="rs-sbox">
      <div className="fl-tc fl-glass rs-tc">
        <div className="gs is-focus has-q">
          <span className="rs-sic"><Ic n="search" s={15}/></span>
          <input className="gs-in mono" value={query} readOnly aria-label="Search"/>
          <div className="gs-pop">
            <div className="gs-list" role="listbox" aria-label="Suggestions">
              <div className="gs-gh"><span>Bookmarks</span></div>
              {rows.map((r, i) => {
                const on = i === hi, name = FULL(r);
                return (
                  <div key={name} role="option" aria-selected={on} className={"gs-row" + (on ? " on" : "")} onMouseMove={() => setHi(i)}>
                    <span className="gs-ic"><BmGlyph s={14}/></span>
                    <span className="gs-main"><span className="gs-nm rs-mono"><Hl t={name} q={hq}/></span>{r.state === "untracked" && <span className="gs-tag">untracked</span>}</span>
                    <span className="gs-meta">
                      {on && <span className="rs-sacts">
                        {r.state === "untracked" && <Btn label="Track" title={`jj bookmark track ${name}`}/>}
                        <Btn icon="plus" label="New change here" title={`New change here — jj new ${name}`}/>
                      </span>}
                      <Cid id={r.at}/>
                    </span>
                  </div>
                );
              })}
            </div>
            <div className="gs-ft">
              <span className="gs-ft-t">Selects the change — the graph stays as it is</span>
              <span className="gs-ft-k">Select<kbd>↩</kbd></span>
              <span className="gs-ft-k">New change here<kbd>⌘↩</kbd></span>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}
const bm = (name) => BOOKMARKS.find((b) => b.name === name);

// ------------------------------------------------------------ 9 · top inset
// Today the bar's centre is the system's traffic-light centre (y 26), so the bar sits 4 from the top
// (zs_metrics.dart › tlMidY 26, chromeTop = 26 + 22 + 12 = 60). Proposed: the bar 12 from the top like every other edge.
function Inset({ title, mid }) {
  const WW = 560, HH = 300, barY = mid - 22, top = mid + 22 + 12;
  const isl = (x, w) => <rect x={x} y={barY} width={w} height="44" rx="14" className="rs-w-isl"/>;
  const vdim = (x, y1, y2, label) => <g className="rs-w-dim"><path d={`M${x} ${y1}V${y2}M${x - 3} ${y1}h6M${x - 3} ${y2}h6`}/><text x={x + 6} y={Math.max(y1 + 9, (y1 + y2) / 2 + 4)}>{label}</text></g>;
  const hdim = (x1, x2, y, label) => <g className="rs-w-dim"><path d={`M${x1} ${y}H${x2}M${x1} ${y - 3}v6M${x2} ${y - 3}v6`}/><text x={(x1 + x2) / 2} y={y - 6} textAnchor="middle">{label}</text></g>;
  return (
    <figure className="rs-fig">
      <svg width={WW} height={HH} viewBox={`0 0 ${WW} ${HH}`} role="img" aria-label={title}>
        <rect x=".5" y=".5" width={WW - 1} height={HH - 1} rx="10" className="rs-w-frame"/>
        <line x1="0" x2={WW} y1={mid} y2={mid} className="rs-w-mid"/>
        {[26, 49, 72].map((x) => <circle key={x} cx={x} cy={mid} r="7" className="rs-w-tl"/>)}
        {isl(91, 120)}{isl(223, 150)}{isl(WW - 12 - 120, 120)}
        <rect x="12" y={top} width="52" height="150" rx="16" className="rs-w-isl"/>
        <rect x={WW - 12 - 170} y={top} width="170" height={HH - 12 - top} rx="16" className="rs-w-isl"/>
        {vdim(395, 0, barY, barY)}
        {vdim(WW - 97, barY + 44, top, "12")}
        <text x="298" y={mid - 5} textAnchor="middle" className="rs-w-lbl">centre y {mid}</text>
        <text x="72" y={top + 12} className="rs-w-lbl">content y {top}</text>
        {hdim(0, 12, top + 90, "12")}
        {hdim(WW - 12, WW, top + 40, "12")}
        {vdim(WW - 97, HH - 12, HH, "12")}
      </svg>
      <figcaption><b>{title}</b></figcaption>
    </figure>
  );
}

// ------------------------------------------------------------ page
function App() {
  const [force, setForce] = useState("none");
  return (
    <div className={"rs-win force-" + force}>
      <header className="rs-head">
        <b>Refs Study</b> — how tags join bookmarks in the floating client: a tag legend on the cards, a Tags view in the
        rail, both views as trees you can filter, row buttons, and the sheets to delete, name and move a bookmark or tag.
        Everything on this page is a proposal for Ralph; nothing is approved yet.
      </header>
      <div className="rs-force">Pretend the pointer is:
        <div className="gtb-seg" role="radiogroup" aria-label="Pretend hover">
          {[["none", "nowhere"], ["cards", "on the cards"], ["rows", "on rows"]].map(([k, t]) => (
            <button key={k} role="radio" aria-checked={force === k} className={force === k ? "on" : ""} onClick={() => setForce(k)}>{t}</button>))}
        </div>
        <span>(real hover works too)</span>
      </div>

      <section>
        <h2>1 · Commit cards</h2>
        <p className="rs-note">The bookmark legend stays where it is: top edge, right. The tag legend is the same pill on the
          bottom edge, right, in a calmer tone, and it stays right of the card's centre so the parent line below stays free.
          The ⋯ button is gone: right-click opens the card menu, which now ends with “Create bookmark here…” and “Create tag
          here…”, so a change without refs can get a tag (there is no hover “+” for tags).</p>
        <CardsScene/>
        <p className="rs-note rs-after">Keyboard: on a focused card the context-menu key or ⇧F10 opens the same menu.
          VoiceOver keeps a “Show menu” action on every card.</p>
      </section>

      <section>
        <h2>2 · Left rail</h2>
        <p className="rs-note">Tags get their own button under Bookmarks: same 40 × 40 button, same hover callout (first five, then “+N more”).</p>
        <RailScene/>
      </section>

      <section>
        <h2>3 · Bookmarks view</h2>
        <p className="rs-note">The pinned panel as a tree of the “/” segments: folders open and close with their icon, leaves
          show the last segment, no bookmark icon. Under the name: change id · subject. On the right: ✓ in sync, ↑2 ahead,
          “deleted” (gone here, still on origin), the conflict mark; a local-only bookmark shows nothing. A remote-only
          name is dimmed and ends in @origin. The filter field searches this tree only. On the hovered row the state mark
          gives way to buttons; the row keeps its height. Choose “on rows” above to see one row of each kind.</p>
        <div className="rs-flow">
          <div><div className="rs-cap">Rows of each kind: local (pager), tracked (auth-flow), untracked remote (1.4.x)</div>
            <RefPanel title="Bookmarks" icon="branch" kind="bookmark" items={BOOKMARKS} height={600}
              fhov={["feature/onboarding/pager", "feature/auth-flow", "release/1.4.x@origin"]}/></div>
          <div><div className="rs-cap">Filtered: “onb” — only matching names and their folders, the folders open</div>
            <RefPanel title="Bookmarks" icon="branch" kind="bookmark" items={BOOKMARKS} initialQ="onb" height={600}/></div>
          <ul className="rs-legend">
            <li><b>Local</b> — <Ic n="plus" s={12}/> New change here (<code>jj new name</code>) · <Ic n="trash" s={12}/> Delete…</li>
            <li><b>Tracked</b> — also Untrack (<code>jj bookmark untrack name@origin</code>); Delete… asks where (section 5)</li>
            <li><b>Untracked remote</b> — Track (<code>jj bookmark track name@origin</code>) · New change here</li>
            <li><b>Deleted here, tracked</b> — Untrack · New change here</li>
          </ul>
        </div>
      </section>

      <section>
        <h2>4 · Tags view</h2>
        <p className="rs-note">The same panel and tree for tags. Row buttons: New change here (<code>jj new v1.4.2</code>) and Delete….</p>
        <RefPanel title="Tags" icon="tag" kind="tag" items={TAGS} height={460} fhov={["v1.4.2"]}/>
      </section>

      <section>
        <h2>5 · Delete dialog</h2>
        <p className="rs-note">Only when the bookmark is also on a remote. A bookmark with no remote is deleted at once, with
          no dialog; the toast offers Undo.</p>
        <div className="rs-flow">
          <DeleteSheet name="feature/auth-flow" what="bookmark" choices={BM_DELETE} init="delete" width={460}/>
          <DeleteSheet name="v1.5.0-rc1" what="tag" choices={TAG_DELETE} init="delete" width={400}/>
        </div>
      </section>

      <section>
        <h2>6 · Name field</h2>
        <p className="rs-note">Characters git refuses are replaced with “_” while typing and on paste. Rules about the whole
          name (leading or trailing “/” or “.”, “..”, “{"@{"}”, a “.lock” ending, “//”) show an error instead: replacing them
          while typing would fight the user. Type in the fields to try it.</p>
        <div className="rs-flow">
          <div><div className="rs-cap">(a) typed <code>feature/my new:idea?</code></div><NameSheet init="feature/my new:idea?"/></div>
          <div><div className="rs-cap">(b) pasted <code>fix/login ~ crash</code></div><NameSheet init="fix/login ~ crash"/></div>
          <div><div className="rs-cap">(c) a rule the replacement can't fix</div><NameSheet init="release/1.5."/></div>
        </div>
      </section>

      <section>
        <h2>7 · Move existing here…</h2>
        <p className="rs-note">A picker instead of a free-text field: it suggests names like the top search, shows where each
          one is now, and marks a move that goes backwards or sideways. Click a row to see its command.</p>
        <div className="rs-flow">
          <MovePicker kind="bookmark" init="feat"/>
          <MovePicker kind="tag" init="v1."/>
        </div>
      </section>

      <section>
        <h2>8 · Top search rows</h2>
        <p className="rs-note">Only the active (hovered or arrowed) row shows buttons, so the list stays calm: New change here
          before the change id, and Track for an untracked remote name.</p>
        <div className="rs-flow">
          <SearchDemo query="b:feat" rows={[{ ...bm("feature/auth-flow"), on: true }, bm("feature/onboarding/pager"), bm("feature/onboarding/swipe")]}/>
          <SearchDemo query="b:rel" rows={[bm("release/1.5.x"), { ...bm("release/1.4.x"), on: true }]}/>
        </div>
      </section>

      <section>
        <h2>9 · Top inset</h2>
        <p className="rs-note">Today the bar sits 4 from the top edge while the rail, the inspector and the bottom keep 12.
          Proposed: the bar 12 from the top too; the traffic lights move down to stay centred on the bar (y 34), and the
          content starts at 68. Drawn 1 : 1.</p>
        <div className="rs-flow">
          <Inset title="Today" mid={26}/>
          <Inset title="Proposed" mid={34}/>
        </div>
      </section>
    </div>
  );
}

ReactDOM.createRoot(document.getElementById("root")).render(<App/>);
})();
