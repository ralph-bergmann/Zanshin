#!/usr/bin/env node
// Stage 4 — iteration friction: the time from a one-line edit in the layout code to a result.
// Copies rust/ and dart/ into a work dir (default: $TMPDIR/graph-layout-friction; nothing in the
// spike is edited), builds once, then toggles one line of the `free` gap function between two
// equivalent spellings (so every test stays green) and times, per edit (median of --reps):
//   Rust: cargo build --release | cargo build (dev) | cargo test --release | release build + run
//   Dart: dart compile exe | dart run (JIT: edit → layout written) | dart run test/layout_test.dart
//
//   node tools/friction.mjs [--reps 3] [--workdir <dir>]
// Needs cargo and dart on PATH and inputs/synth-10k.json.

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const spike = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const argv = process.argv.slice(2);
const opt = (f, d) => (argv.includes(f) ? argv[argv.indexOf(f) + 1] : d);
const reps = Number(opt("--reps", "3"));
const work = path.resolve(opt("--workdir", path.join(os.tmpdir(), "graph-layout-friction")));
const input = path.join(spike, "inputs/synth-10k.json");

fs.rmSync(work, { recursive: true, force: true });
for (const [from, to] of [["rust/src", "rust/src"], ["rust/Cargo.toml", "rust/Cargo.toml"], ["rust/Cargo.lock", "rust/Cargo.lock"],
  ["dart/lib", "dart/lib"], ["dart/bin", "dart/bin"], ["dart/test", "dart/test"], ["dart/pubspec.yaml", "dart/pubspec.yaml"],
  ["dart/analysis_options.yaml", "dart/analysis_options.yaml"]]) {
  fs.cpSync(path.join(spike, from), path.join(work, to), { recursive: true });
}
const rust = path.join(work, "rust"), dart = path.join(work, "dart");
// The spike builds with the repo's pinned toolchain (rustup finds ../../rust-toolchain.toml by
// walking up); a work dir outside the repo would silently fall back to the default toolchain.
const pin = path.join(spike, "../../rust-toolchain.toml");
if (fs.existsSync(pin)) fs.copyFileSync(pin, path.join(rust, "rust-toolchain.toml"));
fs.mkdirSync(path.join(dart, "build"), { recursive: true }); // `dart compile exe -o` does not create it

/** Runs a command, returns wall ms; throws on a non-zero exit unless allowed. */
function timed(cmd, args, cwd, env = {}) {
  const t0 = process.hrtime.bigint();
  const r = spawnSync(cmd, args, { cwd, encoding: "utf8", maxBuffer: 1 << 26, env: { ...process.env, ...env } });
  const ms = Number(process.hrtime.bigint() - t0) / 1e6;
  if (r.status !== 0) throw new Error(`${cmd} ${args.join(" ")} failed (${r.status}):\n${r.stderr}`);
  return ms;
}

// The edited line: SPEC §4.2 gap(), written two equivalent ways.
const EDITS = [
  { file: path.join(rust, "src/layout.rs"), a: "min(48, (2 * l2(1 + g.div_euclid(MINUTE_MS))).div_euclid(256))", b: "(2 * l2(1 + g.div_euclid(MINUTE_MS))).div_euclid(256).min(48)" },
  { file: path.join(dart, "lib/src/layout.dart"), a: "return gap < 48 ? gap : 48;", b: "return gap > 48 ? 48 : gap;" },
];
function toggle(lang) {
  const e = EDITS[lang === "rust" ? 0 : 1];
  const src = fs.readFileSync(e.file, "utf8");
  const [from, to] = src.includes(e.a) ? [e.a, e.b] : [e.b, e.a];
  if (!src.includes(from)) throw new Error(`edit anchor not found in ${e.file}`);
  fs.writeFileSync(e.file, src.replace(from, to));
}

const median = (xs) => [...xs].sort((a, b) => a - b)[Math.floor(xs.length / 2)];
const results = [];
function measure(label, lang, fn) {
  const xs = [];
  for (let k = 0; k < reps; k++) {
    toggle(lang);
    xs.push(fn());
  }
  results.push({ label, median: median(xs), all: xs });
  console.log(`${label.padEnd(58)} median ${(median(xs) / 1000).toFixed(2)} s  [${xs.map((x) => (x / 1000).toFixed(2)).join(", ")}]`);
}

const out = path.join(work, "out.json");
const cargoEnv = { CARGO_TARGET_DIR: path.join(rust, "target") };
console.log(`work dir ${work}, ${reps} edits per row\n`);
console.log(`cold: cargo build --release (serde + serde_json + crate)          ${(timed("cargo", ["build", "--release", "--offline"], rust, cargoEnv) / 1000).toFixed(2)} s`);
timed("cargo", ["build", "--offline"], rust, cargoEnv);
timed("cargo", ["test", "--release", "--offline", "--no-run"], rust, cargoEnv);
timed("dart", ["pub", "get", "--offline"], dart);
timed("dart", ["compile", "exe", "bin/graph_layout.dart", "-o", "build/graph_layout"], dart);
console.log("");

measure("Rust: cargo build --release", "rust", () => timed("cargo", ["build", "--release", "--offline"], rust, cargoEnv));
measure("Rust: cargo build (dev, incremental)", "rust", () => timed("cargo", ["build", "--offline"], rust, cargoEnv));
measure("Rust: cargo test --release (compile + run unit tests)", "rust", () => timed("cargo", ["test", "--release", "--offline"], rust, cargoEnv));
measure("Rust: edit → layout (cargo build --release + run, synth-10k)", "rust", () =>
  timed("cargo", ["build", "--release", "--offline"], rust, cargoEnv) +
  timed(path.join(rust, "target/release/graph-layout"), ["layout", "--mode", "free", "--order", "greedy", input, out], rust));
measure("Dart: dart compile exe", "dart", () => timed("dart", ["compile", "exe", "bin/graph_layout.dart", "-o", "build/graph_layout"], dart));
measure("Dart: edit → layout (dart run, JIT, synth-10k)", "dart", () =>
  timed("dart", ["run", "bin/graph_layout.dart", "layout", "--mode", "free", "--order", "greedy", input, out], dart));
measure("Dart: dart run test/layout_test.dart", "dart", () => timed("dart", ["run", "test/layout_test.dart"], dart));
