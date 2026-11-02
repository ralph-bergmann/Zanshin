// SPDX-License-Identifier: MIT

import 'package:test/test.dart';
import 'package:zanshin_core/src/ffi/revset_search.dart';
import 'package:zanshin_core/src/revset_text.dart';

void main() {
  test('string literals quote as jj format_string', () {
    expect(revsetStringLiteral('Lena König'), '"Lena König"');
    expect(revsetStringLiteral(r'a"b\c'), r'"a\"b\\c"');
    expect(revsetStringLiteral('t\tr\rn\n\u0000\u0001\u007f'), r'"t\tr\rn\n\0\x01\x7f"');
  });

  test('author, every kind, with and without -i', () {
    expect(authorRevset('Lena König'), 'author(exact:"Lena König")');
    expect(
      authorRevset('lena', pattern: RevsetTextPattern.substring, caseInsensitive: true),
      'author(substring-i:"lena")',
    );
    expect(authorRevset('L*', pattern: RevsetTextPattern.glob), 'author(glob:"L*")');
    expect(authorRevset('^L', pattern: RevsetTextPattern.regex, caseInsensitive: true), 'author(regex-i:"^L")');
    expect(authorRevset('x', caseInsensitive: true), 'author(exact-i:"x")');
  });

  test('description, every kind', () {
    expect(descriptionRevset('cache', caseInsensitive: true), 'description(substring-i:"cache")');
    expect(descriptionRevset('fix'), 'description(substring:"fix")');
    expect(descriptionRevset('fix\n', pattern: RevsetTextPattern.exact), r'description(exact:"fix\n")');
    expect(descriptionRevset('f*', pattern: RevsetTextPattern.glob), 'description(glob:"f*")');
    expect(descriptionRevset('(', pattern: RevsetTextPattern.regex), 'description(regex:"(")');
  });

  test('files, every kind; a bracket stays literal', () {
    expect(filesRevset('lib/features/'), 'files(cwd:"lib/features/")');
    expect(filesRevset('a[1].txt', pattern: RevsetPathPattern.file), 'files(file:"a[1].txt")');
    expect(filesRevset('*.md', pattern: RevsetPathPattern.glob), 'files(glob:"*.md")');
    expect(mineRevset(), 'mine()');
  });

  test('committer and subject, every kind, with and without -i', () {
    expect(committerRevset('lena'), 'committer(exact:"lena")');
    expect(
      committerRevset('lena', pattern: RevsetTextPattern.substring, caseInsensitive: true),
      'committer(substring-i:"lena")',
    );
    expect(committerRevset('L*', pattern: RevsetTextPattern.glob), 'committer(glob:"L*")');
    expect(committerRevset('^L', pattern: RevsetTextPattern.regex), 'committer(regex:"^L")');
    expect(subjectRevset('fix'), 'subject(substring:"fix")');
    expect(subjectRevset('Fix', pattern: RevsetTextPattern.exact, caseInsensitive: true), 'subject(exact-i:"Fix")');
    expect(subjectRevset('f*', pattern: RevsetTextPattern.glob), 'subject(glob:"f*")');
    expect(subjectRevset('^f', pattern: RevsetTextPattern.regex, caseInsensitive: true), 'subject(regex-i:"^f")');
  });

  test('not and join', () {
    expect(revsetNot(filesRevset('*.lock', pattern: RevsetPathPattern.glob)), '~files(glob:"*.lock")');
    expect(revsetJoin(['mine()', '~files(cwd:"a")'], any: false), 'mine() & ~files(cwd:"a")');
    expect(revsetJoin(['mine()', 'author(exact:"x")'], any: true), 'mine() | author(exact:"x")');
    expect(revsetJoin(['mine()'], any: true), 'mine()');
    expect(revsetJoin(const [], any: false), 'all()');
  });

  test('a group keeps free revset text one primary under join and not', () {
    expect(revsetGroup('a | b'), '(a | b)');
    expect(revsetNot(revsetGroup('conflicts()')), '~(conflicts())');
    expect(revsetJoin([revsetGroup('trunk()..@'), 'mine()'], any: false), '(trunk()..@) & mine()');
  });

  test('a span in UTF-8 bytes converts to UTF-16 offsets', () {
    // "ö" is 2 bytes and 1 unit, "😀" 4 bytes and 2 units.
    const text = 'author("ö😀") & x(';
    expect(revsetSpanUtf16(text, const RevsetSpan(offset: 0, length: 6)), (start: 0, end: 6));
    expect(revsetSpanUtf16(text, const RevsetSpan(offset: 8, length: 6)), (start: 8, end: 11));
    // `x(` starts at byte 19 = unit 16.
    expect(revsetSpanUtf16(text, const RevsetSpan(offset: 19, length: 2)), (start: 16, end: 18));
    expect(revsetSpanUtf16(text, const RevsetSpan(offset: 19, length: null)), (start: 16, end: 16));
    expect(revsetSpanUtf16(text, const RevsetSpan(offset: 99, length: 1)), (start: 18, end: 18));
  });
}
