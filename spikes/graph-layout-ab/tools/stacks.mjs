#!/usr/bin/env node
// SPDX-License-Identifier: MIT
//
// Story 4.13 — commit stacks (docs/graph-layout.md §4.8): the run-rule oracle and the stack
// inputs.
//
//   node tools/stacks.mjs                    (from the spike root; needs dart/build/graph_layout)
//   node tools/stacks.mjs facts <in> <out>   (adds deterministic synthetic stack facts to an input)
//
// Without arguments, four steps; any failure exits 1:
//   1. The oracle check. The design sample at e243dd2 (52 commits) is the run-rule oracle only if
//      the design's gap walk (computeLayout's parents / missing, which keeps transitive indirect
//      edges) yields jj's edges on it. This step re-runs that check against a port of jj-lib
//      0.44's RevsetGraphWalk semantics (default_index/revset_graph_iterator.rs: Direct, the
//      closest in-set ancestors as Indirect, one Missing per parent that reaches no in-set commit,
//      `remove_transitive_edges`) for both revsets. On a difference it stops: the fallback is the
//      36-commit sample at a399daf plus the hand-built gap cases (decisions-review-4-10-to-4-13.md,
//      Story 4.13, "Tests").
//   2. inputs/stacks-design-{default,all}.json: tools/design-input.mjs's input of the sample at
//      e243dd2 plus every node's stack facts (key = change id, immutable, parent_count = the real
//      parents, has_ref = a bookmark, working_copy = "this" for the design's @).
//   3. outputs/oracle/stacks-design-{default,all}.runs.json: the design's own groupStacks(all,
//      rev, []) (extracted by name, like design-input.mjs), as runs of input node indices, oldest
//      member first, ordered by newest member index (§4.8 step 2).
//   4. The spike's Dart binary (`layout --stacks`, default request) must yield exactly those runs.
//
// genStackInput / stackRequest (seeded, tools/fuzz.mjs's rng) are tools/goldens.mjs's stack fuzz
// cases.

process.env.TZ = "UTC";

import fs from "node:fs";
import path from "node:path";
import vm from "node:vm";
import { spawnSync } from "node:child_process";
import { fileURLToPath, pathToFileURL } from "node:url";
import { designFile } from "./design-source.mjs";
import { designInput, extract, loadDesign, validate } from "./design-input.mjs";

const spike = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const DART = path.join(spike, "dart/build/graph_layout");

/** The design export the run-rule oracle reads (52 commits; decisions-review 4.13). */
export const ORACLE_REV = "e243dd2b11e9bbbdb6920122bf4a94d689533394";
const FALLBACK_REV = "a399daf";
const REVS = ["default", "all"];
/** The runs §4.8 must find, per revset (the story's matrix): key and member count. */
const EXPECTED = {
  default: [["uwqmpnrk", 2], ["mwoqxlpn", 4], ["qmsvtlkr", 3], ["nqxwrptl", 2], ["pnwqxrtk", 2], ["tqwmlnxz", 2]],
  all: [["mzvwutvl", 2], ["nvkqlxsp", 2], ["uwqmpnrk", 2], ["mwoqxlpn", 4], ["qmsvtlkr", 3], ["nqxwrptl", 2], ["pnwqxrtk", 7]],
};

// ---- 1. jj-lib 0.44's RevsetGraphWalk, semantically ---------------------------------------------

/** Every visible commit's edges as jj yields them: [{kind: "direct"|"indirect"|"missing", target}]. */
export function jjEdges(all, rev) {
  const byId = new Map(all.map((c) => [c.id, c]));
  const S = new Set((rev === "all" ? all : all.filter((c) => c.inDefault)).map((c) => c.id));
  const ancMemo = new Map();
  const ancestors = (id) => {
    if (ancMemo.has(id)) return ancMemo.get(id);
    const out = new Set();
    const stack = [...byId.get(id).parents];
    while (stack.length) {
      const x = stack.pop();
      if (out.has(x)) continue;
      out.add(x);
      stack.push(...byId.get(x).parents);
    }
    ancMemo.set(id, out);
    return out;
  };
  const reaches = (p) => S.has(p) || [...ancestors(p)].some((a) => S.has(a));
  const missing = (e) => e.kind === "missing";
  // remove_transitive_edges: only with an indirect edge; drops every non-missing edge whose
  // target is a strict ancestor of a target.
  const removeTransitive = (edges) => {
    if (!edges.some((e) => e.kind === "indirect")) return edges;
    const unwanted = new Set();
    for (const e of edges) if (!missing(e)) for (const a of ancestors(e.target)) unwanted.add(a);
    return edges.filter((e) => missing(e) || !unwanted.has(e.target));
  };
  // The edges of a commit outside the set (edges_from_external_commit). One parent: the parent
  // itself (in the set), its own external edges, or Missing when they are all missing. Several:
  // the same per parent, the external edges deduplicated by target (known_ancestors), then the
  // transitive ones removed.
  const extMemo = new Map();
  const viaParents = (parents, inSetKind) => {
    if (parents.length === 1) {
      const p = parents[0];
      if (S.has(p)) return [{ kind: inSetKind, target: p }];
      if (!reaches(p)) return [{ kind: "missing", target: p }];
      const pe = ext(p);
      return pe.every(missing) ? [{ kind: "missing", target: p }] : pe;
    }
    const edges = [];
    const known = new Set();
    for (const p of parents) {
      if (S.has(p)) edges.push({ kind: inSetKind, target: p });
      else if (!reaches(p)) edges.push({ kind: "missing", target: p });
      else {
        const pe = ext(p);
        if (pe.every(missing)) edges.push({ kind: "missing", target: p });
        else for (const e of pe) if (!known.has(e.target)) known.add(e.target), edges.push(e);
      }
    }
    return removeTransitive(edges);
  };
  const ext = (x) => {
    if (!extMemo.has(x)) extMemo.set(x, viaParents(byId.get(x).parents, "indirect"));
    return extMemo.get(x);
  };
  const out = new Map();
  for (const c of all) if (S.has(c.id)) out.set(c.id, viaParents(c.parents, "direct"));
  return out;
}

/** The design's own edges (computeLayout's gap walk) in the same shape. */
function designEdges(d, rev) {
  const L = d.computeLayout(d.GRAPH_COMMITS, rev, 240, 62, "compact", { optimize: false });
  const out = new Map();
  for (const x of L.nodes) {
    out.set(x.id, [
      ...x.parents.map((p) => ({ kind: p.skipped ? "indirect" : "direct", target: p.id })),
      ...x.missing.map((m) => ({ kind: "missing", target: m.via })),
    ]);
  }
  return out;
}

function oracleCheck(d) {
  for (const rev of REVS) {
    const jj = jjEdges(d.GRAPH_COMMITS, rev);
    const design = designEdges(d, rev);
    const counts = { direct: 0, indirect: 0, missing: 0 };
    const diffs = [];
    if (jj.size !== design.size) diffs.push(`${jj.size} jj nodes vs ${design.size} design nodes`);
    for (const [id, edges] of jj) {
      edges.forEach((e) => counts[e.kind]++);
      // Layout edges in order; Missing edges by count (the input lists them after the others).
      const real = (es) => JSON.stringify(es.filter((e) => e.kind !== "missing").map((e) => [e.kind, e.target]));
      const nMissing = (es) => es.filter((e) => e.kind === "missing").length;
      const theirs = design.get(id) ?? [];
      if (real(edges) !== real(theirs) || nMissing(edges) !== nMissing(theirs)) {
        diffs.push(`${id}: jj ${JSON.stringify(edges)} vs design ${JSON.stringify(theirs)}`);
      }
    }
    if (diffs.length) {
      console.error(`stacks: the design's gap walk at ${ORACLE_REV.slice(0, 7)} (${rev}) differs from jj's edges:`);
      diffs.slice(0, 10).forEach((x) => console.error(`  ${x}`));
      console.error(`stacks: the run-rule oracle falls back to the 36-commit sample at ${FALLBACK_REV} plus the hand-built gap cases`);
      process.exit(1);
    }
    console.error(`stacks: ${rev}: jj edges == the design's gap walk (${counts.direct} direct, ${counts.indirect} indirect, ${counts.missing} missing)`);
  }
}

// ---- 2. the stack inputs ------------------------------------------------------------------------

/** docs/graph-layout.md §2 (amended 2026-10-01): the design sample's input for `rev` plus every node's stack facts. */
export function stackDesignInput(d, rev) {
  const input = designInput(d, rev);
  const byId = new Map(d.GRAPH_COMMITS.map((c) => [c.id, c]));
  input.nodes = input.nodes.map((x) => {
    const c = byId.get(x.id);
    return {
      ...x,
      key: c.id,
      immutable: !!c.immutable,
      parent_count: c.parents.length,
      has_ref: c.bookmarks.length > 0,
      working_copy: c.isWorkingCopy ? "this" : null,
    };
  });
  return input;
}

// ---- 3. the design's groupStacks ----------------------------------------------------------------

function designRuns(d, rev, input) {
  if (!d.ctx.__groupStacks) {
    vm.runInContext(`${extract(designFile("graph-view.jsx", ORACLE_REV), "groupStacks")}\nglobalThis.__groupStacks = groupStacks;`, d.ctx, {
      filename: "graph-view.jsx (groupStacks)",
    });
  }
  const index = new Map(input.nodes.map((x, i) => [x.key, i]));
  return d.ctx.__groupStacks(d.GRAPH_COMMITS, rev, []).runs
    .map((r) => ({ key: r.members[0].id, members: r.members.map((m) => index.get(m.id)) }))
    .sort((a, b) => a.members[a.members.length - 1] - b.members[b.members.length - 1]);
}

// ---- 4. the Dart binary --------------------------------------------------------------------------

function dartRuns(inFile, requestFile, mode = "compact", order = "greedy") {
  const out = path.join(spike, "outputs/stacks/out.json");
  fs.mkdirSync(path.dirname(out), { recursive: true });
  fs.rmSync(out, { force: true });
  const r = spawnSync(DART, ["layout", "--mode", mode, "--order", order, "--stacks", requestFile, inFile, out], { encoding: "utf8" });
  if (r.status !== 0) throw new Error(`dart layout --stacks ${path.basename(inFile)}: exit ${r.status} ${r.stderr}`);
  return JSON.parse(fs.readFileSync(out, "utf8")).runs;
}

// ---- seeded stack-shaped inputs (tools/goldens.mjs) --------------------------------------------

const MIN = 60000, DAY = 24 * 60 * MIN;
const STEPS = [0, 1000, MIN, 7 * MIN, 50 * MIN, 3 * 3600000, 20 * 3600000, DAY, 3 * DAY];

/**
 * One random stack-shaped input (§2 with facts) from the generator `r` (tools/fuzz.mjs's rng):
 * mostly chains, broken by bookmarks / tags, working copies, the immutable boundary, merges,
 * forks and Indirect child edges, with Indirect, multi-Indirect and Missing parent gaps, and now
 * and then the split-run shape of §4.8 step 4 (m_1 continues its parent beside the parent's merge
 * reservation).
 */
export function genStackInput(r) {
  const n = r.chance(0.05) ? r.int(0, 3) : r.int(4, 40);
  const pFork = r.pick([0, 0.08, 0.2]);
  const pMerge = r.pick([0, 0.06, 0.15]);
  const pGap = r.pick([0, 0.08, 0.2]);
  const pRef = r.pick([0, 0.06, 0.15]);
  const pOther = r.pick([0, 0.03]);
  const cut = r.int(Math.floor(n / 3), n); // nodes at or above this index are immutable
  const nodes = new Array(n);
  const base = 1_790_000_000_000;
  for (let i = n - 1; i >= 0; i--) {
    const parents = [];
    let parentCount = 0;
    if (i < n - 1) {
      const fp = r.chance(pFork) ? r.int(i + 1, Math.min(n - 1, i + 6)) : i + 1;
      const gap = r.chance(pGap) ? r.pick(["indirect", "multi", "missing"]) : null;
      if (gap === "missing") parents.push({ idx: null, kind: "missing" });
      else if (gap === "multi" && fp + 1 < n) {
        // One hidden merge parent: two Indirect edges.
        parents.push({ idx: fp, kind: "indirect" }, { idx: r.int(fp + 1, n - 1), kind: "indirect" });
      } else parents.push({ idx: fp, kind: gap === "indirect" ? "indirect" : "direct" });
      parentCount = 1;
      if (r.chance(pMerge)) {
        const q = r.int(i + 1, n - 1);
        if (!parents.some((p) => p.idx === q)) {
          parents.push(r.chance(0.2) ? { idx: null, kind: "missing" } : { idx: q, kind: r.chance(0.2) ? "indirect" : "direct" });
          parentCount = 2;
        }
      }
    }
    const pts = parents.filter((p) => p.idx !== null && nodes[p.idx].ts_ms !== null).map((p) => nodes[p.idx].ts_ms);
    const from = pts.length ? Math.max(...pts) : base - r.int(0, 30) * DAY;
    const root = i === n - 1;
    nodes[i] = {
      id: i.toString(16).padStart(8, "0"),
      ts_ms: root ? null : from + r.pick(STEPS) + r.int(0, 999),
      is_root: root,
      priority: r.int(0, 2),
      parents,
      key: `k${i}`,
      immutable: root || i >= cut,
      parent_count: parentCount,
      has_ref: !root && r.chance(pRef),
      working_copy: !root && r.chance(pOther) ? "other" : null,
    };
  }
  const members = n >= 6 && r.chance(0.3) ? splitShape(r, nodes) : [];
  if (n > 1 && r.chance(0.6)) {
    // Never on the split shape's m_1 / m_2: their facts stay plain, as in the Dart generator.
    const at = r.int(0, Math.min(n - 2, 5));
    if (!members.includes(at)) nodes[at].working_copy = "this";
  }
  return { now_ms: base, utc_offset_min: r.pick([0, 120, -300, 330]), nodes };
}

/**
 * Rewires six consecutive nodes into §4.8 step 4's split shape: p = node j + 5; its children m_1 =
 * j + 4 (the continuation: priority 0) and x = j + 2 (priority 2); the run m_1 ← m_2 = j + 3 with
 * m_2's one child c0 = j; and a merge c = j + 1 of x and p, which keeps p's reservation open above
 * m_1, so that m_2 cannot continue m_1's lane. Returns [m_1, m_2].
 */
function splitShape(r, nodes) {
  const n = nodes.length;
  const j = r.int(0, n - 6);
  const c0 = j, c = j + 1, x = j + 2, m2 = j + 3, m1 = j + 4, p = j + 5;
  const plain = (idx) => ({ idx, kind: "direct" });
  const member = { parent_count: 1, has_ref: false, working_copy: null, immutable: nodes[p].immutable };
  Object.assign(nodes[m1], member, { parents: [plain(p)], priority: 0 });
  Object.assign(nodes[m2], member, { parents: [plain(m1)] });
  Object.assign(nodes[x], { parents: [plain(p)], parent_count: 1, priority: 2 });
  Object.assign(nodes[c], { parents: [plain(x), plain(p)], parent_count: 2 });
  Object.assign(nodes[c0], { parents: [plain(m2)], parent_count: 1 });
  for (const k of [m1, x, m2, c, c0]) {
    nodes[k].ts_ms = Math.max(...nodes[k].parents.map((q) => nodes[q.idx].ts_ms ?? 0)) + 7 * MIN;
  }
  // Nothing else may hang off m_1 or m_2: each keeps its one child.
  for (let i = 0; i < j; i++) {
    const seen = new Set();
    nodes[i].parents = nodes[i].parents
      .map((q) => (q.idx === m1 || q.idx === m2 ? { idx: c0, kind: q.kind } : q))
      .filter((q) => q.idx === null || (!seen.has(q.idx) && seen.add(q.idx)));
  }
  return [m1, m2];
}

/** A random stack request for `input` from `r`: a few node keys per list, now and then an unknown one. */
export function stackRequest(r, input) {
  const keys = input.nodes.map((x) => x.key);
  const some = (p) => keys.filter(() => r.chance(p));
  return {
    expanded: [...some(r.pick([0, 0.1, 0.3])), ...(r.chance(0.2) ? ["no-such-key"] : [])],
    collapsed: some(r.pick([0, 0.1, 0.3])),
    keep_open: some(r.pick([0, 0.03, 0.1])),
  };
}

// ---- facts for benchmark inputs ----------------------------------------------------------------

/**
 * Deterministic synthetic stack facts for any §2 input: key `k<i>`, immutable for the older half
 * (index ≥ n / 2, closed under parents), parent_count = the parent entries, has_ref for one node
 * in 17 (by a hash of i), node 0 is "this" working copy, one other in 211 is "other".
 */
export function addFacts(input) {
  const n = input.nodes.length;
  const hash = (i) => Math.imul(i + 1, 2654435761) >>> 0;
  input.nodes = input.nodes.map((x, i) => ({
    ...x,
    key: `k${i}`,
    immutable: i >= Math.floor(n / 2),
    parent_count: x.parents.length,
    has_ref: !x.is_root && hash(i) % 17 === 0,
    working_copy: x.is_root ? null : i === 0 ? "this" : hash(i) % 211 === 0 ? "other" : null,
  }));
  return input;
}

function main() {
  const args = process.argv.slice(2);
  if (args[0] === "facts") {
    if (args.length !== 3) throw new Error("usage: node tools/stacks.mjs facts <in> <out>");
    fs.writeFileSync(args[2], JSON.stringify(addFacts(JSON.parse(fs.readFileSync(args[1], "utf8")))) + "\n");
    return;
  }
  if (args.length) throw new Error("usage: node tools/stacks.mjs [facts <in> <out>]");
  if (!fs.existsSync(DART)) throw new Error(`missing ${DART}: dart compile exe dart/bin/graph_layout.dart -o dart/build/graph_layout`);

  const d = loadDesign(ORACLE_REV);
  oracleCheck(d);

  const request = path.join(spike, "outputs/stacks/request-default.json");
  fs.mkdirSync(path.dirname(request), { recursive: true });
  fs.writeFileSync(request, JSON.stringify({ expanded: [], collapsed: [], keep_open: [] }) + "\n");
  fs.mkdirSync(path.join(spike, "outputs/oracle"), { recursive: true });
  fs.mkdirSync(path.join(spike, "inputs"), { recursive: true });
  for (const rev of REVS) {
    const input = stackDesignInput(d, rev);
    validate(input);
    const inFile = path.join(spike, "inputs", `stacks-design-${rev}.json`);
    fs.writeFileSync(inFile, JSON.stringify(input) + "\n");

    const runs = designRuns(d, rev, input);
    const got = runs.map((x) => `${x.key} ${x.members.length}`).sort();
    const want = EXPECTED[rev].map(([key, k]) => `${key} ${k}`).sort();
    if (JSON.stringify(got) !== JSON.stringify(want)) {
      throw new Error(`the design's groupStacks (${rev}) found ${JSON.stringify(got)}, expected ${JSON.stringify(EXPECTED[rev])}`);
    }
    fs.writeFileSync(path.join(spike, "outputs/oracle", `stacks-design-${rev}.runs.json`), JSON.stringify({ rev, runs }) + "\n");

    const dart = dartRuns(inFile, request).map((x) => ({ key: input.nodes[x.members[0]].key, members: x.members }));
    if (JSON.stringify(dart) !== JSON.stringify(runs)) {
      console.error(`stacks: ${rev}: dart ${JSON.stringify(dart)}\n  design ${JSON.stringify(runs)}`);
      process.exit(1);
    }
    console.error(`stacks: ${rev}: ${runs.length} runs == the design's groupStacks; wrote ${path.relative(spike, inFile)}`);
  }
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) main();
