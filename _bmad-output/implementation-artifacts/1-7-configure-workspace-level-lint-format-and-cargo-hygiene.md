---
baseline_commit: 2156cc85fca5b8c084de8f8f552e1ae82d8f6881
---

# Story 1.7: Configure workspace-level lint, format, and Cargo hygiene

Status: review

<!-- Note: Validation is optional. Run validate-create-story for quality check before dev-story. -->

## Story

As a **developer ensuring mechanical code-style consistency across the whole repo**,
I want **`rustfmt.toml` at the workspace root, `clippy::pedantic` enforced centrally via `[workspace.lints]`, `.editorconfig` at the repo root, a `# WHY:`-comment backstop for `default-features = false`, and the already-committed Dart lint/format gate brought back to green against the UI code that landed since Story 1.6**,
so that **AR-P-8 and AR-P-9 are mechanically enforced, `cargo make test` is green end-to-end again (it is currently RED on the two Dart steps — see AC-7), the Story-1.1 deferred-work item "`[workspace.lints]` table — owned by Story 1.7" is absorbed, and Story 1.9's CI workflow can gate on a passing baseline**.

## Acceptance Criteria

**Note on superseded epics ACs (same pattern as Story 1.6's cargo-deny v2 crosswalk):** several bullets of `epics.md` § Story 1.7 (lines 852–913) are outdated against the actual toolchain and repo state, verified empirically at story-write time (2026-06-13). The crosswalk in Dev Notes § "Supersession crosswalk" maps every original bullet to its disposition. Headline supersessions: (a) `imports_granularity` / `group_imports` are **nightly-only** in rustfmt 1.9.0-stable (pinned toolchain 1.95.0) — they are warned-about and **silently ignored** on stable; (b) per-crate `#![warn(clippy::pedantic)]` attributes are replaced by the central `[workspace.lints]` table that the Story-1.1 review explicitly assigned to this story; (c) "empty `lib/main.dart` with `SizedBox.shrink` stub" no longer exists — commits `3aaf7c8` (Flutter UI) and `752477b` (DI) put ~3.6k lines of real UI code into `app/lib/`, and the Dart gate is **currently failing** against it.

1. **AC-1 — `rustfmt.toml` exists at the workspace root with only stable-channel options active.** New file `/Users/ralph.bergmann/development/projects/privat/Zanshin/rustfmt.toml`:
   - Line 1: `# SPDX-License-Identifier: Apache-2.0` (TOML comment prefix `#`, per the SPDX-on-TOML convention Story 1.6 established for `Makefile.toml`, `rust-toolchain.toml`, `cbindgen.toml`, `deny.toml`).
   - Active options: `max_width = 100` (AR-P-9), `edition = "2021"` (matches `[workspace.package]`; only relevant for direct `rustfmt` invocations — `cargo fmt` reads the edition from Cargo.toml).
   - `imports_granularity = "Crate"` and `group_imports = "StdExternalCrate"` are **commented out** with a `# WHY:` block: they are nightly-only in the rustfmt shipped with the pinned stable 1.95.0 toolchain. Verified empirically at story-write time (rustfmt `1.9.0-stable (59807616e1 2026-04-14)`):
     ```
     Warning: can't set `imports_granularity = Crate`, unstable features are only available in nightly channel.
     Warning: can't set `group_imports = StdExternalCrate`, unstable features are only available in nightly channel.
     ```
     Exit code stays 0 and the options do **nothing** — leaving them active would be dead config plus warning noise on every `cargo fmt` run. Keep the commented-out lines so the intent survives until the options stabilize; import grouping is enforced by review convention meanwhile. **Do NOT introduce a nightly toolchain just for `cargo +nightly fmt`** — the single pinned stable toolchain is a project invariant (`rust-toolchain.toml`, Story 1.3).
   - `cargo fmt --all --check` exits 0 after the file lands (it already exits 0 today against the formatted skeletons; the config must not change that) **and emits no unstable-option warnings**.

2. **AC-2 — Central Clippy pedantic via `[workspace.lints]` in the root `Cargo.toml`.** Append to `/Users/ralph.bergmann/development/projects/privat/Zanshin/Cargo.toml`:
   ```toml
   [workspace.lints.clippy]
   # WHY: priority = -1 so later, individually-configured lints (level overrides
   # for single pedantic lints) take precedence over the group without a
   # Cargo "ambiguous lint priority" warning.
   pedantic = { level = "warn", priority = -1 }
   ```
   - This is the **central enforcement** the Story-1.1 review deferred to this story (`deferred-work.md` § 1-1: "No `[workspace.lints]` table for central lint enforcement — owned by Story 1.7"). `[workspace.lints]` is stable Cargo since Rust 1.74 — fine on 1.95.0.
   - **Do NOT add** `nursery`, `cargo`, or other lint groups, and do NOT add `[workspace.lints.rust]` entries — AR-P-9 mandates pedantic only; anything more is unrequested scope.
   - **Do NOT add** per-crate `#![warn(clippy::pedantic)]` attributes (the original epics form) — the lints table replaces them; having both would be redundant config drift.

3. **AC-3 — All six member crates opt in via `[lints] workspace = true`.** Each of `crates/{zanshin-jj,zanshin-diff,zanshin-graph,zanshin-ffi,zanshin-mcp,xtask}/Cargo.toml` gains:
   ```toml
   [lints]
   workspace = true
   ```
   - `cargo clippy --workspace --all-targets -- -D warnings` exits 0 afterwards. Empirical baseline at story-write time: a forced pedantic re-check (`touch` crate roots, then `-W clippy::pedantic`) produced **zero** findings across the workspace, including `zanshin-ffi`'s `zanshin_ffi_version()` — so no suppressions should be needed. If a pedantic lint nonetheless fires during implementation: fix-by-refactor first; `#![allow(clippy::xxx)]` at crate root with `// WHY:` is the documented last resort (`project-context.md` § Rust).
   - `cargo build --workspace` still exits 0 **with zero warnings** (Story 1.1 invariant — pedantic warns would surface in plain builds too).
   - Note the Clippy caching gotcha for honest verification: Clippy does NOT re-lint cached crates when only the trailing `-- <flags>` change. Editing the seven `Cargo.toml` files invalidates the fingerprints anyway, so the post-change run is a real check; do not "verify" against a warm cache without a manifest change or `touch`.

4. **AC-4 — `.editorconfig` exists at the repo root.** New file, content:
   - Line 1: `# SPDX-License-Identifier: Apache-2.0`.
   - `root = true`; `[*]` with `indent_style = space`, `indent_size = 4`, `end_of_line = lf`, `insert_final_newline = true`, `trim_trailing_whitespace = true`.
   - `[*.{yml,yaml,json,toml}]` with `indent_size = 2`; `[*.dart]` with `indent_size = 2`.
   - One deliberate addition beyond the epics bullet: `[*.md]` with `trim_trailing_whitespace = false` plus a `# WHY:` comment — Markdown uses two trailing spaces as hard line breaks; trimming them silently corrupts docs (`docs/`, `_bmad-output/`). Flag in the PR description as a reviewed extension.
   - `.editorconfig` is advisory tooling config (editors pick it up); nothing in the test gate parses it. No Makefile wiring.

5. **AC-5 — `default-features = false` → inline `# WHY:` backstop wired into the test gate.** The epics AC asks for "a CI-level grep check (an xtask or simple grep in `ci.yml`)" — `ci.yml` is Story 1.9's deliverable, so the check lands as a **Makefile.toml task** that Story 1.9 inherits for free via `cargo make test`:
   - New private task `test-cargo-hygiene` in `Makefile.toml` (`script_runner = "bash"`, same pattern as `verify-codegen`). Logic: for every tracked `Cargo.toml` (`git ls-files '*Cargo.toml'` — must list exactly 7 files: root + six crates), flag any line matching `default-features *= *false` that does not also contain `# WHY:` **on the same line** (the inline form is what `crates/README.md` § "`default-features = false` comment requirement" documents — same-line only, no preceding-line variant). Non-empty findings → print file:line(s) with a clear message → exit 1.
   - `test-cargo-hygiene` is added to `[tasks.test]` `dependencies` (after `test-cargo-deny`), and the `[tasks.test]` `description` string is updated to mention it.
   - Today the check passes **vacuously** (zero `default-features` occurrences in the workspace). Per the Story 1.6 verification pattern (its AC-7), prove the fail path empirically: temporarily add `serde = { version = "1", default-features = false }` to one member crate, run `cargo make test` (or the single task), confirm exit 1 naming the file and line, **revert immediately**, confirm green, and capture both outputs in Debug Log References. Do NOT commit the violation. Also verify the positive path: the same line **with** an inline `# WHY: …` comment passes.
   - Keep the script portable to macOS BSD userland: plain `grep` (no `-P`), bash process substitution is fine (same as `verify-codegen`).

6. **AC-6 — `analysis_options.yaml` verification (verify-only, no authoring).** Per the epics forward-pull note ("landed in Story 1.2 — authoring the rule set itself is no longer Story 1.7 scope"):
   - `app/analysis_options.yaml` still `include`s `package:flutter_lints/flutter.yaml`, still carries the hand-curated inline rule list (no `very_good_analysis` dependency), and still sets `formatter: page_width: 120` + `trailing_commas: preserve`. **No edits to this file** — the rule set is the contract; this story makes the *code* conform, not the rules conform to the code (see AC-7 guardrails).
   - `flutter_lints: ^6.0.0` is pinned in `app/pubspec.yaml` `dev_dependencies` (verified true at story-write time — confirm, no edit needed).

7. **AC-7 — The Dart gate is brought from RED to green against the grown codebase, by mechanical conformance only.** Story-write-time baseline (2026-06-13, measured):
   - `dart analyze --fatal-infos --fatal-warnings` in `app/`: **217 issues — all severity `info`, 0 warnings, 0 errors** (with `--fatal-infos` that is a non-zero exit). Per-rule: 48× `specify_nonobvious_local_variable_types`, 40× `prefer_relative_imports`, 32× `always_put_required_named_parameters_first`, 30× `prefer_expression_function_bodies`, 22× `avoid_redundant_argument_values`, 15× `omit_obvious_property_types`, 9× `prefer_const_constructors`, 8× `cascade_invocations`, 7× `sort_child_properties_last`, 4× `always_put_control_body_on_new_line`, 1× `unreachable_from_main`, 1× `prefer_final_fields`. All in `app/lib/src/features/` + `app/lib/src/shared/` + 1 in `lib/main.dart` — i.e., the UI code from commits `3aaf7c8` / `752477b`. **Zero** issues in `main.inject.dart` (generated), `test/`, `hook/`, `lib/src/ffi/bindings.dart`.
   - `dart format --output=none --set-exit-if-changed .` in `app/`: **14 of 24 files would change** — all 14 are UI files under `lib/src/features/` and `lib/src/shared/`; `bindings.dart` and `main.inject.dart` are format-clean.
   - Required end state: both commands exit 0; `flutter test` still passes (passes today); `flutter build macos --debug` still succeeds.
   - **The conformance path is mechanical, in this order:**
     1. `dart format .` (writes; respects `page_width: 120` from `analysis_options.yaml`).
     2. `dart fix --apply`, iterated until convergence — `dart fix --dry-run` proposed **190 fixes in 16 files** at story-write time; fixes can cascade new findings (e.g., `prefer_relative_imports` rewrites trigger `directives_ordering`), so re-run analyze→fix up to ~3 rounds.
     3. Manual edits for the small auto-unfixable remainder (~13: `always_put_control_body_on_new_line`, `cascade_invocations`, `unreachable_from_main`) — smallest possible diffs.
     4. Final `dart format .` pass, then re-verify both gate commands.
   - **Scope guardrails (binding):** this is lint conformance of existing files, NOT UI work. No widget-tree restructuring, no renames, no new widgets, no behavior or layout changes, no rewriting of Ralph's UI logic beyond what the named lint at the named location requires. `project-context.md`'s "NEVER write Flutter UI code in this scope" stays intact — mechanical conformance ≠ UI authoring.
   - **Do NOT relax or remove `analysis_options.yaml` rules to get green** (see AC-6). Do NOT add `analyzer: exclude:` entries for generated files — `main.inject.dart` is clean today; pre-emptive excludes are speculative scaffolding.
   - `unreachable_from_main` (1 finding): if the flagged member is genuinely dead, delete it; if it is deliberately-kept mock/staging data for upcoming UI work, a line-level `// ignore: unreachable_from_main` with a `// WHY:` comment is the acceptable last resort (mirror of the Rust suppression discipline).
   - **Generated-file guard (AR-AP-7):** `app/lib/src/ffi/bindings.dart` and `app/lib/main.inject.dart` must not be hand-edited. Both are gate-clean today; if any step would modify them, stop and reassess instead of committing the edit.

8. **AC-8 — License-header and Cargo-pin conventions verified (no edits expected).**
   - SPDX discipline: every `.rs`/`.dart` source file starts with `// SPDX-License-Identifier: Apache-2.0` (true today), and **no** file carries `// Copyright …` boilerplate. The original epics bullet "the file contains no license header at all (per AR-P-9)" is REFINED by the `project-context.md` frontmatter override: the single-line SPDX identifier is **required**, full Apache boilerplate stays banned. New files from this story (`rustfmt.toml`, `.editorconfig`) carry the `#`-prefixed SPDX line.
   - Pin convention: `crates/README.md` already documents `=x.y.z` pins for pre-1.0 deps and the inline-`# WHY:` rule for `default-features = false` (Story 1.1). Verify it is unchanged; member crates still have empty `[dependencies]` tables. No edit.

9. **AC-9 — No regressions on Story 1.1–1.6 invariants.** After all edits:
   - `cargo build --workspace` exits 0, zero warnings.
   - `cargo build --release` exits 0, zero warnings, does NOT compile `xtask` (`default-members` untouched).
   - `cargo make test` exits 0 **end-to-end** — this story is what returns it to green (the two Dart steps fail at story start; everything else is green today: `test-cargo`, `test-clippy`, `test-fmt`, `test-flutter`, `test-cargo-deny`).
   - `cargo make codegen` exits 0 and is byte-idempotent; `cargo make verify-codegen` exits 0 on a clean tree (Story 1.5 invariants — nothing here touches codegen inputs).
   - `cd app && flutter build macos --debug` exits 0 (Story 1.2 invariant).
   - `rustup show active-toolchain` from repo root still reports the `1.95.0` override (Story 1.3 invariant).

10. **AC-10 — `deferred-work.md` updated: the `[workspace.lints]` entry is RESOLVED.** In `_bmad-output/implementation-artifacts/deferred-work.md` § "Deferred from: code review of 1-1-…", apply the established strikethrough pattern:

    Before:
    ```markdown
    - **No `[workspace.lints]` table for central lint enforcement** [`Cargo.toml`] — owned by Story 1.7 (lint/format config).
    ```
    After:
    ```markdown
    - ~~**No `[workspace.lints]` table for central lint enforcement** [`Cargo.toml`]~~ — RESOLVED 2026-06-13 (Story 1.7): `[workspace.lints.clippy] pedantic = { level = "warn", priority = -1 }` at workspace root, all six member crates opt in via `[lints] workspace = true`; replaces the per-crate `#![warn(clippy::pedantic)]` attribute form from the original epics AC.
    ```
    The sibling 1-1 entries (`NOTICE` file, `[profile.*]`) and all other sections stay untouched — Story 1.7 absorbs exactly this one entry.

11. **AC-11 — `sprint-status.yaml` audit trail.** At story-write time (done by this workflow): `1-7-configure-workspace-level-lint-format-and-cargo-hygiene: ready-for-dev`, `last_updated: 2026-06-13`, audit comment `# Story 1-7 created (ready-for-dev): 2026-06-13` appended after the 1-6 lines. The dev agent transitions `in-progress` → `review` → `done` per the standard workflow, with matching audit comments.

**Edge cases:**

12. **Edge case — rustfmt options stabilize on a future toolchain bump.** When a Rust pin bump ships a rustfmt where `imports_granularity` / `group_imports` are stable, uncomment them in `rustfmt.toml` **in the same PR as the toolchain bump**, run `cargo fmt --all`, and commit the (possibly large) one-time reformat there. Until then the commented block + `# WHY:` is the record of intent.

13. **Edge case — pedantic fires on future real code.** Epic 2+ will trigger pedantic lints (`must_use_candidate`, `missing_errors_doc`, …) on real implementations. The discipline is already written down (`project-context.md` § Rust): refactor first, `#![allow]`+`// WHY:` at crate root as last resort, reviewed in the PR that adds it. This story only establishes the mechanism; it does not pre-suppress anything.

14. **Edge case — `dart fix --apply` produces oscillating or conflicting fixes.** Two curated rules can interact (e.g., `omit_obvious_property_types` vs `specify_nonobvious_property_types` are complementary, not contradictory — but fix application order matters). If a fix round re-introduces findings a previous round removed, stop iterating, fix the residue by hand, and note the rule pair in Debug Log References. Do not loop `dart fix` unboundedly.

15. **Edge case — `main.inject.dart` regeneration drift.** `build_runner`/`inject_generator` output is format-clean today. If a future regeneration emits code that violates `dart format` (e.g., generator's line width ≠ project's `page_width: 120`), that is the moment to add an `analyzer`/format exclusion — deliberately, in its own PR. Not pre-empted here.

16. **Edge case — `git ls-files '*Cargo.toml'` scope.** The hygiene check intentionally covers only **tracked** manifests; an uncommitted scratch crate doesn't fail the gate until it is added. After Epic 2 adds workspace deps, the check keeps working unchanged — it greps manifests, not the lockfile, and `Cargo.lock` is irrelevant to it. If a future `[workspace.dependencies]` entry in the root manifest uses `default-features = false`, the root `Cargo.toml` is in the checked set (file #7) and the same inline-`# WHY:` rule applies.

17. **Edge case — new Dart deps from the UI commits.** `app/pubspec.yaml` gained `flutter_svg`, `window_manager`, `inject_annotation`/`inject_flutter`, `theme_tailor_annotation` (+ dev: `build_runner`, `inject_generator`, `theme_tailor`) outside any story. The WIP license rule (eyeball permissive-only at review) applies; a quick license glance during this story's review is cheap due diligence. Not a blocker for this story; `pana`/license-gate work stays deferred (release phase).

## Tasks / Subtasks

- [x] **T1 — Create `rustfmt.toml` (AC: 1)**
  - [x] SPDX line 1; `max_width = 100`; `edition = "2021"`; commented-out `imports_granularity` / `group_imports` block with `# WHY:` naming the nightly-only constraint and the empirically-captured warning text.
  - [x] Run `cargo fmt --all --check` → exit 0, **no warnings on stderr**.
- [x] **T2 — Central Clippy pedantic (AC: 2, 3)**
  - [x] Append `[workspace.lints.clippy]` table (with `priority = -1` + `# WHY:`) to root `Cargo.toml`.
  - [x] Add `[lints] workspace = true` to all six member-crate manifests.
  - [x] `cargo clippy --workspace --all-targets -- -D warnings` → exit 0 (manifest edits force real re-lint; no warm-cache false green).
  - [x] `cargo build --workspace` → exit 0, zero warnings.
- [x] **T3 — Create `.editorconfig` (AC: 4)**
  - [x] SPDX line 1, `root = true`, `[*]` (space/4/lf/final-newline/trim), `[*.{yml,yaml,json,toml}]` 2, `[*.dart]` 2, `[*.md]` no-trim + `# WHY:`.
- [x] **T4 — `test-cargo-hygiene` Makefile task (AC: 5)**
  - [x] Author the bash script task; verify `git ls-files '*Cargo.toml'` lists exactly 7 manifests.
  - [x] Wire into `[tasks.test]` dependencies (after `test-cargo-deny`); update the `test` task description string.
  - [x] Fail-path verification: temp `default-features = false` without `# WHY:` → task exits 1 naming file:line → revert → green. Positive path: same line **with** `# WHY:` → passes. Capture both in Debug Log References. Do not commit the temp edits.
- [x] **T5 — Bring the Dart gate to green, mechanically (AC: 6, 7)**
  - [x] Verify `analysis_options.yaml` + `flutter_lints: ^6.0.0` pin unchanged (read-only).
  - [x] `dart format .` → `dart fix --apply` (iterate ≤ 3 rounds) → manual residue (~13 findings) → final `dart format .`.
  - [x] `dart analyze --fatal-infos --fatal-warnings` → exit 0; `dart format --output=none --set-exit-if-changed .` → exit 0.
  - [x] `flutter test` passes; `flutter build macos --debug` succeeds.
  - [x] Confirm `bindings.dart` and `main.inject.dart` are byte-identical to pre-story state (`git diff --stat` shows no generated files).
- [x] **T6 — Convention verification sweep (AC: 8)**
  - [x] All `.rs`/`.dart` files: SPDX line 1 present, no `// Copyright` boilerplate (spot-check + grep).
  - [x] `crates/README.md` pin-convention section unchanged; member `[dependencies]` still empty.
- [x] **T7 — Full regression sweep (AC: 9)**
  - [x] `cargo make test` end-to-end exit 0 (now 8 sub-tasks including `test-cargo-hygiene`).
  - [x] `cargo build --workspace` / `cargo build --release` (no xtask) / `cargo make codegen` idempotent / `cargo make verify-codegen` clean / `flutter build macos --debug` / `rustup show active-toolchain`.
  - [x] `git status` — expected footprint: NEW `rustfmt.toml`, `.editorconfig`; EDIT root `Cargo.toml`, 6× member `Cargo.toml`, `Makefile.toml`, ~16 files under `app/lib/`, `deferred-work.md`, `sprint-status.yaml`. **No** edits to `analysis_options.yaml`, `pubspec.yaml`, `bindings.dart`, `main.inject.dart`, `zanshin_ffi.h`, `deny.toml`, `crates/README.md`.
- [x] **T8 — Bookkeeping (AC: 10, 11)**
  - [x] Mark the `[workspace.lints]` deferred-work entry RESOLVED (exact replacement text in AC-10).
  - [x] sprint-status transitions + audit comments per workflow.

## Dev Notes

### What this story is

Config + conformance. Four small config artifacts (`rustfmt.toml`, `[workspace.lints]` + member opt-ins, `.editorconfig`, one Makefile task) and one mechanical cleanup pass that returns `cargo make test` to green after the UI/DI commits (`3aaf7c8`, `752477b`) landed 217 lint infos and 14 unformatted files in `app/lib/`. Satisfies AR-P-8 / AR-P-9 enforcement and absorbs the 1-1 deferred `[workspace.lints]` item. No new functionality, no FFI surface change, no codegen, no schemas.

### What this story is NOT

- **NOT authoring the Dart rule set** — `analysis_options.yaml` landed in Story 1.2 (forward-pull accepted in its review); this story treats it as read-only contract.
- **NOT relaxing lints to get green.** The code conforms to the rules, never vice versa. If a rule genuinely proves wrong for this project, that's a deliberate Ralph decision in its own PR — not a side effect of this story.
- **NOT UI work.** The `app/lib/src/features|shared` edits are strictly the mechanical fix for the named lint at the named location plus formatter output. No redesign, no renames, no widget changes. (`project-context.md` "NEVER write Flutter UI code" stays binding.)
- **NOT adding per-crate `#![warn(clippy::pedantic)]` attributes** — superseded by `[workspace.lints]` (see crosswalk).
- **NOT adding extra lint groups** (`clippy::nursery`, `clippy::cargo`) or `[workspace.lints.rust]` rows — AR-P-9 says pedantic.
- **NOT installing a nightly toolchain** for rustfmt's unstable options.
- **NOT touching `ci.yml`** — Story 1.9 creates it and gets the hygiene check via `cargo make test`.
- **NOT pre-adding analyzer excludes, format ignores, or `[bans]`/`[licenses]` entries** — no speculative scaffolding.
- **NOT editing generated files** (`bindings.dart`, `main.inject.dart`, `zanshin_ffi.h`) — AR-AP-7.

### Current state at story start (all measured 2026-06-13)

| Gate step (`cargo make test` order) | Status today |
|---|---|
| `test-cargo` (`cargo test --workspace`) | green |
| `test-clippy` (`-D warnings`, no pedantic yet) | green — **and a forced pedantic probe also fires zero** |
| `test-fmt` (`cargo fmt --all --check`) | green (no rustfmt.toml yet — defaults happen to hold) |
| `test-flutter` (`flutter test`) | green (1 smoke test) |
| `test-dart-analyze` (`--fatal-infos --fatal-warnings`) | **RED — 217 infos** (UI code) |
| `test-dart-format` (`--set-exit-if-changed`) | **RED — 14 of 24 files** (UI code) |
| `test-cargo-deny` (`advisories bans`) | green |

Repo facts: no `rustfmt.toml`, no `.editorconfig`, no `[workspace.lints]`, no `[lints]` in members, no clippy attributes in crate roots, zero `default-features` occurrences, member `[dependencies]` all empty, `[workspace.dependencies]` empty. `crates/README.md` documents the pin + `# WHY:` conventions (Story 1.1). All `.rs` crate roots and TOML configs carry SPDX line 1 (Stories 1.1–1.6). `dart fix --dry-run`: 190 proposed fixes in 16 files.

### Supersession crosswalk (epics.md § Story 1.7 → this story)

| Original epics bullet (lines 852–913) | Disposition |
|---|---|
| `rustfmt.toml` with `max_width`, `edition`, `imports_granularity`, `group_imports` | **PARTIAL** — first two active; last two nightly-only on stable rustfmt 1.9.0 → commented out + `# WHY:` (AC-1). Empirically verified, same outdated-AC pattern Story 1.6 hit with cargo-deny v1 keys. |
| `#![warn(clippy::pedantic)]` at top of every crate root | **SUPERSEDED** by `[workspace.lints.clippy]` + member `[lints] workspace = true` (AC-2/3) — central enforcement explicitly assigned to 1.7 by the 1-1 review (`deferred-work.md`). |
| "`cargo clippy … -D warnings` exits 0; empty crates trigger nothing" | **CONFIRMED empirically** — still zero pedantic findings incl. `zanshin_ffi_version()` (AC-3). |
| `analysis_options.yaml` include + curated rules + `flutter_lints ^6.0.0` pin | **VERIFY-ONLY** (AC-6) — landed in 1.2; pin confirmed present. |
| "`dart analyze` against the empty `lib/main.dart` (SizedBox.shrink stub) exits 0" | **OUTDATED** — real UI app exists since `3aaf7c8`/`752477b`; gate target is the grown codebase, currently RED → AC-7 makes it green. |
| "no `[dependencies]` pinned yet; convention documented in `crates/README.md`" | **ALREADY SATISFIED** (Story 1.1) — verify, no edit (AC-8). |
| CI-level grep check for `default-features = false` without `# WHY:` ("xtask or grep in ci.yml") | **RELOCATED** to Makefile task `test-cargo-hygiene` so the single-entry-point invariant holds and 1.9 inherits it (AC-5). xtask stays a placeholder until Epic 2 (`gen-fixture`). |
| `.editorconfig` contents | **AS WRITTEN** + reviewed `[*.md]` no-trim extension (AC-4). |
| "no per-file license headers / no `// Copyright`" | **REFINED** — SPDX single line required per `project-context.md` frontmatter override of architecture § P-9; boilerplate still banned (AC-8). |
| Edge case "pedantic noise → crate-level `#![allow]` + `// WHY:`" | **KEPT** as the standing discipline (Edge case 13). |

### Previous-story intelligence (1-6 and earlier)

- **Verify tool schemas/options against the installed binaries, not the planning docs** — 1-6's cargo-deny v1→v2 lesson; this story's rustfmt probe repeats the pattern. When an AC and the tool disagree, the tool wins and the story documents the supersession.
- **SPDX-on-TOML convention** (`#` prefix, line 1) established in 1-6 — applies to `rustfmt.toml`; extended here to `.editorconfig` (INI-style `#` comments).
- **Empirical fail-path verifications are captured in Debug Log References, not committed as tests** (1-6 AC-7 precedent) — reused for the hygiene-check fail path (AC-5).
- **Makefile conventions** (Story 1.4): private sub-tasks named `test-*`, `script_runner = "bash"` with `set -euo pipefail` for script tasks, `# WHY:` comments on non-obvious choices, `cwd = "app"` for Dart-side tasks. `[tasks.test]` order is the documentation of the gate — append, don't reorder.
- **`verify-codegen` refuses dirty codegen outputs** (1-5) — run the T7 sweep from a tree where `bindings.dart`/`zanshin_ffi.h` are committed-clean, or it exits 1 by design.
- **Audit-comment pattern in sprint-status.yaml** (`# Story 1-7 started: …` etc.) — keep it; reviews check for it (a 1-6 review patch added missing lines).

### Git intelligence (commits since 1-6 done)

- `b98c7b1` Story 1.6 (deny.toml + README + SPDX retrofits) — last story-tracked commit.
- `752477b` "add DI" — `inject_annotation`/`inject_flutter`/`inject_generator` + generated `app/lib/main.inject.dart`; `main.dart` now bootstraps via DI.
- `3aaf7c8` "Flutter UI generated from Claude Design" — ~3.6k lines UI Dart (14 widgets/screens, mock data, theme, 37 SVG assets) + `flutter_svg`, `window_manager`, `theme_tailor*` deps. **This is the commit that broke the Dart gate** (it was never run through `cargo make test`).
- `45130b9`/`6cf948f` cleanup + revert (restored `_bmad-output/`), `2156cc8` gitignore fix. No Rust-side changes since 1-6 — the Rust gate is exactly as 1-6 left it.

### Project Structure Notes

- New files at repo root per architecture § "Project Structure Anchors" / § "File Organization Patterns": `rustfmt.toml` (anchor listed at architecture.md:388 "max_width = 100"), `.editorconfig` (anchor at architecture.md:383). Tool configs live at workspace root — matches `deny.toml`/`cbindgen.toml`/`Makefile.toml` precedent.
- No new directories. No `mod.rs`, no Dart barrels, no schema files touched.
- Expected diff footprint (≈): 2 NEW config files, 8 EDITED TOML manifests/Makefile, ~16 EDITED Dart files (mechanical), 2 EDITED bookkeeping docs.

### Testing standards summary (this story's shape)

- **No new automated tests.** The deliverables *are* test-gate config; their test is the gate itself (`cargo make test`, 8 sub-tasks after this story).
- Fail-path proofs (hygiene check, AC-5) are one-time manual verifications → Debug Log References (1-6 pattern).
- JSON-schema validation rules don't apply (no FFI JSON in scope). No fixtures, no `insta`, no `JJ_CONFIG` pinning needed.
- The behavioral safety net for the Dart edits is `flutter test` + `flutter build macos --debug` — both must stay green; lint conformance must not alter runtime behavior.

### References

- [Source: _bmad-output/planning-artifacts/epics.md § "Story 1.7: Configure workspace-level lint, format, and Cargo hygiene" — lines 852–913]
- [Source: _bmad-output/planning-artifacts/epics.md § "Additional Requirements" — AR-P-8 (lines 200), AR-P-9 (line 201), AR-AP-7 (line 211)]
- [Source: _bmad-output/planning-artifacts/architecture.md § P-8 "Cargo.toml Hygiene" (line 340), § P-9 "Linter / Formatter Configs" (lines 346–348), structure anchors (lines 383, 388, 466), § "File Organization Patterns" (line 591)]
- [Source: _bmad-output/project-context.md § "Language-Specific Rules — Rust" (Clippy refactor-not-suppress discipline), § "Linter / formatter enforcement", § "Documentation" (SPDX override of architecture § P-9), § "Critical Don't-Miss Rules" ("NEVER write Flutter UI code in this scope", "NEVER plan with a good-enough mindset on CODE QUALITY")]
- [Source: _bmad-output/implementation-artifacts/deferred-work.md § 1-1 — "`[workspace.lints]` table … owned by Story 1.7"]
- [Source: _bmad-output/implementation-artifacts/1-6-add-cargo-deny-advisories-bans-security-backstop.md — SPDX-on-TOML convention, empirical-verification pattern, supersession-crosswalk pattern]
- [Source: crates/README.md § "`default-features = false` comment requirement" — inline `# WHY:` form the hygiene check enforces]
- [Source: Makefile.toml — `[tasks.test]` dependency list (lines 47–57), `verify-codegen` bash-script precedent (lines 123–201)]
- [Empirical, story-write 2026-06-13: rustfmt `1.9.0-stable` warns + ignores `imports_granularity`/`group_imports` on the pinned 1.95.0 toolchain; forced clippy-pedantic probe → 0 findings; `dart analyze` → 217 infos/0 warnings/0 errors; `dart format` → 14/24 files; `dart fix --dry-run` → 190 fixes in 16 files; `flutter test` → pass]
- [Source: Cargo reference § `[lints]` — workspace lints table stable since Rust 1.74; `priority` field for group-vs-lint precedence]

## Dev Agent Record

### Agent Model Used

claude-opus-4-8 (Opus 4.8), BMad dev-story workflow.

### Debug Log References

Baseline commit at story start: `2156cc85fca5b8c084de8f8f552e1ae82d8f6881`. Empirical state re-verified against the installed toolchain (story's "tool wins" discipline):

- Toolchain: `1.95.0-aarch64-apple-darwin` (overridden by `rust-toolchain.toml`); rustfmt `1.9.0-stable (59807616e1 2026-04-14)`.
- `git ls-files '*Cargo.toml'` → exactly 7 manifests (root + six crates). Member `[dependencies]` all empty; `[workspace.dependencies]` empty; zero `default-features` occurrences pre-change.

**T1** — `cargo fmt --all --check` → exit 0, no stderr (no unstable-option warnings; `imports_granularity`/`group_imports` kept commented out).

**T2** — after appending `[workspace.lints.clippy] pedantic = { level = "warn", priority = -1 }` and `[lints] workspace = true` to all six members:
- `cargo clippy --workspace --all-targets -- -D warnings` → exit 0, **zero findings** (all six crates re-linted — manifest edits invalidated fingerprints, no warm-cache false green, incl. `zanshin_ffi_version()`).
- `cargo build --workspace` → exit 0, zero warnings.

**T4** — `test-cargo-hygiene` fail-path proof (AC-5), run against the exact script body on `crates/zanshin-diff/Cargo.toml`, reverted immediately (not committed):
- Scenario 1 (clean tree): `test-cargo-hygiene: OK` → exit 0.
- Scenario 2 (`serde = { version = "1", default-features = false }`, no `# WHY:`): exit 1, printed
  `  crates/zanshin-diff/Cargo.toml:16:serde = { version = "1", default-features = false }`
  then `test-cargo-hygiene: 1 occurrence(s) of \`default-features = false\` lack an inline \`# WHY:\` comment`.
- Scenario 3 (same line **with** trailing `# WHY: …`): `test-cargo-hygiene: OK` → exit 0.
- Post-revert: guinea manifest byte-identical to its T2 state (only the `[lints]` addition vs HEAD; no test pollution). Private task → not invokable via `cargo make test-cargo-hygiene` directly (by design); exercised via the identical script body and via the full `cargo make test` gate (T7).

### Completion Notes List

- **Config artifacts (T1–T4):** `rustfmt.toml` (`max_width = 100`, `edition = "2021"`; `imports_granularity`/`group_imports` commented out — nightly-only on rustfmt 1.9.0-stable, verified). Central `[workspace.lints.clippy] pedantic = { level = "warn", priority = -1 }` + `[lints] workspace = true` in all six member crates → clippy pedantic **zero findings**, build zero warnings. `.editorconfig` (root, with the reviewed `[*.md]` no-trim extension). New `test-cargo-hygiene` Makefile task enforcing the inline `# WHY:` backstop for `default-features = false`, wired into `[tasks.test]` after `test-cargo-deny`; fail/positive paths proven empirically (see Debug Log References) and reverted, not committed.
- **Dart gate RED → green (T5):** baseline reproduced exactly (217 `info`, 0 warn/err; 14/24 files unformatted). Mechanical path: `dart format .` → `dart fix --apply` (191 fixes in 16 files; round 2 = "Nothing to fix!") → 12 manual residue edits → final `dart format .`. Residue: 7 `cascade_invocations` in `_ZanshinMarkPainter.paint` + 1 in `home_dialog`'s `arc()` helper (merged `moveTo`/`arcToPoint` into the `path` cascade), 3 `always_put_control_body_on_new_line` (braced `if`-returns), 1 `unreachable_from_main` on `MainComponent.zanshinAppFactory` — a deliberately-kept `@inject` DI contract that inject_generator overrides in `main.inject.dart`; suppressed with a line-level `// ignore: unreachable_from_main` + `// WHY:` (mirror of the Rust suppression discipline). End state: `dart analyze --fatal-infos --fatal-warnings` → **No issues found!**; `dart format --set-exit-if-changed` → 0 changed; `flutter test` passes; `flutter build macos --debug` succeeds.
- **Generated files untouched (AR-AP-7):** `bindings.dart` and `main.inject.dart` byte-identical pre/post (blob hashes `e624259b…` / `299b27e6…`). The SPDX sweep (T6) found 4 `.dart` files without a line-1 SPDX header — all four are generator output (`bindings.dart` = ffigen; `main.inject.dart`, `zanshin_app.factory.dart`, `home_page.factory.dart` = inject_generator), correctly left unedited. All hand-authored source carries SPDX line 1; no `// Copyright` boilerplate anywhere.
- **Regression (T7):** `cargo make test` **green end-to-end** (8 subtasks) — this is what returns the gate to green. `cargo build --release` skips `xtask`; `cargo make verify-codegen` no drift; toolchain pinned `1.95.0`.
- **Out-of-scope state observed, not touched:** `app/pubspec.yaml` + `app/pubspec.lock` carry pre-existing **staged** changes from before this story (present in the session-start git status) — left untouched per AC-7. Incidental CocoaPods/Xcode churn from `flutter build` (`app/macos/Podfile.lock`, `Runner.xcodeproj/project.pbxproj`) was reverted to keep the diff focused.

### File List

**New:**
- `rustfmt.toml`
- `.editorconfig`

**Modified — config/build:**
- `Cargo.toml`
- `Makefile.toml`
- `crates/zanshin-jj/Cargo.toml`
- `crates/zanshin-diff/Cargo.toml`
- `crates/zanshin-graph/Cargo.toml`
- `crates/zanshin-ffi/Cargo.toml`
- `crates/zanshin-mcp/Cargo.toml`
- `crates/xtask/Cargo.toml`

**Modified — Dart lint/format conformance (mechanical):**
- `app/lib/main.dart`
- `app/lib/src/features/app/zanshin_app.dart`
- `app/lib/src/features/branches/branches_panel.dart`
- `app/lib/src/features/commits/commit_card.dart`
- `app/lib/src/features/commits/commit_detail.dart`
- `app/lib/src/features/commits/diff_block.dart`
- `app/lib/src/features/history/history_column.dart`
- `app/lib/src/features/home/home_page.dart`
- `app/lib/src/features/projects/home_dialog.dart`
- `app/lib/src/features/shell/app_shell.dart`
- `app/lib/src/features/shell/main_nav_rail.dart`
- `app/lib/src/features/shell/status_bar.dart`
- `app/lib/src/features/shell/window_title_bar.dart`
- `app/lib/src/shared/data/mock_data.dart`
- `app/lib/src/shared/theme/zanshin_colors.dart`
- `app/lib/src/shared/widgets/commit_tags.dart`
- `app/lib/src/shared/widgets/zanshin_icon.dart`

**Modified — bookkeeping:**
- `_bmad-output/implementation-artifacts/deferred-work.md`
- `_bmad-output/implementation-artifacts/sprint-status.yaml`
- `_bmad-output/implementation-artifacts/1-7-configure-workspace-level-lint-format-and-cargo-hygiene.md` (this story)

### Change Log

| Date | Change |
|---|---|
| 2026-06-13 | Story 1.7 implemented: `rustfmt.toml` + `[workspace.lints]` central pedantic + member `[lints]` opt-ins + `.editorconfig` + `test-cargo-hygiene` gate; Dart gate brought RED → green by mechanical lint/format conformance (217 infos + 14 unformatted files resolved); `[workspace.lints]` deferred-work item resolved. `cargo make test` green end-to-end. Status → review. |
