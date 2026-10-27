#!/usr/bin/env node
// SPDX-License-Identifier: MIT
//
// Story 4.14 (I1) — the design's layout engine `graph-layout.jsx` (GL), evaluated whole, and the
// joint-columns design oracle (docs/graph-layout.md §7.2, amended 2026-10-27).
//
//   node tools/design-layout.mjs [--rev <commit>]   (from the spike root; sets TZ=UTC itself)
//
// From e74ced3 on, the export keeps its layout in graph-layout.jsx — plain JS, one IIFE that sets
// window.computeLayout — instead of graph-view.jsx, so the by-name extraction of
// tools/design-input.mjs cannot read it. `loadLayout` evaluates graph-data.js and graph-layout.jsx
// whole in a fresh vm context: `window` = the context's global, the Graph Lines Study's
// revsetMatch stub (its line 54) and a no-op placeGapMarkers (its markers are drawing only).
// `exact: false` removes GL's one exact-colouring candidate line by a checked substitution.
//
// The CLI runs GL's computeLayout(GRAPH_COMMITS, revset, 240, 62, "compact", {optimize: false})
// for revset ∈ {default, all}, with and without exact colouring, and compares GL's greedy lane
// count (exact colouring off: the fewer of its two greedy candidates, packed in Free and in
// Compact order) with the spike's Dart binary `layout --mode compact --order greedy --columns
// joint` on inputs/design-e243dd2-<revset>.json (the sample's data is unchanged at e74ced3; run
// `node tools/design-input.mjs --rev e243dd2` first). It writes
// outputs/oracle/joint-design-<revset>.lanes.json and exits 1 on a mismatch — then re-derive by
// hand before changing code.

process.env.TZ = "UTC"; // Date.parse of the mock's zone-less ISO strings is local time

import fs from "node:fs";
import path from "node:path";
import vm from "node:vm";
import { spawnSync } from "node:child_process";
import { fileURLToPath, pathToFileURL } from "node:url";
import { designFile } from "./design-source.mjs";

const spike = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

/** The floating-client export whose graph-layout.jsx shares one set of columns between Free and Compact. */
export const LAYOUT_REV = "e74ced3";

/** GL's exact-colouring candidate (graph-layout.jsx:525 at e74ced3), removed by `exact: false`. */
const EXACT_LINE = "if (Math.min(...cands.map(c => c.count)) > 2) { const X = exact(); if (X) cands.push(X); }";

/** GL evaluated whole at `commit`: its computeLayout and the sample's GRAPH_COMMITS / GRAPH_NOW. */
export function loadLayout(commit = LAYOUT_REV, { exact = true } = {}) {
  if (new Date(2026, 0, 1).getTimezoneOffset() !== 0) throw new Error("run with TZ=UTC");
  let src = designFile("graph-layout.jsx", commit);
  if (!exact) {
    if (src.split(EXACT_LINE).length !== 2) throw new Error(`graph-layout.jsx at ${commit}: the exact-colouring line is not there exactly once`);
    src = src.replace(EXACT_LINE, "/* exact colouring disabled (tools/design-layout.mjs) */");
  }
  const ctx = vm.createContext({});
  vm.runInContext(
    'var window = globalThis; window.placeGapMarkers = () => []; window.revsetMatch = (id) => id === "all" ? () => true : (c) => !!c.inDefault;',
    ctx,
  );
  vm.runInContext(designFile("graph-data.js", commit), ctx, { filename: "graph-data.js" });
  vm.runInContext(src, ctx, { filename: "graph-layout.jsx" });
  if (typeof ctx.computeLayout !== "function") throw new Error(`graph-layout.jsx at ${commit} sets no window.computeLayout`);
  return { computeLayout: ctx.computeLayout, GRAPH_COMMITS: ctx.GRAPH_COMMITS, GRAPH_NOW: ctx.GRAPH_NOW, ctx };
}

/** GL's lane count for `revset`: max lane + 1 over its nodes. */
function glLanes(d, revset) {
  const L = d.computeLayout(d.GRAPH_COMMITS, revset, 240, 62, "compact", { optimize: false });
  return Math.max(...L.nodes.map((n) => n.lane)) + 1;
}

/** The spike's Dart binary's joint greedy lane count on `inFile`. */
function dartJointLanes(inFile) {
  const bin = path.join(spike, "dart/build/graph_layout");
  if (!fs.existsSync(bin)) throw new Error(`missing ${bin}: dart compile exe dart/bin/graph_layout.dart -o dart/build/graph_layout`);
  const outFile = path.join(spike, "outputs/oracle/joint-design.out.json");
  fs.rmSync(outFile, { force: true });
  const r = spawnSync(bin, ["layout", "--mode", "compact", "--order", "greedy", "--columns", "joint", inFile, outFile], { encoding: "utf8" });
  if (r.status !== 0) throw new Error(`dart joint layout of ${path.basename(inFile)}: exit ${r.status} ${r.stderr}`);
  const lanes = JSON.parse(fs.readFileSync(outFile, "utf8")).lanes;
  fs.rmSync(outFile);
  return lanes;
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  const args = process.argv.slice(2);
  if (args.length && !(args.length === 2 && args[0] === "--rev")) throw new Error("usage: node tools/design-layout.mjs [--rev <commit>]");
  const commit = args.length ? args[1] : LAYOUT_REV;
  const greedy = loadLayout(commit, { exact: false });
  const exact = loadLayout(commit);
  fs.mkdirSync(path.join(spike, "outputs/oracle"), { recursive: true });
  let failed = false;
  for (const revset of ["default", "all"]) {
    const inFile = path.join(spike, "inputs", `design-e243dd2-${revset}.json`);
    if (!fs.existsSync(inFile)) throw new Error(`missing ${inFile}: run node tools/design-input.mjs --rev e243dd2 first`);
    const record = {
      design: commit,
      revset,
      input: path.relative(spike, inFile),
      gl_greedy_lanes: glLanes(greedy, revset),
      gl_exact_lanes: glLanes(exact, revset),
      joint_greedy_lanes: dartJointLanes(inFile),
    };
    const ok = record.joint_greedy_lanes === record.gl_greedy_lanes;
    if (!ok) failed = true;
    const file = path.join(spike, "outputs/oracle", `joint-design-${revset}.lanes.json`);
    fs.writeFileSync(file, JSON.stringify(record, null, 2) + "\n");
    console.log(`${ok ? "ok  " : "FAIL"} ${revset}: GL greedy ${record.gl_greedy_lanes}, GL exact ${record.gl_exact_lanes}, Dart joint greedy ${record.joint_greedy_lanes} → ${path.relative(spike, file)}`);
  }
  if (failed) process.exitCode = 1;
}
