// SPDX-License-Identifier: MIT

// Decode-contract tests for Story 9.32's warning channel, using synthetic
// FlatBuffers buffers built via the generated `*ObjectBuilder`s. No real cdylib
// required — these pin the shared `decodeEnvelopeWarningsInternal` helper
// (absent → [], order kept, unmodifiable), the `ZanshinWarningCode` registry,
// and that EVERY top-level decoder surfaces the envelope's warnings, mirroring
// crates/zanshin-ffi/src/envelope.rs.

import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zanshin_core/src/ffi/bookmarks.dart' show decodeBookmarksEnvelope;
import 'package:zanshin_core/src/ffi/change.dart' show decodeChangeEnvelope;
import 'package:zanshin_core/src/ffi/commit_views.dart'
    show decodeEvologViewEnvelope, decodeInterdiffViewEnvelope, decodeShowViewEnvelope;
import 'package:zanshin_core/src/ffi/config.dart'
    show
        decodeConfigFileTextEnvelopeInternal,
        decodeConfigFileWriteEnvelopeInternal,
        decodeConfigGcListEnvelopeInternal,
        decodeConfigGcResultEnvelopeInternal,
        decodeConfigGetEnvelopeInternal,
        decodeConfigListEnvelope,
        decodeConfigPathEnvelopeInternal,
        decodeConfigSetEnvelope,
        decodeConfigUnsetEnvelopeInternal;
import 'package:zanshin_core/src/ffi/envelope_zanshin.ffi_generated.dart' as fbs;
import 'package:zanshin_core/src/ffi/file.dart'
    show decodeFileAnnotationEnvelope, decodeFileContentsEnvelope, decodeFileListEnvelope, decodeFileSearchEnvelope;
import 'package:zanshin_core/src/ffi/file_ops.dart' show decodeTrackResultEnvelope, decodeUntrackResultEnvelope;
import 'package:zanshin_core/src/ffi/git.dart'
    show decodeGitExportResultEnvelope, decodeGitImportResultEnvelope, decodeGitRemoteEnvelopeInternal;
import 'package:zanshin_core/src/ffi/graph.dart' show decodeGraphSliceEnvelope;
import 'package:zanshin_core/src/ffi/log_defaults.dart' show decodeLogDefaultsEnvelope;
import 'package:zanshin_core/src/ffi/mutate.dart' show decodeAbsorbResultEnvelope, decodeMutationResultEnvelope;
import 'package:zanshin_core/src/ffi/op_log.dart' show decodeOpLogEnvelope;
import 'package:zanshin_core/src/ffi/precondition.dart' show decodeSnapshotEnvelope;
import 'package:zanshin_core/src/ffi/remotes.dart' show decodeRemotesEnvelope;
import 'package:zanshin_core/src/ffi/repo_detect.dart' show decodeRepoDetectEnvelope;
import 'package:zanshin_core/src/ffi/status.dart' show decodeStatusEnvelope;
import 'package:zanshin_core/src/ffi/warning.dart';
import 'package:zanshin_core/src/ffi/workspace.dart' show decodeWorkspaceListEnvelope, decodeWorkspaceRootEnvelope;

/// The two warnings every "carries them" case puts on the wire, in this order.
const _expected = [
  ZanshinWarning(code: ZanshinWarningCode.configAliasInvalid, message: 'first'),
  ZanshinWarning(code: ZanshinWarningCode.pathsUnmatched, message: 'second\n  line'),
];

List<fbs.WarningObjectBuilder> _wire() => [
  for (final ZanshinWarning w in _expected) fbs.WarningObjectBuilder(code: w.code, message: w.message),
];

/// An ok envelope with [data] of [type], carrying [_expected] unless [warned] is false.
Uint8List _ok(fbs.PayloadTypeId type, Object? data, {bool warned = true}) =>
    fbs.EnvelopeObjectBuilder(ok: true, dataType: type, data: data, warnings: warned ? _wire() : null).toBytes();

/// One decoder under test: its name, the payload it needs, and how to read the
/// warnings off its result.
typedef _Case = ({
  String name,
  fbs.PayloadTypeId type,
  Object? Function() data,
  List<ZanshinWarning> Function(Uint8List) read,
});

final List<_Case> _cases = [
  (
    name: 'status',
    type: fbs.PayloadTypeId.Status,
    data: fbs.StatusObjectBuilder.new,
    read: (b) => decodeStatusEnvelope(b).warnings,
  ),
  (
    name: 'getChange',
    type: fbs.PayloadTypeId.Change,
    data: fbs.ChangeObjectBuilder.new,
    read: (b) => decodeChangeEnvelope(b).warnings,
  ),
  (
    name: 'graphSlice',
    type: fbs.PayloadTypeId.GraphSlice,
    data: fbs.GraphSliceObjectBuilder.new,
    read: (b) => decodeGraphSliceEnvelope(b).warnings,
  ),
  (
    name: 'opLog',
    type: fbs.PayloadTypeId.OpLog,
    data: fbs.OpLogObjectBuilder.new,
    read: (b) => decodeOpLogEnvelope(b).warnings,
  ),
  (
    name: 'bookmarks',
    type: fbs.PayloadTypeId.Bookmarks,
    data: fbs.BookmarksObjectBuilder.new,
    read: (b) => decodeBookmarksEnvelope(b).warnings,
  ),
  (
    name: 'remotes',
    type: fbs.PayloadTypeId.Remotes,
    data: fbs.RemotesObjectBuilder.new,
    read: (b) => decodeRemotesEnvelope(b).warnings,
  ),
  (
    name: 'logDefaults',
    type: fbs.PayloadTypeId.LogDefaults,
    data: fbs.LogDefaultsObjectBuilder.new,
    read: (b) => decodeLogDefaultsEnvelope(b).warnings,
  ),
  (
    name: 'detect',
    type: fbs.PayloadTypeId.RepoDetect,
    data: fbs.RepoDetectObjectBuilder.new,
    read: (b) => decodeRepoDetectEnvelope(b).warnings,
  ),
  (
    name: 'describe & co',
    type: fbs.PayloadTypeId.MutationResult,
    data: fbs.MutationResultObjectBuilder.new,
    read: (b) => decodeMutationResultEnvelope(b).warnings,
  ),
  (
    name: 'gitRemote*',
    type: fbs.PayloadTypeId.MutationResult,
    data: fbs.MutationResultObjectBuilder.new,
    read: (b) => decodeGitRemoteEnvelopeInternal(b).warnings,
  ),
  (
    name: 'absorb',
    type: fbs.PayloadTypeId.AbsorbResult,
    data: fbs.AbsorbResultObjectBuilder.new,
    read: (b) => decodeAbsorbResultEnvelope(b).warnings,
  ),
  (
    name: 'fileList',
    type: fbs.PayloadTypeId.FileList,
    data: fbs.FileListObjectBuilder.new,
    read: (b) => decodeFileListEnvelope(b).warnings,
  ),
  (
    name: 'fileShow',
    type: fbs.PayloadTypeId.FileContents,
    data: fbs.FileContentsObjectBuilder.new,
    read: (b) => decodeFileContentsEnvelope(b).warnings,
  ),
  (
    name: 'fileAnnotate',
    type: fbs.PayloadTypeId.FileAnnotation,
    data: fbs.FileAnnotationObjectBuilder.new,
    read: (b) => decodeFileAnnotationEnvelope(b).warnings,
  ),
  (
    name: 'fileSearch',
    type: fbs.PayloadTypeId.FileSearch,
    data: fbs.FileSearchObjectBuilder.new,
    read: (b) => decodeFileSearchEnvelope(b).warnings,
  ),
  (
    name: 'gitImport',
    type: fbs.PayloadTypeId.GitImportResult,
    data: fbs.GitImportResultObjectBuilder.new,
    read: (b) => decodeGitImportResultEnvelope(b).warnings,
  ),
  (
    name: 'gitExport',
    type: fbs.PayloadTypeId.GitExportResult,
    data: fbs.GitExportResultObjectBuilder.new,
    read: (b) => decodeGitExportResultEnvelope(b).warnings,
  ),
  (
    name: 'show',
    type: fbs.PayloadTypeId.ShowView,
    data: fbs.ShowViewObjectBuilder.new,
    read: (b) => decodeShowViewEnvelope(b).warnings,
  ),
  (
    name: 'evolog',
    type: fbs.PayloadTypeId.EvologView,
    data: fbs.EvologViewObjectBuilder.new,
    read: (b) => decodeEvologViewEnvelope(b).warnings,
  ),
  (
    name: 'interdiff',
    type: fbs.PayloadTypeId.InterdiffView,
    data: fbs.InterdiffViewObjectBuilder.new,
    read: (b) => decodeInterdiffViewEnvelope(b).warnings,
  ),
  (
    name: 'workspaces',
    type: fbs.PayloadTypeId.WorkspaceList,
    data: fbs.WorkspaceListObjectBuilder.new,
    read: (b) => decodeWorkspaceListEnvelope(b).warnings,
  ),
  (
    name: 'workspaceRoot',
    type: fbs.PayloadTypeId.WorkspaceRoot,
    data: () => fbs.WorkspaceRootObjectBuilder(root: '/repo'),
    read: (b) => decodeWorkspaceRootEnvelope(b).warnings,
  ),
  (
    name: 'fileTrack',
    type: fbs.PayloadTypeId.TrackResult,
    data: fbs.TrackResultObjectBuilder.new,
    read: (b) => decodeTrackResultEnvelope(b).warnings,
  ),
  (
    name: 'fileUntrack',
    type: fbs.PayloadTypeId.UntrackResult,
    data: fbs.UntrackResultObjectBuilder.new,
    read: (b) => decodeUntrackResultEnvelope(b).warnings,
  ),
  (
    name: 'configList',
    type: fbs.PayloadTypeId.ConfigListResult,
    data: fbs.ConfigListResultObjectBuilder.new,
    read: (b) => decodeConfigListEnvelope(b).warnings,
  ),
  (
    name: 'configGet',
    type: fbs.PayloadTypeId.ConfigGetResult,
    data: fbs.ConfigGetResultObjectBuilder.new,
    read: (b) => decodeConfigGetEnvelopeInternal(b).warnings,
  ),
  (
    name: 'configPath',
    type: fbs.PayloadTypeId.ConfigPathResult,
    data: fbs.ConfigPathResultObjectBuilder.new,
    read: (b) => decodeConfigPathEnvelopeInternal(b).warnings,
  ),
  (
    name: 'configSet',
    type: fbs.PayloadTypeId.ConfigSetResult,
    data: fbs.ConfigSetResultObjectBuilder.new,
    read: (b) => decodeConfigSetEnvelope(b).warnings,
  ),
  (
    name: 'configUnset',
    type: fbs.PayloadTypeId.ConfigUnsetResult,
    data: fbs.ConfigUnsetResultObjectBuilder.new,
    read: (b) => decodeConfigUnsetEnvelopeInternal(b).warnings,
  ),
  (
    name: 'configFileRead',
    type: fbs.PayloadTypeId.ConfigFileText,
    data: fbs.ConfigFileTextObjectBuilder.new,
    read: (b) => decodeConfigFileTextEnvelopeInternal(b).warnings,
  ),
  (
    name: 'configFileWrite',
    type: fbs.PayloadTypeId.NONE,
    data: () => null,
    read: (b) => decodeConfigFileWriteEnvelopeInternal(b).warnings,
  ),
  (
    name: 'configGcList',
    type: fbs.PayloadTypeId.ConfigGcList,
    data: fbs.ConfigGcListObjectBuilder.new,
    read: (b) => decodeConfigGcListEnvelopeInternal(b).warnings,
  ),
  (
    name: 'configGcDelete',
    type: fbs.PayloadTypeId.ConfigGcResult,
    data: fbs.ConfigGcResultObjectBuilder.new,
    read: (b) => decodeConfigGcResultEnvelopeInternal(b).warnings,
  ),
];

void main() {
  group('decodeEnvelopeWarningsInternal', () {
    test('an absent vector reads as an empty list', () {
      final env = fbs.Envelope(fbs.EnvelopeObjectBuilder(ok: true).toBytes());

      expect(env.warnings, isNull, reason: 'the wire omits an empty list');
      expect(decodeEnvelopeWarningsInternal(env), isEmpty);
    });

    test('the wire order is kept and the list is unmodifiable', () {
      final env = fbs.Envelope(fbs.EnvelopeObjectBuilder(ok: true, warnings: _wire()).toBytes());

      final List<ZanshinWarning> warnings = decodeEnvelopeWarningsInternal(env);

      expect(warnings, _expected);
      expect(() => warnings.add(_expected.first), throwsUnsupportedError);
    });
  });

  group('ZanshinWarningCode', () {
    test('every registered code is a constant equal to its registry string', () {
      // The registry: `docs/rust-error-codes.md` § Warning Codes, emitted from
      // `crates/zanshin-ffi/src/envelope.rs`.
      expect(ZanshinWarningCode.values, const [
        'jj.identity_missing',
        'jj.working_copy_immutable',
        'jj.jjconflict_files_present',
        'jj.git_head_update_failed',
        'jj.git_export_failed',
        'jj.git_import_failed',
        'jj.snapshot_files_refused',
        'jj.snapshot_paths_not_utf8',
        'jj.checkout_files_skipped',
        'jj.paths_unmatched',
        'jj.config_alias_invalid',
        'jj.config_alias_redefined',
        'jj.revset_diagnostic',
        'jj.short_prefixes_failed',
        'jj.remote_url_duplicate',
        'jj.bookmark_target_empty',
        'jj.bookmark_names_unmatched',
        'jj.absorb_path_skipped',
        'jj.path_access_denied',
        'jj.path_not_a_file',
        'jj.config_working_copy_author',
        'jj.config_gc_delete_failed',
        'jj.config_nothing_listed',
      ]);
      expect(ZanshinWarningCode.values.toSet(), hasLength(23), reason: 'no code is registered twice');
    });
  });

  group('WarnedList', () {
    test('is the list it wraps, plus the warnings', () {
      final WarnedList<int> list = WarnedList([1, 2], _expected);

      expect(list, [1, 2]);
      expect(list.warnings, _expected);
      list
        ..add(3)
        ..addAll([4])
        ..[0] = 9;
      expect(list, [9, 2, 3, 4]);
      list.length = 1;
      expect(list, [9]);
    });
  });

  group('every top-level decoder carries the envelope warnings', () {
    for (final _Case c in _cases) {
      test('${c.name}: present → decoded in order', () {
        expect(c.read(_ok(c.type, c.data())), _expected);
      });

      test('${c.name}: absent → []', () {
        expect(c.read(_ok(c.type, c.data(), warned: false)), isEmpty);
      });
    }

    test('snapshot: the returned Precondition carries them', () {
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: true,
        precondition: fbs.PreconditionObjectBuilder(),
        warnings: _wire(),
      ).toBytes();

      expect(decodeSnapshotEnvelope(bytes).warnings, _expected);
    });
  });
}
