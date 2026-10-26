// SPDX-License-Identifier: MIT
//
// Story 10.1 item 13 — the graph view's recorded layouts. Runs the product engine CLI
// (packages/zanshin_core/benchmark/graph_layout_cli.dart, docs/graph-layout.md §6) on repo-tracked
// inputs only and writes app/widgetbook/graph/graph_recordings.g.dart: one const raw string per
// input and per output, a map from each recording's name to its (input, output) pair, and the
// names in order. The view joins each pair with RecordedGraphLayout.fromSpec.
//
//   node spikes/graph-layout-ab/tools/record-graph.mjs        (from the repository root, or anywhere)
//
// Recordings:
//   - the design sample at e243dd2 (packages/zanshin_core/test/graph_layout/goldens/stacks/
//     design-{default,all}.json, which carry the view facts; laid out without --stacks) in
//     {free, compact} × {compact, greedy};
//   - design-cli-default: the CLI-faithful variant of the older design sample (epics.md Story 10.1
//     item 13(a), prototype defect 15), derived here from goldens/design/design-default.json —
//     `wqnwkozp` dropped, `vruxwmqv`'s parent Missing, the other parent indices re-indexed — in
//     {free, compact} × {compact, greedy};
//   - goldens/fixtures/medium-narrow.input.json (the switched dumper's output, with indirect and
//     Missing edges) in {free, compact} × {compact, greedy}.
// Needs: dart on PATH. Deterministic: a second run leaves `git status` clean. Exit code 1 on any
// failure. The large 10k–100k spike outputs are never committed; the catalogue and the tests
// generate scale fixtures with app/widgetbook/graph/synthetic_layout.dart instead.

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const spike = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const repo = path.resolve(spike, "../..");
const core = path.join(repo, "packages/zanshin_core");
const goldens = path.join(core, "test/graph_layout/goldens");
const target = path.join(repo, "app/widgetbook/graph/graph_recordings.g.dart");

const COMBOS = [["free", "compact"], ["free", "greedy"], ["compact", "compact"], ["compact", "greedy"]];

/** The CLI-faithful variant: `wqnwkozp` gone, `vruxwmqv`'s parent Missing, the rest re-indexed. */
function cliFaithful(json) {
  const input = JSON.parse(json);
  const dropped = input.nodes.findIndex((n) => n.id === "wqnwkozp");
  if (dropped < 0 || !input.nodes.some((n) => n.id === "vruxwmqv")) {
    fail("design-default.json lacks wqnwkozp or vruxwmqv");
  }
  const reindex = (idx) => (idx === null ? null : idx > dropped ? idx - 1 : idx);
  input.nodes = input.nodes
    .filter((_, k) => k !== dropped)
    .map((n) => ({
      ...n,
      parents: n.id === "vruxwmqv" ? [{ idx: null, kind: "missing" }] : n.parents.map((p) => ({ ...p, idx: reindex(p.idx) })),
    }));
  return JSON.stringify(input);
}

/** [name, input file, derive (or null), combinations [mode, order]]. */
const SOURCES = [
  ["design-default", "stacks/design-default.json", null, COMBOS],
  ["design-all", "stacks/design-all.json", null, COMBOS],
  ["design-cli-default", "design/design-default.json", cliFaithful, COMBOS],
  ["medium-narrow", "fixtures/medium-narrow.input.json", null, COMBOS],
];

function fail(message) {
  console.error(`record-graph: ${message}`);
  process.exit(1);
}

/** `designDefault`, `designDefaultFreeCompact`, … */
function identifier(...parts) {
  const words = parts.join("-").split("-");
  return words.map((w, k) => (k === 0 ? w : w[0].toUpperCase() + w.slice(1))).join("");
}

/** One JSON document as a Dart raw string; the trailing newline goes (JSON ignores it). */
function rawString(json) {
  const text = json.trimEnd();
  if (text.includes("'''") || text.includes("\n")) {
    fail("a document cannot be embedded as a single-line raw string");
  }
  return `r'''${text}'''`;
}

const work = fs.mkdtempSync(path.join(os.tmpdir(), "record-graph-"));
const inputs = [];
const outputs = [];
const recordings = [];
try {
  for (const [name, file, derive, combos] of SOURCES) {
    let inFile = path.join(goldens, file);
    if (derive !== null) {
      const derived = path.join(work, `${name}.input.json`);
      fs.writeFileSync(derived, derive(fs.readFileSync(inFile, "utf8")));
      inFile = derived;
    }
    const inputId = `_${identifier(name)}`;
    inputs.push(`const ${inputId} = ${rawString(fs.readFileSync(inFile, "utf8"))};`);
    for (const [mode, order] of combos) {
      const outFile = path.join(work, `${name}.${mode}.${order}.json`);
      const run = spawnSync(
        "dart",
        ["run", "benchmark/graph_layout_cli.dart", "layout", "--mode", mode, "--order", order, inFile, outFile],
        { cwd: core, encoding: "utf8" },
      );
      if (run.status !== 0) {
        fail(`${name} ${mode} ${order}: exit ${run.status}\n${run.stderr}`);
      }
      const outputId = `_${identifier(name, mode, order)}`;
      outputs.push(`const ${outputId} = ${rawString(fs.readFileSync(outFile, "utf8"))};`);
      recordings.push([`${name} ${mode} ${order}`, inputId, outputId]);
    }
  }
} finally {
  fs.rmSync(work, { recursive: true, force: true });
}

const dart = `// GENERATED by spikes/graph-layout-ab/tools/record-graph.mjs (Story 10.1 item 13) — do not edit; re-run the tool.
// Inputs: packages/zanshin_core/test/graph_layout/goldens/{stacks/design-default,stacks/design-all,design/design-default (CLI-faithful variant),fixtures/medium-narrow.input}.json;
// outputs: the product engine CLI (packages/zanshin_core/benchmark/graph_layout_cli.dart).

/// The recordings by name (\`<input> <mode> <order>\`): a docs/graph-layout.md §2 input and the engine's §3 output for
/// it, joined by \`RecordedGraphLayout.fromSpec\`.
const graphRecordings = <String, (String, String)>{
${recordings.map(([name, input, output]) => `  '${name}': (${input}, ${output}),`).join("\n")}
};

/// The recording names in order.
const graphRecordingNames = <String>[
${recordings.map(([name]) => `  '${name}',`).join("\n")}
];

${inputs.join("\n\n")}

${outputs.join("\n\n")}
`;

fs.mkdirSync(path.dirname(target), { recursive: true });
fs.writeFileSync(target, dart);
const format = spawnSync("dart", ["format", target], { cwd: path.join(repo, "app"), encoding: "utf8" });
if (format.status !== 0) {
  fail(`dart format: exit ${format.status}\n${format.stderr}`);
}
console.log(`record-graph: ${recordings.length} recordings → ${path.relative(repo, target)}`);
