// SPDX-License-Identifier: MIT

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/src/l10n/strings.dart';

void main() {
  test('slotSpans puts each slot\'s span in place and styles the text around them', () {
    const mono = TextStyle(fontFamily: 'mono');
    const dim = TextStyle(fontSize: 9);
    final List<InlineSpan> spans = slotSpans(
      'from ${slot(1)} into ${slot(0)}.',
      const <InlineSpan>[TextSpan(text: 'B', style: mono), TextSpan(text: 'A', style: mono)],
      style: dim,
    );
    expect(
      <(String?, TextStyle?)>[for (final span in spans.cast<TextSpan>()) (span.text, span.style)],
      <Object>[
        ('from ', dim),
        ('A', mono),
        (' into ', dim),
        ('B', mono),
        ('.', dim),
      ],
    );
    expect(slotSpans('${slot(0)} stays', const <InlineSpan>[TextSpan(text: '~/a')]).length, 2);
  });

  testWidgets('context.l10n falls back to the platform strings without the delegate', (tester) async {
    late AppLocalizations strings;
    await tester.pumpWidget(
      Builder(
        builder: (context) {
          strings = context.l10n;
          return const SizedBox.shrink();
        },
      ),
    );
    expect(strings.projectsTitle, 'Projects');
    expect(identical(strings, platformStrings()), isTrue, reason: 'one instance per locale');
  });
}
