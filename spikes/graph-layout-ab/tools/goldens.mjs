// SPDX-License-Identifier: MIT
//
// The product engine's goldens (docs/graph-layout.md §13, amended 2026-11-10), written into
// packages/zanshin_core/test/graph_layout/goldens/. Every output comes from the product CLI
// (packages/zanshin_core/benchmark/graph_layout_cli.dart) over the COMMITTED inputs, one file per
// mode, named <input>.<mode>.json. The inputs and the oracles are never touched here: they stay as
// tools/design-input.mjs, fuzz.mjs, stacks.mjs, js_oracle.mjs and the dumper wrote them.
//
//   node spikes/graph-layout-ab/tools/goldens.mjs
//
// Needs: dart on PATH and the spike's inputs/fixture-medium-all.json and fixture-large-all.json.
// Deterministic: a second run leaves `git status` clean. Exit code 1 on any failure.

import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const spike = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const repo = path.resolve(spike, "../..");
const core = path.join(repo, "packages/zanshin_core");
const out = path.join(core, "test/graph_layout/goldens");
const work = path.join(spike, "outputs/goldens");
const BIN = path.join(spike, "outputs/bin/graph_layout_core");
const MODES = ["compact", "free"];
const REVS = ["default", "all"];
const STATES = ["default", "expanded", "mixed"];
/** The seeds the committed cases were generated with (tools/fuzz.mjs, tools/stacks.mjs). */
const SEED = 411;
const STACK_SEED = 413;

function fail(message) {
  throw new Error(message);
}

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
const json = (v) => JSON.stringify(v, null, 2) + "\n";
const write = (rel, data) => fs.writeFileSync(path.join(out, rel), data);
const committed = (rel) => path.join(out, rel);

/** Runs the product CLI on `inFile` (with the stack request `stacks`, when given) and returns the output bytes. */
function layout(inFile, mode, stacks = null) {
  const outFile = path.join(work, "out.json");
  fs.rmSync(outFile, { force: true });
  const args = ["layout", "--mode", mode, ...(stacks === null ? [] : ["--stacks", stacks]), inFile, outFile];
  const r = spawnSync(BIN, args, { encoding: "utf8" });
  if (r.status !== 0) fail(`${path.basename(inFile)} ${mode}: exit ${r.status} ${r.stderr}`);
  return fs.readFileSync(outFile);
}

function compileCli() {
  fs.mkdirSync(path.dirname(BIN), { recursive: true });
  const r = spawnSync("dart", ["compile", "exe", "benchmark/graph_layout_cli.dart", "-o", BIN], { cwd: core, encoding: "utf8" });
  if (r.status !== 0) fail(`dart compile: exit ${r.status}\n${r.stdout}\n${r.stderr}`);
}

function main() {
  compileCli();
  fs.mkdirSync(work, { recursive: true });

  // The design sample and the fixture dumps in full.
  for (const rev of REVS) {
    for (const mode of MODES) write(`design/design-${rev}.${mode}.json`, layout(committed(`design/design-${rev}.json`), mode));
  }
  for (const name of ["tiny-all", "medium-narrow"]) {
    for (const mode of MODES) write(`fixtures/${name}.${mode}.json`, layout(committed(`fixtures/${name}.input.json`), mode));
  }

  // The large fixture dumps as hashes: their inputs are the spike's, too big to commit.
  const hashes = JSON.parse(fs.readFileSync(committed("fixtures/hashes.json"), "utf8"));
  for (const name of Object.keys(hashes)) {
    if (name === "tiny-all" || name === "medium-narrow") continue;
    const record = hashes[name];
    const inFile = path.join(spike, "inputs", `fixture-${name}.json`);
    if (!fs.existsSync(inFile)) fail(`missing ${inFile}: regenerate the spike's fixture inputs (README \`## Run\`)`);
    const bytes = fs.readFileSync(inFile);
    if (fnv1a64(bytes) !== record.input.fnv1a64) fail(`${inFile} is not the input hashes.json records for ${name}`);
    hashes[name] = { fixture: record.fixture, revset: record.revset, now_ms: record.now_ms, utc_offset_min: record.utc_offset_min, input: record.input };
    for (const mode of MODES) hashes[name][mode] = digest(layout(inFile, mode));
  }
  write("fixtures/hashes.json", json(hashes));

  // Seeded fuzz cases: per case and mode the output's hash.
  const caseFile = path.join(work, "case.json");
  const requestFile = path.join(work, "request.json");
  const cases = fs.readFileSync(committed("fuzz/cases.jsonl"), "utf8").trimEnd().split("\n");
  const expected = cases.map((line) => {
    fs.writeFileSync(caseFile, line + "\n");
    return Object.fromEntries(MODES.map((mode) => [mode, digest(layout(caseFile, mode))]));
  });
  write("fuzz/expected.json", json({ seed: SEED, cases: expected }));

  // Stacks: the design sample × the requests × modes, and the seeded stack fuzz cases.
  for (const rev of REVS) {
    for (const state of STATES) {
      for (const mode of MODES) {
        write(`stacks/design-${rev}.${state}.${mode}.json`, layout(committed(`stacks/design-${rev}.json`), mode, committed(`stacks/request-${state}.json`)));
      }
    }
  }
  const stackCases = fs.readFileSync(committed("stacks/fuzz/cases.jsonl"), "utf8").trimEnd().split("\n");
  const stackExpected = stackCases.map((line) => {
    const { input, request } = JSON.parse(line);
    fs.writeFileSync(caseFile, JSON.stringify(input) + "\n");
    fs.writeFileSync(requestFile, JSON.stringify(request) + "\n");
    return Object.fromEntries(MODES.map((mode) => [mode, digest(layout(caseFile, mode, requestFile))]));
  });
  write("stacks/fuzz/expected.json", json({ seed: STACK_SEED, cases: stackExpected }));

  write("README.md", readme(cases.length, stackCases.length));
  console.log(`wrote ${path.relative(repo, out)}: ${cases.length} fuzz cases, ${stackCases.length} stack fuzz cases`);
}

function readme(caseCount, stackCaseCount) {
  return `# Layout goldens (Story 4.11, stacks Story 4.13, branch columns Story 4.17)

Generated — do not edit by hand. Regenerate from the repository root (\`dart\` on PATH):

\`\`\`sh
node spikes/graph-layout-ab/tools/goldens.mjs
\`\`\`

Every output is \`docs/graph-layout.md\` §3's canonical form from the product CLI
(\`packages/zanshin_core/benchmark/graph_layout_cli.dart\`, §13, amended 2026-11-10), for the modes
\`compact\` | \`free\`, named \`<input>.<mode>.json\`. The columns are §4.3's branch columns, chosen per
mode. The tool never touches the inputs or the oracles below.

- \`design/\`: the design sample's inputs, their outputs, and \`oracle/\`: the design's own
  \`computeLayout\` at export \`57f259c\` in \`compact\` mode (its rows, edge endpoints and edge kinds are
  what the product test compares; its lane packing is not the product's).
- \`fixtures/\`: the dumper's inputs (\`rust-inputs/\`, \`Repo::graph_topology\`; prioritize
  \`present(@)\`, short prefixes \`''\`, anchors \`[trunk(), present(@)]\`, \`utc_offset_min\` 120,
  \`now_ms\` = newest ts + 60 s) — \`tiny-all\` (tiny-3-commits \`all()\`) and \`medium-narrow\`
  (medium-1k-commits, the NARROW revset) in full; \`hashes.json\` holds every fixture case's revset,
  \`now_ms\` and \`utc_offset_min\`, and for \`medium-all\` and \`large-all\` (medium-1k-commits and
  large-10k-commits \`all()\`, whose inputs are \`spikes/graph-layout-ab/inputs/fixture-*.json\`) the
  input's and each mode's output's hash and byte length.
- \`fuzz/\`: \`cases.jsonl\` holds ${caseCount} canonical inputs, one per line (case k =
  \`genInput(rng(${SEED} * 1_000_003 + k))\` of \`tools/fuzz.mjs\`, generated once); \`expected.json\` per
  case and \`<mode>\` the output's hash and byte length.
- \`stacks/\` (Story 4.13, \`docs/graph-layout.md\` §4.8):
  - \`design-<rev>.json\`: the design sample at \`e243dd2\` (52 commits) with stack facts;
  - \`request-{default,expanded,mixed}.json\`: the stack requests — \`default\` names nothing
    (every run collapses), \`expanded\` names every run's key of both revsets, \`mixed\` has a key in
    both lists, a kept-open middle member and keys that change nothing;
  - \`design-<rev>.<request>.<mode>.json\`: the outputs;
  - \`oracle/design-<rev>.runs.json\`: the design's own \`groupStacks(all, rev, [])\` as runs of input
    node indices (oldest first, ordered by newest member);
  - \`fuzz/\`: \`cases.jsonl\` holds ${stackCaseCount} cases, one \`{"input":…,"request":…}\` per line, case k =
    \`genStackInput(r)\` then \`stackRequest(r, input)\` of \`tools/stacks.mjs\` with
    \`r = rng(${STACK_SEED} * 1_000_003 + k)\` (generated once); \`expected.json\` per case and \`<mode>\` the
    output's hash and byte length.

Hashes are FNV-1a 64 (offset basis \`0xcbf29ce484222325\`, prime \`0x100000001b3\`) over the
canonical UTF-8 bytes including the trailing \`\\n\`, as 16 lowercase hex digits.
`;
}

try {
  main();
} catch (e) {
  console.error(`goldens: ${e.message}`);
  process.exit(1);
}
