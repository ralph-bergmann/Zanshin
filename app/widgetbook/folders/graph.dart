// SPDX-License-Identifier: MIT

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:widgetbook/widgetbook.dart';
import 'package:zanshin/src/features/graph/at_pill.dart';
import 'package:zanshin/src/features/graph/graph_canvas.dart';
import 'package:zanshin/src/features/graph/graph_card.dart';
import 'package:zanshin/src/features/graph/graph_layout.dart';
import 'package:zanshin/src/features/graph/graph_metrics.dart';
import 'package:zanshin/src/features/graph/graph_peek.dart';
import 'package:zanshin/src/features/graph/graph_view.dart';
import 'package:zanshin/src/features/graph/graph_view_model.dart';
import 'package:zanshin/src/features/graph/graph_viewport.dart';
import 'package:zanshin/src/features/graph/hatch_swatch.dart';
import 'package:zanshin/src/features/graph/layout_invariants.dart';
import 'package:zanshin/src/features/graph/recorded_graph_layout.dart';
import 'package:zanshin/src/features/graph/stale_notice.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

import '../graph/fake_content.dart';
import '../graph/fake_graph_source.dart';
import '../graph/graph_recordings.g.dart';
import '../graph/synthetic_layout.dart';

/// The "Graph" folder (Story 10.1, decision 16.30): the fake-data host of every Epic 10 story. "Viewport / Recording"
/// shows the recorded layouts of the design sample and medium-narrow, "Viewport / Scale" the synthetic 10k–100k
/// fixtures, both with fake content (Story 10.3); every `GraphViewOptions` field is a knob, and the left and right
/// insets stand in for the floating chrome. "Viewport / View model" drives a `GraphViewModel` on a fake source over the
/// recordings, with the stale notice and the @ pill over it (Stories 10.5, 10.6). "Card / States" shows one commit card
/// per state (Story 10.3); "Peek / Open" the commit callout and "@ pill / Directions" the pill (Story 10.6); "Stale
/// notice / Variants" the notice with its action, busy, and with Copy (Story 10.5).
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
              options: _options(context),
              insets: _insets(context),
              staleCause: stale == 'none' ? null : stale,
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
      name: 'Stale notice',
      useCases: <WidgetbookUseCase>[WidgetbookUseCase(name: 'Variants', builder: (context) => const _StaleNotices())],
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

/// The recording of [sample] that [options] ask for, with fake content and refs.
RecordedGraphLayout recordedLayout(String sample, GraphViewOptions options) {
  final name = '$sample ${options.layout.name} ${options.laneOrder.name}';
  return _fixture(name, () {
    final (String input, String output) = graphRecordings[name]!;
    return RecordedGraphLayout.fromSpec(input, output, content: fakeContent, refs: fakeRefs);
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
  const _GraphDemo({required this.layout, required this.options, required this.insets, required this.nowMs});

  final GraphLayout layout;
  final GraphViewOptions options;
  final EdgeInsets insets;
  final int nowMs;

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
      GraphCanvas(layout: widget.layout, cards: _cards, options: widget.options, insets: widget.insets),
    ],
  );
}

/// "Viewport / View model" (Story 10.5): a [GraphViewModel] on a [FakeGraphSource] over the recordings (`jj log` →
/// design-default, `all()` → design-all), bound by [GraphView]; the knobs switch the revset, mode and lane order
/// through the model (each re-centres on @), and a stale cause makes every layout refuse, so the notice stands over
/// the last layout (or, picked before the first, over the empty canvas).
///
/// Widgetbook 3.25 keys a use case on its route, knobs included (`workbench.dart:82`), so a knob change would build a
/// fresh state with a fresh model; [_viewModelDemoKeys] moves the one state, source and model into the new subtree.
class _ViewModelDemo extends StatefulWidget {
  const _ViewModelDemo({
    required this.revset,
    required this.options,
    required this.insets,
    required this.staleCause,
    super.key,
  });

  final String revset;
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
    (request) => recordedLayout(
      request.revset == 'all()' ? 'design-all' : 'design-default',
      GraphViewOptions(layout: request.mode, laneOrder: request.order),
    ),
    staleCause: widget.staleCause,
  );
  late final _model = GraphViewModel();

  String get _revset => widget.revset == 'all()' ? 'all()' : FakeGraphSource.defaults.log;

  @override
  void initState() {
    super.initState();
    final int now = recordedNowMs('design-default');
    _model.init(_source, clock: () => DateTime.fromMillisecondsSinceEpoch(now));
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
      ..setLaneOrder(widget.options.laneOrder);
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

/// "Stale notice / Variants" (Story 10.5): the notice for each cause with "Update working copy", one busy, and the
/// notice without the action, offering Copy.
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
