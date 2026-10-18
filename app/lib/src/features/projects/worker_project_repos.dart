// SPDX-License-Identifier: MIT

import 'package:logging/logging.dart';
import 'package:zanshin_core/zanshin_core.dart';
import 'package:zanshin_settings/zanshin_settings.dart';

import 'project_repos.dart';

final _log = Logger('zanshin.projects');

/// Logs the codes of [warnings] from [call] at INFO — the code only, never the message, which may quote a path. Where
/// the warnings are shown is 10.5's design question (e).
void _logWarnings(String call, List<ZanshinWarning> warnings) {
  for (final warning in warnings) {
    _log.info('$call warned: ${warning.code}');
  }
}

/// [ProjectRepos] over the worker isolate (Story 11.5): detect and open pass through, a repository's changes are the
/// worker's op-heads events for its handle, and a reading is one `show` of @ and one topology call. The calls' warnings
/// are logged by code.
class WorkerProjectRepos implements ProjectRepos {
  /// Repositories through [_worker], the boot's worker.
  WorkerProjectRepos(this._worker);

  final Future<ZanshinWorker> _worker;

  @override
  Future<RepoDetectResult> detect(String path) async {
    final RepoDetectResult detected = await (await _worker).detect(path);
    _logWarnings('detect', detected.warnings);
    return detected;
  }

  @override
  Future<ProjectRepo> open(String path) async {
    final ZanshinWorker worker = await _worker;
    final OpenedRepoHandle handle = await worker.openRepo(path);
    _logWarnings('open', handle.warnings);
    return _WorkerProjectRepo(worker, handle);
  }
}

class _WorkerProjectRepo implements ProjectRepo {
  _WorkerProjectRepo(this._worker, this.handle);

  /// The bookmark revset of design question (b): @'s closest bookmarked ancestors.
  static const _bookmarkHeads = 'heads(::@ & bookmarks())';

  final ZanshinWorker _worker;

  @override
  final OpenedRepoHandle handle;

  @override
  Stream<void> get changes =>
      _worker.events.where((event) => event is OpHeadsChangedEvent && event.handleId == handle.handleId).map((_) {});

  @override
  Future<ProjectReading> read() async {
    try {
      // One `show` of @ gives its conflict state and its diff against the merged parents (the diff `status()` reports).
      final ProjectStatus status = await handle.show(revset: '@', limit: 1).then((entries) {
        _logWarnings('show', entries.warnings);
        return statusOf(
          conflict: entries.first.change.conflict,
          hasFileChanges: entries.first.fileChanges.isNotEmpty,
        );
      });
      final GraphTopologyView heads = await handle.graphTopology(
        revset: _bookmarkHeads,
        anchors: const <String>[],
        withTimestamps: false,
      );
      _logWarnings('graph topology', heads.warnings);
      return ProjectReading(status: status, bookmark: bookmarkLabel(heads.refs));
    } on ZanshinFfiException catch (error) {
      if (isStale(error)) {
        return const ProjectReading(status: ProjectStatus.stale);
      }
      rethrow;
    }
  }

  @override
  Future<void> close() => handle.close();
}
