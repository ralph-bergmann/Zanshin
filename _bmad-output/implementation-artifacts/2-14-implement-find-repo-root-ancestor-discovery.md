# Story 2.14: Implement `find_repo_root` — ancestor repository discovery (consent-gated walk-up)

---
baseline_commit: 65557be70a23913f50ad3b9c8c99bc4261e23c84
---

Status: done

<!-- Note: Validation is optional. Run validate-create-story for quality check before dev-story. -->
<!-- Reconciled 2026-06-28: composes the post-Design-B `detect_repo` (Result<RepoKind,DetectError>,
     RepoKind::Missing→PathNotFound). find_repo_root now returns Result<Option<RepoRoot>,DetectError>
     and propagates the detect_repo I/O error fail-fast (Ralph 2026-06-28). See Dev Notes D2. -->

## Story

As a Rust caller powering the open-project flow (Flutter UI **and** the MCP server),
I want `zanshin-jj` to walk **up** from a chosen path to the nearest enclosing jj/Git repository root and report it,
So that when the user (or an MCP invocation) points at a **sub-directory** of a repo — not the root — the surface can offer "this folder is inside a repo at `<root>` — open that?" instead of falsely reporting "not a repository", **without the backend silently retargeting** (the choice stays with the UI / the human running MCP).

> **Why this exists (research-backed):** `detect_repo()` (Story 2.11) classifies a **single** directory — correct, but it returns `Ok(Neither)` for a sub-directory of a repo. The research doc `technical-repository-discovery-walkup-and-jj-marker-depth-research-2026-06-26.md` established that **every** jj client (jj-CLI `find_workspace_dir`, the `gg` GUI) and **every** editor (VS Code, JetBrains, Zed) walks **up** to the enclosing root, because `jj-lib`'s `Workspace::load` does **not** (it requires the exact root). This story adds that walk-up as a small, additive helper *above* `detect_repo()` — exactly mirroring `gg`'s `find_workspace_dir(cwd) = cwd.ancestors().find(|p| p.join(".jj").is_dir())`.

> **Scope boundary (read first):** This is a **PURE `zanshin-jj` Rust** story, **stat-only**, **ZERO `jj_lib`** (std-only, like `detect.rs`). It adds **one struct + one free function** to `detect.rs`, plus the `lib.rs` re-export + api-stability wiring + a new integration test file. It does **NOT** add FFI (the UI consumes this via Story **3.4c**, which is extended — see Dev Notes → "Consumer contract") and does **NOT** add MCP wiring (the MCP server consumes it via Story **7-1**, also extended). It does **NOT** implement walk-up *policy* knobs (ceiling dirs, filesystem-boundary stop) beyond the documented default. (project-context.md § "Simplicity First", § "Surgical Changes")

## Acceptance Criteria

> Driver: research doc `_bmad-output/planning-artifacts/research/technical-repository-discovery-walkup-and-jj-marker-depth-research-2026-06-26.md` (Q1/Q2 + recommendation §2). Marker semantics inherited verbatim from Story 2.11 `detect_repo()` (`.jj` is-`dir` / `.git` `exists`). FR family: FR-JJ-17 (detection).
>
> **Post-2.11 reconciliation (2026-06-28):** Story 2.11's `detect` was renamed `detect_repo` and made fallible — `pub fn detect_repo(path: &Path) -> Result<RepoKind, DetectError>` with `RepoKind { Jj, Git, Neither, PathNotFound }` (the old `Missing` variant is now `PathNotFound`). This story composes that fallible primitive; see Dev Notes D2 for how the new `Err` arm is handled.

### AC-1 — `RepoRoot` type + `find_repo_root` signature

**Given** `crates/zanshin-jj/src/detect.rs`
**When** extended
**Then** it defines `pub struct RepoRoot { pub root: PathBuf, pub kind: RepoKind }` deriving `Debug, Clone, PartialEq, Eq`
**And** `pub fn find_repo_root(start: &Path) -> Result<Option<RepoRoot>, DetectError>`
**And** the `kind` field is documented to only ever be `RepoKind::Jj` or `RepoKind::Git` (never `Neither`/`PathNotFound`).

### AC-2 — Nearest enclosing root wins (composes `detect_repo`), I/O error propagates fail-fast

**Given** `find_repo_root(start)`
**When** called
**Then** it evaluates `start` first, then each ancestor of `start` (toward the filesystem root), and returns `Ok(Some(..))` for the **first** (nearest) directory whose `detect_repo()` is `Ok(RepoKind::Jj)` or `Ok(RepoKind::Git)`, packaged as `RepoRoot { root: <that dir>, kind: <Jj|Git> }`
**And** it reuses `detect_repo()` at each level (inheriting the exact `.jj`-is-`dir` / `.git`-`exists` semantics of Story 2.11) — it does **not** re-implement the marker check
**And** a level that `detect_repo` reports as `Ok(RepoKind::Neither)` or `Ok(RepoKind::PathNotFound)` is a non-match: the walk continues upward
**And** if `detect_repo()` returns `Err(DetectError::Io)` for a visited level, `find_repo_root` **propagates that `Err` immediately (fail-fast)** — it does **not** treat an un-inspectable level as "no repo". (Rationale in AC-2a + Dev Notes D2: an un-inspectable level could itself be the repo, and the caller must be able to tell the user inspection failed rather than falsely report "not a repository".)

### AC-2a — The `Err` localizes to `start` (reachability)

**Given** the `find_repo_root` doc comment
**When** read
**Then** it documents that, because statting `start` already requires search (`x`) permission on **every** ancestor, `detect_repo` can only return `Err` for the **first** visited level (`start` itself) — in practice a non-directory component in the path (`ENOTDIR`) or an unsearchable prefix (`EACCES`). Fail-fast therefore reports the I/O problem at the earliest point and never skips a *deeper* un-inspectable repo (nothing is deeper than `start`).

### AC-3 — `start` itself counts (direct-hit case)

**Given** `find_repo_root(start)`
**When** `start` is itself a repo (`detect_repo(start)` is `Ok(RepoKind::Jj)` or `Ok(RepoKind::Git)`)
**Then** it returns `Ok(Some(RepoRoot { root == start, kind }))` — i.e. `root == start` signals "open directly, no suggestion needed".

### AC-4 — No enclosing repo → `Ok(None)`

**Given** `find_repo_root(start)`
**When** neither `start` nor any ancestor up to the filesystem root (within the ceiling) is a repo, and no level errored
**Then** it returns `Ok(None)`.

### AC-5 — Jj precedence at a colocated level (inherited)

**Given** an ancestor that is colocated (`.jj/` + `.git/`)
**When** it is the nearest match
**Then** the returned `kind` is `Jj` (inherited from `detect_repo()`'s `Jj`-before-`Git` ordering).

### AC-6 — Stat-only, std-only, no `jj_lib`, no panic; bounded by the `$HOME` ceiling

**Given** `find_repo_root`
**When** called on any path
**Then** it is **stat-only** (only the `stat(2)` calls `detect_repo()` already makes per level), never loads a workspace, never mutates, and **never panics**
**And** it imports **no** `jj_lib` (the `test-jj-adapter-hygiene` grep gate stays clean)
**And** the upward walk stops at the **first repo found** (or the first `Err`), otherwise **before reaching `$HOME` or any directory above it** — the `$HOME` **ceiling** (JetBrains-style), so a dotfiles repo at `~` is not surfaced when opening an unrelated folder under home
**And** the ceiling bounds the walk-**up only**: `start` itself is **always** classified even when `start == $HOME` (explicitly opening `~` still finds `~/.jj`/`~/.git`) — cf. git's `GIT_CEILING_DIRECTORIES` "will not exclude the current working directory". Precisely: a directory is "`$HOME` or above" iff `home.starts_with(dir)`; the walk stops there, except for `start` itself
**And** `$HOME` is read from the `HOME` env var (macOS always sets it); when unset, the walk degrades to the filesystem root. The ceiling is **injectable via a crate-private fn** so it is unit-testable without depending on the real `$HOME`
**And** there is **no** filesystem-boundary/mount guard (lower priority for a single-disk macOS GUI).

> **Ceiling semantics (Ralph-confirmed 2026-06-26):** the ceiling only has any effect when `start` is **under** `$HOME` (only then is `$HOME` on the ancestor chain) — e.g. from `~/dev/.../Zanshin/schemas` it prevents climbing to `~`, but it never truncates before finding a project repo lower down. For a `start` **outside** `$HOME` (e.g. `/foo/bar/dev/projekt/bla`), `$HOME` is not an ancestor, so the ceiling has no effect and the walk proceeds up the tree as normal.

### AC-7 — Consent-gated contract documented

**Given** the `find_repo_root` doc comment
**When** read
**Then** it documents the **consent-gated** usage explicitly: on `Ok(Some(root))` the caller compares `root` against `start` — `root == start` ⇒ open directly; `root != start` ⇒ the result is a **suggestion** of an enclosing repo that the consumer must **surface for confirmation** (UI prompt / MCP message), and that the backend **never** silently opens the ancestor.

### AC-8 — Re-export + `jj_lib`-free signature + surface-lock

**Given** the public API
**When** inspected
**Then** `RepoRoot` and `find_repo_root` are re-exported from `lib.rs` (`pub use detect::{detect_repo, find_repo_root, DetectError, RepoKind, RepoRoot};`)
**And** no `jj_lib` (or `gix`) type appears in the signature (`(&Path) -> Result<Option<RepoRoot>, DetectError>`, and `RepoRoot` is crate-owned)
**And** `crates/zanshin-jj/tests/api_stability.rs` is updated: a `type _RepoRoot = zanshin_jj::RepoRoot;` alias (under the `// detect` section), a fn-pointer binding `_ = zanshin_jj::find_repo_root as fn(&std::path::Path) -> Result<Option<zanshin_jj::RepoRoot>, zanshin_jj::DetectError>;`, and a trivially-constructible value `_ = zanshin_jj::RepoRoot { root: std::path::PathBuf::new(), kind: zanshin_jj::RepoKind::Jj };`; the header count comment is corrected **26 → 27** (`RepoRoot` is the one new type; `find_repo_root` is a fn, `DetectError`/`RepoKind` already counted).

### AC-9 — Test coverage (integration + inline unit)

**Given** integration tests in `crates/zanshin-jj/tests/find_repo_root.rs` (public `find_repo_root`) **and** inline `#[cfg(test)]` unit tests in `src/detect.rs` (private `find_repo_root_within`, for the ceiling)
**When** they run
**Then** they assert at least:
1. `start` is the `tiny-3-commits` fixture root → `Ok(Some(root == start, Jj))`.
2. `start` is a **sub-directory** of a jj workspace → `Ok(Some(root == workspace root, Jj))` and `root != start` (the consent-gated suggestion case).
3. `start` is a **sub-directory** of a `git init` dir (no `.jj`) → `Ok(Some(root == git root, Git))`.
4. **Deep nesting / nearest wins:** an inner jj workspace nested inside an outer repo → returns the **inner** (nearest) root, not the outer.
5. No repo at/above `start` (a tmpdir with no markers, no markers above within the tmp tree) → `Ok(None)`.
6. Non-existent `start` whose lexical ancestors contain no repo → `Ok(None)`.
7. Colocated (`.jj/` + `.git/`) nearest level → `Ok(Some(.., Jj))`.
8. **`$HOME` ceiling** (inline unit tests on `find_repo_root_within` with an injected temp ceiling `C`): (a) start below `C` with a repo marker only **at `C`** → `Ok(None)` (dotfiles-at-`~` analog, not surfaced); (b) start **== `C`** and `C` is a repo → `Ok(Some(root == C))` (start carve-out); (c) `ceiling = None` → finds a repo above where the ceiling would have stopped (covers the `is_none_or` None arm); (d) a repo **strictly below** `C` → still found.
9. **`Err` propagation:** `start` is a path *under a regular file* (a non-directory path component) → `detect_repo(start)` fails with `ENOTDIR`, so `find_repo_root(start)` returns `Err(DetectError::Io)` (mirrors Story 2.11's `detect_path_under_a_regular_file_returns_io_error`). Asserts the `Err` is *not* collapsed to `Ok(None)`.

### AC-10 — Quality gate green incl. coverage ratchet

**Given** the change is complete
**When** `cargo make test` runs
**Then** it passes end-to-end (`cargo test`, clippy pedantic `-D warnings`, rustfmt, dart analyze/format, `cargo deny`, **and** the coverage ratchet)
**And** the new `find_repo_root` / `find_repo_root_within` / `RepoRoot` lines in `detect.rs` reach the per-file floor (in practice ~100% — both `Ok(Jj)`/`Ok(Git)` match arms, the `Ok(Neither)`/`Ok(PathNotFound)` continue arm, the `?` `Err` propagation, the `Ok(None)` fall-through, and both `take_while` predicate arms are exercised by AC-9)
**And** the auto-raised `coverage-baseline.txt` is committed in the same change.

## Tasks / Subtasks

- [x] **Task 1 — Extend `src/detect.rs`** (AC: 1, 2, 2a, 3, 4, 5, 6, 7)
  - [x] Change `use std::path::Path;` → `use std::path::{Path, PathBuf};`.
  - [x] Define `pub struct RepoRoot { pub root: PathBuf, pub kind: RepoKind }` with `#[derive(Debug, Clone, PartialEq, Eq)]`. Doc-comment the struct **and both fields** (`#![deny(missing_docs)]` is on — missing docs is a compile error). Document the `kind` invariant (only `Jj`/`Git`).
  - [x] Implement `pub fn find_repo_root(start: &Path) -> Result<Option<RepoRoot>, DetectError>` per the skeleton: it reads `$HOME` (`std::env::var_os("HOME")`) and delegates to a crate-private `fn find_repo_root_within(start: &Path, ceiling: Option<&Path>) -> Result<Option<RepoRoot>, DetectError>`. **No `#[must_use]`** — `Result` is already `#[must_use]`, so adding it would trip `clippy::double_must_use` under `-D warnings`. Doc-comment it **including the consent-gated contract (AC-7)**, the **`$HOME`-ceiling** note (AC-6), the **`# Errors`** section (AC-2/AC-2a), and the reachability note (AC-2a).
  - [x] In `find_repo_root_within`, bound the walk with `take_while(|dir| *dir == start || ceiling.is_none_or(|c| !c.starts_with(dir)))` (start-path carve-out + `$HOME` ceiling). For each surviving `dir`, call `detect_repo(dir)?` (the `?` propagates `Err(DetectError::Io)` fail-fast) and `return Ok(Some(..))` on `RepoKind::Jj`/`RepoKind::Git`; `RepoKind::Neither`/`RepoKind::PathNotFound` continue. After the loop, `Ok(None)`. Keep it stat-only and `jj_lib`-free (only `detect_repo()` over `start.ancestors()`). No panics, no `unwrap`.
- [x] **Task 2 — Wire `lib.rs`** (AC: 8)
  - [x] Extend the existing re-export `pub use detect::{detect_repo, DetectError, RepoKind};` → `pub use detect::{detect_repo, find_repo_root, DetectError, RepoKind, RepoRoot};`.
- [x] **Task 3 — Update the surface-lock test** (AC: 8)
  - [x] In `crates/zanshin-jj/tests/api_stability.rs`: add `type _RepoRoot = zanshin_jj::RepoRoot;` under the `// detect` section; inside `api_surface_resolves`, add the `find_repo_root` fn-pointer binding (`Result<Option<..>, DetectError>` signature) and a trivially-constructible `RepoRoot` value.
  - [x] Bump the header comment "(26 types, AC-1 table)" → "(27 types, AC-1 table)".
- [x] **Task 4a — Integration tests `tests/find_repo_root.rs`** (AC: 9, cases 1–7 + 9 — the public `find_repo_root`)
  - [x] `// SPDX-License-Identifier: MIT` first line.
  - [x] Mirror `tests/detect.rs`: reuse `tempfile::TempDir`, `test_helpers::extract_fixture`, a local `git(args, dir)` shell helper for the bare-git case. No `jj_lib` import.
  - [x] Build sub-directory / nesting scenarios with `std::fs::create_dir_all` + `std::fs::create_dir(".jj")` etc. (no jj-lib, no `pin_env()` — `find_repo_root` never reads config). Note: tempdirs live outside `$HOME`, so the real `$HOME` ceiling never interferes with these (they behave as walk-to-root).
  - [x] Cover AC-9 cases 1–7 (with explicit `root == start` vs `root != start` assertions on the suggestion case) **and case 9** (`start` under a regular file → `Err(DetectError::Io)`, matching `tests/detect.rs`'s `detect_path_under_a_regular_file_returns_io_error` recipe).
- [x] **Task 4b — Inline unit tests for the `$HOME` ceiling** (AC: 9, case 8 — the private `find_repo_root_within`)
  - [x] Per CLAUDE.md test-placement: private-item tests go **inline** in `src/detect.rs` (`#[cfg(test)] mod tests`). Target `find_repo_root_within(start, Some(<temp ceiling>))` with a temp-dir tree — **no** real-`$HOME` dependency, **no** global env mutation. Assertions are over `Result<Option<RepoRoot>, DetectError>` (wrap in `Ok(Some(..))` / `Ok(None)`).
  - [x] Cases: (a) start below an injected ceiling `C`, with a repo marker only at/above `C` → `Ok(None)` (the at-`C` repo is NOT surfaced); (b) start **== `C`** and `C` is itself a repo → `Ok(Some(root == C))` (start-path carve-out); (c) `ceiling = None` → walks past where the ceiling would be (covers the `is_none_or` None arm); (d) a repo strictly below `C` is still found.
- [x] **Task 5 — Gate** (AC: 10)
  - [x] Run `cargo make test`; make it green.
  - [x] Commit the auto-raised `coverage-baseline.txt`. **Never** lower the baseline or add an `exclude_prefix` to pass (CLAUDE.md, review-blocking).

## Dev Notes

### Decision D1 — `find_repo_root` lives in `detect.rs`, not a new module

It composes `detect_repo()` and references `RepoKind`/`RepoRoot`/`DetectError` — all in `detect.rs`. Folding it in keeps the detection/discovery concern cohesive and avoids a near-empty `discover.rs` that would just `use super::{detect_repo, RepoKind, DetectError}`. This matches the module-by-noun layout (project-context.md § File & module organization): "detection" is the noun; single-dir classify and nearest-ancestor discovery are two functions of it. (Alternative considered: a `discover.rs` module — rejected as premature given two small items.)

### Decision D2 — `find_repo_root` returns `Result<Option<RepoRoot>, DetectError>` (Ralph 2026-06-28)

> **This flips the original D2.** The story was authored against the *infallible* `detect()`; that primitive became fallible in Story 2.11's Design B (`detect_repo -> Result<RepoKind, DetectError>`). With a fallible per-level probe, the walk-up must decide what to do when a level cannot be inspected.

- **`Ok(None)` = "no repo at/above `start`"** — a normal result, not an error (same framing as `detect_repo`'s `Neither`/`PathNotFound`; see `[[feedback-null-for-absence]]`).
- **`Err(DetectError::Io)` = "a level could not be inspected"** — propagated **fail-fast** via `?`. We do **not** swallow it as `Ok(None)`: an un-inspectable level could itself be the repository, and the caller must be able to tell the user *inspection failed* rather than falsely report "not a repository" (Ralph 2026-06-28; aligns with `[[feedback-null-for-absence]]`'s "structurally-un-inspectable may error" carve-out).
- **Why `Result`, not just `Option` (answering Ralph's "could the error case *be* the repo dir?"):** Yes — and that is exactly why we propagate. `detect_repo(dir)` only errors when `dir` itself cannot be `stat`-ed, which requires a problem in `dir`'s path *prefix*. Because reaching/statting `start` already requires search (`x`) permission on **every** ancestor, the implication runs one way: **if `start` is inspectable, every ancestor is too.** So the `Err` can in practice only occur on the **first** visited level (`start` itself) — a non-directory path component (`ENOTDIR`) or an unsearchable prefix (`EACCES`). Fail-fast (`?` on the first level) therefore surfaces it at the earliest point and **never skips a deeper un-inspectable repo** (there is nothing deeper than `start`), and never wrongly returns a *farther* root in place of a nearer-but-unreadable one. The error is honest ("could not inspect this path") and the consumers (3.4c UI, 7-1 MCP) get a third, distinct outcome to react to.
- **Not propagated as a panic and not a new error type** — reuse `DetectError` (already public, already counted in the surface). No new variant.

### Decision D3 — `$HOME` ceiling (Ralph-confirmed); start-path carve-out; injectable for tests

The upward walk uses `std::path::Path::ancestors()` (start, parent, … up the tree) — the same shape as jj-CLI's `find_workspace_dir` and `gg` (research doc Q2) — but **bounded by a `$HOME` ceiling** (JetBrains-style). Rationale (Ralph 2026-06-26): Ralph keeps his dotfiles in a Git repo, so `~/.git` exists; without the ceiling, opening an unrelated folder under home and finding no project repo would walk all the way up and surface the dotfiles repo. The ceiling prevents that.

Mechanics:
- A directory is "`$HOME` or above" iff `home.starts_with(dir)`. The walk stops at such a directory (does not classify it).
- **Carve-out:** `start` itself is always classified, even if `start == $HOME` — so explicitly opening `~` still finds the dotfiles repo. (Mirrors git's `GIT_CEILING_DIRECTORIES`, which excludes the cwd from the ceiling.) Implemented as `*dir == start || ceiling.is_none_or(|c| !c.starts_with(dir))` inside `take_while`.
- **Only affects starts under `$HOME`:** for a `start` outside the home subtree, `$HOME` is not on the ancestor chain, so the predicate never trips early and the walk proceeds normally.
- **Testability:** the public `find_repo_root(start)` reads `$HOME` (`std::env::var_os("HOME")`) and delegates to a crate-private `find_repo_root_within(start, ceiling: Option<&Path>)`. Unit tests target the private fn with an injected temp-dir ceiling (no dependency on the real `$HOME`, no global env mutation — important under parallel tests). `$HOME` unset ⇒ `ceiling = None` ⇒ walk to filesystem root.
- No filesystem-boundary/mount guard (low value on a single-disk macOS GUI).

### Copy-adaptable skeleton (append to `detect.rs`)

```rust
use std::path::{Path, PathBuf}; // detect.rs currently has `use std::path::Path;`

/// A repository root discovered by walking up from a start path ([`find_repo_root`]).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RepoRoot {
    /// The directory that is the repository root.
    pub root: PathBuf,
    /// The kind of repository found. Only ever [`RepoKind::Jj`] or [`RepoKind::Git`]
    /// — `find_repo_root` never yields a `RepoRoot` for `Neither`/`PathNotFound`.
    pub kind: RepoKind,
}

/// Walks up from `start` to the nearest enclosing repository root (FR-JJ-17).
///
/// Evaluates `start`, then each ancestor, returning the first directory that
/// [`detect_repo`] classifies as [`RepoKind::Jj`] or [`RepoKind::Git`]. The upward
/// walk is bounded by the **`$HOME` ceiling**: it never climbs to `$HOME` or above,
/// so a dotfiles repo at `~` is not surfaced when opening an unrelated folder under
/// home. The ceiling bounds the walk-*up* only — `start` itself is always classified,
/// so explicitly opening `~` still finds `~/.jj`/`~/.git`. Returns `Ok(None)` if no
/// repository is found within the ceiling.
///
/// Stat-only — composes [`detect_repo`] per level (same `.jj`-is-dir / `.git`-exists
/// semantics, symlinks followed). Never loads, mutates, or panics.
///
/// # Consent-gated use
///
/// On `Ok(Some(root))`, compare `root` against `start`: `root == start` ⇒ the chosen
/// path is itself a repository (open directly); `root != start` ⇒ a *suggestion* of an
/// **enclosing** repository the caller should **surface for confirmation** (UI prompt,
/// or MCP message such as "not a jj workspace here; the nearest is `<root>`"). This
/// function never opens anything — it only reports.
///
/// # Errors
///
/// Returns [`DetectError::Io`] if a visited level cannot be inspected (the I/O error
/// surfaced by [`detect_repo`], e.g. `EACCES`/`ENOTDIR`) — propagated **fail-fast**,
/// never collapsed to `Ok(None)`. Because statting `start` already requires search
/// permission on every ancestor, this can only occur on `start` itself (a
/// non-directory path component, or an unsearchable prefix); surfacing it lets the
/// caller report "could not inspect this path" instead of "not a repository".
pub fn find_repo_root(start: &Path) -> Result<Option<RepoRoot>, DetectError> {
    let home = std::env::var_os("HOME").map(PathBuf::from);
    find_repo_root_within(start, home.as_deref())
}

/// Core walk-up with an explicit `ceiling` (crate-private so the `$HOME` ceiling is
/// unit-testable without depending on the real `$HOME`). Classifies `start`, then
/// ancestors strictly below `ceiling`; `ceiling` and anything above is never climbed
/// into, except that `start` itself is always classified. `ceiling == None` ⇒ walk
/// to the filesystem root. Propagates a [`detect_repo`] I/O error fail-fast.
fn find_repo_root_within(start: &Path, ceiling: Option<&Path>) -> Result<Option<RepoRoot>, DetectError> {
    for dir in start
        .ancestors()
        .take_while(|dir| *dir == start || ceiling.is_none_or(|c| !c.starts_with(dir)))
    {
        match detect_repo(dir)? {
            RepoKind::Jj => return Ok(Some(RepoRoot { root: dir.to_owned(), kind: RepoKind::Jj })),
            RepoKind::Git => return Ok(Some(RepoRoot { root: dir.to_owned(), kind: RepoKind::Git })),
            RepoKind::Neither | RepoKind::PathNotFound => {}
        }
    }
    Ok(None)
}
```

That is the entire production addition (~35 lines incl. docs). The `for` + `?` form is the idiomatic way to early-return both the found root **and** the propagated `Err` (a `find_map` cannot early-return an error cleanly). `is_none_or` is stable since Rust 1.82 (we pin 1.95) and is clippy-pedantic's preferred form over `map_or(true, …)`. Note the **absence of `#[must_use]`**: `Result` already carries it, and a bare `#[must_use]` on a `Result`-returning fn fires `clippy::double_must_use` under `-D warnings`. Resist adding more (Simplicity First).

### Consumer contract — how UI and MCP get the **consent-gated** behaviour

> These are **NOT implemented in this story** (it is pure `zanshin-jj`). They are the contract the two downstream stories implement against `find_repo_root`. Both story scope-notes are updated in `sprint-status.yaml` to reference this story. Note the three outcomes each consumer now handles: `Ok(Some)`, `Ok(None)`, `Err(DetectError::Io)`.

**UI — via FFI (Story 3.4c, extended):** `3.4c` already exposes `zanshin_repo_detect(path)`. Extend its `RepoDetect` FlatBuffers payload to also carry the **optional suggestion**: when `detect_repo(path)` is `Ok(Neither)` (or `Ok(PathNotFound)`), call `find_repo_root(path)` and, if `Ok(Some)`, include `{ suggested_root: string, suggested_kind: RepoKind }` in the payload; if `Err`, map it to the existing FFI I/O failure (`jj.detect_failed`) rather than a suggestion. The Flutter UI renders consent-gated, e.g.:
> "Dieser Ordner liegt in einem **{jj|Git}**-Repository unter `<root>`. Öffnen?" — **[Öffnen]** / **[Abbrechen]**

The backend never auto-opens; the UI decides (this matches `[[feedback-dont-patronize-users]]`: backend exposes the capability, UI offers the decision).

**MCP — at startup repo-selection (Story 7-1, extended):** `7-1` resolves the repo from `--repo <path>` or CWD. Route that through `find_repo_root`, but **the MCP never decides for the user and never silently retargets** — it reports the situation factually and leaves the next step to the MCP user/agent (`[[feedback-dont-patronize-users]]`; resolved with Ralph 2026-06-26):
- `Ok(Some(root == start, Jj))` → the path **is** a jj workspace → start normally.
- `Ok(Some(root != start, Jj))` → the path is **inside** a jj workspace. **Do not** open `<root>` silently (the user asked for `<path>`, not `<root>`). Report it neutrally — what was given, what it is, and the nearest jj root as an *option* — and let the user decide (re-invoke with `--repo <root>`, or not). e.g. `"<path> is not a jj workspace; it is inside the jj repository at <root>. To use that repo, re-run with --repo <root>."`
- `Ok(Some(.., Git))` → `"<path> is a Git repository, not a jj workspace."` (the user decides: convert, or point elsewhere — the MCP does not act).
- `Ok(None)` → `"No jj or Git repository at or above <path>."`
- `Err(DetectError::Io)` → `"Could not inspect <path>: <io error>."` (a genuine I/O failure — distinct from "no repo here"; the MCP exits without retargeting).

The MCP **surfaces facts + options, it does not act or prescribe**. Concretely: when the given path is not itself a jj workspace, startup does not proceed against a *different* directory — it exits with the neutral, machine-readable message above so the user/orchestrating agent chooses what to do. (This is the non-interactive analog of the UI consent gate.)

### Test recipe — mirror `tests/detect.rs`

- `tempfile::TempDir::new()` for scratch trees; build nesting with `std::fs::create_dir_all(root.join("a/b/c"))` then `std::fs::create_dir(root.join(".jj"))`.
- `test_helpers::extract_fixture("tiny-3-commits")` for the real-fixture direct-hit + a sub-dir-of-fixture case (`fixture.path.join("somedir")` — create it, assert `root == fixture.path`).
- Local `fn git(args, dir)` (verbatim from `tests/detect.rs`) for the git sub-dir case.
- Nearest-wins: outer dir with `.git/`, inner dir `outer/inner` with `.jj/`; assert `find_repo_root(outer/inner/deeper) == Ok(Some(inner, Jj))`.
- **Err case (AC-9 #9):** create a regular file, then call `find_repo_root(file.join("sub"))` — the `sub` component under a non-dir yields `ENOTDIR`; assert `matches!(result, Err(DetectError::Io(_)))` (recipe per `tests/detect.rs`'s `detect_path_under_a_regular_file_returns_io_error`).
- No `pin_env()` — `find_repo_root` never reads jj/git config.
- Scenario-describing names: `find_repo_root_on_subdir_of_jj_returns_workspace_root`, `find_repo_root_nearest_inner_wins`, `find_repo_root_no_repo_returns_none`, `find_repo_root_path_under_regular_file_returns_io_error`, etc.

### Coverage note

New lines are in `detect.rs` (already 100%). Coverage split: the **integration** tests (Task 4a) hit the public `find_repo_root` (`$HOME` read + delegation), both `Ok(Jj)`/`Ok(Git)` match arms, the `Ok(Neither)`/`Ok(PathNotFound)` continue arm via the no-repo/nesting cases, the `Ok(None)` fall-through, and the `?` `Err`-propagation arm (case 9, path-under-a-regular-file → `ENOTDIR`, deterministic — no flaky `EACCES` needed); the **inline unit** tests (Task 4b) hit both `take_while` predicate arms — the `*dir == start` carve-out, the `ceiling = Some` stop, and the `ceiling = None` (`is_none_or`) arm. Together ⇒ ~100%. No FFI/extern coverage trap here (that belongs to 3.4c). `cargo make coverage` auto-raises the baseline; commit it.

### Previous-story intelligence — pre-empt the known traps

- **Composes the *fallible* `detect_repo` (Story 2.11 Design B).** This story was authored against the old infallible `detect()`; reconciled 2026-06-28. The primitive is now `detect_repo(&Path) -> Result<RepoKind, DetectError>` with `RepoKind { Jj, Git, Neither, PathNotFound }` (no more `Missing`). The walk-up uses `?` to propagate the I/O error (D2). Verify the live names with [`detect.rs`](crates/zanshin-jj/src/detect.rs) before coding.
- **Dependency is satisfied.** Story 2.11 (`detect_repo`), 2.12 (`convert_colocated`) and 2.13 (`convert_import`) are all `done`. `find_repo_root` calls `detect_repo()` and reuses `RepoKind`/`DetectError`.
- **Surface-lock test (Story 2.10/2.11).** `tests/api_stability.rs` won't *know* about `RepoRoot`/`find_repo_root` unless added (Task 3). The current count is **26** ([api_stability.rs:12](crates/zanshin-jj/tests/api_stability.rs#L12)) — adding the one new type `RepoRoot` makes it **27**. Count drift was a flagged finding in 2.10 and 2.11 — get it right.
- **`#![deny(missing_docs)]` (Story 2.10).** The struct **and both fields** and the fn each need a `///`. A missing field doc is a build failure.
- **`clippy::double_must_use`.** Do **not** put `#[must_use]` on `find_repo_root` now that it returns `Result` — it would fail the gate under `-D warnings` (D2 / skeleton).
- **Scope discipline (2.8/2.9).** Do **not** pull the FFI (3.4c) or MCP (7-1) wiring into this story — only the `zanshin-jj` capability + the documented contract.

### Files this story touches

| File | Action | What |
|------|--------|------|
| `crates/zanshin-jj/src/detect.rs` | UPDATE | `+ RepoRoot` struct, `+ find_repo_root()` + private `find_repo_root_within()` (both `-> Result<Option<RepoRoot>, DetectError>`, `?`-propagation), `use std::path::{Path, PathBuf}`, `+ #[cfg(test)] mod tests` (inline `$HOME`-ceiling unit tests) |
| `crates/zanshin-jj/src/lib.rs` | UPDATE | extend re-export with `find_repo_root, RepoRoot` |
| `crates/zanshin-jj/tests/find_repo_root.rs` | **NEW** | integration tests for public `find_repo_root` (direct hit, sub-dir suggestion, nearest-wins, none, colocated, **Err propagation**) |
| `crates/zanshin-jj/tests/api_stability.rs` | UPDATE | bind `RepoRoot` + `find_repo_root` (Result signature); 26 → 27 |
| `coverage-baseline.txt` | UPDATE (auto) | commit the auto-raised baseline |

No `Cargo.toml` change (no new deps). No FFI, no codegen, no schema, no error-registry change (`DetectError` already exists).

### Hard rules in scope (project-context.md — reject-at-review on violation)

- **No `jj_lib` import** in `detect.rs` (the grep gate enforces it). `find_repo_root` is std-only.
- **No `extern "C"` here** — FFI is 3.4c.
- **No `unwrap()`/`expect()`/`panic!()`** on the library path. `find_repo_root` has none (`for` + `?` + `to_owned`). Tests may `expect()`.
- **No `jj_lib` type in a public position** — signature is `(&Path) -> Result<Option<RepoRoot>, DetectError>`, `RepoRoot` crate-owned, `DetectError` crate-owned.
- **SPDX first line** on the new test file.
- **rustfmt `max_width = 100`, clippy pedantic `-D warnings`** (incl. `double_must_use` — see D2).
- **Coverage ratchet: add tests, never lower the baseline.**

### References

- [Research: walk-up + marker depth](_bmad-output/planning-artifacts/research/technical-repository-discovery-walkup-and-jj-marker-depth-research-2026-06-26.md) — Q1 (walk-up), Q2 (stop point), recommendation §2 (separate additive helper)
- [`zanshin-jj/src/detect.rs`](crates/zanshin-jj/src/detect.rs) — `detect_repo()` + `RepoKind` + `DetectError` (Story 2.11, Design B), the primitive this composes
- [Story 2.11 — detect_repo](_bmad-output/implementation-artifacts/2-11-implement-detect-rs-repository-kind-detection.md) — marker + error semantics inherited
- [`zanshin-jj/tests/detect.rs`](crates/zanshin-jj/tests/detect.rs) — `git()` + `TempDir` + `extract_fixture` patterns to mirror; `detect_path_under_a_regular_file_returns_io_error` is the Err-case recipe
- [`zanshin-jj/tests/api_stability.rs`](crates/zanshin-jj/tests/api_stability.rs) — surface-lock test to extend (26 → 27)
- Story 3.4c (FFI detect/convert — **consumer**, extended for the UI suggestion + `Err` mapping) — `sprint-status.yaml`
- Story 7-1 (MCP repo-selection cwd-walk-up — **consumer**, extended for the "nearest is `<root>`" + `Err` response) — `sprint-status.yaml`
- [project-context.md](_bmad-output/project-context.md) — FR-JJ-16/17, Simplicity First, coverage ratchet
- jj parity: jj-cli `find_workspace_dir` (`cli/src/cli_util.rs:2739`); `gg` `find_workspace_dir` (`src/worker/gui_util.rs:1345`)

## Dev Agent Record

### Agent Model Used

claude-sonnet-4-6

### Debug Log References

None.

### Completion Notes List

- Added `RepoRoot { root: PathBuf, kind: RepoKind }` struct to `detect.rs` with full doc-comments on struct and both fields (satisfies `#![deny(missing_docs)]`).
- Implemented `pub fn find_repo_root(start)` — reads `$HOME` from env, delegates to crate-private `find_repo_root_within` for testability.
- Implemented `fn find_repo_root_within(start, ceiling)` — `for` + `?` idiom for clean fail-fast `Err` propagation; `take_while` with `is_none_or` for ceiling + start-carve-out; stat-only, no `jj_lib`, no `unwrap`.
- No `#[must_use]` on `find_repo_root` (avoiding `clippy::double_must_use` since `Result` already is `#[must_use]`).
- Consent-gated contract fully doc-commented in `find_repo_root` (AC-7).
- `lib.rs` re-export extended: `find_repo_root, RepoRoot` added.
- `api_stability.rs` updated: `type _RepoRoot`, fn-pointer binding, trivially-constructible `RepoRoot` value; count bumped 26→27.
- New integration test file `tests/find_repo_root.rs` (SPDX header, 8 tests covering AC-9 cases 1–7 + 9).
- Inline unit tests in `src/detect.rs` `#[cfg(test)] mod tests` covering all 4 `$HOME`-ceiling cases (AC-9 case 8a–d); no real-`$HOME` dependency, no env mutation.
- One clippy fix during gate: `"expected Io, got {:?}", err` → `"expected Io, got {err:?}"` (uninlined_format_args).
- `cargo make test` green: all tests pass, clippy pedantic clean, rustfmt clean, coverage held at 98.28% (no regression, no baseline change needed since detect.rs was already 100% and new lines reached 100% too).

### File List

- `crates/zanshin-jj/src/detect.rs` — updated: `PathBuf` import, `RepoRoot` struct, `find_repo_root`, `find_repo_root_within`, inline `#[cfg(test)] mod tests`
- `crates/zanshin-jj/src/lib.rs` — updated: re-export extended with `find_repo_root, RepoRoot`
- `crates/zanshin-jj/tests/find_repo_root.rs` — new: 8 integration tests (cases 1–7 + 9)
- `crates/zanshin-jj/tests/api_stability.rs` — updated: `_RepoRoot` alias, fn-pointer + value bindings, count 26→27

### Change Log

- 2026-06-28: Implemented Story 2.14 — `find_repo_root` ancestor discovery. Added `RepoRoot` struct + `find_repo_root` / `find_repo_root_within` to `detect.rs`; wired lib.rs re-export; updated api_stability.rs (26→27); added integration tests (`tests/find_repo_root.rs`) and inline ceiling unit tests. `cargo make test` green, coverage 98.28% held.

## Open Questions for Ralph (non-blocking — defaults chosen, override before dev if desired)

1. **Walk-up ceiling.** ✅ **RESOLVED with Ralph 2026-06-26: include the `$HOME` ceiling.** Ralph keeps dotfiles in a Git repo (`~/.git` exists), so the walk must not climb to `~` and surface it. The walk stops before `$HOME`/above, with a carve-out so explicitly opening `~` still works. No filesystem-boundary guard. (See D3 + AC-6.)
2. **MCP behaviour when `start` is a sub-dir of a jj repo.** ✅ **RESOLVED with Ralph 2026-06-26:** the MCP **never silently retargets** ("open xyz" must not quietly operate on abc) and **never decides for the user** — it reports the situation neutrally (what was given, what it is, the nearest jj root as an option) and leaves the handling to the MCP user/agent. (Silent-retarget / jj-CLI "just works from a sub-dir" is explicitly **rejected** here.)
3. **`detect_repo` `Err` during walk-up (introduced by 2.11 Design B).** ✅ **RESOLVED with Ralph 2026-06-28: propagate, fail-fast.** `find_repo_root` returns `Result<Option<RepoRoot>, DetectError>`; an un-inspectable level yields `Err(DetectError::Io)` (not swallowed as `Ok(None)`), so the consumer can tell the user inspection failed. By stat-reachability the `Err` localizes to `start` itself. (Rejected alternatives: skip-and-continue — could skip the very dir that is the repo; `Err`=wall returning `None` — hides the failure.) See D2 + AC-2/AC-2a.
4. **Story slicing.** This story = the `zanshin-jj` capability + the contract. The UI-FFI wiring is folded into **3.4c** and the MCP wiring into **7-1** (their scope-notes updated to reference this). Prefer instead **dedicated wrapper stories** (a `3.4c`-sibling for the FFI suggestion, a `7-x` for the MCP message) so each surface is independently trackable? **Default: extend 3.4c + 7-1.**

## Review Findings

_Code review 2026-06-28 (bmad-code-review, ultracode: adversarial 3-layer — Blind Hunter + Edge Case Hunter + Acceptance Auditor — plus a Completeness Critic, with per-finding adversarial verification; 14 agents). Quality gate independently re-verified **GREEN**: `cargo fmt -p zanshin-jj -- --check` ✓, `cargo clippy -p zanshin-jj --all-targets -- -D warnings` (pedantic) ✓, tests ✓ (`find_repo_root` 8/8, `api_stability` 1/1, inline ceiling 4/4), `cargo make coverage` **98.28% held** — no regression, baseline unchanged, extern-coverage OK → **AC-10 confirmed**. 10 raw findings → 9 refuted by verification, 1 confirmed._

- [x] [Review][Patch] Stale surface-count comment: `count unchanged at 26` now contradicts the bumped header `(27 types …)` [crates/zanshin-jj/tests/api_stability.rs:96] — this diff bumped the header to 27 and added the 27th alias `_RepoRoot`, which rendered the convert-section comment's literal `26` stale (it was correct before this change). The comment exists to keep the surface count honest (Dev Notes: _"Count drift was a flagged finding in 2.10 and 2.11 — get it right"_), so a `26` two lines below the file's own `27` is exactly the drift it guards against. Fix: `26` → `27`, or drop the trailing absolute number (the sentence _"convert exports no new type"_ stays true). Comment-only; gate is green regardless. Low severity. (Dissent: one verifier read it as pre-existing/out-of-scope per Surgical-Changes since Task 3 named only the header; the stronger reading — "clean up your own change's mess" — prevails because the comment was correct pre-diff.) **— ✅ applied 2026-06-28 (`26` → `27`).**

**Dismissed as noise / verified non-issues (9):**
1. _"Ceiling carve-out climbs above `$HOME`"_ (blind) — correct-by-spec (AC-3/AC-6 carve-out); the doc states it verbatim. The behavior (always classify `start`) is the ratified contract; gating it would regress AC-3/AC-6.
2. _"No multi-level ceiling-stop test"_ (blind) — the climb-then-stop behavior is hermetically covered by the inline ceiling unit tests; not an actionable gap.
3. _"Empty-string `HOME` disables the ceiling"_ (edge) — benign; `Some("")` makes `starts_with` admit everything → degrades to walk-to-root, identical to the documented unset case.
4. _"`symlinks followed` only at the marker level; walk-up is lexical"_ (edge) — intended std behavior; mirrors jj-CLI `find_workspace_dir` + `gg`; ancestor canonicalization is out of scope.
5. _"AC-2a reachability not airtight vs TOCTOU"_ (edge) — code is correct; the doc wording is verbatim from the ratified spec (AC-2a).
6. _"`Ok(None)` tests walk TMPDIR→`/` (cross-env isolation)"_ (edge) — TMPDIR is `/var/folders/…` (outside `$HOME`); established crate convention (`tests/detect.rs`); the ceiling protects it anyway.
7. _"Stale count comment"_ (acceptance-auditor framing) — same underlying issue as the patch above; merged.
8. _"Duplicated Jj/Git match arms could collapse to `k @ (Jj | Git)`"_ (critic) — optional cosmetic; the expanded two-arm form is mandated verbatim by the story's copy-adaptable skeleton and AC-10 names both arms as distinct coverage targets; clippy pedantic clean.
9. _"Doc claims accurate"_ (critic) — self-declared negative result (no defect); independently re-verified clean.
