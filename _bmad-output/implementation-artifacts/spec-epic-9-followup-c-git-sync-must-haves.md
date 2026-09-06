---
title: 'Epic 9 follow-up C: the two Story 9.5 git-sync must-haves'
type: 'chore'
created: '2026-09-05'
status: 'done'
baseline_revision: '859a3a932c611e4a9972362c4babe395eaaebbd1'
review_loop_iteration: 0
followup_review_recommended: true
context: []
warnings: ['multiple-goals', 'oversized']
deferred:
  - summary: >-
      `remotes::git_fetch` projects an EMPTY `MutationResult` — `new_change_ids` and
      `abandoned_change_ids` are hardcoded `Vec::new()` — so the abandoning that
      `git.abandon-unreachable-commits` now lets a user control is invisible in fetch's result.
    evidence: |-
      `crates/zanshin-jj/src/remotes.rs` (the `MutationResult` literal at the end of `git_fetch`)
      ships both vectors empty since Story 6.4a, while the sibling verb `git::git_import` projects
      real stats from the same `import_refs` call. This run's config route makes the abandoning
      user-controllable and its descendant-rebase pass makes it reach the op log, which is exactly
      why the new pruning tests have to observe the effect through `resolve_revset(&repo, "all()")`
      instead of through the returned result. Pre-existing and not one of the two ledger bullets;
      the projection is a shipped-payload change with its own witnesses, so it is recorded rather
      than folded in.
    location: >-
      crates/zanshin-jj/src/remotes.rs (git_fetch's MutationResult literal)
    severity: low
    resolved: >-
      RESOLVED 2026-09-05 (spec-epic-9-followup-e-payload-widenings, commit 28a9aaa). git_fetch now binds the
      GitImportStats that import_refs() already returned and threw away one line later, and
      fills abandoned_change_ids from it. This item's premise about the sibling was wrong, and
      the fix follows its own prescription instead: git_import does NOT project into
      MutationResult either — it leaves both vectors empty (git.rs:103-106) and puts the
      abandonments in its own GitImportResult.abandoned_change_ids. Fetch has no second result
      struct, so the stats land in MutationResult.abandoned_change_ids, which WIDENS that
      field's documented meaning for this one verb: everywhere else it is the ids abandon's
      caller echoed back, here it is jj-lib's OWN abandonments. Both call sites go through one
      pub(crate) git::project_abandoned helper so the two verbs cannot drift. new_change_ids
      stays Vec::new() with a WHY — GitImportStats has no minted-change concept at all, and a
      replacement @ for an abandoned one is already reported through working_copy_change_id.
      Every doc claiming both vectors are always empty for git_fetch was corrected at all four
      layers (the two MutationResult field docs, the Repo facade, the extern "C" wrapper — so
      zanshin_ffi.h and bindings.dart moved, doc-only — and the Dart field docs plus
      RepoHandle.gitFetch). Witnessed on this run's own prune fixture at both poles: the
      default-config row asserts the pruned change IS reported and new_change_ids is empty, and
      the abandon-unreachable-commits = false sibling is the negative control with an empty
      list, so the pair proves the projection reads the stats rather than being hardcoded
      either way.
---

<intent-contract>

## Intent

**Problem:** Two entries in `deferred-work.md` § "Deferred from: bmad-build-auto runs of Stories
9.3–9.8" § "Must-haves" are still open, and both live in the same two `zanshin-jj` functions.
(1) "This workspace has no git backend" maps to TWO observable error codes: `remotes.rs::git_fetch`
reports jj-lib's `UnexpectedGitBackendError` as `jj.remote_not_found` (Story 6.4a's reading: a native
backend has no remotes, so the remote categorically cannot exist), while all six Story 9.5 verbs in
`git.rs` report the identical condition as `jj.not_a_git_repo` — so a UI cannot branch on "no git
backend" with one arm. (2) `remotes.rs::git_fetch` and `repo.rs::clone_into` still build
`GitImportOptions` from Rust constants, while `git_import` reads the same two keys
(`git.abandon-unreachable-commits`, `git.record-synthetic-predecessors`) through
`config::git_import_options` — so one user setting is honoured by one verb and overridden by two
others in the same crate, which the jj CLI does not do (NFR-R-2, FR-JJ-17).

**Approach:** A CLOSING run that resolves exactly those two ledger bullets and nothing else.
Item 1 moves `git_fetch`'s `GitFetch::new` failure arm to `MutateError::NotAGitRepo` — jj-lib types
that call's error as `UnexpectedGitBackendError`, its ONLY failure mode, so the remap is exact — then
follows the code through every layer that names it (jj docs, `MutateError` variant docs, the
`extern "C"` doc, the Dart worker docs, `docs/rust-error-codes.md`) and re-points the one test that
pins the old code. Item 2 routes both call sites through `config::git_import_options`, honouring the
CLI's OWN per-verb shape: `git fetch` takes both booleans from config, `git clone` takes
`abandon_unreachable_commits` from config and keeps `record_synthetic_predecessors: false` as its own
deliberate override (`cli/src/commands/git/clone.rs:384-389` @ v0.44.0).

## Boundaries & Constraints

**Always:**
- The jj CLI at `../jj` tag `v0.44.0` is the behavioural oracle. `cli/src/commands/git/fetch.rs:235`
  uses `load_git_import_options` verbatim (BOTH keys from config);
  `cli/src/commands/git/clone.rs:384-389` spreads it but pins `record_synthetic_predecessors: false`
  with the comment "There may be a large number of new commits". Reproduce that asymmetry exactly.
- Item 1 is a DELIBERATE observable-behaviour change on one shipped verb. Record it as such in
  `docs/rust-error-codes.md` (both the `jj.remote_not_found` and the `jj.not_a_git_repo` row) and in
  the `## Auto Run Result` summary. `jj.remote_not_found` keeps its OTHER producers untouched: an
  unknown remote name on a git-backed repo (`GitFetchError::NoSuchRemote`, `remotes.rs`) and the
  three Story 9.5 remote verbs (`git.rs::map_remote_err`).
- Item 2 gives `git_fetch` a new reachable error, `MutateError::Config` → `jj.config_error`, exactly
  as `git_import` already has. Register it (row `jj.config_error`) and witness it.
- Item 2 changes `git_fetch`'s DEFAULT behaviour for `record_synthetic_predecessors`: the old
  hardcode was `false`, jj-lib's own default (`config/misc.toml`) is `true`, and the CLI takes the
  config value. Say so explicitly in `Repo::git_fetch`'s doc and in the run summary — do not present
  item 2 as "only changes anything when the user set a key".
- `remote_auto_track_bookmarks` stays EMPTY at all three sites. `config::git_import_options` already
  leaves it empty and documents why; that is a separate, still-open ledger item.
- Coverage may rise but never drop. `crates/zanshin-jj/src/{remotes,config}.rs` and
  `crates/zanshin-ffi/src/repo.rs` sit at 100.00 in `coverage-baseline.txt`, so every line added
  there must be executed by a test. Never lower an entry, never add an `exclude_prefix`.
- `cargo make codegen` MUST run (the `zanshin_git_fetch` / `zanshin_repo_clone` `extern "C"` doc text
  changes) and its regenerated `zanshin_ffi.h` + `bindings.dart` committed in the same change.
- `cargo make test` is the single gate: run it unpiped and synchronously (allow ~10 min); it must
  exit 0.
- Bookkeeping is part of the run — see the two Execution tasks for `deferred-work.md` and
  `spec-9-5-git-local-sync-remote-config.md`.
- Commits use `--no-gpg-sign`, stay on `main`, and end with the Co-Authored-By trailer.

**Block If:**
- `GitFetch::new` in the pinned jj-lib turns out to have a failure mode OTHER than
  `UnexpectedGitBackendError` (re-read `~/.cargo/registry/src/*/jj-lib-0.44.0/src/git.rs:3032-3047`
  before editing): the blanket `map_err(|_| …)` would then be mapping unrelated faults to
  `jj.not_a_git_repo`. HALT with `blocked`, blocking condition `git_fetch new error surface widened`.
- A pre-existing test that this change did not touch fails because
  `record_synthetic_predecessors` flipped to `true` for fetch, in a way that indicates the flip is
  wrong rather than the test being over-pinned. HALT with `blocked`, blocking condition
  `fetch synthetic-predecessor default flip breaks an unrelated witness`.
- The gate can only be made green by lowering a `coverage-baseline.txt` entry or adding an
  `exclude_prefix`. HALT with `blocked`, blocking condition `coverage ratchet regression`.
- `cargo make codegen` moves a file OTHER than `zanshin_ffi.h` / `bindings.dart` (a `*_generated.rs`
  or `*.ffi_generated.dart` although no `.fbs` was edited). HALT with `blocked`, blocking condition
  `unexpected codegen drift`.

**Never:**
- Do NOT add a new error code or a new `RepoError` variant. A config fault inside `clone_into`
  travels as `RepoError::CloneFailed { reason }` → `jj.jj_lib_error`, the same channel every other
  clone-step failure already uses; widening `RepoError` would pull in the FFI mapper, the registry,
  `api_stability.rs` and the Dart docs for a case the intent does not name.
- Do NOT change any public signature. `Repo::git_fetch`, `Repo::clone` and `Repo::git_import` keep
  theirs; only the `pub(crate)` `remotes::git_fetch` gains an `import_options` parameter.
- Do NOT touch `MutateError::RemoteNotFound`'s other two producing sites (`remotes.rs`'s
  `GitFetchError::NoSuchRemote` arm, `git.rs`'s `GitRemoteManagementError::NoSuchRemote` arm) or
  `git.rs`'s six verbs. Leave every EXISTING `jj.remote_not_found` / `RemoteNotFound` assertion
  exactly as it stands — in `crates/zanshin-ffi/tests/repo_write_ffi.rs`,
  `crates/zanshin-jj/tests/git_remotes.rs`, `crates/zanshin-ffi/tests/git_ffi.rs` and
  `packages/zanshin_core/test/worker/{git,mutate}_test.dart`; each runs on a GIT backend or on a
  remote-config verb and is unaffected. (Task 9 ADDS a test to `repo_write_ffi.rs`; that is the only
  edit any of these files may receive.)
- Do NOT regenerate a test fixture, and do NOT unset `JJ_CONFIG` anywhere (see
  `tests/config_user_layer.rs`'s "rule this file must never break").
- Do NOT widen: no `docs/ffi-abi.md` pass, no `.fbs` edit, no `push_url` on `Remote`, no
  `auto-track-bookmarks` parser, no reformatting of adjacent code.
- Do NOT open a new ledger entry for anything of the same shape. This run exists to leave the ledger
  SMALLER — a same-shape leftover is fixed here or rejected, never deferred.
- Do NOT write a literal NUL byte (`U+0000`) into any source or spec file.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| `git_fetch` on a NATIVE backend | `Repo::init(tmp, None)`, then `git_fetch("origin", …)` | `Err(MutateError::NotAGitRepo)` — was `RemoteNotFound { name: "origin" }` | This IS the assertion (item 1) |
| Same, over FFI | `zanshin_repo_init(path, 0)` then `zanshin_git_fetch(handle, "origin")` | error envelope with code `jj.not_a_git_repo` and NO `context` (the variant names no path) | This IS the assertion |
| `git_fetch` with an unknown remote on a GIT backend | `Repo::init(tmp, Git)`, no remote registered, `git_fetch("nonexistent", …)` | unchanged: `Err(MutateError::RemoteNotFound { name: "nonexistent" })` → `jj.remote_not_found` | Unchanged — the existing tests must stay green untouched |
| `git_fetch` honours `abandon-unreachable-commits = false` | bare remote whose `feature` branch is the ONLY ref to commit B; fetch, delete `feature` on the remote, write the repo config, reopen, fetch again | B's change is STILL visible after the pruning fetch (`resolve_revset(.., "all()")` contains it) | No error expected |
| `git_fetch` with a non-boolean value for either key | `[git] abandon-unreachable-commits = "yes"` in `.jj/repo/config.toml` | `Err(MutateError::Config { reason })` naming the key, and NO new operation in the op log | This IS the assertion |
| `clone_into` with a non-boolean `abandon-unreachable-commits` in the USER layer | `JJ_CONFIG` → a file with `[git] abandon-unreachable-commits = "yes"`, clone from a local `file://` git source | `Err(RepoError::CloneFailed { reason })` whose reason names the key; no `.jj/` left behind | This IS the assertion |
| `clone_into` with a valid `abandon-unreachable-commits = false` | same source, valid user config | clone SUCCEEDS and the working copy is materialised (positive control) | No error expected |

</intent-contract>

## Code Map

Anchors read against the working tree at baseline `859a3a9`. Line numbers shift as edits land —
re-grep rather than trusting a number after the first edit in a file.

**Item 1 — the single behavioural line, and every place that names its code**

- `crates/zanshin-jj/src/remotes.rs:212-215` — `GitFetch::new(...).map_err(|_| MutateError::RemoteNotFound { name })`.
  jj-lib pins the error type: `GitFetch::new(&mut MutableRepo, GitSubprocessOptions, &GitImportOptions)
  -> Result<Self, UnexpectedGitBackendError>` (`jj-lib-0.44.0/src/git.rs:3032-3047`), whose only
  fallible step is `get_git_backend(mut_repo.store())`. Replace with `MutateError::NotAGitRepo`.
- `crates/zanshin-jj/src/remotes.rs:9` — module doc: "or `RemoteNotFound` from `git_fetch`".
- `crates/zanshin-jj/src/remotes.rs:186-188` — `git_fetch`'s `# Errors` bullet, whose second clause
  ("or the repo has no git backend at all …") moves to a new `NotAGitRepo` bullet.
- `crates/zanshin-jj/src/remotes.rs:236-240` — `GitFetchError::NoSuchRemote` → `RemoteNotFound`.
  READ-ONLY: this is the arm that must KEEP `RemoteNotFound`.
- `crates/zanshin-jj/src/repo.rs:652-658` — `Repo::git_fetch`'s facade `# Errors`, same two clauses.
- `crates/zanshin-jj/src/mutate.rs:141-148` — `MutateError::RemoteNotFound`'s own variant doc carries
  the "or the repo has no git backend at all" clause, which becomes false.
- `crates/zanshin-jj/src/mutate.rs:180-186` — `MutateError::NotAGitRepo`'s variant doc says
  "(Story 9.5)"; `git_fetch` joins its producers.
- `crates/zanshin-ffi/src/repo.rs:896-903` — `zanshin_git_fetch`'s `# Errors` list. Doc-only, but it
  flows into the generated header + bindings, so `cargo make codegen` is mandatory.
- `crates/zanshin-ffi/src/repo.rs:95-160` (`map_mutate_err`) — READ-ONLY. It ALREADY maps
  `NotAGitRepo` → `JJ_NOT_A_GIT_REPO` (no `context`) and `Config` → `JJ_CONFIG_ERROR`; no mapper edit
  is needed for either item. Its doc-comment prose at `:83-86` describes the Story 9.5 arms and stays
  true.
- `docs/rust-error-codes.md:61` (`jj.remote_not_found`) and `:49` (`jj.not_a_git_repo`) — the
  canonical registry rows; `:56` (`jj.config_error`) gains `zanshin_git_fetch` for item 2.
- `packages/zanshin_core/lib/src/worker/handle.dart:275-277` and
  `packages/zanshin_core/lib/src/worker/isolate.dart:758-761` — the two `gitFetch` doc code lists.
- `crates/zanshin-jj/tests/remotes_write.rs:320-335`
  (`git_fetch_on_native_backend_returns_remote_not_found`) — the ONE test that pins the old code.
  Rename to `…_returns_not_a_git_repo` and re-point the `matches!`.
- `crates/zanshin-jj/tests/api_stability.rs:443-444, 579` — READ-ONLY. It pins variant EXISTENCE and
  `Display` strings, neither of which changes; no edit expected.

**Item 2 — the two hardcoding sites, the config helper, and the CLI oracle**

- `crates/zanshin-jj/src/remotes.rs:206-210` — the hardcoded `GitImportOptions` inside `git_fetch`.
  Delete; take `import_options: &GitImportOptions` as a parameter instead (placed before `progress`,
  mirroring `git::git_import(workspace, immutable, options)`).
- `crates/zanshin-jj/src/repo.rs:660-666` — `Repo::git_fetch`, the facade that must now load the
  config. Copy `Repo::git_import`'s two lines verbatim (`repo.rs:740-742`):
  `config::load(self).map_err(mutate::cfg)?` then `config::git_import_options(&config).map_err(mutate::cfg)?`.
- `crates/zanshin-jj/src/repo.rs:1449-1455` — `clone_into`'s hardcoded `GitImportOptions`, built in
  Step 4 after the Step-3 `Workspace::load`. That reloaded `workspace` is the config source.
- `crates/zanshin-jj/src/config.rs:372-387` (`load`) — takes `&Repo` but only ever uses
  `repo.workspace()`. `clone_into` has no `Repo` yet, so add a `pub(crate) load_for_workspace(&Workspace)`
  next to it and make `load` a one-line delegate. Do NOT re-point the six existing `load(repo)` callers.
- `crates/zanshin-jj/src/config.rs:441-471` (`git_import_options`) — READ-ONLY, the target helper. Its
  doc says `git_fetch` and `clone_into` "already leave [`remote_auto_track_bookmarks`] empty"; that
  sentence stays true and must not be rewritten.
- `../jj` @ `v0.44.0` — `cli/src/git_util.rs:205-215` (`load_git_import_options`),
  `cli/src/commands/git/fetch.rs:235` (both keys from config) and
  `cli/src/commands/git/clone.rs:384-389` (spread with `record_synthetic_predecessors: false`).
- `~/.cargo/registry/src/*/jj-lib-0.44.0/src/config/misc.toml:13,15` — both keys default `true`.

**Item 2 — test scaffolding to reuse (all already present)**

- `crates/zanshin-jj/tests/git_sync.rs:246-275` (`git_import_honours_abandon_unreachable_commits_false`)
  and `:277-295` (`git_import_with_a_non_boolean_config_value_refuses_as_config`) — the two shapes to
  mirror; `write_repo_config` (`:82-84`) and `head_op_id` are its helpers.
- `crates/zanshin-jj/tests/remotes_write.rs` — `pin_env`, `git_cmd`, `git_stdout`, `git_bare_clone`,
  `register_remote`, `make_test_settings` are all file-local and cover the whole fetch fixture.
  `init_git_repo_with_commits` (`:79-90`) tags its tip `v1`; a fetch test that needs a
  non-tagged, prunable branch should build its own source rather than reuse it.
- `crates/zanshin-jj/tests/config_user_layer.rs` — the ONLY established pattern for repointing
  `JJ_CONFIG`: one `#[test]` in its own binary, because `JJ_CONFIG` is process-global and `cargo test`
  threads a binary. `clone_into`'s witness needs the USER layer (a fresh clone target has no repo
  config to pre-write), so it needs the same treatment in its own new file.
- `crates/zanshin-jj/tests/repo.rs:158-190` (`repo_clone_from_local_git_source_returns_ok`) — the
  local `file://` git-source clone fixture to copy.
- `crates/zanshin-ffi/tests/repo_write_ffi.rs:714-740`
  (`git_fetch_nonexistent_remote_returns_jj_remote_not_found`) — the shape for the new FFI witness;
  READ-ONLY itself (it inits with `backend = 1`, a git repo, and keeps `jj.remote_not_found`).

**Bookkeeping targets**

- `_bmad-output/implementation-artifacts/deferred-work.md:206` (the two-error-codes bullet) and
  `:208` (the hardcoded-`GitImportOptions` bullet), both in
  `## Deferred from: bmad-build-auto runs of Stories 9.3–9.8` § `### Must-haves (cross-cutting, medium)`.
  The strikethrough convention is on lines 216-226 of the same file.
- `_bmad-output/implementation-artifacts/spec-9-5-git-local-sync-remote-config.md:46-58` and `:59-72`
  — the two matching `deferred:` frontmatter items.

## Tasks & Acceptance

**Execution:**

1. `crates/zanshin-jj/src/config.rs` -- add `pub(crate) fn load_for_workspace(workspace: &Workspace) -> Result<StackedConfig, ConfigError>` holding the current body of `load`, and reduce `load(repo)` to `load_for_workspace(repo.workspace())` -- `clone_into` needs the effective config of a workspace it has not wrapped in a `Repo` yet, and re-pointing the six existing `load(repo)` callers would be churn outside this change.
2. `crates/zanshin-jj/src/remotes.rs` -- (a) map `GitFetch::new`'s failure to `MutateError::NotAGitRepo`; (b) delete the hardcoded `GitImportOptions` and take `import_options: &GitImportOptions` as a parameter; (c) update the module doc, the `# Errors` list (drop the no-backend clause from the `RemoteNotFound` bullet, add a `NotAGitRepo` bullet, add a `Config` bullet) and the options paragraph -- items 1 and 2 both land in this one function.
3. `crates/zanshin-jj/src/repo.rs` -- (a) `Repo::git_fetch`: load the config and build the options the way `Repo::git_import` does, pass them down, and update its `# Errors` + a behaviour paragraph naming the two keys AND the `record_synthetic_predecessors` default flip; (b) `clone_into`: replace the hardcoded struct with `GitImportOptions { record_synthetic_predecessors: false, ..config::git_import_options(&config)? }` over a config loaded from the Step-3 workspace, mapping a `ConfigError` to `RepoError::CloneFailed`, with a `// WHY:` naming `cli/src/commands/git/clone.rs:384-389`; (c) extend `Repo::clone`'s `# Errors` to say a malformed `git.abandon-unreachable-commits` now fails the clone.
4. `crates/zanshin-jj/src/mutate.rs` -- drop the "or the repo has no git backend at all" clause from `MutateError::RemoteNotFound`'s variant doc and add `git_fetch` to `MutateError::NotAGitRepo`'s producer list -- a variant doc that still claims the old routing is the most misleading place to leave it.
5. `crates/zanshin-ffi/src/repo.rs` -- update `zanshin_git_fetch`'s `# Errors` (replace the no-backend clause on `jj.remote_not_found` with a `jj.not_a_git_repo` bullet, add `jj.config_error`) and add one clause to `zanshin_repo_clone`'s `jj.jj_lib_error` bullet -- doc-only; `map_mutate_err` already routes both variants.
6. `docs/rust-error-codes.md` -- amend three rows: `jj.remote_not_found` loses the no-git-backend clause and records the move as a deliberate change; `jj.not_a_git_repo` gains `zanshin_git_fetch`; `jj.config_error` gains `zanshin_git_fetch` -- `project-context.md` makes this file the canonical registry.
7. `packages/zanshin_core/lib/src/worker/{handle,isolate}.dart` -- add `jj.not_a_git_repo` and `jj.config_error` to both `gitFetch` doc code lists -- these are the codes a UI author reads.
8. `crates/zanshin-jj/tests/remotes_write.rs` -- rename `git_fetch_on_native_backend_returns_remote_not_found` to `…_returns_not_a_git_repo` and assert `MutateError::NotAGitRepo`; add `git_fetch_honours_abandon_unreachable_commits_false` and `git_fetch_with_a_non_boolean_config_value_refuses_as_config` (local `write_repo_config` helper, mirroring `git_sync.rs`) -- the three witnesses for row 1, 4 and 5 of the matrix.
9. `crates/zanshin-ffi/tests/repo_write_ffi.rs` -- add `git_fetch_on_native_backend_returns_jj_not_a_git_repo` (init with `backend = 0`), asserting the code AND that `context` is absent -- the observable change is at the FFI surface, so it needs a witness there.
10. `crates/zanshin-jj/tests/clone_config.rs` (new) -- one `#[test]` in its own binary that repoints `JJ_CONFIG` (never unsets it), walking both clone rows of the matrix in sequence: valid `abandon-unreachable-commits = false` → clone succeeds; non-boolean value → `RepoError::CloneFailed` naming the key -- a fresh clone has no unreachable commits, so a type error is the only observable proof the value is now read from config; the module doc must say that and cite `config_user_layer.rs`.
11. `cargo make codegen`, then commit `crates/zanshin-ffi/include/zanshin_ffi.h` + `packages/zanshin_core/lib/src/ffi/bindings.dart` -- the two `extern "C"` doc bodies changed and generated output is committed, never rebuilt.
12. `_bmad-output/implementation-artifacts/deferred-work.md` -- strike through the two Must-have bullets in the file's existing convention (`~~**title**~~ **RESOLVED 2026-09-05 (spec-epic-9-followup-c-git-sync-must-haves, commit <short hash>)** …`) with a `**Resolution:**` sentence each, and state in the item-2 bullet that the 9.20 fold-in is no longer needed (item 1's own bullet already says "before … (9.20)", which this run satisfies) -- the ledger must end this run smaller.
13. `_bmad-output/implementation-artifacts/spec-9-5-git-local-sync-remote-config.md` -- add a `resolved: >-` block scalar to the two matching `deferred:` items (the "two different error codes" one and the "hardcode `GitImportOptions`" one), keeping the YAML valid -- the originating spec carries the evidence and must not keep reading as open.

**Acceptance Criteria:**

- Given a jj workspace with a native backend, when `Repo::git_fetch` is called, then it returns
  `MutateError::NotAGitRepo` and the FFI envelope carries `jj.not_a_git_repo` with no `context` —
  identical to what all six `git.rs` verbs already return for the same condition.
- Given a git-backed workspace with no remote named `nonexistent`, when `git_fetch("nonexistent")` is
  called, then it still returns `RemoteNotFound` / `jj.remote_not_found`, and the pre-existing Rust,
  FFI and Dart tests asserting that pass unmodified.
- Given a repo config that sets `git.abandon-unreachable-commits = false`, when a fetch prunes the
  only ref to a commit, then that commit is still visible afterwards; and given a non-boolean value
  for either key, when `git_fetch` runs, then it refuses with `MutateError::Config` naming the key and
  writes no operation.
- Given a user config that sets a non-boolean `git.abandon-unreachable-commits`, when `Repo::clone`
  runs against a local `file://` source, then it fails with `RepoError::CloneFailed` whose reason
  names the key; and given the same key set to a valid `false`, then the clone succeeds.
- Given `git grep -n "no git backend at all"` over `crates/` and `docs/`, when the run is finished,
  then no hit still attributes that condition to `jj.remote_not_found` / `MutateError::RemoteNotFound`.
- Given a clean tree, when `cargo make test` runs unpiped, then it exits 0 and no
  `coverage-baseline.txt` entry is lower than at baseline `859a3a9`.
- Given the run is finished, when `deferred-work.md` is read, then exactly two further bullets of the
  Stories 9.3–9.8 "Must-haves" subsection are struck through with a resolution line naming this
  spec's slug and a commit, the other eight Must-have bullets are untouched, and no new section has
  been added for this run.

## Spec Change Log

### 2026-09-05 — One task target moved layers; the review pass then extended scope to a pruning-fetch panic

**Trigger.** (a) Task 2(c) told the implementation to add a `MutateError::Config` bullet to
`remotes::git_fetch`'s `# Errors`. `remotes::git_fetch` RECEIVES the already-built
`GitImportOptions` and cannot produce `Config` at all — only the `Repo::git_fetch` facade, which
does the `config::load` + `git_import_options` calls, can. (b) The four-lens review pass found that
a pruning `git_fetch` PANICS inside jj-lib (`transaction.rs:141` "BUG: Descendants have not been
rebased after the last rewrites") whenever `git.abandon-unreachable-commits` is at its default
`true`, and that this run's own new test steered around it by pinning the one value (`false`) that
avoids the panicking branch.

**Amendment.** (a) The bullet went on `Repo::git_fetch` instead, where the fault actually
originates; `remotes::git_fetch`'s list stayed as it was. (b) `remotes::git_fetch` gained the
descendant-rebase pass its sibling verb `crate::git::git_import` already runs for the identical
reason, plus an `immutable: &Arc<UserRevsetExpression>` parameter (`pub(crate)`, so no public
signature moved) that `Repo::git_fetch` supplies from `op_support::immutable_user_expression`. The
false comment above `import_refs()` — which claimed no rebase was needed and cited the CLI at
v0.42.0 — was replaced by the true reason, cited at v0.44.0. A default-config sibling test now
covers the previously-panicking branch, and `git.record-synthetic-predecessors` gained the pair of
force-push witnesses it had none of.

**Authority and bound.** For (a), the intent's own error-taxonomy rule: a `# Errors` bullet names
what the function can return, and putting `Config` on a function that cannot return it is a false
doc, not a spec-satisfying edit. For (b), the run's own new test is what exposed the panic; the
run's own config route is what makes the panicking value user-selectable; the fix is a
line-for-line mirror of `git_import` in the same crate; and `project-context.md` forbids reaching
the FFI panic-catch ("no `unwrap`/`panic!` in library code paths reachable from FFI … the goal is
to never reach the catch"), which a `internal.panic` envelope instead of an error envelope is
exactly. The bound is the descendant pass, its comment and its test coverage: no change to fetch's
`MutationResult` projection (its `new_change_ids`/`abandoned_change_ids` stay empty), no new error
code, no other verb touched.

**Known-bad state avoided.** For (a), an unrecorded deviation — the defect the sibling follow-up B
had to correct in its own second pass. For (b), shipping a verb that panics on the default config
while the run's own witness quietly demonstrated only the value that avoids it.

## Review Triage Log

### 2026-09-05 — Review pass

- intent_gap: 0
- bad_spec: 0
- patch: 11: (high 1, medium 5, low 5)
- defer: 1: (high 0, medium 0, low 1)
- reject: 10: (high 0, medium 0, low 10)
- addressed_findings:
  - `[high]` `[patch]` A pruning `git_fetch` PANICKED inside jj-lib on the DEFAULT config
    (`transaction.rs:141`, "Descendants have not been rebased"): `remotes::git_fetch` never ran a
    descendant-rebase pass after `import_refs()`, and the comment above the call claimed none was
    needed, citing the CLI at v0.42.0. Pre-existing on `main`, but this run's config route made
    the panicking value user-selectable and its own witness had steered around it. Fixed by
    mirroring `git::git_import`'s `resolve_immutable` + `rebase_descendants_with_options` pass
    (`immutable` supplied by `Repo::git_fetch`), the comment replaced with the true reason cited at
    `cli/src/cli_util.rs` @ v0.44.0, plus a default-config sibling test for the previously
    panicking branch. Recorded as a bounded scope extension in `## Spec Change Log`.
  - `[medium]` `[patch]` `git.record-synthetic-predecessors` — the key whose effective default
    this change FLIPPED (`false` → jj-lib's `true`) — was completely unwitnessed for `git_fetch`.
    Two `Repo::evolog`-based tests now pin both values through a force-push fixture whose upstream
    commits carry a `change-id` header so both versions share one jj change id; the
    `record_synthetic_predecessors: false` spread regression fails exactly one of them.
  - `[medium]` `[patch]` `git_fetch_honours_abandon_unreachable_commits_false` could pass
    vacuously (never asserted the prune happened); both pruning tests now assert
    `feature@origin` is gone.
  - `[medium]` `[patch]` `docs/rust-error-codes.md`'s `jj.jj_lib_error` row was silent about
    clone's new config-fault cause although the file is the canonical registry; the row now names
    `zanshin_repo_clone`, the cause and that it is an observable change.
  - `[medium]` `[patch]` `zanshin_repo_clone`'s new `# Errors` line overclaimed "the offending key
    in `context`" (the unreadable-file branch names a PATH), baked into generated output; reworded
    at the `extern "C"` and `Repo::clone` docs, header + `bindings.dart` regenerated.
  - `[medium]` `[patch]` Task 2(c)'s target moved layers (`remotes::git_fetch` cannot produce
    `MutateError::Config`; the bullet went on the `Repo::git_fetch` facade) and the pruning-fetch
    scope extension were unrecorded in an empty `## Spec Change Log` — the same defect follow-up B
    had to correct. Both now carry a dated entry.
  - `[low]` `[patch]` `handle.dart`'s / `isolate.dart`'s `gitFetch` throw-lists omitted
    `jj.jj_lib_error` — added.
  - `[low]` `[patch]` `git_fetch_with_a_non_boolean_config_value_refuses_as_config` had no
    positive control and, like its sibling, could not distinguish "read per call" from a
    per-handle cache; restructured to fetch successfully first, then write the bad config and
    fetch again on the SAME handle.
  - `[low]` `[patch]` This run's own ledger text pointed at a "separate, still-open item" for
    `remote_auto_track_bookmarks` that does not exist — repointed at the section intro's spec-only
    parking.
  - `[low]` `[patch]` `JJ_REMOTE_NOT_FOUND`'s doc comment left with a ragged mid-sentence wrap —
    reflowed, wording unchanged.
  - `[low]` `[patch]` The `GitFetch::new` remap relied on the error type being exactly
    `UnexpectedGitBackendError`; the closure parameter is now annotated so a widened jj-lib error
    surface fails to compile instead of silently reporting as `jj.not_a_git_repo`.
  - `[low]` `[defer]` `remotes::git_fetch` hardcodes `new_change_ids` / `abandoned_change_ids` as
    empty, so fetch's `MutationResult` cannot show the abandoning the user can now control.
    Pre-existing (Story 6.4a), not one of the two ledger bullets, and a shipped-payload change
    wanting its own witnesses — recorded in frontmatter `deferred` and in `deferred-work.md`.
  - `[low]` `[reject]` × 10 — noise or out of scope on the intent's own authority: `clone_into`'s
    subprocess options still come from `make_settings()`'s synthetic stack (pre-existing, Story
    2.3); no separate `ConfigError::Load` mapping in `clone_into`'s reason string; no FFI/Dart-
    layer witness for `jj.config_error` from `zanshin_git_fetch` (the crate-level test plus the
    unchanged `map_mutate_err` unit test cover the mapping); no Dart-layer witness for the
    `jj.not_a_git_repo` remap (the Rust + FFI witnesses observe the same code); `clone_config.rs`
    fixture helpers duplicate `remotes_write.rs`/`repo.rs` ones (test-only, no shared test crate
    exists); the `unsafe { env::set_var }` single-test convention has no mechanical guard;
    `ENV_GUARD`'s `JJ_CONFIG = ""` pre-pin is overwritten by `set_jj_config` (matches the sibling
    files' shape); `jj.config_error` row sentence order / `jj.not_a_git_repo` summary column; a
    TMPDIR-with-spaces `file://` URL edge; and amending `sprint-status.yaml`'s 9-5 line and
    `spec-6-4a`'s retired mapping (the ledger + registry are the tracked surfaces for this change).

## Design Notes

**Why `clone_into` keeps `record_synthetic_predecessors: false`.** The naive reading of item 2 —
route both booleans of both call sites through config — would DIVERGE from the CLI, which the intent's
own justification ("the CLI honours them, so this is CLI parity, NFR-R-2") rules out.
`cli/src/commands/git/clone.rs` reads the options and then pins that one field to `false`, because a
clone imports a large number of new commits at once. Reproducing the spread reproduces the intent:

```rust
let import_options = GitImportOptions {
    // WHY: CLI parity — `cli/src/commands/git/clone.rs:384-389` @ v0.44.0 pins this to false
    // regardless of config ("There may be a large number of new commits").
    record_synthetic_predecessors: false,
    ..crate::config::git_import_options(&config).map_err(|e| RepoError::CloneFailed { reason: e.to_string() })?
};
```

**Why a type error is `clone_into`'s only witness.** `abandon_unreachable_commits` decides whether
commits that BECOME unreachable are abandoned. A fresh clone imports into an empty repo, so nothing
can become unreachable and the flag has no positive observable effect; `record_synthetic_predecessors`
is pinned. What CAN be observed is that the value is now READ: a non-boolean value fails the clone
where it was previously ignored. That is exactly the ledger's grievance ("no test asserts either
behaviour at the two old sites"), and the CLI fails the same way (`GitSettings::from_settings`
propagates the type error). The valid-`false` phase in the same test is the positive control that the
new config read does not itself break a clone.

**Why the config fault stays `CloneFailed`.** `RepoError` deliberately has one bucket for every
clone-step failure — init, remote registration, fetch, import, check-out are all `CloneFailed`. Adding
a `Config` variant to make this one fault more precise would ripple into `map_repo_err`,
`docs/rust-error-codes.md`, `api_stability.rs` and the Dart docs, for a case the intent does not name.
The reason string carries the key, so the fault is still diagnosable.

**Why the `RemoteNotFound` → `NotAGitRepo` remap is exact and not a widening.** `GitFetch::new`'s
error type IS `UnexpectedGitBackendError` — there is no second failure mode for the blanket
`map_err(|_| …)` to swallow. `GitFetchError::NoSuchRemote`, the arm that legitimately means "no such
remote", is raised later, by `fetch()`, and is untouched. So after this change `git_fetch` reports
exactly the same two conditions as before, under the two codes the rest of the crate already uses for
them.

## Verification

**Commands:**
- `cargo test -p zanshin-jj --test remotes_write` -- expected: all pass, including the renamed
  no-backend test and the two new config tests; then mutation-probe the honours-`false` test by
  temporarily hardcoding `abandon_unreachable_commits: true` in `Repo::git_fetch`'s options and
  confirm ONLY that test fails, and revert.
- `cargo test -p zanshin-jj --test clone_config` -- expected: the single test passes; then
  temporarily restore `clone_into`'s hardcoded struct and confirm the non-boolean phase fails, and
  revert.
- `cargo test -p zanshin-ffi --test repo_write_ffi` -- expected: all pass, including the new
  native-backend `jj.not_a_git_repo` witness and the unmodified `jj.remote_not_found` one.
- `git grep -n "no git backend at all" -- crates docs` -- expected: no surviving hit ties that
  condition to `RemoteNotFound` / `jj.remote_not_found`.
- `cargo make codegen` -- expected: exits 0; afterwards `git status --porcelain` lists only
  `crates/zanshin-ffi/include/zanshin_ffi.h` and `packages/zanshin_core/lib/src/ffi/bindings.dart`
  among generated files.
- `git status --porcelain -- 'crates/zanshin-ffi/src/*_generated.rs' 'packages/zanshin_core/lib/src/ffi/*.ffi_generated.dart' schemas/`
  -- expected: empty after codegen.
- `cargo make test` -- expected: exit 0. Run unpiped and synchronously, allow ~10 minutes (cargo test
  + clippy pedantic `-D warnings` + rustfmt + `flutter test` + dart analyze/format + `cargo deny` +
  the coverage ratchet). The single gate.
- `git status --porcelain` -- expected: clean after each commit.

## Auto Run Result

**Outcome: done.** Both ledger bullets closed; nothing else opened. Code + docs + tests +
regenerated FFI output in commit `824615a`; bookkeeping in the follow-on commit.

**Item 1 — one code for "no git backend" (DELIBERATE observable change).** The `Block If` was
cleared first: `GitFetch::new` in the pinned jj-lib is
`-> Result<Self, UnexpectedGitBackendError>` with `get_git_backend` its only fallible step
(`jj-lib-0.44.0/src/git.rs:3032-3047`), so the blanket `map_err` swallows nothing else and the
remap is exact. `remotes::git_fetch`'s `GitFetch::new` arm now yields `MutateError::NotAGitRepo`
→ `jj.not_a_git_repo`. `jj.remote_not_found` keeps its other producers untouched: `fetch()`'s
`GitFetchError::NoSuchRemote` and the three `git.rs` remote-config verbs. Every pre-existing
`RemoteNotFound` / `jj.remote_not_found` assertion in the four named test files passed
unmodified. Followed through: `remotes.rs` module doc + `# Errors`, `Repo::git_fetch`'s facade,
`MutateError::{RemoteNotFound, NotAGitRepo}` variant docs, `envelope.rs`'s
`JJ_REMOTE_NOT_FOUND` / `JJ_NOT_A_GIT_REPO` consts (a hit the Code Map did not list, but the
grep AC required), `zanshin_git_fetch`'s `extern "C"` doc, both Dart `gitFetch` doc lists, and
the two `docs/rust-error-codes.md` rows, where it is recorded as a deliberate change on BOTH
sides.

**Item 2 — the two `git.*` keys come from config (DEFAULT FLIP).** `remotes::git_fetch` takes
`import_options: &GitImportOptions`; `Repo::git_fetch` loads it exactly as `Repo::git_import`
does. `clone_into` spreads `config::git_import_options` but pins
`record_synthetic_predecessors: false`, reproducing the CLI's own asymmetry
(`fetch.rs:235` vs `clone.rs:384-389` @ v0.44.0, both re-read). **This flips fetch's default for
`git.record-synthetic-predecessors` from the old hardcoded `false` to jj-lib's own `true`** —
not merely "changes something when the user set a key". `git.abandon-unreachable-commits`'s
effective default is unchanged (`true` hardcoded before, `true` from jj-lib's defaults now).
`config::load_for_workspace` was split out of `load`; the six `load(repo)` callers are
untouched. `remote_auto_track_bookmarks` stays EMPTY at all three sites, and
`git_import_options`'s doc sentence saying so is still true and was not rewritten. No new error
code, no new `RepoError` variant, no public signature change.

**Verification.** `cargo make test` run unpiped and synchronously: **exit 0**; coverage held at
**99.20% (8313/8380)** and `coverage-baseline.txt` is byte-identical to baseline `859a3a9` — no
entry lowered, no `exclude_prefix` added. `cargo make codegen` moved only
`crates/zanshin-ffi/include/zanshin_ffi.h` and
`packages/zanshin_core/lib/src/ffi/bindings.dart`; no `*_generated.rs`, no
`*.ffi_generated.dart`, no `schemas/` drift. Both new behaviours were mutation-probed as the
spec asked: forcing `abandon_unreachable_commits: true` failed
`git_fetch_honours_abandon_unreachable_commits_false` and only that test; restoring
`clone_into`'s hardcoded struct failed `clone_config`'s non-boolean phase at exactly its own
assertion. `git grep -n "no git backend at all" -- crates docs` leaves no hit attributing the
condition to `RemoteNotFound` / `jj.remote_not_found`.

**Finding — a PRE-EXISTING latent panic in `git_fetch`, not introduced here, left unfixed.**
The `abandon_unreachable_commits: true` mutation probe did not fail on its assertion; it
panicked inside jj-lib: `transaction.rs:141 "BUG: Descendants have not been rebased after the
last rewrites."` Re-running the probe with the EXACT baseline option pair
(`abandon_unreachable_commits: true, record_synthetic_predecessors: false`) reproduces it
identically, which proves it is pre-existing on `main` and independent of this change.
`remotes::git_fetch` never calls `rebase_descendants()` after `import_refs()` — its comment
claims `import_refs_inner` handles it, which holds only while nothing is abandoned. Because
`abandon_unreachable_commits` defaults to `true` both before and after this run, a default
`git_fetch` that PRUNES a remote bookmark whose commits become unreachable panics today and
still panics after this change — the risk profile is unchanged, but this run is the first to
exercise a pruning fetch at all and so the first to see it. Deliberately NOT fixed here: it is
neither of the two ledger bullets, and a fix changes fetch's transaction handling and needs its
own design + witness. **Not entered in the ledger** either, per this spec's "never defer a
same-shape leftover" rule — it is reported to the caller instead, as a decision for Ralph.

**Superseded 2026-09-05 by the review pass.** The panic WAS fixed, as a bounded scope extension
recorded in `## Spec Change Log` above: `remotes::git_fetch` now runs the same descendant-rebase
pass `crate::git::git_import` already ran for the identical reason, and the default-config branch
has its own witness.

### Review findings breakdown

One four-lens review pass over the implementation diff (`824615a` + `0d3281e`): 11 patches
applied (high 1, medium 5, low 5) in `1b0cbd3` (code, tests, docs, regenerated header +
`bindings.dart`) and `e7eb26e` (spec change log + one ledger clause); 1 item deferred (low —
fetch's empty `MutationResult` projection, pre-existing since Story 6.4a); 10 rejected. No
`intent_gap` and no `bad_spec`, so `review_loop_iteration` stayed at 0. Both behavioural patches
were mutation-probed: removing the rebase pass fails three tests with the jj-lib panic message,
and the `record_synthetic_predecessors: false` spread regression fails exactly the new default
witness.

**Deferred: 1 (recorded in frontmatter `deferred` and under
`## Deferred from: spec-epic-9-followup-c-git-sync-must-haves (2026-09-05)` in
`deferred-work.md`).** The ledger still ends smaller than it started (2 must-haves closed, 1 low
item opened), and the opened item is a payload change the intent excluded, not a same-shape
leftover.

### Follow-up review recommendation

`true`. Counting only this pass's patched findings: high 1, medium 5, low 5 — a `high` patch alone
sets it, and the score 3 × 5 + 1 × 5 = 20 is ≥ 5 as well. The `high` finding was a real defect
(a panic reachable on the default config), fixed and witnessed; the rest were verification and
documentation corrections.

### Closing verification (2026-09-05, after the session-limit interruption)

The run was cut off between the patch commits and this close-out. On the committed tree at
`e7eb26e`, `cargo make test` was re-run unpiped and synchronously by the resuming orchestrator:
exit 0, coverage held (no `coverage-baseline.txt` change). This close-out commit touches only this
spec and `deferred-work.md`.
