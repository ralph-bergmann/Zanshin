---
title: 'Story 9.48 closing run — `projects_window_test` waits on real time, not a fixed 500 ms poll'
type: 'bugfix'
created: '2026-10-19'
baseline_revision: 'b4f0074e53086cd867f26954367b19a3104f1215'
status: 'in-progress'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
warnings: []
deferred: []
---

<intent-contract>

## Intent

**Problem:** The one item Story 9.48's run deferred, verified against the current code: `_Rig.settle` (`app/test/features/projects/projects_window_test.dart:147-154`) gives the settings writes started in the fake zone at most 100 polls of 5 ms real time (~0.5 s plus pumps). Each write is real file IO — `SettingsStore._write` (`packages/zanshin_settings/lib/src/settings_store.dart`) creates the folder, writes the temp file with `flush: true` (an fsync) and renames it, chained per update — so under the full gate's parallel load a single fsync can exceed the budget and `expect(done(), isTrue)` fails on whichever test happened to be waiting (three different tests in Story 9.48's runs, more in 9.23/9.15); alone the file is green.

**Approach:** Keep the poll loop (pump in the fake zone, let real IO run in `runAsync`), but bound it by a wall-clock deadline (`Stopwatch`, real time — fake_async fakes only `package:clock`) of 10 s instead of a poll count, and make the failure say it ran out of real time. A passing wait returns at the first poll where `done()` holds, exactly as today.

## Boundaries & Constraints

**Always:**
- Only `app/test/features/projects/projects_window_test.dart` changes, and in it only `_Rig.settle` (signature `settle(bool Function() done)` and every call site unchanged).
- The deadline is measured on real time (`Stopwatch`), so pumps and fake-zone timers do not consume it; the poll interval stays 5 ms so a passing test is not slower.
- On timeout the `expect` still fails (no silent pass), with a reason naming the real-time budget.
- `dart analyze` / `dart format` (line length as configured for `app/`) clean; `cargo make test` green.

**Never:**
- No production code change (no test hook in `SettingsStore`, `ProjectRegistry` or `ProjectSession`); no change to the 9.48 Rust code or its spec.
- No change to other test files (e.g. `app/test/features/home/home_page_test.dart`'s own `settle`) — not this item's.
- No skip/retry annotations, no `tags`, no lowering of what any test asserts.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Fast IO | `done()` true after a few polls | returns as soon as `done()` holds, one trailing pump | — |
| Slow IO (gate load) | the chained writes take 1–5 s real time | keeps polling until `done()` holds; test passes | — |
| Never done | `done()` stays false | stops after 10 s real time | `expect` fails with a reason naming the budget |

</intent-contract>

## Code Map

- `app/test/features/projects/projects_window_test.dart` -- `_Rig.settle` :146-154 (the fix); 20+ call sites (e.g. :349, :493, :542, :664, :702, :753) keep their calls.
- `packages/zanshin_settings/lib/src/settings_store.dart` -- `update` chains writes on `_queue`; `_write` does `create(recursive)` → `writeAsString(flush: true)` → `rename` (read-only evidence for why one wait can take long under load).
- `~/.pub-cache/hosted/pub.dev/fake_async-1.3.3/lib/fake_async.dart:182` -- fake_async wraps the body in `withClock` only, so `dart:core` `Stopwatch` reads real time inside `testWidgets` (read-only evidence).
- `app/test/features/home/home_page_test.dart:99-105` -- the same 100 × 5 ms helper; not touched (scope).

## Tasks & Acceptance

**Execution:**
- `app/test/features/projects/projects_window_test.dart` -- `_Rig.settle`: replace `for (var i = 0; i < 100 && !done(); i++)` with a `Stopwatch` loop `while (!done() && watch.elapsed < budget)` (budget 10 s real time, a private const), keep the `runAsync(delayed 5 ms)` + `pump` body, give the final `expect(done(), isTrue, reason: …)` a reason naming the budget, and update the doc comment (real-time budget; why: the gate's load can hold an fsync'd settings write for seconds) -- item 1.

**Acceptance Criteria:**
- Given the changed file, when `flutter test test/features/projects/projects_window_test.dart` runs in `app/`, then every test passes.
- Given a deliberately never-true predicate (temporary local check, not committed), when `settle` runs, then it fails after ~10 s real time with the budget reason — proving the deadline is real time and the wait still fails.
- Given `cargo make test` on the final tree (repo root, unpiped), then it exits 0.
- Given the end of the run, then `git status --porcelain` is clean and every commit ends with the required co-author trailer and was made with `--no-gpg-sign`.

## Spec Change Log

## Review Triage Log

## Design Notes

"Wait on the IO completing" (the ledger's first option) would need the test to hold the write futures, but the writes are started inside widget callbacks (`ProjectsWindow` → `ProjectSession`/`ProjectRegistry` → `SettingsStore.update`); exposing them means a production test hook. The predicate the call sites already pass *is* the completion condition, so only the budget was wrong: a count of polls measures nothing under load, a real-time deadline does. 10 s is far beyond any observed write and well inside the test timeout.

## Verification

**Commands:**
- `flutter test test/features/projects/projects_window_test.dart` (in `app/`) -- expected: all pass.
- `dart analyze` and `dart format --output=none --set-exit-if-changed test/features/projects/projects_window_test.dart` (in `app/`) -- expected: clean.
- `cargo make test` (repo root, unpiped to a log, synchronous, long timeout; PATH with `~/development/sdks/flutter/bin` and `~/development/sdks/cargo/bin`, `CARGO_HOME=~/development/sdks/cargo`, `RUSTUP_HOME` unset) -- expected: exit 0.
