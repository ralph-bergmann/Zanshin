---
title: 'Story 9.53 — Parity clean-up after the 2026-10-19 story loop'
type: 'bugfix'
created: '2026-10-20'
status: 'in-progress'
baseline_revision: '2e0d7f8c4f28ff5c83fe4f7b59a824c2e42433a5'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-9-context.md'
warnings: ['multiple-goals', 'oversized']
deferred: []
---

<intent-contract>

## Intent

**Problem:** Five small findings of the 2026-10-19 loop, each verified against the code at the baseline (epics.md Story 9.53; deferred-work.md items I1–I5). (1) No verb warns "There are unresolved conflicts at these paths:" after a checkout onto a conflicted `@` — `mutate::finish_transaction` and `stale::recover_at` emit only `jj.checkout_files_skipped`; the oracle ledgers it for `new_conflicting_merge`. (2) `trackingStatusOf` ignores a tracked remote row with a null target (the CLI's `(not created yet)`), so a never-pushed bookmark reads clean. (3) When the auto-update-stale recovery fails after writing operations, `snapshot::run` returns the error with `was_snapshot_taken` measured against the recovered op (set in `snapshot_locked` inside `trailing_snapshot`), not the op `run` loaded. (4) `file.rs`'s `parse_path` (single-path `file show`, `file annotate`) takes `./x`, `a/../x`, `../x` literally. (5) Two app test helpers wait a fixed number of 5 ms polls on real settings-file IO.

**Approach:** (1) A new 9.32 warning kind `UnresolvedConflicts` / code `jj.unresolved_conflicts`, emitted right after the checkout-skipped warning wherever Zanshin checks out a new `@` that differs from the old one and has conflicts — `mutate::finish_transaction` (every verb, the precondition's import finishes, clone, `workspace add`) and `stale::recover_at` — with the CLI's text block (heading + `print_conflicted_paths` lines); the ledger entry goes, an oracle scenario for `edit` comes. (2) A tracked non-`git` remote row with `target == null` for a name on the heads counts as local-ahead. (3) On ANY error from `stale::recover`, `run` re-reads the op heads (read-only) against its own loaded op id. (4) `parse_path` delegates to `op_support::parse_prefixes`. (5) Both helpers get the real-time `Stopwatch` budget of `projects_window_test.dart`.

## Boundaries & Constraints

**Always:**
- The CLI at v0.46.0 is the spec (`git -C ../jj show v0.46.0:cli/src/cli_util.rs`): `print_updated_working_copy_stats` `:2297-2331` (warn only when `Some(new_commit) != maybe_old_commit && new_commit.has_conflict()`, AFTER `print_checkout_stats`), `print_conflicted_paths` `:3129-3219`, callers `:2424` (finish) and `:715` (stale recovery, old = the stale `@`); jj-lib 0.46.0 `ui_path.rs:156-169`.
- Item 1 message: `There are unresolved conflicts at these paths:` then one line per `new_commit.tree().conflicts()` entry, in iteration order: the path as `warning::ui_path` renders it, padded with `format!("{:width$}", p, width = max_path_len.min(32) + 3)` (`max_path_len` = the max byte `len()` of the rendered paths, as the CLI), a space, then the description on the simplified merge: `{sides}-sided conflict`, plus ` including ` + the sorted (`BTreeMap` keys) set of `{n} deletion(s)` (count `sides - adds().flatten().count()`, plural `s` when > 1) and the kinds among removes+adds (`an executable`, `a symlink`, `a directory`, `a git submodule`; a non-executable file adds nothing), joined `a`, `a and b`, `a, b and c`. Lines joined by `\n`, no trailing newline (the `Warning.message` convention). A tree-read error for a conflict fails the call (`MutateError::Backend` / `PreconditionError::Backend`), as the CLI's `conflict?`.
- Warning order in `finish_transaction`: became-immutable, HEAD reset, export failures, checkout skipped, **unresolved conflicts**, identity. In `recover_at`: checkout skipped, then unresolved conflicts (old = `stale_wc_commit`, new = `desired_wc_commit`). Nothing else (the snapshot step, `report_repo_changes`, `status`) gains the warning.
- Item 1 registration follows `CloneBranchesUnmatched` exactly: `WarningKind` (doc with CLI anchor), `zanshin-ffi` `envelope.rs` const `JJ_UNRESOLVED_CONFLICTS` + both match arms + the exhaustive kind list, `tests/api_stability.rs` (both sites), `docs/rust-error-codes.md` § Warning Codes row, `packages/zanshin_core/lib/src/ffi/warning.dart` const + `values`, `test/ffi/warning_test.dart`. Every doc that lists `jj.checkout_files_skipped` as a possible warning of a call names `jj.unresolved_conflicts` next to it; header/bindings regenerated with `cargo make codegen` where a Rust doc comment feeds them.
- Item 2: only `trackingStatusOf` changes (`statusFrom` / `statusOf` precedence unchanged); a null-target row of the `git` remote or an untracked row still never counts; the DS `--proj-ahead` colour already exists.
- Item 3: the flag = `heads != [loaded_op_id]` from `op_heads_store().get_op_heads()`, nothing written, an unreadable store leaves the flag as it was — the same rule as `snapshot_locked`'s error arm (share a helper rather than copy it). The `Config` refusal for a wrong-typed `snapshot.auto-update-stale` is not a recovery error and stays as is.
- Item 4: `file show` with ONE path and `file annotate` resolve exactly as `parse_prefixes` (`./x` → `x`, `a/../x` → `x`, `../x` → `jj.invalid_input` with `invalid path: Path "../x" is not in the repo "."`; `/x`, `x/` stay refused). `PathNotFound` / `NotAFile` name the resolved path.
- Item 5: each helper loops until done or a 10 s real-time budget (`Stopwatch`, not `package:clock`) is spent, failing with a reason naming the elapsed real time — as `projects_window_test.dart:150-169`; the fake-zone helper keeps its `tester.runAsync` + `pump` per iteration.
- Rust: clippy pedantic `-D warnings`, rustfmt, rustdoc updated where it states the rules; coverage never drops; new code ≥ the floor. Dart: `dart analyze` / `dart format` clean.

**Never:**
- No new error code, no schema/`.fbs` change, no FFI signature change, no MCP change, no UI widget or visual change.
- No "unresolved conflicts" in `status` (it has its own typed conflict list) and no port of `report_repo_changes`.
- No other change to `parse_prefixes`, `build_matcher` or `wc_ops::parse_paths`; never regenerate fixtures; never lower `coverage-baseline.txt`; no edit to `epics.md`, `project-context.md`, `sprint-status.yaml` beyond this story's status line.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Edit onto conflict | `edit(M)`, M a conflicted merge (c.txt 2-sided) | ok; warnings include one `UnresolvedConflicts`, message `There are unresolved conflicts at these paths:\nc.txt    2-sided conflict` | — |
| Clean checkout | `edit(B)`, B conflict-free | no `UnresolvedConflicts` | — |
| `@` unchanged | a verb whose finish leaves the same conflicted `@` commit (e.g. `bookmark create` on a conflicted `@`) | no `UnresolvedConflicts` | — |
| Stale recovery | `workspace_update_stale()` where the head's `@` is conflicted | `Updated`; one `UnresolvedConflicts` after any `CheckoutFilesSkipped` | — |
| Rendering | deletion + executable side; symlink; one path > 32 bytes | `2-sided conflict including 1 deletion and an executable`; `… including a symlink`; padding capped at 35 | — |
| Not created yet | heads `main`, rows: tracked `origin` `main` with `target: null` | `ProjectStatus.ahead` (with a behind row elsewhere: `diverged`) | — |
| Untracked / git | null-target row untracked, or remote `git` | still null | — |
| Failed recovery | colocated, `snapshot.auto-update-stale = true`, `@` reparented (reset git head written), `git.abandon-unreachable-commits = "yes"` (or another option only the trailing snapshot's refs step reads) | call refused with `jj.config_error`; partial report `was_snapshot_taken == true`; head ≠ loaded op | `PreconditionError::Config` |
| File paths | `file_show(["./x.txt"])`, `file_annotate("a/../x.txt")` | answer for `x.txt` | — |
| Escaping path | `file_show(["../x"])`, `file_annotate("../x")` | refused | `jj.invalid_input`, `invalid path: Path "../x" is not in the repo "."` |

</intent-contract>

## Code Map

- `crates/zanshin-jj/src/warning.rs` -- `WarningKind` :29-161 (append `UnresolvedConflicts` after `CheckoutFilesSkipped`'s group or at the end, doc with `cli_util.rs:2297-2331` @ v0.46.0, Story 9.53); `checkout_files_skipped` :427 (sibling to add the builder next to); `ui_path` :256; `local` :235; inline tests :546+ (rendering witnesses with hand-built `Merge<Option<TreeValue>>` go here).
- `crates/zanshin-jj/src/mutate.rs` -- `finish_transaction` :655-722: `maybe_old_wc_commit` :670, checkout :701-714 — add the conflict warning after `checkout_files_skipped` :712, only when `maybe_old_wc_commit.map(id) != Some(new.id())`; doc :628-646 lists the order.
- `crates/zanshin-jj/src/stale.rs` -- `recover_at` :216-288, checkout warning :272 (old = `stale_wc_commit`, new = `desired_wc_commit`); module doc.
- `crates/zanshin-jj/src/snapshot.rs` -- `run` :410-440 (`loaded_op_id` :420, `stale::recover(...)?` :433 — catch the error, re-read heads, return it); `snapshot_locked` error arm :467-478 (the read to share); `run` doc :389-409.
- `crates/zanshin-jj/src/file.rs` -- `parse_path` :254-258 → `op_support::parse_prefixes(std::slice::from_ref(...))`, mapping the reason to `FileError::InvalidInput`; callers :485 (single-entry `file show`), :545 (`file_annotate`); `file_annotate` doc `# Errors` :524-531.
- `crates/zanshin-jj/src/op_support.rs` -- `parse_prefixes` :783-792 (reuse, unchanged).
- `crates/zanshin-ffi/src/envelope.rs` -- `JJ_CLONE_BRANCHES_UNMATCHED` :328, `warning_code` match :382, `registered` :1223, kind list :1280.
- `crates/zanshin-ffi/src/repo.rs` :775, `crates/zanshin-jj/src/repo.rs` :2499, `crates/zanshin-jj/src/convert.rs` :97/:263, `packages/zanshin_core/lib/src/ffi/workspace.dart` -- doc sites listing `jj.checkout_files_skipped`.
- `docs/rust-error-codes.md` -- § Warning Codes :91+, row `jj.checkout_files_skipped` :127 (new row after it); `jj.clone_branches_unmatched` :165 shape.
- `packages/zanshin_core/lib/src/ffi/warning.dart` :201/:210-257; `packages/zanshin_core/test/ffi/warning_test.dart` :424.
- `crates/zanshin-jj/tests/api_stability.rs` :1403, :1472.
- `crates/zanshin-parity/tests/oracle/ledger.rs` :125-132 (entry `new_conflicting_merge` / `warnings` goes — it turns STALE); `scenarios.rs` :420-434 (`new_conflicting_merge` setup to reuse for an `edit` scenario, e.g. `edit_conflicted_merge`: setup `new @-- -m D`, write `c.txt`, `new C D`, `new`; call `edit` on the merge); `main.rs` `parity!` :38, count :180 (127 → 128 per added scenario).
- `crates/zanshin-jj/tests/workspace_update_stale.rs` -- `two_workspaces` :67, `make_default_stale` :144, `reparent_default_at` :154, `a_failed_recovery_reports_its_code_and_a_report` :335 (item 3 witness sits next to it; item 1's stale witness needs the head's default `@` conflicted — build it from ws2 or a raw tx).
- `crates/zanshin-jj/tests/file_reads.rs` -- item 4 witnesses (`./x`, `a/../x`, `../x` for both verbs).
- `crates/zanshin-jj/tests/` -- an `edit`-onto-conflict witness with the exact message (e.g. `mutate.rs`); existing tests that assert an exact warning list on a conflicted `@` may need the new entry.
- `app/lib/src/features/projects/project_repos.dart` -- `trackingStatusOf` :125-145 + its doc :121-124.
- `app/test/features/projects/worker_project_repos_test.dart` -- :107-128 asserts a null-target tracked `upstream` row stays null: rewrite that case to the new rule (null-target tracked row → ahead) and keep the untracked/`git` cases null; add a `statusFrom` case (:151-183) reading ahead for a `(not created yet)` row.
- `app/test/features/home/home_page_test.dart` :98-105 `settle`; `app/test/features/window/app_window_coordinator_test.dart` :134-140 `until` (plain `test`, no fake zone); reference `app/test/features/projects/projects_window_test.dart` :34-35, :150-169.
- `_bmad-output/implementation-artifacts/deferred-work.md` -- the five source entries :1508-1511, :1515-1518, :1560-1563, :1576-1579, :1586-1589.

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/src/warning.rs` -- `WarningKind::UnresolvedConflicts` + a `pub(crate)` builder taking the workspace root and the new `@` (or its tree) returning `Result<Option<Warning>, BackendError>`; inline tests for the description variants and the padding cap -- item 1.
- `crates/zanshin-jj/src/mutate.rs`, `crates/zanshin-jj/src/stale.rs` -- emit it after the checkout-skipped warning when the new `@` differs from the old; docs list it -- item 1.
- `crates/zanshin-ffi/src/envelope.rs`, `crates/zanshin-jj/tests/api_stability.rs`, `docs/rust-error-codes.md`, `packages/zanshin_core/lib/src/ffi/warning.dart`, `packages/zanshin_core/test/ffi/warning_test.dart`, the doc sites above (+ `cargo make codegen`) -- registration -- item 1.
- `crates/zanshin-parity/tests/oracle/{ledger,scenarios,main}.rs` -- drop the `new_conflicting_merge` warnings entry; add the `edit` scenario; bump the count -- item 1.
- `crates/zanshin-jj/tests/` (mutate or a new file) and `tests/workspace_update_stale.rs` -- `edit` onto a conflicted merge asserts the exact message; a clean `edit` and an unchanged-`@` finish assert none; the stale recovery onto a conflicted head `@` warns -- item 1.
- `crates/zanshin-jj/src/snapshot.rs` -- `run`'s recovery-error arm re-reads the heads via a helper shared with `snapshot_locked`; doc; `tests/workspace_update_stale.rs` witness per the matrix row (assert the refusal kind, `was_snapshot_taken`, and that the head moved) -- item 3.
- `crates/zanshin-jj/src/file.rs` + `tests/file_reads.rs` -- item 4 and its witnesses.
- `app/lib/src/features/projects/project_repos.dart` + `app/test/features/projects/worker_project_repos_test.dart` -- item 2.
- `app/test/features/home/home_page_test.dart`, `app/test/features/window/app_window_coordinator_test.dart` -- item 5; verify locally (NOT committed) by injecting a 1.5 s delay into the settings write path or the polled condition that both helpers then still pass.
- `_bmad-output/implementation-artifacts/deferred-work.md` -- at finalisation, mark each of the five source entries resolved in the file's `~~**…**~~ — RESOLVED <date> (spec-9-53-…, commit <hash>): …` style.
- `coverage-baseline.txt` -- commit an auto-raise if the gate makes one; never lower.

**Acceptance Criteria:**
- Given `cargo test -p zanshin-parity --test oracle`, when it runs, then every scenario (the new `edit` one and `new_conflicting_merge` included) matches the pinned CLI with no ledger entry for the unresolved-conflicts warning.
- Given a Dart caller, when a verb's envelope carries the new warning, then `Warning.code == 'jj.unresolved_conflicts'` is in zanshin_core's registered `values`.
- Given `cargo make test` on the final tree (repo root, unpiped, synchronous), then it exits 0 and `coverage-baseline.txt` is not lowered.
- Given the end of the run, then `git status --porcelain` is clean and every commit ends with the required co-author trailer and was made with `--no-gpg-sign`.

## Spec Change Log

## Review Triage Log

## Design Notes

**Item 1, where it fires.** The CLI has exactly two emitters (`git grep` @ v0.46.0: `cli_util.rs:715`, `:2424` → `:2297`); every Zanshin path that the CLI routes through `finish_transaction` already goes through `mutate::finish_transaction` (verbs via `finish_verb`, `snapshot.rs` head/refs imports, `creation.rs` clone, `workspace_add.rs`, `convert.rs`), so one site there plus `recover_at` is complete. The CLI's guard compares commits (`Some(new) != old`); Zanshin checks out unconditionally, so the guard must be explicit — otherwise a no-move finish on a conflicted `@` would warn where the CLI does not. A rewrite of a conflicted `@` (e.g. `describe`) DOES warn in the CLI (new commit id), so it warns here too.

Golden (CLI from the workspace root): `edit` onto a merge whose `c.txt` conflicts →
```
Warning: There are unresolved conflicts at these paths:
c.txt    2-sided conflict
```
`max_path_len = 5`, width `min(5, 32) + 3 = 8`, then `' '`.

**Item 3.** Any recovery error, not only the trailing snapshot's, can follow written operations (a `snapshot working copy` + reconcile, a `reset git head`), so the re-read covers the whole `stale::recover` error path.

## Verification

**Commands:**
- `cargo test -p zanshin-jj --lib warning` and `cargo test -p zanshin-jj --test workspace_update_stale --test file_reads --test mutate` -- expected: green, new tests included.
- `cargo test -p zanshin-parity --test oracle` -- expected: all pass, ledger one entry shorter.
- `flutter test test/features/projects/worker_project_repos_test.dart test/features/home/home_page_test.dart test/features/window/app_window_coordinator_test.dart` (in `app/`) -- expected: green.
- `cargo make test` (repo root, unpiped, synchronous, long timeout; PATH with `~/development/sdks/flutter/bin` and `~/development/sdks/cargo/bin`, `CARGO_HOME=~/development/sdks/cargo`, `RUSTUP_HOME` unset) -- expected: exit 0; coverage held or raised.
