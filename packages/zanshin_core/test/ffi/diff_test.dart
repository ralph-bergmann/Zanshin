// SPDX-License-Identifier: MIT

// Decode-contract tests for Story 5.5's `Diff` payload, using synthetic
// FlatBuffers buffers built via the generated `*ObjectBuilder`s in the shape
// `zanshin_ffi::diff::diff_to_envelope` writes. No real cdylib required.

import 'package:test/test.dart';
import 'package:zanshin_core/src/ffi/diff.dart';
import 'package:zanshin_core/src/ffi/envelope_zanshin.ffi_generated.dart' as fbs;
import 'package:zanshin_core/src/ffi/select_tree.dart' show HunkKey;
import 'package:zanshin_core/src/ffi/warning.dart';
import 'package:zanshin_core/src/worker/responses.dart';

fbs.HunkKeyObjectBuilder _key(int oldStart, int oldCount, int newStart, int newCount) =>
    fbs.HunkKeyObjectBuilder(oldStart: oldStart, oldCount: oldCount, newStart: newStart, newCount: newCount);

fbs.HunkLineObjectBuilder _line(fbs.HunkLineKind kind, String text) =>
    fbs.HunkLineObjectBuilder(kind: kind, text: text);

void main() {
  test('a diff decodes field by field', () {
    final Diff diff = decodeDiffEnvelope(
      fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.Diff,
        data: fbs.DiffObjectBuilder(
          files: [
            fbs.FileDiffObjectBuilder(
              path: 'src/a.rs',
              binary: false,
              modeChange: false,
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
            fbs.FileDiffObjectBuilder(path: 'run.sh', binary: false, modeChange: true),
          ],
        ),
        warnings: [fbs.WarningObjectBuilder(code: 'jj.commit_paths_unmatched', message: 'm')],
      ).toBytes(),
    );

    expect(diff.files.map((f) => f.path), ['src/a.rs', 'bin.dat', 'run.sh']);
    final FileDiff a = diff.files[0];
    expect((a.binary, a.modeChange), (false, false));
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

  test('absent files decode as an empty diff', () {
    final Diff diff = decodeDiffEnvelope(
      fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.Diff,
        data: fbs.DiffObjectBuilder(),
      ).toBytes(),
    );
    expect(diff.files, isEmpty);
    expect(diff.warnings, isEmpty);
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
}
