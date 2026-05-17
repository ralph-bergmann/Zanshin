# Story 1.1: Initialize Cargo workspace and create empty crate skeletons

Status: done

<!-- Note: Validation is optional. Run validate-create-story for quality check before dev-story. -->

## Story

As a **developer setting up the Zanshin project**,
I want **a Cargo workspace at the repo root with all six initial crates (`zanshin-jj`, `zanshin-diff`, `zanshin-graph`, `zanshin-ffi`, `zanshin-mcp`, `xtask`) created as compilable empty skeletons**,
so that **subsequent epics can implement crate contents against an already-wired workspace structure without further scaffolding overhead**.

## Acceptance Criteria

1. **AC-1 — Workspace skeleton compiles.** The repo contains six member directories under `crates/`: `zanshin-jj`, `zanshin-diff`, `zanshin-graph`, `zanshin-ffi`, `zanshin-mcp`, `xtask`. The root `Cargo.toml` declares `[workspace]` with `members = ["crates/*"]` and `resolver = "2"`. `cargo build --workspace` exits 0 with **no warnings**.

2. **AC-2 — `zanshin-ffi` is a cdylib.** `crates/zanshin-ffi/Cargo.toml` sets `[lib] crate-type = ["cdylib"]` explicitly and `[lib] name = "zanshin_ffi"` (snake_case) so the macOS artefact is `libzanshin_ffi.dylib`.

3. **AC-3 — Workspace-level package metadata (AR-AD-7).** Root `Cargo.toml` `[workspace.package]` sets `version = "0.1.0"`, `edition = "2021"`, `license = "Apache-2.0"`, `repository = "..."`, `authors = [...]`. Every member crate's `Cargo.toml` inherits via `version.workspace = true`, `edition.workspace = true`, `license.workspace = true` (and `authors.workspace = true`, `repository.workspace = true` where present).

4. **AC-4 — Cargo.toml hygiene convention documented (AR-P-8).** `crates/README.md` (or root `README.md`) documents the convention that load-bearing pre-1.0 deps use `=x.y.z` pins and that any `default-features = false` needs an inline `# WHY:` comment. No actual deps are added in this story — the convention is documented for later stories.

5. **AC-5 — Empty crate bodies, doc-clean.** Each crate's `src/lib.rs` (or `src/main.rs` for `zanshin-mcp` and `xtask`) contains only a single placeholder `//!` crate-level doc comment plus an empty module/main entry — no functions, no `pub use` re-exports, no `extern` declarations. `cargo doc --workspace --no-deps` completes without warnings.

6. **AC-6 — `xtask` is invokable via alias.** `crates/xtask/Cargo.toml` has `[[bin]] name = "xtask"` (with `src/main.rs`). A `.cargo/config.toml` at the workspace root maps the alias `xtask = "run --package xtask --"` so `cargo xtask` works.

7. **AC-7 — `cargo metadata` is clean.** `cargo metadata --format-version 1` lists every member crate with `manifest_path` under `crates/`, and no crate carries an unexpected dependency.

8. **AC-8 — `.gitignore` extended.** The root `.gitignore` (currently BMad-only) is extended to include `target/`, `app/build/`, `.dart_tool/`, `app/.flutter-plugins*`, `*.swp`, `.DS_Store`. (CI-only secrets dirs are mentioned but not actually created in this story.) `Cargo.lock` is **NOT** ignored (it is committed — see architecture.md directory listing).

9. **Edge case — Case-insensitive collision.** On macOS APFS (case-insensitive default), if any two crate names differ only in case, the build fails by design. Story 1.1 ships six names that are unique case-insensitively — verify nothing was renamed during implementation.

10. **Edge case — Rust toolchain pre-1.95.0.** Story 1.1 does NOT add `rust-toolchain.toml` (that lands in Story 1.3). If a developer runs on Rust < 1.95.0 the build may still succeed; `crates/README.md` includes a "install Rust 1.95.0" pointer with a forward-reference to Story 1.3 which will enforce the pin.

## Tasks / Subtasks

- [x] **T1 — Root `Cargo.toml` workspace declaration (AC: 1, 3)**
  - [x] Create `Cargo.toml` at repo root with `[workspace]` block: `members = ["crates/*"]`, `resolver = "2"`.
  - [x] Add `[workspace.package]` with `version`, `edition = "2021"`, `license = "Apache-2.0"`, `repository`, `authors`, `rust-version = "1.95.0"`.
  - [x] Add an empty `[workspace.dependencies]` table (placeholder for later stories per AR-P-8).
  - [x] Add a top-of-file comment block stating: "Single workspace version (AR-AD-7). Pre-1.0 — breaking changes allowed in WIP."

- [x] **T2 — Create the four `zanshin-*` lib crates (AC: 1, 5)**
  - [x] `cd crates && cargo new --lib zanshin-jj --vcs none && cargo new --lib zanshin-diff --vcs none && cargo new --lib zanshin-graph --vcs none && cargo new --lib zanshin-ffi --vcs none`. `--vcs none` is required — we're inside an existing git repo.
  - [x] For each generated `Cargo.toml`: convert metadata to workspace-inherited form (`version.workspace = true`, `edition.workspace = true`, `license.workspace = true`).
  - [x] Replace generated `src/lib.rs` body with the SPDX header + a single `//!` crate doc comment + an empty body. No `pub fn`s, no re-exports.
  - [x] Verify each generated dir contains exactly `Cargo.toml` + `src/lib.rs` (no stray `.git/`, no `tests/` yet).

- [x] **T3 — Configure `zanshin-ffi` as cdylib (AC: 2)**
  - [x] In `crates/zanshin-ffi/Cargo.toml`, append `[lib]` with `crate-type = ["cdylib"]` and `name = "zanshin_ffi"` (snake_case underscore — Rust translates the package name `zanshin-ffi` to `zanshin_ffi` already, but the explicit `name = "zanshin_ffi"` future-proofs against linker artefact naming surprises).
  - [x] Do NOT add any `extern "C"` declarations yet — Story 3.1 lands the envelope; Story 1.1 is skeleton-only.

- [x] **T4 — Create `zanshin-mcp` bin crate (AC: 1, 5)**
  - [x] `cd crates && cargo new --bin zanshin-mcp --vcs none`.
  - [x] Convert `Cargo.toml` metadata to workspace-inherited form.
  - [x] Replace generated `src/main.rs` with SPDX header + `//!` doc comment + empty `fn main() {}` body.

- [x] **T5 — Create `xtask` bin crate (AC: 6)**
  - [x] `cd crates && cargo new --bin xtask --vcs none`. **NOTE:** The epics AC text reads "`cargo new --lib xtask`", but the final-state ACs (AC-5/AC-6 here) require `src/main.rs` + `[[bin]] name = "xtask"` (matching the architecture directory tree). `--bin` produces that final state in one step; `--lib` would force an immediate rename of `src/lib.rs` → `src/main.rs`. Either route is acceptable; the final structure must match AC-6.
  - [x] In `Cargo.toml`, add `[[bin]] name = "xtask" path = "src/main.rs"` (explicit; `cargo new --bin` already does this implicitly — make it explicit for review clarity).
  - [x] Convert metadata to workspace-inherited form.

- [x] **T6 — `.cargo/config.toml` alias (AC: 6)**
  - [x] Create `.cargo/config.toml` at the workspace root with:
    ```toml
    [alias]
    xtask = "run --package xtask --"
    ```
  - [x] Verify `cargo xtask` runs the empty binary (no panic, exit 0).

- [x] **T7 — Cargo.toml hygiene README (AC: 4)**
  - [x] Create `crates/README.md` documenting:
    - Workspace-version single-source-of-truth rule (AR-AD-7).
    - Pre-1.0 deps pinned `=x.y.z`; stable deps caret (AR-P-8).
    - `default-features = false` requires inline `# WHY:` comment (AR-P-8, also in project-context.md).
    - "No `[patch.crates-io]` in 0.x" rule (AR-P-8).
    - Pointer to Story 1.3 ("Rust 1.95.0 will be pinned via `rust-toolchain.toml`; install via `rustup` until then").

- [x] **T8 — Extend `.gitignore` (AC: 8)**
  - [x] Append to the existing root `.gitignore`:
    - `# Rust`
    - `target/`
    - `# Dart / Flutter` (forward-looking; `app/` lands in Story 1.2)
    - `app/build/`
    - `app/.dart_tool/`
    - `app/.flutter-plugins*`
    - `.dart_tool/`
    - `# Editor / OS`
    - `*.swp`
    - `.DS_Store`
  - [x] Do NOT add `Cargo.lock` — it must be committed per architecture.md directory listing.
  - [x] Verify `git status` shows no surprise untracked files after `cargo build --workspace`.

- [x] **T9 — SPDX headers on every source file (AR-P-9, project-context.md §Documentation)**
  - [x] First line of every `.rs` file in this story: `// SPDX-License-Identifier: Apache-2.0`. Single line, no surrounding Apache boilerplate. Repo-root `LICENSE` (Story scope: add it if missing) is canonical.
  - [x] If `LICENSE` file does not yet exist at repo root, add an Apache-2.0 `LICENSE` file (full text). This is a one-line subtask; the per-file SPDX rule is meaningless without it.

- [x] **T10 — Validation sweep (AC: 1, 5, 7)**
  - [x] `cargo build --workspace` → exit 0, zero warnings.
  - [x] `cargo doc --workspace --no-deps` → completes without warnings.
  - [x] `cargo metadata --format-version 1 | jq '.packages[] | .manifest_path'` (or grep) → every path is under `crates/`.
  - [x] `cargo xtask` → exit 0, no output.
  - [x] `git status` → only the new files this story added are untracked / staged; nothing surprising.

### Review Findings

_Code review 2026-05-17 (Opus 4.7, parallel Blind Hunter + Edge Case Hunter + Acceptance Auditor). All 10 ACs verified met by Acceptance Auditor; `cargo build --workspace` and `cargo doc --workspace --no-deps` re-run by reviewer with zero warnings. Triage: 1 decision-needed, 1 patch, 8 deferred, 32 dismissed (false-positives / spec-mandated / out-of-scope)._

- [x] [Review][Patch] Add `publish = false` to `[workspace.package]` (promoted from decision-needed) — pre-1.0 placeholder crates accidentally pushed via `cargo publish` would reserve names on crates.io permanently. [`Cargo.toml:7-13`] — applied 2026-05-17
- [x] [Review][Patch] `crates/README.md` "Bad" example is byte-identical to "Good" example — the lesson is opaque; the Bad block should drop the `# WHY:` comment to show the contrast. [`crates/README.md:42-49`] — applied 2026-05-17 (Good now carries inline `# WHY:`, Bad omits it)
- [x] [Review][Patch] LICENSE copyright `2026` → `2026-present` [`LICENSE:187`] — applied 2026-05-17 (quick win during review).
- [x] [Review][Patch] Add `description` + `homepage` to `[workspace.package]` and inherit in all 6 member crates [`Cargo.toml`, `crates/*/Cargo.toml`] — applied 2026-05-17 (quick win); `cargo metadata` now surfaces description across all members.
- [x] [Review][Patch] Add `._*` (macOS AppleDouble) to `.gitignore` [`.gitignore`] — applied 2026-05-17 (quick win).
- [x] [Review][Patch] Add macOS APFS case-insensitivity note to `crates/README.md` [`crates/README.md`] — applied 2026-05-17 (quick win).
- [x] [Review][Defer] No `NOTICE` file alongside Apache-2.0 `LICENSE` [`LICENSE`] — deferred to release phase (no downstream redistributors during WIP).
- [x] [Review][Defer] No `[workspace.lints]` table for central lint enforcement [`Cargo.toml`] — deferred to Story 1.7 (lint/format config).
- [x] [Review][Defer] No `[profile.release]` / `[profile.dev]` customization (LTO, codegen-units, strip) [`Cargo.toml`] — deferred; release-phase optimization.
- [x] [Review][Defer] `xtask` not excluded from default-members [`Cargo.toml:3-5`] — deferred to Story 1.4/1.9 tooling review; ergonomic, not breaking.

## Dev Notes

### What this story is

The very first scaffolding story. Output is a **compilable, zero-warning, dependency-free Cargo workspace** matching the architecture's directory tree (architecture.md § "Complete Project Directory Structure"). No functionality lands here — that starts in Story 2.1 onward. No Flutter package — Story 1.2. No Rust toolchain pin — Story 1.3. No `Makefile.toml` — Story 1.4. No codegen — Story 1.5. No `cargo-deny` — Story 1.6. No lint config — Story 1.7. No CI — Story 1.9.

### What this story is NOT

- **NOT adding any external crate deps.** Empty `[workspace.dependencies]` is fine. `jj-lib`, `rmcp`, `imara-diff`, `serde`, `tracing`, `notify-debouncer-full` etc. all land in their respective epic-3+ stories. The `crates/README.md` documents the *convention* for when those land.
- **NOT writing any code.** Every `lib.rs` / `main.rs` is one `//!` doc comment + an empty body. No `pub use`. No `extern "C"`. No `fn` other than `fn main() {}` for bins. If you find yourself writing logic, you've left scope.
- **NOT creating the `app/` Flutter package.** That's Story 1.2. Story 1.1's `.gitignore` entries for `app/build/` etc. are forward-looking — they cost nothing now and avoid a churn-commit in 1.2.
- **NOT creating `schemas/`, `test-fixtures/`, `docs/adr/`.** Those land in their respective epics. (Note: `docs/` already exists from BMad scaffolding — leave it alone.)
- **NOT pinning Rust.** Story 1.3 adds `rust-toolchain.toml`. Story 1.1 just documents the expected version in `crates/README.md`.

### Files being modified / created

This story is **net-new** for almost everything. The only existing file touched is `.gitignore` (extended, not rewritten — preserve the BMad block at the top).

**Existing repo state (verified at story-write time):**
- `.gitignore` exists with BMad-installer rules. Extend, do not replace.
- `docs/` exists (BMad). Leave untouched.
- `_bmad/`, `_bmad-output/`, `.idea/`, `.mcp.json`, `Zanshin.iml` — leave untouched.
- No `crates/`, no `Cargo.toml`, no `LICENSE`, no `.cargo/`, no `app/` yet.

**New files this story creates:**

| Path | Purpose |
|---|---|
| `Cargo.toml` | Workspace root (`[workspace]`, `[workspace.package]`, empty `[workspace.dependencies]`) |
| `LICENSE` | Apache-2.0 full text (per OD-2; SPDX headers point at this) |
| `.cargo/config.toml` | `cargo xtask` alias |
| `crates/README.md` | Cargo.toml hygiene + workspace-version + toolchain-install pointer |
| `crates/zanshin-jj/Cargo.toml` + `src/lib.rs` | Empty lib skeleton |
| `crates/zanshin-diff/Cargo.toml` + `src/lib.rs` | Empty lib skeleton |
| `crates/zanshin-graph/Cargo.toml` + `src/lib.rs` | Empty lib skeleton |
| `crates/zanshin-ffi/Cargo.toml` + `src/lib.rs` | Empty cdylib skeleton (`crate-type = ["cdylib"]`, `name = "zanshin_ffi"`) |
| `crates/zanshin-mcp/Cargo.toml` + `src/main.rs` | Empty bin skeleton |
| `crates/xtask/Cargo.toml` + `src/main.rs` | Empty bin skeleton with `[[bin]] name = "xtask"` |
| `Cargo.lock` (auto-generated) | Committed (architecture.md line 386). Lands in the same PR. |

### Source-doc citations

- [Source: epics.md § "Story 1.1: Initialize Cargo workspace and create empty crate skeletons" — full AC text]
- [Source: epics.md § "Epic 1: Workspace & Build Foundation" — Epic-level goal, FR coverage, AR-AD-7 anchor]
- [Source: architecture.md § "Initialization Sequence (executed in Epic A)" — `cargo new` command sequence + toolchain pins]
- [Source: architecture.md § "Complete Project Directory Structure" — authoritative repo layout (lines 374–542)]
- [Source: architecture.md § "AD-7: Workspace Versioning & Public API" — single workspace version, WIP stability]
- [Source: architecture.md § "P-8: Cargo.toml Hygiene" — version-pinning convention documented in this story]
- [Source: architecture.md § "P-9: Linter / Formatter Configs" — SPDX-on-first-line rule]
- [Source: architecture.md § "Repo Layout Decision" — Cargo workspace at repo root; Flutter package in `app/`]
- [Source: prd.md § 4.6 lines 264, 268–270 — FR-BO-1, FR-BO-5, FR-BO-6, FR-BO-7]
- [Source: prd.md § 4.4 line 237 — FR-FFI-1 (single cdylib)]
- [Source: project-context.md § "Code Quality & Style Rules" — SPDX, no `mod.rs`, file/module organization]
- [Source: project-context.md § "Technology Stack & Versions" — toolchain pins to document in README]

### Architecture guardrails — patterns that bind this story

**Workspace versioning (AD-7).** Single `[workspace.package] version = "0.1.0"` at root. **No** per-crate `version = "..."` lines. Every crate inherits via `version.workspace = true`. This is non-negotiable — AI agents have a tendency to drop a `version = "0.1.0"` into each crate's Cargo.toml "for clarity". Don't.

**Module/file structure (P-3).** Empty as it is, structure your skeletons so the future module layout slots in without rename. `zanshin-ffi/src/lib.rs` is the eventual home for re-exports + `zanshin_ffi_version` + panic handler init (Stories 3.1–3.2). Don't put placeholder `pub mod envelope;` etc. — but don't structure it in a way that later forces a rename. A single `//!` doc comment is the safe minimum.

**Anti-patterns to NOT introduce (architecture.md § Anti-Patterns):**
- Don't add any `extern "C"` outside `zanshin-ffi` — not even commented-out scaffolding.
- Don't add internal dependencies (e.g. `zanshin-ffi` depending on `zanshin-jj` in `[dependencies]`). Those land in Story 3.4 onwards.
- Don't add `flutter_rust_bridge` or comparable abstractions (memory: `[[feedback-avoid-flutter-rust-bridge]]`).
- Don't add `[patch.crates-io]` anywhere.

### Toolchain context

Local box at story-write time (verified):
- `rustc 1.95.0` ✓ (matches pin, but pin file is Story 1.3, not this story)
- `cargo 1.95.0` ✓
- `cargo-make 0.37.24` (not invoked in this story — Story 1.4)
- `rustup` available

The dev agent does NOT need to run `rustup install`, `cargo install cargo-make`, or any external setup for this story. The validation sweep is pure-cargo.

### `cargo new` ergonomics in an existing git repo

`cargo new --lib <name>` and `cargo new --bin <name>` will, by default, initialize a nested `.git/` directory inside the new crate. That breaks because we're already inside a git repo. **Always pass `--vcs none`** for every `cargo new` in this story.

Example:
```bash
cd crates
cargo new --lib zanshin-jj   --vcs none
cargo new --lib zanshin-diff --vcs none
cargo new --lib zanshin-graph --vcs none
cargo new --lib zanshin-ffi  --vcs none
cargo new --bin zanshin-mcp  --vcs none
cargo new --bin xtask        --vcs none
```

### Crate count: 6 (resolving the project-context.md ambiguity)

`project-context.md` line 26 says "5 lib crates + 1 bin + xtask". The epics.md Story 1.1 AC and architecture.md directory tree both list **6 crates**: 4 `zanshin-*` libs (`-jj`, `-diff`, `-graph`, `-ffi`) + 1 bin (`zanshin-mcp`) + xtask. There is **no fifth `zanshin-*` lib** in scope for this story. The project-context.md wording is loose, not authoritative. Follow the AC.

### Apache-2.0 license file

The repo currently has no `LICENSE` file. Story 1.1 adds one with the full Apache-2.0 text (`https://www.apache.org/licenses/LICENSE-2.0.txt`). This is required to give the per-file SPDX identifiers their referent. The architecture's AR-AD-7 + `OD-2` justify Apache-2.0 specifically.

### Edition and resolver

- `edition = "2021"` (project-context.md and AC). Do NOT use `edition = "2024"`.
- `resolver = "2"` at `[workspace]` level — required by AC. This is the default for new 2021-edition workspaces but state it explicitly per AC.

### `cargo doc --workspace --no-deps` zero-warning bar

The placeholder doc comments need to not trip rustdoc lints. The minimum compliant form is:

```rust
// SPDX-License-Identifier: Apache-2.0

//! Placeholder for the zanshin-jj adapter crate. Body lands in Epic 2.
```

Do NOT add `#![deny(missing_docs)]` yet — that's a Story 1.7 lint-config concern.

### `zanshin-ffi` cdylib note — what NOT to do here

- Do NOT add a `build.rs`.
- Do NOT add `include/zanshin_ffi.h` (that's Story 1.5 codegen output).
- Do NOT add the `cbindgen.toml` at workspace root (Story 1.5).
- Do NOT set `[lib] crate-type = ["cdylib", "rlib"]` — `cdylib` alone is correct. Adding `rlib` is a common over-cautious habit and would silently change link semantics later.

### Project Structure Notes

**Alignment:** Output of this story is the bare-minimum subset of architecture.md § "Complete Project Directory Structure" — specifically: the root `Cargo.toml`, the six `crates/<name>/` skeletons, `.cargo/config.toml`, `LICENSE`, `crates/README.md`, and a `.gitignore` extension.

**Deliberate omissions vs. the full architecture tree (all land in later stories, all in this epic):**
- `rust-toolchain.toml` → Story 1.3
- `rustfmt.toml`, `analysis_options.yaml` → Story 1.7
- `Makefile.toml` → Story 1.4
- `cbindgen.toml`, `app/ffigen.yaml` → Story 1.5
- `deny.toml` → Story 1.6
- `.github/workflows/ci.yml` → Story 1.9
- `app/` (Flutter package) → Story 1.2
- `schemas/`, `test-fixtures/`, `docs/{adr,rust-error-codes.md,ffi-abi.md,...}` → later epics

**Variance from architecture.md initialization sequence (lines 132–157):** Architecture lists only 5 `cargo new` invocations (no xtask). Story 1.1 AC explicitly adds xtask as a sixth crate. This is the AC's clarification, not a contradiction — implement six crates.

**Variance from epics.md AC wording:** Epics AC says `cargo new --lib xtask`; this story's T5 substitutes `cargo new --bin xtask` because the final-state ACs (AC-5/AC-6) require `src/main.rs` + `[[bin]] name = "xtask"`. Both paths reach the same end state; `--bin` is one step shorter.

### Testing standards summary

Story 1.1 ships **no functional code**, so there are no unit tests, no integration tests, no schema validation. The validation surface is purely the cargo toolchain itself:

- `cargo build --workspace` (zero warnings) — AC-1.
- `cargo doc --workspace --no-deps` (zero warnings) — AC-5.
- `cargo metadata --format-version 1` (clean output) — AC-7.
- `cargo xtask` (exits 0) — AC-6.
- `git status` after build (no surprises) — AC-8.

Test layout (P-7) — `tests/` directories per crate, `test-fixtures/` at root, `insta` snapshots, `jsonschema`/`json_schema` validation — all land starting Story 2.1. **Do not pre-create empty `tests/` directories.**

## Dev Agent Record

### Agent Model Used

claude-sonnet-4-6 (2026-05-17)

### Debug Log References

No issues encountered. `cargo new` (Rust 1.95.0) automatically generated workspace-inherited
`Cargo.toml` entries — all six member `Cargo.toml` files were already in the correct format
straight out of `cargo new --vcs none`.

### Completion Notes List

- Created root `Cargo.toml` with `[workspace]`, `[workspace.package]`, empty `[workspace.dependencies]`.
- Created six crate skeletons via `cargo new --vcs none` under `crates/`: four libs (`zanshin-jj`,
  `zanshin-diff`, `zanshin-graph`, `zanshin-ffi`) + two bins (`zanshin-mcp`, `xtask`).
- Configured `zanshin-ffi` as `cdylib` with explicit `name = "zanshin_ffi"`.
- All `src/lib.rs` and `src/main.rs` files contain only SPDX header + `//!` doc comment + empty body.
- Added `.cargo/config.toml` with `cargo xtask` alias; verified `cargo xtask` exits 0.
- Created `crates/README.md` documenting Cargo.toml hygiene conventions (AR-P-8, AR-AD-7).
- Extended `.gitignore` with Rust/Dart/Editor entries; `Cargo.lock` is NOT ignored (committed).
- Added `LICENSE` file (Apache-2.0 full text).
- Validation sweep passed: `cargo build --workspace` (0 warnings), `cargo doc --workspace --no-deps`
  (0 warnings), `cargo metadata` (all 6 members under `crates/`), `cargo xtask` (exit 0),
  `git status` (no surprises — `target/` correctly gitignored).

### File List

- `.gitignore` (modified — extended with Rust/Dart/Editor entries)
- `.cargo/config.toml` (new — xtask alias)
- `Cargo.toml` (new — workspace root)
- `Cargo.lock` (new — auto-generated, committed per architecture.md)
- `LICENSE` (new — Apache-2.0 full text)
- `crates/README.md` (new — Cargo.toml hygiene documentation)
- `crates/zanshin-jj/Cargo.toml` (new)
- `crates/zanshin-jj/src/lib.rs` (new)
- `crates/zanshin-diff/Cargo.toml` (new)
- `crates/zanshin-diff/src/lib.rs` (new)
- `crates/zanshin-graph/Cargo.toml` (new)
- `crates/zanshin-graph/src/lib.rs` (new)
- `crates/zanshin-ffi/Cargo.toml` (new — includes `[lib] crate-type = ["cdylib"]`)
- `crates/zanshin-ffi/src/lib.rs` (new)
- `crates/zanshin-mcp/Cargo.toml` (new)
- `crates/zanshin-mcp/src/main.rs` (new)
- `crates/xtask/Cargo.toml` (new — includes `[[bin]] name = "xtask"`)
- `crates/xtask/src/main.rs` (new)

## Change Log

- 2026-05-17: Story implemented — Cargo workspace initialized with six crate skeletons, LICENSE, .gitignore extended, crates/README.md created (claude-sonnet-4-6)
