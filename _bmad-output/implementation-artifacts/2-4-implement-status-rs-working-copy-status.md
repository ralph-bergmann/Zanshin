---
baseline_commit: c7d0197
---

# Story 2.4: Implement `status.rs` — working-copy status

Status: done

<!-- Note: Validation is optional. Run validate-create-story for quality check before dev-story. -->

> **Scope-correction callout (binding — read before coding).** Five things in the epic's Story 2.4
> text are stale against the current WIP reality and the verified jj-lib 0.41.0 API. They are
> corrected in the ACs below; the rationale is in Dev Notes. Treat the corrections, not the epic
> prose, as the contract.
>
> 1. **`WorkspaceCommandHelper` does NOT exist in jj-lib.** The epic says status "queries jj-lib's
>    `WorkspaceCommandHelper` or equivalent" (epics.md:1187). That type lives in the **`jj` CLI crate
>    (`jj_cli`)**, not `jj-lib`, and is forbidden here (it would mean depending on the CLI). The
>    working-copy status is computed directly from jj-lib's tree diff:
>    `MergedTree::diff_stream_with_copies(...)` fed by `Store::get_copy_records(...)`. See **D4** + the
>    verified API anchors. [verified: jj-lib 0.41.0 source]
> 2. **No perf assertions.** Drop the epic ACs "< 100 ms on the large fixture" and the "10,000+ files"
>    edge case (epics.md:1218-1220) — the `large-10k-commits` fixture was **never generated** (Story 2.1
>    WIP-rework: tiny + medium only), and there is no perf-gate in WIP. NFR-P-1 stays a soft design
>    goal. [Source: sprint-status.yaml:96; mirrors the Story 2.3 precedent]
> 3. **FlatBuffers, not JSON.** The epic's non-UTF-8 edge case mentions "later JSON serialization (in
>    `zanshin-ffi`)" (epics.md:1211). Per **ADR-0001** the FFI wire is **FlatBuffers**; there is no JSON
>    on the FFI wire. (And the non-UTF-8 case itself is moot — see #4.)
> 4. **Non-UTF-8 paths are moot.** jj-lib stores repo paths as UTF-8 by construction (`RepoPathBuf` wraps
>    a Rust `String`) and **rejects** non-UTF-8 working-copy paths at snapshot time
>    (`SnapshotError::InvalidUtf8Path`). So a tracked file's path is always valid UTF-8;
>    `path: PathBuf` built from `RepoPath::as_internal_file_string()` is lossless. There is no raw-`OsString`
>    handling to write here. [verified: repo_path.rs, working_copy.rs:176]
> 5. **Rename/Copy detection is git-backend-only and needs explicit copy records.** A plain tree diff
>    yields **only** Added/Removed/Modified. Renames/copies require `diff_stream_with_copies` fed by a
>    `CopyRecords` obtained from `Store::get_copy_records(..)`, which only returns data on the **git
>    backend** (native/`SimpleBackend` → empty stream). The rename AC test therefore runs on a
>    git-backed repo; on a native repo a rename degrades to an Added+Removed pair (documented, not a
>    bug). See **D4**. [verified: git_backend.rs:1409, simple_backend.rs:341]
>
> Also: **SPDX is `MIT`** (project relicensed Apache-2.0 → MIT on 2026-06-20, OD-2). Story 2.3's file
> header says Apache-2.0 — that is stale; new files use `// SPDX-License-Identifier: MIT` (matches the
> current `lib.rs` / `repo.rs`).
>
> [Source: epics.md#Story 2.4 (lines 1159-1221); prd.md FR-JJ-4 (line 197); project-context.md § zanshin-jj, § ADR-0001/0002; architecture.md:419]

---

## Story

As a Rust caller wanting to display working-copy state (later `zanshin-ffi` Story 3.4b and `zanshin-mcp`),
I want `zanshin-jj` to expose `Repo::status() -> Result<Status, StatusError>` returning the files changed
between the working-copy commit (`@`) and its parent (`@-`), plus both change IDs,
so that consumers can answer `status` queries with structured, `jj_lib`-type-free data **without ever
shelling to the `jj` CLI** (FR-JJ-4, AR-AP-1).

This is the **second `zanshin-jj` read-path noun** (after Story 2.3's `repo.rs`). It is the first story to
read the working copy through the `Repo` handle: it re-resolves to head per call (ADR-0002 — the handle is
a warm loader, not a state cache) and absorbs the jj-lib tree-diff churn behind a stable surface (FR-JJ-16).
It introduces `ChangeId`, the shared `jj_lib`-type-free change-identifier newtype that later read stories
(2.6 `change.rs`, 2.7 `op_log.rs`) reuse.

---

## Acceptance Criteria

Grouped by deliverable. Each item is a checkable contract. Source is `epics.md#Story 2.4` unless noted;
where this story **corrects** the epic, the correction is flagged inline with rationale in Dev Notes.

### AC-1 — public types in `status.rs` (FR-JJ-4)

1. `crates/zanshin-jj/src/status.rs` exists (SPDX `MIT` line 1) and defines:
   - `pub struct Status { pub files: Vec<FileChange>, pub working_copy_change_id: ChangeId, pub parent_change_id: ChangeId }`
   - `pub struct FileChange { pub path: PathBuf, pub kind: ChangeKind }`
   - `pub enum ChangeKind { Added, Modified, Removed, Renamed { from: PathBuf }, Copied { from: PathBuf } }`
   - `pub struct ChangeId(pub String)` — the `jj_lib`-type-free change identifier (see **D1**).
   - `pub enum StatusError` deriving `thiserror::Error` + `Debug` (see AC-5).
2. **No `jj_lib` type appears in any `pub` signature** of these items (FR-JJ-16 / Story 2.3 AC-17). A reviewer
   greps the public surface for `jj_lib::` and finds none. `ChangeId` is a `String` newtype, **not** a
   re-exported `jj_lib::backend::ChangeId`.
3. For `ChangeKind::Renamed` and `ChangeKind::Copied`, the `from` field carries the **source** path.

### AC-2 — `Repo::status()` (the read method)

4. `pub fn status(&self) -> Result<Status, StatusError>` is added to `impl Repo` in `repo.rs` (it needs the
   `Repo`'s **private** `workspace` field — `status.rs`, a sibling module, cannot reach it; see **D3**). It
   delegates to a `pub(crate) fn` in `status.rs`.
5. `status()` **re-resolves to head** on every call via
   `pollster::block_on(self.workspace.repo_loader().load_at_head())` (ADR-0002: the handle is a warm loader,
   not a cache — never trust a previously-loaded `ReadonlyRepo` across a call). [Source: docs/adr/0002; project-context.md "Lane state is re-derived"]
6. **Read-only — does NOT snapshot the working copy (D2).** `status()` reads the **already-recorded** `@`
   commit and diffs it against `@-`. It does not stat/snapshot the on-disk tree and does not write a new
   operation. (External `jj` activity or `fsmonitor.backend = "watchman"` is what refreshes `@`; that
   reactivity is the watcher's job — Stories 3.5/3.6, deferred.) [Source: epics.md:1213-1216 corrected per ADR-0002]

### AC-3 — clean working copy

7. `Repo::status()` on a fixture repo with a clean working copy returns `Status { files: vec![], .. }` with
   **both** `working_copy_change_id` and `parent_change_id` populated (non-empty strings). Verify against the
   extracted `tiny-3-commits` fixture (whose `@` is on the root commit — see Story 2.3 AC-22 — so the diff is
   empty). [Source: epics.md:1176-1178]

### AC-4 — changed files (Added / Modified / Removed)

8. On a repo whose `@` differs from `@-` (set up by snapshotting on-disk edits in the test — see **D2** + the
   test recipe), `status()` returns the correct `FileChange` list:
   - a new file → `ChangeKind::Added`
   - an edited file → `ChangeKind::Modified`
   - a deleted file → `ChangeKind::Removed`
   and `working_copy_change_id` equals the current `@` commit's change id. [Source: epics.md:1180-1183, 1195-1199]
9. Binary-vs-text classification is **delegated to jj-lib** — no manual `is_text()` / content sniffing in
   `status.rs`. `ChangeKind` carries **no content diff** (that is `zanshin-diff`'s job in Epic 5). [Source: epics.md:1190-1193]

### AC-5 — `StatusError` (jj-lib-type-free)

10. `pub enum StatusError` derives `thiserror::Error` + `Debug` with at minimum:
    - `#[error("workspace has no working-copy commit")] NoWorkingCopy` — when `View::get_wc_commit_id`
      returns `None` for the workspace (don't unwrap; see API anchors).
    - `#[error("jj-lib error: {0}")] Backend(String)` — the opaque catch-all for any wrapped jj-lib failure,
      built via `.map_err(|e| StatusError::Backend(e.to_string()))` (mirrors `RepoError::Backend`, Story 2.3 D1).
    No `jj_lib` type appears in any variant's public signature.

### AC-6 — rename / copy (git backend; graceful degradation elsewhere) — see D4

11. Status is computed with `MergedTree::diff_stream_with_copies(&after, matcher, &copy_records)` where
    `copy_records` come from `Store::get_copy_records(None, parent_id, wc_commit_id)`. A renamed file on a
    **git-backed** repo yields a single `ChangeKind::Renamed { from: old_path }` entry — **not** a separate
    Added+Removed pair. [Source: epics.md:1201-1204]
12. On a **native** (`SimpleBackend`) repo, `get_copy_records` returns an empty stream, so a rename degrades to
    an `Added` + `Removed` pair. This is documented expected behaviour, not a defect (the native backend has no
    copy detection). The rename **test** therefore uses a git-backed repo (`Backend::Git`).

### AC-7 — no shelling to the `jj` CLI (AR-AP-1)

13. The implementation uses jj-lib APIs only. It does **not** shell to `jj status`, does not parse `jj` output,
    and does not depend on `jj_cli` / `WorkspaceCommandHelper`. (jj-lib's own internal git-subprocess for copy
    detection on the git backend is jj-lib's mechanism — it is **not** the `jj` CLI; it does not violate
    AR-AP-1, same reasoning as Story 2.3 D2.) [Source: epics.md:1185-1188; project-context.md:503-509]

### AC-8 — integration tests (`crates/zanshin-jj/tests/status.rs`)

14. Tests live in `crates/zanshin-jj/tests/status.rs`, are scenario-named (project-context § Naming, e.g.
    `status_on_clean_fixture_returns_no_files`), pin `JJ_CONFIG` / `GIT_CONFIG_GLOBAL` via the same
    `pin_env()` / `ENV_GUARD` pattern as `tests/repo.rs`, and run in parallel (no `#[serial]`).
15. Required cases:
    - **clean** (AC-3): `tiny-3-commits` fixture → `files == []`, both change IDs non-empty.
    - **added** (AC-4): write a new file → snapshot → `status()` shows it `Added`.
    - **modified** (AC-4): change an existing tracked file → snapshot → `Modified`.
    - **removed** (AC-4): delete a tracked file → snapshot → `Removed`.
    - **renamed** (AC-6): on a **git-backed** repo, rename a tracked file → snapshot → one `Renamed { from }`
      entry, and assert there is **no** separate Added/Removed pair for that logical rename.
    - **change-id population** (AC-3/4): `working_copy_change_id` reflects the current `@`.
16. Tests do **not** read developer globals and do **not** reach the network (project-context § Testing). No
    `#[ignore]` / skip-for-flakiness. [Source: project-context.md:267-298]
17. **(Correction — no perf test.)** There is **no** "< 100 ms" timing assertion and **no** "10,000+ files"
    case — the `large-10k-commits` fixture does not exist in WIP. [Source: epics.md:1218-1220 corrected per sprint-status.yaml:96]

### AC-9 — quality gate stays green

18. `cargo make test` passes end-to-end: `cargo clippy --workspace --all-targets -- -D warnings` (pedantic on)
    clean — **refactor, don't `#[allow]`**; any unavoidable suppression needs a `// WHY:` note —
    `cargo fmt --all --check` clean, `cargo test --workspace` green, `cargo deny check advisories bans` clean,
    and the `test-cargo-hygiene` gate passes. **No new crate is added**, so the crate-count guard is
    **unchanged** — do not touch it. [Source: Makefile.toml; Story 2.3 AC-24]
19. **No `unwrap()` / `expect()` / `panic!()` on reachable error paths** in `status.rs` (it feeds the FFI;
    propagate via `StatusError`). **No `unsafe`.** Every new/edited `.rs` starts with `// SPDX-License-Identifier: MIT`.
    [Source: project-context.md:88-96, 363-370]
20. No `docs/rust-error-codes.md` change is needed: that registry is for the FFI `error.code` taxonomy
    (Story 3.4b maps `StatusError` → `jj.*` codes). `StatusError` is an internal Rust type here. [Source: project-context.md:323-331]

---

## Tasks / Subtasks

- [x] **T1 — `futures` dependency promotion** (AC: 18 — D5)
  - [x] In `crates/zanshin-jj/Cargo.toml`, move `futures = { workspace = true }` from `[dev-dependencies]`
        to `[dependencies]`.

- [x] **T2 — `status.rs` public types** (AC: 1, 2, 3, 5)
  - [x] Create `crates/zanshin-jj/src/status.rs` (SPDX `MIT` line 1). Define `Status`, `FileChange`,
        `ChangeKind`, `ChangeId(String)`, `StatusError` (thiserror; D1). Doc-comment each `pub` item.
  - [x] On `ChangeId`, add a `///` note that the string is jj's **reverse-hex** display form.

- [x] **T3 — status computation** (AC: 1, 4, 5, 6, 7) — `pub(crate) fn working_copy_status(workspace: &Workspace) -> Result<Status, StatusError>`
  - [x] Re-resolve to head via `pollster::block_on(workspace.repo_loader().load_at_head())`.
  - [x] Resolve `@` via `View::get_wc_commit_id` → `StatusError::NoWorkingCopy` on `None`.
  - [x] Trees: `after = wc_commit.tree()` (sync) + `before = parent_tree(repo)` (async, root-safe).
  - [x] Parent commit id + `parent_change_id` via first parent or root fallback.
  - [x] Copy records via `Store::get_copy_records` + drain `BoxStream` with `StreamExt::next`.
  - [x] Copies-aware diff via `diff_stream_with_copies`; classify Renamed/Copied/Added/Removed/Modified.
  - [x] Build `Status { files, working_copy_change_id, parent_change_id }`.

- [x] **T4 — `Repo::status()` method** (AC: 2, 4) — in `repo.rs`
  - [x] Add `pub fn status(&self) -> Result<Status, StatusError>` delegating to `crate::status::working_copy_status(&self.workspace)`.

- [x] **T5 — wire the module** (AC: 1) — in `lib.rs`
  - [x] Add `pub(crate) mod status;` and `pub use status::{ChangeId, ChangeKind, FileChange, Status, StatusError};`.

- [x] **T6 — tests** (AC: 8, 14-17)
  - [x] `crates/zanshin-jj/tests/status.rs` (SPDX `MIT`): all 6 cases in AC-15, scenario-named, `pin_env()` first.
  - [x] `snapshot_working_copy(path)` helper + `jj_new(path)` helper for test setup.

- [x] **T7 — gate** (AC: 18, 19, 20)
  - [x] `cargo make test` green. Clippy pedantic clean. `fmt` clean. SPDX `MIT` on both new `.rs` files. No `jj_lib` type in any `pub` signature.

  - [ ] `cargo make test` green. Clippy pedantic clean (refactor, not `#[allow]`). `fmt` clean. SPDX `MIT` on the
        two new `.rs` files. Confirm `grep -rn "jj_lib::" crates/zanshin-jj/src/status.rs` reveals only
        non-public internal uses; **no `jj_lib` type in any `pub` signature** (AC-2/5). No registry edit (AC-20).

---

## Dev Notes

### Decision D1 — `ChangeId` is a `String` newtype over jj's reverse-hex (RECOMMENDED)

FR-JJ-16 / Story 2.3 AC-17 forbid any `jj_lib` type in `zanshin-jj`'s public surface. jj's
`jj_lib::backend::ChangeId` is therefore **not** re-exportable. Wrap it:

```rust
/// A jj change identifier in jj's canonical reverse-hex (`z-k`) display form — the
/// `qpvuntsm`-style id shown by `jj log`. `jj_lib`-type-free (FR-JJ-16).
/// Reused by Story 2.6 (`change.rs`) and 2.7 (`op_log.rs`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ChangeId(pub String);
```

Build it with `ChangeId(commit.change_id().reverse_hex())`. **Use `reverse_hex()`, NOT `hex()`** — jj's
`ChangeId::Display` uses reverse-hex (the `z-k` alphabet); `hex()` would yield a non-jj `0-9a-f` string that
no jj user or revset recognizes. (CommitId, by contrast, uses ordinary hex — but this story exposes change
IDs, not commit IDs.) [verified: backend.rs:47,77; object_id.rs:89]

> **Open question for Ralph (see end):** `ChangeId` lives in `status.rs` for now (scope discipline — don't
> pre-build 2.6's module). When 2.6 lands it may be promoted to a shared `id.rs` noun module — a non-breaking
> re-export move. Flagging in case you'd rather create `id.rs` now.

### Decision D2 — status is READ-ONLY (no snapshot); tests snapshot in setup (RECOMMENDED)

`Repo::status()` reads the **already-recorded** working-copy commit `@` and diffs it against `@-`. It does
**not** stat/snapshot the on-disk working tree and does **not** write a new operation. This is mandated by the
epic edge case ("does NOT trigger a manual snapshot — that's jj's `fsmonitor.backend = "watchman"` path's job")
and is consistent with **ADR-0002**: Zanshin *reacts* to jj's snapshots (the watcher fires on
`.jj/repo/working_copy/checkout` + `op_heads`), it does not initiate them. In WIP (watcher deferred, watchman
optional), status reflects the last snapshot taken by an external `jj` op — an accepted, documented degradation.

**Consequence for tests:** to make on-disk edits appear in `status()`, the *test* must snapshot them into `@`
first (simulating jj/fsmonitor). The production code stays a pure read. See the **Test snapshot recipe** below.

### Decision D3 — module privacy: the method is in `repo.rs`, the logic is in `status.rs`

`Repo`'s fields (`workspace`, `settings`) are **private to `repo.rs`**. Rust privacy is module-scoped, so
`status.rs` (a sibling module) **cannot** read `repo.workspace`. Therefore:

- `status.rs` owns the types **and** `pub(crate) fn working_copy_status(workspace: &Workspace) -> Result<Status, StatusError>`.
- `repo.rs` adds the thin method `pub fn status(&self) -> Result<Status, StatusError> { crate::status::working_copy_status(&self.workspace) }`.

Do **not** widen `Repo`'s fields to `pub`/`pub(crate)` to work around this — the thin-delegation method is the
intended pattern (keeps encapsulation; every later read story 2.5-2.9 follows it). `status()` needs only
`workspace` (head-resolution via `repo_loader().load_at_head()` takes no `settings`), so leave the `settings`
field's `#[allow(dead_code)]` exactly as-is.

### Decision D4 — copies-aware diff, used uniformly (RECOMMENDED)

A plain `MergedTree::diff_stream` yields only Added/Removed/Modified. To satisfy the rename/copy AC, use
`diff_stream_with_copies` **uniformly**, fed by `Store::get_copy_records(None, parent_id, wc_id)`:

- On the **git backend**, `get_copy_records` computes renames/copies (gix tree-to-tree, rename threshold 0.5)
  between the parent and `@` trees → `Renamed`/`Copied` entries populate.
- On the **native** (`SimpleBackend`) backend, `get_copy_records` returns an **empty** stream → the same code
  path degrades to Added/Removed (graceful; AC-12). One code path, no backend branching.

`CopiesTreeDiffEntry.path` is a `CopiesTreeDiffEntryPath { source: Option<(RepoPathBuf, CopyOperation)>, target: RepoPathBuf }`:
`source == None` → ordinary change (classify by before/after presence); `source == Some((src, Rename|Copy))` →
`ChangeKind::Renamed/Copied { from: src }`. `diff_stream_with_copies` folds the source's removal into the
rename entry, so there is no separate Added+Removed pair (AC-6/11).

**Merge-`@` caveat (edge):** `get_copy_records` takes a single `root` commit id. For a merge working copy
(multiple parents), use the **first** parent id as the copy-records root and `parent_change_id`, while the diff
`before` tree uses `wc_commit.parent_tree(repo)` (which merges all parents, root-safe). For the overwhelmingly
common single-parent `@`, these coincide exactly. Document the single-parent assumption with a `// WHY:` note;
full multi-parent copy attribution is out of scope for WIP.

### Decision D5 — `futures` becomes a production dependency

The diff and copy-record APIs return `futures::Stream` (`BoxStream`), not iterators. Draining them needs
`futures::StreamExt::next` (jj-lib exposes no sync iterator). `futures` is already a `[workspace.dependencies]`
entry consumed as a **dev**-dep; promote it to `[dependencies]` of `crates/zanshin-jj`. Pattern:

```rust
use futures::StreamExt as _;
let mut stream = before.diff_stream_with_copies(&after, &EverythingMatcher, &records);
pollster::block_on(async {
    while let Some(entry) = stream.next().await {
        // ... build FileChange
    }
});
```

`pollster` (already a dep) drives the future; `StreamExt` advances the stream. Public `Repo::status()` stays
**sync** — only the internal drains block on a future (same async-bridging discipline as Story 2.3's `init`/`clone`).

### jj-lib 0.41.0 API anchors — VERIFIED against the pinned source

Pinned `=0.41.0`, pre-1.0, churny. All confirmed from
`~/.cargo/registry/src/index.crates.io-*/jj-lib-0.41.0/src/` (re-verify with `cargo doc -p jj-lib` if in doubt).

```rust
// Head resolution (ASYNC) — workspace.rs:429, repo.rs:764
workspace.repo_loader() -> &RepoLoader
RepoLoader::load_at_head(&self) -> Result<Arc<ReadonlyRepo>, RepoLoaderError>   // ASYNC -> pollster::block_on

// Working-copy commit (@) — view.rs:58, repo.rs:305, workspace.rs:421, store.rs:151
ReadonlyRepo::view(&self) -> &View
View::get_wc_commit_id(&self, name: &WorkspaceName) -> Option<&CommitId>        // Option! -> StatusError::NoWorkingCopy
Workspace::workspace_name(&self) -> &WorkspaceName
Store::get_commit(self: &Arc<Self>, id: &CommitId) -> BackendResult<Commit>     // SYNC (wraps block_on internally)

// Commit -> trees + ids — commit.rs:120/134/106/171
Commit::tree(&self) -> MergedTree                                              // SYNC, NOT Result, NOT async
Commit::parent_tree(&self, repo: &dyn Repo) -> BackendResult<MergedTree>        // ASYNC -> pollster::block_on (merges parents, root-safe)
Commit::parent_ids(&self) -> &[CommitId]                                        // SYNC
Commit::change_id(&self) -> &ChangeId                                           // SYNC
ChangeId::reverse_hex(&self) -> String                                          // backend.rs:77 — the jj-canonical display form

// Copy records (ASYNC stream) — store.rs:105, backend.rs:661, copies.rs:54/65
Store::get_copy_records(&self, paths: Option<&[RepoPathBuf]>, root: &CommitId, head: &CommitId)
    -> BackendResult<BoxStream<BackendResult<CopyRecord>>>
CopyRecords::default(); CopyRecords::add_records(&mut self, impl IntoIterator<Item = CopyRecord>)

// Copies-aware diff (ASYNC stream) — merged_tree.rs:311/118/127, copies.rs:109, matchers.rs:120
MergedTree::diff_stream_with_copies<'a>(&self, other: &Self, matcher: &'a dyn Matcher, copy_records: &'a CopyRecords)
    -> BoxStream<'a, CopiesTreeDiffEntry>
struct CopiesTreeDiffEntry { path: CopiesTreeDiffEntryPath, values: BackendResult<Diff<MergedTreeValue>> }
struct CopiesTreeDiffEntryPath { source: Option<(RepoPathBuf, CopyOperation)>, target: RepoPathBuf }
enum CopyOperation { Copy, Rename }
EverythingMatcher;  // unit struct, pass &EverythingMatcher

// before/after sides — merge.rs:53/55/57/645/650
struct Diff<T> { before: T, after: T }    // T = MergedTreeValue = Merge<Option<TreeValue>>
MergedTreeValue::is_absent(&self) -> bool ; MergedTreeValue::is_present(&self) -> bool

// RepoPath -> PathBuf (infallible UTF-8) — repo_path.rs:360
RepoPath::as_internal_file_string(&self) -> &str       // -> PathBuf::from(...)

// Import aliasing: the jj Repo TRAIT clashes with our Repo struct — alias it
use jj_lib::repo::{ReadonlyRepo, Repo as _};           // (Story 2.3 used the same `as _` trick)
```

**CHURN-RISK gotchas (from the source audit):**
- `Commit::tree()` is **sync and returns `MergedTree` directly** (no `Result`, no `await`). There is no
  `tree_id()` — it's `tree_ids() -> &Merge<TreeId>`.
- `TreeDiffEntry.values` / `CopiesTreeDiffEntry.values` is `BackendResult<Diff<MergedTreeValue>>` — access
  `.before` / `.after` **fields** (it is NOT a `(before, after)` tuple).
- The diffs and `get_copy_records` are `Stream`s, not iterators — drive with `pollster::block_on` + `StreamExt::next` (D5).
- `get_commit` is sync; `parent_tree`/`parents`/`load_at_head` are async — mixed; wrap the async ones in `pollster::block_on`.
- `get_wc_commit_id` returns `Option` — map `None` to `StatusError::NoWorkingCopy`, never unwrap.

### Test snapshot recipe (TEST setup only — production never snapshots, D2)

To make on-disk edits show in `status()`, the test writes files then snapshots them into a fresh `@`. Verified
0.41.0 calls:

```rust
// 1. Snapshot the on-disk working copy into a MergedTree.
let mut locked = pollster::block_on(workspace.start_working_copy_mutation())?;       // workspace.rs:442 (ASYNC, &mut Workspace)
let opts = SnapshotOptions {                                                          // working_copy.rs:211 — NO Default, build literal
    base_ignores: GitIgnoreFile::empty(),                                            // gitignore.rs:44
    progress: None,
    start_tracking_matcher: &EverythingMatcher,
    force_tracking_matcher: &EverythingMatcher,
    max_new_file_size: u64::MAX,                                                      // avoid NewFileTooLarge in tests
};
let (new_tree, _stats) = pollster::block_on(locked.locked_wc().snapshot(&opts))?;    // working_copy.rs:117 (ASYNC) -> (MergedTree, _)
// 2. Record the snapshot tree as a new @ via a transaction.
let mut tx = repo.start_transaction();                                               // repo.rs:334
let parents = wc_commit.parent_ids().to_vec();
let new_commit = pollster::block_on(tx.repo_mut().new_commit(parents, new_tree).write())?;  // repo.rs:965 + commit_builder.rs:163 (ASYNC)
tx.repo_mut().set_wc_commit(workspace.workspace_name().to_owned(), new_commit.id().clone())?; // repo.rs:1493
let new_repo = pollster::block_on(tx.commit("test: snapshot"))?;                     // transaction.rs:119 (ASYNC)
pollster::block_on(locked.finish(new_repo.op_id().clone()))?;                        // workspace.rs:491 (ASYNC)
// Now Repo::status() (which re-loads at head) sees @ != @-.
```

For the **rename** case, init with `Backend::Git` (`Repo::init(tmp, Some(Backend::Git))`), commit a baseline
containing the file, then rename it on disk + snapshot. Renames only surface on the git backend (D4). Factor
the snapshot dance into a `fn snapshot_working_copy(...)` helper in the test file to keep cases readable. This
is the churniest part of the story — verify each async signature against `cargo doc -p jj-lib` before relying on it.

### Previous-story intelligence (Story 2.3 — `done`, 3-layer review, all ACs pass)

- **`Repo` is `{ workspace: Workspace, settings: UserSettings }`**, fields private. `make_settings()` is a
  private free fn in `repo.rs` (you don't need it — `status()` uses only `workspace`). [repo.rs:38-45, 288-305]
- **`make_settings`/`pollster::block_on` patterns** and the `jj_lib::repo::Repo as _` import alias come straight
  from `repo.rs` — reuse the shapes. [repo.rs `clone_into` already calls `workspace.repo_loader().load_at_head()`]
- **Test harness:** `extract_fixture("tiny-3-commits") -> FixtureHandle { pub path: PathBuf }` (keep the handle
  alive — it owns a `TempDir`). `pin_env()` forces `ENV_GUARD` (sets `JJ_CONFIG=""` / `GIT_CONFIG_GLOBAL=""`).
  `copy_dir_all` helper exists for relocation. [crates/test-helpers/src/lib.rs; tests/repo.rs:14-26]
- **Fixture `@` is on the root commit, not the tip** (Story 2.3 AC-22). So the clean-status assertion (AC-3)
  holds directly on an extracted fixture (diff vs root parent is empty). [2-3 story:122-127]
- **`thiserror` opaque-string wrapping** (`Backend(String)` built from `e.to_string()`) is the established
  pattern (Story 2.3 D1) — `StatusError::Backend` mirrors it. [2-3 story:204-233]

### Files this story touches (NEW unless marked UPDATE)

- `crates/zanshin-jj/Cargo.toml` **(UPDATE)** — move `futures` from `[dev-dependencies]` to `[dependencies]` (D5). Nothing else. [Cargo.toml:12-21]
- `crates/zanshin-jj/src/status.rs` **(NEW)** — `Status`/`FileChange`/`ChangeKind`/`ChangeId`/`StatusError` + `working_copy_status`.
- `crates/zanshin-jj/src/repo.rs` **(UPDATE)** — add `pub fn status(&self)` to `impl Repo` (≈3 lines). Do not
  touch the `settings` field or `#[allow(dead_code)]`. [repo.rs `impl Repo` 55-264]
- `crates/zanshin-jj/src/lib.rs` **(UPDATE)** — add `mod status;` + the 5 re-exports. [lib.rs:9-11]
- `crates/zanshin-jj/tests/status.rs` **(NEW)** — integration tests + `snapshot_working_copy` helper (AC-8).
- **Do not** add `revset.rs`/`change.rs`/etc. — those are Stories 2.5+. Stay in scope.

### Hard rules in scope (project-context.md — reject-at-review on violation)

- **`zanshin-jj` is the ONLY crate that imports `jj_lib`**, and **no `jj_lib` type may appear in its public
  surface** (D1, AC-2/5). Absorb churn inside module bodies. [project-context:160-168]
- **No shelling to / parsing the `jj` CLI**, and **no dependency on `jj_cli` / `WorkspaceCommandHelper`** (AC-7).
  jj-lib's internal git subprocess for copy detection is fine — not the `jj` CLI. [project-context:503-509]
- **No `unsafe`** in `zanshin-jj`; **no `unwrap`/`expect`/`panic!`** on reachable paths — structured
  `StatusError` via `thiserror`. [project-context:88-96]
- **Clippy pedantic, `-D warnings`** — fix, don't `#[allow]`; any unavoidable suppression needs `// WHY:`. [project-context:75-86]
- **No `mod.rs`**; `status.rs` is a `lib.rs` sibling. **`lib.rs` = re-exports + docs only.** [project-context:302-310]
- **SPDX `MIT` line 1** on every `.rs`. [project-context:363-370]
- **No JSON anywhere** in this story — `zanshin-jj` returns typed Rust; FlatBuffers/FFI is Epic 3 (3.4b). [project-context:124-156]

### Project Structure Notes (variances)

- Architecture's source tree places exactly this at `crates/zanshin-jj/src/status.rs # FR-JJ-4` — this story
  realizes that node. [Source: architecture.md:419]
- **Variance vs. epic AC wording:** `WorkspaceCommandHelper` → `diff_stream_with_copies` + `get_copy_records`;
  perf assertions dropped; non-UTF-8/JSON edge case removed as moot; rename/copy scoped to the git backend. All
  corrected above with rationale (callout #1-5). Deliberate, not oversights.
- **Variance vs. project-context "`zanshin-jj` is sync":** `load_at_head`/`parent_tree`/the stream drains are
  async in 0.41.0; bridged with `pollster::block_on` so the public `Repo::status()` stays sync. The
  project-context statement holds for the *shape* of the public API and the read path; it does not contradict
  bridging an internal async call (same as Story 2.3's `init`/`clone`).

### References

- [Source: _bmad-output/planning-artifacts/epics.md#Story 2.4 (lines 1159-1221); Epic 2 intro (998-1000); FR map (197)]
- [Source: _bmad-output/planning-artifacts/prd.md FR-JJ-4 (line 197), FR-JJ-16 (213)]
- [Source: _bmad-output/planning-artifacts/architecture.md source tree (line 419)]
- [Source: _bmad-output/project-context.md § zanshin-jj, § Testing Rules, § Code Quality, § Critical Don't-Miss, § ADR-0001/0002]
- [Source: docs/adr/0002-repository-state-model-warm-loader-reload-per-operation.md (re-resolve-to-head); docs/adr/0001 (FlatBuffers — FFI only, not this story)]
- [Source: _bmad-output/implementation-artifacts/2-3-implement-repo-rs-open-init-clone.md — Repo struct, make_settings, pollster pattern, test harness, Backend(String) discipline, @-on-root]
- [Source: crates/zanshin-jj/src/{repo.rs,lib.rs}; crates/zanshin-jj/tests/repo.rs (pin_env/ENV_GUARD); crates/zanshin-jj/Cargo.toml; crates/test-helpers/src/lib.rs]
- jj-lib 0.41.0 source (verified this story): `view.rs:58`, `repo.rs:305/334/764/965/1493`, `workspace.rs:421/429/442/491`,
  `store.rs:105/151`, `commit.rs:106/120/134/171`, `merged_tree.rs:283/311/367`, `copies.rs:54/109/118/127`,
  `merge.rs:53/645/650`, `backend.rs:47/77/661`, `matchers.rs:120`, `repo_path.rs:360`, `working_copy.rs:117/176/211`.

---

## Dev Agent Record

### Agent Model Used

Claude Sonnet 4.6 (1M context)

### Debug Log References

None — implementation compiled and all tests passed on first attempt (one clippy `single_match_else` fix + `cargo fmt` pass required).

### Completion Notes List

- T1: Promoted `futures` from `[dev-dependencies]` to `[dependencies]` in `crates/zanshin-jj/Cargo.toml` (D5: production code drains `BoxStream` with `StreamExt::next`).
- T2+T3: Created `crates/zanshin-jj/src/status.rs` — defines `Status`, `FileChange`, `ChangeKind`, `ChangeId(String)` (reverse-hex newtype, FR-JJ-16), `StatusError` (thiserror); `working_copy_status(workspace)` re-resolves to head (ADR-0002), drains copy-records stream, runs `diff_stream_with_copies` uniformly (D4). `be()` helper + `repo_path_to_pathbuf()` helper. No `jj_lib` type in any `pub` signature.
- T4: Added `pub fn status(&self) -> Result<Status, StatusError>` to `impl Repo` in `repo.rs`; thin delegation to `crate::status::working_copy_status(&self.workspace)`. `settings` field `#[allow(dead_code)]` left unchanged.
- T5: Wired `pub(crate) mod status` + 5 re-exports in `lib.rs`.
- T6: `crates/zanshin-jj/tests/status.rs` — 6 tests (clean, added, modified, removed, renamed-on-git, change-id-population); `snapshot_working_copy(path)` and `jj_new(path)` test helpers replicate the Dev Notes recipe. Rename test uses `Backend::Git` as required (AC-12).
- T7: `cargo make test` green end-to-end: 6 new + 13 existing zanshin-jj tests, 58 zanshin-ffi tests, clippy pedantic clean, fmt clean, cargo deny clean, test-cargo-hygiene clean.

### File List

- `crates/zanshin-jj/Cargo.toml` (updated — `futures` promoted to `[dependencies]`)
- `crates/zanshin-jj/src/status.rs` (new)
- `crates/zanshin-jj/src/repo.rs` (updated — `pub fn status()` added to `impl Repo`)
- `crates/zanshin-jj/src/lib.rs` (updated — `mod status` + 5 re-exports)
- `crates/zanshin-jj/tests/status.rs` (new)

### Change Log

| Datum      | Änderung                                            |
|------------|-----------------------------------------------------|
| 2026-06-22 | Story-Datei erstellt (Status: ready-for-dev)        |
| 2026-06-22 | Implementierung abgeschlossen (Status: review) — status.rs + Repo::status() + 6 Tests; cargo make test grün |
| 2026-06-22 | Code-Review (3-Layer adversarial, Opus 4.8) — 0 Bugs / 0 AC-Verstöße, 11 Findings widerlegt. Härtung: +2 Error-Pfad-Tests (NoWorkingCopy + Backend), change-id-Gleichheitsassertion, ENV_GUARD-Kommentar korrigiert; cargo make test grün (Status: done) |

---

## Open Questions for Ralph (non-blocking — defaults chosen, override if desired)

These are genuine design forks. I picked a recommended default for each (so the story is ready-for-dev as-is);
flagging them so you can override before implementation rather than after review:

1. **Read-only status vs. snapshot-on-read (D2).** I made `Repo::status()` a **pure read** of the recorded `@`
   (no working-copy snapshot), per the epic edge case + ADR-0002's react-to-the-watcher model. Trade-off: in
   WIP (watcher deferred, watchman optional) raw on-disk edits won't appear in status until an external `jj`
   op/watchman snapshots them. The alternative (snapshot inside `status()`, like `jj status`) would reflect
   on-disk edits immediately but makes status a mutation (writes a new op every call) and contradicts the AC.
   **Recommended: keep read-only.** Confirm?

2. **`ChangeId` location (D1).** Defined in `status.rs` now (scope discipline), reused by 2.6. Alternative: create
   a dedicated `id.rs` noun module now so 2.6 doesn't have to relocate it. **Recommended: keep in `status.rs`**
   (a later move is a non-breaking re-export). Prefer `id.rs` upfront?

3. **Rename/copy scope (D4).** Implemented copies-aware diff uniformly → renames detected on the **git backend**,
   degrade to Added+Removed on native. This fully meets the epic's rename AC. The alternative (defer rename/copy
   entirely, only Added/Removed/Modified for now) is simpler but leaves the `Renamed`/`Copied` variants unexercised.
   **Recommended: implement copies-aware (it's modest extra code and the AC asks for it).** OK?

---

## Review Findings (Code Review 2026-06-22)

_Adversarial 3-layer review (Blind Hunter / Edge Case Hunter / Acceptance Auditor) on Opus 4.8;
each finding adversarially verified against the real code + pinned jj-lib 0.41.0 source (some with a
live `cargo test` run). 18 raw findings → 15 unique. **0 correctness/security bugs, 0 AC violations,
all hard-rules satisfied.** 11 findings dismissed as adversarially-refuted noise._

### Resolution (2026-06-22 — Ralph chose option 2: harden the high-value two, accept Copied as scoped-out)

`cargo make test` green after the changes (8 status tests, 13 repo tests, 58 ffi tests, clippy pedantic
clean, fmt clean, cargo deny ok, test-cargo-hygiene ok). No production code changed — all fixes are in
`tests/status.rs`.

### Decision-needed (resolved)

- [x] [Review][Decision→Patch] Error-path tests missing (`StatusError::NoWorkingCopy` + `Backend`) — both
      public error variants were unexercised. ✅ **Added** `status_on_workspace_without_wc_commit_returns_no_working_copy`
      (removes `@` via `MutableRepo::remove_wc_commit` + `rebase_descendants`) and
      `status_on_corrupt_repo_returns_backend_error` (removes `op_heads` after open → re-resolve fails →
      `Backend`). [crates/zanshin-jj/tests/status.rs]
- [x] [Review][Decision] `ChangeKind::Copied` variant untested — ✅ **Accepted as scoped-out** (option 2):
      left unexercised per Open Question #3; hard to trigger (gix needs a copy whose source is also modified)
      and the `from`-extraction is already covered by the rename test. No change.
      [crates/zanshin-jj/tests/status.rs:202-230]
- [x] [Review][Decision→Patch] change-id test weaker than its name — ✅ **Strengthened**: it now asserts
      `working_copy_change_id`/`parent_change_id` **equal** the jj-lib-computed `@`/`@-` reverse-hex ids
      (new `wc_and_parent_change_ids` oracle), not merely non-empty (AC-4 item 8).
      [crates/zanshin-jj/tests/status.rs]

### Patch (resolved)

- [x] [Review][Patch] `ENV_GUARD` comment overstated `JJ_CONFIG` — jj-lib 0.41.0 never reads `JJ_CONFIG`
      (it is a `jj`-CLI var); only `GIT_CONFIG_GLOBAL=""` provides real isolation. ✅ **Corrected** the
      comment to the accurate framing. (Correction to the original note: the comment was *not* verbatim from
      `tests/repo.rs` — `tests/repo.rs` was already accurate; `status.rs` was the imprecise paraphrase, now
      aligned to it. No change needed in `tests/repo.rs`.) [crates/zanshin-jj/tests/status.rs:18-24]
