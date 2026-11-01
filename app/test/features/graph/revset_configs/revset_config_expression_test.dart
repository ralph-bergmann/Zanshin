// SPDX-License-Identifier: MIT

import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/src/features/graph/revset_configs/revset_config_expression.dart';
import 'package:zanshin_settings/zanshin_settings.dart';

RevsetConfiguration _config(List<RevsetRule> rules, {RevsetCombine op = RevsetCombine.and}) =>
    RevsetConfiguration(id: 'c', op: op, rules: rules);

void main() {
  test('every text function × mode × -i × not builds its golden term', () {
    const kinds = <RevsetRuleMode, String>{
      RevsetRuleMode.substring: 'substring',
      RevsetRuleMode.exact: 'exact',
      RevsetRuleMode.glob: 'glob',
      RevsetRuleMode.regex: 'regex',
    };
    for (final fn in <RevsetRuleFunction>[
      RevsetRuleFunction.author,
      RevsetRuleFunction.committer,
      RevsetRuleFunction.subject,
      RevsetRuleFunction.description,
    ]) {
      for (final MapEntry<RevsetRuleMode, String> kind in kinds.entries) {
        for (final ci in <bool>[false, true]) {
          for (final not in <bool>[false, true]) {
            final rule = RevsetRule(fn: fn, mode: kind.key, value: 'v"x', ci: ci, not: not);
            expect(
              revsetRuleTerm(rule),
              '${not ? '~' : ''}${fn.name}(${kind.value}${ci ? '-i' : ''}:"v\\"x")',
              reason: '$rule',
            );
          }
        }
      }
    }
  });

  test('files: path or folder, exact file and glob, never -i; mine() has no value', () {
    RevsetRule files(RevsetRuleMode mode, {bool not = false}) =>
        RevsetRule(fn: RevsetRuleFunction.files, mode: mode, value: 'a[1]/b', ci: true, not: not);
    expect(revsetRuleTerm(files(RevsetRuleMode.prefix)), 'files(cwd:"a[1]/b")');
    expect(revsetRuleTerm(files(RevsetRuleMode.file)), 'files(file:"a[1]/b")');
    expect(revsetRuleTerm(files(RevsetRuleMode.glob, not: true)), '~files(glob:"a[1]/b")');
    expect(revsetRuleTerm(const RevsetRule(fn: RevsetRuleFunction.mine)), 'mine()');
    expect(revsetRuleTerm(const RevsetRule(fn: RevsetRuleFunction.mine, not: true)), '~mine()');
  });

  test('the matrix row: author contains lena -i & ~files glob *.lock', () {
    expect(
      revsetConfigText(
        _config(const <RevsetRule>[
          RevsetRule(fn: RevsetRuleFunction.author, value: 'lena', ci: true),
          RevsetRule(fn: RevsetRuleFunction.files, mode: RevsetRuleMode.glob, value: '*.lock', not: true),
        ]),
      ),
      'author(substring-i:"lena") & ~files(glob:"*.lock")',
    );
  });

  test('| joins with " | "; a blank value drops its rule; no kept rule is all()', () {
    expect(
      revsetConfigText(
        _config(const <RevsetRule>[
          RevsetRule(fn: RevsetRuleFunction.mine),
          RevsetRule(fn: RevsetRuleFunction.subject, value: '  '),
          RevsetRule(fn: RevsetRuleFunction.description, mode: RevsetRuleMode.exact, value: 'x'),
        ], op: RevsetCombine.or),
      ),
      'mine() | description(exact:"x")',
    );
    expect(revsetConfigText(_config(const <RevsetRule>[])), 'all()');
    expect(revsetConfigText(_config(const <RevsetRule>[RevsetRule(fn: RevsetRuleFunction.author)])), 'all()');
  });

  test('each kept rule has its UTF-16 range in the text, a dropped one none', () {
    final ({String text, List<({int start, int end})?> ranges}) built = revsetConfigExpression(
      _config(const <RevsetRule>[
        RevsetRule(fn: RevsetRuleFunction.author, value: 'König'),
        RevsetRule(fn: RevsetRuleFunction.files),
        RevsetRule(fn: RevsetRuleFunction.mine, not: true),
      ]),
    );
    expect(built.text, 'author(substring:"König") & ~mine()');
    expect(built.ranges[1], isNull);
    final ({int start, int end}) first = built.ranges[0]!;
    final ({int start, int end}) last = built.ranges[2]!;
    expect(built.text.substring(first.start, first.end), 'author(substring:"König")');
    expect(built.text.substring(last.start, last.end), '~mine()');
  });
}
