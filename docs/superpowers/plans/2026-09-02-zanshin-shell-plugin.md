# zanshin_shell Federated Plugin Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An endorsed federated Flutter plugin (`zanshin_shell`) providing a bidirectional macOS platform channel — macOS→Flutter: system brightness (day/night) + accent color as a live stream; Flutter→macOS: window drag, titlebar double-click action, and a per-window appearance override — plus a `WindowDragArea` widget, wired into the app (theme in `zanshin_app.dart`, drag on the AppBar) and replacing `window_manager` entirely.

**Architecture:** Three flat packages under `packages/` (the pub workspace glob `packages/*` picks them up automatically): `zanshin_shell` (app-facing API + widget, endorses the macOS package), `zanshin_shell_platform_interface` (types + `PlatformInterface` contract), `zanshin_shell_macos` (Dart `MethodChannel` implementation registered via `dartPluginClass` + Swift `FlutterPlugin` via `pluginClass`). One `MethodChannel("zanshin_shell")` is used in both directions: Dart→Swift via `invokeMethod`, Swift→Dart via `invokeMethod("onThemeChanged", …)` into a Dart `setMethodCallHandler`.

**Tech Stack:** Flutter (master 3.48 pre), Dart 3.14, `plugin_platform_interface`, Swift/AppKit (KVO on `NSApp.effectiveAppearance`, `DistributedNotificationCenter`, `NSWindow.performDrag`), yaru 10.2.0 (`createYaruLightTheme(primaryColor:)`).

## Global Constraints

- Every new Dart/Swift file starts with `// SPDX-License-Identifier: MIT` (repo convention).
- New package pubspecs MUST contain `resolution: workspace` (repo is a pub workspace; root glob `packages/*` already matches flat packages — do NOT nest packages a level deeper).
- Comments/docs in English; match repo style (explain constraints, not narration).
- Commits: `git commit --no-gpg-sign`, message ends with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- `cargo make test` is the definition of done (Task 7). Never lower `coverage-baseline.txt` (it is Rust-only and must not change here).
- Simplicity first: no Windows/Linux stubs, no features beyond this plan.
- The Swift side must NOT touch `NSApp.appearance` (that would corrupt Flutter's own `platformBrightness`); the appearance override is per-window (`window.appearance`).
- Do not run `flutter run` interactively; use `flutter build macos --debug` for native compile verification.
- Do not modify `app/macos/Runner/MainFlutterWindow.swift` (its `DragInterceptorView` stays — it is what routes titlebar mouse events to Flutter).

---

### Task 1: `zanshin_shell_platform_interface` package

**Files:**
- Create: `packages/zanshin_shell_platform_interface/pubspec.yaml`
- Create: `packages/zanshin_shell_platform_interface/analysis_options.yaml`
- Create: `packages/zanshin_shell_platform_interface/lib/zanshin_shell_platform_interface.dart`
- Create: `packages/zanshin_shell_platform_interface/lib/src/shell_theme.dart`
- Create: `packages/zanshin_shell_platform_interface/lib/src/zanshin_shell_platform.dart`
- Test: `packages/zanshin_shell_platform_interface/test/zanshin_shell_platform_test.dart`

**Interfaces:**
- Produces: `ShellTheme{Brightness brightness, Color accentColor}`, `enum WindowAppearance {light, dark, system}`, `abstract class ZanshinShellPlatform extends PlatformInterface` with `instance` getter/setter and the five members below. Tasks 2 and 4 consume these exact names.

- [x] **Step 1: pubspec + analysis options**

`pubspec.yaml`:
```yaml
name: zanshin_shell_platform_interface
description: Platform interface for the zanshin_shell plugin (macOS shell integration for Zanshin).
version: 0.1.0
publish_to: 'none'

environment:
  sdk: ^3.14.0-143.0.dev
  flutter: ^3.48.0-1.0.pre-295
resolution: workspace

dependencies:
  flutter:
    sdk: flutter
  plugin_platform_interface: ^2.1.8

dev_dependencies:
  flutter_lints: ^6.0.0
  flutter_test:
    sdk: flutter
```

`analysis_options.yaml`:
```yaml
include: package:flutter_lints/flutter.yaml
```

- [x] **Step 2: Write the failing test**

`test/zanshin_shell_platform_test.dart`:
```dart
// SPDX-License-Identifier: MIT

import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:zanshin_shell_platform_interface/zanshin_shell_platform_interface.dart';

final class _FakePlatform extends ZanshinShellPlatform {
  _FakePlatform() : super.forTesting();
}

final class _NotMockPlatform extends ZanshinShellPlatform
    with MockPlatformInterfaceMixin {
  _NotMockPlatform() : super.forTesting();
}

void main() {
  test('ShellTheme value equality and toString', () {
    const a = ShellTheme(
        brightness: Brightness.dark, accentColor: Color(0xFF007AFF));
    const b = ShellTheme(
        brightness: Brightness.dark, accentColor: Color(0xFF007AFF));
    const c = ShellTheme(
        brightness: Brightness.light, accentColor: Color(0xFF007AFF));
    expect(a, equals(b));
    expect(a.hashCode, equals(b.hashCode));
    expect(a, isNot(equals(c)));
    expect(a.toString(), contains('dark'));
  });

  test('default methods throw UnimplementedError', () {
    final platform = _FakePlatform();
    expect(() => platform.getTheme(), throwsUnimplementedError);
    expect(() => platform.onThemeChanged, throwsUnimplementedError);
    expect(() => platform.setWindowAppearance(WindowAppearance.dark),
        throwsUnimplementedError);
    expect(() => platform.startWindowDrag(), throwsUnimplementedError);
    expect(() => platform.performTitlebarDoubleClickAction(),
        throwsUnimplementedError);
  });

  test('instance setter verifies the token', () {
    final mock = _NotMockPlatform();
    ZanshinShellPlatform.instance = mock;
    expect(ZanshinShellPlatform.instance, same(mock));
  });
}
```

- [x] **Step 3: Run test to verify it fails**

Run (cwd `packages/zanshin_shell_platform_interface`): `flutter test`
Expected: FAIL (package/library does not exist yet). Run `flutter pub get` at the workspace root first if resolution errors mask the compile error.

- [x] **Step 4: Implement**

`lib/src/shell_theme.dart`:
```dart
// SPDX-License-Identifier: MIT

import 'dart:ui';

/// A snapshot of the macOS system theme relevant to Zanshin.
class ShellTheme {
  const ShellTheme({required this.brightness, required this.accentColor});

  /// Day/night mode of the system (`Brightness.dark` in night mode).
  final Brightness brightness;

  /// The macOS accent color ("Farbakzent" in System Settings), resolved
  /// under the current appearance.
  final Color accentColor;

  @override
  bool operator ==(Object other) =>
      other is ShellTheme &&
      other.brightness == brightness &&
      other.accentColor == accentColor;

  @override
  int get hashCode => Object.hash(brightness, accentColor);

  @override
  String toString() =>
      'ShellTheme(brightness: ${brightness.name}, accentColor: $accentColor)';
}

/// Appearance override for the app window.
///
/// [system] removes the override so the window follows the OS appearance.
/// Applied per-window on purpose: overriding `NSApp.appearance` instead would
/// also flip Flutter's `platformBrightness` and hide the real system value.
enum WindowAppearance { light, dark, system }
```

`lib/src/zanshin_shell_platform.dart`:
```dart
// SPDX-License-Identifier: MIT

import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'shell_theme.dart';

/// The interface that platform implementations of zanshin_shell must extend.
abstract class ZanshinShellPlatform extends PlatformInterface {
  ZanshinShellPlatform() : super(token: _token);

  /// Test-only constructor so tests can subclass without holding the token.
  @protected
  ZanshinShellPlatform.forTesting() : super(token: _token);

  static final Object _token = Object();

  static ZanshinShellPlatform? _instance;

  /// The platform implementation in use.
  ///
  /// Unset until a platform registers itself (`registerWith`); accessing it
  /// then is a wiring error, so it throws instead of returning a stub.
  static ZanshinShellPlatform get instance {
    final instance = _instance;
    if (instance == null) {
      throw StateError(
          'No ZanshinShellPlatform registered. Is the app running on a '
          'supported platform with the endorsed implementation?');
    }
    return instance;
  }

  static set instance(ZanshinShellPlatform value) {
    PlatformInterface.verify(value, _token);
    _instance = value;
  }

  /// The current system theme.
  Future<ShellTheme> getTheme() => throw UnimplementedError();

  /// Emits whenever the system brightness or accent color changes.
  Stream<ShellTheme> get onThemeChanged => throw UnimplementedError();

  /// Forces the window (blur background + traffic lights) to the given
  /// appearance, or back to following the system.
  Future<void> setWindowAppearance(WindowAppearance appearance) =>
      throw UnimplementedError();

  /// Starts a native window drag. Must be called from within an active
  /// pointer-down gesture (the native side reuses the current mouse event).
  Future<void> startWindowDrag() => throw UnimplementedError();

  /// Performs the system titlebar double-click action (zoom/minimize/none,
  /// per the user's "double-click a window's title bar to" setting).
  Future<void> performTitlebarDoubleClickAction() =>
      throw UnimplementedError();
}
```

Note: `@protected` needs `import 'package:meta/meta.dart';` — `plugin_platform_interface` already depends on `meta`; add `meta: ^1.16.0` to dependencies to import it directly (do not rely on transitive deps).

`lib/zanshin_shell_platform_interface.dart`:
```dart
// SPDX-License-Identifier: MIT

export 'src/shell_theme.dart';
export 'src/zanshin_shell_platform.dart';
```

- [x] **Step 5: Run test to verify it passes**

Run (cwd `packages/zanshin_shell_platform_interface`): `flutter test`
Expected: PASS. Also run `dart analyze --fatal-infos --fatal-warnings` and `dart format .` in the package.

- [x] **Step 6: Commit**

```bash
git add packages/zanshin_shell_platform_interface docs/superpowers/plans/2026-09-02-zanshin-shell-plugin.md pubspec.lock
git commit --no-gpg-sign -m "feat(zanshin_shell): platform interface package" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```
(Only add `pubspec.lock` if `flutter pub get` changed it.)

---

### Task 2: `zanshin_shell_macos` — Dart method-channel implementation

**Files:**
- Create: `packages/zanshin_shell_macos/pubspec.yaml`
- Create: `packages/zanshin_shell_macos/analysis_options.yaml`
- Create: `packages/zanshin_shell_macos/lib/zanshin_shell_macos.dart`
- Test: `packages/zanshin_shell_macos/test/zanshin_shell_macos_test.dart`

**Interfaces:**
- Consumes: `ZanshinShellPlatform`, `ShellTheme`, `WindowAppearance` from Task 1.
- Produces: `class ZanshinShellMacOS extends ZanshinShellPlatform` with `static void registerWith()`. Channel protocol (Task 3 must match exactly):
  - Dart→Swift methods: `getTheme` (returns `Map{'brightness': 'light'|'dark', 'accentColor': int ARGB}`), `setWindowAppearance` (arg `'light'|'dark'|'system'`), `startWindowDrag`, `performTitlebarDoubleClickAction`.
  - Swift→Dart: `onThemeChanged` with the same theme map.

- [x] **Step 1: pubspec + analysis options**

`pubspec.yaml`:
```yaml
name: zanshin_shell_macos
description: macOS implementation of the zanshin_shell plugin.
version: 0.1.0
publish_to: 'none'

environment:
  sdk: ^3.14.0-143.0.dev
  flutter: ^3.48.0-1.0.pre-295
resolution: workspace

dependencies:
  flutter:
    sdk: flutter
  zanshin_shell_platform_interface:
    path: ../zanshin_shell_platform_interface

dev_dependencies:
  flutter_lints: ^6.0.0
  flutter_test:
    sdk: flutter

flutter:
  plugin:
    implements: zanshin_shell
    platforms:
      macos:
        pluginClass: ZanshinShellPlugin
        dartPluginClass: ZanshinShellMacOS
```

`analysis_options.yaml`: same one-liner as Task 1.

- [x] **Step 2: Write the failing test**

`test/zanshin_shell_macos_test.dart`:
```dart
// SPDX-License-Identifier: MIT

import 'dart:ui';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin_shell_macos/zanshin_shell_macos.dart';
import 'package:zanshin_shell_platform_interface/zanshin_shell_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('zanshin_shell');
  final log = <MethodCall>[];

  late ZanshinShellMacOS shell;

  setUp(() {
    log.clear();
    shell = ZanshinShellMacOS();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      log.add(call);
      if (call.method == 'getTheme') {
        return <String, Object?>{
          'brightness': 'dark',
          'accentColor': 0xFFFF453A,
        };
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('registerWith installs the macOS implementation', () {
    ZanshinShellMacOS.registerWith();
    expect(ZanshinShellPlatform.instance, isA<ZanshinShellMacOS>());
  });

  test('getTheme parses brightness and accent color', () async {
    final theme = await shell.getTheme();
    expect(theme.brightness, Brightness.dark);
    expect(theme.accentColor, const Color(0xFFFF453A));
    expect(log.single.method, 'getTheme');
  });

  test('setWindowAppearance sends the enum name', () async {
    await shell.setWindowAppearance(WindowAppearance.dark);
    expect(log.single.method, 'setWindowAppearance');
    expect(log.single.arguments, 'dark');
  });

  test('startWindowDrag and double-click action invoke their methods',
      () async {
    await shell.startWindowDrag();
    await shell.performTitlebarDoubleClickAction();
    expect(log.map((c) => c.method),
        ['startWindowDrag', 'performTitlebarDoubleClickAction']);
  });

  test('onThemeChanged emits when the native side pushes a theme', () async {
    final future = shell.onThemeChanged.first;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    await messenger.handlePlatformMessage(
      'zanshin_shell',
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('onThemeChanged', <String, Object?>{
          'brightness': 'light',
          'accentColor': 0xFF32D74B,
        }),
      ),
      (_) {},
    );
    final theme = await future;
    expect(theme.brightness, Brightness.light);
    expect(theme.accentColor, const Color(0xFF32D74B));
  });
}
```

- [x] **Step 3: Run test to verify it fails**

Run (cwd `packages/zanshin_shell_macos`): `flutter test`
Expected: FAIL (ZanshinShellMacOS undefined).

- [x] **Step 4: Implement**

`lib/zanshin_shell_macos.dart`:
```dart
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:zanshin_shell_platform_interface/zanshin_shell_platform_interface.dart';

/// macOS implementation of [ZanshinShellPlatform] over a single bidirectional
/// [MethodChannel]: this side calls into Swift, and the Swift side pushes
/// `onThemeChanged` calls back through the same channel.
class ZanshinShellMacOS extends ZanshinShellPlatform {
  ZanshinShellMacOS() {
    _channel.setMethodCallHandler(_handleMethodCall);
  }

  static void registerWith() {
    ZanshinShellPlatform.instance = ZanshinShellMacOS();
  }

  @visibleForTesting
  static const MethodChannel _channel = MethodChannel('zanshin_shell');

  final StreamController<ShellTheme> _themeChanges =
      StreamController<ShellTheme>.broadcast();

  Future<Object?> _handleMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'onThemeChanged':
        _themeChanges.add(_themeFromMap(call.arguments));
      default:
        throw MissingPluginException('Unknown method ${call.method}');
    }
    return null;
  }

  static ShellTheme _themeFromMap(Object? arguments) {
    final map = (arguments! as Map).cast<String, Object?>();
    return ShellTheme(
      brightness:
          map['brightness'] == 'dark' ? Brightness.dark : Brightness.light,
      accentColor: Color(map['accentColor']! as int),
    );
  }

  @override
  Future<ShellTheme> getTheme() async {
    final map = await _channel.invokeMapMethod<String, Object?>('getTheme');
    return _themeFromMap(map);
  }

  @override
  Stream<ShellTheme> get onThemeChanged => _themeChanges.stream;

  @override
  Future<void> setWindowAppearance(WindowAppearance appearance) =>
      _channel.invokeMethod<void>('setWindowAppearance', appearance.name);

  @override
  Future<void> startWindowDrag() =>
      _channel.invokeMethod<void>('startWindowDrag');

  @override
  Future<void> performTitlebarDoubleClickAction() =>
      _channel.invokeMethod<void>('performTitlebarDoubleClickAction');
}
```
(If the analyzer rejects `@visibleForTesting` on the private static, drop the annotation — the tests do not reference the field.)

- [x] **Step 5: Run test to verify it passes**

Run (cwd `packages/zanshin_shell_macos`): `flutter test`, then `dart analyze --fatal-infos --fatal-warnings` and `dart format .`.
Expected: PASS / clean.

- [x] **Step 6: Commit**

```bash
git add packages/zanshin_shell_macos
git commit --no-gpg-sign -m "feat(zanshin_shell): macOS method-channel implementation (Dart side)" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: `zanshin_shell_macos` — Swift plugin

**Files:**
- Create: `packages/zanshin_shell_macos/macos/zanshin_shell_macos.podspec`
- Create: `packages/zanshin_shell_macos/macos/Classes/ZanshinShellPlugin.swift`

**Interfaces:**
- Consumes: the channel protocol from Task 2 (names and payloads verbatim).
- Produces: `ZanshinShellPlugin` (the `pluginClass` already declared in Task 2's pubspec).

- [x] **Step 1: podspec**

`macos/zanshin_shell_macos.podspec` (check `app/macos/Runner.xcodeproj/project.pbxproj` for `MACOSX_DEPLOYMENT_TARGET` first; use that value, expected `10.15`):
```ruby
Pod::Spec.new do |s|
  s.name             = 'zanshin_shell_macos'
  s.version          = '0.1.0'
  s.summary          = 'macOS implementation of the zanshin_shell plugin.'
  s.description      = 'macOS shell integration (system theme, window drag) for Zanshin.'
  s.homepage         = 'https://example.com/zanshin'
  s.license          = { :type => 'MIT' }
  s.author           = { 'Zanshin' => 'ralph@dasralph.de' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'FlutterMacOS'
  s.platform         = :osx, '10.15'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version    = '5.0'
end
```

- [x] **Step 2: Swift plugin**

`macos/Classes/ZanshinShellPlugin.swift`:
```swift
// SPDX-License-Identifier: MIT

import Cocoa
import FlutterMacOS

/// Native half of the bidirectional "zanshin_shell" channel.
///
/// Pushes system theme changes (dark/light + accent color) to Dart and
/// executes window commands (drag, appearance override, titlebar
/// double-click action) on the window that hosts the Flutter view.
public class ZanshinShellPlugin: NSObject, FlutterPlugin {
    private let channel: FlutterMethodChannel
    private weak var view: NSView?
    private var appearanceObservation: NSKeyValueObservation?

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "zanshin_shell", binaryMessenger: registrar.messenger)
        let instance = ZanshinShellPlugin(channel: channel, view: registrar.view)
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    init(channel: FlutterMethodChannel, view: NSView?) {
        self.channel = channel
        self.view = view
        super.init()

        // Covers dark/light switches AND accent changes: macOS republishes the
        // effective appearance when the accent color changes appearance-relevant
        // state; the distributed notification below covers pure accent swaps.
        appearanceObservation = NSApp.observe(\.effectiveAppearance) {
            [weak self] _, _ in
            self?.emitThemeChanged()
        }
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleAccentChanged),
            name: NSNotification.Name("AppleColorPreferencesChangedNotification"),
            object: nil
        )
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
    }

    @objc private func handleAccentChanged(_ notification: Notification) {
        // The distributed notification can arrive before AppKit has refreshed
        // NSColor.controlAccentColor; resolve on the next run-loop turn.
        DispatchQueue.main.async { [weak self] in
            self?.emitThemeChanged()
        }
    }

    private func emitThemeChanged() {
        channel.invokeMethod("onThemeChanged", arguments: currentTheme())
    }

    /// The window hosting the Flutter view - resolved lazily because the view
    /// is not attached to a window yet when the plugin registers.
    private var window: NSWindow? {
        return view?.window ?? NSApp.mainWindow
    }

    private func currentTheme() -> [String: Any] {
        let appearance = NSApp.effectiveAppearance
        let isDark =
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua

        // controlAccentColor is appearance-dependent; resolve it under the
        // current effective appearance so the ARGB value matches what the
        // user sees. Fallback: the accent blue that macOS defaults to.
        var argb = isDark ? 0xFF0A84FF : 0xFF007AFF
        let resolve = {
            if let c = NSColor.controlAccentColor.usingColorSpace(.sRGB) {
                argb =
                    (Int(round(c.alphaComponent * 255)) << 24)
                    | (Int(round(c.redComponent * 255)) << 16)
                    | (Int(round(c.greenComponent * 255)) << 8)
                    | Int(round(c.blueComponent * 255))
            }
        }
        if #available(macOS 11.0, *) {
            appearance.performAsCurrentDrawingAppearance(resolve)
        } else {
            resolve()
        }

        return ["brightness": isDark ? "dark" : "light", "accentColor": argb]
    }

    public func handle(
        _ call: FlutterMethodCall, result: @escaping FlutterResult
    ) {
        switch call.method {
        case "getTheme":
            result(currentTheme())
        case "setWindowAppearance":
            setWindowAppearance(call.arguments as? String)
            result(nil)
        case "startWindowDrag":
            // Reuses the mouse event of the Flutter gesture that triggered the
            // call; without an active event this is a deliberate no-op.
            if let window = self.window, let event = NSApp.currentEvent {
                window.performDrag(with: event)
            }
            result(nil)
        case "performTitlebarDoubleClickAction":
            performTitlebarDoubleClickAction()
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    /// Per-window override on purpose: overriding NSApp.appearance would also
    /// flip the platformBrightness Flutter reports, hiding the real system
    /// value that the theme channel is supposed to deliver.
    private func setWindowAppearance(_ name: String?) {
        guard let window = self.window else { return }
        switch name {
        case "light":
            window.appearance = NSAppearance(named: .aqua)
        case "dark":
            window.appearance = NSAppearance(named: .darkAqua)
        default:
            window.appearance = nil
        }
    }

    /// Mirrors the native titlebar double-click behavior, which the user
    /// configures in System Settings ("double-click a window's title bar to").
    private func performTitlebarDoubleClickAction() {
        guard let window = self.window else { return }
        let action = UserDefaults.standard.string(
            forKey: "AppleActionOnDoubleClick")
        switch action {
        case "Minimize":
            window.performMiniaturize(nil)
        case "None":
            break
        default:
            // "Maximize", "Fill" (unsupported pre-Sequoia semantics) and the
            // unset default all map to zoom.
            window.performZoom(nil)
        }
    }
}
```

- [x] **Step 3: Commit**

Native compile verification happens in Task 5 (the plugin only builds as part of the app).

```bash
git add packages/zanshin_shell_macos/macos
git commit --no-gpg-sign -m "feat(zanshin_shell): macOS Swift plugin (theme events, window drag/appearance/zoom)" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: `zanshin_shell` app-facing package (API + `WindowDragArea`)

**Files:**
- Create: `packages/zanshin_shell/pubspec.yaml`
- Create: `packages/zanshin_shell/analysis_options.yaml`
- Create: `packages/zanshin_shell/lib/zanshin_shell.dart`
- Create: `packages/zanshin_shell/lib/src/zanshin_shell.dart`
- Create: `packages/zanshin_shell/lib/src/window_drag_area.dart`
- Test: `packages/zanshin_shell/test/zanshin_shell_test.dart`
- Test: `packages/zanshin_shell/test/window_drag_area_test.dart`

**Interfaces:**
- Consumes: `ZanshinShellPlatform`, `ShellTheme`, `WindowAppearance` (Task 1).
- Produces (Task 5 consumes): `class ZanshinShell` with static members `getTheme()`, `onThemeChanged`, `setWindowAppearance(WindowAppearance)`, `startWindowDrag()`, `performTitlebarDoubleClickAction()`; `class WindowDragArea extends StatelessWidget implements PreferredSizeWidget`; re-exports `ShellTheme` and `WindowAppearance`.

- [x] **Step 1: pubspec + analysis options**

`pubspec.yaml` (the `default_package` line is the endorsement):
```yaml
name: zanshin_shell
description: macOS shell integration for Zanshin - system theme (day/night + accent color) and native window dragging.
version: 0.1.0
publish_to: 'none'

environment:
  sdk: ^3.14.0-143.0.dev
  flutter: ^3.48.0-1.0.pre-295
resolution: workspace

dependencies:
  flutter:
    sdk: flutter
  zanshin_shell_macos:
    path: ../zanshin_shell_macos
  zanshin_shell_platform_interface:
    path: ../zanshin_shell_platform_interface

dev_dependencies:
  flutter_lints: ^6.0.0
  flutter_test:
    sdk: flutter

flutter:
  plugin:
    platforms:
      macos:
        default_package: zanshin_shell_macos
```

`analysis_options.yaml`: same one-liner as Task 1.

- [x] **Step 2: Write the failing tests**

`test/zanshin_shell_test.dart`:
```dart
// SPDX-License-Identifier: MIT

import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:zanshin_shell/zanshin_shell.dart';
import 'package:zanshin_shell_platform_interface/zanshin_shell_platform_interface.dart';

final class RecordingPlatform extends ZanshinShellPlatform
    with MockPlatformInterfaceMixin {
  RecordingPlatform() : super.forTesting();

  final calls = <String>[];
  final themeController = StreamController<ShellTheme>.broadcast();

  static const theme = ShellTheme(
      brightness: Brightness.dark, accentColor: Color(0xFFBF5AF2));

  @override
  Future<ShellTheme> getTheme() async {
    calls.add('getTheme');
    return theme;
  }

  @override
  Stream<ShellTheme> get onThemeChanged => themeController.stream;

  @override
  Future<void> setWindowAppearance(WindowAppearance appearance) async {
    calls.add('setWindowAppearance:${appearance.name}');
  }

  @override
  Future<void> startWindowDrag() async {
    calls.add('startWindowDrag');
  }

  @override
  Future<void> performTitlebarDoubleClickAction() async {
    calls.add('performTitlebarDoubleClickAction');
  }
}

void main() {
  late RecordingPlatform platform;

  setUp(() {
    platform = RecordingPlatform();
    ZanshinShellPlatform.instance = platform;
  });

  test('ZanshinShell delegates to the platform instance', () async {
    expect(await ZanshinShell.getTheme(), RecordingPlatform.theme);
    await ZanshinShell.setWindowAppearance(WindowAppearance.light);
    await ZanshinShell.startWindowDrag();
    await ZanshinShell.performTitlebarDoubleClickAction();
    expect(platform.calls, [
      'getTheme',
      'setWindowAppearance:light',
      'startWindowDrag',
      'performTitlebarDoubleClickAction',
    ]);
  });

  test('onThemeChanged forwards the platform stream', () async {
    final future = ZanshinShell.onThemeChanged.first;
    platform.themeController.add(RecordingPlatform.theme);
    expect(await future, RecordingPlatform.theme);
  });
}
```
(`dart:async` import needed for `StreamController`.)

`test/window_drag_area_test.dart`:
```dart
// SPDX-License-Identifier: MIT

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin_shell/zanshin_shell.dart';
import 'package:zanshin_shell_platform_interface/zanshin_shell_platform_interface.dart';

import 'zanshin_shell_test.dart' show RecordingPlatform;

void main() {
  late RecordingPlatform platform;

  setUp(() {
    platform = RecordingPlatform();
    ZanshinShellPlatform.instance = platform;
  });

  Widget harness(Widget child) => MaterialApp(home: Scaffold(body: child));

  testWidgets('pan start triggers a native window drag', (tester) async {
    await tester.pumpWidget(harness(
        const WindowDragArea(child: SizedBox(width: 300, height: 44))));
    final gesture = await tester
        .startGesture(tester.getCenter(find.byType(WindowDragArea)));
    await gesture.moveBy(const Offset(30, 0));
    await gesture.up();
    await tester.pump();
    expect(platform.calls, ['startWindowDrag']);
  });

  testWidgets('double tap performs the titlebar double-click action',
      (tester) async {
    await tester.pumpWidget(harness(
        const WindowDragArea(child: SizedBox(width: 300, height: 44))));
    await tester.tap(find.byType(WindowDragArea));
    await tester.pump(kDoubleTapMinTime);
    await tester.tap(find.byType(WindowDragArea));
    await tester.pumpAndSettle();
    expect(platform.calls, ['performTitlebarDoubleClickAction']);
  });

  testWidgets('preferredSize delegates to a PreferredSizeWidget child',
      (tester) async {
    const area = WindowDragArea(child: PreferredSize(
        preferredSize: Size.fromHeight(44), child: SizedBox()));
    expect(area.preferredSize, const Size.fromHeight(44));
    const plain = WindowDragArea(child: SizedBox());
    expect(plain.preferredSize, const Size.fromHeight(kToolbarHeight));
  });
}
```

- [x] **Step 3: Run tests to verify they fail**

Run (cwd `packages/zanshin_shell`): `flutter test`
Expected: FAIL (library does not exist).

- [x] **Step 4: Implement**

`lib/src/zanshin_shell.dart`:
```dart
// SPDX-License-Identifier: MIT

import 'package:zanshin_shell_platform_interface/zanshin_shell_platform_interface.dart';

/// App-facing API of the zanshin_shell plugin.
abstract final class ZanshinShell {
  static ZanshinShellPlatform get _platform => ZanshinShellPlatform.instance;

  /// The current system theme (day/night mode + accent color).
  static Future<ShellTheme> getTheme() => _platform.getTheme();

  /// Emits whenever the system brightness or accent color changes.
  static Stream<ShellTheme> get onThemeChanged => _platform.onThemeChanged;

  /// Forces the window chrome (blur background, traffic lights) to the given
  /// appearance - use this when the in-app theme mode overrides the system.
  static Future<void> setWindowAppearance(WindowAppearance appearance) =>
      _platform.setWindowAppearance(appearance);

  /// Starts a native window drag; call from an active drag gesture.
  static Future<void> startWindowDrag() => _platform.startWindowDrag();

  /// Performs the user-configured titlebar double-click action.
  static Future<void> performTitlebarDoubleClickAction() =>
      _platform.performTitlebarDoubleClickAction();
}
```

`lib/src/window_drag_area.dart`:
```dart
// SPDX-License-Identifier: MIT

import 'package:flutter/material.dart';

import 'zanshin_shell.dart';

/// Makes its subtree behave like a native macOS titlebar: dragging moves the
/// window and double-clicking performs the system titlebar action.
///
/// Interactive children (buttons etc.) keep working - they win the gesture
/// arena for taps, while an actual drag movement starts the window drag.
///
/// Implements [PreferredSizeWidget] so it can wrap an [AppBar] directly in
/// `Scaffold.appBar`; outside that slot the preferred size is ignored.
class WindowDragArea extends StatelessWidget implements PreferredSizeWidget {
  const WindowDragArea({required this.child, super.key});

  final Widget child;

  @override
  Size get preferredSize => child is PreferredSizeWidget
      ? (child as PreferredSizeWidget).preferredSize
      : const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) => GestureDetector(
        behavior: HitTestBehavior.translucent,
        onPanStart: (_) => ZanshinShell.startWindowDrag(),
        onDoubleTap: ZanshinShell.performTitlebarDoubleClickAction,
        child: child,
      );
}
```

`lib/zanshin_shell.dart`:
```dart
// SPDX-License-Identifier: MIT

export 'package:zanshin_shell_platform_interface/zanshin_shell_platform_interface.dart'
    show ShellTheme, WindowAppearance;

export 'src/window_drag_area.dart';
export 'src/zanshin_shell.dart';
```

- [x] **Step 5: Run tests to verify they pass**

Run (cwd `packages/zanshin_shell`): `flutter test`, then `dart analyze --fatal-infos --fatal-warnings` and `dart format .`.
Expected: PASS / clean. If the double-tap test is flaky around `kDoubleTapMinTime`, use `await tester.pump(const Duration(milliseconds: 100));` between the taps instead.

- [x] **Step 6: Commit**

```bash
git add packages/zanshin_shell
git commit --no-gpg-sign -m "feat(zanshin_shell): app-facing API and WindowDragArea widget" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: App integration (theme wiring, drag wiring, drop window_manager)

**Files:**
- Modify: `app/pubspec.yaml` (remove `window_manager`, add `zanshin_shell` path dep)
- Modify: `app/lib/main.dart` (remove the window_manager import, `ensureInitialized()` call and its comment)
- Modify: `app/lib/src/features/app/zanshin_app.dart` (theme wiring, drag on the test AppBar)
- Modify: `app/lib/src/features/shell/window_title_bar.dart` (replace `DragToMoveArea` with `WindowDragArea`)

**Interfaces:**
- Consumes: `ZanshinShell`, `WindowDragArea`, `ShellTheme` (Task 4); yaru 10.2.0 `createYaruLightTheme({required Color primaryColor})` / `createYaruDarkTheme({required Color primaryColor})` (verified present in `~/.pub-cache/hosted/pub.dev/yaru-10.2.0/lib/src/themes/common_themes.dart`; confirm they are exported from `package:yaru/yaru.dart`, otherwise fall back to `yaruLight.copyWith(colorScheme: yaruLight.colorScheme.copyWith(primary: accent))`).

- [x] **Step 1: pubspec + main.dart**

In `app/pubspec.yaml`: delete the `window_manager: ^0.5.1` line; add under dependencies:
```yaml
  zanshin_shell:
    path: ../packages/zanshin_shell
```

In `app/lib/main.dart`: delete the `import 'package:window_manager/window_manager.dart';` line and the block
```dart
      // Needed by DragToMoveArea in the title bar. All window geometry and
      // titlebar styling lives in macos/Runner/MainFlutterWindow.swift.
      await windowManager.ensureInitialized();
```
Run `flutter pub get` at the workspace root.

- [x] **Step 2: zanshin_app.dart theme wiring**

Rewrite `ZanshinApp` as a `StatefulWidget` (keep the `@assistedInject` constructor, the `_homePageFactory` field with its ignore-comment, the commented-out `_buildTheme` block, and the `part` directive untouched). The Linux `YaruTheme` branch and `_ExampleHome` stay; only the macOS path becomes theme-aware:

```dart
class ZanshinApp extends StatefulWidget {
  @assistedInject
  const ZanshinApp({
    required this._homePageFactory,
    @assisted super.key,
  });

  // Temporarily unused while `home` shows the Yaru test page below.
  // ignore: unused_field
  final HomePageFactory _homePageFactory;

  @override
  State<ZanshinApp> createState() => _ZanshinAppState();
}

class _ZanshinAppState extends State<ZanshinApp> {
  ShellTheme? _shellTheme;
  StreamSubscription<ShellTheme>? _subscription;

  @override
  void initState() {
    super.initState();
    if (!kIsWeb && Platform.isMacOS) {
      unawaited(ZanshinShell.getTheme().then(_applyShellTheme));
      _subscription = ZanshinShell.onThemeChanged.listen(_applyShellTheme);
    }
  }

  void _applyShellTheme(ShellTheme theme) {
    if (!mounted) return;
    setState(() => _shellTheme = theme);
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!kIsWeb && Platform.isLinux) {
      return YaruTheme(
        builder: (context, yaru, child) => _ExampleHome(
          themeMode: ThemeMode.system,
          lightTheme: yaru.theme,
          darkTheme: yaru.darkTheme,
        ),
      );
    }

    final shellTheme = _shellTheme;
    if (shellTheme == null) {
      // First frame before the platform answered: follow the system via
      // Flutter's own brightness until the shell theme arrives.
      return const _ExampleHome(
        themeMode: ThemeMode.system,
        lightTheme: null,
        darkTheme: null,
      );
    }

    return _ExampleHome(
      // The shell channel is authoritative for day/night on macOS.
      themeMode: shellTheme.brightness == Brightness.dark
          ? ThemeMode.dark
          : ThemeMode.light,
      lightTheme: createYaruLightTheme(primaryColor: shellTheme.accentColor),
      darkTheme: createYaruDarkTheme(primaryColor: shellTheme.accentColor),
    );
  }
}
```

Adjust `_ExampleHome` to accept nullable themes with the yaru defaults:
```dart
class _ExampleHome extends StatelessWidget {
  const _ExampleHome({
    required this.lightTheme,
    required this.darkTheme,
    required this.themeMode,
  });

  final ThemeData? lightTheme;
  final ThemeData? darkTheme;
  final ThemeMode themeMode;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Yaru Test',
    theme: lightTheme ?? yaruLight,
    themeMode: themeMode,
    darkTheme: darkTheme ?? yaruDark,
    home: const _Example(),
  );
}
```

New imports needed in zanshin_app.dart: `dart:async` (unawaited, StreamSubscription), `package:zanshin_shell/zanshin_shell.dart`. `dart:io`, `flutter/foundation.dart`, `flutter/material.dart`, yaru are already imported.

- [x] **Step 3: Drag wiring**

In `zanshin_app.dart`, wrap the test page's AppBar:
```dart
  Widget build(BuildContext context) => Scaffold(
    appBar: WindowDragArea(
      child: AppBar(title: const Text('hallo ralph, dies ist dein Yaru Test')),
    ),
    body: const CheckboxPage(),
  );
```

In `app/lib/src/features/shell/window_title_bar.dart`: replace the import `package:window_manager/window_manager.dart` with `package:zanshin_shell/zanshin_shell.dart` and `DragToMoveArea(` with `WindowDragArea(` (the closing paren stays; the child stays).

- [x] **Step 4: Verify analysis, tests, native build**

```bash
dart analyze --fatal-infos --fatal-warnings app
```
Expected: clean.
```bash
cd app && flutter test
```
Expected: PASS (existing native-asset smoke test still green).
```bash
cd app && flutter build macos --debug
```
Expected: build succeeds — this is the first compile of the Swift plugin; fix any Swift compile errors here (the plugin registrant should now list `ZanshinShellPlugin`, and `dart_plugin_registrant` should call `ZanshinShellMacOS.registerWith()` — verify `ZanshinShellPlugin` appears in `app/macos/Flutter/GeneratedPluginRegistrant.swift` after the build).

- [x] **Step 5: Commit**

```bash
git add app/pubspec.yaml app/lib/main.dart app/lib/src/features/app/zanshin_app.dart app/lib/src/features/shell/window_title_bar.dart pubspec.lock
git commit --no-gpg-sign -m "feat(app): drive theme from zanshin_shell and drop window_manager" -m "macOS day/night + accent color now come over the zanshin_shell channel; the Yaru test AppBar and the WindowTitleBar are draggable via WindowDragArea (incl. titlebar double-click action)." -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: Quality-gate integration (Makefile.toml)

**Files:**
- Modify: `Makefile.toml` (the `[tasks.test]` dependency list around line 48, and new task blocks next to the existing `test-core*` blocks)

- [x] **Step 1: Add gate tasks**

Append to the `[tasks.test]` `dependencies` list (after `"test-core-format"`):
```toml
    "test-shell",
    "test-shell-analyze",
    "test-shell-format",
    "test-shell-pi",
    "test-shell-pi-analyze",
    "test-shell-pi-format",
    "test-shell-macos",
    "test-shell-macos-analyze",
    "test-shell-macos-format",
```

Add the task blocks (mirror the existing `test-core*` pattern; `flutter test` instead of `dart test` because these are Flutter packages):
```toml
[tasks.test-shell]
private = true
command = "flutter"
args = ["test"]
cwd = "packages/zanshin_shell"

[tasks.test-shell-analyze]
private = true
command = "dart"
args = ["analyze", "--fatal-infos", "--fatal-warnings"]
cwd = "packages/zanshin_shell"

[tasks.test-shell-format]
private = true
command = "dart"
args = ["format", "--output=none", "--set-exit-if-changed", "."]
cwd = "packages/zanshin_shell"

[tasks.test-shell-pi]
private = true
command = "flutter"
args = ["test"]
cwd = "packages/zanshin_shell_platform_interface"

[tasks.test-shell-pi-analyze]
private = true
command = "dart"
args = ["analyze", "--fatal-infos", "--fatal-warnings"]
cwd = "packages/zanshin_shell_platform_interface"

[tasks.test-shell-pi-format]
private = true
command = "dart"
args = ["format", "--output=none", "--set-exit-if-changed", "."]
cwd = "packages/zanshin_shell_platform_interface"

[tasks.test-shell-macos]
private = true
command = "flutter"
args = ["test"]
cwd = "packages/zanshin_shell_macos"

[tasks.test-shell-macos-analyze]
private = true
command = "dart"
args = ["analyze", "--fatal-infos", "--fatal-warnings"]
cwd = "packages/zanshin_shell_macos"

[tasks.test-shell-macos-format]
private = true
command = "dart"
args = ["format", "--output=none", "--set-exit-if-changed", "."]
cwd = "packages/zanshin_shell_macos"
```

- [x] **Step 2: Run the full gate**

```bash
cargo make test
```
Expected: PASS end-to-end, including the coverage ratchet reporting "coverage held" (no Rust changed; `coverage-baseline.txt` must NOT change).

- [x] **Step 3: Commit**

```bash
git add Makefile.toml
git commit --no-gpg-sign -m "chore(gate): run analyze/format/test for the zanshin_shell packages" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 7: Final verification

- [x] **Step 1: Full gate once more from a clean state**

```bash
cargo make test
```
Expected: PASS. `git status --short` afterwards shows a clean tree (everything committed; if `pubspec.lock` changed, amend it into the Task 5 commit or add a follow-up chore commit).

- [x] **Step 2: Report**

Summarize for the orchestrator: what was built, test counts, gate result, any deviations from this plan (with reasons), and anything left for manual verification (window drag feel, theme switching live on screen).

---

## Deviations from this plan (as implemented)

1. **macOS deployment target is 12.0, not 10.15.** `app/macos/Runner.xcodeproj/project.pbxproj`
   sets `MACOSX_DEPLOYMENT_TARGET = 12.0` and the Flutter Podfile template pins
   `platform :osx, '12.0'`. The podspec uses 12.0, and the `#available(macOS 11.0, *)`
   branch around `performAsCurrentDrawingAppearance` was dropped (always true at that target).
2. **The macOS plugin ships as a Swift Package, not CocoaPods-only.** The app integrates
   plugins via SPM; a CocoaPods-only plugin made `flutter build macos` fall back to
   CocoaPods and rewrite the Xcode project (Podfile, Podfile.lock, `Pods.xcodeproj`
   workspace ref, `Flutter-*.xcconfig` includes, `project.pbxproj`). Sources moved to
   `macos/zanshin_shell_macos/Sources/zanshin_shell_macos/`, `Package.swift` added,
   podspec kept as a CocoaPods fallback pointing at the same sources.
3. **`@visibleForTesting` dropped** from the private `_channel` in `zanshin_shell_macos`
   (the annotation is invalid on private members; the plan allowed dropping it).
4. **`dart:ui` imports removed** from `zanshin_shell_macos` lib+test (`unnecessary_import`:
   `package:flutter/services.dart` already provides `Color`/`Brightness`).
5. **`plugin_platform_interface` added as a dev_dependency of `zanshin_shell`**
   (`depend_on_referenced_packages`: the test's fake mixes in `MockPlatformInterfaceMixin`).
6. **`kDoubleTapMinTime` needs `package:flutter/gestures.dart`** — added that import
   rather than the plan's duration fallback.
7. **The pan-drag widget test pumps `kDoubleTapTimeout`** instead of a bare `pump()`:
   the double-tap recognizer arms a timer on tap-down that would otherwise outlive
   the widget tree ("A Timer is still pending").
8. **`.gitignore` added per new package** (`build/`) so the Flutter test/asset output
   does not dirty the tree; mirrors `packages/zanshin_core/.gitignore`.
9. **`analysis_options.yaml` of the new packages carries a tool-written
   `analyzer: exclude:` block** (`build/**`, plus `macos/**` for the plugin package) —
   `flutter pub get` adds it automatically.
10. **`window_manager` survives as a transitive dependency** via `yaru` →
    `yaru_window_manager`, so it still appears in `GeneratedPluginRegistrant.swift`.
    The app's direct dependency and all app-side usage are gone.
11. **`pubspec.lock` did not change** (workspace-root-relative direct/transitive marks;
    `plugin_platform_interface` was already locked), so no commit touched it.
