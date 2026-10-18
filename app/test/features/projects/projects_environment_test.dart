// SPDX-License-Identifier: MIT

import 'package:flutter_test/flutter_test.dart';
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('identity reads user.name and user.email for the workspace root; an empty value is not configured', () async {
    final worker = _ConfigWorker(<String, String>{'user.name': 'Ralph', 'user.email': ''});
    final environment = DesktopProjectsEnvironment(Future<ZanshinWorker>.value(worker));

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
    );

    expect(await environment.appVersion(), '2026.9.1 · Build 7');
  });
}
