// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin_settings/zanshin_settings.dart';

/// Lets every write queued on [store] reach the disk, writes queued while it waits included, so a teardown can delete
/// the store's folder.
///
/// A write started in a widget test's fake zone advances only when the real event loop gets a turn and the fake
/// microtasks are flushed after it; left alone, its file IO races the folder's deletion. Register this with
/// `addTearDown` after the delete teardown: it then runs first, still before the binding's `postTest`, while
/// [WidgetTester.runAsync] and [WidgetTester.pump] still advance the fake zone.
Future<void> settleSettingsWrites(WidgetTester tester, SettingsStore store) async {
  Future<void> tail;
  do {
    tail = store.settled;
    var done = false;
    unawaited(tail.whenComplete(() => done = true));
    while (!done) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 1)));
      await tester.pump();
    }
    // A finished write can queue the next one, as an `await update(a); await update(b)` chain does.
  } while (!identical(tail, store.settled));
}
