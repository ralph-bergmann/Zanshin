---
project_name: 'Zanshin'
user_name: 'Ralph'
date: '2026-05-15'
last_revised: '2026-08-23'
sections_completed:
  ['technology_stack', 'language_specific_rules', 'framework_specific_rules', 'testing_rules', 'code_quality_and_style', 'development_workflow', 'critical_dont_miss']
status: 'complete (WIP-scope rework 2026-05-17)'
optimized_for_llm: true
overrides:
  - 'architecture.md § P-9 (no per-file license headers) — superseded by SPDX-Identifier rule in Code Quality & Style'
  - 'architecture.md AD-1/AD-3/AD-4 + epics.md AR-AD-1/AR-AD-3/AR-P-2 (JSON envelope + JSON Schemas as the FFI wire) — superseded by docs/adr/0001: FlatBuffers for composite FFI data, lone strings stay CString, MCP keeps JSON-RPC'
  - 'prd.md FR-GR-3/FR-GR-5 + epics.md Story 4.3/4.6 (full materialized lane-cache on open / op_heads) — superseded by docs/adr/0002 (AC-4 resolved 2026-06-22): lazy revset stream (GG model), no long-lived materialized lane cache; full graph derive ~3 ms @ 10k (AMENDED 2026-09-30, Story 4.10: the ~3 ms is the index-only TOPOLOGY walk; the whole topology call is 22 ms @ 10k packed incl. its precondition, and since Story 4.8 a full row costs the commit loads — re-measured numbers in spec-4-10 § Measurements and the ADR-0002 Addendum 2026-09-30)'
  - 'prd.md FR-GR-4/NFR-P-2 + epics.md Story 4.4 (render-slice over a row range, O(slice-size), no scan of the lane-cache) — superseded by the 2026-05-17 WIP-rework + ADR-0002 (no cache to slice): Story 4.4 delivered `zanshin_graph::collect_lanes` (return-all lanes per revset call, 2026-08-23); windowing deferred past WIP. AMENDED 2026-09-26 (Ralph, Story 4.10; research `_bmad-output/planning-artifacts/research/technical-commit-graph-virtualization-research-2026-09-26.md` §3): row-range windowing is REPLACED, not built, because lanes depend on the whole prefix — the graph call returns the complete index-only geometry for the whole revset per operation, and card content is loaded lazily per visible page in O(page). Still open (Ralph, 2026-09-26): a fixed row-based layout or a free layout whose vertical spacing follows commit time (DECIDED 2026-09-27, Ralph: the free layout is the default and compact the only other mode; time is dropped, so the default layout needs every timestamp); time-based layouts need every commit''s committer timestamp, which lives in the commit object, not in jj''s index — Story 4.10 loads them per call on request (measured 2026-09-26: 6.7 ms for a real 1.4k-commit repo, 33.6 ms at 10k in a packed store; the earlier ~1.2 s was the loose-object fixture). AMENDED 2026-10-01 (Story 4.12): `zanshin_graph::collect_lanes` was removed together with the `zanshin-graph` crate and `zanshin_graph_slice`; the graph read is now the topology call `zanshin_graph_topology` (Story 4.10''s `Repo::graph_topology` on the wire, read in Dart through `GraphTopologyView`), and the layout is computed in Dart (Story 4.11)'
scope_reminder: 'Rust workspace + FFI + MCP + build (unsigned) + minimal Dart bootstrap. Flutter UI is OUT OF SCOPE (Ralph''s separate work). Exception 2026-09-26 (Ralph): Epic 10, the commit-graph view (epics.md), is built by Claude at Ralph''s request; the rest of the Flutter UI stays Ralph''s. Changed 2026-10-14 (Ralph): the rest of the Flutter UI is built by Claude too (Epic 11, the floating app shell); Ralph accompanies and reviews. Release pipeline (codesign, notarize, Sparkle, GitHub Releases, reproducibility) is DEFERRED — see prd.md § 4.7.'
posture: 'Code quality is production-grade from day 1. Scope/release-readiness is WIP — breaking changes between WIP versions are allowed, callers update, no _v2 suffixes, no in-wire schema_version. See feedback-no-mvp-shortcuts in memory.'
---

# Project Context for AI Agents

_This file contains critical rules and patterns that AI agents must follow when implementing code in this project. Focus on unobvious details that agents might otherwise miss._

---

## Technology Stack & Versions

**Toolchain (systemwide installs — NO FVM, NO rustup overrides per-project):**
- Flutter `main` channel (≥ `3.44.0-1.0.pre-573`) — main is required for the multi-window
  surface that the Flutter UI (Ralph's separate work) targets. Stable-channel pins are
  not viable until multi-window support lands on a stable release; revisit then.
  Exception 2026-09-26 (Ralph): Epic 10, the commit-graph view (epics.md), is built
  by Claude at Ralph's request; the rest of the Flutter UI stays Ralph's.
  Changed 2026-10-14 (Ralph): the rest of the Flutter UI is built by Claude too
  (Epic 11, the floating app shell); Ralph accompanies and reviews.
- Dart `main` channel (≥ `3.13.0-104.0.dev`) — bundled with Flutter main; track moves
  in lockstep.
- Rust `1.97.1` (pinned via `rust-toolchain.toml`)

**Rust workspace (5 lib crates + 1 bin + xtask):** *(2026-10-01, Story 4.12: 4 lib crates —
the `zanshin-graph` lane crate was removed)*
- `jj-lib` `=0.46.0` (pre-1.0 — pin exact; churn absorbed in `zanshin-jj`)
- `rmcp` `=1.7.0` (pin exact)
- `imara-diff` `=*` (pin exact — Histogram algorithm)
- `tree-sitter-highlight`
- `notify` + `notify-debouncer-full` (50ms window, AD-5)
- `tracing` + `tracing-appender`
- `flatbuffers` `=25.12.19` (pin exact — FFI wire transport for composite data, ADR-0001)
- `serde` / `serde_json` (workspace deps — MCP/`rmcp` + config; NOT the FFI wire anymore)
- `insta` (test-only, snapshots)
- `cargo-deny` (CI license + advisory gate)

**Dart shell (`app/`):**
- `native_toolchain_rust` `1.0.4` (Dart Hook for Rust)
- `ffigen` `20.1.1` (dev_dependency)
- `flat_buffers` `25.9.23` (FFI wire transport for composite data, ADR-0001)
- `hooks` (Dart Hooks runtime)
- `package:flutter_lints` + a hand-curated rule set in `app/analysis_options.yaml`
  (no `very_good_analysis` dependency — rules are listed inline)
- `marionette_flutter` `^0.7.0` (debug builds only — the agent driver; one configuration for the app and
  the catalogue, `app/lib/src/app/zanshin_marionette.dart`; Story 11.11)
- `widgetbook` `3.25.0` (dev_dependency, pinned **exactly** — the review catalogue in `app/widgetbook/`;
  3.25.0 is the last 3.x, and 4.x boots only through `runApp`, which the view-less windowing runner cannot
  run; Story 11.11)
- ~~`pana`~~ — license-gate deferred to release phase

**Build & distribution:**
- `cargo-make` (`Makefile.toml` — single entry point)
- `cbindgen` (C header generation for the `extern "C"` surface, committed output)
- `flatc` `25.12.19` (FlatBuffers compiler — generates Rust + Dart accessors from `schemas/*.fbs`, committed output, ADR-0001)
- **Deferred (release phase, not WIP):** Apple Developer ID codesigning, `notarytool` notarization, Sparkle `2.x` (auto-update, EdDSA-signed appcast), GitHub Releases primary distribution channel

**Platform constraints:**
- macOS-only. Windows/Linux are explicit non-goals.
- Watchman is a runtime system dependency of jj's `fsmonitor`, NOT bundled.
  jj-lib is built with its `watchman` feature (the CLI's default set, Story
  9.26), so the CLIENT is compiled in and a user's `fsmonitor.backend =
  "watchman"` is honoured by every snapshot; Zanshin never bundles or launches
  the daemon (jj-lib falls back to a full scan when it is unreachable).

**Version pinning rules:**
- Load-bearing pre-1.0 crates: `=x.y.z` exact pins (`jj-lib`, `rmcp`, `imara-diff`).
- `flatbuffers` is pinned `=x.y.z` to the installed `flatc` version — generated code and runtime must match.
- Stable crates: caret (`^x.y.z`).
- `default-features = false` requires inline `# WHY:` comment.
- No `[patch.crates-io]` while in 0.x.
- Generated code (`zanshin_ffi.h`, `bindings.dart`, and the `flatc`-generated Rust + Dart FlatBuffers accessors) is COMMITTED — build never regenerates.

## Critical Implementation Rules

### Language-Specific Rules

**Rust:**
- `clippy::pedantic` is on crate-wide. CI runs `cargo clippy -- -D warnings`.
- Clippy warnings must be FIXED, not suppressed. The default response to a clippy
  warning is to refactor: split long functions, group args into a struct, simplify
  control flow, extract helpers. `#[allow(...)]` is a LAST RESORT — only when the
  lint is genuinely wrong for that call site (false positive, intentional pattern
  the lint can't see). Every suppression needs a `// WHY:` comment justifying it
  at the suppression site. Crate-root `#![allow(...)]` is reserved for lints that
  are incompatible with the crate's nature (rare; document at the top of `lib.rs`).
- Reason: untracked suppressions accumulate. Once a project habitually silences
  `too_many_arguments` / `too_many_lines` / `cognitive_complexity`, those warnings
  stop carrying signal. Keeping the bar high forces the refactor that the lint
  was pointing at.
- `rustfmt.toml` at workspace root sets `max_width = 100`. Format on save / pre-push.
- No `unsafe` outside `zanshin-ffi/src/{handle,ffi_strings}.rs` and the cdylib boundary.
  Every `unsafe` block needs a `// SAFETY:` comment naming the invariants.
- No `unwrap()` / `expect()` / `panic!()` in library code paths reachable from FFI.
  Panics inside `extern "C"` are caught via `std::panic::catch_unwind` and converted
  to `error.code = "internal.panic"` — but the goal is to never reach the catch.
- Errors: structured types per crate (`thiserror::Error`). The FFI layer translates them
  into the FlatBuffers `Envelope`'s `error.code` (AR-P-4 taxonomy: `<domain>.<reason>`).
- Async: `tokio` only where required by a dependency (e.g. `rmcp`, `notify-debouncer-full`).
  `zanshin-jj` is sync — jj-lib's APIs are sync, do not wrap them in `async`.
- Shared workspace deps: declare in `[workspace.dependencies]`, consume via
  `serde = { workspace = true }` in member crates.

**Dart:**
- Strict mode is implicit (Dart 3.x). Sound null safety always on.
- `analysis_options.yaml` extends `package:flutter_lints` + a hand-curated set of rules
  (no `very_good_analysis` dependency). `dart format` enforced in CI.
- `dart:ffi` boundary lives ONLY in `app/lib/src/ffi/`. No `dart:ffi` imports elsewhere
  in `lib/`.
- Async: use `Future`/`Stream` plus the single long-running worker isolate (AD-4).
  Never `Isolate.run` for repeated work — send a `WorkerCommand` instead. One exception
  (Story 9.52): the worker itself runs each network verb (fetch, clone, push) on a
  short-lived `Isolate.run` helper, once per call, so its event loop keeps forwarding
  progress; other calls on that handle queue behind it.
- Use `sealed class` for `WorkerCommand` hierarchy so the dispatcher's `switch`
  is exhaustive (compile-time guarantee).
- `NativeFinalizer` MUST be attached to every Dart wrapper holding a Rust handle.
  Even though explicit `close()` is the canonical lifecycle, the finalizer is the
  belt-and-suspenders against forgotten closes during development.
- Logging on Dart side: a thin logging façade forwards to Rust via the infallible
  `zanshin_log(level, target, message)` FFI call — Rust stays the single sink (no
  second Dart log file, no package-level logger that owns its own sink). Use
  `dart:developer` `log()` ONLY as the bootstrap fallback (records emitted before
  tracing/FFI is up, e.g. isolate-spawn failures). See `zanshin_log` contract under
  Logging discipline below (AR-P-5, revised 2026-06-17).

**FFI boundary (Rust ↔ Dart):**
- **Transport rule (ADR-0001):** the data's TYPE decides the transport — fixed
  scalar (`int`/`bool`/`float`) → plain C value; lone string → `*mut c_char`
  (CString); composite (table/list/nested) → **FlatBuffers**. No JSON on the FFI wire.
- Lone strings cross as `*mut c_char` (CString). Rust owns the allocation; Dart
  calls `zanshin_string_free(ptr)` to release. Never `malloc`/`free` mismatched.
- Composite data crosses as a single FlatBuffers buffer (`*mut u8` + length). Rust
  owns the allocation; Dart releases it either via `zanshin_buffer_free(ptr, len)`
  (synchronous call sites) or via the `NativeFinalizer`-backed token path
  (`zanshin_buffer_free_token`, used by `FfiBuffer` — `NativeFinalizer` needs a
  single-pointer callback). Both reclaim the identical allocation — one allocation,
  one free, no per-node pointer trees.
- All faillible `extern "C"` functions return a FlatBuffers `Envelope` table:
  `table Envelope { ok: bool; error: FfiError; data: Payload; }` where `Payload`
  is a union over the concrete payload types. No JSON envelope; no in-wire
  `schema_version` field (WIP: schemas evolve freely, callers update).
- Infallible hot-path functions (`zanshin_ffi_version`, `zanshin_string_free`,
  `zanshin_buffer_free`) return plain types directly — no envelope overhead.
- Field naming: `snake_case` in the `.fbs` schema (committed at `schemas/*.fbs`).
  `flatc --dart` generates `lowerCamelCase` getters automatically — NO `@JsonKey`,
  no hand-written mapping.
- `schemas/*.fbs` are the wire-contract source of truth. `flatc` generates the Rust
  (`flatc --rust`) and Dart (`flatc --dart`) accessors; generated code is COMMITTED
  (same discipline as `zanshin_ffi.h` / `bindings.dart`).
- Wire-contract validation in tests is built into the format: typed accessors make a
  wrong-shape payload a COMPILE error, and the FlatBuffers `Verifier` is the runtime
  integrity backstop. No `jsonschema` / `json_schema`. A test that reads an FFI buffer
  without going through the generated typed accessors is incomplete.
- **WIP: breaking changes are allowed.** Edit the `.fbs` in place, regenerate both
  sides, update all callers in the same PR. No `_v2` FFI-suffix discipline. Post-1.0
  stability policy is deferred and will be revisited at release time.
- **MCP exception:** `zanshin-mcp` speaks MCP JSON-RPC (protocol-mandated). That is a
  DIFFERENT boundary (MCP ↔ client), not the FFI wire — it stays JSON via `rmcp`.

### Framework-Specific Rules

**`zanshin-jj` — jj-lib adapter (anti-corruption layer):**
- ALL jj access goes through `zanshin-jj` → `jj-lib`. No shelling to the `jj` CLI.
  No string-parsing of `jj` output. Fixture-setup scripts may shell out; production
  code may not. (FR-JJ-16, NFR-R-1) Tests may also run `crates/zanshin-parity`'s pinned
  `jj` (stock CLI built from crates.io `jj-cli` at the `jj-lib` pin) — the parity oracle,
  Story 9.47. It compares repo STATE through jj-lib; the CLI's own text is read only to count
  its `Warning:` lines and, in a scenario's read-back (`config get` / `config path`), as
  stdout compared between the two repos — never to drive Zanshin.
- `zanshin-jj` is the ONLY production/library crate that imports `jj_lib`. Other
  internal crates consume `zanshin-jj`'s typed API, not jj-lib directly. (The
  `xtask` fixture generator also imports `jj_lib`, but only as a build-time tool —
  not part of the shipped surface; likewise `crates/test-helpers` — a test-only
  tool crate, dev-dep everywhere, coverage `exclude_prefix` — imports it for the
  `add_commit_off_root` write helper, Story 4.6; and `crates/zanshin-parity` — test-only,
  never shipped, coverage `exclude_prefix` — builds the stock `jj` from `jj-cli` and reads
  repo state through `jj_lib` in its oracle tests, Story 9.47.)
- `zanshin-jj` also depends on the `jj-cli` LIBRARY (Story 9.51) — for jj's template engine ONLY
  (`CommitTemplateLanguage`, `template_builder::parse`, `TemplateRenderer`, and the builtin
  `[template-aliases]` / `templates.*` defaults taken from `jj_cli::config::default_config_layers`),
  never `CliRunner`, `Ui` or a command. No `jj_cli` type appears in a public position either. It is
  pinned exactly with `jj-lib` and moves with it at every pin bump (below).
- **Pin bump (jj-lib).** (1) Bump `jj-lib` and `jj-cli` together in
  `[workspace.dependencies]` (both exact pins). (2) Bump the `../jj` reference tag
  (CLAUDE.md). (3) Run `cargo make test`. (4) Triage every parity-oracle failure
  (`crates/zanshin-parity/tests/oracle/`): UNEXPECTED → port the CLI change, ledger it in
  `ledger.rs` (reason, reference, both values), or open a story; CHANGED → a ledgered gap now
  shows other values (a wrong fix, a regression, or a CLI change) — fix it or update the
  values with a reason; STALE → a gap closed — remove the entry.
  (5) Hand-audit what the oracle cannot see: read verbs, refusal and warning CODES, network
  and interactive verbs, and verbs no scenario covers yet. A new verb story adds its
  scenarios to `scenarios.rs` — they are its acceptance criteria against the real CLI.
- When jj-lib's API changes (it will — pre-1.0), absorb the diff inside `zanshin-jj`'s
  module body. The crate's public surface stays stable. Mutations are visible in
  `jj op log` indistinguishably from CLI-initiated ones (NFR-R-2).
- **Operation surface = typed verb-level API (ADR-0003).** `zanshin-jj` exposes the jj
  CLI's *operation set* as typed verb calls (`new`, `squash`, `rebase`, …) implemented
  against jj-lib — WE compose; consumers name the verb. The transaction boundary stays
  entirely Rust-side; NO mutation primitives cross FFI (impossible anyway — borrowed
  handles/locks + the `write()`-time `has_rewrites()` panic-assert). Reads also get one
  generic `eval_revset` joker (lazy `Box<dyn Revset>`, streamed per ADR-0002) + direct
  `View` access. **As built (Story 9.2):** `eval_revset` is a VISITOR
  (`Repo::eval_revset(&str, impl FnMut(Change) -> ControlFlow<()>)`), not a returned stream —
  the evaluated revset borrows the `ReadonlyRepo` the call loads. Same inversion as
  `Repo::walk_graph`; laziness, no-collect and mid-walk cancellation are preserved. The direct
  `View` reads are `list_tags`/`list_heads`/`list_working_copies` (+ `list_bookmarks` from 2.8),
  all `zanshin-jj`-only — none crosses FFI yet. A shared support module re-ports the `cli_util` orchestration jj-lib does
  NOT expose (immutable-heads check, insert-location resolution, message-combine,
  selected-tree plumbing). Granularity tracks the CLI verb set, re-evaluated at each pin bump.
- **CLI behavior is the semantic reference (NFR-R-2, ADR-0003).** Mirror the jj CLI's
  *observable behavior* — which verbs exist, their preconditions, error/refusal conditions,
  arg arity, op-log effect, default revset/config resolution — read as prior-art from `../jj`
  at the pinned tag. A user of both jj CLI and Zanshin gets the behavior they rightly expect.
  Replicate WHAT the CLI does, not HOW: Zanshin is a GUI/headless backend, so it REPLACES the
  CLI's terminal UX (no TUI/`$EDITOR`/diff-editor/pager/prompts/colored-templated stdout/`ui.status`
  chatter). Interactive verbs (diffedit/resolve/split) take a GUI-supplied selection (`TreeId`),
  never a terminal editor. When the CLI errors/refuses, surface an equivalent error — don't invent
  a "nicer" outcome. (Parity is via jj-lib, never by shelling/scraping the CLI.)
- **Pass CLI parameters through; never decide for the user (FR-JJ-17).** Where the jj CLI leaves
  a path/revset/destination/flag to the user (e.g. `jj git init --git-repo=<repo> <dest>` — two
  paths, both user-chosen), the typed verb + FFI/MCP surface PASSES IT THROUGH so Ralph's UI can
  offer the choice. NO hidden/baked-in default that silently decides. Mirroring a CLI default the
  CLI itself applies (dest `.`, config-driven revset) is fine — surface it as a pre-filled,
  user-editable parameter, not a silent one. The backend classifies/offers; the UI decides.

**Dart Hooks + `native_toolchain_rust`:**
- `app/hook/build.dart` is the ONLY Dart Hook. It points at `zanshin-ffi`:
  `manifestPath: '../crates/zanshin-ffi/Cargo.toml'`.
- Dart Hooks build ONLY `zanshin-ffi` (the single cdylib). Internal Rust crates
  stay pure `lib`; they have no `extern "C"` surface. (FR-FFI-1)
- Never adopt `flutter_rust_bridge` or comparable FFI abstractions. The cbindgen +
  ffigen chain is deliberately manual to avoid version-churn pain.

**`zanshin-ffi` — single cdylib boundary:**
- `crate-type = ["staticlib", "cdylib"]` lives only in `crates/zanshin-ffi/Cargo.toml`.
  The `cdylib` is the actual FFI boundary; the `staticlib` is hard-required by
  `native_toolchain_rust` 1.0.4 (`crate_info_validator.dart:29`) and has no
  in-tree consumer. Documented with a `# WHY:` comment at the declaration.
- Module layout: `lib.rs` (init, panic handler, `zanshin_ffi_version`),
  `envelope.rs` (FlatBuffers `Envelope` build + `FfiError`), `handle.rs` (`Box<T>` ↔
  `*mut T`, panic-catch wrapper), `ffi_strings.rs` (CString in/out + FlatBuffers
  buffer return / `zanshin_buffer_free`), then one file per noun
  (`repo.rs`, `diff.rs`, `graph.rs`, `watcher.rs`).
- All `extern "C"` symbols: `zanshin_<noun>_<verb>` snake_case.
  Constructor/destructor pairs share noun: every `_open` has matching `_close`.
- Single-threaded Rust-side access. NO `Arc<Mutex<T>>` / `RwLock` around handles.
  The Dart worker isolate is the sole consumer (AD-2). The app holds 0..N handles
  (multi-repo / project overview); one isolate serializes all access, so still no
  `Arc<Mutex>`. The repo handle is a warm `Workspace` loader + op-heads-watcher owner,
  not a state cache — reads re-resolve to head (ADR-0002). *(2026-09-30, Story 4.10: one
  read is pinned instead — `Repo::commit_contents` / `zanshin_commit_contents` answers at
  the caller-supplied operation with commit-intrinsic values only and retains nothing; see
  the ADR-0002 Addendum 2026-09-30.)*
- Async Rust→Dart signals: `NativeCallable.listener` ONLY. Same mechanism for
  watcher events AND progress notifications — no special-case channels.

**Watcher subsystem (inside `zanshin-ffi`):**
- Watch TWO paths: `.jj/repo/op_heads/heads/` (primary, real state mutations) and
  `.jj/working_copy/checkout` (heartbeat, fires on any jj activity). NOTE: the
  heartbeat file is at `.jj/working_copy/`, NOT `.jj/repo/working_copy/` — corrected
  in Story 3.5 per jj-lib 0.42.0 `workspace.rs` (`working_copy_state_path =
  <workspace_root>/.jj/working_copy`, per-workspace). The op_heads store is resolved
  through the `.jj/repo` indirection (a FILE in secondary workspaces). prd.md/epics.md/
  architecture.md still carry the stale `.jj/repo/working_copy/checkout` path — fix on next touch.
- Use `notify-debouncer-full` with a 50ms debounce window. Bounded `tokio::mpsc`
  channel, capacity 256. On full: drop-oldest with `tracing::warn!`. NEVER panic
  or block the watcher thread. (AD-5)
- The watcher must start BEFORE `zanshin_repo_open` returns. No race window
  where mutations happen before the watcher is armed.
- Watchman is NOT bundled or launched. Its client IS linked, through jj-lib's
  `watchman` feature (amended 2026-09-23, Story 9.26): jj-lib queries the daemon
  on every snapshot when `fsmonitor.backend = "watchman"`, exactly as the CLI
  does, and falls back to a full scan when it is unreachable. Zanshin itself
  never calls it; detection (`register-snapshot-trigger`, FR-FFI-7) stays
  deferred. When absent, the app still works.

**Worker isolate (Dart, AD-4):**
- ONE worker isolate spawned at app start via manual `Isolate.spawn` +
  `SendPort`/`ReceivePort`. The worker holds all FFI handles for app lifetime.
- Commands (UI → Worker): typed `sealed class WorkerCommand` subclasses.
- Responses (Worker → UI): FlatBuffers byte buffers — the same bytes that crossed
  FFI. Read by the requesting code via the generated typed accessors.
  *(2026-10-01, Story 4.12: the graph topology is the one exception — it crosses as a
  `TransferableTypedData` (one copy instead of `readToken` + `SendPort`'s two) and is read
  through `GraphTopologyView`'s typed-data views over its scalar vectors, not object by
  object; its tests check every value the view reads against the generated accessors.)*
  *(2026-10-01, Story 4.11: `RepoHandle.graphLayout`'s reply carries the topology AND the layout's
  grid as two `TransferableTypedData`, one copy each; the grid is read through `GraphGridView`'s
  typed-data views over its one buffer.)*
- Correlation: every command carries an incrementing `commandId`; worker echoes
  it. Main isolate holds `Map<int, Completer<String>>` to resolve futures.
- Async events (watcher, progress): a separate `SendPort` per stream type.
  Do not multiplex events and command-responses on the same port.

**`zanshin-mcp` — MCP server binary:**
- Single-repo process. Repo selected at startup: `--repo <path>` flag or CWD
  ancestor walk for `.jj/`. NO runtime repo switching. NO in-process repo
  registry. (AD-6)
- `zanshin-mcp` consumes `zanshin-jj` DIRECTLY (no FFI). FFI exists only for
  the Flutter app.
- Tool descriptions are an LLM-quality gate (FR-MCP-5): every tool has a
  one-line description + parameter docs + a usage example. Test via
  `mcp-tester` smoke run before merging tool changes.
- Same-repo concurrency model (FR-MCP-9): GUI + MCP + external `jj` CLI all
  hit the same filesystem. Mutations propagate via the watcher path. NO IPC,
  NO locking choreography between them — beyond jj's OWN locks, which Zanshin
  takes exactly where the CLI does (e.g. `git_import_export.lock`, Story 9.26).

### Testing Rules

**Test layout:**
- Rust unit tests inline: `#[cfg(test)] mod tests { ... }` at bottom of the module
  they test. Integration tests in each crate's `tests/` directory; `zanshin-jj` and
  `zanshin-ffi` build ONE integration-test binary each (Story 9.55): `tests/it/main.rs`
  plus one module per test file (`tests/it/<name>.rs`). The process environment there has
  one writer, `test_helpers::pin_test_env()`; a test that needs a different environment (or
  the FFI event sink) starts with `test_helpers::own_process!` and runs alone in a child
  process of the binary.
- Dart unit tests in `app/test/` mirroring `lib/src/` layout.
- E2E tests in `app/integration_test/` — boot a real worker isolate and a real
  compiled cdylib. The isolate boundary is NEVER mocked.
- No `#[ignore]` / `skip:` on tests for "flakiness" reasons. Either the test is
  deterministic or it's deleted.

**Coverage ratchet (local-only; part of `cargo make test`):**
- `cargo make coverage` measures **Rust** line coverage — the source-level union
  of the FFI-path coverage (the instrumented `zanshin-ffi` cdylib exercised by
  `packages/zanshin_core`'s `dart test`) and the cargo-test coverage
  (`cargo-llvm-cov`). A line counts if covered by EITHER. It then gates per-file
  coverage against the committed `coverage-baseline.txt`.
- `cargo make test` runs `coverage` as its final step, so the ratchet is part of
  the standard gate (Rust is rebuilt instrumented + `dart test` re-runs — this is
  the slow part; folded in deliberately, revisit if it bites). After a run that
  raised coverage, commit the updated `coverage-baseline.txt` with the code that
  earned it (improvements raise the baseline in place; it never lowers).
- Changed 2026-10-17 (Ralph): `coverage` is also where the gate runs the Rust
  test suites and the `packages/zanshin_core` suite — `test-cargo` / `test-core`
  left the gate flow (a separate `test-cargo-doc` keeps the doctests, which
  cargo llvm-cov skips), and `cargo make test` runs `coverage` only when Rust,
  `packages/zanshin_core`, test fixtures or root config changed since the last
  green run (see the build-commands bullet below).
- A regression (a tracked file dropping below baseline, or a new file under the
  `new_file_floor_pct`) FAILS the gate. The fix is to ADD TESTS — never lower the
  baseline to pass. Lowering the floor or adding an `exclude_prefix` is a
  deliberate, reviewed edit to `coverage-baseline.txt`.
- Coverage is **Rust-only** — Dart-side lines are not measured (heavy logic is
  Rust; the Dart bridge is thin, the UI is out of scope). Exception 2026-09-26
  (Ralph): Epic 10, the commit-graph view (epics.md), is built by Claude at Ralph's
  request; the rest of the Flutter UI stays Ralph's. Epic 10's Dart lines stay
  unmeasured as well. Changed 2026-10-14 (Ralph): the rest of the Flutter UI is
  built by Claude too (Epic 11, the floating app shell); its Dart lines stay
  unmeasured as well. Mechanism + knobs:
  `docs/coverage.md`, `crates/xtask/src/tasks/{lcov_union,coverage_check}.rs`.

**Fixtures:**
- Repository fixtures live at `test-fixtures/repos/` as compressed
  `.tar.zst` archives: `tiny-3-commits/`, `medium-1k-commits/`, `large-10k-commits/`.
- Fixtures are COMMITTED. They are NOT rebuilt at test time.
- Regeneration happens via `cargo xtask gen-fixture` and is a deliberate, reviewed
  PR — never an automatic side-effect of running tests.
- Diff input fixtures in `test-fixtures/diffs/`; expected golden outputs in
  `test-fixtures/golden/`.

**FlatBuffers wire-contract validation in tests:**
- Every test that produces or consumes a FlatBuffers buffer crossing the FFI
  boundary reads it through the generated typed accessors (a wrong shape is a
  compile error) and runs the FlatBuffers `Verifier` on untrusted buffers. No
  `jsonschema` / `json_schema`.
- Snapshot tests via `insta`: snapshot a readable projection of the decoded buffer
  (the typed values rendered to JSON for the snapshot only, or `flatc --json`).
  Snapshots are committed and reviewed; `cargo insta accept` is a deliberate step.
- A test fixture that can't be parsed by the generated accessors is a bug in the
  FIXTURE, not in the test.

**Worker / isolate testing (Dart):**
- Dart tests that exercise the worker isolate boot the REAL `Isolate.spawn` flow
  and the real ffigen bindings against the real cdylib. No mocked isolates,
  no mocked FFI surface.
- The cdylib must be built (`cargo make build` or equivalent) before the Dart
  test suite runs. CI gates this explicitly.

**Performance assertions — DEFERRED to release phase:**
- NFR-P-* budgets remain as soft design targets that inform algorithm choice
  (e.g., `imara-diff` Histogram over `similar`). **No CI perf-gate enforcement
  while WIP.**
- One WIP exception: `zanshin-graph` should have a small algorithmic-correctness
  test on a ~100-commit fixture (correct lane output, not timing). Catches dumb
  O(n²) regressions cheaply without paying for a large-fixture perf-test infra.
  *(2026-10-01, Story 4.12: lapsed — the `zanshin-graph` crate was removed; the layout
  engine's correctness tests are Dart-side, Story 4.11.)*
- Test only against committed fixtures of known size. Do not generate
  variable-size inputs at test time.

**MCP server tests (WIP-minimal):**
- A "MCP-server boots + lists tools" smoke runs in CI (prevents the MCP code
  path from silently rotting).
- **Deferred:** `mcp-tester` LLM-quality smoke (FR-MCP-5 quality gate),
  dedicated GUI-worker + MCP-binary same-repo concurrency test
  (concurrency assertions live in the FR-JJ-10a mutation smoke instead).

**Property of every test suite:**
- Tests do not depend on the developer's global `~/.jjconfig.toml` or
  `~/.gitconfig`. All test runs pin `JJ_CONFIG` / `GIT_CONFIG_GLOBAL` to a
  fixture-controlled location. Reason: the same `cargo make test` must produce
  identical results on a clean CI runner and on a developer's machine.
- No test reaches the network. No `git fetch` / `git push` against real remotes.
  Use the `tiny-3-commits` fixture's git backend or a `git daemon` on localhost.
- Tests run in parallel by default. Any test that requires serialization opts
  in explicitly (`#[serial]` in Rust, `setUpAll`-coordinated in Dart).

### Code Quality & Style Rules

**File & module organization:**
- Rust crates organize source by NOUN, not by layer. `zanshin-jj/src/repo.rs`,
  `status.rs`, `change.rs` — NOT `models.rs`, `services.rs`, `utils.rs`.
- No `mod.rs` files. Use Rust 2018+ module paths: `foo.rs` + `foo/` sibling.
- `lib.rs` is for re-exports, crate-level docs, and `#![...]` attributes only.
  No business logic in `lib.rs`.
- Dart files are `snake_case.dart` matching their class/feature name.
- Each Dart `lib/src/` subdirectory has a barrel file ONLY if it makes imports
  meaningfully shorter. No barrel-for-the-sake-of-barrel.

**Naming conventions:**
- Rust: types `PascalCase`, functions/vars `snake_case`, consts `SCREAMING_SNAKE`,
  modules `snake_case`. `extern "C"` symbols `zanshin_<noun>_<verb>` (already in
  Framework-Specific Rules).
- Dart: types `PascalCase`, members/locals `lowerCamelCase`, library-private
  prefixed `_`. No Hungarian notation, no `m_`, no `I` prefix on interfaces.
- FlatBuffers fields: `snake_case` in the `.fbs`. `flatc --dart` generates
  `lowerCamelCase` getters automatically — no `@JsonKey`, no hand-mapping.
- Test names describe the SCENARIO, not the function:
  `repo_open_with_invalid_path_returns_error` beats `test_open_repo_2`.

**Error code taxonomy:**
- `error.code` is dotted lowercase: `<domain>.<reason>`.
- Domains: `jj`, `diff`, `graph`, `ffi`, `watcher`, `mcp`, `internal`.
- Reasons are short, stable, machine-readable: `repo_not_found`, `invalid_handle`,
  `panic`. Never include user-data in the code (paths, IDs go in `error.context`).
- `docs/rust-error-codes.md` is the canonical registry. Any PR that adds an
  `error.code` MUST update the registry.
- Error reasons NEVER change after release. New reasons are added; old reasons
  may be deprecated (still callable) but not renamed or repurposed.

**Logging discipline:**
- Rust: `tracing` + `tracing-appender`. Initialized once per process inside
  `zanshin-ffi::lib_init` and `zanshin-mcp::main`.
- Sink: rotating files at `~/Library/Logs/Zanshin/zanshin.log.YYYY-MM-DD`.
- NO console output in release builds. Debug builds may also log to stderr
  during local development.
- **MCP exception (binding):** `zanshin-mcp` MUST sink tracing to file ONLY in
  ALL build modes. Stray stdout/stderr corrupts the MCP stdio protocol — a hard
  failure mode, not a warning.
- **Dart → Rust log forwarding (AR-P-5, revised 2026-06-17):** Dart never owns a
  log sink. A thin Dart logging façade forwards each record across FFI via the
  infallible `extern "C" zanshin_log(level: i32, target: *const c_char,
  message: *const c_char)` → `void`. Two lone strings = two CStrings (NOT
  FlatBuffers; ADR-0001: lone string → CString). **Inbound-string ownership is the
  REVERSE of the outbound rule:** Dart allocates AND frees; Rust only borrows for
  the call. `catch_unwind`-wrapped (no panic across FFI); no `Envelope` (infallible
  — a dropped line is the worst case). Handle-free, so it is **exempt from the
  single-consumer rule (AD-2)** and callable from any isolate (`tracing`'s global
  subscriber is thread-safe). `dart:developer` `log()` is the bootstrap fallback
  ONLY (records before tracing/FFI is ready).
- Levels: `error` (boundary violation), `warn` (degraded mode), `info` (lifecycle
  events), `debug` (per-call entry/exit — compiled out in release), `trace`
  (off in release).
- Every FFI call gets a `tracing::span!` with fields `fn_name`, `command_id?`,
  `handle_id?`. The span lifetime brackets the call's work.
- Verbosity override: `ZANSHIN_LOG=info` env variable (matches `RUST_LOG`
  filter syntax).
- Never log user data (file contents, commit messages, change IDs) at `info`
  or above. PII is `debug`-only and compiled out of release.

**Documentation:**
- Every source file (Rust `.rs`, Dart `.dart`) starts with an SPDX license
  identifier on the FIRST line:
    `// SPDX-License-Identifier: MIT`
  Single line, machine-readable, makes the license visible per-file (OD-2).
  No license boilerplate in-file — SPDX +
  repo-root `LICENSE` is the canonical pattern.
  Note: this OVERRIDES `architecture.md` § P-9, which predates this decision.
  **Exception — committed generated files are EXEMPT** from the SPDX-first-line
  rule: the generator owns the file's leading banner and the file is regenerated
  wholesale, so a hand-added SPDX line would be clobbered. This covers `flatc`
  output (`*_generated.rs`, `*.ffi_generated.dart`), cbindgen output
  (`zanshin_ffi.h`), and ffigen output (`bindings.dart`). The repo-root `LICENSE`
  still governs them.
- Doc comments (`///` in Rust, `///` in Dart) on every `pub`/exported item in
  library crates. `extern "C"` functions in `zanshin-ffi` are doc-commented for
  cbindgen to lift into the generated header.
- Internal-only items don't need doc comments unless the name doesn't carry the
  intent. Don't write `/// Gets the foo.` on `fn get_foo()`.
- Code comments explain WHY, not WHAT. The default is to write no comment;
  add one only when the rationale is non-obvious (hidden constraint, subtle
  invariant, workaround for a specific upstream bug — include the issue link).
- `docs/` holds architecture-level docs (`architecture.md`, `rust-error-codes.md`,
  `ffi-abi.md`, `release-process.md`, `watchman-setup.md`). ADRs go in `docs/adr/`.

**Linter / formatter enforcement:**
- `rustfmt.toml`: `max_width = 100`. `cargo fmt --check` in CI.
- `analysis_options.yaml`: `package:flutter_lints` + hand-curated rules (no `very_good_analysis`)
  rules. `dart format --set-exit-if-changed` in CI.
- See Language-Specific Rules § Rust for the Clippy refactor-not-suppress rule.

**Cargo.toml hygiene:**
- Shared deps via root `[workspace.dependencies]`. Member crates consume as
  `serde = { workspace = true }`.
- Exact version pins (`=x.y.z`) for load-bearing pre-1.0 deps: `jj-lib`, `rmcp`,
  `imara-diff`. Caret pins for stable deps.
- `default-features = false` requires an inline `# WHY:` comment.
- No `[patch.crates-io]` while in 0.x. If a fork is required, file an issue
  documenting when it can be dropped, link the issue from the patch entry.
- `[workspace.package]` carries a single shared `version` (AR-AD-7).

### Development Workflow Rules

**Build commands (`cargo-make` is the single entry point):**
- `cargo make build` — full build, produces unsigned, unnotarized `.app` in
  `app/build/macos/Build/Products/Release/Zanshin.app` (dev mode — this is the
  WIP deliverable).
- `cargo make test` — Rust workspace tests + Dart bootstrap tests +
  `cargo deny check advisories bans` + the **coverage ratchet** (runs
  `cargo make coverage`; gates per-file Rust coverage, see `docs/coverage.md`).
  (Full license-gate + `pana` deferred.) Changed 2026-10-17 (Ralph): it runs only
  the steps the paths changed since its last green run need — `cargo xtask
  gate-plan` maps each path to its package plus every package depending on it
  (rules in `crates/xtask/src/tasks/gate_plan.rs`; the stamp lives in
  `target/gate/last-green`); docs/planning-only changes run nothing, root
  manifests / toolchains / the gate itself / unknown paths run everything. A test
  that reads a file outside its own package needs that path in the rules.
- `cargo make test-full` — every gate step, whatever changed.
- `cargo make coverage` — measure unified Rust coverage (FFI-path + cargo tests)
  and gate it against `coverage-baseline.txt`; raises the baseline on improvement.
  Standalone form of the ratchet that `cargo make test` also runs.
- `cargo make codegen` — regenerates `zanshin_ffi.h` (cbindgen) and
  `bindings.dart` (ffigen). RUN MANUALLY whenever an `extern "C"` signature
  changes. Commit the regenerated files in the same PR.
- `cargo make verify-codegen` — codegen drift check. **Deferred as CI gate
  while WIP** — discipline rule applies during development.
- `flutter run -d macos` — for UI work only (Ralph's separate scope; Changed 2026-10-14
  (Ralph): also Claude's Epic 10 / Epic 11 stories).
  Requires a prior `cargo make build` so the cdylib is present.

**UI tooling (Story 11.11):**
- The Zs controls live in `packages/zanshin_ui` (`lib/src/controls/`), on Flutter's widgets-layer primitives
  and one state core (`ZsControlCore`); the app imports them from `package:zanshin_ui/zanshin_ui.dart`.
- Every control takes an optional `identifier`, rendered as `Semantics(identifier:)`. Agents (Marionette,
  tests) match by identifier or by text, **never by coordinates** — coordinate gestures hit the first view,
  not the window the control is in.
- An `@experimental`, `@Deprecated` or `@internal` API is used only with one explicit `// ignore:` naming
  the diagnostic and a `// WHY:` line above it — or it stays out.
- Widgetbook is pinned exactly at `3.25.0`; no Widgetbook 4 (it boots only through `runApp`), no generator,
  no Widgetbook Cloud.
- The catalogue runs with `flutter run -d macos -t widgetbook/main.dart` from `app/`, in a window of its own.
- `marionette_mcp` is installed with `dart pub global activate marionette_mcp` and must match the app's
  `marionette_flutter` version exactly.
- The catalogue's Marionette extension `zanshinCatalogue.open` (debug builds) opens a use case by its
  Widgetbook path in an appearance: `path=controls/switch/state-matrix` (names joined by `/`, spaces as `-`,
  lower case), optional `theme`, `accent`, `contrast`, `reduceMotion`, `reduceTransparency`, `inactive`.
- **Claude checks every UI change visually before it counts as done** (Ralph, 2026-10-18; epics.md house
  rule "Tests"): run the catalogue (or the app), connect Marionette, open the affected use cases with
  `zanshinCatalogue.open`, take screenshots and compare them with the DS cards rendered at full size
  (headless Chrome over the `design-system-preview` server, `.claude/launch.json`). Widget tests do not
  replace this check, and Ralph's review comes on top of it.
  - Marionette cannot hover: a surface that shows only on hover needs a use case that shows it open.
  - Screenshots are the Flutter layer only and come out scaled: compare proportions, not absolute pixels; the
    native chrome stays the CGWindowList probe's.

**Deferred targets (release phase, not WIP):**
- `cargo make sign` / `cargo make notarize`
- `cargo make release` (full pipeline: build → sign → notarize → Sparkle appcast → tag → GitHub Releases upload)

**Codegen workflow:**
- Generated files (`crates/zanshin-ffi/include/zanshin_ffi.h`,
  `app/lib/src/ffi/bindings.dart`) are COMMITTED to the repo.
- Build never auto-regenerates. The only path to update them is
  `cargo make codegen` followed by an explicit commit.
- **WIP:** CI's `verify-codegen` drift-gate is deferred. The discipline rule
  (never regenerate outside `cargo make codegen`) still applies during
  development — code review must see the diff of generated code.

**CI gates (WIP-minimal, every PR on `main` branch protection):**
- `cargo clippy -- -D warnings` (workspace-wide, pedantic on)
- `cargo fmt --check`
- `cargo test --workspace` (Rust unit + integration tests; performance tests deferred)
- `dart analyze --fatal-infos --fatal-warnings`
- `dart format --set-exit-if-changed`
- `flutter test`
- `cargo deny check advisories bans` (security backstop)

**Deferred CI gates (release phase):**
- `flutter test integration_test`
- `cargo deny check licenses`
- `pana --no-warning` against `app/` package
- `cargo make verify-codegen` (codegen drift)
- `mcp-tester` smoke run against `zanshin-mcp` (FR-MCP-5 LLM-quality gate)
- Performance budget tests
- Reproducibility check (FR-BO-8 two-build diff, `reproducibility.yml`)

**Git / repo conventions:**
- Direct commits to `main` are allowed (solo project — Ralph's call, 2026-06-15). No
  mandatory per-change branch or PR; create a branch only when it genuinely adds value
  or when Ralph asks.
- Branch naming: `<type>/<short-slug>` where `<type>` ∈
  `{feat, fix, refactor, perf, docs, build, ci, chore, release}`.
  Example: `feat/zanshin-jj-bookmarks`.
- Commit messages: imperative present tense, ~60 chars subject + optional body.
  Reference FR-IDs (e.g. `FR-JJ-8`) when implementing a tracked requirement.
  No "WIP" / "fix typo" / "address review" commits on `main` — squash before
  merge or rebase locally first.
- Each PR maps to ONE epic-story or one focused refactor. Don't bundle
  unrelated changes.
- Co-authoring credit for AI agents follows the repo's convention; see local
  CLAUDE.md if it specifies. Do not add unprompted attribution lines.

**PR review requirements:**
- Every PR description references the FR-IDs / NFR-IDs / AR-IDs it implements
  or touches.
- For FFI-surface changes: the diff MUST include both `extern "C"` source AND
  regenerated `zanshin_ffi.h` + `bindings.dart`. (CI drift-gate deferred —
  reviewer enforces during code review.)
- For schema changes: the PR includes the schema diff (`schemas/*.json`).
  WIP: in-place edit; no version bump, no `_v2` FFI suffix, no `schema_version`
  field. Update all callers in the same PR.
- For new error codes: `docs/rust-error-codes.md` is updated in the same PR.

**Release flow — DEFERRED (Epic H reduced to "build unsigned `.app`" in WIP):**
- Tag-driven releases, codesigning, notarization, Sparkle appcast,
  GitHub Releases automation are all deferred to the release phase.
- Versioning posture in WIP (0.x): breaking changes allowed; callers update.

**License compliance (WIP-scope):**
- `cargo deny check advisories bans` runs in CI (security backstop, cheap).
- **Deferred to release phase:** `cargo deny check licenses` (full license-gate),
  `pana` validation of Dart `pubspec.yaml` license metadata.
- The dependency policy still holds informally: prefer permissive only —
  MIT, BSD-2/3, Apache-2.0, MPL-2.0, Unlicense, CC0. Avoid GPL/AGPL/LGPL/SSPL.
  Before adding a non-trivial dep, eyeball its license; the formal gate lands later.

**No-telemetry constraint (NFR-PRIV-1..4):**
- Adding Sentry / Crashlytics / Firebase / Datadog / any analytics SDK is a
  HARD-BLOCK at review. Not a warning, not a discussion — rejected at the
  first sight of the dependency.
- Once Sparkle auto-update lands (release phase), the Sparkle update check
  will be the ONLY outbound network call in the shipped app. User-Agent only;
  no identifying payload. WIP has no outbound network calls.
- Crash logs are LOCAL: `~/Library/Logs/Zanshin/`. No upload, no
  auto-collection, no opt-in dialog.

### Critical Don't-Miss Rules

**Hard-banned anti-patterns (reject at review on first sight):**

- **NEVER shell out to the `jj` CLI** in production code. All jj access goes
  through `zanshin-jj` → `jj-lib`. Fixture-setup scripts may shell out, and so may the
  parity oracle's tests (`crates/zanshin-parity`, Story 9.47); production code may not.
  (NFR-R-1, FR-JJ-16)
- **NEVER parse `jj` CLI output strings.** Even for "just a quick lookup".
  Structured access through the adapter is the WHOLE POINT.
- **NEVER diverge from the jj CLI's observable behavior** for a given input — same verbs,
  preconditions, refusals, op-log effect. Observable behaviour includes every ON-DISK, repo-side
  effect the CLI produces (its repo-level config rewrites, for instance), not only the op-log and
  refusals; only the terminal UX is replaced. The CLI is the semantic oracle (read at the pinned
  tag in `../jj`), but only for behavior: Zanshin REPLACES its terminal UX (no TUI/`$EDITOR`/
  pager/prompts/templated stdout); interactive verbs take a GUI-supplied `TreeId`. (NFR-R-2, ADR-0003)
- **NEVER bake in a default path or silently pick a parameter the jj CLI leaves to the user.**
  Pass every such CLI parameter through the typed verb + FFI/MCP surface so the UI offers it.
  (Pre-filling a CLI-applied default as a user-editable field is fine; deciding for the user is not.) (FR-JJ-17)
- **NEVER add `extern "C"` functions outside `crates/zanshin-ffi/`.** Internal
  crates stay pure-Rust `lib`. The single-cdylib boundary is non-negotiable.
- **NEVER adopt `flutter_rust_bridge`** or any comparable FFI abstraction.
  The cbindgen + ffigen chain is deliberately manual.
- **NEVER add Sentry / Crashlytics / Firebase / Datadog / analytics SDKs.**
  No telemetry. Ever. (NFR-PRIV-1)
- **NEVER add GPL / AGPL / LGPL / SSPL dependencies.** The formal `cargo deny
  check licenses` gate is deferred to release phase; meanwhile, eyeball every
  new dep's license at PR-review time. Permissive only.
- **NEVER regenerate `bindings.dart` or `zanshin_ffi.h` outside
  `cargo make codegen`.** The CI drift-check is deferred while WIP — the
  discipline rule still applies; code-review catches it.
- **NEVER use `Isolate.run` for repeated work** in Dart. Send the work as a
  `WorkerCommand` on the existing worker bus. The only `Isolate.run` is the worker's
  once-per-call helper for the network verbs (Story 9.52, `isolate.dart`
  `_fetchOnHelper` / `_pushOnHelper` / `_cloneOnHelper`).
- **NEVER put JSON on the FFI wire, and NEVER invent alternative envelope shapes.**
  Faillible FFI functions return the FlatBuffers `Envelope` table (ADR-0001);
  composite data is FlatBuffers; lone strings are CString; scalars are plain types.
  The only JSON in the project is `zanshin-mcp`'s protocol-mandated JSON-RPC.
- **NEVER add per-call locking** (`Arc<Mutex<T>>`, `RwLock`) around handles.
  The concurrency model is single-threaded Rust-side (AD-2).
- **NEVER push jj operation orchestration into the consumer** (Flutter/MCP), and NEVER
  expose jj-lib mutation primitives across FFI. Compose verbs inside `zanshin-jj`; the
  transaction runs start-to-finish Rust-side (ADR-0003). Primitive-level FFI is impossible
  (borrowed handles + on-disk locks), not merely discouraged.
- **NEVER let stdout/stderr leak from `zanshin-mcp`.** It corrupts MCP stdio
  protocol — file-only tracing in ALL build modes, no exceptions.
- **NEVER write Flutter UI code in this scope.** Widgets, layout, navigation,
  theming, a11y, i18n are Ralph's separate work. Stick to API surfaces.
  Exception 2026-09-26 (Ralph): Epic 10, the commit-graph view (epics.md), is built
  by Claude at Ralph's request; the rest of the Flutter UI stays Ralph's.
  Changed 2026-10-14 (Ralph): the rest of the Flutter UI is built by Claude too
  (Epic 11, the floating app shell); Ralph accompanies and reviews. Write UI code
  only inside an Epic 10 / Epic 11 story (or another story that asks for it).
- **NEVER plan with a "good enough for now" mindset on CODE QUALITY.** Every line
  of code that ships meets the project's quality bar (Clippy pedantic, structured
  errors, `NativeFinalizer`, schema-validated JSON in tests, no shelling to jj CLI,
  etc.). **Scope / release-readiness is separately WIP** — release infrastructure
  (codesigning, notarization, Sparkle, GitHub Releases automation, reproducibility,
  schema versioning machinery, full license-gate, perf-gate enforcement) is
  deliberately deferred. Don't confuse the two axes. See `[[feedback-no-mvp-shortcuts]]`
  in memory.
- **NEVER `--amend` a published commit or force-push without explicit
  authorization.** New commit, not amend.
- **NEVER lower the coverage baseline to make the gate pass.** Coverage is a
  ratchet (`coverage-baseline.txt`, part of `cargo make test`) — a regression
  means ADD TESTS, not edit the floor down. Lowering `new_file_floor_pct` or
  adding an `exclude_prefix` to dodge an untested file is a review-blocking
  change. (See `docs/coverage.md`.)

**Edge cases agents typically miss:**

- **Watcher armed BEFORE `zanshin_repo_open` returns.** Mutations between
  open-call-start and watcher-arm would silently disappear. Test for this.
- **`NativeCallable.listener` lifecycle.** The Dart-side callable must outlive
  every Rust-side reference. Attach it to the worker isolate's lifetime, not
  to a single FFI call.
- **`*mut c_char` ownership.** Rust allocates, Dart frees via
  `zanshin_string_free`. Mixing `malloc`/`free` across runtimes corrupts heaps
  silently — the crash happens far from the cause.
- **Watcher recovers from FS disturbances** (network drives unmounting, Time
  Machine snapshots). `notify-debouncer-full` handles this; don't add manual
  reset logic that fights the debouncer. (FR-RX-4)
- **Same-repo concurrency uses the filesystem as IPC, NOT locks.** When GUI +
  MCP + external CLI mutate the same repo, the only synchronization point is
  `op_heads` changing. Adding any cross-process lock OF ZANSHIN'S OWN breaks the
  model. (FR-MCP-9, FR-RX-3) The one exception is taking jj's OWN locks where the
  CLI takes them: the pre-verb snapshot and every colocated finish hold
  `<repo>/git_import_export.lock` (a blocking `jj_lib::lock::FileLock`, Story
  9.26), so a Zanshin Git HEAD/ref import-export and a CLI one never interleave.
- **Generated code is committed; build doesn't regenerate.** When an
  `extern "C"` signature changes, run `cargo make codegen` and commit BOTH the
  source change and the regenerated header/bindings in the same PR. CI's
  `verify-codegen` drift-gate is deferred while WIP — code-review enforces.
- **No in-wire `schema_version` field in WIP.** The FlatBuffers `Envelope`
  (`ok` / `error` / `data`) carries no version field. When you change a `.fbs`,
  edit in place, regenerate both sides, and update all callers in the same PR.
- **Watchman detection (FR-FFI-7) is deferred** (the jj-lib client itself is
  compiled in since Story 9.26 — see Platform constraints). When/if it lands later:
  Watchman absence is degradation, not failure — repo-open succeeds without it,
  external-edit reactivity degrades to "refresh on jj operation only". WIP
  works without any Watchman-detection surface.
- **`jj-lib` is sync.** Wrapping its calls in `async` / `tokio::spawn_blocking`
  obscures the call stack and serves no purpose. The worker isolate provides
  the async boundary; `zanshin-jj` itself stays synchronous.
- **Test-fixture jj configs override user globals.** When tests run, pin
  `JJ_CONFIG` / `GIT_CONFIG_GLOBAL` to a fixture-controlled location, or local
  vs. CI behavior diverges.

**Security / data-integrity invariants:**

- **No data loss is acceptable.** All mutations route through `jj-lib` via
  `zanshin-jj`. Every Zanshin mutation must be visible AND reversible in
  `jj op log`. (NFR-R-1, NFR-R-2)
- **No panic crosses the FFI boundary.** Wrapped via `std::panic::catch_unwind`
  in `zanshin-ffi::handle`, converted to `internal.panic` error. The goal is
  to never reach the catch — but the catch exists as a backstop. (FR-FFI-9)
- **No secrets in CI logs.** WIP CI has no secrets to leak (release pipeline
  deferred). When codesign / Sparkle EdDSA / notarytool credentials land later,
  they live in encrypted GitHub Secrets, never echoed.
- **No PII at `info` or above** in logs. Commit messages, file paths, change
  IDs are `debug`-level only and compiled out in release.

**Performance gotchas:**

- **Lane state is re-derived (streamed) on every `op_heads` change**, not held as a
  long-lived materialized cache (ADR-0002 AC-4 resolved: full graph derive ~3 ms @ 10k,
  first render page ~27 µs). The op-heads watcher is the coherency trigger (op-id compare);
  the graph is re-derived via a lazy revset stream (`stream_graph` + `TopoGroupedGraph`, GG
  model) and never trusted across an op-id advance. *(2026-10-01, Story 4.12: there is no
  lane state any more — the lane crate was removed; what is re-derived per operation is the
  topology `zanshin_graph_topology` returns.)* **Don't reintroduce a materialized lane
  cache** — it buys nothing here (re-derive ≪ NFR-P-1's < 1s @ 10k) and brings back staleness.
  *(2026-09-30, Story 4.10: the ~3 ms / ~27 µs time the index-only TOPOLOGY walk (re-measured
  3.1 ms / 30 µs). The whole `graph_topology(all())` call is 22 ms @ 10k packed (5 ms @ 1k),
  its timestamps +31 ms packed / ~1 s on the loose fixture, a 60-id content page 1.7 ms
  packed, and `walk_graph(all())` itself 53 ms packed / 1.09 s loose @ 10k; since Story 4.8 `walk_graph`'s rows cost the commit loads. See spec-4-10 §
  Measurements and the ADR-0002 Addendum 2026-09-30.)*
- **`zanshin-graph` slice API = `collect_lanes`, a collect-all over the lazy stream.**
  There is no held cache to iterate: `collect_lanes(repo, revset, prioritize)` drives
  `stream_lanes` with a collecting sink (Story 4.4; windowing deferred past WIP). A future
  page composes as an early-exit sink on `stream_lanes` (O(prefix)), never as a scan over
  held rows. *(2026-10-01, Story 4.12: removed — `collect_lanes`, `stream_lanes`, the
  `zanshin-graph` crate and `zanshin_graph_slice` are gone. The graph read is
  `zanshin_graph_topology`: the whole revset's index-only topology per call (Story 4.10),
  scalar vectors + CSR on the wire, laid out in Dart (Story 4.11); still re-derived per
  operation, still no held cache.)*
- **`imara-diff` Histogram algorithm** is ~30× faster than `similar` for large
  diffs. Don't substitute `similar` "for consistency" — the perf gap is real.
- **Don't pre-compute things "in case the UI needs them".** Compute on
  callback dispatch, not speculatively. The UI is out of scope; designing for
  hypothetical UI demands is over-engineering.

---

## Usage Guidelines

**For AI agents:**
- Read this file before implementing any code in the Zanshin workspace.
- When a rule here conflicts with `architecture.md`, this file wins. The
  `overrides:` list in the frontmatter tracks known conflicts.
- When a rule here conflicts with `prd.md` or `epics.md`, raise it — those
  are upstream source documents and an inconsistency is a bug to fix, not
  a choice to make silently.
- Cross-references to architecture identifiers (AD-1..AD-7, P-1..P-9) point
  at `_bmad-output/planning-artifacts/architecture.md` for the original
  rationale.
- When in doubt between two valid implementations, prefer the one this file
  shows first; if neither is shown, prefer the more restrictive option.

**For humans (Ralph):**
- Keep this file lean. Rules that become obvious in the codebase should be
  pruned — every line costs LLM context on every read.
- When a load-bearing decision changes (tech-stack version bump, new pattern,
  retired anti-pattern), update this file first, then the architecture doc.
- The `sections_completed` and `overrides:` frontmatter is the audit trail
  for what was deliberately decided here vs. inherited from architecture.

**Reference documents:**
- `docs/adr/0002-repository-state-model-warm-loader-reload-per-operation.md` — repository
  state model (warm loader + re-resolve-per-operation; refines AD-2/AD-4/AD-5; resolves the
  FR-GR-3 lane-cache decision → lazy revset stream, no materialized cache)
- `_bmad-output/planning-artifacts/research/technical-vcs-gui-repo-state-cache-vs-reload-research-2026-06-22.md`
  — research backing ADR-0002 (29-agent survey of 13 Git/jj GUIs; coherency patterns; jj cost model)
- `docs/adr/0001-ffi-data-transport-flatbuffers.md` — FFI transport decision
  (FlatBuffers for composite data; supersedes the JSON-envelope parts of AD-1/AD-3/AD-4)
- `docs/adr/0003-jj-operation-api-surface.md` — the operation API surface (CLI-operation-set
  as a typed verb-level API over jj-lib; we compose; no mutation primitives over FFI; revset
  read joker; refines AD-2/AD-4)
- `_bmad-output/planning-artifacts/research/technical-jj-operation-api-cli-vs-lib-surface-research-2026-06-27.md`
  — research backing ADR-0003 (30-agent jj-0.42 feasibility map; 69 ops mapped+verified; prior art GG/JayJay/VisualJJ)
- `../jj` (local, read-only) — upstream jj **monorepo** checkout (sibling of the repo root):
  both `lib/` (jj-lib source) and `cli/` (the jj CLI). Read at the pinned tag: `git -C ../jj show
  v0.46.0:lib/src/<file>` / `:cli/src/<file>` (working tree may be on `main`, ahead of the pin).
  Since jj 0.45 many jj-lib modules (`merge`, `backend`, `op_store`, `repo_path`, `file_util`, …)
  live in the `jj-core` crate (`core/src/`) and are re-exported by jj-lib under their old paths.
  The jj **CLI** orchestration (`cli/`, `cli_util`) is NOT vendored — prior art for ADR-0003 / Epic 9.
  For jj-lib reads there's a shortcut: the same crates are vendored version-exact under
  `~/.cargo/registry/.../jj-lib-0.46.0/src/…` and `…/jj-core-0.46.0/src/…` (read directly, no
  `git show`). Optional convenience;
  the build never depends on `../jj`. See CLAUDE.md § "jj source reference" for the full convention.
- `_bmad-output/planning-artifacts/architecture.md` — full architecture
  rationale (AD-1..AD-7, P-1..P-9, anti-patterns, structure)
- `_bmad-output/planning-artifacts/prd.md` — functional + non-functional
  requirements (FR-*, NFR-*)
- `_bmad-output/planning-artifacts/epics.md` — epic + story breakdown
- `_bmad-output/planning-artifacts/research/technical-zanshin-jj-flutter-dart-hooks-mcp-research-2026-05-15.md`
  — technical research backing the architecture
- `~/.claude/projects/.../memory/project_zanshin.md` — auto-memory snapshot
  of the 12 validated architectural decisions (2026-05-15)

Last Updated: 2026-09-06 (Epic 9 follow-up J: the CLI-parity anti-pattern now binds every ON-DISK, repo-side effect the CLI produces — its repo-level config rewrites included — not just op-log and refusals.)
Previously: 2026-06-27 (ADR-0003 adopted: `zanshin-jj` exposes the jj CLI's operation set as a typed verb-level API over jj-lib — we compose, consumers name the verb; no mutation primitives cross FFI (impossible — borrowed handles/locks; transaction stays Rust-side); reads add a generic `eval_revset` joker + direct `View`; a shared support module re-ports the `cli_util` orchestration jj-lib doesn't expose. Backed by the jj-0.42 feasibility map (69 ops mapped+verified). Pin bump 0.41→0.42 is the first impl step.)
Previously: 2026-06-22 (ADR-0002 adopted: the repo handle is a warm `Workspace` loader + op-heads-watcher owner that re-resolves per operation, NOT an authoritative state cache; app is multi-repo (0..N handles); FR-GR-3 lane-cache decision resolved (AC-4): the lane graph is streamed (GG model), no materialized cache — full derive ~3 ms @ 10k (Story 3.11). Performance-gotchas + handle-semantics sections reconciled.)
Previously: 2026-06-20 (Relicensed Apache-2.0 → MIT per OD-2; SPDX headers, `LICENSE`, `Cargo.toml`, and planning docs updated. Apache-2.0 remains an accepted *dependency* license.)
Previously: 2026-06-17 (AR-P-5 revised: Dart logs forward to the Rust sink via `zanshin_log`; supersedes the original "no Dart logger" clause)
Previously: 2026-06-15 (ADR-0001: FlatBuffers FFI transport supersedes the JSON envelope)
