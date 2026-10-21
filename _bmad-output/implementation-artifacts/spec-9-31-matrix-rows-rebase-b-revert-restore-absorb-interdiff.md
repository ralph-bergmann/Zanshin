---
title: 'Story 9.31 follow-on — the dropped matrix rows: rebase -b, revert, restore, absorb, interdiff'
type: 'feature'
created: '2026-10-21'
status: 'done'
baseline_revision: '4e40594e5f896bce2d3ba397ef58857447701391'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-9-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/spec-9-31-drop-actions-capability-query.md'
warnings: [oversized]
deferred:
  - summary: >-
      A location's immutable set is resolved before its ids and whether or not it has children, so -A/-B plans refuse jj.config_error where the CLI would not.
    evidence: |-
      plan_revert / plan_rebase_branch (and the shipped plan_duplicate / plan_new) call resolve_immutable before resolve_commit_location; the CLI's compute_commit_location resolves the ids first and checks rewritability only for non-empty children, so an unresolvable immutable_heads() alias with -A on a leaf, or with an unknown location id, reads jj.config_error.
    location: >-
      crates/zanshin-jj/src/revert.rs plan_revert; crates/zanshin-jj/src/rebase.rs plan_rebase_branch
    severity: low
    resolved: >-
      2026-10-21 — rejected (spec-9-31-matrix-rows-closing-location-ids-before-immutable): the CLI refuses too, in tx.finish; the reorder failed the parity oracle and was reverted.
---

<intent-contract>

## Intent

**Problem:** Story 9.31 shipped `Repo::drop_actions` with the 2026-10-14 design's rows only; the original matrix rows `rebase -b`, `revert`, `restore`, `absorb` and `interdiff` were dropped (deferred-work I1, "Surfaced in Story 9.31"). Ralph decided 2026-10-21 to build them so the query is complete, although no UI consumes them yet.

**Approach:** Five new `DropVerb` rows for a `Change` source, each answered by the verb's own pure plan fn, called by the verb and by the query — the 9.31 contract. `restore`, `absorb` and `interdiff` are shipped: their guards are extracted into plan fns the verbs call, byte-identical behaviour. `rebase -b` gets `plan_rebase_branch` in `rebase.rs`; `revert` (Story 9.18, no verb yet) gets `plan_revert` ported from `cmd_revert`'s plan phase @ v0.46.0. Rust → schema (append) → FFI → Dart → docs, as 9.31 did.

## Boundaries & Constraints

**Always:**
- `DropVerb` gains, APPENDED in this order: `RebaseBranch` (`rebase -b S -o T…`), `Revert` (`revert -r S <location>`), `Restore` (`restore --from S --into T`), `Absorb` (`absorb --from S --into T`), `Interdiff` (`interdiff --from S --to T`). Rust enum, `.fbs` enum, FFI mapping and Dart enum all append; no existing value moves.
- Rows per location for a `Change` source (the shipped rows first, unchanged, then the new ones):
  - at `onto`: `RebaseSource`, `RebaseRevisions`, `Squash`¹, `NewMerge`, `Duplicate`, **`RebaseBranch`, `Revert`, `Restore`¹, `Absorb`¹, `Interdiff`¹** (¹ only when `onto` has exactly one id);
  - at `-A`/`-B` (either or both): `RebaseRevisions`, **`Revert`**.
  - `Selection` and `Bookmark` sources gain no rows. `change_actions` is unchanged. `rebase -s`/`-b` at `-A`/`-B` stays out (Story 9.16's deferred corner).
- Statuses (Available | NoOp | Refused with the verb's own `MutateError`, same variant and text):
  - `RebaseBranch`: `plan_rebase_branch` (`rebase.rs:514-561` @ v0.46.0): branch resolved in order → location (`"rebased commits"`) → `roots(new_parents..branch)` checked rewritable → with `-o`, `check_rebase_destinations` per root. NoOp when the roots are empty (the CLI's "No revisions to rebase.", `cmd_rebase:395-399`) or the dry-run move changes nothing (`rebase_is_no_op`, which takes over the empty-target answer for every rebase form).
  - `Revert`: `plan_revert` (`revert.rs` @ v0.46.0): revisions evaluated in reverse topological order; none → `None` (the CLI's "No revisions to revert.", reported NoOp; a one-change source never reaches it); then the location (`"reverted commits"`, immutable set resolved only for `-A`/`-B`, as `plan_duplicate`), then `refuse_git_root_merge` on the location's parents (the Git backend refuses the reverted commit's write, as for duplicate). The `templates.revert_description` parse stays in 9.18's transaction phase.
  - `Restore`: `plan_restore` = today's `restore` from its `into`/`from` resolution through the same-tree check (resolve `into` then `from` → `guard_rewritable(into)` → matcher → `SelectedTree` → `warn_unmatched`); same tree → NoOp. Root `T` refuses `jj.immutable` (no root guard, as today).
  - `Absorb`: `plan_absorb` = today's `absorb` from source resolution through `guard_rewritable` over the split's targets; no target → NoOp (exact: `absorb_hunks` rewrites every target, so a non-empty target set always changes the repo). The row's destinations are `T`'s commit, `T` resolved like every location id.
  - `Interdiff`: `plan_interdiff` = the verb's two `resolve_side` calls. Never NoOp; Available for any resolvable S, T (root, immutable, S == T included — the CLI refuses none); an unresolvable id refuses `ChangeNotFound`, carried as the `MutateError` variant with the same id (the FFI maps both to `jj.change_not_found` with the id as context).
- The verbs `Repo::restore`, `Repo::absorb`, `Repo::interdiff` keep their observable behaviour byte-identical: same refusals in the same order, same warnings, same no-op results, same op descriptions. Their clap-level checks (`changes_in` with `from`/`into`; interdiff's both-absent and path checks) stay where they are, before the repo load.
- Plan fns run on the row's own dropped transaction from the call's ONE dry-run head, like 9.31's; row warnings are discarded.

**Never:** a new error code; a new verb or the revert/rebase transaction phase; UI code; MCP; rows for `Selection`/`Bookmark` sources; `rebase -s`/`-b` at `-A`/`-B`; changing a shipped row's answer or order; `cargo make test`/`test-full`/`coverage` (run gate rule).

## I/O & Edge-Case Matrix

Fixture: 9.31's `base()` — Git-backed, `root → A (a.txt) → B (b.txt, f) → C (c.txt)`, `D (d.txt)` a second child of `A` (`@`); `immutable_heads()` per test. New rows only (shipped rows unchanged). "imm(x)" = `Immutable{x}`.

| Scenario | Input | RebaseBranch | Revert | Restore | Absorb | Interdiff |
|---|---|---|---|---|---|---|
| Onto parent | B onto [A] | NoOp | Available | Available | NoOp (B only adds files) | Available |
| Leaf onto parent | D onto [A] | NoOp | Available | Available | NoOp | Available |
| Onto descendant | B onto [C] | NoOp (C..B empty) | Available | Available | NoOp | Available |
| Onto itself | B onto [B] | NoOp | Available | NoOp (same tree) | NoOp | Available |
| Onto root | B onto [root] | NoOp (A already on root) | Available | imm(root) | NoOp | Available |
| Immutable source | A ∈ imm, A onto [D] | NoOp (D..A empty) | Available | Available | NoOp | Available |
| Root source | root onto [A] | NoOp | Available | Available | NoOp | Available |
| Root + other | B onto [root, D] | Refused Git root-merge text | Refused Git root-merge text | — | — | — |
| Two targets | C onto [B, D] | Available (C gains D as a parent) | Available | — | — | — |
| Unrelated | C onto [D] | Available (B moves onto D) | Available | Available | NoOp | Available |
| Immutable branch root | A ∈ imm, C onto [root] | imm(A) (roots(root..C) = A) | Available | imm(root) | NoOp | Available |
| Insert locations | C at -A [A] / -B [B] / both | — | Available each | — | — | — |
| Insert refusals | B ∈ imm: C at -A [A]; loop -A [B] -B [A] | — | imm(B); loop text "… of the reverted commits" | — | — | — |
| Absorbable hunk | E = child of C rewriting b.txt's line; E onto [B] / [A]; again with B ∈ imm onto [B] | — | — | — | Available / NoOp; imm(B) | — |
| Unknown | S = unknown onto [A]; C at -A [unknown] | not_found | not_found (both) | not_found | not_found | not_found |
| Agreement | restore / absorb / interdiff rows above | — | — | verb answers as the row | verb answers as the row | Available ⇒ Ok; Refused ⇒ Err same id |

</intent-contract>

## Code Map

- `crates/zanshin-jj/src/drop_actions.rs` — `DropVerb` (:67, append), `ActionStatus::NoOp` doc (:90), `Rows::rebase` (:226, takes a `-s`/`-r` bool → make it take the form), `location_rows` (:275, add rows), `outcome` (:169). Module doc lists the plan fns.
- `crates/zanshin-jj/src/rebase.rs` — `plan_rebase_source` (:84, template), `check_rebase_destinations` (:114), `rebase_is_no_op` (:155: add the empty-target answer before `compute_move_commits`). Module doc: `-b` joins.
- `crates/zanshin-jj/src/duplicate.rs` — `plan_duplicate`, the template for `plan_revert` (`resolve_ordered` + reverse-topo evaluate, immutable only for inserts, `refuse_git_root_merge`, `#[allow(dead_code)]` + WHY on the plan struct).
- `crates/zanshin-jj/src/mutate.rs` — `restore` (:1573-1649) and `absorb` (:1689-1782) to split into `plan_restore`/`plan_absorb` + the verb; `guard_rewritable` (:533), `refuse_git_root_merge` (:971), `warn_unmatched` (:493), `no_op_result` (:1289), `rev` (:447).
- `crates/zanshin-jj/src/commit_views.rs` — `interdiff` (:525), `resolve_side` (:278), `CommitViewError` (:163).
- `crates/zanshin-jj/src/op_support.rs` — `resolve_commit_location` (:171), `resolve_immutable` (:85), `check_rewritable` (:110), `resolve_ordered` (:638), `resolve_commit` (:609), `LocationArgs` (:147).
- `crates/zanshin-jj/src/revset.rs:482` — `resolve_expression` (absorb destinations).
- `crates/zanshin-jj/src/lib.rs` — module list (add `revert`).
- CLI @ v0.46.0 (`git -C ../jj show v0.46.0:<path>`): `cli/src/commands/rebase.rs:369-599` (`cmd_rebase`, `plan_rebase_branch`), `cli/src/commands/revert.rs` (`cmd_revert` up to its transaction), `cli/src/commands/interdiff.rs` (no S ≠ T refusal). jj-lib 0.46.0 `absorb.rs:108-190` (`split_hunks_to_trees`: new files have no destination), `:308` (`absorb_hunks`).
- Tests: `crates/zanshin-jj/tests/it/drop_actions.rs` (fixture `base`, `query`, `agree`, `the_row`; existing exact row lists at :253-576 gain the new rows); `api_stability.rs:1158-1210` (DropVerb list); `content_ops.rs` / `commit_views*.rs` stay green (the verbs' own tests).
- Schema: `schemas/envelope.fbs:1326-1333` (`DropVerb` doc + append; `ActionStatus` doc).
- FFI: `crates/zanshin-ffi/src/envelope.rs:866-872` (mapping) and `:1614-1620` (its unit test); `crates/zanshin-ffi/src/drop_actions.rs:101` (rows doc); `crates/zanshin-ffi/tests/it/drop_actions_ffi.rs` (row assertions).
- Codegen (committed): `crates/zanshin-ffi/src/envelope_generated.rs`, `packages/zanshin_core/lib/src/ffi/envelope_zanshin.ffi_generated.dart` (+ header/bindings if they change).
- Dart: `packages/zanshin_core/lib/src/ffi/drop_actions.dart:148-170` (enum + docs), `:363-370` (`_verb` switch); `test/ffi/drop_actions_test.dart:50` (verb pairs), `test/worker/drop_actions_test.dart:93-134` (row lists).
- Docs: `docs/ffi-abi.md:1598-1605` (rows per location + NoOp sentence).
- Ledger: `_bmad-output/implementation-artifacts/sprint-status.yaml` (9-31 :221, 9-18 :206, 9-16), `deferred-work.md:1701` (I1 line).

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/src/rebase.rs` -- add `plan_rebase_branch`; `rebase_is_no_op` answers `true` for an empty target before computing -- the `-b` plan fn for 9.16 and the CLI's "No revisions to rebase.".
- `crates/zanshin-jj/src/revert.rs` (new, + `lib.rs`) -- `plan_revert(tx, immutable, revisions, location) -> Result<Option<RevertPlan>, MutateError>` with inline tests if a branch is not reachable from the integration tests -- for 9.18.
- `crates/zanshin-jj/src/mutate.rs` -- extract `plan_restore` (-> `RestorePlan { to_commit, restored: Option<SelectedTree> }`, `None` = same tree) and `plan_absorb` (-> `AbsorbPlan { source, target_commits, skipped_paths }`); `restore`/`absorb` call them -- shared preconditions, behaviour unchanged.
- `crates/zanshin-jj/src/commit_views.rs` -- extract `plan_interdiff(repo, workspace_name, from, to) -> Result<(Commit, Commit), CommitViewError>`; `interdiff` calls it.
- `crates/zanshin-jj/src/drop_actions.rs` -- the five variants, the rows per the Always rules, a `CommitViewError → MutateError` mapping for the interdiff row (variant for variant, unit-tested inline), docs.
- `crates/zanshin-jj/tests/it/drop_actions.rs` -- extend the existing row lists with the new rows; new tests for the matrix rows above (unrelated, immutable branch root, absorbable hunk, insert refusals, unknown); agreement tests `restore_rows_agree_with_restore`, `absorb_rows_agree_with_absorb`, `interdiff_rows_agree_with_interdiff`; `api_stability.rs` lists the new variants.
- `schemas/envelope.fbs` then `cargo make codegen` -- append the five `DropVerb` values, update the doc comments; commit the generated files.
- `crates/zanshin-ffi/src/envelope.rs`, `drop_actions.rs`, `tests/it/drop_actions_ffi.rs` -- mapping + its unit test, doc, row assertions (one FFI round trip that returns every new verb).
- `packages/zanshin_core` -- `DropVerb` values + `_verb` cases + docs; decode test pairs; worker test row lists.
- `docs/ffi-abi.md` -- the rows-per-location paragraph and the NoOp sentence.
- `_bmad-output/implementation-artifacts/sprint-status.yaml`, `deferred-work.md` -- 9-31 dated DONE note; 9-18 note (`revert::plan_revert` is meant to be called by the verb); 9-16 note (`plan_rebase_branch`); I1 marked RESOLVED with the commit; this run's deferrals mirrored.

**Acceptance Criteria:**
- Given a `Change` source at an `onto` location with one target, when `Repo::drop_actions` returns, then its rows are the five shipped rows followed by `RebaseBranch`, `Revert`, `Restore`, `Absorb`, `Interdiff`, and the head operation is unchanged.
- Given any `Restore`/`Absorb`/`Interdiff` row of the matrix, when the verb runs right after the query with the same arguments, then Available ⇒ Ok (a new operation, except interdiff, which reads), NoOp ⇒ Ok with the head unchanged, Refused ⇒ the same error.
- Given `RepoHandle.dropActions` in Dart against the real cdylib, when a change is dropped onto one target, then the decoded rows include the five new verbs with the statuses the Rust query produced.
- Given the parity oracle, when it runs, then every scenario passes (restore/absorb refactored).

## Spec Change Log

## Review Triage Log

### 2026-10-21 — Review pass
- verdicts: 29 findings — high 0, medium 0, low 23, false 6, maybe-false 0
- findings:
  - `[low]` `[patch]` (blind) `ActionStatus::Available` says "would run and write an operation", false for the read-only `Interdiff` row — patched: Rust, `.fbs` and Dart docs now say "would run — writing an operation, except `Interdiff`, which only reads" (codegen rerun).
  - `[low]` `[patch]` (blind) `plan_rebase_branch` drops the CLI's `-b` default `@` (empty branch → empty target) — verified (CLI `plan_rebase_branch` resolves `@` when empty); the row always passes one change. Patched: the doc and the 9-16 sprint-status note say the caller resolves `@` and passes it.
  - `[low]` `[patch]` (blind) `plan_rebase_branch`'s `-A`/`-B` arm is reached by no test (coverage ratchet risk on `rebase.rs`) — verified (drop rows use `-b` at `onto` only). Patched: inline test `plan_rebase_branch_with_an_insert_location_checks_the_children` (Ok parents/children/roots, and the immutable-child refusal).
  - `[low]` `[reject]` (blind) the immutable set is resolved twice on `-b`'s insert path — a revset resolution per hover on a path no row reaches today; the fix adds a branch (`check_rewritable` vs `guard_rewritable`).
  - `[low]` `[reject]` (blind) sprint-status 9-16 / 9-18 keep their older clauses before the new dated note — the ledger's convention appends dated notes and keeps earlier text (9.31's follow-up review rejected the same).
  - `[low]` `[patch]` (blind) the RESOLVED I1 entry carries no commit hash — patched at finalize: deferred-work and sprint-status name commit ad64376.
  - `[low]` `[reject]` (blind) the `RebaseBranch` / `Revert` expectations have no parity-oracle check — an oracle scenario needs an executing Zanshin verb (9.16 / 9.18 add theirs); the texts and order were checked against `git -C ../jj show v0.46.0:cli/src/commands/{rebase,revert}.rs` (9.31's logged reject, same reason).
  - `[low]` `[reject]` (blind) the absorb row cannot tell "nothing absorbable" from "every hunk skipped" — both are the verb's no-op (no operation), so the status agrees; a reason field is new public surface no consumer asked for; the verb's own tests cover skipped paths.
  - `[low]` `[reject]` (blind) the hover now plans ten rows per one-target location, absorb annotating through history — no UI consumes these rows yet, so no user meets the cost today; recorded in the existing deferred-work hover-cost/store-writes entry for Story 10.10's measurement.
  - `[low]` `[patch]` (blind) `RevertPlan`'s WHY says drop_actions "needs just the refusal" though it also reads `is_none()` — patched: the comment says the FIELDS are unused until 9.18.
  - `[low]` `[patch]` (blind) the docs list revert's "No revisions to revert." as a NoOp source no drop row can produce — patched: Rust, `.fbs`, Dart and ffi-abi mark it unreachable through `drop_actions`.
  - `[low]` `[patch]` (blind) the `Restore` docs do not say the row restores with no paths (T's whole tree becomes S's) — patched in Rust, `.fbs`, Dart and ffi-abi.
  - `[low]` `[patch]` (blind) agreement misses an unknown restore TARGET, and the FFI an unknown interdiff target — patched the first: `restore_rows_agree_with_restore` gains B into an unknown change (both `ChangeNotFound`); the FFI target case rejected: the same `view_err` / `map_mutate_err` path the source case pins.
  - `[low]` `[reject]` (blind) with a broken `templates.revert_description` AND a root merge the row says `jj.invalid_input` where the CLI says the config error — needs two faults at once; the template parse is 9.18's transaction phase and the verb's refusal stays authoritative (deferred template-fault class).
  - `[low]` `[patch]` (edge) empty `-b` branch vs the CLI's `@` default — same root cause and patch as the blind row above.
  - `[low]` `[defer]` (edge) `plan_revert` resolves the immutable set for `-A`/`-B` before the ids and regardless of children: an unresolvable alias with `-A` on a leaf refuses `jj.config_error` where the CLI reverts — verified; the same order is shipped in `plan_duplicate` / `plan_new` (pre-existing pattern). Deferred (spec frontmatter + deferred-work).
  - `[low]` `[defer]` (edge) `plan_rebase_branch` with `-A`/`-B`, an unknown location id and an unresolvable alias reports `jj.config_error` before the unknown revision — same root cause as the row above; deferred with it.
  - `[low]` `[patch]` (edge) the RESOLVED ledger note lacks the commit — same as the blind row; patched at finalize.
  - `[low]` `[patch]` (verification-gap, other) `plan_rebase_branch`'s `inserts()` arm is unreachable from tests — same as the blind coverage row; patched with the inline test.
  - `[false]` `[reject]` (intent) `rebase -b` onto a descendant is NoOp, not the matrix's "T not a descendant" refusal — the CLI prints "No revisions to rebase." before any destination check, and the intent names "`rebase -b` empty branch" as NoOp; this is that case.
  - `[false]` `[reject]` (intent) `interdiff` S == T is Available, not refused — the intent says "the verb's own refusal"; neither the verb nor `cmd_interdiff` @ v0.46.0 refuses it.
  - `[false]` `[reject]` (intent) absorb onto an immutable non-target T is NoOp — the verb (and `absorb.rs:160-162`) guards only the split's targets; the row is the verb's plan, as the intent's contract demands.
  - `[low]` `[patch]` (intent) revert's NoOp sits outside the intent's three named NoOps — unreachable through a drop row; same patch as the blind unreachable-NoOp row (docs mark it unreachable).
  - `[false]` `[reject]` (intent) revert's up-front root-merge refusal goes beyond "location checks only" — the CLI refuses the same location at the reverted commit's write; refusing up front keeps preview and execution in agreement (9.31's `plan_duplicate` precedent).
  - `[false]` `[reject]` (intent) no restore/absorb/interdiff rows for a multi-target `onto` — the original matrix defines them as `--into T` / `--to T` with one T, and restore/interdiff take one revision.
  - `[low]` `[reject]` (intent) absorb agreement does not exercise an unknown target, where row and verb codes differ — the asymmetry is documented (Design Notes, ffi-abi); a test would pin a disagreement, not agreement.
  - `[false]` `[reject]` (intent) "byte-identical" rests on no before/after comparison — the verbs' own suites (`content_ops`, `commit_views`) and the parity oracle (191 passed) run unchanged against the refactored verbs.
  - `[low]` `[reject]` (intent) no cells for a non-parent ancestor / non-descendant child for the new rows — no plan branches on those relations beyond the covered ones (9.31's sampled-matrix reject).
  - `[low]` `[patch]` (intent) the I1 outcome and commit hash are not visible yet — written at finalize (Auto Run Result, ledger with commit ad64376).

## Design Notes

- **Row placement.** New rows are appended after the shipped ones per location, so no shipped row's position moves (10.10 reads the first available row as the default; its rows keep their order).
- **Absorb's `T`.** The absorb verb takes `--into` as a revset string; a drop location carries ids. The row resolves `T` with `resolve_commit` like every location id (9.31's "an id that does not resolve refuses `ChangeNotFound`") and passes its commit as the destination set. For a resolvable `T` the verb with `T`'s change id as its revset answers identically; an unresolvable `T` reads `jj.change_not_found` in the row where the verb says `jj.revset_resolution_error` — both refuse.
- **Interdiff's refusal type.** The verb returns `CommitViewError`; the row carries a `MutateError`. The only reachable row refusal is `ChangeNotFound`, mapped to the same-named variant with the same id; the FFI maps both to `jj.change_not_found` with the id as context, so the wire agrees.
- **Revert's root merge.** `cmd_revert` writes its first commit on the location's parents, so `-o root -o X` fails at the Git backend's write; the row refuses it up front with the backend text, exactly as 9.31 did for `plan_duplicate`.
- The store writes of a dry run (rebase's commits, restore's merged tree, absorb's split blobs) stay as 9.31 deferred them.

## Verification

**Commands:**
- `cargo test -p zanshin-jj --test it drop_actions::` / `content_ops::` / `api_stability::` (+ the interdiff module) and `cargo test -p zanshin-jj --lib` -- expected: pass
- `cargo test -p zanshin-ffi` -- expected: pass
- `cargo clippy -p zanshin-jj -p zanshin-ffi --all-targets -- -D warnings`, `cargo fmt --all --check` -- expected: clean
- `cargo make codegen` -- expected: generated files committed, a second run changes nothing
- `cargo test -p zanshin-parity --test oracle` -- expected: pass
- `packages/zanshin_core`: `cargo make --allow-private test-core`, `test-core-analyze`, `test-core-format` (or `dart test` / `dart analyze` / `dart format --set-exit-if-changed .`) -- expected: pass/clean

**Verification notes (run gate rule: targeted checks only — no `cargo make test` / `test-full` / `coverage`), all on the final tree after the review patches:**
- `cargo test -p zanshin-jj --lib` — 295 passed.
- `cargo test -p zanshin-jj --test it` — 993 passed, 1 ignored (the pre-existing `revset.rs` 10k benchmark).
- `cargo test -p zanshin-ffi` — 192 unit + 306 `it` passed.
- `cargo test -p zanshin-parity --test oracle` — 191 passed (restore/absorb/interdiff refactored).
- `cargo clippy -p zanshin-jj -p zanshin-ffi --all-targets -- -D warnings` — clean; `cargo fmt --all --check` — exit 0.
- `cargo make codegen` — run after the last `.fbs` edit; a second run changed nothing.
- `packages/zanshin_core`: `cargo make --allow-private test-core` — 926 passed (real cdylib); `test-core-analyze` — no issues; `test-core-format` — 0 changed. No `app/` code references `DropVerb`.
- Matrix audit: every I/O-matrix row has a passing test in `crates/zanshin-jj/tests/it/drop_actions.rs` (the shipped scenarios' row lists extended; new: `a_change_dropped_onto_an_unrelated_change`, `a_branch_whose_root_is_immutable_refuses_rebase_b`, `an_absorbable_hunk_absorbs_into_the_commit_that_last_changed_it`, the revert insert/loop/unknown cells, and the agreement tests `restore_rows_agree_with_restore` / `absorb_rows_agree_with_absorb` / `interdiff_rows_agree_with_interdiff`).
- Coverage not measured (run rule): `revert.rs` is a new file (inline test for its `None` branch); `rebase.rs`'s `-A`/`-B` arm has an inline test.

## Auto Run Result

Status: done
Blocking condition: none

**Summary.** `Repo::drop_actions` now answers the five matrix rows the 2026-10-14 design update had dropped, for a `Change` source. Each comes from the verb's own plan fn:
- `RebaseBranch` (`rebase -b S -o T…`): `rebase::plan_rebase_branch`, ported from the CLI @ v0.46.0; `rebase_is_no_op` answers an empty target as the CLI's "No revisions to rebase.".
- `Revert` (`revert -r S`, at `onto` and `-A`/`-B`): `revert::plan_revert` (new), ported from `cmd_revert` up to its template parse, with the Git root-merge refusal up front.
- `Restore` / `Absorb` / `Interdiff` (one `onto` target): `mutate::plan_restore`, `mutate::plan_absorb`, `commit_views::plan_interdiff`, extracted from the shipped verbs, which now call them.
- The rows are appended after the shipped ones, so no shipped row moves. Schema (append-only `DropVerb`), FFI, Dart and `docs/ffi-abi.md` follow.

Code commit: `ad64376647b7bf96eb2bbbb1c3ad9874ae6d8988`.

**Deferred-work items:**
- **I1 — fixed** (`ad64376647b7bf96eb2bbbb1c3ad9874ae6d8988`). All five rows are built. `plan_rebase_branch` (for Story 9.16) and `plan_revert` (for Story 9.18) are meant to be called by those verbs, as their sprint-status notes say; the three shipped verbs already call their plan fns, with preview ⇔ execution agreement tests.

**Files changed:**
- `crates/zanshin-jj/src/rebase.rs` — `plan_rebase_branch`, the empty-target answer in `rebase_is_no_op`, an inline `-A`/`-B` test.
- `crates/zanshin-jj/src/revert.rs` (new) — `plan_revert` / `RevertPlan`, inline test; `lib.rs` — module.
- `crates/zanshin-jj/src/mutate.rs` — `plan_restore` / `RestorePlan`, `plan_absorb` / `AbsorbPlan`; `restore` / `absorb` call them.
- `crates/zanshin-jj/src/commit_views.rs` — `plan_interdiff`; `interdiff` calls it.
- `crates/zanshin-jj/src/drop_actions.rs` — the five `DropVerb` values, their rows, `view_err` (+ inline test), docs.
- `crates/zanshin-jj/tests/it/drop_actions.rs`, `api_stability.rs` — matrix and agreement tests, the verb list.
- `schemas/envelope.fbs` + committed codegen (`envelope_generated.rs`, `zanshin_ffi.h`, Dart flatbuffers, `bindings.dart`).
- `crates/zanshin-ffi/src/envelope.rs`, `drop_actions.rs`, `tests/it/drop_actions_ffi.rs` — mapping, docs, wire tests.
- `packages/zanshin_core/lib/src/ffi/drop_actions.dart`, `test/ffi/drop_actions_test.dart`, `test/worker/drop_actions_test.dart`.
- `docs/ffi-abi.md` — rows per location, NoOp sentence.
- `_bmad-output/implementation-artifacts/sprint-status.yaml` (9-31 DONE note, 9-16 / 9-18 notes), `deferred-work.md` (I1 RESOLVED, two dated sub-notes, the new "Surfaced in the Story 9.31 matrix-rows run" section), `epic-9-context.md` (recompiled: epics.md was newer).

**Review:** 29 findings — low 23, false 6, no high or medium.
- **Patched (all low):** the `Available` wording (interdiff is a read); `plan_rebase_branch`'s `@`-default doc and 9-16 note; an inline test for its `-A`/`-B` arm; the `RevertPlan` WHY; the unreachable revert NoOp marked in the docs; the `Restore` whole-tree docs; an unknown-target restore agreement case; the ledger commit hash.
- **Deferred (1, low, mirrored in deferred-work.md):** location plans resolve the immutable set before their ids and regardless of children (`plan_revert`, `plan_rebase_branch`, and the shipped `plan_duplicate` / `plan_new`).
- **Rejected, each with its reason in the Review Triage Log:** the double immutable resolution; the sprint-status note order (ledger convention); no oracle for unshipped verbs; the absorb no-op reason; the hover cost (no consumer yet, noted in the 10.10 ledger entry); the template-plus-root-merge order; the unknown-absorb-target test; the sampled matrix; and six intent readings (false: CLI parity where the matrix text differs).

**Follow-up review recommended: false.** No patched entry was high or medium. Patched counts by verdict: low 9 entries (high 0, medium 0).

**Residual risks:**
- Coverage was not measured (run rule): `revert.rs` (new) must reach 80% and `rebase.rs` / `drop_actions.rs` / `mutate.rs` must hold their baselines at the loop's final gate.
- `RebaseBranch` and `Revert` have no executing verb to agree with until Stories 9.16 / 9.18.
- An unknown absorb TARGET reads `jj.change_not_found` in the row where the verb (whose `--into` is a revset) says `jj.revset_resolution_error` — both refuse (documented).
- The hover now plans ten rows per one-target location (absorb annotates); measured with the rebase dry run in Story 10.10.
