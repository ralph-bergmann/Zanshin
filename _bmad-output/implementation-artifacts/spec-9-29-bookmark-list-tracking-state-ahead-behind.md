---
title: 'Story 9.29 — Bookmark list tracking state (synced, tracked, ahead/behind, untracked and deleted rows; `bookmark list --all-remotes` parity) + the project dot''s ahead/behind/diverged'
type: 'feature'
created: '2026-10-19'
status: 'done'
baseline_revision: 'ae370222fa3868147258ac1a64ff4aa1a211ad45'
review_loop_iteration: 0
followup_review_recommended: true
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/planning-artifacts/epics.md#Story 9.29'
warnings: ['oversized']
deferred:
  - summary: >-
      No app-level real-worker test reads a diverged, ahead or behind project through _WorkerProjectRepo.read().
    evidence: |-
      A tracked non-git remote needs a fetch, a clone or remotes.<name>.auto-track-bookmarks. Fetch and clone spawn a git child the Dart VM reaps (zanshin_core mutate_test.dart gitFetch note), and jj 0.46 keeps repo-scope config in the secure store under $XDG_CONFIG_HOME, which the test-flutter task deliberately does not pin (Makefile.toml:138-140; flutter reads its own settings there). The composition is covered by the pure statusFrom/trackingStatusOf tests and the diverged facts by zanshin_core's real-cdylib test.
    location: >-
      app/test/features/projects/worker_project_repos_test.dart
    severity: medium
  - summary: >-
      A never-pushed tracked bookmark (the CLI's "(not created yet)" remote row) reads as a clean dot, not "ahead of remote".
    evidence: |-
      The dot follows design question (a)'s rule "from 9.29's distances"; the CLI prints no distances for an absent remote target (templates.toml format_commit_ref @ v0.46.0), so trackingStatusOf sees no distance and returns null. Whether an unpushed tracked bookmark should read "ahead of remote" is a product decision.
    location: >-
      app/lib/src/features/projects/project_repos.dart trackingStatusOf
    severity: low
---

<intent-contract>

## Intent

**Problem:** `Repo::list_bookmarks` / `zanshin_bookmarks` / `RepoHandle.bookmarks()` return only present local and tracked-remote rows with a target CHANGE id — no `synced`/`conflicted`/`tracked` facts, no distances, untracked remote rows and the CLI's `(deleted)` local row dropped — so after a local rewrite a bookmark and `<name>@origin` look "in sync" while `jj bookmark list --all-remotes` says ahead 1 / behind 1 (ledger I1, I2). The project dot (`ProjectStatus`) therefore cannot show ahead / behind / diverged (ledger I3).

**Approach:** Widen the shipped `Bookmark` in place (zanshin-jj → `.fbs` → FFI → Dart) to the CLI `CommitRef` facts and emit the CLI's `--all-remotes` row set, computing distances exactly as the CLI (`walk_revs` + `count_estimate`, synced fast path), locally, in the same `load_at_head` scope. Then let the app's project reading add `ahead`/`behind`/`diverged` to `ProjectStatus` from the distances of the local bookmarks on `heads(::@ & bookmarks())`.

## Boundaries & Constraints

**Always:**
- Reference = jj CLI @ v0.46.0: `cli/src/commit_ref_list.rs::collect_items` with the `--all-remotes` predicates (`include_local_only`, `include_synced_remotes`, `include_untracked_remotes` all true, every name/remote) and `cli/src/commit_templater.rs::CommitRef::{local,remote,remote_only,is_tracking_present,tracking_ahead_count,tracking_behind_count}` (`:1662-1811`), `format_commit_ref` in `cli/src/config/templates.toml:383-436`.
- Row set per name (from `view.bookmarks()`): a LOCAL row when the local target is present OR the name has ≥1 tracked remote ref (absent local → the `(deleted)` row, `target` absent); a REMOTE row for every tracked remote ref (synced or not, present or absent — absent = the CLI's `(not created yet)` row, `target` absent); a REMOTE row for every untracked remote ref. `@git` is a remote like any other — no filtering, no sort keys (9.19 / UI).
- Facts: every row `conflicted = !target.is_resolved()`; `target` = change id of the first `present_adds()`, absent when none. Local `synced` = every TRACKED remote ref's target == the local target (vacuously true with none). Remote: `tracked = remote_ref.is_tracked()`; `synced = tracked && remote target == local target`; untracked → `synced = false`.
- Distances only on tracked remote rows whose own target AND the local target are present (the template's `ref.present()` + `tracking_present()`): synced → `(0, Some(0))` without evaluating a revset; else `ahead = walk_revs(repo, remote_adds, local_adds).count_estimate()` (remote has, local lacks) and `behind = walk_revs(repo, local_adds, remote_adds).count_estimate()` (local has, remote lacks), carried as `{lower, upper?}` (`upper` null-for-absence). Present-adds only, as the CLI.
- Sort stays name, then Local, then remotes by remote name (existing order; CLI sort keys are 9.19's). Read-only, no operation; same precondition (`with_verb`) as today; a revset failure is `BookmarkError::Backend` → `jj.jj_lib_error` (no new code).
- Wire: presence pair for optional scalars (`has_upper`, flatc 25.12.19 rejects optional scalars for Dart); generated code regenerated with `flatc` 25.12.19 / the repo's codegen tasks and committed. Dart: `target` nullable; `synced`/`conflicted` on `Bookmark`; `tracked`/`ahead`/`behind` on `RemoteBookmark`.
- App dot precedence: stale (unchanged short-circuit), conflict, dirty, diverged, ahead, behind, clean; `missing` stays detect-side. Project-dot direction is the LOCAL side's: `ahead` ("ahead of remote") = some remote row's `behind.lower > 0`; `behind` ("behind remote") = some remote row's `ahead.lower > 0`; both (across the considered rows) → `diverged`. Considered rows: tracked remote rows of the LOCAL bookmark names on `heads(::@ & bookmarks())`, remote ≠ `git` (the CLI's `--tracked` default `--remote=~git`, `default_ignored_remote_name`).

**Never:** no network, no 9.24 poll; no filters / sort keys / template matrix (9.19); no track/untrack/set/forget (9.11); no removed/added conflict target lists; no repo-wide sum in the backend; no `syncing` state (11.8); no change to 10.14's panel or other UI beyond the dot's states and their catalogue use case; never regenerate fixtures; never shell to `jj` in production.

## I/O & Edge-Case Matrix

Rows built in-test with `test_helpers::{set_local_bookmark, set_remote_bookmark}` (tiny / medium fixtures).

| Scenario | State | Expected rows | Error |
|---|---|---|---|
| Synced | local `f`=C, `f@origin`=C tracked | Local{target C, synced, !conflicted}; Remote{tracked, synced, ahead (0,0), behind (0,0)} (no revset evaluated) | — |
| Remote ahead | local=P, remote=child of P | Remote ahead (1,1), behind (0,0); both rows `synced=false` | — |
| Local ahead | local=child, remote=P | Remote ahead (0,0), behind (1,1) | — |
| Diverged rewrite | local=C' (rewrite of C, same change id), remote=C | Both targets equal change id; Remote ahead (1,1), behind (1,1), `synced=false` | — |
| ≥10 apart (test build) | remote 12 commits ahead | ahead `{lower 10, upper null}` (jj-lib `testing` feature caps `count_estimate` in zanshin-jj tests) | — |
| Untracked remote | `r@origin` untracked, no local | one Remote{tracked false, synced false, no distances}; no Local row | — |
| Deleted local | no local `d`, `d@origin` tracked present | Local{target null, synced false}; Remote{tracked, no distances} | — |
| Not created yet | local `n`=C, `n@origin` tracked ABSENT | Local{synced false}; Remote{target null, tracked, no distances} | — |
| Conflicted local | local `c`=[A,B] | Local{conflicted, target = A's change id} | — |
| Colocated `@git` | colocated repo + `bookmark_create` | Local + Remote{remote `git`, tracked, synced, (0,0)} | — |
| Broken head | unloadable head | — | `BookmarkError::Backend` / `jj.jj_lib_error` |

</intent-contract>

## Code Map

- `crates/zanshin-jj/src/bookmarks.rs` -- `Bookmark`/`BookmarkKind` (`:19-43`, `Ord` on kind is the sort key today), `list_bookmarks` (`:74-118`; local loop skips absent; remote loop skips absent + untracked at `:102`). Rewrite over `view.bookmarks()` (jj-lib `view.rs:92`, `LocalRemoteRefTarget { local_target, remote_refs }`); `jj_lib::revset::walk_revs` (`revset.rs:2705`) + `Revset::count_estimate` (`revset.rs:3542`; capped (10,None) under jj-lib `testing`, `default_index/revset_engine.rs:195`). Inline unit test `:127` (broken head) stays.
- `crates/zanshin-jj/src/repo.rs:460-473` -- `Repo::list_bookmarks` doc (now "the `--all-remotes` row set"); signature unchanged.
- `crates/zanshin-jj/src/lib.rs:63` -- re-export new public types (e.g. `RefDistance`).
- `crates/zanshin-jj/tests/bookmarks.rs` -- integration tests; `bookmarks_skips_absent_and_untracked_remotes` (`:201`) and setup at `:93-160` change meaning; add the matrix rows. `tests/bookmark_ops.rs:232,538` doc/asserts mention the old filter (`delete_leaves_a_tracked_remote_bookmark_in_place` now sees the `(deleted)` Local row too); `tests/api_stability.rs:55,1241` type/fn pins; other `list_bookmarks` callers (`convert.rs:168,377,1188`, `git_sync.rs:156`, `remotes_write.rs:285`, `mutate.rs:385`, `snapshot_precondition.rs:302`) must still compile/pass.
- `crates/test-helpers/src/lib.rs:531-582` -- `set_local_bookmark` (empty slice deletes), `set_remote_bookmark(root, name, remote, target_hex, tracked)` (always present target), `describe_commit` (`:385`), `add_commit_off_root`. jj-lib `View::set_remote_bookmark` keeps an absent tracked ref only while the local is present — the "not created yet" row needs a raw tx in the test (absent target + Tracked, local present).
- `schemas/envelope.fbs:767-783` -- `BookmarkKind` / `Bookmark` / `Bookmarks`; widen in place (presence-pair convention, see `:324-344`).
- `crates/zanshin-ffi/src/bookmarks.rs` -- `bookmarks_to_envelope` (`:36-60`) + inline tests; `crates/zanshin-ffi/tests/bookmarks_ffi.rs` real-path test.
- Generated: Rust `crates/zanshin-ffi/src/*_generated.rs` and Dart `packages/zanshin_core/lib/src/ffi/envelope_zanshin.ffi_generated.dart` via the repo's flatc task (find it in `Makefile.toml`); no `extern "C"` signature change → no cbindgen/ffigen diff expected.
- `packages/zanshin_core/lib/src/ffi/bookmarks.dart` -- models + `_mapBookmark`/`_mapKind` (`:26-111`); `packages/zanshin_core/lib/zanshin_core.dart` -- export `Bookmark, BookmarkKind, LocalBookmark, RemoteBookmark, RefDistance` (app now consumes them). Tests: `test/ffi/bookmarks_test.dart` (synthetic decode), `test/worker/bookmarks_test.dart` (real cdylib), `test/worker/bookmark_ops_test.dart`, `test/ffi/warning_test.dart`, `test/worker/warnings_test.dart`.
- `docs/ffi-abi.md:496` (row + payload notes), `docs/rust-error-codes.md:45` (`jj.jj_lib_error` "Also emitted — Story 9.29" clause).
- `packages/zanshin_settings/lib/src/model/projects_settings.dart:89-107` -- `ProjectStatus` (+ doc `:91`); regenerate `projects_settings.g.dart` with `dart run build_runner build --delete-conflicting-outputs` in that package (build.yaml header keeps `// dart format width=80`); `test/model/projects_settings_test.dart:64` uses `'ahead'` as the UNKNOWN value — switch it to `'syncing'`.
- `app/lib/src/features/projects/project_status_style.dart:9-27` -- add `projAhead`/`projBehind`/`projDiverged` (`packages/zanshin_ui/lib/src/design/zs_colors.dart:105-113`, already match DS `tokens/colors.css:65,101`) and DS labels 'ahead of remote' / 'behind remote' / 'diverged' (`design_system/components/content/ProjectRow.jsx:5-15`).
- `app/lib/src/features/projects/project_repos.dart:84-98` -- `statusOf`, `bookmarkLabel`; `worker_project_repos.dart:88-112` -- `read()` (show @ → topology `heads(::@ & bookmarks())` → add `handle.bookmarks()`).
- Tests: `app/test/features/projects/project_status_style_test.dart`, `worker_project_repos_test.dart` (real worker; `Process.run('git', …)` precedent at `:180`; clone via `ZanshinWorker.cloneRepo`, `isolate.dart:423`; `RepoHandle.describe`, `handle.dart:346`). Catalogue: `app/widgetbook/folders/projects.dart:148-162` (`_CapsuleStates`).

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/src/bookmarks.rs` -- widen `Bookmark` (`target: Option<ChangeId>`, `conflicted`, `synced`) and `BookmarkKind::Remote { remote_name, tracked, ahead: Option<RefDistance>, behind: Option<RefDistance> }` (or an equivalent shape keeping remote-only facts on the remote kind), add `RefDistance { lower: u64, upper: Option<u64> }`; rebuild `list_bookmarks` over `view.bookmarks()` per the Always rules; explicit sort key -- the CLI row set + facts.
- `crates/zanshin-jj/src/repo.rs`, `src/lib.rs` -- docs + re-exports.
- `crates/zanshin-jj/tests/bookmarks.rs` -- one test per I/O matrix row (asserting all facts), update the old skip test and setup; fix `bookmark_ops.rs`, `api_stability.rs` and any other caller -- the matrix is the acceptance oracle.
- `schemas/envelope.fbs` -- `table RefDistance { lower: ulong; upper: ulong; has_upper: bool; }`; `Bookmark` gains `conflicted: bool; synced: bool; tracked: bool; ahead: RefDistance; behind: RefDistance;` (`target` absent = null); update the comments (no "tracked-remote only"); regenerate both sides.
- `crates/zanshin-ffi/src/bookmarks.rs` + `tests/bookmarks_ffi.rs` -- encode every field (remote-only fields only on Remote rows; distances only when present); unit tests round-trip each field incl. absent target, `has_upper=false`.
- `packages/zanshin_core/lib/src/ffi/bookmarks.dart`, `lib/zanshin_core.dart` -- nullable `target`, `synced`/`conflicted`, `RemoteBookmark.tracked/ahead/behind`, `RefDistance {lower, upper?}` (`has_upper=false` → null); keep the Remote-without-name corruption rejection; export the types.
- `packages/zanshin_core/test/ffi/bookmarks_test.dart`, `test/worker/bookmarks_test.dart` (+ other compile fallout) -- a synthetic decode test per new field; a real-cdylib assertion of the new facts on a real repo (e.g. created bookmark: synced, not conflicted, target present).
- `docs/ffi-abi.md`, `docs/rust-error-codes.md` -- payload + clause.
- `packages/zanshin_settings/...` -- add `ahead`, `behind`, `diverged` to `ProjectStatus` (doc: syncing is 11.8's), regenerate, retarget the unknown-value test.
- `app/lib/src/features/projects/project_status_style.dart`, `project_repos.dart`, `worker_project_repos.dart` -- style + labels; a pure sync derivation (local names from `heads.refs`, `Bookmark`s → diverged/ahead/behind/null) folded into `statusOf` after dirty; `read()` calls `handle.bookmarks()` (log its warnings like the others).
- `app/test/features/projects/*` -- style test per new state; pure-function tests for every combination (none / ahead / behind / both on one row / split across two rows / remote `git` ignored / untracked ignored / remote-only names ignored / dirty beats diverged); a real-worker test: clone a local bare git repo (`git` CLI) with a `main` branch, `describe` the `main` commit → reading `diverged`, label `main`.
- `app/widgetbook/folders/projects.dart` (+ `demo_projects_fakes.dart` if it lists states) -- add the three states to the capsule States use case.

**Acceptance Criteria:**
- Given any matrix state, when `RepoHandle.bookmarks()` is called through the real worker and cdylib, then the decoded rows carry exactly the facts the zanshin-jj matrix asserts (row set, `target` null-for-absence, flags, distances).
- Given the diverged-rewrite state, when `bookmarks()` is read, then the local row and `f@origin` share a target change id yet report `synced=false`, ahead 1 / behind 1 (I1 closed).
- Given an open project whose `heads(::@ & bookmarks())` bookmark is diverged from its tracked non-`git` remote and @ is empty and conflict-free, when the project is read, then the capsule shows `ProjectStatus.diverged` with DS colour `projDiverged` and label 'diverged'; with only local commits → `ahead` ('ahead of remote'); only remote commits → `behind` ('behind remote').
- Given a settings file written with `"status": "syncing"`, when loaded, then that entry's status is null and the rest loads.
- `cargo make test` is green, coverage ratchet incl. (new code ≥ baseline; commit a raised `coverage-baseline.txt`).

## Spec Change Log

## Review Triage Log

### 2026-10-19 — Review pass
- verdicts: 28 findings — high 0, medium 6, low 18, false 4, maybe-false 0
- findings:
  - `[medium]` `[patch]` (blind) No end-to-end check that read() reaches diverged/ahead/behind; the spec's real-worker diverged test was replaced by a clean one — group A: the composition moved into the pure `statusFrom` (project_repos.dart), read() uses it, tests feed diverged/ahead/behind/clean rows and prove conflict/dirty never call bookmarks(); the real-worker e2e itself is infeasible in the app suite (repo config lives under the unpinned $XDG_CONFIG_HOME in jj 0.46; fetch/clone reaped) → deferred item 1.
  - `[low]` `[reject]` (blind) Spec not updated for the deviations — the fix edits this build's spec; the deviations are recorded under Auto Run Result instead.
  - `[low]` `[reject]` (blind) Regenerated zanshin_ffi.h / bindings.dart drop TopologyRef_VT_SYNCED, TopologyRef_VT_CONFLICTED, GitRefUpdate_VT_TRACKED — group B: real (cbindgen collapses same-named associated consts), but nothing in the repo uses them (Dart reads via flatc accessors) and the fix is a cbindgen config change; noted as a residual risk.
  - `[low]` `[reject]` (blind) Row order interleaves tracked/untracked remotes unlike collect_items — the epic's non-goals put sort keys/order in 9.19 or the UI; the documented order (name, Local, remote name) is the shipped one and is stated explicitly in docs/ffi-abi.md.
  - `[low]` `[patch]` (blind) "conflicted = more than one added commit" is wrong (adds [A, absent] is unresolved with one present add) — reworded to "the target is an unresolved conflict (`!RefTarget::is_resolved`)" in bookmarks.rs, envelope.fbs (+ codegen), bookmarks.dart, docs/ffi-abi.md.
  - `[low]` `[defer]` (blind) The dot has no decided behaviour for a never-pushed tracked bookmark — group C: it follows the intent's "from 9.29's distances" (none → clean); whether it should read "ahead of remote" is Ralph's call → deferred item 2. The `(deleted)` half does not apply: a deleted local is never on heads(::@ & bookmarks()).
  - `[low]` `[patch]` (blind) Every read evaluates repo-wide distance revsets on every op — group D: bookmarks() is now called only when @ is neither conflicted nor dirty (statusFrom); the walks are index-only and run only for unsynced tracked pairs.
  - `[low]` `[reject]` (blind) read() mixes three head loads, so the dot can combine facts from two operations — pre-existing pattern (show + topology already were separate); transient, the next op-heads event re-reads; a fix needs an op-pinned read API.
  - `[medium]` `[patch]` (blind) A bookmarks() failure discards an already computed conflict/dirty — group D: with statusFrom, bookmarks() runs only when the dot would otherwise be clean, so conflict/dirty survive; a failure then keeps the last state (ProjectSession._read), as a topology failure does.
  - `[low]` `[patch]` (blind) demo_projects_fakes.dart lists states but got none of the new ones; Marionette check not shown — api-server → ahead, dotfiles → behind, new `billing` entry diverged (keeps a clean demo); the Marionette/Playwright check of the capsule States was done by the implementer (night + paper, against the DS window card and tokens).
  - `[low]` `[patch]` (blind) Missing matrix case: local with mixed tracked remotes; fast path "no revset evaluated" unasserted — added `a_local_with_one_synced_and_one_unsynced_tracked_remote_is_unsynced`; the fast path is unobservable from outside (equal results), not asserted.
  - `[low]` `[reject]` (blind) Dart RefDistance lacks ==/hashCode/toString — matches the sibling Bookmark/BookmarkKind classes; no consumer compares them.
  - `[low]` `[reject]` (blind) 'git' hard-coded in the app — jj's REMOTE_NAME_FOR_LOCAL_GIT_REPO is fixed and a non-Git backend has no such remote; a pass-through would add surface for no observed harm.
  - `[medium]` `[patch]` (edge) bookmarks() error rethrown from read() loses conflict/dirty — group D, see above.
  - `[low]` `[patch]` (edge) Unbounded count_estimate walks on every read — group D, see above.
  - `[low]` `[defer]` (edge) Never-pushed tracked bookmark shows a clean dot — group C, deferred item 2.
  - `[low]` `[reject]` (edge) Concurrent operation between the three calls mixes operations — same as the blind finding above.
  - `[low]` `[reject]` (edge) Header/bindings lost three constants — group B.
  - `[medium]` `[patch]` (edge) AC 3's capsule reading checked only by pure tests — group A.
  - `[medium]` `[patch]` (verification-gap) read() never reaches a non-clean tracking state in any test — group A; its suggested repo-config route writes into ~/.config/jj under the app suite (jj 0.46 secure config, Makefile.toml:138-140), hence the seam + deferred item 1.
  - `[low]` `[reject]` (verification-gap other) Dropped vtable constants — group B.
  - `[false]` `[reject]` (intent) Absent tracked remote refs are emitted although the epic says "stay skipped" — v0.44.0 and v0.46.0 `format_commit_ref` both print `@origin (not created yet)` under --all-remotes and collect_items never filters on presence; CLI parity at the pin is binding (Design Notes).
  - `[false]` `[reject]` (intent) Distances also require the remote target present — the CLI never prints a distance for an absent remote target (`if(ref.present(), …)`); nothing observable differs from the CLI.
  - `[false]` `[reject]` (intent) The dot's derivation policy is not in the intent — it is design question (a)'s recommendation (epics.md 11.5: distances of the bookmarks on @'s closest bookmarked ancestor), with git excluded as the CLI's --tracked default; recorded in the spec's Boundaries.
  - `[medium]` `[patch]` (intent) No real read() of a non-clean tracking state — group A.
  - `[low]` `[patch]` (intent) Deleted/not-created/conflicted rows never cross the Dart real-worker path — the zanshin_core rewrite test now deletes the local bookmark and asserts the `(deleted)` row (target null, unsynced) and the tracked origin row without distances; the absent-target and flag decode is covered field by field by the synthetic decode tests.
  - `[false]` `[reject]` (intent) Auto Run Result / ledger outcomes missing — written at finalize, below.
  - `[low]` `[reject]` (intent) Collateral constant loss in generated header — group B.

## Design Notes

- The epic text says "Absent remote refs stay skipped as today" (written against v0.44.0). Both v0.44.0 and v0.46.0 `format_commit_ref` print a tracked ABSENT remote ref as `@origin (not created yet)` under `--all-remotes` (`collect_items` never filters on presence), and jj-lib stores such a ref only while the local exists (the `auto-track-created-bookmarks` state). The project's binding rule is CLI parity at v0.46.0, so these rows ARE emitted (`target` null). An UNTRACKED absent remote ref cannot exist (`View::set_remote_bookmark` removes it).
- Direction trap: on the wire `ahead`/`behind` are the REMOTE row's (CLI); the project dot speaks for the local side, so "ahead of remote" = remote row's `behind`.
- `count_estimate` is exact in the shipped cdylib; only zanshin-jj's test build (jj-lib `testing`) caps at 10 → the `upper: None` path is testable there.

## Verification

**Commands:**
- `cargo make test` -- expected: green (clippy pedantic, fmt, doctests, Dart analyze/format/tests, deny, coverage ratchet).
- `dart run build_runner build --delete-conflicting-outputs` (in `packages/zanshin_settings`) -- expected: only `projects_settings.g.dart`'s enum map changes.

**Manual checks:**
- Per project-context.md § UI tooling: run the catalogue, open Projects > Project capsule > States via Marionette (`zanshinCatalogue.open`) in night and paper, screenshot, and compare the three new dots with the DS ProjectRow / capsule cards.

## Auto Run Result

Status: done. Code commit `b5c3b95b627d3d0e1c1fdf4644ccd612543e3892` (baseline `ae370222fa3868147258ac1a64ff4aa1a211ad45`).

**Summary.** `Repo::list_bookmarks` / `zanshin_bookmarks` / `RepoHandle.bookmarks()` now return the `jj bookmark list --all-remotes` row set at v0.46.0 — present and `(deleted)` local rows, tracked remote rows (synced or not, incl. `(not created yet)`), untracked remote rows, `@git` like any remote — each with `target` (null-for-absence), `conflicted`, `synced`, and on remote rows `tracked` plus `ahead`/`behind` `RefDistance {lower, upper?}` computed as the CLI does (`walk_revs` + `count_estimate`, synced fast path), locally, in the listing's `load_at_head` scope. The app's open-project reading adds `ProjectStatus.ahead/behind/diverged` (DS colours and labels) from the tracked non-`git` remotes of the local bookmarks on `heads(::@ & bookmarks())`, only when @ is conflict-free and clean.

**Ledger items.**
- **I1** — fixed (`b5c3b95b627d3d0e1c1fdf4644ccd612543e3892`): every row carries `synced`, and remote rows the CLI's distances, so a local rewrite (same change id, different commits) reads `synced=false`, ahead 1 / behind 1 — asserted in zanshin-jj (`a_local_rewrite_is_ahead_one_and_behind_one_under_the_same_change_id`) and through the real cdylib in zanshin_core (`a_local_rewrite_reads_ahead_one_behind_one_under_the_same_change_id`). The graph rows' `CommitRef.synced` (4.8) is unchanged by design.
- **I2** — fixed (`b5c3b95b627d3d0e1c1fdf4644ccd612543e3892`), Story 9.29's part: untracked remote rows (e.g. `release/1.5.x@origin`), the `(deleted)` row and the synced/conflicted flags cross the bridge, and `Bookmark`/`BookmarkKind`/`LocalBookmark`/`RemoteBookmark`/`RefDistance` are exported from `zanshin_core`. 10.14's panel is not part of this run.
- **I3** — fixed (`b5c3b95b627d3d0e1c1fdf4644ccd612543e3892`), Story 9.29's part: `ProjectStatus` gains `ahead`, `behind`, `diverged`, `ProjectStatusStyle` maps them to `projAhead/projBehind/projDiverged` and the DS labels, and the open project's read derives them. `syncing` stays Story 11.8's.

**Deviations from the epic text / spec (for Ralph).**
- Tracked remote refs with an ABSENT target (the CLI's `@origin (not created yet)`) ARE emitted, against the epic's "Absent remote refs stay skipped as today": both v0.44.0 and v0.46.0 print them under `--all-remotes` (Design Notes).
- The spec's app real-worker diverged test was not built (jj 0.46 repo config lives under the unpinned `$XDG_CONFIG_HOME`; fetch/clone are reaped under the Dart VM); replaced by the pure `statusFrom` seam tests plus zanshin_core's real-cdylib rewrite test → deferred item 1.
- `cargo make codegen` also changed `zanshin_ffi.h` / `bindings.dart` (the spec expected no diff): new `Bookmark_VT_*` constants, and cbindgen dropped `TopologyRef_VT_SYNCED`, `TopologyRef_VT_CONFLICTED`, `GitRefUpdate_VT_TRACKED` (same-named associated consts collide). Nothing uses them.

**Files changed.**
- `crates/zanshin-jj/src/bookmarks.rs` — the --all-remotes row set, facts and distances; `RefDistance`; explicit sort key.
- `crates/zanshin-jj/src/{lib.rs,repo.rs,view.rs}` — re-export, docs, a stale comment.
- `crates/zanshin-jj/tests/{bookmarks.rs,bookmark_ops.rs,api_stability.rs}` — one test per matrix row plus mixed tracked remotes; updated callers.
- `schemas/envelope.fbs` + generated Rust/Dart/C header/ffigen bindings — `RefDistance`, widened `Bookmark`.
- `crates/zanshin-ffi/src/bookmarks.rs`, `tests/bookmarks_ffi.rs` — encoder for every field; unit + real-path tests.
- `packages/zanshin_core/lib/src/ffi/bookmarks.dart`, `lib/zanshin_core.dart`, `lib/src/worker/{handle,isolate}.dart` — widened models, decoder, exports, docs; tests in `test/ffi/bookmarks_test.dart`, `test/worker/{bookmarks,warnings}_test.dart`.
- `packages/zanshin_settings/lib/src/model/projects_settings{.dart,.g.dart}`, its test — the three states; the unknown-value fixture now `syncing`.
- `app/lib/src/features/projects/{project_repos,project_status_style,worker_project_repos}.dart` — `statusFrom`, `trackingStatusOf`, style and labels, read wiring; tests in `app/test/features/projects/`.
- `app/widgetbook/folders/projects.dart`, `app/widgetbook/demo_projects_fakes.dart` — the three states in the capsule States use case and the demo tree.
- `docs/ffi-abi.md`, `docs/rust-error-codes.md` — `Bookmarks` payload section, `jj.jj_lib_error` clause.
- `coverage-baseline.txt` — `crates/zanshin-jj/src/bookmarks.rs` 94.87 → 100.00.

**Review.** 28 findings (high 0, medium 6, low 18, false 4). Patched entries: 2 medium (group A: the read composition seam + its tests; group D: bookmarks() only when @ is clean, so conflict/dirty survive a tracking-read failure and no walks run otherwise) and 4 low (`conflicted` wording, demo states, mixed-remote test, `(deleted)` row through the real worker). Deferred: 2 (the app real-worker e2e test, medium; the never-pushed bookmark's dot, low — both mirrored in deferred-work.md). Rejected: the spec-edit finding, the cbindgen constant loss (×4, low, unused), the row-order finding (sort is 9.19's/the UI's per the epic), mixed-operation reads (×2, pre-existing, transient), `RefDistance` equality, the hard-coded `git` remote, and four `false` intent findings (see the triage log).

**Follow-up review recommendation: true** (first pass, 2 medium entries patched). Named unverified risk: the open project's real read of a diverged/ahead/behind state is not exercised end to end (only the pure `statusFrom` seam and the zanshin_core bookmark facts are), and the demo-tree states added in review were not re-checked visually in the Projects window.

**Verification.** `cargo make test` green before and after the review patches (exit 0; coverage held at 99.46 %, every extern covered; 779.8 s post-patch run from the main session). Matrix test audit: each I/O-matrix row has a passing test in `crates/zanshin-jj/tests/bookmarks.rs` (synced, remote/local ahead, rewrite, ≥10 → `upper: None`, untracked, deleted, not created yet, conflicted, colocated `@git`, corrupt repo + the inline broken-head test). `build_runner` changed only the enum map. Visual: the implementer ran the catalogue's Projects > Project capsule > States in night and paper via Marionette and compared the dots with the DS tokens/labels (the DS card has no diverged row; checked against the token).

**Residual risks.** Each `read()` of a clean project now adds a third head load (`bookmarks()`), and its distance walks scale with the distance of unsynced tracked pairs (uncapped in the shipped cdylib). The C header lost three unused vtable constants to a cbindgen name collision.
