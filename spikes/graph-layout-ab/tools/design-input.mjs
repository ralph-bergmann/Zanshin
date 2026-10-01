#!/usr/bin/env node
// Converts the design's own sample (graph-data.js) into layout INPUT files, as docs/graph-layout.md §7.2
// defines them: inputs/design-default.json and inputs/design-all.json.
//
//   node tools/design-input.mjs [--rev <commit>]   (from the spike root; sets TZ=UTC itself)
//
// The design is read from git at the pinned export (tools/design-source.mjs), never from the live
// export folder. `--rev` converts another export instead, into inputs/design-<commit>-<rev>.json;
// the pinned inputs are never overwritten.
//
// It evaluates graph-data.js plus the declarations docs/graph-layout.md §7.2 names, extracted BY NAME from
// graph-view.jsx (the JSX parts are never evaluated), and reads the design's own visible set
// from computeLayout(GRAPH_COMMITS, rev, 240, 62, "compact", {optimize: false}).nodes, so the
// parents (incl. `skipped` → indirect) and `elided` (→ one missing entry) are the design's.
//
// The oracle can reuse `loadDesign` / `designInput` instead of re-deriving the input.
//
// Faithfulness note: the mock's default set is converted as the mock says (14 of 22 commits).
// Its wqnwkozp carries inDefault: true, which is wrong for the revset it claims
// (present(@) | ancestors(immutable_heads().., 2) | trunk()): jj would show 13 commits, with
// the elided stub under vruxwmqv instead of wqnwkozp.

process.env.TZ = "UTC"; // Date.parse of the mock's zone-less ISO strings is local time

import fs from "node:fs";
import path from "node:path";
import vm from "node:vm";
import { fileURLToPath, pathToFileURL } from "node:url";
import { DESIGN_REV, designFile } from "./design-source.mjs";

const spike = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

export const DECLARATIONS = ["G", "LADDER", "timeBucket", "roundedPath", "routeEdges", "analyzeEdges", "optimizeLanes", "computeLayout"];

// A top-level `const NAME = …;` (one line) or `function NAME(…) {` up to the next line that is
// exactly "}" — the file's own layout; anything else fails loudly.
function extract(src, name) {
  const lines = src.split("\n");
  const i = lines.findIndex((l) => l.startsWith(`const ${name} =`) || l.startsWith(`function ${name}(`));
  if (i < 0) throw new Error(`graph-view.jsx: no top-level declaration of ${name}`);
  if (lines[i].startsWith("const ")) {
    if (!lines[i].trimEnd().endsWith(";")) throw new Error(`graph-view.jsx: ${name} is not a one-line const`);
    return lines[i];
  }
  const j = lines.findIndex((l, k) => k > i && l === "}");
  if (j < 0) throw new Error(`graph-view.jsx: unterminated function ${name}`);
  return lines.slice(i, j + 1).join("\n");
}

/** The design's declarations + GRAPH_COMMITS / GRAPH_NOW of the export at `commit`, evaluated in a fresh context. */
export function loadDesign(commit = DESIGN_REV) {
  if (new Date(2026, 0, 1).getTimezoneOffset() !== 0) throw new Error("run with TZ=UTC");
  const jsx = designFile("graph-view.jsx", commit);
  const ctx = vm.createContext({});
  // From e243dd2 on, computeLayout calls graph-gaps.jsx's placeGapMarkers. Its markers are
  // drawing only, never layout input, so a no-op stands in.
  vm.runInContext("var window = globalThis; window.placeGapMarkers = () => [];", ctx);
  vm.runInContext(designFile("graph-data.js", commit), ctx, { filename: "graph-data.js" });
  const src = DECLARATIONS.map((n) => extract(jsx, n)).join("\n");
  vm.runInContext(`${src}\nglobalThis.__design = { ${DECLARATIONS.join(", ")} };`, ctx, { filename: "graph-view.jsx (extracted)" });
  // ctx: the design's `window`; timeBucket reads window.GRAPH_NOW (tools/js_oracle.mjs --fuzz sets it).
  return { ...ctx.__design, GRAPH_COMMITS: ctx.GRAPH_COMMITS, GRAPH_NOW: ctx.GRAPH_NOW, ctx };
}

/** docs/graph-layout.md §7.2: the input for rev ∈ {"default", "all"} (of the sample, or of other design-shaped commits). */
export function designInput(d, rev, commits = d.GRAPH_COMMITS, nowIso = d.GRAPH_NOW) {
  const L = d.computeLayout(commits, rev, 240, 62, "compact", { optimize: false });
  const nodes = L.nodes; // design order: root first; node k has idx k
  const n = nodes.length;
  const at = new Map(nodes.map((x, k) => [x.id, n - 1 - k]));
  // priority = 0-based rank of (c.priority, design index) — folds the float priority and the
  // root-first idx into one integer (D3).
  const prio = new Array(n);
  [...nodes.keys()]
    .sort((a, b) => nodes[a].c.priority - nodes[b].c.priority || nodes[a].idx - nodes[b].idx)
    .forEach((k, rank) => { prio[k] = rank; });
  const out = [];
  for (let k = n - 1; k >= 0; k--) {
    const x = nodes[k];
    const parents = x.parents.map((p) => ({ idx: at.get(p.id), kind: p.skipped ? "indirect" : "direct" }));
    // One Missing entry per Missing parent, as jj yields them. `missing` exists from e243dd2 on;
    // older exports only sum the hidden commits into `elided`.
    const missing = x.missing ? x.missing.length : x.elided > 0 ? 1 : 0;
    for (let m = 0; m < missing; m++) parents.push({ idx: null, kind: "missing" });
    out.push({ id: x.id, ts_ms: x.c.ts ? Date.parse(x.c.ts) : null, is_root: !!x.c.isRoot, priority: prio[k], parents });
  }
  return { now_ms: Date.parse(nowIso), utc_offset_min: 0, nodes: out };
}

/** docs/graph-layout.md §2 V1-V4 (V3 over non-null idx). Throws on the first violation. */
export function validate(input) {
  const n = input.nodes.length;
  const safe = (v) => Number.isSafeInteger(v);
  if (!safe(input.now_ms) || !safe(input.utc_offset_min) || Math.abs(input.utc_offset_min) > 1440) throw new Error("V4: header");
  input.nodes.forEach((x, i) => {
    if (x.ts_ms !== null && !safe(x.ts_ms)) throw new Error(`V4: node ${i} ts`);
    if (!safe(x.priority) || x.priority < 0 || x.priority >= 2 ** 31) throw new Error(`V4: node ${i} priority`);
    const seen = new Set();
    for (const p of x.parents) {
      if ((p.idx === null) !== (p.kind === "missing")) throw new Error(`V1: node ${i}`);
      if (p.idx === null) continue;
      if (!(i < p.idx && p.idx < n)) throw new Error(`V2: node ${i} parent ${p.idx}`);
      if (seen.has(p.idx)) throw new Error(`V3: node ${i} parent ${p.idx} twice`);
      seen.add(p.idx);
    }
  });
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  const args = process.argv.slice(2);
  if (args.length && !(args.length === 2 && args[0] === "--rev")) throw new Error("usage: node tools/design-input.mjs [--rev <commit>]");
  const commit = args.length ? args[1] : DESIGN_REV;
  const prefix = commit === DESIGN_REV ? "design" : `design-${commit}`;
  const d = loadDesign(commit);
  const dir = path.join(spike, "inputs");
  fs.mkdirSync(dir, { recursive: true });
  for (const rev of ["default", "all"]) {
    const input = designInput(d, rev);
    validate(input);
    const file = path.join(dir, `${prefix}-${rev}.json`);
    fs.writeFileSync(file, JSON.stringify(input) + "\n"); // insertion order = the canonical key order
    const kinds = { direct: 0, indirect: 0, missing: 0 };
    input.nodes.forEach((x) => x.parents.forEach((p) => { kinds[p.kind]++; }));
    console.error(`wrote ${path.relative(spike, file)}: ${input.nodes.length} nodes, edges ${JSON.stringify(kinds)}`);
  }
}
