---
title: 'Story 9.48 closing run — `projects_window_test` waits on real time, not a fixed 500 ms poll'
type: 'bugfix'
created: '2026-10-19'
baseline_revision: 'b4f0074e53086cd867f26954367b19a3104f1215'
status: 'done'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
warnings: []
deferred:
  - summary: >-
      Two sibling test helpers keep a poll-count budget over real settings-file IO: `home_page_test.dart`'s `settle` (100 x 5 ms) and `app_window_coordinator_test.dart`'s `until` (200 x 5 ms), so they can flake under the full gate's load the way `projects_window_test.dart` did.
    evidence: |-
      app/test/features/home/home_page_test.dart:99-105 and app/test/features/window/app_window_coordinator_test.dart:135-140 loop a fixed number of 5 ms polls over work that ends in `SettingsStore._write` (fsync'd, chained). Neither has been seen failing; the intent limited this run to projects_window_test.dart. Found by the blind and verification-gap review layers.
    location: >-
      app/test/features/home/home_page_test.dart:99; app/test/features/window/app_window_coordinator_test.dart:135
    severity: low
    resolved: >-
      2026-10-20 — fixed (spec-9-53-parity-cleanup-after-2026-10-19-loop, commit 56f5868): both helpers poll until done or 10 s of real time (Stopwatch).
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

### 2026-10-19 — Review pass
- verdicts: 10 findings — high 0, medium 0, low 7, false 2, maybe-false 1
- findings:
  - `[low]` `[defer]` (blind 1) `home_page_test.dart`'s `settle` (100 × 5 ms) and `app_window_coordinator_test.dart`'s `until` (200 × 5 ms) keep a poll-count budget over the same real IO, untracked — verified at :99-105 / :135-140; pre-existing and excluded by the intent ("exactly these items"); deferred (frontmatter `deferred:`, mirrored in deferred-work.md).
  - `[low]` `[reject]` (blind 2) the 10 s budget is per call, so a test with three `settle`s could hit the framework timeout before the budget message — only on the failing path, where the test fails loudly either way; carrying a budget across calls adds state for a message.
  - `[low]` `[patch]` (blind 3) the failure reason printed the budget, not the real wait — patched: the reason now reads "settings writes not done after <elapsed> ms of real time (budget 10 s)" (c7c8e05), witnessed by a temporary never-true check (10005 ms).
  - `[low]` `[patch]` (blind 4) the doc said fake_async fakes "only `package:clock`" though it also fakes timers and microtasks — patched: the doc names timers, microtasks and `package:clock`, says `Stopwatch` is real and warns that `clock.stopwatch()` would never advance (c7c8e05).
  - `[low]` `[reject]` (blind 5) after a timeout, teardown can delete the temp folder under in-flight writes and add a second error — failing path only, the budget failure is still reported; draining after a failure adds a branch for a test that already failed.
  - `[low]` `[defer]` (verification-gap, other 1) `home_page_test.dart`'s identical helper has the same flake risk — same root cause as blind 1, deferred there.
  - `[maybe-false]` `[reject]` (intent a) predicates read in-memory state that `SettingsStore.update` sets before its write lands, so a test may finish with a write in flight — not shown to fail (the ledger's failures are budget exhaustion in `settle`); if true only a low test flake, and pre-existing; settling it needs a run that catches a teardown IO error.
  - `[false]` `[reject]` (intent b) nothing separates "fixed" from "lucky run" — a temporary check whose predicate turned true only after 1.5 s real time passed with the new helper (1504 ms) where the old 100 × 5 ms budget fails; the never-true check still fails (10005 ms).
  - `[low]` `[reject]` (intent c) budget per call vs test timeout — same as blind 2.
  - `[false]` `[reject]` (intent d) no `## Auto Run Result` yet — a mid-run state; finalize writes it.

## Design Notes

"Wait on the IO completing" (the ledger's first option) would need the test to hold the write futures, but the writes are started inside widget callbacks (`ProjectsWindow` → `ProjectSession`/`ProjectRegistry` → `SettingsStore.update`); exposing them means a production test hook. The predicate the call sites already pass *is* the completion condition, so only the budget was wrong: a count of polls measures nothing under load, a real-time deadline does. 10 s is far beyond any observed write and well inside the test timeout.

## Verification

**Commands:**
- `flutter test test/features/projects/projects_window_test.dart` (in `app/`) -- expected: all pass.
- `dart analyze` and `dart format --output=none --set-exit-if-changed test/features/projects/projects_window_test.dart` (in `app/`) -- expected: clean.
- `cargo make test` (repo root, unpiped to a log, synchronous, long timeout; PATH with `~/development/sdks/flutter/bin` and `~/development/sdks/cargo/bin`, `CARGO_HOME=~/development/sdks/cargo`, `RUSTUP_HOME` unset) -- expected: exit 0.

## Auto Run Result

Status: done (2026-10-19). Blocking condition: none. Code commits: 1cbf841 (fix), c7c8e05ae295c00a4336a3217b65d096cf77d6e4 (review patches); spec f83d851, plus the finalisation commit of this spec and deferred-work.md.

**Items handed to this closing run.**
1. **`projects_window_test.dart` fails intermittently under the full gate's load — fixed** (commit `1cbf841`, review patches `c7c8e05ae295c00a4336a3217b65d096cf77d6e4`).
   - Verified first: `_Rig.settle` stopped after 100 polls of 5 ms real time (~0.5 s), while the work it waits for ends in `SettingsStore._write` (folder create, `writeAsString(flush: true)`, rename; chained per update), which a loaded machine can hold longer.
   - Now: the same poll (5 ms `runAsync` + `pump`) runs until `done()` holds or 10 s of real time (`Stopwatch`; fake_async does not fake it) have passed; a stuck wait still fails, naming the real wait and the budget. A passing wait returns as soon as before. "Wait on the IO completing" was not chosen: the writes start inside widget callbacks, so it needs a production test hook (Design Notes).

**Summary.** One test helper changed; no production, Rust, API or 9.48 code touched.

**Files changed:**
- `app/test/features/projects/projects_window_test.dart` — `_settleBudget`, real-time `_Rig.settle`, failure reason, doc.
- Tracking: this spec; `deferred-work.md` ("Surfaced in the closing run of Story 9.48": 1 item).

**Review findings.** 10 findings (high 0, medium 0, low 7, false 2, maybe-false 1).
- **Patched, 2 entries (low):** the failure reason gives the real wait (blind 3); the doc names what fake_async fakes (blind 4). Applied by the parent, not the implementation subagent (a resumed agent reports asynchronously, which this unattended run cannot wait for).
- **Deferred (new, mirrored):** sibling poll-count helpers in `home_page_test.dart` and `app_window_coordinator_test.dart` (blind 1, verification-gap other 1; low, pre-existing, outside the intent).
- **Rejected:** per-call budget vs test timeout (blind 2, intent c — failing path only); teardown under in-flight writes after a timeout (blind 5 — failing path only); in-memory predicates vs write completion (intent a, maybe-false, if true low and pre-existing).
- **False:** "no evidence of fixed vs lucky" (intent b — the temporary 1.5 s check); missing Auto Run Result (intent d, mid-run).

**Follow-up review recommendation:** false — this first pass patched 2 entries, both low (patched counts: high 0, medium 0, low 2).

**Verification:**
- Implementation run: `flutter test test/features/projects/projects_window_test.dart` 45 passed; temporary never-true check failed after 10.01 s with the budget reason (removed); `dart analyze`, `dart format` clean; `cargo make test` exit 0 (gate plan 3 of 27 steps: test-flutter, test-dart-analyze, test-dart-format; 730 Flutter tests).
- Orchestrator: the file 45/45 green; a temporary check whose predicate turned true after 1.5 s real time passed (waited 1504 ms; the old budget would have failed it); after the patches `dart format`/`dart analyze` clean, the file 45/45, a temporary never-true check failed with "settings writes not done after 10005 ms of real time (budget 10 s)" (removed), `cargo make test` (repo root, unpiped to a log, `CARGO_HOME=~/development/sdks/cargo`, `RUSTUP_HOME` unset) exit 0, 730 Flutter tests passed. Coverage did not run (Dart test change only; Rust-only ratchet).
- Matrix audit: fast IO — the 45 existing tests; slow IO — the temporary 1.5 s check; never done — the temporary never-true checks (both runs). All ran with the expected outcome.

**Residual risks:**
- Not re-run under the exact parallel load that produced the failures; the bound is now real time, so a write of up to 10 s passes.
- The two sibling helpers keep their poll-count budgets (deferred).
