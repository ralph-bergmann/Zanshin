// SPDX-License-Identifier: MIT

// Decode-contract tests for Story 5.5's `Diff` payload, using synthetic
// FlatBuffers buffers built via the generated `*ObjectBuilder`s in the shape
// `zanshin_ffi::diff::diff_to_envelope` writes. No real cdylib required.

import 'package:test/test.dart';
import 'package:zanshin_core/src/ffi/diff.dart';
import 'package:zanshin_core/src/ffi/envelope_zanshin.ffi_generated.dart' as fbs;
import 'package:zanshin_core/src/ffi/select_tree.dart' show HunkKey;
import 'package:zanshin_core/src/ffi/status.dart' show FileChangeKind;
import 'package:zanshin_core/src/ffi/warning.dart';
import 'package:zanshin_core/src/worker/responses.dart';

fbs.HunkKeyObjectBuilder _key(int oldStart, int oldCount, int newStart, int newCount) =>
    fbs.HunkKeyObjectBuilder(oldStart: oldStart, oldCount: oldCount, newStart: newStart, newCount: newCount);

fbs.HunkLineObjectBuilder _line(fbs.HunkLineKind kind, String text) =>
    fbs.HunkLineObjectBuilder(kind: kind, text: text);

fbs.SegmentObjectBuilder _segment(fbs.SegmentKind kind, String text) =>
    fbs.SegmentObjectBuilder(kind: kind, text: text);

void main() {
  test('a diff decodes field by field', () {
    final Diff diff = decodeDiffEnvelope(
      fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.Diff,
        data: fbs.DiffObjectBuilder(
          operationId: 'op1',
          commitIds: ['c1', 'c2'],
          files: [
            fbs.FileDiffObjectBuilder(
              path: 'src/a.rs',
              binary: false,
              modeChange: false,
              kind: fbs.ChangeKind.Modified,
              removed: 2,
              added: 1,
              fingerprint: 'ab12',
              sections: [_key(1, 2, 1, 3), _key(9, 1, 10, 0)],
              hunks: [
                fbs.HunkObjectBuilder(
                  beforeStart: 0,
                  beforeEnd: 5,
                  afterStart: 0,
                  afterEnd: 6,
                  symbol: 'fn main() {',
                  sections: [_key(1, 2, 1, 3)],
                  removed: 1,
                  added: 1,
                  lines: [
                    _line(fbs.HunkLineKind.Context, 'fn main() {\n'),
                    _line(fbs.HunkLineKind.Removed, '    a();\n'),
                    _line(fbs.HunkLineKind.Added, '    b();'),
                  ],
                ),
                fbs.HunkObjectBuilder(
                  beforeStart: 7,
                  beforeEnd: 12,
                  afterStart: 8,
                  afterEnd: 12,
                  sections: [_key(9, 1, 10, 0)],
                  removed: 1,
                  added: 0,
                  lines: [_line(fbs.HunkLineKind.Removed, 'y\n')],
                ),
              ],
            ),
            fbs.FileDiffObjectBuilder(path: 'bin.dat', binary: true, modeChange: false, sections: [], hunks: []),
            fbs.FileDiffObjectBuilder(path: 'run.sh', binary: false, modeChange: true, kind: fbs.ChangeKind.Removed),
            fbs.FileDiffObjectBuilder(path: 'new.txt', kind: fbs.ChangeKind.Renamed, fromPath: 'old.txt'),
            fbs.FileDiffObjectBuilder(path: 'copy.txt', kind: fbs.ChangeKind.Copied, fromPath: 'src.txt'),
          ],
        ),
        warnings: [fbs.WarningObjectBuilder(code: 'jj.commit_paths_unmatched', message: 'm')],
      ).toBytes(),
    );

    expect(diff.files.map((f) => f.path), ['src/a.rs', 'bin.dat', 'run.sh', 'new.txt', 'copy.txt']);
    expect((diff.operationId, diff.fromCommitId), ('op1', null));
    expect(diff.commitIds, ['c1', 'c2']);
    expect(diff.files.map((f) => (f.kind, f.fromPath)), [
      (FileChangeKind.modified, null),
      (FileChangeKind.added, null),
      (FileChangeKind.removed, null),
      (FileChangeKind.renamed, 'old.txt'),
      (FileChangeKind.copied, 'src.txt'),
    ]);
    final FileDiff a = diff.files[0];
    expect((a.binary, a.modeChange), (false, false));
    expect((a.removed, a.added, a.fingerprint), (2, 1, 'ab12'));
    expect((diff.files[1].removed, diff.files[1].added, diff.files[1].fingerprint), (0, 0, ''));
    expect(a.sections, const [
      HunkKey(oldStart: 1, oldCount: 2, newStart: 1, newCount: 3),
      HunkKey(oldStart: 9, oldCount: 1, newStart: 10, newCount: 0),
    ]);
    expect(a.hunks, hasLength(2));

    final Hunk first = a.hunks[0];
    expect(first.before, (start: 0, end: 5));
    expect(first.after, (start: 0, end: 6));
    expect(first.symbol, 'fn main() {');
    expect(first.sections, const [HunkKey(oldStart: 1, oldCount: 2, newStart: 1, newCount: 3)]);
    expect((first.removed, first.added), (1, 1));
    expect(first.lines.map((l) => (l.kind, l.text)), [
      (HunkLineKind.context, 'fn main() {\n'),
      (HunkLineKind.removed, '    a();\n'),
      (HunkLineKind.added, '    b();'),
    ]);

    final Hunk second = a.hunks[1];
    expect(second.before, (start: 7, end: 12));
    expect(second.after, (start: 8, end: 12));
    expect(second.symbol, isNull);
    expect(second.sections, const [HunkKey(oldStart: 9, oldCount: 1, newStart: 10, newCount: 0)]);
    expect((second.removed, second.added), (1, 0));
    expect(second.lines.single.kind, HunkLineKind.removed);

    final FileDiff bin = diff.files[1];
    expect((bin.binary, bin.modeChange), (true, false));
    expect(bin.sections, isEmpty);
    expect(bin.hunks, isEmpty);
    final FileDiff mode = diff.files[2];
    expect((mode.binary, mode.modeChange), (false, true));
    expect(mode.sections, isEmpty);
    expect(mode.hunks, isEmpty);

    expect(diff.warnings.single.code, ZanshinWarningCode.commitPathsUnmatched);
  });

  test('a line decodes its word-level segments, an absent vector as none', () {
    final Diff diff = decodeDiffEnvelope(
      fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.Diff,
        data: fbs.DiffObjectBuilder(
          files: [
            fbs.FileDiffObjectBuilder(
              path: 'w.txt',
              hunks: [
                fbs.HunkObjectBuilder(
                  lines: [
                    fbs.HunkLineObjectBuilder(
                      kind: fbs.HunkLineKind.Removed,
                      text: 'x y\n',
                      segments: [
                        _segment(fbs.SegmentKind.Equal, 'x'),
                        _segment(fbs.SegmentKind.Removed, ' '),
                        _segment(fbs.SegmentKind.Equal, 'y\n'),
                      ],
                    ),
                    fbs.HunkLineObjectBuilder(
                      kind: fbs.HunkLineKind.Added,
                      text: 'n\n',
                      segments: [_segment(fbs.SegmentKind.Added, 'n\n')],
                    ),
                    _line(fbs.HunkLineKind.Context, 'c\n'),
                  ],
                ),
              ],
            ),
          ],
        ),
      ).toBytes(),
    );

    final List<HunkLine> lines = diff.files.single.hunks.single.lines;
    expect(lines[0].segments.map((s) => (s.kind, s.text)), [
      (SegmentKind.equal, 'x'),
      (SegmentKind.removed, ' '),
      (SegmentKind.equal, 'y\n'),
    ]);
    expect(lines[1].segments.map((s) => (s.kind, s.text)), [(SegmentKind.added, 'n\n')]);
    expect(identical(lines[1].segments.single.text, lines[1].text), isTrue, reason: 'reuses the line text');
    expect(lines[2].segments, isEmpty, reason: 'no segments vector');
  });

  test('a line decodes its color-words kind and line numbers, 0 as null', () {
    final Diff diff = decodeDiffEnvelope(
      fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.Diff,
        data: fbs.DiffObjectBuilder(
          files: [
            fbs.FileDiffObjectBuilder(
              path: 'git.rs',
              hunks: [
                fbs.HunkObjectBuilder(
                  lines: [
                    fbs.HunkLineObjectBuilder(
                      kind: fbs.HunkLineKind.Changed,
                      text: '  ab\n',
                      leftLine: 2454,
                      rightLine: 2459,
                      segments: [
                        _segment(fbs.SegmentKind.Equal, '  '),
                        _segment(fbs.SegmentKind.Removed, 'a'),
                        _segment(fbs.SegmentKind.Added, 'b'),
                        _segment(fbs.SegmentKind.Equal, '\n'),
                      ],
                    ),
                    fbs.HunkLineObjectBuilder(kind: fbs.HunkLineKind.Added, text: 'n\n', rightLine: 2460),
                    fbs.HunkLineObjectBuilder(kind: fbs.HunkLineKind.ConflictHeader, text: '>>>>>>> Conflict ends\n'),
                  ],
                ),
              ],
            ),
          ],
        ),
      ).toBytes(),
    );

    final List<HunkLine> lines = diff.files.single.hunks.single.lines;
    expect(lines.map((l) => (l.kind, l.left, l.right)), [
      (HunkLineKind.changed, 2454, 2459),
      (HunkLineKind.added, null, 2460),
      (HunkLineKind.conflictHeader, null, null),
    ]);
    expect(lines[0].segments.map((s) => (s.kind, s.text)), [
      (SegmentKind.equal, '  '),
      (SegmentKind.removed, 'a'),
      (SegmentKind.added, 'b'),
      (SegmentKind.equal, '\n'),
    ]);
  });

  test('a file decodes its whitespace lines, an absent vector as none', () {
    final Diff diff = decodeDiffEnvelope(
      fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.Diff,
        data: fbs.DiffObjectBuilder(
          files: [
            fbs.FileDiffObjectBuilder(
              path: 'text_field.dart',
              whitespaceLines: [
                fbs.HunkLineObjectBuilder(
                  kind: fbs.HunkLineKind.Context,
                  text: '    a\n',
                  leftLine: 6,
                  rightLine: 8,
                  segments: [
                    _segment(fbs.SegmentKind.Equal, '  '),
                    _segment(fbs.SegmentKind.Added, '  '),
                    _segment(fbs.SegmentKind.Equal, 'a\n'),
                  ],
                ),
              ],
            ),
            fbs.FileDiffObjectBuilder(path: 'other.dart'),
          ],
        ),
      ).toBytes(),
    );

    final HunkLine line = diff.files.first.whitespaceLines.single;
    expect((line.kind, line.left, line.right, line.text), (HunkLineKind.context, 6, 8, '    a\n'));
    expect(line.segments.map((s) => (s.kind, s.text)), [
      (SegmentKind.equal, '  '),
      (SegmentKind.added, '  '),
      (SegmentKind.equal, 'a\n'),
    ]);
    expect(diff.files[1].whitespaceLines, isEmpty);
  });

  test('absent files decode as an empty diff', () {
    final Diff diff = decodeDiffEnvelope(
      fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.Diff,
        data: fbs.DiffObjectBuilder(),
      ).toBytes(),
    );
    expect(diff.files, isEmpty);
    expect(diff.commitIds, isEmpty);
    expect(diff.warnings, isEmpty);
  });

  test('a from/to diff carries both pins', () {
    final Diff diff = decodeDiffEnvelope(
      fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.Diff,
        data: fbs.DiffObjectBuilder(operationId: 'op', commitIds: ['to'], fromCommitId: 'from', files: []),
      ).toBytes(),
    );
    expect((diff.operationId, diff.fromCommitId), ('op', 'from'));
    expect(diff.commitIds, ['to']);
  });

  test('an error envelope throws ZanshinFfiException with its code and context', () {
    expect(
      () => decodeDiffEnvelope(
        fbs.EnvelopeObjectBuilder(
          ok: false,
          error: fbs.FfiErrorObjectBuilder(code: 'jj.invalid_input', context: 'bad tree'),
        ).toBytes(),
      ),
      throwsA(
        isA<ZanshinFfiException>()
            .having((e) => e.code, 'code', 'jj.invalid_input')
            .having((e) => e.context, 'context', 'bad tree'),
      ),
    );
  });

  test('another payload throws ffi.unknown', () {
    expect(
      () => decodeDiffEnvelope(
        fbs.EnvelopeObjectBuilder(
          ok: true,
          dataType: fbs.PayloadTypeId.SelectedTree,
          data: fbs.SelectedTreeObjectBuilder(treeIds: const ['t'], labels: const []),
        ).toBytes(),
      ),
      throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'ffi.unknown')),
    );
  });

  // Story 10.43.
  test('a file decodes its left line count, an absent one as 0', () {
    final Diff diff = decodeDiffEnvelope(
      fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.Diff,
        data: fbs.DiffObjectBuilder(
          files: [
            fbs.FileDiffObjectBuilder(path: 'a.dart', leftLineCount: 120),
            fbs.FileDiffObjectBuilder(path: 'b.dart'),
          ],
        ),
      ).toBytes(),
    );
    expect(diff.files.map((f) => f.leftLineCount), [120, 0]);
  });

  test('diff lines decode in order, an absent vector as none', () {
    final List<HunkLine> lines = decodeDiffLinesEnvelope(
      fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.DiffLines,
        data: fbs.DiffLinesObjectBuilder(
          lines: [
            fbs.HunkLineObjectBuilder(
              kind: fbs.HunkLineKind.Context,
              text: 'x\n',
              leftLine: 9,
              rightLine: 11,
              segments: [_segment(fbs.SegmentKind.Equal, 'x\n')],
            ),
            fbs.HunkLineObjectBuilder(
              kind: fbs.HunkLineKind.Context,
              text: '  y\n',
              leftLine: 10,
              rightLine: 12,
              segments: [_segment(fbs.SegmentKind.Removed, '  '), _segment(fbs.SegmentKind.Equal, 'y\n')],
            ),
          ],
        ),
      ).toBytes(),
    );
    expect(lines.map((l) => (l.kind, l.left, l.right, l.text)), [
      (HunkLineKind.context, 9, 11, 'x\n'),
      (HunkLineKind.context, 10, 12, '  y\n'),
    ]);
    expect(lines[1].segments.map((s) => (s.kind, s.text)), [(SegmentKind.removed, '  '), (SegmentKind.equal, 'y\n')]);
    final List<HunkLine> none = decodeDiffLinesEnvelope(
      fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.DiffLines,
        data: fbs.DiffLinesObjectBuilder(),
      ).toBytes(),
    );
    expect(none, isEmpty);
  });

  test('a diff lines error envelope throws, another payload throws ffi.unknown', () {
    expect(
      () => decodeDiffLinesEnvelope(
        fbs.EnvelopeObjectBuilder(
          ok: false,
          error: fbs.FfiErrorObjectBuilder(code: 'jj.revset_resolution_error', context: 'no such revision'),
        ).toBytes(),
      ),
      throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'jj.revset_resolution_error')),
    );
    expect(
      () => decodeDiffLinesEnvelope(
        fbs.EnvelopeObjectBuilder(ok: true, dataType: fbs.PayloadTypeId.Diff, data: fbs.DiffObjectBuilder()).toBytes(),
      ),
      throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'ffi.unknown')),
    );
  });

  test('every DiffWhitespace crosses as its wire value', () {
    expect(
      {for (final DiffWhitespace ws in DiffWhitespace.values) ws: ws.wire},
      {
        DiffWhitespace.exact: fbs.DiffWhitespace.Exact,
        DiffWhitespace.ignoreAllSpace: fbs.DiffWhitespace.IgnoreAllSpace,
        DiffWhitespace.ignoreSpaceChange: fbs.DiffWhitespace.IgnoreSpaceChange,
      },
    );
  });
}
