// Throwaway spike viewer for spikes/graph-layout-ab: paints the layout outputs of every mode ×
// lane order the way the 2026-09-26 design draws them (graph-view.jsx), on real data.
//
// Painter model (what the Flutter view would do too):
// - geometry (x, y per node; edge polylines) is derived from the layout's grid output and the card
//   size only, so the scroll extents are exact before anything is painted;
// - a canvas behind a transparent scroll layer paints the background, the time guides and the
//   edges of the viewport only (edges are found through an index sorted by their upper end);
// - DOM cards exist only for nodes in the viewport ± MARGIN, found by binary search over the
//   nodes sorted by y;
// - crossing gaps ("bridges") are computed only between edges that intersect the viewport;
// - "Time+gaps" is Time's rows plus inter-bucket gaps sized by elapsed time, as prefix sums over
//   the Time output's buckets (SPEC §0: painter-side, no layout mode).
// - Free has a day gutter too: one label per local day of the layout's clamped time (y is monotone
//   in it), "Today" / "Yesterday" / date relative to the bundle's now_ms.
// - Go to commit: search box → instant jump (no smooth scroll) + pulse. A jump costs the same at
//   any distance: the viewport is a pure function of the scroll offset (binary search + visible).
// - Minimap: rasterised ONCE per layout into an ImageData (difference arrays → O(n + E + pixels)),
//   the viewport rectangle is a DOM overlay moved by transform on scroll.
//
// URL params: ?dataset=&mode=&order=&minimap=0|1 (override the stored UI), ?lang=de (day labels),
// ?jumptest=N[&seed=S], ?scrolltest=N (frames) — results in the info bar, console and window.__viewer.
"use strict";
(() => {
  const G = { gapX: 56, gapY: 48, pad: 56, hCompact: 40, hDetailed: 62, elide: 44, gutter: 88 };
  const Q = new URLSearchParams(location.search);
  const ORDERS = ["greedy", "optimized", "compact"]; // lane orders (SPEC §4.6, §4.7)
  const ORDER_NAME = { greedy: "Greedy", optimized: "Optimized", compact: "Compact" };
  const LABEL_GAP = 22;        // min px between two day labels in the free gutter (pushed down)
  const HITS = 50;             // search results listed
  const LADDER = { 10: "10m", 20: "20m", 40: "40m", 60: "1h", 120: "2h", 240: "4h", 480: "8h", 720: "12h" };
  const MON = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
  const DAY = 86400000;
  const MARGIN = 360;          // px rendered beyond the viewport on every side
  const BLOCK = 32;            // edge-index block size (max lower end per block prunes the scan)
  const COL = {                // canvas colours (graph.css / styles.css tokens; oklch → sRGB)
    base: "#12162a", dot: "rgba(255,255,255,.07)", guide: "rgba(255,255,255,.14)",
    edge: "rgba(214,222,245,.34)", hov: "rgba(234,238,250,.72)", co: "rgb(242,166,24)",
    coGlow: "rgba(242,166,24,.30)", faint: "#5c6480",
  };
  const MONO_11 = '11px "JetBrains Mono", "SF Mono", Menlo, monospace';
  const $ = (id) => document.getElementById(id);
  const esc = (s) => String(s).replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);
  const store = {
    get(k, d) { try { const v = localStorage.getItem("glv." + k); return v == null ? d : JSON.parse(v); } catch { return d; } },
    set(k, v) { try { localStorage.setItem("glv." + k, JSON.stringify(v)); } catch { /* private mode */ } },
  };

  const ui = {
    dataset: store.get("dataset", null), mode: store.get("mode", "time"), order: store.get("order", "optimized"),
    detailed: store.get("detailed", true), cardW: store.get("cardW", 240), gaps: store.get("gaps", true),
    minimap: store.get("minimap", true),
  };
  if (["compact", "time", "free", "timegaps"].includes(Q.get("mode"))) ui.mode = Q.get("mode");
  if (ORDERS.includes(Q.get("order"))) ui.order = Q.get("order");
  if (Q.has("dataset")) ui.dataset = Q.get("dataset");
  if (Q.has("minimap")) ui.minimap = Q.get("minimap") !== "0";
  const scroll = $("scroll"), plane = $("plane"), cardsEl = $("cards"), gutter = $("gutter");
  const canvas = $("canvas"), ctx = canvas.getContext("2d");
  const mmEl = $("mm"), mmCanvas = $("mmCanvas"), mmView = $("mmView"), mmBand = $("mmBand"), mmCtx = mmCanvas.getContext("2d");

  let T = null;               // topology of the loaded bundle
  let L = null;               // geometry for the current ui
  let mm = null;              // minimap mapping + render timing for the current L (null when off)
  let hover = -1, sel = -1, focus = null, flashI = -1;
  const live = new Map();     // node index → card element
  const liveLabels = new Map(); // bucket index → label element
  const counters = { created: 0, removed: 0 }; // DOM cards, cumulative (jump test)
  let stats = { cards: 0, edges: 0, cross: 0, crossAll: 0, paintMs: 0, mmMs: 0, jump: null, scroll: null };

  // ---------------------------------------------------------------- bundle → topology
  function prepare(b) {
    const n = b.n, e = b.e;
    const poff = Int32Array.from(b.poff), pidx = Int32Array.from(b.pidx);
    const eFrom = new Int32Array(e), eTo = new Int32Array(e), eDash = new Uint8Array(e);
    const missing = new Uint8Array(n), merge = new Uint8Array(n), toOff = new Int32Array(n + 1);
    let k = 0;
    for (let i = 0; i < n; i++) {
      if (poff[i + 1] - poff[i] >= 2) merge[i] = 1;
      for (let j = poff[i]; j < poff[i + 1]; j++) {
        if (pidx[j] < 0) { missing[i] = 1; continue; }
        eFrom[k] = pidx[j]; eTo[k] = i; eDash[k] = b.pkind[j] === "i" ? 1 : 0; k++;
      }
      toOff[i + 1] = k; // layout edges are ordered by child: a node's parent edges are contiguous
    }
    if (k !== e) throw new Error(`bundle: ${k} layout edges, header says ${e}`);
    const fromOff = new Int32Array(n + 1), fromList = new Int32Array(e);
    for (let q = 0; q < e; q++) fromOff[eFrom[q] + 1]++;
    for (let i = 0; i < n; i++) fromOff[i + 1] += fromOff[i];
    const fill = fromOff.slice(0, n);
    for (let q = 0; q < e; q++) fromList[fill[eFrom[q]]++] = q;
    const ts = new Float64Array(n);
    for (let i = 0; i < n; i++) ts[i] = b.ts[i] == null ? NaN : b.ts[i];
    const root = new Uint8Array(n);
    for (const r of b.roots) root[r] = 1;
    // the free layout's clamped time (SPEC §4.2 free 1–2): T(i) = max(t(i), T(parents)); y is monotone in it
    let tmin = Infinity;
    for (let i = 0; i < n; i++) if (ts[i] < tmin) tmin = ts[i]; // NaN compares false
    if (tmin === Infinity) tmin = 0;
    const tc = new Float64Array(n);
    for (let i = n - 1; i >= 0; i--) { // parents have larger indices (V2)
      let v = root[i] || Number.isNaN(ts[i]) ? tmin : ts[i];
      for (let q = toOff[i]; q < toOff[i + 1]; q++) if (tc[eFrom[q]] > v) v = tc[eFrom[q]];
      tc[i] = v;
    }
    const m = b.meta;
    const wc = m ? m.wc : -1;
    const t = { b, n, e, eFrom, eTo, eDash, toOff, fromOff, fromList, missing, merge, ts, tc, root, meta: m, wc };
    t.anc = wc >= 0 ? walk(t, wc, true, new Uint8Array(n)) : null;
    return t;
  }

  /** Marks start and all its ancestors (up) or descendants (down) over layout edges. */
  function walk(t, start, up, mark) {
    const stack = [start];
    mark[start] = 1;
    while (stack.length) {
      const i = stack.pop();
      if (up) {
        for (let q = t.toOff[i]; q < t.toOff[i + 1]; q++) { const p = t.eFrom[q]; if (!mark[p]) { mark[p] = 1; stack.push(p); } }
      } else {
        for (let s = t.fromOff[i]; s < t.fromOff[i + 1]; s++) { const c = t.eTo[t.fromList[s]]; if (!mark[c]) { mark[c] = 1; stack.push(c); } }
      }
    }
    return mark;
  }

  // ---------------------------------------------------------------- time helpers
  /** SPEC §4.2 free gap(g) in 1/16 pitch: min(48, 2·L2(1 + g div 60000) div 256). */
  function gapUnits(g) {
    const x = 1 + Math.floor(Math.max(0, g) / 60000);
    let k = 0;
    while (2 ** (k + 1) <= x) k++;
    const l2 = 256 * k + Math.floor(((x - 2 ** k) * 256) / 2 ** k);
    return Math.min(48, Math.floor((2 * l2) / 256));
  }
  const bucketTime = (kind, value) => (kind === "root" ? null : kind === "age" ? T.b.now_ms - value * 60000 : value);
  function dayText(ms, withToday) {
    const off = T.b.utc_offset_min * 60000, d = new Date(ms + off), now = new Date(T.b.now_ms + off);
    const today = Math.floor((T.b.now_ms + off) / DAY) * DAY - off;
    if (withToday && ms === today - DAY) return "Yesterday";
    let s = `${MON[d.getUTCMonth()]} ${d.getUTCDate()}`;
    if (d.getUTCFullYear() !== now.getUTCFullYear()) s += `, ${d.getUTCFullYear()}`;
    return s;
  }
  const bucketLabel = (kind, value) => (kind === "root" ? "" : kind === "age" ? LADDER[value] ?? `${value}m` : dayText(value, true));

  // Free-mode day labels. Localisable by construction: Intl supplies the words and the date format
  // for any BCP-47 tag (?lang=de → "Heute", "Gestern", "24. Sept."); no string table.
  const LANG = Q.get("lang") || "en";
  const fmtDay = new Intl.DateTimeFormat(LANG, { month: "short", day: "numeric", timeZone: "UTC" });
  const fmtDayY = new Intl.DateTimeFormat(LANG, { month: "short", day: "numeric", year: "numeric", timeZone: "UTC" });
  const fmtRel = new Intl.RelativeTimeFormat(LANG, { numeric: "auto" });
  /** Label of local day number d (days since the epoch in the bundle's utc offset), relative to now_ms. */
  function dayLabel(d) {
    const off = T.b.utc_offset_min * 60000, today = Math.floor((T.b.now_ms + off) / DAY);
    if (d === today || d === today - 1) { const s = fmtRel.format(d - today, "day"); return s.charAt(0).toLocaleUpperCase(LANG) + s.slice(1); }
    const date = new Date(d * DAY); // UTC midnight of that local day, formatted in UTC
    return (date.getUTCFullYear() === new Date(T.b.now_ms + off).getUTCFullYear() ? fmtDay : fmtDayY).format(date);
  }

  /** Free mode's gutter: walking the cards top-down meets the days of the clamped time newest first
   *  (y is monotone in it, SPEC I6), so each day gets one label, on its top card, and a guide in the
   *  gap above that card. Raw ts would not do: a child older than its parent is lifted above it by
   *  the clamp and would open its day early. Labels closer than LABEL_GAP px are pushed down.
   *  One row at a time, newest day first: a row can hold two days (commits < 1 min apart around
   *  midnight share a row, gap = 0), and the x order inside a row says nothing about time. */
  function freeDays(ny, ord, H) {
    const off = T.b.utc_offset_min * 60000, out = [], dayOf = (i) => Math.floor((T.tc[i] + off) / DAY);
    let cur = Infinity, prevBottom = -Infinity;
    const label = (d, y, guide) => {
      out.push({ label: dayLabel(d), y: out.length ? Math.max(y + H / 2, out[out.length - 1].y + LABEL_GAP) : y + H / 2,
        guide: out.length && guide ? y - Math.max(4, (y - prevBottom) / 2) : null });
      cur = d;
    };
    for (let s = 0, e; s < ord.length; s = e) {
      const y = ny[ord[s]];
      let hi = -Infinity, lo = Infinity;
      for (e = s; e < ord.length && ny[ord[e]] === y; e++) if (!T.root[ord[e]]) { const d = dayOf(ord[e]); if (d > hi) hi = d; if (d < lo) lo = d; }
      if (hi === lo) { if (hi < cur) label(hi, y, true); } else if (hi > lo) { // two days in one row (rare): newest first, one guide
        const ds = [...new Set(Array.from(ord.subarray(s, e)).filter((i) => !T.root[i]).map(dayOf))].sort((a, b) => b - a);
        let first = true;
        for (const d of ds) if (d < cur) { label(d, y, first); first = false; }
      }
      prevBottom = y + H; // ord is sorted by y and every card is H tall
    }
    return out;
  }
  function ago(i) {
    const t = T.ts[i];
    if (Number.isNaN(t)) return "";
    const m = (T.b.now_ms - t) / 60000;
    if (m < 0) return "future";
    if (m < 1) return "now";
    if (m < 60) return `${Math.floor(m)}m`;
    if (m < 1440) return `${Math.floor(m / 60)}h`;
    if (m < 7 * 1440) return `${Math.floor(m / 1440)}d`;
    const off = T.b.utc_offset_min * 60000;
    return dayText(Math.floor((t + off) / DAY) * DAY - off, false);
  }

  // ---------------------------------------------------------------- geometry
  function computeGeometry() {
    const t0 = performance.now();
    const src = ui.mode === "timegaps" ? "time" : ui.mode;
    const m = T.b.modes[src], n = T.n, e = T.e;
    const unit = m.unit, W = ui.cardW, H = ui.detailed ? G.hDetailed : G.hCompact, pitch = H + G.gapY;
    const offX = src === "time" || src === "free" ? G.gutter : 0;
    // greedy / optimized: col = π(greedy lane); compact: its own lanes, col = lane (SPEC §4.7), and
    // its own route string only where a branch-off's blocked flag differs (bundle v2)
    const cp = ui.order === "compact" ? m.compact : null;
    const pi = cp ? null : m.perm[ui.order];
    const lanes = cp ? cp.lanes : m.lanes, route = (cp && cp.route) || m.route;
    const maxU = n ? m.rows - unit : 0;

    // Time+gaps: extra px below bucket k (between k-1 and k) = max(0, gap(Δkey) − 1 pitch), the free
    // mode's gap curve; prefix sums give every row its cumulative extra.
    let rowExtra = null, bucketExtra = null, extraTotal = 0, gapsMs = 0;
    if (ui.mode === "timegaps") {
      const g0 = performance.now(), nb = m.buckets.length;
      bucketExtra = new Float64Array(nb);
      rowExtra = new Float64Array(m.rows);
      let prev = null;
      for (let k = 0; k < nb; k++) {
        const [kind, value, start, end] = m.buckets[k];
        const tk = bucketTime(kind, value);
        if (k > 0 && prev != null && tk != null) bucketExtra[k] = (Math.max(0, gapUnits(tk - prev) - 16) / 16) * pitch;
        extraTotal += bucketExtra[k];
        for (let r = start; r <= end; r++) rowExtra[r] = extraTotal;
        prev = tk;
      }
      gapsMs = performance.now() - g0;
    }

    const lane = cp ? cp.lane : m.lane, row = m.row;
    const nx = new Float64Array(n), ny = new Float64Array(n), col = new Int32Array(n);
    let bottomStub = false;
    for (let i = 0; i < n; i++) {
      col[i] = pi ? pi[lane[i]] : lane[i];
      nx[i] = offX + G.pad + col[i] * (W + G.gapX);
      ny[i] = G.pad + ((maxU - row[i]) / unit) * pitch + (rowExtra ? extraTotal - rowExtra[row[i]] : 0);
      if (T.missing[i] && row[i] === 0) bottomStub = true;
    }
    const width = n ? offX + G.pad * 2 + lanes * (W + G.gapX) - G.gapX : 0;
    const height = n ? G.pad * 2 + (bottomStub ? G.elide : 0) + (maxU / unit) * pitch + H + extraTotal : 0;

    // nodes sorted by y (then x) for the viewport binary search
    const ord = new Int32Array(n);
    for (let i = 0; i < n; i++) ord[i] = i;
    ord.sort((a, b) => ny[a] - ny[b] || nx[a] - nx[b]);
    const sy = new Float64Array(n);
    for (let s = 0; s < n; s++) sy[s] = ny[ord[s]];

    // edges: vertical extent [child bottom, parent top], x extent; index sorted by upper end
    const eTop = new Float64Array(e), eBot = new Float64Array(e), eX0 = new Float64Array(e), eX1 = new Float64Array(e);
    for (let k = 0; k < e; k++) {
      const p = T.eFrom[k], c = T.eTo[k];
      eTop[k] = ny[c] + H; eBot[k] = ny[p];
      const pcx = nx[p] + W / 2, ncx = nx[c] + W / 2;
      let lo = Math.min(pcx, ncx), hi = Math.max(pcx, ncx);
      const r = route.charCodeAt(k);
      if (r === 98 || r === 66) { const sx = pcx + (ncx > pcx ? 1 : -1) * W * 0.28; lo = Math.min(lo, sx); hi = Math.max(hi, sx); } // b, B
      eX0[k] = lo; eX1[k] = hi;
    }
    const eOrd = new Int32Array(e);
    for (let k = 0; k < e; k++) eOrd[k] = k;
    eOrd.sort((a, b) => eTop[a] - eTop[b]);
    const eTopS = new Float64Array(e), blkMax = new Float64Array(Math.ceil(e / BLOCK));
    blkMax.fill(-Infinity);
    for (let s = 0; s < e; s++) {
      const k = eOrd[s];
      eTopS[s] = eTop[k];
      const bi = (s / BLOCK) | 0;
      if (eBot[k] > blkMax[bi]) blkMax[bi] = eBot[k];
    }

    // time gutter: label on the bucket's oldest row, guide in the gap below it (not for the oldest)
    const buckets = src === "time" ? m.buckets.map(([kind, value, start], k) => {
      const top = G.pad + (maxU - start) * pitch + (rowExtra ? extraTotal - rowExtra[start] : 0);
      return { label: bucketLabel(kind, value), y: top + H / 2, guide: k > 0 ? top + H + (G.gapY + (bucketExtra ? bucketExtra[k] : 0)) / 2 : null };
    }) : src === "free" ? freeDays(ny, ord, H) : [];

    return {
      m, src, unit, W, H, pitch, offX, nx, ny, lane, lanes, col, width, height, ord, sy, eTop, eBot, eX0, eX1, eOrd, eTopS, blkMax,
      route, buckets, extraTotal, gapsMs, geomMs: performance.now() - t0,
    };
  }

  // ---------------------------------------------------------------- queries
  function lowerBound(a, v) { let lo = 0, hi = a.length; while (lo < hi) { const mid = (lo + hi) >> 1; if (a[mid] < v) lo = mid + 1; else hi = mid; } return lo; }
  function upperBound(a, v) { let lo = 0, hi = a.length; while (lo < hi) { const mid = (lo + hi) >> 1; if (a[mid] <= v) lo = mid + 1; else hi = mid; } return lo; }

  function edgesIn(top, bot, left, right) {
    const out = [], ub = upperBound(L.eTopS, bot);
    for (let bi = 0; bi * BLOCK < ub; bi++) {
      if (L.blkMax[bi] < top) continue;
      const end = Math.min(ub, (bi + 1) * BLOCK);
      for (let s = bi * BLOCK; s < end; s++) {
        const k = L.eOrd[s];
        if (L.eBot[k] < top || L.eX1[k] < left || L.eX0[k] > right) continue;
        out.push(k);
      }
    }
    return out;
  }

  /** The design's routeEdges polyline for layout edge k (flat [x0,y0,x1,y1,…]). */
  function edgePts(k) {
    const p = T.eFrom[k], c = T.eTo[k], W = L.W;
    const pcx = L.nx[p] + W / 2, ncx = L.nx[c] + W / 2, outY = L.ny[p], inY = L.ny[c] + L.H;
    const r = L.route[k];
    if (r === "s") return [pcx, outY, ncx, inY];
    if (r === "m") { const my = inY + G.gapY * 0.4; return [pcx, outY, pcx, my, ncx, my, ncx, inY]; }
    const sx = pcx + (ncx > pcx ? 1 : -1) * W * 0.28, hy = outY - G.gapY * 0.4; // branch-off (incl. blocked merge)
    return [sx, outY, sx, hy, ncx, hy, ncx, inY];
  }

  /** H×V crossings between the given edges (design analyzeEdges, 1 px tolerance, no shared endpoint). */
  function crossings(ks, pts) {
    const hs = [], vs = [];
    ks.forEach((k, j) => {
      const P = pts[j];
      for (let q = 2; q < P.length; q += 2) {
        const x1 = P[q - 2], y1 = P[q - 1], x2 = P[q], y2 = P[q + 1];
        if (x1 === x2 && y1 === y2) continue;
        if (y1 === y2) hs.push({ y: y1, a: Math.min(x1, x2), b: Math.max(x1, x2), k });
        else vs.push({ x: x1, a: Math.min(y1, y2), b: Math.max(y1, y2), k });
      }
    });
    vs.sort((u, v) => u.x - v.x);
    const vx = Float64Array.from(vs, (v) => v.x);
    const gaps = new Map(), list = [];
    for (const h of hs) {
      for (let s = upperBound(vx, h.a + 1); s < vs.length && vs[s].x < h.b - 1; s++) {
        const v = vs[s];
        if (!(h.y > v.a + 1 && h.y < v.b - 1)) continue;
        const A = h.k, Bk = v.k;
        const af = T.eFrom[A], at = T.eTo[A], bf = T.eFrom[Bk], bt = T.eTo[Bk];
        if (af === bf || at === bt || af === bt || at === bf) continue;
        list.push(v.x, h.y);
        if (!gaps.has(A)) gaps.set(A, []);
        gaps.get(A).push(v.x);
      }
    }
    return { gaps, list };
  }

  // ---------------------------------------------------------------- canvas
  let dotPattern = null, dpr = 1;
  function sizeCanvas() {
    dpr = window.devicePixelRatio || 1;
    const w = scroll.clientWidth, h = scroll.clientHeight;
    canvas.style.width = w + "px"; canvas.style.height = h + "px";
    canvas.width = Math.round(w * dpr); canvas.height = Math.round(h * dpr);
    const pc = document.createElement("canvas");
    pc.width = pc.height = Math.round(24 * dpr);
    const p = pc.getContext("2d");
    p.fillStyle = COL.dot;
    p.beginPath(); p.arc(12 * dpr, 12 * dpr, 1.15 * dpr, 0, Math.PI * 2); p.fill();
    dotPattern = ctx.createPattern(pc, "repeat");
  }

  /** Rounded orthogonal polyline (design roundedPath, r = 10) with gaps cut into its horizontal. */
  function tracePath(P, gapsX, ox, oy) {
    const Q = [P[0], P[1]];
    for (let q = 2; q < P.length; q += 2) if (P[q] !== Q[Q.length - 2] || P[q + 1] !== Q[Q.length - 1]) Q.push(P[q], P[q + 1]);
    const m = Q.length / 2;
    let cx = Q[0], cy = Q[1];
    ctx.moveTo(cx - ox, cy - oy);
    for (let i = 1; i < m; i++) {
      const x1 = Q[2 * i], y1 = Q[2 * i + 1];
      let ex = x1, ey = y1, corner = null;
      if (i < m - 1) {
        const x0 = Q[2 * i - 2], y0 = Q[2 * i - 1], x2 = Q[2 * i + 2], y2 = Q[2 * i + 3];
        const l1 = Math.hypot(x1 - x0, y1 - y0), l2 = Math.hypot(x2 - x1, y2 - y1), rr = Math.min(10, l1 / 2, l2 / 2);
        ex = x1 - ((x1 - x0) / l1) * rr; ey = y1 - ((y1 - y0) / l1) * rr;
        corner = [x1, y1, x1 + ((x2 - x1) / l2) * rr, y1 + ((y2 - y1) / l2) * rr];
      }
      if (gapsX && cy === ey && cx !== ex) {
        const dir = ex > cx ? 1 : -1, lo = Math.min(cx, ex), hi = Math.max(cx, ex);
        const gs = gapsX.filter((g) => g > lo && g < hi).sort((a, b) => (a - b) * dir);
        // cuts may overlap (two collinear verticals give the same x twice): never draw back into a cut
        let pen = cx;
        for (const g of gs) {
          const a = g - 6 * dir, b = (g + 6 * dir - ex) * dir > 0 ? ex : g + 6 * dir;
          if ((a - pen) * dir > 0) ctx.lineTo(a - ox, cy - oy);
          if ((b - pen) * dir > 0) { ctx.moveTo(b - ox, cy - oy); pen = b; }
        }
      }
      ctx.lineTo(ex - ox, ey - oy);
      if (corner) { ctx.quadraticCurveTo(corner[0] - ox, corner[1] - oy, corner[2] - ox, corner[3] - oy); cx = corner[2]; cy = corner[3]; } else { cx = ex; cy = ey; }
    }
  }

  function paintCanvas(sx, sy, vw, vh) {
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.fillStyle = COL.base;
    ctx.fillRect(0, 0, vw, vh);
    // dot grid anchored to the content: dots at 16 + 24k (background-position 4px, tile centre 12px)
    ctx.save();
    dotPattern.setTransform(new DOMMatrix([1 / dpr, 0, 0, 1 / dpr, 4 - (sx % 24), 4 - (sy % 24)]));
    ctx.fillStyle = dotPattern;
    ctx.fillRect(0, 0, vw, vh);
    ctx.restore();
    if (!T.n) return;

    // time guides (dotted, from the gutter edge to the full width)
    if (L.buckets.length) {
      ctx.strokeStyle = COL.guide; ctx.lineWidth = 1; ctx.setLineDash([2, 6]);
      ctx.beginPath();
      for (const b of L.buckets) {
        if (b.guide == null || b.guide < sy - 2 || b.guide > sy + vh + 2) continue;
        const y = Math.round(b.guide - sy) + 0.5;
        ctx.moveTo(G.gutter - sx, y); ctx.lineTo(L.width - sx, y);
      }
      ctx.stroke();
      ctx.setLineDash([]);
    }

    // edges intersecting the viewport (+ a small margin so line caps and hops at the border are right)
    const pad = 16;
    const ks = edgesIn(sy - pad, sy + vh + pad, sx - pad, sx + vw + pad);
    const pts = ks.map(edgePts);
    const cr = ui.gaps ? crossings(ks, pts) : { gaps: new Map(), list: [] };
    let inView = 0;
    for (let q = 0; q < cr.list.length; q += 2) {
      const x = cr.list[q], y = cr.list[q + 1];
      if (x >= sx && x <= sx + vw && y >= sy && y <= sy + vh) inView++;
    }
    // style groups, painted in the design's order: plain, then hov, then hl (@ ancestry)
    const groups = new Map();
    ks.forEach((k, j) => {
      const a = T.eFrom[k], c = T.eTo[k];
      const hl = T.anc ? T.anc[a] && T.anc[c] : false;
      const hv = focus ? focus[a] && focus[c] : hover >= 0 && (a === hover || c === hover);
      const dim = !!focus && !hv;
      const key = (hl ? 4 : 0) + (hv ? 2 : 0) + (dim ? 8 : 0) + (T.eDash[k] ? 1 : 0);
      if (!groups.has(key)) groups.set(key, []);
      groups.get(key).push(j);
    });
    const keys = [...groups.keys()].sort((a, b) => ((a & 4) - (b & 4)) || ((a & 2) - (b & 2)) || a - b);
    ctx.lineCap = "butt"; ctx.lineJoin = "round";
    for (const key of keys) {
      const hl = key & 4, hv = key & 2;
      ctx.globalAlpha = key & 8 ? 0.28 : 1;
      ctx.strokeStyle = hl ? COL.co : hv ? COL.hov : COL.edge;
      ctx.lineWidth = hl ? 2.25 : 1.5;
      ctx.setLineDash(key & 1 ? [3, 5] : []);
      if (hl) { ctx.shadowColor = COL.coGlow; ctx.shadowBlur = 4 * dpr; } else ctx.shadowBlur = 0;
      ctx.beginPath();
      for (const j of groups.get(key)) tracePath(pts[j], cr.gaps.get(ks[j]), sx, sy);
      ctx.stroke();
    }
    ctx.globalAlpha = 1; ctx.shadowBlur = 0; ctx.setLineDash([]);

    // missing parents: the design's dashed "~ elided" stub below the card (no count: out of scope)
    const top = sy - MARGIN, bot = sy + vh;
    const lo = lowerBound(L.sy, top - L.H - G.elide), hi = upperBound(L.sy, bot);
    ctx.setLineDash([3, 5]);
    ctx.font = MONO_11;
    for (let s = lo; s < hi; s++) {
      const i = L.ord[s];
      if (!T.missing[i]) continue;
      const cx = L.nx[i] + L.W / 2 - sx, y = L.ny[i] + L.H - sy;
      if (cx < -L.W || cx > vw + L.W) continue;
      const gold = T.anc && T.anc[i];
      ctx.globalAlpha = focus && !focus[i] ? 0.28 : 1;
      ctx.strokeStyle = gold ? COL.co : COL.edge;
      ctx.lineWidth = gold ? 2.25 : 1.5; // design .gedge.hl
      ctx.shadowColor = COL.coGlow; ctx.shadowBlur = gold ? 4 * dpr : 0;
      ctx.beginPath(); ctx.moveTo(cx, y); ctx.lineTo(cx, y + G.elide - 6); ctx.stroke();
      ctx.shadowBlur = 0;
      ctx.fillStyle = COL.faint; ctx.fillText("~", cx + 10, y + G.elide - 14);
    }
    ctx.globalAlpha = 1; ctx.setLineDash([]);
    stats.edges = ks.length; stats.cross = inView; stats.crossAll = cr.list.length / 2;
  }

  // ---------------------------------------------------------------- cards
  const SVG_NS = "http://www.w3.org/2000/svg";
  function glyph(kind) {
    const s = document.createElementNS(SVG_NS, "svg");
    s.setAttribute("viewBox", "0 0 16 16");
    const size = kind === "bm" ? 11 : 12;
    s.setAttribute("width", size); s.setAttribute("height", size);
    const d = {
      bm: '<path d="M4.6 2.2h6.8c.47 0 .85.38.85.85v10.4c0 .35-.4.55-.68.34L8 11.1l-3.57 2.69a.43.43 0 0 1-.68-.34V3.05c0-.47.38-.85.85-.85z" fill="currentColor" stroke="currentColor" stroke-width="1.4" stroke-linejoin="round"/>',
      merge: '<g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"><circle cx="4.5" cy="3.5" r="1.6"/><circle cx="4.5" cy="12.5" r="1.6"/><circle cx="11.5" cy="8" r="1.6"/><path d="M4.5 5.1v5.8M4.5 5.2c0 2.3 2.4 2.8 5.4 2.8"/></g>',
      conflict: '<g fill="none" stroke="currentColor" stroke-width="1.4" stroke-linejoin="round" stroke-linecap="round"><path d="M8 2.2 14.2 13H1.8z"/><path d="M8 6.3v3.2"/></g><circle cx="8" cy="11.4" r=".8" fill="currentColor"/>',
    }[kind];
    s.innerHTML = d; // static markup only, never data
    return s;
  }
  function span(cls, text) { const e = document.createElement("span"); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; }

  // feature/ZAN-412_onboarding-swipe → { main: "ZAN-412", rest: "onboarding-swipe" } (design shortBookmark)
  function shortBookmark(name) {
    const [base, remote] = name.split("@");
    const m = base.match(/[A-Z][A-Z0-9]+-\d+/);
    if (m) return { main: m[0], rest: base.slice(m.index + m[0].length).replace(/^[_\-/.]+/, ""), remote };
    const seg = base.split("/");
    if (seg.length > 1) return { prefix: seg.slice(0, -1).join("/") + "/", main: seg[seg.length - 1], remote };
    return { main: base, remote };
  }

  const flagsOf = (i) => (T.meta ? T.meta.flags[i] : 0) | (T.root[i] ? 16 : 0);
  function cardClass(i) {
    const f = flagsOf(i);
    return "gcard " + (ui.detailed ? "is-detailed" : "is-compact") + (i === sel ? " sel" : "") + (f & 1 ? " wc" : "") +
      (i === hover ? " hov" : "") + (f & 2 ? " immutable" : "") + (f & 16 ? " root" : "") + (focus && !focus[i] ? " dim" : "") +
      (i === flashI ? " jump" : "");
  }

  function makeCard(i) {
    const M = T.meta, f = flagsOf(i), wc = !!(f & 1), root = !!(f & 16);
    const el = document.createElement("div");
    el.className = cardClass(i);
    el.style.cssText = `left:${L.nx[i]}px;top:${L.ny[i]}px;width:${L.W}px;height:${L.H}px`;
    el.dataset.i = i;
    const id = M ? M.change[i] : T.b.ids[i];
    const bold = Math.max(1, Math.min(id.length, M ? M.plen[i] : 2));
    const cid = span("gcid");
    if (f & 2 && !root) cid.append(span("gimm", "◆"));
    const b = document.createElement("b"); b.textContent = id.slice(0, bold);
    cid.append(b, id.slice(bold, Math.max(bold, ui.detailed && !wc ? 8 : 5)));
    let subjText, subjCls = "gsubj";
    if (M) {
      subjText = root ? "root()" : M.desc[i] || "(no description set)";
      if (root || !M.desc[i] || f & 4) subjCls += " is-dim";
    } else {
      subjText = root ? "root()" : T.b.ids[i];
      subjCls += root ? " is-dim" : " is-mono";
    }
    const subj = span(subjCls, subjText);
    const flags = [];
    if (f & 8) { const x = span("gflag conflict"); x.title = "conflict"; x.append(glyph("conflict")); flags.push(x); }
    if (T.merge[i]) { const x = span("gflag"); x.title = "merge"; x.append(glyph("merge")); flags.push(x); }
    const at = wc ? span("gat", "@") : null;
    if (ui.detailed) {
      const l1 = span("gline"); l1.append(subj);
      const l2 = span("gline gmeta");
      if (at) l2.append(at);
      l2.append(cid);
      if (M && M.author[i]) l2.append(span("gmeta-t au", M.author[i].split(" ")[0]));
      const when = ago(i);
      if (when) l2.append(span("gmeta-t", when));
      if (f & 4) l2.append(span("gmeta-t em", "empty"));
      l2.append(...flags);
      el.append(l1, l2);
    } else {
      const l = span("gline");
      if (at) l.append(at);
      l.append(cid, subj, ...flags);
      el.append(l);
    }
    const bms = M && M.bm[i];
    if (bms && !root) {
      const s = shortBookmark(bms[0]);
      const g = span("gbm"), t = span("gbm-trigger");
      t.title = bms.join("\n");
      t.append(glyph("bm"));
      if (s.prefix) t.append(span("gbm-rest gbm-prefix", s.prefix));
      t.append(span("gbm-main", s.main));
      if (s.remote) t.append(span("gbm-rest", "@" + s.remote));
      if (s.rest) t.append(span("gbm-rest gbm-shrink", s.rest));
      if (bms.length > 1) t.append(span("gbm-more", "+" + (bms.length - 1)));
      g.append(t);
      el.append(g);
    }
    const col = L.col[i], row = L.m.row[i];
    el.title = `${M ? M.change[i] + "  " : ""}${T.b.ids[i]}\nrow ${row}${L.unit > 1 ? ` (${(row / L.unit).toFixed(2)} pitch)` : ""} · lane ${L.lane[i]} · col ${col}` +
      (wc ? "\nworking copy (@)" : "");
    el.addEventListener("mouseenter", () => setHover(i));
    el.addEventListener("mouseleave", () => { if (hover === i) setHover(-1); });
    el.addEventListener("click", () => { sel = sel === i ? -1 : i; restyleCards(); renderInfo(); });
    return el;
  }

  function paintCards(sx, sy, vw, vh) {
    const top = sy - MARGIN - L.H, bot = sy + vh + MARGIN, left = sx - MARGIN - L.W, right = sx + vw + MARGIN;
    const lo = lowerBound(L.sy, top), hi = upperBound(L.sy, bot);
    const want = new Set();
    for (let s = lo; s < hi; s++) {
      const i = L.ord[s];
      if (L.nx[i] < left || L.nx[i] > right) continue;
      want.add(i);
      if (!live.has(i)) { const el = makeCard(i); live.set(i, el); cardsEl.append(el); counters.created++; }
    }
    for (const [i, el] of live) if (!want.has(i)) { el.remove(); live.delete(i); counters.removed++; }
    stats.cards = live.size;
  }
  function restyleCards() { for (const [i, el] of live) el.className = cardClass(i); requestPaint(); }
  function clearCards() { cardsEl.replaceChildren(); live.clear(); gutter.replaceChildren(); liveLabels.clear(); }

  // Free only (a day there can span many screens): the day at the viewport's top edge stays pinned
  // at the top of the gutter until the next day's label pushes it up, like a list section header.
  const pin = span("gtime-label pinned"), PIN = 20;
  function paintGutter(sy, vh) {
    if (!L.buckets.length) return;
    let pk = -1;
    if (L.src === "free") { // free labels are sorted by y: the last one above the pin line
      let lo = 0, hi = L.buckets.length;
      while (lo < hi) { const mid = (lo + hi) >> 1; if (L.buckets[mid].y < sy + PIN) lo = mid + 1; else hi = mid; }
      pk = lo - 1;
    }
    if (pk >= 0) {
      const next = L.buckets[pk + 1];
      pin.textContent = L.buckets[pk].label;
      pin.style.top = Math.min(sy + PIN, next ? next.y - LABEL_GAP : Infinity) + "px";
      if (!pin.isConnected) gutter.append(pin);
    } else pin.remove();
    const want = new Set();
    L.buckets.forEach((b, k) => {
      if (k === pk || !b.label || b.y < sy - 30 || b.y > sy + vh + 30) return;
      want.add(k);
      if (!liveLabels.has(k)) {
        const el = span("gtime-label", b.label);
        el.style.top = b.y + "px";
        liveLabels.set(k, el); gutter.append(el);
      }
    });
    for (const [k, el] of liveLabels) if (!want.has(k)) { el.remove(); liveLabels.delete(k); }
  }

  function setHover(i) {
    hover = i;
    focus = i >= 0 ? walk(T, i, false, walk(T, i, true, new Uint8Array(T.n))) : null;
    restyleCards();
    renderInfo();
  }

  // ---------------------------------------------------------------- minimap
  // The whole graph scaled into the strip (x: the columns right of the gutter, y: the full height,
  // never stretched beyond the x scale). Rendered once per geometry or strip size: every node adds
  // a rectangle, every edge its vertical and horizontal runs, to difference arrays; one prefix-sum
  // pass per array turns them into per-pixel counts, a LUT maps the counts to alpha. That is
  // O(n + E + pixels) whatever the rectangle and run lengths; 100k nodes never touch a canvas API.
  const MM = { padX: 8, padY: 8 };
  const LUT_E = new Uint8Array(256), LUT_N = new Uint8Array(256); // count → alpha (log ramp)
  for (let c = 1; c < 256; c++) {
    LUT_E[c] = Math.round(255 * Math.min(0.75, 0.3 + 0.1 * Math.log2(c)));
    LUT_N[c] = Math.round(255 * Math.min(1, 0.6 + 0.12 * Math.log2(c)));
  }
  let mmBox = "";
  function renderMinimap() {
    mm = null; mmBox = "";
    if (!ui.minimap || !T || !L || !T.n) return;
    const cw = mmEl.clientWidth, ch = mmEl.clientHeight;
    if (!cw || !ch) return;
    const t0 = performance.now();
    const d = window.devicePixelRatio || 1, RW = Math.round(cw * d), RH = Math.round(ch * d), S1 = RW + 1;
    const ox = L.offX, kx = (cw - 2 * MM.padX) / Math.max(1, L.width - ox), ky = Math.min((ch - 2 * MM.padY) / L.height, kx);
    const ax = kx * d, bx = (MM.padX - ox * kx) * d, ay = ky * d, by = MM.padY * d; // device px = a·content + b
    const cx = (v) => (v < 0 ? 0 : v >= RW ? RW - 1 : v), cy = (v) => (v < 0 ? 0 : v >= RH ? RH - 1 : v);
    const nD = new Int32Array((RH + 1) * S1), vD = new Int32Array((RH + 1) * RW), hD = new Int32Array(RH * S1);
    const M = T.meta, bD = M ? new Int32Array((RH + 1) * S1) : null;
    const { nx, ny, W, H, route } = L, n = T.n;
    for (let i = 0; i < n; i++) { // node → rectangle, 4 corner updates (bookmarked nodes in their own layer)
      const x0 = cx(Math.floor(nx[i] * ax + bx)), x1 = Math.max(x0, cx(Math.ceil((nx[i] + W) * ax + bx) - 1));
      const y0 = cy(Math.floor(ny[i] * ay + by)), y1 = Math.max(y0, cy(Math.ceil((ny[i] + H) * ay + by) - 1));
      const D = bD && M.bm[i] ? bD : nD;
      D[y0 * S1 + x0]++; D[y0 * S1 + x1 + 1]--; D[(y1 + 1) * S1 + x0]--; D[(y1 + 1) * S1 + x1 + 1]++;
    }
    const vseg = (x, ya, yb) => {
      const c = cx(Math.floor(x * ax + bx));
      let a = cy(Math.floor(ya * ay + by)), b = cy(Math.floor(yb * ay + by));
      if (a > b) { const t = a; a = b; b = t; }
      vD[a * RW + c]++; vD[(b + 1) * RW + c]--;
    };
    const hseg = (y, xa, xb) => {
      const r = cy(Math.floor(y * ay + by));
      let a = cx(Math.floor(xa * ax + bx)), b = cx(Math.floor(xb * ax + bx));
      if (a > b) { const t = a; a = b; b = t; }
      hD[r * S1 + a]++; hD[r * S1 + b + 1]--;
    };
    for (let k = 0; k < T.e; k++) { // edge → its runs (edgePts geometry, without the allocation)
      const p = T.eFrom[k], c = T.eTo[k], pcx = nx[p] + W / 2, ncx = nx[c] + W / 2, outY = ny[p], inY = ny[c] + H;
      const r = route.charCodeAt(k);
      if (r === 115) vseg(pcx, inY, outY); // s
      else if (r === 109) { const my = inY + G.gapY * 0.4; vseg(pcx, my, outY); hseg(my, pcx, ncx); vseg(ncx, inY, my); } // m
      else { const sx = pcx + (ncx > pcx ? 1 : -1) * W * 0.28, hy = outY - G.gapY * 0.4; vseg(sx, hy, outY); hseg(hy, sx, ncx); vseg(ncx, inY, hy); }
    }
    const img = new ImageData(RW, RH), px = img.data;
    for (let y = 0; y < RH; y++) { // prefix sums (2-D for the rectangles, 1-D for the runs) + compose
      const o = y * S1, u = o - S1, v = y * RW;
      let rn = 0, rb = 0, rh = 0;
      for (let x = 0; x < RW; x++) {
        rn += nD[o + x]; const nc = (nD[o + x] = rn + (y ? nD[u + x] : 0));
        let bc = 0;
        if (bD) { rb += bD[o + x]; bc = bD[o + x] = rb + (y ? bD[u + x] : 0); }
        if (y) vD[v + x] += vD[v - RW + x];
        rh += hD[o + x];
        const ec = vD[v + x] + rh, q = (v + x) * 4;
        if (bc > 0) { px[q] = 96; px[q + 1] = 165; px[q + 2] = 250; px[q + 3] = 255; continue; } // bookmark
        const an = nc > 0 ? LUT_N[nc > 255 ? 255 : nc] : 0, ae = ec > 0 ? LUT_E[ec > 255 ? 255 : ec] : 0;
        if (!an && !ae) continue;
        const a = an + ((ae * (255 - an)) >> 8); // node over edge
        px[q] = (231 * an + ((150 * ae * (255 - an)) >> 8)) / a;
        px[q + 1] = (233 * an + ((160 * ae * (255 - an)) >> 8)) / a;
        px[q + 2] = (242 * an + ((196 * ae * (255 - an)) >> 8)) / a;
        px[q + 3] = a;
      }
    }
    if (T.wc >= 0) { // @: a gold line across the strip and the card itself, at least 3 device px
      const i = T.wc, row = cy(Math.floor((ny[i] + H / 2) * ay + by));
      for (let x = 0; x < RW; x++) { const q = (row * RW + x) * 4; px[q] = 242; px[q + 1] = 166; px[q + 2] = 24; px[q + 3] = 150; }
      const x0 = cx(Math.floor(nx[i] * ax + bx) - 1), x1 = cx(Math.max(x0 + 2, Math.ceil((nx[i] + W) * ax + bx)));
      for (let y = cy(row - 1); y <= cy(row + 1); y++) for (let x = x0; x <= x1; x++) { const q = (y * RW + x) * 4; px[q] = 242; px[q + 1] = 166; px[q + 2] = 24; px[q + 3] = 255; }
    }
    const t1 = performance.now();
    mmCanvas.width = RW; mmCanvas.height = RH;
    mmCanvas.style.width = cw + "px"; mmCanvas.style.height = ch + "px";
    mmCtx.putImageData(img, 0, 0);
    mm = { kx, ky, ox, cw, ch, RW, RH, rasterMs: t1 - t0, putMs: performance.now() - t1 };
  }

  /** The viewport rectangle: a DOM overlay moved by transform (no canvas repaint on scroll). */
  function paintMinimapView(sx, sy, vw, vh) {
    if (!mm) return;
    const x0 = MM.padX + sx * mm.kx, x1 = MM.padX + (sx + vw - L.offX) * mm.kx; // the gutter hides L.offX px
    const y0 = MM.padY + sy * mm.ky, y1 = MM.padY + (sy + vh) * mm.ky;
    const w = Math.max(4, Math.round(x1 - x0)), h = Math.max(6, Math.round(y1 - y0)), y = ((y0 + y1) / 2 - h / 2).toFixed(1);
    mmView.style.transform = `translate(${((x0 + x1) / 2 - w / 2).toFixed(1)}px,${y}px)`;
    mmBand.style.transform = `translateY(${y}px)`; // full-width band: the rectangle is tiny on long graphs
    const box = w + "x" + h;
    if (box !== mmBox) { mmBox = box; mmView.style.width = w + "px"; mmView.style.height = mmBand.style.height = h + "px"; }
  }

  /** Click or drag on the minimap: centre the viewport there (instant). */
  let mmDrag = false;
  function mmJump(e) {
    if (!mm) return;
    const r = mmCanvas.getBoundingClientRect(); // not the strip's: its 1 px left border would shift x
    const x = (e.clientX - r.left - MM.padX) / mm.kx + mm.ox, y = (e.clientY - r.top - MM.padY) / mm.ky;
    scroll.scrollLeft = x - (scroll.clientWidth + L.offX) / 2;
    scroll.scrollTop = y - scroll.clientHeight / 2;
  }
  mmEl.addEventListener("pointerdown", (e) => { if (e.button !== 0 || !mm) return; mmDrag = true; mmEl.setPointerCapture(e.pointerId); mmJump(e); });
  mmEl.addEventListener("pointermove", (e) => { if (mmDrag) mmJump(e); });
  mmEl.addEventListener("pointerup", () => { mmDrag = false; });
  mmEl.addEventListener("pointercancel", () => { mmDrag = false; });
  function applyMinimap() { // the strip's size change re-renders it (ResizeObserver below)
    $("view").classList.toggle("mm-on", ui.minimap);
    mmEl.hidden = !ui.minimap;
    if (!ui.minimap) mm = null;
    else if (!mm) scheduleMinimap(); // off and on again within one frame: the observer sees no size change
  }
  let mmPending = false;
  function scheduleMinimap() { // next frame, unless the raster already fits the strip (observer + toggle)
    if (mmPending) return;
    mmPending = true;
    requestAnimationFrame(() => {
      mmPending = false;
      if (mm && mm.cw === mmEl.clientWidth && mm.ch === mmEl.clientHeight) return;
      renderMinimap(); requestPaint();
    });
  }
  new ResizeObserver(scheduleMinimap).observe(mmEl);

  // ---------------------------------------------------------------- frame
  let pending = false;
  function requestPaint() { if (!pending) { pending = true; requestAnimationFrame(paint); } }
  function paint() {
    pending = false;
    if (!T || !L) return;
    const t0 = performance.now();
    const sx = scroll.scrollLeft, sy = scroll.scrollTop, vw = scroll.clientWidth, vh = scroll.clientHeight;
    paintCanvas(sx, sy, vw, vh);
    paintCards(sx, sy, vw, vh);
    paintGutter(sy, vh);
    const t1 = performance.now();
    paintMinimapView(sx, sy, vw, vh);
    stats.mmMs = performance.now() - t1;
    stats.paintMs = performance.now() - t0;
    renderInfo();
  }

  // ---------------------------------------------------------------- info bar
  const fmtN = (v) => v.toLocaleString("en-US");
  function fmtNs(ns) { return ns == null ? "–" : ns < 1e6 ? `${(ns / 1e3).toFixed(ns < 1e4 ? 1 : 0)} µs` : `${(ns / 1e6).toFixed(2)} ms`; }
  function renderInfo() {
    if (!T || !L) return;
    const m = L.m, tm = m.timing?.[ui.order];
    const rows = L.unit > 1 ? `${fmtN(m.rows)} units (${fmtN(Math.round(m.rows / L.unit))} pitches)` : fmtN(m.rows);
    const parts = [
      `<span><b>${fmtN(T.n)}</b> nodes · <b>${fmtN(T.e)}</b> edges · rows <b>${rows}</b> · lanes <b>${L.lanes}</b>` +
        (L.buckets.length ? ` · ${L.src === "free" ? "days" : "buckets"} <b>${fmtN(L.buckets.length)}</b>` : "") + "</span>",
      `<span><span class="k">painted</span> ${stats.cards} DOM cards (±${MARGIN} px) · ${stats.edges} edges · crossings in view <b>${stats.cross}</b>` +
        (ui.gaps ? "" : " (gaps off)") + "</span>",
      `<span><span class="k">layout ${L.src}/${ui.order}</span> <b>${tm ? fmtNs(tm.median_ns.total) : "–"}</b>` +
        (tm ? ` ${tm.impl} median of ${tm.runs}` : "") +
        (ui.mode === "timegaps" ? ` + gap prefix sums <b>${L.gapsMs.toFixed(1)} ms</b> (viewer; browser timer resolution 0.1 ms)` : "") + "</span>",
      `<span><span class="k">viewer</span> geometry ${L.geomMs.toFixed(1)} ms · frame ${stats.paintMs.toFixed(1)} ms · ${fmtN(Math.round(L.width))}×${fmtN(Math.round(L.height))} px</span>`,
    ];
    if (m.metrics) { // precomputed by the bundler (tools/lane-metrics.mjs), so free here
      const cell = (o) => {
        const x = m.metrics[o];
        if (!x) return "";
        const s = `${ORDER_NAME[o]} ${fmtN(x.cross)} ✕ · ${x.meanW.toFixed(2)}/${x.maxW} cols · ${x.holesPct.toFixed(1)} % holes`;
        return o === ui.order ? `<b>${s}</b>` : s;
      };
      parts.push(`<span title="Whole graph, drawn at 240×62 cards: crossings (✕) as the viewer draws them, mean/max width in columns, empty cells left of the rightmost occupied column (tools/lane-metrics.mjs)">` +
        `<span class="k">lane orders, ${L.src}</span> ${ORDERS.map(cell).filter(Boolean).join(" &nbsp;|&nbsp; ")}</span>`);
    }
    if (mm) parts.push(`<span><span class="k">minimap</span> ${mm.RW}×${mm.RH} px · raster <b>${mm.rasterMs.toFixed(1)} ms</b> + put ${mm.putMs.toFixed(1)} ms · view ${stats.mmMs.toFixed(2)} ms/frame</span>`);
    const j = stats.jump, s = stats.scroll, f = (q, d = 1) => `${q.med.toFixed(d)}/${q.p95.toFixed(d)}/${q.max.toFixed(d)}`;
    if (j) parts.push(`<span><span class="k">jump test (med/p95/max)</span> ${j.jumps}× ${esc(j.dataset)}/${j.mode} · next frame <b>${f(j.next)} ms</b> · ` +
      `frame work ${f(j.work)} ms (idle frame ${f(j.idle)}) · paint JS ${f(j.js)} ms · cards +${f(j.created, 0)} −${f(j.removed, 0)} · ` +
      `r(distance, work) ${j.r_dist_work.toFixed(2)}</span>`);
    if (s) parts.push(`<span><span class="k">scroll test</span> ${s.frames} frames · frame work with minimap <b>${s.with.work.med.toFixed(2)}</b>/${s.with.work.p95.toFixed(2)} ms, ` +
      `without <b>${s.without.work.med.toFixed(2)}</b>/${s.without.work.p95.toFixed(2)} ms (med/p95) · overlay ${s.overlayUs.toFixed(2)} µs/update</span>`);
    if (m.lanes <= 24 && ui.order === "optimized") parts.push(`<span><span class="k">π</span> [${m.perm.optimized.join(",")}]</span>`);
    if (T.meta?.dropped) parts.push(`<span><span class="k">dump</span> ${T.meta.dropped} duplicate parent edge(s) dropped</span>`);
    const i = sel >= 0 ? sel : hover;
    if (i >= 0) {
      const id = T.meta ? T.meta.change[i] : T.b.ids[i];
      parts.push(`<span class="sel">${sel >= 0 ? "selected" : "hover"} ${esc(id)} · row ${m.row[i]} · lane ${L.lane[i]} · col ${L.col[i]}</span>`);
    }
    $("info").innerHTML = parts.join(""); // numbers, fixed text and the escaped id only
  }
  // The bar's per-frame text (frame ms, card counts, hover) can re-wrap while scrolling; each
  // re-wrap resized the graph area mid-scroll, and with it the canvas and the minimap strip
  // (a re-raster). So the bar only grows, until the window resizes or a dataset loads.
  const infoEl = $("info");
  new ResizeObserver(() => {
    const h = infoEl.getBoundingClientRect().height; // exact, so the write below changes no size
    if (h > (parseFloat(infoEl.style.minHeight) || 0)) infoEl.style.minHeight = h + "px";
  }).observe(infoEl);
  const infoReset = () => { infoEl.style.minHeight = ""; };
  window.addEventListener("resize", infoReset);

  // ---------------------------------------------------------------- relayout + anchoring
  function anchor() {
    if (!L || !live.size) return null;
    const cx = scroll.scrollLeft + scroll.clientWidth / 2, cy = scroll.scrollTop + scroll.clientHeight / 2;
    let best = -1, bd = Infinity;
    const pick = sel >= 0 && live.has(sel) ? [sel] : live.keys();
    for (const i of pick) {
      const d = Math.hypot(L.nx[i] + L.W / 2 - cx, L.ny[i] + L.H / 2 - cy);
      if (d < bd) { bd = d; best = i; }
    }
    return best < 0 ? null : { i: best, dx: L.nx[best] - scroll.scrollLeft, dy: L.ny[best] - scroll.scrollTop };
  }
  function relayout(keep) {
    const a = keep ? anchor() : null;
    L = computeGeometry();
    clearCards();
    hover = -1; focus = null; // the hovered card is rebuilt; its mouseenter comes with the next move
    plane.style.width = L.width + "px";
    plane.style.height = L.height + "px";
    gutter.hidden = !L.buckets.length;
    gutter.style.height = L.height + "px";
    if (a) { scroll.scrollLeft = L.nx[a.i] - a.dx; scroll.scrollTop = L.ny[a.i] - a.dy; }
    renderMinimap();
    syncControls();
    requestPaint();
  }
  function centreOn(i, smooth) {
    scroll.scrollTo({ left: L.nx[i] + L.W / 2 - scroll.clientWidth / 2, top: L.ny[i] + L.H / 2 - scroll.clientHeight / 2, behavior: smooth ? "smooth" : "auto" });
  }

  /** Go to node i: an instant jump (plain scroll offset assignment, never smooth) that centres it
   *  vertically and scrolls horizontally only as far as needed to show its lane clear of the
   *  gutter; then it is selected and pulses. The next frame costs the same at any distance. */
  let flashTimer = 0;
  function jumpTo(i) {
    const vw = scroll.clientWidth, a = L.nx[i] - L.offX - 24, b = L.nx[i] + L.W + 24;
    if (a < scroll.scrollLeft) scroll.scrollLeft = a; else if (b > scroll.scrollLeft + vw) scroll.scrollLeft = b - vw;
    scroll.scrollTop = L.ny[i] + L.H / 2 - scroll.clientHeight / 2;
    const prev = sel;
    sel = i; flashI = i;
    if (prev >= 0 && live.has(prev)) live.get(prev).className = cardClass(prev);
    const el = live.get(i);
    if (el) { el.className = cardClass(i).replace(" jump", ""); void el.offsetWidth; el.className = cardClass(i); } // restart the pulse
    clearTimeout(flashTimer);
    flashTimer = setTimeout(endFlash, 2000);
    requestPaint(); // also redraws the info bar
  }
  function endFlash() {
    clearTimeout(flashTimer);
    const f = flashI;
    flashI = -1;
    if (live.has(f)) live.get(f).className = cardClass(f);
  }

  // ---------------------------------------------------------------- controls
  function syncControls() {
    for (const [id, v] of [["mode", ui.mode], ["order", ui.order]]) {
      for (const b of $(id).children) { b.classList.toggle("on", b.dataset.v === v); b.setAttribute("aria-checked", b.dataset.v === v); }
    }
    $("detailed").classList.toggle("on", ui.detailed);
    $("detailed").setAttribute("aria-checked", ui.detailed);
    $("detailedLabel").textContent = ui.detailed ? "Detailed cards" : "Compact cards";
    $("gaps").classList.toggle("on", ui.gaps);
    $("gaps").setAttribute("aria-checked", ui.gaps);
    $("minimap").classList.toggle("on", ui.minimap);
    $("minimap").setAttribute("aria-checked", ui.minimap);
    const r = $("cardW");
    r.value = ui.cardW;
    r.style.setProperty("--p", ((ui.cardW - 160) / 240) * 100 + "%");
    $("cardWVal").textContent = ui.cardW + "px";
    $("locate").disabled = !T || T.wc < 0;
  }
  function set(k, v) { ui[k] = v; store.set(k, v); }
  for (const id of ["mode", "order"]) {
    $(id).addEventListener("click", (e) => {
      const b = e.target.closest("button");
      if (!b || ui[id] === b.dataset.v) return;
      set(id, b.dataset.v);
      if (T) relayout(true);
    });
  }
  $("detailed").addEventListener("click", (e) => { e.preventDefault(); set("detailed", !ui.detailed); if (T) relayout(true); });
  $("gaps").addEventListener("click", (e) => { e.preventDefault(); set("gaps", !ui.gaps); syncControls(); requestPaint(); });
  $("minimap").addEventListener("click", (e) => { e.preventDefault(); set("minimap", !ui.minimap); applyMinimap(); syncControls(); });
  $("jumptest").addEventListener("click", () => jumpTest(+Q.get("jumptest") || 100, +(Q.get("seed") || 1)));
  $("scrolltest").addEventListener("click", () => scrollTest(+Q.get("scrolltest") || 240));

  // go to commit: change-id / commit-id prefix, else description substring; ⌘F / Ctrl+F focuses it
  const searchEl = $("search"), listEl = $("searchList");
  let hits = [], active = 0, landed = false; // landed: the last jump went to hits[active], so Enter steps on
  function runSearch() {
    const q = searchEl.value.trim().toLowerCase();
    hits = []; active = 0; landed = false;
    if (!T || !q) { listEl.hidden = true; return; }
    const t0 = performance.now(), M = T.meta;
    if (M && !T.descLower) T.descLower = M.desc.map((s) => s.toLowerCase());
    const idq = /^[0-9a-z]+$/.test(q), ids = [], descs = [];
    let total = 0;
    for (let i = 0; i < T.n; i++) { // stream order ≈ newest first; id hits rank before description hits
      if (idq && ((M && M.change[i].startsWith(q)) || T.b.ids[i].startsWith(q))) { total++; if (ids.length < HITS) ids.push(i); }
      else if (M && T.descLower[i].includes(q)) { total++; if (descs.length < HITS) descs.push(i); }
    }
    hits = ids.concat(descs).slice(0, HITS);
    renderHits(total, performance.now() - t0);
  }
  function renderHits(total, ms) {
    const head = span("gsearch-head", `${total ? fmtN(total) : "no"} match${total === 1 ? "" : "es"}` +
      `${total > hits.length ? ` · first ${hits.length}` : ""} · ${ms.toFixed(1)} ms`);
    const M = T.meta;
    listEl.replaceChildren(head, ...hits.map((i, k) => {
      const b = document.createElement("button");
      b.type = "button"; b.className = "gsr" + (k === active ? " on" : ""); b.dataset.k = k; b.setAttribute("role", "option");
      const id = M ? M.change[i] : T.b.ids[i], bold = M ? Math.max(1, Math.min(id.length, M.plen[i])) : 0;
      const idEl = span("gsr-id"), bEl = document.createElement("b");
      bEl.textContent = id.slice(0, bold);
      idEl.append(bEl, id.slice(bold, M ? 8 : 12));
      b.append(idEl);
      if (M) b.append(span("gsr-id", T.b.ids[i].slice(0, 8)));
      b.append(span("gsr-d" + (M && M.desc[i] ? "" : " is-dim"), M ? M.desc[i] || "(no description set)" : `row ${L.m.row[i]} · lane ${L.lane[i]}`));
      b.append(span("gsr-t", ago(i)));
      return b;
    }));
    listEl.hidden = false;
  }
  function go(k) {
    if (!hits.length) return;
    active = (k + hits.length) % hits.length;
    landed = true;
    jumpTo(hits[active]);
    listEl.hidden = true; // out of the way of the target; ↓/↑ or typing reopens it
  }
  searchEl.addEventListener("input", runSearch);
  searchEl.addEventListener("keydown", (e) => {
    // Enter again = next hit; a list closed by Esc or a click outside, before any jump, still jumps to the highlighted hit
    if (e.key === "Enter") { e.preventDefault(); go(landed && listEl.hidden ? active + (e.shiftKey ? -1 : 1) : active); }
    else if (e.key === "ArrowDown" || e.key === "ArrowUp") {
      e.preventDefault();
      if (!hits.length) return;
      if (!listEl.hidden) { active = (active + (e.key === "ArrowDown" ? 1 : -1) + hits.length) % hits.length; landed = false; }
      listEl.hidden = false;
      for (const x of listEl.querySelectorAll(".gsr")) x.classList.toggle("on", +x.dataset.k === active);
      listEl.querySelector(".gsr.on")?.scrollIntoView({ block: "nearest" });
    } else if (e.key === "Escape") { // not the search input's native clear: Enter keeps stepping through the hits
      e.preventDefault(); e.stopPropagation();
      if (!listEl.hidden) listEl.hidden = true; else searchEl.blur();
    }
  });
  listEl.addEventListener("click", (e) => { const b = e.target.closest(".gsr"); if (b) go(+b.dataset.k); });
  document.addEventListener("pointerdown", (e) => { if (!e.target.closest(".gsearch")) listEl.hidden = true; });
  window.addEventListener("keydown", (e) => {
    if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "f") { e.preventDefault(); searchEl.focus(); searchEl.select(); }
  });
  $("cardW").addEventListener("input", (e) => { set("cardW", +e.target.value); if (T) relayout(true); });
  $("locate").addEventListener("click", () => { if (T && T.wc >= 0) centreOn(T.wc, true); });
  $("dataset").addEventListener("change", (e) => load(e.target.value));
  window.addEventListener("keydown", (e) => { if (e.key === "Escape" && sel >= 0) { sel = -1; restyleCards(); renderInfo(); } });
  scroll.addEventListener("scroll", requestPaint, { passive: true });
  new ResizeObserver(() => { sizeCanvas(); requestPaint(); }).observe(scroll);

  // drag-to-pan on empty canvas (design)
  let pan = null;
  scroll.addEventListener("pointerdown", (e) => {
    if (e.button !== 0 || e.target.closest(".gcard")) return;
    const r = scroll.getBoundingClientRect();
    if (e.clientX - r.left >= scroll.clientWidth || e.clientY - r.top >= scroll.clientHeight) return; // scrollbar
    pan = { x: e.clientX, y: e.clientY, l: scroll.scrollLeft, t: scroll.scrollTop };
    scroll.setPointerCapture(e.pointerId);
    scroll.classList.add("panning");
  });
  scroll.addEventListener("pointermove", (e) => {
    if (!pan) return;
    scroll.scrollLeft = pan.l - (e.clientX - pan.x);
    scroll.scrollTop = pan.t - (e.clientY - pan.y);
  });
  const endPan = () => { pan = null; scroll.classList.remove("panning"); };
  scroll.addEventListener("pointerup", endPan);
  scroll.addEventListener("pointercancel", endPan);

  // ---------------------------------------------------------------- tests: jumps, scrolling ± minimap
  const raf = () => new Promise((r) => requestAnimationFrame(r)); // resolves with the frame's timestamp
  /** Resolves in a task queued now; queued from a rAF callback it runs after that frame's rendering. */
  const afterRender = () => new Promise((r) => { const c = new MessageChannel(); c.port1.onmessage = () => r(performance.now()); c.port2.postMessage(0); });
  const task = () => new Promise((r) => setTimeout(r, 0));
  function mulberry32(a) {
    return () => { a = (a + 0x6d2b79f5) | 0; let t = Math.imul(a ^ (a >>> 15), 1 | a); t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t; return ((t ^ (t >>> 14)) >>> 0) / 4294967296; };
  }
  function summary(a) {
    const s = Float64Array.from(a).sort(), n = s.length;
    return { med: (s[(n - 1) >> 1] + s[n >> 1]) / 2, p95: s[Math.max(0, Math.ceil(0.95 * n) - 1)], max: s[n - 1] };
  }
  let testing = false;

  /** N jumps to uniformly random nodes. Each starts from a plain task (like a keydown handler), after
   *  two idle frames. next = scroll assignment → the rAF after the frame that painted it (2 rAFs:
   *  vsync-quantised, what the user waits); work = that frame's main-thread time, from its rAF
   *  timestamp to a task queued behind its rendering (our paint JS + style/layout/paint of the new
   *  cards); js = our paint() alone; created/removed = DOM cards. */
  async function jumpTest(N = 100, seed = 1) {
    if (!T || !L || testing) return null;
    testing = true;
    const rnd = mulberry32(seed), rows = [];
    try {
      for (let k = 0; k < N; k++) {
        const i = Math.floor(rnd() * T.n);
        endFlash(); // the last target's pulse repaints every frame: the idle frames would not be idle
        await raf();
        const tsIdle = await raf(), idle = (await afterRender()) - tsIdle; // an idle frame: the pipeline's floor here
        await task();
        const c0 = counters.created, r0 = counters.removed, y0 = scroll.scrollTop;
        const t0 = performance.now();
        jumpTo(i);
        const ts = await raf();          // frame 1: the paint (queued by jumpTo) has just run
        const js = stats.paintMs;
        const tr = await afterRender();  // behind frame 1's rendering
        await raf();                     // frame 2 begins: frame 1 is on screen
        rows.push({ i, dist: Math.abs(scroll.scrollTop - y0), next: performance.now() - t0, work: tr - ts, idle, js,
          created: counters.created - c0, removed: counters.removed - r0, cards: live.size });
      }
    } finally { testing = false; }
    const col = (k) => rows.map((r) => r[k]);
    const pearson = (a, b) => {
      const n = a.length, ma = a.reduce((s, v) => s + v, 0) / n, mb = b.reduce((s, v) => s + v, 0) / n;
      let sab = 0, saa = 0, sbb = 0;
      for (let k = 0; k < n; k++) { sab += (a[k] - ma) * (b[k] - mb); saa += (a[k] - ma) ** 2; sbb += (b[k] - mb) ** 2; }
      return sab / Math.sqrt(saa * sbb || 1);
    };
    const res = { dataset: T.b.name, mode: ui.mode, order: ui.order, detailed: ui.detailed, cardW: ui.cardW, minimap: ui.minimap,
      jumps: N, seed, viewport: `${scroll.clientWidth}x${scroll.clientHeight}`, next: summary(col("next")), work: summary(col("work")),
      idle: summary(col("idle")), js: summary(col("js")), created: summary(col("created")), removed: summary(col("removed")),
      cards: summary(col("cards")), distPx: summary(col("dist")), r_dist_work: pearson(col("dist"), col("work")), r_dist_js: pearson(col("dist"), col("js")) };
    stats.jump = res;
    window.__viewer.lastJumpTest = { res, rows };
    console.log("[jump test]", JSON.stringify(res));
    console.table(rows.slice(0, 20));
    renderInfo();
    return res;
  }

  /** frames × step px of scrolling down (bouncing at the ends), once with the minimap and once
   *  without (strip hidden, but the scroll area keeps its width, so both passes paint the same
   *  viewport), from the same offset; per frame the main-thread time (rAF timestamp → task behind the
   *  rendering), our paint JS, the overlay update and the rAF interval. Plus the overlay update in
   *  a 20k-call loop, since one call is far below the 0.1 ms timer resolution. */
  async function scrollTest(frames = 240, step = 64, order = [true, false]) {
    if (!T || !L || testing) return null;
    testing = true;
    const was = ui.minimap, x = scroll.scrollLeft, y = scroll.scrollTop, res = { dataset: T.b.name, mode: ui.mode, frames, step };
    try {
      for (const on of order) {
        ui.minimap = on; applyMinimap(); syncControls();
        if (!on) $("view").classList.add("mm-on"); // the wider viewport would paint more cards and edges
        await raf(); await raf(); await raf();
        scroll.scrollLeft = x; scroll.scrollTop = y;
        await raf(); await raf();
        const work = [], js = [], mmjs = [], dt = [];
        let dir = 1, prev = await raf();
        for (let f = 0; f < frames; f++) {
          const ts = await raf();
          if (dir > 0 && scroll.scrollTop + scroll.clientHeight + step >= scroll.scrollHeight) dir = -1;
          else if (dir < 0 && scroll.scrollTop - step < 0) dir = 1;
          scroll.scrollTop += dir * step;             // painted in the next frame (scroll event → rAF)
          const tr = await afterRender();
          if (f > 0) { work.push(tr - ts); js.push(stats.paintMs); mmjs.push(stats.mmMs); dt.push(ts - prev); }
          prev = ts;
        }
        res[on ? "with" : "without"] = { work: summary(work), js: summary(js), overlayJs: summary(mmjs), interval: summary(dt) };
      }
      ui.minimap = true; applyMinimap();
      await raf(); await raf(); await raf();
      const t0 = performance.now(), R = 20000;
      for (let k = 0; k < R; k++) paintMinimapView(x, (k * 97) % Math.max(1, L.height), scroll.clientWidth, scroll.clientHeight);
      res.overlayUs = ((performance.now() - t0) / R) * 1000;
    } finally {
      ui.minimap = was; applyMinimap(); syncControls();
      scroll.scrollLeft = x; scroll.scrollTop = y;
      testing = false;
    }
    stats.scroll = res;
    window.__viewer.lastScrollTest = res;
    console.log("[scroll test]", JSON.stringify(res));
    renderInfo();
    return res;
  }

  // ---------------------------------------------------------------- loading
  const msg = (text) => { const m = $("msg"); m.textContent = text || ""; m.hidden = !text; };
  async function load(name) {
    msg(`Loading ${name}…`);
    try {
      const res = await fetch(`data/${encodeURIComponent(name)}.json`);
      if (!res.ok) throw new Error(`data/${name}.json: HTTP ${res.status}`);
      const b = await res.json();
      if (b.v !== 2) throw new Error(`bundle version ${b.v}, the viewer needs 2: re-run tools/viewer-bundle.mjs`);
      T = prepare(b);
      set("dataset", name);
      $("dataset").value = name;
      hover = -1; sel = -1; focus = null; flashI = -1;
      hits = []; listEl.hidden = true; searchEl.value = "";
      stats.jump = null; stats.scroll = null;
      infoReset();
      relayout(false);
      if (T.wc >= 0) centreOn(T.wc, false); else { scroll.scrollLeft = 0; scroll.scrollTop = 0; }
      msg("");
    } catch (err) {
      msg(String(err.message || err));
      throw err;
    }
  }
  async function start() {
    applyMinimap();
    syncControls();
    sizeCanvas();
    let index;
    try {
      const res = await fetch("data/index.json");
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      index = await res.json();
    } catch (err) {
      msg(`No data/index.json (${err.message}). Run tools/viewer-bundle.mjs, and serve this folder over http.`);
      return;
    }
    const sel_ = $("dataset");
    for (const d of index.datasets) {
      const o = document.createElement("option");
      o.value = d.name;
      o.textContent = `${d.name} — ${d.n.toLocaleString("en-US")} commits${d.meta ? "" : " (ids only)"}`;
      sel_.append(o);
    }
    if (!index.datasets.length) { msg("data/index.json lists no datasets"); return; }
    const name = index.datasets.some((d) => d.name === ui.dataset) ? ui.dataset : index.datasets[0].name;
    await load(name);
    await raf(); await raf();
    if (+Q.get("jumptest") > 0) await jumpTest(+Q.get("jumptest"), +(Q.get("seed") || 1));
    if (+Q.get("scrolltest") > 0) await scrollTest(+Q.get("scrolltest"));
  }
  // debug handle for checks from the devtools console (read-only use, plus the tests)
  window.__viewer = { ui, get T() { return T; }, get L() { return L; }, get mm() { return mm; }, edgePts, crossings, get stats() { return stats; },
    relayout, load, renderMinimap, jumpTo, jumpTest, scrollTest, set(k, v) { ui[k] = v; if (k === "minimap") applyMinimap(); else relayout(true); } };
  start();
})();
