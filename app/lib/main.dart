// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:developer' as developer;
import 'dart:ui' show DartPluginRegistrant;

import 'package:flutter/semantics.dart';
import 'package:flutter/widgets.dart';
import 'package:inject_annotation/inject_annotation.dart';
import 'package:logging/logging.dart';
import 'package:zanshin_core/zanshin_core.dart';
import 'package:zanshin_settings/zanshin_settings.dart';

import 'main.inject.dart' as g;
import 'src/app/worker_lifecycle_module.dart';
import 'src/features/app/zanshin_app.dart';

Future<void> main() async {
  // All initialization inside the same zone as runApp to avoid zone mismatch.
  await runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();
      // The macOS engine does not invoke the generated Dart plugin registrant
      // on its own, so dartPluginClass-based plugins (zanshin_shell_macos)
      // would never register their platform instance. Idempotent.
      DartPluginRegistrant.ensureInitialized();
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

      // Resolve the settings before the graph exists so the DI chain stays
      // synchronous (no @asynchronous provider, no Future entry points).
      final SettingsStore settings = await SettingsStore.open();
      // ignore: specify_nonobvious_local_variable_types
      final mainComponent = MainComponent.create(settingsModule: SettingsModule(store: settings));
      // Start the worker and trigger the ProvisionListener (which wires the
      // AppLifecycleListener for graceful shutdown on macOS).
      await mainComponent.worker;
      final ZanshinApp app = mainComponent.zanshinAppFactory.create();
      runApp(app);
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

@Component([ZanshinFfiModule, ZanshinDiagnosticsModule, WorkerModule, WorkerLifecycleModule, SettingsModule])
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
