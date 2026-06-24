---
baseline_commit: 485e289
---

# Story 2.7: Implement `op_log.rs` — operation log read

Status: review

<!-- Note: Validation is optional. Run validate-create-story for quality check before dev-story. -->

> **Scope-correction callout (binding overrides of epic prose):**
>
> 1. **Story 2.7 is PURE `zanshin-jj` Rust.** NO `extern "C"`, NO FlatBuffers, NO FFI, NO codegen, NO `docs/rust-error-codes.md` change, NO `Cargo.toml` change. The `zanshin_op_log` FFI wrapper is a **separate** story (`3-4b-zanshin-op-log-ffi-wrapper`, hard-gated on this one) and the `error.code` registry is minted at the FFI envelope layer, not here. The epic's 3.4b `limit_json = "{\"limit\": 100}"` / "JSON envelope" phrasing (epics.md:2201-2223) predates [ADR-0001](../../docs/adr/0001-ffi-data-transport-flatbuffers.md) and is irrelevant to this story. [verified: sprint-status.yaml:73-74; epics.md:2151-2153,2201-2223]
> 2. **`OperationId` means a crate-own `OperationId(pub String)` newtype**, NOT `jj_lib::op_store::OperationId`. The epic struct (epics.md:1375) writes `id: OperationId` / `parent_ids: Vec<OperationId>` implying the jj-lib type — that would violate FR-JJ-16 (no `jj_lib` type in any public signature). Introduce `pub struct OperationId(pub String)` holding `op.id().hex()`, mirroring `ChangeId(pub String)` / `CommitId(pub String)` (Decision D2). [verified: jj-lib op_store.rs:47 `id_type!(pub OperationId { hex() })`; status.rs:48-49; change.rs CommitId]
> 3. **Operation ids are PLAIN forward hex, NOT reverse-hex.** `ChangeId` uses `reverse_hex()` (the z-k display form); operation ids use `op.id().hex()` (`id_type!(pub OperationId { hex() })`, op_store.rs:47). The "always reverse-hex" habit from 2.5/2.6 **inverts** here — use `.hex()`. Requires `use jj_lib::object_id::ObjectId as _;` (same as change.rs:5). [verified: jj-lib op_store.rs:47; object_id.rs]
> 4. **Timestamps are carried as raw jj values, not `OffsetDateTime`.** The epic writes `timestamp: OffsetDateTime` (epics.md:1375). This story **reuses the existing `crate::Timestamp { millis_since_epoch: i64, tz_offset_minutes: i32 }`** (re-exported from `change.rs` at lib.rs:14) — infallible, no `chrono`/`time` coupling in the public API, FlatBuffers-friendly for 3.4b (mirrors 2.6 Decision D2). Use the operation's **end** time (`metadata.time.end`; jj's own ordering key — `walk_ancestors` sorts by end-time, op_walk.rs:228) (Decision D3 / OQ1). [verified: jj-lib op_store.rs:340-345,417-429; backend.rs:96-107]
> 5. **`-> Vec<Operation>` is refined to `-> Result<Vec<Operation>, OpLogError>`.** The epic shows an infallible `Vec` (epics.md:1368), but the `OpStore` async walk and `load_at_head()` can fail, and every sibling read module returns `Result`. Add `pub enum OpLogError { Backend(String) }` + a `be()` flatten helper (mirrors `StatusError`/`ChangeError`) (Decision D4 / OQ2). [verified: status.rs:52-65; change.rs:96-114]
> 6. **The "non-UTF-8 hostname/username → `String::from_utf8_lossy`" edge AC is MOOT.** jj-lib stores `OperationMetadata.username` / `.hostname` as Rust `String` (already UTF-8 by construction, op_store.rs:419-421). There are no bytes to lossy-convert at this layer. Satisfy the AC with a **doc note** ("jj-lib guarantees UTF-8; no lossy conversion needed"), NOT dead code — an untested `from_utf8_lossy` branch would be flagged by the coverage ratchet (Decision D5 / OQ3, parallel to 2.4's OsString note). [verified: jj-lib op_store.rs:419-421]
> 7. **`is_snapshot: bool` is added to `Operation` beyond the epic's field list.** `OperationMetadata.is_snapshot` (op_store.rs:425) flags pure working-copy-snapshot ops vs. real ops. It is free (already in metadata) and lets the op-log UI / MCP distinguish snapshot noise (matches `feedback-dont-patronize-users`: the backend exposes the capability, the consumer decides). This is a create-story addition (Decision D6 / OQ4). [verified: jj-lib op_store.rs:425]
> 8. **The `< 100 ms` figure is a SOFT design target, not a CI gate.** Performance assertions are deferred to the release phase — no blocking `assert!(elapsed < …)` in a non-`#[ignore]` test (Scope-correction parallel to 2.5 #3 / 2.6 #6). [verified: project-context.md "Performance assertions — DEFERRED"; epics.md:343 "NFRs: None enforced in WIP"]

---

## Story

As a Rust caller wanting to display the operation log,
I want `zanshin-jj` to expose `Repo::op_log(limit: Option<usize>) -> Result<Vec<Operation>, OpLogError>` returning a reverse-chronologically ordered list of operations (id, parent ids, raw end-timestamp, user, host, jj's user-friendly description, root-op flag, snapshot flag),
So that the `zanshin_op_log` FFI wrapper (Story 3.4b) and the MCP `op_log` tool (Story 7.3, calls `zanshin-jj` directly) can render the op-log UI / serve `op_log` queries (FR-JJ-7), with all jj-lib API churn absorbed inside the adapter (FR-JJ-16).

## Acceptance Criteria

Grouped by deliverable. Each item is a checkable contract. Source is `epics.md#Story 2.7` (lines 1365-1420) unless noted; where this story corrects the epic, the correction is flagged inline and justified in the Scope-correction callout / Dev Notes.

### AC-1 — Public surface: `Repo::op_log` + module wiring (FR-JJ-7) [epics.md:1367-1369,1396-1399]

1. `crates/zanshin-jj/src/op_log.rs` exists. `crates/zanshin-jj/src/repo.rs` gains a public method `pub fn op_log(&self, limit: Option<usize>) -> Result<Vec<crate::Operation>, crate::OpLogError>` that delegates to a `pub(crate) fn op_log::op_log(workspace: &Workspace, limit: Option<usize>) -> Result<Vec<Operation>, OpLogError>` (the established "method-on-`Repo` → `pub(crate)` free fn taking `&Workspace`" shape, mirroring `Repo::status` → `status::working_copy_status` and `Repo::get_change` → `change::get_change`).
2. The implementation is **synchronous** (no `async`, no `tokio`); the only async bridge is `pollster::block_on`, exactly as `status.rs:85` / `change.rs:139` do.
3. No `jj_lib::*` type appears in the public signature of `op_log`, in the `Operation` / `OperationId` types, or in any `OpLogError` variant (FR-JJ-16).
4. The implementation queries jj-lib's operation store directly (via the `op_walk`/`Operation` wrappers over `OpStore`) and **does NOT shell to `jj op log`** (AR-AP-1) nor parse CLI output (AR-AP-2). [epics.md:1396-1399]

### AC-2 — `Operation` struct shape (FR-JJ-7) [epics.md:1373-1375; corrections per Scope-corrections #2,#3,#4,#7]

5. `op_log.rs` defines:
   ```rust
   pub struct Operation {
       pub id: OperationId,            // plain forward hex (op.id().hex()) — D2/D3
       pub parent_ids: Vec<OperationId>, // parent op ids in jj order; empty for the root op
       pub timestamp: crate::Timestamp,  // raw jj end-time (metadata.time.end) — D3, replaces epic OffsetDateTime
       pub user: String,              // metadata.username — may be empty
       pub host: String,              // metadata.hostname — may be empty
       pub description: String,       // jj's user-friendly op summary; always present, may be empty
       pub root_op: bool,             // true iff this is the op-store root operation
       pub is_snapshot: bool,         // pure working-copy-snapshot op (metadata.is_snapshot) — D6, create-story addition
   }
   ```
   `#[derive(Debug, Clone, PartialEq, Eq)]`. Every `pub` item carries a `///` doc comment (clippy pedantic). The epic's `id: OperationId` / `parent_ids: Vec<OperationId>` are the crate-own newtype (item 6), and `timestamp: OffsetDateTime` is the raw `crate::Timestamp` (Scope-correction #4).
6. `pub struct OperationId(pub String);` — a `jj_lib`-type-free newtype mirroring `ChangeId`/`CommitId`, holding `op.id().hex()` (**plain forward hex**, NOT reverse-hex — Scope-correction #3). `#[derive(Debug, Clone, PartialEq, Eq)]`; doc-commented that it is the jj operation id in forward-hex display form.
7. `Operation.timestamp` is **`crate::Timestamp`** (reused from `change.rs` via lib.rs:14 — do NOT redefine), built from `metadata.time.end` (`millis_since_epoch = md.time.end.timestamp.0`, `tz_offset_minutes = md.time.end.tz_offset`). [verified: jj-lib op_store.rs:340-345; backend.rs:96-107]

### AC-3 — Ordering: reverse-chronological, root op last [epics.md:1377-1380]

8. `op_log(None)` on `tiny-3-commits` returns the operation history with the **head (most recent) operation first** and the **root operation as the last element**. The order is jj's reverse-topological walk (`op_walk::walk_ancestors`), which **prefers** newer-first for a mostly-linear history (it is not a strict total guarantee for forked histories — op_walk.rs doc). Assert the pinned invariants — head-op-first, **root-op-last** — rather than a strict total order over every pair. [epics.md:1379-1380; carry-forward 2.6 review #10]
9. The returned `Vec` is non-empty for any opened repo (the head op and root op always exist).

### AC-4 — Limit: at most N most-recent ops [epics.md:1382-1384]

10. `op_log(Some(10))` returns at most 10 operations (the 10 most recent). `op_log(Some(1))` returns exactly 1 (the most recent / head op). Apply the limit by short-circuiting the walk after `n` items (do NOT collect-all-then-truncate).
11. `op_log(Some(0))` returns an empty `Vec` cleanly (no panic). `op_log(None)` returns the full history ("all"); the caller is responsible for sane limits on pathological repos (epics.md:1409-1410).

### AC-5 — `description` is jj's stored summary, not a CLI reconstruction [epics.md:1386-1389]

12. `Operation.description` is whatever jj-lib stores as `OperationMetadata.description` (e.g. `"snapshot working copy"`, `"describe commit …"`, `"new empty commit"`) — it is **NOT** a reconstructed CLI argument list. It is always present and may be empty (the root op's description is `""`). Do not synthesize or reformat it. [epics.md:1388-1389]

### AC-6 — Parents: single for linear ops, empty for root, multi for DAG forks [epics.md:1391-1394,1417-1420]

13. For a regular (non-root) operation, `parent_ids` contains its parent op id(s) in jj order — a single parent for linear history.
14. For the **root** operation, `parent_ids` is empty (`Vec::new()`) and `root_op == true`. `root_op` is computed as `op.id() == readonly.op_store().root_operation_id()` (equivalently `parent_ids.is_empty()`). [verified: jj-lib op_store.rs:467,386-413]
15. jj's op-log is a DAG — a forked/parallel operation may have **multiple** `parent_ids`. The mapping preserves all parents in jj order; downstream consumers (3.4b FFI / Epic 7 MCP) handle multi-parent ops. (Hard to construct deterministically in a unit test — may be documented-as-deferred to the 3.4b builder/decoder tests, but try first; see Test recipe.) [epics.md:1417-1420]

### AC-7 — `OpLogError` enum + flatten helper [Scope-correction #5]

16. `#[derive(Debug, thiserror::Error)] pub enum OpLogError { Backend(String) }` with `#[error("jj-lib error: {0}")]` and a `///` doc comment on the variant. `Backend(String)` is the opaque catch-all for any jj-lib failure (mirrors `StatusError::Backend` / `ChangeError::Backend`). There is **no** "not found" variant — listing the log never misses (the head op and root op always exist).
17. A private `fn be<E: std::fmt::Display>(e: E) -> OpLogError { OpLogError::Backend(e.to_string()) }` flattens every jj-lib failure (`RepoLoaderError` from `load_at_head`, `OpStoreError` from the walk) to `Backend(String)` via `Display` so no `jj_lib` type escapes (FR-JJ-16). [verified: jj-lib op_walk.rs (OpStoreResult); status.rs:62-65]

### AC-8 — UTF-8 / lossy edge documented, not coded [Scope-correction #6]

18. `user` / `host` map directly from `OperationMetadata.username` / `.hostname` (already `String`). The epic's "non-UTF-8 → `from_utf8_lossy`" edge (epics.md:1412-1415) is satisfied **by construction** — document on the `Operation` type that jj-lib guarantees UTF-8 and no lossy conversion is performed. Do NOT add an untested `from_utf8_lossy` branch (coverage ratchet would flag it).

### AC-9 — Integration-test coverage [epics.md:1401-1403]

19. `crates/zanshin-jj/tests/op_log.rs` exists and covers **at minimum**:
    - full log on `tiny-3-commits` (`op_log(None)`) → non-empty, **head op first**, **root op is the last element** with empty `parent_ids` and `root_op == true` (AC-3, AC-6);
    - `op_log(Some(1))` → exactly 1 operation, the most recent (AC-4);
    - the root op → empty `parent_ids`, `root_op == true`, `description == ""` (AC-6, AC-5);
    - a **non-root** op → `root_op == false` and `parent_ids` non-empty (assert BOTH sides of the boolean — carry-forward 2.6 review #2);
    - **equality** of at least one op's `id` / `description` / `user` / `host` against an independent jj-lib oracle (AC-5; equality, not non-emptiness — carry-forward 2.4 hardening).
20. The `OpLogError::Backend` variant is exercised — directly if a deterministic trigger is feasible (corrupt the repo while open — e.g. `fs::remove_dir_all(.jj/repo/op_heads)` after `Repo::open`, so the re-resolve/walk fails → `Backend`), otherwise via a focused unit test of the `be()` helper with a documented reason. [carry-forward 2.4/2.6 review: test ALL public error variants]
21. Do **not** hard-code an exact op count for the fixture: `gen-fixture` writes commits via the store (not one transaction per commit), so the precise op count is not statically knowable. Assert structural properties (≥1 op, root-last, root parents empty, head-first, reverse-chron) computed against an oracle (Scope-correction; OQ5).

### AC-10 — Public-API hygiene + docs (Story 2.10 prerequisites) [epics.md:1536-1537,1561-1564]

22. `lib.rs` adds `pub(crate) mod op_log;` and `pub use op_log::{OpLogError, Operation, OperationId};`. `crate::Timestamp` is reused (no re-export added — it already comes from `change.rs` at lib.rs:14). `crate::ChangeId` is **not** used by op_log. No `pub use jj_lib::...` is added.
23. `Repo::op_log` carries a `///` doc comment **including a `# Errors` section** mapping `OpLogError::Backend` to its trigger and a note that the read re-resolves to the head operation per call (ADR-0002); carries `#[must_use = "the Result must be used; drop it explicitly if intentional"]`. The `pub(crate) fn op_log` carries the same `# Errors` section. Every new `pub` item is doc-commented (clippy pedantic).

### AC-11 — Quality gate green (coverage ratchet) [CLAUDE.md; docs/coverage.md]

24. `cargo make test` passes end-to-end: `cargo test`, `cargo clippy --workspace --all-targets -- -D warnings` (pedantic — **refactor, don't `#[allow]`**; any unavoidable suppression carries a `// WHY:`), `cargo fmt --all --check`, `cargo deny check advisories bans`, the Dart suite, and the **coverage ratchet** (`cargo make coverage`). The new file `crates/zanshin-jj/src/op_log.rs` reaches the per-file floor (≥ 80 %; aim for 100 % like `change.rs`/`revset.rs`); the auto-raised `coverage-baseline.txt` entry is committed with the code. `crates/zanshin-jj/src/repo.rs` stays ≥ its current 90.96 % (the one-line delegate is covered by any passing `op_log` integration test). **Never lower the baseline or add an `exclude_prefix` to dodge testing.** [verified: coverage-baseline.txt; CLAUDE.md coverage ratchet]

## Tasks / Subtasks

- [x] **T1 — Domain types** (AC: 5, 6, 7, 8)
  - [x] In `src/op_log.rs` (SPDX `// SPDX-License-Identifier: MIT` line 1): define `Operation` and `OperationId(pub String)` with `#[derive(Debug, Clone, PartialEq, Eq)]` + `///` docs. Reuse `use crate::Timestamp;` for the `timestamp` field (do **not** redefine — D2/D3). Doc-note on `user`/`host` that jj-lib guarantees UTF-8 (D5).
- [x] **T2 — `OpLogError` enum + `be` helper** (AC: 16, 17)
  - [x] `#[derive(Debug, thiserror::Error)] pub enum OpLogError { #[error("jj-lib error: {0}")] Backend(String) }` with a per-variant `///`; `fn be<E: std::fmt::Display>(e: E) -> OpLogError { OpLogError::Backend(e.to_string()) }`.
- [x] **T3 — `op_log` body** (AC: 1, 2, 3, 4, 5, 6, 7) — the verified call sequence (see Dev Notes)
  - [x] Reload to head: `let readonly = pollster::block_on(workspace.repo_loader().load_at_head()).map_err(be)?;` (ADR-0002 reload-per-call, mirrors `status.rs:85`).
  - [x] Capture `let root_id = readonly.op_store().root_operation_id().clone();` and `let head_op = readonly.operation().clone();` (`use jj_lib::repo::Repo as _;` for `op_store()`).
  - [x] Drive `jj_lib::op_walk::walk_ancestors(std::slice::from_ref(&head_op))` with `pollster::block_on` + `futures::StreamExt::next` (`use futures::StreamExt as _;`); for each `OpStoreResult<Operation>` → `.map_err(be)?`; short-circuit when `limit` reached (`Some(n)` and `out.len() >= n` → break before pushing).
  - [x] Per op: `OperationId(op.id().hex())` (`use jj_lib::object_id::ObjectId as _;`); `parent_ids` = `op.parent_ids().iter().map(|p| OperationId(p.hex())).collect()`; `md = op.metadata()`; `timestamp` from `md.time.end`; `user = md.username.clone()`; `host = md.hostname.clone()`; `description = md.description.clone()`; `root_op = op.id() == &root_id`; `is_snapshot = md.is_snapshot`.
- [x] **T4 — `Repo::op_log` method** (AC: 1, 23)
  - [x] In `src/repo.rs` (after `get_change`, before `Repo::open`): `pub fn op_log(&self, limit: Option<usize>) -> Result<Vec<crate::Operation>, crate::OpLogError> { crate::op_log::op_log(self.workspace(), limit) }` with `///` + `# Errors` + `#[must_use = "the Result must be used; drop it explicitly if intentional"]`.
- [x] **T5 — Wire module + re-exports** (AC: 22)
  - [x] `lib.rs`: add `pub(crate) mod op_log;` (after `pub(crate) mod change;`) + `pub use op_log::{OpLogError, Operation, OperationId};`.
- [x] **T6 — Docs** (AC: 23)
  - [x] `///` on every `pub` item; `# Errors` on `Repo::op_log` and the `pub(crate) fn`; `#[must_use]` on the method.
- [x] **T7 — Integration tests `tests/op_log.rs`** (AC: 19, 20, 21)
  - [x] Mirror `tests/change.rs` / `tests/status.rs` scaffolding (ENV_GUARD/pin_env, make_test_settings, `extract_fixture`). Oracle equality; both-sides boolean asserts; Backend-error test; no hard-coded op count; no timing assert.
- [x] **T8 — Green gate** (AC: 24)
  - [x] `cargo make test` green incl. coverage ratchet; clippy pedantic; fmt; cargo deny. Commit the auto-raised `coverage-baseline.txt`. Grep the public surface: no `jj_lib::` in any `op_log` public signature.

## Dev Notes

### Decision D1 — Module shape: `Repo::method` → `pub(crate) fn(&Workspace)` (mirror 2.4/2.6, NOT 2.5)

`src/op_log.rs` owns the types **and** `pub(crate) fn op_log(workspace: &Workspace, limit: Option<usize>) -> Result<Vec<Operation>, OpLogError>`. `src/repo.rs` adds the thin public method delegating to it. Rationale: `Repo`'s `workspace`/`settings` fields are private to `repo.rs`; sibling modules reach the workspace via the existing `pub(crate) fn workspace(&self) -> &Workspace` accessor (repo.rs:60) — **reuse it, do not re-add**. op_log needs only the workspace (not `settings`), so it mirrors the `status`/`change` `&Workspace` signature, NOT the `revset.rs` `&Repo` exception. [verified: repo.rs:60-67,78-94]

### Decision D2 — `OperationId(pub String)` newtype, forward hex (FR-JJ-16)

The epic's `OperationId` is jj-lib's type (FR-JJ-16 violation). Introduce a crate-own `pub struct OperationId(pub String)` from `op.id().hex()`. **Plain forward hex**, NOT `reverse_hex()` — operation ids are not change ids (`id_type!(pub OperationId { hex() })`, op_store.rs:47; `reverse_hex` is a `ChangeId`-only concept). Bring the trait into scope with `use jj_lib::object_id::ObjectId as _;` (same as change.rs:5). [verified: jj-lib op_store.rs:47; object_id.rs]

### Decision D3 — Raw `crate::Timestamp` from `metadata.time.end` (mirror 2.6 D2)

Reuse the existing `crate::Timestamp { millis_since_epoch: i64, tz_offset_minutes: i32 }` (lib.rs:14, defined in change.rs). The op's metadata carries a `TimestampRange { start, end }`; use **`time.end`** (the op completion time — jj's own ordering key in `walk_ancestors`, op_walk.rs:228). Map exactly as `change.rs`'s `to_signature` does: `millis_since_epoch = md.time.end.timestamp.0`, `tz_offset_minutes = md.time.end.tz_offset`. `tz_offset` is minutes **east of UTC**. This locks the 3.4b FlatBuffers wire (`timestamp_millis: long` + `tz_offset_minutes: int`, matching the existing `Signature` table at schemas/envelope.fbs:76-81). [verified: jj-lib op_store.rs:340-345,417-429; backend.rs:96-107; change.rs:117-126]

### Decision D4 — Fallible signature `Result<Vec<Operation>, OpLogError>`

The walk + `load_at_head` can fail; siblings all return `Result`. Single-variant `OpLogError { Backend(String) }` + `be()` flatten (there is no "not found" — the head/root op always exist). [verified: status.rs:52-65; change.rs:96-114]

### Decision D5 — UTF-8 is by construction (no dead code)

`OperationMetadata.username`/`.hostname` are `String` (op_store.rs:419-421). The epic's lossy-conversion AC is satisfied by a doc note; adding a `from_utf8_lossy` branch would be untested dead code the coverage ratchet flags. (Parallel to 2.4's OsString note.)

### Decision D6 — `is_snapshot: bool` added (create-story addition)

`OperationMetadata.is_snapshot` (op_store.rs:425) distinguishes pure working-copy-snapshot ops from real ops. Cheap, honest, no validation; lets the op-log UI / MCP gray-out or filter snapshot noise. Expose-all, no filtering (full history per the epic). [matches `feedback-dont-patronize-users`]

### jj-lib 0.41.0 op-log API anchors — VERIFIED against source

All under `~/.cargo/registry/src/index.crates.io-1949cf8c6b5b557f/jj-lib-0.41.0/src/`. jj-lib pinned `=0.41.0` (Cargo.toml workspace dep; `crates/zanshin-jj/Cargo.toml:16` uses `jj-lib = { workspace = true }`).

```
repo::ReadonlyRepo::operation(&self) -> &Operation                       repo.rs:301  (the head op — START of the walk)
repo::ReadonlyRepo::op_id(&self) -> &OperationId                         repo.rs:297
repo::Repo::op_store(&self) -> &Arc<dyn OpStore>                         repo.rs:358  (trait method — `use jj_lib::repo::Repo as _;`)
op_store::OpStore::root_operation_id(&self) -> &OperationId             op_store.rs:467  (root-op detection)
operation::Operation::id(&self) -> &OperationId                         operation.rs:97
operation::Operation::parent_ids(&self) -> &[OperationId]               operation.rs:105  (SYNC; empty ⇒ root)
operation::Operation::metadata(&self) -> &OperationMetadata             operation.rs:122  (SYNC)
op_store::OperationMetadata {                                           op_store.rs:417-429
    pub time: TimestampRange,        // .start / .end : Timestamp
    pub description: String,         // jj's user-friendly summary (NOT a CLI reconstruction)
    pub hostname: String,
    pub username: String,
    pub is_snapshot: bool,           // pure working-copy snapshot op
    pub workspace_name: Option<WorkspaceNameBuf>,
    pub attributes: BTreeMap<String, String>,
}
op_store::TimestampRange { pub start: Timestamp, pub end: Timestamp }    op_store.rs:340-345
backend::Timestamp { pub timestamp: MillisSinceEpoch(i64), pub tz_offset: i32 }  backend.rs:96-107
op_store: id_type!(pub OperationId { hex() })                           op_store.rs:47
object_id::ObjectId::hex(&self) -> String                              object_id.rs  (PLAIN hex — Scope-correction #3)
op_walk::walk_ancestors(head_ops: &[Operation])
    -> impl Stream<Item = OpStoreResult<Operation>>                    op_walk.rs:266-290  (reverse-topological, most-recent-first; lazy)
```

**Three load-bearing gotchas:**
- **GOTCHA 1 — `hex()`, not `reverse_hex()`** for op ids (Scope-correction #3 / D2).
- **GOTCHA 2 — `walk_ancestors` is an async `Stream`, not an iterator.** Drive it like `status.rs` drains its copy/diff stream: `use futures::StreamExt as _;` (already a `[dependencies]` of zanshin-jj — Cargo.toml:14) + `pollster::block_on(async { while let Some(item) = stream.next().await { … } })`. Each item is `OpStoreResult<Operation>` → `.map_err(be)?`. Apply `limit` by breaking after `n` items.
- **GOTCHA 3 — root detection.** `op.id() == readonly.op_store().root_operation_id()` (explicit) or `op.parent_ids().is_empty()` (equivalent; the root op is the only parentless op — `Operation::make_root` sets `parents: vec![]`, op_store.rs:386-413). The root op's metadata is all-empty (`description == ""`, millis == 0).

### The verified call sequence (copy-adaptable skeleton for `op_log.rs`)

```rust
// SPDX-License-Identifier: MIT

//! `op_log.rs` — jj operation-log read (FR-JJ-7).
//!
//! Exposes a `jj_lib`-type-free view of jj's operation log: a reverse-
//! chronological list of operations (head first, root last). The read
//! re-resolves to the head operation per call (ADR-0002) and never shells to
//! the `jj` CLI (AR-AP-1).

use futures::StreamExt as _;
use jj_lib::object_id::ObjectId as _; // for OperationId::hex()
use jj_lib::op_walk;
use jj_lib::repo::Repo as _;          // for ReadonlyRepo::op_store()
use jj_lib::workspace::Workspace;

use crate::Timestamp; // reuse the raw Timestamp from change.rs (millis_since_epoch + tz_offset_minutes)

/// A jj operation-log id in plain forward-hex display form (e.g. "abc123…").
/// NOT reverse-hex — operation ids are not change ids. `jj_lib`-type-free (FR-JJ-16).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OperationId(pub String);

/// One entry in jj's operation log (FR-JJ-7).
///
/// `user`/`host` come from jj-lib `String` fields and are UTF-8 by construction
/// (no lossy conversion needed).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Operation {
    /// Forward-hex op id (`op.id().hex()`).
    pub id: OperationId,
    /// Parent op ids in jj order; empty for the root op. May have >1 (DAG fork).
    pub parent_ids: Vec<OperationId>,
    /// Operation completion time (`metadata.time.end`), raw jj timestamp.
    pub timestamp: Timestamp,
    /// `metadata.username` — may be empty.
    pub user: String,
    /// `metadata.hostname` — may be empty.
    pub host: String,
    /// jj's user-friendly op description; always present, may be empty.
    pub description: String,
    /// True iff this is the op-store root operation (parents empty).
    pub root_op: bool,
    /// True if a pure working-copy snapshot op (`metadata.is_snapshot`).
    pub is_snapshot: bool,
}

/// Errors returned by [`crate::Repo::op_log`].
#[derive(Debug, thiserror::Error)]
pub enum OpLogError {
    /// An underlying jj-lib failure (op-store read / loader / walk),
    /// opaque-string-wrapped so no `jj_lib` type escapes the public API (FR-JJ-16).
    #[error("jj-lib error: {0}")]
    Backend(String),
}

/// Converts any jj-lib error to [`OpLogError::Backend`].
fn be<E: std::fmt::Display>(e: E) -> OpLogError {
    OpLogError::Backend(e.to_string())
}

/// Reads the operation log, most-recent-first, root op last (FR-JJ-7).
///
/// Re-resolves to the head operation every call (ADR-0002). Read-only; never
/// shells to `jj op log` (AR-AP-1). `limit = None` means "all"; `Some(0)`
/// returns an empty `Vec`.
///
/// # Errors
/// - [`OpLogError::Backend`] — `load_at_head` or the op-store walk failed; the
///   jj-lib reason is forwarded as a string.
pub(crate) fn op_log(workspace: &Workspace, limit: Option<usize>) -> Result<Vec<Operation>, OpLogError> {
    let readonly = pollster::block_on(workspace.repo_loader().load_at_head()).map_err(be)?;
    let root_id = readonly.op_store().root_operation_id().clone();
    let head_op = readonly.operation().clone();

    let mut out = Vec::new();
    pollster::block_on(async {
        let mut stream = op_walk::walk_ancestors(std::slice::from_ref(&head_op));
        while let Some(item) = stream.next().await {
            if let Some(n) = limit {
                if out.len() >= n {
                    break;
                }
            }
            let op = item.map_err(be)?;
            let md = op.metadata();
            let end = md.time.end;
            out.push(Operation {
                id: OperationId(op.id().hex()),
                parent_ids: op.parent_ids().iter().map(|p| OperationId(p.hex())).collect(),
                timestamp: Timestamp {
                    millis_since_epoch: end.timestamp.0,
                    tz_offset_minutes: end.tz_offset,
                },
                user: md.username.clone(),
                host: md.hostname.clone(),
                description: md.description.clone(),
                root_op: op.id() == &root_id,
                is_snapshot: md.is_snapshot,
            });
        }
        Ok::<(), OpLogError>(())
    })?;
    Ok(out)
}
```

(The `repo.rs` delegate and the `lib.rs` re-export are in T4/T5. Note: the exact jj-lib types in intermediate `let`s — `Operation`, `OperationMetadata`, `Timestamp` — never appear in any `pub` signature, satisfying FR-JJ-16.)

### Test recipe (mirror `tests/change.rs` / `tests/status.rs` — do NOT invent a new harness)

Reuse the scaffolding from `tests/change.rs:1-53` / `tests/status.rs:1-51`:
- SPDX line 1; `static ENV_GUARD: LazyLock<()>` pinning `JJ_CONFIG=""` + `GIT_CONFIG_GLOBAL=""` inside `unsafe`; `fn pin_env() { LazyLock::force(&ENV_GUARD); }` called first in every test (test hermeticity — no global `~/.jjconfig.toml`/`~/.gitconfig`).
- `fn make_test_settings() -> UserSettings` (the `[user]` + `[operation] username/hostname` literal — verbatim from change.rs:36-53).
- Open fixture: `let fx = extract_fixture("tiny-3-commits").unwrap(); let repo = Repo::open(&fx.path).unwrap();` — **keep `fx` bound for the whole test** (it owns a `TempDir`). `test-helpers` path dev-dep is already present (Cargo.toml:22).
- **Oracle:** open the workspace independently via jj-lib (`Workspace::load` → `repo_loader().load_at_head()` → `readonly.operation()` + `op_walk::walk_ancestors`) and read `op.id().hex()` / `op.metadata().description` / `.username` / `.hostname` directly; assert **EQUALITY** against `repo.op_log()`'s result (never mere non-emptiness for id/metadata fields).
- **Grow the log to assert >1 op + a non-root op:** drive a transaction (`repo.start_transaction()` + `tx.commit("test op")`, as `tests/change.rs:58-205` helpers do) — each transaction creates a NEW operation, giving a non-root op whose `parent_ids` is non-empty and `root_op == false`.
- **Backend error:** mirror `change_on_corrupt_repo_returns_backend_error` (tests/change.rs:598-617) — `Repo::init` into a fresh `TempDir` (`let tmp = TempDir::new()?; let repo = Repo::init(tmp.path())?;`), then corrupt it *while open* via `fs::remove_dir_all(tmp.path().join(".jj").join("repo").join("op_heads"))`, then assert `repo.op_log(None)` returns `Err(OpLogError::Backend(_))` (the re-resolve/walk fails). This is especially apt because op_log reads the op-heads store. (Use the `tmp`/`init` handle here, NOT the `fx`/fixture handle from the happy-path tests.)
- **Fixture identity note:** `gen-fixture` sets `[operation] username = "fixture"`, `hostname = "zanshin.test"` (gen_fixture.rs:116-117); opening with `make_test_settings()` may add a working-copy-snapshot op under the test identity. Do NOT hard-code identities or op counts — derive expectations from the oracle (OQ5).
- Naming: `op_log_on_<condition>_returns_<result>` (e.g. `op_log_on_tiny_returns_history_with_root_op_last`, `op_log_with_limit_one_returns_most_recent`, `op_log_root_op_has_empty_parents_and_root_op_true`, `op_log_non_root_op_has_parents_and_root_op_false`, `op_log_on_corrupt_repo_returns_backend_error`). No `#[serial]`, no network, no `#[ignore]`/skip-for-flakiness, no timing assert.

### Previous-story intelligence (2.4 status, 2.5 revset, 2.6 change) — pre-empt the known traps

1. **Assert BOTH sides of every boolean AC** (2.6 review: `let _ = x;` "proves nothing"). Here: `root_op == true` on the root **and** `root_op == false` on a non-root op; `parent_ids.is_empty()` on root **and** `parent_ids` non-empty on a regular op.
2. **Equality oracle, never non-emptiness** for id/metadata fields (2.4 hardening, repeated every story).
3. **Test ALL public error variants** — exercise `OpLogError::Backend` (corrupt-while-open trigger).
4. **`use jj_lib::repo::Repo as _;`** to alias the jj `Repo` trait away from the crate's `pub struct Repo`; **`use jj_lib::object_id::ObjectId as _;`** for `.hex()`. (2.6 Debug Log: LSP may report these `as _` imports as stale while the compiler accepts them — trust the compiler.)
5. **One clippy-pedantic fix per story is normal — refactor, don't `#[allow]`.** An unavoidable `#[allow]` needs a `// WHY:`. (`needless_pass_by_value` etc. resolved by `Clone`/`Copy` or borrowing.)
6. **`cargo fmt --check` enforces the committed `rustfmt.toml`** — the committed `max_width` is **120** (rustfmt.toml:6), not the `100` quoted in project-context.md (tracked doc drift). Don't treat 100 as the budget; let `cargo fmt` decide.
7. **`pollster::block_on` is the only async bridge**; the crate stores no runtime; the public API is sync (jj-lib is sync — do NOT wrap in `async`/`tokio`).
8. **Reverse-topological order is jj's PREFERENCE, not a hard guarantee** (`walk_ancestors` doc: "works so long as the operation history is mostly linear"). Word AC-3 as "head-op first / root-op last" pinned invariants, not a strict total order.
9. **DAG/forked op-log (multi-parent)** is hard to construct deterministically in a `zanshin-jj` unit test — try first; if not feasible, document-as-deferred to the 3.4b builder/decoder tests (which can synthesize a multi-parent `Operation`), and don't fake it (don't cite the wrong file in the deferral note — 2.6 review caught exactly that).

### Files this story touches

| File | Action | What |
|------|--------|------|
| `crates/zanshin-jj/src/op_log.rs` | **NEW** | `Operation`, `OperationId`, `OpLogError`, `be`, `pub(crate) fn op_log(workspace, limit)`. SPDX line 1. |
| `crates/zanshin-jj/tests/op_log.rs` | **NEW** | Integration tests (full/limit/root + oracle equality + Backend + both-sides booleans). SPDX line 1. |
| `crates/zanshin-jj/src/lib.rs` | UPDATE | add `pub(crate) mod op_log;` + `pub use op_log::{OpLogError, Operation, OperationId};`. |
| `crates/zanshin-jj/src/repo.rs` | UPDATE | add `pub fn op_log(&self, limit: Option<usize>) -> Result<Vec<crate::Operation>, crate::OpLogError>` delegating to `crate::op_log::op_log(self.workspace(), limit)`. |
| `coverage-baseline.txt` | UPDATE | auto-raised `crates/zanshin-jj/src/op_log.rs = <pct>` entry; commit with the code. |

**No `Cargo.toml` change** — `jj-lib`, `pollster`, `futures`, `thiserror`, `chrono` (deps) and `tempfile`/`test-helpers` (dev-deps) are all already present (Cargo.toml:12-22). `crate::Timestamp` is reused → no new `chrono`/`time` coupling.

### Hard rules in scope (from project-context.md — reject-at-review on violation)

- **NO `extern "C"` outside `zanshin-ffi`** — `op_log.rs` is pure-Rust `lib`. The FFI wrapper is Story 3.4b.
- **NO shelling to / parsing the `jj` CLI** — all access via `jj-lib` (AR-AP-1/AR-AP-2). `zanshin-jj` is the ONLY crate importing `jj_lib`.
- **NO `jj_lib` type in any public signature** (FR-JJ-16) — `Operation`/`OperationId`/`OpLogError` are crate-own.
- **NO `unwrap()`/`expect()`/`panic!()`** in code reachable from FFI; **NO `async`/`tokio`** wrapping of sync jj-lib (`pollster::block_on` is the sole bridge).
- **SPDX `// SPDX-License-Identifier: MIT` on line 1** of every new `.rs`.
- **NO lowering the coverage baseline / no `exclude_prefix`** to dodge testing — add tests instead.

### Project Structure Notes

`op_log.rs` is a NOUN-named read module (no `mod.rs`), slotting between `change.rs` and `bookmarks.rs` per architecture.md:422 (`op_log.rs # FR-JJ-7, 14`). Inline `#[cfg(test)]` is **not** used (change.rs/status.rs keep their tests in `tests/`); op_log follows — integration tests in `crates/zanshin-jj/tests/op_log.rs`. `lib.rs` stays re-exports + docs only.

### References

- [Source: epics.md#Story 2.7 (lines 1365-1420)] — user story, ACs, edge cases.
- [Source: epics.md#Story 2.7 FRs] — FR-JJ-7 (op-log read, line 37), FR-JJ-16 (adapter stability, line 49), AR-AP-1/2 (no shelling/parsing, lines 205-206).
- [Source: docs/adr/0002-repository-state-model-warm-loader-reload-per-operation.md] — reload-per-call.
- [Source: crates/zanshin-jj/src/{lib.rs:9-17, repo.rs:60-94, change.rs, status.rs}] — the read-module template + reused `crate::Timestamp`/`workspace()`.
- [Source: crates/zanshin-jj/tests/{change.rs:1-205, status.rs:1-51}] — test harness, oracle pattern, transaction helpers, corrupt-repo Backend test.
- [Source: jj-lib-0.41.0/src/{operation.rs:97-122, op_store.rs:47,340-345,417-429,467, op_walk.rs:266-290, repo.rs:297-301,358, object_id.rs, backend.rs:96-107}] — verified op-log API anchors.
- [Source: coverage-baseline.txt] — `new_file_floor_pct = 80.00`; current `change.rs = 100.00`, `repo.rs = 90.96`.
- [Source: crates/xtask/src/tasks/gen_fixture.rs:116-117] — fixture `[operation]` identity.

## Dev Agent Record

### Agent Model Used

claude-sonnet-4-6

### Debug Log References

- `Box::pin()` required on `op_walk::walk_ancestors` stream — the returned `impl Stream` is not `Unpin`, so `.next().await` inside a `while let` fails without pinning. Fixed by `Box::pin(op_walk::walk_ancestors(...))`.

### Completion Notes List

- All 10 integration tests in `tests/op_log.rs` pass; coverage auto-raised to 100% in `coverage-baseline.txt`.
- `OperationId` uses forward hex (`op.id().hex()`), not reverse-hex — critical difference from `ChangeId`.
- Corrupt-repo Backend error test removes `.jj/repo/op_heads` while the repo is open; the subsequent `op_log(None)` call triggers `load_at_head` failure → `OpLogError::Backend`.
- `walk_ancestors` stream is not `Unpin`; required `Box::pin()` (matches `benches/graph_blueprint.rs` pattern).

### File List

- `crates/zanshin-jj/src/op_log.rs` (NEW)
- `crates/zanshin-jj/tests/op_log.rs` (NEW)
- `crates/zanshin-jj/src/lib.rs` (MODIFIED)
- `crates/zanshin-jj/src/repo.rs` (MODIFIED)
- `coverage-baseline.txt` (MODIFIED — auto-raised)

### Change Log

| Datum | Änderung |
|-------|----------|
| 2026-06-24 | create-story: comprehensive context engineered (jj-lib 0.41 op-log API source-verified; FlatBuffers/raw-timestamp reconciliations from 2.6 carried forward). Status → ready-for-dev. |
| 2026-06-24 | dev-story: implemented `op_log.rs`, integration tests (10 tests), wired `Repo::op_log`, re-exports. `cargo make test` green; coverage 100%. Status → review. |

## Open Questions for Ralph (non-blocking — defaults chosen, override before dev if desired)

1. **OQ1 — Timestamp: end vs start (default = `end`).** `metadata.time` is a `TimestampRange { start, end }`. Default uses `time.end` (op completion; jj's own ordering key). Override to expose `start`, or both (`started_at`/`ended_at`), if the op-log UI wants creation time.
2. **OQ2 — Fallible return (default = `Result`).** Epic shows infallible `Vec<Operation>`; default refines to `Result<Vec<Operation>, OpLogError>` (the walk can fail; the 3.4b FFI wrapper needs a fallible result anyway). Override only if you want a panic-on-error infallible API (not recommended).
3. **OQ3 — UTF-8 edge as doc, not code (default = doc note).** The epic's `from_utf8_lossy` AC is moot (`username`/`hostname` are already `String`). Default documents this; no dead branch. Override if you want a defensive (untested) branch — note the coverage-ratchet cost.
4. **OQ4 — `is_snapshot: bool` field (default = include).** Added beyond the epic struct, free, lets the UI/MCP distinguish pure working-copy-snapshot ops. Override to drop it (trivial removal; it widens the 3.4b wire by one bool).
5. **OQ5 — No hard-coded fixture op count (default = oracle-derived structural asserts).** The tiny fixture's exact op count is not statically knowable; tests assert structure (root-last, parents-empty, head-first) against an oracle. No action needed unless you want a pinned count (discouraged).
6. **OQ6 — `parent_ids` ordering for forks.** For a DAG fork (multi-parent op) the order is jj's `parent_ids()` order. Default preserves it verbatim. Confirm no sort is desired.
