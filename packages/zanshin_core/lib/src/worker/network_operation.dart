// SPDX-License-Identifier: MIT

import 'events.dart';

/// One running network call — a fetch, clone or push (Story 9.52).
///
/// The worker runs the call on a helper isolate, so [progress] delivers the
/// call's [ProgressEvent]s while [result] is still pending, and [cancel] can
/// stop it: a cancelled fetch or clone refuses with `jj.cancelled`
/// (`ZanshinFfiException`), a cancelled push reports it as data
/// (`GitPushResult.failure` with `PushFailureKind.cancelled`). A cancel that
/// arrives after the call's last checkpoint changes nothing — the call ends
/// with its normal result.
final class NetworkOperation<T> {
  /// Wraps a running call: its [result], its [progress] and the request that
  /// cancels it.
  NetworkOperation({required this.result, required this.progress, required this._cancel});

  /// The call's outcome — the same payload and refusals the verb has always
  /// had.
  final Future<T> result;

  /// This call's progress: `ZanshinWorker.events` filtered by the call's
  /// handle id and operation (`"fetch"`, `"clone"`, `"push"`). Single
  /// subscription; it closes when [result] completes. A push reports few or no
  /// events (git reports a push's progress mostly as text).
  final Stream<ProgressEvent> progress;

  final Future<void> Function() _cancel;

  /// Asks the worker to cancel the call; completes once the worker has
  /// processed the request. A no-op after [result] completed or after the
  /// worker was closed.
  Future<void> cancel() => _cancel();
}
