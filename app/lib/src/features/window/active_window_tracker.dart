// SPDX-License-Identifier: MIT

import 'dart:ui' show ViewFocusEvent, ViewFocusState;

import 'package:flutter/widgets.dart';
import 'package:inject_annotation/inject_annotation.dart';

/// Which Zanshin window is key, for the inactive delta every window root applies (DS tokens/inactive.css;
/// readme.md:194; Story 11.12 item 5).
///
/// The engine reports a window becoming key as its view gaining focus and resigning key as losing it
/// (`windowDidBecomeKey` / `windowDidResignKey` → `didChangeViewFocus`), so this observer follows those events:
/// a focused view is the key window, an unfocused key view leaves none (Zanshin went to the background, or a window
/// of another app took over). Before the first event every window counts as active (Claude's proposal), so a window
/// never starts out dimmed.
///
/// One instance for the app (the DI graph's singleton): it registers with the [WidgetsBinding] when made and leaves
/// it on [dispose].
@inject
@singleton
class ActiveWindowTracker extends ChangeNotifier with WidgetsBindingObserver {
  /// Follows the binding's view focus events from now on.
  ActiveWindowTracker() {
    WidgetsBinding.instance.addObserver(this);
  }

  var _seen = false;
  int? _keyView;

  /// Whether the window of the Flutter view [viewId] is the key window (or no focus event has arrived yet).
  bool isActive(int viewId) => !_seen || _keyView == viewId;

  @override
  void didChangeViewFocus(ViewFocusEvent event) {
    final int? key = switch (event.state) {
      ViewFocusState.focused => event.viewId,
      // Another view's unfocus says nothing about the key window, unless none is known yet.
      ViewFocusState.unfocused when _keyView != event.viewId && _seen => _keyView,
      ViewFocusState.unfocused => null,
    };
    if (_seen && key == _keyView) {
      return;
    }
    _seen = true;
    _keyView = key;
    notifyListeners();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
