---
title: 'Story 9.48 — `jj new --insert-after` / `--insert-before` (`new -A` / `-B` parity), parents deduplicated'
type: 'feature'
created: '2026-10-19'
status: 'ready-for-dev'
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

**Problem:** `Repo::new_change(parents)` takes parents only, so the card menu's "Insert after" / "Insert before" rows (Story 10.15) have no verb behind them: `jj new -A <id>` / `-B <id>` (`cli/src/commands/new.rs:160-291` @ v0.46.0) inserts the new change between a target and its children / parents and rebases those children. Also (deferred item **I1**): `new_change(&[c, c])` writes a commit with the same parent twice and skips the one-parent bookmark advance, where the CLI resolves its revisions through an `IndexSet` (`cli_util.rs:1845-1858` `resolve_revsets_ordered`, reached through `compute_commit_location` `:3644`) into one parent and advances.

**Approach:** `Repo::new_change(parents, insert_after, insert_before)` mirrors `cmd_new`: one pure precondition fn `plan_new` (shape check, ordered dedup resolution of all three lists, and — for `-A`/`-B` — Story 9.1's `op_support::compute_commit_location(…, "new commit")` with its immutable/loop/no-parent refusals) returns the new commit's parents and the children to rebase; the transaction writes the commit on the merged parent tree, rebases each child with the CLI's parent-replacement rule, then `rebase_descendants`, `edit`, and the bookmark advance only when neither `-A` nor `-B` is given. The surface (`.fbs` → FFI → Dart `newChange(parents, {insertAfter, insertBefore})` → `docs/ffi-abi.md`) and 9.47 oracle scenarios follow.

## Boundaries & Constraints

**Always:**
- The CLI at v0.46.0 is the spec: `git -C ../jj show v0.46.0:cli/src/commands/new.rs` (`cmd_new` `:160-291`, the help diagrams `:79-151`), `cli/src/cli_util.rs` `compute_commit_location` `:3644-3730`, `ensure_no_commit_loop` `:3734-3754`, `resolve_revsets_ordered` `:1845-1858`.
- Arguments: each of the three lists is a `&[ChangeId]`; EMPTY means "flag not given" (the CLI's clap cannot pass a flag with zero values, and an id cannot resolve to nothing). `parents` non-empty together with a non-empty `insert_after`/`insert_before` → `jj.invalid_input` (clap `conflicts_with = "revisions"`). All three empty → `jj.invalid_input` (no Zanshin `@` default; the caller passes `@` explicitly, as today).
- Each list resolves in argument order with duplicates dropped (the `resolve_revsets_ordered` `IndexSet`), order of resolution `parents` → `insert_after` → `insert_before`; an unknown/hidden/divergent id → `jj.change_not_found`. Reuse the resolution `squash_split.rs` `resolve_ordered` does (moved to `op_support.rs` as `pub(crate)` and called from both) — one implementation.
- With `-A`/`-B`: the immutable set is resolved (`op_support::resolve_immutable` on the transaction's base repo; an unresolvable alias → `jj.config_error`) and `compute_commit_location(repo, &immutable, None, after, before, "new commit")` gives `(new_parents, children)` with its refusals verbatim: an immutable child → `jj.immutable` (first offender's hex in `context`), a loop → `jj.invalid_input` `Refusing to create a loop: commit <12 hex> would be both an ancestor and a descendant of the new commit`, no parent → `jj.invalid_input` `No revisions found to use as parent`. Without `-A`/`-B` the immutable set is NOT resolved (plain `new` keeps its behavior) and `children` is empty.
- `plan_new` is ONE `pub(crate)` fn in `crates/zanshin-jj/src/mutate.rs` that writes nothing; `new_change` calls it first. 9.31's `new` row will call the same fn (its doc says so).
- Every refusal (shape, resolution, location, the one-parent advance config) happens before the first write; a refusal writes no operation.
- Transaction (`new.rs:208-284`): new commit = `new_commit(new_parents, merge_commit_trees(new_parents))` with the description exactly as the shipped `new` sets it; for each child in `children` order: new parent list = for each old parent, the new commit if the old parent is in `new_parents` else the old parent, then the new commit — ordered, deduplicated (`IndexSet`) — and `jj_lib::rewrite::rebase_commit(child, that list)`; then `rebase_descendants`; `edit(new commit)`; bookmark advance ONLY when `insert_after` and `insert_before` are both empty and exactly one parent remains after dedup (I1); op description `new empty commit`.
- Result: `MutationResult` as today — `new_change_ids` = `[the new change]`, `@` = the new change. No new field ("Rebased N descendant commits." is a status line).
- Surface: `schemas/envelope.fbs` `ChangeIdList` gains `insert_after: [string]; insert_before: [string];` APPENDED after `change_ids` (in-place WIP edit, both codegen sides regenerated in the same commit via `cargo make codegen`); only `zanshin_new_change` reads them (documented; `zanshin_abandon` ignores them). Dart: `newChange(List<String> parents, {List<String> insertAfter = const [], List<String> insertBefore = const []})` through `RepoHandle` → `WorkerIsolate` → `NewChangeCommand` → `zanshinNewChange`.
- Rust: clippy pedantic `-D warnings`, rustfmt; rustdoc of `plan_new`, `new_change`, `Repo::new_change`, `zanshin_new_change` names the rules and every error cause; coverage never drops, `coverage-baseline.txt` never lowered.

**Never:**
- No `--no-edit`, no `-m`, no `-o`/`-r`/`-d` aliases beyond the positional parents, no UI code, no MCP change, no new error or warning code.
- No change to `compute_commit_location`'s behavior or its existing callers' results (split keeps its `"split-out commit"` noun and refusals); no change to `templates.new_description` / trailer handling (Story 9.46 / the 9.47 ledger).
- Never regenerate fixtures; never edit existing `deferred-work.md` bullets, `epics.md` or `epic-9-context.md`.

## I/O & Edge-Case Matrix

History BASE = root → A → B (`b-mark`) → C = `@`, as in the oracle.

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| -A, two children | BASE + sibling S on B; `new([], [B], [])` | N on B; C and S rebased onto N; `@` = N; op `new empty commit` | — |
| -B | BASE; `new([], [], [C])` | N on B; C rebased onto N; `@` = N | — |
| -A + -B | BASE + D on C; `new([], [A], [D])` | N on A; D's parents = [C, N] (help example `new.rs:135-145`); B, C unchanged | — |
| -A on a head | BASE; `new([], [C], [])` | N on C, nothing rebased | — |
| No advance with -A | `enabled-branches = ["*"]`, `a-mark` on A; `new([], [B], [])` | `a-mark` stays on A, `b-mark` on B | — |
| Duplicate parents (I1) | `enabled-branches = ["*"]`; `new([C, C], [], [])` | N with ONE parent C; `b-mark` advances to C | — |
| Duplicate -A ids | `new([], [B, B], [])` | same as `new([], [B], [])` | — |
| Immutable child | `immutable_heads() = b-mark`; `new([], [A], [])` | refused, op head unchanged | `jj.immutable` (B's hex) |
| -B root | `new([], [], [root])` | refused, op head unchanged | `jj.immutable` |
| Loop | `new([], [C], [A])` | refused, op head unchanged | `jj.invalid_input`, `Refusing to create a loop: commit <A 12 hex> would be both an ancestor and a descendant of the new commit` |
| Positional + -A | `new([C], [B], [])` | refused before resolution | `jj.invalid_input` |
| All empty | `new([], [], [])` | refused | `jj.invalid_input` |
| Unknown id | `new([], [bogus], [])` | refused | `jj.change_not_found` |

</intent-contract>

## Code Map

- `crates/zanshin-jj/src/mutate.rs` -- `new_change` :804-875 (doc :804-822): today resolves `parents` inside the tx :838-841 without dedup (I1), one-parent advance via `match parent_commits.as_slice() { [parent] => … }` :844-852, writes :853-855, `rebase_descendants` :858, `edit` :859, advance :861-863, final `rebase_descendants` :869, `finish_verb(…, "new empty commit", ctx)` :871. Add `plan_new` here. `guard_rewritable` :501 (shape reference: resolves immutable on `tx.base_repo()`), `be`/`cfg` error mappers, `mutation_result`.
- `crates/zanshin-jj/src/op_support.rs` -- `compute_commit_location` :166-270 (takes RESOLVED, DEDUPED ids; `None` = flag absent; `"new commit"` is the CLI's noun for `new`), `ensure_no_commit_loop` :272-293, `check_rewritable` :123-155, `resolve_immutable` :99-121, `resolve_commit` (change id → commit, `ChangeNotFound`). Its unit tests :933-1149 stay green.
- `crates/zanshin-jj/src/squash_split.rs` -- `resolve_ordered` :514-528 (private): ordered, deduped `Option<&[ChangeId]>` → `Option<Vec<CommitId>>`; `prepare_split` :442-511 is the calling pattern (`compute_commit_location(tx.base_repo().as_ref(), &immutable, …)`).
- `crates/zanshin-jj/src/commit.rs` -- `advanceable_bookmarks` / `advance_bookmarks` / `advance_bookmarks_matcher` (`pub(crate)`, Story 9.49 closing run) — reused unchanged.
- `crates/zanshin-jj/src/repo.rs` -- `Repo::new_change` :972-995 (signature + doc: the three lists, the rules, `# Errors` gains `Immutable` and the location/shape `InvalidInput` causes and `Config` for the immutable alias).
- `crates/zanshin-ffi/src/repo.rs` -- `read_change_id_list` :174-196 (abandon keeps it); add a reader returning the three lists for `NewChange`; `zanshin_new_change` :830-883 (doc: the two fields, `jj.immutable`, the new `jj.invalid_input`/`jj.config_error` causes); `map_mutate_err` already maps `Immutable`.
- `schemas/envelope.fbs` -- `ChangeIdList` :110-118 and the `RequestKind` doc :57-66 (say only `NewChange` reads the two lists). Regenerate with `cargo make codegen` (Rust `envelope_generated.rs`, Dart `envelope_zanshin.ffi_generated.dart`, header/bindings if touched).
- `packages/zanshin_core/lib/src/ffi/mutate.dart` -- `_withChangeIdListBytes` :30-36, `zanshinNewChange` :59-62 (gain `insertAfter`/`insertBefore`, NUL check like `squash_split.dart:137`); `lib/src/worker/commands.dart` `NewChangeCommand` :345; `lib/src/worker/isolate.dart` `newChange` :892-905 and dispatch :2334; `lib/src/worker/handle.dart` `newChange` :360. Pattern: split's `insertAfter` plumbing (`handle.dart:601-634`, `isolate.dart:1138-1176`, `:2498-2514`, `commands.dart:1337-1361`).
- Docs -- `docs/ffi-abi.md` :383-389 (shared tables), :406-412 (`RequestKind`), row :500 (`zanshin_new_change`: add `jj.immutable`, cite 9.48); `docs/rust-error-codes.md` rows `jj.change_not_found` :48, `jj.invalid_input` :65, `jj.immutable` :66 (append "also emitted — Story 9.48" clauses).
- Tests -- `crates/zanshin-jj/tests/mutate.rs` `new_change_*` :179-247 (harness `pin_env` :24); `crates/zanshin-jj/tests/commit.rs` `base_with` :136 (A→B→C with a repo config, `bookmark` :117, `head_op` :112, `parents` :103) — copy that harness into a new `crates/zanshin-jj/tests/new_insert.rs` for the matrix. `crates/zanshin-ffi/tests/repo_write_ffi.rs` (`zanshin_new_change` tests :265-320, request building with `ChangeIdListArgs`); `packages/zanshin_core/test/worker/mutate_test.dart` `newChange_*` :59; `packages/zanshin_core/test/ffi/bookmark_ops_test.dart` :105 (ChangeIdList codec test). ~53 existing `.new_change(&[…])` call sites across `crates/*/tests` and `crates/zanshin-ffi/src/repo.rs` move to the 3-arg form (`, &[], &[]`).
- Oracle -- `crates/zanshin-parity/tests/oracle/scenarios.rs` (`BASE` :32-40, `ADVANCE_ALL` :283, `ADVANCE_ALL_A_MARK`, `new_*` scenarios :411-440 and :1296-1360, `describe_immutable` config setup :553-560, `IMMUTABLE_WC_WITH_CHILD` :378 for the `revset-aliases` form); `main.rs` `parity!` list and `assert_eq!(SCENARIO_IDS.len(), 89)` :141.

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/src/op_support.rs` (+ `squash_split.rs`) -- move `resolve_ordered` to `op_support` as `pub(crate)` (doc: the CLI's `resolve_revsets_ordered` over change ids), `squash_split` imports it -- one ordered-dedup resolver for split and new.
- `crates/zanshin-jj/src/mutate.rs` -- add `pub(crate) struct NewLocation { parents: Vec<CommitId>, children: Vec<CommitId> }` (or a tuple) and `pub(crate) fn plan_new(repo, immutable_expr, parents, insert_after, insert_before) -> Result<…, MutateError>`: shape check, resolution, `compute_commit_location` for `-A`/`-B`; rewrite `new_change(workspace, ctx, parents, insert_after, insert_before)` around it: advance read only with no `-A`/`-B` and one deduped parent, child rebase loop, the rest unchanged; inline unit tests for `plan_new`'s shape refusals and dedup if cheaper than integration tests -- the verb and I1.
- `crates/zanshin-jj/src/repo.rs` -- `Repo::new_change(&mut self, parents, insert_after, insert_before)` + doc -- the public API.
- `crates/zanshin-jj/tests/new_insert.rs` (new) -- every I/O-matrix row against jj-lib state (parents of N and of each rebased child, `@`, op description, bookmark targets, op head unchanged on refusals, the loop text) -- witnesses.
- Every existing `new_change(` call site (`crates/zanshin-jj/tests/*.rs`, `crates/zanshin-ffi/tests/*.rs`, `crates/zanshin-parity/tests/oracle/scenarios.rs`) -- add `&[], &[]` -- compile.
- `schemas/envelope.fbs` -- append the two fields to `ChangeIdList`, docs; `cargo make codegen` and commit both generated sides -- wire format.
- `crates/zanshin-ffi/src/repo.rs` -- `NewChange` reader returning `(parents, insert_after, insert_before)` (absent = empty), `zanshin_new_change` passes them, doc; `crates/zanshin-ffi/tests/repo_write_ffi.rs` -- one `-A` round trip through `zanshin_new_change` (new change between target and child, `@` = it) and one `jj.immutable` refusal envelope -- FFI.
- `packages/zanshin_core` (`ffi/mutate.dart`, `worker/commands.dart`, `worker/isolate.dart`, `worker/handle.dart`) -- the named parameters end to end; `test/worker/mutate_test.dart` -- a real-cdylib round trip `newChange([], insertAfter: [x])` and `insertBefore: [y]` checking the resulting graph via existing read verbs; `test/ffi/bookmark_ops_test.dart` (or `mutate_test.dart`) -- the builder writes both lists -- Dart.
- `docs/ffi-abi.md`, `docs/rust-error-codes.md` -- rows and clauses as in the Code Map -- docs.
- `crates/zanshin-parity/tests/oracle/scenarios.rs` + `main.rs` -- scenarios `new_insert_after_two_children` (setup `new -m S b-mark` — S becomes `@`, B has children C and S; then `new -A B`), `new_insert_before` (`new -B C`), `new_insert_after_and_before` (setup `new -m D`, `new -A A -B D`), `new_insert_after_immutable_child` (`immutable_heads() = b-mark`, `new -A A`), `new_insert_after_no_advance` (`ADVANCE_ALL_A_MARK`, `new -A B`), `new_insert_loop` (`new -A C -B A`), `new_duplicate_parents` (`ADVANCE_ALL`, `new C C`); add to `parity!`, count 89 → 96 -- oracle.
- `coverage-baseline.txt` -- commit an auto-raise if the gate raises it; never lower.

**Acceptance Criteria:**
- Given each new oracle scenario, when `cargo test -p zanshin-parity --test oracle` runs, then it matches the pinned CLI on every compared aspect (graph, op description, op count, refused) with no new ledger entry.
- Given a Dart caller, when `RepoHandle.newChange([], insertAfter: [t])` runs against a real repo through the cdylib, then the new change sits on `t`, `t`'s former children sit on it, and the result's `workingCopyChangeId` is the new change.
- Given an existing `newChange(parents)` / `new_change(parents, &[], &[])` caller, when it runs, then its observable behavior is unchanged except that duplicate parents collapse to one (I1).
- Given `cargo make test` on the final tree (repo root, unpiped, synchronous), then it exits 0 and `coverage-baseline.txt` is not lowered.
- Given the end of the run, then `git status --porcelain` is clean and every commit ends with the required co-author trailer and was made with `--no-gpg-sign`.

## Spec Change Log

## Review Triage Log

## Design Notes

**Wire shape.** The epic asks for the two id lists "appended" to the request. `ChangeIdList` is the request (`kind` tells `NewChange` from `Abandon`), so the fields go after `change_ids`; `zanshin_abandon` never reads them. A dedicated `NewChangeRequest` table was considered and rejected: more codegen churn and it breaks the documented "one table, two kinds" design for no caller-visible gain.

**Empty = absent.** Unlike split (`Option`, where a present-empty `-A` is refused), `new` takes plain slices: the CLI cannot pass a flag with no values, a change id always resolves to exactly one commit, and Dart's defaults are `const []`. `compute_commit_location` still gets `None` for an empty list.

**Child rebase golden** (`-A A -B D` on A–B–C–D): `new_parents = [A]`, `children = [D]`; D's old parents `[C]`, C ∉ {A} → `[C]`, then push N → D on `[C, N]`. With `-B C` on BASE: `new_parents = [B]`, `children = [C]`; C's `[B]` → `[N]`, push N (dedup) → `[N]`.

## Verification

**Commands:**
- `cargo test -p zanshin-jj --test new_insert --test mutate --test commit` and `cargo test -p zanshin-jj --lib` -- expected: green.
- `cargo test -p zanshin-ffi` -- expected: green.
- `cargo test -p zanshin-parity --test oracle` -- expected: 96 scenario tests + the meta tests pass, no ledger change.
- `cargo make test` (repo root, unpiped, synchronous, long timeout; PATH with `~/development/sdks/flutter/bin` and `~/development/sdks/cargo/bin`, `CARGO_HOME=~/development/sdks/cargo`, `RUSTUP_HOME` unset) -- expected: exit 0; coverage held or raised.
