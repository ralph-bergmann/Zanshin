// SPDX-License-Identifier: MIT
//
// Story 4.11 — the product engine's goldens (docs/graph-layout.md §13), written into
// packages/zanshin_core/test/graph_layout/goldens/. Amended 2026-10-27 (Story 4.14): the product
// always lays out joint columns (§4.3 / §4.7), so every output comes from the spike's Dart binary
// with `--columns joint`, both orders (the Rust reference stays per-mode history). The design
// oracle files come from outputs/oracle/ (run js_oracle.mjs and design-layout.mjs first), the
// fuzz cases from tools/fuzz.mjs's generator under fixed seeds. Shipped scope only: modes
// compact | free × orders greedy | compact.
//
//   node tools/goldens.mjs        (from the spike root)
//
// Needs: the Dart binary built, inputs/ regenerated (fixture-tiny-all included), outputs/oracle/
// (js_oracle.mjs, design-layout.mjs), and (Story 4.13) tools/stacks.mjs run, which writes
// inputs/stacks-design-*.json and the outputs/oracle/stacks-design-*.runs.json the `stacks/`
// section copies.
// Deterministic: a second run leaves `git status` clean. Exit code 1 on any failure.

import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { genInput, rng } from "./fuzz.mjs";
import { genStackInput, stackRequest } from "./stacks.mjs";

const spike = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const repo = path.resolve(spike, "../..");
const out = path.join(repo, "packages/zanshin_core/test/graph_layout/goldens");
const work = path.join(spike, "outputs/goldens");
const BIN = path.join(spike, "dart/build/graph_layout");
const MODES = ["compact", "free"];
const ORDERS = ["greedy", "compact"];
/** Fuzz cases: tools/fuzz.mjs genInput(rng(SEED * 1_000_003 + case)), case = 0 … CASES − 1. */
const SEED = 411;
const CASES = 100;
/**
 * `compact`-order outputs at a small budget that stops the search mid-way: each must differ from
 * both the default budget's output and greedy's (checked below). The committed fixtures cannot
 * serve: their `compact` order equals greedy's (tiny, medium NARROW) or is final after the first
 * window, which even budget 0 evaluates (medium and large `all()`). With joint columns (Story 4.14)
 * `design-all`'s search is final after its first window too, and the cut is the same in both modes
 * (the search does not depend on the mode); two budgets cut `design-default`.
 */
const CUT = [
  ["design-default", "compact", 20],
  ["design-default", "free", 10],
];
/** Stack fuzz cases (Story 4.13): tools/stacks.mjs genStackInput + stackRequest of rng(STACK_SEED * 1_000_003 + case). */
const STACK_SEED = 413;
const STACK_CASES = 60;
/**
 * The design stack inputs' request files (Story 4.13, docs/graph-layout.md §4.8): `default` names
 * nothing (every run collapses: none lies under @); `expanded` names every run's key of both
 * revsets (a key the revset lacks is dropped); `mixed` — qmsvtlkr in both lists (EX wins),
 * tzkvmrls (a non-oldest member) and the root's key (no run) changing nothing, nqxwrptl collapsed,
 * and hvsmqplk (a middle member of the mwoqxlpn run) kept open.
 */
const MIXED = { expanded: ["qmsvtlkr", "tzkvmrls"], collapsed: ["qmsvtlkr", "nqxwrptl", "zzzzzzzz"], keep_open: ["hvsmqplk"] };

/** FNV-1a 64 over the bytes: offset basis 0xcbf29ce484222325, prime 0x100000001b3, 16 hex digits. */
function fnv1a64(bytes) {
  let h = 0xcbf29ce484222325n;
  for (const b of bytes) {
    h ^= BigInt(b);
    h = (h * 0x100000001b3n) & 0xffffffffffffffffn;
  }
  return h.toString(16).padStart(16, "0");
}

const digest = (bytes) => ({ fnv1a64: fnv1a64(bytes), bytes: bytes.length });

/**
 * Runs the spike's Dart binary with `--columns joint` on `inFile` (with `budget` and a stack
 * request file `stacks`, when given) and returns the output bytes.
 */
function layout(inFile, mode, order, budget = null, stacks = null) {
  const outFile = path.join(work, "out.json");
  fs.rmSync(outFile, { force: true });
  const args = [
    "layout", "--mode", mode, "--order", order, "--columns", "joint",
    ...(budget === null ? [] : ["--budget", String(budget)]),
    ...(stacks === null ? [] : ["--stacks", stacks]),
    inFile, outFile,
  ];
  const r = spawnSync(BIN, args, { encoding: "utf8" });
  if (r.status !== 0) throw new Error(`${order} reference, ${path.basename(inFile)} ${mode}: exit ${r.status} ${r.stderr}`);
  return fs.readFileSync(outFile);
}

const write = (rel, data) => {
  const file = path.join(out, rel);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, data);
};
const json = (v) => JSON.stringify(v, null, 2) + "\n";

function main() {
  if (!fs.existsSync(BIN)) throw new Error(`missing ${BIN}: build the Dart reference first`);
  fs.mkdirSync(work, { recursive: true });
  fs.rmSync(out, { recursive: true, force: true });

  // Design sample: inputs, the 8 outputs, the oracle (the design's own computeLayout, compact).
  for (const rev of ["default", "all"]) {
    const inFile = path.join(spike, "inputs", `design-${rev}.json`);
    write(`design/design-${rev}.json`, fs.readFileSync(inFile));
    for (const mode of MODES) for (const order of ORDERS) write(`design/design-${rev}.${mode}.${order}.json`, layout(inFile, mode, order));
    const oracle = path.join(spike, "outputs/oracle", `design-${rev}.compact.greedy.json`);
    if (!fs.existsSync(oracle)) throw new Error(`missing ${oracle}: run node tools/js_oracle.mjs first`);
    write(`design/oracle/design-${rev}.compact.greedy.json`, fs.readFileSync(oracle));
    // Story 4.14: GL's (e74ced3) lane counts on the e243dd2 sample (tools/design-layout.mjs).
    const lanes = path.join(spike, "outputs/oracle", `joint-design-${rev}.lanes.json`);
    if (!fs.existsSync(lanes)) throw new Error(`missing ${lanes}: run node tools/design-layout.mjs first`);
    write(`design/oracle/joint-design-${rev}.lanes.json`, fs.readFileSync(lanes));
  }
  for (const [name, mode, budget] of CUT) {
    const inFile = path.join(spike, "inputs", `${name}.json`);
    const cut = layout(inFile, mode, "compact", budget);
    const lanes = (bytes) => JSON.stringify(JSON.parse(bytes).nodes.map((x) => x.lane));
    if (cut.equals(layout(inFile, mode, "compact")) || lanes(cut) === lanes(layout(inFile, mode, "greedy"))) {
      throw new Error(`${name} ${mode} at budget ${budget} does not stop the compact search mid-way: pick another budget`);
    }
    write(`design/${name}.${mode}.compact.budget-${budget}.json`, cut);
  }

  // Fixture dumps: tiny and medium NARROW in full, medium and large all() as hashes.
  const manifest = JSON.parse(fs.readFileSync(path.join(spike, "inputs/manifest.json"), "utf8"));
  const fixtures = {};
  for (const [name, file, full] of [
    ["tiny-all", "fixture-tiny-all.json", true],
    ["medium-narrow", "fixture-medium-narrow.json", true],
    ["medium-all", "fixture-medium-all.json", false],
    ["large-all", "fixture-large-all.json", false],
  ]) {
    const inFile = path.join(spike, "inputs", file);
    const bytes = fs.readFileSync(inFile);
    const input = JSON.parse(bytes);
    const entry = manifest.files.find((f) => f.file === file);
    if (!entry) throw new Error(`${file} is not in inputs/manifest.json: regenerate the inputs`);
    const record = { fixture: entry.source.replace(/^test-fixtures\/repos\/|\.tar\.zst$/g, ""), revset: entry.revset, now_ms: input.now_ms, utc_offset_min: input.utc_offset_min };
    if (full) write(`fixtures/${name}.input.json`, bytes);
    else record.input = digest(bytes);
    for (const mode of MODES) for (const order of ORDERS) {
      const o = layout(inFile, mode, order);
      if (full) write(`fixtures/${name}.${mode}.${order}.json`, o);
      else record[`${mode}.${order}`] = digest(o);
    }
    fixtures[name] = record;
  }
  write("fixtures/hashes.json", json(fixtures));

  // Seeded fuzz cases: one canonical input per line, and per case × mode × order its output's hash.
  const lines = [], expected = [];
  const caseFile = path.join(work, "case.json");
  for (let c = 0; c < CASES; c++) {
    const text = JSON.stringify(genInput(rng(SEED * 1_000_003 + c)));
    lines.push(text);
    fs.writeFileSync(caseFile, text + "\n");
    const row = {};
    for (const mode of MODES) for (const order of ORDERS) row[`${mode}.${order}`] = digest(layout(caseFile, mode, order));
    expected.push(row);
  }
  write("fuzz/cases.jsonl", lines.join("\n") + "\n");
  write("fuzz/expected.json", json({ seed: SEED, cases: expected }));

  // Stacks (Story 4.13, docs/graph-layout.md §4.8), all from the spike's Dart binary: the design
  // sample at e243dd2 with stack facts (tools/stacks.mjs) × three requests × modes × orders, the
  // design's own groupStacks runs, and seeded stack fuzz cases.
  const oracleRuns = {};
  for (const rev of ["default", "all"]) {
    const file = path.join(spike, "outputs/oracle", `stacks-design-${rev}.runs.json`);
    if (!fs.existsSync(file)) throw new Error(`missing ${file}: run node tools/stacks.mjs first`);
    oracleRuns[rev] = JSON.parse(fs.readFileSync(file, "utf8"));
    write(`stacks/oracle/design-${rev}.runs.json`, fs.readFileSync(file));
  }
  const requests = {
    default: { expanded: [], collapsed: [], keep_open: [] },
    expanded: { expanded: [...new Set(Object.values(oracleRuns).flatMap((o) => o.runs.map((x) => x.key)))].sort(), collapsed: [], keep_open: [] },
    mixed: MIXED,
  };
  for (const [state, request] of Object.entries(requests)) write(`stacks/request-${state}.json`, JSON.stringify(request) + "\n");
  for (const rev of ["default", "all"]) {
    const inFile = path.join(spike, "inputs", `stacks-design-${rev}.json`);
    if (!fs.existsSync(inFile)) throw new Error(`missing ${inFile}: run node tools/stacks.mjs first`);
    write(`stacks/design-${rev}.json`, fs.readFileSync(inFile));
    for (const state of Object.keys(requests)) {
      for (const mode of MODES) for (const order of ORDERS) {
        write(`stacks/design-${rev}.${state}.${mode}.${order}.json`, layout(inFile, mode, order, null, path.join(out, `stacks/request-${state}.json`)));
      }
    }
  }
  const stackLines = [], stackExpected = [];
  const requestFile = path.join(work, "request.json");
  let splitRuns = 0; // runs whose oldest and newest members sit in different columns (§4.8 step 4)
  for (let c = 0; c < STACK_CASES; c++) {
    const r = rng(STACK_SEED * 1_000_003 + c);
    const input = genStackInput(r);
    const request = stackRequest(r, input);
    stackLines.push(JSON.stringify({ input, request }));
    fs.writeFileSync(caseFile, JSON.stringify(input) + "\n");
    fs.writeFileSync(requestFile, JSON.stringify(request) + "\n");
    const row = {};
    for (const mode of MODES) for (const order of ORDERS) {
      const bytes = layout(caseFile, mode, order, null, requestFile);
      row[`${mode}.${order}`] = digest(bytes);
      if (mode === "compact" && order === "greedy") {
        const cols = JSON.parse(layout(caseFile, mode, order)).nodes.map((x) => x.col);
        for (const run of JSON.parse(bytes).runs) if (cols[run.members[0]] !== cols[run.members[run.members.length - 1]]) splitRuns++;
      }
    }
    stackExpected.push(row);
  }
  if (splitRuns === 0) throw new Error("no stack fuzz case has a split run (compact, greedy): raise the split shape's chance in tools/stacks.mjs");
  console.log(`stack fuzz cases: ${splitRuns} split runs (compact, greedy)`);
  write("stacks/fuzz/cases.jsonl", stackLines.join("\n") + "\n");
  write("stacks/fuzz/expected.json", json({ seed: STACK_SEED, cases: stackExpected }));

  write("README.md", readme());
  let total = 0;
  const walk = (dir) => fs.readdirSync(dir, { withFileTypes: true }).forEach((e) => (e.isDirectory() ? walk(path.join(dir, e.name)) : (total += fs.statSync(path.join(dir, e.name)).size)));
  walk(out);
  console.log(`wrote ${path.relative(repo, out)}: ${total} bytes`);
}

function readme() {
  return `# Layout goldens (Story 4.11, stacks Story 4.13, joint columns Story 4.14)

Generated — do not edit by hand. Regenerate from \`spikes/graph-layout-ab/\` after building the
Dart reference (\`dart compile exe dart/bin/graph_layout.dart -o dart/build/graph_layout\`),
regenerating the inputs and running \`node tools/js_oracle.mjs\`, \`node tools/design-layout.mjs\`
and \`node tools/stacks.mjs\` (README \`## Run\`):

\`\`\`sh
node tools/goldens.mjs
\`\`\`

Every output is \`docs/graph-layout.md\` §3's canonical form, for the shipped scope: modes
\`compact\` | \`free\` × lane orders \`greedy\` | \`compact\`, named \`<input>.<mode>.<order>.json\`.
The product always lays out joint columns (§4.3 / §4.7, amended 2026-10-27): one lane packing and
one column order for both modes, so \`lane\`, \`col\` and \`lanes\` are the same in a compact and a free
output (I8). Every output therefore comes from the spike's Dart reference (\`dart/\`) with
\`--columns joint\`, both orders; the Rust reference (\`rust/\`) keeps the per-mode packing.

- \`design/\`: the design sample's inputs (\`tools/design-input.mjs\`, export pinned at \`57f259c\`),
  their 8 outputs, and \`oracle/\`: the design's own \`computeLayout\` (\`tools/js_oracle.mjs\`) in
  \`compact\` mode, greedy, with the per-mode lanes of that export (the product test compares rows
  and edges only); and \`joint-design-<rev>.lanes.json\`: the lane counts of the export \`e74ced3\`'s
  \`graph-layout.jsx\` (\`tools/design-layout.mjs\`) on the \`e243dd2\` sample (\`stacks/design-<rev>.json\`
  without its stack facts) — \`gl_greedy_lanes\` (exact colouring off: the fewer of its two greedy
  packings), \`gl_exact_lanes\` and the Dart reference's \`joint_greedy_lanes\`.
- \`design/<input>.<mode>.compact.budget-<N>.json\`: the \`compact\` order at a budget N that stops its
  search mid-way (the output differs from the default budget's and from greedy's) — ${CUT.map(([name, mode, n]) => "`" + name + "` " + mode + " N = " + n).join(", ")}. The
  committed fixtures cannot show a cut: their \`compact\` order equals greedy's or is final after the
  first window, which even budget 0 evaluates.
- \`fixtures/\`: the dumper's inputs (\`rust-inputs/\`, \`Repo::graph_topology\`; prioritize
  \`present(@)\`, short prefixes \`''\`, anchors \`[trunk(), present(@)]\`, \`utc_offset_min\` 120,
  \`now_ms\` = newest ts + 60 s) — \`tiny-all\` (tiny-3-commits \`all()\`) and \`medium-narrow\`
  (medium-1k-commits, the NARROW revset) in full; \`hashes.json\` holds every fixture case's revset,
  \`now_ms\` and \`utc_offset_min\`, and for \`medium-all\` and \`large-all\` (medium-1k-commits and
  large-10k-commits \`all()\`) the input's and each output's hash and byte length.
- \`fuzz/\`: \`cases.jsonl\` holds ${CASES} canonical inputs, one per line, case k =
  \`genInput(rng(${SEED} * 1_000_003 + k))\` of \`tools/fuzz.mjs\`; \`expected.json\` per case and
  \`<mode>.<order>\` the output's hash and byte length.
- \`stacks/\` (Story 4.13, \`docs/graph-layout.md\` §4.8; every output from the spike's Dart binary
  with \`--stacks\`, for both orders — stacks are Dart-only; run \`node tools/stacks.mjs\` first):
  - \`design-<rev>.json\`: the design sample at \`e243dd2\` (52 commits) with stack facts;
  - \`request-{default,expanded,mixed}.json\`: the stack requests — \`default\` names nothing
    (every run collapses), \`expanded\` names every run's key of both revsets, \`mixed\` has a key in
    both lists, a kept-open middle member and keys that change nothing;
  - \`design-<rev>.<request>.<mode>.<order>.json\`: the outputs;
  - \`oracle/design-<rev>.runs.json\`: the design's own \`groupStacks(all, rev, [])\` as runs of
    input node indices (oldest first, ordered by newest member), after \`tools/stacks.mjs\` checked
    that the design's gap walk yields jj-lib 0.44's edges on this sample;
  - \`fuzz/\`: \`cases.jsonl\` holds ${STACK_CASES} cases, one \`{"input":…,"request":…}\` per line, case k
    = \`genStackInput(r)\` then \`stackRequest(r, input)\` of \`tools/stacks.mjs\` with
    \`r = rng(${STACK_SEED} * 1_000_003 + k)\`; \`expected.json\` per case and \`<mode>.<order>\` the output's
    hash and byte length.

Hashes are FNV-1a 64 (offset basis \`0xcbf29ce484222325\`, prime \`0x100000001b3\`) over the
canonical UTF-8 bytes including the trailing \`\\n\`, as 16 lowercase hex digits.
`;
}

main();
