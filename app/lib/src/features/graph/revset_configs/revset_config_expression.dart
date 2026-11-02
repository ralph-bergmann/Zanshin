// SPDX-License-Identifier: MIT

import 'package:zanshin_core/zanshin_core.dart';
import 'package:zanshin_settings/zanshin_settings.dart';

/// [configuration]'s revset (Story 10.22; DS RevsetDialog.jsx `exprOf`) through zanshin_core's builder, with each
/// rule's `[start, end)` UTF-16 range in it — null for a rule a blank value drops — so a count error's span names
/// its rule. No kept rule gives `all()`.
({String text, List<({int start, int end})?> ranges}) revsetConfigExpression(RevsetConfiguration configuration) {
  final any = configuration.op == RevsetCombine.or;
  final separator = any ? ' | ' : ' & ';
  final terms = <String>[];
  final ranges = <({int start, int end})?>[];
  var offset = 0;
  final alone = configuration.rules.where(_kept).length == 1;
  for (final RevsetRule rule in configuration.rules) {
    final String? term = revsetRuleTerm(rule, alone: alone);
    if (term == null) {
      ranges.add(null);
      continue;
    }
    if (terms.isNotEmpty) {
      offset += separator.length;
    }
    ranges.add((start: offset, end: offset + term.length));
    offset += term.length;
    terms.add(term);
  }
  return (text: revsetJoin(terms, any: any), ranges: ranges);
}

/// [configuration]'s revset ([revsetConfigExpression]'s text).
String revsetConfigText(RevsetConfiguration configuration) => revsetConfigExpression(configuration).text;

bool _kept(RevsetRule rule) => rule.fn == RevsetRuleFunction.mine || rule.value.trim().isNotEmpty;

/// [rule]'s term, `~`-prefixed when negated; null when its value is blank (`mine()` has none). A `revset` rule's
/// text is grouped unless it is the configuration's only kept term ([alone]) and not negated (Story 10.28).
String? revsetRuleTerm(RevsetRule rule, {bool alone = false}) {
  if (!_kept(rule)) {
    return null;
  }
  final String term = switch (rule.fn) {
    RevsetRuleFunction.revset => alone && !rule.not ? rule.value : revsetGroup(rule.value),
    RevsetRuleFunction.mine => mineRevset(),
    RevsetRuleFunction.files => filesRevset(rule.value, pattern: _pathPattern(rule.mode)),
    RevsetRuleFunction.author => authorRevset(rule.value, pattern: _textPattern(rule.mode), caseInsensitive: rule.ci),
    RevsetRuleFunction.committer => committerRevset(
      rule.value,
      pattern: _textPattern(rule.mode),
      caseInsensitive: rule.ci,
    ),
    RevsetRuleFunction.subject => subjectRevset(rule.value, pattern: _textPattern(rule.mode), caseInsensitive: rule.ci),
    RevsetRuleFunction.description => descriptionRevset(
      rule.value,
      pattern: _textPattern(rule.mode),
      caseInsensitive: rule.ci,
    ),
  };
  return rule.not ? revsetNot(term) : term;
}

// A mode of the other family (a hand-edited file) reads as that family's first kind.
RevsetTextPattern _textPattern(RevsetRuleMode mode) => switch (mode) {
  RevsetRuleMode.exact => RevsetTextPattern.exact,
  RevsetRuleMode.glob => RevsetTextPattern.glob,
  RevsetRuleMode.regex => RevsetTextPattern.regex,
  RevsetRuleMode.substring || RevsetRuleMode.prefix || RevsetRuleMode.file => RevsetTextPattern.substring,
};

RevsetPathPattern _pathPattern(RevsetRuleMode mode) => switch (mode) {
  RevsetRuleMode.file => RevsetPathPattern.file,
  RevsetRuleMode.glob => RevsetPathPattern.glob,
  _ => RevsetPathPattern.prefix,
};
