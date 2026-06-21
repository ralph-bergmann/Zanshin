// SPDX-License-Identifier: MIT

import 'dart:ui' show AppExitResponse;

import 'package:flutter/widgets.dart';
import 'package:inject_annotation/inject_annotation.dart';

import 'isolate.dart';

/// DI module that owns the full lifecycle of the [ZanshinWorker] singleton.
///
/// The module starts the worker asynchronously via `@asynchronous`; the
/// generator awaits the future and wires the resolved instance before
/// returning the component. A [ProvisionListener] is registered eagerly at
/// component-creation time to hook the worker's shutdown into the Flutter
/// app-lifecycle.
@module
class WorkerModule {
  /// Start and provide the single long-running worker isolate (AR-AD-4).
  ///
  /// `@asynchronous` tells the generator to await [ZanshinWorker.start] and
  /// wire the resolved [ZanshinWorker] instance into the graph. The component
  /// `create` becomes `async` as a result.
  @provides
  @singleton
  @asynchronous
  Future<ZanshinWorker> worker() => ZanshinWorker.start();

  /// Register the app-lifecycle listener that shuts the worker down on exit.
  ///
  /// `@provisionListener` causes [_WorkerLifecycleListener.onProvision] to
  /// fire after each [ZanshinWorker] instance is created.
  @provides
  @singleton
  @provisionListener
  ProvisionListener<ZanshinWorker> workerLifecycle() => _WorkerLifecycleListener();
}

/// Hooks [ZanshinWorker.close] into the Flutter app-lifecycle on macOS.
///
/// `onExitRequested` fires when the system asks the app to quit (macOS
/// window-close / Cmd-Q). Calling [ZanshinWorker.close] here gives the
/// worker a chance to release FFI handles before the process exits. On other
/// platforms this is best-effort — the OS reclaims process resources anyway.
class _WorkerLifecycleListener implements ProvisionListener<ZanshinWorker> {
  @override
  void onProvision(ZanshinWorker instance) {
    // WidgetsBinding holds a strong reference to AppLifecycleListener
    // internally, so no field is needed to prevent GC.
    // WidgetsFlutterBinding.ensureInitialized() is guaranteed to have run in
    // main() before the component is created.
    AppLifecycleListener(
      onExitRequested: () async {
        instance.close();
        return AppExitResponse.exit;
      },
    );
  }
}
