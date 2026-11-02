// SPDX-License-Identifier: MIT

// The windowing API is experimental and only reachable through implementation
// imports; see https://github.com/flutter/flutter/issues/30701.
// ignore_for_file: invalid_use_of_internal_member

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/src/foundation/_features.dart';
import 'package:flutter/src/widgets/_window.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/src/features/bootstrap/zanshin_bootstrap.dart';
import 'package:zanshin/src/features/projects/project_registry.dart';
import 'package:zanshin/src/features/projects/project_session.dart';
import 'package:zanshin/src/features/settings/settings_window_state.dart';
import 'package:zanshin/src/features/window/app_window_actions.dart';
import 'package:zanshin/src/features/window/app_window_coordinator.dart';
import 'package:zanshin/src/features/window/app_windows.dart';
import 'package:zanshin_core/zanshin_core.dart';
import 'package:zanshin_settings/zanshin_settings.dart';

import '../../helpers/fake_projects.dart';
import '../../helpers/fake_windows.dart';

/// How long `until` waits, in real time, for the coordinator's chains.
const _untilBudget = Duration(seconds: 10);

/// The project window's stand-in content.
class _ProjectContent extends StatelessWidget {
  const _ProjectContent();

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

/// The Projects window's stand-in content, with the `onOpened` the coordinator handed it.
class _ProjectsContent extends StatelessWidget {
  const _ProjectsContent(this.onOpened);

  final ValueChanged<ProjectOpened> onOpened;

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

/// One coordinator over fake windows, a session on fake repositories and a settings store in a temporary folder.
class _Rig {
  late final Directory dir;
  late final SettingsStore store;
  late final ProjectSession session;
  final repos = FakeProjectRepos();
  final factory = FakeWindowFactory();
  final registry = WindowRegistry();
  final exits = <String>[];
  late final AppWindows windows;
  late final AppWindowCoordinator coordinator;
  final channel = const MethodChannel('test/window_frames');

  /// The folders that exist, for the launch's check.
  final folders = <String>{};

  /// Every Projects content built, with its `onOpened`.
  final projectsContents = <_ProjectsContent>[];
  var projectContents = 0;
  var revsetConfigsContents = 0;
  var settingsContents = 0;

  Future<void> setUp({String? openProject}) async {
    dir = await Directory.systemTemp.createTemp('app_window_coordinator_test');
    addTearDown(() => dir.delete(recursive: true));
    store = await SettingsStore.load(File('${dir.path}/settings.json'));
    if (openProject != null) {
      await store.update(
        (settings) => settings.copyWith(
          projects: ProjectsSettings(
            projects: <ProjectEntry>[ProjectEntry(path: openProject, name: openProject.split('/').last)],
            openProject: openProject,
          ),
        ),
      );
    }
    session = ProjectSession(registry: ProjectRegistry(store), repos: repos);
    addTearDown(session.dispose);
    windows = AppWindows(createController: factory.call, exitProcess: () async => exits.add('exit'))..attach(registry);
    addTearDown(() {
      for (final WindowEntry entry in registry.windows) {
        entry.controller.destroy();
      }
      channel.setMethodCallHandler(null);
    });
    coordinator = AppWindowCoordinator(
      windows: windows,
      session: session,
      buildProject: () {
        projectContents++;
        return const _ProjectContent();
      },
      buildProjects: (onOpened) {
        final content = _ProjectsContent(onOpened);
        projectsContents.add(content);
        return content;
      },
      buildRevsetConfigs: () {
        revsetConfigsContents++;
        return const _ProjectContent();
      },
      buildSettings: (state) {
        settingsContents++;
        return const _ProjectContent();
      },
      folderExists: folders.contains,
      channel: channel,
    );
  }

  /// Starts the coordinator and opens its first window as the boot host does (created, registered), then runs its
  /// `onShown`; answers the first window.
  Future<BootFirstWindow> launch() async {
    final BootFirstWindow first = coordinator.start();
    final WindowEntry entry = switch (first.kind) {
      BootWindowKind.project => await windows.create(
        key: mainWindowKey,
        title: 'Zanshin',
        builder: (_) => first.content,
      ),
      BootWindowKind.projects => await windows.create(
        key: projectsWindowKey,
        title: projectsWindowTitle,
        builder: (_) => first.content,
        dialog: projectsWindowSpec,
      ),
    };
    windows.register(entry);
    await first.onShown?.call();
    return first;
  }

  /// The keys of the open windows, in registry order.
  List<String> get open => <String>[
    for (final key in <String>[mainWindowKey, projectsWindowKey, settingsWindowKey, revsetConfigsWindowKey])
      if (windows.isOpen(key)) key,
  ];

  /// Waits until [done] (the coordinator's chains run on real file IO).
  ///
  /// The wait is bounded by [_untilBudget] of real time, not by a number of polls: each settings write is fsync'd
  /// and chained, so under the full gate's parallel load one can take seconds.
  Future<void> until(bool Function() done) async {
    final watch = Stopwatch()..start();
    while (!done() && watch.elapsed < _untilBudget) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(
      done(),
      isTrue,
      reason:
          'coordinator chains not done after ${watch.elapsedMilliseconds} ms of real time '
          '(budget ${_untilBudget.inSeconds} s)',
    );
  }

  /// Presses the red button of the window [key].
  void close(String key) => factory.requestClose(windows.controllerOf(key)!);

  /// The `onOpened` of the Projects content built last.
  ValueChanged<ProjectOpened> get projectsOpened => projectsContents.last.onOpened;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late bool windowingWasEnabled;

  setUp(() {
    windowingWasEnabled = isWindowingEnabled;
    isWindowingEnabled = true;
  });

  tearDown(() {
    isWindowingEnabled = windowingWasEnabled;
  });

  group('launch', () {
    test('a stored project whose folder exists: the project window first, the project reopens, nothing else', () async {
      final rig = _Rig();
      await rig.setUp(openProject: '/r/zanshin');
      rig.folders.add('/r/zanshin');

      final BootFirstWindow first = await rig.launch();

      expect(first.kind, BootWindowKind.project);
      expect(first.content, isA<AppWindowActionsScope>());
      expect((first.content as AppWindowActionsScope).actions, same(rig.coordinator));
      expect(rig.session.current?.path, '/r/zanshin');
      expect(rig.open, <String>[mainWindowKey]);
      expect(rig.exits, isEmpty);
    });

    for (final (String label, String? stored) in const <(String, String?)>[
      ('nothing stored', null),
      ('a stored folder that is gone', '/r/gone'),
    ]) {
      test('$label: Projects is the first and only window, built before the boot shows it', () async {
        final rig = _Rig();
        await rig.setUp(openProject: stored);
        if (stored != null) {
          rig.repos.detections[stored] = const RepoDetectResult(kind: RepoKind.pathNotFound);
        }

        final BootFirstWindow first = await rig.launch();

        expect(first.kind, BootWindowKind.projects);
        expect(first.content, isA<AppWindowActionsScope>());
        expect(rig.projectsContents, hasLength(1));
        expect(rig.open, <String>[projectsWindowKey]);
        expect(rig.projectContents, 0, reason: 'no project window');
        expect(rig.store.value.projects.openProject, isNull, reason: 'the reopen clears what it could not open');
      });
    }

    test('a reopen that fails: Projects opens, then the project window goes, and the app keeps running', () async {
      final rig = _Rig();
      await rig.setUp(openProject: '/r/broken');
      rig.folders.add('/r/broken');
      rig.repos.openFailures['/r/broken'] = const ZanshinFfiException('jj.repo_open_failed');

      final BootFirstWindow first = await rig.launch();

      expect(first.kind, BootWindowKind.project);
      expect(rig.session.lastFailure?.code, 'jj.repo_open_failed');
      expect(rig.open, <String>[projectsWindowKey]);
      expect(rig.exits, isEmpty);
      // The Projects content shows it as its notice as it mounts (projects_window_test.dart).
      expect(rig.session.failedOpen.value?.path, '/r/broken');
      expect(rig.session.failedOpen.value?.outcome, same(rig.session.lastFailure));
    });
  });

  group('Settings (Story 11.7)', () {
    Future<_Rig> launched({bool project = true}) async {
      final rig = _Rig();
      await rig.setUp(openProject: project ? '/r/zanshin' : null);
      rig.folders.add('/r/zanshin');
      await rig.launch();
      return rig;
    }

    List<AppWindowRequest> settingsRequests(_Rig rig) => <AppWindowRequest>[
      ...rig.factory.requests.where((request) => request.key == settingsWindowKey),
    ];

    test(
      'openSettings twice: one content-sized window, built once, activated the second time, tab and page kept',
      () async {
        final _Rig rig = await launched();
        await rig.coordinator.openSettings(target: SettingsTarget.immutableCommits);

        await rig.coordinator.openSettings();

        final List<AppWindowRequest> requests = settingsRequests(rig);
        expect(requests, hasLength(1));
        expect(requests.single.title, 'Immutable commits');
        expect(requests.single.dialog, same(settingsWindowSpec));
        expect(settingsWindowSpec.constraints, const BoxConstraints(maxWidth: 620, maxHeight: 740));
        expect(settingsWindowSpec.constraints.smallest, Size.zero, reason: 'no minimum');
        expect(settingsWindowSpec.size, isNull);
        expect(settingsWindowSpec.resizable, isFalse);
        expect(settingsWindowSpec.frame, WindowFrameMode.position);
        expect(settingsWindowSpec.keepsAppAlive, isFalse);
        expect(rig.settingsContents, 1);
        expect((rig.windows.controllerOf(settingsWindowKey)! as DialogWindowController).isActivated, isTrue);
        expect(rig.coordinator.settingsState.tab, SettingsTab.project);
        expect(rig.coordinator.settingsState.page, SettingsPage.immutableCommits);
      },
    );

    test('no project open: ⌘, on the Project tab shown last opens General, Project disabled', () async {
      final _Rig rig = await launched(project: false);
      rig.coordinator.settingsState
        ..projectOpen = true
        ..selectTab(SettingsTab.project);

      await rig.coordinator.openSettings();

      expect(rig.coordinator.settingsState.tab, SettingsTab.general);
      expect(rig.coordinator.settingsState.projectOpen, isFalse);
      expect(settingsRequests(rig).single.title, 'General');
    });

    test('a target switches: Project titles the window with the project; General, then the project closes', () async {
      final _Rig rig = await launched();

      await rig.coordinator.openSettings(target: SettingsTarget.project);
      expect(settingsRequests(rig).single.title, 'zanshin');
      expect(rig.coordinator.settingsState.tab, SettingsTab.project);
      await rig.coordinator.openSettings(target: SettingsTarget.general);
      expect(rig.coordinator.settingsState.tab, SettingsTab.general);
      await rig.coordinator.openSettings(target: SettingsTarget.project);

      await rig.session.closeProject();
      await rig.until(() => !rig.windows.isOpen(mainWindowKey));

      expect(rig.coordinator.settingsState.tab, SettingsTab.general);
      expect(rig.coordinator.settingsState.projectOpen, isFalse);
    });
  });

  group('the project window', () {
    Future<_Rig> launched() async {
      final rig = _Rig();
      await rig.setUp(openProject: '/r/zanshin');
      rig.folders.add('/r/zanshin');
      await rig.launch();
      expect(rig.open, <String>[mainWindowKey]);
      return rig;
    }

    test('its red button closes the project: Projects opens, then the project window and Configurations go', () async {
      final _Rig rig = await launched();
      await rig.windows.openOrActivate(
        key: revsetConfigsWindowKey,
        title: 'jj log Configurations',
        builder: (_) => const SizedBox.shrink(),
        dialog: const DialogWindowSpec(
          size: Size(880, 580),
          constraints: BoxConstraints(minWidth: 820, minHeight: 460),
        ),
      );

      rig.close(mainWindowKey);
      await rig.until(() => rig.open.length == 1 && rig.open.single == projectsWindowKey);

      expect(rig.session.current, isNull);
      expect(rig.repos.log, contains('close /r/zanshin'));
      expect(rig.exits, isEmpty);
    });

    test('Story 10.22: Edit Configurations… opens the floating 880 × 580 window once; again brings it forward with '
        'its content kept; it closes with the project', () async {
      final _Rig rig = await launched();

      await rig.coordinator.openRevsetConfigs();
      await rig.coordinator.openRevsetConfigs();

      expect(rig.open, <String>[mainWindowKey, revsetConfigsWindowKey]);
      final requests = <AppWindowRequest>[
        ...rig.factory.requests.where((request) => request.key == revsetConfigsWindowKey),
      ];
      expect(requests, hasLength(1));
      expect(requests.single.title, 'jj log Configurations');
      final DialogWindowSpec spec = requests.single.dialog!;
      expect(spec.size, const Size(880, 580));
      expect(spec.constraints, const BoxConstraints(minWidth: 820, minHeight: 460));
      expect(spec.frame, WindowFrameMode.full);
      expect(spec.level, WindowLevel.floatingWhileActive);
      expect(spec.keepsAppAlive, isFalse);
      expect(rig.revsetConfigsContents, 1, reason: 'the edits live on: the content is built once');
      expect((rig.windows.controllerOf(revsetConfigsWindowKey)! as DialogWindowController).isActivated, isTrue);

      rig.close(mainWindowKey);
      await rig.until(() => rig.open.length == 1 && rig.open.single == projectsWindowKey);
    });

    test('Story 10.22: a guard that refuses keeps the project on a switch (ProjectSwitchCancelled)', () async {
      final _Rig rig = await launched();
      rig.session.mayLeave = rig.windows.mayClose;
      var refuse = true;
      var asked = 0;
      rig.windows.addCloseGuard(() async {
        asked++;
        return !refuse;
      });

      rig.repos.detections['/r/plain'] = const RepoDetectResult(kind: RepoKind.neither);
      expect(await rig.session.open('/r/plain'), isA<ProjectNotARepo>());
      expect(asked, 0, reason: 'a path that is no workspace asks nothing');

      expect(await rig.session.open('/r/jj'), isA<ProjectSwitchCancelled>());
      expect(asked, 1);
      expect(rig.session.current?.path, '/r/zanshin');
      expect(await rig.session.initRepo('/r/new'), isA<ProjectSwitchCancelled>());
      expect(await rig.session.convert('/r/git'), isA<ProjectSwitchCancelled>());
      final clone = '${rig.dir.path}/clone';
      expect(
        await rig.session.clone(url: 'https://example.org/r.git', destination: clone),
        isA<ProjectSwitchCancelled>(),
      );
      expect(Directory(clone).existsSync(), isFalse, reason: 'refused before the destination is made');
      expect(rig.session.current?.path, '/r/zanshin');
      expect(await rig.session.open('/r/zanshin'), isA<ProjectOpened>(), reason: 'the open project asks nothing');

      refuse = false;
      expect(await rig.session.open('/r/jj'), isA<ProjectOpened>());
      expect(rig.session.current?.path, '/r/jj');
    });

    test('a close guard that refuses keeps the project and the window', () async {
      final _Rig rig = await launched();
      var asked = 0;
      rig.windows.addCloseGuard(() async {
        asked++;
        return false;
      });

      rig.close(mainWindowKey);
      await rig.until(() => asked == 1);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(rig.session.current?.path, '/r/zanshin');
      expect(rig.open, <String>[mainWindowKey]);
    });

    test('its red button with no project open shows Projects instead of the window', () async {
      final _Rig rig = await launched();
      // Closing the project switches to Projects through the session listener; the project window is then opened
      // again by hand, so it stands without a project.
      await rig.session.closeProject();
      await rig.until(() => rig.open.single == projectsWindowKey);
      await rig.windows.openOrActivate(key: mainWindowKey, title: 'Zanshin', builder: (_) => const SizedBox.shrink());
      expect(rig.open, <String>[mainWindowKey, projectsWindowKey]);

      rig.close(mainWindowKey);
      await rig.until(() => !rig.windows.isOpen(mainWindowKey));

      expect(rig.open, <String>[projectsWindowKey]);
      expect(rig.exits, isEmpty);
    });

    test('All Projects… opens Projects beside it, and a second time brings it forward', () async {
      final _Rig rig = await launched();

      await rig.coordinator.openProjects();
      await rig.coordinator.openProjects();

      expect(rig.open, <String>[mainWindowKey, projectsWindowKey]);
      expect(rig.factory.requests.where((request) => request.key == projectsWindowKey), hasLength(1));
      expect((rig.windows.controllerOf(projectsWindowKey)! as DialogWindowController).isActivated, isTrue);
      expect((rig.projectContents, rig.projectsContents.length), (1, 1), reason: 'each content is built once');
    });

    test('its red button pressed while the launch reopen is pending waits for it, then closes the project', () async {
      final rig = _Rig();
      await rig.setUp(openProject: '/r/zanshin');
      rig.folders.add('/r/zanshin');
      final Completer<void> gate = rig.repos.openGate = Completer<void>();
      final BootFirstWindow first = rig.coordinator.start();
      rig.windows.register(
        await rig.windows.create(key: mainWindowKey, title: 'Zanshin', builder: (_) => first.content),
      );
      final Future<void> shown = first.onShown!();

      rig.close(mainWindowKey);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(rig.open, <String>[mainWindowKey], reason: 'nothing acts before the first window is settled');

      gate.complete();
      await shown;
      await rig.until(() => rig.open.length == 1 && rig.open.single == projectsWindowKey);

      expect(rig.session.current, isNull);
      expect(rig.repos.log, containsAllInOrder(<String>['open /r/zanshin', 'close /r/zanshin']));
      expect(rig.exits, isEmpty);
    });

    test('the runner channel refuses a method it does not know', () async {
      final _Rig rig = await launched();
      ByteData? reply = ByteData(1);

      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
        rig.channel.name,
        rig.channel.codec.encodeMethodCall(const MethodCall('restore')),
        (data) => reply = data,
      );

      // The handler's MissingPluginException is how a method channel answers "not implemented": no reply data.
      expect(reply, isNull);
    });

    test('a project opened in Projects switches the window in place and closes Projects', () async {
      final _Rig rig = await launched();
      await rig.coordinator.openProjects();

      await rig.session.open('/r/jj');
      rig.projectsOpened(const ProjectOpened());
      await rig.until(() => !rig.windows.isOpen(projectsWindowKey));

      expect(rig.session.current?.path, '/r/jj');
      expect(rig.open, <String>[mainWindowKey]);
      expect(rig.factory.requests.where((request) => request.key == mainWindowKey), hasLength(1), reason: 'one window');
    });

    test('the Dock reopen brings a minimised project window back', () async {
      final _Rig rig = await launched();
      final main = rig.windows.controllerOf(mainWindowKey)! as WindowController..setMinimized(true);

      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
        rig.channel.name,
        rig.channel.codec.encodeMethodCall(const MethodCall('reopen')),
        (_) {},
      );
      await rig.until(() => !main.isMinimized);

      expect(main.isActivated, isTrue);
      expect(rig.open, <String>[mainWindowKey]);
    });
  });

  group('Projects as the only window', () {
    Future<_Rig> launched() async {
      final rig = _Rig();
      await rig.setUp();
      await rig.launch();
      expect(rig.open, <String>[projectsWindowKey]);
      return rig;
    }

    test('a project opened there opens the project window, then Projects closes', () async {
      final _Rig rig = await launched();

      await rig.session.open('/r/zanshin');
      rig.projectsOpened(const ProjectOpened());
      await rig.until(() => !rig.windows.isOpen(projectsWindowKey));

      expect(rig.open, <String>[mainWindowKey]);
      expect(rig.exits, isEmpty);
    });

    test('an open that carries warnings closes Projects too: the project window toasts them', () async {
      final _Rig rig = await launched();

      await rig.session.open('/r/zanshin');
      rig.projectsOpened(
        const ProjectOpened(
          warnings: <ZanshinWarning>[
            ZanshinWarning(code: ZanshinWarningCode.identityMissing, message: 'Name and email not configured.'),
          ],
        ),
      );
      await rig.until(() => !rig.windows.isOpen(projectsWindowKey));

      expect(rig.open, <String>[mainWindowKey]);
    });

    test('closing it quits, even with Settings open', () async {
      final _Rig rig = await launched();
      await rig.windows.openOrActivate(
        key: settingsWindowKey,
        title: 'General',
        builder: (_) => const SizedBox.shrink(),
        dialog: const DialogWindowSpec(constraints: BoxConstraints(maxWidth: 620, maxHeight: 740), resizable: false),
      );

      rig.close(projectsWindowKey);

      expect(rig.exits, <String>['exit']);
    });

    test('the Dock reopen brings Projects forward', () async {
      final _Rig rig = await launched();
      await rig.windows.openOrActivate(
        key: settingsWindowKey,
        title: 'General',
        builder: (_) => const SizedBox.shrink(),
        dialog: const DialogWindowSpec(constraints: BoxConstraints(maxWidth: 620, maxHeight: 740), resizable: false),
      );
      final projects = rig.windows.controllerOf(projectsWindowKey)! as DialogWindowController;
      expect(projects.isActivated, isFalse);

      await rig.coordinator.reopen();

      expect(projects.isActivated, isTrue);
      expect(rig.factory.requests.where((request) => request.key == projectsWindowKey), hasLength(1));
    });
  });

  test('before the first window is up the Dock reopen does nothing', () async {
    final rig = _Rig();
    await rig.setUp();
    rig.coordinator.start();

    await rig.coordinator.reopen();

    expect(rig.factory.requests, isEmpty);
  });
}
