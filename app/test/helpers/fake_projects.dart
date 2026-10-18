// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:zanshin/src/features/projects/project_repos.dart';
import 'package:zanshin_core/zanshin_core.dart';
import 'package:zanshin_settings/zanshin_settings.dart';

/// [ProjectRepos] for the project tests: scripted detect results and failures, a log of every call in order
/// (`detect <path>`, `open <path>`, `convert <path>`, `init <path>`, `clone <url> <destination>`, `read <path>`,
/// `close <path>`), per creation its warnings or failure, and per repository its readings and a
/// [FakeProjectRepo.changes] the test drives.
class FakeProjectRepos implements ProjectRepos {
  /// What detect answers per path; a path not listed is a jj workspace.
  final detections = <String, RepoDetectResult>{};

  /// Paths whose detect throws.
  final detectFailures = <String, ZanshinFfiException>{};

  /// Paths whose open throws.
  final openFailures = <String, ZanshinFfiException>{};

  /// What a reading answers per path; a path not listed reads clean without a bookmark.
  final readings = <String, ProjectReading>{};

  /// Paths whose readings throw.
  final readFailures = <String, ZanshinFfiException>{};

  /// The warnings a successful creation at a path (a clone: at its destination) reports.
  final creationWarnings = <String, List<ZanshinWarning>>{};

  /// Paths (a clone: destinations) whose creation throws.
  final creationFailures = <String, ZanshinFfiException>{};

  /// While set, a clone waits for it before it answers (a test sees the busy form).
  Completer<void>? cloneGate;

  /// Runs during each reading, before it answers (a test emits a change from inside one).
  void Function(FakeProjectRepo repo)? onRead;

  /// Every call in order.
  final log = <String>[];

  /// The repositories opened, in order.
  final opened = <FakeProjectRepo>[];

  /// The latest repository opened at [path].
  FakeProjectRepo repoAt(String path) => opened.lastWhere((repo) => repo.path == path);

  @override
  Future<RepoDetectResult> detect(String path) async {
    log.add('detect $path');
    final ZanshinFfiException? failure = detectFailures[path];
    if (failure != null) {
      throw failure;
    }
    return detections[path] ?? const RepoDetectResult(kind: RepoKind.jj);
  }

  @override
  Future<ProjectRepo> open(String path) async {
    log.add('open $path');
    final ZanshinFfiException? failure = openFailures[path];
    if (failure != null) {
      throw failure;
    }
    final repo = FakeProjectRepo._(this, path);
    opened.add(repo);
    return repo;
  }

  @override
  Future<ProjectCreation> convert(String path) async {
    log.add('convert $path');
    return _created(path);
  }

  @override
  Future<ProjectCreation> init(String path) async {
    log.add('init $path');
    return _created(path);
  }

  @override
  Future<ProjectCreation> clone({required String url, required String destination}) async {
    log.add('clone $url $destination');
    await cloneGate?.future;
    return _created(destination);
  }

  ProjectCreation _created(String path) {
    final ZanshinFfiException? failure = creationFailures[path];
    if (failure != null) {
      throw failure;
    }
    final repo = FakeProjectRepo._(this, path);
    opened.add(repo);
    return ProjectCreation(repo: repo, warnings: creationWarnings[path] ?? const <ZanshinWarning>[]);
  }
}

/// One repository a [FakeProjectRepos] opened.
class FakeProjectRepo implements ProjectRepo {
  FakeProjectRepo._(this._repos, this.path);

  final FakeProjectRepos _repos;

  /// Where it was opened.
  final String path;

  /// Stays open after [close], as the worker's event stream does, so a test can emit on a closed repository and see
  /// that the session no longer listens.
  final _changes = StreamController<void>.broadcast(sync: true);

  /// How many readings it answered.
  var reads = 0;

  /// Whether it was closed.
  var closed = false;

  /// Reports a jj operation in this repository.
  void emitChange() => _changes.add(null);

  @override
  RepoHandle get handle => throw UnsupportedError('a fake repository has no worker handle');

  @override
  Stream<void> get changes => _changes.stream;

  @override
  Future<ProjectReading> read() async {
    _repos.log.add('read $path');
    reads++;
    _repos.onRead?.call(this);
    final ZanshinFfiException? failure = _repos.readFailures[path];
    if (failure != null) {
      throw failure;
    }
    return _repos.readings[path] ?? const ProjectReading(status: ProjectStatus.clean);
  }

  @override
  Future<void> close() async {
    _repos.log.add('close $path');
    closed = true;
  }

  /// Whether anyone listens to [changes].
  bool get listened => _changes.hasListener;
}
