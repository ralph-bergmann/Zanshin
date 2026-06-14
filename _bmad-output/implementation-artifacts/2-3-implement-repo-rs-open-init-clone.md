---
baseline_commit: c5d90d7e3cc4259e67b0399e33c56628748aeeef
---

# Story 2.3: Implement `repo.rs` — open, init, clone

Status: done

<!-- Note: Validation is optional. Run validate-create-story for quality check before dev-story. -->

> **Scope-correction callout (binding — read before coding):** Three things in the epic's
> Story 2.3 text are stale against the current WIP reality and the verified jj-lib 0.41.0 API.
> They are corrected in the ACs below; the rationale is in Dev Notes:
> 1. **No perf assertion.** The epic AC "completes in < 400 ms on the `large-10k-commits` fixture
>    (per NFR-P-1 sub-budget from Story 2.2)" is **dropped** — Story 2.2 was deleted, the
>    `large-10k-commits` fixture was **never generated** (Story 2.1 WIP-rework: tiny + medium only),
>    and there is no perf-gate in WIP. NFR-P-1 stays a soft design goal. [Source: epics.md:1098, 1076, 1004; sprint-status.yaml:91]
> 2. **`init` API name.** The epic says `init_with_git_backend(...)`. That function does **not exist**
>    in jj-lib 0.41.0. The verified names are `Workspace::init_internal_git` (git backend) and
>    `Workspace::init_simple` (native backend). Both are **async**. [verified: docs.rs/jj-lib/0.41.0]
> 3. **`clone` has no one-call API.** jj-lib 0.41.0 exposes **no clone function** (jj's `clone` lives in
>    the `jj` CLI crate, not `jj-lib`). Clone must be composed from init + `add_remote` + `GitFetch` +
>    `import_refs`. See **Decision D2**. [verified: docs.rs/jj-lib/0.41.0/jj_lib/git]
>
> [Source: epics.md#Story 2.3 (lines 1082-1156); project-context.md § zanshin-jj; architecture.md:396-409]

---

## Story

As a Rust caller (later `zanshin-ffi` and `zanshin-mcp`),
I want `zanshin-jj` to expose `Repo::open`, `Repo::init`, and `Repo::clone` returning an opaque `Repo`
handle, backed by `jj-lib` but **leaking no `jj_lib` types in its public surface**,
so that the rest of the read-path stories (2.4 status, 2.5 revset, 2.6 change, 2.7 op-log,
2.8 bookmarks, 2.9 remotes) and the MCP binary have a working repo handle to operate on without ever
touching `jj-lib` directly.

This is the **first substance** in `zanshin-jj` (today it is a one-line placeholder) and the crate's
**first `jj-lib` consumer in production code** (Story 2.1's `jj-lib` use was in `xtask`, which is build-tooling,
not a shipped crate). It establishes the anti-corruption-layer boundary (FR-JJ-16) that every later
read/write story builds on: jj-lib churn is absorbed here; the public API stays stable.

---

## Acceptance Criteria

Grouped by deliverable. Each item is a checkable contract. Source is `epics.md#Story 2.3` unless noted;
where this story **corrects** the epic, the correction is flagged inline with rationale in Dev Notes.

### AC-1 — `Repo::open` (FR-JJ-1)

1. `crates/zanshin-jj/src/repo.rs` exists and defines `pub struct Repo { /* private fields */ }` plus
   `pub fn open(path: &Path) -> Result<Repo, RepoError>`.
2. `Repo::open(p)` with a valid `.jj/`-containing workspace root loads via
   `jj_lib::workspace::Workspace::load(...)` (**sync** — see API anchors) and returns a `Repo` wrapping it.
   Verify against the `tiny-3-commits` **and** `medium-1k-commits` fixtures.
3. `Repo::open(p)` where `p` does **not** exist → `Err(RepoError::PathNotFound { path })`. No panic.
4. `Repo::open(p)` where `p` exists but contains **no** `.jj/` → `Err(RepoError::NotARepo { path })`. No panic.
5. `Repo::open(p)` where `.jj/` exists but is **corrupt** (e.g. `op_heads` removed) → an `Err` that wraps
   the underlying jj-lib failure (see AC-9 for the variant), **never** a panic.
6. **(Correction — no perf assertion.)** There is **no** timing assertion on `open`. NFR-P-1 (< 2 s repo
   open at 10k commits) is a soft design goal only; the `large` fixture does not exist in WIP. [Source: epics.md:1098 corrected per sprint-status.yaml:91]

### AC-2 — `Repo::init` (FR-JJ-2)

7. `pub fn init(path: &Path, backend: Option<Backend>) -> Result<Repo, RepoError>` exists.
8. `init(dir, Some(Backend::Git))` initializes a git-backed jj workspace via
   `Workspace::init_internal_git(...)` (**async** — drive with `pollster::block_on`, see Async note).
   The resulting `.jj/` is valid: a subsequent `Repo::open(dir)` returns `Ok`.
9. `init(dir, None)` initializes jj's **native** backend via `Workspace::init_simple(...)` (async) and
   returns a `Repo`. A subsequent `Repo::open(dir)` returns `Ok`.
10. `Backend` is a `pub enum Backend { Git }` exported from `lib.rs`. `Git` is the only variant in WIP
    (the epic notes "`Backend::Git` is the only currently-supported variant"). Adding more variants later
    is a non-breaking additive change. [Source: epics.md:1109]

### AC-3 — `Repo::clone` (FR-JJ-3) — see Decision D2 for the composition

11. `pub fn clone(url: &str, target_path: &Path) -> Result<Repo, RepoError>` exists.
12. With a **valid** Git source URL, it composes a clone (init internal-git → `git::add_remote("origin", url)`
    → `GitFetch` fetch → `import_refs` → point the working copy at the fetched default branch) and returns a
    `Repo` handle after completion. **No progress callback is wired here** — leave an explicit
    `// TODO(FR-JJ-13, Epic 6 Story 6.4a): wire NativeCallable progress callback` at the fetch site. [Source: epics.md:1119-1123]
13. With an **invalid / unreachable** URL → `Err(RepoError::CloneFailed { reason })` carrying a descriptive
    reason string. No panic. (This is the **network-free** path and is the mandatory clone test; see AC-10/Decision D2.)

### AC-4 — `RepoError` (jj-lib-type-free public surface)

14. `pub enum RepoError` derives `thiserror::Error` + `Debug` and has, at minimum, the variants:
    `PathNotFound { path: PathBuf }`, `NotARepo { path: PathBuf }`, `InitFailed { reason: String }`,
    `CloneFailed { reason: String }`, and a catch-all for wrapped jj-lib failures (AC-9).
15. **(Correction — Decision D1.)** The wrapped-jj-lib variant **must not expose a `jj_lib` type in its
    public signature.** The epic's suggested `JjLibError(jj_lib::backend::BackendError)` is rejected because
    it directly violates the same story's AC "no `jj_lib` types appear in the public signatures" (epics.md:1128)
    and FR-JJ-16 (absorb jj-lib churn, don't re-export it). Use a string/opaque form instead — e.g.
    `#[error("jj-lib error: {0}")] Backend(String)` built from the jj-lib error's `Display`. [Source: epics.md:1126-1133 — internal contradiction resolved in D1]

### AC-5 — public surface hygiene (FR-JJ-16 / AR-AP-3-style)

16. `lib.rs` re-exports **only** `Repo`, `RepoError`, `Backend` (`pub use repo::{Backend, Repo, RepoError};`)
    plus `mod repo;` and crate-level docs. **No business logic in `lib.rs`** (project-context § File & module
    organization). The placeholder doc-comment currently in `lib.rs` is replaced.
17. **No `jj_lib` type appears in any `pub` signature** of `zanshin-jj` (return types, params, public enum
    fields, public struct fields). `jj_lib` stays an internal implementation detail. A reviewer greps the
    public surface for `jj_lib::` and finds none. [Source: epics.md:1125-1128; project-context.md:144-152]

### AC-6 — integration tests (`crates/zanshin-jj/tests/repo.rs`)

18. Tests live in `crates/zanshin-jj/tests/repo.rs` and consume the `tiny-3-commits` (and where useful,
    `medium-1k-commits`) fixture via `test_helpers::extract_fixture(name)` (dev-dependency `test-helpers`,
    path dep — see Dependencies). [Source: 2-1 story Decision D1; crates/test-helpers/src/lib.rs]
19. Required cases (scenario-named per project-context § Naming): `open` of an extracted fixture → `Ok`;
    `open("/nonexistent/...")` → `Err(PathNotFound)`; `open` of an existing non-jj tempdir → `Err(NotARepo)`;
    `init(tmp, Some(Backend::Git))` then `open(tmp)` → `Ok`; `init(tmp, None)` then `open(tmp)` → `Ok`;
    `open` of a fixture with `.jj/repo/op_heads` removed → the wrapped-error variant, **no panic**;
    `clone("not-a-real-url://nope", tmp)` → `Err(CloneFailed)`.
20. **Resource-leak sanity (epic edge case):** a loop that `open`s and **drops** a fixture handle 100×
    completes cleanly (no fd leak, no panic). [Source: epics.md:1152-1155]
21. **Relocatable-load (upgrades Story 2.1 edge case 25):** assert `Repo::open` **succeeds** from a temp
    path different from where the fixture was generated. (2.1 could only assert `.jj/` well-formedness because
    `load` didn't exist yet; 2.3 makes it a real `Workspace::load` assertion.) [Source: 2-1 story AC-25]

### AC-7 — fixture working-copy reality (don't assume `@` is at the tip)

22. Tests must **not** assume the fixture's working-copy commit (`@`) points at the generated head. Per the
    Story 2.1 hand-off, `@` is left **parented on the root commit**; the tip history is reachable only via
    bookmarks. `Workspace::load` succeeds and `.jj/working_copy/` is present, but do not assert "`@` == tip".
    [Source: 2-1 story "Heads-up for Story 2.3", lines 273]

### AC-8 — tests don't read developer globals

23. Tests do **not** depend on `~/.jjconfig.toml` / `~/.gitconfig`. The `Repo`'s settings are built from
    an explicit in-process config (Decision D3), which already avoids global reads; as belt-and-suspenders,
    set `JJ_CONFIG` and `GIT_CONFIG_GLOBAL` to a fixture-controlled (empty/temp) value in the test harness.
    [Source: project-context.md § Property of every test suite, lines 267-275; 2-1 story Testing standards]

### AC-9 — quality gate stays green

24. `cargo make test` passes end-to-end: `cargo clippy --workspace --all-targets -- -D warnings` (pedantic on)
    clean, `cargo fmt --all --check` clean, `cargo test --workspace` green, `cargo deny check advisories bans`
    clean, and the `test-cargo-hygiene` gate passes. **No new crate is added**, so the crate-count guard
    (currently `8`) is **unchanged** — do not touch it. [Source: Makefile.toml test-cargo-hygiene; 2-1 story T8]
25. Every new/edited `.rs` file starts with `// SPDX-License-Identifier: Apache-2.0` on line 1. Member-crate
    `Cargo.toml` files get **no** SPDX header (stay consistent with existing manifests). [Source: project-context.md:330-336; 2-1 story]
26. **No `unwrap()` / `expect()` / `panic!()` on reachable error paths** in `repo.rs`. This crate is the
    anti-corruption layer feeding the FFI; propagate via `RepoError`. `expect` is tolerable only on a
    genuinely-unreachable invariant with a `// WHY:`/`// SAFETY-of-invariant:` note. **No `unsafe`.**
    [Source: project-context.md:88-96, 459-499]

---

## Tasks / Subtasks

- [x] **T1 — Wire `zanshin-jj` dependencies** (AC: 1, 8, 14, 18)
  - [x] Root `Cargo.toml` `[workspace.dependencies]`: **add `thiserror = "2"`** (new — caret pin, stable
        crate, dual MIT/Apache-2.0 = permissive ✓; verify the current `2.x` on crates.io). Do not disturb the
        existing entries or the `[workspace.lints.clippy]` block. [current state: Cargo.toml:28-41]
  - [x] `crates/zanshin-jj/Cargo.toml` `[dependencies]` (currently empty): add
        `jj-lib = { workspace = true }`, `pollster = { workspace = true }` (drives the async `init_*`),
        `thiserror = { workspace = true }`. Keep the existing `[lints] workspace = true`.
  - [x] `crates/zanshin-jj/Cargo.toml` `[dev-dependencies]`: add `test-helpers = { path = "../test-helpers", version = "0.1.0" }`
        and `tempfile = { workspace = true }` (for init/clone-target tmpdirs in tests).
  - [x] If any dep needs `default-features = false`, add an inline `# WHY:` comment (AR-P-8 / hygiene gate).

- [x] **T2 — `Repo` + `RepoError` + `Backend` skeleton** (AC: 1, 7, 10, 14, 15, 16, 17)
  - [x] Create `crates/zanshin-jj/src/repo.rs` (SPDX line 1). Define `Repo` (private fields — see Decision D4),
        `RepoError` (thiserror; D1 — no `jj_lib` types), `Backend { Git }`.
  - [x] Replace `lib.rs` body: crate docs + `mod repo;` + `pub use repo::{Backend, Repo, RepoError};`. No logic.
  - [x] Add the private `settings()` helper that builds a `UserSettings` from an explicit `StackedConfig`
        (Decision D3 — reuse the `make_settings` recipe proven in `xtask`).

- [x] **T3 — `open`** (AC: 1, 2, 3, 4, 5, 9)
  - [x] Implement `open(path)`: pre-check existence → `PathNotFound`; check for `.jj/` → `NotARepo`; then
        `Workspace::load(&settings, path, &StoreFactories::default(), &default_working_copy_factories())`
        (verify the two factory defaults against `cargo doc -p jj-lib`), mapping `WorkspaceLoadError` to
        `RepoError` (corrupt repo → the wrapped-jj-lib variant). [API anchors below]

- [x] **T4 — `init`** (AC: 2)
  - [x] Implement `init(path, backend)`: `Some(Backend::Git)` → `pollster::block_on(Workspace::init_internal_git(&settings, path))`;
        `None` → `pollster::block_on(Workspace::init_simple(&settings, path))`. Map errors to `InitFailed { reason }`.
        Both return `(Workspace, Arc<ReadonlyRepo>)`; store what `Repo` needs (D4).

- [x] **T5 — `clone`** (AC: 3, 11, 12, 13 + Decision D2)
  - [x] Implement `clone(url, target_path)` by composing init-internal-git + `jj_lib::git::add_remote` +
        `GitFetch::{new,fetch,import_refs}`. Map any failure → `CloneFailed { reason }`. Add the
        `// TODO(FR-JJ-13, Epic 6 Story 6.4a)` progress placeholder at the fetch site.
  - [x] **Verify the `GitFetch` API against `cargo doc -p jj-lib` before relying on it** — it is the
        churniest surface here (subprocess options, callback trait, refspec type). See D2 for the 0.41.0 shape.

- [x] **T6 — Tests** (AC: 6, 18-23, 26)
  - [x] `crates/zanshin-jj/tests/repo.rs`: the cases in AC-19; the 100× open/drop loop (AC-20); the
        relocatable-load assertion (AC-21); the corrupt-repo no-panic case (AC-5/19).
  - [x] Pin `JJ_CONFIG` / `GIT_CONFIG_GLOBAL` in the test harness (AC-23). Do not assert `@` == tip (AC-22).
  - [x] **Clone happy-path test (Decision D2):** clone from a `file://` URL of a **locally-created**
        plain git source repo (built in a tempdir via `std::process::Command("git")`, no network). Happy path delivered (AC-12).

- [x] **T7 — Gate** (AC: 24, 25, 26)
  - [x] `cargo make test` green. Clippy pedantic clean (refactor, don't `#[allow]`). `fmt` clean. SPDX present.
        Confirmed `grep -r "jj_lib::" crates/zanshin-jj/src/lib.rs` finds nothing. Public signatures are clean (AC-17).

---

## Dev Notes

### Decision D1 — `RepoError` must not leak `jj_lib` types (RECOMMENDED, resolves an epic self-contradiction)

The epic AC says two incompatible things: (a) "no `jj_lib` types appear in the public signatures" (epics.md:1128),
and (b) `RepoError` should include `JjLibError(jj_lib::backend::BackendError)` (epics.md:1133). A public enum
variant **is** a public signature, so (b) breaks (a) — and breaks FR-JJ-16 (the whole reason `zanshin-jj` exists:
absorb jj-lib churn so a `jj_lib::backend::BackendError` field-type change doesn't ripple into every caller and
the FFI). **Resolution:** keep the wrapped variant **opaque** —

```rust
#[derive(Debug, thiserror::Error)]
pub enum RepoError {
    #[error("path not found: {path}")]
    PathNotFound { path: PathBuf },
    #[error("not a jj repository: {path}")]
    NotARepo { path: PathBuf },
    #[error("init failed: {reason}")]
    InitFailed { reason: String },
    #[error("clone failed: {reason}")]
    CloneFailed { reason: String },
    /// Underlying jj-lib failure, flattened to its Display so no jj_lib type escapes the public API.
    #[error("jj-lib error: {0}")]
    Backend(String),
}
```

Build `Backend(String)` from the jj-lib error at the boundary (`.map_err(|e| RepoError::Backend(e.to_string()))`).
You **lose** programmatic matching on the inner jj-lib error — acceptable in WIP; if a later story needs to
branch on a specific jj-lib failure, add a **typed `zanshin-jj`-owned** reason (not a re-exported jj-lib type).
This keeps the FFI error-code taxonomy (`jj.repo_not_found`, etc., AR-P-4) mappable from `zanshin-jj`'s **own**
variants. [Source: epics.md:1126-1133; project-context.md:144-152, 300-308]

### Decision D2 — `clone` composition (jj-lib 0.41.0 has no clone function)

jj's user-facing `clone` lives in the `jj` **CLI** crate, not `jj-lib`. `jj_lib::git` exposes only primitives
(verified: `add_remote`, `remove_remote`, `import_refs`, `push_*`, `GitFetch`). So `Repo::clone` is composed:

1. `init_internal_git(&settings, target_path)` (async) — creates the target jj workspace + internal git store.
2. `jj_lib::git::add_remote(...)` to register `origin → url` on the git backend.
3. Construct `GitFetch::new(mut_repo, GitSubprocessOptions, &GitImportOptions)` and call
   `fetch(&RemoteName, refspecs, &mut callback, depth, fetch_tags_override)`, then `import_refs().await`
   (async) — inside a transaction (`repo.start_transaction()` → `tx.repo_mut()` → … → `tx.commit(...)`),
   mirroring the transaction pattern proven in `xtask/src/tasks/gen_fixture.rs`.
4. Point the working copy at the fetched default branch (`GitFetch::get_default_branch`).

> ⚠️ **0.41.0 fetch uses a git subprocess** (`GitSubprocessOptions` / `GitSubprocessCallback` in the signature),
> i.e. jj-lib shells out to the `git` binary internally. That is jj-lib's own mechanism — it does **not** violate
> AR-AP-1/AR-AP-2 (which ban shelling to the **`jj`** CLI and parsing **`jj`** output). It does mean `git` must be
> on `PATH` (fine in dev/CI). **Verify the exact `GitFetch`/`add_remote` signatures against
> `cargo doc -p jj-lib` for 0.41.0 before coding** — this is the highest-churn surface in the story.

**Verified 0.41.0 shapes (re-verify before relying on each):**
```rust
// jj_lib::git
pub fn add_remote(/* git_backend/repo, remote: &RemoteName, url: &str ... */) -> Result<…, GitRemoteManagementError>;
// jj_lib::git::GitFetch
pub fn new(mut_repo: &mut MutableRepo, subprocess_options: GitSubprocessOptions, import_options: &GitImportOptions)
    -> Result<GitFetch, UnexpectedGitBackendError>;
pub fn fetch(&mut self, remote_name: &RemoteName, refspecs: ExpandedFetchRefSpecs,
             callback: &mut dyn GitSubprocessCallback, depth: Option<NonZeroU32>,
             fetch_tags_override: Option<FetchTagsOverride>) -> Result<(), GitFetchError>;
pub fn get_default_branch(&self, remote_name: &RemoteName) -> Result<Option<RefNameBuf>, GitFetchError>;
pub async fn import_refs(&mut self) -> Result<GitImportStats, GitImportError>;  // ASYNC
```

**Test strategy (no network — project-context bans it):** the **mandatory** test is the invalid-URL →
`CloneFailed` path (AC-13), which needs no network. For a happy path, build a **local** source repo in a tempdir
via `Workspace::init_colocated_git` (a real on-disk git repo with real git refs), make one commit + a bookmark,
then `Repo::clone(&format!("file://{}", source_dir.display()), target)`. `file://` + the git subprocess is
local-only and CI-safe. If the 0.41.0 `GitFetch` plumbing proves intractable inside this story's budget,
ship `clone` + the error-path test and record the happy-path deferral to Epic 6 Story 6.4a (where fetch lands
with progress) in Completion Notes — **do not** fake it and **do not** `#[ignore]` a flaky test.

### Decision D3 — `UserSettings` construction (reuse the proven `make_settings` recipe)

`Workspace::load` and every `init_*` need `&UserSettings`. Building one is the **#1 jj-lib churn-risk area**
(2.1 flagged the same). **Reuse the exact recipe already working in `xtask/src/tasks/gen_fixture.rs:104-120`** —
it builds settings from defaults + an explicit in-process layer and **never reads user globals** (which is also
how AC-23 is satisfied by construction):

```rust
use jj_lib::config::{ConfigLayer, ConfigSource, StackedConfig};
use jj_lib::settings::UserSettings;

fn settings() -> Result<UserSettings, RepoError> {
    let mut config = StackedConfig::with_defaults();
    config.add_layer(
        ConfigLayer::parse(ConfigSource::User, r#"
            [user]
            name = "Zanshin"
            email = "zanshin@localhost"
            [operation]
            username = "zanshin"
            hostname = "localhost"
        "#).map_err(|e| RepoError::Backend(e.to_string()))?,
    );
    UserSettings::from_config(config).map_err(|e| RepoError::Backend(e.to_string()))
}
```

Identity here is a **fallback** for op-log authorship on init/clone; read-only `open` doesn't depend on it being
"correct". Full settings access (read/write `user.email` etc.) is **FR-JJ-15 / `settings.rs`, a later story** —
do **not** build it here. [Source: crates/xtask/src/tasks/gen_fixture.rs:104-120; project-context.md § zanshin-jj]

### Decision D4 — `Repo` struct fields

`Workspace::load` returns just a `Workspace` (sync); `init_*` return `(Workspace, Arc<ReadonlyRepo>)`. To keep
`open`/`init`/`clone` uniform and give later stories (2.4-2.9) what they need, store at minimum:

```rust
pub struct Repo {
    workspace: jj_lib::workspace::Workspace,
    settings: jj_lib::settings::UserSettings, // needed to load the repo at head + start transactions later
}
```

Obtain the `ReadonlyRepo` lazily when a read story needs it — e.g. `self.workspace.repo_loader().load_at_head(&self.settings)`
(**verify the exact accessor/signature for 0.41.0**). Don't over-build for hypothetical needs; 2.3 only has to
return a valid handle. All fields are **private** (AC-17). [Source: epics.md:1090-1092]

### jj-lib 0.41.0 API anchors — VERIFIED (re-verify each against `cargo doc -p jj-lib` / docs.rs)

jj-lib is pinned `=0.41.0`, pre-1.0, **churny**. These were confirmed from docs.rs 0.41.0:

```rust
// jj_lib::workspace::Workspace
pub fn load(                                    // SYNC ✓ (aligns with "zanshin-jj is sync")
    user_settings: &UserSettings,
    workspace_path: &Path,
    store_factories: &StoreFactories,
    working_copy_factories: &WorkingCopyFactories,
) -> Result<Self, WorkspaceLoadError>;

pub async fn init_internal_git(user_settings: &UserSettings, workspace_root: &Path)   // ASYNC
    -> Result<(Self, Arc<ReadonlyRepo>), WorkspaceInitError>;                         // git backend (Backend::Git)
pub async fn init_simple(user_settings: &UserSettings, workspace_root: &Path)         // ASYNC
    -> Result<(Self, Arc<ReadonlyRepo>), WorkspaceInitError>;                         // native backend (None)
pub async fn init_colocated_git(user_settings: &UserSettings, workspace_root: &Path)  // ASYNC — use for the clone TEST source
    -> Result<(Self, Arc<ReadonlyRepo>), WorkspaceInitError>;
```

- **Store / working-copy factory defaults:** `Workspace::load` wants `&StoreFactories` and
  `&WorkingCopyFactories`. The defaults are `StoreFactories::default()` and the free function
  `jj_lib::workspace::default_working_copy_factories()` (**verify both names/paths for 0.41.0** — they are the
  one part of the `load` call not visible in the struct page).
- **Confirmed import set** (from working `xtask` code): `jj_lib::workspace::Workspace`,
  `jj_lib::settings::UserSettings`, `jj_lib::config::{ConfigLayer, ConfigSource, StackedConfig}`,
  `jj_lib::repo::{ReadonlyRepo, Repo as _}` (the `Repo` **trait** — note the `as _` to avoid clashing with our
  own `Repo` struct name; you will need this alias), `jj_lib::transaction::Transaction`,
  `jj_lib::op_store::RefTarget`, `jj_lib::ref_name::RefNameBuf`. [Source: crates/xtask/src/tasks/gen_fixture.rs:8-19]
- **`WorkspaceLoadError` mapping:** inspect its variants (`cargo doc -p jj-lib`) to distinguish "no workspace
  here" from a genuine load failure. Prefer to pre-check existence (`PathNotFound`) and `.jj/` presence
  (`NotARepo`) **before** calling `load`, so those two map cleanly to our own variants and only true load
  failures fall through to `RepoError::Backend(...)`.

### Async — driving jj-lib's async from sync `zanshin-jj`

project-context says "`zanshin-jj` is sync — jj-lib's APIs are sync, do not wrap them in `async`." That is true
for the **read** path (`load`, revset, change, op-log are sync). It is **not** literally true for `init_*` and
`GitFetch::import_refs`, which **are** `async` in 0.41.0. Resolve exactly as Story 2.1 did: wrap each async call
in **`pollster::block_on(...)`** (already a workspace dep). This keeps `Repo::init/clone` **sync** public
functions — the crate's public surface stays synchronous; only the internal call sites block on a future. Do
**not** make `zanshin-jj` adopt `tokio` or expose `async fn`. [Source: project-context.md:95-96, 529-531; 2-1 story "Async" note; gen_fixture.rs:74]

### Previous-story intelligence (Story 2.1 — `done`, reviewed 3-layer, 27/27 ACs pass)

- **`test_helpers::extract_fixture(name) -> Result<FixtureHandle, Box<dyn Error>>`** is ready. `FixtureHandle`
  has a **`pub path: PathBuf`** (the extracted workspace root containing `.jj/`) and owns a `TempDir` that
  cleans up on `Drop` — **keep the handle alive** while you use `.path`. [crates/test-helpers/src/lib.rs]
- **Fixture `@` is on the root commit, not the tip** (AC-22). `Workspace::load` succeeds; tip is reachable via
  bookmarks only. [2-1 story:273]
- **`make_settings` recipe** (D3) and the **`pollster::block_on`** async pattern come straight from 2.1's
  `gen_fixture.rs` — copy the shapes, don't reinvent.
- **Workspace deps already present:** `jj-lib =0.41.0`, `pollster`, `tempfile`, `tokio` (io-util only), `clap`,
  `tar`, `zstd`. You add **`thiserror`** (new) and the `zanshin-jj`-local `{ workspace = true }` references. [Cargo.toml:28-35]
- **`test-helpers` is crate #8**; the `test-cargo-hygiene` guard is already `8`. This story adds **no** crate, so
  **leave the guard alone** (touching it will fail the gate). [2-1 story:133, T8]

### Files this story touches (NEW unless marked UPDATE)

- `Cargo.toml` **(UPDATE)** — add `thiserror = "2"` to `[workspace.dependencies]`. Nothing else. [Cargo.toml:28-35]
- `crates/zanshin-jj/Cargo.toml` **(UPDATE)** — populate empty `[dependencies]` + add `[dev-dependencies]`. [crates/zanshin-jj/Cargo.toml:12-13]
- `crates/zanshin-jj/src/lib.rs` **(UPDATE)** — replace the 3-line placeholder with crate docs + `mod repo;` +
  the three re-exports. [crates/zanshin-jj/src/lib.rs:1-3]
- `crates/zanshin-jj/src/repo.rs` **(NEW)** — `Repo`, `RepoError`, `Backend`, `open`/`init`/`clone`, private `settings()`.
- `crates/zanshin-jj/tests/repo.rs` **(NEW)** — integration tests (AC-6/7/8).
- **Do not** add `status.rs`/`revset.rs`/etc. — those are Stories 2.4+. Stay in scope.

### Hard rules in scope (project-context.md — reject-at-review on violation)

- **`zanshin-jj` is the ONLY crate that imports `jj_lib`**, and **no `jj_lib` type may appear in its public
  surface** (D1, AC-17). Absorb jj-lib churn inside module bodies. [project-context:144-152]
- **No shelling to / parsing the `jj` CLI.** (jj-lib's internal `git` subprocess for fetch is fine — it's not
  the `jj` CLI. See D2.) [project-context:463-466]
- **No `unsafe`** in `zanshin-jj` (no FFI surface here). [project-context:88]
- **No `unwrap`/`expect`/`panic!`** on reachable paths; structured `RepoError` via `thiserror`. [project-context:90-94]
- **Clippy pedantic, `-D warnings`** — fix, don't `#[allow]`; any unavoidable suppression needs `// WHY:`. [project-context:75-86]
- **No `mod.rs`**; `repo.rs` is a `lib.rs` sibling (allowed). **`lib.rs` = re-exports + docs only.** [project-context:279-284]
- **SPDX line 1** on every `.rs`; **no** SPDX on member `Cargo.toml`. [project-context:330-336]
- **`[workspace.dependencies]` for shared deps**, consumed via `{ workspace = true }`; `=x.y.z` only for the
  load-bearing pre-1.0 trio (`jj-lib`, `rmcp`, `imara-diff`) — `thiserror` is stable → caret. [project-context:63-67, 354-362]

### Testing standards (project-context § Testing Rules)

- Integration tests in `crates/zanshin-jj/tests/repo.rs`; inline `#[cfg(test)]` unit tests allowed for pure
  helpers if any. Scenario-named tests (`repo_open_with_nonexistent_path_returns_path_not_found`). [project-context:215-228, 297-298]
- **No network**, **no `#[ignore]`/skip-for-flakiness**, tests run in parallel by default. [project-context:267-275]
- Pin `JJ_CONFIG` / `GIT_CONFIG_GLOBAL` so local and CI runs agree (AC-23). The explicit `settings()` already
  avoids global reads — the env pin is defense-in-depth, mainly for the `init`/`clone` git-backend paths.
- **No JSON crosses the FFI boundary in this story** (that's Epic 3's `zanshin-ffi`), so the schema-validation
  rule does **not** apply here. `zanshin-jj` returns typed Rust, not JSON. [project-context:235-241]

### Project Structure Notes (variances)

- Architecture's source tree places exactly this at `crates/zanshin-jj/src/repo.rs # FR-JJ-1..3 open/init/clone` —
  this story realizes that node. [Source: architecture.md:396-409]
- **Variance vs. epic AC wording:** `init_with_git_backend` → `init_internal_git`; `JjLibError(jj_lib::…)` →
  opaque `Backend(String)`; perf assertion dropped. All three are corrected above with rationale (D1, D2,
  scope-correction callout). These are deliberate, not oversights.
- **Variance vs. project-context "jj-lib is sync":** `init_*`/`import_refs` are async in 0.41.0; bridged with
  `pollster::block_on` so the public API stays sync. The project-context statement holds for the read path and
  for the *shape* of `zanshin-jj`'s public API; it does not contradict bridging an internal async call.

### References

- [Source: _bmad-output/planning-artifacts/epics.md#Story 2.3 (lines 1082-1156); Epic 2 intro (998-1000); FR map (243-261)]
- [Source: _bmad-output/planning-artifacts/architecture.md source tree (393-409, 450-521)]
- [Source: _bmad-output/planning-artifacts/prd.md FR-JJ-1/2/3/16 (epics.md inventory:31-49)]
- [Source: _bmad-output/project-context.md § Technology Stack, § zanshin-jj, § Testing Rules, § Code Quality, § Critical Don't-Miss]
- [Source: _bmad-output/implementation-artifacts/2-1-…gen-fixture.md — extract_fixture handle, @-on-root heads-up (273), make_settings/pollster patterns, crate-count guard]
- [Source: crates/test-helpers/src/lib.rs (FixtureHandle); crates/xtask/src/tasks/gen_fixture.rs:8-19,67-131 (imports + make_settings + sig + init pattern); crates/zanshin-jj/{Cargo.toml,src/lib.rs}; Cargo.toml:1-42]
- jj-lib 0.41.0 docs (verified this story): https://docs.rs/jj-lib/0.41.0/jj_lib/workspace/struct.Workspace.html ,
  https://docs.rs/jj-lib/0.41.0/jj_lib/git/index.html , https://docs.rs/jj-lib/0.41.0/jj_lib/git/struct.GitFetch.html

## Dev Agent Record

### Agent Model Used

claude-sonnet-4-6

### Debug Log References

1. `jj_lib::git::add_remote` schreibt die Git-Config sofort auf Disk via `save_git_config()`, aktualisiert aber NICHT den in-memory `gix::ThreadSafeRepository`-Cache. `GitFetch::new` ruft `backend.git_repo()` = `base_repo.to_thread_local()` auf, das den alten Cache verwendet — der Remote "origin" ist daher nicht sichtbar. Fix: Workspace nach `add_remote` frisch neu laden via `Workspace::load` + `workspace.repo_loader().load_at_head()`. Das neue `GitBackend` liest die Disk-Config und sieht den Remote.
2. macOS: `workspace.workspace_root()` gibt den kanonischen Pfad zurück (`/private/var/…`), `TempDir::path()` den nicht-kanonischen (`/var/…`). Fix: `std::fs::canonicalize` auf beiden Seiten der Assertion.
3. `gix = "0.83.0"` als Workspace-Dep nötig für `gix::remote::fetch::Tags::All` (5. Argument von `add_remote`).
4. `cargo-deny wildcards = "deny"` behandelt `{ path = "../test-helpers" }` ohne Version als Wildcard. Fix: `version = "0.1.0"` hinzufügen.
5. `Backend` brauchte `#[derive(Clone, Copy)]` damit Clippy `needless_pass_by_value` nicht feuert.

### Completion Notes List

- Alle 12 Integration-Tests grün; vollständiges Quality Gate (`cargo make test`) bestanden.
- Clone happy-path (AC-12) implementiert und getestet via `file://` URL einer lokal via `git` CLI erstellten Git-Quelle. Der gix-Caching-Workaround (zwei-Phasen: `add_remote` → Workspace-Reload → `GitFetch`) ist stabil.
- Working-copy-Update (`@` auf Default-Branch nach Clone) ist **implementiert** (Code-Review 2026-06-14, D4): `GitFetch::get_default_branch` → Ziel-Commit aus den `import_refs`-Stats → `MutableRepo::check_out` (+ `rebase_descendants`) → On-Disk `Workspace::check_out`. AC-12 ist damit **vollständig** erfüllt; der Happy-Path-Test asserted die materialisierte `README.md`. **Nur** der NativeCallable-Progress-Callback (FR-JJ-13) bleibt für Epic 6 Story 6.4a — das `// TODO` ist am Fetch-Aufruf hinterlegt.
- `init_colocated_git` wurde für Clone nicht verwendet (kein Bedarf, da `init_internal_git` + frischer Reload ausreicht).

### File List

- `Cargo.toml` — UPDATE: `gix = { version = "0.83.0", default-features = false }`, `thiserror = "2"` in `[workspace.dependencies]`
- `crates/zanshin-jj/Cargo.toml` — UPDATE: Dependencies und Dev-Dependencies befüllt
- `crates/zanshin-jj/src/lib.rs` — UPDATE: Placeholder ersetzt durch Crate-Docs + `mod repo;` + Re-Exports
- `crates/zanshin-jj/src/repo.rs` — NEW: `Repo` (+ private `settings` field, D4), `RepoError`, `Backend`, `open`/`init`/`clone` (+ private `clone_into` with default-branch working-copy checkout), `NoopCallback`, `make_settings`
- `crates/zanshin-jj/tests/repo.rs` — NEW: 13 Integration-Tests (alle ACs abgedeckt; + `repo_clone_failure_leaves_no_partial_workspace` und AC-12 Working-Copy-Content-Assertion)

### Change Log

| Datum      | Änderung                                                                                                        |
|------------|-----------------------------------------------------------------------------------------------------------------|
| 2026-06-14 | Story-Datei erstellt (Status: ready-for-dev)                                                                    |
| 2026-06-14 | Implementierung: Cargo.toml, lib.rs, repo.rs, tests/repo.rs; 12/12 Tests grün; cargo make test bestanden      |
| 2026-06-14 | Fix: gix-Cache-Workaround (Workspace-Reload nach add_remote); macOS-Symlink-Pfadfix; cargo-deny Wildcard-Fix  |
| 2026-06-14 | Status → review                                                                                                 |
| 2026-06-14 | Code review (3-layer): 5 fixes applied — D1 clone rollback-on-failure, D2 `settings` field (D4), D3 reload workspace after commit, P1 panic-free fetch globs (`# Panics` removed), P2 corrupt-repo assertion; + `repo_clone_failure_leaves_no_partial_workspace` test. D4 (full AC-12 working-copy update) tracked as open action item. `cargo make test` green (13 tests). Status → in-progress. |
| 2026-06-14 | Code-review follow-up: D4 implementiert — `clone` aktualisiert jetzt die Working-Copy auf den gefetchten Default-Branch (`get_default_branch` → `check_out` + `rebase_descendants` → `Workspace::check_out`); Happy-Path-Test asserted die materialisierte README. AC-12 vollständig erfüllt. `cargo make test` green (13 tests). Status → done. |

### Review Findings

_Adversarial code review (Blind Hunter + Edge Case Hunter + Acceptance Auditor), 2026-06-14. 4 decision-needed, 2 patch, 4 deferred, 7 dismissed as noise._

#### Decision-needed — all resolved 2026-06-14

All four decision-needed findings were resolved by Ralph and converted to patches (listed below):
- D1 clone partial-state cleanup → **Patch (rollback)**
- D2 missing `settings` field (D4) → **Patch (add field)**
- D3 stale `workspace` handle → **Patch (reload after commit)**
- D4 AC-12 working-copy update → **Implemented 2026-06-14 (check_out + rebase_descendants + Workspace::check_out; AC-12 fully met)**

#### Patch

- [x] [Review][Patch] D1 — `clone`: roll back the partial `.jj/` created by `init_internal_git` if any later step fails (remove only what clone created). [repo.rs:100-185]
- [x] [Review][Patch] D2 — add the `settings: UserSettings` field to `Repo` per Decision D4; store it in `open`/`init`/`clone`. [repo.rs:38-40]
- [x] [Review][Patch] D3 — `clone`: after `tx.commit`, reload the workspace via `Workspace::load` and return the current handle instead of the pre-fetch one. [repo.rs:100-185]
- [x] [Review][Patch] D4 — `clone` now implements the working-copy update: `GitFetch::get_default_branch` → target commit from `import_refs` stats → `MutableRepo::check_out` + `rebase_descendants` → on-disk `Workspace::check_out`. AC-12 fully met; happy-path test asserts the materialised `README.md`. (Only the NativeCallable progress callback (FR-JJ-13) remains for Epic 6 Story 6.4a.) [repo.rs clone/clone_into]
- [x] [Review][Patch] P1 — add the `// WHY:` note to the second `expect()` (tag glob) per AC-26 (or convert both globs to `?`). [repo.rs:165]
- [x] [Review][Patch] P2 — corrupt-repo test: `assert!(op_heads.exists())` before removal so it cannot silently pass on a healthy repo. [tests/repo.rs:86]

#### Deferred

- [x] [Review][Defer] `open()` pre-check (`exists()`/`is_dir()`) masks permission/IO errors as `PathNotFound` and mislabels a file-path or `.jj`-as-file as `NotARepo` [repo.rs:64-70] — deferred, tighten with FFI error taxonomy (Epic 3)
- [x] [Review][Defer] Happy-path clone test asserts only `is_ok()`+re-open (no content/ref assertion); depends on `git` ≥ 2.28 on PATH [tests/repo.rs:138-161] — deferred, strengthen when working-copy update lands (6.4a)
- [x] [Review][Defer] Untested clone/init boundaries: empty url, `file://` to missing/non-git dir, init/clone into already-initialized or missing-parent dir [repo.rs:90-185] — deferred
- [x] [Review][Defer] `copy_dir_all` test helper ignores symlinks/permissions (latent) [tests/repo.rs] — deferred
