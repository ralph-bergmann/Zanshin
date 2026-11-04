// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:widgetbook/widgetbook.dart';
import 'package:zanshin/src/features/graph/graph_layout.dart';
import 'package:zanshin/src/features/graph/graph_view_model.dart';
import 'package:zanshin/src/features/graph/recorded_graph_layout.dart';
import 'package:zanshin/src/features/shell/shell_toast.dart';
import 'package:zanshin/src/features/sync/push_sheet.dart';
import 'package:zanshin/src/features/sync/push_sheet_model.dart';
import 'package:zanshin/src/features/sync/remote_sync.dart';
import 'package:zanshin/src/features/sync/sync_island.dart';
import 'package:zanshin/src/features/sync/sync_model.dart';
import 'package:zanshin_core/zanshin_core.dart';
import 'package:zanshin_settings/zanshin_settings.dart' show RemotePollSetting;

import '../graph/fake_graph_source.dart';

/// The "Sync" folder (Story 11.8): the top bar's sync island in its states, and the Push sheet (DS
/// components/push/PushDialog) over demo dry-run plans — the preselection with a skipped ref and a tag, two remotes,
/// the change row with its inline Allow, and a push that failed in part.
final syncFolder = WidgetbookFolder(
  name: 'Sync',
  children: <WidgetbookNode>[
    WidgetbookComponent(
      name: 'Sync island',
      useCases: <WidgetbookUseCase>[
        WidgetbookUseCase(name: 'States', builder: (context) => const _IslandStates()),
      ],
    ),
    WidgetbookComponent(
      name: 'Push sheet',
      useCases: <WidgetbookUseCase>[
        for (final _Sheet sheet in _Sheet.values)
          WidgetbookUseCase(
            name: sheet.label,
            builder: (context) => _SheetHost(key: ValueKey<_Sheet>(sheet), sheet: sheet),
          ),
      ],
    ),
  ],
);

enum _Sheet {
  preselection('Preselection'),
  remotes('Two remotes'),
  change('Change allowed'),
  done('Done in part'),
  gitSwitcher('Git switcher');

  const _Sheet(this.label);

  final String label;
}

PushRef _ref(
  String name, {
  PushRefKind kind = PushRefKind.bookmark,
  PushPath path = PushPath.push,
  String action = 'move forward from 4c1d0e2a9b77 to 9e8f7a6b5c4d', // l10n-ignore: demo data
  PushRefusal? refusal,
  PushRefusal? explicitRefusal,
  PushCommitRejection? rejection,
  PushRefStatus status = PushRefStatus.notReached,
  String? statusReason,
  String? before,
  String? after,
  String? beforeChangeId,
  String? afterChangeId,
}) => PushRef(
  kind: kind,
  name: name,
  path: path,
  action: action,
  before: before,
  after: after,
  beforeChangeId: beforeChangeId,
  beforeChangePrefixLen: beforeChangeId == null ? 0 : 2,
  afterChangeId: afterChangeId,
  afterChangePrefixLen: afterChangeId == null ? 0 : 2,
  refusal: refusal,
  explicitRefusal: explicitRefusal,
  rejection: rejection,
  status: status,
  statusReason: statusReason,
);

/// `main` moved forward, with both change ids (Story 11.22).
PushRef _main({PushRefStatus status = PushRefStatus.notReached}) => _ref(
  'main',
  status: status,
  before: '4c1d0e2a9b77${'0' * 28}',
  after: '9e8f7a6b5c4d${'0' * 28}',
  beforeChangeId: 'qpvuntsmwlqtpsluzzsnyyzlmlwvmlnu', // l10n-ignore: demo data
  afterChangeId: 'ksxypqwmzzzzzzzzzzzzzzzzzzzzzzzz', // l10n-ignore: demo data
);

PushCommitRejection _noDescription(String commit, {bool workingCopy = false}) => PushCommitRejection(
  commitId: commit,
  reasons: const <String>['has no description'], // l10n-ignore: jj's text
  reasonKinds: const <PushRejectReason>[PushRejectReason.noDescription],
  workingCopy: workingCopy,
  message: "Won't push commit ${commit.substring(0, 12)} since it has no description", // l10n-ignore: jj's text
);

/// A Git switcher's first push (Story 11.22): `main` beside an untracked `main@origin`, a new local bookmark `fresh`,
/// and an undescribed @; Track turns `main` into a forward move.
GitPushResult _gitSwitcherPlan(PushRequest request, {required bool tracked}) {
  const untracked = PushRefusal(
    kind: PushRefusalKind.remoteUntracked,
    message: 'Non-tracking remote bookmark main@origin exists', // l10n-ignore: jj's text
    hint: 'Run `jj bookmark track main@origin` to import the remote bookmark.', // l10n-ignore: jj's text
  );
  if (request.changes.isNotEmpty || request.named.isNotEmpty) {
    return _result(
      <String, List<PushRef>>{
        'origin': <PushRef>[
          _ref(
            'push-ovknlmrozxyw',
            action: 'add to 7d6c5b4a3f2e', // l10n-ignore: demo data
            path: request.allowEmptyDescription ? PushPath.push : PushPath.abort,
            rejection: _noDescription('7d6c5b4a3f2e1d0c9b8a7f6e5d4c3b2a1f0e9d8c', workingCopy: true),
          ),
        ],
      },
      created: const <PushCreatedBookmark>[PushCreatedBookmark(name: 'push-ovknlmrozxyw', changeId: 'ovknlmro')],
    );
  }
  return _result(<String, List<PushRef>>{
    'origin': <PushRef>[
      if (tracked)
        _main()
      else
        _ref('main', action: '', path: PushPath.skip, refusal: untracked, explicitRefusal: untracked),
      if (request.mode == PushMode.bare)
        _ref(
          'fresh',
          action: 'add to 2d0dbb65bad8', // l10n-ignore: demo data
          path: PushPath.skip,
          refusal: const PushRefusal(
            kind: PushRefusalKind.newRemote,
            message: 'Refusing to create new remote bookmark fresh@origin', // l10n-ignore: jj's text
            hint: 'Run `jj bookmark track fresh@origin` and try again.', // l10n-ignore: jj's text
          ),
        )
      else if (request.mode == PushMode.all || request.mode == PushMode.custom)
        _ref('fresh', action: 'add to 2d0dbb65bad8'), // l10n-ignore: demo data
    ],
  });
}

GitPushResult _result(Map<String, List<PushRef>> remotes, {List<PushCreatedBookmark> created = const []}) =>
    GitPushResult(
      remotes: <PushRemote>[
        for (final MapEntry<String, List<PushRef>> remote in remotes.entries)
          PushRemote(name: remote.key, refs: remote.value, alreadyMatches: const <PushRefName>[], finished: false),
      ],
      createdBookmarks: created,
      hints: const <String>[],
      nothingChanged: false,
      dryRun: true,
      recorded: false,
      newOpId: 'op',
    );

/// Demo plans: `main` forward, `wip` skipped for its empty description, the tag `v1.5.0` new, `feature/ZAN-412`
/// sideways and new on upstream.
class _DemoSync implements RemoteSync {
  _DemoSync({this.names = const <String>['origin'], this.done = false, this.gitSwitcher = false});

  final List<String> names;
  final bool done;
  final bool gitSwitcher;
  var _tracked = false;

  @override
  Future<void> track(List<String> symbols) async => _tracked = true;

  NetworkOperation<T> _now<T>(T value) => NetworkOperation<T>(
    result: Future<T>.value(value),
    progress: const Stream<ProgressEvent>.empty(),
    cancel: () async {},
  );

  @override
  Future<List<String>> fetchRemotes() async => const <String>['origin'];

  @override
  Future<List<String>> pushRemotes() async => const <String>['origin'];

  @override
  Future<List<String>> remoteNames() async => names;

  @override
  Future<PushConfig> pushConfig() async => const PushConfig(gitPushRevset: 'remote_bookmarks(remote=origin)..@');

  @override
  NetworkOperation<GitFetchResult> fetch() => NetworkOperation<GitFetchResult>(
    result: Completer<GitFetchResult>().future,
    progress: const Stream<ProgressEvent>.empty(),
    cancel: () async {},
  );

  @override
  NetworkOperation<WarnedList<RemoteRefChange>> remoteChanges(String remote) => _now(
    WarnedList<RemoteRefChange>(const <RemoteRefChange>[
      RemoteRefChange(
        kind: RemoteRefKind.bookmark,
        name: 'main',
        change: RemoteRefChangeKind.moved,
        oldCommitIds: <String>['a'],
        newCommitId: 'b',
      ),
      RemoteRefChange(
        kind: RemoteRefKind.bookmark,
        name: 'feature-x',
        change: RemoteRefChangeKind.created,
        oldCommitIds: <String>[],
        newCommitId: 'c',
      ),
    ], const <ZanshinWarning>[]),
  );

  @override
  NetworkOperation<GitPushResult> push(PushRequest request) {
    final List<String> remotes = request.remotes ?? const <String>['origin'];
    if (gitSwitcher) {
      return _now(_gitSwitcherPlan(request, tracked: _tracked));
    }
    if (done && !request.dryRun) {
      return _now(
        GitPushResult(
          remotes: <PushRemote>[
            PushRemote(
              name: 'origin',
              refs: <PushRef>[
                _ref('main', status: PushRefStatus.pushed),
                _ref(
                  'feature/ZAN-412',
                  status: PushRefStatus.leaseRejected,
                  action: 'move sideways from 1a2b3c4d5e6f to 9e8f7a6b5c4d', // l10n-ignore: demo data
                ),
              ],
              alreadyMatches: const <PushRefName>[],
              finished: true,
            ),
          ],
          createdBookmarks: const <PushCreatedBookmark>[],
          hints: const <String>[],
          nothingChanged: false,
          dryRun: false,
          recorded: true,
          newOpId: 'op2',
          description: 'push bookmark main to git remote origin', // l10n-ignore: jj's text
          failure: const PushFailure(
            kind: PushFailureKind.someRefsFailed,
            message: 'Failed to push some bookmarks', // l10n-ignore: jj's text
            hint:
                'Try fetching from the remote, then make the bookmark point to where you want it to be, and push '
                'again.', // l10n-ignore: jj's text
          ),
        ),
      );
    }
    if (request.changes.isNotEmpty || request.named.isNotEmpty) {
      return _now(
        _result(
          <String, List<PushRef>>{
            for (final String remote in remotes)
              remote: <PushRef>[
                _ref(
                  'push-ovknlmrozxyw',
                  action: 'add to 7d6c5b4a3f2e', // l10n-ignore: demo data
                  path: request.allowEmptyDescription ? PushPath.push : PushPath.abort,
                  rejection: _noDescription('7d6c5b4a3f2e1d0c9b8a7f6e5d4c3b2a1f0e9d8c', workingCopy: true),
                ),
                for (final String name in request.bookmarks) _ref(name),
              ],
          },
          created: const <PushCreatedBookmark>[PushCreatedBookmark(name: 'push-ovknlmrozxyw', changeId: 'ovknlmro')],
        ),
      );
    }
    return _now(
      _result(<String, List<PushRef>>{
        for (final String remote in remotes)
          remote: switch (request.mode) {
            PushMode.deleted => const <PushRef>[],
            PushMode.tracked => <PushRef>[_main()],
            _ => <PushRef>[
              _main(),
              _ref(
                'wip',
                path: PushPath.skip,
                rejection: _noDescription('3f2e1d0c9b8a7f6e5d4c3b2a1f0e9d8c7b6a5f4e'),
              ),
              _ref(
                'feature/ZAN-412',
                action: remote == 'upstream'
                    ? 'add to 9e8f7a6b5c4d' // l10n-ignore: demo data
                    : 'move sideways from 1a2b3c4d5e6f to 9e8f7a6b5c4d', // l10n-ignore: demo data
              ),
              _ref('v1.5.0', kind: PushRefKind.tag, action: 'add to 9e8f7a6b5c4d'), // l10n-ignore: demo data
            ],
          },
      }),
    );
  }
}

/// The island in its states: idle, with the poll's badge, fetching, without a remote, stale.
class _IslandStates extends StatefulWidget {
  const _IslandStates();

  @override
  State<_IslandStates> createState() => _IslandStatesState();
}

class _IslandStatesState extends State<_IslandStates> {
  final _toasts = ShellToasts();
  final _graphs = <GraphViewModel>[];
  final _models = <SyncModel>[];

  SyncModel _model({bool stale = false, List<String> names = const <String>['origin']}) {
    final graph = GraphViewModel();
    if (stale) {
      graph.init(FakeGraphSource((_) => _emptyLayout(), staleCause: 'stale'));
    }
    _graphs.add(graph);
    final model = SyncModel(
      sync: _DemoSync(names: names),
      graph: graph,
      toasts: _toasts,
      pollSetting: () => RemotePollSetting.fiveMinutes,
    );
    _models.add(model);
    return model;
  }

  late final SyncModel _idle = _model();
  late final SyncModel _badge = _model()..poll();
  late final SyncModel _fetching = _model();
  late final SyncModel _none = _model(names: const <String>[]);
  late final SyncModel _stale = _model(stale: true);

  @override
  void initState() {
    super.initState();
    // After the remotes are read.
    unawaited(_fetching.reloadRemotes().then((_) => _fetching.fetch()));
  }

  @override
  void dispose() {
    for (final SyncModel model in _models) {
      model.dispose();
    }
    for (final GraphViewModel graph in _graphs) {
      graph.dispose();
    }
    _toasts.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      spacing: 16,
      children: <Widget>[
        for (final SyncModel model in <SyncModel>[_idle, _badge, _fetching, _none, _stale])
          SyncIsland(onReload: () {}, sync: model),
        const SyncIsland(onReload: null),
      ],
    ),
  );
}

GraphLayout _emptyLayout() => RecordedGraphLayout(
  mode: GraphMode.compact,
  unit: 1,
  rows: 0,
  colCount: 0,
  keys: const <String>[],
  cols: Int32List(0),
  nodeRows: Int32List(0),
  parentCounts: Int32List(0),
  elided: Uint8List(0),
  edgeChildren: Int32List(0),
  edgeParents: Int32List(0),
  edgeKinds: const <GraphEdgeKind>[],
  edgeShapes: const <GraphEdgeShape>[],
  operationId: 'op',
  commitIds: const <String>[],
  changeIdPrefixLengths: Int32List(0),
);

/// One Push sheet state over [_DemoSync].
class _SheetHost extends StatefulWidget {
  const _SheetHost({required this.sheet, super.key});

  final _Sheet sheet;

  @override
  State<_SheetHost> createState() => _SheetHostState();
}

class _SheetHostState extends State<_SheetHost> {
  late final PushSheetModel _model;

  @override
  void initState() {
    super.initState();
    final _Sheet sheet = widget.sheet;
    _model = PushSheetModel(
      sync: _DemoSync(
        names: sheet == _Sheet.remotes ? const <String>['origin', 'upstream'] : const <String>['origin'],
        done: sheet == _Sheet.done,
        gitSwitcher: sheet == _Sheet.gitSwitcher,
      ),
      change: (id: 'ovknlmro', rev: '@'),
      onPushed: (_) {},
    );
    unawaited(_play());
  }

  Future<void> _play() async {
    await _model.load();
    switch (widget.sheet) {
      case _Sheet.preselection || _Sheet.gitSwitcher:
        break;
      case _Sheet.remotes:
        _model.toggleRemote('upstream');
      case _Sheet.change:
        _model
          ..setAllow(PushAllow.emptyDescription, true)
          ..setChange(true);
      case _Sheet.done:
        // Once the command's dry run passed.
        final ready = Completer<void>();
        void check() {
          if (_model.canPush && !ready.isCompleted) {
            ready.complete();
          }
        }

        _model.addListener(check);
        check();
        await ready.future;
        _model.removeListener(check);
        await _model.push();
    }
  }

  @override
  void dispose() {
    _model.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PushSheet(model: _model);
}
