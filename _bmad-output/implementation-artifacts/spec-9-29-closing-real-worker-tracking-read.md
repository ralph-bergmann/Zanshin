---
title: 'Story 9.29 closing run — the app suite pins XDG_CONFIG_HOME; real-worker `read()` tests end diverged / ahead / behind'
type: 'chore'
created: '2026-10-19'
baseline_revision: 'c77196d650692a26ca19e156e7cb833d68b9a265'
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

**Problem:** The one item Story 9.29's run deferred, verified against the current code: no test drives `_WorkerProjectRepo.read()` (`app/lib/src/features/projects/worker_project_repos.dart`) through the real worker to `ProjectStatus.diverged`, `ahead` or `behind`; the only real-worker tracking test (`worker_project_repos_test.dart:374-405`) ends `clean`. A tracked non-`git` remote needs `remotes.<name>.auto-track-bookmarks` (fetch/clone spawn a git child the Dart VM reaps), and jj 0.46 writes repo-scope config into the secure store under `$XDG_CONFIG_HOME`, which `test-flutter` deliberately leaves unpinned because `flutter test` reads its own settings (`enable-windowing`) from `$XDG_CONFIG_HOME/flutter` (`Makefile.toml:138-140`).

**Approach:** Pin `XDG_CONFIG_HOME` for the app suite inside `test-flutter`'s script to the throwaway `target/test-xdg-config` the Dart suites already use, after seeding it with a fresh copy of the developer's flutter settings folder; then add three real-worker tests that set `remotes.origin.auto-track-bookmarks` at repo scope (zanshin_core's recipe), import a tracked `main@origin`, move one side and assert `read()` returns `diverged` / `ahead` / `behind` with label `main`.

## Boundaries & Constraints

**Always:**
- The pin is set in `test-flutter`'s bash script (an `export` before `flutter test`), NOT in the task's `env` table, so it cannot leak into later cargo-make tasks; the existing `env` pins stay as they are.
- Seed: copy `${XDG_CONFIG_HOME:-$HOME/.config}/flutter` (read before the pin) to `$ROOT/target/test-xdg-config/flutter`, replacing any previous copy; skip the copy when the source does not exist or already is the target; the rest of `target/test-xdg-config` (the jj secure store) is left untouched.
- Each new test fails fast (`fail(...)`) when `XDG_CONFIG_HOME` is unset, before any `configSet`, so a direct `flutter test` never writes into `~/.config/jj` (zanshin_core precedent, e.g. `test/worker/creation_test.dart:48`). The existing tests in the file keep running without the pin.
- Tracking comes only from `worker.configSet(const ConfigScopeTarget(ConfigScope.repo), 'remotes.origin.auto-track-bookmarks', 'glob:*', workspaceRoot: path)` followed by `git update-ref refs/remotes/origin/main …` (imported by the next verb's precondition); each test first asserts the tracked, synced start reads `ProjectReading(status: clean, bookmark: 'main')`.
- Moves use only shipped verbs and plain `git` ref plumbing (`Process.run('git', …)`): diverged = `handle.describe` of `main`'s change; ahead = local `main` moved to a child of its commit; behind = local `main` moved back to its parent. Each test ends `expect(await repo.read(), ProjectReading(status: <state>, bookmark: 'main'))`.
- Comments that say no app test writes jj config / XDG is unpinned are updated: `Makefile.toml:130-140`, `worker_project_repos_test.dart:3-5` and `:369-373`.

**Never:** no production code change (no Story 9.29 lib code, no test hook); no `jj` CLI in tests; no network, fetch or clone; no change to other test files, the Dart suites' tasks, `gate_plan.rs` or the coverage baseline; never write into the developer's real `~/.config` (flutter settings are copied FROM there, never written).

## I/O & Edge-Case Matrix

| Scenario | State | Expected `read()` | Error |
|---|---|---|---|
| Start | colocated repo, local `main` = A, tracked `main@origin` = A, @ empty on A | `clean`, bookmark `main` | — |
| Diverged | `describe` A → A' (same change id), `main@origin` = A | `diverged`, `main` | — |
| Ahead | local `main` = B (child of A), @ on B or above, `main@origin` = A | `ahead`, `main` | — |
| Behind | local `main` = A0 (parent of A), `main@origin` = A, `main` on `heads(::@ & bookmarks())` | `behind`, `main` | — |
| Unpinned | `XDG_CONFIG_HOME` unset | — | the new tests `fail` before any config write |

</intent-contract>

## Code Map

- `Makefile.toml:116-140` -- `[tasks.test-flutter]`: `script_runner = "bash"` script (`rm -f build/unit_test_assets/AssetManifest.bin; flutter test`, `cwd = "app"`) and the WHY comment `:130-140` ("NOT XDG_CONFIG_HOME … no app test calls a jj config verb"). `CARGO_MAKE_WORKSPACE_WORKING_DIRECTORY` is the repo root. Sibling pins: `test-core` env `:166`, coverage script `:707` (`XDG_CONFIG_HOME="$ROOT/target/test-xdg-config"`).
- `crates/xtask/src/tasks/gate_plan.rs:455-465` -- `GIT_ENV_OVERRIDES` already lists `XDG_CONFIG_HOME` (read-only evidence: env leaks between tasks are a known trap; the script-local export avoids it).
- `~/.config/flutter/settings` holds `"enable-windowing": true` (+ `tool_state`); the windowing-dependent app tests are `app/test/features/{home/home_page_test,window/app_windows_test,window/app_window_coordinator_test,bootstrap/boot_window_host_test,projects/project_window_title_test}.dart` -- the seed must keep them green.
- `app/test/features/projects/worker_project_repos_test.dart` -- real-worker group `:207-447`; `gitWithCommit` `:334-348` (git init -b main, one commit); the untracked/`@git` test `:369-405` (its comment `:369-373` changes; the test itself stays); header comment `:3-5`.
- `app/lib/src/features/projects/worker_project_repos.dart` / `project_repos.dart` -- `read()` → `statusFrom` → `trackingStatusOf` (Story 9.29; read-only here). Dot direction: remote row `behind > 0` → project `ahead`; remote row `ahead > 0` → project `behind`; both → `diverged`; only tracked non-`git` remotes of the local names on `heads(::@ & bookmarks())`.
- `packages/zanshin_core/test/worker/bookmarks_test.dart:96-150` -- the recipe to mirror: `worker.convert(root)` → `worker.configSet(ConfigScopeTarget(ConfigScope.repo), 'remotes.origin.auto-track-bookmarks', 'glob:*', workspaceRoot: root)` → `git update-ref refs/remotes/origin/feature HEAD` → `handle.bookmarks()` shows it tracked/synced → `handle.describe(changeId:, description:)` gives ahead 1 / behind 1.
- `packages/zanshin_core/lib/zanshin_core.dart:22-23` exports `ConfigScope`, `ConfigScopeTarget`; `ZanshinWorker.configSet` at `lib/src/worker/isolate.dart:1977`; `RepoHandle.describe` `handle.dart:347`, `newChange` `:381`.
- jj-lib 0.46 `git.rs:705-726` (read-only): an import of a TRACKED remote ref also merges the local bookmark (`merge_local_bookmark`), so moving `refs/remotes/origin/main` alone resyncs local `main` — ahead/behind must move the LOCAL side (`refs/heads/main`, imported as the local bookmark), not the remote. jj CLI v0.46.0 `bookmark/create.rs` refuses re-creating a deleted bookmark with tracked remotes, so delete+create is not a route.

## Tasks & Acceptance

**Execution:**
- `Makefile.toml` -- in `test-flutter`'s script, before `flutter test`: compute the pinned dir `$CARGO_MAKE_WORKSPACE_WORKING_DIRECTORY/target/test-xdg-config`, copy the flutter settings folder into it per the Always rules, `export XDG_CONFIG_HOME` to it; rewrite the WHY comment (the app suite now pins it like test-core/coverage, seeded with flutter's own settings so `enable-windowing` still applies; exported in the script so it cannot leak to later tasks) -- the pin item 1 needs.
- `app/test/features/projects/worker_project_repos_test.dart` -- add a helper that builds the tracked start (git repo with commits A0 → A on `main` via `gitWithCommit` + one more commit, `repos.convert`, the XDG guard, `configSet`, `update-ref refs/remotes/origin/main HEAD`, assert the start reads clean/`main`), and three tests: diverged (describe), ahead (`git commit-tree` a child B of A, `git update-ref refs/heads/main B`, then `newChange` on local `main`'s target from `handle.bookmarks()` so `main` is on @'s ancestry), behind (`git update-ref refs/heads/main <A0>`); each asserts the final `ProjectReading`; update the header comment and the comment at `:369-373` -- item 1's tests.

**Acceptance Criteria:**
- Given each matrix row, when `cargo make test` runs the app suite, then the new tests pass with exactly the expected `ProjectReading`, and the windowing-dependent app tests still pass.
- Given the gate run, when it finishes, then nothing new appears under `~/.config/jj` (the repo-scope writes land under `target/test-xdg-config/jj`) and `~/.config/flutter` is unchanged.
- Given the new tests run with `XDG_CONFIG_HOME` unset (temporary local check, not committed), then they fail with the "not pinned" message before any config write.
- Given `cargo make test` on the final tree (repo root, unpiped), then it exits 0; `git status --porcelain` is clean at the end and every commit carries the co-author trailer and `--no-gpg-sign`.

## Spec Change Log

- 2026-10-19 (implementation): two premises did not hold against the real worker. (1) Diverged cannot be a `describe` of `main`'s change: jj's default `trunk()` resolves to `main@origin`, so A is immutable and the rewrite is refused with `jj.immutable` (as by the CLI). Diverged now moves the local `main` to a sibling of A (`git commit-tree` with A's tree on A0). (2) Git HEAD is symbolic on `main` after `convert`, so moving `refs/heads/main` also moves HEAD; the import puts @ on the new target with the old files still on disk, which reads `dirty` for behind. All three moves therefore share one helper: `update-ref refs/heads/main <rev>`, then `newChange` on the local `main`'s target (checks out its tree, @ empty). Still only shipped verbs and git ref plumbing; the matrix's expected readings are unchanged.
- 2026-10-19 (implementation): the seed target was wrong. flutter_tools' `Config._configPath` (base/config.dart) reads `$XDG_CONFIG_HOME/<name>` when the variable is set — no `flutter/` segment — and `~/.config/flutter/<name>` only when it is unset; a copy at `target/test-xdg-config/flutter` left `enable-windowing` off and failed the windowing tests ("Windowing APIs are not enabled"). The script now copies flutter's two config files, `settings` and `tool_state`, from `${XDG_CONFIG_HOME:-$HOME/.config/flutter}` to the pinned dir's root (each replaced fresh, skipped when absent or when the source already is the pinned dir); `jj/` is untouched. The Makefile WHY comment names the real lookup.

## Review Triage Log

### 2026-10-19 — Review pass
- verdicts: 25 findings — high 0, medium 0, low 16, false 9, maybe-false 0
- findings:
  - `[low]` `[patch]` (blind 1) the Dart guard only checks that XDG_CONFIG_HOME is set, so a developer exporting it to their own config dir and running `flutter test` directly would write repo-scope config there — group G: the guard now requires a value ending in `/target/test-xdg-config` and fails otherwise (e38ee64); witnessed by a direct run with a scratch XDG dir: the three tests failed with the new message, the other 24 passed.
  - `[low]` `[patch]` (blind 2) `moveLocalMain`'s doc names `[commit]`, which is no parameter — group D: now `[rev]` (e38ee64).
  - `[low]` `[patch]` (blind 3) `env = {` became `env ={` in `test-flutter` — group E: restored (e38ee64).
  - `[low]` `[reject]` (blind 4) `gitAt` is a third way to run `git -C` in the file — the two existing closures are pre-existing, `gitAt` alone returns stdout (needed for `commit-tree`); hoisting the old ones refactors code this item does not need.
  - `[low]` `[reject]` (blind 5) per-repo secure-config entries accumulate under `target/test-xdg-config/jj` — the same as the zanshin_core suites already do there; a few small files under `target/`, removed by `cargo clean`; pruning adds script logic for no observed harm.
  - `[low]` `[reject]` (blind 6) when XDG_CONFIG_HOME already is the pinned dir the copy is skipped silently — only reachable when the caller pins the same dir by hand (`test-flutter` runs before the Dart suites' tasks in the gate, and their pin lives in other tasks' env); then the dir's own copy is used, as intended.
  - `[low]` `[reject]` (blind 7) the comment omits flutter's legacy `~/.flutter_<name>` precedence and `custom_devices.json` — with a legacy file flutter reads it exactly as before the pin (no harm); `flutter test` uses no custom devices; a comment completion for a path no developer here has (`~/.flutter_settings` absent).
  - `[low]` `[reject]` (blind 8) `moveLocalMain` force-unwraps the local target — a conflicted `main` cannot arise in these tests, and if it did the null-check error still fails the test loudly.
  - `[false]` `[reject]` (blind 9) no real-worker check that a tracked synced pair reads clean — `trackedMain` asserts exactly that (tracked, synced, `ProjectReading(clean, main)`) before every move.
  - `[low]` `[reject]` (blind 10) `commitOn` takes its tree from `refs/remotes/origin/main` without saying so — the doc says "A's tree" and that ref is A in every call; renaming the anchor changes nothing observable.
  - `[low]` `[patch]` (edge 1) guard passes for an empty or real config dir — group G, see blind 1.
  - `[low]` `[reject]` (edge 2) a differently spelled pinned path (trailing slash, symlink) makes the copy delete then miss the pinned files — only the pinned dir's own files under `target/` are touched (never the developer's), and the trigger needs a hand-set XDG_CONFIG_HOME naming the throwaway dir; canonicalising adds shell logic for an unseen case.
  - `[low]` `[reject]` (edge 3) unbounded growth of `target/test-xdg-config/jj` — same as blind 5.
  - `[low]` `[reject]` (edge 4) the behind/ahead moves leave the imported @ (A's files on the new target) as a visible sibling — inside a temp repo deleted at teardown; it is not on @'s ancestry, so the reading is unaffected (the test asserts the exact reading).
  - `[false]` `[reject]` (edge 5) the spec's Tasks still name `describe` and a `flutter/` seed — the deviations are recorded in the Spec Change Log; the fix is an edit of this build's spec.
  - `[low]` `[patch]` (verification-gap other 1) presence-only XDG guard — group G, see blind 1.
  - `[low]` `[patch]` (verification-gap other 2) stale `[commit]` doc reference — group D, see blind 2.
  - `[false]` `[reject]` (intent a) the diff implements R1a (pin + one real `read()` test per state); no defect claimed.
  - `[false]` `[reject]` (intent b) "behind" comes from moving the local side backward, not from the remote advancing — a tracked import merges the local bookmark forward with the remote (jj-lib `git.rs:719-722`), so a remote-only advance cannot leave a tracked pair behind; the view state `read()` sees is the one the item names.
  - `[false]` `[reject]` (intent c) diverged changed from `describe` to a sibling commit — `describe` of A is refused with `jj.immutable` (`trunk()` = `main@origin`), as by the CLI; the reading still ends `diverged`; recorded in the Spec Change Log.
  - `[false]` `[reject]` (intent d) the flutter seed has no direct test — the 36 windowing tests are its witness: they failed with "Windowing APIs are not enabled" under the wrong seed and pass under this one (743 app tests green).
  - `[low]` `[patch]` (intent e) guard weaker than "never write into ~/.config" — group G, see blind 1.
  - `[low]` `[patch]` (intent f) `env ={` whitespace edit — group E, see blind 3.
  - `[false]` `[reject]` (intent g) the pinned dir is now shared by three tasks — by design (one throwaway jj store, as the spec states); the jj entries are keyed by random repo ids, so suites cannot collide.
  - `[false]` `[reject]` (intent h) no `## Auto Run Result` yet — a mid-run state; finalize writes it.

## Design Notes

Why the local side moves: a tracked import merges the local bookmark (`merge_local_bookmark(name, old_remote, new_remote)`), so a moved `origin/main` with an unmoved local `main` resyncs it. Moving `refs/heads/main` instead is a git-side edit of the colocated local bookmark, which the next precondition imports (local follows `@git`), while `main@origin` stays put. Whether git `HEAD` is symbolic on `main` or detached after `convert` changes only where the new `@` lands; ahead adds an explicit `newChange` on B so `main` is on @'s ancestry either way, and behind holds either way (A0 is an ancestor of every candidate @).

Why seed rather than leave flutter unpinned: `flutter test` and the `flutter_tester` processes share one environment, and the cdylib reads `XDG_CONFIG_HOME` from it; a per-process split is not available, so the pinned dir carries a copy of flutter's settings.

## Verification

**Commands:**
- `flutter test test/features/projects/worker_project_repos_test.dart` (in `app/`, with `XDG_CONFIG_HOME` exported to a scratch dir seeded with `~/.config/flutter`, plus the Makefile's other test-flutter env) -- expected: all pass.
- `dart analyze` and `dart format --output=none --set-exit-if-changed .` (in `app/`) -- expected: clean.
- `cargo make test` (repo root, unpiped to a log, synchronous, long timeout; PATH with `~/development/sdks/flutter/bin` and `~/development/sdks/cargo/bin`, `CARGO_HOME=~/development/sdks/cargo`, `RUSTUP_HOME` unset) -- expected: exit 0 (Makefile.toml changed, so the gate plans every step).
- `find ~/.config/jj -newer <a marker touched before the gate>` -- expected: nothing from this run.

## Auto Run Result

Status: done (2026-10-19). Blocking condition: none. Code commits: `54d6049e17ea63290c34f5d2d15651e32e6ba09f` (fix), `e38ee649f3015f1faac05813b7eee573f4915694` (review patches); spec `777ca41` + change log `0424ae6`, plus the finalisation commit of this spec.

**Items handed to this closing run.**
1. **No app-level real-worker test reads a diverged, ahead or behind project through `_WorkerProjectRepo.read()` — fixed** (commit `54d6049e17ea63290c34f5d2d15651e32e6ba09f`, review patches `e38ee649f3015f1faac05813b7eee573f4915694`).
   - Verified first: the only real-worker tracking test ended `clean`; `test-flutter` left `XDG_CONFIG_HOME` unpinned, so a repo-scope `configSet` (the one way to a tracked remote under the Dart VM) would have written into the developer's own jj config.
   - Now: `test-flutter`'s script exports `XDG_CONFIG_HOME=target/test-xdg-config` (the Dart suites' throwaway dir; script-local, so it cannot leak into later tasks) after copying flutter's own `settings` and `tool_state` into that dir's root — flutter reads `$XDG_CONFIG_HOME/<name>` when set (flutter_tools `Config._configPath`), so `enable-windowing` still applies. Three real-worker tests build a tracked `main@origin` (repo-scope `remotes.origin.auto-track-bookmarks`), move the local `main` with git ref plumbing plus `newChange`, and assert `read()` = `diverged` / `ahead` / `behind` with label `main`; they refuse to run unless XDG points at the gate's dir.

**Summary.** One gate task and one test file changed; no production, Rust or Story 9.29 lib code touched.

**Files changed:**
- `Makefile.toml` — `test-flutter` seeds and exports the pinned `XDG_CONFIG_HOME`; WHY comment.
- `app/test/features/projects/worker_project_repos_test.dart` — `gitAt`, `trackedMain`, `moveLocalMain`, `commitOn`; the three tracking tests; header and comment updates.
- Tracking: this spec (no new deferrals, so `deferred-work.md` is unchanged).

**Deviations from the spec (Spec Change Log).** Diverged is a sibling commit, not a `describe` of A (A is immutable: `trunk()` = `main@origin`); every move ends in `newChange` on the local target (git HEAD follows `main` after `convert`, so the import moved @ with stale files on disk); the flutter seed goes to the pinned dir's root, not `flutter/`.

**Review findings.** 25 findings (high 0, medium 0, low 16, false 9, maybe-false 0).
- **Patched, 3 entries (all low):** the XDG guard requires the gate's dir (blind 1, edge 1, verification-gap other 1, intent e); the `[rev]` doc reference (blind 2, verification-gap other 2); `env = {` spacing (blind 3, intent f). Applied by the parent, not the implementation subagent (a resumed agent reports asynchronously, which this unattended run cannot wait for).
- **Deferred:** none.
- **Rejected:** a third git helper (pre-existing duplicates); secure-config entries accumulating under `target/` (×2, as the Dart suites already do); the silent skip when XDG already is the pinned dir; the comment's missing legacy-file precedence; the force-unwrap of the local target; `commitOn`'s implicit tree anchor; a differently spelled pinned path; the visible sibling left by a move (temp repo, off @'s ancestry).
- **False:** synced-pair read untested (asserted in `trackedMain`); stale spec Tasks (spec edit; logged); the reading/route/seed-witness/shared-dir/Auto Run Result intent notes (see the triage log).

**Follow-up review recommendation:** false — this first pass patched 3 entries, all low (patched counts: high 0, medium 0, low 3).

**Verification:**
- Implementation run: the file 27/27 with the pin; the three new tests fail with the "not pinned" message when XDG is unset (other 24 pass); `cargo make --allow-private test-flutter` 743 passed incl. the windowing tests; `dart analyze` / `dart format` clean; `cargo make test` exit 0 (full plan, Makefile.toml changed, 994 s; coverage held 99.46 %).
- Orchestrator, after the review patches: a direct run with a scratch XDG dir — the three tracking tests fail with "XDG_CONFIG_HOME is not pinned to target/test-xdg-config — run via cargo make", 24 pass. Every one of the gate plan's 27 steps run on the patched tree as its own `cargo make --allow-private <task>` (one `cargo make test` exceeds this session's 10-minute foreground limit; coverage alone took 676 s): `test-flutter` 743 passed, all analyze/format/deny/hygiene steps, the shell/settings/ui suites, `coverage` exit 0 (held at 99.46 %, every extern covered, baseline unchanged); then `gate-stamp`. `find ~/.config/jj ~/.config/flutter -newer <marker>` returned nothing.
- Matrix audit: Start — asserted in `trackedMain` before every move; Diverged / Ahead / Behind — the three new tests (ran, passed in the 743); Unpinned — the direct runs above (unset by the implementer, a wrong dir by the orchestrator).

**Residual risks:**
- The gate's run of this tree was step by step, not one `cargo make test` invocation (same tasks, same plan).
- `target/test-xdg-config/{settings,tool_state}` are overwritten from the developer's flutter config each app run; a developer with a legacy `~/.flutter_settings` keeps reading that file (as before).
