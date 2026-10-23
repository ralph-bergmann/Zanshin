// SPDX-License-Identifier: MIT

// Decode-contract tests for Story 9.32's warning channel, using synthetic
// FlatBuffers buffers built via the generated `*ObjectBuilder`s. No real cdylib
// required — these pin the shared `decodeEnvelopeWarningsInternal` helper
// (absent → [], order kept, unmodifiable), the `ZanshinWarningCode` registry,
// and that EVERY top-level decoder surfaces the envelope's warnings, mirroring
// crates/zanshin-ffi/src/envelope.rs — on the ok arm as the result's `warnings`,
// on the error arm (Story 9.35) as the thrown `ZanshinFfiException`'s
// `warnings` and `precondition`.

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
import 'package:zanshin_core/src/ffi/diagnostics.dart' show decodeDiagnosticsEnvelope;
import 'package:zanshin_core/src/ffi/envelope_zanshin.ffi_generated.dart' as fbs;
import 'package:zanshin_core/src/ffi/file.dart'
    show decodeFileAnnotationEnvelope, decodeFileContentsEnvelope, decodeFileListEnvelope, decodeFileSearchEnvelope;
import 'package:zanshin_core/src/ffi/file_ops.dart' show decodeTrackResultEnvelope, decodeUntrackResultEnvelope;
import 'package:zanshin_core/src/ffi/git.dart'
    show decodeGitExportResultEnvelope, decodeGitImportResultEnvelope, decodeGitRemoteEnvelopeInternal;
import 'package:zanshin_core/src/ffi/graph.dart' show GraphTopologyView;
import 'package:zanshin_core/src/ffi/log_defaults.dart' show decodeLogDefaultsEnvelope;
import 'package:zanshin_core/src/ffi/mutate.dart' show decodeAbsorbResultEnvelope, decodeMutationResultEnvelope;
import 'package:zanshin_core/src/ffi/op_log.dart'
    show decodeOpAbandonResultEnvelope, decodeOpDiffResultEnvelope, decodeOpLogEnvelope, decodeOpShowEnvelope;
import 'package:zanshin_core/src/ffi/precondition.dart' show Precondition, decodeCreationReport, decodeSnapshotEnvelope;
import 'package:zanshin_core/src/ffi/remotes.dart' show decodeRemotesEnvelope;
import 'package:zanshin_core/src/ffi/repo_detect.dart' show decodeRepoDetectEnvelope;
import 'package:zanshin_core/src/ffi/status.dart' show decodeStatusEnvelope;
import 'package:zanshin_core/src/ffi/warning.dart';
import 'package:zanshin_core/src/ffi/workspace.dart'
    show
        decodeStaleRecoveryEnvelope,
        decodeWorkspaceAddEnvelope,
        decodeWorkspaceListEnvelope,
        decodeWorkspaceRootEnvelope;
import 'package:zanshin_core/src/worker/responses.dart' show ZanshinFfiException;

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

/// An error envelope (`jj.invalid_input`, context `ctx`) carrying a partial
/// precondition unless [preconditioned] is false and [_expected] unless [warned]
/// is false; without its `error` table when [coded] is false.
Uint8List _error({bool preconditioned = true, bool warned = true, bool coded = true}) => fbs.EnvelopeObjectBuilder(
  ok: false,
  error: coded ? fbs.FfiErrorObjectBuilder(code: 'jj.invalid_input', context: 'ctx') : null,
  precondition: preconditioned
      ? fbs.PreconditionObjectBuilder(
          wasSnapshotTaken: true,
          gitHeadImported: true,
          gitHeadReset: true,
          gitHeadRebased: 3,
          snapshotRebased: 4,
          gitRefsRebased: 5,
        )
      : null,
  warnings: warned ? _wire() : null,
).toBytes();

/// The exception [_error] stands for, its report included.
final Matcher _throwsReported = throwsA(
  isA<ZanshinFfiException>()
      .having((e) => e.code, 'code', 'jj.invalid_input')
      .having((e) => e.context, 'context', 'ctx')
      .having((e) => e.warnings, 'warnings', _expected)
      .having((e) => e.precondition?.wasSnapshotTaken, 'precondition.wasSnapshotTaken', isTrue)
      .having((e) => e.precondition?.gitHeadImported, 'precondition.gitHeadImported', isTrue)
      .having((e) => e.precondition?.gitHeadReset, 'precondition.gitHeadReset', isTrue)
      .having((e) => e.precondition?.gitHeadRebased, 'precondition.gitHeadRebased', 3)
      .having((e) => e.precondition?.snapshotRebased, 'precondition.snapshotRebased', 4)
      .having((e) => e.precondition?.gitRefsRebased, 'precondition.gitRefsRebased', 5)
      .having((e) => e.precondition?.warnings, 'precondition.warnings', isEmpty),
);

/// The exception a report-less [_error] stands for.
final Matcher _throwsBare = throwsA(
  isA<ZanshinFfiException>()
      .having((e) => e.code, 'code', 'jj.invalid_input')
      .having((e) => e.context, 'context', 'ctx')
      .having((e) => e.warnings, 'warnings', isEmpty)
      .having((e) => e.precondition, 'precondition', isNull),
);

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
    name: 'opShow',
    type: fbs.PayloadTypeId.OpShow,
    data: () => fbs.OpShowObjectBuilder(operation: fbs.OperationObjectBuilder(id: 'o')),
    read: (b) => decodeOpShowEnvelope(b).warnings,
  ),
  (
    name: 'opDiff',
    type: fbs.PayloadTypeId.OpDiffResult,
    data: () => fbs.OpDiffResultObjectBuilder(
      to: fbs.OperationObjectBuilder(id: 'o'),
      diff: fbs.OpDiffObjectBuilder(),
    ),
    read: (b) => decodeOpDiffResultEnvelope(b).warnings,
  ),
  (
    name: 'opAbandon',
    type: fbs.PayloadTypeId.OpAbandonResult,
    data: fbs.OpAbandonResultObjectBuilder.new,
    read: (b) => decodeOpAbandonResultEnvelope(b).warnings,
  ),
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
    name: 'graphTopology',
    type: fbs.PayloadTypeId.GraphTopology,
    // The minimal valid payload: no node, no edge, no anchor.
    data: () => fbs.GraphTopologyObjectBuilder(
      operationId: 'ab',
      commitIds: const [],
      changeIds: const [],
      flags: const [],
      changeOffset: const [],
      changeIdPrefixLen: const [],
      commitIdPrefixLen: const [],
      parentCount: const [],
      edgeStart: const [0],
      edgeTarget: const [],
      edgeKind: const [],
      refs: const [],
      workingCopies: const [],
      anchorStart: const [0],
      anchorNode: const [],
    ),
    read: (b) => GraphTopologyView.fromEnvelope(b).warnings,
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
    name: 'workspaceAdd',
    type: fbs.PayloadTypeId.WorkspaceAddResult,
    data: () => fbs.WorkspaceAddResultObjectBuilder(
      workspaceName: 'ws2',
      workspaceRoot: '/ws2',
      checkout: fbs.CheckoutStatsObjectBuilder(),
    ),
    read: (b) => decodeWorkspaceAddEnvelope(b).warnings,
  ),
  (
    name: 'workspaceUpdateStale',
    type: fbs.PayloadTypeId.StaleRecovery,
    data: () => fbs.StaleRecoveryObjectBuilder(opId: 'head'),
    read: (b) => decodeStaleRecoveryEnvelope(b).warnings,
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
        'jj.unresolved_conflicts',
        'jj.paths_unmatched',
        'jj.config_alias_invalid',
        'jj.config_alias_redefined',
        'jj.revset_diagnostic',
        'jj.short_prefixes_failed',
        'jj.remote_url_duplicate',
        'jj.bookmark_target_empty',
        'jj.bookmark_names_unmatched',
        'jj.bookmark_auto_track_existing',
        'jj.bookmark_rename_remote_exists',
        'jj.bookmark_tracking_dropped',
        'jj.bookmark_remotes_not_renamed',
        'jj.bookmark_tracked_remotes_exist',
        'jj.absorb_path_skipped',
        'jj.path_access_denied',
        'jj.path_not_a_file',
        'jj.config_working_copy_author',
        'jj.config_gc_delete_failed',
        'jj.config_nothing_listed',
        'jj.clone_cleanup_failed',
        'jj.config_migrated',
        'jj.config_copied',
        'jj.config_regenerated',
        'jj.undo_push_operation',
        'jj.undo_workspace_removal',
        'jj.colocated_in_git_worktree',
        'jj.workspace_path_inaccessible',
        'jj.workspace_in_current_directory',
        'jj.split_all_selected',
        'jj.split_none_selected',
        'jj.commit_paths_unmatched',
        'jj.push_remotes_unmatched',
        'jj.push_bookmarks_unmatched',
        'jj.push_tags_unmatched',
        'jj.push_revset_empty',
        'jj.push_revisions_empty',
        'jj.push_ref_skipped',
        'jj.push_commit_skipped',
        'jj.push_refs_moved_on_remote',
        'jj.push_remote_rejected',
        'jj.push_bookmarks_not_updated_locally',
        'jj.push_signing_skipped_immutable',
        'jj.clone_branches_unmatched',
        'jj.template_diagnostic',
        'jj.fetch_remotes_unmatched',
        'jj.fetch_refspec_ignored',
        'jj.fetch_branches_unmatched',
        'jj.trunk_alias_unresolved',
        'jj.duplicate_as_own_descendant',
        'jj.duplicate_as_own_ancestor',
        'jj.fix_tool_start_failed',
        'jj.fix_tool_failed',
        'jj.fileset_diagnostic',
        'jj.config_deprecated',
        'jj.op_diff_changes_unresolved',
        'jj.op_abandon_working_copy_not_updated',
        'env.login_shell_unresolved',
      ]);
      expect(ZanshinWarningCode.values.toSet(), hasLength(67), reason: 'no code is registered twice');
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

    // Story 9.33: init/clone/convert answer with a RepoHandle whose envelope
    // carries the creating call's report.
    test('creation: the report carries them and the precondition', () {
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.RepoHandle,
        data: fbs.RepoHandleObjectBuilder(handle: 1, sessionId: 1),
        precondition: fbs.PreconditionObjectBuilder(wasSnapshotTaken: true),
        warnings: _wire(),
      ).toBytes();

      final (:List<ZanshinWarning> warnings, :Precondition? precondition) = decodeCreationReport(bytes);

      expect(warnings, _expected);
      expect(precondition?.wasSnapshotTaken, isTrue);
    });

    test('creation: absent → [] and null', () {
      final (:List<ZanshinWarning> warnings, :Precondition? precondition) = decodeCreationReport(
        _ok(fbs.PayloadTypeId.RepoHandle, fbs.RepoHandleObjectBuilder(handle: 1, sessionId: 1), warned: false),
      );

      expect(warnings, isEmpty);
      expect(precondition, isNull);
    });
  });

  // Story 9.35: the error arm keeps the report — every `!env.ok` branch throws
  // through the one shared `decodeEnvelopeErrorInternal`.
  group('every top-level decoder throws the error envelope with its report', () {
    for (final _Case c in _cases) {
      test('${c.name}: present → on the exception', () {
        expect(() => c.read(_error()), _throwsReported);
      });

      test('${c.name}: absent → null and []', () {
        expect(() => c.read(_error(preconditioned: false, warned: false)), _throwsBare);
      });
    }

    test('snapshot: present → on the exception', () {
      expect(() => decodeSnapshotEnvelope(_error()), _throwsReported);
    });

    test('snapshot: absent → null and []', () {
      expect(() => decodeSnapshotEnvelope(_error(preconditioned: false, warned: false)), _throwsBare);
    });

    test('diagnostics: present → on the exception', () {
      expect(() => decodeDiagnosticsEnvelope(_error()), _throwsReported);
    });

    test('diagnostics: absent → null and []', () {
      expect(() => decodeDiagnosticsEnvelope(_error(preconditioned: false, warned: false)), _throwsBare);
    });

    test('no error table → ffi.unknown without a context', () {
      expect(
        () => decodeStatusEnvelope(_error(preconditioned: false, warned: false, coded: false)),
        throwsA(
          isA<ZanshinFfiException>()
              .having((e) => e.code, 'code', 'ffi.unknown')
              .having((e) => e.context, 'context', isNull)
              .having((e) => e.warnings, 'warnings', isEmpty)
              .having((e) => e.precondition, 'precondition', isNull),
        ),
      );
    });

    // Real envelopes carry one half without the other: a clone refusal has
    // warnings only, a config_set failure may have a precondition only.
    test('warnings only → decoded, precondition null', () {
      expect(
        () => decodeStatusEnvelope(_error(preconditioned: false)),
        throwsA(
          isA<ZanshinFfiException>()
              .having((e) => e.code, 'code', 'jj.invalid_input')
              .having((e) => e.warnings, 'warnings', _expected)
              .having((e) => e.precondition, 'precondition', isNull),
        ),
      );
    });

    test('precondition only → decoded, warnings []', () {
      expect(
        () => decodeStatusEnvelope(_error(warned: false)),
        throwsA(
          isA<ZanshinFfiException>()
              .having((e) => e.code, 'code', 'jj.invalid_input')
              .having((e) => e.warnings, 'warnings', isEmpty)
              .having((e) => e.precondition?.wasSnapshotTaken, 'precondition.wasSnapshotTaken', isTrue)
              .having((e) => e.precondition?.gitRefsRebased, 'precondition.gitRefsRebased', 5),
        ),
      );
    });

    test("the exception's warnings are unmodifiable", () {
      final ZanshinFfiException e;
      try {
        decodeStatusEnvelope(_error());
        fail('an error envelope must throw');
      } on ZanshinFfiException catch (thrown) {
        e = thrown;
      }

      expect(() => e.warnings.add(_expected.first), throwsUnsupportedError);
    });

    test('the positional constructor carries no report', () {
      const e = ZanshinFfiException('ffi.unknown', 'corrupt');

      expect(e.precondition, isNull);
      expect(e.warnings, isEmpty);
      expect(e.hints, isEmpty);
      expect(e.toString(), 'ZanshinFfiException(ffi.unknown: corrupt)');
    });

    test('toString names the hints when there are some (Story 9.56)', () {
      const e = ZanshinFfiException.withReport(
        'jj.invalid_input',
        'reserved',
        precondition: null,
        warnings: [],
        hints: ['first', 'second'],
      );

      expect(e.toString(), 'ZanshinFfiException(jj.invalid_input: reserved; hints: first | second)');
    });

    // Story 9.56: the error's hints ride the exception — absent reads as [], order and embedded
    // newlines are kept, the list is unmodifiable.
    test("an error envelope's hints reach the exception", () {
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: false,
        error: fbs.FfiErrorObjectBuilder(
          code: 'jj.invalid_input',
          context: "Git remote named 'git' is reserved for local Git repository",
          hints: ['Run `jj git remote rename` to give a different name.', 'second\nline'],
        ),
      ).toBytes();

      expect(
        () => decodeStatusEnvelope(bytes),
        throwsA(
          isA<ZanshinFfiException>()
              .having((e) => e.context, 'context', "Git remote named 'git' is reserved for local Git repository")
              .having((e) => e.hints, 'hints', ['Run `jj git remote rename` to give a different name.', 'second\nline'])
              .having(
                (e) =>
                    () => e.hints.add('x'),
                'hints.add',
                throwsUnsupportedError,
              ),
        ),
      );
      expect(
        () => decodeStatusEnvelope(_error()),
        throwsA(isA<ZanshinFfiException>().having((e) => e.hints, 'hints', isEmpty)),
      );
    });

    // Story 9.57: what a failed conversion left on disk rides the exception — absent reads as
    // [], the wire order (outermost first) is kept, the list is unmodifiable.
    test("an error envelope's left-behind paths reach the exception", () {
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: false,
        error: fbs.FfiErrorObjectBuilder(
          code: 'jj.convert_failed',
          context: 'snapshot failed',
          leftBehind: ['/w', '/w/.jj'],
        ),
      ).toBytes();

      expect(
        () => decodeStatusEnvelope(bytes),
        throwsA(
          isA<ZanshinFfiException>()
              .having((e) => e.leftBehind, 'leftBehind', ['/w', '/w/.jj'])
              .having((e) => e.hints, 'hints', isEmpty)
              .having(
                (e) =>
                    () => e.leftBehind.add('x'),
                'leftBehind.add',
                throwsUnsupportedError,
              ),
        ),
      );
      expect(
        () => decodeStatusEnvelope(_error()),
        throwsA(isA<ZanshinFfiException>().having((e) => e.leftBehind, 'leftBehind', isEmpty)),
      );
    });

    test('toString names the left-behind paths when there are some (Story 9.57)', () {
      const e = ZanshinFfiException.withReport(
        'jj.convert_failed',
        'snapshot failed',
        precondition: null,
        warnings: [],
        leftBehind: ['/w/.jj'],
      );

      expect(e.toString(), 'ZanshinFfiException(jj.convert_failed: snapshot failed; left behind: /w/.jj)');
      expect(const ZanshinFfiException('ffi.unknown').leftBehind, isEmpty);
    });
  });
}
