// Graph layout for the UI kit — a port of the floating client's engine (graph-layout.jsx), trimmed to what the kit's data needs.
// Rows: Free (default) — commits close in time stand close together across branches; gaps grow with the time between commits,
//   log-damped and capped at 3 pitches; an edge is always at least one pitch long. Compact — rows = generation depth.
// Columns: shared by both layouts (the data's lanes when they hold in both, else greedy packing), so switching only moves cards up and down.
// Lines: one per parent → child pair — own exits/entries (GraphPorts), tracks that nest, gutter detours, bridges.
// Days (Free only): a dashed divider between calendar days; each day's label sits on the divider below that day's first commit.
(() => {
const G = { gapX: 56, gapY: 48, padT: 92, padL: 100, padR: 180, padB: 110 };
const U = 16, CUT_CLEAR = 12;
const ports = () => window.ZanshinDesignSystem_a33847.GraphPorts;

// Free: time gap (ms) → units (1/16 pitch); piecewise-linear log2, integers only, capped at 3 pitches
function gapUnits(g) {
  const x = 1 + Math.floor(Math.max(0, g) / 60000);
  let k = 0; while (2 ** (k + 1) <= x) k++;
  const l2 = 256 * k + Math.floor(((x - 2 ** k) * 256) / 2 ** k);
  return Math.min(48, Math.floor((2 * l2) / 256));
}

function rows(nodes, by, now) {
  const tsOf = (c) => now - (c.t || 0) * 60000;
  const lastOf = (id) => { const n = by.get(id); return n && n.stack ? n.members[n.members.length - 1].id : id; };
  const V = [];
  nodes.forEach((n) => {
    const ps = n.ps.map(lastOf);
    if (n.stack) n.members.forEach((m, k, ms) => V.push({ id: m.id, node: n, ts: tsOf(m), parents: k ? [ms[k - 1].id] : ps, last: k === ms.length - 1, idx: n.idx }));
    else V.push({ id: n.id, node: n, ts: tsOf(n), parents: ps, last: true, idx: n.idx });
  });
  const VM = new Map(V.map((v) => [v.id, v]));
  const up = (v) => v.parents.map((id) => VM.get(id)).filter(Boolean);
  const T = (v) => (v.T != null ? v.T : (v.T = Math.max(v.ts, ...up(v).map(T))));
  const D = (v) => (v.d != null ? v.d : (v.d = 1 + Math.max(-1, ...up(v).map(D))));
  V.forEach((v) => { T(v); D(v); });
  V.sort((a, b) => a.T - b.T || a.d - b.d || a.idx - b.idx);
  let prevT = null, prevU = null, acc = 0;
  V.forEach((v) => {
    if (prevT != null) acc += gapUnits(v.T - prevT);
    prevT = v.T;
    if (!v.last) return;
    const n = v.node;
    n.uF = Math.max(prevU == null ? 0 : prevU + acc, ...n.ps.map((p) => by.get(p).uF + U));
    n.T = v.T; prevU = n.uF; acc = 0;
  });
  const rowOf = (n) => (n.rc != null ? n.rc : (n.rc = n.ps.length ? Math.max(...n.ps.map((p) => rowOf(by.get(p)))) + 1 : 0));
  nodes.forEach((n) => { n.uC = U * rowOf(n); });
}

// columns don't depend on the layout: the data's lanes if no two cards of a lane come closer than a pitch and no card of a lane sits
// between a parent and its child in that lane — in both layouts; otherwise greedy interval packing over both layouts
function columns(nodes, by) {
  const M = [(n) => n.uF, (n) => n.uC];
  const holds = M.every((m) => nodes.every((a) => !nodes.some((b) => a !== b && a.lane === b.lane && Math.abs(m(a) - m(b)) < U))
    && nodes.every((n) => n.ps.every((pid) => { const p = by.get(pid); return p.lane !== n.lane || !nodes.some((o) => o.lane === p.lane && m(o) > m(p) && m(o) < m(n)); })));
  if (holds) {
    const ls = [...new Set(nodes.map((n) => n.lane))].sort((a, b) => a - b);
    nodes.forEach((n) => { n.col = ls.indexOf(n.lane); });
    return ls.length;
  }
  const kidsOf = new Map(nodes.map((n) => [n.id, []]));
  nodes.forEach((n) => n.ps.forEach((p, i) => kidsOf.get(p).push({ n, i })));
  // the lane continues with the oldest first-parent child — a new change forks off instead of pushing the existing line aside
  nodes.forEach((n) => { const c = kidsOf.get(n.id).filter((k) => k.i === 0).map((k) => k.n).sort((a, b) => a.T - b.T || a.idx - b.idx)[0]; n.cont = c ? c.id : null; });
  const lanes = [], lane = new Map();
  const fits = (L, iv, allow) => !(lanes[L] || []).some((o) => o.owner !== allow && M.some((m, k) => o.a[k] < iv.b[k] && iv.a[k] < o.b[k]));
  [...nodes].sort((a, b) => a.uC - b.uC || a.lane - b.lane || a.idx - b.idx).forEach((n) => {
    const fp = n.ps[0] ? by.get(n.ps[0]) : null;
    const kids = kidsOf.get(n.id).filter((k) => k.n.id === n.cont || k.i > 0).map((k) => k.n);
    const iv = { owner: n.id, a: [], b: [] };
    M.forEach((m, k) => { iv.a[k] = fp ? m(fp) + U : m(n); iv.b[k] = (kids.length ? Math.max(m(n), Math.max(...kids.map(m)) - U) : m(n)) + 2 * U; });
    let L;
    if (fp && fp.cont === n.id && fits(lane.get(fp), iv, fp.id)) L = lane.get(fp);
    else { L = 0; while (!fits(L, iv, null)) L++; }
    (lanes[L] = lanes[L] || []).push(iv); lane.set(n, L);
  });
  nodes.forEach((n) => { n.col = lane.get(n); });
  return Math.max(1, lanes.length);
}

// horizontal stretches that share room → tracks: if A spans a down-exit of B, A runs above B; if B spans an up-exit of A, too
function assignTracks(segs) {
  const n = segs.length, inside = (s, x) => x > s.a + 0.5 && x < s.b - 0.5, pred = segs.map(() => new Set());
  for (let i = 0; i < n; i++) for (let j = 0; j < n; j++) {
    if (i !== j && (segs[j].down.some((x) => inside(segs[i], x)) || segs[i].up.some((x) => inside(segs[j], x)))) pred[j].add(i);
  }
  for (let i = 0; i < n; i++) [...pred[i]].forEach((j) => { if (pred[j].has(i)) { pred[i].delete(j); pred[j].delete(i); } }); // unavoidable crossing
  const done = new Set(), order = [];
  while (order.length < n) {
    let pick = -1, best = Infinity;
    for (let i = 0; i < n; i++) if (!done.has(i)) {
      let open = 0; pred[i].forEach((k) => { if (!done.has(k)) open++; });
      const key = open * 1e5 - (segs[i].b - segs[i].a);
      if (key < best) { best = key; pick = i; }
    }
    done.add(pick); order.push(pick);
  }
  const pos = new Map(order.map((i, k) => [i, k])), track = new Array(n).fill(0), rws = [];
  order.forEach((i) => {
    let t = 0;
    pred[i].forEach((k) => { if (pos.get(k) < pos.get(i)) t = Math.max(t, track[k] + 1); });
    while ((rws[t] || []).some((k) => segs[k].a < segs[i].b + 10 && segs[i].a < segs[k].b + 10)) t++;
    (rws[t] = rws[t] || []).push(i); track[i] = t;
  });
  return { track, count: Math.max(1, rws.length) };
}
// tracks of one cluster → heights: in order, 3.5–6px apart, each inside its own free range, the block centred
function placeTracks(segs, near) {
  const { track, count } = assignTracks(segs);
  const ord = [...segs.keys()].sort((i, j) => track[i] - track[j]);
  const pack = (sp) => {
    const top = [], bot = [];
    ord.forEach((i) => { top[i] = segs[i].lo; ord.forEach((j) => { if (track[j] < track[i] && near(segs[i], segs[j])) top[i] = Math.max(top[i], top[j] + sp); }); });
    [...ord].reverse().forEach((i) => { bot[i] = segs[i].hi; ord.forEach((j) => { if (track[j] > track[i] && near(segs[i], segs[j])) bot[i] = Math.min(bot[i], bot[j] - sp); }); });
    return { top, bot, ok: ord.every((i) => top[i] <= bot[i] + 0.01) };
  };
  const sp0 = ports().trackSpacing(count);
  let P = pack(sp0);
  if (!P.ok && sp0 > 3.5) P = pack(3.5);
  if (P.ok) { segs.forEach((s, i) => { s.y = P.top[i] + 0.5 * (P.bot[i] - P.top[i]); }); return; }
  const mid = segs.reduce((a, s) => a + (s.lo + s.hi) / 2, 0) / segs.length, ys = segs.map((s, i) => P.top[i]);
  const shift = mid - (Math.min(...ys) + Math.max(...ys)) / 2;
  segs.forEach((s, i) => { s.y = ys[i] + shift; });
}

// one line per parent → child pair. fork: turns above the parent, climbs the child's lane · merge1: one pitch apart ·
// mergeUp: climbs the parent's free lane, turns below the child · gutter: lane taken (or, in Free, a card in the way)
function route(nodes, by, W, H, free) {
  const GP = ports(), GY = G.gapY, colW = W + G.gapX, E = [];
  nodes.forEach((n) => n.ps.forEach((pid, i) => E.push({ p: by.get(pid), n, i, from: pid, to: n.id, dashed: n.gapParents.includes(pid) })));
  const cols = new Map();
  nodes.forEach((o) => { if (!cols.has(o.col)) cols.set(o.col, []); cols.get(o.col).push(o); });
  const colFree = (col, u0, u1) => !(cols.get(col) || []).some((o) => o.u > u0 && o.u < u1);
  const pBand = (p) => [p.y - GY, p.y], nBand = (n) => [n.y + H, n.y + H + GY];
  const room = (band, a, b) => {
    let ivs = [[band[0] + 12, band[1] - 12]];
    if (free) nodes.forEach((o) => {
      if (o.x >= b + 4 || o.x + W <= a - 4) return;
      const c0 = o.y - 10, c1 = o.y + H + 10;
      ivs = ivs.flatMap(([l, h]) => (c1 <= l || c0 >= h ? [[l, h]] : [[l, c0], [c1, h]].filter(([x, y]) => y >= x)));
    });
    return ivs;
  };
  const clear = (band, x0, x1) => room(band, Math.min(x0, x1), Math.max(x0, x1)).length > 0;
  const gutterXs = (e) => { const k = Math.abs(e.n.col - e.p.col); return k ? [...Array(k).keys()].map((j) => e.n.cx - e.side * colW * (j + 0.5)) : [e.n.cx + (e.side * colW) / 2]; };
  E.forEach((e) => {
    const { p, n } = e;
    e.side = Math.sign(n.cx - p.cx);
    let kind = !e.side ? (e.i === 0 && colFree(p.col, p.u, n.u) ? "straight" : "gutter")
      : e.i === 0 ? (colFree(n.col, p.u, n.u) ? "fork" : "gutter")
      : n.u === p.u + U ? "merge1" : colFree(p.col, p.u, n.u) ? "mergeUp" : "gutter";
    if (!e.side) e.side = 1;
    const direct = kind === "mergeUp" ? clear(nBand(n), p.cx, n.cx) : kind === "fork" || kind === "merge1" ? clear(pBand(p), p.cx, n.cx) : true;
    if (kind === "gutter" || !direct) {
      const xs = gutterXs(e), x = xs.find((g) => clear(pBand(p), p.cx, g) && clear(nBand(n), g, n.cx));
      if (kind === "gutter" || x != null) { kind = "gutter"; e.gx = x != null ? x : xs[0]; }
    }
    e.kind = kind;
  });
  const gut = new Map();
  E.filter((e) => e.kind === "gutter").forEach((e) => { const k = gut.get(e.gx) || 0; gut.set(e.gx, k + 1); e.xg = e.gx + (k ? (k % 2 ? 6 : -6) * Math.ceil(k / 2) : 0); });
  // entry slots (router.dart): ≥ 2 dashed lines into a single-parent change (not a stack) share the first one's port
  const single = (n) => !n.stack && (n.realParents ?? n.parents.length + n.gapParents.length) === 1;
  nodes.forEach((n) => { const d = E.filter((e) => e.n === n && e.dashed); if (single(n) && d.length > 1) d.forEach((e) => { e.slot = d[0]; }); });
  // entries, per slot owner: a lone or the straight one in the centre (none straight: the centre stays free), every other beside
  // it — the farther the parent, the farther out; an approach right above the centre counts as the right side
  const approach = (e) => (e.kind === "gutter" ? e.xg : e.p.cx), used = new Map();
  nodes.forEach((n) => {
    const ins = E.filter((e) => e.n === n), owners = ins.filter((e) => !e.slot || e.slot === e);
    const centre = owners.length === 1 ? owners[0] : owners.find((e) => e.kind === "straight");
    if (centre) centre.xi = n.cx;
    [-1, 1].forEach((s) => {
      const list = owners.filter((e) => e !== centre && (approach(e) < n.cx ? -1 : 1) === s).sort((a, b) => Math.abs(approach(a) - n.cx) - Math.abs(approach(b) - n.cx) || a.p.u - b.p.u);
      const xs = GP.entries(list.length, W);
      list.forEach((e, k) => { e.xi = n.cx + s * xs[k]; });
    });
    ins.forEach((e) => { if (e.slot) e.xi = e.slot.xi; });
    used.set(n.id, [...new Set(ins.map((e) => e.xi))]);
  });
  // exits, as the entries: a lone line (not a merge-up) or the straight one in the centre, the rest per side — lines climbing the
  // parent's own lane innermost (MERGE_UP_SHIFT outside their slot), then by how far they turn; the width decides the spacing
  nodes.forEach((p) => {
    const outs = E.filter((e) => e.p === p);
    if (outs.length === 1 && outs[0].kind !== "mergeUp") { outs[0].xo = p.cx; return; }
    outs.forEach((e) => { if (e.kind === "straight") e.xo = p.cx; });
    [-1, 1].forEach((s) => {
      const side = outs.filter((e) => e.kind !== "straight" && e.side === s);
      if (!side.length) return;
      const turn = (e) => (e.kind === "gutter" ? e.xg : e.xi);
      const upL = side.filter((e) => e.kind === "mergeUp").sort((a, b) => b.n.u - a.n.u || Math.abs(a.xi - p.cx) - Math.abs(b.xi - p.cx));
      const rest = side.filter((e) => e.kind !== "mergeUp").sort((a, b) => Math.abs(turn(a) - p.cx) - Math.abs(turn(b) - p.cx));
      const list = [...upL, ...rest], xs = GP.exits(list.length, W);
      list.forEach((e, k) => { e.xo = p.cx + s * (xs[k] + (k < upL.length ? GP.MERGE_UP_SHIFT : 0)); });
    });
  });
  E.forEach((e) => {
    const { p, n } = e;
    e.hs = e.kind === "straight" ? [] : e.kind === "mergeUp" ? [{ band: nBand(n), d: e.xo, u: e.xi }]
      : e.kind === "gutter" ? [{ band: pBand(p), d: e.xo, u: e.xg }, { band: nBand(n), d: e.xg, u: e.xi }] : [{ band: pBand(p), d: e.xo, u: e.xi }];
  });
  const segs = [];
  E.forEach((e) => e.hs.forEach((h) => { const s = { down: [h.d], up: [h.u], band: h.band }; segs.push(s); h.seg = s; }));
  segs.forEach((s) => {
    const xs = [...s.down, ...s.up], mid = (s.band[0] + s.band[1]) / 2;
    s.a = Math.min(...xs); s.b = Math.max(...xs);
    let best = null, bd = Infinity;
    room(s.band, s.a, s.b).forEach(([l, h]) => { const d = mid < l ? l - mid : mid > h ? mid - h : 0; if (d < bd) { bd = d; best = [l, h]; } });
    [s.lo, s.hi] = best || [mid, mid];
  });
  const near = (A, B) => A.a < B.b + 10 && B.a < A.b + 10;
  const root = segs.map((_, i) => i), find = (i) => (root[i] === i ? i : (root[i] = find(root[i])));
  for (let i = 0; i < segs.length; i++) for (let j = i + 1; j < segs.length; j++) {
    const A = segs[i], B = segs[j];
    if (A.band[0] < B.band[1] && B.band[0] < A.band[1] && near(A, B)) root[find(i)] = find(j);
  }
  const clusters = new Map();
  segs.forEach((s, i) => { const r = find(i); if (!clusters.has(r)) clusters.set(r, []); clusters.get(r).push(s); });
  clusters.forEach((cl) => placeTracks(cl, near));
  const edges = E.map((e) => {
    const top = e.p.y, bot = e.n.y + H, y = e.hs.map((h) => h.seg.y);
    const pts = e.kind === "straight" ? [[e.xo, top], [e.xo, bot]]
      : e.kind === "gutter" ? [[e.xo, top], [e.xo, y[0]], [e.xg, y[0]], [e.xg, y[1]], [e.xi, y[1]], [e.xi, bot]]
      : [[e.xo, top], [e.xo, y[0]], [e.xi, y[0]], [e.xi, bot]];
    return { key: e.from + ">" + e.to, from: e.from, to: e.to, pts, dashed: e.dashed, cuts: [] };
  });
  // bridges: the horizontal line breaks where it passes a vertical one — unless that would sit closer than 12px to a bend or card
  const segsOf = (e) => { const s = []; for (let i = 1; i < e.pts.length; i++) { const [x1, y1] = e.pts[i - 1], [x2, y2] = e.pts[i]; if (x1 === x2 && y1 === y2) continue; s.push(y1 === y2 ? { h: true, c: y1, a: Math.min(x1, x2), b: Math.max(x1, x2) } : { h: false, c: x1, a: Math.min(y1, y2), b: Math.max(y1, y2) }); } return s; };
  const S = edges.map(segsOf);
  for (let i = 0; i < edges.length; i++) for (let j = i + 1; j < edges.length; j++) {
    const A = edges[i], B = edges[j];
    if (A.from === B.from || A.to === B.to || A.from === B.to || A.to === B.from) continue;
    S[i].forEach((s) => S[j].forEach((t) => {
      if (s.h === t.h) return;
      const [h, v, hi, vi] = s.h ? [s, t, i, j] : [t, s, j, i];
      if (!(v.c > h.a + 1 && v.c < h.b - 1 && h.c > v.a + 1 && h.c < v.b - 1)) return;
      const hRoom = Math.min(v.c - 6 - h.a, h.b - v.c - 6), vRoom = Math.min(h.c - 6 - v.a, v.b - h.c - 6);
      if (hRoom < CUT_CLEAR && vRoom > hRoom) edges[vi].cuts.push(GP.bridge(v.c, h.c, "v"));
      else edges[hi].cuts.push(GP.bridge(v.c, h.c, "h"));
    }));
  }
  return { edges, used };
}

const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
function dayOf(t, now) {
  const d0 = (x) => { const d = new Date(x); d.setHours(0, 0, 0, 0); return d.getTime(); };
  const key = d0(t), today = d0(now), d = new Date(key);
  return { key, label: key >= today ? "Today" : key === d0(today - 3600000) ? "Yesterday" : MONTHS[d.getMonth()] + " " + d.getDate() + (d.getFullYear() !== new Date(now).getFullYear() ? ", " + d.getFullYear() : "") };
}

// nodes: folded changes ({ id, parents, gapParents, lane, t (minutes ago), stack, members, endBelow }) · mode "free" | "compact"
function zkLayout(nodes0, W, H, mode = "free") {
  const now = Date.parse((window.ZK_DATA && window.ZK_DATA.now) || Date.now()), free = mode !== "compact";
  const nodes = nodes0.map((c, idx) => ({ ...c, idx }));
  const by = new Map(nodes.map((n) => [n.id, n]));
  nodes.forEach((n) => { n.ps = [...n.parents, ...n.gapParents].filter((p) => by.has(p)); });
  rows(nodes, by, now);
  const colCount = columns(nodes, by);
  const pitch = H + G.gapY;
  nodes.forEach((n) => { n.u = free ? n.uF : n.uC; });
  const maxU = Math.max(0, ...nodes.map((n) => n.u));
  nodes.forEach((n) => { n.y = G.padT + ((maxU - n.u) / U) * pitch; n.x = G.padL + n.col * (W + G.gapX); n.cx = n.x + W / 2; });
  const R = route(nodes, by, W, H, free);
  // end of history: centred when the card has no other parent line, otherwise beside its entries so it never sits on a real line
  const ends = nodes.filter((n) => n.endBelow).map((n) => {
    const taken = R.used.get(n.id) || [];
    const cand = (n.ps.length ? [0.28, -0.28, 0.14, -0.14, 0.4, -0.4] : [0, 0.28, -0.28]).map((f) => n.cx + f * W);
    return { key: "end" + n.id, id: n.id, x: cand.find((c) => taken.every((u) => Math.abs(u - c) >= 14)) ?? n.cx, y: n.y + H };
  });
  // days (Free): divider midway between the top of the previous day's newest card and the bottom of this day's oldest card
  const days = [];
  if (free) {
    const g = new Map();
    nodes.forEach((n) => { const b = dayOf(n.T, now), d = g.get(b.key); if (!d) g.set(b.key, { ...b, lo: n, hi: n }); else { if (n.u < d.lo.u) d.lo = n; if (n.u > d.hi.u) d.hi = n; } });
    let prev = null, lastY = Infinity;
    [...g.values()].sort((a, b) => a.key - b.key).forEach((d) => {
      const floor = prev ? prev.hi.y : d.lo.y + H + G.gapY, mid = (floor + d.lo.y + H) / 2, y = Math.min(mid, lastY - 22);
      days.push({ key: d.key, label: d.label, y, guide: prev ? mid : null });
      prev = d; lastY = y;
    });
  }
  return {
    mode: free ? "free" : "compact", nodes, edges: R.edges, ends, days,
    pos: new Map(nodes.map((n) => [n.id, { x: n.x, y: n.y }])),
    width: G.padL + colCount * (W + G.gapX) - G.gapX + G.padR,
    height: G.padT + (maxU / U) * pitch + H + G.padB,
  };
}

Object.assign(window, { ZK_G: G, zkLayout, zkDayOf: dayOf });
})();
