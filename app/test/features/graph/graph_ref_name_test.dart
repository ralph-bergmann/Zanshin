// SPDX-License-Identifier: MIT

import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/l10n/app_localizations_en.dart';
import 'package:zanshin/src/features/graph/graph_ref_name.dart';

final _en = AppLocalizationsEn();

void main() {
  group('graphCleanRefName', () {
    test('the witnesses: typed and pasted', () {
      expect(graphCleanRefName('feature/my new:idea?'), 'feature/my_new_idea_');
      expect(graphCleanRefName('fix/login ~ crash'), 'fix/login___crash');
    });

    test('every refused character becomes _, length kept; the rest stays', () {
      const refused = ' \t\n~^:?*[\\\u0000\u001f\u007f ';
      expect(graphCleanRefName(refused), '_' * refused.length);
      expect(graphCleanRefName('a@b/c.d-e_f+ü'), 'a@b/c.d-e_f+ü');
    });
  });

  group('graphRefNameError', () {
    test('empty and valid names have none; @ inside a name stays allowed', () {
      for (final name in <String>['', 'feature/ok', 'a@b', 'v1.5.0-rc1', 'x.locks']) {
        expect(graphRefNameError(_en, name), isNull, reason: name);
      }
    });

    test('each rule, in its order', () {
      <String, String>{
        '@': 'Must not be “@” alone',
        '/a': 'Must not start with “/”',
        'a/': 'Must not end with “/”',
        '.a': 'Must not start with “.”',
        'a.lock': 'Must not end with “.lock”',
        'release/1.5.': 'Must not end with “.”',
        'a..b': 'Must not contain “..”',
        'a//b': 'Must not contain “//”',
        'a@{b': 'Must not contain “@{”',
        // The first failing rule wins.
        '/a/': 'Must not start with “/”',
        '.a.lock': 'Must not start with “.”',
      }.forEach((name, error) => expect(graphRefNameError(_en, name), error, reason: name));
    });
  });
}
