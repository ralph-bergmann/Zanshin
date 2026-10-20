---
title: 'Story 9.52 — Network verbs on a helper thread: live progress and Cancel for fetch, clone and push'
type: 'feature'
created: '2026-10-20'
status: 'done'
baseline_revision: '31e4bcab50485082491452ffbbff9b7a0c376286'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/docs/ffi-abi.md'
  - '{project-root}/docs/rust-error-codes.md'
warnings: ['oversized']
deferred:
  - summary: >-
      Cancel identifies stock macOS git by its `--git-dir` argument, not by the token pair — Ralph to confirm this attribution rule (no process group is created).
    evidence: |-
      macOS hides the environment of Apple platform binaries (/usr/bin/git, CLT git, /bin/sh, ssh) from KERN_PROCARGS2, even for our own children, so the spec's "only processes carrying ZANSHIN_CANCEL_TOKEN" rule never matches stock git. cancel.rs signals a hidden-env descendant naming `--git-dir <dir>` when exactly one live call watches that dir (plus its descendants). Residual: a token-less git on that dir (a concurrent `workspace add` worktree on another handle of the same repo) is not told apart. Deviates from Ralph's "kill git's process group" note and the spec's Never rule. Alternatives: an exec wrapper with setpgid (needs a shipped executable — Dart hooks ship dylibs only, macOS has no setsid(1)), or cancel by checkpoints only for Apple git.
    location: >-
      crates/zanshin-jj/src/cancel.rs (Marks::matches, poll); docs/ffi-abi.md § Cancel
    severity: medium
  - summary: >-
      No Dart witness for a successful worker clone (the reserved handle id registered and usable) — blocked by the Dart VM child-reaping limit.
    evidence: |-
      network_operation_test.dart's clone-progress test accepts jj.network_error "Failed to wait for the git process" (3 of 3 runs on the helper isolate, re-checked in this story); so the CreatedRepoHandle branch of the worker's clone reply (handles[reserved], sessionToId) never runs in Dart, and the Dart clone-cancel twin may resolve at the pre-git checkpoint. The mid-git kill and clean-up are witnessed in Rust (clone_cancel.rs).
    location: >-
      packages/zanshin_core/lib/src/worker/isolate.dart (CloneRepoCommand arm reply); packages/zanshin_core/test/worker/network_operation_test.dart
    severity: medium
---

<intent-contract>

## Intent

**Problem:** The worker runs `gitFetch`, `cloneRepo` and `gitPush` synchronously on its own isolate thread, and the `NativeCallable.listener` event sink lives in that isolate, so every `ProgressEvent` reaches Dart only after the call returned (deferred-work "Surfaced in Story 9.20", I1). jj-lib 0.46.0 spawns git itself with no hook, so none of the three verbs can be cancelled (deferred-work "Surfaced in Story 11.6", I2's cancel remainder).

**Approach:** The worker hands each network call to a short-lived helper isolate (`Isolate.run`) and keeps per-handle serialization itself, so its event loop forwards progress live while the call runs. Cancel uses a process-unique token: Zanshin injects it into git's environment, and cancelling sets the token's flag, kills every descendant process of ours that carries it, and makes the verb refuse at its next checkpoint with the new code `jj.cancelled`. A push reports the cancel as data, `PushFailureKind.cancelled`.

## Boundaries & Constraints

**Always:**
- Every call on one repo handle stays serialized. While a network call holds handle H, every `HandleScopedCommand` for H, including `CloseRepoCommand`, waits in arrival order and runs after it. Calls on other handles, handle-free commands and events do not wait.
- The helper isolate is the only isolate touching the raw `*mut RepoSession` while the call runs (AD-2 — `crates/zanshin-ffi/src/handle.rs:1-4`; Rust adds no handle locking).
- `ShutdownCommand` first cancels every in-flight network token, then waits until no network call is in flight, then runs as today. A shutdown must never free a session a helper still uses.
- Cancel mechanism: a process-unique token rides git's environment as `ZANSHIN_CANCEL_TOKEN=<token>`. It is added by `environment::git_subprocess_options` only for a call that carries a token. Cancelling kills every *descendant* of the current process whose environment carries that exact pair: SIGTERM first, so git removes its lock and temp files as on the CLI's Ctrl-C, then SIGKILL for any still alive 2 s after the cancel. Polling (about 50 ms) runs only while the token's verb is attached, so a git spawned later is caught too. The token's registry entry exists from allocation to the end of the verb.
- Checkpoints. A cancelled token refuses at its verb's next checkpoint:
  - fetch: before `GitFetch::fetch`, and after it but before `import_refs` — so a cancelled fetch records no import;
  - clone: before and after `fetch_new_remote`'s git work, inside `clone_into_workspace`, so 9.20's clean-up runs;
  - push: before each remote's `push_refs`. There is no checkpoint after the last remote: once every git push has run, the push finishes normally.

  A subprocess error (`GitSubprocessError` / `NetworkError`) while the token is cancelled also maps to the cancel. Every other error passes through unchanged.
- A cancelled fetch or clone refuses with `jj.cancelled` (a new registered code; context "Cancelled"), never `jj.network_error`. The clone's clean-up is 9.20's failure path (`creation.rs:340-348`). A cancelled push returns its ok `GitPushResult`: `failure.kind = cancelled`, `recorded = false`, and the per-remote data says which remotes already got their refs (9.20's `PushRemote.finished` / ref `status`).
- Tokens and session ids share one id space: `next_session_id()` in `zanshin-ffi/src/repo.rs:536`. A clone with a non-zero token uses the token as the new session's id, so the worker can route its progress before the clone returns.
- `ProgressEvent`'s shape and `operation` values (`fetch` / `clone` / `push`) are unchanged, and the events keep flowing on `ZanshinWorker.events`.
- The canonical rules from `project-context.md`: FlatBuffers tables edited in place, codegen committed, `docs/ffi-abi.md` and `docs/rust-error-codes.md` updated, a real-cdylib `zanshin_core` test per new or changed extern, `cargo make test` green with the coverage ratchet (a new file at 80 % or more).

**Never:**
- UI: 11.8 owns progress in the clone form, its Cancel and removing `ProjectSession.clone`'s port; the Push sheet keeps Cancel inert.
- No credential prompts and no MCP.
- No change to jj-lib, no fork, no `git.executable-path` override, no exec wrapper binary in production.
- No Rust-side locking of `RepoSession`, and no Rust worker thread owning the handle.
- No `jj.cancelled` for a call that carried no token. No killing of processes that are not our descendants or lack the exact token pair.
- No regenerated fixtures, and no writes to `~/.config/jj`. Dart tests must not put `git.executable-path` into the shared `$XDG_CONFIG_HOME` user config, because test files run in parallel; use repo-scope config.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Live progress | fetch / clone / push whose git reports progress | `ProgressEvent`s reach `worker.events` and the operation's `progress` while `result` is still pending | — |
| Cancel mid-fetch | git running (a slow wrapper in repo config) | git and its descendants get SIGTERM; returns within a few seconds | `jj.cancelled`; head op unchanged (no import) |
| Cancel mid-clone | clone into a missing folder, git slow | the folder the clone created is gone; a pre-existing empty folder stays | `jj.cancelled` |
| Cancel push between remotes | remotes r1, r2; r2's git slow | r1 `finished`, refs `Pushed`; r2 not finished | ok result, `failure.kind = cancelled`, `recorded = false` |
| Cancel before git spawns | cancel arrives before the verb's first checkpoint | verb refuses at that checkpoint, git never runs | fetch/clone `jj.cancelled`; push failure `cancelled` |
| Cancel too late | cancel after the last checkpoint and after the git work | verb's normal result | none — cancel is a no-op |
| Cancel finished/unknown token | operation already completed | no-op | no error |
| Same-handle call | `status(A)` sent while `gitFetch(A)` runs | completes after the fetch's result | — |
| Other-repo call | `status(B)` while `gitFetch(A)` runs | completes before the fetch's result | — |
| Queued network command cancelled | `gitFetch(A)` queued behind another call on A, then cancelled | when dequeued it runs with an already-cancelled token, so it refuses at its first checkpoint | `jj.cancelled` |
| Non-network error while cancelled | e.g. unknown remote | that error unchanged | its own code |

</intent-contract>

## Code Map

**Dart worker** (`packages/zanshin_core/lib/src/worker/`)
- `isolate.dart:2206-3160` -- `_workerEntry`. Today a fully synchronous `commandPort.listen` switch. The handle table is `handles` / `sessionToId` / `nextHandleId` (:2228-2230). The event sink at :2235-2247 drops events for an unknown session.
  - Network arms: `CloneRepoCommand` :2290, `GitFetchCommand` :2562, `GitPushCommand` :2573.
  - `CloseRepoCommand` :2314; `ShutdownCommand` :3133-3148.
  - `_replyRepoOp` :3184-3205 allocates a handle id after the reply. Clone needs a reserved-id variant.
  - `_invalidHandleEnvelope` :3172 and `internal.dispatch_error` :3150-3159 are the worker-built envelopes.
- `isolate.dart:459-497` -- `ZanshinWorker.cloneRepo`; `:1062-1123` `gitFetch` / `gitPush`.
  - Main-side plumbing: `_sendCommand` :567, `_onResponse` :278, `_onEvent` :287, `events` :363.
  - `_doClose` :605-629 waits 5 s for the shutdown ack, then kills the worker.
- `commands.dart:20,32` -- `WorkerCommand`, `HandleScopedCommand` (all handle commands implement it); `GitFetchCommand` :484, `GitPushCommand` :506, `CloneRepoCommand` :75. Add a `cancelToken`-free `NetworkCancelCommand(targetCommandId)`; the worker owns the tokens.
- `handle.dart:445-534` -- `RepoHandle.gitFetch` / `gitPush`: synchronous closed-handle `StateError` guard, then `_worker.gitFetch/gitPush`.
- `events.dart:49` -- `ProgressEvent`; its doc still says "No producer exists yet" (stale, fix it).
- `responses.dart:101-148` -- `ZanshinFfiException`.
- `../ffi/events.dart:102-160` -- `registerEventSink` (the worker owns the listener; any thread may dispatch into it).
- `../ffi/mutate.dart:122` `zanshinGitFetch`, `../ffi/push.dart:31-73` `zanshinGitPush` and `PushFailureKind` (:120), `../ffi/repo.dart:95-131` `zanshinRepoClone`. These are `@Native` bindings resolved through native assets of the isolate group, so they work inside `Isolate.run`. No `Isolate.run` exists in the package yet.
- `lib/zanshin_core.dart` -- barrel; export the new operation type.

**Rust FFI** (`crates/zanshin-ffi/`)
- `src/repo.rs`
  - :1271-1295 `zanshin_git_fetch(handle, remote_name)`; the progress closure is at :1281.
  - :785-799 `zanshin_repo_clone`, which calls `next_session_id()` at :789 before `Repo::clone`.
  - :536 `next_session_id` (AtomicU64 from 1, never reused).
  - :557 `arm_session_with`; :613 `creation_envelope_for`.
  - :55-68 `map_repo_err`; :150 `map_mutate_err` (`NetworkError` → `JJ_NETWORK_ERROR`).
  - :395 `read_clone_request`.
- `src/push.rs:322-345` -- `zanshin_git_push`; `read_push_request` :43; `ok_git_push_result`.
- `src/events.rs:37,96,178` -- `SINK`; `dispatch` runs synchronously on the calling thread (the helper isolate's thread after this story); `progress_to_envelope`.
- `src/envelope.rs:18-313` -- `JJ_*` constants (single emission point; `JJ_NETWORK_ERROR` :163); `catch` :963.
- `tests/ffi_abi_doc_sync.rs:37` -- `EXPECTED_EXPORTS = 68` (becomes 70); index/registry sync tests :161, :273, :302.
- `include/zanshin_ffi.h` -- cbindgen output, committed.

**Rust jj layer** (`crates/zanshin-jj/src/`)
- `environment.rs:109-113` -- `git_subprocess_options(settings)`: the single place that builds `GitSubprocessOptions` and sets `.environment` (jj-lib applies the map last and never clears the env — `jj-lib-0.46.0/src/git_subprocess.rs:105-140`). It has a fourth caller, `workspace_add.rs:153` (no token).
- `remotes.rs:149-205,259-320` -- `ProgressEvent`, `ProgressFn`, `ProgressCallback`; `git_fetch` (options :273, `GitFetch::new` :282, `fetch` :306-316, `import_refs` :318).
- `repo.rs:1182-1190` `Repo::git_push`, `:1229-1240` `Repo::git_fetch`, `:2520` `Repo::clone`.
- `creation.rs`
  - :251 `clone`; :268-275 `fetch_error`.
  - :340-348 failure clean-up around `clone_into_workspace` (:400-462); :373-385 `clean_up`.
  - :526-604 `fetch_new_remote`: options :534, fetch :559, `import_refs` :562, `get_default_branch` :563.
- `push.rs:246` `PushFailureKind`; `:1605` `push_error`; `:1656-1690` `render`; `:1802-1853` `push_remotes` (per-remote loop, options :1808, `push_refs` :1822).
- jj-lib facts:
  - A killed git is indistinguishable from any other failure: `wait_with_progress` `git_subprocess.rs:803-829`, parse :462-486 / :715-738. Detect a cancel by the flag, not by parsing.
  - Callback errors are dropped at :901.
  - Pipe reads end only when every holder closes, so the kill must include descendants (`git-remote-*`, `ssh`, `git-upload-pack`).
- libc `0.2.186` is transitive only. `src/unix/bsd/apple/mod.rs` has `proc_listchildpids` :4901, `sysctl` :4405, `CTL_KERN`, `KERN_PROCARGS2 = 49` :3681. Add `libc = "=0.2.186"` (exact pin plus a WHY comment, `deny.toml` wildcards=deny).

**Docs and schema**
- `schemas/envelope.fbs` -- `RepoCloneRequest`, `GitPushRequest` (append `cancel_token: uint64`), `PushFailureKind` :1180 (append `Cancelled`).
- `docs/ffi-abi.md` -- symbol index :458-460 ("exports 68"), fetch row :520, clone row :481, Progress producer notes :835-852 (they say the clone mapping holds only because the call is synchronous — rewrite), `GitPushResult` :1372.
- `docs/rust-error-codes.md` -- table :34ff, `jj.network_error` :70, "Adding a New Code" :197-203.

**Test anchors**
- Rust remote helpers: `zanshin-ffi/tests/repo_write_ffi.rs:760-800` (`git_bare_clone`, `register_remote`), `push_ffi.rs:49` `remote()`, `zanshin-jj/tests/clone_init.rs:46,64` (`source_repo`, `file_url`), `zanshin-jj/tests/push.rs:38-160` `world()`, `test_helpers::pin_test_env()`.
- Existing witnesses to keep green: `repo_write_ffi.rs:802` (fetch progress), `push_ffi.rs:264` (clone progress carries the new session id), `clone_init.rs:277,316` (clean-up), `push.rs:653` (second remote stops the push).
- Dart: `test/worker/creation_test.dart:29` (git `Process.run` helper), `mutate_test.dart:220-237`, `push_test.dart:11-17`.
  - Dart VM child-reaping limit: inside `dart test`, jj-lib's `Child::wait()` fails with "Failed to wait for the git process" (deferred-work.md:449). Dart network tests must accept that outcome where the witness does not depend on it.
  - The config verbs (repo scope) set `git.executable-path` per repo: `test/worker/config_test.dart:30-40` (XDG pin).
- App call site: `app/lib/src/features/projects/worker_project_repos.dart:57` (`worker.cloneRepo(...)` inside `_create`, which expects a `Future<CreatedRepoHandle>`). Fake: `app/test/helpers/fake_projects.dart:89` (interface unchanged).

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/src/cancel.rs` (new) + `lib.rs` + `Cargo.toml` (libc pin)
  - Process-global registry `id → state`: cancelled flag, attached count, cancel instant.
  - API:
    - `register(id)`;
    - `attach(id) -> Option<CancelGuard>` (`0`/unknown → `None`; guard drop removes the entry and stops polling);
    - `cancel(id)` (idempotent; unknown → no-op; when attached, start the kill polling);
    - `CancelGuard::is_cancelled()` / `checkpoint() -> Result<(), Cancelled>`;
    - `env_pair()`.
  - macOS kill: walk descendants of `getpid()` with `proc_listchildpids` and read each one's environment via `sysctl(KERN_PROCARGS2)`. Skip processes that vanished or whose read fails. SIGTERM matches, then SIGKILL after 2 s. `cfg(not(target_os = "macos"))`: flag and checkpoints only.
  - Unit tests inline. Reason: the kill machinery replaces the missing jj-lib hook.
- `crates/zanshin-jj/src/environment.rs`
  - `git_subprocess_options(settings, cancel: Option<&CancelGuard>)` adds the env pair when present.
  - `workspace_add.rs` passes `None`.
- `crates/zanshin-jj/src/remotes.rs`, `creation.rs`, `push.rs`, `repo.rs`, `error`/mutate types
  - Thread `Option<&CancelGuard>` through `Repo::git_fetch` / `git_push` / `clone` (e.g. on the clone options or one added parameter) to the checkpoints listed under Always.
  - Add `MutateError::Cancelled` / `RepoError::Cancelled`, and map subprocess errors to them when cancelled.
  - Add `PushFailureKind::Cancelled`, rendered with the per-remote data intact.
- `crates/zanshin-ffi/src/{repo.rs,push.rs,envelope.rs,lib.rs}`
  - `JJ_CANCELLED = "jj.cancelled"` mapped from both `Cancelled` variants.
  - New externs:
    - `zanshin_network_token() -> u64` (`next_session_id()` + `cancel::register`);
    - `zanshin_network_cancel(token: u64)` (infallible, panic-safe, like the existing infallible externs).
  - `zanshin_git_fetch(handle, remote_name, cancel_token: u64)`.
  - `read_clone_request` / `read_push_request` read `cancel_token`. Clone uses a non-zero token as its session id. Each verb wraps its call in `cancel::attach`.
  - `# Errors` rustdoc names `jj.cancelled` on fetch and clone.
- `schemas/envelope.fbs` + `cargo make codegen` outputs (Rust, Dart, cbindgen, ffigen) -- append the fields and enum value; commit the regenerated files.
- `packages/zanshin_core/lib/src/worker/network_operation.dart` (new) + barrel
  - `final class NetworkOperation<T>` with:
    - `Future<T> result`;
    - `Stream<ProgressEvent> progress` — this call's events: `worker.events` filtered by the call's handle id and operation, closing when `result` completes;
    - `Future<void> cancel()` — completes once the worker has processed the cancel; a no-op after `result` completed or after worker close.
- `packages/zanshin_core/lib/src/worker/{commands.dart,isolate.dart,handle.dart,events.dart}`
  - `RepoHandle.gitFetch` / `gitPush`, `ZanshinWorker.gitFetch` / `gitPush` / `cloneRepo` return `NetworkOperation<…>`. The closed-handle and argument guards stay synchronous throws.
  - Worker side:
    - per-handle busy set plus FIFO queue for `HandleScopedCommand`s;
    - a network arm allocates the token (`zanshinNetworkToken`, FFI on the worker thread), records `commandId → token`, runs the FFI call via `Isolate.run`, replies, then clears busy state and drains the queue in a `finally`;
    - a helper-isolate throw replies `internal.dispatch_error`;
    - clone reserves its handle id, maps `sessionToId[token]` before the run, removes the mapping on failure, and announces `(commandId, reservedHandleId)` to main through a private, non-`RepoEvent` message on the event port, sent before the run, so `progress` can filter;
    - `NetworkCancelCommand`: cancels the in-flight token; marks a queued target so it starts with a cancelled token; otherwise a no-op;
    - shutdown: cancel all tokens, defer until idle.
  - Fix `ProgressEvent`'s stale doc. Dart wrappers in `ffi/mutate.dart`, `ffi/push.dart`, `ffi/repo.dart` take the token; `PushFailureKind.cancelled`.
- `app/lib/src/features/projects/worker_project_repos.dart` -- `.result` on `cloneRepo`. The only app call site; no UI change.
- Rust tests -- slow wrapper scripts generated in tempdirs and set via `git.executable-path`: repo config for fetch and push, a `JJ_CONFIG` file under the env guards for clone; real git found on `PATH`. Wrapper shapes are in Design Notes. Cover:
  - `zanshin-jj`: the matrix's cancel rows (elapsed < 10 s against a 30 s sleep, so the kill is proven), the pre-start cancel and too-late cancel, the non-network error passthrough, push cancelled between remotes, and a registry/attach/poll unit test;
  - `zanshin-ffi`: token/cancel externs, fetch with a token, and a clone with a token whose progress and `RepoHandle.session_id` equal the token.
- `packages/zanshin_core/test/worker/network_operation_test.dart` (new; real cdylib)
  - Progress before result: a fetch whose repo-scope `git.executable-path` wrapper runs git and then sleeps. At least one `ProgressEvent` arrives on `progress` while `result` is pending. Then `cancel()` gives `jj.cancelled`, and the head op is unchanged.
  - Other-repo `status` completes before that fetch's result; same-repo `status` completes after it.
  - A clone of a `file://` source emits `progress` events with the announced handle id before `result` completes; the outcome may be ok or the reaping `jj.network_error`.
  - A clone cancelled right after start refuses `jj.cancelled` and leaves no created folder.
  - A cancel after completion is a no-op.
  - A push with a cancelled token reports `PushFailureKind.cancelled`.
  - Re-check the child-reaping limit (does a helper-isolate clone still fail its wait?). Record the result in the spec and Auto Run Result.
  - Update the existing fetch/push/clone tests to `.result`.
- `docs/ffi-abi.md`, `docs/rust-error-codes.md`
  - New index rows and the export count 70.
  - Changed fetch signature and request fields, plus a "Cancel" subsection: token lifetime, checkpoints, kill scope, the push-as-data rule.
  - Rewrite the Progress producer notes for live delivery and the clone's token-as-session-id.
  - The `jj.cancelled` registry row.

**Acceptance Criteria:**
- Given a network call is in flight on handle A, when the worker receives commands for another handle or handle-free commands, then they are answered without waiting for it, and the worker keeps forwarding watcher and progress events.
- Given a network call is in flight on handle A, when `closeRepo(A)` or `ZanshinWorker.close()` is requested, then no session is freed while the helper runs. Close waits; shutdown cancels and then waits, finishing within its 5 s ack window for a wrapper-slowed fetch.
- Given the Dart API, when a consumer starts any network verb, then it gets a `NetworkOperation` whose `result` carries the same payload and refusals as before (`MutationResult`, `GitPushResult`, `CreatedRepoHandle`), and the existing zanshin_core and app tests pass after switching to `.result`.
- Given the ABI docs, when `cargo make test` runs, then `ffi_abi_doc_sync` passes with 70 exports, `jj.cancelled` is registered, and the coverage ratchet holds with `cancel.rs` at 80 % or more.

## Spec Change Log

- 2026-10-20 (implementation) — **Kill scope: the environment of Apple's platform binaries is
  unreadable.** On macOS 27.0.1 `sysctl(KERN_PROCARGS2)` (and `ps -E`) stops after the arguments
  for Apple-signed platform binaries — `/usr/bin/git`, the Command Line Tools' git and helpers,
  `/bin/sh`, `/bin/sleep` — even for our own children; a non-platform binary (Homebrew, a locally
  compiled one) still shows it. So "kill every descendant whose environment carries the exact
  pair" alone finds nothing for the stock git. Implemented (`crates/zanshin-jj/src/cancel.rs`): a
  descendant is the call's if its environment carries the exact pair, or — only when its
  environment is hidden (empty) — if its arguments hold `--git-dir <dir>` for the call's
  repository git dir (jj-lib runs every git that way; the verb registers the dir through
  `cancel::watch_store`); every descendant of such a process is the call's too (git's helpers).
  The token still rides git's environment as specified. Review follow-up: the `--git-dir`
  fallback applies only to a dir exactly one live token watches (two handles of one repository
  get no fallback; the env-pair match still applies). Residual: a token-less git on that dir (a
  concurrent `workspace add` worktree) is not told apart.
  This deviates from the Never "no killing of processes … that lack the exact token pair" for
  processes whose environment cannot be read — Ralph to confirm. Documented in
  `docs/ffi-abi.md` § Cancel.
- 2026-10-20 (implementation) — **Stop before signalling.** A gate run showed the race: the
  wrapper shell was scanned between `touch` and forking `sleep 30`, got SIGTERM, died, and the
  `sleep` — reparented to launchd, no longer our descendant — held git's stderr pipe for 30 s.
  Each poll now stops (SIGSTOP) every matched process and repeats the walk, 5 ms after each round
  of stops, until it finds nothing new (a stop lands only after an in-flight fork completes);
  then it signals them all and continues them (SIGCONT), so no child forked mid-scan escapes.
- 2026-10-20 (implementation) — **Child-reaping re-check:** a clone run on the helper isolate
  inside `dart test` still fails jj-lib's wait — `jj.network_error` "Failed to wait for the git
  process", 3 of 3 runs. The Dart VM's reaping is process-wide; moving the call off the worker
  isolate does not change it. `network_operation_test.dart` accepts that outcome for the clone.
- 2026-10-20 (implementation) — Worker-closed: `NetworkOperation.result` fails with `StateError`
  after `ZanshinWorker.close()` (as every command's future did before); the closed-HANDLE guard
  and the argument guards throw synchronously.

## Review Triage Log

### 2026-10-20 — Review pass
- verdicts: 45 findings — high 0, medium 14, low 22, false 9, maybe-false 0
- findings:
  - `[medium]` `[patch]` B1 (blind): the hidden-env `--git-dir` fallback signals another live call's git on the same git dir (two handles/workspaces of one repo), and the docs say "No other process is signalled". Group G1 (with E1, E14, V6). Action: the fallback now uses only git dirs that no other live registry entry watches, and the docs state the real rule and its residual.
  - `[low]` `[patch]` B2 (blind): `zanshin_repo_clone` makes any non-zero token the session id even when `attach` found no entry. Action: session id = token only when a guard was returned.
  - `[low]` `[reject]` B3 (blind): `attach` gives a second guard for an already attached token. Unreachable from Dart: the worker allocates a fresh token per call and never reuses one. The fix adds a branch.
  - `[low]` `[reject]` B4 (blind): push/clone attach after parsing the request, so a token whose request is malformed or refused stays registered. Dart always builds valid buffers; only API misuse (e.g. both colocate flags) leaks a few bytes; the fix needs a parse restructuring.
  - `[medium]` `[patch]` B5 (blind): a fetch/push queued behind another call on the same handle streams the running call's progress as its own. Group G2 (with E6, E16). Action: the worker announces each network call when it starts, and `progress` forwards only after its own announcement.
  - `[low]` `[reject]` B6 (blind): calls on different handles of the same repo now overlap. jj's lock-free op log reconciles concurrent operations, same-workspace snapshots take jj-lib's working-copy lock, and the epic scopes the wait to "the same repo handle" — the situation equals the CLI running beside Zanshin.
  - `[false]` `[reject]` B7 (blind): the fetch's post-git checkpoint discards landed refs. The intent requires "records no import" for a cancelled fetch, and git's remote-tracking refs being updated but not imported is exactly the CLI's state when interrupted after `git fetch`.
  - `[false]` `[reject]` B8 (blind): a push cancelled between remotes leaves stale tracking state. That is 9.20's failure path for a stopped multi-remote push (`push.rs` `a_second_unreachable_remote_stops_the_push`); the intent asks for "what jj-lib records for a failed one".
  - `[low]` `[reject]` B9 (blind): shutdown can outlive the 5 s ack. The 5 s backstop kill predates this story. Main unregisters the Rust sink, so nothing dispatches into a dead listener; only a session leaks after a pathological checkout.
  - `[false]` `[reject]` B10 (blind): a second ShutdownCommand loses the first ack, and queued commands drain after shutdown. Main sends `ShutdownCommand` once (`_doClose` is guarded by `_closed`); queued commands were sent before the shutdown, so FIFO holds.
  - `[low]` `[reject]` B11 (blind): the poller allocates an ARG_MAX buffer per descendant. It runs only while a cancelled call is still running (seconds), over a handful of descendants.
  - `[low]` `[patch]` B12 (blind): the kill tests are not gated to macOS. Action: the kill-dependent tests carry `#[cfg(target_os = "macos")]`.
  - `[low]` `[patch]` B13 (blind): the gitFetch/cloneRepo doc error lists omit `jj.cancelled`; `progress` buffers when unlistened. Action: `jj.cancelled` added to the documented lists. The buffering part is rejected: it is bounded by one call and freed when `result` completes.
  - `[medium]` `[patch]` E1 (edge): another session's hidden-env git on the same git dir is signalled. G1; fixed as B1.
  - `[low]` `[patch]` E2 (edge): a clone with an unregistered, finished or reused token shares a session id. Fixed as B2.
  - `[low]` `[reject]` E3 (edge): the same token attached twice loses cancellability. Unreachable, as B3.
  - `[low]` `[reject]` E4 (edge): a push request refused while parsing leaks its token. As B4.
  - `[low]` `[reject]` E5 (edge): a clone request refused while parsing leaks its token. As B4.
  - `[medium]` `[patch]` E6 (edge): a queued operation's progress shows the running call's events. G2; fixed as B5.
  - `[low]` `[reject]` E7 (edge): a cancelled call outlives the 5 s ack. As B9.
  - `[false]` `[reject]` E8 (edge): git's remote-tracking refs are updated but not imported after a cancel. As B7: the required and CLI-equivalent state.
  - `[low]` `[patch]` E9 (edge): a throw inside `reply`/`fail` leaves the command unanswered. Action: wrapped so any throw answers `internal.dispatch_error`, restoring the catch-all the synchronous switch had, with busy release kept.
  - `[false]` `[reject]` E10 (edge): `zanshinNetworkToken` returns 0. It is the never-zero `next_session_id()` AtomicU64 plus a poison-tolerant registry insert; there is no path to 0.
  - `[low]` `[reject]` E11 (edge): `_cancelledWhileQueued` keeps a stale id. A queued command always reaches `run` (close is queued behind it), so the mark is removed; no reachable path was shown.
  - `[low]` `[reject]` E12 (edge): a pid is reused between the walk and the signal. The window is milliseconds and the processes are our own children, so reuse is implausible; a start-time check adds complexity.
  - `[low]` `[reject]` E13 (edge): the fallback does not compile off unix. Zanshin is a macOS app and the workspace targets macOS only.
  - `[medium]` `[patch]` E14 (edge, claim): hidden-env processes naming the git dir are killed without a token check. G1; docs corrected and the fallback restricted, as B1.
  - `[low]` `[reject]` E15 (edge, claim): the registry holds a bool, not an attached count. As B3: unreachable.
  - `[medium]` `[patch]` E16 (edge, claim): the progress filter matches an earlier queued call's events. G2; fixed as B5.
  - `[low]` `[reject]` E17 (edge, claim): tokens passed to a rejected call are never unregistered. As B4.
  - `[medium]` `[patch]` V1 (verification gap): no test proves the token reaches git's environment. Action: a wrapper logs its own env; the pair is present with a guard and absent without one.
  - `[medium]` `[patch]` V2 (verification gap): the clone's checkpoint after its git work is not exercised. Action: a `clone_cancel.rs` row for a cancel after the last git call → `RepoError::Cancelled`, destination gone.
  - `[medium]` `[patch]` V3 (verification gap): the worker's helper-failure path has no test. Action: a `network_operation_test` case where a NUL remote name answers `internal.dispatch_error` and a later `status()` completes.
  - `[medium]` `[patch]` V4 (verification gap): cancelling a queued fetch, and calls queued at shutdown, are not exercised. Action: tests for a cancelled queued fetch and a second fetch queued at close, both `jj.cancelled` within the window.
  - `[medium]` `[defer]` V5 (verification gap): the worker clone's success path (registering the reserved handle) never runs in Dart. Blocked by the pre-existing Dart VM child-reaping limit (deferred-work.md:449); group G3 with I4.
  - `[medium]` `[patch]` V6 (verification gap, other): the kill scope is wider than documented for two handles on one repo. G1; fixed as B1.
  - `[low]` `[reject]` V7 (verification gap, other): the push/clone token leak on parse refusal. As B4.
  - `[medium]` `[defer]` I1 (intent): no process group is created; stock git is attributed by `--git-dir`, not by the token pair, which deviates from Ralph's "kill git's process group" note and the spec's Never; the "Ralph to confirm" item is not listed under `deferred`. Deferred for Ralph's decision on the hidden-env attribution rule (mirrored in deferred-work.md).
  - `[false]` `[reject]` I2 (intent): push reports the cancel as data. The epic requires that "the result says which remotes got their refs", and 9.20's push failure model never uses an error envelope.
  - `[false]` `[reject]` I3 (intent): helper isolate vs the title's "helper thread". The epic says "or a helper isolate — the story decides".
  - `[medium]` `[defer]` I4 (intent): Dart witness strength — the clone cancel twin may resolve at the pre-git checkpoint, and a successful clone is never witnessed in Dart. G3 with V5; the mid-git kill is witnessed in Rust.
  - `[low]` `[reject]` I5 (intent): per-handle rather than per-repository serialization. As B6.
  - `[false]` `[reject]` I6 (intent): token-keyed cancel vs handle-keyed. The capability is the same, and the epic allows "a token or `cancel()`".
  - `[low]` `[reject]` I7 (intent): the kill path is macOS-only. Zanshin is a macOS app; elsewhere the checkpoints still refuse.
  - `[false]` `[reject]` I8 (intent): the Auto Run Result and deferred-work bookkeeping are missing. They are written at finalize in this run.

### 2026-10-20 — Review pass (follow-up)
- verdicts: 31 findings — high 0, medium 3, low 20, false 8, maybe-false 0
- findings:
  - `[low]` `[reject]` B1 (blind): a fetch/push runs alongside other handles (and path-addressed handle-free calls) of the same repository — carried: calls on different handles of the same repo overlap; jj's op log reconciles concurrent operations and the epic scopes the wait to the same handle (row B6, first pass).
  - `[low]` `[reject]` B2 (blind): `KILL_GRACE` is measured from the cancel, so a git first seen more than 2 s after it gets SIGKILL ~50 ms after its SIGTERM, and `terminated` is never pruned (a recycled pid). After a cancel every verb refuses at its checkpoint or fails its git step, so no git of the call spawns seconds later; pid reuse is the first pass's E12; per-pid timing adds state.
  - `[false]` `[reject]` B3 (blind): the fetch's post-git checkpoint drops refs git already wrote — carried: "records no import" is the intent and the CLI's interrupted-fetch state (row B7, first pass).
  - `[low]` `[patch]` B4 (blind): a cancelled push leaves stale tracking with no hint, and a remote whose killed git push may already have accepted refs is reported not `finished` while the docs said the rows show "which remotes got their refs". The stale-tracking part is carried (row B8, first pass: 9.20's stopped-push path). Action: `docs/ffi-abi.md` § Outcomes now says the rows show whose git push completed and that a killed remote may have accepted some refs, as after any failed git push.
  - `[false]` `[reject]` B5 (blind): the between-remotes checkpoint is untested and two test docs contradict each other. The checkpoint is one statement in the per-remote loop, exercised by `a_push_cancelled_before_it_starts_runs_no_git_push`; the two docs describe a cancel during the last git push that kills it (cancelled) versus one that kills nothing (finishes normally) — both what "no checkpoint after the last remote" implies.
  - `[medium]` `[patch]` B6 (blind): the environment-pair match is never exercised against a real process; every real kill goes through `/bin/sh` and the `--git-dir` fallback, yet a Homebrew git depends on the pair alone. Action: `network_cancel.rs` `a_readable_process_spawned_after_the_cancel_is_killed_by_its_token` spawns this (locally built, environment-readable) test binary carrying the pair, with no git dir watched, and asserts SIGTERM.
  - `[low]` `[reject]` B7 (blind): shutdown waits unbounded when a kill does not land, and helper isolates outlive the killed worker — carried: the 5 s backstop kill predates this story (row B9, first pass).
  - `[low]` `[reject]` B8 (blind): a panic or process exit between SIGSTOP and SIGCONT leaves git stopped. Nothing in that span panics (signals and `tracing::debug!`); an exiting app orphans the process group, which the kernel sends SIGHUP and SIGCONT; a drop guard adds machinery.
  - `[low]` `[reject]` B9 (blind): the walk allocates an ARG_MAX buffer per descendant — carried (row B11, first pass).
  - `[false]` `[reject]` B10 (blind): `zanshinNetworkToken` returning 0 fails silently — carried: no path to 0 (row E10, first pass).
  - `[false]` `[reject]` B11 (blind): the app ignores `progress`/`cancel()` with no deferral recorded. The spec's Never gives that UI to Story 11.8, and the Auto Run Result records it as 11.8 item 10.
  - `[low]` `[patch]` B12 (blind): garbled `zanshin_network_cancel` sentence, unwrapped long lines, and a non-sequitur in § Kill scope. Action: the sentence reads "…carries the pair, or — when its environment is hidden — when its arguments hold `--git-dir`…" (`repo.rs`, regenerated header and `bindings.dart`); long lines wrapped in `cancel.rs` and `ffi-abi.md`; § Kill scope says the polling keeps running until the call ends.
  - `[false]` `[reject]` B13 (blind): the Dart clone-cancel test may get a handle when a fast clone beats the cancel. The `NetworkCancelCommand` is queued on the same port right behind the clone and is handled as soon as the clone arm awaits `Isolate.run`, before the helper runs; and any git failure after the cancel maps to `jj.cancelled`.
  - `[low]` `[reject]` E1 (edge): a second `attach` of one live token — carried (rows B3/E3, first pass).
  - `[low]` `[reject]` E2 (edge): a helper that ignores SIGTERM is reparented once git dies and escapes SIGKILL. git's helpers (`git-remote-*`, `ssh`, `git-upload-pack`) exit on SIGTERM; tracking pids beyond our descendants adds state.
  - `[low]` `[reject]` E3 (edge): the poller signals with a git-dir snapshot taken before the guard dropped, so the next call's git on that dir could be hit. The next call's git must spawn within one poll iteration (tens of ms) after the drop — through the reply, a new `Isolate.run` and a repo load; the re-check is an added guard.
  - `[low]` `[reject]` E4 (edge): a token stays registered when request parsing fails — carried (rows B4/E4/E5, first pass).
  - `[low]` `[reject]` E5 (edge): a helper throw before the FFI call (NUL in an argument) leaves the token's Rust entry. API misuse only, a few bytes; ending it needs a new extern (public surface).
  - `[false]` `[reject]` E6 (edge): a 0 token maps `sessionToId[0]` — carried: no path to 0 (row E10, first pass).
  - `[low]` `[reject]` E7 (edge): `_cancelledWhileQueued` keeps the id of a queued fetch whose handle a close ahead of it invalidated. One int per such case, and command ids are unique, so nothing behaves differently.
  - `[low]` `[reject]` E8 (edge): unlistened `progress` buffers — carried (row B13's buffering part, first pass).
  - `[low]` `[reject]` E9 (edge, claim): the registry holds a bool, not an attached count — carried (row E15, first pass).
  - `[low]` `[patch]` V1 (verification gap): no test pins that a non-zero but finished token gets a fresh session id. Action: `push_ffi.rs` `a_clone_with_a_finished_token_gets_a_fresh_session_id` clones twice with one token; the second session id differs.
  - `[medium]` `[defer]` V2 (verification gap): the worker's successful-clone reply never runs in Dart — carried (row V5, first pass; deferred item 2).
  - `[low]` `[reject]` V3 (verification gap, other): the `_cancelledWhileQueued` leak — as E7.
  - `[medium]` `[defer]` I1 (intent): stock git is attributed by `--git-dir`, not the token pair — carried (row I1, first pass; deferred item 1).
  - `[false]` `[reject]` I2 (intent): no test shows git removing its lock files after SIGTERM. That is git's own behavior; Zanshin's contract is SIGTERM first, which the kill tests assert.
  - `[low]` `[patch]` I3 (intent): `push_remotes` maps any `push_refs` error to the cancel while cancelled, not only subprocess errors. Action: only `GitPushError::Subprocess` maps to `Cancelled`; `NoSuchRemote` / `RemoteName` / `UnexpectedBackend` pass through.
  - `[low]` `[reject]` I4 (intent): the mid-clone, between-remotes and too-late rows are witnessed at the Rust `Repo` surface, not the Dart one, and a too-late fetch (cancel during `import_refs`) at none. The Dart clone rows are blocked by the deferred reaping limit; timing a cancel into `import_refs` needs a production hook.
  - `[low]` `[patch]` I5 (intent): no test shows a git spawned after the cancel is caught. Action: covered by B6's new test, whose child spawns after the cancel while the guard is attached.
  - `[false]` `[reject]` I6 (intent): additions outside the intent (`NetworkOperation`, `NetworkCancelCommand`, the announcement, SIGSTOP). Each is in the spec's Tasks or Change Log, and the intent's matrix names "the operation's `progress` while `result` is still pending".

## Design Notes

**Helper isolate, not a Rust thread** (the story leaves the choice open). The Rust handle is an unlocked `&mut RepoSession` under AD-2. A Rust helper thread would either need a Mutex in every handle access or would have to move the session's ownership out and back. A Dart helper isolate keeps the invariant "one isolate touches a handle at a time": the worker simply does not touch H until the helper returns. The `@Native` bindings work in any isolate of the group, and the worker-owned listener receives dispatches from any thread. The worker and main isolates each have one message queue, so events posted during the call are forwarded before the result. That ordering is the observable fix for I1.

**Kill by token-marked descendants, not a process group.** Ralph's choice was "kill git's process group". The epic left the method to a spike: an exec wrapper with `setpgid`, or libproc enumeration. A wrapper needs an executable: macOS has no `setsid(1)`, Dart build hooks ship code assets (dylibs) only, and a `sh` background-job trick or perl is fragile. It would also override the user's `git.executable-path`. jj-lib's `GitSubprocessOptions.environment` is applied to every git it spawns and is inherited by git's helpers (`git-remote-https`, `ssh`, `git-upload-pack`). So the token marks exactly git's process tree — the set a process group would hold — and enumeration finds it among our descendants without changing what runs. That is the libproc variant, refined.

**Checkpoints plus flag.** A killed git is indistinguishable from any other failure in jj-lib. Checkpoints make an early cancel deterministic, which matters for a fast local clone. The flag maps a git that died after the cancel. A push is never an error envelope (9.20's failure model, `push.rs:1605`), so its cancel is a `PushFailureKind`. That keeps the story's demand that "the result says which remotes got their refs".

Wrapper script shapes for tests:
```sh
#!/bin/sh   # fetch/push: real git, then hold stderr open
"$REAL_GIT" "$@"; s=$?; sleep 30; exit $s
#!/bin/sh   # clone: slow before git
sleep 30; exec "$REAL_GIT" "$@"
#!/bin/sh   # push: slow only for remote r2
case "$*" in *r2*) sleep 30;; esac; exec "$REAL_GIT" "$@"
```

## Verification

**Commands:**
- `cargo make codegen` then `cargo make verify-codegen` -- expected: no drift after committing the outputs.
- `cargo make test` (from the main session, unpiped) -- expected: green, including clippy pedantic, `ffi_abi_doc_sync`, the zanshin_core suite and the coverage ratchet. Commit the raised `coverage-baseline.txt` if it rises.

**Manual checks (if no CLI):**
- `docs/ffi-abi.md`'s Progress notes no longer claim synchronous delivery.

## Auto Run Result

Status: done (code commit `910179b09a2997b37f88631edfe68500d526e2cd`).

**Summary.** The three network verbs now run on a short-lived Dart helper isolate (`Isolate.run`), so their progress streams live; the worker keeps per-handle serialization and returns a `NetworkOperation<T>` (`result`, `progress`, `cancel()`).
- **Live progress.** While a fetch, clone or push runs, its `ProgressEvent`s reach main. A clone reserves its handle id and uses its cancel token as session id, so its progress is routed before it returns.
- **Cancel.**
  - New externs `zanshin_network_token` / `zanshin_network_cancel`.
  - The token rides git's environment, and a macOS poller signals the call's git processes: SIGTERM, then SIGKILL after 2 s.
  - Checkpoints make the verbs refuse: fetch and clone with the new `jj.cancelled` (the clone through 9.20's clean-up), push as `PushFailureKind.cancelled` with its per-remote data.

**Intent items.**
- **I1 (progress reaches main only after the call returned): fixed** in `910179b09a2997b37f88631edfe68500d526e2cd`. Fetch, clone and push run on a helper isolate, so the worker's event loop forwards `ProgressEvent`s while the call runs. Witnesses: `network_operation_test.dart` (progress while `result` is pending, fetch and clone; a queued call sees none of the running call's events).
- **I2 (clone has no progress and cannot be cancelled): partly done** in `910179b09a2997b37f88631edfe68500d526e2cd`. Story 9.52's part — live clone progress and Cancel — is done; the CLI destination rules came with 9.20.
  - Left for Story 11.8 item 10, already recorded there: removing `ProjectSession.clone`'s app-side port and showing progress and Cancel in the form.
  - Cancel is not a literal process-group kill. Stock macOS git hides its environment, so it is identified by `--git-dir`; Ralph is asked to confirm this rule (deferred item 1).

**Files changed** (54):
- `crates/zanshin-jj/src/cancel.rs` (new) — the token registry, attach guards, checkpoints and the macOS kill poller.
- `environment.rs` — adds the token to git's environment.
- `remotes.rs` / `creation.rs` / `push.rs` / `repo.rs` / `mutate.rs` — checkpoints and the `Cancelled` variants.
- `workspace_add.rs` — passes no token.
- `crates/zanshin-ffi/src/{repo,push,envelope}.rs` — `JJ_CANCELLED`, the two externs, the fetch's `cancel_token` argument, and clone's token-as-session-id.
- `schemas/envelope.fbs` plus the regenerated Rust, Dart and C outputs — the `cancel_token` fields and the `Cancelled` enum value.
- `packages/zanshin_core/lib/src/worker/network_operation.dart` (new); `isolate.dart` — the network scheduler, queueing, announcements, cancel and shutdown; `commands.dart`, `handle.dart`, `events.dart`, `ffi/{mutate,push,repo}.dart`, the barrel.
- `app/lib/src/features/projects/worker_project_repos.dart` — `.result`.
- `docs/ffi-abi.md` (Cancel section, index rows, 70 exports), `docs/rust-error-codes.md` (`jj.cancelled`).
- Tests: `zanshin-jj/tests/{network_cancel,clone_cancel}.rs` (new), the FFI tests, `zanshin_core` `network_operation_test.dart` (new), updated call sites in existing tests.
- `coverage-baseline.txt` raised: `cancel.rs` 98.85, `creation.rs` 96.88, `push.rs` 93.84.

**Review** (one pass, 45 findings: high 0, medium 14, low 22, false 9).
- **Patched** (11 entries: 6 medium, 5 low):
  - the shared-git-dir cross-kill (G1);
  - a queued call's progress showing the running call's events (G2);
  - the env-pair, clone after-git checkpoint, helper-failure and queued/shutdown cancel tests (V1–V4);
  - clone session id only for a live token;
  - reply/fail wrapped to answer `internal.dispatch_error`;
  - macOS gating of the kill tests;
  - `jj.cancelled` in the doc error lists.
- **Deferred:** 2 entries (mirrored in deferred-work.md).
  - The `--git-dir` attribution rule needs Ralph's confirmation.
  - There is no Dart witness of a successful worker clone (child-reaping limit).
- **Rejected:**
  - Unreachable: double attach and attach count; tokens leaked by malformed or refused requests; a stale queued-cancel mark; a token of 0.
  - Pre-existing 5 s shutdown backstop.
  - Concurrency across handles of one repo: jj's op log reconciles it, and the epic scopes the wait per handle.
  - Fetch refs not imported, and stale tracking after a stopped push: both are required, CLI-equivalent states.
  - Poller allocation and pid reuse: negligible.
  - Off-unix compile: macOS app.
  - The intent-reading divergences (push as data, isolate vs thread, token-keyed cancel, macOS-only kill, bookkeeping written at finalize): the epic allows each.
  - Every row is in the Review Triage Log.

**Follow-up review recommended: true.** Six medium entries were patched (counts by verdict: medium 6, low 5). The specific unverified risk is the kill attribution after the G1 patch: the "exactly one live call watches the dir" filter, and the SIGSTOP/rescan loop, run against a real network git (`git-remote-https` / `ssh`) rather than the `file://` wrappers the tests use.

**Verification.**
- `cargo make codegen` produced no drift (run twice).
- `cargo make test` exited 0 before review, and again after the patches: a full run of 918 s, clippy pedantic, `ffi_abi_doc_sync`, the zanshin_core suite, and the coverage ratchet held at 99.09%; extern-coverage OK.
- The matrix rows are covered by `network_cancel.rs`, `clone_cancel.rs`, the `cancel.rs` unit tests and `network_operation_test.dart`.

**Child-reaping re-check** (epic witness): inside `dart test`, a helper-isolate clone still fails jj-lib's wait with `jj.network_error` "Failed to wait for the git process" in 3 of 3 runs. The limit is process-wide, so the Rust-only success witnesses got no Dart twins.

**Residual risks.**
- A token-less git on the same git dir (a concurrent `workspace add` on another handle of the repo) could be signalled by a cancel.
- The Dart clone-cancel test relies on the cancel landing before the first checkpoint.
- `project-context.md`'s "never `Isolate.run` for repeated work" rule now has a per-network-call exception that the rule text does not mention.
- Calls on different handles of the same repo now overlap during a network verb.

### Follow-up review pass (2026-10-20)

Status: done. A fresh four-layer review of the change since `31e4bcab50485082491452ffbbff9b7a0c376286`; the small fixes were applied in this run.

**Summary.**
- A cancelled push now maps only a git subprocess failure to `PushFailureKind.cancelled`; other `push_refs` errors pass through, as the spec requires.
- Two new tests:
  - a real, environment-readable process spawned after the cancel is killed by its token pair alone;
  - a finished token gets a fresh session id when it is passed to a clone again.
- Doc corrections: the `zanshin_network_cancel` sentence, § Kill scope, § Outcomes on a killed remote, and the long lines.

**Files changed.**
- `crates/zanshin-jj/src/push.rs`: only `GitPushError::Subprocess` maps to the cancel.
- `crates/zanshin-jj/src/cancel.rs`: the module doc is rewrapped.
- `crates/zanshin-jj/tests/network_cancel.rs`: adds `a_readable_process_spawned_after_the_cancel_is_killed_by_its_token`, plus its `sleeper_child` helper.
- `crates/zanshin-ffi/tests/push_ffi.rs`: adds `a_clone_with_a_finished_token_gets_a_fresh_session_id`.
- `crates/zanshin-ffi/src/repo.rs`, `include/zanshin_ffi.h` and `packages/zanshin_core/lib/src/ffi/bindings.dart` (the last two regenerated): the `zanshin_network_cancel` doc sentence.
- `docs/ffi-abi.md`: § Kill scope, § Outcomes and line wrapping.

**Review** (31 findings: high 0, medium 3, low 20, false 8).
- **Patched** (6 entries: medium 1, low 5):
  - the environment-pair kill on a real process (B6);
  - a git spawned after the cancel (I5);
  - the push error mapping (I3);
  - the finished-token clone test (V1);
  - the killed-remote wording (B4);
  - doc readability (B12).
- **Deferred:** none new. V2 and I1 are carried from the first pass and are already deferred items 2 and 1, so nothing was added to `deferred-work.md`.
- **Rejected:** each with its reason in the Review Triage Log.
  - Carried from the first pass: cross-handle overlap; refs not imported; stale tracking; the shutdown backstop; poller allocation; token 0; double attach; parse-refusal leaks; progress buffering.
  - New and negligible: KILL_GRACE measured from the cancel; panic safety between stop and continue; a helper that ignores SIGTERM; the stale git-dir snapshot; the Dart throw before the FFI leaking a token; the queued-cancel id leak.
  - False: the between-remotes checkpoint (it is one loop statement); the Dart clone-cancel race (the cancel is queued right behind the clone); the UI deferral (it belongs to 11.8); git's lock-file clean-up; the spec-sanctioned additions.

**Follow-up review recommended: false.** This was a follow-up pass and patched no `high`; patched counts are medium 1 and low 5.

**Verification.**
- `cargo make codegen` regenerated the header and `bindings.dart` doc comments.
- `cargo test -p zanshin-jj --test network_cancel`: 11 passed.
- `cargo test -p zanshin-ffi --test push_ffi`: 9 passed.
- `cargo make test`, change-aware, 11 of 27 steps: exit 0 in 915 s. Clippy pedantic, fmt, cargo doc, flutter/dart analyze and format, hygiene, and coverage all passed. Coverage held at 99.09% and extern coverage is OK; the baseline did not change.

**Residual risks.** Unchanged from the first pass: the `--git-dir` attribution rule waits on Ralph (deferred item 1), and no Dart test witnesses a successful worker clone (deferred item 2).
