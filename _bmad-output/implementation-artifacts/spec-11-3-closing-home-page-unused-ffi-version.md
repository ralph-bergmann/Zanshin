---
title: 'Story 11.3 closing run — HomePage stops injecting the unread ZanshinFfiVersion'
type: 'chore'
created: '2026-10-18'
status: 'done'
baseline_revision: 'b67f9c1d494a2952e65d2a7f5d2723766e3bd8e1'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
warnings: ['oversized']
deferred:
  - summary: >-
      ZanshinFfiModule's version wrapper never frees the Rust-allocated C string it reads, against the caller-frees contract of zanshin_ffi_version.
    evidence: |-
      Review pass 2026-10-18 (verification-gap, blind hunter), verified: packages/zanshin_core/lib/src/ffi/zanshin_version.dart:15 returns `bindings.zanshin_ffi_version().cast<Utf8>().toDartString`, a tear-off over a pointer that is never passed to `zanshin_string_free`; bindings.dart:792, crates/zanshin-ffi/src/lib.rs:65-72 and docs/ffi-abi.md:28 say the caller MUST free it. Pre-existing. After this run nothing in the app's production graph calls the wrapper; app/test/native_asset_smoke_test.dart and zanshin_version_test.dart:26 still do. GetDiagnostics (diagnostics.dart:15-29) already carries appVersion and gitSha and frees its buffer through the token path.
    location: >-
      packages/zanshin_core/lib/src/ffi/zanshin_version.dart:15
    severity: low
  - summary: >-
      Two DI bindings in MainComponent, GetDiagnostics and IconRegistry, are registered but consumed by nothing, so every build_runner run in app/ prints two unused-binding warnings.
    evidence: |-
      Review pass 2026-10-18 (blind hunter), verified: in the regenerated app/lib/main.inject.dart `getDiagnostics$Provider` and `iconRegistry$Provider` are built and handed to nothing; the implementation run's build_runner output carried both warnings (the Story 11.3 spec's verification noted them too); deferred-work.md records neither. Pre-existing; this run kept them (its Never list).
    location: >-
      app/lib/main.dart:118-124 (ZanshinDiagnosticsModule, IconModule); app/lib/main.inject.dart
    severity: low
---

<intent-contract>

## Intent

**Problem:** Ledger item 1 handed to this closing run (deferred-work.md "Surfaced in Story 11.3", review pass 2026-10-18, blind hunter): `HomePage` (`app/lib/src/features/home/home_page.dart:22-27`) takes a required `ZanshinFfiVersion zanshinFfiVersion` and never reads it. Verified against the current code: the only reads of `zanshinFfiVersion` in `app/lib` are the field and the generated `_HomePageFactory$Factory.create` that fills it (`main.inject.dart:147`), which costs one `zanshin_ffi_version` FFI call per created home for nothing; both app tests that build `HomePage` pass a dummy `() => 'test'`.

**Approach:** Drop the parameter and field from `HomePage`, regenerate the DI code, and remove what that change orphans: `HomePage`'s `zanshin_core` import and the `ZanshinFfiModule` entry of `MainComponent`'s `@Component` list (its one binding has no other consumer in the graph). The two tests stop passing the dummy.

## Boundaries & Constraints

**Always:**
- The project window renders exactly as before (`FloatingShell` with the bar-row `WindowDragArea` stand-in); `home_page_test.dart` and `zanshin_app_test.dart` keep every assertion they have today, minus the dummy argument.
- `ZanshinFfiModule` / `ZanshinFfiVersion` stay in `packages/zanshin_core` and its barrel export: `app/test/native_asset_smoke_test.dart` and `packages/zanshin_core/test/ffi/zanshin_version_test.dart` use them (the latter is the extern fn's cross-FFI coverage witness).
- Generated files (`main.inject.dart`, `home_page.factory.dart`) change only through `dart run build_runner build --delete-conflicting-outputs` in `app/`, never by hand.
- SPDX first line, page width 120, `dart analyze --fatal-infos --fatal-warnings` and `dart format` clean in `app/`.

**Never:**
- No change to `FloatingShell`, the shell controllers, `zanshin_ui`, `zanshin_settings`, `zanshin_core` or any Rust code; no other Story 11.3 code touched.
- No removal of other unconsumed bindings (`ZanshinDiagnosticsModule`/`GetDiagnostics`, `IconRegistry`) — pre-existing, outside this item.
- No change to deferred-work.md's existing bullets, `epic-11-context.md`, `epics.md`, `sprint-status.yaml`, `project-context.md` or the Story 11.3 spec.
- No `coverage-baseline.txt` lowering or `exclude_prefix`.

</intent-contract>

## Code Map

- `app/lib/src/features/home/home_page.dart:6` -- `import 'package:zanshin_core/zanshin_core.dart';` (used only for `ZanshinFfiVersion`); `:20-27` `@assistedInject const HomePage({required this.zanshinFfiVersion, required this.viewModelFactory, @assisted super.key})` and `final ZanshinFfiVersion zanshinFfiVersion;` (never read in `build` :32-39).
- `app/lib/src/features/home/home_page.factory.dart` -- generated `HomePageFactory` (`create({Key? key})`); its shape does not change.
- `app/lib/main.dart:118-125` -- `@Component([ZanshinFfiModule, ZanshinDiagnosticsModule, WorkerModule, WorkerLifecycleModule, SettingsModule, IconModule])`; `ZanshinFfiModule` provides only `ZanshinFfiVersion` (`packages/zanshin_core/lib/src/ffi/zanshin_version.dart:10-16`); the `zanshin_core` import stays (other modules, `ZanshinWorker`, `adoptLoginShellEnvironment`).
- `app/lib/main.inject.dart:37,44,53,67-77,134-171,323-335` -- generated: the `zanshinFfiModule` create parameter, `_ZanshinFfiVersion$Provider`, and `_HomePageFactory$Factory`/`$Provider` taking it; regenerate. No caller passes `zanshinFfiModule:` (grep of `app/`, `packages/`).
- `app/test/features/home/home_page_test.dart:60` -- `HomePage(zanshinFfiVersion: () => 'test', viewModelFactory: _factory(store))`.
- `app/test/features/app/zanshin_app_test.dart:20-31` -- `_HomePageFactory.create` passes `zanshinFfiVersion: () => 'test'`; its doc comment says "with a fake FFI version".
- Gate: app-only Dart change → the change-aware plan runs the app's Flutter test, analyze and format steps; no Rust and no `zanshin_core` change, so coverage does not run.

## Tasks & Acceptance

**Execution:**
- `app/lib/src/features/home/home_page.dart` -- remove the `zanshinFfiVersion` constructor parameter and field, and the now-unused `zanshin_core` import -- the item's fix.
- `app/lib/main.dart` -- remove `ZanshinFfiModule` from the `@Component` list -- its only binding loses its only consumer (orphan of the fix).
- `app/lib/main.inject.dart`, `app/lib/src/features/home/home_page.factory.dart` -- regenerate with `dart run build_runner build --delete-conflicting-outputs` in `app/` -- DI follows the constructor.
- `app/test/features/home/home_page_test.dart`, `app/test/features/app/zanshin_app_test.dart` -- drop the `zanshinFfiVersion:` argument (and "with a fake FFI version" from the fake factory's doc) -- the parameter is gone.

**Acceptance Criteria:**
- Given the change, when `grep -rn zanshinFfiVersion app/lib app/test` runs, then it finds nothing, and `grep -n ZanshinFfiModule app/lib/main.dart app/lib/main.inject.dart` finds nothing.
- Given the regenerated DI, when `HomePageFactory.create()` builds the home, then `HomePage` takes only `viewModelFactory` and `key`, and no `zanshin_ffi_version` call happens on the way.
- Given `flutter test` in `app/`, when `home_page_test.dart` and `zanshin_app_test.dart` run, then they pass with their existing assertions (the home is `HomePage` over `FloatingShell`, canvas fill, bar-row drag area, empty islands, no rail), and `native_asset_smoke_test.dart` still passes.
- Given the change, when `cargo make test` runs unpiped from the main session, then it exits 0 and `coverage-baseline.txt` is unchanged.

## Spec Change Log

## Review Triage Log

### 2026-10-18 — Review pass
- verdicts: 14 findings — high 0, medium 0, low 9, false 5, maybe-false 0
- findings:
  - `[low]` `[reject]` (blind 1) No test runs the generated `MainComponent` graph, so the "no `zanshin_ffi_version` call on the way" AC has no runtime witness — pre-existing gap (no test ever built the component); the analyzer compiles `main.inject.dart` (`dart analyze --fatal-infos` clean), inject's generator validates the graph at build time, and the regenerated code holds no `ZanshinFfiVersion` provider at all; a component test needs new settings and icon fixtures for a breakage that would fail loudly at codegen or compile time.
  - `[low]` `[reject]` (blind 2) The Problem statement's "one FFI call per created home" is wrong: the removed provider was a `late final` singleton, so it was one call per app run — true; the fix edits this build's spec (inside the intent contract); the Auto Run Result states the corrected cost.
  - `[low]` `[defer]` (blind 3) `ZanshinFfiModule` leaks the Rust-allocated version string — grouped with verification-gap other 1; deferred there.
  - `[low]` `[reject]` (blind 4) The Design Notes send a future consumer back to `ZanshinFfiModule`, while `GetDiagnostics` already carries `appVersion` and `gitSha` and frees its buffer — true (`diagnostics.dart:15-29`); the fix edits this build's spec; the deferred leak entry's follow-up names `GetDiagnostics` instead.
  - `[low]` `[defer]` (blind 5) `GetDiagnostics` and `IconRegistry` stay registered and unconsumed, so build_runner warns twice per run, and no ledger entry records it — verified (both providers are built and passed to nothing; the implementation run's build_runner printed both warnings); pre-existing, outside this run's item; deferred and mirrored.
  - `[false]` `[reject]` (blind 6) The diff leaves deferred-work.md:1350-1352 and the 11.3 spec's entry open, so 11.10 inherits a phantom task — the orchestrating loop closes handed-over ledger items after the run (precedent `90015a8` after 11.14's closing run, `b67f9c1` after 11.3); this run records the fix commit in its Auto Run Result for that close, and its Never list keeps existing bullets untouched.
  - `[low]` `[reject]` (edge 1) AC 1's `grep -rn zanshinFfiVersion app/lib app/test` still hits `app/test/native_asset_smoke_test.dart:12` (`ZanshinFfiModule().zanshinFfiVersion()`), which the Always list keeps — true, the AC's pattern is wider than its purpose; the fix edits this build's spec; the only hit is that kept smoke test, every `HomePage` reference is gone (recorded in Verification).
  - `[low]` `[defer]` (verification-gap other 1) `ZanshinFfiModule.zanshinFfiVersion()` keeps the pointer from `zanshin_ffi_version()` and never calls `zanshin_string_free`, against the caller-frees contract — verified (`zanshin_version.dart:15`, `bindings.dart:792`, `lib.rs:65-72`, `docs/ffi-abi.md:28`); pre-existing; with this run no production code calls it; the fix is in `zanshin_core`, which this run's Never list excludes; deferred and mirrored (grouped with blind 3).
  - `[false]` `[reject]` (intent 1) Removing `ZanshinFfiModule` from `main.dart`'s `@Component` reaches beyond `HomePage` into pre-11.3 code — the intent limits changes to Story 11.3's code "as far as an item needs"; `main.dart` is not 11.3's code, and the entry's one binding lost its one consumer through this fix, so it is the fix's orphan (CLAUDE.md "Surgical Changes"); runtime behaviour is unchanged (the provider was lazy and is now never built).
  - `[low]` `[reject]` (intent 2) No test asserts the item's property (no FFI version on `HomePage`, no call while building the home); compilation and grep enforce it — grouped with blind 1; rejected there.
  - `[false]` `[reject]` (intent 3) No commit and no `## Auto Run Result` in the reviewed state — both are written at finalize (fix commit `d96bb16`, then the spec commit).
  - `[false]` `[reject]` (intent 4) deferred-work.md's existing bullet is not marked resolved — grouped with blind 6; rejected there.
  - `[low]` `[reject]` (intent 5) The Problem statement overstates the cost ("per created home") — grouped with blind 2; rejected there.
  - `[false]` `[reject]` (intent 6) Nothing shows the gate ran — it did: the implementation run's `cargo make test` exited 0 (3 of 27 steps planned), and from the main session `flutter test` (423 passed), `dart analyze` and `dart format` in `app/` were clean and `cargo make test` exited 0.

## Design Notes

**Why `ZanshinFfiModule` leaves the component.** Before this change the module's one binding fed only `HomePage`; afterwards nothing in `MainComponent`'s graph asks for `ZanshinFfiVersion`, so the registration is an orphan of the fix (CLAUDE.md "Surgical Changes": remove what your change made unused) and would only add an unused-binding warning to inject's build output. `ZanshinDiagnosticsModule`'s `GetDiagnostics` was already unconsumed before this run — pre-existing, left alone. A future consumer (an About box, a diagnostics view) re-adds the module in one line.

**No visual check.** The rendered window is unchanged (the field was never read in `build`); the existing widget tests that pin the home's render are the witness, so no Marionette catalogue comparison applies.

## Verification

**Commands:**
- `dart run build_runner build --delete-conflicting-outputs` in `app/` -- succeeds; `main.inject.dart` no longer mentions `ZanshinFfiVersion`/`ZanshinFfiModule`.
- `flutter test` in `app/` -- all pass.
- `dart analyze --fatal-infos --fatal-warnings` and `dart format --output=none --set-exit-if-changed .` in `app/` -- clean.
- `cargo make test` (repo root, unpiped, main session; PATH with `~/development/sdks/flutter/bin` and `~/development/sdks/cargo/bin`, `CARGO_HOME=~/development/sdks/cargo`) -- exit 0.

## Auto Run Result

Status: done (2026-10-18). Blocking condition: none.

**Items handed to this closing run.**
1. **`HomePage` injects `ZanshinFfiVersion` and never reads it — fixed** (commit `d96bb16d5c5ec8db40f961648e79eda361acd31a`).
   - Verified first: the field was read nowhere; the generated `_HomePageFactory$Factory.create` filled it from a lazy singleton provider, so the first home of each app run made one `zanshin_ffi_version` FFI call for nothing (and kept the unfreed string, see the first deferral).
   - `HomePage` loses the parameter, the field and its `zanshin_core` import. `ZanshinFfiModule` leaves `MainComponent`'s `@Component` list, the orphan of the fix (its one binding had no other consumer). DI regenerated with build_runner; the two app tests stop passing the dummy.
   - The ledger's own follow-up ("drop it with the next change to the home (11.10)") is done here, so 11.10 no longer carries it.

**Summary.** One item, fixed: the project window's home no longer takes an FFI version it never used, and the app's DI graph no longer registers the module behind it. The window renders exactly as before; `ZanshinFfiModule`/`ZanshinFfiVersion` stay in `zanshin_core` for the native-asset smoke test and the extern fn's cross-FFI coverage witness.

**Files changed:**
- `app/lib/src/features/home/home_page.dart` — the `zanshinFfiVersion` parameter, field and the `zanshin_core` import removed.
- `app/lib/main.dart` — `ZanshinFfiModule` removed from the `@Component` list.
- `app/lib/main.inject.dart` — regenerated: no `zanshinFfiModule` create parameter, no `_ZanshinFfiVersion$Provider`, the home factory takes only the view-model factory (the rest is renumbered import aliases). `home_page.factory.dart` came out identical.
- `app/test/features/home/home_page_test.dart`, `app/test/features/app/zanshin_app_test.dart` — the dummy `() => 'test'` argument and the "fake FFI version" doc wording removed; every assertion unchanged.
- Tracking: this spec; `deferred-work.md` gets the section "Surfaced in the closing run of Story 11.3" (2 items).

**Review findings.** 14 findings (high 0, medium 0, low 9, false 5).
- **Patched:** none.
- **Deferred and mirrored, 2:**
  - `ZanshinFfiModule`'s wrapper never frees the Rust-allocated version string (low; pre-existing; the fix is in `zanshin_core`);
  - `GetDiagnostics` and `IconRegistry` stay registered and unconsumed, so build_runner warns twice (low; pre-existing).
- **Rejected, low:**
  - no test runs the generated `MainComponent` graph (pre-existing; the analyzer compiles the generated graph and the generator validates it, so a breakage fails loudly; a component test needs new fixtures);
  - the Problem statement's "one call per created home" is wrong — it was one call per app run (the fix edits this spec's intent contract; corrected here);
  - the Design Notes point a future consumer at `ZanshinFfiModule` although `GetDiagnostics` carries the same build stamp (spec edit; the deferral's follow-up says so);
  - AC 1's grep also hits the kept `native_asset_smoke_test.dart:12` (spec edit; that is its only hit).
- **False, 5:** the `main.dart` edit is the fix's orphan, not scope creep; the commit and this result are written at finalize; the ledger close is the loop's (2 rows); the gate ran.

**Follow-up review recommendation:** false — this pass patched nothing (0 high, 0 medium, 0 low).

**Verification:**
- `dart run build_runner build --delete-conflicting-outputs` in `app/` (implementation run): succeeded; only the two pre-existing unused-binding warnings (`GetDiagnostics`, `IconRegistry`); `main.inject.dart` no longer names `ZanshinFfiVersion` or `ZanshinFfiModule`.
- AC greps: `grep -n ZanshinFfiModule app/lib/main.dart app/lib/main.inject.dart` finds nothing; `grep -rn zanshinFfiVersion app/lib app/test` finds only `app/test/native_asset_smoke_test.dart:12`, the kept smoke test, and no `HomePage` reference.
- Main session: `flutter test` in `app/` — 423 passed (incl. `home_page_test.dart`, `zanshin_app_test.dart`, `native_asset_smoke_test.dart`); `dart analyze --fatal-infos --fatal-warnings` — no issues; `dart format --output=none --set-exit-if-changed .` — 0 changed.
- `cargo make test`: exit 0 in the implementation run (the change-aware plan ran 3 of 27 steps: test-flutter, test-dart-analyze, test-dart-format; no Rust or `zanshin_core` change, so no coverage), and exit 0 again from the main session on the same tree; `coverage-baseline.txt` unchanged.
- No visual check: the rendered window is unchanged; the home's widget tests pin its render.

**Residual risks:**
- The app's boot-time DI graph has no test; it was checked by compilation and codegen only, not by a launch of the app.
