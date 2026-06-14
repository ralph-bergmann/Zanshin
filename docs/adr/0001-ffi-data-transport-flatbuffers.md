# ADR-0001: FFI data transport — FlatBuffers for composite data

- **Status:** Accepted
- **Date:** 2026-06-15
- **Deciders:** Ralph
- **Amends:** AD-1 (FFI error model), AD-3 (wire contract), AD-4 (worker response leg), AD-7 (schema bits) in `architecture.md`

## Context

AD-1 chose a **JSON result envelope** for all fallible FFI functions —
`{ ok, data, error }` serialized to a `*mut c_char`. AD-3 made `schemas/*.schema.json`
the wire contract with mandatory schema-validation in tests. AD-4 specified that
worker-isolate responses are the same JSON strings.

JSON-over-FFI for complex, variable-length data (graph slices, diffs) felt wrong
on review. A spike (`spikes/ffi-payload-bench/`) measured JSON vs FlatBuffers
head-to-head on synthetic-but-realistically-shaped payloads. The result depends
on data *shape + size*, not origin, so it transfers to real jj-lib payloads.

A secondary, explicit goal: **transport uniformity.** A per-payload mix of JSON
and FlatBuffers was rejected in favor of a single, symmetric rule.

## Decision

Transport across the **Rust ↔ Dart FFI boundary** is determined purely by the
data's type:

| Data | Transport | Free function |
|------|-----------|---------------|
| fixed scalar (`int` / `bool` / `float`) | plain C value | — |
| lone string | `*mut c_char` (CString, Rust-owned) | `zanshin_string_free` |
| composite (table / list / nested) | **FlatBuffers** (single buffer) | `zanshin_buffer_free` |

The fallible-call envelope becomes a FlatBuffers table with a union payload:

```fbs
union Payload { GraphSlice, Diff, Status, OpLog /* ...closed registry... */ }

table FfiError { code: string; context: string; }

table Envelope {
  ok: bool;
  error: FfiError;   // null when ok
  data: Payload;     // typed union, exhaustively matchable on the Dart side
}
```

- Async Rust→Dart signals (`NativeCallable.listener`: watcher events, progress)
  carry composite data → FlatBuffers, same as everything else.
- **The only remaining JSON is `zanshin-mcp`'s JSON-RPC**, which the MCP protocol
  mandates. That is a *different boundary* (MCP ↔ client), not our FFI transport,
  so the FFI boundary stays 100 % uniform. `zanshin-jj`'s internal API is typed
  Rust with no serialization at all.
- `.fbs` schemas become the wire-contract source of truth, replacing
  `schemas/*.schema.json` for the FFI boundary. The official `flatc` compiler
  generates both Rust (`flatc --rust`) and Dart (`flatc --dart`) accessors;
  generated code is committed (consistent with the existing codegen discipline).

## Evidence

From the spike (Apple M4 Pro, macOS 26.5.1, release build; full table in
`spikes/ffi-payload-bench/README.md`):

- **Wire size:** FlatBuffers 27–30 % smaller across all sizes.
- **Rust serialize:** FlatBuffers 1.3–1.7× faster.
- **Dart parse/access** (the latency-critical consumer side):
  - materialize everything (incl. strings): **5.4–9× faster**;
  - read a subset of fields (virtualized-UI case): **77–1400× faster** (zero-copy);
  - absolute JSON cost is user-perceptible at scale (~50 ms to decode a 50k-node
    graph, ~56 ms for a 2k-file diff) — material independent of jj-lib compute time.
- JSON numbers are a lower bound (untyped maps, no typed-class mapping), so the
  FlatBuffers advantage is, if anything, understated.

## Consequences

**Positive**

- One transport, one mental model: "not a fixed scalar or lone string → FlatBuffers."
- Large, consistent perf win exactly where Zanshin's big payloads live (10k-commit
  graphs, large diffs) and on the side that governs UI responsiveness.
- Smaller wire → also less to copy across the isolate `SendPort`.
- Typed accessors make a wrong-shape payload a compile error; the FlatBuffers
  `Verifier` is the runtime integrity backstop. The AD-3 correctness backstop
  survives — it changes form (typed + verifier) rather than disappearing.
- FlatBuffers has first-class schema-evolution rules, fitting the WIP posture.

**Negative / costs (accepted)**

- `flatc` is a build dependency on both sides; generated code is committed on both
  sides. Tooling pinned on the 25.x line: `flatc` 25.12.19, Rust `flatbuffers`
  25.12.19, Dart `flat_buffers` 25.9.23.
- FlatBuffers builders (bottom-up, nested) are more verbose on the Rust side than
  `serde_json::to_string`. Tameable with helpers/macros; the verbosity is uniform.
- The wire is binary, not human-readable. Mitigated: logs are Rust-side `tracing`
  (structured, not wire bytes); tests use typed accessors; `flatc --json` converts
  for ad-hoc inspection.
- The FFI string-return shape for composite data changes from CString to
  buffer+len with `zanshin_buffer_free`.

## Affected prior decisions

- **AD-1** — superseded for the data path: JSON envelope → FlatBuffers `Envelope`
  table. The infallible-hot-path exception (plain scalars) stands. The
  `catch_unwind` → `internal.panic` rule stands (error becomes an `FfiError`).
- **AD-3** — `schemas/*.schema.json` (JSON Schema) → `schemas/*.fbs` as the wire
  contract; "validate every FFI-JSON in tests" → "typed FlatBuffers accessors +
  `Verifier`". The *principle* (schema is the contract, drift caught in tests) holds.
- **AD-4** — worker→UI responses are no longer JSON strings; they are FlatBuffers
  byte buffers parsed into typed accessors. The command leg (`sealed WorkerCommand`),
  `commandId` correlation, and per-stream event ports are unchanged.
- **AD-7** — the "JSON schemas committed + validated" clauses now refer to `.fbs`.
- **AD-6** — unaffected: MCP error/responses are JSON-RPC by protocol, independent
  of the FFI transport.

## Tier-2 (end-to-end isolate round-trip) — consciously skipped

The end-to-end round-trip through the real FFI + worker isolate was **not**
measured (Ralph's call, 2026-06-15). The spike evidence (serialize + parse +
size, all decisive) and the fact that the isolate leg copies raw bytes either
way — where FlatBuffers' smaller buffers mean *less* to copy — made a Tier-2
confirmation unlikely to change the decision. The decision is final.

## Open questions

- Builder ergonomics: whether to add a thin Rust helper layer / macro to reduce
  nested-builder boilerplate.
- `.fbs` directory layout and naming convention under `schemas/`.

## References

- Spike: `spikes/ffi-payload-bench/` (README has the full result tables and a
  reproducibility guide).
- `architecture.md` §§ AD-1, AD-3, AD-4, AD-6, AD-7.
