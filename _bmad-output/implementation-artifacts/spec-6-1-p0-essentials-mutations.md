---
title: 'Story 6.1: P0 essentials mutations (mutate.rs) — describe, new, edit, abandon'
type: 'feature'
created: '2026-08-24'
status: 'done'
baseline_revision: 'bdfc46c15cd764d048d89d839a2af23297143f05'
review_loop_iteration: 0
followup_review_recommended: true
context: []
warnings: ['oversized']
deferred:
  - summary: >-
      No immutable-heads/trunk-protection guard on describe/edit/abandon (the CLI
      refuses via check_rewritable against immutable_heads()).
    evidence: |-
      Blind Hunter review pass. project-context.md already earmarks this as a future
      shared-support-module concern ("a shared support module re-ports the cli_util
      orchestration jj-lib does NOT expose (immutable-heads check, ...)"), not
      per-verb-story scope — consistent with Story 6.1 being "P0 essentials."
    location: >-
      crates/zanshin-jj/src/mutate.rs (describe, edit, abandon)
    severity: medium
  - summary: >-
      describe doesn't short-circuit when the new description equals the existing one
      (the CLI does, to avoid a no-op commit and descendant rebase).
    evidence: |-
      Blind Hunter review pass; confirmed against cli/src/commands/describe.rs at
      v0.42.0. CLI-parity refinement beyond the story's literal AC.
    location: 'crates/zanshin-jj/src/mutate.rs:describe'
    severity: low
  - summary: >-
      edit doesn't short-circuit when already on the target commit (the CLI prints
      "Already editing that commit" and skips opening a transaction).
    evidence: |-
      Blind Hunter review pass; confirmed against cli/src/commands/edit.rs at v0.42.0.
    location: 'crates/zanshin-jj/src/mutate.rs:edit'
    severity: low
  - summary: >-
      abandon aborts the whole batch on the first already-hidden/nonexistent id instead
      of skipping it with a warning, unlike the CLI's visible-heads intersection.
    evidence: |-
      Blind Hunter review pass; confirmed against cli/src/commands/abandon.rs at
      v0.42.0 ("Skipping N revisions that are already hidden.").
    location: 'crates/zanshin-jj/src/mutate.rs:abandon'
    severity: medium
  - summary: >-
      abandon doesn't dedupe change_ids (the CLI collects targets into an IndexSet).
    evidence: |-
      Blind Hunter review pass. A duplicate input id inflates the op-log message count
      and double-calls record_abandoned_commit for the same commit.
    location: 'crates/zanshin-jj/src/mutate.rs:abandon'
    severity: low
  - summary: >-
      new_change doesn't validate or dedupe parents; a duplicate parent id's behavior
      through merge_commit_trees/new_commit is untested and undocumented.
    evidence: |-
      Blind Hunter review pass.
    location: 'crates/zanshin-jj/src/mutate.rs:new_change'
    severity: low
  - summary: >-
      MutationResult doesn't report bookmarks deleted by abandon's
      delete_abandoned_bookmarks:true side effect.
    evidence: |-
      Blind Hunter review pass. A caller must separately diff list_bookmarks() before
      and after to discover this; not required by the story's literal AC.
    location: 'crates/zanshin-jj/src/mutate.rs:MutationResult'
    severity: medium
  - summary: >-
      MutationResult doesn't surface conflict state on the resulting commit (e.g. from
      a multi-parent new_change's merged tree).
    evidence: |-
      Blind Hunter review pass. The read-side Change type already has a
      ConflictState field for this; MutationResult has no equivalent.
    location: 'crates/zanshin-jj/src/mutate.rs:MutationResult'
    severity: medium
  - summary: >-
      new_change doesn't replicate the CLI's single-parent bookmark auto-advance (jj
      new moves a bookmark pointing at the sole parent forward onto the new commit).
    evidence: |-
      Blind Hunter review pass; confirmed against cli/src/commands/new.rs at v0.42.0
      (advanceable_bookmarks / tx.advance_bookmarks).
    location: 'crates/zanshin-jj/src/mutate.rs:new_change'
    severity: medium
  - summary: >-
      concurrent_writes.rs never has two Repo handles race to move `@` itself
      concurrently — only one thread ever moves the working copy.
    evidence: |-
      Blind Hunter review pass. The story's own edge case explicitly defers deeper
      same-repo concurrency validation to Epic 7 (zanshin-mcp).
    location: crates/zanshin-jj/tests/concurrent_writes.rs
    severity: low
  - summary: >-
      The WIP-rework append's "FFI boundary" / "envelope error-channel" language for
      the concurrent-write smoke test has no corresponding assertion yet, since
      zanshin-ffi's mutation wrapper doesn't exist until Story 6.5.
    evidence: |-
      Intent Alignment Auditor pass. The zanshin-jj-level test built here is the
      correct interim scope; whichever story adds the FFI mutation wrapper should
      extend this smoke test to the FFI/envelope layer.
    location: crates/zanshin-jj/tests/concurrent_writes.rs
    severity: low
  - summary: >-
      NFR-R-2 op-log-description CLI parity is verified via string literals
      cross-checked by the implementer against the real CLI source, not via a
      repeatable, executable CLI oracle.
    evidence: |-
      Intent Alignment Auditor pass. Consistent with the rest of this test suite's
      existing convention — no live-CLI-oracle testing exists anywhere else in the
      codebase either, so this isn't specific to this story.
    location: crates/zanshin-jj/tests/mutate.rs
    severity: low
---

<intent-contract>

## Intent

**Problem:** `zanshin-jj` currently exposes only reads. Epic 6 needs the four highest-frequency change mutations — describe, new, edit, abandon — going through jj-lib transactions only, so FFI/MCP callers can write to a repo (FR-JJ-10a).

**Approach:** Add `crates/zanshin-jj/src/mutate.rs` with a shared `MutationResult` + `MutateError`, and four `Repo` methods that each open a jj-lib transaction, mutate via `tx.repo_mut()`, and commit with a CLI-matching op-log description.

## Boundaries & Constraints

**Always:**
- Every mutation follows: `let mut tx = readonly_repo.start_transaction(); tx.repo_mut().<mutate>; [rebase_descendants]; tx.commit("<cli-parity description>")` — jj-lib only, never shells to `jj` (AR-AP-1).
- Resolve every `ChangeId` argument (describe's target, edit's target, each of new_change's parents, each of abandon's targets) with the SAME pattern as `change.rs::get_change`: empty/malformed reverse-hex → `MutateError::ChangeNotFound`; `resolve_change_id` on `tx.repo()` (works identically on `MutableRepo`, mid-transaction); `.into_visible()` first target, `None` → `ChangeNotFound`. Any other jj-lib failure → `MutateError::Backend(String)`.
- After `tx.commit()`, compare the workspace's wc-commit-id before vs. after (`view().get_wc_commit_id(&workspace_name)`). Only if it changed, call `workspace.check_out(new_repo.op_id().clone(), Some(&old_tree), &new_wc_commit)` to sync the on-disk working copy (`old_tree` = the pre-mutation wc commit's `MergedTree`, for jj-lib's own concurrent-modification guard). If unchanged, skip the disk checkout entirely.
- Use the CLI's exact op-log description strings so `jj op log` output is indistinguishable (NFR-R-2): describe → `"describe commit {commit_hex}"`; new_change → `"new empty commit"` (always, regardless of parent count); edit → `"edit commit {commit_hex}"`; abandon → `"abandon commit {hex}"` (one id) or `"abandon commit {first_hex} and {n-1} more"` (multiple).
- `abandon`'s `rebase_descendants` call MUST pass `RewriteRefsOptions { delete_abandoned_bookmarks: true }` (via `rebase_descendants_with_options`) — the bare no-args `rebase_descendants()` defaults `delete_abandoned_bookmarks` to `false` and would silently diverge from the CLI's default (NFR-R-2).
- `new_change`/`edit` call `tx.repo_mut().edit(workspace_name, &commit)` directly — NEVER `mut_repo.check_out(...)`, which would build an unwanted *second* empty commit on top (`check_out` = `new_commit` + `edit`; for `new_change` you already built the commit yourself).
- `new_change` with >1 parent: compute the merged tree yourself first via `jj_lib::rewrite::merge_commit_trees(tx.repo(), &parent_commits).await` (a free fn — `new_commit` never merges trees for you), then `tx.repo_mut().new_commit(parent_ids, merged_tree)...write()`.
- Add `pub(crate) mod mutate;` to `lib.rs` + `pub use mutate::{MutationResult, MutateError};`; extend `tests/api_stability.rs` with `_MutationResult`/`_MutateError` aliases and trivial `MutateError::Backend(String::new())` construction (existing structural surface-pin convention, FR-JJ-16).

**Block If:** none identified — the ACs and jj-lib 0.42.0 research below fully resolve the call sequence.

**Never:**
- Never implement undo/redo or op-restore semantics here (Story 6.2).
- Never add a coordination lock (`Arc<Mutex<T>>`) around these calls — concurrency safety is jj-lib's own op-heads + working-copy file locking (AD-2, FR-MCP-9); the concurrent_writes.rs test proves this, it doesn't add locking.
- Never let `abandoned_change_ids` reflect jj-lib's internal "trivial previous-@ auto-abandoned by `edit()`" side effect — only `Repo::abandon`'s own explicit input ids, echoed verbatim (a resolved-change-id can't be re-resolved once abandoned; this also keeps the four mutations' result shape simple, per the AC's silence on this for describe/new/edit).
- Never touch `zanshin-ffi` or `docs/rust-error-codes.md` — this story is `zanshin-jj`-only; FFI exposure is Story 6.5.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Describe happy path | `describe(id, "New description")` | New commit (same change id) with new description; op-log records it; `working_copy_change_id` reflects post-commit `@` | — |
| Describe empty string | `describe(id, "")` | Description set to `""`; `Change::is_anonymous` (Story 2.6) becomes `true` | — |
| Describe not found | `describe(bogus_id, "x")` | — | `Err(ChangeNotFound { id })` |
| New, one parent | `new_change(&[p])` | New empty change, child of `p`; working copy points at it; `new_change_ids = [new_id]` | — |
| New, multiple parents | `new_change(&[p1, p2])` | Merge commit with both parents (merged tree via `merge_commit_trees`) | — |
| New, empty parents | `new_change(&[])` | — | `Err(InvalidInput { reason })` |
| Edit happy path | `edit(id)` | Working copy switches to `id`, no new commit created; op-log records it | — |
| Abandon, non-`@` change | `abandon(&[id])` | `id` gone from visible DAG; `new_change_ids = []`; `abandoned_change_ids = [id]` | — |
| Abandon, `@` itself | `abandon(&[wc_id])` | jj-lib auto-creates new `@` at parent (`update_wc_commits`); `new_change_ids = [auto_created_id]` | — |
| Abandon, empty slice | `abandon(&[])` | — | `Err(InvalidInput { reason: "abandon requires at least one change id" })` |

</intent-contract>

## Code Map

- `crates/zanshin-jj/src/mutate.rs` -- NEW. `MutationResult`, `MutateError`, and `pub(crate) fn describe/new_change/edit/abandon(workspace: &mut Workspace, ...)` — mirrors `op_log.rs`'s free-fn-per-noun pattern.
- `crates/zanshin-jj/src/repo.rs:94-259` -- existing single `impl Repo` block; ALL other noun modules' logic is delegated to from here (e.g. `op_log` at :137-151, `get_change` at :123-136). Add 4 new `&mut self` methods here delegating to `crate::mutate::*`, plus a `pub(crate) fn workspace_mut(&mut self) -> &mut Workspace` accessor beside the existing `workspace(&self)` at :100-104.
- `crates/zanshin-jj/src/repo.rs:334-461` (`clone_into`) -- the ONLY existing production transaction code; shows the exact `start_transaction`/`tx.repo_mut()`/`rebase_descendants`/`tx.commit`/post-commit `workspace.check_out` sequence to replicate. `NoopCallback` at the top of the file is fetch-specific — not needed here.
- `crates/zanshin-jj/src/change.rs:145-232` (`get_change`) -- the `ChangeId` (reverse-hex) → jj-lib `Commit` resolution pattern to reuse for every change-id argument (the empty-string guard at line ~163 matters — `try_from_reverse_hex("")` is NOT itself a safe not-found signal).
- `crates/test-helpers/src/lib.rs` (`add_commit_off_root`, `describe_commit`, `abandon_commit`) -- proven jj-lib call sequences for exactly these 3 of the 4 mutations (test-only code, but real jj-lib API); `edit` has no existing precedent in this repo.
- `crates/zanshin-jj/src/lib.rs:30-54` -- module declarations + the crate's re-export list; add `mutate` alongside the other `pub(crate) mod`s.
- `crates/zanshin-jj/tests/api_stability.rs` -- structural surface-pin test (AC-8/FR-JJ-16); add aliases/constructions for the two new public types.
- `crates/zanshin-jj/tests/change.rs:53-85` (`jj_new_with_description`) -- an existing test-only "new" helper using the lower-level `set_wc_commit` (no auto-abandon side effect) — NOT the pattern to copy for production `new_change` (use `edit()` instead, per Boundaries).

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/src/mutate.rs` -- add `MutationResult`, `MutateError`, `describe`, `new_change`, `edit`, `abandon` -- the story's core deliverable
- `crates/zanshin-jj/src/repo.rs` -- add `workspace_mut()` + 4 delegating `&mut self` methods -- wires mutate.rs into `Repo`'s public surface per the established per-noun delegation pattern
- `crates/zanshin-jj/src/lib.rs` -- `pub(crate) mod mutate;` + `pub use mutate::{MutationResult, MutateError};` -- exposes the new types
- `crates/zanshin-jj/tests/mutate.rs` -- NEW integration tests against the `tiny-3-commits` fixture -- covers every I/O-matrix row above plus the op-log-matches-mutation AC
- `crates/zanshin-jj/tests/concurrent_writes.rs` -- NEW ~80-100 line test: two `std::thread`s, each with its own `Repo::open` handle on the same tempdir repo, run interleaved `describe`+`new_change` calls -- WIP-rework append; exercises FR-MCP-9 same-repo concurrency (no spurious errors, no misinterpreted jj warnings)
- `crates/zanshin-jj/tests/api_stability.rs` -- add `_MutationResult`/`_MutateError` type aliases + a trivial `MutateError::Backend(String::new())` construction -- keeps the structural surface-pin test complete

**Acceptance Criteria:**
- Given `crates/zanshin-jj/src/mutate.rs`, when created, it defines the four `Repo` methods with exactly the signatures in epics.md Story 6.1 (`describe(&mut self, change_id: ChangeId, description: &str)`, `new_change(&mut self, parents: &[ChangeId])`, `edit(&mut self, change_id: ChangeId)`, `abandon(&mut self, change_ids: &[ChangeId])`), all returning `Result<MutationResult, MutateError>`.
- Given any successful mutation, when `Repo::op_log(Some(1))` is read afterward, then the most recent operation's description matches the CLI-parity string from Boundaries (NFR-R-2).
- Given a mutation that does NOT change the working-copy commit (e.g. describing a non-`@`, non-ancestor-of-`@` change), when it commits, then no `workspace.check_out` call happens (verify via a test asserting the working-copy file mtime/content is untouched, or by construction/code review).
- Given `crates/zanshin-jj/tests/concurrent_writes.rs`, when both threads' transactions land, then neither thread observes an error from jj-lib's own locking, and `Repo::op_log(None)` shows both operations in the final repo state.
- Given `cargo test -p zanshin-jj` and `cargo make test`, when run, then all pass, including clippy pedantic (`-D warnings`) and the coverage ratchet (new file ≥ 80% floor, `coverage-baseline.txt` updated and committed).

## Spec Change Log

## Review Triage Log

### 2026-08-24 — Review pass
- intent_gap: 0
- bad_spec: 0
- patch: 5: (high 2, medium 3, low 0)
- defer: 12: (high 0, medium 5, low 7)
- reject: 1: (high 0, medium 0, low 1)
- addressed_findings:
  - `high` `patch` `describe`/`abandon` targeting the root commit's change id panicked via jj-lib's internal `assert_ne!` instead of returning a `MutateError` (Edge Case Hunter). Added an explicit root-commit guard in both functions returning `MutateError::InvalidInput`; added regression tests `describe_root_commit_returns_invalid_input_not_a_panic` / `abandon_root_commit_returns_invalid_input_not_a_panic`.
  - `medium` `patch` `resolve_commit` silently mutated an arbitrary commit for a divergent change id instead of refusing, unlike the CLI (Blind Hunter + Edge Case Hunter, deduplicated). Added an `is_divergent`-equivalent guard (reject when more than one visible target) returning `MutateError::ChangeNotFound`; added regression test `every_mutation_returns_change_not_found_for_a_divergent_change_id`.
  - `medium` `patch` No test verified the POSITIVE on-disk working-copy checkout path (a dropped/inverted `workspace.check_out` call for `edit`/`new_change`/`abandon`-of-`@` would ship undetected) — only the negative "must not checkout" case was tested (Verification Gap). Added a before/after checkout-file byte-comparison assertion to `new_change_single_parent_creates_empty_child_and_switches_wc`.
  - `medium` `patch` No test verified `abandon`'s `delete_abandoned_bookmarks: true` side effect (Verification Gap). Added `abandon_deletes_bookmarks_pointing_only_at_the_abandoned_commit` using `test_helpers::set_local_bookmark` + `Repo::list_bookmarks()`.

## Design Notes

**describe** (single target):
```rust
let commit = resolve_change_id(tx.repo(), &change_id)?;   // change.rs pattern, MutateError-mapped
let rewritten = tx.repo_mut().rewrite_commit(&commit).set_description(description).write().await?;
tx.repo_mut().rebase_descendants().await?;
let new_repo = tx.commit(format!("describe commit {}", commit.id().hex())).await?;
```

**new_change** (N parents; resolve each `ChangeId` first, collect `Vec<Commit>`):
```rust
let merged_tree = jj_lib::rewrite::merge_commit_trees(tx.repo(), &parent_commits).await?;
let new_commit = tx.repo_mut().new_commit(parent_ids, merged_tree).write().await?;
tx.repo_mut().rebase_descendants().await?;   // matches CLI; usually a no-op here
tx.repo_mut().edit(workspace_name, &new_commit).await?;   // NOT check_out — see Boundaries
let new_repo = tx.commit("new empty commit").await?;
```

**edit**: identical shape to `new_change` minus the `new_commit`/`merge_commit_trees` steps — resolve the target commit, `tx.repo_mut().edit(workspace_name, &commit).await?`, commit with `format!("edit commit {}", commit.id().hex())`.

**abandon** (the trickiest — read this twice):
```rust
for commit in &commits { tx.repo_mut().record_abandoned_commit(commit); }  // sync, no Result
let opts = RebaseOptions { rewrite_refs: RewriteRefsOptions { delete_abandoned_bookmarks: true }, ..Default::default() };
tx.repo_mut().rebase_descendants_with_options(&opts, |_, _| {}).await?;
let new_repo = tx.commit(/* singular/plural format from Boundaries */).await?;
// abandoned_change_ids = the caller's own input, echoed (do NOT re-resolve post-commit).
// If @ was among the abandoned ids, jj-lib's update_wc_commits already built a fresh
// empty commit at the (merged) parent(s) and repointed the view automatically — read
// it back via new_repo.view().get_wc_commit_id(&workspace_name) for new_change_ids.
```

**Shared "sync on-disk working copy" step** (all four functions, at the very end, AFTER `tx.commit()`): capture `old_wc_commit_id`/`old_tree` BEFORE `start_transaction`; after commit, `if new_repo.view().get_wc_commit_id(&workspace_name) != old_wc_commit_id.as_ref() { let new_wc_commit = new_repo.store().get_commit(new_id)?; workspace.check_out(new_repo.op_id().clone(), old_tree.as_ref(), &new_wc_commit).map_err(be)?; }`. This one check covers new_change/edit directly AND describe/abandon's indirect case (descendant-rebase moves `@`, or `@` was abandoned).

## Verification

**Commands:**
- `cargo test -p zanshin-jj` -- expected: new `tests/mutate.rs` + `tests/concurrent_writes.rs` pass, existing suite unaffected
- `cargo clippy -p zanshin-jj -- -D warnings` -- expected: clean (pedantic on)
- `cargo make test` -- expected: full gate passes (clippy, rustfmt, `flutter test`/`dart analyze` unaffected by this Rust-only change, `cargo deny`, coverage ratchet); commit the updated `coverage-baseline.txt`

## Auto Run Result

**Summary:** Implemented Story 6.1's four P0 mutations in a new `crates/zanshin-jj/src/mutate.rs`, wired through `Repo::{describe, new_change, edit, abandon}`. Every mutation opens a jj-lib transaction, mutates via `tx.repo_mut()`, and commits with the real `jj` CLI's own op-log description string (verified against `../jj` at `v0.42.0`) — never shells to the `jj` binary. A planning-time gap (the `MutationResult` struct was missing the AC-mandated `new_op_id: OperationId` field) was caught and fixed before the review pass. The review pass (Blind Hunter, Edge Case Hunter, Verification Gap, Intent Alignment Auditor) found and fixed two real panic-safety bugs (root-commit targets crashed the process instead of returning an error) plus a silent-arbitrary-target bug for divergent change ids, and closed two verification gaps (the positive on-disk-checkout path and `abandon`'s bookmark-deletion side effect were previously unasserted).

**Files changed:**
- `crates/zanshin-jj/src/mutate.rs` (new) — `MutationResult`, `MutateError` (`ChangeNotFound`/`InvalidInput`/`Backend`), `describe`/`new_change`/`edit`/`abandon`, plus shared helpers `resolve_commit`, `capture_old_wc`, `sync_working_copy`.
- `crates/zanshin-jj/src/repo.rs` — added `workspace_mut()` accessor and the four public `Repo` delegating methods.
- `crates/zanshin-jj/src/lib.rs` — `pub(crate) mod mutate;` + `pub use mutate::{MutateError, MutationResult};`.
- `crates/zanshin-jj/tests/mutate.rs` (new) — 15 tests covering every I/O-matrix row, the two panic-safety regressions, the divergent-id guard, and the two verification-gap fixes.
- `crates/zanshin-jj/tests/concurrent_writes.rs` (new) — two-thread same-repo concurrency smoke test (FR-MCP-9 / WIP-rework append).
- `crates/zanshin-jj/tests/api_stability.rs` — added `_MutationResult`/`_MutateError` structural surface-pin entries, including a `sample_mutation_result()` naming every field.
- `coverage-baseline.txt` — `crates/zanshin-jj/src/mutate.rs` raised to 94.55%; `crates/zanshin-jj/src/repo.rs` raised to 92.72%.

**Review findings breakdown:** 5 patch (2 high, 3 medium) — all applied and re-verified; 12 defer (5 medium, 7 low) — logged in frontmatter `deferred`, mostly CLI-parity refinements explicitly beyond "P0 essentials" scope (immutable-heads guard, no-op short-circuits, abandon skip-hidden/dedup, bookmark/conflict reporting, bookmark auto-advance, deeper concurrency racing, FFI-layer concurrency test, live-CLI-oracle testing); 1 reject (low) — an "unexplained coverage percentage" finding already covered by the coverage ratchet gate.

**Verification performed:** `cargo test -p zanshin-jj` (all suites green, including 15/15 `mutate.rs` + 1/1 `concurrent_writes.rs`), `cargo clippy -p zanshin-jj --all-targets -- -D warnings` (clean), `cargo fmt -p zanshin-jj -- --check` (clean), and three full `cargo make test` runs (clippy workspace-wide, rustfmt, `flutter test`, `dart analyze`/`format`, `cargo deny`, jj-adapter-hygiene, coverage ratchet) — all exit 0. The Matrix Test Audit confirmed every I/O-matrix row is covered by a test that ran and passed.

**Residual risks:** the 12 deferred findings (see frontmatter) are real, reviewer-identified gaps versus full CLI parity — none are data-loss or crash risks (those were fixed as patches), but a caller relying on full `jj describe`/`jj new`/`jj abandon` CLI-observable behavior (no-op short-circuiting, bookmark auto-advance/deletion reporting, immutable-commit refusal) will see a narrower P0 surface until a later story (Epic 9's operation-surface build-out, per its own charter, is the natural home) picks them up. An unrelated, recurring, inert change to `app/analysis_options.yaml` (adds excludes for platform directories that don't exist in this repo) reappears every time the Dart/Flutter toolchain runs as part of `cargo make test`; it was reverted from this story's diff each time and left untouched on disk otherwise — worth a look outside this story if it keeps recurring.
