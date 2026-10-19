// SPDX-License-Identifier: MIT

// Decode-contract tests for Story 9.20's `GitPushResult` decoder, using
// synthetic FlatBuffers buffers built via the generated `*ObjectBuilder`s. No
// real cdylib required — these exercise the Dart-side decode logic in isolation
// and mirror the Rust round-trip in crates/zanshin-ffi/src/push.rs (AR-P-7
// parity).
//
// Also covers the push / init / clone adapters' argument guards, which fire
// BEFORE any FFI call, so a raw handle of 0 never reaches the cdylib.
//
// Mirrors packages/zanshin_core/test/ffi/squash_split_test.dart.

import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zanshin_core/src/ffi/envelope_zanshin.ffi_generated.dart' as fbs;
import 'package:zanshin_core/src/ffi/push.dart';
import 'package:zanshin_core/src/ffi/repo.dart';
import 'package:zanshin_core/src/ffi/warning.dart';
import 'package:zanshin_core/src/worker/responses.dart';

final Matcher _unknown = throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'ffi.unknown'));

Uint8List _envelope(fbs.GitPushResultObjectBuilder result, {List<fbs.WarningObjectBuilder>? warnings}) =>
    fbs.EnvelopeObjectBuilder(
      ok: true,
      dataType: fbs.PayloadTypeId.GitPushResult,
      data: result,
      warnings: warnings,
    ).toBytes();

fbs.PushRefObjectBuilder _row({
  String? name = 'main',
  fbs.PushRefusalObjectBuilder? refusal,
  fbs.PushRefusalObjectBuilder? explicitRefusal,
  fbs.PushCommitRejectionObjectBuilder? rejection,
}) => fbs.PushRefObjectBuilder(
  kind: fbs.PushRefKind.Bookmark,
  name: name,
  before: 'aaa',
  after: 'bbb',
  action: 'move forward from aaa to bbb',
  path: fbs.PushPath.Push,
  refusal: refusal,
  explicitRefusal: explicitRefusal,
  rejection: rejection,
  status: fbs.PushRefStatus.Pushed,
);

void main() {
  group('decodeGitPushResultEnvelope decode contract', () {
    test('decodes every field, the nested rows and the warnings', () {
      final GitPushResult r = decodeGitPushResultEnvelope(
        _envelope(
          fbs.GitPushResultObjectBuilder(
            remotes: [
              fbs.PushRemoteObjectBuilder(
                name: 'origin',
                refs: [
                  _row(),
                  fbs.PushRefObjectBuilder(
                    kind: fbs.PushRefKind.Tag,
                    name: 'v1',
                    action: 'delete from ccc',
                    before: 'ccc',
                    path: fbs.PushPath.Skip,
                    refusal: fbs.PushRefusalObjectBuilder(message: 'Non-tracking remote tag v1@origin exists'),
                    explicitRefusal: fbs.PushRefusalObjectBuilder(message: 'm', hint: 'h'),
                    rejection: fbs.PushCommitRejectionObjectBuilder(
                      commitId: 'ccc',
                      reasons: const ['has no description'],
                      message: "Won't push commit ccc since it has no description",
                      hints: const ['Rejected commit: ccc'],
                    ),
                    status: fbs.PushRefStatus.RemoteRejected,
                    statusReason: 'hook declined',
                  ),
                  fbs.PushRefObjectBuilder(
                    kind: fbs.PushRefKind.Bookmark,
                    name: 'a',
                    action: 'add to ddd',
                    path: fbs.PushPath.Abort,
                    status: fbs.PushRefStatus.LeaseRejected,
                  ),
                  fbs.PushRefObjectBuilder(
                    kind: fbs.PushRefKind.Bookmark,
                    name: 'b',
                    status: fbs.PushRefStatus.Unexported,
                  ),
                ],
                alreadyMatches: [fbs.PushRefNameObjectBuilder(kind: fbs.PushRefKind.Tag, name: 'v0')],
                finished: true,
                error: 'boom',
              ),
            ],
            createdBookmarks: [fbs.PushCreatedBookmarkObjectBuilder(name: 'push-abc', changeId: 'abc')],
            hints: const ['Pushing to the only existing remote: origin'],
            signing: fbs.PushSigningObjectBuilder(updatedSignatures: 2, rebasedDescendants: 1),
            nothingChanged: false,
            dryRun: true,
            recorded: false,
            description: 'push bookmark main to git remote origin',
            newOpId: 'op',
            failure: fbs.PushFailureObjectBuilder(
              kind: fbs.PushFailureKind.SomeRefsFailed,
              message: 'Failed to push some bookmarks',
              hint: 'h',
            ),
          ),
          warnings: [fbs.WarningObjectBuilder(code: 'jj.push_ref_skipped', message: 'm')],
        ),
      );

      final PushRemote origin = r.remotes.single;
      expect(origin.name, 'origin');
      expect(origin.finished, isTrue);
      expect(origin.error, 'boom');
      expect(origin.alreadyMatches.single.kind, PushRefKind.tag);
      expect(origin.alreadyMatches.single.name, 'v0');
      final PushRef main = origin.refs[0];
      expect(main.kind, PushRefKind.bookmark);
      expect(main.before, 'aaa');
      expect(main.after, 'bbb');
      expect(main.path, PushPath.push);
      expect(main.status, PushRefStatus.pushed);
      expect(main.action, 'move forward from aaa to bbb');
      expect(main.refusal, isNull);
      expect(main.rejection, isNull);
      final PushRef tag = origin.refs[1];
      expect(tag.kind, PushRefKind.tag);
      expect(tag.after, isNull, reason: 'absent is null, never an empty string');
      expect(tag.path, PushPath.skip);
      expect(tag.refusal!.message, 'Non-tracking remote tag v1@origin exists');
      expect(tag.refusal!.hint, isNull);
      expect(tag.explicitRefusal!.hint, 'h');
      expect(tag.rejection!.commitId, 'ccc');
      expect(tag.rejection!.reasons, ['has no description']);
      expect(tag.rejection!.hints, ['Rejected commit: ccc']);
      expect(tag.status, PushRefStatus.remoteRejected);
      expect(tag.statusReason, 'hook declined');
      expect(origin.refs[2].path, PushPath.abort);
      expect(origin.refs[2].status, PushRefStatus.leaseRejected);
      expect(origin.refs[3].status, PushRefStatus.unexported);
      expect(origin.refs[3].action, isNull, reason: 'a conflicted ref has no action');
      expect(r.createdBookmarks.single.name, 'push-abc');
      expect(r.createdBookmarks.single.changeId, 'abc');
      expect(r.hints, ['Pushing to the only existing remote: origin']);
      expect(r.signing!.updatedSignatures, 2);
      expect(r.signing!.rebasedDescendants, 1);
      expect(r.dryRun, isTrue);
      expect(r.recorded, isFalse);
      expect(r.nothingChanged, isFalse);
      expect(r.description, 'push bookmark main to git remote origin');
      expect(r.newOpId, 'op');
      expect(r.failure!.kind, PushFailureKind.someRefsFailed);
      expect(r.failure!.message, 'Failed to push some bookmarks');
      expect(r.failure!.hint, 'h');
      expect(r.warnings.single.code, ZanshinWarningCode.pushRefSkipped);
    });

    test('every failure kind and an empty result decode', () {
      for (final (fbs.PushFailureKind wire, PushFailureKind dart) in [
        (fbs.PushFailureKind.RefRefused, PushFailureKind.refRefused),
        (fbs.PushFailureKind.CommitRejected, PushFailureKind.commitRejected),
        (fbs.PushFailureKind.PushError, PushFailureKind.pushError),
      ]) {
        final GitPushResult r = decodeGitPushResultEnvelope(
          _envelope(
            fbs.GitPushResultObjectBuilder(
              newOpId: 'op',
              nothingChanged: true,
              failure: fbs.PushFailureObjectBuilder(kind: wire, message: 'm'),
            ),
          ),
        );
        expect(r.failure!.kind, dart);
        expect(r.remotes, isEmpty);
        expect(r.createdBookmarks, isEmpty);
        expect(r.hints, isEmpty);
        expect(r.signing, isNull);
        expect(r.description, isNull);
        expect(r.nothingChanged, isTrue);
        expect(r.warnings, isEmpty);
      }
    });

    test('a missing required string is refused, not defaulted', () {
      expect(() => decodeGitPushResultEnvelope(_envelope(fbs.GitPushResultObjectBuilder())), _unknown);
      fbs.GitPushResultObjectBuilder withRow(fbs.PushRefObjectBuilder row) => fbs.GitPushResultObjectBuilder(
        newOpId: 'op',
        remotes: [
          fbs.PushRemoteObjectBuilder(name: 'origin', refs: [row]),
        ],
      );
      expect(() => decodeGitPushResultEnvelope(_envelope(withRow(_row(name: null)))), _unknown);
      expect(
        () => decodeGitPushResultEnvelope(_envelope(withRow(_row(refusal: fbs.PushRefusalObjectBuilder())))),
        _unknown,
      );
      expect(
        () => decodeGitPushResultEnvelope(
          _envelope(withRow(_row(rejection: fbs.PushCommitRejectionObjectBuilder(message: 'm')))),
        ),
        _unknown,
      );
      expect(
        () => decodeGitPushResultEnvelope(
          _envelope(fbs.GitPushResultObjectBuilder(newOpId: 'op', remotes: [fbs.PushRemoteObjectBuilder()])),
        ),
        _unknown,
      );
      expect(
        () => decodeGitPushResultEnvelope(
          _envelope(
            fbs.GitPushResultObjectBuilder(
              newOpId: 'op',
              createdBookmarks: [fbs.PushCreatedBookmarkObjectBuilder(name: 'n')],
            ),
          ),
        ),
        _unknown,
      );
      expect(
        () => decodeGitPushResultEnvelope(
          _envelope(fbs.GitPushResultObjectBuilder(newOpId: 'op', failure: fbs.PushFailureObjectBuilder())),
        ),
        _unknown,
      );
    });

    test('throws ZanshinFfiException on an error envelope and ffi.unknown on a wrong payload', () {
      expect(
        () => decodeGitPushResultEnvelope(
          fbs.EnvelopeObjectBuilder(
            ok: false,
            error: fbs.FfiErrorObjectBuilder(code: 'jj.push_ref_refused', context: 'c'),
          ).toBytes(),
        ),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'jj.push_ref_refused')),
      );
      expect(
        () => decodeGitPushResultEnvelope(
          fbs.EnvelopeObjectBuilder(
            ok: true,
            dataType: fbs.PayloadTypeId.RepoHandle,
            data: fbs.RepoHandleObjectBuilder(handle: 0),
          ).toBytes(),
        ),
        _unknown,
      );
    });
  });

  group('adapter argument guards', () {
    test('every string argument of the push adapter is checked before the FFI call', () {
      const nul = 'a\u0000b';
      expect(() => zanshinGitPush(0, remotes: const [nul]), throwsArgumentError);
      expect(() => zanshinGitPush(0, bookmarks: const [nul]), throwsArgumentError);
      expect(() => zanshinGitPush(0, tags: const [nul]), throwsArgumentError);
      expect(() => zanshinGitPush(0, revisions: const [nul]), throwsArgumentError);
      expect(() => zanshinGitPush(0, changes: const [nul]), throwsArgumentError);
      expect(() => zanshinGitPush(0, named: const [nul]), throwsArgumentError);
      expect(() => zanshinGitPush(0, options: const [nul]), throwsArgumentError);
    });

    test('init and clone check their arguments before the FFI call', () {
      const nul = 'a\u0000b';
      expect(() => zanshinRepoInit(nul, backend: 1), throwsArgumentError);
      expect(() => zanshinRepoInit('/p', backend: 2), throwsArgumentError);
      expect(() => zanshinRepoClone(source: nul, destination: '/d'), throwsArgumentError);
      expect(() => zanshinRepoClone(source: 's', destination: nul), throwsArgumentError);
      expect(() => zanshinRepoClone(source: 's', destination: '/d', remoteName: nul), throwsArgumentError);
      expect(() => zanshinRepoClone(source: 's', destination: '/d', branches: const [nul]), throwsArgumentError);
      expect(() => zanshinRepoClone(source: 's', destination: '/d', tags: const [nul]), throwsArgumentError);
      expect(() => zanshinRepoClone(source: 's', destination: '/d', depth: 0), throwsArgumentError);
      // The wire's `depth` is a uint32: a larger value would wrap silently.
      expect(() => zanshinRepoClone(source: 's', destination: '/d', depth: 0x100000000), throwsArgumentError);
    });
  });
}
