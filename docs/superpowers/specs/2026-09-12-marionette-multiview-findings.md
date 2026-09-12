# marionette_flutter: taps and visibility miss non-implicit views

Findings from 2026-09-12, collected to prepare an upstream fix for
[leancodepl/marionette_mcp](https://github.com/leancodepl/marionette_mcp).

## Summary

In a Flutter app that renders through the desktop windowing API — `runWidget` +
`WindowManager`/`RegularWindow`, no content in the implicit view — `marionette_flutter`
0.6.0 connects, discovers elements and takes screenshots, but every `tap` (by
coordinates, text or key) reports success and changes nothing, and every element is
reported as `visible: false`.

Cause: the gesture dispatcher builds its pointer events without a `viewId`, so they
target view 0 (the implicit view), and the visibility check measures against
`platformDispatcher.views.first`, which is view 0 as well. The app's only `RenderView`
belongs to view 1, the window. Element discovery is unaffected because it already
resolves the element's own `View`.

## Environment

- `marionette_flutter` 0.6.0, `marionette_mcp` 0.6.0 (latest on pub.dev on 2026-09-12)
- Flutter 3.48.0-1.0.pre-713, channel master, framework `c0f80388fc` (2026-09-11),
  Dart 3.14.0-217.0.dev, `flutter config --enable-windowing`
- macOS 26 (Darwin 25.6.0)
- App: Zanshin `app/` with `MarionetteBinding.ensureInitialized()` in debug builds.
  Every window is created from Dart (`RegularWindowController`), the runner's engine is
  view-less. A temporary `PlatformDispatcher.onPointerDataPacket` wrapper logged
  `views=[0, 1] renderViews=[1]`: the implicit view exists but is never rendered.

## Reproduction

1. `cd app && flutter run -d macos`; take the `A Dart VM Service on macOS is available
   at: http://127.0.0.1:<port>/<token>/` line and connect Marionette to
   `ws://127.0.0.1:<port>/<token>/ws`.
2. `get_interactive_elements` → 32 elements with correct window-local bounds, all of
   them `visible: false`.
3. `tap` `{x: 36, y: 82}` (centre of the first `YaruCheckbox`) → "Tapped element
   matching …", but `take_screenshots` before and after are identical.
4. `tap` `{text: "YaruCheckButton"}` → same result.
5. Control: native clicks on the same widgets do toggle them (verified with an
   in-process `NSApp.sendEvent` probe the same day), so the widgets themselves are fine.

## Root cause

### Taps carry no `viewId`

`lib/src/services/gesture_dispatcher.dart`, `_dispatchTapAtPosition` — and likewise
`_dispatchMouseTapAtPosition`, `_dispatchLongPressAtPosition`,
`_dispatchPinchZoomAtPosition` and `drag`:

```dart
PointerAddedEvent(position: globalPosition, device: _kDeviceId),
PointerDownEvent(pointer: pointerId, position: globalPosition, device: _kDeviceId),
```

No `viewId:` is passed, so `PointerEvent.viewId` is 0. `_handlePointerEventRecord` hands
the records to `GestureBinding.instance.handlePointerEvent`, which hit-tests through
`RendererBinding.hitTestInView(result, position, event.viewId)`:

```dart
// flutter/lib/src/rendering/binding.dart
void hitTestInView(HitTestResult result, Offset position, int viewId) {
  _viewIdToRenderView[viewId]?.hitTest(result, position: position);
  super.hitTestInView(result, position, viewId);
}
```

There is no `RenderView` for view 0, so the hit-test path contains only the binding
itself and the event reaches no widget. The tool still answers "Tapped" because the
dispatcher never checks whether anything was hit.

`lib/src/services/hit_test_utils.dart` (`isElementHittable`) already does the right
thing for discovery:

```dart
final view = element.findAncestorWidgetOfExactType<View>();
final viewId = view?.view.viewId ??
    WidgetsBinding.instance.platformDispatcher.implicitView?.viewId;
```

The dispatcher simply does not reuse that lookup.

### Visibility measures the wrong view

`lib/src/services/element_tree_finder.dart`, `_isElementVisible`:

```dart
final screenSize = WidgetsBinding.instance.platformDispatcher.views.first.physicalSize /
    WidgetsBinding.instance.platformDispatcher.views.first.devicePixelRatio;
```

`views.first` is the implicit view 0. It is never rendered here, so its size does not
describe the window and every element is reported off-screen.

## Proposed fix

1. **Thread a `viewId` through `GestureDispatcher`.**
   - Element-based paths: resolve `element.findAncestorWidgetOfExactType<View>()?.view.viewId
     ?? implicitView?.viewId` — extract the lookup from `hit_test_utils.dart` into a shared
     helper so discovery and dispatch agree.
   - Coordinate paths (`CoordinatesMatcher`): default to the first rendered view,
     `WidgetsBinding.instance.renderViews.first.flutterView.viewId`, falling back to the
     implicit view when `renderViews` is empty. An optional explicit `viewId` on the
     matcher / MCP tool would let multi-window apps pick a window.
   - Pass `viewId: viewId` to every `PointerAddedEvent`, `PointerDownEvent`,
     `PointerMoveEvent`, `PointerUpEvent` and `PointerRemovedEvent`; all constructors
     accept it.
2. **`_isElementVisible`:** resolve the element's `View` the same way and measure against
   `view.physicalSize / view.devicePixelRatio`. `renderObject.localToGlobal` is already
   relative to that view's `RenderView`, so the comparison becomes consistent.
3. **Audit the other `views.first` / `renderViews.first` assumptions:**
   `screencast_service.dart` (lines ~168 and ~184) and `marionette_binding.dart` (line ~73)
   use `renderViews.first`. That works while exactly one view is rendered, but picks an
   arbitrary window in a multi-window app.
4. **Tests:** a widget test whose content lives in a non-implicit `View` (a
   `TestWidgetsFlutterBinding` with a second `FlutterView`, or `runWidget` with an explicit
   `View`) asserting that `tap` reaches a `GestureDetector` inside that view, and that
   `findInteractiveElements` reports it `visible: true`.

## Also observed, not investigated

- `get_logs` answered "Server error" once during the session.

## What Zanshin changed for this check

- `app/lib/main.dart`: `MarionetteBinding.ensureInitialized()` when `kDebugMode`, else
  `WidgetsFlutterBinding.ensureInitialized()`.
- `app/pubspec.yaml`: `marionette_flutter: ^0.6.0`.

Until the fix lands, Marionette remains useful here for element discovery and
screenshots; real-input verification goes through the in-process click injector
described in the session notes.
