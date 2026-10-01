#!/usr/bin/env node
// Stage 4 — FFI payload size per variant, as exact byte counts from the inputs and the layout
// outputs (no FFI plumbing). Fixed-width little-endian scalar arrays (struct-of-arrays), which is
// what a FlatBuffers table of scalar vectors / vectors of structs carries (plus a few bytes of
// vtable and length prefixes per vector, ignored here).
//
//   Dart layout: Rust ships the TOPOLOGY only.
//     header   now_ms i64, utc_offset_min i16, n u32, edge count u32           18 B
//     per node ts_ms i64 (null = sentinel), priority u32, flags u8 (is_root),
//              CSR offset u32 (+1 final offset)                                  17 B (+4)
//     per jj edge (direct / indirect / missing) target u32 (missing = sentinel), kind u8   5 B
//   Rust layout: Rust ships the topology AND the LAYOUT:
//     header   mode u8, unit u8, rows u32, lanes u32, bucket count u32           14 B
//     per node row u32, lane u16, col u16                                          8 B
//     per layout edge route (2 bits) + blocked (1 bit) in one u8; from/to are implied by the
//              topology's CSR order with missing edges skipped (SPEC §3)          1 B
//     per bucket kind u8, value i64, start u32, end u32 (time and free)          17 B
//   The Rust-layout variant can drop `priority` (4 B/node): only the layout reads it.
//
//   node tools/payload.mjs [--only <substring>]
// Needs outputs/rust/<input>.<mode>.greedy.json from `node tools/compare.mjs`.

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const spike = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const argv = process.argv.slice(2);
const only = argv.includes("--only") ? argv[argv.indexOf("--only") + 1] : null;
const manifest = JSON.parse(fs.readFileSync(path.join(spike, "inputs/manifest.json"), "utf8"));

const kb = (b) => (b >= 1e6 ? `${(b / 1e6).toFixed(2)} MB` : `${(b / 1e3).toFixed(1)} KB`);
const pct = (a, b) => `${((100 * a) / b).toFixed(0)} %`;

console.log("| input | n | jj edges | layout edges | topology (Dart layout) | + layout, compact/free | + layout, time (buckets) | layout share (time) |");
console.log("|---|---|---|---|---|---|---|---|");
for (const f of manifest.files) {
  if (only && !f.file.includes(only)) continue;
  const inp = JSON.parse(fs.readFileSync(path.join(spike, "inputs", f.file), "utf8"));
  const n = inp.nodes.length;
  const jjEdges = inp.nodes.reduce((s, x) => s + x.parents.length, 0);
  const topology = 18 + 17 * n + 4 + 5 * jjEdges;
  const layoutOf = (mode) => {
    const o = JSON.parse(fs.readFileSync(path.join(spike, "outputs/rust", `${f.file.replace(/\.json$/, "")}.${mode}.greedy.json`), "utf8"));
    if (o.lanes > 0xffff) throw new Error(`${f.file} ${mode}: ${o.lanes} lanes do not fit u16`);
    if (o.rows > 0xffffffff) throw new Error(`${f.file} ${mode}: rows do not fit u32`);
    return { bytes: 14 + 8 * n + o.edges.length + 17 * o.buckets.length, edges: o.edges.length, buckets: o.buckets.length, lanes: o.lanes };
  };
  const compact = layoutOf("compact");
  const time = layoutOf("time");
  console.log(`| ${f.file.replace(/\.json$/, "")} | ${n} | ${jjEdges} | ${compact.edges} | ${kb(topology)} | +${kb(compact.bytes)} (${pct(compact.bytes, topology)}) | +${kb(time.bytes)} (${time.buckets}) | ${pct(time.bytes, topology + time.bytes)} |`);
}
