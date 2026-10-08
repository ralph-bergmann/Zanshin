// SPDX-License-Identifier: MIT

import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../worker/responses.dart';
import 'bindings.dart';
import 'envelope_zanshin.ffi_generated.dart' as fbs;
import 'precondition.dart' show Precondition, decodeEnvelopeErrorInternal, decodeEnvelopePreconditionInternal;
import 'request_bytes.dart';
import 'warning.dart';

// This file owns the Dart half of Story 9.28's config surface — the CLI's
// `jj config list/get/path/set/unset/edit/gc`: the nine request builders and
// adapters, the payload models and their decoders. Every wrapper is HANDLE-LESS:
// `workspaceRoot` (null = no workspace, the CLI without `-R`) travels in the
// request buffer, so a config that makes `openRepo` fail can still be repaired.
// `dart:ffi` stays inside `ffi/` — only the worker isolate calls these adapters.
//
// The `rejectInteriorNul(s)` calls below are the DIRECT-CALLER backstop; the
// primary guard lives on the calling side, in `ZanshinWorker`.

// ── Models ───────────────────────────────────────────────────────────────────

/// A config level — the CLI's `--user` / `--repo` / `--workspace`.
enum ConfigScope {
  /// The user config (`JJ_CONFIG`, `~/.jjconfig.toml`, `<config_dir>/jj/…`).
  user(fbs.ConfigScope.User),

  /// The repo config (`<config_dir>/jj/repos/<config-id>/config.toml`).
  repo(fbs.ConfigScope.Repo),

  /// The workspace config (`<config_dir>/jj/workspaces/<id>/config.toml`).
  workspace(fbs.ConfigScope.Workspace);

  const ConfigScope(this.wire);

  /// The wire value.
  final fbs.ConfigScope wire;
}

/// The file `configSet` / `configUnset` / `configFileRead` write — the CLI's
/// `--user | --repo | --workspace | --file PATH`, exactly one (jj 0.45).
sealed class ConfigTarget {
  const ConfigTarget();
}

/// A scope's first file, else its new-file default.
final class ConfigScopeTarget extends ConfigTarget {
  const ConfigScopeTarget(this.scope);

  /// The scope.
  final ConfigScope scope;
}

/// One file (`--file PATH`) — a location jj recognizes as a config file: a
/// loaded layer's file, the repo or workspace config file, a user config path,
/// or a `*.toml` directly inside a user config directory. A relative path is
/// taken against the workspace root; anything else is refused with
/// `jj.config_unrecognized_file`.
final class ConfigFileTarget extends ConfigTarget {
  const ConfigFileTarget(this.path);

  /// The file's path.
  final String path;
}

/// Which layer a listed value comes from (mirrors `zanshin_jj::ConfigValueSource`).
enum ConfigValueSource {
  /// jj's (and Zanshin's builtin) defaults.
  defaults,

  /// `/etc/jj`.
  system,

  /// Environment values config files override.
  envBase,

  /// A user config file.
  user,

  /// The repo config file.
  repo,

  /// The workspace config file.
  workspace,

  /// Environment values that override every file (`JJ_USER`, …).
  envOverrides,
}

/// One row of `configList` (mirrors `zanshin_jj::ConfigEntry`).
final class ConfigEntry {
  const ConfigEntry({
    required this.name,
    required this.value,
    required this.source,
    required this.path,
    required this.overridden,
  });

  /// The dotted name.
  final String name;

  /// The value as TOML text (strings stay quoted).
  final String value;

  /// The layer it comes from.
  final ConfigValueSource source;

  /// The file it comes from; `null` for the default and environment layers.
  final String? path;

  /// True if a higher-precedence layer shadows it.
  final bool overridden;
}

/// `@`'s author when a `user.name` / `user.email` write differs from it.
final class WorkingCopyAuthor {
  const WorkingCopyAuthor({required this.name, required this.email});

  /// `@`'s current author name.
  final String name;

  /// `@`'s current author email.
  final String email;
}

/// Outcome of a successful `configSet`.
final class ConfigSetResult {
  const ConfigSetResult({
    required this.path,
    required this.workingCopyAuthor,
    required this.precondition,
    this.warnings = const [],
  });

  /// The file written.
  final String path;

  /// Present iff `user.name`/`user.email` was set and `@`'s author differs
  /// (change it with `jj metaedit --update-author`); the same fact is the
  /// `jj.config_working_copy_author` entry of [warnings].
  final WorkingCopyAuthor? workingCopyAuthor;

  /// The report of the working-copy snapshot the identity check ran; `null`
  /// when it did not run.
  final Precondition? precondition;

  /// The call's warnings (Story 9.32), in the CLI's print order — the start-up
  /// secure-config fix-up's notices (Story 9.37: `jj.config_migrated`,
  /// `jj.config_copied`, `jj.config_regenerated`; only with a workspace root),
  /// the identity check's snapshot warnings, then the working-copy-author note;
  /// empty when there were none.
  final List<ZanshinWarning> warnings;
}

/// The result of `configGet` (Story 9.32): the value text plus the call's
/// warnings.
final class ConfigGetResult {
  const ConfigGetResult({required this.value, this.warnings = const []});

  /// The value: a string's raw text, anything else as TOML text.
  final String value;

  /// The call's warnings (Story 9.32), in the CLI's print order; empty when
  /// there were none.
  final List<ZanshinWarning> warnings;
}

/// The result of `configUnset` (Story 9.32): the file written plus the call's
/// warnings.
final class ConfigUnsetResult {
  const ConfigUnsetResult({required this.path, this.warnings = const []});

  /// The file written.
  final String path;

  /// The call's warnings (Story 9.32), in the CLI's print order; empty when
  /// there were none.
  final List<ZanshinWarning> warnings;
}

/// The result of `configFileWrite` (Story 9.32) — it writes the file and
/// returns nothing else, so only the call's warnings.
final class ConfigFileWriteResult {
  const ConfigFileWriteResult({this.warnings = const []});

  /// The call's warnings (Story 9.32), in the CLI's print order; empty when
  /// there were none.
  final List<ZanshinWarning> warnings;
}

/// A config file's text, as `configFileRead` returns it.
final class ConfigFileText {
  const ConfigFileText({required this.path, required this.text, this.warnings = const []});

  /// The file.
  final String path;

  /// Its exact contents.
  final String text;

  /// The call's warnings (Story 9.32), in the CLI's print order; empty when
  /// there were none.
  final List<ZanshinWarning> warnings;
}

/// A repo config directory whose recorded repo no longer exists.
final class MissingRepoConfig {
  const MissingRepoConfig({required this.configDir, required this.repoPath});

  /// `<config_dir>/jj/repos/<config-id>`.
  final String configDir;

  /// The repo path its metadata records.
  final String repoPath;
}

/// A directory `configGcDelete` did not delete, and why.
final class ConfigGcFailure {
  const ConfigGcFailure({required this.configDir, required this.reason});

  /// The directory.
  final String configDir;

  /// Why it was not deleted.
  final String reason;
}

/// What `configGcDelete` did.
final class ConfigGcResult {
  const ConfigGcResult({required this.deleted, required this.failed, this.warnings = const []});

  /// The directories deleted.
  final List<String> deleted;

  /// The requested directories that were not deleted.
  final List<ConfigGcFailure> failed;

  /// The call's warnings (Story 9.32) — one `jj.config_gc_delete_failed` per
  /// directory whose removal failed; empty when there were none.
  final List<ZanshinWarning> warnings;
}

// ── FFI adapters ─────────────────────────────────────────────────────────────

/// `zanshin_config_list` — `jj config list`. [scope] null = no scope flag; a
/// scope together with [includeDefaults] is refused (`jj.invalid_input`).
Uint8List zanshinConfigList({
  String? workspaceRoot,
  String? name,
  ConfigScope? scope,
  bool includeDefaults = false,
  bool includeOverridden = false,
}) {
  rejectInteriorNul(workspaceRoot, 'workspaceRoot');
  rejectInteriorNul(name, 'name');
  final Uint8List request = fbs.ConfigListRequestObjectBuilder(
    kind: fbs.RequestKind.ConfigList,
    workspaceRoot: workspaceRoot,
    name: name,
    scope: scope?.wire,
    includeDefaults: includeDefaults,
    includeOverridden: includeOverridden,
  ).toBytes();
  return callWithRequest(request, zanshin_config_list);
}

/// `zanshin_config_get` — `jj config get NAME`.
Uint8List zanshinConfigGet(String name, {String? workspaceRoot}) {
  rejectInteriorNul(workspaceRoot, 'workspaceRoot');
  rejectInteriorNul(name, 'name');
  final Uint8List request = fbs.ConfigGetRequestObjectBuilder(
    kind: fbs.RequestKind.ConfigGet,
    workspaceRoot: workspaceRoot,
    name: name,
  ).toBytes();
  return callWithRequest(request, zanshin_config_get);
}

/// `zanshin_config_path` — `jj config path --user|--repo|--workspace`.
Uint8List zanshinConfigPath(ConfigScope scope, {String? workspaceRoot}) {
  rejectInteriorNul(workspaceRoot, 'workspaceRoot');
  final Uint8List request = fbs.ConfigPathRequestObjectBuilder(
    kind: fbs.RequestKind.ConfigPath,
    workspaceRoot: workspaceRoot,
    scope: scope.wire,
  ).toBytes();
  return callWithRequest(request, zanshin_config_path);
}

/// [target] on the wire: a scope, or a `path` with the scope left ABSENT.
(fbs.ConfigScope?, String?) _wireTarget(ConfigTarget target) {
  switch (target) {
    case ConfigScopeTarget(:final scope):
      return (scope.wire, null);
    case ConfigFileTarget(:final path):
      rejectInteriorNul(path, 'path');
      return (null, path);
  }
}

/// `zanshin_config_set` — `jj config set --<scope>|--file PATH NAME VALUE`;
/// [value] is TOML text (a bare string when it does not look like TOML).
Uint8List zanshinConfigSet(ConfigTarget target, String name, String value, {String? workspaceRoot}) {
  rejectInteriorNuls([name, value], 'name/value');
  rejectInteriorNul(workspaceRoot, 'workspaceRoot');
  final (fbs.ConfigScope? scope, String? path) = _wireTarget(target);
  final Uint8List request = fbs.ConfigSetRequestObjectBuilder(
    kind: fbs.RequestKind.ConfigSet,
    workspaceRoot: workspaceRoot,
    scope: scope,
    name: name,
    value: value,
    path: path,
  ).toBytes();
  return callWithRequest(request, zanshin_config_set);
}

/// `zanshin_config_unset` — `jj config unset --<scope>|--file PATH NAME`.
Uint8List zanshinConfigUnset(ConfigTarget target, String name, {String? workspaceRoot}) {
  rejectInteriorNul(name, 'name');
  rejectInteriorNul(workspaceRoot, 'workspaceRoot');
  final (fbs.ConfigScope? scope, String? path) = _wireTarget(target);
  final Uint8List request = fbs.ConfigUnsetRequestObjectBuilder(
    kind: fbs.RequestKind.ConfigUnset,
    workspaceRoot: workspaceRoot,
    scope: scope,
    name: name,
    path: path,
  ).toBytes();
  return callWithRequest(request, zanshin_config_unset);
}

/// `zanshin_config_file_read` — `jj config edit`, editor half 1.
Uint8List zanshinConfigFileRead(ConfigTarget target, {String? workspaceRoot}) {
  rejectInteriorNul(workspaceRoot, 'workspaceRoot');
  final (fbs.ConfigScope? scope, String? path) = _wireTarget(target);
  final Uint8List request = fbs.ConfigFileReadRequestObjectBuilder(
    kind: fbs.RequestKind.ConfigFileRead,
    workspaceRoot: workspaceRoot,
    scope: scope,
    path: path,
  ).toBytes();
  return callWithRequest(request, zanshin_config_file_read);
}

/// `zanshin_config_file_write` — `jj config edit`, editor half 2.
Uint8List zanshinConfigFileWrite(String path, String text, {String? workspaceRoot}) {
  rejectInteriorNuls([path, text], 'path/text');
  rejectInteriorNul(workspaceRoot, 'workspaceRoot');
  final Uint8List request = fbs.ConfigFileWriteRequestObjectBuilder(
    kind: fbs.RequestKind.ConfigFileWrite,
    workspaceRoot: workspaceRoot,
    path: path,
    text: text,
  ).toBytes();
  return callWithRequest(request, zanshin_config_file_write);
}

/// `zanshin_config_gc_list` — `jj config gc`, half 1.
Uint8List zanshinConfigGcList() {
  final Uint8List request = fbs.ConfigGcListRequestObjectBuilder(kind: fbs.RequestKind.ConfigGcList).toBytes();
  return callWithRequest(request, zanshin_config_gc_list);
}

/// `zanshin_config_gc_delete` — `jj config gc`, half 2.
Uint8List zanshinConfigGcDelete(List<String> configDirs) {
  rejectInteriorNuls(configDirs, 'configDirs');
  final Uint8List request = fbs.ConfigGcDeleteRequestObjectBuilder(
    kind: fbs.RequestKind.ConfigGcDelete,
    configDirs: configDirs,
  ).toBytes();
  return callWithRequest(request, zanshin_config_gc_delete);
}

// ── Decoders ─────────────────────────────────────────────────────────────────

/// Decode a `ConfigListResult` envelope. Exposed for decode-contract tests.
@visibleForTesting
WarnedList<ConfigEntry> decodeConfigListEnvelope(Uint8List bytes) => decodeConfigListEnvelopeInternal(bytes);

/// Internal decoder used by production code in `isolate.dart`.
WarnedList<ConfigEntry> decodeConfigListEnvelopeInternal(Uint8List bytes) {
  final fbs.Envelope env = _okEnvelope(bytes);
  final fbs.ConfigListResult p = _payload<fbs.ConfigListResult>(env);
  return WarnedList(
    p.entries
            ?.map(
              (e) => ConfigEntry(
                name: e.name ?? '',
                value: e.value ?? '',
                source: _source(e.source),
                path: e.path,
                overridden: e.overridden,
              ),
            )
            .toList() ??
        const [],
    decodeEnvelopeWarningsInternal(env),
  );
}

/// Decode a `ConfigGetResult` envelope into the value text and the warnings.
ConfigGetResult decodeConfigGetEnvelopeInternal(Uint8List bytes) {
  final fbs.Envelope env = _okEnvelope(bytes);
  return ConfigGetResult(
    value: _payload<fbs.ConfigGetResult>(env).value ?? '',
    warnings: decodeEnvelopeWarningsInternal(env),
  );
}

/// Decode a `ConfigPathResult` envelope into its paths and the warnings.
WarnedList<String> decodeConfigPathEnvelopeInternal(Uint8List bytes) {
  final fbs.Envelope env = _okEnvelope(bytes);
  return WarnedList(
    _payload<fbs.ConfigPathResult>(env).paths?.toList() ?? const [],
    decodeEnvelopeWarningsInternal(env),
  );
}

/// Decode a `ConfigSetResult` envelope, the envelope's `precondition` included.
/// Exposed for decode-contract tests.
@visibleForTesting
ConfigSetResult decodeConfigSetEnvelope(Uint8List bytes) => decodeConfigSetEnvelopeInternal(bytes);

/// Internal decoder used by production code in `isolate.dart`.
ConfigSetResult decodeConfigSetEnvelopeInternal(Uint8List bytes) {
  final fbs.Envelope env = _okEnvelope(bytes);
  final fbs.ConfigSetResult p = _payload<fbs.ConfigSetResult>(env);
  final fbs.WorkingCopyAuthor? a = p.workingCopyAuthor;
  return ConfigSetResult(
    path: p.path ?? '',
    workingCopyAuthor: a == null ? null : WorkingCopyAuthor(name: a.name ?? '', email: a.email ?? ''),
    precondition: decodeEnvelopePreconditionInternal(bytes),
    warnings: decodeEnvelopeWarningsInternal(env),
  );
}

/// Decode a `ConfigUnsetResult` envelope into the file written and the warnings.
ConfigUnsetResult decodeConfigUnsetEnvelopeInternal(Uint8List bytes) {
  final fbs.Envelope env = _okEnvelope(bytes);
  return ConfigUnsetResult(
    path: _payload<fbs.ConfigUnsetResult>(env).path ?? '',
    warnings: decodeEnvelopeWarningsInternal(env),
  );
}

/// Decode a `ConfigFileText` envelope.
ConfigFileText decodeConfigFileTextEnvelopeInternal(Uint8List bytes) {
  final fbs.Envelope env = _okEnvelope(bytes);
  final fbs.ConfigFileText p = _payload<fbs.ConfigFileText>(env);
  return ConfigFileText(path: p.path ?? '', text: p.text ?? '', warnings: decodeEnvelopeWarningsInternal(env));
}

/// Decode a no-payload `zanshin_config_file_write` envelope into its warnings.
ConfigFileWriteResult decodeConfigFileWriteEnvelopeInternal(Uint8List bytes) =>
    ConfigFileWriteResult(warnings: decodeEnvelopeWarningsInternal(_okEnvelope(bytes)));

/// Decode a `ConfigGcList` envelope.
WarnedList<MissingRepoConfig> decodeConfigGcListEnvelopeInternal(Uint8List bytes) {
  final fbs.Envelope env = _okEnvelope(bytes);
  return WarnedList(
    _payload<fbs.ConfigGcList>(
          env,
        ).missing?.map((m) => MissingRepoConfig(configDir: m.configDir ?? '', repoPath: m.repoPath ?? '')).toList() ??
        const [],
    decodeEnvelopeWarningsInternal(env),
  );
}

/// Decode a `ConfigGcResult` envelope.
ConfigGcResult decodeConfigGcResultEnvelopeInternal(Uint8List bytes) {
  final fbs.Envelope env = _okEnvelope(bytes);
  final fbs.ConfigGcResult p = _payload<fbs.ConfigGcResult>(env);
  return ConfigGcResult(
    deleted: p.deleted?.toList() ?? const [],
    failed:
        p.failed?.map((f) => ConfigGcFailure(configDir: f.configDir ?? '', reason: f.reason ?? '')).toList() ??
        const [],
    warnings: decodeEnvelopeWarningsInternal(env),
  );
}

ConfigValueSource _source(fbs.ConfigValueSource s) => switch (s) {
  fbs.ConfigValueSource.Default => ConfigValueSource.defaults,
  fbs.ConfigValueSource.System => ConfigValueSource.system,
  fbs.ConfigValueSource.EnvBase => ConfigValueSource.envBase,
  fbs.ConfigValueSource.User => ConfigValueSource.user,
  fbs.ConfigValueSource.Repo => ConfigValueSource.repo,
  fbs.ConfigValueSource.Workspace => ConfigValueSource.workspace,
  fbs.ConfigValueSource.EnvOverrides => ConfigValueSource.envOverrides,
};

/// The ok [env]'s payload as [T]; a different payload throws [ZanshinFfiException].
T _payload<T>(fbs.Envelope env) {
  final Object? payload = env.data;
  if (payload is! T) {
    throw ZanshinFfiException('ffi.unknown', 'expected $T payload, got ${env.dataType}');
  }
  return payload;
}

/// Parse [bytes] as an `Envelope` and throw [ZanshinFfiException] when it is not ok.
fbs.Envelope _okEnvelope(Uint8List bytes) {
  final env = fbs.Envelope(bytes);
  if (!env.ok) {
    throw decodeEnvelopeErrorInternal(env);
  }
  return env;
}
