#!/usr/bin/env node
// Stage 4 — lines of code per implementation, tests excluded: Rust's inline `#[cfg(test)]` tails
// and the test-only `checks.rs` module, Dart's test/ directory. "code" = non-blank lines that are
// not only a comment (`//`, `///`, `//!`).
//
//   node tools/loc.mjs

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const spike = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

function count(file, { cutAtCfgTest = false, cfgTestTail = false } = {}) {
  let lines = fs.readFileSync(file, "utf8").split("\n");
  if (lines.at(-1) === "") lines.pop();
  if (cfgTestTail) {
    const k = lines.findIndex((l) => l.trim() === "#[cfg(test)]");
    lines = k >= 0 ? lines.slice(k) : [];
  } else if (cutAtCfgTest) {
    // lib.rs: `#[cfg(test)] mod checks;` is two lines mid-file; elsewhere the tests are the tail.
    const k = lines.findIndex((l) => l.trim() === "#[cfg(test)]");
    if (k >= 0) lines = lines[k + 1]?.trim().endsWith(";") ? lines.filter((_, i) => i !== k && i !== k + 1) : lines.slice(0, k);
  }
  const code = lines.filter((l) => l.trim() !== "" && !l.trim().startsWith("//")).length;
  return { lines: lines.length, code };
}

function table(title, groups) {
  console.log(`\n${title}\n`);
  console.log("| part | files | lines | code |");
  console.log("|---|---|---|---|");
  const all = { lines: 0, code: 0 };
  for (const [part, files, opts] of groups) {
    const c = files.map((f) => count(path.join(spike, f), opts)).reduce((a, b) => ({ lines: a.lines + b.lines, code: a.code + b.code }));
    all.lines += c.lines;
    all.code += c.code;
    console.log(`| ${part} | ${files.map((f) => path.basename(f)).join(", ")} | ${c.lines} | ${c.code} |`);
  }
  console.log(`| **total** | | **${all.lines}** | **${all.code}** |`);
}

table("Rust (tests excluded)", [
  ["layout (§4)", ["rust/src/layout.rs", "rust/src/order.rs"], { cutAtCfgTest: true }],
  ["input parse + validation (§2)", ["rust/src/input.rs"], { cutAtCfgTest: true }],
  ["output + digest (§3, §8.4)", ["rust/src/output.rs"], { cutAtCfgTest: true }],
  ["crate root", ["rust/src/lib.rs"], { cutAtCfgTest: true }],
  ["CLI + bench (§6, §8)", ["rust/src/main.rs"]],
]);
table("Dart (tests excluded)", [
  ["layout (§4)", ["dart/lib/src/layout.dart", "dart/lib/src/lane_order.dart"]],
  ["input parse + validation (§2)", ["dart/lib/src/input.dart"]],
  ["output + digest (§3, §8.4)", ["dart/lib/src/output.dart"]],
  ["library root", ["dart/lib/graph_layout.dart"]],
  ["CLI + bench (§6, §8)", ["dart/bin/graph_layout.dart"]],
]);
table("Tests", [
  ["Rust inline `#[cfg(test)]` tails", ["rust/src/input.rs", "rust/src/layout.rs", "rust/src/order.rs", "rust/src/output.rs"], { cfgTestTail: true }],
  ["Rust test-only checks module", ["rust/src/checks.rs"]],
  ["Dart", ["dart/test/layout_test.dart", "dart/test/harness.dart"]],
]);
