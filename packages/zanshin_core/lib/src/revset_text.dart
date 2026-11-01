// SPDX-License-Identifier: MIT

import 'ffi/revset_search.dart' show RevsetSpan;

// The one owner of revset text a UI composes for structured filters (Story 10.21 item 7; 10.22 reuses it): every
// string pattern names its kind explicitly — at jj v0.46.0 a bare string is a `glob:` in revsets and a `prefix-glob:`
// in filesets (docs/revsets.md, docs/filesets.md), so a bare path holding `[` would act as a glob.

/// [text] as a jj string literal, quoted as jj's `format_string` prints one (core/src/symbol_util.rs @ v0.46.0):
/// straight double quotes, with `\"` `\\` `\t` `\r` `\n` `\0` and `\xHH` for the other ASCII controls.
String revsetStringLiteral(String text) {
  final out = StringBuffer('"');
  for (final int c in text.runes) {
    switch (c) {
      case 0x22:
        out.write(r'\"');
      case 0x5C:
        out.write(r'\\');
      case 0x09:
        out.write(r'\t');
      case 0x0D:
        out.write(r'\r');
      case 0x0A:
        out.write(r'\n');
      case 0x00:
        out.write(r'\0');
      case < 0x20 || 0x7F:
        out.write('\\x${c.toRadixString(16).padLeft(2, '0')}');
      default:
        out.writeCharCode(c);
    }
  }
  return (out..write('"')).toString();
}

/// A revset string pattern's kind (docs/revsets.md "String patterns" @ v0.46.0).
enum RevsetTextPattern {
  /// `substring:` — the text contains the value.
  substring,

  /// `exact:` — the text is the value.
  exact,

  /// `glob:` — a Unix-style shell wildcard.
  glob,

  /// `regex:` — a regular expression.
  regex,
}

/// A fileset path pattern's kind (docs/filesets.md @ v0.46.0); paths are relative to the workspace root, which is
/// the cwd revsets are resolved in (crates/zanshin-jj/src/revset.rs).
enum RevsetPathPattern {
  /// `cwd:` — the path and everything under it.
  prefix,

  /// `file:` — exactly this file.
  file,

  /// `glob:` — a Unix-style shell wildcard.
  glob,
}

String _textPattern(RevsetTextPattern pattern, String value, {required bool caseInsensitive}) =>
    '${pattern.name}${caseInsensitive ? '-i' : ''}:${revsetStringLiteral(value)}';

/// `author(<kind>[-i]:"<value>")`: commits whose author name or email matches [value].
String authorRevset(
  String value, {
  RevsetTextPattern pattern = RevsetTextPattern.exact,
  bool caseInsensitive = false,
}) => 'author(${_textPattern(pattern, value, caseInsensitive: caseInsensitive)})';

/// `committer(<kind>[-i]:"<value>")`: commits whose committer name or email matches [value].
String committerRevset(
  String value, {
  RevsetTextPattern pattern = RevsetTextPattern.exact,
  bool caseInsensitive = false,
}) => 'committer(${_textPattern(pattern, value, caseInsensitive: caseInsensitive)})';

/// `subject(<kind>[-i]:"<value>")`: commits whose description's first line matches [value].
String subjectRevset(
  String value, {
  RevsetTextPattern pattern = RevsetTextPattern.substring,
  bool caseInsensitive = false,
}) => 'subject(${_textPattern(pattern, value, caseInsensitive: caseInsensitive)})';

/// `~<term>`: the commits [term] does not match. [term] must be a primary (a function call), as every builder here
/// returns.
String revsetNot(String term) => '~$term';

/// [terms] joined with ` | ` when [any], else ` & `; `all()` when there are none.
String revsetJoin(Iterable<String> terms, {required bool any}) {
  final String joined = terms.join(any ? ' | ' : ' & ');
  return joined.isEmpty ? 'all()' : joined;
}

/// `description(<kind>[-i]:"<value>")`: commits whose description matches [value].
String descriptionRevset(
  String value, {
  RevsetTextPattern pattern = RevsetTextPattern.substring,
  bool caseInsensitive = false,
}) => 'description(${_textPattern(pattern, value, caseInsensitive: caseInsensitive)})';

/// `files(<kind>:"<path>")`: commits that change a path [path] matches.
String filesRevset(String path, {RevsetPathPattern pattern = RevsetPathPattern.prefix}) {
  final String kind = switch (pattern) {
    RevsetPathPattern.prefix => 'cwd',
    RevsetPathPattern.file => 'file',
    RevsetPathPattern.glob => 'glob',
  };
  return 'files($kind:${revsetStringLiteral(path)})';
}

/// `mine()`: commits whose author email is `user.email`, case-insensitively (`author_email(exact-i:…)`).
String mineRevset() => 'mine()';

/// [span] (UTF-8 bytes of [text], as jj reports a revset error's span) as UTF-16 offsets into [text]: `end == start`
/// for a position and for an unknown length. Offsets past the text clamp to its end.
({int start, int end}) revsetSpanUtf16(String text, RevsetSpan span) {
  final int start = _utf16Offset(text, span.offset);
  final int? length = span.length;
  return (start: start, end: length == null ? start : _utf16Offset(text, span.offset + length));
}

int _utf16Offset(String text, int bytes) {
  var seen = 0;
  var index = 0;
  for (final int rune in text.runes) {
    if (seen >= bytes) {
      return index;
    }
    seen += rune < 0x80
        ? 1
        : rune < 0x800
        ? 2
        : rune < 0x10000
        ? 3
        : 4;
    index += rune > 0xFFFF ? 2 : 1;
  }
  return index;
}
