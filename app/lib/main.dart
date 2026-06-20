// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/semantics.dart';
import 'package:flutter/widgets.dart';
import 'package:inject_annotation/inject_annotation.dart';
import 'package:logging/logging.dart';
import 'package:window_manager/window_manager.dart';

import 'main.inject.dart' as g;
import 'src/features/app/zanshin_app.dart';
import 'src/ffi/log_forwarder.dart';
import 'src/ffi/zanshin_version.dart';

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

      final g.MainComponent$Component mainComponent = MainComponent.create();
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

@Component([ZanshinFfiModule])
abstract class MainComponent {
  static const g.MainComponent$Component Function() create = g.MainComponent$Component.create;

  // WHY: inject_generator reads this @inject abstract getter as the DI contract
  // and emits its concrete override in main.inject.dart. The analyzer's
  // unreachable_from_main check can't see the generated override, so it reports
  // the declaration as dead — it is load-bearing for codegen. Suppress the false
  // positive (mirrors the Rust crate-level #[allow] + // WHY: discipline).
  @inject
  ZanshinAppFactory get zanshinAppFactory; // ignore: unreachable_from_main
}
