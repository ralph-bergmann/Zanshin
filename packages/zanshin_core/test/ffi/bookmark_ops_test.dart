// SPDX-License-Identifier: MIT

// Wire-shape and guard tests for the bookmark mutation adapters (Story 9.8's
// create / delete, Story 9.19's move / advance / rename),
// using synthetic FlatBuffers buffers built via the generated `*ObjectBuilder`s.
// No real cdylib required - these exercise the Dart-side request encoding and
// the adapters' NUL backstop in isolation, and mirror the Rust-side readers in
// crates/zanshin-ffi/src/bookmark_ops.rs (AR-P-7 parity).
//
// There is deliberately no decoder test for a bookmark-specific payload: both
// verbs return the shipped `MutationResult`, so what is pinned here is that the
// two NEW error codes travel through the shipped decoder unchanged.
//
// Mirrors packages/zanshin_core/test/ffi/workspace_test.dart.

import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zanshin_core/src/ffi/bookmark_ops.dart';
import 'package:zanshin_core/src/ffi/envelope_zanshin.ffi_generated.dart' as fbs;
import 'package:zanshin_core/src/ffi/mutate.dart' show decodeMutationResultEnvelope, zanshinNewChange;
import 'package:zanshin_core/src/worker/responses.dart';

/// An error envelope carrying [code].
Uint8List errorEnvelope(String code, String context) => fbs.EnvelopeObjectBuilder(
  ok: false,
  error: fbs.FfiErrorObjectBuilder(code: code, context: context),
).toBytes();

void main() {
  group('BookmarkCreateRequest wire shape', () {
    test('an absent revision stays null - it is what applies the CLI -r default', () {
      final req = fbs.BookmarkCreateRequest(
        fbs.BookmarkCreateRequestObjectBuilder(kind: fbs.RequestKind.BookmarkCreate, names: ['feature']).toBytes(),
      );

      expect(req.kind, fbs.RequestKind.BookmarkCreate, reason: 'the tag rides field 0 of every request');
      expect(req.names, ['feature']);
      expect(req.revision, isNull, reason: 'null-for-absence: absent means `@`');
    });

    test('a present revision and several names survive in ARGUMENT order', () {
      final req = fbs.BookmarkCreateRequest(
        fbs.BookmarkCreateRequestObjectBuilder(
          kind: fbs.RequestKind.BookmarkCreate,
          names: ['b', 'a'],
          revision: 'qpvuntsm',
        ).toBytes(),
      );

      expect(req.names, ['b', 'a'], reason: 'argument order is the fail-fast order');
      expect(req.revision, 'qpvuntsm');
    });

    test('an explicitly empty revision is a VALUE, not an absence', () {
      final req = fbs.BookmarkCreateRequest(
        fbs.BookmarkCreateRequestObjectBuilder(
          kind: fbs.RequestKind.BookmarkCreate,
          names: ['feature'],
          revision: '',
        ).toBytes(),
      );

      expect(req.revision, isNotNull);
      expect(req.revision, isEmpty);
    });
  });

  group('BookmarkDeleteRequest wire shape', () {
    test('patterns cross verbatim, including their kind prefixes', () {
      final req = fbs.BookmarkDeleteRequest(
        fbs.BookmarkDeleteRequestObjectBuilder(
          kind: fbs.RequestKind.BookmarkDelete,
          names: [r'glob:"foo-*"', 'exact:bar'],
        ).toBytes(),
      );

      expect(req.kind, fbs.RequestKind.BookmarkDelete, reason: 'the tag rides field 0 of every request');
      expect(req.names, [r'glob:"foo-*"', 'exact:bar']);
    });

    test('an empty pattern list is carried as an empty vector, not dropped', () {
      final req = fbs.BookmarkDeleteRequest(
        fbs.BookmarkDeleteRequestObjectBuilder(kind: fbs.RequestKind.BookmarkDelete, names: const <String>[]).toBytes(),
      );

      // Either wire form reaches the same jj-level refusal (`jj.invalid_input`),
      // so the assertion is only that nothing else is smuggled in.
      expect(req.names ?? const <String>[], isEmpty);
      expect(req.kind, fbs.RequestKind.BookmarkDelete);
    });
  });

  group('the request-kind tag', () {
    test('an unset kind reads back as Unspecified, which Rust always refuses', () {
      // FlatBuffers writes no bytes for a field equal to its default, so this buffer is
      // byte-identical to one built before the tag existed - "legacy buffer" and "forgotten
      // tag" are the same, always-refused state.
      final req = fbs.BookmarkDeleteRequest(
        fbs.BookmarkDeleteRequestObjectBuilder(names: ['feature']).toBytes(),
      );

      expect(req.kind, fbs.RequestKind.Unspecified);
    });

    test('the two ChangeIdList wrappers tag the SAME table differently', () {
      // The one table read by both zanshin_new_change (as parents) and zanshin_abandon (as
      // change_ids): a per-table tag would leave that pair - one of them destructive -
      // unrefused, so the tag is per-WRAPPER.
      final asParents = fbs.ChangeIdList(
        fbs.ChangeIdListObjectBuilder(kind: fbs.RequestKind.NewChange, changeIds: ['qpvuntsm']).toBytes(),
      );
      final asTargets = fbs.ChangeIdList(
        fbs.ChangeIdListObjectBuilder(kind: fbs.RequestKind.Abandon, changeIds: ['qpvuntsm']).toBytes(),
      );

      expect(asParents.kind, fbs.RequestKind.NewChange);
      expect(asTargets.kind, fbs.RequestKind.Abandon);
      expect(asParents.changeIds, asTargets.changeIds, reason: 'only the tag differs');
    });

    test('a NewChange ChangeIdList carries the -A / -B lists after change_ids', () {
      // Story 9.48: only zanshin_new_change reads insert_after / insert_before.
      final req = fbs.ChangeIdList(
        fbs.ChangeIdListObjectBuilder(
          kind: fbs.RequestKind.NewChange,
          changeIds: const [],
          insertAfter: ['after1', 'after2'],
          insertBefore: ['before1'],
        ).toBytes(),
      );

      expect(req.changeIds, isEmpty);
      expect(req.insertAfter, ['after1', 'after2']);
      expect(req.insertBefore, ['before1']);
    });
  });

  group('adapter guards', () {
    // A raw handle of 0 would be `ffi.invalid_handle` if the call went through -
    // it must not, so each guard has to fire first. These are the DIRECT-CALLER
    // backstop; the primary guard lives in ZanshinWorker / RepoHandle, because
    // inside the worker isolate a throw here returns as `internal.dispatch_error`.
    final nul = String.fromCharCode(0);

    test('zanshinBookmarkCreate rejects an interior NUL in a name', () {
      expect(
        () => zanshinBookmarkCreate(0, ['fea${nul}ture']),
        throwsA(isA<ArgumentError>().having((e) => e.name, 'name', 'names')),
      );
    });

    test('zanshinBookmarkCreate rejects an interior NUL in the revision', () {
      expect(
        () => zanshinBookmarkCreate(0, ['feature'], revision: 'qpv${nul}untsm'),
        throwsA(isA<ArgumentError>().having((e) => e.name, 'name', 'revision')),
      );
    });

    test('zanshinNewChange rejects an interior NUL in any list', () {
      expect(
        () => zanshinNewChange(0, ['qpv${nul}untsm']),
        throwsA(isA<ArgumentError>().having((e) => e.name, 'name', 'parents')),
      );
      expect(
        () => zanshinNewChange(0, const [], insertAfter: ['qpv${nul}untsm']),
        throwsA(isA<ArgumentError>().having((e) => e.name, 'name', 'insertAfter')),
      );
      expect(
        () => zanshinNewChange(0, const [], insertBefore: ['qpv${nul}untsm']),
        throwsA(isA<ArgumentError>().having((e) => e.name, 'name', 'insertBefore')),
      );
    });

    test('zanshinBookmarkDelete rejects an interior NUL in a pattern', () {
      expect(
        () => zanshinBookmarkDelete(0, ['ok', 'fo${nul}o']),
        throwsA(isA<ArgumentError>().having((e) => e.name, 'name', 'names')),
      );
    });
  });

  group('the two new error codes travel through the shipped MutationResult decoder', () {
    test('each surfaces as a ZanshinFfiException carrying the offending name', () {
      for (final code in const ['jj.bookmark_exists', 'jj.bookmark_tracked_remote_exists']) {
        expect(
          () => decodeMutationResultEnvelope(errorEnvelope(code, 'feature')),
          throwsA(
            isA<ZanshinFfiException>()
                .having((e) => e.code, 'code', code)
                .having((e) => e.context, 'context', 'feature'),
          ),
        );
      }
    });
  });

  group('Story 9.19 request wire shapes', () {
    test('BookmarkMoveRequest: absent to and empty from stay distinguishable', () {
      final req = fbs.BookmarkMoveRequest(
        fbs.BookmarkMoveRequestObjectBuilder(
          kind: fbs.RequestKind.BookmarkMove,
          names: ['b', 'a'],
          allowBackwards: true,
        ).toBytes(),
      );
      expect(req.kind, fbs.RequestKind.BookmarkMove);
      expect(req.names, ['b', 'a']);
      expect(req.from, isNull, reason: 'absent = no --from');
      expect(req.to, isNull, reason: 'null-for-absence: absent means `@`');
      expect(req.allowBackwards, isTrue);

      final withFrom = fbs.BookmarkMoveRequest(
        fbs.BookmarkMoveRequestObjectBuilder(
          kind: fbs.RequestKind.BookmarkMove,
          from: ['@-', 'main'],
          to: 'qpvuntsm',
        ).toBytes(),
      );
      expect(withFrom.from, ['@-', 'main']);
      expect(withFrom.to, 'qpvuntsm');
      expect(withFrom.allowBackwards, isFalse);
    });

    test('BookmarkAdvanceRequest: absent names and to apply the config defaults', () {
      final req = fbs.BookmarkAdvanceRequest(
        fbs.BookmarkAdvanceRequestObjectBuilder(kind: fbs.RequestKind.BookmarkAdvance).toBytes(),
      );
      expect(req.kind, fbs.RequestKind.BookmarkAdvance);
      expect(req.names, isNull);
      expect(req.to, isNull);
    });

    test('BookmarkRenameRequest carries both names and the flag', () {
      final req = fbs.BookmarkRenameRequest(
        fbs.BookmarkRenameRequestObjectBuilder(
          kind: fbs.RequestKind.BookmarkRename,
          oldName: 'old',
          newName: 'new',
          overwriteExisting: true,
        ).toBytes(),
      );
      expect(req.kind, fbs.RequestKind.BookmarkRename);
      expect((req.oldName, req.newName, req.overwriteExisting), ('old', 'new', true));
    });
  });

  group('Story 9.19 adapter guards', () {
    final nul = String.fromCharCode(0);

    test('zanshinBookmarkMove rejects an interior NUL in names, from and to', () {
      expect(
        () => zanshinBookmarkMove(0, ['a${nul}b']),
        throwsA(isA<ArgumentError>().having((e) => e.name, 'name', 'names')),
      );
      expect(
        () => zanshinBookmarkMove(0, const [], from: ['@$nul-']),
        throwsA(isA<ArgumentError>().having((e) => e.name, 'name', 'from')),
      );
      expect(
        () => zanshinBookmarkMove(0, ['a'], to: 'qpv${nul}untsm'),
        throwsA(isA<ArgumentError>().having((e) => e.name, 'name', 'to')),
      );
    });

    test('zanshinBookmarkAdvance rejects an interior NUL in names and to', () {
      expect(
        () => zanshinBookmarkAdvance(0, names: ['a${nul}b']),
        throwsA(isA<ArgumentError>().having((e) => e.name, 'name', 'names')),
      );
      expect(
        () => zanshinBookmarkAdvance(0, to: 'qpv${nul}untsm'),
        throwsA(isA<ArgumentError>().having((e) => e.name, 'name', 'to')),
      );
    });

    test('zanshinBookmarkRename rejects an interior NUL in either name', () {
      expect(
        () => zanshinBookmarkRename(0, 'o${nul}ld', 'new'),
        throwsA(isA<ArgumentError>().having((e) => e.name, 'name', 'oldName')),
      );
      expect(
        () => zanshinBookmarkRename(0, 'old', 'n${nul}ew'),
        throwsA(isA<ArgumentError>().having((e) => e.name, 'name', 'newName')),
      );
    });
  });

  group('a refusal with hints travels through the shipped MutationResult decoder', () {
    test('the backwards refusal keeps its hint', () {
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: false,
        error: fbs.FfiErrorObjectBuilder(
          code: 'jj.invalid_input',
          context: 'Refusing to move bookmark backwards or sideways: feature',
          hints: ['Use --allow-backwards to allow it.'],
        ),
      ).toBytes();
      expect(
        () => decodeMutationResultEnvelope(bytes),
        throwsA(
          isA<ZanshinFfiException>().having((e) => e.code, 'code', 'jj.invalid_input').having((e) => e.hints, 'hints', [
            'Use --allow-backwards to allow it.',
          ]),
        ),
      );
    });
  });
}
