---
title: 'Story-loop 5.9 fix-up: settings writes race the temp-folder teardown'
type: 'bugfix'
created: '2026-11-12'
status: 'done'
baseline_revision: 'e48fc9ce86c29c8e3562ab9b48927b0741177ac7'
review_loop_iteration: 0
followup_review_recommended: true
context: []
warnings: ['oversized']
deferred:
  - summary: >-
      The app may quit before a queued settings write reaches the disk: no quit path waits for SettingsStore's write queue.
    evidence: |-
      Unverified. answerExitRequest closes the worker and exits; AppWindows calls unawaited(exitProcess()) with AppExitType.required. A fire-and-forget write started just before is not awaited. To settle: check whether a write is queued on the quit path and whether the engine ends the process before it lands.
    location: >-
      app/lib/src/app/app_exit_handler.dart:13-22; app/lib/src/features/window/app_windows.dart:202,507
    severity: medium (unverified)
  - summary: >-
      Plain tests that delete the settings folder with an async delete may race a write still in flight, like the deleteSync teardowns this run fixed.
    evidence: |-
      Unverified. Out of the intent's deleteSync scope; none of them was shown to end with a write in flight. To settle: check each for a fire-and-forget write at the end of a test.
    location: >-
      app/test/app/app_window_coordinator_test.dart:75; app/test/features/projects/project_session_test.dart:40-43; project_registry_test.dart, boot_module_test.dart, floating_shell_view_model_test.dart, window_appearance_sync_test.dart, zanshin_app_view_model_test.dart
    severity: medium (unverified)
---

<intent-contract>

## Intent

**Problem:** The loop's final `cargo make test` failed one app test under load: `app_menu_test.dart` "View › Zoom In ⌘+, Zoom Out ⌘−, Actual Size ⌘0 …" threw `FileSystemException: Deletion failed … Directory not empty` from its teardown `dir.deleteSync(recursive: true)`. Cause (verified with a teardown probe): the menu's zoom items call `SettingsStore.update` unawaited from the widget test's fake-async zone. Each I/O step of that write advances only when the real event loop gets a turn (a `runAsync` window) and the fake microtasks are flushed after it, so at teardown four of the five writes are still queued (in-memory zoom 90, `settings.json` still 110) and one I/O step is in flight. Under load that step creates `settings.json.tmp` while `deleteSync` empties the folder. The same race sits in other widget tests, and in plain tests that leave an unawaited write running when their teardown deletes the folder.

**Approach:** Give `SettingsStore` a `@visibleForTesting` getter `settled` (the write queue's tail). Add one test helper `settleSettingsWrites(tester, store)` that pumps `runAsync` turns until `settled` completes. Each affected site runs the drain before the folder is deleted: widget tests through an `addTearDown` registered after the delete teardown (so it runs first, still before `binding.postTest`), plain tests through `addTearDown(() => store.settled)`.

## Boundaries & Constraints

**Always:** Fix at the cause: tests wait for the store's writes before deleting its folder. The production change is the one getter. Keep each test's assertions unchanged.

**Never:** Swallow or retry the deletion error; add fixed sleeps as the fix; change `SettingsStore` write behaviour; await `store.settled` in a teardown of a widget test (a fake-zone future never completes after the body) or in a group-level `tearDown` (it runs after `postTest`); touch tests without a write in flight at teardown (`boot_window_host_test`, `zanshin_bootstrap_test`, `graph_card_menu_test`, `operation_changes_test`, `undo_timeline_view_test`, plain tests that await their last write, and the async-`delete` plain tests that are not this teardown); run `cargo make test`/`test-full`.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Widget test, writes queued in the fake zone | zoom test ends with 4 writes pending | drain pumps until the last write is on disk; folder deleted cleanly | No error expected |
| Widget test, nothing written | rig set up, no update | drain finishes after one turn | No error expected |
| Plain test, unawaited write | `ProjectSearchStore.saveView` then test ends | teardown awaits `settled`, then deletes | No error expected |
| A failed write | write's folder is a file | `settled` still completes (the queue catches errors) | write error stays with its caller |

</intent-contract>

## Code Map

- `packages/zanshin_settings/lib/src/settings_store.dart:29,81-92` -- `_queue`, the write chain; `update` sets `_queue = write.catchError(...)`, so the tail completes after every queued write, failed ones included. Add `settled` here.
- `packages/zanshin_settings/test/settings_store_test.dart:104-161` -- `update` group; add one `settled` test in its style (`_darkJson`, `file`).
- `flutter_test` `binding.dart:2477-2550,2682-2722` (read-only) -- `runAsync` flushes the fake microtasks only after its future completes; `testWidgets` registers `addTearDown(binding.postTest)` first, so body-registered teardowns run before it, while `tester.pump` still works.
- `app/test/app/menu/app_menu_test.dart:219-225` -- `_Rig.setUp`: dir, delete teardown, store. Writers: zoom items (`app_menu.dart:106`), `GraphPreferences` toggles.
- `app/test/helpers/settings_rig.dart:68-70` -- `SettingsRig.pump`; settings view model writes.
- `app/test/helpers/test_component.dart:181-188` -- `testComponent`; the component graph writes (registry, shell widths, …).
- `app/test/features/projects/projects_window_test.dart:114-118` -- rig `pump`; registry writes.
- `app/test/features/graph/revset_configs/revset_configs_window_test.dart:91-101` -- `setUp(tester)`; Save writes `revsetConfigs`.
- `app/test/features/window/window_zoom_test.dart:139-141` -- the ⌘= test; `window_zoom.dart:73` writes unawaited. The first test awaits its writes in `runAsync`: no race.
- `app/test/features/graph/graph_inspector_test.dart:380-435,2416-2426` -- group `setUp`/`tearDown`; `pump` builds every inspector (Viewed, Side by side write); plain test "ProjectViewedStore: … newest 2000 stay" saves to `/r/a` unawaited.
- `app/test/features/graph/graph_stacks_test.dart:502-548` -- group `persistence (item 5)`; only the widget test at 530 toggles (`graph_view_model.dart:549` saves).
- `app/test/features/graph/graph_controls_test.dart:135-178,724-750` -- `_store` (writes `graph` unawaited), `_testWidgets` (end-of-body cleanup over `_rigs`); plain tests "a stored width out of range…" and "another writer of the store…" leave writes running.
- `app/test/features/graph/graph_search_field_test.dart:919-946` -- plain test "ProjectSearchStore keeps …"; `graph_search_store.dart:73` writes unawaited.

## Tasks & Acceptance

**Execution:**
- `packages/zanshin_settings/lib/src/settings_store.dart` -- add `@visibleForTesting Future<void> get settled => _queue;` with a one-line doc -- the only signal that all queued writes are done.
- `packages/zanshin_settings/test/settings_store_test.dart` -- one test: two unawaited updates, `await store.settled`, file holds the last value, no `.tmp` -- pins the contract the drain relies on.
- `app/test/helpers/settle_settings.dart` (new) -- `settleSettingsWrites(WidgetTester, SettingsStore)`: listen to `settled`, loop `runAsync` (1 ms) + `pump` until it completed; doc says why.
- `app/test/app/menu/app_menu_test.dart` -- remove the temporary probe; register the drain teardown after the store is created.
- `app/test/helpers/settings_rig.dart`, `app/test/helpers/test_component.dart`, `app/test/features/projects/projects_window_test.dart`, `app/test/features/graph/revset_configs/revset_configs_window_test.dart`, `app/test/features/window/window_zoom_test.dart` (⌘= test), `app/test/features/graph/graph_inspector_test.dart` (`pump`), `app/test/features/graph/graph_stacks_test.dart` (test at 530) -- same drain teardown after the store exists.
- `app/test/features/graph/graph_controls_test.dart` -- `_testWidgets`: after disposing the rigs, drain each rig's store; the two plain tests that leave a write running add `addTearDown(() => store.settled)`.
- `app/test/features/graph/graph_inspector_test.dart` (plain "ProjectViewedStore" test), `app/test/features/graph/graph_search_field_test.dart` (plain "ProjectSearchStore" test) -- `addTearDown(() => settings.settled)`.

**Acceptance Criteria:**
- Given the zoom test, when it ends, then the drain has written zoom 90 to `settings.json` before the folder is deleted, and the test passes repeatedly alone and with other app test files.
- Given every changed test file, when it runs with `flutter test`, then it passes; `dart analyze` and `dart format --set-exit-if-changed` are clean for `app` and `packages/zanshin_settings`.

## Spec Change Log

## Review Triage Log

### 2026-11-12 — Review pass
- verdicts: 23 findings — high 0, medium 4, low 12, false 3, maybe-false 4
- findings:
  - `[medium]` `[patch]` (blind) The drain reads `store.settled` once; a write queued after the captured tail completes (an `await update; await update` chain like `ProjectSession.open`, `project_session.dart:443-448`) is not waited for, and the doc overstates it — the helper now drains until the tail it waited for is `identical` to `store.settled`; doc says writes queued meanwhile are included.
  - `[low]` `[reject]` (blind) The drain loop has no time limit — every write completes or fails, so no reachable hang was shown; a budget adds a branch and a clock for a case that only a broken store reaches, where the test timeout still reports it.
  - `[low]` `[patch]` (blind) The failed-write `settled` test passes if `settled` were already complete — added `expect(warnings, hasLength(1))` after `await store.settled`.
  - `[low]` `[reject]` (blind) `graph_controls_test` drains inside the `_testWidgets` body, so a failing body skips it — only adds a second error to a test that already fails; the rigs' dispose already behaves the same; a try/finally around the body changes that wrapper's failure path for noise only.
  - `[low]` `[patch]` (blind) `settled`'s doc ("failed ones included") reads as "completes with the failure" — doc now says it never completes with an error.
  - `[maybe-false]` `[defer]` (blind) No quit path awaits queued settings writes (`app_exit_handler.dart:13-22`, `app_windows.dart:202,507`) — pre-existing, not caused by this run; to settle: is a write queued on the quit path and does the engine exit before it lands. Deferred, medium (unverified).
  - `[maybe-false]` `[defer]` (blind) Older workarounds (dummy writes, 50 ms sleeps) and the async-`delete` plain tests left unexplained — the workarounds work and refactoring them fixes no failure; the async-`delete` tests are outside the intent's `deleteSync` scope and none was shown to end with a write in flight. Deferred, medium (unverified).
  - `[medium]` `[patch]` (edge) Same as the first blind finding: a write queued after the captured tail is not drained — same patch.
  - `[low]` `[reject]` (edge) No bound on the drain loop — same as the blind finding; rejected for the same reason.
  - `[low]` `[reject]` (edge) A body that failed with its own `runAsync` pending makes the teardown's `runAsync` throw (reentrant) — only after a test already failed; a guard adds a catch branch for noise on a red test.
  - `[low]` `[reject]` (edge) `_testWidgets` skips the drain when the body throws — same as the blind finding; rejected for the same reason.
  - `[low]` `[patch]` (edge) `projects_window_test` pumps twice (lines 557, 562); the teardown reads the `store` field late, so both drains drain the second store — the three sites with a mutable `store` field (`projects_window_test`, `settings_rig`, `revset_configs_window_test`) now capture the loaded store in a local; `app_menu_test`'s field is `late final`.
  - `[low]` `[patch]` (edge) The failed-write test can pass vacuously — same as the blind finding; same patch.
  - `[medium]` `[patch]` (verification-gap) No test asserts that the drain puts writes on disk; breaking or removing it keeps the suite green — added `app/test/helpers/settle_settings_test.dart`: a chained write in the fake zone, the drain, then the file must hold the second value.
  - `[low]` `[patch]` (verification-gap) The drain teardown reads a mutable field (`projects_window_test.dart:119-120`) — same as the edge finding; same patch.
  - `[medium]` `[patch]` (intent) No test reproduces the failure or checks the drain's effect on disk — same root cause as the verification gap; same patch.
  - `[maybe-false]` `[defer]` (intent) The quit path was not examined for lost writes — same as the blind finding; deferred with it.
  - `[false]` `[reject]` (intent) The sweep goes beyond the literal pattern (plain tests; one 1 ms turn per harness test) — the plain tests changed are `deleteSync` + store sites with a write in flight, which is the intent's criterion; the cost is one turn per test.
  - `[maybe-false]` `[defer]` (intent) The async-`delete` store tests are not covered — same as the blind finding; deferred with it.
  - `[false]` `[reject]` (intent) The five excluded files are judged only in spec prose — each was checked in planning: the boot tests never write, `graph_card_menu_test`'s viewed store is outside the registry, the Undo Timeline widget tests never toggle the layout and its plain test awaits its last write.
  - `[low]` `[reject]` (intent) A second drain idiom next to `floating_shell_view_model_test`'s dummy write — that idiom changes state and notifies listeners; migrating the old tests fixes no failure.
  - `[low]` `[reject]` (intent) A failing `_testWidgets` body skips the drain — same as the blind finding; rejected for the same reason.
  - `[false]` `[reject]` (intent) No Auto Run Result, no actual check outcomes, no commit — written at finalize, which follows the review.

## Design Notes

The drain must run inside the test, not after it: writes started in the fake zone queue their continuations in the test's `FakeAsync`, which nobody flushes after `binding.postTest`. A body-registered `addTearDown` runs before `postTest` (LIFO), so `tester.runAsync` + `tester.pump` still advance the chain there. Sketch:

```dart
var settled = false;
unawaited(store.settled.whenComplete(() => settled = true));
while (!settled) {
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 1)));
  await tester.pump();
}
```

## Verification

**Commands:**
- `flutter test test/app/menu/app_menu_test.dart --plain-name "View › Zoom In"` (from `app/`, 5×) -- expected: pass each time
- `flutter test` on every changed app test file in one run (load) -- expected: all pass
- `flutter test test/settings_store_test.dart` (from `packages/zanshin_settings/`) -- expected: all pass
- `dart analyze` and `dart format --set-exit-if-changed .` in `app` and `packages/zanshin_settings` -- expected: clean

**Outcomes (2026-11-12, after the review patches):**
- Cause probe (temporary, removed): at teardown the store held zoom 90 while `settings.json` held 110 — four of five writes still queued. With the drain, the same probe showed only `settings.json`, holding zoom 90.
- Zoom test alone, 5×: passed 5 of 5 (before and after the review patches).
- Load run, one `flutter test` over 19 targets — every changed test file, `test/helpers/settle_settings_test.dart`, the `settings_rig` / `test_component` users, `graph_card_menu_test` and `test/features/undo_timeline`: +552, all passed (551 before the new helper test).
- `settle_settings_test` fails with the identity loop disabled ("contains pair 'zoom' => <125>"), so it pins the chained-write case.
- `packages/zanshin_settings`: `flutter test test/settings_store_test.dart` +14 passed; `dart analyze` no issues; `dart format --set-exit-if-changed .` exit 0.
- `app`: `dart analyze` no issues; `dart format --set-exit-if-changed .` exit 0.
- Not run, per the gate exception: `cargo make test` / `test-full`; the main session reruns the gate.

## Auto Run Result

Status: done

- **Failure 1 (`app_menu_test.dart` zoom test: `Deletion failed … Directory not empty`)** — fixed by a770e6ad360887dedc722196c90395319013bbf7. Cause verified: the menu's zoom items write the settings unawaited from the widget test's fake-async zone; each file operation advances only on a `runAsync` turn followed by a fake microtask flush, so at teardown four of five writes were still queued and one operation raced `deleteSync`. Not a production defect: the store lives for the app's lifetime.
- **Summary:** `SettingsStore` gets a `@visibleForTesting` `settled` future (the write queue's tail; never completes with an error). The new helper `settleSettingsWrites(tester, store)` pumps `runAsync` turns until `settled` completes, writes queued meanwhile included. Widget tests that write register it as a teardown after the delete teardown (it runs before `binding.postTest`); plain tests that leave a write running add `addTearDown(() => store.settled)`.
- **Files:**
  - `packages/zanshin_settings/lib/src/settings_store.dart` — the `settled` getter.
  - `packages/zanshin_settings/test/settings_store_test.dart` — two tests: `settled` after queued writes, and after a failed one.
  - `app/test/helpers/settle_settings.dart` (new) — the drain helper; `app/test/helpers/settle_settings_test.dart` (new) — a chained write reaches the disk.
  - Drain teardowns: `app_menu_test.dart` (`_Rig.setUp`), `settings_rig.dart`, `test_component.dart`, `projects_window_test.dart`, `revset_configs_window_test.dart`, `window_zoom_test.dart` (⌘= test), `graph_inspector_test.dart` (`pump`), `graph_stacks_test.dart` (toggle test), `graph_controls_test.dart` (`_testWidgets`).
  - `addTearDown(() => store.settled)`: two plain tests in `graph_controls_test.dart`, one each in `graph_inspector_test.dart` and `graph_search_field_test.dart`.
- **Sweep:** every `deleteSync` + `SettingsStore` site in `app/test` and `packages/*/test` was checked. Unchanged because no write is in flight at teardown: `boot_window_host_test`, `zanshin_bootstrap_test`, `graph_card_menu_test`, `operation_changes_test`, `undo_timeline_view_test`, `window_zoom_test`'s first test, and plain tests that await their last write. `packages/zanshin_settings` tests are plain and await their writes.
- **Review:** 23 findings (medium 4, low 12, false 3, maybe-false 4). Patched: 5 entries — chained writes after the captured tail (medium), no test of the drain's effect (medium), the vacuous failed-write test (low), the `settled` doc (low), late-read `store` fields (low). Deferred: 2 (quit path does not await queued writes; async-`delete` plain tests), both medium (unverified), mirrored into `deferred-work.md`. Rejected: no time limit on the drain (no reachable hang; the test timeout still reports it); a failing `_testWidgets` body or a pending `runAsync` skips the drain (only adds noise to a test already red); a second drain idiom next to the dummy-write one (migrating fixes no failure); and three false findings (sweep scope, excluded files, finalize items).
- **Follow-up review recommended: true** — patched high 0, medium 2, low 3. The named unverified risk: the teardown-time drain (`runAsync` + `pump` after the body) has run only on 552 targeted tests; the full app suite under the gate's parallel load, the only place the original failure showed, has not run it yet. The main session's `cargo make test` settles it.
- **Residual risks:** the drain loops without a bound, so a write that never finishes shows as the test timeout. The async-`delete` plain tests may hold the same race (deferred).
