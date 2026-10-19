---
title: 'Story 9.20 closing run — clone failures typed on the wire (`jj.network_error`, `jj.invalid_input`)'
type: 'bugfix'
created: '2026-10-20'
baseline_revision: '20002837d99404db5e646e8b2bdeb8aeb66372dd'
status: 'in-progress'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
warnings: ['oversized']
deferred: []
---

<intent-contract>

## Intent

**Problem:** The one item Story 9.20's run deferred, verified against the current code: every failure inside `jj git clone` — an unreachable source or credential failure in the fetch (`GitFetchError::Subprocess`), and an invalid `--remote` name (`GitRemoteManagementError::RemoteName` from `jj_lib::git::add_remote`) — goes through `clone_failed` (`crates/zanshin-jj/src/creation.rs:258`, call sites :478, :537, :541) to `RepoError::CloneFailed`, which `map_repo_err` (`crates/zanshin-ffi/src/repo.rs:55`) sends out as `jj.jj_lib_error`. A GUI cannot tell a network/credential problem or a bad remote name from an internal fault without matching text, while `zanshin_git_fetch` already types the same fetch failure as `jj.network_error`.

**Approach:** Type the two failure classes the ledger names, exactly as `git_fetch` already does (`crates/zanshin-jj/src/remotes.rs:308-316`): the clone's git-subprocess failures (fetch and the default-branch query) become a new `RepoError::NetworkError` → `jj.network_error`; an invalid remote name becomes the existing `RepoError::InvalidInput` → `jj.invalid_input`. Everything else stays `CloneFailed` → `jj.jj_lib_error`. The clean-up scope and warnings are unchanged.

## Boundaries & Constraints

**Always:**
- Only the error classification changes: the failures still happen at the same step, inside the clean-up scope (`clone_into_workspace` → `clone_steps`' clean-up), with the same warnings (the finished `add git remote`'s identity warning, `jj.clone_cleanup_failed`) on the error envelope. `context` carries jj-lib's own message (`e.to_string()`), as today.
- `GitFetchError::Subprocess(_)` → `RepoError::NetworkError { reason }` for BOTH `GitFetch::fetch` and `GitFetch::get_default_branch` (both run git: `git fetch` / `git remote show`), via one shared mapping fn; any other `GitFetchError` variant stays `CloneFailed`.
- `GitRemoteManagementError::RemoteName(_)` from `add_remote` → `RepoError::InvalidInput { reason }` (jj-lib's reason verbatim: reserved name `git`, a slash, or a name gix refuses — the same class `zanshin_git_remote_add` already reports as `jj.invalid_input`); every other `add_remote` error stays `CloneFailed`.
- `RepoError::NetworkError` follows the house doc style of the sibling variants (`repo.rs:32-37`); `map_repo_err` maps it to `JJ_NETWORK_ERROR` with the reason in `context`.
- Docs follow the code: `Repo::clone`'s `# Errors` (`repo.rs:2490-2500`), `zanshin_repo_clone`'s `# Errors` bullets (`crates/zanshin-ffi/src/repo.rs:740-757`) and its `docs/ffi-abi.md` index row (`:481`) — `ffi_abi_doc_sync` requires both lists to match — and the `docs/rust-error-codes.md` rows `jj.network_error` (`:70`, its "Story 9.20 … `zanshin_repo_clone` a failing fetch as `jj.jj_lib_error` — neither emits this code" sentence becomes the clone emission) and `jj.invalid_input` (`:65`, add `zanshin_repo_clone`'s remote-name arm).
- New lines are covered by tests (coverage ratchet: `creation.rs` baseline 96.59 %, no drop).

**Never:**
- No change to push (it reports push failures as data by design), fetch, init or convert error mapping; no new error code (both codes exist); no change to the clone's steps, ordering, clean-up scope or op descriptions.
- An unparseable source URL (`add_remote`'s `InternalGitError` from gix `remote_at`) and other internal failures stay `jj.jj_lib_error` — the ledger asks for network and remote-name typing only.
- No Dart/app API change, no MCP change, no `.fbs` change; never lower the coverage baseline or add an `exclude_prefix`.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Unreachable source | `source` = `file://` path that does not exist, or a plain non-git directory | `.jj`/`.git` removed, created destination removed; the `add git remote` identity warning kept | `RepoError::NetworkError` → `jj.network_error`, git's message in `context` |
| Invalid remote name | valid source, `remote_name` = `git` (or `a/b`) | refused at `add git remote`, inside the clean-up scope; created destination removed | `RepoError::InvalidInput` → `jj.invalid_input`, jj-lib's reason in `context` |
| Uncreatable destination | `/nonexistent/...` | unchanged | `CloneFailed` → `jj.jj_lib_error` ("Failed to create …") |
| Successful clone | local source | unchanged (ops, presets, warnings) | — |

</intent-contract>

## Code Map

- `crates/zanshin-jj/src/creation.rs:258-260` -- `clone_failed`; `:471-496` `configure_remote` (`add_remote` at :478 — the remote-name arm); `:502-582` `fetch_new_remote` (`fetcher.fetch` :535-537 and `get_default_branch` :539-541 — the subprocess arms; `GitFetch::new` :528 and `import_refs` :538 stay `clone_failed`). `GitFetchError` / `GitRemoteManagementError` need importing from `jj_lib::git`.
- `crates/zanshin-jj/src/remotes.rs:308-316` -- the template: `git_fetch`'s `GitFetchError::Subprocess(sub) => MutateError::NetworkError { reason: sub.to_string() }`.
- `crates/zanshin-jj/src/repo.rs:13-89` -- `RepoError` (add `NetworkError { reason: String }` next to `CloneFailed`); `:2490-2500` `Repo::clone` `# Errors`.
- jj-lib 0.46.0 (vendored, read-only): `git.rs:2365-2382` `GitRemoteManagementError` (`RemoteName(#[from] GitRemoteNameError)`), `:2609-2647` `add_remote` (`validate_remote_name` :169-178 runs first, before any git config write), `:2908-2917` `GitFetchError` (`Subprocess(#[from] GitSubprocessError)`), `:3363-3370` `get_default_branch` (`spawn_remote_show(..)?` → `Subprocess`); `git_subprocess.rs:54-78` `GitSubprocessError` (`NoSuchRepository`, `Spawn*`, `Wait`, `UnsupportedGitOption`, `External`). CLI v0.46.0 `command_error.rs:583-631`: both are `user_error`s (no internal error).
- `crates/zanshin-ffi/src/repo.rs:43-110` -- `map_repo_err` (`:55` the shared jj_lib_error arm); inline tests `:1445-1501` (add one for `NetworkError`); `:740-757` `zanshin_repo_clone` `# Errors`. `JJ_NETWORK_ERROR` already exists in `envelope.rs`.
- `crates/zanshin-jj/tests/clone_init.rs:271-305` (`a_failing_fetch_cleans_up_what_the_clone_created`, missing `file://` path → flip to `NetworkError`), `:307-325` (`an_invalid_remote_name_fails_and_cleans_up`, remote `git` → flip to `InvalidInput`), `:725-753` (`a_failing_fetch_keeps_the_identity_warning…`, plain directory source → `NetworkError`).
- `crates/zanshin-jj/tests/repo.rs:204-248` -- two tests with source `not-a-real-url://nope`: whether that fails in gix `remote_at` (stays `CloneFailed`) or in the git subprocess (`NetworkError`) is not known up front — run them, assert the observed variant, rename the tests to say what they witness, and note the finding in the Spec Change Log.
- `crates/zanshin-ffi/tests/repo_ffi.rs:298-309` -- `repo_clone_with_invalid_url_returns_jj_lib_error` (same URL; `repo_clone` helper) — keep one wire test per class: an unreachable `file://` source → `jj.network_error`, an invalid remote name → `jj.invalid_input` (needs a request with `remote_name`; see the file's request builder), both with `.jj` gone afterwards.
- `crates/zanshin-jj/tests/api_stability.rs:1538-1540` -- pin `RepoError::NetworkError { reason: String::new() }` beside the 9.20 pins.
- `packages/zanshin_core/test/worker/creation_test.dart:85-103` -- real-cdylib clone refusal template; an invalid remote name is refused before any git runs (gix init + `validate_remote_name`), so it is the one Dart-reachable witness: `cloneRepo(source: 'file:///nowhere', destination: <empty temp subdir>, remoteName: 'git', noColocate: true)` → `ZanshinFfiException` code `jj.invalid_input`, destination removed. A network failure needs a git child (the Dart VM reaps it) — Rust/FFI only.
- `docs/rust-error-codes.md:65,70`, `docs/ffi-abi.md:481` -- rows to update (see Always).

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/src/repo.rs` -- add `RepoError::NetworkError { reason }` (doc: the clone's `git` subprocess failed — network, authentication or transport; Story 9.20 closing run); update `Repo::clone`'s `# Errors` (new variant; `InvalidInput` gains the remote name; `CloneFailed` loses the fetch and the remote name).
- `crates/zanshin-jj/src/creation.rs` -- a `fetch_error(GitFetchError) -> RepoError` used by `fetch` and `get_default_branch`; `add_remote`'s error mapped with `RemoteName` → `InvalidInput`, rest → `clone_failed`.
- `crates/zanshin-ffi/src/repo.rs` -- `map_repo_err` arm `NetworkError` → `JJ_NETWORK_ERROR`; inline unit test; `zanshin_repo_clone` `# Errors` gains `jj.network_error` and the remote name under `jj.invalid_input`, `jj.jj_lib_error` narrowed.
- `crates/zanshin-jj/tests/{clone_init,repo,api_stability}.rs`, `crates/zanshin-ffi/tests/repo_ffi.rs`, `packages/zanshin_core/test/worker/creation_test.dart` -- flip/add per the Code Map and the matrix.
- `docs/rust-error-codes.md`, `docs/ffi-abi.md` -- rows per Always.
- `_bmad-output/implementation-artifacts/deferred-work.md` -- mark the ledger entry "Clone failures are untyped on the wire" resolved (struck/annotated in the file's existing style) with the fix commit.

**Acceptance Criteria:**
- Given each matrix row, when `zanshin_repo_clone` is called over FFI (and `Repo::clone` in Rust), then the envelope's error code is the row's code with the stated `context`, the clean-up result is as stated, and the warnings are unchanged.
- Given `cloneRepo` with remote name `git` in `packages/zanshin_core` (real cdylib), then it throws `ZanshinFfiException` with code `jj.invalid_input` and no `.jj` remains.
- Given `cargo make test` on the final tree (repo root, unpiped), then it exits 0 — incl. `ffi_abi_doc_sync` and the coverage ratchet with no drop — and `git status --porcelain` is clean with every commit carrying the co-author trailer.

## Spec Change Log

## Review Triage Log

## Design Notes

Why a new `RepoError` variant rather than reusing `MutateError::NetworkError`: creation paths return `RepoError` (`CreationOutcome`), and `map_repo_err` is the single wire mapping for them; one variant + one arm mirrors `DestinationNotEmpty`/`GitRepoExists` from Story 9.20.

Why only `Subprocess`: it is exactly `git_fetch`'s rule for the same jj-lib call, so a GUI sees one code for "git could not reach/authenticate the remote" whether it fetched or cloned. `GitSubprocessError::Spawn*` (git missing) also lands there, as it does for fetch today.

## Verification

**Commands:**
- `cargo test -p zanshin-jj --test clone_init --test repo --test api_stability` -- expected: pass.
- `cargo test -p zanshin-ffi --test repo_ffi --test ffi_abi_doc_sync` and `cargo test -p zanshin-ffi --lib repo::` -- expected: pass.
- `cargo make test` (repo root, unpiped, synchronous, long timeout) -- expected: exit 0.
