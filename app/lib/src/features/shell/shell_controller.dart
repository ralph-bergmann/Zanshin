// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

import 'calm_controller.dart';
import 'shell_layout.dart';

/// One item of the rail (epics.md Story 11.3 item 4; Claude's proposal for the shape): Bookmarks (10.14) and the
/// Undo Timeline (11.9) supply one each.
@immutable
class ShellRailItem {
  /// An item.
  const ShellRailItem({
    required this.id,
    required this.label,
    required this.icon,
    required this.preview,
    required this.panel,
    this.count,
  });

  /// The item's key; the rail button's identifier is `rail-<id>`.
  final String id;

  /// The button's name and the preview's and the panel's title.
  final String label;

  /// A `ZI` glyph.
  final String icon;

  /// The count in the preview's header ("12", "48 ops"), or null.
  final String? count;

  /// The preview's body.
  final Widget preview;

  /// The pinned panel's body.
  final Widget panel;
}

/// The floating shell's state (epics.md Story 11.3; Design Notes of spec-11-3): the pinned rail item, the hover
/// preview, the flyout, the holds that block calm scrolling, the remembered widths and the [calm] state machine.
///
/// **Preview** (DS ui_kits/desktop/chrome.jsx:140-157; Callout.prompt.md:9-11). [railEnter] cancels the waits; on the
/// pinned item it closes the preview and stops; with a preview open it switches at once; else the preview opens
/// after `--delay-callout`. [railExit] and [previewExit] close it after `--delay-callout-out`, [previewEnter] cancels
/// that. Nothing opens while the window is [inactive], during an edge or item drag, or during a calm phase; a phase
/// closes an open preview outright. An open preview holds calm.
///
/// **Pins and the flyout** (decision 16.23; Claude's proposal for the detail). [activate] toggles the pin of one item
/// at a time and closes the preview. Without room for the panel (the layout would collapse it), a click on an
/// unpinned item pins it and shows it as the flyout; a click on the pinned item while collapsed shows the flyout; a
/// click on it while the flyout shows closes the flyout and unpins. [closeFlyout] (Esc, a click outside) keeps the
/// pin. An open flyout holds calm. Unpinning clears the collapse.
///
/// **Widths.** The remembered widths live here; a drag changes them live, and the `on…Committed` callbacks run once
/// per release, reset and key step — the view model persists them.
///
/// The waits are `ZsMotion.full`'s (reduce motion leaves them unchanged, DS tokens/motion.css:70-71).
class ShellController extends ChangeNotifier {
  /// A controller over the remembered widths [panelWidth] and [inspectorWidth], gated by [hideControls].
  ShellController({
    this._panelWidth = 300,
    this._inspectorWidth = 460,
    bool hideControls = true,
    this.onPanelWidthCommitted,
    this.onInspectorWidthCommitted,
  }) : calm = CalmController(hideControls: hideControls) {
    calm.addListener(_calmChanged);
  }

  /// Calm scrolling's state machine.
  final CalmController calm;

  /// Runs with the panel width a drag, reset or key step ended at.
  ValueChanged<double>? onPanelWidthCommitted;

  /// Runs with the inspector width a drag, reset or key step ended at.
  ValueChanged<double>? onInspectorWidthCommitted;

  double _panelWidth;
  double _inspectorWidth;
  String? _pinnedId;
  String? _previewId;
  var _flyoutOpen = false;
  var _collapsed = false;
  var _inactive = false;
  var _edgeDragging = false;
  var _itemDrags = 0;
  Timer? _opening;
  Timer? _closing;
  CalmHold? _previewHold;
  CalmHold? _flyoutHold;
  CalmHold? _edgeHold;

  /// The inputs of the last [layoutFor], for the flyout's probe.
  ({double width, ZsMetrics metrics, bool inspectorOpen, bool minimapShown})? _inputs;

  /// The pinned item's id, or null.
  String? get pinnedId => _pinnedId;

  /// The item whose preview shows, or null.
  String? get previewId => _previewId;

  /// Whether the pinned item shows as the rail's flyout.
  bool get flyoutOpen => _flyoutOpen;

  /// Whether the last layout collapsed the pinned panel.
  bool get collapsed => _collapsed;

  /// Whether an item drag (10.10's card drag, 10.27's hunk lift) runs: the edges are inert.
  bool get itemDragging => _itemDrags > 0;

  /// Whether a resize edge is being dragged.
  bool get edgeDragging => _edgeDragging;

  /// The remembered panel width.
  double get panelWidth => _panelWidth;
  set panelWidth(double value) {
    if (value != _panelWidth) {
      _panelWidth = value;
      notifyListeners();
    }
  }

  /// The remembered inspector width.
  double get inspectorWidth => _inspectorWidth;
  set inspectorWidth(double value) {
    if (value != _inspectorWidth) {
      _inspectorWidth = value;
      notifyListeners();
    }
  }

  /// The preference "Hide controls" (see [CalmController.hideControls]).
  bool get hideControls => calm.hideControls;
  set hideControls(bool value) => calm.hideControls = value;

  /// Whether the window is not key: no preview opens, and turning inactive closes an open one.
  ///
  /// It does not notify — the shell sets it while its dependencies change and rebuilds anyway.
  bool get inactive => _inactive;
  set inactive(bool value) {
    if (value == _inactive) {
      return;
    }
    _inactive = value;
    if (value) {
      _cancelWaits();
      _showPreview(null, notify: false);
    }
  }

  /// The layout of a [windowWidth] wide window, with the collapse remembered for the next one; a flyout closes once
  /// the panel has room again (it then shows pinned).
  ShellLayout layoutFor({
    required double windowWidth,
    required ZsMetrics metrics,
    required bool inspectorOpen,
    required bool minimapShown,
  }) {
    _inputs = (width: windowWidth, metrics: metrics, inspectorOpen: inspectorOpen, minimapShown: minimapShown);
    final layout = ShellLayout.resolve(
      windowWidth: windowWidth,
      metrics: metrics,
      pinned: _pinnedId != null,
      inspectorOpen: inspectorOpen,
      minimapShown: minimapShown,
      rememberedPanel: _panelWidth,
      rememberedInspector: _inspectorWidth,
      wasCollapsed: _collapsed,
    );
    _collapsed = layout.collapsed;
    if (!_collapsed && _flyoutOpen) {
      _setFlyout(false);
    }
    return layout;
  }

  /// The pointer entered rail button [id].
  void railEnter(String id) {
    _cancelWaits();
    if (_inactive || _edgeDragging || _itemDrags > 0 || calm.value.calm) {
      return;
    }
    if (id == _pinnedId) {
      _showPreview(null);
    } else if (_previewId != null) {
      _showPreview(id);
    } else {
      _opening = Timer(ZsMotion.full.delayCallout, () => _showPreview(id));
    }
  }

  /// The pointer left a rail button.
  void railExit() {
    _cancelWaits();
    if (_previewId != null) {
      _closing = Timer(ZsMotion.full.delayCalloutOut, () => _showPreview(null));
    }
  }

  /// The pointer entered the preview.
  void previewEnter() => _cancelWaits();

  /// The pointer left the preview.
  void previewExit() => railExit();

  /// Closes the preview at once.
  void closePreview() {
    _cancelWaits();
    _showPreview(null);
  }

  /// A click (↩, Space, VoiceOver's press) on rail button [id]: toggles its pin (see the class doc).
  void activate(String id) {
    _cancelWaits();
    _showPreview(null, notify: false);
    if (id == _pinnedId) {
      if (_flyoutOpen) {
        _setFlyout(false);
        _clearPin();
      } else if (_collapsed) {
        _setFlyout(true);
      } else {
        _clearPin();
      }
    } else {
      final bool noRoom = _wouldCollapse();
      _pinnedId = id;
      _setFlyout(noRoom);
    }
    notifyListeners();
  }

  /// Unpins the pinned item (the panel's close button).
  void unpin() {
    if (_pinnedId == null) {
      return;
    }
    _setFlyout(false);
    _clearPin();
    notifyListeners();
  }

  /// Closes the flyout and keeps the pin (Esc, a click outside it).
  void closeFlyout() {
    if (_flyoutOpen) {
      _setFlyout(false);
      notifyListeners();
    }
  }

  /// Esc: closes the preview, else the flyout; false when neither was open.
  bool handleEscape() {
    if (_previewId != null) {
      closePreview();
      return true;
    }
    if (_flyoutOpen) {
      closeFlyout();
      return true;
    }
    return false;
  }

  /// A menu, popover or sheet of this window opened: calm waits until the hold is released.
  CalmHold openSurface() => calm.hold();

  /// An item drag starts (10.10, 10.27): the edges turn inert, previews close, calm waits — until the hold is
  /// released.
  CalmHold startItemDrag() {
    final CalmHold held = calm.hold();
    _itemDrags++;
    _cancelWaits();
    _showPreview(null, notify: false);
    notifyListeners();
    return CalmHold(() {
      held.release();
      _itemDrags--;
      notifyListeners();
    });
  }

  /// [amount] pixels of user scrolling that do not pass the shell's own listener (pans, flings, the minimap).
  void reportUserScroll(double amount) => calm.addUserScroll(amount);

  /// A resize edge's drag started: no preview, no calm.
  void edgeDragStarted() {
    _edgeHold?.release();
    _edgeHold = calm.hold();
    _edgeDragging = true;
    _cancelWaits();
    _showPreview(null, notify: false);
    notifyListeners();
  }

  /// A resize edge's drag ended.
  void edgeDragEnded() {
    _edgeHold?.release();
    _edgeHold = null;
    if (_edgeDragging) {
      _edgeDragging = false;
      notifyListeners();
    }
  }

  /// Sets the remembered panel width to [width] and reports it as committed.
  void commitPanelWidth(double width) {
    panelWidth = width;
    onPanelWidthCommitted?.call(width);
  }

  /// Sets the remembered inspector width to [width] and reports it as committed.
  void commitInspectorWidth(double width) {
    inspectorWidth = width;
    onInspectorWidthCommitted?.call(width);
  }

  bool _wouldCollapse() {
    final ({double width, ZsMetrics metrics, bool inspectorOpen, bool minimapShown})? inputs = _inputs;
    if (inputs == null) {
      return false;
    }
    return ShellLayout.resolve(
      windowWidth: inputs.width,
      metrics: inputs.metrics,
      pinned: true,
      inspectorOpen: inputs.inspectorOpen,
      minimapShown: inputs.minimapShown,
      rememberedPanel: _panelWidth,
      rememberedInspector: _inspectorWidth,
      wasCollapsed: _pinnedId != null && _collapsed,
    ).collapsed;
  }

  void _clearPin() {
    _pinnedId = null;
    _collapsed = false;
  }

  void _setFlyout(bool open) {
    _flyoutOpen = open;
    if (open) {
      _flyoutHold ??= calm.hold();
    } else {
      _flyoutHold?.release();
      _flyoutHold = null;
    }
  }

  void _showPreview(String? id, {bool notify = true}) {
    if (id == _previewId) {
      return;
    }
    _previewId = id;
    if (id != null) {
      _previewHold ??= calm.hold();
    } else {
      _previewHold?.release();
      _previewHold = null;
    }
    if (notify) {
      notifyListeners();
    }
  }

  void _cancelWaits() {
    _opening?.cancel();
    _closing?.cancel();
    _opening = null;
    _closing = null;
  }

  void _calmChanged() {
    if (calm.value.calm) {
      _cancelWaits();
      _showPreview(null);
    }
  }

  @override
  void dispose() {
    _cancelWaits();
    calm
      ..removeListener(_calmChanged)
      ..dispose();
    super.dispose();
  }
}
