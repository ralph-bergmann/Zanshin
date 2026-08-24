---
title: 'Story 6.2: Op-log undo (P0)'
type: 'feature'
created: '2026-08-24'
status: 'done'
baseline_revision: '7578cb20db27a82cb56bb365a09d1eb875d17d93'
review_loop_iteration: 0
followup_review_recommended: true
context: []
warnings: ['oversized']
deferred:
  - summary: >-
      No test proves remote-tracking bookmarks round-trip through undo (restored_view
      restores remote_views from the target op, per DEFAULT_REVERT_WHAT, but nothing
      exercises this).
    evidence: |-
      Blind Hunter review pass. restored_view's other under-tested field — lower urgency
      than git_refs/git_head since remote-tracking is additive-restore, not a
      preservation-vs-revert distinction with an easy silent inversion.
    location: 'crates/zanshin-jj/src/op_log.rs (restored_view, undo)'
    severity: medium
  - summary: >-
      sync_working_copy can fail after tx.commit() already persisted the op, leaving a
      committed-but-unsynced on-disk state with no distinct signal to the caller.
    evidence: |-
      Edge Case Hunter review pass. Inherited unchanged from Story 6.1's four mutations
      (describe/new_change/edit/abandon) — not introduced by this story, just reused.
    location: 'crates/zanshin-jj/src/mutate.rs:sync_working_copy; crates/zanshin-jj/src/op_log.rs:undo'
    severity: medium
  - summary: >-
      Three new undo tests manipulate .jj/repo/op_heads/heads/ directly, extending a
      pre-existing technique that couples the suite to jj-lib's on-disk op-store format
      across future version pins.
    evidence: |-
      Blind Hunter review pass. The technique itself predates this story (Story 2.7's
      corrupt-repo test); this story's NothingToUndo and merge-op tests extend it.
    location: 'crates/zanshin-jj/tests/op_log.rs'
    severity: low
  - summary: >-
      sync_working_copy/restored_view only sync/restore the CURRENT workspace's on-disk
      checkout and wc_commit_ids entry in a multi-workspace repo; other workspaces'
      recorded @ pointers move in the view without their on-disk checkouts following.
    evidence: |-
      Blind Hunter review pass. Inherited unchanged from Story 6.1's mutations — a
      whole-crate scope boundary, not specific to undo.
    location: 'crates/zanshin-jj/src/mutate.rs; crates/zanshin-jj/src/op_log.rs'
    severity: low
---

<intent-contract>

## Intent

**Problem:** `zanshin-jj` has no way to revert the last operation — a caller who just made a mistake (bad `describe`, unwanted `new_change`) has no undo (FR-JJ-14a).

**Approach:** Extend `crates/zanshin-jj/src/op_log.rs` with `pub(crate) fn undo(workspace: &mut Workspace) -> Result<MutationResult, MutateError>`, backing a new `Repo::undo(&mut self)` in `repo.rs`. A thin, single-step walk-back: replace the current transaction's view with the current head operation's single parent's view (jj-lib has no CLI-parity undo-stack helper — WIP-rework explicitly drops that; see Design Notes), then commit as a new op. Reuses Story 6.1's `MutationResult`/`MutateError` and its `capture_old_wc`/`sync_working_copy` helpers (promoted to `pub(crate)`).

## Boundaries & Constraints

**Always:**
- Mirror the CLI's `cmd_undo` (`../jj` `v0.42.0` `cli/src/commands/undo.rs`) mechanism, NOT its "jump over old undo-stacks" description-prefix optimization (explicitly out of scope, per epic context — plain `undo()` only walks back one op from the CURRENT head, no history parsing).
- Op-log description on success: `format!("undo: restore to operation {}", target_op_parent.id().hex())` — verbatim CLI string (NFR-R-2 indistinguishability).
- View restore = the CLI's default `jj undo` behavior (`DEFAULT_REVERT_WHAT` = Repo + RemoteTracking, both always on for plain `undo`, no flag): the target parent op's `head_ids`/`local_bookmarks`/`local_tags`/`remote_views`/`wc_commit_ids` become current; `git_refs`/`git_head` stay at the CURRENT (pre-undo) view — reimplement `cli/src/commands/operation/mod.rs`'s `view_with_desired_portions_restored` inline (small, pure, single-use — CLI-only orchestration jj-lib doesn't expose).
- No `rebase_descendants()` call — a raw `set_view` records no rewrites, matching the CLI (which doesn't call it either).
- After `tx.commit()`, reuse `mutate::capture_old_wc`/`mutate::sync_working_copy` (before/after respectively) for the same on-disk-checkout-sync-only-if-`@`-moved behavior as Story 6.1's four mutations.
- A head op with >1 parents (a real, reachable state — jj-lib silently persists a "reconcile divergent operations" merge op on the next `load_at_head()` after racing writers, per `tests/concurrent_writes.rs`) MUST return `MutateError::InvalidInput { reason: "cannot undo a merge operation" }`, mirroring the CLI's own refusal (`cli/src/commands/undo.rs`: `at_most_one()` → `user_error("Cannot undo a merge operation")`) — never silently pick one parent (NFR-R-2: never invent a nicer outcome than the CLI's refusal).
- `MutationResult.new_change_ids` / `.abandoned_change_ids` are always empty for `undo` (it restores state, it doesn't mint or abandon anything) — extend those two fields' doc comments in `mutate.rs` to name `undo` alongside `describe`/`new_change`/`edit`.

**Block If:** none identified — the CLI source and jj-lib API fully resolve the call sequence.

**Never:**
- Never replicate the CLI's `UNDO_OP_DESC_PREFIX` linked-list-jump-over logic (redo works correctly without it — see Design Notes).
- Never shell to `jj undo` (AR-AP-1).
- Never touch `zanshin-ffi` — this story is `zanshin-jj`-only (Story 6.5 exposes it over FFI).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Undo a describe | `describe` then `undo()` | Description reverts to prior value; op-log head = new "undo: restore to operation …" op | — |
| Undo a new_change | `new_change` then `undo()` | New change no longer visible; `@` returns to prior change id | — |
| Undo twice in a row | `mutate()`, `undo()`, `undo()` again | 2nd undo's target = 1st undo op's own parent = the post-mutation op → redoes the mutation | — |
| Nothing to undo | head op IS the root op (no parents) | — | `Err(MutateError::NothingToUndo)` |
| Merge op at head | head op has >1 parents (divergent-write reconciliation) | — | `Err(MutateError::InvalidInput{reason: "cannot undo a merge operation"})` |

</intent-contract>

## Code Map

- `crates/zanshin-jj/src/op_log.rs` -- add `pub(crate) fn undo(workspace: &mut Workspace) -> Result<MutationResult, MutateError>` + private `restored_view(target: &op_store::View, current: &op_store::View) -> op_store::View` helper -- the story's core deliverable; add `use jj_lib::op_store;` and `use crate::mutate::{self, MutateError, MutationResult};`.
- `crates/zanshin-jj/src/mutate.rs:107-139` (`capture_old_wc`, `sync_working_copy`) -- change from private `fn` to `pub(crate) fn` (same signatures) so `op_log.rs` can call them; no behavior change. Also extend `MutationResult`'s `new_change_ids`/`abandoned_change_ids` doc comments (lines ~29-37) to mention `undo`. Add `NothingToUndo` (unit variant, `#[error("nothing to undo")]`) to `MutateError` (lines ~46-67).
- `crates/zanshin-jj/src/repo.rs:333-335` (`abandon` delegate, end of the mutation group) -- add `pub fn undo(&mut self) -> Result<crate::MutationResult, crate::MutateError> { crate::op_log::undo(self.workspace_mut()) }` right after, matching the existing delegation pattern exactly (doc comment + `#[must_use]`).
- `../jj` `v0.42.0` `cli/src/commands/undo.rs` -- behavioral reference: `cmd_undo`'s core (minus the `UNDO_OP_DESC_PREFIX` jump-over block, explicitly deferred) — target = head op's single parent; `at_most_one()` parent-count guard; `tx.finish(..., format!("{UNDO_OP_DESC_PREFIX}{}", target_op_parent.id().hex()))`.
- `../jj` `v0.42.0` `cli/src/commands/operation/mod.rs:87-117` (`DEFAULT_REVERT_WHAT`, `view_with_desired_portions_restored`) -- the view-merge logic to reimplement inline as `restored_view` (with `what` hardcoded to "always both", since plain `jj undo` never exposes the flag).
- `jj-lib 0.42.0` (vendored: `~/.cargo/registry/.../jj-lib-0.42.0/src/`): `operation.rs:105` (`Operation::parent_ids(&self) -> &[OperationId]`, sync, no lookup needed), `repo.rs:808` (`RepoLoader::load_operation(&self, id: &OperationId) -> OpStoreResult<Operation>`), `repo.rs:1887` (`MutableRepo::set_view(&mut self, data: op_store::View)`), `repo.rs:300` (`ReadonlyRepo::operation(&self) -> &Operation`), `op_store.rs:249-264` (`op_store::View`'s 7 public fields).
- `crates/zanshin-jj/tests/op_log.rs` -- extend (existing file, existing `pin_env`/`make_test_settings`/`oracle_workspace` helpers) with the undo tests; reuse `crates/zanshin-jj/tests/mutate.rs`'s `oracle_layout`/`Layout` pattern (or a trimmed copy) for change-id targets on `tiny-3-commits`.
- `crates/zanshin-jj/tests/op_log.rs:270-288` (`op_log_on_corrupt_repo_returns_backend_error`) -- precedent for direct `.jj/repo/op_heads/heads/<hex>` file manipulation (empty marker files, named by op hex — `simple_op_heads_store.rs:79-99`); reuse this technique to engineer BOTH the `NothingToUndo` state (unreachable via `Repo::init`/`open`/`clone` alone, since `Workspace::init_*` always commits an "add workspace" op on top of root) and the merge-op state (see Design Notes for both recipes).
- `crates/zanshin-jj/tests/api_stability.rs:204-206` -- add `_ = zanshin_jj::MutateError::NothingToUndo;` alongside the existing `Backend`/`sample_mutation_result()` lines.

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/src/mutate.rs` -- widen `capture_old_wc`/`sync_working_copy` to `pub(crate)`, add `MutateError::NothingToUndo`, extend `MutationResult` field docs -- enables reuse from `op_log.rs`
- `crates/zanshin-jj/src/op_log.rs` -- add `undo` + `restored_view` -- the core deliverable
- `crates/zanshin-jj/src/repo.rs` -- add `pub fn undo(&mut self)` delegate -- wires it into `Repo`'s public surface
- `crates/zanshin-jj/tests/op_log.rs` -- add tests covering every I/O-matrix row, including the merge-op divergence test (marker-file choreography, see Design Notes)
- `crates/zanshin-jj/tests/api_stability.rs` -- pin the new `MutateError::NothingToUndo` variant

**Acceptance Criteria:**
- Given `Repo::undo()` called after a `describe`, when it commits, then `Repo::op_log(Some(1))`'s newest entry's description is `"undo: restore to operation <parent-hex>"` and the description change is reverted.
- Given `Repo::undo()` called twice in a row after one mutation, when both commit, then the op-log has grown by exactly 2 new ops and the 2nd `undo()`'s resulting state matches the post-mutation (pre-first-undo) state (redo).
- Given `cargo test -p zanshin-jj` and `cargo make test`, when run, then all pass, including clippy pedantic (`-D warnings`), rustfmt, and the coverage ratchet (updated `coverage-baseline.txt` committed).

## Spec Change Log

## Review Triage Log

### 2026-08-24 — Review pass
- intent_gap: 0
- bad_spec: 0
- patch: 4: (high 1, medium 0, low 3)
- defer: 4: (high 0, medium 2, low 2)
- reject: 6: (high 0, medium 0, low 6)
- addressed_findings:
  - `high` `patch` No test proved `restored_view`'s `git_refs`/`git_head` preservation (held at CURRENT, not reverted to `target`) — a silently-invertible regression that all 7 existing tests would miss (Verification Gap + Blind Hunter + Intent Alignment, deduplicated). Added a colocated-git test constructing a `git_refs`/`git_head` divergence between the undo target and current op, asserting they survive `undo()` unchanged.
  - `low` `patch` The base describe+undo test never captured a before/after op-log count, so epics.md's literal AC ("verify the op-log has 2 new ops") wasn't directly asserted for the single-undo case (Intent Alignment Auditor). Extended `undo_reverts_a_describe_and_records_op_log_entry` to assert the op count grew by exactly 2.
  - `low` `patch` `op_log.rs`'s new `mutate_be` duplicated `mutate.rs`'s existing private `be` helper (Blind Hunter). Widened `mutate::be` to `pub(crate)` and removed the duplicate, updating `undo`'s call sites.
  - `low` `patch` `MutateError::NothingToUndo`'s doc comment didn't explain it's currently unreachable via the public `Repo` API (Blind Hunter). Added a note that `Workspace::init_*` always commits an op on top of root, so this variant only fires against a hand-crafted/externally-mutated op-store — a defensive CLI-parity guard, not a normally-reachable path.

Deferred (pre-existing patterns surfaced incidentally, not caused by this story): no test proves remote-tracking bookmarks round-trip through `undo` (Blind Hunter, medium — `restored_view`'s other under-tested field, lower urgency than git_refs/git_head since remote-tracking is additive-restore not preservation-vs-revert); `sync_working_copy` can fail after `tx.commit()` already persisted the op, leaving a committed-but-unsynced state with no distinct signal — inherited unchanged from Story 6.1's four mutations (Edge Case Hunter, medium); three new tests manipulate `.jj/repo/op_heads/heads/` directly, extending a pre-existing technique (Story 2.7's corrupt-repo test) that couples the suite to jj-lib's on-disk op-store format across future version pins (Blind Hunter, low); `sync_working_copy`/`restored_view` only sync/restore the CURRENT workspace's on-disk checkout in a multi-workspace repo, an inherited limitation from Story 6.1 (Blind Hunter, low).

Rejected (explicitly out of scope per the epic/story intent itself, not merely the spec's paraphrase): the CLI's `UNDO_OP_DESC_PREFIX` "jump over old undo-stacks" chaining/redo-stack logic — epic-6-context.md states this is "explicitly out of scope" (no jj-lib helper exists; CLI-only orchestration) and epics.md's own WIP-rework note shrinks Story 6.2 to a thin one-step wrapper (Blind Hunter); dedicated tests for `undo()` after `abandon()`/`edit()` — the restore mechanism is agnostic to which mutation preceded it, and epics.md's ACs only exemplify describe/new_change (Blind Hunter, 2 findings); FFI/error-taxonomy follow-up for the new error variant — the spec's own boundaries state "Never touch `zanshin-ffi` — this story is `zanshin-jj`-only (Story 6.5 exposes it over FFI)" (Blind Hunter); the CLI's "undoing a push operation" warning and `jj redo` hint — interactive terminal-UX chatter Zanshin explicitly replaces, and `git push` itself is deferred out of WIP scope entirely (Blind Hunter); `MutationResult.new_change_ids`/`.abandoned_change_ids` always empty for `undo` — an intentional, spec-mandated design consistent with those fields' existing "minted/abandoned BY this mutation's own action" semantics from Story 6.1, not an oversight (Blind Hunter).

## Design Notes

**Why not the CLI's `UNDO_OP_DESC_PREFIX` jump-over logic:** the epic context is explicit that this is out of scope ("jj's stack semantics (description-prefix detection) are CLI-only orchestration with no jj-lib helper... explicitly out of scope"). The "undo twice = redo" AC still holds WITHOUT it: each `undo()` call always targets the CURRENT head's single parent (not a description-parsed target), so `undo()` after `undo()` naturally targets the first undo op's parent — which IS the original post-mutation op — reproducing that state. Verified by hand-tracing: op1 (mutate) → op2 ("undo: restore to op0", view=op0) → op3 ("undo: restore to op1", target=op2's parent=op1, view=op1) = the mutated state. No prefix-parsing needed for this specific AC.

**`undo` core (op_log.rs):**
```rust
let readonly = pollster::block_on(workspace.repo_loader().load_at_head()).map_err(be)?;
let head_op = readonly.operation().clone();
let parent_ids = head_op.parent_ids();
if parent_ids.is_empty() { return Err(MutateError::NothingToUndo); }
let [target_parent_id] = parent_ids else {
    return Err(MutateError::InvalidInput { reason: "cannot undo a merge operation".to_owned() });
};
let workspace_name = workspace.workspace_name().to_owned();
let (old_wc_id, old_tree) = mutate::capture_old_wc(&readonly, &workspace_name)?;
let target_parent = pollster::block_on(workspace.repo_loader().load_operation(target_parent_id)).map_err(be)?;
let target_view = pollster::block_on(target_parent.view()).map_err(be)?;
let mut tx = readonly.start_transaction();
tx.repo_mut().set_view(restored_view(target_view.store_view(), readonly.view().store_view()));
let new_repo = pollster::block_on(tx.commit(format!("undo: restore to operation {}", target_parent.id().hex()))).map_err(be)?;
// then mutate::sync_working_copy(...) + build MutationResult (new_change_ids/abandoned_change_ids empty)
```

**`NothingToUndo` test is unreachable via `Repo::init`/`open`:** jj-lib's `Workspace::init_with_factories` → `init_working_copy` ALWAYS commits an `"add workspace 'default'"` op on top of root (`workspace.rs:143-149`), so a freshly-opened repo's head always has ≥1 parent. Engineer the state directly: after `Repo::init`, read the head + root hex ids via `repo.op_log(...)`, then in `.jj/repo/op_heads/heads/`, `fs::remove_file` the head's marker and `fs::write` an empty file named after the root's hex (mirrors the existing corrupt-repo test's technique) — a fresh `Repo::open` then resolves head == root directly.

**Merge-op guard test — deterministic marker-file choreography (no threads, no flakiness):** a real 2-parent op-heads state needs two sibling ops off the same parent, both present as `op_heads/heads/` markers simultaneously — `tests/concurrent_writes.rs`'s real-thread race proves this state is reachable in production, but a thread race is unsuitable for a deterministic unit test. Build it by hand instead:
1. `Repo::open` handle A on `tiny-3-commits`; note `h0` = current head hex (`repo.op_log(Some(1))`).
2. Handle A: `repo.describe(commit1_id, "A")` → new head `h1` (jj-lib's commit already removed the `h0` marker and added `h1`).
3. Rewind: `fs::remove_file(heads_dir.join(h1))`, `fs::write(heads_dir.join(h0), "")` — `op_heads/heads/` now has only `h0` again, as if step 2 never happened.
4. Fresh `Repo::open` handle B (unaware of `h1`): `repo_b.describe(commit3_id, "B")` → new head `h2`, a genuine sibling of `h1` (both children of `h0`, divergent content since they describe different commits).
5. Restore divergence: `fs::write(heads_dir.join(h1), "")` — `op_heads/heads/` now has BOTH `h1` and `h2` (jj-lib's own commit already left `h2`'s marker in place).
6. Fresh `Repo::open` handle C; `repo_c.undo()` — its internal `load_at_head()` observes 2 markers, jj-lib synchronously persists a "reconcile divergent operations" merge op (parents = `[h1, h2]` or `[h2, h1]`) as the new sole head, and `undo()`'s parent-count guard sees `parent_ids().len() == 2` → `Err(MutateError::InvalidInput{reason: "cannot undo a merge operation"})`.

`heads_dir` = `fx.path.join(".jj").join("repo").join("op_heads").join("heads")` (matches `simple_op_heads_store.rs:66-77`'s `dir.join("heads")`, `dir` being `.jj/repo/op_heads`).

## Verification

**Commands:**
- `cargo test -p zanshin-jj` -- expected: new `tests/op_log.rs` undo tests pass, existing suite unaffected
- `cargo clippy -p zanshin-jj --all-targets -- -D warnings` -- expected: clean (pedantic on)
- `cargo make test` -- expected: full gate passes (clippy workspace-wide, rustfmt, `flutter test`/`dart analyze` unaffected, `cargo deny`, coverage ratchet); commit the updated `coverage-baseline.txt`

## Auto Run Result

**Summary:** Implemented `Repo::undo()` (FR-JJ-14a) as a thin, single-step op-log walk-back: `crates/zanshin-jj/src/op_log.rs` gained `pub(crate) fn undo` + a private `restored_view` helper that replaces the current transaction's view with the head operation's single parent's view — mirroring the CLI's default (unflagged) `jj undo` field selection (repo state + local bookmarks/tags + remote-tracking restored from the target op; `git_refs`/`git_head` held at the CURRENT pre-undo value) — then commits with the CLI's verbatim `"undo: restore to operation {hex}"` op-log description. Deliberately omits the CLI's `UNDO_OP_DESC_PREFIX` "jump over old undo-stacks" chaining logic (explicitly out of scope per the epic context); the "undo twice = redo" AC still holds because each call always targets the current head's own parent. A head op with >1 parents (a real, reachable state after racing writers reconcile) is refused with `MutateError::InvalidInput{reason: "cannot undo a merge operation"}`, mirroring the CLI's own refusal rather than silently picking one parent. Reused Story 6.1's `MutationResult`/`MutateError` types and its `capture_old_wc`/`sync_working_copy` helpers (widened to `pub(crate)`) rather than duplicating them.

**Files changed:**
- `crates/zanshin-jj/src/op_log.rs` — added `undo`, `restored_view`, and (post-review) reused `mutate::be` instead of a duplicate local error-conversion helper.
- `crates/zanshin-jj/src/repo.rs` — added the public `Repo::undo(&mut self)` delegate, matching the existing per-noun delegation pattern used by `describe`/`new_change`/`edit`/`abandon`.
- `crates/zanshin-jj/src/mutate.rs` — widened `capture_old_wc`/`sync_working_copy`/`be` to `pub(crate)`; added `MutateError::NothingToUndo` (documented, post-review, as currently unreachable via this crate's own public API alone — `Workspace::init_*` always commits an op on top of root); extended `MutationResult`'s `new_change_ids`/`abandoned_change_ids` doc comments to name `undo`.
- `crates/zanshin-jj/tests/op_log.rs` — added 8 tests covering every I/O-matrix row plus (post-review) the git-refs/git-head preservation regression test, using deterministic `.jj/repo/op_heads/heads/` marker-file engineering (no threads) for the `NothingToUndo` and merge-op states.
- `crates/zanshin-jj/tests/api_stability.rs` — pinned `MutateError::NothingToUndo`.
- `coverage-baseline.txt` — `crates/zanshin-jj/src/mutate.rs` raised 94.55% → 96.04% (widening `be` to `pub(crate)` exposed more of it to the FFI-path coverage union); `op_log.rs` held at 100.00%.

**Review findings breakdown:** 4 patch (1 high, 0 medium, 3 low) — all applied and re-verified; 4 defer (0 high, 2 medium, 2 low) — logged in frontmatter `deferred` (remote-tracking-bookmark restore untested, `sync_working_copy`'s post-commit partial-failure signal inherited from Story 6.1, the `op_heads` marker-file test technique's jj-lib-version coupling, multi-workspace on-disk-sync scope inherited from Story 6.1); 6 reject (0 high, 0 medium, 6 low) — the CLI's undo-stack chaining/redo logic (explicitly out of scope per epic-6-context.md) and its "undoing a push operation" terminal warning (UX chatter Zanshin replaces; `git push` itself is deferred), undo-after-abandon/edit test requests (same restore mechanism already exercised by describe/new_change), FFI/error-taxonomy follow-up (explicitly Story 6.5's job), and `MutationResult`'s always-empty `new_change_ids`/`abandoned_change_ids` for `undo` (intentional, spec-mandated, consistent with those fields' Story 6.1 semantics).

**Follow-up review recommendation:** `true` — one `high`-severity patch was applied this pass (the git-refs/git-head preservation test), which alone triggers the threshold regardless of the `3×medium + 1×low` score (which was `0` for this pass, since the other three patches were all `low`).

**Verification performed:** Independently re-ran (not just trusted the implementation/patch subagents' self-reports) `cargo test -p zanshin-jj --test op_log` (19/19 pass, including all 8 undo tests), `cargo clippy -p zanshin-jj --all-targets -- -D warnings` (clean), `cargo fmt -p zanshin-jj -- --check` (clean), and two full `cargo make test` runs to convergence — the second (post-patch) run exit 0, coverage held/raised at 98.92%, `extern-coverage: OK`. Matrix Test Audit: all 5 I/O-matrix rows have a covering test that ran and passed. Reviewed the actual diff content directly (not just descriptions) for both the initial implementation and the patch round, including reading the new git-refs/git-head regression test's body to confirm it genuinely constructs a target/current divergence and would fail under a swapped-argument regression.

**Residual risks:** the 4 deferred findings (see frontmatter) are real but pre-existing-pattern or lower-urgency gaps, none data-loss or crash risks — `sync_working_copy`'s post-`tx.commit()` partial-failure case (op persisted, on-disk checkout unsynced, generic `Backend` error with no distinct signal) is the most consequential of the four but is inherited unchanged from Story 6.1's four mutations, not introduced here. The recurring, inert `app/analysis_options.yaml` toolchain side effect (noted in Story 6.1's own residual risks) reappeared on every `cargo make test` run in this story too and was reverted from the diff each time.
