// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/semantics.dart';
import 'package:flutter/widgets.dart';
import 'package:inject_annotation/inject_annotation.dart';
import 'package:logging/logging.dart';
import 'package:window_manager/window_manager.dart';

import 'main.inject.dart' as g;
import 'src/features/app/zanshin_app.dart';
import 'src/ffi/diagnostics.dart';
import 'src/ffi/log_forwarder.dart';
import 'src/ffi/zanshin_version.dart';
import 'src/worker/isolate.dart';
import 'src/worker/worker_module.dart';

Future<void> main() async {
  // All initialization inside the same zone as runApp to avoid zone mismatch.
  await runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();
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

      await windowManager.ensureInitialized();
      await windowManager.waitUntilReadyToShow(
        const WindowOptions(
          titleBarStyle: TitleBarStyle.hidden,
          minimumSize: Size(900, 600),
        ),
        () async {
          await windowManager.show();
          await windowManager.focus();
        },
      );

      // ignore: specify_nonobvious_local_variable_types
      final mainComponent = MainComponent.create();
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

@Component([ZanshinFfiModule, ZanshinDiagnosticsModule, WorkerModule])
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
