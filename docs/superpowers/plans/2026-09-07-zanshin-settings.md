# zanshin_settings Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A `zanshin_settings` package that persists app settings (first: the day/night/system `ThemeMode`) as one JSON file — read once at start, cached in memory, written immediately on change — wired into the app's inject.dart graph and consumed by a new `ZanshinAppViewModel` so `ZanshinApp` becomes stateless.

**Architecture:** Freezed root model `AppSettings` with typed sub-models (`AppearanceSettings`), each field with `@Default` so missing keys fall back cleanly (no version field). `SettingsStore implements ValueListenable<AppSettings>` owns the cache and the serialized, atomic (`.tmp` + rename) writes. `SettingsModule` is an inject.dart `@module` that carries a **pre-loaded** store (`SettingsModule({required SettingsStore store})`), so the DI graph stays synchronous ("resolve before the graph"). The app loads the store in `main()` before `MainComponent.create(...)`. `ZanshinAppViewModel` (`ChangeNotifier`, `@inject`) takes over all theme handling from `_ZanshinAppState`; `ZanshinApp` builds through `ViewModelFactory<ZanshinAppViewModel>`.

**Tech Stack:** Flutter master (3.48 pre) / Dart 3.14 pub workspace, `freezed` 4.0.1 + `freezed_annotation` 3.1, `json_serializable` 6.14 (options `checked`, `explicit_to_json`), `path_provider` 2.1 (+ `path_provider_platform_interface` and `plugin_platform_interface` for test fakes), `inject_annotation`/`inject_generator`/`inject_flutter` 1.2.1, `logging` 1.3, `build_runner`.

Spec: `docs/superpowers/specs/2026-09-07-zanshin-settings-design.md` (read it first).

## Global Constraints

- Every new hand-written Dart file starts with `// SPDX-License-Identifier: MIT` on line 1. Generated files (`*.freezed.dart`, `*.g.dart`, `*.inject.dart`, `*.factory.dart`) are exempt and are **committed**.
- The package pubspec keeps `resolution: workspace` (pub workspace; root glob `packages/*` already matches). Dependencies sorted alphabetically (`sort_pub_dependencies` is enforced with `--fatal-infos`).
- Lints: `linter/rules.yaml` (page width 120, `prefer_relative_imports` inside `lib/`, `avoid_catching_errors`, `avoid_slow_async_io` — use `existsSync()`, never `exists()`, `specify_nonobvious_local_variable_types` / `omit_obvious_local_variable_types`, `require_trailing_commas`, `sort_constructors_first`). Every gate runs `dart analyze --fatal-infos --fatal-warnings` and `dart format --output=none --set-exit-if-changed .` — infos fail the build.
- Verify with the CLI commands given in each step (not an IDE/MCP analyzer, which can be stale). Run commands one at a time, from the directory stated, without `&&` chains.
- Comments and docs in English; `///` on every exported item; comments explain WHY, not WHAT.
- No `dart:ffi`, no `Isolate.run`, no telemetry, no new non-permissive-license dependencies.
- Logging: `package:logging` only (`Logger('zanshin.settings')`); WARNING lines carry the file **name** only — never a path or file content (paths are user data); the exception object goes to `FINE`.
- Commits: `git commit --no-gpg-sign` (1Password signing is unavailable unattended); subject imperative, ≤ ~60 chars; body ends with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`. Direct commits to `main` are allowed. Ralph's already-staged scaffold files (`packages/zanshin_settings/{.gitignore,.metadata,analysis_options.yaml,pubspec.yaml}`, `pubspec.lock`) go into Task 1's commit.
- `cargo make test` (repo root) is the definition of done; it ends with the Rust coverage ratchet. Rust is untouched here, so `coverage-baseline.txt` must not change — never edit it.
- Do not run `flutter run`; use `flutter build macos --debug` (Task 7) for the native compile check.
- Do not touch `app/lib/src/features/home/`, `app/lib/src/features/shell/`, or any other UI file; only `zanshin_app.dart`, the new view model, `main.dart`, pubspecs and generated files change in `app/`.

---

### Task 1: Package skeleton and the Freezed data model

**Files:**
- Modify: `packages/zanshin_settings/pubspec.yaml`
- Modify: `packages/zanshin_settings/analysis_options.yaml`
- Create: `packages/zanshin_settings/build.yaml`
- Create: `packages/zanshin_settings/lib/zanshin_settings.dart`
- Create: `packages/zanshin_settings/lib/src/model/app_settings.dart`
- Create: `packages/zanshin_settings/lib/src/model/appearance_settings.dart`
- Generated (commit): `packages/zanshin_settings/lib/src/model/app_settings.freezed.dart`, `app_settings.g.dart`, `appearance_settings.freezed.dart`, `appearance_settings.g.dart`
- Test: `packages/zanshin_settings/test/model/app_settings_test.dart`

**Interfaces:**
- Produces: `AppSettings({AppearanceSettings appearance = const AppearanceSettings()})` with `fromJson(Map<String, Object?>)`, `toJson()`, `copyWith`, deep `copyWith.appearance(themeMode: ...)`, structural `==`; `AppearanceSettings({ThemeMode themeMode = ThemeMode.system})` with the same members. Both exported from `package:zanshin_settings/zanshin_settings.dart`. JSON shape `{"appearance": {"themeMode": "system"}}`; decoding failures throw `CheckedFromJsonException` (from `freezed_annotation`, which re-exports `json_annotation`).

- [ ] **Step 1: Finish the pubspec (dependencies sorted, `publish_to`, `logging`, `inject_annotation`, test fakes)**

Replace `packages/zanshin_settings/pubspec.yaml` with:

```yaml
name: zanshin_settings
description: Persistent app settings for Zanshin - a Freezed AppSettings model cached in memory and stored as one JSON file.
version: 0.0.1
publish_to: 'none'

environment:
  sdk: ^3.14.0-143.0.dev
  flutter: ^3.48.0-1.0.pre-295
resolution: workspace

dependencies:
  flutter:
    sdk: flutter
  freezed_annotation: ^3.1.0
  inject_annotation: ^1.2.1
  json_annotation: ^4.12.0
  logging: ^1.3.0
  path_provider: ^2.1.6

dev_dependencies:
  build_runner: ^2.16.1
  flutter_lints: ^6.0.0
  flutter_test:
    sdk: flutter
  freezed: ^4.0.1
  json_serializable: ^6.14.1
  # Test-only: fakes for SettingsStore.open() (path_provider) mix in MockPlatformInterfaceMixin.
  path_provider_platform_interface: ^2.1.0
  plugin_platform_interface: ^2.1.8
```

- [ ] **Step 2: Analyzer excludes for generated code**

Replace `packages/zanshin_settings/analysis_options.yaml` with:

```yaml
include: ../../linter/flutter.yaml

analyzer:
  exclude:
    - "**/*.freezed.dart" # freezed output
    - "**/*.g.dart" # json_serializable output
    - build/**
```

- [ ] **Step 3: json_serializable options**

Create `packages/zanshin_settings/build.yaml`:

```yaml
targets:
  $default:
    builders:
      json_serializable:
        options:
          # WHY: `checked` turns every decoding failure (wrong type, unknown enum
          # name, non-object sub-model) into a CheckedFromJsonException instead
          # of a TypeError/ArgumentError, so SettingsStore.load can recover from
          # a corrupt file without catching Errors (avoid_catching_errors).
          # `explicit_to_json` makes toJson() emit nested maps instead of nested
          # objects, so the on-disk shape is testable without jsonEncode.
          checked: true
          explicit_to_json: true
```

- [ ] **Step 4: Resolve dependencies**

Run (in `packages/zanshin_settings`): `flutter pub get`
Expected: exit 0; `pubspec.lock` at the repo root updates.

- [ ] **Step 5: Write the failing model tests**

Create `packages/zanshin_settings/test/model/app_settings_test.dart`:

```dart
// SPDX-License-Identifier: MIT

import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_test/flutter_test.dart';
import 'package:freezed_annotation/freezed_annotation.dart' show CheckedFromJsonException;
import 'package:zanshin_settings/zanshin_settings.dart';

void main() {
  test('defaults follow the system theme', () {
    expect(const AppSettings().appearance.themeMode, ThemeMode.system);
  });

  test('a non-default value survives a JSON round trip', () {
    const settings = AppSettings(appearance: AppearanceSettings(themeMode: ThemeMode.dark));
    expect(AppSettings.fromJson(settings.toJson()), settings);
  });

  test('toJson nests the sub-model as a map and encodes the enum by name', () {
    const settings = AppSettings(appearance: AppearanceSettings(themeMode: ThemeMode.dark));
    expect(settings.toJson(), {
      'appearance': {'themeMode': 'dark'},
    });
  });

  test('a missing key takes its default', () {
    expect(AppearanceSettings.fromJson({}).themeMode, ThemeMode.system);
  });

  test('a missing sub-model takes its default', () {
    expect(AppSettings.fromJson({}), const AppSettings());
  });

  test('an unknown key is ignored', () {
    expect(AppSettings.fromJson({'unknown': 1}), const AppSettings());
  });

  test('a wrongly typed sub-model throws CheckedFromJsonException', () {
    expect(() => AppSettings.fromJson({'appearance': 5}), throwsA(isA<CheckedFromJsonException>()));
  });

  test('an unknown enum name throws CheckedFromJsonException', () {
    expect(
      () => AppearanceSettings.fromJson({'themeMode': 'purple'}),
      throwsA(isA<CheckedFromJsonException>()),
    );
  });
}
```

- [ ] **Step 6: Run the tests to verify they fail**

Run (in `packages/zanshin_settings`): `flutter test test/model/app_settings_test.dart`
Expected: FAIL — compilation error, `package:zanshin_settings/zanshin_settings.dart` does not exist.

- [ ] **Step 7: Write the models and the barrel**

Create `packages/zanshin_settings/lib/src/model/appearance_settings.dart`:

```dart
// SPDX-License-Identifier: MIT

import 'package:flutter/material.dart' show ThemeMode;
import 'package:freezed_annotation/freezed_annotation.dart';

part 'appearance_settings.freezed.dart';
part 'appearance_settings.g.dart';

/// Look-and-feel settings.
@freezed
abstract class AppearanceSettings with _$AppearanceSettings {
  /// Creates appearance settings; an omitted [themeMode] follows the OS.
  const factory AppearanceSettings({
    /// The user's day/night choice; `system` follows the OS.
    @Default(ThemeMode.system) ThemeMode themeMode,
  }) = _AppearanceSettings;

  /// Decodes from JSON; throws [CheckedFromJsonException] on a malformed document.
  factory AppearanceSettings.fromJson(Map<String, Object?> json) => _$AppearanceSettingsFromJson(json);
}
```

Create `packages/zanshin_settings/lib/src/model/app_settings.dart`:

```dart
// SPDX-License-Identifier: MIT

import 'package:freezed_annotation/freezed_annotation.dart';

import 'appearance_settings.dart';

part 'app_settings.freezed.dart';
part 'app_settings.g.dart';

/// Root of all persisted app settings.
///
/// Every sub-model is a field with a `@Default`, so a file written by an older
/// app version (missing keys or whole sub-objects) still loads — the missing
/// parts take their defaults. Unknown keys are ignored. Adding a setting means
/// adding a defaulted field here or on a sub-model and re-running
/// `dart run build_runner build`; no version field, no migration.
@freezed
abstract class AppSettings with _$AppSettings {
  /// Creates settings; omitted sub-models take their defaults.
  const factory AppSettings({
    /// Look-and-feel settings.
    @Default(AppearanceSettings()) AppearanceSettings appearance,
  }) = _AppSettings;

  /// Decodes from JSON; throws [CheckedFromJsonException] on a malformed document.
  factory AppSettings.fromJson(Map<String, Object?> json) => _$AppSettingsFromJson(json);
}
```

Create `packages/zanshin_settings/lib/zanshin_settings.dart`:

```dart
// SPDX-License-Identifier: MIT

/// Persistent app settings for Zanshin: a Freezed root model cached in memory
/// and stored as one JSON file.
library;

export 'src/model/app_settings.dart';
export 'src/model/appearance_settings.dart';
```

- [ ] **Step 8: Generate the Freezed and JSON parts**

Run (in `packages/zanshin_settings`): `dart run build_runner build --delete-conflicting-outputs`
Expected: exit 0; four new files next to the models: `app_settings.freezed.dart`, `app_settings.g.dart`, `appearance_settings.freezed.dart`, `appearance_settings.g.dart`. The `.g.dart` files must contain `$checkedCreate(` (checked mode on) and `_$ThemeModeEnumMap`.

- [ ] **Step 9: Run the tests to verify they pass**

Run (in `packages/zanshin_settings`): `flutter test test/model/app_settings_test.dart`
Expected: all 8 tests PASS. If "an unknown enum name" or "a wrongly typed sub-model" fails with a `TypeError`/`ArgumentError` instead of `CheckedFromJsonException`, the `build.yaml` option was not picked up — check the builder key is exactly `json_serializable` and re-run Step 8.

- [ ] **Step 10: Analyzer and formatter must be clean, including generated files**

Run (in `packages/zanshin_settings`): `dart analyze --fatal-infos --fatal-warnings`
Expected: `No issues found!`

Run (in `packages/zanshin_settings`): `dart format --output=none --set-exit-if-changed .`
Expected: exit 0 (Freezed emits `// dart format off`, json_serializable emits `// dart format width=80`, so generated files are stable). If a generated file is reported, do NOT hand-edit it — that is a generator-option problem to fix in `build.yaml`.

- [ ] **Step 11: Commit**

```bash
git add packages/zanshin_settings pubspec.lock
git commit --no-gpg-sign -m "feat(settings): scaffold zanshin_settings with the Freezed AppSettings model

AppSettings root + AppearanceSettings(themeMode) sub-model, JSON via
json_serializable (checked, explicit_to_json), defaults for missing keys.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: SettingsStore — cache, load, atomic serialized writes

**Files:**
- Create: `packages/zanshin_settings/lib/src/settings_store.dart`
- Modify: `packages/zanshin_settings/lib/zanshin_settings.dart` (add export)
- Test: `packages/zanshin_settings/test/settings_store_test.dart`

**Interfaces:**
- Consumes: `AppSettings`, `AppearanceSettings` from Task 1.
- Produces: `class SettingsStore implements ValueListenable<AppSettings>` with `static Future<SettingsStore> load(File file)`, `static Future<SettingsStore> open()`, `File get file`, `AppSettings get value`, `addListener`/`removeListener`, `Future<void> update(AppSettings Function(AppSettings current) change)`. Logger name `zanshin.settings`.

- [ ] **Step 1: Write the failing store tests**

Create `packages/zanshin_settings/test/settings_store_test.dart`:

```dart
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:zanshin_settings/zanshin_settings.dart';

const _dark = AppSettings(appearance: AppearanceSettings(themeMode: ThemeMode.dark));
const _light = AppSettings(appearance: AppearanceSettings(themeMode: ThemeMode.light));
const _darkJson = '{\n  "appearance": {\n    "themeMode": "dark"\n  }\n}\n';

/// Answers `getApplicationSupportPath` with a fixed directory.
final class FakePathProvider extends PathProviderPlatform with MockPlatformInterfaceMixin {
  FakePathProvider(this.path);

  final String path;

  @override
  Future<String?> getApplicationSupportPath() async => path;
}

void main() {
  late Directory dir;
  late File file;
  final List<LogRecord> warnings = [];
  late StreamSubscription<LogRecord> logSubscription;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('zanshin_settings_test');
    file = File('${dir.path}/settings.json');
    warnings.clear();
    logSubscription = Logger.root.onRecord.listen((record) {
      if (record.loggerName == 'zanshin.settings' && record.level == Level.WARNING) {
        warnings.add(record);
      }
    });
  });

  tearDown(() async {
    await logSubscription.cancel();
    await dir.delete(recursive: true);
  });

  group('load', () {
    test('a missing file yields defaults and creates nothing', () async {
      final SettingsStore store = await SettingsStore.load(file);

      expect(store.value, const AppSettings());
      expect(store.file, file);
      expect(file.existsSync(), isFalse);
      expect(warnings, isEmpty);
    });

    test('a valid file is parsed', () async {
      await file.writeAsString(_darkJson);

      final SettingsStore store = await SettingsStore.load(file);

      expect(store.value, _dark);
      expect(warnings, isEmpty);
    });

    for (final (String label, String content) in [
      ('invalid JSON', '{not json'),
      ('a top-level array', '[]'),
      ('a wrongly typed field', '{"appearance": 5}'),
      ('an unknown enum name', '{"appearance": {"themeMode": "purple"}}'),
    ]) {
      test('$label is moved aside and replaced by defaults', () async {
        await file.writeAsString(content);

        final SettingsStore store = await SettingsStore.load(file);

        expect(store.value, const AppSettings());
        expect(file.existsSync(), isFalse);
        expect(File('${file.path}.corrupt').readAsStringSync(), content);
        expect(warnings, hasLength(1));
        expect(warnings.single.message, isNot(contains(dir.path)));
      });
    }

    test('a corrupt file replaces an older backup', () async {
      await File('${file.path}.corrupt').writeAsString('old');
      await file.writeAsString('[]');

      await SettingsStore.load(file);

      expect(File('${file.path}.corrupt').readAsStringSync(), '[]');
    });
  });

  group('update', () {
    test('notifies synchronously and has written the file when it completes', () async {
      final SettingsStore store = await SettingsStore.load(file);
      final List<ThemeMode> seen = [];
      store.addListener(() => seen.add(store.value.appearance.themeMode));

      final Future<void> done = store.update((s) => s.copyWith.appearance(themeMode: ThemeMode.dark));

      expect(seen, [ThemeMode.dark]);
      expect(store.value, _dark);
      await done;
      expect(file.readAsStringSync(), _darkJson);
      expect(File('${file.path}.tmp').existsSync(), isFalse);
    });

    test('an unchanged value neither notifies nor writes', () async {
      final SettingsStore store = await SettingsStore.load(file);
      var notifications = 0;
      store.addListener(() => notifications++);

      await store.update((s) => s);

      expect(notifications, 0);
      expect(file.existsSync(), isFalse);
    });

    test('rapid updates persist in call order', () async {
      final SettingsStore store = await SettingsStore.load(file);

      await Future.wait([
        store.update((s) => s.copyWith.appearance(themeMode: ThemeMode.dark)),
        store.update((s) => s.copyWith.appearance(themeMode: ThemeMode.light)),
        store.update((s) => s.copyWith.appearance(themeMode: ThemeMode.dark)),
      ]);

      expect(store.value, _dark);
      expect(file.readAsStringSync(), _darkJson);
    });

    test('a failed write reports the error, keeps the value and does not block later writes', () async {
      // A directory in the file's place makes the final rename fail.
      await Directory(file.path).create();
      final SettingsStore store = await SettingsStore.load(file);

      await expectLater(
        store.update((s) => s.copyWith.appearance(themeMode: ThemeMode.dark)),
        throwsA(isA<FileSystemException>()),
      );

      expect(store.value, _dark);
      expect(warnings, hasLength(1));
      expect(warnings.single.message, isNot(contains(dir.path)));

      await Directory(file.path).delete();
      await store.update((s) => s.copyWith.appearance(themeMode: ThemeMode.light));
      expect(jsonDecode(file.readAsStringSync()), _light.toJson());
    });
  });

  test('open() loads from the application support directory', () async {
    PathProviderPlatform.instance = FakePathProvider(dir.path);
    await file.writeAsString(_darkJson);

    final SettingsStore store = await SettingsStore.open();

    expect(store.file.path, '${dir.path}/settings.json');
    expect(store.value, _dark);
  });
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run (in `packages/zanshin_settings`): `flutter test test/settings_store_test.dart`
Expected: FAIL — compilation error, `SettingsStore` undefined.

- [ ] **Step 3: Implement the store**

Create `packages/zanshin_settings/lib/src/settings_store.dart`:

```dart
// SPDX-License-Identifier: MIT

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:freezed_annotation/freezed_annotation.dart' show CheckedFromJsonException;
import 'package:logging/logging.dart';
import 'package:path_provider/path_provider.dart';

import 'model/app_settings.dart';

final _log = Logger('zanshin.settings');
const _encoder = JsonEncoder.withIndent('  ');

/// In-memory cache of [AppSettings] backed by one JSON file.
///
/// The file is read once in [load]; every [update] replaces the cached value,
/// notifies listeners synchronously and persists immediately. The store lives
/// for the app's lifetime, so it has no `dispose`.
class SettingsStore implements ValueListenable<AppSettings> {
  SettingsStore._(this.file, AppSettings initial) : _notifier = ValueNotifier(initial);

  /// The file this store persists to.
  final File file;

  final ValueNotifier<AppSettings> _notifier;
  Future<void> _queue = Future<void>.value();

  /// Reads [file].
  ///
  /// A missing file yields defaults without writing anything. An unreadable or
  /// malformed file is moved aside as `<file>.corrupt` (logged at WARNING) and
  /// defaults are used, so nothing is silently destroyed and a hand-edit typo
  /// never blocks app start. Never throws for either case.
  static Future<SettingsStore> load(File file) async {
    if (!file.existsSync()) {
      return SettingsStore._(file, const AppSettings());
    }
    try {
      final Object? decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, Object?>) {
        return _recover(file, const FormatException('top-level JSON value is not an object'), StackTrace.current);
      }
      return SettingsStore._(file, AppSettings.fromJson(decoded));
    } on FormatException catch (error, stack) {
      return _recover(file, error, stack);
    } on CheckedFromJsonException catch (error, stack) {
      return _recover(file, error, stack);
    } on FileSystemException catch (error, stack) {
      return _recover(file, error, stack);
    }
  }

  /// [load] at the default location `<application support dir>/settings.json`
  /// (macOS: `~/Library/Application Support/<bundle id>/`).
  ///
  /// Errors from path_provider propagate: without a location there is nothing
  /// sensible to fall back to.
  static Future<SettingsStore> open() async {
    final Directory dir = await getApplicationSupportDirectory();
    return load(File('${dir.path}/settings.json'));
  }

  @override
  AppSettings get value => _notifier.value;

  @override
  void addListener(VoidCallback listener) => _notifier.addListener(listener);

  @override
  void removeListener(VoidCallback listener) => _notifier.removeListener(listener);

  /// Applies [change] to [value], notifies listeners synchronously and
  /// persists immediately.
  ///
  /// Completes when the write has finished. A failed write completes with the
  /// error while [value] keeps the new settings. A [change] that returns the
  /// current value is a no-op: no notification, no write.
  Future<void> update(AppSettings Function(AppSettings current) change) {
    final AppSettings next = change(_notifier.value);
    if (next == _notifier.value) {
      return Future<void>.value();
    }
    _notifier.value = next;
    final Future<void> write = _queue.then((_) => _write(next));
    // WHY: keep the chain alive after a failure — the error reaches this
    // update's caller through `write`; later writes must still run.
    _queue = write.catchError((_) {});
    return write;
  }

  static Future<SettingsStore> _recover(File file, Object error, StackTrace stack) async {
    final String name = file.uri.pathSegments.last;
    // WHY: a settings path is user data and the exception may quote the file,
    // so the WARNING carries only the file name; details go to FINE.
    _log.warning('$name is unreadable; backing it up as $name.corrupt and starting with defaults');
    _log.fine('settings decode failure', error, stack);
    try {
      await file.rename('${file.path}.corrupt');
    } on FileSystemException catch (renameError, renameStack) {
      _log.warning('could not back up $name; the next write overwrites it');
      _log.fine('settings backup failure', renameError, renameStack);
    }
    return SettingsStore._(file, const AppSettings());
  }

  Future<void> _write(AppSettings settings) async {
    final File tmp = File('${file.path}.tmp');
    try {
      await file.parent.create(recursive: true);
      await tmp.writeAsString('${_encoder.convert(settings.toJson())}\n', flush: true);
      // WHY: rename is atomic on POSIX — a crash mid-write never leaves a
      // half-written settings.json behind.
      await tmp.rename(file.path);
    } on FileSystemException catch (error, stack) {
      _log.warning('could not write ${file.uri.pathSegments.last}');
      _log.fine('settings write failure', error, stack);
      rethrow;
    }
  }
}
```

Add to `packages/zanshin_settings/lib/zanshin_settings.dart` (keep exports alphabetical):

```dart
export 'src/settings_store.dart';
```

- [ ] **Step 4: Run the tests to verify they pass**

Run (in `packages/zanshin_settings`): `flutter test`
Expected: all model + store tests PASS (8 + 12).

- [ ] **Step 5: Analyzer and formatter**

Run (in `packages/zanshin_settings`): `dart analyze --fatal-infos --fatal-warnings`
Expected: `No issues found!`

Run (in `packages/zanshin_settings`): `dart format --output=none --set-exit-if-changed .`
Expected: exit 0.

- [ ] **Step 6: Commit**

```bash
git add packages/zanshin_settings
git commit --no-gpg-sign -m "feat(settings): add SettingsStore (cached, atomic, serialized writes)

ValueListenable<AppSettings> over one JSON file: load with corrupt-file
backup and defaults, update notifies synchronously and persists via
tmp+rename in call order; open() resolves the app support directory.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: SettingsModule and the quality-gate tasks

**Files:**
- Create: `packages/zanshin_settings/lib/src/settings_module.dart`
- Modify: `packages/zanshin_settings/lib/zanshin_settings.dart` (add export)
- Modify: `Makefile.toml:59-71` (dependency list) and after `Makefile.toml:195` (new tasks)
- Test: `packages/zanshin_settings/test/settings_module_test.dart`

**Interfaces:**
- Consumes: `SettingsStore` from Task 2.
- Produces: `@module class SettingsModule { SettingsModule({required SettingsStore store}); SettingsStore get store; @provides @singleton SettingsStore settingsStore(); }` exported from the barrel. Task 4 passes it as `MainComponent.create(settingsModule: SettingsModule(store: ...))`.

- [ ] **Step 1: Write the failing module test**

Create `packages/zanshin_settings/test/settings_module_test.dart`:

```dart
// SPDX-License-Identifier: MIT

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin_settings/zanshin_settings.dart';

void main() {
  test('the module provides the store it was built with', () async {
    final Directory dir = await Directory.systemTemp.createTemp('zanshin_settings_module_test');
    addTearDown(() => dir.delete(recursive: true));
    final SettingsStore store = await SettingsStore.load(File('${dir.path}/settings.json'));

    expect(SettingsModule(store: store).settingsStore(), same(store));
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run (in `packages/zanshin_settings`): `flutter test test/settings_module_test.dart`
Expected: FAIL — `SettingsModule` undefined.

- [ ] **Step 3: Implement the module**

Create `packages/zanshin_settings/lib/src/settings_module.dart`:

```dart
// SPDX-License-Identifier: MIT

import 'package:inject_annotation/inject_annotation.dart';

import 'settings_store.dart';

/// DI module handing a pre-loaded [SettingsStore] to the graph.
///
/// The store is loaded *before* the component exists —
/// `MainComponent.create(settingsModule: SettingsModule(store: await SettingsStore.open()))` —
/// so the graph stays synchronous: no `@asynchronous` provider, no `Future`
/// entry points, and `ViewModelFactory` chains stay plain.
@module
class SettingsModule {
  /// Wraps an already loaded [store].
  SettingsModule({required this.store});

  /// The store every consumer receives.
  final SettingsStore store;

  /// Provides the app-wide [SettingsStore].
  @provides
  @singleton
  SettingsStore settingsStore() => store;
}
```

Add to `packages/zanshin_settings/lib/zanshin_settings.dart` (alphabetical, before `settings_store`):

```dart
export 'src/settings_module.dart';
```

- [ ] **Step 4: Run the tests to verify they pass**

Run (in `packages/zanshin_settings`): `flutter test`
Expected: all tests PASS.

- [ ] **Step 5: Add the gate tasks to `Makefile.toml`**

In `[tasks.test].dependencies`, insert after the line `"test-shell-macos-format",`:

```toml
    "test-settings",
    "test-settings-analyze",
    "test-settings-format",
```

After the `[tasks.test-shell-macos-format]` block (ends at `cwd = "packages/zanshin_shell_macos"`) and before `[tasks.test-cargo-deny]`, insert:

```toml
[tasks.test-settings]
private = true
command = "flutter"
args = ["test"]
cwd = "packages/zanshin_settings"

[tasks.test-settings-analyze]
private = true
command = "dart"
args = ["analyze", "--fatal-infos", "--fatal-warnings"]
cwd = "packages/zanshin_settings"

[tasks.test-settings-format]
private = true
command = "dart"
args = ["format", "--output=none", "--set-exit-if-changed", "."]
cwd = "packages/zanshin_settings"
```

- [ ] **Step 6: Run exactly what the gate will run**

Run (in `packages/zanshin_settings`): `flutter test`
Expected: PASS.

Run (in `packages/zanshin_settings`): `dart analyze --fatal-infos --fatal-warnings`
Expected: `No issues found!`

Run (in `packages/zanshin_settings`): `dart format --output=none --set-exit-if-changed .`
Expected: exit 0.

- [ ] **Step 7: Commit**

```bash
git add packages/zanshin_settings Makefile.toml
git commit --no-gpg-sign -m "feat(settings): add SettingsModule and gate tasks

SettingsModule carries a pre-loaded store (resolve before the graph);
cargo make test now runs the zanshin_settings test/analyze/format trio.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 4: Wire the module into the app graph

**Files:**
- Modify: `app/pubspec.yaml` (dependencies)
- Modify: `app/lib/main.dart:11-15` (imports), `:41-45` (bootstrap), `:61` (`@Component`)
- Generated (commit): `app/lib/main.inject.dart`, `app/macos/Flutter/GeneratedPluginRegistrant.swift`, `pubspec.lock`

**Interfaces:**
- Consumes: `SettingsStore.open()`, `SettingsModule(store:)` from Tasks 2–3.
- Produces: `SettingsStore` is a synchronous binding in `MainComponent`'s graph (consumed by Task 5's view model); `MainComponent.create` gains the required named parameter `settingsModule`.

- [ ] **Step 1: Add the package dependency**

In `app/pubspec.yaml` `dependencies:`, insert after the `zanshin_core:` entry (keeps alphabetical order `zanshin_core` < `zanshin_settings` < `zanshin_shell`):

```yaml
  zanshin_settings:
    path: ../packages/zanshin_settings
```

Run (in `app`): `flutter pub get`
Expected: exit 0. Then run (repo root): `git status --short app/macos` — `app/macos/Flutter/GeneratedPluginRegistrant.swift` should now be modified with a `PathProviderPlugin` registration line. If it is not modified yet, it will be after Task 7's `flutter build macos --debug`; commit it then.

- [ ] **Step 2: Edit `app/lib/main.dart`**

Imports — after `import 'package:zanshin_core/zanshin_core.dart';` add:

```dart
import 'package:zanshin_settings/zanshin_settings.dart';
```

Bootstrap — replace

```dart
      // ignore: specify_nonobvious_local_variable_types
      final mainComponent = MainComponent.create();
```

with

```dart
      // Resolve the settings before the graph exists so the DI chain stays
      // synchronous (no @asynchronous provider, no Future entry points).
      final SettingsStore settings = await SettingsStore.open();
      // ignore: specify_nonobvious_local_variable_types
      final mainComponent = MainComponent.create(settingsModule: SettingsModule(store: settings));
```

Component — replace

```dart
@Component([ZanshinFfiModule, ZanshinDiagnosticsModule, WorkerModule, WorkerLifecycleModule])
```

with

```dart
@Component([ZanshinFfiModule, ZanshinDiagnosticsModule, WorkerModule, WorkerLifecycleModule, SettingsModule])
```

- [ ] **Step 3: Regenerate the component**

Run (in `app`): `dart run build_runner build --delete-conflicting-outputs`
Expected: exit 0; `app/lib/main.inject.dart` now has a `required _i5.SettingsModule settingsModule` (import prefix may differ) parameter on `create` and a `SettingsStore` provider backed by the module. Nothing consumes the store yet (Task 5 does); an "unused binding" style warning from the generator is not an error — only fail this step on a real build error.

- [ ] **Step 4: Analyzer, formatter, app tests**

Run (in `app`): `dart analyze --fatal-infos --fatal-warnings`
Expected: `No issues found!`

Run (in `app`): `dart format --output=none --set-exit-if-changed .`
Expected: exit 0.

Run (in `app`): `flutter test`
Expected: PASS (`native_asset_smoke_test.dart`; this builds the Rust cdylib via the hook — slow the first time).

- [ ] **Step 5: Commit**

```bash
git add app/pubspec.yaml app/lib/main.dart app/lib/main.inject.dart app/macos/Flutter/GeneratedPluginRegistrant.swift pubspec.lock
git commit --no-gpg-sign -m "feat(app): load settings before the graph and install SettingsModule

main() awaits SettingsStore.open() and hands the store to
MainComponent.create(settingsModule:), keeping every entry point sync.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

(If `GeneratedPluginRegistrant.swift` was not modified in Step 1, drop it from `git add`.)

---

### Task 5: ZanshinAppViewModel (TDD)

**Files:**
- Modify: `app/pubspec.yaml` (dev_dependencies)
- Create: `app/lib/src/features/app/zanshin_app_view_model.dart`
- Test: `app/test/features/app/zanshin_app_view_model_test.dart`

**Interfaces:**
- Consumes: `SettingsStore` (Task 2), `ZanshinShell.getTheme()/onThemeChanged/setWindowAppearance(WindowAppearance)`, `ShellTheme`, `WindowAppearance` from `package:zanshin_shell/zanshin_shell.dart` (existing).
- Produces: `@inject class ZanshinAppViewModel extends ChangeNotifier { ZanshinAppViewModel(SettingsStore settings); ShellTheme? get shellTheme; ThemeMode get selectedMode; ThemeMode get effectiveMode; void init(); Future<void> setThemeMode(ThemeMode mode); void dispose(); }` — Task 6 injects it through `ViewModelFactory<ZanshinAppViewModel>`.

- [ ] **Step 1: Test-only dependencies for the shell fake**

In `app/pubspec.yaml` `dev_dependencies:`, insert after `inject_generator: ^1.2.1` (before the commented `# theme_tailor` line):

```yaml
  # Test-only: the fake ZanshinShellPlatform in test/ mixes in MockPlatformInterfaceMixin.
  plugin_platform_interface: ^2.1.8
  zanshin_shell_platform_interface:
    path: ../packages/zanshin_shell_platform_interface
```

Run (in `app`): `flutter pub get`
Expected: exit 0.

- [ ] **Step 2: Write the failing view-model tests**

Create `app/test/features/app/zanshin_app_view_model_test.dart`:

```dart
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart' show Brightness, Color, ThemeMode;
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:zanshin/src/features/app/zanshin_app_view_model.dart';
import 'package:zanshin_settings/zanshin_settings.dart';
import 'package:zanshin_shell_platform_interface/zanshin_shell_platform_interface.dart';

const _darkShell = ShellTheme(brightness: Brightness.dark, accentColor: Color(0xFFBF5AF2));
const _lightShell = ShellTheme(brightness: Brightness.light, accentColor: Color(0xFF0A84FF));

/// Records shell calls; `getTheme` answers when the test completes [theme].
final class RecordingShell extends ZanshinShellPlatform with MockPlatformInterfaceMixin {
  RecordingShell() : super.forTesting();

  final List<String> calls = [];
  final Completer<ShellTheme> theme = Completer<ShellTheme>();
  final StreamController<ShellTheme> changes = StreamController<ShellTheme>.broadcast();

  @override
  Future<ShellTheme> getTheme() {
    calls.add('getTheme');
    return theme.future;
  }

  @override
  Stream<ShellTheme> get onThemeChanged => changes.stream;

  @override
  Future<void> setWindowAppearance(WindowAppearance appearance) async {
    calls.add('setWindowAppearance:${appearance.name}');
  }

  @override
  Future<void> startWindowDrag() async {}

  @override
  Future<void> performTitlebarDoubleClickAction() async {}
}

void main() {
  late Directory dir;
  late File file;
  late RecordingShell shell;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('zanshin_app_view_model_test');
    file = File('${dir.path}/settings.json');
    shell = RecordingShell();
    ZanshinShellPlatform.instance = shell;
  });

  tearDown(() async {
    await shell.changes.close();
    await dir.delete(recursive: true);
  });

  Future<ZanshinAppViewModel> viewModelWith(ThemeMode persisted) async {
    await file.writeAsString('{"appearance": {"themeMode": "${persisted.name}"}}');
    return ZanshinAppViewModel(await SettingsStore.load(file));
  }

  test('selectedMode reflects the persisted choice', () async {
    final ZanshinAppViewModel vm = await viewModelWith(ThemeMode.dark);

    expect(vm.selectedMode, ThemeMode.dark);
    expect(vm.shellTheme, isNull);
    vm.dispose();
  });

  test('init mirrors the persisted choice onto the window and applies the shell theme', () async {
    final ZanshinAppViewModel vm = await viewModelWith(ThemeMode.dark);
    var notifications = 0;
    vm.addListener(() => notifications++);

    vm.init();
    expect(shell.calls, ['getTheme', 'setWindowAppearance:dark']);

    shell.theme.complete(_darkShell);
    await pumpEventQueue();
    expect(vm.shellTheme, _darkShell);
    expect(notifications, 1);

    shell.changes.add(_lightShell);
    await pumpEventQueue();
    expect(vm.shellTheme, _lightShell);
    expect(notifications, 2);
    vm.dispose();
  });

  test('setThemeMode persists, mirrors onto the window and notifies', () async {
    final ZanshinAppViewModel vm = await viewModelWith(ThemeMode.dark);
    var notifications = 0;
    vm.addListener(() => notifications++);

    await vm.setThemeMode(ThemeMode.light);

    expect(vm.selectedMode, ThemeMode.light);
    expect(notifications, 1);
    expect(shell.calls, ['setWindowAppearance:light']);
    expect(file.readAsStringSync(), contains('"light"'));
    vm.dispose();
  });

  test('effectiveMode resolves system through the shell theme', () async {
    final ZanshinAppViewModel vm = await viewModelWith(ThemeMode.system);
    expect(vm.effectiveMode, ThemeMode.system);

    vm.init();
    shell.theme.complete(_darkShell);
    await pumpEventQueue();
    expect(vm.effectiveMode, ThemeMode.dark);

    await vm.setThemeMode(ThemeMode.light);
    expect(vm.effectiveMode, ThemeMode.light);
    vm.dispose();
  });

  test('an external store update notifies the view model', () async {
    final SettingsStore store = await SettingsStore.load(file);
    final ZanshinAppViewModel vm = ZanshinAppViewModel(store);
    var notifications = 0;
    vm.addListener(() => notifications++);

    await store.update((s) => s.copyWith.appearance(themeMode: ThemeMode.dark));

    expect(notifications, 1);
    expect(vm.selectedMode, ThemeMode.dark);
    vm.dispose();
  });

  test('after dispose neither a shell event nor a late theme answer is applied', () async {
    final ZanshinAppViewModel vm = await viewModelWith(ThemeMode.system);
    vm.init();
    vm.dispose();

    shell.changes.add(_darkShell);
    shell.theme.complete(_darkShell);
    await pumpEventQueue();

    // A disposed ChangeNotifier asserts on notifyListeners; reaching here
    // without an error and with no theme applied is the assertion.
    expect(vm.shellTheme, isNull);
  });
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run (in `app`): `flutter test test/features/app/zanshin_app_view_model_test.dart`
Expected: FAIL — `package:zanshin/src/features/app/zanshin_app_view_model.dart` does not exist.

- [ ] **Step 4: Implement the view model**

Create `app/lib/src/features/app/zanshin_app_view_model.dart`:

```dart
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Brightness, ThemeMode;
import 'package:inject_annotation/inject_annotation.dart';
import 'package:zanshin_settings/zanshin_settings.dart';
import 'package:zanshin_shell/zanshin_shell.dart';

/// Theme state for the app root: the persisted [ThemeMode] choice plus the
/// live macOS shell theme, resolved into the mode `MaterialApp` should use.
@inject
class ZanshinAppViewModel extends ChangeNotifier {
  ZanshinAppViewModel(this._settings) {
    // Changes from anywhere (another window, another widget) reach this VM.
    _settings.addListener(notifyListeners);
  }

  final SettingsStore _settings;
  ShellTheme? _shellTheme;
  StreamSubscription<ShellTheme>? _subscription;
  bool _disposed = false;

  /// Last theme reported by the macOS shell; null until the platform answered.
  ShellTheme? get shellTheme => _shellTheme;

  /// The user's persisted choice (may be `system`).
  ThemeMode get selectedMode => _settings.value.appearance.themeMode;

  /// The mode `MaterialApp` should use.
  ///
  /// A forced mode wins outright; in system mode the shell channel is
  /// authoritative for day/night on macOS. The channel keeps reporting the
  /// SYSTEM value even while the window appearance is overridden (the
  /// override is per-window), so switching back to system stays correct.
  ThemeMode get effectiveMode {
    final ShellTheme? shellTheme = _shellTheme;
    return switch (selectedMode) {
      ThemeMode.system when shellTheme != null =>
        shellTheme.brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
      _ => selectedMode,
    };
  }

  /// One-shot setup for `ViewModelBuilder`'s `init`.
  ///
  /// On macOS: start the shell-theme query and subscription (both unawaited,
  /// so the first frame renders immediately with Flutter's own brightness) and
  /// mirror the persisted choice onto the window chrome once — a saved `dark`
  /// must style the native title bar after a relaunch, not only Flutter.
  void init() {
    if (!_onMacOS) {
      return;
    }
    unawaited(ZanshinShell.getTheme().then(_applyShellTheme));
    _subscription = ZanshinShell.onThemeChanged.listen(_applyShellTheme);
    _mirrorWindowAppearance(selectedMode);
  }

  /// Persists [mode] and mirrors it onto the native window chrome (blur
  /// background, traffic lights), which Flutter theming cannot reach.
  ///
  /// Listeners are notified through the store; the returned future completes
  /// when the settings file has been written.
  Future<void> setThemeMode(ThemeMode mode) {
    final Future<void> written = _settings.update((s) => s.copyWith.appearance(themeMode: mode));
    _mirrorWindowAppearance(mode);
    return written;
  }

  @override
  void dispose() {
    _disposed = true;
    _settings.removeListener(notifyListeners);
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  static bool get _onMacOS => !kIsWeb && Platform.isMacOS;

  void _applyShellTheme(ShellTheme theme) {
    // A late getTheme() answer after dispose must not notify a disposed notifier.
    if (_disposed) {
      return;
    }
    _shellTheme = theme;
    notifyListeners();
  }

  void _mirrorWindowAppearance(ThemeMode mode) {
    if (!_onMacOS) {
      return;
    }
    unawaited(
      ZanshinShell.setWindowAppearance(switch (mode) {
        ThemeMode.light => WindowAppearance.light,
        ThemeMode.dark => WindowAppearance.dark,
        ThemeMode.system => WindowAppearance.system,
      }),
    );
  }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run (in `app`): `flutter test test/features/app/zanshin_app_view_model_test.dart`
Expected: all 6 tests PASS.

- [ ] **Step 6: Analyzer and formatter**

Run (in `app`): `dart analyze --fatal-infos --fatal-warnings`
Expected: `No issues found!` (the view model is not yet referenced by the graph; that is fine — `@inject` classes are only generated when reachable from a component.)

Run (in `app`): `dart format --output=none --set-exit-if-changed .`
Expected: exit 0.

- [ ] **Step 7: Commit**

```bash
git add app/pubspec.yaml pubspec.lock app/lib/src/features/app/zanshin_app_view_model.dart app/test/features/app/zanshin_app_view_model_test.dart
git commit --no-gpg-sign -m "feat(app): add ZanshinAppViewModel owning theme state

Persisted ThemeMode via SettingsStore, live macOS shell theme, effective
mode resolution and window-chrome mirroring (also once at init).

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 6: Stateless ZanshinApp driven by the view model

**Files:**
- Modify: `app/lib/src/features/app/zanshin_app.dart:1-163` (everything above `class _ExampleHome`)
- Generated (commit): `app/lib/main.inject.dart` (view-model provider + `ViewModelFactory` binding); `app/lib/src/features/app/zanshin_app.factory.dart` (unchanged signature, may be rewritten)

**Interfaces:**
- Consumes: `ZanshinAppViewModel` (Task 5), `ViewModelFactory<T>` from `package:inject_flutter/inject_flutter.dart` — a function `({Key? key, ViewModelInitializer<T>? init, Widget? loading, ViewModelErrorBuilder? error, required ViewModelWidgetBuilder<T> builder, Widget? child})` returning a `ViewModelBuilder<T>` that calls `init` once and `dispose()` on unmount.
- Produces: `ZanshinApp` is a `StatelessWidget`; `ZanshinAppFactory.create({Key? key})` is unchanged for `main.dart`.

- [ ] **Step 1: Rewrite the top of `zanshin_app.dart`**

Replace lines 1–163 of `app/lib/src/features/app/zanshin_app.dart` (from the SPDX line through the closing `}` of `_ZanshinAppState`) with the block below. `_ExampleHome`, `_Example`, `CheckboxPage` and `_CheckboxPageState` below it stay byte-for-byte. Keep the commented-out `_buildTheme`/`build` block from the old file exactly where it was (between the fields and `build`) — it is pre-existing and not part of this change.

```dart
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:inject_annotation/inject_annotation.dart';
import 'package:inject_flutter/inject_flutter.dart';
import 'package:material_ui/material_ui.dart';
import 'package:yaru/yaru.dart';
import 'package:zanshin_shell/zanshin_shell.dart';

import '../home/home_page.dart';
import 'zanshin_app_view_model.dart';

part 'zanshin_app.factory.dart';

class ZanshinApp extends StatelessWidget {
  @assistedInject
  const ZanshinApp({
    required this._homePageFactory,
    required this._viewModelFactory,
    @assisted super.key,
  });

  // Temporarily unused while `home` shows the Yaru test page below.
  // ignore: unused_field
  final HomePageFactory _homePageFactory;
  final ViewModelFactory<ZanshinAppViewModel> _viewModelFactory;

  // <-- keep the pre-existing commented-out `_buildTheme` / `build` block here, unchanged -->

  @override
  Widget build(BuildContext context) => _viewModelFactory(
    init: (vm) => vm.init(),
    builder: (context, vm, _) {
      void onModeChanged(ThemeMode mode) => unawaited(vm.setThemeMode(mode));

      if (!kIsWeb && Platform.isLinux) {
        return YaruTheme(
          builder: (context, yaru, child) => _ExampleHome(
            themeMode: vm.selectedMode,
            selectedMode: vm.selectedMode,
            onModeChanged: onModeChanged,
            lightTheme: yaru.theme,
            darkTheme: yaru.darkTheme,
          ),
        );
      }

      final ShellTheme? shellTheme = vm.shellTheme;
      if (shellTheme == null) {
        // First frame before the platform answered: follow the system via
        // Flutter's own brightness until the shell theme arrives.
        return _ExampleHome(
          themeMode: vm.effectiveMode,
          selectedMode: vm.selectedMode,
          onModeChanged: onModeChanged,
          lightTheme: null,
          darkTheme: null,
        );
      }

      return _ExampleHome(
        themeMode: vm.effectiveMode,
        selectedMode: vm.selectedMode,
        onModeChanged: onModeChanged,
        lightTheme: createYaruLightTheme(primaryColor: shellTheme.accentColor),
        darkTheme: createYaruDarkTheme(primaryColor: shellTheme.accentColor),
      );
    },
  );
}
```

Removed on purpose: the `StatefulWidget`/`_ZanshinAppState`, `_shellTheme`, `_themeMode`, `_subscription`, `initState`, `_applyShellTheme`, `_setThemeMode`, `dispose` — all of that now lives in `ZanshinAppViewModel`.

- [ ] **Step 2: Regenerate the graph**

Run (in `app`): `dart run build_runner build --delete-conflicting-outputs`
Expected: exit 0; `app/lib/main.inject.dart` now contains a `ZanshinAppViewModel` provider fed by the `SettingsStore` provider and a `ViewModelFactory<ZanshinAppViewModel>` binding injected into the `ZanshinApp` factory. `zanshin_app.factory.dart` still declares `ZanshinApp create({Key? key})`.

- [ ] **Step 3: Analyzer, formatter, all app tests**

Run (in `app`): `dart analyze --fatal-infos --fatal-warnings`
Expected: `No issues found!`

Run (in `app`): `dart format --output=none --set-exit-if-changed .`
Expected: exit 0.

Run (in `app`): `flutter test`
Expected: PASS (native asset smoke test + 6 view-model tests).

- [ ] **Step 4: Commit**

```bash
git add app/lib/src/features/app/zanshin_app.dart app/lib/src/features/app/zanshin_app.factory.dart app/lib/main.inject.dart
git commit --no-gpg-sign -m "refactor(app): make ZanshinApp stateless over ZanshinAppViewModel

Theme handling moves into the injected view model (ViewModelFactory);
the widget only renders selected/effective mode and forwards changes.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 7: Full quality gate and native compile check

**Files:**
- Possibly modified by tooling (commit if so): `app/macos/Flutter/GeneratedPluginRegistrant.swift`, `pubspec.lock`

- [ ] **Step 1: Run the whole gate**

Run (repo root): `cargo make test`
Expected: exit 0. It runs cargo test/clippy/fmt, `flutter test` + analyze + format for `app`, `dart test`/analyze/format for `zanshin_core`, the three shell packages, the new `test-settings*` trio, cargo-deny, hygiene checks and the coverage ratchet. Coverage must report no regression and `coverage-baseline.txt` must be unchanged (`git status --short coverage-baseline.txt` prints nothing). If a Dart step fails, fix the code and re-run — never edit the baseline.

- [ ] **Step 2: Native compile check (path_provider_foundation linking)**

Run (in `app`): `flutter build macos --debug`
Expected: exit 0, `app/build/macos/Build/Products/Debug/Zanshin.app` exists. This also regenerates `GeneratedPluginRegistrant.swift` if `flutter pub get` did not.

- [ ] **Step 3: Commit anything the tooling regenerated**

Run (repo root): `git status --short`
Expected: either clean, or only `app/macos/Flutter/GeneratedPluginRegistrant.swift` / `pubspec.lock`. If not clean:

```bash
git add app/macos/Flutter/GeneratedPluginRegistrant.swift pubspec.lock
git commit --no-gpg-sign -m "build(app): register path_provider_foundation in the macOS plugin registrant

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

- [ ] **Step 4: Done-check against the spec**

Confirm by reading, not by memory:
- `packages/zanshin_settings/lib/` has exactly `zanshin_settings.dart`, `src/settings_module.dart`, `src/settings_store.dart`, `src/model/{app_settings,appearance_settings}.dart` plus their four generated parts, all committed.
- `app/lib/main.dart` awaits `SettingsStore.open()` before `MainComponent.create(settingsModule: ...)` and `zanshinAppFactory` is still a synchronous getter.
- `zanshin_app.dart` contains no `StatefulWidget`, `setState`, `StreamSubscription` or `ThemeMode _themeMode`.
- `git log --oneline -7` shows the seven commits from Tasks 1–7 (or six if Task 7 committed nothing).
