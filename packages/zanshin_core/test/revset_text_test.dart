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
