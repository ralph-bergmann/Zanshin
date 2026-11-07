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
import 'package:zanshin_ui/zanshin_ui.dart';

import 'main.inject.dart' as g;
import 'src/app/app_module.dart';
import 'src/app/boot/boot_module.dart';
import 'src/app/boot/boot_window_host.dart';
import 'src/app/boot/zanshin_bootstrap.dart';
import 'src/app/zanshin_application.dart';
import 'src/app/zanshin_marionette.dart';
import 'src/features/projects/projects_module.dart';
import 'src/features/window/app_windows.dart';

final _log = Logger('zanshin.bootstrap');

Future<void> main() async {
  // All initialization inside the same zone as the first `runWidget` to avoid
  // a zone mismatch; the asynchronous boot runs inside the sequence below,
  // i.e. in this zone too.
  await runZonedGuarded(
    () async {
      if (kDebugMode) {
        MarionetteBinding.ensureInitialized(zanshinMarionetteConfiguration);
      } else {
        WidgetsFlutterBinding.ensureInitialized();
      }
      SemanticsBinding.instance.ensureSemantics();
      zsRingFollowsInput();

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
      // sequence opens one: the splash if the boot is slow, else the first
      // app window straight away. The boot loads what the DI graph needs, the
      // graph wires the app, and the app answers the first window. One
      // AppWindows serves the host and the graph.
      final windows = AppWindows();
      final host = ZanshinWindowHost(windows: windows);
      await ZanshinBootSequence(host: host).run((progress) async {
        final BootValues boot = await loadBootValues(progress);
        final MainComponent component = MainComponent.create(bootModule: BootModule(boot, windows));
        final ZanshinApplication app = component.application;
        final BootFirstWindow first = app.start();
        // After start(): a start that throws keeps the boot's system menus, not app menus whose windows never come.
        host.showMenu(app.menu);
        return first;
      });
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

/// The app's DI graph over the boot's values ([BootModule]): it wires the app and hands out one object, the app.
@Component([
  ZanshinDiagnosticsModule,
  BootModule,
  ProjectsModule,
  AppModule,
])
abstract class MainComponent {
  // ignore: specify_nonobvious_property_types
  static const create = g.MainComponent$Component.create;

  /// The app, wired.
  @inject
  ZanshinApplication get application;
}
