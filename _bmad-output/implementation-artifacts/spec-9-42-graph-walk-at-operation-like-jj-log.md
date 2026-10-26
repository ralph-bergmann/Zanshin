---
title: 'Story 9.42: Graph walk evaluates like `jj log` @ v0.46 — `at_operation()` over sibling operations, `within_visibility` prioritization'
type: 'bugfix'
created: '2026-10-25'
status: 'done'
baseline_revision: 'c6ea7e4a79b27e0f928580fa17b7fdb119014717'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
warnings: ['oversized']
deferred:
  - summary: >-
      `graph_topology` now returns the rows of an `at_operation(<non-ancestor op>, …)` revset, but `commit_contents` refuses their ids, so the GUI's two-call path cannot load those rows' object half (author, description, `empty`).
    evidence: |-
      `commit_content.rs:184-187` refuses every id not in the pinned operation's index (`CommitNotFound`); the topology reports the head operation id, whose index lacks the sibling operation's commits. Pre-existing contract of the op-pinned content call; `jj log` renders those rows in full.
    location: >-
      crates/zanshin-jj/src/commit_content.rs:184; crates/zanshin-jj/src/topology.rs (operation_id)
    severity: low
    resolved: >-
      2026-10-26 — fixed (spec-loop-9-25-9-46-leftover-b-when-commands-rows-at-operation-contents, commit 51c9d24): `GraphTopology.extra_operation_ids` reports the `at_operation()` operations and `commit_contents` loads against the merged index.
  - summary: >-
      A merge outside the head index (an `at_operation()` commit) reports `empty: false` where the pinned `jj log` prints an inline template error; the error text is not surfaced.
    evidence: |-
      jj-lib's `Commit::is_empty` for a merge looks up common ancestors in the head index and fails; the CLI keeps the row and renders `<Error: Commit ID … not found in index …>` for the keyword. `CommitMeta.empty` is a `bool`, so Story 9.42 (no API change) reports `false`.
    location: >-
      crates/zanshin-jj/src/commit_meta.rs (is_empty)
    severity: low
    resolved: >-
      2026-10-26 — fixed (spec-loop-9-25-9-46-leftover-b-when-commands-rows-at-operation-contents, commit 51c9d24): `CommitMeta.empty` / `CommitContent.empty` are nullable; null where emptiness cannot be determined.
---

<intent-contract>

## Intent

**Problem:** `jj log` @ v0.46.0 evaluates its revset through `ResolvedRevset::evaluate` (`cli/src/commands/log.rs:161`), which merges the indexes of every operation an `at_operation()` brings in, so `at_operation(<op not an ancestor of @>, …)` works; and it confines `revsets.log-graph-prioritize` to the query with `query.within_visibility(repo)` (`log.rs:184-193`). Zanshin's `LogParse::evaluate` (`crates/zanshin-jj/src/graph.rs:259`) evaluates the RESOLVED log expression against the repo's own index (the topology's `ParentCount` passes refine it the same way), so such a revset fails in `walk_graph`/`graph_topology`, and `prioritize ∩ revset` shares one visibility scope instead of the CLI's two. (deferred-work I1.)

**Approach:** Resolve the log expression once into jj-lib's `ResolvedRevset`, evaluate the set with its `evaluate()` (merged index), then keep its `into_inner()` parts — the resolved expression AND the `at_operation()` repos — for the topology's refinement passes, which evaluate against the merged index only when that list is non-empty (unchanged fast path otherwise). Build the prioritize expression at evaluation time as the CLI does: `prioritize ∩ revset.within_visibility(head repo)`.

## Boundaries & Constraints

**Always:**
- Behavior = `jj log` @ v0.46.0: same rows, same order, same prioritization for the same revset/prioritize text; errors keep their kinds (parse → `ParseError`, resolution → `ResolutionError`, evaluation → `JjLibError`).
- Per-node metadata stays computed against the head repo (as the CLI's templates do): an `at_operation()`-only commit reports `hidden: true`; absent-from-index lookups degrade as jj-lib does (no error).
- No-`at_operation()` calls take exactly today's evaluation path (no merged index built, no extra pass) — no `large-10k` regression.

**Never:** No FFI, schema, Dart or public-API change; no layout-engine/graph-view change; no change to the anchors' semantics (Zanshin-only, intersected with the user `revset` as today); no second revset parser.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Sibling op revset | an operation written but never published (not an ancestor of head) holding a new commit; revset `at_operation(<op>, all())` | `walk_graph` and `graph_topology` return the rows `jj log --ignore-working-copy -r` prints, in its order; the new commit `hidden` | before: evaluation error |
| Sibling merge | that op also holds a 2-parent merge | `graph_topology` reports `parent_count == 2` for it | — |
| Prioritize, hidden in query | `describe -m1`, `describe -m2`; prioritize `at_operation(@-, @)`, revset `::(@\|at_operation(@-, @))` | commit "1" first (jj's `test_log_graph_prioritize_hidden_commits` case 1) | — |
| Prioritize outside query | prioritize `at_operation(@-, @ \| subject(1))`, revset `all()` | `[2, root]`, "1" not prioritized/emitted (case 2) | — |
| Query at old op | prioritize `@ \| subject(2)`, revset `at_operation(@-, all())` | `[1, root]` (case 3) | — |
| Unknown op | `at_operation(ffffffffffff, all())` | — | `ResolutionError`, as before |

</intent-contract>

## Code Map

- `crates/zanshin-jj/src/graph.rs` -- `LogParse` (:179-247): `prio` = `prioritize.intersection(&log)` at parse time (:237-239) → keep the parsed prioritize, intersect in `evaluate`; `LogParse::evaluate` (:259-273) uses `resolve_expression` + `ResolvedRevsetExpression::evaluate` (repo index); `LogSetup` (:278-287) carries `resolved` for the topology. Module/fn docs cite v0.42.0 — re-point the touched ones to v0.46.0.
- `crates/zanshin-jj/src/revset.rs` -- `resolve_for_evaluation` (:924, returns jj-lib `ResolvedRevset<'r>`), `resolve_expression` (:898, drops `other_repos`), `evaluate_revset` (:947, already merged). Reuse `resolve_for_evaluation`; nothing new here.
- `crates/zanshin-jj/src/topology.rs` -- `graph_topology` (:140-235) uses `setup.set` / `setup.resolved`; `parent_counts` (:244-255) evaluates `resolved.filtered(ParentCount(2..))` and `commits(candidates).filtered(ParentCount(k..))` with `ResolvedRevsetExpression::evaluate(repo_dyn)` → must use the merged index when `other_repos` is non-empty: `jj_lib::revset::optimize(expr).evaluate_unoptimized(repo_dyn, &other_repos)` (public; merges per call). `all_count` (:224) stays the head repo's `all()`.
- jj-lib 0.46.0 (`~/.cargo/registry/src/index.crates.io-*/jj-lib-0.46.0/src/revset.rs`): `within_visibility` (:632), `ResolvedRevset::{evaluate, into_inner}` (:738-763, `evaluate` returns a `'static` `Box<dyn Revset>`), `ResolvedRevsetExpression::evaluate_unoptimized(repo, other_repos)` (:798), `optimize` (:2684). `Transaction::write(..).leave_unpublished()` (`transaction.rs:135/239`) writes an operation without publishing it — how a test makes a non-ancestor operation.
- jj CLI @ v0.46.0: `cli/src/commands/log.rs:140-193`; `cli/src/revset_util.rs:84-160` (`RevsetExpressionEvaluator`); tests `cli/tests/test_log_command.rs::test_log_graph_prioritize_hidden_commits` (:812-863), `cli/tests/test_operations.rs` (:985-1030), `lib/tests/test_revset.rs::test_evaluate_expression_at_operation_that_is_not_ancestor` (:4332).
- `crates/test-helpers/src/lib.rs` -- private `load(root)`, `add_commit_off_root` (:226) is the pattern for a new unpublished-op helper.
- `crates/zanshin-jj/tests/it/graph.rs`, `tests/it/graph_topology.rs` -- `walk_graph`/`graph_topology` integration tests (helpers `collect_nodes`, `commit_id_of`).
- `crates/zanshin-parity/tests/oracle/hints.rs` -- pattern for a hand-written read comparison: `fresh_repo` + `jj(...)` on the SAME repo, then Zanshin; register a new module in `tests/oracle/main.rs`.
- `crates/zanshin-ffi/benches/graph_topology.rs` -- `Repo::graph_topology` timing on `large-10k-commits` (`cargo bench -p zanshin-ffi --bench graph_topology`).

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/src/graph.rs` -- `LogParse` keeps the parsed `prioritize`; `evaluate` resolves `log` via `resolve_for_evaluation`, evaluates the set with `ResolvedRevset::evaluate`, stores `into_inner()`'s expression and repos in `LogSetup` (new field `other_repos`), and evaluates `prioritize ∩ log.within_visibility(repo_dyn)`; docs updated (CLI citations @ v0.46.0, the two-scope rule).
- `crates/zanshin-jj/src/topology.rs` -- `parent_counts` takes the `at_operation()` repos and evaluates every pass against the merged index when there are any.
- `crates/test-helpers/src/lib.rs` -- `pub fn add_unpublished_op(workspace_root, description) -> (op_id_hex, Vec<commit_id_hex>)`: from the head, writes an unpublished operation with two commits off root and their merge (returns `[left, right, merge]`), so the op is never an ancestor of any head.
- `crates/zanshin-jj/tests/it/graph.rs` + `graph_topology.rs` -- witnesses: sibling-op revset rows (+ hidden flag), merge `parent_count == 2`, topology node order == `walk_graph` order, unknown op → `ResolutionError`.
- `crates/zanshin-parity/tests/oracle/log_at_operation.rs` (new, + `main.rs`) -- on one CLI-built repo, Zanshin's `walk_graph` commit-id order equals `jj log --ignore-working-copy -T 'commit_id ++ "\n"'` for the sibling-op revset (unpublished op created after the CLI steps) and for jj's three prioritize cases (`--config=revsets.log-graph-prioritize=…`).
- `docs/ffi-abi.md` -- if its graph-topology/walk text states how `prioritize` is intersected or that `at_operation()` needs an ancestor op, align it; otherwise unchanged.

**Acceptance Criteria:**
- Given a revset with `at_operation(<non-ancestor op>, …)`, when `walk_graph` or `graph_topology` runs, then it returns the CLI's rows in the CLI's order (oracle comparison), where before this story it failed.
- Given jj's three `test_log_graph_prioritize_hidden_commits` inputs, when Zanshin walks them, then the order equals the pinned CLI's.
- Given `large-10k-commits` and `all()` with the default prioritize, when `graph_topology` is timed before and after, then the median stays within noise (recorded in Verification).

## Spec Change Log

## Review Triage Log

### 2026-10-25 — Review pass
- verdicts: 20 findings — high 0, medium 0, low 14, false 6, maybe-false 0
- findings:
  - (blind-hunter) `low` `defer` sibling-op rows from `graph_topology` cannot get their object half: `commit_contents` (`commit_content.rs:184-187`) refuses an id outside the pinned (head) operation's index — confirmed; pre-existing contract of the op-pinned content call, closing it needs the topology's `at_operation()` operations handed to `commit_contents` (an API decision) — deferred.
  - (blind-hunter) `low` `patch` `is_empty`'s fallback turns ANY failure of a non-indexed commit into `empty: false` — confirmed (a store failure on a non-merge would be swallowed); narrowed to merges (`parent_ids().len() > 1`), the only case that needs the head index.
  - (blind-hunter) `low` `patch` the `false`-for-uncomputable degradation is undocumented — `CommitMeta::empty` doc now says a merge outside the head index reports `false` for the CLI's inline template error (the `docs/ffi-abi.md` `empty` text is `commit_contents`', which never reaches the fallback — unchanged).
  - (blind-hunter) `low` `patch` the oracle compares only commit-id order, no CLI witness for the merge row's metadata — the sibling oracle test now also compares each row's `hidden` and `empty` with the pinned CLI (template error = `false`).
  - (blind-hunter) `false` `reject` anchors keep the one-scope `anchor ∩ revset` — an anchor's ids that fall outside the evaluated set are dropped (`anchor_indices`), the same outcome `within_visibility` would give (the id is not a row); anchors are Zanshin-only, no CLI counterpart to diverge from.
  - (blind-hunter) `low` `reject` `resolved` + `other_repos` as two fields invite a future refinement that forgets the merged index — no such caller exists; a wrapper method is added complexity for a hypothetical caller.
  - (blind-hunter) `low` `reject` the `at_operation()` path re-resolves the log for `prioritize` and merges per pass, and the design note's "loaded once per call" overstates it — only revsets naming a non-ancestor operation pay it (no common path changes, bench within noise); the note is spec text, not code.
  - (blind-hunter) `low` `reject` no zanshin-jj witness for `within_visibility` and no `is_empty` unit test — the oracle's `prioritize_outside_the_query_matches_the_cli` fails with the fix reverted, and the sibling witnesses run both `is_empty` arms' lines; a duplicate in-crate test adds nothing.
  - (blind-hunter) `low` `patch` the topology sibling witness runs only `with_timestamps: false` — the test now also runs `with_timestamps: true` and asserts every non-root node has a timestamp.
  - (edge-case-hunter) `low` `patch` `is_empty` swallows backend failures of non-indexed commits — same root as the blind-hunter `is_empty` row; same fix (merge-only guard).
  - (intent-alignment) `low` `patch` rows are CLI-compared by commit id only (hidden/empty/parent_count in-crate) — same root as the oracle-metadata row; `hidden`/`empty` now compared with the CLI (`parent_count` has no `jj log` keyword; checked in-crate).
  - (intent-alignment) `low` `defer` the merge row's CLI error text is dropped (Zanshin reports `false`) — surfacing it needs an API change (`Option<bool>` or a warning); deferred.
  - (intent-alignment) `low` `patch` the oracle drives only `walk_graph`, `graph_topology` only transitively — `assert_same_order` now also asserts `graph_topology`'s order equals the CLI's, for every case.
  - (intent-alignment) `low` `patch` jj's prioritize cases are not run on `graph_topology` — same root and fix as the previous row.
  - (intent-alignment) `low` `patch` no witness for a `prioritize` that selects an `at_operation()`-only commit inside the query — oracle case added (prioritize = the sibling op's left commit on `at_operation(<op>, all())`).
  - (intent-alignment) `false` `reject` no FFI/worker witness — the change is below the FFI (no `.fbs`/extern change); `cargo test -p zanshin-ffi --test it graph` passes unchanged.
  - (intent-alignment) `false` `reject` the `large-10k` timing pin is not committed — the story asks to pin it; it is a recorded before/after measurement (Verification), the 9.27/9.41 precedent; the bench is optional scaffolding.
  - (intent-alignment) `false` `reject` `commit_contents` changed through the shared `object_half` without a test — `commit_contents` refuses non-indexed ids before `object_half` (`commit_content.rs:184-187`), so its behavior is unchanged.
  - (intent-alignment) `false` `reject` the passes use a second jj-lib door (`evaluate_unoptimized`) — the intent asks to keep the resolved expression the passes need, which is what the seam yields; jj-lib keeps its index merge private.
  - (intent-alignment) `false` `reject` `## Auto Run Result` / I1 outcome absent — written at finalization (this run).

## Design Notes

Why keep the resolved expression at all: the topology's `ParentCount` passes refine it (`resolved.filtered(..)`) instead of re-resolving the user text, so an `at_operation()` op is loaded once per call. jj-lib keeps its merge private; `evaluate_unoptimized(repo, other_repos)` is its public door and merges per pass — acceptable because only `at_operation()` revsets with non-ancestor ops pay it (typically 1–2 passes).

Why `within_visibility` matters: the CLI resolves the query "within a separate scope so its visibility and referenced commits aren't affected by the prioritize expression" (`log.rs:186-188`) — commits the prioritize text references by id or through `at_operation()` must not widen the query's `all()`/`::x`, or a prioritised id falls outside the evaluated set.

## Verification

**Commands:**
- `cargo test -p zanshin-jj --test it graph::` and `--test it graph_topology::` -- expected: pass, new witnesses fail with the fix reverted
- `cargo test -p zanshin-jj --lib` -- expected: pass
- `cargo test -p zanshin-ffi --test it graph` -- expected: pass (dependent)
- `cargo test -p zanshin-parity --test oracle` -- expected: pass incl. `log_at_operation::*`
- `cargo clippy -p zanshin-jj -p test-helpers -p zanshin-parity --all-targets -- -D warnings`; `cargo fmt --all --check` -- expected: clean
- `cargo bench -p zanshin-ffi --bench graph_topology` at the baseline and after -- expected: `large-10k` topology median within noise

**Baseline measured (2026-10-25, at c6ea7e4, before any change):** `large-10k-commits` loose — `graph_topology` (default anchors) min 24.77 ms / med 25.39 ms, (anchors []) min 21.63 / med 21.80 ms; packed — (default anchors) min 20.65 / med 20.98 ms, (anchors []) min 21.10 / med 21.57 ms; `walk_graph(all())` packed med 56.18 ms. Re-run the same bench after the change and record it beside these.

**Results (2026-10-25, implementation run, uncommitted working tree):**
- `cargo test -p zanshin-jj --test it graph::` — 41 passed; `--test it graph_topology::` — 15 passed. With
  `crates/zanshin-jj/src` stashed (fix reverted) the two sibling-op witnesses fail with
  `JjLibError("Commit ID … not found in index …")`; the two unknown-op witnesses pass either way (as before).
- `cargo test -p zanshin-jj --lib` — 396 passed. Whole `cargo test -p zanshin-jj --test it` — 1406 passed, 1 ignored
  (pre-existing), since `commit_meta.rs`'s `object_half` is shared with `commit_contents`.
- `cargo test -p zanshin-ffi --test it graph` — 21 passed.
- `cargo test -p zanshin-parity --test oracle` — 456 passed, incl. `log_at_operation::*` (4). Fix reverted:
  `sibling_operation_revset_rows_match_the_cli` and `prioritize_outside_the_query_matches_the_cli` fail; jj's cases 1
  and 3 already matched before.
- `cargo clippy -p zanshin-jj -p test-helpers -p zanshin-parity --all-targets -- -D warnings` — clean;
  `cargo fmt --all --check` — clean.
- Found while implementing (not in the spec's code map): with the default template the pinned `jj log` prints the
  sibling op's MERGE row with `<Error: Commit ID … not found in index …>` in place of `empty` (jj-lib's
  `Commit::is_empty` → `merge_commit_trees` → `common_ancestors` on the head index) and still prints the row. Zanshin's
  `walk_graph` failed the whole call there, so `commit_meta::is_empty` now reports `false` (no "(empty)", as the CLI's
  row shows none) only when `is_empty` fails AND the commit is not in the head index; every other failure stays an
  error. The error text itself is not surfaced (the row's `empty` is a `bool`; no API change in this story).
- `cargo bench -p zanshin-ffi --bench graph_topology`, `large-10k-commits`, after the change (two runs) — loose
  (default anchors) med 25.68 / 27.19 ms, (anchors []) 23.38 / 23.84 ms; packed (default anchors) 24.01 / 24.01 ms,
  (anchors []) 24.30 / 24.95 ms; `walk_graph(all())` packed 58.53 / 57.86 ms. The machine was slower than at the
  recorded baseline, so the baseline was re-run in the same session with the src change stashed: loose 25.77 /
  23.36 ms, packed 26.32 / 26.60 ms, `walk_graph(all())` packed 61.05 ms — the after-change medians are within noise
  of (here even below) the same-session baseline.

**After the review patches (2026-10-25, orchestrator run on the patched tree; the full gate is the story loop's, not run here):**
- `cargo test -p zanshin-jj --test it graph` (covers `graph::` + `graph_topology::`) — 64 passed
- `cargo test -p zanshin-jj --lib` — 396 passed
- `cargo test -p zanshin-ffi --test it graph` — 21 passed
- `cargo test -p zanshin-parity --test oracle` — 457 passed, incl. the 5 `log_at_operation::*` (rows compared as commit id + `hidden` + `empty`, `graph_topology` order asserted too)
- `cargo clippy -p zanshin-jj -p test-helpers -p zanshin-parity --all-targets -- -D warnings` — clean; `cargo fmt --all --check` — clean
- No FFI/schema/Dart change: no `cargo make codegen`, no Dart checks. Coverage not measured (gate rule); every new line runs in the sibling-op witnesses.

## Auto Run Result

Status: done

**Summary.** `walk_graph` and `graph_topology` now evaluate like `jj log` @ v0.46.0: the log set goes through jj-lib's `ResolvedRevset::evaluate` (the head index merged with every operation an `at_operation()` brings in), so `at_operation(<op not an ancestor of the head>, …)` returns the CLI's rows instead of failing "Commit ID … not found in index"; the resolved expression and the `at_operation()` repos are kept for the topology's `ParentCount` passes, which use the merged index only when there are any (the common path is unchanged — `large-10k` within noise of a same-session baseline). Prioritization is `prioritize ∩ revset.within_visibility(head)`, the CLI's two scopes, so ids or `at_operation()`s in `prioritize` no longer widen the query. A merge outside the head index reports `empty: false` where the CLI prints an inline template error (it failed the whole walk before).

**Files changed (code commit 5c45951):**
- `crates/zanshin-jj/src/graph.rs` -- `LogParse` keeps the parsed `prioritize`; `evaluate` uses `ResolvedRevset::evaluate` + `into_inner()` (new `LogSetup.other_repos`) and the `within_visibility` prioritize; docs at v0.46.0.
- `crates/zanshin-jj/src/topology.rs` -- `parent_counts` evaluates against the merged index when `other_repos` is non-empty.
- `crates/zanshin-jj/src/commit_meta.rs` -- `is_empty`: `false` for a merge outside the head index; `CommitMeta::empty` doc.
- `crates/test-helpers/src/lib.rs` -- `add_unpublished_op` (an operation never published: two commits off root + their merge).
- `crates/zanshin-jj/tests/it/graph.rs`, `graph_topology.rs` -- sibling-op rows/hidden/empty/edges, topology order + merge `parent_count == 2` + timestamps, unknown op → `ResolutionError`.
- `crates/zanshin-parity/tests/oracle/log_at_operation.rs` (+ `main.rs`) -- five comparisons with the pinned `jj log` (sibling-op revset, a prioritised sibling-op commit, jj's three `test_log_graph_prioritize_hidden_commits` cases).

**Items:**
- I1 (the graph walk's log set does not merge `at_operation()` indexes; also `within_visibility` on prioritize) -- fixed (5c45951).

**Review:** 20 findings (high 0, medium 0, low 14, false 6). Patched (all low): `is_empty`'s fallback narrowed to merges (a non-merge's store failure stays an error) + the `CommitMeta::empty` doc; the oracle compares `hidden`/`empty` per row and `graph_topology`'s order for every case, plus a case prioritising a sibling-op commit; the topology witness also runs `with_timestamps: true`. Deferred (mirrored to deferred-work.md "Surfaced in Story 9.42"): `commit_contents` refuses the sibling-op rows' ids (op-pinned head index; needs the topology's operations handed over — an API decision); the merge's CLI error text is not surfaced (needs `Option<bool>` or a warning). Rejected: anchors' one-scope intersection (an out-of-set anchor id is dropped either way; Zanshin-only), the two-field `LogSetup` split (no caller forgets it today), the `at_operation()` path's extra resolve/merge cost (only non-ancestor `at_operation()` revsets pay it), no in-crate `within_visibility` witness (the oracle's case 2 fails with the fix reverted), no FFI witness (no FFI change), the uncommitted timing pin (recorded measurement, 9.27/9.41 precedent), `commit_contents` behavior via `object_half` (refused before it, unchanged), the second jj-lib door for the passes (jj-lib's merge is private), the missing Auto Run Result (written here).

**Follow-up review recommended:** false — no high and no medium entry was patched (patched: 7 entries, all low).

**Residual risks:** the full gate (incl. the coverage ratchet for the changed files) runs at the end of the story loop; the fix-reverted check was run before the review patches, not after (the patches only narrowed a guard and added assertions).
