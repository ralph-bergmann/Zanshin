---
title: 'Story 9.24: Remote-change poll — `git ls-remote` diff against the view'
type: 'feature'
created: '2026-10-21'
status: 'done'
baseline_revision: '479adf60fbfb10877e5b9f5a13237bb8baab10b2'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
warnings: [oversized]
deferred:
  - summary: >-
      The poll diffs every advertised branch and tag, ignoring the bookmark/tag filters the CLI's `jj git fetch` applies per remote (`remotes.<name>.fetch-bookmarks` / `fetch-tags`, else the Git fetch refspecs), so a ref the fetch would never bring stays "new upstream" forever.
    evidence: |-
      cli/src/commands/git/fetch.rs:211-231 @ v0.46.0 (`parse_remote_fetch_bookmarks`, `load_default_fetch_bookmarks`, `parse_remote_fetch_tags`); Zanshin's own `Repo::git_fetch` still fetches `glob("*")` for both (crates/zanshin-jj/src/remotes.rs:289-299), so the poll matches today's Zanshin fetch. Story 9.30 brings the CLI's filters.
    location: >-
      crates/zanshin-jj/src/remote_changes.rs (advertisement filter); Story 9.30
    severity: medium
  - summary: >-
      A tag whose target is not a commit (a tag of a tree or blob) is reported as "new upstream" on every poll, because the ref advertisement carries no object type and jj never imports such a tag.
    evidence: |-
      jj-lib 0.46.0 git.rs:442-492 imports only refs that peel to a commit; `git ls-remote` gives the peeled id (`^{}`) but not its type, and no objects are downloaded.
    location: >-
      crates/zanshin-jj/src/remote_changes.rs (tag diff)
    severity: low
---

<intent-contract>

## Intent

**Problem:** The Fetch button's badge needs to know whether a remote has something new without fetching: `Repo::git_fetch` downloads objects, writes an operation and moves tracked local bookmarks. jj-lib has no public ls-remote (`GitSubprocessContext` and `spawn_remote_show` are `pub(crate)`, jj-lib 0.46.0 `git_subprocess.rs:81-253`), and Zanshin has no read of the remote's refs (FR-JJ-13c, epics.md Story 9.24).

**Approach:** A one-shot, read-only `Repo::remote_changes(remote_name, cancel)`: run `git ls-remote --heads --tags -- <remote>` the way jj-lib spawns git (same executable from `git.executable-path`, same flags and environment, the user's git auth), parse the ref advertisement, and diff it against the head view's `<name>@<remote>` bookmarks and tags. The result is a list of moved / new / deleted refs; an empty list means nothing new. No transaction, no snapshot, no operation. It is a network call, so it takes Story 9.52's cancel token and, in Dart, runs as a `NetworkOperation` on the worker's helper isolate like fetch. The surface is the usual chain: `.fbs`, then `zanshin-jj`, then `extern "C"`, then the `WorkerCommand`, then `RepoHandle.remoteChanges`.

## Boundaries & Constraints

**Always:**
- **Steps, in order:**
  1. `refresh_settings`. Its secure-config fix-up warnings become the call's warnings.
  2. Head load via `snapshot::load_head`. This is the CLI's `resolve_operation`: divergent op heads get one `reconcile divergent operations` op named for the workspace, as every jj command does. Otherwise nothing is written.
  3. `jj_lib::git::get_git_backend`. A native backend → `MutateError::NotAGitRepo`.
  4. `git::get_all_remote_names` must contain `remote_name` exactly. Otherwise → `MutateError::RemoteNotFound { name }`. git is never spawned in that case.
  5. `environment::git_subprocess_options(settings, cancel)`. A config fault → `mutate::cfg`.
  6. `cancel::watch_store`, then `cancel::checkpoint`.
  7. Spawn git, then `cancel::checkpoint` again.
  8. Parse the output, then diff.
- **No pre-verb snapshot** (`with_verb` is not used). No transaction, no `Precondition` report: `pending_precondition` is set to `None`. A dirty working copy stays unsnapshotted. Views, bookmarks, Git refs and files are untouched.
- **Spawn = jj-lib's `create_command` (`git_subprocess.rs:102-140`):**
  - `Command::new(options.executable_path)`, args `-c core.fsmonitor=false -c submodule.recurse=false --git-dir <git_backend.git_repo_path()>`.
  - Environment: `env_remove("LC_ALL")`, `env_remove("LANGUAGE")`, `env("LC_MESSAGES","C")`, plus `envs(options.environment)`, which carries the adopted login-shell environment and the cancel token.
  - stdin null, stdout and stderr piped. Then `ls-remote --heads --tags -- <remote_name>`, read with `wait_with_output`.
- **Git failures → `MutateError::NetworkError { reason }`, with jj-lib's own texts:**
  - spawn error: `Could not execute the git process, found in the OS path '<path>'` (relative path) or `Could not execute git process at specified path '<path>'` (absolute path);
  - wait error: `Failed to wait for the git process`;
  - non-zero exit: `External git program failed:\n<stderr, lossy>`.
  - Any git failure while the token is cancelled, and either checkpoint, → `MutateError::Cancelled`.
- **Parsing** (pure function, inline unit tests):
  - Each line is `<hex>\t<refname>`.
  - `refs/heads/<n>` → bookmark `<n>`, except `HEAD` (jj-lib `parse_git_ref`, `git.rs:347-354`).
  - `refs/tags/<n>` → tag `<n>`. `refs/tags/<n>^{}` → the peeled id, which wins over the direct id whatever the line order.
  - Other refs are ignored. A ref name that is not UTF-8 is skipped.
  - A line without a tab, or with a non-hex or empty id, → `MutateError::Backend("unexpected git ls-remote output: <line>")`.
- **Diff** (pure function, inline unit tests), against `view.remote_bookmarks(remote)` and `view.remote_tags(remote)`, present targets only:
  - advertised, view target absent → `New` (`old_commit_ids` empty, `new_commit_id` set);
  - view target is exactly the advertised id (`as_normal()`) → no entry;
  - any other view target (another id, or conflicted) → `Moved` (`old_commit_ids` = the target's `added_ids()` in order, full lowercase hex);
  - present in the view, not advertised → `Deleted` (`new_commit_id = None`).
  - Order: bookmarks before tags, each by name (byte order).
- **Public types** (`src/remote_changes.rs`, re-exported from `lib.rs`, rustdoc on every item):
  - `RemoteRefChange { kind: RemoteRefKind, name: String, change: RemoteRefChangeKind, old_commit_ids: Vec<CommitId>, new_commit_id: Option<CommitId> }`
  - `enum RemoteRefKind { Bookmark, Tag }`
  - `enum RemoteRefChangeKind { Moved, New, Deleted }`
  - Signature: `pub fn remote_changes(&mut self, remote_name: &str, cancel: Option<&crate::cancel::CancelGuard>) -> Result<Vec<RemoteRefChange>, MutateError>`, with `# Errors`.
- **Wire:**
  - `.fbs`: enums `RemoteRefKind : ubyte { Bookmark, Tag }` and `RemoteRefChangeKind : ubyte { Moved, New, Deleted }`. Tables `RemoteRefChange { kind; name: string; change; old_commit_ids: [string]; new_commit_id: string (absent = Deleted) }` and `RemoteChanges { changes: [RemoteRefChange] }`. `Payload` += `RemoteChanges`, appended at the end.
  - Extern fn: `zanshin_git_remote_changes(handle: u64, remote_name: *const c_char, cancel_token: u64) -> *mut ZanshinBuf`, with fetch's call order: `cancel::attach` first. The envelope comes from `precondition_envelope` (warnings, no precondition) with `map_mutate_err`.
  - Error codes: `jj.remote_not_found`, `jj.not_a_git_repo`, `jj.network_error`, `jj.cancelled`, `jj.config_error`, `jj.jj_lib_error`, plus the handle/`ffi.*` codes. No new code.
- **Dart:**
  - `NetworkOperation<WarnedList<RemoteRefChange>> RepoHandle.remoteChanges(String remoteName)`, on the helper isolate through `_NetworkScheduler` (later calls on that handle queue behind; `cancel()` → `jj.cancelled`).
  - Progress operation name `remote_changes`. git sends no progress, so the stream stays empty.
- Every new and changed line gets a test: real-cdylib `zanshin_core` witness for the new extern fn; new files ≥ 80 % (measured by the story loop's final gate).

**Never:**
- No `git fetch --dry-run`, no object download, no commit count (a non-goal in epics.md). No tracked-local-bookmark logic: the result is about `<name>@<remote>` only.
- No poll timer, interval setting or indicator: UI scope. No multi-remote or pattern argument: one configured remote name, exact. No MCP tool.
- No pre-verb snapshot, no op of its own. No gix in-process transport.
- No full gate in this run: `cargo make test`, `test-full` and `coverage` are not run (the story-loop gate rule; targeted checks only).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| nothing new | fetched clone, upstream unchanged | `[]`; head op id unchanged; no new op | N/A |
| moved | upstream `main` advanced after the fetch | one `Bookmark main Moved`, old `[A]`, new `B`; view, `main` and `main@origin` unchanged afterwards | N/A |
| new branch / tags | upstream gains `feature`, lightweight tag `t1` and annotated tag `v1` | `Bookmark feature New`, `Tag t1 New`, `Tag v1 New` (`v1`'s new id = the peeled commit, not the tag object) | N/A |
| deleted | upstream branch removed | `Bookmark x Deleted`, old `[X]`, new `None` | N/A |
| never fetched | remote added, no fetch yet | every advertised ref is `New` | N/A |
| conflicted remote target | view `main@origin` conflicted `{A,B}` (unit test) | `Moved`, old `[A,B]` | N/A |
| dirty working copy | an edited file in the workspace | result as above; no `snapshot working copy` op; `@` unchanged | N/A |
| unknown remote | `"nope"` | git never runs | `jj.remote_not_found` (name in context) |
| native backend | `init_simple` repo | nothing runs | `jj.not_a_git_repo` |
| git fails | remote URL points at a missing path | — | `jj.network_error`, reason starts `External git program failed:` |
| cancelled | token cancelled before the call / while a slow `git.executable-path` wrapper runs | the wrapper's git is killed | `jj.cancelled` |
| malformed output | a line without a tab (unit test) | — | `Backend` / `jj.jj_lib_error` |
| null remote (FFI) | `remote_name = NULL` | — | `ffi.null_pointer` |

</intent-contract>

## Code Map

`../jj` anchors are `git -C ../jj show v0.46.0:<path>`. jj-lib = `~/.cargo/registry/src/index.crates.io-1949cf8c6b5b557f/jj-lib-0.46.0/src/`.

**Reference (read-only)**
- jj-lib `git_subprocess.rs`: `:54-77` `GitSubprocessError` texts; `:102-140` `create_command` (mirror it); `:143-160` `spawn_cmd` (spawn-error split by `is_absolute()`); `:355-360` `external_git_error`; `:782-784` `wait_with_output`.
- jj-lib `git.rs`: `:92` `REMOTE_NAME_FOR_LOCAL_GIT_REPO`; `:347-375` `parse_git_ref` (the `HEAD` skip); `:442-492` tags peel to commits only; `get_git_backend`, `get_all_remote_names`.
- jj-lib `view.rs`: `:234` `remote_bookmarks(remote)`, `:448` `remote_tags(remote)` → `(&RefName, &RemoteRef)`. `RemoteRef.target: RefTarget` (`is_present`, `as_normal`, `added_ids`).
- CLI `cli/src/commands/git/fetch.rs:131-265`: the fetch whose effect the poll previews. Its per-remote filters are deferred (frontmatter).

**zanshin-jj**
- NEW `src/remote_changes.rs` — the types, `remote_changes(workspace, settings, remote_name, cancel)`, the private `parse_advertisement` and `diff_against_view` with inline unit tests. Model the module doc on `src/remotes.rs:1-9`.
- `src/remotes.rs:261-352` `git_fetch` — template for the remote/cancel/error mapping (`:276` options, `:285` `watch_store`, `:312`/`:325` checkpoints, `:319` cancelled-failure arm). `ProgressCallback` is not needed.
- `src/environment.rs:113-123` `git_subprocess_options` (executable path, adopted env minus locale, cancel pair).
- `src/cancel.rs`: `:185` `is_cancelled`, `:190` `checkpoint`, `:196` `watch_store`; `impl From<Cancelled> for MutateError` at `:172`.
- `src/snapshot.rs:289` `load_head(&Workspace) -> Result<Arc<ReadonlyRepo>, PreconditionError>`.
- `src/mutate.rs`: `MutateError` (`RemoteNotFound{name}`, `NotAGitRepo`, `NetworkError{reason}`, `Cancelled`, `Precondition`, `Backend`); `be` `:427`, `cfg` `:434`.
- `src/repo.rs`: `refresh_settings` `:270`; `start_call` `:360-374` (how fix-up warnings land in `pending_warnings`); `git_fetch` `:1294` (doc/signature model); `list_remotes` `:570`. Add `remote_changes` after `git_fetch`. Doc: no snapshot, no op of its own, divergent-head reconcile, the `# Errors` list.
- `src/change.rs:18` `CommitId(pub String)`; `src/lib.rs:67-106` re-exports (add `pub use remote_changes::{RemoteRefChange, RemoteRefChangeKind, RemoteRefKind};` and `pub(crate) mod remote_changes;`).

**zanshin-jj tests**
- NEW `tests/it/remote_changes.rs` (+ `mod remote_changes;` in `tests/it/main.rs`). Build the bare remote with the `git` CLI, as `tests/it/network_cancel.rs:27-38,87-195` does (`git()`, the `World` clone, `advance_main`). Every test calls `test_helpers::pin_test_env()` first.
- `tests/it/network_cancel.rs` — two rows on its `World` / `slow_git` / `token` / `cancel_when`: cancelled while the wrapper's `git ls-remote` runs (killed within `KILLED_WITHIN`, `MutateError::Cancelled`), and cancelled before the call (git never runs).
- `tests/it/api_stability.rs` — `remote_changes_surface_resolves` (fn-pointer cast of `Repo::remote_changes`, field and variant reads). Pattern: `git_ops_surface_resolves` `:720`, type aliases `:60-61`.

**FFI / wire**
- `schemas/envelope.fbs`: remote tables `:934-950` (declare the new enums and tables near them); `union Payload` `:1855-1899` (append `RemoteChanges` last). Run `cargo make codegen` and commit its outputs.
- `crates/zanshin-ffi/src/remotes.rs`: `zanshin_remotes` `:86` and `remotes_to_envelope` (`finish_envelope` `:61`) as the builder template. Add `remote_changes_to_envelope` and `zanshin_git_remote_changes`; the extern fn's call order follows `zanshin_git_fetch` (`src/repo.rs:1300-1360`).
- Envelope helpers: `src/envelope.rs:425-428` `CallReport`, `:506` `precondition_envelope`, `:856` `finish_envelope`. Error mapping: `src/repo.rs:145` `map_mutate_err`.
- NEW `crates/zanshin-ffi/tests/it/remote_changes_ffi.rs` (+ `mod` in `tests/it/main.rs`). Read the result through the typed accessors and the Verifier: moved/new/deleted round trip, no `precondition` on the envelope, unknown remote, native backend, null remote, zero handle, a token cancelled before the call. Remote helpers to copy: `tests/it/repo_write_ffi.rs:742-790` (`git_cmd`, `init_git_repo_with_commit`, `git_bare_clone`, `register_remote`), `open_handle` `:186`, cancel `:868`.
- `crates/zanshin-ffi/tests/it/ffi_abi_doc_sync.rs:37` `EXPECTED_EXPORTS` 71 → 72.

**Dart (`packages/zanshin_core`)**
- `lib/src/ffi/remotes.dart` (`zanshinRemotes` `:22`, model `:35`, decoder `:66-90`): add `zanshinGitRemoteChanges(raw, remoteName, {cancelToken = 0})` (C-string lifecycle as `ffi/mutate.dart:125`), the `RemoteRefChange` model, the `RemoteRefKind` and `RemoteRefChangeKind` enums, and `decodeRemoteChangesEnvelope[Internal]` returning `WarnedList` (`ffi/warning.dart:284`).
- `lib/src/worker/commands.dart` — `GitRemoteChangesCommand{commandId, handleId, remoteName}` implements `HandleScopedCommand` (model: `GitFetchCommand` `:500`).
- `lib/src/worker/isolate.dart`:
  - API `remoteChanges(handleId, remoteName)` via `_networkOperation(operation: 'remote_changes', …)`. Model: `gitFetch` `:1157`, `_networkOperation` `:380`.
  - Dispatch case like `GitFetchCommand`'s at `:2710` (scheduler + `_NetworkHandleAnnouncement`).
  - Top-level `_remoteChangesOnHelper`, modeled on `_fetchOnHelper` `:3473`.
- `lib/src/worker/handle.dart:487` `gitFetch` — add `remoteChanges` next to it (`_closed` guard, doc with throw list).
- `lib/zanshin_core.dart` barrel — export the new model and enums.
- NEW `test/worker/remote_changes_test.dart` — real cdylib, based on `test/worker/network_operation_test.dart:40-100` (`git()`, bare remote, `repoWithOrigin`, `gitFetch`):
  - after a fetch: empty;
  - after a git push to the bare remote: moved, new tag (peeled), deleted;
  - op log length unchanged;
  - `jj.remote_not_found`;
  - `progress` emits nothing.

**Docs**
- `docs/ffi-abi.md`:
  - counters "71" at `:40`, `:221`, `:467` → re-count;
  - symbol index row near `zanshin_git_fetch` `:528`;
  - the "does not run the precondition" list near `:142`;
  - the Cancel section `:920-929` (a fourth network call);
  - a `RemoteChanges` payload section beside GitPushRemotes `:1462`.
- `docs/rust-error-codes.md` `:50`, `:69-71` — add `zanshin_git_remote_changes` as an emitter of `jj.not_a_git_repo`, `jj.remote_not_found`, `jj.network_error`, `jj.cancelled`.
- `_bmad-output/project-context.md` `:125-128`, `:697-700` — the `Isolate.run` exception names the remote-changes helper too.

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/src/remote_changes.rs` (NEW) + `src/lib.rs` -- types, spawn, parse, diff, inline unit tests for every parse/diff rule and both spawn-error texts (a non-existent relative and absolute executable) -- the read.
- `crates/zanshin-jj/src/repo.rs` -- `Repo::remote_changes`: `pending_precondition = None`, a fresh `pending_warnings` holding the fix-up warnings, `refresh_settings`, delegate; full rustdoc -- public surface.
- `crates/zanshin-jj/tests/it/{remote_changes.rs,main.rs,network_cancel.rs,api_stability.rs}` -- one witness per matrix row not covered inline; op-log and view unchanged asserted on the happy rows -- behaviour.
- `schemas/envelope.fbs` + `cargo make codegen` -- enums, tables, `Payload` member; commit the generated outputs -- wire.
- `crates/zanshin-ffi/src/remotes.rs` -- builder + `zanshin_git_remote_changes` with rustdoc (`# Errors`, `# Safety`) -- FFI.
- `crates/zanshin-ffi/tests/it/{remote_changes_ffi.rs,main.rs,ffi_abi_doc_sync.rs}` -- FFI witnesses, export count 72 -- FFI.
- `packages/zanshin_core/lib/src/{ffi/remotes.dart,worker/commands.dart,worker/isolate.dart,worker/handle.dart}`, `lib/zanshin_core.dart`, `test/worker/remote_changes_test.dart` -- bridge + real-cdylib witness -- Dart.
- `docs/ffi-abi.md`, `docs/rust-error-codes.md`, `_bmad-output/project-context.md` -- docs -- registry/ABI.
- `_bmad-output/implementation-artifacts/sprint-status.yaml`, `deferred-work.md` -- 9-24 row → done with a summary; mirror the frontmatter deferrals under `## Surfaced in Story 9.24 (bmad-build-auto, 2026-10-21)` -- ledger.

**Acceptance Criteria:**
- Given a repo cloned from a local bare remote and fetched, when upstream `main` advances and `RepoHandle.remoteChanges('origin')` runs from Dart, then `result` lists `main` as a `moved` bookmark with the old and new commit ids. The op log, `main@origin` and the working copy are unchanged afterwards.
- Given a call cancelled while its `git ls-remote` runs, when the cancel lands, then git is killed and the call refuses with `jj.cancelled` and writes nothing.
- Given the new extern fn, then `ffi_abi_doc_sync` passes with 72 exports, and the symbol is listed in `docs/ffi-abi.md`.
- Given this run's gate rule, then every targeted check under Verification passes and is recorded in the spec.

## Spec Change Log

- 2026-10-21 (implementation): the Dart success rows cannot pass as written. Inside `dart test` the Dart VM reaps its children (its resident frontend-server child keeps the VM's `wait()` loop running), so the poll's `wait_with_output` — jj-lib's own wait, as this spec requires — fails with `Failed to wait for the git process` on every local run, the limit already recorded for fetch and clone. `test/worker/remote_changes_test.dart` builds the view without a jj fetch (a colocated init over a `git clone`), accepts exactly that one outcome on its success rows and checks the result whenever the wait wins; the diff is witnessed in Rust (`tests/it/remote_changes.rs`, `remote_changes_ffi.rs`) and the Dart decoder by `test/ffi/remotes_test.dart`. AC 1 is therefore met in Rust, not from Dart; mirrored in deferred-work.md "Surfaced in Story 9.24". The Dart enum spells `New` as `created` (`new` is a Dart keyword), as `GitRefUpdateKind` does.

## Review Triage Log

## Design Notes

**Why no snapshot, and why the head view.** The verb's whole point is to change nothing (epics: "No transaction, no op-log entry"). A timer-driven poll that snapshotted would write `snapshot working copy` operations while the user types. jj has no CLI counterpart to mirror. The diff base is "the last-known `<name>@<remote>` targets in the current view", which is the head. Loading the head the CLI way (`load_head`) can reconcile divergent op heads. That reconcile is the CLI's behaviour for any command; the poll itself writes nothing.

**Why a cancel token.** It is a network call on the same serialized handle. A hung SSH connection would block every later call on that repo. Story 9.52's token and helper isolate already solve this for fetch, and the git spawn here honours the token through `git_subprocess_options`.

**Peeled tags.** jj imports a remote tag at the commit it peels to, so the poll compares `refs/tags/v1^{}` and not the tag object:
```
063103bb…	refs/tags/v1        ← tag object (ignored when ^{} follows)
9341a781…	refs/tags/v1^{}     ← compared against v1@origin
```

## Verification

**Commands** (the story-loop gate rule: no `cargo make test` / `test-full` / `coverage`):
- `cargo test -p zanshin-jj --lib remote_changes` and `cargo test -p zanshin-jj --test it remote_changes:: network_cancel:: api_stability::` -- expected: pass.
- `cargo make codegen`, then `git status` -- expected: generated outputs updated and committed.
- `cargo test -p zanshin-ffi --test it remote_changes_ffi:: ffi_abi_doc_sync::` -- expected: pass.
- `cargo clippy -p zanshin-jj -p zanshin-ffi --all-targets -- -D warnings`; `cargo fmt --all --check` -- expected: clean.
- In `packages/zanshin_core`: `dart analyze`, `dart format --set-exit-if-changed .`, `dart test test/worker/remote_changes_test.dart test/worker/network_operation_test.dart` (cdylib built first) -- expected: clean / pass.

**Results (2026-10-21, targeted checks only — no `cargo make test`):**
- `cargo test -p zanshin-jj --lib remote_changes` — 9 passed. `cargo test -p zanshin-jj --test it -- remote_changes:: network_cancel:: api_stability::` — 43 passed.
- `cargo make codegen` — `zanshin_ffi.h`, `bindings.dart`, both `envelope_generated` files regenerated (the Dart accessors re-run with `flatc --dart` + `dart format` inside `packages/zanshin_core`, see deferred-work.md), committed with the story.
- `cargo test -p zanshin-ffi --test it -- remote_changes_ffi:: ffi_abi_doc_sync::` — 21 passed (72 exports); `cargo test -p zanshin-ffi --lib remotes` — 5 passed.
- `cargo clippy -p zanshin-jj -p zanshin-ffi --all-targets -- -D warnings`, `cargo fmt --all --check` — clean.
- `packages/zanshin_core`: `dart analyze --fatal-infos --fatal-warnings` and `dart format --output=none --set-exit-if-changed .` clean; `dart test test/worker/remote_changes_test.dart test/worker/network_operation_test.dart test/ffi/remotes_test.dart` (Makefile `test-core` env) — 23 passed (the success rows took the reaped-wait branch, see the Spec Change Log).
