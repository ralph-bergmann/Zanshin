// Graph: stack folding, the plane (cards, the router's lines, gaps, end stubs, the day axis, peek) and the minimap. Layout: layout.js.
(() => {
const { ChangeCard, StackCard, GraphEdge, GraphEnd, PeekCard, DayAxis } = window.ZanshinDesignSystem_a33847;
const G = window.ZK_G;

const allParents = (n) => [...n.parents, ...n.gapParents];

// linear runs of ≥ 2 changes: one parent, one child, no bookmark, not @ — and never across a gap
function zkStackRuns(changes, wc) {
  const by = new Map(changes.map((c) => [c.id, c])), kids = new Map();
  changes.forEach((c) => allParents(c).forEach((p) => { if (!kids.has(p)) kids.set(p, []); kids.get(p).push({ id: c.id, gap: c.gapParents.includes(p) }); }));
  const ok = (c) => c && c.id !== wc && !c.bookmarks.length && !c.merge && !c.conflict && allParents(c).length === 1 && (kids.get(c.id) || []).length === 1;
  const runs = [], seen = new Set();
  changes.forEach((c) => {
    if (seen.has(c.id) || !ok(c)) return;
    let b = c;
    while (b.parents.length === 1 && ok(by.get(b.parents[0]))) b = by.get(b.parents[0]);
    const run = [b]; seen.add(b.id);
    for (let cur = b; ;) {
      const k = kids.get(cur.id)[0], n = by.get(k.id);
      if (k.gap || !ok(n) || n.parents.length !== 1) break;
      run.push(n); seen.add(n.id); cur = n;
    }
    if (run.length >= 2) runs.push(run);
  });
  return runs;
}

function zkFold(changes, wc, stacksOn, expanded) {
  const runs = stacksOn ? zkStackRuns(changes, wc).filter((r) => !expanded.includes(r[0].id)) : [];
  const hide = new Map();
  runs.forEach((r) => r.forEach((m) => hide.set(m.id, "s:" + r[0].id)));
  const map = (p) => hide.get(p) || p;
  const nodes = changes.filter((c) => !hide.has(c.id)).map((c) => ({ ...c, parents: [...new Set(c.parents.map(map))], gapParents: c.gapParents.map(map) }));
  runs.forEach((r) => {
    const bot = r[0], top = r[r.length - 1];
    nodes.push({ id: "s:" + bot.id, stack: true, members: r, count: r.length, subject: top.subject, author: top.author.split(" ")[0], date: top.date, t: top.t,
      parents: bot.parents.slice(), gapParents: bot.gapParents.slice(), lane: bot.lane, bookmarks: [], immutable: r.every((m) => m.immutable), conflict: r.some((m) => m.conflict) });
  });
  return nodes;
}

function zkAncestors(nodes, id) {
  const by = new Map(nodes.map((n) => [n.id, n])), s = new Set(), st = [id];
  while (st.length) { const x = st.pop(); if (s.has(x) || !by.has(x)) continue; s.add(x); allParents(by.get(x)).forEach((p) => st.push(p)); }
  return s;
}

const zkCount = (files) => files.reduce((s, f) => { f.hunks.forEach((h) => h.lines.forEach((l) => { if (l[0] === "+") s.a++; else if (l[0] === "-") s.r++; })); return s; }, { a: 0, r: 0 });
const zkFileCounts = (files) => ({ a: files.filter((f) => f.status === "A").length, m: files.filter((f) => f.status === "M").length, d: files.filter((f) => f.status === "D").length });

function ZKPeek({ n, isWC, style }) {
  const st = zkCount(n.files || []);
  // an immutable change can't be edited: its hint leaves out the double-click, its eyebrow says why
  const hint = (isWC ? "Working copy (@) · Click for details" : n.immutable ? "Click: details" : "Click: details · Double-click: jj edit") + " · Drag: onto another change · Right-click: actions";
  return (
    <div className="zk-peek" style={style}>
      <PeekCard id={n.id} commit={n.commit} subject={n.subject || "(no description set)"} description={n.description} author={n.author} date={n.date}
        files={zkFileCounts(n.files || [])} added={st.a} removed={st.r} hint={hint} immutable={!!n.immutable} immutableWhy={n.immWhy}/>
    </div>
  );
}

function ZKStackPop({ n, style }) {
  return (
    <div className="zk-stackpop" style={style}>
      {n.members.slice().reverse().map((m) => (
        <div key={m.id} className="zk-stackpop-row">
          <span className="zs-cid"><b>{m.id.slice(0, 2)}</b>{m.id.slice(2, 6)}</span>
          <span className="zk-stackpop-subj">{m.subject}</span>
          <span className="zk-stackpop-date">{m.date}</span>
        </div>
      ))}
      <div className="zk-stackpop-hint">Click to expand {n.count} changes</div>
    </div>
  );
}

function ZKPlane({ nodes, L, W, H, axisLeft = 0, detailed, wcId, selId, hoverId, menuId, peekId, dnd, bornId, flashIds, moving, view, onSelect, onDouble, onMenu, onHover, onToggleStack, onCardDown }) {
  const anc = zkAncestors(nodes, wcId);
  const edges = L.edges.map((e) => {
    const wc = anc.has(e.to) && anc.has(e.from), hov = hoverId && (hoverId === e.to || hoverId === e.from);
    return { ...e, kind: wc ? "wc" : hov ? "hover" : "normal", z: wc ? 2 : hov ? 1 : 0 };
  });
  const ends = L.ends.map((e) => ({ ...e, kind: anc.has(e.id) ? "wc" : "normal" }));
  edges.sort((x, y) => x.z - y.z);
  const peek = peekId && !dnd && !menuId ? nodes.find((n) => n.id === peekId) : null;
  let peekEl = null;
  if (peek) {
    const p = L.pos.get(peek.id);
    if (peek.stack) peekEl = <ZKStackPop n={peek} style={{ left: p.x, top: p.y + H + 12 }}/>;
    else {
      const right = p.x + W + 18 + 340 > view.right;
      const up = view.bottom - p.y < 260 && p.y - view.top > view.bottom - p.y;
      peekEl = <ZKPeek n={peek} isWC={peek.id === wcId} style={{ left: right ? p.x - 18 - 340 : p.x + W + 18, top: up ? p.y + H + 6 : p.y - 6, transform: up ? "translateY(-100%)" : undefined }}/>;
    }
  }
  return (
    <div className={"zk-plane" + (moving ? " is-moving" : "")} style={{ width: L.width, height: L.height }}>
      {L.days.length > 0 && <DayAxis width={L.width} height={L.height} days={L.days} stickyLeft={Math.max(0, axisLeft - 6)} labelLeft={2}/>}
      <svg className="zk-edges" width={L.width} height={L.height}>
        {edges.map((e) => <GraphEdge key={e.key} points={e.pts} kind={e.kind} gap={e.dashed} cuts={e.cuts}/>)}
        {ends.map((e) => <GraphEnd key={e.key} x={e.x} y={e.y} kind={e.kind}/>)}
      </svg>
      {nodes.map((n) => {
        const p = L.pos.get(n.id), style = { left: p.x, top: p.y };
        const hov = { onMouseEnter: () => onHover(n.id), onMouseLeave: () => onHover(null) };
        if (n.stack) return <StackCard key={n.id} className="zk-node" style={style} width={W} detailed={detailed} count={n.count} subject={n.subject} from={n.members[n.members.length - 1].id} to={n.members[0].id} immutable={n.immutable}
          author={n.author} date={n.date} onClick={() => onToggleStack(n.members[0].id)} {...hov}/>;
        const isDnd = dnd && (dnd.src === n.id ? "src" : dnd.from === n.id ? "from" : null);
        return <ChangeCard key={n.id} className={"zk-node" + (n.id === bornId ? " zk-born" : "")} style={style} width={W} detailed={detailed}
          id={n.id} subject={n.subject} author={n.author} date={n.date} bookmarks={n.bookmarks.map((b) => b.name)} workingCopy={n.id === wcId} selected={n.id === selId}
          immutable={n.immutable} empty={!n.files.length && !n.merge} conflict={n.conflict} merge={n.merge}
          drop={dnd && dnd.target === n.id} dragging={isDnd || undefined} flash={flashIds.includes(n.id)} menuOpen={menuId === n.id}
          onMenu={(e) => onMenu(n.id, e, true)} onBookmark={() => onSelect(n.id, true)}
          onClick={() => onSelect(n.id)} onDoubleClick={() => onDouble(n.id)} onContextMenu={(e) => { e.preventDefault(); onMenu(n.id, e); }}
          onPointerDown={(e) => onCardDown(e, n)} {...hov}
          onKeyDown={(e) => { if (e.target === e.currentTarget && (e.key === "Enter" || e.key === " ")) { e.preventDefault(); onSelect(n.id, true); } }}/>;
      })}
      {peekEl}
    </div>
  );
}

// MINIMAP — the graph's scroll indicator: time labels left, the graph in dots right, the viewport band, a gold line at its centre.
// Labels are calendar days only — "Today", "Yesterday", then dates ("Sep 23"), newest at the top. Cards keep their relative age (now · 3h · 2d).
// Free: the day axis's labels, which mark a day's bottom edge — the pill names the day the viewport centre is in.
// Compact: one label per row, only when its day is older than the one above it (compact rows mix generations).
const MINI_W = 118, MINI_SPLIT = 58, MINI_GL = 66;
const ZK_MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
function zkDay(t) {
  const now = new Date((window.ZK_DATA && window.ZK_DATA.now) || Date.now()), d = new Date(now.getTime() - (t || 0) * 60000);
  const day0 = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime(), dayD = new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime();
  const ago = Math.round((day0 - dayD) / 86400000);
  return { ago, label: ago === 0 ? "Today" : ago === 1 ? "Yesterday" : ZK_MONTHS[d.getMonth()] + " " + d.getDate() };
}
function ZKMinimap({ nodes, L, W, H, wcId, selId, view, scrollH, hidden, onJump }) {
  const ref = React.useRef(null), drag = React.useRef(false);
  const [mh, setMh] = React.useState(400), [hov, setHov] = React.useState(null);
  React.useEffect(() => { const ro = new ResizeObserver(([e]) => setMh(e.contentRect.height)); ro.observe(ref.current); return () => ro.disconnect(); }, []);
  const k = mh / Math.max(1, scrollH);
  const gr = MINI_W - 4, xs = nodes.map((n) => L.pos.get(n.id).x + W / 2), x0 = Math.min(...xs), x1 = Math.max(...xs);
  const kx = x1 > x0 ? Math.min((gr - MINI_GL) / (x1 - x0), 0.04) : 0;
  const mx = (x) => gr - (x1 - x) * kx, my = (y) => y * k;
  const by = new Map(nodes.map((n) => [n.id, n]));
  const pts = nodes.map((n) => { const p = L.pos.get(n.id); return { id: n.id, x: mx(p.x + W / 2), y: my(p.y + H / 2), grp: !!n.stack }; });
  const P = new Map(pts.map((p) => [p.id, p]));
  const lines = [];
  nodes.forEach((n) => allParents(n).forEach((pid) => {
    const a = P.get(pid), b = P.get(n.id); if (!a || !b) return;
    const bend = my(L.pos.get(n.id).y + H + G.gapY / 2);
    lines.push({ k: pid + ">" + n.id, dashed: n.gapParents.includes(pid), d: [[a.x, a.y], [a.x, bend], [b.x, bend], [b.x, b.y]].map(([x, y]) => x.toFixed(1) + "," + y.toFixed(1)).join(" ") });
  }));
  const vTop = my(view.top), vBot = my(view.bottom), cy = (vTop + vBot) / 2;
  const free = L.days.length > 0, rowLabels = [];
  if (free) L.days.forEach((d) => rowLabels.push({ label: d.label, y: my(d.y) }));
  else {
    const rowsByY = new Map();
    nodes.forEach((n) => { const y = L.pos.get(n.id).y, r = rowsByY.get(y); if (!r || n.t < r.t) rowsByY.set(y, n); });
    let lastAgo = -1;
    [...rowsByY.entries()].sort((a, b) => a[0] - b[0]).forEach(([y, n]) => { const d = zkDay(n.t); if (d.ago > lastAgo) { rowLabels.push({ label: d.label, y: my(y + H / 2) }); lastAgo = d.ago; } });
  }
  rowLabels.sort((a, b) => a.y - b.y);
  const labelAt = (y) => {
    if (free) { const l = rowLabels.find((x) => x.y >= y - 1) || rowLabels[rowLabels.length - 1]; return l ? l.label : ""; }
    let pick = rowLabels[0]; rowLabels.forEach((l) => { if (l.y <= y + 1) pick = l; }); return pick ? pick.label : "";
  };
  let last = -99;
  const shown = rowLabels.filter((l) => { if (l.y - last < 18 || Math.abs(l.y - cy) < 15 || (hov != null && Math.abs(l.y - hov) < 13)) return false; last = l.y; return true; });
  const layer = (cls, clip) => (
    <g className={"zk-mini-g " + cls} clipPath={clip}>
      {lines.map((e) => <polyline key={e.k} points={e.d} className={"zk-mini-e" + (e.dashed ? " dashed" : "")}></polyline>)}
      {pts.map((p) => <circle key={p.id} cx={p.x} cy={p.y} r={p.grp ? 2.6 : 2} className={"zk-mini-n" + (p.grp ? " grp" : "")}></circle>)}
    </g>
  );
  const mark = (id, cls) => { const p = id && P.get(id); return p ? <circle cx={p.x} cy={p.y} r="3.2" className={"zk-mini-n " + cls}></circle> : null; };
  const jump = (e) => { const r = ref.current.getBoundingClientRect(); onJump((e.clientY - r.top) / k); };
  return (
    <div className={"zk-mini" + (hidden ? " is-hidden" : "")} aria-label="Minimap" aria-hidden={hidden}>
      <div className="zk-mini-strip" ref={ref}
        onPointerDown={(e) => { drag.current = true; e.currentTarget.setPointerCapture(e.pointerId); setHov(null); jump(e); }}
        onPointerMove={(e) => { if (drag.current) return jump(e); const r = ref.current.getBoundingClientRect(); setHov(e.clientY - r.top); }}
        onPointerUp={() => { drag.current = false; }} onPointerLeave={() => setHov(null)}>
        <svg className="zk-mini-svg" width={MINI_W} height={mh}>
          <defs><clipPath id="zk-mini-clip"><rect x="-8" y={vTop} width={MINI_W + 16} height={Math.max(0, vBot - vTop)}></rect></clipPath></defs>
          <rect className="zk-mini-view" x={MINI_SPLIT + 2} y={vTop} width={MINI_W - MINI_SPLIT + 2} height={Math.max(4, vBot - vTop)} rx="4"></rect>
          {layer("", undefined)}
          {layer("in", "url(#zk-mini-clip)")}
          {mark(selId, "sel")}
          {mark(wcId, "wc")}
          {hov != null && <line className="zk-mini-hline" x1={MINI_SPLIT} x2={MINI_W} y1={hov} y2={hov}></line>}
          <line className="zk-mini-conn" x1={MINI_SPLIT} x2={MINI_W} y1={cy} y2={cy}></line>
        </svg>
        {shown.map((l) => <span key={l.label} className="zk-mini-lbl" style={{ top: l.y, right: MINI_W - MINI_SPLIT + 4 }}>{l.label}</span>)}
        {hov != null && <span className="zk-mini-pill is-hov" style={{ top: hov, right: MINI_W - MINI_SPLIT }}>{labelAt(hov)}</span>}
        <span className="zk-mini-pill" style={{ top: cy, right: MINI_W - MINI_SPLIT }}>{labelAt(cy)}</span>
      </div>
    </div>
  );
}

Object.assign(window, { zkFold, zkAncestors, zkCount, zkStackRuns, ZKPlane, ZKMinimap });
})();
