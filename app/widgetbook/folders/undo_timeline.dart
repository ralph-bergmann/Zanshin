// SPDX-License-Identifier: MIT

import 'package:flutter/widgets.dart';
import 'package:widgetbook/widgetbook.dart';
import 'package:zanshin/src/features/graph/graph_ports.dart';
import 'package:zanshin/src/features/shell/pinned_panel.dart';
import 'package:zanshin/src/features/shell/rail_preview.dart';
import 'package:zanshin/src/features/shell/shell_controller.dart';
import 'package:zanshin/src/features/undo_timeline/undo_timeline_model.dart';
import 'package:zanshin/src/features/undo_timeline/undo_timeline_view.dart';
import 'package:zanshin/src/l10n/strings.dart';
import 'package:zanshin_core/zanshin_core.dart';

/// The "Undo Timeline" folder (Story 11.9): the rail item's hover preview and pinned panel over a fake op log and a
/// fake runner — the preview as the rail's callout (290 wide), the panel at the default 300.
final undoTimelineFolder = WidgetbookFolder(
  name: 'Undo Timeline',
  children: <WidgetbookNode>[
    WidgetbookComponent(
      name: 'Undo Timeline',
      useCases: <WidgetbookUseCase>[
        for (final _Demo demo in _Demo.values)
          WidgetbookUseCase(
            name: demo.label,
            builder: (context) => _DemoHost(key: ValueKey<_Demo>(demo), demo: demo),
          ),
      ],
    ),
  ],
);

enum _Demo {
  preview('Preview'),
  panel('Panel'),
  panelMany('Panel 1,000 ops'),
  rootParent('Root parent'),
  stale('Stale'),
  noRunner('No runner');

  const _Demo(this.label);

  final String label;
}

class _DemoHost extends StatefulWidget {
  const _DemoHost({required this.demo, super.key});

  final _Demo demo;

  @override
  State<_DemoHost> createState() => _DemoHostState();
}

class _DemoHostState extends State<_DemoHost> {
  late final UndoTimelineModel _model;
  late final _DemoActions? _actions;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    final List<Operation> operations = switch (widget.demo) {
      _Demo.panelMany => demoOperations(now, 1000),
      _Demo.rootParent => <Operation>[demoOperation(now, 0, parent: _rootId), demoRoot(now)],
      _ => demoOperations(now, 12),
    };
    _model = UndoTimelineModel(_DemoSource(operations, stale: widget.demo == _Demo.stale), clock: () => now);
    _actions = widget.demo == _Demo.noRunner ? null : _DemoActions(redo: widget.demo == _Demo.panel);
  }

  @override
  void dispose() {
    _model.dispose();
    _actions?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ShellRailItem item = undoTimelineRailItem(context.l10n, _model, actions: _actions);
    return Center(
      child: widget.demo == _Demo.preview
          ? SizedBox(width: 290, child: RailPreview(item: item, closing: false))
          : SizedBox(
              width: 300,
              height: 640,
              child: PinnedPanel(item: item, onClose: () {}),
            ),
    );
  }
}

final String _rootId = '0' * 128;

/// Operation [i] of a demo log, newest first: every third a snapshot, the others a CLI command with its `args` tag.
Operation demoOperation(DateTime now, int i, {String? parent}) {
  const commands = <(String, String)>[
    ('new empty commit', 'jj new main'),
    ('squash commits into 3f9a0c1b', 'jj squash --into @-'),
    ('describe commit 7c2e91d4', "jj describe -m 'Graph lanes'"),
    ('fetch from git remote(s) origin', 'jj git fetch'),
    ('create bookmark feat/onboarding pointing to commit 9d1b20aa', 'jj bookmark create feat/onboarding'),
  ];
  final snapshot = i % 3 == 2;
  final (String description, String args) = commands[i % commands.length];
  return Operation(
    id: (0x1a2b3c4d5e6f + i * 7919).toRadixString(16).padRight(128, '0'),
    parentIds: <String>[parent ?? (0x1a2b3c4d5e6f + (i + 1) * 7919).toRadixString(16).padRight(128, '0')],
    timestampMillis: now.subtract(Duration(minutes: i * 23)).millisecondsSinceEpoch,
    tzOffsetMinutes: 60,
    user: 'ralph',
    host: 'mac',
    description: snapshot ? 'snapshot working copy' : description,
    rootOp: false,
    isSnapshot: snapshot,
    workspaceName: 'default',
    tags: snapshot ? const <OperationTag>[] : <OperationTag>[OperationTag(key: 'args', value: args)],
  );
}

/// [count] demo operations, newest first.
List<Operation> demoOperations(DateTime now, int count) => <Operation>[
  for (var i = 0; i < count; i++) demoOperation(now, i),
];

/// The root operation.
Operation demoRoot(DateTime now) => Operation(
  id: _rootId,
  parentIds: const <String>[],
  timestampMillis: 0,
  tzOffsetMinutes: 0,
  user: '',
  host: '',
  description: '',
  rootOp: true,
  isSnapshot: false,
);

class _DemoSource implements UndoTimelineSource {
  _DemoSource(this.operations, {required this.stale});

  final List<Operation> operations;
  final bool stale;

  @override
  Future<List<Operation>> opLog({required int limit}) async {
    if (stale) {
      throw const ZanshinFfiException('jj.stale_working_copy');
    }
    return operations.take(limit).toList();
  }

  @override
  Stream<RepoEvent> get events => const Stream<RepoEvent>.empty();
}

/// A runner that runs nothing: idle, with an own undo to redo when asked for one.
class _DemoActions extends ChangeNotifier implements UndoTimelineActions {
  _DemoActions({required bool redo})
    : redoable = redo ? const GraphOutcome(GraphUndo(GraphLoggedOperation('', 'new empty commit'))) : null;

  @override
  bool get actionsEnabled => true;

  @override
  final GraphOutcome? redoable;

  @override
  Future<GraphActionResult> undoOperation(String head, GraphLoggedOperation of) async =>
      const GraphActionDisabled(GraphDisabledReason.busy);

  @override
  Future<GraphActionResult> redoLast() async => const GraphActionDisabled(GraphDisabledReason.busy);

  @override
  Future<GraphActionResult> redoOperation(String head, GraphLoggedOperation of) async =>
      const GraphActionDisabled(GraphDisabledReason.busy);

  @override
  Future<GraphActionResult> restoreOperation(String operation) async =>
      const GraphActionDisabled(GraphDisabledReason.busy);
}
