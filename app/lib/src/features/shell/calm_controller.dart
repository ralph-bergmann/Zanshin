// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

/// A calm-scrolling phase as the chrome reads it.
@immutable
class CalmPhase {
  /// A phase; [rest] is none.
  const CalmPhase({this.calm = false, this.inspectorPinned = false});

  /// No phase: everything at rest.
  static const rest = CalmPhase();

  /// Whether the chrome steps aside.
  final bool calm;

  /// Whether the inspector stays for this phase: a text field inside it had focus as the phase started.
  final bool inspectorPinned;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is CalmPhase && other.calm == calm && other.inspectorPinned == inspectorPinned;

  @override
  int get hashCode => Object.hash(calm, inspectorPinned);

  @override
  String toString() => 'CalmPhase(calm: $calm, inspectorPinned: $inspectorPinned)';
}

/// A reason calm scrolling must not start, held until [release] (an open preview, flyout, menu, popover or sheet of
/// this window, an edge or item drag). Releasing twice is harmless.
class CalmHold {
  /// A hold whose callback runs once, on the first [release].
  CalmHold(this._onRelease);

  final VoidCallback _onRelease;
  var _released = false;

  /// Whether [release] ran.
  bool get released => _released;

  /// Ends the hold.
  void release() {
    if (_released) {
      return;
    }
    _released = true;
    _onRelease();
  }
}

/// Calm scrolling's state machine (decisions 16.4, 16.45; epics.md Story 11.3 item 8; Story 10.5 item 15; DS
/// tokens/motion.css:63-67): while the user scrolls the graph, the chrome steps aside, and it returns one wait after
/// the last scroll.
///
/// - [addUserScroll] counts user scrolling only — the shell's listener the wheel and the trackpad's pan, 10.1 and
///   10.16 pans, flings and the minimap through `ShellScope.of(context).reportUserScroll`; a programmatic scroll is
///   never reported.
/// - Counting is ignored while a [hold] exists or [hideControls] is off. Each counted event adds its amount and
///   restarts the `--delay-calm-return` wait; once the sum passes 30 px the phase starts. When the wait runs out the
///   phase ends and the sum starts again from 0. A hold taken during a phase ends it at once (Ralph 2026-11-01: the
///   chrome returns, so a menu opened mid-phase opens at full opacity).
/// - At the start of a phase [decideInspectorPinned] fixes [CalmPhase.inspectorPinned] for the whole phase.
///
/// The waits are `ZsMotion.full`'s: reduce motion leaves them unchanged (DS tokens/motion.css:70-71).
class CalmController extends ChangeNotifier implements ValueListenable<CalmPhase> {
  /// A controller, gated by [hideControls].
  CalmController({this._hideControls = true, this.decideInspectorPinned});

  /// The scrolled distance a phase needs, exclusive (the floating export's graph-view.jsx:972, `c.acc > 30`; epics.md
  /// Story 11.3 item 8).
  static const double threshold = 30;

  /// Whether a text field inside the inspector has focus, asked once as a phase starts.
  bool Function()? decideInspectorPinned;

  CalmPhase _value = CalmPhase.rest;
  var _sum = 0.0;
  var _holds = 0;
  bool _hideControls;
  Timer? _return;

  @override
  CalmPhase get value => _value;

  /// The preference "Hide controls"; while it is off nothing steps aside, and switching it off ends a phase.
  bool get hideControls => _hideControls;
  set hideControls(bool value) {
    if (value == _hideControls) {
      return;
    }
    _hideControls = value;
    if (!value) {
      _end();
    }
  }

  /// Whether a hold blocks counting.
  bool get held => _holds > 0;

  /// Counts [amount] pixels of user scrolling.
  void addUserScroll(double amount) {
    if (_holds > 0 || !_hideControls || amount <= 0) {
      return;
    }
    _sum += amount;
    if (!_value.calm && _sum > threshold) {
      _value = CalmPhase(calm: true, inspectorPinned: decideInspectorPinned?.call() ?? false);
      notifyListeners();
    }
    _return?.cancel();
    _return = Timer(ZsMotion.full.delayCalmReturn, _end);
  }

  /// Ends a running phase and blocks counting until the returned hold is released.
  CalmHold hold() {
    _holds++;
    if (_value.calm) {
      _end();
    }
    return CalmHold(() => _holds--);
  }

  void _end() {
    _return?.cancel();
    _return = null;
    _sum = 0;
    if (_value.calm) {
      _value = CalmPhase.rest;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _return?.cancel();
    super.dispose();
  }
}
