// SPDX-License-Identifier: MIT

// Decode-contract tests for Story 9.31's two decoders (drop actions, change
// actions) and the `DropActionsRequest` builder, using synthetic FlatBuffers
// buffers built via the generated `*ObjectBuilder`s. No real cdylib required —
// these tests exercise the Dart-side encode/decode logic in isolation and mirror
// the Rust round-trips in crates/zanshin-ffi/src/envelope.rs (AR-P-7 parity).
//
// Also covers the adapters' interior-NUL guards, which fire BEFORE any FFI
// call, so a raw handle of 0 never reaches the cdylib.

import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zanshin_core/src/ffi/drop_actions.dart';
import 'package:zanshin_core/src/ffi/envelope_zanshin.ffi_generated.dart' as fbs;
import 'package:zanshin_core/src/ffi/warning.dart';
import 'package:zanshin_core/src/worker/responses.dart';

/// An error envelope carrying [code].
Uint8List errorEnvelope(String code, String context) => fbs.EnvelopeObjectBuilder(
  ok: false,
  error: fbs.FfiErrorObjectBuilder(code: code, context: context),
).toBytes();

/// An ok envelope whose union variant is deliberately the WRONG one.
Uint8List wrongPayload() => fbs.EnvelopeObjectBuilder(
  ok: true,
  dataType: fbs.PayloadTypeId.RepoHandle,
  data: fbs.RepoHandleObjectBuilder(handle: 0),
).toBytes();

final Matcher _unknown = throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'ffi.unknown'));

fbs.ActionOutcomeObjectBuilder outcome(
  fbs.ActionStatus status, {
  fbs.FfiErrorObjectBuilder? refusal,
  bool combined = false,
  bool backwards = false,
}) => fbs.ActionOutcomeObjectBuilder(
  status: status,
  refusal: refusal,
  combinedDescriptionNeeded: combined,
  allowBackwardsNeeded: backwards,
);

void main() {
  group('decodeDropActionsEnvelope decode contract', () {
    test('decodes every verb, location, status, refusal and flag', () {
      const List<(fbs.DropVerb, DropVerb)> verbs = [
        (fbs.DropVerb.RebaseSource, DropVerb.rebaseSource),
        (fbs.DropVerb.RebaseRevisions, DropVerb.rebaseRevisions),
        (fbs.DropVerb.Squash, DropVerb.squash),
        (fbs.DropVerb.NewMerge, DropVerb.newMerge),
        (fbs.DropVerb.Duplicate, DropVerb.duplicate),
        (fbs.DropVerb.Split, DropVerb.split),
        (fbs.DropVerb.BookmarkMove, DropVerb.bookmarkMove),
      ];
      final List<fbs.ActionOutcomeObjectBuilder> outcomes = [
        outcome(fbs.ActionStatus.NoOp),
        outcome(
          fbs.ActionStatus.Refused,
          refusal: fbs.FfiErrorObjectBuilder(code: 'jj.invalid_input', context: 'Cannot rebase x onto itself'),
        ),
        outcome(fbs.ActionStatus.Available, combined: true),
        outcome(fbs.ActionStatus.Available),
        outcome(fbs.ActionStatus.Refused, refusal: fbs.FfiErrorObjectBuilder(code: 'jj.not_a_git_repo')),
        outcome(fbs.ActionStatus.Available),
        outcome(fbs.ActionStatus.Available, backwards: true),
      ];
      final DropActions actions = decodeDropActionsEnvelope(
        fbs.EnvelopeObjectBuilder(
          ok: true,
          dataType: fbs.PayloadTypeId.DropActions,
          data: fbs.DropActionsObjectBuilder(
            actions: [
              for (var i = 0; i < verbs.length; i++)
                fbs.DropActionObjectBuilder(verb: verbs[i].$1, location: i, outcome: outcomes[i]),
            ],
          ),
          warnings: [fbs.WarningObjectBuilder(code: 'jj.paths_unmatched', message: 'm')],
        ).toBytes(),
      );

      expect(actions.actions.map((a) => a.verb), verbs.map((v) => v.$2));
      expect(actions.actions.map((a) => a.location), [0, 1, 2, 3, 4, 5, 6]);
      expect(actions.actions.map((a) => a.outcome.status), [
        ActionStatus.noOp,
        ActionStatus.refused,
        ActionStatus.available,
        ActionStatus.available,
        ActionStatus.refused,
        ActionStatus.available,
        ActionStatus.available,
      ]);
      expect(actions.actions[0].outcome.refusal, isNull);
      expect(actions.actions[1].outcome.refusal?.code, 'jj.invalid_input');
      expect(actions.actions[1].outcome.refusal?.context, 'Cannot rebase x onto itself');
      expect(actions.actions[4].outcome.refusal?.context, isNull, reason: 'an absent context stays null');
      expect(actions.actions[2].outcome.combinedDescriptionNeeded, isTrue);
      expect(actions.actions[6].outcome.allowBackwardsNeeded, isTrue);
      expect(
        actions.actions[3].outcome.combinedDescriptionNeeded || actions.actions[3].outcome.allowBackwardsNeeded,
        isFalse,
      );
      expect(actions.warnings.single.code, ZanshinWarningCode.pathsUnmatched);
    });

    test('an absent actions vector is no rows', () {
      final DropActions actions = decodeDropActionsEnvelope(
        fbs.EnvelopeObjectBuilder(
          ok: true,
          dataType: fbs.PayloadTypeId.DropActions,
          data: fbs.DropActionsObjectBuilder(),
        ).toBytes(),
      );
      expect(actions.actions, isEmpty);
      expect(actions.warnings, isEmpty);
    });

    test('a row without its outcome, or a refusal without its code, is malformed', () {
      expect(
        () => decodeDropActionsEnvelope(
          fbs.EnvelopeObjectBuilder(
            ok: true,
            dataType: fbs.PayloadTypeId.DropActions,
            data: fbs.DropActionsObjectBuilder(actions: [fbs.DropActionObjectBuilder(verb: fbs.DropVerb.Squash)]),
          ).toBytes(),
        ),
        _unknown,
      );
      expect(
        () => decodeDropActionsEnvelope(
          fbs.EnvelopeObjectBuilder(
            ok: true,
            dataType: fbs.PayloadTypeId.DropActions,
            data: fbs.DropActionsObjectBuilder(
              actions: [
                fbs.DropActionObjectBuilder(
                  verb: fbs.DropVerb.Squash,
                  outcome: outcome(fbs.ActionStatus.Refused, refusal: fbs.FfiErrorObjectBuilder()),
                ),
              ],
            ),
          ).toBytes(),
        ),
        _unknown,
      );
    });

    test('throws ZanshinFfiException on an error envelope', () {
      expect(
        () => decodeDropActionsEnvelope(errorEnvelope('jj.invalid_input', 'boom')),
        throwsA(
          isA<ZanshinFfiException>()
              .having((e) => e.code, 'code', 'jj.invalid_input')
              .having((e) => e.context, 'context', 'boom'),
        ),
      );
    });

    test('throws ffi.unknown on a non-DropActions payload', () {
      expect(() => decodeDropActionsEnvelope(wrongPayload()), _unknown);
    });
  });

  group('decodeChangeActionsEnvelope decode contract', () {
    test('decodes the seven outcomes in field order', () {
      final ChangeActions card = decodeChangeActionsEnvelope(
        fbs.EnvelopeObjectBuilder(
          ok: true,
          dataType: fbs.PayloadTypeId.ChangeActions,
          data: fbs.ChangeActionsObjectBuilder(
            newOnto: outcome(fbs.ActionStatus.Available),
            newInsertAfter: outcome(fbs.ActionStatus.Available),
            newInsertBefore: outcome(
              fbs.ActionStatus.Refused,
              refusal: fbs.FfiErrorObjectBuilder(code: 'jj.immutable', context: 'abc'),
            ),
            edit: outcome(fbs.ActionStatus.Refused, refusal: fbs.FfiErrorObjectBuilder(code: 'jj.immutable')),
            describe: outcome(fbs.ActionStatus.Available),
            squashIntoParent: outcome(fbs.ActionStatus.NoOp, combined: true),
            abandon: outcome(fbs.ActionStatus.Available),
          ),
        ).toBytes(),
      );

      expect(
        [
          card.newOnto,
          card.newInsertAfter,
          card.newInsertBefore,
          card.edit,
          card.describe,
          card.squashIntoParent,
          card.abandon,
        ].map((o) => o.status),
        [
          ActionStatus.available,
          ActionStatus.available,
          ActionStatus.refused,
          ActionStatus.refused,
          ActionStatus.available,
          ActionStatus.noOp,
          ActionStatus.available,
        ],
      );
      expect(card.newInsertBefore.refusal?.context, 'abc');
      expect(card.squashIntoParent.combinedDescriptionNeeded, isTrue);
      expect(card.warnings, isEmpty);
    });

    test('a missing outcome is malformed', () {
      expect(
        () => decodeChangeActionsEnvelope(
          fbs.EnvelopeObjectBuilder(
            ok: true,
            dataType: fbs.PayloadTypeId.ChangeActions,
            data: fbs.ChangeActionsObjectBuilder(newOnto: outcome(fbs.ActionStatus.Available)),
          ).toBytes(),
        ),
        _unknown,
      );
    });

    test('throws on an error envelope and on a non-ChangeActions payload', () {
      expect(
        () => decodeChangeActionsEnvelope(errorEnvelope('ffi.invalid_handle', 'h')),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'ffi.invalid_handle')),
      );
      expect(() => decodeChangeActionsEnvelope(wrongPayload()), _unknown);
    });
  });

  group('dropActionsRequestBytes', () {
    test('writes every source kind and every location list', () {
      final change = fbs.DropActionsRequest(
        dropActionsRequestBytes(const ChangeDropSource('s'), const [
          DropLocation(onto: ['t']),
          DropLocation(insertAfter: ['a'], insertBefore: ['b']),
        ]),
      );
      expect(change.kind, fbs.RequestKind.DropActions);
      expect(change.sourceKind, fbs.DropSourceKind.Change);
      expect(change.changeId, 's');
      expect(change.paths, isNull);
      expect(change.bookmark, isNull);
      expect(change.locations!.map((l) => l.onto), [
        ['t'],
        <String>[],
      ]);
      expect(change.locations![1].insertAfter, ['a']);
      expect(change.locations![1].insertBefore, ['b']);

      final selection = fbs.DropActionsRequest(
        dropActionsRequestBytes(const SelectionDropSource('s', ['f']), const []),
      );
      expect(selection.sourceKind, fbs.DropSourceKind.Selection);
      expect(selection.changeId, 's');
      expect(selection.paths, ['f']);

      final bookmark = fbs.DropActionsRequest(
        dropActionsRequestBytes(const BookmarkDropSource('main'), const []),
      );
      expect(bookmark.sourceKind, fbs.DropSourceKind.Bookmark);
      expect((bookmark.changeId, bookmark.bookmark), (null, 'main'));
    });

    test('an interior NUL is refused before any FFI call', () {
      expect(() => zanshinDropActions(0, const ChangeDropSource('a\u0000b'), const []), throwsArgumentError);
      expect(
        () => zanshinDropActions(0, const SelectionDropSource('s', ['a\u0000b']), const []),
        throwsArgumentError,
      );
      expect(() => zanshinDropActions(0, const BookmarkDropSource('a\u0000b'), const []), throwsArgumentError);
      expect(
        () => zanshinDropActions(0, const ChangeDropSource('s'), const [
          DropLocation(insertBefore: ['a\u0000b']),
        ]),
        throwsArgumentError,
      );
      expect(() => zanshinChangeActions(0, 'a\u0000b'), throwsArgumentError);
    });
  });
}
