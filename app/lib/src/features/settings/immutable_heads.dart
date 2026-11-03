// SPDX-License-Identifier: MIT

import 'package:flutter/foundation.dart';
import 'package:zanshin_core/zanshin_core.dart' show ConfigEntry, TopologyRef, TopologyRefKind;

/// The effective value among [entries] (`jj config list NAME --include-overridden`, lowest layer first): the last
/// entry no higher layer overrides, or null when there is none.
ConfigEntry? effectiveConfigEntry(List<ConfigEntry> entries) => entries.lastWhereOrNull((entry) => !entry.overridden);

extension<E> on List<E> {
  E? lastWhereOrNull(bool Function(E element) test) {
    for (int i = length - 1; i >= 0; i--) {
      if (test(this[i])) {
        return this[i];
      }
    }
    return null;
  }
}

/// The config key the Immutable commits page writes.
const immutableHeadsKey = 'revset-aliases."immutable_heads()"'; // l10n-ignore: jj's config key

/// The config key History › Trunk writes.
const trunkKey = 'revset-aliases."trunk()"'; // l10n-ignore: jj's config key

/// jj's default for `immutable_heads()`.
const builtinImmutableHeads = 'builtin_immutable_heads()'; // l10n-ignore: jj's revset

/// What [builtinImmutableHeads] stands for, in the jj CLI's order (`cli/src/config/revsets.toml` @ v0.46.0).
const immutableBuiltins = <String>[
  'trunk()', // l10n-ignore: jj's revset
  'tags()', // l10n-ignore: jj's revset
  'untracked_remote_bookmarks()', // l10n-ignore: jj's revset
  'untracked_remote_tags()', // l10n-ignore: jj's revset
];

/// One commit a revset denotes, as the Immutable commits page names it.
@immutable
class RevsetMember {
  /// A member with its [refs], the shortest unique [changeIdPrefix] and whether it [isRoot].
  const RevsetMember({this.refs = const <TopologyRef>[], this.changeIdPrefix = '', this.isRoot = false});

  /// Its bookmarks then tags, local and remote.
  final List<TopologyRef> refs;

  /// The shortest unique prefix of its change id.
  final String changeIdPrefix;

  /// Whether it is the root commit.
  final bool isRoot;
}

/// jj's ignored remote, the colocated Git repository's refs (`parse_remote_refs_arguments`, jj-lib 0.46 `revset.rs`).
const _gitRemote = 'git'; // l10n-ignore: jj's remote name

/// A remote ref's display name, `name@remote`.
String _remoteName(TopologyRef ref) => '${ref.name}@${ref.remote}';

/// Whether [ref] is a remote ref of [kind] that jj counts as untracked.
bool _untrackedRemote(TopologyRef ref, TopologyRefKind kind) =>
    ref.kind == kind && ref.remote != null && ref.remote != _gitRemote && !ref.tracked;

/// The names [term] (one of [immutableBuiltins] after `trunk()`) matches among its [members]: `tags()` the local tags,
/// the untracked terms the untracked remote refs of their kind as `name@remote`; deduplicated, in [members]' order.
List<String> matchNames(List<RevsetMember> members, String term) => <String>{
  for (final RevsetMember member in members)
    for (final TopologyRef ref in member.refs)
      if (switch (term) {
        'tags()' => ref.kind == TopologyRefKind.tag && ref.remote == null, // l10n-ignore: jj's revset
        'untracked_remote_bookmarks()' => _untrackedRemote(ref, TopologyRefKind.bookmark), // l10n-ignore: jj's revset
        'untracked_remote_tags()' => _untrackedRemote(ref, TopologyRefKind.tag), // l10n-ignore: jj's revset
        _ => false,
      })
        if (ref.remote == null) ref.name else _remoteName(ref),
}.toList();

/// The heads line's labels: each member as its local refs' names, else its remote refs (`name@remote`, not `git`), else
/// `root()` for the root, else its shortest unique change id prefix; deduplicated.
List<String> headLabels(List<RevsetMember> members) {
  final labels = <String>{};
  for (final member in members) {
    final local = <String>[
      for (final TopologyRef ref in member.refs)
        if (ref.remote == null) ref.name,
    ];
    final remote = <String>[
      for (final TopologyRef ref in member.refs)
        if (ref.remote != null && ref.remote != _gitRemote) _remoteName(ref),
    ];
    labels.addAll(
      local.isNotEmpty
          ? local
          : remote.isNotEmpty
          ? remote
          : <String>[if (member.isRoot) 'root()' else member.changeIdPrefix], // l10n-ignore: jj's revset
    );
  }
  return labels.toList();
}

/// [names] cut to [cap], then [more] of the rest's count as the last item.
List<String> nameList(List<String> names, int cap, String Function(int count) more) =>
    names.length <= cap ? names : <String>[...names.take(cap), more(names.length - cap)];

/// "Other people's changes", jj's own example term.
const othersImmutableTerm = '(trunk().. & ~mine())'; // l10n-ignore: jj's revset

/// [othersImmutableTerm] without whitespace, for matching.
const _othersCompact = '(trunk()..&~mine())';

/// A bookmark name jj takes bare as a revset symbol.
final _bareSymbol = RegExp(r'^[\w./@+-]+$');

/// [revset]'s top-level `|` terms, trimmed, empty ones dropped: a `|` inside parentheses or a quoted string does not
/// split. `builtin_immutable_heads() | present(develop) | heads(foo)` → those three.
List<String> splitRevsetUnion(String revset) {
  final terms = <String>[];
  final current = StringBuffer();
  var depth = 0;
  String? quote;
  for (var i = 0; i < revset.length; i++) {
    final String c = revset[i];
    if (quote != null) {
      current.write(c);
      if (c == r'\' && quote == '"' && i + 1 < revset.length) {
        current.write(revset[++i]);
      } else if (c == quote) {
        quote = null;
      }
      continue;
    }
    switch (c) {
      case '"' || "'":
        quote = c;
      case '(':
        depth++;
      case ')':
        depth--;
      case '|' when depth == 0:
        terms.add(current.toString());
        current.clear();
        continue;
    }
    current.write(c);
  }
  terms.add(current.toString());
  return <String>[
    for (final String term in terms)
      if (term.trim().isNotEmpty) term.trim(),
  ];
}

/// The text of a TOML string value ([toml] as `jj config list` reads it: a basic `"…"`, a literal `'…'` or a
/// multi-line `"""…"""` / `'''…'''` string), or null when [toml] is not a string (a list, a table, a number).
String? tomlStringValue(String? toml) {
  final String? text = toml?.trim();
  if (text == null || text.length < 2) {
    return null;
  }
  for (final quote in <String>["'''", '"""']) {
    if (text.length >= 6 && text.startsWith(quote) && text.endsWith(quote)) {
      String body = text.substring(3, text.length - 3);
      // TOML drops a newline right after the opening delimiter.
      if (body.startsWith('\r\n')) {
        body = body.substring(2);
      } else if (body.startsWith('\n')) {
        body = body.substring(1);
      }
      return quote == "'''" ? body : _unescape(body);
    }
  }
  if (text.startsWith("'") && text.endsWith("'")) {
    return text.substring(1, text.length - 1);
  }
  if (!text.startsWith('"') || !text.endsWith('"')) {
    return null;
  }
  return _unescape(text.substring(1, text.length - 1));
}

/// A basic string's [body] with its escapes resolved.
String _unescape(String body) {
  final out = StringBuffer();
  for (var i = 0; i < body.length; i++) {
    final String c = body[i];
    if (c != r'\' || i + 1 >= body.length) {
      out.write(c);
      continue;
    }
    final String next = body[++i];
    switch (next) {
      case 'n':
        out.write('\n');
      case 't':
        out.write('\t');
      case 'r':
        out.write('\r');
      case 'b':
        out.write('\b');
      case 'f':
        out.write('\f');
      case 'u' || 'U':
        final length = next == 'u' ? 4 : 8;
        final int? code = i + length < body.length
            ? int.tryParse(body.substring(i + 1, i + 1 + length), radix: 16)
            : null;
        if (code == null) {
          out.write('\\$next');
        } else {
          out.writeCharCode(code);
          i += length;
        }
      default:
        out.write(next);
    }
  }
  return out.toString();
}

/// [text] as a TOML string as the DS shows it: double quotes, single quotes when it holds a double quote, an escaped
/// basic string when it holds both quotes.
String tomlString(String text) => !text.contains('"')
    ? '"$text"'
    : !text.contains("'")
    ? "'$text'"
    : '"${text.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';

/// `revset-aliases."immutable_heads()"` as the Immutable commits page's controls (Story 11.7): the four built-ins,
/// the bookmark chips (`present(<name>)`), "Other people's changes" and a custom revset.
@immutable
class ImmutableHeads {
  /// The controls; jj's default when nothing is given.
  const ImmutableHeads({
    this.builtins = const <String>{...immutableBuiltins},
    this.bookmarks = const <String>[],
    this.others = false,
    this.custom = '',
  });

  /// Maps [alias] — the effective alias's text, or null when it is unset (jj's default) — onto the controls: its
  /// top-level `|` terms; `builtin_immutable_heads()` turns all four built-ins on, a built-in its switch,
  /// `present(x)` or a bare name among the local [bookmarks] a chip (any other bare symbol — `@-`, `main@origin`, a
  /// change id, a tag — stays custom), [othersImmutableTerm] its switch, the rest the custom revset in order,
  /// `none()` nothing.
  factory ImmutableHeads.parse(String? alias, {Iterable<String> bookmarks = const <String>[]}) {
    if (alias == null) {
      return const ImmutableHeads();
    }
    final Set<String> known = bookmarks.toSet();
    final builtins = <String>{};
    final chips = <String>[];
    var others = false;
    final custom = <String>[];
    for (final String term in splitRevsetUnion(alias)) {
      final String compact = term.replaceAll(RegExp(r'\s+'), '');
      if (term == builtinImmutableHeads) {
        builtins.addAll(immutableBuiltins);
      } else if (immutableBuiltins.contains(term)) {
        builtins.add(term);
      } else if (compact == _othersCompact || '($compact)' == _othersCompact) {
        others = true;
      } else if (term == 'none()') {
        // Nothing: the empty set.
      } else if (_bookmarkOf(term, known) case final String name when !chips.contains(name)) {
        chips.add(name);
      } else {
        custom.add(term);
      }
    }
    return ImmutableHeads(builtins: builtins, bookmarks: chips, others: others, custom: custom.join(' | '));
  }

  /// The built-ins on, as their revset calls.
  final Set<String> builtins;

  /// The bookmark chips, by name.
  final List<String> bookmarks;

  /// Whether "Other people's changes" is on.
  final bool others;

  /// The custom revset, trimmed; empty for none.
  final String custom;

  /// The alias the controls write: the built-ins (or `builtin_immutable_heads()` when all four are on), the chips as
  /// `present(<name>)`, [othersImmutableTerm], the custom revset — joined with ` | ` (the lowest precedence, so no term
  /// needs parentheses); `none()` when nothing is on.
  String compose() {
    final bool all = immutableBuiltins.every(builtins.contains);
    final String customText = custom.trim();
    final parts = <String>[
      if (all) builtinImmutableHeads else ...immutableBuiltins.where(builtins.contains),
      for (final String name in bookmarks) 'present(${_bareSymbol.hasMatch(name) ? name : _quoted(name)})',
      if (others) othersImmutableTerm,
      if (customText.isNotEmpty) customText,
    ];
    return parts.isEmpty ? 'none()' : parts.join(' | ');
  }

  /// Whether the controls write jj's default.
  bool get isDefault => compose() == builtinImmutableHeads;

  /// A copy with the given fields replaced.
  ImmutableHeads copyWith({Set<String>? builtins, List<String>? bookmarks, bool? others, String? custom}) =>
      ImmutableHeads(
        builtins: builtins ?? this.builtins,
        bookmarks: bookmarks ?? this.bookmarks,
        others: others ?? this.others,
        custom: custom ?? this.custom,
      );

  static String _quoted(String name) => '"${name.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';

  /// The bookmark name of a `present(x)` [term], or of a bare [term] among the [known] bookmarks, else null.
  static String? _bookmarkOf(String term, Set<String> known) {
    if (term.startsWith('present(') && term.endsWith(')')) {
      final String inner = term.substring('present('.length, term.length - 1).trim();
      if (_bareSymbol.hasMatch(inner)) {
        return inner;
      }
      return inner.startsWith('"') ? tomlStringValue(inner) : null;
    }
    return known.contains(term) ? term : null;
  }

  @override
  bool operator ==(Object other) =>
      other is ImmutableHeads &&
      setEquals(other.builtins, builtins) &&
      listEquals(other.bookmarks, bookmarks) &&
      other.others == others &&
      other.custom == custom;

  @override
  int get hashCode => Object.hash(Object.hashAllUnordered(builtins), Object.hashAll(bookmarks), others, custom);
}
