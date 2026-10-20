---
title: 'Story 9.20 closing run — clone failures typed on the wire (`jj.network_error`, `jj.invalid_input`)'
type: 'bugfix'
created: '2026-10-20'
baseline_revision: '20002837d99404db5e646e8b2bdeb8aeb66372dd'
status: 'done'
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

- 2026-10-20 (implementation): the open question of `crates/zanshin-jj/tests/repo.rs`'s `not-a-real-url://nope` source is answered by running it — gix `remote_at` accepts the URL (`add git remote` succeeds) and the fetch's `git` subprocess fails ("fatal: remote helper 'not-a-real-url' aborted session"), so it is `RepoError::NetworkError`. The two tests are renamed `repo_clone_with_unknown_url_scheme_returns_network_error` and `repo_clone_network_failure_leaves_no_partial_workspace`. The FFI wire test `repo_clone_with_invalid_url_returns_jj_lib_error` is replaced by one test per class (`…_from_an_unreachable_source_returns_network_error`, `…_with_an_invalid_remote_name_returns_invalid_input`) plus `…_into_an_uncreatable_destination_returns_jj_lib_error` for the matrix's unchanged row on the wire.

## Review Triage Log

### 2026-10-20 — Review pass
- verdicts: 22 findings — high 0, medium 0, low 15, false 7, maybe-false 0 (edge-case layer: no findings)
- findings:
  - `[low]` `[patch]` (verification-gap 1) the default-branch query's network arm (`get_default_branch(..).map_err(fetch_error)`) had no test; every network test failed inside `fetch` first — group A: `clone_init.rs::a_failing_default_branch_query_is_a_network_error_and_cleans_up` (empty `-b` list → no refspecs → `fetch` runs no git, `git remote show` fails) (bd0c7bc); witnessed by a mutation run: reverting that call site to `clone_failed` makes the test fail.
  - `[low]` `[patch]` (verification-gap other 1) `packages/zanshin_core/lib/src/ffi/repo.dart:93` `zanshinRepoClone`'s hand-written "Errors:" list lacked `jj.network_error` — group B: added (bd0c7bc).
  - `[false]` `[reject]` (intent 1) no `## Auto Run Result` yet — a mid-run state; finalisation writes it.
  - `[false]` `[reject]` (intent 2) the run struck the existing deferred-work.md entry — the dispatch forbids only re-mirroring it; marking a ledger item RESOLVED is the ledger's own convention (every closing run does it) and was a task of this spec.
  - `[low]` `[reject]` (intent 3) the network class is not witnessed at the `packages/zanshin_core` surface — unreachable there: a network failure needs a `git` child, which the Dart VM reaps (`creation_test.dart`'s WHY note); witnessed on the wire (`repo_ffi.rs`) and in Rust.
  - `[low]` `[reject]` (intent 4) no authentication-failure witness — an auth failure is the same `GitSubprocessError::External` as any failing git child; a credential-rejecting remote needs a local auth server for a mapping arm already witnessed.
  - `[low]` `[reject]` (intent 5) `jj.network_error` also covers non-network causes (git not runnable, an unknown URL scheme) — group C, see blind 1.
  - `[low]` `[patch]` (intent 6) the Dart wrapper error list — group B, see verification-gap other 1.
  - `[false]` `[reject]` (intent 7) renamed / replaced 9.20 tests exceed "only as far as the item needs" — each flipped or replaced test asserted the old `CloneFailed` / `jj.jj_lib_error` the item changes; the uncreatable-destination wire test pins the matrix row that must stay `jj.jj_lib_error`.
  - `[low]` `[reject]` (blind 1) every `GitFetchError::Subprocess` becomes `jj.network_error`, also `Wait` / `Spawn*` / `UnsupportedGitOption` — group C: exactly the ledger's named mapping and `zanshin_git_fetch`'s existing rule for the same jj-lib call (one code for both verbs); `GitSubprocessError` is not nameable outside jj-lib, so splitting it needs a jj-lib type the crate cannot match on plus a new code; the reason (now with its cause, blind 3) says which.
  - `[low]` `[reject]` (blind 2) under the Dart VM every clone that reaches the fetch now fails as `jj.network_error` (`Wait`) instead of `jj.jj_lib_error` — group C; the underlying "clone/push from the running app unverified" gap is pre-existing and already ledgered (Story 9.20's residual risks / deferred-work); the code swaps one generic code for another in an already-broken environment.
  - `[low]` `[patch]` (blind 3) `context` lost the `#[source]` cause of `Spawn*` / `Wait`, and the docs called the text "git's message" — group D: `fetch_error` builds the reason with `mutate::flatten_chain(&e)`; "the git failure (jj-lib's message with its cause)" in the variant doc, `Repo::clone`, the `zanshin_repo_clone` bullet (+ codegen) and the registry row (bd0c7bc).
  - `[low]` `[patch]` (blind 4) default-branch arm untested — group A, see verification-gap 1.
  - `[low]` `[patch]` (blind 5) the `CloneFailed` / `jj.jj_lib_error` docs dropped fetch failures that still land there (rejected ref updates) — group E: one phrase back in the variant doc, `Repo::clone` and the `zanshin_repo_clone` bullet (+ codegen) (bd0c7bc).
  - `[low]` `[patch]` (blind 6) Dart wrapper error list — group B.
  - `[low]` `[patch]` (blind 7a) the `jj.network_error` row's "No operation is committed" is not literally true for a clone — group F: qualified (fetch commits none; a clone's committed `add git remote` op is removed with the workspace by the clean-up) (bd0c7bc).
  - `[low]` `[reject]` (blind 7b) the `jj.invalid_input` Meaning column says "for a mutation" — pre-existing wording that already mismatches most of its emitters (config readers, file reads, environment adopt); rewriting the shared column is beyond this item.
  - `[low]` `[patch]` (blind 8) the wire remap is not flagged as a deliberate observable change — group F: the registry row marks the clone emission "DELIBERATE OBSERVABLE CHANGE (was `jj.jj_lib_error`)"; the `docs/ffi-abi.md` row's Story column adds "9.20 closing run" (bd0c7bc).
  - `[false]` `[reject]` (blind 9) "warnings are unchanged" not asserted over FFI — the diff touches no warning code (the sink is filled independently of the error variant), and the Rust network test still asserts the finished `add git remote`'s identity warning (`clone_init.rs`), which the envelope carries by the unchanged `creation_envelope`.
  - `[false]` `[reject]` (blind 10) the ledger was closed before the review finished — the cited fix commit 24ce688 is the fix; finalisation adds the review-patch commit to the ledger line.
  - `[low]` `[reject]` (blind 11) the uncreatable-destination wire test hardcodes `/nonexistent/...` — the same pattern the existing `tests/repo.rs:110` test uses; the gate never runs as root on macOS.
  - `[low]` `[patch]` (blind 12) `zanshin_ffi::JJ_INVALID_INPUT` written as a full path while `JJ_NETWORK_ERROR` is imported — imported in the `use` list (bd0c7bc).
  - `[false]` `[reject]` (blind 13) the FFI remote-name test covers only `git` — the wire mapping is per variant (`RepoError::InvalidInput`), and both names are asserted on that variant in `clone_init.rs`; a second wire case adds no witness.

## Design Notes

Why a new `RepoError` variant rather than reusing `MutateError::NetworkError`: creation paths return `RepoError` (`CreationOutcome`), and `map_repo_err` is the single wire mapping for them; one variant + one arm mirrors `DestinationNotEmpty`/`GitRepoExists` from Story 9.20.

Why only `Subprocess`: it is exactly `git_fetch`'s rule for the same jj-lib call, so a GUI sees one code for "git could not reach/authenticate the remote" whether it fetched or cloned. `GitSubprocessError::Spawn*` (git missing) also lands there, as it does for fetch today.

## Verification

**Commands:**
- `cargo test -p zanshin-jj --test clone_init --test repo --test api_stability` -- expected: pass.
- `cargo test -p zanshin-ffi --test repo_ffi --test ffi_abi_doc_sync` and `cargo test -p zanshin-ffi --lib repo::` -- expected: pass.
- `cargo make test` (repo root, unpiped, synchronous, long timeout) -- expected: exit 0.

## Auto Run Result

Status: done (2026-10-20). Blocking condition: none.

**Items handed to this closing run.**
1. **Clone failures are untyped on the wire — fixed** (commit `24ce688c436063e4b859729960ec91f6148355da`, review patches `bd0c7bc695f2579c6476f701a5e151256b63ed3c`).
   - Verified first: `configure_remote` and `fetch_new_remote` (`crates/zanshin-jj/src/creation.rs`) sent every failure through `clone_failed` → `RepoError::CloneFailed` → `jj.jj_lib_error` (`crates/zanshin-ffi/src/repo.rs` `map_repo_err`), while `zanshin_git_fetch` already typed the same jj-lib failure as `jj.network_error`.
   - Now: the clone's `git` subprocess failures (`GitFetchError::Subprocess` from the fetch and from the default-branch query `git remote show`) are the new `RepoError::NetworkError` → `jj.network_error`, with jj-lib's message and its cause in `context`; a remote name jj refuses (`GitRemoteManagementError::RemoteName`: reserved `git`, a slash, a name gix rejects) is `RepoError::InvalidInput` → `jj.invalid_input`; everything else stays `jj.jj_lib_error`. Steps, ordering, clean-up scope and warnings are unchanged.

**Summary.** One new `RepoError` variant and its FFI arm, two error-mapping fns in `creation.rs`, docs and tests. No `.fbs`, Dart API, push, fetch or init change.

**Files changed:**
- `crates/zanshin-jj/src/repo.rs` — `RepoError::NetworkError`; `CloneFailed` / `InvalidInput` docs; `Repo::clone` `# Errors`.
- `crates/zanshin-jj/src/creation.rs` — `fetch_error`, `add_remote_error`; inline test for the arms that stay `CloneFailed`.
- `crates/zanshin-ffi/src/repo.rs` — `map_repo_err` `NetworkError` → `jj.network_error`; inline test; `zanshin_repo_clone` `# Errors`; regenerated `zanshin_ffi.h` / `bindings.dart` (doc comments only).
- `packages/zanshin_core/lib/src/ffi/repo.dart` — `zanshinRepoClone`'s error list.
- Tests: `crates/zanshin-jj/tests/{clone_init,repo,api_stability}.rs` (flipped to the typed variants, a default-branch-query witness, the `NetworkError` pin), `crates/zanshin-ffi/tests/repo_ffi.rs` (one wire test per class + the unchanged uncreatable-destination row), `packages/zanshin_core/test/worker/creation_test.dart` (reserved remote name → `jj.invalid_input`, real cdylib).
- Docs: `docs/rust-error-codes.md` (`jj.network_error` row: clone emission, deliberate observable change; `jj.invalid_input` row: clone remote name), `docs/ffi-abi.md` (`zanshin_repo_clone` row).
- `coverage-baseline.txt` — `creation.rs` 96.59 → 96.74 (raised by the gate).
- Tracking: `deferred-work.md` (the item marked RESOLVED), this spec. No new deferrals, so no "Surfaced in the closing run of Story 9.20" section was added.

**Deviations from the spec (Spec Change Log).** The `not-a-real-url://nope` source fails in the git subprocess, not in gix, so those two `tests/repo.rs` tests now witness `NetworkError` (renamed).

**Review findings.** 22 findings (high 0, medium 0, low 15, false 7, maybe-false 0); the edge-case layer reported none.
- **Patched, 6 entries (all low):** the default-branch-query witness (verification-gap 1, blind 4; mutation-checked); the Dart wrapper's error list (verification-gap other 1, intent 6, blind 6); the reason keeps its cause + doc wording (blind 3); fetch failures that stay `jj.jj_lib_error` named in the docs (blind 5); the registry row's "no operation" qualified and the remap marked a deliberate observable change, ffi-abi Story column (blind 7a, blind 8); the `JJ_INVALID_INPUT` import (blind 12). Applied by the implementation subagent on re-engagement.
- **Deferred:** none.
- **Rejected:** network class not witnessed in Dart (git child reaped by the VM); no auth-failure witness (same `External` arm); `jj.network_error` covering `Wait` / `Spawn*` / unknown schemes (×3 — the ledger's named mapping and `git_fetch`'s rule; `GitSubprocessError` is not nameable outside jj-lib); the shared `jj.invalid_input` "for a mutation" wording (pre-existing, mismatches most emitters); the hardcoded `/nonexistent` path (existing pattern, no root runs).
- **False:** Auto Run Result missing (mid-run); striking the ledger entry (ledger convention, not a re-mirror); renamed tests out of scope (they asserted the changed codes); warnings unasserted over FFI (no warning code touched; Rust witness stands); ledger closed early (fix commit correct; patch commit added at finalisation); only `git` over the wire (per-variant mapping).

**Follow-up review recommendation:** false — this first pass patched 6 entries, all low (patched counts: high 0, medium 0, low 6).

**Verification:**
- Implementation run: `cargo test -p zanshin-jj --test clone_init --test repo --test api_stability`, `--lib creation::`, `cargo test -p zanshin-ffi --test repo_ffi --test ffi_abi_doc_sync`, `--lib repo::` pass; `cargo make test` exit 0 on `24ce688` (≈ 890 s).
- Orchestrator, on the patched tree (`bd0c7bc`): the targeted commands above pass; mutation check (default-branch call site reverted to `clone_failed` → the new test fails; reverted). The gate plan was "every step" (`coverage-baseline.txt` changed); each of its 29 tasks (incl. `gate-plan` and `gate-stamp`) ran as its own `cargo make --allow-private <task>` (one `cargo make test` exceeds this session's 10-minute foreground limit): clippy, fmt, cargo-doc, deny, hygiene, jj-adapter-hygiene, the core/app/shell/settings/ui analyze/format/test steps (app 743, zanshin_core 867 tests passed), `gate-coverage` exit 0 (held at 99.07 %, every extern covered, baseline unchanged), then `gate-stamp`.
- Matrix audit: Unreachable source — `clone_init.rs` (missing path, plain directory with the identity warning, empty `-b` list), `tests/repo.rs`, `repo_ffi.rs` wire test; Invalid remote name — `clone_init.rs` (`git`, `a/b`), `repo_ffi.rs`, `creation_test.dart`; Uncreatable destination — `tests/repo.rs`, `repo_ffi.rs`; Successful clone — the existing `clone_init.rs` / oracle clone tests (all ran and passed).

**Residual risks:**
- A GUI branching on `jj.network_error` for clone also sees "git not runnable" and the Dart-VM child-reaping `Wait` failure under that code (same as `zanshin_git_fetch`); the reason text distinguishes them.
- The gate's run of this tree was step by step, not one `cargo make test` invocation (same tasks, same plan).
