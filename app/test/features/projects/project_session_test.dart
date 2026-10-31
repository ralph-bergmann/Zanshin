// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:zanshin/src/features/projects/project_registry.dart';
import 'package:zanshin/src/features/projects/project_repos.dart';
import 'package:zanshin/src/features/projects/project_session.dart';
import 'package:zanshin_core/zanshin_core.dart';
import 'package:zanshin_settings/zanshin_settings.dart';

import '../../helpers/fake_projects.dart';

void main() {
  late Directory dir;
  late SettingsStore store;
  late ProjectRegistry registry;
  late FakeProjectRepos repos;
  late ProjectSession session;
  final warnings = <LogRecord>[];
  late StreamSubscription<LogRecord> logs;
  final now = DateTime(2026, 10, 18, 14, 30);

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('project_session_test');
    store = await SettingsStore.load(File('${dir.path}/settings.json'));
    registry = ProjectRegistry(store);
    repos = FakeProjectRepos();
    session = ProjectSession(registry: registry, repos: repos, clock: () => now);
    warnings.clear();
    logs = Logger.root.onRecord.listen((record) {
      if (record.loggerName == 'zanshin.projects' && record.level >= Level.WARNING) {
        warnings.add(record);
      }
    });
  });

  tearDown(() async {
    await logs.cancel();
    session.dispose();
    await dir.delete(recursive: true);
  });

  /// Runs after everything queued so far: opening the open project again does nothing but take its turn.
  Future<void> drain() async {
    final String? open = session.current?.path;
    if (open != null) {
      await session.open(open);
    }
  }

  Future<void> register(List<String> paths) async {
    for (final path in paths) {
      await registry.add(path);
    }
  }

  group('launch', () {
    test('the stored project opens with its first reading; the capsule has its entry', () async {
      await register(<String>['/r/a']);
      await registry.setOpen('/r/a');
      repos.readings['/r/a'] = const ProjectReading(status: ProjectStatus.dirty, bookmark: 'main');

      await session.reopenLast();

      expect(repos.log, <String>['detect /r/a', 'open /r/a', 'read /r/a']);
      expect(
        session.current,
        ProjectEntry(path: '/r/a', name: 'a', lastOpened: now.toUtc(), status: ProjectStatus.dirty, bookmark: 'main'),
      );
      expect(session.repo, same(repos.repoAt('/r/a')));
      expect(registry.value.openProject, '/r/a');
    });

    test('a stored project that is gone opens nothing, is marked missing and is no longer the open one', () async {
      await register(<String>['/r/gone']);
      await registry.recordState('/r/gone', ProjectStatus.clean, 'main');
      await registry.setOpen('/r/gone');
      repos.detections['/r/gone'] = const RepoDetectResult(kind: RepoKind.pathNotFound);

      await session.reopenLast();

      expect(repos.log, <String>['detect /r/gone']);
      expect(session.current, isNull);
      expect(registry.value.openProject, isNull);
      expect(registry.entry('/r/gone')!.status, ProjectStatus.missing);
      expect(registry.entry('/r/gone')!.bookmark, 'main');
      expect(warnings, isEmpty);
    });

    test('a stored project whose open fails stays stored, so the next launch tries again', () async {
      await register(<String>['/r/a']);
      await registry.setOpen('/r/a');
      repos.openFailures['/r/a'] = const ZanshinFfiException('jj.jj_lib_error');

      await session.reopenLast();

      expect(session.current, isNull);
      expect(session.lastFailure?.code, 'jj.jj_lib_error');
      expect(registry.value.openProject, '/r/a');
    });

    for (final (String name, RepoDetectResult detected) in <(String, RepoDetectResult)>[
      ('a Git repository', const RepoDetectResult(kind: RepoKind.git)),
      (
        'a folder inside a repository',
        const RepoDetectResult(kind: RepoKind.neither, suggestedRoot: '/r', suggestedKind: RepoKind.jj),
      ),
    ]) {
      test('a stored path that is now $name is no longer the open project', () async {
        await register(<String>['/r/a']);
        await registry.setOpen('/r/a');
        repos.detections['/r/a'] = detected;

        await session.reopenLast();

        expect(registry.value.openProject, isNull);
      });
    }

    test('nothing stored: no detect, no open', () async {
      await register(<String>['/r/a']);

      await session.reopenLast();

      expect(repos.log, isEmpty);
      expect(session.current, isNull);
    });
  });

  group('open and switch', () {
    test('a switch detects, opens and reads the new project, switches to it, then closes the old one', () async {
      await register(<String>['/r/a', '/r/b']);
      repos.readings['/r/a'] = const ProjectReading(status: ProjectStatus.dirty, bookmark: 'main');
      await session.open('/r/a');
      repos.log.clear();
      final notified = <String?>[];
      session.addListener(() {
        final String? path = session.current?.path;
        if (notified.isEmpty || notified.last != path) {
          notified.add(path);
          repos.log.add('current $path');
        }
      });

      final ProjectOpenOutcome outcome = await session.open('/r/b');

      expect(outcome, isA<ProjectOpened>());
      expect(repos.log, <String>[
        'detect /r/b',
        'open /r/b',
        'read /r/b',
        'current /r/a',
        'current /r/b',
        'close /r/a',
      ]);
      expect(repos.repoAt('/r/a').closed, isTrue);
      expect(session.current?.path, '/r/b');
      expect(registry.value.openProject, '/r/b');
      expect(registry.entry('/r/b')!.lastOpened, now.toUtc());
      expect(registry.entry('/r/b')!.lastOpened!.isUtc, isTrue);
      expect(registry.entry('/r/a')!.status, ProjectStatus.dirty, reason: 'a keeps its last state');
      expect(registry.entry('/r/a')!.bookmark, 'main');
      expect(session.recent.map((project) => project.path), <String>['/r/b', '/r/a']);
    });

    test('opening the open project again does nothing', () async {
      await register(<String>['/r/a']);
      await session.open('/r/a');
      repos.log.clear();

      expect(await session.open('/r/a'), isA<ProjectOpened>());
      expect(repos.log, isEmpty);
    });

    test('a path the registry does not hold is added when it opens', () async {
      await session.open('/r/new');

      expect(
        session.current,
        ProjectEntry(path: '/r/new', name: 'new', lastOpened: now.toUtc(), status: ProjectStatus.clean),
      );
    });

    test('a failed open keeps the current project, records the failure and logs only its code', () async {
      await register(<String>['/r/a', '/r/b']);
      await session.open('/r/a');
      final ProjectsSettings before = registry.value;
      repos.openFailures['/r/b'] = const ZanshinFfiException('jj.repo_not_found', '/r/b');

      final ProjectOpenOutcome outcome = await session.open('/r/b');

      expect(
        outcome,
        isA<ProjectOpenFailed>()
            .having((o) => o.code, 'code', 'jj.repo_not_found')
            .having((o) => o.context, 'context', '/r/b'),
      );
      expect(session.current?.path, '/r/a');
      expect(session.repo, same(repos.repoAt('/r/a')));
      expect(repos.repoAt('/r/a').closed, isFalse);
      expect(session.lastFailure?.code, 'jj.repo_not_found');
      expect(registry.value, before);
      expect(warnings.single.message, contains('jj.repo_not_found'));
      expect(warnings.single.message, isNot(contains('/r/')));

      await session.open('/r/a');
      expect(session.lastFailure, isNotNull, reason: 'the open project again changes nothing');
      repos.openFailures.clear();
      await session.open('/r/b');
      expect(session.lastFailure, isNull, reason: 'a project opened');
    });

    test('a detect that throws is a failed open', () async {
      repos.detectFailures['/r/a'] = const ZanshinFfiException('jj.detect_failed');

      expect(await session.open('/r/a'), isA<ProjectOpenFailed>().having((o) => o.code, 'code', 'jj.detect_failed'));
      expect(repos.log, <String>['detect /r/a']);
      expect(warnings.single.message, contains('jj.detect_failed'));
    });

    test('a path that is gone is not a repository; its entry is missing and leaves Recent', () async {
      await register(<String>['/r/a', '/r/b']);
      await session.open('/r/b');
      await session.open('/r/a');
      expect(session.recent.map((project) => project.path), <String>['/r/a', '/r/b']);
      repos.detections['/r/b'] = const RepoDetectResult(kind: RepoKind.pathNotFound);

      expect(await session.open('/r/b'), isA<ProjectNotARepo>().having((o) => o.kind, 'kind', RepoKind.pathNotFound));
      expect(registry.entry('/r/b')!.status, ProjectStatus.missing);
      expect(session.current?.path, '/r/a');
      expect(session.recent.map((project) => project.path), <String>['/r/a']);

      repos.detections['/r/unregistered'] = const RepoDetectResult(kind: RepoKind.pathNotFound);
      await session.open('/r/unregistered');
      expect(registry.entry('/r/unregistered'), isNull, reason: 'a missing path is not added');
    });

    for (final kind in <RepoKind>[RepoKind.git, RepoKind.neither]) {
      test('a ${kind.name} folder is not opened', () async {
        repos.detections['/r/x'] = RepoDetectResult(kind: kind);

        expect(await session.open('/r/x'), isA<ProjectNotARepo>().having((o) => o.kind, 'kind', kind));
        expect(repos.log, <String>['detect /r/x']);
        expect(session.current, isNull);
      });
    }

    test('a folder inside a repository reports the root for the caller to offer and opens nothing', () async {
      repos.detections['/r/a/src'] = const RepoDetectResult(
        kind: RepoKind.neither,
        suggestedRoot: '/r/a',
        suggestedKind: RepoKind.jj,
      );

      final ProjectOpenOutcome outcome = await session.open('/r/a/src');

      expect(
        outcome,
        isA<ProjectInsideRepo>().having((o) => o.root, 'root', '/r/a').having((o) => o.kind, 'kind', RepoKind.jj),
      );
      expect(repos.log, <String>['detect /r/a/src']);
    });

    test('opens and closes run one at a time, in call order', () async {
      await register(<String>['/r/a', '/r/b', '/r/c']);
      await Future.wait(<Future<Object?>>[
        session.open('/r/a'),
        session.open('/r/b'),
        session.closeProject(),
        session.open('/r/c'),
      ]);

      expect(repos.log, <String>[
        'detect /r/a',
        'open /r/a',
        'read /r/a',
        'detect /r/b',
        'open /r/b',
        'read /r/b',
        'close /r/a',
        'close /r/b',
        'detect /r/c',
        'open /r/c',
        'read /r/c',
      ]);
      expect(session.current?.path, '/r/c');
    });

    test('closing the project closes the handle; no project is open, its entry keeps its last state', () async {
      await register(<String>['/r/a']);
      repos.readings['/r/a'] = const ProjectReading(status: ProjectStatus.conflict, bookmark: 'fix');
      await session.open('/r/a');

      await session.closeProject();

      expect(repos.repoAt('/r/a').closed, isTrue);
      expect(session.current, isNull);
      expect(session.repo, isNull);
      expect(registry.value.openProject, isNull);
      expect(registry.entry('/r/a')!.status, ProjectStatus.conflict);
      expect(registry.entry('/r/a')!.bookmark, 'fix');
      await session.closeProject();
      expect(repos.log.where((line) => line.startsWith('close')), hasLength(1));
    });
  });

  group('readings', () {
    test('a stale reading marks the project stale and keeps its bookmark label', () async {
      await register(<String>['/r/a']);
      repos.readings['/r/a'] = const ProjectReading(status: ProjectStatus.dirty, bookmark: 'main');
      await session.open('/r/a');
      repos.readings['/r/a'] = const ProjectReading(status: ProjectStatus.stale);

      repos.repoAt('/r/a').emitChange();
      await drain();

      expect(session.current!.status, ProjectStatus.stale);
      expect(session.current!.bookmark, 'main');
    });

    test('any other failed reading keeps the last state and logs its code', () async {
      await register(<String>['/r/a']);
      repos.readings['/r/a'] = const ProjectReading(status: ProjectStatus.dirty, bookmark: 'main');
      await session.open('/r/a');
      repos.readFailures['/r/a'] = const ZanshinFfiException('jj.jj_lib_error', 'detail');

      repos.repoAt('/r/a').emitChange();
      await drain();

      expect(session.current!.status, ProjectStatus.dirty);
      expect(session.current!.bookmark, 'main');
      expect(warnings.single.message, contains('jj.jj_lib_error'));
    });

    test('a first reading that fails opens the project with its stored state', () async {
      await register(<String>['/r/a']);
      await registry.recordState('/r/a', ProjectStatus.clean, 'old');
      repos.readFailures['/r/a'] = const ZanshinFfiException('jj.jj_lib_error');

      expect(await session.open('/r/a'), isA<ProjectOpened>());
      expect(session.current!.status, ProjectStatus.clean);
      expect(session.current!.bookmark, 'old');
    });

    test('an operation reads again; operations during a reading coalesce into one more', () async {
      await register(<String>['/r/a']);
      await session.open('/r/a');
      final FakeProjectRepo repo = repos.repoAt('/r/a');
      repos.onRead = (repo) {
        if (repo.reads == 2) {
          repo
            ..emitChange()
            ..emitChange()
            ..emitChange();
        }
      };
      repos.readings['/r/a'] = const ProjectReading(status: ProjectStatus.dirty, bookmark: 'feat');

      repo.emitChange();
      await drain();
      await drain();

      expect(repo.reads, 3);
      expect(session.current!.status, ProjectStatus.dirty);
      expect(session.current!.bookmark, 'feat');
    });

    test("a reading's own operation reads exactly once more, then it is quiet", () async {
      await register(<String>['/r/a']);
      await session.open('/r/a');
      final FakeProjectRepo repo = repos.repoAt('/r/a');
      repos.onRead = (repo) {
        if (repo.reads == 2) {
          repo.emitChange();
        }
      };

      repo.emitChange();
      await drain();
      await drain();

      expect(repo.reads, 3);
    });

    test('an operation during the first reading reads once more right after the switch', () async {
      await register(<String>['/r/a']);
      repos.onRead = (repo) {
        if (repo.reads == 1) {
          repo.emitChange();
        }
      };

      await session.open('/r/a');
      await drain();

      expect(repos.repoAt('/r/a').reads, 2);
    });

    test(
      'refresh reads the open project once more; calls before it runs coalesce; without a project it reads nothing',
      () async {
        session.refresh();
        await register(<String>['/r/a']);
        await session.open('/r/a');
        expect(repos.log, <String>['detect /r/a', 'open /r/a', 'read /r/a'], reason: 'the queued refresh read nothing');
        final FakeProjectRepo repo = repos.repoAt('/r/a');
        repos.readings['/r/a'] = const ProjectReading(status: ProjectStatus.dirty);

        session
          ..refresh()
          ..refresh();
        await drain();

        expect(repo.reads, 2);
        expect(session.current!.status, ProjectStatus.dirty);
      },
    );

    test("the old project's operations no longer read once it was switched away from", () async {
      await register(<String>['/r/a', '/r/b']);
      await session.open('/r/a');
      final FakeProjectRepo a = repos.repoAt('/r/a');
      await session.open('/r/b');
      expect(a.listened, isFalse);

      a.emitChange();
      await drain();

      expect(a.reads, 1);
      expect(repos.log.where((line) => line == 'read /r/a'), hasLength(1));
      expect(repos.repoAt('/r/b').reads, 1);
    });
  });

  test('the store\'s notifications reach the session\'s listeners', () async {
    var notifications = 0;
    session.addListener(() => notifications++);
    await registry.add('/r/a');
    expect(notifications, 1);
  });

  test('disposing the session closes the open repository', () async {
    final local = ProjectSession(registry: registry, repos: repos);
    await local.open('/r/a');
    local.dispose();
    await Future<void>.delayed(Duration.zero);
    expect(repos.repoAt('/r/a').closed, isTrue);
  });

  group('Story 11.6: placement, canonical paths and adding', () {
    test('a new path opens at its placement; the open outcome carries no warnings', () async {
      final String group = await registry.addGroup('G');
      await registry.add('/r/a', group: group);

      final ProjectOpenOutcome outcome = await session.open('/r/new', group: group, index: 0);

      expect(outcome, isA<ProjectOpened>().having((o) => o.warnings, 'warnings', isEmpty));
      expect(registry.entry('/r/new')!.group, group);
      expect(registry.entry('/r/new')!.order, 0);
      expect(registry.entry('/r/a')!.order, 1);
    });

    test('another spelling of a registered path opens that entry and adds nothing', () async {
      final String real = (await Directory('${dir.path}/real').create()).resolveSymbolicLinksSync();
      await Link('${dir.path}/alias').create(real);
      await registry.add(real);

      await session.open('$real/');
      await session.closeProject();
      await session.open('${dir.path}/alias');

      expect(registry.value.projects, hasLength(1));
      expect(repos.log.where((line) => line.startsWith('open ')), <String>['open $real', 'open $real']);
      expect(session.current?.path, real);
    });

    test('a new path registers canonical: its symlinks resolved', () async {
      final String real = (await Directory('${dir.path}/real').create()).resolveSymbolicLinksSync();
      await Link('${dir.path}/alias').create(real);

      await session.open('${dir.path}/alias/');

      expect(registry.value.projects.single.path, real);
      expect(repos.log.first, 'detect $real');
    });

    test('add registers a jj workspace without opening it; a listed path is not detected again', () async {
      final String group = await registry.addGroup('G');

      final ProjectOpenOutcome added = await session.add('/r/a', group: group, index: 0);
      final ProjectOpenOutcome again = await session.add('/r/a/');

      expect(added, isA<ProjectAdded>().having((o) => o.path, 'path', '/r/a'));
      expect(again, isA<ProjectAdded>().having((o) => o.path, 'path', '/r/a'));
      expect(repos.log, <String>['detect /r/a']);
      expect(registry.entry('/r/a')!.group, group);
      expect(session.current, isNull);
    });

    test('add reports a Git repository and registers nothing', () async {
      repos.detections['/r/git'] = const RepoDetectResult(kind: RepoKind.git);

      expect(await session.add('/r/git'), isA<ProjectNotARepo>().having((o) => o.kind, 'kind', RepoKind.git));
      expect(registry.value.projects, isEmpty);
    });
  });

  group('Story 11.6: creations', () {
    const identityMissing = ZanshinWarning(
      code: ZanshinWarningCode.identityMissing,
      message: 'Name and email not configured. Until configured, your commits will be created with the empty identity.',
    );

    test('convert runs without detecting, registers at its placement, opens and carries its warnings', () async {
      final String group = await registry.addGroup('G');
      repos.creationWarnings['/r/git'] = const <ZanshinWarning>[identityMissing];

      final ProjectOpenOutcome outcome = await session.convert('/r/git', group: group, index: 0);

      expect(outcome, isA<ProjectOpened>().having((o) => o.warnings, 'warnings', <ZanshinWarning>[identityMissing]));
      expect(repos.log, <String>['convert /r/git', 'read /r/git']);
      expect(session.current?.path, '/r/git');
      expect(session.repo, same(repos.repoAt('/r/git')));
      expect(registry.entry('/r/git')!.group, group);
      expect(registry.value.openProject, '/r/git');
    });

    test('a failed conversion registers nothing, keeps the open project and carries the failure', () async {
      await session.open('/r/a');
      repos.creationFailures['/r/git'] = const ZanshinFfiException.withReport(
        'jj.convert_failed',
        'detail',
        precondition: null,
        warnings: <ZanshinWarning>[identityMissing],
      );

      final ProjectOpenOutcome outcome = await session.convert('/r/git');

      expect(
        outcome,
        isA<ProjectOpenFailed>()
            .having((o) => o.code, 'code', 'jj.convert_failed')
            .having((o) => o.context, 'context', 'detail')
            .having((o) => o.warnings, 'warnings', <ZanshinWarning>[identityMissing]),
      );
      expect(registry.entry('/r/git'), isNull);
      expect(session.current?.path, '/r/a');
      expect(session.lastFailure?.code, 'jj.convert_failed');
      expect(warnings.single.message, 'converting a project failed: jj.convert_failed');
    });

    test('initRepo creates, registers last at the top level and opens', () async {
      await registry.add('/r/a');

      expect(await session.initRepo('/r/plain'), isA<ProjectOpened>());

      expect(repos.log, <String>['init /r/plain', 'read /r/plain']);
      expect(registry.entry('/r/plain')!.order, 1);
      expect(session.current?.path, '/r/plain');
    });

    test('clone creates a missing destination, clones into its canonical path and opens it', () async {
      final String root = dir.resolveSymbolicLinksSync();
      final destination = '${dir.path}/code/repo';
      repos.creationWarnings['$root/code/repo'] = const <ZanshinWarning>[identityMissing];

      final ProjectOpenOutcome outcome = await session.clone(
        url: 'https://example.com/repo.git',
        destination: destination,
      );

      expect(outcome, isA<ProjectOpened>().having((o) => o.warnings, 'warnings', <ZanshinWarning>[identityMissing]));
      expect(Directory(destination).existsSync(), isTrue);
      expect(repos.log.first, 'clone https://example.com/repo.git $root/code/repo');
      expect(session.current?.path, '$root/code/repo');
    });

    test('clone refuses a destination that exists and is not empty, with the CLI text, before any jj call', () async {
      final Directory full = await Directory('${dir.path}/full').create();
      File('${full.path}/README.md').writeAsStringSync('hello');
      File('${dir.path}/file').writeAsStringSync('');

      expect(
        await session.clone(url: 'https://example.com/repo.git', destination: full.path),
        isA<ProjectRefused>().having(
          (o) => o.message,
          'message',
          'Destination path exists and is not an empty directory',
        ),
      );
      expect(
        await session.clone(url: 'https://example.com/repo.git', destination: '${dir.path}/file'),
        isA<ProjectRefused>(),
      );
      expect(repos.log, isEmpty);
      expect(full.listSync(), hasLength(1));
    });

    test('a failed clone removes the folder it created and carries the warnings', () async {
      final String root = dir.resolveSymbolicLinksSync();
      repos.creationFailures['$root/repo'] = const ZanshinFfiException.withReport(
        'jj.jj_lib_error',
        'fetch failed',
        precondition: null,
        warnings: <ZanshinWarning>[],
      );

      final ProjectOpenOutcome outcome = await session.clone(url: 'file:///nowhere', destination: '${dir.path}/repo');

      expect(outcome, isA<ProjectOpenFailed>().having((o) => o.code, 'code', 'jj.jj_lib_error'));
      expect(Directory('${dir.path}/repo').existsSync(), isFalse);
      expect(registry.value.projects, isEmpty);
      expect(warnings.single.message, 'cloning a project failed: jj.jj_lib_error');
    });

    test('a clone into an empty folder that existed clones there; after a failure the folder stays', () async {
      final String empty = (await Directory('${dir.path}/empty').create()).resolveSymbolicLinksSync();
      repos.creationFailures[empty] = const ZanshinFfiException('jj.jj_lib_error');

      expect(await session.clone(url: 'file:///nowhere', destination: empty), isA<ProjectOpenFailed>());
      expect(Directory(empty).existsSync(), isTrue);

      repos.creationFailures.clear();
      expect(await session.clone(url: 'file:///somewhere', destination: empty), isA<ProjectOpened>());
      expect(session.current?.path, empty);
    });

    test(
      'a destination that cannot be created is refused with the CLI text and its cause, before any jj call',
      () async {
        File('${dir.path}/file').writeAsStringSync('');

        final ProjectOpenOutcome outcome = await session.clone(
          url: 'https://example.com/repo.git',
          destination: '${dir.path}/file/sub',
        );

        expect(
          outcome,
          isA<ProjectRefused>().having(
            (o) => o.message,
            'message',
            startsWith('Failed to create ${dir.path}/file/sub: '),
          ),
        );
        expect(
          (outcome as ProjectRefused).message.length,
          greaterThan('Failed to create ${dir.path}/file/sub: '.length),
        );
        expect(repos.log, isEmpty);
      },
    );

    test('a clone into a folder listed under another spelling keeps that one entry', () async {
      final String real = (await Directory('${dir.path}/real').create()).resolveSymbolicLinksSync();
      await Link('${dir.path}/alias').create(real);
      await registry.add('${dir.path}/alias/repo');

      expect(await session.clone(url: 'https://example.com/repo.git', destination: '$real/repo'), isA<ProjectOpened>());

      expect(registry.value.projects, hasLength(1));
      expect(repos.log.first, 'clone https://example.com/repo.git ${dir.path}/alias/repo');
      expect(session.current?.path, '${dir.path}/alias/repo');
    });

    test('creations run in the serial queue with opens', () async {
      await Future.wait(<Future<Object?>>[
        session.open('/r/a'),
        session.convert('/r/git'),
        session.initRepo('/r/plain'),
      ]);

      expect(repos.log, <String>[
        'detect /r/a',
        'open /r/a',
        'read /r/a',
        'convert /r/git',
        'read /r/git',
        'close /r/a',
        'init /r/plain',
        'read /r/plain',
        'close /r/git',
      ]);
    });
  });
}
