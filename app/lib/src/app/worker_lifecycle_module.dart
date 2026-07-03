// SPDX-License-Identifier: MIT

import 'dart:ui' show AppExitResponse;

import 'package:flutter/widgets.dart';
import 'package:inject_annotation/inject_annotation.dart';
import 'package:zanshin_core/zanshin_core.dart';

/// App-layer DI module that hooks [ZanshinWorker.close] into the Flutter
/// app-lifecycle.
///
/// Lives in the app (not `zanshin_core`) because it depends on Flutter's
/// [AppLifecycleListener]; the core bridge package stays Flutter-free so it
/// remains testable under `dart test`.
@module
class WorkerLifecycleModule {
  /// Register the app-lifecycle listener that shuts the worker down on exit.
  ///
  /// `@provisionListener` causes [_WorkerLifecycleListener.onProvision] to fire
  /// after each [ZanshinWorker] instance is created.
  @provides
  @singleton
  @provisionListener
  ProvisionListener<ZanshinWorker> workerLifecycle() => _WorkerLifecycleListener();
}

/// Hooks [ZanshinWorker.close] into the Flutter app-lifecycle on macOS.
///
/// `onExitRequested` fires when the system asks the app to quit (macOS
/// window-close / Cmd-Q). Calling [ZanshinWorker.close] gives the worker a
/// chance to release FFI handles before the process exits. On other platforms
/// this is best-effort — the OS reclaims process resources anyway.
class _WorkerLifecycleListener implements ProvisionListener<ZanshinWorker> {
  @override
  void onProvision(ZanshinWorker instance) {
    // WidgetsBinding holds a strong reference to AppLifecycleListener internally,
    // so no field is needed to prevent GC. WidgetsFlutterBinding.ensureInitialized()
    // is guaranteed to have run in main() before the component is created.
    AppLifecycleListener(
      onExitRequested: () async {
        await instance.close();
        return AppExitResponse.exit;
      },
    );
  }
}
