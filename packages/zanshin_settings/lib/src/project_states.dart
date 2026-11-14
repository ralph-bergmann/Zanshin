// SPDX-License-Identifier: MIT

part of 'settings_store.dart';

const _legacyStateKeys = <String>['viewedFiles', 'expandedStacks', 'collapsedStacks'];

/// The view state files of the registered projects (Story 10.37): one `<directory>/<stateId>.json` per project, named
/// by its [ProjectEntry.stateId]. A path outside the registry has none.
class ProjectStates {
  ProjectStates._(this._settings);

  final SettingsStore _settings;
  final _stores = <String, ProjectStateStore>{};
  // The ids given to entries whose settings write is still pending, by path.
  final _pending = <String, String>{};
  final _random = math.Random.secure();

  /// `projects/` beside `settings.json`.
  Directory get directory => Directory(p.join(_settings.file.parent.path, 'projects'));

  File _fileOf(String stateId) => File(p.join(directory.path, '$stateId.json'));

  /// The view state of the project registered at [path], or null when no project is registered there. The first call
  /// for an entry without a [ProjectEntry.stateId] gives it one; that settings write runs in a microtask, so a caller
  /// inside a build or a listener never notifies the settings' listeners.
  ProjectStateStore? of(String path) {
    final ProjectEntry? entry = _settings.value.projects.projects.where((e) => e.path == path).firstOrNull;
    if (entry == null) {
      return null;
    }
    final String id = entry.stateId ?? _pending[path] ?? _assign(path);
    return _stores[id] ??= _open(id, entry);
  }

  String _assign(String path) {
    final String id = _newId();
    _pending[path] = id;
    scheduleMicrotask(() {
      unawaited(
        _settings
            .update(
              (s) => s.copyWith(
                projects: s.projects.copyWith(
                  projects: <ProjectEntry>[
                    for (final ProjectEntry e in s.projects.projects)
                      if (e.path == path && e.stateId == null) e.copyWith(stateId: id) else e,
                  ],
                ),
              ),
            )
            // The store logs a failed write; the id holds for this session.
            .onError<FileSystemException>((_, _) {}),
      );
      // The entry holds the id now; a path removed and added again gets a new one.
      _pending.remove(path);
    });
    return id;
  }

  String _newId() => <String>[
    for (var i = 0; i < 8; i++) _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ].join();

  /// Deletes the state file [stateId] once its pending writes are done; its store writes nothing more. A missing file
  /// is fine.
  Future<void> delete(String stateId) async {
    _stores.remove(stateId)?._deleted = true;
    await _settings._queue;
    try {
      await _fileOf(stateId).delete();
    } on PathNotFoundException {
      // Never written.
    } on FileSystemException catch (error, stack) {
      _log
        ..warning('could not delete the view state file $stateId.json')
        ..fine('view state delete failure', error, stack);
    }
  }

  // The file's content, or for a missing file the lists the entry still holds from an old settings.json (a failed
  // migration), or nothing for an unreadable file.
  ProjectStateStore _open(String id, ProjectEntry entry) {
    final File file = _fileOf(id);
    var initial = ProjectState(
      viewedFiles: entry.viewedFiles,
      expandedStacks: entry.expandedStacks,
      collapsedStacks: entry.collapsedStacks,
    );
    if (file.existsSync()) {
      try {
        final Object? decoded = jsonDecode(file.readAsStringSync());
        if (decoded is! Map<String, Object?>) {
          throw const FormatException('top-level JSON value is not an object');
        }
        initial = ProjectState.fromJson(decoded);
      } on Exception catch (error, stack) {
        _log
          ..warning('the view state file $id.json is unreadable; starting empty')
          ..fine('view state decode failure', error, stack);
        initial = const ProjectState();
      }
    }
    return ProjectStateStore._(_settings, file, initial);
  }

  // Moves the view state lists of an old settings.json ([raw]) into the state files, then writes settings.json once
  // without them. A state file that already exists wins; a failed state write is logged and the lists stay in memory.
  Future<void> _migrate(Map<String, Object?> raw) async {
    final Object? registry = raw['projects'];
    final Object? entries = registry is Map<String, Object?> ? registry['projects'] : null;
    final bool legacy =
        entries is List<Object?> &&
        entries.any((e) => e is Map<String, Object?> && _legacyStateKeys.any(e.containsKey));
    if (!legacy) {
      return;
    }
    final projects = <ProjectEntry>[];
    for (final ProjectEntry entry in _settings.value.projects.projects) {
      if (entry.viewedFiles.isEmpty && entry.expandedStacks.isEmpty && entry.collapsedStacks.isEmpty) {
        projects.add(entry);
        continue;
      }
      final String id = entry.stateId ?? _newId();
      final File file = _fileOf(id);
      if (!file.existsSync()) {
        final state = ProjectState(
          viewedFiles: entry.viewedFiles,
          expandedStacks: entry.expandedStacks,
          collapsedStacks: entry.collapsedStacks,
        );
        try {
          await writeJsonFile(file, state.toJson());
        } on FileSystemException catch (error, stack) {
          _log
            ..warning('could not write the view state file $id.json; its lists stay in memory')
            ..fine('view state write failure', error, stack);
        }
      }
      projects.add(entry.copyWith(stateId: id));
    }
    final AppSettings next = _settings.value.copyWith(projects: _settings.value.projects.copyWith(projects: projects));
    _settings._notifier.value = next;
    try {
      await _settings._write(next);
    } on FileSystemException {
      // Logged by _write; the next settings write drops the lists.
    }
  }
}

/// One project's view state, cached in memory and stored in [file] (Story 10.37).
///
/// [update] notifies listeners at once and queues an atomic write behind the settings' writes (so
/// [SettingsStore.settled] covers it); a failed write is logged and the value kept. A deleted store
/// ([ProjectStates.delete]) writes nothing.
class ProjectStateStore implements ValueListenable<ProjectState> {
  ProjectStateStore._(this._settings, this.file, ProjectState initial) : _notifier = ValueNotifier(initial);

  final SettingsStore _settings;

  /// The file this store persists to.
  final File file;

  final ValueNotifier<ProjectState> _notifier;
  var _deleted = false;

  @override
  ProjectState get value => _notifier.value;

  @override
  void addListener(VoidCallback listener) => _notifier.addListener(listener);

  @override
  void removeListener(VoidCallback listener) => _notifier.removeListener(listener);

  /// Applies [change] to [value], notifies listeners synchronously and queues a write; the returned future completes
  /// when it has finished, never with an error. A [change] that returns the current value is a no-op.
  Future<void> update(ProjectState Function(ProjectState current) change) {
    final ProjectState next = change(_notifier.value);
    if (next == _notifier.value) {
      return Future<void>.value();
    }
    _notifier.value = next;
    // WHY: the queue is shared with settings.json; an unexpected error must not fail later writes or `settled`.
    final Future<void> write = _settings._queue.then((_) => _write(next)).catchError((Object _) {});
    return _settings._queue = write;
  }

  Future<void> _write(ProjectState state) async {
    if (_deleted) {
      return;
    }
    try {
      await writeJsonFile(file, state.toJson());
    } on FileSystemException catch (error, stack) {
      _log
        ..warning('could not write the view state file ${file.uri.pathSegments.last}')
        ..fine('view state write failure', error, stack);
    }
  }
}
