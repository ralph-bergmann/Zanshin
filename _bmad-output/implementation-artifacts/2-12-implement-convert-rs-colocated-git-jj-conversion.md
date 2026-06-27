---
baseline_commit: 52a765206ad0f8a8ac82abc0e9e6c6ccd7c505b3
---

# Story 2.12: Implement `convert.rs` — colocated Git → jj conversion

Status: done

<!-- Note: Validation is optional. Run validate-create-story for quality check before dev-story. -->

## Story

As a Rust caller acting on the user's explicit choice,
I want `zanshin-jj` to convert an existing Git repository into a **colocated** jj workspace (history-preserving, additive, reversible),
So that a user who chose "use this Git project with jj, keep git too" gets a `.jj/` alongside their untouched `.git/`, with full history and a working `git` CLI (FR-JJ-18a).

> **Scope boundary (read first):** This is a **PURE `zanshin-jj` Rust** story. Do **NOT** add any `extern "C"` / FFI code — exposing `convert_colocated` over FFI (`zanshin_repo_convert`) is a **separate** story, **3.4c** (status `backlog`), which depends on this one. Do **NOT** implement Story 2.13 (`convert_import`, the jj-native import mode) — that is a deferred 0.2 fast-follow. Do **NOT** add `pub const` codes to `zanshin-ffi/src/envelope.rs` (that emission lands in 3.4c). One new module + 3 new `RepoError` variants + one test file + the lib.rs / api-stability / error-registry wiring. (project-context.md § "Simplicity First", § "Surgical Changes")

## Acceptance Criteria

> All `epics.md` line cites are from `_bmad-output/planning-artifacts/epics.md` (Story 2.12, lines 1674–1735). Two ACs (AC-3, AC-9) are **reconciled** to the `detect_repo → Result<RepoKind, …>` shape adopted in Story 2.11 (see Dev Notes → Decision D6) and to the detect-gated design; the reconciliation is called out inline.

### AC-1 — Module + public surface (FR-JJ-18a) [epics.md:1684–1687]

**Given** `crates/zanshin-jj/src/convert.rs`
**When** created
**Then** it defines `pub fn convert_colocated(path: &Path) -> Result<Repo, RepoError>` (FR-JJ-18a)
**And** `RepoError` (in `repo.rs`) gains three struct variants: `AlreadyJjRepo { path: PathBuf }`, `NotAGitRepo { path: PathBuf }`, `ConvertFailed { reason: String }`
**And** `convert_colocated` is re-exported from `lib.rs` (`pub use convert::convert_colocated;`, with `pub(crate) mod convert;`).

### AC-2 — Happy path: convert a `RepoKind::Git` path [epics.md:1689–1694]

**Given** `convert_colocated(path)`
**When** `detect_repo(path) == Ok(RepoKind::Git)`
**Then** it performs jj's colocated init (the jj-lib equivalent of `jj git init --colocate`; the exact jj-lib calls are absorbed inside `convert.rs` per FR-JJ-16 — see Dev Notes → "Confirmed jj-lib 0.42 API")
**And** on success a `.jj/` exists next to the existing `.git/`
**And** the existing Git history is imported and visible — the Git HEAD commit is reachable in the resulting jj repo
**And** it returns a `Repo` handle, and a subsequent `Repo::open(path)` and `detect_repo(path) == Ok(RepoKind::Jj)` both succeed.

### AC-3 — Precondition: already a jj repo → `AlreadyJjRepo` [epics.md:1696–1698]

**Given** `convert_colocated(path)`
**When** `detect_repo(path) == Ok(RepoKind::Jj)`
**Then** it returns `Err(RepoError::AlreadyJjRepo { path })` and changes nothing on disk.

### AC-4 — Precondition: not a git repo → `NotAGitRepo` [epics.md:1700–1702]

**Given** `convert_colocated(path)`
**When** `detect_repo(path)` is `Ok(RepoKind::Neither)` or `Ok(RepoKind::PathNotFound)`
**Then** it returns `Err(RepoError::NotAGitRepo { path })`.

### AC-5 — Additive & reversible; `.git/` never destructively modified [epics.md:1704–1708]

**Given** the conversion is additive and reversible
**When** it completes (or fails)
**Then** the existing `.git/` is never destructively modified — the Git `HEAD` SHA and the set of refs are **unchanged** (asserted before/after in a test, see AC-9 test recipe)
**And** removing the created `.jj/` restores the plain Git repo (a subsequent `detect_repo(path) == Ok(RepoKind::Git)`)
**And** on failure any partially-created `.jj/` is rolled back — no leftover `.jj/` remains (mirrors the `Repo::clone` rollback discipline in `repo.rs`).

### AC-6 — Working copy is never clobbered; no data loss [epics.md:1725–1727, 1704–1707]

**Given** a Git repo with a dirty working tree (uncommitted changes)
**When** `convert_colocated` is called
**Then** **no on-disk working-copy file is overwritten** by the conversion — the dirty changes survive verbatim (jj snapshots the working-copy state into `@` on the next working-copy-reading operation; documented behaviour)
**And** "no changes are lost" holds because `convert` performs **no** working-copy materialisation (`Workspace::check_out`) — it only updates the jj view in a transaction. See Dev Notes → Decision D3 (the load-bearing difference from `Repo::clone`).

### AC-7 — jj-lib failures wrapped, never panic [epics.md:1710–1713]

**Given** any jj-lib failure during conversion (or a `detect_repo` I/O error)
**When** it occurs
**Then** it is wrapped as `RepoError::ConvertFailed { reason }` (the jj-lib / `DetectError` Display flattened to a `String` — no `jj_lib`/`gix` type leaks the public API)
**And** the call never panics (no `unwrap`/`expect`/`panic!` on the library path).

### AC-8 — Error-code registry rows added [epics.md:1715–1717]

**Given** the error-code registry
**When** this story lands
**Then** `docs/rust-error-codes.md` registers `jj.already_jj_repo`, `jj.not_a_git_repo`, and `jj.convert_failed` in the same PR (project-context Error-code-taxonomy rule)
**And** each row's **Status** marks the code as *Reserved* — the `RepoError` variants are introduced here, but the dotted `error.code` strings are emitted later by Story 3.4c in `envelope.rs` (this story adds **no** `envelope.rs` const — it has no FFI). See Dev Notes → Decision D5.

### AC-9 — Integration-test coverage [epics.md:1719–1735]

**Given** integration tests in `crates/zanshin-jj/tests/convert.rs`
**When** they run
**Then** they assert all of:
1. **Happy path** — `git init` + one commit on `main` → `convert_colocated` → `Ok`; afterwards `detect_repo == Ok(Jj)`, and the committed history is reachable in jj — assert via `repo.list_bookmarks()` containing a bookmark named `main` whose target is the HEAD change (the robust check; `import_refs`/`import_head` ran). **Do not assert `resolve_revset("@-") == HEAD`** — `@` is not positioned onto HEAD until the first colocated snapshot (D3a), so `@-` is the root commit immediately after convert. Also assert `git log` (via test-only `git()` shell) still shows the commit.
2. **`.git/` untouched** — capture the Git `HEAD` SHA and ref list *before* convert and assert they are identical *after* (AC-5).
3. **AlreadyJjRepo** — converting an already-jj path (the `tiny-3-commits` fixture, or the just-converted repo) → `Err(AlreadyJjRepo)`.
4. **NotAGitRepo** — converting an empty tmpdir → `Err(NotAGitRepo)`; and a nonexistent path → `Err(NotAGitRepo)` (both arms of AC-4).
5. **Unborn branch** — `git init` with **zero** commits → `Ok` (a colocated repo with empty history; no panic) (AC: epics.md:1729–1731).
6. **Dirty working tree** — `git init` + commit, then modify a tracked file *without* committing → `convert_colocated` → `Ok`, and the modified file's on-disk contents are **byte-identical** afterwards (AC-6).
7. **Rollback** — a forced mid-conversion failure leaves **no** partial `.jj/` (`!path.join(".jj").exists()`) and returns `Err(ConvertFailed)` (see Dev Notes → "Coverage note" for a deterministic failure-injection recipe).
8. **Reconciled — bare repo** — a `git init --bare` dir → `Err(NotAGitRepo)` (the detect-gated design classifies a bare repo as `Neither`; this *reconciles* the epic's predate-detect "bare → ConvertFailed" prose — see Decision D7 + Open Question OQ1).

### AC-10 — Quality gate green incl. coverage ratchet [CLAUDE.md; docs/coverage.md]

**Given** the change is complete
**When** `cargo make test` runs
**Then** it passes end-to-end: `cargo test`, clippy (pedantic, `-D warnings`), rustfmt, `dart analyze`/`format`, `cargo deny`, **and** the coverage ratchet
**And** `crates/zanshin-jj/src/convert.rs` (a new file) meets the new-file floor and in practice reaches ~100% line coverage (every precondition arm + the success/rollback paths are exercised by AC-9)
**And** the auto-raised `coverage-baseline.txt` is committed in the same change.

## Tasks / Subtasks

- [x] **Task 1 — Add the three `RepoError` variants** (AC: 1, 7) — in `crates/zanshin-jj/src/repo.rs`
  - [x] Add `AlreadyJjRepo { path: PathBuf }`, `NotAGitRepo { path: PathBuf }`, `ConvertFailed { reason: String }` to the `RepoError` enum, each with a `#[error("…")]` message and doc comments on the variant **and its fields** (`#![deny(missing_docs)]` is on — missing docs is a compile error). Mirror the existing `PathNotFound { path }` / `InitFailed { reason }` styling.
  - [x] Make the module-private `fn make_settings()` **`pub(crate)`** so `convert.rs` can reuse the canonical settings builder (same `[user]`/`[operation]` identity as `init`/`clone`, so the convert operation is attributed to "Zanshin" in `jj op log`). This is the *only* change to `make_settings`.

- [x] **Task 2 — Create `src/convert.rs`** (AC: 1, 2, 3, 4, 5, 6, 7) — see Dev Notes → "Copy-adaptable skeleton"
  - [x] `// SPDX-License-Identifier: MIT` as the **first line**.
  - [x] `pub fn convert_colocated(path: &Path) -> Result<Repo, RepoError>`: detect-gate (Decision D2) → on `Git`, run the conversion in a rollback wrapper → reopen via `Repo::open(path)`.
  - [x] Conversion body (private helper, returns `Result<(), RepoError>` so the caller can roll back): `init_external_git(path, &path.join(".git"))` → `import_refs` → `import_head` → `tx.commit` → reopen via `Repo::open`. **No** `@`-reparent (`mut_repo.check_out`), **no** `workspace.check_out`, **no** snapshot (Decisions D1 / D3 / D3a).
  - [x] Rollback (Decision D4): on any `Err`, `let _ = std::fs::remove_dir_all(path.join(".jj"));` — **never** touch `.git/`.
  - [x] Map every `jj_lib` error and the `DetectError` to `RepoError::ConvertFailed { reason: e.to_string() }`. No `unwrap`/`expect`/`panic!` on the library path.

- [x] **Task 3 — Wire `lib.rs`** (AC: 1)
  - [x] Add `pub(crate) mod convert;` to the module list.
  - [x] Add `pub use convert::convert_colocated;` to the re-export list.

- [x] **Task 4 — Update the surface-lock test** (AC: 1) — `crates/zanshin-jj/tests/api_stability.rs`
  - [x] Inside `api_surface_resolves`, add the fn-pointer binding: `_ = zanshin_jj::convert_colocated as fn(&std::path::Path) -> Result<zanshin_jj::Repo, zanshin_jj::RepoError>;`
  - [x] Add the three new variant constructions next to the existing `RepoError::Backend(String::new())` line, proving they are `jj_lib`-free: `_ = zanshin_jj::RepoError::AlreadyJjRepo { path: std::path::PathBuf::new() };`, `… NotAGitRepo { path: PathBuf::new() };`, `… ConvertFailed { reason: String::new() };`.
  - [x] **Do NOT bump the "(26 types …)" comment** — `convert_colocated` is a free function and the new variants belong to the already-counted `RepoError`; no new exported **type** is added. (Story 2.10's review flagged spurious *and* stale count drift — keep it accurate in both directions.)

- [x] **Task 5 — Integration tests `tests/convert.rs`** (AC: 2–7, 9) — mirror `tests/repo.rs` helpers (Dev Notes → "Test recipe")
  - [x] `// SPDX-License-Identifier: MIT` first line; reuse the `pin_env()` + `git()` + `TempDir` patterns from `tests/repo.rs` (copy the helpers — integration tests don't share a module). **`pin_env()` IS required here** (convert exercises jj/git config, unlike `detect`).
  - [x] Cover the eight cases in AC-9 (happy path, `.git/` untouched, AlreadyJjRepo, NotAGitRepo ×2 inputs, unborn branch, dirty tree, rollback, bare repo).

- [x] **Task 6 — Error-code registry** (AC: 8) — `docs/rust-error-codes.md`
  - [x] Add three rows under the `jj` domain: `jj.already_jj_repo`, `jj.not_a_git_repo`, `jj.convert_failed`. Status column = `Reserved — Story 2.12 (RepoError variants); emitted by Story 3.4c (envelope.rs)`. (Mirror the `watcher.*` "Reserved" rows' format.) Add **no** `envelope.rs` const.

- [x] **Task 7 — Gate** (AC: 10)
  - [x] Run `cargo make test`; make it green. Commit the auto-raised `coverage-baseline.txt` alongside the code. **Never** lower the baseline or add an `exclude_prefix` to pass (CLAUDE.md, review-blocking).

## Dev Notes

### Decision D1 — Use `init_external_git` (open the existing `.git`), **NOT** `init_colocated_git`. Verified against the shipping jj CLI.

> ⚠️ **This corrects the naïve guess.** The lib-only reconstruction would reach for `Workspace::init_colocated_git` — that is **wrong** for converting an *existing* repo. Confirmed by reading the shipping CLI at the pinned tag.

The canonical, non-destructive way to convert an *existing* Git repo to colocated is **`Workspace::init_external_git(&settings, path, &path.join(".git"))`**:

- It `gix::open`s the existing `.git` (opens, **never** re-inits → strongest possible "`.git/` untouched" guarantee for AC-5).
- Because `.git` sits *inside* the workspace root, the result is a **colocated** workspace — `git_util::is_colocated_git_workspace` returns `true` precisely when `git_backend.git_workdir() == workspace.workspace_root()` (jj CLI `git_util.rs:63–78` @ `v0.42.0`).

`init_colocated_git` is the **wrong** primitive here: it calls `gix::init_opts` (re-initialises the repo) and is what the CLI uses **only when no `.git` exists yet** (a fresh colocated repo). This is exactly how `jj git init --colocate` is implemented — confirmed by reading `cli/src/commands/git/init.rs::do_init` @ `v0.42.0` (local checkout `../jj`): when `.git` already exists it takes the `GitInitMode::External(workspace_root/.git)` branch, **not** `Colocate`. (It even refuses to colocate inside a *linked Git worktree* — see OQ4.)

`repo.rs::clone_into` (lines ~237–364) is your template for the **transaction/commit/reload mechanics only**. Convert is **much simpler** than clone: no remote-registration/fetch, **no `@`-reparent** (Decision D3a), and **no `workspace.check_out`** materialisation (Decision D3). Read `clone_into` for the `start_transaction`/`tx.repo_mut()`/`tx.commit` shape, then write the far shorter convert body below.

### Decision D2 — Gate on `detect_repo`, not hand-rolled `.jj`/`.git` checks.

The epic frames every precondition in terms of `detect_repo(path) == RepoKind::X`. `detect_repo` (Story 2.11, **done**) now returns `Result<RepoKind, DetectError>`. Branch exactly:

```rust
match crate::detect_repo(path) {
    Ok(RepoKind::Jj)        => return Err(RepoError::AlreadyJjRepo { path: path.to_owned() }), // AC-3
    Ok(RepoKind::Git)       => { /* proceed with the conversion */ }                            // AC-2
    Ok(RepoKind::Neither)
    | Ok(RepoKind::PathNotFound) => return Err(RepoError::NotAGitRepo { path: path.to_owned() }), // AC-4
    Err(e)                  => return Err(RepoError::ConvertFailed { reason: e.to_string() }),  // AC-7 (stat I/O error)
}
```

This composes 2.11's `detect_repo` (clean dependency; 2.11 is `done`). Use the `crate::detect_repo` re-export, not `crate::detect::detect_repo`.

### Decision D3 — The load-bearing safety property: **never materialise or reset the working copy.**

`clone_into` ends with `workspace.check_out(op_id, None, wc_commit)` — that **writes** `@`'s tree to disk (correct for clone: the target dir is empty/new). For **convert**, the working tree already exists and may be dirty; writing to it would **clobber uncommitted changes** → data loss → AC-6 violation. So convert performs **no** working-copy I/O at all:

- **Do NOT call `workspace.check_out(...)`** (the on-disk materialiser).
- **Do NOT snapshot the working copy** inside convert.
- Convert writes **only** to `.jj/` (jj metadata via `init_external_git` + the import transaction) and **opens** (never re-inits) the existing `.git/`. The user's tracked files are never touched ⇒ "no changes are lost" (AC-6) holds by construction. jj snapshots the on-disk state into `@` lazily on the next working-copy-reading op (the documented colocated auto-sync). `Repo::status()` is read-only and will not snapshot — fine for the ACs.

### Decision D3a — Convert does **not** reparent `@` onto HEAD; HEAD/`@` positioning is lazy.

The CLI's `import_head` + `tx.check_out(git_head)` block is gated behind **`!working_copy_shared_with_git()`** — i.e. it runs **only for non-colocated** workspaces. For a colocated repo (ours), that block is **skipped**: HEAD import and `@` positioning come from the colocated working-copy **snapshot** the CLI runs afterwards, which we deliberately don't do (D3). So:

- Convert does **not** call `mut_repo.check_out` to move `@`. After convert, `@` is the fresh empty commit `init_external_git` created; the imported history (incl. the HEAD commit) is reachable via the imported **bookmarks** (see the API table + skeleton below). `@` settles onto HEAD on the first colocated snapshot.
- We *do* call `git::import_head` (view-only — see the API table below) so the HEAD **commit object** + `git_head` ref are imported immediately, guaranteeing AC-2's "HEAD commit reachable" even for a detached HEAD. `import_head`'s own doc: it imports HEAD but "doesn't move the working-copy commit" — exactly the view-only, no-clobber behaviour we want.

### Decision D4 — Rollback removes only `.jj/`, never `.git/`.

Wrap the conversion body in a helper returning `Result<(), RepoError>`; on `Err`, `let _ = std::fs::remove_dir_all(path.join(".jj"));`. Because the precondition guaranteed `RepoKind::Git` (a pre-existing `.git/` that **we did not create**), the only artefact convert creates is `.jj/`. This mirrors `Repo::clone`'s else-branch (`repo.rs:226–231`) which removes just `.jj/` when the target dir pre-existed. **Never** `remove_dir_all(.git)` and **never** `remove_dir_all(path)` — that would destroy the user's Git repo.

### Decision D5 — Error codes are *registered* here, *emitted* in 3.4c.

Per `docs/rust-error-codes.md`, every dotted `error.code` is emitted **only** from `zanshin-ffi/src/envelope.rs`, and 2.12 has **no FFI** (that's 3.4c). So:

- 2.12 adds the three **`RepoError` variants** (Rust-side) **and** three **doc rows** to `docs/rust-error-codes.md` (satisfies the epic AC), each marked *Reserved — emitted by 3.4c*.
- 2.12 adds **no** `pub const JJ_*` to `envelope.rs` and **no** error.code string in code. 3.4c will add the consts and map `AlreadyJjRepo`/`NotAGitRepo`/`ConvertFailed` → `jj.already_jj_repo`/`jj.not_a_git_repo`/`jj.convert_failed`. (This is the same split 2.11 used for `jj.detect_failed`.)

### Decision D6 — ACs reconciled to `detect_repo: Result<…>` and `RepoKind::PathNotFound`.

The epic prose (written 2026-06-20) predates Story 2.11's post-review **Design B** (`detect_repo` returns `Result<RepoKind, DetectError>`; the not-found variant is `RepoKind::PathNotFound`, not `Missing`). The ACs above use the *final* shape. The `Err(DetectError)` arm (AC-7) is new surface the epic didn't enumerate — a stat I/O error during detection (`EACCES`/`ENOTDIR`) maps to `ConvertFailed`, not `NotAGitRepo` (a stat failure is a genuine failure, not "absent").

### Decision D7 — Bare repo reconciles to `NotAGitRepo` (not the epic's `ConvertFailed`).

The epic's edge case (epics.md:1733–1735) says a bare repo → `ConvertFailed`. But that prose predates the **detect-gated** design: a bare repo dir (`git init --bare`) has `HEAD`/`objects/`/`refs/` *directly* — **no `.git` sub-entry and no `.jj`** — so `detect_repo` classifies it `Neither` ⇒ convert returns `NotAGitRepo` before any jj-lib call. This is the correct, consistent outcome of gating on `detect_repo` (Decision D2). `ConvertFailed` stays reserved for genuine jj-lib failures on a `.git`-bearing path. AC-9 case 8 locks `NotAGitRepo`; flagged as OQ1 for Ralph to confirm.

### Confirmed jj-lib 0.42 API (cross-verified: vendored `jj-lib-0.42.0` **and** the jj CLI `do_init` @ `v0.42.0`, local checkout `../jj`)

All are `async` → wrap in `pollster::block_on(...)` exactly as the rest of `repo.rs` does. `jj_lib` is fine **inside** this crate (FR-JJ-16); just keep it out of public signatures.

| Call | Signature (0.42) | Notes |
|------|------------------|-------|
| `Workspace::init_external_git` | `(&UserSettings, &Path /*workspace_root*/, &Path /*git_repo_path*/) -> Result<(Workspace, Arc<ReadonlyRepo>), WorkspaceInitError>` | `workspace.rs:255`. **The correct primitive (D1).** Pass `git_repo_path = path.join(".git")`. `gix::open`s the existing `.git` (non-destructive); colocated because `.git` is inside the workspace root. The CLI uses exactly this for an existing `.git` (`init.rs::do_init` → `GitInitMode::External`). |
| `git::import_refs` | `(&mut MutableRepo, &GitImportOptions) -> Result<GitImportStats, GitImportError>` | `git.rs:563`. Imports local git branches/tags as jj bookmarks (this is what makes the HEAD commit reachable via its branch). `GitImportOptions { abandon_unreachable_commits: false, record_synthetic_predecessors: false, remote_auto_track_bookmarks: HashMap::new() }` — note **`false`** for `abandon_unreachable_commits` (the CLI's *init* path sets it `false`: "no old refs to abandon" — **not** clone's `true`). |
| `git::import_head` | `(&mut MutableRepo) -> Result<(), GitImportError>` | `git.rs:1113`. Imports the Git `HEAD` commit object + sets `git_head`. **View-only — does NOT move `@`** (its own doc). Guarantees AC-2 even for a detached HEAD. No-op on an unborn branch (`head_id()` errors → `None`) ⇒ AC-9 case 5 succeeds. |
| `tx.commit("convert to colocated")` | `async -> Result<Arc<ReadonlyRepo>, …>` | Commits the import transaction — visible in `jj op log` as a Zanshin op (NFR-R-2). |

Recommended order inside the one transaction: `import_refs` → `import_head` → `tx.commit(...)`. Then **reopen** with `Repo::open(path)` to produce the returned handle (Decision D8). **Do NOT** add `mut_repo.check_out`/`rebase_descendants`/`workspace.check_out` (D3/D3a — `@` settles lazily). `git::export_refs` is **not** needed (OQ3): convert creates no jj-side bookmarks that git lacks, so there is nothing to export and `.git` refs stay byte-identical (AC-5). The CLI calls `export_refs` only to push back *auto-tracked* local bookmarks, which we don't configure.

### Decision D8 — Build the returned `Repo` by reopening, not by reaching into private fields.

`Repo`'s fields (`workspace`, `settings`) are private to the `repo` module, so `convert.rs` can't construct `Repo { … }`. After `tx.commit` succeeds and `.jj/` exists, simply `return Repo::open(path);` — it re-runs the `.jj` check + `Workspace::load` and returns a fresh, correctly-warmed handle (`RepoError` type already matches). This avoids adding a `from_parts` constructor and keeps `Repo` construction owned by `repo.rs`. (If the reopen ever fails it surfaces as `RepoError::Backend` — acceptable; optionally map to `ConvertFailed` for taxonomy consistency.)

### Copy-adaptable skeleton for `convert.rs`

```rust
// SPDX-License-Identifier: MIT

//! Colocated Git → jj conversion (FR-JJ-18a).
//!
//! Converts an existing Git repository into a colocated jj workspace: a `.jj/`
//! is created next to the existing, **untouched** `.git/`, full history is
//! imported, and the `git` CLI keeps working. Additive and reversible —
//! deleting `.jj/` restores the plain Git repo. Acts only on the caller's
//! explicit choice; the conversion never overwrites a working-copy file.

use std::collections::HashMap;
use std::path::Path;

use jj_lib::git::{import_head, import_refs, GitImportOptions};
use jj_lib::settings::UserSettings;
// `Workspace::init_external_git` is in `jj_lib::workspace`; `start_transaction`/
// `repo_mut`/`commit` are inherent — no `jj_lib::repo::Repo` trait import needed here.

use crate::repo::make_settings; // now pub(crate)
use crate::{detect_repo, Repo, RepoError, RepoKind};

/// Converts the Git repository at `path` into a colocated jj workspace (FR-JJ-18a).
///
/// Additive and reversible: a `.jj/` is created alongside the existing,
/// non-destructively-reused `.git/`; the working-copy files are never
/// overwritten. Returns a warm [`Repo`] handle for the now-colocated workspace.
///
/// # Errors
///
/// - [`RepoError::AlreadyJjRepo`] — `path` is already a jj workspace.
/// - [`RepoError::NotAGitRepo`] — `path` is neither a Git repo nor exists.
/// - [`RepoError::ConvertFailed`] — a jj-lib failure (or a `detect_repo` I/O
///   error) during conversion; the partially-created `.jj/` is rolled back.
pub fn convert_colocated(path: &Path) -> Result<Repo, RepoError> {
    match detect_repo(path) {
        Ok(RepoKind::Jj) => return Err(RepoError::AlreadyJjRepo { path: path.to_owned() }),
        Ok(RepoKind::Git) => {}
        Ok(RepoKind::Neither | RepoKind::PathNotFound) => {
            return Err(RepoError::NotAGitRepo { path: path.to_owned() })
        }
        Err(e) => return Err(RepoError::ConvertFailed { reason: e.to_string() }),
    }

    let settings = make_settings()?;
    match convert_into(&settings, path) {
        Ok(()) => Repo::open(path),
        Err(e) => {
            // Roll back only what convert created: the `.jj/` dir. Never touch `.git/`.
            let _ = std::fs::remove_dir_all(path.join(".jj"));
            Err(e)
        }
    }
}

/// Runs the external-git init + ref/head import. On `Err`, the caller rolls back `.jj/`.
fn convert_into(settings: &UserSettings, path: &Path) -> Result<(), RepoError> {
    // 1. Open the EXISTING `.git` as the backing store (gix::open — strictly
    //    non-destructive). Because `.git` is inside `path`, the workspace is
    //    colocated. This is what `jj git init --colocate` does for an existing
    //    repo (cli/src/commands/git/init.rs @ v0.42.0 -> GitInitMode::External).
    let git_repo_path = path.join(".git");
    let (_workspace, repo) = pollster::block_on(
        jj_lib::workspace::Workspace::init_external_git(settings, path, &git_repo_path),
    )
    .map_err(|e| RepoError::ConvertFailed { reason: e.to_string() })?;

    // 2. Import existing Git history into jj's view — VIEW-ONLY, no disk writes:
    //    branches/tags -> bookmarks (makes the HEAD commit reachable via its
    //    branch), and HEAD -> git_head + the HEAD commit object (covers a
    //    detached HEAD too). NO `@`-reparent, NO working-copy snapshot/check_out
    //    (D3/D3a): `@` settles onto HEAD on the next colocated snapshot.
    let import_options = GitImportOptions {
        abandon_unreachable_commits: false, // fresh import: no stale jj refs (CLI init path)
        record_synthetic_predecessors: false,
        remote_auto_track_bookmarks: HashMap::new(),
    };
    let mut tx = repo.start_transaction();
    pollster::block_on(import_refs(tx.repo_mut(), &import_options))
        .map_err(|e| RepoError::ConvertFailed { reason: e.to_string() })?;
    pollster::block_on(import_head(tx.repo_mut()))
        .map_err(|e| RepoError::ConvertFailed { reason: e.to_string() })?;
    pollster::block_on(tx.commit("convert to colocated"))
        .map_err(|e| RepoError::ConvertFailed { reason: e.to_string() })?;
    Ok(())
}
```

> ⚠️ The jj-lib entry points and order above are **cross-verified against the shipping jj CLI** (`do_init` @ `v0.42.0`, local checkout `../jj`) — this is the real `jj git init --colocate` path for an existing repo. Still reconcile the exact transaction method names against `repo.rs::clone_into` as you write it (`tx.repo_mut()` → `&mut MutableRepo`; `tx.commit(...)` is async via `pollster::block_on`). Let the compiler + `clone_into` guide the precise borrows; the **structure is correct**. Clippy pedantic (`-D warnings`) is on — group args / extract helpers rather than `#[allow]`.

### Test recipe — mirror `tests/repo.rs`

Copy the helper style verbatim (integration tests don't share a module):

- `pin_env()` + the `static ENV_GUARD` (`tests/repo.rs:14–25`) — **required** here (convert touches jj/git config; without pinning, local vs. CI diverge).
- `git(args, dir)` shell helper (`tests/repo.rs:222–229`) and the `git init --initial-branch=main` + `config user.*` + `write` + `add` + `commit` recipe (`tests/repo.rs:166–171`) for building the source Git repo. Shelling `git` in **tests** is allowed (AR-AP-1 bans it only in production code).
- `tempfile::TempDir` for scratch dirs; `test_helpers::extract_fixture("tiny-3-commits")` for the AlreadyJjRepo case.
- **"`.git/` untouched" (AC-9 case 2):** read `git("rev-parse", "HEAD")` output and the `git("show-ref")` / `for-each-ref` listing before and after convert; assert equal. (Capture stdout — extend the local `git()` helper to a `git_stdout()` variant that returns the captured output, since the existing helper only checks exit status.)
- **"reachable in jj" (AC-9 case 1):** after convert, `let repo = zanshin_jj::Repo::open(path)?;` then assert `repo.list_bookmarks()` contains a bookmark named `main` (its target is the imported HEAD change). Avoid `resolve_revset("@-")` for this assertion — `@` is positioned lazily (D3a).
- **Dirty tree (AC-9 case 6):** after the initial commit, `fs::write(path.join("README.md"), "dirty")` (no commit), convert, then assert `fs::read_to_string(path.join("README.md")) == "dirty"` (byte-identical, AC-6).
- Naming: scenario-describing — `convert_git_repo_with_commit_returns_jj`, `convert_already_jj_repo_returns_already_jj_repo`, `convert_empty_dir_returns_not_a_git_repo`, `convert_unborn_branch_succeeds_empty_history`, `convert_dirty_tree_preserves_uncommitted_changes`, `convert_failure_rolls_back_partial_jj`, `convert_bare_repo_returns_not_a_git_repo`, … (project-context Naming rule).

### Coverage note — the rollback / `ConvertFailed`-from-jj-lib arm is the attention point

`convert.rs` is a **new file** → must clear the new-file floor (`docs/coverage.md`); aim ~100%. Most arms are trivially covered (the four `detect_repo` arms, the success body). The **one** arm that needs deliberate effort is `convert_into` returning `Err` *after* `.jj/` was created (exercises both the `ConvertFailed` jj-lib mapping **and** the `remove_dir_all(.jj)` rollback line).

Deterministic failure-injection recipe (AC-9 case 7): create a **structurally-present but invalid `.git`** so `detect_repo` returns `Git` yet `init_external_git` fails *after* `.jj/` is created. Simplest: an **empty `.git` directory** — `std::fs::create_dir(path.join(".git"))` and nothing else. `detect_repo` sees a `.git` dir ⇒ `Ok(Git)` ⇒ convert proceeds; `Workspace::init_external_git` first creates `.jj/` (via `create_jj_dir`, `workspace.rs:303`) **then** `gix::open`s the empty `.git`, which fails (no HEAD/objects) ⇒ `ConvertFailed`; the rollback removes `.jj/`. Assert the result is `Err(ConvertFailed)` **and** `!path.join(".jj").exists()`. (A junk `.git` *file* — `fs::write(path.join(".git"), b"garbage")` — is an equivalent alternative.) This exercises **both** the `ConvertFailed` jj-lib mapping **and** the `remove_dir_all(.jj)` rollback line. **Do not** add an `exclude_prefix` to dodge this arm (review-blocking — CLAUDE.md). The `Err(DetectError) → ConvertFailed` arm (AC-7) is separately covered by the 2.11 trick: a path *under a regular file* makes `detect_repo` return `Err` (`detect_path_under_a_regular_file` in `tests/detect.rs` shows the construction).

### Files this story touches

| File | Action | What |
|------|--------|------|
| `crates/zanshin-jj/src/convert.rs` | **NEW** | `convert_colocated()` + private `convert_into()` (the skeleton above) |
| `crates/zanshin-jj/src/repo.rs` | UPDATE | +3 `RepoError` variants (`AlreadyJjRepo`/`NotAGitRepo`/`ConvertFailed`); `make_settings` → `pub(crate)` |
| `crates/zanshin-jj/src/lib.rs` | UPDATE | `pub(crate) mod convert;` + `pub use convert::convert_colocated;` |
| `crates/zanshin-jj/tests/convert.rs` | **NEW** | integration tests (8 cases per AC-9) |
| `crates/zanshin-jj/tests/api_stability.rs` | UPDATE | bind `convert_colocated` fn-pointer + 3 new `RepoError` variant constructions (no type-count bump) |
| `docs/rust-error-codes.md` | UPDATE | 3 new `jj.*` rows, Status = Reserved (emitted by 3.4c) |
| `coverage-baseline.txt` | UPDATE (auto) | commit the auto-raised baseline |

No `Cargo.toml` change (no new deps — `pollster`, `gix`, `jj_lib`, `tempfile`, `test-helpers` already present). **No** codegen, **no** `schemas/*.fbs`, **no** `envelope.rs`, **no** FFI, **no** Dart.

### Hard rules in scope (project-context.md — reject-at-review on violation)

- **No shelling to `jj`/`git` in production code** (NFR-R-1, FR-JJ-16). `convert.rs` calls jj-lib only; tests may shell `git`.
- **No `extern "C"` outside `crates/zanshin-ffi/`** — none here; FFI is 3.4c.
- **No `unwrap()`/`expect()`/`panic!()` on the library path.** Every jj-lib `Result` maps to `RepoError::ConvertFailed`. Tests may `expect()`.
- **No `jj_lib`/`gix` type in a public position** (FR-JJ-16) — the signature is `(&Path) -> Result<Repo, RepoError>`; `RepoError` variants carry only `PathBuf`/`String`.
- **No data loss / fully reversible** (NFR-R-1/2): never materialise the working copy (D3); rollback removes only `.jj/` (D4); the convert op is visible in `jj op log`.
- **SPDX first line** on both new `.rs` files. **rustfmt `max_width = 100`, clippy pedantic `-D warnings`.**
- **Coverage ratchet: add tests, never lower the baseline / never `exclude_prefix`.**

### Previous-story intelligence (2.11 detect + 2.3 clone) — pre-empt the known traps

- **`detect_repo` is fallible now (2.11 Design B).** It returns `Result<RepoKind, DetectError>` and the not-found variant is `PathNotFound` (not `Missing`). The skeleton's `match` handles all four `Ok` arms + the `Err`. Don't write `detect_repo(path) == RepoKind::Git` (won't compile — it's a `Result`).
- **`clone_into` is your template and it already solved the hard parts** (the `mut_repo.check_out` borrow dance, `rebase_descendants`, `tx.commit`, reload). The clone story's review **deferred** a clone-*rollback* data-loss concern (`deferred-work.md`); convert's rollback is simpler (only `.jj/`, `.git/` pre-existed) — get it right here.
- **`#![deny(missing_docs)]` is a hard compile gate.** Every new `pub` item — `convert_colocated`, the three `RepoError` variants, **and each variant field** — needs a `///`.
- **Surface-lock test (2.10) won't *know* about new surface unless you add it.** Bind `convert_colocated` + the new variants in `api_stability.rs` (Task 4). But **don't** bump the "26 types" comment — no new *type* is exported (it's a fn + enum variants).
- **Scope discipline (2.8/2.9/2.11).** Do **not** start 3.4c (FFI `zanshin_repo_convert`) or 2.13 (`convert_import`) here, even though they're adjacent. 2.11 deferred all FFI to 3.4c — mirror that.
- **Doc-comment accuracy is reviewed against ground truth** (2.6/2.9 patched over-stated docs). Keep the module/fn docs precise: "additive, reversible, `.git/` non-destructively reused, working copy never overwritten" must match the code (they do, in the skeleton).

### Project Structure Notes

- Module-by-noun layout (project-context.md § File & module organization): `convert.rs` sits beside `repo.rs`, `detect.rs`, `status.rs`, `change.rs`, `op_log.rs`, `bookmarks.rs`, `remotes.rs`, `revset.rs` — consistent. No `mod.rs`.
- `pub(crate) mod convert;` mirrors the sibling `pub(crate) mod`s; `pub use convert::convert_colocated;` mirrors the existing re-export block (`lib.rs:39–46`).
- Tests live in `tests/convert.rs` (integration: exercises the public API + real repos) per CLAUDE.md test-placement rule and the epic's explicit path (epics.md:1719). `convert_into` is a private helper but is fully exercised through the public `convert_colocated`, so no inline `#[cfg(test)]` unit tests are needed.

### References

- [Story 2.12 ACs + edge cases](_bmad-output/planning-artifacts/epics.md) — epics.md:1674–1735
- [FR-JJ-18a (colocated conversion)](_bmad-output/planning-artifacts/prd.md) — prd.md:215
- [Epic 2 scope incl. FR-JJ-18a](_bmad-output/planning-artifacts/epics.md) — epics.md:339, 341
- [Story 2.11 — `detect_repo` (done; the precondition gate)](_bmad-output/implementation-artifacts/2-11-implement-detect-rs-repository-kind-detection.md)
- [Story 2.13 — `convert_import` (NOT this story; deferred 0.2)](_bmad-output/planning-artifacts/epics.md) — epics.md:1739–1768
- [Story 3.4c — FFI exposure of detect/convert (NOT this story)](_bmad-output/planning-artifacts/epics.md) — epics.md:2117–2157
- [`zanshin-jj/src/repo.rs`](crates/zanshin-jj/src/repo.rs) — `RepoError` enum, `make_settings`, and `clone_into` (the conversion template: lines 237–364; rollback else-branch 226–231)
- [`zanshin-jj/src/lib.rs`](crates/zanshin-jj/src/lib.rs) — re-export surface + `#![deny(missing_docs)]`
- [`zanshin-jj/src/detect.rs`](crates/zanshin-jj/src/detect.rs) — `detect_repo` / `RepoKind` / `DetectError` (the gate)
- [`zanshin-jj/tests/repo.rs`](crates/zanshin-jj/tests/repo.rs) — `git()` + `pin_env()` + `TempDir` + the git-init-with-commit recipe to mirror (lines 14–25, 158–190, 222–229)
- [`zanshin-jj/tests/api_stability.rs`](crates/zanshin-jj/tests/api_stability.rs) — surface-lock test to extend
- jj-lib 0.42 source (read-only reference, vendored at `~/.cargo/registry/src/…/jj-lib-0.42.0/`): `workspace.rs:255` (`init_external_git` — the correct primitive, D1), `git.rs:563` (`import_refs`), `git.rs:1113` (`import_head`)
- **jj CLI source @ tag `v0.42.0`** (local checkout `../jj`; matches the pinned lib version): `cli/src/commands/git/init.rs::do_init` — the real `jj git init --colocate`, whose `GitInitMode::External` branch (existing `.git`) is the canonical conversion path; `cli/src/git_util.rs:63` (`is_colocated_git_workspace`). ⚠️ The working tree is checked out **56 commits past** the tag — read at the exact tag with `git show v0.42.0:<path>` (or `git -C ../jj checkout v0.42.0`).
- [docs/rust-error-codes.md](docs/rust-error-codes.md) — registry to extend (Reserved-row format under `jj`)
- [project-context.md](_bmad-output/project-context.md) — canonical ruleset (FR-JJ-16, simplicity, coverage ratchet, error-code taxonomy)
- [docs/coverage.md](docs/coverage.md) — coverage ratchet mechanism + new-file floor

## Dev Agent Record

### Agent Model Used

claude-sonnet-4-6

### Debug Log References

- rustfmt required `Ok(RepoKind::Neither | RepoKind::PathNotFound)` as a single-line arm (not a braced block) and `import_head(...).map_err(...)` on one line. Applied manually after each `cargo make test` run.
- Coverage ratchet caught `zanshin-ffi/src/repo.rs` regression (96.60% < 100% baseline): the `AlreadyJjRepo`, `NotAGitRepo`, and `ConvertFailed` arms in `map_repo_err` were untested. Added three unit tests; baseline auto-raised.
- `refs/jj/keep/*` GC-keep refs added by jj during `import_refs`/`import_head` are internal/additive; scoped the "`.git/` untouched" assertion in `convert_git_repo_does_not_modify_git_dir` to `refs/heads` + `refs/tags` only.

### Completion Notes List

- `convert_colocated` uses `Workspace::init_external_git` (NOT `init_colocated_git`) — confirmed against jj CLI `do_init` @ v0.42.0 (Decision D1). Opens existing `.git` via `gix::open`; strictly non-destructive.
- No working-copy I/O: no `workspace.check_out`, no snapshot, no `@`-reparent (Decisions D3/D3a). `@` settles lazily on next colocated op.
- Rollback removes only `.jj/`; never touches `.git/` (Decision D4).
- Error-code rows registered as Reserved in `docs/rust-error-codes.md`; actual `envelope.rs` consts + FFI mapping deferred to Story 3.4c (Decision D5). `zanshin-ffi/src/repo.rs::map_repo_err` bridges new variants to `JJ_JJ_LIB_ERROR` as a temporary measure.
- D7 confirmed: bare repo → `NotAGitRepo` (detect-gated; classifies as `Neither`).
- Open Questions OQ1–OQ4 remain non-blocking defaults as designed.
- `cargo make test` green with coverage-baseline.txt auto-raised.

### File List

- `crates/zanshin-jj/src/convert.rs` — **NEW**: `convert_colocated()` + private `convert_into()`
- `crates/zanshin-jj/src/repo.rs` — +3 `RepoError` variants; `make_settings` → `pub(crate)`
- `crates/zanshin-jj/src/lib.rs` — `pub(crate) mod convert;` + `pub use convert::convert_colocated;`
- `crates/zanshin-jj/tests/convert.rs` — **NEW**: 10 integration tests (8 AC-9 cases + reversibility)
- `crates/zanshin-jj/tests/api_stability.rs` — fn-pointer + 3 `RepoError` variant constructions
- `crates/zanshin-ffi/src/repo.rs` — `map_repo_err` extended for 3 new variants + 3 new unit tests
- `docs/rust-error-codes.md` — 3 Reserved rows: `jj.already_jj_repo`, `jj.not_a_git_repo`, `jj.convert_failed`
- `coverage-baseline.txt` — auto-raised by coverage gate

### Change Log

- 2026-06-27: Story 2.12 created (create-story). Pure `zanshin-jj` Rust: `convert_colocated(&Path) -> Result<Repo, RepoError>` (FR-JJ-18a) composing 2.11's `detect_repo` gate + jj-lib history import. +3 `RepoError` variants, `make_settings`→`pub(crate)`, 3 Reserved error-registry rows (emitted by 3.4c), surface-lock + tests. ACs reconciled to `detect_repo: Result<…>`/`PathNotFound` (D6) and bare-repo→`NotAGitRepo` (D7). NO FFI (3.4c), NO `convert_import` (2.13).
- 2026-06-27: **Correction after reading the shipping jj CLI @ `v0.42.0` (local checkout `../jj`).** The lib-only first draft chose `Workspace::init_colocated_git` — **wrong** for an existing repo. The CLI's `do_init` proves the canonical path: existing `.git` → `GitInitMode::External` → **`Workspace::init_external_git(path, path/.git)`** (`gix::open`, non-destructive), and for a *colocated* result it does `import_refs` (+`export_refs`) but **skips** `import_head`/`@`-reparent (gated to non-colocated; colocated gets HEAD/`@` from the lazy snapshot). Rewrote D1, the API table, the skeleton (now `init_external_git` → `import_refs` → `import_head` → commit → reopen; **no** `@`-reparent, **no** `workspace.check_out`; `GitImportOptions.abandon_unreachable_commits` `true`→**`false`** per the CLI init path), D3 + new D3a, the "reachable" test assertion (`list_bookmarks`, not `@-`), the rollback injection (empty `.git` dir), References, and OQ4 (linked-worktree). Net effect: simpler, strictly non-destructive, AC-5 strengthened.

## Open Questions for Ralph (non-blocking — defaults chosen, override before dev if desired)

1. **Bare repo classification (Decision D7).** The detect-gated design returns `NotAGitRepo` for a `git init --bare` dir (it classifies as `Neither`), reconciling the epic's predate-detect "bare → `ConvertFailed`" prose. **Default: `NotAGitRepo`.** Override only if you want convert to special-case a bare repo as `ConvertFailed` (would require a separate bare-repo probe outside `detect_repo`).
2. **Snapshot + `@`-positioning at convert time vs. lazily (D3/D3a).** The default does no working-copy snapshot and no `@`-reparent — the dirty tree is snapshotted and `@` settles onto HEAD on the next working-copy-reading op (matches the jj CLI's colocated behaviour; guarantees no clobber). Immediately after convert, `@` is the root-based empty commit and history is reachable via bookmarks (not `@-`). If you'd want the returned handle to *already* show `@` on HEAD + uncommitted changes, that's a larger change (`LockedWorkingCopy::snapshot`, Epic 9 territory). **Default: lazy.**
3. **`export_refs` after import.** Skipped — convert adds no jj-side bookmarks git lacks, so there's nothing to export and `.git` refs stay byte-identical (strengthens AC-5). The CLI runs `export_refs` only to push back *auto-tracked* local bookmarks, which we don't configure. **Default: no `export_refs`.**
4. **Linked Git worktree (`.git` is a file pointing to `…/.git/worktrees/<name>`).** `detect_repo` classifies it `Git`, so convert would attempt `init_external_git` on it. The jj CLI explicitly **refuses** this ("Cannot create a colocated jj repo inside a Git worktree"). Replicating that check (`is_linked_git_worktree`) is extra scope; **default: let `init_external_git` surface whatever it does → wrapped as `ConvertFailed`** (never a panic). Say if you want an explicit, friendlier `NotAGitRepo`-style refusal for linked worktrees (would need a small gix probe).

## Review Findings

_Code review 2026-06-27 (bmad-code-review, ultracode multi-agent: 9 parallel review layers → dedup → per-finding adversarial verification [refute + source lenses] → synthesis; 71 agents). **36 raw → 30 canonical → 11 actionable + 18 dismissed.** Headline: **0 high-severity, 1 medium, rest low/info — ZERO production correctness or data-loss defects.** The no-data-loss invariant (rollback touches only `.jj/`; `.git/` never written destructively; no working-copy I/O) was independently re-verified clean, and an independent fast-gate run (`cargo fmt` / `clippy -D warnings` / `cargo test -p zanshin-jj -p zanshin-ffi`) came back green._

- [x] [Review][Decision] `# Errors` doc + success-path reopen `Backend` leak — **RESOLVED: Option A** (keep house style, no code change; Ralph 2026-06-27). D8's explicit "optionally map" choice [convert.rs:26-31, :40, success-path `Repo::open`] — `convert_colocated`'s `# Errors` lists only AlreadyJjRepo/NotAGitRepo/ConvertFailed, but `make_settings()?` (`:40`) and the success-path `Repo::open` can each return `RepoError::Backend`; a reopen failure also leaves `.jj/` on disk despite returning `Err`. Dev Note D8 explicitly left the disposition to Ralph. **Option A (recommended, keep house style):** no code change — `Repo::init`/`Repo::clone` also omit the `make_settings→Backend` leak and D8 accepts the reopen `Backend`. **Option B (closed taxonomy):** wrap the success arm so a reopen failure folds into `ConvertFailed` and rolls back the leftover `.jj/`.
- [x] [Review][Defer] Mutation-sensitive rollback test for the post-init failure window — NOT deterministically constructible (was medium/patch) [tests/convert.rs; convert.rs:45] — the empty-`.git` test is self-cleaned by jj-lib's `init_with_factories` `inspect_err` (workspace.rs:339) before `convert.rs:45` runs, so it can't prove the production rollback line. **Empirical outcome (2026-06-27):** three principled, source-grounded failure injections AFTER a successful `init_external_git` (ref → missing object; corrupt loose object; ref → tree object) ALL leave convert returning `Ok` — jj-lib's import degrades gracefully (gix skips broken refs during listing; `import_head` no-ops on an unreadable HEAD). The rollback line is correct but guards a rare I/O failure (e.g. disk error during `tx.commit`) that needs a fault-injection seam to trigger; a chmod/permission-based test would be flaky/platform-fragile (project-banned). Reclassified patch→defer; see deferred-work.md. The detached-HEAD (AC-2) and AC-7 detect-error tests from this review WERE added and pass.
- [x] [Review][Patch] Add a detached-HEAD reachability test [tests/convert.rs] — the happy path asserts reachability only via the `main` bookmark; the `import_head` object-import arm (the detached-HEAD path that AC-2/D3a explicitly claim) is unexercised — a regression dropping `add_head` would still pass. Add a `git checkout --detach` (+ delete the branch) case asserting the HEAD commit is reachable WITHOUT `list_bookmarks`.
- [x] [Review][Patch] Add the AC-7 detect-error test [convert.rs:37; tests/convert.rs] — the `detect_repo` I/O-error → `ConvertFailed` arm (`:37`) is never reached by any test (the "2.11 ENOTDIR trick": convert a path *under a regular file*). Closes the enumerated AC-7 arm and raises `convert.rs` toward 100%.
- [x] [Review][Patch] Scope the "VIEW-ONLY, no disk writes" comment [convert.rs:~65] — `tx.commit` does persist the op/view to `.jj/`; reword to "no working-copy writes (no check_out/snapshot); `tx.commit` persists the op/view to `.jj/`" so a future reader doesn't optimize away the load-bearing commit.
- [x] [Review][Patch] Update the `RepoError` enum doc header [repo.rs:16] — it still reads "Errors returned by `Repo::open`, `Repo::init`, and `Repo::clone`."; add `crate::convert_colocated` as a fourth producer.
- [x] [Review][Defer] Best-effort rollback can leave a partial `.jj/` on a failed `remove_dir_all`, which `detect_repo` then reads as `AlreadyJjRepo` (blocks retry); doc over-states *unconditional* rollback [convert.rs:45] — deferred, mirrors the repo-wide `Repo::clone` best-effort convention; no data loss (`.git/` untouched). See deferred-work.md.
- [x] [Review][Defer] Post-import failure leaves additive `refs/jj/keep/*` markers in `.git/` (rollback removes only `.jj/`) [convert.rs:45] — deferred, benign, namespace-isolated, self-heals on next jj op. See deferred-work.md.
- [x] [Review][Defer] Linked git worktree (`.git` is a file) is classified `Git` and convert attempts it; jj CLI refuses [detect.rs:67 → convert.rs] — deferred, OQ4-approved default (→ `ConvertFailed`, no panic); optional characterization test only. See deferred-work.md.
- [x] [Review][Defer] `.git/ untouched` test scopes refs to `refs/heads`+`refs/tags` (symbolic-HEAD repoint / remotes / notes / packed-refs would slip past) [tests/convert.rs] — deferred, non-destructive by construction (read-only `gix::open`, no `export_refs`); optional test hardening. See deferred-work.md.
- [x] [Review][Defer] `remote_auto_track_bookmarks` hardcoded empty ignores user auto-track config (CLI loads it) [convert.rs import_options] — deferred, OQ3-documented default; imported remote bookmarks stay untracked-but-pinned (no data loss). See deferred-work.md.
