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
// Story 10.17 also writes app/widgetbook/graph/graph_stack_recordings.g.dart: the design sample
// (design-default, design-all) laid out with --stacks in {free, compact} × compact, in its default
// stack state, all expanded, and each run flipped alone from the default.
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
const stackTarget = path.join(repo, "app/widgetbook/graph/graph_stack_recordings.g.dart");

/** Story 10.17: the samples and modes recorded with `--stacks` (lane order `compact`). */
const STACK_SAMPLES = ["design-default", "design-all"];
const STACK_MODES = ["free", "compact"];

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

/** Runs the engine CLI on `inFile` (with the stack request `stacksFile`, or without) and returns its output. */
function layoutOf(label, inFile, mode, order, outFile, stacksFile = null) {
  const stacks = stacksFile === null ? [] : ["--stacks", stacksFile];
  const run = spawnSync(
    "dart",
    ["run", "benchmark/graph_layout_cli.dart", "layout", "--mode", mode, "--order", order, ...stacks, inFile, outFile],
    { cwd: core, encoding: "utf8" },
  );
  if (run.status !== 0) {
    fail(`${label}: exit ${run.status}\n${run.stderr}`);
  }
  return fs.readFileSync(outFile, "utf8");
}

const work = fs.mkdtempSync(path.join(os.tmpdir(), "record-graph-"));
const inputs = [];
const outputs = [];
const recordings = [];
// Story 10.17: the stack recordings, their inputs, outputs and requests, and each sample's default state.
const stackInputs = [];
const stackOutputs = [];
const stackRecordings = [];
const stackDefaults = [];
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
      const outputId = `_${identifier(name, mode, order)}`;
      outputs.push(`const ${outputId} = ${rawString(layoutOf(`${name} ${mode} ${order}`, inFile, mode, order, outFile))};`);
      recordings.push([`${name} ${mode} ${order}`, inputId, outputId]);
    }
  }

  // The stack states (docs/graph-layout.md §4.8): the default, all expanded, and each run flipped alone from the
  // default, each run named by its oldest member's key.
  for (const name of STACK_SAMPLES) {
    const file = SOURCES.find(([n]) => n === name)[1];
    const inFile = path.join(goldens, file);
    const input = JSON.parse(fs.readFileSync(inFile, "utf8"));
    const keyOf = (idx) => input.nodes[idx].key ?? input.nodes[idx].id;
    const inputId = `_${identifier(name)}`;
    stackInputs.push(`const ${inputId} = ${rawString(fs.readFileSync(inFile, "utf8"))};`);
    for (const mode of STACK_MODES) {
      const record = (state, request) => {
        const reqFile = path.join(work, `${name}.${mode}.${state}.request.json`);
        const requestJson = JSON.stringify({ expanded: request.expanded ?? [], collapsed: request.collapsed ?? [], keep_open: [] });
        fs.writeFileSync(reqFile, requestJson);
        const label = `${name} ${mode} ${state}`;
        const output = layoutOf(label, inFile, mode, "compact", path.join(work, `${name}.${mode}.${state}.json`), reqFile);
        const id = `_${identifier(name, mode, ...state.split(" "))}`;
        stackOutputs.push(`const ${id} = ${rawString(output)};`);
        stackOutputs.push(`const ${id}Request = ${rawString(requestJson)};`);
        stackRecordings.push([label, inputId, id, `${id}Request`]);
        return JSON.parse(output);
      };
      const defaults = record("default", {});
      stackDefaults.push([`${name} ${mode}`, `${name} ${mode} default`]);
      const runs = defaults.runs.map((run) => ({ key: keyOf(run.members[0]), state: run.state }));
      record("expanded", { expanded: runs.map((run) => run.key) });
      for (const run of runs) {
        record(`flip ${run.key}`, run.state === "collapsed" ? { expanded: [run.key] } : { collapsed: [run.key] });
      }
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

const stackDart = `// GENERATED by spikes/graph-layout-ab/tools/record-graph.mjs (Story 10.17) — do not edit; re-run the tool.
// Inputs: packages/zanshin_core/test/graph_layout/goldens/stacks/{design-default,design-all}.json;
// outputs: the product engine CLI with --stacks (packages/zanshin_core/benchmark/graph_layout_cli.dart), lane order compact.

/// The stack recordings by name (\`<input> <mode> <state>\`, state \`default\`, \`expanded\` or \`flip <oldest key>\`): a
/// docs/graph-layout.md §2 input, the engine's grouped §3 output for it and the §4.8 stack request it was laid out with.
const graphStackRecordings = <String, (String, String, String)>{
${stackRecordings.map(([name, input, output, request]) => `  '${name}': (${input}, ${output}, ${request}),`).join("\n")}
};

/// The default-state recording of each \`<input> <mode>\`.
const graphStackDefaults = <String, String>{
${stackDefaults.map(([sample, name]) => `  '${sample}': '${name}',`).join("\n")}
};

${stackInputs.join("\n\n")}

${stackOutputs.join("\n\n")}
`;

for (const [file, text, count] of [[target, dart, recordings.length], [stackTarget, stackDart, stackRecordings.length]]) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, text);
  const format = spawnSync("dart", ["format", file], { cwd: path.join(repo, "app"), encoding: "utf8" });
  if (format.status !== 0) {
    fail(`dart format: exit ${format.status}\n${format.stderr}`);
  }
  console.log(`record-graph: ${count} recordings → ${path.relative(repo, file)}`);
}
