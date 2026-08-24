---
title: 'Story 6.4a: Remote op — git fetch with progress callback'
type: 'feature'
created: '2026-08-24'
status: 'done'
baseline_revision: '57ae0d0643953b2c5f318048b47a5d136236e5ac'
review_loop_iteration: 0
followup_review_recommended: true
context: []
warnings: ['oversized']
deferred:
  - summary: >-
      remote_auto_track_bookmarks is hardcoded empty, so newly-fetched remote
      bookmarks are never auto-tracked per the user's git.auto-local-bookmark
      config.
    evidence: |-
      Blind Hunter review pass. Mirrors clone_into's own pre-existing hardcoded
      GitImportOptions literal (Story 2.x) verbatim, per this story's own spec
      Boundaries ("mirrors clone_into verbatim") — not a new limitation introduced
      by this story.
    location: 'crates/zanshin-jj/src/remotes.rs:git_fetch'
    severity: medium
  - summary: >-
      Several fallible internal steps (GitSubprocessOptions::from_settings,
      expand_fetch_refspecs, fetcher.import_refs()'s generic-failure path, the
      get_wc_commit_id internal invariant) funnel to the generic
      MutateError::Backend with no dedicated test forcing that exact path.
    evidence: |-
      Blind Hunter review pass. Low practical value to engineer directly: some are
      near-infallible given the hardcoded valid glob("*") inputs; others would
      require corrupting jj-lib internals to trigger deterministically.
    location: 'crates/zanshin-jj/src/remotes.rs:git_fetch'
    severity: low
  - summary: >-
      git_fetch_reserved_remote_name_returns_backend_error and the happy-path
      test's raw .jj/repo/store/git ODB inspection both couple the test suite to
      jj-lib internal implementation details (validation order, on-disk store
      layout) that could shift on a future jj-lib version bump.
    evidence: |-
      Blind Hunter review pass. Same class of risk already accepted for Story
      6.2's op_heads marker-file tests (Blind Hunter, low, that story's own
      Review Triage Log).
    location: 'crates/zanshin-jj/tests/remotes_write.rs'
    severity: low
  - summary: >-
      No cancellation/timeout mechanism exists for git_fetch; a hung network
      fetch has no way to be interrupted by the caller.
    evidence: |-
      Blind Hunter review pass. Real for a GUI-invoked long-running operation, but
      jj-lib's own synchronous GitFetch::fetch offers no cancellation hook to
      build on — a future concern for a UI-facing wrapper, not resolvable within
      this story's scope.
    location: 'crates/zanshin-jj/src/remotes.rs:git_fetch'
    severity: medium
  - summary: >-
      import_refs() can fail after fetch() has already written git-level
      remote-tracking refs/objects to the colocated git ODB, leaving the git repo
      and jj's own view momentarily out of sync until a subsequent successful
      fetch reconciles them.
    evidence: |-
      Edge Case Hunter review pass. An inherent two-phase characteristic of
      jj-lib's own GitFetch API (also present, unchanged, in the pre-existing
      clone_into), not something introduced by this story.
    location: 'crates/zanshin-jj/src/remotes.rs:git_fetch'
    severity: medium
  - summary: >-
      Reading the post-commit working-copy commit (get_wc_commit_id/get_commit)
      can fail after tx.commit() has already persisted the fetch operation,
      leaving a committed-but-unreported state with no distinct signal to the
      caller.
    evidence: |-
      Edge Case Hunter review pass. Same accepted risk class already deferred
      from Story 6.1/6.2's sync_working_copy post-commit partial-failure gap.
    location: 'crates/zanshin-jj/src/remotes.rs:git_fetch'
    severity: medium
  - summary: >-
      epics.md's edge-case list names "authentication failures (HTTPS without
      credentials, SSH key issues)" as a case distinct from the generic
      network-failure case, but git_fetch's error mapping treats every git
      subprocess failure uniformly as NetworkError with the message forwarded
      verbatim, and only one subprocess-failure trigger (unreachable path) is
      tested.
    evidence: |-
      Intent Alignment Auditor pass. Satisfies the AC's actual requirement ("the
      error message is descriptive... the user knows what to fix") without a
      second test, since the code path is identical regardless of the subprocess
      failure's specific cause — testing a second trigger would add no additional
      code-path coverage, just a different error message.
    location: 'crates/zanshin-jj/src/remotes.rs:git_fetch'
    severity: low
---

<intent-contract>

## Intent

**Problem:** `zanshin-jj` can only read remotes (`list_remotes`); it has no way to actually sync with one (FR-JJ-13). `git fetch` is the first real load-bearing consumer of a Rust-level progress-callback contract in WIP.

**Approach:** Extend `crates/zanshin-jj/src/remotes.rs` with `Repo::git_fetch(remote_name: &str, progress: &ProgressFn) -> Result<MutationResult, MutateError>`, following the exact jj-lib call sequence `Repo::clone`'s existing `clone_into` already uses for its own fetch step, but wired to a real progress-forwarding `GitSubprocessCallback` instead of `NoopCallback`. `git_push` is dropped entirely from this story (WIP-rework, 2026-05-17) — deferred to the release phase (FR-JJ-13b).

## Boundaries & Constraints

**Always:**
- Signature is exactly epics.md's: `pub type ProgressFn = dyn Fn(ProgressEvent) + Send + Sync;` `pub struct ProgressEvent { pub operation: String, pub progress: f32, pub message: String }`; `Repo::git_fetch(&mut self, remote_name: &str, progress: &ProgressFn) -> Result<MutationResult, MutateError>`.
- Fetch ALL branches and tags (`GitFetchRefExpression { bookmark: glob("*"), tag: glob("*") }` via `expand_fetch_refspecs`) — mirrors `clone_into`'s existing precedent exactly, since this story's signature exposes no branch/tag filter param (epics.md's AC only parameterizes `remote_name`).
- `GitImportOptions`/`GitSubprocessOptions` construction mirrors `clone_into` verbatim: `record_synthetic_predecessors: false, abandon_unreachable_commits: true, remote_auto_track_bookmarks: HashMap::new()`, `GitSubprocessOptions::from_settings(settings)`.
- Op-log description on success: `format!("fetch from git remote(s) {remote_name}")` — the CLI's own literal prefix (`cli/src/commands/git/fetch.rs`), adapted to this API's single-remote signature (NFR-R-2).
- A fresh op is committed even when nothing changed (matches the CLI — fetch never no-ops the transaction).
- Do NOT call `rebase_descendants()` between `import_refs()` and `tx.commit()` — the real CLI doesn't either (`import_refs_inner` handles any needed rebase internally); calling it anyway is harmless but not CLI-observed behavior.
- `git_fetch` never moves `@` — skip `mutate::capture_old_wc`/`sync_working_copy`/`workspace.check_out` entirely (fetch only touches remote-tracking refs); `MutationResult.working_copy_change_id` is simply the (unchanged) post-commit `@`. Because of this, the internal free fn takes `&Workspace`, not `&mut Workspace`.
- `MutationResult.new_change_ids`/`.abandoned_change_ids` are always empty for `git_fetch` (it imports remote refs; it doesn't mint/abandon a change in the sense these fields track) — extend their doc comments in `mutate.rs` to name `git_fetch` alongside `describe`/`new_change`/`undo`.
- The callback always requests progress (`needs_progress() -> true`); forward every `GitSubprocessCallback::progress(&GitProgress)` tick verbatim as `ProgressEvent{operation:"fetch", progress: git_progress.overall(), message}` — no synthetic manual 100% event (the epic context's "final event rides the function's return" describes the FFI-dispatch layer added in Story 6.5, not a requirement on this Rust-level callback).
- `local_sideband`/`remote_sideband` are no-ops (`Ok(())`) — raw git subprocess text is terminal-UX chatter Zanshin replaces (matches `NoopCallback`'s existing treatment of the same two hooks).
- Error mapping (`GitFetchError`/`UnexpectedGitBackendError` → `MutateError`, via `remote_name` in scope): `NoSuchRemote(_)` and `GitFetch::new`'s `UnexpectedGitBackendError` (no git backend ⇒ the remote categorically can't exist) → `RemoteNotFound { name }`; `Subprocess(sub_err)` → `NetworkError { reason: sub_err.to_string() }`; everything else (`RemoteName`, `RejectedUpdates`, `GitImportError`, `ConfigGetError` from `GitSubprocessOptions::from_settings`) → `mutate::be(e)` (`MutateError::Backend`).

**Block If:** none identified — the AC, jj-lib 0.42.0 API, and the existing `clone_into` precedent fully resolve the call sequence.

**Never:**
- Never implement `git_push` — dropped from this story's scope entirely (WIP-rework); a later, separate story adds it as a linear extension.
- Never touch `zanshin-ffi` or `docs/rust-error-codes.md` — this story is `zanshin-jj`-only (Story 6.5 wraps the Dart `NativeCallable.listener` into `ProgressFn` and maps these new `MutateError` variants to `error.code`).
- Never modify `Repo::clone`/`clone_into`/`NoopCallback` in `repo.rs` — a separate code path (initial clone), out of this story's scope; leave its pre-existing "Epic 6 Story 6.4a" TODO comment as-is.
- Never replicate the CLI's `--branch`/`--tag`/`--tracked`/`--remote`/`--all-remotes` filtering or its `git.fetch`-config/single-remote-guess default-remote resolution — this story's signature takes only `remote_name: &str`, caller-supplied (FR-JJ-17); no hidden default remote.
- Never shell to `jj git fetch` (AR-AP-1) — only jj-lib's `GitFetch`.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Fetch happy path | `git_fetch("origin", cb)`, bare remote has commits not yet local | New commits/bookmarks imported; op-log gains `"fetch from git remote(s) origin"`; `cb` invoked ≥1 time with `progress` in `0.0..=1.0` | — |
| Fetch, nothing new | `git_fetch("origin", cb)`, remote unchanged since last fetch | Op-log still gains a new fetch op (CLI parity); `working_copy_change_id` unchanged | — |
| Fetch, remote absent | `git_fetch("nonexistent", cb)` | — | `Err(RemoteNotFound{name: "nonexistent"})` |
| Fetch, native (non-git) backend | `git_fetch` on a `Repo::init(path, None)` repo | — | `Err(RemoteNotFound{name})` (no git backend ⇒ no such remote) |
| Fetch, subprocess/auth/network failure | remote URL unreachable or requires unavailable credentials | — | `Err(NetworkError{reason})`, `reason` chains the underlying git/jj-lib message; no op committed |

</intent-contract>

## Code Map

- `crates/zanshin-jj/src/remotes.rs` -- extend: add `ProgressEvent`, `ProgressFn`, `pub(crate) fn git_fetch(workspace: &Workspace, settings: &UserSettings, remote_name: &str, progress: &ProgressFn) -> Result<MutationResult, MutateError>`, and a private `FetchCallback<'a>` implementing `jj_lib::git::GitSubprocessCallback` (translates `GitProgress` ticks into `progress` calls; sidebands no-op). Update the module doc comment (currently "configured git-remote list **read**") to note it now also fetches. New imports: `jj_lib::git::{expand_fetch_refspecs, GitFetch, GitFetchError, GitFetchRefExpression, GitImportOptions, GitProgress, GitSidebandLineTerminator, GitSubprocessCallback, GitSubprocessOptions}`, `jj_lib::ref_name::{RemoteName, RemoteNameBuf}`, `jj_lib::settings::UserSettings`, `jj_lib::str_util::{StringExpression, StringPattern}`, `crate::mutate::{self, MutateError, MutationResult}`, `std::io`.
- `crates/zanshin-jj/src/mutate.rs:49-81` (`MutateError`) -- add `RemoteNotFound { name: String }` (`#[error("no such remote: {name}")]`) and `NetworkError { reason: String }` (`#[error("network error: {reason}")]`) variants; extend `MutationResult`'s `new_change_ids`/`abandoned_change_ids` doc comments (lines ~29-40) to also name `git_fetch` as always-empty.
- `crates/zanshin-jj/src/repo.rs:333-354` (mutation delegate group, right after `undo`) -- add `pub fn git_fetch(&mut self, remote_name: &str, progress: &crate::ProgressFn) -> Result<crate::MutationResult, crate::MutateError> { crate::remotes::git_fetch(self.workspace(), self.settings(), remote_name, progress) }` (both args are `&self`-borrows — no borrow conflict), matching the existing per-noun delegation pattern (doc comment + `#[must_use]`).
- `crates/zanshin-jj/src/repo.rs:430-557` (`clone_into`) -- READ-ONLY reference: the `Workspace::init_internal_git` → `add_remote` → reload → `GitFetch::new` → `.fetch(remote_name, refspecs, callback, None, None)` → `import_refs()` sequence, and the exact `GitFetchRefExpression{bookmark: glob("*"), tag: glob("*")}` / `GitImportOptions{..}` / `GitSubprocessOptions::from_settings(settings)` literals to reuse. Do not modify this function or `NoopCallback` (lines 560-580).
- `../jj` `v0.42.0` `cli/src/commands/git/fetch.rs:170-262` (`cmd_git_fetch`) -- behavioral reference for the op-log description literal (`"fetch from git remote(s) {}"`) and confirms no `rebase_descendants()` call between `import_refs()` and `tx.finish()`.
- `jj-lib 0.42.0` (vendored `~/.cargo/registry/.../jj-lib-0.42.0/src/`): `git.rs:2969-3097` (`GitFetch::new`/`fetch`/`import_refs`; `GitFetchError::{NoSuchRemote,Subprocess,RemoteName,RejectedUpdates}`; `GitFetchError` wraps `UnexpectedGitBackendError` only via `GitFetch::new`'s own `Result`, not a `GitFetchError` variant — map it directly), `git_subprocess.rs:686-785` (`GitSubprocessCallback` trait; `GitProgress{deltas,objects,counted_objects,compressed_objects}:(u64,u64)` + `overall()->f32`; `GitSubprocessError::External(String)` is where auth/network failures surface as text).
- `crates/zanshin-jj/tests/api_stability.rs:73,139,205-209` -- add `type _ProgressEvent = zanshin_jj::ProgressEvent;`, a `let _: &zanshin_jj::ProgressFn = &|_: zanshin_jj::ProgressEvent| {};` type-pin, a `Repo::git_fetch` fn-pointer pin (`as fn(&mut zanshin_jj::Repo, &str, &zanshin_jj::ProgressFn) -> Result<zanshin_jj::MutationResult, zanshin_jj::MutateError>`), and `_ = zanshin_jj::MutateError::RemoteNotFound{name: String::new()};` / `_ = zanshin_jj::MutateError::NetworkError{reason: String::new()};`.
- `crates/zanshin-jj/src/lib.rs:39,53` -- `pub use remotes::{ProgressEvent, ProgressFn, Remote, RemoteError};` (add the two new types to the existing `remotes::` re-export line; `mutate`/`repo` re-export lines already cover `MutateError`/`Repo`, no change needed there).
- `crates/zanshin-jj/tests/convert.rs:22,323-331` (`fn git(args, dir)`, `fn git_bare_clone(src, parent) -> PathBuf`) -- precedent subprocess-git-in-tests helpers (each `tests/*.rs` file is a separate compilation unit, so `remotes_write.rs` needs its own small local copy, not an import).
- `crates/zanshin-jj/tests/remotes_write.rs` -- NEW (epics.md AC's literal filename) -- local bare-git-remote fixture (no network), covering the I/O matrix.

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/src/mutate.rs` -- add `MutateError::{RemoteNotFound,NetworkError}`, extend `MutationResult` field docs -- error taxonomy + doc accuracy for the new mutation
- `crates/zanshin-jj/src/remotes.rs` -- add `ProgressEvent`, `ProgressFn`, `git_fetch`, `FetchCallback` -- the story's core deliverable
- `crates/zanshin-jj/src/repo.rs` -- add `pub fn git_fetch(&mut self, ...)` delegate -- wires it into `Repo`'s public surface
- `crates/zanshin-jj/src/lib.rs` -- re-export `ProgressEvent`/`ProgressFn` -- exposes the new public types (FR-JJ-16)
- `crates/zanshin-jj/tests/remotes_write.rs` -- NEW integration tests against a local bare-git fixture -- covers every I/O-matrix row
- `crates/zanshin-jj/tests/api_stability.rs` -- pin the new types/variants/method signature

**Acceptance Criteria:**
- Given `crates/zanshin-jj/src/remotes.rs`, when extended, then it exposes `ProgressFn`, `ProgressEvent{operation,progress,message}`, and `Repo::git_fetch(&mut self, remote_name: &str, progress: &ProgressFn) -> Result<MutationResult, MutateError>` with exactly epics.md's signature (`git_push` excluded).
- Given `Repo::git_fetch("origin", callback)` against a local bare-git remote with unfetched commits, when called, then `callback` is invoked one or more times with `ProgressEvent{operation:"fetch", progress in 0.0..=1.0, ..}`, the commits/bookmarks are imported, and `Repo::op_log(Some(1))`'s newest entry's description is `"fetch from git remote(s) origin"` (NFR-R-2).
- Given a fetch against a nonexistent remote, when it fails, then `Repo::git_fetch` returns `Err(MutateError::RemoteNotFound{name})` and no new operation appears in the op-log.
- Given `cargo test -p zanshin-jj` and `cargo make test`, when run, then all pass, including clippy pedantic (`-D warnings`), rustfmt, and the coverage ratchet (updated `coverage-baseline.txt` committed).

## Spec Change Log

## Review Triage Log

### 2026-08-24 — Review pass
- intent_gap: 0
- bad_spec: 0
- patch: 5: (high 1, medium 1, low 3)
- defer: 7: (high 0, medium 4, low 3)
- reject: 7: (high 0, medium 0, low 7)
- addressed_findings:
  - `high` `patch` No test verified that `fetcher.import_refs()` actually makes fetched refs visible in jj's OWN view (`list_bookmarks`/revset), only that the raw git ODB was updated — Verification Gap demonstrated that deleting the `import_refs()` call would leave every existing assertion passing. Extended the happy-path test to also push+fetch a tag and assert, via `Repo::list_bookmarks()`, that the fetched bookmark is visible in jj's own view (not only via `git rev-parse` against the git ODB).
  - `medium` `patch` `progress_message`'s 4-way phase-priority logic (deltas > objects > compressed_objects > counted_objects) had no test asserting its actual output or selection order (Verification Gap + Blind Hunter, deduplicated). Added a focused `#[cfg(test)]` unit test in `remotes.rs` covering phase-priority selection and the `"<phase>: <fraction>/<total>"` format.
  - `low` `patch` `GitProgress::overall()` is jj-lib's own computed value; a transient reporting glitch could theoretically produce a value outside `0.0..=1.0`, violating `ProgressEvent.progress`'s documented range guarantee (Edge Case Hunter). Clamped it defensively in `FetchCallback::progress`.
  - `low` `patch` `mutate.rs`'s two extended `MutationResult` field doc comments linked to the private `` [`crate::remotes::git_fetch`] `` path, inconsistent with every other public-surface link in this diff (Blind Hunter). Changed both to `` [`crate::Repo::git_fetch`] ``.
  - `low` `patch` `Repo::git_fetch`'s public doc comment didn't mention that it always fetches ALL branches and tags with no filter parameter — the private `remotes.rs` free fn has a `WHY:` comment explaining this, but the public-facing doc comment didn't (Blind Hunter). Added one sentence.

Deferred (pre-existing patterns or out-of-scope concerns surfaced incidentally, not caused fresh by this story): `remote_auto_track_bookmarks` hardcoded empty, inherited from `clone_into` (Blind Hunter, medium); several fallible internal steps funnel to the generic `Backend` error with no dedicated forcing test, low practical value to engineer (Blind Hunter, low); two tests couple the suite to jj-lib internal implementation details that could shift on a version bump, same class already accepted for Story 6.2 (Blind Hunter, low); no cancellation/timeout mechanism for a long-running fetch, jj-lib itself offers no hook to build on (Blind Hunter, medium); `import_refs()` can fail after `fetch()` already wrote git-level refs, an inherent two-phase characteristic of jj-lib's own API also present unchanged in `clone_into` (Edge Case Hunter, medium); the post-commit working-copy read can fail after `tx.commit()` already persisted the op, same accepted risk class as Story 6.1/6.2's `sync_working_copy` gap (Edge Case Hunter, medium); epics.md names auth failures as a case distinct from generic network failures but the code (correctly, per the AC's own wording) treats every subprocess failure uniformly with a descriptive message (Intent Alignment Auditor, low).

Rejected (noise, or addressed by design on inspection of the actual jj-lib 0.42.0 source and this crate's existing conventions, not merely the spec's paraphrase): `GitFetch::new`'s error unconditionally mapped to `RemoteNotFound` "discards other failure causes" — factually incorrect, `UnexpectedGitBackendError` is a unit struct with exactly one possible cause, verified directly against the vendored jj-lib 0.42.0 source (Blind Hunter); `MutateError::NetworkError` conflating network/auth/transport into one variant — matches epics.md's actual AC literally ("the error message is descriptive... the user knows what to fix"), separate typed variants would be scope creep (Blind Hunter); `RemoteNotFound`'s doc comment FR-JJ-13 tag "should be" FR-JJ-9 — the tag correctly identifies which feature the error variant belongs to (Blind Hunter); `needs_progress()` unconditionally `true` with no caller opt-out — no real cost or harm, not part of epics.md's AC (Blind Hunter); no `catch_unwind` around the caller's progress closure — architecturally out of pattern for `zanshin-jj` (panic-catching is deliberately centralized at the FFI boundary per project-context.md, not per mutation function); a panicking closure unwinds and drops the uncommitted transaction exactly like any other early-return error path, already safe by jj-lib's transaction model (Edge Case Hunter); `import_refs()` discarding abandoned-commit stats "contradicts" `abandoned_change_ids`' contract — actually consistent with that field's own established doc-comment rule excluding jj-lib's own automatic side effects (same rule Story 6.1 already applied to `edit()`'s implicit abandon) (Edge Case Hunter); the public-delegate-plus-private-free-fn signature shape diverging from epics.md's illustrative code block — the Intent Alignment Auditor itself confirmed this matches the codebase's established per-noun delegation convention, not a deviation from intent.

## Design Notes

**`git_fetch` core** (mirrors `clone_into`'s fetch step; no wc capture/sync — `@` never moves):
```rust
let remote_buf: RemoteNameBuf = remote_name.into();
let remote: &RemoteName = &remote_buf;
let readonly = pollster::block_on(workspace.repo_loader().load_at_head()).map_err(mutate::be)?;
let mut tx = readonly.start_transaction();
let subprocess_options = GitSubprocessOptions::from_settings(settings).map_err(mutate::be)?;
let import_options = GitImportOptions { record_synthetic_predecessors: false, abandon_unreachable_commits: true, remote_auto_track_bookmarks: HashMap::new() };
let mut fetcher = GitFetch::new(tx.repo_mut(), subprocess_options, &import_options)
    .map_err(|_| MutateError::RemoteNotFound { name: remote_name.to_owned() })?;
let expr = GitFetchRefExpression { bookmark: StringExpression::Pattern(Box::new(StringPattern::glob("*").map_err(mutate::be)?)), tag: StringExpression::Pattern(Box::new(StringPattern::glob("*").map_err(mutate::be)?)) };
let refspecs = expand_fetch_refspecs(remote, expr).map_err(mutate::be)?;
let mut cb = FetchCallback { progress };
fetcher.fetch(remote, refspecs, &mut cb, None, None).map_err(|e| match e {
    GitFetchError::NoSuchRemote(_) => MutateError::RemoteNotFound { name: remote_name.to_owned() },
    GitFetchError::Subprocess(sub) => MutateError::NetworkError { reason: sub.to_string() },
    other => mutate::be(other),
})?;
pollster::block_on(fetcher.import_refs()).map_err(mutate::be)?; // no rebase_descendants — see Boundaries
let new_repo = pollster::block_on(tx.commit(format!("fetch from git remote(s) {remote_name}"))).map_err(mutate::be)?;
let wc_id = new_repo.view().get_wc_commit_id(workspace.workspace_name())
    .ok_or_else(|| MutateError::Backend("workspace has no working-copy commit".to_owned()))?;
let wc_commit = new_repo.store().get_commit(wc_id).map_err(mutate::be)?;
Ok(MutationResult { new_op_id: crate::OperationId(new_repo.op_id().hex()), new_change_ids: vec![], abandoned_change_ids: vec![], working_copy_change_id: ChangeId(wc_commit.change_id().reverse_hex()) })
```

**`FetchCallback`** (private, `remotes.rs`): holds `progress: &'a ProgressFn`; `needs_progress() -> true`; `progress(&mut self, p: &GitProgress)` calls `(self.progress)(ProgressEvent{operation:"fetch".to_owned(), progress: p.overall(), message})`, returns `Ok(())`; `local_sideband`/`remote_sideband` are `Ok(())` no-ops. `message` is a short freeform string naming whichever of `p.deltas`/`p.objects`/`p.counted_objects`/`p.compressed_objects` has a nonzero total (e.g. `"resolving deltas: 4/10"`) — NOT CLI-exact terminal wording (only op-log descriptions need NFR-R-2 parity; free-form progress text doesn't).

**Test fixture recipe** (`remotes_write.rs`, no network): build a small source repo with 1-2 commits via plain `git` subprocess calls (init/commit — allowed in fixture-setup, AR-AP-1's exception), `git clone --bare` it into a tmpdir (mirrors `tests/convert.rs`'s `git_bare_clone`), `Repo::init(dst, Some(Backend::Git))`, `jj_lib::git::add_remote(...)` pointing "origin" at the bare path (mirrors `tests/remotes.rs`'s `add_remotes` / `clone_into`'s Step 2 reload dance — add_remote + drop tx + reload workspace so the fresh `GitBackend` sees the config), then `Repo::git_fetch("origin", &collecting_closure)`.

## Verification

**Commands:**
- `cargo test -p zanshin-jj` -- expected: new `tests/remotes_write.rs` tests pass, existing suite unaffected
- `cargo clippy -p zanshin-jj --all-targets -- -D warnings` -- expected: clean (pedantic on)
- `cargo make test` -- expected: full gate passes (clippy workspace-wide, rustfmt, `flutter test`/`dart analyze` unaffected by this Rust-only change, `cargo deny`, coverage ratchet); commit the updated `coverage-baseline.txt`

## Auto Run Result

**Summary:** Implemented `Repo::git_fetch` (FR-JJ-13) — the first real load-bearing consumer of the `zanshin-jj`-level progress-callback pattern. `crates/zanshin-jj/src/remotes.rs` gained `ProgressEvent`/`ProgressFn`, a private `FetchCallback` adapter (translates jj-lib's `GitSubprocessCallback`/`GitProgress` ticks into `ProgressEvent`s; sidebands are no-ops), and `pub(crate) fn git_fetch` mirroring `clone_into`'s existing fetch step (same `GitFetchRefExpression{bookmark: glob("*"), tag: glob("*")}`, `GitImportOptions`, `GitSubprocessOptions::from_settings` construction) but wired to real progress forwarding instead of `NoopCallback`. `git_fetch` always fetches ALL branches and tags (no filter param in this story's signature), always commits a fresh op even when nothing changed (CLI parity), and — because fetch never moves `@` — skips the `capture_old_wc`/`sync_working_copy` dance the four `mutate.rs` mutations use. Two new `MutateError` variants (`RemoteNotFound`, `NetworkError`) were added, with `GitFetchError`/`UnexpectedGitBackendError` mapped precisely (`NoSuchRemote` and "no git backend at all" → `RemoteNotFound`; `Subprocess` → `NetworkError`; everything else → the existing generic `Backend`). `git_push` was deliberately NOT implemented — dropped from this story's scope entirely per the 2026-05-17 WIP-rework, deferred to the release phase (FR-JJ-13b). `zanshin-ffi` was not touched (Story 6.5's job).

**Files changed:**
- `crates/zanshin-jj/src/remotes.rs` — added `ProgressEvent`, `ProgressFn`, `progress_message`, `FetchCallback`, `git_fetch`; updated the module doc comment; added a `progress_message` phase-priority unit test and the pre-existing `local_sideband` no-op unit test.
- `crates/zanshin-jj/src/mutate.rs` — added `MutateError::RemoteNotFound`/`NetworkError`; extended `MutationResult`'s `new_change_ids`/`abandoned_change_ids` doc comments to name `git_fetch` as always-empty, linked via the public `` [`crate::Repo::git_fetch`] `` path (post-review fix).
- `crates/zanshin-jj/src/repo.rs` — added the public `Repo::git_fetch(&mut self, remote_name: &str, progress: &ProgressFn)` delegate, matching the existing per-noun delegation pattern used by `describe`/`new_change`/`edit`/`abandon`/`undo`; its doc comment notes the "fetches ALL branches/tags, no filter param" behavior (post-review addition). `clone_into`/`NoopCallback` were left untouched.
- `crates/zanshin-jj/src/lib.rs` — re-exported `ProgressEvent`/`ProgressFn` alongside `Remote`/`RemoteError`.
- `crates/zanshin-jj/tests/remotes_write.rs` — new integration-test file (epics.md AC's literal filename); a local bare-git-remote fixture (no network) with 6 tests covering every I/O-matrix row (happy path with progress + view-level bookmark/tag verification, fetch-with-nothing-new, remote absent, native backend, subprocess/network failure) plus one extra test for a reserved remote name exercising the generic `Backend` mapping arm. Post-review: the fixture now also tags its tip commit, and the happy-path test verifies the fetched bookmark AND tag are visible in jj's OWN view (via direct `jj_lib` view reads, since a freshly-fetched bookmark is untracked by this story's design and thus invisible to `zanshin_jj::Repo::list_bookmarks`), not only via a raw `git rev-parse` against the git object database.
- `crates/zanshin-jj/tests/api_stability.rs` — pinned `ProgressEvent`, the `ProgressFn` closure type, `Repo::git_fetch`'s exact signature, and the two new `MutateError` variants.
- `coverage-baseline.txt` — `crates/zanshin-jj/src/repo.rs` raised 92.72% → 93.06%; `remotes.rs` held at 100.00%.

**Review findings breakdown:** 5 patch (1 high, 1 medium, 3 low) — all applied and re-verified; 7 defer (0 high, 4 medium, 3 low) — logged in frontmatter `deferred` (hardcoded-empty `remote_auto_track_bookmarks` inherited from `clone_into`; several fallible steps funnel to the generic `Backend` error untested, low value to force; two tests coupled to jj-lib internal details, same class as Story 6.2's accepted pattern; no cancellation/timeout mechanism, jj-lib itself offers no hook; `import_refs()` can fail after `fetch()` already wrote git-level refs, an inherent jj-lib two-phase characteristic also present in `clone_into`; the post-commit working-copy read can fail after `tx.commit()` already persisted, same accepted class as Story 6.1/6.2's `sync_working_copy` gap; epics.md names auth failures as distinct from generic network failures but the code correctly treats every subprocess failure uniformly per the AC's own wording); 7 reject (0 high, 0 medium, 7 low) — a factually-incorrect claim about `GitFetch::new`'s error causes (verified against the jj-lib 0.42.0 source: `UnexpectedGitBackendError` is a unit struct with exactly one possible cause), `NetworkError` "conflating" failure classes (matches the AC's literal wording), a doc-comment FR-ID nitpick, `needs_progress()` having no opt-out, no `catch_unwind` around the caller's closure (architecturally out of pattern — panic-catching is centralized at the FFI boundary, not per mutation function, and a panicking closure unwinds exactly as safely as any other early-return error path), `import_refs()` discarding abandoned-commit stats (consistent with `MutationResult`'s own established side-effect-exclusion rule), and the public-delegate-plus-private-free-fn signature shape (confirmed by the Intent Alignment Auditor to match the codebase's established convention, not a deviation from intent).

**Follow-up review recommendation:** `true` — one `high`-severity patch was applied this pass (the jj-own-view verification gap), which alone triggers the threshold; the `3×medium + 1×low` score for the remaining patches was `3×1 + 1×3 = 6`, also ≥ 5.

**Verification performed:** Independently re-ran (not just trusted the implementation subagent's self-report) `cargo test -p zanshin-jj --test remotes_write` (6/6 pass), `cargo clippy -p zanshin-jj --all-targets -- -D warnings` (clean), `cargo test -p zanshin-jj` (full crate suite, all green) both before and after applying the 5 patches, `cargo fmt -p zanshin-jj -- --check` (clean), and two full `cargo make test` runs to convergence — the first (pre-patch) and second (post-patch) both exit 0, coverage held/raised (98.94% → 98.95%), `extern-coverage: OK`. Matrix Test Audit: all 5 I/O-matrix rows have a covering test that ran and passed, both before and after the patch round. Reviewed the actual diff content directly for the initial implementation (not just its self-description), and independently verified two specific review claims against the vendored jj-lib 0.42.0 source before triaging (`UnexpectedGitBackendError`'s single-cause shape; `default_remote_ref_state_for`'s bookmark-vs-tag default-tracking asymmetry, which is what made the patched view-level test assertion for bookmarks require reading `jj_lib`'s view directly rather than `zanshin_jj::Repo::list_bookmarks`).

**Residual risks:** the 7 deferred findings (see frontmatter) are real but pre-existing-pattern, jj-lib-inherent, or lower-urgency gaps — none are data-loss or crash risks. The most consequential is that `remote_auto_track_bookmarks` being hardcoded empty means every `git_fetch`-imported bookmark is untracked by default (invisible to `zanshin_jj::Repo::list_bookmarks` until a future `track`-bookmark verb or config-driven resolution lands), which a GUI built directly on `list_bookmarks()` alone would need to account for — inherited unchanged from `clone_into` (Epic 2), not introduced by this story. The recurring, inert `app/analysis_options.yaml` toolchain side effect (noted in Stories 6.1/6.2's own residual risks) reappeared on every `cargo make test` run in this story too and was reverted from the diff each time.
