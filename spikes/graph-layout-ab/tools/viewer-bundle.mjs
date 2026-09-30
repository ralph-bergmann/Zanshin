#!/usr/bin/env node
// Packs one layout input + its layout outputs (every mode × order) into ONE compact bundle for
// the throwaway viewer (viewer/index.html), and keeps viewer/data/index.json up to date.
//
//   node tools/viewer-bundle.mjs [--outputs DIR] [--runs N] [--warmup W] [--no-bench] [--fresh] <input.json>…
//
// - Sidecar: `<input>.meta.json` next to the input (gen-inputs `dump` writes it) is picked up when
//   present. For the design samples (`design-*.json`) without one, the card content comes from the
//   design's own graph-data.js, read from git at the export the input was converted from
//   (tools/design-source.mjs; `design-<commit>-<rev>.json` from tools/design-input.mjs --rev).
//   Otherwise cards show ids only.
// - Outputs: `<outputs>/<name>.<mode>.<order>.json` (default outputs/dart). A missing output, or one
//   older than its input or than the binary, is (re)written by the spike's Dart AOT binary
//   (dart/build/graph_layout, compiled with `dart compile exe` if absent). Orders: greedy,
//   optimized and the Dart-only compact (SPEC §4.7).
// - Timing: one `graph_layout bench` process per mode × order (default --runs 11 --warmup 3), its
//   median `total` goes into the bundle. `--no-bench` skips it.
// - Metrics: tools/lane-metrics.mjs over the three outputs of each mode (crossings as drawn, run
//   length, width, holes; whole graph, at the viewer's default card size).
// - The bundle goes to viewer/data/<name>.json. viewer/data/ is gitignored: bundles may hold
//   customer-derived data (descriptions, authors, bookmarks) and must never be committed.
//
// Bundle v2: the topology once (ts, parents as CSR, short ids, optional card meta), then per mode
// greedy's order-independent part of the output (row, lane, route+blocked, buckets), per π order
// (greedy, optimized) only the lane→column permutation π, and for compact its own lane array
// (col = lane there) plus its route string only if it differs. The split is checked, not assumed:
// greedy and optimized must agree on everything but col, and col = π(lane) (SPEC §7.3 I4); compact
// must agree with greedy on rows, buckets, edges, route kinds and the trunk (SPEC §4.7).

import fs from "node:fs";
import path from "node:path";
import vm from "node:vm";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { designFile } from "./design-source.mjs";

const spike = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const dataDir = path.join(spike, "viewer", "data");
const binary = path.join(spike, "dart", "build", "graph_layout");
const metricsTool = path.join(spike, "tools", "lane-metrics.mjs");
const MODES = ["compact", "time", "free"];
const PERM_ORDERS = ["greedy", "optimized"]; // col = π(lane) over greedy's lanes (SPEC §4.6)
const ORDERS = [...PERM_ORDERS, "compact"];  // compact: own lanes, col = lane (SPEC §4.7, Dart-only)
const KIND = { direct: "d", indirect: "i", missing: "m" };

function usage(msg) {
  if (msg) console.error(msg);
  console.error("usage: node tools/viewer-bundle.mjs [--outputs DIR] [--runs N] [--warmup W] [--no-bench] [--fresh] <input.json>…");
  process.exit(2);
}

function parseArgs(argv) {
  const o = { outputs: path.join(spike, "outputs", "dart"), runs: 11, warmup: 3, bench: true, fresh: false, inputs: [] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    const val = () => (i + 1 < argv.length ? argv[++i] : usage(`${a} needs a value`));
    if (a === "--outputs") o.outputs = path.resolve(val());
    else if (a === "--runs") o.runs = +val();
    else if (a === "--warmup") o.warmup = +val();
    else if (a === "--no-bench") o.bench = false;
    else if (a === "--fresh") o.fresh = true;
    else if (a.startsWith("--")) usage(`unknown flag ${a}`);
    else o.inputs.push(path.resolve(a));
  }
  if (!o.inputs.length) usage();
  if (!(o.runs >= 1) || !(o.warmup >= 0)) usage("--runs must be ≥ 1, --warmup ≥ 0");
  return o;
}

function ensureBinary() {
  if (fs.existsSync(binary)) return;
  console.error("compiling dart/build/graph_layout (dart compile exe) …");
  fs.mkdirSync(path.dirname(binary), { recursive: true });
  execFileSync("dart", ["compile", "exe", path.join(spike, "dart", "bin", "graph_layout.dart"), "-o", binary], { stdio: "inherit" });
}

const readJson = (f) => JSON.parse(fs.readFileSync(f, "utf8"));
const mtime = (f) => fs.statSync(f).mtimeMs;

/** The output for mode × order: reused when present and not older than the input and the binary,
 *  else rewritten. */
function output(o, input, n, name, mode, order) {
  const file = path.join(o.outputs, `${name}.${mode}.${order}.json`);
  if (!o.fresh && fs.existsSync(file) && mtime(file) >= mtime(input) && (!fs.existsSync(binary) || mtime(file) >= mtime(binary))) {
    const out = readJson(file);
    if (out.nodes.length === n && out.mode === mode && out.order === order) return { file, out, ran: false };
  }
  ensureBinary();
  fs.mkdirSync(o.outputs, { recursive: true });
  execFileSync(binary, ["layout", "--mode", mode, "--order", order, input, file], { stdio: ["ignore", "ignore", "inherit"] });
  return { file, out: readJson(file), ran: true };
}

/** tools/lane-metrics.mjs over the given output files: { order: {lanes, cross, hlen, maxW, meanW, holesPct} }. */
function metrics(files) {
  const lines = execFileSync(process.execPath, [metricsTool, "--json", ...files], { encoding: "utf8" }).trim().split("\n");
  const res = {};
  for (const l of lines) {
    const r = JSON.parse(l);
    res[r.order] = { lanes: r.lanes, cross: r.cross, hlen: r.hlen, maxW: r.maxW, meanW: r.meanW, holesPct: r.holesPct };
  }
  return res;
}

function bench(o, input, mode, order) {
  ensureBinary();
  const line = execFileSync(binary, ["bench", "--mode", mode, "--order", order, "--runs", String(o.runs), "--warmup", String(o.warmup), input], { encoding: "utf8" });
  const b = JSON.parse(line);
  const ph = {};
  for (const [k, v] of Object.entries(b.phases)) ph[k] = v.median_ns;
  return { impl: b.impl, runs: b.runs, warmup: b.warmup, median_ns: ph };
}

/** Card content from a gen-inputs `dump` sidecar. */
function sidecarMeta(meta, input) {
  const n = input.nodes.length;
  if (!Array.isArray(meta.nodes) || meta.nodes.length !== n) throw new Error(`meta: ${meta.nodes?.length} nodes, input has ${n}`);
  const m = { source: "sidecar", revset: meta.revset ?? null, change: [], plen: [], desc: [], author: [], flags: [], bm: [], wc: -1, dropped: 0 };
  meta.nodes.forEach((x, k) => {
    if (x.idx !== k) throw new Error(`meta: node ${k} has idx ${x.idx}`);
    const id = String(input.nodes[k].id ?? "");
    if (x.commit_id && id && !id.startsWith(x.commit_id)) throw new Error(`meta: node ${k} commit ${x.commit_id} ≠ input id ${id}`);
    m.change.push(x.change_id ?? "");
    m.plen.push(x.change_id_prefix_len ?? 2);
    m.desc.push(String(x.description ?? "").split("\n")[0]);
    m.author.push(x.author ?? "");
    m.flags.push((x.working_copy ? 1 : 0) | (x.immutable ? 2 : 0) | (x.empty ? 4 : 0) | (x.conflict ? 8 : 0) |
      (x.root ? 16 : 0) | (x.divergent ? 32 : 0) | (x.hidden ? 64 : 0));
    const bms = (x.bookmarks ?? []).map((b) => (b.remote ? `${b.name}@${b.remote}` : b.name));
    m.bm.push(bms.length ? bms : 0);
    if (x.working_copy && m.wc < 0) m.wc = k;
    m.dropped += (x.dropped_duplicate_parents ?? []).length;
  });
  return m;
}

/** Card content for the design samples, from the design's graph-data.js at `commit` (matched by change id). */
function designMeta(input, commit) {
  const ctx = vm.createContext({});
  vm.runInContext("var window = globalThis;", ctx);
  vm.runInContext(designFile("graph-data.js", commit), ctx, { filename: "graph-data.js" });
  const byId = new Map(ctx.GRAPH_COMMITS.map((c) => [c.id, c]));
  const m = { source: "design graph-data.js", revset: null, change: [], plen: [], desc: [], author: [], flags: [], bm: [], wc: -1, dropped: 0 };
  input.nodes.forEach((x, k) => {
    const c = byId.get(x.id);
    if (!c) throw new Error(`design meta: no commit ${x.id}`);
    m.change.push(c.id);
    m.plen.push(2);
    m.desc.push(c.subject ?? "");
    m.author.push(c.author ?? "");
    m.flags.push((c.isWorkingCopy ? 1 : 0) | (c.immutable ? 2 : 0) | (c.isEmpty ? 4 : 0) | (c.hasConflict ? 8 : 0) | (c.isRoot ? 16 : 0));
    m.bm.push(c.bookmarks.length ? c.bookmarks.map((b) => b.name) : 0);
    if (c.isWorkingCopy && m.wc < 0) m.wc = k;
  });
  return m;
}

/** Everything of one output except col, in bundle form. */
function modePart(out) {
  let route = "";
  for (const e of out.edges) {
    const r = e.route === "straight" ? "s" : e.route === "merge" ? "m" : "b";
    if (e.blocked && r !== "b") throw new Error(`edge ${e.from}→${e.to}: blocked ${e.route}`); // SPEC I3/D4
    route += e.blocked ? "B" : r;
  }
  return {
    unit: out.unit, rows: out.rows, lanes: out.lanes,
    row: out.nodes.map((x) => x.row), lane: out.nodes.map((x) => x.lane), route,
    buckets: out.buckets.map((b) => [b.kind, b.value, b.start, b.end]),
  };
}

/** compact's own part: its lanes (col = lane) and, only if it differs from greedy's, its route
 *  string. Checks SPEC §4.7's claims against greedy: same rows, buckets and edges; every route kind
 *  equal (only a branch-off's blocked flag may change); π = identity; the trunk (lane 0) unchanged;
 *  no more lanes than greedy. */
function compactPart(what, part, greedy, compact) {
  const c = modePart(compact);
  for (const key of ["unit", "rows", "row", "buckets"]) {
    if (JSON.stringify(part[key]) !== JSON.stringify(c[key])) throw new Error(`${what}: greedy and compact differ in ${key}`);
  }
  if (compact.edges.length !== greedy.edges.length) throw new Error(`${what}: compact has ${compact.edges.length} edges, greedy ${greedy.edges.length}`);
  compact.edges.forEach((ed, k) => {
    const g = greedy.edges[k];
    if (ed.from !== g.from || ed.to !== g.to) throw new Error(`${what}: compact edge ${k} is ${ed.from}→${ed.to}, greedy's ${g.from}→${g.to}`);
    if (ed.route !== g.route) throw new Error(`${what}: edge ${k} routes ${g.route} under greedy, ${ed.route} under compact`);
  });
  compact.nodes.forEach((x, i) => {
    if (x.col !== x.lane) throw new Error(`${what}: compact node ${i} has lane ${x.lane}, col ${x.col}`);
    if ((x.lane === 0) !== (part.lane[i] === 0)) throw new Error(`${what}: compact moved node ${i} ${x.lane === 0 ? "into" : "out of"} the trunk lane`);
  });
  if (c.lanes > part.lanes) throw new Error(`${what}: compact has ${c.lanes} lanes, greedy ${part.lanes}`);
  const res = { lanes: c.lanes, lane: c.lane };
  if (c.route !== part.route) res.route = c.route; // blocked flags of first-parent branch-offs only
  return res;
}

function bundleOne(o, inputFile) {
  const name = path.basename(inputFile).replace(/\.json$/, "");
  const input = readJson(inputFile);
  const n = input.nodes.length;

  // topology: parents as CSR (missing → -1), in jj stream order
  const ts = [], poff = [0], pidx = [], ids = [], roots = [];
  let pkind = "", e = 0;
  for (const x of input.nodes) {
    if (x.is_root) roots.push(ts.length);
    ts.push(x.ts_ms);
    ids.push(String(x.id ?? "").slice(0, 12));
    for (const p of x.parents) {
      pidx.push(p.idx ?? -1);
      pkind += KIND[p.kind];
      if (p.idx !== null) e++;
    }
    poff.push(pidx.length);
  }

  const metaFile = inputFile.replace(/\.json$/, ".meta.json");
  let meta = null;
  if (fs.existsSync(metaFile)) meta = sidecarMeta(readJson(metaFile), input);
  else if (name.startsWith("design-")) meta = designMeta(input, /^design-(.+)-(?:default|all)$/.exec(name)?.[1]);

  const modes = {};
  let ran = 0;
  for (const mode of MODES) {
    const outs = {}, files = [];
    for (const order of ORDERS) {
      const r = output(o, inputFile, n, name, mode, order);
      outs[order] = r.out;
      files.push(r.file);
      ran += r.ran ? 1 : 0;
    }
    const part = modePart(outs.greedy);
    if (outs.greedy.edges.length !== e) throw new Error(`${name} ${mode}: ${outs.greedy.edges.length} edges, topology has ${e}`);
    // edge order = child asc, then parent position (SPEC §3): check against the CSR walk
    let k = 0;
    for (let i = 0; i < n; i++) for (let j = poff[i]; j < poff[i + 1]; j++) {
      if (pidx[j] < 0) continue;
      const ed = outs.greedy.edges[k++];
      if (ed.to !== i || ed.from !== pidx[j]) throw new Error(`${name} ${mode}: edge ${k - 1} is ${ed.from}→${ed.to}, expected ${pidx[j]}→${i}`);
    }
    const again = modePart(outs.optimized);
    for (const key of Object.keys(part)) {
      if (JSON.stringify(part[key]) !== JSON.stringify(again[key])) throw new Error(`${name} ${mode}: greedy and optimized differ in ${key}`);
    }
    part.perm = {};
    for (const order of PERM_ORDERS) {
      const pi = new Array(part.lanes).fill(-1);
      outs[order].nodes.forEach((x, i) => {
        const l = part.lane[i];
        if (pi[l] >= 0 && pi[l] !== x.col) throw new Error(`${name} ${mode} ${order}: lane ${l} has cols ${pi[l]} and ${x.col}`);
        pi[l] = x.col;
      });
      if (order === "greedy" && pi.some((c, l) => c !== l)) throw new Error(`${name} ${mode}: greedy col ≠ lane`);
      part.perm[order] = pi;
    }
    part.compact = compactPart(`${name} ${mode}`, part, outs.greedy, outs.compact);
    part.metrics = metrics(files);
    part.timing = {};
    if (o.bench) for (const order of ORDERS) part.timing[order] = bench(o, inputFile, mode, order);
    modes[mode] = part;
  }

  const bundle = { v: 2, name, input: path.basename(inputFile), now_ms: input.now_ms, utc_offset_min: input.utc_offset_min, n, e, ts, roots, poff, pidx, pkind, ids, meta, modes };
  fs.mkdirSync(dataDir, { recursive: true });
  const file = path.join(dataDir, `${name}.json`);
  fs.writeFileSync(file, JSON.stringify(bundle));
  const tm = modes.time.timing, ms = (k) => (tm[k] ? `${(tm[k].median_ns.total / 1e6).toFixed(3)}` : "–");
  console.error(`${name}: n=${n} e=${e} meta=${meta ? meta.source : "ids only"} layouts run=${ran}/${MODES.length * ORDERS.length}` +
    `${o.bench ? ` time layout greedy/optimized/compact=${ms("greedy")}/${ms("optimized")}/${ms("compact")} ms` : ""}` +
    ` → viewer/data/${name}.json (${(fs.statSync(file).size / 1e6).toFixed(2)} MB)`);
  return { name, file: `${name}.json`, n, e, meta: meta ? meta.source : null, revset: meta?.revset ?? null,
    lanes: Object.fromEntries(MODES.map((m) => [m, modes[m].lanes])) };
}

const o = parseArgs(process.argv.slice(2));
const indexFile = path.join(dataDir, "index.json");
let index = { datasets: [] };
try { index = readJson(indexFile); } catch { /* first bundle */ }
for (const f of o.inputs) {
  const entry = bundleOne(o, f);
  index.datasets = index.datasets.filter((d) => d.name !== entry.name).concat(entry);
}
index.datasets.sort((a, b) => a.name.localeCompare(b.name));
fs.writeFileSync(indexFile, JSON.stringify(index, null, 1) + "\n");
