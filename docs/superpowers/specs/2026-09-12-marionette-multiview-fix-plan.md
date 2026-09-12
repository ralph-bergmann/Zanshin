# marionette_flutter: route gestures and visibility to the element's view — fix plan

Intent file for a `bmad-build-auto` run. Companion of
[2026-09-12-marionette-multiview-findings.md](2026-09-12-marionette-multiview-findings.md),
which holds the reproduction and root-cause evidence. Read that first.

## Where the code lives

- Repository: `/Users/ralph.bergmann/development/projects/privat/marionette_mcp` — Ralph's fork of
  [leancodepl/marionette_mcp](https://github.com/leancodepl/marionette_mcp), checked out with
  **jj (colocated with git)**, working copy `@` empty on top of `main` (`7e825235`).
  Use `jj` for version control there (`jj status`, `jj diff`, `jj describe`, `jj new`), never
  `git commit`/`git checkout`. No commit signing is configured for jj in that repo.
- Package to change: `packages/marionette_flutter` (the in-app side). The MCP server package
  `packages/marionette_mcp` and the CLI need no change: the wire protocol stays the same.
- Local toolchain: Flutter `3.48.0-1.0.pre-713` (master) on `PATH`; the repo pins `3.41.6` via
  `.fvmrc` for CI and also analyzes/tests against `3.27.0` (`.github/workflows/ci.yaml`). Every
  API this fix needs (`PointerEvent.viewId`, `RendererBinding.renderViews`, `View`,
  `pumpWidget(wrapWithView:)`, `TestFlutterView`) exists since Flutter 3.10, so no new
  dependency or SDK bump.
- Gate (mirrors CI, run from `packages/marionette_flutter`):
  `flutter analyze --fatal-infos lib`, `dart format --set-exit-if-changed lib`,
  `flutter test --no-pub`.

## Bug in one paragraph

`GestureDispatcher` builds every `PointerAddedEvent` / `PointerDownEvent` / `PointerMoveEvent` /
`PointerUpEvent` / `PointerRemovedEvent` without `viewId`, so `PointerEvent.viewId` is `0`
(the implicit view). `GestureBinding.handlePointerEvent` hit-tests through
`RendererBinding.hitTestInView(result, position, event.viewId)`, which looks up
`_viewIdToRenderView[viewId]`. In an app whose content lives in a non-implicit view (Flutter
windowing API, `runWidget` + `RegularWindow` → `View(view: controller.rootView, …)`) there is no
`RenderView` for view 0, so nothing is hit and the tool still reports success. Independently,
`ElementTreeFinder._isElementVisible` measures against `platformDispatcher.views.first` (view 0),
so every element is `visible: false`. Element discovery is correct because `isElementHittable`
already resolves the element's own `View`.

## Which tools are affected (verified by reading the dispatch path)

All pointer gestures funnel through `GestureDispatcher._handlePointerEventRecord` with events
that carry no `viewId`, so **every** pointer-based tool misses non-implicit views:

| Tool | Path in `gesture_dispatcher.dart` |
|---|---|
| `tap` | `_dispatchTapAtPosition` |
| `double_tap` | `_dispatchDoubleTapAtPosition` → `_dispatchTapAtPosition` ×2 |
| `long_press` | `_dispatchLongPressAtPosition` |
| `secondary_tap` | `_dispatchMouseTapAtPosition` |
| `swipe` (element and coordinate form) | `swipe` → `drag` / `drag` |
| `pinch_zoom` | `_dispatchPinchZoomAtPosition` |
| `scroll_to` | `ScrollSimulator._dragUntilVisible` → `GestureDispatcher.drag` |

Not affected (no pointer events): `enter_text` (`EditableTextState.updateEditingValue`),
`press_key` (`HardwareKeyboard`), `press_back_button`, `set_device_config`,
`get_interactive_elements` (except the `visible` flag), `take_screenshots`, `get_logs`.

## Design

1. **One view resolver, shared by discovery and dispatch.** Extract the lookup that
   `hit_test_utils.dart` already does into a helper in that file:
   - `int? viewIdOf(Element element)` → `element.findAncestorWidgetOfExactType<View>()?.view.viewId
     ?? WidgetsBinding.instance.platformDispatcher.implicitView?.viewId`.
   - `int? defaultViewId()` → `WidgetsBinding.instance.renderViews.firstOrNull?.flutterView.viewId
     ?? WidgetsBinding.instance.platformDispatcher.implicitView?.viewId`. For a normal app this
     is the implicit view (unchanged behaviour); for a windowing app it is the first rendered
     window. `renderViews` is `Map.values`, so the order is insertion order and deterministic.
   - `isElementHittableAt` uses `viewIdOf`.
2. **`GestureDispatcher` threads `viewId` into every pointer event.**
   - Every `_dispatch…AtPosition` and `drag` take a `required int viewId` (or `int? viewId` on
     the public `drag`, defaulting to `defaultViewId()`), and pass `viewId: viewId` to each
     `Pointer*Event` constructor.
   - Element paths resolve `viewIdOf(element)` next to `_globalCenterOf(element)`. Coordinate
     paths (`CoordinatesMatcher`, coordinate `swipe`) use `defaultViewId()`.
   - If the resolver returns `null` (no view at all), throw a descriptive `StateError` rather
     than silently dispatching to view 0.
   - `ScrollSimulator._dragUntilVisible` passes `viewIdOf(scrollable)` to `drag`.
3. **`ElementTreeFinder._isElementVisible` measures the element's own view.** Take the
   `Element` (not only the `RenderObject`), resolve the `View` the same way, and compare against
   `view.physicalSize / view.devicePixelRatio`. `localToGlobal` is already relative to that
   view's `RenderView`. Keep the existing `catch (_) => true` fallback.
4. **Leave the other `renderViews.first` users alone** (`screencast_service.dart:168/184`,
   `marionette_binding.dart:138`): they pick the first rendered view, which is exactly the
   behaviour `defaultViewId()` now shares. Mention them in the PR as a follow-up for true
   multi-window support, do not change them here.
5. **No new MCP parameter.** An explicit `viewId` argument on the tools (to pick a window in a
   multi-window app) is out of scope for this fix; note it as a follow-up in the PR text.
6. **Changelog.** Add one line under `# Unreleased` in **both** `CHANGELOG.md` (repo root) and
   `packages/marionette_flutter/CHANGELOG.md` — the two files are identical copies and are kept
   in sync by hand. Do not bump any `version:` and do not touch `version.g.dart`.

## Tests (write them first, watch them fail on view 0, then fix)

Test helper `packages/marionette_flutter/test/multi_view_test_helpers.dart`, modelled on
Flutter's own `packages/flutter/test/widgets/multi_view_testing.dart`:

```dart
class FakeView extends TestFlutterView {
  FakeView(FlutterView view, {this.viewId = 100})
      : super(view: view,
              platformDispatcher: view.platformDispatcher as TestPlatformDispatcher,
              display: view.display as TestDisplay);
  @override final int viewId;
  @override void render(Scene scene, {Size? size}) {}
  @override void updateSemantics(SemanticsUpdate update) {}
}
```

Mount content in that view with
`tester.pumpWidget(wrapWithView: false, View(view: FakeView(tester.view), child: …))`, so the
implicit view has no `RenderView` — the same shape as the windowing app.

- `gesture_dispatcher_test.dart`: for **each** of `tap`, `doubleTap`, `longPress`,
  `secondaryTap`, `pinchZoom`, `swipe` (element form), `drag` (coordinate form): a
  `GestureDetector` (or `Listener`) inside the fake view records the callback, and a
  `pointerRouter.addGlobalRoute` capture asserts every dispatched event has
  `viewId == fakeView.viewId`. At least `tap` by `CoordinatesMatcher` **and** by `KeyMatcher`
  must assert the callback actually fired. Existing single-view tests stay green.
- `scroll_simulator_test.dart`: one `scrollUntilVisible` case inside the fake view reaches a
  target below the fold.
- `element_tree_finder_test.dart`: an interactive widget inside the fake view is reported with
  `visible: true`; one placed beyond the view's logical size is `visible: false`.
- `widget_finder_hittable_test.dart`: unchanged behaviour, still green (guards the extracted
  helper).

## Verification with Zanshin (manual, after the package tests pass)

1. In `Zanshin/app/pubspec.yaml` add a **temporary, uncommitted** override:
   ```yaml
   dependency_overrides:
     marionette_flutter:
       path: ../../marionette_mcp/packages/marionette_flutter
   ```
   then `flutter pub get` in `app/`.
2. `flutter run -d macos` from `app/`, connect the `marionette` MCP server to the printed VM
   service URI (`ws://127.0.0.1:<port>/<token>/ws`).
3. `get_interactive_elements` → elements report `visible: true`.
4. `tap` `{x: 36, y: 82}` and `tap` `{text: "YaruCheckButton"}` → `take_screenshots` before and
   after differ (checkbox toggles). Then one `double_tap`, one `long_press`, one `swipe` on a
   suitable widget to confirm the other paths.
5. Remove the override, `flutter pub get` again, confirm `git status` shows no pubspec change.

## Delivery

- jj: `jj describe -m "<message>"` on `@`, then `jj new`. Bookmark
  `fix/multi-view-gestures` on the commit; push with
  `jj git push --bookmark fix/multi-view-gestures --allow-new` to `origin`
  (`ralph-bergmann/marionette_mcp`) **only after Ralph confirms**.
- PR against `leancodepl/marionette_mcp` `main` from `ralph-bergmann:fix/multi-view-gestures`;
  body: the summary above, the affected-tools table, the follow-ups (multi-window
  `screencast`/`viewport` picks, optional `viewId` tool argument, dispatcher not reporting an
  empty hit test).
