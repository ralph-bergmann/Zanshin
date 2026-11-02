// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:widgetbook/widgetbook.dart';
import 'package:zanshin/src/features/graph/graph_ports.dart';
import 'package:zanshin/src/features/shell/pinned_panel.dart';
import 'package:zanshin/src/features/shell/rail_preview.dart';
import 'package:zanshin/src/features/shell/shell_controller.dart';
import 'package:zanshin/src/features/undo_timeline/operation_changes.dart';
import 'package:zanshin/src/features/undo_timeline/undo_timeline_model.dart';
import 'package:zanshin/src/features/undo_timeline/undo_timeline_view.dart';
import 'package:zanshin/src/l10n/strings.dart';
import 'package:zanshin_core/zanshin_core.dart';
import 'package:zanshin_settings/zanshin_settings.dart' show SettingsStore;

/// The "Undo Timeline" folder (Story 11.9): the rail item's hover preview and pinned panel over a fake op log and a
/// fake runner — the preview as the rail's callout (290 wide), the panel at the default 300. "Show changes" (Story
/// 10.29) shows the panel with an operation's view open, wider (420) for its diff.
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
  noRunner('No runner'),
  changes('Show changes');

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
  late final List<Operation> _operations;
  final _changes = _DemoChanges();
  final Directory _dir = Directory.systemTemp.createTempSync('zanshin_catalogue_undo_timeline');
  SettingsStore? _settings;
  OperationChangesModel? _open;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _operations = switch (widget.demo) {
      _Demo.panelMany => demoOperations(now, 1000),
      _Demo.rootParent => <Operation>[demoOperation(now, 0, parent: _rootId), demoRoot(now)],
      _ => demoOperations(now, 12),
    };
    _model = UndoTimelineModel(_DemoSource(_operations, stale: widget.demo == _Demo.stale), clock: () => now);
    _actions = widget.demo == _Demo.noRunner ? null : _DemoActions(redo: widget.demo == _Demo.panel);
    unawaited(_load());
  }

  Future<void> _load() async {
    final SettingsStore store = await SettingsStore.load(File('${_dir.path}/settings.json'));
    if (!mounted) {
      return;
    }
    setState(() {
      _settings = store;
      if (widget.demo == _Demo.changes) {
        _open = OperationChangesModel(_changes, operation: _operations[1].id, settings: store);
      }
    });
  }

  @override
  void dispose() {
    _open?.dispose();
    _model.dispose();
    _actions?.dispose();
    try {
      _dir.deleteSync(recursive: true);
    } on FileSystemException {
      // A catalogue temp dir; the system cleans it up otherwise.
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final SettingsStore? settings = _settings;
    if (settings == null) {
      return const SizedBox.shrink();
    }
    final ShellRailItem timeline = undoTimelineRailItem(
      context.l10n,
      _model,
      changes: _changes,
      settings: settings,
      actions: _actions,
    );
    final OperationChangesModel? open = _open;
    final item = open == null
        ? timeline
        : ShellRailItem(
            id: timeline.id,
            label: timeline.label,
            icon: timeline.icon,
            scrolls: true,
            preview: timeline.preview,
            panel: OperationChangesView(model: open, operation: _operations[1], onBack: () {}),
          );
    return Center(
      child: widget.demo == _Demo.preview
          ? SizedBox(width: 290, child: RailPreview(item: item, closing: false))
          : SizedBox(
              width: open == null ? 300 : 420,
              height: 640,
              child: PinnedPanel(item: item, onClose: () {}),
            ),
    );
  }
}

/// `jj op show` of a describe: one rewritten commit (its interdiff changes two files), the working copy moved, a
/// bookmark moved with it.
class _DemoChanges implements OperationChangesSource {
  static final String _new = '7c2e91d4'.padRight(40, '3');
  static final String _old = '5b0a77e2'.padRight(40, '9');
  static final String _wcOld = '1f4d6c08'.padRight(40, '0');

  @override
  Future<OpShow> opShow(String operation) async => OpShow(
    operation: demoOperation(DateTime.now(), 1),
    diff: OpDiff(
      commits: OpCommitsDiff(
        changes: <OpChangedCommit>[
          OpChangedCommit(
            commitId: _new,
            abandoned: false,
            addedCommitIds: <String>[_new],
            removedCommitIds: <String>[_old],
          ),
        ],
        elidedNewlyVisible: const RefDistance(lower: 0, upper: 0),
        elidedNewlyHidden: const RefDistance(lower: 2, upper: 2),
      ),
      workingCopies: <OpWorkingCopyChange>[OpWorkingCopyChange(workspace: 'default', from: _wcOld, to: _new)],
      localBookmarks: <OpRefChange>[
        OpRefChange(
          name: 'feat/lanes',
          from: OpRefTarget(adds: <String>[_old], removes: const <String>[], conflicted: false),
          to: OpRefTarget(adds: <String>[_new], removes: const <String>[], conflicted: false),
        ),
      ],
      localTags: const <OpRefChange>[],
      remoteBookmarks: const <OpRemoteRefChange>[],
      remoteTags: const <OpRemoteRefChange>[],
    ),
  );

  @override
  Future<List<ShowEntry>> show(String revset) async => <ShowEntry>[
    _entry('qpvuntsmwlqt', _new, 'Graph lanes\n'),
    _entry('qpvuntsmwlqt', _old, ''),
    _entry('zzmrkyvlxnop', _wcOld, 'Toolbar spacing\n'),
  ];

  static ShowEntry _entry(String change, String commit, String description) {
    const signature = Signature(name: 'Ralph', email: 'ralph@example.com', timestampMillis: 0, tzOffsetMinutes: 0);
    return ShowEntry(
      change: Change(
        id: change,
        commitId: commit,
        parents: const <String>[],
        description: description,
        author: signature,
        committer: signature,
        isSigned: false,
        conflict: ConflictState.clean,
        conflictedPaths: const <String>[],
        isAnonymous: false,
        divergent: false,
      ),
      fileChanges: const <FileChange>[],
    );
  }

  @override
  Future<Diff> diff({
    String? revision,
    String? from,
    String? to,
    bool interdiff = false,
    bool summary = false,
    List<String> paths = const <String>[],
  }) async {
    final files = <FileDiff>[
      _file('src/graph/lanes.dart', 'final lanes = <Lane>[];\n', 'final lanes = <Lane>[...seed];\n'),
      _file('README.md', 'Graph view.\n', 'Graph view with lanes.\n'),
    ];
    return Diff(
      files: <FileDiff>[
        for (final file in files)
          if (paths.isEmpty || paths.contains(file.path)) file,
      ],
      operationId: '',
      commitIds: <String>[?to],
      fromCommitId: from,
    );
  }

  static FileDiff _file(String path, String old, String now) => FileDiff(
    path: path,
    kind: FileChangeKind.modified,
    fromPath: null,
    binary: false,
    modeChange: false,
    sections: const <HunkKey>[],
    hunks: <Hunk>[
      Hunk(
        before: (start: 3, end: 4),
        after: (start: 3, end: 4),
        symbol: null,
        sections: const <HunkKey>[],
        removed: 1,
        added: 1,
        lines: <HunkLine>[
          const HunkLine(kind: HunkLineKind.context, text: '// lanes\n'),
          HunkLine(kind: HunkLineKind.removed, text: old),
          HunkLine(kind: HunkLineKind.added, text: now),
        ],
      ),
    ],
    removed: 1,
    added: 1,
    fingerprint: path,
  );
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
