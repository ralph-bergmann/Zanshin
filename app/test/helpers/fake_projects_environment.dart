// SPDX-License-Identifier: MIT

import 'package:zanshin/src/features/projects/projects_environment.dart';
import 'package:zanshin_core/zanshin_core.dart';

/// [ProjectsEnvironment] for the Projects window tests: scripted versions and identity (or an identity read that
/// throws), the folder picker's answers in order, and logs of every picker call and every Reveal in Finder.
class FakeProjectsEnvironment implements ProjectsEnvironment {
  /// What [appVersion] answers.
  String? version = '2026.9.1 · Build 1';

  /// What [jjLibVersion] answers.
  String? jjLib = '0.46.0';

  /// What [identity] answers.
  var identityAnswer = JjIdentity(name: 'Ralph Stein', email: 'ralph@example.com');

  /// When set, [identity] throws it.
  ZanshinFfiException? identityFailure;

  /// The folder picker's answers, first first; an empty list answers null (cancelled).
  final pickerAnswers = <String?>[];

  /// Every picker call as `<viewId> <initialDirectory> <prompt>`.
  final pickerCalls = <String>[];

  /// Every revealed path.
  final revealed = <String>[];

  /// Every identity read's workspace root.
  final identityReads = <String?>[];

  @override
  var home = '/Users/me';

  @override
  Future<String?> appVersion() async => version;

  @override
  Future<String?> jjLibVersion() async => jjLib;

  @override
  Future<JjIdentity> identity({String? workspaceRoot}) async {
    identityReads.add(workspaceRoot);
    final ZanshinFfiException? failure = identityFailure;
    if (failure != null) {
      throw failure;
    }
    return identityAnswer;
  }

  @override
  Future<String?> chooseDirectory({required int viewId, String? initialDirectory, String? prompt}) async {
    pickerCalls.add('$viewId $initialDirectory $prompt');
    return pickerAnswers.isEmpty ? null : pickerAnswers.removeAt(0);
  }

  @override
  Future<void> revealInFinder(String path) async => revealed.add(path);
}
