---
baseline_commit: 07ae68b9f92ada3408094717a508c3cfa8dac99a
---

# Story 2.11: Implement `detect.rs` — repository-kind detection

Status: done

<!-- Note: Validation is optional. Run validate-create-story for quality check before dev-story. -->

## Story

As a Rust caller powering the open-project flow,
I want `zanshin-jj` to classify a filesystem path as a jj workspace, a (convertible) Git repo, neither, or a missing path,
So that the Flutter UI can open directly, offer a "convert this Git project to jj?" dialog, or report "not a repository" — without the backend deciding for the user (FR-JJ-17).

> **Scope boundary (read first):** This is a **PURE `zanshin-jj` Rust** story. It is **stat-only** and touches **NO `jj_lib`** at all — `detect` is implemented entirely with `std::path`/`std::fs`. Do **not** add any `extern "C"` / FFI code: the FFI exposure (`zanshin_repo_detect`) is a **separate** story, **3.4c** (status `backlog`), which depends on this one. Do **not** implement Story 2.12 conversion (`convert.rs`) here. One module, one enum, one free function, one test file, plus the lib.rs + api-stability wiring. (project-context.md § "Simplicity First", § "Surgical Changes")

## Acceptance Criteria

> All `epics.md` line cites are from `_bmad-output/planning-artifacts/epics.md` (Story 2.11, lines 1594-1652).

### AC-1 — Module + public surface (FR-JJ-17) [epics.md:1604-1607]

**Given** `crates/zanshin-jj/src/detect.rs`
**When** created
**Then** it defines `pub enum RepoKind { Jj, Git, Neither, PathNotFound }`, `pub fn detect_repo(path: &Path) -> Result<RepoKind, DetectError>`, and a `DetectError` error type
**And** `RepoKind` derives `Debug`, `Clone`, `Copy`, `PartialEq`, `Eq`.

### AC-2 — Missing: path does not exist [epics.md:1609-1611]

**Given** `detect(path)`
**When** the path does not exist
**Then** it returns `Ok(RepoKind::PathNotFound)`.

### AC-3 — Jj: `.jj/` directory present (colocated counts as Jj) [epics.md:1613-1615]

**Given** `detect(path)`
**When** the path contains a `.jj/` **directory** (whether or not a `.git/` is also present — a colocated repo **is** a jj repo)
**Then** it returns `RepoKind::Jj`.

### AC-4 — Git: `.git` entry present, no `.jj/` [epics.md:1617-1619]

**Given** `detect(path)`
**When** the path contains a `.git/` **entry** (directory **or** file) but no `.jj/` directory
**Then** it returns `RepoKind::Git`.

### AC-5 — Neither: exists, but no `.jj/` and no `.git` [epics.md:1621-1623]

**Given** `detect(path)`
**When** the path exists but contains neither `.jj/` nor `.git`
**Then** it returns `RepoKind::Neither`.

### AC-6 — Stat-only, no load, no mutation, no panic, cheap [epics.md:1625-1628]

**Given** `detect`
**When** called on any path
**Then** it is **stat-only** — it never loads the workspace, never creates or modifies anything on disk, and **never panics**
**And** it is cheap enough to call on every folder the user browses in a file picker (a handful of `stat(2)` calls, no `Workspace::load`, no I/O beyond metadata).

### AC-7 — Re-export + `jj_lib`-free signature + surface-lock [epics.md:1630-1633]

**Given** the public API
**When** inspected
**Then** `RepoKind` and `detect` are re-exported from `lib.rs` (`pub use detect::{detect, RepoKind};`, with `pub(crate) mod detect;`)
**And** no `jj_lib` (or `gix`) type appears in the signature (it has none — the fn signature is `(&Path) -> RepoKind`)
**And** `crates/zanshin-jj/tests/api_stability.rs` is updated to bind the new surface (a `type _RepoKind = zanshin_jj::RepoKind;` alias, a `detect as fn(&std::path::Path) -> zanshin_jj::RepoKind` fn-pointer binding, and a trivially-constructible `RepoKind::Jj` value), and its "(24 types …)" comment is corrected to 25.

### AC-8 — Integration-test coverage: the five baseline cases [epics.md:1635-1637]

**Given** integration tests in `crates/zanshin-jj/tests/detect.rs`
**When** they run
**Then** they assert all five baseline classifications:
1. the `tiny-3-commits` fixture → `Jj`
2. a bare `git init` dir (fixture-setup may shell to `git` — AR-AP-1 applies to **production** code only) → `Git`
3. an empty tmpdir → `Neither`
4. a nonexistent path → `Missing`
5. a colocated dir (`.jj/` + `.git/`, both directories) → `Jj`.

### AC-9 — Edge: `.jj` is a regular file (corruption) → not Jj [epics.md:1641-1644]

**Given** a `.jj` that is a **regular file**, not a directory
**When** `detect` is called
**Then** it does **not** classify the path as `Jj` (it falls through to `Git` or `Neither` by the `.git` check)
**And** the behaviour is documented in the `detect` doc comment — `detect` reports **structural presence**, not integrity; integrity is `Repo::open`'s job.

### AC-10 — Edge: `.git` is a file with a `gitdir:` pointer (worktree/submodule) → Git [epics.md:1646-1648]

**Given** a `.git` that is a **file** containing a `gitdir:` pointer (git worktree / submodule)
**When** `detect` is called
**Then** it still returns `RepoKind::Git` (it is a git working tree).

### AC-11 — Edge: symlinked `.jj`/`.git` followed to target [epics.md:1650-1652]

**Given** `.jj` or `.git` is a symlink
**When** `detect` is called
**Then** the link is **followed** and the path is classified by the target (a `.jj` symlink → directory ⇒ `Jj`; a `.git` symlink → existing target ⇒ `Git`). This is the default behaviour of `Path::is_dir()` / `Path::exists()` (both `stat`, not `lstat`) — do not add manual symlink resolution.

### AC-12 — Quality gate green incl. coverage ratchet [CLAUDE.md; docs/coverage.md]

**Given** the change is complete
**When** `cargo make test` runs
**Then** it passes end-to-end: `cargo test`, clippy (pedantic, `-D warnings`), rustfmt, `dart analyze`/`format`, `cargo deny`, **and** the coverage ratchet
**And** `crates/zanshin-jj/src/detect.rs` (a new file) meets the new-file floor and in practice reaches ~100% line coverage (every `RepoKind` return branch is exercised by AC-8/AC-9/AC-10/AC-11)
**And** the auto-raised `coverage-baseline.txt` is committed in the same change.

## Tasks / Subtasks

- [x] **Task 1 — Create `src/detect.rs`** (AC: 1, 6, 9, 11)
  - [x] Add `// SPDX-License-Identifier: MIT` as the **first line**.
  - [x] Define `pub enum RepoKind { Jj, Git, Neither, Missing }` with `#[derive(Debug, Clone, Copy, PartialEq, Eq)]`. Doc-comment the enum **and every variant** (`#![deny(missing_docs)]` is on at the crate root — missing docs is a compile error).
  - [x] Implement `pub fn detect(path: &Path) -> RepoKind` per the skeleton in Dev Notes → "Copy-adaptable skeleton". Doc-comment it, including the **structural-presence-not-integrity** note (AC-9) and the **symlinks-followed** note (AC-11).
  - [x] Keep it stat-only: only `path.exists()`, `path.join(".jj").is_dir()`, `path.join(".git").exists()`. No `Workspace::load`, no `canonicalize().unwrap()`, no `fs::read_dir`, no panics.
- [x] **Task 2 — Wire `lib.rs`** (AC: 1, 7)
  - [x] Add `pub(crate) mod detect;` to the module list.
  - [x] Add `pub use detect::{detect, RepoKind};` to the re-export list.
- [x] **Task 3 — Update the surface-lock test** (AC: 7)
  - [x] In `crates/zanshin-jj/tests/api_stability.rs`: add `type _RepoKind = zanshin_jj::RepoKind;` (a `// detect` section), add a fn-pointer binding `_ = zanshin_jj::detect as fn(&std::path::Path) -> zanshin_jj::RepoKind;` inside `api_surface_resolves`, and a trivially-constructible value `_ = zanshin_jj::RepoKind::Jj;`.
  - [x] Bump the header comment "(24 types, AC-1 table)" → "(25 types, AC-1 table)" so the count stays accurate (Story 2.10 review flagged exactly this kind of count drift).
- [x] **Task 4 — Integration tests `tests/detect.rs`** (AC: 2, 3, 4, 5, 8, 9, 10, 11)
  - [x] `// SPDX-License-Identifier: MIT` first line.
  - [x] Mirror the helper style of `tests/repo.rs`: reuse `tempfile::TempDir`, `test_helpers::extract_fixture`, and a local `git(args, dir)` shell helper for the bare-git case. Do **not** import `jj_lib` (integration tests don't get the lib's regular deps).
  - [x] Pin env like the other suites if you touch jj at all — **not needed here** (detect never reads config), so skip `pin_env()` unless you also exercise the fixture's openability. Keep tests minimal.
  - [x] Baseline cases (AC-8): tiny fixture → `Jj`; `git init` dir → `Git`; empty tmpdir → `Neither`; nonexistent path → `Missing`; manual `.jj/`+`.git/` dirs → `Jj`.
  - [x] Edge cases: `.jj` as a regular **file** (alone) → `Neither` and (`.jj` file + `.git` dir) → `Git` (AC-9); `.git` as a **file** containing `gitdir: …` → `Git` (AC-10); symlinked `.jj` → dir ⇒ `Jj` and symlinked `.git` → existing target ⇒ `Git` via `std::os::unix::fs::symlink` (AC-11).
- [x] **Task 5 — Gate** (AC: 12)
  - [x] Run `cargo make test`; make it green.
  - [x] Commit the auto-raised `coverage-baseline.txt` alongside the code. **Never** lower the baseline or add an `exclude_prefix` to pass (CLAUDE.md, review-blocking).

## Dev Notes

### Decision D1 — The `is_dir()` vs `exists()` asymmetry is the whole story. Get it exactly right.

This single line-pair is where a careless implementation fails the ACs:

- `.jj` check uses **`is_dir()`** → a `.jj` that is a *regular file* (corruption) must **not** count as Jj (AC-9). `is_dir()` returns `false` for a file. ✅
- `.git` check uses **`exists()`** → a `.git` that is a *file* (worktree/submodule `gitdir:` pointer) **must** count as Git (AC-10). `exists()` returns `true` for a file. ✅

Do **not** "normalise" both to `is_dir()` (breaks AC-10) or both to `exists()` (breaks AC-9). The asymmetry is intentional and load-bearing. Both `Path::is_dir()` and `Path::exists()` `stat` the target (follow symlinks), which is exactly what AC-11 wants — so symlink-following is free; do not add manual `read_link`/`symlink_metadata` logic.

### Decision D2 — `detect` is infallible: returns `RepoKind`, not `Result`.

Detection is a **classification**, not a fallible operation. "Missing" and "Neither" are *normal results*, not errors (this mirrors the FFI framing in 3.4c's epic: epics.md:2119-2121 "missing / neither are normal results, NOT errors"). Therefore:

- **No new error type.** Do not add a `DetectError`. Do not return `Result`.
- **No `# Errors` doc section** (there are none). `#[must_use]` on the fn is reasonable (the return value is the entire point) but not required by an AC — match the crate's taste; the other read fns use `#[must_use]` on their `Result`s, here a plain `#[must_use]` on the enum-returning fn is fine.

### Decision D3 — Zero `jj_lib`. This is a `std`-only module.

`detect` does **not** load a workspace — that is precisely *why* it exists (the open-project flow needs to classify *before* attempting a load that would collapse "empty folder", "random folder", and "a Git repo" all into `NotARepo`; see epics.md:1596). So:

- No `use jj_lib::…` in `detect.rs`. (The `test-jj-adapter-hygiene` Makefile gate greps `src/` for `jj_lib` leaks; a `detect.rs` with zero `jj_lib` is trivially clean.)
- The README "Adding new functionality" steps 2 & 4 (import `jj_lib`, map its errors) are **N/A** here — there is nothing to map. Steps 1, 3, 5, 6 (new module, crate-owned type, re-export, no `pub use jj_lib`) do apply.

### Decision D4 — Branch order: Missing → Jj → Git → Neither.

Check existence first so a nonexistent path is `Missing` (AC-2), not `Neither`. Then Jj (AC-3) before Git (AC-4) so a **colocated** repo (`.jj/` + `.git/`) classifies as `Jj` (AC-3 explicit). `Neither` is the fall-through (AC-5).

A path that **exists but is a plain file** (not a directory): `path.exists()` is `true`, `path.join(".jj").is_dir()` and `path.join(".git").exists()` are both `false` ⇒ `Neither`. That is acceptable and consistent with "exists but no repo markers" — no special "not a directory" kind exists in the 4-variant enum. (See Open Question OQ1 if you want to confirm with Ralph; the chosen default is `Neither`.)

### Copy-adaptable skeleton for `detect.rs`

```rust
// SPDX-License-Identifier: MIT

//! Repository-kind detection (FR-JJ-17).
//!
//! Stat-only classification of a filesystem path for the open-project flow.
//! Reports *structural presence* of repo markers, **not** integrity — a
//! structurally-present but corrupt repo is `Repo::open`'s problem, not this
//! module's. Never loads a workspace, never mutates the filesystem, never panics.

use std::path::Path;

/// How a filesystem path looks to the open-project flow.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RepoKind {
    /// Contains a `.jj/` directory — a jj workspace (colocated repos count as Jj).
    Jj,
    /// Contains a `.git` entry but no `.jj/` directory — a (convertible) Git repo.
    Git,
    /// Exists but contains neither `.jj/` nor `.git`.
    Neither,
    /// The path does not exist.
    Missing,
}

/// Classifies `path` as a jj workspace, a Git repo, neither, or missing (FR-JJ-17).
///
/// Stat-only and cheap enough to call on every folder in a file picker. Reports
/// *structural presence*, not integrity: a `.jj` that is a regular file (not a
/// directory) is treated as corruption and does **not** classify as [`RepoKind::Jj`]
/// — integrity is [`crate::Repo::open`]'s job. Symlinked `.jj`/`.git` entries are
/// followed to their target (`stat`, not `lstat`). Never panics.
#[must_use]
pub fn detect(path: &Path) -> RepoKind {
    if !path.exists() {
        return RepoKind::Missing;
    }
    if path.join(".jj").is_dir() {
        return RepoKind::Jj;
    }
    if path.join(".git").exists() {
        return RepoKind::Git;
    }
    RepoKind::Neither
}
```

That is the entire production implementation. Resist the urge to add anything (project-context.md § "Simplicity First": "If you write 200 lines and it could be 50, rewrite it" — here it's ~15).

### Test recipe — mirror `tests/repo.rs`, do NOT invent a new harness

`tests/repo.rs` already establishes the exact helpers you need; copy their style:

- `tempfile::TempDir::new()` for scratch dirs.
- `test_helpers::extract_fixture("tiny-3-commits")` → `FixtureHandle { path }` (field, auto-deleted on drop) for the Jj happy path.
- A local `fn git(args: &[&str], dir: &Path)` that shells `git` and asserts success (verbatim from `tests/repo.rs:222-229`) for the `git init` case. Shelling to `git` in **tests** is allowed (AR-AP-1 / NFR-R-1 bans shelling only in *production* code).
- For colocated / corruption / pointer / symlink edges, build the markers directly with `std::fs` — **no jj-lib, no git needed**:
  - colocated: `fs::create_dir(dir.join(".jj"))` + `fs::create_dir(dir.join(".git"))` → `Jj`.
  - `.jj`-as-file: `fs::write(dir.join(".jj"), b"not a dir")` (alone → `Neither`; plus a `.git` dir → `Git`).
  - `.git`-as-file pointer: `fs::write(dir.join(".git"), b"gitdir: ../whatever/.git/worktrees/x\n")` → `Git` (content need not be valid; detect is structural).
  - symlinks: `std::os::unix::fs::symlink(target, dir.join(".jj"))` — macOS-only project, `unix::fs::symlink` is fine. Point `.jj` at a real dir (⇒ `Jj`); point `.git` at a real existing path (⇒ `Git`).
- Naming: scenario-describing (`detect_tiny_fixture_returns_jj`, `detect_colocated_dir_returns_jj`, `detect_dot_jj_regular_file_is_not_jj`, `detect_symlinked_dot_jj_dir_returns_jj`, …) per project-context Naming rule.

You do **not** need `pin_env()` here — `detect` never reads jj/git config. Add it only if a test also calls `Repo::open` (none need to).

### Coverage note

`detect.rs` is a **new file** → must clear the new-file floor (`docs/coverage.md`). The four `return` branches map 1:1 to AC-2 (Missing), AC-3 (Jj), AC-4 (Git), AC-5 (Neither); the AC-8 baseline + AC-9/10/11 edges exercise all four ⇒ ~100% line coverage. There is **no FFI/extern coverage trap here** — that trap (a `no_mangle` fn only hit by cargo-test, needing a `zanshin_core` cdylib round-trip) belongs to the wrapper stories (3.4b/3.4c), not to this pure-Rust module. `cargo make coverage` auto-raises the baseline; commit it. Do not lower the floor or add an `exclude_prefix`.

### Previous-story intelligence (2.4–2.10) — pre-empt the known traps

- **Surface-lock test is now load-bearing (Story 2.10).** `tests/api_stability.rs` enumerates the full public surface and **won't compile** if a re-export is missing — but it also won't *know* about a new type unless you add it. Adding `RepoKind`/`detect` without updating that test means the new surface is unguarded; the 2.10 review explicitly cares about this. Update it (Task 3). Also fix the "24 types" → "25 types" comment — 2.10's review applied a patch for exactly this kind of stale count.
- **`#![deny(missing_docs)]` (Story 2.10) is a hard compile gate.** Every `pub` item — the enum, **each variant**, and the fn — needs a `///`. Omitting a variant doc is a build failure, not a lint.
- **Doc-comment accuracy is reviewed against ground truth.** The 2.6/2.9 reviews patched doc comments that over- or mis-stated behaviour. Keep the `detect` doc precise: "structural presence, not integrity" and "symlinks followed" must match the code (they do, in the skeleton).
- **Scope discipline.** 2.8/2.9 deferred the Remote re-export to the right story rather than pulling it forward. Mirror that: do **not** start 2.12 (`convert.rs`) or 3.4c (FFI) here, even though they're adjacent in `repo.rs`/the epic.

### Files this story touches

| File | Action | What |
|------|--------|------|
| `crates/zanshin-jj/src/detect.rs` | **NEW** | `RepoKind` enum + `detect()` fn (the skeleton above) |
| `crates/zanshin-jj/src/lib.rs` | UPDATE | `pub(crate) mod detect;` + `pub use detect::{detect, RepoKind};` |
| `crates/zanshin-jj/tests/detect.rs` | **NEW** | integration tests (baseline + edges) |
| `crates/zanshin-jj/tests/api_stability.rs` | UPDATE | bind `RepoKind` + `detect`; fix the type-count comment |
| `coverage-baseline.txt` | UPDATE (auto) | commit the auto-raised baseline |

No `Cargo.toml` change (no new deps — `tempfile` + `test-helpers` dev-deps already present). No codegen, no error-registry change, no `schemas/*.fbs` change, no FFI. No `RepoError` change (detect is infallible).

### Hard rules in scope (project-context.md — reject-at-review on violation)

- **No shelling to `jj` in production code** (NFR-R-1, FR-JJ-16). `detect` doesn't shell at all; tests may shell `git` only.
- **No `extern "C"` outside `crates/zanshin-ffi/`** — none here; FFI is 3.4c.
- **No `unwrap()`/`expect()`/`panic!()` on the library path.** `detect` has none (the skeleton can't panic). Tests may `expect()`.
- **No `jj_lib` type in a public position** (FR-JJ-16) — the signature is `(&Path) -> RepoKind`; clean.
- **SPDX first line** on both new `.rs` files.
- **rustfmt `max_width = 100`, clippy pedantic `-D warnings`.**
- **Coverage ratchet: add tests, never lower the baseline.**

### Project Structure Notes

- Module-by-noun layout (project-context.md § File & module organization): `detect.rs` sits beside `repo.rs`, `status.rs`, `change.rs`, `op_log.rs`, `bookmarks.rs`, `remotes.rs`, `revset.rs` — consistent. No `mod.rs`.
- Re-export pattern matches the existing `lib.rs` (`pub use <noun>::{…}`). `pub(crate) mod detect;` matches the sibling `pub(crate) mod`s (only `repo` is bare `mod`; either is acceptable, but `pub(crate)` mirrors the majority and the `detect` items are re-exported anyway).
- Tests live in `tests/detect.rs` (integration: exercises the public API + a real fixture) per CLAUDE.md test-placement rule and the epic's explicit path (epics.md:1635). `detect` has no private items needing inline `#[cfg(test)]` unit tests, so none are added.

### References

- [Story 2.11 ACs + edge cases](_bmad-output/planning-artifacts/epics.md) — epics.md:1594-1652
- [FR-JJ-17 (detection)](_bmad-output/planning-artifacts/prd.md) — prd.md:214
- [Epic 2 scope incl. FR-JJ-17](_bmad-output/planning-artifacts/epics.md) — epics.md:341, 380 (prd.md)
- [Story 3.4c — FFI exposure of detect/convert (NOT this story)](_bmad-output/planning-artifacts/epics.md) — epics.md:2101-2143
- [Story 2.12 — convert.rs (NOT this story)](_bmad-output/planning-artifacts/epics.md) — epics.md:1656-1713
- [`zanshin-jj/src/lib.rs`](crates/zanshin-jj/src/lib.rs) — re-export surface + `#![deny(missing_docs)]`
- [`zanshin-jj/src/repo.rs`](crates/zanshin-jj/src/repo.rs) — `Repo::open`'s `.jj`-dir check (the integrity counterpart to `detect`'s structural check)
- [`zanshin-jj/tests/repo.rs`](crates/zanshin-jj/tests/repo.rs) — `git()` + `TempDir` + `extract_fixture` test-helper patterns to mirror
- [`zanshin-jj/tests/api_stability.rs`](crates/zanshin-jj/tests/api_stability.rs) — surface-lock test to extend
- [`test-helpers/src/lib.rs`](crates/test-helpers/src/lib.rs) — `extract_fixture` → `FixtureHandle { pub path }`
- [project-context.md](_bmad-output/project-context.md) — canonical ruleset (FR-JJ-16, simplicity, coverage ratchet)
- [docs/coverage.md](docs/coverage.md) — coverage ratchet mechanism + new-file floor

## Dev Agent Record

### Agent Model Used

claude-sonnet-4-6

### Debug Log References

None — implementation was straightforward. Only issue was a rustfmt ordering difference (modules and re-exports inserted before the alphabetically-first sibling; resolved by `cargo fmt`), and `extract_fixture` returning `Result` requiring `.unwrap()` (fixed immediately after first compile error).

### Completion Notes List

- Created `crates/zanshin-jj/src/detect.rs`: `RepoKind` enum (4 variants, all doc-commented) + `detect(&Path) -> RepoKind` (stat-only, `#[must_use]`, infallible). Exactly the Dev Notes skeleton — 15 lines of production code.
- Wired `lib.rs`: `pub(crate) mod detect;` + `pub use detect::{detect, RepoKind};`.
- Updated `tests/api_stability.rs`: added `// detect` section with type alias, bumped count comment 24 → 25 types, added fn-pointer binding and `RepoKind::Jj` value inside `api_surface_resolves`.
- Created `tests/detect.rs`: 11 tests covering all 5 baseline classifications (AC-8), both `.jj`-as-file corruption cases (AC-9), `.git`-pointer-file case (AC-10), and both symlink cases (AC-11). Mirrors `tests/repo.rs` helper style.
- `cargo make test` green: all tests pass, clippy pedantic clean, rustfmt clean, `detect.rs` reaches 100% line coverage, baseline auto-raised (97.72% → 97.74%).

### File List

- `crates/zanshin-jj/src/detect.rs` (NEW)
- `crates/zanshin-jj/src/lib.rs` (MODIFIED)
- `crates/zanshin-jj/tests/detect.rs` (NEW)
- `crates/zanshin-jj/tests/api_stability.rs` (MODIFIED)
- `coverage-baseline.txt` (MODIFIED — auto-raised by ratchet)

### Change Log

- 2026-06-26: Story 2.11 implemented — `detect.rs` + `RepoKind` enum + `detect()` fn + integration tests + surface-lock update + coverage baseline raised.
- 2026-06-26: Code review (bmad-code-review) — 0 correctness/safety/AC defects, all 12 ACs PASS, 9/12 findings refuted, 3 nits resolved. Applied: OQ1 pin test (`Neither`), dangling-`.git`-symlink test, `Missing` doc tweak (EACCES). Renamed `detect` → `detect_repo` per Ralph. `cargo make test` green.
- 2026-06-26: Post-review design change (Ralph) — **Design B**: `detect_repo` → `Result<RepoKind, DetectError>`; `RepoKind::Missing`→`PathNotFound`; `EACCES`/`ENOTDIR` → `Err` via `Path::try_exists()` (makes 3.4c `jj.detect_failed` reachable). Added `DetectError` + Err-arm test; the EACCES doc-tweak is superseded. `epics.md` reconciled (`Missing`→`PathNotFound`, signature→`Result`). `cargo make test` green, `detect.rs` 100%, coverage 97.74% held.

## Open Questions for Ralph (non-blocking — defaults chosen, override before dev if desired)

1. **A path that exists but is a plain *file* (not a directory)** → current default returns `RepoKind::Neither` (it has no `.jj`/`.git` markers; the 4-variant enum has no "not a directory" kind). Acceptable, or do you want a file-path to be `Missing`-like? **Default: `Neither`.**
2. **Inline unit tests vs `tests/detect.rs` only** — the epic specifies `tests/detect.rs`, and `detect` has no private items, so all tests live there (no inline `#[cfg(test)]`). **Default: integration tests only.** Override if you want a redundant inline smoke for coverage robustness (not needed — integration tests already hit 100%).
3. **`#[must_use]` on `detect`** — added (the classification *is* the result; ignoring it is almost always a bug). Harmless; say if you'd rather omit it. **Default: keep `#[must_use]`.**

## Review Findings

_bmad-code-review 2026-06-26 (5-layer adversarial review — Blind Hunter, Edge Case Hunter, Acceptance Auditor, Project-Rules, Test-Quality — + per-finding adversarial verification + synthesis; 18 agents). **All 12 ACs PASS, D1–D4 honored, `cargo make test` reported green, `detect.rs` 100% line coverage. 0 correctness / safety / acceptance-criteria defects.** 12 raw findings → 9 dismissed as refuted/immaterial, 3 surviving nits (all optional polish, none merge-blocking)._

**Resolution (2026-06-26, Ralph):** decision resolved, both patches applied, plus two Ralph-directed follow-ups (rename `detect`→`detect_repo`, then **Design B** — fallible `Result<RepoKind, DetectError>` + `RepoKind::Missing`→`PathNotFound`); `cargo make test` re-run green after each.

- [x] [Review][Decision] OQ1 plain-file-path classification — **resolved: keep `Neither`** (a regular file is never a repo; `Missing` would be wrong since the path *exists*). Pinned by new test `detect_regular_file_path_returns_neither`. [crates/zanshin-jj/tests/detect.rs]
- [x] [Review][Patch] Dangling `.git` symlink (target nonexistent) → `Neither` — **applied**: new test `detect_dangling_dot_git_symlink_returns_neither` locks the classify-by-target half of AC-11. [crates/zanshin-jj/tests/detect.rs]
- [x] [Review][Patch] `RepoKind::Missing` doc-tweak (EACCES) — **superseded by Design B**: rather than documenting that `EACCES` collapses to the not-found kind, `detect_repo` now returns `Err(DetectError::Io)` for genuine stat errors, and the not-found kind is `PathNotFound` (strictly absent). [crates/zanshin-jj/src/detect.rs]
- [x] [Review][Change] **Two Ralph-directed follow-ups (2026-06-26):** (1) function renamed `detect` → `detect_repo` (call-site clarity / avoid accidental misuse); (2) **Design B** — `detect_repo` now returns `Result<RepoKind, DetectError>` (was infallible `-> RepoKind`), the not-found variant renamed `RepoKind::Missing` → `RepoKind::PathNotFound`, and a genuine stat I/O error (`EACCES`/`ENOTDIR`, detected via `Path::try_exists()`) is `Err(DetectError::Io)` instead of silently collapsing to the not-found kind. This makes Story 3.4c's `jj.detect_failed` reachable. Added `DetectError` (re-exported) + Err-arm test (`detect_path_under_a_regular_file_returns_io_error`, ENOTDIR). Updated: `detect.rs`, `lib.rs`, `tests/detect.rs`, surface-lock `tests/api_stability.rs` (25→26 types). Unchanged: module/file `detect.rs`. **Reconciliation:** `epics.md` reconciled 2026-06-26 (Stories 2.11/2.12/2.13/3.4c — `detect`→`detect_repo`, `Missing`→`PathNotFound`, signature→`Result`; FFI name `zanshin_repo_detect` kept; Story 2.14 not in epics.md). AC-1/AC-2 above were updated to the final shape; the remaining AC/Dev-Notes prose predates these follow-ups and should be read accordingly.
