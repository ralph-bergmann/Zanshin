// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:material_ui/material_ui.dart' show Theme, ThemeData;
import 'package:widgetbook/widgetbook.dart';
import 'package:zanshin/src/features/graph/at_pill.dart';
import 'package:zanshin/src/features/graph/graph_canvas.dart';
import 'package:zanshin/src/features/graph/graph_card.dart';
import 'package:zanshin/src/features/graph/graph_controls.dart';
import 'package:zanshin/src/features/graph/graph_drag.dart';
import 'package:zanshin/src/features/graph/graph_drop_menu.dart';
import 'package:zanshin/src/features/graph/graph_inspector.dart';
import 'package:zanshin/src/features/graph/graph_layout.dart';
import 'package:zanshin/src/features/graph/graph_metrics.dart';
import 'package:zanshin/src/features/graph/graph_peek.dart';
import 'package:zanshin/src/features/graph/graph_ports.dart';
import 'package:zanshin/src/features/graph/graph_preferences.dart';
import 'package:zanshin/src/features/graph/graph_search_controller.dart';
import 'package:zanshin/src/features/graph/graph_search_field.dart';
import 'package:zanshin/src/features/graph/graph_search_store.dart';
import 'package:zanshin/src/features/graph/graph_stack_store.dart';
import 'package:zanshin/src/features/graph/graph_toasts.dart';
import 'package:zanshin/src/features/graph/graph_view.dart';
import 'package:zanshin/src/features/graph/graph_view_model.dart';
import 'package:zanshin/src/features/graph/graph_viewport.dart';
import 'package:zanshin/src/features/graph/hatch_swatch.dart';
import 'package:zanshin/src/features/graph/inspector_diff.dart';
import 'package:zanshin/src/features/graph/inspector_viewed_store.dart';
import 'package:zanshin/src/features/graph/layout_invariants.dart';
import 'package:zanshin/src/features/graph/recorded_graph_layout.dart';
import 'package:zanshin/src/features/graph/stale_notice.dart';
import 'package:zanshin/src/features/shell/floating_shell.dart';
import 'package:zanshin/src/features/shell/shell_controller.dart';
import 'package:zanshin/src/features/shell/shell_toast.dart';
import 'package:zanshin/src/features/sync/sync_island.dart';
import 'package:zanshin_core/zanshin_core.dart'
    show
        ActionOutcome,
        ActionStatus,
        Change,
        ChangeActions,
        ConflictState,
        Diff,
        FileChange,
        FileChangeKind,
        FileDiff,
        Hunk,
        HunkKey,
        HunkLine,
        HunkLineKind,
        MutationResult,
        ShowEntry,
        Signature,
        SquashPlan,
        ZanshinWarning;
import 'package:zanshin_settings/zanshin_settings.dart' show DiffLayoutSetting, SettingsStore;
import 'package:zanshin_ui/zanshin_ui.dart';

import '../graph/fake_content.dart';
import '../graph/fake_graph_search_source.dart';
import '../graph/fake_graph_source.dart';
import '../graph/graph_recordings.g.dart';
import '../graph/graph_stack_recordings.g.dart';
import '../graph/stack_recordings.dart';
import '../graph/synthetic_layout.dart';
import 'projects.dart' show demoCapsule;

/// The "Graph" folder (Story 10.1, decision 16.30): the fake-data host of every Epic 10 story. "Viewport / Recording"
/// shows the recorded layouts of the design sample and medium-narrow, "Viewport / Scale" the synthetic 10k–100k
/// fixtures, both with fake content (Story 10.3); every `GraphViewOptions` field is a knob, and the left and right
/// insets stand in for the floating chrome; its design-default recording shows the hidden-history marks, with the gap
/// clearance as a knob (Story 10.19). "Viewport / View model" drives a `GraphViewModel` on a fake source over the
/// recordings, with the stale notice and the @ pill over it (Stories 10.5, 10.6). "Viewport / Operation" lands one
/// layout of a pair after the other with a `GraphTransition` (Story 10.20; slow it with the TimeDilation addon).
/// "Card / States" shows one commit card per state (Story 10.3); "Peek / Open" the commit callout and "@ pill /
/// Directions" the pill (Story 10.6); "Stale notice / Variants" the notice with its action, busy, and with Copy (Story
/// 10.5). "Floating shell / Controls" hosts the graph's top-bar controls in the floating shell (Story 10.7) and the
/// inspector of the selection, a mutable change selected when it opens (Story 10.8). "Minimap / Recording" shows the
/// minimap in the floating shell over the view-model demo's graph (Story 10.16). "Drop menu / Open" and "Inspector diff /
/// Hunk selection" hold the drag's menu and a partly picked file still for a look (Stories 10.10, 10.26).
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
            // Story 10.19: the visible line a gap marker keeps to every card, bend, crossing and mark.
            final double clearance = context.knobs.double.slider(
              label: 'gap clearance',
              initialValue: 12,
              min: 4,
              max: 24,
              divisions: 20,
            );
            return _withClearance(
              clearance,
              _GraphDemo(
                layout: recordedLayout(sample, options),
                options: options,
                insets: _insets(context),
                nowMs: recordedNowMs(sample),
              ),
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
        WidgetbookUseCase(
          name: 'View model',
          builder: (context) {
            final String revset = context.knobs.object.dropdown(
              label: 'revset',
              options: const <String>['jj log', 'all()'],
            );
            final String stale = context.knobs.object.dropdown(
              label: 'stale cause',
              options: const <String>['none', 'stale', 'sibling_operation', 'operation_not_found'],
            );
            return _ViewModelDemo(
              key: _viewModelDemoKeys[WidgetbookState.of(context)] ??= GlobalKey<_ViewModelDemoState>(),
              revset: revset,
              stacks: context.knobs.boolean(label: 'group stacks', initialValue: true),
              options: _options(context),
              insets: _insets(context),
              staleCause: stale == 'none' ? null : stale,
            );
          },
        ),
        WidgetbookUseCase(
          name: 'Operation',
          builder: (context) {
            final String pair = context.knobs.object.dropdown(label: 'pair', options: _operationPairs);
            final synthetic = pair == _operationPairs.last;
            final GraphViewOptions options = _options(context, laneOrder: !synthetic);
            final free = options.layout == GraphMode.free;
            final String sample = pair.split(' ').first;
            final (GraphLayout from, GraphLayout to) = synthetic
                ? (
                    _fixture('synthetic 10000 ${options.layout.name}', () => syntheticLayout(10000, free: free)),
                    _fixture('synthetic 10001 ${options.layout.name}', () => syntheticLayout(10001, free: free)),
                  )
                : (recordedLayout(sample, options), recordedLayout('design-all', options));
            final int nowMs = synthetic ? _syntheticNowMs(from) : recordedNowMs(sample);
            return _OperationDemo(
              key: _operationDemoKeys[WidgetbookState.of(context)] ??= GlobalKey<_OperationDemoState>(),
              from: from,
              to: to,
              ran: context.knobs.boolean(label: 'run operation'),
              born: context.knobs.boolean(label: 'born', initialValue: true),
              flash: context.knobs.boolean(label: 'flash', initialValue: true),
              options: options,
              insets: _insets(context),
              nowMs: nowMs,
            );
          },
        ),
      ],
    ),
    WidgetbookComponent(
      name: 'Minimap',
      useCases: <WidgetbookUseCase>[
        WidgetbookUseCase(
          name: 'Recording',
          builder: (context) {
            final String revset = context.knobs.object.dropdown(
              label: 'revset',
              options: const <String>['jj log', 'all()'],
            );
            return _MinimapDemo(
              key: _minimapDemoKeys[WidgetbookState.of(context)] ??= GlobalKey<_MinimapDemoState>(),
              revset: revset,
              options: _options(context),
            );
          },
        ),
        // Story 10.31: nine years with a 400-day quiet stretch every 75 rows — breaks, year labels, a minimap sized by
        // its columns and scrolled past its minimum density (DS card *Long history*).
        WidgetbookUseCase(
          name: 'Long history',
          builder: (context) {
            final int lanes = context.knobs.int.slider(label: 'columns', initialValue: 6, min: 1, max: 24);
            return _MinimapDemo(
              key: ValueKey<int>(lanes),
              revset: 'jj log',
              options: _options(context, laneOrder: false),
              layoutOf: (request) => _fixture(
                'long history $lanes ${request.mode.name}',
                () => syntheticLayout(1500, free: request.mode == GraphMode.free, lanes: lanes, longGapEvery: 75),
              ),
            );
          },
        ),
      ],
    ),
    WidgetbookComponent(
      name: 'Floating shell',
      useCases: <WidgetbookUseCase>[
        WidgetbookUseCase(
          name: 'Controls',
          builder: (context) {
            final double width = context.knobs.double.slider(
              label: 'window width',
              initialValue: 1440,
              min: 880,
              max: 1440,
              divisions: 56,
            );
            const size = Size.fromHeight(900);
            return FittedBox(
              child: SizedBox(
                width: width,
                height: size.height,
                // The 1040 / 920 rules read the window width.
                child: MediaQuery(
                  data: MediaQuery.of(context).copyWith(size: Size(width, size.height)),
                  child: _ShellControlsDemo(
                    key: _shellControlsDemoKeys[WidgetbookState.of(context)] ??= GlobalKey<_ShellControlsDemoState>(),
                  ),
                ),
              ),
            );
          },
        ),
      ],
    ),
    WidgetbookComponent(
      name: 'Peek',
      useCases: <WidgetbookUseCase>[WidgetbookUseCase(name: 'Open', builder: (context) => const _Peeks())],
    ),
    WidgetbookComponent(
      name: '@ pill',
      useCases: <WidgetbookUseCase>[WidgetbookUseCase(name: 'Directions', builder: (context) => const _AtPills())],
    ),
    WidgetbookComponent(
      name: 'Drop menu',
      useCases: <WidgetbookUseCase>[WidgetbookUseCase(name: 'Open', builder: (context) => const _DropMenus())],
    ),
    WidgetbookComponent(
      name: 'Inspector diff',
      useCases: <WidgetbookUseCase>[
        WidgetbookUseCase(name: 'Hunk selection', builder: (context) => const _HunkSelection()),
      ],
    ),
    WidgetbookComponent(
      name: 'Stale notice',
      useCases: <WidgetbookUseCase>[WidgetbookUseCase(name: 'Variants', builder: (context) => const _StaleNotices())],
    ),
    WidgetbookComponent(
      name: 'Toast',
      useCases: <WidgetbookUseCase>[WidgetbookUseCase(name: 'Tones', builder: (context) => const _Toasts())],
    ),
    WidgetbookComponent(
      name: 'Card',
      useCases: <WidgetbookUseCase>[
        WidgetbookUseCase(
          name: 'States',
          builder: (context) => _CardStates(
            width: context.knobs.double.slider(
              label: 'card width',
              initialValue: 240,
              min: GraphMetrics.minCardWidth,
              max: GraphMetrics.maxCardWidth,
            ),
            detailed: context.knobs.boolean(label: 'detailed cards', initialValue: true),
            workspaceName: context.knobs.string(label: 'our workspace', initialValue: 'default'),
          ),
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

/// The recording of [sample] that [options] ask for, with fake refs and — unless [inlineContent] is false (the content
/// is paged, Story 10.11) — fake content.
RecordedGraphLayout recordedLayout(String sample, GraphViewOptions options, {bool inlineContent = true}) {
  final recording = '$sample ${options.layout.name} ${options.laneOrder.name}';
  return _fixture(inlineContent ? recording : '$recording paged', () {
    final (String input, String output) = graphRecordings[recording]!;
    return RecordedGraphLayout.fromSpec(
      input,
      output,
      content: inlineContent ? fakeContent : null,
      refs: fakeRefs,
      operationId: catalogueOperationId,
    );
  });
}

/// The design sample's every commit with its real parents (design-all, ungrouped): the fakes' `show` (Story 10.19).
GraphLayout _allParents() => recordedLayout('design-all', const GraphViewOptions(), inlineContent: false);

/// [child] with the gap clearance set to [clearance] (Story 10.19's knob, decision 16.30).
Widget _withClearance(double clearance, Widget child) => Builder(
  builder: (context) {
    final ThemeData theme = Theme.of(context);
    return Theme(
      data: theme.copyWith(
        // A later extension of a type replaces the earlier one.
        extensions: theme.extensions.values.followedBy(<GraphTheme>[
          GraphTheme.of(context).copyWith(gapClearance: clearance),
        ]),
      ),
      child: child,
    );
  },
);

/// The one operation every catalogue layout is pinned to, as a worker layout is to its topology's: the search's counts
/// and lookups ask the fakes only with one.
const catalogueOperationId = 'catalogue';

/// The fakes' answer to [request] on [sample] (Story 10.17): with Group stacks, the stack recording matching its run
/// states ([stackRecordingFor]); otherwise, or for a sample without stack recordings, the ungrouped recording. Content
/// is paged.
RecordedGraphLayout requestedLayout(String sample, GraphRequest request) {
  final String? stacks = stackRecordingFor(sample, request);
  if (stacks == null) {
    return recordedLayout(
      sample,
      GraphViewOptions(layout: request.mode, laneOrder: request.order),
      inlineContent: false,
    );
  }
  return _fixture('$stacks paged', () {
    final (String input, String output, _) = graphStackRecordings[stacks]!;
    return RecordedGraphLayout.fromSpec(input, output, refs: fakeRefs, operationId: catalogueOperationId);
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

/// A [GraphCanvas] over [layout] on the window canvas, with a card controller whose "now" is [nowMs] (the app's view
/// model owns "now"; the samples keep theirs).
class _GraphDemo extends StatefulWidget {
  const _GraphDemo({
    required this.layout,
    required this.options,
    required this.insets,
    required this.nowMs,
    this.transition,
  });

  final GraphLayout layout;
  final GraphViewOptions options;
  final EdgeInsets insets;
  final int nowMs;

  /// The operation [layout] lands with (Story 10.20).
  final GraphTransition? transition;

  @override
  State<_GraphDemo> createState() => _GraphDemoState();
}

class _GraphDemoState extends State<_GraphDemo> {
  late final _cards = GraphCardController(now: widget.nowMs);

  @override
  void didUpdateWidget(_GraphDemo oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.nowMs != widget.nowMs) {
      _cards.now.value = widget.nowMs;
    }
  }

  @override
  void dispose() {
    _cards.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: <Widget>[
      const ZsCanvas(),
      GraphCanvas(
        layout: widget.layout,
        cards: _cards,
        options: widget.options,
        insets: widget.insets,
        transition: widget.transition,
      ),
    ],
  );
}

/// "Viewport / Operation"'s pairs (Story 10.20): a recording and its `all()` view, or the synthetic 10k with one newest
/// change more.
const _operationPairs = <String>[
  'design-default ⇄ design-all',
  'design-cli-default ⇄ design-all',
  'synthetic 10k ⇄ 10k + 1',
];

/// One key per Widgetbook instance (see [_viewModelDemoKeys]): the "run operation" toggle swaps the layouts of one
/// state.
final _operationDemoKeys = Expando<GlobalKey<_OperationDemoState>>('operation demo key');

/// "Viewport / Operation" (Story 10.20): [ran] shows [to], else [from]; each toggle lands the other layout with a
/// [GraphTransition] from the shown one — with [born], the first key new in the target whose parent was shown grows
/// out of that parent; with [flash], the first key both show flashes. Slow it down with the TimeDilation addon.
class _OperationDemo extends StatefulWidget {
  const _OperationDemo({
    required this.from,
    required this.to,
    required this.ran,
    required this.born,
    required this.flash,
    required this.options,
    required this.insets,
    required this.nowMs,
    super.key,
  });

  final GraphLayout from;
  final GraphLayout to;
  final bool ran;
  final bool born;
  final bool flash;
  final GraphViewOptions options;
  final EdgeInsets insets;
  final int nowMs;

  @override
  State<_OperationDemo> createState() => _OperationDemoState();
}

class _OperationDemoState extends State<_OperationDemo> {
  GraphTransition? _transition;

  GraphLayout _shownBy(_OperationDemo demo) => demo.ran ? demo.to : demo.from;

  @override
  void didUpdateWidget(_OperationDemo oldWidget) {
    super.didUpdateWidget(oldWidget);
    final GraphLayout before = _shownBy(oldWidget);
    final GraphLayout after = _shownBy(widget);
    if (oldWidget.ran == widget.ran || identical(before, after)) {
      // Another pair or option: no operation.
      _transition = null;
      return;
    }
    final ({String born, String anchor})? birth = widget.born ? _birth(before, after) : null;
    final String? kept = widget.flash ? _kept(before, after) : null;
    _transition = GraphTransition(
      from: before,
      to: after,
      anchor: birth?.anchor,
      born: birth?.born,
      flash: <String>{?kept},
    );
  }

  /// The first shown key of [to] that [from] shows too.
  static String? _kept(GraphLayout from, GraphLayout to) {
    for (var node = 0; node < to.nodeCount; node++) {
      if (!to.isFolded(node) && from.placeOfKey(to.keyOf(node)) != null) {
        return to.keyOf(node);
      }
    }
    return null;
  }

  /// The first key of [to] that [from] lacks with a parent [from] shows, and that parent.
  static ({String born, String anchor})? _birth(GraphLayout from, GraphLayout to) {
    for (var node = 0; node < to.nodeCount; node++) {
      if (to.isFolded(node) || from.indexOfKey(to.keyOf(node)) != null) {
        continue;
      }
      final ({int start, int end}) parents = to.parentEdges(node);
      for (int e = parents.start; e < parents.end; e++) {
        final String parent = to.keyOf(to.parentOf(e));
        if (from.placeOfKey(parent) != null) {
          return (born: to.keyOf(node), anchor: parent);
        }
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) => _GraphDemo(
    layout: _shownBy(widget),
    options: widget.options,
    insets: widget.insets,
    nowMs: widget.nowMs,
    transition: _transition,
  );
}

/// "Viewport / View model" (Story 10.5): a [GraphViewModel] on a [FakeGraphSource] over the recordings (`jj log` →
/// design-default, `all()` → design-all), bound by [GraphView]; their content is paged with the fake's latency, so
/// the cards show skeletons first (Story 10.11). The knobs switch the revset, mode and lane order
/// through the model (each re-centres on @), and a stale cause makes every layout refuse, so the notice stands over
/// the last layout (or, picked before the first, over the empty canvas).
///
/// Widgetbook 3.25 keys a use case on its route, knobs included (`workbench.dart:82`), so a knob change would build a
/// fresh state with a fresh model; [_viewModelDemoKeys] moves the one state, source and model into the new subtree.
class _ViewModelDemo extends StatefulWidget {
  const _ViewModelDemo({
    required this.revset,
    required this.stacks,
    required this.options,
    required this.insets,
    required this.staleCause,
    super.key,
  });

  final String revset;

  /// Group stacks (Story 10.17).
  final bool stacks;
  final GraphViewOptions options;
  final EdgeInsets insets;
  final String? staleCause;

  @override
  State<_ViewModelDemo> createState() => _ViewModelDemoState();
}

/// One key per Widgetbook instance: its [WidgetbookState] lives as long as the instance, across knob changes, while a
/// re-open (`ZanshinCatalogueState.open`, a fresh Widgetbook) starts afresh with a new state and model.
final _viewModelDemoKeys = Expando<GlobalKey<_ViewModelDemoState>>('view model demo key');

class _ViewModelDemoState extends State<_ViewModelDemo> {
  late final _source = FakeGraphSource(
    (request) => requestedLayout(request.revset == 'all()' ? 'design-all' : 'design-default', request),
    staleCause: widget.staleCause,
  )..parentsLayout = _allParents;
  late final _model = GraphViewModel();

  String get _revset => widget.revset == 'all()' ? 'all()' : FakeGraphSource.defaults.log;

  @override
  void initState() {
    super.initState();
    final int now = recordedNowMs('design-default');
    _model.init(_source, clock: () => DateTime.fromMillisecondsSinceEpoch(now), stacks: widget.stacks);
    _apply(null);
  }

  @override
  void didUpdateWidget(_ViewModelDemo oldWidget) {
    super.didUpdateWidget(oldWidget);
    _apply(oldWidget);
  }

  void _apply(_ViewModelDemo? old) {
    _model
      ..setMode(widget.options.layout)
      ..setLaneOrder(widget.options.laneOrder)
      ..setStacks(widget.stacks);
    if (old == null ? widget.revset == 'all()' : old.revset != widget.revset) {
      _model.setRevset(_revset);
    }
    if (old != null && old.staleCause != widget.staleCause) {
      _source.staleCause = widget.staleCause;
      _model.reload();
    }
  }

  @override
  void dispose() {
    _model.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: <Widget>[
      const ZsCanvas(),
      GraphView(model: _model, options: widget.options, insets: widget.insets),
      Positioned(
        left: 0,
        right: 0,
        top: 12,
        child: Center(
          heightFactor: 1,
          child: ListenableBuilder(
            listenable: _model,
            builder: (context, _) => GraphView.staleNotice(_model) ?? const SizedBox.shrink(),
          ),
        ),
      ),
      // The shell's bottom slot: 20 px up, centred over the visible graph.
      Positioned(
        left: widget.insets.left,
        right: widget.insets.right,
        bottom: 20,
        child: Center(heightFactor: 1, child: GraphView.atPill(_model)),
      ),
    ],
  );
}

/// One key per Widgetbook instance, as [_viewModelDemoKeys].
final _minimapDemoKeys = Expando<GlobalKey<_MinimapDemoState>>('minimap demo key');

/// "Minimap / Recording" (Story 10.16): the floating shell over a [GraphView] on the view-model demo's fake source,
/// with the minimap in its slot (no inspector, so it shows) and the @ pill.
class _MinimapDemo extends StatefulWidget {
  const _MinimapDemo({required this.revset, required this.options, this.layoutOf, super.key});

  final String revset;
  final GraphViewOptions options;

  /// The layout of a request; the design recordings when null.
  final GraphLayout Function(GraphRequest request)? layoutOf;

  @override
  State<_MinimapDemo> createState() => _MinimapDemoState();
}

class _MinimapDemoState extends State<_MinimapDemo> {
  // The last layout answered: a given [_MinimapDemo.layoutOf]'s "now" is half a day after its newest day.
  GraphLayout? _last;
  late final _source = FakeGraphSource(
    (request) => _last = (widget.layoutOf ?? _recording)(request),
  )..parentsLayout = widget.layoutOf == null ? _allParents : null;
  final _model = GraphViewModel();
  final _shell = ShellController();

  static GraphLayout _recording(GraphRequest request) =>
      requestedLayout(request.revset == 'all()' ? 'design-all' : 'design-default', request);

  @override
  void initState() {
    super.initState();
    final int? now = widget.layoutOf == null ? recordedNowMs('design-default') : null;
    _model.init(
      _source,
      clock: () => now != null
          ? DateTime.fromMillisecondsSinceEpoch(now)
          : _last == null
          ? DateTime.now()
          : DateTime.fromMillisecondsSinceEpoch(_syntheticNowMs(_last!)),
      mode: widget.options.layout,
    );
    _apply(null);
  }

  @override
  void didUpdateWidget(_MinimapDemo oldWidget) {
    super.didUpdateWidget(oldWidget);
    _apply(oldWidget);
  }

  void _apply(_MinimapDemo? old) {
    _model
      ..setMode(widget.options.layout)
      ..setLaneOrder(widget.options.laneOrder);
    if (old == null ? widget.revset == 'all()' : old.revset != widget.revset) {
      _model.setRevset(widget.revset == 'all()' ? 'all()' : FakeGraphSource.defaults.log);
    }
  }

  @override
  void dispose() {
    _model.dispose();
    _shell.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FloatingShell(
    controller: _shell,
    canvas: const ZsCanvas(),
    graph: GraphView(model: _model, options: widget.options),
    minimap: GraphView.minimap(_model),
    atPill: GraphView.atPill(_model),
  );
}

/// One key per Widgetbook instance, as [_viewModelDemoKeys]: the width knob keeps the store, model and shell.
final _shellControlsDemoKeys = Expando<GlobalKey<_ShellControlsDemoState>>('shell controls demo key');

/// "Floating shell / Controls" (Story 10.7): the floating shell over a [GraphView] on the view-model demo's fake
/// source, the graph's controls in VIEW and ACTION and the @ pill; the View options are [GraphPreferences] on a
/// settings file in a temp folder, and New change runs on [_DemoActions]. The width knob sizes the window (its
/// `MediaQuery` too, so the 1040 / 920 rules show).
class _ShellControlsDemo extends StatefulWidget {
  const _ShellControlsDemo({super.key});

  @override
  State<_ShellControlsDemo> createState() => _ShellControlsDemoState();
}

class _ShellControlsDemoState extends State<_ShellControlsDemo> {
  final Directory _dir = Directory.systemTemp.createTempSync('zanshin_catalogue_graph');
  // Anything but the default search shows the `all()` recording (Story 10.21's fake ports).
  final _source = FakeGraphSource(
    (request) =>
        requestedLayout(request.revset == FakeGraphSource.defaults.log ? 'design-default' : 'design-all', request),
  )..parentsLayout = _allParents;
  final _model = GraphViewModel();
  late final _search = GraphSearchController(
    model: _model,
    source: FakeGraphSearchSource(
      () => requestedLayout(
        'design-all',
        GraphRequest(
          revset: 'all()',
          prioritize: FakeGraphSource.defaults.logGraphPrioritize,
          shortPrefixes: FakeGraphSource.defaults.shortPrefixes,
          anchors: const <String>[],
          utcOffsetMin: 0,
        ),
      ),
    ),
    store: MemoryGraphSearchStore(),
  );
  final _shell = ShellController();
  // Story 10.23: the graph's toasts, as the project window wires them.
  final _toasts = ShellToasts();
  late final _graphToasts = GraphToasts(_model, _toasts);
  final _descriptions = <String, String>{};
  GraphPreferences? _preferences;
  InspectorViewModel? _inspector;

  @override
  void initState() {
    super.initState();
    _graphToasts; // Listening from the start.
    unawaited(_load());
  }

  Future<void> _load() async {
    final SettingsStore store = await SettingsStore.load(File('${_dir.path}/settings.json'));
    if (!mounted) {
      return;
    }
    final int now = recordedNowMs('design-default');
    final preferences = GraphPreferences(store)
      ..init(
        _model,
        _source,
        actions: _DemoActions(_descriptions),
        clock: () => DateTime.fromMillisecondsSinceEpoch(now),
        // A path outside the registry: the stack toggles live in memory for the demo (Story 10.17).
        stackStore: ProjectStackStore(store, '/demo'),
        revset: _search.revset,
      );
    _model.addListener(_selectFirst);
    setState(() {
      _preferences = preferences;
      _inspector = InspectorViewModel(
        graph: _model,
        details: _DemoDetails(_model, _descriptions),
        // A path outside the registry: the Viewed marks live in memory for the demo (Story 10.24).
        viewed: ProjectViewedStore(store, '/demo'),
        settings: store,
      );
    });
  }

  /// Once the first layout landed, selects its first mutable change other than @, so the inspector shows.
  void _selectFirst() {
    final GraphLayout? layout = _model.layout;
    if (layout == null) {
      return;
    }
    _model.removeListener(_selectFirst);
    for (var node = 0; node < layout.nodeCount; node++) {
      if (node != layout.workingCopyIndex && node != layout.rootIndex && !layout.isImmutable(node)) {
        _model.select(layout.keyOf(node));
        return;
      }
    }
  }

  @override
  void dispose() {
    _model.removeListener(_selectFirst);
    _inspector?.dispose();
    _preferences?.dispose();
    _search.dispose();
    _graphToasts.dispose();
    _model.dispose();
    _toasts.dispose();
    _shell.dispose();
    _dir.deleteSync(recursive: true);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final GraphPreferences? preferences = _preferences;
    final InspectorViewModel? inspector = _inspector;
    if (preferences == null || inspector == null) {
      return const ZsCanvas();
    }
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[_model, _toasts]),
      builder: (context, _) => GraphSearchShortcuts(
        search: _search,
        child: FloatingShell(
          controller: _shell,
          canvas: const ZsCanvas(),
          graph: ListenableBuilder(
            listenable: preferences,
            builder: (context, _) => GraphView(model: _model, options: preferences.options, search: _search),
          ),
          projectCapsule: demoCapsule(),
          view: GraphViewControls(model: _model, preferences: preferences, search: _search),
          syncGroup: SyncIsland(onReload: _model.reload),
          newChange: NewChangeButton(model: _model),
          inspector: GraphView.inspector(inspector),
          atPill: GraphView.atPill(_model),
          toast: _toasts.occupied ? ShellToastView(toasts: _toasts) : null,
        ),
      ),
    );
  }
}

/// The demo's verbs: each writes one operation; `jj new` and `jj revert` give birth to a change the recording does
/// not show; `jj describe` keeps its text in [descriptions] for [_DemoDetails].
class _DemoActions implements GraphActions {
  _DemoActions(this.descriptions);

  /// The described changes' descriptions, by key.
  final Map<String, String> descriptions;

  var _ops = 0;

  @override
  Future<String> headOpId() async => 'op$_ops';

  @override
  Future<MutationResult> run(GraphAction action) async {
    if (action is GraphDescribe) {
      descriptions[action.id] = action.description;
    }
    return MutationResult(
      newOpId: 'op${++_ops}',
      newChangeIds: <String>[if (action is GraphNew || action is GraphRevert) 'born$_ops'],
      abandonedChangeIds: const <String>[],
      workingCopyChangeId: null,
      finish: null,
    );
  }
}

/// The demo's inspector reads (Story 10.8), derived from the shown layout: the fake content's subject and author, a
/// body on every third change, the layout's direct parents, and up to four files whose kinds cycle (a rename among
/// them); a merge and the root change no files. Every verb preview is available.
class _DemoDetails implements GraphDetails {
  _DemoDetails(this._model, this._descriptions);

  final GraphViewModel _model;
  final Map<String, String> _descriptions;

  static const _paths = <String>['lib/auth/session.dart', 'lib/ui/onboarding.dart', 'assets/logo.png', 'src/main.rs'];

  static const _kinds = <FileChangeKind>[
    FileChangeKind.modified,
    FileChangeKind.added,
    FileChangeKind.renamed,
    FileChangeKind.removed,
  ];

  @override
  Future<ShowEntry> show(String commitId) async {
    final GraphLayout layout = _model.layout!;
    final int node = List<int>.generate(layout.nodeCount, (i) => i).firstWhere((i) => layout.commitIdOf(i) == commitId);
    final String key = layout.keyOf(node);
    final GraphCommitContent content = fakeContent(commitId.hashCode, commitId);
    final ({int start, int end}) edges = layout.parentEdges(node);
    final bool merge = layout.parentCountOf(node) >= 2;
    final int files = merge || node == layout.rootIndex ? 0 : commitId.hashCode % 5;
    final author = Signature(
      name: content.authorName,
      email: content.authorEmail,
      timestampMillis: layout.timestampOf(node) ?? 0,
      tzOffsetMinutes: 0,
    );
    return ShowEntry(
      change: Change(
        id: layout.changeIdOf(node),
        commitId: commitId,
        parents: <String>[for (var e = edges.start; e < edges.end; e++) layout.keyOf(layout.parentOf(e))],
        description:
            _descriptions[key] ??
            (content.subject.isEmpty
                ? ''
                : node % 3 == 0
                ? '${content.subject}\n\nWhy: the catalogue shows a body under the title.\n'
                : '${content.subject}\n'),
        author: author,
        committer: author,
        isSigned: false,
        conflict: content.conflict ? ConflictState.conflicted : ConflictState.clean,
        conflictedPaths: const <String>[],
        isAnonymous: content.subject.isEmpty,
        divergent: false,
      ),
      fileChanges: <FileChange>[
        for (var i = 0; i < files; i++)
          FileChange(
            path: _paths[i],
            kind: _kinds[i],
            fromPath: _kinds[i] == FileChangeKind.renamed ? 'assets/icon.png' : null,
          ),
      ],
    );
  }

  static const _available = ActionOutcome(
    status: ActionStatus.available,
    refusal: null,
    combinedDescriptionNeeded: false,
    allowBackwardsNeeded: false,
  );

  @override
  Future<ChangeActions> changeActions(String changeId) async => const ChangeActions(
    newOnto: _available,
    newInsertAfter: _available,
    newInsertBefore: _available,
    edit: _available,
    describe: _available,
    squashIntoParent: _available,
    abandon: _available,
  );

  /// Story 10.24: a modified file gets two hunks (in Rust the first under `fn main()`), an added or removed one a
  /// single hunk of its lines, a `.png` is binary.
  @override
  Future<Diff> diff(String commitId, {List<String> paths = const [], bool summary = false}) async {
    final ShowEntry entry = await show(commitId);
    return Diff(
      files: <FileDiff>[
        for (final FileChange file in entry.fileChanges)
          if (paths.isEmpty || paths.contains(file.path)) _diffOf(file, summary: summary),
      ],
      operationId: 'op',
      commitIds: <String>[commitId],
    );
  }

  /// Story 10.25: the change's and its first parent's descriptions combined as jj's editor shows them, when both are
  /// set; else none.
  @override
  Future<SquashPlan> squashPlan(String changeId) async {
    final GraphLayout layout = _model.layout!;
    final int node = layout.indexOfKey(changeId)!;
    final ({int start, int end}) edges = layout.parentEdges(node);
    if (edges.start == edges.end) {
      return const SquashPlan(combinedDescription: null);
    }
    final String own = (await show(layout.commitIdOf(node))).change.description;
    final String parent = (await show(layout.commitIdOf(layout.parentOf(edges.start)))).change.description;
    return SquashPlan(combinedDescription: own.isEmpty || parent.isEmpty ? null : '$parent\n$own');
  }

  static HunkLine _line(HunkLineKind kind, String text) => HunkLine(kind: kind, text: '$text\n');

  static FileDiff _diffOf(FileChange file, {required bool summary}) {
    final bool binary = file.path.endsWith('.png');
    final bool rust = file.path.endsWith('.rs');
    final List<Hunk> hunks = binary
        ? const <Hunk>[]
        : switch (file.kind) {
            FileChangeKind.added || FileChangeKind.copied => <Hunk>[
              Hunk(
                before: (start: 0, end: 0),
                after: (start: 0, end: 3),
                symbol: null,
                sections: const [],
                removed: 0,
                added: 3,
                lines: <HunkLine>[
                  _line(HunkLineKind.added, "import 'package:flutter/widgets.dart';"),
                  _line(HunkLineKind.added, ''),
                  _line(HunkLineKind.added, 'class Onboarding extends StatelessWidget {}'),
                ],
              ),
            ],
            FileChangeKind.removed => <Hunk>[
              Hunk(
                before: (start: 0, end: 2),
                after: (start: 0, end: 0),
                symbol: null,
                sections: const [],
                removed: 2,
                added: 0,
                lines: <HunkLine>[
                  _line(HunkLineKind.removed, 'fn main() {'),
                  _line(HunkLineKind.removed, '}'),
                ],
              ),
            ],
            _ => <Hunk>[
              Hunk(
                before: (start: 11, end: 16),
                after: (start: 11, end: 15),
                symbol: rust ? 'fn main()' : null,
                sections: const [],
                removed: 3,
                added: 2,
                lines: <HunkLine>[
                  _line(HunkLineKind.context, '  final Duration ttl;'),
                  _line(HunkLineKind.removed, '  Session refresh() {'),
                  _line(HunkLineKind.removed, '    return Session(token: token, ttl: ttl);'),
                  _line(HunkLineKind.removed, '  }'),
                  _line(
                    HunkLineKind.added,
                    '  Future<Session> refresh() async => Session(token: await renew(token), ttl: ttl);',
                  ),
                  _line(HunkLineKind.added, '  bool get expired => DateTime.now().isAfter(issued.add(ttl));'),
                  _line(HunkLineKind.context, '}'),
                ],
              ),
              Hunk(
                before: (start: 40, end: 42),
                after: (start: 39, end: 42),
                symbol: rust ? 'fn main()' : null,
                sections: const [],
                removed: 0,
                added: 1,
                lines: <HunkLine>[
                  _line(HunkLineKind.context, '  void dispose() {'),
                  _line(HunkLineKind.added, '    _timer?.cancel();'),
                  _line(HunkLineKind.context, '  }'),
                ],
              ),
            ],
          };
    return FileDiff(
      path: file.path,
      kind: file.kind,
      fromPath: file.fromPath,
      binary: binary,
      modeChange: false,
      sections: const [],
      hunks: summary ? const <Hunk>[] : hunks,
      removed: hunks.fold(0, (sum, hunk) => sum + hunk.removed),
      added: hunks.fold(0, (sum, hunk) => sum + hunk.added),
      fingerprint: file.path.hashCode.toRadixString(16),
    );
  }
}

/// "Peek / Open" (Story 10.6): the commit callout as the hover opens it, for a mutable change, an immutable one, @
/// and the root.
class _Peeks extends StatelessWidget {
  const _Peeks();

  @override
  Widget build(BuildContext context) {
    const int imm = RecordedGraphLayout.flagImmutable;
    final peeks = <GraphCardData>[
      GraphCardData.of(_single('kxwsnptmqrvl', prefix: 3), 0),
      GraphCardData.of(
        _single(
          'vruxwmqvnklt',
          flags: imm,
          content: const GraphCommitContent(subject: 'release: 1.4.2', authorEmail: 'bob@example.com'),
        ),
        0,
      ),
      GraphCardData.of(_single('ovknlmrotwqs', workingCopy: true), 0),
      GraphCardData.of(_single('zzzzzzzzzzzz', prefix: 1, root: true, flags: imm, content: null), 0),
    ];
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        const ZsCanvas(),
        SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: Wrap(
            spacing: 24,
            runSpacing: 24,
            children: <Widget>[for (final GraphCardData data in peeks) GraphPeek(data: data, nowMs: _statesNow)],
          ),
        ),
      ],
    );
  }
}

/// "@ pill / Directions" (Story 10.6): the pill pointing to each side @ can lie on.
class _AtPills extends StatelessWidget {
  const _AtPills();

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: <Widget>[
      const ZsCanvas(),
      Center(
        child: Wrap(
          spacing: 24,
          runSpacing: 24,
          children: <Widget>[
            for (final GraphDirection direction in GraphDirection.values)
              AtPill(direction: direction, onPressed: () {}),
          ],
        ),
      ),
    ],
  );
}

/// One state of the card matrix: its label, its one-node layout and the controller state it forces.
typedef _CardCase = ({
  String label,
  RecordedGraphLayout layout,
  bool hover,
  bool selected,
  bool menu,
  bool focus,
  bool disabled,
});

// The States sample's "now": Sep 25 2026, 14:00 UTC.
const _statesNow = 1790344800000;
const _minute = 60000;

const _subject = GraphCommitContent(
  subject: 'feat(onboarding): swipe gestures + haptic feedback',
  authorName: 'Ralph Stein',
  authorEmail: 'ralph@example.com',
);

/// A one-node layout carrying one card's facts.
RecordedGraphLayout _single(
  String id, {
  int prefix = 2,
  int? offset,
  bool workingCopy = false,
  bool root = false,
  int flags = 0,
  List<GraphRef> refs = const <GraphRef>[],
  List<String> workspaces = const <String>[],
  String? workspaceName,
  GraphCommitContent? content = _subject,
  int age = 40 * _minute,
  int parents = 1,
}) => RecordedGraphLayout(
  mode: GraphMode.compact,
  unit: 1,
  rows: 1,
  colCount: 1,
  keys: <String>[id],
  cols: Int32List(1),
  nodeRows: Int32List(1),
  parentCounts: Int32List.fromList(<int>[parents]),
  elided: Uint8List(1),
  edgeChildren: Int32List(0),
  edgeParents: Int32List(0),
  edgeKinds: const <GraphEdgeKind>[],
  edgeShapes: const <GraphEdgeShape>[],
  timestamps: <int?>[if (root) null else _statesNow - age],
  changeIds: <String>[id],
  changeIdPrefixLengths: Int32List.fromList(<int>[prefix]),
  changeOffsets: <int?>[offset],
  flags: Uint8List.fromList(<int>[flags]),
  refs: <List<GraphRef>>[refs],
  workingCopies: <List<String>>[workspaces],
  contents: <GraphCommitContent?>[content],
  workspaceName: workspaceName,
  rootIndex: root ? 0 : null,
  workingCopyIndex: workingCopy ? 0 : null,
);

List<_CardCase> _cases(String ours) {
  _CardCase c(
    String label,
    RecordedGraphLayout layout, {
    bool hover = false,
    bool selected = false,
    bool menu = false,
    bool focus = false,
    bool disabled = false,
  }) => (
    label: label,
    layout: layout,
    hover: hover,
    selected: selected,
    menu: menu,
    focus: focus,
    disabled: disabled,
  );
  const int imm = RecordedGraphLayout.flagImmutable;
  return <_CardCase>[
    c('base', _single('kxwsnptmqrvl', prefix: 3)),
    c('hover', _single('kywqlmnrstvp'), hover: true),
    c('selected', _single('lpmxnvqrtzkw'), selected: true),
    c('menu open', _single('lqvrsntmwkpx'), menu: true),
    c('keyboard focus', _single('mrplxqwvtnks'), focus: true),
    c('@', _single('ovknlmrotwqs', workingCopy: true)),
    c('@ selected', _single('ovkqrtsmlnwp', workingCopy: true), selected: true),
    c('immutable', _single('vruxwmqvnklt', flags: imm, refs: const <GraphRef>[GraphRef('main')])),
    c('immutable hovered', _single('vrtkslwqmnop', flags: imm), hover: true),
    c('immutable selected', _single('vrnqpsxwtklm', flags: imm), selected: true),
    c('immutable menu open', _single('vrmzkqlstnwx', flags: imm), menu: true),
    c('root', _single('zzzzzzzzzzzz', prefix: 1, root: true, flags: imm, content: null)),
    c(
      'no description',
      _single(
        'nqxwrptlksmv',
        content: const GraphCommitContent(subject: '', authorName: 'Lena König'),
      ),
    ),
    c(
      'empty, conflict, merge',
      _single(
        'kxwqtzrsplmn',
        parents: 2,
        content: const GraphCommitContent(
          subject: 'merge: bring iOS keyboard fix into develop',
          authorName: 'Bob',
          empty: true,
          conflict: true,
        ),
      ),
    ),
    c('content not loaded', _single('tnrkslqwvmpx', content: null)),
    c('divergent', _single('mzvwutvlqrsk', offset: 1, flags: RecordedGraphLayout.flagDivergent)),
    c('hidden', _single('mzvqrsktlnwp', offset: 2, flags: RecordedGraphLayout.flagHidden)),
    c('long prefix', _single('qpvuntsmrkwl', prefix: 10)),
    c(
      '2 workspaces',
      _single('ovkwsplmqrtz', workingCopy: true, workspaces: <String>[ours, 'ci'], workspaceName: ours),
    ),
    c(
      '5 workspaces, long author',
      _single(
        'ovkzrtlqmwsp',
        workingCopy: true,
        workspaces: <String>[ours, 'ci', 'docs', 'release', 'scratch'],
        workspaceName: ours,
        content: const GraphCommitContent(
          subject: 'feat(onboarding): swipe gestures + haptic feedback',
          authorName: 'Maximilian-Alexander Featherstonehaugh',
        ),
      ),
    ),
    c('quoted name', _single('plkzrtwqmnsv', workspaces: <String>['my ws', ours], workspaceName: ours)),
    c('actions disabled', _single('rtmswzvklqnp'), hover: true, disabled: true),
    c('legend: ticket', _single('plkmnvxoqrst', refs: const <GraphRef>[GraphRef('feature/ZAN-412_onboarding-swipe')])),
    c(
      'legend: path + remote',
      _single('yostqsxwlmkr', refs: const <GraphRef>[GraphRef('release/1.5.x', remote: 'origin')]),
    ),
    c(
      'legend: + more',
      _single(
        'tnrkqlsmwvxp',
        refs: const <GraphRef>[GraphRef('riverpod'), GraphRef('exp/riverpod-3'), GraphRef('main')],
      ),
    ),
    c(
      'legend: sigils',
      _single(
        'kxwmqlrtsnvp',
        refs: const <GraphRef>[GraphRef('main', conflicted: true), GraphRef('dev', synced: false)],
      ),
    ),
    c('legend: unsynced', _single('kxwplsrtmqnv', refs: const <GraphRef>[GraphRef('dev', synced: false)])),
  ];
}

/// "Card / States" (Story 10.3): one card per state of the matrix, each in its own inflated box with its own
/// controller (hover, selection, menu and focus forced), and the hatch swatch.
// shortcut: the forced hover clears when the pointer leaves the card, and the focus ring shows only under
// traditional (keyboard) highlighting; reopen the use case to see them again.
class _CardStates extends StatefulWidget {
  const _CardStates({required this.width, required this.detailed, required this.workspaceName});

  final double width;
  final bool detailed;
  final String workspaceName;

  @override
  State<_CardStates> createState() => _CardStatesState();
}

class _CardStatesState extends State<_CardStates> {
  final _controllers = <GraphCardController>[];
  late List<_CardCase> _all;
  String? _ours;

  List<_CardCase> get _matrix {
    if (_ours != widget.workspaceName) {
      _ours = widget.workspaceName;
      _all = _cases(widget.workspaceName.isEmpty ? 'default' : widget.workspaceName);
      for (final GraphCardController controller in _controllers) {
        controller.dispose();
      }
      _controllers
        ..clear()
        ..addAll(<GraphCardController>[
          for (final _CardCase each in _all)
            GraphCardController(now: _statesNow)
              ..hovered.value = each.hover ? each.layout.keyOf(0) : null
              ..selected.value = each.selected ? each.layout.keyOf(0) : null
              ..menuOpen.value = each.menu ? each.layout.keyOf(0) : null
              ..focused.value = each.focus ? each.layout.keyOf(0) : null
              ..actionsEnabled.value = !each.disabled,
        ]);
    }
    return _all;
  }

  @override
  void dispose() {
    for (final GraphCardController controller in _controllers) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final List<_CardCase> matrix = _matrix;
    final ZsColors colors = ZsColors.of(context);
    final TextStyle label = ZsType.meta.copyWith(color: colors.textMuted);
    final double height = widget.detailed ? ZsMetrics.standard.cardHDetailed : ZsMetrics.standard.cardHCompact;
    final double width = widget.width.clamp(GraphMetrics.minCardWidth, GraphMetrics.maxCardWidth);
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        const ZsCanvas(),
        SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: Wrap(
            spacing: 24,
            runSpacing: 16,
            children: <Widget>[
              for (var i = 0; i < matrix.length; i++)
                Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Padding(
                      padding: const EdgeInsets.only(left: graphCardOverhang),
                      child: Text(matrix[i].label, style: label),
                    ),
                    SizedBox(
                      width: width + 2 * graphCardOverhang,
                      height: height + 2 * graphCardOverhang,
                      child: GraphCard(layout: matrix[i].layout, node: 0, controller: _controllers[i]),
                    ),
                  ],
                ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  const HatchSwatch(),
                  const SizedBox(width: 6),
                  Text('Immutable', style: label),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// "Toast / Tones" (Story 10.23): a success with Undo, one with a warning clause, a refusal (warn) and a failure with
/// Retry, then the live host — Replay shows the next of them through a `ShellToastView`, with its motion and hold.
class _Toasts extends StatefulWidget {
  const _Toasts();

  @override
  State<_Toasts> createState() => _ToastsState();
}

class _ToastsState extends State<_Toasts> {
  final _toasts = ShellToasts();
  var _next = 0;

  @override
  void dispose() {
    _toasts.dispose();
    super.dispose();
  }

  static ZsToast _sample(BuildContext context, int i, VoidCallback dismiss) {
    final ZsColors colors = ZsColors.of(context);
    InlineSpan id(String bold, String rest) => TextSpan(
      children: <TextSpan>[
        TextSpan(
          text: bold,
          style: ZsType.id.copyWith(fontSize: ZsType.fsMd, fontWeight: FontWeight.w600, color: colors.text),
        ),
        TextSpan(
          text: rest,
          style: ZsType.id.copyWith(fontSize: ZsType.fsMd, color: colors.textMuted),
        ),
      ],
    );
    final undo = ZsToastAction(label: 'Undo', tooltip: 'jj undo', onPressed: dismiss);
    return switch (i % 4) {
      0 => ZsToast(
        message: TextSpan(
          children: <InlineSpan>[
            const TextSpan(text: 'Squashed '),
            id('ov', 'knlmro'),
            const TextSpan(text: ' into '),
            id('vr', 'uxwmqv'),
          ],
        ),
        actions: <ZsToastAction>[undo],
        onDismiss: dismiss,
      ),
      1 => ZsToast(
        message: toastWithWarnings(
          colors,
          TextSpan(
            children: <InlineSpan>[
              const TextSpan(text: 'Abandoned '),
              id('ov', 'knlmro'),
            ],
          ),
          const <ZanshinWarning>[
            ZanshinWarning(code: 'jj.identity_missing', message: 'Name and email not configured.'),
          ],
        ),
        actions: <ZsToastAction>[undo],
        onDismiss: dismiss,
      ),
      2 => ZsToast(
        tone: ZsToastTone.warn,
        message: const TextSpan(text: 'Commit 1234abcd is immutable'),
        onDismiss: dismiss,
      ),
      _ => ZsToast(
        tone: ZsToastTone.error,
        message: const TextSpan(text: 'Updating the working copy failed — jj.io_error'),
        actions: <ZsToastAction>[
          ZsToastAction(label: 'Retry', tooltip: 'jj workspace update-stale', onPressed: dismiss),
        ],
        onDismiss: dismiss,
      ),
    };
  }

  void _replay() {
    final int i = _next++;
    _toasts.show(
      ShellToastEntry(
        tone: const <ZsToastTone>[ZsToastTone.success, ZsToastTone.success, ZsToastTone.warn, ZsToastTone.error][i % 4],
        build: (context, dismiss) => _sample(context, i, dismiss),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: <Widget>[
      const ZsCanvas(),
      SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 16,
          children: <Widget>[
            for (var i = 0; i < 4; i++) Builder(builder: (context) => _sample(context, i, () {})),
            ZsButton(label: 'Replay', identifier: 'toast-replay', onPressed: _replay),
            SizedBox(
              height: 80,
              child: ListenableBuilder(
                listenable: _toasts,
                builder: (context, _) =>
                    _toasts.occupied ? Center(child: ShellToastView(toasts: _toasts)) : const SizedBox.shrink(),
              ),
            ),
          ],
        ),
      ),
    ],
  );
}

/// "Stale notice / Variants" (Story 10.5): the notice for each cause with "Update working copy", one busy, and the
/// notice without the action, offering Copy.
/// The drop menu as it opens (Story 10.10; Marionette cannot hold a drag): below and above a card, "Move here"
/// highlighted.
class _DropMenus extends StatelessWidget {
  const _DropMenus();

  static GraphDropRow _row(GraphDropKind kind, String command) => GraphDropRow(
    kind: kind,
    command: command,
    action: const GraphRebase(source: <String>['a'], onto: <String>['b']),
  );

  @override
  Widget build(BuildContext context) {
    // Priority order, as the preview delivers them; the menu itself runs them bottom-up above a card.
    final rows = <GraphDropRow>[
      _row(GraphDropKind.moveHere, 'jj rebase -s wkumzvop -o nmomqylo'),
      _row(GraphDropKind.moveOnly, 'jj rebase -r wkumzvop -o nmomqylo'),
      _row(GraphDropKind.insertAfter, 'jj rebase -s wkumzvop -A nmomqylo'),
      _row(GraphDropKind.insertBefore, 'jj rebase -s wkumzvop -B nmomqylo'),
      _row(GraphDropKind.squash, 'jj squash --from wkumzvop --into nmomqylo'),
    ];
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        const ZsCanvas(),
        Padding(
          padding: const EdgeInsets.all(32),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 48,
            children: <Widget>[
              GraphDropMenu(rows: rows, highlight: 0, above: false),
              GraphDropMenu(rows: rows, highlight: 0, above: true),
            ],
          ),
        ),
      ],
    );
  }
}

/// A partly picked file in the inspector (Story 10.26): the mode row picked, hunk 1 and 3 picked, hunk 2 not.
class _HunkSelection extends StatelessWidget {
  const _HunkSelection();

  static Hunk _hunk(int start, List<HunkLine> lines, String symbol) => Hunk(
    before: (start: start, end: start + 3),
    after: (start: start, end: start + 3),
    symbol: symbol,
    sections: <HunkKey>[HunkKey(oldStart: start + 1, oldCount: 1, newStart: start + 1, newCount: 1)],
    removed: lines.where((l) => l.kind == HunkLineKind.removed).length,
    added: lines.where((l) => l.kind == HunkLineKind.added).length,
    lines: lines,
  );

  static List<HunkLine> _lines(String old, String now) => <HunkLine>[
    const HunkLine(kind: HunkLineKind.context, text: 'fn main() {\n'),
    HunkLine(kind: HunkLineKind.removed, text: '$old\n'),
    HunkLine(kind: HunkLineKind.added, text: '$now\n'),
    const HunkLine(kind: HunkLineKind.context, text: '}\n'),
  ];

  @override
  Widget build(BuildContext context) {
    final hunks = <Hunk>[
      _hunk(3, _lines('    let a = 1;', '    let a = 2;'), 'main'),
      _hunk(20, _lines('    log("x");', '    log("y");'), 'run'),
      _hunk(40, _lines('    exit(0)', '    exit(1)'), 'stop'),
    ];
    final picked = <Hunk>{hunks[0], hunks[2]};
    final diff = FileDiff(
      path: 'src/main.rs',
      kind: FileChangeKind.modified,
      fromPath: null,
      binary: false,
      modeChange: true,
      sections: const [],
      hunks: hunks,
      removed: 3,
      added: 3,
      fingerprint: 'f',
    );
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        const ZsCanvas(),
        Padding(
          padding: const EdgeInsets.all(32),
          child: SizedBox(
            width: 560,
            child: SingleChildScrollView(
              child: InspectorDiffView(
                path: diff.path,
                diff: diff,
                error: null,
                layout: DiffLayoutSetting.unified,
                onLayoutChanged: (_) {},
                hunkPicked: picked.contains,
                onHunkToggled: (_) {},
                modePicked: true,
                onModeToggled: () {},
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _StaleNotices extends StatelessWidget {
  const _StaleNotices();

  @override
  Widget build(BuildContext context) {
    final causes = <GraphStale>[
      for (final String cause in <String>['stale', 'sibling_operation', 'operation_not_found'])
        GraphStale.fromError(FakeGraphSource.staleError(cause)),
    ];
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        const ZsCanvas(),
        SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 16,
            children: <Widget>[
              for (final GraphStale stale in causes)
                StaleNotice(command: stale.command, message: stale.message, onUpdate: () {}),
              StaleNotice(command: causes.first.command, message: causes.first.message, onUpdate: () {}, busy: true),
              StaleNotice(command: causes.first.command, message: causes.first.message),
            ],
          ),
        ),
      ],
    );
  }
}
