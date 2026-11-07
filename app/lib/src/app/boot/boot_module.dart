// SPDX-License-Identifier: MIT

import 'package:inject_annotation/inject_annotation.dart';
import 'package:logging/logging.dart';
import 'package:zanshin_core/zanshin_core.dart';
import 'package:zanshin_settings/zanshin_settings.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

import '../../features/window/app_windows.dart';
import '../../l10n/strings.dart';
import 'zanshin_bootstrap.dart';

final _log = Logger('zanshin.bootstrap');

/// What the boot loads before the DI graph exists ([loadBootValues]) and hands to it ([BootModule]).
typedef BootValues = ({SettingsStore settings, IconRegistry icons, ZanshinWorker worker});

/// The boot's steps before the DI graph, reported to [progress]: the persisted settings — the persisted theme is
/// reported as soon as they are read, in time for a failure in a later step —, the login shell's environment
/// ([adoptShellEnvironment], Story 9.36) and the icons ([loadIcons], decision 16.32) read alongside them, so their time
/// is hidden behind the settings', then the worker ([startWorker]), only once the environment is adopted, so no repo is
/// ever opened without it. A failed step fails the boot; the worker then never starts.
///
/// The status lines come from the platform-resolved strings (Story 11.16; no window exists yet); the wording is
/// Claude's proposal (Story 11.1).
Future<BootValues> loadBootValues(
  BootProgress progress, {
  Future<SettingsStore> Function() openSettings = SettingsStore.open,
  Future<void> Function() adoptShellEnvironment = _adoptShellEnvironment,
  Future<IconRegistry> Function() loadIcons = IconRegistry.load,
  Future<ZanshinWorker> Function() startWorker = ZanshinWorker.start,
}) async {
  final AppLocalizations strings = platformStrings();
  progress.log(strings.bootLoadingSettings);
  var shellPending = true;
  // `ignore` only keeps an early failure from counting as unhandled while the settings load: the awaits below still
  // throw it.
  final Future<void> shellEnvironment = adoptShellEnvironment().whenComplete(() => shellPending = false)..ignore();
  final Future<IconRegistry> icons = loadIcons()..ignore();
  final SettingsStore settings = await openSettings();
  progress.persistedTheme = settings.value.appearance.themeMode;
  if (shellPending) {
    progress.log(strings.bootReadingShell);
  }
  await shellEnvironment;
  final IconRegistry registry = await icons;
  progress.log(strings.bootStarting);
  return (settings: settings, icons: registry, worker: await startWorker());
}

/// A Finder/Dock launch inherits launchd's minimal environment, so the login shell's is adopted before the app starts
/// (Story 9.36). On failure the started-with environment stays in effect — logged, not fatal.
Future<void> _adoptShellEnvironment() async {
  final LoginShellEnvironmentResult result = await adoptLoginShellEnvironment();
  for (final ZanshinWarning warning in result.warnings) {
    _log.warning('${warning.code}: ${warning.message}');
  }
}

/// DI module handing the boot's values and the app's [AppWindows] to the graph: they exist before the component, so
/// the graph stays synchronous — no `@asynchronous` provider, no future of the worker.
@module
class BootModule {
  /// The module over what the boot loaded ([boot]) and the app's [windows], which the boot's window host shares.
  BootModule(this.boot, this.windows);

  /// What the boot loaded.
  final BootValues boot;

  /// The app's windows.
  final AppWindows windows;

  /// Provides the app-wide [SettingsStore].
  @provides
  @singleton
  SettingsStore settings() => boot.settings;

  /// Provides the boot-loaded [IconRegistry].
  @provides
  @singleton
  IconRegistry icons() => boot.icons;

  /// Provides the boot's [ZanshinWorker], started.
  @provides
  @singleton
  ZanshinWorker worker() => boot.worker;

  /// Provides the app's [AppWindows].
  @provides
  @singleton
  AppWindows appWindows() => windows;
}
