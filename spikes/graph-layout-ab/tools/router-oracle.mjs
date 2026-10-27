#!/usr/bin/env node
// SPDX-License-Identifier: MIT
//
// Story 4.15 — the router oracle (docs/graph-layout.md §7.2, amended 2026-10-27; §14): the
// product's line router B (packages/zanshin_core/lib/src/graph_layout/router.dart) against the
// export's own routeAll (graph-layout.jsx = GL at e74ced3) on GL's own grids, so differences in lane
// order never leak in.
//
//   node tools/router-oracle.mjs [--bin <router_cli>]   (from the spike root; sets TZ=UTC itself)
//
// <router_cli> = `dart compile exe benchmark/router_cli.dart` in packages/zanshin_core (default:
// outputs/bin/router_cli). Cases: the sample (default, all; optimize false) and the Lines Study's
// PRESETS 1/2/3 × FAN 0/4/8 (groupStacks(…, "default", []).list, optimize true), each at W 160/240/400 ×
// H 40/62 × free/compact. Per case GL's grid — node order, col, row = u (free, U 16) or u / 16
// (compact, U 1), parents in order with their kind, parentCount = the commit's parents.length — goes
// to `router_cli oracle`; per edge the kind, the gutter, the polyline (±1e-6, so the exit and entry
// offsets and the tracks) and the bridges are compared. A case is `equal`, or every class and slot
// difference is explained:
//   - unit rule: GL's decision (its pixel test, GL:162-190) and the same decision under §14.2's unit
//     rule differ, and the router took the unit rule's — listed with the cards' unit distances;
//   - shared entry: GL groups dashed edges by its `via` (GL:212), §14 by parentCount = 1.
// The other geometry differences of such a case count as consequential. Writes
// outputs/oracle/router-{cases,dart,report}.json; exits 1 on an unexplained difference.

process.env.TZ = "UTC";

import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { loadLayout } from "./design-layout.mjs";

const spike = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const args = process.argv.slice(2);
if (args.length && !(args.length === 2 && args[0] === "--bin")) throw new Error("usage: node tools/router-oracle.mjs [--bin <router_cli>]");
const bin = args.length ? path.resolve(args[1]) : path.join(spike, "outputs/bin/router_cli");
if (!fs.existsSync(bin)) throw new Error(`missing ${bin}: dart compile exe benchmark/router_cli.dart -o ${bin} (in packages/zanshin_core)`);

const G = { gapX: 56, gapY: 48, pad: 56 }; // GL:8
const U = 16;
const EPS = 1e-6;
const KIND = { straight: "straight", fork: "fork", merge1: "merge-adjacent", mergeUp: "merge-up", gutter: "gutter" };

const d = loadLayout(undefined, { kinds: true, study: true });

// ---------- the cases ----------
const cases = [];
const metrics = [];
for (const W of [160, 240, 400]) for (const H of [40, 62]) for (const mode of ["free", "compact"]) metrics.push({ W, H, mode });
for (const rev of ["default", "all"]) {
  for (const { W, H, mode } of metrics) {
    cases.push({ name: `sample-${rev}-${mode}-W${W}-H${H}`, category: "sample", W, H, mode, L: d.computeLayout(d.GRAPH_COMMITS, rev, W, H, mode, { optimize: false }) });
  }
}
for (const preset of d.PRESETS) {
  for (const fan of [0, 4, 8]) {
    const base = [...d.GRAPH_COMMITS, ...d.FAN.slice(0, fan)];
    const byId = new Map(base.map((c) => [c.id, c]));
    const tgt = byId.get(d.TARGET);
    const commits = base.map((c) => (c.id === tgt.id && preset.extra.length
      ? { ...c, parents: [...c.parents, ...preset.extra.filter((x) => !c.parents.includes(x) && byId.has(x))], isMerge: true } : c));
    const list = d.groupStacks(commits, "default", []).list;
    for (const { W, H, mode } of metrics) {
      cases.push({ name: `study-p${preset.n}-fan${fan}-${mode}-W${W}-H${H}`, category: "study", W, H, mode, L: d.computeLayout(list, "default", W, H, mode, { optimize: true }) });
    }
  }
}

// ---------- GL's grid → the router's input ----------
for (const k of cases) {
  const { L, mode } = k;
  const index = new Map(L.nodes.map((n, i) => [n.id, i]));
  k.index = index;
  k.edges = [];
  L.nodes.forEach((n, i) => n.parents.forEach((pp) => k.edges.push([index.get(pp.id), i, pp.skipped ? 1 : 0])));
  if (k.edges.length !== L.edges.length) throw new Error(`${k.name}: ${k.edges.length} parent edges, GL routed ${L.edges.length}`);
  L.edges.forEach((e, q) => {
    if (L.nodes[k.edges[q][0]].id !== e.from || L.nodes[k.edges[q][1]].id !== e.to) throw new Error(`${k.name}: GL's edge ${q} is not in parent order`);
  });
  k.input = {
    name: k.name,
    width: k.W,
    height: k.H,
    free: mode === "free",
    unit: mode === "free" ? U : 1,
    rows: L.nodes.map((n) => (mode === "free" ? n.u : n.u / U)),
    cols: L.nodes.map((n) => n.col),
    parent_counts: L.nodes.map((n) => n.c.parents.length),
    edges: k.edges,
  };
  if (k.input.rows.some((r) => !Number.isInteger(r))) throw new Error(`${k.name}: a non-integer row`);
}
const outDir = path.join(spike, "outputs/oracle");
fs.mkdirSync(outDir, { recursive: true });
const casesFile = path.join(outDir, "router-cases.json");
const dartFile = path.join(outDir, "router-dart.json");
fs.writeFileSync(casesFile, JSON.stringify({ cases: cases.map((k) => k.input) }) + "\n");
const r = spawnSync(bin, ["oracle", casesFile, dartFile], { encoding: "utf8" });
if (r.status !== 0) throw new Error(`router_cli oracle: exit ${r.status} ${r.stderr}`);
const dart = JSON.parse(fs.readFileSync(dartFile, "utf8")).cases;

// ---------- GL's class decision with a pluggable "clear" (GL:173-190) ----------
function decide(L, W, H, free, e, clear) {
  const p = L.N.get(e.from), n = L.N.get(e.to), i = n.parents.findIndex((pp) => pp.id === e.from);
  const colW = W + G.gapX;
  const colFree = (col, u0, u1) => !L.nodes.some((o) => o.col === col && o.u > u0 && o.u < u1);
  let side = Math.sign(n.cx - p.cx);
  let kind = !side ? (i === 0 && colFree(p.col, p.u, n.u) ? "straight" : "gutter")
    : i === 0 ? (colFree(n.col, p.u, n.u) ? "fork" : "gutter")
    : n.u === p.u + U ? "merge1"
    : colFree(p.col, p.u, n.u) ? "mergeUp" : "gutter";
  if (!side) side = 1;
  const pBand = [p.y - G.gapY, p.y], nBand = [n.y + H, n.y + H + G.gapY];
  const kk = Math.abs(n.col - p.col);
  const xs = kk ? [...Array(kk).keys()].map((j) => n.cx - side * colW * (j + 0.5)) : [n.cx + side * colW / 2];
  const direct = !free ? true : kind === "mergeUp" ? clear(nBand, p.cx, n.cx, p, n) : kind === "fork" || kind === "merge1" ? clear(pBand, p.cx, n.cx, p, n) : true;
  let gx = null;
  if (kind === "gutter" || !direct) {
    const x = !free ? xs[0] : xs.find((g) => clear(pBand, p.cx, g, p, n) && clear(nBand, g, n.cx, p, n));
    if (kind === "gutter" || x != null) { kind = "gutter"; gx = x != null ? x : xs[0]; }
  }
  return { kind, gutter: gx == null ? null : Math.round((2 * (gx - G.pad - W / 2)) / colW) };
}
/** GL's pixel test (GL:163-172) in free. */
const pixelClear = (L, W, H) => (band, x0, x1) => {
  const a = Math.min(x0, x1), b = Math.max(x0, x1);
  let ivs = [[band[0] + 12, band[1] - 12]];
  L.nodes.forEach((o) => {
    if (o.x >= b + 4 || o.x + W <= a - 4) return;
    const c0 = o.y - 10, c1 = o.y + H + 10;
    ivs = ivs.flatMap(([l, h]) => (c1 <= l || c0 >= h ? [[l, h]] : [[l, c0], [c1, h]].filter(([x, y]) => y >= x)));
  });
  return ivs.length > 0;
};
/** §14.2's unit rule: the cards in a column strictly between the run's ends, 1–12 units off its band. */
function unitCards(L, W, band, x0, x1, p, n) {
  const pos = (x) => Math.round((2 * (x - G.pad - W / 2)) / (W + G.gapX));
  const A = Math.min(pos(x0), pos(x1)), B = Math.max(pos(x0), pos(x1));
  const above = band[1] === p.y; // the band above the parent
  return L.nodes.filter((o) => {
    if (!(2 * o.col > A && 2 * o.col < B)) return false;
    const dist = above ? o.u - p.u : n.u - o.u;
    return dist >= 1 && dist <= 12;
  }).map((o) => ({ id: o.id, units: above ? o.u - p.u : n.u - o.u, band: above ? "above parent" : "below child" }));
}
const unitClear = (L, W) => (band, x0, x1, p, n) => unitCards(L, W, band, x0, x1, p, n).length === 0;

// ---------- compare ----------
const near = (a, b) => Math.abs(a - b) <= EPS;
const cutsOf = (list) => list.map((c) => [c.x, c.y, c.w, c.h]).sort((a, b) => a[0] - b[0] || a[1] - b[1] || a[2] - b[2]);
const report = [];
const byCategory = {};
let failed = false;
cases.forEach((k, ci) => {
  const { L, W, H, mode } = k, free = mode === "free", out = dart[ci];
  if (out.name !== k.name) throw new Error(`router_cli answered ${out.name} for ${k.name}`);
  const unitRule = [], verdicts = [], shared = [], unexplained = [], consequential = [];
  // classes
  L.edges.forEach((e, q) => {
    const gl = decide(L, W, H, free, e, pixelClear(L, W, H));
    if (KIND[gl.kind] !== KIND[e.kind]) throw new Error(`${k.name}: the oracle's GL decision (${gl.kind}) is not GL's (${e.kind}) on edge ${q}`);
    const unit = free ? decide(L, W, H, free, e, unitClear(L, W)) : gl;
    const ours = { kind: out.kinds[q], gutter: out.gutters[q] };
    const same = (x) => KIND[x.kind] === ours.kind && (x.gutter ?? null) === ours.gutter;
    // I2's listing: a direct run the two tests judge differently, even when the class ends up equal
    // (e.g. the unit rule blocks it, every gutter is blocked too, and it stays direct as a fallback).
    if (free && ["fork", "merge1", "mergeUp"].includes(e.kind)) {
      const p = L.N.get(e.from), n = L.N.get(e.to);
      const band = e.kind === "mergeUp" ? [n.y + H, n.y + H + G.gapY] : [p.y - G.gapY, p.y];
      const px = pixelClear(L, W, H)(band, p.cx, n.cx), un = unitClear(L, W)(band, p.cx, n.cx, p, n);
      if (px !== un) verdicts.push({ edge: q, from: e.from, to: e.to, kind: e.kind, pixel_clear: px, unit_clear: un, cards: unitCards(L, W, band, p.cx, n.cx, p, n) });
    }
    if (!same(unit)) unexplained.push({ edge: q, what: "class", gl, unit, ours });
    else if (!same(gl)) {
      const p = L.N.get(e.from), n = L.N.get(e.to);
      const pBand = [p.y - G.gapY, p.y], nBand = [n.y + H, n.y + H + G.gapY];
      // The cards between the two columns that the unit rule counts, and GL's pixel verdict on each band.
      const cards = [...unitCards(L, W, pBand, p.cx, n.cx, p, n), ...unitCards(L, W, nBand, p.cx, n.cx, p, n)];
      const pixel = { above_parent: pixelClear(L, W, H)(pBand, p.cx, n.cx), below_child: pixelClear(L, W, H)(nBand, p.cx, n.cx) };
      unitRule.push({ edge: q, from: e.from, to: e.to, gl: { kind: gl.kind, gutter: gl.gutter }, ours, cards, gl_direct_clear: pixel });
    }
  });
  // shared entries: GL by `via` (≥ 2 dashed edges through one hidden parent), §14 by parentCount = 1
  L.nodes.forEach((n, i) => {
    const vias = n.parents.filter((pp) => pp.skipped).map((pp) => pp.via);
    const glShares = vias.some((v) => vias.indexOf(v) !== vias.lastIndexOf(v));
    const ourShares = n.c.parents.length === 1 && vias.length >= 2;
    if (glShares !== ourShares) shared.push({ node: n.id, gl: glShares, ours: ourShares, dashed: vias.length, parent_count: n.c.parents.length });
  });
  // geometry
  const cutsByEdge = L.edges.map(() => []);
  out.bridges.forEach(([x, y, h, v, vb]) => cutsByEdge[vb ? v : h].push(vb ? { x: x - 5, y: y - 6, w: 10, h: 12 } : { x: x - 6, y: y - 5, w: 12, h: 10 }));
  L.edges.forEach((e, q) => {
    const gl = e.pts.flat(), ours = out.points[q];
    const diffs = [];
    if (gl.length !== ours.length || gl.some((x, j) => !near(x, ours[j]))) {
      const p = L.N.get(e.from), n = L.N.get(e.to);
      diffs.push({ what: "polyline", exit: [e.pts[0][0] - p.cx, ours[0] - p.cx], entry: [e.pts.at(-1)[0] - n.cx, ours.at(-2) - n.cx], gl, ours });
    }
    const gc = cutsOf(e.cuts), oc = cutsOf(cutsByEdge[q]);
    if (gc.length !== oc.length || gc.some((c, j) => c.some((x, t) => !near(x, oc[j][t])))) diffs.push({ what: "bridges", gl: gc, ours: oc });
    if (diffs.length) consequential.push({ edge: q, from: e.from, to: e.to, diffs });
  });
  const explained = unitRule.length + shared.length > 0;
  if (!explained && consequential.length) unexplained.push(...consequential.map((c) => ({ ...c, what: "geometry" })));
  const status = unexplained.length ? "unexplained" : explained ? "explained" : "equal";
  if (unexplained.length) failed = true;
  const row = {
    name: k.name, category: k.category, status, nodes: L.nodes.length, edges: L.edges.length,
    unit_rule: unitRule, unit_rule_verdicts: verdicts, shared_entry: shared, consequential: explained ? consequential.length : 0, unexplained,
    reports: { direct_fallbacks: out.direct_fallbacks, overfull_gutters: out.overfull_gutters, overfull_clusters: out.overfull_clusters, unavoidable_crossings: out.unavoidable_crossings },
  };
  report.push(row);
  const cat = (byCategory[`${k.category} ${mode} H${H}`] ||= { equal: 0, explained: 0, unexplained: 0, unit_rule_edges: 0, unit_rule_verdicts: 0, shared_entry_nodes: 0, consequential_edges: 0 });
  cat[status]++;
  cat.unit_rule_edges += unitRule.length;
  cat.unit_rule_verdicts += verdicts.length;
  cat.shared_entry_nodes += shared.length;
  cat.consequential_edges += row.consequential;
});
fs.writeFileSync(path.join(outDir, "router-report.json"), JSON.stringify({ design: "e74ced3", summary: byCategory, cases: report }, null, 1) + "\n");
for (const [cat, s] of Object.entries(byCategory)) {
  console.log(`${cat}: equal ${s.equal}, explained ${s.explained}, unexplained ${s.unexplained} (unit-rule edges ${s.unit_rule_edges}, run verdicts that differ ${s.unit_rule_verdicts}, shared-entry nodes ${s.shared_entry_nodes}, consequential edges ${s.consequential_edges})`);
}
for (const row of report.filter((x) => x.status === "unexplained")) console.log(`FAIL ${row.name}: ${JSON.stringify(row.unexplained[0])}`);
console.log(`${failed ? "FAIL" : "ok"}: ${cases.length} cases → outputs/oracle/router-report.json`);
if (failed) process.exitCode = 1;
