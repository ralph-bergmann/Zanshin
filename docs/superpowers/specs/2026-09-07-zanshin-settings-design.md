# zanshin_settings — Persistent App Settings Design

**Date:** 2026-09-07
**Status:** approved design, pending implementation plan
**Scope:** the new `packages/zanshin_settings` package, its wiring into the app's
DI graph, and the first consumer (`ZanshinAppViewModel` in `app/`).

## Goal

Persist user-facing app settings (first one: the day/night/system `ThemeMode`)
as a JSON file on disk. The file is read once at app start and cached in memory;
every write persists immediately. The settings model is a Freezed root model
(`AppSettings`) that grows by adding typed sub-models. An inject.dart module
exposes the store to the app's `MainComponent`.

## Context

- `packages/zanshin_settings` exists as an empty `flutter create --template=package`
  scaffold (pubspec with `freezed_annotation`, `json_annotation`, `path_provider`,
  dev: `build_runner`, `freezed`, `json_serializable`); `lib/` is empty.
- DI is inject.dart (`inject_annotation` / `inject_generator` / `inject_flutter`).
  The app's root graph is `MainComponent` in `app/lib/main.dart`
  (`@Component([ZanshinFfiModule, ZanshinDiagnosticsModule, WorkerModule, WorkerLifecycleModule])`).
- `ZanshinApp` (`app/lib/src/features/app/zanshin_app.dart`) is a `StatefulWidget`
  that keeps the `ThemeMode` in widget state, subscribes to `ZanshinShell.onThemeChanged`
  on macOS, and mirrors the user's choice onto the native window chrome via
  `ZanshinShell.setWindowAppearance`.
- `cargo make test` is the definition of done; it runs per-package
  `flutter test` / `dart analyze --fatal-infos --fatal-warnings` /
  `dart format --set-exit-if-changed` tasks declared in `Makefile.toml`.

## Decisions (with rationale)

| Decision | Choice | Why |
|---|---|---|
| Sub-model extension | Typed fields on `AppSettings`, one Freezed class per sub-model, each with `@Default` | Type-safe, deep `copyWith`, minimal code. A dynamic section registry was rejected as speculative. |
| Change notification | `SettingsStore implements ValueListenable<AppSettings>` | Flutter-native; `ValueListenableBuilder`/`addListener` work directly; fits multi-window. |
| DI shape | `SettingsModule` carries a pre-loaded `SettingsStore` (required constructor parameter); no `@asynchronous` | Keeps the whole graph synchronous ("resolve before the graph", inject.dart docs ch. 4). No `Future<T>` entry points, `ViewModelFactory` chains stay safe. |
| Corrupt file | Log a warning, rename to `settings.json.corrupt`, start with defaults | Nothing is silently destroyed; a hand-edit typo never blocks app start. |
| Versioning | No `version` field, no migrations | A missing key or sub-model falls back to its `@Default` (json_serializable uses the constructor default when the key is absent). WIP posture: breaking changes are allowed. |
| File location | `getApplicationSupportDirectory()/settings.json` | Conventional macOS location (`~/Library/Application Support/<bundle-id>/`). |
| Enum encoding | Flutter's `ThemeMode` reused; serialized by name (`"system"`) | No mapping layer in the UI; readable JSON. |
| First consumer | `ZanshinAppViewModel` (`ChangeNotifier`, injected via `ViewModelFactory`) owns all theme handling; `ZanshinApp` becomes stateless | Requested by Ralph; removes `setState` theme logic from the widget. |

## Package layout

```
packages/zanshin_settings/
  pubspec.yaml                              # + logging; dev: path_provider_platform_interface, plugin_platform_interface
  analysis_options.yaml                     # excludes **/*.freezed.dart, **/*.g.dart, build/**
  build.yaml                                # json_serializable `checked: true`
  lib/zanshin_settings.dart                 # barrel: exports model, store, module
  lib/src/model/app_settings.dart           # root model (+ app_settings.freezed.dart, app_settings.g.dart)
  lib/src/model/appearance_settings.dart    # first sub-model (+ generated parts)
  lib/src/settings_store.dart               # cache + persistence
  lib/src/settings_module.dart              # inject.dart module
  test/model/app_settings_test.dart
  test/settings_store_test.dart
  test/settings_module_test.dart
```

Rules:
- Every hand-written Dart file starts with `// SPDX-License-Identifier: MIT`.
  Generated files (`*.freezed.dart`, `*.g.dart`) are exempt and are **committed**
  (same discipline as `main.inject.dart`; the build never regenerates).
- `pubspec.yaml` gains `publish_to: 'none'` (all sibling packages have it) and
  dependencies sorted alphabetically (`sort_pub_dependencies` is enforced with
  `--fatal-infos`; the scaffold currently lists `flutter_test` last).
- Comments and docs in English; `///` on every exported item.

## Data model

```dart
@freezed
abstract class AppSettings with _$AppSettings {
  const factory AppSettings({
    @Default(AppearanceSettings()) AppearanceSettings appearance,
  }) = _AppSettings;

  factory AppSettings.fromJson(Map<String, Object?> json) => _$AppSettingsFromJson(json);
}

@freezed
abstract class AppearanceSettings with _$AppearanceSettings {
  const factory AppearanceSettings({
    @Default(ThemeMode.system) ThemeMode themeMode,
  }) = _AppearanceSettings;

  factory AppearanceSettings.fromJson(Map<String, Object?> json) =>
      _$AppearanceSettingsFromJson(json);
}
```

- On-disk shape (pretty-printed, two-space indent, trailing newline):

  ```json
  {
    "appearance": {
      "themeMode": "system"
    }
  }
  ```

- JSON keys are the Dart property names (lowerCamelCase). Enums serialize by
  `name`.
- Missing keys and missing sub-model objects resolve to the `@Default` value.
  Unknown keys are ignored (json_serializable default). No `version` field.
- Adding a setting = add a field with `@Default` to the relevant sub-model.
  Adding a sub-model = new Freezed class + `@Default(NewSettings()) NewSettings newSettings`
  field on `AppSettings`. Run `dart run build_runner build` in the package and
  commit the regenerated parts.
- `build.yaml` enables json_serializable's `checked: true` so every decoding
  failure (wrong type, unknown enum name, non-object sub-model) surfaces as a
  `CheckedFromJsonException` (an `Exception`), never as a `TypeError`/`ArgumentError`
  (`avoid_catching_errors` forbids catching `Error`s).

## SettingsStore

```dart
/// In-memory cache of [AppSettings] backed by one JSON file.
class SettingsStore implements ValueListenable<AppSettings> {
  /// Reads [file]; never throws for a missing or unreadable file.
  static Future<SettingsStore> load(File file);

  /// [load] at the default location: `<application support dir>/settings.json`
  /// (path_provider `getApplicationSupportDirectory`).
  static Future<SettingsStore> open();

  /// The file this store persists to.
  File get file;

  /// Current settings (never null; defaults until the first successful load/update).
  @override
  AppSettings get value;

  @override void addListener(VoidCallback listener);
  @override void removeListener(VoidCallback listener);

  /// Applies [change] to [value], notifies listeners synchronously, persists
  /// immediately. Completes when the write has finished.
  Future<void> update(AppSettings Function(AppSettings current) change);
}
```

Semantics:

- **load**
  - File does not exist → `value = AppSettings()`; nothing is written.
  - File parses (`jsonDecode` yields a `Map<String, Object?>` and
    `AppSettings.fromJson` succeeds) → that value.
  - Anything else (`FormatException`, top-level JSON that is not an object,
    `CheckedFromJsonException`) → log at `WARNING` (file **name** only, no path,
    no content; the exception object at `FINE`), rename the file to
    `<file>.corrupt` (replacing an older `.corrupt`), `value = AppSettings()`.
    Nothing is written until the next `update`. If the rename itself fails, that
    error is logged at `WARNING` too and the store still starts with defaults
    (the next `update` overwrites the unreadable file).
  - `open()` does not catch errors from path_provider; a missing platform
    implementation surfaces to the caller (`main()`), because without a
    location there is nothing sensible to fall back to.
  - Logger name: `zanshin.settings` (`package:logging`; the app already forwards
    `Logger.root` to the Rust sink via `initLogForwarding`).
- **update**
  - `next = change(value)`. If `next == value` (Freezed structural equality):
    no notification, no write, the future completes immediately.
  - Otherwise `value = next` and listeners are notified **synchronously**
    (via an internal `ValueNotifier`), then the write is enqueued.
  - Writes are serialized in call order through one Future chain; each `update`
    returns the future of its own write. A failed write completes that future
    with the error and is logged at `WARNING` (no path); it does **not** stop
    later writes, and the in-memory value stays as set.
  - A write creates the parent directory if missing, writes `<file>.tmp`, then
    renames it over `<file>` (atomic replace on POSIX — a crash mid-write never
    leaves a half-written `settings.json`).
- The store lives for the app's lifetime; it has no `dispose`.
- Consumer example: `store.update((s) => s.copyWith.appearance(themeMode: mode))`.

## SettingsModule and app bootstrap

```dart
/// DI module handing a pre-loaded [SettingsStore] to the graph.
@module
class SettingsModule {
  SettingsModule({required this.store});

  final SettingsStore store;

  @provides
  @singleton
  SettingsStore settingsStore() => store;
}
```

`app/lib/main.dart`:

```dart
initLogForwarding(level: .ALL);   // existing — before the store so its warnings are forwarded
...
final SettingsStore settings = await SettingsStore.open();
final mainComponent = MainComponent.create(settingsModule: SettingsModule(store: settings));
await mainComponent.worker;        // existing
final ZanshinApp app = mainComponent.zanshinAppFactory.create();   // stays synchronous
```

- `@Component([ZanshinFfiModule, ZanshinDiagnosticsModule, WorkerModule, WorkerLifecycleModule, SettingsModule])`.
- No `settings` getter on `MainComponent`: consumers inject `SettingsStore`
  directly; the file is read before the component exists, i.e. before `runApp`.
- `app/pubspec.yaml` gains `zanshin_settings: path: ../packages/zanshin_settings`.
- `dart run build_runner build --delete-conflicting-outputs` in `app/` regenerates
  `main.inject.dart` and `zanshin_app.factory.dart`; `flutter pub get` / a
  macOS build refreshes `app/macos/Flutter/GeneratedPluginRegistrant.swift`
  (path_provider_foundation registers there). Both are committed.

## ZanshinAppViewModel and stateless ZanshinApp

`app/lib/src/features/app/zanshin_app_view_model.dart`:

```dart
@inject
class ZanshinAppViewModel extends ChangeNotifier {
  ZanshinAppViewModel(this._settings) {
    _settings.addListener(notifyListeners);   // changes from anywhere reach this VM
  }

  /// Last theme reported by the macOS shell; null until the platform answered.
  ShellTheme? get shellTheme;

  /// The user's persisted choice (may be `system`).
  ThemeMode get selectedMode => _settings.value.appearance.themeMode;

  /// Resolved mode for MaterialApp: `system` + shell brightness → light/dark;
  /// otherwise [selectedMode]. Same rules as today's `_ZanshinAppState.build`.
  ThemeMode get effectiveMode;

  /// One-shot setup, called by ViewModelBuilder's `init`. On macOS: start
  /// `ZanshinShell.getTheme()` and subscribe to `onThemeChanged` (both unawaited,
  /// so the first frame renders immediately, as today), and mirror
  /// [selectedMode] onto the window chrome once, so a persisted `dark` also
  /// styles the native title bar after a relaunch.
  void init();

  /// Persists [mode] and mirrors it onto the window chrome (macOS).
  /// Listeners are notified through the store listener.
  Future<void> setThemeMode(ThemeMode mode);

  /// Cancels the shell subscription, unregisters from the store; a late
  /// `getTheme()` result after dispose is dropped (no notify on a disposed notifier).
  @override
  void dispose();
}
```

- The mode → `WindowAppearance` mapping and the `!kIsWeb && Platform.isMacOS`
  guard move verbatim from `zanshin_app.dart`.
- `ZanshinApp` becomes a `StatelessWidget`. Its `@assistedInject` constructor keeps
  `HomePageFactory` (still unused, `// ignore: unused_field` stays) and adds
  `ViewModelFactory<ZanshinAppViewModel>`. `build` returns
  `_viewModelFactory(init: (vm) => vm.init(), builder: (context, vm, _) => ...)`,
  where the builder body is today's `build` with `_themeMode` → `vm.selectedMode`,
  `effectiveMode` → `vm.effectiveMode`, `_shellTheme` → `vm.shellTheme`,
  `_setThemeMode` → `(mode) => unawaited(vm.setThemeMode(mode))`.
  `_ExampleHome`, `_Example`, `CheckboxPage`, the Linux branch and the
  "first frame before the platform answered" branch are unchanged.
- `main.dart`'s flow does not change beyond the bootstrap lines above.

## Quality gate integration

`Makefile.toml`: three private tasks mirroring the `zanshin_shell` trio, appended
to `[tasks.test].dependencies` after `test-shell-macos-format`:

- `test-settings` — `flutter test` in `packages/zanshin_settings`
- `test-settings-analyze` — `dart analyze --fatal-infos --fatal-warnings`
- `test-settings-format` — `dart format --output=none --set-exit-if-changed .`

Generated files must pass the format check unchanged: Freezed ≥ 3 emits
`// dart format off`, json_serializable emits `// dart format width=80`. If a
generated file still fails the check, the fix is a generator option, never a
hand edit of generated code.

`coverage-baseline.txt` is Rust-only and must not change.

## Testing

All tests use temp directories (`Directory.systemTemp.createTemp`) cleaned up in
`tearDown`; no test touches the real Application Support directory.

**`packages/zanshin_settings`** (`flutter test`):

- `test/model/app_settings_test.dart`
  - defaults: `AppSettings()` has `appearance.themeMode == ThemeMode.system`
  - JSON round trip preserves a non-default value (`dark`)
  - missing `themeMode` key → default; missing `appearance` object → default
  - unknown key is ignored
  - `toJson` encodes the enum by name (`'dark'`)
- `test/settings_store_test.dart`
  - missing file → defaults, no file created
  - valid file → parsed value
  - corrupt file (invalid JSON / top-level array / wrong field type / unknown enum
    name) → defaults, original bytes now at `settings.json.corrupt`, a WARNING
    record on `zanshin.settings`, no `settings.json` left behind
  - `update` notifies synchronously with the new value and the file contains the
    pretty-printed JSON when the future completes; no `.tmp` file remains
  - unchanged `update` → no notification, no write
  - three rapid `update` calls persist in order (final file = last value)
  - write failure (file path is an existing directory) → the future fails, the
    in-memory value is still updated, a later write to a good path succeeds
  - `open()` with a fake `PathProviderPlatform` (`MockPlatformInterfaceMixin`)
    → `store.file.path == '<dir>/settings.json'`
- `test/settings_module_test.dart`
  - `SettingsModule(store: s).settingsStore()` is identical to `s`

**`app/test/features/app/zanshin_app_view_model_test.dart`** (`flutter test`;
dev-deps `plugin_platform_interface`, `zanshin_shell_platform_interface` for the
fake `ZanshinShellPlatform`, same shape as `packages/zanshin_shell/test`):

- `selectedMode` reflects the persisted value loaded from the temp file
- `init()` records `setWindowAppearance:<persisted mode>`, applies the
  `getTheme()` result (`shellTheme` set, listener notified), and forwards
  `onThemeChanged` events
- `setThemeMode(light)` persists (`settings.json` contains `"light"`), records
  `setWindowAppearance:light`, notifies listeners
- `effectiveMode`: `system` + dark shell → `dark`; explicit `light` → `light`;
  `system` without shell theme → `system`
- an external `store.update` notifies the view model
- after `dispose()` a shell event does not notify

## Non-goals

- Watching `settings.json` for external edits.
- Schema versioning or migrations.
- Debounced or batched writes; per-setting convenience methods.
- Widget/UI changes beyond `zanshin_app.dart` (no new screens, no settings UI).
- Encryption or anything beyond a plain JSON file.

## Files touched outside the package

- `app/lib/main.dart` (component annotation, bootstrap lines)
- `app/lib/main.inject.dart`, `app/lib/src/features/app/zanshin_app.factory.dart` (regenerated)
- `app/lib/src/features/app/zanshin_app.dart` (stateless, view-model driven)
- `app/lib/src/features/app/zanshin_app_view_model.dart` (new)
- `app/test/features/app/zanshin_app_view_model_test.dart` (new)
- `app/pubspec.yaml` (dependency + two dev-dependencies)
- `app/macos/Flutter/GeneratedPluginRegistrant.swift` (regenerated)
- `Makefile.toml` (three tasks + dependency list)
- `pubspec.lock` (workspace lock, already partially staged)
