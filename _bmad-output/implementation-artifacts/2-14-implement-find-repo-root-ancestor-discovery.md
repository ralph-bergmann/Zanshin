# Story 2.14: Implement `find_repo_root` — ancestor repository discovery (consent-gated walk-up)

Status: ready-for-dev

<!-- Note: Validation is optional. Run validate-create-story for quality check before dev-story. -->

## Story

As a Rust caller powering the open-project flow (Flutter UI **and** the MCP server),
I want `zanshin-jj` to walk **up** from a chosen path to the nearest enclosing jj/Git repository root and report it,
So that when the user (or an MCP invocation) points at a **sub-directory** of a repo — not the root — the surface can offer "this folder is inside a repo at `<root>` — open that?" instead of falsely reporting "not a repository", **without the backend silently retargeting** (the choice stays with the UI / the human running MCP).

> **Why this exists (research-backed):** `detect()` (Story 2.11) classifies a **single** directory — correct, but it returns `Neither` for a sub-directory of a repo. The research doc `technical-repository-discovery-walkup-and-jj-marker-depth-research-2026-06-26.md` established that **every** jj client (jj-CLI `find_workspace_dir`, the `gg` GUI) and **every** editor (VS Code, JetBrains, Zed) walks **up** to the enclosing root, because `jj-lib`'s `Workspace::load` does **not** (it requires the exact root). This story adds that walk-up as a small, additive helper *above* `detect()` — exactly mirroring `gg`'s `find_workspace_dir(cwd) = cwd.ancestors().find(|p| p.join(".jj").is_dir())`.

> **Scope boundary (read first):** This is a **PURE `zanshin-jj` Rust** story, **stat-only**, **ZERO `jj_lib`** (std-only, like `detect.rs`). It adds **one struct + one free function** to `detect.rs`, plus the `lib.rs` re-export + api-stability wiring + a new integration test file. It does **NOT** add FFI (the UI consumes this via Story **3.4c**, which is extended — see Dev Notes → "Consumer contract") and does **NOT** add MCP wiring (the MCP server consumes it via Story **7-1**, also extended). It does **NOT** implement walk-up *policy* knobs (ceiling dirs, filesystem-boundary stop) beyond the documented default. (project-context.md § "Simplicity First", § "Surgical Changes")

## Acceptance Criteria

> Driver: research doc `_bmad-output/planning-artifacts/research/technical-repository-discovery-walkup-and-jj-marker-depth-research-2026-06-26.md` (Q1/Q2 + recommendation §2). Marker semantics inherited verbatim from Story 2.11 `detect()`. FR family: FR-JJ-17 (detection).

### AC-1 — `RepoRoot` type + `find_repo_root` signature

**Given** `crates/zanshin-jj/src/detect.rs`
**When** extended
**Then** it defines `pub struct RepoRoot { pub root: PathBuf, pub kind: RepoKind }` deriving `Debug, Clone, PartialEq, Eq`
**And** `pub fn find_repo_root(start: &Path) -> Option<RepoRoot>`
**And** the `kind` field is documented to only ever be `RepoKind::Jj` or `RepoKind::Git` (never `Neither`/`Missing`).

### AC-2 — Nearest enclosing root wins (composes `detect`)

**Given** `find_repo_root(start)`
**When** called
**Then** it evaluates `start` first, then each ancestor of `start` (toward the filesystem root), and returns the **first** (nearest) directory whose `detect()` is `Jj` or `Git`, packaged as `RepoRoot { root: <that dir>, kind: <Jj|Git> }`
**And** it reuses `detect()` at each level (inheriting the exact `.jj`-is-`dir` / `.git`-`exists` semantics, AC-9..AC-11 of Story 2.11) — it does **not** re-implement the marker check.

### AC-3 — `start` itself counts (direct-hit case)

**Given** `find_repo_root(start)`
**When** `start` is itself a repo (`detect(start)` is `Jj` or `Git`)
**Then** it returns `Some(RepoRoot { root == start, kind })` — i.e. `root == start` signals "open directly, no suggestion needed".

### AC-4 — No enclosing repo → `None`

**Given** `find_repo_root(start)`
**When** neither `start` nor any ancestor up to the filesystem root is a repo
**Then** it returns `None`.

### AC-5 — Jj precedence at a colocated level (inherited)

**Given** an ancestor that is colocated (`.jj/` + `.git/`)
**When** it is the nearest match
**Then** the returned `kind` is `Jj` (inherited from `detect()`'s AC-3 ordering).

### AC-6 — Stat-only, std-only, no `jj_lib`, no panic; bounded by the `$HOME` ceiling

**Given** `find_repo_root`
**When** called on any path
**Then** it is **stat-only** (only the `stat(2)` calls `detect()` already makes per level), never loads a workspace, never mutates, and **never panics**
**And** it imports **no** `jj_lib` (the `test-jj-adapter-hygiene` grep gate stays clean)
**And** the upward walk stops at the **first repo found**, otherwise **before reaching `$HOME` or any directory above it** — the `$HOME` **ceiling** (JetBrains-style), so a dotfiles repo at `~` is not surfaced when opening an unrelated folder under home
**And** the ceiling bounds the walk-**up only**: `start` itself is **always** classified even when `start == $HOME` (explicitly opening `~` still finds `~/.jj`/`~/.git`) — cf. git's `GIT_CEILING_DIRECTORIES` "will not exclude the current working directory". Precisely: a directory is "`$HOME` or above" iff `home.starts_with(dir)`; the walk stops there, except for `start` itself
**And** `$HOME` is read from the `HOME` env var (macOS always sets it); when unset, the walk degrades to the filesystem root. The ceiling is **injectable via a crate-private fn** so it is unit-testable without depending on the real `$HOME`
**And** there is **no** filesystem-boundary/mount guard (lower priority for a single-disk macOS GUI).

> **Ceiling semantics (Ralph-confirmed 2026-06-26):** the ceiling only has any effect when `start` is **under** `$HOME` (only then is `$HOME` on the ancestor chain) — e.g. from `~/dev/.../Zanshin/schemas` it prevents climbing to `~`, but it never truncates before finding a project repo lower down. For a `start` **outside** `$HOME` (e.g. `/foo/bar/dev/projekt/bla`), `$HOME` is not an ancestor, so the ceiling has no effect and the walk proceeds up the tree as normal.

### AC-7 — Consent-gated contract documented

**Given** the `find_repo_root` doc comment
**When** read
**Then** it documents the **consent-gated** usage explicitly: the caller compares `root` against `start` — `root == start` ⇒ open directly; `root != start` ⇒ the result is a **suggestion** of an enclosing repo that the consumer must **surface for confirmation** (UI prompt / MCP message), and that the backend **never** silently opens the ancestor.

### AC-8 — Re-export + `jj_lib`-free signature + surface-lock

**Given** the public API
**When** inspected
**Then** `RepoRoot` and `find_repo_root` are re-exported from `lib.rs` (`pub use detect::{detect, find_repo_root, RepoKind, RepoRoot};`)
**And** no `jj_lib` (or `gix`) type appears in the signature (`(&Path) -> Option<RepoRoot>`, and `RepoRoot` is crate-owned)
**And** `crates/zanshin-jj/tests/api_stability.rs` is updated: a `type _RepoRoot = zanshin_jj::RepoRoot;` alias (under the `// detect` section), a fn-pointer binding `_ = zanshin_jj::find_repo_root as fn(&std::path::Path) -> Option<zanshin_jj::RepoRoot>;`, and a trivially-constructible value `_ = zanshin_jj::RepoRoot { root: std::path::PathBuf::new(), kind: zanshin_jj::RepoKind::Jj };`; the header count comment is corrected **25 → 26**.

### AC-9 — Test coverage (integration + inline unit)

**Given** integration tests in `crates/zanshin-jj/tests/find_repo_root.rs` (public `find_repo_root`) **and** inline `#[cfg(test)]` unit tests in `src/detect.rs` (private `find_repo_root_within`, for the ceiling)
**When** they run
**Then** they assert at least:
1. `start` is the `tiny-3-commits` fixture root → `Some(root == start, Jj)`.
2. `start` is a **sub-directory** of a jj workspace → `Some(root == workspace root, Jj)` and `root != start` (the consent-gated suggestion case).
3. `start` is a **sub-directory** of a `git init` dir (no `.jj`) → `Some(root == git root, Git)`.
4. **Deep nesting / nearest wins:** an inner jj workspace nested inside an outer repo → returns the **inner** (nearest) root, not the outer.
5. No repo at/above `start` (a tmpdir with no markers, no markers above within the tmp tree) → `None`.
6. Non-existent `start` whose lexical ancestors contain no repo → `None`.
7. Colocated (`.jj/` + `.git/`) nearest level → `Some(.., Jj)`.
8. **`$HOME` ceiling** (inline unit tests on `find_repo_root_within` with an injected temp ceiling `C`): (a) start below `C` with a repo marker only **at `C`** → `None` (dotfiles-at-`~` analog, not surfaced); (b) start **== `C`** and `C` is a repo → `Some(root == C)` (start carve-out); (c) `ceiling = None` → finds a repo above where the ceiling would have stopped (covers the `is_none_or` None arm); (d) a repo **strictly below** `C` → still found.

### AC-10 — Quality gate green incl. coverage ratchet

**Given** the change is complete
**When** `cargo make test` runs
**Then** it passes end-to-end (`cargo test`, clippy pedantic `-D warnings`, rustfmt, dart analyze/format, `cargo deny`, **and** the coverage ratchet)
**And** the new `find_repo_root` / `RepoRoot` lines in `detect.rs` reach the per-file floor (in practice ~100% — every `match` arm + the `None` fall-through is exercised by AC-9)
**And** the auto-raised `coverage-baseline.txt` is committed in the same change.

## Tasks / Subtasks

- [ ] **Task 1 — Extend `src/detect.rs`** (AC: 1, 2, 3, 4, 5, 6, 7)
  - [ ] Change `use std::path::Path;` → `use std::path::{Path, PathBuf};`.
  - [ ] Define `pub struct RepoRoot { pub root: PathBuf, pub kind: RepoKind }` with `#[derive(Debug, Clone, PartialEq, Eq)]`. Doc-comment the struct **and both fields** (`#![deny(missing_docs)]` is on — missing docs is a compile error). Document the `kind` invariant (only `Jj`/`Git`).
  - [ ] Implement `pub fn find_repo_root(start: &Path) -> Option<RepoRoot>` per the skeleton: it reads `$HOME` (`std::env::var_os("HOME")`) and delegates to a crate-private `fn find_repo_root_within(start: &Path, ceiling: Option<&Path>) -> Option<RepoRoot>`. `#[must_use]` on the public fn. Doc-comment it **including the consent-gated contract (AC-7)** and the **`$HOME`-ceiling** note (AC-6).
  - [ ] In `find_repo_root_within`, bound the walk with `take_while(|dir| *dir == start || ceiling.is_none_or(|c| !c.starts_with(dir)))` (start-path carve-out + `$HOME` ceiling). Keep it stat-only and `jj_lib`-free (only `detect()` over `start.ancestors()`). No panics, no `unwrap`.
- [ ] **Task 2 — Wire `lib.rs`** (AC: 8)
  - [ ] Extend the re-export to `pub use detect::{detect, find_repo_root, RepoKind, RepoRoot};`.
- [ ] **Task 3 — Update the surface-lock test** (AC: 8)
  - [ ] In `crates/zanshin-jj/tests/api_stability.rs`: add `type _RepoRoot = zanshin_jj::RepoRoot;` under the `// detect` section; inside `api_surface_resolves`, add the `find_repo_root` fn-pointer binding and a trivially-constructible `RepoRoot` value.
  - [ ] Bump the header comment "(25 types, AC-1 table)" → "(26 types, AC-1 table)".
- [ ] **Task 4a — Integration tests `tests/find_repo_root.rs`** (AC: 9, cases 1–7 — the public `find_repo_root`)
  - [ ] `// SPDX-License-Identifier: MIT` first line.
  - [ ] Mirror `tests/detect.rs`: reuse `tempfile::TempDir`, `test_helpers::extract_fixture`, a local `git(args, dir)` shell helper for the bare-git case. No `jj_lib` import.
  - [ ] Build sub-directory / nesting scenarios with `std::fs::create_dir_all` + `std::fs::create_dir(".jj")` etc. (no jj-lib, no `pin_env()` — `find_repo_root` never reads config). Note: tempdirs live outside `$HOME`, so the real `$HOME` ceiling never interferes with these (they behave as walk-to-root).
  - [ ] Cover AC-9 cases 1–7, with explicit `root == start` vs `root != start` assertions on the suggestion case.
- [ ] **Task 4b — Inline unit tests for the `$HOME` ceiling** (AC: 9, case 8 — the private `find_repo_root_within`)
  - [ ] Per CLAUDE.md test-placement: private-item tests go **inline** in `src/detect.rs` (`#[cfg(test)] mod tests`). Target `find_repo_root_within(start, Some(<temp ceiling>))` with a temp-dir tree — **no** real-`$HOME` dependency, **no** global env mutation.
  - [ ] Cases: (a) start below an injected ceiling `C`, with a repo marker only at/above `C` → `None` (the at-`C` repo is NOT surfaced); (b) start **== `C`** and `C` is itself a repo → `Some(root == C)` (start-path carve-out); (c) `ceiling = None` → walks past where the ceiling would be (covers the `is_none_or` None arm); (d) a repo strictly below `C` is still found.
- [ ] **Task 5 — Gate** (AC: 10)
  - [ ] Run `cargo make test`; make it green.
  - [ ] Commit the auto-raised `coverage-baseline.txt`. **Never** lower the baseline or add an `exclude_prefix` to pass (CLAUDE.md, review-blocking).

## Dev Notes

### Decision D1 — `find_repo_root` lives in `detect.rs`, not a new module

It composes `detect()` and references `RepoKind`/`RepoRoot` — all in `detect.rs`. Folding it in keeps the detection/discovery concern cohesive and avoids a near-empty `discover.rs` that would just `use super::{detect, RepoKind}`. This matches the module-by-noun layout (project-context.md § File & module organization): "detection" is the noun; single-dir classify and nearest-ancestor discovery are two functions of it. (Alternative considered: a `discover.rs` module — rejected as premature given two small items.)

### Decision D2 — `find_repo_root` is infallible-ish: `Option`, not `Result`

"No repo at/above start" is a **normal result**, not an error (same framing as `detect`'s `Neither`/`Missing` — see Story 2.11 D2 and `[[feedback-null-for-absence]]`). `None` means "nothing found"; there is no failure mode to report (stat-only, no I/O beyond metadata, no panic). No `DetectError`, no `Result`.

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
    /// — `find_repo_root` never yields a `RepoRoot` for `Neither`/`Missing`.
    pub kind: RepoKind,
}

/// Walks up from `start` to the nearest enclosing repository root (FR-JJ-17).
///
/// Evaluates `start`, then each ancestor, returning the first directory that
/// [`detect`] classifies as [`RepoKind::Jj`] or [`RepoKind::Git`]. The upward walk
/// is bounded by the **`$HOME` ceiling**: it never climbs to `$HOME` or above, so a
/// dotfiles repo at `~` is not surfaced when opening an unrelated folder under home.
/// The ceiling bounds the walk-*up* only — `start` itself is always classified, so
/// explicitly opening `~` still finds `~/.jj`/`~/.git`. Returns `None` if no
/// repository is found within the ceiling.
///
/// Stat-only — composes [`detect`] per level (same `.jj`-is-dir / `.git`-exists
/// semantics, symlinks followed). Never loads, mutates, or panics.
///
/// # Consent-gated use
///
/// Compare `root` against `start`: `root == start` ⇒ the chosen path is itself a
/// repository (open directly); `root != start` ⇒ a *suggestion* of an **enclosing**
/// repository the caller should **surface for confirmation** (UI prompt, or MCP
/// message such as "not a jj workspace here; the nearest is `<root>`"). This
/// function never opens anything — it only reports.
#[must_use]
pub fn find_repo_root(start: &Path) -> Option<RepoRoot> {
    let home = std::env::var_os("HOME").map(PathBuf::from);
    find_repo_root_within(start, home.as_deref())
}

/// Core walk-up with an explicit `ceiling` (crate-private so the `$HOME` ceiling is
/// unit-testable without depending on the real `$HOME`). Classifies `start`, then
/// ancestors strictly below `ceiling`; `ceiling` and anything above is never climbed
/// into, except that `start` itself is always classified. `ceiling == None` ⇒ walk
/// to the filesystem root.
fn find_repo_root_within(start: &Path, ceiling: Option<&Path>) -> Option<RepoRoot> {
    start
        .ancestors()
        .take_while(|dir| *dir == start || ceiling.is_none_or(|c| !c.starts_with(dir)))
        .find_map(|dir| match detect(dir) {
            RepoKind::Jj => Some(RepoRoot { root: dir.to_owned(), kind: RepoKind::Jj }),
            RepoKind::Git => Some(RepoRoot { root: dir.to_owned(), kind: RepoKind::Git }),
            RepoKind::Neither | RepoKind::Missing => None,
        })
}
```

That is the entire production addition (~30 lines incl. docs). `is_none_or` is stable since Rust 1.82 (we pin 1.95) and is clippy-pedantic's preferred form over `map_or(true, …)`. Resist adding more (Simplicity First).

### Consumer contract — how UI and MCP get the **consent-gated** behaviour

> These are **NOT implemented in this story** (it is pure `zanshin-jj`). They are the contract the two downstream stories implement against `find_repo_root`. Both story scope-notes are updated in `sprint-status.yaml` to reference this story.

**UI — via FFI (Story 3.4c, extended):** `3.4c` already exposes `zanshin_repo_detect(path)`. Extend its `RepoDetect` FlatBuffers payload to also carry the **optional suggestion**: when `detect(path)` is `Neither` (or `Missing`), call `find_repo_root(path)` and, if `Some`, include `{ suggested_root: string, suggested_kind: RepoKind }` in the payload. The Flutter UI renders consent-gated, e.g.:
> "Dieser Ordner liegt in einem **{jj|Git}**-Repository unter `<root>`. Öffnen?" — **[Öffnen]** / **[Abbrechen]**

The backend never auto-opens; the UI decides (this matches `[[feedback-dont-patronize-users]]`: backend exposes the capability, UI offers the decision).

**MCP — at startup repo-selection (Story 7-1, extended):** `7-1` resolves the repo from `--repo <path>` or CWD. Route that through `find_repo_root`, but **the MCP never decides for the user and never silently retargets** — it reports the situation factually and leaves the next step to the MCP user/agent (`[[feedback-dont-patronize-users]]`; resolved with Ralph 2026-06-26):
- `Some(root == start, Jj)` → the path **is** a jj workspace → start normally.
- `Some(root != start, Jj)` → the path is **inside** a jj workspace. **Do not** open `<root>` silently (the user asked for `<path>`, not `<root>`). Report it neutrally — what was given, what it is, and the nearest jj root as an *option* — and let the user decide (re-invoke with `--repo <root>`, or not). e.g. `"<path> is not a jj workspace; it is inside the jj repository at <root>. To use that repo, re-run with --repo <root>."`
- `Some(.., Git)` → `"<path> is a Git repository, not a jj workspace."` (the user decides: convert, or point elsewhere — the MCP does not act).
- `None` → `"No jj or Git repository at or above <path>."`

The MCP **surfaces facts + options, it does not act or prescribe**. Concretely: when the given path is not itself a jj workspace, startup does not proceed against a *different* directory — it exits with the neutral, machine-readable message above so the user/orchestrating agent chooses what to do. (This is the non-interactive analog of the UI consent gate.)

### Test recipe — mirror `tests/detect.rs`

- `tempfile::TempDir::new()` for scratch trees; build nesting with `std::fs::create_dir_all(root.join("a/b/c"))` then `std::fs::create_dir(root.join(".jj"))`.
- `test_helpers::extract_fixture("tiny-3-commits")` for the real-fixture direct-hit + a sub-dir-of-fixture case (`fixture.path.join("somedir")` — create it, assert `root == fixture.path`).
- Local `fn git(args, dir)` (verbatim from `tests/detect.rs`) for the git sub-dir case.
- Nearest-wins: outer dir with `.git/`, inner dir `outer/inner` with `.jj/`; assert `find_repo_root(outer/inner/deeper) == Some(inner, Jj)`.
- No `pin_env()` — `find_repo_root` never reads jj/git config.
- Scenario-describing names: `find_repo_root_on_subdir_of_jj_returns_workspace_root`, `find_repo_root_nearest_inner_wins`, `find_repo_root_no_repo_returns_none`, etc.

### Coverage note

New lines are in `detect.rs` (already 100%). Coverage split: the **integration** tests (Task 4a) hit the public `find_repo_root` ($HOME read + delegation) and the three `find_map` `match` arms + `None` fall-through; the **inline unit** tests (Task 4b) hit both `take_while` predicate arms — the `*dir == start` carve-out, the `ceiling = Some` stop, and the `ceiling = None` (`is_none_or`) arm. Together ⇒ ~100%. No FFI/extern coverage trap here (that belongs to 3.4c). `cargo make coverage` auto-raises the baseline; commit it.

### Previous-story intelligence — pre-empt the known traps

- **Surface-lock test (Story 2.10/2.11).** `tests/api_stability.rs` won't *know* about `RepoRoot`/`find_repo_root` unless added (Task 3). Also fix the "25 types" → "26 types" comment — count drift was a flagged finding in 2.10 and 2.11.
- **`#![deny(missing_docs)]` (Story 2.10).** The struct **and both fields** and the fn each need a `///`. A missing field doc is a build failure.
- **Depends on Story 2.11 `detect` being present.** `find_repo_root` calls `detect()` and reuses `RepoKind`. 2.11 is currently in `review`; sequence 2.14 after 2.11 is `done`.
- **Scope discipline (2.8/2.9).** Do **not** pull the FFI (3.4c) or MCP (7-1) wiring into this story — only the `zanshin-jj` capability + the documented contract.

### Files this story touches

| File | Action | What |
|------|--------|------|
| `crates/zanshin-jj/src/detect.rs` | UPDATE | `+ RepoRoot` struct, `+ find_repo_root()` + private `find_repo_root_within()`, `use std::path::{Path, PathBuf}`, `+ #[cfg(test)] mod tests` (inline `$HOME`-ceiling unit tests) |
| `crates/zanshin-jj/src/lib.rs` | UPDATE | re-export `find_repo_root, RepoRoot` |
| `crates/zanshin-jj/tests/find_repo_root.rs` | **NEW** | integration tests for public `find_repo_root` (direct hit, sub-dir suggestion, nearest-wins, none, colocated) |
| `crates/zanshin-jj/tests/api_stability.rs` | UPDATE | bind `RepoRoot` + `find_repo_root`; 25 → 26 |
| `coverage-baseline.txt` | UPDATE (auto) | commit the auto-raised baseline |

No `Cargo.toml` change (no new deps). No FFI, no codegen, no schema, no error-registry change.

### Hard rules in scope (project-context.md — reject-at-review on violation)

- **No `jj_lib` import** in `detect.rs` (the grep gate enforces it). `find_repo_root` is std-only.
- **No `extern "C"` here** — FFI is 3.4c.
- **No `unwrap()`/`expect()`/`panic!()`** on the library path. `find_repo_root` has none (`find_map` + `to_owned`). Tests may `expect()`.
- **No `jj_lib` type in a public position** — signature is `(&Path) -> Option<RepoRoot>`, `RepoRoot` crate-owned.
- **SPDX first line** on the new test file.
- **rustfmt `max_width = 100`, clippy pedantic `-D warnings`.**
- **Coverage ratchet: add tests, never lower the baseline.**

### References

- [Research: walk-up + marker depth](_bmad-output/planning-artifacts/research/technical-repository-discovery-walkup-and-jj-marker-depth-research-2026-06-26.md) — Q1 (walk-up), Q2 (stop point), recommendation §2 (separate additive helper)
- [`zanshin-jj/src/detect.rs`](crates/zanshin-jj/src/detect.rs) — `detect()` + `RepoKind` (Story 2.11), the primitive this composes
- [Story 2.11 — detect](_bmad-output/implementation-artifacts/2-11-implement-detect-rs-repository-kind-detection.md) — marker semantics inherited verbatim
- [`zanshin-jj/tests/detect.rs`](crates/zanshin-jj/tests/detect.rs) — `git()` + `TempDir` + `extract_fixture` patterns to mirror
- [`zanshin-jj/tests/api_stability.rs`](crates/zanshin-jj/tests/api_stability.rs) — surface-lock test to extend
- Story 3.4c (FFI detect/convert — **consumer**, extended for the UI suggestion) — `sprint-status.yaml`
- Story 7-1 (MCP repo-selection cwd-walk-up — **consumer**, extended for the "nearest is `<root>`" response) — `sprint-status.yaml`
- [project-context.md](_bmad-output/project-context.md) — FR-JJ-16/17, Simplicity First, coverage ratchet
- jj parity: jj-cli `find_workspace_dir` (`cli/src/cli_util.rs:2739`); `gg` `find_workspace_dir` (`src/worker/gui_util.rs:1345`)

## Dev Agent Record

### Agent Model Used

### Debug Log References

### Completion Notes List

### File List

### Change Log

## Open Questions for Ralph (non-blocking — defaults chosen, override before dev if desired)

1. **Walk-up ceiling.** ✅ **RESOLVED with Ralph 2026-06-26: include the `$HOME` ceiling.** Ralph keeps dotfiles in a Git repo (`~/.git` exists), so the walk must not climb to `~` and surface it. The walk stops before `$HOME`/above, with a carve-out so explicitly opening `~` still works. No filesystem-boundary guard. (See D3 + AC-6.)
2. **MCP behaviour when `start` is a sub-dir of a jj repo.** ✅ **RESOLVED with Ralph 2026-06-26:** the MCP **never silently retargets** ("open xyz" must not quietly operate on abc) and **never decides for the user** — it reports the situation neutrally (what was given, what it is, the nearest jj root as an option) and leaves the handling to the MCP user/agent. (Silent-retarget / jj-CLI "just works from a sub-dir" is explicitly **rejected** here.)
3. **Story slicing.** This story = the `zanshin-jj` capability + the contract. The UI-FFI wiring is folded into **3.4c** and the MCP wiring into **7-1** (their scope-notes updated to reference this). Prefer instead **dedicated wrapper stories** (a `3.4c`-sibling for the FFI suggestion, a `7-x` for the MCP message) so each surface is independently trackable? **Default: extend 3.4c + 7-1.**
