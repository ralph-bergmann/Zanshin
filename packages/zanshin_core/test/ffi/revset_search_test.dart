// SPDX-License-Identifier: MIT

// Decode-contract tests for Story 9.25's RevsetCounts / FoundChanges decoders
// and the FfiError.revset detail, using synthetic FlatBuffers buffers built via
// the generated `*ObjectBuilder`s. No real cdylib required; mirrors the Rust
// round-trips in crates/zanshin-ffi/src/revset_search.rs.

import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zanshin_core/src/ffi/envelope_zanshin.ffi_generated.dart' as fbs;
import 'package:zanshin_core/src/ffi/revset_search.dart';
import 'package:zanshin_core/src/worker/responses.dart';

fbs.FfiErrorObjectBuilder revsetError({fbs.RevsetErrorDetailObjectBuilder? revset}) => fbs.FfiErrorObjectBuilder(
  code: 'jj.revset_parse_error',
  context: 'bad',
  hints: const ['Did you mean `foo`?'],
  revset: revset,
);

Uint8List countsEnvelope(List<fbs.RevsetCountObjectBuilder>? counts) => fbs.EnvelopeObjectBuilder(
  ok: true,
  dataType: fbs.PayloadTypeId.RevsetCounts,
  data: fbs.RevsetCountsObjectBuilder(counts: counts),
).toBytes();

Uint8List foundEnvelope(List<fbs.FoundChangeObjectBuilder>? entries) => fbs.EnvelopeObjectBuilder(
  ok: true,
  dataType: fbs.PayloadTypeId.FoundChanges,
  data: fbs.FoundChangesObjectBuilder(entries: entries, truncated: true),
).toBytes();

void main() {
  group('decodeRevsetCountsEnvelope decode contract', () {
    test('decodes each count and a failed entry with its own exception and detail', () {
      final RevsetCounts counts = decodeRevsetCountsEnvelope(
        countsEnvelope([
          fbs.RevsetCountObjectBuilder(n: 5, capped: true),
          fbs.RevsetCountObjectBuilder(
            error: revsetError(
              revset: fbs.RevsetErrorDetailObjectBuilder(
                kind: fbs.RevsetErrorKind.NoSuchFunction,
                span: fbs.RevsetSpanObjectBuilder(offset: 3, length: fbs.RevsetSpanLengthObjectBuilder(value: 4)),
                symbol: 'fooo',
                candidates: const ['foo'],
              ),
            ),
          ),
          fbs.RevsetCountObjectBuilder(error: revsetError()),
        ]),
      );

      expect(counts, hasLength(3));
      expect((counts[0].n, counts[0].capped, counts[0].error), (5, true, null));
      final ZanshinFfiException? error = counts[1].error;
      expect(error?.code, 'jj.revset_parse_error');
      expect(error?.context, 'bad');
      expect(error?.hints, ['Did you mean `foo`?']);
      expect(error?.revsetError?.kind, RevsetErrorKind.noSuchFunction);
      expect(error?.revsetError?.span?.offset, 3);
      expect(error?.revsetError?.span?.length, 4);
      expect(error?.revsetError?.symbol, 'fooo');
      expect(error?.revsetError?.candidates, ['foo']);
      expect(counts[2].error?.revsetError, isNull, reason: 'an absent detail is null');
      expect(error.toString(), contains('revset: noSuchFunction at 3+4 `fooo`'));
      expect(counts.warnings, isEmpty);
    });

    test('a span across lines has a null length, and absent fields read as none', () {
      final RevsetCounts counts = decodeRevsetCountsEnvelope(
        countsEnvelope([
          fbs.RevsetCountObjectBuilder(
            error: revsetError(
              revset: fbs.RevsetErrorDetailObjectBuilder(
                kind: fbs.RevsetErrorKind.InAliasExpansion,
                span: fbs.RevsetSpanObjectBuilder(offset: 1),
              ),
            ),
          ),
        ]),
      );

      final RevsetErrorDetail? detail = counts.single.error?.revsetError;
      expect(detail?.kind, RevsetErrorKind.inAliasExpansion);
      expect(detail?.span?.length, isNull);
      expect(detail?.symbol, isNull);
      expect(detail?.candidates, isEmpty);
    });

    test('a missing counts vector or error code throws ffi.unknown', () {
      for (final Uint8List bytes in [
        countsEnvelope(null),
        countsEnvelope([fbs.RevsetCountObjectBuilder(error: fbs.FfiErrorObjectBuilder(context: 'no code'))]),
      ]) {
        expect(
          () => decodeRevsetCountsEnvelope(bytes),
          throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'ffi.unknown')),
        );
      }
      expect(
        () => decodeFoundChangesEnvelope(foundEnvelope(null)),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'ffi.unknown')),
      );
    });

    test('an error envelope throws with its revset detail', () {
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: false,
        error: revsetError(revset: fbs.RevsetErrorDetailObjectBuilder(kind: fbs.RevsetErrorKind.SyntaxError)),
      ).toBytes();

      expect(
        () => decodeFoundChangesEnvelope(bytes),
        throwsA(
          isA<ZanshinFfiException>()
              .having((e) => e.code, 'code', 'jj.revset_parse_error')
              .having((e) => e.revsetError?.kind, 'kind', RevsetErrorKind.syntaxError),
        ),
      );
      expect(
        () => decodeRevsetCountsEnvelope(
          fbs.EnvelopeObjectBuilder(
            ok: false,
            error: fbs.FfiErrorObjectBuilder(code: 'jj.invalid_input'),
          ).toBytes(),
        ),
        throwsA(isA<ZanshinFfiException>().having((e) => e.revsetError, 'revsetError', isNull)),
      );
    });
  });

  group('decodeFoundChangesEnvelope decode contract', () {
    test('decodes every field in wire order', () {
      final FoundChanges found = decodeFoundChangesEnvelope(
        foundEnvelope([
          fbs.FoundChangeObjectBuilder(commitId: 'bb', changeId: 'kbb', commitPrefixLen: 2, changePrefixLen: 3),
          fbs.FoundChangeObjectBuilder(commitId: 'aa', changeId: 'kaa', commitPrefixLen: 1, changePrefixLen: 1),
        ]),
      );

      expect(found.truncated, isTrue);
      expect(found.entries.map((e) => (e.commitId, e.changeId, e.commitPrefixLen, e.changePrefixLen)), [
        ('bb', 'kbb', 2, 3),
        ('aa', 'kaa', 1, 1),
      ]);
      expect(found.warnings, isEmpty);
    });

    test('an entry missing an id throws ffi.unknown', () {
      expect(
        () => decodeFoundChangesEnvelope(foundEnvelope([fbs.FoundChangeObjectBuilder(changeId: 'k')])),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'ffi.unknown')),
      );
    });
  });

  group('adapters guard interior NULs before the FFI call', () {
    test('zanshinRevsetCounts and zanshinFindChanges throw ArgumentError', () {
      expect(() => zanshinRevsetCounts(0, operationId: 'a\u0000', expressions: const [], cap: 1), throwsArgumentError);
      expect(
        () => zanshinFindChanges(0, operationId: 'ab', expression: 'x', limit: 1, shortPrefixes: '\u0000'),
        throwsArgumentError,
      );
    });
  });
}
