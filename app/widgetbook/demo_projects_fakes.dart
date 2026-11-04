// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:zanshin/src/features/projects/project_registry.dart';
import 'package:zanshin/src/features/projects/project_repos.dart';
import 'package:zanshin/src/features/projects/project_session.dart';
import 'package:zanshin/src/features/projects/projects_environment.dart';
import 'package:zanshin/src/features/projects/projects_window.dart';
import 'package:zanshin_core/zanshin_core.dart';
import 'package:zanshin_settings/zanshin_settings.dart';
import 'package:zanshin_shell/zanshin_shell.dart';

/// The Projects window demo's registry under [home] (Claude's proposal; names from the floating export's
/// design/data.js:305-338): nested groups, every status, a missing project, long names and a project without a
/// bookmark.
ProjectsSettings demoProjectsSettings(String home) {
  final now = DateTime.now();
  return ProjectsSettings(
    groups: const <ProjectGroup>[
      ProjectGroup(id: 'g1', name: 'Work'),
      ProjectGroup(id: 'g2', name: 'Mobile', parent: 'g1'),
      ProjectGroup(id: 'g3', name: 'Backend', parent: 'g1', order: 1),
      ProjectGroup(id: 'g4', name: 'Personal', order: 1),
    ],
    projects: <ProjectEntry>[
      ProjectEntry(
        path: '$home/code/work/mobile/myapp',
        name: 'MyApp',
        group: 'g2',
        status: ProjectStatus.dirty,
        bookmark: 'feature/new-ui',
        lastOpened: now,
      ),
      ProjectEntry(
        path: '$home/code/work/mobile/design-kit',
        name: 'design-kit',
        group: 'g2',
        order: 1,
        status: ProjectStatus.stale,
        lastOpened: now.subtract(const Duration(days: 5)),
      ),
      ProjectEntry(
        path: '$home/code/work/backend/api-server',
        name: 'api-server',
        group: 'g3',
        status: ProjectStatus.ahead,
        bookmark: 'develop',
        lastOpened: now.subtract(const Duration(hours: 2)),
      ),
      ProjectEntry(
        path: '$home/code/work/backend/workers-for-the-queue-that-retries-after-a-dropped-connection',
        name: 'workers-for-the-queue-that-retries-after-a-dropped-connection',
        group: 'g3',
        order: 1,
        status: ProjectStatus.conflict,
        bookmark: 'fix/queue-retries-after-a-dropped-connection',
        lastOpened: now.subtract(const Duration(days: 1, hours: 2)),
      ),
      ProjectEntry(
        path: '$home/code/work/backend/billing',
        name: 'billing',
        group: 'g3',
        order: 2,
        status: ProjectStatus.diverged,
        bookmark: 'release/2.4',
        lastOpened: now.subtract(const Duration(days: 3)),
      ),
      ProjectEntry(
        path: '$home/code/work/infra',
        name: 'infra',
        group: 'g1',
        order: 2,
        bookmark: 'main',
        lastOpened: now.subtract(const Duration(days: 40)),
      ),
      ProjectEntry(
        path: '$home/code/dotfiles',
        name: 'dotfiles',
        group: 'g4',
        status: ProjectStatus.behind,
        bookmark: 'main',
        lastOpened: now.subtract(const Duration(days: 400)),
      ),
      ProjectEntry(
        path: '$home/code/old-prototype',
        name: 'old-prototype',
        group: 'g4',
        order: 1,
        status: ProjectStatus.missing,
        bookmark: 'main',
      ),
      ProjectEntry(path: '$home/code/zanshin', name: 'zanshin', order: 2, status: ProjectStatus.clean),
    ],
  );
}

/// The demo's open project under [home].
String demoOpenProject(String home) => '$home/code/work/mobile/myapp';

/// The demo's Git repository under [home], which Add directory offers to convert.
String demoGitRepository(String home) => '$home/code/legacy-git';

/// [ProjectRepos] for the catalogue: [demoGitRepository] is a Git repository, a path under `plain` a plain folder,
/// everything else a jj workspace; creations succeed (a clone after [cloneGate], when set) and read clean.
class DemoProjectRepos implements ProjectRepos {
  /// Repositories under [home].
  DemoProjectRepos(this.home);

  /// The demo's home folder.
  final String home;

  /// While set, a clone waits for it (the busy form).
  Completer<void>? cloneGate;

  @override
  Future<RepoDetectResult> detect(String path) async {
    if (path == demoGitRepository(home)) {
      return const RepoDetectResult(kind: RepoKind.git);
    }
    if (path.contains('/plain')) {
      return const RepoDetectResult(kind: RepoKind.neither);
    }
    return const RepoDetectResult(kind: RepoKind.jj);
  }

  @override
  Future<ProjectRepo> open(String path) async => _DemoRepo();

  @override
  Future<ProjectCreation> convert(String path) async => ProjectCreation(repo: _DemoRepo());

  @override
  Future<ProjectCreation> init(String path) async => ProjectCreation(repo: _DemoRepo());

  @override
  Future<ProjectCreation> clone({required String url, required String destination, CloneTicket? ticket}) async {
    await cloneGate?.future;
    return ProjectCreation(repo: _DemoRepo());
  }
}

class _DemoRepo implements ProjectRepo {
  @override
  RepoHandle get handle => throw UnsupportedError('the catalogue has no worker');

  @override
  Stream<void> get changes => const Stream<void>.empty();

  @override
  Stream<RepoEvent> get events => const Stream<RepoEvent>.empty();

  @override
  Future<ProjectReading> read() async => const ProjectReading(status: ProjectStatus.dirty, bookmark: 'feature/new-ui');

  @override
  Future<void> trackBookmarks(List<String> symbols) async {}

  @override
  Future<void> close() async {}
}

/// [ProjectsEnvironment] for the catalogue: fixed versions and [identity], the real folder picker and Reveal in
/// Finder (`ZanshinShell`), and [home].
class DemoProjectsEnvironment implements ProjectsEnvironment {
  /// The demo environment under [home] with [identity].
  DemoProjectsEnvironment(this.home, {JjIdentity? identity})
    : _identity = identity ?? JjIdentity(name: 'Ralph Stein', email: 'ralph@example.com');

  final JjIdentity _identity;

  @override
  final String home;

  @override
  Future<String?> appVersion() async => '2026.9.1 · Build 1';

  @override
  Future<String?> jjLibVersion() async => '0.46.0';

  @override
  Future<JjIdentity> identity({String? workspaceRoot}) async => _identity;

  @override
  Future<String?> chooseDirectory({required int viewId, String? initialDirectory, String? prompt}) =>
      ZanshinShell.chooseDirectory(viewId: viewId, initialDirectory: initialDirectory, prompt: prompt);

  @override
  Future<void> revealInFinder(String path) => ZanshinShell.revealInFinder(path);

  /// The demo's jj config, in memory: the user scope's and the repo scope's values as TOML text, by name.
  final config = <ConfigScope, Map<String, String>>{
    ConfigScope.user: <String, String>{'user.name': '"Ralph Stein"', 'user.email': '"ralph@example.com"'},
    ConfigScope.repo: <String, String>{'revset-aliases."trunk()"': '"main@origin"'},
  };

  final _writes = ConfigWrites();

  @override
  Listenable get configWrites => _writes;

  @override
  Future<List<ConfigEntry>> configList({required String name, String? workspaceRoot}) async => <ConfigEntry>[
    for (final ConfigScope scope in <ConfigScope>[ConfigScope.user, if (workspaceRoot != null) ConfigScope.repo])
      if (config[scope]?[name] case final String value)
        ConfigEntry(
          name: name,
          value: value,
          source: scope == ConfigScope.user ? ConfigValueSource.user : ConfigValueSource.repo,
          path: await configPath(scope),
          overridden: false,
        ),
  ];

  @override
  Future<ConfigSetResult> configSet(ConfigScope scope, String name, String value, {String? workspaceRoot}) async {
    // The demo stores strings quoted, as `jj config list` reads them back.
    (config[scope] ??= <String, String>{})[name] = value.startsWith('"') || value.startsWith('[') ? value : '"$value"';
    _writes.fire();
    return ConfigSetResult(path: await configPath(scope), workingCopyAuthor: null, precondition: null);
  }

  @override
  Future<void> configUnset(ConfigScope scope, String name, {String? workspaceRoot}) async {
    config[scope]?.remove(name);
    _writes.fire();
  }

  @override
  Future<String> configPath(ConfigScope scope, {String? workspaceRoot}) async => switch (scope) {
    ConfigScope.user => '$home/.config/jj/config.toml',
    ConfigScope.repo || ConfigScope.workspace => '$home/.config/jj/repos/1f3a/config.toml',
  };
}

/// The Projects window's content over the demo: a temp-folder settings store holding [demoProjectsSettings] (or none
/// when [empty]), [DemoProjectRepos] and [DemoProjectsEnvironment] with [identity]; it opens [demoOpenProject] and
/// then runs [setup] on the content's state (the catalogue's states). [busyClone] holds every clone.
class DemoProjectsWindow extends StatefulWidget {
  /// The demo content.
  const DemoProjectsWindow({this.empty = false, this.identity, this.setup, this.busyClone = false, super.key});

  /// Whether the registry is empty.
  final bool empty;

  /// The identity the footer shows; Ralph's when null.
  final JjIdentity? identity;

  /// Runs on the content's state once the demo project is open.
  final void Function(ProjectsWindowState state, String home)? setup;

  /// Whether a clone never finishes (the busy form).
  final bool busyClone;

  @override
  State<DemoProjectsWindow> createState() => _DemoProjectsWindowState();
}

class _DemoProjectsWindowState extends State<DemoProjectsWindow> {
  final _content = GlobalKey<ProjectsWindowState>();
  late final Directory _dir = Directory.systemTemp.createTempSync('zanshin_catalogue_projects');
  late final String _home = _dir.resolveSymbolicLinksSync();
  late final _repos = DemoProjectRepos(_home)..cloneGate = widget.busyClone ? Completer<void>() : null;
  ProjectSession? _session;
  ProjectRegistry? _registry;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final SettingsStore store = await SettingsStore.load(File('${_dir.path}/settings.json'));
    if (!widget.empty) {
      // The demo's writes go to the temp folder; a failed one changes nothing the demo shows.
      unawaited(
        store
            .update((settings) => settings.copyWith(projects: demoProjectsSettings(_home)))
            .onError<FileSystemException>((_, _) {}),
      );
    }
    if (!mounted) {
      return;
    }
    final registry = ProjectRegistry(store);
    final session = ProjectSession(registry: registry, repos: _repos);
    setState(() {
      _registry = registry;
      _session = session;
    });
    if (!widget.empty) {
      await session.open(demoOpenProject(_home));
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ProjectsWindowState? state = _content.currentState;
      if (mounted && state != null) {
        widget.setup?.call(state, _home);
      }
    });
  }

  @override
  void dispose() {
    _session?.dispose();
    try {
      _dir.deleteSync(recursive: true);
    } on FileSystemException {
      // A write still under way; the temp folder goes with the system's clean-up.
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ProjectSession? session = _session;
    final ProjectRegistry? registry = _registry;
    if (session == null || registry == null) {
      return const SizedBox.expand();
    }
    return ProjectsWindow(
      key: _content,
      session: session,
      registry: registry,
      environment: DemoProjectsEnvironment(_home, identity: widget.identity),
      onIdentitySettings: () {},
    );
  }
}
