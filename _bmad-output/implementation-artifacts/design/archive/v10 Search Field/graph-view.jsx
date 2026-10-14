/* global React */
(() => {
const { useState, useEffect, useRef, useMemo, useLayoutEffect } = React;
const Ic = (p) => <window.Icon {...p}/>;

const G = { gapX: 56, gapY: 48, pad: 56, hCompact: 40, hDetailed: 62, elide: 44, gutter: 88 };

// Time buckets: one granularity everywhere — the calendar day. Today is the only relative label.
function timeBucket(c) {
  if (c.isRoot || !c.ts) return { key: -Infinity, label: "" };
  const d = new Date(Date.parse(c.ts)); d.setHours(0, 0, 0, 0);
  const today = new Date(Date.parse(window.GRAPH_NOW)); today.setHours(0, 0, 0, 0);
  return { key: d.getTime(), label: d.getTime() >= today.getTime() ? "Today" : d.toLocaleDateString("en-US", { month: "short", day: "numeric" }) };
}

function BookmarkGlyph({ filled, size = 14 }) {
  return (
    <svg width={size} height={size} viewBox="0 0 16 16" style={{ flexShrink: 0 }}>
      <path d="M4.6 2.2h6.8c.47 0 .85.38.85.85v10.4c0 .35-.4.55-.68.34L8 11.1l-3.57 2.69a.43.43 0 0 1-.68-.34V3.05c0-.47.38-.85.85-.85z"
        fill={filled ? "currentColor" : "none"} stroke="currentColor" strokeWidth="1.4" strokeLinejoin="round"/>
    </svg>
  );
}

// feature/ZAN-412_onboarding-swipe → { main: "ZAN-412", rest: "onboarding-swipe" }
function shortBookmark(name) {
  const [base, remote] = name.split("@");
  const m = base.match(/[A-Z][A-Z0-9]+-\d+/);
  if (m) return { main: m[0], rest: base.slice(m.index + m[0].length).replace(/^[_\-/.]+/, ""), remote };
  const seg = base.split("/");
  if (seg.length > 1) return { prefix: seg.slice(0, -1).join("/") + "/", main: seg[seg.length - 1], remote };
  return { main: base, remote };
}

function roundedPath(raw, r) {
  const pts = raw.filter((p, i) => i === 0 || p[0] !== raw[i - 1][0] || p[1] !== raw[i - 1][1]);
  let d = `M${pts[0][0]},${pts[0][1]}`;
  for (let i = 1; i < pts.length - 1; i++) {
    const [x0, y0] = pts[i - 1], [x1, y1] = pts[i], [x2, y2] = pts[i + 1];
    const l1 = Math.hypot(x1 - x0, y1 - y0), l2 = Math.hypot(x2 - x1, y2 - y1);
    const rr = Math.min(r, l1 / 2, l2 / 2);
    d += ` L${x1 - (x1 - x0) / l1 * rr},${y1 - (y1 - y0) / l1 * rr} Q${x1},${y1} ${x1 + (x2 - x1) / l2 * rr},${y1 + (y2 - y1) / l2 * rr}`;
  }
  const last = pts[pts.length - 1];
  return d + ` L${last[0]},${last[1]}`;
}

// Root at the bottom, children above (jj log order). Rows = generation depth (compact), lanes = greedy interval packing.
function routeEdges(nodes, N, W, H, xOf) {
  const out = [];
  nodes.forEach(n => n.parents.forEach((pp, i) => {
    const p = N.get(pp.id), pcx = xOf(p) + W / 2, ncx = xOf(n) + W / 2;
    const outY = p.y, inY = n.y + H;
    let pts;
    if (pcx === ncx) pts = [[pcx, outY], [ncx, inY]];
    else if (i > 0 && !pp.blocked) {     // merge: up in parent lane, then across into child
      const my = inY + G.gapY * 0.4;
      pts = [[pcx, outY], [pcx, my], [ncx, my], [ncx, inY]];
    } else {                             // branch-off: out of parent's side, across, then up
      const sx = pcx + (ncx > pcx ? 1 : -1) * W * 0.28, hy = outY - G.gapY * 0.4;
      pts = [[sx, outY], [sx, hy], [ncx, hy], [ncx, inY]];
    }
    out.push({ from: p.id, to: n.id, pts, dashed: pp.skipped, via: pp.via, count: pp.count, hiddenIds: pp.hiddenIds });
  }));
  return out;
}

// Orthogonal polylines → H/V crossings (+ collinear overlaps, which read as one line).
function analyzeEdges(edges) {
  const segs = edges.map(e => {
    const s = [];
    for (let i = 1; i < e.pts.length; i++) {
      const [x1, y1] = e.pts[i - 1], [x2, y2] = e.pts[i];
      if (x1 === x2 && y1 === y2) continue;
      s.push(y1 === y2 ? { h: true, c: y1, a: Math.min(x1, x2), b: Math.max(x1, x2) } : { h: false, c: x1, a: Math.min(y1, y2), b: Math.max(y1, y2) });
    }
    return s;
  });
  const cross = [];
  let overlaps = 0;
  const E = 1;
  for (let i = 0; i < edges.length; i++) for (let j = i + 1; j < edges.length; j++) {
    const A = edges[i], B = edges[j];
    if (A.from === B.from || A.to === B.to || A.from === B.to || A.to === B.from) continue;
    segs[i].forEach(s => segs[j].forEach(t => {
      if (s.h !== t.h) {
        const [h, v, hi] = s.h ? [s, t, i] : [t, s, j];
        if (v.c > h.a + E && v.c < h.b - E && h.c > v.a + E && h.c < v.b - E) cross.push({ x: v.c, y: h.c, edge: hi });
      } else if (Math.abs(s.c - t.c) < E && Math.min(s.b, t.b) - Math.max(s.a, t.a) > E) overlaps++;
    }));
  }
  return { cross, overlaps };
}

// Reorder lanes (lane 0 = trunk stays put) to minimise crossings, then edge length, then displacement from greedy order.
function optimizeLanes(nodes, N, laneCount, W, H) {
  const ident = [...Array(laneCount).keys()];
  if (laneCount < 3) return ident;
  const step = W + G.gapX;
  const cost = (pos) => {
    const edges = routeEdges(nodes, N, W, H, n => pos[n.lane] * step);
    const { cross, overlaps } = analyzeEdges(edges);
    let len = 0;
    edges.forEach(e => { len += Math.abs(e.pts[e.pts.length - 1][0] - e.pts[0][0]) / step; });
    let disp = 0;
    pos.forEach((p, l) => { disp += Math.abs(p - l); });
    return cross.length * 100 + overlaps * 100 + len + disp * 0.25;
  };
  let best = ident, bestC = cost(ident);
  const rest = ident.slice(1);
  if (rest.length <= 7) {
    const perm = (arr, k) => {
      if (k === arr.length) {
        const pos = [0]; arr.forEach((lane, i) => { pos[lane] = i + 1; });
        const c = cost(pos);
        if (c < bestC - 1e-9) { bestC = c; best = pos; }
        return;
      }
      for (let i = k; i < arr.length; i++) { [arr[k], arr[i]] = [arr[i], arr[k]]; perm(arr, k + 1); [arr[k], arr[i]] = [arr[i], arr[k]]; }
    };
    perm(rest.slice(), 0);
  } else {
    let improved = true;
    while (improved) {
      improved = false;
      for (let a = 1; a < laneCount; a++) for (let b = a + 1; b < laneCount; b++) {
        const pos = best.slice(), la = pos.indexOf(a), lb = pos.indexOf(b);
        pos[la] = b; pos[lb] = a;
        const c = cost(pos);
        if (c < bestC - 1e-9) { bestC = c; best = pos; improved = true; }
      }
    }
  }
  return best;
}

function computeLayout(all, revset, W, H, mode = "compact", opts = {}) {
  const byId = new Map(all.map(c => [c.id, c]));
  const rm = window.revsetMatch(revset);
  const list = all.filter(c => c.isGroup || rm(c));
  const vis = new Set(list.map(c => c.id));
  // parent edges: direct | indirect (skipped, via = hidden parent, hiddenIds = commits in the gap) | missing (no visible ancestor)
  const nodes = list.map((c, idx) => {
    const parents = [], missing = [];
    c.parents.forEach(pid => {
      if (vis.has(pid)) { if (!parents.some(p => p.id === pid)) parents.push({ id: pid, skipped: false }); return; }
      const hidden = [], hs = new Set(), found = [], q = [pid];
      while (q.length) {
        const x = q.shift();
        if (vis.has(x)) { if (!found.includes(x)) found.push(x); continue; }
        if (hs.has(x)) continue; hs.add(x); hidden.push(x);
        const cc = byId.get(x); if (cc) q.push(...cc.parents);
      }
      if (!found.length) { missing.push({ via: pid, count: hidden.length, hiddenIds: hidden }); return; }
      const memo = new Map();
      const reaches = (x, f) => {
        const k = x + ">" + f; if (memo.has(k)) return memo.get(k); memo.set(k, false);
        const cc = byId.get(x), r = !!cc && cc.parents.some(p => p === f || (hs.has(p) && reaches(p, f)));
        memo.set(k, r); return r;
      };
      found.forEach(f => {
        if (parents.some(p => p.id === f)) return;
        const ids = hidden.filter(x => reaches(x, f));
        parents.push({ id: f, skipped: true, via: pid, count: ids.length, hiddenIds: ids });
      });
    });
    return { c, id: c.id, idx, parents, missing, elided: missing.reduce((s, m) => s + m.count, 0), children: [] };
  });
  const N = new Map(nodes.map(n => [n.id, n]));
  nodes.forEach(n => n.parents.forEach(p => N.get(p.id).children.push(n.id)));
  const buckets = [];
  if (mode === "time") {
    const groups = new Map();
    nodes.forEach(n => { const b = timeBucket(n.c); if (!groups.has(b.key)) groups.set(b.key, { ...b, nodes: [] }); groups.get(b.key).nodes.push(n); });
    let next = 0;
    [...groups.keys()].sort((a, b) => a - b).forEach(k => {
      const g = groups.get(k), start = next; let end = start;
      g.nodes.sort((a, b) => (Date.parse(a.c.ts) || 0) - (Date.parse(b.c.ts) || 0));
      // same-minute parent and child (a split, a fresh jj new): place parents first, whatever the clock says
      const pend = g.nodes.slice(), inB = new Set(pend.map(n => n.id));
      while (pend.length) {
        const i = pend.findIndex(n => n.parents.every(p => !inB.has(p.id) || N.get(p.id).row != null));
        const n = pend.splice(i < 0 ? 0 : i, 1)[0];
        n.row = Math.max(start, ...n.parents.map(p => (N.get(p.id).row ?? -1) + 1)); end = Math.max(end, n.row);
      }
      buckets.push({ label: g.label, start, end });
      next = end + 1;
    });
  } else {
    const rowOf = (n) => n.row != null ? n.row : (n.row = n.parents.length ? Math.max(...n.parents.map(p => rowOf(N.get(p.id)))) + 1 : 0);
    nodes.forEach(rowOf);
  }

  const order = [...nodes].sort((a, b) => a.row - b.row || a.c.priority - b.c.priority || a.idx - b.idx);
  const lanes = [];
  const free = (L, a, b, allow) => !(lanes[L] || []).some(iv => iv.a <= b && a <= iv.b && iv.owner !== allow);
  order.forEach(n => {
    const fp = n.parents[0] ? N.get(n.parents[0].id) : null;
    // lifetime in own lane: merge children (routed up this lane) + the one first-parent child expected to continue it.
    // Other branch-off children leave from the card's side and don't need this lane.
    const kids = n.children.map(id => N.get(id));
    const cont = kids.filter(ch => ch.parents[0].id === n.id).sort((a, b) => a.c.priority - b.c.priority || a.idx - b.idx)[0];
    n.cont = cont ? cont.id : null;
    const childRows = kids.filter(ch => ch === cont || ch.parents.findIndex(p => p.id === n.id) > 0).map(ch => ch.row);
    const end = childRows.length ? Math.max(n.row, Math.max(...childRows) - 1) : n.row;
    const a = fp ? fp.row + 1 : n.row, b = end + 1; // +1 = one empty row buffer so unrelated chains never "touch"
    let L;
    if (fp && fp.cont === n.id && free(fp.lane, a, b, fp.id)) L = fp.lane;
    else { L = 0; while (!free(L, a, b, null)) L++; }
    (lanes[L] = lanes[L] || []).push({ a, b, owner: n.id });
    n.lane = L;
  });

  const laneCount = Math.max(1, ...nodes.map(n => n.lane + 1));
  const maxRow = Math.max(0, ...nodes.map(n => n.row));
  const botExtra = nodes.some(n => n.missing.length && n.row === 0) ? G.elide : 0;
  const offX = mode === "time" && opts.gutter !== false ? G.gutter : 0;
  const rowTop = (r) => G.pad + (maxRow - r) * (H + G.gapY);
  buckets.forEach((b, i) => { b.y = rowTop(b.start) + H / 2; b.guide = i > 0 ? rowTop(b.start) + H + G.gapY / 2 : null; });
  nodes.forEach(n => {
    n.y = rowTop(n.row);
    n.parents.forEach(pp => { const p = N.get(pp.id); pp.blocked = nodes.some(o => o.lane === p.lane && o.row > p.row && o.row <= n.row); });
  });
  // opts.cols: columns frozen from the fully expanded layout, so (un)grouping stacks only moves cards vertically.
  let frozen = false;
  if (opts.cols) {
    const cs = nodes.map(n => opts.cols.get(n.c.isGroup ? n.c.members[0].id : n.id));
    frozen = cs.every(v => v != null) && !nodes.some((a, i) => nodes.some((b, j) => j > i && cs[i] === cs[j] && a.row === b.row))
      && !nodes.some((n, i) => n.parents.some(pp => { const p = N.get(pp.id), pc = cs[nodes.indexOf(p)];
        return pc === cs[i] && nodes.some((o, k) => cs[k] === pc && o.row > p.row && o.row < n.row); }));
    if (frozen) nodes.forEach((n, i) => { n.col = cs[i]; });
  }
  if (!frozen) {
    const pos = opts.optimize ? optimizeLanes(nodes, N, laneCount, W, H) : [...Array(laneCount).keys()];
    nodes.forEach(n => { n.col = pos[n.lane]; });
  }
  nodes.forEach(n => {
    n.x = offX + G.pad + n.col * (W + G.gapX);
    n.cx = n.x + W / 2;
  });
  if (frozen) nodes.forEach(n => n.parents.forEach(pp => { const p = N.get(pp.id); pp.blocked = nodes.some(o => o.col === p.col && o.row > p.row && o.row <= n.row); }));
  const colCount = Math.max(1, ...nodes.map(n => n.col + 1));

  const raw = routeEdges(nodes, N, W, H, n => n.x);
  const { cross } = analyzeEdges(raw);
  const edges = raw.map((e, i) => ({ ...e, d: roundedPath(e.pts, 10), gaps: cross.filter(c => c.edge === i) }));
  const markers = window.placeGapMarkers(raw);
  // missing stubs: centered when the card has no other parent edge, otherwise off to the side so they never sit on a real edge
  const stubs = [];
  nodes.forEach(n => n.missing.forEach((m, k) => {
    const slots = n.parents.length ? [0.28, -0.28, 0.14] : [0, 0.28, -0.28];
    stubs.push({ kind: "end", key: n.id + "~" + m.via, node: n.id, x: n.cx + (slots[k] ?? 0) * W, y: n.y + H, ...m });
  }));

  return {
    nodes, N, edges, markers, stubs, buckets, offX, crossings: cross.length,
    width: offX + G.pad * 2 + colCount * (W + G.gapX) - G.gapX,
    height: G.pad * 2 + botExtra + (maxRow + 1) * (H + G.gapY) - G.gapY,
    total: all.length, shown: list.length,
  };
}

// Linear runs (1 parent, 1 child, no bookmark, not @) of ≥2 changes collapse into one synthetic "stack" commit.
function groupStacks(all, revset, expanded) {
  const vis = all.filter(window.revsetMatch(revset));
  const V = new Set(vis.map(c => c.id)), byId = new Map(all.map(c => [c.id, c]));
  const kids = new Map(vis.map(c => [c.id, []]));
  // descendants behind a gap count as children too: a direct child + one behind a gap = fork, the stack ends there
  const reach = (pid) => {
    const out = new Set(), seen = new Set(), st = [pid];
    while (st.length) { const x = st.pop(); if (seen.has(x)) continue; seen.add(x); if (V.has(x)) { out.add(x); continue; } const cc = byId.get(x); if (cc) st.push(...cc.parents); }
    return out;
  };
  vis.forEach(c => c.parents.forEach(p => {
    if (V.has(p)) kids.get(p).push(c.id);
    else reach(p).forEach(a => { if (!kids.get(a).includes(c.id)) kids.get(a).push(c.id); });
  }));
  // members need a direct, visible single parent: a change whose edge down is indirect or missing is never part of a stack
  const ok = c => c && !c.isRoot && !c.isWorkingCopy && !c.bookmarks.length && c.parents.length === 1 && V.has(c.parents[0]) && kids.get(c.id).length === 1;
  const nextOf = c => { const k = byId.get(kids.get(c.id)[0]); return ok(k) && k.parents[0] === c.id && k.immutable === c.immutable ? k : null; };
  const runs = [], memberOf = new Map();
  vis.forEach(c => {
    if (!ok(c)) return;
    const p = byId.get(c.parents[0]);
    if (ok(p) && nextOf(p) === c) return;
    const m = [c]; let x = c;
    while ((x = nextOf(x))) m.push(x);
    if (m.length < 2) return;
    const id = "grp:" + c.id, exp = expanded.includes(id);
    runs.push({ id, members: m, expanded: exp });
    if (!exp) m.forEach(mm => memberOf.set(mm.id, id));
  });
  if (!memberOf.size) return { list: all, runs };
  const out = [], done = new Set(), remap = pid => memberOf.get(pid) || pid;
  all.forEach(c => {
    const gid = memberOf.get(c.id);
    if (gid) {
      if (done.has(gid)) return; done.add(gid);
      const m = runs.find(r => r.id === gid).members, top = m[m.length - 1];
      const authors = [...new Set(m.map(x => x.author.split(" ")[0]))];
      out.push({ id: gid, isGroup: true, members: m, parents: [m[0].parents[0]], bookmarks: [], subject: top.subject,
        author: authors.join(", "), date: m[0].date === top.date ? top.date : m[0].date + " – " + top.date, ts: top.ts, priority: top.priority,
        immutable: m[0].immutable, inDefault: m.every(x => x.inDefault), hasConflict: m.some(x => x.hasConflict), isEmpty: false, isMerge: false,
        stats: m.reduce((s, x) => ({ added: s.added + x.stats.added, removed: s.removed + x.stats.removed }), { added: 0, removed: 0 }) });
      return;
    }
    out.push(c.parents.some(p => memberOf.has(p)) ? { ...c, parents: [...new Set(c.parents.map(remap))] } : c);
  });
  return { list: out, runs };
}

const GQ = new URLSearchParams(location.search), EMBED = GQ.has("embed");
function usePersist(key, init) {
  const [v, setV] = useState(() => {
    if (EMBED) return init;
    try { const s = localStorage.getItem(key); return s == null ? init : JSON.parse(s); } catch { return init; }
  });
  useEffect(() => { if (!EMBED) try { localStorage.setItem(key, JSON.stringify(v)); } catch {} }, [key, v]);
  return [v, setV];
}

const STATE_LABEL = { synced: "in sync with origin", ahead: "ahead of origin", behind: "behind origin", local: "local only", remote: "remote only", diverged: "diverged from origin" };

// ============================================================
// TOOLBAR
// ============================================================
function GraphToolbar({ revset, setRevset, layout, setLayout, detailed, setDetailed, stacks, setStacks, cardW, setCardW, shown, total, onLocate, gapInfo }) {
  const pct = ((cardW - 160) / (400 - 160)) * 100;
  return (
    <div className="gtb" role="toolbar" aria-label="Graph view">
      <window.RevsetSelect value={revset} onChange={setRevset}/>
      <window.GapLegend {...gapInfo} onShowAll={() => setRevset("all")}/>
      <div className="gtb-sep"/>
      <div className="gtb-group">
        <span className="gtb-label">Layout</span>
        <div className="gtb-seg" role="radiogroup" aria-label="Layout">
          <button role="radio" aria-checked={layout === "compact"} className={layout === "compact" ? "on" : ""} onClick={() => setLayout("compact")} title="Rows = dependency depth">Compact</button>
          <button role="radio" aria-checked={layout === "time"} className={layout === "time" ? "on" : ""} onClick={() => setLayout("time")} title="Rows = rounded commit time">Time</button>
        </div>
      </div>
      <div className="gtb-sep"/>
      <label className="gtb-group">
        <button role="switch" aria-checked={detailed} className={"gtb-switch " + (detailed ? "on" : "")} onClick={() => setDetailed(!detailed)}/>
        <span className="gtb-label">{detailed ? "Detailed cards" : "Compact cards"}</span>
      </label>
      <div className="gtb-sep"/>
      <label className="gtb-group" title="Collapse linear runs of changes into one stack card">
        <button role="switch" aria-checked={stacks} className={"gtb-switch " + (stacks ? "on" : "")} onClick={() => setStacks(!stacks)}/>
        <span className="gtb-label">Group stacks</span>
      </label>
      <div className="gtb-sep"/>
      <div className="gtb-group">
        <span className="gtb-label">Card width</span>
        <input type="range" className="gtb-range" min="160" max="400" step="10" value={cardW}
          style={{ "--p": pct + "%" }} onChange={(e) => setCardW(+e.target.value)} aria-label="Card width"/>
        <span className="gtb-val">{cardW}px</span>
      </div>
      <div className="gtb-right">
        <span className="gtb-count">{shown} / {total} commits</span>
        <button className="gtb-locate" onClick={onLocate} title="Scroll to working copy"><b>@</b>Working copy</button>
      </div>
    </div>
  );
}

// ============================================================
// BOOKMARK CONTROL — button top-right; with labels on, it becomes a
// legend sitting on the card's bottom border (top carries outgoing
// branch lines; bottom only has the centered incoming edge).
// ============================================================
function BookmarkControl({ bookmarks, legend, cid, onBeginDrag }) {
  const has = bookmarks.length > 0;
  const asLegend = legend && has;
  const s = has ? shortBookmark(bookmarks[0].name) : null;
  const stop = (e) => e.stopPropagation();
  const movable = (b) => !!onBeginDrag && b.state !== "remote" && !b.name.includes("@");
  const grab = (b) => (e) => { e.stopPropagation(); if (movable(b)) onBeginDrag(e, { kind: "bookmark", name: b.name, from: cid }); };
  return (
    <div className={"gbm " + (asLegend ? "is-legend " : "is-btn ") + (has ? "has" : "")} onClick={stop} onDoubleClick={stop} onPointerDown={stop}>
      <button className={"gbm-trigger" + (has && movable(bookmarks[0]) ? " is-grab" : "")} onPointerDown={has ? grab(bookmarks[0]) : undefined} aria-label={has ? "Bookmarks: " + bookmarks.map(b => b.name).join(", ") : "Add bookmark"}>
        <BookmarkGlyph filled={has} size={asLegend ? 11 : 14}/>
        {asLegend && <>
          {s.prefix && <span className="gbm-rest gbm-prefix" title={s.prefix}>{s.prefix}</span>}
          <span className="gbm-main">{s.main}</span>
          {s.remote && <span className="gbm-rest">@{s.remote}</span>}
          {s.rest && <span className="gbm-rest gbm-shrink">{s.rest}</span>}
          {bookmarks.length > 1 && <span className="gbm-more">+{bookmarks.length - 1}</span>}
        </>}
      </button>
      <div className="gbm-pop">
        <div className="gbm-pop-inner">
          {has ? bookmarks.map(b => (
            <div key={b.name} className={"gbm-item" + (movable(b) ? " is-grab" : "")} onPointerDown={grab(b)} title={movable(b) ? "Drag onto a change to move this bookmark" : undefined}>
              <BookmarkGlyph filled size={12}/>
              <span className="gbm-name">{b.name}</span>
              <span className={"gbm-state s-" + b.state}>{b.state === "ahead" ? `↑${b.ahead}` : ""} {STATE_LABEL[b.state]}</span>
            </div>
          )) : <div className="gbm-none">No bookmark on this change</div>}
          <div className="gbm-actions">
            {has
              ? <><button>Rename…</button><button>Move to…</button><button className="danger">Delete</button></>
              : <><button>Create bookmark here…</button><button>Move existing here…</button></>}
          </div>
        </div>
      </div>
    </div>
  );
}

// ============================================================
// QUICK ACTIONS — "more" button on the bottom-right border; on hover
// round action buttons fan out to the left (Flow-style stagger).
// List will later come from user settings.
// ============================================================
// new-change glyphs: rect = this change, bar = its neighbour (child above / parent below)
const QA_NEWG = { stroke: "currentColor", strokeWidth: 1.4, fill: "none", strokeLinecap: "round", strokeLinejoin: "round" };
const QA_ICON = {
  new: <g {...QA_NEWG}><rect x="2.5" y="10" width="11" height="4" rx="1.2"/><path d="M8 1.75v5.5M5.25 4.5h5.5"/></g>,
  after: <g {...QA_NEWG}><path d="M3.5 1.75h9"/><path d="M8 4v4.5M5.75 6.25h4.5"/><rect x="2.5" y="10.5" width="11" height="3.75" rx="1.2"/></g>,
  before: <g {...QA_NEWG}><rect x="2.5" y="1.75" width="11" height="3.75" rx="1.2"/><path d="M8 7.5v4.5M5.75 9.75h4.5"/><path d="M3.5 14.25h9"/></g>,
  edit: <text x="8" y="12" textAnchor="middle" fontSize="11" fontWeight="700" fill="currentColor" fontFamily="ui-monospace,monospace">@</text>,
  describe: <path d="M3 13l.6-2.6L10.5 3.5l2 2-6.9 6.9L3 13zM9.3 4.7l2 2" stroke="currentColor" strokeWidth="1.4" fill="none" strokeLinejoin="round"/>,
  squash: <g stroke="currentColor" strokeWidth="1.5" fill="none" strokeLinecap="round" strokeLinejoin="round"><path d="M8 2v7M5 6l3 3 3-3"/><path d="M3 13h10"/></g>,
  abandon: <g stroke="currentColor" strokeWidth="1.4" fill="none" strokeLinecap="round" strokeLinejoin="round"><path d="M3 4.5h10M6.5 4.5V3h3v1.5M4.5 4.5l.6 8.5h5.8l.6-8.5"/></g>,
};
const QUICK_ACTIONS = [
  { id: "edit", label: "Edit (jj edit)" },
  { id: "describe", label: "Describe…" },
  { id: "squash", label: "Squash into parent" },
  { id: "abandon", label: "Abandon", danger: true },
];
const NEW_ACTIONS = [
  { id: "new", label: "New change on top (jj new)", add: true },
  { id: "after", label: "Insert after — between this and its children (jj new -A)", add: true },
  { id: "before", label: "Insert before — between this and its parent (jj new -B)", add: true },
];
const QA_WITH_NEW = [...NEW_ACTIONS, { ...QUICK_ACTIONS[0], sep: true }, ...QUICK_ACTIONS.slice(1)];
const QA_ROOT = NEW_ACTIONS.slice(0, 1);
const MENU_GROUPS = [
  [{ id: "new", label: "New change on top", cmd: "jj new" }, { id: "after", label: "Insert after", cmd: "jj new -A", mut: true }, { id: "before", label: "Insert before", cmd: "jj new -B", mut: true }],
  [{ id: "edit", label: "Edit", cmd: "jj edit", mut: true }, { id: "describe", label: "Describe…", cmd: "jj describe", mut: true }, { id: "squash", label: "Squash into parent", cmd: "jj squash", mut: true }],
  [{ id: "abandon", label: "Abandon", cmd: "jj abandon", danger: true, mut: true }],
];
// Right-click menu, positioned in .gws coordinates and clamped to it.
function CardMenu({ menu, c, isWC, onAction, onClose }) {
  const ref = useRef(null);
  const [pos, setPos] = useState({ left: menu.x, top: menu.y, vis: false });
  useLayoutEffect(() => {
    const el = ref.current, ws = el && el.offsetParent; if (!ws) return;
    const w = el.offsetWidth, h = el.offsetHeight, W = ws.clientWidth, Hh = ws.clientHeight;
    const x = menu.alignRight ? menu.x - w : menu.x, up = menu.yUp != null ? menu.yUp : menu.y;
    setPos({ left: Math.max(6, Math.min(x, W - w - 6)), top: menu.y + h > Hh - 6 ? Math.max(6, up - h) : menu.y, vis: true });
  }, [menu]);
  useEffect(() => {
    const down = e => { if (ref.current && !ref.current.contains(e.target) && !e.target.closest("[data-menu-anchor]")) onClose(); };
    const key = e => { if (e.key === "Escape") { e.stopImmediatePropagation(); onClose(); } };
    window.addEventListener("pointerdown", down, true); window.addEventListener("keydown", key, true);
    window.addEventListener("wheel", onClose, { passive: true }); window.addEventListener("resize", onClose); window.addEventListener("blur", onClose);
    return () => {
      window.removeEventListener("pointerdown", down, true); window.removeEventListener("keydown", key, true);
      window.removeEventListener("wheel", onClose); window.removeEventListener("resize", onClose); window.removeEventListener("blur", onClose);
    };
  }, []);
  const groups = c.isRoot ? [MENU_GROUPS[0].slice(0, 1)] : MENU_GROUPS;
  return (
    <div ref={ref} className="gmenu" role="menu" style={{ left: pos.left, top: pos.top, visibility: pos.vis ? "visible" : "hidden" }} onContextMenu={e => e.preventDefault()}>
      <div className="gmenu-head"><span className="gcid"><b>{c.id.slice(0, 2)}</b>{c.id.slice(2, 8)}</span><span className="gmenu-subj">{c.subject}</span></div>
      {groups.map((g, gi) => <React.Fragment key={gi}>
        {gi > 0 && <div className="gmenu-sep"></div>}
        {g.map(a => {
          const off = (a.mut && c.immutable && a.id !== "after") || (a.id === "edit" && isWC);
          return (
            <button key={a.id} role="menuitem" className={"gmenu-item " + (a.danger ? "danger" : "")} disabled={off} onClick={() => onAction(a.id)}>
              <svg width="14" height="14" viewBox="0 0 16 16">{QA_ICON[a.id]}</svg>
              <span>{a.label}</span><span className="gmenu-cmd">{a.cmd}</span>
            </button>
          );
        })}
      </React.Fragment>)}
    </div>
  );
}
const ADD_GLYPH = <svg width="10" height="10" viewBox="0 0 16 16"><path d="M8 2.5v11M2.5 8h11" stroke="currentColor" strokeWidth="2" strokeLinecap="round"/></svg>;
function QuickActions({ actions = QUICK_ACTIONS, onAction }) {
  const stop = (e) => e.stopPropagation();
  let sep = 0;
  const items = actions.map((a, i) => { if (a.sep && i) sep += 8; return { a, i: i + 1, sep }; });
  return (
    <div className="gqa" style={{ "--qa-w": actions.length * 28 + sep + 24 + "px" }} onClick={stop} onDoubleClick={stop} onPointerDown={stop}>
      <div className="gqa-items">
        {items.map(({ a, i, sep }) => (
          <button key={a.id} className={"gqa-btn " + (a.danger ? "danger " : "") + (a.add ? "add" : "")} title={a.label} aria-label={a.label} onClick={() => onAction && onAction(a.id)}
            style={{ "--i": i, "--n": actions.length, "--sep": sep + "px" }}>
            <svg width="13" height="13" viewBox="0 0 16 16">{QA_ICON[a.id]}</svg>
          </button>
        ))}
      </div>
      <button className="gqa-more" aria-label="Quick actions">
        <svg width="12" height="12" viewBox="0 0 16 16"><g fill="currentColor"><circle cx="3.5" cy="8" r="1.4"/><circle cx="8" cy="8" r="1.4"/><circle cx="12.5" cy="8" r="1.4"/></g></svg>
      </button>
    </div>
  );
}

// ============================================================
// CARD
// ============================================================
function fitPeek(el, needBelow) {
  const sc = el.closest(".gscroll"); if (!sc) return;
  const s = sc.getBoundingClientRect(), r = el.getBoundingClientRect();
  el.classList.toggle("flip-up", s.bottom - r.bottom < needBelow && r.top - s.top > s.bottom - r.bottom);
}
function fitSide(el) {
  const sc = el.closest(".gscroll"); if (!sc) return;
  const s = sc.getBoundingClientRect(), r = el.getBoundingClientRect();
  el.classList.toggle("anchor-bot", s.bottom - r.top < 260 && r.bottom - s.top > s.bottom - r.top);
}
function fitRight(el) {
  const sc = el.closest(".gscroll"); if (!sc) return;
  const s = sc.getBoundingClientRect(), r = el.getBoundingClientRect();
  el.classList.toggle("flip-left", s.right - r.right < 370 && r.left - s.left > s.right - r.right);
}

function fileCounts(c) {
  if (c.fileCounts) return c.fileCounts;
  const f = c.stats.files || 0, tot = c.stats.added + c.stats.removed || 1;
  const a = Math.min(f, Math.round(f * 0.35 * c.stats.added / tot)), d = f - a > 2 && c.stats.removed > c.stats.added * 0.6 ? 1 : 0;
  return { a, m: f - a - d, d };
}

function CommitPeek({ c, hint }) {
  const fc = fileCounts(c);
  return (
    <div className="gpeek-inner">
      <div className="gpeek-subj">{c.subject}</div>
      {c.description && <div className="gpeek-desc">{c.description}</div>}
      <div className="gpeek-meta">
        <span className="gcid"><b>{c.id.slice(0, 2)}</b>{c.id.slice(2, 8)}</span>
        {c.commitId && <span className="gpeek-dim">{c.commitId}</span>}
        {c.author && <span>{c.author}</span>}
        {c.date && <span className="gpeek-dim">{c.date}</span>}
      </div>
      {!c.isRoot && (c.stats.files > 0 ? (
        <div className="gpeek-stats">
          <span className="fa" title="files added">A {fc.a}</span>
          <span className="fm" title="files modified">M {fc.m}</span>
          <span className="fd" title="files deleted">D {fc.d}</span>
          <span className="gpeek-lines"><span className="la">+{c.stats.added}</span><span className="lr">−{c.stats.removed}</span></span>
        </div>
      ) : <div className="gpeek-stats gpeek-dim">No file changes</div>)}
      {hint && <div className="gstack-hint">{hint}</div>}
    </div>
  );
}

function GraphCard({ reveal, flash, n, W, H, detailed, legend, addMode, isCtx, onMenu, isSel, isWC, isHover, dim, onClick, onDoubleClick, onHover, onAction, dnd, onBeginDrag }) {
  const c = n.c;
  const hasLegend = legend && c.bookmarks.length > 0;
  const cid = (
    <span className="gcid">
      {c.immutable && !c.isRoot && <span className="gimm" title="immutable">◆</span>}
      <b>{c.id.slice(0, 2)}</b>{c.id.slice(2, detailed && !isWC ? 8 : 5)}
    </span>
  );
  const flags = <>
    {c.hasConflict && <span className="gflag conflict" title="conflict"><Ic name="conflict" size={12}/></span>}
    {c.isMerge && <span className="gflag" title="merge"><Ic name="merge" size={12}/></span>}
  </>;
  const subj = <span className={"gsubj " + (c.isEmpty || c.isRoot ? "is-dim" : "")}>{c.subject}</span>;
  return (
    <div
      className={"gcard " + (detailed ? "is-detailed " : "is-compact ") + (isSel ? "sel " : "") + (isWC ? "wc " : "") +
        (isHover ? "hov " : "") + (c.immutable ? "immutable " : "") + (c.isRoot ? "root " : "") + (hasLegend ? "has-legend " : "") + (addMode !== "edges" ? "add-menu " : "") + (isCtx ? "ctx " : "") + (dim ? "dim " : "") + (reveal ? "reveal " : "") + (flash ? "flash " : "") + (dnd === "src" ? "drag-src " : dnd === "drop" ? "drop " : dnd === "from" ? "drag-from " : dnd === "bm" ? "bm-lift " : "")}
      style={{ left: n.x, top: n.y, width: W, height: H }}
      tabIndex={0} role="button" aria-label={(isWC ? "Working copy, " : "") + c.subject}
      onKeyDown={e => { if (e.target === e.currentTarget && (e.key === "Enter" || e.key === " ")) { e.preventDefault(); onClick(); } }}
      onClick={onClick} onDoubleClick={onDoubleClick}
      onContextMenu={addMode === "context" || addMode === "both" ? e => { e.preventDefault(); e.stopPropagation(); onMenu(c.id, e); } : undefined}
      onMouseEnter={e => { fitRight(e.currentTarget); fitSide(e.currentTarget); onHover(c.id); }} onMouseLeave={() => onHover(null)}
      data-change={c.id}
    >
      <div className="gpeek gpeek-side" onClick={e => e.stopPropagation()} onDoubleClick={e => e.stopPropagation()}>
        <CommitPeek c={c} hint={c.isRoot ? null : (isWC ? "Working copy (@) · Click for details" : "Click: details · Double-click: jj edit") + " · Drag: onto another change" + (addMode === "context" || addMode === "both" ? " · Right-click: actions" : "")}/>
      </div>
      {detailed ? <>
        <div className="gline">{subj}</div>
        <div className="gline gmeta">
          {isWC && <span className="gat">@</span>}
          {cid}
          {c.author && <span className="gmeta-t au">{c.author.split(" ")[0]}</span>}
          {c.date && <span className="gmeta-t">{c.date}</span>}
          {c.isEmpty && <span className="gmeta-t em">empty</span>}
          {flags}
        </div>
      </> : (
        <div className="gline">
          {isWC && <span className="gat">@</span>}
          {cid}{subj}{flags}
        </div>
      )}
      {!c.isRoot && <BookmarkControl bookmarks={c.bookmarks} legend={legend} cid={c.id} onBeginDrag={onBeginDrag}/>}
      {addMode === "context" ? null : addMode === "both" ? (
        <div className="gqa gqa-solo" onClick={e => e.stopPropagation()} onDoubleClick={e => e.stopPropagation()} onPointerDown={e => e.stopPropagation()}>
          <button className="gqa-more" data-menu-anchor="" aria-label="Actions" aria-haspopup="menu" aria-expanded={!!isCtx} title="Actions (or right-click the card)"
            onClick={e => isCtx ? onMenu(null) : onMenu(c.id, e, e.currentTarget)}>
            <svg width="12" height="12" viewBox="0 0 16 16"><g fill="currentColor"><circle cx="3.5" cy="8" r="1.4"/><circle cx="8" cy="8" r="1.4"/><circle cx="12.5" cy="8" r="1.4"/></g></svg>
          </button>
        </div>
      ) : addMode === "menu" ? <QuickActions actions={c.isRoot ? QA_ROOT : QA_WITH_NEW} onAction={a => onAction(c.id, a)}/> : <>
      {!c.isRoot && <QuickActions onAction={a => onAction(c.id, a)}/>}
      <button className="gadd gadd-top" title="New change on top (jj new)" aria-label="New change on top" onClick={e => { e.stopPropagation(); onAction(c.id, "new"); }} onDoubleClick={e => e.stopPropagation()}>{ADD_GLYPH}</button>
      {!c.isRoot && <button className="gadd gadd-bot" title="Insert new change before (jj new --insert-before)" aria-label="Insert new change before" onClick={e => { e.stopPropagation(); onAction(c.id, "before"); }} onDoubleClick={e => e.stopPropagation()}>{ADD_GLYPH}</button>}
      </>}
    </div>
  );
}

function StackCard({ n, W, H, detailed, dim, onClick, onHover }) {
  const c = n.c, m = c.members, a = m[0].id, b = m[m.length - 1].id;
  const range = <span className="gcid"><b>{b.slice(0, 2)}</b>{b.slice(2, 5)}<span className="grange-sep">‥</span><b>{a.slice(0, 2)}</b>{a.slice(2, 5)}</span>;
  const count = <span className="gstack-n" title={m.length + " changes"}>{m.length}</span>;
  return (
    <div className={"gcard gstack " + (detailed ? "is-detailed " : "is-compact ") + (c.immutable ? "immutable " : "") + (dim ? "dim " : "")}
      style={{ left: n.x, top: n.y, width: W, height: H }} onClick={onClick}
      onMouseEnter={e => { fitPeek(e.currentTarget, 60 + m.length * 34); onHover(c.id); }} onMouseLeave={() => onHover(null)} data-change={c.id}>
      {detailed ? <>
        <div className="gline">{count}<span className="gsubj">{c.subject}</span></div>
        <div className="gline gmeta">
          {range}
          <span className="gmeta-t au">{c.author}</span>
          <span className="gmeta-t">{c.date}</span>
          {c.hasConflict && <span className="gflag conflict" title="contains conflict"><Ic name="conflict" size={12}/></span>}
        </div>
      </> : (
        <div className="gline">{count}{range}<span className="gsubj">{c.subject}</span>
          {c.hasConflict && <span className="gflag conflict"><Ic name="conflict" size={12}/></span>}</div>
      )}
      <div className="gstack-pop" onClick={e => e.stopPropagation()}>
        <div className="gstack-pop-inner">
          {m.slice().reverse().map(x => (
            <div key={x.id} className="gstack-row" onMouseEnter={e => fitRight(e.currentTarget)}>
              <span className="gcid"><b>{x.id.slice(0, 2)}</b>{x.id.slice(2, 6)}</span>
              <span className="gstack-subj">{x.subject}</span>
              <span className="gstack-date">{x.date}</span>
              <div className="gpeek gpeek-right"><CommitPeek c={x}/></div>
            </div>
          ))}
          <div className="gstack-hint">Click to expand {m.length} changes</div>
        </div>
      </div>
    </div>
  );
}

// ============================================================
// DETAIL PANEL (right)
// ============================================================
function GraphDetail({ commit, isWC, editMeta, setEditMeta, onClose, onEdit, t, setTweak }) {
  return (
    <section className="gdetail" style={{ "--branch-color": "var(--accent)" }} data-screen-label={`Detail ${commit.id}`}>
      <div className="bcd-header">
        <div className="commit-tags">
          {isWC && <span className="tag checkout-tag">@ working copy</span>}
          {commit.immutable && <span className="tag merge">◆ immutable</span>}
          {commit.isEmpty && <span className="tag empty">empty</span>}
          {commit.isMerge && <span className="tag merge">merge</span>}
          {commit.hasConflict && <span className="tag conflict"><Ic name="conflict" size={10}/>conflict</span>}
          <span className="gdetail-id"><b>{commit.id.slice(0, 2)}</b>{commit.id.slice(2)}</span>
        </div>
        {!isWC && !commit.immutable && <button className="bcd-edit-btn" onClick={onEdit} title="Move the working copy here (jj edit)"><span className="gat sm">@</span><span>Edit</span></button>}
        {!editMeta && !commit.immutable && <button className="bcd-edit-btn" onClick={() => setEditMeta(true)} title="Edit description (jj describe)"><Ic name="edit" size={11}/><span>Describe</span></button>}
        <button className="bcd-close" onClick={onClose} title="Close (Esc)"><Ic name="close" size={12}/></button>
      </div>
      <h2 className="bcd-subject">{commit.subject}</h2>
      {commit.bookmarks.length > 0 && (
        <div className="gdetail-bms">
          {commit.bookmarks.map(b => (
            <span key={b.name} className="gdetail-bm" title={STATE_LABEL[b.state]}>
              <BookmarkGlyph filled size={11}/>{b.name}
              <span className={"gbm-state s-" + b.state}>{b.state === "ahead" ? `↑${b.ahead}` : b.state === "synced" ? "✓" : b.state === "remote" ? "remote" : "local"}</span>
            </span>
          ))}
        </div>
      )}
      <div className="bcd-body">
        {editMeta
          ? <window.EditPanel commit={commit} onDone={() => setEditMeta(false)} onDiscard={() => setEditMeta(false)}/>
          : <window.CommitDetail commit={commit} diffMode={t.diffMode} onSetDiffMode={(v) => setTweak("diffMode", v)} showFiles={t.showFiles}/>}
      </div>
    </section>
  );
}

function BookmarkList({ commits, onPick, visibleSet, limit, onBeginDrag }) {
  const rows = commits.flatMap(c => c.bookmarks.map(b => ({ b, c }))).slice(0, limit || undefined);
  return (
    <div className="gbl">
      {rows.map(({ b, c }) => (
        <button key={b.name} className={"gbl-row " + (visibleSet.has(c.id) ? "" : "is-hidden")} onClick={() => onPick(c.id)} title={b.name}
          onPointerDown={onBeginDrag && b.state !== "remote" && !b.name.includes("@") ? (e) => onBeginDrag(e, { kind: "bookmark", name: b.name, from: c.id }) : undefined}>
          <BookmarkGlyph filled size={12}/>
          <span className="gbl-text">
            <span className="gbl-name">{b.name}</span>
            <span className="gbl-sub"><b>{c.id.slice(0, 2)}</b>{c.id.slice(2, 8)} · {c.subject}</span>
          </span>
          <span className={"gbm-state s-" + b.state}>{b.state === "ahead" ? `↑${b.ahead}` : b.state === "synced" ? "✓" : b.state}</span>
        </button>
      ))}
    </div>
  );
}

// ============================================================
// WORKSPACE
// ============================================================
// ============================================================
// MINIMAP (floating mode) — vertical density strip + time labels, replaces the time gutter
// ============================================================
const MINI_W = 118, MINI_CARD = 134, MINI_GL = 66, MINI_KX = 0.04, MINI_SPLIT = 58;
function minimapLabels(L, H) {
  if (L.buckets.length) return L.buckets.filter(b => b.label).map(b => ({ y: b.y, label: b.label })).sort((a, b) => a.y - b.y);
  const rows = new Map();
  L.nodes.forEach(n => (n.c.members || [n.c]).forEach(c => {
    const t = Date.parse(c.ts) || 0, r = rows.get(n.y);
    if (!r || t > r.t) rows.set(n.y, { t, c });
  }));
  // compact rows mix generations, so a label only appears when its day is older than the one above it
  const out = []; let lastKey = Infinity;
  [...rows.entries()].sort((a, b) => a[0] - b[0]).forEach(([y, { c }]) => {
    const b = timeBucket(c);
    if (b.label && b.key < lastKey) { out.push({ y: y + H / 2, label: b.label }); lastKey = b.key; }
  });
  return out;
}
// top/bottom = view insets (px of the scrollport covered by chrome); pos = card placement
// Layout (mirrored): time labels left of MINI_SPLIT, the graph itself drawn in dots on the right.
function GraphMinimap({ L, H, scrollRef, planeRef, pos, hidden, top, bottom, wcId, selectedId, onScrub }) {
  const ref = useRef(null), drag = useRef(false);
  const [vp, setVp] = useState({ st: 0, sh: 1, ch: 1, mh: 0, oy: 0 });
  const [hov, setHov] = useState(null);
  useEffect(() => {
    const el = scrollRef.current, m = ref.current, p = planeRef.current;
    if (!el || !m) return;
    const read = () => setVp({ st: el.scrollTop, sh: el.scrollHeight, ch: el.clientHeight, mh: m.clientHeight, oy: p ? p.offsetTop + p.clientTop : 0 });
    read();
    el.addEventListener("scroll", read, { passive: true });
    const ro = new ResizeObserver(read);
    ro.observe(el); ro.observe(m); if (p) ro.observe(p, { box: "border-box" });
    return () => { el.removeEventListener("scroll", read); ro.disconnect(); };
  }, []);
  const k = vp.mh / Math.max(1, vp.sh);
  const labels = useMemo(() => minimapLabels(L, H), [L, H]);
  const geo = useMemo(() => {
    if (!L.nodes.length || !vp.mh) return { nodes: [], edges: [] };
    const xs = L.nodes.map(n => n.cx), x0 = Math.min(...xs), x1 = Math.max(...xs), gr = MINI_W - 4;
    const kx = x1 > x0 ? Math.min((gr - MINI_GL) / (x1 - x0), MINI_KX) : 0;
    const mx = (x) => gr - (x1 - x) * kx, my = (y) => (y + vp.oy) * k;
    const nodes = L.nodes.map(n => ({ id: n.id, x: mx(n.cx), y: my(n.y + H / 2), grp: !!n.c.isGroup }));
    const edges = L.edges.map((e, i) => {
      const p = L.N.get(e.from), c = L.N.get(e.to);
      if (!e.pts || !p || !c) return null;
      const pts = [[p.cx, p.y + H / 2], ...e.pts, [c.cx, c.y + H / 2]];
      return { k: e.from + ">" + e.to + i, dashed: e.dashed, d: pts.map(([x, y]) => mx(x).toFixed(1) + "," + my(y).toFixed(1)).join(" ") };
    }).filter(Boolean);
    return { nodes, edges };
  }, [L, H, k, vp.mh, vp.oy]);

  const view = (sy) => sy / Math.max(k, 1e-6);
  const vTop = (vp.st + top) * k, vBot = (vp.st + vp.ch - bottom) * k, cy = (vTop + vBot) / 2;
  const labelAt = (sy) => { const y = view(sy) - vp.oy; let pick = labels[0]; labels.forEach(l => { if (l.y <= y + 1) pick = l; }); return pick ? pick.label : ""; };
  let lastY = -99;
  const shown = labels.map(l => ({ ...l, sy: (l.y + vp.oy) * k })).filter(l => {
    if (l.sy - lastY < 18 || Math.abs(l.sy - cy) < 15 || (hov != null && Math.abs(l.sy - hov) < 13)) return false;
    lastY = l.sy; return true;
  });
  const jump = (e) => {
    const el = scrollRef.current, r = ref.current.getBoundingClientRect();
    el.scrollTop = view(e.clientY - r.top) - (top + (vp.ch - top - bottom) / 2);
  };
  const pillLabel = labelAt(cy), hovLabel = hov != null ? labelAt(hov) : null;
  const layer = (cls, clip) => (
    <g className={"gmini-g " + cls} clipPath={clip}>
      {geo.edges.map(e => <polyline key={e.k} points={e.d} className={"gmini-e " + (e.dashed ? "dashed" : "")}></polyline>)}
      {geo.nodes.map(n => <circle key={n.id} cx={n.x} cy={n.y} r={n.grp ? 2.6 : 2} className={"gmini-n " + (n.grp ? "grp" : "")}></circle>)}
    </g>
  );
  const mark = (id, cls) => { const n = id && geo.nodes.find(x => x.id === id); return n ? <circle cx={n.x} cy={n.y} r="3.2" className={"gmini-n " + cls}></circle> : null; };
  return (
    <div className={"gmini" + (hidden ? " is-hidden" : "")} style={pos} aria-label="Minimap" aria-hidden={hidden}>
    <div className="gmini-strip" ref={ref}
      onPointerDown={(e) => { drag.current = true; e.currentTarget.setPointerCapture(e.pointerId); setHov(null); jump(e); }}
      onPointerMove={(e) => { if (drag.current) { onScrub && onScrub(40); return jump(e); } const r = ref.current.getBoundingClientRect(); setHov(e.clientY - r.top); }}
      onPointerUp={() => { drag.current = false; }} onPointerCancel={() => { drag.current = false; }}
      onPointerLeave={() => setHov(null)}
      onWheel={(e) => { if (scrollRef.current) scrollRef.current.scrollBy(e.deltaX, e.deltaY); onScrub && onScrub(Math.abs(e.deltaX) + Math.abs(e.deltaY)); }}>
      <svg className="gmini-svg" width={MINI_W} height={vp.mh}>
        <defs><clipPath id="gmini-clip"><rect x="-8" y={vTop} width={MINI_W + 16} height={Math.max(0, vBot - vTop)}></rect></clipPath></defs>
        <rect className="gmini-view" x={MINI_SPLIT + 2} y={vTop} width={MINI_W - MINI_SPLIT + 2} height={Math.max(4, vBot - vTop)} rx="4"></rect>
        {layer("", undefined)}
        {layer("in", "url(#gmini-clip)")}
        {mark(selectedId, "sel")}
        {mark(wcId, "wc")}
        {hov != null && <line className="gmini-hline" x1={MINI_SPLIT} x2={MINI_W} y1={hov} y2={hov}></line>}
        <line className="gmini-conn" x1={MINI_SPLIT} x2={MINI_W} y1={cy} y2={cy}></line>
      </svg>
      {shown.map(l => <span key={l.label + l.y} className="gmini-lbl" style={{ top: l.sy, right: MINI_W - MINI_SPLIT + 4 }}>{l.label}</span>)}
      {hovLabel && <span className="gmini-pill is-hov" style={{ top: hov, right: MINI_W - MINI_SPLIT }}>{hovLabel}</span>}
      {pillLabel && <span className="gmini-pill" style={{ top: cy, right: MINI_W - MINI_SPLIT }}>{pillLabel}</span>}
    </div>
    </div>
  );
}

// floating: graph fills the window, chrome(api) renders the overlay UI; floatInsets = px covered by that UI (for centering)
function GraphWorkspace({ t, setTweak, leftPanel, onCloseLeft, floating = false, chrome, floatInsets }) {
  const boot = useRef(null);
  if (!boot.current) {
    const D = window.buildDiffs ? window.buildDiffs(window.GRAPH_COMMITS) : {}, O = window.GraphOps;
    const A = O ? window.GRAPH_COMMITS.map(c => c.isRoot || !D[c.id] || (!D[c.id].length && c.isMerge) ? c : { ...c, stats: O.count(D[c.id]), isEmpty: !D[c.id].length }) : window.GRAPH_COMMITS;
    window.GRAPH_COMMITS = A;
    boot.current = { A, D };
  }
  const [all, setAll] = useState(boot.current.A);
  const [diffs, setDiffs] = useState(boot.current.D);
  const [revset, setRevset] = usePersist("zanshin.graph.revset", "default");
  const rsv = window.useRevsetVersion();
  const [detailed, setDetailed] = usePersist("zanshin.graph.detailed", true);
  const [cardW, setCardW] = usePersist("zanshin.graph.cardW", 240);
  const [layout, setLayout] = usePersist("zanshin.graph.layout", "compact");
  const [stacks, setStacks] = usePersist("zanshin.graph.stacks", true);
  const [expanded, setExpanded] = usePersist("zanshin.graph.expanded", []);
  const [revealId, setRevealId] = useState(null);
  const [selectedId, setSelectedId] = useState(null);
  const [wcId, setWcId] = useState(() => { const q = GQ.get("wc"); return q && all.some(c => c.id === q) ? q : (all.find(c => c.isWorkingCopy) || {}).id; });
  const [hoverId, setHoverId] = useState(null);
  const [editMeta, setEditMeta] = useState(false);
  const [gapHover, setGapHover] = useState(null);
  const [counted, setCounted] = useState(() => new Set());
  const [flash, setFlash] = useState(() => new Set());
  const [menu, setMenu] = useState(null);
  const [toast, setToast] = useState(null);
  const wsRef = useRef(null);
  const openMenu = (id, e, anchor) => {
    if (!id) return setMenu(null);
    const r = wsRef.current.getBoundingClientRect();
    if (anchor) { const a = anchor.getBoundingClientRect(); return setMenu({ id, x: a.right - r.left, y: a.bottom - r.top + 4, yUp: a.top - r.top - 4, alignRight: true }); }
    setMenu({ id, x: e.clientX - r.left, y: e.clientY - r.top });
  };
  const closeMenu = () => setMenu(null);
  const gapT = useRef(null);
  const scrollRef = useRef(null);
  const planeRef = useRef(null);
  const pendingScroll = useRef(GQ.get("focus") || wcId);
  const mounted = useRef(false);
  const clickT = useRef(null);
  const H = detailed ? G.hDetailed : G.hCompact;
  const optimize = t.laneOrder !== "greedy";
  const S = useMemo(() => stacks ? groupStacks(all, revset, expanded) : { list: all, runs: [] }, [all, revset, rsv, stacks, expanded]);
  const cols = useMemo(() => {
    if (!stacks) return null;
    const L0 = computeLayout(all, revset, cardW, H, layout, { optimize, gutter: !floating });
    return new Map(L0.nodes.map(n => [n.id, n.col]));
  }, [all, revset, rsv, stacks, cardW, H, layout, optimize]);
  const L = useMemo(() => computeLayout(S.list, revset, cardW, H, layout, { optimize, cols, gutter: !floating }), [S, revset, rsv, cardW, H, layout, optimize, cols]);
  const shownCount = L.nodes.reduce((s, n) => s + (n.c.members ? n.c.members.length : 1), 0);
  const toggleStack = (gid) => {
    const run = S.runs.find(r => r.id === gid); if (!run) return;
    const m = run.members;
    if (run.expanded) { setExpanded(expanded.filter(x => x !== gid)); pendingScroll.current = gid; setRevealId(null); }
    else { setExpanded([...expanded, gid]); pendingScroll.current = m[Math.floor(m.length / 2)].id; setRevealId(gid); }
    setHoverId(null);
  };
  const brackets = S.runs.filter(r => r.expanded && r.members.every(m => L.N.get(m.id))).map(r => {
    const ns = r.members.map(m => L.N.get(m.id));
    const top = Math.min(...ns.map(n => n.y)), bot = Math.max(...ns.map(n => n.y)) + H;
    return { id: r.id, x: Math.min(...ns.map(n => n.x)) - 16, top: top + 6, h: bot - top - 12, n: r.members.length, members: new Set(r.members.map(m => m.id)) };
  });
  const revealSet = useMemo(() => { const r = S.runs.find(x => x.id === revealId); return new Set(r ? r.members.map(m => m.id) : []); }, [S, revealId]);
  const visibleSet = useMemo(() => new Set(L.nodes.map(n => n.id)), [L]);

  const ancestors = useMemo(() => {
    const s = new Set(); const st = [wcId];
    while (st.length) { const x = st.pop(); const n = L.N.get(x); if (!n || s.has(x)) continue; s.add(x); n.parents.forEach(p => st.push(p.id)); }
    return s;
  }, [L, wcId]);

  const viewInsets = (sel) => {
    if (!floating) return { l: 0, r: 0, t: 0, b: 0 };
    const fi = floatInsets || {};
    return { l: fi.left || 0, r: (fi.right || 0) + (sel ? (fi.detail || 0) : (floating ? MINI_CARD + 12 : 0)), t: fi.top || 0, b: fi.bottom || 0 };
  };
  const scrollToNode = (id, smooth = true, sel = selectedId) => {
    const n = L.N.get(id), el = scrollRef.current, p = planeRef.current;
    if (!n || !el) return;
    const ox = p ? p.offsetLeft + p.clientLeft : 0, oy = p ? p.offsetTop + p.clientTop : 0, v = viewInsets(sel);
    el.scrollTo({ left: n.cx + ox - (v.l + el.clientWidth - v.r) / 2, top: n.y + H / 2 + oy - (v.t + el.clientHeight - v.b) / 2, behavior: smooth ? "smooth" : "auto" });
  };
  // floating: is @ out of view? drives the contextual "Working copy" pill
  const [wcDir, setWcDir] = useState(null);
  const wcMeasure = useRef(null), wcRaf = useRef(0);
  wcMeasure.current = () => {
    const n = L.N.get(wcId), el = scrollRef.current, p = planeRef.current;
    if (!floating || !n || !el || !p) { setWcDir(null); return; }
    const v = viewInsets(selectedId), m = 8;
    const x = n.x + p.offsetLeft + p.clientLeft - el.scrollLeft, y = n.y + p.offsetTop + p.clientTop - el.scrollTop;
    setWcDir(y + H < v.t + m ? "up" : y > el.clientHeight - v.b - m ? "down" : x + cardW < v.l + m ? "left" : x > el.clientWidth - v.r - m ? "right" : null);
  };
  useEffect(() => {
    const el = scrollRef.current;
    if (!floating || !el) return;
    const h = () => { cancelAnimationFrame(wcRaf.current); wcRaf.current = requestAnimationFrame(() => wcMeasure.current()); };
    el.addEventListener("scroll", h, { passive: true });
    const ro = new ResizeObserver(h); ro.observe(el);
    h();
    return () => { el.removeEventListener("scroll", h); ro.disconnect(); cancelAnimationFrame(wcRaf.current); };
  }, []);
  useEffect(() => { wcMeasure.current(); }, [L, wcId, selectedId, cardW, H, floatInsets && floatInsets.left]);
  useLayoutEffect(() => {
    let id = pendingScroll.current;
    if (id && !L.N.get(id)) { const r = S.runs.find(x => !x.expanded && x.members.some(m => m.id === id)); if (r) id = r.id; }
    if (id && L.N.get(id)) {
      const smooth = mounted.current, el = scrollRef.current;
      scrollToNode(id, smooth);
      pendingScroll.current = null;
      if (!smooth && el) {
        // first mount: the viewport may not have its final size yet (lazy iframes, fonts) — retry until it sticks
        let tries = 0;
        const retry = () => { if (!scrollRef.current || tries++ > 30) return; scrollToNode(id, false); const e = scrollRef.current; if (e.clientWidth < 50 || (e.scrollLeft === 0 && e.scrollTop === 0 && e.scrollWidth > e.clientWidth)) setTimeout(retry, 100); };
        requestAnimationFrame(retry);
      }
    }
    mounted.current = true;
  }, [L]);
  // ============================================================
  // MOTION WITH MEANING — jj new grows out of its parent; a rebase flies the change (and what sits on it) to the new parent.
  // FLIP: snapshot card rects before the data change, keep the anchor card still, animate every card from where it was.
  // ============================================================
  const flip = useRef(null), movingT = useRef(0), bornT = useRef(0), pendingDescribe = useRef(false), scrollFn = useRef(null);
  scrollFn.current = scrollToNode;
  const [moving, setMoving] = useState(false);
  const [bornId, setBornId] = useState(null);
  const snapshot = () => {
    const m = new Map(), p = planeRef.current;
    if (p) p.querySelectorAll(".gcard[data-change]").forEach(el => { const r = el.getBoundingClientRect(); m.set(el.dataset.change, { x: r.left, y: r.top }); });
    return m;
  };
  useLayoutEffect(() => {
    const f = flip.current; flip.current = null;
    const el = scrollRef.current, plane = planeRef.current;
    if (!f || !el || !plane) return;
    const cards = new Map([...plane.querySelectorAll(".gcard[data-change]")].map(n => [n.dataset.change, n]));
    const an = cards.get(f.anchor), ap = f.rects.get(f.anchor);
    if (an && ap) { const r = an.getBoundingClientRect(); el.scrollLeft += r.left - ap.x; el.scrollTop += r.top - ap.y; }
    const still = window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    if (!still) {
      const ease = "cubic-bezier(.32,.72,0,1)";
      cards.forEach((node, id) => {
        const r = node.getBoundingClientRect(), p = f.rects.get(id);
        if (p) {
          const dx = p.x - r.left, dy = p.y - r.top;
          if (Math.abs(dx) > .5 || Math.abs(dy) > .5) node.animate([{ transform: `translate(${dx}px,${dy}px)` }, { transform: "translate(0,0)" }], { duration: 460, easing: ease });
        } else if (id === f.born && ap) {
          node.animate([{ transform: `translate(${ap.x - r.left}px,${ap.y - r.top}px) scale(.94)`, opacity: 0 }, { opacity: 1, offset: .3 }, { transform: "translate(0,0) scale(1)", opacity: 1 }], { duration: 540, easing: ease });
        } else node.animate([{ opacity: 0 }, { opacity: 1 }], { duration: 240, delay: 220, fill: "backwards" });
      });
      setMoving(true); clearTimeout(movingT.current); movingT.current = setTimeout(() => setMoving(false), 470);
    }
    if (f.born) setTimeout(() => {
      const n = planeRef.current && planeRef.current.querySelector(`.gcard[data-change="${f.born}"]`), s = scrollRef.current;
      if (!n || !s) return;
      const r = n.getBoundingClientRect(), b = s.getBoundingClientRect(), v = viewInsets(selectedId);
      if (r.top < b.top + v.t + 8 || r.bottom > b.bottom - v.b - 8 || r.left < b.left + v.l + 8 || r.right > b.right - v.r - 8) scrollFn.current(f.born, true);
    }, still ? 0 : 480);
  }, [L]);

  const commitAll = (next) => { window.GRAPH_COMMITS = next; setAll(next); };
  const mkId = () => { const abc = "kmnopqrstuvwxyz", taken = new Set(all.map(c => c.id)); let s; do { s = ""; for (let i = 0; i < 8; i++) s += abc[Math.floor(Math.random() * abc.length)]; } while (taken.has(s)); return s; };
  // jj new <pid> · -A (after: takes over pid's children) · -B (before: slots in between pid and its parents)
  const newChange = (pid = wcId, mode = "new") => {
    const p = all.find(c => c.id === pid);
    if (!p || (mode === "before" && p.immutable)) return;
    if (mode === "after" && all.some(c => c.parents.includes(pid) && c.immutable)) mode = "new";
    const id = mkId();
    const n = { id, commitId: Math.floor(Math.random() * 0xffffffff).toString(16).padStart(8, "0"), parents: mode === "before" ? [...p.parents] : [pid],
      subject: "(no description set)", description: "", author: "Ralph Stein", date: "now", ts: window.GRAPH_NOW, priority: p.priority || 0,
      bookmarks: [], files: [], immutable: false, inDefault: true, isEmpty: true, isWorkingCopy: true, hasConflict: false, stats: { added: 0, removed: 0, files: 0 } };
    let next = all.map(c => c.isWorkingCopy ? { ...c, isWorkingCopy: false } : c);
    if (mode === "after") next = next.map(c => c.parents.includes(pid) ? { ...c, parents: c.parents.map(x => x === pid ? id : x) } : c);
    if (mode === "before") next = next.map(c => c.id === pid ? { ...c, parents: [id] } : c);
    flip.current = { anchor: pid, rects: snapshot(), born: id };
    pendingScroll.current = null;
    commitAll([...next, n]);
    setWcId(id);
    if (selectedId === pid) setSelectedId(id);
    setBornId(id); clearTimeout(bornT.current); bornT.current = setTimeout(() => setBornId(null), 1400);
  };
  // ============================================================
  // EDITS — every change to the graph goes through apply(): FLIP snapshot, @ bookkeeping, and a toast that can take it back (jj undo)
  // ============================================================
  const ops = window.GraphOps;
  const stateRef = useRef(null);
  stateRef.current = { all, diffs, wcId, selectedId };
  const toastT = useRef(0);
  const apply = (fn, opts = {}) => {
    const s = stateRef.current, prev = { all: s.all, diffs: s.diffs, wcId: s.wcId, selectedId: s.selectedId };
    const r = fn(s.all, s.diffs, mkId);
    if (!r || !r.all) return;
    const wc = r.wc !== undefined ? r.wc : (r.all.some(c => c.id === s.wcId) ? s.wcId : null);
    const next = r.all.map(c => !!c.isWorkingCopy !== (c.id === wc) ? { ...c, isWorkingCopy: c.id === wc } : c);
    const rects = snapshot();
    if (opts.from) rects.set(opts.from.id, opts.from);
    flip.current = { anchor: r.anchor, rects, born: r.born };
    pendingScroll.current = null;
    commitAll(next);
    if (r.diffs) setDiffs(r.diffs);
    if (wc !== s.wcId) setWcId(wc);
    const sel = r.select !== undefined ? r.select : s.selectedId;
    setSelectedId(sel && next.some(c => c.id === sel) ? sel : null);
    if (r.flash) { setFlash(new Set(r.flash)); setTimeout(() => setFlash(new Set()), 1800); }
    if (r.born) { setBornId(r.born); clearTimeout(bornT.current); bornT.current = setTimeout(() => setBornId(null), 1400); }
    if (r.toast) { clearTimeout(toastT.current); setToast({ ...r.toast, prev, n: Date.now() }); toastT.current = setTimeout(() => setToast(null), 6500); }
  };
  const undo = () => {
    const p = toast && toast.prev;
    clearTimeout(toastT.current); setToast(null);
    if (!p) return;
    flip.current = { anchor: null, rects: snapshot() };
    pendingScroll.current = null;
    commitAll(p.all); setDiffs(p.diffs); setWcId(p.wcId);
    setSelectedId(p.selectedId && p.all.some(c => c.id === p.selectedId) ? p.selectedId : null);
  };
  useEffect(() => {
    if (!toast) return;
    const k = (e) => { if ((e.metaKey || e.ctrlKey) && !e.shiftKey && e.key.toLowerCase() === "z" && !/INPUT|TEXTAREA/.test((document.activeElement || {}).tagName || "")) { e.preventDefault(); undo(); } };
    window.addEventListener("keydown", k);
    return () => window.removeEventListener("keydown", k);
  }, [toast]);
  const editAt = (id) => apply((all) => ({ all, wc: id }));
  const describeChange = (id, sub, body) => apply((all) => ({ all: ops.describe(all, id, sub, body) }));
  const splitChange = (id, hunkIds, msg) => apply((all, diffs, mk) => {
    const nid = mk(), r = ops.split(all, diffs, id, hunkIds, nid, msg.trim() ? msg.trim() : null);
    return { ...r, born: nid, anchor: id, select: id, toast: { text: ["Split ", { id }, " — the rest is now ", { id: nid }] } };
  });
  const commitWC = (id, hunkIds, msg) => apply((all, diffs, mk) => {
    const nid = mk(), r = ops.commit(all, diffs, id, hunkIds, nid, msg.trim());
    return { ...r, born: nid, anchor: id, select: nid, toast: { text: ["Committed ", { id }, msg.trim() ? " · “" + msg.trim().split("\n")[0] + "”" : ""] } };
  });
  const canSquash = (c) => !!c && !c.immutable && c.parents.length === 1 && !(all.find(p => p.id === c.parents[0]) || {}).immutable;
  const squashParent = (id) => {
    const c = all.find(x => x.id === id);
    if (!canSquash(c)) return;
    const pid = c.parents[0];
    apply((all, diffs) => { const r = ops.squash(all, diffs, id, pid, null); return { ...r, anchor: pid, flash: [pid], select: r.gone ? pid : id, toast: { text: ["Squashed ", { id }, " into ", { id: pid }] } }; });
  };
  const abandonChange = (id) => apply((all, diffs, mk) => {
    const c = all.find(x => x.id === id), nid = mk(), r = ops.abandon(all, diffs, id, nid);
    return { ...r, anchor: c.parents[0], born: r.wc ? nid : undefined, select: null, toast: { text: ["Abandoned ", { id }] } };
  });
  const cardAction = (id, a) => {
    if (a === "new" || a === "after" || a === "before") return newChange(id, a);
    if (a === "edit") { const c = all.find(x => x.id === id); if (c && !c.immutable) editAt(id); return; }
    if (a === "describe") { if (selectedId === id) setEditMeta(true); else { pendingDescribe.current = true; setSelectedId(id); } return; }
    if (a === "squash") return squashParent(id);
    if (a === "abandon") return abandonChange(id);
  };

  // ============================================================
  // DIRECT MANIPULATION — one drag engine for changes, bookmarks and hunks (graph-dnd.jsx decides what can happen).
  // Rest on a card → the drop menu opens over it; a plain drop runs the action nearest the card.
  // ============================================================
  const dragRef = useRef(null), auto = useRef({ raf: 0, vx: 0, vy: 0 }), dwellT = useRef(0);
  const [drag, setDrag] = useState(null);
  const dragImpl = useRef({}), dragFns = useRef(null);
  if (!dragFns.current) dragFns.current = { move: e => dragImpl.current.move(e), up: e => dragImpl.current.up(e), cancel: e => dragImpl.current.cancel(e), key: e => dragImpl.current.key(e) };
  const defaultIdx = (acts, alt) => { const i = alt && acts ? acts.findIndex(a => a.id === "only") : -1; return i >= 0 ? i : 0; };
  const renderDrag = () => {
    const d = dragRef.current, w = wsRef.current;
    if (!d || !d.started || !w) return;
    const r = w.getBoundingClientRect();
    setDrag({ payload: d.payload, x: d.lx - r.left, y: d.ly - r.top, target: d.target, actions: d.actions, sel: d.menu ? d.menu.sel : d.sel, menu: d.menu ? { ...d.menu } : null, overMenu: d.overMenu });
  };
  const nearMenu = (d) => {
    const m = wsRef.current && wsRef.current.querySelector(".gdrop"), c = d.target && planeRef.current && planeRef.current.querySelector('.gcard[data-change="' + d.target + '"]');
    if (!m || !c) return false;
    const a = m.getBoundingClientRect(), b = c.getBoundingClientRect(), p = 10;
    return d.lx >= Math.min(a.left, b.left) - p && d.lx <= Math.max(a.right, b.right) + p && d.ly >= Math.min(a.top, b.top) - p && d.ly <= Math.max(a.bottom, b.bottom) + p;
  };
  const dropTarget = (d, id) => {
    const st = stateRef.current;
    const acts = window.dropActionsFor(d.payload, id, { all: st.all, diffs: st.diffs, wcId: st.wcId, selectedId: st.selectedId });
    clearTimeout(dwellT.current);
    if (!acts.length) { d.target = null; d.actions = null; d.menu = null; return; }
    d.target = id; d.actions = acts; d.sel = defaultIdx(acts, d.alt); d.menu = null;
    dwellT.current = setTimeout(() => dragImpl.current.dwell(), 260);
  };
  const track = () => {
    const d = dragRef.current;
    if (!d || !d.started) return;
    const hit = document.elementFromPoint(d.lx, d.ly), el = hit && hit.closest ? hit : null;
    d.overMenu = !!(el && el.closest(".gdrop") && d.menu);
    if (d.overMenu) { const it = el.closest("[data-act]"); if (it) d.menu.sel = +it.dataset.act; }
    else {
      const card = el && el.closest(".gcard[data-change]");
      const id = card && !card.classList.contains("gstack") ? card.dataset.change : null;
      if (id && id === d.target) { d.sel = defaultIdx(d.actions, d.alt); if (d.menu) d.menu.sel = d.sel; }
      else if (id) { if (!(d.menu && nearMenu(d))) dropTarget(d, id); }
      else if (d.target && !(d.menu && nearMenu(d))) { clearTimeout(dwellT.current); d.target = null; d.actions = null; d.menu = null; }
    }
    renderDrag();
  };
  const openDropMenu = () => {
    const d = dragRef.current, n = d && d.target && L.N.get(d.target), el = scrollRef.current, p = planeRef.current;
    if (!n || !el || !p) return;
    const oy = p.offsetTop + p.clientTop - el.scrollTop, ox = p.offsetLeft + p.clientLeft - el.scrollLeft, v = viewInsets(selectedId);
    const seps = d.actions.reduce((s, a, i) => s + (i && d.actions[i - 1].group !== a.group ? 1 : 0), 0);
    const mh = 50 + d.actions.length * 30 + seps * 9;
    const place = n.y + oy - 12 - mh >= v.t + 6 ? "above" : "below";
    const half = 140, lo = v.l + 8 + half - ox, hi = el.clientWidth - v.r - 8 - half - ox, cx = n.x + cardW / 2;
    d.menu = { x: lo > hi ? cx : Math.max(lo, Math.min(hi, cx)), y: place === "above" ? n.y - 12 : n.y + H + 12, place, sel: d.sel };
    renderDrag();
  };
  const stopAuto = () => { cancelAnimationFrame(auto.current.raf); auto.current = { raf: 0, vx: 0, vy: 0 }; };
  const tickAuto = () => {
    const a = auto.current, el = scrollRef.current;
    if (!el || !dragRef.current || (!a.vx && !a.vy)) { a.raf = 0; return; }
    el.scrollLeft += a.vx; el.scrollTop += a.vy; track();
    a.raf = requestAnimationFrame(tickAuto);
  };
  const autoScroll = (d) => {
    const el = scrollRef.current; if (!el) return;
    const r = el.getBoundingClientRect(), v = viewInsets(selectedId), E = 56, x = d.lx, y = d.ly;
    const L0 = r.left + v.l, R0 = r.right - v.r, T0 = r.top + v.t, B0 = r.bottom - v.b;
    if (!d.armed && x > L0 + E && x < R0 - E && y > T0 + E && y < B0 - E) d.armed = true;   // edge-scroll only once the pointer has been inside the graph
    const inside = d.armed && x > L0 - 24 && x < R0 + 24 && y > T0 - 24 && y < B0 + 24;
    const sp = (dist) => dist < E ? Math.ceil((E - Math.max(dist, 0)) / 4) : 0;
    const a = auto.current;
    a.vx = inside ? sp(R0 - x) - sp(x - L0) : 0;
    a.vy = inside ? sp(B0 - y) - sp(y - T0) : 0;
    if ((a.vx || a.vy) && !a.raf) a.raf = requestAnimationFrame(tickAuto);
  };
  const endDrag = () => {
    const d = dragRef.current, f = dragFns.current;
    dragRef.current = null; stopAuto(); clearTimeout(dwellT.current);
    window.removeEventListener("pointermove", f.move, true); window.removeEventListener("pointerup", f.up, true); window.removeEventListener("pointercancel", f.cancel, true);
    window.removeEventListener("keydown", f.key, true); window.removeEventListener("keyup", f.key, true);
    if (d && d.started) {
      try { d.el && d.el.releasePointerCapture(d.pid); } catch (_) {}
      const kill = (e) => { e.stopPropagation(); e.preventDefault(); };
      window.addEventListener("click", kill, true); setTimeout(() => window.removeEventListener("click", kill, true), 0);
      setDrag(null);
    }
    return d;
  };
  useEffect(() => () => endDrag(), []);
  dragImpl.current = {
    move(e) {
      const d = dragRef.current; if (!d) return;
      d.lx = e.clientX; d.ly = e.clientY;
      if (!d.started) {
        if (Math.hypot(e.clientX - d.x0, e.clientY - d.y0) < 5) return;
        d.started = true;
        try { d.el && d.el.setPointerCapture(d.pid); } catch (_) {}
        if (clickT.current) { clearTimeout(clickT.current); clickT.current = null; }
        clearTimeout(hoverT.current); setHoverId(null); setMenu(null);
        window.addEventListener("keydown", dragFns.current.key, true); window.addEventListener("keyup", dragFns.current.key, true);
        const sel = window.getSelection && window.getSelection(); if (sel) sel.removeAllRanges();
      }
      d.alt = e.altKey;
      track();
      autoScroll(d);
    },
    up(e) {
      const d = dragRef.current; if (!d) return;
      if (d.started) { d.lx = e.clientX; d.ly = e.clientY; track(); }
      const g = wsRef.current && wsRef.current.querySelector(".gghost-card"), gr = g && g.getBoundingClientRect();
      const fin = endDrag();
      if (!fin || !fin.started || !fin.target || !fin.actions) return;
      const act = fin.actions[fin.menu ? fin.menu.sel : fin.sel];
      if (act) apply(act.apply, { from: fin.payload.kind === "change" && gr ? { id: fin.payload.id, x: gr.left, y: gr.top } : null });
    },
    cancel() { endDrag(); },
    key(k) {
      const d = dragRef.current; if (!d) return;
      if (k.key === "Escape") { k.stopPropagation(); k.preventDefault(); endDrag(); }
      else if (k.key === "Alt") { d.alt = k.type === "keydown"; if (d.actions && !d.overMenu) { d.sel = defaultIdx(d.actions, d.alt); if (d.menu) d.menu.sel = d.sel; } renderDrag(); }
    },
    dwell() { const d = dragRef.current; if (d && d.started && d.target && !d.menu) openDropMenu(); },
  };
  // el: element that keeps the pointer while dragging (the scroll view for cards, the source itself otherwise)
  const beginDrag = (e, payload, el) => {
    if (e.button !== 0 || dragRef.current) return;
    if (payload.kind === "change") { const c = all.find(x => x.id === payload.id); if (!c || c.isRoot) return; }
    dragRef.current = { payload, x0: e.clientX, y0: e.clientY, lx: e.clientX, ly: e.clientY, alt: e.altKey, started: false, pid: e.pointerId, el: el || e.currentTarget, target: null, actions: null, menu: null, sel: 0, armed: false };
    const f = dragFns.current;
    window.addEventListener("pointermove", f.move, true); window.addEventListener("pointerup", f.up, true); window.addEventListener("pointercancel", f.cancel, true);
  };
  const dndOf = (id) => {
    if (!drag) return null;
    const p = drag.payload;
    if (drag.target === id) return "drop";
    if (p.kind === "change" && p.id === id) return "src";
    if (p.kind === "diff" && p.from === id) return "from";
    if (p.kind === "bookmark" && p.from === id) return "bm";
    return null;
  };

  // ============================================================
  // CALM SCROLLING — while you scroll, the floating controls step aside; the minimap (the graph's scroll indicator) stays.
  // Only real scrolling counts (wheel, pan, minimap) — never a programmatic scroll. What you are typing in never disappears.
  // ============================================================
  const autoHide = floating && t.autoHide !== false;
  const [calm, setCalm] = useState(null);
  const calmRef = useRef({ on: false, acc: 0, t: 0 });
  const nudgeCalm = (amount, endIn = 650) => {
    const c = calmRef.current;
    if (!autoHide || dragRef.current || document.querySelector(".gmenu, .fl-menu, .gtb-menu, .gpm, .rsd-ov, .gset-ov, .home-overlay")) return;
    c.acc += amount;
    if (!c.on && c.acc > 30) {
      c.on = true;
      const a = document.activeElement;
      setCalm({ pin: !!(a && a.closest && a.closest(".gdetail") && /INPUT|TEXTAREA/.test(a.tagName)) });
      clearTimeout(hoverT.current); setHoverId(null);
    }
    clearTimeout(c.t);
    c.t = setTimeout(() => { c.on = false; c.acc = 0; setCalm(null); }, endIn);
  };
  useEffect(() => () => clearTimeout(calmRef.current.t), []);

  // hover intent: crossing the gap between two cards keeps the focus instead of flashing the whole graph back
  const hoverT = useRef(null);
  const hoverCard = (id) => {
    if ((dragRef.current && dragRef.current.started) || calmRef.current.on) return;
    clearTimeout(hoverT.current);
    if (id) setHoverId(id); else hoverT.current = setTimeout(() => setHoverId(null), 140);
  };
  useEffect(() => () => clearTimeout(hoverT.current), []);

  const skipFirst = useRef(true);
  useEffect(() => { if (skipFirst.current) { skipFirst.current = false; return; } pendingScroll.current = wcId; }, [revset, layout]);

  // hidden-history hover + reveal
  const gapEnter = (g) => { clearTimeout(gapT.current); setGapHover(g); };
  const gapLeave = () => { clearTimeout(gapT.current); gapT.current = setTimeout(() => setGapHover(null), 180); };
  const revealGap = (g) => {
    setGapHover(null);
    setRevset("all");
    pendingScroll.current = g.hiddenIds[0] || g.via;
    setFlash(new Set(g.hiddenIds));
    setTimeout(() => setFlash(new Set()), 2600);
  };
  const gapVariant = t.gapMarker || "break";
  const showCount = !!t.gapCount;

  useEffect(() => { setEditMeta(pendingDescribe.current); pendingDescribe.current = false; }, [selectedId]);
  useEffect(() => {
    const h = (e) => {
      if (e.key !== "Escape") return;
      if (editMeta) setEditMeta(false); else setSelectedId(null);
    };
    window.addEventListener("keydown", h);
    return () => window.removeEventListener("keydown", h);
  }, [editMeta]);

  const onCardClick = (id) => {
    if (clickT.current) return;
    clickT.current = setTimeout(() => { clickT.current = null; setSelectedId(id); }, 220);
  };
  const onCardDbl = (id) => {
    if (clickT.current) { clearTimeout(clickT.current); clickT.current = null; }
    const c = L.N.get(id)?.c;
    if (c && !c.immutable) editAt(id);
  };

  // drag-to-pan on empty canvas
  const pan = useRef(null);
  const [panning, setPanning] = useState(false);
  const onPointerDown = (e) => {
    if (e.button !== 0) return;
    const card = e.target.closest(".gcard[data-change]");
    if (card) { if (!card.classList.contains("gstack") && !e.target.closest("button, .gbm, .gqa, .gpeek, .gstack-pop")) beginDrag(e, { kind: "change", id: card.dataset.change }, scrollRef.current); return; }
    if (e.target.closest(".gcard, .gbracket-btn, .ggap-pop, .ghit, .ggap-hit, .gdrop")) return;
    const el = scrollRef.current;
    pan.current = { x: e.clientX, y: e.clientY, l: el.scrollLeft, t: el.scrollTop };
    el.setPointerCapture(e.pointerId);
    setPanning(true);
  };
  const onPointerMove = (e) => {
    if (!pan.current) return;
    const el = scrollRef.current;
    el.scrollLeft = pan.current.l - (e.clientX - pan.current.x);
    el.scrollTop = pan.current.t - (e.clientY - pan.current.y);
    nudgeCalm(Math.abs(e.movementX || 0) + Math.abs(e.movementY || 0), 420);
  };
  const endPan = () => { pan.current = null; setPanning(false); };
  const onPointerUp = () => endPan();
  const onPointerCancel = () => endPan();

  const selected = selectedId ? all.find(c => c.id === selectedId) : null;
  const pickBookmark = (id) => {
    if (!visibleSet.has(id)) setRevset("all");
    setSelectedId(id);
    pendingScroll.current = id;
    if (visibleSet.has(id)) scrollToNode(id, true, id);
  };
  // floating: keep the selected card clear of the floating detail panel
  useEffect(() => {
    if (!floating || !selectedId) return;
    const n = L.N.get(selectedId), el = scrollRef.current, p = planeRef.current;
    if (!n || !el || !p) return;
    const v = viewInsets(selectedId), x = n.x + p.offsetLeft + p.clientLeft - el.scrollLeft;
    if (x < v.l + 8 || x + cardW > el.clientWidth - v.r - 8) scrollToNode(selectedId, true, selectedId);
  }, [selectedId]);

  const focus = useMemo(() => {
    if (!t.hoverFocus || !hoverId || !L.N.get(hoverId)) return null;
    const s = new Set([hoverId]);
    const walk = (key) => { const st = [hoverId]; while (st.length) { const n = L.N.get(st.pop()); (key === "up" ? n.parents.map(p => p.id) : n.children).forEach(x => { if (!s.has(x)) { s.add(x); st.push(x); } }); } };
    walk("up"); walk("down");
    return s;
  }, [L, hoverId, t.hoverFocus]);
  const gapEdges = gapHover && gapHover.edges ? new Set(gapHover.edges) : null;
  const edgeCls = (e, i) => {
    const hl = ancestors.has(e.from) && ancestors.has(e.to);
    const hov = (gapEdges && gapEdges.has(i)) || (focus ? focus.has(e.from) && focus.has(e.to) : hoverId && (e.from === hoverId || e.to === hoverId));
    return { hl, hov, dim: !!focus && !hov };
  };
  const bridges = t.crossings !== "plain";
  const sortedEdges = L.edges.map((e, i) => ({ ...e, i, ...edgeCls(e, i) })).sort((a, b) => (a.hl - b.hl) || (a.hov - b.hov));
  const edgeState = new Map(sortedEdges.map(e => [e.i, e]));
  const cuts = new Map();
  const addCut = (i, r) => { if (!cuts.has(i)) cuts.set(i, []); cuts.get(i).push(r); };
  if (bridges) L.edges.forEach((e, i) => e.gaps.forEach(g => addCut(i, { x: g.x - 6, y: g.y - 5, w: 12, h: 10 })));
  L.markers.forEach(m => { const r = window.gapCut(m, gapVariant); if (r) m.edges.forEach(i => addCut(i, r)); });
  const markerCls = (m) => {
    const es = m.edges.map(i => edgeState.get(i));
    return (es.every(e => e.hl) ? "hl " : "") + (gapHover && gapHover.key === m.key || es.some(e => e.hov) ? "hov " : "") + (es.every(e => e.dim) ? "dim" : "");
  };
  const stubCls = (s) => (ancestors.has(s.node) ? "hl " : "") + (gapHover && gapHover.key === s.key || hoverId === s.node ? "hov " : "") + (focus && !focus.has(s.node) ? "dim" : "");
  const gapInfo = { variant: gapVariant, gaps: L.markers.length, ends: L.stubs.length };
  // floating: plane border = area covered by floating UI, so every edge of the graph can be scrolled clear of it
  const fi = floatInsets || {};
  const pad = floating ? { t: (fi.top || 0) + 4, r: (fi.right || 0) + 12 + (selectedId ? (fi.detail || 0) : MINI_CARD + 12), b: (fi.bottom || 0) + 12, l: (fi.left || 0) + 2 } : null;
  const prevPadL = useRef(pad ? pad.l : 0);
  useLayoutEffect(() => {
    if (!pad) return;
    const d = pad.l - prevPadL.current, el = scrollRef.current;
    prevPadL.current = pad.l;
    if (d && el) el.scrollLeft += d; // keep the graph visually still when a side panel opens/closes
  }, [pad && pad.l]);
  const planeStyle = pad
    ? { width: L.width, height: L.height, borderWidth: `${pad.t}px ${pad.r}px ${pad.b}px ${pad.l}px`, minWidth: `calc(100% - ${pad.l + pad.r}px)`, minHeight: `calc(100% - ${pad.t + pad.b}px)` }
    : { width: L.width, height: L.height };

  return (
    <div className={"gws" + (floating ? " is-float" : "") + (drag ? " is-dragging drag-" + drag.payload.kind : "") + (calm ? " is-calm" + (calm.pin ? " pin-ins" : "") : "")} ref={wsRef}>
      {!floating && <GraphToolbar revset={revset} setRevset={setRevset} layout={layout} setLayout={setLayout} detailed={detailed} setDetailed={setDetailed}
        stacks={stacks} setStacks={setStacks}
        cardW={cardW} setCardW={setCardW} shown={shownCount} total={all.length} gapInfo={gapInfo}
        onLocate={() => scrollToNode(wcId)}/>}
      <div className="gbody">
        {!floating && leftPanel !== "history" && (
          <div className="gleft">
            {leftPanel === "branches"
              ? <window.SidePanel title="Bookmarks" icon="branch" onClose={onCloseLeft}><BookmarkList commits={all} visibleSet={visibleSet} onPick={pickBookmark} onBeginDrag={beginDrag}/></window.SidePanel>
              : <window.LeftPanel kind={leftPanel} onClose={onCloseLeft}/>}
          </div>
        )}
        <div className={"gscroll " + (panning ? "panning" : "")} ref={scrollRef}
          onPointerDown={onPointerDown} onPointerMove={onPointerMove} onPointerUp={onPointerUp} onPointerCancel={onPointerCancel}
          onWheel={(e) => { if (!e.ctrlKey) nudgeCalm(Math.abs(e.deltaX) + Math.abs(e.deltaY)); }}
          data-screen-label="Graph">
          <div className={"gplane" + (moving ? " is-moving" : "")} ref={planeRef} style={planeStyle}>
            {!floating && L.buckets.length > 0 && (
              <div className="gtime" style={{ height: L.height, width: G.gutter }}>
                {L.buckets.filter(b => b.label).map(b => (
                  <div key={b.start} className="gtime-label" style={{ top: b.y }}>{b.label}</div>
                ))}
              </div>
            )}
            <svg className="gedges" width={L.width} height={L.height}>
              {L.buckets.filter(b => b.guide != null).map(b => (
                <line key={"g_" + b.start} x1={L.offX} x2={L.width} y1={b.guide} y2={b.guide} className="gguide"/>
              ))}
              <defs>
                {[...cuts].map(([i, rs]) => (
                  <mask key={i} id={"gm" + i} maskUnits="userSpaceOnUse" x="0" y="0" width={L.width} height={L.height}>
                    <rect x="0" y="0" width={L.width} height={L.height} fill="white"></rect>
                    {rs.map((g, k) => <rect key={k} x={g.x} y={g.y} width={g.w} height={g.h} fill="black"></rect>)}
                  </mask>
                ))}
              </defs>
              {sortedEdges.map(e => (
                <path key={e.from + ">" + e.to} d={e.d} mask={cuts.has(e.i) ? `url(#gm${e.i})` : undefined} pathLength={bornId && (e.from === bornId || e.to === bornId) ? 1 : undefined}
                  className={"gedge " + (e.dashed ? "dashed " : "") + (e.hov ? "hov " : "") + (e.hl ? "hl " : "") + (e.dim ? "dim " : "") + (bornId && (e.from === bornId || e.to === bornId) ? "born" : "")}/>
              ))}
              {L.markers.map(m => <window.GapMark key={m.key} m={m} variant={gapVariant} count={showCount || counted.has(m.key) ? m.count : null} cls={markerCls(m)}/>)}
              {L.stubs.map(s => <window.GapEnd key={s.key} s={s} variant={gapVariant} count={showCount || counted.has(s.key) ? s.count : null} cls={stubCls(s)}/>)}
              {L.markers.map(m => m.edges.map(i => (
                <path key={"h" + m.key + i} d={L.edges[i].d} className="ghit" onMouseEnter={() => gapEnter(m)} onMouseLeave={gapLeave}/>
              )))}
            </svg>
            {L.markers.map(m => (
              <div key={"mh" + m.key} className="ggap-hit" style={{ left: m.x - 13, top: m.y - 13, width: 26, height: 26 }} onMouseEnter={() => gapEnter(m)} onMouseLeave={gapLeave}></div>
            ))}
            {L.stubs.map(s => (
              <div key={"sh" + s.key} className="ggap-hit" style={{ left: s.x - 10, top: s.y + 1, width: 96, height: 20 }} onMouseEnter={() => gapEnter(s)} onMouseLeave={gapLeave}></div>
            ))}
            {gapHover && (L.markers.some(m => m.key === gapHover.key) || L.stubs.some(s => s.key === gapHover.key)) && (
              <window.GapPeek g={gapHover.kind === "end" ? { ...gapHover, y: gapHover.y + 10 } : gapHover} N={L.N} variant={gapVariant} showCount={showCount} counted={counted.has(gapHover.key)}
                flip={gapHover.x + 380 > L.width} onCount={() => setCounted(new Set([...counted, gapHover.key]))}
                onReveal={() => revealGap(gapHover)} onEnter={() => gapEnter(gapHover)} onLeave={gapLeave}/>
            )}
            {drag && drag.menu && drag.actions && <window.DropMenu menu={drag.menu} actions={drag.actions} over={drag.overMenu}/>}
            {brackets.map(b => (
              <div key={b.id} className={"gbracket " + (b.members.has(hoverId) ? "on" : "")} style={{ left: b.x, top: b.top, height: b.h }}>
                <button className="gbracket-btn" onClick={() => toggleStack(b.id)} title={"Collapse " + b.n + " changes into a stack"} aria-label="Collapse stack">
                  <svg width="11" height="11" viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinejoin="round"><rect x="2" y="6.5" width="9" height="7.5" rx="1.5"/><path d="M5 4h8.5a.5.5 0 0 1 .5.5V11"/><path d="M8 1.5h7.5"/></svg>
                </button>
              </div>
            ))}
            {L.nodes.map(n => n.c.isGroup ? (
              <StackCard key={n.id} n={n} W={cardW} H={H} detailed={detailed} dim={!!focus && !focus.has(n.id)}
                onClick={() => toggleStack(n.id)} onHover={hoverCard}/>
            ) : (
              <GraphCard reveal={revealSet.has(n.id)} flash={flash.has(n.id)} key={n.id} n={n} W={cardW} H={H} detailed={detailed} legend={t.bookmarkLabels !== "hover"} addMode={t.addButtons || "menu"} isCtx={!!menu && menu.id === n.id} onMenu={openMenu}
                isSel={selectedId === n.id} isWC={wcId === n.id} isHover={hoverId === n.id} dim={!!focus && !focus.has(n.id)}
                onClick={() => onCardClick(n.id)} onDoubleClick={() => onCardDbl(n.id)} onHover={hoverCard} onAction={cardAction}
                dnd={dndOf(n.id)} onBeginDrag={beginDrag}/>
            ))}
          </div>
        </div>
        {floating && <GraphMinimap L={L} H={H} scrollRef={scrollRef} planeRef={planeRef} pos={{ right: fi.right || 0, top: fi.top || 0, bottom: fi.bottom || 0 }} hidden={!!selected && !(calm && !calm.pin)} onScrub={nudgeCalm} top={fi.top || 0} bottom={fi.bottom || 0} wcId={wcId} selectedId={selectedId}/>}
        {selected && (floating ? (
          <window.GraphInspector key={selected.id} commit={selected} isWC={wcId === selected.id} files={diffs[selected.id] || []}
            editing={editMeta} setEditing={setEditMeta} canSquash={canSquash(selected)}
            onClose={() => setSelectedId(null)} onEdit={() => editAt(selected.id)} onNew={(pid) => newChange(pid)}
            onDescribe={(sub, body) => describeChange(selected.id, sub, body)} onSplit={(ids, m) => splitChange(selected.id, ids, m)} onCommit={(ids, m) => commitWC(selected.id, ids, m)}
            onSquash={() => squashParent(selected.id)} onAbandon={() => abandonChange(selected.id)}
            beginDrag={beginDrag} lift={drag && drag.payload.kind === "diff" && drag.payload.from === selected.id ? drag.payload.hunkIds : null}
            t={t} setTweak={setTweak}/>
        ) : (
          <GraphDetail key={selected.id} commit={selected} isWC={wcId === selected.id}
            editMeta={editMeta} setEditMeta={setEditMeta}
            onClose={() => setSelectedId(null)} onEdit={() => editAt(selected.id)} t={t} setTweak={setTweak}/>
        ))}
      </div>
      {floating && chrome && chrome({
        revset, setRevset, layout, setLayout, detailed, setDetailed, stacks, setStacks, cardW, setCardW,
        shown: shownCount, total: all.length, gapInfo, onLocate: () => scrollToNode(wcId),
        all, visibleSet, pickBookmark, detailOpen: !!selected, wcDir, newChange: () => newChange(wcId), beginDrag, calm: !!calm, toastOn: !!toast,
      })}
      {menu && L.N.get(menu.id) && (
        <CardMenu key={menu.id + menu.x + "," + menu.y} menu={menu} c={L.N.get(menu.id).c} isWC={wcId === menu.id} onClose={closeMenu}
          onAction={(a) => { closeMenu(); cardAction(menu.id, a); }}/>
      )}
      {drag && <window.DragGhost drag={drag} commit={drag.payload.kind === "change" ? (all.find(c => c.id === drag.payload.id) || null) : null} isWC={drag.payload.kind === "change" && drag.payload.id === wcId}/>}
      {toast && <window.OpToast toast={toast} onUndo={undo} onClose={() => { clearTimeout(toastT.current); setToast(null); }}
        style={{ left: `calc((${floating ? (fi.left || 0) : 0}px + 100% - ${(selected ? (fi.detail || 0) + (fi.right || 0) : floating ? MINI_CARD + 12 + (fi.right || 0) : 0)}px) / 2)` }}/>}
    </div>
  );
}

Object.assign(window, { GraphWorkspace, computeLayout, shortBookmark, groupStacks, BookmarkList, BookmarkGlyph });
})();
