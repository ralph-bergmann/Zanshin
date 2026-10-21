---
title: 'Cleanup after the 9.24/9.30/9.31 loop — fetch import stats, fetch error mapping, test git isolation'
type: 'chore'
created: '2026-10-21'
status: 'done'
baseline_revision: 'bebcc428703200159adbf5d947b350abada1d193'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
warnings:
  - multiple-goals
  - oversized
deferred:
  - summary: >-
      git push still lists the remotes before it parses --remote / git.push; the CLI builds the remote expression first.
    evidence: |-
      cmd_git_push (cli/src/commands/git/push.rs:294-301 @ v0.46.0) parses the patterns / get_default_push_remotes before get_all_remote_names; Zanshin's push::resolve_remotes lists first, so a non-Git backend with a malformed git.push or an unparsable --remote answers jj.not_a_git_repo where the CLI reports the config / pattern error. Pre-existing; the same gap item 4 fixed for fetch, outside this run's items.
    location: >-
      crates/zanshin-jj/src/push.rs resolve_remotes (~:784)
    severity: low
  - summary: >-
      Errors have no hint channel: fetch's RemoteName refusal carries the CLI's rename hint as the reason's last "Hint:" line, and GitRefExpansionError::Expression's CLI hint is dropped.
    evidence: |-
      MutateError::InvalidInput has only `reason`; the FFI error envelope is code + context. fetch_error appends "\nHint: Run `jj git remote rename` to give a different name." (this run); remotes.rs maps expand_fetch_refspecs errors through `invalid`, losing the CLI's "Specify patterns in `(positive | ...) & ~(negative | ...)` form." (command_error.rs:604-609 @ v0.46.0). The UI cannot show the hint apart from the message.
    location: >-
      crates/zanshin-jj/src/remotes.rs fetch_error, expand_fetch_refspecs call sites
    severity: low
  - summary: >-
      num_rewritten is only ever observed as 0 through a real fetch or import.
    evidence: |-
      git_fetch_parity::the_fetch_reports_the_remote_refs_it_changed and git_sync.rs (git_import) assert 0; the FFI and Dart tests feed a synthetic count. Taking the count from the wrong stats would pass every test. Needs a fixture where the import rewrites commits (e.g. an upstream force-push leaving descendants to rebase), shared by both verbs.
    location: >-
      crates/zanshin-jj/tests/it/git_fetch_parity.rs, crates/zanshin-jj/tests/it/git_sync.rs
    severity: low
---

<intent-contract>

## Intent

**Problem:** Seven ledger items left by the story loop 9.24/9.30/9.31 (deferred-work.md, "Surfaced in the follow-up review of Story 9.30" and "Surfaced in the loop 9.24/9.30/9.31 fix-up"): (1) a fetch does not report the remote bookmarks/tags it changed nor the rewritten-commit count; (2) `fetch_error` maps `RejectedUpdates` to `Backend` where the CLI says user error; (3) `fetch_error`'s `RemoteName` arm drops the CLI's rename hint (and falls to `Backend`); (4) a malformed `git.fetch` is read after the remote listing; (5) nothing pins that `--remote` / `--all-remotes` ignore a malformed `git.fetch` and that `Repo::git_fetch_remotes` refuses it; (6) never-run `panic!` arms in inline tests keep two files below 100% coverage; (7) integration tests spawn `git` before `pin_test_env()`, so the developer's `~/.gitconfig` (e.g. `commit.gpgsign`) leaks into fixtures.

**Approach:** Each item verified against the code and real. Fix all seven surgically: append three fields to `GitFetchOutcome` / `GitFetchResult` projected by the existing `git::project_import`; make `fetch_error` exhaustive with the CLI's classification; build the fetch's remote expression before listing remotes; add the missing tests; rewrite the panic helpers as `assert!(matches!(…))`; pin the test env inside the four git-spawning helpers that run before any pin.

## Boundaries & Constraints

**Always:** CLI v0.46.0 observable parity (`cli/src/command_error.rs:583-593`, `cli/src/commands/git/fetch.rs:142-172`, `cli/src/git_util.rs:228-266`); schema change is append-only at the end of `GitFetchResult`; run `cargo make codegen` and commit its output; the gate rule of this run — targeted checks only, no `cargo make test` / `test-full` / `coverage`.

**Never:** change push's remote-resolution order (same CLI-order gap exists there — a new finding, deferred); add an error-hint channel to `MutateError` / the FFI error envelope; touch Dart test suites' git spawning (isolated by the Makefile task env, see Design Notes); lower the coverage baseline.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| First fetch | origin has `main`, tag `v1` | `changed_bookmarks` = [`main`@origin New, tracked per auto-track], `changed_tags` = [`v1`@origin New], `num_rewritten` 0 | — |
| Re-fetch after upstream moves `main` | `main` advanced upstream | `changed_bookmarks` = [`main`@origin Updated]; no-change fetch → both lists empty | — |
| Git rejects a ref update | `GitFetchError::RejectedUpdates` | `MutateError::InvalidInput` "Failed to update refs: …" | no op written |
| Remote name jj cannot use | git remote named `git`, `--remote git` | `InvalidInput` with jj-lib's text + `\nHint: Run \`jj git remote rename\` to give a different name.` | no op written |
| Malformed `git.fetch` on native backend | `git.fetch = 1`, no Git backend | `MutateError::Config` (not `NotAGitRepo`) | — |
| Malformed `git.fetch` + `--remote origin` / `--all-remotes` | `git.fetch = 1` | fetch succeeds (`git.fetch` unread) | — |
| `git_fetch_remotes` with malformed `git.fetch` | `git.fetch = 1`, Git backend | `MutateError::Config` | — |

</intent-contract>

## Code Map

- `crates/zanshin-jj/src/remotes.rs` -- `GitFetchOutcome` (:271), `resolve_fetch_remotes` (:284, lists remotes at :290 before parsing), `fetch_error` (:447, `other => mutate::be`), `git_fetch` (:471; stats at :541, finish at :563 — `finish.repo` is the post-commit view), inline test `fetch_failures_map_to_their_mutate_errors` (:602).
- `crates/zanshin-jj/src/push.rs` -- `default_remotes` (:850, reads `defaults.configured` then the single/origin fallback), `matching_remotes` (:872), `resolve_remotes` (:784, push caller), `default_remote_names` (:905, query caller), `push_error` (:1703, the hint text to mirror).
- `crates/zanshin-jj/src/git.rs` -- `project_import(stats, repo, committed, mutation)` (:369) builds `GitImportResult` (changed refs from the post-import view, saturating `num_rewritten`, failed refs); reuse it with `committed = true` (a fetch always commits: `finish_transaction` has no `has_changes` check).
- `crates/zanshin-jj/src/repo.rs` -- `Repo::git_fetch` doc (:1290-1346): outcome fields + `# Errors`.
- `schemas/envelope.fbs` -- `table GitFetchResult` (:1029) + its doc block (:1020); `GitRefUpdate` (:1598) already exists.
- `crates/zanshin-ffi/src/repo.rs` -- `ok_git_fetch_result` (:1341), inline test (:1738).
- `crates/zanshin-ffi/src/git.rs` -- private `build_ref_updates` (:112) → `pub(crate)` for reuse.
- `packages/zanshin_core/lib/src/ffi/fetch.dart` -- `GitFetchResult` model (:141) + strict decoder (:184, absent vector = malformed); `packages/zanshin_core/lib/src/ffi/git.dart` private `_refUpdates` → shared internal; `packages/zanshin_core/test/ffi/fetch_test.dart` synthetic-buffer tests.
- `crates/zanshin-jj/src/remote_changes.rs` -- panic helpers `malformed` (:316) and `network_reason` (:474). `crates/zanshin-jj/src/drop_actions.rs` -- `reason` (:459, panic arm :463). Pattern to copy: commit 492220f's `config.rs` rewrite.
- Git-spawning tests unpinned at first spawn (audit of all 36 modules): `crates/zanshin-jj/tests/it/git_fetch_parity.rs` `git()` (:22; `Upstream::new` runs before `Fx::new` pins — 27 tests), `crates/zanshin-ffi/tests/it/push_ffi.rs` `git()` (:42; `remote()` before `pushable()` pins — 4 tests), `crates/zanshin-jj/tests/it/detect.rs` `git()` (:11), `crates/zanshin-jj/tests/it/find_repo_root.rs` `git()` (:11). Precedent: `crates/zanshin-jj/tests/it/clone_init.rs` pins inside its `git()` helper. All other modules pin first or set `GIT_CONFIG_GLOBAL` explicitly.

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/src/remotes.rs` -- add `changed_bookmarks: Vec<GitRefUpdate>`, `changed_tags: Vec<GitRefUpdate>`, `num_rewritten: u32` to `GitFetchOutcome`; in `git_fetch` build them via `crate::git::project_import(&stats, &finish.repo, true, mutation)` (failed refs from it too) -- item 1.
- same file -- `fetch_error` exhaustive: `NoSuchRemote` → `RemoteNotFound`; `RemoteName` → `InvalidInput` with `"{e}\nHint: Run \`jj git remote rename\` to give a different name."`; `RejectedUpdates` → `InvalidInput`; `Subprocess` as today -- items 2, 3.
- `crates/zanshin-jj/src/push.rs` + `remotes.rs` -- split `default_remotes`: new `configured_remotes(config, defaults) -> Result<Option<StringExpression>, MutateError>`; `default_remotes(all, configured, defaults, sink, hints)` becomes infallible. Push callers keep their order. `resolve_fetch_remotes` builds the expression (`All` / `Named` parse / `Default` → `configured_remotes`) BEFORE `get_all_remote_names`, then calls `default_remotes` -- item 4.
- `crates/zanshin-jj/src/repo.rs` -- `git_fetch` doc: new outcome fields; `InvalidInput` covers `RemoteName` (with hint) and `RejectedUpdates`; `Config` precedes `NotAGitRepo` -- items 1-4.
- `crates/zanshin-jj/src/remotes.rs` inline test -- `RejectedUpdates` → `InvalidInput`; `RemoteName` → `InvalidInput` ending in the hint -- items 2, 3.
- `crates/zanshin-jj/tests/it/git_fetch_parity.rs` -- pin in `git()`; tests: changed refs + count on first fetch and on an upstream move; malformed `git.fetch` ignored under `Named` / `All` and refused by `git_fetch_remotes`; native backend + malformed `git.fetch` → `Config`; remote named `git` → `InvalidInput` with hint -- items 1, 3, 4, 5, 7.
- `schemas/envelope.fbs` -- append `changed_bookmarks: [GitRefUpdate]; changed_tags: [GitRefUpdate]; num_rewritten: uint;` to `GitFetchResult`, doc them; `cargo make codegen` -- item 1.
- `crates/zanshin-ffi/src/repo.rs` + `git.rs` -- write the three fields (reuse `build_ref_updates`); extend the inline test -- item 1.
- `packages/zanshin_core/lib/src/ffi/fetch.dart`, `git.dart`, `test/ffi/fetch_test.dart` -- model fields `changedBookmarks`, `changedTags`, `numRewritten`; decode strictly like the other vectors; tests -- item 1.
- `crates/zanshin-jj/src/remote_changes.rs`, `drop_actions.rs` -- panic helpers → `assert!(matches!(…))` with guards; no unexecuted arm -- item 6.
- `crates/zanshin-ffi/tests/it/push_ffi.rs`, `crates/zanshin-jj/tests/it/detect.rs`, `find_repo_root.rs` -- `test_helpers::pin_test_env();` first in each `git()` helper -- item 7.

**Acceptance Criteria:**
- Given a Git-backed repo, when `zanshin_git_fetch` succeeds, then its `GitFetchResult` envelope (and Dart `GitFetchResult`) carries `changed_bookmarks`, `changed_tags`, `num_rewritten` equal to what `GitImportResult` would report for the same import.
- Given any git-spawning integration test, when it runs first in a fresh process under a `~/.gitconfig` with `commit.gpgsign = true`, then its git fixtures read no global config (env pinned before the first spawn).
- Given the inline tests of `remote_changes.rs` and `drop_actions.rs`, when they pass, then no source line in them is a never-executed `panic!` arm.

## Spec Change Log

## Review Triage Log

### 2026-10-21 — Review pass
- verdicts: 28 findings — high 0, medium 0, low 20, false 8, maybe-false 0
- findings:
  - `[low]` `[defer]` (blind) push still lists remotes before parsing `--remote` / `git.push` (CLI `push.rs:294-301` parses first) — pre-existing, the same order gap item 4 fixed for fetch; outside this run's seven items → deferred (new finding D1).
  - `[false]` `[reject]` (blind) `git_fetch_remotes` answers `Ok([])` on a non-Git backend with a malformed `git.fetch` while the fetch refuses `Config` — the query's documented contract is "empty on a non-Git backend" (schema `GitFetchRemotes`, `default_remote_names` doc); it is the Fetch button's enable rule, not a CLI verb, and the button is disabled either way.
  - `[low]` `[reject]` (blind) regeneration drops `GitImportResult_VT_CHANGED_BOOKMARKS/_CHANGED_TAGS/_NUM_REWRITTEN` from `zanshin_ffi.h` / `bindings.dart` — real, cbindgen's same-name associated-const collision (already dropping `GitImportResult_VT_MUTATION` / `_FAILED_REF_NAMES` at baseline); nothing in or out of the repo consumes these FlatBuffers vtable offsets (Dart reads through the flatc accessors), the fix is cbindgen configuration.
  - `[false]` `[reject]` (blind) ~25 other git helpers don't pin first — the audit of all 36 modules shows each of those tests reaches `pin_test_env` (fixture constructor, `own_process!`, or explicit `GIT_CONFIG_GLOBAL`) before its first spawn; only the four patched helpers spawned unpinned.
  - `[low]` `[reject]` (blind) `TEST_ENV` does not set `GIT_CONFIG_NOSYSTEM` — Ralph's decision for item 7 is the `pin_test_env` mechanism; this machine has no `/etc/gitconfig`, and a system config carrying `commit.gpgsign` is not a developer-machine case met in practice.
  - `[low]` `[defer]` (blind) the rename hint rides in-band as the reason's last `Hint:` line; the UI cannot separate it — deliberate (Design Notes): errors have no hint channel; adding one is an API decision → deferred (new finding D2).
  - `[low]` `[reject]` (blind) the hint literal appears three times (source + two tests) — tests pin the exact CLI text on purpose; a shared const would make the tests restate the implementation.
  - `[low]` `[patch]` (blind) `git::failed_ref_names` doc still says it is shared with `git_fetch` — fixed (doc / visibility).
  - `[low]` `[reject]` (blind) `project_abandoned` computed twice in `git_fetch` — one iteration over a short list; avoiding it needs restructuring `project_import`'s mutation parameter.
  - `[low]` `[patch]` (blind) the end-to-end `zanshin_git_fetch` FFI test asserts none of the new fields — assertions added in `repo_write_ffi.rs`.
  - `[low]` `[patch]` (blind) `the_fetch_reports_the_remote_refs_it_changed` has no `Deleted` case and derives `tracked` from the implementation — `Deleted` case added, literal tracking flags.
  - `[low]` `[patch]` (blind) rewritten test helpers print only the actual result — expected text added to each message.
  - `[low]` `[patch]` (blind) `--remote` patterns are now parsed before the backend check, undocumented and untested — native-backend `Named` test + doc sentences added.
  - `[low]` `[patch]` (blind) one edited FFI doc line runs to ~120 chars — rewrapped, codegen rerun.
  - `[low]` `[reject]` (blind) Dart fetch decoder tests miss absent `num_rewritten`, `Deleted`, tracked tag — the shared `decodeRefUpdatesInternal` kinds are covered by `test/ffi/git_test.dart`; an absent scalar is the FlatBuffers default 0 by construction.
  - `[false]` `[reject]` (edge) query vs fetch on non-Git with malformed `git.fetch` — same as the blind row above: documented contract.
  - `[low]` `[defer]` (edge) push order — same root cause as D1.
  - `[low]` `[reject]` (edge) a `GitRefUpdate` entry without name/remote decodes as empty — pre-existing in the shared decoder (`gitImport` too); Rust always writes both strings, so only a corrupt buffer reaches it.
  - `[low]` `[patch]` (edge) `Repo::git_fetch` doc says "Nothing is written" for `InvalidInput`, but earlier remotes' Git remote-tracking refs are already updated on a multi-remote fetch — reworded to "No operation is written."
  - `[low]` `[reject]` (edge) header constants deleted — same as the blind row above.
  - `[low]` `[defer]` (verification-gap) `num_rewritten` only ever observed as 0 through a real fetch — needs a fixture where the import rewrites commits; shared with `git_import` → deferred (new finding D3).
  - `[low]` `[patch]` (verification-gap) `--remote` pattern before listing unpinned — same patch as the blind row (native-backend `Named` test).
  - `[low]` `[patch]` (verification-gap, other) the bookmark `tracked` assertion adds little — same patch as the literal tracking flags.
  - `[false]` `[reject]` (intent) tracking flag read off the post-finish repo, not the CLI's in-transaction repo — the finish only rebases descendants and exports; remote-ref tracking state is unchanged between the two views.
  - `[false]` `[reject]` (intent) `fetch_error`'s doc says every variant is a CLI `user_error` while `Subprocess` stays `NetworkError` — the sentence describes the CLI's classification, which is accurate; Zanshin's finer `NetworkError` / `Cancelled` split for `Subprocess` predates this run.
  - `[false]` `[reject]` (intent) item 5 tests placed at the module end, not "next to" the existing test — same test module, same surface; placement is not behavior.
  - `[false]` `[reject]` (intent) `GIT_CONFIG_NOSYSTEM` not applied — same as the blind row: Ralph chose the `pin_test_env` mechanism.
  - `[false]` `[reject]` (intent) bookkeeping (Auto Run Result, commits, deferred mirroring) not on the reviewed surface — written at finalize, outside the code diff by design.

## Design Notes

- Item 3's hint: errors have no hint channel (`MutateError::InvalidInput { reason }`, FFI `code` + `context`); push carries hints only because its failure rides the outcome. Appending the CLI's own `Hint:` line to `reason` keeps the CLI's observable text without widening the error API; a structured error-hint channel would be a cross-cutting API decision (the same gap exists for `GitRefExpansionError::Expression`'s hint, `remotes.rs` `.map_err(invalid)`), noted as a new deferred finding.
- Item 4 for push: `cmd_git_push` (`push.rs:294-301` @ v0.46.0) has the same expression-first order; changing it is outside this run's items → deferred finding, push's order untouched.
- Item 7, Dart: the 8 Dart suites spawning git run only under `cargo make` tasks that set `GIT_CONFIG_GLOBAL=""` (Makefile.toml test-core/test-flutter/coverage), 5 of them refuse to start without the task env (`XDG_CONFIG_HOME` guard), and every Dart commit passes `--no-gpg-sign` — isolated by the same mechanism; no change.

## Verification

**Commands:**
- `cargo make codegen` -- expected: regenerated accessors committed, no further diff.
- `cargo test -p zanshin-jj --lib remotes:: remote_changes:: drop_actions:: push::` and `cargo test -p zanshin-jj --test it git_fetch_parity:: detect:: find_repo_root:: push:: remotes_write::` -- expected: pass.
- `cargo test -p zanshin-ffi --lib repo::` and `cargo test -p zanshin-ffi --test it push_ffi:: repo_write_ffi:: push_remotes_ffi::` -- expected: pass.
- `cargo clippy -p zanshin-jj -p zanshin-ffi --all-targets -- -D warnings`; `cargo fmt --all --check` -- expected: clean.
- `cargo test -p zanshin-parity --test oracle` -- expected: pass (fetch verb error mapping changed).
- In `packages/zanshin_core`: `flutter test test/ffi/fetch_test.dart test/ffi/git_test.dart`, `dart analyze`, `dart format --set-exit-if-changed .` -- expected: clean.

**Verification notes (this run, gate rule: targeted checks only — no `cargo make test` / `test-full` / `coverage`):**
- `cargo make codegen` -- ran after the last doc edit; a second run left no diff. Side effects committed with it: the header / `bindings.dart` picked up a committed-but-unregenerated Story 9.31 doc change of `zanshin_new`, and cbindgen's same-name collision now drops `GitImportResult_VT_CHANGED_BOOKMARKS` / `_CHANGED_TAGS` / `_NUM_REWRITTEN` (no consumer).
- `cargo test -p zanshin-jj --lib -- remotes:: remote_changes:: drop_actions:: push:: git::` -- 21 passed.
- `cargo test -p zanshin-jj --test it -- git_fetch_parity:: detect:: find_repo_root:: push:: remotes_write:: api_stability:: git_sync::` -- 129 passed.
- `cargo test -p zanshin-jj --test it -- --exact git_fetch_parity::default_fetches_origin_without_a_hint` and `cargo test -p zanshin-ffi --test it -- --exact push_ffi::a_real_push_returns_its_result_on_the_wire` -- 1 passed each, alone in a fresh process under a `~/.gitconfig` with `commit.gpgsign = true` (the leak scenario of item 7).
- `cargo test -p zanshin-ffi --lib repo::` -- 39 passed; `cargo test -p zanshin-ffi --test it -- push_ffi:: repo_write_ffi:: push_remotes_ffi::` -- 53 passed.
- `cargo clippy -p zanshin-jj -p zanshin-ffi --all-targets -- -D warnings` -- clean; `cargo fmt --all --check` -- clean.
- `cargo test -p zanshin-parity --test oracle` -- 191 passed.
- `packages/zanshin_core`: `dart test test/ffi/fetch_test.dart test/ffi/git_test.dart` -- 21 passed; `dart analyze` -- no issues; `dart format --set-exit-if-changed .` -- 0 changed. `app/`: `dart analyze` -- no issues.
- Coverage not measured (gate rule); the panic-arm rewrite of item 6 should let the loop's final gate raise `remote_changes.rs` / `drop_actions.rs`.

## Auto Run Result

Status: done (2026-10-21). Code commit: `46031eaf5e4c8a436bc22cb675be9f7f121fb263`.

**Items:**
1. Fetch import stats -- fixed (`46031eaf5e4c8a436bc22cb675be9f7f121fb263`): `GitFetchOutcome` / `GitFetchResult` / Dart `GitFetchResult` carry `changed_bookmarks`, `changed_tags`, `num_rewritten`, projected by `git::project_import`.
2. `RejectedUpdates` -> `InvalidInput` -- fixed (`46031eaf5e4c8a436bc22cb675be9f7f121fb263`); `fetch_error` is now exhaustive.
3. `RemoteName` hint -- fixed (`46031eaf5e4c8a436bc22cb675be9f7f121fb263`): `InvalidInput` (was `Backend`) with the CLI's hint as the reason's last `Hint:` line; a structured hint channel is a new deferred finding (Ralph's call if wanted).
4. `git.fetch` read order -- fixed (`46031eaf5e4c8a436bc22cb675be9f7f121fb263`): the fetch builds its remote expression (`git.fetch`, `--remote` patterns) before listing; push's same gap deferred as a new finding.
5. Malformed `git.fetch` under `--remote` / `--all-remotes` and `git_fetch_remotes` -- fixed (`46031eaf5e4c8a436bc22cb675be9f7f121fb263`): `git_fetch_parity::a_malformed_git_fetch_setting_is_read_only_without_remotes`.
6. Never-run `panic!` arms -- fixed (`46031eaf5e4c8a436bc22cb675be9f7f121fb263`): `remote_changes.rs` / `drop_actions.rs` helpers are `assert!(matches!(…))`.
7. Test git isolation -- fixed (`46031eaf5e4c8a436bc22cb675be9f7f121fb263`): audit of all 36 git-spawning test modules; the four whose `git()` ran before any pin (`git_fetch_parity`, `detect`, `find_repo_root`, `zanshin-ffi` `push_ffi`) now call `pin_test_env()` first; every other Rust module already pinned or set `GIT_CONFIG_GLOBAL`. Dart suites unchanged: isolated by the Makefile task env (`GIT_CONFIG_GLOBAL=""`), five refuse to start without it, all commits pass `--no-gpg-sign`.

**Files changed:** `crates/zanshin-jj/src/{remotes,push,repo,git,remote_changes,drop_actions}.rs` (verb + docs + test helpers); `crates/zanshin-jj/tests/it/{git_fetch_parity,detect,find_repo_root,api_stability}.rs` (tests, pins, exhaustive destructure); `schemas/envelope.fbs` + generated Rust/Dart accessors, `zanshin_ffi.h`, `bindings.dart`; `crates/zanshin-ffi/src/{repo,git}.rs` (encoder, docs); `crates/zanshin-ffi/tests/it/{push_ffi,repo_write_ffi}.rs`; `packages/zanshin_core/lib/src/ffi/{fetch,git}.dart`, `test/ffi/fetch_test.dart`; `docs/ffi-abi.md`.

**Review:** 28 findings (low 20, false 8). Patched 7 low entries (stale `failed_ref_names` doc, end-to-end FFI fetch assertions, `Deleted` case + literal tracking flags, assert messages with expectations, `--remote` pattern before the backend check test + docs, doc rewrap, "No operation is written"). Deferred 3 new low findings (push read order, error hint channel, `num_rewritten` > 0 never observed), mirrored into deferred-work.md. Rejected: see Review Triage Log (query contract, cbindgen VT constants, other git helpers already pinned, `GIT_CONFIG_NOSYSTEM`, duplicate literal, double `project_abandoned`, Dart decoder extra cases, corrupt-buffer decode, intent-audit notes).

**Follow-up review recommendation:** false — patched entries: high 0, medium 0, low 7.

**Residual risks:** coverage unmeasured until the loop's final gate; the in-band `Hint:` line is a new convention in a `MutateError` reason (deferred for Ralph).
