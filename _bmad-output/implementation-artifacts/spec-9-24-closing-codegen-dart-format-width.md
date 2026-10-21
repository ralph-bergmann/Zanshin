---
title: 'Story 9.24 closing run — `cargo make codegen` formats the Dart accessors at the package width'
type: 'bugfix'
created: '2026-10-21'
status: 'done'
baseline_revision: 'e79d74379649555836a79662637027fe781b5ff1'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
warnings: []
deferred: []
---

<intent-contract>

## Intent

**Problem:** Ledger item 1 handed to this closing run (Story 9.24's deferral): `cargo make codegen` re-wrapped 29 hand-written `packages/zanshin_core/lib/src/ffi/*.dart` files at 80 columns. Verified at `e79d743`: the ledger's diagnosis (cwd = repo root) is wrong — `dart format --output=none packages/zanshin_core/lib/src/ffi/` from the root reports `0 changed` today, and running `cargo make --allow-private codegen-flatc-dart` leaves the tree clean. The real trigger is a missing workspace `.dart_tool/package_config.json`: with it moved away, BOTH the root run and the in-package run report `31 changed` (80 columns). The package's width (`page_width: 120`, `linter/rules.yaml:1-2`) is reached through `analysis_options.yaml` → `include: ../../linter/dart.yaml` → `include: [package:lints/recommended.yaml, rules.yaml]`; without a package config the `package:` include cannot resolve and the formatter silently falls back to 80. In 9.24's run the root package config was (re)created only later (`.dart_tool/package_config.json` mtime 02:28, after the codegen run), which is why the in-package re-run then "worked". The task also formats every hand-written file in the directory, which is not codegen's business.

**Approach:** In `[tasks.codegen-flatc-dart]`, resolve the workspace (`dart pub get` — the same resolution `codegen-ffigen`'s `dart run ffigen` already triggers implicitly, just earlier) before formatting, and format only the flatc outputs (`*.ffi_generated.dart`), from inside `packages/zanshin_core` as the ledger follow-up suggests.

## Boundaries & Constraints

**Always:** Keep the flatc loop over `schemas/*.fbs` unchanged; the formatted set is exactly the flatc outputs (glob `lib/src/ffi/*.ffi_generated.dart`), so a future schema file is covered; keep a `# WHY:` comment naming the package-config dependency of the width; codegen on an up-to-date tree still reproduces the committed generated file byte-for-byte.

**Never:** No hard-coded `--line-length`/`-l 120` (duplicates `linter/rules.yaml`); no change to the gate's format steps, to `codegen-flatc-rust`, `codegen-cbindgen`, `codegen-ffigen` or `verify-codegen`; no edit of hand-written Dart, `epics.md`, `epic-9-context.md`, `sprint-status.yaml` or Story 9.24's spec.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Normal tree | package config present | `git status` clean after the task | — |
| Missing package config | root `.dart_tool/package_config.json` absent | task recreates it, generated file formatted at 120, `git status` clean | `dart pub get` failure aborts the task (`set -euo pipefail`) |
| Hand-written file mis-wrapped | a hand-written `lib/src/ffi/*.dart` not at committed style | codegen leaves it untouched | — |

</intent-contract>

## Code Map

- `Makefile.toml:559-572` -- `[tasks.codegen-flatc-dart]`: flatc loop `:565-567`, format step + WHY comment `:568-571` (the only change).
- `Makefile.toml:583-587` -- `codegen-ffigen` already runs `dart run ffigen` with `cwd = "packages/zanshin_core"` (implicit pub get) — read-only precedent.
- `packages/zanshin_core/analysis_options.yaml:1` → `linter/dart.yaml` → `linter/rules.yaml:1-2` (`formatter: page_width: 120`) — read-only; the include chain that needs `package:` resolution.
- `packages/zanshin_core/lib/src/ffi/envelope_zanshin.ffi_generated.dart` -- the sole flatc Dart output today.

## Tasks & Acceptance

**Execution:**
- `Makefile.toml` -- in `codegen-flatc-dart`: after the flatc loop, `cd packages/zanshin_core`, `dart pub get`, `dart format lib/src/ffi/*.ffi_generated.dart`; rewrite the WHY comment to say why (width comes from an include chain that needs the package config; hand-written files are not codegen's) -- fixes the silent 80-column fallback and scopes the format.

**Acceptance Criteria:**
- Given an up-to-date tree, when `cargo make codegen` runs, then `git status --short` is empty.
- Given the root `.dart_tool/package_config.json` is moved away, when `cargo make --allow-private codegen-flatc-dart` runs, then the package config exists again and `git status --short` is empty.
- Given a hand-written `lib/src/ffi/*.dart` file deliberately re-wrapped, when `codegen-flatc-dart` runs, then that file is unchanged by the task.

## Spec Change Log

## Review Triage Log

### 2026-10-21 — Review pass
- verdicts: 12 findings — high 0, medium 0, low 5, false 6, maybe-false 0 (+1 descriptive audit row)
- findings:
  - `[low]` `[reject]` (verification-gap) no automated check re-runs codegen without a package config or asserts hand-written files stay untouched — the repo has no harness for `Makefile.toml` scripts (`verify-codegen` is manual and snapshots only the four generated outputs); a regression needs someone to edit this task again, and a harness is far more than a direct correction. The three scenarios were run by hand on the final version (Verification below).
  - `[low]` `[patch]` (edge-case) the glob `*.ffi_generated.dart` only matches flatc output for namespace `zanshin.ffi` (flatc writes `<schema>_<namespace>_generated.dart`) — widened to `lib/src/ffi/*_generated.dart`; no hand-written file there ends in `_generated`.
  - `[false]` `[reject]` (edge-case) an unmatched glob would hand `dart format` the literal pattern — every schema the loop compiles yields a `*_generated.dart` (any namespace, after the widening), and with no schema at all the flatc loop already fails on the literal `schemas/*.fbs` before the format line.
  - `[low]` `[patch]` (edge-case, claim) the spec claims a future schema file is covered, which the namespace-specific glob did not honour — same root cause and fix as the glob row above.
  - `[low]` `[patch]` (blind) glob catches one namespace — same root cause and fix as above.
  - `[low]` `[patch]` (blind) a failed `dart pub get` after flatc leaves an unformatted generated file in the tree — `(cd packages/zanshin_core && dart pub get)` now runs before the flatc loop.
  - `[false]` `[reject]` (blind) `dart pub get` needs the Flutter-bundled `dart` — `codegen-ffigen`'s `dart run ffigen` (same package, same workspace, same `dart`) already resolved the workspace implicitly in every codegen run; no new requirement.
  - `[low]` `[patch]` (blind) the WHY comment hard-codes "120", duplicating `linter/rules.yaml` — it now names `formatter.page_width` in `linter/rules.yaml`.
  - `[false]` `[reject]` (blind) `codegen-flatc-rust`'s comment ("the exact mirror of the `dart format` step") went stale — both steps still normalise exactly the flatc outputs (`rustfmt …/*_generated.rs` vs `dart format …/*_generated.dart`); the mirror is now closer, not looser.
  - `[false]` `[reject]` (blind) `verify-codegen` keeps the silent 80-column fallback — it calls `cargo make codegen`, which now resolves the workspace first.
  - `[false]` `[reject]` (blind) the gate's `dart format --set-exit-if-changed` has the same fallback — there it runs with `--output=none`, so a missing package config fails the step loudly instead of rewriting files, and the gate's `flutter test`/`dart test` steps on the same workspace resolve it; not the silent damage this item is about, and pre-existing.
  - `[false]` `[reject]` (intent-alignment) the `## Auto Run Result` section was missing in the reviewed state — it is written at finalization (below).
  - `[descriptive]` `[reject]` (intent-alignment) the diff implements the "fix the real cause" reading plus the ledger's scoping; the `cd` into the package is not load-bearing for the width (the package config is) but follows the ledger follow-up and keeps the format paths package-relative — no defect.

## Verification

**Commands:**
- `cargo make codegen` then `git status --short` -- expected: empty.
- move `.dart_tool/package_config.json` away, `cargo make --allow-private codegen-flatc-dart`, `git status --short` -- expected: empty, package config recreated.
- `packages/zanshin_core`: `dart format --output=none --set-exit-if-changed .`, `dart analyze` -- expected: clean.

**Verification notes (this run, gate rule: no full gate):**
- Reproduction at `e79d743`: `dart format --output=none packages/zanshin_core/lib/src/ffi/` from the root → 0 changed; with `.dart_tool/package_config.json` moved away → 31 changed from the root AND from inside the package (cwd is not the cause).
- Final version: package config moved away, `cargo make --allow-private codegen-flatc-dart` → config recreated, only the generated file formatted, `git status --short` clean apart from the task edit.
- `cargo make codegen` (all four steps) → `git status --short` clean apart from the task edit.
- `lib/src/ffi/commit.dart` re-wrapped at 40 columns, task run → checksum unchanged (restored with `git checkout`).
- `packages/zanshin_core`: `dart format --output=none --set-exit-if-changed .` → 0 of 129 changed; `dart analyze` → no issues.
- No Rust, Dart source, schema or FFI change, so no `cargo test`/`clippy`/`fmt`/parity run applies. The `Makefile.toml` edit makes the change-aware gate plan run every step at the loop's final gate.

## Auto Run Result

Status: done

**Items:**
1. **fixed** (`fe7b82a623ea50d4237282e3889ca8eedc0cb72e`) — real, but the ledger's diagnosis was wrong: the 80-column re-wrap comes from a missing workspace `.dart_tool/package_config.json` (the `package:lints` include in the `analysis_options.yaml` chain carrying `page_width` cannot resolve, and the formatter silently falls back to 80), not from the root cwd. `codegen-flatc-dart` now runs `dart pub get` in `packages/zanshin_core` before flatc and formats only `lib/src/ffi/*_generated.dart` from inside the package.

**Files changed:**
- `Makefile.toml` — `[tasks.codegen-flatc-dart]`: resolve the workspace first, format only flatc outputs, WHY comment.

**Review:** 12 findings — 5 low patched (one root cause: the namespace-specific glob, 3 rows; pub-get ordering; hard-coded width in the comment), 1 low rejected (no automated harness for Makefile scripts — manual scenarios run instead), 6 false rejected (see the triage log). Nothing deferred; no new deferred-work.md entries.

**Follow-up review recommended:** false — patched entries: high 0, medium 0, low 3 (grouped).

**Residual risks:** codegen now always runs `dart pub get` (needs the pub cache or network) — the same resolution `codegen-ffigen` already triggered later in every run. The full gate has not run (loop gate rule).
