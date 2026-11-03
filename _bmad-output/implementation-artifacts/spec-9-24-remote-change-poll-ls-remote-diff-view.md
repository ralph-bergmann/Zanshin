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
    resolved: >-
      2026-10-21 — fixed (spec-9-30-git-fetch-parity-default-remotes-filters, commit 7e51a50): the poll filters with the fetch's per-remote filters and refuses what the fetch refuses.
  - summary: >-
      A tag whose target is not a commit (a tag of a tree or blob) is reported as "new upstream" on every poll, because the ref advertisement carries no object type and jj never imports such a tag.
    evidence: |-
      jj-lib 0.46.0 git.rs:442-492 imports only refs that peel to a commit; `git ls-remote` gives the peeled id (`^{}`) but not its type, and no objects are downloaded.
    location: >-
      crates/zanshin-jj/src/remote_changes.rs (tag diff)
    severity: low
  - summary: >-
      No Dart witness of a SUCCESSFUL remote-change poll: inside `dart test` the poll's `git ls-remote` wait fails with `jj.network_error: Failed to wait for the git process`, so AC 1's moved `main` read from Dart is witnessed in Rust and FFI only.
    evidence: |-
      The Dart VM reaps its children while its resident frontend-server runs, so `Child::wait()` gets ECHILD — the same limit fetch, clone and push carry (packages/zanshin_core/test/worker/network_operation_test.dart:12-16, push_test.dart:12, creation_test.dart:80). test/worker/remote_changes_test.dart accepts that one outcome and asserts the result only when the wait wins (it lost in every local run).
    location: >-
      packages/zanshin_core/test/worker/remote_changes_test.dart
    severity: medium
  - summary: >-
      A timer-driven poll runs git with the user's full auth and no non-interactive guard (no `GIT_TERMINAL_PROMPT=0`, no ssh `BatchMode`), so each tick might raise a credential-helper or SSH-agent confirmation prompt.
    evidence: |-
      Unverified. crates/zanshin-jj/src/remote_changes.rs ls_remote spawns git as jj-lib does for fetch (stdin null, no tty under a Finder launch), which the intent asks for ("auth = the user's git … for free"). What would settle it: poll an SSH remote whose key sits behind an agent that confirms each use (1Password) from the running app, and an HTTPS remote with a GUI credential helper.
    location: >-
      crates/zanshin-jj/src/remote_changes.rs (ls_remote environment)
    severity: medium (unverified)
    resolved: >-
      2026-11-03 — fixed (spec-11-8-sync-fetch-push-poll-badge, commit 3516be5): the poll uses no special auth environment; a failed tick is silent, the next tick retries, ticks never overlap (sync_model_test).
  - summary: >-
      `cargo make codegen` re-wraps hand-written `packages/zanshin_core/lib/src/ffi/*.dart` at 80 columns, because its `dart format` step runs from the repo root and misses the package's 120-column setting.
    evidence: |-
      Makefile.toml [tasks.codegen-flatc-dart] runs `dart format packages/zanshin_core/lib/src/ffi/` from the root; this story's codegen run re-wrapped 29 hand-written files, reverted by re-running flatc + dart format from inside packages/zanshin_core.
    location: >-
      Makefile.toml [tasks.codegen-flatc-dart]
    severity: low
    resolved: >-
      2026-10-21 — fixed (spec-9-24-closing-codegen-dart-format-width, commit fe7b82a): the cause was a missing workspace package_config (the width's include chain ends in `lints`); the task now runs `dart pub get` first and formats only the flatc output from inside the package.
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

### 2026-10-21 — Review pass
- verdicts: 28 findings — high 0, medium 7, low 16, false 4, maybe-false 1
- findings:
  - `[medium]` `[defer]` (intent) AC 1's Dart success row is never asserted: `resultOrReaped` turns the reaped wait into `null` on every local run — the harness limit fetch/clone/push share (`network_operation_test.dart:12-16`, `push_test.dart:12`, `creation_test.dart:80`); pre-existing, not caused by this story; deferred (D1), witnessed in Rust + FFI instead.
  - `[false]` `[reject]` (intent) the badge wants a bookmark count but the result mixes bookmarks and tags — every entry carries `kind`, so the count is a filter on the list; epics names both `View::remote_bookmarks` and remote tags as the diff base.
  - `[low]` `[reject]` (intent) `load_head` can write a `reconcile divergent operations` op against "no op-log entry" — only with divergent op heads (a concurrent writer), the CLI's own head load, documented in the rustdoc and spec Design Notes; avoiding it needs an op-pinned API the intent does not ask for.
  - `[false]` `[reject]` (intent) the command adds `--git-dir` and `--` to the epic's literal `git ls-remote --heads --tags <remote>` — both are jj-lib's own spawn route the epic asks for (`git_subprocess.rs:102-140`) and guard a dash-led name; same command.
  - `[false]` `[reject]` (intent) one remote per call / network-operation shape instead of a plain one-shot — the epic signature is `remote_changes(remote)`; the cancel shape still answers once per call (one-shot) and only adds a cancel.
  - `[medium]` `[patch]` (verification-gap) no test has a fetched `<tag>@<remote>` in the view, so a wrong `remote_tags` input or a tag-object compare would pass — test row added: fetch lightweight `t1` + annotated `v1`, poll `[]`, then `t1` Moved / `v1` Deleted upstream.
  - `[medium]` `[patch]` (verification-gap) the Dart cancel wiring for `remoteChanges` (queued predicate, helper token) is untested — two Dart tests added mirroring fetch's queued and in-flight cancel.
  - `[low]` `[reject]` (verification-gap) codegen dropped `ShowEntry_VT_CHANGE` from `zanshin_ffi.h` / `bindings.dart` — a cbindgen per-field-name constant collision with `RemoteRefChange.change`; `git grep` finds no user, the vtable constants are generated noise no Dart or C caller reads; fixing needs cbindgen config work.
  - `[medium]` `[defer]` (verification-gap) the Dart success rows only assert when the wait wins — same root as D1.
  - `[low]` `[reject]` (blind) a git-config remote named `git` or containing `/` is not refused like jj-lib's `validate_remote_name` (`git.rs:169-178`) — such remotes need plain-git setup jj itself warns about; the fix adds a guard for a case unlikely in everyday use.
  - `[low]` `[reject]` (blind) colocated repos are not imported first, so an external `git fetch` shows as Moved until the next importing call — any snapshotting Zanshin read (graph topology, status) imports the refs and the next poll clears; importing here would write operations, which the intent forbids.
  - `[medium]` `[patch]` (blind) no end-to-end test of tags being "nothing new" after a jj fetch — same root as the verification-gap tag row; covered by the same added test. (The "colocated repo tags New forever" half is false: a jj fetch creates `t@origin`, after which the tag is no longer New — exactly the contract.)
  - `[false]` `[reject]` (blind) "done" is premature — the sprint-status row is set by the finalize step after review; AC 1's Dart half is the D1 deferral.
  - `[medium]` `[defer]` (blind) the Dart success tests prove nothing where they run — same root as D1.
  - `[low]` `[patch]` (blind) `RepoHandle.remoteChanges`' error list is wrong (interior NUL → `internal.dispatch_error`, not `ffi.invalid_argument`; `ffi.null_pointer` unreachable from Dart) — doc corrected.
  - `[medium]` `[patch]` (blind) the Dart cancel path for the poll is untested — same root as the verification-gap cancel row; same tests.
  - `[low]` `[patch]` (blind) `docs/rust-error-codes.md` meaning columns, the "seven git verbs" note and the `jj.config_error` emitter list miss the poll — rows corrected.
  - `[low]` `[patch]` (blind) docs and comments still say three network verbs (`docs/ffi-abi.md` live-delivery paragraph, `Progress.operation` comment, `network_operation.dart`, `isolate.dart` scheduler doc) — corrected.
  - `[maybe-false]` `[defer]` (blind) a timer-driven poll has no non-interactive guard (`GIT_TERMINAL_PROMPT=0`, ssh `BatchMode`), so each tick could raise credential or SSH-agent prompts — fetch shares the route the intent asks for ("auth = the user's git … for free"); whether prompts actually appear for a Finder-launched app (no tty, stdin null) needs a run against an SSH remote behind a confirming agent; deferred (D2), medium if true.
  - `[low]` `[defer]` (blind) the spec frontmatter and deferred-work.md disagree on the deferrals — the frontmatter now carries D1 and the codegen re-format item (D3), so both ledgers list the same items.
  - `[low]` `[reject]` (blind) the header lost `ShowEntry_VT_CHANGE` — same as the verification-gap row; rejected on the same note.
  - `[low]` `[reject]` (blind) FFI tests miss `ffi.utf8_error`, a git failing on its own while cancelled, and fix-up warnings on success — the UTF-8 check and the fix-up warnings are shared helpers (`cstr_to_string`, `refresh_settings`) already witnessed by every other extern fn; the cancelled-failure arm is the same branch the in-flight kill test in `network_cancel.rs` takes.
  - `[low]` `[reject]` (edge) reserved `git` / slash remote names — same as the blind row.
  - `[low]` `[reject]` (edge) a valid-hex id that is not 40 chars (SHA-256 remote) reads Moved/New on every poll — jj's Git backend is SHA-1 only and cannot fetch such a remote either; a guard for a case unlikely in everyday use.
  - `[low]` `[patch]` (edge) an interior NUL reaches the caller as `internal.dispatch_error`, not the documented `ffi.invalid_argument` — same root as the handle doc row; doc corrected to the behaviour fetch already has (`network_operation_test.dart:206-209`).
  - `[low]` `[reject]` (edge) a token registered by `zanshinNetworkToken()` leaks when the helper throws before the FFI call — the pre-existing pattern of fetch/push/clone, one tiny map entry per programming-error call.
  - `[low]` `[reject]` (edge) the non-zero-exit reason lacks fetch's `Git process failed: ` prefix — the spec's matrix fixes the text (`reason starts External git program failed:`); a UI never string-matches contexts.
  - `[low]` `[reject]` (edge) `ShowEntry_VT_CHANGE` dropped — same as the verification-gap row.

### 2026-10-21 — Review pass (follow-up)
- verdicts: 33 findings — high 0, medium 4, low 23, false 6, maybe-false 0
- findings:
  - `[medium]` `[defer]` (intent) the success-path matrix rows never reach an executed assertion at the Dart `RepoHandle.remoteChanges` surface — carried: same as the first pass's D1 row (`resultOrReaped`, VM child reaping), already in the frontmatter and deferred-work.md.
  - `[low]` `[reject]` (intent) "git fails" and "cancelled while running" are witnessed as `MutateError` variants only, and `jj.config_error` not at all for this call — the code mapping is the pre-existing shared `map_mutate_err`, witnessed by fetch's FFI rows; `git_subprocess_options`' config fault is the same helper fetch uses; a per-call duplicate witness adds no behaviour.
  - `[false]` `[reject]` (intent) local `main` and `@` are never read directly after the poll — `head_op()` asserts the op-heads directory unchanged, and a jj view is bound to its operation, so `main`, `main@origin` and `@` cannot change without a new op head.
  - `[low]` `[reject]` (intent) `ShowEntry_VT_CHANGE` dropped from the header and `bindings.dart` — carried: first pass rejected it (cbindgen per-name constant collision, no user).
  - `[false]` `[reject]` (intent) `present_adds()` instead of `added_ids()`, and a failing `get_all_remote_names` mapped to `NotAGitRepo` — `added_ids` does not exist on jj-core 0.46.0's `Merge`; `present_adds()` yields the same ids in order; the auditor itself names both behaviour-neutral, and the remote-name read only fails on an unreadable git dir.
  - `[false]` `[reject]` (intent) the fetch-filter, non-commit-tag and auth-prompt behaviours sit outside the intent's text — the auditor finds them consistent with the intent's letter, and all three are already frontmatter deferrals.
  - `[low]` `[patch]` (verification-gap) `Repo::remote_changes` wires its fix-up warnings inline (not via `start_call`) and no test reads them — added `a_remote_change_poll_reports_its_own_migration` (migrated, then `NotAGitRepo`) and `a_remote_change_poll_refused_by_its_refresh_still_reports_the_migration` to `crates/zanshin-jj/tests/it/secure_config_fixups.rs`; dropping or reordering the `extend` now fails both.
  - `[medium]` `[defer]` (verification-gap) the Dart success witness never runs its assertions — carried: D1.
  - `[low]` `[reject]` (verification-gap) `ShowEntry_VT_CHANGE` silently removed — carried: first-pass rejection.
  - `[low]` `[reject]` (edge) a git remote named `git` or containing `/` is not refused — carried: first-pass rejection (plain-git setup only, adds a guard).
  - `[low]` `[reject]` (edge) a hung `git ls-remote` without a cancel never returns and queues every later command on the handle — the intent itself specifies that later calls queue behind and that `cancel()` is the remedy; a deadline would add a parameter, and the poll timer (UI scope) owns the cancel.
  - `[low]` `[reject]` (edge) a blank or CR-terminated line fails the whole poll — git's `ls-remote` writes LF-terminated `<id>\t<ref>` lines only (the trailing LF is stripped, `remote_changes.rs:185`); the guard covers output git does not produce.
  - `[low]` `[reject]` (edge) a hex id of the wrong length is accepted — carried: the first pass's non-40-char id rejection (SHA-1 backend, git never truncates).
  - `[low]` `[reject]` (edge) the Dart decoder turns an absent `RemoteRefChange.name` into `''` — the same file's `Remote` decoder does the same (`remotes.dart:168`), and the Rust builder always writes the name; only a broken Rust builder reaches it, and a throw is an added guard.
  - `[low]` `[reject]` (edge) `ShowEntry_VT_CHANGE` deletion — carried: first-pass rejection.
  - `[low]` `[reject]` (edge) the poll's `jj.network_error` text lacks fetch's `Git process failed: ` prefix — carried: first-pass rejection (the matrix fixes the text).
  - `[medium]` `[defer]` (edge) AC 1 has no Dart witness — carried: D1.
  - `[low]` `[reject]` (edge) `load_head` can write a reconcile op — carried: first-pass rejection (the CLI's own head load, divergent heads only).
  - `[low]` `[reject]` (blind) header lost `ShowEntry_VT_CHANGE` (and `RemoteRefChange_VT_KIND`/`_VT_NAME` absent) — carried: first-pass rejection.
  - `[low]` `[patch]` (blind) `zanshin_network_token` / `zanshin_network_cancel` docs still name only fetch, push and clone — both docs now name `zanshin_git_remote_changes` (`crates/zanshin-ffi/src/repo.rs`); header and `bindings.dart` regenerated (`cargo make --allow-private codegen-cbindgen` + `codegen-ffigen`, comment lines only). The Dart `zanshinNetworkToken` doc names no call list.
  - `[low]` `[reject]` (blind) the poll blocks the whole handle per tick and has no timeout — same as the edge-case hang row: the intent's queue-behind shape, cancel is the remedy.
  - `[low]` `[reject]` (blind) a git remote named `git` is not refused — carried: first-pass rejection.
  - `[low]` `[reject]` (blind) spawn/wait errors drop the `io::Error` cause and skip jj-lib's `tracing::debug!` — fetch's reason (`GitSubprocessError::to_string()`) drops the `#[source]` too, so the poll matches it; adding the cause changes the texts the matrix fixes, and zanshin-jj logs no git spawn anywhere.
  - `[low]` `[reject]` (blind) Dart decoder `name: c.name ?? ''` — same as the edge-case row.
  - `[medium]` `[defer]` (blind) the Dart success tests pass without checking anything — carried: D1 (when the wait wins, the `if (changes != null)` branch does run the assertions).
  - `[false]` `[reject]` (blind) `coverage-baseline.txt` lacks `remote_changes.rs` — coverage is measured and the baseline auto-raised by the story loop's final gate (this loop's gate rule); nothing is skipped.
  - `[low]` `[patch]` (blind) Story 9.30's sprint-status row still says "no poll (9-24)" although the fetch-filter deferral hands the poll's filter to 9.30 — the 9-30 row now carries that obligation and points at deferred-work.md "Surfaced in Story 9.24".
  - `[low]` `[patch]` (blind) FFI tests miss `ffi.utf8_error`, `jj.network_error`, `jj.config_error`, the fix-up warnings and divergent reconcile — the utf8/network/config/reconcile part is carried (first-pass rejection, shared helpers); the fix-up-warnings part shares VG's root and is closed by the same two tests at the `Repo` layer, where the inline wiring lives.
  - `[false]` `[reject]` (blind) no test shows a fetch clears Deleted entries, so a deleted upstream tag might light the badge forever — jj-lib's fetch runs `git fetch --prune` with forced refspecs into `refs/jj/remote-tags/<remote>/*` (jj-lib 0.46.0 `git_subprocess.rs:180`, `git.rs:2975-2999`); settled by running it: `fetched_tags_are_compared_at_their_peeled_commits` and `a_branch_removed_upstream_is_deleted` now fetch again and poll `[]`, both pass.
  - `[low]` `[reject]` (blind) all Rust tests use non-colocated clones; an external `git fetch` in a colocated repo reads Moved — carried: first-pass rejection (colocated repo not imported first).
  - `[low]` `[reject]` (blind) `parse_advertisement` accepts ids of any length — carried: first-pass rejection.
  - `[low]` `[reject]` (blind) `ls-remote --heads` is a deprecated synonym of `--branches` since git 2.46 — git emits no warning for it and only a non-zero exit is an error; `--branches` would break every git before 2.46.
  - `[false]` `[reject]` (blind) the 9-24 sprint-status row's deferral count disagrees with deferred-work.md — the row names all five: three under OPEN (fetch filters, non-commit tags, codegen) plus the Dart success witness, and the review note's three (Dart success, auth prompts, codegen).

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

**Results after the review patches (2026-10-21, targeted checks only):**
- `cargo test -p zanshin-jj --lib remote_changes` — 9 passed. `cargo test -p zanshin-jj --test it -- remote_changes:: network_cancel:: api_stability::` — 44 passed (+ `fetched_tags_are_compared_at_their_peeled_commits`).
- `cargo test -p zanshin-ffi --test it -- remote_changes_ffi:: ffi_abi_doc_sync::` — 21 passed; `cargo test -p zanshin-ffi --lib remotes` — 5 passed.
- `cargo clippy -p zanshin-jj -p zanshin-ffi --all-targets -- -D warnings`, `cargo fmt --all --check` — clean.
- `packages/zanshin_core`: `dart analyze --fatal-infos --fatal-warnings`, `dart format --output=none --set-exit-if-changed .` — clean; `dart test test/worker/remote_changes_test.dart test/worker/network_operation_test.dart test/ffi/remotes_test.dart` (the `test-core` environment) — 25 passed (+ the two `remoteChanges` cancel tests).
- The `.fbs` comment edit regenerated one comment line in each `envelope_generated` file (`cargo make --allow-private codegen-flatc-rust`; `flatc --dart` + `dart format` from inside `packages/zanshin_core`); header and `bindings.dart` unchanged.
- Not run, by this run's gate rule: `cargo make test` / `test-full` / `coverage`, and the parity oracle (no jj verb changed — the poll has no CLI counterpart and writes nothing).

**Results of the follow-up review pass (2026-10-21, targeted checks only — no `cargo make test` / `test-full` / `coverage`):**
- `cargo test -p zanshin-jj --test it -- remote_changes:: secure_config_fixups::` — 22 passed (the two new fix-up rows; the two extended prune rows).
- `cargo make --allow-private codegen-cbindgen`, then `codegen-ffigen` — header and `bindings.dart` changed in the two doc comments only (schema unchanged, so flatc was not re-run).
- `cargo test -p zanshin-ffi --test it -- remote_changes_ffi:: ffi_abi_doc_sync::` — 21 passed.
- `cargo clippy -p zanshin-jj -p zanshin-ffi --all-targets -- -D warnings` — clean. `cargo fmt --all --check` — clean after `cargo fmt --all` re-wrapped the new test lines.
- `packages/zanshin_core`: `dart analyze --fatal-infos --fatal-warnings` — no issues; `dart format --output=none --set-exit-if-changed .` — 0 changed.
- Parity oracle not run: no jj verb changed.

## Auto Run Result

Status: done

**Summary.** Story 9.24 adds a read-only remote-change poll, `Repo::remote_changes(remote_name, cancel)`. It runs `git ls-remote --heads --tags -- <remote>` the way jj-lib spawns git: `git.executable-path`, jj-lib's flags, environment and error texts, the user's git auth. It then diffs the advertisement, with annotated tags compared at their peeled commits, against the head view's `<name>@<remote>` bookmarks and tags. The result is a list of moved / new / deleted refs. There is no snapshot, no transaction and no operation of its own. The poll takes a Story 9.52 cancel token. It is surfaced as:
- FFI `zanshin_git_remote_changes`, 72 exports;
- the `RemoteChanges` payload;
- Dart `RepoHandle.remoteChanges`, a `NetworkOperation` on the helper isolate.

**Files changed.**
- `crates/zanshin-jj/src/remote_changes.rs` (new): types, spawn, parse, diff, and inline tests.
- `crates/zanshin-jj/src/{repo,lib}.rs`: `Repo::remote_changes`, which writes no precondition report and keeps the fix-up warnings; re-exports.
- `crates/zanshin-jj/tests/it/{remote_changes,network_cancel,api_stability,main}.rs`: matrix rows, the fetched-tags row, the two cancel rows, and the surface test.
- `schemas/envelope.fbs` plus the generated header, `bindings.dart` and both `envelope_generated` files: the two enums, `RemoteRefChange`, `RemoteChanges`, and the `Payload` member.
- `crates/zanshin-ffi/src/remotes.rs` and `tests/it/{remote_changes_ffi,ffi_abi_doc_sync,main}.rs`: the extern fn, its builder, and the witnesses.
- `packages/zanshin_core/lib/src/{ffi/remotes.dart,worker/commands.dart,worker/isolate.dart,worker/handle.dart,worker/network_operation.dart}` and `lib/zanshin_core.dart`: the bridge, the scheduler's queued cancel, and the docs.
- `packages/zanshin_core/test/{worker/remote_changes_test.dart,worker/network_operation_test.dart,ffi/remotes_test.dart}`: real-cdylib rows, cancel rows, and decoder rows.
- `docs/ffi-abi.md`, `docs/rust-error-codes.md`, `_bmad-output/project-context.md`: ABI, the error registry, and the `Isolate.run` exception.
- `_bmad-output/implementation-artifacts/{sprint-status.yaml,deferred-work.md}`: the 9-24 row is done, and the deferrals are mirrored.

**Review findings.** 28 findings: 0 high, 7 medium, 16 low, 4 false, 1 maybe-false.
- **Patched: 5 entries.**
  - 2 medium:
    - a fetched-tags row, so the tag view input and the peeled compare are witnessed;
    - Dart queued and in-flight cancel tests for `remoteChanges`.
  - 3 low:
    - the `RepoHandle.remoteChanges` error list;
    - the `rust-error-codes.md` meaning columns and emitter lists;
    - the remaining "three network verbs" wording in the docs, the `.fbs` comment and the Dart docs.
- **Deferred: 3.** All are mirrored in deferred-work.md.
  - No Dart witness of a successful poll, because of the VM's child reaping (medium, the harness limit fetch/clone/push share).
  - Possible credential or SSH-agent prompts on a timer-driven poll (medium, unverified).
  - The codegen 80-column re-wrap (low).
  - These sit beside the two planning-time deferrals: the fetch's per-remote filters (9.30) and non-commit tag targets.
- **Rejected: 15.**
  - Bookmark-count reading: false, because the list carries `kind`.
  - Divergent-head reconcile op: low; the CLI's own head load, rare.
  - `--git-dir` / `--` in the command: false; jj-lib's route.
  - One remote / network-operation shape: false; the epic signature.
  - `ShowEntry_VT_CHANGE` dropped by cbindgen (×3): low; no user, a generator quirk.
  - Reserved `git` / slash remote names (×2): low; needs plain-git setup, the fix adds a guard.
  - Colocated repo not imported first: low; the next snapshotting read imports it, and importing would write ops.
  - "done" premature: false; sequencing.
  - FFI utf8 / cancelled-own-failure / fix-up-warning witnesses: low; shared helpers already witnessed.
  - Non-40-char ids: low; the SHA-1 backend cannot fetch them either.
  - Leaked token on a helper throw: low; the pre-existing fetch/push/clone pattern.
  - Missing `Git process failed: ` prefix: low; the matrix fixes the text.

**Follow-up review recommendation: true.** This was the first pass and 2 medium entries were patched (0 high, 2 medium, 3 low). The unverified risk is the Dart end-to-end success path of `RepoHandle.remoteChanges`: its moved/new/deleted result has never been decoded from a real poll through the worker, because the VM reaps git. That path, and the coverage of the two new Rust files, is checked only by the story loop's final gate and a run in the app.

**Verification.** See `## Verification`: every targeted check passed before and after the review patches. The full gate was not run, by this run's rule.

**Residual risks.**
- The Dart success path is witnessed only in Rust and FFI (deferred).
- Coverage of `remote_changes.rs` and the FFI additions is unmeasured until the final gate. A few error-mapping lines, such as the wait error, have no test.
- A timer-driven poll may prompt for credentials (unverified, deferred).
- `cargo make codegen` will re-wrap hand-written Dart again until `Makefile.toml` is fixed (deferred).

### Follow-up review pass (2026-10-21)

Status: done

**Summary.** A fresh four-layer review of the finished Story 9.24 diff (baseline `479adf60fbfb10877e5b9f5a13237bb8baab10b2`). It found no defect in the poll itself. It added witnesses for two gaps, corrected two stale docs and one ledger row. No production code changed.

**Files changed.**
- `crates/zanshin-jj/tests/it/secure_config_fixups.rs`: two rows that read the poll's own fix-up warnings (a migration, then `NotAGitRepo`; a migration refused by the refresh).
- `crates/zanshin-jj/tests/it/remote_changes.rs`: the deleted-branch and moved/deleted-tag rows fetch again and poll `[]`, so the fetch is shown to prune deleted refs.
- `crates/zanshin-ffi/src/repo.rs`, plus the regenerated `crates/zanshin-ffi/include/zanshin_ffi.h` and `packages/zanshin_core/lib/src/ffi/bindings.dart`: the `zanshin_network_token` / `zanshin_network_cancel` docs name the poll.
- `_bmad-output/implementation-artifacts/sprint-status.yaml`: the 9-30 row carries the poll's per-remote filter obligation.

**Review findings.** 33 findings: 0 high, 4 medium, 23 low, 6 false, 0 maybe-false. 18 rows carried from the first pass.
- **Patched: 3 entries, all low.**
  - The poll's inline fix-up warning wiring is witnessed (verification-gap row plus the blind FFI-row half).
  - The network-token docs name the poll.
  - The 9-30 sprint-status row names the poll filter.
- **Deferred: none new.** The four medium rows are the carried D1 deferral (no Dart witness of a successful poll), already in the frontmatter and deferred-work.md. Nothing was mirrored to deferred-work.md, because no item was added to `deferred:`.
- **Rejected.**
  - False: local refs unread (op heads pin the view); `present_adds` / remote-name mapping; out-of-text behaviours (already deferred); coverage baseline (the final gate measures it); fetch never clearing Deleted (refuted by running it); deferral-count mismatch (the row lists all five).
  - Low, not worth fixing: error rows witnessed at the `MutateError` layer only (shared `map_mutate_err`); hang without timeout / handle blocked per tick (×2, the intent's queue-behind shape with `cancel()` as remedy); CR/blank lines (git never emits them); absent Dart `name` coalesced to `''` (×2, same as the sibling `Remote` decoder, needs a broken builder); `io::Error` cause dropped (fetch's reason drops it too); `--heads` deprecation (no warning, `--branches` breaks older git).
  - Carried first-pass rejections: `ShowEntry_VT_CHANGE` (×4), reserved remote names (×2), id length (×2), the `Git process failed:` prefix, the divergent-head reconcile op, the colocated import, and the FFI utf8/network/config rows.

**Follow-up review recommendation: false.** This is a follow-up pass, and it patched no high entry (patched: 0 high, 0 medium, 3 low). The work has converged.

**Verification.** See `## Verification` → "Results of the follow-up review pass": every targeted check passed. The full gate was not run, by this run's rule.

**Residual risks.** Unchanged from the first pass:
- The Dart success path is witnessed only in Rust and FFI (D1).
- Possible credential prompts on a timer-driven poll (unverified).
- The codegen 80-column re-wrap.
- Coverage of the new files is unmeasured until the story loop's final gate.
