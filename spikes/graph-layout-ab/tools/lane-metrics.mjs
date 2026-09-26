#!/usr/bin/env node
// Lane-order quality metrics for layout outputs (SPEC §3 files; the input is not needed).
//
//   node tools/lane-metrics.mjs [--json] [--node IDX]… <output.json>…
//
// Per output file:
// - lanes      the output's `lanes` (every order uses exactly lanes columns 0 … lanes − 1).
// - cross      H×V crossings of the routed edges, drawn the way viewer/viewer.js (the design's
//              routeEdges) draws them, at the viewer's defaults: card W = 240, H = 62 (detailed),
//              gapX = 56, gapY = 48. A crossing is a horizontal segment and a vertical segment that
//              intersect with 1 px tolerance and whose edges share no endpoint node (the design's
//              analyzeEdges, the viewer's `crossings`).
// - hlen       total horizontal run length in columns: Σ |col(p) − col(i)| over the non-straight
//              edges.
// - maxW       max width: the largest rightmost occupied column + 1 over the row units. It equals
//              lanes whenever the last column holds a node, which every order guarantees.
// - meanW      mean per-row width: the rightmost occupied column + 1, averaged over the row units
//              that hold a node or a vertical edge segment.
// - holes      hole area: per row unit, the empty columns left of the rightmost occupied one;
//              summed over the row units and divided by U, i.e. in column × row pitches.
// - holes%     holes · U / Σ (rightmost + 1): the empty share of the occupied width.
//
// Occupancy (grid terms, independent of W and H): node i holds (y(i), col(i)); a layout edge
// (p, i) holds its vertical column at every unit y(p) < r < y(i). That column is col(p) for
// straight and merge (the run up the parent's lane) and col(i) for branch_off (the run up the
// child's lane). The merge's short run into the child lies inside the row gap and is ignored.
//
// --node IDX prints, per output, node IDX's row and column and its "left slack": the leftmost
// column c whose units y(fp) < r ≤ y(i) are all empty apart from IDX's own run (so the node and
// its incoming vertical could have sat in c). Slack = col − c, 0 if no column further left is free.

import fs from "node:fs";
import path from "node:path";

const V = { W: 240, H: 62, gapX: 56, gapY: 48, pad: 56 };

function usage(msg) {
  if (msg) console.error(msg);
  console.error("usage: node tools/lane-metrics.mjs [--json] [--node IDX]… <output.json>…");
  process.exit(2);
}

/** The viewer's node positions and edge polylines (viewer.js computeGeometry / edgePts). */
function geometry(o) {
  const n = o.nodes.length, U = o.unit, pitch = V.H + V.gapY;
  const maxU = n ? o.rows - U : 0;
  const nx = new Float64Array(n), ny = new Float64Array(n);
  for (let i = 0; i < n; i++) {
    nx[i] = V.pad + o.nodes[i].col * (V.W + V.gapX);
    ny[i] = V.pad + ((maxU - o.nodes[i].row) / U) * pitch;
  }
  const pts = o.edges.map((e) => {
    const pcx = nx[e.from] + V.W / 2, ncx = nx[e.to] + V.W / 2, outY = ny[e.from], inY = ny[e.to] + V.H;
    if (e.route === "straight") return [pcx, outY, ncx, inY];
    if (e.route === "merge") { const my = inY + V.gapY * 0.4; return [pcx, outY, pcx, my, ncx, my, ncx, inY]; }
    const sx = pcx + (ncx > pcx ? 1 : -1) * V.W * 0.28, hy = outY - V.gapY * 0.4;
    return [sx, outY, sx, hy, ncx, hy, ncx, inY];
  });
  return pts;
}

/** H×V crossings over all edges (viewer `crossings`, whole graph instead of the viewport). */
function crossings(o) {
  const pts = geometry(o);
  const hs = [], vs = [];
  pts.forEach((P, k) => {
    for (let q = 2; q < P.length; q += 2) {
      const x1 = P[q - 2], y1 = P[q - 1], x2 = P[q], y2 = P[q + 1];
      if (x1 === x2 && y1 === y2) continue;
      if (y1 === y2) hs.push({ y: y1, a: Math.min(x1, x2), b: Math.max(x1, x2), k });
      else vs.push({ x: x1, a: Math.min(y1, y2), b: Math.max(y1, y2), k });
    }
  });
  // Group the verticals by x; per group sorted by a, with a prefix max of b to stop early.
  vs.sort((u, v) => u.x - v.x || u.a - v.a);
  const groups = [];
  for (let s = 0; s < vs.length;) {
    let t = s;
    while (t < vs.length && vs[t].x === vs[s].x) t++;
    const g = vs.slice(s, t), pmax = new Float64Array(g.length);
    let m = -Infinity;
    g.forEach((v, j) => { m = Math.max(m, v.b); pmax[j] = m; });
    groups.push({ x: vs[s].x, g, a: Float64Array.from(g, (v) => v.a), pmax });
    s = t;
  }
  const gx = Float64Array.from(groups, (g) => g.x);
  const E = o.edges;
  let count = 0;
  for (const h of hs) {
    const af = E[h.k].from, at = E[h.k].to;
    for (let s = upperBound(gx, h.a + 1); s < groups.length && groups[s].x < h.b - 1; s++) {
      const G = groups[s];
      // verticals with a < y − 1, scanned downwards while some earlier one still reaches y + 1
      for (let j = lowerBound(G.a, h.y - 1) - 1; j >= 0 && G.pmax[j] > h.y + 1; j--) {
        const v = G.g[j];
        if (!(h.y > v.a + 1 && h.y < v.b - 1)) continue;
        const bf = E[v.k].from, bt = E[v.k].to;
        if (af === bf || at === bt || af === bt || at === bf) continue;
        count++;
      }
    }
  }
  return count;
}

function lowerBound(a, v) { let lo = 0, hi = a.length; while (lo < hi) { const mid = (lo + hi) >> 1; if (a[mid] < v) lo = mid + 1; else hi = mid; } return lo; }
function upperBound(a, v) { let lo = 0, hi = a.length; while (lo < hi) { const mid = (lo + hi) >> 1; if (a[mid] <= v) lo = mid + 1; else hi = mid; } return lo; }

/** Occupancy intervals [lo, hi] (inclusive units) per column: nodes and vertical edge runs. */
function occupancy(o, skipEdge = -1, skipNode = -1) {
  const iv = [];
  o.nodes.forEach((x, i) => { if (i !== skipNode) iv.push([x.col, x.row, x.row]); });
  o.edges.forEach((e, k) => {
    if (k === skipEdge) return;
    const p = o.nodes[e.from], c = o.nodes[e.to];
    if (c.row - p.row < 2) return;
    iv.push([e.route === "branch_off" ? c.col : p.col, p.row + 1, c.row - 1]);
  });
  return iv;
}

/** maxW, meanW, holes, holes% by a sweep over the occupancy events. */
function widthMetrics(o) {
  const L = o.lanes, U = o.unit;
  const ev = [];
  for (const [c, lo, hi] of occupancy(o)) { ev.push([lo, c, 1]); ev.push([hi + 1, c, -1]); }
  ev.sort((a, b) => a[0] - b[0]);
  const cnt = new Int32Array(L);
  let occ = 0, right = -1, units = 0, sumW = 0, holes = 0, maxW = 0;
  for (let s = 0; s < ev.length;) {
    const u = ev[s][0];
    for (; s < ev.length && ev[s][0] === u; s++) {
      const [, c, d] = ev[s];
      if (d > 0) { if (cnt[c]++ === 0) occ++; if (c > right) right = c; }
      else if (--cnt[c] === 0) { occ--; if (c === right) while (right >= 0 && cnt[right] === 0) right--; }
    }
    const span = s < ev.length ? ev[s][0] - u : 0;
    if (occ > 0 && span > 0) { units += span; sumW += (right + 1) * span; holes += (right + 1 - occ) * span; maxW = Math.max(maxW, right + 1); }
  }
  return { units, maxW, meanW: units ? sumW / units : 0, holes: holes / U, holesPct: sumW ? (100 * holes) / sumW : 0 };
}

/** Node idx: row, col and its left slack (see the header). */
function nodeSlack(o, idx) {
  const x = o.nodes[idx];
  if (!x) return null;
  const k = o.edges.findIndex((e) => e.to === idx); // first parent edge: edges are ordered by (child, pos)
  const fpRow = k >= 0 ? o.nodes[o.edges[k].from].row : x.row - 1;
  const lo = fpRow + 1, hi = x.row;
  const busy = new Uint8Array(o.lanes);
  for (const [c, a, b] of occupancy(o, k >= 0 && o.edges[k].route === "branch_off" ? k : -1, idx)) {
    if (a <= hi && b >= lo) busy[c] = 1;
  }
  let free = x.col;
  for (let c = 0; c < x.col; c++) if (!busy[c]) { free = c; break; }
  return { idx, row: x.row, lane: x.lane, col: x.col, freeCol: free, slack: x.col - free };
}

const argv = process.argv.slice(2);
const opts = { json: false, nodes: [], files: [] };
for (let i = 0; i < argv.length; i++) {
  const a = argv[i];
  if (a === "--json") opts.json = true;
  else if (a === "--node") { const v = Number(argv[++i]); if (!Number.isInteger(v) || v < 0) usage("--node needs an index"); opts.nodes.push(v); }
  else if (a.startsWith("--")) usage(`unknown flag ${a}`);
  else opts.files.push(a);
}
if (!opts.files.length) usage();

const rows = [];
for (const f of opts.files) {
  const o = JSON.parse(fs.readFileSync(f, "utf8"));
  let hlen = 0;
  for (const e of o.edges) if (e.route !== "straight") hlen += Math.abs(o.nodes[e.from].col - o.nodes[e.to].col);
  const w = widthMetrics(o);
  const r = {
    file: path.basename(f), mode: o.mode, order: o.order, n: o.nodes.length, lanes: o.lanes,
    cross: crossings(o), hlen, maxW: w.maxW, meanW: +w.meanW.toFixed(3), holes: +w.holes.toFixed(1), holesPct: +w.holesPct.toFixed(1),
    nodes: opts.nodes.map((i) => nodeSlack(o, i)),
  };
  rows.push(r);
}

if (opts.json) {
  for (const r of rows) console.log(JSON.stringify(r));
} else {
  const head = ["file", "mode", "order", "n", "lanes", "cross", "hlen", "maxW", "meanW", "holes", "holes%"];
  const cells = rows.map((r) => [r.file, r.mode, r.order, r.n, r.lanes, r.cross, r.hlen, r.maxW, r.meanW.toFixed(2), r.holes.toFixed(1), r.holesPct.toFixed(1)].map(String));
  const w = head.map((h, k) => Math.max(h.length, ...cells.map((c) => c[k].length)));
  console.log(head.map((h, k) => h.padEnd(w[k])).join(" | "));
  console.log(w.map((x) => "-".repeat(x)).join("-|-"));
  for (const c of cells) console.log(c.map((v, k) => (k >= 3 ? v.padStart(w[k]) : v.padEnd(w[k]))).join(" | "));
  for (const r of rows) for (const x of r.nodes) {
    if (x) console.log(`${r.file}: node ${x.idx} row ${x.row} lane ${x.lane} col ${x.col}; leftmost free column over its run ${x.freeCol} (slack ${x.slack})`);
  }
}
