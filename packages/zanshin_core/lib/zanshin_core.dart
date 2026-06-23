// SPDX-License-Identifier: MIT

/// Public API of the Zanshin Rust↔Dart bridge.
///
/// The app (and any other consumer) imports `package:zanshin_core/zanshin_core.dart`
/// rather than reaching into `src/` directly. Internal files stay under `src/`.
library;

export 'src/ffi/diagnostics.dart' show GetDiagnostics, ZanshinDiagnosticsModule;
export 'src/ffi/log_forwarder.dart' show forwardLogRecord, initLogForwarding;
export 'src/ffi/zanshin_version.dart' show ZanshinFfiModule, ZanshinFfiVersion;
export 'src/worker/isolate.dart' show ZanshinWorker;
export 'src/worker/worker_module.dart' show WorkerModule;
