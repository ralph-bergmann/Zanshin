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
  /// The module over [mayQuit], which a quit asks first (Story 11.12 item 7: the windows' close guards, 10.22's
  /// "Discard changes?").
  WorkerLifecycleModule({required this.mayQuit});

  /// Answers whether the app may quit now.
  final Future<bool> Function() mayQuit;

  /// Register the app-lifecycle listener that shuts the worker down on exit.
  ///
  /// `@provisionListener` causes [_WorkerLifecycleListener.onProvision] to fire
  /// after each [ZanshinWorker] instance is created.
  @provides
  @singleton
  @provisionListener
  ProvisionListener<ZanshinWorker> workerLifecycle() => _WorkerLifecycleListener(mayQuit);
}

/// What a quit request runs (⌘Q): [mayQuit] first — a refusal cancels the quit and leaves the worker alone —, then
/// [closeWorker], then the exit.
Future<AppExitResponse> answerExitRequest({
  required Future<bool> Function() mayQuit,
  required Future<void> Function() closeWorker,
}) async {
  if (!await mayQuit()) {
    return AppExitResponse.cancel;
  }
  await closeWorker();
  return AppExitResponse.exit;
}

/// Hooks [ZanshinWorker.close] into the Flutter app-lifecycle on macOS.
///
/// `onExitRequested` fires when the system *asks* the app to quit — on macOS
/// that is ⌘Q. Closing the last window that keeps the app alive does not reach
/// it: the window registry exits with `AppExitType.required`, which the
/// framework documents as exiting immediately without querying the application.
/// The quit asks the windows' close guards first ([answerExitRequest]); calling
/// [ZanshinWorker.close] then gives the worker a chance to release FFI handles
/// before the process exits. On other platforms this is best-effort — the OS
/// reclaims process resources anyway.
class _WorkerLifecycleListener implements ProvisionListener<ZanshinWorker> {
  _WorkerLifecycleListener(this._mayQuit);

  final Future<bool> Function() _mayQuit;

  @override
  void onProvision(ZanshinWorker instance) {
    // WidgetsBinding holds a strong reference to AppLifecycleListener internally,
    // so no field is needed to prevent GC. WidgetsFlutterBinding.ensureInitialized()
    // is guaranteed to have run in main() before the component is created.
    AppLifecycleListener(
      onExitRequested: () => answerExitRequest(mayQuit: _mayQuit, closeWorker: instance.close),
    );
  }
}
