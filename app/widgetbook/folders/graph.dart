// SPDX-License-Identifier: MIT

import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:widgetbook/widgetbook.dart';
import 'package:zanshin/src/features/graph/day_axis.dart';
import 'package:zanshin/src/features/graph/graph_layout.dart';
import 'package:zanshin/src/features/graph/graph_metrics.dart';
import 'package:zanshin/src/features/graph/graph_viewport.dart';
import 'package:zanshin/src/features/graph/layout_invariants.dart';
import 'package:zanshin/src/features/graph/recorded_graph_layout.dart';
import 'package:zanshin/src/features/graph/vertical_layout.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

import '../graph/graph_recordings.g.dart';
import '../graph/placeholder_card.dart';
import '../graph/synthetic_layout.dart';

/// The "Graph" folder (Story 10.1, decision 16.30): the fake-data host of every Epic 10 story. "Viewport / Recording"
/// shows the recorded layouts of the design sample and medium-narrow, "Viewport / Scale" the synthetic 10k–100k
/// fixtures; every `GraphViewOptions` field is a knob, and the left and right insets stand in for the floating chrome.
final graphFolder = WidgetbookFolder(
  name: 'Graph',
  children: <WidgetbookNode>[
    WidgetbookComponent(
      name: 'Viewport',
      useCases: <WidgetbookUseCase>[
        WidgetbookUseCase(
          name: 'Recording',
          builder: (context) {
            final String sample = context.knobs.object.dropdown(
              label: 'recording',
              options: const <String>['design-default', 'design-all', 'design-cli-default', 'medium-narrow'],
            );
            final GraphViewOptions options = _options(context);
            return _GraphDemo(
              layout: recordedLayout(sample, options),
              options: options,
              insets: _insets(context),
              nowMs: recordedNowMs(sample),
            );
          },
        ),
        WidgetbookUseCase(
          name: 'Scale',
          builder: (context) {
            final int size = context.knobs.object.dropdown(
              label: 'nodes',
              options: syntheticSizes,
              labelBuilder: (value) => '${value ~/ 1000}k',
            );
            // No lane-order knob: the synthetic generator writes columns directly and has no lane order.
            final GraphViewOptions options = _options(context, laneOrder: false);
            final RecordedGraphLayout layout = _fixture(
              'synthetic $size ${options.layout.name}',
              () => syntheticLayout(size, free: options.layout == GraphMode.free),
            );
            return _GraphDemo(
              layout: layout,
              options: options,
              insets: _insets(context),
              nowMs: _syntheticNowMs(layout),
            );
          },
        ),
      ],
    ),
  ],
);

GraphViewOptions _options(BuildContext context, {bool laneOrder = true}) => GraphViewOptions(
  layout: context.knobs.object.dropdown(
    label: 'layout',
    options: GraphMode.values,
    labelBuilder: (value) => value.name,
  ),
  laneOrder: laneOrder
      ? context.knobs.object.dropdown(
          label: 'lane order',
          options: GraphLaneOrder.values,
          labelBuilder: (value) => value.name,
        )
      : GraphLaneOrder.compact,
  detailedCards: context.knobs.boolean(label: 'detailed cards', initialValue: true),
  cardWidth: context.knobs.double.slider(
    label: 'card width',
    initialValue: 240,
    min: GraphMetrics.minCardWidth,
    max: GraphMetrics.maxCardWidth,
  ),
);

EdgeInsets _insets(BuildContext context) => EdgeInsets.only(
  // 76: the design's rail inset.
  left: context.knobs.double.slider(label: 'left inset', initialValue: 76, max: 480),
  right: context.knobs.double.slider(label: 'right inset', initialValue: 0, max: 480),
);

/// The recording of [sample] that [options] ask for.
RecordedGraphLayout recordedLayout(String sample, GraphViewOptions options) {
  final name = '$sample ${options.layout.name} ${options.laneOrder.name}';
  return _fixture(name, () {
    final (String input, String output) = graphRecordings[name]!;
    return RecordedGraphLayout.fromSpec(input, output);
  });
}

final _fixtures = <String, RecordedGraphLayout>{};

/// Each fixture is built once, and checked once in debug builds: a fixture that fails a hard invariant is a recording
/// or generator bug, never patched in the view.
RecordedGraphLayout _fixture(String name, RecordedGraphLayout Function() build) => _fixtures.putIfAbsent(name, () {
  final RecordedGraphLayout layout = build();
  assert(() {
    final List<LayoutViolation> violations = checkLayoutInvariants(layout);
    if (violations.isNotEmpty) {
      throw StateError('$name fails the layout invariants: ${violations.take(5).join('; ')}');
    }
    return true;
  }());
  return layout;
});

final _nowMs = <String, int>{};

/// The recording input's `now_ms` for [sample] (every mode of a sample shares one input).
int recordedNowMs(String sample) => _nowMs.putIfAbsent(sample, () {
  final (String input, _) = graphRecordings['$sample free compact']!;
  return (jsonDecode(input) as Map<String, Object?>)['now_ms']! as int;
});

/// A synthetic layout's "now": noon of its newest day (0 without days).
int _syntheticNowMs(GraphLayout layout) =>
    layout.bucketCount == 0 ? 0 : layout.bucketValueOf(layout.bucketCount - 1) + 12 * 3600000;

/// A viewport over [layout] with placeholder cards and Free's day axis, over the window canvas; it owns its scroll
/// controllers and its day-axis painter.
class _GraphDemo extends StatefulWidget {
  const _GraphDemo({required this.layout, required this.options, required this.insets, required this.nowMs});

  final GraphLayout layout;
  final GraphViewOptions options;
  final EdgeInsets insets;
  final int nowMs;

  @override
  State<_GraphDemo> createState() => _GraphDemoState();
}

class _GraphDemoState extends State<_GraphDemo> {
  final _vertical = ScrollController();
  final _horizontal = ScrollController();
  VerticalLayout? _rows;
  GraphDayAxisPainter? _axis;
  VerticalLayout? _axisRows;

  @override
  void dispose() {
    _axis?.dispose();
    _vertical.dispose();
    _horizontal.dispose();
    super.dispose();
  }

  // A tear-off of this state's method is equal across builds, so the delegate rebuilds no card.
  Widget _card(BuildContext context, int node) => GraphPlaceholderCard(layout: widget.layout, node: node);

  /// The rows, built once per layout and remapped once per metrics change.
  VerticalLayout _rowsFor(GraphMetrics metrics) {
    final VerticalLayout? rows = _rows;
    if (rows != null && rows.layout == widget.layout) {
      return rows.metrics == metrics ? rows : _rows = rows.withMetrics(metrics);
    }
    return _rows = UniformRows(widget.layout, metrics);
  }

  /// The day-axis painter, recreated (the old one disposed) when the rows, the theme or "now" change.
  GraphDayAxisPainter _axisFor(VerticalLayout rows, GraphTheme theme) {
    final GraphDayAxisPainter? axis = _axis;
    if (axis != null && identical(_axisRows, rows) && axis.theme == theme && axis.nowMs == widget.nowMs) {
      return axis;
    }
    axis?.dispose();
    _axisRows = rows;
    return _axis = GraphDayAxisPainter(
      axis: GraphDayAxis.of(widget.layout, rows),
      theme: theme,
      nowMs: widget.nowMs,
      utcOffsetMinutes: widget.layout.utcOffsetMinutes,
    );
  }

  @override
  Widget build(BuildContext context) {
    final metrics = GraphMetrics.fromOptions(widget.options);
    final VerticalLayout rows = _rowsFor(metrics);
    final GraphDayAxisPainter axis = _axisFor(rows, GraphTheme.of(context));
    final double leftInset = widget.insets.left;
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        const ZsCanvas(),
        GraphViewport(
          layout: widget.layout,
          metrics: metrics,
          verticalLayout: rows,
          cardBuilder: _card,
          verticalController: _vertical,
          horizontalController: _horizontal,
          insets: widget.insets,
          paintBackground: axis.paintGuides,
          paintOverlay: (context, origin, visible) => axis.paintLabels(context, origin, visible, leftInset: leftInset),
        ),
      ],
    );
  }
}
