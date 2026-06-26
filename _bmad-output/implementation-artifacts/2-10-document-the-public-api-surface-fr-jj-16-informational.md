---
baseline_commit: 168fd63
---

# Story 2.10: Document the public API surface (FR-JJ-16 informational)

Status: done

<!-- Note: Validation is optional. Run validate-create-story for quality check before dev-story. -->

> **Scope-correction callout (binding overrides of epic prose — read first):**
>
> The epic ACs (epics.md:1532-1590) were authored before Stories 2.4-2.9 existed. Several
> describe a surface that is now richer, or prescribe machinery that the WIP-rework banner
> (epics.md:1526) already retired, or cite the wrong reference. The corrections below are
> **binding**; each is justified inline and in Dev Notes.
>
> 1. **This is a DOCS + light-tooling story. NO behaviour change. NO new `src/` logic.** The
>    only files touched: `crates/zanshin-jj/src/lib.rs` (the `//!` crate doc-comment + one
>    crate-level attribute — no executable lines), a **new** `crates/zanshin-jj/README.md`, the
>    workspace `Cargo.toml` (`# WHY:` comment), a **new** `crates/zanshin-jj/tests/api_stability.rs`,
>    and (AC-4, gated on OQ1) `Makefile.toml`. **Coverage is unaffected** — doc-comments aren't
>    counted and the only new code lives in `tests/`, not `src/`. The `coverage-baseline.txt` does
>    **not** change. Do **not** add executable code to `src/`.
>
> 2. **The epic's 19-type re-export list is a STALE SUBSET — the real surface is richer
>    (24 types + 1 fn).** `lib.rs:17-23` **already** re-exports the correct, complete set
>    [verified: lib.rs:17-23]. The epic list (epics.md:1536) predates the per-noun error types
>    (`StatusError`, `ChangeError`, `OpLogError`, `BookmarkError`, `RemoteError`), the `Timestamp`
>    singular, and the `resolve_revset` free function. The reconciled, authoritative surface is in
>    **AC-1** below — assert *that*, not the epic's subset. lib.rs re-exports likely need **no
>    change**; the work is to *verify* them and assert them in `api_stability.rs`.
>
> 3. **ZERO `jj_lib` types leak today — the "single allowed leak point" edge case (epics.md:1576-1582)
>    is OBSOLETE.** Every one of the seven error enums wraps jj-lib failures as an opaque
>    `Backend(String)` (or `JjLibError(String)` in revset), never a `jj_lib::*` type
>    [verified: repo.rs:16-29, status.rs:50-59, change.rs:95-108, revset.rs:16-28, op_log.rs:48-55,
>    bookmarks.rs:44-51, remotes.rs:25-32]. The implementation went **further** than the epic
>    envisioned. **Disaster trap:** do **NOT** introduce a `RepoError::JjLibError(jj_lib::backend::BackendError)`
>    variant to "match" the stale AC — that would be a *regression* that reintroduces a leak the
>    codebase already eliminated. The doc-comment (AC-2) states the surface is **fully** jj_lib-free;
>    it adds **no** leak-exception clause.
>
> 4. **The doc-comment cites FR-JJ-16, NOT "AR-AP-3".** The epic's prescribed sentence
>    (epics.md:1541) ends "(see AR-AP-3)", but AR-AP-3 is the *"no `extern "C"` outside zanshin-ffi"*
>    anti-pattern (architecture.md:375) — unrelated to jj-lib re-exports. The adapter-stability
>    invariant is **FR-JJ-16** (architecture.md:28). Cite FR-JJ-16.
>
> 5. **The `jj-lib` pin lives in `[workspace.dependencies]`, already `=0.41.0` — do NOT inline it
>    into the crate manifest.** `crates/zanshin-jj/Cargo.toml:16` consumes `jj-lib = { workspace = true }`;
>    the exact pin is `jj-lib = "=0.41.0"` at root `Cargo.toml:33` [verified]. This is the *correct*
>    shape per the workspace-deps rule (project-context.md § "Cargo.toml hygiene"). AC-7's only
>    actionable deliverable is **adding the missing `# WHY:` comment** to that root line. Do **not**
>    move the pin into the crate manifest.
>
> 6. **AC-4 leak-guard: `clippy::disallowed_types` is NOT viable.** That lint flags *every* use of a
>    type, which would reject the legitimate **internal** `jj_lib` use inside `repo.rs`/`status.rs`/etc.
>    (the whole crate is the adapter). The guard must target only `pub use jj_lib`/`pub use jj-lib`
>    — a grep check modelled on the existing `test-cargo-hygiene` task (Makefile.toml:141-189),
>    folded into `cargo make test`. **Decision D1 (resolved): the grep guard IS added.** It is a
>    narrow hygiene check — *not* the `cargo public-api` snapshot or "API surface diff" gate the
>    WIP-rework banner retired (epics.md:1526) — and it catches a future `pub use jj_lib` regression
>    that AC-8's positive-surface test structurally cannot.

---

## Story

As an architect enforcing FR-JJ-16,
I want the public API of `zanshin-jj` documented as the explicit anti-corruption boundary with a stated stability invariant,
So that future jj-lib upgrades absorb their churn inside this crate without leaking type changes to `zanshin-ffi` or `zanshin-mcp`.

## Acceptance Criteria

Grouped by deliverable; each item is a checkable contract. Source is `epics.md#Story 2.10`
(lines 1524-1590) unless noted. Where this story corrects the epic, the correction is flagged
inline and justified in the Scope-correction callout / Dev Notes.

### AC-1 — Re-export surface is complete and `jj_lib`-free (FR-JJ-16) [epics.md:1536-1537; Scope-correction #2]

1. `crates/zanshin-jj/src/lib.rs` re-exports **exactly** this set (the authoritative, reconciled
   surface — verified already present at lib.rs:17-23):

   | Module | Re-exported public items |
   |---|---|
   | `repo` | `Repo`, `RepoError`, `Backend` |
   | `status` | `Status`, `StatusError`, `FileChange`, `ChangeKind`, `ChangeId` |
   | `change` | `Change`, `ChangeError`, `CommitId`, `ConflictState`, `Signature`, `Timestamp`, `Timestamps` |
   | `revset` | `resolve_revset` (fn), `RevsetError` |
   | `op_log` | `Operation`, `OperationId`, `OpLogError` |
   | `bookmarks` | `Bookmark`, `BookmarkKind`, `BookmarkError` |
   | `remotes` | `Remote`, `RemoteError` |

   (24 types + 1 free function.) If lib.rs already matches, **no edit** — just confirm.
2. **No `jj_lib::*` (and no `gix::*`) type is publicly re-exported**, and none appears in any public
   signature, struct field, or error variant. The sub-modules are `pub(crate) mod` / `mod` (lib.rs:9-15)
   so only the items above are public.

### AC-2 — Crate top-level doc-comment states the invariant (FR-JJ-16) [epics.md:1539-1541; Scope-corrections #3,#4]

3. The `//!` doc-comment in `lib.rs` explicitly states, in plain English, all of:
   - This crate is the **anti-corruption layer over jj-lib** (FR-JJ-16).
   - The public API of `zanshin-jj` is **stable**; jj-lib API changes are **absorbed inside** this crate.
   - **Adding `pub use jj_lib::...` is forbidden** — cite **FR-JJ-16** (not AR-AP-3, per Scope-correction #4).
   - The surface is **fully `jj_lib`-type-free**: every jj-lib failure is flattened to an opaque
     `Backend(String)` / `JjLibError(String)` error variant, so **no `jj_lib` type escapes any public
     signature** (Scope-correction #3). **No leak-exception clause** is written, because there is no leak.

### AC-3 — `crates/zanshin-jj/README.md` (new) [epics.md:1543-1549]

4. A new `crates/zanshin-jj/README.md` documents:
   - **Purpose** — the anti-corruption layer over jj-lib (FR-JJ-16); the only crate that imports `jj_lib`.
   - **The "do not leak jj-lib types" rule** — public signatures, fields, and error variants are
     jj_lib-free; jj-lib failures flatten to `Backend(String)`.
   - **How to add new functionality** — new noun → new `src/<noun>.rs`; use jj-lib internally; define
     the crate's **own** types; re-export them from `lib.rs`; **never** `pub use jj_lib::...`
     (mirrors the epic's "Adding a new FR-JJ function" edge, epics.md:1584-1590).
   - **The integration-test fixture pattern** — load fixtures via
     `test_helpers::extract_fixture("tiny-3-commits")` → `FixtureHandle`
     [verified: test-helpers/src/lib.rs:27; tests/repo.rs:7,33].

### AC-4 — `pub use jj_lib` leak-prevention guard [epics.md:1551-1554; Scope-correction #6; Decision D1]

5. A mechanical guard rejects any future `pub use jj_lib` / `pub use jj-lib` in
   `crates/zanshin-jj/src/`, folded into `cargo make test`. Implement as a **grep-based hygiene
   task** modelled on `test-cargo-hygiene` (Makefile.toml:141-189): a new private
   `[tasks.test-jj-adapter-hygiene]` (bash, BSD-grep-portable `grep -nE`, `git ls-files`
   `crates/zanshin-jj/src/`) appended to the `[tasks.test]` `dependencies` list (Makefile.toml:49-62).
   **NOT** `clippy::disallowed_types` (Scope-correction #6). The guard greps for a `pub use` whose
   path contains `jj_lib` / `jj-lib` (the public-leak shape) — it must **not** match the legitimate
   internal `use jj_lib::…` imports that every adapter module carries, so anchor the pattern on
   `pub[[:space:]]+use` + `jj_lib`. A no-match is success (`|| true` so `set -e` survives).

### AC-5 — Every public item is documented (`cargo doc`) [epics.md:1556-1559]

6. `cargo doc --package zanshin-jj --no-deps` produces docs in which **every** public item (type,
   variant, field, method, free fn) has a `///` doc-comment describing its role in plain English
   (not just the signature). **Mechanical enforcement (Decision D2, required):** add
   `#![deny(missing_docs)]` to `lib.rs` so the build fails unconditionally on any undocumented public
   item — a forcing function superior to a manual eyeball. Doc-comments are **already pervasive**
   (every module already carries `# Errors` sections — verified), so this should surface few or no
   gaps; fix any it flags. **Fallback:** if `deny` proves noisy on re-exported items in this toolchain,
   downgrade to `#![warn(missing_docs)]` (still a hard error under `cargo clippy -- -D warnings`,
   Makefile.toml `test-clippy`) and note why in the Completion Notes.

### AC-6 — `# Errors` (and `# Examples` if non-trivial) on fallible public fns [epics.md:1561-1564]

7. Every **fallible** public fn (`Repo::{open, init, clone, status, get_change, op_log, list_bookmarks,
   list_remotes}` and `resolve_revset`) has a `# Errors` section naming which `RepoError` /
   `StatusError` / `ChangeError` / `OpLogError` / `BookmarkError` / `RemoteError` / `RevsetError`
   variants can be returned and under what conditions. (Infallible fns like `workspace_root() -> &Path`
   need none.) This is an **audit** — `# Errors` sections already exist across all modules (verified);
   fill any gap, don't rewrite.
8. **Decision D3 (resolved): omit `# Examples` sections.** AC-6 makes them optional ("if non-trivial"),
   and a runnable library doctest links against the public crate only — `test_helpers` (a
   `dev-dependency`) is **not** available and `Repo::open` needs a real repo, so a runnable example is
   impractical/broken here. Ship no examples. (If a future contributor wants one, it **must** be fenced
   ` ```no_run ` / `text` so `cargo test` never executes it against a missing path.)

### AC-7 — `jj-lib` pin + `# WHY:` comment [epics.md:1566-1569; Scope-correction #5]

9. The exact pin `jj-lib = "=0.41.0"` stays in root `Cargo.toml:33` (`[workspace.dependencies]`),
   and that line gains a `# WHY:` comment noting **pre-1.0 exact-pin** (churn absorbed in `zanshin-jj`)
   and the **FR-JJ-16** invariant. Do **not** add an inline pin or `# WHY:` to
   `crates/zanshin-jj/Cargo.toml` (it correctly uses `jj-lib = { workspace = true }`).

### AC-8 — `crates/zanshin-jj/tests/api_stability.rs` (new) [epics.md:1571-1574; Scope-correction #2]

10. A new integration test names **every** public item by its `zanshin_jj::` path, so the test
    compiles **only if** the full surface (AC-1) resolves under that path. Form: type-path aliases
    (`type _Repo = zanshin_jj::Repo; …`) for all 24 types, a fn-pointer binding for `resolve_revset`
    (`let _f: fn(&zanshin_jj::Repo, &str) -> Result<Vec<zanshin_jj::ChangeId>, zanshin_jj::RevsetError>
    = zanshin_jj::resolve_revset;`), and cheap value construction for the trivially-constructible ones
    (`Backend::Git`, `RemoteError::Backend(String::new())`, etc.). It lives in `tests/` (public-API
    only) and, by design, **passes across a jj-lib upgrade** as long as the public surface is unchanged.
11. The test **also asserts the leak-free invariant** structurally: because it only references
    `zanshin_jj::` paths and constructs error variants as `Backend(String)`, a future `jj_lib` type in
    a public position would be observable here. (No `jj_lib` import in this test file.)

### Edge case — Adding a new FR-JJ function (documented in README, AC-3) [epics.md:1584-1590]

12. The README's "how to add new functionality" section captures the pattern: new file `<noun>.rs`,
    jj-lib used internally, crate-owned types, re-export in `lib.rs`, no jj-lib leak. (No code; this is
    the worked example that makes the invariant self-enforcing for the next contributor.)

## Tasks / Subtasks

- [x] **Task 1 — Verify & assert the re-export surface (AC-1, AC-8)**
  - [x] Confirm `lib.rs:17-23` matches the AC-1 table exactly; edit only if a drift exists.
  - [x] Create `crates/zanshin-jj/tests/api_stability.rs` with path-aliases for all 24 types + the
        `resolve_revset` fn-pointer binding + cheap value construction for trivial variants (AC-8).
  - [x] Confirm no `jj_lib::*` / `gix::*` in any public signature/field/variant (AC-1 #2).
- [x] **Task 2 — Crate doc-comment (AC-2)**
  - [x] Expand the `lib.rs` `//!` block to state: anti-corruption layer (FR-JJ-16), stable surface,
        `pub use jj_lib` forbidden (cite **FR-JJ-16**), surface fully jj_lib-free (no leak clause).
- [x] **Task 3 — README (AC-3, edge #12)**
  - [x] Create `crates/zanshin-jj/README.md`: purpose, no-leak rule, how-to-add-functionality
        (worked example), fixture pattern (`test_helpers::extract_fixture`).
- [x] **Task 4 — Doc completeness (AC-5, AC-6)**
  - [x] Add `#![deny(missing_docs)]` to `lib.rs` (D2); run `cargo doc -p zanshin-jj --no-deps` and fix
        any flagged public item. Fall back to `#![warn(missing_docs)]` only if `deny` is noisy (note why).
  - [x] Audit `# Errors` sections on the 9 fallible public fns; fill gaps (no rewrites). **No
        `# Examples`** (D3).
- [x] **Task 5 — Cargo `# WHY:` (AC-7)**
  - [x] Add the `# WHY:` comment to `jj-lib = "=0.41.0"` at root `Cargo.toml:33` (pre-1.0 pin + FR-JJ-16).
- [x] **Task 6 — Leak guard (AC-4, D1)**
  - [x] Add `[tasks.test-jj-adapter-hygiene]` (grep `pub[[:space:]]+use` lines containing `jj_lib`/`jj-lib`
        in `crates/zanshin-jj/src/`) modelled on `test-cargo-hygiene`; append to `[tasks.test]`
        `dependencies`. Add a one-line negative self-check assumption: the guard must stay green on the
        current tree (no `pub use jj_lib` exists today).
- [x] **Task 7 — Gate**
  - [x] `cargo make test` green (incl. coverage ratchet — baseline must be **unchanged**, since no
        `src/` executable lines were added).

## Dev Notes

### What is already done (do not redo)
- **Re-exports** (lib.rs:17-23) and **per-fn `# Errors` doc-comments** across all seven modules already
  exist — Stories 2.3-2.9 added them under the quality gate. This story is **verify + fill + the new
  README/test/Cargo-comment**, not bulk authoring.
- **No `jj_lib` leak anywhere.** All error enums are `Backend(String)` / `JjLibError(String)`
  [verified: repo.rs:16-29, status.rs:50-59, change.rs:95-108, revset.rs:16-28, op_log.rs:48-55,
  bookmarks.rs:44-51, remotes.rs:25-32]. Re-confirm before writing the doc-comment so the wording is
  accurate.

### Public surface reference (the contract the docs describe)
- **`Repo` impl** [repo.rs]: `pub fn open(&Path)->Result<Self,RepoError>` (147), `init(&Path,Option<Backend>)`
  (173), `clone(&str,&Path)` (195), `workspace_root(&self)->&Path` (55, infallible), `status` (78),
  `get_change(&ChangeId)` (92), `op_log(Option<usize>)` (107), `list_bookmarks` (122), `list_remotes` (137).
  `workspace`/`settings` are `pub(crate)` (60,65) — **not** public surface; `clone_into`/`make_settings`/`NoopCallback`
  are private. Do **not** document the non-public items as if they were API.
- **Free fn** `resolve_revset(&Repo,&str)->Result<Vec<ChangeId>,RevsetError>` [revset.rs].

### Citations corrected vs the epic
- Doc-comment reference: **FR-JJ-16** (architecture.md:28), not AR-AP-3 (= extern-C rule, architecture.md:375).
- Re-export list: the **24-type + 1-fn** table in AC-1 supersedes the epic's 19-type list (epics.md:1536).
- Leak edge case: **N/A** — surface is already fully leak-free; do not add a `JjLibError(jj_lib::...)` variant.

### Tooling / gate mechanics
- **`#![deny(missing_docs)]`** is the clean mechanical enforcement for AC-5/AC-6 — it makes the gate fail
  on any undocumented public item (rustc `missing_docs` warning → hard error under `cargo clippy -- -D warnings`,
  Makefile.toml `test-clippy`). If it produces noise on re-exported items, fall back to `#![warn(missing_docs)]`
  + manual fix.
- **AC-4 guard** template: `test-cargo-hygiene` (Makefile.toml:141-189) shows the exact, proven shape —
  `set -euo pipefail`, `git ls-files`, `grep -nE` (no `-P`, macOS BSD-grep safe), `|| true` to survive a
  no-match. Scope the new task's `git ls-files` to `crates/zanshin-jj/src/`. Wire into `[tasks.test]`
  dependencies (Makefile.toml:49-62).
- **Coverage:** doc-comments + `tests/` only ⇒ `coverage-baseline.txt` unchanged. If you find yourself
  editing it, you added `src/` code you shouldn't have.

### Anti-patterns to avoid (disaster prevention)
- ❌ Adding `RepoError::JjLibError(jj_lib::backend::BackendError)` to match stale AC prose (reintroduces a leak).
- ❌ Moving the `jj-lib` pin into `crates/zanshin-jj/Cargo.toml` (violates workspace-deps rule).
- ❌ `clippy::disallowed_types = ["jj_lib::..."]` (breaks legitimate internal adapter use).
- ❌ A runnable doctest that calls `Repo::open`/uses `test_helpers` (won't link / needs a real repo).
- ❌ Any executable `src/` change (this is a docs story; keep coverage baseline static).

### Project Structure Notes
- New files: `crates/zanshin-jj/README.md`, `crates/zanshin-jj/tests/api_stability.rs`. Edited:
  `crates/zanshin-jj/src/lib.rs` (doc-comment + attribute), root `Cargo.toml` (line 33 comment), and
  conditionally `Makefile.toml` (AC-4). All within the established crate layout (noun-per-file `src/`,
  one integration test per concern in `tests/`). No FFI, no codegen, no `docs/rust-error-codes.md` change.
- Naming/SPDX: `README.md` is prose (no SPDX line); `api_stability.rs` gets the standard
  `// SPDX-License-Identifier: MIT` first line (project-context.md § Documentation).

### References
- [Source: epics.md#Story 2.10 (lines 1524-1590), incl. WIP-rework banner 1526]
- [Source: project-context.md § "Framework-Specific Rules → zanshin-jj" + § "Cargo.toml hygiene" + § Documentation]
- [Source: architecture.md:28 (FR-JJ-16 adapter), :369-382 (Anti-Patterns), :375 (AR-AP-3 = extern-C)]
- [Source: crates/zanshin-jj/src/lib.rs:1-23 (current re-exports + doc-comment)]
- [Source: crates/zanshin-jj/src/{repo,status,change,revset,op_log,bookmarks,remotes}.rs (error enums, all `Backend(String)`)]
- [Source: Cargo.toml:33 (`jj-lib = "=0.41.0"` workspace pin); crates/zanshin-jj/Cargo.toml:16 (`workspace = true`)]
- [Source: Makefile.toml:47-62 (`[tasks.test]`), :141-189 (`test-cargo-hygiene` template)]
- [Source: crates/test-helpers/src/lib.rs:27 (`extract_fixture`); tests/repo.rs:7,33 (usage)]

## Resolved Decisions (binding — Ralph delegated the call, 2026-06-26)

1. **D1 — AC-4 leak-guard: ADD the mechanical grep gate.** A narrow `pub use … jj_lib` hygiene task in
   `cargo make test` is *not* the `cargo public-api` snapshot / surface-diff gate the WIP-rework banner
   retired; it is regression-proof, cheap, and catches a leak that AC-8's positive-surface test
   structurally cannot. Modelled on `test-cargo-hygiene`. (AC-4 + Task 6 are firm.)
2. **D2 — `#![deny(missing_docs)]`** (unconditional hard error) is the AC-5 enforcement. Fallback to
   `#![warn(missing_docs)]` (still hard under `cargo clippy -- -D warnings`) **only** if `deny` proves
   noisy on re-exports — document the reason in Completion Notes.
3. **D3 — Omit `# Examples`.** Runnable library doctests can't link `test_helpers` and `Repo::open`
   needs a real repo, so examples are impractical/broken here. None ship. Any future example must be
   `no_run`-fenced.

No open questions remain — the story is fully specified for `dev-story`.

## Dev Agent Record

### Agent Model Used

claude-sonnet-4-6

### Debug Log References

None — gate passed first run after fixing the `pub use jj_lib` grep to exclude comment lines.

### Completion Notes List

- `#![deny(missing_docs)]` applied unconditionally (D2). ~30 public items across `status.rs`, `change.rs`, `repo.rs`, `revset.rs`, `bookmarks.rs` needed doc-comments; all filled. No fallback to `warn` needed.
- `api_stability.rs` uses `_ = expr` (anonymous discard) instead of `let _x = expr` to avoid the `no_effect_underscore_binding` Clippy pedantic lint.
- `test-jj-adapter-hygiene` grep must exclude comment lines (`| grep -vE '^[0-9]+:[[:space:]]*//'`) because `lib.rs` doc-comment text contains the literal string `pub use jj_lib`.
- Coverage baseline **unchanged** — only `tests/` and doc-comments added; no `src/` executable lines touched.
- Broken intra-doc link `[`list_bookmarks`]` in `bookmarks.rs` fixed → `[`crate::Repo::list_bookmarks`]`.

### File List

- `crates/zanshin-jj/src/lib.rs` — added `#![deny(missing_docs)]`, expanded `//!` doc-comment
- `crates/zanshin-jj/src/status.rs` — added doc-comments to `FileChange` fields, `ChangeKind` variants, named variant fields
- `crates/zanshin-jj/src/change.rs` — added doc-comments to `Signature`, `Timestamp`, `Timestamps` fields; `ConflictState` variants/fields; `Change` fields; refactored `ChangeError::NotFound` to named struct variant
- `crates/zanshin-jj/src/repo.rs` — added doc-comment to `RepoError` and `Repo`; refactored all 4 `RepoError` variants to named struct variants with field doc-comments
- `crates/zanshin-jj/src/revset.rs` — refactored `RevsetError::ParseError` and `ResolutionError` to named struct variants with `reason` field doc-comments
- `crates/zanshin-jj/src/bookmarks.rs` — fixed broken intra-doc link
- `crates/zanshin-jj/tests/api_stability.rs` — new: path-aliases for all 24 types + `resolve_revset` fn-pointer + trivial value construction
- `crates/zanshin-jj/README.md` — new: purpose, no-leak rule, how-to-add-functionality, fixture pattern
- `Cargo.toml` — added `# WHY:` comment to `jj-lib = "=0.41.0"` line
- `Makefile.toml` — added `test-jj-adapter-hygiene` to `[tasks.test]` dependencies; added new `[tasks.test-jj-adapter-hygiene]` task

## Review Findings

_Code review 2026-06-26 (bmad-code-review, direct adversarial pass: blind diff read + grep-gate
edge-case analysis + 12-AC audit + doc-accuracy vs. ground-truth + conventions). AC-1/AC-8 exact
surface match (24 types + `resolve_revset`), AC-2 four-point `//!` citing FR-JJ-16, AC-3 README
complete, AC-4 gate wired + logically sound (`|| true`/pipefail and the empty-`matches` guard verified
correct), AC-5/AC-6 every fallible public fn has `# Errors` (op_log/remotes/all `Repo::*` confirmed),
AC-7 `# WHY` on root pin, named-variant refactors confirmed behaviour-neutral (doc-only, Display
unchanged), SPDX + intra-doc-link fix correct._

- [x] [Review][Patch] (resolved 2026-06-26 — applied options 1+2: qualified `lib.rs` `//!` + `README.md` to "production/library crate" and reconciled `project-context.md` § Framework-Specific Rules) "sole/only importer of `jj_lib`" overstated the boundary — `lib.rs` `//!`
  ("This crate is the **sole** importer of `jj_lib` in the Zanshin workspace") and `README.md`
  ("the **only** crate in the workspace that imports `jj_lib`") are contradicted by `crates/xtask`
  (`src/tasks/gen_fixture.rs` imports `jj_lib`; `xtask/Cargo.toml:18` declares `jj-lib = { workspace = true }`),
  the sanctioned fixture generator. The claim is true for the **production/library** surface
  (`zanshin-ffi`/`zanshin-mcp` consume `zanshin-jj`, never `jj_lib`) but literally false at the
  whole-workspace level. Note: `project-context.md` § Framework-Specific Rules carries the same
  over-broad claim, so the docs faithfully inherited a canonical imprecision. Options: (a) qualify both
  to "the only **library/production** crate that imports `jj_lib`" or add "(the `xtask` fixture
  generator aside)"; (b) accept as-is, treating `xtask` build-tooling as out of scope for the claim;
  (c) additionally reconcile the `project-context.md` line.

_Dismissed (non-blocking, by-design): (1) the gate's `pub[[:space:]]+use[[:space:]]+jj_lib` pattern
does not catch the exotic leading-colon form `pub use ::jj_lib::…` — adversarial, and AC-8 +
`#![deny(missing_docs)]` + review provide defense-in-depth; (2) a trailing comment `// pub use jj_lib`
on an unrelated `pub use` line would be a false-positive (only full-line comments are excluded) — fails
closed (annoying, never unsafe), extremely unlikely. Neither warrants a change for a hygiene gate._
