// SPDX-License-Identifier: MIT

import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/src/features/graph/immutable_reasons.dart';
import 'package:zanshin_core/zanshin_core.dart';

void main() {
  test('a custom alias is split at its top-level terms; a failed count answers null', () async {
    final asked = <List<String>>[];
    var fail = false;
    final reasons = ImmutableReasons(
      readAlias: () async => 'present(develop) | heads(foo)',
      counts: (operation, expressions, {required cap}) async {
        asked.add(expressions);
        if (fail) {
          throw const ZanshinFfiException('jj.jj_lib_error', 'boom');
        }
        return RevsetCounts(<RevsetCount>[
          for (final String expression in expressions)
            RevsetCount(n: expression.contains('heads(foo)') ? 1 : 0, capped: false, error: null),
        ], const <ZanshinWarning>[]);
      },
    );

    expect(await reasons.reasonOf('op1', 'c1'), 'heads(foo)');
    expect(asked.single, <String>['c1 & ::(present(develop))', 'c1 & ::(heads(foo))']);

    fail = true;
    expect(await reasons.reasonOf('op2', 'c1'), isNull, reason: 'a new operation reads again; a failure is no reason');
  });

  test('invalidate re-reads the alias at the same operation (a config write writes no operation)', () async {
    var alias = 'trunk()';
    var reads = 0;
    final reasons = ImmutableReasons(
      readAlias: () async {
        reads++;
        return alias;
      },
      counts: (operation, expressions, {required cap}) async => RevsetCounts(<RevsetCount>[
        for (final String _ in expressions) const RevsetCount(n: 1, capped: false, error: null),
      ], const <ZanshinWarning>[]),
    );

    expect(await reasons.reasonOf('op1', 'c1'), 'trunk()');
    expect(await reasons.reasonOf('op1', 'c1'), 'trunk()');
    expect(reads, 1, reason: 'cached');

    alias = 'tags()';
    reasons.invalidate();
    expect(await reasons.reasonOf('op1', 'c1'), 'tags()');
    expect(reads, 2);
  });
}
