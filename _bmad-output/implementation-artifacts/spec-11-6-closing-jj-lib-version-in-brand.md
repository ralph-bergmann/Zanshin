---
title: 'Story 11.6 closing run — the Projects sidebar shows jj-lib''s version'
type: 'feature'
created: '2026-10-18'
status: 'done'
baseline_revision: '117c201c317d7235449ef59b7d316fd12ca99cdc'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-11-context.md'
warnings: ['oversized']
deferred:
  - summary: >-
      The jj-lib pin-bump steps do not name `zanshin_jj::JJ_LIB_VERSION`, the third place a bump must change.
    evidence: |-
      project-context.md:190-192 (§ zanshin-jj "Pin bump (jj-lib)", step 1) names only `jj-lib` and `jj-cli`, and the root Cargo.toml:40 `jj-lib` comment does not mention the constant; the guard `jj_lib_version_is_the_locked_jj_lib` (crates/zanshin-jj/src/version.rs) fails at step 3 with both values, so a bump meets it as a test failure. The fix edits project-context.md, an agent-context file.
    location: >-
      _bmad-output/project-context.md:190-192; Cargo.toml:40
    severity: low
---

<intent-contract>

## Intent

**Problem:** Ledger item 1 handed to this closing run (Story 11.6's `deferred:`), verified against the current code: epics.md:12411 asks for "the app's version with jj-lib's" in the Projects sidebar's brand (Claude's proposal), but nothing carries jj-lib's version — jj-lib exposes none, the only FFI version is zanshin-ffi's own (`zanshin_ffi_version`, `crates/zanshin-ffi/src/lib.rs:69-72`), the `Diagnostics` payload has `app_version`/`git_sha`/`log_path` only, and the pin lives only in the root `Cargo.toml` (`jj-lib = { version = "=0.46.0" … }`) — so `_Brand` shows just "‹version› · Build ‹build›".

**Approach:** As the ledger's follow-up proposes: `zanshin-jj` (the one crate that knows jj-lib) exposes `JJ_LIB_VERSION`, guarded against the lockfile; `zanshin_diagnostics` carries it as a new `Diagnostics.jj_lib_version` field; the Dart `Diagnostics` reads it; `ProjectsEnvironment` gains `jjLibVersion()` (the desktop adapter reads the DI-provided `GetDiagnostics`); the brand shows a second version line "jj-lib ‹version›" under the app's (Claude's proposal).

## Boundaries & Constraints

**Always:**
- `zanshin_jj::JJ_LIB_VERSION: &str` equals the jj-lib version in the committed `Cargo.lock` (the exact pin); a test fails, naming both values, when a pin bump leaves it behind. Its doc says jj-lib exposes no version, so this repeats the pin.
- Schema change edits `schemas/envelope.fbs` in place (append `jj_lib_version: string;` to `table Diagnostics`), then `cargo make codegen` regenerates the flatc Rust/Dart accessors, `zanshin_ffi.h` and `bindings.dart`; all are committed with the change. No new `extern "C"` symbol.
- The Dart `Diagnostics.jjLibVersion` follows its siblings (`String`, absent → `''`); `zanshin_core.dart` exports `Diagnostics` (the app's adapter test builds one).
- The desktop adapter reads `GetDiagnostics` injected through `ProjectsModule` (no direct FFI module construction in the app); a `ZanshinFfiException` answers null and logs a WARNING carrying the code (FINE for the rest), as the identity read does.
- The brand's lines: "Zanshin", then the app's line, then "jj-lib ‹version›" — same mono `--fs-xs` `--text-dim` style, one line each with ellipsis, 1 apart; a null read leaves its line out. Marked "Claude's proposal" in the class doc; the window's class doc drops "jj-lib's version is not exposed, deferred".
- Rust: clippy pedantic `-D warnings`, rustfmt, SPDX first line, docs on every pub item. Dart: SPDX first line, page width 120, `dart analyze --fatal-infos --fatal-warnings`, `dart format`. Coverage never drops.

**Never:**
- No build.rs lockfile parsing, no new crate dependency, no `pub use jj_lib::…`, no change to `zanshin_ffi_version`'s output.
- No other change to Story 11.6's code (sidebar layout, nav, footer, header, tree); no golden tests; no edits under `design/` or `design_system/`; no change to existing deferred-work.md bullets, `epic-11-context.md`, `epics.md`, `sprint-status.yaml`, `project-context.md` or the Story 11.6 spec; never lower `coverage-baseline.txt`.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| FFI | `zanshin_diagnostics()` | ok envelope; `Diagnostics.jj_lib_version == zanshin_jj::JJ_LIB_VERSION`, the other three fields unchanged | panic backstop unchanged |
| Pin drift | `JJ_LIB_VERSION` ≠ `Cargo.lock`'s `jj-lib` version (or not exactly one `jj-lib` entry) | the zanshin-jj guard test fails with both values | — |
| Both versions | env answers `2026.9.1 · Build 1` and `0.46.0` | brand: "Zanshin", "2026.9.1 · Build 1", "jj-lib 0.46.0", top to bottom | — |
| jj-lib unreadable | `jjLibVersion()` null | no "jj-lib" line; the app's line stays | adapter: `ZanshinFfiException` → null, WARNING with the code |
| App version unreadable | `appVersion()` null, `jjLibVersion()` `0.46.0` | "jj-lib 0.46.0" directly under "Zanshin" | — |

</intent-contract>

## Code Map

- `crates/zanshin-jj/src/lib.rs` -- module list :30-56 (`pub(crate) mod …`), re-exports :58-87 (consts re-exported from noun modules, e.g. `revset::DEFAULT_LOG_REVSET` :34 of revset.rs); `#![deny(missing_docs)]`; lib.rs holds no logic → put the const in a new noun module (`version.rs`) and re-export it.
- `crates/zanshin-jj/tests/api_stability.rs` -- names every public item; consts are pinned around :473-482 (`DEFAULT_GRAPH_PRIORITIZE`, `DEFAULT_LOG_REVSET`) — add `JJ_LIB_VERSION` there (typed `&'static str`, no second hard-coded value).
- `Cargo.lock` -- the `jj-lib` entry: `name = "jj-lib"` then `version = "0.46.0"` (:2352-2353); exactly one entry. Gate plan: `Cargo.lock` → `Need::Everything` (`crates/xtask/src/tasks/gate_plan.rs:168`), so a test reading it needs no new rule. From `crates/zanshin-jj/src/version.rs`, `include_str!("../../../Cargo.lock")`.
- `schemas/envelope.fbs:589-595` -- `table Diagnostics { app_version; git_sha; log_path; }` and its comment ("All three fields…"); regenerate with `cargo make codegen` (Makefile.toml:497-555: flatc Rust → `crates/zanshin-ffi/src/`, flatc Dart → `packages/zanshin_core/lib/src/ffi/`, cbindgen, ffigen; flatc 25.12.19 installed).
- `crates/zanshin-ffi/src/envelope.rs` -- `ok_diagnostics(app_version, git_sha, log_path)` :670-700 (add the fourth string); test `ok_diagnostics_produces_diagnostics_envelope` :922-933.
- `crates/zanshin-ffi/src/diagnostics.rs` -- `zanshin_diagnostics` :13-38 (doc lists the fields and says "two compile-time constants + one path resolution"; passes `env!(…)` values); test :51-89 (pattern for the new assert against `zanshin_jj::JJ_LIB_VERSION`). zanshin-ffi already depends on zanshin-jj (`crates/zanshin-ffi/Cargo.toml:31`).
- `docs/ffi-abi.md:34-36` -- "two compile-time constants plus one path resolution" for `zanshin_diagnostics` → three.
- `packages/zanshin_core/lib/src/ffi/diagnostics.dart` -- `Diagnostics` :15-30, `decodeDiagnosticsEnvelope` :65-82 (`payload.x ?? ''`); `packages/zanshin_core/lib/zanshin_core.dart:29` (show list); test `packages/zanshin_core/test/ffi/diagnostics_test.dart` (real cdylib; siblings assert non-empty — assert a dotted `x.y.z` version).
- `app/lib/src/features/projects/projects_environment.dart` -- port `ProjectsEnvironment` (`appVersion()` doc "The sidebar's version line…"); `DesktopProjectsEnvironment(this._worker)` with `appVersion()` (PackageInfo, `on Exception` → null + warning). Add `Future<String?> jjLibVersion()` (the bare version, e.g. "0.46.0") and a required named `diagnostics: GetDiagnostics`.
- `app/lib/src/features/projects/projects_module.dart:42-45` -- `projectsEnvironment()` provider → take `GetDiagnostics` (the component has `ZanshinDiagnosticsModule`, `app/lib/main.dart:128`); regenerate `app/lib/main.inject.dart` with `dart run build_runner build --delete-conflicting-outputs` in `app/`.
- `app/lib/src/features/projects/projects_window.dart` -- class doc :32-33 (version line sentence), state `_version` :156, `_readVersion` :223-228 (called from initState :167), `_Brand(version: _version)` :643, `_Brand` :953-990 (Column spacing 1, version `Text` style `ZsType.id.copyWith(fontSize: ZsType.fsXs, color: colors.textDim)`); the identity read :229-243 shows the WARNING-with-code pattern.
- `app/test/helpers/fake_projects_environment.dart` (`version` field pattern), `app/widgetbook/demo_projects_fakes.dart:150-174` (`DemoProjectsEnvironment.appVersion` → add `jjLibVersion` "0.46.0").
- Tests: `app/test/features/projects/projects_window_test.dart` layout test :189-233 (asserts `'2026.9.1 · Build 1'`), DI witness :1072-1089 (does not pump; must still build); `app/test/features/projects/projects_environment_test.dart` (constructs `DesktopProjectsEnvironment(Future<ZanshinWorker>.value(worker))` twice — pass `diagnostics:`).
- Catalogue: Projects › Projects window › Tree (`projects/projects-window/tree`), DS card `ui_kits/desktop/dialogs.jsx:36` (brand `jj client · v0.24.0`, stale per epics.md:12411), `kit.css:192-194`.

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/src/version.rs` (new) + `crates/zanshin-jj/src/lib.rs` -- `pub const JJ_LIB_VERSION: &str = "0.46.0"` with doc; inline test reading `Cargo.lock` asserting exactly one `jj-lib` package whose version equals the const (message names both); `pub(crate) mod version;` + `pub use version::JJ_LIB_VERSION;`.
- `crates/zanshin-jj/tests/api_stability.rs` -- name `zanshin_jj::JJ_LIB_VERSION` beside the other consts.
- `schemas/envelope.fbs` -- append `jj_lib_version: string;` (doc: jj-lib's version, `zanshin_jj::JJ_LIB_VERSION`); "four fields" comment; then `cargo make codegen` and keep only the Diagnostics-related regenerated diff (inspect the rest; unrelated drift is reverted, not committed).
- `crates/zanshin-ffi/src/envelope.rs`, `crates/zanshin-ffi/src/diagnostics.rs`, `docs/ffi-abi.md` -- the fourth field through `ok_diagnostics` and `zanshin_diagnostics` (docs updated: four fields, three compile-time constants), both tests assert it.
- `packages/zanshin_core/lib/src/ffi/diagnostics.dart`, `packages/zanshin_core/lib/zanshin_core.dart`, `packages/zanshin_core/test/ffi/diagnostics_test.dart` -- `jjLibVersion` field + decode; export `Diagnostics`; real-cdylib test (`x.y.z`).
- `app/lib/src/features/projects/projects_environment.dart`, `projects_module.dart` (+ regenerated `app/lib/main.inject.dart`) -- port `jjLibVersion()`; adapter over `GetDiagnostics` (failure → null, WARNING with code); provider passes the injected `GetDiagnostics`.
- `app/lib/src/features/projects/projects_window.dart` -- read `jjLibVersion()` with the app version; `_Brand` gets the third line; docs (window class doc, `_Brand` doc, Claude's proposal).
- `app/test/helpers/fake_projects_environment.dart`, `app/widgetbook/demo_projects_fakes.dart` -- answer `jjLibVersion()` (fake: a settable field defaulting to "0.46.0"; demo: "0.46.0").
- `app/test/features/projects/projects_window_test.dart`, `app/test/features/projects/projects_environment_test.dart` -- the matrix's brand rows (order top to bottom, absent lines) and the adapter's read and failure (fake `GetDiagnostics`, a throwing one); existing tests updated only for the new constructor argument.

**Acceptance Criteria:**
- Given the Projects window content in the app, when it renders, then the sidebar brand shows "Zanshin", the app's version line and "jj-lib 0.46.0" below it, each on one line within the 200 px sidebar.
- Given a jj-lib pin bump that leaves `JJ_LIB_VERSION` unchanged, when `cargo make test` runs, then it fails in the zanshin-jj guard test.
- Given the change, when `cargo make test` runs unpiped from the repo root, then it exits 0 and `coverage-baseline.txt` is not lowered (an auto-raise is committed with the code).
- Given the running catalogue, when `projects/projects-window/tree` is opened in night and paper, then the brand shows the three lines without clipping (Claude's visual check, compared with the DS Projects window card).

## Spec Change Log

## Review Triage Log

### 2026-10-18 — Review pass
- verdicts: 21 findings — high 0, medium 0, low 12, false 9, maybe-false 0
- findings:
  - `[low]` `[reject]` (blind 1) An absent `jj_lib_version` decodes to `''`, which the adapter passes on, so the brand would draw a bare "jj-lib " line — real only with a cdylib built from another schema than the Dart side; the hook builds the cdylib from the same tree for every build, so nobody meets it, and the fixes are a guard branch in the adapter or breaking the spec's "follows its siblings" rule for the decode.
  - `[low]` `[reject]` (blind 2) `_readVersions` awaits both reads with `.wait`, so a non-FFI throw from one drops both lines as an unhandled `ParallelWaitError` — the adapters catch their documented failures (`appVersion` every `Exception`, `jjLibVersion` `ZanshinFfiException`); a remaining throw needs an unresolvable native symbol, which leaves the app without its worker too (the class Story 11.6's review rejected, its blind 21); independent reads add a second read path for it.
  - `[low]` `[patch]` (blind 3) The brand test's `jjLib.height == app.height` cannot fail (`maxLines: 1` forces one-line height) and app tests load no fonts, so nothing automated shows the lines fit — patched: the vacuous assertion is gone and the test is renamed ("top to bottom"); the fit stays the visual check's (night and paper, nothing ellipsized).
  - `[false]` `[reject]` (blind 4) The third line grows the brand and re-centres the chip, unrecorded — the Row centres as the DS's `.zk-brand{align-items:center}` (kit.css:192) does; the extra height is the line the spec prescribes; the 680 × 440 window test (which fails on any overflow) passes and the visual check saw the chip centred and nothing clipped.
  - `[low]` `[patch]` (blind 5) The Dart decode is pinned only by an `x.y.z` regex that the app's own `0.1.0` also matches — patched with verification-gap 1 (same root cause).
  - `[low]` `[patch]` (blind 6) `docs/ffi-abi.md:513` still lists only Story 3.8 for `zanshin_diagnostics`, while rows with a later payload change carry "(+story)" (e.g. `3.4a (+9.37)`, `6.5 (+9.39)`) — patched: `3.8 (+11.6)`.
  - `[low]` `[defer]` (blind 7) The pin-bump steps do not name `JJ_LIB_VERSION` (project-context.md:190-192, root Cargo.toml:40), so a bump meets it as the guard's failure — the fix edits project-context.md, an agent-context file; deferred (frontmatter `deferred:`, mirrored in deferred-work.md).
  - `[false]` `[reject]` (blind 8) `version.rs`'s doc gives the wrong reason ("the exact pin makes it the compiled version") — with `=0.46.0` the resolver can pick nothing else, so the sentence holds; the guard compares against `Cargo.lock`, which also covers a loosened pin.
  - `[false]` `[reject]` (blind 9) No test covers both versions missing — no matrix row asks for it and nothing breaks there: the two `if (… != null)` lines are independent and each is tested alone.
  - `[low]` `[reject]` (blind 10) The now-exported `Diagnostics` has no `toString` / `==` — no caller compares or prints one (the app's tests compare strings); equality and `toString` are new surface for no use.
  - `[low]` `[reject]` (edge 1) A non-FFI throw from `jjLibVersion()` escapes `.wait` and drops the app's line — same as blind 2, rejected there.
  - `[low]` `[reject]` (edge 2) A stale cdylib without the field shows "jj-lib " — same as blind 1, rejected there.
  - `[low]` `[patch]` (verification-gap 1) A copy-paste regression in `decodeDiagnosticsEnvelope` (e.g. `jjLibVersion: payload.appVersion`) passes every test — patched: the decode contract group gains "reads each field from its own slot" (a synthetic `DiagnosticsObjectBuilder` with four distinct values); the deliberate break `payload.appVersion` fails it while the regex test still passes (+6 −1), restored.
  - `[false]` `[reject]` (intent a) The intent places jj-lib's version in the version line; the diff adds a line of its own — the follow-up says "the brand block appends it", epics.md:12411 asks for the app's version "with jj-lib's", and one line would ellipsize in the 131 px column (Design Notes); both lines are whole in the visual check.
  - `[false]` `[reject]` (intent b) The constant is a hand-repeated literal, not derived from the compiled crate — the intent asks for "a build-time constant", which a `const` is; jj-lib exposes no version to derive, and the guard against `Cargo.lock` failed on a deliberate drift ("JJ_LIB_VERSION is 0.45.0, Cargo.lock's jj-lib is 0.46.0"); the checklist half is blind 7.
  - `[false]` `[reject]` (intent c) No test joins the real FFI read to the rendered brand, and the catalogue shows the demo literal — each link is witnessed (real-cdylib decode, the adapter over `GetDiagnostics`, the window over a fake environment) and the regenerated `main.inject.dart` passes `_getDiagnostics$Provider.get()` to the provider; no app surface hosts Projects before 11.12 (Story 11.6's recorded residual risk), so the real chain is seen first there.
  - `[low]` `[reject]` (intent d1) `_readVersions` couples the app's line to the jj-lib read — same as blind 2, rejected there.
  - `[low]` `[reject]` (intent d2) An absent field yields `''`, not null — same as blind 1, rejected there.
  - `[false]` `[reject]` (intent d3) `Diagnostics` joins zanshin_core's public barrel — the spec's Always requires it (the adapter test builds one), the show-list pattern every bridge story extends.
  - `[false]` `[reject]` (intent e) No Auto Run Result, no commit, untracked spec — a mid-run state; finalize writes the result and commits the spec with the code.
  - `[false]` `[reject]` (intent f) A "bridge story" done inside a closing run — the intent allows fixing an item here; the auditor itself finds no divergence under that reading.

## Design Notes

**Why a const and not a build script.** jj-lib publishes no version constant (no `CARGO_PKG_VERSION` use in jj-lib-0.46.0 or jj-core-0.46.0), and cargo gives build scripts no dependency versions. A build.rs parsing `Cargo.lock` would need a fallback for a missing lockfile and still a test to prove itself; the exact pin means the pinned version is the compiled one, so a const guarded by a lockfile test is the smaller, checked duplicate. A pin bump fails the guard until the const follows.

**Why a second line.** The brand's text column is 200 − 14 − 14 − 32 − 9 = 131 px; JetBrains Mono at 10.5 px advances ~6.3 px, so about 20 characters fit. "2026.9.1 · Build 1" (18) fits; appending " · jj-lib 0.46.0" (34 in all) would ellipsize. "jj-lib" rather than "jj": it is the library Zanshin is built on; the user's installed jj CLI may be another version.

## Verification

**Commands:**
- `cargo make codegen` (repo root) -- expected: only Diagnostics-related diffs in the generated files plus the edited doc comments in `zanshin_ffi.h` / `bindings.dart`.
- `dart run build_runner build --delete-conflicting-outputs` in `app/` -- expected: `main.inject.dart` passes `GetDiagnostics` to the projects environment provider.
- `cargo make test` (repo root, unpiped; PATH with `~/development/sdks/flutter/bin` and `~/development/sdks/cargo/bin`, `CARGO_HOME=~/development/sdks/cargo`, `RUSTUP_HOME` unset) -- expected: exit 0; coverage held or raised.

**Manual checks (if no CLI):**
- Claude's check (project-context.md "UI tooling"): run the catalogue (`flutter run -d macos -t widgetbook/main.dart` in `app/`), connect Marionette, open `projects/projects-window/tree` in night and paper, screenshot the sidebar brand; compare with the DS Projects window card. Record what was and was not seen in the Auto Run Result.

## Auto Run Result

Status: done (2026-10-18). Blocking condition: none. Code commit: 23ddab31a6a2257e7732e1d4864c83a419ae06a5.

**Items handed to this closing run.**
1. **The Projects sidebar's version line shows only the app's version — fixed** (commit `23ddab31a6a2257e7732e1d4864c83a419ae06a5`).
   - Verified first: jj-lib publishes no version constant (no `CARGO_PKG_VERSION` in jj-lib-0.46.0 or jj-core-0.46.0); the only FFI version was zanshin-ffi's own (`zanshin_ffi_version`, `crates/zanshin-ffi/src/lib.rs:69-72`); `Diagnostics` carried `app_version` / `git_sha` / `log_path`; `_Brand` drew "Zanshin" and "‹version› · Build ‹build›" only.
   - As the ledger's follow-up proposes: a build-time constant (`zanshin_jj::JJ_LIB_VERSION`, guarded against `Cargo.lock`) crosses through `Diagnostics` (new `jj_lib_version` field), and the brand block appends it as its own line "jj-lib ‹version›" (Claude's proposal: one line would ellipsize in the 131 px column). Story 11.6's code changed only in the brand, its version read and the environment port/adapter.

**Summary.** The Projects window's sidebar brand now reads "Zanshin", "2026.9.1 · Build 1" and "jj-lib 0.46.0" (same mono `--fs-xs` `--text-dim` style, 1 apart, one line each; a null read leaves its line out). The brand is one line taller, so the navigation sits about 15 px lower; the chip stays centred on the block as the DS's `.zk-brand{align-items:center}` says. `GetDiagnostics` now has a consumer through DI (`ProjectsModule`), which settles the `GetDiagnostics` half of the closing run of Story 11.3's ledger line "Two DI bindings … consumed by nothing" (left for the dispatcher's ledger commit).

**Files changed:**
- `crates/zanshin-jj/src/version.rs` (new), `crates/zanshin-jj/src/lib.rs` — `JJ_LIB_VERSION` and its `Cargo.lock` guard (plus a test of the guard's lockfile reader); re-export.
- `crates/zanshin-jj/tests/api_stability.rs` — names the const.
- `schemas/envelope.fbs` (+ regenerated `crates/zanshin-ffi/src/envelope_generated.rs`, `packages/zanshin_core/lib/src/ffi/envelope_zanshin.ffi_generated.dart`, `crates/zanshin-ffi/include/zanshin_ffi.h`, `packages/zanshin_core/lib/src/ffi/bindings.dart`) — `Diagnostics.jj_lib_version`.
- `crates/zanshin-ffi/src/{envelope,diagnostics}.rs` — the fourth field through `ok_diagnostics` and `zanshin_diagnostics`; tests assert it.
- `docs/ffi-abi.md` — three compile-time constants; the table row reads `3.8 (+11.6)`.
- `packages/zanshin_core/lib/src/ffi/diagnostics.dart`, `lib/zanshin_core.dart`, `test/ffi/diagnostics_test.dart` — `Diagnostics.jjLibVersion`, the export, a real-cdylib `x.y.z` check and a field-by-field decode test.
- `app/lib/src/features/projects/{projects_environment,projects_module,projects_window}.dart` (+ regenerated `app/lib/main.inject.dart`) — port `jjLibVersion()`, the adapter over `GetDiagnostics`, the provider, the brand's third line.
- `app/test/helpers/fake_projects_environment.dart`, `app/widgetbook/demo_projects_fakes.dart` — answer "0.46.0".
- `app/test/features/projects/{projects_window,projects_environment}_test.dart` — the brand rows and the adapter's read and failure.
- `coverage-baseline.txt` — new entry `crates/zanshin-jj/src/version.rs = 95.83` (auto-raised, no line lowered).
- Tracking: this spec; `deferred-work.md` ("Surfaced in the closing run of Story 11.6": 1 item).

**Review findings.** 21 findings (high 0, medium 0, low 12, false 9).
- **Patched, 3 entries (all low):** a field-by-field decode test for `decodeDiagnosticsEnvelope` (blind 5 + verification-gap 1; the deliberate break `jjLibVersion: payload.appVersion` fails it while the regex test still passes); the brand test's vacuous height assertion removed and the test renamed (blind 3; the fit is the visual check's); the ffi-abi table row `3.8 (+11.6)` (blind 6). The implementation subagent was not re-engaged (a resumed agent reports asynchronously, which this unattended run cannot wait for); the parent applied the patches.
- **Deferred (new, mirrored in deferred-work.md):** the pin-bump steps (project-context.md:190-192, root `Cargo.toml:40`) do not name `JJ_LIB_VERSION` (low; the fix edits an agent-context file).
- **Rejected, low:** an absent field showing "jj-lib " (blind 1 + edge 2 + intent d2: needs a cdylib from another schema; fixes are a guard branch or a spec change); `.wait` coupling the two reads (blind 2 + edge 1 + intent d1: a non-FFI throw needs an unresolvable native symbol, Story 11.6's rejected worker-death class); no `toString` / `==` on `Diagnostics` (blind 10: no caller compares or prints one).
- **False, 9:** the brand's growth and centring (blind 4), the doc's pin wording (blind 8), both versions missing (blind 9), a line of its own vs the version line (intent a), a literal vs a derived value (intent b), no end-to-end test (intent c: each link witnessed, the DI wiring in the generated graph; Projects is hosted first by 11.12), the export (intent d3), the mid-run process state (intent e), scope (intent f).

**Follow-up review recommendation:** false — this first pass patched 3 entries, all low (0 high, 0 medium).

**Verification:**
- `cargo make codegen`: exit 0; a second run left the diff byte-identical (no drift).
- `cargo make test` (repo root, unpiped to a log, `CARGO_HOME=~/development/sdks/cargo`, `RUSTUP_HOME` unset): exit 0 in the implementation run (11 of 27 steps: clippy, fmt, doctests, app flutter test 659, app and core analyze and format, both hygiene checks, coverage 99.48 %); a rerun on that tree planned nothing (0 paths changed since green); after the review patches exit 0 again (the same 11 steps; app 659 tests, zanshin_core 789, analyze clean, 0 files reformatted, coverage 99.48 % over 57 files, no regression).
- Targeted runs by name: `version::tests::*` (2), `diagnostics::tests::*` and `envelope::tests::ok_diagnostics_produces_diagnostics_envelope`, `diagnostics_test.dart` on the real cdylib (7, incl. "reads each field from its own slot"), `projects_environment_test.dart` (4), `projects_window_test.dart` (46, incl. both brand tests).
- Deliberate breaks: `JJ_LIB_VERSION = "0.45.0"` failed the guard ("JJ_LIB_VERSION is 0.45.0, Cargo.lock's jj-lib is 0.46.0"); `jjLibVersion: payload.appVersion` failed the new decode test. Both restored.
- Matrix audit: FFI (Rust diagnostics test, real-cdylib Dart test), pin drift (the guard, the lockfile-reader test for none/two entries, the deliberate break), both versions / jj-lib unreadable / app version unreadable (`projects_window_test.dart` sidebar group; the adapter's failure path in `projects_environment_test.dart`) — each ran and passed.
- Visual check (implementation run; catalogue via `flutter run -d macos -t widgetbook/main.dart`, Marionette 0.7, `projects/projects-window/tree` in night and paper): "Zanshin", "2026.9.1 · Build 1", "jj-lib 0.46.0" on three lines in both themes, nothing clipped or ellipsized, the chip centred on the block; compared with the DS brand (full size, `scale: "device"`), the new line matches the version line's style and spacing — the DS still shows its one stale "jj client · v0.24.0" line, the second line is the marked proposal.
- Not seen: the inactive appearance, the null cases (widget tests only), the DS card in paper, and the real FFI value in a rendered brand (the catalogue's demo answers the literal; no app surface hosts Projects before 11.12). The review patches changed tests and a doc row only, so the catalogue was not re-checked.

**Residual risks:**
- `JJ_LIB_VERSION` is a hand-repeated literal; a pin bump meets it as the guard's failure until the pin-bump steps name it (deferred).
- The real chain (FFI → adapter → brand) is first seen in a window when 11.12 hosts Projects.
