// SPDX-License-Identifier: MIT

import 'package:inject_annotation/inject_annotation.dart';

import 'isolate.dart';

/// DI module that provides the [ZanshinWorker] singleton.
///
/// The module starts the worker asynchronously via `@asynchronous`; the
/// generator awaits the future and wires the resolved instance before
/// returning the component. The component `create` becomes `async` as a result.
///
/// Shutdown wiring (hooking [ZanshinWorker.close] into the host application's
/// lifecycle) lives in the app layer, not here — this package is Flutter-free so
/// it stays testable under `dart test`.
@module
class WorkerModule {
  /// Start and provide the single long-running worker isolate (AR-AD-4).
  ///
  /// `@asynchronous` tells the generator to await [ZanshinWorker.start] and
  /// wire the resolved [ZanshinWorker] instance into the graph.
  @provides
  @singleton
  @asynchronous
  Future<ZanshinWorker> worker() => ZanshinWorker.start();
}
