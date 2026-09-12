---
title: 'marionette_flutter: route gestures and visibility to the element''s view'
type: 'bugfix'
created: '2026-09-12'
status: 'done'
baseline_revision: 'marionette_mcp (jj, implementation repo): change nuyorxlllxtxwozynywptxyuzoslxpny, commit 30c792f32bd50a65298755978770872b55e1601c; Zanshin (git, spec repo): ce80d6fd98e76d6adcc5c88339a7310ea2ec2273'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/docs/superpowers/specs/2026-09-12-marionette-multiview-fix-plan.md'
  - '{project-root}/docs/superpowers/specs/2026-09-12-marionette-multiview-findings.md'
warnings: ['oversized']
deferred:
  - summary: >-
      Coordinate-addressed gestures cannot target a specific window in a
      multi-window app, and no tool exposes a view selector.
    evidence: |-
      defaultViewId() returns the first entry of RendererBinding.renderViews
      (attach order), and tap/doubleTap/longPress/secondaryTap/pinchZoom by
      coordinates plus the coordinate swipe all use it. Neither the
      marionette.* extensions nor the MCP tool schemas expose a viewId or
      window argument, so with two windows open a coordinate gesture silently
      lands in whichever view attached first. Explicitly out of scope for this
      fix per the fix plan's Design section 5, which names it a PR follow-up.
    location: >-
      marionette_mcp/packages/marionette_flutter/lib/src/services/hit_test_utils.dart
    severity: medium
  - summary: >-
      Discovered elements report view-local bounds with no view identity, so
      bounds from a second window cannot be replayed as coordinates.
    evidence: |-
      ElementTreeFinder._extractElementData emits data['bounds'] from
      renderObject.localToGlobal, which is relative to the owning view, and a
      per-view data['visible'], but no viewId. With two windows rendered,
      elements from different views report overlapping coordinate ranges and
      are indistinguishable in the returned list, so an agent that reads
      bounds for an element in the non-first window and taps those
      coordinates has the gesture delivered to the other window.
    location: >-
      marionette_mcp/packages/marionette_flutter/lib/src/services/element_tree_finder.dart
    severity: medium
  - summary: >-
      Screencast and the binding still pick renderViews.first, so they show an
      arbitrary window in a multi-window app.
    evidence: |-
      screencast_service.dart (around lines 168 and 184) and
      marionette_binding.dart (around line 138) resolve the view as
      renderViews.first. Correct while exactly one view is rendered, arbitrary
      once more than one is. The fix plan's Design section 4 deliberately
      leaves them alone and names them a follow-up for true multi-window
      support.
    location: >-
      marionette_mcp/packages/marionette_flutter/lib/src/services/screencast_service.dart
    severity: low
---

<intent-contract>

## Intent

**Problem:** `GestureDispatcher` builds every pointer event without a `viewId`, so `PointerEvent.viewId` is `0` (the implicit view) and `RendererBinding.hitTestInView` finds no `RenderView` in an app whose content lives in a non-implicit view (Flutter windowing API, `runWidget` + `RegularWindow`); every tap/drag/pinch silently hits nothing while the tool reports success. Independently `ElementTreeFinder._isElementVisible` measures against `platformDispatcher.views.first`, so every element is reported `visible: false`.

**Approach:** Extract the view lookup `hit_test_utils.dart` already performs into two shared helpers (`viewIdOf(Element)`, `defaultViewId()`), thread the resolved `viewId` into every `Pointer*Event` the dispatcher builds, hand `ScrollSimulator` the scrollable's own view, and measure visibility against the element's own `View`.

## Boundaries & Constraints

**Always:**
- All code changes live in the sibling repo `/Users/ralph.bergmann/development/projects/privat/marionette_mcp`, package `packages/marionette_flutter` only.
- That repo is version-controlled with **jj** (colocated with git): use `jj status`/`jj diff`/`jj describe`/`jj new`/`jj bookmark`. Never `git commit`/`git add`/`git checkout`/`git stash` there.
- **No AI attribution anywhere in marionette_mcp** — no `Co-Authored-By`, no "generated with", no mention of Claude/AI in commit messages, changelog, code, comments or tests.
- Tests first: write the `FakeView` tests, run them, confirm they FAIL against the current code, then implement, then confirm green.
- Only APIs available since Flutter 3.10 (package pins `flutter: ">=3.27.0"`, CI runs 3.41.6 and 3.27.0); local toolchain is 3.48 master.
- `dart format` default 80 columns; the package has no `analysis_options.yaml`, so default `flutter analyze` lints apply.

**Block If:**
- The package gate cannot be made green without changing `packages/marionette_mcp` or `marionette_cli`.
- An existing single-view test can only be kept green by changing its expectations.

**Never:**
- No `viewId` parameter on MCP tools / extensions; no change to `packages/marionette_mcp` or the CLI (the wire protocol is unchanged).
- Do not touch `screencast_service.dart` or `marionette_binding.dart` (`renderViews.first` users stay as they are — follow-up, not this fix).
- Do not bump any `version:` and do not touch `version.g.dart`.
- Do not run Zanshin's `cargo make test`; do not modify anything under `Zanshin/app` or `Zanshin/packages`. Skip the plan's "Verification with Zanshin" and "Delivery" sections (the orchestrator does those).
- No `jj git push`, no PR.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Element gesture, content in non-implicit view | `tap(KeyMatcher('btn'))`, content mounted under `View(view: FakeView(viewId: 100))` | every dispatched `Pointer*Event` carries `viewId == 100`; the widget's `onTap` fires | No error expected |
| Coordinate gesture, content in non-implicit view | `tap(CoordinatesMatcher(x, y))`, only the fake view is rendered | events carry the first rendered view's id (100); the widget's callback fires | No error expected |
| Ordinary single-view app | any gesture, content in the implicit view | events carry the implicit view's id; behaviour unchanged, existing tests stay green | No error expected |
| No view resolvable | `renderViews` empty and `implicitView == null` | no pointer event is dispatched | throw a descriptive `StateError` instead of silently dispatching to view 0 |
| Visibility inside a sized non-implicit view | element inside the fake view, within its logical size | `visible: true` | — |
| Visibility beyond the view bounds | element positioned past the fake view's logical size | `visible: false` | unmeasurable view (none resolvable / throw) keeps the existing permissive `true` |

</intent-contract>

## Code Map

Paths below are relative to `/Users/ralph.bergmann/development/projects/privat/marionette_mcp/packages/marionette_flutter`.

- `lib/src/services/hit_test_utils.dart` — home of the new helpers. `isElementHittableAt` (L25-58) already does the exact lookup to extract: `element.findAncestorWidgetOfExactType<View>()?.view.viewId ?? platformDispatcher.implicitView?.viewId` (L35-40), then `WidgetsBinding.instance.hitTestInView(result, absoluteOffset, viewId)`.
- `lib/src/services/gesture_dispatcher.dart` — every `Pointer*Event` constructor call site, none passing `viewId`: `_dispatchTapAtPosition` (L64), `_dispatchMouseTapAtPosition` (L119), `_dispatchLongPressAtPosition` (L247), `_dispatchPinchZoomAtPosition` (L354), `drag` (L440, public — called by `ScrollSimulator`), `_dispatchDoubleTapAtPosition` (L197, delegates to `_dispatchTapAtPosition`). Element paths go through `_globalCenterOf(element)` (L49) — resolve `viewIdOf` right next to it. Coordinate fast paths: `tap` L28, `_mouseTap` L106, `doubleTap` L176, `longPress` L226, `pinchZoom` L330. `swipe` (L282) resolves an element then calls `drag`. Dispatch funnel: `_handlePointerEventRecord` (L486).
- `lib/src/services/scroll_simulator.dart` — `_dragUntilVisible` calls `_gestureDispatcher.drag(globalPosition, to)` at L337; `scrollable` is in scope there. Already imports `hit_test_utils.dart`.
- `lib/src/services/element_tree_finder.dart` — `_isElementVisible(RenderObject?)` (L173-207) uses `platformDispatcher.views.first` (L190-193); its only caller is `_extractElementData` at L120, which has the `Element` in hand. `catch (_) => true` fallback at L201.
- `test/gesture_dispatcher_test.dart` (28k) — conventions to mirror: `const _timeout = Timeout(Duration(seconds: 10))`, `GestureBinding.instance.pointerRouter.addGlobalRoute(events.add)` + `addTearDown(... removeGlobalRoute ...)`, and `await tester.runAsync(() => dispatcher.X(...))` (runAsync is required — the dispatcher awaits real `Future.delayed`).
- `test/element_tree_finder_test.dart`, `test/scroll_simulator_test.dart`, `test/widget_finder_hittable_test.dart` — existing suites that must stay green.
- `/Users/ralph.bergmann/development/sdks/flutter/packages/flutter/test/widgets/multi_view_testing.dart` — read-only reference; the `FakeView extends TestFlutterView` snippet to model the helper on (verified present in the local SDK).
- **`packages/marionette_flutter/CHANGELOG.md` is a symlink to the repo-root `CHANGELOG.md`** (verified: `CHANGELOG.md -> ../../CHANGELOG.md`), not a hand-synced copy. Editing the root file therefore satisfies "both" — **do not** replace the symlink with a regular file.
- `packages/marionette_flutter/pubspec.yaml` — `version: 0.6.0`, `flutter: ">=3.27.0"`, `sdk: ">=3.6.0"`. Read-only here.

## Tasks & Acceptance

**Execution:**
- `test/multi_view_test_helpers.dart` -- NEW: add `FakeView extends TestFlutterView` (`viewId = 100` default, `render`/`updateSemantics` no-ops), modelled on the SDK reference -- lets tests mount content in a non-implicit view, the exact shape of the windowing app.
- `test/gesture_dispatcher_test.dart` -- add a `multi-view` group: for each of `tap`, `doubleTap`, `longPress`, `secondaryTap`, `pinchZoom`, `swipe` (element form) and `drag` (coordinate form), mount via `tester.pumpWidget(wrapWithView: false, View(view: fakeView, child: …))` and assert through a global pointer route that **every** dispatched event has `viewId == fakeView.viewId`; `tap` by `CoordinatesMatcher` **and** by `KeyMatcher` must additionally assert the widget callback actually fired -- these are the red tests that prove the bug.
- `test/scroll_simulator_test.dart` -- add one `scrollUntilVisible` case inside the fake view reaching a target below the fold -- covers the `ScrollSimulator` → `drag` path.
- `test/element_tree_finder_test.dart` -- add two cases in the fake view: an interactive widget within the view's logical size reports `visible: true`, one beyond it reports `visible: false`.
- `lib/src/services/hit_test_utils.dart` -- extract `int? viewIdOf(Element)` and add `int? defaultViewId()` (first `WidgetsBinding.instance.renderViews` entry's `flutterView.viewId`, else `implicitView?.viewId`); make `isElementHittableAt` use `viewIdOf` -- one resolver shared by discovery and dispatch.
- `lib/src/services/gesture_dispatcher.dart` -- give every `_dispatch…AtPosition` a `required int viewId` and the public `drag` an optional `int? viewId` defaulting to `defaultViewId()`; pass `viewId:` to every `Pointer*Event`; element paths resolve `viewIdOf(element)`, coordinate paths `defaultViewId()`; throw a descriptive `StateError` when the resolver yields `null`.
- `lib/src/services/scroll_simulator.dart` -- pass `viewId: viewIdOf(scrollable)` in the `_dragUntilVisible` `drag` call.
- `lib/src/services/element_tree_finder.dart` -- change `_isElementVisible` to take the `Element`, resolve its `View` (ancestor `View` → `implicitView`), and measure against `view.physicalSize / view.devicePixelRatio`; keep the permissive fallback when nothing is measurable.
- `CHANGELOG.md` (repo root — reached by both paths via the symlink) -- add one user-facing line under `# Unreleased`, in the voice of the existing `- Fix …` entries, with no AI attribution.

**Acceptance Criteria:**
- Given the new multi-view tests and the unmodified `lib/`, when `flutter test --no-pub` runs, then the new tests fail (events carry `viewId: 0` / callbacks never fire / `visible: false`) — recorded before any `lib/` change.
- Given the completed fix, when `flutter test --no-pub` runs from `packages/marionette_flutter`, then all tests pass, including every pre-existing suite unchanged.
- Given the completed fix, when `flutter analyze --fatal-infos lib` and `dart format --set-exit-if-changed lib` run from `packages/marionette_flutter`, then both exit 0.
- Given the change is complete and green, when version control is inspected, then `jj status` in marionette_mcp shows only the intended files, no `version:` or `version.g.dart` change, and `packages/marionette_flutter/CHANGELOG.md` is still a symlink.

## Spec Change Log

No spec amendments were needed: the review pass produced no `intent_gap` and no `bad_spec` findings, so the code was never re-derived.

## Review Triage Log

### 2026-09-12 — Review pass
- intent_gap: 0
- bad_spec: 0
- patch: 4: (high 0, medium 0, low 4)
- defer: 3: (high 0, medium 2, low 1)
- reject: 12: (high 0, medium 1, low 11)
- addressed_findings:
  - `[low]` `[patch]` The plan's "one view resolver shared by discovery and dispatch" did not literally hold: `_isElementVisible` repeated the `findAncestorWidgetOfExactType<View>()` walk because it needs the `FlutterView` object, not the id — and the two lookups had already drifted in their fallback. Added `FlutterView? viewOf(Element)` to `hit_test_utils.dart`, made `viewIdOf` a one-liner over it, and pointed `_isElementVisible` at it (plus the `dart:ui` import the named return type needs).
  - `[low]` `[patch]` `defaultViewId()` used a `for` loop that returns on its first iteration, which reads like a bug. Replaced with an explicit `isNotEmpty`/`first` check plus a comment naming why `firstOrNull` is not used (it lives in `package:collection`, not a dependency here).
  - `[low]` `[patch]` The `pinchZoom`, element `swipe` and coordinate `drag` multi-view cases asserted only the events' `viewId` — routing, not delivery — and the `drag` case built a keyed target it never used. Gave `_gestureTarget` optional `onPanUpdate`/`onScaleUpdate` callbacks, asserted each of those three gestures is actually recognised inside the non-implicit view, and dropped the unused key.
  - `[low]` `[patch]` The `_probeAt` dartdoc in `element_tree_finder_test.dart` claimed `Transform.translate` changes only painting and leaves the element's place in the hit-test path. `RenderTransform` transforms hit testing too. Rewrote the comment to state what actually holds, including the test's reliance on hit tests not being clipped to the view bounds.

## Design Notes

`defaultViewId()` deliberately prefers the first **rendered** view over the implicit one: in a normal app they are the same view, so behaviour is unchanged; in a windowing app the implicit view exists but is never rendered, and the first `renderViews` entry is the window. `renderViews` is a `Map.values`, so its order is insertion order and deterministic.

Avoid `Iterable.firstOrNull` — it comes from `package:collection`, which this package does not depend on. Use an explicit emptiness check:

```dart
int? defaultViewId() {
  for (final renderView in WidgetsBinding.instance.renderViews) {
    return renderView.flutterView.viewId;
  }
  return WidgetsBinding.instance.platformDispatcher.implicitView?.viewId;
}
```

`renderObject.localToGlobal` is already relative to the owning `RenderView`, so measuring against that same view's logical size is what makes the visibility comparison self-consistent.

## Verification

**Commands** (all run from `/Users/ralph.bergmann/development/projects/privat/marionette_mcp/packages/marionette_flutter`):
- `flutter test --no-pub` (before touching `lib/`) -- expected: the new multi-view tests FAIL; record which ones.
- `flutter analyze --fatal-infos lib` -- expected: `No issues found!`, exit 0.
- `dart format --set-exit-if-changed lib` -- expected: exit 0 (format first if needed).
- `flutter test --no-pub` (after the fix) -- expected: all tests pass, exit 0.
- `jj status` (in `/Users/ralph.bergmann/development/projects/privat/marionette_mcp`) -- expected: only the intended `lib/`, `test/` and `CHANGELOG.md` paths listed.

## Auto Run Result

Status: done
Blocking condition: none

### Summary

`marionette_flutter` now routes pointer gestures to, and measures visibility against, the view an element actually lives in. A single resolver in `hit_test_utils.dart` answers the element-to-view question for discovery, dispatch and visibility; `GestureDispatcher` stamps a `viewId` on every `Pointer*Event` it builds; `ScrollSimulator` hands `drag` the scrollable's own view; and `ElementTreeFinder` measures against the element's view instead of `platformDispatcher.views.first`. In an app rendering through the desktop windowing API — where the implicit view exists but is never rendered — every pointer tool previously hit nothing while reporting success, and every element was reported `visible: false`. The MCP wire protocol, the `marionette_mcp` package and the CLI are untouched.

### Files changed (all in `/Users/ralph.bergmann/development/projects/privat/marionette_mcp`)

- `packages/marionette_flutter/lib/src/services/hit_test_utils.dart` -- new `viewOf` / `viewIdOf` / `defaultViewId` resolvers; `isElementHittableAt` now calls the shared helper.
- `packages/marionette_flutter/lib/src/services/gesture_dispatcher.dart` -- every `_dispatch…AtPosition` takes a `required int viewId`, public `drag` takes optional `viewId` defaulting to the first rendered view; every pointer event carries it; an unresolvable view throws a descriptive `StateError` instead of silently targeting view 0.
- `packages/marionette_flutter/lib/src/services/element_tree_finder.dart` -- `_isElementVisible` takes the `Element` and measures `view.physicalSize / view.devicePixelRatio` of that element's own view.
- `packages/marionette_flutter/lib/src/services/scroll_simulator.dart` -- `_dragUntilVisible` passes `viewId: viewIdOf(scrollable)`.
- `packages/marionette_flutter/test/multi_view_test_helpers.dart` (new) -- `FakeView extends TestFlutterView`, modelled on Flutter's own multi-view test helper.
- `packages/marionette_flutter/test/no_implicit_view_test.dart` (new) -- bindings that report no view at all; pins the `StateError` refusal and that nothing is dispatched.
- `packages/marionette_flutter/test/gesture_dispatcher_test.dart` -- multi-view group covering tap (coordinates and key), doubleTap, longPress, secondaryTap, pinchZoom, swipe and coordinate drag.
- `packages/marionette_flutter/test/element_tree_finder_test.dart` -- visibility inside and beyond a non-implicit view's bounds.
- `packages/marionette_flutter/test/scroll_simulator_test.dart` -- `scrollUntilVisible` in a non-implicit view; the pre-existing `drag` test doubles pick up the new optional parameter.
- `CHANGELOG.md` -- one line under `# Unreleased`. Note: `packages/marionette_flutter/CHANGELOG.md` is a symlink to this file, so both paths are updated by the single edit; the symlink was deliberately left intact.

### Review findings breakdown

- Patches applied: 4 (all low severity) -- shared `viewOf` resolver, clearer `defaultViewId`, delivery assertions for pinchZoom/swipe/coordinate-drag, corrected `_probeAt` comment. See the Review Triage Log.
- Items deferred: 3 -- multi-window view targeting on the tools, missing view identity on reported element bounds, `renderViews.first` in screencast/binding. All three are excluded from this fix by the plan's Design sections 4 and 5.
- Items rejected: 12 -- chiefly the suggestion to make `viewIdOf` fall back to `defaultViewId()` (contradicts the plan's stated resolver and is unreachable: an element with an attached render object always sits below a `View`), the `visible: true` fallback asymmetry (intent-prescribed and unreachable), doc-site updates the plan does not ask for, and several speculative or unreachable edge cases.
- Follow-up review recommended: **false** (patched severities: high 0, medium 0, low 4; no high-severity patch, and the score `3 x medium (0) + 1 x low (4)` = 4, below the threshold of 5).

### Verification performed

Run from `packages/marionette_flutter` after the patches:

- `flutter analyze --fatal-infos lib` -> `No issues found!`, exit 0. Also run on `test` -> `No issues found!`, exit 0.
- `dart format --set-exit-if-changed lib` -> exit 0.
- `flutter test --no-pub` -> `All tests passed!`, 208 tests, exit 0.
- `jj status` -> exactly the ten intended paths; no `version:` or `version.g.dart` change; the package `CHANGELOG.md` symlink intact; three `pubspec.lock` files dirtied by pub re-resolution under the local Flutter 3.48 were restored with `jj restore`.
- Attribution check: `jj diff --git | grep -icE 'claude|anthropic|co-authored|generated with'` -> 0.
- Red-before-green was confirmed before the fix: the eight new gesture assertions failed with `Expected: <100> Actual: <0>` and both visibility cases failed, while every pre-existing test in those files stayed green. The `StateError` test was separately shown non-vacuous by mutating the guard to `return viewId ?? 0`, which makes it fail.

### Residual risks

- Only the local Flutter 3.48 master toolchain was exercised. CI also runs 3.41.6 and 3.27.0; every API used (`PointerEvent.viewId`, `RendererBinding.renderViews`, `pumpWidget(wrapWithView:)`, `TestFlutterView.physicalSize`) predates 3.27, but those runs were not performed here.
- `GestureDispatcher.drag` gained an optional named parameter. Callers are unaffected; subclasses that override `drag` must add it (the four in-repo test doubles did). `GestureDispatcher` is not exported from the package barrel, so out-of-repo overriders would have had to import a `src/` path.
- The live-app verification from the plan (running Zanshin against the patched package over the MCP server) was deliberately skipped here and remains the orchestrator's step; no test in this change exercises the real windowing-API surface.
- `renderViews` iteration order decides which window a coordinate gesture reaches when more than one is rendered. Deferred, see frontmatter.
