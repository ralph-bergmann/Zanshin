#!/usr/bin/env node
// SPEC.md §8 — the benchmark. Runs one `bench` process per impl × input × mode × order (W = 10,
// N = 31, the defaults), sequentially, with the three impls interleaved per combination so slow
// drift hits all of them alike. Writes the bench lines as JSONL, checks that every impl reports the
// same nodes / edges / rows / lanes / digest per combination, and prints the README tables.
//
//   node tools/bench.mjs [--impl rust,dart-aot,dart-jit] [--only <substring>] [--out <file.jsonl>]
//   node tools/bench.mjs --report <file.jsonl>      # tables only, from an earlier run
//
// Build first (from the spike root):
//   cargo build --release --manifest-path rust/Cargo.toml
//   dart compile exe dart/bin/graph_layout.dart -o dart/build/graph_layout
// Dart JIT runs as `dart run bin/graph_layout.dart` in dart/ (SPEC §6).

import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const spike = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const MODES = ["compact", "time", "free"];
const ORDERS = ["greedy", "optimized"];
const IMPLS = ["rust", "dart-aot", "dart-jit"];
const PHASES = ["parse", "layering", "lanes", "blocked", "routing", "ordering", "total"];

const argv = process.argv.slice(2);
const opt = (f) => (argv.includes(f) ? argv[argv.indexOf(f) + 1] : null);

function command(impl, args) {
  switch (impl) {
    case "rust":
      return { cmd: path.join(spike, "rust/target/release/graph-layout"), args, cwd: spike };
    case "dart-aot":
      return { cmd: path.join(spike, "dart/build/graph_layout"), args, cwd: spike };
    case "dart-jit":
      return { cmd: "dart", args: ["run", "bin/graph_layout.dart", ...args], cwd: path.join(spike, "dart") };
    default:
      throw new Error(`unknown impl ${impl}`);
  }
}

function runAll() {
  const impls = (opt("--impl") ?? IMPLS.join(",")).split(",");
  const only = opt("--only");
  const stamp = new Date().toISOString().replace(/[:.]/g, "-");
  const out = opt("--out") ?? path.join(spike, "outputs/bench", `bench-${stamp}.jsonl`);
  fs.mkdirSync(path.dirname(out), { recursive: true });
  fs.writeFileSync(out, "");
  const manifest = JSON.parse(fs.readFileSync(path.join(spike, "inputs/manifest.json"), "utf8"));
  const files = manifest.files.map((f) => f.file).filter((f) => !only || f.includes(only));
  let bad = 0;
  for (const file of files) {
    const input = path.join(spike, "inputs", file);
    for (const mode of MODES) {
      for (const order of ORDERS) {
        const seen = [];
        for (const impl of impls) {
          const c = command(impl, ["bench", "--mode", mode, "--order", order, input]);
          const t0 = process.hrtime.bigint();
          const r = spawnSync(c.cmd, c.args, { cwd: c.cwd, encoding: "utf8", maxBuffer: 1 << 24 });
          const wallMs = Number(process.hrtime.bigint() - t0) / 1e6;
          const line = (r.stdout ?? "").trim().split("\n").filter((l) => l.startsWith("{")).pop();
          if (r.status !== 0 || !line) {
            console.error(`FAIL ${impl} ${file} ${mode} ${order}: exit ${r.status}\n${r.stderr}`);
            bad++;
            continue;
          }
          const b = JSON.parse(line);
          b.process_wall_ms = Math.round(wallMs);
          fs.appendFileSync(out, JSON.stringify(b) + "\n");
          seen.push(b);
          const tot = b.phases.total.median_ns;
          console.log(`${impl.padEnd(8)} ${file.padEnd(28)} ${mode.padEnd(7)} ${order.padEnd(9)} total ${fmt(tot).padStart(9)}  parse ${fmt(b.phases.parse.median_ns).padStart(9)}  (${Math.round(wallMs)} ms wall)`);
        }
        const key = (b) => [b.nodes, b.edges, b.rows, b.lanes, b.digest].join("/");
        if (new Set(seen.map(key)).size > 1) {
          console.error(`MISMATCH ${file} ${mode} ${order}: ${seen.map((b) => `${b.impl}=${key(b)}`).join(" ")}`);
          bad++;
        }
      }
    }
  }
  console.log(`\nwrote ${path.relative(spike, out)}${bad ? `; ${bad} failure(s)` : ""}`);
  report(out);
  process.exitCode = bad ? 1 : 0;
}

/** ns → a short human string (µs below 1 ms, ms above). */
function fmt(ns) {
  if (ns < 1e6) return `${(ns / 1e3).toFixed(ns < 1e4 ? 1 : 0)} µs`;
  return `${(ns / 1e6).toFixed(ns < 1e7 ? 2 : 1)} ms`;
}

const ratio = (a, b) => (a && b ? `${(a / b).toFixed(1)}×` : "–");

function report(file) {
  const rows = fs.readFileSync(file, "utf8").trim().split("\n").filter(Boolean).map((l) => JSON.parse(l));
  const get = (impl, input, mode, order) =>
    rows.find((b) => b.impl === impl && b.input === input && b.mode === mode && b.order === order);
  const inputs = [...new Set(rows.map((b) => b.input))];
  const tot = (b) => b?.phases.total.median_ns;
  const t = (b) => (b ? fmt(tot(b)) : "–");

  console.log("\n### Layout total, Rust --release vs Dart AOT (median of 31; parse excluded)\n");
  console.log("| input | n | mode | lanes | greedy: Rust | Dart AOT | AOT/Rust | optimized: Rust | Dart AOT | AOT/Rust |");
  console.log("|---|---|---|---|---|---|---|---|---|---|");
  for (const input of inputs) for (const mode of MODES) {
    const [rg, ag, ro, ao] = [["rust", "greedy"], ["dart-aot", "greedy"], ["rust", "optimized"], ["dart-aot", "optimized"]].map(([i, o]) => get(i, input, mode, o));
    const any = rg ?? ag ?? ro ?? ao;
    if (!any) continue;
    console.log(`| ${input.replace(/\.json$/, "")} | ${any.nodes} | ${mode} | ${any.lanes} | ${t(rg)} | ${t(ag)} | ${ratio(tot(ag), tot(rg))} | ${t(ro)} | ${t(ao)} | ${ratio(tot(ao), tot(ro))} |`);
  }

  console.log("\n### Dart JIT (`dart run`) vs Dart AOT (median total)\n");
  console.log("| input | mode | greedy: AOT | JIT | JIT/AOT | optimized: AOT | JIT | JIT/AOT |");
  console.log("|---|---|---|---|---|---|---|---|");
  for (const input of inputs) for (const mode of MODES) {
    const [ag, jg, ao, jo] = [["dart-aot", "greedy"], ["dart-jit", "greedy"], ["dart-aot", "optimized"], ["dart-jit", "optimized"]].map(([i, o]) => get(i, input, mode, o));
    if (!(ag ?? jg)) continue;
    console.log(`| ${input.replace(/\.json$/, "")} | ${mode} | ${t(ag)} | ${t(jg)} | ${ratio(tot(jg), tot(ag))} | ${t(ao)} | ${t(jo)} | ${ratio(tot(jo), tot(ao))} |`);
  }

  console.log("\n### Layout total, all impls (median; min in parentheses)\n");
  console.log("| input | n | mode | order | lanes | Rust | Dart AOT | AOT/Rust | Dart JIT | JIT/Rust |");
  console.log("|---|---|---|---|---|---|---|---|---|---|");
  for (const input of inputs) for (const mode of MODES) for (const order of ORDERS) {
    const [r, a, j] = IMPLS.map((i) => get(i, input, mode, order));
    const any = r ?? a ?? j;
    if (!any) continue;
    const cell = (b) => (b ? `${fmt(b.phases.total.median_ns)} (${fmt(b.phases.total.min_ns)})` : "–");
    console.log(`| ${input.replace(/\.json$/, "")} | ${any.nodes} | ${mode} | ${order} | ${any.lanes} | ${cell(r)} | ${cell(a)} | ${ratio(tot(a), tot(r))} | ${cell(j)} | ${ratio(tot(j), tot(r))} |`);
  }

  console.log("\n### Parse + validate (median; compact/greedy run; not part of total)\n");
  console.log("| input | bytes | Rust (serde_json) | Dart AOT (dart:convert) | AOT/Rust | Dart JIT | JIT/Rust |");
  console.log("|---|---|---|---|---|---|---|");
  for (const input of inputs) {
    const [r, a, j] = IMPLS.map((i) => get(i, input, "compact", "greedy"));
    const bytes = fs.existsSync(path.join(spike, "inputs", input)) ? fs.statSync(path.join(spike, "inputs", input)).size : "?";
    const p = (b) => b?.phases.parse.median_ns;
    console.log(`| ${input.replace(/\.json$/, "")} | ${bytes} | ${p(r) ? fmt(p(r)) : "–"} | ${p(a) ? fmt(p(a)) : "–"} | ${ratio(p(a), p(r))} | ${p(j) ? fmt(p(j)) : "–"} | ${ratio(p(j), p(r))} |`);
  }

  for (const mode of MODES) {
    console.log(`\n### Phases, ${mode} mode (median)\n`);
    console.log("| input | order | impl | layering | lanes | blocked | routing | ordering | total |");
    console.log("|---|---|---|---|---|---|---|---|---|");
    for (const input of ["fixture-large-all.json", "synth-10k.json", "synth-100k.json"]) for (const order of ORDERS) for (const impl of ["rust", "dart-aot"]) {
      const b = get(impl, input, mode, order);
      if (!b) continue;
      const ph = PHASES.slice(1).map((p) => fmt(b.phases[p].median_ns));
      console.log(`| ${input.replace(/\.json$/, "")} | ${order} | ${impl} | ${ph.join(" | ")} |`);
    }
  }
}

if (opt("--report")) report(path.resolve(opt("--report")));
else runAll();
