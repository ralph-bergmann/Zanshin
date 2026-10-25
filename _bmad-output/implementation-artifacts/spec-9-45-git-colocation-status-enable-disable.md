---
title: 'Story 9.45: `git colocation status | enable | disable` — per workspace (jj 0.46)'
type: 'feature'
created: '2026-10-25'
status: 'done'
baseline_revision: '65aee07970e4468174faa3d2d44801d011a4ccbd'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
warnings: ['oversized']
deferred:
  - summary: >-
      A second open handle on the same repo keeps a GitBackend that points at the old Git directory after its default workspace's colocation is toggled (by Zanshin on another handle, or by the jj CLI).
    evidence: |-
      `GitBackend` caches the Git repo path from `store/git_target` at load; a handle reloads its workspace only when the config-stack fingerprint or the per-command resolution changes, never when `git_target` changes. `colocation::reload` replaces only the calling handle's workspace. The same staleness already follows a `jj git colocation enable|disable` run by the CLI in a terminal, so it is not new with this story.
    location: >-
      crates/zanshin-jj/src/repo.rs (start_call / refresh_settings reload rule); crates/zanshin-jj/src/colocation.rs (reload)
    severity: medium
    resolved: >-
      2026-10-26 — fixed (spec-9-45-closing-sibling-handle-follows-git-target, commit 6c19d53): every handle records the `store/git_target` bytes it loaded and reloads its workspace at call start (also in the op-pinned reads) when the bytes on disk differ.
---

<intent-contract>

## Intent

**Problem:** jj 0.46's `jj git colocation status|enable|disable` (`cli/src/commands/git/colocation.rs` @ v0.46.0) reports whether a workspace shares its working copy with Git and converts an EXISTING jj repo/workspace between colocated and non-colocated — for the default workspace (moving the Git repo between `.jj/repo/store/git` and `<root>/.git`) and, since 0.46, for child workspaces (creating / removing a Git worktree). Zanshin has none of it: its conversions (Stories 2.12/2.13) only create a new jj repo (deferred-work I1, Story 9.45's part).

**Approach:** Port the three verbs step for step through the full chain (`zanshin-jj` → handle-only `extern "C"` → `WorkerCommand`/`RepoHandle`), reusing what Stories 9.13/9.23/2.12 already ported (`is_colocated_git_workspace`, `maybe_add_gitignore`, `unlink_worktrees`, `git::create_worktree`, `reload_workspace`, `finish_verb`). `status` is a typed read; `enable`/`disable` return a `MutationResult` plus the CLI's status lines as typed facts.

## Boundaries & Constraints

**Always:**
- Behavior = the CLI @ v0.46.0, in its order. All three run the pre-verb precondition (the CLI's `workspace_helper` snapshots) via `with_verb` with `cli_command::GIT_COLOCATION_{STATUS,ENABLE,DISABLE}` = `"git colocation status|enable|disable"`; then `get_git_backend` (non-Git backend → `MutateError::NotAGitRepo`), then the colocation check (`ctx.colocated`, computed at the call's start exactly as the CLI's `is_colocated_git_workspace`).
- **status** → `GitColocationStatus { colocated, workspace_name, git_head: OpRefTarget (the view's `git_head(name)`, projected like `op_diff::ref_target`), git_repo_path (`GitBackend::git_repo_path()`), external_git_repo, hints }`. `external_git_repo` = the CLI's middle hint condition (not colocated, not a child workspace, and `<repo_path>/store/git` does not exist). `hints` = the CLI's one hint line verbatim without `Hint: `: colocated → ``To disable colocation, run: `jj git colocation disable` ``; external → `Colocation cannot be enabled because the workspace is backed by an external Git repository.`; else ``To enable colocation, run: `jj git colocation enable` ``. Writes no operation of its own.
- **enable**: already colocated → `converted: false` + the house no-op result (the CLI's "Workspace is already colocated with Git."). No working-copy commit → `MutateError::NoWorkingCopy`. Child workspace (`<root>/.jj/repo` is a FILE) → `git::create_worktree(store, git_subprocess_options, root)` (error → `MutateError::GitWorktree(chain)`, as `workspace_add`). Default workspace → `rename(<repo>/store/git, <root>/.git)` with the CLI's mapping: `AlreadyExists|DirectoryNotEmpty` → `InvalidInput "A .git directory already exists in the workspace root. Cannot colocate."`; `NotFound` → `InvalidInput "Cannot colocate a workspace backed by an external Git repository at <git_repo_path>"`; other → `InvalidInput "Failed to move Git repository from .jj/repo/store/git to workspace root directory.: <err>"`; then write `store/git_target` = `../../../.git`, then `core.bare = false` (see Design Notes). Then reload the workspace (replace the handle's `Workspace`), load the repo at the PRE-MOVE op id, `maybe_add_gitignore`, `git::reset_head` to `@`'s parent (error → `Backend "Failed to reset Git HEAD state: <chain>"`), finish as `set git head to working copy parent` through `finish_verb` with `ctx.colocated` re-read from the reloaded workspace (so the colocated finish resets HEAD and exports refs, as the CLI's `tx.finish`; no changes → no operation).
- **disable**: not colocated → `converted: false` + no-op ("Workspace is already not colocated with Git."). Child → `workspace_ops::unlink_worktrees` on `[root]` (a failure is the existing `jj.git_worktree_unlink_failed` warning; success sets `git_worktree_removed: true`, the CLI's "Removed Git worktree for …"). Default → `rename(<root>/.git, <repo>/store/git)` (error → `InvalidInput "Failed to move Git repository to .jj/repo/store/git: <err>"`), `core.bare = true`, `git_target` = `git`. Then `remove_file(<root>/.jj/.gitignore)` ignoring errors, reload, load at the pre-move op, `set_git_head_target(name, RefTarget::absent())`, finish as `remove git head reference` (no changes → no operation).
- Result `GitColocationResult { mutation: MutationResult, converted: bool, git_worktree_removed: bool }`. Op descriptions byte-identical. No rollback after the move: a later failure leaves the disk as the CLI leaves it; the handle's workspace is the reloaded one whenever the reload succeeded.

**Never:** No `ui.status` text as data beyond the typed facts; no new error codes or warning kinds; no MCP surface; no change to existing verbs' behavior (only `pub(crate)` visibility of reused helpers); never `jj`/`git` in any directory but a test's own temp dir.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Status, non-colocated default | `--no-colocate` repo | `colocated=false`, name `default`, git_head absent, enable hint, `external_git_repo=false` | — |
| Status, colocated | colocated repo with a commit | `colocated=true`, git_head = `@-`'s commit, disable hint | — |
| Status, external Git | `jj git init --git-repo=<ext>` | `external_git_repo=true`, external hint | — |
| Enable default | non-colocated, one commit | `<root>/.git` dir, `store/git` gone, `git_target`=`../../../.git`, `core.bare=false`, `.jj/.gitignore`=`/*\n`, Git HEAD = `@-`, op `set git head to working copy parent`, `converted=true`; a fresh `Repo::open` reports colocated | — |
| Enable empty repo | non-colocated, no commits | converted; layout as above; no-op mutation if nothing changed | — |
| Enable already colocated | colocated | `converted=false`, no operation | — |
| Enable, `.git` exists | non-colocated + non-empty `<root>/.git` | — | `jj.invalid_input` "A .git directory already exists…", store untouched, no operation |
| Enable, external Git | `--git-repo` repo | — | `jj.invalid_input` "Cannot colocate a workspace backed by an external Git repository at <path>" |
| Disable default | colocated, one commit | `.git` gone, `store/git` bare (`core.bare=true`), `git_target`=`git`, no `.jj/.gitignore`, git_head absent, op `remove git head reference`, `converted=true` | — |
| Disable not colocated | non-colocated | `converted=false`, no operation | — |
| Round trip | non-colocated → enable → disable | layout back to the start; `status` agrees at each step | — |
| Enable child | `--no-colocate` + `workspace add ../ws2`, handle at ws2 | `ws2/.git` FILE (gitlink), `ws2/.jj/.gitignore`, ws2's git_head = its `@-`, `converted=true` | — |
| Disable child | colocated + colocated `ws2`, handle at ws2 | `ws2/.git` gone, no `ws2/.jj/.gitignore`, `git_worktree_removed=true`, ws2's git_head absent | unlink failure → warning only |
| Enable child, `.git` exists | child with `ws2/.git` dir | — | `jj.git_worktree_failed` "A .git file or directory already exists in the Git worktree destination", no worktree added |
| Non-Git backend | local-backend workspace | — | `jj.not_a_git_repo` (all three) |

</intent-contract>

## Code Map

- `../jj` @ v0.46.0: `cli/src/commands/git/colocation.rs` (the whole port: `cmd_git_colocation_{status,enable,disable}`, `set_git_repo_bare`, `set_git_head_to_wc_parent`, `remove_git_head`, `reload_workspace_helper`, `is_child_workspace`); `cli/src/commands/git/mod.rs:110` `maybe_add_gitignore`; `cli/src/git_util.rs:67` `is_colocated_git_workspace`, `:572` `unlink_git_worktree`; `cli/src/command_error.rs:633-648` (`GitCreateWorktreeError`/`UnexpectedGitBackendError` → `user_error`, `GitResetHeadError` → "Failed to reset Git HEAD state"); tests `cli/tests/test_git_colocation.rs` (the matrix rows come from them, incl. child workspaces :445-610).
- jj-lib 0.46.0 (`~/.cargo/registry/src/index.crates.io-1949cf8c6b5b557f/jj-lib-0.46.0/src/`): `git.rs:1860` `create_worktree`, `:1955` `unlink_worktree`, `:1998` `reset_head`, `:2435` `save_git_config`; `git_backend.rs:412` `git_repo_path`.
- `crates/zanshin-jj/src/wc_ops.rs:361` `is_colocated_git_workspace`; `convert.rs:458` `maybe_add_gitignore(root, colocated)`; `workspace_ops.rs:95` `unlink_worktrees` (make `pub(crate)`); `workspace_add.rs:161-163` `git_subprocess_options` + `create_worktree` → `MutateError::GitWorktree`; `op_diff.rs:361` `ref_target` (make `pub(crate)`); `mutate.rs:948` `finish_verb`, `:992` `mutation_result`, `:1546` `no_op_result`; `snapshot.rs:325` `reload_head`; `op_support::start_repo_transaction`; `repo.rs:2017` `reload_workspace` (the `Workspace::load` call to mirror inside the module fn).
- NEW `crates/zanshin-jj/src/colocation.rs` -- `status`, `enable`, `disable`, `set_git_repo_bare`, result types; module docs citing v0.46.0 and the divergences (status lines as facts).
- `crates/zanshin-jj/src/repo.rs` -- facades `git_colocation_status/enable/disable(&mut self)` via `with_verb(..., |repo, ctx| crate::colocation::x(repo.workspace_mut(), ctx))`, rustdoc + `# Errors` like `workspace_forget` (:2700-2730); `records!` lines in `every_verb_resolves_for_its_cli_command` (:4908-5105). `lib.rs` -- `mod colocation;` + `pub use colocation::{GitColocationResult, GitColocationStatus};` (like :154).
- `crates/zanshin-jj/src/cli_command.rs` -- `GIT_COLOCATION_DISABLE/ENABLE/STATUS` between `GIT_CLONE` (:111) and `GIT_EXPORT` (:113); audited by `every_name_is_a_canonical_subcommand_path_of_the_pinned_cli` (:213).
- `crates/zanshin-jj/tests/it/` -- new `git_colocation.rs` (+ `main.rs`), fixtures built in temp dirs via `Repo::init`/`workspace_add` (see `workspace_add.rs`, `workspace_ops.rs` tests for child-workspace setup); `api_stability.rs` cast lines.
- `schemas/envelope.fbs` -- `table GitColocationStatus`, `table GitColocationResult` (reuse `OpRefTarget` :1656, `MutationResult`), appended to `union Payload` after `FoundChanges` (:3071). Handle-only fns need NO `RequestKind`. Then `cargo make codegen`; commit `envelope_generated.rs`, `zanshin_ffi.h`, `envelope_zanshin.ffi_generated.dart`, `bindings.dart` (check `packages/zanshin_core/ffigen.yaml`'s allow-list).
- `crates/zanshin-ffi/src/git.rs` -- `zanshin_git_import` (:247) is the handle-only template; add the three `zanshin_git_colocation_*` with `precondition_envelope(.., map_mutate_err, builder)`; `op_log.rs:149` `ref_target_to_fbs` (make `pub(crate)`), `build_mutation_result`. Tests `crates/zanshin-ffi/tests/it/git_ffi.rs`; doc sync `tests/it/ffi_abi_doc_sync.rs`.
- `packages/zanshin_core/lib/src/ffi/git.dart` (`zanshinGitImport` :39 + decoders; reuse `OpRefTarget` from `ffi/op_log.dart:197`), `worker/commands.dart:1017` (`GitImportCommand`), `worker/isolate.dart:2416` + dispatch :4687, `worker/handle.dart:1816`; tests `test/worker/git_test.dart` (real cdylib, one per extern fn) and `test/ffi/`.
- `crates/zanshin-parity/tests/oracle/scenarios.rs` -- `Scenario` (:78), `simple` (:102), `NO_COLOCATE` (:309), `GIT_INIT` (:37), `ADD_WS2` (:5292), `extra` read-backs (`ws2_read_back` :227); `main.rs` `parity!` id list; `state.rs` compares "git HEAD (.git on disk)" and "colocated (.git dir)" of the default root only.
- `docs/ffi-abi.md` (index from :589, section pattern :1754), `docs/rust-error-codes.md` (`jj.no_working_copy` :48, `jj.not_a_git_repo` :51, `jj.invalid_input` :66, `jj.git_worktree_failed` :82, `jj.jj_lib_error`, warning `jj.git_worktree_unlink_failed` :170).

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/src/colocation.rs` (+ `lib.rs`, visibility bumps in `workspace_ops.rs`, `op_diff.rs`) -- the three fns per Boundaries; inline unit tests for `set_git_repo_bare` (both values round-trip in a temp Git config) and the rename-error mapping fn.
- `crates/zanshin-jj/src/repo.rs`, `cli_command.rs` -- facades, table entries, `records!` lines.
- `crates/zanshin-jj/tests/it/git_colocation.rs` (+ `main.rs`, `api_stability.rs`) -- one witness per matrix row on the Rust API, incl. the round trip with a fresh `Repo::open` after each step and on-disk layout asserts (`.git` kind, `git_target`, `core.bare`, `.jj/.gitignore`).
- `schemas/envelope.fbs` + `cargo make codegen` -- the two tables, documented like `WorkspaceRemoveResult`; generated files committed.
- `crates/zanshin-ffi/src/git.rs`, `op_log.rs` + `tests/it/git_ffi.rs` -- three extern fns, round trips (status before/after enable, enable, disable) and refusals (handle 0, `.git` exists).
- `packages/zanshin_core` -- adapters, models `GitColocationStatus`/`GitColocationResult`, three commands, client methods + dispatch, `RepoHandle.gitColocationStatus/Enable/Disable`; real-cdylib worker tests per extern fn (round trip + a refusal + closed handle) and ffi decode tests.
- `crates/zanshin-parity/tests/oracle/scenarios.rs` + `main.rs` -- scenarios `git_colocation_{status_*,enable,enable_empty,enable_already,enable_git_dir_exists,disable,disable_not_colocated,disable_after_cli_enable,enable_child,disable_child,enable_child_git_dir_exists}`; the CLI argv `["git","colocation",…]` (child: prefixed `-R ../ws2`; Zanshin opens `Repo::open(root.join("../ws2"))`); an `extra` read-back of the layout (`.git` kind at root and ws2, `git_target`, `core.bare` from the Git config file, `.jj/.gitignore`, `.git/worktrees` entry names) plus the pinned CLI's `jj git colocation status` stdout run in each root (the CLI reads Zanshin's result). External-Git status/enable only if `Step`s can build it; otherwise Rust witnesses only, recorded in Verification.
- `docs/ffi-abi.md`, `docs/rust-error-codes.md` -- rows, a `## zanshin_git_colocation_status, _enable, _disable (Story 9.45)` section, emitter sentences.

**Acceptance Criteria:**
- Given each oracle scenario, when Zanshin and the pinned CLI run it on twin repos, then every aspect incl. the `extra` read-back matches (no ledger entry unless a divergence is named here).
- Given a `RepoHandle` from `packages/zanshin_core`, when `gitColocationEnable` then `gitColocationStatus` then `gitColocationDisable` run against the real cdylib on one handle, then status reports colocated in between, each result decodes, and a refusal surfaces as `ZanshinFfiException` with the registry code.
- Given `cargo test -p zanshin-jj --lib`, when `cli_command`'s audit runs, then the three names are canonical subcommand paths of the pinned jj-cli.

## Spec Change Log

## Review Triage Log

### 2026-10-25 — Review pass
- verdicts: 29 findings — high 0, medium 1, low 23, false 5, maybe-false 0
- findings:
  - (blind-hunter) `low` `patch` a failure of `write_git_target`/`set_git_repo_bare` after the rename returns before `reload`, leaving the handle on the moved Git dir (spec: the handle holds the reloaded workspace whenever the reload succeeds) — the error path now attempts the reload too; witness with a read-only Git config and a second call on the same handle.
  - (blind-hunter) `low` `reject` the status scenarios do not compare Zanshin's `GitColocationStatus` with the CLI's stdout — the oracle compares repo state and outcomes; reads and texts are hand-audited by house rule (Epic 9 oracle decision); the Rust witnesses assert the CLI test snapshots' lines.
  - (blind-hunter) `low` `patch` the `!is_child_workspace` term of `external_git_repo` is untested — child status now asserts `external_git_repo == false`, the enable hint and the child's name.
  - (blind-hunter) `low` `patch` `enable`'s `NoWorkingCopy` refusal is untested — witness added (forgotten child workspace; see Auto Run Result for what the call returns).
  - (blind-hunter) `low` `patch` the child-disable unlink-failure branch is untested — witness added (warning `GitWorktreeUnlinkFailed`, `git_worktree_removed == false`, `converted == true`).
  - (blind-hunter) `low` `patch` the `.jj/.gitignore` write failure maps to `jj.jj_lib_error` though the CLI raises a user error like `set_git_repo_bare`'s — mapped to `MutateError::invalid`, docs adjusted.
  - (blind-hunter) `low` `patch` `jj.git_worktree_failed`'s meaning text in `docs/rust-error-codes.md` names only `workspace add` — widened to `git colocation enable`.
  - (blind-hunter) `low` `patch` `git_repo_path`'s doc does not say that a child workspace reports the main repository's Git dir — doc clause + child assertion added.
  - (blind-hunter) `false` `reject` `hints` ships English text against "typed facts" — the house rule sends a hint the UI shows verbatim as payload `hints: [string]`; the typed decision fact is `external_git_repo` (plus `colocated`).
  - (blind-hunter) `low` `patch` the colocated Git HEAD is never checked across the FFI after enable — the FFI round trip now asserts `adds == [@-]`.
  - (blind-hunter) `low` `patch` the Dart `RepoHandle.gitColocation*` docs omit `jj.stale_working_copy` — added.
  - (blind-hunter) `false` `reject` `coverage-baseline.txt` has no entry for `colocation.rs` — the baseline is written by the gate's coverage run, which this run's gate rule leaves to the story loop's end.
  - (blind-hunter) `false` `reject` `reload` skips the config-fault routing — `Workspace::load` takes the already-resolved `UserSettings` and reads no config file, so no config fault can reach it (the same as `Repo::reload_workspace`).
  - (edge-case-hunter) `low` `patch` enable: failure after the rename leaves a stale handle — same root and fix as the first blind-hunter row.
  - (edge-case-hunter) `low` `patch` disable: the same after the `.git` rename — same root and fix.
  - (edge-case-hunter) `medium` `defer` other open handles on the same repo keep a `GitBackend` pointing at the old Git dir after a default-workspace move — pre-existing: the same staleness follows the CLI's own `jj git colocation enable|disable` run beside an open handle; closing it needs a reload rule on `git_target` for every handle (deferred, mirrored into deferred-work.md).
  - (edge-case-hunter) `low` `patch` `.jj/.gitignore` failure mapped to `jj.jj_lib_error` — same root and fix as the blind-hunter row.
  - (edge-case-hunter) `low` `patch` the spec's reuse of `reload_workspace` was replaced by a private `reload` without the failure-path reload — same root and fix as the first row.
  - (edge-case-hunter) `low` `reject` the worktree read-back compares a count, not names — jj-lib names a worktree added to a populated directory after a random temp dir (`git.rs` `add_worktree_to_populated_dir`, `TempDir::new_in`), so names differ between twins; the count is the deterministic part.
  - (verification-gap) `low` `patch` child status: `external_git_repo`/`hints` never checked — same as the blind-hunter row; assertions added.
  - (verification-gap) `low` `patch` child-disable unlink failure untested — same as the blind-hunter row; witness added.
  - (intent-alignment) `low` `reject` typed status fields are not compared with the CLI by the oracle — same as the blind-hunter oracle row (reads hand-audited).
  - (intent-alignment) `low` `reject` refusal texts are asserted only in the Rust tests — the oracle compares outcomes; codes and texts are hand-audited by house rule, and the Rust/unit tests assert the CLI's texts verbatim.
  - (intent-alignment) `low` `patch` "This command requires a working copy" is not exercised — same as the blind-hunter row; witness added.
  - (intent-alignment) `low` `reject` external-Git rows have Rust witnesses only — the oracle's `init` runs before any step, so it cannot build a `--git-repo` workspace without new driver machinery; recorded in Verification.
  - (intent-alignment) `low` `reject` no single artifact runs Zanshin enable → Zanshin disable → CLI read, and the reverse mixed direction is absent — the harness compares one Zanshin call with one CLI argv; per-step CLI read-backs (`jj git colocation status` on Zanshin's result), `disable_after_cli_enable` and the Rust round trip cover the clause.
  - (intent-alignment) `low` `patch` child status never asserts the workspace name — assertions added with the child status row.
  - (intent-alignment) `false` `reject` the ledger surfaces (I1 marker, Auto Run Result) are absent — written at finalization (this run's ledger commit).
  - (intent-alignment) `false` `reject` the verification notes record no outcomes — written at finalization.

## Design Notes

**`core.bare`.** Port `set_git_repo_bare` literally: `gix::config::File::from_path_no_includes(<git dir>/config, Source::Local)`, `set_raw_value("core.bare", "true"|"false")`, `jj_lib::git::save_git_config`; failures → `InvalidInput` with the CLI's messages ("Failed to open Git config file.", "Failed to set core.bare to <v> in Git config.", "Failed to write to Git config file at <path>.") + `: <err>`, the `creation.rs:223` convention for `user_error_with_message`.

**Why the handle's workspace is replaced in the module fn.** `GitBackend` caches the Git repo path from `git_target` at load, so after the move the old `Workspace` points at a vanished directory; the CLI reloads its helper for the same reason (`reload_workspace_helper`). `*workspace = Workspace::load(workspace.settings(), root, …)` right after the move keeps `finish_verb` and every later call on the new store.

## Verification

**Commands (gate rule of this run — no `cargo make test`/`test-full`/`coverage`):**
- `cargo test -p zanshin-jj --lib` -- expected: pass (incl. `cli_command` audit, `every_verb_resolves_for_its_cli_command`)
- `cargo test -p zanshin-jj --test it -- git_colocation:: api_stability::` -- expected: pass
- `cargo make codegen` -- expected: generated files committed, rerun shows no drift
- `cargo test -p zanshin-ffi --lib` and `--test it -- git_ffi:: ffi_abi_doc_sync::` -- expected: pass
- `cargo test -p zanshin-parity --test oracle` -- expected: pass incl. the new scenarios
- `cargo clippy -p zanshin-jj -p zanshin-ffi -p zanshin-parity --all-targets -- -D warnings`; `cargo fmt --all --check` -- expected: clean
- `packages/zanshin_core`: `cargo make --allow-private test-core`, `dart analyze --fatal-infos --fatal-warnings`, `dart format --output=none --set-exit-if-changed .` -- expected: pass/clean

**Results (2026-10-25, orchestrator run on the patched tree, before commit 53b5f87; the full gate is the story loop's, not run here):**
- `cargo test -p zanshin-jj --lib` — 400 passed (incl. the `cli_command` audit against the pinned jj-cli and `every_verb_resolves_for_its_cli_command`)
- `cargo test -p zanshin-jj --test it -- git_colocation:: api_stability:: workspace_ops::` — 73 passed
- `cargo test -p zanshin-ffi --lib` — 229 passed; `--test it -- git_ffi:: ffi_abi_doc_sync::` — 39 passed
- `cargo test -p zanshin-parity --test oracle` — 491 passed (12 `git_colocation_*` scenarios, no ledger entry)
- `cargo clippy -p zanshin-jj -p zanshin-ffi -p zanshin-parity --all-targets -- -D warnings` — clean; `cargo fmt --all --check` — clean
- `cargo make codegen` re-run — exit 0, no drift beyond the committed generated files
- `packages/zanshin_core`: `cargo make --allow-private test-core` — 1113 passed; `dart analyze --fatal-infos --fatal-warnings` — no issues; `dart format --output=none --set-exit-if-changed .` — 0 changed
- Matrix audit: all 15 rows have a passing witness in `crates/zanshin-jj/tests/it/git_colocation.rs` (plus the oracle scenarios for every row the driver can build). External-Git status/enable: Rust witnesses only — the oracle's `init` argv runs before any setup step, so it cannot build a `--git-repo` workspace without new driver machinery.
- Coverage not measured (gate rule); every new line of `colocation.rs` runs in a witness except I/O error arms of `write_git_target` and the `reload`/`Workspace::load` failure arms.

## Auto Run Result

Status: done

**Summary.** `jj git colocation status|enable|disable` (jj 0.46) are ported end to end. `Repo::git_colocation_status()` → `GitColocationStatus { colocated, workspace_name, git_head (OpRefTarget), git_repo_path, external_git_repo, hints }` (the CLI's two status lines and its one hint, verbatim). `Repo::git_colocation_enable()` / `git_colocation_disable()` → `GitColocationResult { mutation, converted, git_worktree_removed }`, ported step for step from `colocation.rs` @ v0.46.0: get_git_backend (`jj.not_a_git_repo`), the "already (not) colocated" no-op (`converted: false`, no operation), `NoWorkingCopy`; default workspace: the Git repo renamed between `.jj/repo/store/git` and `<root>/.git` with the CLI's error mapping, `store/git_target` and `core.bare` rewritten, `.jj/.gitignore` written/removed; child workspace: `git::create_worktree` / the shared `unlink_worktrees` (failure = `jj.git_worktree_unlink_failed` warning); then the handle's workspace is reloaded from disk (also when a step after the move fails), the repo loaded at the pre-move operation, and `set git head to working copy parent` (Git HEAD reset to `@-`, colocated finish exporting refs) / `remove git head reference` finished through `finish_verb` (no changes = no operation). Chain: `GitColocationStatus`/`GitColocationResult` tables, handle-only `zanshin_git_colocation_{status,enable,disable}`, three worker commands, `RepoHandle.gitColocationStatus/Enable/Disable`.

**Files changed (code commit 53b5f87):**
- `crates/zanshin-jj/src/colocation.rs` (new) -- the three verbs, `set_git_repo_bare`, `reload`, `reload_on_error`, result types; unit tests for the rename-error mapping and `core.bare`.
- `crates/zanshin-jj/src/repo.rs`, `cli_command.rs`, `lib.rs`, `op_diff.rs`, `workspace_ops.rs` -- facades, `GIT_COLOCATION_*`, `records!` lines, exports, `pub(crate)` reuse of `ref_target` / `unlink_worktrees`.
- `crates/zanshin-jj/tests/it/git_colocation.rs` (new), `main.rs`, `api_stability.rs`, `workspace_ops.rs` (`ReadOnlyDir` `pub(crate)`) -- 18 witnesses: every matrix row, the round trip with fresh `Repo::open`s, a failure after the move, the unlink-failure warning, `NoWorkingCopy` on a forgotten child.
- `schemas/envelope.fbs` + generated `envelope_generated.rs`, `zanshin_ffi.h`, `envelope_zanshin.ffi_generated.dart`, `bindings.dart` -- two tables appended to `Payload`.
- `crates/zanshin-ffi/src/git.rs`, `op_log.rs`, `tests/it/git_ffi.rs`, `tests/it/ffi_abi_doc_sync.rs` -- three extern fns; round trip (Git HEAD = `@-` after enable), refusals, export count.
- `packages/zanshin_core/lib/src/ffi/{git,op_log}.dart`, `worker/{commands,isolate,handle}.dart`, `lib/zanshin_core.dart`, `test/ffi/git_test.dart`, `test/worker/git_test.dart` -- adapters, models, commands, `RepoHandle` methods, real-cdylib tests.
- `crates/zanshin-parity/tests/oracle/scenarios.rs`, `main.rs` -- 12 scenarios with a layout + CLI-status read-back.
- `docs/ffi-abi.md`, `docs/rust-error-codes.md` -- rows, section, emitter sentences.

**Items:**
- I1 (Story 9.45's part: `jj git colocation status|enable|disable` per workspace recorded as a story) -- fixed (53b5f87); deferred-work.md marks only that part done; the entry's other parts (9.43, 9.20's addendum, 9.40's update) belong to those stories.

**Review:** 29 findings (high 0, medium 1, low 23, false 5). Patched (all low, 9 entries): reload of the handle's workspace when a step after the move fails; `.jj/.gitignore` failure as `jj.invalid_input` (the CLI's user error); `jj.git_worktree_failed` meaning widened; `git_repo_path` documented for child workspaces; child status asserts (`external_git_repo`, hint, name); unlink-failure, `NoWorkingCopy` and failure-after-move witnesses; Git HEAD = `@-` asserted across the FFI; `jj.stale_working_copy` in the Dart docs. Deferred (medium, mirrored into deferred-work.md "Surfaced in Story 9.45"): a second open handle on the same repo goes stale after a default-workspace move — pre-existing class (the CLI's own `jj git colocation` beside an open handle). Rejected: oracle comparison of the status payload / refusal texts (reads and texts are hand-audited by house rule), worktree names (random in jj-lib), external-Git oracle rows (driver cannot build them), the Zanshin→CLI mixed round trip (harness compares one call per side), `hints` as text (house rule for verbatim hints), coverage baseline / config-fault routing / ledger rows (false).

**Follow-up review recommended:** false — no high and no medium entry was patched (patched: 9 entries, all low).

**Residual risks:** the full gate (incl. the coverage ratchet for the new `colocation.rs` and the extern-fn guard for the three new symbols) runs at the end of the story loop; the stale-sibling-handle case is deferred.
