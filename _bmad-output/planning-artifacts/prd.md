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
  OD-2-license: Apache-2.0
  OD-3-update-mechanism: Sparkle
  OD-4-mcp-tool-surface: read-and-write
  OD-5-homebrew-cask: later
  OD-6-snapshot-fallback: pure-watchman
  OD-8-dart-license-tool: pana
  OD-9-tree-sitter-grammars: [rust, dart, typescript, javascript, python, markdown, toml, yaml, json, html]
  OD-10-mcp-resources: tools-only-in-0.1
performanceTargets:
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
**Date:** 2026-05-15
**Status:** Draft (slim path)
**Scope:** Rust workspace + FFI + MCP server + build/distribution

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

Sub-criteria:

- All JJ operations the author needs in daily work are reachable through `zanshin-ffi`'s `extern "C"` API.
- The MCP binary exposes the same operations (read + write per OD-4) over the MCP protocol and is usable from Claude Desktop without GUI involvement.
- A single command (`cargo make build`) produces a signed, notarized, ready-to-distribute `.app` bundle (Flutter shell stays minimal until Ralph fills it in).

Adoption, stars, contributors — welcome side-effects, none required.

---

## 3. Scope

### 3.1 In Scope

**Cargo workspace (Rust)**
- `zanshin-jj` — Adapter crate over `jj-lib`. Anti-corruption layer that shields the rest of the workspace from jj-lib's pre-1.0 API churn. Plain `lib` crate.
- `zanshin-ffi` — The single `cdylib` crate. Re-exports `extern "C"` API of all internal crates. Dart Hooks build only this crate.
- `zanshin-diff` — Word-level diff with syntax highlighting (`imara-diff` + `tree-sitter-highlight`). Plain `lib` crate. Output: structured JSON.
- `zanshin-graph` — DAG lane-assignment for commit-graph rendering. Plain `lib` crate. Output: structured JSON.
- `zanshin-mcp` — Standalone Rust binary using `rmcp`. Depends on `zanshin-jj`. Spawned by MCP hosts via stdio.
- Future crates (e.g. `zanshin-crypto` for signing) follow the same pattern: plain `lib`, re-exported through `zanshin-ffi`.

**FFI surface**
- C ABI via `extern "C"` functions in `zanshin-ffi`
- Opaque pointer types for repository / change / operation handles
- Primitives and JSON strings for data that crosses the boundary (no C struct mapping for complex types)
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

**Build orchestration**
- `cargo-make` with `Makefile.toml` as the single entry point
- Targets: `cargo make build`, `cargo make test`, `cargo make sign`, `cargo make notarize`, `cargo make release`
- Dart Hooks (`native_toolchain_rust`) wired into Flutter build
- Generated code (`ffigen`, `cbindgen`) committed, not regenerated at build time
- Reproducible builds: same source + same toolchain = byte-identical artefacts (modulo signature)

**Distribution & release engineering**
- Apple Developer ID codesigning
- Notarization via `notarytool`
- Sparkle-based auto-update with signed appcast served from GitHub Releases
- GitHub Releases as primary distribution channel (Homebrew Cask deferred per OD-5)
- License compliance CI check (`cargo-deny` + Dart-side equivalent)
- Crash logs written **locally only** to `~/Library/Logs/Zanshin/` (no upload)

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
- **No MVP / "good enough for now" tier.** Every shipped piece is production-grade.
- **No telemetry.** None, ever.

### 3.3 Deferred (explicit "maybe later")

- AST-level structural diff (difftastic class) — `zanshin-diff` stays at word-level + syntax-highlight (Delta class).
- Multi-platform builds — revisit if a contributor adopts non-mac maintenance.
- Homebrew Cask — ship after 0.1 stabilises (OD-5 = later).
- Additional MCP transports (HTTP/SSE) — stdio only initially.
- Extra crates (`zanshin-crypto` for signing keys, etc.) — designed-for but not built initially.

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
| FR-JJ-12 | Conflict ops: report conflict files in a change; call `jj resolve` after external edit. | P0 |
| FR-JJ-13 | Remote ops: `git fetch` and `git push` with progress callbacks. | P0 |
| FR-JJ-14a | Op-log op: `undo`. | P0 |
| FR-JJ-14b | Op-log ops: `op restore`, op-diff. | P2 |
| FR-JJ-15 | Settings access: read/write `user.email`, `user.name`, signing key config, defaults. | P1 (global jj config picks up most defaults) |
| FR-JJ-16 | Abstraction stability: any jj-lib API change is absorbed inside `zanshin-jj` — the public API of `zanshin-jj` itself stays stable as far as practical, so the FFI surface doesn't churn. | P0 (architectural invariant) |

### 4.2 `zanshin-diff` — Diff Engine
| FR | Description | Priority |
|----|-------------|----------|
| FR-DF-1 | Compute line-level hunks for a change (delegate to jj-lib), then enrich with word-level diff inside changed lines using `imara-diff` (Histogram algorithm). | P0 |
| FR-DF-2 | Emit syntax-highlight metadata per token using `tree-sitter-highlight`. Language detection from file extension; fallback to plain text for unknown extensions. | P0 |
| FR-DF-3 | Output: structured JSON. Hunks → lines → segments. Each segment has `kind` (Equal / Added / Removed) and optional `syntax_class`. | P0 |
| FR-DF-4 | Diff between any two revisions (revset-resolved). | P0 |
| FR-DF-5 | Bundled tree-sitter grammars (initial Kern-Set, ~9): **Rust, Dart, TypeScript/JavaScript, Python, Markdown, TOML, YAML, JSON, HTML**. Unknown extensions fall back to plain text. Additional grammars added on demand. | P0 |

### 4.3 `zanshin-graph` — Commit-Graph Lane Assignment
| FR | Description | Priority |
|----|-------------|----------|
| FR-GR-1 | Compute lane assignment for the full DAG using jj-lib's `default_index` / `dag_walk`. Strategy: "straight branches" (pvigier-style). | P0 |
| FR-GR-2 | Output: structured JSON. Rows with `lane`, `edges_below`, `color_idx`. | P0 |
| FR-GR-3 | Full lane-cache computed on repo-open and on every `op_heads` change. | P0 |
| FR-GR-4 | Render-slice API: given a row range, return the slice of rows in O(slice-size). | P0 |
| FR-GR-5 | Performance: a 10k-commit repo produces a full lane-cache in < 1s (sub-budget of NFR-P-1's < 2s repo-open). | P0 |
| FR-GR-6 | Checkpoint-caching for very large repos (kicks in beyond the 10k-commit baseline NFR-P-1 covers). Deferred to a later milestone. | P2 |

### 4.4 `zanshin-ffi` — FFI Surface (cdylib)
| FR | Description | Priority |
|----|-------------|----------|
| FR-FFI-1 | Single cdylib crate that re-exports `extern "C"` API of all internal crates. Dart Hooks build only this crate. | P0 |
| FR-FFI-2 | Opaque handle types: repository handle, change-iterator handle, operation handle. Lifetime managed via `extern "C"` constructor/destructor pairs. | P0 |
| FR-FFI-3 | JSON-serialized data for complex types crossing the boundary. No C struct mapping for graphs / diffs / change-metadata. | P0 |
| FR-FFI-4 | Async signals from Rust to Dart via `NativeCallable.listener`. Same mechanism for filesystem-watcher events and progress notifications. | P0 |
| FR-FFI-5 | `notify-rs` watcher subsystem inside `zanshin-ffi`: watches `.jj/repo/op_heads/heads/` (primary) and `.jj/repo/working_copy/checkout` (heartbeat). | P0 |
| FR-FFI-6 | Watcher-event latency: from `op_heads` filesystem mutation to Dart callback invocation < 100ms (aligned with NFR-P-4 / FR-RX-1). | P0 |
| FR-FFI-7 | Watchman-availability check API: callable from Dart at repo-open time. Returns: installed? configured in `.jj/repo/config.toml`? `register-snapshot-trigger` set? | P0 |
| FR-FFI-8 | Progress callback contract: long-running ops (fetch, push, large diffs, lane-cache rebuilds) accept a `NativeCallable.listener` and emit `{operation, progress, message}` events. | P0 |
| FR-FFI-9 | Error model: every `extern "C"` function returns either success-with-handle or a structured error code + message. No panics across the FFI boundary (Rust panics are caught and converted to errors). | P0 |
| FR-FFI-10 | Versioning: `zanshin_ffi_version()` returns the build's exact version + git SHA — required for Dart-side compatibility check at startup. | P0 |

### 4.5 `zanshin-mcp` — MCP Server Binary
| FR | Description | Priority |
|----|-------------|----------|
| FR-MCP-1 | Standalone Rust binary using `rmcp`. Shares `zanshin-jj` crate (no FFI involved on the MCP side — direct Rust API usage). | P0 |
| FR-MCP-2 | Stdio transport. Spawned by MCP hosts (Claude Desktop, etc.). | P0 |
| FR-MCP-3 | Read tools: `status`, `log`, `show <rev>`, `diff <rev>`, `op_log`, `bookmarks`, `remotes`. | P0 |
| FR-MCP-4 | Write tools: `describe`, `new`, `edit`, `abandon`, `split`, `squash`, `rebase`, `undo`, bookmark CRUD, `git fetch`, `git push`. | P0 (OD-4 = read+write) |
| FR-MCP-5 | Tool descriptions accurate enough that an LLM-driven host picks correctly without trial-and-error. Every tool has a concrete one-line description + parameter docs + a usage example. | P0 (quality gate) |
| FR-MCP-6 | Structured-data resources: revset → JSON (for hosts that prefer reading resources over calling tools repeatedly). | P1 (deferred to 0.2 per OD-10 — tools-only initially) |
| FR-MCP-7 | Bundled inside `Zanshin.app` (`Contents/Resources/zanshin-mcp` or platform-appropriate location). Path documented for MCP-host config. | P0 |
| FR-MCP-8 | Standalone usability: `zanshin-mcp` works as a CLI binary independent of the GUI. Allows manual MCP-protocol testing and embedding in non-bundled environments. | P0 |
| FR-MCP-9 | Same-repo concurrency: when GUI and MCP server operate on the same repo simultaneously, mutations from one are reflected in the other via the filesystem-watcher path. No IPC, no locking choreography. | P0 (architectural) |

### 4.6 Build Orchestration
| FR | Description | Priority |
|----|-------------|----------|
| FR-BO-1 | `cargo make build` produces a complete, signed, notarized `.app` bundle in `dist/`. Single command, no manual steps. | P0 |
| FR-BO-2 | `cargo make test` runs Rust workspace tests + Dart-bootstrap tests + license compliance check. | P0 |
| FR-BO-3 | `cargo make sign` and `cargo make notarize` as separate explicit targets (for cases where build is in-place but signing creds are restricted). | P0 |
| FR-BO-4 | `cargo make release` orchestrates: build → sign → notarize → assemble Sparkle appcast entry → tag git release → upload to GitHub Releases. | P0 |
| FR-BO-5 | Dart Hooks (`native_toolchain_rust`) integrate so Flutter's normal build flow ("flutter build macos") picks up the Rust artefact correctly. | P0 |
| FR-BO-6 | Generated code (`ffigen` output, `cbindgen` headers) is committed to the repo. Build does NOT regenerate; a separate target `cargo make codegen` does. | P0 |
| FR-BO-7 | Toolchain pinned: `rust-toolchain.toml` for Rust, Flutter/Dart versions documented at repo root. CI pulls exactly these versions. | P0 |
| FR-BO-8 | Reproducibility: two builds of the same SHA on different machines produce byte-identical artefacts (modulo codesignature). Verified by a CI job that builds twice and diffs. | P0 |

### 4.7 Distribution & Release
| FR | Description | Priority |
|----|-------------|----------|
| FR-DR-1 | Apple Developer ID codesigning of every binary (`.app`, embedded `zanshin-mcp`, Rust dylib). Certificate handling in CI does not leak secrets. | P0 |
| FR-DR-2 | Notarization via `notarytool`. Build fails if notarization fails. Stapled receipt embedded in distributed `.app`. | P0 |
| FR-DR-3 | Sparkle-based auto-update. Signed appcast (`appcast.xml`) hosted on GitHub Pages (or equivalent), points at GitHub Releases artefacts. | P0 |
| FR-DR-4 | Update check sends no user / repo identifying data. User-Agent only. No analytics. | P0 (privacy) |
| FR-DR-5 | GitHub Releases as primary distribution channel. Tag → CI auto-publishes release with `.app.zip` + (optional) `.dmg` + checksums + appcast update. | P0 |
| FR-DR-6 | Homebrew Cask: deferred. (OD-5) | P2 |

### 4.8 Reactivity (cross-cutting)
| FR | Description | Priority |
|----|-------------|----------|
| FR-RX-1 | `.jj/repo/op_heads/heads/` change → Dart callback fires within < 100ms. | P0 |
| FR-RX-2 | External file edit → Watchman → jj auto-snapshot → new op → op_heads change → callback. End-to-end latency < 500ms. | P0 |
| FR-RX-3 | MCP-server mutation → same filesystem-mutation path → same callback. GUI consumers of the FFI see no difference between GUI-origin, MCP-origin, or external-CLI-origin changes. | P0 |
| FR-RX-4 | Watcher recovers cleanly from temporary FS disturbances (network drives unmounting, Time Machine snapshots, etc.) without process restart. | P0 |

---

## 5. Non-Functional Requirements

### 5.1 Performance
| NFR | Target |
|-----|--------|
| NFR-P-1 | Repo open (incl. full lane-cache computation, op-log read) for a 10k-commit repo: **< 2s** |
| NFR-P-2 | `zanshin-graph` render-slice API: O(slice-size), no scan of the full lane-cache per call |
| NFR-P-3 | `zanshin-diff` JSON output for a 5k-line changed file: **< 500ms** |
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
- **Project license:** Apache-2.0 (OD-2 — for the patent grant).
- **Dependency policy:** Permissive only — MIT, BSD-2/3, Apache-2.0, MPL-2.0, Unlicense, CC0. Excluded: GPL (any), AGPL, LGPL, SSPL, custom non-OSI licenses.
- **Enforcement:** `cargo-deny` for Rust, `pana` for Dart pub dependencies (parses each package's license metadata). CI fails on any forbidden license.
- **Watchman:** runtime system dependency (not bundled), so its MIT license is informational only.

### 5.5 Distribution & Update
- Codesigning: Apple Developer ID Application certificate. Stored as encrypted secret in CI. Never logged.
- Notarization: every release passes `notarytool` before publish.
- Update mechanism: Sparkle 2.x (OD-3). Appcast signed; auto-update on user confirmation only (no silent installs).
- Versioning: SemVer (`MAJOR.MINOR.PATCH`). 0.x while pre-1.0; post-1.0 implies API/behaviour stability commitments for the `zanshin-ffi` extern "C" API and the MCP tool surface.

### 5.6 Build & Reproducibility
- One command: `cargo make build`. CI runs the same command.
- Generated code committed (FR-BO-6).
- Toolchain pinned (FR-BO-7).
- Cross-machine reproducibility verified by CI (FR-BO-8).

### 5.7 Supportability
- First-run / repo-open: Zanshin detects missing Watchman or missing jj-fsmonitor config and exposes the result via `extern "C"` API for the UI to render an install/setup dialog (FR-FFI-7).
- Diagnostics API: `extern "C"` function returns a structured JSON with jj-lib version, Watchman version, app version, OS version, repo path summary — clipboard-copyable for issue reports.
- Crash on launch produces a local log in `~/Library/Logs/Zanshin/` (5.3).

### 5.8 Stability of FFI Contract
- The `extern "C"` API of `zanshin-ffi` is the *external* contract; once 1.0 ships, breaking changes require a major version bump.
- jj-lib's API churn is absorbed inside `zanshin-jj` (FR-JJ-16). The rest of the workspace and the FFI surface do not see jj-lib API changes directly.

---

## 6. Open Decisions

| # | Decision | Status | Resolution |
|---|----------|--------|------------|
| OD-2 | Project license | ✅ Resolved | **Apache-2.0** |
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

Eight epics. Sequencing reflects dependency, not strict time order.

1. **Epic A — Workspace & Build Foundation**
   Cargo workspace skeleton, all five crates created as stubs (`zanshin-jj`, `zanshin-ffi`, `zanshin-diff`, `zanshin-graph`, `zanshin-mcp`). `cargo-make` Makefile.toml with `build`/`test`/`codegen` targets. Flutter project initialised with `native_toolchain_rust` Dart Hook wired. ffigen + cbindgen chain operational. CI green on empty bindings + license check. Toolchain pinned.

2. **Epic B — `zanshin-jj` Adapter & Read Path**
   Repository open, status, revset queries, change-metadata read, op-log read, bookmarks read, remotes read. Adapter API stable enough that the public surface won't change as jj-lib churns. Tests against fixture repos.

3. **Epic C — `zanshin-ffi` & Watcher**
   Opaque handles + JSON-serialized data crossing the FFI boundary. `notify-rs` watcher on `op_heads` + `working_copy/checkout`. `NativeCallable.listener` callback infrastructure for FS events and progress notifications. Error model (no panic crossings). Watchman-availability detection API. Diagnostics API. End-to-end test: filesystem mutation triggers Dart callback in the bootstrap.

4. **Epic D — `zanshin-graph`**
   Lane-assignment algorithm on jj-lib's `default_index` / `dag_walk`. Full lane-cache on repo-open and on `op_heads` change. Render-slice API. JSON output. Performance test against 10k-commit fixture.

5. **Epic E — `zanshin-diff`**
   `imara-diff` integration for word-level breakdown. `tree-sitter-highlight` integration for syntax classes. JSON output schema. Initial set of bundled grammars (OD-9). Performance test against 5k-line fixture.

6. **Epic F — `zanshin-jj` Write Path & `extern "C"` Exposure**
   `describe`, `new`, `edit`, `abandon`, `split`, `squash`, `rebase`, `undo`, bookmark CRUD, `git fetch`, `git push` with progress callbacks. Conflict-resolve handoff. All exposed through `zanshin-ffi`.

7. **Epic G — `zanshin-mcp` Binary**
   `rmcp`-based server, stdio transport. Read tools + write tools. Tool descriptions and parameter docs at LLM-quality. Bundled into `Zanshin.app`. End-to-end test with `mcp-tester` and a smoke test with Claude Desktop. Same-repo concurrency verified.

8. **Epic H — Distribution & Release Engineering**
   Apple Developer ID codesigning in CI. Notarization. Sparkle appcast generation and hosting. GitHub Releases automation on tag. License-compliance CI step (`cargo-deny` + Dart-side, OD-8). Reproducibility verification job (two-build diff). 0.1.0 release.

> **Dart-side bootstrap** (long-running worker isolate, FFI handle management, command-bus) belongs in Epic C — the minimum viable substrate the UI plugs into.

---

## 8. Reference Documents

- [`research/technical-zanshin-jj-flutter-dart-hooks-mcp-research-2026-05-15.md`](./research/technical-zanshin-jj-flutter-dart-hooks-mcp-research-2026-05-15.md) — **authoritative architecture and technology decisions**. This PRD references it.
- `~/.claude/projects/.../memory/project_zanshin.md` — auto-memory snapshot of the 12 validated architectural decisions (2026-05-15).
- [JJ official docs](https://docs.jj-vcs.dev/latest/) — JJ feature semantics and Watchman setup.
- [jj-vcs/jj#6646](https://github.com/jj-vcs/jj/discussions/6646) — jj-maintainer recommendation on watch paths.
- [JayJay reference implementation](https://github.com/hewigovens/jayjay) — referenced for adapter-crate pattern.
- [Sparkle 2 documentation](https://sparkle-project.org/documentation/) — auto-update integration reference.
