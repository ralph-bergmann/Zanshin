/* global React, ReactDOM */
// Graph Lines Study — same cards, data and layout engine as the floating client (graph-layout.jsx: computeLayout + groupStacks).
// Only the line routing differs: A = the client before · B = one line per parent→child pair (shipped) · C = shared fork lines, own merge ports.
(() => {
const { useState, useEffect, useMemo, useRef, useLayoutEffect } = React;
const { G, reroute } = window.GraphLayout;
const H = 62, WC = "ovknlmro", TARGET = "tzkvmrls", TRUNK = "vruxwmqv";
const PRESETS = [{ n: 1, extra: [] }, { n: 2, extra: ["jqntwrpx"] }, { n: 3, extra: ["jqntwrpx", "vtxnbqrs"] }];
// extra children of the trunk: more lines than a card's top edge has room for
const FAN = [
  ["wkpxnfqa", "spike(perf): frame timing overlay", "Bob", "2026-09-22T16:00", "3d"],
  ["rqmzlsvt", "spike(a11y): larger tap targets", "Lena König", "2026-09-23T11:00", "2d"],
  ["tvnplkqx", "spike(i18n): RTL layout pass", "Charlie Davis", "2026-09-23T17:30", "2d"],
  ["zmqrwnkp", "spike(ci): cache pub packages", "Bob", "2026-09-24T07:30", "1d"],
  ["pkszvqmx", "spike(ui): skeleton loaders", "Lena König", "2026-09-24T13:00", "1d"],
  ["nwtlxrqv", "spike(api): retry budget", "Bob", "2026-09-24T16:30", "21h"],
  ["xqkvmnzs", "spike(ux): undo toast", "Ralph Stein", "2026-09-25T07:00", "7h"],
  ["lrvpqtwn", "spike(web): PWA manifest", "Charlie Davis", "2026-09-25T10:30", "3h"],
].map(([id, subject, author, ts, date], k) => ({ id, changeId: id, commitId: (0x5a17c0de + k * 7919).toString(16).slice(0, 8), parents: [TRUNK], subject, description: "",
  author, date, ts, priority: 10 + k, bookmarks: [], files: [], immutable: false, inDefault: true, isEmpty: false, isWorkingCopy: false, hasConflict: false, isMerge: false,
  stats: { added: 12 + k * 7, removed: k * 3, files: 1 + (k % 3) } }));
const FANS = [{ v: 0, l: "As is" }, { v: 4, l: "+4 children" }, { v: 8, l: "+8 children" }];
const VARIANTS = [
  { id: "A", label: "Before", note: "The client before: children on the same side of a parent share one line. Every parent of a merge enters the card at its bottom centre." },
  { id: "B", label: "Own lines", tag: "client", note: "Every parent → child pair is its own line with its own exit and entry; lines nest instead of crossing. Too little card width: the exits squeeze to 7 px apart, then the outermost lines share one exit and split above the card." },
  { id: "C", label: "Shared forks", note: "A parent's children still share one line — but lines of different parents never run on top of each other, and each parent of a merge has its own port." },
];
const KEY = "zanshin.linesStudy.";
function usePersist(k, init) {
  const [v, setV] = useState(() => { try { const s = localStorage.getItem(KEY + k); return s == null ? init : JSON.parse(s); } catch { return init; } });
  useEffect(() => { try { localStorage.setItem(KEY + k, JSON.stringify(v)); } catch {} }, [v]);
  return [v, setV];
}

// ---------- cards (static copies of the client's GraphCard / StackCard, detailed) ----------
const MERGE_I = <svg width="12" height="12" viewBox="0 0 16 16"><g stroke="currentColor" strokeWidth="1.4" fill="none" strokeLinecap="round"><path d="M5 3v6a3 3 0 0 0 3 3h3"/><circle cx="5" cy="3" r="1.5"/><circle cx="11" cy="12" r="1.5"/></g></svg>;
const CONFLICT_I = <svg width="12" height="12" viewBox="0 0 16 16"><g stroke="currentColor" strokeWidth="1.4" fill="none" strokeLinecap="round" strokeLinejoin="round"><path d="M8 1.5L1.5 13.5h13L8 1.5z"/><path d="M8 6v3.5M8 11v0.4"/></g></svg>;
function Bookmark({ c }) {
  const s = window.shortBookmark(c.bookmarks[0].name);
  return (
    <div className="gbm is-legend has">
      <span className="gbm-trigger">
        <window.BookmarkGlyph filled size={11}/>
        {s.prefix && <span className="gbm-rest gbm-prefix">{s.prefix}</span>}
        <span className="gbm-main">{s.main}</span>
        {s.remote && <span className="gbm-rest">@{s.remote}</span>}
        {s.rest && <span className="gbm-rest gbm-shrink">{s.rest}</span>}
        {c.bookmarks.length > 1 && <span className="gbm-more">+{c.bookmarks.length - 1}</span>}
      </span>
    </div>
  );
}
function Card({ n, w, sel, dim, onPick, onHover }) {
  const c = n.c, grp = !!c.isGroup, wc = c.id === WC;
  const cls = "gcard is-detailed add-menu " + (grp ? "gstack " : "") + (wc ? "wc " : "") + (sel ? "sel " : "") + (c.immutable ? "immutable " : "") +
    (c.isRoot ? "root " : "") + (!grp && c.bookmarks.length ? "has-legend " : "") + (dim ? "dim " : "");
  const conflict = c.hasConflict && <span className="gflag conflict" title="conflict">{CONFLICT_I}</span>;
  let body;
  if (grp) {
    const m = c.members, a = m[0].id, b = m[m.length - 1].id;
    body = <>
      <div className="gline"><span className="gstack-n">{m.length}</span><span className="gsubj">{c.subject}</span></div>
      <div className="gline gmeta">
        <span className="gcid"><b>{b.slice(0, 2)}</b>{b.slice(2, 5)}<span className="grange-sep">‥</span><b>{a.slice(0, 2)}</b>{a.slice(2, 5)}</span>
        <span className="gmeta-t au">{c.author}</span><span className="gmeta-t">{c.date}</span>{conflict}
      </div>
    </>;
  } else body = <>
    <div className="gline"><span className={"gsubj " + (c.isEmpty || c.isRoot ? "is-dim" : "")}>{c.subject}</span></div>
    <div className="gline gmeta">
      {wc && <span className="gat">@</span>}
      <span className="gcid">{c.immutable && !c.isRoot && <span className="gimm">◆</span>}<b>{c.id.slice(0, 2)}</b>{c.id.slice(2, wc ? 5 : 8)}</span>
      {c.author && <span className="gmeta-t au">{c.author.split(" ")[0]}</span>}
      {c.date && <span className="gmeta-t">{c.date}</span>}
      {c.isEmpty && <span className="gmeta-t em">empty</span>}
      {conflict}
      {c.isMerge && <span className="gflag" title="merge">{MERGE_I}</span>}
    </div>
    {!c.isRoot && c.bookmarks.length > 0 && <Bookmark c={c}/>}
  </>;
  return (
    <div className={cls} style={{ left: n.x, top: n.y, width: w, height: H }} data-change={c.id}
      onClick={(e) => onPick(n, e)} onMouseEnter={() => onHover(n.id)} onMouseLeave={() => onHover(null)}>{body}</div>
  );
}
const Cid = ({ id }) => <span className="ls-cid"><b>{id.slice(0, 2)}</b>{id.slice(2, 5)}</span>;

// ---------- study ----------
function LinesStudy() {
  const [variant, setVariant] = usePersist("variant", "B");
  const [target, setTarget] = usePersist("target", TARGET);
  const [extra, setExtra] = usePersist("extra", PRESETS[2].extra);
  const [fan, setFan] = usePersist("fan", 0);
  const [layoutPick, setLayout] = usePersist("layout2", "free");
  const [w, setW] = usePersist("width", 240);
  const [zoom, setZoom] = usePersist("zoom", "fit");
  const layout = layoutPick === "compact" ? "compact" : "free";
  const [hover, setHoverRaw] = useState(null);
  const [msg, setMsg] = useState(null);
  const msgT = useRef(0), hovT = useRef(0);
  const setHover = (id) => { clearTimeout(hovT.current); if (id) setHoverRaw(id); else hovT.current = setTimeout(() => setHoverRaw(null), 120); };
  const say = (t) => { clearTimeout(msgT.current); setMsg(t); msgT.current = setTimeout(() => setMsg(null), 2800); };
  const base = useMemo(() => [...window.GRAPH_COMMITS, ...FAN.slice(0, fan)], [fan]);
  const byId = useMemo(() => new Map(base.map(c => [c.id, c])), [base]);
  const tgt = byId.get(target) || byId.get(TARGET);
  const commits = useMemo(() => base.map(c => c.id === tgt.id && extra.length
    ? { ...c, parents: [...c.parents, ...extra.filter(x => !c.parents.includes(x) && byId.has(x))], isMerge: true } : c), [base, tgt, extra]);
  const list = useMemo(() => window.groupStacks(commits, "default", []).list, [commits]);
  const L = useMemo(() => window.computeLayout(list, "default", w, H, layout, { optimize: true }), [list, layout, w]);
  const R = useMemo(() => variant === "B" ? L : reroute(L, w, H, variant), [L, variant, w]);
  const nodeOf = (id) => L.N.get(id) || L.nodes.find(n => n.c.isGroup && n.c.members.some(m => m.id === id));
  const tNode = nodeOf(tgt.id);
  const desc = useMemo(() => {
    const kids = new Map();
    commits.forEach(c => c.parents.forEach(p => { if (!kids.has(p)) kids.set(p, []); kids.get(p).push(c.id); }));
    const s = new Set([tgt.id]), st = [tgt.id];
    while (st.length) (kids.get(st.pop()) || []).forEach(k => { if (!s.has(k)) { s.add(k); st.push(k); } });
    return s;
  }, [commits, tgt]);
  const short = (id) => id.slice(0, 5);
  const pick = (n, e) => {
    const c = n.c, id = c.isGroup ? c.members[c.members.length - 1].id : n.id;
    if (e.shiftKey) { if (id !== tgt.id) { setTarget(id); setExtra([]); } return; }
    if (c.isGroup ? c.members.some(m => m.id === tgt.id) : id === tgt.id) return say(`That is ${short(tgt.id)} itself — ⇧-click picks another change`);
    if (extra.includes(id)) return setExtra(extra.filter(x => x !== id));
    if (tgt.parents.includes(id)) return say(`${short(id)} is already its first parent`);
    if (desc.has(id)) return say(`${short(id)} sits on top of ${short(tgt.id)} — that would be a loop`);
    setExtra([...extra, id]);
  };
  const preset = tgt.id === TARGET ? PRESETS.find(p => p.extra.length === extra.length && p.extra.every((x, i) => x === extra[i])) : null;
  const choose = (p) => { setTarget(TARGET); setExtra(p.extra); };
  useEffect(() => {
    const k = (e) => {
      if (e.metaKey || e.ctrlKey || e.altKey || /INPUT/.test((document.activeElement || {}).tagName || "")) return;
      const v = e.key.toUpperCase();
      if (v === "A" || v === "B" || v === "C") setVariant(v);
      const p = PRESETS.find(x => String(x.n) === e.key); if (p) choose(p);
    };
    window.addEventListener("keydown", k);
    return () => window.removeEventListener("keydown", k);
  }, []);

  // hover focus + @ ancestry, as in the client
  const anc = useMemo(() => { const s = new Set(), st = [WC]; while (st.length) { const x = st.pop(), n = L.N.get(x); if (!n || s.has(x)) continue; s.add(x); n.parents.forEach(p => st.push(p.id)); } return s; }, [L]);
  const focus = useMemo(() => {
    if (!hover || !L.N.get(hover)) return null;
    const s = new Set([hover]);
    [true, false].forEach(upw => { const st = [hover]; while (st.length) { const n = L.N.get(st.pop()); (upw ? n.parents.map(p => p.id) : n.children).forEach(x => { if (!s.has(x)) { s.add(x); st.push(x); } }); } });
    return s;
  }, [L, hover]);
  const st = R.edges.map((e, i) => { const hl = anc.has(e.from) && anc.has(e.to), hov = !!focus && focus.has(e.from) && focus.has(e.to); return { ...e, i, hl, hov, dim: !!focus && !hov }; })
    .sort((a, b) => (a.hl - b.hl) || (a.hov - b.hov));
  const est = new Map(st.map(e => [e.i, e]));
  const cuts = new Map(), addCut = (i, r) => { if (!cuts.has(i)) cuts.set(i, []); cuts.get(i).push(r); };
  R.edges.forEach((e, i) => e.cuts.forEach(r => addCut(i, r)));
  R.markers.forEach(m => { const r = window.gapCut(m, "break"); if (r) m.edges.forEach(i => addCut(i, r)); });
  const mCls = (m) => { const es = m.edges.map(i => est.get(i)).filter(Boolean); return (es.length && es.every(e => e.hl) ? "hl " : "") + (es.some(e => e.hov) ? "hov " : "") + (es.length && es.every(e => e.dim) ? "dim" : ""); };
  const sCls = (s) => (anc.has(s.node) ? "hl " : "") + (hover === s.node ? "hov " : "") + (focus && !focus.has(s.node) ? "dim" : "");
  const outs = R.edges.filter(e => e.from === TRUNK).length;

  // viewport: fit or 100 %, target kept in view when the graph changes
  const scRef = useRef(null), pan = useRef(null);
  const [vp, setVp] = useState({ w: 1200, h: 800 });
  const [panning, setPanning] = useState(false);
  useLayoutEffect(() => {
    const el = scRef.current, read = () => setVp({ w: el.clientWidth, h: el.clientHeight });
    read(); const ro = new ResizeObserver(read); ro.observe(el); return () => ro.disconnect();
  }, []);
  const PT = 132, PB = 232, PX = 24;
  const z = zoom === "fit" ? Math.max(0.3, Math.min(1, (vp.w - PX * 2) / L.width)) : 1;
  useLayoutEffect(() => {
    const el = scRef.current; if (!el || !tNode) return;
    el.scrollTo({ left: PX + tNode.cx * z - el.clientWidth / 2, top: PT + (tNode.y + H / 2) * z - el.clientHeight / 2 });
  }, [L, z, tgt.id]);
  const down = (e) => {
    if (e.button !== 0 || e.target.closest(".gcard")) return;
    const el = scRef.current;
    pan.current = { x: e.clientX, y: e.clientY, l: el.scrollLeft, t: el.scrollTop };
    el.setPointerCapture(e.pointerId); setPanning(true);
  };
  const move = (e) => { const p = pan.current, el = scRef.current; if (!p) return; el.scrollLeft = p.l - (e.clientX - p.x); el.scrollTop = p.t - (e.clientY - p.y); };
  const up = () => { pan.current = null; setPanning(false); };

  const parents = commits.find(c => c.id === tgt.id).parents;
  const V = VARIANTS.find(v => v.id === variant);
  const seg = (items, val, set) => (
    <div className="ls-seg" role="radiogroup">
      {items.map(it => <button key={it.v} role="radio" aria-checked={val === it.v} className={val === it.v ? "on" : ""} onClick={() => set(it.v)}>
        {it.k && <kbd>{it.k}</kbd>}{it.l}{it.tag && <span className="ls-tag">{it.tag}</span>}</button>)}
    </div>
  );
  return (
    <div className="fwin ls">
      <div className={"gscroll ls-scroll" + (panning ? " panning" : "")} ref={scRef} onPointerDown={down} onPointerMove={move} onPointerUp={up} onPointerCancel={up} data-screen-label="Graph lines">
        <div className="ls-sizer" style={{ width: L.width * z + PX * 2, height: L.height * z + PT + PB }}>
          <div className="ls-plane" style={{ left: PX, top: PT, width: L.width, height: L.height, transform: `scale(${z})` }}>
            {L.days.length > 0 && (
              <div className="gtime ls-days" style={{ height: L.height, width: G.gutter }}>
                {L.days.map(d => <div key={d.key} className="gtime-label" style={{ top: d.y }}>{d.label}</div>)}
              </div>
            )}
            <svg className="gedges" width={L.width} height={L.height}>
              {L.days.filter(d => d.guide != null).map(d => <line key={"g" + d.key} x1={L.offX} x2={L.width} y1={d.guide} y2={d.guide} className="gguide"></line>)}
              <defs>
                {[...cuts].map(([i, rs]) => (
                  <mask key={i} id={"lsm" + i} maskUnits="userSpaceOnUse" x="0" y="0" width={L.width} height={L.height}>
                    <rect x="0" y="0" width={L.width} height={L.height} fill="white"></rect>
                    {rs.map((g, k) => <rect key={k} x={g.x} y={g.y} width={g.w} height={g.h} fill="black"></rect>)}
                  </mask>
                ))}
              </defs>
              {st.map(e => <path key={e.from + ">" + e.to} d={e.d} mask={cuts.has(e.i) ? `url(#lsm${e.i})` : undefined}
                className={"gedge " + (e.dashed ? "dashed " : "") + (e.hov ? "hov " : "") + (e.hl ? "hl " : "") + (e.dim ? "dim" : "")}></path>)}
              {R.markers.map(m => <window.GapMark key={m.key} m={m} variant="break" count={null} cls={mCls(m)}/>)}
              {R.stubs.map(s => <window.GapEnd key={s.key} s={s} variant="break" count={null} cls={sCls(s)}/>)}
            </svg>
            {L.nodes.map(n => <Card key={n.id} n={n} w={w} sel={n === tNode} dim={!!focus && !focus.has(n.id)} onPick={pick} onHover={setHover}/>)}
          </div>
        </div>
      </div>

      <div className="ls-panel ls-top fl-glass">
        {seg(VARIANTS.map(v => ({ v: v.id, k: v.id, l: v.label, tag: v.tag })), variant, setVariant)}
        <p className="ls-note">{V.note}</p>
      </div>

      <div className="ls-panel ls-scn fl-glass">
        <div className="ls-h">Parents of <Cid id={tgt.id}/></div>
        {seg(PRESETS.map(p => ({ v: p.n, k: String(p.n), l: p.n === 1 ? "1 parent" : p.n + " parents" })), preset ? preset.n : null, (v) => choose(PRESETS.find(p => p.n === v)))}
        <div className="ls-chain">
          {parents.map((id, i) => (
            <span key={id} className={"ls-chip" + (i ? " is-x" : "")} onMouseEnter={() => { const n = nodeOf(id); if (n) setHover(n.id); }} onMouseLeave={() => setHover(null)}>
              <i>{i + 1}</i><Cid id={id}/>
              {i > 0 && extra.includes(id) && <button aria-label={"Remove " + id} onClick={() => setExtra(extra.filter(x => x !== id))}>✕</button>}
            </span>
          ))}
        </div>
        <div className="ls-rule"></div>
        <div className="ls-h">Lines out of <Cid id={TRUNK}/><span className="ls-n">{outs}</span></div>
        {seg(FANS, fan, setFan)}
        <p className="ls-hint">{msg || "Hover a card to trace its lines. Click a card to add or remove it as a parent; ⇧-click picks another change. Narrow the cards to see the exits squeeze."}</p>
      </div>

      <div className="ls-panel ls-view fl-glass">
        {seg([{ v: "free", l: "Free" }, { v: "compact", l: "Compact" }], layout, setLayout)}
        <label className="ls-w">
          <span>Card width</span>
          <input type="range" className="gtb-range" min="160" max="400" step="10" value={w} style={{ "--p": ((w - 160) / 240) * 100 + "%" }} onChange={(e) => setW(+e.target.value)} aria-label="Card width"/>
          <span className="gtb-val">{w}px</span>
        </label>
        {seg([{ v: "fit", l: "Fit" }, { v: "100", l: "100 %" }], zoom, setZoom)}
      </div>
    </div>
  );
}

ReactDOM.createRoot(document.getElementById("root")).render(<LinesStudy/>);
})();
