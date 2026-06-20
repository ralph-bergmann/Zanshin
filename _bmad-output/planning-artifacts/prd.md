---
stepsCompleted: ['step-01-init', 'step-02-discovery', 'slim-path-drafted', 'scope-rust-only-rewrite', 'todos-resolved']
inputDocuments:
  - _bmad-output/planning-artifacts/research/technical-zanshin-jj-flutter-dart-hooks-mcp-research-2026-05-15.md
  - .claude/projects/-Users-ralph-bergmann-development-projects-privat-Zanshin/memory/project_zanshin.md
workflowType: 'prd'
workflowVariant: 'slim'
documentCounts:
  briefs: 0
  research: 1
  brainstorming: 0
  projectDocs: 0
classification:
  projectType: rust_workspace_with_ffi
  parentProject: zanshin_flutter_macos_app
  domain: developer_tooling_vcs
  domainComplexity: low
  technicalComplexity: high
  projectContext: greenfield
  distribution: [open_source, distributed_binary]
  primaryComponents:
    - zanshin_ffi_cdylib
    - zanshin_jj_adapter_crate
    - zanshin_diff_crate
    - zanshin_graph_crate
    - zanshin_mcp_binary
    - build_orchestration
decisionsResolved:
  OD-2-license: MIT
  OD-3-update-mechanism: Sparkle
  OD-4-mcp-tool-surface: read-and-write
  OD-5-homebrew-cask: later
  OD-6-snapshot-fallback: pure-watchman
  OD-8-dart-license-tool: pana
  OD-9-tree-sitter-grammars: [rust, dart, typescript, javascript, python, markdown, toml, yaml, json, html]
  OD-10-mcp-resources: tools-only-in-0.1
performanceTargets:
  # WIP: design targets only — no CI perf-gate enforcement while scope is still moving
  repo-open-10k-commit: <2s
  zanshin-diff-5k-line-file: <500ms
  watcher-op-heads-callback: <100ms
  external-edit-end-to-end: <500ms
  ffi-handle-overhead: <1ms
slimPathSkippedSteps:
  - step-02c-executive-summary
  - step-03-success
  - step-04-journeys
  - step-05-domain
  - step-06-innovation
  - step-07-project-type
slimPathRationale: >
  Solo OSS / personal-tool project. Author is the user. Success criterion is daily personal use.
  Marketing-style ceremony (exec summary, vision-as-deliverable, personas, market success metrics)
  is dead weight. Substance-only path is sufficient input for architecture / epic-breakdown /
  dev-story workflows downstream.
scopeBoundary: >
  This PRD covers the Rust workspace + FFI + MCP server + build/distribution infrastructure ONLY.
  Flutter UI development (widgets, layout, navigation, theming, UX terminology, accessibility,
  i18n) is explicitly OUT OF SCOPE and is built by the author separately. FRs here describe the
  API surface that a future UI (or MCP client) will consume.
---

# Product Requirements Document — Zanshin (Backend & Infrastructure)

**Author:** Ralph
**Date:** 2026-05-15 (WIP-scope rework: 2026-05-17)
**Status:** Draft (slim path, WIP)
**Scope:** Rust workspace + FFI + MCP server + build (unsigned). Distribution/release pipeline deferred — see Section 4.7.

---

## 1. Project Context

Zanshin's user-facing form is a macOS-native Flutter desktop GUI client for [JJ VCS (Jujutsu)](https://github.com/jj-vcs/jj) with a bundled MCP server binary. This PRD covers everything **except** the Flutter UI itself:

- A Cargo workspace with `zanshin-jj` (jj-lib adapter), `zanshin-ffi` (cdylib bridge), `zanshin-diff` (word-level diff + syntax-highlight), `zanshin-graph` (DAG lane-assignment) and future crates
- A `zanshin-mcp` Rust binary using `rmcp`, sharing the workspace crates
- Build orchestration with `cargo-make`, Dart Hooks integration via `native_toolchain_rust`, generated FFI bindings via `cbindgen` + `ffigen` (committed)
- Codesign / notarization / Sparkle-based auto-update / GitHub-Releases automation
- A minimal Dart-side bootstrap (long-running worker isolate, FFI handle management) — *just enough* for the author's UI to plug in later; no widgets, no layout

The Flutter UI (graph painter widget, diff viewer, navigation, theming, terminology choices, accessibility) is **Ralph's own work, outside this PRD's scope**.

**Authoritative reference documents** (do not duplicate here):
- Technical research: [`research/technical-zanshin-jj-flutter-dart-hooks-mcp-research-2026-05-15.md`](./research/technical-zanshin-jj-flutter-dart-hooks-mcp-research-2026-05-15.md)
- Auto-memory `project_zanshin.md` — pinned versions and the 12 validated architectural decisions

---

## 2. Success Criterion

> **The Rust workspace + MCP binary + Dart-bootstrap is robust and complete enough that the author can build the Flutter UI on top of it without needing to touch the Rust side for missing functionality.**

Sub-criteria (WIP-scope):

- All JJ read operations + the P0 mutation subset (describe/new/edit/abandon/undo + `git fetch`) are reachable through `zanshin-ffi`'s `extern "C"` API.
- The MCP binary exposes the WIP tool subset over the MCP protocol and is usable as a standalone CLI without GUI involvement.
- A single command (`cargo make build`) produces an **unsigned, unnotarized** `.app` bundle suitable for local development (Flutter shell stays minimal until Ralph fills it in). Release-grade `.app` (signed, notarized, distributable) is post-WIP.

Adoption, stars, contributors — welcome side-effects, none required.

---

## 3. Scope

### 3.1 In Scope

**Cargo workspace (Rust)**
- `zanshin-jj` — Adapter crate over `jj-lib`. Anti-corruption layer that shields the rest of the workspace from jj-lib's pre-1.0 API churn. Plain `lib` crate.
- `zanshin-ffi` — The single `cdylib` crate. Re-exports `extern "C"` API of all internal crates. Dart Hooks build only this crate.
- `zanshin-diff` — Word-level diff with syntax highlighting (`imara-diff` + `tree-sitter-highlight`). Plain `lib` crate. Output: structured data (crosses the FFI boundary as FlatBuffers per [ADR-0001](../../docs/adr/0001-ffi-data-transport-flatbuffers.md)).
- `zanshin-graph` — DAG lane-assignment for commit-graph rendering. Plain `lib` crate. Output: structured data (crosses the FFI boundary as FlatBuffers per [ADR-0001](../../docs/adr/0001-ffi-data-transport-flatbuffers.md)).
- `zanshin-mcp` — Standalone Rust binary using `rmcp`. Depends on `zanshin-jj`. Spawned by MCP hosts via stdio.
- Future crates (e.g. `zanshin-crypto` for signing) follow the same pattern: plain `lib`, re-exported through `zanshin-ffi`.

**FFI surface**
- C ABI via `extern "C"` functions in `zanshin-ffi`
- Opaque pointer types for repository / change / operation handles
- Primitives (plain), lone strings (CString), and **FlatBuffers** for composite data crossing the boundary — no C struct mapping for complex types. *Amended by [ADR-0001](../../docs/adr/0001-ffi-data-transport-flatbuffers.md) — originally "Primitives and JSON strings".*
- `cbindgen`-generated C header committed to the repo
- `ffigen`-generated Dart bindings committed to the repo
- Async Rust→Dart signals exclusively via `NativeCallable.listener` (filesystem-watcher events and progress notifications use the same pattern)

**Watcher subsystem (inside `zanshin-ffi`)**
- `notify-rs` watches `.jj/repo/op_heads/heads/` (primary) and `.jj/repo/working_copy/checkout` (heartbeat)
- Watchman is a system dependency; Zanshin detects installation and the relevant `.jj/repo/config.toml` entries at repo-open time
- All watcher events deliver to Dart via `NativeCallable` callback

**MCP server binary (`zanshin-mcp`)**
- Read + write tools (per OD-4)
- Stdio transport
- Bundled inside `Zanshin.app/Contents/Resources/` (or appropriate location)
- Reusable as a standalone CLI for testing without the GUI

**Build orchestration (WIP)**
- `cargo-make` with `Makefile.toml` as the single entry point
- Targets in WIP: `cargo make build`, `cargo make test`, `cargo make codegen`
- Dart Hooks (`native_toolchain_rust`) wired into Flutter build
- Generated code (`ffigen`, `cbindgen`) committed, not regenerated at build time
- **Deferred (release phase):** `cargo make sign`, `cargo make notarize`, `cargo make release`, reproducible-builds CI

**Distribution & release engineering — DEFERRED**
- The entire Distribution & Release pipeline (codesigning, notarization, Sparkle auto-update, GitHub Releases automation, Homebrew Cask) is deferred to the release phase. See Section 4.7.
- **In scope while WIP:** `cargo-deny check advisories bans` runs in CI (security backstop). Crash logs written **locally only** to `~/Library/Logs/Zanshin/` (no upload).

**Dart-side bootstrap (minimum viable)**
- Long-running worker isolate spawned at app start via manual `Isolate.spawn` + SendPort/ReceivePort
- Worker holds FFI handles for app lifetime
- Command-bus pattern: UI sends typed messages to worker, worker dispatches FFI calls, returns results / streams events
- *No widgets, no UI, no navigation* — just the substrate Ralph will plug his Flutter UI into

### 3.2 Out of Scope (explicit non-goals)

- **No Flutter widgets, layouts, or navigation.** Ralph builds these separately.
- **No UX terminology decision.** JJ-native vs. Git-skin happens in Ralph's UI spec.
- **No accessibility work.** UI concern, out of this PRD.
- **No i18n / l10n.** UI concern.
- **No Windows / Linux build.** macOS-only.
- **No Git-only repo support.** Zanshin works against jj-init'd repos (which may use jj's Git backend).
- **No PR / MR / review tooling.** Repository hosting is the user's browser.
- **Code quality is production-grade from day one** (Clippy pedantic, structured errors, `NativeFinalizer` on every handle, schema-validated FlatBuffers in tests (typed accessors + `Verifier` per [ADR-0001](../../docs/adr/0001-ffi-data-transport-flatbuffers.md); was JSON), no shelling to `jj` CLI). **Scope/release-readiness is treated as WIP** — release infrastructure (codesigning, notarization, auto-update, reproducibility) is deferred. Breaking changes between WIP versions are allowed; callers update.
- **No telemetry.** None, ever.

### 3.3 Deferred (explicit "maybe later")

**Long-running deferrals (post-1.0):**
- AST-level structural diff (difftastic class) — `zanshin-diff` stays at word-level + syntax-highlight (Delta class).
- Multi-platform builds — revisit if a contributor adopts non-mac maintenance.
- Additional MCP transports (HTTP/SSE) — stdio only initially.
- Extra crates (`zanshin-crypto` for signing keys, etc.) — designed-for but not built initially.

**WIP-phase deferrals (planned to land at the release-phase transition):**
- Entire Distribution & Release pipeline (Section 4.7): codesigning, notarization, Sparkle auto-update, GitHub Releases automation, Homebrew Cask (OD-5).
- Reproducibility CI (FR-BO-8).
- Full license-gate (`cargo deny check licenses`) + Dart-side `pana`.
- Codegen drift CI-gate (`cargo make verify-codegen`).
- Performance budget tests (NFR-P-1..6 enforcement).
- Schema-versioning machinery (`schema_version` field, `_v2` suffixes).
- Mutating ops beyond P0 essentials: conflict ops (FR-JJ-12), `git push` (FR-JJ-13b), `split`/`squash`/`rebase` (FR-JJ-10b), bookmark CRUD (FR-JJ-11), settings R/W (FR-JJ-15), rare mutations (FR-JJ-10c), op-restore/op-diff (FR-JJ-14b).
- Watchman-availability check API (FR-FFI-7).
- Full structured diagnostics surface (beyond version-string + log-path).
- MCP: bundling into `Zanshin.app` (FR-MCP-7), LLM-quality tool-descriptions gate (FR-MCP-5 quality-bar), MCP resources surface (FR-MCP-6 / OD-10), full write-tool surface beyond `describe` + `new`.
- Dedicated same-repo concurrency test story (assertions live in the mutation smoke).

---

## 4. Functional Requirements

> **Framing:** Each FR is a behavioral requirement on a specific crate or build artefact. A future UI (built by Ralph) and the MCP server are consumers of these surfaces.

### 4.1 `zanshin-jj` — JJ Adapter Crate
| FR | Description | Priority |
|----|-------------|----------|
| FR-JJ-1 | Open repository at a given filesystem path; return opaque handle. | P0 |
| FR-JJ-2 | Initialize new repository (with optional `--git` backend). | P0 (bootstrap prerequisite — without init/clone there's nothing to query) |
| FR-JJ-3 | Clone from remote URL (delegates to jj's Git-clone via jj-lib). | P0 (bootstrap prerequisite) |
| FR-JJ-4 | Read working-copy status (changed files vs parent). | P0 |
| FR-JJ-5 | Resolve revset string → list of change IDs. | P0 |
| FR-JJ-6 | Read change metadata: ID, parents, description, author, timestamps, signed-by, conflict-state, anonymous-yes/no. | P0 |
| FR-JJ-7 | Read operation log: list of operations with timestamps and command summaries. | P0 |
| FR-JJ-8 | List bookmarks (local + remote-tracking) with their target change IDs. | P0 |
| FR-JJ-9 | List remotes with URLs. | P0 |
| FR-JJ-10a | Mutating ops — essentials: `describe`, `new`, `edit`, `abandon`. Each goes through jj-lib only — no shelling to `jj` CLI. | P0 |
| FR-JJ-10b | Mutating ops — advanced: `split`, `squash`, `rebase`. | P1 (0.2 — CLI/MCP bridges the gap) |
| FR-JJ-10c | Mutating ops — rare: `duplicate`, `restore`, `backout`. | P2 |
| FR-JJ-11 | Bookmark ops: create, move, delete, track, untrack, forget. | P1 (0.2) |
| FR-JJ-12 | Conflict ops: report conflict files in a change; call `jj resolve` after external edit. Deferred — linear add-on to the FFI mutation surface; not on the WIP build/run path. | P1 (deferred) |
| FR-JJ-13a | Remote op: `git fetch` with progress callbacks. Real consumer of the FR-FFI-8 progress-callback pattern in WIP. | P0 |
| FR-JJ-13b | Remote op: `git push` with progress callbacks. Deferred — `fetch` covers the progress-callback consumer requirement; `push` is a linear add-on later. | P1 (deferred) |
| FR-JJ-14a | Op-log op: `undo`. | P0 |
| FR-JJ-14b | Op-log ops: `op restore`, op-diff. | P2 |
| FR-JJ-15 | Settings access: read/write `user.email`, `user.name`, signing key config, defaults. | P1 (global jj config picks up most defaults) |
| FR-JJ-16 | Abstraction stability: any jj-lib API change is absorbed inside `zanshin-jj` — the public API of `zanshin-jj` itself stays stable as far as practical, so the FFI surface doesn't churn. | P0 (architectural invariant) |
| FR-JJ-17 | Repository-kind detection: classify a filesystem path as a jj workspace (`.jj/` present), a (convertible) Git repo (`.git/` present, no `.jj/`), neither, or a missing path. Read-only, stat-only, no workspace load, no mutation, no panic. Powers the open-project flow's "this is / isn't a jj / git project" feedback so the UI can decide whether to open directly, offer a conversion dialog, or report "not a repository". The backend only *classifies*; it never decides for the user. | P0 (open-project UX prerequisite) |
| FR-JJ-18a | Convert an existing Git repository to jj in-place — **colocated** mode (`.jj/` created alongside the existing `.git/`; jj and git share the store, full history preserved, the `git` CLI keeps working). Additive and reversible: deleting `.jj/` restores the plain Git repo; `.git/` is never destructively modified. Acts only on the user's explicit choice. (Note: "start fresh, ignore existing history" is **not** a conversion — it is `init` per FR-JJ-2, reused as-is.) | P0 |
| FR-JJ-18b | Convert an existing Git repository to a **jj-native** workspace via external-git import (jj leads; the existing `.git/` becomes the backing store). The second user-selectable conversion mode. | P1 (0.2 fast-follow — colocated covers the common case) |

### 4.2 `zanshin-diff` — Diff Engine
| FR | Description | Priority |
|----|-------------|----------|
| FR-DF-1 | Compute line-level hunks for a change (delegate to jj-lib), then enrich with word-level diff inside changed lines using `imara-diff` (Histogram algorithm). | P0 |
| FR-DF-2 | Emit syntax-highlight metadata per token using `tree-sitter-highlight`. Language detection from file extension; fallback to plain text for unknown extensions. | P0 |
| FR-DF-3 | Output: structured data — Hunks → lines → segments; each segment has `kind` (Equal / Added / Removed) and optional `syntax_class`. Crosses the FFI boundary as **FlatBuffers** (*amended by [ADR-0001](../../docs/adr/0001-ffi-data-transport-flatbuffers.md)*; was "structured JSON"). | P0 |
| FR-DF-4 | Diff between any two revisions (revset-resolved). | P0 |
| FR-DF-5 | Bundled tree-sitter grammars (initial Kern-Set, ~9): **Rust, Dart, TypeScript/JavaScript, Python, Markdown, TOML, YAML, JSON, HTML**. Unknown extensions fall back to plain text. Additional grammars added on demand. | P0 |

### 4.3 `zanshin-graph` — Commit-Graph Lane Assignment
| FR | Description | Priority |
|----|-------------|----------|
| FR-GR-1 | Compute lane assignment for the full DAG using jj-lib's `default_index` / `dag_walk`. Strategy: "straight branches" (pvigier-style). | P0 |
| FR-GR-2 | Output: structured data — rows with `lane`, `edges_below`, `color_idx`. Crosses the FFI boundary as **FlatBuffers** (*amended by [ADR-0001](../../docs/adr/0001-ffi-data-transport-flatbuffers.md)*; was "structured JSON"). | P0 |
| FR-GR-3 | Full lane-cache computed on repo-open and on every `op_heads` change. | P0 |
| FR-GR-4 | Render-slice API: given a row range, return the slice of rows in O(slice-size). | P0 |
| FR-GR-5 | Performance: a 10k-commit repo produces a full lane-cache in < 1s (sub-budget of NFR-P-1's < 2s repo-open). | P0 |
| FR-GR-6 | Checkpoint-caching for very large repos (kicks in beyond the 10k-commit baseline NFR-P-1 covers). Deferred to a later milestone. | P2 |

### 4.4 `zanshin-ffi` — FFI Surface (cdylib)
| FR | Description | Priority |
|----|-------------|----------|
| FR-FFI-1 | Single cdylib crate that re-exports `extern "C"` API of all internal crates. Dart Hooks build only this crate. | P0 |
| FR-FFI-2 | Opaque handle types: repository handle, change-iterator handle, operation handle. Lifetime managed via `extern "C"` constructor/destructor pairs. | P0 |
| FR-FFI-3 | Composite data for complex types crosses the boundary as **FlatBuffers** (single buffer); lone strings stay CString, scalars stay plain; no C struct mapping for graphs / diffs / change-metadata. *Amended by [ADR-0001](../../docs/adr/0001-ffi-data-transport-flatbuffers.md) — originally "JSON-serialized data".* | P0 |
| FR-FFI-4 | Async signals from Rust to Dart via `NativeCallable.listener`. Same mechanism for filesystem-watcher events and progress notifications. | P0 |
| FR-FFI-5 | `notify-rs` watcher subsystem inside `zanshin-ffi`: watches `.jj/repo/op_heads/heads/` (primary) and `.jj/repo/working_copy/checkout` (heartbeat). | P0 |
| FR-FFI-6 | Watcher-event latency: from `op_heads` filesystem mutation to Dart callback invocation < 100ms (aligned with NFR-P-4 / FR-RX-1). | P0 |
| FR-FFI-7 | Watchman-availability check API. Deferred — `notify-debouncer-full` covers the WIP watcher path; Watchman-status surfacing is release-grade UX polish. | P1 (deferred) |
| FR-FFI-8 | Progress callback contract: long-running ops accept a `NativeCallable.listener` and emit `{operation, progress, message}` events. Exercised in WIP by FR-JJ-13a (`git fetch`). | P0 |
| FR-FFI-9 | Error model: every `extern "C"` function returns either success-with-handle or a structured error code + message. No panics across the FFI boundary (Rust panics are caught and converted to errors). | P0 |
| FR-FFI-10 | `zanshin_ffi_version()` returns the build's exact version + git SHA. Used as build-stamp / diagnostics. No compatibility-negotiation logic — WIP allows breaking changes; callers update. | P0 |

### 4.5 `zanshin-mcp` — MCP Server Binary
| FR | Description | Priority |
|----|-------------|----------|
| FR-MCP-1 | Standalone Rust binary using `rmcp`. Shares `zanshin-jj` crate (no FFI involved on the MCP side — direct Rust API usage). | P0 |
| FR-MCP-2 | Stdio transport. Spawned by MCP hosts (Claude Desktop, etc.). | P0 |
| FR-MCP-3 | Read tools: `status`, `log`, `show <rev>`, `diff <rev>`, `op_log`, `bookmarks`, `remotes`. | P0 |
| FR-MCP-4 | Write tools: `describe`, `new` in WIP. `edit`, `abandon`, `split`, `squash`, `rebase`, `undo`, bookmark CRUD, `git fetch`, `git push` follow via FR-JJ-* as those land (most deferred). | P0 (subset in WIP, OD-4 = read+write) |
| FR-MCP-5 | Tool descriptions and parameter docs exist for every tool (basic discoverability). LLM-quality iteration + `mcp-tester` smoke gate deferred to release phase. | P0 (basic), deferred (quality gate) |
| FR-MCP-6 | Structured-data resources: revset → JSON. | P1 (deferred to 0.2 per OD-10) |
| FR-MCP-7 | Bundled inside `Zanshin.app`. Deferred — WIP runs `zanshin-mcp` as standalone CLI; bundling re-evaluated at release phase alongside codesigning. | P1 (deferred) |
| FR-MCP-8 | Standalone usability: `zanshin-mcp` runs as a CLI binary independent of any GUI. Allows manual MCP-protocol use without bundling. | P0 |
| FR-MCP-9 | Same-repo concurrency: when GUI and MCP server operate on the same repo simultaneously, mutations from one are reflected in the other via the filesystem-watcher path. No IPC, no locking choreography. Concurrency assertions live in the FR-JJ-10a mutation smoke (no separate concurrency-test story while WIP). | P0 (architectural) |

### 4.6 Build Orchestration
| FR | Description | Priority |
|----|-------------|----------|
| FR-BO-1 | `cargo make build` produces an unsigned, unnotarized `.app` bundle suitable for local development. Single command, no manual steps. Signing/notarization deferred — see Section 4.7. | P0 |
| FR-BO-2 | `cargo make test` runs Rust workspace tests + Dart-bootstrap tests + `cargo deny check advisories bans`. Full license-gate + `pana` deferred. | P0 |
| FR-BO-3 | `cargo make sign` / `cargo make notarize` targets. | P1 (deferred — release phase) |
| FR-BO-4 | `cargo make release` orchestration (build → sign → notarize → appcast → tag → upload). | P1 (deferred — release phase) |
| FR-BO-5 | Dart Hooks (`native_toolchain_rust`) integrate so Flutter's normal build flow ("flutter build macos") picks up the Rust artefact correctly. | P0 |
| FR-BO-6 | Generated code (`ffigen` output, `cbindgen` headers) is committed to the repo. Build does NOT regenerate; a separate target `cargo make codegen` does. CI drift-gate (`cargo make verify-codegen`) deferred — discipline rule applies during development. | P0 |
| FR-BO-7 | Toolchain pinned: `rust-toolchain.toml` for Rust, Flutter/Dart versions documented at repo root. CI pulls exactly these versions. | P0 |
| FR-BO-8 | Reproducibility (two-build SHA diff in CI). | P1 (deferred — release phase) |

### 4.7 Distribution & Release — DEFERRED

> **Status (2026-05-17):** Entire section is deferred to the release phase. WIP delivers the unsigned, unnotarized `.app` from FR-BO-1 for local development only. None of the items below are in scope for WIP.

| FR | Description | Priority |
|----|-------------|----------|
| FR-DR-1 | Apple Developer ID codesigning (`.app`, embedded `zanshin-mcp`, Rust dylib). | Deferred |
| FR-DR-2 | Notarization via `notarytool`, stapled receipt. | Deferred |
| FR-DR-3 | Sparkle-based auto-update with signed appcast on GitHub Pages. | Deferred |
| FR-DR-4 | Update-check privacy (User-Agent only, no analytics). When FR-DR-3 lands, this binding remains. | Deferred (binding when DR-3 lands) |
| FR-DR-5 | GitHub Releases automation on tag (`.app.zip` + checksums + appcast). | Deferred |
| FR-DR-6 | Homebrew Cask. | Deferred (post-0.1, OD-5) |

### 4.8 Reactivity (cross-cutting)
| FR | Description | Priority |
|----|-------------|----------|
| FR-RX-1 | `.jj/repo/op_heads/heads/` change → Dart callback fires. Latency target `< 100ms` is a soft design goal in WIP; functional pathway is asserted, no Test-Assertion on the latency bound. | P0 (functional), soft target |
| FR-RX-2 | External file edit → Watchman → jj auto-snapshot → new op → op_heads change → callback. End-to-end target `< 500ms` is a soft design goal in WIP. | P0 (functional), soft target |
| FR-RX-3 | MCP-server mutation → same filesystem-mutation path → same callback. GUI consumers of the FFI see no difference between GUI-origin, MCP-origin, or external-CLI-origin changes. | P0 |
| FR-RX-4 | Watcher recovers cleanly from temporary FS disturbances (network drives unmounting, Time Machine snapshots, etc.) without process restart. | P0 |

---

## 5. Non-Functional Requirements

### 5.1 Performance

> **WIP:** budgets below are design targets that inform algorithm choice (e.g., `imara-diff` Histogram over `similar`). They are **not** enforced by CI perf-gates while WIP. Enforcement is deferred to the release phase.

| NFR | Target |
|-----|--------|
| NFR-P-1 | Repo open (incl. full lane-cache computation, op-log read) for a 10k-commit repo: **< 2s** |
| NFR-P-2 | `zanshin-graph` render-slice API: O(slice-size), no scan of the full lane-cache per call |
| NFR-P-3 | `zanshin-diff` output (FlatBuffers per [ADR-0001](../../docs/adr/0001-ffi-data-transport-flatbuffers.md); was JSON) for a 5k-line changed file: **< 500ms** |
| NFR-P-4 | Watcher latency `op_heads → callback`: **< 100ms** (FR-RX-1) |
| NFR-P-5 | FFI handle creation/destruction overhead: negligible (< 1ms per call) so the long-running-worker pattern stays the right choice |
| NFR-P-6 | External-edit end-to-end refresh (Watchman → jj-snapshot → callback): **< 500ms** (FR-RX-2) |

### 5.2 Reliability / Correctness
- No data loss is acceptable. All mutating operations route through jj-lib via `zanshin-jj`. No shelling to `jj` CLI. No string-parsing of jj output.
- Every Zanshin-initiated mutation must be visible and reversible in `jj op log`, indistinguishably from a CLI-initiated one.
- Rust panics never cross the FFI boundary — caught and converted to error codes (FR-FFI-9).
- MCP server failures (malformed input, jj-lib errors) produce structured MCP error responses, never crash the process.

### 5.3 Privacy / Telemetry
- **No telemetry. No analytics. No phone-home. Ever.**
- No automatic crash-reporting. Crash logs are local-only (`~/Library/Logs/Zanshin/`); user shares them manually when filing issues.
- Update check (FR-DR-4) is the only outbound connection. User-Agent only; no identifying payload.
- No third-party SDKs that contradict the above (Sentry, Crashlytics, Firebase, etc. are excluded).

### 5.4 Licensing
- **Project license:** MIT (OD-2 — chosen for simplicity; solo project with no software patents to grant, so Apache-2.0's patent clause added length without benefit. Attribution (name retained) is the one condition. Relicensed Apache-2.0 → MIT 2026-06-20).
- **Dependency policy:** Permissive only — MIT, BSD-2/3, Apache-2.0, MPL-2.0, Unlicense, CC0. Excluded: GPL (any), AGPL, LGPL, SSPL, custom non-OSI licenses.
- **Enforcement (WIP):** `cargo deny check advisories bans` runs in CI (security backstop, cheap). The full license-gate (`cargo deny check licenses`) and Dart-side `pana` are deferred to the release phase.
- **Watchman:** runtime system dependency (not bundled), so its MIT license is informational only.

### 5.5 Distribution & Update — DEFERRED

> Distribution and update infrastructure (codesigning, notarization, Sparkle, GitHub Releases automation) is deferred to the release phase — see Section 4.7. While WIP, no distribution channel exists.

- Versioning posture: SemVer (`MAJOR.MINOR.PATCH`). 0.x is WIP — breaking changes allowed. Post-1.0 SemVer stability commitments for the `extern "C"` ABI and MCP tool surface are the *intent*, but the exact policy is deferred and will be revisited at release time.

### 5.6 Build & Reproducibility
- One command: `cargo make build`. CI runs the same command. WIP output: unsigned `.app`.
- Generated code committed (FR-BO-6); CI drift-gate deferred (discipline rule applies).
- Toolchain pinned (FR-BO-7).
- Cross-machine reproducibility CI (FR-BO-8) deferred to the release phase.

### 5.7 Supportability
- Diagnostics API (WIP): `extern "C"` function returns version-string + log-path as a FlatBuffers `Envelope` (per [ADR-0001](../../docs/adr/0001-ffi-data-transport-flatbuffers.md), not JSON). Full structured diagnostics (jj-lib version, Watchman state, OS, repo summary) deferred — basic version + log-path are enough to support local development.
- Crash on launch produces a local log in `~/Library/Logs/Zanshin/` (5.3).
- First-run / Watchman-detection (FR-FFI-7): deferred.

### 5.8 Stability of FFI Contract
- **WIP (0.x):** the `extern "C"` API of `zanshin-ffi`, the MCP tool surface, and the JSON schemas evolve freely. Breaking changes are allowed; callers update in the same PR. No `_v2`-suffix discipline, no in-wire `schema_version` field. The intent is that these surfaces become the external SemVer contract once 1.0 ships, but the exact policy is deferred and will be revisited at release time.
- jj-lib's API churn is absorbed inside `zanshin-jj` (FR-JJ-16). The rest of the workspace and the FFI surface do not see jj-lib API changes directly.

---

## 6. Open Decisions

| # | Decision | Status | Resolution |
|---|----------|--------|------------|
| OD-2 | Project license | ✅ Resolved | **MIT** (was Apache-2.0; relicensed 2026-06-20) |
| OD-3 | Update mechanism | ✅ Resolved | **Sparkle 2.x** |
| OD-4 | MCP tool surface | ✅ Resolved | **Read + Write** |
| OD-5 | Homebrew Cask from day one | ✅ Resolved | **Later** (post-0.1 stabilisation) |
| OD-6 | Manual snapshot button | ✅ Resolved | **Pure Watchman** (no fallback button — Watchman is mandatory) |
| OD-8 | Dart-side license compliance tool | ✅ Resolved | **pana** |
| OD-9 | Initial tree-sitter grammars to bundle | ✅ Resolved | **Kern-Set:** Rust, Dart, TS/JS, Python, Markdown, TOML, YAML, JSON, HTML |
| OD-10 | MCP resources surface (FR-MCP-6) | ✅ Resolved | **Tools-only in 0.1**, Resources in 0.2 |

> **Removed from this PRD's scope** (UI concerns): OD-1 (UI terminology), OD-7 (accessibility scope). These are decided in Ralph's UI spec, not here.

---

## 7. Epic Breakdown

Eight epics (WIP-scoped). Sequencing reflects dependency, not strict time order.

1. **Epic A — Workspace & Build Foundation**
   Cargo workspace skeleton, all five crates created as stubs. `cargo-make` Makefile.toml with `build`/`test`/`codegen` targets. Flutter project initialised with `native_toolchain_rust` Dart Hook wired. ffigen + cbindgen chain operational (manual regen). CI green on minimal gate: clippy/fmt/test/dart-analyze/dart-format/flutter-test/`cargo deny check advisories bans`. Toolchain pinned. **Deferred:** schemas-dir versioning README, full license-gate, pana, codegen drift CI-check.

2. **Epic B — `zanshin-jj` Adapter & Read Path**
   Repository open/init/clone, repo-kind detection (FR-JJ-17), colocated Git→jj conversion (FR-JJ-18a), status, revset queries, change-metadata read, op-log read, bookmarks read, remotes read. Adapter API absorbs jj-lib churn (FR-JJ-16). Tests against committed fixture repos (tiny + medium; large fixture deferred with perf-tests). **Deferred:** NFR-P-1 sub-budget allocation, API-surface-lock doc, external-git-import conversion (FR-JJ-18b → 0.2 fast-follow).

3. **Epic C — `zanshin-ffi` & Watcher**
   Opaque handles + composite data crossing the FFI boundary as FlatBuffers; AD-1 error envelope (both *amended by [ADR-0001](../../docs/adr/0001-ffi-data-transport-flatbuffers.md)* — originally JSON). AD-5 `notify-debouncer-full` watcher on `op_heads` + `working_copy/checkout`. `NativeCallable.listener` callback infrastructure for FS events and progress notifications. Error model (no panic crossings). Tracing init (file appender). Diagnostics API (version-string + log-path). Dart worker isolate bootstrap. End-to-end test: filesystem mutation triggers Dart callback (functional only — no latency assert). **Deferred:** Watchman-availability check (FR-FFI-7), full structured diagnostics, watcher latency-assertion.

4. **Epic D — `zanshin-graph`**
   Lane-assignment algorithm on jj-lib's `default_index` / `dag_walk`. On-demand lane computation per request (full persistent lane-cache deferred). Render-slice returns all lanes for revset (windowing deferred). FlatBuffers output ([ADR-0001](../../docs/adr/0001-ffi-data-transport-flatbuffers.md)). Algorithmic correctness test on ~100-commit fixture. **Deferred:** 10k-commit perf test, persistent cache + op_heads invalidation, checkpoint-caching.

5. **Epic E — `zanshin-diff`**
   Line-level hunks. Word-level breakdown via `imara-diff` (Histogram). `tree-sitter-highlight` integration. Bundled grammars: rust, dart, markdown (remaining OD-9 grammars deferred). FlatBuffers output ([ADR-0001](../../docs/adr/0001-ffi-data-transport-flatbuffers.md)). Diff between two revisions. **Deferred:** 5k-line perf test, fallback strategies, incremental highlighting.

6. **Epic F — `zanshin-jj` Write Path & `extern "C"` Exposure**
   Mutations: `describe`, `new`, `edit`, `abandon` (FR-JJ-10a). Op-log `undo` (FR-JJ-14a — wrapper on `jj op restore`). FFI mutation surface (the wrapper convention itself). `git fetch` with progress callback — real consumer of the FR-FFI-8 progress path. Two-thread concurrent-write assertions appended to the mutation smoke (Szenario-1 from the dropped E7-8 story). **Deferred:** conflict ops (FR-JJ-12), `git push` (FR-JJ-13b), `split`/`squash`/`rebase` (FR-JJ-10b), bookmark CRUD (FR-JJ-11), settings (FR-JJ-15), rare mutations (FR-JJ-10c), op-log visibility test (NFR-R-2), op-restore/op-diff (FR-JJ-14b).

7. **Epic G — `zanshin-mcp` Binary**
   `rmcp`-based server, stdio transport, file-only tracing in all build modes, repo selection (`--repo` or CWD walk-up). Read tools (status/log/show/diff/op_log/bookmarks/remotes). Write tools subset: `describe` + `new`. Tool descriptions and parameter docs exist (basic). Minimal "MCP-server boots + lists tools" smoke. Structured MCP errors (basic mapping). **Deferred:** LLM-quality iteration + `mcp-tester` smoke gate, bundling into `Zanshin.app`, standalone-CLI polish, full write-tool surface, MCP resources surface (FR-MCP-6), error-taxonomy-stability tests, dedicated same-repo concurrency test story.

8. **Epic H — Build Output (WIP)**
   `cargo make build` produces an unsigned `.app` for local development. **Entire release pipeline deferred:** codesigning, notarization, Sparkle appcast, GitHub Releases automation, reproducibility CI, Homebrew Cask. See Section 4.7.

> **Dart-side bootstrap** (long-running worker isolate, FFI handle management, command-bus) belongs in Epic C — the minimum viable substrate the UI plugs into.

---

## 8. Reference Documents

- [`research/technical-zanshin-jj-flutter-dart-hooks-mcp-research-2026-05-15.md`](./research/technical-zanshin-jj-flutter-dart-hooks-mcp-research-2026-05-15.md) — **authoritative architecture and technology decisions**. This PRD references it.
- `~/.claude/projects/.../memory/project_zanshin.md` — auto-memory snapshot of the 12 validated architectural decisions (2026-05-15).
- [JJ official docs](https://docs.jj-vcs.dev/latest/) — JJ feature semantics and Watchman setup.
- [jj-vcs/jj#6646](https://github.com/jj-vcs/jj/discussions/6646) — jj-maintainer recommendation on watch paths.
- [JayJay reference implementation](https://github.com/hewigovens/jayjay) — referenced for adapter-crate pattern.
- [Sparkle 2 documentation](https://sparkle-project.org/documentation/) — auto-update integration reference.
