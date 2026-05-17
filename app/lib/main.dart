// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/semantics.dart';
import 'package:flutter/widgets.dart';
import 'package:yaru/widgets.dart';

import 'src/features/app/zanshin_app.dart';

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
      runApp(const ZanshinApp());
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
