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

- **FR-GR-1** (P0): Compute lane assignment for the full DAG using jj-lib's `default_index` / `dag_walk`. Strategy: "straight branches" (pvigier-style).
- **FR-GR-2** (P0): Output structured data (rows with `lane`, `edges_below`, `color_idx`), crossing the FFI boundary as **FlatBuffers** (*amended by [ADR-0001](../../docs/adr/0001-ffi-data-transport-flatbuffers.md)*; was "structured JSON").
- **FR-GR-3** (P0): Full lane-cache computed on repo-open and on every `op_heads` change.
- **FR-GR-4** (P0): Render-slice API: given a row range, return the slice in O(slice-size).
- **FR-GR-5** (P0): Performance: 10k-commit repo produces full lane-cache in < 1s (sub-budget of NFR-P-1).
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
- **NFR-P-2**: `zanshin-graph` render-slice API: O(slice-size), no full-cache scan per call.
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
| FR-JJ-14a | 6 | op-log undo (P0) |
| FR-JJ-14b | 6 | op restore + op-diff (P2 — story marked deferred) |
| FR-JJ-15 | 6 | settings read/write (P1) |
| FR-JJ-16 | 2 | Adapter-stability invariant established with read path |
| FR-DF-1 | 5 | line hunks → word-level via imara-diff |
| FR-DF-2 | 5 | tree-sitter-highlight syntax classes |
| FR-DF-3 | 5 | structured output, FlatBuffers (ADR-0001) |
| FR-DF-4 | 5 | diff between any two revisions |
| FR-DF-5 | 5 | bundled tree-sitter Kern-Set-9 grammars |
| FR-GR-1 | 4 | lane-assignment algorithm on jj-lib default_index |
| FR-GR-2 | 4 | FlatBuffers output (lane, edges_below, color_idx) — ADR-0001 |
| FR-GR-3 | 4 | full lane-cache on open + op_heads change |
| FR-GR-4 | 4 | render-slice API O(slice-size) |
| FR-GR-5 | 4 | 10k-commit lane-cache < 1s |
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

### Epic 4: `zanshin-graph` — DAG Lane Assignment

**Goal:** Compute commit-graph lane assignments for arbitrary jj DAGs and expose them as render-ready FlatBuffers (ADR-0001) via the FFI surface.

**User outcome:** A caller (FFI consumer or test) obtains lane data per request (computed on demand, in-memory) and receives a render-slice response (all lanes for the revset). An algorithmic-correctness test on a ~100-commit fixture catches dumb regressions cheaply.

**FRs covered:** FR-GR-1, FR-GR-2, FR-GR-4 (return-all-lanes form, no windowing). FR-GR-3 reduced to "compute on demand" — full persistent lane-cache with op_heads-invalidation is deferred. FR-GR-5 (perf budget) is a soft target only.

**NFRs:** None enforced in WIP (NFR-P-1 / NFR-P-2 are soft targets).

**Additional requirements anchored here:** `schemas/graph.schema.json` (no `.v1` infix in WIP).

**WIP-rework:** Story 4.5 (10k-commit perf test) deleted — algorithmic-correctness test on ~100-commit fixture absorbed into Story 4.1. Story 4.7 (P2 checkpoint caching) deleted. Story 4.3 (full lane-cache) shrunk to on-demand in-memory. Story 4.4 (render-slice) shrunk to return-all-lanes-for-revset.

**Sequencing:** After Epic 3. Parallelizable with Epics 5 and 6.

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

**FRs covered:** FR-JJ-10b, FR-JJ-10c, FR-JJ-11, FR-JJ-12 (conflict ops), FR-JJ-13b (push), FR-JJ-14b, FR-JJ-15 — plus the new operation-support layer (Story 9.1) and `eval_revset` read primitive (Story 9.2).

**Additional requirements anchored here:** AR-AP-1 + AR-AP-2 re-asserted per verb; the transaction boundary stays Rust-side (ADR-0003); each verb's `.fbs` edited in place (no `_v2`, WIP).

**Precedence / scope:** **Post-WIP-minimal build-out — scheduling is Ralph's call.** Stories are at backlog granularity; full acceptance criteria are authored per story (via bmad-create-story) when scheduled. Each verb follows the surfacing chain: `.fbs` → `zanshin-jj` typed op (tx Rust-side) → `zanshin-ffi` `extern "C"` + `cargo make codegen` → Dart `WorkerCommand` → optional MCP tool → tests (zanshin-jj integration + FFI-path Dart test for coverage attribution + Verifier + ratchet).

**Sequencing:** Step 9.0 (pin bump 0.41→0.42) precedes all operation work; Story 9.1 (operation-support layer) unblocks Tier C. Then Tier A (cheap) → Tier B (medium) → Tier C (thick) by feasibility-map thickness. Reuses Epic 6's `mutate.rs` (6.1) + FFI mutation surface (6.5) patterns; the interactive thick verbs additionally need the Flutter diff/merge editor (Ralph's UI scope) to supply a selected `TreeId`.

---

### Cross-Cutting Concerns (no dedicated epic)

These are reviewed in every epic's acceptance criteria rather than implemented once:

- **NFR-R-1, NFR-R-2** — no data loss, every mutation visible/reversible in op log. Review gate in Epics 2, 6, 7.
- **NFR-PRIV-1, NFR-PRIV-2, NFR-PRIV-4** — no telemetry, no third-party analytics SDKs. Code-review gate in every epic.
- **NFR-ST-1, NFR-ST-2** — FFI-contract stability. Inactive in WIP (0.x); breaking changes allowed. Review gate when release-phase begins.
- **AR-P-2** (snake_case JSON), **AR-P-7** (test layout), **AR-AP-3..AP-10** — enforced by tool configs and lint/CI gates set up in Epic 1; passive thereafter.

> **Sequencing recap (WIP):** Epic 1 → Epic 2 → Epic 3, then Epics 4, 5, 6 parallelizable, then Epic 7. Epic 8 is concurrent with Epic 1 (just the unsigned build target). Epic 3 (FFI Keystone) blocks all downstream epics that need the FFI envelope/handle/watcher patterns. Epic 9 (the ADR-0003 operation build-out) follows Epic 6 and is post-WIP-minimal (scheduling TBD).

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

**Given** a very large working copy (10,000+ files, none changed)
**When** `Repo::status()` is called
**Then** it returns quickly (< 100 ms on the large fixture) because jj-lib's status check leverages the index

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

## Epic 4: `zanshin-graph` — DAG Lane Assignment

Compute commit-graph lane assignments for arbitrary jj DAGs and expose render-ready FlatBuffers (ADR-0001) via the FFI surface. Hit the < 1s lane-cache budget (FR-GR-5 / NFR-P-1 sub-budget) on the 10k-commit fixture and provide O(slice-size) render-slice responses.

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

> **Delivered (2026-08-23):** `crates/zanshin-graph/src/slice.rs` ships `pub fn collect_lanes(repo: &zanshin_jj::Repo, revset: &str, prioritize: &str) -> Result<Vec<Row>, LaneStreamError>` — a collecting sink over the 4.3 `stream_lanes` stream (re-resolve to head per call, `jj log` order, `finish()` run, both parameters caller pass-throughs). There is no `LaneCache`, no `render_slice`, no `start`/`count`/`limit`/`reversed`, no paging struct and no `total_rows` field: `Vec<Row>` is the return type and the FFI `GraphSlice` builder (4.2) derives `total_rows == rows.len()`. Windowing stays deferred past WIP; a future page composes as an early-exit sink on `stream_lanes`, never a scan over held rows (ADR-0002 AC-4). The CLI's `--limit`/`--reversed` are deliberately NOT passed through (presentation/paging knobs dropped together with windowing; a consumer wanting a prefix uses `stream_lanes` + `Break`) — revisit when windowing returns. Tests: `crates/zanshin-graph/tests/slice.rs` (tiny exact rows + equality with a `stream_lanes` collection for both prioritize values, medium invariants + determinism, empty revset, parse errors incl. blank `prioritize`, resolution errors for either parameter). The `render_slice` ACs below are superseded.

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

### Story 9.1: Operation-support layer (`zanshin-jj/src/op_support.rs`)
Re-port the orchestration jj-lib does NOT expose (lives in jj-cli's `cli_util`): the immutable-heads / `check_rewritable` guard, `compute_commit_location` (insert `-A`/`-B`/`--onto`), description combination (`combine_messages` + trailers), and the `SelectedTree` plumbing that replaces the CLI's interactive `DiffSelector`. Shared by every thick verb + MCP. **Blocks Tier C.**

### Story 9.2: `eval_revset` generic read primitive + `View` read helpers (extends 2.5)
A typed `eval_revset(&str) -> Stream<Commit>` over the verified parse→resolve→evaluate path (lazy `Box<dyn Revset>`, streamed per ADR-0002, never `try_collect`-ed); plus direct `View` reads (bookmarks/tags/heads/wc) so the GUI does not route everything through revsets. Preserve the 3-stage parse/resolution/evaluation error taxonomy.

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

### Story 9.21: Operation-log surface — `op log`, `op show`, `op diff`, `op abandon`, `redo` [M/R]
`op_walk::{walk_ancestors,resolve_op_with_repo,reparent_range}` + `RepoLoader::merge_operations`; typed op entries + cross-op diff; redo stack semantics (beyond 6.2 undo).

### Story 9.22: `file track`, `file untrack` (locked-WC lifecycle) [M]
`LockedWorkingCopy::{snapshot,reset}` + `SnapshotOptions`; multi-phase reset/resnapshot reconciliation.

### Story 9.23: `workspace add`, `workspace update-stale` [M]
`Workspace::init_workspace_with_existing_repo` + sparse mutation; `WorkingCopyFreshness::check_stale` + `create_and_check_out_recovery_commit`.

### MCP exposure (cross-cut with Epic 7)
Each verb optionally gets an MCP tool (extends Epic 7's write-tools 7.4 beyond `describe`/`new`). Per ADR-0003 open questions: decide (a) whether every mutation verb gets an MCP tool immediately or reads + a core subset first, and (b) whether MCP gets the raw `eval_revset` or only named views.

---
