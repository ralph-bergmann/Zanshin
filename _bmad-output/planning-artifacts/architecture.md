---
stepsCompleted: [1, 2, 3, 4, 5, 6, 7, 8]
inputDocuments:
  - _bmad-output/planning-artifacts/prd.md
  - _bmad-output/planning-artifacts/research/technical-zanshin-jj-flutter-dart-hooks-mcp-research-2026-05-15.md
  - .claude/projects/-Users-ralph-bergmann-development-projects-privat-Zanshin/memory/project_zanshin.md
workflowType: 'architecture'
project_name: 'Zanshin'
user_name: 'Ralph'
date: '2026-05-15'
lastStep: 8
status: 'complete'
completedAt: '2026-05-15'
---

# Architecture Decision Document

_This document builds collaboratively through step-by-step discovery. Sections are appended as we work through each architectural decision together._

## Project Context Analysis

### Requirements Overview

**Functional Requirements (~64 FRs in 8 categories):**

| Category | Count | Component | Architectural Role |
|---|---|---|---|
| FR-JJ-* | 16 | `zanshin-jj` | Adapter / anti-corruption layer over jj-lib (pre-1.0) |
| FR-FFI-* | 10 | `zanshin-ffi` | Single cdylib; FFI surface + watcher subsystem |
| FR-MCP-* | 9 | `zanshin-mcp` | Standalone Rust binary using `rmcp`, stdio transport |
| FR-DF-* | 5 | `zanshin-diff` | Word-level diff + syntax highlight (Delta class) |
| FR-GR-* | 6 | `zanshin-graph` | DAG lane-assignment on jj-lib's `default_index` |
| FR-BO-* | 8 | Build orchestration | `cargo-make` + Dart Hooks + committed codegen |
| FR-DR-* | 6 | Distribution | Codesign + notarize + Sparkle + GitHub Releases |
| FR-RX-* | 4 | Reactivity (cross-cutting) | End-to-end behaviour of the watcher path |

**Non-Functional Requirements — architecturally load-bearing:**

- **Performance budgets (design targets — soft while WIP, no CI enforcement):**
  - Repo open with full lane-cache @ 10k commits: < 2s (NFR-P-1)
  - `zanshin-graph` full lane-cache: < 1s (sub-budget of NFR-P-1)
  - `zanshin-diff` JSON output @ 5k-line file: < 500ms (NFR-P-3)
  - Watcher `op_heads` → Dart callback: < 100ms (NFR-P-4 / FR-RX-1)
  - FFI handle create/destroy: < 1ms (NFR-P-5) — validates long-running-worker pattern
  - External edit → Watchman → jj snapshot → callback: < 500ms (NFR-P-6 / FR-RX-2)

  Budgets inform algorithm choice (e.g., `imara-diff` Histogram over `similar`); they are not enforced by CI perf-gates in the WIP phase.
- **No telemetry. Ever.** (NFR 5.3) — excludes Sentry/Crashlytics/Firebase/etc. Update check is the only outbound call; User-Agent only.
- **Licensing posture:** Apache-2.0 project; permissive-only dependencies. `cargo-deny` runs `advisories` + `bans` checks (security backstop). License-gate (`cargo-deny licenses`) and `pana` are deferred to the release phase.
- **FFI contract stability (post-1.0, aspirational):** once 1.0 ships, breaking `extern "C"` changes will require a major bump. While WIP (0.x), breaking changes are allowed — schemas, error codes, and FFI signatures may evolve without `_v2` suffixes; callers update. jj-lib churn is absorbed inside `zanshin-jj` (FR-JJ-16 — architectural invariant).
- **No data loss tolerance:** all mutations go through jj-lib via `zanshin-jj`. No shelling to `jj` CLI. No string-parsing of CLI output.

**Scale & Complexity:**

- Primary technical domain: native macOS desktop application with a cross-language stack (Rust core + Dart/Flutter shell + MCP protocol).
- Domain complexity: low (developer tooling, single-user, no multi-tenancy, no compliance regime beyond Apple notarization).
- Technical complexity: high (FFI lifecycle management, native async bridging via `NativeCallable.listener`, OS integration via Watchman through jj, codesign/notarize pipeline, jj-lib pre-1.0 absorption layer).
- Greenfield; no migration constraints.
- Code-quality production-grade from day one; scope/release-readiness is treated as WIP (release infrastructure deferred — see Section 4.7 deferred box in PRD). No "MVP shortcut" framing — every line of code that ships meets the project's quality bar; not every release-grade artefact ships yet.
- Architectural components: ~8 logical components (5 Rust libraries, 1 Rust binary, 1 Dart bootstrap, build/distribution pipeline).

### Technical Constraints & Dependencies

**Platform / Distribution:**
- **macOS-only.** Windows/Linux out of scope.
- Apple Developer ID codesigning + `notarytool` notarization mandatory for every binary (`.app`, embedded `zanshin-mcp`, Rust cdylib).
- Sparkle 2.x for auto-update; appcast served from GitHub Pages, artefacts from GitHub Releases.

**Environmental prerequisites (no Zanshin coupling):**
- **Watchman is a runtime dependency of JJ's `fsmonitor.backend = "watchman"` path, NOT of Zanshin.** Zanshin neither links, bundles, ships, nor calls Watchman. Its only interaction (FR-FFI-7) is to *detect* whether Watchman is installed and whether the relevant `.jj/repo/config.toml` keys are set (`fsmonitor.backend = "watchman"`, `register-snapshot-trigger = true`), then surface the result via FFI.
  - When present + configured: external edits trigger jj auto-snapshots → `op_heads` mutates → Zanshin's watcher fires. FR-RX-2 / NFR-P-6 budget (< 500ms) is reachable.
  - When absent: Zanshin still functions. External-edit detection degrades to non-reactive — refreshes only happen when a jj operation runs. FR-RX-2 / NFR-P-6 become unreachable; this is a UX consequence, not a Zanshin failure mode.
  - Why we don't bundle: Watchman runs as a per-user daemon — a bundled instance would conflict with a brew-installed one (facebook/watchman#558); codesign + auto-update complexity for a daemon we don't own; Homebrew already publishes a current bottle (2026.05.11.00) built from upstream source, which is the canonical macOS install path.

**Library dependencies (pinned):**
- Flutter `main` channel (≥ `3.44.0-1.0.pre-573`) / Dart `main` channel (≥ `3.13.0-104.0.dev`) / Rust `1.95.0` (systemwide installs, no FVM). README.md is the human source-of-truth; `app/pubspec.yaml` + `rust-toolchain.toml` are the machine-enforced pins.
- jj-lib v0.41.0 (pre-1.0 — API churn risk absorbed inside `zanshin-jj`, FR-JJ-16).
- `rmcp` v1.7.0, `native_toolchain_rust` v1.0.4, `imara-diff`, `tree-sitter-highlight`, `notify-rs`, `cargo-make`.

**Pattern constraints (locked by prior research and project_zanshin memory):**
- Rust integration: Dart Hooks + `native_toolchain_rust` only. `flutter_rust_bridge` rejected.
- One cdylib (`zanshin-ffi`); internal crates are plain `lib` and re-exported.
- All async Rust→Dart signals use `NativeCallable.listener` uniformly (watcher events + progress notifications).
- Dart async: one long-running worker isolate via manual `Isolate.spawn` + SendPort/ReceivePort.
- Generated code (`ffigen`, `cbindgen`) committed; build does not regenerate.
- `cargo make build` is the single build entry point.

**Scope boundaries (explicit non-goals):**
- No Flutter widgets / layout / navigation / theming (Ralph's separate work).
- No UX terminology decisions, no a11y work, no i18n.
- No Windows / Linux builds.
- No Git-only repo support (jj-init required; jj's Git backend is fine).
- No "good enough for now" code quality. (Scope is WIP — see code-quality vs. release-readiness clarification above.) No telemetry. No third-party analytics SDKs.

### Cross-Cutting Concerns Identified

These concerns span multiple components and will be explicitly decided in later sections:

1. **FFI boundary contract** — opaque handle types, FlatBuffers for composite data (ADR-0001), structured-error model with no panic crossings (FR-FFI-9), version handshake (FR-FFI-10), `NativeCallable.listener` shape for events and progress.
2. **Aggregator re-export discipline** — how `zanshin-ffi` re-exports internal crates' `extern "C"` APIs (single namespace? per-crate prefix? wrapper layer for FFI-only types?).
3. **Watcher reactivity end-to-end** — recovery from FS disturbances (FR-RX-4), event coalescing, channel backpressure, ordering guarantees for `op_heads` vs `working_copy/checkout` events.
4. **Same-repo concurrency model** — GUI + MCP server + external CLI simultaneously; filesystem mutation is the notification channel; no IPC; no locking choreography (FR-MCP-9, FR-RX-3).
5. **License compliance posture** — `cargo-deny` config for `advisories` + `bans` only in WIP. Full license-gate (`cargo-deny licenses` + Dart `pana`) is deferred to the release phase.
6. **Diagnostics & local-only logging** — the no-telemetry constraint forces a self-service diagnostics API (`extern "C"` returns version-string + log-path; full structured-JSON diagnostics deferred) and a local crash log location (`~/Library/Logs/Zanshin/`).

## Starter Template Evaluation

### Primary Technology Domain

**Cross-language native macOS desktop application** — Flutter shell + Rust workspace (5 crates) + Rust MCP binary, integrated via Dart Hooks + manual FFI (`cbindgen` + `ffigen`). No single starter template covers this composition.

### Starter Options Considered

| Candidate | Verdict |
|---|---|
| `brickpop/flutter-rust-ffi` | Rejected — iOS/Android focus, pre-Hooks era |
| `hareendranmg/rust-in-flutter` | Rejected — single-crate, not workspace |
| `shekohex/flutterust` | Rejected — older, not Dart-Hooks-based |
| `flutter_rust_bridge` starter | Rejected per existing decision — version-churn aversion, manual `cbindgen + ffigen` chain preferred |
| `native_toolchain_rust` example | Insufficient as starter — single-crate reference only; used as wiring reference (see below) |

### Decision: No starter template

**Rationale:**

1. No existing starter matches the Zanshin composition (macOS-only Flutter shell + multi-crate Cargo workspace + `zanshin-ffi` aggregator cdylib + `zanshin-mcp` binary + `cbindgen`/`ffigen` toolchain + `cargo-make` orchestration + codesign/notarize/Sparkle pipeline). Adapting any of them would leave nothing of the original.
2. Code-quality production-grade from day one is incompatible with starter cruft we would need to remove (demo widgets, alternative build paths, mobile-target boilerplate).
3. Flutter UI is explicitly out of scope for this architecture; a Flutter starter would force UI decisions (theming, navigation, state management) that belong in Ralph's separate UI work.
4. Vanilla CLI commands plus a hand-maintained workspace `Cargo.toml` produce a smaller, clearer, more reviewable scaffold than any generator output.
5. Epic A (Workspace & Build Foundation) executes this scaffolding explicitly — a starter would be redundant to and inconsistent with Epic A.

### Initialization Sequence (executed in Epic A)

```bash
# 1. Flutter macOS-only shell
flutter create --platforms=macos --org=de.dasralph zanshin

# 2. Cargo workspace — top-level Cargo.toml hand-written;
#    crate-type for zanshin-ffi set in its own Cargo.toml.
cargo new --lib zanshin-jj
cargo new --lib zanshin-ffi      # Cargo.toml manually set to crate-type = ["cdylib"]
cargo new --lib zanshin-diff
cargo new --lib zanshin-graph
cargo new --bin zanshin-mcp

# 3. Dart Hooks + FFI toolchain
dart pub add native_toolchain_rust hooks
dart pub add ffigen --dev

# 4. Build orchestrator
cargo install cargo-make
# Makefile.toml hand-maintained (Epic A deliverable)

# 5. License compliance toolchain (wired into CI in Epic H)
cargo install cargo-deny
dart pub global activate pana
```

**Toolchain pins** (committed at workspace root):
- `rust-toolchain.toml` → Rust 1.95.0
- Flutter / Dart pinned via README (no FVM) → Flutter `main` channel (≥ `3.44.0-1.0.pre-573`) / Dart `main` channel (≥ `3.13.0-104.0.dev`)
- `native_toolchain_rust` 1.0.4, `ffigen` 20.1.1, `rmcp` 1.7.0, `jj-lib` 0.41.0 (in respective `pubspec.yaml` / `Cargo.toml`)

### Reference Implementations (consult, do not fork)

| Reference | Used for |
|---|---|
| [hewigovens/JayJay](https://github.com/hewigovens/jayjay) | Adapter-crate pattern over `jj-lib`; validates the anti-corruption-layer approach |
| [native_toolchain_rust example](https://github.com/GregoryConrad/native_toolchain_rs) | Canonical `hook/build.dart` form for `RustBuilder` |
| [modelcontextprotocol/rust-sdk examples](https://github.com/modelcontextprotocol/rust-sdk) | Minimal `rmcp` stdio server skeleton |

**Note:** Workspace scaffolding via the commands above is the first implementation story of Epic A.

## Core Architectural Decisions

### Decision Priority Analysis

**Already Decided** (PRD + Research + Auto-Memory):
Toolchain pins, workspace layout, FFI tooling chain, async patterns, MCP framework, build orchestrator, watcher paths, Watchman role, diff/graph libraries, licensing, update mechanism. See "Project Context Analysis" and "Starter Template Evaluation" sections above.

**Critical (block Epic A or C):** AD-1 through AD-5.
**Important (shape architecture but not blocking):** AD-6, AD-7.
**Deferred to Step 5 (Patterns):** code-form conventions, naming, test-strategy details.

### AD-1: FFI Error Model

> **⚠️ AMENDED by [ADR-0001](../../docs/adr/0001-ffi-data-transport-flatbuffers.md) (2026-06-15):**
> the transport is now **FlatBuffers**, not JSON. The envelope is a FlatBuffers table
> `Envelope { ok: bool; error: FfiError; data: Payload (union); }` returned as an owned
> buffer (`*mut u8` + len, freed via `zanshin_buffer_free`). Lone strings stay CString
> (`zanshin_string_free`); fixed scalars stay plain. The error model and panic-catch
> behaviour below are unchanged — only the serialization format changed. See the ADR
> for the spike evidence and full rationale.

**Original decision (superseded — kept for history):** JSON result envelope for all faillible FFI functions:
`{ "ok": bool, "data": <payload> | null, "error": { "code": string, "message": string, "context": object | null } | null }`
returned as a `*mut c_char` (owned by Rust, freed via dedicated `zanshin_free_string`).

**Rationale (original):** Consistent with FR-FFI-3 (JSON for complex types). One pattern for all calls — AI implementation agents cannot accidentally choose a divergent error-handling form. Per-call allocation cost is negligible against the <1ms FFI overhead budget (NFR-P-5).

**Exception:** Infallible, hot-path functions (e.g., `zanshin_ffi_version()`, `zanshin_free_string()`) return plain types directly — they cannot fail in a recoverable way.

**Implementation note:** Rust panics inside `extern "C"` functions are caught via `std::panic::catch_unwind` and converted to `error.code = "internal_panic"`. No panic crosses the FFI boundary (FR-FFI-9).

### AD-2: Handle Lifetime & Ownership

**Decision:** Rust owns all opaque handles via `Box<T>`; Dart holds raw `*mut c_void` pointers. Lifecycle pairs: `zanshin_X_open(...) -> *mut X` / `zanshin_X_close(ptr)`.

**Dart-side safety net:** Every handle-wrapping Dart class registers a `NativeFinalizer` pointing at the corresponding `_close` function — guards against forgotten explicit close.

**Concurrency assumption:** Single-threaded Rust-side access. The long-running worker isolate is the sole consumer; no `Arc<Mutex<T>>` overhead. If a second consumer ever appears (e.g., a UI-thread diagnostic call), it goes through the worker via the command bus, not directly to the handle.

**Rationale:** Minimal overhead; matches the worker-isolate concurrency model (PRD §3.1). `NativeFinalizer` is belt-and-suspenders against leaks during development.

### AD-3: Schemas as Wire Contract

> **⚠️ AMENDED by [ADR-0001](../../docs/adr/0001-ffi-data-transport-flatbuffers.md) (2026-06-15):**
> the wire contract is now **FlatBuffers `.fbs` schemas** at `schemas/*.fbs`
> (`flatc`-generated, committed accessors on both sides), not JSON Schema. The
> correctness backstop survives in a stronger form: typed accessors make a wrong shape
> a compile error, and the FlatBuffers `Verifier` checks buffer integrity at runtime.
> No `jsonschema` / `json_schema`. The WIP-scope clause below (breaking changes in
> place, no `schema_version`, no `_v2`) still holds — applied to `.fbs`.

**Original decision (superseded — kept for history):** JSON Schema files at `schemas/*.schema.json` are the source of truth for the FFI wire format. Both Rust tests (`jsonschema` crate) and Dart tests (`json_schema` package) validate fixtures against the committed schemas — schema validation in every FFI-JSON test is mandatory (correctness backstop, not versioning).

**WIP scope (0.x):** Breaking changes are allowed. Schemas are updated in place; the old shape is deleted; callers update in the same PR. No `schema_version` field on emitted JSON. No `_v2`-suffix discipline on FFI functions when shapes change. Post-1.0 stability policy is open and will be revisited.

**Rationale:** AI agents reading the codebase determine field shape from the schema files (single source of truth). Schema-validation in tests catches encoder/decoder drift at the boundary — this stays. The versioning *machinery* (parallel `v1`/`v2`, in-wire `schema_version`, FFI `_v2` suffixes) is release-grade scaffolding that does not earn its keep while the API is still moving.

### AD-4: Worker Isolate Command Protocol

**Decision:**
- **Commands (UI → Worker):** Dart `sealed class WorkerCommand` with concrete subclasses per operation (`OpenRepo`, `GetStatus`, `Describe`, etc.). Sent over `SendPort` as Dart objects.
- **Responses (Worker → UI):** FlatBuffers byte buffers (the same bytes that crossed the FFI boundary; see [ADR-0001](../../docs/adr/0001-ffi-data-transport-flatbuffers.md)). Read by the requesting code via the generated typed accessors.
- **Correlation:** each command carries a `commandId` (incrementing int); worker echoes it in the response. A `Map<int, Completer<String>>` in the main isolate resolves the appropriate future.
- **Async events (watcher, progress):** separate `SendPort` per stream type. The worker isolate fans these out from the corresponding `NativeCallable.listener` callbacks.

**Rationale:** Typed commands give compile-time safety on the easy side (Dart→Worker). Responses are the FlatBuffers buffers already produced by Rust (ADR-0001), read via typed accessors. One correlation mechanism, one event-stream mechanism — no special cases for AI agents to misremember.

### AD-5: Watcher Event Coalescing & Backpressure

**Decision:** Use `notify-debouncer-full` (the official `notify-rs` companion crate) with a **50ms debounce window**.

- Single bounded `tokio::mpsc` channel from debouncer → `NativeCallable.listener` dispatch loop. Capacity: 256 events.
- **On channel-full:** drop-oldest with a `tracing::warn!` log. Degradation is recoverable (UI will refresh on next non-storm event); the alternative — panicking or blocking — is unacceptable.
- **Recovery from FS disturbances** (FR-RX-4): the debouncer auto-rescans when a watched path disappears and reappears (network drives, Time Machine snapshots).

**Rationale:** 50ms window leaves 50ms headroom inside the <100ms NFR-P-4 budget. Drop-oldest preserves the latest state — the only state that matters for UI refresh.

### AD-6: MCP Server Process Model

**Decision:** `zanshin-mcp` is a single-repo process. Repository selected at process start:

- **Primary:** `--repo <path>` CLI argument.
- **Fallback:** current working directory; binary walks up looking for `.jj/`. Errors if not found.
- **Not supported:** repository switching at runtime; multi-repo within one process; repository discovery beyond the CWD ancestor walk.

**Rationale:** Same-repo concurrency (FR-MCP-9) is about multiple consumers (GUI + MCP + external CLI) hitting the *same* repo, not about one MCP process serving multiple repos. Stateless process model. MCP-host configuration (Claude Desktop's `claude_desktop_config.json`) explicitly names the repo path. Anti-features (runtime switching, in-process repo registry) are excluded.

### AD-7: Workspace Versioning & Public API

**Decision:**
- **Versioning:** workspace-wide single version via `[workspace.package] version = "0.1.0"` in the root `Cargo.toml`. All five lib crates and the `zanshin-mcp` binary move together.
- **WIP stability (0.x):** breaking changes are allowed across the `extern "C"` ABI of `zanshin-ffi`, the MCP tool surface, and the `.fbs` wire schemas. Callers update in the same PR. No `_v2`-suffix discipline.
- **Post-1.0 stability:** open. The intent is that `extern "C"` ABI and MCP tool surface become the external SemVer contract once 1.0 ships, but the exact policy is deferred and will be revisited.
- **Crates.io publishing:** none in 0.x. Apache-2.0 license at the repo level covers reuse by source. Post-1.0, `zanshin-jj` may be published as a standalone crate for other jj-GUI builders — opt-in, not a 0.1 deliverable.
- **Wire schemas:** FlatBuffers `.fbs` committed at `schemas/*.fbs`; `flatc`-generated accessors committed on both sides. Typed accessors + `Verifier` are the correctness backstop (see AD-3, as amended by ADR-0001).

**Rationale:** Internal crate version-skew has no benefit for a single-team mono-repo. While WIP, locking the FFI/MCP/schema surface against breaking change would be premature — they're still discovering their shape.

### Decision Impact Analysis

**Implementation sequence (across epics):**
1. **Epic A** establishes workspace, versioning (AD-7), schema-dir convention (AD-3), `cargo-deny advisories + bans` config.
2. **Epic C** is where AD-1 (error envelope), AD-2 (handle lifetime), AD-3 (schemas as wire contract), AD-4 (command protocol), AD-5 (watcher debouncer) all land in code form.
3. **Epic G** applies AD-6 (MCP process model).
4. Other epics consume these patterns; nothing in B/D/E/F/H re-decides them.

**Cross-component dependencies:**
- AD-1 + AD-3 share the FlatBuffers `Envelope` (ADR-0001): error and data ride the same table. No in-wire `schema_version` in WIP.
- AD-2 + AD-4: handles are *only* dereferenced inside the worker isolate; commands carry handle-IDs (Dart-side), the worker resolves ID → pointer.
- AD-5 feeds AD-4: debounced watcher events become messages on the dedicated event-stream port.
- AD-6 + AD-1: MCP error responses re-use the same `error.code` taxonomy, mapped into MCP's own error structure (`McpError` from `rmcp`). MCP stays JSON-RPC (ADR-0001); the FlatBuffers envelope is FFI-only.

## Implementation Patterns & Consistency Rules

These rules exist to prevent divergence when multiple AI implementation agents touch the codebase. Where alternatives exist, the first form is canonical.

### P-1: FFI Function Naming
- All `extern "C"` symbols use prefix `zanshin_` + snake_case.
- Pattern: `zanshin_<noun>_<verb>` (e.g., `zanshin_repo_open`, `zanshin_diff_compute`).
- Constructor/destructor pairs share the noun (every `_open` has a matching `_close`).
- **WIP (0.x):** breaking changes are in-place — rename / change signature / delete; update all callers in the same PR. No `_v2`/`_v3` suffixes while WIP. (Suffix discipline is the deferred post-1.0 stability policy.)

### P-2: JSON Field Naming
- `snake_case` in all JSON across the FFI boundary and in committed schema files.
- Dart-side `@JsonKey(name: '...')` (or `json_serializable`) translates to `lowerCamelCase` on parse.
- Schema files at `schemas/*.fbs` are the source of truth (`flatc`-generated accessors committed; ADR-0001).

### P-3: Module/File Structure

**`zanshin-ffi` layout:**
```
src/
├── lib.rs              # re-exports + panic_handler + zanshin_ffi_version
├── repo.rs             # zanshin_repo_* — wraps zanshin-jj
├── diff.rs / graph.rs  # respective zanshin_<crate>_* wrappers
├── watcher.rs          # zanshin_watcher_*, debouncer, callback dispatch
├── envelope.rs         # FlatBuffers Envelope (AD-1, ADR-0001)
├── handle.rs           # Box<T> ↔ *mut T helpers, panic_catch wrapper
└── ffi_strings.rs      # CString in/out + zanshin_string_free + zanshin_buffer_free
```
Internal Rust crates stay pure `lib` — no `extern "C"` outside `zanshin-ffi`.

**Dart shell layout:**
```
lib/src/
├── ffi/         # bindings.dart (ffigen-generated, committed) + envelope.dart
├── worker/      # commands.dart (sealed classes), isolate.dart, correlation.dart
└── domain/      # typed result classes
hook/build.dart  # native_toolchain_rust hook
```

### P-4: Error Code Taxonomy
- `error.code` is a dotted lowercase string: `<domain>.<reason>`.
- Domains: `jj`, `diff`, `graph`, `ffi`, `watcher`, `mcp`, `internal`.
- Reasons are short, stable, machine-readable (`jj.repo_not_found`, `ffi.invalid_handle`, `internal.panic`).
- `docs/rust-error-codes.md` lists every code; PRs adding codes update it.
- Reasons never change after release; new reasons are added, old ones deprecated but callable.

### P-5: Tracing / Logging Discipline
- **Rust:** `tracing` + `tracing_appender`. Initialised once per process (`zanshin-ffi`, `zanshin-mcp`).
- **Sink:** rotating files at `~/Library/Logs/Zanshin/zanshin.log.YYYY-MM-DD`. No console in release builds.
- **Levels:** `error` (boundary violation), `warn` (degraded mode), `info` (lifecycle events), `debug` (per-call entry/exit — compiled out in release), `trace` (off in release).
- **Spans:** one per FFI call, fields `fn_name`, `command_id?`, `handle_id?`.
- **Verbosity:** `ZANSHIN_LOG=info` env override; default `info`.
- **Dart side (revised 2026-06-17 — supersedes the original "no Dart logger" clause):** A thin Dart logging façade forwards *every* record to the Rust `tracing` sink via the infallible `extern "C" zanshin_log(level, target, message)`. Rust stays the **single** log sink — no package-level Dart logger, no second log file. `dart:developer` `log()` survives ONLY as the bootstrap fallback, for records emitted before tracing/FFI is available (e.g. isolate-spawn failures). `zanshin_log` carries two lone strings as CStrings (ADR-0001: lone string → CString, not FlatBuffers); inbound-string ownership is the reverse of the outbound rule (Dart allocates + frees, Rust borrows for the call); it is `catch_unwind`-wrapped, returns `void` (no `Envelope`), is handle-free, and is therefore exempt from the single-consumer rule (AD-2) — callable from any isolate because `tracing`'s global subscriber is thread-safe.

### P-6: Generated Code Location & Regeneration
- `zanshin-ffi/include/zanshin_ffi.h` — cbindgen output, committed.
- `zanshin/lib/src/ffi/bindings.dart` — ffigen output, committed.
- **Regeneration:** explicit `cargo make codegen` only. `cargo make build` does NOT regenerate (FR-BO-6).
- **CI gate:** `cargo make verify-codegen` re-runs codegen into tmpdir, diffs against committed files, fails on drift.
- `cbindgen.toml` at workspace root; `ffigen.yaml` in the Dart package root.

### P-7: Test Layout
- Rust unit tests inline (`#[cfg(test)] mod tests`). Integration tests in each crate's `tests/`.
- **Fixture repos** committed at `test-fixtures/repos/` as pre-initialized `.jj/` trees (compressed `.tar.zst`):
  `tiny-3-commits/`, `medium-1k-commits/`, `large-10k-commits/`.
- Fixtures are built by an `xtask gen-fixture` once and committed — never re-built at test time.
- Watcher tests assert functional arrival of events (filesystem mutation → callback fires). Latency assertions are deferred while WIP — NFR-P-4 (`<100ms`) remains a soft target.
- Dart tests boot a real worker isolate; the isolate boundary is not mocked.
- JSON outputs: `insta` snapshot tests in Rust; same JSON validated against committed schemas in both Rust + Dart test suites (correctness backstop — see AD-3).

### P-8: Cargo.toml Hygiene
- Shared deps via `[workspace.dependencies]`; member crates use `serde = { workspace = true }`.
- **Version pins:** explicit `=x.y.z` for load-bearing pre-1.0 deps (`jj-lib`, `rmcp`, `imara-diff`). Caret for stable deps.
- `default-features = false` requires a `# WHY:` comment explaining the rationale.
- No `[patch.crates-io]` in 0.x. Forks need an issue link explaining when they can be dropped.

### P-9: Linter / Formatter Configs
- **Rust:** `rustfmt.toml` at workspace root (`max_width = 100`). `clippy::pedantic` enabled crate-wide; CI runs `cargo clippy -- -D warnings`. Suppressions only at crate root with documented rationale.
- **Dart:** `analysis_options.yaml` based on `package:flutter_lints` + selected `package:very_good_analysis` rules. `dart format` enforced in CI.
- **SPDX license identifier on the first line of every source file:** `// SPDX-License-Identifier: Apache-2.0` for Rust and Dart. Single line, machine-readable, makes the patent-grant visible to anyone reading a file in isolation — the rationale that drove the Apache-2.0 choice (OD-2). Repo-root `LICENSE` is still authoritative; SPDX is the per-file pointer. No full Apache boilerplate. (Decided 2026-05-15, supersedes earlier "no per-file headers" rule.)

### Anti-Patterns

These mistakes would be silently corrosive — they pass review by individual look but break a core architectural invariant.

- **Don't shell out to the `jj` CLI.** All jj access goes through `zanshin-jj` → `jj-lib`. Fixture setup may shell out; production code may not.
- **Don't parse jj CLI output strings.** Structured access is the whole point of the adapter crate.
- **Don't add `extern "C"` functions outside `zanshin-ffi`.** Internal crates stay pure-Rust `lib`.
- **Don't introduce FFI abstractions** (`flutter_rust_bridge`, `flutter_ffi_plugin`, etc.). Decided per the `flutter_rust_bridge` rejection.
- **Don't add upload-on-error logging frameworks** (Sentry, Crashlytics, Firebase, datadog-agent). NFR 5.3.
- **Don't add GPL/AGPL/LGPL/SSPL dependencies.** `cargo-deny` will fail CI; run `cargo deny check licenses` locally before adding deps.
- **Don't regenerate `bindings.dart` or `zanshin_ffi.h` outside `cargo make codegen`.** The CI drift-check (`cargo make verify-codegen`) is deferred while WIP; the discipline rule still applies during development.
- **Don't use `Isolate.run` for repeated work.** Send the work as a command on the existing worker bus.
- **Don't invent alternative envelope shapes or put JSON on the FFI wire.** Faillible functions return the FlatBuffers `Envelope` (AD-1 as amended by ADR-0001); infallible functions return plain types.
- **Don't add per-call locking** (`Arc<Mutex<T>>`, `RwLock`, etc.) around handles. Concurrency model is single-threaded Rust-side (AD-2).

## Project Structure & Boundaries

### Repo Layout Decision

**Cargo workspace at repo root; Flutter package in `app/`.**

Rationale: `cargo make build` is the FR-BO-1 single entry point; the Rust workspace has 7 crates (5 lib + bin + xtask) against one minimal Flutter package; CI scripts run from the Cargo root naturally. The `native_toolchain_rust` default path is overridden in `app/hook/build.dart` via `manifestPath: '../crates/zanshin-ffi/Cargo.toml'` — one line.

### Complete Project Directory Structure

```
zanshin/                                # repo root, Cargo workspace
├── README.md
├── LICENSE                             # Apache-2.0
├── CHANGELOG.md
├── .gitignore
├── .gitattributes                      # binary detection for *.tar.zst fixtures
├── .editorconfig
│
├── Cargo.toml                          # [workspace] declaration, shared deps
├── Cargo.lock                          # committed
├── rust-toolchain.toml                 # pins Rust 1.95.0
├── rustfmt.toml                        # max_width = 100
├── cbindgen.toml                       # P-6 — workspace-level cbindgen config
├── deny.toml                           # cargo-deny: licenses + advisories
├── Makefile.toml                       # cargo-make orchestration (FR-BO-1..4)
├── .cargo/
│   └── config.toml                     # cargo aliases (e.g., `cargo xtask ...`)
│
├── crates/
│   ├── zanshin-jj/                     # FR-JJ-* — jj-lib adapter (lib)
│   │   ├── Cargo.toml
│   │   └── src/
│   │       ├── lib.rs                  # public surface; FR-JJ-16 invariant
│   │       ├── repo.rs                 # FR-JJ-1..3 open/init/clone
│   │       ├── status.rs               # FR-JJ-4
│   │       ├── revset.rs               # FR-JJ-5
│   │       ├── change.rs               # FR-JJ-6
│   │       ├── op_log.rs               # FR-JJ-7, 14
│   │       ├── bookmarks.rs            # FR-JJ-8, 11
│   │       ├── remotes.rs              # FR-JJ-9, 13 (progress callbacks)
│   │       ├── mutate.rs               # FR-JJ-10a/b/c
│   │       ├── conflict.rs             # FR-JJ-12
│   │       └── settings.rs             # FR-JJ-15
│   │
│   ├── zanshin-diff/                   # FR-DF-* — word-level diff (lib)
│   │   ├── Cargo.toml
│   │   └── src/
│   │       ├── lib.rs
│   │       ├── hunks.rs                # FR-DF-1 line-level via jj-lib
│   │       ├── word_diff.rs            # imara-diff Histogram
│   │       ├── highlight.rs            # tree-sitter-highlight
│   │       ├── grammars.rs             # FR-DF-5 Kern-Set 9
│   │       └── output.rs               # FR-DF-3 JSON serialization
│   │
│   ├── zanshin-graph/                  # FR-GR-* — DAG lane-assignment (lib)
│   │   ├── Cargo.toml
│   │   └── src/
│   │       ├── lib.rs
│   │       ├── lane.rs                 # FR-GR-1 algorithm
│   │       ├── cache.rs                # FR-GR-3 full lane-cache on open / op_heads
│   │       ├── slice.rs                # FR-GR-4 render-slice API
│   │       └── output.rs               # FR-GR-2 JSON
│   │
│   ├── zanshin-ffi/                    # FR-FFI-* — single cdylib
│   │   ├── Cargo.toml                  # crate-type = ["cdylib"]
│   │   ├── include/
│   │   │   └── zanshin_ffi.h           # P-6 cbindgen output, COMMITTED
│   │   └── src/                        # P-3 module breakdown
│   │       ├── lib.rs                  # init, panic handler, zanshin_ffi_version (FR-FFI-10)
│   │       ├── envelope.rs             # AD-1/ADR-0001 FlatBuffers Envelope, error code emission (P-4)
│   │       ├── handle.rs               # Box<T> ↔ *mut T, catch_unwind wrapper
│   │       ├── ffi_strings.rs          # CString in/out + zanshin_string_free + zanshin_buffer_free
│   │       ├── repo.rs                 # zanshin_repo_*
│   │       ├── diff.rs                 # zanshin_diff_*
│   │       ├── graph.rs                # zanshin_graph_*
│   │       └── watcher.rs              # FR-FFI-5..7, AD-5 — notify-debouncer-full + dispatch
│   │
│   ├── zanshin-mcp/                    # FR-MCP-* — standalone bin
│   │   ├── Cargo.toml
│   │   └── src/
│   │       ├── main.rs                 # rmcp stdio setup; AD-6 CLI parse
│   │       ├── env.rs                  # --repo arg / CWD walk-up
│   │       ├── tracing_init.rs         # P-5
│   │       └── tools/
│   │           ├── mod.rs              # registry + descriptions (FR-MCP-5 quality gate)
│   │           ├── read.rs             # FR-MCP-3
│   │           └── write.rs            # FR-MCP-4
│   │
│   └── xtask/                          # ad-hoc project tooling (cargo xtask pattern)
│       ├── Cargo.toml
│       └── src/
│           ├── main.rs                 # dispatch
│           └── tasks/
│               ├── gen_fixture.rs      # P-7 fixture generation
│               └── verify_codegen.rs   # P-6 codegen drift check (manual in WIP)
│               # appcast.rs, reproducibility.rs — deferred (release phase)
│
├── app/                                # Flutter macOS package (minimal bootstrap)
│   ├── pubspec.yaml                    # name: zanshin
│   ├── analysis_options.yaml           # P-9 lint config
│   ├── ffigen.yaml                     # P-6 ffigen config
│   ├── lib/
│   │   ├── main.dart                   # minimal — Ralph fills the UI later
│   │   └── src/
│   │       ├── ffi/
│   │       │   ├── bindings.dart       # P-6 ffigen output, COMMITTED
│   │       │   └── envelope.dart       # AD-1/ADR-0001 FlatBuffers envelope reader
│   │       ├── worker/                 # AD-4 worker isolate
│   │       │   ├── isolate.dart        # Isolate.spawn + ports
│   │       │   ├── commands.dart       # sealed WorkerCommand classes
│   │       │   └── correlation.dart    # commandId → Completer<String>
│   │       └── domain/                 # typed result classes (parsed JSON)
│   │           ├── status.dart
│   │           ├── change.dart
│   │           ├── diff.dart
│   │           ├── graph.dart
│   │           └── progress.dart       # progress event payloads
│   ├── hook/
│   │   └── build.dart                  # native_toolchain_rust hook;
│   │                                   # manifestPath: '../crates/zanshin-ffi/Cargo.toml'
│   ├── macos/                          # `flutter create --platforms=macos` output
│   │   ├── Runner.xcodeproj/
│   │   ├── Runner/
│   │   │   ├── AppDelegate.swift
│   │   │   ├── Info.plist              # entitlements, hardened-runtime flags
│   │   │   └── Resources/
│   │   │       └── zanshin-mcp         # ← copied by `cargo make build` from target/ (release phase; WIP runs standalone CLI)
│   │   └── Podfile
│   │   # Sparkle/ — deferred (release phase)
│   ├── test/                           # P-7 Dart unit tests
│   │   ├── ffi/
│   │   ├── worker/
│   │   └── domain/
│   └── integration_test/               # E2E worker tests (real isolate, real cdylib)
│
├── schemas/                            # AD-3, P-2 — single source of truth for wire format
│   ├── README.md                       # how schemas are used in tests + WIP-policy on breaking changes
│   ├── envelope.fbs                    # AD-1/ADR-0001 FlatBuffers Envelope + FfiError + Payload union
│   ├── status.fbs
│   ├── change.fbs
│   ├── op_log.fbs
│   ├── diff.fbs
│   ├── graph.fbs
│   └── progress.fbs                    # progress callback events
│
├── test-fixtures/                      # P-7 — committed, not generated at test time
│   ├── README.md                       # regenerate via `cargo xtask gen-fixture`
│   ├── repos/
│   │   ├── tiny-3-commits.tar.zst
│   │   ├── medium-1k-commits.tar.zst
│   │   └── large-10k-commits.tar.zst
│   ├── diffs/                          # diff input fixtures
│   │   ├── rust-5k-lines.before.in
│   │   └── rust-5k-lines.after.in
│   └── golden/                         # snapshot expected outputs (insta)
│
├── docs/
│   ├── architecture.md                 # → THIS DOCUMENT
│   ├── rust-error-codes.md             # P-4 taxonomy registry (PR-updated)
│   ├── ffi-abi.md                      # how to read cbindgen header + stability rules
│   ├── release-process.md              # codesign/notarize/Sparkle/GH-Releases
│   ├── watchman-setup.md               # what users see on first-run if missing
│   └── adr/                            # optional — ADRs for future delta-decisions
│
├── .github/
│   ├── workflows/
│   │   └── ci.yml                      # build + clippy + fmt + test + dart analyze (release.yml + reproducibility.yml deferred)
│   └── ISSUE_TEMPLATE/
│       ├── bug.md                      # asks for diagnostics-API output
│       └── feature.md
│
# ci/codesign/, sparkle/ — deferred (release phase, alongside release.yml)
│
├── target/                             # gitignored — cargo output
└── app/build/                          # gitignored — flutter output
```

### Architectural Boundaries

**Compile-time boundaries:**

| Boundary | Crossing artefact | Format | Owner |
|---|---|---|---|
| Rust workspace ↔ FFI | `extern "C"` symbols in `zanshin-ffi` | C ABI (cbindgen header) | `crates/zanshin-ffi/include/zanshin_ffi.h` |
| FFI ↔ Dart shell | `dart:ffi` bindings | C ABI via ffigen translation | `app/lib/src/ffi/bindings.dart` |
| Internal crate ↔ internal crate | Plain Rust `pub fn` | Rust API | Crate's `src/lib.rs` |
| `zanshin-mcp` ↔ MCP host | `rmcp` tool surface (JSON-RPC over stdio) | MCP protocol | `crates/zanshin-mcp/src/tools/*` |
| `zanshin-mcp` ↔ jj | Direct `zanshin-jj` Rust API (no FFI) | Rust API | `crates/zanshin-jj/src/lib.rs` |

**Run-time boundaries:**

| Boundary | Channel | Format | Reference |
|---|---|---|---|
| Filesystem ↔ Watcher | `notify-rs` events on `.jj/repo/op_heads/heads/` + `.jj/repo/working_copy/checkout` | Raw fsevents → debounced events | AD-5, FR-FFI-5 |
| Watcher ↔ Dart UI | `NativeCallable.listener` callback delivering a FlatBuffers buffer | `progress.fbs` / `op_heads_changed` event | AD-4, FR-RX-1 |
| Dart UI ↔ Worker isolate | `SendPort` / `ReceivePort` | sealed `WorkerCommand` classes (in) / JSON strings (out) | AD-4 |
| Worker isolate ↔ FFI | direct dart:ffi calls | C ABI | bindings.dart |
| Same-repo concurrency | Filesystem only — no IPC, no locks | `op_heads` mutation is the notification | FR-MCP-9, FR-RX-3 |

**Stability boundaries** (WIP — 0.x — breaking changes allowed; post-1.0 policy open):

1. `extern "C"` ABI of `zanshin-ffi` (the C-header surface) — evolves freely in WIP; callers update.
2. MCP tool surface of `zanshin-mcp` (tool names + parameter schemas + return shapes) — same.
3. FlatBuffers `.fbs` schemas in `schemas/*.fbs` — updated in place; no `_v2` discipline, no in-wire `schema_version` (ADR-0001).

Everything else (internal crate APIs, internal Rust types, Flutter widgets, JSON test fixtures, log formats) is **not** part of any contract.

Post-1.0 the intent is that the three surfaces above become the external SemVer contract, but the exact policy is deferred and will be revisited when the API stabilises.

### Requirements → Structure Mapping (Epic Level)

| Epic | Primary locations | Cross-cuts into |
|---|---|---|
| A — Workspace & Build Foundation | `Cargo.toml`, `Makefile.toml`, `rust-toolchain.toml`, `deny.toml`, `crates/*/Cargo.toml`, `app/pubspec.yaml`, `app/hook/build.dart`, `.github/workflows/ci.yml`, `schemas/README.md` | All — establishes the scaffolding |
| B — `zanshin-jj` Adapter & Read Path | `crates/zanshin-jj/src/{repo,status,revset,change,op_log,bookmarks,remotes}.rs` | `test-fixtures/repos/` |
| C — `zanshin-ffi` & Watcher | `crates/zanshin-ffi/src/{lib,envelope,handle,ffi_strings,repo,watcher}.rs`, `app/lib/src/{ffi,worker}/*.dart` | `schemas/envelope.fbs`, `schemas/progress.fbs`, `docs/rust-error-codes.md`, `docs/ffi-abi.md` |
| D — `zanshin-graph` | `crates/zanshin-graph/src/*.rs`, `crates/zanshin-ffi/src/graph.rs` | `schemas/graph.fbs`, `test-fixtures/repos/large-10k-commits.tar.zst` |
| E — `zanshin-diff` | `crates/zanshin-diff/src/*.rs`, `crates/zanshin-ffi/src/diff.rs` | `schemas/diff.fbs`, `test-fixtures/diffs/` |
| F — Write Path & FFI Exposure | `crates/zanshin-jj/src/{mutate,conflict}.rs`, `crates/zanshin-ffi/src/repo.rs` (write surface) | `schemas/change.fbs` |
| G — `zanshin-mcp` Binary | `crates/zanshin-mcp/src/**` | `app/macos/Runner/Resources/zanshin-mcp` (bundled via `cargo make build`) |
| H — Build Output (WIP) | `Makefile.toml` build target — produces unsigned `.app` for local development. **Deferred to release phase:** codesigning, notarization, Sparkle appcast, GitHub Releases automation, reproducibility CI, Homebrew Cask. | `app/macos/Runner/Info.plist` |

### File Organization Patterns (recap)

- **Configuration files** live at the repo root or in the package they configure. Tool configs (`rustfmt.toml`, `deny.toml`, `cbindgen.toml`) at workspace root. Per-crate `Cargo.toml` inherits from workspace via `[workspace.dependencies]`.
- **Source organization** inside each Rust crate is by noun (`repo.rs`, `diff.rs`, etc.), not by layer.
- **Tests** live alongside the code they test. Rust unit tests inline; integration tests in each crate's `tests/`. Dart tests in `app/test/`. E2E in `app/integration_test/`.
- **Assets:** macOS-specific resources in `app/macos/Runner/Resources/`. `zanshin-mcp` binary is copied here by the build pipeline.
- **Generated artefacts:** committed (`zanshin_ffi.h`, `bindings.dart`, fixture tarballs); `target/` and `app/build/` are gitignored.

### Development Workflow Integration

**Daily development:**
- `cargo make build` from repo root → produces `app/build/macos/Build/Products/Release/Zanshin.app` (unsigned, dev mode).
- `cargo make test` → Rust tests + Dart tests + `cargo-deny advisories + bans`.
- `cargo make codegen` → regenerates `zanshin_ffi.h` and `bindings.dart`; commit the diff in the same PR as the FFI change (drift-gate deferred — discipline rule applies).
- For UI work (Ralph's domain): `cd app && flutter run -d macos` after a successful `cargo make build`.

**Release flow (deferred):**
Codesigning, notarization (`notarytool`), Sparkle appcast generation, GitHub Releases automation, and Homebrew Cask are deferred to the release phase. While WIP, the build output is the unsigned `.app` only.

**CI gating (WIP-minimal):**
- `ci.yml` blocks merge on: `cargo fmt --check`, `cargo clippy -- -D warnings`, `cargo test --workspace`, `dart analyze --fatal-infos --fatal-warnings`, `dart format --set-exit-if-changed`, `flutter test`, `cargo deny check advisories bans`.
- Deferred until release phase: `cargo make verify-codegen` (drift check), `cargo deny check licenses`, `pana`, `mcp-tester` smoke, performance budget tests, reproducibility two-build diff.

## Architecture Validation Results

### Coherence Validation ✅

**Decision Compatibility:** All seven AD decisions and nine P rules cross-reference without conflict.
- AD-1 (FlatBuffers `Envelope`) + AD-3 (`.fbs` wire contract): no in-wire `schema_version` in WIP (ADR-0001).
- AD-2 (single-thread handle ownership) + AD-4 (worker isolate): handles only dereferenced inside the worker; no Arc/Mutex overhead.
- AD-5 (50ms debounce) + NFR-P-4 (<100ms): 50ms headroom.
- AD-6 (single-repo MCP) + FR-MCP-9 (same-repo concurrency): consistent — concurrency lives in the filesystem, not in process state.

**Pattern Consistency:**
- P-1 (`zanshin_<noun>_<verb>`) + P-3 (per-noun module): cbindgen output groups alphabetically.
- P-2 (snake_case JSON) + Rust-idiomatic side: single conversion point in Dart deserialization.
- P-4 (error code taxonomy) + AD-1 (envelope): codes emitted from a single `envelope.rs` location.

**Structure Alignment:** Stability boundaries (FFI ABI, MCP tools, JSON schemas) are each owned by an explicit file. Every epic has a primary-location mapping (see "Requirements → Structure Mapping" table in Project Structure section).

### Requirements Coverage Validation ✅

**Functional (64 FRs across 8 categories):** every FR maps to a concrete module + epic. See "Requirements → Structure Mapping" table.

**Non-Functional:** all eight NFR sections (5.1–5.8) have explicit architectural support. Two NFRs have minor refinements pending (see Gap Analysis).

### Implementation Readiness Validation ✅

- **Decisions:** all binding, non-ambiguous. AD-1 through AD-7 leave no implementation-level interpretation gaps.
- **Structure:** complete tree with per-file purpose. Epic-mapping ties every FR to a location.
- **Patterns:** 9 positive rules (P-1..P-9) + 10 anti-patterns cover the conflict-prone areas (naming, structure, format, communication, process).

### Gap Analysis Results

**Critical:** none. Epic A scaffolding can begin.

**Important (resolve during Epic A/C):**
1. **MCP-binary tracing sink discipline:** P-5 says "no console output in release builds". For `zanshin-mcp` this must be **stricter** — file sink only in **all** build modes, never stderr/stdout, because the binary is spawned via stdio by MCP hosts and stray output corrupts the protocol. Tighten P-5 wording or specify in Epic G.

**Minor (refinements during natural epic touchpoints):**
2. Watcher initialization ordering: explicit "watcher starts before `zanshin_repo_open` returns".
3. MCP-binary minimal smoke: a `zanshin-mcp` "boots + lists tools" smoke test, so the MCP code path doesn't silently rot. Full `mcp-tester` LLM-quality gate is deferred (release phase).

**Deferred to release phase (out of WIP):**
- NFR-P-1 sub-budget allocation (numeric breakdown of the <2s repo-open target).
- Schema-file inventory expansion (`bookmarks`, `remotes`, `revset`, `settings`, `diagnostics`, `watchman_state`).
- `docs/release-process.md` (Sparkle EdDSA key handling, codesign/notarize flow).

### Architecture Completeness Checklist

**Requirements Analysis**
- [x] Project context thoroughly analyzed
- [x] Scale and complexity assessed
- [x] Technical constraints identified
- [x] Cross-cutting concerns mapped

**Architectural Decisions**
- [x] Critical decisions documented with versions
- [x] Technology stack fully specified
- [x] Integration patterns defined
- [x] Performance considerations addressed (framework in place; numeric sub-budget allocation = Important Gap #1)

**Implementation Patterns**
- [x] Naming conventions established
- [x] Structure patterns defined
- [x] Communication patterns specified
- [x] Process patterns documented

**Project Structure**
- [x] Complete directory structure defined
- [x] Component boundaries established
- [x] Integration points mapped
- [x] Requirements to structure mapping complete

### Architecture Readiness Assessment

**Overall Status:** ✅ **READY FOR IMPLEMENTATION**

**Confidence Level:** **high** — the load-bearing FFI, watcher, and build decisions were validated by two upstream workflows (Research + PRD). This architecture layer translates them into code-form consistency. No critical gaps block scaffolding.

**Key Strengths:**
- Pre-validated decisions from Research/PRD/Memory cleanly translated to AD/P rules — no decision fatigue for AI implementation agents.
- Code-quality production-grade from day one: Clippy pedantic, structured errors, `NativeFinalizer` on every handle, schema-validated JSON in tests, no shelling to `jj` CLI. The WIP framing applies to scope/release-readiness, not to per-line code quality.
- Filesystem-as-IPC: eliminates a whole family of potential race conditions between GUI / MCP / CLI consumers.

**Areas for Future Enhancement (release phase or post-0.1):**
- Sub-budget allocation for NFR-P-1.
- Schema-versioning machinery (`schema_version` field, `_v2`-suffix discipline) once the wire format stabilises.
- Codesigning, notarization, Sparkle auto-update, GitHub Releases automation, reproducibility CI (Section 4.7 of PRD — deferred).
- Schema coverage expansion (bookmarks, remotes, revset, settings, diagnostics, watchman_state).
- `zanshin-jj` as a crates.io-publishable library (AD-7 opt-in, post-1.0).
- AST-level diff in `zanshin-diff` (deferred per OD).
- MCP Resources Surface (FR-MCP-6, deferred to 0.2 per OD-10).

### Implementation Handoff

**AI Agent Guidelines:**
- Follow all AD/P decisions exactly as documented. Where alternatives existed, the first-listed form is canonical.
- Use implementation patterns consistently across all components.
- Respect project structure and boundaries — especially the FFI ABI boundary (the only `extern "C"` surface lives in `zanshin-ffi`).
- Refer to this document for all architectural questions. New decisions emerging during implementation are recorded as ADRs in `docs/adr/`.

**First Implementation Priority:**
Epic A — Workspace & Build Foundation. First story: workspace scaffolding via the Initialization Sequence in the "Starter Template Evaluation" section, plus `Makefile.toml` with `build`, `test`, `codegen` targets and CI workflow `ci.yml` running the WIP-minimal gate (clippy + fmt + cargo test + dart analyze + dart format + flutter test + cargo deny advisories/bans). Once green, Epic A is done.
