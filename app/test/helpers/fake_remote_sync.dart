// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:zanshin/src/features/sync/remote_sync.dart';
import 'package:zanshin_core/zanshin_core.dart';

/// [RemoteSync] for the sync tests (Story 11.8): scripted remotes, a log of every call (`fetch`, `changes <remote>`,
/// and each push's command, a dry run with ` --dry-run`), gates that hold a fetch, a poll or a real push, and
/// controllable progress. Never a real jj call.
class FakeRemoteSync implements RemoteSync {
  /// The default fetch remotes.
  var fetchRemoteNames = <String>['origin'];

  /// The default push remotes.
  var pushRemoteNames = <String>['origin'];

  /// Every remote.
  var names = <String>['origin'];

  /// The config the sheet names.
  var config = const PushConfig();

  /// Every call in order.
  final log = <String>[];

  /// What a fetch answers.
  GitFetchResult Function() fetchAnswer = fetchResult;

  /// While set, a fetch waits for it.
  Completer<void>? fetchGate;

  /// What a remote-change poll answers per remote; a remote not listed has none.
  final changes = <String, List<RemoteRefChange>>{};

  /// While set, a poll fails with it.
  ZanshinFfiException? changesError;

  /// While set, a poll waits for it.
  Completer<void>? changesGate;

  /// What a push answers (a dry run too).
  GitPushResult Function(PushRequest request) pushAnswer = (_) => pushResult(const <String, List<PushRef>>{});

  /// While set, a real push waits for it.
  Completer<void>? pushGate;

  late void Function(ProgressEvent event) _emit;

  /// Reports [event] as the latest call's progress.
  void emitProgress(ProgressEvent event) => _emit(event);

  /// The real pushes, in order.
  List<String> get pushes => <String>[
    for (final String entry in log)
      if (entry.startsWith('jj git push') && !entry.endsWith('--dry-run')) entry,
  ];

  @override
  Future<List<String>> fetchRemotes() async => fetchRemoteNames;

  @override
  Future<List<String>> pushRemotes() async => pushRemoteNames;

  @override
  Future<List<String>> remoteNames() async => names;

  @override
  Future<PushConfig> pushConfig() async => config;

  NetworkOperation<T> _operation<T>(Future<T> Function() run) {
    final controller = StreamController<ProgressEvent>();
    _emit = controller.add;
    // Not awaited: a progress stream nobody listens to never finishes closing.
    final Future<T> result = run().whenComplete(() => unawaited(controller.close()));
    return NetworkOperation<T>(result: result, progress: controller.stream, cancel: () async {});
  }

  @override
  NetworkOperation<GitFetchResult> fetch() {
    log.add('fetch');
    return _operation(() async {
      await fetchGate?.future;
      return fetchAnswer();
    });
  }

  @override
  NetworkOperation<WarnedList<RemoteRefChange>> remoteChanges(String remote) {
    log.add('changes $remote');
    return _operation(() async {
      await changesGate?.future;
      final ZanshinFfiException? error = changesError;
      if (error != null) {
        throw error;
      }
      return WarnedList<RemoteRefChange>(changes[remote] ?? const <RemoteRefChange>[], const <ZanshinWarning>[]);
    });
  }

  @override
  NetworkOperation<GitPushResult> push(PushRequest request) {
    log.add(request.toString());
    return _operation(() async {
      if (!request.dryRun) {
        await pushGate?.future;
      }
      return pushAnswer(request);
    });
  }
}

/// A fetch result changing [bookmarks] on [remotes].
GitFetchResult fetchResult({
  List<String> bookmarks = const <String>[],
  List<String> remotes = const <String>['origin'],
}) => GitFetchResult(
  mutation: const MutationResult(
    newOpId: 'op',
    newChangeIds: <String>[],
    abandonedChangeIds: <String>[],
    workingCopyChangeId: null,
    finish: null,
  ),
  remotes: remotes,
  hints: const <String>[],
  failedRefNames: const <String>[],
  changedBookmarks: <GitRefUpdate>[
    for (final String name in bookmarks)
      GitRefUpdate(name: name, remote: remotes.first, kind: GitRefUpdateKind.updated, tracked: true),
  ],
  changedTags: const <GitRefUpdate>[],
  numRewritten: 0,
);

/// A push result: each remote's [remotes] rows.
GitPushResult pushResult(
  Map<String, List<PushRef>> remotes, {
  bool nothingChanged = false,
  bool recorded = false,
  PushFailure? failure,
  List<PushCreatedBookmark> created = const <PushCreatedBookmark>[],
  Map<String, String> errors = const <String, String>{},
  Set<String> finished = const <String>{},
}) => GitPushResult(
  remotes: <PushRemote>[
    for (final MapEntry<String, List<PushRef>> remote in remotes.entries)
      PushRemote(
        name: remote.key,
        refs: remote.value,
        alreadyMatches: const <PushRefName>[],
        finished: finished.contains(remote.key),
        error: errors[remote.key],
      ),
  ],
  createdBookmarks: created,
  hints: const <String>[],
  nothingChanged: nothingChanged,
  dryRun: false,
  recorded: recorded,
  newOpId: 'pushop',
  description: 'push bookmark main to git remote origin',
  failure: failure,
);

/// One push row: [name] moved by [action], on [path].
PushRef pushRef(
  String name, {
  PushRefKind kind = PushRefKind.bookmark,
  PushPath path = PushPath.push,
  String? action = 'move forward from aaaaaaaaaaaa to bbbbbbbbbbbb',
  PushRefusal? refusal,
  PushRefusal? explicitRefusal,
  PushCommitRejection? rejection,
  PushRefStatus status = PushRefStatus.notReached,
  String? statusReason,
}) => PushRef(
  kind: kind,
  name: name,
  path: path,
  status: status,
  action: action,
  refusal: refusal,
  explicitRefusal: explicitRefusal,
  rejection: rejection,
  statusReason: statusReason,
);

/// jj's rejection of a commit for [reasons].
PushCommitRejection rejected(List<String> reasons) => PushCommitRejection(
  commitId: 'c' * 40,
  reasons: reasons,
  message: "Won't push commit cccccccccccc since it ${reasons.join(' and ')}",
);
