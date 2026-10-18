// SPDX-License-Identifier: MIT

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:zanshin_core/zanshin_core.dart';
import 'package:zanshin_shell/zanshin_shell.dart';

final _log = Logger('zanshin.projects');

/// What the Projects window reads from and asks of its surroundings besides the registry and the session (Story 11.6;
/// Claude's proposal): the app's version, jj-lib's version, the effective jj identity, the folder picker, Reveal in
/// Finder and the home folder. The app's adapter is [DesktopProjectsEnvironment]; tests and the catalogue pass fakes.
abstract interface class ProjectsEnvironment {
  /// The sidebar's version line, "‹version› · Build ‹build›" as the splash shows it, or null when it cannot be read.
  Future<String?> appVersion();

  /// The sidebar's second version line's version: the version of jj-lib Zanshin is built on, e.g. "0.46.0", or null
  /// when it cannot be read.
  Future<String?> jjLibVersion();

  /// The effective `user.name` and `user.email` (`jj config get`, 9.28) for the workspace at [workspaceRoot], or the
  /// user-level ones without it. Throws [ZanshinFfiException] when the read fails.
  Future<JjIdentity> identity({String? workspaceRoot});

  /// Asks for one folder as a sheet on the window of the Flutter view [viewId], starting in [initialDirectory], its
  /// default button named [prompt]; answers its path, or null when the panel was cancelled.
  Future<String?> chooseDirectory({required int viewId, String? initialDirectory, String? prompt});

  /// Shows [path] selected in a Finder window.
  Future<void> revealInFinder(String path);

  /// The user's home folder, which paths abbreviate to `~` and a clone's destination defaults to.
  String get home;
}

/// The jj identity as `jj config get user.name` / `user.email` read it; an empty value — jj's built-in default for an
/// unset identity (jj-lib misc.toml:48-50) — is null.
@immutable
class JjIdentity {
  /// An identity of [name] and [email]; an empty string is null.
  JjIdentity({String? name, String? email})
    : name = (name?.isEmpty ?? true) ? null : name,
      email = (email?.isEmpty ?? true) ? null : email;

  /// `user.name`, or null when it is not configured.
  final String? name;

  /// `user.email`, or null when it is not configured.
  final String? email;

  /// The jj CLI's phrase for what is missing (`cli_util.rs:2447-2449` @ v0.46.0), or null when both are configured.
  String? get missingPhrase => switch ((name == null, email == null)) {
    (true, true) => 'Name and email not configured.',
    (true, false) => 'Name not configured.',
    (false, true) => 'Email not configured.',
    (false, false) => null,
  };

  @override
  bool operator ==(Object other) => other is JjIdentity && other.name == name && other.email == email;

  @override
  int get hashCode => Object.hash(name, email);

  @override
  String toString() => 'JjIdentity($name, $email)';
}

/// The app's [ProjectsEnvironment]: the bundle's version through `package_info_plus` in the splash's format, jj-lib's
/// version through the diagnostics (`zanshin_diagnostics`), the identity through the boot's worker (`configGet`), and
/// the folder picker and Reveal in Finder through `ZanshinShell`.
class DesktopProjectsEnvironment implements ProjectsEnvironment {
  /// The environment over [_worker], the boot's worker, and [_diagnostics], the DI-provided diagnostics read.
  DesktopProjectsEnvironment(this._worker, {required this._diagnostics});

  final Future<ZanshinWorker> _worker;
  final GetDiagnostics _diagnostics;

  @override
  Future<String?> appVersion() async {
    try {
      final PackageInfo info = await PackageInfo.fromPlatform();
      return '${info.version} · Build ${info.buildNumber}';
    } on Exception catch (error, stack) {
      _log.warning('the app version could not be read', error, stack);
      return null;
    }
  }

  @override
  Future<String?> jjLibVersion() async {
    try {
      return _diagnostics().jjLibVersion;
    } on ZanshinFfiException catch (error, stack) {
      _log
        ..warning('reading the jj-lib version failed: ${error.code}')
        ..fine('jj-lib version failure', error, stack);
      return null;
    }
  }

  @override
  Future<JjIdentity> identity({String? workspaceRoot}) async {
    final ZanshinWorker worker = await _worker;
    final ConfigGetResult name = await worker.configGet('user.name', workspaceRoot: workspaceRoot);
    final ConfigGetResult email = await worker.configGet('user.email', workspaceRoot: workspaceRoot);
    return JjIdentity(name: name.value, email: email.value);
  }

  @override
  Future<String?> chooseDirectory({required int viewId, String? initialDirectory, String? prompt}) =>
      ZanshinShell.chooseDirectory(viewId: viewId, initialDirectory: initialDirectory, prompt: prompt);

  @override
  Future<void> revealInFinder(String path) => ZanshinShell.revealInFinder(path);

  @override
  String get home => Platform.environment['HOME'] ?? '/';
}
