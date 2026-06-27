---
baseline_commit: 19638d9738cf15cdd843d04c0f5038d799678798
---

# Story 2.13: Implement external-git-import conversion (`convert_import`) — fast-follow

Status: review

<!-- Note: Validation is optional. Run validate-create-story for quality check before dev-story. -->

## Story

As a Rust caller acting on the user's choice of a **jj-native** (not colocated) workflow,
I want `zanshin-jj` to create a jj-native workspace at a user-chosen destination directory, backed by an existing Git repository's object store,
so that a user who prefers "jj leads, my Git repo stays the way it was" gets a separate jj workspace whose history is imported from the existing repo (FR-JJ-18b).

## Scope decision (read first — this reshapes the epic AC)

> **Locked with Ralph, 2026-06-27.** The epic prose (written 2026-06-20) described `convert_import(path: &Path)` as an *in-place, single-path* conversion symmetric to Story 2.12. **That shape is impossible in jj 0.42** and is reconciled to a **two-path** signature. Evidence + decision:
>
> Reading `cli/src/commands/git/init.rs::do_init` @ `v0.42.0` (`../jj`):
> - `jj git init --colocate` over an **existing** `.git` → `GitInitMode::External(workspace_root/.git)` → **colocated** = Story 2.12 (`convert_colocated`).
> - `jj git init --no-colocate` over an **existing** `.git` → **hard error** (*"Did not create a jj repo because there is an existing Git repo… run `jj git init --colocate` instead"*).
> - The jj-native external import is `jj git init --git-repo=<repo> <destination>`; `is_colocated_git_workspace` (`cli/src/git_util.rs:63–78`) is non-colocated **only when the destination workspace dir ≠ the git repo's working dir**.
>
> ⇒ jj 0.42 has **no in-place jj-native conversion**; a genuinely jj-native result **requires a separate destination directory**.
>
> **Ralph's decision:** mirror the jj CLI exactly; the destination is an explicit, user-selected parameter (no baked-in defaults — per the canonical "replicate jj CLI behavior" + "pass CLI params through / never decide for the user" rules in `project-context.md` § zanshin-jj):
>
> ```rust
> pub fn convert_import(git_repo_path: &Path, workspace_path: &Path) -> Result<Repo, RepoError>
> ```
>
> `git_repo_path` = the existing Git repo the user picked; `workspace_path` = the new dir the user selects for the jj-native workspace.

> **⚠️ This is NOT a clone — it shares the source's object store.** `init_external_git` points the new workspace's Git backend at the source repo (`.jj/repo/store/git_target` → the source's `.git`). jj's commits land in the **source's shared object store**; the new workspace **depends on the source repo's continued existence** (deleting/moving the source corrupts it). This is exactly how `jj git init --git-repo` behaves — and it is the key difference from `Repo::clone` (which copies objects into an internal store). The UI must convey "the new jj workspace shares storage with the original repo; don't move/delete the original." (See Decision D6/D11.)

## Acceptance Criteria

> ACs reconciled to the two-path import design (Decision D1/D2). Epic line refs point at the original prose so the reconciliation is auditable; epics.md Story 2.13 and prd.md FR-JJ-18b were reconciled to this shape in the same change.

### AC-1 — Module surface extended (FR-JJ-18b) [epics.md Story 2.13]

`crates/zanshin-jj/src/convert.rs` is **extended** (2.12 created it) to define `pub fn convert_import(git_repo_path: &Path, workspace_path: &Path) -> Result<Repo, RepoError>`, re-exported from `lib.rs` as `pub use convert::convert_import;`. It reuses the existing `RepoError` variants (`AlreadyJjRepo`, `NotAGitRepo`, `ConvertFailed`) — **no new variant, no new type, no new error code**. The implementation mirrors `do_init`'s `GitInitMode::External` (non-colocated) branch (exact jj-lib calls absorbed per FR-JJ-16).

### AC-2 — Happy path: a Git source → a jj-native workspace at the destination

**Given** `convert_import(git_repo_path, workspace_path)` where `git_repo_path` is a Git repo (normal **or bare**, AC-4) and `workspace_path` is a fresh directory (≠ the git repo dir)
**Then** it produces a **non-colocated** jj-native workspace at `workspace_path` backed by the source repo's object store
**And** the destination has a `.jj/` and **no `.git/`** (jj leads; not colocated)
**And** the imported Git `HEAD` commit is reachable in the resulting jj repo (`@` is a fresh working-copy commit on top of the imported HEAD)
**And** the destination working copy is materialised on disk (HEAD's tree is present in `workspace_path`)
**And** it returns a `Repo` handle; `detect_repo(workspace_path) == RepoKind::Jj` afterwards and `Repo::open(workspace_path)` succeeds.

### AC-3 — Precondition: destination (or source) already a jj repo → `AlreadyJjRepo`

**Given** `convert_import(git_repo_path, workspace_path)`
**When** `detect_repo(workspace_path) == Jj` (destination already a jj workspace) **or** `detect_repo(git_repo_path) == Jj` (source itself already a jj workspace — e.g. a `dest == source` colocated request, not this mode)
**Then** it returns `Err(RepoError::AlreadyJjRepo { path })` — `path` is the offending path — and changes nothing on disk.

### AC-4 — Precondition: source must be a Git repo; **bare is supported** (CLI parity)

**Given** `convert_import(git_repo_path, workspace_path)`
**When** `git_repo_path` is a Git repo
**Then** it proceeds — for **both** a normal repo (`git_repo_path/.git` present) **and a bare repo** (`git_repo_path` is itself the git dir: `HEAD` + `objects/` + `refs/`). Bare support **replicates the jj CLI** (`jj git init --git-repo` accepts a bare repo) and is the one precondition that **differs from Story 2.12** (which rejects bare → `NotAGitRepo`, D7). The two convert verbs therefore **cannot share a gate** (Decision D3).
**And** when `git_repo_path` is neither a normal nor a bare Git repo (nor exists) → `Err(RepoError::NotAGitRepo { path: git_repo_path })`.

### AC-5 — Additive; the **source** repo is never destructively modified

**Given** the conversion completes (or fails)
**Then** the source repo's **user-visible refs (`refs/heads`, `refs/tags`) and `HEAD` are unchanged** (asserted before/after) — non-colocated ⇒ jj does **not** export refs back to the source
**And** removing the created `workspace_path` (or its `.jj/`) leaves the source a working, standalone Git repo
**And** on failure any partially-created destination is rolled back (Decision D7).

> **Note (documented, not a violation):** jj writes its own commit objects (the new `@`) and `refs/jj/keep/*` GC-keep markers into the **shared** object store (= the source's `.git`). These are **additive** — the source's branches/tags/`HEAD` are byte-identical. AC-5 asserts the *user-visible ref namespace*, exactly as 2.12's `convert_git_repo_does_not_modify_git_dir`.

### AC-6 — No data loss; the **source working copy** is never touched

The destination is materialised from `HEAD` (objects read from the shared store), so a normal source's working tree — clean **or** dirty — is never written by `convert_import` (it only opens the source's `.git`). A bare source has no working tree (N/A).

### AC-7 — jj-lib failures wrapped, never panic

Any jj-lib failure during init/import/materialise (or a `detect_repo` I/O error in the precondition check) is wrapped as `RepoError::ConvertFailed { reason }` (flattened `Display`; no `jj_lib` type leaks); the call never panics. `NotAGitRepo` is returned by the **pre-check** for a non-git source — `ConvertFailed` is reserved for genuine jj-lib failures (Decision D3 + D8).

### AC-8 — Error-code registry reconciled (no new codes)

**No new `error.code`.** `convert_import` reuses `jj.already_jj_repo` / `jj.not_a_git_repo` / `jj.convert_failed` (Reserved since 2.12). The three existing rows' Status notes are amended to mention `convert_import` also produces them and that its FFI wrapper ships in the 0.2 fast-follow (not Story 3.4c, which is colocated-only). No `pub const JJ_*`, no `error.code` string here (no FFI).

### AC-9 — README/rustdoc documents the colocated-vs-import trade-off + the shared-store dependency

`crates/zanshin-jj/README.md` **and** the `convert.rs` module rustdoc document: **colocated** (`convert_colocated`, FR-JJ-18a, in-place, git+jj share the dir) vs **jj-native import** (`convert_import`, FR-JJ-18b, separate dest, **shares the source's object store — not a clone; source must remain**), plus the jj-0.42 fact that in-place existing-`.git` conversion is colocated and a jj-native result needs a separate destination — so callers/UI can describe the choice (and the source-dependency) accurately.

### AC-10 — Integration-test coverage, symmetric to the colocated tests

Tests in `crates/zanshin-jj/tests/convert.rs` cover: success + history import + working-copy materialisation (normal source); **bare source** → `Ok` (jj-native); source `.git` refs/HEAD untouched; destination-already-jj → `AlreadyJjRepo`; source-already-jj → `AlreadyJjRepo`; `dest == source` → `AlreadyJjRepo` **or** a colocated result (Decision D5 — see the recipe for which); non-git source (empty dir / nonexistent) → `NotAGitRepo`; unborn-branch source (normal **and** bare) → `Ok` (empty history, no panic); rollback on a post-`create_dir` failure; `detect_repo` I/O error → `ConvertFailed`. (See Test recipe.)

### AC-11 — Quality gate green incl. coverage ratchet

`cargo make test` passes (clippy pedantic `-D warnings`, rustfmt, `dart analyze`/`format`, `cargo deny`, **coverage ratchet**). `convert.rs` per-file coverage does not drop; the auto-raised `coverage-baseline.txt` is committed with the code.

## Tasks / Subtasks

- [x] **Task 1 — Extend `convert.rs` with `convert_import` + helpers (AC-1..AC-7)**
  - [x] `pub fn convert_import(git_repo_path, workspace_path)` with the **OR-gate** (Decision D3): source must be normal-or-bare git (else `NotAGitRepo`), source/dest not already jj (`AlreadyJjRepo`), detect I/O error → `ConvertFailed`; create-dir + created-dir-aware rollback (Decision D7).
  - [x] Private `import_into(settings, git_repo_path, workspace_path) -> Result<(), RepoError>` porting `do_init`'s `GitInitMode::External` non-colocated branch (Decision D4): `create_dir_all(dest)` → `init_external_git(dest, resolved)` → `import_refs` → `import_head` → (if `!is_colocated` **and** `git_head().as_normal()` is `Some`) `check_out(git_head)` + `rebase_descendants` → `tx.commit` → `workspace.check_out` materialise.
  - [x] Private helpers: `resolve_git_repo_path` (mirror `do_init`'s `.git`-append/bare-pop), `is_bare_git_dir` (stat-only HEAD+objects+refs), `is_colocated` (port `git_util::is_colocated_git_workspace`, Decision D5).
  - [x] Reopen via `Repo::open(workspace_path)` (Decision D8); never construct `Repo { … }`.
- [x] **Task 2 — Re-export + module doc (AC-1, AC-9)** — `lib.rs`: `pub use convert::convert_import;`; extend `convert.rs` `//!` to cover both modes + the shared-store dependency.
- [x] **Task 3 — README "Conversion modes" section (AC-9)** — colocated vs jj-native import; in-place-is-colocated note; destination-dir requirement; **shares-source-object-store / not-a-clone** warning.
- [x] **Task 4 — Error-code registry reconcile (AC-8)** — amend the 3 existing `jj.*` row notes; add **no** new rows.
- [x] **Task 5 — Surface-lock (AC-1)** — bind a `convert_import` fn-pointer in `tests/api_stability.rs`; **do not** bump "26 types".
- [x] **Task 6 — Integration tests (AC-10)** — extend `tests/convert.rs` (helpers already present from 2.12; add a `git_bare_clone` helper).
- [x] **Task 7 — Gate green + coverage (AC-11)** — `cargo make test`; commit the auto-raised baseline.

## Dev Notes

### Decision D1 — Scope: mirror `jj git init --git-repo=<repo> <dest>` (external-git-import branch). Two paths.

See **Scope decision**. Authoritative reference: `do_init`'s `GitInitMode::External` arm @ `v0.42.0`, run non-colocated (separate destination). Genuinely distinct from 2.12. Do **not** attempt an in-place single-path jj-native conversion — jj refuses it.

### Decision D2 — Signature: `convert_import(git_repo_path, workspace_path)`; destination is user-selected.

Both paths are caller-supplied; the destination is **user-selected** (no baked default — canonical rule). Reconciles the epic's single-`path` AC (same "epic prose predates discovery" pattern as 2.12 D6).

### Decision D3 — Gate: source = normal **OR bare** git (NOT `detect_repo`-only). [THE correction]

`detect_repo` returns `Neither` for a **bare** repo (it checks `.jj/` then a `.git` *child*; a bare repo has neither). So gating the source on `detect_repo == Git` (as `convert_colocated` does) would **reject every bare source** — the opposite of CLI parity. **Do not extend `detect_repo`** (a bare dir genuinely is `Neither` for the file-picker; the existing `convert_bare_repo_returns_not_a_git_repo` test for `convert_colocated` must keep passing). Gate locally:

```rust
// Precondition 1: source is a Git repo (normal OR bare) and not already jj.
match detect_repo(git_repo_path) {
    Ok(RepoKind::Jj) => return Err(RepoError::AlreadyJjRepo { path: git_repo_path.to_owned() }), // AC-3
    Ok(RepoKind::Git) => {}                                                                       // normal source
    Ok(RepoKind::Neither | RepoKind::PathNotFound) => {
        if !is_bare_git_dir(git_repo_path) {                                                      // AC-4
            return Err(RepoError::NotAGitRepo { path: git_repo_path.to_owned() });
        }
        // bare source — SUPPORTED (CLI parity)
    }
    Err(e) => return Err(RepoError::ConvertFailed { reason: e.to_string() }),                     // AC-7
}
// Precondition 2: destination not already a jj workspace.
match detect_repo(workspace_path) {
    Ok(RepoKind::Jj) => return Err(RepoError::AlreadyJjRepo { path: workspace_path.to_owned() }), // AC-3
    Ok(_) => {}
    Err(e) => return Err(RepoError::ConvertFailed { reason: e.to_string() }),                     // AC-7
}
```

`is_bare_git_dir` is stat-only — `path.join("HEAD").is_file() && path.join("objects").is_dir() && path.join("refs").is_dir()` — git's own gitdir heuristic; false positives need a hand-crafted dir mimicking all three. (`detect_repo` is fallible per 2.11 Design B; handle the `Err` arm.)

### Decision D4 — Import sequence: port `do_init` External (non-colocated) branch; single transaction.

Order, all `async` → `pollster::block_on(...)`:
1. `create_dir_all(workspace_path)` (mirror the CLI's `create_or_reuse_dir`).
2. `resolve_git_repo_path(git_repo_path)` → backing `.git` (normal: `<src>/.git`; bare: `<src>` itself).
3. `Workspace::init_external_git(settings, workspace_path, &resolved)` — **bind `(mut workspace, repo)`; you MUST keep `workspace`** to materialise later (unlike `convert_colocated`, which drops it). `gix::open`s the source (non-destructive).
4. `import_refs(tx.repo_mut(), &GitImportOptions { abandon_unreachable_commits: false, record_synthetic_predecessors: false, remote_auto_track_bookmarks: HashMap::new() })` — **no `export_refs`** (non-colocated ⇒ AC-5).
5. `import_head(tx.repo_mut())` — imports HEAD commit + sets `git_head` (covers detached HEAD; no-op on unborn).
6. **If `!is_colocated(...)` AND `tx.repo().view().git_head().as_normal()` is `Some(id)`:** `store().get_commit(&id)` → `mut_repo.check_out(workspace_name, &commit)` → `mut_repo.rebase_descendants()` → keep the `wc_commit`. (Guard on `as_normal()` is mandatory — an unborn HEAD yields `None`; then skip check_out, `wc_commit = None`.)
7. `tx.commit("import git repo")`.
8. **Materialise:** if `wc_commit` is `Some`, `workspace.check_out(new_repo.op_id().clone(), None, &wc_commit)` — writes HEAD's tree into the fresh dest (safe: empty dir). Steps 6+8 mirror `repo.rs::clone_into` (lines ~346–371).

> **Single-tx, documented:** the CLI uses **two** ops ("import git refs", then "import git head"). We fold into one op `"import git repo"` — consistent with `convert_colocated` and acceptable for a fresh import. This preserves the op-log **effect** (the conversion is one visible, reversible op — NFR-R-2); matching the CLI's exact op-count/messages is cosmetic (same category as the skipped `trunk()` alias, D10). State this in the rustdoc; don't imply CLI-identical op-log.

### Decision D5 — Port `is_colocated_git_workspace`; guards the working-copy block (robustness + `dest == source`).

The non-colocated working-copy block (step 6/8) runs only when not colocated. For the intended use (separate dest) it's always non-colocated, but a caller could pass `workspace_path == git_repo_path` (→ colocated, like `jj git init --git-repo=.`). Port the tiny helper (`cli/src/git_util.rs:63–78`); `git_workdir()` is `None` for a bare backing repo (→ not colocated). The simple `git_workdir == workspace_root` check (no `dunce`) suffices for the test matrix — see OQ1.

```rust
fn is_colocated(repo: &impl jj_lib::repo::Repo, workspace_root: &Path) -> bool {
    let Ok(b) = jj_lib::git::get_git_backend(repo.store()) else { return false; };
    let Some(workdir) = b.git_workdir() else { return false; }; // bare → not colocated
    workdir == workspace_root
}
```

> **`dest == source` semantics:** that's a colocated request, not this mode. Two acceptable handlings — pick one and lock it in a test: (a) **pre-reject** it (`git_repo_path == workspace_path` after canonicalize → `AlreadyJjRepo`/explicit error), or (b) **let it through** to a colocated result (`is_colocated` true → step 6/8 skipped → a colocated workspace at the dir). (b) is the more CLI-faithful (jj produces colocated for `--git-repo=.`); (a) is clearer for the dialog. **Default: (b)** + a `convert_import_into_same_dir_is_colocated` test. Flagged OQ4.

### Decision D6 — Shared object store: source untouched, but the workspace DEPENDS on the source.

`init_external_git` writes `git_target` → the source's `.git`; the new workspace's store **is** the source's object store. jj **adds** objects (additive; source user-visible refs/HEAD unchanged — AC-5), but the dest workspace **requires the source to keep existing** — deleting/moving the source corrupts it. This is inherent to external-git (and to `jj git init --git-repo`); it is the key way `convert_import` differs from `Repo::clone` (which copies into an internal store). Document loudly (AC-9 + rustdoc + D11).

### Decision D7 — Rollback: created-dir aware, source never touched.

Compute `created_dir = !workspace_path.exists()` **before** `import_into`. On `Err`: `created_dir` → `remove_dir_all(workspace_path)`; else → `remove_dir_all(workspace_path.join(".jj"))`. **Never** touch `git_repo_path`. (`import_into` `create_dir_all`s the dest first.)

### Decision D8 — Returned `Repo` via reopen; surface-lock; error codes reused.

After success `return Repo::open(workspace_path);` (private fields). In `api_stability.rs` add next to `convert_colocated` (L90):
```rust
_ = zanshin_jj::convert_import
    as fn(&std::path::Path, &std::path::Path) -> Result<zanshin_jj::Repo, zanshin_jj::RepoError>;
```
No new type → "26 types" header unchanged. No new error code (reuses 2.12's three; amend their registry notes only).

### Decision D9 — Bare source SUPPORTED (flips 2.12's D7), per the "replicate jj CLI behavior" rule.

`jj git init --git-repo` accepts a bare repo (its `.git`-pop fallback). The canonical rule (`project-context.md` § zanshin-jj: "CLI behavior is the semantic reference") makes bare support the correct stance for `convert_import` — even though `convert_colocated` (2.12 D7) rejects bare (`detect_repo → Neither → NotAGitRepo`). The two verbs legitimately disagree; hence the separate gate (D3). Verified against jj-lib 0.42: `init_external_git` → `gix::open` on a bare dir works; `git_workdir() == None` → non-colocated → import_head + check_out + materialise run, reading objects from the shared store into the empty dest.

### Decision D10 — `trunk()` alias, gitignore, `ui.status` chatter: out of scope (cosmetic).

`do_init`'s External branch also `maybe_add_gitignore` + `maybe_set_repository_level_trunk_alias` + `print_trackable_remote_bookmarks`. These are CLI-UX/convenience, not repo-state behavior — out of scope for the bridge (the canonical rule replicates *behavior*, not terminal UX). Don't let "CLI parity" creep into porting them. Note the difference in rustdoc.

### Decision D11 — `convert_import` is NOT a clone. (Restates D6 for emphasis — reviewers check this.)

`Repo::clone` (remote URL) copies objects into an internal store and is self-contained. `convert_import` (local existing repo) **shares** the source's object store. Don't model it on clone's *storage*; model the **transaction/check_out/materialise mechanics** on `clone_into`, but the backing store is external. The rustdoc and README must not call it a "clone."

### Confirmed jj-lib 0.42 API (cross-verified: vendored `jj-lib-0.42.0` + jj CLI `do_init`/`git_util` @ `v0.42.0`)

`jj_lib` is fine **inside** this crate (FR-JJ-16); keep it out of public signatures. All `async` via `pollster::block_on`.

| Call | Signature (0.42) | Notes |
|------|------------------|-------|
| `Workspace::init_external_git` | `(&UserSettings, &Path /*ws_root*/, &Path /*git_repo*/) -> Result<(Workspace, Arc<ReadonlyRepo>), WorkspaceInitError>` | `workspace.rs:255`. ws_root=`workspace_path`, git_repo=resolved source. Non-colocated (ws_root ≠ git workdir). `gix::open` handles bare. |
| `git::import_refs` | `(&mut MutableRepo, &GitImportOptions) -> Result<GitImportStats, GitImportError>` | `git.rs:563`. `abandon_unreachable_commits:false`, `record_synthetic_predecessors:false`. |
| `git::import_head` | `(&mut MutableRepo) -> Result<(), GitImportError>` | `git.rs:1113`. Sets `git_head`; reads `git_repo.head_id()` (None for unborn). |
| `View::git_head` | `(&self) -> &RefTarget` | `view.rs:100`. `.as_normal()` → `Option<&CommitId>`; **guard step 6 on `Some`**. |
| `MutableRepo::check_out` | `async (WorkspaceNameBuf, &Commit) -> BackendResult<Commit>` | `repo.rs:1549`. `@` = child of the given commit. |
| `MutableRepo::rebase_descendants` | `async (&mut self) -> BackendResult<usize>` | `repo.rs:1461`. No-op for a fresh repo; keep for symmetry with `clone_into`. |
| `Workspace::check_out` | `async (OperationId, Option<&CommitId>, &Commit) -> …` | `workspace.rs:452`. Materialises into the (empty) dest. |
| `Workspace::workspace_name` | `(&self) -> &WorkspaceName` | `workspace.rs:421`. `.to_owned()` for check_out. |
| `git::get_git_backend` / `GitBackend::git_workdir` | `(&Store) -> Result<&GitBackend, _>` / `(&self) -> Option<&Path>` | `git.rs:418` / `git_backend.rs:352`. For `is_colocated` (D5). |

### Copy-adaptable skeleton (append to `convert.rs`)

> Structure cross-verified against `do_init` (non-colocated External) + `clone_into` + an adversarial jj-lib-0.42 read. Let the compiler + `clone_into` guide exact borrows (`tx.repo()` / `tx.repo_mut()` interleave in step 6 mirrors `clone_into`). `jj_lib::repo::Repo` (trait) must be in scope for `.store()`/`.view()` on `tx.repo()` (`repo.rs` imports it as `Repo as _`). Clippy pedantic `-D warnings`; if `too_many_lines`, split `import_into`.

```rust
use std::path::PathBuf; // add to convert.rs imports (HashMap, Path already present)

/// Creates a **jj-native** (non-colocated) workspace at `workspace_path` from the
/// existing Git repository at `git_repo_path` (FR-JJ-18b).
///
/// Mirrors `jj git init --git-repo=<git_repo_path> <workspace_path>`: jj leads, the
/// original repo stays a working Git repo, and the two **share the Git object store**.
/// This is NOT a clone — the new workspace depends on `git_repo_path` continuing to
/// exist; deleting or moving the source corrupts it. Unlike [`convert_colocated`]
/// (in-place, colocated), the jj workspace lives in a **separate** directory and ends
/// up with a `.jj/` and no `.git/`. A **bare** source repo is supported.
///
/// The source's user-visible refs (`refs/heads`, `refs/tags`) and `HEAD` are never
/// modified; jj only adds its own objects to the shared store.
///
/// # Errors
/// - [`RepoError::AlreadyJjRepo`] — `workspace_path` (or `git_repo_path`) is already a jj workspace.
/// - [`RepoError::NotAGitRepo`] — `git_repo_path` is not a Git repo (normal or bare) / does not exist.
/// - [`RepoError::ConvertFailed`] — a jj-lib failure (or a `detect_repo` I/O error); the
///   partially-created destination is rolled back.
pub fn convert_import(git_repo_path: &Path, workspace_path: &Path) -> Result<Repo, RepoError> {
    match detect_repo(git_repo_path) {
        Ok(RepoKind::Jj) => return Err(RepoError::AlreadyJjRepo { path: git_repo_path.to_owned() }),
        Ok(RepoKind::Git) => {}
        Ok(RepoKind::Neither | RepoKind::PathNotFound) => {
            if !is_bare_git_dir(git_repo_path) {
                return Err(RepoError::NotAGitRepo { path: git_repo_path.to_owned() });
            }
        }
        Err(e) => return Err(RepoError::ConvertFailed { reason: e.to_string() }),
    }
    match detect_repo(workspace_path) {
        Ok(RepoKind::Jj) => return Err(RepoError::AlreadyJjRepo { path: workspace_path.to_owned() }),
        Ok(_) => {}
        Err(e) => return Err(RepoError::ConvertFailed { reason: e.to_string() }),
    }

    let settings = make_settings()?;
    let created_dir = !workspace_path.exists();
    match import_into(&settings, git_repo_path, workspace_path) {
        Ok(()) => Repo::open(workspace_path),
        Err(e) => {
            if created_dir {
                let _ = std::fs::remove_dir_all(workspace_path);
            } else {
                let _ = std::fs::remove_dir_all(workspace_path.join(".jj"));
            }
            Err(e)
        }
    }
}

/// Stat-only: is `path` itself a (bare) git directory? Git's own gitdir heuristic.
/// `detect_repo` classifies bare as `Neither` (correct for the file-picker), so the
/// bare-source case is recognised here, locally — NOT by extending `detect_repo`.
fn is_bare_git_dir(path: &Path) -> bool {
    path.join("HEAD").is_file() && path.join("objects").is_dir() && path.join("refs").is_dir()
}

/// Resolves the backing git dir exactly as `do_init`: append `.git` unless present;
/// fall back to the path itself for a bare repo. (`Path::ends_with` is component-wise.)
fn resolve_git_repo_path(arg: &Path) -> PathBuf {
    if arg.ends_with(".git") {
        return arg.to_owned();
    }
    let dot_git = arg.join(".git");
    if dot_git.exists() { dot_git } else { arg.to_owned() }
}

/// Ports `do_init`'s `GitInitMode::External` (non-colocated) branch. On `Err`, the
/// caller rolls back the destination.
fn import_into(settings: &UserSettings, git_repo_path: &Path, workspace_path: &Path) -> Result<(), RepoError> {
    std::fs::create_dir_all(workspace_path)
        .map_err(|e| RepoError::ConvertFailed { reason: e.to_string() })?;
    let resolved = resolve_git_repo_path(git_repo_path);

    // 1. Open the existing repo as the backing store (gix::open — non-destructive).
    //    Keep `workspace`: we materialise into the dest below.
    let (mut workspace, repo) = pollster::block_on(
        jj_lib::workspace::Workspace::init_external_git(settings, workspace_path, &resolved),
    )
    .map_err(|e| RepoError::ConvertFailed { reason: e.to_string() })?;
    let workspace_name = workspace.workspace_name().to_owned();

    let import_options = GitImportOptions {
        abandon_unreachable_commits: false,
        record_synthetic_predecessors: false,
        remote_auto_track_bookmarks: HashMap::new(),
    };
    let mut tx = repo.start_transaction();
    pollster::block_on(import_refs(tx.repo_mut(), &import_options))
        .map_err(|e| RepoError::ConvertFailed { reason: e.to_string() })?;
    pollster::block_on(import_head(tx.repo_mut()))
        .map_err(|e| RepoError::ConvertFailed { reason: e.to_string() })?;

    // jj-native working copy: @ on top of imported HEAD. Skipped if colocated
    // (dest == source) OR if HEAD is unborn (git_head None).
    let new_wc_commit = if is_colocated(tx.repo(), workspace_path) {
        None
    } else if let Some(git_head_id) = tx.repo().view().git_head().as_normal().cloned() {
        let mut_repo = tx.repo_mut();
        let commit = mut_repo
            .store()
            .get_commit(&git_head_id)
            .map_err(|e| RepoError::ConvertFailed { reason: e.to_string() })?;
        let wc = pollster::block_on(mut_repo.check_out(workspace_name.clone(), &commit))
            .map_err(|e| RepoError::ConvertFailed { reason: e.to_string() })?;
        pollster::block_on(mut_repo.rebase_descendants())
            .map_err(|e| RepoError::ConvertFailed { reason: e.to_string() })?;
        Some(wc)
    } else {
        None
    };

    let new_repo = pollster::block_on(tx.commit("import git repo"))
        .map_err(|e| RepoError::ConvertFailed { reason: e.to_string() })?;

    if let Some(wc_commit) = &new_wc_commit {
        pollster::block_on(workspace.check_out(new_repo.op_id().clone(), None, wc_commit))
            .map_err(|e| RepoError::ConvertFailed { reason: e.to_string() })?;
    }
    Ok(())
}

/// Port of `cli/src/git_util.rs::is_colocated_git_workspace` (@ v0.42.0).
fn is_colocated(repo: &impl jj_lib::repo::Repo, workspace_root: &Path) -> bool {
    let Ok(git_backend) = jj_lib::git::get_git_backend(repo.store()) else {
        return false;
    };
    let Some(git_workdir) = git_backend.git_workdir() else {
        return false; // bare backing repo
    };
    git_workdir == workspace_root
}
```

### Test recipe — extend `tests/convert.rs` (2.12 helpers already present)

Reuse `pin_env()`/`ENV_GUARD`, `git()`, `git_stdout()`, `init_git_repo_with_commit()`. Add a bare-source helper: build a normal repo with a commit in a temp dir, then `git(&["clone", "--bare", <normal>, <bare>], parent)` → a populated bare repo (shelling `git` in tests is allowed). Naming = scenario-describing.

| # | Test | Setup → assertion |
|---|------|-------------------|
| 1 | `convert_import_git_repo_with_commit_returns_jj_native` | normal source + fresh `dest` → `Ok`; `detect_repo(dest)==Jj`; `dest/.jj` is_dir; **`!dest/.git` exists**; `dest/README.md == "hello"`; `Repo::open(dest)` ok; `resolve_revset(&repo,"git_head()")` → 1 commit. |
| 2 | `convert_import_does_not_modify_source_git` | capture source `rev-parse HEAD` + `for-each-ref refs/heads refs/tags` before/after → equal (AC-5; refs only). |
| 3 | `convert_import_bare_source_returns_jj_native` | `git clone --bare` a 1-commit repo → bare source; fresh `dest` → `Ok`; `detect_repo(dest)==Jj`; HEAD commit reachable; file materialised in `dest`. (Bare = the AC-4/D9 case.) |
| 4 | `convert_import_destination_already_jj_returns_already_jj_repo` | dest = extracted `tiny-3-commits`; normal source → `Err(AlreadyJjRepo)`, path==dest. |
| 5 | `convert_import_source_already_jj_returns_already_jj_repo` | source = extracted `tiny-3-commits`; fresh dest → `Err(AlreadyJjRepo)`, path==source. |
| 6 | `convert_import_empty_source_returns_not_a_git_repo` | source = empty dir (not bare) → `Err(NotAGitRepo)`. |
| 7 | `convert_import_nonexistent_source_returns_not_a_git_repo` | source = `/nonexistent/...` → `Err(NotAGitRepo)`. |
| 8 | `convert_import_unborn_branch_source_succeeds` | source = `git init` + config, no commit; fresh dest → `Ok`; `detect_repo(dest)==Jj`; no panic (git_head None → no check_out). |
| 9 | `convert_import_failure_rolls_back` | source = dir with empty `.git` dir (`detect_repo==Git`, `init_external_git` fails after dest created); fresh `dest` → `Err(ConvertFailed)` **and** `!dest.exists()` (created_dir ⇒ whole dest removed). |
| 10 | `convert_import_detect_io_error_returns_convert_failed` | source = `<file>/child` (path under a regular file → `detect_repo` `Err`) → `Err(ConvertFailed)`. |
| 11 | `convert_import_then_remove_dest_restores_source` | after test-1, `remove_dir_all(dest)`; source still `detect_repo==Git` + `git rev-parse HEAD` works. |
| 12 | `convert_import_into_same_dir_is_colocated` | normal source; `convert_import(src, src)` (D5 default (b)) → `Ok`; `src/.jj` is_dir **and** `src/.git` exists (is_colocated true ⇒ check_out skipped). *(If you pick D5 option (a), invert this to assert `AlreadyJjRepo`.)* |

> **`.git/` untouched (test 2):** compare only `refs/heads`+`refs/tags`+`HEAD` (objects/`refs/jj/keep/*` are additive — same helper/rationale as 2.12). **Do NOT** port 2.12's dirty-tree test (the source workdir is never touched here; for bare there is no workdir).

### Coverage note

`convert.rs` is existing (~100%). New arms + tests: the four source-`detect` arms + `is_bare_git_dir` true/false (tests 1/3/4/5/6/9/10), `import_into` success + materialise (1/3), the unborn `git_head==None` skip (8), the `is_colocated` true branch (12), the rollback/`ConvertFailed` arm (9; **same caveat as 2.12** — jj-lib's `init_with_factories` `inspect_err` may pre-clean `.jj`, so test 9 pins the `ConvertFailed` mapping + created-dir removal). `resolve_git_repo_path`'s bare branch is hit by test 3; its `ends_with(".git")` early-return is minor — add a unit test rather than an `exclude` if coverage flags it. **Never** `exclude_prefix` to dodge an arm (CLAUDE.md).

### Files this story touches

| File | Action | What |
|------|--------|------|
| `crates/zanshin-jj/src/convert.rs` | UPDATE | `+ convert_import` + `import_into`/`resolve_git_repo_path`/`is_bare_git_dir`/`is_colocated`; extend `//!` (both modes + shared-store-not-a-clone) |
| `crates/zanshin-jj/src/lib.rs` | UPDATE | `pub use convert::convert_import;` |
| `crates/zanshin-jj/tests/convert.rs` | UPDATE | +12 tests (+ a `git clone --bare` helper) |
| `crates/zanshin-jj/tests/api_stability.rs` | UPDATE | bind `convert_import` fn-ptr (no type-count bump) |
| `crates/zanshin-jj/README.md` | UPDATE | "Conversion modes" (colocated vs import; **shared store / not a clone**) |
| `docs/rust-error-codes.md` | UPDATE | amend 3 existing `jj.*` row notes (no new rows) |
| `coverage-baseline.txt` | UPDATE (auto) | commit the auto-raised baseline |

**No** `Cargo.toml` change (`pollster`/`gix`/`jj_lib`/`tempfile`/`test-helpers` present; `is_colocated` default avoids a `dunce` dep — OQ1). **No** codegen/`.fbs`/`envelope.rs`/FFI/Dart. (`convert_import`'s FFI wrapper is a 0.2 fast-follow — not 3.4c.)

### Hard rules in scope (project-context.md — reject-at-review)

- **Replicate jj CLI behavior, not terminal UX** (new canonical rule, § zanshin-jj) — `convert_import` mirrors `do_init`'s External branch; trunk-alias/gitignore/`ui.status` skipped (D10).
- **No shelling/parsing jj-or-git in production** (NFR-R-1, FR-JJ-16); tests may shell `git`.
- **No `extern "C"` outside `zanshin-ffi`**; **no `unwrap`/`expect`/`panic!`** on the lib path; **no `jj_lib`/`gix` type in public positions** (signature is `(&Path,&Path)->Result<Repo,RepoError>`).
- **No data loss**: source never written; rollback removes only the destination; the import is one visible op (NFR-R-2).
- **`#![deny(missing_docs)]`** — `convert_import` needs `///`; private helpers don't. **SPDX present; rustfmt 100; clippy pedantic.**
- **Coverage ratchet: add tests, never lower the baseline / never `exclude_prefix`.**

### Previous-story intelligence (2.12 convert + 2.3 clone)

- `convert.rs` exists (2.12, committed `d01d507`); **extend**, keep `convert_colocated` untouched. Reuse `make_settings` (pub(crate)), the rollback idiom.
- **`clone_into` is the materialise template** (`mut_repo.check_out` borrow dance, `rebase_descendants`, `tx.commit`, `workspace.check_out`, reload) — BUT clone copies into an internal store; `convert_import` shares the source store (D11). Model the *mechanics*, not the storage.
- **The gate trap (D3):** `convert_colocated` reuses `detect_repo` and rejects bare on purpose. `convert_import` must NOT — bare is supported. Do not unify their gate.
- **Surface-lock** (2.10): bind `convert_import`; **don't** bump "26 types". **Doc accuracy** reviewed vs ground truth (2.6/2.9) — say "shares the object store / not a clone", "source user-visible refs unchanged", not "`.git` never written".
- **Scope discipline** — no FFI here (0.2 wrapper), don't touch 3.4c.

### Project Structure Notes

- `convert_import` joins `convert_colocated` in `convert.rs` (module-by-noun). `pub use` mirrors `lib.rs:42`. Tests in `tests/convert.rs`.
- **UI/FFI consequence (0.2 wrapper + Ralph's Flutter work):** the dialog collects **two** user-chosen paths (source repo + destination) — no baked default (canonical rule) — and must surface the **shared-store dependency** ("the new jj workspace shares storage with the original repo; don't move/delete it"). The backend never invents the destination.

### References

- [Story 2.13 ACs](_bmad-output/planning-artifacts/epics.md) — epics.md Story 2.13 (reconciled to two-path in this change)
- [FR-JJ-18b](_bmad-output/planning-artifacts/prd.md) — prd.md:216 (reconciled in this change)
- [Story 2.12 (`convert_colocated`) — template](_bmad-output/implementation-artifacts/2-12-implement-convert-rs-colocated-git-jj-conversion.md)
- jj CLI prior art: `git -C ../jj show v0.42.0:cli/src/commands/git/init.rs` (`do_init`, `GitInitMode::External`) + `:cli/src/git_util.rs:63–78` (`is_colocated_git_workspace`)
- jj-lib 0.42 (vendored): `~/.cargo/registry/.../jj-lib-0.42.0/src/{workspace.rs,git.rs,git_backend.rs,view.rs,repo.rs}`
- `crates/zanshin-jj/src/repo.rs::clone_into` (mechanics) + `convert.rs::convert_colocated` (gate/rollback)
- Canonical rules: `project-context.md` § zanshin-jj ("CLI behavior is the semantic reference"; "pass CLI parameters through"); `[[feedback-cli-is-the-behavioral-reference]]`; ADR-0003

## Dev Agent Record

### Agent Model Used

claude-sonnet-4-6

### Debug Log References

- Coverage ratchet required 100% on `convert.rs`; macOS path canonicalization caused `is_colocated()` to always return false in integration tests (TempDir gives `/var/folders/...`, gix normalises to the real path). Fixed by adding `canonicalize()` in both the inline unit test and Test 12.
- The `else { remove .jj/ }` rollback branch (line 144-145) required a test with a pre-existing dest dir and an invalid source (empty `.git/`).
- `resolve_git_repo_path`'s `ends_with(".git")` early-return (line 166) required passing `src/.git` directly as the source arg.

### Completion Notes List

- D5 option (b) chosen: `dest == source` passes through to a colocated result (`is_colocated` true → check_out skipped). Test 12 asserts this.
- Single-transaction import (`"import git repo"`) vs CLI's two-op sequence is documented in rustdoc and accepted (cosmetic difference; op-log effect preserved).
- `dunce` not added (OQ1): plain `git_workdir == workspace_root` suffices; integration tests use `canonicalize()` to match what gix reports.
- Coverage held at 100.00% for `convert.rs`; `coverage-baseline.txt` unchanged (no auto-raise needed).

### File List

- `crates/zanshin-jj/src/convert.rs` — added `convert_import`, `import_into`, `resolve_git_repo_path`, `is_bare_git_dir`, `is_colocated`; extended `//!` module doc; added `#[cfg(test)] mod tests` with 2 inline unit tests for `is_colocated`
- `crates/zanshin-jj/src/lib.rs` — `pub use convert::convert_import;`
- `crates/zanshin-jj/tests/convert.rs` — added Tests 1–12 (15 new tests: Tests 13-15 inserted before Test 12 during coverage ratchet work)
- `crates/zanshin-jj/tests/api_stability.rs` — bound `convert_import` fn-ptr
- `crates/zanshin-jj/README.md` — "Conversion modes" section (colocated vs import; shared-store warning)
- `docs/rust-error-codes.md` — amended 3 existing `jj.*` row notes

### Change Log

- 2026-06-27: Story implemented; all ACs satisfied; `cargo make test` green; status → review

## Open Questions for Ralph (non-blocking — defaults chosen)

1. **`dunce` for the colocated check (D5)?** The faithful `is_colocated_git_workspace` port uses `dunce::canonicalize` for the `.git`-parent comparison; `dunce` isn't a direct dep. **Default: drop it**, keep only `git_workdir == workspace_root` (sufficient for all tests on macOS). Add `dunce` only if a real symlink case appears.
2. **`dest == source` handling (D5)?** **Default: let it through → a colocated result** (most CLI-faithful; `is_colocated` skips the jj-native block), with test 12 asserting colocated. Alternative: pre-reject as `AlreadyJjRepo` (clearer for the dialog). Which do you want?
3. **`AlreadyJjRepo` now means two things** (source-jj *or* dest-jj; `path` disambiguates). **Default: reuse it.** Want a distinct variant for "source already jj" (adds a 4th `RepoError` variant + registry row)?
4. **README home** — colocated-vs-import doc in `crates/zanshin-jj/README.md` (AC-9). **Default: yes, plus module rustdoc.** Fine?

## Reconciliation done in this change (was OQ5)

- **prd.md FR-JJ-18b** (line 216) and **epics.md Story 2.13** (+ the FRs-covered note) were reconciled to the two-path / jj-native-at-a-separate-dest shape (verified blocks). The "in-place jj-native" wording is gone from the upstream docs, so this story no longer fights its own epic.
- **Bare-source support (OQ2 — resolved):** supported, per the canonical "replicate jj CLI behavior" rule (D9). **`trunk()` alias (OQ3 — resolved):** out of scope (cosmetic UX, D10).
