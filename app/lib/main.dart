// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/semantics.dart';
import 'package:flutter/widgets.dart';
import 'package:inject_annotation/inject_annotation.dart';
import 'package:yaru/widgets.dart';

import 'main.inject.dart' as g;
import 'src/features/app/zanshin_app.dart';
import 'src/ffi/zanshin_version.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SemanticsBinding.instance.ensureSemantics();

  FlutterError.onError = (details) {
    developer.log(
      'FlutterError: ${details.exceptionAsString()}',
      stackTrace: details.stack,
      name: 'zanshin',
    );
    FlutterError.presentError(details);
  };

  await runZonedGuarded(
    () async {
      await YaruWindowTitleBar.ensureInitialized();

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

  @inject
  ZanshinAppFactory get zanshinAppFactory;
}
