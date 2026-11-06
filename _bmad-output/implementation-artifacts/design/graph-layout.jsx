/* global React */
// Commit graph layout engine — shared by the client (graph-view.jsx) and the studies (Graph Lines Study).
// Rows — Free (default): commits close in time stand close together, across branches · Compact: generation depth.
//   y is counted in units, 16 units = 1 pitch (card height + gapY); y = 0 is the oldest commit, at the bottom.
// Lines — one line per parent → child pair: own exit on the parent's top edge, own entry on the child's bottom edge,
//   horizontal stretches nest instead of crossing. route "A" = the routing before, "C" = shared fork lines (study only).
(() => {
const G = { gapX: 56, gapY: 48, pad: 56, hCompact: 40, hDetailed: 62, elide: 44, gutter: 88 };
// Settings › Density (sync #21): more air around the cards, never larger text — card heights and the gaps between them.
// Compact = G's own values; the client copies a set into G before it lays out (graph-view.jsx).
const DENSITY = {
  compact:  { gapX: 56, gapY: 48, hCompact: 40, hDetailed: 62 },
  balanced: { gapX: 62, gapY: 54, hCompact: 44, hDetailed: 68 },
  comfy:    { gapX: 68, gapY: 60, hCompact: 48, hDetailed: 74 },
};
const U = 16;
const CUT_CLEAR = 12;
const colMemo = new WeakMap();                          // graph list → chosen lanes + columns                                       // a bridge keeps this much visible line to the next bend or card
// Ports, top and bottom alike (Story 10.30; by local direction since 2026-11-02): only the stretch right at a card edge
// decides, whatever the line's kind — a line is vertical there when it runs straight through the band next to the edge,
// else it turns there toward its side. One line → centre; several → the vertical line that stays straight longest takes
// the centre, the rest fan to the side they turn to (vertical innermost); none vertical → the centre stays free. Two
// vertical lines never share an x, also across the card edges of one column (the column tie-break in routeLines).
const ENTRY = { first: 24, step: 16, min: 8, inset: 18 };   // the fan on either edge, offsets from the centre

function roundedPath(raw, r) {
  const pts = raw.filter((p, i) => i === 0 || p[0] !== raw[i - 1][0] || p[1] !== raw[i - 1][1]);
  let d = `M${pts[0][0]},${pts[0][1]}`;
  for (let i = 1; i < pts.length - 1; i++) {
    const [x0, y0] = pts[i - 1], [x1, y1] = pts[i], [x2, y2] = pts[i + 1];
    const l1 = Math.hypot(x1 - x0, y1 - y0), l2 = Math.hypot(x2 - x1, y2 - y1), rr = Math.min(r, l1 / 2, l2 / 2);
    d += ` L${x1 - (x1 - x0) / l1 * rr},${y1 - (y1 - y0) / l1 * rr} Q${x1},${y1} ${x1 + (x2 - x1) / l2 * rr},${y1 + (y2 - y1) / l2 * rr}`;
  }
  const last = pts[pts.length - 1];
  return d + ` L${last[0]},${last[1]}`;
}

// Free: time gap (ms) → units (1/16 pitch); piecewise-linear log2, integers only, capped at 3 pitches
function gapUnits(g) {
  const x = 1 + Math.floor(Math.max(0, g) / 60000);
  let k = 0; while (2 ** (k + 1) <= x) k++;
  const l2 = 256 * k + Math.floor(((x - 2 ** k) * 256) / 2 ** k);
  return Math.min(48, Math.floor((2 * l2) / 256));
}

function dayStart(t) { const d = new Date(t); d.setHours(0, 0, 0, 0); return d.getTime(); }
// local calendar day of a time stamp (ms) → key + label + year: Today · Yesterday · Sep 23 — never a year in the label;
// the year is a label of its own at each year boundary (sync #22)
function dayBucket(t) {
  if (t == null || isNaN(t)) return { key: -Infinity, label: "" };
  const now = new Date(dayStart(Date.parse(window.GRAPH_NOW) || Date.now())), yd = new Date(now);
  yd.setDate(yd.getDate() - 1);
  const key = dayStart(t), d = new Date(key);
  const label = key >= now.getTime() ? "Today" : key === yd.getTime() ? "Yesterday" : d.toLocaleDateString("en-US", { month: "short", day: "numeric" });
  return { key, label, year: d.getFullYear() };
}

function segsOf(e) {
  const s = [];
  for (let i = 1; i < e.pts.length; i++) {
    const [x1, y1] = e.pts[i - 1], [x2, y2] = e.pts[i];
    if (x1 === x2 && y1 === y2) continue;
    s.push(y1 === y2 ? { h: true, c: y1, a: Math.min(x1, x2), b: Math.max(x1, x2) } : { h: false, c: x1, a: Math.min(y1, y2), b: Math.max(y1, y2) });
  }
  return s;
}
// Orthogonal polylines → H/V crossings (+ collinear overlaps, which read as one line)
function analyzeEdges(edges) {
  const segs = edges.map(segsOf), cross = [], E = 1;
  let overlaps = 0;
  for (let i = 0; i < edges.length; i++) for (let j = i + 1; j < edges.length; j++) {
    const A = edges[i], B = edges[j];
    if (A.from === B.from || A.to === B.to || A.from === B.to || A.to === B.from) continue;
    segs[i].forEach(s => segs[j].forEach(t => {
      if (s.h !== t.h) {
        const [h, v, hi, vi] = s.h ? [s, t, i, j] : [t, s, j, i];
        if (v.c > h.a + E && v.c < h.b - E && h.c > v.a + E && h.c < v.b - E) cross.push({ x: v.c, y: h.c, edge: hi, hEdge: hi, vEdge: vi, hs: h, vs: v });
      } else if (Math.abs(s.c - t.c) < E && Math.min(s.b, t.b) - Math.max(s.a, t.a) > E) overlaps++;
    }));
  }
  return { cross, overlaps };
}
// Bridges: the horizontal line breaks where it passes a vertical one — unless the break would sit closer than CUT_CLEAR
// to a bend or a card; then the vertical line breaks instead (whichever keeps more line visible).
function placeCuts(edges, cross) {
  const cuts = edges.map(() => []);
  cross.forEach(c => {
    const hRoom = Math.min(c.x - 6 - c.hs.a, c.hs.b - c.x - 6), vRoom = Math.min(c.y - 6 - c.vs.a, c.vs.b - c.y - 6);
    if (hRoom < CUT_CLEAR && vRoom > hRoom) cuts[c.vEdge].push({ x: c.x - 5, y: c.y - 6, w: 10, h: 12 });
    else cuts[c.hEdge].push({ x: c.x - 6, y: c.y - 5, w: 12, h: 10 });
  });
  return cuts;
}

// Horizontal stretches that share room → tracks. `down` = x where a line leaves the stretch downward (towards the parent),
// `up` = x where it leaves upward (towards the child). If A spans a down-exit of B, A must run above B; if B spans an up-exit of A, too.
// Topological order on that relation, then the first free track that keeps it — so lines nest instead of crossing.
function assignTracks(segs) {
  const n = segs.length, inside = (s, x) => x > s.a + 0.5 && x < s.b - 0.5;
  const pred = segs.map(() => new Set());
  for (let i = 0; i < n; i++) for (let j = 0; j < n; j++) {
    if (i !== j && (segs[j].down.some(x => inside(segs[i], x)) || segs[i].up.some(x => inside(segs[j], x)))) pred[j].add(i);
  }
  for (let i = 0; i < n; i++) [...pred[i]].forEach(j => { if (pred[j].has(i)) { pred[i].delete(j); pred[j].delete(i); } }); // unavoidable crossing
  const done = new Set(), order = [];
  while (order.length < n) {
    let pick = -1, best = Infinity;
    for (let i = 0; i < n; i++) if (!done.has(i)) {
      let open = 0; pred[i].forEach(k => { if (!done.has(k)) open++; });
      const key = open * 1e5 - (segs[i].b - segs[i].a);
      if (key < best) { best = key; pick = i; }
    }
    done.add(pick); order.push(pick);
  }
  const pos = new Map(order.map((i, k) => [i, k])), track = new Array(n).fill(0), rows = [];
  order.forEach(i => {
    let t = 0;
    pred[i].forEach(k => { if (pos.get(k) < pos.get(i)) t = Math.max(t, track[k] + 1); });
    while ((rows[t] || []).some(k => segs[k].a < segs[i].b + 10 && segs[i].a < segs[k].b + 10)) t++;
    (rows[t] = rows[t] || []).push(i); track[i] = t;
  });
  return { track, count: Math.max(1, rows.length) };
}
// Tracks of one cluster → heights: in order, 3.5–6 px apart, each inside its own free range, the block centred.
// A cluster carrying a hidden merge (dashed lines sharing one entry) sits as far from the child as it can, so the gap marker fits on the stem.
function placeTracks(segs, near) {
  const { track, count } = assignTracks(segs);
  const ord = [...segs.keys()].sort((i, j) => track[i] - track[j]), lam = segs.some(s => s.deep) ? 1 : 0.5;
  const pack = (sp) => {
    const top = [], bot = [];
    ord.forEach(i => { top[i] = segs[i].lo; ord.forEach(j => { if (track[j] < track[i] && near(segs[i], segs[j])) top[i] = Math.max(top[i], top[j] + sp); }); });
    [...ord].reverse().forEach(i => { bot[i] = segs[i].hi; ord.forEach(j => { if (track[j] > track[i] && near(segs[i], segs[j])) bot[i] = Math.min(bot[i], bot[j] - sp); }); });
    return { top, bot, ok: ord.every(i => top[i] <= bot[i] + 0.01) };
  };
  const sp0 = count > 1 ? Math.max(3.5, Math.min(6, 24 / (count - 1))) : 0;
  let P = pack(sp0);
  if (!P.ok && sp0 > 3.5) P = pack(3.5);
  if (P.ok) { segs.forEach((s, i) => { s.y = P.top[i] + lam * (P.bot[i] - P.top[i]); }); return; }
  // more lines than room: keep order and spacing, centre the block on the band
  const mid = segs.reduce((a, s) => a + (s.lo + s.hi) / 2, 0) / segs.length, ys = segs.map((s, i) => P.top[i]);
  const shift = mid - (Math.min(...ys) + Math.max(...ys)) / 2;
  segs.forEach((s, i) => { s.y = ys[i] + shift; });
}

// The routing before (study variant A, and the optimizer's quick estimate): children on one side share a line, merges enter at the centre.
function routeLegacy(nodes, N, W, H, xOf = n => n.x, yOf = n => n.y, blk = pp => pp.blocked) {
  const out = [];
  nodes.forEach(n => n.parents.forEach((pp, i) => {
    const p = N.get(pp.id), pcx = xOf(p) + W / 2, ncx = xOf(n) + W / 2, outY = yOf(p), inY = yOf(n) + H;
    let pts;
    if (pcx === ncx) pts = [[pcx, outY], [ncx, inY]];
    else if (i > 0 && !blk(pp)) { const my = inY + G.gapY * 0.4; pts = [[pcx, outY], [pcx, my], [ncx, my], [ncx, inY]]; }
    else { const sx = pcx + (ncx > pcx ? 1 : -1) * W * 0.28, hy = outY - G.gapY * 0.4; pts = [[sx, outY], [sx, hy], [ncx, hy], [ncx, inY]]; }
    out.push({ from: p.id, to: n.id, pts, dashed: pp.skipped, via: pp.via, count: pp.count, hiddenIds: pp.hiddenIds });
  }));
  return { edges: out, ports: null };
}

// One line per parent → child pair (variant B; bus = C: a parent's children share one line).
// fork: turns above the parent, climbs the child's lane · merge1: one pitch apart · mergeUp: climbs the parent's free lane, turns below the child ·
// gutter: lane taken (or, in Free, a card in the way) — turns above the parent, climbs a gutter between columns, turns below the child.
function routeLines(nodes, N, W, H, { bus = false, free = false } = {}) {
  const GY = G.gapY, colW = W + G.gapX;
  const E = [];
  nodes.forEach(n => n.parents.forEach((pp, i) => {
    const p = N.get(pp.id);
    E.push({ p, n, i, from: p.id, to: n.id, dashed: pp.skipped, via: pp.via, count: pp.count, hiddenIds: pp.hiddenIds });
  }));
  const cols = new Map();
  nodes.forEach(o => { if (!cols.has(o.col)) cols.set(o.col, []); cols.get(o.col).push(o); });
  const colFree = (col, u0, u1) => !(cols.get(col) || []).some(o => o.u > u0 && o.u < u1);
  const pBand = p => [p.y - GY, p.y], nBand = n => [n.y + H, n.y + H + GY];
  // inner part of a band (12px off the cards); in Free, minus every card that reaches into it over the stretch's x-range
  const room = (band, a, b) => {
    let ivs = [[band[0] + 12, band[1] - 12]];
    if (free) nodes.forEach(o => {
      if (o.x >= b + 4 || o.x + W <= a - 4) return;
      const c0 = o.y - 10, c1 = o.y + H + 10;
      ivs = ivs.flatMap(([l, h]) => c1 <= l || c0 >= h ? [[l, h]] : [[l, c0], [c1, h]].filter(([x, y]) => y >= x));
    });
    return ivs;
  };
  const clear = (band, x0, x1) => room(band, Math.min(x0, x1), Math.max(x0, x1)).length > 0;
  const gutterXs = e => {
    const k = Math.abs(e.n.col - e.p.col);
    return k ? [...Array(k).keys()].map(j => e.n.cx - e.side * colW * (j + 0.5)) : [e.n.cx + e.side * colW / 2];
  };
  const gutterOk = (e, x) => clear(pBand(e.p), e.p.cx, x) && clear(nBand(e.n), x, e.n.cx);
  E.forEach(e => {
    const { p, n } = e;
    e.side = Math.sign(n.cx - p.cx);
    let kind = !e.side ? (e.i === 0 && colFree(p.col, p.u, n.u) ? "straight" : "gutter")
      : e.i === 0 ? (colFree(n.col, p.u, n.u) ? "fork" : "gutter")
      : n.u === p.u + U ? "merge1"
      : colFree(p.col, p.u, n.u) ? "mergeUp"
      // 2026-11-03 (Ralph's review): the parent's lane is taken — climb the child's lane like a first parent first.
      : colFree(n.col, p.u, n.u) ? "fork" : "gutter";
    if (!e.side) e.side = 1;
    const direct = kind === "mergeUp" ? clear(nBand(n), p.cx, n.cx) : kind === "fork" || kind === "merge1" ? clear(pBand(p), p.cx, n.cx) : true;
    if (kind === "gutter" || !direct) {
      const xs = gutterXs(e), x = xs.find(g => gutterOk(e, g));   // nearest the child first
      if (kind === "gutter" || x != null) { kind = "gutter"; e.gx = x != null ? x : xs[0]; }
    }
    e.kind = kind;
  });
  const gut = new Map();
  E.filter(e => e.kind === "gutter").forEach(e => {
    const k = gut.get(e.gx) || 0; gut.set(e.gx, k + 1);
    e.xg = e.gx + (k ? (k % 2 ? 6 : -6) * Math.ceil(k / 2) : 0);
  });
  // m ports, inner → outer: `step` apart while they fit, squeezed down to `min`; past that the overflow shares the outermost port
  const fan = (m, first, step, min, max) => {
    if (m <= 1) return m ? [first] : [];
    const span = Math.max(0, max - first), st = Math.min(step, span / (m - 1));
    if (st >= min) return [...Array(m).keys()].map(k => first + k * st);
    const own = Math.floor(span / min);
    return [...Array(m).keys()].map(k => first + Math.min(k, own) * min);
  };
  // Ports by local direction (see the header). A line's reach at a card edge: how far it runs straight from the edge to the
  // near side of the band it first turns in (straight: Infinity) — vertical there when reach ≥ gapY. At the parent's top a
  // mergeUp turns in the band below its child, the rest in the band above the parent; at the child's bottom a fork turns in
  // the band above its parent, the rest in the band below the child.
  const stretch = e => e.p.y - GY - (e.n.y + H);
  E.forEach(e => {
    e.rIn = e.kind === "straight" ? Infinity : e.kind === "fork" ? stretch(e) : 0;
    e.rOut = e.kind === "straight" ? Infinity : e.kind === "mergeUp" ? stretch(e) : 0;
    e.noIn = e.noOut = false; e.extIn = e.extOut = 0;
  });
  // one card edge's lines → x: one line, else the vertical one that stays straight longest, at the centre (none vertical:
  // the centre stays free); the rest per side of the x they turn toward — vertical innermost (longest first), then turning
  // lines nearest first. `no` bans a line from the centre, `ext` puts it that many fan slots further out (the column tie-break).
  const place = (lines, mid, reach, toward, tie, no, ext, set) => {
    let centre = null;
    lines.forEach(l => { if (!no(l) && (lines.length === 1 || reach(l) >= GY && (!centre || reach(l) > reach(centre)))) centre = l; });
    if (centre) set(centre, mid);
    [-1, 1].forEach(s => {
      const key = l => reach(l) >= GY ? -reach(l) : Math.abs(toward(l) - mid);
      const list = lines.filter(l => l !== centre && (toward(l) < mid ? -1 : 1) === s).sort((a, b) => key(a) - key(b) || tie(a) - tie(b));
      const xs = fan(list.reduce((m, l) => m + 1 + ext(l), 0), ENTRY.first, ENTRY.step, ENTRY.min, W / 2 - ENTRY.inset);
      let slot = 0;
      list.forEach(l => { slot += ext(l); set(l, mid + s * xs[slot++]); });
    });
  };
  // entries on the child's bottom edge, per slot: dashed edges through the same hidden parent are one parent — they share its
  // port (and its gap marker); the slot's first line owns it.
  const approach = e => e.kind === "gutter" ? e.xg : e.p.cx;
  const inSlots = new Map();
  nodes.forEach(n => {
    const slots = new Map();
    E.filter(e => e.n === n).forEach(e => { const k = e.dashed ? "~" + e.via : e.from; if (!slots.has(k)) slots.set(k, []); slots.get(k).push(e); });
    inSlots.set(n, [...slots.values()]);
  });
  const entries = () => nodes.forEach(n => place(inSlots.get(n), n.cx, es => es[0].rIn, es => approach(es[0]), es => es[0].p.u,
    es => es[0].noIn, es => es[0].extIn, (es, x) => es.forEach(e => { e.xi = x; })));
  // exits on the parent's top edge, the same rule (in bus mode a side's lines that turn at the top share its innermost such exit)
  const turn = e => e.kind === "gutter" ? e.xg : e.xi;
  const exits = () => nodes.forEach(p => {
    const outs = E.filter(e => e.p === p);
    place(outs, p.cx, e => e.rOut, turn, () => 0, e => e.noOut, e => e.extOut, (e, x) => { e.xo = x; });
    if (bus) [-1, 1].forEach(s => {
      const rest = outs.filter(e => e.rOut < GY && e.xo !== p.cx && Math.sign(e.xo - p.cx) === s)
        .sort((a, b) => Math.abs(a.xo - p.cx) - Math.abs(b.xo - p.cx));
      rest.forEach(e => { e.xo = rest[0].xo; e.bus = p.id + "|" + s; });
    });
  });
  // the column tie-break: two vertical lines never share an x — where the straight stretches (card edge through the first turn
  // band) of lines of different card edges overlap on one x, the one that stays straight longer keeps its port (tie: the lower
  // edge index), the other leaves the centre or sits one fan slot further out; two lines that both turn at their edges are left to the
  // tracks. Returns whether a line moved.
  const ban = () => {
    const claims = [];
    E.forEach((e, k) => {
      const top = e.p.y, bottom = e.n.y + H;
      claims.push({ e, k, entry: false, at: e.xo, lo: e.kind === "straight" ? bottom : top - e.rOut - GY, hi: top, len: e.rOut });
      if (e.kind !== "straight" && inSlots.get(e.n).some(es => es[0] === e)) {
        claims.push({ e, k, entry: true, at: e.xi, lo: bottom, hi: bottom + e.rIn + GY, len: e.rIn });
      }
    });
    claims.sort((a, b) => a.at - b.at || a.lo - b.lo);
    const moved = new Set();
    let any = false;
    claims.forEach((a, i) => {
      for (let j = i + 1; j < claims.length && claims[j].at === a.at && claims[j].lo < a.hi; j++) {
        const b = claims[j];
        const sameEdge = a.entry === b.entry && (a.entry ? a.e.n === b.e.n : a.e.p === b.e.p);
        if (a.e === b.e || (a.len < GY && b.len < GY) || sameEdge || moved.has(a) || moved.has(b)) continue;
        const l = a.len < b.len || (a.len === b.len && a.k > b.k) ? a : b;
        if (l.at === (l.entry ? l.e.n.cx : l.e.p.cx)) l.e[l.entry ? "noIn" : "noOut"] = true;
        else l.e[l.entry ? "extIn" : "extOut"]++;
        moved.add(l); any = true;
      }
    });
    return any;
  };
  let passes = 0;
  do { entries(); exits(); } while (++passes < 8 && ban());
  const ports = new Map(nodes.map(n => [n.id, [...new Set(E.filter(e => e.n === n).map(e => e.xi))]]));
  // horizontal stretches: in the band above the parent and/or the band below the child
  const grouped = new Set();
  nodes.forEach(n => {
    const vias = E.filter(e => e.n === n && e.dashed).map(e => e.via);
    vias.forEach(v => { if (vias.indexOf(v) !== vias.lastIndexOf(v)) grouped.add(n.id + "|" + v); });
  });
  E.forEach(e => {
    const { p, n } = e, deep = e.dashed && grouped.has(n.id + "|" + e.via);
    e.hs = e.kind === "straight" ? []
      : e.kind === "mergeUp" ? [{ band: nBand(n), d: e.xo, u: e.xi, deep }]
      : e.kind === "gutter" ? [{ band: pBand(p), d: e.xo, u: e.xg }, { band: nBand(n), d: e.xg, u: e.xi, deep }]
      : [{ band: pBand(p), d: e.xo, u: e.xi, deep: deep && e.kind === "merge1" }];
  });
  const segOf = new Map(), segs = [];
  E.forEach(e => e.hs.forEach((h, hi) => {
    const key = bus && hi === 0 && e.bus ? "bus:" + e.bus : e.from + ">" + e.to + "#" + hi;
    let s = segOf.get(key);
    if (!s) { s = { down: [], up: [], band: h.band, deep: false }; segOf.set(key, s); segs.push(s); }
    if (!s.down.includes(h.d)) s.down.push(h.d);
    if (!s.up.includes(h.u)) s.up.push(h.u);
    if (h.deep) s.deep = true;
    h.seg = s;
  }));
  segs.forEach(s => {
    const xs = [...s.down, ...s.up], mid = (s.band[0] + s.band[1]) / 2;
    s.a = Math.min(...xs); s.b = Math.max(...xs);
    let best = null, bd = Infinity;
    room(s.band, s.a, s.b).forEach(([l, h]) => { const d = mid < l ? l - mid : mid > h ? mid - h : 0; if (d < bd) { bd = d; best = [l, h]; } });
    [s.lo, s.hi] = best || [mid, mid];
  });
  // stretches whose bands and x-ranges touch share their room: one cluster, one track order
  const near = (A, B) => A.a < B.b + 10 && B.a < A.b + 10;
  const root = segs.map((_, i) => i), find = i => root[i] === i ? i : (root[i] = find(root[i]));
  for (let i = 0; i < segs.length; i++) for (let j = i + 1; j < segs.length; j++) {
    const A = segs[i], B = segs[j];
    if (A.band[0] < B.band[1] && B.band[0] < A.band[1] && near(A, B)) root[find(i)] = find(j);
  }
  const clusters = new Map();
  segs.forEach((s, i) => { const r = find(i); if (!clusters.has(r)) clusters.set(r, []); clusters.get(r).push(s); });
  clusters.forEach(cl => placeTracks(cl, near));
  const out = E.map(e => {
    const top = e.p.y, bot = e.n.y + H, y = e.hs.map(h => h.seg.y);
    const pts = e.kind === "straight" ? [[e.xo, top], [e.xo, bot]]
      : e.kind === "gutter" ? [[e.xo, top], [e.xo, y[0]], [e.xg, y[0]], [e.xg, y[1]], [e.xi, y[1]], [e.xi, bot]]
      : [[e.xo, top], [e.xo, y[0]], [e.xi, y[0]], [e.xi, bot]];
    return { from: e.from, to: e.to, pts, dashed: e.dashed, via: e.via, count: e.count, hiddenIds: e.hiddenIds };
  });
  return { edges: out, ports };
}


// segments of lines that run through a card that is neither of their ends
function throughCards(edges, nodes, W, H) {
  let k = 0;
  edges.forEach(e => { for (let i = 1; i < e.pts.length; i++) {
    const [x1, y1] = e.pts[i - 1], [x2, y2] = e.pts[i], xa = Math.min(x1, x2), xb = Math.max(x1, x2), ya = Math.min(y1, y2), yb = Math.max(y1, y2);
    nodes.forEach(o => { if (o.id !== e.from && o.id !== e.to && xa < o.x + W - 1 && xb > o.x + 1 && ya < o.y + H - 1 && yb > o.y + 1) k++; });
  } });
  return k;
}

// Reorder lanes (lane 0 = trunk stays put) to minimise crossings, then edge length, then displacement from greedy order —
// summed over both layouts, since they share their columns. Free: a horizontal stretch through a card weighs like a crossing.
function optimizeLanes(nodes, N, laneCount, W, H, views, judge) {
  const ident = [...Array(laneCount).keys()];
  if (laneCount < 3) return ident;
  const step = W + G.gapX;
  const cost = (pos) => {
    const xOf = n => pos[n.lane] * step;
    let total = 0;
    views.forEach(v => {
      const yOf = n => v.y.get(n), { edges } = routeLegacy(nodes, N, W, H, xOf, yOf, pp => v.blocked.get(pp));
      const { cross, overlaps } = analyzeEdges(edges);
      let len = 0, hit = 0;
      edges.forEach(e => {
        len += Math.abs(e.pts[e.pts.length - 1][0] - e.pts[0][0]) / step;
        if (v.free) for (let k = 1; k < e.pts.length; k++) {
          const [x1, y1] = e.pts[k - 1], [x2, y2] = e.pts[k];
          if (y1 !== y2) continue;
          const a = Math.min(x1, x2), b = Math.max(x1, x2);
          nodes.forEach(o => { if (o.id !== e.from && o.id !== e.to) { const ox = xOf(o), oy = yOf(o); if (ox < b - 1 && ox + W > a + 1 && y1 > oy - 8 && y1 < oy + H + 8) hit++; } });
        }
      });
      total += (cross.length + overlaps + hit) * 100 + len;
    });
    let disp = 0;
    pos.forEach((p, l) => { disp += Math.abs(p - l); });
    return total + disp * 0.25;
  };
  let best = ident, bestC = cost(ident);
  const rest = ident.slice(1);
  if (rest.length <= 6) {
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
    // many lanes: local search (move one lane, or swap two) from several starts; the real router judges the best few
    const toPos = ord => { const pos = []; ord.forEach((lane, i) => { pos[lane] = i; }); return pos; };
    const local = (start) => {
      let ord = start, c = cost(toPos(ord)), improved = true;
      const tryOrd = cand => { const cc = cost(toPos(cand)); if (cc < c - 1e-9) { c = cc; ord = cand; improved = true; } };
      while (improved) {
        improved = false;
        for (let i = 1; i < laneCount; i++) for (let j = 1; j < laneCount; j++) if (i !== j) { const cand = ord.slice(), [m] = cand.splice(i, 1); cand.splice(j, 0, m); tryOrd(cand); }
        for (let i = 1; i < laneCount; i++) for (let j = i + 1; j < laneCount; j++) { const cand = ord.slice(); [cand[i], cand[j]] = [cand[j], cand[i]]; tryOrd(cand); }
      }
      return { ord, c };
    };
    const starts = [ident, [0, ...rest.slice().reverse()]];
    const seen = new Set(), found = [];
    starts.map(local).forEach(r => { const k = r.ord.join(); if (!seen.has(k)) { seen.add(k); found.push(r); } });
    found.sort((a, b) => a.c - b.c);
    const pick = judge ? found.slice(0, 4).map(r => ({ r, s: judge(toPos(r.ord)) })).sort((a, b) => a.s - b.s || a.r.c - b.r.c)[0].r : found[0];
    best = toPos(pick.ord);
  }
  return best;
}

// Free rows. T = committer time clamped to the parents (a child is never older); walk by T, parents first on ties.
// Each card sits the time gap above the commit walked before it (whatever branch) and at least one pitch above its parents.
// A collapsed stack walks as its members: it takes the newest member's place and T, and the gaps of the hidden members carry over
// to it — never recomputed from T — so collapsing never pushes anything up. Nothing here depends on the clock.
function freeRows(nodes, N) {
  const tsOf = c => c.isRoot || !c.ts ? NaN : Date.parse(c.ts);
  const lastOf = id => { const n = N.get(id); return n && n.c.isGroup ? n.c.members[n.c.members.length - 1].id : id; };
  const V = [];
  nodes.forEach(n => {
    const ps = n.parents.map(p => lastOf(p.id)), pri = n.c.priority || 0;
    if (n.c.isGroup) n.c.members.forEach((m, k, ms) => V.push({ id: m.id, node: n, ts: tsOf(m), parents: k ? [ms[k - 1].id] : ps, last: k === ms.length - 1, pri, idx: n.idx }));
    else V.push({ id: n.id, node: n, ts: tsOf(n.c), parents: ps, last: true, pri, idx: n.idx });
  });
  const VM = new Map(V.map(v => [v.id, v])), known = V.map(v => v.ts).filter(t => !isNaN(t));
  const tmin = known.length ? Math.min(...known) : 0;
  const up = v => v.parents.map(id => VM.get(id)).filter(Boolean);
  const T = v => v.T != null ? v.T : (v.T = Math.max(isNaN(v.ts) ? tmin : v.ts, ...up(v).map(T)));
  const D = v => v.d != null ? v.d : (v.d = 1 + Math.max(-1, ...up(v).map(D)));
  V.forEach(v => { T(v); D(v); });
  V.sort((a, b) => a.T - b.T || a.d - b.d || a.pri - b.pri || a.idx - b.idx);
  let prevT = null, prevU = null, acc = 0;
  V.forEach(v => {
    if (prevT != null) acc += gapUnits(v.T - prevT);
    prevT = v.T;
    if (!v.last) return;
    const n = v.node;
    n.u = Math.max(prevU == null ? 0 : prevU + acc, ...n.parents.map(p => N.get(p.id).u + U));
    n.t = v.T;
    prevU = n.u; acc = 0;
  });
}

// Free, long histories (sync #22, Story 10.31): a collapsed stack keeps its hidden members' time below it, so a long one
// leaves screens of canvas with only lines in it. Any stretch with no card in any column taller than BREAK_MIN shrinks to
// BREAK_TO (card to card) and becomes a break: a torn band naming the time it skips. Layout units, so a break never
// depends on the window; an expanded stack fills its stretch with cards and the break is gone.
const BREAK_MIN = 8 * U, BREAK_TO = 1.5 * U;
function shortenFree(nodes) {
  const byU = new Map();
  nodes.forEach(n => { const a = byU.get(n.u); a ? a.push(n) : byU.set(n.u, [n]); });
  const us = [...byU.keys()].sort((a, b) => a - b), cuts = [];
  for (let i = 1; i < us.length; i++) {
    if (us[i] - us[i - 1] <= BREAK_MIN) continue;
    const t = (u, f) => f(...byU.get(u).map(n => n.t).filter(x => x != null && !isNaN(x)));
    cuts.push({ lo: us[i - 1], hi: us[i], save: us[i] - us[i - 1] - BREAK_TO, tLo: t(us[i - 1], Math.max), tHi: t(us[i], Math.min) });
  }
  if (!cuts.length) return [];
  const shift = u => cuts.reduce((s, c) => s + (c.hi <= u ? c.save : 0), 0);
  cuts.forEach(c => { c.hiU = c.hi - shift(c.hi); });
  nodes.forEach(n => { n.u -= shift(n.u); });
  return cuts.map(c => ({ hiU: c.hiU, tLo: c.tLo, tHi: c.tHi, label: spanLabel(c.tLo, c.tHi) }));
}
// "4 years · Feb 2021 – Mar 2025" · "8 months · Jun – Dec 2025" · "3 weeks · Jun 3 – 24"
function spanLabel(t0, t1) {
  const d = (t1 - t0) / 864e5, a = new Date(t0), b = new Date(t1), M = (x) => x.toLocaleDateString("en-US", { month: "short" });
  const len = d >= 548 ? Math.round(d / 365) + " years" : d >= 60 ? Math.round(d / 30.4) + " months" : d >= 14 ? Math.round(d / 7) + " weeks" : Math.max(1, Math.round(d)) + " days";
  const range = a.getFullYear() !== b.getFullYear() ? `${M(a)} ${a.getFullYear()} – ${M(b)} ${b.getFullYear()}`
    : a.getMonth() !== b.getMonth() ? `${M(a)} – ${M(b)} ${b.getFullYear()}` : `${M(a)} ${a.getDate()} – ${b.getDate()}`;
  return len + " · " + range;
}

function routeAll(nodes, N, W, H, route, free) {
  const R = route === "A" ? routeLegacy(nodes, N, W, H) : routeLines(nodes, N, W, H, { bus: route === "C", free });
  const { cross } = analyzeEdges(R.edges), cuts = placeCuts(R.edges, cross);
  const edges = R.edges.map((e, i) => ({ ...e, d: roundedPath(e.pts, 10), cuts: cuts[i] }));
  const markers = window.placeGapMarkers(R.edges);
  // missing-parent stubs: centred when the card has no other parent edge, otherwise beside its entries so they never sit on a real edge
  const stubs = [];
  nodes.forEach(n => {
    if (!n.missing.length) return;
    const used = R.ports ? [...(R.ports.get(n.id) || [])] : n.parents.length ? [n.cx] : [];
    const cand = (n.parents.length ? [0.28, -0.28, 0.14, -0.14, 0.4, -0.4] : [0, 0.28, -0.28, 0.14, -0.14]).map(f => n.cx + f * W);
    n.missing.forEach((m, k) => {
      const x = cand.find(c => used.every(u => Math.abs(u - c) >= 14)) ?? cand[k] ?? n.cx;
      used.push(x);
      stubs.push({ kind: "end", key: n.id + "~" + m.via, node: n.id, x, y: n.y + H, ...m });
    });
  });
  return { edges, markers, stubs, crossings: cross.length };
}

function computeLayout(all, revset, W, H, mode = "free", opts = {}) {
  const free = mode !== "compact";
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
  // rows in both layouts — they share their columns, so switching layouts only moves cards up and down (same width, same order)
  freeRows(nodes, N);
  const breaks = shortenFree(nodes);
  const rowOf = (n) => n.rowC != null ? n.rowC : (n.rowC = n.parents.length ? Math.max(...n.parents.map(p => rowOf(N.get(p.id)))) + 1 : 0);
  nodes.forEach(n => { n.uF = n.u; n.uC = U * rowOf(n); });
  const M = [n => n.uF, n => n.uC];
  nodes.forEach(n => {
    const cont = n.children.map(id => N.get(id)).filter(ch => ch.parents[0].id === n.id).sort((a, b) => (a.c.priority || 0) - (b.c.priority || 0) || a.idx - b.idx)[0];
    n.cont = cont ? cont.id : null;
  });

  // lanes: greedy interval packing — a lane holds a chain from one pitch above its first parent to its last child (+ one pitch buffer).
  // Lifetime = the first-parent child expected to continue the lane + merge children (routed up this lane).
  // Two chains share a lane only if they are apart in both layouts. Packed in Compact order and in Free order; fewer lanes win.
  const pack = (key) => {
    const order = [...nodes].sort((a, b) => key(a) - key(b) || (a.c.priority || 0) - (b.c.priority || 0) || a.idx - b.idx);
    const lanes = [], lane = new Map();
    const fits = (L, iv, allow) => !(lanes[L] || []).some(o => o.owner !== allow && M.some((m, k) => o.a[k] < iv.b[k] && iv.a[k] < o.b[k]));
    order.forEach(n => {
      const fp = n.parents[0] ? N.get(n.parents[0].id) : null;
      const kids = n.children.map(id => N.get(id)).filter(ch => ch.id === n.cont || ch.parents.findIndex(p => p.id === n.id) > 0);
      const iv = { owner: n.id, a: [], b: [] };
      M.forEach((m, k) => { iv.a[k] = fp ? m(fp) + U : m(n); iv.b[k] = (kids.length ? Math.max(m(n), Math.max(...kids.map(m)) - U) : m(n)) + 2 * U; });
      let L;
      if (fp && fp.cont === n.id && fits(lane.get(fp), iv, fp.id)) L = lane.get(fp);
      else { L = 0; while (!fits(L, iv, null)) L++; }
      (lanes[L] = lanes[L] || []).push(iv); lane.set(n, L);
    });
    return { lane, count: Math.max(1, lanes.length) };
  };
  // exact colouring of whole chains (a chain = a node and the children continuing its lane) — few chains, capped search; wins only if it saves a lane
  const exact = () => {
    const heads = nodes.filter(n => { const fp = n.parents[0] && N.get(n.parents[0].id); return !fp || fp.cont !== n.id; });
    if (heads.length > 40) return null;
    const ch = heads.map(h => { const ns = [h]; for (let x = h; x.cont && N.get(x.cont);) { x = N.get(x.cont); ns.push(x); } return ns; });
    const iv = ch.map(ns => M.map(m => {
      let a = Infinity, b = -Infinity;
      ns.forEach(n => { const fp = n.parents[0] && N.get(n.parents[0].id), kids = n.children.map(id => N.get(id)).filter(c => c.id === n.cont || c.parents.findIndex(p => p.id === n.id) > 0);
        a = Math.min(a, fp ? m(fp) + U : m(n)); b = Math.max(b, (kids.length ? Math.max(m(n), Math.max(...kids.map(m)) - U) : m(n)) + 2 * U); });
      return [a, b];
    }));
    const k = ch.length, adj = ch.map((_, i) => ch.map((_, j) => i !== j && [0, 1].some(t => iv[i][t][0] < iv[j][t][1] && iv[j][t][0] < iv[i][t][1])));
    const ord = [...Array(k).keys()].sort((i, j) => adj[j].filter(Boolean).length - adj[i].filter(Boolean).length);
    let steps = 0;
    for (let c = 1; c <= k; c++) {
      const col = new Array(k).fill(-1);
      const go = t => { if (t === k) return true; if (++steps > 20000) return false; const i = ord[t];
        for (let x = 0; x < c; x++) { if (col.some((y, j) => y === x && adj[i][j])) continue; col[i] = x; if (go(t + 1)) return true; col[i] = -1; if (x > Math.max(...col)) break; }
        return false; };
      if (go(0)) {
        const first = (ns) => Math.min(...ns.map(n => n.uC)), trunk = ch.findIndex(ns => ns.includes([...nodes].sort((a, b) => a.uC - b.uC || (a.c.priority || 0) - (b.c.priority || 0) || a.idx - b.idx)[0]));
        const colors = [...new Set(col)].sort((x, y) => (x === col[trunk] ? -1 : y === col[trunk] ? 1 : Math.min(...ch.filter((_, i) => col[i] === x).map(first)) - Math.min(...ch.filter((_, i) => col[i] === y).map(first))));
        const lane = new Map(); ch.forEach((ns, i) => ns.forEach(n => lane.set(n, colors.indexOf(col[i]))));
        return { lane, count: c };
      }
      if (steps > 20000) return null;
    }
    return null;
  };
  const pitch = H + G.gapY;
  // columns don't depend on the layout, so switching Free ↔ Compact reuses them
  const choose = () => {
    let cands = [pack(M[1]), pack(M[0])];
    if (Math.min(...cands.map(c => c.count)) > 2) { const X = exact(); if (X) cands.push(X); }
    const fewest = Math.min(...cands.map(c => c.count));
    cands = cands.filter(c => c.count === fewest).filter((c, i, a) => a.findIndex(d => nodes.every(n => d.lane.get(n) === c.lane.get(n))) === i);
    const laneCount = fewest;
    const view = (m, isFree) => {
      const top = Math.max(0, ...nodes.map(m)), y = new Map(), blocked = new Map();
      nodes.forEach(n => { y.set(n, G.pad + (top - m(n)) / U * pitch); });
      nodes.forEach(n => n.parents.forEach(pp => { const p = N.get(pp.id); blocked.set(pp, nodes.some(o => o.lane === p.lane && m(o) > m(p) && m(o) <= m(n))); }));
      return { y, blocked, free: isFree };
    };
    // the real router's verdict on a column order, in both layouts: crossings and lines through cards weigh 100, then line length
    const judge = (pos) => {
      let sc = 0;
      [true, false].forEach(fr => {
        const m = fr ? M[0] : M[1], top = Math.max(0, ...nodes.map(m));
        nodes.forEach(n => { n.u = m(n); n.col = pos[n.lane]; n.y = G.pad + (top - n.u) / U * pitch; n.x = G.pad + n.col * (W + G.gapX); n.cx = n.x + W / 2; });
        nodes.forEach(n => n.parents.forEach(pp => { const p = N.get(pp.id); pp.blocked = nodes.some(o => o.col === p.col && o.u > p.u && o.u <= n.u); }));
        const { edges } = routeLines(nodes, N, W, H, { free: fr });
        sc += analyzeEdges(edges).cross.length * 100 + throughCards(edges, nodes, W, H) * 100;
        edges.forEach(e => { sc += Math.abs(e.pts[e.pts.length - 1][0] - e.pts[0][0]) / (W + G.gapX); });
      });
      return sc;
    };
    // opts.cols: columns frozen from the collapsed graph, so expanding a stack only moves cards vertically — valid in both layouts or not at all
    let frozen = false;
    if (opts.cols) {
      const cs = nodes.map(n => opts.cols.get(n.c.isGroup ? n.c.members[0].id : n.id)), ix = new Map(nodes.map((n, i) => [n, i]));
      const okIn = m => !nodes.some((a, i) => nodes.some((b, j) => j > i && cs[i] === cs[j] && Math.abs(m(a) - m(b)) < U))
        && !nodes.some((n, i) => n.parents.some(pp => { const p = N.get(pp.id), pc = cs[ix.get(p)];
          return pc === cs[i] && nodes.some((o, k) => cs[k] === pc && m(o) > m(p) && m(o) < m(n)); }));
      frozen = cs.every(v => v != null) && M.every(okIn);
      if (frozen) nodes.forEach((n, i) => { n.col = cs[i]; n.lane = cands[0].lane.get(n); });
    }
    if (!frozen) {
      // every packing with the fewest lanes gets its best order; the real router picks the winner
      let win = null;
      cands.forEach(P => {
        nodes.forEach(n => { n.lane = P.lane.get(n); });
        const pos = opts.optimize ? optimizeLanes(nodes, N, laneCount, W, H, [view(M[0], true), view(M[1], false)], judge) : [...Array(laneCount).keys()];
        const sc = opts.optimize && cands.length > 1 ? judge(pos) : 0;
        if (!win || sc < win.sc) win = { P, pos, sc };
      });
      nodes.forEach(n => { n.lane = win.P.lane.get(n); n.col = win.pos[n.lane]; });
    }
  };
  const ck = [revset, W, H, opts.optimize ? 1 : 0, opts.cols ? [...opts.cols].map(e => e.join(":")).join() : ""].join("|");
  let memo = colMemo.get(all);
  if (!memo) colMemo.set(all, (memo = new Map()));
  const hit = memo.get(ck);
  if (hit && nodes.every(n => hit.has(n.id))) nodes.forEach(n => { [n.lane, n.col] = hit.get(n.id); });
  else { choose(); memo.set(ck, new Map(nodes.map(n => [n.id, [n.lane, n.col]]))); }

  // this layout's rows
  nodes.forEach(n => { n.u = free ? n.uF : n.uC; n.row = n.u / U; });
  const maxU = Math.max(0, ...nodes.map(n => n.u));
  const botExtra = nodes.some(n => n.missing.length && n.u < U) ? G.elide : 0;
  nodes.forEach(n => { n.y = G.pad + (maxU - n.u) / U * pitch; n.x = G.pad + n.col * (W + G.gapX); n.cx = n.x + W / 2; });
  nodes.forEach(n => n.parents.forEach(pp => { const p = N.get(pp.id); pp.blocked = nodes.some(o => o.col === p.col && o.u > p.u && o.u <= n.u); }));
  const colCount = Math.max(1, ...nodes.map(n => n.col + 1));
  const R = routeAll(nodes, N, W, H, opts.route || "B", free);

  // Free: day axis — a dashed divider between two local calendar days (by clamped T); each day's label sits on the divider below its
  // first commit, at the left edge. Days never interleave in Free, so the band around a divider holds no cards — the label needs no gutter.
  const days = [], years = [];
  // breaks (sync #22): the band between the upper card's bottom and the lower card's top; a day divider inside it is the break
  const bands = free ? breaks.map((b, i) => { const top = G.pad + (maxU - b.hiU) / U * pitch; return { key: "brk" + i, top: top + H, bottom: top + BREAK_TO / U * pitch, label: b.label }; }) : [];
  const inBand = (y) => bands.some(b => y > b.top - 1 && y < b.bottom + 1);
  if (free) {
    const by = new Map(), root = nodes.find(n => n.c.isRoot);
    nodes.forEach(n => {
      if (n.c.isRoot) return;
      const b = dayBucket(n.t), d = by.get(b.key);
      if (!d) by.set(b.key, { ...b, lo: n, hi: n });
      else { if (n.u < d.lo.u) d.lo = n; if (n.u > d.hi.u) d.hi = n; }
    });
    let prev = null, lastY = Infinity;
    [...by.values()].sort((a, b) => a.key - b.key).forEach(d => {
      const floor = prev ? prev.hi.y : root ? root.y : d.lo.y + H + G.gapY, g = (floor + d.lo.y + H) / 2, y = Math.min(g, lastY - 22);
      // a year boundary at this divider (or the oldest day): year = the year above (the canvas pairs it with that day's label,
      // read upward like the day labels), below = the year under it (the minimap's section header, read downward)
      // inside a break the band's own label names both ends, so the canvas shows no year there
      if (!prev || prev.year !== d.year) years.push({ key: "y" + d.year, year: d.year, below: prev ? prev.year : null, inBand: !!prev && inBand(g), y: prev && inBand(g) ? bands.find(b => g > b.top - 1 && g < b.bottom + 1).top : y });
      if (!(prev && inBand(g))) days.push({ key: d.key, label: d.label, y, guide: prev ? g : null });
      prev = d; lastY = y;
    });
  }

  return {
    nodes, N, ...R, days, years, bands, offX: 0, mode: free ? "free" : "compact",
    width: G.pad * 2 + colCount * (W + G.gapX) - G.gapX,
    height: G.pad * 2 + botExtra + maxU / U * pitch + H,
    total: all.length, shown: list.length,
  };
}
// same cards, other lines (study): route "A" | "B" | "C"
const reroute = (L, W, H, route) => routeAll(L.nodes, L.N, W, H, route, L.mode === "free");

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

window.GraphLayout = { G, DENSITY, U, CUT_CLEAR, gapUnits, dayBucket, roundedPath, analyzeEdges, reroute };
Object.assign(window, { computeLayout, groupStacks });
})();
