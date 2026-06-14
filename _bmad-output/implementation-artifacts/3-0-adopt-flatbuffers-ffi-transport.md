# Story 3.0: Adopt FlatBuffers FFI transport (foundation + migration)

Status: ready-for-dev

> **Origin:** [ADR-0001 — FFI data transport: FlatBuffers for composite data](../../docs/adr/0001-ffi-data-transport-flatbuffers.md).
> This story supersedes the JSON-envelope transport of AR-AD-1/AR-AD-3/AR-AD-4 (and the
> `*.schema.json` wire contract) for the Rust ↔ Dart FFI boundary. It is **foundational**:
> it lands the FlatBuffers tooling + core envelope schema **before** Story 3.1, and
> re-points the dependent stories. There is essentially no JSON code to tear out —
> `zanshin-ffi/src` is still a one-line `lib.rs`, so this is a forward-looking adoption,
> not a rip-out.

---

## Story

As the Rust + Dart developer building the FFI boundary,
I want the FlatBuffers transport infrastructure in place (compiler, deps, schema dir,
committed codegen, the core `Envelope`, and the buffer ownership contract),
so that every later FFI story (3.1 envelope, 3.2 strings/version, 3.4a/3.4b wrappers,
4.6 graph, 5.8 diff, 6.5 mutations, 3.8 diagnostics) is written in FlatBuffers from the
first line, with one uniform transport and one ownership rule.

**The transport rule (ADR-0001), restated:** fixed scalar (`int`/`bool`/`float`) → plain
C value; lone string → `*mut c_char` (CString, `zanshin_string_free`); composite
(table/list/nested) → **FlatBuffers** single buffer (`*mut u8` + len,
`zanshin_buffer_free`). The only JSON in the project is `zanshin-mcp`'s protocol-mandated
JSON-RPC — a different boundary, unaffected.

A working proof-of-concept already exists at `spikes/ffi-payload-bench/` (the bake-off that
drove ADR-0001); lift its `flatc` build wiring and builder patterns rather than reinventing them.

---

## Acceptance Criteria

### AC-1 — FlatBuffers toolchain & dependencies

1. `flatc` (official FlatBuffers compiler, `25.12.19`) is a documented prerequisite
   (`brew install flatbuffers`); the README / build doc states the pin.
2. Workspace dep `flatbuffers = "=25.12.19"` added to `[workspace.dependencies]`; consumed
   by `zanshin-ffi` (and any crate that builds/reads buffers) via `flatbuffers = { workspace = true }`.
3. Dart dep `flat_buffers: ^25.9.23` added to `app/pubspec.yaml`.
4. The three versions (flatc / `flatbuffers` crate / `flat_buffers` package) are on the 25.x
   line and documented as needing to move together.

### AC-2 — Schema directory & codegen wiring

5. `schemas/` directory exists holding the `.fbs` wire schemas (replaces the deleted
   Story 1.8 JSON-schema dir). `schemas/README.md` states: `.fbs` is the wire contract;
   breaking changes are in-place edits in WIP; the generated accessors are committed.
6. `cargo make codegen` (Makefile.toml) is extended to run `flatc --rust` (into
   `crates/zanshin-ffi/`) **and** `flatc --dart` (into `app/lib/src/ffi/`) for every
   `schemas/*.fbs`, alongside the existing cbindgen/ffigen steps. cbindgen stays — the
   `extern "C"` functions (now returning buffers) still need the committed C header.
7. The `flatc`-generated Rust and Dart accessors are **committed** (same discipline as
   `zanshin_ffi.h` / `bindings.dart`). The build never regenerates them.

### AC-3 — Core envelope schema (`schemas/envelope.fbs`)

8. `schemas/envelope.fbs` defines:
   `table FfiError { code: string; context: string; }`,
   `union Payload { … }` (the closed registry of concrete payload types; starts minimal,
   grows as nouns land), and
   `table Envelope { ok: bool; error: FfiError; data: Payload; }`.
9. `error.code` keeps the AR-P-4 dotted-lowercase taxonomy (`<domain>.<reason>`); the
   registry `docs/rust-error-codes.md` is still the source of truth. (No taxonomy change —
   only the carrier changed.)

### AC-4 — FFI buffer ownership contract

10. `crates/zanshin-ffi/src/ffi_strings.rs` (or a sibling) provides the buffer return path:
    a fallible `extern "C"` function returns an owned FlatBuffers buffer as `*mut u8` + a
    length out-param (or a small `{ ptr, len }` repr), allocated by Rust.
11. `extern "C" fn zanshin_buffer_free(ptr: *mut u8, len: usize)` exists and is the **only**
    way Dart releases a buffer. Allocation and free use the same Rust allocator — no
    `malloc`/`free` mismatch across runtimes.
12. `zanshin_string_free` is **retained** for lone-string returns (CString path unchanged).
13. The Dart worker reads buffers via the generated typed accessors and frees via
    `zanshin_buffer_free`; a `NativeFinalizer` belt-and-suspenders is wired (AD-2).

### AC-5 — Tests reflect the FlatBuffers contract

14. Tests that produce/consume an FFI buffer read it through the generated typed accessors
    (wrong shape = compile error) and run the FlatBuffers `Verifier` on untrusted buffers.
    No `jsonschema` / `json_schema` deps.
15. `insta` snapshots (where used) snapshot a **readable projection** of the decoded buffer
    (typed values rendered to JSON for the snapshot only, or `flatc --json`), not the binary.

### AC-6 — Dependent-story re-pointing (tracking, not code)

16. The following backlog stories are re-pointed to FlatBuffers; each carries a one-line
    scope-correction when it is created (matching the Story 2.3 callout pattern):

    | Story | Was (JSON) | Now (FlatBuffers) |
    |-------|------------|-------------------|
    | 3-1 | `envelope.rs` JSON envelope | FlatBuffers `Envelope` (this story lands the schema) |
    | 3-2 | ffi_strings / version | + `zanshin_buffer_free`; lone strings unchanged |
    | 3-4a / 3-4b | repo + read wrappers return JSON envelopes | return FlatBuffers `Envelope` buffers |
    | 3-8 | diagnostics JSON envelope | FlatBuffers `Envelope` (small; no extra schema) |
    | 3-9 | worker responses = JSON strings | worker responses = FlatBuffers buffers |
    | 4-2 | `graph.schema.json` | `schemas/graph.fbs` (rename the "json-output" story) |
    | 4-6 / 5-8 / 6-5 | FFI wrappers return JSON | return FlatBuffers buffers |
    | 5-5 | `diff.schema.json` | `schemas/diff.fbs` (rename the "json-output" story) |
    | 6-6 | `change.schema.json` extension | `schemas/change.fbs` extension |

17. **Unaffected:** Epic 7 (`zanshin-mcp`) stories — MCP speaks JSON-RPC by protocol
    (`rmcp`); `zanshin-mcp` consumes `zanshin-jj`'s typed Rust API directly, no FFI, no
    FlatBuffers. 7-10 (MCP error responses) keeps mapping the `error.code` taxonomy into
    `McpError`.

### AC-7 — Spike disposition

18. The `spikes/ffi-payload-bench/` proof-of-concept is either kept as a reference (its
    README holds the ADR-0001 evidence) or removed once its patterns are lifted — decided at
    implementation time. It is a detached workspace and never part of CI.

---

## Dev Notes

- **Why before 3.1:** Story 3.1 builds `envelope.rs`. With FlatBuffers the envelope *is* a
  generated schema type, so the schema + codegen wiring must exist first. Doing 3.0 → 3.1
  avoids writing then rewriting `envelope.rs`.
- **Union vs nested buffer:** AC-3 uses a FlatBuffers `union` for `Payload` (type-safe,
  exhaustively matchable). A `nested_flatbuffer` `[ubyte]` field is the alternative if the
  closed-union registry proves awkward; pick during implementation, record the choice.
- **Builder ergonomics (ADR-0001 open question):** the nested bottom-up builders are verbose
  on the Rust side. If the boilerplate bites, add a thin helper module — but don't reach for
  a macro until a second noun proves the shape.
- **`flatc` in CI:** `cargo make codegen` needs `flatc`; the WIP `verify-codegen` drift-gate
  is still deferred, so CI does not yet need `flatc`. When that gate lands, add `flatc` to
  the CI image. (The spike is deliberately a detached workspace so CI never needs `flatc`
  for it.)
- **No data-shape change:** payload *fields* (graph nodes, diff hunks, etc.) are unchanged —
  only their serialization. The Epic 2 typed Rust API (`zanshin-jj`) is untouched.

## References

- `docs/adr/0001-ffi-data-transport-flatbuffers.md` — the decision + spike evidence.
- `spikes/ffi-payload-bench/` — working `flatc` build wiring + Rust/Dart builder + reader patterns.
- `_bmad-output/project-context.md` § FFI boundary — the binding transport rule (already updated).
- `architecture.md` AD-1/AD-3/AD-4 (amended), `epics.md` AR-AD-1/AR-AD-3/AR-P-2 (amended).
