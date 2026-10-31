// SPDX-License-Identifier: MIT

import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/l10n/app_localizations_en.dart';
import 'package:zanshin/src/features/projects/relative_time.dart';

final _en = AppLocalizationsEn();

void main() {
  group('lastOpenedLabel', () {
    final now = DateTime(2026, 10, 18, 14, 30);

    for (final (Duration ago, String label) in <(Duration, String)>[
      (Duration.zero, 'now'),
      (const Duration(seconds: 59), 'now'),
      (const Duration(minutes: 1), '1m ago'),
      (const Duration(minutes: 59), '59m ago'),
      (const Duration(hours: 1), '1h ago'),
      (const Duration(hours: 14, minutes: 29), '14h ago'),
      (const Duration(hours: 23, minutes: 59), '23h ago'),
      (const Duration(hours: 30), 'yesterday'),
      (const Duration(hours: 39), '1d ago'),
      (const Duration(days: 6), '6d ago'),
      (const Duration(days: 7), '1w ago'),
      (const Duration(days: 29), '4w ago'),
      (const Duration(days: 30), '1mo ago'),
      (const Duration(days: 364), '12mo ago'),
      (const Duration(days: 365), '1y ago'),
      (const Duration(days: 800), '2y ago'),
    ]) {
      test('$ago ago reads "$label"', () => expect(lastOpenedLabel(_en, now.subtract(ago), now), label));
    }

    test('a time after now reads now; a UTC time is compared in local time', () {
      expect(lastOpenedLabel(_en, now.add(const Duration(hours: 2)), now), 'now');
      expect(lastOpenedLabel(_en, now.subtract(const Duration(hours: 3)).toUtc(), now), '3h ago');
    });
  });

  group('displayPath', () {
    test('the home folder at the start becomes ~', () {
      expect(displayPath('/Users/me/code/api', '/Users/me'), '~/code/api');
      expect(displayPath('/Users/me', '/Users/me'), '~');
      expect(displayPath('/Users/me/code', '/Users/me/'), '~/code');
    });

    test('a path outside home, or one that only shares its prefix, stays as it is', () {
      expect(displayPath('/Volumes/work/api', '/Users/me'), '/Volumes/work/api');
      expect(displayPath('/Users/meg/api', '/Users/me'), '/Users/meg/api');
      expect(displayPath('/srv/api', '/'), '/srv/api');
      expect(displayPath('/srv/api', ''), '/srv/api');
    });
  });
}
