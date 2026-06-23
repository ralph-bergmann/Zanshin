---
baseline_commit: 884b518
---

# Story 2.6: Implement `change.rs` — change metadata read

Status: done

<!-- Note: Validation is optional. Run validate-create-story for quality check before dev-story. -->

> **Scope-correction callout (binding overrides of epic prose):**
>
> 1. **Story 2.6 is PURE `zanshin-jj` Rust.** NO `extern "C"`, NO FlatBuffers, NO FFI, NO codegen, NO `docs/rust-error-codes.md` change. The `zanshin_change` FFI wrapper is a **separate** story (`3-4b-zanshin-change-ffi-wrapper`, gated on this one) and the `error.code` registry is minted at the FFI envelope layer, not here. The epic's 3.4b `change_id_json = "{\"id\":\"<hex>\"}"` phrasing predates [ADR-0001](../../docs/adr/0001-ffi-data-transport-flatbuffers.md) and is irrelevant to this story. [verified: sprint-status.yaml:71; epics.md:2205-2207]
> 2. **`ChangeId` means the crate's own `ChangeId(String)` newtype** (canonical reverse-hex), NOT `jj_lib::backend::ChangeId`. It already exists in `status.rs:48-49` and its doc literally says *"Reused by Story 2.6 (`change.rs`)"* — **reuse it, do not redefine** (Decision D1). No `jj_lib` type may appear in any public signature or error variant (FR-JJ-16). [verified: status.rs:48-49; epics.md:1302]
> 3. **Timestamps are carried as raw jj values, not `OffsetDateTime`.** The epic hedges *"`time: Timestamp` (or `OffsetDateTime`)"* (epics.md:1306,1310). This story stores raw `millis_since_epoch: i64` + `tz_offset_minutes: i32` — infallible, no `chrono`/`time` coupling in the public API, and FlatBuffers-friendly for 3.4b (Decision D2 / OQ2). [verified: jj-lib backend.rs:102-107]
> 4. **The cryptographic `signature` field is presence-only (`is_signed: bool`), NOT `Option<Signature>` carrying signer identity.** The epic says signature validation is **NOT** performed at this stage (epics.md:1333), but jj-lib's `SecureSig` carries only raw bytes (no name/email); recovering signer identity requires `Commit::verification()`, which shells out to gpg/ssh — i.e. validation. Presence is the only honest, cheap, no-validation representation (Decision D3 / OQ3). [verified: jj-lib commit.rs:204,209; backend.rs:173-178; epics.md:1330-1333]
> 5. **`get_change` additionally returns `divergent: bool`.** A jj `ChangeId` can resolve to >1 visible commit (divergence). `get_change` picks the first visible target and reports divergence so the UI can decide (matches `feedback-dont-patronize-users`: backend exposes the capability). This is a create-story addition beyond the epic's field list (Decision D4 / OQ4). [verified: jj-lib index.rs:228-266]
> 6. **The `< 50 ms` figure is a SOFT design target, not a CI gate.** Performance assertions are deferred to the release phase — no blocking `assert!(elapsed < …)` in a non-`#[ignore]` test. [verified: project-context.md "Performance assertions — DEFERRED"; epics.md:1320]

---

## Story

As a Rust caller wanting to display a specific change,
I want `zanshin-jj` to expose `Repo::get_change(id: &ChangeId) -> Result<Change, ChangeError>` returning all metadata for a change (change id, commit id, parents, description, author, committer, timestamps, signed-state, conflict state, anonymous-yes/no, divergent-yes/no),
So that the `zanshin_change` FFI wrapper (Story 3.4b) and the MCP `show` tool (Story 7.3, calls `zanshin-jj` directly) can serve `show <rev>` queries with full metadata (FR-JJ-6), with all jj-lib API churn absorbed inside the adapter (FR-JJ-16).

## Acceptance Criteria

Grouped by deliverable. Each item is a checkable contract. Source is `epics.md#Story 2.6` unless noted; where this story corrects the epic, the correction is flagged inline and justified in the Scope-correction callout / Dev Notes.

### AC-1 — Public surface: `Repo::get_change` + module wiring (FR-JJ-6) [epics.md:1294-1296,1317-1319]

1. `crates/zanshin-jj/src/change.rs` exists. `crates/zanshin-jj/src/repo.rs` gains a public method `pub fn get_change(&self, id: &crate::ChangeId) -> Result<crate::Change, crate::ChangeError>` that delegates to a `pub(crate) fn change::get_change(workspace: &Workspace, id: &crate::ChangeId) -> Result<Change, ChangeError>` (the established "method-on-`Repo` → `pub(crate)` free fn taking `&Workspace`" shape, mirroring `Repo::status` → `status::working_copy_status`).
2. The implementation is **synchronous** (no `async`, no `tokio`); the only async bridge is `pollster::block_on`, exactly as `status.rs:85` does.
3. No `jj_lib::*` type appears in the public signature of `get_change`, in the `Change`/`Signature`/`Timestamp`/`Timestamps`/`CommitId`/`ConflictState` types, or in any `ChangeError` variant (FR-JJ-16).
4. The signature takes `id: &crate::ChangeId` **by reference** (the epic wrote `id: ChangeId` by value — a borrow is the idiomatic refinement; document it). [correction of epics.md:1295]

### AC-2 — `Change` struct shape (FR-JJ-6 exhaustive) [epics.md:1300-1302,1359-1361]

5. `change.rs` defines:
   ```rust
   pub struct Change {
       pub id: crate::ChangeId,            // reverse-hex display form (reused from status.rs)
       pub commit_id: CommitId,            // Git SHA hex (changes on rebase)
       pub parents: Vec<crate::ChangeId>,  // parent change ids in jj order; empty for the root change
       pub description: String,            // always present, may be empty (jj convention)
       pub author: Signature,
       pub committer: Signature,
       pub timestamps: Timestamps,
       pub is_signed: bool,                // cryptographic signature present (presence-only — D3, replaces epic `signature: Option<Signature>`)
       pub conflict: ConflictState,
       pub is_anonymous: bool,
       pub divergent: bool,                // change id resolved to >1 visible commit (D4)
   }
   ```
6. Both `id` (`ChangeId` — stable across rebases) and `commit_id` (`CommitId` — Git-like SHA, changes on rebase) are present and distinct: `id` is built from `commit.change_id().reverse_hex()`, `commit_id` from `commit.id().hex()`. [epics.md:1359-1361]

### AC-3 — `CommitId`, `Signature`, `Timestamp`, `Timestamps` shapes [epics.md:1304-1310]

7. `pub struct CommitId(pub String);` — a jj-lib-type-free newtype mirroring `ChangeId`, holding the Git SHA hex (`commit.id().hex()`). `#[derive(Debug, Clone, PartialEq, Eq)]`; doc-commented that it is the Git-backend SHA and changes on rebase.
8. `pub struct Signature { pub name: String, pub email: String, pub timestamp: Timestamp }` (jj allows empty name/email — do **not** assume non-empty).
9. `pub struct Timestamp { pub millis_since_epoch: i64, pub tz_offset_minutes: i32 }` — raw jj timestamp (Decision D2). `tz_offset_minutes` is minutes **east of UTC** (jj's convention). `#[derive(Debug, Clone, Copy, PartialEq, Eq)]`.
10. `pub struct Timestamps { pub authored_at: Timestamp, pub committed_at: Timestamp }` — the canonical authored/committed pair, equal to `author.timestamp` / `committer.timestamp` respectively (a convenience projection; the overlap is intentional per the epic's exhaustive list — document it).

### AC-4 — `ConflictState` enum [epics.md:1312-1315,1354-1357]

11. `pub enum ConflictState { Clean, Conflicted { paths: Vec<PathBuf> } }`. The `Conflicted` variant lists the conflicted file paths (consumed by Epic 6's conflict-resolution flow).

### AC-5 — `ChangeError` enum + flatten helper [epics.md:1322-1324]

12. `#[derive(Debug, thiserror::Error)] pub enum ChangeError { NotFound { id: String }, Backend(String) }` with `#[error("...")]` on each variant and a `///` doc comment per variant. `NotFound.id` is the reverse-hex **string** that was passed in (not a jj_lib type). `Backend(String)` is the opaque catch-all (mirrors `StatusError::Backend` / `RevsetError::JjLibError`).
13. A private `fn be<E: std::fmt::Display>(e: E) -> ChangeError { ChangeError::Backend(e.to_string()) }` flattens every jj-lib failure (`RepoLoaderError`, `IndexError`, `BackendError`) to `Backend(String)` so no `jj_lib` type escapes (FR-JJ-16). NOTE: `resolve_change_id` returns `IndexResult` (an `IndexError`), `get_commit` returns `BackendResult` (a `BackendError`), and `load_at_head` returns `RepoLoaderError` — `be` covers all three via their `Display`.

### AC-6 — Happy path: valid id → populated `Change` [epics.md:1317-1320,1339-1342]

14. `get_change` with a valid change id returns `Ok(Change { .. })` populated from jj-lib's commit metadata, with all fields correct (assert by equality against an independent jj-lib oracle — see Test recipe). The `< 50 ms` budget is a soft target (Scope-correction #6), not a blocking assertion.
15. Retrieving the working-copy change (`get_change(&repo.status()?.working_copy_change_id)`) returns the correct fields, and `parents` includes the working-copy's parent change id.

### AC-7 — Not-found / malformed / hidden-only id → `NotFound` [epics.md:1322-1324]

16. `get_change` with a non-existent (well-formed but absent) id returns `Err(ChangeError::NotFound { id })`. A **malformed** id (not valid reverse-hex — `try_from_reverse_hex` returns `None`) and an id that resolves only to hidden/abandoned commits (`into_visible()` returns `None`) **also** map to `ChangeError::NotFound { id }` (the three failure modes are not distinguished — the caller does not need them apart; Decision D6). Never panics, never returns `Backend` for a plain miss.

### AC-8 — Empty description is `""`, not `Option` [epics.md:1326-1328]

17. A change with no description yields `Change.description == ""` (an empty `String`, **not** `Option<String>`) — jj's convention is always-present-but-may-be-empty.

### AC-9 — Signed change → `is_signed == true`; no validation [epics.md:1330-1333]

18. A change carrying a GPG/SSH signature yields `Change.is_signed == true` via `commit.is_signed()` (cheap; `secure_sig.is_some()`). **No** signature validation is performed — `Commit::verification()` (which shells out to gpg/ssh) is **not** called (Decision D3 honors epics.md:1333). An unsigned change yields `is_signed == false`.

### AC-10 — Anonymous change → `is_anonymous == true` [epics.md:1335-1337]

19. A change with an empty description **and** no local bookmark pointing at it yields `Change.is_anonymous == true`. Computed as `commit.description().is_empty() && repo.view().local_bookmarks_for_commit(commit.id()).next().is_none()` (Decision D5). A described or bookmarked change yields `false`.

### AC-11 — Merge change → all parents in order; root → empty [epics.md:1344-1346,1348-1352]

20. A merge change with multiple parents yields `Change.parents` containing **all** parent change ids in jj-lib's order (iterate every `commit.parent_ids()`, convert each to its reverse-hex `ChangeId`).
21. The root change has empty `parents` (`Vec::new()`).

### AC-12 — Conflicted change → `Conflicted { paths }` [epics.md:1354-1357]

22. A change with conflicted file(s) yields `Change.conflict == ConflictState::Conflicted { paths }` listing the conflicted paths (via `commit.tree().conflicts()`); a clean change yields `ConflictState::Clean`. Per-path backend errors from `conflicts()` are dropped (path-only list; the conflict-resolution flow re-reads — Decision D7).

### AC-13 — Divergent id → `divergent == true`, first visible returned [epics.md:n/a — create-story addition, see OQ4]

23. When a change id resolves to >1 visible commit (`ResolvedChangeTargets::is_divergent()`), `get_change` returns the **first** visible target (jj sorts newer-first, index.rs:218) with `Change.divergent == true`. A non-divergent change yields `divergent == false`.

### AC-14 — Integration-test coverage [epics.md:1344-1346]

24. `crates/zanshin-jj/tests/change.rs` exists and covers **at minimum**: a known id → metadata **equality** against an independent jj-lib oracle (AC-6); the working-copy change → parents include `@-` (AC-6); a non-existent id → `NotFound` (AC-7); a malformed (non-reverse-hex) id → `NotFound` (AC-7); the **root** change → empty `parents` (AC-11); an in-test-constructed **anonymous** change → `is_anonymous == true` plus a described/bookmarked change → `false` (AC-10); the `medium-1k-commits` **merge** change → `parents.len() == 3` in order (AC-11); an in-test-constructed **divergent** change → `divergent == true` and the returned change id appears (AC-13); an in-test-constructed **conflicted** change → `Conflicted { paths }` contains the path (AC-12).
25. The `Backend(String)` error variant is exercised — directly if a deterministic trigger is feasible, otherwise via a focused unit test of the `be()` helper (document why a real backend failure can't be forced deterministically). [carry-forward from 2.4 review: test ALL public error variants]

### AC-15 — Public-API hygiene + docs (Story 2.10 prerequisites) [epics.md:1534-1537,1561-1564]

26. `lib.rs` adds `pub(crate) mod change;` and `pub use change::{Change, ChangeError, CommitId, ConflictState, Signature, Timestamp, Timestamps};`. `ChangeId` is **not** re-exported again (already exported from `status.rs`). No `pub use jj_lib::...` is added.
27. `get_change` carries a `///` doc comment **including a `# Errors` section** mapping each `ChangeError` variant to its trigger; carries `#[must_use = "..."]`. Every new `pub` item is doc-commented (clippy pedantic). The `Change`/`CommitId` docs note the change-id-vs-commit-id distinction and that `commit_id` changes on rebase.

## Tasks / Subtasks

- [x] **T1 — Domain types** (AC: 5, 7, 8, 9, 10, 11)
  - [x] In `src/change.rs` (SPDX `MIT` line 1): define `Change`, `CommitId(pub String)`, `Signature`, `Timestamp`, `Timestamps`, `ConflictState`, each with derives + `///` docs. Reuse `crate::ChangeId` (do **not** redefine — D1).
- [x] **T2 — `ChangeError` enum + `be` helper** (AC: 12, 13)
  - [x] `#[derive(Debug, thiserror::Error)] pub enum ChangeError { NotFound { id: String }, Backend(String) }` with `#[error(...)]` + per-variant `///`; `fn be<E: Display>(e) -> ChangeError::Backend(e.to_string())`.
- [x] **T3 — `get_change` body** (AC: 1, 2, 3, 6, 7, 10, 11, 12, 13, 14)
  - [x] Reload to head: `pollster::block_on(workspace.repo_loader().load_at_head()).map_err(be)?` → `Arc<ReadonlyRepo>`; `repo_dyn = readonly.as_ref()` (`&dyn jj_lib::repo::Repo`); `store = readonly.store()`; `view = readonly.view()`. (ADR-0002 reload-per-call, mirrors `status.rs:85`.)
  - [x] `jj_lib::backend::ChangeId::try_from_reverse_hex(&id.0)` → `None` ⇒ `NotFound`.
  - [x] `repo_dyn.resolve_change_id(&jj_id).map_err(be)?` → `None` ⇒ `NotFound`; `targets.is_divergent()` → `divergent`; `targets.into_visible()` → `None` ⇒ `NotFound`; take first `CommitId`.
  - [x] `store.get_commit(&commit_id).map_err(be)?` → `Commit`.
  - [x] Map parents (each `parent_id` → `get_commit` → `change_id().reverse_hex()`); author/committer via a `to_signature` helper; `timestamps` from author/committer timestamps; conflict via `has_conflict()` + `tree().conflicts()`; `is_anonymous`; `is_signed` via `is_signed()` (NOT `verification()`).
- [x] **T4 — `Repo::get_change` method** (AC: 1)
  - [x] In `src/repo.rs`: `pub fn get_change(&self, id: &crate::ChangeId) -> Result<crate::Change, crate::ChangeError> { crate::change::get_change(self.workspace(), id) }` (reuses the `workspace()` accessor added in Story 2.5).
- [x] **T5 — Wire module + re-exports** (AC: 26)
  - [x] `lib.rs`: `pub(crate) mod change;` + `pub use change::{Change, ChangeError, CommitId, ConflictState, Signature, Timestamp, Timestamps};`.
- [x] **T6 — Docs** (AC: 27)
  - [x] `///` + `# Errors` + `#[must_use]` on `get_change`; `///` on every new type/variant; note the change-id/commit-id distinction.
- [x] **T7 — Integration tests `tests/change.rs`** (AC: 24, 25)
  - [x] Mirror `tests/status.rs` scaffolding verbatim: `ENV_GUARD`/`pin_env()`, `make_test_settings()`, `extract_fixture(...)`, keep the `FixtureHandle` alive, `fs::canonicalize` before any path equality.
  - [x] Oracle: open the workspace directly via jj-lib and read the same fields independently; assert **equality** (not non-emptiness).
  - [x] Setup helpers (copy/adapt from `tests/status.rs` / `tests/revset.rs`): `jj_new_with_description` for the described/anonymous case; `make_divergent_change` for AC-13; `ConflictState::Clean` covered by integration test (Conflicted deferred to 3.4b per escape hatch).
  - [x] Scenario-named tests (`change_on_known_id_returns_metadata`, `change_on_nonexistent_id_returns_not_found`, …). No `#[serial]`; no network.
- [x] **T8 — Green gate**
  - [x] `cargo make test` green: clippy pedantic (`-D warnings`, refactor — don't `#[allow]`), `cargo fmt --check`, `cargo deny check advisories bans`, all zanshin-jj unit + integration tests. (Trust the unpiped CLI exit code per the verify-via-CLI-gate rule.) Confirm no `jj_lib::` appears in any public signature (`grep`).

## Dev Notes

### Decision D1 — Reuse `crate::ChangeId`, do not promote to `id.rs` (RECOMMENDED — OQ1)

`ChangeId(pub String)` already lives in `status.rs:48-49`, `#[derive(Debug, Clone, PartialEq, Eq)]`, re-exported from `lib.rs`, and its doc comment already says *"Reused by Story 2.6 (`change.rs`)."* `change.rs` references it as `crate::ChangeId` — **no redefinition, no move**. Story 2.4's Open Question #2 floated promoting it to a shared `id.rs`; that is a future **non-breaking** re-export move and is **not** in scope here (it would touch `status.rs` for zero behavioral gain). `CommitId(pub String)` is the only new id newtype this story introduces.

### Decision D2 — Raw timestamps (`millis_since_epoch: i64` + `tz_offset_minutes: i32`), not `chrono`/`OffsetDateTime` (RECOMMENDED — OQ2)

jj-lib's `backend::Timestamp { timestamp: MillisSinceEpoch(i64), tz_offset: i32 }` (`tz_offset` is **minutes** east of UTC). The epic hedges between `Timestamp` and `OffsetDateTime`. Carrying the raw pair:
- is **infallible** (`Timestamp::to_datetime()` can return `Err(TimestampOutOfRange)`);
- avoids a `chrono`/`time` dependency in `change.rs` (Story 2.5 added `chrono = "=0.4.45"` to the workspace for `DatePatternContext`, but `change.rs` needs none of it);
- maps 1:1 onto the FlatBuffers wire in Story 3.4b (ADR-0001) — `long` + `int`, no datetime serialization.

`Timestamps { authored_at, committed_at }` is the canonical pair; it overlaps `author.timestamp` / `committer.timestamp` by design (the epic lists both `author: Signature` and a `Timestamps` struct). Document the overlap; do not drop either (FR-JJ-6 "exhaustive").

### Decision D3 — `is_signed: bool` (presence-only), not `signature: Option<Signature>` (RECOMMENDED — OQ3)

The epic field is `signature: Option<Signature>` "with the signer's identity," but the **same** AC says "signature validation is NOT performed at this stage" (epics.md:1333). These conflict against the jj-lib 0.41 reality:
- `Commit::is_signed() -> bool` is cheap (`secure_sig.is_some()`) and needs no validation.
- The raw `SecureSig` (backend.rs:173-178) carries only opaque `data`/`sig` bytes — **no** name/email.
- The only way to get signer identity is `Commit::verification()`, which invokes the configured gpg/ssh backend (a subprocess) and may return `SigStatus::Unknown` when the key isn't local — i.e. exactly the validation the epic forbids here, and a per-change subprocess cost when listing many changes.

So `is_signed: bool` is the honest, cheap, no-validation representation. Full signer identity + verification is deferred (Epic 6 may add it for write-side flows, as the epic itself notes). No fixture contains a signed commit, so this field is exercised only by the FFI builder/decoder tests (Story 3.4b) and an optional in-test signed commit if Ralph wants one.

### Decision D4 — `get_change` is divergence-aware: first visible + `divergent: bool` (RECOMMENDED — OQ4)

A jj `ChangeId` can map to multiple visible commits (divergent change). `resolve_change_id` returns `ResolvedChangeTargets` (a `Vec<(CommitId, ResolvedChangeState)>`), **not** a single commit. `get_change` uses `is_divergent()` to set the flag, takes the **first** visible target (`into_visible()`; jj sorts newer-first), and reports `divergent` so the UI decides what to show (`feedback-dont-patronize-users`). The alternative — erroring on divergence — hides a normal jj state from the UI. `is_divergent()` is essentially free (it's computed during resolution), so this is not speculative pre-computation.

### Decision D5 — `is_anonymous` = empty description AND no local bookmark (RECOMMENDED — OQ5)

jj has no literal "anonymous" flag. The epic defines it as "no description, no bookmark" (epics.md:1335). Compute:
```rust
let is_anonymous = commit.description().is_empty()
    && view.local_bookmarks_for_commit(commit.id()).next().is_none();
```
`View::local_bookmarks_for_commit(&CommitId)` (view.rs:149) yields `(name, target)` for every local bookmark whose target adds this commit; empty iterator ⇒ no local bookmark. **Local bookmarks only** for WIP. Whether remote bookmarks / tags should also count as "named" is OQ5 (recommend local-only). jj-lib's adjacent notions `Commit::is_discardable` (empty description AND empty diff) and `Commit::is_hidden` (not in the change-id index) are **not** "anonymous" — do not use them.

### Decision D6 — Three not-found modes collapse to `NotFound` (RECOMMENDED)

`try_from_reverse_hex` → `None` (malformed reverse-hex), `resolve_change_id` → `Ok(None)` (well-formed but absent), and `into_visible()` → `None` (exists only as hidden/abandoned) are three distinct misses. The caller (FFI/MCP/UI showing one change) does not need them apart, so all three map to `ChangeError::NotFound { id }`. Genuine jj-lib failures (`IndexError`/`BackendError`/`RepoLoaderError`) map to `Backend(String)` via `be`. Keeping the public error surface at two variants matches `StatusError`'s shape and Story 2.10's minimal-surface goal.

### Decision D7 — Conflicted paths are path-only (drop per-path value errors) (RECOMMENDED)

`MergedTree::conflicts()` yields `(RepoPathBuf, BackendResult<MergedTreeValue>)`. `get_change` needs only the **path list** for `ConflictState::Conflicted { paths }`; the per-path value `BackendResult` is dropped (`.map(|(p, _value)| …)`). Epic 6's conflict-resolution flow re-reads the actual conflict content. `RepoPathBuf` → `PathBuf` via `PathBuf::from(p.as_internal_file_string())` — the **internal** `/`-separated form, exactly as `status.rs:70-72`.

### jj-lib 0.41.0 API anchors — VERIFIED against source

All paths under `~/.cargo/registry/src/index.crates.io-1949cf8c6b5b557f/jj-lib-0.41.0/src/`. Every symbol below was confirmed to exist at the cited line by an adversarial verification pass against the pinned crate (verdict: **all confirmed**; the one fabricated symbol in the draft — a nonexistent `ChangeError::OnlyHidden` — was caught and removed; `into_visible()` returns a std `Option`, so the impl supplies its own error).

```
backend::ChangeId::try_from_reverse_hex(impl AsRef<[u8]>) -> Option<Self>   backend.rs:71  (inverse of reverse_hex; None on malformed)
repo::Repo::resolve_change_id(&self, &ChangeId)
    -> IndexResult<Option<ResolvedChangeTargets>>                            repo.rs:135    (DEFAULT trait method; needs `use jj_lib::repo::Repo as _;`)
index::ResolvedChangeTargets { pub targets: Vec<(CommitId, ResolvedChangeState)> }  index.rs:216
    .is_divergent(&self) -> bool                                             index.rs:245
    .into_visible(self) -> Option<Vec<CommitId>>                            index.rs:266   (None if all hidden; std Option, NOT Result)
    .visible_with_offsets(&self) -> ...                                      index.rs:228   (alt; newer-first per index.rs:218)
store::Store::get_commit(self: &Arc<Self>, &CommitId) -> BackendResult<Commit>  store.rs:151  (SYNC; same as status.rs:92)
commit::Commit::id(&self) -> &CommitId                                       commit.rs:102  (.hex() = Git SHA)
commit::Commit::change_id(&self) -> &ChangeId                               commit.rs:171  (.reverse_hex() = z-k display form)
commit::Commit::description(&self) -> &str                                  commit.rs:179  ("" when unset)
commit::Commit::author(&self) -> &Signature                                commit.rs:183
commit::Commit::committer(&self) -> &Signature                             commit.rs:187
commit::Commit::parent_ids(&self) -> &[CommitId]                           commit.rs:106  (SYNC; empty for root)
commit::Commit::has_conflict(&self) -> bool                                commit.rs:167  (cheap; !tree_ids().is_resolved())
commit::Commit::tree(&self) -> MergedTree                                  commit.rs:120  (SYNC)
commit::Commit::is_signed(&self) -> bool                                   commit.rs:204  (cheap; secure_sig.is_some())
commit::Commit::verification(&self) -> SignResult<Option<Verification>>    commit.rs:209  (SLOW — shells gpg/ssh; DO NOT CALL, D3)
merged_tree::MergedTree::conflicts(&self)
    -> impl Iterator<Item = (RepoPathBuf, BackendResult<MergedTreeValue>)>  merged_tree.rs:196
repo_path::RepoPath::as_internal_file_string(&self) -> &str                repo_path.rs:360  (internal '/'-separated form)
backend::Signature { pub name: String, pub email: String, pub timestamp: Timestamp }  backend.rs:161
backend::Timestamp { pub timestamp: MillisSinceEpoch, pub tz_offset: i32 }  backend.rs:102  (tz_offset in MINUTES)
backend::MillisSinceEpoch(pub i64)                                          backend.rs:98
view::View::local_bookmarks_for_commit(&self, &CommitId)
    -> impl Iterator<Item = (&RefName, &RefTarget)>                         view.rs:149
repo::RepoLoader::load_at_head() -> Result<Arc<ReadonlyRepo>, RepoLoaderError>  repo.rs:764  (async → pollster::block_on)
```

**In-repo precedent** — `status.rs` already loads a commit and reads metadata; reuse the exact mechanics:
```rust
// status.rs:85, 88-92, 105-107 (the proven path: load_at_head → view/store → get_commit → reverse_hex)
let repo = pollster::block_on(workspace.repo_loader().load_at_head()).map_err(be)?;
let wc_commit = repo.store().get_commit(wc_id).map_err(be)?;
let parent_commit = repo.store().get_commit(id).map_err(be)?;
(id.clone(), ChangeId(parent_commit.change_id().reverse_hex()))
```

### The verified call sequence (copy-adaptable)

```rust
// SPDX-License-Identifier: MIT
use std::path::PathBuf;

use jj_lib::repo::Repo as _;          // trait: store()/view()/resolve_change_id(); `as _` dodges crate::Repo
use jj_lib::workspace::Workspace;

use crate::ChangeId;                   // reused from status.rs (D1)

/// Git-backend commit hash (changes on rebase, unlike [`ChangeId`]).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CommitId(pub String);

/// Who authored/committed a change, and when.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Signature { pub name: String, pub email: String, pub timestamp: Timestamp }

/// A raw jj timestamp: millis since the Unix epoch + a timezone offset in minutes east of UTC.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Timestamp { pub millis_since_epoch: i64, pub tz_offset_minutes: i32 }

/// Authored/committed timestamp pair (mirrors `author.timestamp` / `committer.timestamp`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Timestamps { pub authored_at: Timestamp, pub committed_at: Timestamp }

/// Whether a change is conflict-free.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ConflictState { Clean, Conflicted { paths: Vec<PathBuf> } }

/// Errors returned by [`crate::Repo::get_change`].
#[derive(Debug, thiserror::Error)]
pub enum ChangeError {
    /// No change exists for the given id (absent, malformed reverse-hex, or only-hidden).
    #[error("change not found: {id}")]
    NotFound { id: String },
    /// An underlying jj-lib failure (index/backend/loader), opaque-string-wrapped so no
    /// `jj_lib` type escapes the public API (FR-JJ-16).
    #[error("jj-lib error: {0}")]
    Backend(String),
}

fn be<E: std::fmt::Display>(e: E) -> ChangeError { ChangeError::Backend(e.to_string()) }

fn to_signature(sig: &jj_lib::backend::Signature) -> Signature {
    Signature {
        name: sig.name.clone(),
        email: sig.email.clone(),
        timestamp: Timestamp {
            millis_since_epoch: sig.timestamp.timestamp.0,
            tz_offset_minutes: sig.timestamp.tz_offset,
        },
    }
}

/// Full metadata for one change (FR-JJ-6).
pub struct Change {
    pub id: ChangeId,
    pub commit_id: CommitId,
    pub parents: Vec<ChangeId>,
    pub description: String,
    pub author: Signature,
    pub committer: Signature,
    pub timestamps: Timestamps,
    pub is_signed: bool,
    pub conflict: ConflictState,
    pub is_anonymous: bool,
    pub divergent: bool,
}

pub(crate) fn get_change(workspace: &Workspace, id: &ChangeId) -> Result<Change, ChangeError> {
    // 1. Reload to head (ADR-0002; sync via pollster — mirrors status.rs:85).
    let readonly = pollster::block_on(workspace.repo_loader().load_at_head()).map_err(be)?;
    let repo_dyn: &dyn jj_lib::repo::Repo = readonly.as_ref();
    let store = readonly.store();
    let view = readonly.view();

    // 2. Public reverse-hex string → jj ChangeId. Malformed ⇒ NotFound (D6).
    let jj_id = jj_lib::backend::ChangeId::try_from_reverse_hex(&id.0)
        .ok_or_else(|| ChangeError::NotFound { id: id.0.clone() })?;

    // 3. Resolve → visible commit(s), divergence-aware (D4). resolve_change_id is a Repo-trait method.
    let targets = repo_dyn
        .resolve_change_id(&jj_id)
        .map_err(be)?                                                      // IndexError → Backend
        .ok_or_else(|| ChangeError::NotFound { id: id.0.clone() })?;       // absent
    let divergent = targets.is_divergent();
    let commit_id = targets
        .into_visible()
        .and_then(|v| v.into_iter().next())                               // first visible (newer-first)
        .ok_or_else(|| ChangeError::NotFound { id: id.0.clone() })?;       // only hidden/abandoned

    // 4. Load the chosen commit (sync; status.rs:92).
    let commit = store.get_commit(&commit_id).map_err(be)?;

    // 5. Parents: CommitIds → reverse-hex ChangeIds (status.rs:105-107 for the first parent).
    let mut parents = Vec::with_capacity(commit.parent_ids().len());
    for pid in commit.parent_ids() {
        let parent = store.get_commit(pid).map_err(be)?;
        parents.push(ChangeId(parent.change_id().reverse_hex()));
    }

    // 6. Signatures + timestamps (raw — D2). Timestamp is Copy.
    let author = to_signature(commit.author());
    let committer = to_signature(commit.committer());
    let timestamps = Timestamps { authored_at: author.timestamp, committed_at: committer.timestamp };

    // 7. Conflict state (D7).
    let conflict = if commit.has_conflict() {
        let paths = commit
            .tree()
            .conflicts()
            .map(|(p, _value)| PathBuf::from(p.as_internal_file_string()))
            .collect();
        ConflictState::Conflicted { paths }
    } else {
        ConflictState::Clean
    };

    // 8. Anonymity (D5): empty description AND no local bookmark targets this commit.
    let is_anonymous = commit.description().is_empty()
        && view.local_bookmarks_for_commit(commit.id()).next().is_none();

    Ok(Change {
        id: ChangeId(commit.change_id().reverse_hex()),
        commit_id: CommitId(commit.id().hex()),
        parents,
        description: commit.description().to_owned(),
        author,
        committer,
        timestamps,
        is_signed: commit.is_signed(),     // presence-only (D3) — NOT verification()
        conflict,
        is_anonymous,
        divergent,
    })
}
```

Borrow-checker notes: `readonly` (hence `repo_dyn`, `store`, `view`) lives the whole fn. `is_divergent()` borrows `targets` before `into_visible()` consumes it — call order matters. `Timestamp` is `Copy`, so `author.timestamp` copies into `timestamps` while `author` still moves into `Change`.

### Test recipe (mirror `tests/status.rs` — do not invent a new harness)

`tests/status.rs` is the template. Reuse verbatim:
```rust
// SPDX-License-Identifier: MIT
use std::sync::LazyLock;
use std::{env, fs};

use jj_lib::repo::Repo as _;
use test_helpers::extract_fixture;
use zanshin_jj::{ChangeError, ChangeId, ConflictState, Repo};

static ENV_GUARD: LazyLock<()> = LazyLock::new(|| unsafe {
    env::set_var("JJ_CONFIG", "");
    env::set_var("GIT_CONFIG_GLOBAL", "");   // the part that actually isolates the gix git backend
});
fn pin_env() { LazyLock::force(&ENV_GUARD); }
```

- **Open a fixture:** `let fx = extract_fixture("tiny-3-commits"); let repo = Repo::open(&fx.path).unwrap();` — **keep `fx` bound for the whole test** (its `TempDir` cleans up on drop). `extract_fixture` needs `version = "0.1.0"` on the `test-helpers` path dev-dep (cargo-deny wildcard gate — learned in 2.3; already present from 2.4/2.5).
- **Oracle:** open the workspace directly via jj-lib, load the same commit, and read `change_id().reverse_hex()` / `id().hex()` / `description()` / `author().name` independently. Assert **equality** against `get_change`'s result (the key 2.4 review hardening — never assert mere non-emptiness for id/metadata fields).
- **Known id / `@`:** get the `@` change id from `repo.status().unwrap().working_copy_change_id`, then `repo.get_change(&that)` and assert metadata equality + `parents` includes `@-`.
- **`NotFound`:** a syntactically valid but absent reverse-hex id, and a clearly malformed id (e.g. a string with characters outside jj's reverse-hex alphabet) → both `Err(ChangeError::NotFound { .. })`.
- **Root change:** resolve the root change id (via the oracle / `repo.store().root_commit_id()`) → `parents` is empty.
- **Merge (medium):** `extract_fixture("medium-1k-commits")` has one 3-parent merge commit (bookmark `merge`); get its change id (oracle: find the commit with 3 parents) → `parents.len() == 3` in jj order.
- **Anonymous:** construct an empty-description, no-bookmark commit in-test (`jj new`-style, the way `tests/status.rs` builds working-copy state) → `is_anonymous == true`; a described or bookmarked commit → `false`.
- **Divergent:** reuse the `make_divergent_change` pattern from `tests/revset.rs:290` (rewrite one commit into two visible commits sharing one change id) → `get_change(&that_change_id).divergent == true`; verify the 2-commit divergence with an independent jj-lib oracle.
- **Conflicted:** build a conflicting merge in-test (two commits editing the same file differently, merged) → `conflict == Conflicted { paths }` containing the path. This is the one test that needs real conflict construction; if jj-lib conflict construction proves impractical in a unit test, document it and rely on the FFI builder/decoder tests in 3.4b to exercise the `Conflicted` mapping. Clean fixture changes assert `Clean`.
- **macOS path gotcha (from 2.3):** `workspace_root()` returns canonical `/private/var/…`; `TempDir::path()` returns `/var/…` — `fs::canonicalize` both sides before any path comparison (only relevant if you compare paths, not change ids).
- **Naming:** `change_on_<condition>_returns_<result>`. No `#[serial]` — tests run in parallel; `ENV_GUARD` makes the env pin idempotent. No `#[ignore]`/skip-for-flakiness.

### Previous-story intelligence (2.3, 2.4, 2.5) — pre-empt the known traps

1. **`ChangeId::reverse_hex()`, never `hex()`** for change ids — `reverse_hex()` is jj's canonical `qpvuntsm` z-k display form. **`CommitId` is the opposite**: `commit.id().hex()` (the `0-9a-f` Git SHA). (2.4/2.5)
2. **`use jj_lib::repo::Repo as _;`** — the jj `Repo` *trait* must be aliased `as _` to avoid clashing with the crate's own `pub struct Repo` and to bring `store()/view()/resolve_change_id()` into scope. (2.4/2.5)
3. **`load_at_head` / `get_commit` / `resolve_change_id` return wrapped values** — never `unwrap`; map to `ChangeError` via `be`. (2.4)
4. **`cargo-deny wildcards = "deny"`** — path dev-deps need an explicit `version` (already on `test-helpers`). (2.3)
5. **macOS canonical-path mismatch** (see Test recipe). (2.3)
6. **Test ALL public error variants, and assert equality (not non-emptiness) for id/metadata fields.** AC-7 (NotFound) + AC-25 (Backend) + AC-6 equality are written to satisfy this up front. (2.4)
7. **One clippy-pedantic fix per story is normal** — refactor, do **not** `#[allow]`; any unavoidable `#[allow]` needs a `// WHY:`. An enum passed by value may need `#[derive(Clone, Copy)]` to dodge `needless_pass_by_value`. (2.3/2.4)
8. **`pollster::block_on` is the only async bridge**; the crate stores no runtime. (2.3/2.4)
9. **`max_width` is actually 120, NOT 100.** The committed `rustfmt.toml:6` sets `max_width = 120`; `project-context.md:91,389` and older story prose say `100` — that is a tracked, unreconciled doc drift (deferred-work.md). `cargo fmt --check` enforces **120**. Do not treat `100` as the budget. (2.5 review / deferred-work)

### Files this story touches

| File | Action | What |
|------|--------|------|
| `crates/zanshin-jj/src/change.rs` | **NEW** | `Change`, `CommitId`, `Signature`, `Timestamp`, `Timestamps`, `ConflictState`, `ChangeError`, `to_signature`, `be`, `pub(crate) fn get_change`. |
| `crates/zanshin-jj/tests/change.rs` | **NEW** | Integration tests (AC-24/25 + oracle). |
| `crates/zanshin-jj/src/lib.rs` | UPDATE | `pub(crate) mod change;` + `pub use change::{Change, ChangeError, CommitId, ConflictState, Signature, Timestamp, Timestamps};`. |
| `crates/zanshin-jj/src/repo.rs` | UPDATE | `pub fn get_change(&self, id: &ChangeId)` delegating to `change::get_change(self.workspace(), id)` (reuses the `workspace()` accessor from 2.5). |

No FFI, no schema, no codegen, no error-registry change, **no `Cargo.toml` change** (raw timestamps → no `chrono` needed here; `pollster`/`thiserror`/`jj-lib` already present). `docs/rust-error-codes.md` is for FFI-layer `error.code`s, minted in Story 3.4b — not this story.

### Hard rules in scope (from project-context.md — reject-at-review on violation)

- **No shelling to `jj` CLI; no string-parsing jj output; no `jj_cli`/`WorkspaceCommandHelper` dep** in production code. All access via `jj-lib`. (Test oracle/setup may call `jj-lib` directly — that is not shelling.)
- **Sync only** — no `async`/`tokio` in `zanshin-jj`; `pollster::block_on` is the bridge.
- **No `jj_lib` type in any public signature or error variant** (FR-JJ-16); `ChangeError` is the crate's own `thiserror` enum.
- **clippy::pedantic, `-D warnings`** — fix, don't `#[allow]`. `cargo fmt --check` (`max_width = 120`).
- **No `unwrap`/`expect`/`panic!`** in the library path (`tests/` may `unwrap`).
- **No `unsafe`** in `zanshin-jj`.
- **SPDX `// SPDX-License-Identifier: MIT` first line** of every new `.rs`.
- **Crates organize by NOUN, no `mod.rs`** — `change.rs` is correct; `lib.rs` stays re-exports + docs only.

### Project Structure Notes (variances)

- `get_change` follows the `Repo::method → pub(crate) fn(&Workspace)` shape (like `status`), unlike `resolve_revset`'s free-fn-taking-`&Repo` shape (2.5's AC-driven exception). The epic's user-story method form (`Repo::get_change`) is honored directly; no dual surface.
- `commit_id` is by-ref-friendly: the method borrows `id: &ChangeId` (epic wrote by value) — idiomatic, avoids a clone at every call site (FFI/MCP).
- `Change` carries `is_signed: bool` and `divergent: bool` (create-story refinements, D3/D4) — both are flagged as Open Questions with recommended defaults.

### References

- [Source: epics.md#Story-2.6 (lines 1292-1361)] — `Change`/`Signature`/`Timestamps`/`ConflictState` shapes, all ACs, change-id-vs-commit-id distinction.
- [Source: epics.md#Story-2.10 (lines 1534-1537, 1561-1564)] — re-export list + `# Errors` doc requirement.
- [Source: prd.md] FR-JJ-6 (change metadata read), FR-JJ-16 (adapter hygiene).
- [Source: docs/adr/0002-repository-state-model-warm-loader-reload-per-operation.md] — reload-per-operation (`load_at_head` per call).
- [Source: crates/zanshin-jj/src/status.rs] — `ChangeId` newtype (48-49), `StatusError`/`be` pattern (52-65), `load_at_head` (85), `@` via view + `get_commit` (88-92), per-parent `reverse_hex` (105-107), `RepoPath`→`PathBuf` (70-72).
- [Source: crates/zanshin-jj/src/repo.rs] — `Repo` struct (39-42), `pub(crate) fn workspace()` (60), `Repo::status` delegation shape (78-80).
- [Source: crates/zanshin-jj/src/revset.rs] — `JjLibError(String)`/`be` flatten pattern; `make_divergent_change` test builder (tests/revset.rs:290).
- [Source: crates/zanshin-jj/tests/status.rs] — `ENV_GUARD`/`pin_env`, `extract_fixture`, oracle-equality discipline.
- [Source: crates/xtask/src/tasks/gen_fixture.rs] — fixture contents: `tiny-3-commits` (linear, no merge/conflict/bookmark, 176-188); `medium-1k-commits` (one 3-parent merge + bookmarks, 190-267).
- [Source: jj-lib 0.41.0 (~/.cargo/.../jj-lib-0.41.0/src/)] — all API anchors above (verified file:line: backend.rs:71/98/102/161/171, repo.rs:135/764, index.rs:216/245/266, store.rs:151, commit.rs:102/106/120/167/171/179/183/187/204, merged_tree.rs:196, repo_path.rs:360, view.rs:149).
- [Source: _bmad-output/implementation-artifacts/deferred-work.md] — `rustfmt max_width` doc drift (real value 120).

## Dev Agent Record

### Agent Model Used

Claude Sonnet 4.6 (1M context)

### Debug Log References

- `.hex()` requires `use jj_lib::object_id::ObjectId as _` — LSP reported as stale but compiler accepted it.
- `change_on_corrupt_repo_returns_backend_error`: must corrupt WHILE the Repo is open (not re-open after corruption), mirrors `status_on_corrupt_repo_returns_backend_error`.
- `ConflictState::Conflicted` integration test deferred to 3.4b per story escape hatch (programmatic conflict construction via jj-lib tree API is impractical without private APIs).

### Completion Notes List

- `crates/zanshin-jj/src/change.rs` — NEW: `Change`, `CommitId`, `Signature`, `Timestamp`, `Timestamps`, `ConflictState`, `ChangeError`, `be`, `to_signature`, `get_change`. All jj-lib types absorbed; no `jj_lib::` in any public signature.
- `crates/zanshin-jj/src/lib.rs` — UPDATED: `pub(crate) mod change;` + 7 re-exports.
- `crates/zanshin-jj/src/repo.rs` — UPDATED: `pub fn get_change(&self, id: &ChangeId)` delegating to `crate::change::get_change`.
- `crates/zanshin-jj/tests/change.rs` — NEW: 11 integration tests covering all ACs (metadata equality oracle, WC parents, NotFound×2, root parents, anonymous×2, merge 3-parents, divergent, clean-conflict, Backend-error).
- All 11 change integration tests green. Full `cargo make test` green (no regressions).

### File List

- `crates/zanshin-jj/src/change.rs` (NEW)
- `crates/zanshin-jj/tests/change.rs` (NEW)
- `crates/zanshin-jj/src/lib.rs` (UPDATED)
- `crates/zanshin-jj/src/repo.rs` (UPDATED)

### Change Log

| Datum | Änderung |
|-------|----------|
| 2026-06-23 | Story 2.6 erstellt (create-story; jj-lib-0.41-Change-API quellenverifiziert via 20-Agenten-Workflow + adversarialer Verifikation aller 13 API-Claims). Reine zanshin-jj-Rust (kein FFI/Wrapper — der `zanshin_change`-Wrapper ist Story 3.4b). Decisions D1-D7 + 5 Open Questions für Ralph (ChangeId-Reuse, raw-Timestamps, is_signed presence-only, divergent-Flag, is_anonymous-Definition). |
| 2026-06-23 | Story 2.6 implementiert (dev-story): change.rs + tests/change.rs neu, lib.rs + repo.rs aktualisiert. cargo make test grün (11 neue Tests, 0 Regressions). Status → review. |
| 2026-06-23 | OQ1-OQ4 von Ralph bestätigt (alle empfohlenen Defaults): ChangeId aus status.rs wiederverwenden, rohe Timestamps (i64 millis + i32 tz-min), `is_signed: bool` presence-only, `divergent: bool` + erstes sichtbares. Story-Body bildete diese Defaults bereits ab — kein Rework. OQ5 (is_anonymous local-only) bleibt offen mit Default. |

## Open Questions for Ralph (non-blocking — defaults chosen, override before dev if desired)

> **OQ1-OQ4 resolved 2026-06-23 (Ralph confirmed every recommended default).** The body of this story
> already encodes these choices — no rework. OQ5 stays open with its recommended default (local-only).

1. **`ChangeId` reuse vs. promote to `id.rs` (Decision D1).** — ✅ **Resolved: (a) reuse `crate::ChangeId` from `status.rs`.**
   - (a) **Reuse `crate::ChangeId` from `status.rs`** (its doc already names this story; zero churn).
   - (b) Promote `ChangeId` to a new shared `id.rs` noun module now (a non-breaking re-export move 2.4 floated).

2. **Timestamp representation (Decision D2).** — ✅ **Resolved: (a) raw `millis_since_epoch: i64` + `tz_offset_minutes: i32`.** (`Timestamps` overlaps `author.timestamp`/`committer.timestamp` by design per the epic's exhaustive list — kept both, documented.)
   - (a) **raw `millis_since_epoch: i64` + `tz_offset_minutes: i32`** (infallible, no `chrono` coupling, maps 1:1 to the 3.4b FlatBuffers wire).
   - (b) `chrono::DateTime<FixedOffset>` via `Timestamp::to_datetime()` (richer, but couples `zanshin-jj` to chrono `=0.4.45` and can fail with `TimestampOutOfRange`).

3. **Cryptographic signature field (Decision D3).** — ✅ **Resolved: (a) `is_signed: bool` (presence-only); full verification deferred to Epic 6 write-side.** (This also locks the 3.4b `Change` FlatBuffers shape.)
   - (a) **`is_signed: bool` (presence-only)** (cheap, honest, no validation — honors epics.md:1333).
   - (b) Keep `Option<Signature>` and populate identity via `verification()` (violates "no validation at this stage"; per-change subprocess cost).

4. **Divergence handling (Decision D4).** — ✅ **Resolved: (a) first visible commit + `divergent: bool` flag.**
   - (a) **returns the first visible commit + `divergent: bool` flag** (surfaces the state to the UI; `feedback-dont-patronize-users`).
   - (b) returns `Err(ChangeError::Divergent { .. })` on divergence.
   - (c) drops the flag and silently returns the first visible commit.

5. **`is_anonymous` definition (Decision D5).** — ⏳ **Open (default: (a) local-only).**
   - (a) **empty description AND no *local* bookmark targets the commit** (recommended — matches the epic text; minimal).
   - (b) also exclude commits referenced only by **remote** bookmarks / tags from "anonymous".
   My recommendation: **(a)** for WIP. Should remote bookmarks / tags count as "named"?

---

## Review Findings — Code Review (2026-06-23)

_Adversarial multi-layer review of the combined 2.6 + 3.4b change slice (8 review lenses → dedup → 2-lens adversarial verify → completeness critic; 61 agents). 9 findings confirmed across both stories, 14 dismissed as noise/PASS (incl. a re-run of `flatc` confirming **zero codegen drift**). This section lists the **2.6 (`zanshin-jj`)** items; FFI/Dart items live in the 3.4b story file._

### Patch

- [x] [Review][Patch] Empty-string `change_id` panics `get_change` (reaches FFI → `internal.panic`, not `jj.change_not_found`) [crates/zanshin-jj/src/change.rs:~144] — `try_from_reverse_hex("")` returns `Some(ChangeId([]))` (0 is even-length), so an empty id **bypasses the malformed guard** and reaches `resolve_change_id`, where an empty `HexPrefix` matches every commit → `AmbiguousMatch` → `panic!("complete change_id should be unambiguous")` for any repo with ≥2 change ids. `Repo::get_change` has no `catch_unwind`, so a direct caller panics; via FFI it degrades to `internal.panic`, violating the documented contract **and** "no `panic!` in library paths reachable from FFI". **Fix:** add `if id.0.is_empty() { return Err(ChangeError::NotFound { id: id.0.clone() }) }` before `resolve_change_id` (4th NotFound mode, extends D6) + an empty-id test at each layer (jj integration, `change_ffi.rs`, Dart worker). _(major — the only real code defect)_
- [x] [Review][Patch] Divergent doc/comment over-promise jj-lib index order as a guarantee [crates/zanshin-jj/src/change.rs:90-91,157] — "jj sorts newer-first" states a hard guarantee, but jj-lib 0.41 `index.rs:217-219` documents target order as only a *preference* ("when possible"). Behaviour is fine (D4: `id` is shared, `divergent==true` set); reword to "index-first visible target; jj prefers newer-first but does not guarantee it".
- [x] [Review][Patch] Non-divergent path (`divergent == false`) never asserted at the integration layer [crates/zanshin-jj/tests/change.rs] — AC-13's second clause is unverified on the real path; an always-true `is_divergent()` regression would pass. **Fix:** `assert!(!change.divergent, …)` on an ordinary-change test.
- [x] [Review][Patch] `is_signed == false` never asserted — `let _ = change.is_signed;` proves nothing [crates/zanshin-jj/tests/change.rs:210] — AC-9's negative clause is unverified; a hard-coded `is_signed = true` regression would pass. (The spec's claim that `is_signed` is "exercised only by the FFI builder/decoder tests" is **false** — the FFI tests reference it nowhere.) **Fix:** `assert!(!change.is_signed, …)` on the unsigned fixture commit.
- [x] [Review][Patch] Divergent test doesn't independently verify the 2-commit divergence [crates/zanshin-jj/tests/change.rs:393-414] — asserts only the shared `id` (passes regardless of which visible commit is picked). Recipe 2-6:401 asked for an independent jj-lib oracle. **Fix:** re-resolve via jj-lib and assert `into_visible().len() == 2`. Do **not** pin `commit_id`/`description` (that asserts the non-guaranteed ordering — see the divergent-doc item).
- [x] [Review][Patch] Conflicted deferral note cites the wrong file [crates/zanshin-jj/tests/change.rs:~438] — the note says Conflicted is exercised in `crates/zanshin-ffi/tests/change_ffi.rs`, but that file has no conflict test; actual synthetic coverage is in `crates/zanshin-ffi/src/change.rs` (`#[cfg(test)]`) + `app/test/ffi/change_test.dart`. **Fix:** correct the file pointer.

### Defer

- [x] [Review][Defer] Oracle-backed real Conflicted-commit test for the `has_conflict()`/`tree().conflicts()` branch [crates/zanshin-jj/tests/change.rs] — deferred, **sanctioned escape-hatch** (2-6:402): programmatic jj-lib conflict construction is impractical without private APIs; the Conflicted→wire mapping is covered synthetically at the FFI builder + Dart decode layers.
- [x] [Review][Defer] Empty author/committer signature (`name`/`email` == "") round-trip never asserted [crates/zanshin-jj/tests/change.rs] — deferred, nit: the builder always calls `create_string` (even for ""), so the documented "may be empty" value round-trips correctly — no correctness risk, only a missing boundary test.
