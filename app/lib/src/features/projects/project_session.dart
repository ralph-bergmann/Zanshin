// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:zanshin_core/zanshin_core.dart';
import 'package:zanshin_settings/zanshin_settings.dart';

import 'project_registry.dart';
import 'project_repos.dart';

final _log = Logger('zanshin.projects');

/// How a call of [ProjectSession] that opens, adds or creates a project ended.
sealed class ProjectOpenOutcome {
  const ProjectOpenOutcome();
}

/// The project is open (it already was, or it is now); a creation's [warnings] came with it.
final class ProjectOpened extends ProjectOpenOutcome {
  /// The project is open; [warnings] are a creation's, in the CLI's print order (9.33), empty for an open.
  const ProjectOpened({this.warnings = const <ZanshinWarning>[]});

  /// What the creating call warned about, the messages verbatim; empty when there was nothing to report.
  final List<ZanshinWarning> warnings;
}

/// A creation that opened with warnings, for the project window's toast (Story 10.23, I2): Projects closes after
/// every open, so the project window reports them.
@immutable
class ProjectOpenReport {
  /// The project [name] opened with [warnings].
  const ProjectOpenReport({required this.name, required this.warnings});

  /// The project's name.
  final String name;

  /// The creation's warnings, in the CLI's print order.
  final List<ZanshinWarning> warnings;
}

/// An open of `path` made outside Projects that ended in `outcome` — a [ProjectOpenFailed], or a missing path — for
/// the Projects window's notice ([ProjectSession.failedOpen]).
typedef ProjectFailedOpen = ({String path, ProjectOpenOutcome outcome});

/// The jj workspace is in the registry at [path] without being opened ([ProjectSession.add]).
final class ProjectAdded extends ProjectOpenOutcome {
  /// The workspace is registered at [path].
  const ProjectAdded(this.path);

  /// The registry's key for it: the canonical path, or the spelling an existing entry already has.
  final String path;
}

/// The path holds no jj workspace: [kind] is `pathNotFound` (the project is missing), `git` (Projects offers the
/// conversion) or `neither` (Projects offers `jj git init`).
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

/// Detecting, opening or creating failed with [code] (`docs/rust-error-codes.md`); the current project stays.
final class ProjectOpenFailed extends ProjectOpenOutcome {
  /// The failure [code] with its [context] and the failed call's [warnings].
  const ProjectOpenFailed(this.code, this.context, {this.warnings = const <ZanshinWarning>[]});

  /// The error code, e.g. `jj.repo_not_found`.
  final String code;

  /// The error's detail (a path, for instance), or null.
  final String? context;

  /// What the failed call warned about before it failed (9.35), the messages verbatim.
  final List<ZanshinWarning> warnings;
}

/// The session refused before any jj call, with the jj CLI's [message] for the case — a clone into a folder that is
/// not empty, for instance.
final class ProjectRefused extends ProjectOpenOutcome {
  /// Refused with [message].
  const ProjectRefused(this.message);

  /// The CLI's refusal, verbatim.
  final String message;
}

/// The project the project window shows (Story 11.5 item 2; Story 11.6): opens, switches, creates and closes
/// repositories through [ProjectRepos] and keeps the registry's last known state of the open project current.
///
/// - **Paths** are registered canonical ([canonicalPath]: symlinks resolved); a path whose canonical form a registry
///   entry already has is that entry — never registered twice.
/// - **Open** detects first: a jj workspace opens; a missing path marks its entry `missing`; a Git repository, a
///   plain folder and a folder inside a repository are reported, never opened. A path the registry does not hold yet
///   is added when it opens — at the given group and index, else last at the top level (Claude's proposal).
/// - **Create** — [convert], [initRepo], [clone] — runs the creation without detecting again (the caller detected)
///   and switches to the new repository as an open does; the creation's warnings come with the outcome.
/// - **Switch** (Claude's proposal): the new handle opens and is read first, then [current] and [repo] switch to it
///   and listeners hear it, then the old handle closes. A failed open or creation changes nothing about the current
///   project.
/// - Opens, creations, closes and readings run one at a time, in call order.
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

  /// The registry the session records into.
  ProjectRegistry get registry => _registry;

  /// The Project menu's Recent: the open project first, then the others by last opened.
  List<ProjectEntry> get recent => _registry.recent(open: _path);

  /// The last failed open, until a project opens.
  ProjectOpenFailed? get lastFailure => _lastFailure;

  final _openReport = ValueNotifier<ProjectOpenReport?>(null);

  /// A creation's warnings, set when it opens with some, until [takeOpenReport] (Story 10.23).
  ValueListenable<ProjectOpenReport?> get openReport => _openReport;

  /// The pending [openReport], cleared: it is reported once.
  ProjectOpenReport? takeOpenReport() {
    final ProjectOpenReport? report = _openReport.value;
    _openReport.value = null;
    return report;
  }

  final _failedOpen = ValueNotifier<ProjectFailedOpen?>(null);

  /// A failed open made outside Projects — reopen-last, the Project menu's Recent — for the Projects window's notice
  /// (Ralph, 2026-11-01), until [takeFailedOpen].
  ValueListenable<ProjectFailedOpen?> get failedOpen => _failedOpen;

  /// Hands the open of [path] that ended in [outcome] to the Projects window's notice.
  void reportFailedOpen(String path, ProjectOpenOutcome outcome) {
    if (!_disposed) {
      _failedOpen.value = (path: path, outcome: outcome);
    }
  }

  /// The pending [failedOpen], cleared: it is shown once.
  ProjectFailedOpen? takeFailedOpen() {
    final ProjectFailedOpen? failed = _failedOpen.value;
    _failedOpen.value = null;
    return failed;
  }

  /// Opens the project at [path], switching from the open one; a path the registry does not hold yet is added at
  /// [index] in [group] (see [ProjectRegistry.add]).
  Future<ProjectOpenOutcome> open(String path, {String? group, int? index}) =>
      _serial(() => _open(path, group: group, index: index));

  /// Registers the jj workspace at [path] at [index] in [group] without opening it (several folders dropped at once):
  /// [ProjectAdded] for a workspace, or one listed already; any other path ends as [open] reports it.
  Future<ProjectOpenOutcome> add(String path, {String? group, int? index}) =>
      _serial(() => _add(path, group: group, index: index));

  /// Converts the Git repository at [path] to a colocated jj workspace (the CLI's `jj git init --colocate <path>`),
  /// registers it at [index] in [group] and opens it.
  Future<ProjectOpenOutcome> convert(String path, {String? group, int? index}) => _serial(
    () => _create('converting', path, _repos.convert, group: group, index: index),
  );

  /// Creates a jj repository in the folder [path] (the CLI's `jj git init --no-colocate <path>`), registers it at
  /// [index] in [group] and opens it.
  Future<ProjectOpenOutcome> initRepo(String path, {String? group, int? index}) => _serial(
    () => _create('creating', path, _repos.init, group: group, index: index),
  );

  /// Clones [url] into [destination] (the CLI's `jj git clone --no-colocate <url> <destination>`), registers the
  /// clone at [index] in [group] and opens it. The CLI's destination rules run here (`clone.rs:186-196`, `:259-270`
  /// @ v0.46.0): a folder that exists and is not empty is refused before any jj call, a missing one is created, and
  /// one created here is removed again when the clone fails.
  Future<ProjectOpenOutcome> clone({required String url, required String destination, String? group, int? index}) =>
      _serial(() => _clone(url, destination, group: group, index: index));

  /// Closes the open project (11.13 binds ⌘W to it; 11.12's close intercept runs it): the handle closes and no
  /// project is open.
  Future<void> closeProject() => _serial(_close);

  /// Reopens the project the registry says was open (the launch, item 2); nothing stored opens nothing. A stored
  /// path that holds no jj workspace (gone, Git, a folder, inside a repository) is no longer the open project; one
  /// whose open failed stays stored, so the next launch tries again, and goes to [failedOpen].
  Future<void> reopenLast() => _serial(() async {
    final String? stored = _registry.value.openProject;
    if (stored == null) {
      return;
    }
    switch (await _open(stored)) {
      case ProjectNotARepo() || ProjectInsideRepo():
        await _registry.setOpen(null);
      case final ProjectOpenFailed failed:
        reportFailedOpen(stored, failed);
      case ProjectOpened() || ProjectAdded() || ProjectRefused():
        break;
    }
  });

  /// The registry's key for [path]: the entry it already has, else its canonical form.
  String _target(String path) => _registry.registered(path)?.path ?? canonicalPath(path);

  Future<ProjectOpenOutcome> _open(String path, {String? group, int? index}) async {
    final String target = _target(path);
    if (_path == target && _repo != null) {
      return const ProjectOpened();
    }
    _log.fine('opening $target');
    final ProjectOpenOutcome? notOpened = await _detect(target);
    if (notOpened != null) {
      return notOpened;
    }
    final ProjectRepo repo;
    try {
      repo = await _repos.open(target);
    } on ZanshinFfiException catch (error, stack) {
      return _failed('opening', error, stack);
    }
    return _switchTo(repo, target, group: group, index: index);
  }

  Future<ProjectOpenOutcome> _add(String path, {String? group, int? index}) async {
    final ProjectEntry? listed = _registry.registered(path);
    if (listed != null) {
      return ProjectAdded(listed.path);
    }
    final String target = canonicalPath(path);
    _log.fine('adding $target');
    final ProjectOpenOutcome? notAdded = await _detect(target);
    if (notAdded != null) {
      return notAdded;
    }
    await _registry.add(target, group: group, index: index);
    return ProjectAdded(target);
  }

  /// Classifies [path]: null for a jj workspace, else how the call ends — a missing path marks its entry missing.
  Future<ProjectOpenOutcome?> _detect(String path) async {
    final RepoDetectResult detected;
    try {
      detected = await _repos.detect(path);
    } on ZanshinFfiException catch (error, stack) {
      return _failed('opening', error, stack);
    }
    switch (detected) {
      case RepoDetectResult(kind: RepoKind.jj):
        return null;
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
  }

  /// Runs the creation [create] ([doing] names it in the log) on [path] and switches to the new repository.
  Future<ProjectOpenOutcome> _create(
    String doing,
    String path,
    Future<ProjectCreation> Function(String path) create, {
    String? group,
    int? index,
  }) async {
    final String target = _target(path);
    _log.fine('$doing a project at $target');
    final ProjectCreation creation;
    try {
      creation = await create(target);
    } on ZanshinFfiException catch (error, stack) {
      return _failed(doing, error, stack);
    }
    return _switchTo(creation.repo, target, group: group, index: index, warnings: creation.warnings);
  }

  /// The jj CLI's refusal of a clone into a folder that is not empty (`clone.rs:190-192` @ v0.46.0).
  static const cloneDestinationNotEmpty =
      'Destination path exists and is not an empty directory'; // l10n-ignore: jj's text

  Future<ProjectOpenOutcome> _clone(String url, String destination, {String? group, int? index}) async {
    final String spelled = canonicalPath(destination);
    final dir = Directory(spelled);
    final FileSystemEntityType type = FileSystemEntity.typeSync(spelled);
    final existed = type != FileSystemEntityType.notFound;
    if (existed && !_isEmptyDirectory(dir, type)) {
      _log.fine('$spelled is not an empty folder');
      return const ProjectRefused(cloneDestinationNotEmpty);
    }
    try {
      dir.createSync(recursive: true);
    } on FileSystemException catch (error, stack) {
      _log
        ..warning('creating the clone destination failed: errno ${error.osError?.errorCode}')
        ..fine('create failure', error, stack);
      // The CLI's message with its cause (`user_error_with_message`, `clone.rs:194-195` @ v0.46.0).
      return ProjectRefused(
        'Failed to create $destination: ${error.osError?.message ?? error.message}', // l10n-ignore: jj's text
      );
    }
    // The registry's key when another spelling of the folder is listed (a missing entry, say), else its canonical form.
    final String target = _target(spelled);
    _log.fine('cloning $url into $target');
    final ProjectCreation creation;
    try {
      creation = await _repos.clone(url: url, destination: target);
    } on ZanshinFfiException catch (error, stack) {
      if (!existed) {
        _removeCreated(Directory(target));
      }
      return _failed('cloning', error, stack);
    }
    return _switchTo(creation.repo, target, group: group, index: index, warnings: creation.warnings);
  }

  static bool _isEmptyDirectory(Directory dir, FileSystemEntityType type) {
    if (type != FileSystemEntityType.directory) {
      return false;
    }
    try {
      return dir.listSync().isEmpty;
    } on FileSystemException {
      return false;
    }
  }

  /// Removes the clone destination this session created, as the CLI does after a failed clone (`fs::remove_dir`,
  /// `clone.rs:265-267`): only while it is empty again.
  void _removeCreated(Directory dir) {
    try {
      dir.deleteSync();
    } on FileSystemException catch (error, stack) {
      _log
        ..warning('removing the clone destination failed: errno ${error.osError?.errorCode}')
        ..fine('remove failure', error, stack);
    }
  }

  /// The switch both an open and a creation end in (11.5's order): [repo] is read, the reading recorded with [path]
  /// registered at [index] in [group], then [current] and [repo] switch and listeners hear it, then the old handle
  /// closes.
  Future<ProjectOpened> _switchTo(
    ProjectRepo repo,
    String path, {
    String? group,
    int? index,
    List<ZanshinWarning> warnings = const <ZanshinWarning>[],
  }) async {
    // Listening from the start: an operation that lands before the switch (the first reading's own snapshot, another
    // process) reads once more right after it.
    var changedEarly = false;
    _incoming = repo.changes.listen((_) {
      if (identical(repo, _repo)) {
        refresh();
      } else {
        changedEarly = true;
      }
    });
    final ProjectReading? reading = await _read(repo);
    await _registry.add(path, group: group, index: index);
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
    if (!_disposed) {
      // A later open without warnings drops an earlier project's report.
      _openReport.value = warnings.isEmpty
          ? null
          : ProjectOpenReport(name: _registry.entry(path)?.name ?? path, warnings: warnings);
    }
    _notify();
    if (changedEarly) {
      refresh();
    }
    if (old != null) {
      await _closeRepo(old);
    }
    return ProjectOpened(warnings: warnings);
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

  /// A failed detect, open or creation ([doing] names it): logged by its code, recorded as [lastFailure].
  ProjectOpenFailed _failed(String doing, ZanshinFfiException error, StackTrace stack) {
    _log
      ..warning('$doing a project failed: ${error.code}')
      ..fine('$doing failure', error, stack);
    final failure = ProjectOpenFailed(error.code, error.context, warnings: error.warnings);
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

  /// A jj operation landed in the open project, or its window turned active again: one more reading, unless one is
  /// already waiting its turn. Without an open project it reads nothing.
  void refresh() {
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
    _openReport.dispose();
    _failedOpen.dispose();
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
