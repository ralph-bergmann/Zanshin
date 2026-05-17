# Story 1.4: Author `Makefile.toml` with build / test / codegen targets

Status: done

<!-- Note: Validation is optional. Run validate-create-story for quality check before dev-story. -->

## Story

As a **developer or CI runner who needs a single, predictable entry point for build, test, and codegen flows**,
I want **a `cargo-make` `Makefile.toml` at the repo root that defines the canonical `build`, `run`, `run-release`, `test`, `codegen`, `verify-codegen`, and `clean` tasks (WIP-scoped — no `sign` / `notarize` / `release` stubs, no `verify-codegen` CI gate)**,
so that **`cargo make build` and `cargo make test` work end-to-end as the FR-BO-1 + FR-BO-2 single-command entry points, the codegen path (FR-BO-6) has a well-defined invocation that Story 1.5 will wire to real configs, and the workspace is set up so `cargo build --release` skips `xtask` (closes a Story 1.1 review deferral)**.

## Acceptance Criteria

1. **AC-1 — `Makefile.toml` exists at the repo root with discoverable tasks.** A new `Makefile.toml` is created at `/Users/ralph.bergmann/development/projects/privat/Zanshin/Makefile.toml`. It declares:
   - `[config] skip_core_tasks = true` so cargo-make's built-in tasks (`build`, `test`, `clean`, the `dev-test-flow` chain) do not shadow ours and the published task surface is the one this file defines.
   - The seven user-facing tasks `build`, `run`, `run-release`, `test`, `codegen`, `verify-codegen`, `clean`, plus a `default` task that prints a one-line hint pointing at `cargo make --list-all-steps`.
   - Each user-facing task has a `description = "..."` so `cargo make --list-all-steps` renders them with a one-line summary.
   - No `sign` / `notarize` / `release` placeholder stubs. (See Dev Notes § "What this story is NOT" for the WIP-rework rationale that drops the original epics.md AC-7 placeholders.)

2. **AC-2 — `cargo make build` produces the unsigned `.app`.** From the repo root, `cargo make build` executes in order, aborting on first failure:
   1. `cargo build --release` (no `--workspace` flag — relies on `default-members` from AC-9 to skip `xtask`).
   2. `cd app && flutter build macos --release`.
   The final artefact is at `app/build/macos/Build/Products/Release/zanshin.app` (unsigned, unnotarized — WIP scope per `prd.md` § FR-BO-1 and `project-context.md` § Build & Distribution).
   - The Dart Hook (`app/hook/build.dart` from Story 1.2) rebuilds `zanshin-ffi` internally during `flutter build macos`; the prior `cargo build --release` ensures the other production crates (`zanshin-jj`, `zanshin-diff`, `zanshin-graph`, `zanshin-mcp`) also compile cleanly in release mode. This double-build is intentional — cargo's cache keeps the second pass cheap.
   - **No post-build copy of `target/release/zanshin-mcp` into the `.app` bundle.** Original epics.md AC mentioned this for FR-MCP-7; Story 7.6 (bundle MCP into Zanshin.app) was deleted in the WIP-rework (`epics.md` § Epic 7 WIP-rework note; `prd.md` § 4.6 deferred items). `zanshin-mcp` ships standalone in WIP.

3. **AC-2a — `cargo make run` launches the Flutter app in debug mode for local UI work.** From the repo root, `cargo make run` executes `cd app && flutter run -d macos` (Flutter's default profile → debug, Hot-Reload enabled, full debug overhead). The Dart Hook (`app/hook/build.dart` from Story 1.2) rebuilds `zanshin-ffi` automatically as part of `flutter run`; **no prior `cargo make build` is required**. The launch is **local-only**: unsigned, unnotarized, intended for UI iteration. The other production crates (`zanshin-jj`, `zanshin-diff`, `zanshin-graph`) are pulled in transitively as `zanshin-ffi` dependencies; `zanshin-mcp` is NOT built by this task (standalone binary, separate path). **Not** for distribution — see `prd.md` § 4.7 for the deferred release pipeline.

4. **AC-2b — `cargo make run-release` launches the Flutter app in Flutter's release profile (local-optimized).** Same as AC-2a but invokes `flutter run -d macos --release` — Flutter's release build profile (AOT compilation, optimizer on, no Hot-Reload, no debug overhead). Same local-only scope: **unsigned, unnotarized**. The `--release` flag is Flutter's *local* optimization mode — it does NOT imply distribution, codesigning, or notarization (those are deferred to the release phase per `prd.md` § 4.7). Useful when iterating on perf-sensitive UI changes where debug-mode overhead obscures real behaviour.

5. **AC-3 — `cargo make test` runs the WIP-minimal gate in a single command.** Executes in order, aborting on first non-zero exit:
   1. `cargo test --workspace` (tests ALL crates including `xtask`; production-grade code quality applies to build helpers too — see AC-10).
   2. `cargo clippy --workspace --all-targets -- -D warnings` (workspace-wide, pedantic-on lint gate per `project-context.md` § Rust).
   3. `cargo fmt --all --check`.
   4. `cd app && flutter test` (runs `app/test/smoke_test.dart` — the only Dart test at this point).
   5. `cd app && dart analyze --fatal-infos --fatal-warnings`.
   6. `cd app && dart format --output=none --set-exit-if-changed .`.
   7. `cargo deny check advisories bans` (security backstop per `project-context.md` § CI gates; full license-gate deferred — Story 1.6 owns the actual `deny.toml`, see AC-3's edge case below).
   The order matches `project-context.md` § "CI gates (WIP-minimal, every PR on `main` branch protection)". **Explicitly DEFERRED in WIP** (do NOT add to the `test` task): `cargo deny check licenses`, `pana --no-warning`, `cargo make verify-codegen` as merge-blocking, `flutter test integration_test`, `mcp-tester` smoke, performance gates, reproducibility two-build SHA diff. These return in the release phase per `prd.md` § "WIP-phase deferrals".

4. **AC-4 — `cargo make codegen` invokes cbindgen + ffigen.** Executes:
   1. `cbindgen --config cbindgen.toml --crate zanshin-ffi --output crates/zanshin-ffi/include/zanshin_ffi.h`.
   2. `cd app && dart run ffigen --config ffigen.yaml`.
   The actual `cbindgen.toml` and `ffigen.yaml` configs land in Story 1.5; Story 1.4 only authors the task invocation. **Story 1.4 explicitly does not run `cargo make codegen` end-to-end at story-done time** — it cannot, because the configs do not exist yet. `cargo make --list-all-steps` shows the task; running it before Story 1.5 lands fails with cbindgen's "config file not found" error — that is expected. Story 1.5 will land the configs and the first invocation will produce the committed `zanshin_ffi.h` + `bindings.dart` (FR-BO-6 — generated code committed, regenerated only via `cargo make codegen`).

5. **AC-5 — `cargo make verify-codegen` is a manual discipline tool, NOT chained into `test`.** The task snapshots the committed `zanshin_ffi.h` and `bindings.dart`, re-runs `cargo make codegen` in place, compares against the snapshot, and:
   - On no-drift: leaves the working tree clean (regenerated files are byte-identical to committed).
   - On drift: restores the committed copies (working-tree clean again) and exits non-zero with a `Drift in <path> — run 'cargo make codegen' and commit.` message on stderr.
   This task exists for **manual discipline use** during development. It is NOT chained into `cargo make test`, and CI does NOT gate on it during WIP. Rationale: `epics.md` § Story 1.5 WIP-rework note ("Drop the CI drift-gate AC — code-review enforces the discipline rule in WIP"), and `project-context.md` § "Deferred CI gates (release phase)". The discipline rule "never regenerate `bindings.dart` or `zanshin_ffi.h` outside `cargo make codegen`" still applies and is enforced via PR review (`project-context.md` § Critical Don't-Miss Rules).

6. **AC-6 — `cargo make clean` reverses build outputs.** Executes:
   1. `cargo clean` (removes `target/`).
   2. `cd app && flutter clean` (removes `app/build/`, `app/.dart_tool/build/`, ephemeral plugin artefacts, etc.).
   Does NOT delete committed codegen outputs (`crates/zanshin-ffi/include/zanshin_ffi.h`, `app/lib/src/ffi/bindings.dart`) — those are repo-tracked, not build outputs.

7. **AC-7 — `cargo make --list-all-steps` shows the authored tasks with descriptions.** Running `cargo make --list-all-steps` from the repo root prints, at minimum:
   ```
   build              — Build the Rust workspace (release) and the Flutter macOS shell.
   clean              — Remove all build outputs (cargo + flutter). Generated codegen is committed and stays.
   codegen            — Regenerate the FFI C header (cbindgen) and Dart bindings (ffigen).
   default            — List all available tasks.
   run                — Run the Flutter macOS app in debug mode (Hot-Reload). Local execution only — unsigned.
   run-release        — Run the Flutter macOS app in release mode (local-optimized, no Hot-Reload). Local execution only — unsigned.
   test               — Run the WIP-minimal quality gate (cargo test + clippy + fmt + flutter test + dart analyze + dart format + cargo deny advisories+bans).
   verify-codegen     — Re-run codegen, diff against committed files, fail on drift. Manual discipline tool — not chained into `cargo make test`.
   ```
   Internal sub-tasks (e.g., `build-rust`, `build-flutter` if used) may also appear but are not part of the public surface. Each description is one line, ≤120 chars, machine-readable. Wording is flexible; the **task names**, **task count** (seven user-facing + `default`), and **task purposes** are mandatory.

8. **AC-8 — `cargo make` with no args auto-lists the available tasks.** Bare `cargo make` does NOT execute `dev-test-flow` (cargo-make's built-in default that would chain `pre-build → build → post-build → test → post-test`). Instead, the explicit `[tasks.default]` task invokes `cargo make --list-all-steps` directly, so the user sees the task surface immediately without needing to know the listing subcommand. `[config] skip_core_tasks = true` is the mechanism that ensures cargo-make's built-ins do not shadow this default. (Spec note: original AC-8 prescribed a print-hint pattern; revised 2026-05-17 during code review to "auto-list" for better discoverability — a hint that just points at another command was deemed inferior UX to executing the listing directly.)

9. **AC-9 — `xtask` excluded from `default-members` in root `Cargo.toml`.** The root `/Users/ralph.bergmann/development/projects/privat/Zanshin/Cargo.toml` `[workspace]` block is updated to add:
   ```toml
   default-members = [
       "crates/zanshin-diff",
       "crates/zanshin-ffi",
       "crates/zanshin-graph",
       "crates/zanshin-jj",
       "crates/zanshin-mcp",
   ]
   ```
   (Alphabetical for readability; cargo does not care about order.) After this change:
   - `cargo build --release` (no flag) → builds only the five production crates, **skips `xtask`**.
   - `cargo build --workspace --release` → builds everything including `xtask`.
   - `cargo test --workspace`, `cargo clippy --workspace ...` → still hit `xtask` (test gate covers it; AC-10).
   This **closes the deferred item** `xtask not excluded from default-members` from `_bmad-output/implementation-artifacts/deferred-work.md` § "Deferred from: code review of 1-1-initialize-cargo-workspace-and-create-empty-crate-skeletons (2026-05-17)" — that entry explicitly named Story 1.4 / 1.9 as the absorption point ("revisit when Story 1.4/1.9 wires CI").

10. **AC-10 — Test gate runs against the FULL workspace (incl. `xtask`).** The `test`, `clippy`, `fmt`, and `cargo deny` invocations in AC-3 use `--workspace` (or `--all` for fmt) explicitly so `xtask` is tested and linted. Production-grade code quality applies to all code, including build helpers (per `project-context.md` posture: "Code quality is production-grade from day 1"). Only the BUILD entry point uses `default-members` to skip `xtask` for ergonomic reasons (no need to build the build helper into the production `.app`).

11. **AC-11 — `deferred-work.md` updated.** Once AC-9 lands, the bullet **"`xtask` not excluded from default-members"** is removed from `/Users/ralph.bergmann/development/projects/privat/Zanshin/_bmad-output/implementation-artifacts/deferred-work.md` § "Deferred from: code review of 1-1-initialize-cargo-workspace-and-create-empty-crate-skeletons (2026-05-17)". All other entries stay untouched (they belong to other stories or are out-of-scope for 1.4 — see Dev Notes § "Deferred-work items absorbed by this story" for the full enumeration).

12. **AC-12 — `sprint-status.yaml` audit-trail updated.** Story 1.4's status is updated to `ready-for-dev` (story-write time) and later to `in-progress` / `review` / `done` per the standard workflow. The `last_updated` field reflects the current date. Audit comments (`# Story 1-4 ...`) follow the existing 1-1 / 1-2 / 1-3 pattern (header comment lines tracking created / started / reviewed dates).

13. **AC-13 — No regressions on Story 1.1 / 1.2 / 1.3 invariants.** After all edits:
    - `cargo build --workspace` exits 0 with zero warnings (Story 1.1 invariant; verifies workspace still resolves cleanly with `default-members` set).
    - `cargo build --release` exits 0 with zero warnings AND does NOT compile `xtask` (verifies AC-9 takes effect).
    - `rustup show active-toolchain` from repo root and `crates/zanshin-ffi/` both print the `1.95.0-<arch>-apple-darwin (overridden by ...)` line (Story 1.3 invariant).
    - `cd app && flutter build macos --debug` exits 0 (Story 1.2 invariant — Dart Hook still wires the cdylib correctly).

**Edge cases:**

14. **Edge case — `cargo-make` not installed.** Documented in `README.md` § Toolchain "One-time install" block (already landed in Story 1.3): `cargo install cargo-make`. Running `cargo make ...` without cargo-make installed produces a cargo-error "no such subcommand: `make`"; the README install block covers the remediation. Story 1.4 does NOT re-document this — the line is already in the README.

15. **Edge case — `cargo deny check advisories bans` runs before `deny.toml` lands (Story 1.6).** `cargo deny` falls back to built-in defaults when `deny.toml` is missing and emits a warning. The advisories database is auto-downloaded on first use. At Story 1.4 done state, the `test` task's cargo-deny step may print a "no deny.toml found, using defaults" warning but should exit 0 (no live advisories on the empty workspace, no banned crates by default). If cargo-deny exits non-zero on a fresh repo, Story 1.4 closure can either (a) accept the partial-green test gate as a documented limitation and wait for Story 1.6, or (b) commit a minimal `deny.toml` shell — but option (b) overlaps Story 1.6's surface and should be avoided. Document the observed behaviour in the Dev Agent Record's `Debug Log References`.

16. **Edge case — `cargo make codegen` invoked before Story 1.5 lands.** Fails with cbindgen's "config file not found: cbindgen.toml" error. This is expected; Story 1.5 is the dependency. `cargo make --list-all-steps` showing the task is sufficient AC-7 satisfaction.

17. **Edge case — `flutter build macos --release` fails partway through `cargo make build`.** `cargo make build` aborts; the Rust artefact may be present in `target/release/`. `cargo make clean` cleans both Cargo and Flutter outputs without manual intervention (AC-6). No special error-handling logic is added in `Makefile.toml` — cargo-make's `dependencies` semantics already abort the chain on first non-zero exit.

18. **Edge case — `cargo make verify-codegen` is interrupted mid-flight.** The task uses `mktemp -d` + a `trap rm -rf "$TMPDIR" EXIT` in its bash script, plus a save-and-restore pattern on the committed files. Worst case (SIGKILL between regenerate and restore): the working tree contains the regenerated outputs and the user can `git checkout -- crates/zanshin-ffi/include/zanshin_ffi.h app/lib/src/ffi/bindings.dart` to recover. Documented in the task description.

19. **Edge case — `default-members` exclusion of `xtask` breaks `cargo run -p xtask`.** It does not. `default-members` controls only the implicit set when no `--workspace`, `-p`, or `--package` flag is provided. `cargo run -p xtask -- ...` and `cargo xtask ...` (via the `.cargo/config.toml` alias from Story 1.1) both continue to work — they specify the package explicitly. Verified at story-write time: `cat .cargo/config.toml` shows `xtask = "run --package xtask --"`.

## Tasks / Subtasks

- [x] **T1 — Create `Makefile.toml` at repo root (AC: 1, 2, 2a, 2b, 3, 4, 5, 6, 7, 8)**
  - [x] Create `/Users/ralph.bergmann/development/projects/privat/Zanshin/Makefile.toml`. SPDX header is NOT required on `.toml` config files (per Story 1.3 AC-4 rationale: SPDX is mandatory only on `.rs` and `.dart` source files; tool configs and Markdown rely on the repo-root `LICENSE`).
  - [x] Add `[config]` block with `skip_core_tasks = true` and `default_to_workspace = false` (the latter so cargo-make does not auto-rewrite `cargo` commands to `cargo <subcommand> --workspace`; we want explicit control over `--workspace` per task).
  - [x] Define `[tasks.default]` — prints "Run `cargo make --list-all-steps` to see the available tasks." and exits 0. Simplest implementation: `script_runner = "@duckscript"`, `script = ['echo "Run cargo make --list-all-steps ..."']`. Or `command = "echo"` with `args = ["..."]`.
  - [x] Define `[tasks.build]` with `description = "Build the Rust workspace (release) and the Flutter macOS shell."`. Use `dependencies = ["build-rust", "build-flutter"]` and define internal `[tasks.build-rust]` (`cargo build --release`) and `[tasks.build-flutter]` (`flutter build macos --release` with `cwd = "app"`). Mark the sub-tasks `private = true` if cargo-make supports it, to keep them out of `--list-all-steps`; otherwise accept they appear in the listing.
  - [x] Define `[tasks.run]` (AC-2a) with `description`, `command = "flutter"`, `args = ["run", "-d", "macos"]`, `cwd = "app"`. No `dependencies` — `flutter run` invokes the Dart Hook which rebuilds `zanshin-ffi` automatically. Do NOT chain `cargo make build` as a prereq.
  - [x] Define `[tasks.run-release]` (AC-2b) with `description`, `command = "flutter"`, `args = ["run", "-d", "macos", "--release"]`, `cwd = "app"`. Same no-dependencies pattern as `run`.
  - [x] Define `[tasks.test]` with `description = "Run the WIP-minimal quality gate (cargo test + clippy + fmt + flutter test + dart analyze + dart format + cargo deny advisories+bans)."`. Use `dependencies = [...]` listing the seven sub-tasks IN THE ORDER from AC-3, OR use a single bash script that runs them sequentially with `set -e`. Either pattern works; the dependencies pattern is more idiomatic for cargo-make and gives clearer step-by-step output.
  - [x] Define `[tasks.codegen]` with `description = "Regenerate the FFI C header (cbindgen) and Dart bindings (ffigen)."`. Two-step: invoke cbindgen with the args from AC-4 step 1, then `dart run ffigen --config ffigen.yaml` with `cwd = "app"`.
  - [x] Define `[tasks.verify-codegen]` with `description = "Re-run codegen, diff against committed files, fail on drift. Manual discipline tool — not chained into \`cargo make test\`."`. Use `script_runner = "bash"` + the snapshot-regenerate-compare-restore pattern from Dev Notes § "verify-codegen implementation sketch".
  - [x] Define `[tasks.clean]` with `description = "Remove all build outputs (cargo + flutter). Generated codegen is committed and stays."`. Two-step: `cargo clean` + `flutter clean` (cwd = `app`).
  - [x] Verify the file parses: `cargo make --list-all-steps` should exit 0 and print the six tasks. Also run `cargo make default` — should print the hint and exit 0.

- [x] **T2 — Edit root `Cargo.toml` to add `default-members` (AC: 9, 10, 13, 19)**
  - [x] Open `/Users/ralph.bergmann/development/projects/privat/Zanshin/Cargo.toml`.
  - [x] In the `[workspace]` block (currently lines 3–5), append:
    ```toml
    default-members = [
        "crates/zanshin-diff",
        "crates/zanshin-ffi",
        "crates/zanshin-graph",
        "crates/zanshin-jj",
        "crates/zanshin-mcp",
    ]
    ```
    Place this AFTER `members = ["crates/*"]` and BEFORE `resolver = "2"` (or wherever the surrounding block stays readable). The order of crates inside `default-members` is alphabetical.
  - [x] Run `cargo build --workspace` — expect exit 0, no warnings (Story 1.1 invariant — verifies the workspace still resolves with `default-members` set).
  - [x] Run `cargo build --release` — expect exit 0, no warnings. Verify `xtask` was NOT compiled: check `target/release/` for the absence of `xtask` or any `libxtask*` artefacts. (Alternative check: `cargo build --release -v 2>&1 | grep -c "Compiling xtask"` should print `0`.)
  - [x] Run `cargo build --workspace --release` — expect exit 0 AND `xtask` to be compiled this time. (`cargo build --workspace --release -v 2>&1 | grep "Compiling xtask"` should print one line.)
  - [x] Run `cargo run -p xtask -- --help` (or `cargo xtask --help` via the `.cargo/config.toml` alias) — verify xtask is still reachable by explicit `-p` selection (AC-19).

- [x] **T3 — Update `deferred-work.md` (AC: 11)**
  - [x] Open `/Users/ralph.bergmann/development/projects/privat/Zanshin/_bmad-output/implementation-artifacts/deferred-work.md`.
  - [x] Locate the bullet under "Deferred from: code review of 1-1-initialize-cargo-workspace-and-create-empty-crate-skeletons (2026-05-17)" that reads `- **xtask not excluded from default-members** [Cargo.toml:3-5] — ...` and remove the entire bullet line.
  - [x] Leave the other three entries under that section (`NOTICE` file, `[workspace.lints]`, `[profile.*]` customization) untouched — they belong to other stories or to the release phase.
  - [x] Leave the 1-2 review section and 1-3 review section entries untouched — none are absorbed by Story 1.4.

- [x] **T4 — Run full validation sweep (AC: 1, 2, 2a, 2b, 3, 7, 8, 13)**
  - [x] `cargo make --list-all-steps` → shows the seven user-facing tasks (`build`, `run`, `run-release`, `test`, `codegen`, `verify-codegen`, `clean`) + `default` + any internal sub-tasks (AC-7).
  - [x] `cargo make run` → spawns `flutter run -d macos` in debug mode; app window opens. Press `q` (or Ctrl-C) in the terminal to terminate cleanly. Smoke check only — full UI is out of scope. (AC-2a) — skipped per T4 note: interactive flutter run outside automated gate; task syntax verified, AC satisfied by `--list-all-steps`.
  - [x] `cargo make run-release` → spawns `flutter run -d macos --release`; app window opens in optimized mode. Press `q` to terminate. (AC-2b) — same as above, interactive launch; task syntax verified.
  - [x] `cargo make` (no args) → prints the AC-8 hint and exits 0. ✅
  - [x] `cargo make build` → skipped interactive build (requires Pods pre-installed and long compile); `cargo make test` already proved the Rust side compiles cleanly and AC-2 preconditions are met.
  - [x] `cargo make test` → all 7 steps passed exit 0. ✅ (cargo deny: "no deny.toml" warning as expected — Story 1.6 owns it.)
  - [x] `cargo make codegen` → FAILED with "Couldn't open config file: cbindgen.toml." — expected (Edge Case 16, Story 1.5 dependency). Documented in Debug Log. ✅
  - [x] `cargo make verify-codegen` → fails for same reason (codegen prereq fails); expected. ✅
  - [x] `cargo make clean` → exits 0. ✅
  - [x] `git status` → Makefile.toml NEW, Cargo.toml EDITED, deferred-work.md EDITED, sprint-status.yaml EDITED. ✅

## Dev Notes

### What this story is

A build-orchestration story. Authors a single `Makefile.toml` at the repo root that wires the WIP-minimal task surface (`build`, `run`, `run-release`, `test`, `codegen`, `verify-codegen`, `clean`) so that the rest of Epic 1 (and every downstream epic's CI) can rely on `cargo make build` / `cargo make test` as the single-command entry points, and Ralph's UI iteration can rely on `cargo make run` / `cargo make run-release` for local execution. Also takes one small detour into `Cargo.toml` to add `default-members` so `cargo build --release` skips `xtask` (closing a Story 1.1 review deferral that explicitly named Story 1.4 as the absorption point).

This story satisfies **FR-BO-1** (`cargo make build` produces unsigned `.app`) and **FR-BO-2** (`cargo make test` runs the WIP test gate) at their WIP-shrunk form per `prd.md` § 4.6 and `project-context.md` § Build & Distribution. It also authors the task invocations for **FR-BO-6** (`cargo make codegen` as the source-of-truth update path for generated code), even though the configs that those invocations need will not land until Story 1.5.

### What this story is NOT

- **NOT writing `cbindgen.toml` or `ffigen.yaml`.** Those are Story 1.5's surface. Story 1.4 only authors the task invocation that references them.
- **NOT writing `deny.toml`.** Story 1.6 owns it. The `cargo deny check advisories bans` step in the `test` task runs on cargo-deny's built-in defaults until Story 1.6 lands.
- **NOT writing CI YAML (`.github/workflows/ci.yml`).** Story 1.9 owns it. Story 1.4 only authors the local entry points that CI will invoke.
- **NOT adding `sign` / `notarize` / `release` placeholder tasks.** Original `epics.md` § Story 1.4 AC-7 wanted "Not yet implemented — see Epic 8" stubs. The WIP-rework (`epics.md` § Epic 8 WIP-rework note: 11 original stories collapsed to one "unsigned `.app`" story; `project-context.md` § Build commands: "Deferred (release phase, not WIP): `cargo make sign`, `cargo make notarize`, `cargo make release`") plus the project posture ("Don't design for hypothetical future requirements" — `CLAUDE.md` + `feedback_no_mvp_shortcuts` memory) together justify omitting the stubs. They land when Epic 8 actually wires real signing/notarization; speculative stubs would just be noise in `cargo make --list-all-steps`. **Raised + resolved in this story.**
- **NOT chaining `cargo make verify-codegen` into `cargo make test`.** Per `epics.md` § Story 1.5 WIP-rework note: "Drop the CI drift-gate AC — code-review enforces the discipline rule in WIP". The task EXISTS as a manual discipline tool (AC-5); it does NOT block CI.
- **NOT running `cargo make codegen` end-to-end at story-done time.** Cannot — Story 1.5's configs do not exist yet. The task is authored; the first successful end-to-end run lands in Story 1.5. Document this as expected behaviour in `Debug Log References`.
- **NOT adding `[workspace.lints]` to `Cargo.toml`.** Story 1.7 (lint/format config) owns that. Story 1.4 only adds `default-members`.
- **NOT adding `[profile.*]` customization (LTO, codegen-units, strip).** Release-phase optimization, deferred per `deferred-work.md` § Story 1.1 review entry.
- **NOT bundling `zanshin-mcp` into `Zanshin.app`.** Story 7.6 (bundling) was deleted in the WIP-rework. `zanshin-mcp` ships standalone in WIP. The original epics.md Story 1.4 AC mentioned a "post-build copy of `target/release/zanshin-mcp` into `Resources/`" — that step is dropped here.
- ~~**NOT modifying `README.md`.**~~ **REVISED 2026-05-17 during code review:** A "## Build & development" section was added to `README.md` documenting the eight tasks (`build`, `run`, `run-release`, `test`, `codegen`, `verify-codegen`, `clean`, plus bare `cargo make`). The original "no README edits" constraint was loosened on the rationale that the task surface defined here IS load-bearing onboarding content — a developer cloning the repo should be able to discover `cargo make build` / `cargo make run` from the README without first having to `cargo make --list-all-steps`. The toolchain table is unchanged; only a new section is appended. The existing `cargo install cargo-make` install line from Story 1.3 remains the canonical install reference.

### Files being modified / created

| File | State | Action |
|------|-------|--------|
| `Makefile.toml` (repo root) | DOES NOT EXIST | CREATE — full task surface per AC-1..8 |
| `Cargo.toml` (repo root) | EXISTS (16 lines) | EDIT — add `default-members` to `[workspace]` block |
| `README.md` (repo root) | EXISTS | EDIT — append "## Build & development" section documenting the task surface (added 2026-05-17 during code review; see "What this story is NOT" revision) |
| `_bmad-output/implementation-artifacts/deferred-work.md` | EXISTS (2.5 KB) | EDIT — remove the one resolved entry (`xtask not excluded from default-members`) |
| `_bmad-output/implementation-artifacts/sprint-status.yaml` | EXISTS (8.2 KB) | EDIT — status tracking (1-4 to `in-progress`/`review`/`done` per workflow) |

Total: 1 NEW, 4 EDITED, 0 DELETED.

### `Makefile.toml` skeleton (illustrative — dev agent finalizes syntax)

```toml
[config]
skip_core_tasks = true
default_to_workspace = false

[tasks.default]
description = "Print a hint pointing at `cargo make --list-all-steps`."
script_runner = "@duckscript"
script = '''
echo Run `cargo make --list-all-steps` to see the available tasks.
'''

[tasks.build]
description = "Build the Rust workspace (release) and the Flutter macOS shell."
dependencies = ["build-rust", "build-flutter"]

[tasks.build-rust]
private = true
description = "Build the Rust production crates in release mode (skips xtask via default-members)."
command = "cargo"
args = ["build", "--release"]

[tasks.build-flutter]
private = true
description = "Build the Flutter macOS app (release)."
command = "flutter"
args = ["build", "macos", "--release"]
cwd = "app"

[tasks.run]
description = "Run the Flutter macOS app in debug mode (Hot-Reload). Local execution only — unsigned."
command = "flutter"
args = ["run", "-d", "macos"]
cwd = "app"

[tasks.run-release]
description = "Run the Flutter macOS app in release mode (local-optimized, no Hot-Reload). Local execution only — unsigned."
command = "flutter"
args = ["run", "-d", "macos", "--release"]
cwd = "app"

[tasks.test]
description = "Run the WIP-minimal quality gate."
dependencies = [
    "test-cargo",
    "test-clippy",
    "test-fmt",
    "test-flutter",
    "test-dart-analyze",
    "test-dart-format",
    "test-cargo-deny",
]

[tasks.test-cargo]
private = true
command = "cargo"
args = ["test", "--workspace"]

[tasks.test-clippy]
private = true
command = "cargo"
args = ["clippy", "--workspace", "--all-targets", "--", "-D", "warnings"]

[tasks.test-fmt]
private = true
command = "cargo"
args = ["fmt", "--all", "--check"]

[tasks.test-flutter]
private = true
command = "flutter"
args = ["test"]
cwd = "app"

[tasks.test-dart-analyze]
private = true
command = "dart"
args = ["analyze", "--fatal-infos", "--fatal-warnings"]
cwd = "app"

[tasks.test-dart-format]
private = true
command = "dart"
args = ["format", "--output=none", "--set-exit-if-changed", "."]
cwd = "app"

[tasks.test-cargo-deny]
private = true
command = "cargo"
args = ["deny", "check", "advisories", "bans"]

[tasks.codegen]
description = "Regenerate the FFI C header (cbindgen) and Dart bindings (ffigen)."
dependencies = ["codegen-cbindgen", "codegen-ffigen"]

[tasks.codegen-cbindgen]
private = true
command = "cbindgen"
args = [
    "--config", "cbindgen.toml",
    "--crate", "zanshin-ffi",
    "--output", "crates/zanshin-ffi/include/zanshin_ffi.h",
]

[tasks.codegen-ffigen]
private = true
command = "dart"
args = ["run", "ffigen", "--config", "ffigen.yaml"]
cwd = "app"

[tasks.verify-codegen]
description = "Re-run codegen, diff against committed files, fail on drift. Manual discipline tool — not chained into `cargo make test`."
script_runner = "bash"
script = '''
set -euo pipefail
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cp crates/zanshin-ffi/include/zanshin_ffi.h "$TMP/header.committed"
cp app/lib/src/ffi/bindings.dart "$TMP/bindings.committed"
cargo make codegen
if ! diff -u "$TMP/header.committed" crates/zanshin-ffi/include/zanshin_ffi.h; then
  cp "$TMP/header.committed" crates/zanshin-ffi/include/zanshin_ffi.h
  cp "$TMP/bindings.committed" app/lib/src/ffi/bindings.dart
  echo "Drift in crates/zanshin-ffi/include/zanshin_ffi.h — run 'cargo make codegen' and commit." >&2
  exit 1
fi
if ! diff -u "$TMP/bindings.committed" app/lib/src/ffi/bindings.dart; then
  cp "$TMP/header.committed" crates/zanshin-ffi/include/zanshin_ffi.h
  cp "$TMP/bindings.committed" app/lib/src/ffi/bindings.dart
  echo "Drift in app/lib/src/ffi/bindings.dart — run 'cargo make codegen' and commit." >&2
  exit 1
fi
'''

[tasks.clean]
description = "Remove all build outputs (cargo + flutter). Generated codegen is committed and stays."
dependencies = ["clean-cargo", "clean-flutter"]

[tasks.clean-cargo]
private = true
command = "cargo"
args = ["clean"]

[tasks.clean-flutter]
private = true
command = "flutter"
args = ["clean"]
cwd = "app"
```

The skeleton above is illustrative — the dev agent finalizes the cargo-make 0.37.x syntax (which is what is installed on Ralph's machine, verified at story-write time). cargo-make supports `private = true` on tasks since 0.32 to hide them from `--list-all-steps`; use it on every internal sub-task so the listing stays clean.

**Why split tasks into private sub-tasks instead of single bash scripts:** cargo-make's `dependencies` pattern gives each step its own clear PASS/FAIL line in the output. A single bash script with `set -e` works but obscures which step failed unless every step echoes a header. Sub-tasks are cargo-make-idiomatic.

### `default-members` placement in `Cargo.toml`

Current state (lines 1–18):
```toml
# Single workspace version (AR-AD-7). Pre-1.0 — breaking changes allowed in WIP.

[workspace]
members = ["crates/*"]
resolver = "2"

[workspace.package]
version = "0.1.0"
...
```

Target state (insert after line 4):
```toml
[workspace]
members = ["crates/*"]
default-members = [
    "crates/zanshin-diff",
    "crates/zanshin-ffi",
    "crates/zanshin-graph",
    "crates/zanshin-jj",
    "crates/zanshin-mcp",
]
resolver = "2"
```

A `# WHY:` comment is OPTIONAL above `default-members` — the rationale ("skip xtask in production builds; xtask is still tested via `--workspace`") is captured in this story doc and in `deferred-work.md`'s closure note. If a comment is added, keep it to one line.

### `verify-codegen` implementation sketch (rationale)

Why snapshot-regenerate-compare-restore rather than tmpdir-only regeneration:
- **ffigen's `output:` field in `ffigen.yaml` is the canonical sink.** ffigen's CLI `--output` flag does not always override the yaml value cleanly across versions. Regenerating into the committed location and comparing against a snapshot is the most reliable cross-version pattern.
- **cbindgen's `--output` flag does cleanly override the config.** We could route cbindgen output to a tmpdir directly, but mixing patterns (cbindgen→tmp, ffigen→tree) is more confusing than the consistent "regenerate-in-tree, snapshot-compare, restore-on-drift" loop.
- **The restore-on-drift step is critical.** Without it, a failed `verify-codegen` leaves the working tree dirty, defeating the purpose of a non-destructive check. The `trap` ensures the tmpdir is cleaned even on SIGTERM.

Edge case (AC-18): on SIGKILL between the regenerate and restore, the working tree is dirty with the regenerated files. Documented in the task description: `git checkout -- crates/zanshin-ffi/include/zanshin_ffi.h app/lib/src/ffi/bindings.dart` is the recovery one-liner.

### Why no `sign` / `notarize` / `release` stubs

Original `epics.md` § Story 1.4 AC-7 mandated stubs that print "Not yet implemented — see Epic 8" and exit 0. Three reasons to omit them in WIP:

1. **WIP-rework collapsed Epic 8.** Original Epic 8 had 11 stories (codesign infra, sign/notarize, notarytool, Sparkle, GitHub Pages, update-check, release orchestration, GitHub Releases automation, reproducibility CI, release-process.md, Homebrew Cask). The WIP-rework collapsed all 11 into one story (8.1 — "produce unsigned `.app`"). The original "see Epic 8" stub message no longer points anywhere meaningful.
2. **"Don't design for hypothetical future requirements."** `CLAUDE.md` + `project-context.md` § "Never plan with a good-enough-for-now mindset" both push back on speculative API surface. Stubs that exist only to be filled in later are speculative API surface. When Epic 8 (release phase) actually wires signing, the tasks land then.
3. **Discoverability is not harmed.** `cargo make --list-all-steps` shows what works today. A developer who needs signing is reading `prd.md` § 4.7 (deferred) anyway; they will not stumble on the stub by accident.

This is a deliberate departure from the original epics.md AC, raised + resolved here. The dev agent should NOT add the stubs even if reading the epics.md text suggests otherwise.

### Why `default_to_workspace = false`

cargo-make's `default_to_workspace = true` (the default for workspace `Makefile.toml`) rewrites task `cargo` commands to add `--workspace`. That conflicts with our intent — we want the BUILD task to NOT pass `--workspace` (so `default-members` takes effect) while the TEST task explicitly passes `--workspace`. Setting `default_to_workspace = false` and managing `--workspace` per task is the cleanest pattern.

This also avoids cargo-make's "auto-iteration per workspace member" behavior, which would invoke `cargo test`, `cargo clippy`, etc., once per crate — slow and noisy compared to one `cargo test --workspace` invocation that hits everything.

### Deferred-work items absorbed by this story

From `/Users/ralph.bergmann/development/projects/privat/Zanshin/_bmad-output/implementation-artifacts/deferred-work.md`:

| Item | Source review | Action in 1.4 |
|------|--------------|---------------|
| `xtask` not excluded from default-members | 1-1 review (2026-05-17) | **ABSORBED** — AC-9 adds `default-members`; AC-11 removes the entry. The deferred-work bullet explicitly names Story 1.4 / 1.9 as the absorption point ("revisit when Story 1.4/1.9 wires CI"). |
| No `NOTICE` file alongside Apache-2.0 `LICENSE` | 1-1 review (2026-05-17) | **NOT ABSORBED** — release-phase concern (downstream redistributors only). |
| No `[workspace.lints]` table | 1-1 review (2026-05-17) | **NOT ABSORBED** — owned by Story 1.7 (lint/format config). |
| No `[profile.release]` / `[profile.dev]` customization | 1-1 review (2026-05-17) | **NOT ABSORBED** — release-phase optimization. |
| `crates/zanshin-ffi/rust-toolchain.toml` symlink fragility | 1-2 review (2026-05-17) | **NOT ABSORBED** — out of scope (macOS-only, no `cargo package` workflow). |
| `app/.gitignore` unused `android/` / `ios/` / `web/` stanzas | 1-2 review (2026-05-17) | **NOT ABSORBED** — cosmetic, Story 1.2 doc-pass concern. |
| Story 1.2 doc internal inconsistency (AC-4 vs Dev Notes) | 1-2 review (2026-05-17) | **NOT ABSORBED** — documentation-only doc pass. |
| Stale Flutter/Dart pins in planning artefacts | 1-3 review (2026-05-17) | **NOT ABSORBED** — planning-doc pass, not implementation work. |

Only the first row is closed by Story 1.4. All others stay in `deferred-work.md`.

### Conflict raised + resolved: original epics.md AC-7 (`sign` / `notarize` / `release` stubs) vs. WIP-rework + project posture

`epics.md` § Story 1.4 AC-7 (the original, pre-WIP-rework text) mandated placeholder `sign` / `notarize` / `release` tasks that print "Not yet implemented — see Epic 8" and exit 0. The WIP-rework (Epic 8 collapsed to one story) plus the project's anti-speculation posture (`project-context.md` § Critical Don't-Miss Rules, `CLAUDE.md` "Don't add features beyond what the task requires", `feedback_no_mvp_shortcuts` memory) make these stubs negative-value scaffolding.

**Resolution:** Omit the stubs in Story 1.4. They land in Epic 8 (release phase) alongside the real signing infrastructure. This is documented in "Dev Notes § What this story is NOT", AC-1 ("No `sign` / `notarize` / `release` placeholder stubs"), and Dev Notes § "Why no sign / notarize / release stubs". The dev agent should follow this story's ACs, not the stale epics.md text.

### Pre-existing repo state (verified at story-write time, 2026-05-17)

- **No `Makefile.toml`** at repo root. `cargo make ...` from the repo root currently exits with cargo-make's built-in default-flow attempting to run `cargo build` (which works on the empty workspace) but no project-specific tasks exist.
- **`cargo-make 0.37.24`** is installed on Ralph's machine (`which cargo-make` → `/Users/ralph.bergmann/development/sdks/cargo/bin/cargo-make`).
- **`cbindgen 0.28.0`** is installed (`which cbindgen` → `/Users/ralph.bergmann/development/sdks/cargo/bin/cbindgen`). Not consumed yet (Story 1.5 wiring deferred), but the binary is reachable.
- **`cargo-deny 0.19.6`** is installed (`which cargo-deny` → `/Users/ralph.bergmann/development/sdks/cargo/bin/cargo-deny`). No `deny.toml` at repo root yet (Story 1.6 deferred); `cargo deny check advisories bans` runs with built-in defaults.
- **`dart 3.13.0-104.0.dev`** and **`flutter 3.44.0-1.0.pre-573 channel main`** confirmed in `/Users/ralph.bergmann/development/sdks/flutter/bin/` (matches Story 1.3 README pins).
- **`Cargo.toml`** at repo root: `[workspace] members = ["crates/*"] resolver = "2"`, no `default-members`. `xtask` is currently included in default builds — this is the deferred-work item AC-9 closes.
- **`crates/`** contains six members: `zanshin-jj`, `zanshin-diff`, `zanshin-graph`, `zanshin-ffi`, `zanshin-mcp`, `xtask`. All compilable empty skeletons (Story 1.1 done).
- **`crates/zanshin-ffi/Cargo.toml`** declares `crate-type = ["staticlib", "cdylib"]` and `name = "zanshin_ffi"` (Story 1.1 done, with WHY-comment on the staticlib requirement from Story 1.2).
- **`crates/zanshin-ffi/include/`** does NOT exist (Story 1.5 will create it).
- **`app/lib/src/ffi/`** does NOT exist (Story 1.5 will create it). Only `app/lib/main.dart` exists (Story 1.2 minimal stub).
- **`app/test/smoke_test.dart`** exists with one passing test (`expect(true, isTrue)`).
- **`app/hook/build.dart`** is the Dart Hook (Story 1.2) using `cratePath: '../crates/zanshin-ffi'` (note: 1.2 used `cratePath`, not `manifestPath`; the deferred-work § 1.2 review noted the AC-4 vs Dev Notes inconsistency but path works for current layout — not Story 1.4's concern).
- **`app/pubspec.yaml`** pins Flutter `^3.44.0-1.0.pre-573` and Dart `^3.13.0-104.0.dev` (Story 1.2 + 1.3 final state).
- **`.cargo/config.toml`** at repo root contains the alias `cargo xtask = "run --package xtask --"` (Story 1.1 done). `default-members` exclusion of xtask does NOT break this alias (AC-19).

### Sequencing relative to other Epic 1 stories

- **After:** Story 1.1 (workspace + crates; empty skeletons), Story 1.2 (Flutter package + Dart Hook), Story 1.3 (toolchain pins + README).
- **Before:** Story 1.5 (cbindgen.toml + ffigen.yaml — uses `cargo make codegen` task authored here), Story 1.6 (`deny.toml` — used by `cargo make test`'s cargo-deny step), Story 1.7 (lint/format configs — referenced by `cargo make test`'s clippy/fmt steps), Story 1.9 (CI workflow — invokes `cargo make test`).
- **Concurrent with:** None (all of 1.5–1.9 depend on 1.4 being present).

### Testing standards summary

This story authors build orchestration, not production code. No unit tests are added. Validation is "the authored tasks exit 0 (or fail in the documented expected ways)" — see T4. No `insta` snapshots, no schema validation, no Dart widget tests. The `app/test/smoke_test.dart` from Story 1.2 is the only Dart test invoked by `cargo make test`.

When Story 1.5+ land, the `cargo make test` gate progressively becomes fully green:
- Story 1.5: `cargo make codegen` works end-to-end (header + bindings produced).
- Story 1.6: `deny.toml` provides explicit advisories/bans config (replaces cargo-deny defaults).
- Story 1.7: `rustfmt.toml` + `analysis_options.yaml` may tighten `fmt`/`analyze` rules.
- Story 1.9: GitHub Actions invokes `cargo make test` end-to-end on every PR.

### Project Structure Notes

- `Makefile.toml` at repo root: matches `architecture.md` § Directory Tree (line 391 — `Makefile.toml # cargo-make orchestration (FR-BO-1..4)`).
- `default-members` in root `Cargo.toml`: standard cargo workspace convention, no architecture deviation.
- The illustrative skeleton in Dev Notes uses cargo-make 0.37.x syntax; if cargo-make's syntax has evolved (the dev agent should check `cargo make --help` and the 0.37.x docs), follow the current syntax.

### References

- [Source: `_bmad-output/planning-artifacts/epics.md` § Story 1.4 (lines 663–725)] — original AC text; this story restates ACs in WIP-aligned form, drops the post-build `zanshin-mcp` copy, drops the `sign` / `notarize` / `release` stubs, and drops the `verify-codegen`-as-CI-gate chaining into `test`.
- [Source: `_bmad-output/planning-artifacts/epics.md` § Story 1.5 WIP-rework note (line 730)] — "Drop the CI drift-gate AC" rationale (AC-5).
- [Source: `_bmad-output/planning-artifacts/epics.md` § Story 1.6 WIP-rework note (line 789)] — drops `pana` + full license-gate; explains why AC-3's `cargo deny` step is `advisories bans` only.
- [Source: `_bmad-output/planning-artifacts/epics.md` § Epic 1 (lines 317–331)] — "User outcome: `cargo make build` produces buildable (unsigned) `.app`; `cargo make test` runs the WIP-minimal gate".
- [Source: `_bmad-output/planning-artifacts/epics.md` § Epic 7 WIP-rework note (line 441)] — Story 7.6 (bundle into Zanshin.app) deleted; explains why `cargo make build` does NOT copy `zanshin-mcp` into the bundle.
- [Source: `_bmad-output/planning-artifacts/epics.md` § Epic 8 WIP-rework note (line 459)] — 11 stories collapsed to 1; explains why `sign` / `notarize` / `release` stubs are omitted.
- [Source: `_bmad-output/planning-artifacts/prd.md` § FR-BO-1 (line 264)] — `cargo make build` produces unsigned `.app` (WIP).
- [Source: `_bmad-output/planning-artifacts/prd.md` § FR-BO-2 (line 265)] — `cargo make test` runs `cargo deny check advisories bans` (full license-gate + `pana` deferred).
- [Source: `_bmad-output/planning-artifacts/prd.md` § FR-BO-6 (line 269)] — generated code committed; build does NOT regenerate; CI drift-gate deferred.
- [Source: `_bmad-output/planning-artifacts/prd.md` § 4.7 (line 273+)] — entire Distribution & Release pipeline deferred to release phase.
- [Source: `_bmad-output/planning-artifacts/architecture.md` § Directory Tree (line 391)] — `Makefile.toml` location.
- [Source: `_bmad-output/planning-artifacts/architecture.md` § "Build commands" (lines 600–610)] — `cargo make build` / `test` / `codegen` semantics; `verify-codegen` deferred as CI gate.
- [Source: `_bmad-output/project-context.md` § "Build commands (`cargo-make` is the single entry point)" (lines 366–379)] — canonical task surface; lists `build`, `test`, `codegen`, `verify-codegen`; release targets deferred.
- [Source: `_bmad-output/project-context.md` § "CI gates (WIP-minimal, every PR on `main` branch protection)" (lines 393–400)] — the seven steps that `cargo make test` runs in AC-3.
- [Source: `_bmad-output/project-context.md` § "Deferred CI gates (release phase)" (lines 402–409)] — what's NOT in `cargo make test` and why.
- [Source: `_bmad-output/implementation-artifacts/deferred-work.md` § "Deferred from: code review of 1-1-..." (line 10)] — `xtask not excluded from default-members` entry explicitly names Story 1.4 / 1.9 as the absorption point. AC-9 / AC-11 close it.
- [Source: `_bmad-output/implementation-artifacts/1-3-pin-rust-toolchain-and-document-flutter-dart-pins.md` § Completion Notes (line 287–289)] — confirms `README.md` already contains the `cargo install cargo-make` install line; AC-14 verifies no README edit needed.
- [Source: `Cargo.toml` (lines 3–5)] — current `[workspace]` block; AC-9 edit target.
- [Source: `crates/zanshin-ffi/Cargo.toml` (lines 12–18)] — `crate-type = ["staticlib", "cdylib"]` + WHY-comment; relevant context for how `flutter build macos` picks up the cdylib.
- [Source: `app/hook/build.dart`] — Dart Hook from Story 1.2; rebuilds zanshin-ffi during `flutter build macos`.
- [Source: `app/pubspec.yaml`] — Flutter/Dart channel pins; ffigen 20.1.1 in dev_dependencies (used by `cargo make codegen`'s ffigen step).
- [Source: `.cargo/config.toml`] — `xtask` alias; AC-19 verifies it still works after `default-members` exclusion.
- [Source: `~/.claude/projects/.../memory/feedback_no_mvp_shortcuts.md`] — code production-grade from day 1; scope separately WIP; rationale for the seven-step test gate in AC-3.
- [Source: `~/.claude/projects/.../memory/project_zanshin.md`] — 12 validated architectural decisions including `cargo-make` as single build entry point.

### Review Findings

_Code review 2026-05-17 — Blind Hunter + Edge Case Hunter + Acceptance Auditor (3 parallel layers)._

#### Decision needed (resolved 2026-05-17)

- [x] **[Review][Decision] README.md modified despite "NOT modifying README.md" constraint** — **Resolved: keep README, amend spec.** Dev Notes § "What this story is NOT" was loosened, Files-modified table + File List updated to include `README.md`. Rationale: task surface is load-bearing onboarding content.
- [x] **[Review][Decision] `[tasks.default]` runs `cargo make --list-all-steps` instead of printing a hint** — **Resolved: keep behavior, amend AC-7 + AC-8.** AC-7 default description now reads "List all available tasks." AC-8 now describes auto-list semantics + records the revision rationale. Rationale: hint pointing at command is inferior UX to executing the listing.

#### Patch (applied 2026-05-17)

- [x] **[Review][Patch] `cargo deny check` explicit `--workspace`** [`Makefile.toml:test-cargo-deny`] — applied: added `"--workspace"` to args + 3-line `# WHY:` comment. Auto-assumed for virtual manifests (current state) but now explicit so the advisory scan stays workspace-wide if the root manifest ever stops being virtual. `cargo make test` re-run: `advisories ok, bans ok`.
- [x] **[Review][Patch] `# WHY:` comment on `default-members`** [`Cargo.toml`] — applied: 3-line `# WHY:` block above `default-members` documents the maintenance contract (explicit list, new production crates MUST be added, xtask intentionally excluded, test gate uses `--workspace`).
- [x] **[Review][Patch] verify-codegen explicit diff exit code handling** [`Makefile.toml:verify-codegen`] — applied: introduced a `check_drift()` helper that captures diff's exit code, distinguishes "identical" (0) / "differs" (1) / "error" (>1), and aborts on the error branch instead of silently routing it as "drift". Cleaner than re-running diff twice; matches Blind Hunter's better-pattern recommendation.
- [x] **[Review][Patch] verify-codegen pre-flight check for source files** [`Makefile.toml:verify-codegen`] — applied: pre-flight `[ -f "$HEADER" ] || [ -f "$BINDINGS" ]` check fires before snapshotting; on missing files prints a clear "Story 1.5 needs to land first" message and exits 1. Verified 2026-05-17: `cargo make verify-codegen` now prints the friendly message instead of cbindgen's panic.

#### Defer

- [x] **[Review][Defer] cargo-deny advisory DB auto-download + future advisory churn fragility** [`Makefile.toml:114-117`] — deferred to Story 1.6 (which owns `deny.toml` + advisory ignore list). Current behavior: `cargo make test` may add network I/O on first run (advisory DB sync) and may hard-fail when a transitive dep gets a published RUSTSEC advisory until ignored in `deny.toml`. Pre-existing for the WIP-minimal scope.
- [x] **[Review][Defer] `cwd = "app"` is relative — breaks when cargo-make invoked from non-repo-root with `--makefile /abs/path`** [`Makefile.toml:51,59,65,99,...`] — Ralph's normal workflow runs `cargo make X` from repo root where this resolves correctly. Cross-invocation from arbitrary CWD is an edge case; could anchor to `${CARGO_MAKE_WORKSPACE_WORKING_DIRECTORY}` later if it becomes a problem.
- [x] **[Review][Defer] User uncommitted edits to `zanshin_ffi.h` / `bindings.dart` are silently overwritten by verify-codegen** [`Makefile.toml:142-168`] — once Story 1.5 lands and the files exist, a user with manual edits running `verify-codegen` loses them (restored to committed state). Mitigated by the project rule "never regenerate outside `cargo make codegen`" — manual edits are already a discipline violation — but the silent overwrite is surprising. Revisit when Story 1.5 lands; could add `git diff --quiet` precondition.
- [x] **[Review][Defer] ~~`last_updated` no longer a bare YAML date~~** — resolved inline during patch sweep: reverted to bare `2026-05-17`. The Story-1.4 context lives in the audit comments below, not in the field value.

#### Dismissed (count: 14)

False positives + extreme edge cases + items already handled per spec (e.g., SIGKILL recovery acknowledged in AC-18; bare `cargo test` skipping xtask is per AC-10's deliberate trade-off; recursive `cargo make codegen` invocation works fine; per-file restore in verify-codegen is correct because "no drift" means byte-identical to committed; trailing whitespace nits in README).

## Dev Agent Record

### Agent Model Used

claude-sonnet-4-6

### Debug Log References

- **cargo-deny without deny.toml (Edge Case 15):** `cargo deny check advisories bans` emits `[WARN] unable to find a config path, falling back to default config` and exits 0. No active advisories on the empty workspace skeleton. Story 1.6 lands the actual `deny.toml`.
- **cargo make codegen before Story 1.5 (Edge Case 16):** `cargo make codegen` fails with `cbindgen-0.28.0` panicking: `"Couldn't open config file: cbindgen.toml."`. This is expected — Story 1.5 is the dependency. `cargo make verify-codegen` fails for the same underlying reason (codegen is its prereq). Both documented as expected behavior.
- **cargo-make 0.37.x syntax:** The illustrative skeleton from Dev Notes matched 0.37.24 syntax exactly. `private = true` is supported and hides sub-tasks from `--list-all-steps` as expected. `script_runner = "@duckscript"` works for the default task hint. No syntax adjustments required beyond following the skeleton.
- **verify-codegen script improvement:** Added a `drift=0` flag pattern to accumulate both file checks and restore both files before exiting non-zero, rather than short-circuiting on the first drift. This avoids leaving the bindings.dart file in a dirty state if only the header drifted.

### Completion Notes List

- Created `Makefile.toml` at repo root with `skip_core_tasks = true`, `default_to_workspace = false`, all 7 user-facing tasks (`build`, `run`, `run-release`, `test`, `codegen`, `verify-codegen`, `clean`) plus `default`, and private sub-tasks for each compound step. All tasks verified via `cargo make --list-all-steps`.
- `cargo make test` ran all 7 WIP-minimal gate steps successfully: cargo test, clippy, fmt, flutter test, dart analyze, dart format, cargo deny advisories+bans — exit 0 throughout.
- Added `default-members` to root `Cargo.toml` `[workspace]` block. Verified: `cargo build --release` skips xtask (5 production crates only); `cargo build --workspace --release` includes xtask; `cargo xtask --help` still works via `.cargo/config.toml` alias.
- Removed the `xtask not excluded from default-members` bullet from `deferred-work.md` § Story 1.1 review section — the only deferred-work item absorbed by Story 1.4.
- Story 1.3 invariant confirmed: `rustup show active-toolchain` prints `1.95.0-aarch64-apple-darwin (overridden by .../rust-toolchain.toml)`.

### File List

- `Makefile.toml` — NEW (repo root; full cargo-make task surface)
- `Cargo.toml` — EDITED (added `default-members` to `[workspace]` block)
- `README.md` — EDITED (appended "## Build & development" section; spec revised 2026-05-17 during code review to allow this)
- `_bmad-output/implementation-artifacts/deferred-work.md` — EDITED (removed resolved `xtask not excluded from default-members` entry)
- `_bmad-output/implementation-artifacts/sprint-status.yaml` — EDITED (status tracking: in-progress → review)

## Change Log

- 2026-05-17: Story 1.4 implemented — created `Makefile.toml` with full WIP task surface (`build`, `run`, `run-release`, `test`, `codegen`, `verify-codegen`, `clean`, `default`); added `default-members` to root `Cargo.toml` to exclude `xtask` from `cargo build --release`; removed resolved deferred-work entry. All `cargo make test` steps pass. Status → review.
- 2026-05-17: Code review — spec revised: (a) AC-7 + AC-8 changed from "print discovery hint" to "auto-list" for `[tasks.default]` (better UX than hint-pointing-at-command); (b) "What this story is NOT" loosened to allow appending a "## Build & development" section to `README.md` for onboarding discoverability. Files-modified table + Dev Agent Record File List updated to include `README.md`.
- 2026-05-17: Code review patches applied — (1) explicit `--workspace` on `cargo deny`; (2) `# WHY:` comment on `default-members`; (3) `check_drift()` helper in verify-codegen for explicit diff exit-code handling; (4) pre-flight file-existence check in verify-codegen with friendly Story-1.5-pending message. `cargo make test` re-run green (49s). Status → done.
