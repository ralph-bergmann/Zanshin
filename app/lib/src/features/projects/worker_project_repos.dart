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

/// [ProjectRepos] over the worker isolate (Stories 11.5 and 11.6): detect, open, convert, init (the Git backend) and
/// clone pass through; a repository's changes are the worker's op-heads events for its handle, and a reading is one
/// `show` of @ and one topology call. The calls' warnings are logged by code; a creation's also reach the caller, on
/// [ProjectCreation] or on the [ZanshinFfiException] a failed one throws.
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

  /// `RepoBackend::Git` (the worker's `backend: 1`): the CLI's `jj git init`, never the native backend.
  static const _gitBackend = 1;

  @override
  Future<ProjectCreation> convert(String path) => _create('convert', (worker) => worker.convert(path));

  /// Init and clone run with `noColocate: true` — the `--no-colocate` commands the Projects window shows (Story 9.20).
  @override
  Future<ProjectCreation> init(String path) =>
      _create('init', (worker) => worker.initRepo(path, backend: _gitBackend, noColocate: true));

  @override
  Future<ProjectCreation> clone({required String url, required String destination}) =>
      _create('clone', (worker) => worker.cloneRepo(source: url, destination: destination, noColocate: true).result);

  /// Runs one creation [call]: its handle becomes a [ProjectRepo] like an opened one; a failure is rethrown with its
  /// warnings, which are logged by code either way.
  Future<ProjectCreation> _create(String call, Future<CreatedRepoHandle> Function(ZanshinWorker worker) create) async {
    final ZanshinWorker worker = await _worker;
    final CreatedRepoHandle handle;
    try {
      handle = await create(worker);
    } on ZanshinFfiException catch (error) {
      _logWarnings(call, error.warnings);
      rethrow;
    }
    _logWarnings(call, handle.warnings);
    return ProjectCreation(repo: _WorkerProjectRepo(worker, handle), warnings: handle.warnings);
  }
}

class _WorkerProjectRepo implements ProjectRepo {
  _WorkerProjectRepo(this._worker, this.handle);

  /// The bookmark revset of design question (b): @'s closest bookmarked ancestors.
  static const _bookmarkHeads = 'heads(::@ & bookmarks())';

  final ZanshinWorker _worker;

  @override
  final RepoHandle handle;

  @override
  Stream<void> get changes =>
      _worker.events.where((event) => event is OpHeadsChangedEvent && event.handleId == handle.handleId).map((_) {});

  @override
  Future<ProjectReading> read() async {
    try {
      // One `show` of @ gives its conflict state and its diff against the merged parents (the diff `status()` reports).
      final (ConflictState conflict, bool hasFileChanges) = await handle.show(revset: '@', limit: 1).then((entries) {
        _logWarnings('show', entries.warnings);
        return (entries.first.change.conflict, entries.first.fileChanges.isNotEmpty);
      });
      final GraphTopologyView heads = await handle.graphTopology(
        revset: _bookmarkHeads,
        anchors: const <String>[],
        withTimestamps: false,
      );
      _logWarnings('graph topology', heads.warnings);
      final ProjectStatus status = await statusFrom(
        conflict: conflict,
        hasFileChanges: hasFileChanges,
        headRefs: heads.refs,
        bookmarks: () async {
          final WarnedList<Bookmark> bookmarks = await handle.bookmarks(
            allRemotes: true,
            sort: const [BookmarkSortKey.name],
          );
          _logWarnings('bookmarks', bookmarks.warnings);
          return bookmarks;
        },
        pushRemotes: () async {
          try {
            final WarnedList<String> remotes = await handle.gitPushRemotes();
            _logWarnings('git push remotes', remotes.warnings);
            return remotes;
          } on ZanshinFfiException catch (error) {
            // A native-backend repo has no Git remotes to push to, as `jj git push` refuses it.
            if (error.code != 'jj.not_a_git_repo') {
              rethrow;
            }
            _logWarnings('git push remotes', error.warnings);
            return const <String>[];
          }
        },
      );
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
