// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:flutter/semantics.dart';

// ignore: implementation_imports, invalid_use_of_internal_member
import 'package:flutter/src/foundation/_features.dart' show isWindowingEnabled;
import 'package:flutter/widgets.dart';
import 'package:inject_annotation/inject_annotation.dart';
import 'package:logging/logging.dart';
import 'package:marionette_flutter/marionette_flutter.dart';
import 'package:zanshin_core/zanshin_core.dart';
import 'package:zanshin_settings/zanshin_settings.dart';

import 'main.inject.dart' as g;
import 'src/app/worker_lifecycle_module.dart';
import 'src/features/app/zanshin_app.dart';
import 'src/features/bootstrap/boot_window_host.dart';
import 'src/features/bootstrap/zanshin_bootstrap.dart';
import 'src/features/window/app_windows.dart';
import 'src/shared/widgets/icon_registry.dart';

final _log = Logger('zanshin.bootstrap');

Future<void> main() async {
  // All initialization inside the same zone as the first `runWidget` to avoid
  // a zone mismatch; the asynchronous boot runs inside the sequence below,
  // i.e. in this zone too.
  await runZonedGuarded(
    () async {
      if (kDebugMode) {
        MarionetteBinding.ensureInitialized();
      } else {
        WidgetsFlutterBinding.ensureInitialized();
      }
      SemanticsBinding.instance.ensureSemantics();

      initLogForwarding(level: .ALL);

      FlutterError.onError = (details) {
        forwardLogRecord(
          LogRecord(
            .SEVERE,
            details.exception.toString(),
            details.library ?? 'FlutterError',
            details.exception,
            details.stack,
          ),
        );
        FlutterError.presentError(details);
      };

      // The windowing feature flag is compiled in from the machine-global
      // `flutter config`. Without it every windowing call throws an
      // UnsupportedError and the app shows nothing at all; say why instead of
      // leaving that to be decoded from the zone handler's output.
      // ignore: invalid_use_of_internal_member
      if (!isWindowingEnabled) {
        _log.severe(
          'Flutter windowing is disabled in this build, so no window can be created. '
          'Run `flutter config --enable-windowing` and rebuild.',
        );
      }

      // Every window is created from Dart, so nothing is on screen until the
      // sequence opens one: the splash if the boot is slow, else the main
      // window straight away. The icons reach every window through the host
      // and the DI graph through `startApp`.
      final icons = ValueNotifier<IconRegistry?>(null);
      await ZanshinBootSequence(
        host: ZanshinWindowHost(windows: AppWindows(), icons: icons),
        openSettings: SettingsStore.open,
        adoptShellEnvironment: _adoptShellEnvironment,
        loadIcons: () async => icons.value = await IconRegistry.load(),
        startApp: _startApp,
      ).run();
    },
    (error, stackTrace) {
      developer.log(
        'Uncaught zone error: $error',
        stackTrace: stackTrace,
        name: 'zanshin',
      );
    },
  );
}

/// Runs alongside the settings load (Story 9.36): a Finder/Dock launch inherits
/// launchd's minimal environment, so the login shell's is adopted before the
/// app starts and no repo is ever opened without it. On failure the
/// started-with environment stays in effect — logged, not fatal.
Future<void> _adoptShellEnvironment() async {
  final LoginShellEnvironmentResult result = await adoptLoginShellEnvironment();
  for (final ZanshinWarning warning in result.warnings) {
    _log.warning('${warning.code}: ${warning.message}');
  }
}

/// Second boot step: the DI graph over the loaded settings and icons (resolved
/// before the graph so the DI chain stays synchronous — no @asynchronous
/// provider), then the worker, whose provision listener wires the
/// AppLifecycleListener for graceful shutdown on macOS, then the app widget.
Future<Widget> _startApp(SettingsStore settings, IconRegistry icons) async {
  // ignore: specify_nonobvious_local_variable_types
  final mainComponent = MainComponent.create(
    settingsModule: SettingsModule(store: settings),
    iconModule: IconModule(registry: icons),
  );
  await mainComponent.worker;
  return mainComponent.zanshinAppFactory.create();
}

@Component([
  ZanshinFfiModule,
  ZanshinDiagnosticsModule,
  WorkerModule,
  WorkerLifecycleModule,
  SettingsModule,
  IconModule,
])
abstract class MainComponent {
  // ignore: specify_nonobvious_property_types
  static const create = g.MainComponent$Component.create;

  // WHY: inject_generator reads these @inject abstract getters as the DI
  // contract and emits concrete overrides in main.inject.dart. The analyzer's
  // unreachable_from_main check can't see the generated overrides — they are
  // load-bearing for codegen. Suppress the false positive.
  @inject
  ZanshinAppFactory get zanshinAppFactory; // ignore: unreachable_from_main

  @inject
  Future<ZanshinWorker> get worker; // ignore: unreachable_from_main
}
