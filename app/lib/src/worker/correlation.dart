// SPDX-License-Identifier: MIT

import 'dart:async';

import 'responses.dart';

/// Correlates in-flight worker commands with their awaiting callers.
///
/// The main isolate calls [allocateId] + [register] before sending each
/// command; the response listener calls [resolve] (success) or [error]
/// (transport failure) to complete the corresponding [Future]. On worker
/// death [failAll] drains the map so no caller waits forever.
class CommandCorrelator {
  final Map<int, Completer<WorkerResponse>> _pending = {};
  var _nextId = 0;

  /// Allocate a fresh, monotonically increasing command id.
  int allocateId() => _nextId++;

  /// Register [id] and return a [Future] that completes when the worker
  /// responds to that command.
  Future<WorkerResponse> register(int id) {
    final completer = Completer<WorkerResponse>();
    _pending[id] = completer;
    return completer.future;
  }

  /// Complete the [Future] registered under [id] with [response].
  void resolve(int id, WorkerResponse response) {
    _pending.remove(id)?.complete(response);
  }

  /// Complete the [Future] registered under [id] with an error.
  void error(int id, Object e, [StackTrace? st]) {
    _pending.remove(id)?.completeError(e, st);
  }

  /// Complete every pending [Future] with [e] and clear the map.
  ///
  /// Used when the worker dies so no caller waits forever (AC-10).
  void failAll(Object e, [StackTrace? st]) {
    final entries = List<MapEntry<int, Completer<WorkerResponse>>>.of(
      _pending.entries,
    );
    _pending.clear();
    for (final entry in entries) {
      entry.value.completeError(e, st);
    }
  }
}
