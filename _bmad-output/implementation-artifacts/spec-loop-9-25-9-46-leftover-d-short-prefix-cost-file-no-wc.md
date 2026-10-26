---
title: 'Leftover run D after the story loop 9.25–9.46 — the short-prefixes cost of a change-id argument, the file reads'' missing working-copy refusal'
type: 'bugfix'
created: '2026-10-26'
status: 'done'
baseline_revision: '743394d2bd65c3d68f1a4a4e1ee63979c5daa0a4'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
warnings:
  - multiple-goals
deferred: []
---

<intent-contract>

## Intent

**Problem:** Two items leftover run C deferred (deferred-work.md "Surfaced in leftover run C after the story loop 9.25–9.46"; Ralph asked for both 2026-10-26): (1) since commit 0e180ac every change-id argument — incl. `Repo::get_change`, called per GUI selection — populates the effective `revsets.short-prefixes` (default `revsets.log`) id-prefix context; the per-call cost on a large repo is unmeasured. (2) The four file reads (`file_list` / `file_show` / `file_annotate` / `file_search`) report an omitted revision in a workspace without a working-copy commit as `FileError::InvalidInput` (`jj.invalid_input`), where the CLI raises `RevsetResolutionError::WorkspaceMissingWorkingCopy` — what the mutation verbs and commit views already map to `jj.revset_resolution_error`.

**Approach:** (1) a release-build bench in `crates/zanshin-jj/benches/` timing `Repo::get_change` with a full change id on `large-10k-commits`, loose and `git gc`-packed, at HEAD and at the pre-change baseline `16d1be55932d6e92de5c577f0605359f419b0f1d` (built in a `git worktree` in a temp dir, removed afterwards); record the numbers. Added cost > 5 ms per call on either store → skip populating the context for a full-length change id (`shortcut:` comment) and re-measure; ≤ 5 ms → no code change. (2) `file.rs::res` maps `ResolveError::NoWorkingCopy(reason)` to `FileError::RevsetResolutionError { reason, hints: vec![] }` (the CLI's `revset_resolution_error_hints` has no arm for it), with test, docs and an oracle scenario.

## Boundaries & Constraints

**Always:** CLI semantics at v0.46.0 (`WorkspaceMissingWorkingCopy`'s text is jj-lib's own `to_string()`, already carried by `ResolveError::NoWorkingCopy`); benches only in `benches/` (never inline in `src/`), printing timings and asserting nothing about wall-clock, registered in `crates/zanshin-jj/Cargo.toml` with `harness = false` and a WHY comment like the others; the baseline measured with the SAME bench source (the public `Repo::get_change` / `Repo::status` signatures are identical at both revisions); the worktree, its target dir and fixture copies live in a temp dir created for this run and are removed afterwards; `jj` only in temp dirs; docs naming the old `jj.invalid_input` for this case updated (Rust rustdoc, FFI rustdoc → `cargo make codegen` regenerates `zanshin_ffi.h` / `bindings.dart`, `docs/rust-error-codes.md`, `docs/ffi-abi.md` rows if they name it).

**Never:** no change to how a present change id resolves unless item 1's measurement crosses 5 ms; no new error code, FFI symbol or schema field; no change to `ResolveError` or the other families' mappings; no full gate (`cargo make test` / `test-full` / `coverage`).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| 1 measure | `get_change(<full id of @->)` on a warm handle, large-10k loose / packed, HEAD vs 16d1be5 | min/median per store and revision recorded in Verification | — |
| 1 shortcut (only if > 5 ms) | full-length (32-char) change id | same `Change` as through the context; no populate, so a broken `revsets.short-prefixes` no longer refuses a full id | shorter prefixes unchanged |
| 2 omitted revision, no `@` | default workspace's working-copy commit forgotten; `file_list(None, ..)`, `file_show(None, ..)`, `file_annotate(None, ..)`, `file_search(None, ..)` | refused | `FileError::RevsetResolutionError { reason: "Workspace `default` doesn't have a working-copy commit", hints: [] }` → `jj.revset_resolution_error` |
| 2 named revision, no `@` | same state, `file_list(Some(a), ..)` | `Ok` | — |
| 2 bad path | `paths` entry outside the repo | unchanged | `FileError::InvalidInput` |

</intent-contract>

## Code Map

- `crates/zanshin-jj/src/repo.rs:737-741` -- `Repo::get_change` (`with_verb(SHOW, ..)`, passes `ctx.template_startup.id_prefix_context()`); at 16d1be5 (`:730-734`) it passed no context. `Repo::status()` returns `Status.parent_change_id` / `working_copy_change_id` (full ids) — the bench's id source.
- `crates/zanshin-jj/src/op_support.rs:~630-700` -- `resolve_commit` / `resolve_change` (validate reverse hex → `prefixes.populate(repo)` → `resolve_change_prefix`); the only place a shortcut would go. `:812-845` `resolve_or_wc` builds `ResolveError::NoWorkingCopy(WorkspaceMissingWorkingCopy{..}.to_string())`.
- `crates/zanshin-jj/src/change.rs:~156-200` -- `get_change(workspace, prefixes, id)` (calls `resolve_change`).
- `crates/zanshin-jj/benches/revset_counts.rs` -- template: `ENV_GUARD` (pins `JJ_CONFIG`, `XDG_CONFIG_HOME` via `test_helpers::leaked_xdg_config_home()`), `measure(min/median)`, `extract_fixture(name)`, `git gc` on `.jj/repo/store/git` for the packed store. `test_helpers` at 16d1be5 has the same `extract_fixture` / `leaked_xdg_config_home`. `crates/zanshin-jj/Cargo.toml:50-74` -- `[[bench]]` entries.
- `crates/zanshin-jj/src/file.rs:254-262` -- `res`: the `NoWorkingCopy` arm (item 2). `repo.rs:~990-1001` -- `file_list`'s `# Errors` (the `InvalidInput` bullet names the missing-`@` case "for all four file reads"; move it to the `RevsetResolutionError` bullet).
- `crates/zanshin-ffi/src/file.rs:352,409,459,516` -- the four `zanshin_file_*` rustdoc bullets `jj.invalid_input — an absent revision's @ default …` → `jj.revset_resolution_error`; `map_file_err` already maps `RevsetResolutionError`. The FFI index rows in `docs/ffi-abi.md:629-632` already list both codes (still both emitted). `ffi_abi_doc_sync` checks rustdoc bullets vs index.
- `crates/zanshin-jj/tests/it/arg_refusals.rs:209-260` -- `an_omitted_revision_without_a_working_copy_commit_is_the_clis_user_error` pins `FileError::InvalidInput` for `file_list` → flip to `RevsetResolutionError` with `hints` empty and add the other three reads. `without_working_copy(fx)` stages the state.
- `crates/zanshin-parity/tests/oracle/scenarios.rs` + `main.rs` `parity!` list -- staging: `Step::Jj(&["workspace", "add", "../ws2"])`, `Step::JjAt("../ws2", &["workspace", "forget", "default"])`, then `repo.file_list(None, &[])` vs `args(&["file", "list"])` (the oracle compares refused + warning count + read-back, not the code). Template: `undo_cross_workspace` (~`:1283`, `init: &["git", "init", "--no-colocate"]`).
- `docs/rust-error-codes.md` -- grep the `jj.invalid_input` (`:66`) and `jj.revset_resolution_error` (`:57`) rows for the file reads' missing-working-copy case; move it.

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/benches/get_change.rs` (new) + `Cargo.toml` `[[bench]]` -- time `Repo::get_change(full id)` on one warm handle (WARMUP 2, ITERS 20, min/median), plus `Repo::status()` on the same handle as the per-call `with_verb` floor; stores large-10k loose and packed.
- run it at HEAD (`cargo bench -p zanshin-jj --bench get_change`) and in a temp-dir `git worktree add <tmp>/base 16d1be55932d6e92de5c577f0605359f419b0f1d` with the bench file and `[[bench]]` entry copied in (separate `CARGO_TARGET_DIR` inside the temp dir); `git worktree remove --force` + delete the temp dir afterwards; record all numbers in Verification and the Auto Run Result.
- only if added cost > 5 ms: `crates/zanshin-jj/src/op_support.rs` -- full-length id skips the populate (`shortcut:` comment), a test that a 32-char id resolves with a broken `revsets.short-prefixes`, re-measure.
- `crates/zanshin-jj/src/file.rs` -- `res`'s `NoWorkingCopy` → `RevsetResolutionError { reason, hints: vec![] }`; `repo.rs` file-read rustdoc; `crates/zanshin-ffi/src/file.rs` four rustdoc bullets; `cargo make codegen`; `docs/rust-error-codes.md`.
- `crates/zanshin-jj/tests/it/arg_refusals.rs` -- flip + extend to the four reads; keep the named-revision line.
- `crates/zanshin-parity/tests/oracle/scenarios.rs`, `main.rs` -- scenario `file_list_without_working_copy` (both refuse).

**Acceptance Criteria:**
- Given the bench at HEAD and at 16d1be5, when it runs in release on both stores, then both revisions' numbers are recorded and the added cost per `get_change` call is stated against the 5 ms threshold, with the resulting code decision.
- Given the matrix rows of item 2, when `cargo test -p zanshin-jj --test it arg_refusals::` and `file_reads::` run, then they pass; given the oracle, when `cargo test -p zanshin-parity --test oracle` runs, then the new scenario matches the CLI with no new ledger entry.
- Given the change, when `cargo clippy -p zanshin-jj -p zanshin-ffi -p zanshin-parity --all-targets -- -D warnings`, `cargo fmt --all --check`, `cargo test -p zanshin-ffi --lib` and `--test it` (incl. `ffi_abi_doc_sync`) run, then all pass.

## Spec Change Log

## Review Triage Log

### 2026-10-26 — Review pass
- verdicts: 19 findings — high 0, medium 2, low 13, false 4, maybe-false 0
- findings:
  - `[low]` `[reject]` (blind) the oracle scenario `file_list_without_working_copy` compares only refused + warning count, so it passes with either error class — oracle design (outcomes, not codes); the intent asked for a scenario "if the oracle can stage" the state, and the class is pinned by `arg_refusals.rs` / `workspace_ops.rs`.
  - `[low]` `[reject]` (blind) parity covers `file list` only, not show / annotate / search — the four reads share `head_commit` → `res`; three more refused-vs-refused scenarios add no signal the one does not; all four are pinned at the library level.
  - `[low]` `[reject]` (blind) the scenario sits in the `commit_*` block — deliberately beside `commit_without_working_copy`, whose `workspace forget` setup it shares; cosmetic.
  - `[low]` `[reject]` (blind) no FFI / Dart test of the wire code for a file read without `@` — `map_file_err`'s `RevsetResolutionError` arm is unchanged and already tested (`map_file_err_covers_every_variant`, code + hints); only the library mapping changed, and it is tested.
  - `[low]` `[reject]` (blind) "no working copy" now shares `jj.revset_resolution_error` with ambiguous/divergent ids and carries no structured `FfiError.revset` kind — the mapping is the intent's decision (CLI parity, Ralph 2026-10-23) and matches the mutation verbs and commit views, which carry no kind either.
  - `[low]` `[reject]` (blind) the bench copies `ENV_GUARD` / `measure` / the `git gc` packing instead of `pin_test_env()` — it mirrors the sibling bench `revset_counts.rs`, and the recorded numbers were taken with this exact source at both revisions; a bench is not run by the gate.
  - `[false]` `[reject]` (blind) `Repo::status()` is no floor, so get_change − status does not isolate the short-prefixes cost — the threshold is applied to get_change at HEAD minus get_change at 16d1be5 (same bench, both revisions), not to the status gap; status is only a reference row.
  - `[low]` `[reject]` (blind) the bench times only a full id inside `revsets.log`, not short/odd prefixes or ids outside the set — the intent names exactly "a full change id"; those paths were not asked for.
  - `[false]` `[reject]` (blind) the cost question has no recorded answer — the numbers and the decision are in this spec's Verification and Auto Run Result (the spec was excluded from the reviewed diff by design).
  - `[low]` `[reject]` (blind) the mutation verbs / interdiff in the same test ignore `hints` — their mapping is untouched by this change.
  - `[low]` `[reject]` (blind) two `jj.revset_resolution_error` bullets per wrapper — the house style since leftover run C is one bullet per cause (`ffi_abi_doc_sync` passes); cosmetic.
  - `[low]` `[patch]` (blind) the new `res` comment cites the CLI without a location — merged with the intent row below: comment rewritten with `cli/src/command_error.rs:971-976` @ v0.46.0.
  - `[medium]` `[patch]` (edge) `tests/it/workspace_ops.rs:96-100` `forget_the_current_workspace_then_at_defaults_refuse_with_the_clis_text` still asserted `FileError::InvalidInput` for `file_list(None, ..)` — the full `it` suite would go red; flipped to `RevsetResolutionError { reason == NO_WC, hints empty }`, `workspace_ops::` 17 ok.
  - `[false]` `[reject]` (verification-gap, other) `map_file_err_covers_every_variant` leaves out `RevsetResolutionError` — it covers it (`crates/zanshin-ffi/src/file.rs:614`, the divergent case with code and hints).
  - `[medium]` `[patch]` (intent) same stale `workspace_ops.rs` assertion — same patch as the edge row.
  - `[low]` `[reject]` (intent) the error-code surface is untested at FFI level — same as the blind wire-contract row.
  - `[low]` `[reject]` (intent) the oracle cannot tell the old and new class apart — same as the first blind row.
  - `[false]` `[reject]` (intent) item 1's HEAD-minus-baseline comparison is not in the diff — it is recorded in this spec (Verification table); the surface measured is `Repo::get_change`, as the intent names.
  - `[low]` `[patch]` (intent) the `res` comment claims the CLI's `revset_resolution_error_hints` "has no arm" for `WorkspaceMissingWorkingCopy` — it has one returning `vec![]` (`command_error.rs:971-976` @ v0.46.0); reworded to "gives it no hints" with that citation.
  - (layers: blind 12, edge 1, verification-gap 0 gaps + 1 other, intent 5.)

## Verification

**Commands:**
- `cargo bench -p zanshin-jj --bench get_change` (HEAD and baseline worktree) -- numbers recorded
- `cargo test -p zanshin-jj --lib`, `cargo test -p zanshin-jj --test it arg_refusals::`, `--test it file_reads::` -- pass
- `cargo test -p zanshin-ffi --lib`, `cargo test -p zanshin-ffi --test it` -- pass
- `cargo test -p zanshin-parity --test oracle` -- pass
- `cargo clippy -p zanshin-jj -p zanshin-ffi -p zanshin-parity --all-targets -- -D warnings`, `cargo fmt --all --check` -- clean
- `cargo make codegen` -- commit the regenerated `zanshin_ffi.h` / `bindings.dart`
- `packages/zanshin_core`: `dart analyze`, `dart format --set-exit-if-changed .` -- clean (only generated doc comments change)

**Results (2026-10-26):**

Item 1 — `cargo bench -p zanshin-jj --bench get_change` (release, `large-10k-commits`, one warm handle, WARMUP 2 / ITERS 20, min / median), two runs per revision; the baseline ran in a temp-dir `git worktree` at `16d1be5` with the same bench file and `[[bench]]` entry and its own `CARGO_TARGET_DIR` (worktree removed, `git worktree prune`d, temp dir deleted):

| store | call | HEAD run 1 | HEAD run 2 | 16d1be5 run 1 | 16d1be5 run 2 |
|---|---|---|---|---|---|
| loose | `status` (floor) | 3.75 / 4.16 ms | 3.51 / 4.03 ms | 4.27 / 6.00 ms | 3.74 / 4.63 ms |
| loose | `get_change(@-)` | 5.19 / 5.65 ms | 4.54 / 4.92 ms | 3.51 / 3.94 ms | 3.96 / 5.02 ms |
| packed | `status` (floor) | 2.96 / 3.14 ms | 2.98 / 3.32 ms | 3.02 / 3.26 ms | 2.79 / 2.95 ms |
| packed | `get_change(@-)` | 4.50 / 4.63 ms | 4.69 / 4.85 ms | 3.03 / 3.25 ms | 3.11 / 3.24 ms |

Added cost of populating the `revsets.short-prefixes` context per `get_change` call: packed ≈ +1.5 ms (min +1.47 / +1.58, median +1.38 / +1.61); loose +0.6 to +1.7 ms (the loose medians are noisy, ±1 ms run to run). At the baseline `get_change` costs about the `with_verb` floor; at HEAD the floor plus ~1.5 ms. Well below the 5 ms threshold → **no code change** to change-id resolution (no `shortcut:`); the bench stays as `crates/zanshin-jj/benches/get_change.rs`.

Item 2 — `file.rs::res` maps `ResolveError::NoWorkingCopy` to `FileError::RevsetResolutionError { reason, hints: [] }` (inline unit test `res_preserves_the_not_found_and_backend_split` extended); `arg_refusals.rs` now pins all four reads; oracle scenario `file_list_without_working_copy` (setup `jj workspace forget`, as `commit_without_working_copy`) added, `every_scenario_has_a_test`'s count 473 → 474.

Checks run:
- `cargo bench -p zanshin-jj --bench get_change` at HEAD and in the baseline worktree -- numbers above
- `cargo test -p zanshin-jj --lib` -- 415 passed
- `cargo test -p zanshin-jj --test it arg_refusals::` -- 4 passed; `--test it file_reads::` -- 31 passed
- `cargo test -p zanshin-ffi --lib` -- 232 passed; `cargo test -p zanshin-ffi --test it` (incl. `ffi_abi_doc_sync`) -- 397 passed
- `cargo test -p zanshin-parity --test oracle` -- first run 497 passed, 1 failed (`every_scenario_has_a_test`: the hard-coded scenario count); after bumping it to 474, `every_scenario_has_a_test` passes; `file_list_without_working_copy` matched the CLI with no ledger entry
- `cargo make codegen` -- regenerated `zanshin_ffi.h` / `bindings.dart` (the four `zanshin_file_*` doc bullets only)
- `cargo clippy -p zanshin-jj -p zanshin-ffi -p zanshin-parity --all-targets -- -D warnings` -- clean; `cargo fmt --all --check` -- clean (after `cargo fmt --all` collapsed the new match arm)
- `packages/zanshin_core`: `dart analyze` -- no issues; `dart format --set-exit-if-changed .` -- 0 changed

**Parent verification (step-03 / step-04, same day):** `zanshin-jj --test it arg_refusals::` 4 ok; oracle `file_list_without_working_copy` + `every_scenario_has_a_test` 2 ok; `zanshin-ffi --test it ffi_abi_doc_sync` 17 ok; clippy (three crates, `--all-targets -D warnings`) and `cargo fmt --all --check` clean. The review found the stale `workspace_ops.rs` assertion the first runs missed (they ran two modules only); after the patch: `zanshin-jj --test it workspace_ops::` 17 ok, `--lib file::` 10 ok, `--lib` 415 ok, the FULL `zanshin-jj --test it` 1469 ok / 5 FAILED — all five in `clone_cancel::` / `network_cancel::` (process-kill timing; an earlier run of the suite was still running alongside, 959 s wall time) — and re-run alone `clone_cancel:: network_cancel::` 14 ok; clippy `-p zanshin-jj --all-targets -D warnings` and `cargo fmt --all --check` clean. No `cargo make test` / `test-full` / `coverage` (gate rule of this run).

## Auto Run Result

Status: done

**Items (each verified against the code first; code commit c2318ca4dc68cdb9cc797bc48f4f033254275bf0, none rejected):**
1. Short-prefixes cost of a change-id argument — MEASURED, no code change. Confirmed first: `Repo::get_change` passes `ctx.template_startup.id_prefix_context()` and `op_support::resolve_change` populates it per call; at 16d1be5 it did a bare lookup. `Repo::get_change` with the full change id of `@-` on `large-10k-commits`, release, one warm handle, 20 iterations, two runs per revision: packed 3.03-3.11 ms min (16d1be5) → 4.50-4.69 ms min (HEAD), +1.5 ms; loose +0.6 to +1.7 ms (noisy medians). Below the 5 ms threshold on both stores, so no `shortcut:`; the bench stays as `crates/zanshin-jj/benches/get_change.rs` (baseline built in a temp-dir `git worktree` with its own target dir, removed and pruned).
2. File reads without a working-copy commit — FIXED (c2318ca4dc68cdb9cc797bc48f4f033254275bf0). Confirmed first: `file.rs::res` mapped `ResolveError::NoWorkingCopy` to `FileError::InvalidInput`. Now `FileError::RevsetResolutionError { reason, hints: [] }` — reason jj-lib's ``Workspace `<name>` doesn't have a working-copy commit``, no hints as the CLI's `revset_resolution_error_hints` (`cli/src/command_error.rs:971-976` @ v0.46.0) — so all four `zanshin_file_*` reads answer `jj.revset_resolution_error`. Oracle: `file_list_without_working_copy` (setup `jj workspace forget`; both refuse).

**Files changed:** `crates/zanshin-jj/benches/get_change.rs` (new bench) + `Cargo.toml` (`[[bench]]`); `crates/zanshin-jj/src/file.rs` (`res` arm, variant doc, inline test); `crates/zanshin-jj/src/repo.rs` (`file_list` `# Errors`); `crates/zanshin-ffi/src/file.rs` (four rustdoc bullets) + codegen `include/zanshin_ffi.h`, `packages/zanshin_core/lib/src/ffi/bindings.dart`; `crates/zanshin-jj/tests/it/{arg_refusals,workspace_ops}.rs` (flipped to the new variant, all four reads); `crates/zanshin-parity/tests/oracle/{scenarios,main}.rs` (new scenario, count 474); `docs/rust-error-codes.md` (`jj.revset_resolution_error` row). Ledger commit: this spec, `deferred-work.md` (both leftover-run-C bullets resolved), leftover run C's spec (`resolved:` lines).

**Review:** one pass, 19 findings (medium 2, low 13, false 4). Patched: the stale `workspace_ops.rs` assertion (medium, edge + intent rows); the `res` comment's wrong CLI claim + missing citation (low, blind + intent rows). Deferred: none (no new findings for deferred-work.md). Rejected with reasons in the triage log: the oracle compares outcomes not codes (twice), parity for the other three reads, the scenario's position, no FFI wire test (the arm is unchanged and tested), the shared code without an `FfiError.revset` kind (intent-mandated, as the other families), the bench's copied helpers, the bench's single id path (intent names a full id), the mutation verbs' unchecked hints, two bullets per code; false: `status` as the delta floor, the unrecorded answer, `map_file_err_covers_every_variant` missing the variant, the delta missing from the diff. Follow-up review: false (patched: 0 high, 1 medium entry, 1 low entry).

**Residual risks:** coverage not measured (the new `res` arm is hit by the inline unit test and `arg_refusals` / `workspace_ops`); the full `it` suite had 5 failures in `clone_cancel::` / `network_cancel::` while a second suite run was still active — they pass alone, but the loop's final gate should confirm; the bench numbers are from one machine, two runs each.
