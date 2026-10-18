// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:zanshin/src/features/projects/projects_environment.dart';
import 'package:zanshin_core/zanshin_core.dart';

/// A worker that answers `configGet` from [values] and records every call as `<name> <workspaceRoot>`; app tests
/// never run a jj config verb for real (Makefile.toml test-flutter).
class _ConfigWorker implements ZanshinWorker {
  _ConfigWorker(this.values);

  final Map<String, String> values;
  final calls = <String>[];

  @override
  Future<ConfigGetResult> configGet(String name, {String? workspaceRoot}) async {
    calls.add('$name $workspaceRoot');
    return ConfigGetResult(value: values[name] ?? '');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A diagnostics read answering jj-lib 0.46.0.
Diagnostics _diagnostics() =>
    const Diagnostics(appVersion: '0.1.0', gitSha: 'abc1234', logPath: '/logs', jjLibVersion: '0.46.0');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('identity reads user.name and user.email for the workspace root; an empty value is not configured', () async {
    final worker = _ConfigWorker(<String, String>{'user.name': 'Ralph', 'user.email': ''});
    final environment = DesktopProjectsEnvironment(Future<ZanshinWorker>.value(worker), diagnostics: _diagnostics);

    final JjIdentity identity = await environment.identity(workspaceRoot: '/r/a');

    expect(worker.calls, <String>['user.name /r/a', 'user.email /r/a']);
    expect(identity, JjIdentity(name: 'Ralph'));
    expect(identity.missingPhrase, 'Email not configured.');

    await environment.identity();
    expect(worker.calls.sublist(2), <String>['user.name null', 'user.email null']);
  });

  test("the version line is the splash's: ‹version› · Build ‹build›", () async {
    PackageInfo.setMockInitialValues(
      appName: 'Zanshin',
      packageName: 'de.dasralph.zanshin',
      version: '2026.9.1',
      buildNumber: '7',
      buildSignature: '',
    );
    final environment = DesktopProjectsEnvironment(
      Future<ZanshinWorker>.value(_ConfigWorker(const <String, String>{})),
      diagnostics: _diagnostics,
    );

    expect(await environment.appVersion(), '2026.9.1 · Build 7');
  });

  test("jj-lib's version is the diagnostics' bare version", () async {
    final environment = DesktopProjectsEnvironment(
      Future<ZanshinWorker>.value(_ConfigWorker(const <String, String>{})),
      diagnostics: _diagnostics,
    );

    expect(await environment.jjLibVersion(), '0.46.0');
  });

  test("a failed diagnostics read answers null for jj-lib's version and logs a warning with its code", () async {
    final records = <LogRecord>[];
    final StreamSubscription<LogRecord> logs = Logger.root.onRecord.listen(records.add);
    addTearDown(logs.cancel);
    final environment = DesktopProjectsEnvironment(
      Future<ZanshinWorker>.value(_ConfigWorker(const <String, String>{})),
      diagnostics: () => throw const ZanshinFfiException('internal.panic', 'zanshin_diagnostics panicked'),
    );

    expect(await environment.jjLibVersion(), isNull);
    final LogRecord warning = records.singleWhere((record) => record.level == Level.WARNING);
    expect(warning.message, 'reading the jj-lib version failed: internal.panic');
  });
}
