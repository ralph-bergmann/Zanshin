// SPDX-License-Identifier: MIT

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:freezed_annotation/freezed_annotation.dart' show CheckedFromJsonException;
import 'package:logging/logging.dart';
import 'package:path_provider/path_provider.dart';

import 'model/app_settings.dart';

final _log = Logger('zanshin.settings');
const _encoder = JsonEncoder.withIndent('  ');

/// In-memory cache of [AppSettings] backed by one JSON file.
///
/// The file is read once in [load]; every [update] replaces the cached value,
/// notifies listeners synchronously and persists immediately. The store lives
/// for the app's lifetime, so it has no `dispose`.
class SettingsStore implements ValueListenable<AppSettings> {
  SettingsStore._(this.file, AppSettings initial) : _notifier = ValueNotifier(initial);

  /// The file this store persists to.
  final File file;

  final ValueNotifier<AppSettings> _notifier;
  var _queue = Future<void>.value();

  /// Reads [file].
  ///
  /// A missing file yields defaults without writing anything. An unreadable or
  /// malformed file is moved aside as `<file>.corrupt` (logged at WARNING) and
  /// defaults are used, so nothing is silently destroyed and a hand-edit typo
  /// never blocks app start. Never throws for either case.
  static Future<SettingsStore> load(File file) async {
    if (!file.existsSync()) {
      return SettingsStore._(file, const AppSettings());
    }
    try {
      final Object? decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, Object?>) {
        return await _recover(file, const FormatException('top-level JSON value is not an object'), StackTrace.current);
      }
      return SettingsStore._(file, AppSettings.fromJson(decoded));
    } on FormatException catch (error, stack) {
      return _recover(file, error, stack);
    } on CheckedFromJsonException catch (error, stack) {
      return _recover(file, error, stack);
    } on FileSystemException catch (error, stack) {
      return _recover(file, error, stack);
    }
  }

  /// [load] at the default location `<application support dir>/settings.json`
  /// (macOS: `~/Library/Application Support/<bundle id>/`).
  ///
  /// Errors from path_provider propagate: without a location there is nothing
  /// sensible to fall back to.
  static Future<SettingsStore> open() async {
    final Directory dir = await getApplicationSupportDirectory();
    return load(File('${dir.path}/settings.json'));
  }

  @override
  AppSettings get value => _notifier.value;

  @override
  void addListener(VoidCallback listener) => _notifier.addListener(listener);

  @override
  void removeListener(VoidCallback listener) => _notifier.removeListener(listener);

  /// Applies [change] to [value], notifies listeners synchronously and
  /// persists immediately.
  ///
  /// Completes when the write has finished. A failed write completes with the
  /// error while [value] keeps the new settings. A [change] that returns the
  /// current value is a no-op: no notification, no write.
  Future<void> update(AppSettings Function(AppSettings current) change) {
    final AppSettings next = change(_notifier.value);
    if (next == _notifier.value) {
      return Future<void>.value();
    }
    _notifier.value = next;
    final Future<void> write = _queue.then((_) => _write(next));
    // WHY: keep the chain alive after a failure — the error reaches this
    // update's caller through `write`; later writes must still run.
    _queue = write.catchError((_) {});
    return write;
  }

  static Future<SettingsStore> _recover(File file, Object error, StackTrace stack) async {
    final String name = file.uri.pathSegments.last;
    // WHY: a settings path is user data and the exception may quote the file,
    // so the WARNING carries only the file name; details go to FINE.
    _log
      ..warning('$name is unreadable; backing it up as $name.corrupt and starting with defaults')
      ..fine('settings decode failure', error, stack);
    try {
      await file.rename('${file.path}.corrupt');
    } on FileSystemException catch (renameError, renameStack) {
      _log
        ..warning('could not back up $name; the next write overwrites it')
        ..fine('settings backup failure', renameError, renameStack);
    }
    return SettingsStore._(file, const AppSettings());
  }

  Future<void> _write(AppSettings settings) async {
    final tmp = File('${file.path}.tmp');
    try {
      await file.parent.create(recursive: true);
      await tmp.writeAsString('${_encoder.convert(settings.toJson())}\n', flush: true);
      // WHY: rename is atomic on POSIX — a crash mid-write never leaves a
      // half-written settings.json behind.
      await tmp.rename(file.path);
    } on FileSystemException catch (error, stack) {
      _log
        ..warning('could not write ${file.uri.pathSegments.last}')
        ..fine('settings write failure', error, stack);
      rethrow;
    }
  }
}
