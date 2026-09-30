#!/usr/bin/env node
// SPEC.md §7.2 — the design as oracle. Runs the design's own computeLayout (extracted BY NAME
// from graph-view.jsx together with G, LADDER, timeBucket, roundedPath, routeEdges, analyzeEdges
// and optimizeLanes, evaluated after graph-data.js with window = globalThis under TZ=UTC; both
// read from git at the pinned export, tools/design-source.mjs) with Lane order = Greedy
// (opts.optimize = false) for rev ∈ {default, all} × layout ∈ {compact, time}, maps each result
// into the spike's OUTPUT shape (§3) and compares it with the Rust and Dart `layout` outputs for
// inputs/design-<rev>.json.
//
//   node tools/js_oracle.mjs [--fuzz N] [--seed S]   (from the spike root; build both binaries first)
//
// Writes outputs/oracle/design-<rev>.<mode>.greedy.json and lists EVERY difference.
// Then, for information only (not a pass/fail check, D5): the design's own optimiser against
// our `optimized` column order, scored with the design's cost (GV:103-111), and the SPEC §7.2
// expectations for what the oracle cannot check.
//
// --fuzz N additionally feeds N random design-shaped commit graphs (hidden commits → indirect /
// missing edges via the design's own DFS, priority ties, non-monotonic timestamps) through the
// same pipeline. Differences are classified: in `time`, a difference is D1 (the topological
// clamp) iff the output equals the design run on D1-clamped timestamps; every other difference
// is a bug.
// Cases the converter rejects because of the design's duplicate-parent defect are skipped.
// Exit code 1 on any unexplained difference.

import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { loadDesign, designInput, validate } from "./design-input.mjs"; // sets TZ=UTC on import
import { rng, MIN, HOUR, DAY, STEPS } from "./fuzz.mjs";

const spike = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const BIN = {
  rust: path.join(spike, "rust/target/release/graph-layout"),
  dart: path.join(spike, "dart/build/graph_layout"),
};
const W = 240, H = 62; // the design's card size; SPEC D6: it cannot change rows, lanes or cols
const argv = process.argv.slice(2);
const opt = (f, d) => (argv.includes(f) ? Number(argv[argv.indexOf(f) + 1]) : d);

/** Runs one implementation's `layout` and returns the output file's text. */
function run(impl, inFile, outFile, mode, order) {
  fs.mkdirSync(path.dirname(outFile), { recursive: true });
  fs.rmSync(outFile, { force: true });
  const r = spawnSync(BIN[impl], ["layout", "--mode", mode, "--order", order, inFile, outFile], { encoding: "utf8" });
  if (r.status !== 0) throw new Error(`${impl} ${inFile} ${mode} ${order}: exit ${r.status} ${r.stderr}`);
  return fs.readFileSync(outFile, "utf8");
}
const sample = (impl, rev, mode, order) =>
  run(impl, path.join(spike, "inputs", `design-${rev}.json`), path.join(spike, "outputs", impl, `design-${rev}.${mode}.${order}.json`), mode, order);

/** The design's layout mapped into the §3 output shape (the expected output of §7.2). */
function expected(d, rev, mode, commits = d.GRAPH_COMMITS) {
  const L = d.computeLayout(commits, rev, W, H, mode, { optimize: false });
  const dn = L.nodes; // design order: root first
  const n = dn.length;
  const at = new Map(dn.map((x, k) => [x.id, n - 1 - k])); // design node → input index
  // routeEdges emits edges node by node (design order), parent by parent: index them that way.
  const edgeOf = new Map();
  let e = 0;
  dn.forEach((x) => x.parents.forEach((_, j) => edgeOf.set(`${x.id}/${j}`, L.edges[e++])));
  if (e !== L.edges.length) throw new Error("design edge count mismatch");

  const nodes = [], edges = [];
  for (let i = 0; i < n; i++) {
    const x = dn[n - 1 - i];
    nodes.push({ row: x.row, lane: x.lane, col: x.col });
    x.parents.forEach((pp, j) => {
      const p = L.N.get(pp.id), pts = edgeOf.get(`${x.id}/${j}`).pts;
      // The route from the design's own geometry (GV:58-65): 2 points = same lane; a merge
      // leaves the parent's lane centre, a branch-off leaves the parent's side (±0.28·W).
      const route = pts.length === 2 ? "straight" : pts[0][0] === p.cx ? "merge" : "branch_off";
      edges.push({ from: at.get(pp.id), to: i, kind: pp.skipped ? "indirect" : "direct", route, blocked: route === "straight" ? false : !!pp.blocked }); // D4
    });
  }
  const ladder = new Map(d.LADDER.map(([m, label]) => [label, m]));
  const buckets = L.buckets.map((b) => {
    const member = dn.find((x) => x.row >= b.start && x.row <= b.end);
    const key = d.timeBucket(member.c).key;
    if (key === -Infinity) return { kind: "root", value: 0, start: b.start, end: b.end };
    if (ladder.has(b.label)) return { kind: "age", value: ladder.get(b.label), start: b.start, end: b.end };
    return { kind: "day", value: key, start: b.start, end: b.end };
  });
  const rows = n ? Math.max(...nodes.map((x) => x.row)) + 1 : 0;
  const lanes = n ? Math.max(...nodes.map((x) => x.lane)) + 1 : 0; // D10: the design says 1 for n = 0
  return { L, text: JSON.stringify({ mode, order: "greedy", unit: 1, rows, lanes, nodes, edges, buckets }) + "\n" };
}

/** Every field-level difference between two outputs. */
function differences(want, got) {
  const out = [];
  for (const k of ["mode", "order", "unit", "rows", "lanes"]) if (want[k] !== got[k]) out.push(`${k}: design ${want[k]}, got ${got[k]}`);
  for (const f of ["nodes", "edges", "buckets"]) {
    const A = want[f], B = got[f];
    if (A.length !== B.length) out.push(`${f}: design ${A.length} entries, got ${B.length}`);
    for (let i = 0; i < Math.min(A.length, B.length); i++) {
      for (const k of Object.keys(A[i])) {
        if (A[i][k] !== B[i][k]) out.push(`${f}[${i}].${k}: design ${JSON.stringify(A[i][k])}, got ${JSON.stringify(B[i][k])}`);
      }
    }
  }
  return out;
}

/** optimizeLanes' cost closure, verbatim (GV:103-111), for a lane → column map. */
function designCost(d, L, pos) {
  const step = W + d.G.gapX;
  const edges = d.routeEdges(L.nodes, L.N, W, H, (n) => pos[n.lane] * step);
  const { cross, overlaps } = d.analyzeEdges(edges);
  let len = 0;
  edges.forEach((e) => { len += Math.abs(e.pts[e.pts.length - 1][0] - e.pts[0][0]) / step; });
  let disp = 0;
  pos.forEach((p, l) => { disp += Math.abs(p - l); });
  return { cost: cross.length * 100 + overlaps * 100 + len + disp * 0.25, crossings: cross.length, overlaps };
}

const piOf = (out) => {
  const pi = new Array(out.lanes);
  out.nodes.forEach((x) => { pi[x.lane] = x.col; });
  return pi;
};

/** Random design-shaped commits (GD fields), root first; parents precede their children. */
function genDesign(r) {
  const n = r.int(1, 45);
  const width = r.pick([1, 2, 3, 6, 12]);
  const pMerge = r.pick([0, 0.15, 0.4]);
  const pHidden = r.pick([0, 0.2, 0.5]);
  const pNonMono = r.pick([0, 0, 0.1, 0.3]);
  const prios = r.pick([[0], [0, 1], [0, 0.5, 1, 2, 3], [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]]);
  const base = Date.parse("2026-09-01T00:00:00Z") + r.int(0, 20) * DAY;
  const commits = [{ id: "c0", parents: [], isRoot: true, priority: r.pick(prios), inDefault: r.chance(0.5) }];
  const ts = [null];
  for (let k = 1; k < n; k++) {
    const parents = [r.int(Math.max(0, k - width), k - 1)];
    while (r.chance(pMerge) && parents.length < 3) {
      const q = r.int(0, k - 1);
      if (!parents.includes(q)) parents.push(q);
    }
    const pts = parents.map((p) => ts[p]).filter((t) => t !== null);
    const from = pts.length ? Math.max(...pts) : base;
    const t = r.chance(pNonMono) ? from - r.pick(STEPS) - r.int(0, 999) : from + r.pick(STEPS) + r.int(0, 999);
    ts.push(t);
    commits.push({ id: `c${k}`, parents: parents.map((p) => `c${p}`), ts: new Date(t).toISOString(), priority: r.pick(prios), inDefault: !r.chance(pHidden) });
  }
  const newest = Math.max(base, ...ts.filter((t) => t !== null));
  return { commits, nowIso: new Date(newest + r.pick([0, MIN, 11 * MIN, 5 * HOUR, 13 * HOUR, 2 * DAY])).toISOString() };
}

/**
 * D1 applied to the design's input: every visible commit's ts raised to the max over its visible
 * (incl. skipped) parents, root / no ts = −∞. timeBucket is monotone in ts, so the design's key of
 * the clamped ts is exactly SPEC's eb(i), and with ts now monotone along every edge the design's
 * in-bucket order visits parents first. So SPEC time mode = design(clamped) — a difference that
 * disappears against it is D1 and nothing else.
 */
function clampTs(d, rev, commits) {
  const L = d.computeLayout(commits, rev, W, H, "compact", { optimize: false });
  const t = new Map();
  for (const x of L.nodes) { // root first: parents before children
    let v = x.c.isRoot || !x.c.ts ? -Infinity : Date.parse(x.c.ts);
    for (const p of x.parents) v = Math.max(v, t.get(p.id));
    t.set(x.id, v);
  }
  return commits.map((c) => (!c.isRoot && t.has(c.id) && t.get(c.id) > -Infinity ? { ...c, ts: new Date(t.get(c.id)).toISOString() } : c));
}

const d = loadDesign();
let bad = 0;

// The committed inputs must be what the converter derives from the pinned export.
for (const rev of ["default", "all"]) {
  const now = JSON.stringify(designInput(d, rev)) + "\n";
  if (now !== fs.readFileSync(path.join(spike, "inputs", `design-${rev}.json`), "utf8")) {
    console.log(`inputs/design-${rev}.json is stale: rerun node tools/design-input.mjs`);
    bad++;
  }
}

console.log("greedy: design computeLayout(…, {optimize: false}) vs Rust / Dart");
const designs = {};
for (const rev of ["default", "all"]) for (const mode of ["compact", "time"]) {
  const { L, text } = expected(d, rev, mode);
  designs[`${rev}/${mode}`] = L;
  const file = path.join(spike, "outputs/oracle", `design-${rev}.${mode}.greedy.json`);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, text);
  const want = JSON.parse(text);
  for (const impl of ["rust", "dart"]) {
    const got = sample(impl, rev, mode, "greedy");
    if (got === text) { console.log(`  ${rev}/${mode} ${impl}: identical (${want.rows} rows, ${want.lanes} lanes, ${want.edges.length} edges, ${want.buckets.length} buckets)`); continue; }
    bad++;
    const diffs = differences(want, JSON.parse(got));
    console.log(`  ${rev}/${mode} ${impl}: ${diffs.length} difference(s)`);
    for (const line of diffs.length ? diffs : ["bytes differ, fields equal (serialisation)"]) console.log(`    ${line}`);
  }
}

console.log("\noptimized (information only, D5): design optimiser vs ours, scored by the design's cost");
for (const rev of ["default", "all"]) for (const mode of ["compact", "time"]) {
  const L = designs[`${rev}/${mode}`];
  const own = d.computeLayout(d.GRAPH_COMMITS, rev, W, H, mode, { optimize: true });
  const designPi = new Array(Math.max(...own.nodes.map((x) => x.lane)) + 1);
  own.nodes.forEach((x) => { designPi[x.lane] = x.col; });
  const oursText = sample("rust", rev, mode, "optimized");
  if (sample("dart", rev, mode, "optimized") !== oursText) { console.log(`  ${rev}/${mode}: rust and dart optimized differ`); bad++; }
  const fmt = (pi) => { const c = designCost(d, L, pi); return `π=${JSON.stringify(pi)} cost ${c.cost.toFixed(6)} (${c.crossings} crossings, ${c.overlaps} overlaps)`; };
  console.log(`  ${rev}/${mode}: greedy ${fmt([...designPi.keys()])}\n    design ${fmt(designPi)}\n    ours   ${fmt(piOf(JSON.parse(oursText)))}`);
}

console.log("\nSPEC §7.2 expectations the oracle cannot check");
const expect = (label, ok) => { console.log(`  ${ok ? "ok  " : "FAIL"} ${label}`); if (!ok) bad++; };
for (const rev of ["default", "all"]) {
  const comp = JSON.parse(sample("rust", rev, "compact", "optimized"));
  expect(`${rev}: optimized compact is the identity`, piOf(comp).every((c, l) => c === l));
  const time = JSON.parse(sample("rust", rev, "time", "optimized"));
  expect(`${rev}: optimized time π = [0,2,3,1] (got ${JSON.stringify(piOf(time))})`, JSON.stringify(piOf(time)) === "[0,2,3,1]");
  const free = JSON.parse(sample("rust", rev, "free", "greedy"));
  const rows = { default: 209, all: 377 }[rev];
  expect(`${rev}: free rows ${rows}, 4 lanes (got ${free.rows}, ${free.lanes})`, free.rows === rows && free.lanes === 4);
}

const CASES = opt("--fuzz", 0), SEED = opt("--seed", 1);
if (CASES) {
  console.log(`\nfuzz: ${CASES} random design graphs (seed ${SEED}), greedy, vs Rust / Dart`);
  const dir = path.join(spike, "outputs/oracle-fuzz");
  const tally = {};
  for (let c = 0; c < CASES; c++) {
    const { commits, nowIso } = genDesign(rng(SEED * 7_000_003 + c));
    d.ctx.GRAPH_NOW = nowIso; // timeBucket reads window.GRAPH_NOW
    for (const rev of ["default", "all"]) {
      const input = designInput(d, rev, commits, nowIso);
      try { validate(input); } catch (err) {
        tally.skipped = (tally.skipped ?? 0) + 1;
        if (!/^V3/.test(err.message)) { bad++; console.log(`  case ${c} ${rev}: converter rejects the design's graph: ${err.message}`); }
        continue; // V3: the design's duplicate-parent defect (verifier, low)
      }
      const inFile = path.join(dir, "case.json");
      fs.mkdirSync(dir, { recursive: true });
      fs.writeFileSync(inFile, JSON.stringify(input) + "\n");
      const kinds = input.nodes.flatMap((x) => x.parents.map((p) => p.kind));
      if (kinds.includes("indirect")) tally.withIndirect = (tally.withIndirect ?? 0) + 1;
      for (const mode of ["compact", "time"]) {
        const want = expected(d, rev, mode, commits).text;
        const clamped = mode === "time" ? expected(d, rev, mode, clampTs(d, rev, commits)).text : want;
        for (const impl of ["rust", "dart"]) {
          const got = run(impl, inFile, path.join(dir, `case.${impl}.json`), mode, "greedy");
          let cls = "identical";
          if (got !== want) cls = got === clamped ? "differs: expected (D1, = design on clamped ts)" : "differs: BUG";
          const k = `${mode} ${impl} ${cls}`;
          tally[k] = (tally[k] ?? 0) + 1;
          if (cls.endsWith("BUG")) {
            bad++;
            const keep = path.join(dir, `fail-${SEED}-${c}-${rev}.json`);
            fs.copyFileSync(inFile, keep);
            console.log(`  case ${c} ${rev}/${mode} ${impl} → ${path.relative(spike, keep)}\n    ${differences(JSON.parse(want), JSON.parse(got)).slice(0, 8).join("\n    ")}`);
          }
        }
      }
    }
    d.ctx.GRAPH_NOW = d.GRAPH_NOW;
  }
  for (const k of Object.keys(tally).sort()) console.log(`  ${k}: ${tally[k]}`);
}

console.log(bad ? `\n${bad} problem(s)` : "\nall greedy results identical to the design, or differing only where SPEC.md says they may; expectations hold");
process.exit(bad ? 1 : 0);
