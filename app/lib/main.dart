// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/semantics.dart';
import 'package:flutter/widgets.dart';
import 'package:inject_annotation/inject_annotation.dart';
import 'package:logging/logging.dart';
import 'package:zanshin_core/zanshin_core.dart';
import 'package:zanshin_settings/zanshin_settings.dart';

import 'main.inject.dart' as g;
import 'src/app/worker_lifecycle_module.dart';
import 'src/features/app/zanshin_app.dart';
import 'src/features/bootstrap/boot_window_host.dart';
import 'src/features/bootstrap/zanshin_bootstrap.dart';
import 'src/features/window/app_windows.dart';

Future<void> main() async {
  // All initialization inside the same zone as the first `runWidget` to avoid
  // a zone mismatch; the asynchronous boot runs inside the sequence below,
  // i.e. in this zone too.
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

      // Every window is created from Dart, so nothing is on screen until the
      // sequence opens one: the splash if the boot is slow, else the main
      // window straight away.
      await ZanshinBootSequence(
        host: ZanshinWindowHost(windows: AppWindows()),
        openSettings: SettingsStore.open,
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
