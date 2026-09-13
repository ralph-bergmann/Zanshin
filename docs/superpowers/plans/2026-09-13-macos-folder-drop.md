# macOS Folder Drop Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Drag folders from Finder into a `TreeSliver` and drop them before, into or after a row, in every window of the view-less windowing runner.

**Architecture:** A native `FolderDropView` (Swift, `hitTest → nil`) sits on top of each Flutter view that has drop targets and reports folder drags with view id, position and paths over the channel `zanshin_shell/folder_drop`. Dart resolves the innermost `FolderDropTarget` with `WidgetsBinding.hitTestInView` and answers whether a drop would be accepted; the native side caches that answer for AppKit. The demo `app/lib/main3.dart` uses the pure tree logic in `app/lib/src/features/projects/tree_drop.dart`.

**Tech Stack:** Flutter (master 3.48 pre, experimental windowing API), Dart 3.14 pre, Swift/AppKit, federated plugin `zanshin_shell` (platform interface + macOS implementation + app-facing package).

**Spec:** `docs/superpowers/specs/2026-09-13-macos-folder-drop-design.md` — read it first; this plan implements it exactly.

## Global Constraints

- Definition of done: `cargo make test` passes, run unpiped from the repo root. For the Dart packages it runs `flutter test`, `dart analyze --fatal-infos --fatal-warnings` and `dart format --output=none --set-exit-if-changed .` in `app/`, `packages/zanshin_shell`, `packages/zanshin_shell_platform_interface` and `packages/zanshin_shell_macos`.
- Toolchain on `PATH`: `~/development/sdks/flutter/bin` and `~/development/sdks/cargo/bin` (`flutter`, `dart`, `cargo`, `cargo-make`).
- Formatter: page width 120, `trailing_commas: preserve` (`linter/rules.yaml`). Run `dart format .` in a package before analyzing it.
- Lints are strict (`linter/rules.yaml`), notably: `discarded_futures` (wrap fire-and-forget futures in `unawaited`), `always_put_control_body_on_new_line`, `specify_nonobvious_local_variable_types`, `omit_obvious_local_variable_types`, `avoid_types_on_closure_parameters`, `cascade_invocations`, `require_trailing_commas`, `prefer_relative_imports` (inside `lib/`), `unnecessary_ignore`, `no_default_cases`. If `dart analyze` reports `unnecessary_import`, delete the flagged import.
- Every new source file starts with `// SPDX-License-Identifier: MIT`. Swift uses 4-space indentation and `///` doc comments like `ZanshinShellPlugin.swift`.
- App code takes Material types from `package:material_ui/material_ui.dart`, never `package:flutter/material.dart`.
- Channel name `zanshin_shell/folder_drop`; methods `attach`, `detach` (Dart → native, argument `viewId`) and `dragEntered`, `dragUpdated`, `dragExited`, `dropped` (native → Dart, arguments `viewId`, `x`, `y`, `paths`) exactly as in the spec's protocol table.
- No Rust changes; the coverage ratchet is unaffected.
- Git: stage explicit paths only. Never stage `app/lib/main2.dart` (Ralph's untracked file). End every commit message with `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`. If 1Password SSH signing fails in an unattended run, add `--no-gpg-sign` to that `git commit`; never edit git config.

## File Structure

| File | Responsibility |
|---|---|
| `packages/zanshin_shell_platform_interface/lib/src/folder_drag_event.dart` (create) | `FolderDragEvent` sealed hierarchy + `FolderDragHandler` typedef. |
| `packages/zanshin_shell_platform_interface/lib/src/zanshin_shell_platform.dart` (modify) | Three new platform members with throwing defaults. |
| `packages/zanshin_shell_platform_interface/lib/zanshin_shell_platform_interface.dart` (modify) | Export the event file. |
| `packages/zanshin_shell_macos/lib/zanshin_shell_macos.dart` (modify) | Folder drop channel: handler install, event decoding, attach/detach. |
| `packages/zanshin_shell_macos/macos/zanshin_shell_macos/Sources/zanshin_shell_macos/FolderPasteboard.swift` (create) | Folder filter: pasteboard file URLs → resolved folder paths (Cocoa only). |
| `packages/zanshin_shell_macos/macos/zanshin_shell_macos/Sources/zanshin_shell_macos/FolderDropView.swift` (create) | Invisible drag destination; session, answer cache, coalescing. |
| `packages/zanshin_shell_macos/macos/zanshin_shell_macos/Sources/zanshin_shell_macos/FolderDropHost.swift` (create) | Channel handler; finds Flutter views by id and installs drop views. |
| `packages/zanshin_shell_macos/macos/zanshin_shell_macos/Sources/zanshin_shell_macos/ZanshinShellPlugin.swift` (modify) | Creates and owns the `FolderDropHost`. |
| `packages/zanshin_shell/lib/src/folder_drop_target.dart` (create) | `FolderDragDetails`, `FolderDropTarget`, `RenderFolderDropTarget`. |
| `packages/zanshin_shell/lib/src/folder_drop_dispatcher.dart` (create) | `FolderDropDispatcher`: platform binding, per-view counts, sessions, hit test. |
| `packages/zanshin_shell/lib/zanshin_shell.dart` (modify) | Export `FolderDragDetails`, `FolderDropTarget`. |
| `packages/zanshin_shell/test/zanshin_shell_test.dart` (modify) | `RecordingPlatform` learns the folder drop members. |
| `packages/zanshin_shell/test/folder_drop_target_test.dart` (create) | Registration and dispatch widget tests. |
| `app/lib/src/features/projects/tree_drop.dart` (create) | Pure tree placement / insertion logic. |
| `app/test/features/projects/tree_drop_test.dart` (create) | Unit tests for `tree_drop.dart`. |
| `app/lib/main3.dart` (create) | Demo entrypoint: windows, TreeSliver UI, indicators, status. |

---

### Task 1: Platform interface — folder drag events

**Files:**
- Create: `packages/zanshin_shell_platform_interface/lib/src/folder_drag_event.dart`
- Modify: `packages/zanshin_shell_platform_interface/lib/src/zanshin_shell_platform.dart`
- Modify: `packages/zanshin_shell_platform_interface/lib/zanshin_shell_platform_interface.dart`
- Test: `packages/zanshin_shell_platform_interface/test/zanshin_shell_platform_test.dart`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `sealed class FolderDragEvent { final int viewId; }`
  - `final class FolderDragEntered extends FolderDragEvent { final Offset position; final List<String> paths; }`
  - `final class FolderDragUpdated extends FolderDragEvent { final Offset position; }`
  - `final class FolderDragExited extends FolderDragEvent {}`
  - `final class FolderDropped extends FolderDragEvent { final Offset position; final List<String> paths; }`
  - `typedef FolderDragHandler = bool Function(FolderDragEvent event);`
  - On `ZanshinShellPlatform`: `void setFolderDragHandler(FolderDragHandler? handler)`, `Future<void> enableFolderDrops(int viewId)`, `Future<void> disableFolderDrops(int viewId)`.
  - All constructors take named `required` arguments (`viewId`, `position`, `paths`).

- [ ] **Step 1: Write the failing test**

In `packages/zanshin_shell_platform_interface/test/zanshin_shell_platform_test.dart`, inside the test `'default methods throw UnimplementedError'`, append after the last `expect(...)`:

```dart
    expect(() => platform.setFolderDragHandler(null), throwsUnimplementedError);
    expect(() => platform.enableFolderDrops(1), throwsUnimplementedError);
    expect(() => platform.disableFolderDrops(1), throwsUnimplementedError);
```

- [ ] **Step 2: Run the test to verify it fails**

Run (in `packages/zanshin_shell_platform_interface`): `flutter test`
Expected: compilation fails with "The method 'setFolderDragHandler' isn't defined for the type '_FakePlatform'".

- [ ] **Step 3: Create the event types**

Create `packages/zanshin_shell_platform_interface/lib/src/folder_drag_event.dart`:

```dart
// SPDX-License-Identifier: MIT

import 'dart:ui' show Offset;

import 'package:flutter/foundation.dart' show immutable;

/// One step of a folder drag over a Flutter view, as the platform reports it.
///
/// A drag over a view is a [FolderDragEntered], any number of
/// [FolderDragUpdated]s, and then a [FolderDragExited] or a [FolderDropped].
/// The platform only reports drags that carry at least one folder.
@immutable
sealed class FolderDragEvent {
  const FolderDragEvent({required this.viewId});

  /// The Flutter view the drag is over (`FlutterView.viewId`).
  final int viewId;
}

/// A drag carrying folders entered the view.
final class FolderDragEntered extends FolderDragEvent {
  const FolderDragEntered({required super.viewId, required this.position, required this.paths});

  /// The pointer position in the view's logical pixels.
  final Offset position;

  /// The absolute paths of the dragged folders; never empty.
  final List<String> paths;
}

/// The drag moved over the view.
final class FolderDragUpdated extends FolderDragEvent {
  const FolderDragUpdated({required super.viewId, required this.position});

  /// The pointer position in the view's logical pixels.
  final Offset position;
}

/// The drag left the view, or ended without dropping on it.
final class FolderDragExited extends FolderDragEvent {
  const FolderDragExited({required super.viewId});
}

/// The folders were dropped on the view.
final class FolderDropped extends FolderDragEvent {
  const FolderDropped({required super.viewId, required this.position, required this.paths});

  /// The drop position in the view's logical pixels.
  final Offset position;

  /// The absolute paths of the dropped folders; never empty.
  final List<String> paths;
}

/// Answers a [FolderDragEvent]: whether a drop at the event's position would
/// be accepted. The answer drives the platform's drag feedback; it is ignored
/// for [FolderDragExited].
typedef FolderDragHandler = bool Function(FolderDragEvent event);
```

- [ ] **Step 4: Add the platform members**

In `packages/zanshin_shell_platform_interface/lib/src/zanshin_shell_platform.dart`, add the import next to the existing relative import (keep alphabetical order):

```dart
import 'folder_drag_event.dart';
import 'shell_theme.dart';
```

Append inside `ZanshinShellPlatform`, after `performTitlebarDoubleClickAction`:

```dart
  /// Routes the folder drags of every Flutter view to [handler]; `null` stops
  /// routing them. Drags only arrive for views enabled with
  /// [enableFolderDrops].
  void setFolderDragHandler(FolderDragHandler? handler) => throw UnimplementedError();

  /// Starts accepting folder drags on the Flutter view [viewId]; idempotent.
  Future<void> enableFolderDrops(int viewId) => throw UnimplementedError();

  /// Stops accepting folder drags on the Flutter view [viewId]; a no-op when
  /// they are not enabled.
  Future<void> disableFolderDrops(int viewId) => throw UnimplementedError();
```

- [ ] **Step 5: Export the events**

Replace the exports of `packages/zanshin_shell_platform_interface/lib/zanshin_shell_platform_interface.dart` with:

```dart
export 'src/folder_drag_event.dart';
export 'src/shell_theme.dart';
export 'src/zanshin_shell_platform.dart';
```

(Keep the file's SPDX header line above them.)

- [ ] **Step 6: Run tests, format and analyze**

Run (in `packages/zanshin_shell_platform_interface`):
- `flutter test` — Expected: all tests pass.
- `dart format .`
- `dart analyze --fatal-infos --fatal-warnings` — Expected: "No issues found!"

- [ ] **Step 7: Commit**

```bash
git add packages/zanshin_shell_platform_interface/lib/src/folder_drag_event.dart packages/zanshin_shell_platform_interface/lib/src/zanshin_shell_platform.dart packages/zanshin_shell_platform_interface/lib/zanshin_shell_platform_interface.dart packages/zanshin_shell_platform_interface/test/zanshin_shell_platform_test.dart
git commit -m "feat(shell): add folder drag events to the platform interface" -m "Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 2: macOS Dart transport

**Files:**
- Modify: `packages/zanshin_shell_macos/lib/zanshin_shell_macos.dart`
- Test: `packages/zanshin_shell_macos/test/zanshin_shell_macos_test.dart`

**Interfaces:**
- Consumes (Task 1): `FolderDragEvent` and subclasses, `FolderDragHandler`, the three `ZanshinShellPlatform` members.
- Produces: `ZanshinShellMacOS` overrides `setFolderDragHandler`, `enableFolderDrops` (invokes `attach {viewId}`), `disableFolderDrops` (invokes `detach {viewId}`) on `MethodChannel('zanshin_shell/folder_drop')`. Native calls `dragEntered {viewId:int, x:double, y:double, paths:List}`, `dragUpdated {viewId, x, y}`, `dragExited {viewId}`, `dropped {viewId, x, y, paths}` are decoded, passed to the handler, and its `bool` is the reply. Malformed calls reply with a `PlatformException` code `bad-args`.

- [ ] **Step 1: Write the failing tests**

In `packages/zanshin_shell_macos/test/zanshin_shell_macos_test.dart`, append this group at the end of `main()` (after the `'onThemeChanged emits…'` test; the existing `shell` variable and `setUp` stay as they are):

```dart
  group('folder drops', () {
    const folderChannel = MethodChannel('zanshin_shell/folder_drop');
    const codec = StandardMethodCodec();
    final folderLog = <MethodCall>[];

    TestDefaultBinaryMessenger messenger() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    /// Delivers a native folder drag call to Dart and decodes the reply.
    Future<Object?> nativeCall(String method, Map<String, Object?> arguments) => messenger()
        .handlePlatformMessage(folderChannel.name, codec.encodeMethodCall(MethodCall(method, arguments)), null)
        .then((reply) => codec.decodeEnvelope(reply!));

    setUp(() {
      folderLog.clear();
      messenger().setMockMethodCallHandler(folderChannel, (call) async {
        folderLog.add(call);
        return null;
      });
    });

    tearDown(() {
      messenger().setMockMethodCallHandler(folderChannel, null);
      shell.setFolderDragHandler(null);
    });

    test('enableFolderDrops and disableFolderDrops attach and detach the view', () async {
      await shell.enableFolderDrops(7);
      await shell.disableFolderDrops(7);
      expect(folderLog.map((call) => call.method), ['attach', 'detach']);
      expect(folderLog.map((call) => call.arguments), [
        {'viewId': 7},
        {'viewId': 7},
      ]);
    });

    test('native drag calls reach the handler as events and return its answer', () async {
      final events = <FolderDragEvent>[];
      shell.setFolderDragHandler((event) {
        events.add(event);
        return event is! FolderDragUpdated;
      });

      expect(
        await nativeCall('dragEntered', {
          'viewId': 1,
          'x': 10.0,
          'y': 20.0,
          'paths': ['/a', '/b'],
        }),
        isTrue,
      );
      expect(await nativeCall('dragUpdated', {'viewId': 1, 'x': 11.0, 'y': 21.0}), isFalse);
      expect(await nativeCall('dragExited', {'viewId': 1}), isTrue);
      expect(
        await nativeCall('dropped', {
          'viewId': 2,
          'x': 12.0,
          'y': 22.0,
          'paths': ['/c'],
        }),
        isTrue,
      );

      expect(events, [
        isA<FolderDragEntered>()
            .having((event) => event.viewId, 'viewId', 1)
            .having((event) => event.position, 'position', const Offset(10, 20))
            .having((event) => event.paths, 'paths', ['/a', '/b']),
        isA<FolderDragUpdated>()
            .having((event) => event.viewId, 'viewId', 1)
            .having((event) => event.position, 'position', const Offset(11, 21)),
        isA<FolderDragExited>().having((event) => event.viewId, 'viewId', 1),
        isA<FolderDropped>()
            .having((event) => event.viewId, 'viewId', 2)
            .having((event) => event.position, 'position', const Offset(12, 22))
            .having((event) => event.paths, 'paths', ['/c']),
      ]);
    });

    test('malformed native calls answer with a bad-args error', () async {
      shell.setFolderDragHandler((_) => true);
      final Matcher badArgs = throwsA(isA<PlatformException>().having((error) => error.code, 'code', 'bad-args'));
      await expectLater(nativeCall('dragUpdated', {'viewId': 1, 'x': 'left', 'y': 2.0}), badArgs);
      await expectLater(
        nativeCall('dragEntered', {'viewId': 1, 'x': 1.0, 'y': 2.0, 'paths': <String>[]}),
        badArgs,
      );
      await expectLater(nativeCall('dragWiggled', {'viewId': 1}), badArgs);
    });

    test('clearing the handler stops answering native calls', () async {
      shell
        ..setFolderDragHandler((_) => true)
        ..setFolderDragHandler(null);
      expect(
        await messenger().handlePlatformMessage(
          folderChannel.name,
          codec.encodeMethodCall(const MethodCall('dragExited', {'viewId': 1})),
          null,
        ),
        isNull,
      );
    });
  });
```

- [ ] **Step 2: Run the tests to verify they fail**

Run (in `packages/zanshin_shell_macos`): `flutter test`
Expected: the new tests fail — `enableFolderDrops` throws `UnimplementedError` from the platform interface default, and `setFolderDragHandler` throws the same.

- [ ] **Step 3: Implement the transport**

In `packages/zanshin_shell_macos/lib/zanshin_shell_macos.dart`, add below `static const _channel = MethodChannel('zanshin_shell');`:

```dart
  static const _folderDropChannel = MethodChannel('zanshin_shell/folder_drop');
```

Append at the end of the class body (after `performTitlebarDoubleClickAction`):

```dart
  /// Installs the host→Dart handler only when asked, never in the
  /// constructor: the engine runs the generated registrant before `main`,
  /// where no binding (and so no binary messenger) exists yet.
  @override
  void setFolderDragHandler(FolderDragHandler? handler) => _folderDropChannel.setMethodCallHandler(
    handler == null ? null : (call) async => handler(_folderDragEventFrom(call)),
  );

  /// Decodes a native folder drag call. Anything malformed becomes a
  /// `bad-args` error reply, which the native side treats as a rejection.
  static FolderDragEvent _folderDragEventFrom(MethodCall call) => switch ((call.method, call.arguments)) {
    (
      'dragEntered',
      {'viewId': final int viewId, 'x': final double x, 'y': final double y, 'paths': final List<Object?> paths},
    )
        when paths.isNotEmpty =>
      FolderDragEntered(viewId: viewId, position: Offset(x, y), paths: List<String>.unmodifiable(paths)),
    ('dragUpdated', {'viewId': final int viewId, 'x': final double x, 'y': final double y}) => FolderDragUpdated(
      viewId: viewId,
      position: Offset(x, y),
    ),
    ('dragExited', {'viewId': final int viewId}) => FolderDragExited(viewId: viewId),
    (
      'dropped',
      {'viewId': final int viewId, 'x': final double x, 'y': final double y, 'paths': final List<Object?> paths},
    )
        when paths.isNotEmpty =>
      FolderDropped(viewId: viewId, position: Offset(x, y), paths: List<String>.unmodifiable(paths)),
    _ => throw PlatformException(code: 'bad-args', message: 'Malformed folder drag call: ${call.method}'),
  };

  @override
  Future<void> enableFolderDrops(int viewId) =>
      _folderDropChannel.invokeMethod<void>('attach', <String, Object?>{'viewId': viewId});

  @override
  Future<void> disableFolderDrops(int viewId) =>
      _folderDropChannel.invokeMethod<void>('detach', <String, Object?>{'viewId': viewId});
```

(`Offset` and `PlatformException` come from the existing `package:flutter/services.dart` import; do not add `dart:ui`.)

- [ ] **Step 4: Run tests, format and analyze**

Run (in `packages/zanshin_shell_macos`):
- `flutter test` — Expected: all tests pass.
- `dart format .`
- `dart analyze --fatal-infos --fatal-warnings` — Expected: "No issues found!"

- [ ] **Step 5: Commit**

```bash
git add packages/zanshin_shell_macos/lib/zanshin_shell_macos.dart packages/zanshin_shell_macos/test/zanshin_shell_macos_test.dart
git commit -m "feat(shell): carry folder drags over the macOS channel" -m "Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 3: `FolderDropTarget` widget and per-view registration

**Files:**
- Create: `packages/zanshin_shell/lib/src/folder_drop_target.dart`
- Create: `packages/zanshin_shell/lib/src/folder_drop_dispatcher.dart`
- Modify: `packages/zanshin_shell/lib/zanshin_shell.dart`
- Modify: `packages/zanshin_shell/test/zanshin_shell_test.dart` (`RecordingPlatform`)
- Test: `packages/zanshin_shell/test/folder_drop_target_test.dart` (create)

**Interfaces:**
- Consumes (Task 1): `ZanshinShellPlatform.instance`, `setFolderDragHandler`, `enableFolderDrops`, `disableFolderDrops`, `FolderDragEvent`.
- Produces:
  - `class FolderDragDetails { final List<String> paths; final Offset localPosition; final Offset globalPosition; }` (const constructor, all named `required`).
  - `class FolderDropTarget extends StatefulWidget` with `required ValueChanged<FolderDragDetails> onDrop`, `required Widget child`, `bool Function(FolderDragDetails details)? onDragUpdate`, `VoidCallback? onDragExit`.
  - `class RenderFolderDropTarget extends RenderProxyBoxWithHitTestBehavior` with a mutable field `FolderDropTarget widget` (not exported).
  - `class FolderDropDispatcher` with `static final instance`, `void retain(int viewId)`, `void release(int viewId)` (not exported).
  - Test fake `RecordingPlatform` gains `FolderDragHandler? folderDragHandler`, `Object? enableError`, and records `setFolderDragHandler:set|null`, `enableFolderDrops:<id>`, `disableFolderDrops:<id>` in `calls`.

- [ ] **Step 1: Teach the test fake the new members**

In `packages/zanshin_shell/test/zanshin_shell_test.dart`, append inside `RecordingPlatform` (after `performTitlebarDoubleClickAction`):

```dart
  /// The folder drag handler the dispatcher installed, if any.
  FolderDragHandler? folderDragHandler;

  /// When set, [enableFolderDrops] fails with this error.
  Object? enableError;

  @override
  void setFolderDragHandler(FolderDragHandler? handler) {
    calls.add('setFolderDragHandler:${handler == null ? 'null' : 'set'}');
    folderDragHandler = handler;
  }

  @override
  Future<void> enableFolderDrops(int viewId) async {
    calls.add('enableFolderDrops:$viewId');
    if (enableError case final Object error) {
      throw error;
    }
  }

  @override
  Future<void> disableFolderDrops(int viewId) async {
    calls.add('disableFolderDrops:$viewId');
  }
```

- [ ] **Step 2: Write the failing registration tests**

Create `packages/zanshin_shell/test/folder_drop_target_test.dart`:

```dart
// SPDX-License-Identifier: MIT

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin_shell/zanshin_shell.dart';
import 'package:zanshin_shell_platform_interface/zanshin_shell_platform_interface.dart';

import 'zanshin_shell_test.dart' show RecordingPlatform;

void main() {
  late RecordingPlatform platform;
  final log = <String>[];

  setUp(() {
    log.clear();
    platform = RecordingPlatform();
    ZanshinShellPlatform.instance = platform;
  });

  tearDown(() => platform.close());

  Widget harness(Widget child) => Directionality(textDirection: TextDirection.ltr, child: child);

  group('registration', () {
    testWidgets('the first target of a view enables drops and the last one disables them', (tester) async {
      final int viewId = tester.view.viewId;
      await tester.pumpWidget(
        harness(
          Column(
            children: [
              _RecordingTarget(name: 'a', log: log, child: const SizedBox(height: 50)),
              _RecordingTarget(name: 'b', log: log, child: const SizedBox(height: 50)),
            ],
          ),
        ),
      );
      expect(platform.calls, ['setFolderDragHandler:set', 'enableFolderDrops:$viewId']);

      await tester.pumpWidget(
        harness(
          Column(
            children: [
              _RecordingTarget(name: 'a', log: log, child: const SizedBox(height: 50)),
            ],
          ),
        ),
      );
      expect(platform.calls, ['setFolderDragHandler:set', 'enableFolderDrops:$viewId']);

      await tester.pumpWidget(harness(const SizedBox.shrink()));
      expect(platform.calls, [
        'setFolderDragHandler:set',
        'enableFolderDrops:$viewId',
        'disableFolderDrops:$viewId',
        'setFolderDragHandler:null',
      ]);
    });

    testWidgets('a failing enable is reported, not thrown into the tree', (tester) async {
      platform.enableError = PlatformException(code: 'unknown-view');
      await tester.pumpWidget(harness(_RecordingTarget(name: 'a', log: log)));
      await tester.pump();
      expect(
        tester.takeException(),
        isA<PlatformException>().having((error) => error.code, 'code', 'unknown-view'),
      );
    });
  });
}

/// A [FolderDropTarget] that logs its callbacks as `name:callback …` entries.
class _RecordingTarget extends StatelessWidget {
  const _RecordingTarget({required this.name, required this.log, this.accepts = true, this.child});

  final String name;
  final List<String> log;
  final bool accepts;
  final Widget? child;

  @override
  Widget build(BuildContext context) => FolderDropTarget(
    onDragUpdate: (details) {
      log.add('$name:update ${details.localPosition}');
      return accepts;
    },
    onDragExit: () => log.add('$name:exit'),
    onDrop: (details) => log.add('$name:drop ${details.paths} ${details.localPosition} ${details.globalPosition}'),
    child: child ?? const SizedBox.expand(),
  );
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run (in `packages/zanshin_shell`): `flutter test test/folder_drop_target_test.dart`
Expected: compilation fails — "Method not found: 'FolderDropTarget'".

- [ ] **Step 4: Create the widget and render object**

Create `packages/zanshin_shell/lib/src/folder_drop_target.dart`:

```dart
// SPDX-License-Identifier: MIT

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import 'folder_drop_dispatcher.dart';

/// A folder drag over a [FolderDropTarget].
@immutable
class FolderDragDetails {
  const FolderDragDetails({required this.paths, required this.localPosition, required this.globalPosition});

  /// The absolute paths of the dragged folders; never empty.
  final List<String> paths;

  /// The pointer position in the target's coordinate space.
  final Offset localPosition;

  /// The pointer position in the view's logical pixels.
  final Offset globalPosition;
}

/// Accepts folders dragged in from other apps, such as Finder (macOS).
///
/// The target is the innermost [FolderDropTarget] under the pointer, found
/// with the framework's own hit test: clipping, transforms and widgets painted
/// on top all count. A target covers its whole box but never keeps pointer
/// events from reaching anything else. When the innermost target rejects a
/// drop, outer targets are not asked.
///
/// Every visit of a target — from its first [onDragUpdate] until the drag
/// leaves it — ends with exactly one [onDragExit] or [onDrop]. Keep hover
/// styling in these callbacks rather than in a `MouseRegion`.
class FolderDropTarget extends StatefulWidget {
  const FolderDropTarget({required this.onDrop, required this.child, this.onDragUpdate, this.onDragExit, super.key});

  /// Called on enter and on every update while the drag is over this target.
  ///
  /// Returns whether a drop at [FolderDragDetails.localPosition] would be
  /// accepted, which drives the platform's drop feedback. When null, the
  /// target accepts everywhere.
  final bool Function(FolderDragDetails details)? onDragUpdate;

  /// Called when the drag leaves this target without dropping on it: it moved
  /// to another target, left the window, or was cancelled.
  final VoidCallback? onDragExit;

  /// Called when folders are dropped on this target at a position
  /// [onDragUpdate] accepted.
  final ValueChanged<FolderDragDetails> onDrop;

  /// The widget below this widget in the tree.
  final Widget child;

  @override
  State<FolderDropTarget> createState() => _FolderDropTargetState();
}

class _FolderDropTargetState extends State<FolderDropTarget> {
  /// The view this target is registered in.
  int? _viewId;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final int viewId = View.of(context).viewId;
    if (viewId == _viewId) {
      return;
    }
    if (_viewId case final int previous) {
      FolderDropDispatcher.instance.release(previous);
    }
    FolderDropDispatcher.instance.retain(viewId);
    _viewId = viewId;
  }

  @override
  void dispose() {
    if (_viewId case final int viewId) {
      FolderDropDispatcher.instance.release(viewId);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _FolderDropRegion(target: widget, child: widget.child);
}

class _FolderDropRegion extends SingleChildRenderObjectWidget {
  const _FolderDropRegion({required this.target, required super.child});

  final FolderDropTarget target;

  @override
  RenderFolderDropTarget createRenderObject(BuildContext context) => RenderFolderDropTarget(target);

  @override
  void updateRenderObject(BuildContext context, RenderFolderDropTarget renderObject) => renderObject.widget = target;
}

/// The render object of a [FolderDropTarget]; the dispatcher looks for it in
/// the hit test path.
///
/// Hit-tests translucently: it is in the path wherever its box is, without
/// keeping hit testing from reaching what lies behind it.
class RenderFolderDropTarget extends RenderProxyBoxWithHitTestBehavior {
  RenderFolderDropTarget(this.widget) : super(behavior: HitTestBehavior.translucent);

  /// The widget whose callbacks answer for this render object.
  FolderDropTarget widget;
}
```

- [ ] **Step 5: Create the dispatcher (registration only)**

Create `packages/zanshin_shell/lib/src/folder_drop_dispatcher.dart`:

```dart
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:zanshin_shell_platform_interface/zanshin_shell_platform_interface.dart';

import 'folder_drop_target.dart';

/// Routes the platform's folder drags to the [FolderDropTarget]s of each view.
///
/// Targets retain the view they live in. The first retain binds the dispatcher
/// to [ZanshinShellPlatform.instance] and the last release lets go of it, so
/// nothing touches the platform before a target exists, and a hot restart or
/// a test that swaps the platform starts clean.
class FolderDropDispatcher {
  FolderDropDispatcher._();

  /// The dispatcher every [FolderDropTarget] shares.
  static final instance = FolderDropDispatcher._();

  /// Mounted targets per view id.
  final _targets = <int, int>{};

  /// The platform the handler is installed on, while any target is mounted.
  ZanshinShellPlatform? _platform;

  /// Registers a target mounted in the view [viewId].
  void retain(int viewId) {
    final ZanshinShellPlatform platform = _platform ?? _bind();
    final int count = (_targets[viewId] ?? 0) + 1;
    _targets[viewId] = count;
    if (count == 1) {
      unawaited(_report('enabling', viewId, () => platform.enableFolderDrops(viewId)));
    }
  }

  /// Unregisters a target that left the view [viewId].
  void release(int viewId) {
    final ZanshinShellPlatform? platform = _platform;
    final int? count = _targets[viewId];
    if (platform == null || count == null) {
      return;
    }
    if (count > 1) {
      _targets[viewId] = count - 1;
      return;
    }
    _targets.remove(viewId);
    unawaited(_report('disabling', viewId, () => platform.disableFolderDrops(viewId)));
    if (_targets.isEmpty) {
      platform.setFolderDragHandler(null);
      _platform = null;
    }
  }

  ZanshinShellPlatform _bind() => _platform = ZanshinShellPlatform.instance..setFolderDragHandler(_handle);

  /// Answers the platform's folder drag events.
  bool _handle(FolderDragEvent event) => false;

  /// Runs a platform call and reports a failure instead of throwing it into
  /// the widget tree.
  Future<void> _report(String action, int viewId, Future<void> Function() call) async {
    try {
      await call();
    } catch (error, stack) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'zanshin_shell',
          context: ErrorDescription('while $action folder drops for view $viewId'),
        ),
      );
    }
  }
}
```

- [ ] **Step 6: Export the public types**

In `packages/zanshin_shell/lib/zanshin_shell.dart`, add the export between the platform-interface export and `src/window_drag_area.dart`:

```dart
export 'src/folder_drop_target.dart' show FolderDragDetails, FolderDropTarget;
```

Also update the `description:` in `packages/zanshin_shell/pubspec.yaml` to:

```yaml
description: macOS shell integration for Zanshin - system theme (day/night + accent color), native window dragging and folder drops.
```

- [ ] **Step 7: Run tests, format and analyze**

Run (in `packages/zanshin_shell`):
- `flutter test` — Expected: all tests pass (including the existing `zanshin_shell_test.dart` and `window_drag_area_test.dart`).
- `dart format .`
- `dart analyze --fatal-infos --fatal-warnings` — Expected: "No issues found!"

- [ ] **Step 8: Commit**

```bash
git add packages/zanshin_shell/lib/src/folder_drop_target.dart packages/zanshin_shell/lib/src/folder_drop_dispatcher.dart packages/zanshin_shell/lib/zanshin_shell.dart packages/zanshin_shell/pubspec.yaml packages/zanshin_shell/test/zanshin_shell_test.dart packages/zanshin_shell/test/folder_drop_target_test.dart
git commit -m "feat(shell): register FolderDropTarget views with the platform" -m "Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 4: Drag dispatch to the innermost target

**Files:**
- Modify: `packages/zanshin_shell/lib/src/folder_drop_dispatcher.dart` (full replacement below)
- Modify: `packages/zanshin_shell/lib/src/folder_drop_target.dart` (`RenderFolderDropTarget.detach`)
- Test: `packages/zanshin_shell/test/folder_drop_target_test.dart`

**Interfaces:**
- Consumes (Task 3): `FolderDropDispatcher.retain/release`, `RenderFolderDropTarget.widget`, `FolderDropTarget` callbacks; (Task 1) the four `FolderDragEvent` subclasses.
- Produces: `FolderDropDispatcher.forget(RenderFolderDropTarget target)`; the handler now implements the spec contract (innermost target, no bubbling, exit before update on target change, drop re-asks `onDragUpdate`, exactly one exit or drop per visit, callback exceptions reported as rejections, silent removal of detached targets, sessions only for views with targets).

- [ ] **Step 1: Write the failing dispatch tests**

In `packages/zanshin_shell/test/folder_drop_target_test.dart`, append this group inside `main()`, after the `'registration'` group:

```dart
  group('dispatch', () {
    bool send(FolderDragEvent event) => platform.folderDragHandler!(event);

    /// `outer` covers (0, 0)–(400, 300); `inner` sits inside it at (100, 100)–(300, 200).
    Widget nested({bool innerAccepts = true, bool withInner = true}) => harness(
      Stack(
        children: [
          Positioned(
            left: 0,
            top: 0,
            width: 400,
            height: 300,
            child: _RecordingTarget(
              name: 'outer',
              log: log,
              child: Padding(
                padding: const EdgeInsets.all(100),
                child: withInner ? _RecordingTarget(name: 'inner', log: log, accepts: innerAccepts) : null,
              ),
            ),
          ),
        ],
      ),
    );

    testWidgets('enter and updates go to the innermost target with local positions', (tester) async {
      final int viewId = tester.view.viewId;
      await tester.pumpWidget(nested());
      expect(send(FolderDragEntered(viewId: viewId, position: const Offset(150, 120), paths: const ['/a'])), isTrue);
      expect(send(FolderDragUpdated(viewId: viewId, position: const Offset(160, 130))), isTrue);
      expect(log, ['inner:update Offset(50.0, 20.0)', 'inner:update Offset(60.0, 30.0)']);
    });

    testWidgets('moving to another target exits the old one first', (tester) async {
      final int viewId = tester.view.viewId;
      await tester.pumpWidget(nested());
      send(FolderDragEntered(viewId: viewId, position: const Offset(150, 120), paths: const ['/a']));
      send(FolderDragUpdated(viewId: viewId, position: const Offset(20, 20)));
      expect(log, ['inner:update Offset(50.0, 20.0)', 'inner:exit', 'outer:update Offset(20.0, 20.0)']);
    });

    testWidgets('leaving every target exits and rejects', (tester) async {
      final int viewId = tester.view.viewId;
      await tester.pumpWidget(nested());
      send(FolderDragEntered(viewId: viewId, position: const Offset(20, 20), paths: const ['/a']));
      expect(send(FolderDragUpdated(viewId: viewId, position: const Offset(600, 500))), isFalse);
      expect(log, ['outer:update Offset(20.0, 20.0)', 'outer:exit']);
    });

    testWidgets('an exited drag ends the visit', (tester) async {
      final int viewId = tester.view.viewId;
      await tester.pumpWidget(nested());
      send(FolderDragEntered(viewId: viewId, position: const Offset(20, 20), paths: const ['/a']));
      send(FolderDragExited(viewId: viewId));
      expect(log, ['outer:update Offset(20.0, 20.0)', 'outer:exit']);
    });

    testWidgets('a new enter exits the target of an unfinished drag', (tester) async {
      final int viewId = tester.view.viewId;
      await tester.pumpWidget(nested());
      send(FolderDragEntered(viewId: viewId, position: const Offset(150, 120), paths: const ['/a']));
      send(FolderDragEntered(viewId: viewId, position: const Offset(20, 20), paths: const ['/a']));
      expect(log, ['inner:update Offset(50.0, 20.0)', 'inner:exit', 'outer:update Offset(20.0, 20.0)']);
    });

    testWidgets('a drop asks the target once more, then drops without an exit', (tester) async {
      final int viewId = tester.view.viewId;
      await tester.pumpWidget(nested());
      send(FolderDragEntered(viewId: viewId, position: const Offset(150, 120), paths: const ['/a', '/b']));
      expect(
        send(FolderDropped(viewId: viewId, position: const Offset(155, 125), paths: const ['/a', '/b'])),
        isTrue,
      );
      expect(log, [
        'inner:update Offset(50.0, 20.0)',
        'inner:update Offset(55.0, 25.0)',
        'inner:drop [/a, /b] Offset(55.0, 25.0) Offset(155.0, 125.0)',
      ]);
    });

    testWidgets('a drop without an enter is still evaluated', (tester) async {
      final int viewId = tester.view.viewId;
      await tester.pumpWidget(nested());
      expect(send(FolderDropped(viewId: viewId, position: const Offset(20, 20), paths: const ['/x'])), isTrue);
      expect(log, ['outer:update Offset(20.0, 20.0)', 'outer:drop [/x] Offset(20.0, 20.0) Offset(20.0, 20.0)']);
    });

    testWidgets('a rejected drop exits instead and never asks an outer target', (tester) async {
      final int viewId = tester.view.viewId;
      await tester.pumpWidget(nested(innerAccepts: false));
      expect(send(FolderDragEntered(viewId: viewId, position: const Offset(150, 120), paths: const ['/a'])), isFalse);
      expect(send(FolderDropped(viewId: viewId, position: const Offset(150, 120), paths: const ['/a'])), isFalse);
      expect(log, ['inner:update Offset(50.0, 20.0)', 'inner:update Offset(50.0, 20.0)', 'inner:exit']);
    });

    testWidgets('a target without onDragUpdate accepts everywhere', (tester) async {
      final int viewId = tester.view.viewId;
      await tester.pumpWidget(
        harness(FolderDropTarget(onDrop: (details) => log.add('drop ${details.paths}'), child: const SizedBox.expand())),
      );
      expect(send(FolderDragEntered(viewId: viewId, position: const Offset(10, 10), paths: const ['/a'])), isTrue);
      expect(send(FolderDropped(viewId: viewId, position: const Offset(10, 10), paths: const ['/a'])), isTrue);
      expect(log, ['drop [/a]']);
    });

    testWidgets('local positions follow transforms', (tester) async {
      final int viewId = tester.view.viewId;
      await tester.pumpWidget(
        harness(
          Align(
            alignment: Alignment.topLeft,
            child: Transform.translate(
              offset: const Offset(50, 50),
              child: Transform.scale(
                scale: 2,
                alignment: Alignment.topLeft,
                child: SizedBox(width: 100, height: 100, child: _RecordingTarget(name: 'scaled', log: log)),
              ),
            ),
          ),
        ),
      );
      send(FolderDragEntered(viewId: viewId, position: const Offset(70, 90), paths: const ['/a']));
      expect(log, ['scaled:update Offset(10.0, 20.0)']);
    });

    testWidgets('a target outside the scroll viewport is not hit', (tester) async {
      final int viewId = tester.view.viewId;
      await tester.pumpWidget(
        harness(
          Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 200,
              height: 100,
              child: ListView(
                children: [
                  SizedBox(height: 100, child: _RecordingTarget(name: 'visible', log: log)),
                  SizedBox(height: 100, child: _RecordingTarget(name: 'cached', log: log)),
                ],
              ),
            ),
          ),
        ),
      );
      // `cached` is laid out below the 100 px viewport, where (10, 150) would hit it without clipping.
      expect(send(FolderDragEntered(viewId: viewId, position: const Offset(10, 150), paths: const ['/a'])), isFalse);
      expect(send(FolderDragUpdated(viewId: viewId, position: const Offset(10, 50))), isTrue);
      expect(log, ['visible:update Offset(10.0, 50.0)']);
    });

    testWidgets('a target removed mid-drag gets no further callbacks', (tester) async {
      final int viewId = tester.view.viewId;
      await tester.pumpWidget(nested());
      send(FolderDragEntered(viewId: viewId, position: const Offset(150, 120), paths: const ['/a']));
      await tester.pumpWidget(nested(withInner: false));
      send(FolderDragUpdated(viewId: viewId, position: const Offset(20, 20)));
      expect(log, ['inner:update Offset(50.0, 20.0)', 'outer:update Offset(20.0, 20.0)']);
    });

    testWidgets('events for another view do nothing', (tester) async {
      final int viewId = tester.view.viewId;
      await tester.pumpWidget(nested());
      expect(
        send(FolderDragEntered(viewId: viewId + 1, position: const Offset(150, 120), paths: const ['/a'])),
        isFalse,
      );
      expect(send(FolderDropped(viewId: viewId + 1, position: const Offset(150, 120), paths: const ['/a'])), isFalse);
      expect(log, isEmpty);
    });

    testWidgets('an exception in a callback is reported and rejects', (tester) async {
      final int viewId = tester.view.viewId;
      await tester.pumpWidget(
        harness(
          FolderDropTarget(
            onDragUpdate: (_) => throw StateError('boom'),
            onDrop: (_) {},
            child: const SizedBox.expand(),
          ),
        ),
      );
      expect(send(FolderDragEntered(viewId: viewId, position: const Offset(10, 10), paths: const ['/a'])), isFalse);
      expect(tester.takeException(), isA<StateError>());
    });
  });
```

- [ ] **Step 2: Run the tests to verify they fail**

Run (in `packages/zanshin_shell`): `flutter test test/folder_drop_target_test.dart`
Expected: the `'registration'` tests pass; most `'dispatch'` tests fail because the stub handler answers `false` and calls nothing (e.g. "Expected: true Actual: <false>"). `'events for another view do nothing'` already passes — it pins behavior the real dispatcher must keep.

- [ ] **Step 3: Replace the dispatcher**

Replace the whole content of `packages/zanshin_shell/lib/src/folder_drop_dispatcher.dart` with:

```dart
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:zanshin_shell_platform_interface/zanshin_shell_platform_interface.dart';

import 'folder_drop_target.dart';

/// The innermost target under a position, with the position in its space.
typedef _Hit = ({RenderFolderDropTarget target, Offset localPosition});

/// Routes the platform's folder drags to the [FolderDropTarget]s of each view.
///
/// Targets retain the view they live in. The first retain binds the dispatcher
/// to [ZanshinShellPlatform.instance] and the last release lets go of it, so
/// nothing touches the platform before a target exists, and a hot restart or
/// a test that swaps the platform starts clean.
///
/// The target of a drag is the innermost [RenderFolderDropTarget] in the
/// framework's hit test at the drag position. Outer targets are never asked,
/// and every visit of a target ends with exactly one `onDragExit` or
/// `onDrop`.
class FolderDropDispatcher {
  FolderDropDispatcher._();

  /// The dispatcher every [FolderDropTarget] shares.
  static final instance = FolderDropDispatcher._();

  /// Mounted targets per view id.
  final _targets = <int, int>{};

  /// The drag in progress per view id.
  final _sessions = <int, _Session>{};

  /// The platform the handler is installed on, while any target is mounted.
  ZanshinShellPlatform? _platform;

  /// Registers a target mounted in the view [viewId].
  void retain(int viewId) {
    final ZanshinShellPlatform platform = _platform ?? _bind();
    final int count = (_targets[viewId] ?? 0) + 1;
    _targets[viewId] = count;
    if (count == 1) {
      unawaited(_report('enabling', viewId, () => platform.enableFolderDrops(viewId)));
    }
  }

  /// Unregisters a target that left the view [viewId].
  void release(int viewId) {
    final ZanshinShellPlatform? platform = _platform;
    final int? count = _targets[viewId];
    if (platform == null || count == null) {
      return;
    }
    if (count > 1) {
      _targets[viewId] = count - 1;
      return;
    }
    _targets.remove(viewId);
    _sessions.remove(viewId);
    unawaited(_report('disabling', viewId, () => platform.disableFolderDrops(viewId)));
    if (_targets.isEmpty) {
      platform.setFolderDragHandler(null);
      _platform = null;
      _sessions.clear();
    }
  }

  /// Takes [target] out of every drag without calling it: it left the tree.
  void forget(RenderFolderDropTarget target) {
    for (final _Session session in _sessions.values) {
      if (identical(session.target, target)) {
        session.target = null;
      }
    }
  }

  ZanshinShellPlatform _bind() => _platform = ZanshinShellPlatform.instance..setFolderDragHandler(_handle);

  /// Answers the platform's folder drag events.
  bool _handle(FolderDragEvent event) => switch (event) {
    FolderDragEntered(:final viewId, :final position, :final paths) => _enter(viewId, position, paths),
    FolderDragUpdated(:final viewId, :final position) => _update(viewId, position),
    FolderDragExited(:final viewId) => _exit(viewId),
    FolderDropped(:final viewId, :final position, :final paths) => _drop(viewId, position, paths),
  };

  bool _enter(int viewId, Offset position, List<String> paths) {
    _exit(viewId);
    if (!_targets.containsKey(viewId)) {
      return false;
    }
    _sessions[viewId] = _Session(paths);
    return _update(viewId, position);
  }

  bool _update(int viewId, Offset position) {
    final _Session? session = _sessions[viewId];
    if (session == null) {
      return false;
    }
    final _Hit? hit = _hitTest(viewId, position);
    if (!identical(hit?.target, session.target)) {
      _leave(session);
      session.target = hit?.target;
    }
    if (hit == null) {
      return false;
    }
    return _ask(
      hit.target,
      FolderDragDetails(paths: session.paths, localPosition: hit.localPosition, globalPosition: position),
    );
  }

  bool _exit(int viewId) {
    if (_sessions.remove(viewId) case final _Session session) {
      _leave(session);
    }
    return false;
  }

  /// A drop carries its own paths, so it is evaluated even without a session.
  bool _drop(int viewId, Offset position, List<String> paths) {
    final _Session session = _sessions.remove(viewId) ?? _Session(paths);
    final _Hit? hit = _targets.containsKey(viewId) ? _hitTest(viewId, position) : null;
    if (!identical(hit?.target, session.target)) {
      _leave(session);
    }
    if (hit == null) {
      return false;
    }
    final target = hit.target;
    final details = FolderDragDetails(paths: paths, localPosition: hit.localPosition, globalPosition: position);
    if (!_ask(target, details)) {
      _call('onDragExit', () => target.widget.onDragExit?.call());
      return false;
    }
    _call('onDrop', () => target.widget.onDrop(details));
    return true;
  }

  /// Ends the visit of the session's current target, if there is one.
  void _leave(_Session session) {
    final RenderFolderDropTarget? target = session.target;
    session.target = null;
    if (target != null) {
      _call('onDragExit', () => target.widget.onDragExit?.call());
    }
  }

  /// Whether [target] accepts [details]; a throwing callback rejects.
  bool _ask(RenderFolderDropTarget target, FolderDragDetails details) {
    var accepted = false;
    _call('onDragUpdate', () => accepted = target.widget.onDragUpdate?.call(details) ?? true);
    return accepted;
  }

  /// The innermost target under [position] in the view [viewId].
  _Hit? _hitTest(int viewId, Offset position) {
    final result = HitTestResult();
    WidgetsBinding.instance.hitTestInView(result, position, viewId);
    for (final HitTestEntry entry in result.path) {
      if (entry case BoxHitTestEntry(target: final RenderFolderDropTarget target, :final localPosition)) {
        return (target: target, localPosition: localPosition);
      }
    }
    return null;
  }

  /// Runs a target callback and reports what it throws.
  void _call(String callback, VoidCallback body) {
    try {
      body();
    } catch (error, stack) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'zanshin_shell',
          context: ErrorDescription('while calling FolderDropTarget.$callback'),
        ),
      );
    }
  }

  /// Runs a platform call and reports a failure instead of throwing it into
  /// the widget tree.
  Future<void> _report(String action, int viewId, Future<void> Function() call) async {
    try {
      await call();
    } catch (error, stack) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'zanshin_shell',
          context: ErrorDescription('while $action folder drops for view $viewId'),
        ),
      );
    }
  }
}

/// A folder drag over one view.
class _Session {
  _Session(this.paths);

  /// The dragged folders.
  final List<String> paths;

  /// The target the drag is visiting, if any.
  RenderFolderDropTarget? target;
}
```

- [ ] **Step 4: Forget detached targets**

In `packages/zanshin_shell/lib/src/folder_drop_target.dart`, append inside `RenderFolderDropTarget` (after the `widget` field):

```dart
  @override
  void detach() {
    FolderDropDispatcher.instance.forget(this);
    super.detach();
  }
```

- [ ] **Step 5: Run tests, format and analyze**

Run (in `packages/zanshin_shell`):
- `flutter test` — Expected: all tests pass.
- `dart format .`
- `dart analyze --fatal-infos --fatal-warnings` — Expected: "No issues found!"

- [ ] **Step 6: Commit**

```bash
git add packages/zanshin_shell/lib/src/folder_drop_dispatcher.dart packages/zanshin_shell/lib/src/folder_drop_target.dart packages/zanshin_shell/test/folder_drop_target_test.dart
git commit -m "feat(shell): dispatch folder drags to the innermost FolderDropTarget" -m "Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 5: Native drop view (Swift)

**Files:**
- Create: `packages/zanshin_shell_macos/macos/zanshin_shell_macos/Sources/zanshin_shell_macos/FolderPasteboard.swift`
- Create: `packages/zanshin_shell_macos/macos/zanshin_shell_macos/Sources/zanshin_shell_macos/FolderDropView.swift`
- Create: `packages/zanshin_shell_macos/macos/zanshin_shell_macos/Sources/zanshin_shell_macos/FolderDropHost.swift`
- Modify: `packages/zanshin_shell_macos/macos/zanshin_shell_macos/Sources/zanshin_shell_macos/ZanshinShellPlugin.swift`
- Modify: `packages/zanshin_shell_macos/macos/zanshin_shell_macos.podspec` (description only)
- Check (not committed): `/tmp/zanshin-folder-drop-check/main.swift` (any scratch directory outside the repo)

**Interfaces:**
- Consumes (Task 2): the channel protocol — Dart sends `attach`/`detach {viewId}`; Dart answers `dragEntered`/`dragUpdated` with a `bool`.
- Produces: `enum FolderPasteboard { static func folderPaths(on: NSPasteboard) -> [String] }`, `final class FolderDropView: NSView` (`init(viewId: FlutterViewIdentifier, channel: FlutterMethodChannel)`), `final class FolderDropHost` (`init(messenger: FlutterBinaryMessenger)`), owned by `ZanshinShellPlugin`. The Swift package and the podspec already compile every file in `Sources/zanshin_shell_macos/`, so no build file changes.

- [ ] **Step 1: Write the folder filter check**

Create `/tmp/zanshin-folder-drop-check/main.swift`:

```swift
import Cocoa

// Checks FolderPasteboard against real items. Argument: a scratch directory.
let base = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let fm = FileManager.default
try? fm.removeItem(at: base)
try! fm.createDirectory(at: base, withIntermediateDirectories: true)

let folder = base.appendingPathComponent("folder", isDirectory: true)
try! fm.createDirectory(at: folder, withIntermediateDirectories: true)
let file = base.appendingPathComponent("file.txt")
try! Data("x".utf8).write(to: file)
let app = base.appendingPathComponent("Some.app", isDirectory: true)
try! fm.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
let symlink = base.appendingPathComponent("symlink")
try! fm.createSymbolicLink(at: symlink, withDestinationURL: folder)
let alias = base.appendingPathComponent("alias")
try! URL.writeBookmarkData(folder.bookmarkData(options: .suitableForBookmarkFile), to: alias)
let fileAlias = base.appendingPathComponent("file-alias")
try! URL.writeBookmarkData(file.bookmarkData(options: .suitableForBookmarkFile), to: fileAlias)
let broken = base.appendingPathComponent("broken-link")
try! fm.createSymbolicLink(atPath: broken.path, withDestinationPath: base.appendingPathComponent("missing").path)

let pasteboard = NSPasteboard(name: NSPasteboard.Name("de.dasralph.zanshin.folder-drop-check"))
pasteboard.clearContents()
pasteboard.writeObjects([folder, file, app, symlink, alias, fileAlias, broken].map { $0 as NSURL })

let canonical = { (path: String) in URL(fileURLWithPath: path).resolvingSymlinksInPath().path }
let actual = FolderPasteboard.folderPaths(on: pasteboard).map(canonical)
// The folder itself, the symlink to it and the alias to it; file, package, file alias and broken link are dropped.
let expected = Array(repeating: canonical(folder.path), count: 3)
pasteboard.releaseGlobally()
print(actual)
if actual != expected {
    print("FAIL: expected \(expected)")
    exit(1)
}
print("OK")
```

- [ ] **Step 2: Run the check to verify it fails**

Run (repo root): `swiftc -o /tmp/zanshin-folder-drop-check/check /tmp/zanshin-folder-drop-check/main.swift`
Expected: error "cannot find 'FolderPasteboard' in scope".

- [ ] **Step 3: Implement the folder filter**

Create `packages/zanshin_shell_macos/macos/zanshin_shell_macos/Sources/zanshin_shell_macos/FolderPasteboard.swift`:

```swift
// SPDX-License-Identifier: MIT

import Cocoa

/// Reads the folders a drag carries off its pasteboard.
enum FolderPasteboard {
    /// The absolute paths of the folders on `pasteboard`.
    ///
    /// Takes the file URLs, resolves Finder aliases and symlinks, and keeps
    /// what is a directory but not a package: Finder treats packages (`.app`,
    /// `.xcodeproj`, ...) as files, so they do not count as folders here
    /// either. An item that cannot be resolved - a broken alias or symlink -
    /// is skipped. The resolved path is returned, because an alias file is no
    /// folder anyone could open.
    static func folderPaths(on pasteboard: NSPasteboard) -> [String] {
        let urls =
            pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.compactMap { url in
            guard let resolved = try? URL(resolvingAliasFileAt: url),
                let values = try? resolved.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]),
                values.isDirectory == true,
                values.isPackage != true
            else {
                return nil
            }
            return resolved.path
        }
    }
}
```

- [ ] **Step 4: Run the check to verify it passes**

Run (repo root, two commands):
- `swiftc -o /tmp/zanshin-folder-drop-check/check packages/zanshin_shell_macos/macos/zanshin_shell_macos/Sources/zanshin_shell_macos/FolderPasteboard.swift /tmp/zanshin-folder-drop-check/main.swift`
- `/tmp/zanshin-folder-drop-check/check /tmp/zanshin-folder-drop-check/fixtures`

Expected: the three canonical folder paths, then `OK`.

- [ ] **Step 5: Create the drop view**

Create `packages/zanshin_shell_macos/macos/zanshin_shell_macos/Sources/zanshin_shell_macos/FolderDropView.swift`:

```swift
// SPDX-License-Identifier: MIT

import Cocoa
import FlutterMacOS

/// An invisible layer over a Flutter view that receives folder drags from
/// other apps and reports them to Dart over the `zanshin_shell/folder_drop`
/// channel; Dart decides with its own hit test whether a drop would land.
///
/// Mouse events never stop here: `hitTest(_:)` returns `nil`, so clicks,
/// scrolling and cursor updates keep reaching the Flutter view. AppKit finds
/// drag destinations with a separate hit test (`_hitTest:dragTypes:`) that
/// does not consult that override, which is what makes an invisible drop
/// layer possible.
///
/// Dart answers asynchronously, AppKit asks synchronously: the view keeps
/// Dart's last answer and returns the matching operation. At most one position
/// is on its way to Dart at a time; a newer one replaces the pending one.
final class FolderDropView: NSView {
    /// One drag carrying folders over this view.
    private final class Session {
        let generation: Int
        let paths: [String]
        /// Dart's last answer: a drop at the last reported position would be accepted.
        var accepted = false
        /// A position was sent to Dart and is not answered yet.
        var inFlight = false
        /// The latest position that arrived while another one was in flight.
        var pending: NSPoint?

        init(generation: Int, paths: [String]) {
            self.generation = generation
            self.paths = paths
        }
    }

    private let viewId: FlutterViewIdentifier
    private let channel: FlutterMethodChannel
    private var session: Session?
    /// Counts drags, so a late answer from an earlier drag is recognised.
    private var generation = 0

    init(viewId: FlutterViewIdentifier, channel: FlutterMethodChannel) {
        self.viewId = viewId
        self.channel = channel
        super.init(frame: .zero)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Event transparency

    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }

    override var acceptsFirstResponder: Bool {
        return false
    }

    /// A transparent view would otherwise count as window-drag area in the
    /// full-size titlebar strip - the reason `DragInterceptorView` in the
    /// runner says the same.
    override var mouseDownCanMoveWindow: Bool {
        return false
    }

    /// Top-left origin like the Flutter view it covers, so its points are
    /// Flutter's logical pixels.
    override var isFlipped: Bool {
        return true
    }

    // MARK: - NSDraggingDestination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let paths = FolderPasteboard.folderPaths(on: sender.draggingPasteboard)
        guard !paths.isEmpty else {
            session = nil
            return []
        }
        generation += 1
        session = Session(generation: generation, paths: paths)
        send("dragEntered", at: location(of: sender), paths: paths)
        return operation(for: sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let session = session else { return [] }
        if session.inFlight {
            session.pending = location(of: sender)
        } else {
            send("dragUpdated", at: location(of: sender))
        }
        return operation(for: sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        endSession()
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        return !operation(for: sender).isEmpty
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let session = session else { return false }
        self.session = nil
        channel.invokeMethod("dropped", arguments: arguments(at: location(of: sender), paths: session.paths))
        return true
    }

    /// A refused or cancelled drop does not always come with
    /// `draggingExited`; ending the session here keeps Dart from holding on
    /// to a hover state.
    override func draggingEnded(_ sender: NSDraggingInfo) {
        endSession()
    }

    // MARK: - Session

    private func endSession() {
        guard session != nil else { return }
        session = nil
        channel.invokeMethod("dragExited", arguments: ["viewId": viewId])
    }

    /// Sends a position to Dart and stores the answer for the drag it belongs
    /// to, then sends the position that arrived meanwhile, if any.
    private func send(_ method: String, at point: NSPoint, paths: [String]? = nil) {
        guard let current = session else { return }
        current.inFlight = true
        channel.invokeMethod(method, arguments: arguments(at: point, paths: paths)) { [weak self] reply in
            guard let self = self, let session = self.session, session.generation == current.generation else {
                return
            }
            // No Dart handler (FlutterMethodNotImplemented) or an error reply is a rejection.
            session.accepted = reply as? Bool ?? false
            session.inFlight = false
            if let pending = session.pending {
                session.pending = nil
                self.send("dragUpdated", at: pending)
            }
        }
    }

    private func arguments(at point: NSPoint, paths: [String]?) -> [String: Any] {
        var arguments: [String: Any] = ["viewId": viewId, "x": Double(point.x), "y": Double(point.y)]
        if let paths = paths {
            arguments["paths"] = paths
        }
        return arguments
    }

    private func location(of sender: NSDraggingInfo) -> NSPoint {
        return convert(sender.draggingLocation, from: nil)
    }

    /// The operation for Dart's last answer, within what the drag source
    /// allows: copy, else link, else generic.
    private func operation(for sender: NSDraggingInfo) -> NSDragOperation {
        guard session?.accepted == true else { return [] }
        let allowed = sender.draggingSourceOperationMask
        for candidate: NSDragOperation in [.copy, .link, .generic] where allowed.contains(candidate) {
            return candidate
        }
        return []
    }
}
```

- [ ] **Step 6: Create the host**

Create `packages/zanshin_shell_macos/macos/zanshin_shell_macos/Sources/zanshin_shell_macos/FolderDropHost.swift`:

```swift
// SPDX-License-Identifier: MIT

import Cocoa
import FlutterMacOS

/// Native half of the `zanshin_shell/folder_drop` channel: puts a
/// `FolderDropView` on each Flutter view Dart enables folder drops for.
///
/// Dart names a view by its `FlutterViewController.viewIdentifier`. Every
/// Flutter view of the app is the content view controller of a window the
/// engine created for Dart, so the host looks it up among the app's windows
/// instead of tracking windows itself. The drop view goes on top of the
/// controller's view - the engine's `FlutterViewWrapper`, which reports only
/// the Flutter view to accessibility, so the extra subview changes nothing
/// there.
final class FolderDropHost {
    /// A drop view the host does not keep alive: it lives as long as its window.
    private struct WeakDropView {
        weak var view: FolderDropView?
    }

    private let channel: FlutterMethodChannel
    private let messenger: FlutterBinaryMessenger
    private var dropViews: [FlutterViewIdentifier: WeakDropView] = [:]

    init(messenger: FlutterBinaryMessenger) {
        self.messenger = messenger
        channel = FlutterMethodChannel(name: "zanshin_shell/folder_drop", binaryMessenger: messenger)
        channel.setMethodCallHandler { [weak self] call, result in
            self?.handle(call, result: result)
        }
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any], let viewId = args["viewId"] as? Int else {
            result(FlutterError(code: "bad-args", message: "expected a viewId", details: nil))
            return
        }
        let id = FlutterViewIdentifier(viewId)
        switch call.method {
        case "attach":
            guard let controller = flutterViewController(id) else {
                result(FlutterError(code: "unknown-view", message: "no Flutter view with id \(viewId)", details: nil))
                return
            }
            attach(to: controller, id: id)
            result(nil)
        case "detach":
            dropViews.removeValue(forKey: id)?.view?.removeFromSuperview()
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    /// Puts a drop view on top of the controller's view; idempotent.
    private func attach(to controller: FlutterViewController, id: FlutterViewIdentifier) {
        if let existing = dropViews[id]?.view, existing.superview === controller.view {
            return
        }
        dropViews = dropViews.filter { $0.value.view != nil }
        let dropView = FolderDropView(viewId: id, channel: channel)
        dropView.frame = controller.view.bounds
        dropView.autoresizingMask = [.width, .height]
        controller.view.addSubview(dropView)
        dropViews[id] = WeakDropView(view: dropView)
    }

    /// The attached view controller of this plugin's engine with the given id.
    private func flutterViewController(_ id: FlutterViewIdentifier) -> FlutterViewController? {
        let ownMessenger = messenger as AnyObject
        return NSApp.windows.lazy
            .compactMap { $0.contentViewController as? FlutterViewController }
            .first { controller in
                // Reading `viewIdentifier` of a detached controller asserts.
                controller.attached() && controller.viewIdentifier == id
                    && (controller.engine.binaryMessenger as AnyObject) === ownMessenger
            }
    }
}
```

- [ ] **Step 7: Let the plugin own the host**

In `ZanshinShellPlugin.swift`:

1. Extend the class doc comment's first paragraph with one sentence:

```swift
/// Native half of the bidirectional "zanshin_shell" channel.
///
/// Pushes system theme changes (dark/light + accent color) to Dart and
/// executes window commands (drag, appearance override, titlebar
/// double-click action) on the window that hosts the Flutter view. It also
/// owns the `FolderDropHost` behind the "zanshin_shell/folder_drop" channel.
```

2. Replace `register(with:)` and the initializer's signature/assignments:

```swift
    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "zanshin_shell", binaryMessenger: registrar.messenger)
        let instance = ZanshinShellPlugin(
            channel: channel, view: registrar.view, folderDrops: FolderDropHost(messenger: registrar.messenger))
        registrar.addMethodCallDelegate(instance, channel: channel)
    }
```

Add the property after `private weak var view: NSView?`:

```swift
    /// The folder drop channel's host; lives as long as the plugin.
    private let folderDrops: FolderDropHost
```

and change the initializer head to:

```swift
    init(channel: FlutterMethodChannel, view: NSView?, folderDrops: FolderDropHost) {
        self.channel = channel
        self.view = view
        self.folderDrops = folderDrops
        super.init()
```

(the rest of the initializer body stays unchanged).

3. In `packages/zanshin_shell_macos/macos/zanshin_shell_macos.podspec`, change the description line to:

```ruby
  s.description      = 'macOS shell integration (system theme, window drag, folder drops) for Zanshin.'
```

- [ ] **Step 8: Build the app to compile the plugin**

Run (in `app/`): `flutter build macos --debug`
Expected: `✓ Built build/macos/Build/Products/Debug/zanshin.app` with no Swift errors.

- [ ] **Step 9: Commit**

```bash
git add packages/zanshin_shell_macos/macos/zanshin_shell_macos/Sources/zanshin_shell_macos/FolderPasteboard.swift packages/zanshin_shell_macos/macos/zanshin_shell_macos/Sources/zanshin_shell_macos/FolderDropView.swift packages/zanshin_shell_macos/macos/zanshin_shell_macos/Sources/zanshin_shell_macos/FolderDropHost.swift packages/zanshin_shell_macos/macos/zanshin_shell_macos/Sources/zanshin_shell_macos/ZanshinShellPlugin.swift packages/zanshin_shell_macos/macos/zanshin_shell_macos.podspec
git commit -m "feat(shell): add the native folder drop view to zanshin_shell_macos" -m "Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 6: Tree drop logic

**Files:**
- Create: `app/lib/src/features/projects/tree_drop.dart`
- Test: `app/test/features/projects/tree_drop_test.dart`

**Interfaces:**
- Consumes: `TreeSliverNode<T>` from `package:flutter/widgets.dart` (`content`, `children`, `isExpanded`).
- Produces:
  - `enum TreeDropPlacement { before, inside, after }`
  - `TreeDropPlacement treeDropPlacement({required double dy, required double rowExtent, required bool canHaveChildren})`
  - `class TreeInsertionPoint<T> { final TreeSliverNode<T>? parent; final int index; final int depth; }` — const constructor with named `required` arguments, value equality (`parent` compared by identity).
  - `TreeInsertionPoint<T> treeInsertionPoint<T>(List<TreeSliverNode<T>> roots, TreeSliverNode<T> target, TreeDropPlacement placement)` — throws `ArgumentError` when `target` is not in `roots`.
  - `TreeInsertionPoint<T> treeAppendPoint<T>(List<TreeSliverNode<T>> roots)`
  - `void insertTreeNodes<T>(List<TreeSliverNode<T>> roots, TreeInsertionPoint<T> point, List<TreeSliverNode<T>> nodes)`

- [ ] **Step 1: Write the failing tests**

Create `app/test/features/projects/tree_drop_test.dart`:

```dart
// SPDX-License-Identifier: MIT

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/src/features/projects/tree_drop.dart';

void main() {
  group('treeDropPlacement', () {
    TreeDropPlacement groupRow(double dy) => treeDropPlacement(dy: dy, rowExtent: 32, canHaveChildren: true);
    TreeDropPlacement leafRow(double dy) => treeDropPlacement(dy: dy, rowExtent: 32, canHaveChildren: false);

    test('rows that can hold children split into quarters', () {
      expect([groupRow(0), groupRow(7.9), groupRow(8), groupRow(23.9), groupRow(24), groupRow(32)], [
        TreeDropPlacement.before,
        TreeDropPlacement.before,
        TreeDropPlacement.inside,
        TreeDropPlacement.inside,
        TreeDropPlacement.after,
        TreeDropPlacement.after,
      ]);
    });

    test('other rows split into halves', () {
      expect([leafRow(0), leafRow(15.9), leafRow(16), leafRow(32)], [
        TreeDropPlacement.before,
        TreeDropPlacement.before,
        TreeDropPlacement.after,
        TreeDropPlacement.after,
      ]);
    });
  });

  group('insertion points', () {
    late TreeSliverNode<String> api;
    late TreeSliverNode<String> deep;
    late TreeSliverNode<String> sub;
    late TreeSliverNode<String> web;
    late TreeSliverNode<String> work;
    late TreeSliverNode<String> old;
    late TreeSliverNode<String> archive;
    late TreeSliverNode<String> empty;
    late TreeSliverNode<String> loose;
    late List<TreeSliverNode<String>> roots;

    // work (expanded): api, sub (collapsed): deep, web
    // archive (collapsed): old
    // empty
    // loose
    setUp(() {
      api = TreeSliverNode('api');
      deep = TreeSliverNode('deep');
      sub = TreeSliverNode('sub', children: [deep]);
      web = TreeSliverNode('web');
      work = TreeSliverNode('work', children: [api, sub, web], expanded: true);
      old = TreeSliverNode('old');
      archive = TreeSliverNode('archive', children: [old]);
      empty = TreeSliverNode('empty');
      loose = TreeSliverNode('loose');
      roots = [work, archive, empty, loose];
    });

    test('before a node takes its place', () {
      expect(
        treeInsertionPoint(roots, loose, TreeDropPlacement.before),
        const TreeInsertionPoint<String>(parent: null, index: 3, depth: 0),
      );
      expect(
        treeInsertionPoint(roots, web, TreeDropPlacement.before),
        TreeInsertionPoint(parent: work, index: 2, depth: 1),
      );
      expect(
        treeInsertionPoint(roots, deep, TreeDropPlacement.before),
        TreeInsertionPoint(parent: sub, index: 0, depth: 2),
      );
    });

    test('after a node goes right behind it', () {
      expect(
        treeInsertionPoint(roots, web, TreeDropPlacement.after),
        TreeInsertionPoint(parent: work, index: 3, depth: 1),
      );
      expect(
        treeInsertionPoint(roots, archive, TreeDropPlacement.after),
        const TreeInsertionPoint<String>(parent: null, index: 2, depth: 0),
      );
    });

    test('after an expanded node with children goes first inside it', () {
      expect(
        treeInsertionPoint(roots, work, TreeDropPlacement.after),
        TreeInsertionPoint(parent: work, index: 0, depth: 1),
      );
    });

    test('inside a node appends to its children', () {
      expect(
        treeInsertionPoint(roots, archive, TreeDropPlacement.inside),
        TreeInsertionPoint(parent: archive, index: 1, depth: 1),
      );
      expect(
        treeInsertionPoint(roots, empty, TreeDropPlacement.inside),
        TreeInsertionPoint(parent: empty, index: 0, depth: 1),
      );
      expect(
        treeInsertionPoint(roots, sub, TreeDropPlacement.inside),
        TreeInsertionPoint(parent: sub, index: 1, depth: 2),
      );
    });

    test('a node outside the tree is an argument error', () {
      expect(
        () => treeInsertionPoint(roots, TreeSliverNode('stranger'), TreeDropPlacement.before),
        throwsArgumentError,
      );
    });

    test('the append point is the end of the top level', () {
      expect(treeAppendPoint(roots), const TreeInsertionPoint<String>(parent: null, index: 4, depth: 0));
    });

    test('insertTreeNodes inserts in order at the point', () {
      final a = TreeSliverNode('a');
      final b = TreeSliverNode('b');
      insertTreeNodes(roots, TreeInsertionPoint(parent: work, index: 1, depth: 1), [a, b]);
      expect(work.children, [api, a, b, sub, web]);

      final c = TreeSliverNode('c');
      insertTreeNodes(roots, treeAppendPoint(roots), [c]);
      expect(roots, [work, archive, empty, loose, c]);
    });
  });
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run (in `app/`): `flutter test test/features/projects/tree_drop_test.dart`
Expected: compilation fails — "Error when reading 'lib/src/features/projects/tree_drop.dart': No such file or directory".

- [ ] **Step 3: Implement the logic**

Create `app/lib/src/features/projects/tree_drop.dart`:

```dart
// SPDX-License-Identifier: MIT

import 'package:flutter/widgets.dart';

/// Where a drop lands relative to the row under the pointer.
enum TreeDropPlacement {
  /// Before the row, as its sibling.
  before,

  /// Into the row, as its last child.
  inside,

  /// After the row, as its sibling — or as the first child of an expanded row
  /// that has children.
  after,
}

/// The placement for a pointer at [dy] (row-local) over a row of [rowExtent].
///
/// A row that [canHaveChildren] splits into quarters: the top quarter is
/// before, the bottom quarter after, the middle half inside. Any other row
/// splits into halves: before and after.
TreeDropPlacement treeDropPlacement({required double dy, required double rowExtent, required bool canHaveChildren}) {
  if (!canHaveChildren) {
    return dy < rowExtent / 2 ? TreeDropPlacement.before : TreeDropPlacement.after;
  }
  if (dy < rowExtent / 4) {
    return TreeDropPlacement.before;
  }
  return dy >= rowExtent * 3 / 4 ? TreeDropPlacement.after : TreeDropPlacement.inside;
}

/// Where dropped nodes go in a tree.
@immutable
class TreeInsertionPoint<T> {
  const TreeInsertionPoint({required this.parent, required this.index, required this.depth});

  /// The node that receives the new nodes as children; `null` for the top
  /// level.
  final TreeSliverNode<T>? parent;

  /// The position the first new node takes among [parent]'s children, or
  /// among the top-level nodes.
  final int index;

  /// The depth of the new nodes, 0 at the top level; also the indent of a
  /// drop indicator line.
  final int depth;

  @override
  bool operator ==(Object other) =>
      other is TreeInsertionPoint<T> && identical(other.parent, parent) && other.index == index && other.depth == depth;

  @override
  int get hashCode => Object.hash(parent, index, depth);

  @override
  String toString() => 'TreeInsertionPoint(parent: ${parent?.content}, index: $index, depth: $depth)';
}

/// Where nodes dropped with [placement] relative to [target] go.
///
/// [target] must be a node of [roots]. Its parent and depth are found by
/// walking [roots] instead of reading `TreeSliverNode.parent` and `depth`,
/// which only a mounted `TreeSliver` fills in.
TreeInsertionPoint<T> treeInsertionPoint<T>(
  List<TreeSliverNode<T>> roots,
  TreeSliverNode<T> target,
  TreeDropPlacement placement,
) {
  final _Location<T>? location = _locate(roots, target, null, 0);
  if (location == null) {
    throw ArgumentError.value(target, 'target', 'is not a node of roots');
  }
  return switch (placement) {
    TreeDropPlacement.before => TreeInsertionPoint(
      parent: location.parent,
      index: location.index,
      depth: location.depth,
    ),
    TreeDropPlacement.after when target.isExpanded && target.children.isNotEmpty => TreeInsertionPoint(
      parent: target,
      index: 0,
      depth: location.depth + 1,
    ),
    TreeDropPlacement.after => TreeInsertionPoint(
      parent: location.parent,
      index: location.index + 1,
      depth: location.depth,
    ),
    TreeDropPlacement.inside => TreeInsertionPoint(
      parent: target,
      index: target.children.length,
      depth: location.depth + 1,
    ),
  };
}

/// The end of the top level of [roots].
TreeInsertionPoint<T> treeAppendPoint<T>(List<TreeSliverNode<T>> roots) =>
    TreeInsertionPoint(parent: null, index: roots.length, depth: 0);

/// Inserts [nodes] at [point], keeping their order.
void insertTreeNodes<T>(List<TreeSliverNode<T>> roots, TreeInsertionPoint<T> point, List<TreeSliverNode<T>> nodes) =>
    (point.parent?.children ?? roots).insertAll(point.index, nodes);

typedef _Location<T> = ({TreeSliverNode<T>? parent, int index, int depth});

_Location<T>? _locate<T>(
  List<TreeSliverNode<T>> nodes,
  TreeSliverNode<T> target,
  TreeSliverNode<T>? parent,
  int depth,
) {
  for (final (int index, TreeSliverNode<T> node) in nodes.indexed) {
    if (identical(node, target)) {
      return (parent: parent, index: index, depth: depth);
    }
    if (_locate(node.children, target, node, depth + 1) case final _Location<T> found) {
      return found;
    }
  }
  return null;
}
```

- [ ] **Step 4: Run tests, format and analyze**

Run (in `app/`):
- `flutter test test/features/projects/tree_drop_test.dart` — Expected: all tests pass.
- `dart format lib/src/features/projects/tree_drop.dart test/features/projects/tree_drop_test.dart`
- `dart analyze --fatal-infos --fatal-warnings` — Expected: no issues in the new files. (`app/lib/main2.dart` is Ralph's untracked file; do not touch it if it reports anything.)

- [ ] **Step 5: Commit**

```bash
git add app/lib/src/features/projects/tree_drop.dart app/test/features/projects/tree_drop_test.dart
git commit -m "feat(app): add tree drop placement logic" -m "Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 7: Demo entrypoint `main3.dart`

**Files:**
- Create: `app/lib/main3.dart`

**Interfaces:**
- Consumes: `FolderDropTarget`, `FolderDragDetails`, `WindowDragArea` (`package:zanshin_shell/zanshin_shell.dart`); everything from Task 6 (`treeDropPlacement`, `treeInsertionPoint`, `treeAppendPoint`, `insertTreeNodes`, `TreeInsertionPoint`, `TreeDropPlacement`); `AppWindows.create` / `AppWindows.openOrActivate` (`app/lib/src/features/window/app_windows.dart`); `WindowManager`, `WindowEntry` (`package:flutter/src/widgets/_window.dart`); `yaruLight`, `yaruDark` (`package:yaru/yaru.dart`).
- Produces: a runnable demo (`flutter run -d macos -t lib/main3.dart`). No test file: the entrypoint is demo UI; its logic is tested in Task 6 and the plugin in Tasks 2–4. Runtime behavior is verified in Task 8.

- [ ] **Step 1: Create the demo**

Create `app/lib/main3.dart`:

```dart
// SPDX-License-Identifier: MIT

// Folder drop proof of concept: drag folders from Finder into a TreeSliver and
// drop them before, into or after a row. The drop plumbing is production code
// in the zanshin_shell plugin (FolderDropTarget); the placement logic lives in
// src/features/projects/tree_drop.dart. Not wired into the real boot.
//
//   flutter run -d macos -t lib/main3.dart      (from `app/`)
//
// The windowing API is experimental and only reachable through implementation
// imports; see https://github.com/flutter/flutter/issues/30701.
// ignore_for_file: invalid_use_of_internal_member, implementation_imports

import 'dart:async';

import 'package:flutter/src/widgets/_window.dart';
import 'package:material_ui/material_ui.dart';
import 'package:yaru/yaru.dart';
import 'package:zanshin_shell/zanshin_shell.dart';

import 'src/features/projects/tree_drop.dart';
import 'src/features/window/app_windows.dart';

/// Content size of every demo window.
const _windowSize = Size(900, 640);

/// Height of a tree row.
const double _rowExtent = 32;

/// Horizontal indent per tree level.
const double _indent = 20;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final windows = _DemoWindows(AppWindows());
  // The first window has to be part of the warm-up frame (see
  // AppWindows.create); later ones go through the registry its build attaches.
  runWidget(WindowManager(initialWindows: <WindowEntry>[await windows.createFirst()]));
}

/// Opens the numbered demo windows; each gets its own key and its own tree.
class _DemoWindows {
  _DemoWindows(this._windows);

  final AppWindows _windows;
  int _opened = 0;

  /// Creates the first window, before `runWidget`.
  Future<WindowEntry> createFirst() {
    final int number = ++_opened;
    return _windows.create(key: _key(number), title: _title(number), size: _windowSize, builder: _builder(number));
  }

  /// Opens one more window through the registry.
  Future<void> openAnother() {
    final int number = ++_opened;
    return _windows.openOrActivate(
      key: _key(number),
      title: _title(number),
      size: _windowSize,
      builder: _builder(number),
    );
  }

  WidgetBuilder _builder(int number) => (_) => _DemoApp(number: number, windows: this);

  static String _key(int number) => 'folder-drop-$number';

  static String _title(int number) => 'Folder drop POC $number';
}

class _DemoApp extends StatelessWidget {
  const _DemoApp({required this.number, required this.windows});

  final int number;
  final _DemoWindows windows;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Folder drop POC',
    debugShowCheckedModeBanner: false,
    theme: yaruLight,
    darkTheme: yaruDark,
    home: _FolderTreePage(number: number, onNewWindow: windows.openAnother),
  );
}

/// A tree entry: a group of projects, or a project folder.
sealed class _Entry {
  _Entry(this.name);

  final String name;
}

class _Group extends _Entry {
  _Group(super.name);
}

class _Project extends _Entry {
  _Project(this.path) : super(_folderName(path));

  final String path;
}

String _folderName(String path) => path.split('/').lastWhere((part) => part.isNotEmpty, orElse: () => path);

/// What a drag points at: a row with a placement, or the end of the list
/// (`node` and `placement` null).
typedef _Hover = ({
  TreeSliverNode<_Entry>? node,
  TreeDropPlacement? placement,
  TreeInsertionPoint<_Entry> point,
  int count,
});

class _FolderTreePage extends StatefulWidget {
  const _FolderTreePage({required this.number, required this.onNewWindow});

  final int number;
  final Future<void> Function() onNewWindow;

  @override
  State<_FolderTreePage> createState() => _FolderTreePageState();
}

class _FolderTreePageState extends State<_FolderTreePage> {
  final _controller = TreeSliverController();
  final List<TreeSliverNode<_Entry>> _tree = [
    TreeSliverNode(
      _Group('Work'),
      expanded: true,
      children: [TreeSliverNode(_Project('~/work/api-gateway')), TreeSliverNode(_Project('~/work/dashboard'))],
    ),
    TreeSliverNode(_Group('Private'), expanded: true, children: [TreeSliverNode(_Project('~/projects/zanshin'))]),
    TreeSliverNode(_Group('Archive')),
  ];
  _Hover? _hover;
  String _status = 'Drag folders from Finder onto the tree.';

  @override
  Widget build(BuildContext context) {
    final _Hover? hover = _hover;
    return Scaffold(
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 52,
            child: Row(
              children: [
                Expanded(
                  child: WindowDragArea(
                    child: Padding(
                      // Leaves room for the traffic lights.
                      padding: const EdgeInsets.only(left: 84),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          'Folder drop POC · window ${widget.number}',
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: OutlinedButton.icon(
                    onPressed: () => unawaited(widget.onNewWindow()),
                    icon: const Icon(Icons.add),
                    label: const Text('New window'),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: FolderDropTarget(
              onDragUpdate: _hoverEnd,
              onDragExit: () => _leave(null),
              onDrop: _dropAtEnd,
              child: CustomScrollView(
                slivers: [
                  TreeSliver<_Entry>(
                    tree: _tree,
                    controller: _controller,
                    indentation: TreeSliverIndentationType.none,
                    treeRowExtentBuilder: (_, _) => _rowExtent,
                    treeNodeBuilder: (context, node, _) => _buildRow(context, node as TreeSliverNode<_Entry>),
                  ),
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: _EndOfList(active: hover != null && hover.node == null),
                  ),
                ],
              ),
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Text(hover == null ? _status : _describe(hover)),
          ),
        ],
      ),
    );
  }

  Widget _buildRow(BuildContext context, TreeSliverNode<_Entry> entry) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final _Hover? hover = _hover;
    final TreeDropPlacement? placement = hover != null && identical(hover.node, entry) ? hover.placement : null;
    return FolderDropTarget(
      onDragUpdate: (details) => _hoverRow(entry, details),
      onDragExit: () => _leave(entry),
      onDrop: (details) => _dropOnRow(entry, details),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _controller.toggleNode(entry),
        child: CustomPaint(
          foregroundPainter: hover == null || placement == null || placement == TreeDropPlacement.inside
              ? null
              : _InsertionLinePainter(
                  atTop: placement == TreeDropPlacement.before,
                  depth: hover.point.depth,
                  color: colors.primary,
                ),
          child: ColoredBox(
            color: placement == TreeDropPlacement.inside ? colors.primary.withValues(alpha: 0.16) : Colors.transparent,
            child: Padding(
              padding: EdgeInsets.only(left: 12 + (entry.depth ?? 0) * _indent, right: 12),
              child: Row(
                spacing: 8,
                children: [
                  Icon(_iconFor(entry), size: 18, color: colors.onSurfaceVariant),
                  Text(entry.content.name),
                  if (entry.content case _Project(:final path))
                    Expanded(
                      child: Text(
                        path,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: colors.onSurfaceVariant),
                      ),
                    )
                  else if (entry.children.isEmpty)
                    Text('empty', style: TextStyle(color: colors.onSurfaceVariant)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  bool _hoverRow(TreeSliverNode<_Entry> entry, FolderDragDetails details) {
    final TreeDropPlacement placement = _placementIn(entry, details);
    _showHover((
      node: entry,
      placement: placement,
      point: treeInsertionPoint(_tree, entry, placement),
      count: details.paths.length,
    ));
    return true;
  }

  bool _hoverEnd(FolderDragDetails details) {
    _showHover((node: null, placement: null, point: treeAppendPoint(_tree), count: details.paths.length));
    return true;
  }

  /// Clears the hover state if it still belongs to [node] (`null`: the end of
  /// the list).
  void _leave(TreeSliverNode<_Entry>? node) {
    final _Hover? hover = _hover;
    if (hover != null && identical(hover.node, node)) {
      _showHover(null);
    }
  }

  void _showHover(_Hover? hover) {
    if (hover != _hover) {
      setState(() => _hover = hover);
    }
  }

  void _dropOnRow(TreeSliverNode<_Entry> entry, FolderDragDetails details) =>
      _insert(details.paths, treeInsertionPoint(_tree, entry, _placementIn(entry, details)));

  void _dropAtEnd(FolderDragDetails details) => _insert(details.paths, treeAppendPoint(_tree));

  TreeDropPlacement _placementIn(TreeSliverNode<_Entry> entry, FolderDragDetails details) => treeDropPlacement(
    dy: details.localPosition.dy,
    rowExtent: _rowExtent,
    canHaveChildren: entry.content is _Group,
  );

  /// Adds the dropped folders at [point], skipping those already in the tree.
  void _insert(List<String> paths, TreeInsertionPoint<_Entry> point) {
    final Set<String> listed = _projectPaths(_tree).toSet();
    final List<String> added = [
      for (final path in paths)
        if (listed.add(path)) path,
    ];
    final TreeSliverNode<_Entry>? parent = point.parent;
    setState(() {
      _hover = null;
      insertTreeNodes(_tree, point, [for (final path in added) TreeSliverNode<_Entry>(_Project(path))]);
      _status = [
        'Added ${added.length} to ${parent == null ? 'the top level' : "'${parent.content.name}'"}',
        if (added.length < paths.length) '${paths.length - added.length} already listed',
      ].join(' · ');
    });
    // A group that just got its first child cannot have been expanded yet.
    if (parent != null && added.isNotEmpty && !parent.isExpanded) {
      _controller.expandNode(parent);
    }
  }
}

IconData _iconFor(TreeSliverNode<_Entry> entry) => switch (entry.content) {
  _Group() => entry.isExpanded ? Icons.folder_open : Icons.folder,
  _Project() => Icons.source,
};

/// The paths of all projects in [nodes], at any depth.
Iterable<String> _projectPaths(List<TreeSliverNode<_Entry>> nodes) sync* {
  for (final node in nodes) {
    if (node.content case _Project(:final path)) {
      yield path;
    }
    yield* _projectPaths(node.children);
  }
}

/// The live status line while a drag is over the tree.
String _describe(_Hover hover) {
  final String folders = hover.count == 1 ? '1 folder' : '${hover.count} folders';
  final TreeSliverNode<_Entry>? node = hover.node;
  if (node == null) {
    return '$folders · at the end';
  }
  final name = "'${node.content.name}'";
  return switch (hover.placement) {
    TreeDropPlacement.before => '$folders · before $name',
    TreeDropPlacement.inside => '$folders · into $name',
    TreeDropPlacement.after when identical(hover.point.parent, node) => '$folders · first in $name',
    TreeDropPlacement.after || null => '$folders · after $name',
  };
}

/// The empty area below the tree, which adds dropped folders at the end.
class _EndOfList extends StatelessWidget {
  const _EndOfList({required this.active});

  final bool active;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return ColoredBox(
      color: active ? colors.primary.withValues(alpha: 0.08) : Colors.transparent,
      child: Align(
        alignment: Alignment.topCenter,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            active ? 'Drop to add at the end' : 'Drop folders here to add them at the end',
            style: TextStyle(color: colors.onSurfaceVariant),
          ),
        ),
      ),
    );
  }
}

/// Paints a before/after insertion line: 2 px on the row's top or bottom edge,
/// indented to [depth], with a dot where it starts.
class _InsertionLinePainter extends CustomPainter {
  const _InsertionLinePainter({required this.atTop, required this.depth, required this.color});

  final bool atTop;
  final int depth;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final double y = atTop ? 1 : size.height - 1;
    final double x = 12 + depth * _indent;
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2;
    canvas
      ..drawLine(Offset(x + 3, y), Offset(size.width - 12, y), paint)
      ..drawCircle(Offset(x, y), 3, paint);
  }

  @override
  bool shouldRepaint(_InsertionLinePainter oldDelegate) =>
      oldDelegate.atTop != atTop || oldDelegate.depth != depth || oldDelegate.color != color;
}
```

- [ ] **Step 2: Format and analyze**

Run (in `app/`):
- `dart format lib/main3.dart`
- `dart analyze --fatal-infos --fatal-warnings` — Expected: no issues in `lib/main3.dart`. Fix any lint the analyzer names in the new file only (typical: a missing/obvious local type, an `unnecessary_import`); do not touch `lib/main2.dart`.

- [ ] **Step 3: Build the demo**

Run (in `app/`): `flutter build macos --debug -t lib/main3.dart`
Expected: `✓ Built build/macos/Build/Products/Debug/zanshin.app`.

- [ ] **Step 4: Commit**

```bash
git add app/lib/main3.dart
git commit -m "feat(app): folder drop POC with a TreeSliver in main3.dart" -m "Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 8: Quality gate and runtime verification

**Files:**
- Modify: `docs/superpowers/specs/2026-09-13-macos-folder-drop-design.md` (status + POC results)
- Uses (not committed): `/tmp/zanshin-folder-drop-check/fixtures` from Task 5

**Interfaces:**
- Consumes: everything from Tasks 1–7.
- Produces: a green gate, a verified POC, and the spec's recorded results.

- [ ] **Step 1: Run the quality gate**

Run (repo root, unpiped): `cargo make test`
Expected: every task succeeds, ending with the coverage task. No Rust changed, so `coverage-baseline.txt` should stay untouched; if the gate rewrites it anyway, commit that file on its own with `chore: refresh coverage baseline`.

- [ ] **Step 2: Prepare Finder fixtures**

Run (repo root):
- `/tmp/zanshin-folder-drop-check/check /tmp/zanshin-folder-drop-check/fixtures` — recreates `folder`, `file.txt`, `Some.app`, `symlink`, `alias`, `file-alias`, `broken-link`; Expected: `OK`.
- `mkdir -p /tmp/zanshin-folder-drop-check/fixtures/second`
- `open /tmp/zanshin-folder-drop-check/fixtures` — opens a Finder window on them.

- [ ] **Step 3: Launch the demo**

Run (in `app/`, as a background process): `flutter run -d macos -t lib/main3.dart`
Expected: the log shows `A Dart VM Service on macOS is available at:` and a window "Folder drop POC · window 1" appears.

- [ ] **Step 4: Drag for real**

Either drive the drags with computer use (grant access to Finder and `zanshin`; per drag: screenshot, `left_mouse_down` on the Finder item, three or more `mouse_move` steps into the app window, `left_mouse_up` on the target, screenshot), or hand the checklist to Ralph. Ralph does the final pass either way.

| # | Action | Expected |
|---|---|---|
| 1 | Click "Work", scroll, drag the window by its header, click **New window** | Group toggles, list scrolls, window moves, window 2 opens; the first click into the inactive window 1 also lands. |
| 2 | Drag `folder` over the middle of the "Work" row | Row tinted, cursor shows the copy badge, status `1 folder · into 'Work'`. |
| 3 | Drop it there | `folder` appended as last child of "Work"; status `Added 1 to 'Work'`. |
| 4 | Drag `second` to the top quarter of "Private", drop | Line above "Private" at depth 0, status `… before 'Private'`; `second` lands at the top level before "Private". |
| 5 | Drag to the bottom quarter of the expanded "Work", drop | Line below "Work" indented one level, status `… first in 'Work'`; lands as the first child. |
| 6 | Drag to the bottom half of a project row, drop | Line below that row at its depth; lands right after it. |
| 7 | Drag to the middle of the empty "Archive", drop | Row tinted; "Archive" expands and shows the new child. |
| 8 | Drag to the empty area below the tree, drop | Area tinted, status `… at the end`; lands at the end of the top level. |
| 9 | Drag over the header and over the status bar | No badge; dropping there changes nothing. |
| 10 | Drag `file.txt` alone | No badge anywhere, status unchanged. |
| 11 | Drag `second` and `file.txt` together | Badge shown; the drop adds only the folder (or reports it as already listed). |
| 12 | Drop `alias` and `symlink` | The listed path is the resolved `…/fixtures/folder` (reported as already listed if `folder` is there). |
| 13 | Drag `Some.app` | No badge. |
| 14 | Drag from Finder over window 1, then into window 2, drop | Window 1's highlight clears when leaving it; only window 2's tree changes. |
| 15 | Press Esc during a drag | Highlight and live status clear. |
| 16 | During a drag, hover over the **New window** button | Note whether its hover effect reacts (spec assumption 4). |
| 17 | Press `R` in the `flutter run` terminal (hot restart), drag again | Drops still work. |

- [ ] **Step 5: Record the results in the spec**

In `docs/superpowers/specs/2026-09-13-macos-folder-drop-design.md`:
- Replace the `**Status:**` line with `**Status:** POC implemented and verified YYYY-MM-DD; plugin code production-ready.` (the date of the run; or `**Status:** POC implemented YYYY-MM-DD; open issues under "POC results".` when a checklist row failed).
- Add a section `## POC results` after "Assumptions the POC has to prove" that lists, for each of the five assumptions, `confirmed` or `refuted` plus the checklist row that showed it, and every failed checklist row with what happened instead.

- [ ] **Step 6: Commit**

```bash
git add docs/superpowers/specs/2026-09-13-macos-folder-drop-design.md
git commit -m "docs(shell): record the folder drop POC results" -m "Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```
