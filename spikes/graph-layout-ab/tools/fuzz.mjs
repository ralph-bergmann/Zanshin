#!/usr/bin/env node
// Differential fuzz for docs/graph-layout.md §7.1, beyond the fixed inputs. First fixed probes: input
// acceptance (§2 incl. its clarifications) and CLI exit codes (§6) must be as expected and the
// same on both sides, with equal outputs where accepted. Then random small inputs that hit the
// corners the real dumps do not (non-monotonic / null / future timestamps, a root with a ts,
// indirect first parents, missing-only nodes, several roots, priority ties, > 9 lanes so the
// windowed sift is not exact, odd UTC offsets). Each case runs Rust and Dart `layout` for every
// mode × order and compares them byte for byte with each other AND with a naive, literal JS
// reading of docs/graph-layout.md §4 (a third voter, quadratic, full cost recomputation per candidate).
//
//   node tools/fuzz.mjs [--cases N] [--seed S]      (defaults: 300 cases, seed 1)
//
// Cases are written to outputs/fuzz/; a failing one is kept as outputs/fuzz/fail-<seed>-<k>.json.
// Exit code 1 on any disagreement.

import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath, pathToFileURL } from "node:url";

const spike = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const BIN = {
  rust: path.join(spike, "rust/target/release/graph-layout"),
  dart: path.join(spike, "dart/build/graph_layout"),
};
const argv = process.argv.slice(2);
const opt = (f, d) => (argv.includes(f) ? Number(argv[argv.indexOf(f) + 1]) : d);
const CASES = opt("--cases", 300), SEED = opt("--seed", 1);

// ---- deterministic generator (splitmix32) --------------------------------------------------
export function rng(seed) {
  let s = seed >>> 0;
  const next = () => {
    s = (s + 0x9e3779b9) >>> 0;
    let z = s;
    z = Math.imul(z ^ (z >>> 16), 0x85ebca6b) >>> 0;
    z = Math.imul(z ^ (z >>> 13), 0xc2b2ae35) >>> 0;
    return (z ^ (z >>> 16)) >>> 0;
  };
  const int = (lo, hi) => lo + (next() % (hi - lo + 1)); // inclusive
  const chance = (p) => next() / 4294967296 < p;
  const pick = (a) => a[next() % a.length];
  return { int, chance, pick };
}

export const MIN = 60000, HOUR = 60 * MIN, DAY = 24 * HOUR;
/** Timestamp steps along an edge: span every age-ladder rung and several calendar days. */
export const STEPS = [0, 1000, MIN, 7 * MIN, 25 * MIN, 50 * MIN, 3 * HOUR, 10 * HOUR, 20 * HOUR, DAY, 3 * DAY, 40 * DAY];

/** One random input (SPEC §2) from the generator [r]; also the seeded fuzz cases of tools/goldens.mjs. */
export function genInput(r) {
  const n = r.chance(0.05) ? r.int(0, 2) : r.chance(0.15) ? r.int(60, 160) : r.int(3, 40);
  const width = r.pick([1, 2, 3, 6, 12, 30]); // how far back a first parent may reach
  const pMerge = r.pick([0, 0.1, 0.25, 0.5]);
  const pIndirect = r.pick([0, 0.15, 0.5]);
  const pMissing = r.pick([0, 0.05, 0.2]);
  const pNonMono = r.pick([0, 0.05, 0.3]);
  const prioMax = r.pick([0, 1, 2, 5, 1000]);
  const nodes = new Array(n);
  const base = 1_790_000_000_000;
  let newest = base;
  for (let i = n - 1; i >= 0; i--) {
    const parents = [];
    const last = i === n - 1;
    if (!last && !r.chance(0.04)) {
      const fp = r.int(i + 1, Math.min(n - 1, i + width));
      parents.push({ idx: fp, kind: r.chance(pIndirect) ? "indirect" : "direct" });
      while (r.chance(pMerge) && parents.length < 4) {
        const q = r.int(i + 1, n - 1);
        if (!parents.some((p) => p.idx === q)) parents.push({ idx: q, kind: r.chance(pIndirect) ? "indirect" : "direct" });
      }
    }
    if (r.chance(pMissing)) parents.splice(r.int(0, parents.length), 0, { idx: null, kind: "missing" });
    const isRoot = last && r.chance(0.6);
    let ts;
    if ((isRoot && !r.chance(0.3)) || r.chance(0.03)) ts = null;
    else {
      const pts = parents.filter((p) => p.idx !== null && nodes[p.idx].ts_ms !== null).map((p) => nodes[p.idx].ts_ms);
      const from = pts.length ? Math.max(...pts) : base - r.int(0, 60) * DAY;
      ts = r.chance(pNonMono) ? from - r.pick(STEPS) - r.int(0, 999) : from + r.pick(STEPS) + r.int(0, 999);
      newest = Math.max(newest, ts);
    }
    nodes[i] = { id: i.toString(16).padStart(8, "0"), ts_ms: ts, is_root: isRoot, priority: r.int(0, prioMax), parents };
  }
  const now = r.chance(0.1) ? newest - r.int(1, 30) * MIN : newest + r.pick([0, MIN, 11 * MIN, 5 * HOUR, 13 * HOUR, 2 * DAY]);
  const off = r.pick([0, 0, 120, -300, 330, 840, -720, 1440, -1440]);
  return { now_ms: now, utc_offset_min: off, nodes };
}

// ---- naive, literal reading of docs/graph-layout.md §4 (third voter) -------------------------------------
const fdiv = (a, b) => Math.floor(a / b); // exact here: |a| < 2^53 and quotients far from ties
function L2(x) { let k = 0; while (2 ** (k + 1) <= x) k++; return 256 * k + fdiv((x - 2 ** k) * 256, 2 ** k); }
const gap = (g) => Math.min(48, fdiv(2 * L2(1 + fdiv(g, MIN)), 256));
const LADDER = [10, 20, 40, 60, 120, 240, 480, 720];

export function reference(input, mode, order) {
  const N = input.nodes, n = N.length, U = mode === "free" ? 16 : 1;
  const LP = N.map((x) => x.parents.filter((p) => p.idx !== null).map((p) => p.idx));
  const C = N.map(() => []);
  for (let i = 0; i < n; i++) for (const p of LP[i]) C[p].push(i);
  const maxOr = (arr, d) => arr.reduce((m, v) => Math.max(m, v), d);
  const y = new Array(n), buckets = [];
  if (mode === "compact") {
    for (let i = n - 1; i >= 0; i--) y[i] = LP[i].length ? 1 + maxOr(LP[i].map((p) => y[p]), -Infinity) : 0;
  } else if (mode === "time") {
    const now = input.now_ms, off = input.utc_offset_min * MIN, b = [], kinds = new Map();
    for (let i = 0; i < n; i++) {
      const x = N[i];
      let key, kind, value;
      if (x.is_root || x.ts_ms === null) [key, kind, value] = [-Infinity, "root", 0];
      else {
        const m = LADDER.find((m) => now - x.ts_ms <= m * MIN);
        if (m !== undefined) [key, kind, value] = [now - m * MIN, "age", m];
        else { key = fdiv(x.ts_ms + off, DAY) * DAY - off; [kind, value] = ["day", key]; }
      }
      b[i] = key;
      kinds.set(key, { kind, value });
    }
    const eb = new Array(n);
    for (let i = n - 1; i >= 0; i--) eb[i] = maxOr(LP[i].map((p) => eb[p]), b[i]);
    let next = 0;
    for (const k of [...new Set(eb)].sort((a, c) => a - c)) {
      const start = next;
      let end = start;
      for (let i = n - 1; i >= 0; i--) if (eb[i] === k) { y[i] = maxOr(LP[i].map((p) => y[p] + 1), start); end = Math.max(end, y[i]); }
      buckets.push({ ...kinds.get(k), start, end });
      next = end + 1;
    }
  } else {
    const tss = N.filter((x) => x.ts_ms !== null).map((x) => x.ts_ms);
    const tmin = tss.length ? Math.min(...tss) : 0;
    const T = new Array(n);
    for (let i = n - 1; i >= 0; i--) T[i] = maxOr(LP[i].map((p) => T[p]), N[i].is_root || N[i].ts_ms === null ? tmin : N[i].ts_ms);
    let prev = -1;
    for (const i of [...Array(n).keys()].sort((a, c) => T[a] - T[c] || c - a)) {
      const base = prev < 0 ? 0 : y[prev] + gap(T[i] - T[prev]);
      y[i] = maxOr(LP[i].map((p) => y[p] + U), base);
      prev = i;
    }
    // Step 4 (amended 2026-10-01): one day bucket per local day of T, every non-root node, its
    // members' min / max y; literally, with no reliance on the walk order.
    const off = input.utc_offset_min * MIN, days = new Map();
    for (let i = 0; i < n; i++) {
      if (N[i].is_root) continue;
      const key = fdiv(T[i] + off, DAY) * DAY - off;
      const b = days.get(key);
      days.set(key, b ? { start: Math.min(b.start, y[i]), end: Math.max(b.end, y[i]) } : { start: y[i], end: y[i] });
    }
    for (const key of [...days.keys()].sort((a, c) => a - c)) buckets.push({ kind: "day", value: key, ...days.get(key) });
  }
  const key = (a, c) => N[a].priority - N[c].priority || a - c;
  const fp = (i) => (LP[i].length ? LP[i][0] : -1);
  const cont = N.map((_, j) => C[j].filter((i) => fp(i) === j).sort(key)[0] ?? -1);
  const lane = new Array(n), ivs = [], ys = [];
  for (const i of [...Array(n).keys()].sort((a, c) => y[a] - y[c] || key(a, c))) {
    const Ey = [];
    if (cont[i] >= 0) Ey.push(y[cont[i]]);
    for (const c of C[i]) if (LP[c].indexOf(i) >= 1) Ey.push(y[c]);
    const end = Ey.length ? Math.max(y[i], Math.max(...Ey) - U) : y[i];
    const f = fp(i), a = f >= 0 ? y[f] + U : y[i], b = end + 2 * U;
    const fits = (l, x) => (ivs[l] || []).every((iv) => iv.o === x || iv.b <= a);
    let L;
    if (f >= 0 && cont[f] === i && fits(lane[f], f)) L = lane[f];
    else { L = 0; while (!fits(L, -2)) L++; }
    (ivs[L] ??= []).push({ a, b, o: i });
    (ys[L] ??= []).push(y[i]);
    lane[i] = L;
  }
  const edges = [];
  for (let i = 0; i < n; i++) LP[i].forEach((p, k) => {
    const blocked = lane[i] !== lane[p] && ys[lane[p]].some((v) => v > y[p] && v <= y[i]);
    const route = lane[p] === lane[i] ? "straight" : k >= 1 && !blocked ? "merge" : "branch_off";
    edges.push({ from: p, to: i, kind: N[i].parents.find((q) => q.idx === p).kind, route, blocked });
  });
  const Lc = n ? Math.max(...lane) + 1 : 0;
  let pi = [...Array(Lc).keys()];
  if (order === "optimized") {
    const bot = (v) => 10 * y[v], top = (v) => bot(v) + 5 * U, up = (v) => bot(v) + 7 * U, dn = (v) => bot(v) - 2 * U;
    const verts = [], hors = [];
    for (const { from: p, to: i, route } of edges) {
      if (route === "straight") verts.push([lane[p], top(p), bot(i)]);
      else if (route === "merge") { verts.push([lane[p], top(p), dn(i)], [lane[i], dn(i), bot(i)]); hors.push([lane[p], lane[i], dn(i)]); }
      else { verts.push([lane[i], up(p), bot(i)]); hors.push([lane[p], lane[i], up(p)]); }
    }
    const m = (l, lam) => verts.filter((v) => v[0] === l && v[1] < lam && lam < v[2]).length;
    const cost = (q) => {
      let X = 0, Len = 0, D = 0;
      for (const [a, b, lam] of hors) {
        const lo = Math.min(q[a], q[b]), hi = Math.max(q[a], q[b]);
        Len += hi - lo;
        for (let l = 0; l < Lc; l++) if (q[l] > lo && q[l] < hi) X += m(l, lam);
      }
      q.forEach((c, l) => { D += Math.abs(c - l); });
      return 400 * X + 4 * Len + D;
    };
    const h = [...Array(Lc).keys()].map((l) => hors.filter(([a, b]) => a === l || b === l).length);
    const sift = [...Array(Lc).keys()].slice(1).sort((a, b) => h[b] - h[a] || a - b);
    const K = 8, R = 4, BUDGET = 2_000_000;
    let spent = 0;
    search: for (let round = 0; round < R; round++) {
      let moved = false;
      for (const A of sift) {
        const c = pi[A], lo = Math.max(1, c - K), hi = Math.min(Lc - 1, c + K);
        let work = 0;
        for (let B = 0; B < Lc; B++) if (B !== A && pi[B] >= lo && pi[B] <= hi) work += h[A] + h[B];
        if (spent + work > BUDGET) break search;
        spent += work;
        const base = cost(pi);
        let best = null;
        for (let d = lo; d <= hi; d++) {
          const byCol = [];
          pi.forEach((col, l) => { byCol[col] = l; });
          const rest = byCol.filter((l) => l !== A);
          rest.splice(d, 0, A);
          const q = new Array(Lc);
          rest.forEach((l, col) => { q[l] = col; });
          const cand = [cost(q) - base, Math.abs(d - c), d, q];
          if (!best || cand[0] < best[0] || (cand[0] === best[0] && (cand[1] < best[1] || (cand[1] === best[1] && cand[2] < best[2])))) best = cand;
        }
        if (best[0] < 0) { pi = best[3]; moved = true; }
      }
      if (!moved) break;
    }
  }
  const nodes = [...Array(n).keys()].map((i) => ({ row: y[i], lane: lane[i], col: pi[lane[i]] }));
  const out = { mode, order, unit: U, rows: n ? Math.max(...y) + U : 0, lanes: Lc, nodes, edges, buckets: mode === "compact" ? [] : buckets };
  return JSON.stringify(out) + "\n";
}

// ---- fixed probes: input acceptance (§2) and CLI (§6); both sides must agree -----------------
const OK = '{"id":"a","ts_ms":5,"is_root":false,"priority":1,"parents":[{"idx":1,"kind":"direct"}]}';
const ROOT = '{"id":"r","ts_ms":null,"is_root":true,"priority":0,"parents":[]}';
const doc = (node0 = OK, head = '"now_ms":10,"utc_offset_min":0') => `{${head},"nodes":[${node0},${ROOT}]}`;
const alt = (from, to) => doc(OK.replace(from, to));
/** [name, input text, expected exit code] */
export const PROBES = [
  ["valid", doc(), 0],
  ["empty graph", '{"now_ms":0,"utc_offset_min":0,"nodes":[]}', 0],
  ["no id", alt('"id":"a",', ""), 0],
  ["id is a number", alt('"id":"a"', '"id":7'), 0],
  ["unknown keys", doc(OK.replace('"id"', '"x":[1,{}],"id"'), '"y":null,"now_ms":10,"utc_offset_min":0'), 0],
  ["duplicate key, last wins", alt('"priority":1', '"priority":9,"priority":1'), 0],
  ["whitespace and key order", ` { "nodes" : [ ${OK} , ${ROOT} ] , "utc_offset_min" : 0 , "now_ms" : 10 } \n`, 0],
  ["root with a ts", doc(OK, '"now_ms":10,"utc_offset_min":0').replace('"ts_ms":null', '"ts_ms":2'), 0],
  ["two missing parents", alt('{"idx":1,"kind":"direct"}', '{"idx":null,"kind":"missing"},{"idx":1,"kind":"direct"},{"idx":null,"kind":"missing"}'), 0],
  ["ts 2^53", alt('"ts_ms":5', '"ts_ms":9007199254740992'), 0],
  ["utc_offset_min -1440", doc(OK, '"now_ms":10,"utc_offset_min":-1440'), 0],
  ["utc_offset_min 1441", doc(OK, '"now_ms":10,"utc_offset_min":1441'), 2],
  ["utc_offset_min 2^53", doc(OK, '"now_ms":10,"utc_offset_min":9007199254740992'), 2],
  ["ts 2^53 + 1", alt('"ts_ms":5', '"ts_ms":9007199254740993'), 2],
  ["now_ms -2^53 - 1", doc(OK, '"now_ms":-9007199254740993,"utc_offset_min":0'), 2],
  ["absent ts_ms", alt('"ts_ms":5,', ""), 2],
  ["absent idx", alt('"idx":1,"kind":"direct"', '"kind":"missing"'), 2],
  ["absent is_root", alt('"is_root":false,', ""), 2],
  ["absent priority", alt('"priority":1,', ""), 2],
  ["absent parents", alt(',"parents":[{"idx":1,"kind":"direct"}]', ""), 2],
  ["absent now_ms", '{"utc_offset_min":0,"nodes":[]}', 2],
  ["is_root 1", alt('"is_root":false', '"is_root":0'), 2],
  ["priority string", alt('"priority":1', '"priority":"1"'), 2],
  ["priority -1", alt('"priority":1', '"priority":-1'), 2],
  ["priority -0", alt('"priority":1', '"priority":-0'), 0],
  ["priority -0.0", alt('"priority":1', '"priority":-0.0'), 2],
  ["priority [-0] in an array", alt('"priority":1', '"priority":[-0]'), 2],
  ["-0 after a string with an escaped quote", alt('"id":"a"', '"id":"x\\"-0,","y":-0.0').replace('"priority":1', '"priority":-0'), 0],
  ["priority 2^31", alt('"priority":1', '"priority":2147483648'), 2],
  ["priority 1.0", alt('"priority":1', '"priority":1.0'), 2],
  ["priority 1e0", alt('"priority":1', '"priority":1e0'), 2],
  ["priority 10^400", alt('"priority":1', `"priority":1${"0".repeat(400)}`), 2],
  ["ts float", alt('"ts_ms":5', '"ts_ms":5.5'), 2],
  ["ts -0", alt('"ts_ms":5', '"ts_ms":-0'), 0],
  ["ts -0e0", alt('"ts_ms":5', '"ts_ms":-0e0'), 2],
  ["ts -01", alt('"ts_ms":5', '"ts_ms":-01'), 2],
  ["V1 null idx direct", alt('"idx":1', '"idx":null'), 2],
  ["V1 idx on missing", alt('"direct"', '"missing"'), 2],
  ["V2 self", alt('"idx":1', '"idx":0'), 2],
  ["V2 beyond n", alt('"idx":1', '"idx":2'), 2],
  ["V3 duplicate", alt('{"idx":1,"kind":"direct"}', '{"idx":1,"kind":"direct"},{"idx":1,"kind":"indirect"}'), 2],
  ["unknown kind", alt('"direct"', '"Direct"'), 2],
  ["nodes not an array", '{"now_ms":0,"utc_offset_min":0,"nodes":{}}', 2],
  ["top level array", "[]", 2],
  ["trailing garbage", doc() + " x", 2],
  ["empty file", "", 2],
  ["byte order mark", "﻿" + doc(), 2],
  ["invalid UTF-8 in id", Buffer.from(alt('"id":"a"', '"id":"\u0000"'), "latin1").map((b) => (b === 0 ? 0xff : b)), 2],
  ["lone surrogate escape in id", alt('"id":"a"', '"id":"\\ud800"'), 0],
  ["unescaped control char in id", alt('"id":"a"', '"id":"a\tb"'), 2],
  ["nesting 1000 deep in an unknown key", alt('"id":"a"', `"x":${"[".repeat(1000)}${"]".repeat(1000)}`), 0],
  ["NaN", alt('"ts_ms":5', '"ts_ms":NaN'), 2],
  ["leading +", alt('"ts_ms":5', '"ts_ms":+5'), 2],
  ["trailing comma", alt('"parents":[{"idx":1,"kind":"direct"}]', '"parents":[{"idx":1,"kind":"direct"},]'), 2],
];
/** [name, args with IN / OUT placeholders, expected exit code] */
export const CLI_PROBES = [
  ["layout ok", ["layout", "--mode", "time", "--order", "greedy", "IN", "OUT"], 0],
  ["--flag=value", ["layout", "--mode=free", "--order=optimized", "IN", "OUT"], 0],
  ["bench defaults", ["bench", "--mode", "compact", "--order", "greedy", "--warmup", "0", "--runs", "1", "IN"], 0],
  ["unknown command", ["draw", "--mode", "time", "--order", "greedy", "IN", "OUT"], 2],
  ["unknown flag", ["layout", "--mode", "time", "--order", "greedy", "--fast", "1", "IN", "OUT"], 2],
  ["repeated flag", ["layout", "--mode", "time", "--mode", "free", "--order", "greedy", "IN", "OUT"], 2],
  ["bad mode", ["layout", "--mode", "hybrid", "--order", "greedy", "IN", "OUT"], 2],
  ["missing --order", ["layout", "--mode", "time", "IN", "OUT"], 2],
  ["--runs on layout", ["layout", "--mode", "time", "--order", "greedy", "--runs", "3", "IN", "OUT"], 2],
  ["--runs 0", ["bench", "--mode", "time", "--order", "greedy", "--runs", "0", "IN"], 2],
  ["--warmup -1", ["bench", "--mode", "time", "--order", "greedy", "--warmup", "-1", "IN"], 2],
  ["one file for layout", ["layout", "--mode", "time", "--order", "greedy", "IN"], 2],
  ["unreadable input", ["layout", "--mode", "time", "--order", "greedy", "NOPE", "OUT"], 2],
  ["unwritable output", ["layout", "--mode", "time", "--order", "greedy", "IN", "NODIR/out.json"], 2],
];

// ---- driver ----------------------------------------------------------------------------------
if (import.meta.url === pathToFileURL(process.argv[1]).href) main();

function main() {
  const dir = path.join(spike, "outputs/fuzz");
  fs.mkdirSync(dir, { recursive: true });
  const firstDiff = (a, b) => {
    let k = 0;
    while (k < a.length && a[k] === b[k]) k++;
    return `@${k}: …${a.slice(Math.max(0, k - 60), k + 40)}… vs …${b.slice(Math.max(0, k - 60), k + 40)}…`;
  };
  let bad = 0, lanesMax = 0;

  // Fixed probes: same exit code on both sides, as expected, and equal outputs when accepted.
  const probe = (name, args, want) => {
    const got = {};
    for (const impl of ["rust", "dart"]) {
      const out = path.join(dir, `probe.${impl}.json`);
      fs.rmSync(out, { force: true });
      const argv = args.map((a) => ({ IN: path.join(dir, "probe.json"), OUT: out, NOPE: path.join(dir, "absent.json"), "NODIR/out.json": path.join(dir, "absent/out.json") })[a] ?? a);
      const r = spawnSync(BIN[impl], argv, { encoding: "utf8" });
      got[impl] = { status: r.status, out: fs.existsSync(out) ? fs.readFileSync(out, "utf8") : null };
    }
    const ok = got.rust.status === want && got.dart.status === want && got.rust.out === got.dart.out && (want === 0 || got.rust.out === null);
    if (!ok) { bad++; console.log(`probe "${name}": want exit ${want}; rust exit ${got.rust.status}, dart exit ${got.dart.status}${got.rust.out === got.dart.out ? "" : ", outputs differ"}`); }
  };
  for (const [name, text, want] of PROBES) {
    fs.writeFileSync(path.join(dir, "probe.json"), text);
    for (const mode of ["time", "free"]) probe(`${name} (${mode})`, ["layout", "--mode", mode, "--order", "optimized", "IN", "OUT"], want);
  }
  fs.writeFileSync(path.join(dir, "probe.json"), PROBES[0][1]);
  for (const [name, args, want] of CLI_PROBES) probe(name, args, want);
  const probeBad = bad;
  console.log(`probes: ${PROBES.length} inputs × 2 modes + ${CLI_PROBES.length} CLI calls, ${probeBad} not as expected on both sides`);

  for (let c = 0; c < CASES; c++) {
    const input = genInput(rng(SEED * 1_000_003 + c));
    const inFile = path.join(dir, "case.json");
    fs.writeFileSync(inFile, JSON.stringify(input) + "\n");
    for (const mode of ["compact", "time", "free"]) for (const order of ["greedy", "optimized"]) {
      const got = {};
      for (const impl of ["rust", "dart"]) {
        const out = path.join(dir, `case.${impl}.json`);
        fs.rmSync(out, { force: true });
        const r = spawnSync(BIN[impl], ["layout", "--mode", mode, "--order", order, inFile, out], { encoding: "utf8" });
        got[impl] = r.status === 0 ? fs.readFileSync(out, "utf8") : `exit ${r.status}: ${r.stderr}`;
      }
      const ref = reference(input, mode, order);
      lanesMax = Math.max(lanesMax, JSON.parse(ref).lanes);
      const msgs = [];
      if (got.rust !== got.dart) msgs.push(`rust≠dart ${firstDiff(got.rust, got.dart)}`);
      if (got.rust !== ref) msgs.push(`rust≠ref ${firstDiff(got.rust, ref)}`);
      if (got.dart !== ref) msgs.push(`dart≠ref ${firstDiff(got.dart, ref)}`);
      if (msgs.length) {
        bad++;
        const keep = path.join(dir, `fail-${SEED}-${c}.json`);
        fs.copyFileSync(inFile, keep);
        console.log(`case ${c} (${input.nodes.length} nodes) ${mode}/${order} → ${path.relative(spike, keep)}\n  ${msgs.join("\n  ")}`);
      }
    }
  }
  console.log(`random: ${CASES} cases × 6 runs, seed ${SEED}: ${CASES * 6 - (bad - probeBad)} agree (rust = dart = reference), ${bad - probeBad} disagree; max lanes ${lanesMax}`);
  process.exit(bad ? 1 : 0);
}
