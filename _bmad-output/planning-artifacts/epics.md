---
stepsCompleted: ['step-01-validate-prerequisites', 'step-02-design-epics', 'step-03-create-stories', 'step-04-wip-scope-rework-2026-05-17']
inputDocuments:
  - _bmad-output/planning-artifacts/prd.md
  - _bmad-output/planning-artifacts/architecture.md
  - _bmad-output/planning-artifacts/research/technical-zanshin-jj-flutter-dart-hooks-mcp-research-2026-05-15.md
project_name: 'Zanshin'
user_name: 'Ralph'
date: '2026-05-15'
last_revised: '2026-05-17'
scope: 'Rust workspace + FFI + MCP + build (unsigned) + minimal Dart bootstrap. Flutter UI explicitly OUT OF SCOPE. Distribution/release pipeline DEFERRED — see PRD § 4.7.'
posture: 'Code quality production-grade from day 1. Scope/release-readiness is WIP — breaking changes between WIP versions are allowed, callers update, no _v2 suffixes, no in-wire schema_version. See feedback-no-mvp-shortcuts in memory.'
---

# Zanshin - Epic Breakdown

## Overview

This document provides the WIP-scoped epic and story breakdown for Zanshin, decomposing the requirements from the PRD and Architecture decisions into implementable stories.

**Scope reminder:** This breakdown covers only the Rust workspace, FFI surface, MCP server binary, WIP build orchestration (producing an unsigned `.app` for local development), and the *minimal* Dart-side bootstrap (worker isolate, command bus, FFI handle management). Flutter UI (widgets, navigation, theming, accessibility, i18n) is Ralph's separate work and explicitly OUT OF SCOPE.

**WIP-scope rework (2026-05-17):** This document was revised to reflect the two-axes clarification — code quality stays production-grade from day 1, scope/release-readiness is treated as WIP. ~70 stories → ~38 stories. Distribution/release pipeline (Epic 8) collapsed to a single "build unsigned `.app`" story; schema-versioning machinery, performance budget enforcement, license-gate, codegen drift CI-gate, and a number of polish/quality stories are deferred. Sections below tagged with **WIP-rework** notes indicate stories that were shrunk or refocused; deleted stories are entirely removed. See the `posture` field in the frontmatter for the underlying directive.

## Requirements Inventory

### Functional Requirements

#### `zanshin-jj` — JJ Adapter Crate (Section 4.1)

- **FR-JJ-1** (P0): Open repository at a given filesystem path; return opaque handle.
- **FR-JJ-2** (P0): Initialize new repository (with optional `--git` backend).
- **FR-JJ-3** (P0): Clone from remote URL (delegates to jj's Git-clone via jj-lib).
- **FR-JJ-4** (P0): Read working-copy status (changed files vs parent).
- **FR-JJ-5** (P0): Resolve revset string → list of change IDs.
- **FR-JJ-6** (P0): Read change metadata: ID, parents, description, author, timestamps, signed-by, conflict-state, anonymous-yes/no.
- **FR-JJ-7** (P0): Read operation log: list of operations with timestamps and command summaries.
- **FR-JJ-8** (P0): List bookmarks (local + remote-tracking) with their target change IDs.
- **FR-JJ-9** (P0): List remotes with URLs.
- **FR-JJ-10a** (P0): Mutating ops — essentials: `describe`, `new`, `edit`, `abandon`. Each goes through jj-lib only — no shelling to `jj` CLI.
- **FR-JJ-10b** (P1, 0.2): Mutating ops — advanced: `split`, `squash`, `rebase`.
- **FR-JJ-10c** (P2): Mutating ops — rare: `duplicate`, `restore`, `backout`.
- **FR-JJ-11** (P1, 0.2): Bookmark ops: create, move, delete, track, untrack, forget.
- **FR-JJ-12** (P0): Conflict ops: report conflict files in a change; call `jj resolve` after external edit.
- **FR-JJ-13** (P0): Remote ops: `git fetch` and `git push` with progress callbacks.
- **FR-JJ-13c** (P1, 0.2): Remote-change poll — `git ls-remote`-style ref advertisement diffed against the view's `<name>@<remote>` targets; read-only, no objects downloaded, no op-log entry. Powers a "something new on `origin`" indicator (Story 9.24).
- **FR-JJ-14a** (P0): Op-log op: `undo`.
- **FR-JJ-14b** (P2): Op-log ops: `op restore`, op-diff.
- **FR-JJ-15** (P1): Settings access: read/write `user.email`, `user.name`, signing key config, defaults.
- **FR-JJ-16** (P0, architectural invariant): Abstraction stability — any jj-lib API change is absorbed inside `zanshin-jj`; the public API of `zanshin-jj` stays stable so the FFI surface doesn't churn.

#### `zanshin-diff` — Diff Engine (Section 4.2)

- **FR-DF-1** (P0): Compute line-level hunks for a change (via jj-lib), then enrich with word-level diff using `imara-diff` (Histogram algorithm).
- **FR-DF-2** (P0): Emit syntax-highlight metadata per token using `tree-sitter-highlight`; language detection from file extension; plain-text fallback.
- **FR-DF-3** (P0): Output structured data (Hunks → lines → segments; each segment has `kind` (Equal / Added / Removed) and optional `syntax_class`), crossing the FFI boundary as **FlatBuffers** (*amended by [ADR-0001](../../docs/adr/0001-ffi-data-transport-flatbuffers.md)*; was "structured JSON").
- **FR-DF-4** (P0): Diff between any two revisions (revset-resolved).
- **FR-DF-5** (P0): Bundled tree-sitter grammars (Kern-Set, ~9): Rust, Dart, TS/JS, Python, Markdown, TOML, YAML, JSON, HTML. Unknown extensions fall back to plain text.

#### `zanshin-graph` — Commit-Graph Lane Assignment (Section 4.3)

- **FR-GR-1** (P0): Compute lane assignment for the full DAG using jj-lib's `default_index` / `dag_walk`. Strategy: "straight branches" (pvigier-style). (*Amended 2026-09-26 (prd.md): the commit-graph view draws the design's layered layout, computed in Dart on the worker isolate (Story 4.11); jj-lib supplies the topology (4.10).*) (*Added 2026-09-28 (prd.md): linear runs can collapse into stack nodes; columns always come from the ungrouped layout (Stories 4.13, 10.17).*)
- **FR-GR-2** (P0): Output structured data (rows with `lane`, `edges_below`, `color_idx`), crossing the FFI boundary as **FlatBuffers** (*amended by [ADR-0001](../../docs/adr/0001-ffi-data-transport-flatbuffers.md)*; was "structured JSON"). (*Amended 2026-09-26 (prd.md): the FFI carries the whole revset's topology as scalar vectors + CSR (Stories 4.10, 4.12); the layout never crosses the FFI (4.11).*)
- **FR-GR-3** (P0): Full lane-cache computed on repo-open and on every `op_heads` change.
- **FR-GR-4** (P0): Render-slice API: given a row range, return the slice in O(slice-size). (*Amended 2026-09-26 (prd.md): row-range windowing is replaced, not built — the complete index-only topology per operation plus lazy content per visible page (Stories 4.10–4.12).*)
- **FR-GR-5** (P0): Performance: 10k-commit repo produces full lane-cache in < 1s (sub-budget of NFR-P-1). (*Amended 2026-09-26 (prd.md): the budget covers the topology call plus the Dart layout (Stories 4.10, 4.11).*)
- **FR-GR-6** (P2): Checkpoint-caching for very large repos (beyond 10k baseline).

#### `zanshin-ffi` — FFI Surface (Section 4.4)

- **FR-FFI-1** (P0): Single cdylib crate that re-exports `extern "C"` API of all internal crates. Dart Hooks build only this crate.
- **FR-FFI-2** (P0): Opaque handle types: repository handle, change-iterator handle, operation handle. Lifetime via `extern "C"` constructor/destructor pairs.
- **FR-FFI-3** (P0): Composite data for complex types crosses the boundary as **FlatBuffers** (single buffer; lone strings stay CString, scalars plain). No C struct mapping. *Amended by [ADR-0001](../../docs/adr/0001-ffi-data-transport-flatbuffers.md) — originally "JSON-serialized data".*
- **FR-FFI-4** (P0): Async signals from Rust to Dart via `NativeCallable.listener` (same mechanism for watcher events and progress notifications).
- **FR-FFI-5** (P0): `notify-rs` watcher subsystem inside `zanshin-ffi`: watches `.jj/repo/op_heads/heads/` (primary) and `.jj/repo/working_copy/checkout` (heartbeat).
- **FR-FFI-6** (P0): Watcher-event latency < 100ms (aligned with NFR-P-4 / FR-RX-1).
- **FR-FFI-7** (P0): Watchman-availability check API: returns installed? configured? `register-snapshot-trigger` set?
- **FR-FFI-8** (P0): Progress callback contract: long-running ops accept a `NativeCallable.listener` and emit `{operation, progress, message}` events.
- **FR-FFI-9** (P0): Error model: every `extern "C"` function returns either success-with-handle or a structured error code + message. No panics across the FFI boundary.
- **FR-FFI-10** (P0): Versioning — `zanshin_ffi_version()` returns build version + git SHA for Dart-side compatibility check.

#### `zanshin-mcp` — MCP Server Binary (Section 4.5)

- **FR-MCP-1** (P0): Standalone Rust binary using `rmcp`. Shares `zanshin-jj` crate (no FFI on MCP side).
- **FR-MCP-2** (P0): Stdio transport. Spawned by MCP hosts.
- **FR-MCP-3** (P0): Read tools: `status`, `log`, `show <rev>`, `diff <rev>`, `op_log`, `bookmarks`, `remotes`.
- **FR-MCP-4** (P0): Write tools: `describe`, `new`, `edit`, `abandon`, `split`, `squash`, `rebase`, `undo`, bookmark CRUD, `git fetch`, `git push`.
- **FR-MCP-5** (P0, quality gate): Tool descriptions accurate enough that LLM hosts pick correctly without trial-and-error. Each tool has one-line description + parameter docs + usage example.
- **FR-MCP-6** (P1, deferred to 0.2 per OD-10): Structured-data resources: revset → JSON.
- **FR-MCP-7** (P0): Bundled inside `Zanshin.app` (`Contents/Resources/zanshin-mcp` or platform-appropriate location). Path documented for MCP-host config.
- **FR-MCP-8** (P0): Standalone usability — `zanshin-mcp` works as a CLI binary independent of the GUI.
- **FR-MCP-9** (P0, architectural): Same-repo concurrency — when GUI and MCP server operate on the same repo, mutations from one are reflected in the other via the filesystem-watcher path. No IPC, no locking.

#### Build Orchestration (Section 4.6)

- **FR-BO-1** (P0): `cargo make build` produces a complete, signed, notarized `.app` bundle in `dist/`. Single command, no manual steps.
- **FR-BO-2** (P0): `cargo make test` runs Rust workspace tests + Dart-bootstrap tests + license compliance check.
- **FR-BO-3** (P0): `cargo make sign` and `cargo make notarize` as separate explicit targets.
- **FR-BO-4** (P0): `cargo make release` orchestrates: build → sign → notarize → assemble Sparkle appcast entry → tag git release → upload to GitHub Releases.
- **FR-BO-5** (P0): Dart Hooks (`native_toolchain_rust`) integrate so `flutter build macos` picks up the Rust artefact correctly.
- **FR-BO-6** (P0): Generated code (`ffigen` output, `cbindgen` headers) is committed. Build does NOT regenerate; separate target `cargo make codegen`.
- **FR-BO-7** (P0): Toolchain pinned: `rust-toolchain.toml` for Rust, Flutter/Dart versions documented at repo root.
- **FR-BO-8** (P0): Reproducibility — two builds of the same SHA on different machines produce byte-identical artefacts (modulo codesignature). Verified by a CI two-build-diff job.

#### Distribution & Release (Section 4.7)

- **FR-DR-1** (P0): Apple Developer ID codesigning of every binary (`.app`, embedded `zanshin-mcp`, Rust dylib). CI does not leak secrets.
- **FR-DR-2** (P0): Notarization via `notarytool`. Build fails if notarization fails. Stapled receipt embedded.
- **FR-DR-3** (P0): Sparkle-based auto-update. Signed appcast (`appcast.xml`) hosted on GitHub Pages (or equivalent), points at GitHub Releases artefacts.
- **FR-DR-4** (P0, privacy): Update check sends no user / repo identifying data. User-Agent only. No analytics.
- **FR-DR-5** (P0): GitHub Releases as primary distribution channel. Tag → CI auto-publishes release with `.app.zip` + (optional) `.dmg` + checksums + appcast update.
- **FR-DR-6** (P2): Homebrew Cask — deferred (OD-5).

#### Reactivity, Cross-Cutting (Section 4.8)

- **FR-RX-1** (P0): `.jj/repo/op_heads/heads/` change → Dart callback fires within < 100ms.
- **FR-RX-2** (P0): External file edit → Watchman → jj auto-snapshot → new op → op_heads change → callback. End-to-end latency < 500ms.
- **FR-RX-3** (P0): MCP-server mutation → same filesystem-mutation path → same callback. GUI consumers see no difference between GUI / MCP / CLI-origin changes.
- **FR-RX-4** (P0): Watcher recovers cleanly from temporary FS disturbances (network drives unmounting, Time Machine snapshots, etc.) without process restart.

### NonFunctional Requirements

#### Performance (Section 5.1)

- **NFR-P-1**: Repo open (incl. full lane-cache, op-log read) for a 10k-commit repo: **< 2s**.
- **NFR-P-2**: `zanshin-graph` render-slice API: O(slice-size), no full-cache scan per call. (*Amended 2026-09-26 (prd.md): no windowing — O(page) moves to the lazy content call; the topology is computed whole, index-only, once per operation.*)
- **NFR-P-3**: `zanshin-diff` output (FlatBuffers per [ADR-0001](../../docs/adr/0001-ffi-data-transport-flatbuffers.md); was JSON) for a 5k-line changed file: **< 500ms**.
- **NFR-P-4**: Watcher latency `op_heads → callback`: **< 100ms** (FR-RX-1).
- **NFR-P-5**: FFI handle create/destroy overhead: **< 1ms** per call.
- **NFR-P-6**: External-edit end-to-end refresh (Watchman → jj-snapshot → callback): **< 500ms** (FR-RX-2).

#### Reliability / Correctness (Section 5.2)

- **NFR-R-1**: No data loss is acceptable. All mutating operations route through jj-lib via `zanshin-jj`. No shelling to `jj` CLI. No string-parsing of jj output.
- **NFR-R-2**: Every Zanshin-initiated mutation must be visible and reversible in `jj op log`, indistinguishably from a CLI-initiated one.
- **NFR-R-3**: Rust panics never cross the FFI boundary — caught and converted to error codes (FR-FFI-9).
- **NFR-R-4**: MCP server failures produce structured MCP error responses, never crash the process.

#### Privacy / Telemetry (Section 5.3)

- **NFR-PRIV-1**: No telemetry. No analytics. No phone-home. Ever.
- **NFR-PRIV-2**: No automatic crash-reporting. Crash logs are local-only (`~/Library/Logs/Zanshin/`); user shares manually.
- **NFR-PRIV-3**: Update check (FR-DR-4) is the only outbound connection. User-Agent only; no identifying payload.
- **NFR-PRIV-4**: No third-party SDKs that contradict the above (Sentry, Crashlytics, Firebase, etc. excluded).

#### Licensing (Section 5.4)

- **NFR-L-1**: Project license — MIT (OD-2; relicensed Apache-2.0 → MIT 2026-06-20).
- **NFR-L-2**: Dependency policy — permissive only (MIT, BSD-2/3, Apache-2.0, MPL-2.0, Unlicense, CC0). Excluded: GPL (any), AGPL, LGPL, SSPL, custom non-OSI licenses.
- **NFR-L-3**: Enforcement — `cargo-deny` (Rust) + `pana` (Dart). CI fails on any forbidden license.

#### Distribution & Update (Section 5.5)

- **NFR-DU-1**: Codesigning — Apple Developer ID Application certificate, stored as encrypted CI secret, never logged.
- **NFR-DU-2**: Notarization — every release passes `notarytool` before publish.
- **NFR-DU-3**: Update mechanism — Sparkle 2.x (OD-3). Appcast signed; auto-update on user confirmation only (no silent installs).
- **NFR-DU-4**: Versioning — SemVer. 0.x pre-1.0; post-1.0 implies API/behaviour stability commitments for `zanshin-ffi` extern "C" API and MCP tool surface.

#### Build & Reproducibility (Section 5.6)

- **NFR-B-1**: One command — `cargo make build`. CI runs the same command.
- **NFR-B-2**: Generated code committed (FR-BO-6).
- **NFR-B-3**: Toolchain pinned (FR-BO-7).
- **NFR-B-4**: Cross-machine reproducibility verified by CI (FR-BO-8).

#### Supportability (Section 5.7)

- **NFR-S-1**: First-run / repo-open — Zanshin detects missing Watchman or missing jj-fsmonitor config and exposes the result via `extern "C"` API (FR-FFI-7).
- **NFR-S-2**: Diagnostics API — `extern "C"` function returns a structured FlatBuffers `Envelope` (*amended by [ADR-0001](../../docs/adr/0001-ffi-data-transport-flatbuffers.md)*; was "structured JSON") with jj-lib version, Watchman version, app version, OS version, repo path summary — clipboard-copyable.
- **NFR-S-3**: Crash on launch produces a local log in `~/Library/Logs/Zanshin/`.

#### Stability of FFI Contract (Section 5.8)

- **NFR-ST-1**: `extern "C"` API of `zanshin-ffi` is the external contract; once 1.0 ships, breaking changes require a major version bump.
- **NFR-ST-2**: jj-lib API churn is absorbed inside `zanshin-jj` (FR-JJ-16). Rest of workspace and FFI surface do not see jj-lib API changes directly.

### Additional Requirements

> Derived from Architecture decisions (AD-1..AD-7), Patterns (P-1..P-9), Anti-Patterns, and Important Gaps.

#### Architectural Decisions (binding)

- **AR-AD-1 (Error Envelope)** — *amended by [ADR-0001](../../docs/adr/0001-ffi-data-transport-flatbuffers.md)*: All faillible FFI functions return a FlatBuffers `Envelope { ok: bool; error: FfiError; data: Payload (union); }` as an owned buffer (`*mut u8` + len, freed via `zanshin_buffer_free`). Lone strings stay CString (`zanshin_string_free`); fixed scalars stay plain. Rust panics caught via `std::panic::catch_unwind` and converted to `error.code = "internal.panic"`.
- **AR-AD-2 (Handle Lifetime)** — *refined by [ADR-0002](../../docs/adr/0002-repository-state-model-warm-loader-reload-per-operation.md)*: Rust owns handles via `Box<T>`; Dart holds raw `*mut c_void` pointers. Lifecycle pairs `zanshin_X_open(...) -> *mut X` / `zanshin_X_close(ptr)`. Dart-side wrappers register `NativeFinalizer`. Single-threaded Rust-side access (no `Arc<Mutex<T>>`). **The repo handle is a warm `Workspace` *loader* + owner of the op-heads watcher — NOT a cache of repo state. Reads re-resolve to the latest operation (`repo_loader().load_at_head()`); they do not trust a long-lived in-memory `ReadonlyRepo`. Ownership / lifecycle / single-thread rules above are unchanged.**
- **AR-AD-3 (Wire Contract)** — *amended by [ADR-0001](../../docs/adr/0001-ffi-data-transport-flatbuffers.md)*: FlatBuffers `.fbs` files at `schemas/*.fbs` are the wire contract; `flatc`-generated accessors are committed on both sides. Typed accessors + the FlatBuffers `Verifier` are the correctness backstop. WIP: breaking changes in place, no in-wire `schema_version`, no `_v2` suffix.
- **AR-AD-4 (Worker Isolate Command Protocol)**: Commands (UI → Worker) are Dart `sealed class WorkerCommand` subclasses sent over `SendPort`. Responses are FlatBuffers byte buffers read via the generated typed accessors (ADR-0001). Correlation via `commandId` (incrementing int) + `Map<int, Completer<String>>`. Async events (watcher, progress) get separate `SendPort` per stream type.
- **AR-AD-5 (Watcher Coalescing & Backpressure)** — *refined by [ADR-0002](../../docs/adr/0002-repository-state-model-warm-loader-reload-per-operation.md)*: Use `notify-debouncer-full` with 50ms debounce window. Single bounded `tokio::mpsc` channel (capacity 256) → `NativeCallable.listener` dispatch. On channel-full: drop-oldest with `tracing::warn!`. Debouncer auto-rescans when watched path disappears/reappears. **The op-heads watcher is also the coherency trigger, not merely a UI notification: comparing the freshly-resolved op-id to the last-seen one is the staleness check. A missed event delays a refresh but cannot produce a silently-stale view, because no authoritative repo state is held.**
- **AR-AD-6 (MCP Server Process Model)**: `zanshin-mcp` is a single-repo process. Repo selected via `--repo <path>` CLI arg or CWD ancestor walk for `.jj/`. No runtime switching; no multi-repo within one process.
- **AR-AD-7 (Workspace Versioning)**: Workspace-wide single version (`[workspace.package] version = "0.1.0"`). External SemVer commitment (post-1.0) on `extern "C"` ABI of `zanshin-ffi` and MCP tool surface — not on internal crate APIs. No crates.io publishing in 0.x.

#### Implementation Patterns (binding)

- **AR-P-1 (FFI Naming)**: All `extern "C"` symbols use prefix `zanshin_` + snake_case, pattern `zanshin_<noun>_<verb>`. Constructor/destructor pairs share noun. Breaking changes append `_v2`, `_v3`.
- **AR-P-2 (Field Naming)** — *amended by [ADR-0001](../../docs/adr/0001-ffi-data-transport-flatbuffers.md)*: `snake_case` in the `.fbs` schemas. `flatc --dart` generates `lowerCamelCase` getters automatically — no `@JsonKey`. Schemas at `schemas/*.fbs` are source of truth.
- **AR-P-3 (Module Structure)**: `zanshin-ffi` layout per architecture document (lib.rs, repo.rs, diff.rs, graph.rs, watcher.rs, envelope.rs, handle.rs, ffi_strings.rs). Internal Rust crates stay pure `lib`. Dart shell layout: `lib/src/{ffi,worker,domain}/`, `hook/build.dart`.
- **AR-P-4 (Error Code Taxonomy)**: `error.code` is dotted lowercase string `<domain>.<reason>` (e.g., `jj.repo_not_found`, `internal.panic`). Registered in `docs/rust-error-codes.md`. Reasons never change after release.
- **AR-P-5 (Tracing / Logging)**: Rust uses `tracing` + `tracing_appender`. Sink: rotating files at `~/Library/Logs/Zanshin/zanshin.log.YYYY-MM-DD`. No console output in release builds. Spans per FFI call. `ZANSHIN_LOG=info` env override.
- **AR-P-5-MCP (MCP tracing discipline — Important Gap #3)**: `zanshin-mcp` MUST sink tracing to file only in **all** build modes, never stderr/stdout, because the binary is spawned via stdio by MCP hosts and stray output corrupts the protocol.
- **AR-P-6 (Generated Code Location)**: `crates/zanshin-ffi/include/zanshin_ffi.h` (cbindgen output, committed); `app/lib/src/ffi/bindings.dart` (ffigen output, committed). Regeneration only via `cargo make codegen`. CI gate `cargo make verify-codegen` re-runs codegen into tmpdir and fails on drift.
- **AR-P-7 (Test Layout)**: Rust unit tests inline; integration tests in each crate's `tests/`. Fixture repos committed at `test-fixtures/repos/` as `.tar.zst` (`tiny-3-commits`, `medium-1k-commits`, `large-10k-commits`), built once via `cargo xtask gen-fixture`. Watcher tests assert event arrival within 200ms. Dart tests boot a real worker isolate. FlatBuffers outputs checked via the generated typed accessors + `Verifier`; `insta` snapshots use a readable projection of the decoded buffer (ADR-0001).
- **AR-P-8 (Cargo.toml Hygiene)**: Shared deps via `[workspace.dependencies]`. Explicit `=x.y.z` pins for load-bearing pre-1.0 deps (`jj-lib`, `rmcp`, `imara-diff`). Caret for stable deps. `default-features = false` requires `# WHY:` comment. No `[patch.crates-io]` in 0.x.
- **AR-P-9 (Linter/Formatter)**: `rustfmt.toml` at workspace root (`max_width = 100`). `clippy::pedantic` crate-wide; CI runs `cargo clippy -- -D warnings`. Dart `analysis_options.yaml` based on `package:flutter_lints` + selected `very_good_analysis` rules. `dart format` enforced. No per-file license headers.

#### Anti-Patterns (banned)

- **AR-AP-1**: Don't shell out to the `jj` CLI from production code. All jj access via `zanshin-jj` → `jj-lib`.
- **AR-AP-2**: Don't parse jj CLI output strings.
- **AR-AP-3**: Don't add `extern "C"` functions outside `zanshin-ffi`. Internal crates stay pure-Rust `lib`.
- **AR-AP-4**: Don't introduce FFI abstractions (`flutter_rust_bridge`, `flutter_ffi_plugin`, etc.).
- **AR-AP-5**: Don't add upload-on-error logging frameworks (Sentry, Crashlytics, Firebase, datadog-agent).
- **AR-AP-6**: Don't add GPL/AGPL/LGPL/SSPL dependencies.
- **AR-AP-7**: Don't regenerate `bindings.dart` or `zanshin_ffi.h` outside `cargo make codegen`.
- **AR-AP-8**: Don't use `Isolate.run` for repeated work — send the work as a command on the existing worker bus.
- **AR-AP-9** — *amended by [ADR-0001](../../docs/adr/0001-ffi-data-transport-flatbuffers.md)*: Don't put JSON on the FFI wire or invent alternative envelope shapes; faillible functions return the FlatBuffers `Envelope`.
- **AR-AP-10**: Don't add per-call locking (`Arc<Mutex<T>>`, `RwLock`) around handles.

#### Important Gaps (resolve during Epic A/C)

- **AR-G-1 (NFR-P-1 sub-budget allocation)**: The < 2s repo-open target needs explicit numeric breakdown per sub-component (jj-lib open, lane-cache, op-log, bootstrap). Define in Epic A or B first story.
- **AR-G-2 (Diagnostics)** — *amended by [ADR-0001](../../docs/adr/0001-ffi-data-transport-flatbuffers.md)*: the FFI diagnostics function returns a FlatBuffers `Envelope` (NFR-S-2). WIP: the shape is small; no dedicated schema beyond the shared `.fbs`.
- **AR-G-4 (Schema inventory expansion)** — *amended by [ADR-0001](../../docs/adr/0001-ffi-data-transport-flatbuffers.md)*: `.fbs` schemas for `bookmarks`, `remotes`, `revset`, `settings`, `diagnostics`, `watchman_state` — added PR-style like `rust-error-codes.md`.
- **AR-G-5 (Watcher init ordering)**: Watcher must start before `zanshin_repo_open` returns.
- **AR-G-6 (Release-process doc)**: `docs/release-process.md` must document Sparkle EdDSA private-key handling in CI + local sign-tests.
- **AR-G-7 (MCP LLM-quality gate enforcement)**: Add `mcp-tester` smoke run as Epic G acceptance criterion.

#### Project Structure Anchors

- Cargo workspace at repo root; Flutter package at `app/`.
- `crates/{zanshin-jj, zanshin-diff, zanshin-graph, zanshin-ffi, zanshin-mcp, xtask}/`.
- `schemas/*.fbs`, `test-fixtures/repos/*.tar.zst`, `docs/{rust-error-codes,ffi-abi,release-process,watchman-setup}.md`.
- CI workflows: `.github/workflows/{ci.yml, release.yml, reproducibility.yml}`.
- Macros / tool configs at repo root: `Cargo.toml`, `rust-toolchain.toml`, `rustfmt.toml`, `cbindgen.toml`, `deny.toml`, `Makefile.toml`, `.cargo/config.toml`.

### UX Design Requirements

> Not applicable. Per PRD §3.2 and `feedback_scaffolding_scope`, Flutter UI is explicitly OUT OF SCOPE. No UX design document exists. The Dart-side bootstrap (worker isolate, FFI handle management, command bus) is the only Dart-side scope and is captured under FR-FFI / AR-AD-4 / AR-P-3.
>
> *Exception 2026-09-26 (Ralph): Epic 10, the commit-graph view, is built by Claude at Ralph's request; the rest of the Flutter UI stays Ralph's.*

### FR Coverage Map

> Every FR from §"Functional Requirements" mapped to its primary epic. Cross-cutting NFRs and AR-* items are addressed in the epic descriptions below.

| FR | Epic | Notes |
|---|---|---|
| FR-JJ-1 | 2 | `zanshin_repo_open` |
| FR-JJ-2 | 2 | `zanshin_repo_init` |
| FR-JJ-3 | 2 | `zanshin_repo_clone` |
| FR-JJ-4 | 2 | working-copy status |
| FR-JJ-5 | 2 | revset resolution |
| FR-JJ-6 | 2 | change metadata read |
| FR-JJ-7 | 2 | op-log read |
| FR-JJ-8 | 2 | bookmarks list (read) |
| FR-JJ-9 | 2 | remotes list (read) |
| FR-JJ-10a | 6 | essentials: describe/new/edit/abandon (P0) |
| FR-JJ-10b | 6 | advanced: split/squash/rebase (P1 — story marked deferred 0.2) |
| FR-JJ-10c | 6 | rare: duplicate/restore/backout (P2 — story marked deferred) |
| FR-JJ-11 | 6 | bookmark CRUD (P1 — story marked deferred 0.2) |
| FR-JJ-12 | 6 | conflict ops + jj resolve |
| FR-JJ-13 | 6 | git fetch/push with progress (mutating) |
| FR-JJ-13c | 9 | remote-change poll: `git ls-remote` diff vs view, read-only, no op-log (Story 9.24, P1) |
| FR-JJ-14a | 6 | op-log undo (P0) |
| FR-JJ-14b | 6 | op restore + op-diff (P2 — story marked deferred) |
| FR-JJ-15 | 6 | settings read/write (P1) |
| FR-JJ-16 | 2 | Adapter-stability invariant established with read path |
| FR-DF-1 | 5 | line hunks → word-level via imara-diff |
| FR-DF-2 | 5 | tree-sitter-highlight syntax classes |
| FR-DF-3 | 5 | structured output, FlatBuffers (ADR-0001) |
| FR-DF-4 | 5 | diff between any two revisions |
| FR-DF-5 | 5 | bundled tree-sitter Kern-Set-9 grammars |
| FR-GR-1 | 4 | lane-assignment algorithm on jj-lib default_index — amended 2026-09-26: the design's layered layout in Dart (4.11); 2026-09-28: commit stacks with fixed columns (4.13) |
| FR-GR-2 | 4 | FlatBuffers output (lane, edges_below, color_idx) — ADR-0001; amended 2026-09-26: topology vectors + CSR (4.10, 4.12) |
| FR-GR-3 | 4 | full lane-cache on open + op_heads change |
| FR-GR-4 | 4 | render-slice API O(slice-size) — amended 2026-09-26: whole-revset topology + lazy content (4.10–4.12) |
| FR-GR-5 | 4 | 10k-commit lane-cache < 1s — amended 2026-09-26: topology call + Dart layout (4.10, 4.11) |
| FR-GR-6 | 4 | checkpoint-caching (P2 — story marked deferred post-0.1) |
| FR-FFI-1 | 1, 3 | cdylib skeleton + re-export wiring (1); substance (3) |
| FR-FFI-2 | 3 | opaque handle types |
| FR-FFI-3 | 3 | FlatBuffers boundary types (ADR-0001) |
| FR-FFI-4 | 3 | NativeCallable.listener for async signals |
| FR-FFI-5 | 3 | notify-rs watcher subsystem |
| FR-FFI-6 | 3 | watcher event latency < 100ms |
| FR-FFI-7 | 3 | Watchman-availability check API |
| FR-FFI-8 | 3 | progress callback contract |
| FR-FFI-9 | 3 | error model, no panic crossings |
| FR-FFI-10 | 3 | zanshin_ffi_version() handshake |
| FR-MCP-1 | 7 | rmcp-based standalone binary |
| FR-MCP-2 | 7 | stdio transport |
| FR-MCP-3 | 7 | read tools |
| FR-MCP-4 | 7 | write tools |
| FR-MCP-5 | 7 | LLM-quality tool descriptions (quality gate) |
| FR-MCP-6 | 7 | resources surface (P1 — story marked deferred 0.2 per OD-10) |
| FR-MCP-7 | 7 | bundled inside Zanshin.app |
| FR-MCP-8 | 7 | standalone CLI usability |
| FR-MCP-9 | 7 | same-repo concurrency (filesystem path) |
| FR-BO-1 | 1 | `cargo make build` produces signed/notarized `.app` (notarize step lit up in Epic 8) |
| FR-BO-2 | 1 | `cargo make test` runs full gate |
| FR-BO-3 | 8 | `cargo make sign` / `cargo make notarize` |
| FR-BO-4 | 8 | `cargo make release` orchestration |
| FR-BO-5 | 1 | Dart Hooks integration |
| FR-BO-6 | 1 | generated code committed; explicit codegen target |
| FR-BO-7 | 1 | toolchain pinned |
| FR-BO-8 | 8 | reproducibility CI (two-build diff) |
| FR-DR-1 | 8 | Apple Developer ID codesigning |
| FR-DR-2 | 8 | notarization via notarytool |
| FR-DR-3 | 8 | Sparkle appcast |
| FR-DR-4 | 8 | update check privacy |
| FR-DR-5 | 8 | GitHub Releases automation |
| FR-DR-6 | 8 | Homebrew Cask (P2 — story marked deferred post-0.1 per OD-5) |
| FR-RX-1 | 3 | op_heads → callback < 100ms |
| FR-RX-2 | 3 | external-edit end-to-end < 500ms |
| FR-RX-3 | 7 | MCP-mutation routing validated through MCP epic |
| FR-RX-4 | 3 | watcher recovery from FS disturbances |

**Coverage check:** all 67 FRs mapped. Eight items are explicitly marked as deferred-story (P1/P2) within their natural epic — they remain in scope as story stubs but are released after 0.1.

## Epic List

> **Sequencing:** Epic 1 → Epic 2 → Epic 3, then Epics 4, 5, 6 parallelizable, then Epic 7, then Epic 8. Epic 3 (FFI Keystone) blocks all downstream epics that need the FFI envelope/handle/watcher patterns.

### Epic 1: Workspace & Build Foundation

**Goal:** Establish a green Cargo workspace + minimal Flutter shell + WIP build/codegen/lint toolchain so every downstream epic begins on a clean foundation.

**User outcome:** A developer (Ralph or CI) can run `cargo make build` from a fresh clone and obtain a buildable (unsigned) `.app` skeleton; `cargo make test` runs the WIP-minimal gate (clippy + fmt + cargo test + dart analyze + dart format + flutter test + `cargo deny check advisories bans`) and is green on empty bindings.

**FRs covered:** FR-FFI-1 (cdylib skeleton + re-export wiring), FR-BO-1, FR-BO-2, FR-BO-5, FR-BO-6, FR-BO-7.

**NFRs:** NFR-L-1, NFR-L-2 (informal), NFR-B-1, NFR-B-2, NFR-B-3.

**Additional requirements anchored here:** AR-AD-7 (workspace versioning), AR-AD-3 (`schemas/` directory; WIP wire-contract — no `_v2` discipline yet), AR-P-3 (module layout for all crates), AR-P-6 (codegen location; manual regen in WIP), AR-P-8 (Cargo.toml hygiene), AR-P-9 (linter/formatter configs).

**WIP-rework:** Schemas-dir versioning README (Story 1.8), full license-gate + pana (Story 1.6 partially), and codegen-drift CI-gate (Story 1.5 partially) are deferred. CI workflow (Story 1.9) shrunk to the WIP-minimal gate.

**Sequencing:** First epic. No predecessors.

---

### Epic 2: `zanshin-jj` Adapter & Read Path

**Goal:** Build the anti-corruption-layer adapter over `jj-lib` with full read-side coverage, so the rest of the workspace and the MCP binary can query a jj repository without ever seeing `jj-lib` types directly.

**User outcome:** A Rust caller (later `zanshin-ffi` and `zanshin-mcp`) can open/init/clone a repo, **detect what kind of repository (if any) lives at a path and convert an existing Git project to colocated jj**, read working-copy status, resolve revsets, read change metadata and op-log, list bookmarks and remotes — all through `zanshin-jj`'s public API. Fixture repos (`tiny`, `medium`) committed and used in tests.

**FRs covered:** FR-JJ-1, FR-JJ-2, FR-JJ-3, FR-JJ-4, FR-JJ-5, FR-JJ-6, FR-JJ-7, FR-JJ-8, FR-JJ-9, FR-JJ-16, FR-JJ-17 (detection), FR-JJ-18a (colocated conversion). FR-JJ-18b (jj-native import: a *separate* jj-native workspace at a chosen destination backed by the source's existing `.git/`, source left standalone — not an in-place convert) is a P1 fast-follow — see Story 2.13.

**NFRs:** None enforced in WIP (NFR-P-1 sub-budget allocation deferred).

**Additional requirements anchored here:** AR-AP-1 + AR-AP-2 enforcement (no shelling, no string-parsing). Fixture-generation via `cargo xtask gen-fixture` lives here (P-7) — tiny + medium only in WIP.

**WIP-rework:** Story 2.2 (NFR-P-1 sub-budget allocation) deleted. Story 2.1 shrunk (large fixture + determinism guarantees deferred). Story 2.10 shrunk to rustdoc on public API (no surface-lock gate — WIP allows breaking changes).

**Sequencing:** After Epic 1. **WIP re-sequencing (2026-06-15):** Epic 2 is now interleaved with Epic 3's FFI infrastructure so the Flutter dev can exercise each read-path noun from Flutter as it lands, instead of waiting for all of Epic 2 to finish. See the re-sequencing banner under the Epic 3 detail section for the authoritative work order.

---

### Epic 3: `zanshin-ffi` & Watcher (Keystone)

**Goal:** Land the load-bearing FFI infrastructure — opaque handles, FlatBuffers envelope (ADR-0001), error model, async event delivery, watcher subsystem, basic diagnostics — plus the minimal Dart-side bootstrap (long-running worker isolate, command bus, `NativeFinalizer`).

**User outcome:** A Dart caller in the worker isolate can open a repo handle through committed `bindings.dart`, receive FlatBuffers-structured read responses (ADR-0001), subscribe to async event streams (op_heads change, external edit, progress), and pull basic diagnostics (version + log-path). No Rust panic ever crosses the FFI boundary. The functional watcher path (`.jj/repo/op_heads/heads/` → callback) is asserted; the `< 100ms` latency target is a soft design goal in WIP.

**FRs covered:** FR-FFI-2, FR-FFI-3, FR-FFI-4, FR-FFI-5, FR-FFI-6 (functional only, no latency assert), FR-FFI-8, FR-FFI-9, FR-FFI-10 (build-stamp; no compat negotiation), FR-RX-1 (functional), FR-RX-2 (functional), FR-RX-4.

**NFRs:** NFR-R-3, NFR-S-3. NFR-P-4, NFR-P-5, NFR-P-6 are soft targets (no CI enforcement). NFR-S-1, NFR-S-2 shrunk (basic diagnostics only).

**Additional requirements anchored here:** AR-AD-1 (envelope — no `schema_version` field in WIP), AR-AD-2 (handle lifetime), AR-AD-3 (first schemas: `envelope.schema.json`, `progress.schema.json`), AR-AD-4 (worker isolate command protocol), AR-AD-5 (debouncer + backpressure), AR-P-1 (FFI naming), AR-P-4 (error code taxonomy), AR-P-5 (tracing/logging), AR-G-5 (watcher init ordering).

**WIP-rework:** Story 3.7 (Watchman availability check, FR-FFI-7) deleted. Story 3.8 (diagnostics) shrunk to version-string + log-path. Story 3.3 (tracing) shrunk (rotation tests + log-cap removed). Story 3.10 latency-assertion removed; functional event-arrival assertion retained; a watcher-storm sub-test (drop-oldest under load) appended.

**Sequencing:** After Epic 1, interleaved with Epic 2 (WIP re-sequencing 2026-06-15). The FFI infrastructure is pulled forward in the order `3.1 → 3.2 → 3.3 → 3.4a → 3.9 → 3.8` to unblock the Flutter dev early; the watcher (Stories 3.5, 3.6, 3.10) is **deferred** — open/init/clone are one-shot operations that need no file-watching, and the watcher rebuilds later with zero rework (the async event sink is process-global in `zanshin_worker_init`, so `zanshin_repo_open`'s signature is unaffected). After Story 3.9, each remaining read wrapper (Story 3.4b) lands as its Epic 2 noun completes. Still blocks downstream epics (4, 5, 6, 7) that consume the envelope/handle/worker patterns.

---

### Epic 4: `zanshin-graph` — DAG Lane Assignment *(2026-10-01: the lane crate was removed in 4.12)*

**Goal:** Compute commit-graph lane assignments for arbitrary jj DAGs and expose them as render-ready FlatBuffers (ADR-0001) via the FFI surface.

**User outcome:** A caller (FFI consumer or test) obtains lane data per request (computed on demand, in-memory) and receives a render-slice response (all lanes for the revset). An algorithmic-correctness test on a ~100-commit fixture catches dumb regressions cheaply.

**FRs covered:** FR-GR-1, FR-GR-2, FR-GR-4 (return-all-lanes form, no windowing; all three amended 2026-09-26 for Stories 4.10–4.12, see the Reopened note below). FR-GR-3 reduced to "compute on demand" — full persistent lane-cache with op_heads-invalidation is deferred. FR-GR-5 (perf budget) is a soft target only.

**NFRs:** None enforced in WIP (NFR-P-1 / NFR-P-2 are soft targets).

**Additional requirements anchored here:** `schemas/graph.schema.json` (no `.v1` infix in WIP).

**WIP-rework:** Story 4.5 (10k-commit perf test) deleted — algorithmic-correctness test on ~100-commit fixture absorbed into Story 4.1. Story 4.7 (P2 checkpoint caching) deleted. Story 4.3 (full lane-cache) shrunk to on-demand in-memory. Story 4.4 (render-slice) shrunk to return-all-lanes-for-revset.

**Sequencing:** After Epic 3. Parallelizable with Epics 5 and 6.

**Reopened (2026-09-26, Ralph — console session on the commit-graph view; re-planned the same day after the layout A/B):** three stories form the backend/bridge half of the commit-graph view (Epic 10, UI). The view draws the HTML design's layered layout, not `jj log`'s one-commit-per-row lanes:
- several commits per row: Compact = generation depth, Time = time buckets, and an experimental Free mode with time-proportional y *(decided 2026-09-27, Ralph, via the spike viewer: the product ships Free, the default, and Compact; Time is dropped. The lane order is `compact`, the default, or greedy; `optimized` is dropped. See Epic 10's "Product decisions 2026-09-27")*;
- greedy interval lane packing and a lane-order optimisation;
- orthogonal edge routing.

The stories:
- **4.10 — topology vs. card content.** A new index-only call returns the whole revset's topology: nodes in `jj log` order, parents with their Direct / Indirect / Missing kinds, the View-derived facts, and, on request for the time-based modes, committer timestamps. A batch content lookup is pinned to that call's operation. `walk_graph` and `zanshin_graph_slice` stay unchanged.
- **4.11 — the Dart layout engine.** The spike's Dart implementation of `spikes/graph-layout-ab/SPEC.md`, ported into `zanshin_core`'s worker isolate, plus the input builder (priority rule, repeated-target rule) and the layout command. Its result reaches the UI isolate as typed data. The spike's dumper becomes the input builder's Rust reference.
- **4.12 — the topology wire.** FlatBuffers scalar vectors + CSR for the whole revset, a lazy Dart view, id → index lookups and at most one copy across isolates. It replaces `zanshin_graph_slice`; whether the pvigier lane path goes with it is its open question.
- **4.13 — commit stacks in the engine** *(added 2026-09-28 with the design update; Epic 10's "Design update 2026-09-28")*. Linear runs of commits collapse into one stack node. Columns always come from the ungrouped layout, so a stack toggle never moves a card sideways; only the rows compact. First in the spike's Dart, then in `zanshin_core` after 4.11's port.

Why:
- **The layout needs the whole revset before the first frame,** but since 4.8 the only graph call loads every commit object inline. Measured 2026-09-26:
  - the index-only topology costs 0.44–0.58 µs per commit;
  - a commit load costs 3.4–4.8 µs in a packed store, but ~122 µs on the loose-object 10k fixture (1.2 s for `all()`);
  - `empty` costs 0.78 ms per merge commit when no changed-path index covers it. On a real 1.4k-commit repo that is 115 ms of the 163 ms today's call takes.
- **Where the layout runs was decided by the A/B spike** (Ralph, 2026-09-26): in Dart. Rust is ~3× faster, 1.2–1.9× once Dart uses monomorphic sorts (outside many-lane `optimized`). But both stay far under a frame at realistic sizes: Dart AOT takes 0.15–0.62 ms for that repo's `all()`. And a Dart layout hot-reloads into the running app.

FR-GR-4 / NFR-P-2 were amended on 2026-09-26: no windowing, but complete geometry plus lazy content. FR-GR-1 / FR-GR-2 / FR-GR-5 carry dated amendment notes that point here. Research: `_bmad-output/planning-artifacts/research/technical-commit-graph-virtualization-research-2026-09-26.md`. Spike: `spikes/graph-layout-ab` (`README.md`, `SPEC.md`).

---

### Epic 5: `zanshin-diff` — Word-Diff + Syntax Highlight

**Goal:** Produce structured diff JSON (hunks → lines → segments) with word-level differentiation (`imara-diff` Histogram) inside changed lines plus tree-sitter syntax classification, served via the FFI surface.

**User outcome:** A caller submits two revisions (or a change) and receives JSON diff output. Syntax classes attach to tokens for an initial 3-grammar subset (Rust, Dart, Markdown); other extensions fall back to plain text. Remaining Kern-Set languages added on demand.

**FRs covered:** FR-DF-1, FR-DF-2, FR-DF-3, FR-DF-4. FR-DF-5 shrunk to 3 grammars (rust, dart, markdown).

**NFRs:** None enforced in WIP (NFR-P-3 is a soft target).

**Additional requirements anchored here:** `schemas/diff.schema.json` (no `.v1` infix in WIP).

**WIP-rework:** Story 5.7 (5k-line perf test) deleted. Story 5.3 (tree-sitter integration) shrunk (fallback strategies + incremental highlighting deferred). Story 5.4 (grammars) shrunk from Kern-Set 9 to 3 grammars.

**Sequencing:** After Epic 3. Parallelizable with Epics 4 and 6.

---

### Epic 6: Write Path & `extern "C"` Mutation Exposure

**Goal:** Add the WIP mutating subset of `zanshin-jj` (describe/new/edit/abandon, undo, fetch-with-progress) and expose it through `zanshin-ffi`. `git fetch` is the real consumer of the FR-FFI-8 progress-callback pattern in WIP.

**User outcome:** A caller (Dart worker, MCP) can safely mutate a repo with the P0 subset: every mutation is visible in `jj op log`. `git fetch` reports progress through the `NativeCallable.listener` channel. A two-thread concurrent-write smoke is appended to the mutation tests (assertions originally planned for Story 7.8).

**FRs covered:** FR-JJ-10a (P0), FR-JJ-13a (P0 — fetch with progress), FR-JJ-14a (P0).

**Deferred (WIP-rework):** FR-JJ-10b, FR-JJ-10c, FR-JJ-11, FR-JJ-12 (conflict ops), FR-JJ-13b (push), FR-JJ-14b, FR-JJ-15.

**NFRs:** NFR-R-1 (no data loss). NFR-R-2 (op-log visibility) is asserted as a code invariant, not as a dedicated test (Story 6.7 deleted).

**Additional requirements anchored here:** `schemas/change.schema.json` extension (in-place edits; no `_v2` discipline in WIP), AR-AP-1 + AR-AP-2 re-asserted on the mutation surface.

**WIP-rework:** Stories 6.3 (conflict ops), 6.7 (op-log visibility test), 6.8–6.12 (deferred advanced/rare mutations + bookmark CRUD + settings + op-restore) all deleted. Story 6.4 → renamed 6.4a, narrowed to `git fetch` with progress (push deferred). Story 6.1 description extended with the two-thread concurrent-write smoke (Szenario-1 from the dropped Story 7.8). Story 6.2 (undo) shrunk to a thin `jj op restore` wrapper. Story 6.6 (schema extension) shrunk (no versioning/migration/compat shims).

**Sequencing:** After Epic 3. Parallelizable with Epics 4 and 5.

---

### Epic 7: `zanshin-mcp` Binary

**Goal:** Build the standalone MCP server binary using `rmcp`, exposing the WIP-subset read + write tools, usable as a standalone CLI.

**User outcome:** An MCP host (Claude Desktop) spawns `zanshin-mcp --repo <path>` (or via CWD walk-up) over stdio and gets a working tool catalog: read tools (`status`, `log`, `show`, `diff`, `op_log`, `bookmarks`, `remotes`) and the WIP write-tool subset (`describe`, `new`). Tool descriptions and parameter docs exist (basic). A minimal "boots + lists tools" smoke prevents code-path rot.

**FRs covered:** FR-MCP-1, FR-MCP-2, FR-MCP-3, FR-MCP-8, FR-MCP-9 (architectural — no dedicated concurrency test in WIP, see Epic 6 mutation smoke).

**Deferred (WIP-rework):** FR-MCP-4 full surface (only `describe` + `new` in WIP), FR-MCP-5 LLM-quality + `mcp-tester` quality-gate (basic descriptions only), FR-MCP-6 (Resources surface, 0.2 per OD-10), FR-MCP-7 (bundling into Zanshin.app).

**NFRs:** NFR-R-4 (structured MCP errors, never crash) — basic mapping only.

**Additional requirements anchored here:** AR-AD-6 (process model), AR-P-5-MCP (file-only tracing in ALL build modes, never stderr/stdout).

**WIP-rework:** Stories 7.5 (LLM-quality + mcp-tester gate), 7.6 (bundle in Zanshin.app), 7.7 (standalone CLI usability polish), 7.8 (dedicated GUI+MCP concurrency test — assertions absorbed into Story 6.1), 7.11 (MCP Resources, deferred to 0.2) all deleted. Story 7.4 (write tools) shrunk to `describe` + `new`. Story 7.9 (mcp-tester smoke) shrunk to a "boots + lists tools" smoke. Story 7.10 (structured errors) shrunk (no taxonomy-stability tests).

**Sequencing:** After Epic 6 (needs the write path) and Epic 2 (needs the read path). Can start as soon as Epics 2 and 6 are done.

---

### Epic 8: Build Output (WIP)

**Goal:** Produce an unsigned, unnotarized `.app` for local development as the WIP build output. The full release pipeline (codesigning, notarization, Sparkle auto-update, GitHub Releases automation, reproducibility CI, Homebrew Cask) is **deferred to the release phase** — see PRD § 4.7.

**User outcome:** `cargo make build` from a fresh clone produces `app/build/macos/Build/Products/Release/Zanshin.app` (unsigned, unnotarized, dev mode) that opens a test repo, exercises the FFI surface, and fires the watcher callback. No release pipeline, no distribution channel, no auto-update.

**FRs covered (WIP):** FR-BO-1 reduced to "unsigned `.app`".

**Deferred to release phase:** FR-BO-3 (sign/notarize targets), FR-BO-4 (release orchestration), FR-BO-8 (reproducibility), FR-DR-1 (codesigning), FR-DR-2 (notarization), FR-DR-3 (Sparkle appcast), FR-DR-4 (update-check privacy), FR-DR-5 (GitHub Releases automation), FR-DR-6 (Homebrew Cask). Plus: AR-G-6 (`docs/release-process.md`), NFR-PRIV-3, NFR-DU-1..4, NFR-B-4.

**NFRs in WIP:** None.

**WIP-rework:** Original Epic 8 (11 stories: codesign infra, sign/notarize targets, notarytool integration, Sparkle EdDSA appcast, GitHub Pages hosting, update-check privacy, release orchestration, GitHub Releases automation, reproducibility CI, release-process.md, Homebrew Cask) collapsed into one story (8.1) for the unsigned build. All 11 originals deleted.

**Sequencing:** Concurrent with Epic 1 (just the build-target definition). No downstream blocking.

---

### Epic 9: jj Operation Surface Build-Out (ADR-0003)

**Goal:** Build the full jj operation surface as typed verb-level operations in `zanshin-jj` (ADR-0003) — beyond Epic 6's WIP-minimal write subset — composing each verb against jj-lib and exposing it via `zanshin-ffi` and (optionally) `zanshin-mcp`. **Supersedes** the deferred Stories 6.8 (squash/split/rebase) and 6.9 (bookmark CRUD); picks up the Epic-6-deferred FR-JJ-10b/10c/11/12/13b/14b/15.

**User outcome:** A caller (Dart worker, MCP) reaches operation parity with the jj CLI's meaningful verbs — every verb a typed, transaction-bounded `zanshin-jj` call; the consumer names the verb, never composes primitives.

**Backed by:** ADR-0003 + the jj-0.42 feasibility map (`research/technical-jj-operation-api-cli-vs-lib-surface-research-2026-06-27.md`) — the authoritative per-operation breakdown (backing jj-lib helper, thickness, typed-API sketch). 69 operations mapped + adversarially verified.

**FRs covered:** FR-JJ-10b, FR-JJ-10c, FR-JJ-11, FR-JJ-12 (conflict ops), FR-JJ-13b (push), FR-JJ-13c (remote-change poll, Story 9.24), FR-JJ-14b, FR-JJ-15 — plus the new operation-support layer (Story 9.1) and `eval_revset` read primitive (Story 9.2).

**Additional requirements anchored here:** AR-AP-1 + AR-AP-2 re-asserted per verb; the transaction boundary stays Rust-side (ADR-0003); each verb's `.fbs` edited in place (no `_v2`, WIP).

**Precedence / scope:** **Post-WIP-minimal build-out — scheduling is Ralph's call.** Stories are at backlog granularity; full acceptance criteria are authored per story (via bmad-create-story) when scheduled. Each verb follows the surfacing chain: `.fbs` → `zanshin-jj` typed op (tx Rust-side) → `zanshin-ffi` `extern "C"` + `cargo make codegen` → Dart `WorkerCommand` → optional MCP tool → tests (zanshin-jj integration + FFI-path Dart test for coverage attribution + Verifier + ratchet).

**Sequencing:** Step 9.0 (pin bump 0.41→0.42) precedes all operation work; Story 9.1 (operation-support layer) unblocks Tier C. Then Tier A (cheap) → Tier B (medium) → Tier C (thick) by feasibility-map thickness. Reuses Epic 6's `mutate.rs` (6.1) + FFI mutation surface (6.5) patterns; the interactive thick verbs additionally need the Flutter diff/merge editor (Ralph's UI scope) to supply a selected `TreeId`.

---

### Epic 10: Commit-Graph View (Flutter UI)

**Goal:** Build the app's main view from the 2026-09-26 HTML design export: `_bmad-output/implementation-artifacts/design/JJ Desktop Client.html`, with sources `graph-view.jsx`, `graph-data.js`, `graph.css`, `app.jsx` and `styles.css`. The export is preliminary but close to final, and it supersedes Ralph's earlier mockup image. The view is the commit graph plus its toolbar, a thin detail panel, a thin bookmark panel and placeholder action popups. It sits on the shipped bridge and on backend Stories 4.10–4.12. The graph:
- commit cards at positions computed from data, several per row: Compact rows = dependency depth; Time rows = time buckets with a sticky time gutter *(2026-09-27: Free, with a sticky day gutter, replaces Time and is the default; "Product decisions 2026-09-27" below)*; a dot-grid canvas;
- rounded orthogonal edges behind the cards:
  - straight, merge, and branch-off with shared buses;
  - dashed indirect edges;
  - crossing hops;
  - the "~ N elided" marker *(2026-09-30: a `//` marker on every dashed edge and a "~ elided" end stub, without counts; Story 10.19)*;
  - the gold lineage of @ and a hover focus path;
- two-axis scrolling, pan-by-drag and exact scrollbars over 10k–100k commits.

**User outcome:** A user opens a repository and sees the commits of `jj log` (their effective `revsets.log`) or of `all()`. They can:
- switch between Compact and Time *(2026-09-27: Free, the default, and Compact)*, and change card detail and width;
- pan and scroll smoothly;
- hover a card to see its ancestry, click it for details, and double-click it to `jj edit`;
- run describe, new, abandon and bookmark create/delete from the cards and the panel.

Squash, rebase, bookmark rename/move and drag-and-drop follow when their backend verbs land. When jj re-derives the graph after an operation (Zanshin's own or an external `jj`), the view stays anchored on the same commit.

**Backed by:**
- The design export above. Every story cites it by file:line.
- `research/technical-commit-graph-virtualization-research-2026-09-26.md` §1–§5: the viewport mechanics and the §5 pitfalls. They are adapted to several cards per row and to per-node y. The §1 "Nachtrag" recommended keeping `jj log` order; the design did not follow it and reorders and packs rows instead.
- The POC at `app/lib/src/features/graph_poc/` + `app/lib/main4.dart`.
- The A/B spike `spikes/graph-layout-ab` (`SPEC.md`): the design's algorithm made scalable and deterministic, in three modes (`compact`, `time`, `free`). Its reference outputs are Epic 10's recorded layouts until 4.11 ships. It also settled where 4.11 runs: in Dart, on `zanshin_core`'s worker isolate, with Rust supplying the jj data (Ralph, 2026-09-26; spike README "Recommendation" and "Review 2026-09-26").
- Backend:
  - Story 4.10: the whole revset's index-only topology (timestamps on request) vs. lazy, op-pinned content. The topology includes jj's Missing edges, which draw the elided marker.
  - Story 4.11: the layout engine in all three modes, in Dart on the worker isolate: rows, columns, route shapes and buckets *(2026-09-27: the product needs `free` and `compact` only)*.
  - Story 4.12: the topology wire and the lazy Dart view.
  - Story 4.13 *(added 2026-09-28)*: commit stacks in the engine, with the columns of the ungrouped layout.

  Epic 10 consumes an abstract `GraphLayout`; 10.12 backs it with 4.11's layout result and 4.12's topology view.

**Time layout is an experiment.** Ralph wants commits made at about the same time on parallel branches drawn at the same height, so that both order and time distance are visible. He has not decided between fixed rows (the design) and a free layout whose vertical spacing follows elapsed time.
- 10.1's contract carries every mode's rows in units of 1/U pitch, the spike's output format. The engine's `free` layout is therefore the same pixel mapping as the design's rows.
- The one view-side variant, time-sized gaps between Time buckets, is a swappable `VerticalLayout`.
- Story 10.13 compares the variants on real data and decides which modes the product exposes.
- 10.13 does not gate 4.11, which is asked to carry all three modes. *(2026-09-27: 4.11's dated note proposes porting only `free` and `compact`.)*
- Every time-based variant needs every commit's timestamp before layout. 4.10 carries them in the topology call on request (a commit-id cache is its open question 1).

**Product decisions 2026-09-27** (Ralph, console session, after using the spike viewer on a real 1.4k-commit repo; details in the Epic 10 header below):
- **Layout modes:** Free is the default, Compact the only other mode. Time and Time+gaps are dropped, so the experiment above is decided: free y. Free keeps the day axis in the gutter. Every default layout therefore needs every timestamp.
- **Lane order:** `compact` is the default, greedy the alternative. `optimized` (the design's "Min. crossings", its default) is dropped.
- **Intended deviations from the design:** crossing gaps are always on (no Plain, no toggle); content fades as it scrolls under the gutter; the current date stays pinned in the gutter; every edge leaves a card's top at the centre, branch-offs included; a commit found by go-to-change pulses (added 2026-09-27, 10.6 item 12).
- **Label language:** the localisable labels stay for now, English by default as in the design. Whether the app is English-only or translated is open.
- 10.13's outcome is these decisions. *(Not Ralph's decision: the story is closed as done on that outcome, Claude's call; its item 6 leaves a Flutter confirmation to Ralph.)*

**Design update 2026-09-28** (Ralph, console session; the export at `a399daf`; details in the Epic 10 header below):
- **What the export adds:** a callout beside a hovered card (full subject, description, ids, author, date), quick actions and the "add bookmark" button shown only on hover, the bookmark popover beside the card, and **commit stacks**: linear runs collapse into one card with a hover popover of its members, a click expands them, a bracket collapses them, and a toolbar switch "Group stacks" turns the grouping on or off.
- **Decided:** a stack toggle never moves a column; the design re-packs the lanes, which Ralph finds irritating. The graph may compact vertically. The callout's file and line stats are not planned. The design is inspiration, not a 1:1 template: small deviations are expected, and FINAL means the intended direction.
- **New stories:** 4.13 (stacks in the engine) and 10.17 (stacks in the view). The callouts go into 10.6, 10.3 and 10.15; the drag-and-drop hint (cards and bookmarks will be draggable) into 10.10.

**Design update 2026-09-30** (Ralph, console session; the export at `e243dd2`; details in the Epic 10 header below):
- **What the export adds:** a study of hidden history (`Graph Gaps Study.html`). It has three marker families for a gap on a dashed edge and for the end of history, a hover callout that explains a gap and offers "Show in all()", and a toolbar legend "N gaps". The sample data gains the gap cases (52 commits). An animation playground (`Animation Show Case.html`) tunes two animations: a stack unfolding and folding, and a tree change after an operation.
- **Decided:**
  - marker family B (`//`), and no counts of hidden commits;
  - a marker's centre keeps 24 px from every card, bend, crossing, junction and other marker;
  - Ralph's animation values: stacks in 250 ms without stagger; tree changes drawn at 1.8 px/ms, fading out over 600 ms with a 16 px blur and a 16 px rise;
  - Ralph's line-behind-card finding is the Time layout's defect 3; it cannot occur in Free or Compact.
- **New stories:** 10.19 (hidden history: markers, end stubs, the gap callout, the legend, "Show in all()") and 10.20 (graph animations). 10.19 takes over 10.4's elided marker. Earlier stories keep the doors open for 10.20, and 10.17 drops its fade.

**FRs covered:** none formally. PRD §3.2 keeps the Flutter UI out of the PRD, and there is no UX document (§ UX Design Requirements). The epic consumes:
- FR-GR-4 and NFR-P-2 as amended 2026-09-26: complete geometry plus lazy content;
- Story 4.11's layout, not FR-GR-1 / FR-GR-2. Those two describe the `jj log` lane model (pvigier lanes; rows with `lane`, `edges_below`, `color_idx`) that the view no longer draws; both carry a dated amendment (2026-09-26) that points at 4.10–4.12;
- FR-RX-1 (op_heads → refresh);
- FR-JJ-8 (bookmarks), FR-JJ-10a and FR-JJ-14a (the shipped mutations and undo), and Story 9.6's `show`.

The epic follows the pass-through rule (`project-context.md:202`; FR-JJ-17 as Epic 9 uses it): CLI parameters are pre-filled from the effective config and passed explicitly, never baked in. The layered layout is presentation. What the view shows (which commits and edges, @, bookmarks) and every verb stay CLI-exact.

**Scope note:** This epic is a dated exception to "the Flutter UI is Ralph's" (PRD §3.2; `project-context.md`; `CLAUDE.md`). Story 10.0 recorded it (done). Ralph reviews every story, and the rest of the UI stays his. The design's dialogs, popups and panels are not final. So the card popups (10.15), the detail panel (10.8) and the bookmark panel (10.14) are thin placeholders, unless Ralph exempts one of the panels. *(2026-09-28: the hover callouts of the design update are interaction, not decoration, so their mechanism is built for real: the commit callout (10.6) and the stack popover (10.17). The bookmark popover stays a placeholder apart from its hover opening and its position (10.15).)*

**Sequencing:**
- 10.0 is done. 10.1 comes first: the viewport, `GraphLayout`, the vertical mapping, the recorded layouts from the spike and the demo host.
- 10.2, 10.3 and 10.4 run in parallel on recorded layouts.
- 10.5 can land any time after 10.1. It also declares the ports later stories use: the layout source and the actions runner.
- 10.13 (the Time-layout lab) follows 10.1, 10.4 and the spike's stages 2–3. It does not gate 4.11. The throwaway viewer inside the spike was built on 2026-09-26; Ralph currently leans to Free (tentative). *Outcome decided 2026-09-27 in the spike viewer (Free by default, plus Compact); a Flutter lab is built only if Ralph asks for one (10.13 item 6).*
- 10.6 follows 10.3 and 10.4.
- 10.7 follows 10.2, 10.3, 10.5 and 10.6.
- 10.8 follows 10.5 and 10.6.
- 10.9 follows 10.3 and 10.5. Until it lands, 10.6's double-click and 10.8's action row run on a fake actions port.
- 10.15 follows 10.8 and 10.9.
- 10.14 follows 10.5, 10.6 and 10.7. Its full row set needs 9.29.
- 10.11 follows 10.3 and 10.5 on the fake port.
- 10.12 follows Stories 4.10, 4.11 and 4.12, and brings real data.
- 10.16 (minimap) follows 10.1, 10.4, 10.5 and 10.6. On its recommended raster path (an app-side `Isolate.run`, its design question (f)) it needs no backend story.
- 10.17 (commit stacks, added 2026-09-28) follows 10.1, 10.3, 10.5 and 10.6, on the spike's stack recordings from 4.13's spike step. Real stacks come with 10.12 plus 4.13.
- 10.18 (AI stack titles, added 2026-09-28) is an idea Ralph has not decided on. If it is built, it follows 10.17 and 10.11.
- 10.19 (hidden history, added 2026-09-30) follows 10.4, 10.5, 10.6 and 10.7, on recordings of the `e243dd2` sample. Real gaps come with 10.12.
- 10.20 (graph animations, added 2026-09-30) follows 10.1, 10.3, 10.4, 10.5 and 10.17. Real triggers come with 10.9 and 10.12.
- 10.10 comes last. It is a placeholder that needs 9.31 and 9.16.

---

### Cross-Cutting Concerns (no dedicated epic)

These are reviewed in every epic's acceptance criteria rather than implemented once:

- **NFR-R-1, NFR-R-2** — no data loss, every mutation visible/reversible in op log. Review gate in Epics 2, 6, 7.
- **NFR-PRIV-1, NFR-PRIV-2, NFR-PRIV-4** — no telemetry, no third-party analytics SDKs. Code-review gate in every epic.
- **NFR-ST-1, NFR-ST-2** — FFI-contract stability. Inactive in WIP (0.x); breaking changes allowed. Review gate when release-phase begins.
- **AR-P-2** (snake_case JSON), **AR-P-7** (test layout), **AR-AP-3..AP-10** — enforced by tool configs and lint/CI gates set up in Epic 1; passive thereafter.

> **Sequencing recap (WIP):** Epic 1 → Epic 2 → Epic 3, then Epics 4, 5, 6 parallelizable, then Epic 7. Epic 8 is concurrent with Epic 1 (just the unsigned build target). Epic 3 (FFI Keystone) blocks all downstream epics that need the FFI envelope/handle/watcher patterns. Epic 9 (the ADR-0003 operation build-out) follows Epic 6 and is post-WIP-minimal (scheduling TBD). **2026-09-26:** Epic 4 is reopened for Stories 4.10–4.12 (topology/content split, the Dart layout engine on the worker isolate, the topology wire); Epic 10 (the commit-graph view — Flutter UI built by Claude at Ralph's request) runs 10.1–10.4 on fake data and adopts 4.10–4.12 in 10.11 / 10.12. **2026-09-28:** the design update adds Story 4.13 (commit stacks in the engine) and Story 10.17 (commit stacks in the view). **2026-09-30:** the gaps study and the animation showcase add Stories 10.19 (hidden history) and 10.20 (graph animations).

---

## Epic 1: Workspace & Build Foundation

Establish the Cargo workspace, the Flutter macOS package, the build orchestration, the codegen toolchain, the license-compliance gates, and a green CI baseline. After this epic, every downstream epic begins on a clean, reproducible foundation; `cargo make build` and `cargo make test` work end-to-end on empty bindings.

### Story 1.1: Initialize Cargo workspace and create empty crate skeletons

As a developer setting up the Zanshin project,
I want a Cargo workspace at the repo root with all six initial crates (`zanshin-jj`, `zanshin-diff`, `zanshin-graph`, `zanshin-ffi`, `zanshin-mcp`, `xtask`) created as compilable empty skeletons,
So that subsequent epics can implement crate contents against an already-wired workspace structure without further scaffolding overhead.

**Acceptance Criteria:**

**Given** a clean working directory at the repo root
**When** the initialization sequence from Architecture §"Starter Template Evaluation" is executed (`cargo new --lib` for the five libs, `cargo new --bin` for `zanshin-mcp`, `cargo new --lib xtask`)
**Then** six member directories exist under `crates/` (`zanshin-jj`, `zanshin-diff`, `zanshin-graph`, `zanshin-ffi`, `zanshin-mcp`, `xtask`)
**And** the root `Cargo.toml` declares `[workspace]` with `members = ["crates/*"]` and `resolver = "2"`
**And** `cargo build --workspace` exits 0 with no warnings.

**Given** the `zanshin-ffi` crate
**When** its `Cargo.toml` is inspected
**Then** `[lib] crate-type = ["cdylib"]` is set explicitly
**And** the lib `name` is set to `zanshin_ffi` (snake_case) so the resulting artefact is `libzanshin_ffi.dylib` on macOS.

**Given** the root `Cargo.toml`
**When** the `[workspace.package]` table is inspected
**Then** `version = "0.1.0"`, `edition = "2021"`, `license = "MIT"`, `repository`, and `authors` are set at workspace level (per AR-AD-7)
**And** every member crate's `Cargo.toml` inherits via `package.version.workspace = true`, `package.edition.workspace = true`, `package.license.workspace = true`.

**Given** the `[workspace.dependencies]` table
**When** load-bearing pre-1.0 deps need to land in subsequent stories
**Then** the convention is documented in `crates/README.md` (or root `README.md`) requiring `=x.y.z` pins for pre-1.0 deps and `# WHY:` comments for `default-features = false` (per AR-P-8).

**Given** each crate's `src/lib.rs` (or `src/main.rs`)
**When** it is compiled
**Then** it contains only a single placeholder doc-comment plus an empty module/main entry — no functions, no `pub use` re-exports, no extern declarations yet
**And** `cargo doc --workspace --no-deps` completes without warnings.

**Given** the `xtask` crate
**When** inspected
**Then** its `Cargo.toml` has `[[bin]] name = "xtask"` and a `.cargo/config.toml` at the workspace root maps the alias `cargo xtask = "run --package xtask --"` (per `cargo xtask` convention).

**Given** the workspace is initialized
**When** `cargo metadata --format-version 1` is invoked
**Then** every listed crate has `manifest_path` under `crates/`
**And** no crate has an unexpected dependency.

**Given** the `.gitignore` at repo root
**When** inspected
**Then** it lists `target/`, `app/build/`, `.dart_tool/`, `app/.flutter-plugins*`, `*.swp`, `.DS_Store` (macOS), and CI-only secrets directories.

**Edge cases:**

**Given** the workspace is created on a case-insensitive filesystem (default macOS APFS)
**When** any crate name differs only in case from another
**Then** the build fails — names are unique case-insensitively.

**Given** the workspace is on a system with Rust < 1.95.0
**When** `cargo build --workspace` runs (without the toolchain pin from Story 1.3)
**Then** the build may succeed but the developer warning in `crates/README.md` instructs to install Rust 1.95.0 (Story 1.3 will enforce this).

---

### Story 1.2: Initialize Flutter macOS package with Dart Hooks wiring

As a developer setting up the Dart/Flutter side,
I want a Flutter macOS-only package at `app/` with the `native_toolchain_rust` Dart Hook wired to build `zanshin-ffi`,
So that running `flutter build macos` picks up the Rust cdylib correctly via Dart Hooks and bundles it into the `.app`.

**Acceptance Criteria:**

**Given** the repo root with the Cargo workspace from Story 1.1
**When** `flutter create --platforms=macos --org=de.dasralph --project-name=zanshin app` is run
**Then** the `app/` directory contains `pubspec.yaml`, `macos/Runner.xcodeproj/`, `macos/Runner/`, `lib/main.dart`, and `test/`
**And** no other platform directories (`ios/`, `android/`, `windows/`, `linux/`, `web/`) exist.

**Given** `app/pubspec.yaml`
**When** inspected
**Then** `name: zanshin`, `version: 0.1.0`, `environment.sdk: "^3.13.0-104.0.dev"`, `environment.flutter: "^3.44.0-1.0.pre-573"` are set (Flutter/Dart `main` channel — required for multi-window APIs)
**And** `dependencies` includes only the Dart SDK + `flutter` SDK at this stage (no third-party deps yet — added in later stories).

**Given** `app/pubspec.yaml`
**When** `dart pub add native_toolchain_rust hooks` is run and `dart pub add --dev ffigen` is run
**Then** these packages appear in `dependencies` and `dev_dependencies` respectively
**And** the version of `native_toolchain_rust` is exactly `=1.0.4` (per Architecture §"Library dependencies").

**Given** the workspace path layout (Cargo workspace at root, Flutter package at `app/`)
**When** `app/hook/build.dart` is created with the `native_toolchain_rust` `RustBuilder` invocation
**Then** the hook explicitly sets `manifestPath: '../crates/zanshin-ffi/Cargo.toml'` so the hook reaches outside `app/` to the Cargo workspace
**And** `app/hook/build.dart` is the only Dart Hooks file (no separate `link.dart` for static-linking — cdylib only).

**Given** the Flutter macOS Runner project at `app/macos/Runner.xcodeproj/`
**When** opened
**Then** the `Runner` target's `Info.plist` has hardened-runtime entitlements declared (placeholder values — populated for real in Epic 8)
**And** the deployment target is set to a macOS version compatible with current Apple toolchain (macOS 12+ at minimum).

**Given** the Flutter package is initialized
**When** `cd app && flutter pub get && flutter build macos --debug` is run
**Then** the build succeeds (even with empty `bindings.dart` — added in Story 1.5)
**And** the `app/build/macos/Build/Products/Debug/zanshin.app/Contents/Frameworks/libzanshin_ffi.dylib` artefact exists (the Hook copied it from the Cargo build output).

**Given** `app/lib/main.dart`
**When** inspected
**Then** it contains only `void main() { runApp(const SizedBox.shrink()); }` (or equivalent minimal stub) — no widgets, no UI, no MaterialApp
**And** comments explicitly state that UI is OUT OF SCOPE (per `feedback_scaffolding_scope`).

**Given** the package is initialized
**When** the `.gitignore` at repo root is inspected
**Then** `app/.dart_tool/`, `app/.flutter-plugins`, `app/.flutter-plugins-dependencies`, `app/build/`, `app/macos/Flutter/ephemeral/`, `app/macos/Podfile.lock` are gitignored.

**Edge case — Pods:**

**Given** Flutter's macOS shell uses CocoaPods
**When** `flutter pub get` runs for the first time
**Then** `app/macos/Podfile` is generated
**And** the Podfile uses platform `:osx, '12.0'` at minimum.

**Edge case — Hook fails:**

**Given** the Cargo workspace from Story 1.1 cannot be reached (e.g., `manifestPath` typo)
**When** `flutter build macos` runs
**Then** the build fails with a clear error message naming the missing path
**And** the hook does not silently fall back to building nothing.

---

### Story 1.3: Pin Rust toolchain and document Flutter/Dart pins

As a developer ensuring reproducible builds,
I want the Rust toolchain pinned via `rust-toolchain.toml` and the Flutter/Dart versions explicitly documented at the repo root,
So that CI and every contributor build with the exact same toolchain and reproducibility (FR-BO-8) is achievable.

**Acceptance Criteria:**

**Given** the repo root
**When** `rust-toolchain.toml` is created
**Then** its contents are exactly:
```toml
[toolchain]
channel = "1.95.0"
components = ["rustfmt", "clippy", "rust-src"]
targets = ["aarch64-apple-darwin", "x86_64-apple-darwin"]
profile = "minimal"
```
**And** committing this file means a developer running `rustup show` from the repo root sees `active toolchain: 1.95.0-aarch64-apple-darwin (overridden by '$REPO/rust-toolchain.toml')`.

**Given** `README.md` at the repo root
**When** inspected
**Then** a "Toolchain" section documents the exact pins: Rust `1.95.0` (auto-pinned), Flutter `main` channel ≥ `3.44.0-1.0.pre-573`, Dart `main` channel ≥ `3.13.0-104.0.dev` (manual install — no FVM)
**And** the section links to `https://flutter.dev/docs/get-started/install` and `https://rustup.rs` for installation instructions.

**Given** the README "Toolchain" section
**When** read
**Then** it explicitly states "No FVM. Install Flutter `main` channel ≥ `3.44.0-1.0.pre-573` system-wide" (per Architecture §"Library dependencies")
**And** it explains why pinning matters (reproducibility, byte-identical artefacts modulo signature).

**Given** the toolchain pin is in place
**When** `cargo build --workspace` runs on a fresh machine after `rustup install` of the pinned version
**Then** the build succeeds without prompting for a toolchain upgrade.

**Given** a CI workflow file (placeholder for Story 1.9)
**When** the CI runs on `ubuntu-latest` or `macos-latest`
**Then** the workflow's "Setup Rust" step uses `actions/checkout@v4` followed by either `dtolnay/rust-toolchain@stable` (reading `rust-toolchain.toml`) or equivalent — no hardcoded Rust version in YAML.

**Given** a Flutter SDK is required by CI
**When** Story 1.9's CI workflow setup runs
**Then** it explicitly invokes `subosito/flutter-action@v2` with `channel: 'master'` (the action's name for Flutter's `main` channel) and the exact `flutter-version` from `app/pubspec.yaml` (currently `3.44.0-1.0.pre-573`).

**Edge cases:**

**Given** a developer has a newer Rust installed (e.g., 1.97.0)
**When** they `cd` into the repo and run `cargo build`
**Then** `rustup` automatically uses 1.95.0 (per `rust-toolchain.toml`) — no manual override needed.

**Given** a developer has no Rust installed
**When** they `cd` into the repo and run `cargo build`
**Then** `rustup` installs 1.95.0 automatically (it's a `rustup`-managed feature)
**And** the README documents this auto-install behaviour.

**Given** a contributor wants to upgrade the Rust pin
**When** they edit `rust-toolchain.toml` to bump the channel
**Then** the change requires a PR with a `# WHY:` rationale comment in the commit message
**And** the reproducibility CI workflow (Epic 8) re-validates byte-identical artefacts on the new toolchain before merge.

---

### Story 1.4: Author `Makefile.toml` with build / test / codegen targets

As a developer or CI runner,
I want a `cargo-make` `Makefile.toml` at the repo root with the canonical targets (`build`, `test`, `codegen`, `verify-codegen`),
So that every developer and CI runs the same single-command entry points, and FR-BO-1 / FR-BO-2 are satisfied.

**Acceptance Criteria:**

**Given** the repo root
**When** `Makefile.toml` is created
**Then** it contains at minimum these tasks: `build` (cargo + flutter), `test` (workspace + dart + license + codegen-drift), `codegen` (cbindgen + ffigen), `verify-codegen` (re-run codegen into tmpdir and diff), `clean` (cargo clean + flutter clean)
**And** each task has a one-line `description = "..."` for `cargo make --list` discoverability.

**Given** `cargo-make` is installed (`cargo install cargo-make`)
**When** `cargo make build` is run from the repo root
**Then** it executes in order:
1. `cargo build --workspace --release` (or `--profile dev` if `CARGO_MAKE_PROFILE=dev`)
2. `flutter build macos` (in `app/`, default `--release`)
3. Post-build copy of `target/release/zanshin-mcp` into `app/build/macos/Build/Products/Release/zanshin.app/Contents/Resources/zanshin-mcp` (FR-MCP-7 — skeleton wiring only; full bundling acceptance owned by Story 7.6)
**And** the final artefact is at `app/build/macos/Build/Products/Release/zanshin.app`.

**Given** `cargo make test` is run
**Then** it executes:
1. `cargo test --workspace`
2. `cargo clippy --workspace --all-targets -- -D warnings`
3. `cargo fmt --all --check`
4. `cd app && flutter test`
5. `cd app && dart analyze`
6. `cargo deny check` (license + advisories)
7. `cd app && dart run pana --no-warning` (or equivalent)
8. `cargo make verify-codegen` (drift check)
**And** any failure aborts subsequent steps and returns non-zero exit code.

**Given** `cargo make codegen` is run
**Then** it regenerates `crates/zanshin-ffi/include/zanshin_ffi.h` via `cbindgen --config cbindgen.toml --crate zanshin-ffi --output crates/zanshin-ffi/include/zanshin_ffi.h`
**And** regenerates `app/lib/src/ffi/bindings.dart` via `dart run ffigen --config app/ffigen.yaml`
**And** the developer commits the resulting changes (FR-BO-6 — generated code is committed, not regenerated at build time).

**Given** `cargo make verify-codegen` is run
**Then** it regenerates codegen into a tmpdir
**And** diffs the tmpdir output against committed files
**And** exits non-zero on any drift with a message naming the drifted file paths and the diff snippet.

**Given** `cargo make sign`, `cargo make notarize`, `cargo make release` placeholder tasks
**When** inspected at this stage
**Then** they exist as task stubs that print "Not yet implemented — see Epic 8" and exit 0 (so the task list is complete)
**And** they're fully wired in Epic 8.

**Given** the `Makefile.toml`
**When** `cargo make --list-all-steps` is run
**Then** the output lists exactly the tasks documented above, in alphabetical order, with their descriptions visible.

**Edge cases:**

**Given** `cargo-make` is not installed
**When** a developer runs `cargo make build` for the first time
**Then** the README "Toolchain" section (Story 1.3) lists `cargo install cargo-make` as a one-time prerequisite step.

**Given** the Flutter build fails partway through `cargo make build`
**When** the failure occurs
**Then** the Rust artefact may have been built (in `target/release/`)
**And** `cargo make clean` cleans both Cargo and Flutter outputs without manual intervention.

---

### Story 1.5: Configure `cbindgen` and `ffigen` with committed outputs

> **WIP-rework (2026-05-17):** Keep `cargo make codegen` as the source-of-truth update path and committed `zanshin_ffi.h` + `bindings.dart`. **Drop the CI drift-gate AC** (`cargo make verify-codegen` as merge-blocking) — code-review enforces the discipline rule in WIP. The drift-gate returns in the release phase.

As a developer wiring the FFI codegen chain,
I want `cbindgen.toml` at the workspace root and `ffigen.yaml` at the `app/` root configured so `cargo make codegen` produces committed-quality output,
So that the C header and Dart bindings are reproducible and AR-P-6 / FR-BO-6 are honoured.

**Acceptance Criteria:**

**Given** the workspace root
**When** `cbindgen.toml` is created
**Then** its contents include at minimum: `language = "C"`, `header = "/* Auto-generated by cbindgen — do not edit */"`, `pragma_once = true`, `include_guard = "ZANSHIN_FFI_H"`, `sys_includes = ["stdint.h", "stdbool.h"]`, `style = "type"`
**And** `[parse] parse_deps = false` so cbindgen only parses `zanshin-ffi`'s own sources.

**Given** `crates/zanshin-ffi/include/zanshin_ffi.h` does not yet exist
**When** `cargo make codegen` runs for the first time
**Then** the file is created
**And** its top line is the cbindgen auto-generation comment from `cbindgen.toml`
**And** subsequent runs produce byte-identical output (idempotency).

**Given** `app/ffigen.yaml`
**When** inspected
**Then** it specifies `output: 'lib/src/ffi/bindings.dart'`, `name: 'ZanshinFfi'`, `description: 'FFI bindings for the Zanshin Rust core'`, `headers.entry-points: ['../crates/zanshin-ffi/include/zanshin_ffi.h']`
**And** function-rename / typedef-include filters limit generated symbols to `zanshin_*` (no system-header noise from `stdint.h`).

**Given** `cargo make codegen` runs
**Then** `app/lib/src/ffi/bindings.dart` is created (or updated) with `// AUTO GENERATED FILE, DO NOT EDIT. By ffigen` at the top
**And** the bindings consist of a `ZanshinFfi` class wrapping `DynamicLibrary.process()` or `DynamicLibrary.open('libzanshin_ffi.dylib')` (configured per macOS bundle layout).

**Given** `cargo make verify-codegen` runs in CI
**Then** it re-runs `cargo make codegen` into a tmpdir
**And** diffs every output file (`zanshin_ffi.h`, `bindings.dart`) against the committed version
**And** fails the build on any drift with a precise file:line diff message.

**Given** `zanshin-ffi/src/lib.rs` contains a placeholder `zanshin_ffi_version()` declaration at this stage
**When** `cargo make codegen` runs
**Then** the resulting `zanshin_ffi.h` contains `const char *zanshin_ffi_version(void);` (no anonymous structs, no unwanted bindings)
**And** `bindings.dart` exposes `String zanshinFfiVersion()` with the proper `Pointer<Utf8>` → Dart String conversion.

**Given** the codegen comment header
**When** read by a reviewer
**Then** it explicitly says "DO NOT EDIT — regenerate via `cargo make codegen`"
**And** AR-AP-7 enforcement: any PR that modifies generated files outside `cargo make codegen` is rejected via the drift-check CI gate.

**Edge cases:**

**Given** `cbindgen` is not installed (`cargo install cbindgen`)
**When** `cargo make codegen` runs
**Then** the `Makefile.toml` `codegen` task either runs `cbindgen` as a regular Cargo dep or surfaces a clear "install cbindgen" error
**And** the README documents the prerequisite installation.

**Given** the `zanshin-ffi` `extern "C"` surface grows over time
**When** `cargo make codegen` runs after adding a new function
**Then** the new function appears in both `zanshin_ffi.h` and `bindings.dart` without manual intervention
**And** the diff in the resulting PR is reviewable (cbindgen output is stable / deterministic).

---

### Story 1.6: Add `cargo-deny` advisories + bans (security backstop)

> **WIP-rework (2026-05-17):** Shrunk significantly. Keep `cargo deny check advisories bans` (security backstop — cheap, no license-list maintenance). **Drop** the full `cargo deny check licenses` configuration (`bans`/`sources`/`licenses` lists), **drop** `pana` integration entirely. License-compliance returns in the release phase. Eyeball every new dep's license at PR-review time meanwhile (permissive only — MIT, BSD-2/3, Apache-2.0, MPL-2.0, Unlicense, CC0).

As a developer enforcing license discipline,
I want `cargo-deny` configured at the workspace root and `pana` integrated for Dart-side license checks, both gating CI,
So that no GPL/AGPL/LGPL/SSPL dependency ever lands and NFR-L-1..3 are enforced automatically.

**Acceptance Criteria:**

**Given** the workspace root
**When** `deny.toml` is created
**Then** the `[licenses]` table sets `allow = ["Apache-2.0", "MIT", "BSD-2-Clause", "BSD-3-Clause", "MPL-2.0", "Unlicense", "CC0-1.0", "Zlib", "ISC"]`
**And** `deny = []` is empty (the allow-list is exhaustive — anything not allowed is denied)
**And** `unlicensed = "deny"`, `copyleft = "deny"`, `default = "deny"` are set.

**Given** `deny.toml` `[advisories]` section
**When** inspected
**Then** `vulnerability = "deny"`, `unmaintained = "warn"`, `yanked = "deny"`, `notice = "warn"` are set
**And** the advisories DB is fetched from the default RustSec source.

**Given** `deny.toml` `[bans]` section
**When** inspected
**Then** `multiple-versions = "warn"`, `wildcards = "deny"` are set
**And** an empty `deny` list at this stage (specific bans added if needed in later stories).

**Given** `cargo deny check` is run from the workspace root
**When** the workspace contains only the empty crates (no third-party deps yet)
**Then** the check passes with zero warnings
**And** the run time is < 5 seconds (no advisory DB caching surprise).

**Given** a developer adds a hypothetical GPL-licensed dependency to a member crate
**When** `cargo deny check` runs
**Then** it exits non-zero with a clear "license GPL-3.0 not in allow-list" message naming the offending crate version.

**Given** the `app/` Flutter package
**When** `dart pub global activate pana` is invoked (one-time per developer / CI machine)
**Then** `pana` is callable from CLI.

**Given** `cargo make test` step runs `cd app && dart run pana --no-warning` (per Story 1.4)
**Then** it analyzes `pubspec.yaml` dependencies and reports any non-permissive license
**And** the script fails CI on any dependency whose license isn't in `{MIT, BSD-2-Clause, BSD-3-Clause, Apache-2.0, MPL-2.0, Unlicense, CC0-1.0, ISC}`.

**Given** the `pana` JSON output (`dart run pana --json`)
**When** parsed by an xtask script
**Then** the script extracts `license` per dependency
**And** maps to the same allow-list as `cargo-deny`'s
**And** fails-fast on first violation with the offending package name + license.

**Edge case — Watchman:**

**Given** Watchman is a runtime system dependency (not bundled, not linked — per PRD §3.1)
**When** `cargo deny check` and `pana` run
**Then** neither flags Watchman (it's never in `Cargo.toml` or `pubspec.yaml`)
**And** the README "Toolchain" section documents that Watchman's MIT license is informational only.

**Edge case — Transitive deps:**

**Given** a permissive top-level dep transitively pulls in a GPL crate
**When** `cargo deny check` runs
**Then** the GPL transitive dep is flagged (cargo-deny checks the full dep graph)
**And** the developer must either find an alternative or document a `[licenses] exceptions` entry with a `# WHY:` rationale (requiring PR review).

---

### Story 1.7: Configure workspace-level lint, format, and Cargo hygiene

As a developer ensuring code-style consistency,
I want `rustfmt.toml` at the workspace root, `clippy::pedantic` enabled crate-wide, `analysis_options.yaml` configured in `app/`, and `dart format` enforced,
So that AR-P-8 and AR-P-9 are mechanically enforced and CI catches style violations before review.

**Acceptance Criteria:**

**Given** the workspace root
**When** `rustfmt.toml` is created
**Then** it contains `max_width = 100`, `edition = "2021"`, `imports_granularity = "Crate"`, `group_imports = "StdExternalCrate"`
**And** `cargo fmt --all --check` exits 0 against the empty crate skeletons.

**Given** every member crate's `src/lib.rs` (or `src/main.rs`)
**When** inspected
**Then** it has `#![warn(clippy::pedantic)]` at the top (workspace-wide opt-in per AR-P-9)
**And** any necessary suppressions (`#![allow(clippy::xxx)]`) live at crate root with a documented `// WHY:` comment.

**Given** `cargo clippy --workspace --all-targets -- -D warnings` is run
**When** invoked against the empty crates
**Then** it exits 0
**And** no `pedantic` suppression is needed at this stage (empty crates trigger nothing).

**Given** `app/analysis_options.yaml` (landed in Story 1.2 — code-review 2026-05-17 accepted forward-pull)
**When** inspected
**Then** it `include`s `package:flutter_lints/flutter.yaml`
**And** carries the hand-curated rule set already committed in Story 1.2 (no `very_good_analysis` dependency; rules listed inline)
**And** Story 1.7 verifies the lints still pass against the by-then-grown code base and confirms `flutter_lints: ^6.0.0` is pinned in `app/pubspec.yaml`. Authoring the rule set itself is no longer Story 1.7 scope.

**Given** `dart analyze` is run in `app/`
**When** invoked against the empty `lib/main.dart` (with the SizedBox.shrink stub)
**Then** it exits 0
**And** `dart format --output=none --set-exit-if-changed .` exits 0 (formatting is canonical).

**Given** each member crate's `Cargo.toml`
**When** inspected
**Then** at this stage no `[dependencies]` are pinned yet (placeholders for later stories)
**And** the convention is documented in `crates/README.md`: pre-1.0 deps require `=x.y.z` pins (per AR-P-8).

**Given** an arbitrary `Cargo.toml` in any member crate
**When** a future PR adds `default-features = false` without a `# WHY:` comment
**Then** a CI-level grep check (an xtask or simple grep in `ci.yml`) flags the missing comment
**And** the build fails until the comment is added.

**Given** the workspace root
**When** `.editorconfig` is created
**Then** it sets `root = true`, `[*]` with `indent_style = space`, `indent_size = 4`, `trim_trailing_whitespace = true`, `end_of_line = lf`, `insert_final_newline = true`
**And** `[*.{yml,yaml,json,toml}] indent_size = 2`
**And** `[*.dart] indent_size = 2`.

**Given** no per-file license headers are required (per AR-P-9)
**When** any contributor adds a new source file
**Then** the file contains no `// Copyright ...` header
**And** the `LICENSE` file at the repo root (MIT) is the sole license declaration.

**Edge case — Pedantic noise:**

**Given** `clippy::pedantic` is enabled
**When** real code is written in later stories and triggers a particular lint that is noise (e.g., `clippy::module_name_repetitions`)
**Then** the suppression is added at the crate-level `#![allow(...)]` with a `// WHY: <rationale>` comment per AR-P-9
**And** the suppression is reviewed in the PR that adds it.

---

### Story 1.8: ~~Create `schemas/` directory with versioning README~~ — DELETED (WIP-rework 2026-05-17)

> **Why deleted:** WIP allows breaking schema changes — no `_v2`-suffix discipline, no in-wire `schema_version` field. The `schemas/` directory itself still exists (created on-demand by the epic that lands the first schema, Epic 3) and `schemas/README.md` is replaced by a short note: "schemas are the wire contract; breaking changes are in-place edits in WIP; both Rust (`jsonschema`) and Dart (`json_schema`) tests validate fixtures against them." Versioning machinery returns in the release phase.

---

### Story 1.9: GitHub Actions CI workflow — WIP-minimal gate

> **WIP-rework (2026-05-17):** The "full quality gate" framing is dropped. Keep CI gates: `cargo fmt --check`, `cargo clippy -- -D warnings`, `cargo test --workspace`, `dart analyze --fatal-infos --fatal-warnings`, `dart format --set-exit-if-changed`, `flutter test`, `cargo deny check advisories bans`. **Drop**: `flutter test integration_test`, `cargo deny check licenses`, `pana`, `cargo make verify-codegen` drift gate, `mcp-tester` smoke, performance budget tests, reproducibility CI. These return in the release phase.

As a developer and reviewer,
I want `.github/workflows/ci.yml` running the complete quality gate on every push and PR,
So that no merge can land without passing build + tests + clippy + dart-analyze + cargo-deny + pana + codegen-drift, and the project starts at a green baseline.

**Acceptance Criteria:**

**Given** the repo root
**When** `.github/workflows/ci.yml` is created
**Then** it triggers on `push` to any branch and `pull_request` against `main`
**And** runs on `macos-latest` (or pinned `macos-14`) since the project is macOS-only.

**Given** the workflow
**When** inspected for the build matrix
**Then** there is exactly one job named `ci` (no matrix expansion — macOS only)
**And** the job uses `actions/checkout@v4`.

**Given** the `ci` job's setup steps
**When** inspected
**Then** they include in order:
1. `actions/checkout@v4`
2. `dtolnay/rust-toolchain@stable` (reading `rust-toolchain.toml` automatically) OR `actions-rs/toolchain` with `toolchain: stable` and `override: true`
3. `subosito/flutter-action@v2` with `channel: 'master'` (Flutter `main`) and `flutter-version` matching `app/pubspec.yaml` (currently `3.44.0-1.0.pre-573`)
4. `Swatinem/rust-cache@v2` for cargo build caching
5. `dart pub global activate cargo_make` (or install via `cargo install cargo-make` cached)
6. `dart pub global activate pana`
7. Install `cargo-deny` via `cargo install --locked cargo-deny`

**Given** the `ci` job's test step
**When** it runs
**Then** the single command `cargo make test` is invoked
**And** the full quality gate from Story 1.4 runs (cargo test + clippy + fmt + flutter test + dart analyze + cargo deny + pana + verify-codegen)
**And** any failure aborts the workflow with the offending step's log retained.

**Given** the workflow runs on a clean main branch
**When** all Stories 1.1–1.8 are merged
**Then** the workflow completes successfully (green) in under 10 minutes (cold cache) or under 5 minutes (warm cache).

**Given** the `.github/workflows/` directory
**When** inspected
**Then** only `ci.yml` exists at this stage (release.yml and reproducibility.yml are added in Epic 8)
**And** the `ci.yml` does NOT trigger any signing, notarization, or release steps.

**Given** the workflow file
**When** YAML-linted (e.g., via `yamllint` locally or `action-yamllint` step)
**Then** it has no YAML errors and follows GitHub-recommended structure (`name`, `on`, `jobs.<job>.steps`).

**Given** a PR introduces a clippy warning
**When** it is opened
**Then** the CI job fails on the `cargo clippy -- -D warnings` step within the `cargo make test` flow
**And** the PR cannot be merged into `main` until the warning is fixed (assuming branch protection rules — documented in README but not enforced by Story 1.9 itself).

**Given** a PR drifts the committed codegen (modifying `bindings.dart` by hand)
**When** CI runs
**Then** the `verify-codegen` step fails with a precise diff message
**And** the PR is blocked until the drift is regenerated via `cargo make codegen` and committed.

**Edge cases:**

**Given** the CI runs on a fresh runner with no cache
**When** the build takes longer than the configured timeout
**Then** the timeout is set generously (`timeout-minutes: 30`) and a warning surfaces in the README about cold-cache duration.

**Given** GitHub Actions changes its `macos-latest` runner under us
**When** that runner changes Apple toolchain versions in a way that affects builds
**Then** the workflow pins to a specific version (e.g., `macos-14`) and the README documents the pin update process.

**Given** a runner has no `cargo-make` pre-installed
**When** the install step is cached by `Swatinem/rust-cache`
**Then** the install completes from cache in seconds — no repeated full install.

---

## Epic 2: `zanshin-jj` Adapter & Read Path

Build the anti-corruption-layer adapter over `jj-lib` with full read-side coverage so the rest of the workspace (and the MCP binary) can query a jj repository without ever touching `jj-lib` types directly. Establish the adapter-stability invariant (FR-JJ-16) and the test-fixture infrastructure.

### Story 2.1: Generate test fixture repos via `cargo xtask gen-fixture`

> **WIP-rework (2026-05-17):** Keep the `cargo xtask gen-fixture` tool and committed fixtures, but **only `tiny-3-commits` + `medium-1k-commits`** (the `large-10k-commits` fixture is dropped — there are no perf tests in WIP). **Drop** determinism guarantees and fixture versioning ACs. The fixture archive format (`.tar.zst`) and the "fixtures committed, not regenerated at test time" rule still apply.

As a developer running tests against jj repositories,
I want three pre-built jj repo fixtures (`tiny-3-commits`, `medium-1k-commits`, `large-10k-commits`) committed to the repo as `.tar.zst` archives generated by `cargo xtask gen-fixture`,
So that all subsequent stories test against deterministic, version-controlled fixtures and CI never shells to `jj` at test time (per AR-P-7).

**Acceptance Criteria:**

**Given** the `xtask` crate from Story 1.1
**When** `crates/xtask/src/tasks/gen_fixture.rs` is created
**Then** it implements a `gen_fixture` task callable as `cargo xtask gen-fixture --size {tiny|medium|large}` (or `--all`)
**And** the task uses `jj-lib` directly (no shelling to `jj` CLI) to construct the fixture repos in a tmpdir, then tars + zstd-compresses to `test-fixtures/repos/<name>.tar.zst`.

**Given** `cargo xtask gen-fixture --size tiny`
**When** invoked
**Then** the output `test-fixtures/repos/tiny-3-commits.tar.zst` contains a jj repo with exactly 3 commits in a linear chain
**And** the commits have deterministic timestamps (e.g., fixed Unix epoch values) and a single author identity (`Fixture <fixture@zanshin.test>`)
**And** the repo is < 50 KB compressed.

**Given** `cargo xtask gen-fixture --size medium`
**When** invoked
**Then** the output `test-fixtures/repos/medium-1k-commits.tar.zst` contains a jj repo with exactly 1000 commits
**And** ~30 bookmarks distributed across the DAG
**And** at least one branching point with 3 parallel branches that later merge
**And** the repo is < 5 MB compressed.

**Given** `cargo xtask gen-fixture --size large`
**When** invoked
**Then** the output `test-fixtures/repos/large-10k-commits.tar.zst` contains a jj repo with exactly 10,000 commits
**And** ~100 bookmarks
**And** several long-running branches (~50 commits deep each) that merge into trunk
**And** the repo is < 50 MB compressed (used for NFR-P-1 / FR-GR-5 perf testing).

**Given** all three fixtures are generated
**When** committed to the repo
**Then** `.gitattributes` declares `test-fixtures/**/*.tar.zst` as binary (so git doesn't attempt diffs)
**And** the README in `test-fixtures/repos/README.md` documents how to regenerate them and warns that regeneration produces byte-identical output (deterministic).

**Given** a fixture is needed at test time
**When** a Rust integration test calls a helper `test_helpers::extract_fixture(name)`
**Then** the helper extracts the `.tar.zst` into a per-test tmpdir
**And** returns the path to the extracted `.jj/` repo
**And** cleanup happens automatically via `Drop` on a `tempfile::TempDir`.

**Given** the fixture generation
**When** `cargo xtask gen-fixture --all` runs
**Then** all three fixtures are regenerated in parallel (or sequentially — implementation choice)
**And** the run takes < 60 seconds on a developer machine (M1 Max baseline) for tiny + medium; large takes < 5 minutes.

**Given** a developer wants to update a fixture
**When** they modify `gen_fixture.rs` (e.g., to add a new branch pattern)
**Then** the deterministic-generation contract is preserved (same inputs → same bytes)
**And** the regenerated `.tar.zst` is committed via a normal PR
**And** dependent tests are updated in the same PR.

**Edge cases:**

**Given** the fixture generation requires `jj-lib` to set up a repo with specific commits
**When** `jj-lib` is invoked with deterministic inputs (fixed timestamps, fixed author, fixed content)
**Then** the resulting `.jj/` tree is byte-identical across machines
**And** if any nondeterminism leaks (e.g., random UUIDs), the gen task explicitly seeds the randomness or substitutes deterministic IDs.

**Given** `zstd` compression has tunable levels
**When** the fixture is compressed
**Then** the gen task uses `zstd -19` (high compression) for archival size — the cost is paid once at generation time, never at test time.

**Given** the fixture archives are committed binaries
**When** a `.gitignore` rule accidentally adds `*.tar.zst`
**Then** the `.gitattributes` rule and an explicit `!test-fixtures/**` un-ignore (or proper `.gitignore` scoping) ensures fixtures stay tracked.

---

### Story 2.2: ~~Define NFR-P-1 sub-budget allocation~~ — DELETED (WIP-rework 2026-05-17)

> **Why deleted:** No perf-gate enforcement in WIP, so a numeric sub-budget allocation has no enforcement target. NFR-P-1 remains as a soft design goal (< 2s repo open at 10k commits). Sub-budget allocation returns in the release phase when perf-gates are enforced.

---

### Story 2.3: Implement `repo.rs` — open, init, clone

As a Rust caller (later `zanshin-ffi` and `zanshin-mcp`),
I want `zanshin-jj` to expose `Repo::open`, `Repo::init`, and `Repo::clone` functions returning opaque `Repo` handles,
So that the rest of the read-path stories (status, revset, change, op-log, bookmarks, remotes) have a working repo handle to operate on.

**Acceptance Criteria:**

**Given** `crates/zanshin-jj/src/repo.rs`
**When** created
**Then** it defines a `pub struct Repo { workspace: jj_lib::workspace::Workspace, /* internal */ }` and a `pub fn open(path: &Path) -> Result<Repo, RepoError>` function (FR-JJ-1).

**Given** `Repo::open(path)`
**When** called with a valid `.jj/`-containing path
**Then** it loads the workspace via `jj_lib::workspace::Workspace::load(...)`
**And** returns a `Repo` handle wrapping the workspace
**And** the call completes in < 400 ms on the `large-10k-commits` fixture (per NFR-P-1 sub-budget from Story 2.2).

**Given** `Repo::open(path)`
**When** called with a path that does not contain `.jj/`
**Then** it returns `Err(RepoError::NotARepo { path: <path> })`
**And** does not panic.

**Given** `Repo::open(path)`
**When** called with a path that does not exist
**Then** it returns `Err(RepoError::PathNotFound { path: <path> })`.

**Given** `Repo::init(path, backend: Option<Backend>)` where `Backend::Git` is the only currently-supported variant (FR-JJ-2)
**When** called with a directory path and `Backend::Git`
**Then** it invokes `jj_lib::workspace::Workspace::init_with_git_backend(...)`
**And** the resulting `.jj/` tree is valid (subsequent `Repo::open` of the same path succeeds).

**Given** `Repo::init(path, None)`
**When** called
**Then** it initializes with jj's native backend (no Git interop)
**And** returns a `Repo` handle.

**Given** `Repo::clone(url: &str, target_path: &Path)` (FR-JJ-3)
**When** called with a valid Git remote URL
**Then** it delegates to jj-lib's clone path (which internally uses jj's Git backend)
**And** the call returns a `Repo` handle after clone completes
**And** progress callbacks (added in Epic 6 Story 6.4) are not yet wired here — placeholder TODO comment for FR-JJ-13 integration.

**Given** the public API of `zanshin-jj`
**When** inspected
**Then** only `Repo`, `RepoError`, and `Backend` are exported from `lib.rs`
**And** no `jj_lib` types appear in the public signatures (AR-AP-3-style hygiene — keep internal types internal).

**Given** the `RepoError` enum
**When** inspected
**Then** it derives `thiserror::Error` (or equivalent)
**And** variants include `NotARepo { path }`, `PathNotFound { path }`, `InitFailed { reason }`, `CloneFailed { reason }`, `JjLibError(jj_lib::backend::BackendError)`.

**Given** unit tests in `crates/zanshin-jj/tests/repo.rs`
**When** they run
**Then** they extract the `tiny-3-commits` fixture (via the helper from Story 2.1)
**And** assert `Repo::open(path)` returns `Ok`
**And** assert `Repo::open("/nonexistent")` returns `Err(RepoError::PathNotFound { .. })`
**And** assert `Repo::init(tmpdir, Some(Backend::Git))` followed by `Repo::open(tmpdir)` succeeds.

**Edge cases:**

**Given** a `.jj/` directory exists but is corrupted (e.g., missing `op_heads`)
**When** `Repo::open(path)` is called
**Then** it returns `Err(RepoError::JjLibError(...))` with the underlying jj-lib error wrapped, never panics.

**Given** `Repo::clone` is called with an invalid URL
**When** the call returns
**Then** it returns `Err(RepoError::CloneFailed { reason })` with a descriptive reason string from jj-lib.

**Given** a `Repo` handle is dropped
**When** the workspace's `Drop` impl runs
**Then** any open file handles in jj-lib are released cleanly
**And** no resource leak occurs (verified by a sanity test that opens and drops 100 times in a loop).

---

### Story 2.4: Implement `status.rs` — working-copy status

As a Rust caller wanting to display working-copy state,
I want `zanshin-jj` to expose `Repo::status() -> Status` returning the list of changed files versus the working-copy parent,
So that `zanshin-ffi` and `zanshin-mcp` can answer `status` queries with structured data.

**Acceptance Criteria:**

**Given** `crates/zanshin-jj/src/status.rs`
**When** created
**Then** it defines a `pub struct Status { pub files: Vec<FileChange>, pub working_copy_change_id: ChangeId, pub parent_change_id: ChangeId }` (FR-JJ-4).

**Given** the `FileChange` struct
**When** inspected
**Then** it has fields `path: PathBuf`, `kind: ChangeKind` (enum `Added | Modified | Removed | Renamed { from: PathBuf } | Copied { from: PathBuf }`)
**And** for `Renamed` and `Copied`, the `from` path is populated.

**Given** `Repo::status()`
**When** called on a fixture repo with a clean working copy
**Then** it returns `Status { files: vec![], .. }` with the parent change ID populated.

**Given** `Repo::status()`
**When** called on a repo with manually-staged modifications (added via fixture setup)
**Then** it returns the correct list of `FileChange` entries
**And** the `working_copy_change_id` reflects the current working-copy commit.

**Given** the implementation
**When** inspected
**Then** it queries jj-lib's `WorkspaceCommandHelper` or equivalent for the diff between working-copy and its parent
**And** does NOT shell to `jj status` (AR-AP-1).

**Given** the `ChangeKind::Modified` variant
**When** comparing file content
**Then** binary vs. text detection is delegated to jj-lib (no manual `is_text()` checks here)
**And** the variant carries no content diff (that's `zanshin-diff`'s job in Epic 5).

**Given** unit tests in `crates/zanshin-jj/tests/status.rs`
**When** they run
**Then** they extract a fixture, modify a file in the working tree, call `Repo::status()`, and assert the modification appears with `ChangeKind::Modified`
**And** test that adding a new file appears with `ChangeKind::Added`
**And** test that removing a file appears with `ChangeKind::Removed`.

**Given** a renamed file (jj's rename detection runs)
**When** `Repo::status()` is called
**Then** the result includes a `ChangeKind::Renamed { from: old_path }` entry
**And** no separate `Added` + `Removed` pair for the same logical rename.

**Edge cases:**

**Given** the working copy contains a file with non-UTF-8 bytes in its path
**When** `Repo::status()` is called
**Then** the path is preserved as raw `OsString` (or `PathBuf` from `OsStr::from_bytes` on Unix)
**And** later JSON serialization (in `zanshin-ffi`) handles lossy conversion explicitly with a documented behaviour.

**Given** the repo has uncommitted snapshot churn (Watchman not yet wired)
**When** `Repo::status()` is called
**Then** it returns the state as seen by jj at call time
**And** does NOT trigger a manual snapshot — that's jj's `fsmonitor.backend = "watchman"` path's job at the system level.

> **Addendum 2026-09-23 (Story 9.26) — superseded.** `Repo::status()` (like every other handle-scoped read
> and mutation except `log_defaults` / `workspace_root`) now runs the jj CLI's pre-command snapshot first —
> colocated: Git HEAD import → working-copy snapshot → Git refs import, under jj's `git_import_export.lock` —
> so it returns the state INCLUDING on-disk edits, exactly as `jj status` does, and may write a
> `snapshot working copy` operation. Watchman is honoured through jj-lib's `watchman` feature
> (`fsmonitor.backend = "watchman"`), never bundled or launched by Zanshin. See ADR-0002's 2026-09-23 addendum.

**Given** a very large working copy (10,000+ files, none changed)
**When** `Repo::status()` is called
**Then** it returns quickly (< 100 ms on the large fixture) because jj-lib's status check leverages the index

> **Addendum 2026-09-24 (Story 9.26 follow-up review).** Since Story 9.26 `status()` includes the pre-verb
> snapshot (a full working-copy scan without Watchman); the criterion above has not been re-measured — see
> deferred-work.md "The cost of the per-verb precondition on a GUI refresh is unmeasured".

---

### Story 2.5: Implement `revset.rs` — revset resolution

As a Rust caller wanting to query the DAG by expression,
I want `zanshin-jj` to expose `Repo::resolve_revset(expr: &str) -> Vec<ChangeId>`,
So that consumers can use jj's powerful revset language (e.g., `trunk()..@`, `bookmarks()`, `heads(::)`) to scope their queries (FR-JJ-5).

**Acceptance Criteria:**

**Given** `crates/zanshin-jj/src/revset.rs`
**When** created
**Then** it defines `pub fn resolve_revset(repo: &Repo, expr: &str) -> Result<Vec<ChangeId>, RevsetError>`.

**Given** `resolve_revset(repo, "@")` (the working-copy change)
**When** called on the `medium-1k-commits` fixture
**Then** it returns a single-element `Vec<ChangeId>` matching the working-copy change.

**Given** `resolve_revset(repo, "all()")`
**When** called on the `tiny-3-commits` fixture
**Then** it returns 3 (or 4, including the root) change IDs.

**Given** `resolve_revset(repo, "bookmarks()")`
**When** called on the `medium-1k-commits` fixture
**Then** it returns the change IDs of all bookmarked changes (~30 entries).

**Given** an invalid revset expression (e.g., `bogus_function()`)
**When** `resolve_revset(repo, "bogus_function()")` is called
**Then** it returns `Err(RevsetError::ParseError { reason })` with a descriptive parse error from jj-lib's revset parser
**And** does not panic.

**Given** a syntactically valid but semantically empty revset (e.g., `none()` or `~all()`)
**When** resolved
**Then** the result is `Ok(vec![])` — empty Vec, not an error.

**Given** a revset that references a non-existent bookmark (e.g., `nonexistent-branch`)
**When** resolved
**Then** the result is `Err(RevsetError::ResolutionError { reason })`.

**Given** the `RevsetError` enum
**When** inspected
**Then** it derives `thiserror::Error`
**And** variants include `ParseError { reason }`, `ResolutionError { reason }`, `JjLibError(...)`.

**Given** the implementation
**When** inspected
**Then** it uses jj-lib's revset parser (`jj_lib::revset::parse(...)` or equivalent)
**And** does NOT regex-parse or string-manipulate the input.

**Given** a complex revset (`(trunk()..@) | (visible_heads() & ~::trunk())`)
**When** resolved
**Then** the result is a deduplicated `Vec<ChangeId>` (jj-lib handles set semantics).

**Given** unit tests in `crates/zanshin-jj/tests/revset.rs`
**When** they run
**Then** they cover at minimum: `@`, `@-` (parent), `all()`, `bookmarks()`, `heads(all())`, `trunk()..@`, an invalid expression, and an empty result.

**Edge cases:**

**Given** a revset that resolves to many thousands of change IDs (e.g., `all()` on the large fixture)
**When** resolved
**Then** the resulting `Vec` is fully materialized — no lazy iterator
**And** the call completes in < 200 ms on the 10k-commit fixture.

**Given** a malformed change-ID literal in the revset (e.g., `xyz123notarealid`)
**When** resolved
**Then** the result is `Err(RevsetError::ResolutionError { .. })`.

---

### Story 2.6: Implement `change.rs` — change metadata read

As a Rust caller wanting to display a specific change,
I want `zanshin-jj` to expose `Repo::get_change(id: ChangeId) -> Change` returning all metadata for a change (ID, parents, description, author, timestamps, signed-by, conflict state, anonymous-yes/no),
So that `zanshin-ffi` and `zanshin-mcp` can serve `show <rev>` queries with full metadata (FR-JJ-6).

**Acceptance Criteria:**

**Given** `crates/zanshin-jj/src/change.rs`
**When** created
**Then** it defines `pub struct Change { pub id: ChangeId, pub commit_id: CommitId, pub parents: Vec<ChangeId>, pub description: String, pub author: Signature, pub committer: Signature, pub timestamps: Timestamps, pub signature: Option<Signature>, pub conflict: ConflictState, pub is_anonymous: bool }` (FR-JJ-6 exhaustive).

**Given** the `Signature` struct
**When** inspected
**Then** it has `name: String`, `email: String`, `time: Timestamp` (or `OffsetDateTime`).

**Given** the `Timestamps` struct
**When** inspected
**Then** it has `authored_at: OffsetDateTime`, `committed_at: OffsetDateTime`.

**Given** the `ConflictState` enum
**When** inspected
**Then** variants are `Clean`, `Conflicted { paths: Vec<PathBuf> }`
**And** the `Conflicted` variant lists the file paths with conflicts (used by Epic 6's conflict-resolution flow).

**Given** `Repo::get_change(id)`
**When** called with a valid change ID
**Then** it returns `Ok(Change { .. })` populated from jj-lib's commit metadata
**And** the call completes in < 50 ms (irrelevant of repo size — single change lookup).

**Given** `Repo::get_change(id)`
**When** called with a non-existent ID
**Then** it returns `Err(ChangeError::NotFound { id })`.

**Given** a change with no description (yet)
**When** retrieved
**Then** `Change.description` is an empty string (not `Option<String>`) — jj's convention is always-present-but-may-be-empty.

**Given** a change with a GPG/SSH signature
**When** retrieved
**Then** `Change.signature` is `Some(Signature { .. })` with the signer's identity
**And** signature validation is NOT performed at this stage (Epic 6 may add it for write-side flows).

**Given** an anonymous change (no description, no bookmark)
**When** retrieved
**Then** `Change.is_anonymous` is `true`.

**Given** the working-copy change (the "@" change)
**When** retrieved via `Repo::get_change(repo.status().working_copy_change_id)`
**Then** the fields are correct
**And** `parents` includes the working-copy's parent change.

**Given** unit tests in `crates/zanshin-jj/tests/change.rs`
**When** they run
**Then** they cover: known change ID → correct metadata, non-existent ID → NotFound, root change has empty `parents`, anonymous change has `is_anonymous: true`.

**Edge cases:**

**Given** a merge change with multiple parents
**When** retrieved
**Then** `Change.parents` contains all parent change IDs in jj-lib's order.

**Given** a change with a conflicted file
**When** retrieved
**Then** `Change.conflict` is `Conflicted { paths }` with the conflicted paths
**And** Epic 6's conflict-resolution flow uses this list.

**Given** the change-ID-vs-commit-ID distinction (jj has both)
**When** displayed via Change
**Then** both `id` (ChangeId — stable across rebases) and `commit_id` (CommitId — Git-like SHA, changes on rebase) are present.

---

### Story 2.7: Implement `op_log.rs` — operation log read

As a Rust caller wanting to display the operation log,
I want `zanshin-jj` to expose `Repo::op_log(limit: Option<usize>) -> Vec<Operation>` returning a chronologically ordered list of operations with timestamps and command summaries,
So that consumers can render the op-log UI (FR-JJ-7) and serve `op_log` MCP queries.

**Acceptance Criteria:**

**Given** `crates/zanshin-jj/src/op_log.rs`
**When** created
**Then** it defines `pub struct Operation { pub id: OperationId, pub timestamp: OffsetDateTime, pub user: String, pub host: String, pub description: String, pub parent_ids: Vec<OperationId>, pub root_op: bool }`.

**Given** `Repo::op_log(None)`
**When** called on the `tiny-3-commits` fixture
**Then** it returns the full operation history in reverse-chronological order (most recent first)
**And** the root operation is the last element.

**Given** `Repo::op_log(Some(10))`
**When** called
**Then** it returns at most 10 operations (the 10 most recent).

**Given** an operation's `description`
**When** inspected
**Then** it is jj's user-friendly summary (e.g., `"new abc123 (empty)"`, `"describe c4f1d2"`, `"rebase -d main -s abc123"`)
**And** is NOT a CLI argument list reconstruction — it's whatever jj-lib stores as the operation description.

**Given** the `parent_ids` field
**When** inspected on a regular operation
**Then** it contains a single parent (linear op history)
**And** for the root operation, `parent_ids` is empty.

**Given** the implementation
**When** inspected
**Then** it queries jj-lib's `OpStore` directly (`jj_lib::op_store::OpStore` or equivalent)
**And** does NOT shell to `jj op log` (AR-AP-1).

**Given** unit tests in `crates/zanshin-jj/tests/op_log.rs`
**When** they run
**Then** they cover: full log on tiny fixture (~3+ ops), limit=1 returns just the most recent, root op has empty parents.

**Edge cases:**

**Given** an op-log with thousands of operations (e.g., after many fixture mutations)
**When** `Repo::op_log(None)` is called
**Then** the call completes in < 100 ms (op-log read is bounded by jj-lib's storage)
**And** memory usage is reasonable (no unbounded `Vec` growth for pathological cases — None means "all", so caller is responsible for sane limits).

**Given** an operation by a user with non-UTF-8 hostname or username (extremely rare)
**When** retrieved
**Then** the string is lossy-converted via `String::from_utf8_lossy` or equivalent
**And** the behaviour is documented.

**Given** parallel operations (jj supports op-log forks)
**When** retrieved
**Then** `parent_ids` may contain multiple IDs (op-log is a DAG, not strictly linear)
**And** consumers (Epic 3+ FFI / Epic 7 MCP) handle this case in their UI/output.

---

### Story 2.8: Implement `bookmarks.rs` — list bookmarks (read-only)

As a Rust caller wanting to display bookmarks,
I want `zanshin-jj` to expose `Repo::list_bookmarks() -> Vec<Bookmark>` returning local and remote-tracking bookmarks with their target change IDs,
So that consumers can render the bookmark list in UI/MCP (FR-JJ-8).

**Acceptance Criteria:**

**Given** `crates/zanshin-jj/src/bookmarks.rs`
**When** created
**Then** it defines `pub struct Bookmark { pub name: String, pub target: ChangeId, pub kind: BookmarkKind }` where `BookmarkKind = Local | Remote { remote_name: String }`.

**Given** `Repo::list_bookmarks()`
**When** called on the `medium-1k-commits` fixture (which has ~30 bookmarks)
**Then** it returns a `Vec<Bookmark>` with all local + remote-tracking entries
**And** results are sorted alphabetically by `name` (then by `kind` if same name).

**Given** a bookmark that exists locally and is tracked from a remote
**When** listed
**Then** two entries appear: one with `BookmarkKind::Local`, one with `BookmarkKind::Remote { remote_name: "<remote>" }`.

**Given** a bookmark pointing at a conflict (jj allows divergent / conflicted bookmark states)
**When** listed
**Then** the bookmark appears with its target (jj-lib's representation of the conflicted target — typically a single change-id representing the conflict state)
**And** a future story may add a `is_conflicted` field if needed for UI; this story's scope is just listing.

**Given** the implementation
**When** inspected
**Then** it queries jj-lib's `View` (`jj_lib::view::View::bookmarks()` or equivalent)
**And** does NOT shell to `jj bookmark list` (AR-AP-1).

**Given** unit tests in `crates/zanshin-jj/tests/bookmarks.rs`
**When** they run
**Then** they cover: empty bookmark list on tiny fixture (which has none), populated list on medium fixture, local-and-remote-tracking pairing.

**Edge cases:**

**Given** a repo with hundreds of bookmarks
**When** listed
**Then** the call completes in < 50 ms
**And** the result Vec is bounded by the actual bookmark count (no truncation).

**Given** a bookmark name with non-ASCII characters
**When** listed
**Then** `name` is preserved as UTF-8 String
**And** sorting is by Unicode codepoint order (jj-lib's convention).

**Given** an empty `remote_name` (theoretical edge case)
**When** appearing
**Then** the bookmark is still listed but `remote_name` is empty string — never `None` (the `Remote` variant always has the field).

---

### Story 2.9: Implement `remotes.rs` — list remotes (read-only)

As a Rust caller wanting to display configured remotes,
I want `zanshin-jj` to expose `Repo::list_remotes() -> Vec<Remote>` returning all configured remotes with their URLs,
So that consumers can render the remote list (FR-JJ-9) and Epic 6's fetch/push stories can resolve remote names to URLs.

**Acceptance Criteria:**

**Given** `crates/zanshin-jj/src/remotes.rs`
**When** created
**Then** it defines `pub struct Remote { pub name: String, pub url: String }`.

**Given** `Repo::list_remotes()`
**When** called on a fixture repo with `origin` configured
**Then** it returns `vec![Remote { name: "origin", url: "<url>" }]`.

**Given** a repo with no remotes
**When** `Repo::list_remotes()` is called
**Then** it returns `vec![]` (empty Vec, not an error).

**Given** the implementation
**When** inspected
**Then** it queries jj's git-backend remote config via jj-lib (for Git-backed repos) or returns empty for native-backend repos
**And** does NOT shell to `jj git remote list` (AR-AP-1).

**Given** unit tests in `crates/zanshin-jj/tests/remotes.rs`
**When** they run
**Then** they cover: no remotes (empty Vec), single remote (`origin`), multiple remotes.

**Edge cases:**

**Given** a remote URL with credentials embedded (`https://user:token@github.com/...`)
**When** listed
**Then** the URL is returned as-is (no scrubbing)
**And** callers are responsible for not exposing credentials in UI (separate concern — likely Epic 7's MCP tool descriptions warn about this).

**Given** a remote configured for SSH (`git@github.com:user/repo.git`)
**When** listed
**Then** the URL is returned in SSH form (no auto-conversion to HTTPS).

**Given** a repo with the native backend (not Git-backed)
**When** `Repo::list_remotes()` is called
**Then** it returns empty Vec (no concept of remotes for native backend)
**And** does not error.

---

### Story 2.10: Document the public API surface (FR-JJ-16 informational)

> **WIP-rework (2026-05-17):** Drop the "lock" framing — WIP explicitly allows breaking changes. Keep only the rustdoc comments on every `pub fn` (Code-quality rule). Drop any `cargo public-api` snapshot gate, drop any "API surface diff" CI check. FR-JJ-16 (anti-corruption-layer absorption of jj-lib churn) remains as an architectural invariant — but it's enforced by review and design, not by a surface-lock document.

As an architect enforcing FR-JJ-16,
I want the public API of `zanshin-jj` documented as the explicit anti-corruption boundary with a stability invariant,
So that future jj-lib upgrades absorb their churn inside this crate without leaking type changes to `zanshin-ffi` or `zanshin-mcp`.

**Acceptance Criteria:**

**Given** `crates/zanshin-jj/src/lib.rs`
**When** inspected
**Then** it re-exports exactly the following types from sub-modules: `Repo`, `RepoError`, `Backend`, `Status`, `FileChange`, `ChangeKind`, `ChangeId`, `CommitId`, `Change`, `Signature`, `Timestamps`, `ConflictState`, `RevsetError`, `Operation`, `OperationId`, `ChangeError`, `Bookmark`, `BookmarkKind`, `Remote`
**And** no `jj_lib::*` type is publicly re-exported.

**Given** the crate's top-level doc-comment (`//! ` in `lib.rs`)
**When** read
**Then** it explicitly states: "This crate is the anti-corruption layer over jj-lib. The public API of `zanshin-jj` is stable; jj-lib API changes are absorbed inside this crate. Adding `pub use jj_lib::...` is forbidden (see AR-AP-3)."

**Given** `crates/zanshin-jj/README.md`
**When** created
**Then** it documents:
- The crate's purpose (anti-corruption layer per FR-JJ-16)
- The "do not leak jj-lib types" rule
- How to add new functionality (always wrap, never re-export)
- The integration-test fixture pattern (load via `test_helpers::extract_fixture`)

**Given** the public API
**When** a future PR attempts to add `pub use jj_lib::SomeType;`
**Then** a CI grep check (added in `cargo make test` or via `clippy::disallowed_types`) flags it
**And** the PR is blocked.

**Given** the public API is documented via `cargo doc`
**When** `cargo doc --package zanshin-jj --no-deps --open` is run
**Then** every public item has a doc-comment
**And** the generated docs describe the type's role in plain English (not just type signatures).

**Given** a public function in `repo.rs`, `status.rs`, etc.
**When** inspected
**Then** it has a `# Errors` section documenting which `RepoError` / `RevsetError` / `ChangeError` variants can be returned and under what conditions
**And** an `# Examples` section if non-trivial.

**Given** the crate's `Cargo.toml`
**When** inspected
**Then** `jj-lib = "=0.41.0"` is pinned exactly (AR-P-8)
**And** the dep section has a `# WHY:` comment noting pre-1.0 status and FR-JJ-16 invariant.

**Given** an integration test in `crates/zanshin-jj/tests/api_stability.rs`
**When** it runs
**Then** it instantiates every public type and asserts the type's path matches `zanshin_jj::*`
**And** if `jj-lib` upgrades break the internal implementation, this test still passes (because the public API hasn't changed).

**Edge case — Type leak via Error chain:**

**Given** `RepoError::JjLibError(jj_lib::backend::BackendError)` includes a jj-lib type in its variant
**When** inspected
**Then** this is the **single** allowed leak point — documented in `lib.rs` doc-comment as an exception
**And** the rationale is: `Error` source chains need to be inspectable; replacing with a String would lose context
**And** future stories may revisit by wrapping into a `JjLibErrorKind` enum if it becomes problematic.

**Edge case — Adding a new FR-JJ function:**

**Given** a contributor wants to add a new read function (e.g., `Repo::tags()`)
**When** they submit the PR
**Then** the function lives in a new file `tags.rs`, uses jj-lib internally, defines its own types in `zanshin-jj`
**And** the new public types are re-exported in `lib.rs`
**And** no jj-lib types leak.

---

### Story 2.11: Implement `detect.rs` — repository-kind detection

> **Added 2026-06-20:** Powers the open-project flow. `Repo::open` (Story 2.3) only answers "is this a loadable jj repo?" and collapses "empty folder", "random folder", and "a Git repo" all into `NotARepo`. To offer the user a *"convert this Git project to jj?"* dialog, the UI first needs to know which of those it is — that is this story. Non-paternalistic by design: the backend classifies, the UI (Ralph's scope) decides what to offer.

As a Rust caller powering the open-project flow,
I want `zanshin-jj` to classify a filesystem path as a jj workspace, a (convertible) Git repo, neither, or a missing path,
So that the Flutter UI can open directly, offer a "convert this Git project to jj?" dialog, or report "not a repository" — without the backend deciding for the user (FR-JJ-17).

**Acceptance Criteria:**

**Given** `crates/zanshin-jj/src/detect.rs`
**When** created
**Then** it defines `pub enum RepoKind { Jj, Git, Neither, PathNotFound }` and `pub fn detect_repo(path: &Path) -> Result<RepoKind, DetectError>` plus a `DetectError` error type (FR-JJ-17)
**And** `RepoKind` derives `Debug`, `Clone`, `Copy`, `PartialEq`, `Eq`.

**Given** `detect_repo(path)`
**When** the path does not exist
**Then** it returns `RepoKind::PathNotFound`.

**Given** `detect_repo(path)`
**When** the path contains a `.jj/` directory (whether or not a `.git/` is also present — a colocated repo IS a jj repo)
**Then** it returns `RepoKind::Jj`.

**Given** `detect_repo(path)`
**When** the path contains a `.git/` entry but no `.jj/`
**Then** it returns `RepoKind::Git`.

**Given** `detect_repo(path)`
**When** the path exists but contains neither `.jj/` nor `.git/`
**Then** it returns `RepoKind::Neither`.

**Given** `detect_repo`
**When** called on any path
**Then** it is stat-only — it never loads the workspace, never creates or modifies anything on disk, and never panics
**And** it is cheap enough to call on every folder the user browses in a file picker.

**Given** the public API
**When** inspected
**Then** `RepoKind` and `detect_repo` are re-exported from `lib.rs`
**And** no `jj_lib` type appears in the signature.

**Given** unit tests in `crates/zanshin-jj/tests/detect.rs`
**When** they run
**Then** they assert: the `tiny-3-commits` fixture → `Jj`; a bare `git init` dir (fixture-setup may shell to `git`, AR-AP-1 applies to production code only) → `Git`; an empty tmpdir → `Neither`; a nonexistent path → `PathNotFound`; a colocated dir (`.jj/` + `.git/`) → `Jj`.

**Edge cases:**

**Given** a `.jj` that is a regular file, not a directory (corruption)
**When** `detect_repo` is called
**Then** it does not classify the path as `Jj` (falls through to `Git` or `Neither` by the `.git` check)
**And** the behaviour is documented — `detect_repo` reports *structural presence*, not integrity; integrity is `Repo::open`'s job.

**Given** a `.git` that is a file containing a `gitdir:` pointer (git worktree / submodule)
**When** `detect_repo` is called
**Then** it still returns `RepoKind::Git` (it is a git working tree).

**Given** `.jj` or `.git` is a symlink
**When** `detect_repo` is called
**Then** the link is followed and the path is classified by the target.

---

### Story 2.12: Implement `convert.rs` — colocated Git → jj conversion

> **Added 2026-06-20:** The history-preserving conversion the user picks from the dialog. NOT the same as `Repo::init(.., Some(Backend::Git))` (Story 2.3) — that creates a *fresh, internal* jj-git store and ignores existing history. "Start fresh (ignore history)" reuses that existing `init` as-is (a separate, clearly-labelled, warned action in the UI), so it needs no new backend work here.

As a Rust caller acting on the user's explicit choice,
I want `zanshin-jj` to convert an existing Git repository into a colocated jj workspace,
So that a user who chose "use this Git project with jj, keep git too" gets a `.jj/` alongside their untouched `.git/`, with full history and a working `git` CLI (FR-JJ-18a).

**Acceptance Criteria:**

**Given** `crates/zanshin-jj/src/convert.rs`
**When** created
**Then** it defines `pub fn convert_colocated(path: &Path) -> Result<Repo, RepoError>` (FR-JJ-18a)
**And** `RepoError` gains variants `AlreadyJjRepo { path }`, `NotAGitRepo { path }`, `ConvertFailed { reason }`.

**Given** `convert_colocated(path)`
**When** called on a path where `detect_repo(path) == RepoKind::Git`
**Then** it performs jj's colocated init (the jj-lib equivalent of `jj git init --colocate`; the exact jj-lib call is absorbed inside `convert.rs` per FR-JJ-16)
**And** on success a `.jj/` exists next to the existing `.git/`
**And** the existing Git history is imported and visible (the Git HEAD commit is reachable in the resulting jj repo)
**And** it returns a `Repo` handle (a subsequent `Repo::open(path)` and `detect_repo(path) == Jj` both succeed).

**Given** `convert_colocated(path)`
**When** called on a path where `detect_repo(path) == RepoKind::Jj`
**Then** it returns `Err(RepoError::AlreadyJjRepo { path })` and changes nothing on disk.

**Given** `convert_colocated(path)`
**When** called on a path where `detect_repo(path)` is `Neither` or `PathNotFound`
**Then** it returns `Err(RepoError::NotAGitRepo { path })`.

**Given** the conversion is additive and reversible
**When** it completes (or fails)
**Then** the existing `.git/` is never destructively modified (HEAD and refs are unchanged — asserted before/after in a test)
**And** removing the created `.jj/` restores the plain Git repo
**And** on failure any partially-created `.jj/` is rolled back (mirrors the `Repo::clone` rollback discipline in Story 2.3).

**Given** any jj-lib failure during conversion
**When** it occurs
**Then** it is wrapped as `RepoError::ConvertFailed { reason }` (the jj-lib error flattened to its Display — no new jj_lib type leak)
**And** the call never panics.

**Given** the error-code registry
**When** this story lands
**Then** `docs/rust-error-codes.md` registers `jj.already_jj_repo`, `jj.not_a_git_repo`, and `jj.convert_failed` in the same PR (project-context Error-code-taxonomy rule).

**Given** unit tests in `crates/zanshin-jj/tests/convert.rs`
**When** they run
**Then** they assert: `git init` + one commit → `convert_colocated` → `Ok`, then `detect_repo == Jj`, the committed file is reachable in jj, and `git log` (via fixture-setup git, test-only) still shows the commit; converting a jj repo → `AlreadyJjRepo`; converting an empty dir → `NotAGitRepo`; a forced mid-conversion failure leaves no partial `.jj/`.

**Edge cases:**

**Given** a Git repo with a dirty working tree (uncommitted changes)
**When** `convert_colocated` is called
**Then** jj snapshots the working-copy state into `@` (documented behaviour) — no changes are lost.

**Given** a Git repo on an unborn branch (initialised, zero commits)
**When** `convert_colocated` is called
**Then** it succeeds, producing a colocated repo with empty history (no panic).

**Given** a bare Git repo (no working tree)
**When** `convert_colocated` is called
**Then** it returns a documented `ConvertFailed` (colocated conversion targets working repos) — bare-repo handling, if ever wanted, is out of scope.

---

### Story 2.13: Implement external-git-import conversion (`convert_import`) — fast-follow

> **Added 2026-06-20 — P1 fast-follow (0.2), deferred.** The *second* user-selectable conversion mode: produce a **jj-native** workspace (jj leads; not colocated) at a separate, user-chosen destination, backed by the source's existing `.git/` (shared object store). The original Git repo stays a plain, standalone Git repo. Deferred deliberately — Story 2.12 (colocated) covers the common case, and shipping one well-tested conversion path first keeps the v1 block lean (Ralph's call, 2026-06-20). Sequence after Story 2.12; its FFI wrapper ships in 0.2 (NOT in Story 3.4c, which is colocated-only).

> **Reshaped 2026-06-27 — two-path signature (epic prose predated the jj-0.42 discovery).** The original AC described an *in-place, single-path* `convert_import(path)` that would turn the existing repo into a jj-native one. That is **impossible on jj 0.42**: there is no in-place jj-native conversion of an existing Git repo — `jj git init --no-colocate` over an existing `.git/` is a hard error (confirmed against `do_init` @ `v0.42.0` in `../jj/cli/src/commands/git/init.rs`). The supported shape is `jj git init --git-repo=<repo> <dest>`: a **new, separate** jj-native workspace at `<dest>` sharing the source repo's object store. So the API takes **two** paths — source git repo + destination workspace — and the source is left untouched. This is the same "epic prose predates discovery" pattern as Story 2.12's reconciliation.

As a Rust caller acting on the user's choice of a jj-native workflow,
I want `zanshin-jj` to create a jj-native workspace at a chosen destination backed by an existing Git repo's object store,
So that users who prefer jj-leading (not colocated) can pick that mode from the dialog while their original Git repo stays standalone (FR-JJ-18b).

**Acceptance Criteria:**

**Given** `crates/zanshin-jj/src/convert.rs`
**When** extended
**Then** it defines `pub fn convert_import(git_repo_path: &Path, workspace_path: &Path) -> Result<Repo, RepoError>` (FR-JJ-18b), mirroring `jj git init --git-repo=<repo> <dest>` (exact jj-lib call absorbed per FR-JJ-16).

**Given** `convert_import(git_repo_path, workspace_path)`
**When** called with `git_repo_path` a Git repo and `workspace_path` a separate destination
**Then** it produces a **non-colocated, jj-native** workspace at `workspace_path` backed by the source repo's existing `.git/` (shared object store)
**And** the source's history is reachable in the resulting jj repo (jj leads)
**And** the original `git_repo_path` stays a plain, standalone Git repo (its user-visible refs and HEAD are unchanged — asserted before/after in a test)
**And** it returns a `Repo` handle; `detect_repo(workspace_path) == Jj` afterwards.

**Given** preconditions and error taxonomy
**When** they are evaluated
**Then** `Err(RepoError::AlreadyJjRepo { path })` if `workspace_path` is already a jj repo **or** `git_repo_path` is already a jj repo
**And** `Err(RepoError::NotAGitRepo { path })` if `git_repo_path` is not a Git repo
**And** a **bare** source Git repo is **supported** (NOT rejected) — replicating jj CLI behavior, which accepts a bare `--git-repo`; this is the one precondition that differs from the colocated path (Story 2.12 rejects bare)
**And** a `dest == source` call (both the same Git repo) produces a *colocated* result (jj detects it as colocated), not this jj-native mode — see Story 2.13 Decision D5
**And** any jj-lib failure (or a detect I/O error during the precondition check) is wrapped as `Err(RepoError::ConvertFailed { reason })` (flattened to its Display — no `jj_lib` type leak) and the call never panics.

**Given** the conversion is additive and reversible
**When** it completes (or fails)
**Then** the source repo is never destructively modified — jj only **adds** objects to the shared store; the source's user-visible refs and HEAD are untouched
**And** removing the created destination workspace restores the standalone source Git repo
**And** on failure any partially-created destination is rolled back (mirrors the rollback discipline in Story 2.12).

**Given** the error-code registry
**When** this story lands
**Then** the `jj.already_jj_repo`, `jj.not_a_git_repo`, and `jj.convert_failed` codes already registered by Story 2.12 cover this path (no new codes) — `docs/rust-error-codes.md` is amended only if the dest/source distinction needs a registry note.

**Given** the docs
**When** this story lands
**Then** `crates/zanshin-jj/README.md` (or rustdoc on `convert.rs`) documents the **colocated (Story 2.12) vs. jj-native import (Story 2.13)** trade-off — including that import **shares the source's object store (not a clone; the source must remain)** — so callers and the UI can describe the choice accurately to the user.

**Given** tests in `crates/zanshin-jj/tests/convert.rs`
**When** they run
**Then** they cover the import path symmetrically to the colocated tests: `git init` + one commit at the source → `convert_import(source, dest)` → `Ok`, `detect_repo(dest) == Jj`, the committed file reachable in jj, and the source still a standalone Git repo (HEAD/refs unchanged); converting where the dest is already jj → `AlreadyJjRepo`; a `dest == source` call → a colocated workspace (the colocated-guard case); a **bare** source repo → `Ok` (bare-source case); a non-Git source → `NotAGitRepo`; a forced mid-conversion failure leaves no partial destination (rollback).

---

## Epic 3: `zanshin-ffi` & Watcher (Keystone)

Land the load-bearing FFI infrastructure: opaque handles, FlatBuffers envelope (ADR-0001), error model, async event delivery, watcher subsystem, Watchman detection, diagnostics — plus the minimal Dart-side bootstrap (long-running worker isolate, command bus, `NativeFinalizer`). This epic is the architectural keystone; every downstream epic (4, 5, 6, 7) consumes these patterns.

> **⚠️ Transport amendment ([ADR-0001](../../docs/adr/0001-ffi-data-transport-flatbuffers.md), 2026-06-15):** all FFI composite data — envelope, graph slice, diff, status, op-log, change, progress/watcher events — is **FlatBuffers**, not JSON. Lone strings stay CString; fixed scalars stay plain; MCP keeps JSON-RPC (different boundary). The detailed per-story GWT in Epics 3–6 still says "JSON" / `*.schema.json` in places — that text is superseded. See the **FlatBuffers transport migration story** (`3-0`) for the foundational tooling + the full per-story rework list.

> **WIP re-sequencing (2026-06-15) — interleave FFI infra with Epic 2 to unblock Flutter early.**
> The Flutter dev (Ralph) needs to exercise the Rust read-path from Flutter without waiting for all of Epic 2 + 3. open/init/clone are one-shot operations that need no file-watching, so the **watcher is deferred**.
>
> **New work order:** `3.1 → 3.2 → 3.3 → `**`3.4a`**` (repo open/init/clone/close) → 3.9 → 3.8`, then per finished Epic 2 noun a thin **3.4b** wrapper (`2.4→status`, `2.6→change`, `2.7→op_log`, `2.8→bookmarks`, `2.9→remotes`).
>
> **Deferred (zero rework):** Story 3.5 (watcher), Story 3.6 (NativeCallable event channel), Story 3.10 (E2E watcher test).
>
> **Why zero rework:** the async event sink is process-global, registered once in `zanshin_worker_init` (Story 3.9), NOT per-`repo_open`. So `zanshin_repo_open`'s `extern "C"` signature is identical with or without the watcher; arming is added later purely inside `repo_open`'s body (Story 3.5). Story 3.9 reserves the sink as a no-op stub so `worker_init`'s signature is final now. Nothing is deleted — only re-ordered, plus the old Story 3.4 split into 3.4a / 3.4b.

### Story 3.1: FFI core — envelope, error codes, panic catch

> **⚠️ Scope-correction (binding — [ADR-0001](../../docs/adr/0001-ffi-data-transport-flatbuffers.md), 2026-06-15):** the envelope is **FlatBuffers**, not JSON. Build a FlatBuffers `Envelope { ok: bool; error: FfiError; data: Payload (union); }` returned as an owned buffer (`*mut u8` + len) freed by `zanshin_buffer_free`; lone strings stay CString. The detailed JSON GWT below is superseded — the FlatBuffers tooling lands in migration story `3-0`. Error-code taxonomy (AR-P-4) and panic-catch behaviour are unchanged.

As a Rust developer implementing the FFI surface,
I want `crates/zanshin-ffi/src/envelope.rs` with the AR-AD-1 FlatBuffers envelope, AR-P-4 error-code taxonomy, and panic-catch wrapper helpers,
So that every fallible FFI function in subsequent stories follows the canonical envelope shape with no duplication.

**Acceptance Criteria:**

**Given** `crates/zanshin-ffi/src/envelope.rs`
**When** created
**Then** it defines `pub struct Envelope<T: Serialize> { pub ok: bool, pub data: Option<T>, pub error: Option<ErrorObj>, pub schema_version: &'static str }`
**And** the `schema_version` is `"1.0"` for the envelope itself (per AR-AD-3).

**Given** the `ErrorObj` struct
**When** inspected
**Then** it has `code: String` (dotted lowercase, per AR-P-4), `message: String`, `context: Option<serde_json::Value>`.

**Given** the envelope is serialized
**When** `data = Some(value)`, `error = None`, `ok = true`
**Then** the output JSON is `{"ok": true, "data": <value>, "error": null, "schema_version": "1.0"}`.

**Given** the envelope is serialized
**When** `data = None`, `error = Some(err)`, `ok = false`
**Then** the output JSON is `{"ok": false, "data": null, "error": {"code": "...", "message": "...", "context": ...}, "schema_version": "1.0"}`.

**Given** the helper function `pub fn ok<T: Serialize>(value: T) -> *mut c_char`
**When** called
**Then** it constructs an `Envelope { ok: true, data: Some(value), error: None, schema_version: "1.0" }`
**And** serializes to JSON via `serde_json::to_string(...)`
**And** returns a `CString::into_raw(...)` pointer owned by Rust.

**Given** the helper function `pub fn err(code: &str, message: &str, context: Option<serde_json::Value>) -> *mut c_char`
**When** called
**Then** it constructs an Envelope with the error populated
**And** serializes and returns the C string the same way.

**Given** the helper function `pub fn catch<F, T>(f: F) -> *mut c_char where F: FnOnce() -> Result<T, ErrorObj> + UnwindSafe, T: Serialize`
**When** called
**Then** it wraps `f` in `std::panic::catch_unwind(...)`
**And** if `f` panics, returns `err("internal.panic", "<panic msg>", None)` (per FR-FFI-9 / NFR-R-3)
**And** if `f` returns `Ok(value)`, returns `ok(value)`
**And** if `f` returns `Err(err_obj)`, returns the serialized error envelope.

**Given** error codes follow AR-P-4 (`<domain>.<reason>` dotted lowercase)
**When** `docs/rust-error-codes.md` is created
**Then** it lists at minimum the codes used by this epic:
- `internal.panic`
- `internal.serialization_failed`
- `ffi.invalid_handle`
- `ffi.null_pointer`
- `ffi.utf8_error`
- `jj.repo_not_found`
- `jj.path_not_found`
- `jj.jj_lib_error`
- `watcher.io_error`
- `watcher.watchman_not_configured`

**Given** a fallible FFI function exists in a later story
**When** it uses `envelope::catch(|| { ... })`
**Then** the function body cannot panic out of the FFI boundary (catch_unwind absorbs it)
**And** the return value is always a valid `*mut c_char` pointing at a JSON envelope.

**Given** the returned `*mut c_char`
**When** the caller (Dart) is done with it
**Then** it calls `zanshin_string_free(ptr)` (defined in Story 3.2) to release the memory
**And** failing to free is a leak (documented; `NativeFinalizer` in Story 3.9 mitigates).

**Given** a unit test in `crates/zanshin-ffi/tests/envelope.rs`
**When** it runs
**Then** it verifies ok-envelope serialization, error-envelope serialization, panic-catch behaviour (a closure that panics returns the `internal.panic` envelope), and round-trip JSON-parse.

**Edge cases:**

**Given** serialization itself fails (e.g., a Serialize impl returns an error)
**When** `ok(value)` is called and the inner serialization fails
**Then** the function returns an envelope with `code = "internal.serialization_failed"`, `message = "<serde error>"` rather than panicking.

**Given** the message string contains non-UTF-8 bytes (theoretical)
**When** wrapping into CString
**Then** the message is lossy-converted via `String::from_utf8_lossy` or scrubbed
**And** does not cause `CString::new` to fail.

**Given** a panic with a non-String payload (e.g., a custom struct as panic payload)
**When** caught
**Then** the message becomes `"<unknown panic payload>"` (the catch_unwind result's `downcast_ref::<String>()` or `&str` fails, so a default message is used).

---

### Story 3.2: Handle module + `ffi_strings` + `zanshin_ffi_version`

As a Rust developer implementing the FFI surface,
I want `crates/zanshin-ffi/src/handle.rs`, `crates/zanshin-ffi/src/ffi_strings.rs`, and a `zanshin_ffi_version()` entry point,
So that subsequent stories have clean `Box<T> ↔ *mut T` helpers, safe CString in/out conversions, a free function, and a version handshake mechanism (FR-FFI-10, AR-AD-2).

**Acceptance Criteria:**

**Given** `crates/zanshin-ffi/src/handle.rs`
**When** created
**Then** it defines a generic helper:
```rust
pub unsafe fn handle_from_raw<T>(ptr: *mut T) -> Option<&'static mut T>;
pub fn handle_into_raw<T>(value: T) -> *mut T;  // Box::into_raw(Box::new(value))
pub unsafe fn handle_drop<T>(ptr: *mut T);  // drop(Box::from_raw(ptr))
```
**And** all functions document safety invariants in their `# Safety` doc-comments.

**Given** the helper functions
**When** invoked
**Then** `handle_into_raw(value)` boxes a value and leaks it as `*mut T`
**And** `handle_drop(ptr)` reconstructs the Box and drops it
**And** `handle_from_raw(ptr)` returns `Some(&mut T)` for non-null ptr, `None` otherwise.

**Given** the `validate_handle` helper
**When** an FFI function receives a `*mut c_void` claiming to be a handle of type T
**Then** the helper checks for null
**And** returns `ErrorObj { code: "ffi.invalid_handle", ... }` if null
**And** otherwise casts via `*mut c_void as *mut T` (caller assumes correct type — typestate must come from the API surface, not from runtime).

**Given** `crates/zanshin-ffi/src/ffi_strings.rs`
**When** created
**Then** it defines `pub unsafe fn cstr_to_string(ptr: *const c_char) -> Result<String, ErrorObj>` that:
- returns `Err(ErrorObj { code: "ffi.null_pointer", ... })` on null
- returns `Err(ErrorObj { code: "ffi.utf8_error", ... })` on invalid UTF-8
- otherwise returns the owned String.

**Given** the same module
**When** inspected
**Then** it defines `pub fn string_to_cstring(s: &str) -> *mut c_char` that allocates a new CString and leaks it via `into_raw()`.

**Given** the `zanshin_string_free` function
**When** declared in `ffi_strings.rs`
**Then** it is `#[no_mangle] pub unsafe extern "C" fn zanshin_string_free(ptr: *mut c_char)`
**And** reconstructs the CString via `CString::from_raw(ptr)` and drops it
**And** is the canonical free function for any C string returned by `zanshin-ffi` (per AR-AD-1).

**Given** `crates/zanshin-ffi/src/lib.rs`
**When** it has the module structure from AR-P-3
**Then** it declares: `mod envelope; mod handle; mod ffi_strings; pub use {envelope, handle, ffi_strings}::*;`
**And** it implements `zanshin_ffi_version()`:
```rust
#[no_mangle]
pub extern "C" fn zanshin_ffi_version() -> *mut c_char {
    let version = format!("{} ({})", env!("CARGO_PKG_VERSION"), env!("ZANSHIN_GIT_SHA"));
    ffi_strings::string_to_cstring(&version)
}
```
**And** `ZANSHIN_GIT_SHA` is populated at build time via a `build.rs` script reading `git rev-parse HEAD`.

**Given** `crates/zanshin-ffi/build.rs`
**When** invoked at compile time
**Then** it runs `git rev-parse HEAD` and exports the result as `ZANSHIN_GIT_SHA`
**And** falls back to `"unknown"` if git is unavailable (e.g., source tarball build).

**Given** `cargo make codegen`
**When** run
**Then** the resulting `zanshin_ffi.h` contains:
```c
const char *zanshin_ffi_version(void);
void zanshin_string_free(char *ptr);
```
**And** `bindings.dart` exposes `String zanshinFfiVersion()` and `void zanshinStringFree(Pointer<Utf8> ptr)`.

**Given** an integration test
**When** it calls `zanshin_ffi_version()` from Rust (round-trip through `CString::from_raw`)
**Then** the returned string matches `"<crate version> (<git sha>)"` format
**And** the caller frees via `zanshin_string_free`.

**Edge cases:**

**Given** a CString contains a null byte mid-string (e.g., user-supplied string with `\0`)
**When** `string_to_cstring` is called
**Then** it handles the error gracefully — either truncates with documented behaviour OR returns an error envelope (since this function returns `*mut c_char` directly, truncation is acceptable but documented).

**Given** a developer calls `zanshin_string_free` twice on the same pointer (double-free)
**When** the second call runs
**Then** behaviour is undefined (this is a C ABI; the docs warn against double-free and AR-AD-2's `NativeFinalizer` in Story 3.13 prevents accidental double-free from Dart).

**Given** a developer calls `zanshin_string_free(NULL)`
**When** the call runs
**Then** it returns without crashing (null check at the top — `if ptr.is_null() { return; }`).

---

### Story 3.3: Tracing init with rotating file sink

> **WIP-rework (2026-05-17):** Keep the tracing init + `tracing-appender` with rotating files at `~/Library/Logs/Zanshin/zanshin.log.YYYY-MM-DD`. Keep level filtering via `ZANSHIN_LOG` env. **Drop** rotation-policy tests, log-size-cap ACs, and structured-event-schema validation ACs. These return in the release phase as part of supportability hardening.

As a developer setting up structured logging,
I want `tracing` + `tracing_appender` initialized at FFI library load with a rotating file sink at `~/Library/Logs/Zanshin/zanshin.log.YYYY-MM-DD`,
So that every FFI call and watcher event is traceable per AR-P-5, with no stdout/stderr output in release builds.

**Acceptance Criteria:**

**Given** `crates/zanshin-ffi/src/tracing_init.rs`
**When** created
**Then** it defines `pub fn init_tracing()` that configures a `tracing_subscriber::Registry` with:
- A `tracing_appender::rolling::daily(...)` sink at `~/Library/Logs/Zanshin/`
- Filename prefix `zanshin.log`
- Log level from `ZANSHIN_LOG` env var, defaulting to `info`
- No stdout/stderr layer in release builds (gated by `#[cfg(debug_assertions)]`).

**Given** `init_tracing()` is called
**When** the log directory `~/Library/Logs/Zanshin/` does not exist
**Then** the function creates it (via `std::fs::create_dir_all`)
**And** any error (permission denied, etc.) is logged via `eprintln!` ONCE during init (acceptable at init time; later FFI calls do not produce stderr).

**Given** the env var `ZANSHIN_LOG` is set (e.g., `ZANSHIN_LOG=debug`)
**When** `init_tracing()` is called
**Then** the subscriber respects the level — debug+ logs are emitted.

**Given** the env var is not set
**When** `init_tracing()` is called
**Then** the default level is `info` (per AR-P-5).

**Given** `init_tracing()` is called multiple times accidentally
**When** the call happens
**Then** subsequent calls are no-ops (init is guarded by `OnceCell` or `std::sync::Once`)
**And** no duplicate-subscriber error occurs.

**Given** `crates/zanshin-ffi/src/lib.rs`
**When** the cdylib is loaded (via `#[ctor]` or via the first FFI call)
**Then** `init_tracing()` runs
**And** subsequent FFI calls are wrapped with `tracing::info_span!("ffi_call", fn_name = %fn_name, command_id = ?command_id)` spans.

**Given** a daily log file (`zanshin.log.2026-05-15`)
**When** more than 7 days of logs accumulate
**Then** older files persist (no auto-cleanup in 0.1 — explicitly noted in `docs/release-process.md` or `docs/diagnostics.md` for users to clean periodically)
**And** future story may add rolling-with-size-cap or age-cap.

**Given** a tracing log file is open and being written
**When** the process crashes mid-write
**Then** `tracing_appender` flushes on drop where possible
**And** at minimum, the partial line is preserved (no corruption of earlier lines).

**Given** a `tracing::span!` is entered in an FFI function
**When** the span exits
**Then** the log entry includes `fn_name`, `command_id` (if provided), `handle_id` (if provided), and any captured fields
**And** trace-level entries (per-call entry/exit) are compiled out in release builds via `tracing`'s `release_max_level_*` features (per AR-P-5).

**Given** unit tests
**When** they run
**Then** `init_tracing()` is called once per test-process
**And** the test uses `tracing_subscriber::test::TestWriter` for assertions, not the file sink (file sink is integration-tested separately).

**Edge cases:**

**Given** `~/Library/Logs/Zanshin/` cannot be created (e.g., sandboxed environment)
**When** `init_tracing()` runs
**Then** it falls back to a stderr layer with a warning (acceptable in dev; documented limitation)
**And** never panics or aborts.

**Given** the user's home directory is unusual (e.g., `HOME` env var unset or pointing somewhere unexpected)
**When** the log path is resolved
**Then** the path resolution uses `dirs::home_dir()` or `std::env::var("HOME")` with a clear fallback
**And** failure is logged on first call.

---

### Story 3.4a: Repo FFI wrappers — `zanshin_repo_open/init/clone/close`

> **WIP re-sequencing (2026-06-15):** Carved out of the former monolithic Story 3.4 so the repo open/init/clone path — the only finished Epic 2 noun (Story 2.3) — can be exercised from Flutter immediately, ahead of the remaining read-path nouns and the watcher. The rest of the old Story 3.4 lives on as Story 3.4b.

> **Transport reconciled to FlatBuffers (2026-06-20):** These ACs originally described the pre-ADR-0001 JSON transport (`*mut c_char` envelope, hex-string handle, `jsonschema` validation). **ADR-0001** (`docs/adr/0001-ffi-data-transport-flatbuffers.md`) and the `project-context.md` `overrides:` block retire that; the committed code (Stories 3-0…3-3) implements the FlatBuffers `Envelope` only. The ACs below are now FlatBuffers-native, matching the sibling Story 3.4c. Three implementation decisions were locked on 2026-06-20 (see the inline notes): `close` detects only the null handle; an out-of-range `init` backend yields `ffi.invalid_argument`; tracing-init stays out of `repo_open`.

As a Dart caller (the worker isolate),
I want `extern "C"` functions wrapping the Epic 2 `repo` path (open, init, clone, close) that return the FlatBuffers `Envelope` (ADR-0001),
So that I can open/init/clone a repository from Flutter as soon as the FFI infrastructure is in place — without waiting for the rest of the read path or the watcher.

**Acceptance Criteria:**

**Given** `crates/zanshin-ffi/src/repo.rs`
**When** created
**Then** it defines `zanshin_repo_open`, `zanshin_repo_init`, `zanshin_repo_clone`, `zanshin_repo_close` as `#[no_mangle] pub unsafe extern "C"` functions, each returning `*mut ZanshinBuf` (an owned FlatBuffers `Envelope` token — `ptr`+`len`, freed via `zanshin_buffer_free_token`, consumed by the existing `FfiBuffer.fromToken`)
**And** each function body is wrapped via `envelope::catch(|| { ... })` (Story 3.1)
**And** `crates/zanshin-ffi/Cargo.toml` gains `zanshin-jj = { workspace = true }` (the crate has no such dependency yet).

**Given** the wire schema
**When** updated
**Then** `schemas/envelope.fbs` gains `table RepoHandle { handle: ulong; }` added to the `Payload` union (the `Empty` placeholder is removed), where `handle` is the Rust `*mut Repo` reinterpreted as an unsigned integer
**And** `cargo make codegen` regenerates the Rust + Dart FlatBuffers accessors, `zanshin_ffi.h`, and `bindings.dart`, all committed in the same PR.

**Given** `zanshin_repo_open(path)`
**When** called with a valid jj repo path
**Then** it returns a success `Envelope` whose `Payload` is `RepoHandle { handle }` (consistent envelope reporting — no NULL-plus-out-of-band-error pattern)
**And** `zanshin_repo_close(handle: u64)` takes that same handle integer and drops the `Box<Repo>` (Story 3.2 handle helpers).

**Given** `zanshin_repo_open(path)` with an invalid / non-repo path
**Then** it returns an error `Envelope` (`ok:false`) with `error.code = "jj.repo_not_found"` (path is not a jj repo) or `"jj.path_not_found"` (path does not exist), detail in `error.context` — never a crash, never NULL.

**Given** `zanshin_repo_init(path, backend: i32)`
**When** called in an empty directory
**Then** it initializes a repo (`backend`: `0 → jj native`, `1 → git`) and returns a `RepoHandle` envelope
**And** calling `init` again at the same location returns `jj.jj_lib_error` (no panic)
**And** an out-of-range `backend` value returns `ffi.invalid_argument` (new code, added to the registry) rather than silently defaulting. **(Decided 2026-06-20.)**

**Given** `zanshin_repo_clone(url, target_path)`
**When** called with a local `file://` source fixture into a temp target
**Then** it returns a `RepoHandle` envelope
**And** a clone failure returns `jj.jj_lib_error` and leaves no usable partial workspace (rollback is already inside `zanshin-jj::Repo::clone`).

**Given** `zanshin_repo_close(handle)`
**When** called with the null handle (`0`)
**Then** it returns a defined `ffi.invalid_handle` error (no panic). **Scope (decided 2026-06-20):** the null handle is the only defined-detectable invalid handle — there is no handle table (AD-2: raw `Box` pointers, single isolate). Double-close of the same non-zero value is UB owned by the Dart contract (null the handle after `close`; `NativeFinalizer` fires at most once); the test asserts on `close(0)` and never re-passes a freed pointer.

**Given** the watcher is deferred (Stories 3.5 / 3.6)
**When** `zanshin_repo_open` returns
**Then** it does NOT arm a filesystem watcher yet. **Watcher arming is added later in Story 3.5 as an internal-only change to `repo_open`'s body — the `extern "C"` signature is unchanged, so no codegen / caller rework results.** (This is the load-bearing assumption behind the 2026-06-15 re-sequencing.)

**Given** `cargo make codegen` runs after this story
**Then** `zanshin_ffi.h` and `bindings.dart` contain the four `zanshin_repo_*` functions, committed in the same PR
**And** `docs/rust-error-codes.md` flips `jj.repo_not_found` / `jj.path_not_found` / `jj.jj_lib_error` from `Reserved` to `Emitted — Story 3.4a` and registers the new `ffi.invalid_argument`.

**Given** Rust integration tests in `crates/zanshin-ffi/tests/repo_ffi.rs`
**When** they run
**Then** for each of open/init/clone/close they exercise a success case and an error case
**And** they read every returned buffer through the **generated typed accessors** (`fbs::Envelope`, `env.data_as_repo_handle()`) and run the FlatBuffers `Verifier` before asserting on any field — a wrong-shape payload is a compile error, not a runtime assert. **No `jsonschema`, no hand-parsing** (per project-context Testing Rules + ADR-0001)
**And** they pin `JJ_CONFIG` / `GIT_CONFIG_GLOBAL` and use committed fixtures with no network access.

**Given** a forced panic inside a wrapper body
**When** triggered in a test
**Then** the call returns an error `Envelope` with `error.code = "internal.panic"` (catch_unwind backstop, Story 3.1) — proving no panic crosses the boundary.

**Given** tracing initialization
**When** `zanshin_repo_open` runs
**Then** it does NOT call `init_tracing()` — tracing-init is owned by `zanshin_logging_init()` / the Story 3.9 worker bootstrap; the repo wrappers only add `tracing` spans. **(Decided 2026-06-20.)**

---

### Story 3.4c: Repo detect + convert FFI wrappers — `zanshin_repo_detect` / `zanshin_repo_convert`

> **Added 2026-06-20.** Exposes Story 2.11 (detection) and Story 2.12 (colocated conversion) across the FFI boundary so the Flutter open-project dialog can drive them. **FlatBuffers-native from the start** (ADR-0001) — no legacy JSON envelope here. Sequence right after Story 3.4a (same `repo.rs`, same bootstrap path). External-git import (FR-JJ-18b / Story 2.13) is intentionally NOT exposed here — it ships with its own wrapper in the 0.2 fast-follow.

As a Dart caller (worker isolate) powering the open-project dialog,
I want `extern "C"` functions wrapping `zanshin-jj`'s `detect_repo` and `convert_colocated`,
So that Flutter can classify a path and, on the user's confirmation, convert a Git project to colocated jj — all through the FlatBuffers envelope (FR-JJ-17, FR-JJ-18a).

**Acceptance Criteria:**

**Given** `crates/zanshin-ffi/src/repo.rs`
**When** extended
**Then** it adds `zanshin_repo_detect(path: *const c_char) -> *mut u8` and `zanshin_repo_convert(path: *const c_char) -> *mut u8` as `#[no_mangle] pub unsafe extern "C"` functions returning owned FlatBuffers `Envelope` buffers (`*mut u8` + length, freed via `zanshin_buffer_free`, per Story 3.1 / ADR-0001)
**And** each is wrapped via `envelope::catch(|| { ... })`.

**Given** the wire schema
**When** updated
**Then** the relevant `schemas/*.fbs` gains a `enum RepoKind : byte { Jj, Git, Neither, PathNotFound }` and the detect/convert payload tables, added to the `Payload` union
**And** `cargo make codegen` regenerates the Rust + Dart accessors, `zanshin_ffi.h`, and `bindings.dart`, all committed in the same PR.

**Given** `zanshin_repo_detect(path)`
**When** called with any path (existing, missing, or garbage)
**Then** it returns a well-formed success `Envelope` whose payload carries the `RepoKind` — detection is a *classification*, so "missing" / "neither" are normal results, NOT errors
**And** only a genuine I/O failure (e.g. permission denied while stat-ing) yields an error envelope `jj.detect_failed`.

**Given** `zanshin_repo_convert(path)`
**When** called on a `RepoKind::Git` path
**Then** it performs the colocated conversion and returns a success `Envelope` whose payload carries a freshly-opened `Repo` handle (so the UI can proceed straight into the now-colocated repo without a second open call).

**Given** `zanshin_repo_convert(path)`
**When** the precondition fails
**Then** it returns an error envelope with `jj.already_jj_repo` (path is already jj) or `jj.not_a_git_repo` (neither/missing), and `jj.convert_failed` on a jj-lib failure — never a crash, never NULL.

**Given** a forced panic inside either wrapper
**When** triggered in a test
**Then** the call returns an `internal.panic` error envelope (catch_unwind backstop, Story 3.1).

**Given** Rust integration tests in `crates/zanshin-ffi/tests/repo_ffi.rs`
**When** they run
**Then** they read every returned buffer through the generated typed accessors (a wrong shape is a compile error; no hand-parsing) and run the FlatBuffers `Verifier`
**And** assert: detect on the `tiny` fixture → `Jj`; on a `git init` dir → `Git`; on an empty tmpdir → `Neither`; on a nonexistent path → `PathNotFound`; convert on a `git init` dir → success handle, then detect on the same path → `Jj`; convert on a jj repo → `jj.already_jj_repo`.

**Given** `docs/ffi-abi.md`
**When** this story lands
**Then** it documents `zanshin_repo_detect` / `zanshin_repo_convert` and the `RepoKind` enum mapping.

---

### Story 3.4b: Read-path FFI wrappers — `zanshin_status`, `zanshin_change`, `zanshin_op_log`, `zanshin_bookmarks`, `zanshin_remotes`

> **WIP re-sequencing (2026-06-15):** Was Story 3.4. The `zanshin_repo_open/init/clone/close` functions moved to Story 3.4a, so the `zanshin_repo_*` acceptance criteria below are **superseded by Story 3.4a**. This story now covers the non-repo read wrappers only, and each wrapper lands as its Epic 2 noun completes: `status` ← 2.4, `revset`/`change` ← 2.5 / 2.6, `op_log` ← 2.7, `bookmarks` ← 2.8, `remotes` ← 2.9. Not on the "open/init/clone early" critical path — sequence freely after Story 3.9.

> **Transport reconciled to FlatBuffers (2026-06-20):** Everything below predates [ADR-0001](../../docs/adr/0001-ffi-data-transport-flatbuffers.md) and is superseded by it + the `project-context.md` `overrides:` block. **The `zanshin_repo_open/init/clone/close` signatures and ACs here are fully superseded by Story 3.4a** — this story is read-path nouns only. Binding contract per read wrapper: returns `*mut ZanshinBuf` (a FlatBuffers `Envelope` token, freed via `zanshin_buffer_free_token`, consumed by `FfiBuffer.fromToken`); the success payload is a per-noun table added to `schemas/envelope.fbs`'s `Payload` union and regenerated via `cargo make codegen`. **No JSON-string inputs** (ADR-0001): a `limit` is a plain scalar, a `change_id` / revset `expr` is a lone string (CString) — drop the `*_json` wrappers and the `internal.serialization_failed` code (use `ffi.invalid_handle` / `ffi.null_pointer` / `ffi.utf8_error` / `ffi.invalid_argument`). Tests read the buffer through generated typed accessors + the FlatBuffers `Verifier` — no `jsonschema`. Per-noun details are finalized at create-story time (cf. Story 3.4a).

> **Repo-state model — [ADR-0002](../../docs/adr/0002-repository-state-model-warm-loader-reload-per-operation.md) (2026-06-22):** Each read wrapper **re-resolves to the latest operation** (`workspace.repo_loader().load_at_head()`) and operates on that freshly-resolved `ReadonlyRepo` — it does not serve from a long-lived cached repo view. This matches "Decision D4" already documented in `crates/zanshin-jj/src/repo.rs` and keeps reads correct under concurrent external `jj` CLI mutations (same-repo concurrency, FR-MCP-9 / FR-RX-3). See the adoption story (**Story 3.11**).

As a Dart caller (the worker isolate),
I want `extern "C"` read-path wrappers (`zanshin_status`, `zanshin_op_log`, `zanshin_change`, `zanshin_bookmarks`, `zanshin_remotes`, `zanshin_revset_resolve`) returning the FlatBuffers `Envelope` (ADR-0001),
So that the Dart side has working read endpoints to exercise the FFI scaffolding against real data.

**Acceptance Criteria:**

**Given** `crates/zanshin-ffi/src/repo.rs`
**When** created
**Then** it defines:
```rust
#[no_mangle]
pub unsafe extern "C" fn zanshin_repo_open(path: *const c_char) -> *mut c_void;
#[no_mangle]
pub unsafe extern "C" fn zanshin_repo_close(handle: *mut c_void);
#[no_mangle]
pub unsafe extern "C" fn zanshin_repo_init(path: *const c_char, backend: *const c_char) -> *mut c_char;
#[no_mangle]
pub unsafe extern "C" fn zanshin_repo_clone(url: *const c_char, target_path: *const c_char) -> *mut c_void;
```
**And** each wraps via `envelope::catch(|| { ... })`.

**Given** `zanshin_repo_open(path)`
**When** called with a valid jj repo path
**Then** it returns a `*mut c_void` pointing at a `Box<Repo>` (per AR-AD-2)
**And** internally logs `tracing::info!("zanshin_repo_open", path = %path)`.

**Given** `zanshin_repo_open(path)`
**When** called with an invalid path
**Then** it returns `NULL`
**And** the error is fetched via a separate `zanshin_last_error()` function (returns `*mut c_char` envelope) OR — alternative cleaner design — the function returns `*mut c_char` (envelope) with `data.handle_ptr` field. **Decision for this story:** use the alternative — open returns `*mut c_char` envelope containing `{"data": {"handle": <ptr_as_u64>}}` to keep error reporting consistent.

Update the signature:
```rust
#[no_mangle]
pub unsafe extern "C" fn zanshin_repo_open(path: *const c_char) -> *mut c_char;
```
where the envelope's `data` field contains `{"handle": "<hex ptr>"}` on success.

**And** `zanshin_repo_close(handle: *mut c_void)` takes the raw handle (parsed from the hex string by Dart) and drops the Box.

**Given** `zanshin_status(handle)`
**When** called with a valid handle
**Then** it calls `zanshin_jj::Repo::status()` via the handle
**And** returns a JSON envelope with `data = Status` serialized
**And** the `Status` type derives `serde::Serialize` (added to `zanshin-jj` types in this story or pre-emptively in Epic 2).

**Given** `zanshin_log(handle, limit_json)`
**When** called with `limit_json = "{\"limit\": 100}"` (or null for unlimited)
**Then** it returns a JSON envelope with `data` as the array of Operations.

**Given** `zanshin_change(handle, change_id_json)`
**When** called with `change_id_json = "{\"id\": \"<hex>\"}"` 
**Then** it returns a JSON envelope with `data = Change`.

**Given** `zanshin_bookmarks(handle)` and `zanshin_remotes(handle)`
**When** called
**Then** each returns an envelope with `data` as the corresponding array.

**Given** `zanshin_revset_resolve(handle, expr_json)` where `expr_json = "{\"expr\": \"...\"}"`
**When** called
**Then** it returns an envelope with `data` as `{"change_ids": [...]}`.

**Given** all read-path functions
**When** they receive a null handle pointer
**Then** they return an `ffi.invalid_handle` error envelope (not crash).

**Given** all read-path functions
**When** they receive a malformed JSON input string
**Then** they return an `internal.serialization_failed` error envelope.

**Given** `cargo make codegen` runs after this story
**Then** `zanshin_ffi.h` contains all the declared functions
**And** `bindings.dart` exposes Dart-friendly wrappers.

**Given** Rust unit tests in `crates/zanshin-ffi/tests/read_path.rs`
**When** they run
**Then** they exercise the round trip: open a fixture, call each read function, parse the JSON envelope, assert the `data` field matches expectations
**And** test invalid handle → `ffi.invalid_handle`, missing path → `jj.path_not_found`, etc.

**Edge cases:**

**Given** a handle pointer encoded as hex string `"0x7f..."` 
**When** Dart parses it from envelope.data.handle and passes it back as `*mut c_void`
**Then** the round-trip is correct on 64-bit macOS
**And** the encoding is documented in `docs/ffi-abi.md`.

**Given** concurrent calls to FFI functions from multiple Dart isolates (theoretical — AR-AD-2 forbids this)
**When** they happen
**Then** behaviour is undefined and documented in `docs/ffi-abi.md` ("single worker isolate only — see AD-2")
**And** debug builds may add a thread-id assertion for early detection.

**Given** the change-id encoding (jj uses base32 or hex)
**When** crossing the FFI boundary as JSON
**Then** the canonical encoding (matching jj-lib's `to_string()`) is used and documented in `docs/ffi-abi.md`.

---

### Story 3.5: Watcher subsystem with `notify-debouncer-full`

> **WIP re-sequencing (2026-06-15): DEFERRED.** The watcher is not needed for the open/init/clone path (one-shot operations). It is rebuilt later as an internal addition to `zanshin_repo_open` (signature unchanged) plus the deferred event channel (Story 3.6). Zero rework — nothing here is deleted, only postponed past the early read-path slices.

As a Rust developer implementing the watcher,
I want `crates/zanshin-ffi/src/watcher.rs` using `notify-debouncer-full` with a 50ms debounce window and bounded mpsc channel (AR-AD-5),
So that filesystem changes on `.jj/repo/op_heads/heads/` (primary) and `.jj/repo/working_copy/checkout` (heartbeat) deliver to the dispatch loop with backpressure handling.

**Acceptance Criteria:**

**Given** `crates/zanshin-ffi/src/watcher.rs`
**When** created
**Then** it defines `pub struct Watcher { debouncer: Debouncer<RecommendedWatcher>, tx: tokio::sync::mpsc::Sender<WatcherEvent>, /* internal */ }`.

**Given** the `WatcherEvent` enum
**When** inspected
**Then** variants are `OpHeadsChanged { paths: Vec<PathBuf>, schema_version: &'static str }`, `WorkingCopyHeartbeat { paths: Vec<PathBuf>, schema_version: &'static str }`, `WatcherError { code: String, message: String }`.

**Given** `Watcher::new(repo_path: &Path) -> Result<(Watcher, mpsc::Receiver<WatcherEvent>), WatcherError>`
**When** called with a valid `.jj/`-containing path
**Then** it sets up two watches:
- Primary: `<repo_path>/.jj/repo/op_heads/heads/` (recursive: false)
- Heartbeat: `<repo_path>/.jj/repo/working_copy/checkout`
**And** uses `notify_debouncer_full::new_debouncer(Duration::from_millis(50), None, callback)` with the 50ms debounce window.

**Given** the mpsc channel
**When** created
**Then** capacity is 256 events (per AR-AD-5).

**Given** a filesystem event on `op_heads/heads/`
**When** the debouncer processes it after the 50ms window
**Then** a `WatcherEvent::OpHeadsChanged { paths }` is sent on the mpsc channel
**And** if the channel is full, the oldest event is dropped with `tracing::warn!("watcher channel full, dropping oldest")` (drop-oldest policy per AR-AD-5).

**Given** a filesystem event on `working_copy/checkout`
**When** processed
**Then** a `WatcherEvent::WorkingCopyHeartbeat { paths }` is sent (same channel-full policy).

**Given** `notify-debouncer-full`'s automatic rescan on disappear+reappear
**When** the watched path becomes unavailable (e.g., network drive unmounts) and later returns
**Then** the debouncer auto-rescans (FR-RX-4)
**And** a `WatcherEvent::OpHeadsChanged` is sent for any changes that happened while the path was unavailable.

**Given** `Watcher::stop(self)`
**When** called
**Then** it shuts down the debouncer cleanly
**And** the mpsc channel is closed (Receiver gets `None`).

**Given** the watcher event dispatch loop (Story 3.6 / 3.7)
**When** it consumes from the receiver
**Then** each event is forwarded to the `NativeCallable.listener` callback (registered per-handle).

**Given** Rust unit tests in `crates/zanshin-ffi/tests/watcher.rs`
**When** they run
**Then** they extract a fixture, set up a `Watcher`, manually touch a file in `.jj/repo/op_heads/heads/`, and assert the event arrives within 200 ms (per AR-P-7's CI noise allowance for the NFR-P-4 < 100ms budget).

**Edge cases:**

**Given** a burst of 1000 events on `op_heads/heads/` in 10 ms
**When** processed by the debouncer
**Then** they collapse into a single `OpHeadsChanged` event (debouncing works)
**And** no event is dropped due to debouncing (debouncing != channel-full drop).

**Given** the watched path does not exist when `Watcher::new` is called
**When** the call returns
**Then** it returns `Err(WatcherError::IoError { ... })` with `code: "watcher.io_error"`.

**Given** a filesystem with high event-rate noise (e.g., Spotlight indexing during fixture-extract)
**When** events fire on non-watched paths
**Then** the watcher ignores them (only paths inside the explicit watches are reported).

---

### Story 3.6: NativeCallable.listener dispatch — events + progress callbacks

> **WIP re-sequencing (2026-06-15): DEFERRED with the watcher (Story 3.5).** Command/response in the worker isolate (Story 3.9) uses `SendPort`/`ReceivePort` + `commandId` correlation and needs no `NativeCallable` events. The event channel is only for async Rust→Dart pushes (watcher / progress), which are deferred. (Progress callbacks for Epic 6 fetch/push also ride this channel — they arrive with it.)
>
> **Story-creation correction (2026-06-21, Story 3.9):** Story 3.9 does **NOT** create a Rust `zanshin_worker_init` no-op stub (the earlier "reserve the signature now" idea is dropped — you cannot finalize the signature of a `NativeCallable` event contract that this story defines; pinning it prematurely *is* the churn it tried to avoid). **THIS STORY (3.6) OWNS the full event-sink surface end-to-end:** the process-global async event sink, `zanshin_worker_init` (or whatever the registration entry point is named), the `NativeCallable.listener` contract, and the matching Dart event-stream wiring. Story 3.9 reserved only the **Dart-side** event `ReceivePort`/`SendPort` plumbing (no traffic), so adding the producer here needs no `ZanshinWorker` restructuring. Tracked in `deferred-work.md`.
>
> **Code-review follow-ups from Story 3.9 (2026-06-21) — build two regression tests here.** Story 3.9's review hardened `ZanshinWorker` against two worker-death paths that 3.9 itself cannot trigger (no fault-injection hook exists yet): (1) `ZanshinWorker.start()` now races the handshake against early worker death + a 10s timeout (fixes a boot deadlock if the worker dies before the handshake send), and (2) `_onWorkerDeath` now `_isolate.kill()`s a worker reported dead via `addErrorListener` (`errorsAreFatal:false` does not self-terminate, so without the kill the "dead" worker would keep holding FFI handles). 3.6 introduces the first worker-side code that can fail during init and the first path that can raise an uncaught *async* error (the event-sink registration + `NativeCallable` dispatch), so add the matching tests **here**: (a) force a pre-handshake worker failure → assert `start()` errors (not hangs) and closes all five ports; (b) force an uncaught async worker error → assert pending commands fail AND the isolate is no longer alive. Tracked in `deferred-work.md` (§ code review of 3-9).
>
> **Also needs reconciliation when 3.6 is written (ADR-0001):** the ACs below predate FlatBuffers — they describe JSON events (`*mut c_char` JSON), `schema_version`, and `schemas/progress.v1.schema.json`. Per ADR-0001 + `project-context.md` `overrides:`, composite event payloads cross as **FlatBuffers** (no JSON on the FFI wire, no in-wire `schema_version`). Reconcile the event/progress payloads to a FlatBuffers schema at story-creation time, the same way Stories 3.4a / 3.9 reconciled their JSON-era prose.

As a Rust developer wiring async signals,
I want the watcher event stream (Story 3.5) and progress callback contract (FR-FFI-8) both delivered to Dart via `NativeCallable.listener`,
So that AR-AD-4's event-stream-port pattern works end-to-end and FR-FFI-4 + FR-RX-1 are satisfied.

**Acceptance Criteria:**

**Given** `crates/zanshin-ffi/src/callbacks.rs` (or in `watcher.rs`)
**When** created
**Then** it defines:
```rust
pub type WatcherCallback = unsafe extern "C" fn(json_event: *mut c_char);
pub type ProgressCallback = unsafe extern "C" fn(json_event: *mut c_char);
```
**And** a global (or per-handle) callback-pointer registry keyed by handle ID.

**Given** an FFI function `zanshin_watcher_register(handle, callback)`
**When** called with a watcher handle and a `WatcherCallback` function pointer (Dart's `NativeCallable.listener` produces such pointers)
**Then** it stores the callback in the registry
**And** returns `ok()` envelope on success.

**Given** the watcher dispatch loop
**When** an event arrives from the mpsc channel
**Then** it serializes the event to JSON
**And** invokes the registered callback with `string_to_cstring(json)` as the argument
**And** the Dart side is responsible for freeing the string via `zanshin_string_free` after parsing.

**Given** a long-running operation (Epic 6's fetch/push, Epic 4's lane-cache rebuild)
**When** progress events fire
**Then** they follow the same pattern: a `ProgressCallback` is registered via `zanshin_progress_register(handle, op_id, callback)`
**And** events shape is `{"operation": "fetch", "progress": 0.42, "message": "Fetching origin", "schema_version": "1.0"}` matching `schemas/progress.v1.schema.json`.

**Given** the `progress.v1.schema.json` schema file
**When** created in `schemas/progress.v1.schema.json`
**Then** it validates the progress event shape with required fields: `operation: string`, `progress: number ∈ [0, 1]`, `message: string`, `schema_version: string`.

**Given** unit tests
**When** they register a callback, push an event, and verify the callback fires within 200ms
**Then** they pass (NFR-P-4 budget honoured).

**Given** the callback function pointer
**When** called from a Rust thread (the watcher's dispatch thread)
**Then** Dart's `NativeCallable.listener` (constructed on the Dart side with `Isolate.current.controlPort`) routes the call back to the right isolate
**And** the Dart isolate handles the JSON parse and stream-push without blocking the Rust thread (it returns immediately).

**Given** multiple handles each with a registered callback
**When** events fire for handle A
**Then** only handle A's callback is invoked (not handle B's)
**And** the registry indexes by handle ID.

**Edge cases:**

**Given** a callback is registered but the Dart isolate is shutting down
**When** the Rust side invokes the callback
**Then** the behaviour is documented: the call may segfault if the function pointer is no longer valid
**And** the Dart side MUST unregister callbacks before isolate shutdown (added to AR-AD-4 protocol in Story 3.9).

**Given** the dispatch thread is blocked
**When** events keep arriving
**Then** the bounded mpsc channel from Story 3.5 absorbs up to 256 events before drop-oldest kicks in.

**Given** the callback signature mismatches (e.g., Dart-side `NativeCallable.listener` typing diverges from Rust's `WatcherCallback`)
**When** loaded
**Then** the mismatch is caught by ffigen-generated bindings at compile time (Dart side)
**And** unit tests cover the binding compatibility.

---

### Story 3.7: ~~Watchman availability check API~~ — DELETED (WIP-rework 2026-05-17)

> **Why deleted:** `notify-debouncer-full` covers the WIP watcher path without Watchman. Watchman-status surfacing is release-grade UX polish (first-run setup dialog). FR-FFI-7 is marked deferred in PRD § 4.4. Returns in the release phase, alongside the diagnostics expansion.

---

### Story 3.8: Diagnostics API (WIP-minimal)

> **WIP-rework (2026-05-17):** Shrunk drastically. Keep `extern "C" fn zanshin_diagnostics() -> *mut c_char` returning a JSON envelope, but the `data` shape is only `{ app_version: string, git_sha: string, log_path: string }` in WIP. **Drop** all the other fields (jj_lib_version, rust_version, watchman_version, os.*, repo.*). **Drop** the dedicated `schemas/diagnostics.schema.json` validation requirement (the WIP shape is so small it doesn't earn a schema). Full structured diagnostics — and the schema — return in the release phase.

> **Transport reconciled to FlatBuffers (2026-06-20):** The `*mut c_char` JSON-envelope return and the `schemas/diagnostics.v1.schema.json` / `jsonschema` ACs below predate [ADR-0001](../../docs/adr/0001-ffi-data-transport-flatbuffers.md) and are superseded. `zanshin_diagnostics` returns `*mut ZanshinBuf` (a FlatBuffers `Envelope` token); the WIP `data` shape `{ app_version, git_sha, log_path }` is a `Diagnostics` table in `schemas/envelope.fbs`'s `Payload` union (regenerated via `cargo make codegen`). The WIP-rework already drops the dedicated schema; tests assert via the generated typed accessors + the `Verifier`, not `jsonschema`. No `schema_version` field.

As a Dart caller producing a "Copy Diagnostics" button,
I want `zanshin_diagnostics()` returning a JSON envelope with versions, OS info, and repo summary (NFR-S-2, AR-G-2),
So that users can paste self-describing diagnostics into bug reports without leaking sensitive data.

**Acceptance Criteria:**

**Given** `crates/zanshin-ffi/src/diagnostics.rs`
**When** created
**Then** it defines `extern "C" fn zanshin_diagnostics(repo_path: *const c_char) -> *mut c_char` returning a JSON envelope.

**Given** `schemas/diagnostics.v1.schema.json` is created
**When** validated
**Then** the schema requires: `app_version: string`, `git_sha: string`, `jj_lib_version: string`, `rust_version: string` (compile-time), `watchman_version: Option<string>`, `os: { name: string, version: string, arch: string }`, `repo: { path: string, backend: "git" | "native", commit_count_approx: number, current_change_id: string }`, `schema_version: "1.0"`.

**Given** the function is called with a valid repo path
**When** it executes
**Then** it populates:
- `app_version` from `CARGO_PKG_VERSION`
- `git_sha` from `ZANSHIN_GIT_SHA` (set in Story 3.2 build.rs)
- `jj_lib_version` from a `jj-lib` re-exported constant or `Cargo.toml` parse
- `rust_version` from `env!("RUSTC_VERSION")` (added via build.rs)
- `watchman_version` by reusing the helper from Story 3.7
- `os.name` from `std::env::consts::OS` (always `"macos"`)
- `os.version` via `sw_vers -productVersion` (1-second timeout)
- `os.arch` from `std::env::consts::ARCH`
- `repo.path` from the supplied path
- `repo.backend` from inspecting `.jj/repo/store/type`
- `repo.commit_count_approx` from a fast `op_log().len() * 2` heuristic (NOT a full DAG walk — approximation is fine for diagnostics)
- `repo.current_change_id` from `Repo::status().working_copy_change_id`

**Given** the JSON output
**When** copied to clipboard
**Then** it contains no email addresses, no commit messages, no file contents, no paths beyond the repo root
**And** the repo path is normalized to a relative-to-home form (e.g., `~/dev/zanshin`) for privacy.

**Given** the function is called with a missing path
**When** it executes
**Then** it returns an envelope with `code: "jj.path_not_found"`.

**Given** unit tests
**When** they run
**Then** they call diagnostics with a fixture repo and assert all required fields are populated and JSON-schema-valid.

**Edge cases:**

**Given** the user has a non-standard `sw_vers` (e.g., a customized macOS build)
**When** parsed
**Then** the `os.version` falls back to `"unknown"` rather than erroring.

**Given** the repo path contains symlinks
**When** normalized
**Then** the function uses `Path::canonicalize` to resolve real path
**And** displays the canonicalized form.

**Given** the diagnostics output exceeds 8 KB (theoretical)
**When** copied
**Then** the user can still paste it — no truncation in this API
**And** future iteration may add a `--compact` flag if the size becomes a UX concern.

---

### Story 3.9: Dart worker isolate bootstrap — `Isolate.spawn` + ports + correlation

> **WIP re-sequencing (2026-06-15):** Brought forward (runs right after Story 3.4a) so open/init/clone are callable from Flutter early. Since the watcher / event channel (Stories 3.5 / 3.6) is deferred, register the process-global async event sink in `zanshin_worker_init` as a **no-op stub now** (reserved slot) — this keeps `worker_init`'s signature final so it won't churn when events land later. The dedicated event-stream port (see the "Async events from FFI" edge case below) is wired but carries no traffic until Story 3.6.

As a Dart developer setting up the worker isolate,
I want `app/lib/src/worker/isolate.dart` + `commands.dart` + `correlation.dart` implementing AR-AD-4 (sealed `WorkerCommand`, `SendPort`-based dispatch, `commandId` correlation),
So that the main isolate can issue typed commands and receive JSON-parsed results, with `NativeFinalizer` registered for handle lifetimes (AR-AD-2).

**Acceptance Criteria:**

**Given** `app/lib/src/worker/commands.dart`
**When** created
**Then** it defines:
```dart
sealed class WorkerCommand {
  final int commandId;
  const WorkerCommand(this.commandId);
}
final class OpenRepoCommand extends WorkerCommand { final String path; ... }
final class StatusCommand extends WorkerCommand { final int handleId; ... }
final class ChangeCommand extends WorkerCommand { final int handleId; final String changeId; ... }
// ... one class per FFI read function
```
**And** each command class has `toJson()` for the worker-side dispatch.

**Given** `app/lib/src/worker/correlation.dart`
**When** created
**Then** it defines a `CommandCorrelator` class with:
- `final Map<int, Completer<String>> _pending = {};`
- `int _nextId = 0;`
- `int allocateId() => _nextId++;`
- `Future<String> register(int id) { final c = Completer(); _pending[id] = c; return c.future; }`
- `void resolve(int id, String response) { _pending.remove(id)?.complete(response); }`
- `void error(int id, Object error) { _pending.remove(id)?.completeError(error); }`

**Given** `app/lib/src/worker/isolate.dart`
**When** created
**Then** it defines `class ZanshinWorker { ... }` with:
- `Future<ZanshinWorker> start()` — spawns the worker isolate via `Isolate.spawn(_workerEntry, sendPort)` and returns once handshake completes
- `Future<String> send(WorkerCommand cmd)` — sends the command, registers correlation, awaits response
- `void close()` — terminates the worker isolate gracefully

**Given** `_workerEntry(SendPort mainPort)` (the isolate entry point)
**When** spawned
**Then** it:
1. Creates its own `ReceivePort`
2. Sends its `SendPort` back to main via `mainPort`
3. Initializes the FFI library via `DynamicLibrary.process()` (or `open('libzanshin_ffi.dylib')`)
4. Enters a message loop receiving `WorkerCommand` objects, dispatching to FFI, returning JSON via `mainPort`

**Given** the FFI binding usage
**When** the worker calls `zanshinFfi.zanshin_repo_open(...)` 
**Then** the resulting handle pointer is wrapped in a Dart `Pointer<Void>`
**And** the handle is stored in an internal `Map<int, Pointer<Void>>` keyed by a worker-assigned `handleId`
**And** the response back to main contains `{"handle_id": <id>}` (NOT the raw pointer — pointers are worker-internal).

**Given** a handle is no longer needed
**When** the main isolate sends a `CloseRepoCommand { handle_id: 42 }`
**Then** the worker calls `zanshin_repo_close(handle_ptr)` and removes the entry from its map.

**Given** `NativeFinalizer` registration on the main-isolate side
**When** a `RepoHandle` Dart class wraps a `handle_id`
**Then** the class registers a `NativeFinalizer` (pointing at a finalize function that sends a `CloseRepoCommand` to the worker)
**And** garbage collection of the wrapper triggers the close (belt-and-suspenders per AR-AD-2).

**Given** unit tests
**When** they run
**Then** they: spawn the worker, send `OpenRepoCommand` with a fixture path, receive a `handle_id`, send `StatusCommand`, assert the response JSON parses cleanly
**And** also test: invalid command, error propagation, isolate shutdown.

**Edge case — Isolate startup failure:**

**Given** `Isolate.spawn` fails (rare)
**When** it occurs
**Then** `ZanshinWorker.start()` returns a `Future` that completes with an error
**And** the main isolate can retry or surface the failure.

**Edge case — Command sent after close:**

**Given** the worker has been closed
**When** `send(cmd)` is called
**Then** it throws `StateError("Worker is closed")` immediately
**And** does not silently drop the command.

**Edge case — Async events from FFI:**

**Given** the watcher fires events independently of commands
**When** the worker receives a `WatcherEvent` callback from FFI
**Then** the worker forwards it to the main isolate on a separate `SendPort` (dedicated event-stream port per AR-AD-4)
**And** does NOT route it through the command-correlation map.

---

### Story 3.10: End-to-end watcher test — filesystem mutation → Dart callback

> **WIP re-sequencing (2026-06-15): DEFERRED with the watcher.** This test validates the reactive feature (filesystem mutation → Dart callback), which is not shipped in the early open/init/clone slice. It returns when the watcher (Stories 3.5 / 3.6) is rebuilt — as net-new test code, no rework.

> **WIP-rework (2026-05-17):** Keep the functional E2E pathway: real cdylib + real worker isolate, filesystem mutation triggers Dart callback. **Drop the latency assertion** (`<200ms` test bound) — NFR-P-4 is a soft target in WIP. **Add** a watcher-storm sub-test (5 rapid mutations → bounded channel drop-oldest behaviour observed; consumes the dropped Story 7.8 / Murat Szenario-2). The full latency-bounded test returns in the release phase.

As a developer validating the FFI keystone end-to-end,
I want an integration test that mutates the filesystem under `.jj/repo/op_heads/heads/` and asserts that a Dart-side callback fires within 200 ms,
So that FR-RX-1 (< 100 ms budget with 100 ms CI slack), FR-RX-2 (external edit path), FR-RX-4 (recovery), and the full Rust→Dart pipeline are validated.

**Acceptance Criteria:**

**Given** `app/integration_test/watcher_e2e_test.dart`
**When** created
**Then** it imports the `ZanshinWorker` from Story 3.9 and the watcher-event stream interface.

**Given** the test setup
**When** the test runs
**Then** it:
1. Extracts the `tiny-3-commits` fixture into a tmpdir
2. Spawns the worker isolate
3. Sends `OpenRepoCommand(fixture_path)`
4. Subscribes to the watcher-event stream
5. Manually `touch`-es a file inside `<fixture_path>/.jj/repo/op_heads/heads/`
6. Asserts a `WatcherEvent::OpHeadsChanged` event arrives within 200 ms (NFR-P-4 + CI slack).

**Given** the test
**When** an event arrives
**Then** the assertion includes the event payload structure (parsed JSON matches `progress.v1.schema.json` or the dedicated watcher schema if one exists)
**And** the `paths` field includes the touched path.

**Given** the FR-RX-4 recovery test
**When** the test:
1. Sets up a watcher
2. Unmounts the watched path (or simulates it via `mv` to a tmp location and back)
3. Re-mounts (or `mv` back)
4. Touches a file
**Then** the watcher recovers and the event arrives within 500 ms post-remount (loose bound for recovery)
**And** no process restart was required.

**Given** the FR-RX-2 external-edit test (requires Watchman to be installed in CI)
**When** an external editor writes to a tracked file in the working copy
**Then** Watchman triggers a jj auto-snapshot (via jj's `fsmonitor.backend = "watchman"` config)
**And** the new op causes an `op_heads` mutation
**And** the watcher event arrives within 500 ms end-to-end (NFR-P-6).
**Note:** if Watchman is not available in CI, this test is marked `@TestOn('mac-with-watchman')` and skipped with a warning rather than failed.

**Given** the test runs in CI
**When** the macOS runner has Watchman pre-installed (per the GitHub Actions setup in Epic 1 Story 1.9, extended with a Watchman install step)
**Then** the FR-RX-2 test runs and passes
**And** if Watchman isn't installed, the test logs a clear skip reason.

**Given** the test
**When** it completes (passes or fails)
**Then** it cleans up: closes the worker, drops the fixture tmpdir, unregisters watcher callbacks.

**Given** flakiness mitigation
**When** the test fails intermittently
**Then** it retries up to 2 times on the 200ms assertion (since CI noise occasionally exceeds the budget)
**And** the retry behaviour is logged in test output so flake patterns are visible.

**Edge cases:**

**Given** the test runs concurrently with other tests
**When** multiple watchers are active
**Then** they don't interfere (each watcher has its own debouncer + mpsc channel — per Story 3.5).

**Given** the test runs on a slow CI runner
**When** the 200ms assertion is exceeded by 50ms
**Then** the test fails with a clear "watcher event arrived in 250ms — exceeds 200ms budget" message
**And** the team investigates rather than relaxing the budget.

**Given** the test on a network-mounted filesystem (theoretical)
**When** events fire on the network mount
**Then** behaviour is documented in `docs/watchman-setup.md` (network mounts may have higher latency)
**And** the budget is not enforced on network mounts.

---

## Epic 4: `zanshin-graph` — DAG Lane Assignment *(2026-10-01: the lane crate was removed in 4.12)*

Compute commit-graph lane assignments for arbitrary jj DAGs and expose render-ready FlatBuffers (ADR-0001) via the FFI surface. Hit the < 1s lane-cache budget (FR-GR-5 / NFR-P-1 sub-budget) on the 10k-commit fixture and provide O(slice-size) render-slice responses. *(2026-09-26: reopened for Stories 4.10–4.12, which replace the render-slice with the whole revset's topology plus lazy content and move the layout to Dart; see the note before Story 4.10.)*

### Story 4.1: Lane-assignment algorithm (`lane.rs`)

As a Rust developer implementing the lane algorithm,
I want `crates/zanshin-graph/src/lane.rs` implementing the "straight branches" lane-assignment algorithm (pvigier-style) over jj-lib's `default_index` and `dag_walk`,
So that the resulting rows correctly position commits in lanes for GitKraken/SourceTree-style rendering (FR-GR-1).

**Acceptance Criteria:**

**Given** `crates/zanshin-graph/src/lane.rs`
**When** created
**Then** it defines `pub struct Row { pub change_id: ChangeId, pub lane: u32, pub edges_below: Vec<u32>, pub color_idx: u32, pub parents: Vec<ChangeId> }`
**And** `pub fn assign_lanes(repo: &Repo) -> Result<Vec<Row>, GraphError>`.

**Given** the function walks the DAG
**When** invoked
**Then** it iterates commits in reverse-chronological order via jj-lib's `dag_walk::dfs_ok(...)` or equivalent (NOT via gix-commitgraph)
**And** uses `jj_lib::default_index::DefaultReadonlyIndex` for parent/child lookups (per Architecture §"Pattern constraints").

**Given** a simple linear DAG (3 commits)
**When** `assign_lanes` runs
**Then** all three commits are on lane 0
**And** `edges_below` for each row contains `[0]` (the edge to the parent in the same lane).

**Given** a DAG with a fork-then-merge pattern
**When** `assign_lanes` runs
**Then** the fork point assigns the second branch to a free lane (e.g., lane 1)
**And** the merge point closes the temporary lane and returns to lane 0
**And** `edges_below` correctly represents the cross-over at the merge point.

**Given** the "straight branches" strategy
**When** a branch has many sequential commits before merging
**Then** all of those commits stay in the same lane (the branch "stays straight")
**And** lanes are not reassigned mid-branch.

**Given** `color_idx`
**When** assigned per lane
**Then** lanes are assigned colors from a small palette (e.g., 0..7) in a stable, deterministic way
**And** the same lane always gets the same color across multiple lane-cache rebuilds.

**Given** the algorithm
**When** it encounters anonymous changes (no description, no bookmark)
**Then** they are still placed on a lane normally
**And** the resulting row is included in the output.

**Given** the algorithm
**When** it encounters working-copy commits (jj-specific — these are tracked in jj's index but not in Git's)
**Then** they appear in the output (because we use jj's `default_index`, not gix-commitgraph)
**And** are placed on a lane like any other change.

**Given** unit tests in `crates/zanshin-graph/tests/lane.rs`
**When** they run
**Then** they cover: linear DAG (single lane), simple fork (two lanes), fork+merge (lane reclaim), nested forks, multiple parallel branches.

**Edge cases:**

**Given** a DAG with octopus merges (3+ parents)
**When** processed
**Then** all parent edges are recorded in `edges_below`
**And** lane assignments handle the wider crossing pattern without panicking.

**Given** a DAG with many roots (no common ancestor)
**When** processed
**Then** each root gets its own initial lane
**And** the output is well-formed.

**Given** a DAG with millions of commits (theoretical — far beyond NFR-P-1's 10k baseline)
**When** processed
**Then** the algorithm completes but may exceed the 1s budget — performance characterization is `O(n)` plus the cost of jj-lib's DAG walk
**And** Story 4.7 (deferred FR-GR-6) addresses very-large repos via checkpoint-caching.

---

### Story 4.2: JSON output + `graph.v1.schema.json`

> **Transport reconciled to FlatBuffers (2026-06-20):** This story's premise — `serde`-JSON output validated against `schemas/graph.v1.schema.json` with `jsonschema`/`json_schema`, `additionalProperties:false`, and minor-version bumps — predates [ADR-0001](../../docs/adr/0001-ffi-data-transport-flatbuffers.md) and is superseded. The graph crosses the FFI boundary as a FlatBuffers `GraphSlice` table (rows with `change_id`, `lane`, `edges_below`, `color_idx`, `parents`, plus `total_rows`) added to `schemas/envelope.fbs`'s `Payload` union — defined in `schemas/*.fbs`, **not** JSON Schema; no `schema_version`, no `.v1` infix, no version-bump rule (WIP: edit in place, regenerate via `cargo make codegen`, callers update). Drop `serde::Serialize`; the wire contract is the typed FlatBuffers accessors + the `Verifier` (compile-time wrong-shape detection). The < 5 MB / < 200 ms numbers remain soft design targets (perf-gate deferred). This story effectively merges into the FlatBuffers schema work consumed by Story 4.6.

> **Delivered standalone (2026-08-22, Story 4.2 done):** shipped as its own story, not merged into 4.6. The wire shape follows Story 4.1's `Row`/`RowEdge` (commit-id keyed, merged edges — **not** the `change_id` / `edges_below` / `parents` columns named above): `GraphEdgeKind : byte { Direct, Indirect, Missing }`, `GraphRowEdge { target, target_lane: uint, kind }` (`target_lane` is meaningful only when `kind != Missing` — `flatc 25.12.19` rejects optional scalars for Dart, so Rust writes `0` and the Dart model exposes `int?` null), `GraphRow { commit_id, lane, color_idx, edges: [GraphRowEdge] }`, `GraphSlice { rows, total_rows }` appended last to `Payload` in `schemas/envelope.fbs`. Rust builder `zanshin_ffi::graph::graph_slice_to_envelope(&[Row]) -> Vec<u8>` in `crates/zanshin-ffi/src/graph.rs` (no `zanshin-graph/src/output.rs`; `zanshin-graph` stays FlatBuffers-free), Dart models + decoder in `packages/zanshin_core/lib/src/ffi/graph.dart`; round-trip / decode-contract tests on both sides. The extern fn + worker command remain Story 4.6. Spec: `_bmad-output/implementation-artifacts/spec-4-2-graph-slice-flatbuffers-payload.md`; ABI: `docs/ffi-abi.md` § "GraphSlice payload (Story 4.2)".

As a Rust developer producing serializable output,
I want `crates/zanshin-graph/src/output.rs` serializing rows to JSON conforming to `schemas/graph.v1.schema.json`,
So that the FFI surface and any downstream consumer parses the graph data with schema validation (FR-GR-2, AR-AD-3).

**Acceptance Criteria:**

**Given** `schemas/graph.v1.schema.json`
**When** created
**Then** it defines a top-level object: `{ schema_version: "1.0", rows: Array<Row>, total_rows: number }`
**And** `Row` matches Story 4.1's struct: `{ change_id: string, lane: number ≥ 0, edges_below: Array<number>, color_idx: number, parents: Array<string> }`.

**Given** `crates/zanshin-graph/src/output.rs`
**When** created
**Then** it implements `Row::serialize` (via `serde::Serialize` derive — auto)
**And** a wrapper struct `GraphSlice { schema_version: &'static str, rows: Vec<Row>, total_rows: u32 }` serialized at the FFI boundary.

**Given** a serialized GraphSlice
**When** validated against `schemas/graph.v1.schema.json`
**Then** the validation passes (Rust test using `jsonschema` crate).

**Given** the Dart side (via Story 3.9's worker, when wired in Story 4.6)
**When** parsing a graph JSON response
**Then** it validates against `schemas/graph.v1.schema.json` (Dart's `json_schema` package)
**And** the validation passes (parity with Rust validation per AR-P-7).

**Given** the schema's `additionalProperties: false`
**When** any future story adds a field without bumping the schema version
**Then** the validation fails — forcing a minor bump (e.g., 1.0 → 1.1) per AR-AD-3.

**Given** a 10k-row GraphSlice serialized to JSON
**When** measured
**Then** the JSON output is < 5 MB (compact representation; no pretty-printing)
**And** the serialization completes in < 200 ms.

**Given** unit tests
**When** they run
**Then** they: build a small graph (3 rows manually), serialize, parse, assert round-trip equality
**And** validate the serialized output against the committed schema.

**Edge cases:**

**Given** an empty graph (zero rows)
**When** serialized
**Then** `{ "schema_version": "1.0", "rows": [], "total_rows": 0 }` is the output
**And** schema validation passes.

**Given** a change-id with non-standard characters (jj base32 is constrained, but defensive)
**When** serialized
**Then** the string is escaped per JSON rules
**And** parses back correctly.

---

### Story 4.3: Lane computation on demand (`cache.rs`)

> **WIP-rework (2026-05-17):** Drop the "full persistent lane-cache" framing. WIP computes lanes on demand per request, in-memory, no persistence. **Drop** op_heads-driven cache invalidation ACs, **drop** the cache-warmth assertions. The lane computation should still be fast enough for development-scale repos. Persistent cache + invalidation return in the release phase.

> **Refined by [ADR-0002](../../docs/adr/0002-repository-state-model-warm-loader-reload-per-operation.md) (2026-06-22):** The 2026-05-17 "compute on demand, no persistent cache" rework is the right direction and is now backed by prior-art research (`research/technical-vcs-gui-repo-state-cache-vs-reload-research-2026-06-22.md`) — the only mature jj-lib GUI (GG) renders the graph from a **lazy revset stream** and holds no materialized graph. **Surviving inconsistency to fix:** the user story and the "rebuild on every `op_heads` change" AC below still carry the persistent-cache framing the 2026-05-17 note retired. Reconcile per ADR-0002 + the adoption story (**Story 3.11**): compute/stream lanes against the head-resolved repo; the op-heads watcher *triggers a re-derive*, it does not invalidate a long-lived authoritative cache. **DECIDED (ADR-0002 AC-4, 2026-06-22): stream, no materialized cache.** A jj-lib spike derives the full graph at 10k in ~3 ms and streams the first render page in ~27 µs (Story 3.11), so re-deriving on op-id advance is trivially cheap and a materialized lane cache is unnecessary. The body ACs below (build/rebuild a materialized `LaneCache`) are **superseded** — this story's create-story rewrite implements a lazy revset stream (`stream_graph` + `TopoGroupedGraph`, GG model).

> **Delivered (2026-08-22, Story 4.3 done — as the lazy stream, not `cache.rs`):** no `LaneCache`, no `Map<ChangeId, usize>`, no `rebuild`, no `cache.rs`. Two pieces: (1) `zanshin-jj` gained the jj-lib-free revset **graph stream** `Repo::walk_graph(revset, prioritize, visit: impl FnMut(GraphNode) -> ControlFlow<()>) -> Result<ControlFlow<()>, RevsetError>` (`crates/zanshin-jj/src/graph.rs`; types `GraphNode { id: CommitId, parents: Vec<GraphEdge { target, kind: Direct|Indirect|Missing }> }` + `pub const DEFAULT_GRAPH_PRIORITIZE = "present(@)"`), built on the exact `jj log` pipeline at v0.42.0 — `TopoGroupedGraph::new(revset.stream_graph(), |id| id)` + `prioritize_branch` for every commit of `prioritize ∩ revset` (user-expression intersection before resolution, as `revsets.log-graph-prioritize`) — re-resolved to head per call, streaming with early exit; `revset.rs` was split into crate-private `parse_revset` + `evaluate_revset` helpers shared with `resolve_revset` (behaviour unchanged). (2) `zanshin-graph` gained `src/stream.rs`: `stream_lanes(repo, revset, prioritize, sink: impl FnMut(Row) -> ControlFlow<()>) -> Result<ControlFlow<()>, LaneStreamError { Revset, Graph }>` mapping that stream into the 4.1 `GraphNode` and pushing it through `LaneAssigner` (`finish()` only when exhausted). **Mapping-owner decision:** `zanshin-graph` depends on `zanshin-jj` (`ffi → graph → jj`; no `jj_lib` in `zanshin-graph`). Both params are caller pass-throughs (FR-JJ-17); no FFI (4.6), no collect-all/paging (4.4). Tests: `crates/zanshin-jj/tests/graph.rs` (18, incl. re-derive-after-external-op on the same handle, corrupt/mid-stream `JjLibError`, blank `prioritize` → `ParseError`, non-working-copy-head prioritisation on medium) + `crates/zanshin-graph/tests/stream.rs` (12, incl. hand-traced tiny rows + medium invariants) + 5 inline `stream.rs` tests (`From` maps, error transparency, synthetic-walk `DanglingEdge` on `finish()`). Spec: `_bmad-output/implementation-artifacts/spec-4-3-lane-computation-on-demand.md`.

As a Rust developer caching graph state,
I want `crates/zanshin-graph/src/cache.rs` building a full in-memory lane-cache on repo-open and on every `op_heads` change (FR-GR-3),
So that subsequent render-slice calls (Story 4.4) are O(slice-size) and the < 2s repo-open budget (NFR-P-1) is achievable.

**Acceptance Criteria:**

**Given** `crates/zanshin-graph/src/cache.rs`
**When** created
**Then** it defines `pub struct LaneCache { rows: Vec<Row>, /* internal indices */ }`.

**Given** `LaneCache::build(repo: &Repo)`
**When** called on the `large-10k-commits` fixture
**Then** it builds the full cache in < 1000 ms (FR-GR-5, NFR-P-1 sub-budget from Story 2.2)
**And** the resulting cache holds 10,000 rows.

**Given** a `LaneCache` exists
**When** `op_heads` mutates (a new operation is recorded)
**Then** the cache is rebuilt via `LaneCache::rebuild(&repo)` (called by the FFI watcher dispatch — wired in Story 4.6)
**And** the rebuild also completes within the < 1s budget for the 10k fixture.

**Given** the cache structure
**When** inspected
**Then** it includes an auxiliary index `Map<ChangeId, usize>` mapping change IDs to row indices (for O(1) lookup in Story 4.4's render-slice).

**Given** the cache build
**When** called concurrently with another build (theoretical — AR-AD-2 says single-threaded, so guarded by handle ownership)
**Then** behaviour is documented: callers serialize via the worker isolate (per AR-AD-2)
**And** the function is not internally locked.

**Given** unit tests in `crates/zanshin-graph/tests/cache.rs`
**When** they run
**Then** they: build the cache on the `tiny-3-commits` fixture, assert all rows present, then mutate the fixture (add an op via jj-lib), rebuild, and assert the new row appears.

**Given** a benchmark (`cargo bench` or a perf-test marked `#[ignore]` for normal runs)
**When** run against `large-10k-commits`
**Then** the build completes in < 1000 ms on the reference hardware (M1 Max baseline per Story 2.2)
**And** memory usage is < 100 MB for the cache itself.

**Edge cases:**

**Given** an empty repo (just the root commit)
**When** the cache is built
**Then** the result is a single-row cache
**And** no panic.

**Given** an op_heads mutation that doesn't actually change the DAG (e.g., a no-op operation)
**When** detected before rebuilding
**Then** an optimization (skip rebuild if `op_heads` hash unchanged at the DAG-affecting level) MAY be implemented — but this story does the unconditional rebuild
**And** future iteration may add optimization based on actual usage patterns.

---

### Story 4.4: Return-all-lanes-for-revset API (`slice.rs`)

> **WIP-rework (2026-05-17):** Drop the windowing/pagination ACs. WIP returns all lanes for the resolved revset in one call. Render-slice with O(slice-size) and viewport optimization return in the release phase, once UI scroll patterns are understood.

> **Delivered (2026-08-23):** `crates/zanshin-graph/src/slice.rs` ships `pub fn collect_lanes(repo: &zanshin_jj::Repo, revset: &str, prioritize: &str) -> Result<Vec<Row>, LaneStreamError>` — a collecting sink over the 4.3 `stream_lanes` stream (re-resolve to head per call, `jj log` order, `finish()` run, both parameters caller pass-throughs). There is no `LaneCache`, no `render_slice`, no `start`/`count`/`limit`/`reversed`, no paging struct and no `total_rows` field: `Vec<Row>` is the return type and the FFI `GraphSlice` builder (4.2) derives `total_rows == rows.len()`. Windowing stays deferred past WIP; a future page composes as an early-exit sink on `stream_lanes`, never a scan over held rows (ADR-0002 AC-4). The CLI's `--limit`/`--reversed` are deliberately NOT passed through (presentation/paging knobs dropped together with windowing; a consumer wanting a prefix uses `stream_lanes` + `Break`) — revisit when windowing returns. Tests: `crates/zanshin-graph/tests/slice.rs` (tiny exact rows + equality with a `stream_lanes` collection for both prioritize values, medium invariants + determinism, empty revset, parse errors incl. blank `prioritize`, resolution errors for either parameter). The `render_slice` ACs below are superseded. **2026-09-26 (Ralph):** windowing does not return — FR-GR-4 / NFR-P-2 were amended to the complete topology plus lazy content (Stories 4.10–4.12), and `collect_lanes` itself goes with Story 4.12's decision on the lane path.

As a Rust developer serving paginated graph slices,
I want `crates/zanshin-graph/src/slice.rs` implementing `LaneCache::render_slice(start: u32, count: u32) -> GraphSlice` in O(slice-size) time,
So that scrolling through the graph UI is performant regardless of repo size (FR-GR-4, NFR-P-2).

**Acceptance Criteria:**

**Given** `crates/zanshin-graph/src/slice.rs`
**When** created
**Then** it implements `pub fn render_slice(cache: &LaneCache, start: u32, count: u32) -> GraphSlice`.

**Given** a cache with 10,000 rows
**When** `render_slice(cache, 5000, 100)` is called
**Then** it returns a `GraphSlice` with 100 rows starting at index 5000
**And** the call completes in O(100) time — NOT a scan of the full cache.

**Given** the implementation
**When** inspected
**Then** it uses simple `&cache.rows[start..end]` indexing (Vec slicing is O(1) + count for the clone into the response struct)
**And** no full-cache iteration occurs.

**Given** `render_slice(cache, 9990, 1000)`
**When** called (count exceeds available rows)
**Then** it returns rows 9990..10000 (clamped, count=10)
**And** does not panic on the over-large count.

**Given** `render_slice(cache, 20000, 100)`
**When** called (start exceeds cache size)
**Then** it returns an empty `GraphSlice { rows: [], total_rows: 10000 }`
**And** does not panic.

**Given** `render_slice(cache, 0, 100)`
**When** called
**Then** it returns the first 100 rows
**And** is the canonical "top of graph" query.

**Given** unit tests in `crates/zanshin-graph/tests/slice.rs`
**When** they run
**Then** they cover: middle slice, end slice (count > available), out-of-range start, empty cache slice.

**Edge cases:**

**Given** `count = 0`
**When** `render_slice` is called
**Then** it returns an empty `GraphSlice`
**And** does not error.

**Given** very large `count` (e.g., 1_000_000)
**When** called
**Then** it returns at most `cache.rows.len() - start` rows (no allocation beyond what's needed)
**And** the call completes proportional to the actual returned count.

---

### Story 4.5: ~~10k-commit performance test~~ — DELETED (WIP-rework 2026-05-17)

> **Why deleted:** No perf-gate enforcement in WIP, and the `large-10k-commits` fixture itself is dropped (Story 2.1 SHRINK). Instead: a small algorithmic-correctness test on ~100 commits (covered as a sub-test inside Story 4.1) catches dumb regressions cheaply. Full 10k-commit perf test returns in the release phase.

<!-- Original AC block (full perf benchmark, CI slack budget, hardware variance handling) removed; consult git history if re-introducing. -->

### Story 4.5-OLD: 10k-commit performance test

As a developer enforcing FR-GR-5 / NFR-P-1 sub-budget,
I want an integration test that builds the lane-cache for the `large-10k-commits` fixture and asserts the build completes in < 1000 ms,
So that performance regressions are caught at PR time, not at release time.

**Acceptance Criteria:**

**Given** `crates/zanshin-graph/tests/perf.rs`
**When** created
**Then** it defines a `#[test]` (NOT `#[ignore]` — runs in CI) that:
1. Extracts the `large-10k-commits` fixture
2. Opens the repo via `zanshin-jj`
3. Times `LaneCache::build(&repo)`
4. Asserts elapsed time < 1500 ms (CI slack on top of the < 1000ms budget — Story 2.2 reference hardware buffer)

**Given** the test runs in CI on `macos-latest`
**When** the build takes 1200 ms (within slack)
**Then** the test passes
**And** the CI log shows the actual timing in milliseconds.

**Given** the test runs locally on a slow machine
**When** the build takes 1800 ms (exceeds slack)
**Then** the test fails with "lane-cache build: 1800 ms exceeds 1500 ms threshold"
**And** the developer investigates either a regression or a hardware variance.

**Given** the test
**When** measured 5 times in the same test run (warm cache)
**Then** subsequent builds may be faster
**And** the test reports the first (cold) timing as the canonical measurement.

**Given** a CI runner with unusually high variance
**When** the timing fluctuates between 800–1400 ms across runs
**Then** the slack value (1500 ms threshold against 1000 ms target) absorbs this variance
**And** if variance persistently exceeds the slack, the CI workflow is refactored (separate perf runner, fewer concurrent jobs, etc.) — not the budget.

**Given** the test logs detailed timings
**When** it runs
**Then** it outputs:
- Repo open time
- jj-lib `default_index` initialization time
- DAG walk time
- Lane assignment time
- Total time
**And** each component is comparable to its sub-budget allocation.

**Edge case — Test runs on incompatible hardware:**

**Given** the test runs on an extremely slow VM (e.g., container with limited CPU)
**When** the timing is dominated by hardware
**Then** the developer adds a `#[cfg(not(slow_ci))]` gate
**And** alternative CI configuration ensures perf tests run on adequate hardware.

**Given** the test detects severe regression (> 2x slowdown)
**When** caught
**Then** the failure message includes the previous expected timing and a suggested investigation: "did jj-lib upgrade? did `imara-diff` change behaviour? — see `docs/perf-budgets.md`".

---

### Story 4.6: FFI wrapper (`zanshin-ffi/src/graph.rs`)

> **Transport reconciled to FlatBuffers (2026-06-20):** The `*mut c_char` signatures, `data = {"graph_handle":"<hex>","total_rows":n}`, and `schemas/graph.v1.schema.json` / `jsonschema` ACs below predate [ADR-0001](../../docs/adr/0001-ffi-data-transport-flatbuffers.md) and are superseded. `zanshin_graph_build` / `zanshin_graph_slice` return `*mut ZanshinBuf` (FlatBuffers `Envelope` token, freed via `zanshin_buffer_free_token`); handles cross inside the payload as `ulong` scalar fields (`graph_handle`, `total_rows`); `zanshin_graph_close(graph_handle: u64)`. The slice is the `GraphSlice` payload (Story 4.2, now `.fbs`). `start` / `count` stay plain `u32` scalars. Tests read via generated typed accessors + the `Verifier` — no `jsonschema`.

> **Delivered (2026-08-23, Story 4.6 done):** ONE extern fn — `zanshin_graph_slice(handle: u64, revset: *const c_char, prioritize: *const c_char) -> *mut ZanshinBuf` in `crates/zanshin-ffi/src/graph.rs` — borrowing the `RepoSession` and passing both caller-supplied expressions through to `zanshin_graph::collect_lanes` (Story 4.4), serialised by the existing 4.2 builder `graph_slice_to_envelope`. **No** `zanshin_graph_build` / `zanshin_graph_close`, no graph handle, no `LaneCache` (ADR-0002 AC-4: nothing to build/rebuild/close), and no `start` / `count` scalars (4.4 delivered return-all; `total_rows == rows.len()`). The "watcher → rebuild + close old handle" AC is superseded: the graph is re-derived from head on every call and the worker holds no graph state; the UI re-requests on `OpHeadsChangedEvent` (Story 3.6 event stream). Dart: `GraphSliceCommand(handleId, revset, prioritize)` (no `GraphBuildCommand`), `ZanshinWorker.graphSlice`, `RepoHandle.graphSlice({revset, prioritize = defaultGraphPrioritize})` (CLI default `present(@)` pre-filled, editable, FR-JJ-17; `none()` = no prioritisation). New registry codes `jj.revset_parse_error`, `jj.revset_resolution_error`, `graph.dangling_edge` (+ the existing `ffi.*` / `jj.jj_lib_error`). Integration tests (`crates/zanshin-ffi/tests/graph_ffi.rs`) read typed accessors + the `Verifier`, compare against a `collect_lanes` oracle, and include the re-derive-after-external-jj-lib-op test via the new `test_helpers::add_commit_off_root`; a real-cdylib Dart worker test (`packages/zanshin_core/test/worker/graph_test.dart`) credits the extern fn.

As a Dart caller wanting to fetch graph data,
I want `crates/zanshin-ffi/src/graph.rs` exposing `zanshin_graph_build` (called at repo-open) and `zanshin_graph_slice(handle, start, count)` returning JSON envelopes,
So that the worker isolate (Story 3.9) gets graph data via the standard envelope pattern.

**Acceptance Criteria:**

**Given** `crates/zanshin-ffi/src/graph.rs`
**When** created
**Then** it defines:
```rust
#[no_mangle]
pub unsafe extern "C" fn zanshin_graph_build(repo_handle: *mut c_void) -> *mut c_char;
#[no_mangle]
pub unsafe extern "C" fn zanshin_graph_slice(graph_handle: *mut c_void, start: u32, count: u32) -> *mut c_char;
#[no_mangle]
pub unsafe extern "C" fn zanshin_graph_close(graph_handle: *mut c_void);
```
**And** all wrap via `envelope::catch(|| { ... })`.

**Given** `zanshin_graph_build(repo_handle)`
**When** called
**Then** it: validates the repo handle, calls `LaneCache::build(&repo)`, boxes the cache via `handle_into_raw`, returns an envelope with `data = {"graph_handle": "<hex ptr>", "total_rows": <n>}`.

**Given** `zanshin_graph_slice(graph_handle, start, count)`
**When** called
**Then** it: validates the graph handle, calls `cache.render_slice(start, count)`, serializes to JSON, returns the envelope.

**Given** the watcher integration
**When** an `OpHeadsChanged` event fires (per Story 3.6)
**Then** the worker isolate calls `zanshin_graph_build` again to rebuild the cache
**And** the previous graph handle is closed via `zanshin_graph_close`.

**Given** `cargo make codegen`
**When** run after this story
**Then** `zanshin_ffi.h` and `bindings.dart` contain the new functions.

**Given** integration tests
**When** they run
**Then** they: open a fixture repo, call `zanshin_graph_build`, parse the envelope, call `zanshin_graph_slice(0, 10)`, validate the JSON against `schemas/graph.v1.schema.json`.

**Given** Dart worker isolate command additions in `commands.dart`
**When** updated
**Then** it adds `GraphBuildCommand(repo_handle_id)` and `GraphSliceCommand(graph_handle_id, start, count)` to the sealed `WorkerCommand` hierarchy.

**Edge cases:**

**Given** `zanshin_graph_slice` is called with `graph_handle` from a prior repo-open after that repo was closed
**When** the call occurs
**Then** it returns `ffi.invalid_handle` (the graph handle wraps a `LaneCache` that holds an `Arc<Repo>`-equivalent or the cache copies enough state — but is now stale).
**Decision:** the cache holds owned data (Vec<Row>), so it remains valid even after the source repo is closed
**And** the Dart side is responsible for closing graph handles when no longer needed.

**Given** rapid `op_heads` mutations causing repeated rebuilds
**When** they happen
**Then** the watcher's debouncing (50ms per Story 3.5) absorbs bursts
**And** the worker isolate processes one rebuild at a time (per AR-AD-2 single-threaded).

---

### Story 4.7: ~~[Deferred P2] Checkpoint-caching for very large repos~~ — DELETED (WIP-rework 2026-05-17)

> **Why deleted:** Already marked P2-deferred; with WIP scope cuts there's no reason to keep the stub.

As a Rust developer planning for post-0.1 work,
I want a story stub for FR-GR-6 (checkpoint-caching beyond the 10k baseline),
So that the deferred work is visible in the backlog without being implemented in 0.1.

**Status:** Deferred to post-0.1 (P2 per PRD §4.3).

**Acceptance Criteria (stub for future implementation):**

**Given** a repo with 100k+ commits
**When** the lane-cache is needed
**Then** an incremental / checkpoint-based caching strategy avoids the full O(n) rebuild on every op_heads change
**And** the design is documented in `docs/perf-budgets.md` (or a future ADR) before implementation begins.

**Given** the deferred status
**When** any developer tries to start this work
**Then** they first open an issue, get scope approval, and align with the post-0.1 milestone plan
**And** the story's acceptance criteria are elaborated at that time.

**Out of 0.1 scope:** No implementation work in this story until post-0.1.

---

### Story 4.8: CLI-parity log rows — metadata-enriched, self-contained `GraphSlice` rows

As a Rust developer completing the graph payload,
I want every `GraphRow` to carry the display metadata `jj log` shows plus the lanes passing through it,
So that the (out-of-scope) Flutter log view renders from ONE `zanshin_graph_slice` call, with no window in which an external `jj` operation can make a row's lanes and its content disagree.

> *(2026-09-30, Story 4.10: the commit-graph view renders from the topology call (`Repo::graph_topology`, on the wire in Story 4.12) plus the op-pinned content call `zanshin_commit_contents` (Stories 4.10–4.12); the slice keeps its one-call rows until 4.12 decides its fate.)*

> **Delivered (2026-08-23, Story 4.8 done):** spec + parity catalog at `_bmad-output/specs/spec-4-8-log-rows-cli-parity/` (`SPEC.md` + `cli-log-parity.md`, both read from the jj monorepo at the pinned tag `v0.42.0`).
>
> - **Metadata (CAP-1).** New `crates/zanshin-jj/src/commit_meta.rs`: `pub struct CommitMeta` (change id + `change_id_prefix_len` / `commit_id_prefix_len` / `change_offset`, author name+email, committer timestamp, `bookmarks`/`tags` as `CommitRef { name, remote: Option<String>, synced, conflicted }`, `working_copies`, and the `working_copy` / `immutable` / `conflict` / `empty` / `hidden` / `divergent` / `root` flags + `description_first_line`). A crate-internal `LogMetaIndex` builds the refs reverse index, the working-copy map, the `IdPrefixIndex` and the immutable `containing_fn` ONCE per call and answers per node in amortized O(1) — no revset is evaluated per row. Extraction happens inside the SAME `load_at_head` scope and the same stream pass as the lane assignment (ADR-0002), so `Repo::walk_graph` now loads each emitted commit (`store.get_commit_async`) exactly as the CLI's render loop does.
> - **Self-contained rows (CAP-2).** `zanshin_graph::Row` gains `active_lanes: Vec<ActiveLane { lane, kind }>` — the pass-through set read off the assigner's live reservation state right after placement — plus `synthetic_elided` and the opaque `meta` pass-through. `zanshin-graph` stays `jj_lib`-free: it moves `CommitMeta` from node to row and never inspects it. Reservations now carry the kind of the edge that OPENED the segment, so a later edge joining a lane does not restyle it.
> - **Elided rows (CAP-3).** `stream.rs` splices the CLI's synthetic "(elided revisions)" rows (`ui.log-synthetic-elided-nodes`, default on): each `Indirect` edge becomes a `Direct` edge to the elided identity `(commit_id, synthetic)` and one synthetic row per collected target follows its child (duplicates are NOT deduped, matching the CLI). `synthetic_elided = false` restores the pre-4.8 TOPOLOGY — plain `Indirect` edges, no synthetic rows — not the pre-4.8 `Row` struct, which grew `active_lanes` / `synthetic_elided` / `meta` for every row.
> - **Builtin aliases (CAP-4).** `revset.rs`'s `build_aliases_map` now carries the CLI's whole builtin `[revset-aliases]` table verbatim (`trunk()` incl. its six `remote_bookmarks(exact:…, exact:…)` terms, `builtin_immutable_heads()`, `immutable_heads()`, `immutable()`, `mutable()`, `visible()`, `hidden()`), built ONCE per walk — the single seam Story 4.9 layers user/repo config over. `pub const DEFAULT_LOG_REVSET` exposes `revsets.log`; the immutable set is built in code (`immutable_heads() | root()` → `.ancestors()`), mirroring `cli_util.rs`.
> - **Surface (CAP-5).** `zanshin_graph_slice(handle, revset, prioritize, synthetic_elided: bool, short_prefixes: *const c_char)`; `schemas/envelope.fbs` gains `GraphCommitRef`, `GraphActiveLane`, `GraphRowMeta` and `GraphRow.{active_lanes, synthetic_elided, meta}` (`meta` is a nested table so Dart can see it as `null` on an elided row). `short_prefixes` mirrors the CLI's toggle: EMPTY = disabled; a parse/resolution failure is a hard error, an index-LOAD failure only warns and degrades to full-index prefixes. Dart: `defaultLogRevset` / `defaultShortPrefixes` consts, `GraphRowMeta` / `GraphCommitRef` / `GraphActiveLane` models, and `RepoHandle.graphSlice({revset, prioritize, syntheticElided = true, shortPrefixes = defaultShortPrefixes})`.
> - **Tests.** Edge states (divergent, hidden, conflicted merge, local/untracked/tracked-unsynced/tracked-synced/conflicted bookmarks, tags, second workspace, external `describe`) are constructed in-test via new `test-helpers` jj-lib write helpers — fixtures are never regenerated. No new error codes; `docs/ffi-abi.md` and `docs/rust-error-codes.md` updated in the same change.

**Acceptance Criteria:**

**Given** a repo handle
**When** `zanshin_graph_slice` is called once with the CLI default log revset
**Then** the returned rows carry, per commit row, every field of `cli-log-parity.md` § Row model, derived from a single `load_at_head` snapshot
**And** no second FFI call is needed to render the default `jj log` view.
*(2026-09-30, Story 4.10: the commit-graph view renders from the topology call plus the op-pinned content call (Stories 4.10–4.12); this AC stays true of the slice, which keeps its one-call rows until 4.12.)*

**Given** the medium fixture (octopus merge, multiple roots)
**When** the structural-invariant test runs
**Then** every routed edge's lane appears in `active_lanes` of every row strictly between its child and its landing row
**And** no assertion needs a neighbouring row's fields to validate a row.

**Given** an eliding revset
**When** `synthetic_elided` is `true`
**Then** each elided target gets one synthetic row directly after its child, with a single `Direct` edge to the real target and a real lane
**And** when it is `false`, the row sequence, edges and lanes are the pre-4.8 ones (plain `Indirect` edges, no synthetic rows) — the `Row` struct itself still carries the new `active_lanes` / `synthetic_elided` / `meta` fields.

**Out of scope:** colors/glyphs/layout (UI); windowing and `--limit`/`--reversed` (Story 4.4 decision unchanged); op-log graph parity; cryptographic-signature display; multi-line descriptions (`get_change`'s job); honoring user/repo jj-config overrides of the aliases (Story 4.9).

---

### Story 4.9: Honor jj config revset aliases + expose the effective log defaults

As a Rust developer completing the log surface,
I want every revset Zanshin parses to resolve `[revset-aliases]` from the repo's effective jj config, and the four `jj log` defaults to be readable per repo handle,
So that a user who has customized `trunk()` or `immutable_heads()` — or defined their own aliases — sees Zanshin's graph agree with their own `jj log`: same ◆ set, same default view, their aliases accepted.

> **Delivered (2026-08-24, Story 4.9 done):** spec + config reference at `_bmad-output/specs/spec-4-9-config-revset-aliases/` (`SPEC.md` + `jj-config-reference.md`), both read from the jj monorepo at the pinned tag `v0.42.0`.
>
> - **One config loader (CAP-1).** New `crates/zanshin-jj/src/config.rs` rebuilds, PER OPERATION, the layered `StackedConfig` the jj CLI would have at v0.42.0 for that workspace: jj-lib defaults + Zanshin's builtin layer (`ConfigSource::Default`) < user config (`ConfigSource::User`) < repo config (`Repo`) < workspace config (`Workspace`), flattened through `jj_lib::config::resolve`. Nothing is cached — config files change externally and the op-heads watcher does not cover them, so ADR-0002's re-resolve-per-operation rule extends to config. Story 4.8's `BUILTIN_ALIASES` Rust array is GONE: the CLI's `[revsets] log` / `log-graph-prioritize`, `ui.log-synthetic-elided-nodes` and the 7-entry `[revset-aliases]` table now live as a verbatim TOML default LAYER, so builtins and user aliases enter the `RevsetAliasesMap` through the one code path the CLI uses (all layers, lowest first, keyed by name+arity — a user's `trunk()` replaces the builtin, a user's `trunk(x)` only adds an overload).
> - **Every parse site follows (CAP-1).** `build_aliases_map(&StackedConfig)` is now infallible with the CLI's warn-and-continue semantics (`cli/src/config.rs:930-981`); both parse entry points (`revset::parse_revset`, `graph::walk_graph`) feed from it, so the graph slice, `prioritize`, `short_prefixes`, plain revset resolution and the per-row `immutable` flag all follow the user's config — the last one for free, because Story 4.8 deliberately built the immutable set in code from `immutable_heads()` rather than from the `immutable()` alias.
> - **Effective log defaults (CAP-2).** `Repo::log_defaults() -> Result<LogDefaults, ConfigError>` returns `revsets.log`, `revsets.log-graph-prioritize`, `revsets.short-prefixes` (falling back to the EFFECTIVE `revsets.log` on ABSENCE only — an explicit `""` means disabled and is returned verbatim) and `ui.log-synthetic-elided-nodes`. New extern fn `zanshin_log_defaults(handle) -> *mut ZanshinBuf`; `schemas/envelope.fbs` gains a `LogDefaults` table APPENDED to the `Payload` union (member order is the wire discriminant). Dart: `LogDefaults` model + decoder in `lib/src/ffi/log_defaults.dart`, `LogDefaultsCommand`, `ZanshinWorker.logDefaults`, `RepoHandle.logDefaults()`. FR-JJ-17 holds: these are pre-fills the UI offers, `graphSlice`'s Dart defaults stay compile-time constants, and nothing Rust-side substitutes a config value for a caller argument.
> - **Read-only, by hand (constraint).** `jj_lib::secure_config::SecureConfig` is never called: its `maybe_load_config` WRITES (creates directories, writes `metadata.binpb`, can generate a `config-id`, copies configs on repo-move detection, symlinks the legacy file away) and consumes an RNG. The `config-id` → `<config_dir>/jj/{repos,workspaces}/<id>/config.toml` indirection is resolved by reading the id and joining the path, with the legacy files as the fallback — identical config CONTENT, zero disk side effects. Two SPEC statements were corrected against the pin (NFR-R-2/ADR-0003, the CLI is the oracle): the repo config is reached through that indirection, not simply `.jj/repo/config.toml`; and `ConfigSource::Workspace` sits ABOVE `Repo` and can carry `[revset-aliases]`. Not layered: the `--config`/`--config-file` CLI layer and the `EnvBase`/`EnvOverrides` layers (provably disjoint key sets), and `config_resolver::migrate` (empty rule list at the pin).
> - **Error split mirrors the CLI, at BOTH its levels.** New registry code `jj.config_error` (malformed/unreadable config, bad `config-id`, wrong-typed value, and a `revset-aliases` key that is not a table) — never a silent fall-back to the builtins. The table level is a hard error (`cli/src/config.rs:943-953` returns `ConfigGetError::Type`); only the per-ENTRY level warns and continues (`:964-977`), so one non-string value or rejected declaration is skipped while every other alias still loads. A malformed alias DEFINITION is not caught at load time at all — jj-lib does not check `defn` at insert time (`dsl_util.rs:594-597`), so it surfaces as `jj.revset_parse_error`, and only where the alias is used.
> - **Tests.** Story 4.8's `every_builtin_revset_alias_expands_and_resolves`, `mutable_and_immutable_partition_all`, `walk_graph_accepts_the_cli_default_log_revset`, `trunk_alias_resolves_a_main_bookmark_on_origin_and_ignores_other_remotes` and `walk_graph_immutable_covers_the_ancestry_of_every_immutable_head` pass unchanged — the no-regression proof for the default layer. Config cases are constructed in-test by writing the legacy repo/workspace config files into an extracted fixture (fixtures are never regenerated), so they need no environment variable; `JJ_CONFIG` — process-global, and now the only thing keeping the developer's real config out of the stack — is repointed by exactly ONE test, alone in `crates/zanshin-jj/tests/config_user_layer.rs`, and never unset. The path-selection matrix (`JJ_CONFIG` file/dir/empty/missing, XDG vs `$HOME/.config`, `config-id` validity) is pinned by pure inline unit tests in `src/config.rs`.

**Acceptance Criteria:**

**Given** an extracted fixture whose repo config redefines `trunk()` and `immutable_heads()` and adds a custom `wip()`
**When** `zanshin_graph_slice` runs on the CLI default log revset and `resolve_revset("wip()")` is called
**Then** the row set, the per-row `immutable` flags and the `wip()` resolution all match what `jj` v0.42.0 would produce with that config
**And** with the config file removed the output is identical to Story 4.8's.

**Given** the same handle
**When** the config file changes between two calls
**Then** the second call reflects the new config without reopening the handle.

**Given** a repo config that overrides `revsets.log` and sets `ui.log-synthetic-elided-nodes = false`
**When** `Repo::log_defaults()` / `zanshin_log_defaults` / `RepoHandle.logDefaults()` are called
**Then** the overrides are returned and `short_prefixes` follows `revsets.log` on absence
**And** with no overrides the four values equal the constants Story 4.8 ships.

**Given** a malformed config file or a wrong-typed config value
**When** any revset is parsed or `log_defaults` is read
**Then** the call fails with `jj.config_error` naming the file or key — never a silent fall-back to the builtin layer
**And** a single bad `[revset-aliases]` entry only warns, and the call still succeeds.

**Out of scope:** template aliases / custom log templates (the GUI replaces the CLI's template UX); fileset aliases; config writing/editing from Zanshin; a settings surface beyond the four values; the `--config`/`--config-file` command-line layer; `user.*` config (Zanshin's commit/operation identity stays pinned in `make_settings`, so a repo's `user.name` can never take over authorship). Known residual, recorded not fixed: `RevsetParseContext.user_email` still comes from that hardcoded identity, so a jj builtin keying off the user's email resolves differently than in the CLI.

---

> **Reopened 2026-09-26 (Ralph, console session on the commit-graph view); re-planned the same day after the layout A/B.**
>
> **The view.** Ralph's near-final HTML design (`_bmad-output/implementation-artifacts/design/JJ Desktop Client.html`; Epic 10) lays commits out in rows shared by several commits:
> - Compact rows are the generation depth, Time rows are time buckets, and an experimental Free mode gives each commit a time-proportional y;
> - lanes come from greedy interval packing plus a lane-order optimisation;
> - every edge is one routed orthogonal polyline.
>
> That is not the `jj log` lane graph that Stories 4.1–4.9 compute.
>
> **Where the layout runs.** The A/B spike `spikes/graph-layout-ab` made the design's algorithm scalable and deterministic (`SPEC.md`). It implemented the algorithm in Rust and in Dart, with byte-identical outputs. Ralph decided on 2026-09-26: Dart, in `zanshin_core`'s worker isolate (spike `README.md`, "Recommendation" and "Review 2026-09-26"). Rust keeps supplying the jj data. The worker is one isolate for every open repo, so a layout delays whatever is queued behind it (4.11 item 9).
>
> **What 4.1–4.9 do not give it.** The layout needs the whole revset's topology before the first frame, and since Story 4.8 `walk_graph` loads every commit object inline. Measured 2026-09-26 (release builds, jj-lib 0.44.0):
> - the index-only topology costs 0.44–0.58 µs per commit;
> - a commit load costs 3.4–4.8 µs in a packed store, but ~122 µs on the committed loose-object `large-10k` (1.2 s for `all()`);
> - `empty` costs 0.78 ms per merge commit when no changed-path index covers it. On a real 1.4k-commit repo that is 115 ms of today's 163 ms `collect_lanes(all())`; the precondition's snapshot is another 28 ms.
>
> The time-based modes also need every commit's timestamp, which jj's index does not hold.
>
> **The three stories** (backend/bridge scope):
> - **4.10** adds an index-only topology call for the whole revset next to `walk_graph`, with timestamps on request, and a batch content call pinned to its operation. `walk_graph` and `zanshin_graph_slice` stay unchanged; the commit-graph view no longer renders from 4.8's one call.
> - **4.11** ports the spike's Dart engine into the worker isolate, with its guardrails, the input builder (priority rule, repeated-target rule), goldens and the layout command. The spike's dumper moves onto 4.10's API and stays the input builder's Rust reference.
> - **4.12** puts the topology on the wire as scalar vectors + CSR, with a lazy Dart view, id → index lookups and one copy across isolates. It replaces `zanshin_graph_slice`; whether the pvigier lane path goes with it is its open question.
> - **4.13** *(added 2026-09-28, the design update)* groups linear runs into stack nodes in the engine. The columns stay those of the ungrouped layout, so only the rows move.
>
> Row-range windowing (FR-GR-4 / NFR-P-2) is replaced, not built: the PRD was amended on 2026-09-26. FR-GR-1 / FR-GR-2 / FR-GR-5 carry dated amendment notes. The first plan's landing lanes, graph width and segment identity belonged to the lane model and are dropped.

### Story 4.10: Graph topology vs. card content — index-only topology call for the whole revset (timestamps on request) + op-pinned batch content lookup [R/bridge]
*(Added 2026-09-26, Ralph — console session on the commit-graph view; research: `_bmad-output/planning-artifacts/research/technical-commit-graph-virtualization-research-2026-09-26.md`. Re-planned 2026-09-26 after the layout A/B (`spikes/graph-layout-ab`, `README.md` incl. "Review 2026-09-26"; Ralph's decision): the layout runs in Dart on the worker isolate (4.11), so the new call carries the revset's topology instead of lanes. Backend + bridge scope. The topology's wire and lazy Dart view are 4.12, the view is Epic 10. Refined enough to build from; ACs to be written when scheduled. The commit-graph view no longer renders from Story 4.8's one call (Scope 9); `walk_graph` and `zanshin_graph_slice` themselves stay unchanged until 4.12.)*

> **Design update 2026-09-28 (Ralph; the Epic 10 header):**
> - **The full description joins the object half,** instead of its first line. The card derives the first line; 10.6's new commit callout shows the whole text beside a hovered card. It comes with the commit load the content call already does, so it costs no extra load, only bytes. The detail panel keeps `show` (Non-goals).
> - **The view half already carries what 4.13's run rule needs:** bookmarks, tags, the working copies of every workspace, `immutable`, `root` and `parent_count`. No change.
> - **No stats fields.** The design's callout also shows file counts and line counts. Ralph dropped that row (deferred-work, 2026-09-28): file counts need a tree diff per commit, and no API provides line counts.

**Motivation.** The view lays out the whole revset before its first frame (4.11: rows by depth or time bucket, lane packing, lane order). No node's position can be computed from a window. So the layout needs the complete topology of the revset, once per operation.
- **Topology is cheap, content is not.** Measured 2026-09-26 (release builds, jj-lib 0.44.0; a real 1.4k-commit repo, and `large-10k` both as committed and repacked):
  - The index-only topology walk costs 0.44–0.58 µs per commit: 0.6–0.8 ms for the real repo's `all()` (1,415 commits), ~3.3 ms at 10k.
  - Loading a commit object costs 3.4–4.8 µs per commit in a packed store: 6.7 ms for the real repo's `all()`, 33.6 ms for `large-10k` repacked.
  - On the committed `large-10k` it costs ~122 µs per commit (1.217 s), because all 30,002 of its objects are loose. Plain git (1.55 s loose, 0.14 s packed) and the jj CLI (1.32 s / 0.12 s) show the same split. The cost comes from the object store's layout, not from jj.
  - `empty` is the expensive field. `Commit::is_empty` first asks jj's changed-path index (jj-lib `commit.rs:160-165`, `is_commit_empty_by_index` `:273-280`). Only when that index does not cover the commit does it load the parents and, for a merge, merge their trees (`:260-271`): 0.78 ms per merge, measured without a changed-path index. The CLI builds one with `jj debug index-changed-paths` (`cli/src/commands/debug/index_changed_paths.rs` @ v0.44.0; jj-lib `DefaultIndexStore::build_changed_path_index_at_operation`, `default_index/store.rs:353`).
  - Today's `collect_lanes(all())` takes 163 ms on the real repo. About 115 ms of that is `empty` on its 147 merges, and 28 ms is the precondition's snapshot. The CLI's default `jj log` template pays the same merge cost (138 ms), but it prints while it streams.
- **Since Story 4.8 the topology waits for every commit.** `walk_graph` loads each commit inline for the card metadata (`crates/zanshin-jj/src/graph.rs:233-234`). The CLI loads per row too (`cli/src/commands/log.rs:275` @ v0.44.0). A GUI that lays out the whole revset first cannot afford that.
- **Timestamps are the exception.** The time-based layout modes (`time`, `free`) need every node's timestamp before layout. *(2026-09-27: Ralph made `free` the default and dropped `time`, so the default layout needs them.)* jj's index holds generation numbers, not timestamps (jj-lib `default_index/readonly.rs:692-696`); the timestamp lives in the commit object. So the timestamp is the one object field the layout needs for the whole revset (Scope 4).

**Split criterion: index/View-derived vs. object-derived.**
- **View half.** What the index and the operation's View answer. Cheap for every node, but it changes with every operation.
- **Object half.** What needs the commit object. Loaded only for the visible nodes ± a buffer. It is commit-intrinsic (the commit is content-addressed and its parents are part of it), so the view may cache it by commit id across reloads (10.11).

"Topology" below means the nodes in `jj log` order with their parent edges. The topology call carries topology + view half.

**Scope (backend + bridge).**

1. **Field split** (verified against `crates/zanshin-jj/src/commit_meta.rs:55-98`, `:161-213`). Name the split types in the spec; avoid `CommitView*`, which `commit_views.rs` already uses.
   - **View half, computed for every node:**
     - `change_id`;
     - `change_id_prefix_len` / `commit_id_prefix_len` (`IdPrefixIndex`, `:186-187`), populated once per call over `short_prefixes`;
     - `change_offset` / `hidden` / `divergent` (`resolve_change_id`, `:171-179`);
     - `immutable` (`containing_fn`, `:202`);
     - `bookmarks` / `tags` / `working_copies` / `working_copy` (View maps built once, `:126-153`, `:195-198`);
     - `root` (`:210`);
     - **new: `parent_count`,** the commit's real parent count, Missing parents included. 10.1's `parentCountOf` needs it for the merge glyph and the merge tag.
       - It is index-only. The call evaluates `revset.filtered(RevsetFilterPredicate::ParentCount(2..u32::MAX))` (jj-lib `revset.rs:579`; the `merges()` builtin is the same filter, `:1024`) and iterates it. That yields exactly the revset's merge nodes, with the predicate read from the index entry (`default_index/revset_engine.rs:1303-1308`).
       - Only on that set does it refine k = 3, 4, … the same way, until a pass is empty. `root()` gets 0, every other node 1. A bare `RevsetExpression::filter(…)` would instead test every visible commit per pass.
       - The edges cannot give it: a hidden parent can yield several Indirect edges, and a merge can yield two edges to one target (next item).
   - **Object half:** `author_name` / `author_email`, `committer_timestamp`, `conflict` (tree ids), `empty`, `description_first_line` (`:181-194`, `:203`, `:207`, `:211`). *(2026-09-28: the full `description` instead of `description_first_line`, for 10.6's commit callout; the card derives the first line. See the note at the top.)*
   - **Edges are jj facts, verbatim.** Direct / Indirect / Missing, in `TopoGroupedGraph`'s stream order, deduplicated and pruned by jj-lib only.
     - That includes repeated targets. On a real repo's default revset, a merge carries a Direct and an Indirect edge to the same parent: its second parent is hidden and descends from the first.
     - So the spike's SPEC §2 premise ("jj never yields duplicate targets, so V3 holds") is false. Normalising them is layout input (4.11 Scope 5), not topology.
   - **No synthetic "(elided revisions)" nodes.** The view draws Indirect edges dashed and has no synthetic nodes (10.1 item 2, 10.4). So the topology is `walk_graph`'s raw graph:
     - this call has no `synthetic_elided` parameter and no "meta absent iff synthetic" rule. Both stay on `zanshin_graph_slice`, unchanged;
     - what `ui.log-synthetic-elided-nodes` means for this view is 10.4 design question (a).
   - **The change id needs one extra index-only pass.** Today it is read off the loaded commit (`:185`).
     - jj-lib's `Index` trait has no commit → change-id accessor (`index.rs:101-165` @ 0.44.0), and the composite index's per-entry access is crate-private (`default_index/composite.rs:106-109`, `:131`).
     - The call therefore runs one `Revset::commit_change_ids()` pass (index-only, `default_index/revset_engine.rs:168-180`) into a commit id → change id map: O(nodes) memory, one pass per call.
   - **`all_count` = `|all()|`** for 10.7's "shown / total" (GV:223). It is counted by iterating `all()`'s positions (index-only), never with `Revset::count_estimate` (see Tests).
   - **"Index-only" means per node, not per call.** Evaluating `immutable_heads()`, the default `short_prefixes` and a `trunk()` anchor loads the ≤ 7 `trunk()` candidates once per call:
     - `trunk()` is `latest(...)` (`cli/src/config/revsets.toml` @ v0.44.0), and `Latest` loads each candidate (`revset_engine.rs:1226-1228`);
     - a user alias with filter predicates loads more.

     That is correct, and still per call.

2. **Topology call = the command.** New `Repo::graph_topology(&mut self, …) -> Result<GraphTopology, RevsetError>` (names in the spec), next to `walk_graph`.
   - **Shared setup, `walk_graph` untouched.** Factor the setup both need into a private helper: `parse_revset_with` for `revset` and `prioritize`, `prioritize ∩ revset`, `load_at_head`, `TopoGroupedGraph` (`crates/zanshin-jj/src/graph.rs:197-223`). `walk_graph`, `stream_lanes`, `collect_lanes` and `zanshin_graph_slice` keep their signatures, their per-row commit load and their full rows. 4.12 removes that path whole, or keeps it whole (its open question 1). So this story changes no existing wire, caller or test.
   - **Parameters,** all caller pass-throughs (FR-JJ-17): `revset`, `prioritize`, `short_prefixes` (as `walk_graph`), the priority `anchors` (item 3) and `with_timestamps` (item 4). Rust bakes in no default for any of them.
   - **Precondition.** It runs the pre-verb precondition exactly ONCE through `with_verb` (`repo.rs:338`, as `Repo::walk_graph` does at `:785-787`), like the CLI's one `jj log`. The precondition is Story 9.26's implicit snapshot + colocated import, the settings refresh, and Story 9.37's secure-config fix-ups.
   - **Result:**
     - the `operation_id` of the operation that its own `load_at_head` loaded (`graph.rs:201`), after the precondition's snapshot if that wrote one. It is a `zanshin_jj::OperationId` (`op_log.rs:26`);
     - the nodes in `jj log` order, each with its commit id and view half;
     - per node its edges as (target node index, kind). A Missing edge has no target;
     - `all_count`, the anchors, and the timestamps when requested.

     Details:
     - Targets are resolved to node indices after the complete pass. A non-Missing target outside the node set is `graph.dangling_edge`, as in `walk_graph`.
     - The operation id comes back in the `Ok` value, not through a side channel. `take_precondition()` / `take_warnings()` (`repo.rs:382`, `:400`) are side channels because their facts must survive an `Err`. The operation id exists only on success.
   - **Not in this story:** the spike's detached dumper (`spikes/graph-layout-ab/rust-inputs/src/jj_dump.rs`) moves to `graph_topology` in 4.11 (its item 10), together with the priority rule it needs.

3. **Priority anchors** (for 4.11's priority rule; SPEC §11.2).
   - `anchors` is an ordered list of caller-supplied revsets and a required parameter; Rust has no default. `zanshin_core` exports the editable pre-fill `["trunk()", "present(@)"]` as a documented constant, and the caller passes it explicitly (4.11 item 9).
   - Each anchor is intersected with the revset as a user expression before resolution (like `prioritize`, `graph.rs:198`) and evaluated once. The result is, per anchor, the node indices it selects, in `jj log` order. An empty list is valid.
   - The rule that turns anchors into priority classes (first-parent chains) is Dart (4.11), so it changes with a hot reload. Rust only resolves the revsets, which it must do: `trunk()` follows the user's `[revset-aliases]` (Story 4.9).
   - A malformed anchor fails the way `revset` does (`jj.revset_parse_error` / `jj.revset_resolution_error`).

4. **Timestamps for the time-based modes** (open question 1).
   - **`with_timestamps: bool`.** The caller sets it for `time` and `free`; `compact` never pays for it *(2026-09-27: `free` is the default and `time` is dropped, so every default layout sets it)*. When set, each non-root node carries its committer timestamp (epoch ms), from `store.get_commit_async`: the object load only, never `is_empty`. The root carries none (SPEC §2: `ts_ms` is null for the root; null for absence).
   - **Recommended: loaded per call (option (b)).** Every timestamped call pays the object loads:
     - 6.7 ms for the real repo's `all()` (1,399 of its 1,414 non-root commits are packed);
     - 33.6 ms for `large-10k` packed;
     - ~1.2 s for the committed loose fixture.

     The loads run inside the synchronous topology call on the worker, the one isolate that serves every open repo's commands and events (4.11 item 9, worker occupancy). The handle stays free of state, so `project-context.md`'s "the repo handle is … not a state cache" (`:232-233`) and "Don't reintroduce a materialized lane cache" (`:698-699`) stay true.
   - **Alternatives considered:**
     - (a) always carry timestamps. Compact pays too: +33.6 ms packed / +1.2 s loose at 10k;
     - (b) **the flag, loaded per call (recommended);**
     - (c) the flag + a per-handle commit id → timestamp cache on `zanshin_jj::Repo`. Commits are content-addressed, so an entry never goes stale, and after the first call only commits not seen before load.
       - It saves at most the per-call cost above: ~7 ms per reload on the real repo, ~34 ms at 10k packed; only loose stores gain ~1.2 s.
       - It costs Rust state on the handle, an ADR-0002 Addendum clause, the bound question (unbounded, or an LRU of a few `all()`s; ~0.5–1 MB at 10k), a cache witness, and dated notes at the "not a state cache" sites (Scope 9).
       - **Trigger:** adopt it when item 8's bench or a real repo shows a first timestamped topology call above ~50 ms on a packed store, or when loose commits accumulate (Zanshin never packs; deferred-work);
     - (d) a Dart-side cache in the worker, plus an op-pinned timestamp call for the misses. No Rust state, but worker state (4.11 item 9 otherwise has none), and a second call on every reload that has misses. Only the missing ids travel to Rust: all of them on the first call, ~45 B per id as hex;
     - (e) time/free only below a node count;
     - (f) lay out without timestamps and relayout when they arrive. The layout jumps under the user. Rejected.
   - **Committer, not author.** The committer timestamp is what `jj log` shows and what the spike's inputs use. Switching is open question 2.

5. **Content call = the render loop, pinned.** New `Repo::commit_contents(&self, operation_id, commit_ids) -> Vec<CommitContent>`.
   - **Shape.** It takes `&self` like `Repo::log_defaults` (`repo.rs:548`), so the type system rules out the precondition.
     - It calls `repo_loader().load_operation(..)` + `load_at(&op)` (jj-lib 0.44.0 `repo.rs:764-767`, `:732-735`), then per id `store.get_commit_async` + the object half.
     - It returns one entry per requested id, in request order.
   - **Proposed framing (open question 3): the continuation of the topology call's `jj log`**, i.e. the CLI's per-row `get_commit_async`. So it:
     - runs no precondition, no snapshot, no import, no config load and no 9.37 fix-up;
     - writes no operation and no op head;
     - leaves `take_precondition()` / `take_warnings()` untouched;
     - carries no `precondition` and no `warnings` on its envelope (add it to `Envelope`'s no-precondition list in `schemas/envelope.fbs`).
   - **Closest CLI analog.** `jj --at-op=<id> log`, where `--at-op` implies `--ignore-working-copy` (`cli/src/cli_util.rs:3696-3697`, `:3744-3745`, `:754-766` @ v0.44.0).
     - But that is a command of its own, and it does run start-up config resolution with the secure-config fix-ups (`:4543-4552`).
     - Which of the two a content page is, is open question 3.
   - **Why pinned rather than at head.**
     - `load_at_head` is not write-free. It prunes ancestor op heads, and with divergent heads it publishes a "reconcile divergent operations" merge (jj-lib `op_heads_store.rs:147-161`, `repo.rs:706-729`).
     - `load_at` writes no operation and no op head. Like any load, it may build and write the operation's index files if they are missing (`default_index/store.rs:519-560`).
     - The ids the caller passes are exactly the ids that operation indexed.
   - **Page cost** (to confirm in item 8).
     - Per id: one commit load (3.4–4.8 µs packed, ~122 µs loose) plus `empty`. Without a changed-path index covering the commit, `empty` loads the parents and, for a merge, merges their trees (0.78 ms per merge); with one, it is an index lookup.
     - The store's 100-entry LRU absorbs most parent loads, because a parent is usually a neighbouring card.
     - So a page of 60 ids costs well under 1 ms without merges, and a few ms with several.
   - **ADR impact.** This departs from ADR-0002 §2, "reads re-resolve to head" (`docs/adr/0002-repository-state-model-warm-loader-reload-per-operation.md:36`).
     - An ADR-0002 Addendum records the pinned read: a read that answers at a caller-supplied operation is pinned, not re-resolved, and returns commit-intrinsic values only (open question 4). With (c) it also records that commit-intrinsic values keyed by commit id are not repo state.
     - It goes next to the existing `## Addendum 2026-09-23` (`:98`), never by rewriting accepted text.

6. **Content error contract, in check order.**
   - (a) **Operation id: full-length hex only.** Prefixes are not resolved; the caller got the full id from the topology call.
     - Empty or non-hex → `jj.invalid_input` with the CLI's `OpsetResolutionError::InvalidIdPrefix` text, `Operation ID "<x>" is not a valid hexadecimal prefix` (jj-lib `op_walk.rs:79-81`).
     - Wrong length → `jj.invalid_input`.
     - Not `op_walk::resolve_op_for_load`: it accepts prefixes and `@`/`-`/`+` expressions, and it resolves `@` against the op heads (`op_walk.rs:91-109`).
   - (b) **Vanished operation.** `load_operation` returns `OpStoreError::ObjectNotFound` when the operation was abandoned and gc'd, e.g. by `jj op abandon` + `jj util gc`.
     - That maps to the CLI's `No operation ID matching "<id>"`. It is `NoSuchOperation` (`op_walk.rs:83-84`), which the CLI reaches through `resolve_single_op_from_store` (`:187-199`).
     - The code is a new `jj.operation_not_found` or a reused one (open question 5).
   - (c) **Commit ids.** Full ids only.
     - Empty, non-hex, or not `store.commit_id_length()` bytes → `jj.invalid_input`.
     - Valid hex that the pinned operation's index does not carry (`index().has_id`, jj-lib `index.rs:119`) → `jj.change_not_found`, with the hex in `context`. This follows the Epic 9 follow-up I precedent for a `CommitIdRef` "which no INDEXED commit carries" (`docs/rust-error-codes.md:48`).
   - (d) **The load itself** (`get_commit_async`, `is_empty`'s parent loads) → `jj.jj_lib_error`.
     - The index check before the load is what separates (c) from (d).
     - `get_commit_async` answers `ObjectNotFound` both for an id that never existed and for an object deleted from the store.
   - **Not errors:**
     - An empty id list is ok, with an empty result.
     - A head that moved after the topology call. The call answers at the pinned operation, and the values are commit-intrinsic anyway. The caller re-requests the layout on the watcher's `OpHeadsChanged` event (Stories 3.5 + 3.6).
   - **Own snapshots.** The returned `operation_id` also lets the caller recognise the event its own snapshot caused: op heads are files named by operation id (jj-lib `simple_op_heads_store.rs:79-80`).

7. **Surface in this story.**
   - **Content call, full stack.** A new `extern "C"` over a request buffer:
     - a new request table `CommitContentsRequest { kind, operation_id, commit_ids: [string] }` with its `RequestKind` member `CommitContents` appended (`envelope.fbs:70-100`; names in the spec). `ChangeIdList` (`:105-108`) is the only id-list request table today, and it carries change ids;
     - the `RequestKind` doc's "For the other 26 tables" count (`:62`) becomes 27;
     - the payload appended to the `Payload` union (`:1366-1403`);
     - `cargo make codegen` and `docs/ffi-abi.md`;
     - the `docs/rust-error-codes.md` "also emitted" clauses, plus the new code row and its `envelope.rs` constant if open question 5 says so.
   - **Content call, Dart:**
     - `ZanshinWorker` / `RepoHandle.commitContents(...)`, with a worker command and a `CommitContent` model;
     - a decoder that throws on a missing required field instead of reintroducing the `?? ''` coercions (`graph.dart:406`, `:413`, `:418-419`, `:432`);
     - interior-NUL guards, like every list argument.
   - **Topology: Rust API only.** `Repo::graph_topology` reaches the FFI and Dart in 4.12. Until then `zanshin_graph_slice` is the FFI graph path, unchanged.
   - **The one-call path stays until 4.12, unused by the view.** The commit-graph view composes the topology call with `commit_contents` at the returned operation. `app/lib` and `crates/zanshin-mcp` call neither `graphSlice` nor `collect_lanes` (verified). A test oracle that wants the CLI's full row composes the two calls the same way.

8. **Re-measure.** The numbers in the docs are stale since 4.8, and the committed fixture is unrepresentative.
   - **Bench.** A new `crates/zanshin-ffi/benches/graph_topology.rs` (`[[bench]] harness = false`).
     - zanshin-ffi reaches `zanshin-jj` and the FlatBuffers builder, and its `crate-type` includes `lib` (`crates/zanshin-ffi/Cargo.toml:19`).
     - Benches are excluded from coverage (`docs/coverage.md`).
   - **Stores:**
     - `medium` and `large-10k` as committed (loose);
     - a `git gc`-packed copy of `large-10k`, made by the bench setup in a temp dir;
     - optionally a local real repo, passed by path. Only its node count and timings are recorded, never its name or data.
   - **What it measures:**
     - the topology call total, and the precondition's share;
     - the topology with timestamps, per call. These numbers decide option (c)'s trigger (item 4);
     - the `all_count`, anchor and `parent_count` passes;
     - content pages of 60 and 200 ids, with and without merges, and with and without a changed-path index (built in the temp copy through jj-lib's `build_changed_path_index_at_operation`). The pinned `load_operation` + `load_at` share per page is broken out; it is the trigger in the Non-goals for memoising the pinned repo;
     - topology + contents for every id (the old full cost).
   - **Recording.** The numbers go into the spec, with the store kind stated for each.
   - **Fix the stale ~3 ms / ~27 µs claims:**
     - `crates/zanshin-jj/benches/graph_blueprint.rs:18-19` (label it topology-only);
     - `_bmad-output/implementation-artifacts/epic-4-context.md:26`;
     - `_bmad-output/project-context.md:13` and `:694-699`;
     - `_bmad-output/planning-artifacts/architecture.md:444`;
     - ADR-0002 `:3`, `:40`, `:89`, `:95`, through the Addendum of item 5.
   - **Also answered.** The same numbers answer the graph half of the open item "the cost of the per-verb precondition on a GUI refresh is unmeasured" (`_bmad-output/implementation-artifacts/deferred-work.md:394`).

9. **Doc sweep.**
   - **4.8's one call.** Add dated notes, in the house pattern of 9.34's note on the 9.26 matrix row:
     - at 4.8's "renders from ONE `zanshin_graph_slice` call" / "no second FFI call is needed" (Story 4.8's user story and first AC);
     - at "exactly ONE graph function" (`docs/ffi-abi.md:886-890`).

     The note says: the commit-graph view renders from the topology call plus the op-pinned content call (Stories 4.10–4.12); the slice keeps its one-call rows until 4.12 decides its fate.
   - **The pinned read against the rules.** In the same change as the ADR-0002 Addendum (item 5), add dated notes that point at it:
     - `_bmad-output/project-context.md:232-233` ("not a state cache — reads re-resolve to head"), the canonical ruleset;
     - ADR-0002 `:87` (AD-2, "reads re-resolve to head");
     - `crates/zanshin-jj/src/repo.rs:118-119` (`Repo`'s doc);
     - `crates/zanshin-ffi/src/repo.rs:695`, then regenerate `crates/zanshin-ffi/include/zanshin_ffi.h` (`:1894`).

     With (c), also the "nothing is retained across calls" docs: `crates/zanshin-jj/src/repo.rs:750` and the new call's own doc.
   - **Re-point the amendment notes.** FR-GR-4's note (`prd.md:237`; NFR-P-2's note at `:312` refers to it) and `project-context.md:14` end in "a free layout needs every row's committer timestamp in the geometry pass, which the index does not carry (epics.md Story 10.2 item 7)". Two things are stale:
     - Epic 10's re-plan renumbered 10.2, so item 7 is now "Clock";
     - every time-based mode needs the timestamps, not only free.

     Point them at this story's item 4 and at the Epic 10 header's "Backend dependencies".
   - **Not here:** the slice's "windowing deferred" statements. They are false since the PRD amendment, but they document the path 4.12 removes or rewrites, so they move to 4.12 item 8.

**Relation to FR-GR-4 / NFR-P-2.** The PRD amendment of 2026-09-26 replaces row-range windowing with complete geometry per operation plus lazy content in O(page). This story implements it.
- With the layout in Dart (4.11), the complete part is the topology: index-only, O(nodes), once per operation.
- Only the time-based modes add the object loads of item 4.

**Tests.**
- **`crates/zanshin-jj/tests/graph.rs`:**
  - **Split equivalence.** View half + object half equal `walk_graph`'s `CommitMeta` for every node on tiny + medium. Use the independent `get_change` oracle too, as `crates/zanshin-ffi/tests/graph_ffi.rs:549` does.
  - **Topology.** Node order and edges equal `walk_graph`'s stream verbatim: kinds, order, and Missing edges without a target. Every target index names the right node.
  - **Repeated target,** constructed in-test: a merge whose second parent is outside the revset and descends from the first. Both edges are kept.
  - **`parent_count`** equals `parent_ids().len()` of the loaded commit for every node; the test's oracle loads commits. The medium fixture's octopus merge gives 3 or more, and `root()` gives 0.
  - **`all_count`** equals `|all()|` as the oracle counts it, and differs from the node count on a narrowed revset.
  - **Anchors:**
    - `trunk()` selects `root()` on the fixtures, which have no remote bookmarks;
    - `present(@)` selects @;
    - an anchor outside the revset selects nothing, and an empty list yields no anchors;
    - a malformed anchor fails with `jj.revset_parse_error`.
  - **Timestamps.** Absent when not requested. When requested, each non-root node's equals the loaded commit's committer timestamp, and the root has none.
  - **Which calls load commits.** After open, remove the git object of a commit that is neither `@`, `@-` nor a `trunk()` candidate. Then:
    - the topology call without timestamps succeeds;
    - with timestamps it fails with `jj.jj_lib_error` (option (b) loads every node; under (c) this case changes with the decision);
    - the content call for that id fails with `jj.jj_lib_error`. The index still answers `has_id`, so it is not `change_not_found`;
    - content for a child of that commit fails too, because `is_empty` loads the parent.

    This is the topology call's counterpart of `walk_graph_mid_stream_store_failure_returns_jj_lib_error` (`tests/graph.rs:479`), which keeps pinning `walk_graph`'s per-row load.
  - **Operation id.** It equals the head after the call's own precondition.
  - **Pinned reads write nothing.** Edit a working-copy file, and make an external commit that moves head. Then:
    - the content call writes no operation, leaves `take_precondition()` at `None`, and returns the unchanged values;
    - the next topology call snapshots and sees both changes.
  - **Error ladder.** Every case of Scope 6: an unparsable, prefix or unknown operation id; a malformed or unindexed commit id; an empty list.
  - **Divergent op heads** stay unmerged by the content call, if test-helpers can construct them.
- **Unchanged.** `walk_graph`'s tests (`crates/zanshin-jj/tests/{graph,warnings}.rs`), `zanshin-graph`'s tests and `crates/zanshin-ffi/tests/graph_ffi.rs` pass without edits: the path they pin does not change.
- **FFI:**
  - A new integration file for the content wrapper. Ladder: null data, wrong `RequestKind`, zero handle, an interior NUL in an id. Its envelope carries no precondition and no warnings.
  - `crates/zanshin-ffi/tests/ffi_abi_doc_sync.rs`: `EXPECTED_EXPORTS` 60 → 61 (`:37`).
- **`zanshin_core`:**
  - Decode-contract tests for the content payload, including that a missing required field throws.
  - A real-cdylib worker test that calls the new extern (e.g. in `test/worker/graph_test.dart`). The extern-coverage guard (`Makefile.toml:562-589`) credits an extern only through a `zanshin_core` test.
- **API pins.** `crates/zanshin-jj/tests/api_stability.rs` pins the split types, `GraphTopology` and both new methods.
- **Coverage ratchet.** It measures Rust lines only. Changed files must not drop, and new files reach the 80 % floor. The bench lives in `benches/`, never inline in `src/`.
- **`count_estimate` quirk.** Use it for no count here.
  - In production it counts exactly (jj-lib `default_index/revset_engine.rs:196-213`).
  - jj-lib's `testing` feature makes it return `(10, None)` from ten commits on. `zanshin-jj`'s dev-dependencies switch that feature on (`crates/zanshin-jj/Cargo.toml:34`), and resolver 2 unifies it into every crate that the same `cargo test` run builds.
  - The Dart tests' cdylib is built without it, so the same code would count differently in the two suites.
  - The view's shown count, and 9.25's optional "N revisions" line, is the node count of the topology.

**Non-goals.**
- No topology wire, lazy Dart view or id → index lookups (4.12).
- No change to `walk_graph`, `stream_lanes`, `collect_lanes` or `zanshin_graph_slice`; 4.12 decides their fate.
- No layout, no priority classes, no normalisation of repeated targets (4.11).
- **No elided count N.** It depends on the revset (a parent is hidden relative to what the revset shows), so it is neither topology nor commit-intrinsic content, and 10.11's commit-id cache cannot hold it. It also needs an index walk per Missing parent. The stub needs only the Missing edge. If 10.4 design question (a) keeps N, a follow-up story adds an op-pinned count call for the visible nodes (e.g. `elided_counts(operation_id, revset, commit_ids)`).
- No row-range API.
- No detail-panel data (full description, parents, diff). That is `show` / `get_change`, Story 9.6. *(2026-09-28: the full description joins the object half anyway, for 10.6's hover callout, because `show` snapshots on every call; parents and the diff stay `show`'s.)*
- No Rust-side state across calls: no repo state, and no timestamp cache unless Ralph picks (c). ADR-0002 §2 would allow memoising the pinned `ReadonlyRepo` within one operation id; do it only if the bench shows `load_operation` + `load_at` dominating a page.
- No `--limit` / `--reversed`; the 4.4 decision stands.
- No UI.

**Depends on.** Nothing. 4.12 depends on this story. 4.11's engine does not; its layout command (item 9) and its dumper switch (item 10) do.

**Open questions (Ralph).**
1. **Timestamps** (item 4): the flag, loaded per call (recommended), or the flag plus a per-handle Rust cache (c) now, or one of (a), (d) and (e)? If (c): bounded (an LRU of a few `all()`s), or for the handle's lifetime? *(2026-09-27: Free is the default now, so every default reload pays these loads, and the flag spares only Compact. The question weighs more.)*
2. **Committer or author timestamp** (SPEC §11.3, 10.2 design question (g))? Committer is what `jj log` shows.
3. **Content-call framing** (item 5): the continuation of the topology call's `jj log` (recommended), or its own `jj --at-op` command with a config load and the fix-ups?
4. **ADR-0002 Addendum:** it covers the pinned read (and, with (c), the commit-intrinsic timestamp cache). Agreed?
5. **Vanished operation:** a new `jj.operation_not_found`, or a reused code?
6. **Anchors** (item 3): a required pass-through list with zanshin_core's exported pre-fill `trunk()`, `present(@)`, or does Ralph's answer to 4.11's priority question (SPEC §11.2) need other inputs?

**Related:**
- 3.5 + 3.6 (watcher, `OpHeadsChanged`)
- 4.4, 4.6
- 4.8 (the per-row load the new call leaves out; its one-call AC)
- 4.11 (priority rule, repeated-target normalisation, the layout command, the dumper switch, worker occupancy)
- 4.12 (the topology's wire; the fate of the slice path)
- 9.25 (Apply evaluates via `graphSlice`; "N revisions")
- 9.26 (precondition), 9.37 (secure-config fix-ups)
- 9.41 (the topology call's CLI command name is `log`; the content call resolves no config — open question 3)
- 10.1 (`parentCountOf`, `totalCount`, `operationId`), 10.2, 10.4 (design question (a)), 10.5, 10.7, 10.11, 10.12
- ADR-0002, FR-JJ-17, FR-GR-4 / NFR-P-2 (amended), FR-GR-5

> **Delivered (2026-09-30, Story 4.10 done):** spec at `_bmad-output/implementation-artifacts/spec-4-10-graph-topology-content-split-op-pinned.md` (open questions answered in `decisions-review-4-10-to-4-13.md`).
>
> - **Topology (Rust API only).** `Repo::graph_topology(revset, prioritize, short_prefixes, anchors, with_timestamps) -> GraphTopology` in the new `crates/zanshin-jj/src/topology.rs`: `walk_graph`'s parse → load → `TopoGroupedGraph` + `prioritize_branch` setup, now one shared helper (`graph.rs::LogParse` / `LogSetup`), the precondition exactly once, and per node the commit id, jj's edges verbatim (targets resolved to node indices, a Missing edge has none; a miss is the new `RevsetError::DanglingEdge`) and `TopologyMeta` — the view half plus an exact index-only `parent_count`. Change ids come from one `commit_change_ids` pass, `all_count` from iterating `all()`, anchors are intersected with the revset and mapped to ascending node indices, committer timestamps (epoch ms, never the root) only on request. The operation id it loaded comes back in the `Ok` value.
> - **Content (full stack).** `Repo::commit_contents(&self, operation_id, commit_ids) -> Vec<CommitContent>` in `commit_content.rs`: `load_operation` + `load_at`, no precondition/config/warnings, full hex ids only, request order; ladder `jj.invalid_input` → new `jj.operation_not_found` → `jj.invalid_input` → `jj.change_not_found` → `jj.jj_lib_error`. `commit_meta.rs`'s extraction is split into the view half and the object half; `walk_graph`'s `CommitMeta` is composed from both, values unchanged. FFI `zanshin_commit_contents` over `CommitContentsRequest` → `CommitContents` (61 exports), Dart `RepoHandle.commitContents` → `WarnedList<CommitContent>`, and the `defaultGraphAnchors` pre-fill.
> - **Measured** (medians, § Measurements of the spec): topology-only walk 3.1 ms @ 10k; the whole topology call 22 ms @ 10k packed (5 ms @ 1k), timestamps +31 ms packed / ~1 s loose; a 60-id content page 1.7 ms packed / 3.1 ms loose on a cold commit cache; `walk_graph(all())`, the old one-call path, 53 ms packed / 1.09 s loose. The slice path (`walk_graph`, `stream_lanes`, `collect_lanes`, `zanshin_graph_slice`) and its tests are untouched.

### Story 4.11: Dart layout engine on the worker isolate — the design's layered layout (compact / time / free) ported from the A/B spike [bridge]
*(Added 2026-09-26, Ralph — console session on the commit-graph view. Re-planned 2026-09-26. The first version (landing lanes and graph width on `zanshin-graph`'s lane model) belongs to the `jj log` lane graph the view no longer draws. The layout A/B (`spikes/graph-layout-ab`: `README.md` incl. "Review 2026-09-26", `SPEC.md`) put the design's layout in Dart on the worker isolate; that is Ralph's decision. Bridge scope: pure Dart in `packages/zanshin_core`, plus moving the spike's dumper onto 4.10's API. The painter is Epic 10. Refined enough to build from; ACs to be written when scheduled.)*

> **Product decisions 2026-09-27 (Ralph, after using the spike viewer on a real 1.4k-commit repo; the Epic 10 header):** the product ships the modes `free` (the default) and `compact`, and the lane orders `compact` (the default, item 11) and greedy. `time`, Time+gaps and `optimized` are dropped ("the rest can go").
> - **Direct consequences:**
>   - items 4 and 9: the greedy-then-optimized pair is gone, and the budget bounds the `compact` order. Whether large repos get greedy first and `compact` swapped in is open question 8;
>   - item 7's seeded rule was written for `optimized`; the `compact` order's stability is open question 8's last point;
>   - the worker requests timestamps for `free`, i.e. for every default layout (4.10 item 4);
>   - Tests: the dev tools' occupancy measurement runs behind the `compact` order.
> - **Port scope** (decided 2026-09-27, Ralph: "the rest can go"): the port carries only what ships, the modes `compact` | `free` and the orders greedy | `compact`. `time` and `optimized` stay in the spike as its reference and history. Then:
>   - item 1: `nowMs` goes (only `time` read it); `utcOffsetMin` stays only if open question 9's day buckets are accepted;
>   - item 2: byte identity with the Rust reference covers greedy in `compact` and `free`; the `compact` order's goldens come from the spike's Dart binary (item 11);
>   - Tests: the design oracle keeps `compact` mode (greedy); SPEC §7.2's `optimized` expectations and the `time` goldens drop out; the invariant runs and the worker tests cover 2 modes × 2 orders.
> - **Route geometry:** every edge now leaves the parent's top at the centre, branch-offs included (10.4 item 1). A dated SPEC §4.5 amendment changes only its geometry text; route classes, `blocked` and every output stay unchanged, so no golden changes (spike SPEC §12).
> - Answered: open question 8's default (`compact`) and its `optimized` point (dropped). Moot with `optimized` out of the product: 7. Moved: 3, into 8's stability point. Still open: 1, 2, 4, 5, 6, 9 and 8's budget and stability points. Open question 4 now concerns the default view, because D8's buses behind cards occur in `free`.
>
> **Design update 2026-09-28 (Ralph; the Epic 10 header):**
> - **No stack logic here.** Commit stacks are Story 4.13, which extends this engine after the port. The port and its goldens stay as specified.
> - **The design sample grew from 22 to 36 commits** (`graph-data.js` at `a399daf`). The spike's JS oracle reads the live design folder (`spikes/graph-layout-ab/tools/design-input.mjs:27`), so SPEC §7.2's expected results and the design goldens below would drift. Pin the oracle to the 22-commit sample of `57f259c` (a copy under the spike, or `git show 57f259c:_bmad-output/implementation-artifacts/design/graph-data.js`) before the goldens are generated. *(Done 2026-09-30: `tools/design-source.mjs` pins it through `git show`, and the oracle passes again; the spike SPEC §7.2's dated note.)* `computeLayout` itself is unchanged by the update (GV:140-225 at both commits). The 36-commit sample serves 4.13's run-rule oracle.

**Motivation.** Ralph's near-final HTML design (`_bmad-output/implementation-artifacts/design/JJ Desktop Client.html`, GV:140-225) lays commits out in rows shared by several commits:
- Compact rows are the generation depth, Time rows are time buckets, and an experimental Free mode places each node at a time-proportional y;
- lanes come from greedy interval packing with a first-parent continuation, optionally permuted to reduce crossings;
- every parent edge is routed as one orthogonal polyline: straight, merge or branch-off.

**The spike.**
- The prototype's algorithm does not scale: a factorial lane search, O(E²) crossing counts and O(n²) blocked checks (Epic 10 prototype defect 16).
- The spike's `SPEC.md` made it scalable and deterministic: O((n+E) log n), plus a budgeted lane-order search.
- It was implemented twice, in Rust and in Dart, with byte-identical outputs. That holds on 48 input × mode × order combinations, and on all 12 combinations of a real 1.4k-commit repo.
- The greedy compact and time outputs equal the design's own `computeLayout` byte for byte on the design sample.

**Where it runs: Dart, in the worker isolate** (Ralph, 2026-09-26).
- **Speed does not decide.** Rust is ~3× faster in AOT. With Dart's library sorts replaced by monomorphic ones, the gap is 1.2–1.9× outside many-lane `optimized` and 2.7–2.8× there (spike Review §2). At realistic sizes both are far below a frame. In Dart AOT:
  - the real repo's `all()` (1,415 nodes, 10–12 lanes) takes 0.15–0.62 ms in any mode and order, and its default revset (12 nodes) takes ≤ 5 µs;
  - `large-10k` takes 0.9–2.5 ms, and jj's own 15.5k-commit history 1.5–5.9 ms;
  - only `optimized` at 100k synthetic nodes with ~170 lanes exceeds 100 ms, and the ordering budget caps it.
- **Iteration decides.** The row model, the bucket ladder, the gap curve and the ordering are all still open (10.13). *(2026-09-27: the row model (Free) and the ordering (`compact`) are decided, and the bucket ladder is moot; the gap curve and Free's other constants stay open.)*
  - A Dart layout change hot-reloads into the running app. The worker is started with `Isolate.spawn` (`packages/zanshin_core/lib/src/worker/isolate.dart:160`), so it shares the UI isolate's group, and a reload reaches it (VM probe: 32 ms). Flutter's own reload cycle on Zanshin is unmeasured (spike Review §8); the manual check under Tests closes that.
  - A Rust change costs a ~6 s release rebuild of `zanshin-ffi`, plus a full app restart.
- **Rust keeps the jj data:** 4.10's topology, view facts and timestamps, over 4.12's wire.

**Scope.**

1. **Home and shape.** The engine lives in `packages/zanshin_core/lib/src/graph_layout/`: pure Dart, no `dart:ffi`, no Flutter. The engine is private to the worker: only the worker (item 9) and the tests import it. Its result view (item 9) is public API, exported from `zanshin_core.dart` by 10.12's bridge part.
   - **Port** the spike's Dart implementation: `spikes/graph-layout-ab/dart/lib/src/layout.dart` and `lane_order.dart` (~760 lines of code), plus `input.dart`'s value checks. Its JSON parser and `output.dart`'s canonical serializer become test support (Tests), not `lib/`.
   - **Input:** flat typed arrays:
     - `n`;
     - `ts` (`Int64List`) with a presence array: false for the root, and everywhere when timestamps were not requested;
     - `isRoot`;
     - `priority` (`Int32List`);
     - the parents as CSR (`parStart`, `parIdx`, `parKind`);
     - `nowMs` (time only) and `utcOffsetMin` (time; also free if open question 9 is accepted);
     - the ordering work budget.
   - **Output:** typed arrays as SPEC §3 defines them:
     - `unit`, `rows`, `lanes`;
     - per node: row, lane and col;
     - per layout edge: from, to, kind, route and blocked;
     - per bucket: kind, value, start and end. **Proposed** (open question 9, for 10.2 item 9's day axis): buckets in `free` too, one `day` bucket per local day of the clamped time T(i) (SPEC §4.2 free, step 2) under the fixed offset (D7), with `start` / `end` in 1/U units and the root in none; `nowMs` stays unused in free. It needs dated amendments to SPEC §2 (`utc_offset_min` is `time` only), §3 (buckets are filled in `time` only) and §7.3 I5 (`[]` outside `time`; and a free row can hold two days, so their ranges may share a row). They are implemented in the spike's `dart/` and its Rust reference before the goldens (item 3). The spike's viewer computes these days itself today.
   - **Naming.** Export no type called `GraphLayout`: that name is 10.1's app-side contract. The spike's internal class of that name is renamed. Names in the spec.

2. **Behaviour = SPEC, byte for byte** (SPEC §1–§4.7):
   - the modes `compact` | `time` | `free` and the orders `greedy` | `optimized`, plus the Dart-only order `compact` (SPEC §4.7, item 11), which has no Rust reference to be byte-identical with *(2026-09-27: the dated note at the top proposes porting only the modes `compact` | `free` and the orders greedy | `compact`)*;
   - integer outputs;
   - total sort keys and no dependence on hash-map iteration order;
   - floor division;
   - the budget's "stop the phase" semantics.

3. **SPEC's home.** SPEC.md becomes the engine's versioned contract (open question 5; proposed `docs/graph-layout.md`).
   - The file moves. The spike's `SPEC.md` becomes a pointer to the new path, and the spike's README, notes and tools cite the new path. There is one SPEC, never two drifting copies.
   - Every behavioural change is a dated SPEC amendment first, with its goldens.
   - The spike keeps its tools (`compare.mjs`, `fuzz.mjs`, `js_oracle.mjs`, `bench.mjs`) and its Rust implementation as the reference for a later Rust port. That port stays mechanical, about a day's work: the two implementations are 1,238 vs 1,136 lines of code.
   - **Revisit trigger** (spike guardrails): once the row model is final and stops changing, the iteration argument weakens. A port to Rust is worth it only if real repos show 50k+ rows with many lanes in a view people actually open.
   - **Architecture mapping.** `_bmad-output/planning-artifacts/architecture.md:32` and `:439` map FR-GR-* to `zanshin-graph`. They get a dated note in this story, whatever 4.12 decides: the FR-GR-1 layout lives in `packages/zanshin_core/lib/src/graph_layout/`.

4. **Guardrails** (spike README, "Guardrails for the Dart variant", "What hot reload does not do" and the Review):
   - **Flat typed arrays and CSR; no per-node objects or maps on hot paths.** The worker shares its isolate group's heap and GC with the UI isolate. The review measured no stall above noise at realistic relayout rates; keep it that way.
   - **No `List.sort` or typed-list `sort` on hot paths.** The SDK sorts typed lists through a generic quicksort with a closure call per comparison.
     - Use monomorphic sorts at the five call sites: the distinct bucket keys, the free walk order, the packing visit order, and the per-lane `lo[]` / `hi[]`.
     - The review's control cut the Dart layout by 35–65 %, or by 17–20 % where many-lane sifting dominates, with byte-identical output.
   - **Bounded `optimized`.** The SPEC's work budget is a parameter (default 2,000,000).
     - `greedy` stays cheap at every size: Dart AOT ≤ 28 ms at 100k synthetic nodes, ~15 ms with monomorphic sorts.
     - For ≥ 50k nodes with many lanes, the caller requests greedy first and optimized afterwards, as two requests (10.5 item 2). Both results are deterministic.
   - **Hot reload keeps working:**
     - engine tunables (the gap curve, the bucket ladder, the budget default) are request parameters or `const`, never static or top-level `final` initializers. A reload does not re-run those, so an edit would silently keep the old value. The manual check (Tests) edits one such constant;
     - the worker stays `Isolate.spawn`ed into the UI isolate's group. An `Isolate.spawnUri` worker would not be reloaded;
     - a change to a command class's shape (e.g. new `GraphLayoutCommand` fields) needs a hot restart. That kills the worker; the app's boot spawns it again, and the open handles are lost.
   - **Keep SPEC and the differential tools current** (item 3).

5. **The input builder** (topology → engine input) and the SPEC §2 amendments. The builder lives next to the engine and runs in the worker (item 9). The spike's dumper is its Rust reference implementation (item 10), so recordings, goldens and the product get the same input.
   - **Repeated targets.** jj does yield them: 4.10 Scope 1 found a merge with a Direct and an Indirect edge to the same parent, on a real repo's default revset. SPEC §2's "jj never yields duplicate targets, so V3 holds" is amended:
     - the builder keeps one layout edge per (child, target), at the first occurrence's position. That position decides the first parent `fp` and `pos`;
     - its kind is `direct` if any of the repeated edges is direct (open question 2);
     - V3 stays the engine's validation. So the spike's Rust reference, `tools/fuzz.mjs` and the JS oracle need no change;
     - the dumper adopts the rule. Today it keeps the first edge unchanged and records the dropped one in its `.meta.json` sidecar (`dropped_duplicate_parents`).
   - **Missing edges** are not layout edges (SPEC §4.1). The engine outputs none; the view draws the stub from 4.12's topology (10.4).
   - **No elided counts** (SPEC §0, D2). N is not layout input. If 10.4 design question (a) keeps it, it comes from a follow-up count call (4.10 Non-goals).
   - **V1, V2 and V4 stay validations.** A violation on topology from Rust is a contract bug. The layout fails with a named Dart error type (name in the spec), replied as a failed command, never a partial or silently repaired layout.

6. **The priority rule** (SPEC §11.2; the spike's `priority` is a stand-in). Recommended as the first real rule, made normative by a dated SPEC §11.2 amendment (its inputs are the anchor node sets; its tie rule is D3), and computed by the input builder from 4.10's anchors:
   - class 0: the nodes of anchor 0 (pre-filled `trunk()`) and their first-parent chains inside the revset, following each node's first non-Missing edge;
   - class 1: the nodes of anchor 1 (pre-filled `present(@)`) and their first-parent chains, up to the first class-0 node;
   - class 2: every other node.

   Ties fall to `jj log` order (SPEC D3), so the earlier-printed commit packs left. On the real repo the three classes hold 119, 3 and 1,293 nodes.
   - **Two implementations.** The dumper's Rust `assign_priorities` (`spikes/graph-layout-ab/rust-inputs/src/input.rs:147`, fed by 4.10's anchors once item 10 lands) is the reference. The Dart builder is the second implementation, checked against it end to end (Tests).
   - Alternatives are open question 1.

7. **Lane-order stability across reloads** (SPEC §11.5). 10.12 wants "columns that stay stable across reloads", but `optimized` is global, so one operation can reshuffle columns. Proposed rule, as a SPEC amendment (open question 3):
   - an optional hint: the previous layout's node key → column map, keyed as in 10.1 (the change id, or the commit id when hidden or divergent);
   - **transported as typed data,** never as a string map over `SendPort`: the previous result's per-node column `Int32List` plus the previous topology's key columns (4.12's id vectors), as one `TransferableTypedData`. The worker resolves the keys through 4.12's lookups;
   - π₀ orders the lanes by the previous column of each lane's lowest hinted node. Lanes without a hinted node follow in greedy order, and lane 0 stays fixed;
   - sifting starts at π₀, and Disp measures |π(ℓ) − π₀(ℓ)| instead of the distance from greedy;
   - without a hint the output is SPEC v1's.

   `greedy` is not seeded: it packs the oldest nodes first, so a new head changes little. Until Ralph confirms the rule, 10.12 records column changes across reloads instead of gating them.

8. **Kept design defects, unchanged until Ralph decides:**
   - blocked-merge routing (SPEC D9, §11.4). `synth-10k` has 229 blocked merges (compact, greedy), and 10.4's route report counts them;
   - free-mode buses behind cards (D8, §11.1) *(2026-09-27: with `free` the default, a default-view issue; open question 4)*.

   A fix is a SPEC amendment plus goldens in this engine, never a view patch.

9. **The layout command** (needs 4.10 + 4.12). A new worker command (e.g. `GraphLayoutCommand`) behind `RepoHandle.graphLayout(...)`.
   - **Request:**
     - `revset`, `prioritize` and `shortPrefixes`: pass-throughs that the caller pre-fills from `logDefaults()` and passes explicitly (FR-JJ-17);
     - `anchors`, a required argument. `zanshin_core` exports the editable pre-fill `["trunk()", "present(@)"]` as a documented constant, and the caller (10.5) passes it explicitly;
     - `mode` and `order`;
     - `nowMs` (time only) and `utcOffsetMin` (time; also free if open question 9 is accepted);
     - the budget, and the optional stability hint (item 7).
   - **In the worker:**
     1. the topology call (4.12's extern), with `with_timestamps` iff the mode is `time` or `free`;
     2. the engine input, built from the topology's typed-data views by the input builder (items 5–6);
     3. the engine;
     4. the reply.
   - **Result view (public).** A read-only view over the materialized result buffer (name in the spec, never `GraphLayout`):
     - a fixed header of per-array offsets and lengths, plus the enum encodings (edge kind, route, bucket kind);
     - typed-data views over the arrays.

     `RepoHandle.graphLayout` returns it together with 4.12's topology view, and 10.12 backs 10.1's `GraphLayout` with the two.
   - **Hand-off to the UI isolate, cheaply.**
     - The result arrays share one backing buffer and cross as one `TransferableTypedData`. That is one copy, and `materialize()` on the UI side is zero-copy, so the UI reads typed-data views.
     - The topology crosses in the same reply, under 4.12's one-copy rule.
     - No per-node objects exist on either side.
   - **Worker occupancy.** The worker is one isolate. It runs every command of every open handle in one `commandPort.listen` switch (`isolate.dart:1699-1708`; `project-context.md:230-231`, "one isolate serializes all access"), and it forwards the watcher events on the same event loop (`registerEventSink`, `:1674-1686`). A layout request is synchronous FFI plus synchronous Dart. For its whole duration it delays content pages (10.11), every other repo's verbs and every `OpHeadsChanged` delivery (head-of-line):
     - greedy: up to 28 ms (Dart AOT) at 100k synthetic nodes;
     - optimized: 74–125 ms at 50k–100k, capped by the budget;
     - the first layout after a hot reload runs cold JIT code: 21–52 ms at 10k (spike, cold-start table);
     - in time and free, the timestamp loads before it (4.10 item 4): 33.6 ms at 10k packed, about 1.2 s on the loose-object 10k fixture.

     The rules:
     - rely on 10.5 item 3's coalescing: one request in flight plus one queued, and the latest wins; the worker cannot cancel;
     - above 10.5's threshold, greedy and optimized are two separate commands (10.5 item 2's greedy-first pair), so that queued content pages run between them;
     - rejected for now: a second long-lived layout isolate, also started with `Isolate.spawn` (so it stays in the group and hot-reloadable), at the cost of one more topology copy. Adopt it only if the occupancy measurement (Tests) shows a content-page stall behind a layout that matters.
   - **Side channels.** The reply keeps the precondition and warnings that every graph read carries (Story 9.35).
   - **No state in the worker between commands** (ADR-0002). Every request re-runs the topology call: under 1 ms of index work at 1.4k, plus the precondition's snapshot (28 ms on the real repo). Changes of mode, order or "now" are new requests.
   - **Hot reload.** The worker lays out only when asked, so the debug-only relayout-on-reassemble hook belongs to the view (10.12 item 6).

10. **The spike's dumper on the product path** (needs 4.10). `gen-inputs` (`spikes/graph-layout-ab/rust-inputs`) calls `Repo::walk_graph` and computes the priority stand-in itself (`src/jj_dump.rs:36-50`, `:126`). It moves to 4.10's API:
    - `Repo::graph_topology` with the same anchors and `with_timestamps`, and `Repo::commit_contents` at the returned operation for the `.meta.json` sidecar's object-half fields;
    - the priority classes of item 6, from the anchors, and the repeated-target rule of item 5, both as the amended SPEC states them.

    It stays in the spike, outside the gate, as the reference input builder: 10.1's recordings, the goldens and the end-to-end tests compare against it. Real-repo output stays in gitignored paths (`spikes/graph-layout-ab/.gitignore`).

11. **The `compact` lane order** (SPEC §4.7, added 2026-09-26, Dart-only; spike README "Lane order review 2026-09-26"). In the spike viewer, on the real 1.4k-commit repo, Ralph found that `optimized` sprawls and greedy is more compact: the card he marked sits one column right of a column that stays empty over its whole run. Without a better order he leaned to greedy.
    - **Cause.** `optimized` gives each whole greedy lane one column for all of history. Greedy reuses a lane for many unrelated branches, and the cost has no width term. On the real repo, a lane occupied 6.7 % of the time lands in column 1, and the two busiest lanes (94 % and 46 %) in columns 10 and 11.
    - **Rule.** Start from greedy's packing and keep its continuation chains (segments). Exchange the segments of two columns only inside local time windows, and keep an exchange only if it lowers U·(400·crossings + 4·run length) + κ·Σ column × reserved length, with κ = 24. Reach 8 columns, 16 rounds, the same 2,000,000 budget. The trunk column never moves, and empty columns are dropped. Rows, buckets, edges and every route equal greedy's, and `col = lane`.
    - **Measured** on the real repo's `all()` (`tools/lane-metrics.mjs`, cards 240×62). Per cell greedy / optimized / compact:

      | mode | crossings | mean width (columns) | holes % | Dart AOT layout |
      |---|---|---|---|---|
      | compact | 185 / 97 / 70 | 5.96 / 8.27 / 5.15 | 31.7 / 50.7 / 21.0 | 0.16 / 0.61 / 2.51 ms |
      | time | 425 / 206 / 203 | 5.75 / 11.10 / 5.60 | 15.6 / 56.2 / 13.3 | 0.27 / 0.58 / 3.47 ms |
      | free | 382 / 190 / 213 | 6.01 / 11.15 / 5.66 | 15.4 / 54.5 / 10.3 | 0.24 / 0.60 / 3.04 ms |

      Against greedy, `compact` has 44–62 % fewer crossings and 21–28 % less horizontal run, and it is 3–14 % narrower on average. Its mean width is 50–62 % of `optimized`'s. At the card Ralph marked (free), the row is 6.00 columns wide under `compact`, 6.33 under greedy and 12.00 under `optimized`.
    - **Caveats** (the spike's adversarial review):
      - it is not uniformly better. In free, 7.8 % of the real history's row units are wider than under greedy (by ≥ 3 columns in 3.1 %), and 31.3 % are narrower. One ~40-pitch stretch shows the pattern of Ralph's screenshot, because a segment is atomic;
      - on the default revset in compact mode it removes the last 3 crossings but widens from 2.83 to 3.67 columns (`optimized` does the same);
      - at 10k+ commits the budget truncates the search (≈ 30 ms at 10k). On synth-10k in compact mode it stops inside the first sweep (column pair 59/60 of 134) and ends wider than greedy (52.97 vs 50.19 columns); in free it reaches that sweep's last pair, and in time d = 5. On synth-100k (68–86 ms) only the leftmost dozen columns move;
      - a new commit can re-cut a window and move columns there (SPEC §11.6). Item 7's seeded rule was written for `optimized`.
    - **Port.** `compact_order.dart` (493 lines including comments) joins the port. The Rust reference rejects `--order compact`, so its goldens and its differential run come from the spike's Dart binary (Tests). Its checks against greedy: the same rows, buckets, edges and routes, `col = lane`, the trunk lane unchanged, no more lanes, a model cost never above greedy's, determinism and I1–I6 (the spike's 4 `compact` unit tests and the viewer bundler's checks).
    - **Occupancy.** Its budget is a request parameter like `optimized`'s, and item 9's rules apply to it: about 3 ms at 1.4k commits, the budget's ≈ 30 ms at 10k.
    - **Default:** open question 8. *(Decided 2026-09-27, Ralph, after looking at it in the viewer: `compact`, with greedy as the alternative and fallback; `optimized` is dropped.)*

**Tests.**
- **Unit tests.** Port the spike's 30 Dart unit tests to `package:test` under `packages/zanshin_core/test/graph_layout/`. Drop the JSON-only cases (BOM, `-0`, duplicate keys); keep the value-range cases.
- **The `compact` order** (item 11). The spike's 4 `compact` unit tests join the 30 (34 in all). Its goldens and the differential run use the spike's Dart binary, because the Rust reference has no `compact`; the bullets below that name the Rust reference cover greedy and optimized. The invariant runs cover all three orders (≥ 1,000 graphs × 3 modes × 3 orders).
- **Test support** (`packages/zanshin_core/test/graph_layout/support/`): the spike's SPEC §2 JSON parser, `output.dart`'s SPEC §3 canonical serializer and the §8.4 digest, so that goldens compare in canonical form.
- **Goldens.** Generated with `gen-inputs` plus the spike's Rust reference, after the SPEC amendments of items 5 and 6. They are committed under `packages/zanshin_core/test/graph_layout/goldens/`: the spike's `/inputs/` and `/outputs/` are gitignored (`spikes/graph-layout-ab/.gitignore:2-3`), so nothing there can be referenced as is.
  - **The design oracle.** `design-default` / `design-all` × greedy × compact / time equal the design's own `computeLayout` output byte for byte (SPEC §7.2).
  - **SPEC §7.2's hand-checked expectations:** `optimized` compact is the identity; `optimized` time gives π = [0, 2, 3, 1] (changes only through open question 7); free gives `rows` = 209 / 377 with 4 lanes.
  - **All 12 design-sample outputs** (2 revsets × 3 modes × 2 orders), recorded from the spike's Rust reference and compared in SPEC §3's canonical form. So the port equals the reference that 10.1's recordings come from.
  - **Seeded random small inputs** in the fuzz generator's shapes: hidden commits, priority ties, clock skew, repeated targets (through the input builder). A few hundred KB at most.
- **End-to-end** (real cdylib, committed fixtures, fixed `nowMs` / `utcOffsetMin`; needs items 9–10):
  - **Input equality.** The Dart input builder's input, serialized in SPEC §2's canonical form, equals the dumper's input for `tiny-3-commits`, `medium-1k-commits` `all()` and its narrowed revset, and `large-10k-commits` `all()`. That checks 4.10's topology, the priority rule and the normalisation against their Rust reference.
  - **Output equality.** `RepoHandle.graphLayout` in every mode × order reproduces the Rust reference's full canonical output.
  - **Form.** Both compare as committed files for `tiny` and `medium`'s narrowed revset, and as hashes of the canonical form (function in the spec) for `medium` `all()` and `large-10k`. Never the §8.4 digest alone: it omits edge kind, bucket kind and value, and `rows` / `lanes`.
- **Invariants.** SPEC I1–I6 are checked on every golden, and on seeded random DAGs generated in Dart: at least 1,000 graphs × 3 modes × 2 orders, including repeated targets and non-monotonic timestamps.
- **Worker** (`test/worker/graph_layout_test.dart`, real cdylib):
  - tiny and medium through `RepoHandle.graphLayout` in every mode × order;
  - determinism across two calls;
  - the UI side receives `TransferableTypedData` and reads it through the result view, with no decode step;
  - a decode-contract test for the result view's header (offsets, lengths, enum encodings);
  - a `compact` request asks for no timestamps, and a `time` request does *(2026-09-27: and a `free` request, the default; the dated note at the top proposes dropping `time` from the port)*;
  - a hand-built V1/V2/V4 violation fails with the named error.
- **Dev tools, outside `test/`, not in the gate:**
  - a differential script. It runs the production engine over the spike's generated inputs (synthetic 10k–100k, fixture dumps, local real-repo dumps kept outside the repo) and compares with the spike's Rust binary byte for byte, as a third implementation in `tools/compare.mjs`;
  - a benchmark under `packages/zanshin_core/benchmark/`: AOT and JIT, cold and warm, per phase;
  - **worker occupancy:** the latency of a content page queued behind an `optimized` `large-10k` layout *(2026-09-27: `optimized` is dropped from the product; measure behind the budgeted `compact` order instead)*, and behind a timestamped topology call on the loose and the packed `large-10k`. It decides item 9's second-isolate trigger.

  The numbers go into the spec: the fixtures, and one real repo with its node count only.
- **Manual check, once, recorded in the spec.** Run `flutter run` on Zanshin, edit the gap function and one tunable constant, and hot reload. A debug relayout request (10.12 item 6's reassemble hook, or a debug host until it lands) must lay out with the new code and the new value. The spike verified the mechanism on the plain VM only.
- **Coverage.** The ratchet is Rust-only, so these Dart lines are not in it; these tests are the safety net. This story adds no product Rust and no extern; the dumper is spike code outside the gate.

**Non-goals.**
- No painting, pixel geometry, crossing hops or highlight sets (Epic 10: 10.1, 10.4, 10.6).
- No elided counts (item 5).
- No Rust layout. A later port follows SPEC (item 3's trigger).
- No second layout isolate unless measured (item 9).
- No lane cap; no horizontal compaction beyond item 11's `compact` order.
- No row-range API, no op-log graph, no persisted layouts.

**Depends on.**
- Items 1–8: nothing. The goldens come from the spike, after the SPEC amendments of items 5–6.
- Item 9: 4.10 and 4.12. Item 10: 4.10.

**Open questions (Ralph).**
1. **Priority source** (SPEC §11.2): the anchors rule of item 6 (recommended), or `jj log` order only, `log-graph-prioritize`, or bookmarks? Note that the design sample hand-sets seven per-branch ranks (0–5, including 4.5; @'s branch is rank 2; GD `priority` fields) that no jj fact supplies. The three anchor classes only approximate them, so the design picture cannot be reproduced from real data.
2. **Repeated targets** (item 5): should the kept edge become `direct` when any repeated edge is direct (recommended)? Or should the first occurrence win unchanged, as in the spike's dumper today?
3. **Lane-order stability** (item 7): build the seeded rule now, or ship without it and let 10.12 record the reshuffles? *(2026-09-27: item 7 was written for `optimized`, which is dropped; the question moves to open question 8's stability point for `compact`.)*
4. **Blocked-merge routing** (D9, SPEC §11.4) and **free-mode buses** (D8, §11.1): keep them unchanged until 10.13 has shown them on real data? *(2026-09-27: the viewer has shown both on the real repo; 10.13's notes count 11–15 horizontal runs behind cards in `free`. With `free` the default, D8 is a default-view issue. Still open. The top-centre exit (10.4 item 1) moves a blocked merge's exit, not its vertical.)*
5. **SPEC's home:** `docs/graph-layout.md`, or stay in the spike?
6. **Day boundaries** (SPEC §11.3, 10.2 design question (f)): the fixed offset per layout (D7), or DST-exact local midnights?
7. **Exact lane order for narrow revsets** (spike Review §7; *moot since 2026-09-27: `optimized` is dropped*): SPEC §4.6 sifting reaches ≈ 96 % of the design optimiser's reduction. On the design sample `default`/`time` picks the equal-cost π = [0, 2, 3, 1] where the design picks [0, 3, 2, 1]. Add an exact search for L ≤ 8 with the design's tie-break on top of sifting (the default revset is typically that narrow), or keep sifting everywhere?
8. **The default lane order** (item 11; spike README "Lane order review 2026-09-26" §5–§6): `compact` or greedy? *(Decided 2026-09-27, Ralph, after looking at it in the viewer: `compact`, with greedy as the alternative; `optimized` is dropped. The budget and stability points below stay open.)*
   - The spike recommends `compact`, on one condition: Ralph looks at it in the viewer first (Lane order → Compact), including the stretch where it reproduces his screenshot's pattern. Greedy stays a defensible default: the gap is mostly crossings, not width.
   - Drop `optimized`? Recommended: on the real `all()` it is the widest order in every mode (50–56 % holes), and its one lead, 23 fewer crossings than `compact` in free, costs about twice the width. If it goes, open questions 3 and 7 and the greedy-then-optimized pair (item 4, 10.5 item 2) are re-pointed at `compact` or dropped.
   - For 10k+ commits: a larger or time-based budget, or greedy painted first and `compact` swapped in when the worker finishes?
   - Stability under edits (SPEC §11.6): a seeded rule for `compact` like item 7's, or none?
9. **Free's day buckets** (item 1; 10.2 item 9): should the engine emit one `day` bucket per local day of T in `free` (recommended: it already has T and the fixed offset, and the goldens then cover the days)? Or should the worker return sorted (row, day) pairs beside the layout, as the spike README's Flutter mapping sketches? Either way the view only formats; it never computes T. The first needs item 1's SPEC amendments.

Which modes the product exposes is 10.13's question. It does not gate this story, because all three modes are carried. *(Decided 2026-09-27: `free`, the default, and `compact`. Only these are ported (dated note at the top; Ralph: "the rest can go").)*

**Related:**
- 4.10 (topology, anchors, timestamps, content for the dumper's sidecar), 4.12 (wire, lazy view, lookups, one copy)
- 10.1 (the `GraphLayout` contract; the recordings from the spike), 10.2 (buckets), 10.4 (routes, route report), 10.5 (requests, coalescing, the greedy-first pair), 10.12 (adoption, reassemble hook), 10.13 (modes, constants)
- 4.13 (commit stacks: extends this engine, its input builder, its request and its result view; added 2026-09-28)
- `spikes/graph-layout-ab` (`SPEC.md`, `README.md`)
- FR-GR-1 / FR-GR-2 (amended 2026-09-26), FR-GR-5, ADR-0002

> **Delivered (2026-10-01, Story 4.11 done):** spec at `_bmad-output/implementation-artifacts/spec-4-11-dart-layout-engine-worker-isolate.md` (open questions answered in `decisions-review-4-10-to-4-13.md`; the run's own under `### 4.11`).
>
> - **SPEC.** Moved to `docs/graph-layout.md` (the spike's `SPEC.md` is a pointer), with dated amendments: §2 (`utc_offset_min` read by `free`; the dumper reads `Repo::graph_topology`; repeated targets → one parent per target at its first position, `direct` if any is; priority = §11.2), §3 and §4.2 free step 4 (`free` emits `day` buckets of the clamped T), §4.3 / §4.5 (the top-centre exit, no output change), §7.3 I5 (free), §11.2 (the anchors rule, normative), §12, and a new §13 (the product engine).
> - **Spike.** Free day buckets in the Rust and Dart references, their invariant checks and the fuzz reference; the dumper on `Repo::graph_topology` + `Repo::commit_contents` (every existing input byte-identical; `fixture-tiny-all` added); `tools/goldens.mjs`; `tools/compare.mjs --core`.
> - **Engine.** `packages/zanshin_core/lib/src/graph_layout/`: modes `compact` | `free`, orders greedy | `compact`, flat typed arrays, monomorphic sorts, `const` tunables, budget a request parameter; the input builder (repeated-target and anchors rules, O(n + E)); V1–V4 → `LayoutContractException`; one-buffer result `GraphGridView`. Byte-identical to both references on every spike input × mode × order (44 cells) and on the committed goldens (design, oracle, fixtures, 100 fuzz cases).
> - **Worker.** `GraphLayoutCommand` → `GraphLayoutResult` (topology + grid, one `TransferableTypedData` each), `ZanshinWorker.graphLayout`, `RepoHandle.graphLayout` (pre-fills free / compact / 2,000,000; `utcOffsetMin` required); not exported from the barrel (10.12). On the fixtures the grid equals the goldens and the builder's input equals the dumper's.
> - **Measured** (spec § Measurements): AOT warm 1.25 ms for `free` / `compact` at large-10k, 51 ms at synth-100k (budget-bound); a content page queued behind a layout waits for the topology's timestamps (1.24 s loose, 59 ms packed at 10k), the layout adds ~1.3 ms.
> - **Open for Ralph:** the one-time hot-reload check and real-repo numbers (`deferred-work.md`, "Surfaced in Story 4.11").

### Story 4.12: Graph topology wire — whole-revset scalar vectors + CSR, lazy Dart view, id → index lookups, one copy across isolates [R/bridge]
*(Added 2026-09-26, Ralph — console session on the commit-graph view; research: `_bmad-output/planning-artifacts/research/technical-commit-graph-virtualization-research-2026-09-26.md`. Re-planned 2026-09-26: the layout runs in Dart (4.11), so the wire carries 4.10's topology instead of lane rows. The first version's landing lanes, pass-through segments and segment identity belong to the lane model the view no longer draws. Backend + bridge scope; the painter is Epic 10. Refined enough to build from; ACs to be written when scheduled. Depends on 4.10.)*

**Motivation.** The Dart engine (4.11) needs the whole revset's topology as typed arrays. The view (Epic 10) needs the view facts of the visible cards only. Today's graph wire suits neither:
- **One table per record.** `zanshin_graph_slice` returns a `GraphRow` table per row, a `GraphRowEdge` table with a hex `target` string per edge, and a `GraphActiveLane` table per pass-through lane.
  - That is O(rows × width) tables, plus lanes the view no longer draws.
  - A FlatBuffers `GraphSlice` costs ~175 B per node (1.75 MB at 10k), mostly id and summary strings (`spikes/ffi-payload-bench`, as the layout spike's README cites it).
  - The layout spike's fixed-width estimate for the topology is ≈ 22 B per node plus the ids (`spikes/graph-layout-ab/tools/payload.mjs`). That estimate includes `priority` (u32) and `ts` (i64), which this wire drops or makes optional, and lacks the prefix lengths, `change_offset` and `parent_count` it adds. Item 1 re-measures.
- **Eager decode.** Dart decodes all of it up front (`packages/zanshin_core/lib/src/ffi/graph.dart:373-433`: `.map(...).toList()` for every row, edge, lane and meta).
- **Two copies.**
  - The worker copies the native buffer (`request_bytes.dart:99-106`, `Uint8List.fromList`), and the `BufferResult` send copies it again (`worker/isolate.dart:1756-1777` → `:619-637`).
  - No `TransferableTypedData` is used anywhere in `packages/zanshin_core/lib`.
  - So `docs/ffi-abi.md:951-954`'s "copied once into Dart" is wrong.

**Scope.**

1. **The wire:** a `GraphTopology` payload (names in the spec) in `schemas/envelope.fbs`.
   - **Union slot.** If item 7 removes the slice, the payload takes `GraphSlice`'s `Payload` union slot in place (WIP: edit in place, regenerate); the member order is the wire discriminant, so reusing the slot renumbers nothing. If the slice stays, the payload is appended.
   - **Contents,** as scalar vectors + CSR:
     - `operation_id` (full hex) and `all_count` (`ulong`);
     - **per node** (n, in `jj log` order):
       - the commit id and the change id (item 2);
       - a flags byte: `working_copy`, `immutable`, `hidden`, `divergent`, `root`, and a presence bit for `change_offset`;
       - `change_offset`, `change_id_prefix_len`, `commit_id_prefix_len` and `parent_count`;
     - **edges as CSR:** `edge_start` (n + 1), `edge_target` (node index, `int`) and `edge_kind` (`GraphEdgeKind`). These are jj's edges verbatim, repeated targets included.
       - A Missing edge has no target. `edge_target` is defined only when `kind != Missing`, which the docs state, and the Dart accessor returns `null`. That is kind-gated, as 4.2 did; flatc has no optional scalars for Dart (cf. the presence pairs at `envelope.fbs:252-253`).
       - The Missing target's commit id is dropped. The CLI never prints it (`cli/src/commands/log.rs:250-272` @ v0.44.0), and the layout ignores it (open question 3);
     - `timestamps: [long]`, present iff the request asked for them. Absent means not requested (null for absence). The root's slot holds 0 and is ignored: the engine keys off the `root` flag, and the Dart accessor returns `null` for the root (SPEC §2);
     - **refs, sparse:** a vector of `TopologyRef` tables `{ node, kind: bookmark | tag, name, remote (absent = local), synced, conflicted }`, sorted by node. Not `GraphRef`: 10.1 item 2 reserves that name for the app-side type and says it is never a wire type. Tables are fine here, because refs are sparse: the real repo has 18 entries for 1,415 nodes;
     - **working copies,** likewise, as `{ node, workspace name }`;
     - **anchors as CSR:** `anchor_start` and `anchor_node`.
   - **Not on the wire:** lanes, `color_idx`, `active_lanes`, synthetic rows, and any per-node strings besides the ids.
   - **Decided by measurement,** not by guess: the id representation (item 2) and the flag packing.
     - Metrics: payload bytes, Rust build time, Dart first-access time.
     - Stores: `large-10k` loose and packed, plus one local real repo's `all()`. Its node count is recorded; its data is never committed.
     - 100k synthetic nodes are exploratory only (FR-GR-6, P2).
     - Benches: `crates/zanshin-ffi/benches/graph_wire.rs` (`harness = false`, like 4.10's) and a Dart timing script outside `test/` (e.g. `packages/zanshin_core/benchmark/`). The gate runs neither.

2. **Ids.** Two options:
   - (a) the display strings that Rust produces, as string vectors: the commit hex, and the change id's `reverse_hex()` (`crates/zanshin-jj/src/commit_meta.rs:185`);
   - (b) fixed-stride byte vectors with a stride field, formatted in Dart on access: the commit id as plain hex, the change id through a small reverse-hex port. The stride matters because the commit-id length depends on the backend: SHA-1 today, with `object_hash` deferred to 9.20.

   (b) carries 36 B per node (SHA-1), against ~95 B of strings and offsets for (a). Either way, never a silent second jj formatter in Dart. With (b), a real-cdylib test pins the Dart format against Rust's display string for every node of every fixture.

3. **Request and extern.** `zanshin_graph_topology(handle, request)`, over a request buffer.
   - The request is a table, because it has a list argument: `GraphTopologyRequest { kind, revset, prioritize, short_prefixes, anchors: [string], with_timestamps }`, with a new `RequestKind` member `GraphTopology` appended (names in the spec). The "For the other N tables" count at `envelope.fbs:62` goes up once more: 27 → 28 after 4.10's content request.
   - Its envelope carries precondition + warnings, like every verb read.
   - It replaces `zanshin_graph_slice` as the graph read (item 7).

4. **Lazy Dart view** (e.g. `GraphTopologyView`) instead of the eager decode.
   - **O(1) access to node i:**
     - the ids, formatted on access;
     - the flags and prefix lengths;
     - `changeOffset` or `null`, and `parentCount`;
     - the edge range, with each target index or `null`, and its kind;
     - the timestamp or `null`;
     - the refs (a binary search over the sorted `node` column), the working copies, and the anchors.
   - No per-node objects are allocated up front.
   - Typed-data views over the aligned scalar vectors (FlatBuffers aligns scalar vectors to their element size). Where a vector is not aligned, a copy of that one vector. Measured.
   - A structurally required field missing on the wire is corruption and throws, instead of today's `?? ''` coercions (`graph.dart:393`, `:438`).
   - 4.11's input builder reads these views, and 10.12 backs `GraphLayout`'s view facts with them.

5. **At most one copy across the isolate boundary.**
   - The worker reads the topology straight from the native buffer, through views over the token's memory, for 4.11's input builder.
   - It then copies the bytes once into a `TransferableTypedData`, frees the token, and sends it. The UI isolate's `materialize()` is zero-copy.
   - `readToken`'s copy plus the `SendPort` copy stay for every other extern.
   - `docs/ffi-abi.md` states both copy counts, correcting `:951-954`.

6. **Lookups**, only for named consumers: commit id → node index, and change id → node indices (a divergent change has several).
   - They are built lazily on first use from the view:
     - in the UI isolate, for 10.1's `indexOfKey`, for reveal (scroll to @), for anchoring across reloads, and for 10.6's go-to-change with a full id (10.6 item 11, if its design question (d) keeps go-to-change);
     - in the worker, for 4.11's stability hint.
   - There are no synthetic rows, so there are no `(commitId, synthetic)` keys.
   - A Rust-emitted sorted permutation only if a measurement demands it.

7. **The old lane path** (open question 1). Recommended: remove it in this story, once the topology call has replaced it.
   - **What goes:**
     - the `zanshin_graph_slice` extern and `graph_slice_to_envelope`;
     - the `GraphSlice` / `GraphRow` / `GraphRowEdge` / `GraphActiveLane` / `GraphRowMeta` / `GraphCommitRef` tables;
     - the Dart `GraphSlice` models and decoder, `GraphSliceCommand`, `ZanshinWorker.graphSlice` and `RepoHandle.graphSlice`;
     - the `zanshin-graph` crate: the pvigier lane assigner (`lane.rs`), `stream_lanes`, `collect_lanes` and the synthetic-row splice, with the root `Cargo.toml` member and dependency (`:11`, `:53`) and `crates/zanshin-ffi/Cargo.toml:31`;
     - the tests that pin the path: `crates/zanshin-graph/tests/*`, and the extern's witnesses elsewhere. `crates/zanshin-ffi/tests/snapshot_ffi.rs:34`, `:430` (a precondition witness) is re-pointed to `zanshin_graph_topology`, and `packages/zanshin_core/test/worker/graph_test.dart` (which credits the slice extern in the extern-coverage guard, `:9`) is rewritten for the new extern;
     - the generated outputs, regenerated: `crates/zanshin-ffi/include/zanshin_ffi.h`, `packages/zanshin_core/lib/src/ffi/bindings.dart`, `crates/zanshin-ffi/src/envelope_generated.rs`, `packages/zanshin_core/lib/src/ffi/envelope_zanshin.ffi_generated.dart`, and `Cargo.lock`.
   - **`Repo::walk_graph`** then has no caller outside its own tests and `crates/zanshin-jj/benches/graph_blueprint.rs` (4.11 item 10 moves the dumper). Whether it stays as zanshin-jj's `jj log`-faithful read is part of open question 1.
   - **Why:**
     - No consumer is left. Its only user is `crates/zanshin-ffi/src/graph.rs`; no other crate, `app/lib` or `zanshin-mcp` uses it (verified). The view draws the design's layout, and Story 7.3's `log` returns `Array<Change>`.
     - Keeping it keeps a second graph contract alive: `docs/ffi-abi.md`'s slice section, the schema tables, the synthetic-row and CAP-2 docs, and a second `walk_graph` caller.
     - It stays recoverable from git history and Stories 4.1–4.9's delivered notes. A future `jj log`-faithful graph (an op-log graph, a TUI-like view) would re-derive it from there. A later Rust port of the layout could re-create a layout crate from SPEC.
   - **Coverage.** Its baseline entries (`coverage-baseline.txt:40-42`) drop out. A removed file is not a ratchet failure (`docs/coverage.md:73`).
   - **Consumers to re-point.** Story 9.25's "Apply evaluates via `graphSlice`" and its "N revisions" line move to the topology call's node count. Settle that when 9.25 is refined.
   - **Alternatives:**
     - (b) keep `zanshin-graph` as a Rust library without FFI. That is dead code in the gate;
     - (c) keep the whole path, for `jj log` parity tests.

8. **Docs.**
   - `docs/ffi-abi.md`: rewrite the graph section. It covers the topology payload, the kind-gated target, null for absence (timestamps not requested, the root's timestamp, a local ref's remote, `change_offset`), both copy counts, and the extern's error list.
   - `docs/rust-error-codes.md`'s "also emitted" clauses follow.
   - The `schemas/envelope.fbs` table docs and the `graph.dart` model docs.
   - **The slice's windowing statements** (moved here from 4.10). They are false since the PRD amendment of 2026-09-26 (FR-GR-4 / NFR-P-2: no windowing). They go with the slice docs if item 7 lands, and are corrected in place otherwise:
     - `schemas/envelope.fbs:814-815` (the `GraphSlice.total_rows` doc);
     - `docs/ffi-abi.md:890`, `:951-954` and `:1081-1084`;
     - `packages/zanshin_core/lib/src/ffi/graph.dart:344`;
     - `crates/zanshin-ffi/src/graph.rs:193-197` and `:229-231`;
     - `crates/zanshin-graph/src/slice.rs:7-9`;
     - `_bmad-output/implementation-artifacts/epic-4-context.md:28`.
   - **If item 7 lands,** add dated notes where docs name the removed API:
     - `_bmad-output/project-context.md:13`, `:346` (the `zanshin-graph` test exception) and `:694-704` (lane state, `collect_lanes`);
     - `_bmad-output/planning-artifacts/architecture.md:41`, `:143`, `:459`, `:601` (`:32` and `:439` get 4.11's note regardless);
     - `_bmad-output/implementation-artifacts/epic-4-context.md`;
     - ADR-0002 (6 mentions of `zanshin-graph` / `zanshin_graph`) and `docs/rust-error-codes.md` (7);
     - code docs: `crates/README.md:11`, `cbindgen.toml:20`, `crates/zanshin-ffi/src/log_defaults.rs:10`, `crates/zanshin-jj/src/graph.rs:3` and `:36`, `crates/zanshin-jj/tests/revset.rs:171`;
     - the Epic 4 title "`zanshin-graph` — DAG Lane Assignment" (epics.md: the Epic List entry and the Epic 4 heading) and the sprint-status comment `# Epic 4: zanshin-graph — DAG Lane Assignment`: a dated retitle note, e.g. "(2026-09-26: the lane crate was removed in 4.12)".

**Tests.**
- **Rust:**
  - **Builder round-trip,** inline in `crates/zanshin-ffi/src/graph.rs`: every vector; kind-gated targets; absent timestamps; the root's ignored slot; sparse refs; an empty revset (n = 0); the `Verifier`.
  - **`crates/zanshin-ffi/tests/graph_ffi.rs`, reshaped for the topology** (or a new file next to it if the slice stays): the wire against the `Repo::graph_topology` oracle on tiny + medium. It covers the anchors, timestamps on and off, `all_count`, a narrowed revset with Indirect and Missing edges, and the repeated-target case.
  - **The request-buffer ladder:** null data, wrong `RequestKind`, zero handle, an interior NUL in an anchor.
  - **Codegen and the export list.** `cargo make codegen` output and `crates/zanshin-ffi/tests/ffi_abi_doc_sync.rs` stay green with the extern swapped. `EXPECTED_EXPORTS` stays 61 if item 7 lands (60 + 4.10's content extern), and becomes 62 otherwise.
  - **The re-pointed precondition witness** in `snapshot_ffi.rs` passes on `zanshin_graph_topology`.
- **Dart decode-contract tests with synthetic buffers** (`packages/zanshin_core/test/ffi/graph_test.dart`):
  - random access;
  - null for absence: timestamps not requested, the root's timestamp, a Missing target, a local ref's remote, an absent `change_offset`;
  - a missing required vector throws;
  - views vs copies;
  - lookups, including a divergent change.
- **Ids.** With option (b), the Dart formatting equals Rust's display string for every node of every fixture (real-cdylib test).
- **Transfer.** A worker test shows the topology arriving as `TransferableTypedData` and read through views, with no decode step.
- **Extern coverage.** A real-cdylib worker test calls `zanshin_graph_topology` (`test/worker/graph_test.dart`). Coverage and the extern-coverage guard credit an extern only through `zanshin_core` tests.
- **Coverage ratchet.** It measures Rust lines only. Changed files must not drop, and new files reach 80 %. Removed `zanshin-graph` files leave the baseline.
- **Numbers.** The size and time numbers of item 1 are recorded in the spec.

**Non-goals.**
- No layout (4.11).
- No painting and no colour model (Epic 10: one gray plus the gold lineage of @).
- No content (4.10).
- No row-range API, no lane cap, no op-log graph, no elided counts.

**Depends on.** 4.10. 4.11's layout command and 10.12 depend on this story.

**Open questions (Ralph).**
1. **The old lane path** (item 7): remove the slice extern and the `zanshin-graph` crate (recommended), keep the crate without FFI, or keep everything? And does `Repo::walk_graph` stay as zanshin-jj's `jj log`-faithful read once nothing calls it?
2. **Ids** (item 2): display strings, or fixed-stride bytes with Dart formatting? Decided by measurement; (b) is expected to win.
3. **Missing targets:** drop the target commit id (recommended), or keep it?

**Related:**
- 4.2, 4.6, 4.8 (the payload this replaces)
- 4.10 (the topology), 4.11 (the input builder, the engine and the layout command)
- 9.25 (a `graphSlice` consumer)
- 9.31 (edge drop zones): each drawn edge is one layout edge with child and parent indices, so segment identity is explicit (10.4 item 9)
- Epic 10 (10.1, 10.12)
- ADR-0001, FR-GR-2 (amended 2026-09-26), FR-GR-6

> **Delivered (2026-10-01, Story 4.12 done):** spec at `_bmad-output/implementation-artifacts/spec-4-12-graph-topology-wire-lazy-dart-view.md` (open questions answered in `decisions-review-4-10-to-4-13.md`; the measured ones under `### 4.12`).
>
> - **Wire.** `zanshin_graph_topology(handle, data, len)` over `GraphTopologyRequest` (`RequestKind.GraphTopology`, appended) → `GraphTopology` in `GraphSlice`'s Payload slot 11: scalar vectors indexed by node (ids as raw bytes at one stride per column, one flags byte, change offset with a presence bit, prefix lengths, parent counts, optional timestamps with the root's slot 0) plus CSR offsets for the edges (target −1 iff Missing, no target id) and the anchors, sparse ref / working-copy tables sorted by node. Precondition + warnings on the ok arm and on every error arm after the snapshot ran; `revset` / `prioritize` / `short_prefixes` required on the wire, no Rust default. 61 exports.
> - **Measured** (spec § Measurements): ids as stride bytes (b) are 36 B/node vs 96 for strings (a), Rust build 146 vs 175 µs, Dart first access level (553 vs 565 µs) at 10k packed → (b); one packed flags byte beats six bool vectors on all three → packed. The chosen envelope is 56 B/node (64 with timestamps); the Dart call is 21.7 ms @ 10k, the view constructs in ~3 µs, a full pass reads every node in ~0.6 ms, the id lookups build in ~2.2 ms.
> - **Dart.** `GraphTopologyView` (lazy typed-data views, O(1) per node, `ffi.unknown` on a malformed buffer, null for absence, lazy `indexOfCommitId` / `indicesOfChangeId`), `GraphTopologyCommand`, `ZanshinWorker.graphTopology`, `RepoHandle.graphTopology` (anchors and `withTimestamps` required). One copy across isolates: the worker copies the native buffer once into a `TransferableTypedData` (`TransferResult`), the UI's `materialize()` is zero-copy; every other reply keeps its two copies. `defaultSyntheticElided` removed.
> - **Removed:** `zanshin_graph_slice`, `graph_slice_to_envelope`, the `GraphSlice` / `GraphRow*` / `GraphCommitRef` / `GraphActiveLane` tables, the Dart slice models + `graphSlice`, and the `zanshin-graph` crate (the workspace has 7 `Cargo.toml` files). `Repo::walk_graph`, its tests and the `graph_blueprint` bench stay.

### Story 4.13: Commit stacks in the layout engine — linear runs grouped into stack nodes, columns from the ungrouped layout, vertical compaction only [bridge]
*(Added 2026-09-28, Ralph — console session on the design update, export at `a399daf`. Bridge scope: pure Dart in `packages/zanshin_core`, after 4.11's port; first in the spike's Dart, which is the reference and the recorder. The view side is 10.17. Refined enough to build from; ACs to be written when scheduled.)*

**Motivation.** The updated design collapses linear runs of commits into one stack card (GV:227-264; the toolbar's "Group stacks" switch GV:336-339; both at `a399daf`). A click expands a stack, and a bracket beside the expanded run collapses it again (GV:654-665, :800-806). The design implements this by rewriting the commit list and re-running the whole layout on it (GV:651-652). Every toggle therefore re-packs the lanes, and whole branches jump sideways. Measured in the design page on 2026-09-28 (default revset, collapsing every stack):
- with Min. crossings, the settings branch moves from column 5 to 3 and the iOS branch from 3 to 1;
- with greedy, the riverpod branch moves from column 5 to 1.

Ralph's decisions (2026-09-28):
- A stack toggle never changes a column, and neither does switching "Group stacks". The columns follow the decided lane logic (the `compact` order, greedy the alternative) on the ungrouped graph. This is an intended deviation from the design (the Epic 10 header, deviation (f)).
- The graph may compact vertically.

The view never computes rows (Epic 10's house rules), and a stack changes rows. So the grouping is engine work.

**Scope.**

1. **The run rule** (GV:228-246 at `a399daf`), evaluated in the worker on the layout's node set.
   - **Candidates.** A node is a candidate when all of these hold:
     - it is not the root and not the working copy of any workspace;
     - it carries no bookmark (local or remote) and no tag;
     - its real parent count is 1 (4.10's `parent_count`), and its one edge is Direct, so its parent is in the revset;
     - exactly one layout edge has it as the parent, Direct or Indirect. An Indirect child is still a visible fork.

     The design checks @, bookmarks, the root, one parent in the revset and one child (GV:233). Tags and other workspaces' working copies are Claude's proposal, accepted on 2026-09-28.
   - **Runs.** A run is a maximal chain of candidates in which each member is the only child of the previous one. It breaks where `immutable` changes (GV:234).
   - **Stacks.** A run of at least 2 members is a stack. Its key is its oldest member's key: the design's `"grp:" + id` (GV:243) under 10.1 item 2's key rule (the change id, or the commit id when hidden or divergent).
   - **Conflicts do not break a run.** 10.17's card shows ⚠ when a member has one (GV:257; proposal accepted).
   - **Inputs.** 4.11's input builder (its item 5) gains per-node `immutable`, `parentCount`, a has-ref flag (bookmark or tag) and an is-working-copy flag (any workspace), all from 4.10's view half. The edges are the layout edges after 4.11's repeated-target rule.

2. **Request.** 4.11's layout command (its item 9) gains:
   - `stacks`: the "Group stacks" switch (10.7). Off means 4.11's layout, byte for byte;
   - `expandedKeys` and `collapsedKeys`: the runs the user toggled. 10.17 persists them per repository;
   - `keepOpenKeys`: node keys whose run stays expanded, i.e. the selection and a pending go-to-change target (10.5).

   **Default state.** A run without an explicit state is collapsed, except a run of mutable ancestors of @ (Claude's proposal, accepted; in jj's default configuration these are the ancestors of @ above `trunk()`). The worker walks them from @ (4.10's `working_copy`) over the layout edges. Explicit keys beat the default, and `keepOpenKeys` beat both. A key that names no current run is ignored, so a run whose oldest member changed falls back to the default.

3. **Columns from the ungrouped layout.** The engine first lays out the ungrouped graph exactly as 4.11 does: rows, packing and lane order (`compact` or greedy). Every node keeps that column in every stack state.
   - **A stack's column.** All members normally share one column: each member after the oldest is the sole continuation of its predecessor, which SPEC §4.3 keeps in its parent's lane unless another node's reservation blocks it. One known case does: the oldest member continues its parent's lane beside the parent's own merge reservation, which §4.3 excepts only for that direct continuation, so the next member moves to another lane. A stack therefore takes its **newest** member's column, which keeps the edge into the run's child straight.
   - **Consequence:** collapsing never makes the graph narrower.

4. **Rows from the grouped graph.** Each collapsed run becomes one stack node. Its parent edge is the oldest member's; the newest member's child edge now starts at it. The layering (SPEC §4.2, per mode) then runs on the grouped graph under extra ordering constraints per column: the segments that share a column keep their ungrouped vertical order and their one-row buffer (SPEC §4.3's [a, b) reservations). So cards move only vertically, and no two cards collide in a column.
   - **`compact`:** a stack sits one row above its parent, where its oldest member was, unless a constraint pushes it up.
   - **`free`:** a stack takes its newest member's timestamp (the design's `ts: top.ts`, GV:256). Free compacts only where the run had stretched the time axis to one pitch per commit (SPEC §4.2 step 3). Elsewhere only the members' cards disappear, and the edge remains.
   - **Routes and `blocked`** are recomputed on the grouped rows with the fixed columns (SPEC §4.4–§4.5). Crossing hops stay the view's (10.4).
   - **Free's day buckets** (4.11 open question 9, if accepted) follow the grouped rows; a stack lies in its newest member's day.
   - **Proposal for the constraints:** extra longest-path constraints, one per pair of adjacent segments in a column, so that the upper segment's reservation cannot start below the lower one's end. Every constraint follows the ungrouped layout's y order. The SPEC amendment (item 6) states the exact rule with a termination argument, and the invariants below check it.

5. **Output.** 4.11's result view (its item 9) gains, per run, collapsed or expanded: its key, its state and its members, oldest first, as a CSR over topology node indices.
   - **Proposal:** the per-node arrays stay indexed by topology node, so 4.12's view is unchanged. Collapsed members carry a hidden flag and no position. Stack nodes are appended after the n topology nodes, with their own row and column, and layout edges reference them by those indices.
   - 10.1's `GraphLayout` exposes all of it through accessors (10.17).

6. **SPEC first, in the spike's Dart.** A dated SPEC section (e.g. §4.8 "Stacks") specifies the rule, the request fields, the columns, the constraints and the output. It is implemented in `spikes/graph-layout-ab/dart/` first. Like the `compact` order it is Dart-only: the Rust reference rejects the stack options, and the goldens come from the spike's Dart binary. The spike's recorder then produces the stack recordings for 10.1 and 10.17.

7. **In `zanshin_core`,** after 4.11's port: the same code under `lib/src/graph_layout/`, the request fields on `RepoHandle.graphLayout`, the result view's new arrays (offsets and lengths in its header), and the input builder's new flags. SPEC's home follows 4.11 open question 5.

8. **Cost.** Every toggle is a new layout request, because the worker keeps no state between commands (ADR-0002; 4.11 item 9). On the real 1.4k-commit repo that is about 30 ms, mostly the precondition's snapshot (28 ms), plus the timestamps in `free` and two layerings: the ungrouped one for the columns and the grouped one for the rows. 4.11's benchmark records it.

**Tests.**
- **The run-rule oracle.** On the design sample at `a399daf` (36 commits), for both revsets, the runs equal the design's `groupStacks` (GV:228-264): members, keys and the immutable split. The design's columns are no oracle, because they re-pack.
  *(2026-09-30: the export at `e243dd2` (52 commits) adds the gap cases, and its `groupStacks` now counts a child behind a gap as a child and requires a Direct parent for members (GV:264-276), as item 1 does. The oracle can move to that sample and then reaches gaps. At build time, check that the design's gap walk, which keeps transitive indirect edges (prototype defect 4), yields jj's edges on it. The hand-built gap cases below stay.)*
- **The gap cases** *(added 2026-09-30, console session: the design sample has no Indirect edge, so the oracle never reaches a gap)*. `jj log` draws a gap as "(elided revisions)" or `~`; the layout sees only 4.10's edge kinds. Hand-built inputs pin the run rule at a gap:
  - **Indirect parent edge.** A node whose one edge is Indirect is no member. Example: B's edge is Indirect, C and D sit above B with Direct edges. Expected: B stays a single card, and C–D is a stack whose parent edge (to B) is Direct.
  - **Several Indirect edges.** A node with one real parent gets two Indirect edges when that hidden parent is a merge (jj-lib 0.44.0 `default_index/revset_graph_iterator.rs:168-172`). It is no member.
  - **Missing parent edge.** A node whose one edge is Missing is no member, and its stub stays with its own card.
  - **Two runs meet at a gap.** The lower run's newest member has one Indirect child edge; it stays a member, and its run ends there. The node above the gap is no member. Expected: two stacks with one single card between them.
  - **Indirect child edge.** A node with one Direct and one Indirect child edge is a fork and no member.
  - **Edge kinds survive collapsing.** A collapsed stack's parent edge is Direct, and its child edge keeps the kind of the newest member's child edge, so it can be Indirect.
- **I7, the column invariant (new).** For every input and every stack state (all collapsed, all expanded, random subsets, `stacks` off): every visible non-member keeps its ungrouped column, the members of an expanded run keep theirs, and a stack sits in its newest member's column.
- **I1–I6 on the grouped layout,** on the goldens and on at least 1,000 seeded DAGs with runs × 2 modes × 2 orders × random stack states. The generator adds runs broken by bookmarks, tags, working copies, the immutable boundary, merges, forks and an Indirect child edge, plus item 3's split run. *(2026-09-30:)* It also breaks runs at gaps below a node: an Indirect parent edge, a single-parent node with several Indirect edges, and a Missing parent edge.
- **Vertical compaction.** Collapsing never increases `rows`. On the design sample in `compact`, collapsing every stack shrinks `rows` by the count the SPEC amendment derives by hand.
- **`stacks: false`** equals 4.11's output byte for byte.
- **State.** A run of mutable ancestors of @ starts expanded. Explicit keys win over the default, a keep-open key wins over both, and an unknown key is ignored.
- **Worker.** A real-cdylib test toggles a stack through `RepoHandle.graphLayout` and reads the new arrays through the result view.
- **Coverage.** Dart only, so the ratchet has no floor here; these tests are the safety net.

**Non-goals.**
- The stack card, its popover, the bracket, the animation and the persistence (10.17; since 2026-09-30 the animation is 10.20's).
- Grouping anything but linear runs, e.g. collapsing a whole branch with its forks.
- Stacks in the spike's Rust reference.
- A narrower layout for collapsed graphs: the columns are fixed by decision.

**Depends on.** 4.11 (the port, the input builder, the layout command, the result view) and 4.10 (the view half, `parent_count`). The spike step (item 6) needs only the spike.

**Open questions (Ralph).** None blocking. The design's rule plus the accepted proposals are recorded above: tags and other workspaces' working copies break a run, conflicts do not; runs of mutable ancestors of @ start expanded; in `free` a stack sits at its newest member's time. Ralph can overrule any of them at review.

**Related:**
- 4.10 (the view half, `parent_count`), 4.11 (engine, input builder, request, result view, SPEC's home)
- 10.1 (accessors, recordings, the invariant checker), 10.5 (the request), 10.7 (the switch), 10.17 (the view)
- spike `SPEC.md` §4.2–§4.7; the Epic 10 header, "Design update 2026-09-28"

> **Delivered (2026-10-01, Story 4.13 done):** spec at `_bmad-output/implementation-artifacts/spec-4-13-commit-stacks-layout-engine.md` (decisions in `decisions-review-4-10-to-4-13.md`; the run's own under `### 4.13`).
>
> - **SPEC.** `docs/graph-layout.md` §4.8 "Stacks" (new): the run rule, the state, the fixed columns (a split run stacks in its newest member's column), the grouped graph, the rows as the least solution of the edge / `free` walk / per-column segment constraints with the level-sweep procedure and its termination argument, `free`'s buckets, D11, and the design sample's compaction by hand; dated §2 (stack facts, the request file, V5), §3 (the output with stacks), §6 (`--stacks`), §7.3 (I7, I1–I6 on the grouped layout, y′ ≤ y), §9 (D11), §13 amendments.
> - **Oracle.** The design's gap walk at `e243dd2` yields jj-lib 0.44's edges on both revsets (`tools/stacks.mjs` re-checks it), so its `groupStacks` is the run-rule oracle: 6 runs (default) and 7 (all), equal to the engine's. The hand-built gap cases are tests.
> - **Engine.** `stacks.dart` in the spike's Dart reference and in `packages/zanshin_core/lib/src/graph_layout/` (the same code, byte-identical via goldens); `StackInput` + V5; the input builder's facts and key resolution (10.1's key rule); grid format version 2 only with stacks (version 1, byte for byte, without). Request fields `stacks` / `expandedKeys` / `collapsedKeys` / `keepOpenKeys` on `RepoHandle.graphLayout`, default off.
> - **Compaction** on the design sample, `compact` / greedy, every run collapsed: all 19 → 15, default 9 → 8 (a column constraint binds; the planning estimate 9 → 7 missed it).
> - **Measured** (spec § Measurements): the `stacks` phase costs 0.3–0.45 ms at large-10k and ~9–11 ms at synth-100k (AOT warm).

---

## Epic 5: `zanshin-diff` — Word-Diff + Syntax Highlight

Produce structured diff JSON (hunks → lines → segments) with word-level diff inside changed lines plus tree-sitter syntax classification, served via the FFI surface. Hit the < 500ms target for a 5k-line changed file (NFR-P-3).

### Story 5.1: Line-level hunks via jj-lib (`hunks.rs`)

As a Rust developer building the diff base,
I want `crates/zanshin-diff/src/hunks.rs` computing line-level hunks for a change by delegating to jj-lib,
So that subsequent stories (word-level diff, syntax highlight, JSON output) build on a correct line-level foundation (FR-DF-1 base).

**Acceptance Criteria:**

**Given** `crates/zanshin-diff/src/hunks.rs`
**When** created
**Then** it defines `pub struct Hunk { pub file_path: PathBuf, pub before_range: Range<u32>, pub after_range: Range<u32>, pub lines: Vec<HunkLine> }` and `pub enum HunkLine { Context(String), Removed(String), Added(String) }`.

**Given** `pub fn compute_hunks(repo: &Repo, from: ChangeId, to: ChangeId) -> Result<Vec<Hunk>, DiffError>` (FR-DF-4 — diff between any two revisions)
**When** called with two change IDs
**Then** it queries jj-lib for the file-level diff between the two revisions
**And** for each changed file, produces a `Hunk` per contiguous change region.

**Given** the `to` change is the working copy and `from` is its parent
**When** `compute_hunks` is called
**Then** the result matches what `jj diff` would show for working-copy modifications
**And** each `Hunk.lines` contains the canonical pre-/post-line content.

**Given** a file added in `to` (not present in `from`)
**When** processed
**Then** the resulting `Hunk` has `before_range: 0..0`, `after_range: 0..N`, and all lines as `HunkLine::Added`.

**Given** a file removed in `to` (present in `from`)
**When** processed
**Then** the resulting `Hunk` has `before_range: 0..M`, `after_range: 0..0`, and all lines as `HunkLine::Removed`.

**Given** a file that exists in both but with no content change (theoretically jj-lib wouldn't list this)
**When** queried
**Then** no hunk is produced (jj-lib only lists changed files).

**Given** a binary file (jj-lib detects via heuristic)
**When** processed
**Then** the hunk is marked as binary (a `Hunk` variant or a `BinaryHunk` separate type — implementation choice; documented in the schema)
**And** no line-level breakdown is attempted.

**Given** unit tests in `crates/zanshin-diff/tests/hunks.rs`
**When** they run
**Then** they: extract a fixture with known modifications, compute hunks between two known change IDs, assert the hunk list matches expected file paths and line counts.

**Given** the implementation
**When** inspected
**Then** it uses jj-lib's diff machinery (specific API depends on jj-lib 0.41.0 — likely `jj_lib::merged_tree::MergedTree::diff_stream` or equivalent)
**And** does NOT shell to `jj diff` (AR-AP-1).

**Edge cases:**

**Given** a file with no newline at end-of-file
**When** processed
**Then** the resulting `HunkLine` preserves the EOF state via a separator/sentinel mechanism (documented in the schema later)
**And** the JSON output indicates the EOF-state per line.

**Given** a hunk that spans 1000 lines
**When** processed
**Then** the `Hunk.lines` Vec contains 1000 entries
**And** memory usage is proportional to the actual line content size (Strings are owned).

**Given** revisions where `from == to`
**When** `compute_hunks(repo, from, to)` is called
**Then** the result is `Ok(vec![])` (empty — no diff)
**And** no error.

---

### Story 5.2: Word-level diff via `imara-diff` Histogram

As a Rust developer enhancing line-level hunks with word granularity,
I want `crates/zanshin-diff/src/word_diff.rs` using `imara-diff` with the Histogram algorithm to identify word-level segments inside `Removed`/`Added` line pairs (FR-DF-1 enrichment),
So that the UI/MCP can render character-precision Delta-class diffs.

**Acceptance Criteria:**

**Given** `crates/zanshin-diff/src/word_diff.rs`
**When** created
**Then** it defines `pub struct Segment { pub text: String, pub kind: SegmentKind }` and `pub enum SegmentKind { Equal, Added, Removed }`.

**Given** a pair of `(removed_line: &str, added_line: &str)` from adjacent `HunkLine::Removed` + `HunkLine::Added`
**When** `compute_word_diff(removed_line, added_line) -> (Vec<Segment>, Vec<Segment>)` is called
**Then** it returns two `Vec<Segment>`: one for the removed line (with `Equal` + `Removed` segments), one for the added line (with `Equal` + `Added` segments)
**And** the segments are aligned word-by-word.

**Given** the implementation
**When** inspected
**Then** it uses `imara_diff::Algorithm::Histogram` (per FR-DF-1)
**And** tokenizes by Unicode word boundaries (`unicode-segmentation` crate or imara-diff's own tokenizer).

**Given** a removed line `"fn foo(x: i32) -> i32"` and added line `"fn foo(y: i32) -> u32"`
**When** word-diffed
**Then** the removed segments are: `[Equal("fn foo("), Removed("x"), Equal(": i32) -> "), Removed("i32"), Equal("")]`
**And** the added segments are: `[Equal("fn foo("), Added("y"), Equal(": i32) -> "), Added("u32"), Equal("")]`.

**Given** a removed line and an added line that share no words (complete rewrite)
**When** word-diffed
**Then** the removed segments are all `Removed`, the added segments are all `Added`
**And** the algorithm correctly identifies this as a no-overlap case.

**Given** a `HunkLine::Removed` without an adjacent `HunkLine::Added` (a pure deletion)
**When** processed
**Then** word-diffing is skipped — the entire line is a single `Removed` segment
**And** the function `compute_word_diff` is only called on pair-able lines.

**Given** the pairing logic
**When** a hunk has 5 contiguous `Removed` lines followed by 3 `Added` lines
**Then** the first 3 `Removed` are paired with the 3 `Added` for word-diffing
**And** the remaining 2 `Removed` lines have no word-diff (entire lines marked `Removed`)
**And** this pairing strategy is documented as the "default Delta-class behaviour".

**Given** unit tests in `crates/zanshin-diff/tests/word_diff.rs`
**When** they run
**Then** they cover: minor character change ("x" → "y"), entire-line rewrite, multiple word changes in a single line, Unicode characters (emoji, accented characters).

**Edge cases:**

**Given** lines that differ only in whitespace
**When** word-diffed
**Then** whitespace is segmented per `unicode-segmentation` rules
**And** trailing whitespace changes show up as small `Removed`/`Added` segments.

**Given** extremely long lines (e.g., minified JS, 100k characters)
**When** word-diffed
**Then** the algorithm completes in reasonable time (imara-diff's Histogram is `O(n log n)` worst case)
**And** the perf test (Story 5.7) confirms the < 500ms budget holds.

**Given** lines with embedded NULL bytes (defensive)
**When** word-diffed
**Then** the algorithm processes them as part of the string
**And** does not panic.

---

### Story 5.3: tree-sitter-highlight integration (`highlight.rs`)

> **WIP-rework (2026-05-17):** Keep the tree-sitter-highlight integration and the syntax-class output schema. **Drop** fallback-strategy ACs (multiple parsers per language, retry logic) and **drop** incremental-highlighting ACs. Plain-text fallback for unknown extensions stays.

As a Rust developer adding syntax classes to diff segments,
I want `crates/zanshin-diff/src/highlight.rs` using `tree-sitter-highlight` to assign a `syntax_class` to each segment,
So that consumers can render syntax-highlighted diffs (FR-DF-2).

**Acceptance Criteria:**

**Given** `crates/zanshin-diff/src/highlight.rs`
**When** created
**Then** it defines `pub fn highlight_line(line: &str, language: &Language) -> Vec<HighlightedToken>` where `HighlightedToken = { range: Range<usize>, class: Option<SyntaxClass> }` and `SyntaxClass` is an enum of standard categories (keyword, string, comment, function, type, variable, number, operator, punctuation, etc.).

**Given** the `Language` enum
**When** inspected
**Then** variants are `Rust, Dart, TypeScript, JavaScript, Python, Markdown, Toml, Yaml, Json, Html, PlainText` (per FR-DF-5 Kern-Set 9 + PlainText fallback).

**Given** a Rust line `"fn foo(x: i32) -> i32"`
**When** highlighted
**Then** the resulting tokens correctly classify:
- `"fn"` → `keyword`
- `"foo"` → `function`
- `"x"` → `variable`
- `":"` → `punctuation`
- `"i32"` → `type`
- etc.

**Given** the `merge_highlight(segments: Vec<Segment>, tokens: Vec<HighlightedToken>) -> Vec<HighlightedSegment>` function
**When** called
**Then** it overlays the per-token classification onto the word-diff segments
**And** produces `HighlightedSegment { text, kind: SegmentKind, syntax_class: Option<SyntaxClass> }` where a segment may span multiple token boundaries (the segment's classification is the most-frequent class within its range, OR each segment is further split at token boundaries — implementation choice; documented in `schemas/diff.v1.schema.json`).
**Decision:** segments are split at token boundaries — finer granularity, slightly larger JSON output, but unambiguous classification.

**Given** plain-text fallback for unknown file extensions
**When** the language detection (Story 5.4) returns `Language::PlainText`
**Then** `highlight_line` returns `Vec<HighlightedToken>` with no syntax classes (all `class: None`)
**And** the merge function produces segments with `syntax_class: None`.

**Given** tree-sitter parsing
**When** a syntactically invalid line is processed (e.g., `"fn foo("`)
**Then** tree-sitter's error-recovery mode produces partial classifications
**And** the function returns whatever classes were extracted (no error).

**Given** unit tests in `crates/zanshin-diff/tests/highlight.rs`
**When** they run
**Then** they cover: Rust keywords + identifiers + types, Dart class declarations, JSON object keys + values, Markdown headings, PlainText fallback returns no classes.

**Edge cases:**

**Given** a multi-line construct (e.g., a Rust function body)
**When** highlighted line-by-line (the diff context is per-line)
**Then** tree-sitter's parser may not have enough context for accurate classification on a single line
**And** the function operates in best-effort mode — classifications are correct for the line's content, not the surrounding context
**And** the limitation is documented.

**Given** a language with significant whitespace (Python)
**When** highlighted
**Then** indentation-only segments are classified as `whitespace` (or `None`)
**And** the per-line analysis works correctly for typical lines.

**Given** very large lines (10k+ characters)
**When** highlighted
**Then** the function completes — tree-sitter scales linearly
**And** the perf test (Story 5.7) confirms the < 500ms budget.

---

### Story 5.4: Bundle initial 3 grammars (`grammars.rs`) — Rust / Dart / Markdown

> **WIP-rework (2026-05-17):** Shrunk from Kern-Set 9 (rust, dart, ts/js, python, markdown, toml, yaml, json, html) to **3 grammars**: rust, dart, markdown. Other languages added on demand later (each is a small additive PR). Plain-text fallback for unknown extensions stays.

As a Rust developer bundling the initial grammar set,
I want `crates/zanshin-diff/src/grammars.rs` declaring the Kern-Set 9 tree-sitter grammar dependencies as Cargo deps and a language-detection function based on file extension,
So that FR-DF-5 (bundled grammars) is satisfied and unknown extensions fall back to plain text.

**Acceptance Criteria:**

**Given** `crates/zanshin-diff/Cargo.toml`
**When** inspected
**Then** it declares the following dependencies pinned per AR-P-8 (`=x.y.z` for pre-1.0 deps):
- `tree-sitter-rust`
- `tree-sitter-dart`
- `tree-sitter-typescript` (includes both TypeScript and JavaScript flavours per the upstream crate's API)
- `tree-sitter-python`
- `tree-sitter-md` (Markdown)
- `tree-sitter-toml-ng` (or `tree-sitter-toml`, whichever is current)
- `tree-sitter-yaml`
- `tree-sitter-json`
- `tree-sitter-html`
**And** each is opted-out of unwanted features via `default-features = false, features = [...]` where appropriate, with `# WHY:` comments.

**Given** `crates/zanshin-diff/src/grammars.rs`
**When** created
**Then** it defines `pub fn detect_language(file_path: &Path) -> Language` returning:
- `Path` ending in `.rs` → `Language::Rust`
- `.dart` → `Dart`
- `.ts` → `TypeScript`
- `.tsx` → `TypeScript` (TSX flavour)
- `.js, .jsx, .mjs, .cjs` → `JavaScript`
- `.py, .pyi` → `Python`
- `.md, .markdown` → `Markdown`
- `.toml` → `Toml`
- `.yaml, .yml` → `Yaml`
- `.json, .jsonc` → `Json`
- `.html, .htm` → `Html`
- Anything else → `PlainText`

**Given** a special-case filename without extension (e.g., `Cargo.toml`, `pubspec.yaml`, `Dockerfile`)
**When** detected
**Then** the function also matches a small registry of known filenames:
- `Cargo.toml`, `Cargo.lock` → `Toml`
- `pubspec.yaml`, `pubspec.lock` → `Yaml`
- `Dockerfile` → `PlainText` (no bundled grammar)
**And** the special-case list is documented in the source.

**Given** the function
**When** called with a file whose extension is uppercase (`README.MD`)
**Then** the comparison is case-insensitive
**And** returns `Markdown`.

**Given** a tree-sitter `Language` instance is required for highlighting (Story 5.3)
**When** `Language::tree_sitter_language(&self) -> tree_sitter::Language` is called
**Then** it returns the corresponding `tree_sitter::Language` instance (each bundled crate exports a `language()` function)
**And** for `PlainText`, returns a sentinel / panics (no tree-sitter language for plain text — the `highlight_line` function checks the variant before constructing the highlighter).

**Given** the highlight queries (each tree-sitter grammar ships an `.scm` file for highlighting)
**When** loaded
**Then** each `Language` variant has an embedded `&'static str` containing its grammar's highlight query (via `include_str!`)
**And** the query string is loaded at first use, cached in a `OnceCell`.

**Given** unit tests in `crates/zanshin-diff/tests/grammars.rs`
**When** they run
**Then** they cover: each extension's detection, case-insensitivity, special-filename matches, unknown extension → PlainText.

**Edge cases:**

**Given** a file with multiple dots (`file.test.ts`)
**When** detected
**Then** the function uses the **final** extension (`.ts`) for language detection
**And** returns `TypeScript`.

**Given** a file with no extension and not in the special-case list (`README`)
**When** detected
**Then** the result is `PlainText`
**And** no error.

**Given** a future need to add a new language (e.g., Go)
**When** a contributor PRs the addition
**Then** they: add `tree-sitter-go` dep, add the `Go` enum variant, extend `detect_language`, update tests
**And** the PRD's OD-9 list is updated in the same PR (or a follow-up).

---

### Story 5.5: JSON output + `diff.v1.schema.json`

> **Transport reconciled to FlatBuffers (2026-06-20):** The `serde`-JSON output + `schemas/diff.v1.schema.json` + `jsonschema`/`json_schema` premise below predates [ADR-0001](../../docs/adr/0001-ffi-data-transport-flatbuffers.md) and is superseded. The diff crosses as a FlatBuffers `Diff` table (the file/hunk/line/segment shape shown below maps 1:1 to nested FlatBuffers tables) added to `schemas/envelope.fbs`'s `Payload` union — defined in `schemas/*.fbs`, not JSON Schema; no `schema_version`, no `.v1` infix, no version-bump rule. Drop `serde::Serialize`; the contract is typed accessors + the `Verifier`. The < 500 ms number stays a soft design target. Merges into the FlatBuffers schema work consumed by Story 5.8.

As a Rust developer producing serializable diff output,
I want `crates/zanshin-diff/src/output.rs` serializing diffs to JSON conforming to `schemas/diff.v1.schema.json` (FR-DF-3, AR-AD-3),
So that the FFI surface and consumers parse diffs with schema validation.

**Acceptance Criteria:**

**Given** `schemas/diff.v1.schema.json`
**When** created
**Then** it defines a top-level object:
```json
{
  "schema_version": "1.0",
  "files": [
    {
      "path": "string",
      "language": "rust|dart|...|plain_text",
      "binary": false,
      "hunks": [
        {
          "before_range": { "start": number, "end": number },
          "after_range": { "start": number, "end": number },
          "lines": [
            {
              "kind": "context|removed|added",
              "segments": [
                {
                  "text": "string",
                  "kind": "equal|added|removed",
                  "syntax_class": "keyword|string|...|null"
                }
              ]
            }
          ]
        }
      ]
    }
  ]
}
```
**And** `additionalProperties: false` at every level.

**Given** `crates/zanshin-diff/src/output.rs`
**When** created
**Then** it defines `pub struct DiffOutput { schema_version: &'static str, files: Vec<FileDiff> }` and the nested types matching the schema.

**Given** a `DiffOutput`
**When** serialized via `serde_json::to_string(...)`
**Then** the output is valid JSON
**And** passes validation against `schemas/diff.v1.schema.json` (Rust test using `jsonschema`).

**Given** the Dart side
**When** parsing a diff JSON response (wired in Story 5.8)
**Then** it validates against the same schema via Dart's `json_schema` package.

**Given** a binary file
**When** serialized
**Then** the `FileDiff` has `binary: true`, `hunks: []`, no line-level data.

**Given** a context line in a hunk
**When** serialized
**Then** its `segments` field contains a single `{"text": "<line content>", "kind": "equal", "syntax_class": <class>}` entry (no word-diff for context lines).

**Given** the compact serialization
**When** measured against a 5k-line diff
**Then** the JSON output is < 5 MB
**And** serialization completes well within the < 500ms NFR-P-3 budget.

**Given** unit tests
**When** they run
**Then** they: build a tiny `DiffOutput` (1 file, 2 hunks, 5 lines), serialize, parse, validate, assert round-trip equality.

**Edge cases:**

**Given** a file with a `syntax_class` that doesn't fit the schema's enum
**When** serialized
**Then** the schema validation fails — forcing the developer to either add the class to the enum (minor bump) or normalize to an existing class
**And** the schema's enum lists the canonical class names.

**Given** an empty `files` array (no changes between revisions)
**When** serialized
**Then** the output is `{"schema_version": "1.0", "files": []}`
**And** validates.

---

### Story 5.6: Diff between two revisions API

As a Rust caller wanting to diff arbitrary revision pairs,
I want `crates/zanshin-diff/src/lib.rs` exposing `pub fn compute_diff(repo: &Repo, from: ChangeId, to: ChangeId) -> Result<DiffOutput, DiffError>` that orchestrates hunks, word-diff, highlighting, and output (FR-DF-4),
So that the FFI wrapper (Story 5.8) and any direct Rust caller have a single entry point.

**Acceptance Criteria:**

**Given** `crates/zanshin-diff/src/lib.rs`
**When** created
**Then** it re-exports the public types (`DiffOutput`, `FileDiff`, `HighlightedSegment`, `Language`, `DiffError`)
**And** exposes `pub fn compute_diff(repo: &Repo, from: ChangeId, to: ChangeId) -> Result<DiffOutput, DiffError>`.

**Given** `compute_diff(repo, from, to)`
**When** called
**Then** it:
1. Calls `hunks::compute_hunks(repo, from, to)`
2. For each file, calls `grammars::detect_language(&file_path)`
3. For each hunk, pairs adjacent `Removed`/`Added` lines and calls `word_diff::compute_word_diff(...)`
4. For each line, calls `highlight::highlight_line(...)` and `merge_highlight(...)`
5. Builds the `DiffOutput` and returns it.

**Given** the `from == to` case
**When** called
**Then** it returns `Ok(DiffOutput { schema_version: "1.0", files: vec![] })`
**And** does not error.

**Given** an invalid change ID
**When** called
**Then** it returns `Err(DiffError::ChangeNotFound { id })`.

**Given** unit tests in `crates/zanshin-diff/tests/integration.rs`
**When** they run
**Then** they: extract a fixture, choose two known change IDs, call `compute_diff`, validate the output against the schema, assert key fields (file count, hunk count, line count) match the fixture's known modifications.

**Given** the `DiffError` enum
**When** inspected
**Then** variants include `ChangeNotFound { id }`, `JjLibError(...)`, `TreeSitterError(...)`, `IoError(io::Error)`.

**Edge cases:**

**Given** a diff that includes a renamed file
**When** computed
**Then** the resulting `FileDiff` has `path: <new_path>` (or both old and new — TBD per schema; current schema has single `path` field, so old path encoded in a note or via separate "moved-from" field added in a minor schema bump if needed).
**Decision for 0.1:** schema uses `path` as new-path; rename detection is implicit (an Added file with the same content as a Removed file). Future minor schema bump may add `moved_from: Option<String>` field.

**Given** a diff with many small files (e.g., 100 files, 1 hunk each)
**When** computed
**Then** the total time is bounded by the sum of per-file costs
**And** the perf test (Story 5.7) characterises the typical case.

---

### Story 5.7: ~~5k-line performance test~~ — DELETED (WIP-rework 2026-05-17)

> **Why deleted:** No perf-gate enforcement in WIP. NFR-P-3 (`< 500ms`) remains as a soft design target — algorithm choice (`imara-diff` Histogram) reflects it. Full perf test returns in the release phase.

### Story 5.7-OLD: 5k-line performance test

As a developer enforcing NFR-P-3,
I want an integration test that calls `compute_diff` on a 5k-line changed file and asserts completion in < 500 ms,
So that diff-performance regressions are caught at PR time.

**Acceptance Criteria:**

**Given** `crates/zanshin-diff/tests/perf.rs`
**When** created
**Then** it uses fixture diff inputs at `test-fixtures/diffs/rust-5k-lines.before.in` and `.after.in` (committed Rust source files of ~5000 lines each, with known differences)
**And** sets up a synthetic Repo or uses a direct API surface to feed the two contents into `compute_diff`.

**Given** the test
**When** it runs
**Then** it times `compute_diff(...)` and asserts elapsed < 750 ms (CI slack on top of the < 500ms NFR-P-3 budget per Story 2.2 reference-hardware buffer).

**Given** the test runs in CI on `macos-latest`
**When** the timing is 600 ms (within slack)
**Then** the test passes
**And** the CI log includes the timing.

**Given** the test logs per-stage timing
**When** it runs
**Then** it outputs:
- Hunk computation time
- Word-diff time
- Tree-sitter highlight time
- JSON serialization time
**And** each is reviewable per PR.

**Given** the perf budget is exceeded
**When** the test fails
**Then** the failure message names the bottleneck stage
**And** the developer investigates: tree-sitter grammar overhead? imara-diff Histogram for super-long lines? JSON serialization?

**Given** the fixture diff inputs
**When** generated
**Then** they are also generated via `cargo xtask gen-fixture --size 5k-line-diff` (an addition to the xtask from Epic 2 Story 2.1) to keep the inputs reproducible
**And** committed to `test-fixtures/diffs/`.

**Edge cases:**

**Given** the test runs on a heavily-loaded CI runner
**When** the slack is insufficient
**Then** the test retries up to 2 times
**And** if still failing, the developer investigates (similar to Epic 4 Story 4.5's approach).

---

### Story 5.8: FFI wrapper (`zanshin-ffi/src/diff.rs`)

> **Transport reconciled to FlatBuffers (2026-06-20):** The `*mut c_char` signature, the JSON `{"id":"<hex>"}` inputs, and the `schemas/diff.v1.schema.json` / `jsonschema` ACs below predate [ADR-0001](../../docs/adr/0001-ffi-data-transport-flatbuffers.md) and are superseded. `zanshin_diff_compute(repo_handle: u64, from_id: *const c_char, to_id: *const c_char) -> *mut ZanshinBuf`: change-ids are lone strings (CString) per ADR-0001 — **not** JSON-wrapped (`from_id_json` / `to_id_json` go away). The result is the `Diff` payload (Story 5.5, now `.fbs`); large diffs ride the buffer+len token, not a CString. Tests read via generated typed accessors + the `Verifier` — no `jsonschema`.

As a Dart caller wanting to fetch diff data,
I want `crates/zanshin-ffi/src/diff.rs` exposing `zanshin_diff_compute(repo_handle, from_id, to_id)` returning a JSON envelope with the `DiffOutput`,
So that the worker isolate (Story 3.9) gets diff data via the standard envelope pattern.

**Acceptance Criteria:**

**Given** `crates/zanshin-ffi/src/diff.rs`
**When** created
**Then** it defines:
```rust
#[no_mangle]
pub unsafe extern "C" fn zanshin_diff_compute(repo_handle: *mut c_void, from_id_json: *const c_char, to_id_json: *const c_char) -> *mut c_char;
```
**And** wraps via `envelope::catch(|| { ... })`.

**Given** `zanshin_diff_compute(repo_handle, from_id, to_id)`
**When** called
**Then** it: validates the repo handle, parses `from_id_json` and `to_id_json` as JSON `{"id": "<hex>"}`, calls `zanshin_diff::compute_diff(...)`, serializes the result, returns the envelope.

**Given** the envelope's `data` field
**When** parsed by Dart
**Then** it matches `schemas/diff.v1.schema.json` (validated by both Rust and Dart tests).

**Given** `cargo make codegen`
**When** run
**Then** `zanshin_ffi.h` and `bindings.dart` include the new function.

**Given** Dart's `commands.dart` (from Epic 3 Story 3.9)
**When** updated
**Then** it adds `DiffComputeCommand { handle_id: int, from_change_id: String, to_change_id: String }` to the sealed hierarchy.

**Given** integration tests
**When** they run
**Then** they: open a fixture, send `DiffComputeCommand` for a known change pair, receive the envelope, validate JSON, assert file/hunk/line counts.

**Edge cases:**

**Given** the same diff is requested twice in quick succession
**When** both calls happen
**Then** each is independently computed (no caching at this layer — caching would be a future optimization based on observed UX patterns)
**And** the worker isolate's single-threaded model serializes them.

**Given** a very large diff (e.g., 10k-line file with 80% changes)
**When** computed
**Then** the JSON envelope's `data` field may be many MB
**And** the C-string return mechanism handles this (CString can be arbitrarily large)
**And** Dart-side memory consumption is bounded by the parse-into-typed-objects step.

---

## Epic 6: Write Path & `extern "C"` Mutation Exposure

Add the mutating side of `zanshin-jj` (describe/new/edit/abandon/undo as P0; remote fetch/push; conflict handoff) and expose them through `zanshin-ffi`. Every mutation must be visible and reversible in `jj op log`, indistinguishable from a CLI-initiated one (NFR-R-1, NFR-R-2). Advanced and rare mutations are deferred-story stubs.

### Story 6.1: P0 essentials mutations (`mutate.rs`) — describe, new, edit, abandon

> **WIP-rework (2026-05-17):** Keep all original ACs. **Append**: a two-thread concurrent-write smoke test (~80-100 lines in `zanshin-jj/tests/concurrent_writes.rs`) that boots a tempdir repo and has two threads run interleaved `describe` + `new` calls directly against the `zanshin-jj` API. Assertions: jj-lib's internal locking produces no spurious errors at the FFI boundary; the FFI envelope's error-channel doesn't misinterpret jj's stderr-style warnings. This consumes Murat's Szenario-1 from the dropped Story 7.8.

As a Rust caller (FFI consumer or MCP),
I want `crates/zanshin-jj/src/mutate.rs` exposing `Repo::describe`, `Repo::new`, `Repo::edit`, `Repo::abandon` going through jj-lib only (no CLI shelling),
So that the four most-frequent change mutations are available and FR-JJ-10a is satisfied.

**Acceptance Criteria:**

**Given** `crates/zanshin-jj/src/mutate.rs`
**When** created
**Then** it defines on the `Repo` struct (or as free functions taking `&mut Repo`):
- `pub fn describe(&mut self, change_id: ChangeId, description: &str) -> Result<MutationResult, MutateError>`
- `pub fn new_change(&mut self, parents: &[ChangeId]) -> Result<MutationResult, MutateError>`
- `pub fn edit(&mut self, change_id: ChangeId) -> Result<MutationResult, MutateError>`
- `pub fn abandon(&mut self, change_ids: &[ChangeId]) -> Result<MutationResult, MutateError>`

**Given** the `MutationResult` struct
**When** inspected
**Then** it has `pub struct MutationResult { pub new_op_id: OperationId, pub new_change_ids: Vec<ChangeId>, pub abandoned_change_ids: Vec<ChangeId>, pub working_copy_change_id: ChangeId }`.

**Given** `Repo::describe(change_id, "New description")`
**When** called
**Then** it updates the change's description via jj-lib's API (likely `Workspace::transaction` + `MutableRepo::set_description` or equivalent)
**And** records a new operation in the op-log
**And** returns the new op-id.

**Given** `Repo::new_change(parents)`
**When** called with one parent
**Then** it creates a new empty change with that parent
**And** updates the working copy to point at it
**And** returns the new change-id.

**Given** `Repo::new_change(parents)`
**When** called with multiple parents
**Then** it creates a merge change with all listed parents.

**Given** `Repo::edit(change_id)`
**When** called
**Then** it switches the working copy to the specified change (jj-lib's `edit` semantics)
**And** records the operation in the op-log.

**Given** `Repo::abandon(change_ids)`
**When** called
**Then** it abandons all listed changes
**And** if the working copy was on an abandoned change, jj-lib auto-creates a new working-copy change at the parent (standard jj behaviour)
**And** the result's `new_change_ids` reflects any auto-created working-copy change.

**Given** the implementation
**When** inspected
**Then** every mutation uses jj-lib's transaction pattern: `let mut tx = repo.start_transaction(...)?; tx.mut_repo().<mutation>; tx.commit(...)?;`
**And** does NOT shell to `jj` CLI (AR-AP-1).

**Given** unit tests in `crates/zanshin-jj/tests/mutate.rs`
**When** they run
**Then** they cover:
- describe: change has new description, op-log records the change
- new_change: working copy points at the new change, op-log records it
- edit: working copy switches, op-log records it
- abandon: change is gone from working DAG, op-log records it, abandoning the working-copy change triggers auto-creation

**Given** `Repo::abandon(&[])`
**When** called with empty slice
**Then** it returns `Err(MutateError::InvalidInput { reason: "abandon requires at least one change id" })`.

**Given** any mutation
**When** the op-log is read after via `Repo::op_log(Some(1))`
**Then** the most recent operation matches the just-performed mutation
**And** is identical to what `jj op log` would show (NFR-R-2).

**Edge cases:**

**Given** `Repo::describe(non_existent_change_id, ...)`
**When** called
**Then** it returns `Err(MutateError::ChangeNotFound { id })`.

**Given** `Repo::describe(change_id, "")` (empty description)
**When** called
**Then** it sets the description to empty string (valid in jj — anonymous-change state)
**And** the change's `is_anonymous` (from Epic 2 Story 2.6) becomes `true`.

**Given** concurrent mutations from another consumer (e.g., MCP server while GUI mutates)
**When** both write to the same repo
**Then** jj-lib handles the op-log divergence — both operations land, jj resolves the heads automatically
**And** FR-MCP-9's same-repo concurrency is exercised (validated in Epic 7).

---

### Story 6.2: Op-log undo (P0)

> **WIP-rework (2026-05-17):** Shrunk to a thin `jj op restore` wrapper. **Drop** undo-stack-UI-surface ACs and multi-step replay ACs. The Dart-side worker hands a single `undo` command to the FFI; the FFI calls `jj op restore` and returns. UI-level undo-stack design returns when UI is in scope.

As a Rust caller wanting to undo the last operation,
I want `crates/zanshin-jj/src/op_log.rs` (extended) exposing `Repo::undo() -> MutationResult`,
So that the most-recent operation can be reverted (FR-JJ-14a).

**Acceptance Criteria:**

**Given** `crates/zanshin-jj/src/op_log.rs`
**When** extended
**Then** it adds `pub fn undo(&mut self) -> Result<MutationResult, MutateError>`.

**Given** `Repo::undo()`
**When** called after a `describe` operation
**Then** it reverts the description change
**And** the change's description returns to its prior value
**And** the op-log records the undo as a new operation (jj's `op undo` semantics).

**Given** `Repo::undo()`
**When** called after a `new_change` operation
**Then** it reverts the new change
**And** the working copy returns to the prior state.

**Given** `Repo::undo()`
**When** called when the op-log has only the root operation (nothing to undo)
**Then** it returns `Err(MutateError::NothingToUndo)`.

**Given** the implementation
**When** inspected
**Then** it uses jj-lib's op-restore mechanism (`jj_lib::op_walk::resolve_op_with_repo` or similar — to walk back one operation)
**And** does NOT shell to `jj undo` (AR-AP-1).

**Given** unit tests
**When** they run
**Then** they: perform a mutation, undo it, verify the state matches pre-mutation, verify the op-log has 2 new ops (the mutation + the undo).

**Edge cases:**

**Given** `Repo::undo()` called twice in a row
**When** the second call runs
**Then** it undoes the previous undo (i.e., redoes the original mutation)
**And** the op-log records both undos.

**Given** an undo across multiple jj operations (e.g., `op restore <id>`)
**When** the user wants this
**Then** they use FR-JJ-14b's `op restore` API (deferred — Story 6.12)
**And** plain `undo()` only walks back one op.

---

### Story 6.3: ~~Conflict ops (`conflict.rs`)~~ — DELETED (WIP-rework 2026-05-17)

> **Why deleted:** Not on the WIP build/run path — Ralph can create a conflict manually in the test repo and observe via the read-path. The conflict-resolve FFI is a linear add-on to the mutation surface (6.5) — nachrüstbar ohne Rewrite. FR-JJ-12 marked deferred in PRD § 4.1.

### Story 6.3-OLD: Conflict ops (`conflict.rs`)

As a Rust caller wanting to handle conflicts,
I want `crates/zanshin-jj/src/conflict.rs` exposing `Repo::list_conflicts(change_id) -> Vec<ConflictFile>` and `Repo::resolve_after_edit(change_id) -> Result<MutationResult>` (FR-JJ-12),
So that the UI/MCP can guide users through conflict resolution after external edits.

**Acceptance Criteria:**

**Given** `crates/zanshin-jj/src/conflict.rs`
**When** created
**Then** it defines `pub struct ConflictFile { pub path: PathBuf, pub markers_present: bool, pub size_bytes: u64 }`
**And** `pub fn list_conflicts(&self, change_id: ChangeId) -> Result<Vec<ConflictFile>, MutateError>`
**And** `pub fn resolve_after_edit(&mut self, change_id: ChangeId) -> Result<MutationResult, MutateError>`.

**Given** `Repo::list_conflicts(change_id)`
**When** called on a change with conflicts
**Then** it returns one `ConflictFile` per conflicting path
**And** `markers_present: true` if the file contains conflict markers (jj-lib's check), false if user has cleared them.

**Given** `Repo::resolve_after_edit(change_id)`
**When** called after the user has cleared conflict markers externally
**Then** it invokes jj-lib's resolve-from-workspace logic (`jj resolve` equivalent)
**And** updates the change to remove its conflict state
**And** records the operation in op-log.

**Given** `Repo::resolve_after_edit` on a change with no conflicts
**When** called
**Then** it returns `Err(MutateError::NoConflicts { id })` (or `Ok` with a no-op? — implementation choice; documented as no-op `Ok` to make idempotent calls safe).
**Decision:** idempotent `Ok` — calling resolve on a clean change is a no-op success.

**Given** the implementation
**When** inspected
**Then** it uses jj-lib's conflict-state API
**And** does NOT shell to `jj resolve` (AR-AP-1).

**Given** unit tests in `crates/zanshin-jj/tests/conflict.rs`
**When** they run
**Then** they: create a fixture with intentional conflicts, list conflicts (assert paths match), clear markers in the working tree, call `resolve_after_edit`, assert the conflict state clears.

**Edge cases:**

**Given** a conflicted file where the user has not actually resolved (markers still present)
**When** `resolve_after_edit` is called
**Then** the change remains conflicted (jj-lib's check)
**And** the function returns `Err(MutateError::UnresolvedMarkers { paths })`.

**Given** a binary conflict (jj-lib handles these specially)
**When** listed
**Then** the `ConflictFile` has `markers_present: false` (no text markers — binary conflict resolution is out of scope for this API)
**And** future story may add binary-conflict resolution helpers.

---

### Story 6.4a: Remote op — `git fetch` with progress callback

> **WIP-rework (2026-05-17):** Renamed from 6.4 to 6.4a. **Drop `git push`** entirely from WIP. Keep `git fetch` with progress callback (`NativeCallable.listener` via FR-FFI-8) — this is the real consumer of the progress-callback pattern in WIP, exercising the AD-5 / 3-6 plumbing under production-ish load (libgit2 progress events fire every N bytes during a real network fetch). `push` deferred to release phase (FR-JJ-13b in PRD) — adding it later is a linear new wrapper, no Pattern-Refactor needed.

As a Rust caller wanting to sync with remotes,
I want `crates/zanshin-jj/src/remotes.rs` (extended) exposing `Repo::git_fetch(remote, progress)` and `Repo::git_push(remote, bookmarks, progress)` accepting a progress callback (FR-JJ-13),
So that long-running network operations report progress to the FFI consumer.

**Acceptance Criteria:**

**Given** `crates/zanshin-jj/src/remotes.rs`
**When** extended
**Then** it adds:
```rust
pub type ProgressFn = dyn Fn(ProgressEvent) + Send + Sync;
pub struct ProgressEvent { pub operation: String, pub progress: f32, pub message: String }
pub fn git_fetch(&mut self, remote_name: &str, progress: &ProgressFn) -> Result<MutationResult, MutateError>;
pub fn git_push(&mut self, remote_name: &str, bookmark_names: &[&str], progress: &ProgressFn) -> Result<MutationResult, MutateError>;
```

**Given** `Repo::git_fetch("origin", callback)`
**When** called
**Then** it delegates to jj-lib's git-fetch implementation
**And** during the fetch, calls `callback(ProgressEvent { operation: "fetch", progress: 0.xx, message: "..." })` at regular intervals
**And** on completion, records a new operation in the op-log.

**Given** `Repo::git_push("origin", &["main"], callback)`
**When** called
**Then** it delegates to jj-lib's git-push (which uses `gix` or `git2` internally for the wire protocol)
**And** progress events are forwarded
**And** the push targets only the listed bookmarks.

**Given** the callback signature
**When** wired into the FFI in Story 6.5
**Then** the FFI side wraps the Dart-supplied `NativeCallable.listener` (per Story 3.6) into a `ProgressFn`
**And** events conform to `schemas/progress.v1.schema.json`.

**Given** a fetch failure (network error, auth failure)
**When** it occurs
**Then** the function returns `Err(MutateError::NetworkError { reason })`
**And** no partial state is committed to the repo (jj-lib's transaction model handles rollback).

**Given** unit tests in `crates/zanshin-jj/tests/remotes_write.rs`
**When** they run
**Then** they: set up a local-only Git remote (via a tmpdir bare repo), perform fetch + push against it, assert progress events arrived, assert op-log records the operations
**And** they do NOT depend on network access (purely local fixture).

**Edge cases:**

**Given** a remote that doesn't exist
**When** `git_fetch("nonexistent", callback)` is called
**Then** it returns `Err(MutateError::RemoteNotFound { name })`.

**Given** authentication failures (HTTPS without credentials, SSH key issues)
**When** they occur
**Then** the error message is descriptive (jj-lib / gix error chained)
**And** the user knows what to fix.

**Given** very frequent progress events (e.g., 1000 per second)
**When** the callback is invoked
**Then** the FFI-side dispatch (per Story 3.6) handles the rate via the bounded mpsc channel
**And** events may be dropped if the channel is full (per AR-AD-5)
**And** the user-visible progress is best-effort — final 100% is always delivered (the final event is guaranteed by the function returning).

---

### Story 6.5: FFI mutation surface — `zanshin-ffi/src/repo.rs` (write extensions)

> **Transport reconciled to FlatBuffers (2026-06-20):** The `*mut c_char` signatures, the `args_json` JSON-string inputs, the `internal.serialization_failed` code, and `schemas/change.v1.schema.json` below predate [ADR-0001](../../docs/adr/0001-ffi-data-transport-flatbuffers.md) and are superseded. Each mutation returns `*mut ZanshinBuf` (FlatBuffers `Envelope` token). Composite inputs cross as FlatBuffers (a per-call request table) or decompose to scalars + lone strings (CString) per ADR-0001 — **no `args_json`**; malformed/missing inputs yield `ffi.invalid_argument` / `ffi.null_pointer` / `ffi.utf8_error` (drop `internal.serialization_failed`). The success payload is the `MutationResult` table in `schemas/envelope.fbs`'s `Payload` union (Story 6.6, now `.fbs`), regenerated via `cargo make codegen`. `op_id` stays a plain `u64` scalar. Tests read via typed accessors + the `Verifier` — no `jsonschema`.

As a Dart caller wanting to perform mutations,
I want `crates/zanshin-ffi/src/repo.rs` extended with write-side functions wrapping the Epic 6.1–6.4 mutations,
So that the worker isolate has callable endpoints for describe, new, edit, abandon, undo, fetch, push, conflict-resolve.

**Acceptance Criteria:**

**Given** `crates/zanshin-ffi/src/repo.rs`
**When** extended
**Then** it adds:
```rust
#[no_mangle] pub unsafe extern "C" fn zanshin_describe(handle: *mut c_void, args_json: *const c_char) -> *mut c_char;
#[no_mangle] pub unsafe extern "C" fn zanshin_new(handle: *mut c_void, args_json: *const c_char) -> *mut c_char;
#[no_mangle] pub unsafe extern "C" fn zanshin_edit(handle: *mut c_void, args_json: *const c_char) -> *mut c_char;
#[no_mangle] pub unsafe extern "C" fn zanshin_abandon(handle: *mut c_void, args_json: *const c_char) -> *mut c_char;
#[no_mangle] pub unsafe extern "C" fn zanshin_undo(handle: *mut c_void) -> *mut c_char;
#[no_mangle] pub unsafe extern "C" fn zanshin_git_fetch(handle: *mut c_void, args_json: *const c_char, op_id: u64) -> *mut c_char;
#[no_mangle] pub unsafe extern "C" fn zanshin_git_push(handle: *mut c_void, args_json: *const c_char, op_id: u64) -> *mut c_char;
#[no_mangle] pub unsafe extern "C" fn zanshin_resolve(handle: *mut c_void, args_json: *const c_char) -> *mut c_char;
```
**And** each wraps via `envelope::catch(|| { ... })`.

**Given** each function's `args_json` parameter
**When** parsed
**Then** the schema for each is:
- describe: `{"change_id": "<hex>", "description": "<text>"}`
- new: `{"parents": ["<hex>", ...]}`
- edit: `{"change_id": "<hex>"}`
- abandon: `{"change_ids": ["<hex>", ...]}`
- git_fetch: `{"remote": "<name>"}`
- git_push: `{"remote": "<name>", "bookmarks": ["<name>", ...]}`
- resolve: `{"change_id": "<hex>"}`

**Given** the `op_id` parameter on fetch/push
**When** non-zero
**Then** it correlates with a previously-registered progress callback (per Story 3.6)
**And** progress events for this operation are routed to that callback.

**Given** every mutation function
**When** it succeeds
**Then** the envelope's `data` is the serialized `MutationResult` (Story 6.1)
**And** the schema is `schemas/change.v1.schema.json` extended in Story 6.6.

**Given** `cargo make codegen`
**When** run
**Then** the new functions appear in `zanshin_ffi.h` and `bindings.dart`.

**Given** Dart's `commands.dart`
**When** extended (Epic 3 Story 3.9's hierarchy)
**Then** it adds: `DescribeCommand`, `NewCommand`, `EditCommand`, `AbandonCommand`, `UndoCommand`, `GitFetchCommand`, `GitPushCommand`, `ResolveCommand`.

**Given** integration tests
**When** they run
**Then** they: spawn the worker, open a fixture, perform each mutation, validate the envelope JSON, assert the op-log shows the expected sequence.

**Edge cases:**

**Given** a mutation called with a malformed `args_json`
**When** processed
**Then** the envelope returns `code: "internal.serialization_failed"` with a clear message.

**Given** concurrent mutations from different Dart-isolate consumers (theoretical — AR-AD-2 forbids)
**When** they happen
**Then** behaviour is undefined as documented; the worker isolate model prevents this in practice.

---

### Story 6.6: `schemas/change.schema.json` extension for mutations

> **WIP-rework (2026-05-17):** Extend the existing `change` schema in place to cover mutation responses (the mutate calls return the new change-id + op-id). **Drop** versioning ACs, **drop** migration ACs, **drop** backward-compat-shim ACs. Filename has no `.v1` infix in WIP. Breaking changes happen in-place; callers update.

> **Transport reconciled to FlatBuffers (2026-06-20):** This whole story is recast from JSON Schema to FlatBuffers per [ADR-0001](../../docs/adr/0001-ffi-data-transport-flatbuffers.md). There is no `schemas/change.v1.schema.json`; the `Change` and `MutationResult` shapes become FlatBuffers tables in `schemas/*.fbs` (added to the `Envelope` `Payload` union), regenerated via `cargo make codegen` and committed. **Drop every versioning AC** (`schema_version`, `.v1` / `.v2` filenames, `_v2` suffixes, minor-bump / `additionalProperties` rules, and the `schemas/README.md` reference to the deleted Story 1.8): WIP edits the `.fbs` in place and updates all callers in the same PR (project-context FFI rules). Validation is the typed accessors + the `Verifier`, both sides — no `jsonschema` / `json_schema`.

As an architect maintaining schema parity,
I want `schemas/change.v1.schema.json` (created in Epic 2 implicitly via Change struct's serialization) extended to include the `MutationResult` shape,
So that mutation responses are schema-validated like all other FFI output (AR-AD-3).

**Acceptance Criteria:**

**Given** `schemas/change.v1.schema.json`
**When** created/extended
**Then** it includes the `Change` shape from Epic 2 (id, parents, description, author, etc.)
**And** also includes `MutationResult`: `{ schema_version: "1.0", new_op_id: string, new_change_ids: Array<string>, abandoned_change_ids: Array<string>, working_copy_change_id: string }`.

**Given** alternatively, two separate schemas
**When** considered
**Then** the **decision** is to keep them in one file `change.v1.schema.json` with both top-level types defined via `$defs`
**And** `MutationResult` and `Change` are independently referenced by FFI functions.

**Given** the schema
**When** an FFI function returns a `MutationResult` (Story 6.5)
**Then** the envelope's `data` matches the `MutationResult` portion of `change.v1.schema.json`
**And** Rust + Dart tests both validate.

**Given** future minor changes (e.g., adding `affected_files_count: number` to `MutationResult`)
**When** they happen
**Then** the schema bumps to `change.v1` minor version (no `_v2` suffix needed for additive)
**And** old consumers ignore the new field.

**Given** a future breaking change (e.g., renaming `new_op_id` to `operation_id`)
**When** it happens
**Then** a new `change.v2.schema.json` is created
**And** new FFI functions with `_v2` suffix use the new schema (per AR-AD-3).

**Given** the `schemas/README.md` from Epic 1 Story 1.8
**When** updated PR-style
**Then** `change.v1.schema.json` is in the inventory with both `Change` and `MutationResult` listed.

---

### Story 6.7: ~~Op-log visibility test (NFR-R-2)~~ — DELETED (WIP-rework 2026-05-17)

> **Why deleted:** NFR-R-2 (every Zanshin mutation visible+reversible in `jj op log`) remains as a code invariant, asserted via design: all mutations route through `zanshin-jj` → `jj-lib`, which produces op-log entries by construction. A dedicated test that round-trips mutation → op_log parse → assert visible was discussed (Murat KEEP, Amelia CUT); Ralph cut it. A regression here would be caught the first time anyone uses `jj op log` against a Zanshin-modified repo. Test returns in the release phase as part of the supportability-hardening pass.

### Story 6.7-OLD: Op-log visibility test (NFR-R-2)

As a developer enforcing NFR-R-2 (every Zanshin-initiated mutation visible/reversible in op-log, indistinguishable from CLI-initiated),
I want an integration test that performs each P0 mutation via the FFI, then re-opens the repo and inspects op-log via the same FFI, and asserts the operations are present and correctly described,
So that the data-loss-prevention invariant is mechanically verified.

**Acceptance Criteria:**

**Given** `crates/zanshin-ffi/tests/op_log_visibility.rs`
**When** created
**Then** it defines tests for each P0 mutation (describe, new, edit, abandon, undo, git_fetch on a local-bare-remote, git_push):
1. Open fixture
2. Perform mutation via FFI
3. Read op-log via FFI
4. Assert the most-recent op describes the mutation correctly
5. Re-open the repo (close + reopen) — assert the op-log is consistent

**Given** a `describe` mutation
**When** performed via FFI
**Then** the op-log entry's `description` field contains the word "describe" (jj's standard op-log description for this operation)
**And** the operation is undoable via the next mutation test (subsequent `undo` reverts it).

**Given** the test
**When** it cross-validates by also reading op-log via `zanshin_jj::Repo::op_log` directly (bypassing FFI)
**Then** both paths return identical data
**And** any divergence would indicate a bug in either the adapter or the FFI wrapper.

**Given** the equivalence assertion (NFR-R-2: indistinguishable from CLI-initiated)
**When** the test optionally shells out to `jj op log` for comparison (only in dev environments with `jj` installed)
**Then** the structured op-log from FFI matches the textual `jj op log` output
**And** this comparison is gated behind a feature flag (no `jj` CLI dependency in CI by default).

**Given** unit-level coverage
**When** the test runs in CI
**Then** all P0 mutations are tested
**And** any new mutation added in future stories (e.g., split/squash/rebase deferred) extends this test in the same PR.

**Edge cases:**

**Given** a mutation that auto-creates a working-copy change (e.g., abandon of the current change)
**When** performed
**Then** the op-log shows two entries: the abandon + the auto-creation
**And** the test asserts both are present.

**Given** a fetch operation against a local bare-remote
**When** performed
**Then** the op-log records the fetch
**And** the test confirms the bookmark updates landed.

---

### Story 6.8: ~~[Deferred 0.2] Advanced mutations — split, squash, rebase~~ — DELETED (WIP-rework 2026-05-17)

> **Why deleted:** Already marked deferred; with the WIP scope cuts there's no reason to keep the stub.

**Status:** Deferred to 0.2 (P1 per PRD §4.1).

As a future implementer planning 0.2 work,
I want a story stub for FR-JJ-10b (advanced mutations: split, squash, rebase),
So that the deferred work is visible in the backlog with placeholder acceptance criteria.

**Acceptance Criteria (stub for future implementation):**

**Given** `crates/zanshin-jj/src/mutate.rs`
**When** extended for 0.2
**Then** it adds: `pub fn split(...)`, `pub fn squash(...)`, `pub fn rebase(...)` — each going through jj-lib only, returning `MutationResult`.

**Given** rebase
**When** invoked with a `-d <dest>` destination
**Then** it rebases the specified change (or chain) onto the destination
**And** records the operation in op-log
**And** handles conflicts by returning `Err(MutateError::ConflictsDetected { changes_with_conflicts })` (UI handles resolution flow via Story 6.3).

**Given** the FFI exposure
**When** the 0.2 story is written
**Then** new functions `zanshin_split`, `zanshin_squash`, `zanshin_rebase` are added to `crates/zanshin-ffi/src/repo.rs`.

**Given** MCP exposure
**When** the 0.2 story includes the MCP tools
**Then** Epic 7's MCP write tools (Story 7.4) are extended to include these (per FR-MCP-4 which already lists them — the MCP-side may be implemented earlier than the FFI-side, since MCP uses `zanshin-jj` directly without going through FFI).

**Out of 0.1 scope:** No implementation work in this story until 0.2.

---

### Story 6.9: ~~[Deferred 0.2] Bookmark CRUD~~ — DELETED (WIP-rework 2026-05-17)

> **Why deleted:** Already marked deferred.

**Status:** Deferred to 0.2 (P1 per PRD §4.1).

As a future implementer planning 0.2 work,
I want a story stub for FR-JJ-11 (bookmark create, move, delete, track, untrack, forget),
So that the deferred work is visible in the backlog.

**Acceptance Criteria (stub for future implementation):**

**Given** `crates/zanshin-jj/src/bookmarks.rs`
**When** extended
**Then** it adds: `Repo::create_bookmark`, `Repo::move_bookmark`, `Repo::delete_bookmark`, `Repo::track_bookmark`, `Repo::untrack_bookmark`, `Repo::forget_bookmark`.

**Given** the FFI exposure
**When** added
**Then** `zanshin_bookmark_*` functions appear in `crates/zanshin-ffi/src/repo.rs`.

**Given** schema impact
**When** assessed
**Then** `schemas/bookmarks.v1.schema.json` may be added with shapes for the mutation responses.

**Out of 0.1 scope:** No implementation work in this story until 0.2.

---

### Story 6.10: ~~[Deferred P1] Settings read/write~~ — DELETED (WIP-rework 2026-05-17)

> **Why deleted:** Already marked deferred.

**Status:** Deferred (P1, jj's global config picks up most defaults per PRD §4.1).

As a future implementer,
I want a story stub for FR-JJ-15 (settings access — user.email, user.name, signing key, defaults),
So that the deferred work is visible.

**Acceptance Criteria (stub for future implementation):**

**Given** `crates/zanshin-jj/src/settings.rs`
**When** added
**Then** it exposes: `Repo::get_setting(key) -> Option<String>`, `Repo::set_setting(key, value, scope: Scope) -> Result<()>` where `Scope = Repo | Global`.

**Given** schema impact
**When** assessed
**Then** `schemas/settings.v1.schema.json` may be added.

**Out of 0.1 scope:** No implementation work in this story until needed.

---

### Story 6.11: ~~[Deferred P2] Rare mutations~~ — DELETED (WIP-rework 2026-05-17)

> **Why deleted:** Already marked deferred.

**Status:** Deferred (P2 per PRD §4.1).

As a future implementer,
I want a story stub for FR-JJ-10c (duplicate, restore, backout — rare mutations),
So that the deferred work is visible.

**Acceptance Criteria (stub for future implementation):**

**Given** `crates/zanshin-jj/src/mutate.rs`
**When** extended
**Then** it adds: `Repo::duplicate(change_id)`, `Repo::restore(change_id, from)`, `Repo::backout(change_id)`.

**Out of 0.1 scope:** No implementation work until needed; lower priority than write-path P0/P1.

---

### Story 6.12: ~~[Deferred P2] Op-restore + op-diff~~ — DELETED (WIP-rework 2026-05-17)

> **Why deleted:** Already marked deferred.

**Status:** Deferred (P2 per PRD §4.1).

As a future implementer,
I want a story stub for FR-JJ-14b (op restore — restore to a specific operation, and op-diff — compute diff between operations),
So that the deferred work is visible.

**Acceptance Criteria (stub for future implementation):**

**Given** `crates/zanshin-jj/src/op_log.rs`
**When** extended
**Then** it adds: `Repo::op_restore(op_id)`, `Repo::op_diff(op_a, op_b)`.

**Given** schema impact
**When** assessed
**Then** `schemas/op_log.v1.schema.json` may be extended for op-diff result shape.

**Out of 0.1 scope:** No implementation work until needed.

---

## Epic 7: `zanshin-mcp` Binary

Build the standalone MCP server binary using `rmcp`, exposing read + write tools at LLM-quality description level, bundled into the macOS `.app` and usable as a standalone CLI. Validate same-repo concurrency with the GUI/CLI via the filesystem-watcher path.

### Story 7.1: Binary scaffold + rmcp stdio init + repo selection (--repo / CWD walk-up)

As a developer scaffolding the MCP binary,
I want `crates/zanshin-mcp/src/main.rs` + `env.rs` setting up an `rmcp` stdio server with `--repo <path>` CLI argument and CWD-walk-up fallback (AR-AD-6, FR-MCP-1, FR-MCP-2),
So that an MCP host can spawn `zanshin-mcp` and the binary correctly identifies the target repo.

**Acceptance Criteria:**

**Given** `crates/zanshin-mcp/src/main.rs`
**When** created
**Then** it uses `clap` (or `pico-args` for minimal-deps) to parse `--repo <path>` argument
**And** if absent, walks up from `std::env::current_dir()` looking for `.jj/`
**And** errors with a clear stderr-free message (file-only logging — see Story 7.2) if no `.jj/` is found.

**Given** `crates/zanshin-mcp/src/env.rs`
**When** created
**Then** it defines `pub fn resolve_repo_path(cli_arg: Option<&Path>) -> Result<PathBuf, EnvError>` that:
1. If `cli_arg` is `Some(p)`, returns `p.canonicalize()` after verifying `p.join(".jj").is_dir()`
2. Else, walks up from `current_dir()` checking each ancestor for `.jj/`
3. Returns `Err(EnvError::NoRepoFound)` if neither succeeds.

**Given** `main`
**When** the binary starts
**Then** it:
1. Initializes file-only tracing (Story 7.2)
2. Resolves the repo path (logs the resolved path at info level)
3. Opens the repo via `zanshin_jj::Repo::open(&path)`
4. Initializes an `rmcp` `Server` with stdio transport
5. Registers tools (Stories 7.3 + 7.4)
6. Runs the server loop until stdin EOF or signal.

**Given** the binary uses `rmcp` v1.7.0
**When** initializing
**Then** the server's name is `"zanshin-mcp"` and version matches `CARGO_PKG_VERSION`
**And** the protocol version is set per rmcp defaults.

**Given** signal handling
**When** the process receives SIGTERM or stdin EOF
**Then** it gracefully shuts down (drops the Repo handle, flushes tracing)
**And** exits 0.

**Given** unit tests in `crates/zanshin-mcp/tests/env.rs`
**When** they run
**Then** they cover: `--repo` with valid path → ok, `--repo` with invalid path → error, no `--repo` + CWD inside a fixture repo → walks up correctly, no `--repo` + CWD outside any repo → NoRepoFound.

**Edge cases:**

**Given** a CWD that is itself a `.jj/` directory (`/repo/.jj`)
**When** walk-up resolves
**Then** it returns the parent (`/repo/`) as the repo root
**And** the canonicalize step strips the `.jj/` suffix.

**Given** a symlinked repo path
**When** resolved
**Then** `canonicalize` follows the symlink to the real path
**And** the binary operates on the canonical path.

**Given** `--repo` and the discovered CWD-walk-up path both point to different repos
**When** the CLI arg is set
**Then** `--repo` wins (explicit > implicit).

---

### Story 7.2: File-only tracing in ALL build modes (AR-P-5-MCP)

As a developer enforcing the MCP-protocol-stability invariant,
I want `crates/zanshin-mcp/src/tracing_init.rs` setting up tracing with a file-only sink **in all build modes** (including release and debug — stricter than AR-P-5's general rule),
So that no stderr/stdout output ever corrupts the MCP stdio protocol.

**Acceptance Criteria:**

**Given** `crates/zanshin-mcp/src/tracing_init.rs`
**When** created
**Then** it defines `pub fn init_mcp_tracing()` that:
1. Creates `~/Library/Logs/Zanshin/mcp.log.YYYY-MM-DD` daily rolling file
2. Sets up `tracing_subscriber::fmt::Layer` writing **only** to that file
3. Explicitly does NOT add any `Stdout` or `Stderr` writer in any build mode
4. Reads `ZANSHIN_MCP_LOG` env var for level (default `info`)

**Given** the function is called from `main()`
**When** the binary starts
**Then** no startup banner, no version string, no warning is written to stdout/stderr
**And** all logging goes to the daily file.

**Given** a contributor accidentally adds a `println!`, `eprintln!`, or `dbg!` call
**When** the binary runs
**Then** the MCP host (Claude Desktop) sees corrupted protocol output
**And** a CI lint (`clippy::print_stdout` and `clippy::print_stderr` denied at crate level) catches this at PR time.

**Given** `crates/zanshin-mcp/src/lib.rs` (or `main.rs`)
**When** inspected
**Then** it has `#![deny(clippy::print_stdout, clippy::print_stderr, clippy::dbg_macro)]`
**And** any future need to log goes through `tracing::info!` etc.

**Given** the rmcp library
**When** it internally logs
**Then** its logs also route through tracing (rmcp uses `tracing` per its docs)
**And** no rmcp output reaches stdio.

**Given** a runtime error that cannot be logged (e.g., the log file is unwritable)
**When** it occurs
**Then** the binary does NOT fall back to stderr (silent failure preferred over protocol corruption)
**And** the error is recorded somewhere best-effort (in-memory buffer, surfaced via diagnostics tool — TBD; documented as acceptable trade-off).

**Given** unit tests
**When** they run
**Then** they capture stdout/stderr via redirection and assert zero bytes written to either
**And** the test runs the binary end-to-end with a mock stdio (rmcp's testing utilities or manual subprocess capture).

**Edge cases:**

**Given** the `~/Library/Logs/Zanshin/` directory cannot be created (permission denied)
**When** init runs
**Then** the binary either:
1. Falls back to a `/tmp/zanshin-mcp.log.*` file (with a documented behaviour), or
2. Continues silently with no logging.
**Decision:** option 1 — fall back to `/tmp/` with a one-time `tracing::error!` (which goes to the new fallback file, not stderr) noting the issue.

**Given** the log file grows large
**When** the daily roll happens (at midnight)
**Then** the old file persists, a new file is opened
**And** auto-cleanup of files older than 30 days may be added in a future story (out of 0.1 scope).

---

### Story 7.3: Read tools — status, log, show, diff, op_log, bookmarks, remotes

As an MCP host consumer (Claude Desktop, etc.),
I want the `zanshin-mcp` server registering read tools (`status`, `log`, `show`, `diff`, `op_log`, `bookmarks`, `remotes`) that call `zanshin-jj` directly (no FFI), returning JSON results,
So that an LLM can query repo state through MCP (FR-MCP-3).

**Acceptance Criteria:**

**Given** `crates/zanshin-mcp/src/tools/mod.rs`
**When** created
**Then** it sets up a tool registry that maps tool name → handler function
**And** the handler signature is `async fn(args: serde_json::Value, repo: &Repo) -> Result<serde_json::Value, McpError>`.

**Given** `crates/zanshin-mcp/src/tools/read.rs`
**When** created
**Then** it registers tools:
- `status` — no args, returns `Status` (Epic 2 Story 2.4)
- `log` — args `{"revset": "...", "limit": <n>}`, returns `Array<Change>` resolved via revset
- `show` — args `{"change_id": "..."}`, returns full `Change` metadata
- `diff` — args `{"from": "...", "to": "..."}`, returns diff JSON (calls `zanshin-diff::compute_diff`)
- `op_log` — args `{"limit": <n>}`, returns `Array<Operation>`
- `bookmarks` — no args, returns `Array<Bookmark>`
- `remotes` — no args, returns `Array<Remote>`

**Given** each tool
**When** invoked by an MCP host
**Then** the handler validates the args against an inline JSON schema (via `schemars` crate or hand-written)
**And** errors with `McpError::InvalidInput { details }` on validation failure.

**Given** the read tools call `zanshin-jj` directly (no FFI involved, no `zanshin-ffi` dependency on the MCP side per FR-MCP-1)
**When** inspected
**Then** the imports in `read.rs` use `zanshin_jj::*` types
**And** the `Cargo.toml` of `zanshin-mcp` depends on `zanshin-jj`, `zanshin-diff`, and `rmcp` — but NOT on `zanshin-ffi`.

**Given** the JSON return shape
**When** consumed by an LLM
**Then** it matches the same `schemas/*.v1.schema.json` files (Story 2.4–2.9 types + Story 5.5 diff type)
**And** the schemas are the single source of truth for both FFI and MCP responses.

**Given** unit tests in `crates/zanshin-mcp/tests/read_tools.rs`
**When** they run
**Then** they: spawn the MCP server (via in-process rmcp test harness, no actual stdio), open a fixture repo, invoke each read tool, assert the response matches expected schema.

**Edge cases:**

**Given** an invalid revset in the `log` tool
**When** invoked
**Then** the handler returns `McpError::InvalidInput { details: "<revset parse error>" }`
**And** no panic.

**Given** the `diff` tool called with from == to
**When** processed
**Then** it returns an empty diff (no files)
**And** no error.

---

### Story 7.4: Write tools — describe, new (WIP subset)

> **WIP-rework (2026-05-17):** Shrunk dramatically. Keep MCP write-tool implementations for **`describe` + `new`** only. **Drop** `edit`, `abandon`, `undo`, `fetch`, `push`, bookmark CRUD, `split`/`squash`/`rebase` — they land later as the corresponding `zanshin-jj` mutations are added beyond the P0 subset. MCP-host integration patterns are exercised by the two-tool subset.

As an MCP host consumer wanting to perform mutations,
I want the `zanshin-mcp` server registering write tools (describe, new, edit, abandon, split, squash, rebase, undo, bookmark CRUD, git fetch, git push) calling `zanshin-jj` directly (FR-MCP-4),
So that an LLM can drive repo mutations through MCP.

**Acceptance Criteria:**

**Given** `crates/zanshin-mcp/src/tools/write.rs`
**When** created
**Then** it registers write tools:
- `describe` — args `{"change_id": "...", "description": "..."}`
- `new` — args `{"parents": [...]}`
- `edit` — args `{"change_id": "..."}`
- `abandon` — args `{"change_ids": [...]}`
- `undo` — no args
- `git_fetch` — args `{"remote": "..."}`
- `git_push` — args `{"remote": "...", "bookmarks": [...]}`
- Deferred-stub registration for `split`, `squash`, `rebase`, bookmark CRUD (P1/0.2 per PRD §4.1)

**Given** P0 write tools
**When** invoked
**Then** they call the corresponding `zanshin_jj::Repo::*` mutation
**And** return the `MutationResult` as JSON
**And** the operation is visible in `jj op log` (NFR-R-2).

**Given** P1/P2 deferred tools
**When** an MCP host invokes them in 0.1
**Then** the tool returns `McpError::NotImplemented { reason: "scheduled for 0.2 — see PRD FR-JJ-10b" }`
**And** the tool descriptions clearly mark them as deferred.

**Given** progress callbacks (fetch/push)
**When** the rmcp server supports progress notifications (rmcp v1.7.0 supports server-initiated notifications)
**Then** the long-running ops emit progress as MCP progress notifications
**And** the LLM/host can render progress to the user.

**Given** unit tests in `crates/zanshin-mcp/tests/write_tools.rs`
**When** they run
**Then** they: open a fixture, perform each P0 mutation via the tool, verify the op-log records it.

**Edge cases:**

**Given** a write tool called on a repo opened read-only (theoretical — jj doesn't really have read-only mode, but defensive)
**When** the mutation fails
**Then** the tool returns `McpError::OperationFailed { details }`
**And** no partial state.

**Given** a write tool's args fail schema validation (e.g., empty `change_id`)
**When** processed
**Then** the tool returns `McpError::InvalidInput`
**And** the LLM gets a clear error to retry with corrected args.

---

### Story 7.5: Basic tool descriptions + parameter docs

> **WIP-rework (2026-05-17):** Shrunk. Each tool must have a non-empty one-line description and parameter docs (basic discoverability). **Drop** the "LLM-quality gate" framing, **drop** usage-example requirements, **drop** any `mcp-tester`-driven quality-bar assertions. LLM-quality iteration returns in the release phase.

As an MCP host consumer relying on the LLM to pick the right tool,
I want every tool's description, parameter doc, and at least one usage example written at high quality (FR-MCP-5, FR-MCP-5 quality gate, AR-G-7 mcp-tester smoke run),
So that an LLM picks tools correctly without trial-and-error.

**Acceptance Criteria:**

**Given** every tool registered in `tools/read.rs` and `tools/write.rs`
**When** its description is inspected
**Then** it has:
- A one-line summary (≤ 100 chars) starting with a verb: "Show working-copy status", "List operations in the op-log", etc.
- A multi-line description explaining when to use, what it returns, common parameter combinations
- For every parameter: name, type, optional/required, default, usage notes
- At least one concrete usage example as a code-fenced JSON object: `{"tool": "log", "args": {"revset": "trunk()..@", "limit": 20}}`

**Given** the description is exposed via rmcp's tool registration
**When** an MCP client queries the tools list
**Then** the full description (summary + body + params + examples) is visible
**And** matches the format expected by Claude Desktop / Cline / similar hosts.

**Given** the `show` tool description
**When** read
**Then** it explains: "Use `show` to retrieve full metadata for a specific change including description, author, timestamps, parents, signature, and conflict state. Use `status` instead for the working-copy summary."

**Given** the `describe` tool description
**When** read
**Then** it warns: "This is a MUTATING operation that updates a change's description and records a new operation in the op-log. Use `undo` to revert."

**Given** the deferred-stub tools
**When** their descriptions are inspected
**Then** they prominently say: "STATUS: deferred to 0.2 — use the GUI or CLI for this operation in 0.1".

**Given** the `mcp-tester` smoke run (AR-G-7)
**When** invoked against the running `zanshin-mcp` binary
**Then** it validates that:
- Every tool has a non-empty description
- Every parameter is documented
- Every tool has at least one example
**And** the smoke run is added as a CI step in `cargo make test` (Epic 1 Story 1.4).

**Given** a quality review
**When** Ralph (or a future-LLM evaluator) inspects the descriptions
**Then** they're at the level of professional API docs — not auto-generated boilerplate, not terse one-liners.

**Edge case — Tool name collisions:**

**Given** tools with similar names (e.g., `log` vs. `op_log`)
**When** an LLM is choosing
**Then** the descriptions explicitly say "Use `log` for change history; use `op_log` for jj's operation history. These are different concepts in jj."

**Edge case — Disambiguation:**

**Given** the `new` tool conflicts with English keyword conventions
**When** documented
**Then** the description explicitly disambiguates: "Create a new empty change as a child of the given parent(s). This is jj's `jj new` command — different from creating a file or directory."

---

### Story 7.6: ~~Bundle `zanshin-mcp` into `Zanshin.app`~~ — DELETED (WIP-rework 2026-05-17)

> **Why deleted:** WIP runs `zanshin-mcp` as a standalone CLI binary (Story 7.7's standalone usability covers this — though 7.7 is also CUT for polish reasons; the binary still works standalone by virtue of being a separate binary). Bundling into the macOS `.app` re-evaluates at release-phase, alongside codesigning. FR-MCP-7 marked deferred in PRD § 4.5.

### Story 7.6-OLD: Bundle `zanshin-mcp` into `Zanshin.app`

As a release manager wiring the bundling,
I want `cargo make build` (Epic 1 Story 1.4) to copy the `zanshin-mcp` binary into `app/macos/Runner/Resources/zanshin-mcp` and `flutter build macos` to include it in the final `.app/Contents/Resources/zanshin-mcp` (FR-MCP-7),
So that the GUI and MCP server ship together.

**Acceptance Criteria:**

**Given** `cargo make build`
**When** run
**Then** the build sequence:
1. `cargo build --release -p zanshin-mcp` produces `target/release/zanshin-mcp`
2. A post-build step copies `target/release/zanshin-mcp` to `app/macos/Runner/Resources/zanshin-mcp` (committed-empty target dir; the binary is gitignored)
3. `flutter build macos --release` packages everything into the `.app`, including the binary in `Contents/Resources/`

**Given** the final `.app` is produced
**When** inspected
**Then** `Zanshin.app/Contents/Resources/zanshin-mcp` exists and is executable
**And** running it from the terminal launches the MCP binary correctly.

**Given** the binary's executable permission
**When** the `cargo make build` step copies it
**Then** the executable bit is preserved (chmod +x on macOS).

**Given** `docs/mcp-host-config.md` (added in this story)
**When** read
**Then** it documents:
- The path to the bundled binary: `/Applications/Zanshin.app/Contents/Resources/zanshin-mcp` (or wherever the user installs the app)
- The Claude Desktop `claude_desktop_config.json` snippet:
```json
{
  "mcpServers": {
    "zanshin": {
      "command": "/Applications/Zanshin.app/Contents/Resources/zanshin-mcp",
      "args": ["--repo", "/path/to/your/repo"]
    }
  }
}
```
- Alternative: using the standalone CLI binary directly (Story 7.7).

**Given** the binary is codesigned (Epic 8)
**When** notarized
**Then** the embedded `zanshin-mcp` is signed and notarized as a hardened-runtime binary (Epic 8 wiring).

**Edge cases:**

**Given** the `app/macos/Runner/Resources/zanshin-mcp` path is intermediate
**When** the user opens the project in Xcode
**Then** the resource is bundled normally via Xcode's Copy Bundle Resources phase
**And** the `cargo make build` step ensures the binary is at the right path before flutter triggers Xcode.

**Given** the bundled binary version drifts from the bundling app version
**When** detected
**Then** the build asserts version equality (since both share the workspace version per AR-AD-7)
**And** a mismatch is a build error.

---

### Story 7.7: ~~Standalone CLI usability~~ — DELETED (WIP-rework 2026-05-17)

> **Why deleted:** Polish-tier story (`--help` formatting, error message wording, exit-code conventions). The binary still runs standalone (it's a separate binary on disk; the `--repo`-or-CWD-walkup behaviour from Story 7.1 is the actual standalone-CLI mechanic). Polish returns in the release phase.

### Story 7.7-OLD: Standalone CLI usability

As a developer or advanced user wanting to test MCP without the GUI,
I want `zanshin-mcp` to work as a standalone CLI binary invokable directly (e.g., `./zanshin-mcp --repo .`),
So that MCP-protocol testing and embedding in non-GUI environments is possible (FR-MCP-8).

**Acceptance Criteria:**

**Given** `cargo build --release -p zanshin-mcp`
**When** run
**Then** `target/release/zanshin-mcp` is a standalone executable
**And** running `./target/release/zanshin-mcp --help` prints usage info to stdout (note: this is the **only** exception to the file-only-tracing rule — `--help` MUST go to stdout because it's not part of the MCP protocol; it's invoked before the protocol starts).

**Decision:** `--help` and `--version` are explicit pre-protocol commands that print to stdout and exit. They do NOT corrupt the MCP protocol because they short-circuit before rmcp's protocol loop starts.

**Given** `./zanshin-mcp --repo /path/to/repo`
**When** invoked manually with stdin connected to a terminal
**Then** the binary starts the MCP server loop
**And** waits for JSON-RPC messages on stdin
**And** writes responses to stdout (this is the **only** other stdout usage — it's the MCP protocol output itself).

**Given** `docs/mcp-host-config.md`
**When** read
**Then** it includes a "Manual testing" section explaining:
- How to spawn `zanshin-mcp` with a manual stdin (e.g., via `socat` or `mcp-tester`)
- How to send a `tools/list` JSON-RPC request
- How to interpret responses

**Given** an MCP CLI tester (`mcp-tester` or similar)
**When** invoked against the standalone binary
**Then** it can discover tools, invoke them, and receive responses correctly.

**Given** the binary running without `--repo` and outside any `.jj/` repo
**When** invoked
**Then** it errors with a clear stderr-free message (logged to file)
**And** exits non-zero
**And** stdout is empty (no protocol output without a repo).

**Edge case — Background process:**

**Given** the binary is launched as a background process (without stdio attached)
**When** running
**Then** the rmcp library detects the missing stdio and exits cleanly
**And** does not hang indefinitely.

**Edge case — Multiple instances on same repo:**

**Given** two `zanshin-mcp` instances spawned against the same `--repo`
**When** both run concurrently
**Then** both work (FR-MCP-9 — same-repo concurrency via filesystem mutation)
**And** their op-log mutations interleave correctly via jj's automatic head resolution.

---

### Story 7.8: ~~Same-repo concurrency test (GUI + MCP)~~ — DELETED (WIP-rework 2026-05-17)

> **Why deleted:** Murat's first-runde Szenario 3 (op_heads divergence stale cache) was based on an assumed cache that the architecture doesn't actually have (`zanshin-graph`'s lane-cache is rebuilt on every op_heads change). After his correction the residual concurrency risk reduced to Szenario 1 (concurrent direct-API calls produce no spurious errors), which is appended as a small two-thread smoke at the end of Story 6.1 instead. Szenario 2 (watcher-storm) wandert in Story 3.10. The dedicated GUI+MCP-binary integration test returns in the release phase.

### Story 7.8-OLD: Same-repo concurrency test (GUI + MCP) — FR-MCP-9 / FR-RX-3

As a developer validating FR-MCP-9 / FR-RX-3,
I want an integration test that runs the GUI's worker isolate AND a `zanshin-mcp` binary simultaneously against the same fixture repo, performs mutations from each, and asserts both see each other's changes via the watcher path,
So that the no-IPC same-repo concurrency model is mechanically verified.

**Acceptance Criteria:**

**Given** `app/integration_test/mcp_concurrency_test.dart`
**When** created
**Then** the test:
1. Extracts a fixture repo
2. Spawns the GUI worker isolate via `ZanshinWorker` (Story 3.9)
3. Spawns the `zanshin-mcp` binary as a subprocess pointing at the same repo path
4. Subscribes both to their respective watcher event streams
5. Performs a `describe` via the worker (GUI-side mutation)
6. Asserts the MCP-side watcher fires within 500 ms with the corresponding op-heads event
7. Performs a `describe` via the MCP binary (using JSON-RPC over the subprocess's stdin/stdout)
8. Asserts the GUI-side watcher fires within 500 ms
9. Reads the op-log from both sides and asserts both see all 2 operations

**Given** the JSON-RPC client logic for the MCP-side test
**When** invoking the MCP binary
**Then** the test sends a `tools/call` request for the `describe` tool
**And** waits for the `tools/call` response
**And** can also subscribe to MCP server notifications if needed.

**Given** the GUI-side worker
**When** it performs a mutation
**Then** the FS mutation is observed by both watchers (the worker's own watcher AND the MCP's watcher of the same `op_heads/heads/` dir).
**Note:** in this architecture, only the GUI-side has a watcher in `zanshin-ffi`; the MCP binary's "watcher" is conceptual — it polls or watches at the OS level via its own `notify-rs` if needed. **Decision for 0.1:** the MCP binary itself does NOT have a watcher (it's a request-response server). The test verifies that:
- The GUI-side watcher fires when MCP mutates (because MCP writes to op-heads, which the GUI watcher monitors).
- Sequencing of operations via op-log is consistent — both consumers see all mutations.

**Adjustment:** simplify the test to verify GUI-side perception of MCP mutations (the asymmetry is by design — MCP is request-response, GUI is event-driven).

**Given** the simplified test
**When** it runs
**Then** it:
1. Spawns the worker
2. Spawns the MCP binary
3. From the test process, sends an MCP request to describe a change
4. Asserts the GUI worker's watcher fires within 500 ms (FR-RX-3)
5. Cross-validates: the GUI worker's status call shows the change has the new description
6. Cleans up both processes.

**Given** the test fails intermittently
**When** retried (up to 2 times)
**Then** persistent failure indicates a real concurrency bug, not flakiness
**And** the developer investigates.

**Edge cases:**

**Given** the MCP binary takes longer than expected to start
**When** the test tries to send a request before it's ready
**Then** the test waits up to 5 seconds for the binary's `initialize` MCP handshake before erroring out.

**Given** the MCP binary crashes mid-test
**When** detected
**Then** the test fails with the binary's exit code and any stderr (since stderr is silent per Story 7.2, but exit code helps diagnose).

---

### Story 7.9: MCP server boot + list-tools smoke

> **WIP-rework (2026-05-17):** Shrunk from the original `mcp-tester` LLM-quality smoke to a minimal **"server boots, lists tools"** test. The test boots `zanshin-mcp --repo <fixture>`, sends the `tools/list` MCP request over stdio, and asserts the response contains the WIP tool subset. Purpose: prevent the MCP code path from silently rotting. Full `mcp-tester`-driven smoke returns in the release phase.

As a developer enforcing AR-G-7,
I want a CI step running `mcp-tester` (or equivalent) against the built `zanshin-mcp` binary as part of `cargo make test`,
So that protocol-level regressions are caught automatically.

**Acceptance Criteria:**

**Given** `mcp-tester` is available (either via `cargo install`, `npm i -g`, or vendored as a small Rust script in `xtask`)
**When** invoked via `cargo make test`
**Then** it:
1. Spawns `target/debug/zanshin-mcp --repo test-fixtures/repos/tiny-3-commits-extracted/` (after extracting the fixture)
2. Sends `tools/list` and asserts the expected tool count + names
3. Invokes each read tool with valid args and asserts non-error responses
4. Invokes each P0 write tool with valid args and asserts non-error responses (on a writable fixture)
5. Validates each response against `schemas/*.v1.schema.json`

**Given** the smoke run
**When** any tool fails validation
**Then** `cargo make test` fails
**And** the CI surfaces the offending tool + response.

**Given** the smoke run runtime
**When** measured
**Then** total time < 30 seconds (read-only fixtures + small mutation set).

**Given** the smoke run uses a copy of the fixture (so the tests can mutate it)
**When** they run
**Then** the mutation tests don't affect the canonical fixture archive.

**Given** the `mcp-tester` tool itself
**When** missing
**Then** `cargo make test` skips this step with a clear "mcp-tester not found; install via X" warning
**And** the CI ensures `mcp-tester` is installed (added to Story 1.9's setup).
**Decision:** for 0.1, write a minimal in-house `mcp-tester` inside `xtask` rather than depending on an external tool — keeps dependencies under control.

**Given** the in-house tester at `crates/xtask/src/tasks/mcp_smoke.rs`
**When** run via `cargo xtask mcp-smoke`
**Then** it implements the test sequence above
**And** uses `tokio::process::Command` to spawn the MCP binary, JSON-RPC over stdio, schema validation via the `jsonschema` crate.

**Edge cases:**

**Given** the MCP binary hangs during the smoke run
**When** detected
**Then** the tester has a 30-second timeout per tool invocation
**And** kills the process on timeout with a clear error.

**Given** schemas evolve and the smoke run uses outdated expectations
**When** detected
**Then** the smoke run fails on schema mismatch
**And** the PR that changes schemas also updates the smoke run.

---

### Story 7.10: Structured MCP error responses (basic mapping)

> **WIP-rework (2026-05-17):** Keep the basic mapping: `zanshin-jj` errors → `rmcp` `McpError` with structured code + message + context. **Drop** the error-taxonomy-stability tests (asserting that error codes never change across PRs) — WIP allows breaking changes; the taxonomy is informal here. Full stability tests return in the release phase.

As an MCP host receiving errors,
I want the `zanshin-mcp` binary to produce structured JSON-RPC error responses for all failure modes (input validation, jj-lib errors, panics),
So that the host can render or react meaningfully and the binary never crashes (NFR-R-4).

**Acceptance Criteria:**

**Given** `crates/zanshin-mcp/src/error.rs` (or distributed across handlers)
**When** created
**Then** it defines an internal error enum `McpHandlerError` with variants: `InvalidInput { details }`, `RepoError(JjError)`, `DiffError(...)`, `Panic { message }`, `NotImplemented { reason }`.

**Given** every tool handler
**When** it returns `Err(McpHandlerError::...)`
**Then** the rmcp framework converts it to a JSON-RPC error response with code and data
**And** the JSON-RPC error code follows MCP/JSON-RPC conventions (e.g., -32000 for application errors).

**Given** a panic in a handler (theoretical — should never happen if `catch_unwind` is used)
**When** caught
**Then** the handler returns `McpHandlerError::Panic { message }`
**And** the binary continues serving subsequent requests.

**Given** an unrecoverable error (e.g., the underlying repo handle is corrupted)
**When** detected
**Then** the binary returns an error response and continues running
**And** does NOT exit (the host can retry or escalate).

**Given** unit tests in `crates/zanshin-mcp/tests/error_handling.rs`
**When** they run
**Then** they cover:
- Invalid input → structured error
- Non-existent change ID → structured error
- Invalid revset → structured error
- (Simulated) panic in a handler → structured error, binary continues

**Edge cases:**

**Given** an out-of-memory condition (OOM)
**When** it occurs
**Then** the binary may exit (this is an OS-level concern, not catchable)
**And** the host detects the EOF on stdin/stdout and reports to the user.

**Given** rmcp itself throws an internal error
**When** detected
**Then** rmcp handles it per its own conventions
**And** the application layer (our handlers) doesn't need to manage it.

---

### Story 7.11: ~~[Deferred 0.2] MCP Resources surface~~ — DELETED (WIP-rework 2026-05-17)

> **Why deleted:** Already marked deferred to 0.2 per OD-10.

**Status:** Deferred to 0.2 per OD-10 (tools-only in 0.1).

As a future implementer planning 0.2 work,
I want a story stub for FR-MCP-6 (structured-data resources — revset → JSON),
So that the deferred work is visible.

**Acceptance Criteria (stub for future implementation):**

**Given** `crates/zanshin-mcp/src/resources/`
**When** added in 0.2
**Then** it exposes MCP resources that wrap revset queries as resources rather than tool calls
**And** consumers can subscribe to resource updates via MCP's resource subscription mechanism.

**Given** the 0.2 design
**When** initiated
**Then** an ADR or follow-up doc captures the design decisions before implementation
**And** the schema and protocol details are aligned with rmcp's resource APIs.

**Out of 0.1 scope:** No implementation work in this story until 0.2.

---

## Epic 8: Build Output (WIP)

> **WIP-rework (2026-05-17):** The original Epic 8 (11 stories: codesign infra, sign/notarize targets, notarytool, Sparkle EdDSA appcast, GitHub Pages hosting, update-check privacy, release orchestration, GitHub Releases automation, reproducibility CI, release-process.md, Homebrew Cask) is **collapsed to a single Story 8.1**. The full release pipeline is deferred to the release phase. PRD § 4.7 deferred-box is authoritative.

Produce an unsigned, unnotarized `.app` for local development as the WIP build output. No codesign, no notarization, no Sparkle, no GitHub Releases, no reproducibility CI.

### Story 8.1: Produce an unsigned `Zanshin.app` for local development

As a developer iterating on Zanshin locally,
I want `cargo make build` to produce an unsigned, unnotarized `.app` bundle that opens a test repo, exercises the FFI surface, and fires the watcher callback,
So that the WIP scaffold is observable as a working macOS application without any release-grade overhead.

**Acceptance Criteria:**

**Given** the workspace from Epic 1 + the artefacts from Epics 2–7
**When** `cargo make build` is invoked from a clean checkout
**Then** the build succeeds end-to-end (Rust workspace + Dart Hooks + Flutter macOS build)
**And** the output is `app/build/macos/Build/Products/Release/Zanshin.app` (unsigned, unnotarized)
**And** the build does NOT shell out to `codesign`, `notarytool`, or any signing/notarization tooling.

**Given** the unsigned `.app`
**When** double-clicked on a developer's macOS machine
**Then** macOS Gatekeeper warns the user (expected — unsigned app)
**And** with `xattr -d com.apple.quarantine` (or right-click → Open) the app launches.

**Given** the running app
**When** it opens a known test fixture repo
**Then** the FFI surface (read path) returns valid JSON
**And** the watcher fires at least one Dart callback when the repo's `op_heads/heads/` is mutated
**And** the diagnostics API returns the WIP-minimal `{ app_version, git_sha, log_path }` payload.

**Given** the Makefile.toml `build` target
**When** inspected
**Then** it documents (via comments) that the `sign`, `notarize`, `release` targets are deferred — pointer to PRD § 4.7
**And** stub targets (`cargo make sign`, `cargo make notarize`, `cargo make release`) either are absent or print a "deferred — see PRD § 4.7" message and exit non-zero.

**Edge case — Hardened-runtime entitlements:**

**Given** the unsigned `.app` still has `Info.plist` entitlements declared (placeholder values from Story 1.2)
**When** launched in WIP
**Then** the placeholder entitlements do not block local execution
**And** real entitlement values are populated when codesigning lands in the release phase.

**Edge case — `flutter run` parity:**

**Given** Ralph also uses `flutter run -d macos` for UI iteration
**When** that command runs (after `cargo make build` has produced the cdylib)
**Then** the running app behaves identically to the bundled `.app`
**And** both paths consume the same `bindings.dart` + `zanshin_ffi.dylib`.

---

### Story 8.2: ~~`cargo make sign` and `cargo make notarize` targets~~ — DELETED (WIP-rework 2026-05-17)

> **Why deleted:** Deferred to release phase — see PRD § 4.7 and Story 8.1's note.

### Story 8.2-OLD: `cargo make sign` and `cargo make notarize` targets

As a release manager,
I want the `Makefile.toml` `sign` and `notarize` targets fully implemented (replacing the Story 1.4 stubs) with explicit ordered steps (FR-BO-3),
So that signing and notarization can be invoked as discrete pipeline stages.

**Acceptance Criteria:**

**Given** `Makefile.toml`
**When** `cargo make sign` is invoked
**Then** it:
1. Runs `ci/codesign/import-cert.sh` (if running in CI; in dev, assumes local keychain already has the cert)
2. Signs `target/release/libzanshin_ffi.dylib`
3. Signs `target/release/zanshin-mcp`
4. Signs the embedded copies in `app/build/macos/Build/Products/Release/Zanshin.app/Contents/Frameworks/libzanshin_ffi.dylib` and `Contents/Resources/zanshin-mcp`
5. Signs the bundle: `Zanshin.app` itself
**And** any signing failure aborts the task.

**Given** `cargo make notarize`
**When** invoked after `cargo make sign`
**Then** it:
1. Creates a zip of `Zanshin.app` for submission
2. Submits via `notarytool submit --apple-id ... --team-id ... --password ... --wait`
3. On approval, staples the ticket via `xcrun stapler staple Zanshin.app`
4. Validates the staple via `stapler validate Zanshin.app`

**Given** `notarytool` credentials
**When** used in CI
**Then** they come from env vars: `APPLE_ID`, `APPLE_TEAM_ID`, `APPLE_APP_PASSWORD` (app-specific password, NOT Apple ID password)
**And** these are stored as GitHub secrets.

**Given** the `notarize` target succeeds
**When** verified
**Then** running `spctl --assess --type execute Zanshin.app` returns "accepted"
**And** `xcrun stapler validate Zanshin.app` returns "The validate action worked!".

**Given** notarization rejection (Apple finds issues)
**When** detected
**Then** the task fetches the log via `notarytool log <submission-id>` and prints it
**And** fails with a clear "notarization rejected — see log above" message.

**Given** the task is invoked locally (not CI)
**When** run by a developer
**Then** it expects the local keychain to have the cert and credentials cached (e.g., via `xcrun notarytool store-credentials`)
**And** uses a local credential profile name documented in `docs/release-process.md`.

**Edge cases:**

**Given** the notarization service is slow or down
**When** the task hangs
**Then** `notarytool` has its own timeout
**And** `cargo make notarize` does not impose an additional timeout (rely on tooling).

**Given** the binary contains entitlements that aren't compatible with hardened runtime
**When** notarization fails
**Then** the log surfaces the issue
**And** the developer adjusts `app/macos/Runner/Info.plist` entitlements.

---

### Story 8.3: ~~`notarytool` integration + stapled receipt~~ — DELETED (WIP-rework 2026-05-17)

> **Why deleted:** Deferred to release phase.

### Story 8.3-OLD: `notarytool` integration + stapled receipt

As a release manager,
I want the notarization flow tested end-to-end with an actual Apple Developer account (in a sandbox/test capacity if needed) and the stapled receipt embedded in the distributed `.app` (FR-DR-2),
So that users opening the app on macOS get the green-light Gatekeeper acceptance.

**Acceptance Criteria:**

**Given** a test/staging Apple Developer account (or the production one used cautiously)
**When** the first notarization attempt runs
**Then** Apple returns approval within ~10 minutes
**And** the staple step succeeds.

**Given** the stapled `.app`
**When** distributed to a user without internet
**Then** Gatekeeper accepts the app without an online check (stapled receipt is offline-valid).

**Given** the stapling step
**When** invoked
**Then** `xcrun stapler staple` modifies `Zanshin.app/Contents/_CodeSignature/CodeResources` to include the staple
**And** the staple is preserved when zipping for distribution.

**Given** a distributed `.app.zip`
**When** unzipped and the app is launched on a fresh macOS install
**Then** Gatekeeper accepts the launch
**And** no warning dialogs appear.

**Given** the notarized + stapled `.app`
**When** the staple is checked via `stapler validate`
**Then** the result is "The validate action worked!"
**And** this is asserted as the final step of `cargo make notarize`.

**Given** any binary inside the bundle missing its hardened-runtime flag
**When** the bundle is submitted to notarytool
**Then** the submission is rejected with a specific error
**And** the relevant info.plist entitlements are reviewed.

**Edge case — Sparkle integration:**

**Given** Sparkle 2 ships as a framework inside `Contents/Frameworks/Sparkle.framework`
**When** the bundle is signed
**Then** the Sparkle framework is also signed (codesign --sign covers it as a nested bundle)
**And** notarization accepts it.

---

### Story 8.4: ~~Sparkle appcast generation + EdDSA signing~~ — DELETED (WIP-rework 2026-05-17)

> **Why deleted:** Deferred to release phase.

### Story 8.4-OLD: Sparkle appcast generation + EdDSA signing

As a release manager wiring auto-update,
I want `crates/xtask/src/tasks/appcast.rs` generating the `appcast.xml` with Sparkle 2 EdDSA-signed entries and `sparkle/ed25519_pub.pem` in the repo (FR-DR-3, NFR-DU-3),
So that users on prior versions get the update prompt and the appcast is tamper-proof.

**Acceptance Criteria:**

**Given** `crates/xtask/src/tasks/appcast.rs`
**When** created
**Then** it implements `cargo xtask appcast --version <v> --release-url <url> --signing-key <path>`
**And** generates an `appcast.xml` entry for the given version with:
- `<sparkle:edSignature>...</sparkle:edSignature>` (EdDSA signature over the `.app.zip`)
- `<sparkle:version>...</sparkle:version>` (numeric version)
- `<sparkle:shortVersionString>...</sparkle:shortVersionString>`
- `<sparkle:minimumSystemVersion>12.0</sparkle:minimumSystemVersion>` (or current macOS pin)
- `<pubDate>...</pubDate>` (RFC-2822 format)
- `<enclosure url="..." length="..." type="application/octet-stream" />`

**Given** the EdDSA private key
**When** stored
**Then** it's a GitHub secret (`SPARKLE_ED25519_PRIVATE_KEY`)
**And** never committed to the repo.

**Given** `sparkle/ed25519_pub.pem`
**When** committed
**Then** it's the public key matching the private key
**And** it's embedded into the `.app` bundle's Info.plist as `SUPublicEDKey`.

**Given** the appcast file
**When** generated
**Then** it's an XML file accumulating all release entries (most recent first)
**And** is hosted at a stable URL (GitHub Pages — Story 8.5) referenced by the `.app`'s `SUFeedURL` Info.plist key.

**Given** Sparkle integration in the app
**When** the app launches
**Then** Sparkle reads `SUFeedURL`, fetches the appcast, validates the EdDSA signature on the enclosure, and (if a newer version is available) prompts the user to update.

**Given** the EdDSA signature
**When** validated by Sparkle
**Then** it uses the public key from `SUPublicEDKey`
**And** rejects any unsigned or mis-signed entries.

**Given** the xtask
**When** run as part of `cargo make release` (Story 8.7)
**Then** it accepts the just-built `.app.zip` path, signs it, and emits the appcast entry to stdout (or appends to `sparkle/appcast.xml`).

**Given** unit tests in `crates/xtask/tests/appcast.rs`
**When** they run
**Then** they: synthesize a test signing key, generate an appcast entry for a fake bundle, validate the EdDSA signature is correct.

**Edge cases:**

**Given** an appcast entry with a corrupted signature
**When** Sparkle fetches it
**Then** Sparkle rejects the update and shows no prompt
**And** the user is not affected.

**Given** multiple appcast entries for different versions
**When** Sparkle reads
**Then** it selects the highest version that meets `<sparkle:minimumSystemVersion>` constraints
**And** older entries are preserved for users on older macOS versions if there are differentiated builds.

---

### Story 8.5: ~~GitHub Pages hosting for `appcast.xml`~~ — DELETED (WIP-rework 2026-05-17)

> **Why deleted:** Deferred to release phase.

### Story 8.5-OLD: GitHub Pages hosting for `appcast.xml`

As a release manager,
I want `sparkle/appcast.xml` hosted on GitHub Pages at a stable URL (e.g., `https://dasralph.de/zanshin/appcast.xml` or `https://<user>.github.io/zanshin/appcast.xml`),
So that the app's `SUFeedURL` points at a reliable, free hosting target.

**Acceptance Criteria:**

**Given** the repo
**When** GitHub Pages is enabled
**Then** the source is set to `main` branch, `/docs` folder OR a separate `gh-pages` branch
**Decision:** use the `/docs/appcast/` folder on `main` for simplicity — the appcast lives at `https://<user>.github.io/zanshin/appcast/appcast.xml`.

**Given** the appcast URL
**When** set in `app/macos/Runner/Info.plist` as `SUFeedURL`
**Then** the value matches the GitHub Pages URL.

**Given** the release workflow (Story 8.7)
**When** it generates a new appcast entry
**Then** it commits the updated `docs/appcast/appcast.xml` back to `main`
**And** pushes the commit (with `[skip ci]` to avoid retriggering CI)
**And** GitHub Pages serves the new file within ~1 minute.

**Given** the appcast is updated
**When** Sparkle next checks (typical default: once per day)
**Then** it sees the new version and prompts the user.

**Given** a custom domain (optional)
**When** configured via `docs/appcast/CNAME` file
**Then** the appcast can be served from `https://dasralph.de/...`
**And** the README documents the CNAME setup.

**Edge cases:**

**Given** GitHub Pages is temporarily down
**When** Sparkle checks
**Then** the check silently fails and is retried on the next interval
**And** users are not blocked from using the app.

**Given** the appcast URL changes (e.g., custom domain added later)
**When** the change happens
**Then** existing users on old versions still use the old URL until they upgrade
**And** the migration is documented (e.g., serve both URLs for a transition period).

---

### Story 8.6: ~~Update-check privacy — User-Agent only~~ — DELETED (WIP-rework 2026-05-17)

> **Why deleted:** Deferred to release phase (no update mechanism in WIP). When Sparkle is added later, the privacy invariant binding still holds (User-Agent only, no analytics).

### Story 8.6-OLD: Update-check privacy — User-Agent only (FR-DR-4, NFR-PRIV-3)

As a privacy-conscious user,
I want the Sparkle update check to send no user-identifying information beyond the User-Agent string,
So that NFR-PRIV-3 is honoured (the update check is the only outbound connection, and even that is privacy-respecting).

**Acceptance Criteria:**

**Given** Sparkle's default behaviour
**When** it sends the update check HTTP request
**Then** it sets `User-Agent: Sparkle/<version> Zanshin/<version>` (or similar)
**And** sends no cookies, no analytics ID, no unique-per-install identifier.

**Given** the Sparkle 2 configuration in `Info.plist`
**When** inspected
**Then** `SUEnableSystemProfiling = false` (default for SUEnableSystemProfiling is false, but explicit)
**And** `SUAllowsAutomaticUpdates = false` (require user confirmation — NFR-DU-3)
**And** no third-party analytics extension is configured.

**Given** a network capture of the update check
**When** examined
**Then** the only outbound request is a GET to the appcast URL
**And** the only fingerprintable data is the User-Agent (containing version info, which is functionally necessary).

**Given** a user inspects the Sparkle behaviour
**When** they read `docs/privacy.md` (added in this story)
**Then** they see a clear statement: "Zanshin makes one outbound connection: a daily HTTPS GET to the appcast URL to check for updates. The request includes only the User-Agent header. No user identifiers, no analytics, no telemetry."

**Given** the `docs/privacy.md`
**When** read
**Then** it also documents:
- Crash logs are local-only (`~/Library/Logs/Zanshin/`)
- No telemetry frameworks are included (Sentry, Crashlytics, etc.)
- No third-party SDKs in the build (verified via `cargo deny` + `pana`)

**Edge cases:**

**Given** a user with a strict firewall
**When** Sparkle's update check is blocked
**Then** the app continues to work — no functionality depends on the check
**And** the user just doesn't get update prompts.

**Given** a future feature wants to add user-supplied diagnostics upload
**When** considered
**Then** it must be opt-in, require explicit consent each time, and surface what's being sent
**And** the default-no-telemetry posture is preserved (separate from any opt-in feature).

---

### Story 8.7: ~~`cargo make release` orchestration~~ — DELETED (WIP-rework 2026-05-17)

> **Why deleted:** Deferred to release phase.

### Story 8.7-OLD: `cargo make release` orchestration

As a release manager invoking a single command per release,
I want `cargo make release` orchestrating build → sign → notarize → appcast → tag-push → GitHub Release upload (FR-BO-4),
So that a tag push triggers the entire pipeline reliably.

**Acceptance Criteria:**

**Given** `Makefile.toml` `release` target
**When** invoked
**Then** it runs:
1. `cargo make build` (assumes the workflow has set release-specific env vars)
2. `cargo make sign`
3. `cargo make notarize`
4. Zip the `.app` to `dist/Zanshin-<version>.app.zip`
5. Compute SHA256: `dist/Zanshin-<version>.app.zip.sha256`
6. `cargo xtask appcast --version <version> --release-url <gh-release-url> --signing-key $SPARKLE_ED25519_PRIVATE_KEY`
7. Stage the updated `appcast.xml` for commit
8. (CI only) Push the appcast update to `main`
9. (CI only) Upload `Zanshin-<version>.app.zip` + `.sha256` to the GitHub Release

**Given** a developer running this locally (rare — typical case is CI)
**When** they invoke `cargo make release VERSION=0.1.0`
**Then** the steps 1–6 run, producing local artefacts in `dist/`
**And** steps 7–9 are skipped (or run with explicit user confirmation prompts).

**Given** the version arg
**When** parsed
**Then** it must match the `Cargo.toml` `[workspace.package] version` field (AR-AD-7)
**And** the build fails if there's a mismatch.

**Given** the artefacts in `dist/`
**When** uploaded to the GitHub Release
**Then** each is hashed with SHA256
**And** the SHA256 file is also uploaded.

**Given** the workflow fails midway (e.g., notarization rejected)
**When** it happens
**Then** subsequent runs can resume from the failed step (some idempotency)
**And** partial state in `dist/` is detectable and cleanable.

**Edge case — Re-running for the same version:**

**Given** a release is re-run for the same version (e.g., notarization retry)
**When** invoked
**Then** the existing GitHub Release tag is reused (don't delete and recreate)
**And** the appcast entry is updated (only one entry per version).

**Edge case — Pre-release versions:**

**Given** a pre-release version (e.g., `0.1.0-rc.1`)
**When** released
**Then** the GitHub Release is marked as "pre-release"
**And** Sparkle's `<sparkle:channel>` is set to `beta` (so stable users don't auto-update to it).

---

### Story 8.8: ~~GitHub Releases automation (`release.yml`)~~ — DELETED (WIP-rework 2026-05-17)

> **Why deleted:** Deferred to release phase.

### Story 8.8-OLD: GitHub Releases automation (`release.yml`)

As a release manager,
I want `.github/workflows/release.yml` triggered on tag push, running `cargo make release` end-to-end (FR-DR-5),
So that creating a Git tag is the sole human action required to ship.

**Acceptance Criteria:**

**Given** `.github/workflows/release.yml`
**When** created
**Then** it triggers on `push: tags: ['v*']`
**And** runs on `macos-latest` (or pinned `macos-14`).

**Given** the workflow
**When** it runs
**Then** the steps are:
1. `actions/checkout@v4` with `fetch-depth: 0` (need full history for `git rev-parse HEAD`)
2. Setup Rust + Flutter (same as Epic 1 Story 1.9)
3. Install `cargo-make`, `cargo-deny`, `cbindgen` (cached)
4. Import codesigning cert (`ci/codesign/import-cert.sh`)
5. Run `cargo make test` (no release if tests fail)
6. Run `cargo make release VERSION=${GITHUB_REF_NAME#v}`
7. Upload artefacts to GitHub Release via `softprops/action-gh-release@v1`
8. Push appcast update to `main` (via committing `docs/appcast/appcast.xml` and pushing with `[skip ci]`)
9. Cleanup keychain (always runs)

**Given** the secrets used
**When** referenced in the workflow
**Then** they're: `APPLE_DEVELOPER_ID_APPLICATION_CERT_BASE64`, `APPLE_DEVELOPER_ID_APPLICATION_CERT_PASSWORD`, `APPLE_TEAM_ID`, `APPLE_KEYCHAIN_PASSWORD`, `APPLE_ID`, `APPLE_APP_PASSWORD`, `SPARKLE_ED25519_PRIVATE_KEY`
**And** all are stored as GitHub encrypted secrets.

**Given** the artefacts uploaded
**When** verified
**Then** the release page lists:
- `Zanshin-<version>.app.zip`
- `Zanshin-<version>.app.zip.sha256`
- (optional) `Zanshin-<version>.dmg` — out of 0.1 scope unless trivial to add
**And** the release body is generated from `CHANGELOG.md` if present, else from `git log` since the previous tag.

**Given** an aborted release (e.g., manual workflow cancellation mid-run)
**When** the cleanup step runs
**Then** the keychain is deleted
**And** no residual secret material remains.

**Edge cases:**

**Given** a tag pushed but `cargo make test` fails
**When** detected
**Then** the workflow exits without publishing anything
**And** the developer fixes the issue and re-tags (or force-pushes the tag after fix).

**Given** the workflow takes longer than the 6-hour GitHub Actions limit
**When** approaching the limit
**Then** the workflow optimizes (parallelizes where possible, caches aggressively)
**And** the bulk of time is in the cargo build + notarization (notarization typically dominates).

**Given** two tags pushed concurrently (theoretical race)
**When** both workflows run
**Then** the appcast-commit step might conflict
**And** the second workflow detects the conflict and retries (or errors out cleanly).

---

### Story 8.9: ~~Reproducibility CI (`reproducibility.yml`) — FR-BO-8~~ — DELETED (WIP-rework 2026-05-17)

> **Why deleted:** Deferred to release phase.

### Story 8.9-OLD: Reproducibility CI (`reproducibility.yml`) — FR-BO-8

As a developer enforcing FR-BO-8 / NFR-B-4,
I want `.github/workflows/reproducibility.yml` building the same SHA twice on two different runners (or sequentially with cache cleared) and diff-ing the output `.app` (modulo signature blob),
So that byte-identical builds across machines is verifiable in CI.

**Acceptance Criteria:**

**Given** `.github/workflows/reproducibility.yml`
**When** created
**Then** it triggers on:
- `schedule: cron: '0 0 * * 0'` (weekly Sunday 00:00 UTC)
- `push: tags: ['v*']`
- `workflow_dispatch` (manual trigger for testing)

**Given** the workflow
**When** it runs
**Then** it:
1. Checks out a specific SHA
2. Builds the project (cargo + flutter, NO codesign/notarize — we diff pre-signing)
3. Renames the output `.app` to `app-build-1`
4. Cleans cargo + flutter caches completely
5. Re-builds the project on the same runner
6. Renames the output `.app` to `app-build-2`
7. Diffs the contents recursively, ignoring `_CodeSignature/`, `Sparkle.framework/_CodeSignature/`, anything with a `.signature` extension, etc.
8. Asserts the diff is empty (byte-identical for non-signature content)

**Given** the diff is non-empty
**When** detected
**Then** the workflow fails with a list of diverging files
**And** the failure surfaces actionable items: which file diverges and why (typical culprits: embedded timestamps, build paths, non-deterministic codegen).

**Given** the workflow has an alternative "two runners" mode
**When** triggered manually with a flag
**Then** it can run on two different macOS runner SKUs (e.g., `macos-14` and `macos-15`) and diff
**And** this gives stronger reproducibility evidence at the cost of longer wall-clock time.

**Given** sources of non-determinism are surfaced
**When** the workflow first fails
**Then** common causes are documented in `docs/perf-budgets.md` (or a new `docs/reproducibility.md`):
- Embedded build timestamps (fix: `SOURCE_DATE_EPOCH`)
- Build path leaks (fix: `--remap-path-prefix`)
- Non-deterministic dependency hashes (fix: pinned Cargo.lock)
- ffigen / cbindgen non-determinism (fix: deterministic output via `cbindgen.toml` config)

**Given** the workflow runs weekly
**When** it consistently passes
**Then** the reproducibility invariant holds
**And** any regression is caught within a week.

**Edge cases:**

**Given** the diff includes timestamps in `.plist` files
**When** detected
**Then** the diff ignore-list is extended
**And** the cause is documented (typically harmless, but loud diff is fixed).

**Given** a contributor adds a new source of non-determinism (e.g., a procedural macro that uses `SystemTime::now()`)
**When** the next reproducibility run catches it
**Then** the contributor is notified and the issue is fixed
**And** the workflow has a clear pointer to the doc explaining how to fix.

---

### Story 8.10: ~~`docs/release-process.md` (AR-G-6)~~ — DELETED (WIP-rework 2026-05-17)

> **Why deleted:** Deferred to release phase — the doc describes the release pipeline that doesn't exist in WIP.

### Story 8.10-OLD: `docs/release-process.md` (AR-G-6)

As a release manager picking up the process for the first time,
I want `docs/release-process.md` documenting every step of cutting a release including Sparkle EdDSA key management,
So that AR-G-6 is resolved and the process is reproducible by a future contributor.

**Acceptance Criteria:**

**Given** `docs/release-process.md`
**When** created
**Then** it covers:
- Prerequisites (Apple Developer account, EdDSA keys, GitHub secrets configured)
- Version bumping process (update `Cargo.toml`'s `[workspace.package] version`, update `CHANGELOG.md`, commit)
- Tag creation and push (`git tag v0.1.0 && git push --tags`)
- What `release.yml` does (linked to Story 8.8)
- What the developer monitors (workflow status, notarization status)
- Manual fallback steps if the workflow fails partway through
- How to revoke / replace a Sparkle signing key if compromised

**Given** the Sparkle EdDSA key section
**When** read
**Then** it documents:
- How keys were initially generated (`generate_keys` tool from Sparkle)
- Where the private key is stored (GitHub secret `SPARKLE_ED25519_PRIVATE_KEY`, never committed)
- Where the public key is stored (`sparkle/ed25519_pub.pem`, committed)
- How to test signing locally (using `sign_update` tool with a local key for non-production testing)
- Recovery: if the private key is compromised, generate a new key pair, update `SUPublicEDKey` in `Info.plist`, ship a transitional release that includes both old + new public keys (Sparkle supports this), then phase out the old key

**Given** the document
**When** the first release is cut by Ralph
**Then** it has been walked through end-to-end and corrected where the process drifted from the doc.

**Given** a future maintainer
**When** they need to release
**Then** they can do so by reading this doc + cargo make commands, without consulting Ralph.

---

### Story 8.11: ~~[Deferred post-0.1] Homebrew Cask~~ — DELETED (WIP-rework 2026-05-17)

> **Why deleted:** Already marked deferred per OD-5.

### Story 8.11-OLD: [Deferred post-0.1] Homebrew Cask (FR-DR-6)

**Status:** Deferred to post-0.1 per OD-5.

As a future implementer,
I want a story stub for FR-DR-6 (Homebrew Cask),
So that the deferred work is visible.

**Acceptance Criteria (stub for future implementation):**

**Given** the project hits a stable 0.1 release
**When** the cask is added (post-0.1)
**Then** a `Casks/zanshin.rb` is submitted to homebrew-cask via PR
**And** the cask points at the GitHub Release artefacts
**And** the cask version auto-updates via homebrew-cask's automation.

**Given** the cask
**When** approved and merged into homebrew-cask
**Then** users can install via `brew install --cask zanshin`
**And** updates flow through brew (in addition to Sparkle for users who installed via GitHub).

**Out of 0.1 scope:** No implementation work in this story until post-0.1.

---

## Epic 9: jj Operation Surface Build-Out (ADR-0003)

> **Granularity:** backlog-level. These stories enumerate the operation surface derived from
> ADR-0003 + the jj-0.42 feasibility map; full acceptance criteria are authored per story (via
> `bmad-create-story`) when scheduled. Per-operation detail (backing jj-lib helper, exact
> thickness, typed-API sketch, special concerns) lives in the feasibility map — not duplicated
> here. **Already covered elsewhere (NOT re-listed in Epic 9):** reads `status`/`revset`/`change`/
> `op_log`/`bookmark list`/`remotes` (Epic 2), graph + `log` (Epic 4), `diff` (Epic 5); mutations
> `describe`/`new`/`edit`/`abandon` (6.1), `undo` (6.2), `git fetch` (6.4a). Tag `[M]` = mutation,
> `[R]` = read.

### Precursors

### Story 9.0: Bump `jj-lib` 0.41.0 → 0.42.0 (precursor)
Edit the `=0.41.0` pins to `=0.42.0`, absorb any API diff inside `zanshin-jj`, regenerate codegen if an `extern "C"` signature changed, `cargo make test` green (incl. coverage ratchet). One reviewed change before any operation work, so the surface is built on current. *(Executed in the 2026-06-27 session.)*

### Story 9.0a: Bump `jj-lib` to latest — 0.42.0 → 0.44.0 (precursor)
Edit the `=0.42.0` pin to the latest release (`=0.44.0` as of 2026-09-02), re-align the pins that track it (`gix` 0.84.0 → 0.85.0 per jj-lib 0.44's transitive version; re-verify the exact `chrono` pin), absorb any API diff inside `zanshin-jj`, regenerate codegen if an `extern "C"` signature changed, and bump the `../jj` reference-tag mentions (`CLAUDE.md`, `project-context.md` § jj source reference) in lockstep. `cargo make test` green (incl. coverage ratchet + `cargo deny`). Lands before any Epic 9 operation work, so the surface is built on current. *(Added 2026-09-02.)*

### Story 9.1: Operation-support layer (`zanshin-jj/src/op_support.rs`)
Re-port the orchestration jj-lib does NOT expose (lives in jj-cli's `cli_util`): the immutable-heads / `check_rewritable` guard, `compute_commit_location` (insert `-A`/`-B`/`--onto`), description combination (`combine_messages` + trailers), and the `SelectedTree` plumbing that replaces the CLI's interactive `DiffSelector`. Shared by every thick verb + MCP. **Blocks Tier C.**

### Story 9.2: `eval_revset` generic read primitive + `View` read helpers (extends 2.5)
A typed `eval_revset(&str) -> Stream<Commit>` over the verified parse→resolve→evaluate path (lazy `Box<dyn Revset>`, streamed per ADR-0002, never `try_collect`-ed); plus direct `View` reads (bookmarks/tags/heads/wc) so the GUI does not route everything through revsets. Preserve the 3-stage parse/resolution/evaluation error taxonomy.

> **As built (2026-09-03):** shipped as a **visitor**, `Repo::eval_revset(&str, impl FnMut(Change) -> ControlFlow<()>)`, not a returned stream — the evaluated revset borrows the `ReadonlyRepo` the call loads, so a stream cannot outlive it (same inversion as `Repo::walk_graph`). Laziness, no-collect and mid-walk cancellation are all preserved; the item is the existing `Change`. Delivered `zanshin-jj`-only: bookmarks already existed (2.8), and `list_tags`/`list_heads`/`list_working_copies` are new. FFI/MCP surfacing was NOT part of this story — a `Stream` has no wire form and the boundary is snapshot-only. See `docs/adr/0003-…md` § Implementation notes.

### Tier A — cheap (start here)

### Story 9.3: Content ops — `restore`, `absorb` [M]
`restore` via `rewrite::restore_tree` (whole-file; interactive selection out of scope); `absorb` via `lib/src/absorb.rs` (`split_hunks_to_trees` + `absorb_hunks`). Both cheap.

### Story 9.4: File reads — `file list`, `file show`, `file annotate`, `file search` [R]
`MergedTree::entries_matching` / `path_value` + `conflicts::materialize_tree_value`; blame via `annotate::FileAnnotator`.

### Story 9.5: Git local sync + remote config — `git import`, `git export`, `git remote add`/`remove`/`rename`/`set-url` [M]
Thin wraps over `git::{import_refs,import_head,export_refs,add_remote,remove_remote,rename_remote,set_remote_urls}`. Remote remove/rename also rewrite the repo config file (outside the tx), mirroring Story 2.9's pattern.

### Story 9.6: Read views — `show`, `evolog`, `interdiff` [R]
`show` (`Commit::parent_tree` + `MergedTree::diff_stream`); `evolog` (`evolution::walk_predecessors`); `interdiff` (`rewrite::rebase_to_dest_parent`).

### Story 9.7: Workspace reads — `workspace list`, `workspace root` [R]
`View::wc_commit_ids` + `WorkspaceStore::get_workspace_path`.

### Story 9.8: Bookmark CRUD (cheap start) — `bookmark create`, `bookmark delete` [M]
`MutableRepo::set_local_bookmark_target` (+ `RefTarget::normal`/`absent`). Supersedes part of deferred 6.9.

### Tier B — medium

### Story 9.9: `metaedit`, `duplicate`, `fix` [M]
`metaedit` (`CommitBuilder` setters + `transform_descendants`); `duplicate` (`rewrite::duplicate_commits{,_onto_parents}`, needs 9.1 location-compute); `fix` (`fix::fix_files` + tool-config/subprocess closure).

### Story 9.10: Working-copy movement — `next`, `prev` [M]
Shared `movement_util` orchestration over `MutableRepo::check_out`/`edit`; revset target computation + ambiguity resolution (GUI picks, no terminal prompt).

### Story 9.11: Bookmark tracking — `bookmark set`, `forget`, `track`, `untrack` [M]
`set_local_bookmark_target` + `track_remote_bookmark`/`untrack_remote_bookmark`/`merge_local_bookmark`; pattern matching + fast-forward guard.

### Story 9.12: Operation edits — `op restore`, `op revert` [M]
`MutableRepo::set_view` / `MutableRepo::merge` over `op_walk::resolve_op_with_repo`; partial-view (`--what`) reassembly.

### Story 9.13: `file chmod`; `workspace forget`, `workspace rename` [M]
`MergedTreeBuilder` + `rewrite_commit`; `MutableRepo::remove_wc_commit`/`rename_workspace` + `WorkspaceStore` (metadata write outside tx).

*(Refined 2026-10-08, jj 0.46 bump — read the verbs at `v0.46.0`, not the API note above.)* `workspace forget` (`cli/src/commands/workspace/forget.rs`) now calls `MutableRepo::remove_workspace` and deliberately LEAVES the recorded path in the `WorkspaceStore` (so `jj undo` can point the workspace back at its directory — jj #9991); unknown names warn "No such workspace: …", all names share ONE transaction (`forget workspace <n>` / `forget workspaces <a, b>`), and in a git-backed repo it then unlinks the workspace's Git worktree (`git_util::unlink_git_worktree`, a git subprocess) for every reachable recorded path. `workspace rename` still renames in the locked working copy, the view and the store. **New verb `workspace remove`** (`remove.rs`, jj 0.46) belongs here too: refuses an unreachable / foreign / repo-containing workspace (hint: `jj workspace forget`), snapshots each workspace before its directory goes, then `remove_workspace` in one transaction (`remove workspace <n>`), deletes the directories and unlinks Git worktrees; `jj undo` of it warns `jj.undo_workspace_removal` (already shipped, Story 9.39).

### Story 9.14: `simplify-parents` [M]
`CommitRewriter::simplify_ancestor_merge` via `transform_descendants`; default revset from settings.

### Tier C — thick (needs Story 9.1; interactive verbs need the Flutter diff/merge editor)

### Story 9.15: `squash`, `split` (partial-file) — *supersedes deferred 6.8 part; FR-JJ-10b/10c* [M]
Tree math via `rewrite::squash_commits` / `CommitWithSelection` / `restore_tree`; message-combine + selected-tree from Story 9.1; GUI supplies the selected `TreeId` (no editor spawn). `split` has no lib primitive — assemble two builders + parallel-tree math.

### Story 9.16: `rebase`, `parallelize`, `arrange` — *supersedes deferred 6.8 part* [M]
`rebase` via `rewrite::{MoveCommitsTarget,compute_move_commits,ComputedMoveCommits::apply}` + 9.1 target/dest resolution; `parallelize` ports the two-map parent recompute; `arrange` exposes only a headless `arrange_apply(plan)` (the CLI's ratatui TUI is replaced by the GUI).

### Story 9.17: `commit`, `resolve`, `diffedit` (GUI-editor-backed) — *FR-JJ-11/12 conflict ops* [M]
Backend wraps pub tree helpers + conflict materialization (`conflicts::*`, `MergedTree::conflicts*`); the diff/merge editor is GUI-native and feeds a selected/edited `TreeId`. Expose context+apply pairs for `resolve`/`diffedit`.

### Story 9.18: `revert` — *no lib helper* [M]
Port the per-commit reverse-3-way-merge + sequential chaining + child-rebase from CLI logic over `merge_commit_trees` / `MergedTree::merge` / conflict labels. The only genuine algorithm port with zero lib helper.

### Story 9.19: Bookmark thick + list filters — `bookmark move`, `advance`, `rename`; `bookmark list` filters — *supersedes deferred 6.9 part* [M/R]
`--from` revset membership, dynamic revset with injected `to`, tracking-state transfer; typed filtered rows (replace the CLI template matrix).

### Story 9.20: `git push`, `git clone`, `git init` — *FR-JJ-13b push* [M]
`git::push_refs` (+ safety/classification pipeline), `Workspace::init_*_git` + `GitFetch`; network + multi-tx filesystem setup; progress via typed callback (the 6.4a pattern).

*(Refined 2026-10-08, jj 0.46 bump — read the verbs at `v0.46.0`.)* `jj git push` pushes to SEVERAL remotes in one call since 0.46: `git.push` may be a string pattern or an array of patterns, and `--remote` is repeatable and takes patterns — pass the remote list through as the CLI's arguments, with `git.push` as the editable default (never a hidden Zanshin default). The default push targets come from the new `revsets.git-push` setting. Also `jj git init` / `jj git clone` changed between v0.44.0 and v0.46.0 (`git -C ../jj diff v0.44.0 v0.46.0 -- cli/src/commands/git`) — re-read both before porting.

### Story 9.21: Operation-log surface — `op log`, `op show`, `op diff`, `op abandon`, `redo` [M/R]
`op_walk::{walk_ancestors,resolve_op_with_repo,reparent_range}` + `RepoLoader::merge_operations`; typed op entries + cross-op diff; redo stack semantics (beyond 6.2 undo).

*(Refined 2026-10-08, jj 0.46 bump.)* `redo` must mirror Story 9.39's `undo`: since jj 0.46 both refuse an operation performed in ANOTHER workspace unless `--allow-cross-workspace` is passed (`cli/src/commands/redo.rs` @ v0.46.0) — pass the flag through, as 9.39 does for `undo`, and reuse 9.39's undo-stack walk (`UNDO_OP_DESC_PREFIX`) rather than re-deriving it. `op log` entries carry the workspace name the operation was created in (since jj 0.40), so the typed entry should expose it.

### Story 9.22: `file track`, `file untrack` (locked-WC lifecycle) [M]
`LockedWorkingCopy::{snapshot,reset}` + `SnapshotOptions`; multi-phase reset/resnapshot reconciliation.

*(Refined 2026-09-17, Ralph — full spec: `implementation-artifacts/spec-9-22-file-track-untrack-locked-wc.md`.)* Ports `cmd_file_track` / `cmd_file_untrack` @ v0.44.0 step for step and, as a by-product, builds the reusable locked-working-copy primitives Story 9.26 drives: `start_working_copy_mutation` → `LockedWorkingCopy::{snapshot,reset}` → `LockedWorkspace::finish`, `SnapshotOptions` from the effective `snapshot.auto-track` / `snapshot.max-new-file-size`, the CLI's `base_ignores()` chain. Both verbs commit unconditionally like the CLI (raw `tx.commit("track paths" | "untrack paths")`, no `has_changes` guard); `untrack` refuses non-ignored paths after its reset → resnapshot round trip WITHOUT writing an operation; colocated `untrack` runs `export_working_copy_changes_to_git`. `SnapshotStats` (untracked paths + reason, invalid-UTF-8 paths), unmatched paths and rebased-descendant counts ride the payload. Prerequisite of 9.26; does NOT itself add the per-verb snapshot.

### Story 9.23: `workspace add`, `workspace update-stale` [M]
`Workspace::init_workspace_with_existing_repo` + sparse mutation; `WorkingCopyFreshness::check_stale` + `create_and_check_out_recovery_commit`.

*(Refined 2026-10-08, jj 0.46 bump — read the verbs at `v0.46.0`.)* `workspace add` gained `--colocate` / `--no-colocate` (default: colocate iff the CURRENT workspace is colocated and `git.colocate` is true): a colocated add creates a Git worktree via jj-lib's `git::create_worktree` (a `git worktree add --orphan` subprocess, git ≥ 2.42.0, like fetch/push), and Git HEAD is tracked per worktree since jj 0.45. Pass both flags through; the default is the CLI's, not ours. It still records relative paths and refuses an empty name. `workspace update-stale` in a colocated workspace now also resets Git HEAD to the parent of the fresh working-copy commit (jj 0.45, #9936): `recover_stale_working_copy_impl` (`cli/src/cli_util.rs:626-740` @ v0.46.0) first commits a separate `reset git head` operation when that changes anything, then updates the stale working copy, then snapshots again. The SAME recovery runs implicitly when `snapshot.auto-update-stale = true` and a verb meets a stale working copy (`cli_util.rs:499-512`) — Zanshin's `Repo::precondition` already reads that key and refuses either way (`repo.rs`, "Its `true` arm is Story 9.23's stale recovery"), so this story owns that arm too. The `jj git colocation status|enable|disable` per-workspace verbs (0.46) are NOT in this story — no Zanshin story covers `git colocation` yet.

### Story 9.24: Remote-change poll — `git ls-remote` diff against the view — *FR-JJ-13c* [R]
*(Added 2026-09-12, Ralph.)* A read-only `Repo::remote_changes(remote)` that fetches only the remote's **ref advertisement** (bookmark/tag name → commit id, no pack transfer) and diffs it against the last-known `<name>@<remote>` targets in the current view (`View::remote_bookmarks` / remote tags). Typed result per remote: moved (old id → new id), new upstream, deleted upstream; empty = nothing new. **No transaction, no op-log entry, working copy and bookmarks untouched** — this is what distinguishes it from 6.4a's `git fetch`, which (jj semantics, `import_refs` → `merge_local_bookmark`) also moves *tracked local* bookmarks. jj-lib has **no public ls-remote helper** (only a `pub(crate)` `git remote show` spawn for the default branch), so the transport is ours: spawn `git ls-remote --heads --tags <remote>` via the same subprocess route jj-lib uses for `fetch`/`push` (auth = the user's git: ssh-agent, credential helpers, `.ssh/config` — for free), honouring the same `git.executable-path` setting; gix `Remote::connect(Fetch).ref_map()` is the in-process alternative if the subprocess route proves awkward. No `git fetch --dry-run` — that still downloads objects. **Non-goal:** a commit count ("5 new commits") — impossible without the objects; the UI shows "`main`, `feature-x` changed on `origin`" and offers the real fetch. Surface through the usual chain (`.fbs` → `zanshin-jj` → `extern "C"` → `WorkerCommand`; MCP optional). The **poll timer, interval setting and indicator are UI-side** (Ralph's scope); the backend is one-shot. Cheap (Tier A); needs a real remote fixture in tests (the checked-in fixtures carry no remote bookmarks — construct in-test, as 2.9/6.4a do). *(2026-09-20 addendum, Ralph: the Fetch button's badge is THIS story's count of remote bookmarks that moved/appeared/vanished upstream — still no commit count; per-bookmark commit distances after the fetch are Story 9.29, the button's enable rule and default-remote resolution are Story 9.30. This story was missing from `sprint-status.yaml` until 2026-09-20.)*

### Story 9.25: Log revset input — presets, apply/save, completion candidates — *NEEDS REFINEMENT* [R/M]
*(Added 2026-09-16, Ralph — captured from a console session, **not yet refined**; ACs to be authored when scheduled. UI decisions below are Ralph's from that session; the UI itself is Ralph's scope, this story is the backend behind it.)*

**Motivation.** `jj log`'s default (`builtin_log()` = `present(@) | ancestors(immutable_heads().., 2) | trunk()`, v0.44.0) hides everything reachable only from **untracked** remote bookmarks, because `builtin_immutable_heads()` includes `untracked_remote_bookmarks()`. A user coming from SourceTree ("all branches") sees a fraction of the repo and thinks something is broken. Zanshin must let the user *choose* the revset — never decide for them (FR-JJ-17), never build a second revset parser (jj-lib is the only parser).

**UI shape (decided, for context).**
- A revset text field pre-filled with the **effective** `revsets.log` (Story 4.9 `log_defaults`) plus presets that only pre-fill the field: *My work* = `builtin_log()`, *All branches* = `ancestors(bookmarks() | remote_bookmarks() | @, N) | trunk()`, *Everything* = `all()`.
- **No live validation while typing** — a half-typed revset is always invalid, so red-while-typing is noise (the CLI validates on Enter too). Enter / **Apply** parses + evaluates in one step and the log view *is* the preview (optionally a "N revisions" line). Errors appear inline only after Apply, with jj-lib's message + caret position; the log stays on the last valid revset. An empty result is not an error.
- **Save** persists the applied revset as `revsets.log` in the **repo** config — parity with `jj config set --repo revsets.log …` (no op-log entry; config file, as the CLI). Enabled only after a successful Apply.
- **Autocomplete** for the trailing partial name, deliberately CLI-dumb: no understanding of the surrounding expression.
- Bookmark **tracking** (Story 9.11) also widens the default log (it changes `immutable_heads()`), but is a repo-state change and belongs in the bookmark sidebar — keep it a separate action, not a log-revset feature.

**Backend work (this story).**
1. **Config write.** A typed `revsets.log` set on the repo config (`.jj/repo/config.toml`). No generic repo-config writer exists yet; Story 9.5's `git remote rename/remove` rewrites that file privately — generalize or add a narrow setter. Decide `--repo` only vs. also `--user`.
2. **Structured parse/resolution errors.** `RevsetError::ParseError { reason }` currently flattens jj-lib's `RevsetParseError` to a string. Add the pest span (byte offset/length) and, for `RevsetParseErrorKind::NoSuchFunction`, the `candidates` list as fields (keep `reason` as fallback), so the UI can underline the position and offer "did you mean `bookmarks()`?". Consider the same for `ResolutionError` (jj-lib already computes `collect_similar` candidates over tags + bookmarks for unknown symbols).
3. **Completion candidates.** `Repo::revset_completions(partial_expr, filter: Option<revset>) -> Vec<Candidate { text, help, kind }>`, ported from the CLI's shell completion at v0.44.0 (`cli/src/complete.rs`: `revisions()` + `split_revset_trailing_name()`), **in-process over existing zanshin-jj reads instead of `jj` subprocesses**: local + remote bookmarks (skip `@git`), tags (skipped when a filter is set — they are almost always immutable), workspace names as `name@` (only when >1 workspace), change ids with first description line (limit 100 over `revsets.short-prefixes` → `revsets.log`), and revset aliases from the effective config with their `.doc` text. Prefix-match on the trailing name, re-prepend the untouched expression prefix, CLI display order.
   **Builtin function names are the gap:** the CLI does not complete them and jj-lib's `BUILTIN_FUNCTION_MAP` is a private `static` (only leaks as `NoSuchFunction.candidates`). Options: (a) our own list from `docs/revsets.md` at the pinned tag, bumped with the `jj-lib` pin — same pattern as the builtin `[revset-aliases]` table already mirrored in `build_aliases_map` (4.9); (b) omit initially, presets + bookmark completion cover the everyday case. **Open — lean (b) first, (a) if missed.**
4. Surface through the usual chain (`.fbs` → `extern "C"` → `WorkerCommand`); MCP optional.

**Open questions for refinement:** preset depth `N`; Save scope (repo / user); function-name list in or out; `ResolutionError` candidates in or out; "Apply" vs "Test" wording; whether Apply's evaluation reuses `graphSlice` directly (it should — no separate validate-only FFI is needed once live validation is off the table).

**Related:** 2.5 (revset error taxonomy), 4.3/4.4 (`stream_lanes`/`graphSlice` take the revset as a pass-through), 4.9 (`log_defaults`, alias map), 9.11 (bookmark track), 9.19 (bookmark list filters). Cheap-to-medium; read-side plus one config write.

### Story 9.26: Implicit snapshot + colocated Git import before every verb — `workspace_helper` parity, reverses D2 [M]
*(Added 2026-09-17, Ralph — full spec: `implementation-artifacts/spec-9-26-implicit-snapshot-colocated-git-import.md`. Depends on 9.22 and 9.27.)*

**Motivation.** Almost every jj CLI command starts with `workspace_helper` → `snapshot_impl` (`cli/src/cli_util.rs:472-516`, `:1298-1326` @ v0.44.0): colocated → `import git head` (re-parents `@` and resets the working-copy state when HEAD moved) → `snapshot working copy` → `import git refs`; non-colocated → the snapshot alone. Zanshin does none of it — project decision D2 (Story 2.4, the AC at `epics.md:1233-1236`, ADR-0002's "Zanshin reacts, never initiates") bet on Watchman snapshotting at the system level. Verified against v0.44.0 on 2026-09-17: Watchman is opt-in and not bundled, jj-lib triggers none of this itself, and the trigger the CLI registers excludes `.git`/`.jj` (`lib/src/fsmonitor.rs:318-337`), so a `git commit`, `git checkout`, an IDE's background fetch or a plain external edit leaves every Zanshin verb on a stale `@`, stale bookmarks and a stale HEAD until the user runs a `jj` command. **Ralph's rule, reaffirmed 2026-09-17: Zanshin behaves exactly like the jj CLI so a user can switch between both without thinking.**

**Scope (backend).**
1. Port `snapshot_impl` as ONE precondition run before every verb whose CLI counterpart goes through `workspace_helper` (reads and mutations); NOT before the CLI's `workspace_helper_no_snapshot` set (`workspace root`, `op integrate`, `util backend name`, `debug *`, `bench *`) nor before `detect`/`open`/`init`/`clone`/`convert`. Same three operations, same descriptions, each written only on `has_changes()`; immutable `@` → new commit on top; stale working copy per `handle_stale_working_copy` (`Updated` → reload, `Stale` → typed refusal; `snapshot.auto-update-stale` routes to 9.23).
2. The CLI's `git_import_export.lock` (jj-lib `FileLock`, colocated only) held across the precondition and across every mutation's colocated `export_refs`/`reset_head` — jj's own lock, so parity, not a new cross-process lock; project-context `:639-642` to be amended.
3. Every knob from the effective config: `snapshot.*`, `git.abandon-unreachable-commits`, `git.record-synthetic-predecessors`, `remotes.<name>.auto-track-bookmarks`, `fsmonitor.*`; jj-lib's `watchman` feature enabled (CLI default features are `watchman` + `git`, jj-lib's default is `git` only) so a user's `fsmonitor.backend = "watchman"` behaves as in the CLI.
4. `jj util snapshot` as an explicit verb `Repo::snapshot()` → `{ was_snapshot_taken, stats }`.
5. Facts that ride the payload, never text: `SnapshotStats` (9.22's table), `was_snapshot_taken`, immutable-on-top flag, rebased counts, HEAD-reset flag, the `GitImportResult` projection, `.jjconflict` warning, export failures.
6. Knock-ons in the same change: `convert.rs::import_git_head` gains `check_out` + `reset`; `git.rs`'s "no colocated skip" divergence note retires (after the precondition the verbs find nothing to do — the CLI's end state); every "Zanshin never snapshots (D2)" paragraph goes; dated addenda on `epics.md:1233-1236` and ADR-0002; the on-disk-edit witnesses 9.3/9.4/9.7 documented as missing.
7. Loop-free with the watcher: a Zanshin-written op → `OpHeadsChanged` → refresh → precondition → nothing changed → no op (`LockedWorkspace::finish` writes nothing when clean) — pinned by a test.

**Prerequisite — Story 9.27 (added 2026-09-17):** `Repo::open`/`init`/`clone` build their `UserSettings` from `repo.rs::make_settings`, which hardcodes `user.name = "Zanshin"`, `user.email = "zanshin@localhost"`, `operation.username = "zanshin"`, `operation.hostname = "localhost"` and adds NO user config layers. Every operation and commit Zanshin writes carries that identity instead of the user's, and jj-lib's working-copy `fsmonitor`/snapshot settings never see the user's config. The precondition is only CLI-parity once `Repo` opens with the effective stack (`config::load_for_workspace` → `UserSettings::from_config`).

**Non-goals.** No caching/debouncing/timer heuristics (the trigger is the verb call, like the CLI; the UI decides when to call — FR-JJ-17); no terminal text; no `--ignore-working-copy`/`--at-op`/`--no-integrate-operation`; not 9.23's recovery, not 9.22's verbs, not FR-FFI-7 Watchman detection. Medium-to-large; touches every verb module once.

### Story 9.27: `Repo` opens with the effective jj config — identity, op metadata, snapshot/fsmonitor knobs (config-stack parity) [M]
*(Added 2026-09-17, Ralph — full spec: `implementation-artifacts/spec-9-27-effective-user-settings-config-stack.md`. Prerequisite of 9.26; 9.28 is its editing counterpart.)*

**Motivation.** `repo.rs::make_settings` builds the `UserSettings` every `Repo::open`/`init`/`clone`/convert uses from jj-lib's defaults plus ONE hardcoded layer (`user.name = "Zanshin"`, `user.email = "zanshin@localhost"`, `operation.username = "zanshin"`, `operation.hostname = "localhost"`) — no user config file, no `JJ_CONFIG`, no repo/workspace layer, no environment layers. Every op Zanshin writes says `zanshin@localhost`, every commit it creates or rewrites is signed `Zanshin <zanshin@localhost>`, and jj-lib's working-copy settings (`fsmonitor.*`, `snapshot.*`) never see the user's config. `config::load_with` mirrors Default/User/Repo/Workspace already, but only for named reads. Found 2026-09-17 while authoring 9.26; never recorded before.

**Scope (backend).** (1) Build `UserSettings` from the CLI's full stack in the CLI's order (`cli/src/config.rs` @ v0.44.0): Default → System (`/etc/jj/…`) → EnvBase (`whoami` hostname/username, `$USER` fallback, `NO_COLOR`, `VISUAL`/`EDITOR`) → User → Repo → Workspace → EnvOverrides (`JJ_USER`, `JJ_EMAIL`, `JJ_TIMESTAMP`, `JJ_RANDOMNESS_SEED`, `JJ_OP_*`, `JJ_EDITOR`, `JJ_PAGER`); no CommandArg layer; `whoami::hostname()` in the `--when.hostnames` resolution context. (2) Open order = `Workspace::load` split in two: `DefaultWorkspaceLoaderFactory` → `repo_path()` → stack → settings → `loader.load`. Creation paths use the stack without repo/workspace layers and re-open. (3) Re-derive settings + reload the `Workspace` when the stack changed (after 9.28 writes; per-verb fingerprint), so an external `jj config set` takes effect without restarting. (4) Empty identity is the CLI's behaviour — proceed, and report `MutationResult.identity_missing { name, email }` where the CLI warns at `finish_transaction` (`cli_util.rs:2387-2415`); the UI's "set your identity" prompt is backed by 9.28. (5) Config faults refuse at open as `jj.config_error`. (6) Tests pin `JJ_USER`/`JJ_EMAIL`/`JJ_OP_HOSTNAME`/`JJ_OP_USERNAME` in the existing `ENV_GUARD`s (jj's own harness does the same) and retire the per-test settings stubs.

**Non-goals.** No `.gitconfig` fallback — jj reads identity only from its own config (`lib/src/settings.rs:141-142`); no config editing (9.28); no CommandArg layer. Small-to-medium.

### Story 9.28: Config surface — `config list`/`get`/`path`/`set`/`unset`/`edit` for user, repo and workspace scope [M/R]
*(Added 2026-09-17, Ralph — full spec: `implementation-artifacts/spec-9-28-config-surface-list-get-set-unset-path-edit.md`. Depends on 9.27. Backend for SourceTree-style repository and global settings; the UI is Ralph's scope.)*

**Motivation.** A user must be able to see where a value comes from and change it from Zanshin — identity (`user.name`/`user.email`, the target of 9.27's prompt), `revsets.log` (9.25), `snapshot.auto-track`, remotes' settings — at the CLI's scopes, so a value set in Zanshin is the value the CLI reads next and vice versa.

**Scope (backend).** Port the `jj config` group @ v0.44.0 (`cli/src/commands/config/*.rs`) for `--user`, `--repo`, `--workspace`: **`list`** = `resolved_config_values` port → `{ name, value (TOML text), source, path?, overridden }` with the CLI's filters (prefix, scope, `include_defaults`, `include_overridden`); **`get`** = resolved value, strings unquoted; **`path`** = candidate paths (user) / the secure file, creating the config dir + id when missing (repo, workspace — the CLI's side effect); **`set`** = the CLI's file selection (`config_files_for`: existing layers of the scope, else the default new file; several existing files → candidates back to the UI, explicit `path` on retry — FR-JJ-17), `parse_value_or_bare_string`, `ConfigFile::set_value` refusals (`WouldOverwriteValue`/`Table`), the `user.name`/`user.email` working-copy-author fact, `toml_edit` round trip; **`unset`** = `delete_value`, "doesn't exist" / `WouldDeleteTable` refusals; **`edit`** = GUI split into `config_file_read` (creates the file if absent) + `config_file_write` (validates as a `ConfigLayer` before writing, jj-lib's parse error + span on refusal). Every write triggers 9.27's reload; no operation is written. The three existing private repo-config writers (remote remove/rename, `trunk()` alias) and 9.25's `revsets.log` writer move onto the same `ConfigFile` helper family.

**Non-goals.** No key catalogue or schema (the CLI sets any key); no `.gitconfig`; no `$EDITOR`; no op-log entry. `config gc` is an open question (own line or rides along). Medium.

### Story 9.29: Bookmark list tracking state — `synced`, `tracked`, ahead/behind distances, untracked and deleted rows (`bookmark list --all-remotes` parity) [R]
*(Added 2026-09-20, Ralph — captured from a console session; refined enough to build from, ACs to be authored when scheduled. The UI decisions below are Ralph's from that session; this story is the backend behind them. Cheap (Tier A); read-only.)*

**Motivation.** `zanshin_jj::Bookmark` (`bookmarks.rs`, FR-JJ-8 / Story 2.8, surfaced in 3.4b) carries `name`, `target` (a **change id**) and `kind` (`Local` | `Remote { remote_name }`) — nothing about tracking or sync — and silently drops every untracked remote bookmark (the `!remote_ref.is_tracked()` skip). The graph rows (Story 4.8, `CommitRef.synced`) know a bool, but omit tracked-and-synced remote entries by design and never count. **A UI cannot derive the sync state from the list:** after a local rewrite (`describe`, `squash`, rebase) the local bookmark and `<name>@origin` share the change id but point at different commits — in the session's example a feature bookmark was `twrlxnqp dca3174e` locally and `twrlxnqp/1 bdf75096 (hidden)` on `@origin`; comparing the two `target`s says "in sync", `jj bookmark list --all-remotes` says `(ahead by 1 commits, behind by 1 commits)`. Without `tracked` the UI also cannot offer `bookmark track` (9.11) for rows it never sees, and cannot tell a deleted-but-still-tracked local bookmark from an untracked remote one.

**How the CLI computes it (verified @ v0.44.0; no network involved).** `cli/src/commit_ref_list.rs::collect_items` builds the rows from `view.bookmarks()` (names with an absent local target but remote refs included); `cli/src/commit_templater.rs::CommitRef::{local,remote,remote_only}` (`:1567-1632`) derive `synced` — local row: every tracked remote agrees with the local target; remote row: tracked AND same target — and `tracking_ahead_count` / `tracking_behind_count` (`:1689-1716`) evaluate `jj_lib::revset::walk_revs(repo, wanted, unwanted)` (= `unwanted..wanted` over the two targets' `added_ids`, `lib/src/revset.rs:2590`) + `Revset::count_estimate()` → `(lower, Option<upper>)`, with a `(0, Some(0))` fast path for synced rows. Direction is the **remote row's**: `ahead` = commits the remote target has that the local lacks (`local..remote`), `behind` = commits the local has that the remote lacks. `format_tracked_remote_ref_distances` (`cli/src/config/templates.toml`) prints `ahead by N commits` for an exact count and `ahead by at least N commits` when `upper` is `None`. All of it is a local computation over the last-fetched `<name>@<remote>` target — it says nothing about the server since the last fetch (that is 9.24's job). `@git` is a remote named `git`, tracked by definition (`lib/src/git.rs:1119-1125`), so in a colocated repo it has a row like any other remote; the CLI's no-flag default hides synced tracked rows and its `--tracked` implies `--remote=~git` — both are *filters* over the same row set.

**Scope (backend).**
1. **Widen `Bookmark` in place** (`.fbs` → `zanshin-jj` → Dart; WIP, no `_v2`) to the CLI `CommitRef` facts: every row gets `conflicted` (target has >1 added id; `target` keeps the first added id — the removed/added target set is NOT widened here) and `synced`; **remote rows** additionally `tracked` and — only when tracked and the local target is present (`is_tracking_present`) — `ahead` / `behind`, each `{ lower, upper? }` with `upper` null-for-absence when jj-lib cannot bound it; **local rows** whose target is absent but which still have tracked remote refs are emitted with `target` absent (null-for-absence) instead of being dropped — the CLI's `(deleted)` row, the state `jj git push --deleted` acts on. Dart: `target` becomes nullable, `synced`/`conflicted` sit on `Bookmark`, `tracked`/`ahead`/`behind` on `RemoteBookmark`.
2. **Emit the full row set, i.e. `--all-remotes`:** present local rows, deleted-with-tracked-remotes local rows, tracked remote rows (synced or not), **untracked remote rows** (`tracked: false`, no distances). Absent remote refs stay skipped as today. `@git` rows are emitted like any other remote and are NOT special-cased in the backend — hiding synced rows, excluding `git`, name/remote/revision filters and sort keys are 9.19's typed-filter work or a UI decision (backend exposes, UI decides; FR-JJ-17).
3. **Computation exactly as the CLI's:** synced → `(0, Some(0))` without evaluating anything; otherwise one `walk_revs` range revset per direction per unsynced tracked pair, `count_estimate` carried as-is. Inside the same `load_at_head` scope as the listing (ADR-0002, stateless per call); cost is bounded by the number of unsynced pairs. No new error code — a revset evaluation failure is `BookmarkError::Backend` (`jj.jj_lib_error`, "also emitted" clause).
4. **Surface** through the shipped chain: `.fbs` table `Bookmark` widened, `zanshin_bookmarks` signature unchanged, Dart `Bookmark`/`BookmarkKind` widened plus decode tests per new field (coverage attribution), `docs/ffi-abi.md` / `docs/rust-error-codes.md` clauses; MCP optional (7.3 lists bookmarks).
5. **Tests** construct the states in-test with `test_helpers::{set_local_bookmark, set_remote_bookmark}` (the checked-in fixtures carry no remote bookmarks — never regenerate): synced (fast path, no revset evaluated), remote-ahead only, local-ahead only (`behind`), diverged after a local rewrite (**same change id, different commits — ahead 1 / behind 1**, the session's case), untracked remote (no distances), deleted local with a tracked remote, conflicted local, `@git` row in a colocated workspace. The inexact `upper: None` path need not be forced if no fixture can produce it — the field is carried, not computed, here.

**Non-goals.** No network and no "new on the server" signal (9.24); no commit-summary columns, sort keys, `-r`/name/remote filters or the CLI template matrix (9.19); no `track`/`untrack`/`set`/`forget` (9.11); no removed/added conflict targets; no repo-wide "ahead/behind" number — jj has none, the CLI prints per-row distances, and a UI badge that sums them is a UI choice (ADR-0002's overview tier lists "ahead-behind shown").

**UI shape (decided, for context — Ralph's scope).** Per-bookmark "↑ ahead / ↓ behind" on the row (SourceTree's pull/push counts translated: `ahead` = fetched but not integrated, `behind` = to push); a "(deleted)" and an "untracked" state per row with `track` offered on the latter (9.11). The Fetch button's badge does NOT come from here but from 9.24 (count of remote bookmarks that changed upstream); its enable rule and default remote come from 9.30.

**Related:** 2.8 (`list_bookmarks`), 4.8 (`CommitRef.synced` on graph rows, same rule), 9.8 (the deleted-local-with-tracked-remote state, pinned there), 9.11, 9.19, 9.24, 9.30.

### Story 9.30: `git fetch` CLI parity — default remotes (`git.fetch`), `--all-remotes`, `--tracked`, bookmark/tag patterns, per-remote fetch settings [M]
*(Added 2026-09-20, Ralph — captured from the same console session as 9.29; ACs to be authored when scheduled. Extends 6.4a; small-to-medium.)*

**Motivation.** `Repo::git_fetch(remote_name, progress)` (6.4a) takes exactly ONE explicit remote and always fetches `glob("*")` bookmarks and tags. The front half of `cmd_git_fetch` (`cli/src/commands/git/fetch.rs` @ v0.44.0) is missing, so a GUI Fetch button has to invent a remote picker even for the everyday one-remote case and cannot mirror what `jj git fetch` would do. Found while answering "how does the Fetch button know it may be enabled".

**Scope (backend) — port the CLI's resolution, pass parameters through (FR-JJ-17).**
1. **Default remotes** (`get_default_fetch_remotes`): `remote` becomes optional; absent → `git.fetch` from the effective config (a list or a single string, as name patterns) → else the single existing remote (the CLI's "Fetching from the only existing remote" hint becomes a payload fact when that remote is not `origin`) → else `origin`.
2. **Remote selection:** `--remote` string patterns (glob by default) and `--all-remotes`, matched against `git::get_all_remote_names`; unmatched exact names reported as payload (the CLI's "No matching remotes for names" warning); **no matching remote refuses** (`No git remotes to fetch from`, a `user_error`, no operation written) — this refusal IS the Fetch button's enable rule: enabled when the default resolution yields ≥1 remote (`list_remotes` already answers "any remote at all"; a git backend is required either way).
3. **What to fetch per remote:** `--branch` / `--tag` patterns (glob, `*` only; union and negative intersection) when given; otherwise `remotes.<name>.fetch-bookmarks` / `fetch-tags` from the remote settings (`parse_remote_fetch_bookmarks/tags`), else the git config's fetch refspecs via `load_default_fetch_bookmarks` (its `IgnoredRefspecs` become payload — the CLI warns) and all tags; `--tracked` = the exact-name unions of that remote's already-tracked bookmarks/tags (`View::local_remote_bookmarks/tags` filtered by `is_tracked`), mutually exclusive with the patterns (clap `conflicts_with`) — a typed either/or, not a refusal.
4. **One transaction for all matched remotes**, one `import_refs`, one op description `fetch from git remote(s) a,b` (the CLI's `join(",")` — NFR-R-2 byte parity), `warn_if_branches_not_found` as payload; the shipped progress callback (FR-FFI-8) fires per remote.
5. **`remotes.<name>.auto-track-bookmarks`** honoured through `GitImportOptions.remote_auto_track_bookmarks` exactly as the CLI's `load_git_import_options` builds it (deferred in 9.5/9.8's notes; fetch and clone pass an empty map today) — one shared helper with `git_import` (9.5), so the three verbs cannot drift.
6. Surface through the shipped chain: the 6.4a request gains the optional fields in place, `MutationResult` unchanged apart from the payload facts above; Dart `gitFetch` widened; MCP optional.

**Non-goals.** No `git push` (9.20), no remote-change poll (9.24), no `--no-integrate-operation` handling (a CLI global), no terminal wording. The implicit snapshot/import before the fetch is 9.26's cross-cut, not this story's.

**Tests.** Local bare remotes built in-test as 6.4a does: two remotes for `--all-remotes` / patterns and the single-remote default; `git.fetch` set through the config layers 9.27 makes effective; `--tracked` over `set_remote_bookmark(.., tracked = true)`; the ignored-refspec and unmatched-name payloads; the no-remote refusal writes no operation.

**Related:** 6.4a, 9.5 (import-options helper), 9.11 (auto-track is `track`'s rule), 9.24, 9.26, 9.27 (effective config), 9.29.

### Story 9.31: Drop-action capability query — `drop_actions(source, location)`: which verbs may run for this change at this location, and why not (CLI precondition parity) [R]
*(Added 2026-09-21, Ralph — captured from a console session on commit drag-and-drop; refined enough to build from, ACs to be authored when scheduled. Small-to-medium; read-only, no transaction, no op-log entry. The UI decisions below are Ralph's from that session; this story is the backend behind them.)*

**Motivation.** Zanshin's graph will be driven by drag-and-drop: the user drags change S and drops it *on* change T, into the gap *above*/*below* T, or on an edge. At that moment the UI needs two answers — is anything possible at all, and which verbs are — so it can show a drop menu of the *available* options and grey the rest out with the reason (backend exposes capabilities, the UI offers the decision — FR-JJ-17). Hand-writing those rules in Dart would duplicate the verbs' refusals and drift from them. The jj CLI already splits every verb into a pure precondition phase and a transaction phase: `compute_commit_location` (`cli/src/cli_util.rs:3551` @ v0.44.0) turns `-o`/`-A`/`-B` into `(new_parents, new_children)` and refuses immutable children and loops (`ensure_no_commit_loop`, `:3641`); `check_rewritable_expr` (`:2011`) refuses immutable targets; `rebase.rs::plan_rebase_{revisions,source,branch}` + `check_rebase_destinations` (`:431-599`) add "Cannot rebase X onto itself" / "onto descendant"; `squash.rs:223-228` refuses a merge source without an explicit destination; `duplicate.rs:123-124` refuses the root; `absorb` considers only ancestors of the source; the Git backend refuses a merge with the root commit as one parent (`lib/src/git_backend.rs:1301`). **Story 9.1 already ported the shared half** into `op_support.rs` (§1 `check_rewritable`/`resolve_immutable`, §2 `compute_commit_location`/`ensure_no_commit_loop`), tested but unwired. This story composes them into one read.

**The mapping (verified @ v0.44.0).** The drop position IS the CLI's location: drop *on* T = `-o T` (parents `{T}`, nothing else rewritten), *above* T = `-A T` (parents `{T}`, all of T's children rebased onto S — they must be mutable), *below* T = `-B T` (parents = T's parents, T and its descendants rebased onto S — T must be mutable), on an *edge* T→C = `-A T -B C`. `-o`/`--onto` with `-d`/`--destination` as aliases since 0.44. Immutability is ancestor-closed, so checking a source covers its descendants; a `-A` target's children are the one set that needs its own check.

**Scope (backend).**
1. **`Repo::drop_actions(source: ChangeId, location: DropLocation) -> DropActions`** with `DropLocation { onto, insert_after, insert_before: Vec<ChangeId> }` — the CLI's `RebaseDestinationArgs` shape passed through (`onto` exclusive with `insert_after`/`insert_before`; an edge drop is after+before; a merge location is several ids), never a Zanshin-invented position enum that bakes a default in. Result: one row per verb of the fixed matrix, `DropAction { verb, status: Available | NoOp | Refused, refusal: { code, reason }? }` (`refusal` null-for-absence).
2. **The matrix** (verb → what the CLI checks, all before any transaction): `rebase -r` (S rewritable; `-o`: T ≠ S; T MAY be a descendant of S — explicitly allowed for `-r`); `rebase -s` / `rebase -b` (S resp. `roots(T..S)` rewritable; `-o`: T ≠ S and T not a descendant of S — `check_rebase_destinations`; `-b` with an empty branch is `NoOp`); `squash --from S --into T` (`-o` only; S ≠ T; S AND T rewritable; any graph relation — parent, ancestor, descendant, unrelated); `new T S` = merge (`-o` only; S ≠ T; neither root — the Git backend's refusal reproduced up front; immutability irrelevant, nothing is rewritten); `duplicate S` (S not root; S may be immutable; the location checks only); `revert -r S` (the location checks only); `restore --from S --into T` (`-o` only; T rewritable; same tree = `NoOp`, the shipped 9.3 guard); `absorb --from S --into T` (`-o` only; T rewritable AND an ancestor of S, else `NoOp`); `interdiff --from S --to T` (`-o` only; S ≠ T; read-only). `rebase -o` with `parents(S) == new_parents` is `NoOp` (the CLI's "Skipped rebase … already in place"); no other no-op is computed — the CLI refuses none of them either, the verb reports its stats.
3. **One precondition function per verb, shared with the verb** — the contract this story establishes (recorded on 9.9/9.15/9.16/9.18 in `sprint-status.yaml`): each verb's precondition phase is ONE pure `plan_*` fn (the CLI's own split) called by the verb AND by `drop_actions`, so preview and execution cannot disagree. For the shipped verbs (`new_change`, `restore`, `absorb`, `interdiff`) this story extracts their guards into that shape; for the Tier C verbs (`rebase`, `squash`, `duplicate`, `revert`) it ports the CLI's plan phase now (≈20-40 lines each over 9.1's helpers) and the verb stories add the transaction phase on top — whichever story lands first creates the function, the other one calls it.
4. **Refusal codes reuse the registry** (`docs/rust-error-codes.md`): `jj.immutable`; `jj.invalid_input` for onto-itself / onto-descendant / loop / no parent / root duplicate / root merge; `jj.change_not_found` for an unresolvable id; `jj.config_error` for a broken `immutable_heads()` alias — `reason` carries the CLI's message verbatim where the CLI has one. **No new error code**; the query's own failures are the same codes with "also emitted" clauses.
5. **Read semantics:** inside one `load_at_head` scope (ADR-0002, stateless per call); once 9.26 lands, behind the same implicit snapshot/import as the verbs it previews, so the preview sees the `@` the verb will see. **Advisory by design:** the repo can change between hover and drop (an external `jj`), so the verb's own refusal stays authoritative and the UI shows it — the preview never replaces the verb's check.
6. **Surface** through the shipped chain: `.fbs` (`DropActionsRequest` / `DropActions`), `zanshin_drop_actions` extern, committed codegen, Dart `RepoHandle.dropActions(...)`, `docs/ffi-abi.md`; MCP optional (an agent's "what can I do with X" — Epic 7).
7. **Tests:** a fixture matrix per verb × relation (T parent of S / ancestor / child / descendant / unrelated; S == T; S root; T root; S immutable; T immutable; a child of T immutable) × location (onto / after / before / after+before), each cell pinning the status and, for `Refused`, the code and message; for every SHIPPED verb the cell also executes the verb and asserts agreement (preview ⇔ execution); each later verb story adds its agreement row. New file → coverage floor 80 %.

**Non-goals.** No bookmark-label drops (`bookmark set`/`move`'s "Refusing to move bookmark backwards or sideways" — 9.11/9.19 own `is_fast_forward`; the same query pattern applies to a bookmark payload once they land); no target-less "what can I do with S" for a context menu (same machinery, own story if wanted); no `abandon` row (a one-commit verb — a trash zone, not a drop on the parent, which is `squash`); no `split`/`parallelize`/`arrange` rows (file-level and set-level gestures; 9.15/9.16); no execution; no UI.

**UI shape (decided, for context — Ralph's scope).** Drop zones are commits and *edges*, not gaps: in a branching graph "above T" is ambiguous (`-A T` inserts before ALL children of T, `-B C` before one), an edge T→C is exactly `-A T -B C`; in a linear stack the two coincide. On drop, a menu lists the available rows (move only S / with descendants / whole branch; squash; merge; copy; revert; compare …), unavailable rows greyed with the reason; ⌥-drag as a shortcut for copy (`duplicate`), never a hidden default. `jj arrange` (new in 0.44, the CLI's own TUI for this) supports only swap-with-parent/child and abandon/keep — this drag-and-drop is a superset, 9.16's headless `arrange_apply` stays for parity.

**Related:** 9.1 (the ported helpers), 9.3 (`restore`/`absorb` guards), 9.6 (`interdiff`), 9.9, 9.15, 9.16 (incl. the `-s`/`-b` + `-A`/`-B` corner recorded in deferred-work 2026-09-21), 9.18, 9.26 (snapshot precondition), ADR-0003, FR-JJ-17.

### Story 9.32: Warning channel on every envelope — `warnings: [{ code, message }]`, the CLI's `ui.warning_*` as coded facts [M/R]
*(Added 2026-09-24, Ralph — decided in a console session after the 9.22–9.28 follow-up reviews; refined enough to build from, ACs to be authored when scheduled. Cross-cut; prerequisite of 9.33 and 9.35.)*

**Motivation.** Zanshin already answers refusals with a machine-readable code (`Envelope.error { code, context }`, registry `docs/rust-error-codes.md`), but it has no uniform channel for the other half of what the CLI prints: **success with a warning**. Today each such fact is a one-off field — `MutationResult.identity_missing` (9.27), `Precondition.working_copy_immutable_new_commit` and `Precondition.jjconflict_files_present` (9.26) — and the creation verbs cannot report anything at all (9.33). Ralph's idea (2026-09-24): a status with a code the UI can switch on, so Zanshin can offer the remedy itself (missing identity → "set your identity") without ever parsing text. Decided shape: a **list** of warnings next to the existing result, not one HTTP-style status per response, because several warnings can hold at once (a clone with an empty identity AND a file too large to track AND a failed ref export).

**Scope (backend + bridge).**
1. **Wire:** `Envelope.warnings: [Warning]` (appended field, WIP in-place edit), `table Warning { code: string; message: string; }`. Present on ok AND error envelopes (a precondition that wrote operations before the verb refused still warns). Success without caveat = `ok = true` and an empty list — there is no "success" code.
2. **Rule:** every warning the CLI @ v0.44.0 writes through `ui.warning_default()` (or another `ui.warning_*` writer) and emits on a code path Zanshin ports becomes ONE warning code. Status lines (`ui.status()`: "Nothing changed.", "Already editing that commit.") are NOT warnings — they stay typed facts (e.g. the unchanged op id). Hints (`ui.hint_*`) are not ported — the UI derives its offer from the code. First task: an inventory of the warning sites on every shipped verb's path (`workspace_helper`/`snapshot_impl`, `finish_transaction`, the verb bodies), each mapped to a code or recorded as out of scope with the reason.
3. **Codes** live in the same registry as the error codes (a new "Warning codes" section of `docs/rust-error-codes.md`), `jj.` namespace, one code per remedy (the house rule for errors) — e.g. `jj.identity_missing`, `jj.working_copy_immutable`, `jj.snapshot_files_refused`, `jj.jjconflict_files_present`, `jj.git_export_failed`. `message` = the CLI's text verbatim where it has one (log/tooltip only; the UI never parses it). Structured data stays typed where it already is (`SnapshotStats`, `GitExportResult`, …): the warning says that there is something, the payload says what.
4. **One mechanism:** `MutationResult.identity_missing`, `Precondition.working_copy_immutable_new_commit` and `Precondition.jjconflict_files_present` move into warnings and the fields are removed (WIP in-place edit; the UI does not consume them yet). Which `FinishFacts` fields are warnings and which are data is part of the inventory.
5. **Rust surface:** the warnings leave `zanshin-jj` with the result they belong to (one collector per call, like `take_precondition()`), so MCP (Epic 7) inherits them.
6. **Dart:** every command's result exposes its warnings on success, handle-scoped and handle-less alike (the error path is 9.35); typed Dart constants for the registered codes.
7. `docs/ffi-abi.md` (envelope contract), coverage ratchet, a `zanshin_core` witness for every warning code a fixture can produce.

**Non-goals.** No UI (the "set your identity" offer is Ralph's); no severity levels beyond warning vs. error; no localization; no hint porting.

**Related:** 9.26 (`precondition`), 9.27 (`identity_missing`), 9.33, 9.35, 9.37 (secure-config warnings), 9.39 (undo-a-push warning), FR-JJ-17, AR-P-4.

### Story 9.33: Creation paths report what the CLI prints — `clone`/`init`/`convert`: `jj.identity_missing` + the conversion's snapshot report [M]
*(Added 2026-09-24, Ralph — decision "extend the return value" on the 9.27 and 9.26 follow-up deferrals. Depends on 9.32.)*

**Motivation.** The CLI warns about an empty identity in `finish_transaction`, which `jj git clone` reaches via `tx.finish(ui, "fetch from git remote into empty repo")` (`cli/src/commands/git/clone.rs:457` @ v0.44.0, also `:314`, `:352`) and `jj git init` over an existing Git repo via `tx.finish(ui, "import git head")` (`init.rs:268`). `zanshin_repo_clone`/`_init`/`_convert` return only a `RepoHandle`, so a GUI clone — the typical first action on a new machine — writes its operations and `@` with the empty identity and the UI learns of it only at the first later mutation. Likewise the conversion's snapshot (`maybe_snapshot` in `jj git init` over an existing repo) drops its report — files left untracked by `snapshot.max-new-file-size`/`auto-track`, the colocated `.jjconflict` warning, export and HEAD-reset failures — because 9.26's AC-3 kept `precondition` off convert envelopes.

**Scope.** (1) The three creation envelopes carry 9.32's warnings exactly where the CLI's flow warns: `jj.identity_missing` only when a `finish_transaction`-equivalent committed an operation (verify each flow @ v0.44.0 — a fresh `init` of an empty directory finishes no transaction, so no warning), plus the conversion's snapshot/export warnings. (2) The conversion's snapshot report rides the convert envelope as the `Precondition`/`SnapshotStats` data 9.26 defined (AC-3's exclusion lifted). (3) Dart `clone`/`init`/`convert` return the handle together with warnings and report. (4) Witnesses per flow: clone with and without identity, init of an empty directory vs. over an existing Git repo, convert (colocated and import) with a file over the size limit.

**Non-goals.** No change to what the flows do (9.20 owns the remaining clone/init parity gaps); no UI.

### Story 9.34: Snapshot knobs read after `import git head` — the CLI's refusal order in the precondition [M]
*(Added 2026-09-24, Ralph — from the 9.26 deferral "Wrong-typed snapshot knob is refused BEFORE the head import". Direction: the CLI's order, per Ralph's parity rule.)*

**Motivation.** Zanshin's precondition reads `snapshot.auto-track`, `snapshot.max-new-file-size`, the ignore files and `immutable_heads()` before taking `git_import_export.lock` (`snapshot.rs::Knobs::read`, `repo.rs::Repo::precondition`); the CLI reads the snapshot knobs only inside `snapshot_working_copy`, i.e. after its lock and its `import git head` (`cli_util.rs::workspace_helper_with_stats` → `snapshot_impl` @ v0.44.0). Observable in the double fault "Git HEAD moved outside AND a wrong-typed snapshot knob": the CLI writes `import git head` and then fails, Zanshin writes nothing and fails — two different op logs. Pinned today by `tests/snapshot_colocated.rs::a_wrong_typed_knob_is_refused_before_the_lock`; the 9.26 matrix row "refused before the lock" was the spec's wording, not the CLI's behaviour.

**Scope.** Read each knob where the CLI reads it (snapshot knobs inside the snapshot step; `immutable_heads()` where `snapshot_working_copy` needs it); invert the pinning test into the CLI's sequence (`import git head` written, then `jj.config_error`); rework the lock-wait witness that relied on the early read; a dated note on the 9.26 spec's matrix row (the CLI wins).

**Non-goals.** No other precondition change.

### Story 9.35: Dart keeps `precondition` and `warnings` on error results — handle-less commands included [bridge]
*(Added 2026-09-24, Ralph — from the 9.28 deferral "`zanshin_config_set`'s precondition is dropped on the Dart ERROR path". Depends on 9.32.)*

**Motivation.** Rust stamps `Envelope.precondition` (9.26) — and after 9.32 `Envelope.warnings` — on error envelopes too: a verb whose precondition snapshotted or imported (and wrote operations) and then refused. The Dart decoders throw `ZanshinFfiException` with code and context only, and `ZanshinWorker.send` records `lastPrecondition` only for handle-scoped commands. So the UI loses the report exactly when something went wrong — e.g. a `config_set` of `user.name` whose identity snapshot ran and then hit `jj.config_would_overwrite`.

**Scope.** The Dart error result (`ZanshinFfiException` or its successor) carries the envelope's `precondition` and `warnings`; every decoder passes them through; handle-less commands (`config_*`, the creation verbs) expose them the same way as handle-scoped ones; a real-cdylib witness per command family that produces an error envelope with a precondition or a warning. Bridge-only unless an error path turns out not to stamp the envelope.

**Non-goals.** No UI.

### Story 9.36: Finder/Dock launch sees the login-shell environment — `JJ_CONFIG`, `XDG_CONFIG_HOME`, `JJ_*` as in the terminal [bootstrap]
*(Added 2026-09-24, Ralph — from the 9.27 deferral "A Finder/Dock-launched Zanshin does not see the user's shell environment". **Decided 2026-09-24, Ralph: option (a)** — resolve the login-shell environment at start-up; (b) and (c) are kept below for the record only.)*

**Motivation.** 9.27's stack reads `JJ_CONFIG`, `XDG_CONFIG_HOME`, `JJ_USER`/`JJ_EMAIL`/`JJ_OP_*`, `VISUAL`/`EDITOR` and `NO_COLOR` exactly as the CLI does (`config.rs::ConfigEnv::from_env`), but an app launched by launchd gets launchd's minimal environment, not the login shell's. A user who sets `XDG_CONFIG_HOME` or `JJ_CONFIG` in a shell rc file then gets a different config — and identity — in Zanshin than in the terminal `jj`; the same holds for what jj-lib's `git` subprocess sees on fetch/push (`PATH`, `SSH_AUTH_SOCK`, `GIT_*`). Started from a terminal Zanshin behaves like the CLI; started from Finder it does not.

**Options (decided: (a)).** (a) Resolve the login-shell environment once at start-up — spawn `$SHELL -l -i -c` with a machine-readable `env` dump and a timeout, the approach VS Code and other macOS developer GUIs use — and hand the result to the config stack and the git subprocess environment as an explicit map (never `std::env::set_var` in a running multi-threaded process); fall back to launchd's environment on timeout or failure and report that as a 9.32 warning. (b) Nothing in the backend; document that shell-only variables do not reach a Finder-launched Zanshin. (c) A Zanshin setting that names `JJ_CONFIG`/`XDG_CONFIG_HOME` explicitly. Recommendation: (a) — the only option under which the same user gets the same config in both tools without having to know about launchd.

**Scope.** The resolution in the app bootstrap before the worker isolate opens a repo (worker boot is bridge scope; the map crosses to Rust once at init); `ConfigEnv` and the git subprocess environment read that map instead of the process environment; tests with a fake `$SHELL`; the fallback warning.

**Non-goals.** No UI beyond the warning; no edits to shell rc files.

### Story 9.37: Secure-config fix-ups at every command start — `SecureConfig::maybe_load_config` parity (legacy `.jj/repo/config.toml` migration, moved/copied repos) [M]
*(Added 2026-09-24, Ralph — from the 9.28 deferral "Read-side secure-config fix-ups are still not run". Direction: reverse "reading never writes" per Ralph's parity rule, as 9.26 reversed D2.)*

**Motivation.** At the start of every command the CLI loads the repo and workspace config through `ConfigEnv::reload_repo_config` / `reload_workspace_config` → `SecureConfig::maybe_load_config` (`cli/src/config.rs:585-593`, `:653-665`, called from `cli_util.rs:4545-4549` and `:4592-4595` @ v0.44.0). That call migrates a legacy `.jj/repo/config.toml` into the secure config directory and re-points or copies the config of a moved or copied repo, printing its `warnings` via `ui.warning_default()`. Zanshin's read path never writes (`config.rs` module doc "Reading never writes"), so `config_list` shows the legacy path until a CLI run or a Zanshin config WRITE migrates it, and a moved or copied repo is not fixed up the way the CLI's next command fixes it. Every on-disk effect of the CLI is required parity.

**Scope.** Run `maybe_load_config` for repo and workspace where the CLI does: `Repo::open`, the settings refresh at every verb start (9.27's fingerprint path — the fix-up must not trigger a reload loop), and the handle-less `config_*` functions with a workspace root (9.28); its warnings become 9.32 warning codes; `config.rs`'s "Reading never writes" doc and the 9.28 deferral are updated. Witnesses: a legacy file is migrated on first open and then listed with its new path; a copied repo gets its own config on open (cf. the 9.28 follow-up's copied-repo allow-list fix); no second migration on the next verb. Note: the CLI's `default_config_migrations()` (key renames through `jj_lib::config::migrate`) is empty at v0.44.0 — re-check at every pin bump; rules added there belong to this story's mechanism.

**Non-goals.** No `config gc` change (9.28 ported it).

### Story 9.38: `edit` of the current `@` is a no-op — "Already editing that commit." parity [M]
*(Added 2026-09-24, Ralph — pre-existing divergence found by the 9.26 follow-up review.)*

**Motivation.** `cmd_edit` (`cli/src/commands/edit.rs` @ v0.44.0) resolves the revision, runs `check_rewritable`, and then — when `get_wc_commit_id() == Some(new_commit.id())` — prints "Already editing that commit." and opens NO transaction. Zanshin's `mutate.rs::edit` always commits `edit commit <id>`, so `jj op log` gains an entry the CLI never writes, and a CLI `jj undo` after a Zanshin no-op edit undoes the previous real operation instead.

**Scope.** The same early return after the immutability check and before the transaction, returning the house no-op result (`new_op_id` = the pre-call head); an immutable current `@` still refuses as `jj.immutable` (the CLI checks first); witnesses for both plus the unchanged op count. The implicit snapshot (9.26) still runs first, as in the CLI.

### Story 9.39: `undo` = the v0.44.0 undo stack — a repeated `undo` goes further back [M]
*(Added 2026-09-24, Ralph — pre-existing divergence found by the 9.26 follow-up review. Related to 9.21 (`redo`) and 9.40 (no-change gate).)*

**Motivation.** `op_log.rs::undo` is v0.42.0's single-step walk-back; its doc says a second undo redoes the first. v0.44.0's `cmd_undo` (`cli/src/commands/undo.rs`) grows an undo stack keyed on the description prefix `UNDO_OP_DESC_PREFIX = "undo: restore to operation "`: undoing an undo-operation undoes the operation that undo restored to (going further back); a restore target that is itself an undo resolves to the original operation (no linked list of undos); redo is the separate `jj redo` (9.21). Refusals: "Cannot undo root operation", "Cannot undo a merge operation" (hint: `jj op restore`); undoing a push warns "Undoing a push operation often leads to conflicted bookmarks." The restore is `view_with_desired_portions_restored(target_parent.view, base.view, &DEFAULT_REVERT_WHAT)` under the description `undo: restore to operation <hex>`. A user alternating between CLI and Zanshin gets different results from the second undo today.

**Scope.** Port the stack walk step for step (both prefix look-ups, the at-most-one-parent refusals, `DEFAULT_REVERT_WHAT`, the description); the push warning as a 9.32 warning code (`is_push_operation`); witnesses for the op-log example in the CLI's own comment (A, B, C, undo, E, undo, undo → A), the root and merge refusals, and CLI↔Zanshin interleaving (an undo stack started by one tool is continued by the other). An undo that restores a view equal to the current one writes nothing — that comes from 9.40's gate.

**Non-goals.** `jj redo` (9.21), `op restore` / `op revert` (9.12).

**Update 2026-10-08 (jj 0.46, done).** Ported against `cmd_undo` @ v0.46.0, which adds two things to the scope above: an operation performed in ANOTHER workspace is refused ("Refusing to undo operation … because it was performed in workspace …") unless `--allow-cross-workspace` — `Repo::undo(allow_cross_workspace)`, `jj.undo_cross_workspace`, the flag through the FFI and `zanshin_core`; and undoing a `remove workspace` operation warns like a push does (`jj.undo_workspace_removal`, next to `jj.undo_push_operation`).

### Story 9.40: No-change verbs write no operation — `WorkspaceCommandTransaction::finish`'s `has_changes()` gate [M]
*(Added 2026-09-24, Ralph — pre-existing divergence first found by the 9.27 review, re-found by the 9.26 follow-up review.)*

**Motivation.** Every CLI verb that ends in `tx.finish(ui, …)` goes through `WorkspaceCommandTransaction::finish` (`cli_util.rs:2790-2806` @ v0.44.0), which prints "Nothing changed." and commits NO operation when `!tx.repo().has_changes()` — and therefore also shows no identity warning. `mutate::finish_verb` ports that function without the gate, so a `describe` with the same text, a `git fetch` that brings nothing, and an `undo` that restores an identical view all write an operation the CLI never writes; 9.27's identity fact fires with it, and a CLI `jj undo` afterwards undoes the wrong operation. `describe` additionally drops unchanged commits before rewriting (`describe.rs`: `old_commit.description() != commit_builder.description()`), so no descendant is rebased.

**Scope.** Add the gate to `finish_verb` (no-op result = the pre-call head op id, the house contract); port `describe`'s unchanged-description filter; audit every `finish_verb` caller against its CLI verb (does the CLI reach `tx.finish`, or commit the raw transaction like `track`/`untrack`?); witnesses per verb (describe with the same text, fetch with nothing new, undo to an equal view; the verbs already routed through `finish_or_no_op` stay unchanged). Coordinate with 9.30's fetch rework — whichever lands first owns fetch's witness.

**Non-goals.** `edit`'s guard (9.38), the undo stack (9.39).

**Update 2026-10-08 (jj 0.46 bump).** The gate is unchanged at v0.46.0 — `WorkspaceCommandTransaction::finish` is now `cli_util.rs:2849-2865` ("Nothing changed." → no commit; descendants are rebased through the free `rebase_mutable_descendants(&env, &mut tx)`). Audit the verbs against v0.46.0, not v0.44.0: `undo` (9.39) is already ported against 0.46 and also ends in `tx.finish`; the new 0.46 verbs `file edit` / `file delete` (9.44) go through the same gate (and each has its own earlier "Nothing changed." when the rewritten tree would equal the commit's).

### Story 9.41: `--when.commands` config scopes apply per verb — every Zanshin verb resolves the config with its CLI command name [M]
*(Added 2026-09-24, Ralph — from the 9.27 second follow-up review's deferral "`--when.commands` scopes never apply outside the config verbs".)*

**Motivation.** A jj config file can scope a table to commands: `[[--scope]]` with `--when.commands = ["git fetch"]`. jj-lib's resolver (`config_resolver.rs:74-78`, `matches_command` @ 0.44.0) matches space-separated prefixes (`["git"]` matches `git fetch`, `["git fetch"]` matches `git fetch` and longer). The CLI names the command before its start-up resolution — `config_env.set_command_name(command_name(&matches))` (`cli_util.rs:4581` @ v0.44.0), where `command_name` joins the clap subcommand chain with spaces (`:4238-4248`, e.g. `"git clone"`, `"describe"`, `"bookmark create"`) — and `settings_for_new_workspace` clones that `config_env` (`:377`). So a scope applies to exactly the commands it names, including identity and op metadata: a user can give `jj git clone` a different `user.email` or `describe` a different editor setting. Zanshin resolves with `command: None` for every verb except Story 9.28's config verbs (documented in the `config.rs` module doc), so such a scope never applies — at creation, open or mutation — and Zanshin writes something the CLI would not.

**Scope (backend).**
1. **Mapping:** every public verb carries the CLI command name of its counterpart as a constant next to the verb (`Repo::clone` → `"git clone"`, `init` → `"git init"`, `convert_colocated` / `convert_import` → `"git init"`, `describe` → `"describe"`, `new_change` → `"new"`, `git_fetch` → `"git fetch"`, `bookmark_create` → `"bookmark create"`, `file_track` → `"file track"`, `snapshot` → `"util snapshot"`, reads → `"status"`, `"log"`, `"show"`, `"file show"` …) — one table in one place, audited against the clap tree @ v0.44.0 and re-checked at every pin bump. Where one Zanshin read serves several CLI commands (e.g. the graph = `log`), the table names the command whose output it replaces and says why.
2. **Resolution:** the name flows into `ConfigResolutionContext.command` for the verb's own resolution — the start-up stack (9.27 `check_startup_stack`), `settings_for_new_workspace`, the per-verb settings refresh inside `Repo::precondition` and every named config read the verb does (`config::load_with`).
3. **Settings per verb:** because the resolved settings now depend on the verb, the refresh can no longer be decided on the stack-file fingerprint alone — resolve per verb and reload the `Workspace` only when the RESOLVED settings differ from the ones it was loaded with (so a config without command scopes keeps today's zero-reload behaviour). Pin the cost on `large-10k` like 9.27 did.
4. The 9.28 config verbs already pass `"config …"` names — fold them into the same table.
5. Witnesses: a `--when.commands = ["describe"]` scope changes the author/op metadata `describe` writes and NOT what `new_change` writes; a `["git clone"]` scope applies to the clone's operations; a `["git"]` prefix matches `git fetch`; no scope → no workspace reload between two different verbs.

**Non-goals.** No CLI aliases (`[aliases]` expansion changes the CLI's command name, but Zanshin has no alias input); no `--config`/`--config-file` flags.

**Related:** 9.26 (`precondition`, where the refresh runs), 9.27 (config stack, fingerprint refresh), 9.28 (config verbs), 9.33, 9.36.

### Story 9.42: Graph walk evaluates like `jj log` @ v0.46 — `at_operation()` over sibling operations, `within_visibility` prioritization [R]
*(Added 2026-10-08, console session — surfaced by the jj-lib 0.44 → 0.46 bump; `deferred-work.md` "Surfaced 2026-10-08". Low priority: only an edge case benefits.)*

**Motivation.** Since jj 0.46 `jj log` evaluates its revset through the evaluator that merges the indexes of every `at_operation()` it references (`cli/src/commands/log.rs:161` @ v0.46.0), so `at_operation(<op>, …)` works for operations that are NOT ancestors of the current one (siblings from concurrent commands — CHANGELOG 0.46 "Fixed bugs"). It also confines `revsets.log-graph-prioritize` with `within_visibility(repo)` (`log.rs:186-193`), so commits referenced only through `at_operation()` are not affected by the prioritization. Zanshin's graph walk (`crates/zanshin-jj/src/graph.rs::LogParse::evaluate`, Story 4.12's `zanshin_graph_topology`) resolves the expression and evaluates the RESOLVED form against the repo's own index, because the topology's index-only passes refine that resolved expression — so a log revset with a sibling `at_operation()` still fails there, and the prioritization is not confined.

**Scope.** Evaluate the log set the way `jj log` does while keeping the resolved expression the topology passes need (find the jj-lib 0.46 seam that yields both — `RevsetExpressionEvaluator` vs. `ResolvedRevsetExpression`); apply `within_visibility` to the prioritize expression as the CLI does; witnesses: a sibling-operation `at_operation()` revset that the CLI accepts returns the same rows, and an `at_operation()`-only commit is not reordered by the prioritization. Pin the topology timing on `large-10k` (no regression).

**Non-goals.** Any change to the layout engine (Epic 4) or the graph view (Epic 10).

**Related:** 4.12 (`zanshin_graph_topology`), 9.41 (the topology's CLI command name is `log`).

### Story 9.43: `converge` — resolve divergent changes (jj 0.45) [M] — *product decision pending (Ralph)*
*(Added 2026-10-08, console session — new CLI verb since jj 0.45, surfaced by the 0.46 bump. Whether Zanshin offers it at all is Ralph's call; this entry records what a port means.)*

**Motivation.** `jj converge` (`cli/src/commands/converge.rs` @ v0.46.0) replaces the visible revisions of a DIVERGENT change with one new revision: it groups the revisions of `--revision` (default: the `revsets.converge` setting) by change id, picks one divergent change (the CLI prompts when there are several), applies heuristics to solve author, description and parents, and falls back to prompting when they are inconclusive (`--no-interactive` warns and changes nothing instead). Descendants are rebased onto the solution and local bookmarks on any divergent revision move to it; the solution may carry file conflicts. Divergence is something a GUI shows prominently (commit metadata already flags it, `CommitMeta.divergent`), so a one-click "converge" is a natural follow-up.

**Scope (if taken).** A two-phase verb in the ADR-0003 style, because the GUI replaces the prompts: (1) a read-only query returning the divergent changes in the search space and, per change, the heuristic proposal or the open choices (descriptions to merge, parent candidates, author candidates); (2) `converge(change_id, choices)` that applies the solution with the CLI's rebase/bookmark effects and op description. Pass `--revision` through with `revsets.converge` as the editable default. Re-read the verb at the pinned tag first — it is new and may still move.

**Non-goals.** A Zanshin-specific heuristic; anything the CLI does not do.

### Story 9.44: `file edit`, `file delete` — rewrite a file in any revision without touching the working copy (jj 0.46) [M]
*(Added 2026-10-08, console session — new CLI verbs since jj 0.46, surfaced by the bump.)*

**Motivation.** `jj file edit [-r REV] [--restore-descendants] FILE` (`cli/src/commands/file/edit.rs` @ v0.46.0) opens one file of a mutable revision in the editor — conflicts materialized with the configured marker style — and writes the result back into that revision, rebasing descendants (or, with `--restore-descendants`, keeping their content); a missing file is created. Refusals: a directory ("Path is a directory: …"), a symlink or submodule ("… is not a regular file"), a non-file conflict ("… has a non-file conflict and cannot be edited"), an immutable revision (`check_rewritable`). An unchanged result prints "Nothing changed." and writes no operation; otherwise the op description is `edit file <path> in commit <id>`. `jj file delete [-r REV] [--restore-descendants] FILESETS…` (`file/delete.rs`) removes every matched path from the revision the same way (`delete paths in commit <id>`, "Nothing changed." when the tree stays the same). For a GUI this is "edit/delete this file in that commit" from the commit detail view, without checking the commit out.

**Scope.** `file_edit` takes the NEW file content from the GUI (the editor is replaced, per ADR-0003 — the GUI supplies the text, the backend writes the tree; the read side is the existing `file show` plus conflict materialization), and `file_delete` takes the CLI's filesets; both pass `-r` (default `@`) and `--restore-descendants` through, port every refusal above as a typed error, the "Nothing changed." no-op (house no-op result), the descendant rebase and the op descriptions. Through the usual chain (`.fbs` → `zanshin-jj` → `extern "C"` → `WorkerCommand`).

**Related:** 9.40 (both end in `tx.finish`'s no-change gate), 9.4 (file reads), 9.17 (conflict materialization).

### Story 9.45: `git colocation status | enable | disable` — per workspace (jj 0.46) [M]
*(Added 2026-10-08, console session — surfaced by the 0.46 bump; no Zanshin story covered `jj git colocation` before.)*

**Motivation.** `jj git colocation` (`cli/src/commands/git/colocation.rs` @ v0.46.0) reports whether a workspace is colocated with Git (`status`), converts a non-colocated repo into a colocated one by moving the Git repo out of `.jj` to the workspace root (`enable`), or the reverse (`disable`). Since jj 0.46 all three work on CHILD workspaces too: `status` names the workspace, `enable` creates a Git worktree for a child workspace and `disable` removes it (the 0.46 workspace model, see 9.13 / 9.23). Zanshin's conversions (`convert_colocated` / `convert_import`, Stories 2.12 / 2.13) only create a NEW jj repo from a Git repo; nothing toggles colocation of an existing jj repo, and nothing reports it as a typed status.

**Scope.** Three verbs ported step for step at v0.46.0 — the status as typed data (colocated or not, workspace name, Git dir), `enable` / `disable` with the CLI's refusals ("This command requires a working copy", destination already exists / not empty, Git repo not found) and its Git HEAD handling (set HEAD to the working-copy commit's parent on enable, remove it on disable), for the default AND child workspaces. Witnesses round-trip a repo through enable → disable and check that the CLI reads the result.

**Related:** 9.13 / 9.23 (the 0.46 workspace model), 2.12 / 2.13 conversions (`convert.rs`, which already detects linked worktrees).

### Story 9.46: v0.44 → v0.46 parity audit of the already-ported verbs [M/R]
*(Added 2026-10-08, console session, Ralph — from `deferred-work.md` "Surfaced 2026-10-08": the jj-lib 0.44 → 0.46 bump only covered what the compiler and the gate surfaced.)*

**Motivation.** The CLI parity rule (project-context.md § zanshin-jj) holds against the PINNED tag, and the pin moved to v0.46.0. `git -C ../jj diff --stat v0.44.0 v0.46.0 -- cli/src` changes these sources behind verbs Zanshin already ships: `describe.rs` (+ `description_util.rs`), `log.rs`, `status.rs`, `show.rs`, `evolog.rs`, `interdiff.rs`, `restore.rs`, `absorb.rs`, `file/{show,list,annotate,search,track,untrack}.rs`, `bookmark/list.rs` and `bookmark/mod.rs` (shared by `bookmark create`/`delete`), `git/init.rs` (the source of `convert_colocated` / `convert_import`), `git/clone.rs`, `git/import.rs`, `git/remote/{add,list}.rs`, `operation/{log,show,diff}.rs` (behind `op_log`), `util/snapshot.rs` (behind `Repo::snapshot`), `config/{set,unset,edit,list}.rs`, and the shared `cli_util.rs` (+289 lines: start-up environment, `snapshot_impl`, `finish`, stale recovery — every verb) and `git_util.rs`. Unchanged at the CLI level: `abandon`, `new`, `edit`, `git fetch`, `git remote remove/rename/set-url`. Without an audit a CLI user and a Zanshin user can see different results from the same verb, and the hundreds of `@ v0.44.0` citations in the source no longer say which behavior is current.

**Scope.**
1. Per verb above, read the CLI diff between the tags (plus the shared helpers it calls) and classify every hunk: terminal UX only (no action), observable behavior Zanshin already matches, or a divergence.
2. Port a divergence in this story when it is small and needs no public-API decision; otherwise record it as its own story (and in `sprint-status.yaml`). A public-API decision goes to Ralph.
3. In every function the audit touches, re-point the `@ v0.44.0` citations to v0.46.0 lines; leave untouched code alone.
4. Witnesses for every ported divergence; the audit result itself — per verb: "no change" / "ported (commit)" / "story X" — goes into this story's spec.

**Already done at v0.46.0 (out of scope).** `undo` (9.39), `workspace list` / `workspace root` (2026-10-08), the `config` file targets of `config/mod.rs` (2026-10-08), the colocated-conversion worktree warning (2026-10-08), and what the bump itself ported (per-workspace Git HEAD, `git import` without the HEAD import, the non-colocated conversion's `import_head_commit`, colocation via `open_git_repo_at_workdir`, `ResolvedRevset::evaluate` for `at_operation()`, `untracked_remote_tags()` in `immutable_heads()`). The graph's `at_operation()` gap is 9.42; the no-change gate is 9.40.

**Non-goals.** Verbs Zanshin has not ported yet — they read v0.46.0 when they are ported; new CLI verbs (9.43–9.45).

### MCP exposure (cross-cut with Epic 7)
Each verb optionally gets an MCP tool (extends Epic 7's write-tools 7.4 beyond `describe`/`new`). Per ADR-0003 open questions: decide (a) whether every mutation verb gets an MCP tool immediately or reads + a core subset first, and (b) whether MCP gets the raw `eval_revset` or only named views.

---

## Epic 10: Commit-Graph View (Flutter UI)

> **Granularity:** backlog-level, like Epic 9. Full acceptance criteria are written per story (via `bmad-create-story`) when it is scheduled, after Ralph has answered that story's design questions.
>
> **Tags:**
> - `[docs]`: planning and rule documents only.
> - `[UI]`: Flutter UI under the exception below.
> - `[UI/bridge]`: UI plus the `zanshin_core` public-API exports it consumes.
>
> **Heading markers:**
> - ***NEEDS DESIGN***: the build waits on several of Ralph's answers.
> - ***PLACEHOLDER***: the story is thin on purpose, for one of two reasons. Either the design is not final there (Ralph: the design's dialogs, popups and panels will look different), or its backend is not scheduled. It is refined later.
> - ***EXPERIMENT***: the story's outcome is a decision, not a product feature.
>
> **Scope exception (Ralph, 2026-09-26):** the Flutter UI is Ralph's work (PRD §3.2, `project-context.md`, `CLAUDE.md`). Ralph asked Claude to build this view anyway, because he has never built one and expects it to be faster and less buggy that way. He asked for separately reviewable pieces because not everything is final. Ralph reviews every story, and the rest of the UI stays his. Story 10.0 wrote this exception into the canonical rules (done).
>
> **Re-planned 2026-09-26 (console session, Ralph)** from the HTML design export. The export supersedes the mockup image that the first version of this epic was written from.
>
> **Product decisions 2026-09-27 (Ralph, console session, after using the spike viewer on a real 1.4k-commit repo).** They supersede every mention below of Time, Time+gaps (M1, the view-side gap variant), `optimized` / "Min. crossings", Plain crossings and the branch-off's ±0.28·W exit, including mentions without a dated note of their own (e.g. 10.1's motivation and items 2–3, 10.2 item 5 and its Non-goals, 10.4 item 8). The affected stories carry dated notes.
> 1. **Layout modes:** Free is the default, Compact the only other mode. Time and Time+gaps are dropped ("the rest can go"). Free keeps its day axis in the gutter (10.2 item 9). The design has no Free mode, and its default is Compact (GV:507).
> 2. **Lane order:** `compact` (SPEC §4.7) is the default, greedy the alternative. `optimized` is dropped. This deviates from the design's default, Min. crossings (APP:13). `compact`'s known limits stay recorded (4.11 item 11): in Free it is wider than greedy in about 8 % of the real repo's history, and its work budget binds from about 10k commits. Greedy is the fallback.
> 3. **Label language:** keep what exists for now: labels formatted per locale, English by default as in the design (the viewer's `?lang=de` gives "Heute", "Gestern", …). Whether the app is English-only or translated is open and app-wide; some terms may sound odd in German (deferred-work).
> 4. **Intended deviations from the design.** Ralph wants these viewer decisions kept:
>    - (a) crossing gaps (line hops) are the only option: always on, no Plain, no toggle (10.4 items 4 and 11);
>    - (b) content fades as it scrolls under the sticky gutter (10.2 item 2). The gradient is the design's own Time gutter (GC:57); it now lives in Free's day gutter, which the design does not have;
>    - (c) the current date is sticky: the day at the viewport's top stays pinned in the gutter until the next day's label pushes it out (10.2 item 9);
>    - (d) every edge leaves a card's top at the centre (item 5);
>    - (e) a commit found by go-to-change pulses: a blue ring that expands and fades, three times (added 2026-09-27; 10.6 item 12). The design has no such animation.
>    - (f) a stack toggle never moves a column; the design re-packs the lanes on every toggle (added 2026-09-28; 4.13, 10.17).
> 5. **Edge exits** (recorded only; the spike viewer is not updated). Every edge already enters its child from below at the centre (Ralph noticed it at merge commits), and straight edges and merges already leave the parent's top at the centre. Only branch-offs leave at ±0.28·W, so edges often leave off-centre. Every edge now leaves the top at the centre too. That changes the painter (10.4 item 1) and SPEC §4.5's geometry text; route classes and every layout output stay unchanged (4.11). 10.4 item 1 lists the consequences; prototype defect 8 disappears.
> 6. **10.13's outcome** is these decisions. *(Not Ralph's decision: the story is closed as done on that outcome, Claude's call; its item 6 leaves a Flutter confirmation to Ralph, who can reopen it.)* Still open: Free's constants and buses behind cards (4.11 open question 4), the source of Free's day buckets (4.11 open question 9), the minimap's design (10.16), and the label language. The port scope is decided: only these modes and orders (Ralph: "the rest can go").

> **Design update 2026-09-28 (Ralph, console session; the re-downloaded export at `a399daf`).** The export adds hover callouts and commit stacks. What changed, and what Ralph decided:
> 1. **What the export adds** (cited at `a399daf`):
>    - **a commit callout** beside a hovered card (GV:461-484, :506-511; GC:249-277). After 450 ms it shows the full subject, the description, the change and commit ids, the author, the date, a file and line stats row, and the hint text that replaces the card's tooltip. It flips left near the right edge and grows upwards near the bottom (GV:438-452). It stays closed while the pointer is on the bookmark control, "…" or a "+" (GC:255);
>    - **"…" and the "add bookmark" button appear only on hover,** like the "+" chips (GC:135-136);
>    - **the bookmark popover** opens to the right of the card, or above the control near the right edge (GC:116-117);
>    - **commit stacks:** linear runs collapse into a stack card (GV:227-264, :536-571; GC:227-247) with a hover popover of its members, each of which opens its own commit callout. A click expands the stack, and a bracket beside the expanded run collapses it. A toolbar switch "Group stacks" turns grouping on and off (GV:336-339), and the expanded stacks persist;
>    - **more mock data:** `graph-data.js` now has 36 commits (22 before). 4.11's dated note pins the spike's oracle to the 22-commit sample;
>    - **assets:** an icon set `icons/ui/` (45 SVGs; 8 are not in `app/assets/icons/svg/` yet: abandon, bookmark, bookmark-filled, describe, squash, stack-collapse, stacked-on, working-copy-at), and `rive/` again (the splash wave, not the graph).
> 2. **Decisions:**
>    - (a) **A stack toggle never moves a column** (intended deviation (f), added to decision 4's list above). The design re-packs the lanes on every toggle, so branches jump sideways; Ralph finds that irritating. The columns come from the ungrouped layout with the decided lane order, and the graph may compact vertically (4.13).
>    - (b) **No stats row in the callout.** Ralph: not important for now, maybe never. File counts need a tree diff per commit, and no API provides line counts (10.8). Recorded in deferred-work.
>    - (c) **The design is inspiration, not a 1:1 template.** It keeps small deviations that Ralph leaves unfixed to save tokens. The house rule "Design status" below is amended accordingly.
>    - (d) **Claude's proposals, accepted by Ralph** ("passt so"):
>      - a toggle keeps the stack in place instead of centring the run;
>      - runs of mutable ancestors of @ start expanded;
>      - a run holding the selection does not collapse by itself;
>      - what the user toggled persists per repository;
>      - the stack popover's height is capped, and its list scrolls;
>      - tags and other workspaces' working copies break a run like bookmarks, and conflicts do not;
>      - in Free a stack sits at its newest member's time;
>      - the quick-action fan opens on hover like the bookmark popover;
>      - callouts yield to pans and drags;
>      - VoiceOver gets the description as the card's hint.
>    - (e) **Drag-and-drop later** (Ralph): commit cards and bookmarks will be draggable. The drag itself stays 10.10's, but the hover and callout mechanics are built so it fits in without rework.
> 3. **Stories:** new 4.13 (stacks in the engine) and 10.17 (stacks in the view). Dated notes in 4.10, 4.11, 10.1, 10.3, 10.5, 10.6, 10.7, 10.10, 10.11, 10.12, 10.15 and 10.16, and on PRD FR-GR-1. Prototype defects 17–20 below.
> 4. **Citations.** GV and GC line numbers written before this update refer to the export at `57f259c`; read them with `git show 57f259c:<path>`. From GV:225 on they no longer match the current file, where the stack code was inserted; GC shifts by up to 3 lines. Citations dated 2026-09-28 refer to `a399daf`. The layout code (GV:140-225) is unchanged.

> **Design update 2026-09-30 (Ralph, console session; the re-downloaded export at `e243dd2`).** The export adds a study of hidden history and an animation playground. What changed, and what Ralph decided:
> 1. **What the export adds** (cited at `e243dd2`):
>    - **the gaps study** `Graph Gaps Study.html` (GS:22-31):
>      - three marker families, A dots, B break and C pill, each for the gap on an indirect edge and for the end of history along a Missing parent;
>      - each family dark without counts and light with counts, with @ moved to `mxnztwqp` so that the gold line runs through a gap;
>      - the code is `graph-gaps.jsx` (GG), wired in at GV:144-170 (a gap walk per parent: direct, indirect with its hidden parent `via` and the hidden commits, or missing), GV:243-249 (markers and stubs), GV:366 (the toolbar legend), GV:755-765 (hover and "Show in all()") and GV:881-896; the styles are GC:279-321;
>    - **a hover callout on every gap:**
>      - the dashed edge, its marker and the stub open it;
>      - it names the gap and shows the child, the gap and the ancestors;
>      - it offers a lazy "Count", and "Show in all()", which switches to `all()`, centres the first hidden commit and flashes the hidden ones for 2.4 s (GG:146-180; GV:755-762; GC:311-312);
>    - **a toolbar legend** "N gaps", whose popover explains solid, dashed and end and offers "Show all()" (GG:182-203; GV:366);
>    - **more mock data:** `graph-data.js` has 52 commits (36 before). The 16 new ones are the gap cases Claude asked Claude Design for on 2026-09-30 (deferred-work): a stack beside a gap, a single card between two stacks, a hidden merge that gives one single-parent card two dashed edges, a merge with one visible and one Missing parent, and a fork behind a gap (GD:76-102). The design tweaks gain "Gap marker" and "Show hidden count" (APP:16-17, :2536-2539);
>    - **the design now follows two earlier decisions:** a stack toggle keeps the columns of the expanded layout while they stay valid (GV:220-237; prototype defect 17), and `groupStacks` counts a child behind a gap as a child and requires a Direct parent for members (GV:264-276), as 4.13 does;
>    - **`Animation Show Case.html`** (AS): a playground with sliders for a stack unfolding and folding and for a tree change after an operation.
> 2. **Decisions** (Ralph):
>    - (a) **Marker family B** ("Break", `//`), for gaps and for ends.
>    - (b) **No counts** anywhere: no "N elided", no "Count" link and no count toggle.
>      - This answers 10.4 design question (a).
>      - No count call is needed, so the follow-up story that 4.10's Non-goals and "Backend dependencies" below reserved is not created.
>    - (c) **The spacing rule:** a marker's centre keeps at least 24 px from everything: every card, bend, crossing and junction, and every other marker, stub and label.
>      - It is a `GraphTheme` constant, tunable in the demo host.
>      - The design's own scan already keeps about 24 px from bends and crossings; its fixed positions do not (prototype defect 21).
>    - (d) **Two new stories:**
>      - 10.19 (hidden history: markers, end stubs, the gap callout, the legend, "Show in all()") takes over 10.4 item 5;
>      - 10.20 (graph animations) carries Ralph's values: stacks unfold and fold in 250 ms without stagger; a tree change draws at 1.8 px/ms and fades out over 600 ms with a 16 px blur and a 16 px rise.
>
>      Earlier stories get dated notes that keep the doors open for 10.20, and 10.17 drops its 260 ms fade.
>    - (e) **Claude's proposals, accepted by Ralph:**
>      - a hidden merge gets one marker per edge, grouped on hover;
>      - the end stub takes the design's side slots (GV:246-248) under the spacing rule;
>      - the gap callout opens after 380 ms, and a press on a dashed edge still pans;
>      - "Show in all()" opens the stack that holds the hidden parent;
>      - the flash is static under reduce motion;
>      - every reload with a new operation animates, within a cap on the duration.
> 3. **Ralph's line-behind-card finding is the Time layout's defect 3** (reproduced in the page on 2026-09-30; Compact is clean).
>    - `kx` (13:30) is a parent of the hidden merge `yx` (12:00) under `sr` (13:00), so in Time `kx` sits above `sr`. The indirect branch-off then runs from `kx`'s top down through `sr`'s own card to its bottom.
>    - The product's Free and Compact put every child at least one pitch above each parent (10.1 item 14), so this cannot occur there.
>    - Edges still pass behind other cards in two open cases: blocked merges (prototype defect 2, SPEC §11.4) and buses in Free (SPEC D8, 4.11 open question 4). 10.19's spacing rule treats every card as an obstacle.
> 4. **Stories:** new 10.19 and 10.20. Dated notes in 4.13, 10.1, 10.3, 10.4, 10.5, 10.6, 10.7, 10.12 and 10.17. Prototype defects 21–24 below, dated amendments to defects 3, 4 and 17, and behaviours (iv)–(v).
> 5. **Citations.** GV, GC, GD and APP line numbers dated 2026-09-30 refer to `e243dd2`. New abbreviations: `GG` = `graph-gaps.jsx`, `GS` = `Graph Gaps Study.html`, `AS` = `Animation Show Case.html`.

**Goal.** The app's main view as in the design export. The canvas and the graph:
- commit cards at positions computed from data, several cards per row, on a navy dot-grid canvas:
  - Compact rows are the dependency depth;
  - Time rows are time buckets, with a sticky time gutter *(dropped 2026-09-27: Free, the default, keeps the sticky gutter as a day axis)*;
- rounded orthogonal edges behind the cards:
  - straight, merge, and branch-off with shared buses;
  - dashed indirect edges;
  - crossing hops;
  - the "~ N elided" marker *(2026-09-30: a `//` marker on every dashed edge and a "~ elided" end stub, without counts; 10.19)*;
- the gold lineage of @, and a hover focus path that dims everything outside a card's ancestry;
- two-axis scrolling and pan-by-drag over 10k–100k commits, with exact scrollbars.

Around the graph sit a toolbar, a thin detail panel for the selected commit, a thin bookmark panel, placeholder action popups, and later drag-and-drop. Everything builds on the shipped bridge (`logDefaults`, `show`, `bookmarks`, the mutation verbs, the op-heads watcher) and on backend Stories 4.10–4.12.

**Design input.** The design export lives under `_bmad-output/implementation-artifacts/design/`. The page `JJ Desktop Client.html` loads `data.js`, `graph-data.js`, `tweaks-panel.jsx`, `graph-view.jsx` and `app.jsx`, styled by `styles.css` and `graph.css`. The stories cite the sources by these abbreviations:
- `GV` = `graph-view.jsx`: the layout algorithm, toolbar, card, bookmark control, quick actions, detail frame, bookmark list and workspace;
- `GC` = `graph.css`;
- `GD` = `graph-data.js`: 22 mock commits, with the clock fixed at 2026-09-25T14:00 *(36 since the 2026-09-28 update at `a399daf`; the spike's oracle keeps the 22 of `57f259c`, 4.11's dated note; 52 since the 2026-09-30 update at `e243dd2`)*;
- `APP` = `app.jsx`: the detail body, the describe editor, and the tweak defaults;
- `SC` = `styles.css`: the design tokens.
- *(since 2026-09-30)* `GG` = `graph-gaps.jsx`, which the page now loads too: gap markers, end stubs, the gap callout and the toolbar legend. `GS` = `Graph Gaps Study.html`, `AS` = `Animation Show Case.html`.

Status of the design:
- **Preliminary but close to final** (Ralph, 2026-09-26). *(2026-09-28, Ralph: inspiration, not a 1:1 template; small deviations are expected and stay unfixed in the export. Decision (c) of the design update.)* The earlier mockup lives at `_bmad-output/planning-artifacts/research/commit-graph-mockup-2026-09-26.webp` (untracked). Where it differs from the export, the mockup and everything planned from it are obsolete.
- **The dialogs, popups and panels are not final** and will look different. The design extraction lists them as:
  - the revset dropdown;
  - the bookmark popover;
  - the quick-action fan;
  - the "+" chips' actions;
  - the detail panel with its describe editor;
  - the left side panels (the bookmark list);
  - the Projects dialog.

  Their stories are thin: 10.15, 10.8, 10.14 and 10.7's dropdown. Whether the two panels really count is 10.8 design question (a).

  *(2026-09-28: the hover callouts of the design update are interaction, not decoration, so their mechanism is built for real: the commit callout (10.6) and the stack popover (10.17). The bookmark popover stays a placeholder apart from its hover opening and its position (10.15).)*
- **The tweaks panel** (`tweaks-panel.jsx`, APP:7-16, :2510-2539) is a design tool, not a product surface. The tweaks that change the graph become view options with the design's defaults (below).
- **Only the visuals and interactions are the reference.** The prototype renders every card and edge as DOM and runs a quadratic layout on the UI thread (about 2 s at 10k commits). Its algorithmic costs and its bugs (below) are not part of the reference.

**The layout model.** The design does not draw `jj log`'s lane graph, which puts one commit on each row. Instead it lays commits out in rows shared by several commits (GV:140-225):
- **Compact:** row = the longest-path depth. Row 0 is the root at the bottom, and the newest commits are at the top.
- **Time:** rows are grouped into time buckets: a ladder from 10m to 12h, then calendar days. Independent commits in one bucket share a row.
- **Lanes:** greedy interval packing with a first-parent continuation and a one-row buffer, optionally permuted to minimise crossings ("Lane order").
- **Edges:** every parent edge is routed as one orthogonal polyline (straight, merge or branch-off), with rounded corners and crossing hops.

That algorithm belongs to the backend:
- **The A/B spike** `spikes/graph-layout-ab` (`SPEC.md`):
  - it made the algorithm scalable and deterministic, and it fixes several of the prototype's defects (below);
  - it implements three modes:
    - `compact`;
    - `time`, with a topological clamp (SPEC D1);
    - `free`: y from compressed commit time, each child at least one pitch above its parents (SPEC §4.2, D8; the constants are provisional);
  - it settled where 4.11 runs: in Dart, on `zanshin_core`'s worker isolate (Ralph, 2026-09-26; spike README "Recommendation" and "Review 2026-09-26"). Rust keeps supplying the jj data.
- Story 4.11 ports the spike's Dart implementation into the worker isolate; Story 4.10 supplies the topology, and Story 4.12 its wire and the lazy Dart view.

**The view never computes rows, columns, route shapes, buckets, elided counts or a free y.** It consumes an abstract `GraphLayout` (10.1) and only maps it to pixels:
- per node: key, column, row in units of 1/U pitch, view facts and lazy content. U = `unit` is 1 in Compact and Time and 16 in `free` (SPEC §3);
- per edge: child, parent, kind (direct | indirect) and shape (straight | merge | branch-off);
- plus the mode, the time buckets, the elided markers, @ and the counts.

Rows, lanes and columns do not depend on card width or height. This was verified on 3000 random layouts: the optimiser's width term is the same for every permutation (SPEC §0, D6). So a layout is requested once per operation and never for a resize.

**Fixed rows or free y: the Time experiment** *(decided 2026-09-27: free y. Free is the default and Compact the other mode; the view-side gap variant is dropped, so `PerNodeTops` serves hand-made fixtures only)*. The design is row-based in both modes, with a uniform pitch, so its spacing is ordinal. Ralph may instead want the vertical spacing to follow elapsed time. The pixel mapping is therefore split in two:
- `GraphMetrics` maps columns to x. It covers the card width (160–400), the lane gap (56), the padding (56) and the gutter (88, in Time, and in Free if Free ships with 10.2 item 9's day axis).
- A `VerticalLayout` maps nodes to y.
  - `UniformRows` maps the layout's rows: top = pad + (rows − U − row)·(H + gapY)/U. With U = 1 that is the design (GV:202). With the engine's `free` output (U = 16) it is the free layout, with no y computed in the view.
  - `PerNodeTops` holds arbitrary per-node tops. It serves the one view-side variant, time-sized gaps between Time buckets (prefix sums over the buckets, SPEC §0), and hand-made fixtures.

Everything vertical reads the `VerticalLayout`: cards, edges, buses, the gutter, guides, reveal, anchoring, hit testing and the extents. The visible set comes from a y-sorted index with binary search, not from row arithmetic. A free layout is therefore a different layout record, not a different viewport.

Every time-based variant needs every commit's timestamp before the first frame. That includes the design's fixed Time rows. *(2026-09-27: with Free the default, the default layout needs them; 4.10 open question 1 weighs more.)* It is a dependency on 4.10 (the index holds no timestamps; its re-plan carries them in the topology call on request) and on 4.11 (the buckets and the free y).

**How it is built** (research §1–§5; the POC).
- **Viewport.** A `TwoDimensionalScrollView` with a custom `RenderTwoDimensionalViewport`. The viewport paints the background, the edges and the gutter itself. Cards are lazily built widgets whose body is a `RenderBox` with text slots.
- **Geometry from data only.** No widget is measured. Extents and scrollbars are exact before the first card exists; the design computes them the same way (GV:219-224).
- **Several cards per row, per-node y.**
  - Visible cards come from the y-sorted index.
  - Visible edges come from an interval index over each edge's vertical extent.
  - Crossing hops are computed per visible window.
- **Accessors only.** Painters and cards read `GraphLayout` through accessors. 10.12 can then swap the recorded source for 4.11's layout result plus 4.12's lazy topology view without touching 10.1–10.4.
- **Pitfalls.** Every research §5 pitfall is a scope item of the story it belongs to, marked "(research §5)". One is moot: colouring lines by the edge that opened them (§5 "Linienfarbe"). The design has one gray plus the gold lineage of @.

**Backend dependencies** (restated in 10.12):
- **4.10:**
  - the index-only topology and view facts for the whole revset before the first paint, including each node's real parent count (index-only, 4.10 item 1);
  - the edge kinds as jj facts: direct, indirect and Missing. A Missing edge is the elided stub (10.4). Its count N, if 10.4 design question (a) keeps it, is not a topology field (4.10 Non-goals): it depends on the revset and needs an index walk per Missing parent, so it would come from a separate op-pinned count call for the visible nodes, owned by a follow-up story created only then *(decided 2026-09-30: no counts, the design update's decision (b); no count call and no follow-up story. The stub is 10.19's)*;
  - content (subject, author, time, empty, conflict), loaded lazily by commit id at the returned operation;
  - `|all()|` for the "shown / total" counter;
  - the operation id.
- **4.11:**
  - the layout in all three modes (compact, time, free) behind a mode enum, as the spike implements them. 10.13 decides which modes the product exposes *(decided 2026-09-27: `free`, the default, and `compact`; 4.11's dated note proposes porting only these)*;
  - rows in units of 1/U, with `unit` and `rows` (SPEC §3), plus columns, route shapes including the blocked rule, and buckets. That is all: elided counts are not part of the layout, and Missing edges are not in its output (SPEC §0, §3, D2);
  - independent of card width and height;
  - with the prototype's layout defects fixed (below). The spike already fixes defects 3, 5 and 6 and the costs of 16;
  - with a real source for the design's hand-set `priority` (a stand-in in the spike, SPEC §11.2), and a lane order that stays stable across reloads (SPEC §11.5; since 2026-09-27 `compact`'s §11.6, 4.11 open question 8);
  - the dated amendments of FR-GR-1 / FR-GR-2 (2026-09-26), which described the `jj log` lane model.
- **Time and free modes:**
  - every node's timestamp before layout, committer or author (SPEC §11.3);
  - for Time, also "now"; free mode never reads "now" (SPEC §4.2). *(2026-09-27: Time is dropped, so no layout reads "now", and Free, the default, needs every timestamp.)*

  4.10's re-plan (2026-09-26) carries them in the topology call on request (`with_timestamps`), loaded per call; a commit-id → timestamp cache is its open question 1.

**Design tweaks that matter** (APP:7-16; the defaults are the design's):
- Bookmark labels: Always (legend pill) | On hover (button only) → 10.3.
- Crossings: Bridge gap | Plain → 10.4. *(Decided 2026-09-27, Ralph: Bridge gap only, always on; no Plain and no option. An intended deviation.)*
- Hover: focus path (on) → 10.6.
- Lane order: Min. crossings | Greedy → an option of the layout request (10.5). 4.11 computes it (the spike's `optimized` | `greedy`, and since 2026-09-26 the Dart-only `compact`, SPEC §4.7). Which orders ship and which is the default is 4.11 open question 8; the spike recommends `compact` with greedy as the fallback, and dropping `optimized`, once Ralph has looked at it in the viewer. *(Decided 2026-09-27, Ralph, after looking at it in the viewer: `compact` is the default and greedy the alternative; `optimized` ("Min. crossings") is dropped. The design's default, Min. crossings (APP:13), is thereby replaced. The control's label is open, because "Compact" collides with the Compact layout (10.7 design question (f)).)*
- Show changed files (on) → 10.8.
- Diff mode (Inline) → the Epic 5 diff follow-up, together with the design's review workflow (deferred-work).
- Density and theme are app-wide and stay Ralph's.

The demo host exposes every graph option. Which of them become user settings is 10.7's design question (f).

**Prototype defects that no story copies.** Each was verified in the page; the owning story is in brackets.
1. **Re-centring on @ misfires** [10.5] (GV:531-538):
   - a revset or layout switch re-centres on @ one relayout late;
   - the first relayout of any kind after load (Card width, Detailed, Lane order) jumps to @;
   - after a double-click `jj edit`, the next relayout scrolls to the old @;
   - a hidden-bookmark pick reveals its target in the relayout it causes (GV:582), but the switch re-arms the @ re-centre (GV:538), so the next relayout of any kind jumps to @.
2. **Blocked merges are routed behind cards** [4.11; reported by 10.4 item 10]. A blocked merge is re-routed as a branch-off and runs up the child's column behind that column's cards, collinear with their chain. Its reservation also pushes the continuation off its lane (GV:52-69, :188-206). The spike keeps this (SPEC D9) and leaves it to Ralph (SPEC §11.4). The design sample has none, but the spike's synthetic inputs have many (229 on `synth-10k`, compact, greedy), so the route invariant is a counted report until 4.11 fixes it.
3. **Time rows break when a child is older than its parent** [4.11; the spike's clamp fixes it (SPEC D1); checked by 10.1 item 14] (GV:169) *(moot for the product since 2026-09-27: Time is dropped; Free clamps its own time, SPEC §4.2)*:
   - across buckets, the parent is drawn above the child;
   - inside one bucket, both land in the same cell and overlap;
   - *(2026-09-30, Ralph's finding in the gaps study; the design update's item 3)* an edge to a parent drawn above its child runs down through the child's own card, because every route climbs from the parent's top to the child's bottom (GV:52-69 at `e243dd2`).
4. **Elided counts are costly and differ from jj** [4.10 supplies the Missing edges; N, if 10.4 design (a) keeps it, a follow-up count call] (GV:141-158):
   - a DFS per parent counts every hidden ancestor down to the root, O(h) per Missing parent;
   - it drops the hidden part of mixed parents and keeps transitive indirect edges;
   - jj's Missing semantics differ: its walk is bounded, and it keeps Missing edges next to Indirect ones.

   The spike takes the edges from jj and leaves the counts out of the layout (SPEC §0, D2). So the stub comes from 4.10's Missing edges; N, if 10.4 (a) keeps it, from a separate count call (4.10 Non-goals).

   *(2026-09-30: counts are dropped, the design update's decision (b). The new gap walk (GV:144-170 at `e243dd2`) also names each indirect edge's hidden parent (`via`) and the hidden commits between; jj reports neither. 10.19 groups a hidden merge by the real parent count instead, and derives the hidden commits from the two layouts after a switch to `all()`.)*
5. **`rowOf` recursion** overflows the stack at about 8k depth with head-first input (GV:174) [4.11; the spike loops instead (SPEC §4.2)].
6. **Duplicate parents** produce a dashed and a solid edge to the same parent, with colliding edge keys (GV:154, :640) [4.11: jj does yield repeated targets (a Direct and an Indirect edge to one parent, seen on a real repo), and 4.11's input builder keeps one layout edge per target (its Scope 5; SPEC §2 amended, V3 stays a validation); 10.1 item 14; 10.4 item 9].
7. **An invisible elided stub**: the stub is drawn over the node's own incoming edge at the card centre (GV:643-645) [10.4 design (b)].
8. **The bookmark legend pill covers branch exits**: it sits on the top border over rightward branch-off exits (GC:97, :105 vs GV:63). The code comment at GV:311-315 intended the bottom border [10.3 design (b)]. *(2026-09-27: it disappears with the top-centre exit, product decision 5: the pill's left end sits at least 24 px right of the card's centre.)*
9. **A stale selection**: it survives a revset that hides the commit, so the panel stays open for a commit that is not on the canvas (GV:578) [10.5 item 7].
10. **A hidden-bookmark pick** permanently rewrites the persisted revset preference (GV:504, :580) [10.14 design (a)].
11. **Esc is global**: the graph's Esc handler is a window-level keydown listener (GV:541-548). So the Esc that closes the Projects dialog (APP:2034) also clears the graph selection [10.6 item 5].
12. **Detail panel defects** [10.8]:
    - a "behind" bookmark reads "local" (GV:467);
    - the root shows a fake parent "c3d4e5f" (APP:765);
    - only the first parent is shown (APP:761-766);
    - the action row is inert, and it shows on immutable commits while the header hides Edit there (APP:854-859);
    - every commit shows the same sample diff (APP:865).
13. **The describe editor saves nothing**: "Done editing" persists nothing, and its hint still says `jj edit … Working copy moved here` (APP:1335-1363, :1345-1348) [10.15].
14. **The subject is dimmed for an empty change**, not for an empty description (GV:407) [10.3 design (a)].
15. **The mock's default-revset flags are wrong for `wq`**. jj's default revset shows 13 of the 22 commits with the elided stub under `vr`, not 14 (GD:1-2, :17) [10.1 item 13].
16. **Nothing is virtualised, and the algorithms do not scale** (GV:71-138) [10.1, 10.4; 4.11]:
    - every card and edge is a DOM node;
    - crossings are found all-pairs, O(E²);
    - the lane optimiser is factorial below 9 lanes and hill-climbing above, and it is global.

    The spike's phases are O((n+E) log n), and its optimiser is budgeted (SPEC §5).

Added with the design update of 2026-09-28 (cited at `a399daf`):

17. **Lanes re-pack on every stack toggle** (GV:651-652), so whole branches jump sideways [4.13; decision (a), deviation (f)]. *(2026-09-30: the export at `e243dd2` keeps the columns of the expanded layout while they stay valid and re-packs only otherwise (GV:220-237); 4.13's I7 keeps them always.)*
18. **The expanded stacks persist in one global list** (`zanshin.graph.expanded`, GV:640), not per repository, although their keys are change ids [10.17].
19. **The stack popover grows without bound.** It lists every member and sizes its flip by 60 + 34 px per member (GV:543, :558) [10.17].
20. **A collapse can hide the selected commit** and leave its panel open, like defect 9: the toggle keeps `selectedId` (GV:654-660) [10.17, 10.5].

Added with the design update of 2026-09-30 (cited at `e243dd2`):

21. **Gap markers crowd cards and bends at fixed positions** [10.19; decision (c)]:
    - the fallback sits 11 px under the card (GG:45-46);
    - a hidden merge's shared marker sits 10 px under the card, on the merge bus's bend (GG:53-57);
    - an end stub's cut sits 10–15 px under the card (GG:106-110).

    The scan itself keeps about 24 px from bends and crossings and 21–27 px from its own cards (GG:22, :30, :39).
22. **Marker placement knows only the edge's own two cards** (GG:22). Nothing keeps a marker off another card, e.g. in Free, where a bus can pass behind one (SPEC D8) [10.19].
23. **Marker placement is all-pairs:** for every dashed edge it scans every segment of every other edge, O(D·E) (GG:26-36) [10.19: whole-layout indexes].
24. **The mock hides commits that jj's `builtin_log()` shows** [10.1 item 13; 10.19 item 9]:
    - that revset holds every mutable commit and every parent of one (`ancestors(immutable_heads().., 2)`);
    - the mock hides the mutable `vw`, `lm`, `nt`, `om` and `yx`, and `ro`, a parent of the mutable merge `wl` (GD:80-81, :91, :95, :99-100).

    Its gaps therefore stand for a narrower revset such as `mine()`. Under jj's default revset, gaps occur only in immutable history.

**Prototype behaviours that are design questions, not defects** (the owning story asks):
- (i) Crossings between edges that share a node are neither bridged nor counted (GV:87) [10.4 design (d)]. The spike's optimiser counts them (SPEC D5).
- (ii) Opening the detail panel keeps the raw scroll offset [10.8 design (e)].
- (iii) A click on empty canvas never clears the selection; it only starts a pan (GV:563-569) [10.6 design (b)].
- (iv) *(2026-09-30)* The gap callout opens without delay (GV:755 at `e243dd2`), so it flashes whenever the pointer crosses a dashed edge [decided in 10.19: after 380 ms].
- (v) *(2026-09-30)* A press on a dashed edge's hover band or on a marker never starts a pan (GV:791) [decided in 10.19: it pans, and only the callout blocks a pan].

**House rules for every Epic 10 story.**
- **Code and tests.** Code goes in `app/lib/src/features/graph/`, tests in `app/test/features/graph/` (mirroring). The POC (`app/lib/src/features/graph_poc/`, `app/lib/main4.dart`) is reference only.
- **Bridge imports.** The app imports only `package:zanshin_core/zanshin_core.dart`. That library exports none of the handle, show, bookmark, mutation, exception or graph types today (`zanshin_core.dart:9-33`). Each story adds the types it consumes to the `show` list; that is what the `[UI/bridge]` tag means.
- **Material.** Material types come from `package:material_ui` only; its `ThemeMode` is not Flutter's.
- **Visuals.** Designed visuals are a `RenderBox` with text slots (the `splash_card_render.dart` pattern), not nested `Column`/`Row` trees.
- **Theme.** Colours and sizes live in a `GraphTheme` `ThemeExtension`, whose dark and light values come from the design tokens (GC:4-5, SC:9-56, SC:2363-2376). `GraphTheme.of(context)` falls back to built-in defaults and never force-unwraps.
- **Layout data.** The view never lays out the graph. Until 10.12, everything runs on recorded layouts from the spike's reference implementation (10.1 item 13). Every recording passes 10.1's hard invariants. 10.4's route invariant is a counted report, not a gate, until SPEC §11.4 is answered and 4.11 fixes the blocked-merge routing.
- **Scroll precedence.** One rule, defined in 10.5 item 6 and used by 10.1, 10.7, 10.8 and 10.14. An explicit reveal (a bookmark pick, locate @, go-to-change) beats the re-centre on @ after a revset or layout switch, which beats the anchor. The anchor is the fallback when the target is absent. It is also the rule for reloads, card-size changes and side panels, unless 10.8 design question (e) keeps the raw offset for panels.
- **Ports.** The view model (10.5) declares the ports the view uses: the layout source (`GraphSource`) and the actions runner (`GraphActions`). A story whose real implementation has not landed yet wires a fake: 10.6 and 10.8 before 10.9, and everything before 10.12.
- **Tests.**
  - Scroll-physics tests run under `TargetPlatformVariant.only(TargetPlatform.macOS)`.
  - There are no golden tests, because the repo has none. Ralph reviews visuals in 10.1's demo host.
  - Real-cdylib widget tests wrap worker and watcher I/O in `tester.runAsync`.
  - App tests never call a jj config verb for real. The `test-flutter` task does not pin `XDG_CONFIG_HOME` (`Makefile.toml:109-111`).
- **Gate and definition of done.**
  - A story is done when `cargo make test` passes: `flutter test`, `dart analyze --fatal-infos`, format, and the rest.
  - The 3 splash-card failures are fixed, so the earlier "adds no new failure" workaround is gone.
  - The coverage ratchet is Rust-only and does not measure these lines. Each story's named witnesses are the only safety net.
- **Backend boundary.** The UI never composes jj operations (ADR-0003). It pre-fills every parameter the shipped API takes from the effective config (Story 4.9) and passes it explicitly. CLI parameters that the API lacks are backend gaps, not UI work.
- **Design status.** Each story separates what the design fixes from what Ralph still decides:
  - FINAL items cite the design by file:line;
  - NEEDS DESIGN items are phrased as concrete questions, and they are answered before the story is built, never guessed;
  - a prototype defect is never FINAL, and a prototype behaviour listed above is a question, not a rule.
  - *Amended 2026-09-28 (Ralph; decision (c) of the design update):* the export is inspiration, not a 1:1 template, and it keeps small deviations that Ralph leaves unfixed to save tokens. FINAL therefore means the intended direction, not pixel or behaviour exactness. For a small gap or inconsistency Claude writes a proposed default, marked as Claude's proposal, which Ralph can overrule at review. NEEDS DESIGN questions are kept for choices that change architecture or scope. A decision recorded in this epic wins over the export.

**Sequencing.**
- 10.0 (the scope-exception note) is done.
- 10.1 comes first: the viewport, the `GraphLayout` contract, `VerticalLayout`, the recorded layouts from the spike, and the demo host.
- 10.2 (background and gutter), 10.3 (cards) and 10.4 (edges) run in parallel on recorded layouts.
- 10.5 (the view model and its ports) can land any time after 10.1.
- 10.13 (the Time-layout lab) follows 10.1, 10.4 and the spike's stages 2–3 (dumper and reference implementation). It uses 10.2 and 10.3 if they have landed. It does not gate 4.11, which carries all three modes; its outcome picks the modes the product exposes. *(2026-09-27: the outcome is picked; 4.11's dated note proposes porting only `free` and `compact`.)* The throwaway viewer inside the spike was built on 2026-09-26, and Ralph currently leans to Free (tentative; 10.13's status note). *Outcome decided 2026-09-27 in the spike viewer (Free by default, plus Compact); a Flutter lab is built only if Ralph asks for one (10.13 item 6).*
- 10.6 (selection, hover focus, locate @) follows 10.3 and 10.4.
- 10.7 (toolbar) follows 10.2, 10.3, 10.5 and 10.6.
- 10.8 (thin detail panel) follows 10.5 and 10.6.
- 10.9 (the action runner) follows 10.3 and 10.5. Until it lands, 10.6's double-click and 10.8's action row call the fake `GraphActions` port.
- 10.15 (placeholder popups) follows 10.8 and 10.9.
- 10.14 (thin bookmark panel) follows 10.5, 10.6 and 10.7. Its full row set needs backend 9.29.
- 10.11 (content paging) follows 10.3 and 10.5 on the fake port.
- 10.12 (real data) follows Stories 4.10, 4.11 and 4.12.
- 10.16 (minimap) follows 10.1, 10.4, 10.5 and 10.6. On its recommended raster path (an app-side `Isolate.run` from the layout arrays, its design question (f)) it needs no backend story and runs on recorded layouts.
- 10.17 (commit stacks, added 2026-09-28) follows 10.1, 10.3, 10.5 and 10.6, on the stack recordings of 4.13's spike step (its item 6). 10.7's "Group stacks" switch can land with it. Real stacks come with 10.12 plus 4.13.
- 10.18 (AI stack titles, added 2026-09-28) is an idea Ralph has not decided on. If it is built, it follows 10.17 and 10.11.
- 10.19 (hidden history, added 2026-09-30) follows 10.4, 10.5, 10.6 and 10.7, on recordings of the `e243dd2` sample (10.1 item 13). Real gaps come with 10.12.
- 10.20 (graph animations, added 2026-09-30) follows 10.1, 10.3, 10.4, 10.5 and 10.17. Real triggers come with 10.9 and 10.12.
- 10.10 (drag-and-drop) comes last. It is a placeholder that needs backend 9.31 and 9.16.

**What changed in the re-plan, and why** (story numbers kept where the topic still fits):
- **10.1–10.7 keep their topics.** Their content now follows the design: several cards per row, routed edges, the design's toolbar. 10.1's contract takes the spike's output format (rows in 1/U units), so the engine's free layout needs no view-side computation.
- **10.8 and 10.14 are thin by default.** The design extraction lists both panels among the design's not-final dialogs and popups. The design's review workflow (review meter, Viewed state, auto-advance, Inline/Split) reviews diffs that do not exist before Epic 5, so it moves to the Epic 5 follow-up.
- **10.9 "Action dialogs" becomes the action runner.** The design has no dialogs. Its verbs are triggered from cards, the panel and popups, so the story is the shared pipeline that runs them.
- **10.12 adopts the backend layout end to end** (4.10 + 4.11 + 4.12). The landing lanes and segment colours it was written for belong to the `jj log` lane model the view no longer draws.
- **Three stories are new:**
  - 10.13, the Time-layout lab (Ralph's experiment). It compares the engine's modes and one view-side gap variant; it computes no layout itself;
  - 10.14, the bookmark panel (a designed surface with its own data source);
  - 10.15, the placeholder popups. They are not final by Ralph's decision, and they are split from 10.9 so that the runner stays real.

### Story 10.0: Record the Epic 10 scope exception in the canonical rules [docs]
*(Added 2026-09-26, Ralph — console session on the commit-graph view; research: `_bmad-output/planning-artifacts/research/technical-commit-graph-virtualization-research-2026-09-26.md`.)*

> **Delivered (2026-09-26, console session):** the dated note "Exception 2026-09-26 (Ralph): Epic 10, the commit-graph view (epics.md), is built by Claude at Ralph's request; the rest of the Flutter UI stays Ralph's" was added at every site of item 1: `CLAUDE.md` (the "Flutter UI is out of scope" sentence); `project-context.md` `scope_reminder`, the Flutter-toolchain bullet ("Ralph's separate work"), the coverage rationale (Epic 10's Dart lines stay unmeasured) and the "NEVER write Flutter UI code" rule; `prd.md` frontmatter `scopeBoundary` (incl. the view's own VoiceOver semantics), §1 (a pointer in the intro sentence + the note after "Ralph's own work"), §3.1 (the "No widgets, no UI" bullet), §3.2 ("No Flutter widgets…" and "No accessibility work", which notes Epic 10's VoiceOver semantics); and § UX Design Requirements above. The general rule stays at every site. The memory note was already updated.

**Motivation.** Every build agent reads `CLAUDE.md` and `project-context.md` first. Both declare the Flutter UI out of scope, and `project-context.md:614` says "NEVER write Flutter UI code in this scope". Without a dated exception, every Epic 10 build refuses the work or quietly shrinks it. Nothing else in Epic 10 owns this edit.

**Scope.**
1. Add one dated note at every site that forbids UI work: "Exception 2026-09-26 (Ralph): Epic 10, the commit-graph view, is built by Claude at Ralph's request; the rest of the Flutter UI stays Ralph's". The sites:
   - `CLAUDE.md:5`;
   - `project-context.md:15` (`scope_reminder`), `:29`, `:307` (coverage rationale: Epic 10's Dart lines stay unmeasured) and `:614` (the NEVER rule);
   - `prd.md`:
     - the frontmatter `scopeBoundary` (`:56-60`);
     - §1 (`:74`, `:82`);
     - §3.1 (`:150`);
     - §3.2 (`:154`, and `:156` "No accessibility work", because Epic 10 adds VoiceOver semantics to its own view);
   - `epics.md:236` (§ UX Design Requirements);
   - Claude's auto-memory note `feedback-scope-bridge-is-claudes-ui-is-ralphs.md` lives outside the repo; it already carries the exception (updated 2026-09-26).

   The general rule stays everywhere. Only the exception is added.

**Non-goals.** No code. No other rule changes. (The mockup image is already in the repo: `_bmad-output/planning-artifacts/research/commit-graph-mockup-2026-09-26.webp`, copied 2026-09-26.)

**Witness.** `grep -n "Epic 10"` hits every site listed in item 1.

### Story 10.1: Graph viewport — two-axis virtualized canvas over positioned nodes, extents from data, pan-by-drag [UI]
*(Added 2026-09-26, Ralph — console session on the commit-graph view; re-authored 2026-09-26 from the HTML design export; research: `_bmad-output/planning-artifacts/research/technical-commit-graph-virtualization-research-2026-09-26.md`.)*

> **Design update 2026-09-28 (the Epic 10 header):**
> - **Stacks** (10.17, 4.13). `GraphLayout` (item 2) gains accessors for stack nodes (a collapsed run as one node, with its members) and for expanded runs (their members, for the bracket); 10.17 adds them. The recordings (item 13) gain stack recordings from the spike's Dart (4.13 item 6), on the 36-commit design sample and on the scale inputs. The invariant checker (item 14) gains 4.13's column invariant I7: a stack recording's columns equal those of its ungrouped recording.
> - **A stack toggle is a relayout under the same revset and mode,** so item 10's anchor applies. The anchor node is the member that shares the toggled stack's place: the oldest in `compact`, the newest in `free` (10.17 item 4; 10.5).
> - **Callouts** (10.6) are widgets above the viewport, anchored to their card like 10.15's popups. The card stays pinned (item 9) while its callout is open. Item 6's paint hooks are unchanged.

> **Design update 2026-09-30 (the Epic 10 header):**
> - **Recordings** (item 13):
>   - the design sample at `e243dd2` (52 commits) joins (a) in both revsets, with the design's flags, for 10.19's gap cases. Those flags stand in for a narrower revset (prototype defect 24);
>   - counts are dropped (decision (b)), so records carry no N: item 13's "A count N exists only for the design sample" goes, and the Missing edges stay;
>   - the spike's `node tools/design-input.mjs --rev e243dd2` converts this export into `inputs/design-e243dd2-{default,all}.json` (fixed 2026-09-30; without `--rev` the tool reads the pinned `57f259c`).
> - **Transitions for 10.20** (a constraint; no animation code here):
>   - the viewport must be able to keep nodes of the previous layout mounted for the length of a transition, and paint them on an overlay layer with opacity, blur and an offset;
>   - during a transition its visible set is the union of both layouts;
>   - a card's y is a paint parameter per key, so a card can slide without a rebuild.
>
>   Keys already survive rewrites (item 2's change-id rule).

**Motivation.** The design places each card at a pixel position computed from data alone (GV:198-224):
- x comes from the node's column, y from its row;
- several cards share a row;
- the canvas scrolls on both axes, and a drag on empty canvas pans it (GV:560-576).

The prototype renders every card and edge as DOM, which is fine for 22 commits, but `all()` can reach 10k–100k. `ListView` cannot do this: its extents are estimates, and nested inside a horizontal scroll view it lets the trackpad lock one axis (research §1–§2).

The POC showed that a `TwoDimensionalScrollView` with a custom `RenderTwoDimensionalViewport` works. It lives in `app/lib/src/features/graph_poc/`, with entry point `app/lib/main4.dart` and test `app/test/features/graph_poc/commit_graph_view_test.dart`. It mounts 13 cards at 800×600 over 100 000 rows, both extents are exact before any card is built, and clicks land on the right card. But:
- it assumes one card per row and finds the visible rows by arithmetic on the row index;
- the design puts several cards on a row;
- the engine's `free` mode (spike SPEC §4.2) puts every node at its own y, which 10.13 evaluates;
- it leaves out the research §5 pitfalls.

This story makes the production viewport that every other Epic 10 story plugs into.

**Scope.**
1. **Home and demo host.** Production code goes in `app/lib/src/features/graph/`, tests in `app/test/features/graph/`. The POC stays untouched.
   - Add one fake-data demo host for Ralph's visual review of every Epic 10 story. It alone registers `GraphTheme` (item 12). It exposes every `GraphViewOptions` field: the design's graph tweaks, dark/light, the fixture, and later 10.13's lab *(2026-09-27: 10.13's outcome is decided; a lab joins the host only if Ralph asks for a Flutter confirmation)*.
   - Which `main*.dart` hosts it is Ralph's call, given his note to clean those files up.
2. **The `GraphLayout` contract.** An app-side, abstract, immutable interface, one per layout. Painters and cards read it **only through accessors**, so 10.12 swaps just the backing store.
   - **Mode and units** (the spike's output fields, SPEC §3):
     - `mode`: compact | time | free *(2026-09-27: the product ships `free`, the default, and `compact`)*;
     - `unit` (U): rows are in units of 1/U pitch; 1 in compact and time, 16 in free;
     - `rows`: max row + U;
     - `colCount`.
   - **Nodes:**
     - `nodeCount`, `keyOf(i)`, `indexOfKey(key)` (null when absent);
     - `colOf(i)`, `rowOf(i)` (row 0 = the oldest, at the bottom);
     - `timestampOf(i)`, nullable; present when the source carries it (Time, free, the lab);
     - view facts, always present;
     - content, nullable until loaded (10.11).

     10.3 defines the fields of both. The view facts include:
     - the bookmark refs as an app-side `GraphRef`: name, remote, synced and conflicted, plus tracked and ahead/behind once 9.29 lands. 10.12 maps 4.12's types onto it, so it is never a wire type such as today's `GraphCommitRef`;
     - `parentCountOf(i)`: the commit's real parent count, Missing parents included. It drives the merge glyph (10.3) and the merge tag (10.8), as the design's `isMerge` does (GD:56). It is not the edge count, because Missing edges are not layout edges (SPEC §3).
   - **Edges:** `edgeCount`, `childOf(e)`, `parentOf(e)`, `kindOf(e)` (direct | indirect), `shapeOf(e)` (straight | merge | branch-off), plus CSR parent and child ranges per node.
   - **Also:**
     - `elidedOf(i)` (10.4): whether the node has a Missing parent, plus the count N where the source carries one. The flag comes from 4.10's topology (its Missing edges, on 4.12's wire), not from the layout (SPEC §0); N has no source until 10.4 design question (a) keeps it (then a follow-up count call, 4.10 Non-goals);
     - the time buckets: kind, value, first and last row (10.2);
     - `workingCopyIndex` (nullable);
     - `shownCount`, and `totalCount`, which is nullable until the source provides `|all()|`;
     - `operationId`, nullable until 4.10.
   - Consumer stories may add accessors, but never backing objects.
   - **Row key.** A node's key is `changeId`, or `commitId` when the commit is hidden or divergent (divergent changes share a change id, `graph.dart:229`). The key survives `describe`, which rewrites the commit id but keeps the change id, and it survives new heads.
   - **No synthetic keys.** The design has no synthetic elided nodes: dashed indirect edges replace them. So the old synthetic-row key rule is gone.
   - **What never comes from the view:** rows, columns, route shapes, buckets, elided data and every y the engine decides. They come from the source: item 13 now, then via 10.12 the layout from 4.11 and the Missing edges from 4.10's topology (N, if kept, from a follow-up count call).
3. **`GraphMetrics`: pixels in x.**
   - The sizes (GV:6): W = card width, 160–400, default 240; H = 62 with Detailed cards and 40 without; gapX 56, gapY 48, pad 56; the gutter 88, in Time (and in Free with 10.2 item 9's day axis; since 2026-09-27 in Free only, the default); elide 44.
   - Corner radius 10 (GV:217, GC:72).
   - x(i) = offX + pad + col·(W + gapX), and cx = x + W/2. offX is 88 wherever the gutter is (Time, and Free per 10.2 item 9) and 0 otherwise.
   - Width = offX + 2·pad + colCount·(W + gapX) − gapX (GV:221).
   - W and H never change rows, lanes or columns (verified, optimiser included; SPEC D6). A change is therefore an O(n) remap, never a new layout request.
4. **`VerticalLayout`: pixels in y, and the visible query.**
   - The interface offers `top(i)`, `contentHeight`, `bottomExtra` and a query for the nodes in a y range.
   - This story ships two implementations:
     - **`UniformRows`** maps the layout's rows:
       - top(i) = pad + (rows − U − rowOf(i))·(H + gapY)/U;
       - height = 2·pad + bottomExtra + (rows/U)·(H + gapY) − gapY.

       With U = 1 these are the design's formulas (GV:202, :222). With the engine's `free` output (U = 16) the same mapping yields the free layout, so no view-side y is computed. The pixel y depends on `rows`, so a new head shifts every card down (item 10).
     - **`PerNodeTops`**: per-node tops for 10.13's view-side gap variant and for hand-made fixtures (the gap variant was dropped on 2026-09-27; the fixtures remain). Its height is the largest top + H + pad + bottomExtra.
   - **Visible query.** The index is a `Float64List` of tops plus an `Int32List` of node indices sorted by top. Binary search finds the nodes whose card rect, inflated by the overhang, intersects the window ± `scrollCacheExtent`; an x filter follows. It is one mechanism for rows and free y, with no row arithmetic.
   - The index is rebuilt per layout and per metrics change: O(n) when the order is unchanged, O(n log n) otherwise.
   - **Child vicinity** is `ChildVicinity(xIndex: col, yIndex: node index)`. That stays unique even when two nodes share a row and a column in free mode. Identity rides on the key (item 9).
5. **Layout.** Override `layoutChildSequence` only, never `performLayout`.
   - Apply both extents from the data before building any child. When `applyContentDimensions` returns `false`, apply them once more.
   - Tolerate a `null` from `buildOrObtainChildFor`.
   - Give every child its `layoutOffset` and lay it out with `parentUsesSize: true`.
   - `firstChild` is valid only in paint.
   - Pass both scroll controllers explicitly, so no `PrimaryScrollController` gets attached.
   - Assert that the axis directions are down and right. That still holds: the newest commits are at the top, and only the row index counts from the bottom.
   - Use `scrollCacheExtent`, not the deprecated `cacheExtent` (research §5). The default is 250 px on both axes.
6. **Paint** (research §5). Override `paint` completely, with an own `LayerHandle<ClipRectLayer>` pushed via `context.pushClipRect(…, oldLayer:)`. The base `paint` returns early without children and keeps `_paintChildren` private.
   - Paint in hook order:
     1. background (10.2: the grid, then the bucket guides);
     2. edges (10.4, including the elided stubs and labels);
     3. the visible cards (`parentData.isVisible`), in the design's z-order: base, then @, then selected, then hovered or pinned (GC:73-77). Each card is painted at the opacity of 10.6's paint-time dim predicate (`context.pushOpacity`, no rebuild);
     4. the overlay (10.2's gutter).
   - The painted plane covers max(content, viewport); the design's `.gplane` has a minimum of 100% (GC:50).
   - Null the handle in `dispose`.
7. **Scrollbars** (research §5). The 2D view builds none (flutter#122348), so wrap two `Scrollbar`s from `package:material_ui` around it on the same controllers.
   - Both axes notify at depth 0, so each predicate also checks `notification.metrics.axis`.
   - Inset one bar by the other's thickness at the corner.
   - Their style is design question (a).
8. **Input.**
   - Use `DiagonalDragBehavior.weightedEvent` (research §5). With the POC's `free` (`graph_poc/commit_graph_view.dart:25`), a vertical swipe drifts sideways.
   - A mouse-wheel event that carries dx and dy scrolls both axes. Otherwise the inner Scrollable wins `pointerSignalResolver` and dy is dropped.
   - Keep the framework's Shift flip for mice (`ScrollBehavior.pointerAxisModifiers`).
   - **Pan-by-drag** (GV:560-576, GC:45-46):
     - It is a canvas-only pan recognizer. A primary-mouse-button drag that starts off every card and card affordance pans both axes 1:1, with pointer capture.
     - `ScrollBehavior.dragDevices` stays unchanged. Adding the mouse would make card drags scroll and collide with 10.10's card drags.
     - The cursor is `grab`, and `grabbing` while panning. Cards show the click cursor.
     - A pan never changes the selection.
     - Presses on empty canvas hit the viewport itself (`hitTestSelf` is true; research §5: otherwise nothing is hit there). The recognizer uses that, and 10.6 decides what a plain click on the canvas does.
   - This story exposes the scroll primitives only: jump or animate to an offset, and `reveal`. Keyboard handling belongs to 10.6.
9. **Child delegate** (research §5, keys and `shouldRebuild`). Replace `TwoDimensionalChildBuilderDelegate` with a custom `TwoDimensionalChildDelegate`. The builder delegate has two problems:
   - It wraps each card in a `RepaintBoundary` without hoisting the card's key, so a card's identity is its slot. In the review, 17 of 17 cards lost their state on a reload.
   - Its `shouldRebuild` is always true, so every parent `setState` rebuilt all mounted cards.

   The custom delegate:
   - puts the node key on the outermost widget, whose type never changes;
   - places `KeepAlive(keepAlive: pinned, child: RepaintBoundary(child: card))` below it. `KeepAlive` is a `ParentDataWidget`, so no render object may sit between it and the viewport. Pinning (an open popup in 10.15, a drag in 10.10) flips the flag and updates the Element in place;
   - compares layout identity or version in `shouldRebuild`;
   - returns `null` for vicinities outside the layout;
   - adds no `AutomaticKeepAlive`;
   - hands cards no per-build closures. Taps and hovers go to stable controllers (10.6), and per-card state arrives through Listenables (10.3).
10. **Anchor and reveal** (research §5).
    - An anchor is a node key plus that node's offset inside the viewport, on both axes.
    - It is re-applied whenever the geometry changes under the same revset and layout mode:
      - a reload (10.5);
      - Detailed cards or Card width (10.3, 10.7);
      - a side panel changing the viewport width: 10.8's right panel (as its design question (e) decides) and 10.14's left panel.

      Resolve the key in the new geometry, then apply `correctBy(newPos − oldPos)` on each axis inside `layoutChildSequence`, before applying the dimensions.
    - A relayout may instead carry a reveal key, which is centred in that same relayout: @ after a revset or layout-mode switch, or a picked bookmark's target (10.14). Which key wins follows 10.5 item 6's precedence. The anchor is the fallback when the key is absent. A reveal key is consumed by the relayout it targets and never re-armed.
    - This covers a new head, which grows `rows` and moves every card down. It also covers a column reorder, because "Min. crossings" is global (GV:98-138; SPEC §4.6, §11.5). *(2026-09-27: `optimized` is dropped; the `compact` order can still move columns locally when a new commit re-cuts a window, SPEC §11.6.)*
    - Which node anchors is 10.5's rule.
    - `reveal(key, alignment: centre | minimal, animate)`. Centre is the design's `scrollToNode` (GV:526-530).
11. **Hit testing and semantics** (research §5).
    - `hitTestChildren` walks item 6's paint order in reverse. The base walks insertion order, which breaks once hover lift, border chips or drag ghosts make children overlap.
    - `describeSemanticsClip` returns the viewport inflated by the cache extent. `describeApproximatePaintClip` returns `Offset.zero & size` unless `Clip.none`. Without these, VoiceOver reports cache-extent cards as visible.
12. **Theme.** Add a `GraphTheme` `ThemeExtension`; this story adds the canvas tokens, and 10.2–10.4 add theirs.
    - Dark and light values come from the design: `--canvas-base` is #12162a dark and #f0ece7 light (SC:9, :42).
    - `GraphTheme.of(context)` falls back to built-in defaults. It must not force-unwrap the way `context.zc` does (`app/lib/src/shared/theme/zanshin_colors.dart:170`).
    - Only the demo host registers it. The running app's `MaterialApp` is Ralph's Yaru test page (`app/lib/src/features/app/zanshin_app.dart:124-149`).
13. **Fake data: recorded layouts from the A/B spike, never a layout engine in the view.** A record joins the spike's input and output (SPEC §2–§3) with the view facts a fixture needs (key, @, bookmarks, immutable, …) and mirrors `GraphLayout`'s fields. The sources:
    - **(a) The design sample.**
      - The spike's design inputs (`inputs/design-<rev>.json`, SPEC §7.2), laid out by the spike's reference implementation in compact, time and free, each with greedy and optimized lane order. *(2026-09-27: the product needs compact and free, with greedy and the `compact` order. The Rust reference has no `compact` order, so those recordings come from the spike's Dart binary, as 4.11's goldens do.)*
      - The greedy compact and time outputs equal the design oracle byte for byte (SPEC §7.2).
      - The design-default input keeps `wq` as the mock has it, so that it matches the oracle.
      - A CLI-faithful variant is recorded as an extra input: 13 commits, with `wq` removed and `vr`'s parent Missing (prototype defect 15).
    - **(b) Scale.** The spike's fixture dumps and seeded synthetic inputs, with their reference outputs (`spikes/graph-layout-ab/inputs/manifest.json`):
      - the dumps: `medium-1k-commits` for `all()` and for a narrowed revset that yields indirect and Missing edges, and `large-10k-commits` for `all()`;
      - the synthetic inputs (SPEC §8.1): 10k, 50k and 100k commits, with 100+ lanes, merges, indirect and Missing edges, and non-monotonic timestamps.

      Vertical tiles of (a) remain only as an extra case.
    - **(c) Free y.** The spike's `free` outputs of (a) and (b) (U = 16), plus one hand-made `PerNodeTops` fixture.
    - **(d)** Real-repo recordings belong to 10.13. *(2026-09-27: 10.13's outcome was decided in the spike viewer, which commits nothing, and a Flutter lab is built only if Ralph asks for one. Real-repo data never enters git; 10.12 lays out real repos live.)*

    **Elided data in a record.** A node's Missing parents come from the spike input's `missing` entries (the stub). A count N exists only for the design sample, taken from the design's `elided`; other records carry the stub without N. N is never a topology field (4.10 Non-goals); if 10.4 design question (a) keeps it, a follow-up count call supplies it.

    **What is committed.** Small records and test excerpts are committed with the tests. The large recordings (10k–100k; the 100k input alone is about 14 MB) are generated locally or in the test setup from the spike, not committed.

    The recorder is a dev-only tool outside `app/lib` and `test/`, e.g. under `spikes/graph-layout-ab/tools/`. Its location is Ralph's call.
14. **Layout invariant checker** (test/debug only). Its **hard invariants** gate every fixture:
    - node keys are unique;
    - every edge references existing nodes;
    - no (child, parent) pair appears twice (prototype defect 6);
    - every child sits at least one pitch above each parent: rowOf(child) ≥ rowOf(parent) + U, i.e. top(child) + H + gapY ≤ top(parent) (SPEC I1);
    - no two cards in one column overlap; in the row modes that means no two nodes share a (row, col) cell (prototype defect 3; SPEC I2).

    Every fixture passes them. 10.4 adds the route invariant as a **counted report**, not a gate (10.4 item 10). A hard-invariant failure on engine output is an engine bug (4.11) to report, never to patch in the view.

**Non-goals.**
- Real cards (10.3; a placeholder box here), edges (10.4), background and gutter (10.2), the view model (10.5), selection and keys (10.6).
- Any layout computation in the view: rows, lanes, columns, route shapes, buckets, elided data or a free y.
- A single-RenderBox rewrite. It brings no measurable gain, and hover, VoiceOver, focus, tooltips, menus and drag would all have to be hand-rolled (research §2).
- Reversed axes and RTL.
- Any dependency on 4.10, 4.11 or 4.12.

**Depends on.**
- 10.0 (done).
- The spike's reference implementation and tools, for the recordings (`spikes/graph-layout-ab`, stages 2–3; a spike, not a backend story).
- No backend story.

**Design status.** FINAL:
- the geometry constants (GV:6), the corner radius (GV:217, GC:72), positions and extents (GV:198-224), and the 56 px padding;
- newest at the top, with row 0 = the oldest, at the bottom;
- the card z-order (GC:73-77);
- pan-by-drag with the grab cursor (GV:560-576, GC:45-46);
- reveal = centre (GV:526-530);
- the canvas tokens for both themes.

NEEDS DESIGN:
- (a) Scrollbars: macOS overlay auto-hide, or the prototype's 10 px custom bars that are always visible (GC:47-49)?
- (b) The demo host's file.

If Ralph wants smaller reviews, this story splits cleanly into two:
- 10.1a: items 1–8 and 11–14;
- 10.1b: items 9–10 (delegate, keys, KeepAlive, anchor, reveal).

**Witnesses.** Widget tests use an explicit 800×600 surface at dpr 1, reset in tearDown. Scroll tests also run under `TargetPlatformVariant.only(TargetPlatform.macOS)` (`BouncingScrollPhysics`). Mounted cards are counted with `skipOffstage: false`, and paint order is checked with the `paints` matcher.
- (a) **Mounting and extents.** On the 100k synthetic fixture, the mounted cards are exactly those whose inflated rect intersects the viewport ± the cache extent (an oracle from the node rects). Both `maxScrollExtent` values equal `UniformRows`' and `GraphMetrics`' formulas before any card is built; at U = 1 those are the design's formulas.
- (b) **Jumping.** A jump to the middle mounts only nearby nodes, and every card of a row that has several.
- (c) **Hits.** Taps hit the right card before and after the jump, including two cards in one row.
- (d) **Input:**
  - a mostly-vertical trackpad pan does not move horizontally;
  - a diagonal drag moves both axes, and so does a wheel event with dx and dy;
  - Shift+wheel on a mouse scrolls horizontally.
- (e) **Pan.** A primary mouse drag on empty canvas moves both offsets by the pointer delta and selects nothing. A drag that starts on a card or an affordance does not pan.
- (f) **Horizontal culling.** On the branchy fixture (at least 100 lanes), at h = 0, far-right columns are not built; at the maximum h, column 0 is not built.
- (g) **Paint order.** `clipRect`, then the background hook, then the first edge `drawPath`, then the first card `drawParagraph`, then the overlay. Among cards: base, then @, then selected, then hovered.
- (h) **Scrollbar axes.** Vertical scrolling never feeds the horizontal scrollbar.
- (i) **Build counts.** A parent `setState` builds 0 cards. A scroll that brings in no new node builds 0. One entering node builds 1.
- (j) **Anchoring:**
  - a reload that adds a head (every card moves down one pitch) keeps the anchor node's viewport offset;
  - a reload that moves the anchor node to another column keeps it in place horizontally too;
  - only entering nodes init a State;
  - a relayout with a reveal key centres that key, and falls back to the anchor when the key is absent;
  - the next relayout after it (a Card-width change) keeps the anchor and does not re-centre.
- (k) **Visible query.** The y-index query equals a brute-force scan on random windows, for `UniformRows` over a row-mode recording and over an engine `free` recording, and for a `PerNodeTops` fixture.
- (l) **Resizing.** Changing W or H re-maps without a layout request: rows and columns are unchanged, the extents are exact, and the anchor holds.
- (m) **Semantics.** A cache-extent card is `isHidden`; a visible card is not.
- (n) **Robustness.** No exception for an empty layout, a shrink while scrolled deep, or macOS overscroll past both ends.
- (o) **Pinning.** A pinned key survives being scrolled out, and survives a reload that moves it. Pinning a mounted card keeps its State (the initState count does not change).
- (p) **Invariant checker.** Its hard invariants pass on every fixture, and it rejects hand-built violations:
  - the prototype's Time output for `r` at 13:59 and `k←r` at 13:55, which puts both in one cell;
  - a child placed below its parent;
  - a duplicate (child, parent) edge;
  - a dangling edge.

### Story 10.2: Canvas background and time gutter — dot grid, sticky 88 px gutter, bucket pills and guides, Free's day axis — *NEEDS DESIGN* [UI]
*(Added 2026-09-26, Ralph — console session on the commit-graph view; re-authored 2026-09-26 from the HTML design export; research: `_bmad-output/planning-artifacts/research/technical-commit-graph-virtualization-research-2026-09-26.md`.)*

> **Decided 2026-09-27 (Ralph, after the spike viewer; the Epic 10 header's "Product decisions 2026-09-27"):** Free is the default layout and Compact the only other one; Time is dropped.
> - The gutter (item 2) serves Free's day axis (item 9), which is no longer conditional. Items 3 and 4 keep giving it the pill and guide styles, but their Time placement, item 6's age ladder and item 7's re-bucketing are no longer built, and item 10 is moot. The Time-only witnesses (pills on a bucket's bottom node, the ladder labels, the today-older-than-12h rule) drop out; the Compact ↔ Free switch witness stays.
> - Two viewer details stay as intended deviations from the design: content fades as it scrolls under the gutter (item 2's gradient, the design's Time gutter GC:57, now in Free), and the current day stays pinned (item 9; design question (e)'s first point is answered: keep it).
> - Design questions: (a) shrinks to the "now" that formats "Today" and "Yesterday" (item 9, Clock); (b) is moot; (c) is settled for now (below); (d), the rest of (e), (f) and (g) stay open, (g) now for Free's timestamps (4.10 open question 2).

**Motivation.** Ralph named the background as its own piece. In the design:
- the canvas is `--canvas-base` with a subtle dot grid anchored to the content (GC:50);
- the Time layout adds a sticky 88 px gutter with one time pill per bucket, plus dotted guides between the buckets (GV:618-628, GC:57-59).

The earlier plan asked whether Time sorts rows by time. The design answers it: Time reorders and packs commits into buckets. That is the layout engine's job (4.11; the spike's `time` mode, SPEC §4.2). This story draws the canvas, and draws the gutter from the layout's buckets.

**Scope.**
1. **Canvas and dot grid.**
   - The base is #12162a dark and #f0ece7 light.
   - A dot of 1 px radius (radial, soft to 1.3 px) every 24 px, offset 4 px, in `--grid-dot`: rgba(255,255,255,.07) dark, rgba(58,46,34,.10) light (GC:4-5, :50).
   - The grid is anchored to the content, so it scrolls with the plane, and covers max(content, viewport).
   - It is painted through 10.1's background hook in **one draw call per frame**: a pre-rendered tile as an `ImageShader`, or `drawRawPoints` over the visible rect. The viewport repaints every scroll frame.
2. **Time gutter** (Time; Free reuses it for its day axis, item 9).
   - 88 px wide. It stays fixed horizontally and scrolls vertically with the content.
   - It is painted through 10.1's overlay hook, above the cards (z 8).
   - Its background is a horizontal gradient from `--canvas-base` (to 70%) to transparent (GC:57).
   - **Hits pass through it** to the cards beneath (`pointer-events:none`, GC:57). This replaces the earlier plan to absorb them. Trackpad and wheel input over it scroll the graph.
   - The content's offX is 88 in Time (and in Free, item 9), so column 0 starts beside the gutter at h = 0 (GV:201).
3. **Pills** (GV:620-622, GC:58). One per bucket with a label; the root bucket has none and is not drawn.
   - Style: 11 px JetBrains Mono in `--text-muted`, padding 2×7, radius 5, `--card-solid` background, 1 px `--border`.
   - Position: x = 14, vertically centred on the card centre of the bucket's **oldest** (bottom) node (GV:203).
   - Labels are cached `TextPainter`s and are never measured into the geometry.
4. **Guides** (GV:203, :626-628, GC:59).
   - A dotted 1 px line in `--border-strong`, dash 2 6, from content x = 88 to the content's right edge.
   - It sits in the middle of the gap below each bucket's bottom node, for every bucket except the oldest.
   - Guides take no height: every gap keeps gapY in `UniformRows`. They are painted in the background hook, behind the edges.
5. **Vertical positions come from 10.1's `VerticalLayout`**, never from row arithmetic. A bucket's extent is the union of its nodes' card rects. So the gutter serves 10.13's view-side gap variant unchanged.
6. **Labels.** The view formats them from the bucket's kind and value that the layout carries (SPEC §3). It uses en-US, as the design does (GV:9-17).
   - An `age` bucket shows its ladder step: 10m, 20m, 40m, 1h, 2h, 4h, 8h or 12h (the age rounded **up**).
   - A `day` bucket shows "Yesterday" or "Sep 23".
     - The label is formatted from the bucket's `value`, the local-midnight instant, with the engine's fixed UTC offset (spike D7). So a label never disagrees with its bucket around a DST switch.
     - DST-exact day boundaries are design question (f).

   The bucketing itself (which commit falls where, and therefore the rows) is the engine's. It needs every node's timestamp and "now" before layout.
7. **Clock.** Buckets are relative to "now", which 10.5 passes in the layout request.
   - As the clock advances, commits change buckets and rows change. That is a relayout that 10.5 issues, not a repaint.
   - This story formats the labels and raises the policy question (a).
8. **Semantics:** design question (d).
9. **Compact:** no gutter, no guides, offX 0.

   **Free: a day axis** (Ralph's request, 2026-09-26, while reviewing the spike viewer; built there the same day, spike README "Viewer"). If Free ships (10.13; since 2026-09-27 it does, as the default), it gets item 2's gutter, with its gradient, its pass-through hits and offX 88. The gutter shows one label per local calendar day: "Today", "Yesterday", then "Sep 24".
   - **The day of a card comes from the layout**, never from the card's own timestamp: it is the local day of the clamped time T(i) = max(ts, T(parents)) (SPEC §4.2 free, step 2), under the engine's fixed offset (D7). y is monotone in T (I6), so top-down every day appears once, newest first.
     - Raw timestamps would open a day early wherever the clamp lifts a child above its older parent. On synth-100k (1,976 such nodes) they put 418 of 2,951 day labels out of order; the clamped days give 2,883 labels, all in order. The real 1.4k-commit repo has no such node (143 days).
     - The price: such a child shows its own date on its card but sits in its parent's day (design question (e)).
     - **Where the days come from** is 4.11 open question 9. Proposed: 4.11 emits one `day` bucket per local day of T in `free` too, and this story formats them as in item 6. Otherwise the worker returns sorted (row, day) pairs beside the layout, as the spike README's Flutter mapping sketches. The view never computes T or the days (the Epic 10 rule: the view never computes buckets). The spike viewer computes them from its bundle today.
   - **Placement** (the viewer's; the design has no Free mode):
     - each label is vertically centred on its day's top (newest) card, in item 3's pill style;
     - a dotted guide in item 4's style runs through the middle of the gap above that card; the newest day has none;
     - a label closer than 22 px to the one above it is pushed down (no dataset triggers that). A row can hold two days (commits less than a minute apart around midnight share a row); both labels then sit on that row, newest first, with one guide.
   - **Pinned label.** A day can span several screens. The day at the viewport's top edge stays pinned at the top of the gutter until the next label pushes it out, like a list section header: one binary search over the sorted label positions per frame. The design has no pin (design question (e)).
   - **Clock.** Free never relayouts on a clock tick (SPEC §4.2): its days depend on T and the offset, not on "now". "Today" and "Yesterday" are formatted against the "now" of design question (a)'s clock policy. When that "now" passes midnight, the labels are re-formatted: a repaint, not a relayout. A change of the UTC offset (DST, travel) moves the day boundaries, so it is a relayout.
   - **Labels** follow item 6, in the language that design question (c) picks.
10. **Not copied from the prototype:** Time rows for a child older than its parent (prototype defect 3). The engine's topological clamp (SPEC D1) prevents them. This story's witnesses use clamped recordings, and 10.1's checker rejects the rest.

**Non-goals.**
- Bucketing and rows (4.11).
- Cards and edges.
- The Layout control (10.7).
- The clock's relayout (10.5).
- The time-gap variant and the choice of modes (10.13; the pick arrives as a layout mode or a `VerticalLayout`). Free's day axis is item 9.

**Depends on.**
- 10.1.
- Real buckets come from 4.11 via 10.12.
- Time needs every node's timestamp before layout *(2026-09-27: Time is dropped; Free, the default, needs them too)*. 4.10 carries them in the topology call on request (its open question 1 weighs a commit-id cache).

**Design status.** FINAL:
- the base colours and the grid for both themes (24 px pitch, 1 px dot, offset 4, anchored to the content);
- the gutter: 88 px, sticky, with a gradient, letting hits pass through;
- the pill style and position, and the guide style and position;
- the ladder and day labels;
- no gutter in Compact.

Ralph's request, not in the design (2026-09-26): a day axis in Free's gutter (item 9), if Free ships (10.13; it does since 2026-09-27, as the default). Its details are design question (e). Kept as intended deviations (Ralph, 2026-09-27): content fading under the gutter, and the pinned current day.

NEEDS DESIGN:
- (a) The clock. Option 1: freeze "now" per reload, so rows stay stable until the next operation but labels can go stale. Option 2: re-bucket periodically, with a relayout plus anchor every few minutes. Recommendation: freeze per reload, and re-bucket on window focus.
- (b) A commit from today that is older than 12h: today's date (as in the prototype) or "Today"?
- (c) The locale: en-US as in the design, or the system locale? Ralph's request for Free's axis was written in German. The spike viewer formats Free's labels with `Intl`, so `?lang=de` gives "Heute", "Gestern", "24. Sept." without a string table (its default, English, follows the design); in Flutter that is `DateFormat.MMMd(locale)` / `yMMMd` plus two ARB strings. The answer applies to Time's labels too. *(Decided 2026-09-27, Ralph, for now: keep the localisable labels, English by default as in the design. Whether the app is English-only or translated is open and app-wide; deferred-work.)*
- (d) Gutter semantics: row headers, or excluded?
- (e) Free's day axis (item 9). The earlier question (none, a time ruler from the timestamps, or pills at day boundaries) was answered by Ralph's request of 2026-09-26: day labels. Still open: keep the viewer's pinned top label, which the design does not have? *(Yes: Ralph, 2026-09-27, an intended deviation.)* Put the label on the day's top card (the viewer) or, like Time's pills, on its bottom card? Add the year to dates outside the current year (the viewer does, e.g. "Dec 29, 2025"; the design never shows one, in Time either)? Is it acceptable that a child older than its parent shows its own date on its card but sits in its parent's day?
- (f) Day boundaries: keep the engine's fixed UTC offset per layout (spike D7), or have 4.11 use DST-exact local midnights (SPEC §11.3)?
- (g) Which timestamp drives Time: the committer's (what `jj log` shows; the spike's stand-in) or the author's (SPEC §11.3)?

**Witnesses.** The scroll cases also run under the macOS variant.
- The dot grid is one draw call (`paints` matcher). It moves with the content, and covers the viewport when the content is smaller.
- The gutter stays fixed horizontally, and column 0 is visible beside it at h = 0.
- A tap on the gutter over a card reaches that card.
- Pills sit at the card centre of each bucket's bottom node. Guides sit below each bucket except the oldest.
- Labels with a fixed clock, offset and bucket set:
  - 10m;
  - the 12h boundary;
  - Yesterday;
  - Sep 23;
  - the today-older-than-12h rule as decided;
  - a day label formatted from the bucket's value and offset.
- The same suite passes on a `PerNodeTops` fixture.
- Switching Compact ↔ Time or Free adds or removes the gutter and the 88 px offset.
- Free, with a fixed clock and offset: Today, Yesterday, Sep 24 and a previous-year date (as decided in (e)). On a recording with a child older than its parent, the labels follow the clamped days (as 4.11 open question 9 delivers them) and stay in order. The pinned label changes exactly where the next label reaches it. Passing midnight re-formats the labels without a layout request.

### Story 10.3: Commit cards — detailed (62) and compact (40) cards, width 160–400, states, bookmark control and affordance slots — *NEEDS DESIGN* [UI]
*(Added 2026-09-26, Ralph — console session on the commit-graph view; re-authored 2026-09-26 from the HTML design export; research: `_bmad-output/planning-artifacts/research/technical-commit-graph-virtualization-research-2026-09-26.md`.)*

> **Design update 2026-09-28 (the Epic 10 header):**
> - **"…" and the empty bookmark button appear only on hover** (GC:135-136 at `a399daf`), fading and scaling like the "+" chips, and hit-testable only while the card is hovered (item 9). Filled bookmark buttons and legend pills stay visible. This changes item 7's "always visible" and item 6's button mode for a card without bookmarks.
> - **The card's tooltip is gone.** Its text is now the hint line of 10.6's commit callout. The affordances keep their labels (item 11).
> - **Icons.** The quick-action, bookmark and stack glyphs come from the export's `icons/ui/`; the 8 files that `app/assets/icons/svg/` lacks are copied there and mapped like the existing icons. Ralph builds the icon font from them.
> - **The stack card** is 10.17. It reuses this story's `RenderBox` pattern and sizes, with its own slots.
> - **Witness:** "…" and the empty bookmark button appear only on hover, and are hit only then.

> **Design update 2026-09-30 (the Epic 10 header; for 10.20):** the card's `RenderBox` can paint without its border. Its content opacity and a vertical offset of its text line are paint parameters per key, paint-only like hover (item 9). 10.20 traces the outline itself from the card's rect and radius. No animation code here.

**Motivation.** The card is the view's unit of information (GV:394-440, GC:71-148). The mock `_CommitCard` (`app/lib/src/features/commits/commit_card.dart:193`) cannot be reused. It is a variable-height `Column`/`Row` tree with its own hover `setState`, which does not fit a fixed-geometry canvas with recycled children. Ralph's rule is that designed visuals are a `RenderBox` with text slots. The house example is `app/lib/src/features/bootstrap/splash_card_render.dart`: `SlottedMultiChildRenderObjectWidget` at :148 and `RenderBox with SlottedContainerRenderObjectMixin` at :188.

**Scope.**
1. **Structure.** A slotted `RenderBox` in the splash-card pattern.
   - Text slots: subject, id head, id rest, author, date.
   - Slot children: the @ badge, the flags, the bookmark control, the "…" button and the two "+" chips.
   - The box itself paints the background, the border, the rings, the glow and the gold tint.
   - The size is W×H, fixed. Text is ellipsized, and nothing is measured into the geometry (research §1).
2. **Detailed layout (H 62)** (GV:397-427, GC:78-94). Padding 0 12. Line 1 holds the subject (13 px / 500, Inter, ellipsized). Line 2 is 11 px, with gap 8, and holds in order:
   - the @ badge, on the working copy only: JetBrains Mono 700 11 px on `--co`, text `--co-ink`, radius 4, 16 px high;
   - the id, 11.5 px mono in `--text-faint`:
     - a 9 px ◆ first when the commit is immutable and not the root;
     - the first 2 characters bold in the text colour;
     - the dim rest, up to 8 characters in total, or 5 on the @ card;
   - the author's first name, which shrinks first and ellipsizes;
   - the relative date;
   - "empty" in italic `--text-faint`;
   - the conflict ⚠ in amber #fbbf24, 12 px;
   - the merge glyph, 12 px in `--text-dim`.
3. **Compact layout (H 40)** (GV:428-432). One line: the @ badge, the id (5 characters), the subject and the flags.
4. **Data → card**, through `GraphLayout`.
   - **View facts** (always present): change id, @, immutable, root, hidden, divergent, the bookmark refs as `GraphRef` (10.1 item 2), and tags.
   - **Content** (nullable until 10.11 loads it): the description's first line, author name and email, committer timestamp, empty, conflict.
   - **Merge** is shown when `parentCountOf(i)` ≥ 2 (10.1 item 2), Missing parents included, as the design derives it from the real parents (GD:56). The layout's edge count would drop the glyph from a merge whose other parent is outside the revset.
   - **The date** is the relative committer time, which is the time `jj log` shows. Its format is design question (h).
   - On a minute-tick Listenable, only the date slot re-lays out, with 0 card builds. The demo host drives the tick; 10.5 owns it in the app.
5. **States** (GC:72-94).
   - **Base:** `--card-solid` (#1a1f35 / #fffdfa), a 1 px `--border-strong` border, radius 10.
   - **Hover:** `--card-solid-hi` and a `--edge-hov` border, drawn above its neighbours (10.1 item 6).
   - **Selected:** an accent #3b82f6 border plus a 3 px ring in rgba(59,130,246,.28).
   - **Working copy:**
     - a `--co` border;
     - a diagonal `--co-soft` tint up to 70%;
     - a 1 px `--co-deep` ring and a 4 px `--co-glow` ring;
     - a drop glow (0 8 28 −10).

     The tokens are SC:2363-2376. When the card is also selected, the outer 4 px ring turns blue, rgba(59,130,246,.35), and the drop glow goes (GC:76).
   - **Immutable:** the subject in `--text-muted`.
   - **Root:** the subject in mono, normal style, muted. The root has no bookmark control, no "…" and no bottom "+". It keeps the top "+" (`jj new root()`).
   - **Dim** (opacity .4) is not a card state. The viewport paints it from 10.6's focus set.
   - **Pending** (a verb is running, 10.9) is not designed: design question (e).
6. **Bookmark control** (GV:316-351, GC:96-128). This story builds the trigger; its popover is 10.15.
   - It sits on the **top** border: right 10, top −11.
   - **Button mode** (no bookmark, or Bookmark labels = On hover): a 20 px circle with a bookmark glyph, outlined when there is no bookmark and filled when there is one.
   - **Legend mode** (Bookmark labels = Always, the default, and at least one bookmark): a pill of max-width 50% − 34 px showing the first bookmark shortened (GV:28-36):
     - a JIRA-like key (`[A-Z][A-Z0-9]+-\d+`) in bold, then the dim rest;
     - otherwise the dim prefix path (at most 4ch) and the bold last segment;
     - "@remote" for a remote entry;
     - "+N" for the further bookmarks.

     The render order is prefix · main · @remote · rest · +N (GV:326-330).
   - Its border follows the card state: accent when selected, `--co` on the working copy.
   - Bookmarks arrive as `GraphRef` view facts (name, remote, synced, conflicted), not as a wire type. The design shows no tags.
7. **"…" and "+".**
   - The "…" button is a 20 px circle at the bottom right (right 10, bottom −11) and is always visible (GV:384-386). It opens 10.15's fan.
   - The two "+" chips (GV:436-437, GC:129-133) are 30×18:
     - top centre, at −10: "New change on top (jj new)";
     - bottom centre: "Insert new change before (jj new --insert-before)".

     They appear only while the card is hovered, fading and scaling from .85 to 1 over 120–160 ms (item 9). They run their verbs through 10.15 → 10.9.
8. **Overhang.** Hit testing stops at the child's size, so anything painted beyond it would be unclickable.
   - The child box is therefore the card rect inflated by the overhang, plus the 4 px ring and the glow:
     - top: at least 11 px, for the bookmark control (−11) and the top "+" chip (−10; GC:97, :131);
     - bottom: at least 11 px, for the "…" button (−11) and the bottom "+" chip (−10; GC:131, :135). If 10.15 draws the quick-action fan inside the card rather than as an overlay, the bottom grows to at least 13 px plus the fan's shadow: its 24 px buttons are centred on the "…" (GC:142).
   - **The card's `RenderBox` hit-tests only the card rect and its affordance slots.** Everything else in the inflated box returns false. So a click or a drag start in the empty margin reaches the canvas (10.1's pan) or an edge (10.4, 10.10) beneath. The design behaves the same way: only `.gcard` and its affordances block the pan (GV:564).
   - gapY 48 and gapX 56 keep neighbours clear.
9. **Identity and rebuild discipline** (research §5).
   - The key comes from 10.1.
   - Selected and pending arrive through Listenables, with a per-key selector. Selecting A, then B, builds exactly 2 cards.
   - **Hover is paint-only.** The card's `RenderBox` subscribes to the hover controller for its key, and to its fade, and calls `markNeedsPaint`.
     - The background, the border, and the "+" chips' opacity and scale are painted.
     - The chips are hit-testable only while the card is hovered.
     - A hover builds 0 cards (10.6).
   - Callbacks go to 10.6's controllers, never to per-build closures.
10. **Global sizing.**
    - Detailed cards sets H; the default is on.
    - Card width sets W: 160–400 in steps of 10, default 240.
    - Both are a pixel remap (10.1 item 3). 10.1's anchor holds, and both are exposed for 10.7.
11. **Semantics.** One node per card, whose label carries subject, change id, author, date and states, with a tap action. The buttons use the design's labels: "Bookmarks: …" / "Add bookmark", "Quick actions", "New change on top", "Insert new change before".
12. **Options and tokens.**
    - Bookmark labels (Always | On hover) is a `GraphViewOptions` field that the demo host toggles.
    - The card, @, selection and text tokens for both themes go into `GraphTheme`.
    - The fonts are Inter and JetBrains Mono, both bundled.
13. **Not copied from the prototype:**
    - Dimming the subject for an empty **change** (prototype defect 14): design question (a).
    - A legend pill that covers the first ~11 px of a rightward branch-off exit (prototype defect 8): design question (b). The exit leaves at centre + 0.28·W, and the pill spans 10–96 px from the right edge. *(2026-09-27: moot once every edge leaves at the top centre (10.4 item 1). The pill reaches at most W/2 − 24 px in from the right edge, so its left end sits at least 24 px right of the centre.)*
    - Its `hov` class, which has no CSS. Hover is the `:hover` style only.

**Non-goals.**
- Selection and hover logic (10.6).
- The popover, the fan and the describe editor (10.15), and the verbs (10.9).
- The drag source (10.10).
- Live data (10.12); this story runs on recorded layouts.
- Skeletons (10.11).

**Depends on.** 10.1.

**Design status.** FINAL: items 2–8 as cited, plus the default width and the default Detailed.

NEEDS DESIGN:
- (a) The subject style. The prototype dims and italicizes on an empty change. Should the dim italic placeholder be keyed on an empty description instead, with an empty change shown only by its "empty" badge?
- (b) The legend vs. branch exits: the bottom border (as the code comment GV:311-315 intended), the left side, or moving the exit point? *(2026-09-27: answered by moving the exit point: Ralph's top-centre exit (10.4 item 1) leaves the pill clear.)*
- (c) The id: the design's fixed 2 bold characters, or the CLI's shortest unique prefix in bold (`changeIdPrefixLen` from `revsets.short-prefixes`)? The lengths stay 8/5 either way.
- (d) The author fallback when the name is empty.
- (e) The states the design lacks:
  - divergent (the CLI's `/offset`) and hidden;
  - a conflicted bookmark (`??`) and an unsynced local one (`*`);
  - other workspaces' working copies (`name@`);
  - pending.
- (f) Should tags be shown?
- (g) Which bookmark leads the legend?
- (h) The relative-date format. The mock pre-formats `now`, `40m`, `1h`, `20h`, `1d`, `3d` and `Sep 19` (GD) with no rule behind them. When does a date replace `Nd`, and what is the rule below an hour?

**Witnesses.**
- Render tests for each state and flag combination, in both sizes and both themes.
- A merge whose second parent is Missing still shows the merge glyph.
- A 500-character subject and a long author name ellipsize without changing the card size.
- Legend cases: `feature/ZAN-412_onboarding-swipe`, `release/1.5.x@origin`, `riverpod` + 2 more, and the render order including the prefix.
- The root card's affordances: top "+" only.
- The "+" chips appear only on hover. They, the "…" and the bookmark trigger are hit in the overhang.
- A drag that starts 5 px above a card, but not on the bookmark control or a chip, pans the canvas.
- A hover builds 0 cards and triggers one repaint.
- Selecting A, then B, builds exactly 2 cards. A minute tick builds 0.
- Changing W from 160 to 400, and toggling Detailed, keeps the anchor node in place (with 10.1).
- Cards keep their State across a reload that shifts every row.

### Story 10.4: Graph edges — rounded orthogonal routes, dashed indirect edges, crossing hops per window, shared buses, the elided marker, the @ lineage — *NEEDS DESIGN* [UI]
*(Added 2026-09-26, Ralph — console session on the commit-graph view; re-authored 2026-09-26 from the HTML design export; research: `_bmad-output/planning-artifacts/research/technical-commit-graph-virtualization-research-2026-09-26.md`.)*

> **Design update 2026-09-30 (the Epic 10 header):**
> - **Item 5 moves to 10.19,** which answers design questions (a)–(c):
>   - no counts;
>   - the end stub on the design's side slots, under a 24 px spacing rule;
>   - dashed edges, markers and stubs as hover targets with a callout.
>
>   This story keeps the dashed style (item 2), and its hit lookup (item 9) serves 10.19's hover bands. The witness "the elided stub and label positions, and bottomExtra" moves to 10.19; bottomExtra stays 44.
> - **The non-goal "A legend" is lifted:** 10.19 adds one to the toolbar.
> - **10.19 adds cuts:** under each `//` marker the dashed edge is cut 8 × 12 px, as split subpaths like the hops (item 4).
> - **Run indexes:** 10.19 places its markers against whole-layout indexes of vertical and horizontal runs, bends and junctions. Item 4's index of vertical runs is one half of that; build it so that both stories can use it.
> - **For 10.20** (a constraint; no animation code here):
>   - an edge can be stroked partially, from its parent end and by length (`PathMetric.extractPath`);
>   - besides its per-layout index (item 9), it has an identity across layouts: (child key, parent key);
>   - the lineage style can switch without a new layout.

**Motivation.** The design draws each parent edge as its own orthogonal polyline between known card positions, in one of three shapes (GV:52-69, GC:61-69). It confirms the earlier mockup reading: merges run below the child, convergence runs above the parent, and siblings share one horizontal. What changed is the model:
- no lane verticals and no per-row recipe;
- one gray plus a gold lineage, so the planned `colorIdx` / colour-by-opening-edge pass is obsolete (research §5's colour pitfall is moot).

The prototype finds crossing bridges with an all-pairs pass (O(E²), about 1.4 s at 10k) and renders every edge. The view must virtualize both.

**Scope.**
1. **Routes.** The view maps the engine's shape to pixels. The points depend on W and H and are recomputed on a metrics change. Let outY be the parent's top, inY the child's bottom, and pcx/ncx their column centres:
   - **Straight** (same column; a first-parent continuation): [(pcx,outY), (ncx,inY)].
   - **Merge** (a non-first parent, not blocked): up the parent's column to my = inY + 0.4·gapY (below the child), across, then up into the child. [(pcx,outY), (pcx,my), (ncx,my), (ncx,inY)].
   - **Branch-off** (a first parent in another column, or a blocked merge): out of the parent's top at sx = pcx ± 0.28·W towards the child, up to hy = outY − 0.4·gapY (above the parent), across, then up into the child. [(sx,outY), (sx,hy), (ncx,hy), (ncx,inY)].
     - **Changed 2026-09-27 (Ralph; an intended deviation from the design): every edge leaves the parent's top at the centre.** Every edge already enters its child from below at the centre (Ralph noticed it at merge commits), and straight edges and merges already leave the parent's top at the centre; only branch-offs leave at ±0.28·W, so edges often leave off-centre. Now sx = pcx: [(pcx,outY), (pcx,hy), (ncx,hy), (ncx,inY)]. The spike viewer keeps the side exit (Ralph: record only). Consequences:
       - a branch-off shares the exit, and the stub up to hy, with the parent's first-parent continuation and with a merge that leaves up the parent's column: a T-junction at the bus height, or a cross where branch-offs leave both ways;
       - sibling branch-offs to one side still share one bus (item 3); both sides now share the stub;
       - the route class, the blocked rule and every layout output stay unchanged. The stub stays inside the gap above the parent (0.4·gapY), and the engine's geometry model never modelled the side stub either (SPEC §4.6, D5). 4.11 amends only SPEC §4.5's geometry text; no golden changes;
       - crossing hops (item 4): the branch-off's horizontal starts on the continuation's vertical, an endpoint rather than a strict interior point, so no hop is cut at the junction. In the row modes no other edge crosses the stub strictly inside: merge buses sit higher in the gap, and other branch-off buses of that row meet it at its end. In Free a foreign bus can cross it and gets a hop like any other crossing;
       - a foreign branch-off bus of the same row that passes over the parent is hopped at the continuation's vertical, exactly where the branch-off's corner now starts; checked visually in the demo host;
       - on the shared stub only the top-painted style shows (item 7's paint order): an indirect branch-off's dash is hidden where a solid continuation shares the stub, as on a shared bus;
       - the route report (item 10) exempts the shared stub, like every overlap between edges that share the parent;
       - a blocked merge (D9, prototype defect 2) leaves at the centre too, but its vertical still runs up the child's column behind that column's cards; SPEC §11.4 stays open;
       - prototype defect 8 disappears: the legend pill's left end sits at least 24 px right of the centre (10.3 item 13, design question (b));
       - the top "+" chip (10.3 item 7, shown on hover) already sat over straight and merge exits; it now sits over every exit.

   Which shape an edge gets, including the blocked rule (GV:204-207), is the source's decision. That is 4.11, i.e. the spike's `route` and `blocked` (SPEC §4.4–§4.5).
   - Corners are rounded with r = 10 by a quadratic curve, clamped to half of each adjacent segment (GV:38-49).
   - Merges run 19.2 px below the upper card and branch-offs 19.2 px above the lower card, so the two zones never meet.
2. **Style.**
   - 1.5 px in `--edge`: rgba(214,222,245,.34) dark, rgba(58,46,34,.30) light.
   - An **indirect** edge (to the nearest visible ancestor, past commits outside the revset) is dashed 3 5 (GC:64).
3. **Shared buses.** Siblings that branch the same way off one parent share one horizontal at hy.
4. **Crossing hops.** Crossings = Bridge gap is the default; Plain draws no gaps. *(Decided 2026-09-27, Ralph: hops are always on; there is no Plain and no toggle. An intended deviation from the design's tweak.)*
   - A crossing is a point strictly inside a horizontal run of one edge and a vertical run of another, with 1 px tolerance. The horizontal gets a 12×10 gap; the vertical stays continuous (GV:71-96, :629-641).
   - Hops are computed **only for the horizontals in the visible window** (plus a margin). They are checked against an index of vertical runs (by x, with y intervals) over the **whole** layout. So a crossing whose vertical starts off-screen is still found, and the result never depends on the window.
   - There is no all-pairs pass.
   - Gaps are cut into the path geometry as split subpaths, not through masks or `saveLayer`.
   - Whether a crossing between two edges that share a node is bridged is design question (d). The prototype skips such pairs (GV:87); the spike's optimiser counts them (SPEC D5).
5. **Elided marker** (GV:643-649, GC:69). It applies to a node with a Missing parent, i.e. no visible ancestor through that parent.
   - Missing edges are jj facts from 4.10's topology; in the recordings they are the spike input's `missing` entries. The layout does not output them (SPEC §3), and 4.11 computes no counts (SPEC §0).
   - A dashed stub runs from the card's bottom centre down 38 px. It is gold when the node is in @'s lineage.
   - The label "~ N elided" (11 px mono, `--text-faint`) sits at (cx + 10, y + H + 20), above the edges and below the cards.
   - bottomExtra is 44 when such a node sits lowest (GV:200).
   - Whether and how N is shown is design question (a).
   - Where the stub goes when the node also has a visible parent is design question (b). The prototype draws it exactly over that parent's incoming edge, which hides it (prototype defect 7).
6. **@ lineage.**
   - An edge is highlighted when both of its endpoints are ancestors of @, inclusive. That means all ancestors, including merged side branches (GV:520-524).
   - The highlight is `--co`, 2.25 px, with a 4 px `--co-glow` glow, painted last (GC:66).
   - The lineage is a bitset over node indices, built once per layout in O(n+E).
7. **Hover and focus states**, driven by 10.6 (GV:593-599, GC:65-67):
   - hovered edges use `--edge-hov`; dimmed edges drop to opacity .28 and fade over 160 ms;
   - with the focus path on: an edge is hovered iff both its ends are in the focus set, and dimmed otherwise;
   - with it off: an edge is hovered iff it touches the hovered card, and nothing dims;
   - paint order: normal, then hovered, then lineage;
   - only visible edges are classified.
8. **Virtualized painting** (research §5, horizontal culling).
   - An interval index over each edge's vertical extent is built once per layout in O(E log E). The extent runs from the child's bottom (or its bus) to the parent's top (or its bus).
   - Per frame, the edges that intersect the window (plus a stroke/glow margin) are selected and culled horizontally by their x extent.
   - One `Path` per style — normal, dashed, hovered, hovered dashed, dimmed, lineage, lineage dashed — each stroked once.
   - Edges are painted behind the cards, inside 10.1's clip.
   - All y values come from 10.1's `VerticalLayout`, so the same code serves the engine's free mode and 10.13's gap variant.
9. **Hit lookup and identity.**
   - A point → the **set** of edges within a tolerance, for 10.6 and 10.10. A shared bus or an overlap yields several.
   - Edge identity is the edge index. The prototype's `from>to` string key collides on duplicate parents (prototype defect 6).
10. **Route invariant**, added to 10.1's checker as a **counted report**, not a gate:
    - no route segment runs behind a card that is not one of its endpoints;
    - no two edges overlap collinearly, except on a shared bus. *(Widened 2026-09-27: except edges that share a node, which the prototype skips too (GV:87). Such edges overlap on a shared bus and up a parent's exit column: its continuation and a merge leaving up that column already share it, and since the top-centre exit (item 1) every branch-off's stub does too. The hand-built collinear-overlap witness uses edges that share no node.)*

    It cannot gate the recordings yet:
    - The spike keeps the prototype's blocked-merge routing (prototype defect 2; SPEC D9), which Ralph has not decided (SPEC §11.4). Its synthetic inputs have many blocked merges, e.g. 229 on `synth-10k` (compact, greedy).
    - In the engine's free mode a bus can also pass behind a card (SPEC D8).

    So the checker counts hits per kind (behind a card, collinear) and per mode, and 10.13 reads the counts *(2026-09-27: 10.13 is closed; the counts now feed 4.11 open question 4 and SPEC §11.4)*. It fails only on hand-built unit cases. Fixing the routing is 4.11's job. Once Ralph answers SPEC §11.4 and 4.11 fixes it, the report can become a gate for the row modes.
11. **The Crossings option** (Bridge gap | Plain) is a `GraphViewOptions` field that the demo host toggles. *(Dropped 2026-09-27: hops are always on, item 4.)* The edge tokens for both themes go into `GraphTheme`.

**Non-goals.**
- The shape decision and the blocked rule (4.11).
- Edge selection or editing.
- Animation beyond the hover fade.
- Lane colours: the design has one gray plus gold.
- Drop zones (10.10).
- A legend.

**Depends on.** 10.1. Everything comes from the source: recordings now, then via 10.12 the route shapes from 4.11 and the Missing edges from 4.10 (N, if kept, from a separate count call; 4.10 Non-goals).

**Design status.** FINAL:
- the three shapes, the 0.4·gapY bus offsets, the ±0.28·W side point *(superseded 2026-09-27 by the top-centre exit, item 1)*, and r = 10;
- stroke and dash;
- one gray plus the gold lineage of all ancestors of @;
- the hover and dim states and the paint order;
- 12×10 bridges cut into the horizontal;
- the stub-and-label position of the elided marker.

NEEDS DESIGN:
- (a) "~ N elided", or jj's bare "~"? The prototype's N walks every hidden ancestor, O(h) per Missing parent, and jj's Missing semantics differ. Relatedly, how does `ui.log-synthetic-elided-nodes` apply to a view that has no synthetic nodes?
- (b) Where does the stub go when the node also has a visible parent?
- (c) Do edges react to hover or show tooltips beyond the card-driven states?
- (d) Should crossings between edges that share a node be bridged? The prototype skips them.

**Witnesses.** `paints`-matcher tests on recorded layouts:
- The route points of each shape at W 240 / H 62 and at W 160 / H 40 equal the design's formulas, except that since 2026-09-27 a branch-off leaves at the top centre (item 1) and meets its parent's continuation in a T-junction without a hop. The radius clamps on a short segment.
- An indirect edge is dashed.
- On the mock's `all()` / Time / Greedy layout, the two bridges sit in the xy→uw bus and the verticals stay continuous. Plain draws none. *(2026-09-27: Time and Plain are dropped; this witness moves to a Compact or Free recording with known crossings.)*
- On random windows of a 10k fixture, the per-window bridges equal an all-pairs oracle (test-only), including a vertical that starts off-screen.
- A strict-interior crossing between two edges that share a node behaves as decided in (d).
- Sibling branch-offs share hy, and the hit lookup there returns both. A branch-off and its parent's continuation share the exit stub (since 2026-09-27, item 1): the hit lookup there returns both, no hop is cut at the junction, and the route report does not count the stub.
- The elided stub and label positions, and bottomExtra.
- The lineage covers every ancestor, including a merged side branch, and is painted last at 2.25 px.
- The hovered/dimmed classification is correct for a given focus set.
- At 100k, only the intersecting edges are stroked. A straight edge that spans the whole window with both ends off-screen is drawn. There is one `drawPath` per style.
- The route report fails a hand-built blocked-merge case and a hand-built collinear overlap. On the `synth-10k` recordings it reports the blocked merges instead of failing, and on an engine free recording it reports the buses behind cards.
- The same suite passes on an engine free recording and on a `PerNodeTops` fixture.

### Story 10.5: Graph view model and repository wiring — reload per operation, anchoring, re-centring on @, ports, states [UI/bridge]
*(Added 2026-09-26, Ralph — console session on the commit-graph view; re-authored 2026-09-26 from the HTML design export; research: `_bmad-output/planning-artifacts/research/technical-commit-graph-virtualization-research-2026-09-26.md`.)*

> **Design update 2026-09-28 (the Epic 10 header; 4.13, 10.17):**
> - **`GraphRequest`** (item 2) gains the stack state: `stacks` (10.7's "Group stacks" switch), the user's toggles (`expandedKeys` / `collapsedKeys`, persisted per repository by 10.17) and `keepOpenKeys`. The latter carries the selected node and a pending go-to-change target, so a reveal into a collapsed stack expands it in the same relayout.
> - **A toggle is a new request** under the same revset and mode. It is anchored on the toggled stack, i.e. on the member that shares its place (10.17 item 4; item 5; 10.1 item 10), and never re-centres on @. Coalescing (item 3) applies.
> - **Selection** (item 7): a run holding the selection stays expanded until the user collapses it. Then the selection clears, and 10.8 closes.
> - **Counter** (item 10): shown stays the revset's commit count, members of collapsed stacks included (the design counts them, GV:653 at `a399daf`).

> **Design update 2026-09-30 (the Epic 10 header; 10.19, 10.20):**
> - **"Show in all()"** (10.19 item 6) is a revset switch to `all()` with an explicit reveal (item 6, rank 1).
>   - The reveal is resolved on the new layout.
>   - The request carries in `keepOpenKeys` the child's real parents that the old revset hid (from the child's `show`), so the stack that holds the hidden parent opens in the same relayout.
>   - The view model then derives the flash set from the new layout and the old layout's keys.
>   - The legend's "Show `all()`" is a plain switch that re-centres on @.
> - **For 10.20** (a constraint; no animation code here): a reload with a new operation and a stack toggle hand the view both the previous and the new layout, plus the anchor. The previous layout stays alive until the transition ends.

**Motivation.** 10.1–10.4 run on recorded layouts. This story owns the view model. It requests layouts through a narrow port and keeps the view coherent while jj re-derives the graph after every operation (ADR-0002), whether the operation is Zanshin's own or an external `jj`. The watcher reports each operation as an `OpHeadsChangedEvent` (`packages/zanshin_core/lib/src/worker/events.dart:19`) on `ZanshinWorker.events` (`packages/zanshin_core/lib/src/worker/isolate.dart:354`).

Anchoring matters more in the design than it did before. Pixel y depends on the layout's row count (GV:202), so a new head shifts every card by one pitch, and a global lane reorder can move columns. The prototype has no reloads, and it re-centres on @ one relayout late (prototype defect 1).

**Scope.**
1. **View model.** `GraphViewModel` is an `@inject` `ChangeNotifier` created through `ViewModelFactory` with `init:`, like `ZanshinAppViewModel` (`app/lib/src/features/app/zanshin_app_view_model.dart:14-15`, used at `zanshin_app.dart:77-78`). The open handle arrives at `init`, never through an asynchronous DI provider.
   - **Ports.** The view model declares the narrow ports the view uses:
     - **`GraphSource`**: `layout(GraphRequest)` → `GraphLayout`, the handle's events, and `logDefaults()`.
       - This story adds the real adapter over `RepoHandle` and `ZanshinWorker` for the events and `logDefaults`.
       - `layout` stays on recorded layouts until 10.12 (4.10–4.12).
       - Later stories add content (10.11), `show` (10.8) and bookmarks (10.14).
     - **`GraphActions`**: run a verb with ids and parameters → a result or a refusal.
       - This story declares it with a fake, and 10.9 implements it.
       - 10.6's double-click and 10.8's action row wire to it, so they do not wait for 10.9.
   - `RepoHandle` is a `final class` (`handle.dart:41`) and cannot be faked, so unit tests drive fake ports.
   - **Bridge part.** Export `RepoHandle`, `OpenedRepoHandle`, `LogDefaults`, `ZanshinFfiException` (`worker/responses.dart:60`) and `Precondition` from `zanshin_core.dart`. None of them is exported today; this picks up the two barrel entries from 9.33 and 9.35 in `deferred-work.md`.
2. **`GraphRequest`.**
   - **Revset:** the `jj log` preset, which is the effective `revsets.log` from `logDefaults().log`, or `all()`.
   - **Layout mode:** Compact | Time, plus Free if 10.13 exposes it. *(Decided 2026-09-27: Free (the default) | Compact.)*
   - **Lane order:** Min. crossings | Greedy, an engine knob, plus 4.11's work budget. Above about 50k nodes with many lanes, request greedy first and optimized afterwards, as two requests (4.11 items 4 and 9; spike README Recommendation §1). The greedy result of such a pair is not stale: it is shown until the optimized one replaces it, an exception to item 3's drop rule. *(Decided 2026-09-27: the orders are `compact` (the default) | greedy; `optimized` is dropped, and this pair with it. Whether large repos get greedy painted first and `compact` swapped in, under the same exception, is 4.11 open question 8.)*
   - **Pass-through parameters:** `prioritize` (`revsets.log-graph-prioritize`), `shortPrefixes` and the priority `anchors` (4.10 item 3), passed explicitly (`project-context.md:202`). `prioritize` and `shortPrefixes` are pre-filled from `logDefaults()` (Story 4.9, `handle.dart:215`), `anchors` from zanshin_core's editable pre-fill `["trunk()", "present(@)"]` (4.11 item 9).
     - `syntheticElided` is not sent: the topology call has no synthetic nodes and takes no such parameter (4.10 item 1, re-planned 2026-09-26). What `ui.log-synthetic-elided-nodes` means for this view stays 10.4 design question (a).
   - **For Time:** "now", set by 10.2's clock policy (a), and the fixed UTC offset for calendar days (SPEC D7; 10.2 design question (f)). **For Free:** the same offset, for its day buckets, if 4.11 open question 9 is accepted (10.2 item 9); Free sends no "now". *(2026-09-27: Time is dropped, so no request carries "now".)*
   - The request carries no card width or height.
3. **Reload.**
   - Reload on every `OpHeadsChangedEvent` for this handle, and after every mutation the app runs (10.9).
   - Coalesce: at most one request in flight plus one queued, and the latest wins.
   - Drop any result older than the newest request. The worker runs one command at a time and cannot cancel one.
   - **Clock.** In Time, a re-bucket under 10.2's policy (a) is a new request with a new "now", followed by an anchored relayout like any reload. *(Moot since 2026-09-27: Time is dropped, and Free never relayouts on a clock tick.)*
4. **Snapshot-loop guard.** The graph call snapshots first and may write an operation (`handle.dart:57-70`). That operation's event triggers a reload, which then finds nothing left to snapshot. A witness proves that this converges.
5. **Anchoring on swap** (research §5).
   - Choose the anchor node by design question (a). The recommendation: the selected node while it is on screen, otherwise the node nearest the viewport centre.
   - Record its viewport offset, resolve its key in the new layout, and correct both axes (10.1 item 10). That covers a new head, rows removed above, and a column reorder.
   - If the anchor node is gone: design question (b).
6. **Re-centring on @, and the scroll precedence** (GV:531-538).
   - On the first layout, centre @ without animation.
   - After a revset or layout switch, centre @ in the **same** relayout that the switch produced, not one relayout later. On these switches the re-centre replaces the anchor.
   - Card width and Detailed changes keep the anchor and never jump to @.
   - **Precedence.** This is the one rule for 10.1, 10.7, 10.8 and 10.14:
     1. an explicit reveal request: a bookmark pick (10.14), locate @ (10.6), or go-to-change (10.6 item 11);
     2. the re-centre on @ after a revset or layout switch;
     3. the anchor.

     So a hidden-bookmark pick that switches the revset to `all()` centres the picked target, not @. The anchor is the fallback when the chosen key is absent. It is also the rule for reloads, card-size changes and side panels, unless 10.8 design question (e) keeps the raw offset for panels. A reveal is consumed by the relayout it targets and never re-armed, so no later relayout jumps.
   - Not copied from the prototype (prototype defect 1): its first relayout of any kind after load or after a switch jumps to @, and after a double-click `jj edit` it scrolls to the old @. Both come from re-arming the re-centre after it has fired (GV:538).
7. **Selection survival.**
   - The selection is keyed by node key, so it survives rewrites.
   - It becomes `null` (absent) when the node is gone: abandoned, or filtered out by the revset. Dependent UI such as 10.8 closes.
   - The prototype keeps the panel open for a commit that is no longer on the canvas (GV:578, prototype defect 9).
8. **Working-tree edits** (design question (c)). A file edit writes no operation until something snapshots, and the watcher reports only op-heads and checkout changes (`events.dart:17-33`). So @'s `empty` badge and the graph go stale while the user edits.
   - Ralph decides the refresh policy: on window focus, a manual refresh, a timer, and/or jj's `fsmonitor.watchman.register-snapshot-trigger`. That trigger is off by default (jj-lib 0.44.0 `lib/src/config/misc.toml:10`).
   - A `WatchErrorEvent` (`events.dart:40`) shows a "live updates degraded" state.
9. **States.**
   - Loading.
   - Empty: the revset matched nothing. This is not an error.
   - Revset error (`jj.revset_parse_error`, `jj.revset_resolution_error`): keep the last valid layout, and expose the message for 10.7.
   - Other errors: an error state with retry.
   - The call's `warnings` (Story 9.32) and `lastPrecondition` (`handle.dart:70`) are exposed for display.
10. **Counter data.** shown = the node count. total = `|all()|` (GV:223), which is `null` until the source provides it (4.10, via 10.12).
11. **Per-layout structures.** The y index, the edge interval index, the adjacency and the lineage bitset are built once per layout, outside the build phase. Their cost at 100k on the fake source is measured, not gated.
12. **Minute tick.** The view model owns the minute-tick Listenable for the cards' relative dates (10.3 item 4).
13. **Host.** The demo host drives the view model with the fake ports. A real-repo host arrives with 10.12.

**Non-goals.**
- The project picker and open flow.
- Revset text editing (10.7 design question (a)).
- Any layout computation.
- Content paging (10.11), the real layout (10.12) and the real actions (10.9).
- Any Rust change.

**Depends on.** 10.1. Story 4.9 (`logDefaults`) and the Epic 3 watcher, both done.

**Design status.** FINAL:
- re-centring on @ at the first layout and after revset or layout switches (without the prototype's delay);
- width and detail changes never jump;
- the selection opens the panel;
- the view preferences are global.

NEEDS DESIGN:
- (a) The anchor node on reloads and resizes. Recommendation: the selected node while visible, otherwise the centre node.
- (b) The fallback when the anchor node vanishes.
- (c) The refresh policy for file edits.
- (d) The looks and wording of the loading, empty, error and degraded states; the design has none.
- (e) Where warnings and snapshot reports appear.
- (f) Should an external operation that moves @ make the view follow @, or keep the anchor?

**Witnesses.** View-model unit tests on fake ports:
- All pass-through parameters are passed explicitly: `prioritize` and `shortPrefixes` from `logDefaults`, `anchors` from zanshin_core's pre-fill.
- Coalescing: 3 events during one load cause exactly one more request. A stale result is dropped.
- The anchor holds when a head is added (every row shifts one pitch) and when the anchor's column changes. A vanished anchor falls back as decided.
- The selection survives a `describe` (same change id, new commit id). It clears on `abandon`, and on a revset that filters the commit out.
- A revset error keeps the last layout. The empty state shows.
- An event caused by the view's own snapshot converges.
- A `WatchErrorEvent` shows the degraded state.
- A revset switch centres @ in the same relayout. A layout-mode switch with @ absent keeps the anchor.
- A reveal request issued together with a revset switch wins over @ (the precedence).
- A Card-width change right after load does not scroll to @.
- After an edit moves @, the next relayout does not scroll to the old @.
- A new "now" in Time issues exactly one request and keeps the anchor. *(Dropped 2026-09-27 with Time.)*

Plus one real-cdylib test on an in-test repo, using `tester.runAsync`: a `describe` through the handle fires `OpHeadsChangedEvent`, and the view model issues exactly one new layout request. The layout source is still fake.

### Story 10.6: Selection, double-click edit, hover focus path, locate @, keyboard and tooltips — *NEEDS DESIGN* [UI]
*(Added 2026-09-26, Ralph — console session on the commit-graph view; re-authored 2026-09-26 from the HTML design export; research: `_bmad-output/planning-artifacts/research/technical-commit-graph-virtualization-research-2026-09-26.md`.)*

> **Design update 2026-09-28 (the Epic 10 header; cited at `a399daf`):**
> - **Item 7's tooltips become the commit callout** (GV:461-484, :506-511; GC:249-277). A card has no tooltip any more; the affordances keep theirs (10.3 item 11).
>   - **Content:** the full subject, wrapped; the full description (4.10's object half); the change id (2 bold + 6); the commit id; the author's full name; the date; and the hint line: "Click: details · Double-click: jj edit", on @ "Working copy (@) · Click for details", none on the root. No stats row (decision (b)).
>   - Content comes from 10.11's cache and is loaded on hover when missing; the 450 ms delay hides the latency.
>   - **VoiceOver:** the description becomes the card's semantics hint (Claude's proposal, accepted).
> - **One hover-callout controller** serves the commit callout, 10.17's stack popover and its row callouts, and 10.15's bookmark popover:
>   - **delays** as in the design: card 450 ms, stack card 380 ms, stack row 180 ms, bookmark control none (GC:254, :234, :259, :118);
>   - **callouts are hoverable.** Moving the pointer from the card into its callout keeps it open, nested too (stack card → popover → row → callout). The gap between card and callout is bridged, as the design's padding does (GC:252). Leaving the whole chain closes it;
>   - **the commit callout stays closed** while the pointer is on the bookmark control, "…" or a "+" (GC:255);
>   - **placement:** beside the card, flipped left near the right edge and growing upwards near the bottom (GV:438-452); always fully inside the canvas, above the cards and the gutter. Callouts are widgets anchored to their card, like 10.15's `OverlayPortal`s, and the card stays pinned while its callout is open (10.1 item 9);
>   - **hover stays paint-only for cards** (0 card builds); only the opening callout builds;
>   - **no callouts while panning or dragging** (10.10).
> - **The focus path** (item 4) passes through stack nodes (10.17).
> - **Witnesses:** the callout opens after 450 ms with the texts above, and stays closed over the affordances; moving into it keeps it open, and leaving closes it; near the right and bottom edges it flips and stays inside the canvas; a hover still builds 0 cards; a pan shows no callout.

> **Design update 2026-09-30 (the Epic 10 header; 10.19):**
> - **The hover-callout controller also serves 10.19's gap callout.** Its targets are a 12 px band along each dashed edge (10.4 item 9's hit lookup), a marker's box and an end stub. It opens after 380 ms and closes 180 ms after the pointer leaves.
> - **10.19's flash after "Show in all()"** runs on item 12's per-key ticker and overlay layer, with its own look: an accent ring held and faded over 2.4 s, static under reduce motion.

**Motivation.** The design fixes the pointer model:
- a click selects and opens the panel;
- a double-click moves the working copy there (`jj edit`);
- hovering keeps the card's ancestors and descendants and dims everything else;
- Esc steps back;
- "@ Working copy" centres @ (GV:541-605).

It designs no keyboard navigation, no context menu and no go-to-change. Research §5 adds that pushing selection or hover through a view rebuild rebuilds every card.

**Scope.**
1. **Controllers.** `GraphSelection` and `GraphHover` are stable controller objects and Listenables, owned by the view model.
   - Cards subscribe per key (10.3 item 9). Selection rebuilds the affected cards; hover only repaints.
   - The view never calls `setState`, and hands out no per-build closures.
2. **Click and double-click** (GV:550-558).
   - A single click on a card selects it and opens 10.8's panel. It does so only after the double-click window has passed, so a double-click never selects. The prototype waits 220 ms. The canvas does not scroll on select.
   - A double-click on a mutable card runs `edit` through 10.5's `GraphActions` port (the fake until 10.9 lands), with no confirmation. On an immutable card: design question (a).
   - Clicks on border affordances never select (GV:322, :375).
3. **Empty canvas.** A press starts 10.1's pan. Whether a click without movement clears the selection is design question (b). The prototype never clears it: a press off every card only starts a pan (GV:563-569). That is a prototype behaviour, not a defect.
4. **Hover and focus path** (GV:586-597). The option is on by default.
   - Hover is the card under the pointer. It is keyed, so after a scroll it follows the pointer, not the recycled child.
   - With the focus path on, the focus set is the hovered node plus all its ancestors and descendants. It is a bitset, O(n+E), computed once per hovered key and cached.
   - Cards outside the set are painted at opacity .4 by the viewport, at paint time with 0 card builds (10.1 item 6). Edges dim to .28 (10.4 item 7).
   - With it off, only the edges that touch the hovered card brighten.
   - The set is measured at 100k, where a root's descendants are the whole graph. If it is too slow, it is computed when the hover settles.
5. **Esc.** It leaves describe mode first (10.15), then clears the selection (GV:541-548).
   - It acts only while the graph or its panel has focus.
   - The prototype's handler is a window-level keydown listener. So the Esc that closes the Projects dialog (APP:2034) also clears the graph selection (prototype defect 11).
6. **Locate @.** `reveal(@, centre, animate: true)`, used by 10.7's button. It is an explicit reveal in 10.5 item 6's precedence. A shortcut is design question (g).
7. **Tooltips**, with the design's texts:
   - on a card: "Click: details · Double-click: jj edit";
   - on the @ card: "Working copy (@)" (GV:415);
   - on the affordances: 10.3 item 11's labels.

   The delay is the platform default.
8. **Keyboard** — not designed. There is one focus node for the graph, visibly indicated and in the tab order with the toolbar and the panel. Everything else is design question (c).
9. **Context menu** — not designed; the design uses the quick-action fan and the bookmark popover instead. Design question (e). If one is wanted, its card stays pinned while it is open (10.1 item 9).
10. **VoiceOver.** The selection is announced, cards expose a tap action, and the reading order is by y, then x.
11. **Go-to-change mechanics**, whatever design question (d) picks for the affordance (measured in the spike viewer, 2026-09-26; spike README "Viewer").
    - **Recommended: an instant jump**, `reveal(key, centre, animate: false)`, i.e. `jumpTo` on both scroll controllers. Whether go-to-change animates, and whether it selects its target, is design question (d). The viewer jumps instantly, centres the target vertically, scrolls horizontally only as far as needed to show the card clear of the gutter, selects it and pulses it three times.
      - 10.1 item 10's `reveal` takes one alignment for both axes. The viewer's behaviour needs a per-axis alignment there (vertical centre, horizontal minimal); otherwise go-to-change centres on both axes.
      - It is an explicit reveal in 10.5 item 6's precedence.
    - **Why an instant jump costs the same at every distance.** The frame after a jump is a pure function of the scroll offset. 10.1's y-sorted index finds the first visible card by binary search (O(log n)), only the visible cards are built, and the edge query does not depend on the distance either. Nothing carries over from the old position. An animated scroll would build and discard every card on the way: about 2,000 viewports over 1.6 M px at 100k.
    - **Budget, from the viewer.** 200 jumps to random nodes, in Chromium, with a 1318×763 px scroll area at DPR 2, Free, the optimized order, detailed 240 px cards and the minimap on, on the real 1.4k-commit repo (median distance 47 k px) and on synth-100k (up to 5.4 M px):
      - the jump is on screen in the first frame after the key press;
      - the main-thread work of that frame is 3.8 / 3.4 ms median, 6.7 / 5.7 ms p95 and 7.4 / 7.0 ms max (real repo / synth-100k), against 0.5–0.7 ms median for an idle frame. A later rerun gave a median of 3.95–4.3, a p95 of 6.5–7.1 and a max of 8.1–10.8 ms;
      - a median of 8–13 cards created (at most 18), and as many removed;
      - distance and work are uncorrelated: |r| ≤ 0.08 over distances up to 5.4 M px, and 1.4k nodes cost the same as 99k.

      Here, the frame after a jump builds at most the visible cards plus the cache extent, and stays within one frame at 100k.
    - **Finding the target.** A full commit id or change id resolves through 4.12's lookups (4.12 item 6 names go-to-change as a consumer), and through the recording's keys until 10.12. A prefix, a bookmark or a revset resolves as the CLI resolves it, with jj's prefix semantics and its refusal of an ambiguous prefix: a backend path (deferred-work). So does a description search, because descriptions are lazy content (10.11). The viewer's linear scan over the ids and first description lines in its bundle took 0.3 ms on the real repo and at most 2.7 ms on synth-100k (ids only); these are viewer numbers, not a product path.

12. **Found-commit pulse** *(decided 2026-09-27, Ralph: the "I am the commit you searched for" animation from the spike viewer ships in the app; an intended deviation from the design, which has no such animation)*. When go-to-change lands on its target, the target card pulses exactly as in the viewer (`spikes/graph-layout-ab/viewer/viewer.css:113-118`, `viewer.js` `jumpTo`):
    - **Shape:** an accent ring (#3B82F6, the selection blue) that grows from 2 px to 22 px beyond the card's border while fading from 80 % to 0 % opacity; the card's own 2 px accent ring stays through the whole pulse.
    - **Timing:** three pulses of 650 ms each, ease-out, then idle. A new go-to-change onto the same card restarts the pulse; a jump to another card ends the old pulse and starts the new one.
    - **Z-order:** while pulsing, the card sits above every other card (the viewer's z-index 7, above @ = 4, selection = 5 and hover = 6; 10.1 item 11's z-order). The ring reaches 22 px beyond the card, more than 10.3's overhang, so it is painted by 10.1's overlay hook at the card's rect (above all cards), never clipped by the card's own box.
    - **Afterwards** the card keeps the selection ring (the viewer selects its target; whether the product selects it too stays design question (d)).
    - **Rebuild discipline:** paint-only. The pulse runs on one ticker driven by a per-key Listenable (10.3 item 7); no other card builds or repaints, and the viewport repaints only the overlay layer.
    - **Reduced motion (recommended):** with the platform's reduce-motion setting on (`MediaQuery.disableAnimations`, macOS "Reduce motion"), there is no pulse, only the selection ring, as the splash card's reduce-motion rule already does.
    - **Scope:** go-to-change only, as in the viewer *(decided 2026-09-27, Ralph: "not for now" — locate @, a bookmark pick and a minimap click do not pulse; another use case can add it later)*.
    - **Witnesses:** a go-to-change starts exactly one pulse on its target (3 × 650 ms, then idle; `pumpAndSettle` completes); other cards build 0 times and do not repaint; a second go-to-change onto the same card restarts it; with `disableAnimations` no animation runs; the ring is visible above an overlapping neighbour (`paints` matcher on the overlay layer).

**Non-goals.**
- Multi-selection (design question (f)).
- Drag (10.10).
- The verbs (10.9) and the popups (10.15).

**Depends on.**
- 10.1, 10.3 and 10.4.
- 10.5 for surviving reloads and for the actions port.
- 10.9 for the real `edit`.

**Design status.** FINAL:
- click = select + panel, after the double-click window;
- double-click = `jj edit` on a mutable commit;
- the focus path with its opacities;
- the Esc order;
- locate @ centres with animation;
- the tooltip texts.

NEEDS DESIGN:
- (a) Double-click on an immutable commit: nothing, as in the prototype, or the CLI's refusal?
- (b) Does a click on empty canvas clear the selection?
- (c) The key map for a layout with several cards per row:
  - What is "next": by y, then x? Along parent/child edges? Along the first-parent chain?
  - Do j/k apply?
  - Do Page Up/Down and Home/End only scroll (the macOS convention) or move the selection?
- (d) Go-to-change: a field, or a ⌘K entry? At 100k, one scrollbar pixel spans about 170 rows; 10.16's minimap is the other navigation for big repos. The spike viewer's version is a candidate:
  - ⌘F focuses a box that matches a change-id or commit-id prefix, else a description substring, and lists up to 50 hits with the total count;
  - Enter or a click jumps, Enter again and Shift+Enter walk the hits, ↑/↓ move in the list, Esc closes the list and keeps the query, and a second Esc leaves the box;
  - the target is selected and pulses three times *(the pulse is decided 2026-09-27: item 12)*.

  Open with it:
  - Does the jump animate? Recommended: instant (item 11). That breaks with "locate @ centres with animation" (FINAL above). Should locate @ also jump instantly when @ is far away (more than a few viewports), where an animation builds every card on the way?
  - Does go-to-change select its target (the viewer does), or only reveal it?
  - jj's prefix semantics (the CLI refuses an ambiguous prefix); whether the input is a revset, as in `jj log -r`; whether a hit outside the shown revset switches to `all()`, as 10.14's pick does; where a description search runs (a backend call, deferred-work).
- (e) A context menu, or not?
- (f) Multi-select? jj verbs take sets (`abandon`, `rebase -r`, `squash --from`).
- (g) The shortcut for locating @.

**Witnesses.** Scroll cases also run under the macOS variant.
- Selecting A, then B, builds exactly 2 cards.
- A click selects only after the double-click window.
- A double-click on a mutable card calls `edit` on the fake actions port and does not select. An immutable card behaves as decided.
- A hover builds 0 cards and triggers one viewport repaint, with the dimming painted as opacity (`paints` matcher).
- On the mock, the focus set equals the node plus its ancestors and descendants. With the option off, only the touching edges brighten.
- Esc order and scope: describe mode first, then the selection, and never while a modal dialog has focus.
- Locate @ centres @.
- After a scroll, hover follows the pointer.
- The selection survives scrolling out and back, and a reload (with 10.5).
- Semantics carry the selected state.
- After a parent rebuild that skips the cards, a tap still reaches the current controller.
- The focus-set timing at 100k is recorded.
- A go-to-change jump from one end of a 100k recording to the other builds only the target's visible cards, no card in between, and places the target as item 11 and (d) decide. Its frame work is recorded at three distances (not gated).

### Story 10.7: Graph toolbar — revset select, Layout, Detailed/Compact cards, Card width, shown / total, @ Working copy — *NEEDS DESIGN* [UI]
*(Added 2026-09-26, Ralph — console session on the commit-graph view; re-authored 2026-09-26 from the HTML design export; research: `_bmad-output/planning-artifacts/research/technical-commit-graph-virtualization-research-2026-09-26.md`.)*

> **Design update 2026-09-28 (the Epic 10 header):** a **"Group stacks"** switch (GV:336-339 at `a399daf`; title "Collapse linear runs of changes into one stack card"), default on, an app-global preference like Detailed (item 7). It sends 10.5's `stacks` flag and re-lays out under the anchor, never re-centring on @. The counter counts the members of collapsed stacks as shown (10.5 item 10). Witness: the switch issues exactly one layout request and keeps the anchor.

> **Design update 2026-09-30 (the Epic 10 header):** 10.19's gap legend, a chip "N gaps" with its popover, sits right after the revset select (GV:366 at `e243dd2`). This story leaves room for it; 10.19 builds it.

**Motivation.** The design's graph toolbar (GV:240-309, GC:10-56) replaces the earlier plan of a free-text revset field with Apply/Save. It offers:
- exactly two revsets;
- the Layout switch;
- the card size and width;
- a counter;
- the @ button.

jj's default log hides work that is reachable only from untracked remote bookmarks; the `all()` preset is how a user gets past that.

**Scope.**
1. **Bar.** 46 px high, with a bottom border on `--bg-window`. Groups run left to right, separated by 1×18 px separators (GC:11-14).
2. **Revset select** (GV:240-276, GC:15-26). A thin control, because the design's popups are not final.
   - A button with a "$" prompt, the code text and a chevron. It opens a 320 px listbox with two options:
     - `jj log`: "Default revset — your mutable changes plus trunk context";
     - `jj log -r 'all()'`: "Every visible commit, incl. immutable history and untracked remotes".
   - The active option has a check mark. The list closes on a pointer-down outside it.
   - `jj log` means the user's **effective** `revsets.log` (`logDefaults().log`), passed through, never a baked-in `builtin_log()`.
   - Config edits write no operation. So while `jj log` is selected, `logDefaults()` is re-read on every reload, or on window focus (design question (b)).
   - A revset error, e.g. a broken `revsets.log`, shows jj's message. Where it shows is design question (c).
3. **Layout** (GV:284-290, GC:53-56). A segmented control: Compact ("Rows = dependency depth") | Time ("Rows = rounded commit time").
   - Switching re-centres on @ (10.5 item 6, with its precedence).
   - The default is Compact (GV:507).
   - A third segment for the engine's free layout exists only if 10.13 decides so (design question (h)).
   - **Decided 2026-09-27 (Ralph):** the segments are Free and Compact, and Free is the default, a deviation from the design's default (GV:507). Time is dropped. Free's label and hint are not designed (design question (h)).
4. **Cards switch** (GV:292-295, GC:27-30). Its label flips between "Detailed cards" and "Compact cards". The default is Detailed.
5. **Card width** (GV:297-302, GC:31-34). A range from 160 to 400 in steps of 10, with a readout such as "240px" in 11 px mono. The default is 240.
6. **Right side** (GV:303-306, GC:35-39):
   - the counter "{shown} / {total} commits" in 11 px mono. total = `|all()|` (10.5 item 10). What it shows while total is unknown is design question (d).
   - the "@ Working copy" button (a gold @; title "Scroll to working copy"), which calls 10.6's locate.
7. **Persistence** (GV:504-507). The revset choice, Detailed, Card width and Layout are app-global preferences in `zanshin_settings`. A switch triggered by the bookmark panel follows 10.14's design question (a).
8. **Controls and semantics.** Controls come from `package:material_ui` with Yaru styling, themed to the design. Semantics follow the design's roles: radiogroup/radio, switch, and a labelled slider.
9. **Other pass-through parameters.** 10.5 passes `prioritize`, `shortPrefixes` and the priority `anchors` (`syntheticElided` is no longer sent; 10.5 item 2). Whether the toolbar offers them is design question (e).

**Non-goals.**
- The earlier free-text field with Apply/Save to `revsets.log` (Stories 9.25 and 9.28), unless design question (a) brings it back.
- Revset completion.
- The window chrome (Fetch / Pull / Push / New, the status bar, the nav rail).
- The design's tweaks panel. Its graph options are view options in the demo host.

**Depends on.** 10.2, 10.3, 10.5 and 10.6.

**Design status.** FINAL: items 1–8 as cited.

NEEDS DESIGN:
- (a) Is the two-preset select final? Or does a free-text field with Apply/Save come back (Story 9.25, the repo-scope `configSet` of 9.28), and do 9.25's presets (My work / All branches) join the list?
- (b) How the `jj log` preset tracks the default.
- (c) Where a revset error shows.
- (d) What the counter shows before total is known.
- (e) Are the advanced parameters offered?
- (f) Which of the design's tweaks become user settings, and where: Bookmark labels, Lane order, Crossings, Hover focus path? *(2026-09-27: Crossings is no longer an option; hops are always on. Lane order is `compact` (the default) | greedy; its label is open, because "Compact" collides with the Compact layout.)*
- (g) Shortcuts.
- (h) Does the Layout control get a Free segment (10.13's outcome)? *(Yes, as the default: decided 2026-09-27. Still open: Free's label and hint text, and the segment order.)*

**Witnesses** (fake port).
- `jj log` sends the effective `revsets.log` (the fake `logDefaults` returns a custom value). `all()` sends `all()`.
- A preset switch issues exactly one layout request and re-centres on @ (with 10.5).
- The switch label flips. The slider's bounds, step and readout are right, and W is applied.
- The counter text is right.
- The @ button calls locate.
- The preferences persist globally and are restored. The defaults are Compact, Detailed and 240 *(since 2026-09-27: Free, Detailed and 240)*.
- A broken `revsets.log` shows jj's message and keeps the last layout.

### Story 10.8: Commit detail panel — thin: header, bookmark chips, meta, description, file list, diff placeholder, action row — *PLACEHOLDER, NEEDS DESIGN* [UI/bridge]
*(Added 2026-09-26, Ralph — console session on the commit-graph view; re-authored 2026-09-26 from the HTML design export; research: `_bmad-output/planning-artifacts/research/technical-commit-graph-virtualization-research-2026-09-26.md`. Thin by default: the design extraction lists this panel, with its describe mode, among the design's dialogs and popups, which Ralph says are not final.)*

**Motivation.** Selecting a card opens the design's right-hand panel (GV:445-479, APP:735-862, GC:150-159). The design extraction lists this panel and its describe mode among the design's dialogs and popups, which Ralph says are not final and will look different.
- So this story is thin by default. It wires the real data and the verbs into a minimal `material_ui` column and invests nothing in polish. Design question (a) asks whether that reading is right.
- The design's review workflow reviews diffs that do not exist before Epic 5: the review meter, the per-file Viewed state, auto-advance and Inline/Split. It moves to the Epic 5 diff follow-up (deferred-work).
- The prototype's data defects (prototype defect 12) are still not copied.
- Mock widgets with a similar structure exist on `MockCommit` and stay for Ralph to retire:
  - `CommitDetail`: `app/lib/src/features/commits/commit_detail.dart:11`;
  - `DiffBlock`: `app/lib/src/features/commits/diff_block.dart:11`.

**Scope.**
1. **Frame.**
   - A right-hand column, 480 px wide (the design's width, a placeholder value), with a left border (GV:657-662, GC:150-155).
   - It opens on selection (10.6). It closes on ×, on Esc (10.6 item 5), or when the selection vanishes (10.5 item 7).
   - It shrinks the canvas. Whether the view holds 10.1's anchor or keeps the raw offset, as the prototype does, is design question (e).
   - The design's 220 ms slide is optional.
2. **Data from two sources.**
   - **The node's view facts** from `GraphLayout`: bookmark refs with their sync state, immutable, empty, @, root, and merge (`parentCountOf(i)` ≥ 2, Missing parents included; the same rule as 10.3's glyph).
   - **`RepoHandle.show(revset: <commit id>)`** (Story 9.6, `handle.dart:690`). It returns a `WarnedList<ShowEntry>` with a single entry:
     - its `Change` provides the full description, `parents`, the author and committer `Signature`s, `isSigned`, and `conflict` with its `conflictedPaths`;
     - its `fileChanges` provide path, kind and `fromPath`.
   - The panel re-fetches when the selection changes and after every reload. A rewritten commit updates the panel; a vanished one closes it.
   - **Snapshot interaction.** `show()` snapshots first. A witness proves that the resulting operation → reload → re-fetch cycle converges.
   - **Bridge part.** Export `ShowEntry`, `Change`, `Signature`, `ConflictState`, `FileChange` and `FileChangeKind`.
3. **Header** (GV:448-460).
   - Tags: "@ working copy", "◆ immutable", "empty", "merge", and "conflict".
   - The full change id, with the first 2 characters bold.
   - **Edit** ("Move the working copy here (jj edit)"), hidden on @ and on immutable commits (GV:457).
   - **Describe** ("Edit description (jj describe)"), hidden on immutable commits and while editing (GV:458).
   - Close × ("Close (Esc)").
4. **Subject and bookmark chips** (GV:461-471).
   - The subject.
   - One chip per bookmark: name and a state, which is ✓ synced, local or remote from the `GraphRef` view facts.
   - "behind" must read as behind once 9.29 provides it; the prototype maps it to "local" (GV:467). The ahead/behind distances need Story 9.29 (backlog).
5. **Body.**
   - **Meta:** author, date, change id and parents. A merge shows every parent, and the root shows none (prototype defect 12).
   - **Description:** the full text.
   - **Changed files:** a plain list of status letter and path (plus `fromPath` for renames) from `fileChanges`. It is shown when "Show changed files" is on (the default).
   - There is no review meter, no Viewed state, no auto-advance and no +/− counts. The counts need line statistics that no API provides (`FileChange`, `status.dart:50`), and the review workflow moves to the Epic 5 follow-up.
6. **Diff.** A "diff not available yet" section until Epic 5 (5.6 and 5.8, backlog).
   - Never a sample diff (prototype defect 12).
   - Never a diff computed in Dart.
7. **Action row** (APP:854-859): Edit, Squash, Abandon, Rebase…, through 10.5's `GraphActions` port. That is the fake until 10.9 lands.
   - Squash and Rebase are disabled, with the reason, until 9.15 and 9.16 land.
   - Hiding vs. disabling on immutable commits is design question (b).
8. **Describe mode.** While editing, the body swaps to 10.15's describe editor.

**Non-goals.**
- Diff rendering (Epic 5 plus a follow-up).
- The design's review workflow (the Epic 5 follow-up).
- Evolog and interdiff views, and a file-content view.
- The describe editor (10.15).
- Line statistics (a backend gap).
- Polish and animation.

**Depends on.**
- 10.5 and 10.6; Story 9.6 (done).
- 10.9 for the real actions.
- Epic 5 for the diff, and 9.29 for behind and ahead.

**Design status.** PLACEHOLDER by default. FINAL: only the header's tag set and its Edit/Describe visibility rules (GV:450-458).

NEEDS DESIGN:
- (a) Does "the dialogs and popups are not final" cover this panel, so it stays thin as planned? Or is it exempt and built to the design: review meter, Viewed persisted per change id, auto-advance, Inline/Split?
- (b) The action row vs. the header: Edit appears twice. On immutable commits, should the row hide its buttons or disable them with the CLI's reason?
- (c) How several parents are displayed.
- (d) Should the committer and the signature be shown?
- (e) The canvas when the panel opens: hold the anchor, or keep the raw offset as the prototype does?
- (f) The look of the diff section before Epic 5 lands.

**Witnesses** (fake ports).
- The header shows the tags, the id, the subject and the chips.
- Edit is hidden on @ and on immutable commits; Describe is hidden on immutable commits.
- The meta shows both parents of a merge, and none for the root.
- The description and the plain file list show.
- The panel updates after a reload caused by `describe`.
- It closes when the commit vanishes, and when the revset filters it out.
- The `show()` snapshot cycle converges.
- The buttons call the actions port. Squash and Rebase are disabled, with the reason.
- No diff request is made and no sample diff is shown.
- Opening and closing the panel follows (e).

### Story 10.9: Action runner — one path from every graph affordance to a verb: pending state, anchored reload, refusals, warnings, undo guard — *NEEDS DESIGN* [UI/bridge]
*(Added 2026-09-26, Ralph — console session on the commit-graph view; re-authored 2026-09-26 from the HTML design export, which has no action dialogs; research: `_bmad-output/planning-artifacts/research/technical-commit-graph-virtualization-research-2026-09-26.md`.)*

**Motivation.** The design triggers verbs from many places:
- a double-click: `edit`;
- the panel header: Edit, Describe;
- the panel's action row: Edit, Squash, Abandon, Rebase…;
- the quick-action fan: Edit, Describe…, Squash into parent, Abandon;
- the "+" chips: new on top, new --insert-before;
- the bookmark popover: create, delete, rename, move.

It shows no pending state, no refusal, no warning and no undo for any of them. The backend owns each verb and its refusals (ADR-0003), and the UI shows the CLI's refusal verbatim.

This story implements 10.5's `GraphActions` port: the one runner that every affordance calls. The popups themselves are thin placeholders (10.15), because Ralph will redesign them. It replaces the earlier "Action dialogs" story: the design has no dialogs.

**Scope.**
1. **Verbs.**
   - **Shipped:** `edit` (`handle.dart:257`), `describe` (`:228`), `newChange([id])` = new on top (`:242`), `abandon` (`:271`), `bookmarkCreate` (`:861`), `bookmarkDelete` (`:891`), `undo` (`:284`).
   - **Backlog:** `squash` (9.15), `rebase` (9.16), bookmark rename / move / move-here (9.19), and `new --insert-before` / `-A`. The last has no backend story; 9.31's preview matrix models it.
   - An affordance whose verb is in the backlog is disabled, with the reason.
2. **Parameters.** Every parameter the shipped verb exposes is offered, pre-filled with the CLI's default. CLI flags the verbs lack are backend gaps (`deferred-work.md`).
3. **Pending.** While a verb runs, the affected cards show the pending state (10.3; its look is 10.3 design question (e)). The worker is serial.
4. **On success.** 10.5 reloads with the anchor held. Whether the view reveals the new or moved @ after `new` or `edit` is design question (a).
5. **Facts.** `MutationResult` provides the new op id, the new and abandoned change ids and @. `FinishFacts` provides the export failures.
6. **One feedback surface** (design question (b)) for:
   - refusals, in the CLI's wording, from `ZanshinFfiException`;
   - 9.32 warnings on success, e.g. `jj.identity_missing`;
   - 9.35's `precondition` / `warnings` on errors.
7. **Undo** is offered only while the op-log head is still `MutationResult.newOpId`.
   - Check the head with `opLog(limit: 1)`, which snapshots first. On any mismatch, drop the affordance.
   - The proper fix is 9.12's `op revert`.
   - `abandon` asks for no confirmation: that is CLI parity, and the design shows none either. Whether an Undo affordance appears is design question (c).
8. **Refusal parity.**
   - `jj.immutable`, including `edit` on the root.
   - `jj.invalid_input` for describing the root.
   - `jj.bookmark_exists`.
   - No invented text.
   - Until 9.38 and 9.40 land, editing @ or saving an unchanged description writes an operation. 10.15's editor therefore sends nothing when nothing changed.
9. **Bridge part.** Export `MutationResult` and `FinishFacts`.

**Non-goals.**
- The popups and the editor (10.15).
- `split`, `diffedit` and `resolve`; `duplicate` and `revert`.
- An identity-remedy flow.
- Drag-and-drop (10.10).

**Depends on.**
- 10.3 (the pending state) and 10.5 (the reload and the port).
- The shipped verbs work now. 9.15, 9.16 and 9.19 enable more.

**Design status.** The design shows only the triggers. NEEDS DESIGN:
- (a) Reveal the new @ after `new` or `edit`?
- (b) The feedback surface: a toast, a banner, or inline?
- (c) An Undo affordance?
- (d) Shortcuts.
- (e) The two flows that arrive when 9.15 and 9.16 land:
  - Squash's combined description, which is the CLI's `$EDITOR` case; 9.15 must surface jj-lib's combined message;
  - Rebase…'s target picking: a click on a card or an edge (via 10.4's lookup), or 10.10's drop.

**Witnesses** (fake ports, per shipped verb).
- The right call is made, followed by exactly one reload request.
- A refusal shows the exception's CLI message.
- Warnings are shown on success.
- The card is pending while the future runs.
- Undo calls `undo()` only while the head is the mutation's operation, and disappears after a foreign operation.
- A disabled verb calls nothing and shows its reason.

Plus one real-cdylib test (`tester.runAsync`): an `edit` through the runner moves @ in the repo, and a reload request follows.

### Story 10.10: Drag-and-drop on the graph — drop on commits and edges, menu from `drop_actions` — *PLACEHOLDER, NEEDS DESIGN* [UI]
*(Added 2026-09-26, Ralph — console session on the commit-graph view; re-authored 2026-09-26 for the HTML design export; research: `_bmad-output/planning-artifacts/research/technical-commit-graph-virtualization-research-2026-09-26.md`. Placeholder: this is not in the design; refine it once Story 9.31 is scheduled.)*

> **Design update 2026-09-28 (Ralph: commit cards and bookmarks will both be draggable later; the design has no drag yet):**
> - **Bookmark drags join this story.** The sources are the legend pill, the bookmark button and the rows of the bookmark popover. A drop on a card moves the bookmark there (`jj bookmark move` / `set`, backend 9.19). As in the CLI, moving a bookmark backwards or sideways needs `--allow-backwards`: a visible choice in the drop menu, never a hidden default. The Non-goal "Dropping bookmark labels" is lifted.
> - **What already holds, so drag needs no rework later** (10.3, 10.6, 10.17):
>   - click, double-click and drag start are separated by the slop on cards, stack cards and bookmark controls, so a stack card expands only on a click that was not a drag;
>   - every callout closes on drag start and stays closed during the drag;
>   - the focus path pauses while the target highlight takes over;
>   - the dragged card stays pinned (10.1 item 9).
> - **New design questions:**
>   - a collapsed stack as a source: the whole run (`rebase -r` over its members), or everything from its oldest member on (`-s`)?
>   - a stack as a target: its newest member, or does it expand while the pointer rests on it, like a folder in the Finder?
>   - dragging one member out of the stack popover?
>   - a bookmark dropped on a stack lands on a member, and the run splits there.

**Motivation.** On 2026-09-21 Ralph decided that the graph is driven by drag-and-drop (Story 9.31, "UI shape"):
- the user drops change S on a commit T, or on an edge T→C;
- a menu lists the available verbs and greys out the unavailable ones with the reason;
- ⌥-drag is a shortcut for duplicate, never a hidden default.

The design has no drag-and-drop. Its canvas drag pans (GV:560-576), which leaves card drags free for this.

**Scope.**
1. **Drag source.** A drag that starts on a card starts a drag past the slop; a drag on the canvas keeps panning (10.1's canvas-only recognizer).
   - A ghost card follows the pointer over other cards. This relies on 10.1's reverse-paint-order hit testing.
   - The source card stays mounted while it is scrolled out, via 10.1's pin.
2. **Auto-scroll** on both axes near the viewport edges.
3. **Drop targets.**
   - A card T means `-o T`.
   - An edge T→C means `-A T -B C`, found through 10.4's point → edge-set lookup. On a shared bus the lookup returns several edges: which one applies is design.
   - No gap zones: 9.31 decided that "above T" is ambiguous in a branching graph.
   - A merge location (several ids) is design.
4. **Preview.** When the pointer settles over a target, query `drop_actions(source, location)` (9.31).
   - The query is debounced, with at most one in flight.
   - Results are cached per (source, location), keyed by the layout's `operationId` (4.10, via 10.12). Until then, the cache is invalidated on every `OpHeadsChangedEvent`.
   - The target is highlighted. On drop, a menu shows one row per verb: Available, NoOp, or Refused with the CLI's reason.
5. **Reload hold.** Every query runs behind 9.26's implicit snapshot and can write an operation. That operation's event would reshuffle the nodes under the pointer. So while a drag is active, 10.5 holds at most one queued reload and applies it after the drop or the cancel.
6. **Execution.** The chosen row runs its verb through 10.9. The possible verbs:
   - `rebase -r` / `-s` / `-b` (9.16);
   - `squash` (9.15);
   - `new` as a merge (6.1);
   - `duplicate` (9.9);
   - `revert` (9.18);
   - `restore` / `absorb` (9.3);
   - `interdiff` (9.6), which is a read; what it opens is design.

   The preview is advisory. The verb's own refusal stays authoritative.
7. **Modifiers.** ⌥ at drop means duplicate. Esc cancels, and so does a drop on nothing.

**Non-goals.**
- Dropping bookmark labels (9.11 / 9.19). *(Lifted 2026-09-28: bookmark drags join this story; see the note at the top.)*
- File-level drags (split).
- Dragging several cards at once (design).

**Depends on.** 10.1, 10.3, 10.4, 10.6 and 10.9. Backend: 9.31 and 9.16 (both backlog), plus 9.15, 9.9 and 9.18 for the full menu. *(2026-09-28: 9.19 for bookmark drags; 10.17 for stack sources and targets.)*

**Design status.** The interaction model was decided in 9.31. NEEDS DESIGN:
- the ghost card;
- the target highlight on cards and on edges;
- which edge a shared bus targets;
- the menu's layout and order;
- what an `interdiff` drop opens;
- dragging several cards at once.

**Witnesses** (fake ports).
- The ghost follows the pointer, while a canvas drag still pans.
- Cards and edges highlight as drop targets.
- Auto-scroll runs on both axes.
- The source card survives scrolling out of view.
- The drop menu shows a fake `drop_actions` result, with refused rows greyed out and their reasons.
- Choosing a row calls the right verb through the runner.
- ⌥-drop picks duplicate. Esc cancels without any call.
- An op-heads event during a drag is held until the drop, and it invalidates the preview cache.

### Story 10.11: Content paging — skeleton cards and visible-range content loads (after Story 4.10) [UI]
*(Added 2026-09-26, Ralph — console session on the commit-graph view; re-authored 2026-09-26 from the HTML design export; research: `_bmad-output/planning-artifacts/research/technical-commit-graph-virtualization-research-2026-09-26.md`.)*

> **Design update 2026-09-28 (the Epic 10 header):** a visible stack card needs the content of all its members: their authors, the oldest and newest dates, and their conflicts (10.17). The stack popover loads its rows as they scroll into view. 10.6's commit callout reads the same cache, with the full description from 4.10's object half.

**Motivation.** Story 4.10 splits the graph call:
- the topology and view facts for the whole revset (cheap, index-only);
- content for the requested commits: the commit objects. On the loose-object 10k fixture that is about 1.2 s of today's 1.22 s (research §3). On a real, packed 1.4k-commit repo most of today's 163 ms is `empty` on its merge commits, 0.78 ms each without a changed-path index (4.10).

The design needs content only on visible cards (subject, author, date, empty, conflict; GV:394-440) and on the selected commit's panel. This story builds the view side against the port with fake latency. 10.12 plugs in 4.10's real call.

**Scope.**
1. **Port.** `content(operationId, commitIds)` returns the content per id. Failures follow 4.10's error contract.
2. **Loading.** Once the viewport settles, request content for the visible nodes plus a buffer. There are no requests while flinging or panning.
3. **Cache.** Content is cached by **commit id** across reloads, because it is commit-intrinsic. The view facts (bookmarks, immutable, @) come with the geometry.
4. **Staleness.** Stale pages are dropped under 10.5's coalescing rule. Geometry and content stay pinned to the same operation (4.10).
5. **Skeletons.** Cards show 10.3's slots without text until their content arrives. The geometry never depends on content, so nothing moves.
6. **Time and free modes.** Timestamps are layout input, never paged content. The view never lays out from paged content. A card's relative date uses the geometry's timestamp when the layout carries one, and the content's otherwise.
7. **Other consumers:** the bookmark panel's subjects for hidden targets (10.14 design question (b)).

**Non-goals.**
- Any Rust change (that is 4.10).
- A growing-extent stream for unbounded revsets (research §3's fallback).

**Depends on.** 10.3 and 10.5. The real call arrives with 10.12 (4.10).

**Design status.** Decide at scheduling: the skeleton look (the design has none), and the buffer size.

**Witnesses** (fake port with latency).
- Settling after a jump requests content only for the visible nodes plus the buffer.
- No requests are made while flinging or panning.
- A reload with unchanged commit ids requests nothing.
- A stale page is dropped.
- A skeleton card gets its text without any card moving.
- Switching to Time never waits for content *(2026-09-27: switching to Free, the default; Time is dropped)*.

### Story 10.12: Adopt the backend layout — the real `GraphSource` over Stories 4.10, 4.11 and 4.12 [UI/bridge]
*(Added 2026-09-26, Ralph — console session on the commit-graph view; re-authored 2026-09-26: the design's layout engine is now Story 4.11, and the landing lanes and segment colours this story was first written for belong to the `jj log` lane model the view no longer draws.)*

> **Design update 2026-09-28 (the Epic 10 header):** real stacks need 4.13: its request fields (10.5) and its result view's stack arrays behind 10.17's accessors. 4.13's column invariant I7 gates every real layout, like 10.1 item 14's hard invariants. This story therefore also depends on 4.13.

> **Design update 2026-09-30 (the Epic 10 header):** the gaps (10.19) need no new backend call.
> - Item 3's N goes, because counts are dropped (decision (b)).
> - 10.19 groups a hidden merge by each node's real parent count, which item 3 already requires from 4.10.
> - Its "Show in all()" reads the child's parents through `show`.

**Motivation.** Everything before this story runs on recorded layouts and fake content. Real data needs all three backend stories:
- 4.10: the index-only topology and view facts for the whole revset (timestamps on request), an operation id, and op-pinned content by commit id;
- 4.11: the design's layout computed at scale in Dart on the worker isolate (the spike's verdict, decided by Ralph 2026-09-26);
- 4.12: the topology wire and a lazy Dart view.

Because of 10.1's accessor rule, adopting them changes no painter and no card.

**Scope.**
1. **The real `GraphSource`.** Implement `layout` over 4.11's `RepoHandle` layout command and `content` over 4.10's content call. The layout runs in the worker isolate; the source never lays out.
2. **Backing swap.** `GraphLayout`'s backing store becomes 4.12's lazy topology view plus 4.11's layout result view, behind the unchanged accessors.
   - `indexOfKey` may use 4.12's key → index lookups.
   - 4.12's bookmark refs are mapped onto the app-side `GraphRef` (10.1 item 2).
3. **Requirements this epic places on 4.10–4.12,** checked here:
   - **4.10:**
     - the complete index-only topology for the revset before the first paint, with node keys, @, the view facts and each node's real parent count (4.10 item 1, on 4.12's wire);
     - the edge kinds as jj facts: direct, indirect and Missing. The Missing edges draw the elided stubs. N, only if 10.4 design question (a) keeps it, comes from a separate op-pinned count call for the visible nodes (a follow-up story; never a topology field, 4.10 Non-goals);
     - `|all()|` and the operation id;
     - every node's timestamp for the time-based modes.
   - **4.11:**
     - the three layout modes (compact, time, free) behind a mode enum, as the spike implements them (SPEC §0) *(2026-09-27: 4.11's dated note proposes porting only `free` and `compact`)*, with `unit` and `rows` (SPEC §3). 10.13 decides which modes are exposed *(decided 2026-09-27: `free`, the default, and `compact`)*;
     - rows, columns, route shapes (with the blocked rule) and buckets, computed from "now" as 10.2's clock policy decides *(moot since 2026-09-27: no product mode reads "now"; Free's day buckets are 4.11 open question 9)*. No elided counts: they are not part of the layout (SPEC §0, D2);
     - the Lane order knob; columns stay stable across reloads only once Ralph confirms 4.11's seeded rule (its item 7, open question 3). *(2026-09-27: that rule was written for the dropped `optimized`; the `compact` order's stability is 4.11 open question 8.)* Until then this story records column changes across reloads instead of gating them;
     - a W-independent result.
   - **4.12:** the wire and the lazy view, with key → index lookups.
   - **Invariants:** 10.1 item 14's hard invariants gate every real layout. 10.4 item 10's route invariant is reported, and becomes a gate for the row modes only once SPEC §11.4 is answered and 4.11 fixes the blocked-merge routing.
4. **Bridge part.** Export 4.10–4.12's Dart types from `zanshin_core.dart`.
5. **Real-repo host.** Until a project-open flow exists, a dev entry point opens an explicitly given path. Where the graph mounts in the shell is Ralph's call.
6. **Debug relayout on reassemble** (4.11's guardrail). A hot reload swaps the engine's code in the worker, which shares the UI isolate's group, but the worker lays out only when asked. In debug builds, `reassemble` re-issues the current layout request, so a layout edit shows at once.

**Non-goals.**
- Painter or card changes.
- Any Rust change (that is 4.10 and 4.12) and any layout code (that is 4.11).

**Depends on.** Stories 4.10, 4.11 and 4.12; 10.1–10.5 and 10.11. *(2026-09-28: also 4.13, and 10.17 for the stack accessors.)*

**Design status.** No design of its own: it checks the requirements above. Decide at scheduling:
- how the dev host receives its path (e.g. `--dart-define`);
- where the graph mounts in the shell (Ralph's call).

**Witnesses.**
- Every 10.1–10.4 witness passes on real layouts of the committed fixtures. Every real layout passes the hard invariants, and its route report is recorded.
- Real-cdylib widget tests on an in-test repo, using `tester.runAsync`:
  - a `describe` through the handle reloads the view, and the anchored node stays in place;
  - a double-click `edit` moves @ and the gold lineage;
  - a revset switch to `all()` shows more nodes and a correct "shown / total".
- Measured, not gated: the time from an operation event to the new layout being painted, on `medium-1k-commits` and `large-10k-commits`, for every exposed mode.

### Story 10.13: Time-layout lab — compare the engine's Compact, Time and Free layouts and a view-side time-gap variant on real data — *EXPERIMENT* [UI]
*(Added 2026-09-26 in the re-plan from the HTML design export, Ralph — console session on the commit-graph view.)*

> **Status 2026-09-26 (Ralph, after the spike viewer):** item 6's faster path was taken. The throwaway viewer (`spikes/graph-layout-ab/viewer/`, README "Viewer") paints the engine's Compact, Time and Free layouts and the M1 gaps ("Time+gaps", with the free mode's gap curve) with all three lane orders, on the real 1.4k-commit repo, the fixtures and synthetic inputs up to 100k. **Ralph's current preference is Free.** It is tentative, not a decision, and this story stays an experiment. His review led to a day axis for Free (10.2 item 9) and to the `compact` lane order (4.11 item 11). Still to decide:
> - (a) Free as the default, and whether Compact and Time stay as options;
> - (b) M1's knobs, if Time+gaps stays a candidate;
> - (c) Free's constants (U = 16, the gap curve, the cap of 48 units; D8) and whether buses may pass behind cards. On the real repo's `all()`, 11–15 horizontal runs cross a card they do not belong to in Free, depending on the lane order (greedy 11, optimized 15, compact 13). The row modes have no such runs, only D9's blocked-merge verticals, which occur in every mode;
> - the default lane order, judged in Free (4.11 open question 8);
> - (d)–(f) below. With Free as the default every layout needs every timestamp, so 4.10's open question 1 (per call or cached) weighs more;
> - whether this Flutter lab is still needed, or shrinks to a Flutter confirmation of the pick (item 6).
>
> **Outcome decided 2026-09-27 (Ralph, via the spike viewer on the real 1.4k-commit repo):**
> - (a) Free is the default and Compact the only other mode. Time and Time+gaps (M1) are dropped.
> - The default lane order is `compact`, with greedy as the alternative; `optimized` is dropped (4.11 open question 8).
> - Ralph also keeps three viewer details as intended deviations from the design (crossing gaps always on, content fading under the gutter, the pinned current date), and he wants every edge to leave a card's top at the centre (the Epic 10 header's "Product decisions 2026-09-27").
>
> **What that leaves of the questions above** (Claude's reading, same day):
> - (b) M1's knobs: moot.
> - (c) Free's constants and buses behind cards: not decided. With Free the default, D8's 11–15 horizontal runs behind cards on the real `all()` are a default-view issue. The question moves to 4.11 open question 4.
> - (d) Recordings: real-repo data never enters git (deferred-work's standing rule); the product's recordings are 10.1's.
> - (e) Committer or author: open, as 4.10 open question 2 and 10.2 design question (g).
> - (f) Clock semantics: moot. Free never relayouts on a clock tick.
> - Every default layout now loads every timestamp (4.10 open question 1).
>
> **Closed as done 2026-09-27 (Claude's call on that outcome; item 6 leaves the Flutter lab to Ralph, who can reopen the story for a Flutter confirmation).** The story's outcome is a decision (item 5), now recorded here and fed to 4.11, 10.2, 10.5 and 10.7, which carry dated notes. The Flutter lab (items 1–4) is not built: with only Free and Compact left there is nothing to compare, and 10.2, 10.4 and 10.12 exercise Free on real data.

**Motivation.** Ralph imagines commits made at about the same time on parallel branches drawn at the same height, so that both order and time distance are visible. A commit at 12:05 on branch b should sit closer to 12:00 on branch a than one at 13:00 does. He is not sure whether that calls for fixed rows (the design's Compact and Time) or a free layout whose vertical spacing follows elapsed time.

The A/B spike already implements the engine side of every candidate (SPEC §0):
- `compact`;
- `time`, with the topological clamp (D1);
- `free`: y from compressed commit time, each child at least one pitch above its parents, with provisional constants (§4.2, D8).

It also names the hybrid, rows with time-sized gaps between the buckets, a painter-side prefix sum. So the question is no longer what 4.11 can build. It is which modes the product exposes, which is the default, and with which constants.

10.1's contract makes each candidate either a different layout record (rows in 1/U units) or a different `VerticalLayout`. None needs a re-architecture, and none computes a layout in the view.

**Scope.**
1. **Data.**
   - Real-repo dumps come from the spike's stage-2 dumper (SPEC §2). It runs on a scratch `jj git clone` of a local repository, e.g. Zanshin's own history or the upstream jj repository at `../jj`.
     - Never `jj git init` in place: `../jj` is read-only (`CLAUDE.md`), and neither repository is a jj workspace today.
     - The dumper extracts the committed fixtures today, so pointing it at a clone is a small extension inside the spike.
   - The spike's fixture dumps and synthetic inputs (non-monotonic timestamps included) complete the set.
   - Each input is laid out by the spike's reference implementation in compact, time and free, and recorded with 10.1's recorder.
   - Every recording passes the hard invariants. The route report is counted in every mode, not failed (10.4 item 10).
   - Whether full recordings are committed is design question (d); tests use small excerpts.
2. **Variants**, switchable live in the demo host:
   - **M0, Rows:** the engine's `compact` and `time` (the design), mapped by `UniformRows`.
   - **M1, Rows + time gaps (hybrid):** the engine's `time` layout with a view-side `VerticalLayout`.
     - It sizes the gap at each bucket boundary from the elapsed time between the buckets (log-scaled and capped), via prefix sums over `buckets` (SPEC §0).
     - Lanes, columns and routes are unchanged, and every bus stays in a card-free gap.
     - Its knobs (scale, cap) are sliders in the demo host only.
   - **M2, Free y:** the engine's `free` layout (U = 16), mapped by `UniformRows`. There is no view-side y computation and no view-side clamp. Its constants (U, the gap curve, the cap) are the engine's (D8, provisional). Variants of them are separate recordings, not view sliders.
3. **Readouts per variant,** shown in the demo host:
   - the content height;
   - the largest and the median vertical gap;
   - 10.4's route report, split by kind:
     - horizontal segments behind a card that is not one of their endpoints. That is the free mode's known issue (SPEC D8); M0 and M1 cannot have any, because every bus lies in a row gap;
     - vertical segments behind such a card, i.e. the blocked merges (SPEC D9). They occur in every mode until SPEC §11.4 is answered;
   - how many cross-column pairs within a given Δt sit at the same height.
4. **Unchanged consumers.** Every variant gives exact extents from data, uses 10.1's y-index query, and runs 10.2's gutter, 10.3's cards and 10.4's edges unchanged.
5. **Outcome.** Ralph picks which modes the product exposes (e.g. Compact plus Time, Time with gaps, Free, or a mix) and the default.
   - The pick is recorded as a dated decision in this story.
   - It is fed to 4.11: which modes ship, the free constants, and whether buses may pass behind cards (SPEC §11.1).
   - It is fed to 10.2 (the gutter for the pick) and to 10.7 (the Layout control).
   - It does not gate 4.11's build, because 4.11 carries all three modes. *(2026-09-27: 4.11's dated note proposes porting only `free` and `compact`.)*
6. **Faster path** (taken 2026-09-26; see the status note above). The throwaway HTML viewer was built inside the spike (`spikes/graph-layout-ab/viewer/`, plain JS, outside the gate). It does not reuse GV's DOM rendering: it paints the design's look with DOM cards for the viewport only and a canvas for the edges, and it scrolls synth-100k at 60 fps. It renders the spike's outputs for compact, time and free, plus the M1 gaps, on the real 1.4k-commit repo, the fixtures and synthetic inputs. Whether this story now shrinks to a Flutter confirmation of the pick or is dropped is Ralph's call.

**Non-goals.**
- Production controls: the lab lives only in the demo host.
- Any engine change: constants change in the spike.
- Persisting the knobs.
- Any view-side layout. M1's gap mapping is the only view-side variant, and it moves no lane, column or route.

**Depends on.**
- 10.1 and 10.4, because the edges are needed to judge the buses. It uses 10.2 and 10.3 if they have landed.
- The spike's stages 2–3 (dumper and reference implementation).
- No backend story.

**Design status.** This story is the design question. M0 is the design (FINAL). NEEDS DESIGN, which the lab answers:
- (a) Which modes are exposed, and which is the default?
- (b) M1's knob values.
- (c) M2's constants, and may buses pass behind cards (SPEC §11.1)?
- (d) Are recordings committed?
- (e) The committer or the author timestamp (SPEC §11.3)?
- (f) Clock semantics. Time re-buckets relative to "now" (10.2 (a)); free mode never relayouts on a clock tick (SPEC §4.2). Is that difference acceptable? Either way, 10.1's anchor absorbs the shift a new head causes.

**Witnesses.**
- Every recording passes 10.1's hard invariants. Route-report hits are counted, not failed.
- The extents are exact for every variant.
- Switching variants keeps the centre node at the same viewport offset. That is a lab rule; the product's mode switch follows 10.5.
- M1 keeps every horizontal run in a card-free gap, and its tops equal the prefix sums over the buckets.
- M2 uses `UniformRows` over the engine's free rows, and the lab reads no timestamp to place a card.
- The readouts are unit-tested on hand-made layouts.
- Only the demo host imports the lab code (a grep-able import boundary).

### Story 10.14: Bookmark list panel — every bookmark, dimmed outside the revset, pick to reveal — *PLACEHOLDER, NEEDS DESIGN* [UI/bridge]
*(Added 2026-09-26 in the re-plan from the HTML design export, Ralph — console session on the commit-graph view. Thin by default: the design extraction lists the left side panels among the design's dialogs and popups, which Ralph says are not final.)*

**Motivation.** The design's "Branches" entry opens a 290 px "Bookmarks" panel on the left (GV:481-497, :607-613, GC:161-169). It lists every bookmark in the repository. Picking one selects and reveals its commit, and switches to `all()` when the commit is not in the current revset (GV:579-584). This is how a user finds work that the default log hides.

The design extraction lists the side panels among the not-final dialogs and popups. So this story ships a minimal `material_ui` list and invests nothing in polish; design question (g) asks whether that reading is right.

**Scope.**
1. **Data.** `RepoHandle.bookmarks()` (`handle.dart:183`, FR-JJ-8) returns one entry per local bookmark and per **tracked** remote bookmark. Each entry has a target change id and nothing else (`packages/zanshin_core/lib/src/ffi/bookmarks.dart:26-67`). It has no synced or conflicted flag, and untracked remote bookmarks are dropped. Story 9.29 adds all of that.
   - **Until 9.29:** rows for local and tracked-remote entries only, with the states local and remote.
     - The view never derives "synced" by pairing a local and a remote entry. After a local rewrite, both share a change id but point at different commits (9.29's motivation).
     - The design's own hidden example, `release/1.5.x@origin` (GD:21, state `remote`), is an untracked remote bookmark. It cannot be listed until 9.29. The `all()` preset promises "untracked remotes" (GV:242).
   - Cards and the detail panel can still show synced, from the graph's view facts (`GraphRef.synced`; Story 4.8's `CommitRef.synced`).
   - Each row shows:
     - a glyph;
     - the name, as `name@remote` for a remote entry;
     - a sub-line "id · subject", with the id as 2 bold characters plus 6;
     - the state.
   - The subject of a target outside the current layout is design question (b).
   - The list reloads with the graph.
   - **Bridge part:** export `Bookmark`, `BookmarkKind`, `LocalBookmark` and `RemoteBookmark`.
2. **Dimming.** Rows whose target is not in the current layout are dimmed to .55.
3. **Pick.** Picking a row selects its target and centres it.
   - If the target is not in the layout, the revset switches to `all()` first. The view reveals the target in the relayout that the switch produces: an explicit reveal beats the @ re-centre of a revset switch (10.5 item 6).
   - No later relayout jumps to @. The prototype reveals the target in that relayout too (GV:582), but its switch re-arms the @ re-centre (GV:538), so the next relayout of any kind jumps to @ (prototype defect 1).
   - Whether that switch rewrites the persisted revset preference is design question (a). The prototype does rewrite it (prototype defect 10).
   - A **divergent** target: a bookmark targets a change id, but a divergent change's commits are keyed by commit id (10.1 item 2), so `indexOfKey` misses it. Design question (f).
4. **Mounting.** Where the panel mounts is Ralph's call: the nav rail is his shell. This story ships the panel widget and its view-model wiring, and the demo host shows it.
5. **Identity.** Rows are keyed by (name, remote).

**Non-goals.**
- Bookmark mutations (10.15 → 10.9).
- Tracking and untracking (9.11).
- The nav rail and the design's placeholder panels (Workstreams, Reviews, Undo Timeline; APP:1054-1080).
- Polish.

**Depends on.**
- 10.5, 10.6 and 10.7.
- Story 9.29 for untracked-remote rows, the synced and conflicted states, and ahead/behind.

**Design status.** PLACEHOLDER by default. FINAL:
- the pick behaviour: select and centre the target, switching to `all()` when it is hidden (GV:579-584), with the reveal in the relayout the switch produces;
- dimming targets outside the layout.

NEEDS DESIGN:
- (a) Does the switch to `all()` persist?
- (b) Where do subjects of hidden targets come from: the content call (10.11), or `show()`?
- (c) Conflicted bookmarks with several targets.
- (d) The sort order; the prototype lists rows in commit order.
- (e) The mount point.
- (f) A divergent target: select every commit, the first one, or refuse?
- (g) Does "the dialogs and popups are not final" cover this panel (thin), or is it exempt and built to the design?

**Witnesses** (fake port).
- Rows appear for local and tracked-remote entries, including a hidden target, which is dimmed.
- No "synced" state is derived from pairing entries.
- Picking a visible bookmark selects and centres it.
- Picking a hidden one switches to `all()` and reveals it, not @, in the relayout the switch produces.
- A Card-width change after that pick keeps the anchor and does not jump to @.
- The persisted preference behaves as decided.
- A reload after an external `bookmark create` adds the row.
- A divergent target behaves as decided.

### Story 10.15: Action popups — quick-action fan, "+" chips, bookmark popover, describe editor — *PLACEHOLDER* [UI]
*(Added 2026-09-26 in the re-plan from the HTML design export, Ralph — console session on the commit-graph view. Placeholder by Ralph's decision: the design's dialogs and popups are not final and will look different; build them thin so the verbs are reachable, and replace their look later.)*

> **Design update 2026-09-28 (the Epic 10 header):**
> - **The bookmark popover opens on hover and on keyboard focus,** without delay (GC:118 at `a399daf`), through 10.6's hover-callout controller. It sits to the right of the card at the control's height, and above the control near the right edge (GC:116-117). Design question (b) is answered for it: hover.
> - **The quick-action fan opens on hover too** (Claude's proposal, accepted), as the design does (item 1), now that "…" itself is visible only on hover (10.3). Design question (b) is thereby answered for both popups.
> - Everything else in this story stays a placeholder.

**Motivation.** The design contains four popups: the quick-action fan, the "+" chips, the bookmark popover and the inline describe editor. They make the shipped verbs reachable from the graph. Their look will change, so this story wires them to 10.9's runner with minimal visuals and invests nothing in polish.

**Scope.** Every popup is thin: `material_ui` widgets, no animation polish, an overlay anchored to its card (e.g. `OverlayPortal`). The card stays pinned (10.1 item 9) while its popup is open.
1. **Quick-action fan**, opened from "…" (GV:353-389).
   - Entries, in the design's order: Edit (jj edit), Describe…, Squash into parent, Abandon (danger).
   - The list is static here; the design says it "will later come from user settings" (GV:356).
   - Edit runs through 10.9. Describe… opens the panel in describe mode. Squash is disabled with its reason until 9.15.
   - It opens on click. The prototype opens it on hover or keyboard focus (GC:143-144): design question (b).
2. **"+" chips** (10.3 item 7).
   - The top chip runs `newChange([this])`.
   - The bottom chip (`new --insert-before`) is disabled, with the reason "no backend verb yet", until a backend story exists.
3. **Bookmark popover** (GV:333-348).
   - A list of the card's bookmarks, with the state text of GV:235. Synced comes from the graph's view facts; ahead, behind and untracked need 9.29.
   - With bookmarks: Rename…, Move to…, Delete (danger). Without: Create bookmark here…, Move existing here….
   - Create (a name field; refused with `jj.bookmark_exists`) and Delete use Story 9.8 (shipped). Rename, Move and Move existing wait for 9.19, and are disabled with the reason.
   - It opens on click. The prototype opens it on hover or keyboard focus (GC:116-117): design question (b).
4. **Describe editor in the panel** (APP:1313-1369).
   - A subject input, focused and selected, plus a body textarea.
   - Enter means done; Esc means discard (10.6 item 5).
   - A dirty indicator, and the buttons Discard / Done editing.
   - Done runs `describe` through 10.9 with the composed description, and only when something changed. The prototype persists nothing (prototype defect 13).
   - Drop the prototype's leftover hint `jj edit … Working copy moved here` (APP:1345-1348).
   - No `JJ:` lines.
   - How the subject and the body are composed into one description is design question (c).
   - What happens to unsaved edits is design question (d). The prototype discards them silently when the selection changes (GV:540).

**Non-goals.**
- The final look and animations.
- A settings UI for the quick-action list.
- Partial (per-file) squash.

**Depends on.** 10.3, 10.8 and 10.9.

**Design status.** PLACEHOLDER by Ralph's decision. Only the verb mapping is FINAL. NEEDS DESIGN, at the later redesign:
- (a) Everything visual.
- (b) Do the quick-action fan and the bookmark popover open on hover and keyboard focus, as in the prototype, or on click?
- (c) How subject and body compose, e.g. with a blank line between them and a trailing newline.
- (d) Unsaved describe edits: what happens when the selection changes, or when a reload rewrites the commit being edited (an external `describe`)? Discard silently, as the prototype does, ask, or keep the draft?

**Witnesses** (fake port, minimal).
- Each enabled affordance calls the right runner verb with the right ids.
- Each disabled one shows its reason and calls nothing.
- Done with no change calls nothing. Esc discards. Unsaved edits behave as decided in (d).
- A card stays mounted while its popup is open and it is scrolled away.

### Story 10.16: Minimap — a raster of the whole graph per layout, viewport overlay, click-and-drag navigation — *NEEDS DESIGN* [UI]
*(Added 2026-09-26, Ralph's idea — console session on the commit-graph view, while reviewing the spike viewer. The viewer then built a minimap to measure its cost (`spikes/graph-layout-ab/viewer/`, README "Viewer"). Backlog; the design has no minimap.)*

> **Design update 2026-09-28 (the Epic 10 header):** the raster shows the grouped layout, so a collapsed stack is one card (10.17). A stack toggle is a new layout and re-rasters through item 6's path.

**Motivation.** On a big repo the scrollbar does not navigate: at 100k, one scrollbar pixel spans about 170 rows (10.6 design question (d)). Ralph proposed a minimap for big repos and asked how it performs. The spike viewer built one to find out: a 112 px strip on the right with a raster of the whole graph (cards bright, edges faint, bookmarked cards blue, @ as a gold line), the viewport as a rectangle plus a full-width band, and click or drag to jump. Measured (budget below):
- the raster is the only real cost: a few milliseconds once per layout, so it belongs off the UI isolate;
- scrolling with the minimap costs at most about 0.4 ms more main-thread work per frame, within the noise.

**Scope.**
1. **The raster: once per layout, off the UI isolate.**
   - A pure-Dart function without `dart:ui` (name in the spec). Its input:
     - the per-node columns and tops: 10.1's `GraphMetrics` and `VerticalLayout`, so `UniformRows` and `PerNodeTops` alike;
     - the card size;
     - the edges' vertical and horizontal runs in 10.4's route geometry (endpoints only, no paths);
     - the marker nodes and the colours as integers;
     - the strip's size in device pixels.
   - O(n + E + pixels), however long the runs are, with no drawing call per node:
     - every node adds its card's rectangle to a 2-D difference array (4 corner updates);
     - every edge adds its runs to 1-D difference arrays;
     - one prefix-sum pass gives per-pixel counts, and a log lookup table maps them to alpha: edges faint, cards bright.
   - Exactness below one strip pixel is not required. At synth-100k's 5.6 M px of content height, one strip point (CSS px) covers about 7,200 content px, about 65 pitches of detailed cards; one raster pixel at DPR 2 covers about 3,600.
   - **Markers that change only with an operation**, and so only with a new layout, are baked in. In the viewer: @ as a gold line across the strip, and bookmarked cards in blue. The set is design question (c).
   - **Output:** an RGBA `Uint8List` at the strip's device size (about 1.4 MB at 222×1546).
   - **Where it runs** is design question (f). Recommended, option A: an app-side `Isolate.run` over the materialized layout arrays and the `VerticalLayout` tops.
     - It needs no change to 4.11, whose Non-goals exclude pixel geometry, and 10.5 item 2's request keeps carrying no card size.
     - It keeps the one worker isolate free (4.11 item 9's occupancy).
     - The inputs are copied into the helper isolate once (a few MB at 100k). The pixels come back through `Isolate.exit`, `Isolate.run`'s return path, which can pass them without a copy.
     - It runs on recorded layouts from the start, with no backend story.
2. **On the UI isolate.** `ui.decodeImageFromPixels` (or `ui.ImageDescriptor.raw`) turns the pixels into a `ui.Image` once per raster. The image is painted inside its own `RepaintBoundary` and never repainted on scroll.
3. **Viewport overlay.** A separate `CustomPainter` with `repaint: Listenable.merge([vertical, horizontal])` over 10.1's scroll controllers draws the viewport rectangle. On a long graph that rectangle is a few pixels tall, so the viewer adds a full-width band (design question (d)). Scrolling repaints only this layer: no raster, no card build.
4. **Dynamic markers** (proposed; not built in the viewer and not covered by its budget). The selection (10.6's `GraphSelection`) and go-to-change hits (10.6 design question (d)) would be painted by the overlay layer at their nodes' positions under the raster's scale, never baked into the raster. Many hits (a one-letter query gave 6,225 on synth-100k) would be drawn as at most one tick per strip pixel row. Whether they are shown is design question (c).
5. **Navigation.** A click centres the viewport on the mapped point. A drag keeps centring it while the pointer is down, as instant jumps, because an animation cannot follow a pointer.
   - Both use 10.6 item 11's jump mechanics, so their cost does not depend on the distance.
   - Whether a click animates follows 10.6 design question (d); recommended: instant.
   - A minimap move is a user scroll, not an explicit reveal (10.5 item 6). It selects nothing unless design question (e) decides otherwise.
6. **Re-raster without a new layout.** A strip resize, a Detailed/Compact or Card-width change, a `VerticalLayout` change (10.13's M1; dropped 2026-09-27, so in the product only a hand-made `PerNodeTops` fixture) or a theme switch changes the pixels but not the layout. On option A they take the same path as a new layout, debounced. A raster of alpha planes that the UI tints would spare the theme switch altogether (design question (c)).
7. **Option and semantics.** On/off is a view option (design question (a)). VoiceOver: design question (g).

**Non-goals.**
- Any layout: the raster maps the layout's rows and columns to pixels and computes none.
- A 4.11 change on the recommended path (option A).
- A minimap of the op log.
- Day labels, @'s lineage and the hover focus path in the strip, unless design question (c) adds them.

**Depends on.**
- 10.1 (viewport, scroll controllers, extents, `GraphMetrics`, `VerticalLayout`), 10.4 (the route geometry for the edge runs), 10.5 (layout swaps) and 10.6 (selection, jump mechanics, go-to-change hits); 10.7 if the toggle lives in the toolbar.
- No backend story on option A. Option B needs 4.11, 4.12 and 10.12, plus the amendments listed under (f).

**Performance budget** (the spike viewer, 2026-09-26: Chromium, an emulated 1440×900 viewport at DPR 2, a strip of 111×773 CSS px = 222×1546 device px; spike README "Viewer"). The viewer rasterises on the page's main thread; here the raster runs off the UI isolate.
- **Raster:** median 1.4–3.9 ms from 22 to 99k nodes, in every mode (9 warm renders each). The floor, about 1.5 ms, is the per-pixel pass over 343k pixels; nodes and edges add about 1 ms per 100k each. A rerun later the same evening was about twice as slow: medians up to 5.0 ms (the real repo 4.3–5.0 ms), one synth-100k series 5.7–7.9 ms, single renders up to 11 ms, and 18 ms right after a strip resize. Each render allocated about 6.6 MB of typed arrays.
- **Scrolling** (240 frames of 64 px): at most about 0.4 ms more main-thread work per frame with the minimap than without (−0.01 to 0.42 ms across the runs), within the run-to-run noise. The overlay update takes 1–3 µs, and no frame was dropped.
- **Here:**
  - the raster stays within a few milliseconds at 100k at this strip size (recorded, not gated), off the UI isolate;
  - the pixels reach the UI isolate without a second copy (option A: `Isolate.exit`; option B: one `TransferableTypedData`);
  - scrolling triggers no raster and no card build;
  - the helper isolate shares its heap and GC with the UI isolate (as the worker does, 4.11 item 4), so each raster's scratch arrays are measured, not assumed free.

**Design status.** The design has no minimap. Ralph's request, not in the design (2026-09-26): a minimap for big repos; he asked about its cost. Everything else is Claude's proposal, modelled on the spike viewer.

NEEDS DESIGN:
- (a) Placement, size and default: a strip on the right as in the viewer (112 px)? Always on, off by default, or on above a node count? Where is the toggle (10.7's toolbar)? How does it share the right edge with 10.8's detail panel?
- (b) Scale: the whole graph fitted into the strip (the viewer), or a fixed scale that scrolls with the view, as code editors do?
- (c) Markers and colours in both themes. Built in the viewer: @ (a gold line) and bookmarked cards (blue). Proposed, not built: the selection and go-to-change hits (item 4). Also @'s lineage, the hover focus path, or Free's days (Time's buckets are moot since 2026-09-27)? Colours baked in, or alpha planes that the UI tints?
- (d) The viewport indicator: a rectangle, a full-width band, or both (the viewer)?
- (e) Interaction: does a click on a card's pixels select it? A hover tooltip with the subject? Instant vs animated follows 10.6 (d).
- (f) Where the raster runs:
  - option A (recommended): an app-side `Isolate.run` over the materialized layout arrays and the `VerticalLayout` tops (item 1). No backend or 4.11 change, and it serves every trigger of item 6, `PerNodeTops` included;
  - option B: a separate worker command with its own geometry parameters in `zanshin_core`, run after the layout. The worker keeps no layout between commands (ADR-0002), so the command re-runs the layout or receives the arrays back, and it occupies the one worker isolate (4.11 item 9). It needs dated amendments to 4.11 (item 9, the Non-goal "no painting, pixel geometry", Related), to 10.5 item 2 ("the request carries no card width or height") and to 10.12. It cannot serve `PerNodeTops` without the tops (10.13's gap variant is dropped since 2026-09-27; the fixtures remain), and the tag becomes [UI/bridge].

  The spike README's "Mapping to Flutter" sketches the worker. Option A keeps its point, the raster off the UI isolate, without those contract changes.
- (g) VoiceOver: exclude the strip, or expose the vertical position as an adjustable value?

**Witnesses.**
- On a hand-made layout and a small strip, the raster's counts equal a naive per-rectangle and per-run fill, pixel for pixel. The marker pixels are as (c) decides.
- The same layout under `UniformRows` and under equivalent `PerNodeTops` rasterises identically.
- The raster time at 222×1546 is recorded for `medium-1k-commits`, `large-10k-commits` and a 100k recording (not gated).
- Scrolling 240 frames with the minimap on rasterises nothing, builds no card through the minimap, and repaints only the overlay layer.
- A click on the strip centres the viewport on the mapped point (the offsets equal the mapping), selects nothing unless (e) decides otherwise, and builds only the target's visible cards. A drag follows the pointer.
- A reload rasterises once. A selection change repaints only the overlay. A strip resize or a Card-width change rasterises once, after the debounce.
- The raster runs off the UI isolate, and its pixels are decoded into an image once per raster.

**Related:** 10.6 item 11 and design question (d) (jump mechanics, go-to-change); 10.1 (metrics, `VerticalLayout`, scroll controllers); 4.11 item 9 (worker occupancy; option B); spike README "Viewer" (the reference implementation and its measurements).

### Story 10.17: Commit stacks — the stack card, its popover and member callouts, the bracket, expand and collapse, persistence [UI]
*(Added 2026-09-28, Ralph — console session on the design update, export at `a399daf`. The engine half is 4.13. Runs on the spike's stack recordings until 10.12. The design is inspiration, not a 1:1 template (the Epic 10 header, decision (c)); the proposals below are Claude's, accepted by Ralph on 2026-09-28.)*

> **Design update 2026-09-30 (the Epic 10 header; 10.19, 10.20):**
> - **Item 4's fade is dropped.** 10.20 brings the unfold and fold animation Ralph tuned in the showcase: the members slide out of the stack's layers in 250 ms. Until then a toggle is instant. The witness "Expand fades the members in over 260 ms…" goes with it.
> - **The export now keeps the columns** on a toggle while its frozen columns stay valid (GV:220-237 at `e243dd2`; prototype defect 17). 4.13's I7 keeps them always.
> - **Stacks at gaps:** the export's `groupStacks` now agrees with 4.13's rule at gaps (GV:264-276). Its sample shows a stack beside a gap and a single card between two stacks (10.19's recordings).
> - **"Show in all()"** (10.19) opens the stack that holds the hidden parent through `keepOpenKeys`, like go-to-change (item 6).

**Motivation.** The updated design collapses linear runs of commits into one stack card (GV:227-264, :536-571; GC:227-247 at `a399daf`). The graph gets shorter and calmer, while forks, merges, bookmarks and @ stay visible. Ralph decided that a toggle never moves a column and that the graph may compact vertically (4.13). This story is the view side: the card, its popover, the bracket, the toggle and the state.

**Scope.**
1. **Stack card** (GV:536-555; GC:228-232). It has a card's size (10.3 item 10) and is a slotted `RenderBox` in 10.3's pattern.
   - **The stacked look:** two offset layers under the card (GC:228-229).
   - **Detailed:** line 1 holds a count badge and the newest member's subject. Line 2 holds the id range newest‥oldest (2 bold + 3 dim characters each, GV:538), the authors' first names, the date range, and ⚠ when a member has a conflict (GV:550).
   - **Compact:** the badge, the range, the subject and ⚠ on one line.
   - **A click expands the stack.** It has no selection, no double-click, no bookmark control, no "…" and no "+" chips, as in the design. The click respects the drag slop (10.10).
   - Hover border, dim and z-order work as for cards (10.3, 10.6), and the focus path passes through the stack node.
   - **Semantics:** one node, labelled with the count, the newest subject and the id range, with an expand action.
2. **Stack popover** (GV:556-568; GC:233-239), through 10.6's hover-callout controller.
   - It opens after 380 ms below the card, or above it when there is no room below (GV:438-442; GC:273).
   - Its rows run newest first, each with the change id (2 bold + 4), the subject and the date. The hint "Click to expand N changes" follows them.
   - Each row opens 10.6's commit callout after 180 ms, beside the row and flipped left near the right edge (GV:559, :563; GC:256-259).
   - **Large stacks** (proposal accepted): the height is capped and the list scrolls; rows load their content as they become visible (10.11). The design lists every member and sizes its flip by 60 + 34 px per member (prototype defect 19).
3. **Bracket** (GV:661-665, :800-806; GC:240-245). Every expanded run gets a 7 px bracket 16 px left of its members' column, from its newest to its oldest member. In 4.13 item 3's rare split run it stands left of the leftmost member, as the design does (GV:664).
   - Its collapse button (the `stack-collapse` icon; 10.3's icon note) appears on hover over the bracket or a member. Its tooltip is "Collapse N changes into a stack".
   - The viewport paints the bracket with the edges (10.1 item 6). The button is hit-testable, and 10.1's pan skips it, as the design's pan does (GV:713).
4. **Expand and collapse** (GV:654-660).
   - A toggle is a new layout request with the changed state (10.5). 4.13 keeps every column.
   - **Anchor, not centre** (proposal accepted). The design scrolls the middle member or the stack into view (GV:657-658). Here the toggled stack keeps its screen position: the anchor is the member that shares the stack's place, and the other members unfold around it; on collapse they fold back into it.
     - In `compact` that member is the oldest, because the stack sits on its row; the others unfold upwards.
     - In `free` it is the newest, because the stack carries its time (4.13 item 4); the older members unfold below it.
   - **On expand the members fade in** over 260 ms: from opacity 0, 6 px higher and at scale .98 (GC:246-247). The animation is paint-only on one ticker, builds no card beyond the entering members, and is skipped under reduce motion (`MediaQuery.disableAnimations`).
5. **Default state and persistence** (4.13 item 2).
   - Every run starts collapsed, as in the design, except a run of mutable ancestors of @ (proposal accepted). Otherwise the work under @ would disappear behind a stack. The design's mock hides the issue, because bookmarks break the chain under @ there.
   - "Group stacks" is 10.7's app-global switch, default on.
   - **The user's toggles persist per repository,** keyed by each run's oldest member. The design persists one global list (prototype defect 18). A run whose oldest member changes falls back to the default.
6. **Interplay.**
   - **Reveal:** go-to-change onto a member of a collapsed stack expands the stack in the same relayout and reveals the member (10.5's `keepOpenKeys`). A bookmark pick and locate @ never target a member, because bookmarked commits and @ are never members.
   - **Selection:** a run holding the selection does not collapse by itself, neither after a reload that forms a new run nor when "Group stacks" is switched on. A collapse by the user clears the selection and closes 10.8 (prototype defect 20).
   - **Counter:** the members of collapsed stacks count as shown (10.5 item 10).
   - **Minimap:** it rasters the grouped layout (10.16).
   - **Content:** a visible stack card loads its members' content (10.11).
7. **`GraphLayout` accessors** (10.1 item 2's rule): the stack nodes with their key and member range, a node's run membership, and the expanded runs with their members for the bracket. They read the recordings now and 4.13's result view after 10.12.
8. **Recordings** (10.1 item 13): the spike's stack recordings (4.13 item 6) of the 36-commit design sample and of the scale inputs, in several stack states. They pass 10.1's hard invariants and 4.13's I7.

**Non-goals.**
- The run rule, the rows and the columns (4.13).
- Dragging stacks (10.10's design questions).
- A stack in the detail panel: a stack is never selected.

**Depends on.** 10.1, 10.3, 10.5 and 10.6 (its hover-callout controller); 10.7 for the switch; 4.13's spike step for the recordings. Real data: 10.12 plus 4.13.

**Design status.** The design gives the direction (cited at `a399daf`), and the proposals above are accepted. Two small points are proposed at build time: the look of the scrolling popover for large stacks, and whether the bracket dims with the focus path.

**Witnesses.**
- On a recording, the stack card shows the count, the range, the newest subject, the authors, the date range and ⚠ as its members say.
- A click expands and the bracket's button collapses. Each toggle issues exactly one layout request, the toggled stack keeps its viewport position on both axes, and no node changes column (I7 on the recordings).
- The popover opens after 380 ms and flips up near the bottom; a row's callout opens after 180 ms. Moving the pointer from the card through the popover into a row's callout keeps all three open, and leaving closes them.
- On a 500-member stack the popover's height is capped, it scrolls, and it builds only its visible rows.
- Expand fades the members in over 260 ms, builds only the entering cards, and animates nothing under `disableAnimations`.
- A run of mutable ancestors of @ starts expanded; persisted toggles come back per repository; a changed oldest member falls back to the default.
- Go-to-change onto a collapsed member expands its stack and reveals the member. A user collapse of the selected member's run clears the selection.
- The counter counts collapsed members as shown.

**Related:** 4.13 (the engine half), 10.1 (accessors, recordings, anchor), 10.3 (card pattern, icons), 10.5 (request, anchor, selection), 10.6 (hover-callout controller, focus path), 10.7 (the switch), 10.10 (drag), 10.11 (content), 10.12 (real data), 10.16 (minimap).

---

### Story 10.18: AI titles for commit stacks — a collapsed stack named by its contents — *IDEA, NOT DECIDED* [UI]
*(Added 2026-09-28, Ralph — console session. Backlog only: Ralph wants to think it over before anything is refined, so there are no ACs. Claude compared the options and ran a spike, `spikes/stack-titles/`; the numbers below come from it.)*

**Motivation.** 10.17's stack card shows the newest member's subject (GV:255, :545 at `a399daf`). A branch's tip is never a member, because a candidate needs exactly one child (4.13 item 1). The label is therefore the subject right below the next visible card, often housekeeping such as "fix tests" or "format code". An anonymous branch has no bookmark, so its subjects are its only name. Ralph asked whether an AI could name what a stack contains.

**Engine.** Only Apple's on-device model (Foundation Models) fits.
- It is free and offline and needs no download and no API key. It needs macOS 26 or later on Apple silicon, with Apple Intelligence turned on. Its context is 4,096 tokens on macOS 26 and 8,192 on macOS 27.
- Zanshin's deployment target is macOS 12.0, so every other Mac needs the fallback.
- The framework is Swift-only: a small Swift bridge in the macOS runner, not the worker and not the FFI. The pub.dev wrappers are all 0.x.
- Ruled out: cloud models (Claude, Gemini; macOS 27's `LanguageModel` protocol can plug them in) and Apple's Private Cloud Compute, because the commit messages would leave the Mac (PRD §5.3). A bundled model (llama.cpp or Gemma via pub.dev) costs 0.5–2 GB of download and RAM, out of proportion for one label.

**Spike 2026-09-28.** 4.13's run rule over a real 1.4k-commit client repo, one on-device call per stack for a title and a summary; M4 Pro, macOS 27.
- **The default `jj log` view (12 commits) formed no stack.** All 103 stacks came from `all()`: all immutable, 2 to 119 members, median 6.
- **Speed:** median 1.06 s per stack, p90 1.81 s, max 3.74 s; cold start 1.0 s; 132 s for all 103. No errors, no guardrail refusals.
- **Quality** (Claude reviewed all 103): the AI title was clearly more informative than the newest subject in about half the stacks, mostly those with 5 or more members. There it often surfaced the feature commit at the bottom of the run. The rest were about equal. One title was misleading: it named the single feature commit of a stack whose other 11 commits were tests and refactorings. No title invented a fact. "At most 6 words" was often ignored, and the casing varied.
- **The summaries add little.** They mostly re-list the subjects and took most of the time, and the popover already lists the members.
- **A label without AI** (the most frequent ticket keys or conventional-commit scopes) mostly showed Jira keys in that repo. It names the ticket, not the content.

**Claude's recommendation, if built.**
- A title only, no summary, and only for stacks of about 4–5 members or more.
- Generated for visible collapsed stacks only, lazily and one request at a time, after 10.11 has loaded the members' content.
- Cached by a hash of the members' descriptions, so a rebase keeps the title.
- Marked as generated (✦) and truncated and normalised by the view. The newest subject stays the fallback and goes into the semantics label.
- Opt-in, through a switch next to "Group stacks" (10.7).

**Open (Ralph).** Whether to build it at all; the card label or only the popover's head; opt-in or on by default; the minimum stack size; an own Swift bridge or a pub.dev wrapper.

**Depends on.** 10.17 (the card and its popover) and 10.11 (the members' content).

**Related:** 10.17, 10.11, 10.7, 4.13; PRD §5.3; `spikes/stack-titles/README.md`.

---

### Story 10.19: Hidden history — gap markers on dashed edges, end stubs, the gap callout, the toolbar legend and "Show in all()" [UI/bridge]
*(Added 2026-09-30, Ralph — console session on the design update, export at `e243dd2`. The design is the gaps study (`Graph Gaps Study.html`, GS), whose variant B Ralph picked. This story takes over 10.4 item 5 and answers 10.4's design questions (a)–(c). It runs on recordings until 10.12. The design is inspiration, not a 1:1 template (the Epic 10 header, decision (c)); the proposals below are Claude's, accepted by Ralph on 2026-09-30.)*

**Motivation.** A revset that leaves commits out leaves gaps. jj reports them as edge kinds (4.10):
- an Indirect edge runs to the nearest visible ancestor;
- a Missing edge marks a parent with no visible ancestor.

10.4 draws an Indirect edge dashed. It had planned a "~ N elided" stub, whose count, position and hover were still open (its design questions (a)–(c)).

The design update of 2026-09-30 answers them (GG; GV:144-170, :243-249, :366, :755-765, :881-896; GC:279-321):
- a marker on every dashed edge;
- an end stub for every Missing edge;
- a hover callout that explains the gap;
- a toolbar legend;
- a one-click way into `all()`.

Ralph picked variant B (`//`, "Break"), no counts anywhere, and one spacing rule: 24 px from everything.

**Scope.**
1. **The marker** (GG:73-92, variant `break`; GC:282).
   - **Look:** two parallel slanted strokes across the edge, 10 px wide and 6 px apart, 1.5 px with round caps, in `--text-faint`.
   - **Cut:** the dashed edge is cut beneath the marker, 8 px along and 12 px across (GG:65-69). The cut is made of split subpaths like 10.4's hops (10.4 item 4), never a mask.
   - Every Indirect edge gets one marker.
   - **A hidden merge** (proposal accepted) is a node with exactly one real parent (4.10's `parent_count`) and at least two Indirect edges. Its hidden parent is a merge (jj-lib 0.44.0 `default_index/revset_graph_iterator.rs:168-172`).
     - The design gives these edges one shared marker on the child's stem, 10 px under the card (GG:53-57). No spacing rule fits there: the stem up to the merge bus is 19.2 px long.
     - Here each edge gets its own marker. Hovering any of them hovers the whole group and opens the group's callout (item 5).
   - **Nodes with several real parents never form a group.** jj does not report through which real parent an Indirect edge was found, and the design's `via` (GV:147-168) has no jj source (prototype defect 4). Each of their edges stands alone.
2. **Placement: the 24 px rule** (Ralph, 2026-09-30). The clearance is a `GraphTheme` constant, 24 px by default, tunable in the demo host.
   - **Obstacles.** The marker's centre keeps at least 24 px from:
     - every card rect, including the bookmark legend pill. Every card counts, not only the edge's own two;
     - every bend (the corner point), crossing and junction of any edge;
     - every other marker, stub and label.
   - **No shared stretches.** The marker never sits where the edge shares its line with another edge: a shared bus, a parent's exit stub, a child's entry stem.
   - **The scan** follows the design (GG:18-44): vertical runs before horizontal ones, each from the child's end, and the first admissible point wins.
     - 24 px is the middle of a 48 px row gap. A straight edge between adjacent rows therefore keeps its marker there, unless a crossing sits in that gap.
     - A branch-off whose child vertical is too short gets its marker on its bus, above a column gap.
   - **Fallback:** without an admissible point, the marker takes the point with the largest minimum distance, the one nearest the child on a tie, never on a shared stretch. The design falls back to 11 px under the card (GG:45-46; prototype defect 21).
   - **Deterministic and independent of the window.**
     - Markers are placed once per layout and card size (W, H), against whole-layout indexes: 10.1's y-sorted card index and 10.4's run indexes (verticals by x, horizontals by y, plus bends and junctions).
     - Stubs are placed first, then markers in edge-index order, each clear of those placed before.
     - The design does neither. It scans every segment of every other edge per dashed edge, O(D·E) (GG:26-36; prototype defect 23), and knows only the edge's own two cards (GG:22; prototype defect 22).
3. **The end stub** (a Missing edge; GG:95-116, variant `break`).
   - **Look:** a dashed lead runs from the card's bottom to a `//` whose centre sits 24 px under the card. Beside it stands "~ elided" in 11 px mono `--text-faint` (GC:284).
   - **No count** (decision (b)). The design shows "~ N elided" only with its count toggle (GG:97).
   - **Position** (answers 10.4 design question (b)):
     - centred when the node has no layout edge to a parent;
     - otherwise the first of the design's side slots that passes the 24 px rule: +0.28·W, −0.28·W, +0.14·W (GV:246-248), else the best of them.

     The design's cut sits 10–15 px under the card (GG:106-110; prototype defect 21).
   - **Label:** it goes right of the glyph where that box is free, else left, else it is left out. The callout says the same.
   - A node that sits lowest keeps 10.4 item 5's bottomExtra of 44 px, which holds the stub.
   - It replaces 10.4 item 5's 38 px stub and label.
4. **States** (GC:286-290).
   - **A marker follows its edge** (10.4 item 7): `--text` when hovered, `--co` when the edge is in @'s lineage, opacity .28 when the focus path dims it.
   - **A stub follows its node:** gold when the node is in @'s lineage, with the lead at 2.25 px and the glow; hovered with the node; dimmed with it.
   - **Painting:** markers and stubs are painted in the edge layer, after the edges and below the cards. Their tokens go into `GraphTheme` for both themes.
5. **The gap callout** (GG:146-180; GC:293-310), through 10.6's hover-callout controller.
   - **Targets:**
     - a band 12 px wide along each dashed edge (the design's `ghit`, GC:291), resolved through 10.4 item 9's hit lookup;
     - a 26×26 box around a marker;
     - an end stub's lead, glyph and label.
   - **Timing** (proposal accepted):
     - it opens after 380 ms, like the stack popover (GC:234). The design opens it at once (GV:755), so it flashes whenever the pointer crosses a dashed edge (prototype behaviour (iv));
     - it closes 180 ms after the pointer leaves both the target and the callout (GV:756);
     - it stays open while the pointer is on it.
   - **Placement:** 18 px right of the target point, flipped left near the right edge (GG:154; GV:895), inside the canvas, above the cards and the gutter. It yields to pans and drags (the Epic 10 header, decision (d)).
   - **Content** (GG:147-172), without a count:
     - the title: "Commits hidden between these changes", "A hidden merge sits below this change", or, for a Missing edge, "History continues outside this revset";
     - the chain:
       - the child's row: the change id (2 bold + 4), the subject, and the member count when the child is a stack;
       - the glyph with "Hidden commits", or "Older history not shown" for a Missing edge;
       - the ancestors' rows. For a Missing edge instead the hidden parent's id, with "parent, not in revset" in italic;
     - the design's description per kind (GG:168-172);
     - the button "Show in `all()`" with the hint "switches revset · centers here".
   - **Data:** the rows read 10.11's content cache. The hidden parent of a Missing edge lies outside the revset; its change id comes from `show` by commit id (Story 9.6).
   - **Pans** (proposal accepted): a press on a band still starts 10.1's pan, and only the callout blocks one. The design excludes the bands from panning (GV:791; prototype behaviour (v)), which makes every dashed edge a dead zone.
6. **"Show in `all()`"** (GV:757-762; GC:311-312).
   - **Request.**
     - One `show` of the child (Story 9.6) gives its real parents. It goes through the `GraphSource` port, where 10.8 adds `show`; if this story lands first, it adds `show` and exports `ShowEntry` and `Change`.
     - The layout request switches the revset to `all()` (10.5).
     - It carries in `keepOpenKeys` the parents that the old layout lacks, so the stack that holds the hidden parent opens in the same relayout (10.17 item 6).
   - **Reveal** (10.5 item 6's precedence, rank 1), resolved on the new layout:
     - the hidden parent from which the edge's target is reached through commits the old revset hid;
     - for a Missing edge, its target.

     A reveal key that ends up inside a collapsed stack reveals that stack card, as the design does (GV:737).
   - **Flash:** every commit the gap hid gets the design's flash.
     - Look: an accent ring, 2 px plus 6 px at 25 %, held for the first 35 % of 2.4 s and then faded out (GC:311-312).
     - It is paint-only, on 10.6 item 12's per-key ticker and overlay layer.
     - Under reduce motion the ring shows for 2.4 s without fading.
     - A collapsed stack with a flashed member flashes as one card.
   - **Which commits** the view model derives without a backend call:
     - the nodes of the new layout that the old layout lacked and that lie on a path from the child to the edge's target through such nodes only;
     - for a hidden merge, the paths to every target of the group;
     - for a Missing edge, every such ancestor of its target, capped at 10,000 (proposal). Beyond the cap only the reveal remains.
7. **The toolbar legend** (GG:182-203; GC:313-321), right after 10.7's revset select (GV:366).
   - **Chip:** a small dashed glyph and "N gaps" ("1 gap"), 11 px mono `--text-faint`, hidden when N = 0. N counts gaps as the design does (GV:838): one per Indirect edge, a hidden merge once, plus one per Missing edge.
   - **Popover:** hover or focus opens it after 200 ms (GC:317). It shows:
     - the title "This revset hides part of the history";
     - three rows with glyphs: Solid "direct parent", Dashed "commits in between are hidden · N×", End "older history isn't in the revset · M×";
     - the line "Stacks never span a gap. Hover a marker for details.";
     - the button "Show `all()`", a plain revset switch; 10.5 re-centres on @.
   - **Semantics** (proposal): the chip is a button labelled "N gaps", and its popover text is readable. Markers and stubs add no semantics nodes.
8. **`GraphLayout` accessors** (10.1 item 2's rule): the edge kind, `parentCountOf`, and the Missing edges per node with their target commit ids (added if the contract lacks them). They read the recordings now and 4.10's topology after 10.12.
9. **Recordings** (10.1 item 13): the design sample at `e243dd2` (52 commits) in both revsets.
   - Its `inDefault` flags stand in for a narrower revset such as `mine()`, because jj's `builtin_log()` would show the hidden mutable commits (prototype defect 24).
   - It holds every case of the study: a stack beside a gap, a single card between two stacks, a hidden merge with two dashed edges, a merge with one visible and one Missing parent, a fork behind a gap, and @'s lineage through a gap (@ on `mxnztwqp`, as GS:26-31 set it).

**Non-goals.**
- Counts of hidden commits, the "Count" link and the design's "Show hidden count" toggle (decision (b)).
- The marker families Dots and Pill.
- A backend call for gap details.
- Edge selection, editing, and drop zones on edges (10.10).
- Animating the reveal beyond the flash. 10.20 animates operations and stacks only.

**Depends on.**
- 10.4: dashed edges, cuts as split subpaths, the hit lookup, the run indexes.
- 10.6: the hover-callout controller, the focus path, item 12's ticker.
- 10.5: the revset switch, the reveal precedence, `keepOpenKeys`.
- 10.7: the toolbar.
- 10.11 for the rows' content, and 10.8's `show` (or this story's own).
- Real data: 10.12, with 4.10's edge kinds and `parent_count`.

**Design status.** The export gives the direction (cited at `e243dd2`); Ralph's decisions and the accepted proposals are above. Proposed at build time: the legend glyphs' sizes and the callout's width (the design's 320 px, GC:296).

**Witnesses.**
- **Painting** (`paints` matcher) on the `e243dd2` recording: every Indirect edge carries one `//` with its cut, a hidden merge one per edge, and every Missing edge a stub with "~ elided".
- **The 24 px rule**, on every recording and on 1,000 random windows of the scale recordings:
  - every marker keeps ≥ 24 px from every card, bend, crossing, junction, marker and stub, or is the recorded fallback with the largest minimum distance;
  - no marker sits on a shared stretch;
  - every window yields the same placement.
- **Placement cases:** a straight edge between adjacent rows gets its marker in the middle of the row gap; a branch-off with a short child vertical gets it on its bus, above a column gap.
- **Stubs:** a stub is centred without another parent edge, otherwise on the first free side slot, with its `//` 24 px under the card.
- **States:** lineage gold, hover and dim.
- **Callout:**
  - it opens after 380 ms on a band, a marker and a stub, and not when the pointer crosses a band quickly;
  - it shows the texts per kind, stays open while hovered and flips near the right edge;
  - a press on a band pans.
- **"Show in `all()`"**, on one hand-built case per kind, a hidden merge included:
  - it issues one `show` and exactly one layout request, with `all()` and the hidden parents in `keepOpenKeys`;
  - it centres the hidden parent, opens its stack, and flashes exactly the gap's commits;
  - under `disableAnimations` nothing animates.
- **Legend:** its count equals the recording's gaps (the design shows 5 on its default revset); it is hidden at 0; its popover shows the rows; "Show `all()`" re-centres on @.
- **Rebuilds:** a hover builds 0 cards.

**Related:** 10.4 (edges; its old item 5), 10.5, 10.6, 10.7, 10.8, 10.11, 10.12, 10.17, 10.20; 4.10 (edge kinds, `parent_count`), 4.13 (stacks never span a gap); the Epic 10 header, "Design update 2026-09-30".

---

### Story 10.20: Graph animations — stacks unfolding and folding, tree changes after an operation [UI]
*(Added 2026-09-30, Ralph — console session on the design update, export at `e243dd2`. Ralph tuned both animations in `Animation Show Case.html` (AS) and picked the values below. The story comes after the view's structure; earlier stories only keep the doors open, in their dated notes. The proposals below are Claude's, accepted by Ralph on 2026-09-30.)*

**Motivation.** The export adds a playground for two graph animations, with the goal "perceptible, but never in the way: quick and smooth, not hectic" (AS:56; the playground is in German):
- a commit stack unfolds and folds (AS:64);
- the tree shows what an operation changed (AS:73).

Without them, a toggle or a reload swaps the picture in one frame. The anchor keeps the viewport still, but the user has to find the change.

**Scope.**
1. **Stacks unfolding and folding** (AS "01 Stapel", AS:109-156).
   - **Ralph's values:** 250 ms, no stagger. The showcase's defaults are 280 ms and off (AS:67-68).
   - **Easing:** `cubic-bezier(.2,.8,.2,1)` (AS:134).
   - **Unfolding:**
     - the members slide from the stack's layers to their positions: the first member from the stack card, the second from the first offset layer, the rest from the second (AS:126-127; GC:228);
     - every other card slides from its old to its new position, and its edges stretch with it (AS:137-138);
     - the stack card fades out over min(150 ms, 0.6 × d) = 150 ms (AS:141-142);
     - the bracket fades in over 180 ms after 0.6 × d = 150 ms, from scaleY .9 (AS:143-144).
   - **Folding:** the reverse (AS:145-149).
     - The stack card fades in over 0.45 × d ≈ 113 ms at the end.
     - The bracket fades out over 100 ms.
     - The members are removed when the fold ends.
   - **Direction** follows from the two layouts and the anchor (10.17 item 4), without a rule of its own:
     - in `free` the newest member keeps its place and the older ones slide down, as in AS;
     - in `compact` the oldest keeps its place and the newer ones slide up, mirrored.

     Columns never change on a toggle (deviation (f), 4.13's I7), so every motion is vertical.
2. **Tree changes** (AS "02 Tree", AS:158-242).
   - **Ralph's values:** drawing speed 1.8 px/ms, fade-out 600 ms, blur 16 px, rise 16 px. The showcase's defaults are 1.8 px/ms, 240 ms, 6 px and 8 px (AS:79-82).
   - **Trigger** (proposal accepted): every reload that brings a new operation (10.5 item 3), whether from Zanshin's own verb (10.9) or an external `jj`. Revset, layout-mode, card-size and Detailed switches do not animate.
   - **Identity** (AS:177, :204-206).
     - A node is kept when its key (10.1 item 2), column, row and parent keys are the same in both layouts. Otherwise its old self leaves and its new self arrives.
     - An edge is kept when its child and its parent are kept.
     - A `describe` therefore animates nothing: the node stays, and only its content updates.
   - **Leaving parts** (AS:210-212, :219): the old layout's leaving cards and edges move to an overlay layer. Over 600 ms it fades to 0, blurs to 16 px and rises 16 px, with easing `cubic-bezier(.4,0,.2,1)`.
   - **Arriving parts** (AS:220-238) start at t0 = 300 ms, half the fade-out, or at once if nothing leaves.
     - A new edge is drawn from its parent at 1.8 px/ms, linear, once its parent is ready: a kept node at t0, a new node when its trace ends.
     - A new card starts when its first incoming edge arrives.
       - **Outline:** it is traced from the entry point (bottom centre) along both sides to the exit point (top centre, where every edge leaves: the Epic 10 header, decision 5), at the same speed. The stroke is 1 px `--border-strong`, or 1.25 px `--co` on @ (AS:44-46). The card's own border stays hidden while tracing (AS:47).
       - **Content:** it fades in over max(0.8 × td, 120 ms), starting at 0.3 × td, with the text line rising 3 px (AS:233-234).
       - **Trace strokes:** they fade out over 160 ms, starting 80 ms after the trace ends (AS:232).
     - A new edge between two kept nodes is drawn from t0.
   - **@** (AS:239, :49-50): when @ moves to a kept card, its @ badge pops at t0 (200 ms, from scale .4, `cubic-bezier(.3,1.4,.5,1)`). Kept edges switch their lineage style at t0.
3. **Limits** (proposals accepted).
   - Only what intersects the viewport (plus the cache extent) animates; changes elsewhere apply at once.
   - **A cap on the total duration** (proposal 1.5 s, tuned in the demo host). A longer chain is drawn faster. Above a node count (proposal 30 arriving cards in view), the arriving parts fade in together without tracing.
   - A new transition finishes the running one at once (AS:201).
   - Under reduce motion (`MediaQuery.disableAnimations`) nothing animates, as with 10.6 item 12's pulse.
   - Scrolling and panning continue during a transition; hover callouts open only after it.
4. **Rebuild discipline.** Paint-only on tickers, like 10.6 item 12's pulse. Leaving and arriving cards build once, when they mount or unmount; kept cards build 0 times.
5. **Demo host:** a "slow motion ×5" switch (`timeDilation`), as in AS:58.

**Non-goals.**
- Animated revset, layout-mode, card-size or Detailed switches.
- Sliding kept nodes that changed row or column in a tree change: by the showcase's rule they leave and arrive.
- Animated scrolling (10.6's reveal decisions stand).

**Depends on.**
- 10.1: transition rendering.
- 10.3: the card's paint parameters.
- 10.4: partial strokes and edge identity.
- 10.5: old and new layout per reload and per toggle.
- 10.17: stacks.
- 10.9 and 10.12 for real triggers.

**Design status.** The showcase gives the values Ralph picked. The limits and the trigger set are Claude's proposals, accepted on 2026-09-30.

**Witnesses.**
- **Stacks**, on a stack recording:
  - each member starts at its layer, and each kept card ends at its new position;
  - the stack card and the bracket fade with the given timings;
  - nothing moves sideways, and `pumpAndSettle` completes after 250 ms plus the fades;
  - in `compact` the newer members slide up, in `free` the older ones slide down, and the anchored member does not move.
- **Tree changes**, between two recordings (a rebase, an abandon and a `jj new`, like AS's steps; AS:165-169):
  - exactly the changed nodes leave and arrive, and the kept ones are untouched;
  - the arrival order follows the edges, and the timings match the values above;
  - a `describe`-like change (same keys, positions and parents) animates nothing.
- **Limits:** the cap and the count limit hold on a large synthetic change; reduce motion shows the end state at once; a second transition finishes the first.
- **Rebuilds:** kept cards build 0 times during a transition.

**Related:** 10.1, 10.3, 10.4, 10.5, 10.9, 10.17; 10.6 item 12 (the pulse's ticker and reduce-motion rule); the Epic 10 header, "Design update 2026-09-30".

---
