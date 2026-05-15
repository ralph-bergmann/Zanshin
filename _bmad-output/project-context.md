---
project_name: 'Zanshin'
user_name: 'Ralph'
date: '2026-05-15'
sections_completed:
  ['technology_stack', 'language_specific_rules', 'framework_specific_rules', 'testing_rules', 'code_quality_and_style', 'development_workflow', 'critical_dont_miss']
status: 'complete'
optimized_for_llm: true
overrides:
  - 'architecture.md § P-9 (no per-file license headers) — superseded by SPDX-Identifier rule in Code Quality & Style'
scope_reminder: 'Rust workspace + FFI + MCP + build/distribution + minimal Dart bootstrap. Flutter UI is OUT OF SCOPE (Ralph''s separate work).'
---

# Project Context for AI Agents

_This file contains critical rules and patterns that AI agents must follow when implementing code in this project. Focus on unobvious details that agents might otherwise miss._

---

## Technology Stack & Versions

**Toolchain (systemwide installs — NO FVM, NO rustup overrides per-project):**
- Flutter `3.41.9`
- Dart `3.11.5`
- Rust `1.95.0` (pinned via `rust-toolchain.toml`)

**Rust workspace (5 lib crates + 1 bin + xtask):**
- `jj-lib` `=0.41.0` (pre-1.0 — pin exact; churn absorbed in `zanshin-jj`)
- `rmcp` `=1.7.0` (pin exact)
- `imara-diff` `=*` (pin exact — Histogram algorithm)
- `tree-sitter-highlight`
- `notify` + `notify-debouncer-full` (50ms window, AD-5)
- `tracing` + `tracing-appender`
- `serde` / `serde_json` (workspace deps)
- `jsonschema` (test-only, schema validation)
- `insta` (test-only, snapshots)
- `cargo-deny` (CI license + advisory gate)

**Dart shell (`app/`):**
- `native_toolchain_rust` `1.0.4` (Dart Hook for Rust)
- `ffigen` `20.1.1` (dev_dependency)
- `hooks` (Dart Hooks runtime)
- `json_schema` (test-only)
- `package:flutter_lints` + selected `package:very_good_analysis` rules
- `pana` (global, CI license gate)

**Build & distribution:**
- `cargo-make` (`Makefile.toml` — single entry point)
- `cbindgen` (C header generation, committed output)
- Apple Developer ID codesigning + `notarytool` notarization
- Sparkle `2.x` (auto-update, EdDSA-signed appcast)
- GitHub Releases (primary distribution channel)

**Platform constraints:**
- macOS-only. Windows/Linux are explicit non-goals.
- Watchman is a runtime system dependency of jj's `fsmonitor`, NOT bundled.
  Zanshin only detects its presence (FR-FFI-7).

**Version pinning rules:**
- Load-bearing pre-1.0 crates: `=x.y.z` exact pins (`jj-lib`, `rmcp`, `imara-diff`).
- Stable crates: caret (`^x.y.z`).
- `default-features = false` requires inline `# WHY:` comment.
- No `[patch.crates-io]` while in 0.x.
- Generated code (`zanshin_ffi.h`, `bindings.dart`) is COMMITTED — build never regenerates.

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
  into the JSON envelope's `error.code` (AR-P-4 taxonomy: `<domain>.<reason>`).
- Async: `tokio` only where required by a dependency (e.g. `rmcp`, `notify-debouncer-full`).
  `zanshin-jj` is sync — jj-lib's APIs are sync, do not wrap them in `async`.
- Shared workspace deps: declare in `[workspace.dependencies]`, consume via
  `serde = { workspace = true }` in member crates.

**Dart:**
- Strict mode is implicit (Dart 3.x). Sound null safety always on.
- `analysis_options.yaml` extends `package:flutter_lints` + selected `very_good_analysis`
  rules. `dart format` enforced in CI.
- `dart:ffi` boundary lives ONLY in `app/lib/src/ffi/`. No `dart:ffi` imports elsewhere
  in `lib/`.
- Async: use `Future`/`Stream` plus the single long-running worker isolate (AD-4).
  Never `Isolate.run` for repeated work — send a `WorkerCommand` instead.
- Use `sealed class` for `WorkerCommand` hierarchy so the dispatcher's `switch`
  is exhaustive (compile-time guarantee).
- `NativeFinalizer` MUST be attached to every Dart wrapper holding a Rust handle.
  Even though explicit `close()` is the canonical lifecycle, the finalizer is the
  belt-and-suspenders against forgotten closes during development.
- Logging on Dart side: `dart:developer` `log()` only for isolate-spawn failures.
  Do NOT add a package-level logger (Rust owns the logs; see AR-P-5).

**FFI boundary (Rust ↔ Dart):**
- Strings cross as `*mut c_char` (CString). Rust owns the allocation;
  Dart calls `zanshin_string_free(ptr)` to release. Never `malloc`/`free` mismatched.
- All faillible `extern "C"` functions return the JSON envelope (AD-1):
  `{ "ok": bool, "data": <payload>|null, "error": {...}|null, "schema_version": "x.y" }`.
- Infallible hot-path functions (`zanshin_ffi_version`, `zanshin_string_free`) return
  plain types directly — no envelope overhead.
- JSON field naming: `snake_case` over the wire (committed in `schemas/*.schema.json`).
  Dart side uses `@JsonKey(name: '...')` to translate to `lowerCamelCase`.
- Schema files in `schemas/*.v1.schema.json` are the source of truth.
- Every test that produces OR consumes JSON crossing the FFI boundary MUST validate
  the JSON against the relevant schema. Rust tests use the `jsonschema` crate;
  Dart tests use the `json_schema` package. A test that asserts on JSON without
  schema-validating it first is incomplete and must be rejected in review.
  This applies to: snapshot fixtures (`insta`), golden outputs, hand-crafted
  test inputs, and any JSON returned by `extern "C"` functions under test.
  Reason: the schema is the wire contract; tests that bypass it can pass while
  the contract is silently broken.
- Schema-breaking change → new FFI function `_v2` suffix (e.g. `zanshin_get_status_v2`).
  Old function stays callable until next major release.

### Framework-Specific Rules

**`zanshin-jj` — jj-lib adapter (anti-corruption layer):**
- ALL jj access goes through `zanshin-jj` → `jj-lib`. No shelling to the `jj` CLI.
  No string-parsing of `jj` output. Fixture-setup scripts may shell out; production
  code may not. (FR-JJ-16, NFR-R-1)
- `zanshin-jj` is the ONLY crate that imports `jj_lib`. Other internal crates
  consume `zanshin-jj`'s typed API, not jj-lib directly.
- When jj-lib's API changes (it will — pre-1.0), absorb the diff inside `zanshin-jj`'s
  module body. The crate's public surface stays stable. Mutations are visible in
  `jj op log` indistinguishably from CLI-initiated ones (NFR-R-2).

**Dart Hooks + `native_toolchain_rust`:**
- `app/hook/build.dart` is the ONLY Dart Hook. It points at `zanshin-ffi`:
  `manifestPath: '../crates/zanshin-ffi/Cargo.toml'`.
- Dart Hooks build ONLY `zanshin-ffi` (the single cdylib). Internal Rust crates
  stay pure `lib`; they have no `extern "C"` surface. (FR-FFI-1)
- Never adopt `flutter_rust_bridge` or comparable FFI abstractions. The cbindgen +
  ffigen chain is deliberately manual to avoid version-churn pain.

**`zanshin-ffi` — single cdylib boundary:**
- `crate-type = ["cdylib"]` lives only in `crates/zanshin-ffi/Cargo.toml`.
- Module layout: `lib.rs` (init, panic handler, `zanshin_ffi_version`),
  `envelope.rs` (JSON envelope), `handle.rs` (`Box<T>` ↔ `*mut T`, panic-catch
  wrapper), `ffi_strings.rs` (CString in/out), then one file per noun
  (`repo.rs`, `diff.rs`, `graph.rs`, `watcher.rs`).
- All `extern "C"` symbols: `zanshin_<noun>_<verb>` snake_case.
  Constructor/destructor pairs share noun: every `_open` has matching `_close`.
- Single-threaded Rust-side access. NO `Arc<Mutex<T>>` / `RwLock` around handles.
  The Dart worker isolate is the sole consumer (AD-2).
- Async Rust→Dart signals: `NativeCallable.listener` ONLY. Same mechanism for
  watcher events AND progress notifications — no special-case channels.

**Watcher subsystem (inside `zanshin-ffi`):**
- Watch TWO paths: `.jj/repo/op_heads/heads/` (primary, real state mutations) and
  `.jj/repo/working_copy/checkout` (heartbeat, fires on any jj activity).
- Use `notify-debouncer-full` with a 50ms debounce window. Bounded `tokio::mpsc`
  channel, capacity 256. On full: drop-oldest with `tracing::warn!`. NEVER panic
  or block the watcher thread. (AD-5)
- The watcher must start BEFORE `zanshin_repo_open` returns. No race window
  where mutations happen before the watcher is armed.
- Watchman is NOT bundled, called, or linked. Zanshin only DETECTS its presence
  and reads `.jj/repo/config.toml` for `fsmonitor.backend = "watchman"` +
  `register-snapshot-trigger = true` (FR-FFI-7). When absent, the app still
  works — external-edit reactivity just degrades.

**Worker isolate (Dart, AD-4):**
- ONE worker isolate spawned at app start via manual `Isolate.spawn` +
  `SendPort`/`ReceivePort`. The worker holds all FFI handles for app lifetime.
- Commands (UI → Worker): typed `sealed class WorkerCommand` subclasses.
- Responses (Worker → UI): JSON strings — the same JSON that crossed FFI.
  Parsed by the requesting code into typed result classes.
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
  NO locking choreography between them.

### Testing Rules

**Test layout:**
- Rust unit tests inline: `#[cfg(test)] mod tests { ... }` at bottom of the module
  they test. Integration tests in each crate's `tests/` directory.
- Dart unit tests in `app/test/` mirroring `lib/src/` layout.
- E2E tests in `app/integration_test/` — boot a real worker isolate and a real
  compiled cdylib. The isolate boundary is NEVER mocked.
- No `#[ignore]` / `skip:` on tests for "flakiness" reasons. Either the test is
  deterministic or it's deleted.

**Fixtures:**
- Repository fixtures live at `test-fixtures/repos/` as compressed
  `.tar.zst` archives: `tiny-3-commits/`, `medium-1k-commits/`, `large-10k-commits/`.
- Fixtures are COMMITTED. They are NOT rebuilt at test time.
- Regeneration happens via `cargo xtask gen-fixture` and is a deliberate, reviewed
  PR — never an automatic side-effect of running tests.
- Diff input fixtures in `test-fixtures/diffs/`; expected golden outputs in
  `test-fixtures/golden/`.

**JSON / schema validation in tests:**
- Every test that produces or consumes JSON crossing the FFI boundary MUST
  schema-validate the JSON before any assertion on it (see Language-Specific
  Rules § FFI boundary). Tools: `jsonschema` (Rust), `json_schema` (Dart).
- Snapshot tests via `insta` for Rust JSON outputs. Snapshots are committed and
  reviewed; `cargo insta accept` is a deliberate step, not automatic.
- Test fixtures that violate the schema are a bug in the FIXTURE, not in the test.

**Worker / isolate testing (Dart):**
- Dart tests that exercise the worker isolate boot the REAL `Isolate.spawn` flow
  and the real ffigen bindings against the real cdylib. No mocked isolates,
  no mocked FFI surface.
- The cdylib must be built (`cargo make build` or equivalent) before the Dart
  test suite runs. CI gates this explicitly.

**Performance assertions:**
- Performance budgets (NFR-P-*) have corresponding tests:
  - `zanshin-graph`: 10k-commit fixture, lane-cache build < 1s (NFR-P-1 sub-budget,
    FR-GR-5).
  - `zanshin-diff`: 5k-line file, JSON output < 500ms (NFR-P-3).
  - Watcher latency: filesystem mutation → callback < 200ms in tests (real budget
    is < 100ms per NFR-P-4; test bound absorbs CI noise).
  - Repo-open: 10k-commit fixture, full open < 2s (NFR-P-1).
- Performance tests run on every CI build, not just release. A perf regression
  is a CI failure, not a warning.
- Test only against committed fixtures of known size. Do not generate
  variable-size inputs at test time.

**MCP server tests:**
- Tool descriptions are validated by an `mcp-tester` smoke run in CI (FR-MCP-5).
- Same-repo concurrency: an integration test boots the GUI worker + the MCP
  binary against the same fixture repo and asserts that a mutation through one
  channel propagates to the other via the watcher (FR-RX-3).

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
- JSON keys: `snake_case` over the wire. Internal Dart classes use
  `lowerCamelCase` via `@JsonKey(name: '...')`.
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
    `// SPDX-License-Identifier: Apache-2.0`
  Single line, machine-readable, satisfies the patent-grant-visibility rationale
  that drove the Apache-2.0 choice (OD-2). No full Apache boilerplate — SPDX +
  repo-root `LICENSE` is the canonical pattern.
  Note: this OVERRIDES `architecture.md` § P-9, which predates this decision.
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
- `analysis_options.yaml`: `package:flutter_lints` + selected `very_good_analysis`
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
- `cargo make build` — full build, produces unsigned `.app` in
  `app/build/macos/Build/Products/Release/Zanshin.app` (dev mode).
- `cargo make test` — Rust workspace tests + Dart bootstrap tests + license
  compliance (`cargo-deny` + `pana`) + codegen drift check.
- `cargo make codegen` — regenerates `zanshin_ffi.h` (cbindgen) and
  `bindings.dart` (ffigen). RUN MANUALLY whenever an `extern "C"` signature
  changes. Commit the regenerated files in the same PR.
- `cargo make verify-codegen` — CI gate: re-runs codegen into tmpdir, diffs
  against committed files, fails on drift.
- `cargo make sign` / `cargo make notarize` — explicit signing/notarization
  targets for environments with restricted creds.
- `cargo make release` — full release pipeline (build → sign → notarize →
  Sparkle appcast → tag → GitHub Releases upload). Tag-push triggered only.
- `flutter run -d macos` — for UI work only (Ralph's separate scope).
  Requires a prior `cargo make build` so the cdylib is present.

**Codegen workflow:**
- Generated files (`crates/zanshin-ffi/include/zanshin_ffi.h`,
  `app/lib/src/ffi/bindings.dart`) are COMMITTED to the repo.
- Build never auto-regenerates. The only path to update them is
  `cargo make codegen` followed by an explicit commit.
- CI's `verify-codegen` target rejects PRs where the committed generated files
  drift from what regeneration would produce.
- Reason: code review must see the diff of generated code, not pretend it
  doesn't exist. Reproducibility requires that two builds of the same SHA
  produce byte-identical artefacts (FR-BO-8), which auto-regen would break.

**CI gates (every PR, on `main` branch protection):**
- `cargo clippy -- -D warnings` (workspace-wide, pedantic on)
- `cargo fmt --check`
- `cargo test --workspace` (Rust unit + integration + performance tests)
- `dart analyze --fatal-infos --fatal-warnings`
- `dart format --set-exit-if-changed`
- `flutter test` + `flutter test integration_test`
- `cargo deny check licenses advisories` (NFR-L-3)
- `pana --no-warning` against `app/` package
- `cargo make verify-codegen`
- `mcp-tester` smoke run against `zanshin-mcp` (FR-MCP-5)
- Performance budget tests (`cargo make perf` or equivalent — see Testing Rules)
- Reproducibility check on tags + weekly (separate workflow,
  `reproducibility.yml`).

**Git / repo conventions:**
- Branch protection on `main`. No direct pushes; all changes via PR.
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
  regenerated `zanshin_ffi.h` + `bindings.dart`. CI enforces this via
  `verify-codegen`.
- For schema changes: the PR includes the schema diff (`schemas/*.json`) +
  the version bump (additive → minor, breaking → new `_v2` FFI function).
- For new error codes: `docs/rust-error-codes.md` is updated in the same PR.

**Release flow (Epic H, FR-DR-1..6):**
- Releases are tag-driven. `v0.1.0`, `v0.1.1`, `v0.2.0`, etc. (SemVer).
- `.github/workflows/release.yml` runs on tag push: `cargo make release`.
- Codesign credentials live in encrypted GitHub Secrets. Never printed in CI
  logs. The signing step is the only stage that touches the secrets.
- Sparkle EdDSA private key lives in GitHub Secrets. Public key is committed
  at `sparkle/ed25519_pub.pem`.
- No silent auto-updates. Sparkle prompts the user before installing.
- No release without notarization. `notarytool` failure fails the workflow.

**License compliance (NFR-L-3):**
- `cargo deny check licenses advisories` runs in CI. Forbidden: GPL (any),
  AGPL, LGPL, SSPL, custom non-OSI. Permitted: MIT, BSD-2/3, Apache-2.0,
  MPL-2.0, Unlicense, CC0.
- `pana` validates Dart `pubspec.yaml` dependencies' SPDX metadata.
- Before adding any new dep: run `cargo deny check licenses` locally first.
  CI as a backstop, not as the primary check.

**No-telemetry constraint (NFR-PRIV-1..4):**
- Adding Sentry / Crashlytics / Firebase / Datadog / any analytics SDK is a
  HARD-BLOCK at review. Not a warning, not a discussion — rejected at the
  first sight of the dependency.
- The Sparkle update check is the ONLY outbound network call in the shipped
  app. User-Agent only; no identifying payload.
- Crash logs are LOCAL: `~/Library/Logs/Zanshin/`. No upload, no
  auto-collection, no opt-in dialog.

### Critical Don't-Miss Rules

**Hard-banned anti-patterns (reject at review on first sight):**

- **NEVER shell out to the `jj` CLI** in production code. All jj access goes
  through `zanshin-jj` → `jj-lib`. Fixture-setup scripts may shell out;
  production code may not. (NFR-R-1, FR-JJ-16)
- **NEVER parse `jj` CLI output strings.** Even for "just a quick lookup".
  Structured access through the adapter is the WHOLE POINT.
- **NEVER add `extern "C"` functions outside `crates/zanshin-ffi/`.** Internal
  crates stay pure-Rust `lib`. The single-cdylib boundary is non-negotiable.
- **NEVER adopt `flutter_rust_bridge`** or any comparable FFI abstraction.
  The cbindgen + ffigen chain is deliberately manual.
- **NEVER add Sentry / Crashlytics / Firebase / Datadog / analytics SDKs.**
  No telemetry. Ever. (NFR-PRIV-1)
- **NEVER add GPL / AGPL / LGPL / SSPL dependencies.** `cargo-deny` will fail
  CI; run `cargo deny check licenses` locally before adding any dep.
- **NEVER regenerate `bindings.dart` or `zanshin_ffi.h` outside
  `cargo make codegen`.** CI drift-check catches it; don't waste the cycle.
- **NEVER use `Isolate.run` for repeated work** in Dart. Send the work as a
  `WorkerCommand` on the existing worker bus.
- **NEVER invent alternative JSON envelope shapes.** Faillible FFI functions
  use the AD-1 envelope; infallible functions return plain types. No exceptions.
- **NEVER add per-call locking** (`Arc<Mutex<T>>`, `RwLock`) around handles.
  The concurrency model is single-threaded Rust-side (AD-2).
- **NEVER let stdout/stderr leak from `zanshin-mcp`.** It corrupts MCP stdio
  protocol — file-only tracing in ALL build modes, no exceptions.
- **NEVER write Flutter UI code in this scope.** Widgets, layout, navigation,
  theming, a11y, i18n are Ralph's separate work. Stick to API surfaces.
- **NEVER plan with an "MVP" / "good enough for now" mindset.** Production-grade
  from day one.
- **NEVER `--amend` a published commit or force-push without explicit
  authorization.** New commit, not amend.

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
  `op_heads` changing. Adding any cross-process lock breaks the model.
  (FR-MCP-9, FR-RX-3)
- **Generated code is committed; build doesn't regenerate.** When an
  `extern "C"` signature changes, run `cargo make codegen` and commit BOTH the
  source change and the regenerated header/bindings in the same PR. Forgetting
  this trips CI's `verify-codegen`.
- **JSON `schema_version` field is mandatory** on every top-level object across
  FFI. Even a tiny status response carries it. Forgetting it breaks the
  versioning contract silently.
- **Watchman absence is degradation, not failure.** Repo-open succeeds without
  Watchman; external-edit reactivity just becomes "refresh on jj operation only".
  Don't treat the absence as an error to surface — surface it as configuration
  guidance.
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
- **No secrets in CI logs.** Codesign creds, Sparkle EdDSA private key,
  notarytool credentials — all encrypted GitHub Secrets, never echoed.
- **No PII at `info` or above** in logs. Commit messages, file paths, change
  IDs are `debug`-level only and compiled out in release.

**Performance gotchas:**

- **Lane-cache rebuild on EVERY `op_heads` change**, not just on repo-open.
  Don't add staleness checks that skip rebuilds — the cache becomes wrong
  silently. The whole rebuild fits in NFR-P-1's < 1s sub-budget at 10k commits.
- **`zanshin-graph` render-slice is O(slice-size), not O(full-cache).**
  Hand-rolled iteration over the cache per render call would tank UI scrolling
  performance. Use the slice API.
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
- `_bmad-output/planning-artifacts/architecture.md` — full architecture
  rationale (AD-1..AD-7, P-1..P-9, anti-patterns, structure)
- `_bmad-output/planning-artifacts/prd.md` — functional + non-functional
  requirements (FR-*, NFR-*)
- `_bmad-output/planning-artifacts/epics.md` — epic + story breakdown
- `_bmad-output/planning-artifacts/research/technical-zanshin-jj-flutter-dart-hooks-mcp-research-2026-05-15.md`
  — technical research backing the architecture
- `~/.claude/projects/.../memory/project_zanshin.md` — auto-memory snapshot
  of the 12 validated architectural decisions (2026-05-15)

Last Updated: 2026-05-15
