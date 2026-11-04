// SPDX-License-Identifier: MIT

// Decode-contract tests for Story 9.4's four file-read decoders, using synthetic
// FlatBuffers buffers built via the generated `*ObjectBuilder`s. No real cdylib
// required - these tests exercise the Dart-side decode logic in isolation and
// mirror the Rust round-trips in crates/zanshin-ffi/src/file.rs (AR-P-7 parity).
//
// Also covers the adapters' interior-NUL guards, which fire BEFORE any FFI call,
// so a raw handle of 0 never reaches the cdylib.
//
// Mirrors packages/zanshin_core/test/ffi/mutate_test.dart.

import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zanshin_core/src/ffi/envelope_zanshin.ffi_generated.dart' as fbs;
import 'package:zanshin_core/src/ffi/file.dart';
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

void main() {
  group('decodeFileListEnvelope decode contract', () {
    test('throws ZanshinFfiException on an error envelope', () {
      expect(
        () => decodeFileListEnvelope(errorEnvelope('jj.change_not_found', 'zzz')),
        throwsA(
          isA<ZanshinFfiException>()
              .having((e) => e.code, 'code', 'jj.change_not_found')
              .having((e) => e.context, 'context', 'zzz'),
        ),
      );
    });

    test('throws ffi.unknown on an ok envelope with a non-FileList payload', () {
      expect(
        () => decodeFileListEnvelope(wrongPayload()),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'ffi.unknown')),
      );
    });

    test('decodes every entry field and maps all five file types', () {
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.FileList,
        data: fbs.FileListObjectBuilder(
          entries: [
            fbs.FileEntryObjectBuilder(
              path: 'a.txt',
              fileType: fbs.FileType.File,
              executable: true,
              conflictSideCount: 1,
            ),
            fbs.FileEntryObjectBuilder(path: 'link', fileType: fbs.FileType.Symlink, conflictSideCount: 1),
            fbs.FileEntryObjectBuilder(path: 'sub', fileType: fbs.FileType.Tree, conflictSideCount: 1),
            fbs.FileEntryObjectBuilder(path: 'mod', fileType: fbs.FileType.GitSubmodule, conflictSideCount: 1),
            fbs.FileEntryObjectBuilder(path: 'c.txt', fileType: fbs.FileType.Conflict, conflictSideCount: 3),
          ],
        ),
      ).toBytes();

      final List<FileEntry> entries = decodeFileListEnvelope(bytes);

      expect(entries.map((e) => e.fileType), [
        FileType.file,
        FileType.symlink,
        FileType.tree,
        FileType.gitSubmodule,
        FileType.conflict,
      ]);
      expect(entries.first.path, 'a.txt');
      expect(entries.first.executable, isTrue);
      expect(entries[1].executable, isFalse);
      expect(entries.last.conflictSideCount, 3);
    });

    test('decodes an absent entries vector as an empty list', () {
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.FileList,
        data: fbs.FileListObjectBuilder(),
      ).toBytes();

      expect(decodeFileListEnvelope(bytes), isEmpty);
    });
  });

  group('decodeFileContentsEnvelope decode contract', () {
    test('throws ffi.unknown on an ok envelope with a non-FileContents payload', () {
      expect(
        () => decodeFileContentsEnvelope(wrongPayload()),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'ffi.unknown')),
      );
    });

    test('decodes raw bytes and skipped paths', () {
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.FileContents,
        data: fbs.FileContentsObjectBuilder(
          files: [
            // Deliberately NOT valid UTF-8: the field is [ubyte] for exactly this.
            fbs.ShownFileObjectBuilder(path: 'bin.dat', content: [0xff, 0x00, 0x41], conflict: true),
            fbs.ShownFileObjectBuilder(path: 'a.txt', content: utf8.encode('alpha\n')),
          ],
          skipped: [fbs.SkippedPathObjectBuilder(path: 'link', reason: "Path 'link' exists but is not a file.")],
        ),
      ).toBytes();

      final FileContents contents = decodeFileContentsEnvelope(bytes);

      expect(contents.files, hasLength(2));
      expect(contents.files.first.path, 'bin.dat');
      expect(contents.files.first.content, Uint8List.fromList([0xff, 0x00, 0x41]));
      expect(contents.files.first.conflict, isTrue);
      expect(utf8.decode(contents.files[1].content), 'alpha\n');
      expect(contents.files[1].conflict, isFalse);
      expect(contents.skipped, hasLength(1));
      expect(contents.skipped.single.path, 'link');
      expect(contents.skipped.single.reason, "Path 'link' exists but is not a file.");
    });

    test('decodes absent vectors and an absent content blob without crashing', () {
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.FileContents,
        data: fbs.FileContentsObjectBuilder(files: [fbs.ShownFileObjectBuilder(path: 'empty.txt')]),
      ).toBytes();

      final FileContents contents = decodeFileContentsEnvelope(bytes);

      expect(contents.files.single.content, isEmpty, reason: 'an absent blob is an empty file');
      expect(contents.skipped, isEmpty);
    });
  });

  group('decodeFileAnnotationEnvelope decode contract', () {
    test('throws ffi.unknown on an ok envelope with a non-FileAnnotation payload', () {
      expect(
        () => decodeFileAnnotationEnvelope(wrongPayload()),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'ffi.unknown')),
      );
    });

    test('decodes both origin states and 1-based original line numbers', () {
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.FileAnnotation,
        data: fbs.FileAnnotationObjectBuilder(
          lines: [
            fbs.AnnotationLineObjectBuilder(
              commitId: 'aa',
              changeId: 'zz',
              originalLineNumber: 1,
              content: utf8.encode('one\n'),
              originFound: true,
            ),
            fbs.AnnotationLineObjectBuilder(
              commitId: 'bb',
              changeId: 'yy',
              originalLineNumber: 7,
              content: utf8.encode('two'),
            ),
          ],
        ),
      ).toBytes();

      final List<AnnotationLine> lines = decodeFileAnnotationEnvelope(bytes);

      expect(lines, hasLength(2));
      expect(lines[0].commitId, 'aa');
      expect(lines[0].changeId, 'zz');
      expect(lines[0].originalLineNumber, 1);
      expect(lines[0].originFound, isTrue);
      expect(utf8.decode(lines[0].content), 'one\n');
      expect(lines[1].originalLineNumber, 7);
      expect(lines[1].originFound, isFalse, reason: 'the search stopped outside the domain');
    });

    test('decodes an absent lines vector as an empty list', () {
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.FileAnnotation,
        data: fbs.FileAnnotationObjectBuilder(),
      ).toBytes();

      expect(decodeFileAnnotationEnvelope(bytes), isEmpty);
    });
  });

  group('decodeFileSearchEnvelope decode contract', () {
    test('throws ffi.unknown on an ok envelope with a non-FileSearch payload', () {
      expect(
        () => decodeFileSearchEnvelope(wrongPayload()),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'ffi.unknown')),
      );
    });

    test('honours the conflict-side presence pair instead of a sentinel', () {
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.FileSearch,
        data: fbs.FileSearchObjectBuilder(
          matches: [
            // hasConflictSide false with conflictSide 0: a sentinel-reading decoder
            // would report side 0 here instead of null.
            fbs.SearchMatchObjectBuilder(
              path: 'a.txt',
              lineNumber: 2,
              content: utf8.encode('needle\n'),
              conflictSide: 0,
            ),
            fbs.SearchMatchObjectBuilder(
              path: 'c.txt',
              lineNumber: 1,
              content: utf8.encode('needle two\n'),
              conflictSide: 1,
              hasConflictSide: true,
              binary: true,
            ),
          ],
        ),
      ).toBytes();

      final FileSearch search = decodeFileSearchEnvelope(bytes);
      final List<SearchMatch> matches = search.matches;

      expect(matches, hasLength(2));
      expect((matches[0].binary, matches[1].binary), (false, true));
      expect(matches[0].conflictSide, isNull, reason: 'null-for-absence, not the 0 sentinel');
      expect(matches[0].lineNumber, 2);
      expect(utf8.decode(matches[0].content), 'needle\n');
      expect(matches[1].conflictSide, 1);
      expect(matches[1].lineNumber, 1, reason: 'line numbers restart at each conflict side');
      expect(search.skipped, isEmpty, reason: 'no blob was unreadable');
    });

    test('decodes skipped paths beside the matches', () {
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.FileSearch,
        data: fbs.FileSearchObjectBuilder(
          matches: [
            fbs.SearchMatchObjectBuilder(
              path: 'plain.txt',
              lineNumber: 1,
              content: utf8.encode('needle\n'),
            ),
          ],
          skipped: [
            fbs.SkippedPathObjectBuilder(
              path: 'secret.txt',
              reason: "Skipping 'secret.txt' due to permission error: No access",
            ),
          ],
        ),
      ).toBytes();

      final FileSearch search = decodeFileSearchEnvelope(bytes);

      expect(search.matches, hasLength(1));
      expect(search.skipped, hasLength(1));
      expect(search.skipped.single.path, 'secret.txt');
      expect(
        search.skipped.single.reason,
        "Skipping 'secret.txt' due to permission error: No access",
        reason: "search's own wording, not `file show`'s",
      );
    });

    test('decodes absent matches and skipped vectors as empty lists', () {
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.FileSearch,
        data: fbs.FileSearchObjectBuilder(),
      ).toBytes();

      final FileSearch search = decodeFileSearchEnvelope(bytes);

      expect(search.matches, isEmpty);
      expect(search.skipped, isEmpty);
    });
  });

  group('interior-NUL guards', () {
    // A FlatBuffers string is length-prefixed, so a NUL would survive the wire and
    // land in a jj change id, path or pattern. Every guard fires BEFORE the FFI
    // call, which is why a raw handle of 0 is safe here.
    const nul = 'a\u0000b';

    test('fileList rejects a NUL in revision or a path', () {
      expect(() => zanshinFileList(0, revision: nul), throwsA(isA<ArgumentError>()));
      expect(
        () => zanshinFileList(0, paths: [nul]),
        throwsA(isA<ArgumentError>().having((e) => e.name, 'name', 'paths')),
      );
    });

    test('fileShow rejects a NUL in revision or a path', () {
      expect(() => zanshinFileShow(0, revision: nul, paths: ['a.txt']), throwsA(isA<ArgumentError>()));
      expect(() => zanshinFileShow(0, paths: [nul]), throwsA(isA<ArgumentError>()));
    });

    test('fileAnnotate rejects a NUL in revision or path', () {
      expect(() => zanshinFileAnnotate(0, path: nul), throwsA(isA<ArgumentError>()));
      expect(() => zanshinFileAnnotate(0, path: 'a.txt', revision: nul), throwsA(isA<ArgumentError>()));
    });

    test('fileSearch rejects a NUL in pattern, revision or a path', () {
      expect(() => zanshinFileSearch(0, pattern: nul), throwsA(isA<ArgumentError>()));
      expect(() => zanshinFileSearch(0, pattern: 'x', revision: nul), throwsA(isA<ArgumentError>()));
      expect(() => zanshinFileSearch(0, pattern: 'x', paths: [nul]), throwsA(isA<ArgumentError>()));
    });
  });
}
