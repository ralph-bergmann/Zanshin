// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:zanshin_settings/zanshin_settings.dart';

import 'graph_layout.dart';
import 'graph_metrics.dart';
import 'graph_ports.dart';
import 'graph_view_model.dart';

/// The graph's View options as app-global preferences (Story 10.7 item 7) over `AppSettings.graph`: the view's
/// [options] (Layout, Detailed cards, Card width) and [groupStacks].
///
/// The setters only write the store (a failed write is logged by the store and swallowed: the value stays in memory
/// for the session); every change of the stored values — the setters', or another writer's — notifies and goes to the
/// bound [model]: Layout through `setMode` (re-centres on @), Group stacks through `setStacks` (keeps the anchor).
/// Detailed cards and Card width change only [options]: rows and columns do not depend on the card size.
class GraphPreferences extends ChangeNotifier {
  /// The preferences in [_store].
  GraphPreferences(this._store) : _graph = _store.value.graph {
    _store.addListener(_changed);
  }

  final SettingsStore _store;
  GraphSettings _graph;

  /// The card width step of the slider.
  static const double cardWidthStep = 10;

  /// The layout mode.
  GraphMode get layout => switch (_graph.layout) {
    GraphLayoutSetting.free => GraphMode.free,
    GraphLayoutSetting.compact => GraphMode.compact,
  };

  /// Whether linear runs group into stacks.
  bool get groupStacks => _graph.groupStacks;

  /// The view's options; the stored width clamped to 160–400 and snapped to [cardWidthStep].
  GraphViewOptions get options =>
      GraphViewOptions(layout: layout, detailedCards: _graph.detailedCards, cardWidth: snapCardWidth(_graph.cardWidth));

  /// [width] clamped to 160–400 and snapped to [cardWidthStep]; a non-finite width (a hand-edited file) reads as 240.
  static double snapCardWidth(double width) {
    final double finite = width.isFinite ? width : const GraphSettings().cardWidth;
    return ((finite / cardWidthStep).round() * cardWidthStep).clamp(
      GraphMetrics.minCardWidth,
      GraphMetrics.maxCardWidth,
    );
  }

  /// Initialises [model] on [source] with the stored layout and Group stacks in its first request, and [stackStore]'s
  /// toggles (Story 10.17), and binds it as [model].
  void init(
    GraphViewModel model,
    GraphSource source, {
    GraphActions? actions,
    DateTime Function()? clock,
    GraphStackStore? stackStore,
    String? revset,
  }) {
    model.init(
      source,
      actions: actions,
      clock: clock,
      mode: layout,
      stacks: groupStacks,
      stackStore: stackStore,
      revset: revset,
    );
    this.model = model;
  }

  /// The model later Layout and Group stacks changes go to; null for none.
  GraphViewModel? model;

  /// Sets the layout mode.
  void setLayout(GraphMode mode) => _write(
    (g) => g.copyWith(layout: mode == GraphMode.free ? GraphLayoutSetting.free : GraphLayoutSetting.compact),
  );

  /// Sets detailed or compact cards.
  void setDetailedCards(bool detailed) => _write((g) => g.copyWith(detailedCards: detailed));

  /// Sets Group stacks.
  void setGroupStacks(bool stacks) => _write((g) => g.copyWith(groupStacks: stacks));

  /// Sets the card width, clamped and snapped.
  void setCardWidth(double width) => _write((g) => g.copyWith(cardWidth: snapCardWidth(width)));

  void _write(GraphSettings Function(GraphSettings graph) change) => unawaited(
    _store.update((s) => s.copyWith(graph: change(s.graph))).onError<FileSystemException>((_, _) {}),
  );

  void _changed() {
    final GraphSettings graph = _store.value.graph;
    if (graph == _graph) {
      return;
    }
    _graph = graph;
    model
      ?..setMode(layout)
      ..setStacks(groupStacks);
    notifyListeners();
  }

  @override
  void dispose() {
    _store.removeListener(_changed);
    super.dispose();
  }
}
