// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:zanshin_core/zanshin_core.dart';
import 'package:zanshin_settings/zanshin_settings.dart';

import 'project_registry.dart';
import 'project_repos.dart';

final _log = Logger('zanshin.projects');

/// How [ProjectSession.open] ended.
sealed class ProjectOpenOutcome {
  const ProjectOpenOutcome();
}

/// The project is open (it already was, or it is now).
final class ProjectOpened extends ProjectOpenOutcome {
  /// The project is open.
  const ProjectOpened();
}

/// The path holds no jj workspace: [kind] is `pathNotFound` (the project is missing), `git` (11.6 offers the
/// conversion) or `neither` (refused).
final class ProjectNotARepo extends ProjectOpenOutcome {
  /// The path is of [kind].
  const ProjectNotARepo(this.kind);

  /// What detect found.
  final RepoKind kind;
}

/// The path lies inside the repository at [root], of [kind] (FR-JJ-14); the caller may offer it, the session never
/// opens it by itself.
final class ProjectInsideRepo extends ProjectOpenOutcome {
  /// The enclosing repository at [root].
  const ProjectInsideRepo(this.root, this.kind);

  /// The enclosing repository's root.
  final String root;

  /// The enclosing repository's kind.
  final RepoKind kind;
}

/// Detecting or opening failed with [code] (`docs/rust-error-codes.md`); the current project stays.
final class ProjectOpenFailed extends ProjectOpenOutcome {
  /// The failure [code] with its [context].
  const ProjectOpenFailed(this.code, this.context);

  /// The error code, e.g. `jj.repo_not_found`.
  final String code;

  /// The error's detail (a path, for instance), or null.
  final String? context;
}

/// The project the project window shows (Story 11.5 item 2): opens, switches and closes repositories through
/// [ProjectRepos] and keeps the registry's last known state of the open project current.
///
/// - **Open** detects first: a jj workspace opens; a missing path marks its entry `missing`; a Git repository, a
///   plain folder and a folder inside a repository are reported, never opened. A path the registry does not hold yet
///   is added at the top level when it opens (Claude's proposal).
/// - **Switch** (Claude's proposal): the new handle opens and is read first, then [current] and [repo] switch to it
///   and listeners hear it, then the old handle closes. A failed open changes nothing about the current project.
/// - Opens, closes and readings run one at a time, in call order.
/// - **Reading** the open project on opening and after every jj operation in it ([ProjectRepo.changes]); operations
///   during a reading coalesce into one more. Every reading records the status and the bookmark label in the
///   project's registry entry — the one [current] returns — so the open project and a stored one are the same
///   [ProjectEntry], and a switch or a close leaves the last reading in the entry. A stale reading keeps the bookmark
///   label; any other failed reading keeps the last state.
///
/// Paths, names and change ids are logged at FINE only; a WARNING carries the error code.
class ProjectSession extends ChangeNotifier {
  /// A session over a [ProjectRegistry] and [ProjectRepos]; [clock] stamps `lastOpened` (UTC is stored).
  ProjectSession({required this._registry, required this._repos, DateTime Function()? clock})
    : _clock = clock ?? DateTime.now {
    _registry.addListener(notifyListeners);
  }

  final ProjectRegistry _registry;
  final ProjectRepos _repos;
  final DateTime Function() _clock;

  ProjectRepo? _repo;
  String? _path;
  StreamSubscription<void>? _changes;

  /// The changes of a repository being opened, until it becomes the open one.
  StreamSubscription<void>? _incoming;
  ProjectOpenFailed? _lastFailure;
  var _refreshQueued = false;
  var _queue = Future<void>.value();
  var _disposed = false;

  /// The registry entry of the open project, or null when none is open.
  ProjectEntry? get current {
    final String? path = _path;
    return path == null ? null : _registry.entry(path);
  }

  /// The open repository, whose `handle` 10.5's graph reads through; null when none is open.
  ProjectRepo? get repo => _repo;

  /// The Project menu's Recent: the open project first, then the others by last opened.
  List<ProjectEntry> get recent => _registry.recent(open: _path);

  /// The last failed open, until a project opens.
  ProjectOpenFailed? get lastFailure => _lastFailure;

  /// Opens the project at [path], switching from the open one.
  Future<ProjectOpenOutcome> open(String path) => _serial(() => _open(path));

  /// Closes the open project (11.13 binds ⌘W to it; 11.12's close intercept runs it): the handle closes and no
  /// project is open.
  Future<void> closeProject() => _serial(_close);

  /// Reopens the project the registry says was open (the launch, item 2); nothing stored opens nothing. A stored
  /// path that holds no jj workspace (gone, Git, a folder, inside a repository) is no longer the open project; one
  /// whose open failed stays stored, so the next launch tries again.
  Future<void> reopenLast() => _serial(() async {
    final String? stored = _registry.value.openProject;
    if (stored == null) {
      return;
    }
    switch (await _open(stored)) {
      case ProjectNotARepo() || ProjectInsideRepo():
        await _registry.setOpen(null);
      case ProjectOpened() || ProjectOpenFailed():
        break;
    }
  });

  Future<ProjectOpenOutcome> _open(String path) async {
    if (_path == path && _repo != null) {
      return const ProjectOpened();
    }
    _log.fine('opening $path');
    final RepoDetectResult detected;
    try {
      detected = await _repos.detect(path);
    } on ZanshinFfiException catch (error, stack) {
      return _failed(error, stack);
    }
    switch (detected) {
      case RepoDetectResult(kind: RepoKind.jj):
        break;
      case RepoDetectResult(kind: RepoKind.pathNotFound):
        _log.fine('$path is missing');
        await _registry.recordState(path, ProjectStatus.missing, _registry.entry(path)?.bookmark);
        return const ProjectNotARepo(RepoKind.pathNotFound);
      case RepoDetectResult(
        kind: RepoKind.neither,
        suggestedRoot: final String root,
        suggestedKind: final RepoKind kind,
      ):
        _log.fine('$path lies inside $root');
        return ProjectInsideRepo(root, kind);
      case RepoDetectResult(:final RepoKind kind):
        _log.fine('$path is no jj workspace (${kind.name})');
        return ProjectNotARepo(kind);
    }
    final ProjectRepo repo;
    try {
      repo = await _repos.open(path);
    } on ZanshinFfiException catch (error, stack) {
      return _failed(error, stack);
    }
    // Listening from the start: an operation that lands before the switch (the first reading's own snapshot, another
    // process) reads once more right after it.
    var changedEarly = false;
    _incoming = repo.changes.listen((_) {
      if (identical(repo, _repo)) {
        _refresh();
      } else {
        changedEarly = true;
      }
    });
    final ProjectReading? reading = await _read(repo);
    await _registry.add(path);
    await _registry.recordOpened(path, at: _clock());
    if (reading != null) {
      await _record(path, reading);
    }
    await _registry.setOpen(path);
    final ProjectRepo? old = _repo;
    await _changes?.cancel();
    _repo = repo;
    _path = path;
    _lastFailure = null;
    _changes = _incoming;
    _incoming = null;
    _notify();
    if (changedEarly) {
      _refresh();
    }
    if (old != null) {
      await _closeRepo(old);
    }
    return const ProjectOpened();
  }

  Future<void> _close() async {
    final ProjectRepo? repo = _repo;
    if (repo == null) {
      return;
    }
    await _changes?.cancel();
    _changes = null;
    _repo = null;
    _path = null;
    await _registry.setOpen(null);
    _notify();
    await _closeRepo(repo);
  }

  /// Closes [repo]; a failure is logged, the project it belonged to is no longer open either way.
  Future<void> _closeRepo(ProjectRepo repo) async {
    try {
      await repo.close();
    } on ZanshinFfiException catch (error, stack) {
      _log
        ..warning('closing a project failed: ${error.code}')
        ..fine('close failure', error, stack);
    }
  }

  ProjectOpenFailed _failed(ZanshinFfiException error, StackTrace stack) {
    _log
      ..warning('opening a project failed: ${error.code}')
      ..fine('open failure', error, stack);
    final failure = ProjectOpenFailed(error.code, error.context);
    _lastFailure = failure;
    _notify();
    return failure;
  }

  Future<void> _record(String path, ProjectReading reading) => _registry.recordState(
    path,
    reading.status,
    reading.status == ProjectStatus.stale ? _registry.entry(path)?.bookmark : reading.bookmark,
  );

  /// One reading, or null when it failed (the last state stays).
  Future<ProjectReading?> _read(ProjectRepo repo) async {
    try {
      return await repo.read();
    } on ZanshinFfiException catch (error, stack) {
      _log
        ..warning('reading the open project failed: ${error.code}')
        ..fine('read failure', error, stack);
      return null;
    }
  }

  /// A jj operation landed in the open project: one more reading, unless one is already waiting its turn.
  void _refresh() {
    if (_refreshQueued) {
      return;
    }
    _refreshQueued = true;
    unawaited(
      _serial(() async {
        _refreshQueued = false;
        final ProjectRepo? repo = _repo;
        final String? path = _path;
        if (repo == null || path == null) {
          return;
        }
        final ProjectReading? reading = await _read(repo);
        if (reading == null || !identical(repo, _repo)) {
          return;
        }
        await _record(path, reading);
      }),
    );
  }

  Future<T> _serial<T>(Future<T> Function() task) {
    final Future<T> result = _queue.then((_) => task());
    // WHY: keep the chain alive after a failure — the error reaches this task's caller through `result`.
    _queue = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _registry.removeListener(notifyListeners);
    unawaited(_changes?.cancel());
    unawaited(_incoming?.cancel());
    final ProjectRepo? repo = _repo;
    if (repo != null) {
      unawaited(_closeRepo(repo));
    }
    super.dispose();
  }
}
