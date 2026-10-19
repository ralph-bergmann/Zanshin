---
title: 'Story 9.29 closing run — the app suite pins XDG_CONFIG_HOME; real-worker `read()` tests end diverged / ahead / behind'
type: 'chore'
created: '2026-10-19'
baseline_revision: 'c77196d650692a26ca19e156e7cb833d68b9a265'
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

## Design Notes

Why the local side moves: a tracked import merges the local bookmark (`merge_local_bookmark(name, old_remote, new_remote)`), so a moved `origin/main` with an unmoved local `main` resyncs it. Moving `refs/heads/main` instead is a git-side edit of the colocated local bookmark, which the next precondition imports (local follows `@git`), while `main@origin` stays put. Whether git `HEAD` is symbolic on `main` or detached after `convert` changes only where the new `@` lands; ahead adds an explicit `newChange` on B so `main` is on @'s ancestry either way, and behind holds either way (A0 is an ancestor of every candidate @).

Why seed rather than leave flutter unpinned: `flutter test` and the `flutter_tester` processes share one environment, and the cdylib reads `XDG_CONFIG_HOME` from it; a per-process split is not available, so the pinned dir carries a copy of flutter's settings.

## Verification

**Commands:**
- `flutter test test/features/projects/worker_project_repos_test.dart` (in `app/`, with `XDG_CONFIG_HOME` exported to a scratch dir seeded with `~/.config/flutter`, plus the Makefile's other test-flutter env) -- expected: all pass.
- `dart analyze` and `dart format --output=none --set-exit-if-changed .` (in `app/`) -- expected: clean.
- `cargo make test` (repo root, unpiped to a log, synchronous, long timeout; PATH with `~/development/sdks/flutter/bin` and `~/development/sdks/cargo/bin`, `CARGO_HOME=~/development/sdks/cargo`, `RUSTUP_HOME` unset) -- expected: exit 0 (Makefile.toml changed, so the gate plans every step).
- `find ~/.config/jj -newer <a marker touched before the gate>` -- expected: nothing from this run.
