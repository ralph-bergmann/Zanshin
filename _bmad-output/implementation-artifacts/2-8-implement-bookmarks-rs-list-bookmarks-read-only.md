---
baseline_commit: 66a7503
---

# Story 2.8: Implement `bookmarks.rs` — list bookmarks (read-only)

Status: done

<!-- Note: Validation is optional. Run validate-create-story for quality check before dev-story. -->

> **Scope-correction callout (binding overrides of epic prose):**
>
> 1. **Story 2.8 is PURE `zanshin-jj` Rust.** NO `extern "C"`, NO FlatBuffers, NO FFI, NO codegen, NO `docs/rust-error-codes.md` change, NO `Cargo.toml` change. The `zanshin_bookmarks` FFI wrapper is a **separate** story (`3-4b-zanshin-bookmarks-ffi-wrapper`, hard-gated on this one) and the `error.code` registry is minted at the FFI envelope layer, not here. This mirrors the 2.6/2.7 → 3.4b split exactly. [verified: sprint-status.yaml:76-77; epics.md:2147-2153]
> 2. **`-> Vec<Bookmark>` is refined to `-> Result<Vec<Bookmark>, BookmarkError>`.** The epic shows an infallible `Vec` (epics.md:1427,1437), but `load_at_head()` AND the per-target `store.get_commit()` (needed to resolve a bookmark's target **commit** to a **change id**) can fail, and every sibling read module returns `Result`. Add `pub enum BookmarkError { Backend(String) }` + a `be()` flatten helper (mirrors `OpLogError`/`StatusError`/`ChangeError`) (Decision D4 / OQ3). [verified: status.rs:52-65; change.rs:96-114; op_log.rs:49-61]
> 3. **`target: ChangeId` reuses `crate::ChangeId` (reverse-hex), resolved CommitId→ChangeId.** jj bookmarks point at **commits** (`RefTarget` over `CommitId`), not change ids. Resolve each target via `store.get_commit(commit_id)?.change_id().reverse_hex()` — the exact idiom `change.rs:172-176` / `status.rs:105-111` already use. Do NOT redefine `ChangeId` (it lives in `status.rs:48`); `use crate::ChangeId;`. **Reverse-hex** (the z-k display form), NOT forward-hex (op-log's `.hex()` is the exception) (Decision D2/D3). [verified: status.rs:48-49; change.rs:172-176,203; jj-lib commit.rs:171, op_store.rs:103,127]
> 4. **`Remote` is NOT re-exported in this story.** epics.md:1536 (a Story **2.10** documentation target) lists a *combined* final re-export set including `Bookmark`, `BookmarkKind`, **and `Remote`** — but `Remote` is the **Story 2.9** type (`remotes.rs`), which does not exist yet. Story 2.8 re-exports only `Bookmark`, `BookmarkKind` (+ the per-noun `BookmarkError`, following the pattern where every noun re-exports its error). Do NOT add `pub use ...Remote` here. [verified: epics.md:1477-1487 (2.9 `Remote`), 1536 (2.10 combined list); repo-wide search: no `Bookmark`/`BookmarkKind`/public `Remote` type exists yet]
> 5. **Remote-tracking bookmarks are constructed IN-TEST, not read from a fixture.** The committed fixtures have **ZERO** remote bookmarks: `tiny-3-commits` has no bookmarks at all, `medium-1k-commits` has exactly **29 LOCAL** bookmarks (`gen_fixture.rs:258-261` calls only `set_local_bookmark_target`; confirmed load-bearing by `tests/revset.rs:178` "fixture has no remote bookmarks"). So the `BookmarkKind::Remote` arm and the "local+remote-tracking pairing" AC (epics.md:1441-1443,1457) are exercised by **constructing** a local + tracked-remote bookmark in a transaction inside the integration test — exactly as `change.rs` constructs divergent/conflicted commits in-test rather than baking them into fixtures. NO fixture regeneration (Decision D6 / OQ1; see Test recipe). [verified: gen_fixture.rs:190-265; tests/revset.rs:146-158,178; jj-lib view.rs:629-668 `test_absent_tracked_bookmarks`; repo.rs:1751 `set_remote_bookmark`]
> 6. **Conflicted/divergent targets are handled by a single uniform `added_ids().next()` path** — NOT an `as_normal().or_else(...)` two-branch form. `RefTarget::added_ids()` yields the one commit for a normal target and the first add for a conflicted target (a normal target is a one-add merge), so one code path covers both — no untested conflict branch to drag the coverage ratchet. `is_conflicted`/`is_divergent` flags are epic-deferred ("this story's scope is just listing", epics.md:1448) (Decision D5 / OQ4). [verified: jj-lib op_store.rs:103,127]
> 7. **The `< 50 ms` figure is a SOFT design target, not a CI gate.** Performance assertions are deferred to the release phase — no blocking `assert!(elapsed < …)` in a non-`#[ignore]` test (parallel to 2.5 #3 / 2.6 #6 / 2.7 #8). [verified: project-context.md "Performance assertions — DEFERRED"; epics.md:341]

---

## Story

As a Rust caller wanting to display bookmarks,
I want `zanshin-jj` to expose `Repo::list_bookmarks() -> Result<Vec<Bookmark>, BookmarkError>` returning local and tracked-remote bookmarks (name, target change id, local/remote kind), sorted by name then kind,
so that the `zanshin_bookmarks` FFI wrapper (Story 3.4b) and the MCP `bookmarks` tool (Story 7.3, calls `zanshin-jj` directly) can render the bookmark list (FR-JJ-8), with all jj-lib API churn absorbed inside the adapter (FR-JJ-16).

## Acceptance Criteria

Grouped by deliverable. Each item is a checkable contract. Source is `epics.md#Story 2.8` (lines 1424-1473) unless noted; where this story corrects the epic, the correction is flagged inline and justified in the Scope-correction callout / Dev Notes.

### AC-1 — Public surface: `Repo::list_bookmarks` + module wiring (FR-JJ-8) [epics.md:1427,1432-1434]

1. `crates/zanshin-jj/src/bookmarks.rs` exists. `crates/zanshin-jj/src/repo.rs` gains a public method `pub fn list_bookmarks(&self) -> Result<Vec<crate::Bookmark>, crate::BookmarkError>` that delegates to a `pub(crate) fn bookmarks::list_bookmarks(workspace: &Workspace) -> Result<Vec<Bookmark>, BookmarkError>` (the established "method-on-`Repo` → `pub(crate)` free fn taking `&Workspace`" shape, mirroring `Repo::op_log` → `op_log::op_log`, `Repo::status` → `status::working_copy_status`).
2. The implementation is **synchronous** (no `async`, no `tokio`); the only async bridge is `pollster::block_on`, exactly as `status.rs:85` / `op_log.rs:73`.
3. No `jj_lib::*` type appears in the public signature of `list_bookmarks`, in the `Bookmark` / `BookmarkKind` types, or in any `BookmarkError` variant (FR-JJ-16).
4. The read **re-resolves to the head operation per call** (`workspace.repo_loader().load_at_head()`, ADR-0002) — it does not serve from a long-lived cached view.

### AC-2 — `Bookmark` + `BookmarkKind` shape (FR-JJ-8) [epics.md:1434; corrections per Scope-corrections #2,#3]

5. `bookmarks.rs` defines:
   ```rust
   /// One jj bookmark (local or tracked-remote) and its target change (FR-JJ-8).
   pub struct Bookmark {
       pub name: String,        // bookmark name, UTF-8 (jj-lib RefName)
       pub target: ChangeId,    // target change id, reverse-hex (crate::ChangeId, reused)
       pub kind: BookmarkKind,
   }

   /// Whether a bookmark is local or a tracked remote bookmark.
   pub enum BookmarkKind {
       Local,
       Remote { remote_name: String }, // always present; never None (may be "" — edge AC)
   }
   ```
   `Bookmark` derives `#[derive(Debug, Clone, PartialEq, Eq)]`; `BookmarkKind` derives `#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]` (the `Ord` powers the AC-4 sort: `Local` < `Remote`, then by `remote_name`). Every `pub` item carries a `///` doc comment (clippy pedantic). `target` is the crate-own `crate::ChangeId` (reused via `use crate::ChangeId;`), NOT a jj-lib type and NOT a re-definition.

### AC-3 — Lists local + tracked-remote, with local/remote pairing [epics.md:1436-1443]

6. `list_bookmarks()` returns every **local** bookmark (from `view.local_bookmarks()`) as a `Bookmark { kind: BookmarkKind::Local }`, and every **present + tracked remote** bookmark (from `view.all_remote_bookmarks()`, filtered `is_present() && is_tracked()`) as a `Bookmark { kind: BookmarkKind::Remote { remote_name } }`.
7. A bookmark that exists locally **and** is tracked from a remote yields **two** entries: one `Local`, one `Remote { remote_name: "<remote>" }` (the local and remote iterators are disjoint, so this falls out naturally). [epics.md:1441-1443]
8. On `medium-1k-commits` the result contains all **29 local** bookmarks (Scope-correction #5: the fixture has no remote bookmarks; the remote arm is exercised in-test — see AC-9). The result `Vec` is bounded by the actual bookmark count (no truncation). [epics.md:1437-1438,1461-1464]

### AC-4 — Sorting: alphabetical by name, then kind [epics.md:1439,1466-1469]

9. The result is sorted by `name` (Unicode codepoint order — jj-lib's convention), then by `kind` (`Local` before `Remote`, remotes among themselves by `remote_name`). Implement as `out.sort_by(|a, b| a.name.cmp(&b.name).then_with(|| a.kind.cmp(&b.kind)))` (relying on the derived `Ord` for `BookmarkKind`). Do NOT rely on the per-iterator order across the local/remote union — sort the merged `Vec` explicitly. [epics.md:1439]
10. A bookmark name with non-ASCII characters is preserved verbatim as a UTF-8 `String`; sorting is by codepoint order. [epics.md:1466-1469]

### AC-5 — Conflicted/divergent target → first added change id [epics.md:1445-1448; Scope-correction #6]

11. A bookmark whose `RefTarget` is conflicted (multiple added commits) appears with **one** target: the change id of the **first** `added_ids()` entry. Use `target.added_ids().next()` uniformly for normal AND conflicted targets (a normal target is a one-add merge) — do NOT branch on `as_normal()` vs conflict. No `is_conflicted`/`is_divergent` field this story (epic-deferred: "this story's scope is just listing", epics.md:1448). [verified: jj-lib op_store.rs:103,127]

### AC-6 — Queries jj-lib `View` directly; no CLI [epics.md:1450-1453]

12. The implementation queries jj-lib's `View` (`view.local_bookmarks()` + `view.all_remote_bookmarks()`) and **does NOT shell to `jj bookmark list`** (AR-AP-1) nor parse CLI output (AR-AP-2). `zanshin-jj` is the only crate importing `jj_lib`. [epics.md:1452-1453]

### AC-7 — `BookmarkError` enum + flatten helper [Scope-correction #2]

13. `#[derive(Debug, thiserror::Error)] pub enum BookmarkError { Backend(String) }` with `#[error("jj-lib error: {0}")]` and a `///` doc on the variant. `Backend(String)` is the opaque catch-all for any jj-lib failure (mirrors `OpLogError::Backend`). There is **no** "not found" variant — listing never misses.
14. A private `fn be<E: std::fmt::Display>(e: E) -> BookmarkError { BookmarkError::Backend(e.to_string()) }` flattens every jj-lib failure (`load_at_head`'s `RepoLoaderError`, `get_commit`'s `BackendError`) to `Backend(String)` via `Display` so no `jj_lib` type escapes (FR-JJ-16). [verified: status.rs:62-65; op_log.rs:59-61]

### AC-8 — Edge cases documented/handled [epics.md:1459-1473]

15. **Empty list** on `tiny-3-commits` (no bookmarks) → `Ok(Vec::new())` (no panic). [epics.md:1457]
16. **Absent/untracked remote refs are skipped.** `view.all_remote_bookmarks()` (unlike `local_bookmarks()`) is NOT pre-pruned: it can yield absent refs and `New` (untracked) refs. The `is_present() && is_tracked()` filter skips both. [verified: jj-lib view.rs:245-260, op_store.rs:161,171,190-196]
17. **`remote_name` is always a `String`, never `None`** — the `Remote` variant always carries the field; it is the empty string only in the theoretical empty-remote edge case (jj-lib does not forbid an empty remote name). [epics.md:1471-1473]

### AC-9 — Integration-test coverage [epics.md:1455-1457]

18. `crates/zanshin-jj/tests/bookmarks.rs` exists and covers **at minimum**:
    - **empty:** `tiny-3-commits` → `Ok` with an empty `Vec` (AC-8 #15);
    - **populated local:** `medium-1k-commits` → all 29 local bookmarks, asserted **by EQUALITY against an independent jj-lib oracle** (open the workspace independently, walk `view().local_bookmarks()`, build the expected `(name, kind, reverse_hex)` set) — never mere non-emptiness/count (carry-forward 2.4/2.6 hardening);
    - **local + tracked-remote pairing (constructed in-test):** in a fresh repo, set a local bookmark AND a tracked-remote bookmark for the same name+commit in one transaction; assert exactly two entries — one `BookmarkKind::Local`, one `BookmarkKind::Remote { remote_name }` — both targeting the same change id (AC-3 #7);
    - **absent/untracked remote skipped (constructed in-test):** also set an absent-tracked remote ref AND a present-`New`(untracked) remote ref in that transaction; assert NEITHER appears in the result (AC-8 #16) — this covers the `is_present()`/`is_tracked()` filter `continue` branches;
    - **sort:** results are sorted by `(name, kind)` (AC-4) — assert ordering on the constructed multi-bookmark repo;
    - **`BookmarkError::Backend`:** corrupt the repo while open (`Repo::init` a fresh `TempDir`, then `fs::remove_dir_all(.jj/repo/op_heads)`), then assert `list_bookmarks()` returns `Err(BookmarkError::Backend(_))` (mirror `op_log_on_corrupt_repo_returns_backend_error`, tests/op_log.rs).
19. Do **not** hard-code remote-bookmark counts from the committed fixtures (they have none) — derive local expectations from the medium oracle and assert the in-test-constructed remote entries structurally.

### AC-10 — Public-API hygiene + docs (Story 2.10 prerequisites) [epics.md:1536-1537; Scope-correction #4]

20. `lib.rs` adds `pub(crate) mod bookmarks;` and `pub use bookmarks::{Bookmark, BookmarkError, BookmarkKind};`. `crate::ChangeId` is reused (already re-exported from `status.rs` at lib.rs:19 — no new re-export). **No `pub use ...Remote`** is added (Scope-correction #4 — that is Story 2.9). No `pub use jj_lib::...` is added.
21. `Repo::list_bookmarks` carries a `///` doc comment **including a `# Errors` section** mapping `BookmarkError::Backend` to its trigger and a note that the read re-resolves to head per call (ADR-0002); carries `#[must_use = "the Result must be used; drop it explicitly if intentional"]`. The `pub(crate) fn list_bookmarks` carries the same `# Errors` section. Every new `pub` item is doc-commented (clippy pedantic).

### AC-11 — Quality gate green (coverage ratchet) [CLAUDE.md; docs/coverage.md]

22. `cargo make test` passes end-to-end: `cargo test`, `cargo clippy --workspace --all-targets -- -D warnings` (pedantic — **refactor, don't `#[allow]`**; any unavoidable suppression carries a `// WHY:`), `cargo fmt --all --check`, `cargo deny check advisories bans`, the Dart suite, and the **coverage ratchet** (`cargo make coverage`). The new file `crates/zanshin-jj/src/bookmarks.rs` reaches the per-file floor (≥ 80 %; aim for 100 % like `change.rs`/`op_log.rs`); the auto-raised `coverage-baseline.txt` entry is committed with the code. `crates/zanshin-jj/src/repo.rs` stays ≥ its current baseline (the one-line delegate is covered by any passing `list_bookmarks` integration test). **Never lower the baseline or add an `exclude_prefix` to dodge testing.** [verified: coverage-baseline.txt; CLAUDE.md coverage ratchet]

## Tasks / Subtasks

- [x] **T1 — Domain types** (AC: 5, 13)
  - [x] In `src/bookmarks.rs` (SPDX `// SPDX-License-Identifier: MIT` line 1): define `Bookmark` (`#[derive(Debug, Clone, PartialEq, Eq)]`) and `BookmarkKind` (`#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]`) with `///` docs. `use crate::ChangeId;` for the `target` field (do **not** redefine — D2). Doc-note that `remote_name` is always present.
- [x] **T2 — `BookmarkError` enum + `be` helper** (AC: 13, 14)
  - [x] `#[derive(Debug, thiserror::Error)] pub enum BookmarkError { #[error("jj-lib error: {0}")] Backend(String) }` with a per-variant `///`; `fn be<E: std::fmt::Display>(e: E) -> BookmarkError { BookmarkError::Backend(e.to_string()) }`.
- [x] **T3 — `list_bookmarks` body** (AC: 1, 2, 3, 4, 5, 6, 7, 8) — the verified call sequence (see Dev Notes)
  - [x] Reload to head: `let readonly = pollster::block_on(workspace.repo_loader().load_at_head()).map_err(be)?;` (ADR-0002, mirrors `status.rs:85`). `let view = readonly.view(); let store = readonly.store();` (`use jj_lib::repo::Repo as _;`).
  - [x] A `to_change` closure: `store.get_commit(commit_id).map_err(be)? .change_id().reverse_hex()` → `ChangeId(..)` (Note: `reverse_hex()` is an inherent method on jj-lib id types — `use jj_lib::object_id::ObjectId as _` is NOT needed, compiler confirmed).
  - [x] Local loop: `for (name, target) in view.local_bookmarks() { if let Some(cid) = target.added_ids().next() { push Local } }`.
  - [x] Remote loop: `for (symbol, remote_ref) in view.all_remote_bookmarks() { if !remote_ref.is_present() || !remote_ref.is_tracked() { continue; } if let Some(cid) = remote_ref.target.added_ids().next() { push Remote { remote_name: symbol.remote.as_str().to_owned() } } }`.
  - [x] `out.sort_by(|a, b| a.name.cmp(&b.name).then_with(|| a.kind.cmp(&b.kind)))`; return `Ok(out)`.
- [x] **T4 — `Repo::list_bookmarks` method** (AC: 1, 21)
  - [x] In `src/repo.rs` (after `op_log`): `pub fn list_bookmarks(&self) -> Result<Vec<crate::Bookmark>, crate::BookmarkError> { crate::bookmarks::list_bookmarks(self.workspace()) }` with `///` + `# Errors` + `#[must_use = "…"]`. Reuse the existing `workspace()` accessor (repo.rs:60) — do NOT re-add it.
- [x] **T5 — Wire module + re-exports** (AC: 20)
  - [x] `lib.rs`: add `pub(crate) mod bookmarks;` + `pub use bookmarks::{Bookmark, BookmarkError, BookmarkKind};` (rustfmt placed them alphabetically). **No `Remote` re-export** (Scope-correction #4).
- [x] **T6 — Docs** (AC: 21)
  - [x] `///` on every `pub` item; `# Errors` on `Repo::list_bookmarks` and the `pub(crate) fn`; `#[must_use]` on the method.
- [x] **T7 — Integration tests `tests/bookmarks.rs`** (AC: 18, 19)
  - [x] Mirror `tests/op_log.rs` scaffolding (ENV_GUARD/pin_env, make_test_settings, `oracle_workspace`, `extract_fixture`). Empty (tiny), local-oracle (medium), in-test local+remote pair, in-test absent/untracked skip, sort, Backend-error. Oracle equality; no hard-coded remote counts; no timing assert.
- [x] **T8 — Green gate** (AC: 22)
  - [x] `cargo make test` green incl. coverage ratchet; clippy pedantic; fmt; cargo deny. Committed the auto-raised `coverage-baseline.txt`. Public surface: no `jj_lib::` in any `bookmarks` public signature.

## Review Findings

_Code review 2026-06-25 — bmad-code-review: 6 parallel adversarial finder layers (Opus 4.8) + 6-agent adversarial verification + completeness critic. **Verdict: 22/22 ACs PASS**, all 7 scope-corrections honored, `cargo make test` independently re-run green (coverage 94.12% ≥ 80% floor). No correctness / safety / AC-functional defects. Items below are optional test-hardening — none block `done`._

- [x] [Review][Patch] Conflicted/divergent `RefTarget` first-added selection is unproven by tests [crates/zanshin-jj/tests/bookmarks.rs] — AC-5 #11. Code is CORRECT (`added_ids().next()` yields the first present add for normal AND conflicted targets, verified vs jj-lib op_store.rs:127 / merge.rs:288), but every test builds targets only via `RefTarget::normal`/`absent`, so a one-add target never proves "first-of-many". Fix: construct a divergent local bookmark via `RefTarget::from_legacy_form([], [id_a, id_b])` (or `from_merge`) from two distinct fixture `CommitId`s, then assert exactly one entry whose target == id_a's change id. ⚠️ Do NOT mirror `change.rs::make_conflicted_change` — that is a *tree* conflict, not a *RefTarget* conflict, and would not exercise this path.
- [x] [Review][Patch] Non-ASCII bookmark name + codepoint-order sort untested [crates/zanshin-jj/tests/bookmarks.rs] — AC-4 #10. Add a non-ASCII-named bookmark in the existing in-test transaction; assert the name round-trips byte-identical and sorts by codepoint vs an ASCII neighbor.
- [x] [Review][Patch] `BookmarkKind::Remote` doc reconciliation (DECISION RESOLVED 2026-06-25 by Ralph: flat model kept) [crates/zanshin-jj/src/bookmarks.rs:23-24] — align this doc-comment with the Dart side: `remote_name` is always PRESENT for a `Remote` entry (the empty-string edge stays only a theoretical value, never fabricated). Pairs with Story 3.4b Finding I.

_Dismissed in triage (recorded so future reviews don't re-litigate):_
- _`get_commit` in-loop error arm "uncovered" → misdiagnosed: `get_commit` is fully covered (151 hits). The only uncovered lines (91, 107) are the `if let Some` None-arms, provably unreachable (jj-lib guarantees a present local target has ≥1 added id; the local map is absent-pruned, view.rs:176-187). 94.12% ≥ 80% floor — gate passes; reaching 100% would require testing unreachable defensive code._
- _"Local bookmark with empty `added_ids` silently dropped" → provably unreachable (same invariants). The asymmetry vs the remote loop's explicit `is_present()/is_tracked()` filter is correct: `all_remote_bookmarks()` is NOT pre-pruned, `local_bookmarks()` is._
- _`to_change` closure dropped the explicit `&CommitId` annotation → cosmetic; the spec skeleton is non-binding, the inferred form is idiomatic and clippy-clean._

## Dev Notes

### Decision D1 — Module shape: `Repo::method` → `pub(crate) fn(&Workspace)` (mirror 2.4/2.6/2.7)

`src/bookmarks.rs` owns the types **and** `pub(crate) fn list_bookmarks(workspace: &Workspace) -> Result<Vec<Bookmark>, BookmarkError>`. `src/repo.rs` adds the thin public method delegating to it. Rationale: `Repo`'s `workspace`/`settings` fields are private to `repo.rs`; sibling modules reach the workspace via the existing `pub(crate) fn workspace(&self) -> &Workspace` accessor (repo.rs:60) — **reuse it, do not re-add**. bookmarks needs only the workspace (not `settings`), so it mirrors the `status`/`op_log` `&Workspace` signature, NOT the `revset.rs` `&Repo` exception. [verified: repo.rs:60-62,106-109]

### Decision D2 — `target: crate::ChangeId` (reverse-hex), CommitId→ChangeId resolution

`ChangeId(pub String)` is defined ONCE in `status.rs:48-49` (holding jj's reverse-hex display form) and re-exported at lib.rs:19. `bookmarks.rs` must `use crate::ChangeId;` — do NOT redefine. Update the `ChangeId` doc-comment's "Reused by" line to also name Story 2.8. A bookmark `RefTarget` yields **`CommitId`**(s), not change ids, so resolve via the codebase's two-step idiom: `store.get_commit(commit_id).map_err(be)?` then `ChangeId(commit.change_id().reverse_hex())` — identical to `change.rs:172-176` (parent resolution) and `status.rs:105-111`. **Reverse-hex**, NOT forward-hex (`.hex()` is op-log's `OperationId` exception). Requires `use jj_lib::object_id::ObjectId as _;` (for `reverse_hex()`) and `use jj_lib::repo::Repo as _;` (for `readonly.view()`/`.store()`, aliased `as _` so the jj `Repo` trait doesn't collide with the crate's own `pub struct Repo`). [verified: status.rs:48-49; change.rs:172-176,203; jj-lib commit.rs:171, object_id.rs, repo.rs:120-131]

### Decision D3 — Uniform `added_ids().next()` for target resolution (covers conflicts, dodges dead branches)

`RefTarget::added_ids()` (op_store.rs:127) yields the added side of the target's internal merge: one commit for a normal target, the first add for a conflicted target, zero for an absent target. `target.added_ids().next()` therefore handles normal **and** conflicted targets in **one** covered path — no `as_normal().or_else(...)` two-branch form (the conflict branch would be untestable against the committed fixtures and would drag the coverage ratchet). For local bookmarks the target is never absent (`local_bookmarks()` is pre-pruned, view.rs:176), so the `Some` arm always fires on the medium fixture's 29 entries → the body line is covered. Using `if let Some(cid) = ... { push }` with **no else block** means there is no uncovered else-line. [verified: jj-lib op_store.rs:103,127; view.rs:176]

### Decision D4 — Fallible signature `Result<Vec<Bookmark>, BookmarkError>`

`load_at_head()` and per-target `get_commit()` can fail; siblings all return `Result`. Single-variant `BookmarkError { Backend(String) }` + `be()` flatten (there is no "not found" — listing never misses). Mirror `OpLogError` exactly. [verified: op_log.rs:49-61; status.rs:52-65]

### Decision D5 — `is_conflicted` deferred (listing scope only)

The epic explicitly defers any `is_conflicted` field ("a future story may add … this story's scope is just listing", epics.md:1448). With the uniform `added_ids().next()` path, a conflicted bookmark is surfaced (with its first added change id) rather than dropped or errored — matching the "expose state, don't patronize" stance from 2.6 (`[[feedback-dont-patronize-users]]`). Adding `is_conflicted` now is OQ4.

### Decision D6 — Remote bookmarks constructed in-test (the "fixture has no remotes" reality)

The committed fixtures contain **zero** remote bookmarks (`gen_fixture.rs` uses only `set_local_bookmark_target`; `tests/revset.rs:178` depends on this). Rather than regenerate the fixtures (a heavier, separately-reviewed change to committed binaries that would also shift the `bookmarks()` revset oracle), the `BookmarkKind::Remote` arm + the `is_present()`/`is_tracked()` filters are covered by **constructing** remote refs in the integration test — the same approach `change.rs` uses to construct divergent/conflicted commits in-test. This keeps the story self-contained and gives the remote arm **real** (not synthetic) coverage. Fixture regeneration remains the override (OQ1). [verified: gen_fixture.rs:190-265; jj-lib view.rs:629-668]

### jj-lib 0.41.0 bookmark API anchors — VERIFIED against source

All under `~/.cargo/registry/src/index.crates.io-1949cf8c6b5b557f/jj-lib-0.41.0/src/`. jj-lib pinned `=0.41.0` (`crates/zanshin-jj/Cargo.toml` uses `jj-lib = { workspace = true }`).

```
repo::Repo::view(&self) -> &View                                       repo.rs:125  (trait method — `use jj_lib::repo::Repo as _;`)
repo::Repo::store(&self) -> &Arc<Store>                                repo.rs:120
view::View::local_bookmarks(&self)
    -> impl Iterator<Item = (&RefName, &RefTarget)>                    view.rs:140  (lexicographic; absent-pruned)
view::View::all_remote_bookmarks(&self)
    -> impl Iterator<Item = (RemoteRefSymbol<'_>, &RemoteRef)>         view.rs:192  (lexicographic; NOT pruned — filter present+tracked)
ref_name::RemoteRefSymbol<'a> { name: &'a RefName, remote: &'a RemoteName }  ref_name.rs:367-372
ref_name::{RefName,RemoteName}::as_str(&self) -> &str                  ref_name.rs:160  (macro-generated)
op_store::RemoteRef { target: RefTarget, state: RemoteRefState }       op_store.rs:138-141
op_store::RemoteRef::is_present(&self) -> bool                         op_store.rs:166
op_store::RemoteRef::is_tracked(&self) -> bool                        op_store.rs:171  (state == Tracked)
op_store::RemoteRefState { New, Tracked }                              op_store.rs:190-196
op_store::RefTarget::added_ids(&self) -> impl Iterator<Item=&CommitId> op_store.rs:127  (1 for normal, first-add for conflict)
op_store::RefTarget::as_normal(&self) -> Option<&CommitId>            op_store.rs:103  (NOT used — added_ids covers both)
store::Store::get_commit(&self, &CommitId) -> BackendResult<Commit>   (used at change.rs:169, status.rs:92)
commit::Commit::change_id(&self) -> &ChangeId                          commit.rs:171
object_id::ObjectId::reverse_hex(&self) -> String                     object_id.rs  (z-k display form — D2)
```

**For the in-test remote-bookmark construction** (mutable side — TEST ONLY, never in production `bookmarks.rs`):
```
repo::MutableRepo::set_local_bookmark_target(&mut self, &RefName, RefTarget)        repo.rs:1723
repo::MutableRepo::set_remote_bookmark(&mut self, RemoteRefSymbol, RemoteRef)       repo.rs:1751
op_store::RefTarget::normal(CommitId) -> RefTarget   /   RefTarget::absent()
```
The canonical construction recipe is jj-lib's own `test_absent_tracked_bookmarks` (view.rs:629-668): build a `RemoteRef { target: RefTarget::normal(commit_id), state: RemoteRefState::Tracked }` and call `set_remote_bookmark(RemoteRefSymbol { name, remote }, remote_ref)`.

### The verified call sequence (copy-adaptable skeleton for `bookmarks.rs`)

```rust
// SPDX-License-Identifier: MIT

//! `bookmarks.rs` — jj bookmark list read (FR-JJ-8).
//!
//! Exposes a `jj_lib`-type-free view of jj's bookmarks: local bookmarks and
//! tracked remote bookmarks, each resolved to its target change id. Re-resolves
//! to the head operation per call (ADR-0002) and never shells to the `jj` CLI
//! (AR-AP-1).

use jj_lib::object_id::ObjectId as _; // for ChangeId::reverse_hex()
use jj_lib::repo::Repo as _;          // for ReadonlyRepo::{view, store}
use jj_lib::workspace::Workspace;

use crate::ChangeId;

/// Whether a bookmark is local or a tracked remote bookmark.
///
/// `PartialOrd`/`Ord` order `Local` before `Remote`, then remotes by
/// `remote_name` — the secondary sort key for [`list_bookmarks`] (FR-JJ-8).
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub enum BookmarkKind {
    /// A bookmark local to this repository.
    Local,
    /// A tracked remote bookmark; `remote_name` is always present (never `None`),
    /// and is the empty string only in the theoretical empty-remote edge case.
    Remote {
        /// The remote this bookmark tracks (e.g. `"origin"`).
        remote_name: String,
    },
}

/// One jj bookmark (local or tracked-remote) and its target change (FR-JJ-8).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Bookmark {
    /// Bookmark name, preserved as UTF-8 (jj-lib `RefName`).
    pub name: String,
    /// Target change id in jj reverse-hex form. For a conflicted/divergent
    /// target, the first added commit's change id (listing scope only).
    pub target: ChangeId,
    /// Whether this entry is the local bookmark or a tracked-remote bookmark.
    pub kind: BookmarkKind,
}

/// Errors returned by [`crate::Repo::list_bookmarks`].
#[derive(Debug, thiserror::Error)]
pub enum BookmarkError {
    /// An underlying jj-lib failure (loader / view / store read),
    /// opaque-string-wrapped so no `jj_lib` type escapes the public API (FR-JJ-16).
    #[error("jj-lib error: {0}")]
    Backend(String),
}

/// Converts any jj-lib error to [`BookmarkError::Backend`].
fn be<E: std::fmt::Display>(e: E) -> BookmarkError {
    BookmarkError::Backend(e.to_string())
}

/// Lists local + tracked-remote bookmarks, sorted by name then kind (FR-JJ-8).
///
/// Re-resolves to the head operation every call (ADR-0002). Read-only; never
/// shells to `jj bookmark list` (AR-AP-1). A conflicted target resolves to the
/// first added commit's change id (listing scope only).
///
/// # Errors
/// - [`BookmarkError::Backend`] — `load_at_head` or a store read failed; the
///   jj-lib reason is forwarded as a string.
pub(crate) fn list_bookmarks(workspace: &Workspace) -> Result<Vec<Bookmark>, BookmarkError> {
    let readonly = pollster::block_on(workspace.repo_loader().load_at_head()).map_err(be)?;
    let view = readonly.view();
    let store = readonly.store();

    // CommitId -> ChangeId (reverse-hex), the codebase idiom (change.rs:172-176).
    let to_change = |commit_id: &jj_lib::backend::CommitId| -> Result<ChangeId, BookmarkError> {
        let commit = store.get_commit(commit_id).map_err(be)?;
        Ok(ChangeId(commit.change_id().reverse_hex()))
    };

    let mut out: Vec<Bookmark> = Vec::new();

    // Local bookmarks — already absent-pruned by jj-lib (view.rs:176).
    for (name, target) in view.local_bookmarks() {
        // added_ids().next() handles normal AND conflicted targets uniformly.
        if let Some(commit_id) = target.added_ids().next() {
            out.push(Bookmark {
                name: name.as_str().to_owned(),
                target: to_change(commit_id)?,
                kind: BookmarkKind::Local,
            });
        }
    }

    // Remote bookmarks — NOT pre-pruned: skip absent + untracked (view.rs:245-260).
    for (symbol, remote_ref) in view.all_remote_bookmarks() {
        if !remote_ref.is_present() || !remote_ref.is_tracked() {
            continue;
        }
        if let Some(commit_id) = remote_ref.target.added_ids().next() {
            out.push(Bookmark {
                name: symbol.name.as_str().to_owned(),
                target: to_change(commit_id)?,
                kind: BookmarkKind::Remote {
                    remote_name: symbol.remote.as_str().to_owned(),
                },
            });
        }
    }

    out.sort_by(|a, b| a.name.cmp(&b.name).then_with(|| a.kind.cmp(&b.kind)));
    Ok(out)
}
```

(The `repo.rs` delegate and the `lib.rs` re-export are in T4/T5. Note: the intermediate jj-lib types — `View`, `RefTarget`, `RemoteRef`, `CommitId`, `Commit` — never appear in any `pub` signature, satisfying FR-JJ-16.)

### Test recipe (mirror `tests/op_log.rs` — do NOT invent a new harness)

Reuse the scaffolding from `tests/op_log.rs:1-57`:
- SPDX line 1; `static ENV_GUARD: LazyLock<()>` pinning `JJ_CONFIG=""` + `GIT_CONFIG_GLOBAL=""` inside `unsafe`; `fn pin_env() { LazyLock::force(&ENV_GUARD); }` called first in every test (hermeticity — no global `~/.jjconfig.toml`/`~/.gitconfig`).
- `fn make_test_settings() -> UserSettings` and `fn oracle_workspace(root: &Path) -> (Workspace, UserSettings)` — verbatim from `tests/op_log.rs`.
- Open fixtures via `extract_fixture("tiny-3-commits")` / `extract_fixture("medium-1k-commits")` → `Repo::open(&fx.path)`; **keep `fx` bound for the whole test** (it owns a `TempDir`).
- **Local oracle** (medium): open the workspace independently, `pollster::block_on(loader.load_at_head())`, walk `view().local_bookmarks()`, build the expected `Vec<(String /*name*/, String /*reverse_hex change id*/)>`, and assert it equals the `Local`-kind subset of `repo.list_bookmarks()?` — EQUALITY, not count-only.
- **In-test remote construction** (covers the `Remote` arm + the skip filters — the fixtures have no remotes). Mirror the transaction pattern from `gen_fixture.rs:179-265` / `change.rs:77-85`:
  ```rust
  // imports: jj_lib::op_store::{RefTarget, RemoteRef, RemoteRefState};
  //          jj_lib::ref_name::RemoteRefSymbol; jj_lib::backend::CommitId;
  let (ws, _settings) = oracle_workspace(&fx.path);
  let base = pollster::block_on(ws.repo_loader().load_at_head()).unwrap();
  let commit_id: CommitId = /* any commit id in the repo, e.g. the @ commit */;
  let mut tx = base.start_transaction();
  let mr = tx.repo_mut();
  mr.set_local_bookmark_target("feature".as_ref(), RefTarget::normal(commit_id.clone()));
  mr.set_remote_bookmark(
      RemoteRefSymbol { name: "feature".as_ref(), remote: "origin".as_ref() },
      RemoteRef { target: RefTarget::normal(commit_id.clone()), state: RemoteRefState::Tracked },
  );
  // skip-branch coverage: an absent-tracked ref and a present-untracked ref:
  mr.set_remote_bookmark(
      RemoteRefSymbol { name: "ghost".as_ref(), remote: "origin".as_ref() },
      RemoteRef { target: RefTarget::absent(), state: RemoteRefState::Tracked },
  );
  mr.set_remote_bookmark(
      RemoteRefSymbol { name: "untracked".as_ref(), remote: "origin".as_ref() },
      RemoteRef { target: RefTarget::normal(commit_id.clone()), state: RemoteRefState::New },
  );
  pollster::block_on(tx.commit("test: add local + remote-tracking bookmarks")).unwrap();
  let repo = Repo::open(&fx.path).unwrap();
  let bms = repo.list_bookmarks().unwrap();
  // assert: a Local("feature") + a Remote("feature", "origin") both target the same change id;
  //         "ghost" (absent) and "untracked" (New) do NOT appear.
  ```
  (For a `commit_id`, either create a commit as `change.rs:77-85` does, or read one from the fixture's view, e.g. a `local_bookmarks()` target on medium — but the cleanest is a fresh `Repo::init` repo where you create a single commit and bookmark it. The dev picks whichever is least friction; the load-bearing part is `set_local_bookmark_target` + `set_remote_bookmark` in one transaction.)
- **Backend error:** mirror `op_log_on_corrupt_repo_returns_backend_error` — `let tmp = TempDir::new()?; let repo = Repo::init(tmp.path(), None)?;`, then `fs::remove_dir_all(tmp.path().join(".jj").join("repo").join("op_heads"))`, then assert `matches!(repo.list_bookmarks(), Err(BookmarkError::Backend(_)))`. (Use the `tmp`/`init` handle, NOT the `fx`/fixture handle.)
- Naming: `bookmarks_on_<condition>_returns_<result>` (e.g. `bookmarks_on_tiny_returns_empty`, `bookmarks_on_medium_equals_local_oracle`, `bookmarks_local_and_remote_tracking_yields_two_entries`, `bookmarks_skips_absent_and_untracked_remotes`, `bookmarks_are_sorted_by_name_then_kind`, `bookmarks_on_corrupt_repo_returns_backend_error`). No `#[serial]`, no network, no `#[ignore]`/skip, no timing assert.

### Previous-story intelligence (2.4 status, 2.5 revset, 2.6 change, 2.7 op_log) — pre-empt the known traps

1. **Assert BOTH sides of every boolean / EQUALITY, never non-emptiness** (2.6 review: `let _ = x;` "proves nothing"; 2.4 hardening). Here: oracle-equality on the medium local set; the constructed remote entry equals `Remote { remote_name: "origin" }` exactly; the skipped refs are asserted ABSENT.
2. **Test ALL public error variants** — exercise `BookmarkError::Backend` (corrupt-while-open trigger).
3. **`use jj_lib::repo::Repo as _;`** to alias the jj `Repo` trait away from the crate's `pub struct Repo`; **`use jj_lib::object_id::ObjectId as _;`** for `.reverse_hex()`. (2.6/2.7 Debug Log: LSP may report these `as _` imports as stale while the compiler accepts them — trust the compiler.)
4. **One clippy-pedantic fix per story is normal — refactor, don't `#[allow]`.** An unavoidable `#[allow]` needs a `// WHY:`. Watch `doc_markdown` (backtick-wrap `jj_lib`, `RefTarget`, `BookmarkKind` in `//!`/doc comments) — bit 2.7.
5. **`cargo fmt --check` enforces the committed `rustfmt.toml`** — the committed `max_width` is **120** (rustfmt.toml:6), not the `100` quoted in project-context.md (tracked doc drift). Let `cargo fmt` decide.
6. **`pollster::block_on` is the only async bridge**; the public API is sync (jj-lib is sync — do NOT wrap in `async`/`tokio`).
7. **Lexicographic per-iterator order is jj's, but the union is re-sorted** — do not assume the merged local+remote `Vec` is sorted; the explicit `sort_by` is load-bearing for AC-4.

### Files this story touches

| File | Action | What |
|------|--------|------|
| `crates/zanshin-jj/src/bookmarks.rs` | **NEW** | `Bookmark`, `BookmarkKind`, `BookmarkError`, `be`, `pub(crate) fn list_bookmarks(&Workspace)`. SPDX line 1. |
| `crates/zanshin-jj/tests/bookmarks.rs` | **NEW** | Integration tests (empty + local-oracle + in-test local/remote pair + absent/untracked skip + sort + Backend). SPDX line 1. |
| `crates/zanshin-jj/src/lib.rs` | UPDATE | add `pub(crate) mod bookmarks;` + `pub use bookmarks::{Bookmark, BookmarkError, BookmarkKind};`. **No `Remote`.** |
| `crates/zanshin-jj/src/repo.rs` | UPDATE | add `pub fn list_bookmarks(&self) -> Result<Vec<crate::Bookmark>, crate::BookmarkError>` delegating to `crate::bookmarks::list_bookmarks(self.workspace())`. |
| `crates/zanshin-jj/src/status.rs` | UPDATE (1 line) | extend the `ChangeId` doc-comment "Reused by …" line to name Story 2.8. |
| `coverage-baseline.txt` | UPDATE | auto-raised `crates/zanshin-jj/src/bookmarks.rs = <pct>` entry; commit with the code. |

**No `Cargo.toml` change** — `jj-lib`, `pollster`, `thiserror` (deps) and `tempfile`/`test-helpers` (dev-deps) are all already present. No `itertools` (not a dep; the std iterator + `sort_by` covers everything). `crate::ChangeId` is reused → no new coupling.

### Hard rules in scope (from project-context.md — reject-at-review on violation)

- **NO `extern "C"` outside `zanshin-ffi`** — `bookmarks.rs` is pure-Rust `lib`. The FFI wrapper is Story 3.4b.
- **NO shelling to / parsing the `jj` CLI** — all access via `jj-lib` (AR-AP-1/AR-AP-2). `zanshin-jj` is the ONLY crate importing `jj_lib`.
- **NO `jj_lib` type in any public signature** (FR-JJ-16) — `Bookmark`/`BookmarkKind`/`BookmarkError` are crate-own; `target` is `crate::ChangeId`.
- **NO `unwrap()`/`expect()`/`panic!()`** in code reachable from FFI (production `list_bookmarks`; tests may `unwrap`); **NO `async`/`tokio`** wrapping of sync jj-lib (`pollster::block_on` is the sole bridge).
- **SPDX `// SPDX-License-Identifier: MIT` on line 1** of every new `.rs`.
- **NO lowering the coverage baseline / no `exclude_prefix`** to dodge testing — add tests instead.

### Project Structure Notes

`bookmarks.rs` is a NOUN-named read module (no `mod.rs`), slotting after `op_log.rs` per architecture.md (`bookmarks.rs # FR-JJ-8`). Inline `#[cfg(test)]` is **not** used (the siblings keep tests in `tests/`); bookmarks follows — integration tests in `crates/zanshin-jj/tests/bookmarks.rs`. `lib.rs` stays re-exports + docs only.

### References

- [Source: epics.md#Story 2.8 (lines 1424-1473)] — user story, ACs, edge cases.
- [Source: epics.md] — FR-JJ-8 (bookmarks list, line 38), FR-JJ-16 (adapter stability), AR-AP-1/2 (no shelling/parsing), Story 2.9 `Remote` (1477-1487), Story 2.10 combined re-export list (1536).
- [Source: docs/adr/0002-repository-state-model-warm-loader-reload-per-operation.md] — reload-per-call.
- [Source: crates/zanshin-jj/src/{lib.rs:9-19, repo.rs:60-109, status.rs:48-49,105-111, change.rs:169-176, op_log.rs:49-75}] — the read-module template + reused `crate::ChangeId`/`workspace()` + the CommitId→ChangeId idiom.
- [Source: crates/zanshin-jj/tests/op_log.rs:1-57] — test harness, oracle pattern, corrupt-repo Backend test.
- [Source: crates/zanshin-jj/tests/change.rs:77-205] — in-test transaction/commit construction to mirror for the remote-bookmark setup.
- [Source: crates/xtask/src/tasks/gen_fixture.rs:190-265] — fixture only sets LOCAL bookmarks (the "no remote bookmarks" reality); the `set_local_bookmark_target` transaction pattern.
- [Source: jj-lib-0.41.0/src/{view.rs:140,192,176,245-260,629-668, op_store.rs:103,127,138-141,161,166,171,190-196, ref_name.rs:160,367-372, commit.rs:171, repo.rs:120-131,1723,1751, object_id.rs}] — verified bookmark read + in-test mutable API anchors.
- [Source: coverage-baseline.txt] — `new_file_floor_pct = 80.00`; sibling `change.rs = 100.00`, `op_log.rs = 100.00`.

## Dev Agent Record

### Agent Model Used

claude-sonnet-4-6

### Debug Log References

- `reverse_hex()` is an inherent method on jj-lib id types (generated by `impl_id_type!` macro), NOT a trait method of `ObjectId`. So `use jj_lib::object_id::ObjectId as _` is not needed in `bookmarks.rs` (unlike `op_log.rs` which needs `.hex()` which IS a trait method). LSP correctly flagged this; compiler confirmed.
- rustfmt max_width = 120 (rustfmt.toml:6); many struct-literal lines were expanded to multi-line by fmt.

### Completion Notes List

- Implemented `Bookmark`, `BookmarkKind` (with `Ord` for sort), `BookmarkError`, `be()` helper, and `pub(crate) fn list_bookmarks` in `crates/zanshin-jj/src/bookmarks.rs`.
- Added `Repo::list_bookmarks` delegate in `repo.rs` (after `op_log`).
- Wired `pub(crate) mod bookmarks` + `pub use bookmarks::{Bookmark, BookmarkError, BookmarkKind}` in `lib.rs`.
- Updated `ChangeId` doc-comment in `status.rs` to include Story 2.8.
- 6 integration tests in `tests/bookmarks.rs`: empty (tiny), oracle equality (medium, 29 local), local+remote pair, skip absent/untracked, sort, Backend error.
- `cargo make test` green: 94.12% coverage on `bookmarks.rs` (above 80% floor); baseline auto-raised.

### File List

- `crates/zanshin-jj/src/bookmarks.rs` — NEW
- `crates/zanshin-jj/tests/bookmarks.rs` — NEW
- `crates/zanshin-jj/src/lib.rs` — updated (module + re-exports)
- `crates/zanshin-jj/src/repo.rs` — updated (`list_bookmarks` method)
- `crates/zanshin-jj/src/status.rs` — updated (`ChangeId` doc comment)
- `coverage-baseline.txt` — auto-raised by coverage ratchet

### Change Log

| Datum | Änderung |
|-------|----------|
| 2026-06-25 | Story 2.8 implemented: `bookmarks.rs` + tests; `cargo make test` green; coverage 94.12%; baseline raised. Status → review. |
| 2026-06-25 | create-story: comprehensive context engineered (jj-lib 0.41 bookmark API source-verified via 5-agent analysis; `Vec`→`Result`, reverse-hex `ChangeId` reuse, uniform `added_ids().next()`, no-`Remote`-re-export, and the in-test remote-bookmark construction that dissolves the "fixtures have no remotes" blocker). Status → ready-for-dev. |

## Open Questions for Ralph (non-blocking — defaults chosen, override before dev if desired)

1. **OQ1 — Remote-bookmark coverage: in-test construction vs fixture regen (default = in-test).** The committed fixtures have **zero** remote bookmarks. Default constructs a local+tracked-remote pair (and an absent + an untracked ref) in the integration test via the jj-lib mutable API — real coverage of the `Remote` arm and the skip filters, no committed-binary churn. Override = regenerate `medium` via `cargo xtask gen-fixture` to bake in a real remote pair (heavier; also shifts the `bookmarks()` revset oracle in `tests/revset.rs`).
2. **OQ2 — Remote scope: tracked-only vs all-present (default = tracked-only).** `list_bookmarks` filters `is_present() && is_tracked()`, matching the epic's "remote-tracking" wording and `jj bookmark list`'s tracked output. Override to include `New`/untracked present remotes (drop the `is_tracked()` filter) if the UI should show every known remote bookmark.
3. **OQ3 — Fallible return (default = `Result`).** Epic shows infallible `Vec<Bookmark>`; default refines to `Result<Vec<Bookmark>, BookmarkError>` (`get_commit` to resolve a target change id can fail; the 3.4b FFI wrapper needs a fallible result anyway). Override only for a panic-on-error infallible API (not recommended).
4. **OQ4 — `is_conflicted` flag (default = omit, epic-deferred).** A conflicted target surfaces with its first added change id; no flag this story. Override to add `is_conflicted: bool` now (cheap; mirrors change's `divergent` flag; widens the 3.4b wire by one bool).
5. **OQ5 — Sort tie-break (default = `Local` < `Remote`, then by `remote_name`).** Via derived `Ord` on `BookmarkKind`. Confirm, or expose jj-view order and let the UI sort (the `[[feedback-dont-patronize-users]]` alternative).
6. **OQ6 — `is_anonymous` interplay (default = unchanged).** `change.rs`'s `is_anonymous` uses local bookmarks only; introducing remote-bookmark awareness here does not change it (recommended — no rework to `change.rs`).
