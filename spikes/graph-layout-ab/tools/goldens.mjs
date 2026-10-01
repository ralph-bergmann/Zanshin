// SPDX-License-Identifier: MIT
//
// Story 4.11 — the product engine's goldens (docs/graph-layout.md §13), generated from the two
// references and written into packages/zanshin_core/test/graph_layout/goldens/. Greedy outputs
// come from the Rust binary, `compact`-order outputs from the spike's Dart binary (the order has
// no Rust reference), the design oracle files from outputs/oracle/ (run js_oracle.mjs first), the
// fuzz cases from tools/fuzz.mjs's generator under fixed seeds. Shipped scope only: modes
// compact | free × orders greedy | compact.
//
//   node tools/goldens.mjs        (from the spike root)
//
// Needs: both binaries built, inputs/ regenerated (fixture-tiny-all included), outputs/oracle/.
// Deterministic: a second run leaves `git status` clean. Exit code 1 on any failure.

import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { genInput, rng } from "./fuzz.mjs";

const spike = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const repo = path.resolve(spike, "../..");
const out = path.join(repo, "packages/zanshin_core/test/graph_layout/goldens");
const work = path.join(spike, "outputs/goldens");
const BIN = {
  greedy: path.join(spike, "rust/target/release/graph-layout"),
  compact: path.join(spike, "dart/build/graph_layout"),
};
const MODES = ["compact", "free"];
const ORDERS = ["greedy", "compact"];
/** Fuzz cases: tools/fuzz.mjs genInput(rng(SEED * 1_000_003 + case)), case = 0 … CASES − 1. */
const SEED = 411;
const CASES = 100;
/**
 * `compact`-order outputs at a small budget that stops the search mid-way: each must differ from
 * both the default budget's output and greedy's (checked below). The committed fixtures cannot
 * serve: their `compact` order equals greedy's (tiny, medium NARROW) or is final after the first
 * window, which even budget 0 evaluates (medium and large `all()`).
 */
const CUT = [
  ["design-all", "compact", 20],
  ["design-all", "free", 90],
  ["design-default", "free", 40],
];

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

/** Runs the reference of `order` on `inFile` (the Dart one with `budget`, when given) and returns the output bytes. */
function layout(inFile, mode, order, budget = null) {
  const outFile = path.join(work, "out.json");
  fs.rmSync(outFile, { force: true });
  const args = ["layout", "--mode", mode, "--order", order, ...(budget === null ? [] : ["--budget", String(budget)]), inFile, outFile];
  const r = spawnSync(BIN[order], args, { encoding: "utf8" });
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
  for (const bin of Object.values(BIN)) if (!fs.existsSync(bin)) throw new Error(`missing ${bin}: build the references first`);
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

  write("README.md", readme());
  let total = 0;
  const walk = (dir) => fs.readdirSync(dir, { withFileTypes: true }).forEach((e) => (e.isDirectory() ? walk(path.join(dir, e.name)) : (total += fs.statSync(path.join(dir, e.name)).size)));
  walk(out);
  console.log(`wrote ${path.relative(repo, out)}: ${total} bytes`);
}

function readme() {
  return `# Layout goldens (Story 4.11)

Generated — do not edit by hand. Regenerate from \`spikes/graph-layout-ab/\` after building both
references (\`cargo build --release --manifest-path rust/Cargo.toml\`,
\`dart compile exe dart/bin/graph_layout.dart -o dart/build/graph_layout\`), regenerating the
inputs and running \`node tools/js_oracle.mjs\` (README \`## Run\`):

\`\`\`sh
node tools/goldens.mjs
\`\`\`

Every output is \`docs/graph-layout.md\` §3's canonical form, for the shipped scope: modes
\`compact\` | \`free\` × lane orders \`greedy\` | \`compact\`, named \`<input>.<mode>.<order>.json\`.
\`greedy\` comes from the Rust reference (\`rust/\`), the \`compact\` order from the spike's Dart
reference (\`dart/\`), which is its only implementation.

- \`design/\`: the design sample's inputs (\`tools/design-input.mjs\`, export pinned at \`57f259c\`),
  their 8 outputs, and \`oracle/\`: the design's own \`computeLayout\` (\`tools/js_oracle.mjs\`) in
  \`compact\` mode, greedy.
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

Hashes are FNV-1a 64 (offset basis \`0xcbf29ce484222325\`, prime \`0x100000001b3\`) over the
canonical UTF-8 bytes including the trailing \`\\n\`, as 16 lowercase hex digits.
`;
}

main();
