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
import 'src/features/bootstrap/zanshin_bootstrap.dart';

void main() {
  // All initialization inside the same zone as runApp to avoid zone mismatch;
  // the asynchronous boot runs inside ZanshinBootstrap, i.e. in this zone too.
  runZonedGuarded(
    () {
      WidgetsFlutterBinding.ensureInitialized();
      // The engine runs the generated Dart plugin registrant before `main`
      // (runtime/dart_isolate.cc); this explicit re-run is redundant but
      // harmless, it is idempotent.
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

      // First frame right away; settings, DI graph and worker boot behind it.
      runApp(const ZanshinBootstrap(openSettings: SettingsStore.open, startApp: _startApp));
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

/// Second boot step: the DI graph over the loaded settings (resolved before
/// the graph so the DI chain stays synchronous — no @asynchronous provider),
/// then the worker, whose provision listener wires the AppLifecycleListener
/// for graceful shutdown on macOS, then the app widget.
Future<Widget> _startApp(SettingsStore settings) async {
  // ignore: specify_nonobvious_local_variable_types
  final mainComponent = MainComponent.create(settingsModule: SettingsModule(store: settings));
  await mainComponent.worker;
  return mainComponent.zanshinAppFactory.create();
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
