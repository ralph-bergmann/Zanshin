// SPDX-License-Identifier: MIT

import 'dart:ui' show AppExitResponse;

import 'package:flutter/widgets.dart';
import 'package:inject_annotation/inject_annotation.dart';
import 'package:zanshin_core/zanshin_core.dart';

import '../features/window/app_windows.dart';

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

/// Hooks [ZanshinWorker.close] into the Flutter app lifecycle on macOS.
///
/// `onExitRequested` fires when the system *asks* the app to quit — on macOS that is ⌘Q. Closing the last window that
/// keeps the app alive does not reach it: the window registry exits with `AppExitType.required`, which the framework
/// documents as exiting immediately without querying the application. The quit asks the windows' close guards first
/// ([AppWindows.mayClose] through [answerExitRequest], Story 11.12 item 7: 10.22's "Discard changes?"); closing the
/// worker then gives it a chance to release FFI handles before the process exits. On other platforms this is
/// best-effort — the OS reclaims process resources anyway.
@inject
@singleton
class AppExitHandler {
  /// The handler over the app's [_windows] and the boot's [_worker].
  AppExitHandler(this._windows, this._worker);

  final AppWindows _windows;
  final ZanshinWorker _worker;

  /// Kept so a second [start] registers nothing; `WidgetsBinding` holds it as an observer for the app's life.
  AppLifecycleListener? _listener;

  /// Registers the app-lifecycle listener that answers a quit request; a second call registers nothing.
  void start() {
    _listener ??= AppLifecycleListener(
      onExitRequested: () => answerExitRequest(mayQuit: _windows.mayClose, closeWorker: _worker.close),
    );
  }
}
