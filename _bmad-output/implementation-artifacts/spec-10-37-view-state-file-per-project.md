---
title: 'Story 10.37 — View state in a file per project: limits, cleanup, a reset'
type: 'feature'
created: '2026-11-14'
status: 'done'
baseline_revision: 'caefd6bf24d970f002088decf474eae8fe50aab9'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
warnings: ['oversized']
deferred:
  - summary: >-
      The new "Reset view state" row in Settings › Project was not checked visually through Marionette or against the DS cards.
    evidence: |-
      The epic's done rule asks for a Marionette check of every UI change; this unattended run had no running app or catalogue session. Only widget tests (settings_window_test.dart) cover the row.
    location: >-
      app/lib/src/features/settings/project_tab.dart
    severity: low
---

<intent-contract>

## Intent

**Problem:** The inspector's Viewed marks and the graph's stack toggles live on `ProjectEntry` in `settings.json`, which is rewritten on every toggle. The stack toggles have no limit and nothing ever drops view state of changes that are gone.

**Approach:** Move the three lists into one JSON state file per project, `<Application Support>/projects/<stateId>.json`, owned by the settings package (`SettingsStore.projectStates`). Cap both kinds, drop stale keys when the inspector reads a change and in one background pass when a project opens, and add "Reset view state" to Settings › Project.

## Boundaries & Constraints

**Always:**
- `settings.json` keeps settings only: after this story it never holds `viewedFiles`, `expandedStacks` or `collapsedStacks`. A toggle or a Viewed mark writes the state file, never `settings.json`.
- A `settings.json` that still holds the three lists moves them into the state files when it is loaded, then is written once without them. A failed state-file write keeps the lists in memory, and the project's state falls back to them while its file is missing.
- Limits keep the newest entries: Viewed 2000, expanded stacks 500 and collapsed stacks 500 (each list). A repeated toggle counts as new.
- Cleanup is by existence in the repository (`visible()` at the shown layout's operation), never by what the graph shows. A key whose id cannot be checked (not a change or commit id, or a failed query) stays.
- Removing a project from the list deletes its state file. A repository outside the project list keeps its view state in memory only, as today.
- Tests use temp directories only; never Ralph's Application Support folder.

**Never:**
- State files in the repository or in `.jj/`; a reset for all projects; sync between machines.
- A new FFI call: the existence pass uses the existing `findChanges`.
- Moving `graphView` or `recentSearches` (not part of this story).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Toggle | registered project, stack expanded | `projects/<id>.json` lists the key; `settings.json` bytes unchanged | write failure logged, value kept in memory |
| Migration | old `settings.json` with the three lists | `projects/<id>.json` holds them; `settings.json` rewritten without them, entry has `stateId` | state write fails: lists stay in memory, store falls back to them |
| Remove project | entry with `stateId` | `projects/<id>.json` deleted | missing file ignored |
| Open: abandoned change | Viewed key + stack toggle of an abandoned change | both gone after the pass | query error: nothing dropped, logged |
| Open: hidden by search | change exists but the search hides it | keys stay | — |
| Inspector read | file of a change changed (new fingerprint) or no longer listed | its old Viewed key dropped | read refused: nothing dropped |
| Divergent / hidden node read | node key is a commit id | no pruning on read | — |
| Reset | open project with marks and toggles | both lists empty; graph shows default stacks at once, inspector shows nothing Viewed | — |

</intent-contract>

## Code Map

- `packages/zanshin_settings/lib/src/model/projects_settings.dart` -- `ProjectEntry`: add `String? stateId`; mark `expandedStacks`, `collapsedStacks`, `viewedFiles` `@JsonKey(includeToJson: false)` (read only to migrate). Regenerate `.freezed.dart`/`.g.dart` with build_runner (`build.yaml` header rule, memory "source_gen format width").
- `packages/zanshin_settings/lib/src/settings_store.dart` -- `SettingsStore`: `load` runs the migration; `_write` (atomic tmp + rename) is the write pattern to share; `file.parent` is the Application Support folder.
- `packages/zanshin_settings/lib/zanshin_settings.dart` -- exports; add the new file.
- `app/lib/src/features/graph/inspector_viewed_store.dart` -- `ProjectViewedStore(SettingsStore, path)`, limit 2000; keep the constructor signature (used by `project_scope.dart:116`, widgetbook `graph.dart:842`, `integration_test/glass_profile.dart:122`, tests).
- `app/lib/src/features/graph/graph_stack_store.dart` -- `ProjectStackStore(SettingsStore, path)`; today sorts and saves without limit.
- `app/lib/src/features/graph/graph_ports.dart:98-123` -- `GraphStackToggles`, `GraphStackStore` interface (fake in `app/test/features/graph/graph_controls_test.dart:136`).
- `app/lib/src/features/graph/graph_view_model.dart:259-334,537-549` -- loads toggles in `init`, `_toggleStack` adds/removes and saves; `dispose` must drop the listener.
- `app/lib/src/features/graph/graph_inspector.dart:56-68,235-259,832-870` -- `InspectorViewModel`: loads viewed in ctor, re-reads them on every settings change (`_settingsChanged`), `_fetch` sets `_summary`/`_changeId`; `layout.keyOf(node) != changeId` means a hidden or divergent node.
- `app/lib/src/features/home/project_scope.dart` -- `ProjectModule` providers and `ProjectScope` (ctor + `dispose`); regenerate `main.inject.dart` and `app/test/helpers/test_component.inject.dart` with build_runner.
- `packages/zanshin_core/lib/src/worker/handle.dart` `findChanges(operationId, expression, limit:, shortPrefixes:)` -- returns `FoundChanges{entries (commitId, changeId), truncated}`; `shortPrefixes: ''` disables disambiguation.
- `app/lib/src/features/projects/project_registry.dart:140-159` -- `remove`.
- `app/lib/src/features/settings/settings_view_model.dart:872-880` -- `setRemotePoll` pattern (`root`, `store`); `project_tab.dart` -- the Project tab's groups (`SettingsGroup`, `SettingsRow`, `ZsButton` as in `config_file_page.dart:511`).
- `app/lib/l10n/app_en.arb` -- strings; run `flutter gen-l10n`, commit output.
- Revset rules (jj v0.47.0 `docs/revsets.md`): `change_id(prefix)` and `commit_id(prefix)` do not error when unmatched; `visible()` = `::visible_heads()`. Change ids are reverse hex (`k`–`z`), commit ids hex — disjoint alphabets.
- Tests: `packages/zanshin_settings/test/settings_store_test.dart`, `app/test/features/graph/graph_stacks_test.dart:530-590`, `graph_inspector_test.dart:2795-2830`, `app/test/features/projects/project_registry_test.dart`, `app/test/features/graph/graph_ports_test.dart` (real worker + temp repo), `app/test/features/settings/settings_window_test.dart`.

## Tasks & Acceptance

**Execution:**
- `packages/zanshin_settings/lib/src/model/project_state.dart` (new) -- freezed `ProjectState{viewedFiles, expandedStacks, collapsedStacks}` with JSON -- the file's content.
- `packages/zanshin_settings/lib/src/project_states.dart` (new) -- `ProjectStateStore` (one file; `ValueListenable<ProjectState>`; `update` notifies at once and queues an atomic write; deleted stores stop writing) and `ProjectStates` (`directory` = `<settings dir>/projects`; `of(path)` returns the cached store of a registered path or null, assigning a random 16-hex `stateId` through `SettingsStore.update` when the entry has none; `delete(stateId)`; the migration). Unreadable file: logged, starts empty.
- `packages/zanshin_settings/lib/src/settings_store.dart` -- `late final projectStates`; `load` awaits the migration; share the atomic write with the state store.
- `packages/zanshin_settings/lib/src/model/projects_settings.dart` + generated files -- `stateId`, legacy lists not written.
- `app/lib/src/features/graph/inspector_viewed_store.dart`, `graph_stack_store.dart`, `graph_ports.dart` -- both store interfaces extend `Listenable`; the project stores read and write `settings.projectStates.of(path)` (memory when null), limits 2000 / 500 per list, insertion order kept (no sort).
- `app/lib/src/features/graph/graph_view_model.dart` -- a repeated toggle moves the key to the end; listen to the stack store and, when its toggles differ from the model's, replace them and request a layout; remove the listener on dispose.
- `app/lib/src/features/graph/graph_inspector.dart` -- listen to the viewed store instead of re-reading it on settings changes; after a read whose node key is the change id, drop that change's keys not in the summary (`viewedKey` of each listed file) and save.
- `app/lib/src/features/graph/view_state_cleanup.dart` (new) -- once the graph's first layout lands, one `findChanges(op, '(change_id(a) | commit_id(b) | …) & visible()', shortPrefixes: '')` over the ids of the Viewed keys and stack toggles; drop the ids not found (only ids that were queried); a truncated result or an error drops nothing.
- `app/lib/src/features/home/project_scope.dart` -- provide the cleanup, hand it to `ProjectScope`, dispose it; regenerate inject code.
- `app/lib/src/features/projects/project_registry.dart` -- `remove` deletes the entry's state file after the registry update.
- `app/lib/src/features/settings/settings_view_model.dart`, `project_tab.dart`, `app/lib/l10n/app_en.arb` -- a "View state" group with a "Reset view state" row (hint saying what it clears, a `Reset` button, `settings-reset-view-state`), resetting the open project's state; no confirmation (Claude's proposal: view state only, cheap to rebuild).
- Tests -- the I/O matrix: settings package (migration, write, fallback, delete, unreadable file); app adapters (toggle writes state file not settings.json, limits, newest kept); registry remove; inspector prune on read; cleanup against a real repo (abandoned change and hidden commit dropped, existing kept); reset in the settings window test plus model reaction (graph default stacks at once).

**Acceptance Criteria:**
- Given a registered project, when the user toggles a stack or marks a file Viewed, then its `projects/<stateId>.json` changes and `settings.json` does not.
- Given an old `settings.json` with the three lists, when the app loads it, then the lists are in the project's state file and `settings.json` holds none of them.
- Given a project with a state file, when it is removed from the list, then the file is gone.
- Given Viewed keys and stack toggles of an abandoned change and of a change the search hides, when the project opens again, then the abandoned change's keys are gone and the hidden change's stay.
- Given a Viewed file whose content changed in its change, when the inspector reads that change, then the file's old Viewed key is gone from the state file.
- Given the open project with marks and toggles, when the user presses Reset view state in Settings › Project, then both are empty and the graph shows the default stack state at once.
- Given the existence pass, when it runs on the 10k-commit fixture with thousands of ids, then its time is measured and recorded below.

## Spec Change Log

## Review Triage Log

### 2026-11-14 — Review pass
- verdicts: 30 findings — high 0, medium 4, low 22, false 4, maybe-false 0
- findings:
  - `[low]` `[reject]` (blind) A failed state write during migration loses the lists at the next start — real, but the spec's matrix accepts it (view state only) and the fix needs the legacy lists written back conditionally; a failing write into Application Support is rare.
  - `[low]` `[reject]` (blind) A failed `settings.json` write during migration re-migrates with new ids next launch (old lists come back, orphan files) — needs two independent write failures in a row of each other's folder; fix adds complexity.
  - `[low]` `[reject]` (blind) Orphan `projects/*.json` files are never swept (crash between update and delete, failed delete, remove while the id is pending) — rare and harmless (small files); a load-time sweep is new surface. The pending-id case was narrowed before review: `_pending` now clears in the assigning microtask.
  - `[low]` `[reject]` (blind) The stores choose their listener target once; a registry change while a project is open leaves listeners on the old notifier — opening always registers the project (`project_session.dart:443`), and removing the open project closes it; memory-only repos exist only in tests and the catalogue.
  - `[low]` `[reject]` (blind) Lazy `stateId` assignment inside `of()` adds a pending map, a microtask and a test workaround — design choice recorded in Design Notes; no user-facing harm named.
  - `[low]` `[patch]` (blind) `ProjectStateStore.update` chains the shared queue without `catchError`, so a non-file error would poison every later write — patched: queue keeps a `catchError` like `SettingsStore.update`.
  - `[medium]` `[patch]` (blind) `ViewStateCleanup._run` catches only `ZanshinFfiException`; a `StateError` from a closed handle escapes as an unhandled async error — patched: catches any error, logs, drops nothing.
  - `[false]` `[reject]` (blind) Exact-string id matching drops keys stored as short prefixes — the bridge's keys and change ids are always full ids (`crates/zanshin-jj/src/view.rs:100` `reverse_hex()`, commit ids `hex()`); 8-character ids appear only in fake layouts.
  - `[low]` `[reject]` (blind) The pass runs on every open and holds the worker up to ~0.9 s at the limits — the intent asks for a pass at each project open; measured and recorded.
  - `[low]` `[patch]` (blind) Missing tests: truncated result (patched), dispose before reply, divergent ids, existing-file-wins, entry with a `stateId`, the failed-query log line, inspector listener removal — the truncated-result test is added (with the verification-gap rows); the rest rejected as low-value additions.
  - `[low]` `[reject]` (blind) Reset does nothing for a repository outside the project list — opening registers every project, so the app never shows Settings › Project for an unregistered open repo.
  - `[low]` `[reject]` (blind) `_stacksChanged` requests a layout with stacks off, sets no anchor, and doubles the request when the 500 limit trims mid-toggle — a reset or cleanup is rare and explicit; the double request needs 500+ toggles.
  - `[false]` `[reject]` (blind) Legacy lists kept in memory can resurrect old state if the file is deleted mid-session — `_open` runs once per id (cached), and the file is only deleted together with its entry, so the stale copy is never read again.
  - `[false]` `[reject]` (blind) Regenerated files are absent from the diff — the review diff excluded generated files on purpose; they are in the working tree, `dart analyze` is clean and `flutter gen-l10n` produced no further change.
  - `[medium]` `[patch]` (edge) Cleanup catches only `ZanshinFfiException` — same root cause as the blind row; patched once.
  - `[low]` `[reject]` (edge) Listener target fixed at `addListener` — same as the blind row; rejected.
  - `[low]` `[reject]` (edge) The 501st toggle starts a layout request without the anchor — same as the blind `_stacksChanged` row; rejected.
  - `[low]` `[reject]` (edge) Migration rewrites `settings.json` after a failed state write — same as the blind migration row; rejected.
  - `[low]` `[reject]` (edge) `remove()` while the id is pending leaves an orphan file — same as the blind orphan row; rejected.
  - `[low]` `[reject]` (edge) An unreadable state file is overwritten without a `.corrupt` backup — view state only; the warning is logged; a backup adds a rename path for little value.
  - `[low]` `[reject]` (edge) A hand-edited `stateId` such as `../x` writes outside `projects/` — needs the user to edit their own `settings.json`; the target is still a `.json` file the user named.
  - `[low]` `[patch]` (edge) Shared queue without `catchError` — same as the blind row; patched once.
  - `[low]` `[reject]` (edge) Reset is a no-op for an unregistered root — same as the blind row; rejected.
  - `[medium]` `[patch]` (edge, claim) "An error drops nothing" is not true for non-FFI errors — same root cause as the cleanup catch row; patched once.
  - `[low]` `[reject]` (edge, claim) The migration AC fails after a failed state write — same as the blind migration row; rejected.
  - `[medium]` `[patch]` (verification-gap) The truncated-result guard has no test — patched: test with a truncated `FoundChanges` that leaves both stores unchanged.
  - `[low]` `[patch]` (verification-gap) The re-read of the stores after the query has no test — patched: a `find` that writes a new mark and toggle before replying keeps them while gone ids drop.
  - `[low]` `[reject]` (intent) "settings.json does not change after a toggle" is met in its loose reading: the first open writes the `stateId` once — the epic itself keeps the id on `ProjectEntry`, so one write per project is inherent; toggles never write it.
  - `[low]` `[defer]` (intent) No Marionette or catalogue check of the new Reset row — the epic's done rule asks for one; this unattended run had no running app session. Deferred.
  - `[false]` `[reject]` (intent) The open-trigger wiring has no test — `project_graph_host_test.dart` opens real `ProjectScope`s through the generated component, which builds the cleanup; the cleanup logic itself is tested against a real repo.

### 2026-11-14 — Review pass (follow-up)
- verdicts: 33 findings — high 0, medium 0, low 25, false 8, maybe-false 0
- findings:
  - `[low]` `[reject]` (intent) The first open of a project writes `settings.json` once to store the `stateId` — carried: same claim as the first pass's intent row; toggles never write it.
  - `[low]` `[reject]` (intent) A failed state write at migration keeps the lists for the session only — carried: same claim as the first pass's migration rows.
  - `[low]` `[reject]` (intent) The limits live in the app's stores only, so a migrated file can stay over 500 toggles until the next save of that list — harmless (the next save trims it); capping in the settings package adds a second copy of the limits.
  - `[false]` `[reject]` (intent) "A truncated result drops nothing" is not in the intent — the intent keeps every key whose id cannot be checked; ids a truncated result leaves out were not checked.
  - `[false]` `[reject]` (intent) The cleanup's wiring at project open has no test — carried: same claim as the first pass's open-trigger row.
  - `[low]` `[reject]` (intent) No test runs Reset from the Settings button through to a live graph and inspector — each link is tested on the same `ProjectStateStore` notifier (`settings_window_test.dart`, the reset test in `graph_stacks_test.dart`, the "another writer" test in `graph_inspector_test.dart`); a joined window test is a large fixture for little gain.
  - `[low]` `[reject]` (intent) The stores pick their notifier once, at `addListener` — carried: same claim as the first pass's listener rows.
  - `[low]` `[reject]` (verification-gap) No test disposes the cleanup while its query runs — carried: same claim as the first pass's "dispose before reply" test row.
  - `[low]` `[reject]` (verification-gap) The migration loses the lists after a failed state write and a restart — carried: same claim as the first pass's migration rows.
  - `[low]` `[reject]` (verification-gap) Migrated stack toggles keep the old sorted order, so the 500 limit trims them alphabetically — needs more than 500 toggles in one list of an old `settings.json`; no insertion order exists to recover.
  - `[false]` `[reject]` (blind) The cleanup drops the view state of a hidden commit a search shows — the intent asks for existence at `visible()`; a hidden commit is not visible, so dropping it is the specified behavior ("never by what the graph shows" is about the search).
  - `[low]` `[reject]` (blind) A failed migration loses the lists for good after a restart — carried: same claim as the first pass's migration rows.
  - `[false]` `[reject]` (blind) The legacy lists stay on the in-memory entry and come back if the state file goes missing — carried: same claim as the first pass's resurrect row.
  - `[low]` `[reject]` (blind) Nothing sweeps orphaned `projects/*.json` files — carried: same claim as the first pass's orphan rows.
  - `[low]` `[reject]` (blind) An unreadable state file starts empty and is overwritten without a `.corrupt` copy — carried: same claim as the first pass's edge row.
  - `[low]` `[reject]` (blind) Reading a project's state writes `settings.json` (lazy `stateId`) — carried: same claim as the first pass's lazy-id row.
  - `[low]` `[reject]` (blind) Listeners bind to the notifier present at subscribe; `removeListener` can miss the old one — carried: same claim as the first pass's listener rows.
  - `[false]` `[reject]` (blind) One ambiguous id term fails the whole query on every launch — `change_id`/`commit_id` error only on a non-unique prefix (jj v0.47.0 `docs/revsets.md:283-288`), and the keys are full ids (first pass's short-prefix row), so no term is ambiguous; the `4 ×` limit is explained in Design Notes.
  - `[low]` `[patch]` (blind) The `on Object` branch logs only the error's type, so a programming error leaves no trace — patched: `view_state_cleanup.dart` logs the error and its stack trace with the warning.
  - `[low]` `[patch]` (blind) Missing cleanup tests: dispose mid-query, no queryable ids, the closed-handle `StateError`, a never-existing id, a divergent change — patched: the failed-query test in `graph_ports_test.dart` now runs with a `ZanshinFfiException` and a `StateError`; dispose mid-query and divergent ids are carried rejects; a never-existing id behaves like the abandoned one already tested; the empty-terms return is a one-line guard.
  - `[false]` `[reject]` (blind) `_pruneViewed` drops marks of files a partial summary leaves out — `Diff.files` has no cap or truncation (`packages/zanshin_core/lib/src/ffi/diff.dart:228-239`); an undo that restores the fingerprint without the mark is the matrix's "new fingerprint → old key dropped".
  - `[false]` `[reject]` (blind) The prune's save notifies mid-load, before `_summary` is set — `_summary` is set at `graph_inspector.dart:851` before `_pruneViewed` (856), and a prune only removes keys, so `_viewedChanged` sees equal sets and does not notify.
  - `[low]` `[reject]` (blind) Hitting the 500-toggle limit requests the layout twice — carried: same claim as the first pass's `_stacksChanged` rows.
  - `[low]` `[reject]` (blind) The limit test hard-codes 503/501/500, and the 2000 Viewed limit is tested on the memory path only — the trim is computed before the branch (`inspector_viewed_store.dart:49`), so both paths share it; cosmetic.
  - `[low]` `[reject]` (blind) Reset view state has no confirmation or undo and stays active when nothing is stored — the spec's recorded choice (view state only, cheap to rebuild); the intent names no confirmation.
  - `[low]` `[reject]` (edge) Listener kept on the old `ProjectStateStore` — carried: same claim as the first pass's listener rows.
  - `[low]` `[reject]` (edge) An unreadable state file is overwritten instead of moved aside — carried: same claim as the first pass's `.corrupt` row.
  - `[low]` `[reject]` (edge) Migration rewrites `settings.json` after a failed state write — carried: same claim as the first pass's migration rows.
  - `[low]` `[patch]` (edge) A user's `[revset-aliases]` can redefine `visible()`, and the cleanup would then drop existing changes — verified: zanshin-jj loads the user's revset aliases (`crates/zanshin-jj/src/revset.rs:37,392`) and `visible()` is a CLI alias (jj v0.47.0 `cli/src/config/revsets.toml:50`); patched: the query uses its builtin definition, `::visible_heads()`.
  - `[false]` `[reject]` (edge) A 3,000-term flat union overflows the native stack — a throwaway debug-build test ran 3,000 terms (2,000 `change_id`, 1,000 `commit_id`) through `find_changes` on a 2 MB thread: it passed in 2.8 s (removed afterwards).
  - `[low]` `[reject]` (edge) The query at the first layout's operation drops keys another window wrote for newer changes — needs two live scopes of one repository at different operations; the app has one project window with one `ProjectScope` per repository (`project_scope.dart:205`); a fix needs operation tracking.
  - `[low]` `[reject]` (edge) The inspector prunes a mark another window made at a newer operation — same premise as the row above; rejected for the same reason.
  - `[low]` `[reject]` (edge) `remove()` while the id is pending leaves an orphan file — carried: same claim as the first pass's pending-id row.

## Design Notes

- **Why the settings package owns the files:** `SettingsStore.file.parent` is already the Application Support folder, tests already point it at temp dirs, and `ProjectViewedStore(settings, path)` / `ProjectStackStore(settings, path)` keep their signatures, so no DI edge changes for them.
- **Why a random `stateId`, assigned lazily:** the epic proposed the id on `ProjectEntry`; no hashing package is a dependency. `of(path)` assigns it when a project's view state is first opened, so a toggle never touches `settings.json`.
- **Query shape:** one `findChanges` with one term per id beats thousands of `revsetCounts` expressions (one parse, one evaluation). Pick the function by alphabet: `^[k-z]+$` → `change_id(x)`, `^[0-9a-f]+$` → `commit_id(x)`; other keys are not queried and stay. Limit: `4 × terms`; `truncated` → keep everything.
- **Measured 2026-11-14** (throwaway release-build test on `large-10k-commits`, 10,002 commits, `find_changes` alone, 3 runs each, removed afterwards): 100 terms 2–6 ms; 1,000 terms 56–66 ms; 3,000 terms (2,000 `change_id` + 1,000 `commit_id`) 527–549 ms; the same with 100 unmatched ids 435–473 ms; 3,000 `change_id` terms 841–931 ms. The flat union grows faster than linear (about 10× the time for 3× the terms). A balanced-parentheses grouping of the same 3,000 terms did not finish in 20 minutes (the parser), so the flat shape stays. At the limits (2,000 Viewed ids + 1,000 toggles) the pass holds the worker for about 0.5–0.9 s once per project open.

## Verification

**Commands:**
- `dart run build_runner build -d` in `packages/zanshin_settings` and in `app` -- expected: generated files updated, committed.
- `flutter test` in `packages/zanshin_settings` and `app` (affected files) -- expected: pass.
- `dart analyze` and `dart format --set-exit-if-changed .` in both packages -- expected: clean.
- `flutter gen-l10n` in `app` -- expected: output committed.

**Verification notes (2026-11-14, gate rule of the story loop: no full gate):**
- `dart run build_runner build -d` in `packages/zanshin_settings` and `app` (implementation run) -- generated files updated.
- `flutter gen-l10n` in `app` -- re-run after review, no further change.
- `dart analyze app packages/zanshin_settings` -- No issues found (before and after the review patches).
- `dart format --set-exit-if-changed` on `app/lib`, `app/test`, `packages/zanshin_settings/lib`, `packages/zanshin_settings/test` -- 0 changed.
- `flutter test` in `packages/zanshin_settings` -- 55 passed (after review patches).
- `cargo make test-app test/features/graph test/features/settings test/features/projects test/features/home` -- 1339 passed after review patches (one earlier run failed in `project_graph_host_test.dart` only while it ran in parallel with the implementer's own test run; the sequential re-run passed).
- Implementation run also ran `test/app`, bookmarks, sync, undo_timeline, widgetbook, helpers, shell, window, l10n, architecture and `process_spawn_guard_test.dart` through `cargo make test-app` -- all passed (before the review patches, which touch only `project_states.dart`, `view_state_cleanup.dart` and `graph_ports_test.dart`).
- No Rust changed (the 10k measurement test was throwaway and removed), so no cargo test, clippy, codegen or parity oracle run.

**Verification notes (follow-up review, 2026-11-14, same gate rule):**
- `cargo test -p zanshin-jj --test it revset_search::throwaway_deep_union_3000_terms` (throwaway, debug build, 2 MB thread, 3,000 terms with `& ::visible_heads()`) -- passed in 2.8 s; the test was removed again, no Rust change remains.
- `dart format --set-exit-if-changed` on `view_state_cleanup.dart` and `graph_ports_test.dart` -- 0 changed.
- `dart analyze app packages/zanshin_settings` -- No issues found.
- `cargo make test-app test/features/graph/graph_ports_test.dart` -- 40 passed, including the five cleanup tests against a real repo (the query now uses `::visible_heads()`; the failed-query test runs with a `ZanshinFfiException` and a `StateError`).
- No generated code, l10n or settings package file changed, so no build_runner, `flutter gen-l10n` or `zanshin_settings` test run.

## Auto Run Result

Status: done

**Summary.** The Viewed marks and stack toggles moved out of `settings.json` into one state file per project, `<Application Support>/projects/<stateId>.json`, owned by `SettingsStore.projectStates`. An old `settings.json` migrates on load. Viewed keeps the newest 2000 marks, each stack list the newest 500. The inspector drops a change's stale marks when it reads the change; a background pass at project open drops marks and toggles of changes gone from the repository (one `findChanges` query, measured on the 10k fixture). Settings › Project has "Reset view state". Removing a project deletes its file.

**Files changed.**
- `packages/zanshin_settings/lib/src/model/project_state.dart` (+ generated) -- the state file's model.
- `packages/zanshin_settings/lib/src/project_states.dart` -- `ProjectStates` (ids, cache, delete, migration) and `ProjectStateStore`.
- `packages/zanshin_settings/lib/src/json_file.dart` -- the atomic JSON write shared with `settings.json`.
- `packages/zanshin_settings/lib/src/settings_store.dart` -- `projectStates`, migration in `load`.
- `packages/zanshin_settings/lib/src/model/projects_settings.dart` (+ generated) -- `stateId`; the three old lists read only.
- `app/lib/src/features/graph/inspector_viewed_store.dart`, `graph_stack_store.dart`, `graph_ports.dart` -- stores over the state file, `Listenable`, limits.
- `app/lib/src/features/graph/graph_view_model.dart` -- repeated toggle is newest; follows other writers of the toggles.
- `app/lib/src/features/graph/graph_inspector.dart` -- follows the Viewed store; prunes a change's stale marks on read.
- `app/lib/src/features/graph/view_state_cleanup.dart` -- the existence pass at project open.
- `app/lib/src/features/home/project_scope.dart` (+ `main.inject.dart`, `test_component.inject.dart`) -- shared stores and the cleanup wired per project.
- `app/lib/src/features/projects/project_registry.dart` -- `remove` deletes the state file.
- `app/lib/src/features/settings/settings_view_model.dart`, `project_tab.dart`, `app/lib/l10n/*` -- the Reset view state row.
- Tests: `settings_store_test.dart`, `projects_settings_test.dart`, `graph_stacks_test.dart`, `graph_inspector_test.dart`, `graph_ports_test.dart` (real repo), `project_registry_test.dart`, `settings_window_test.dart`; adjusted `graph_controls_test.dart`, `remotes_group_test.dart`, `project_graph_host_test.dart`.

**Review findings.** 30 findings: 4 patch rows in 4 entries (queue `catchError` -- low; cleanup catches any error -- medium; truncated-result test -- medium; re-read test -- low), 1 deferred (no Marionette check of the Reset row -- low, mirrored in `deferred-work.md`), 21 rejected low with reasons in the triage log, 4 false. Before review, `ProjectStates._pending` was also fixed to clear once the id is on the entry (a removed and re-added path now gets a persisted new id), with a test.

**Follow-up review recommendation: true.** Patched on this first pass: medium 2, low 2. The named unverified risk: the new `on Object` branch in `ViewStateCleanup._run` has no test with a non-FFI error (for example a `StateError` from a closed handle).

**Residual risks.**
- A failed state-file write during migration loses the old lists at the next start (accepted: view state only).
- The existence pass holds the worker for up to about 0.9 s at the limits, once per project open.
- The first open of a project without a `stateId` writes `settings.json` once to store the id; widget tests that open a real `ProjectScope` in fake async need the real-time/pump loop used in `project_graph_host_test.dart`.
- Not checked visually through Marionette (deferred).

### Follow-up review pass (2026-11-14)

Status: done

**Summary.** A fresh four-layer review of the whole story diff. Three low findings patched in `ViewStateCleanup`; nothing new deferred.

**Files changed.**
- `app/lib/src/features/graph/view_state_cleanup.dart` -- the query uses `::visible_heads()` instead of the user-overridable `visible()` alias; the catch-all branch logs the error and its stack trace.
- `app/test/features/graph/graph_ports_test.dart` -- the failed-query test also runs with a `StateError` (a closed handle), the risk the first pass named.

**Review findings.** 33 findings: 3 patched (all low: the `visible()` alias, the catch-all log line, the `StateError` test), 0 deferred, 22 rejected low (17 of them carried from the first pass; the other 5 -- limits applied only by the app stores, no end-to-end Reset test, sorted migrated toggles, hard-coded limit numbers, no Reset confirmation -- with reasons in the triage log), 8 false (among them the stack-overflow claim, disproved by a debug-build run of 3,000 terms).

**Follow-up review recommendation: false.** A follow-up pass that patched no high has converged. Patched this pass: high 0, medium 0, low 3.

**Residual risks.** Unchanged from the first pass: migration loses the old lists after a failed state write and a restart; the existence pass holds the worker up to about 0.9 s per open at the limits; the Reset row is not checked through Marionette (deferred).
