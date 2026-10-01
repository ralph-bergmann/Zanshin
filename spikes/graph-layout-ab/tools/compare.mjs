#!/usr/bin/env node
// docs/graph-layout.md §7.1 — Rust ≡ Dart. For every input in inputs/manifest.json × mode × order it runs
// both `layout` binaries into outputs/{rust,dart}/<input>.<mode>.<order>.json and compares the
// files byte for byte. On a mismatch it prints the first differing header field / node / edge /
// bucket, with the input node(s) and both sides' values as context. Equal outputs are then checked
// against the §7.3 invariants I1–I6 (cell INV on a violation). With --digest it also runs
// `bench --runs 1 --warmup 0` on both and checks the bench line (nodes, edges, rows, lanes,
// digest) against the digest recomputed here from the layout output (§8.4).
//
//   node tools/compare.mjs [--digest] [--no-run] [--only <substring>] [--core <binary>]
//
// --core <binary> (2026-10-01, Story 4.11) adds the product engine's AOT-compiled CLI
// (packages/zanshin_core/benchmark/graph_layout_cli.dart) as a third implementation over every
// input × {compact, free} × {greedy, compact}; see the end of this file.
//
// Build first (from the spike root):
//   cargo build --release --manifest-path rust/Cargo.toml
//   dart compile exe dart/bin/graph_layout.dart -o dart/build/graph_layout
// Exit code 1 if any combination differs or fails, else 0.

import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const spike = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const BIN = {
  rust: path.join(spike, "rust/target/release/graph-layout"),
  dart: path.join(spike, "dart/build/graph_layout"),
};
const MODES = ["compact", "time", "free"];
const ORDERS = ["greedy", "optimized"];

const argv = process.argv.slice(2);
const flag = (f) => argv.includes(f);
const only = argv.includes("--only") ? argv[argv.indexOf("--only") + 1] : null;

function run(impl, args) {
  const r = spawnSync(BIN[impl], args, { encoding: "utf8", maxBuffer: 1 << 26 });
  if (r.error) throw r.error;
  return r;
}

/** §8.4 digest, recomputed from a canonical output. */
function digest(out) {
  const P = 1000000007n;
  let d = 0n;
  const step = (v) => { d = (31n * d + BigInt(v)) % P; };
  for (const x of out.nodes) step(7 * x.row + 3 * x.col + x.lane);
  const R = { straight: 0, merge: 1, branch_off: 2 };
  for (const e of out.edges) step(R[e.route] + 4 * (e.blocked ? 1 : 0));
  for (const b of out.buckets) step(b.start + 3 * b.end);
  return Number(d);
}

/** SPEC §7.3 I1–I6 (plus the header fields and the edge order of §3) on one output. */
function invariants(inp, o) {
  const fails = [];
  const fail = (m) => { if (fails.length < 5) fails.push(m); };
  const U = o.unit, N = o.nodes, n = inp.nodes.length;
  const LP = inp.nodes.map((x) => x.parents.filter((p) => p.idx !== null).map((p) => p.idx));
  if (N.length !== n) return [`nodes: ${N.length} entries for ${n} input nodes`];
  const maxOr = (arr, d) => arr.reduce((m, v) => Math.max(m, v), d);
  if (o.rows !== (n ? maxOr(N.map((x) => x.row), -Infinity) + U : 0)) fail("rows ≠ max row + U");
  if (o.lanes !== (n ? maxOr(N.map((x) => x.lane), -Infinity) + 1 : 0)) fail("lanes ≠ max lane + 1");
  // Edge order (§3), I1, I3.
  let e = 0;
  for (let i = 0; i < n; i++) LP[i].forEach((p, pos) => {
    const ed = o.edges[e++];
    if (!ed || ed.from !== p || ed.to !== i) { fail(`edge [${e - 1}] is not ${p}→${i}`); return; }
    if (N[i].row < N[p].row + U) fail(`I1 ${p}→${i}`);
    const same = N[p].lane === N[i].lane;
    if ((ed.route === "straight") !== same || (same && pos !== 0)) fail(`I3 straight ${p}→${i}`);
    if (ed.route === "merge" && (pos < 1 || ed.blocked)) fail(`I3 merge ${p}→${i}`);
    if (ed.blocked && same) fail(`I3 blocked ${p}→${i}`);
  });
  if (e !== o.edges.length) fail(`edges: ${o.edges.length} entries for ${e} layout edges`);
  // I2: consecutive cards in a lane keep 2U, or U along a straight edge.
  const straight = new Set(o.edges.filter((x) => x.route === "straight").map((x) => `${x.from}>${x.to}`));
  const byLane = [];
  N.forEach((x, i) => (byLane[x.lane] ??= []).push(i));
  for (const m of byLane) {
    if (!m) continue;
    m.sort((a, b) => N[a].row - N[b].row);
    for (let k = 1; k < m.length; k++) {
      if (N[m[k]].row - N[m[k - 1]].row < (straight.has(`${m[k - 1]}>${m[k]}`) ? U : 2 * U)) fail(`I2 lane ${N[m[k]].lane}: ${m[k - 1]}, ${m[k]}`);
    }
  }
  // I4: col = π(lane), π a permutation with π(0) = 0; greedy ⇒ identity.
  const pi = new Array(o.lanes).fill(-1);
  N.forEach((x) => { if (pi[x.lane] !== -1 && pi[x.lane] !== x.col) fail("I4 col ≠ π(lane)"); pi[x.lane] = x.col; });
  if (new Set(pi).size !== pi.length || pi.some((c) => c < 0 || c >= o.lanes) || (pi.length && pi[0] !== 0)) fail("I4 π is not a permutation fixing lane 0");
  if (o.order === "greedy" && N.some((x) => x.col !== x.lane)) fail("I4 greedy col ≠ lane");
  // I5: time buckets strictly ascending, contiguous 0 … rows − 1, each node inside eb(i)'s bucket.
  if (o.mode === "time") {
    const now = inp.now_ms, off = inp.utc_offset_min * 60000, DAY = 86400000;
    const keyOf = (b) => (b.kind === "root" ? -Infinity : b.kind === "age" ? now - b.value * 60000 : b.value);
    const range = new Map();
    let next = 0, prev = null;
    for (const b of o.buckets) {
      if (b.start !== next || b.end < b.start) fail(`I5 bucket ${JSON.stringify(b)} not contiguous`);
      if (prev !== null && !(keyOf(b) > prev)) fail(`I5 bucket ${JSON.stringify(b)} not ascending`);
      prev = keyOf(b);
      next = b.end + 1;
      range.set(prev, b);
    }
    if (next !== o.rows) fail("I5 buckets do not end at rows − 1");
    const eb = new Array(n);
    for (let i = n - 1; i >= 0; i--) {
      const x = inp.nodes[i];
      let k;
      if (x.is_root || x.ts_ms === null) k = -Infinity;
      else {
        const m = [10, 20, 40, 60, 120, 240, 480, 720].find((m) => now - x.ts_ms <= m * 60000);
        k = m !== undefined ? now - m * 60000 : Math.floor((x.ts_ms + off) / DAY) * DAY - off;
      }
      eb[i] = maxOr(LP[i].map((p) => eb[p]), k);
      const b = range.get(eb[i]);
      if (!b || N[i].row < b.start || N[i].row > b.end) fail(`I5 node ${i} outside its bucket`);
    }
  } else if (o.mode !== "free" && o.buckets.length) fail(`I5 buckets in ${o.mode} mode`);
  // I6: free rows never decrease in (T asc, i desc) order.
  if (o.mode === "free") {
    const tss = inp.nodes.filter((x) => x.ts_ms !== null).map((x) => x.ts_ms);
    const tmin = tss.length ? tss.reduce((a, b) => Math.min(a, b)) : 0;
    const T = new Array(n);
    for (let i = n - 1; i >= 0; i--) T[i] = maxOr(LP[i].map((p) => T[p]), inp.nodes[i].is_root || inp.nodes[i].ts_ms === null ? tmin : inp.nodes[i].ts_ms);
    const ord = [...Array(n).keys()].sort((a, b) => T[a] - T[b] || b - a);
    for (let k = 1; k < n; k++) if (N[ord[k]].row < N[ord[k - 1]].row) { fail(`I6 row decreases at node ${ord[k]}`); break; }
    // I5 in free (amended 2026-10-01): day buckets of the clamped T of every non-root node.
    freeDayBuckets(inp, o, T).forEach(fail);
  }
  return fails;
}

/** Floor division, exact for |a| < 2^53 and b > 0 (a / b alone can round up across an integer). */
const floorDiv = (a, b) => {
  const q = Math.floor(a / b), r = a - q * b;
  return r < 0 ? q - 1 : r >= b ? q + 1 : q;
};

/**
 * SPEC §7.3 I5 for `free` (amended 2026-10-01): `day` buckets only, values strictly ascending,
 * start ≤ end, end_k ≤ start_{k+1}, every non-root node inside the bucket of its clamped T's day,
 * start / end its members' min / max y, and no bucket iff no non-root node.
 */
function freeDayBuckets(inp, o, T) {
  const fails = [];
  const fail = (m) => { if (fails.length < 5) fails.push(m); };
  const DAY = 86400000, off = inp.utc_offset_min * 60000;
  const B = o.buckets, at = new Map();
  B.forEach((b, k) => {
    if (b.kind !== "day") fail(`I5 free bucket ${k} has kind ${b.kind}`);
    if (b.start > b.end) fail(`I5 free bucket ${k}: start > end`);
    if (k > 0 && !(B[k - 1].value < b.value)) fail(`I5 free bucket ${k} not ascending`);
    if (k > 0 && B[k - 1].end > b.start) fail(`I5 free bucket ${k} starts before the previous one ends`);
    at.set(b.value, k);
  });
  const lo = B.map(() => Infinity), hi = B.map(() => -Infinity);
  let nonRoot = 0;
  inp.nodes.forEach((x, i) => {
    if (x.is_root) return;
    nonRoot++;
    const k = at.get(floorDiv(T[i] + off, DAY) * DAY - off);
    if (k === undefined) { fail(`I5 free node ${i} has no bucket of its day`); return; }
    lo[k] = Math.min(lo[k], o.nodes[i].row);
    hi[k] = Math.max(hi[k], o.nodes[i].row);
  });
  if ((B.length === 0) !== (nonRoot === 0)) fail("I5 free: a bucket iff a non-root node");
  B.forEach((b, k) => { if (b.start !== lo[k] || b.end !== hi[k]) fail(`I5 free bucket ${k}: start / end ≠ its members' min / max y`); });
  return fails;
}

const fmtNode = (x) => (x ? `row ${x.row} lane ${x.lane} col ${x.col}` : "—");
const fmtIn = (input, i) => {
  const x = input.nodes[i];
  const ps = x.parents.map((p) => (p.idx === null ? "missing" : `${p.idx}${p.kind === "indirect" ? "(ind)" : ""}`));
  return `node ${i} id ${String(x.id ?? "").slice(0, 12)} ts ${x.ts_ms} root ${x.is_root} prio ${x.priority} parents [${ps.join(", ")}]`;
};

/** The first difference between two parsed outputs, with context from the input. */
function explain(inputFile, a, b) {
  const lines = [];
  for (const k of ["mode", "order", "unit", "rows", "lanes"]) {
    if (a[k] !== b[k]) lines.push(`  header ${k}: rust ${a[k]} dart ${b[k]}`);
  }
  let input = null;
  const loadInput = () => (input ??= JSON.parse(fs.readFileSync(inputFile, "utf8")));
  const same = (x, y) => JSON.stringify(x) === JSON.stringify(y);
  for (const [name, A, B] of [["nodes", a.nodes, b.nodes], ["edges", a.edges, b.edges], ["buckets", a.buckets, b.buckets]]) {
    if (A.length !== B.length) lines.push(`  ${name}: rust ${A.length} entries, dart ${B.length}`);
    const n = Math.min(A.length, B.length);
    let first = -1, count = 0;
    for (let i = 0; i < n; i++) if (!same(A[i], B[i])) { count++; if (first < 0) first = i; }
    if (first < 0) continue;
    lines.push(`  ${name}: ${count} differ; first at [${first}]: rust ${JSON.stringify(A[first])} dart ${JSON.stringify(B[first])}`);
    const inp = loadInput();
    if (name === "nodes") {
      lines.push(`    input ${fmtIn(inp, first)}`);
      for (const p of inp.nodes[first].parents) {
        if (p.idx === null) continue;
        lines.push(`    parent ${fmtIn(inp, p.idx)}\n      rust ${fmtNode(a.nodes[p.idx])} | dart ${fmtNode(b.nodes[p.idx])}`);
      }
    } else if (name === "edges") {
      for (const i of [A[first].to, A[first].from]) {
        lines.push(`    ${fmtIn(inp, i)}\n      rust ${fmtNode(a.nodes[i])} | dart ${fmtNode(b.nodes[i])}`);
      }
    }
  }
  return lines.length ? lines : ["  outputs parse equal but differ in bytes (non-canonical serialisation)"];
}

const manifest = JSON.parse(fs.readFileSync(path.join(spike, "inputs/manifest.json"), "utf8"));
const files = manifest.files.map((f) => f.file).filter((f) => !only || f.includes(only));
for (const impl of ["rust", "dart"]) fs.mkdirSync(path.join(spike, "outputs", impl), { recursive: true });

const matrix = [];
let bad = 0;
for (const file of files) {
  const inputFile = path.join(spike, "inputs", file);
  const base = file.replace(/\.json$/, "");
  const row = { input: base, cells: [] };
  let input = null; // parsed lazily, once per input file
  for (const mode of MODES) for (const order of ORDERS) {
    const out = {};
    let cell = "=";
    const notes = [];
    for (const impl of ["rust", "dart"]) {
      out[impl] = path.join(spike, "outputs", impl, `${base}.${mode}.${order}.json`);
      if (flag("--no-run")) continue;
      fs.rmSync(out[impl], { force: true });
      const r = run(impl, ["layout", "--mode", mode, "--order", order, inputFile, out[impl]]);
      if (r.status !== 0) { cell = "FAIL"; notes.push(`  ${impl} exit ${r.status}: ${r.stderr.trim()}`); }
    }
    if (cell === "=") {
      const A = fs.readFileSync(out.rust), B = fs.readFileSync(out.dart);
      if (!A.equals(B)) {
        cell = "DIFF";
        notes.push(...explain(inputFile, JSON.parse(A), JSON.parse(B)));
      }
      const o = cell === "=" ? JSON.parse(A) : null;
      if (o) {
        input ??= JSON.parse(fs.readFileSync(inputFile, "utf8"));
        const fails = invariants(input, o);
        if (fails.length) { cell = "INV"; notes.push(...fails.map((m) => `  invariant: ${m}`)); }
      }
      if (o && cell === "=" && flag("--digest")) {
        const want = { nodes: o.nodes.length, edges: o.edges.length, rows: o.rows, lanes: o.lanes, digest: digest(o) };
        for (const impl of ["rust", "dart"]) {
          const r = run(impl, ["bench", "--mode", mode, "--order", order, "--runs", "1", "--warmup", "0", inputFile]);
          const line = r.status === 0 ? JSON.parse(r.stdout) : null;
          const got = line && { nodes: line.nodes, edges: line.edges, rows: line.rows, lanes: line.lanes, digest: line.digest };
          if (JSON.stringify(got) !== JSON.stringify(want)) {
            cell = "DIGEST";
            notes.push(`  ${impl} bench ${JSON.stringify(got)} ≠ from output ${JSON.stringify(want)}`);
          }
        }
      }
    }
    if (cell !== "=") { bad++; console.log(`${base} ${mode} ${order}: ${cell}\n${notes.join("\n")}`); }
    row.cells.push(cell);
  }
  matrix.push(row);
}

const cols = MODES.flatMap((m) => ORDERS.map((o) => `${m}/${o === "greedy" ? "greedy" : "opt"}`));
const w = Math.max(...matrix.map((r) => r.input.length), 5);
console.log(`\n${"input".padEnd(w)} | ${cols.join(" | ")}`);
console.log(`${"-".repeat(w)}-|-${cols.map((c) => "-".repeat(c.length)).join("-|-")}`);
for (const r of matrix) console.log(`${r.input.padEnd(w)} | ${r.cells.map((c, k) => c.padEnd(cols[k].length)).join(" | ")}`);
console.log(`\n${matrix.length * cols.length - bad} identical and invariant-clean, ${bad} differ or fail${flag("--digest") ? " (bench digests checked)" : ""}`);

// --core <binary> (Story 4.11): the product engine's CLI (packages/zanshin_core/benchmark/
// graph_layout_cli.dart) as a third implementation, over the shipped scope only: greedy must equal
// the Rust output byte for byte, the `compact` order the spike Dart output (its only reference),
// and every output must pass the invariants.
const coreBin = argv.includes("--core") ? path.resolve(argv[argv.indexOf("--core") + 1]) : null;
if (coreBin) {
  const CORE_MODES = ["compact", "free"], CORE_ORDERS = ["greedy", "compact"];
  const refImpl = { greedy: "rust", compact: "dart" };
  fs.mkdirSync(path.join(spike, "outputs/core"), { recursive: true });
  const coreMatrix = [];
  let coreBad = 0;
  for (const file of files) {
    const inputFile = path.join(spike, "inputs", file);
    const base = file.replace(/\.json$/, "");
    const row = { input: base, cells: [] };
    const input = JSON.parse(fs.readFileSync(inputFile, "utf8"));
    for (const mode of CORE_MODES) for (const order of CORE_ORDERS) {
      const ref = path.join(spike, "outputs", refImpl[order], `${base}.${mode}.${order}.json`);
      const out = path.join(spike, "outputs/core", `${base}.${mode}.${order}.json`);
      let cell = "=";
      const notes = [];
      for (const [bin, dst] of [[BIN[refImpl[order]], ref], [coreBin, out]]) {
        fs.rmSync(dst, { force: true });
        const r = spawnSync(bin, ["layout", "--mode", mode, "--order", order, inputFile, dst], { encoding: "utf8", maxBuffer: 1 << 26 });
        if (r.error) throw r.error;
        if (r.status !== 0) { cell = "FAIL"; notes.push(`  ${path.basename(bin)} exit ${r.status}: ${r.stderr.trim()}`); }
      }
      if (cell === "=") {
        const A = fs.readFileSync(ref), B = fs.readFileSync(out);
        if (!A.equals(B)) { cell = "DIFF"; notes.push(...explain(inputFile, JSON.parse(A), JSON.parse(B)).map((l) => l.replace(/\b(rust|dart)\b/g, (m) => (m === "rust" ? refImpl[order] : "core")))); }
        else {
          const fails = invariants(input, JSON.parse(B));
          if (fails.length) { cell = "INV"; notes.push(...fails.map((m) => `  invariant: ${m}`)); }
        }
      }
      if (cell !== "=") { coreBad++; console.log(`core ${base} ${mode} ${order}: ${cell}\n${notes.join("\n")}`); }
      row.cells.push(cell);
    }
    coreMatrix.push(row);
  }
  const coreCols = CORE_MODES.flatMap((m) => CORE_ORDERS.map((o) => `${m}/${o}`));
  console.log(`\ncore (${path.relative(process.cwd(), coreBin)}) vs ${CORE_ORDERS.map((o) => `${o}: ${refImpl[o]}`).join(", ")}`);
  console.log(`${"input".padEnd(w)} | ${coreCols.join(" | ")}`);
  console.log(`${"-".repeat(w)}-|-${coreCols.map((c) => "-".repeat(c.length)).join("-|-")}`);
  for (const r of coreMatrix) console.log(`${r.input.padEnd(w)} | ${r.cells.map((c, k) => c.padEnd(coreCols[k].length)).join(" | ")}`);
  console.log(`\ncore: ${coreMatrix.length * coreCols.length - coreBad} identical and invariant-clean, ${coreBad} differ or fail`);
  bad += coreBad;
}
process.exit(bad ? 1 : 0);
