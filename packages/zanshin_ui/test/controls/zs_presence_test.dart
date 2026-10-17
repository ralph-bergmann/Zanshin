// SPDX-License-Identifier: MIT

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin_ui/src/controls/zs_presence.dart';
import 'package:zanshin_ui/src/design/zs_motion.dart';

void main() {
  final Duration exit = ZsMotion.full.durExit;
  final closings = <bool>[];

  Widget presence({required bool open}) => Directionality(
    textDirection: TextDirection.ltr,
    child: ZsPresence(
      open: open,
      exit: exit,
      builder: (context, closing) {
        closings.add(closing);
        return const Text('layer');
      },
    ),
  );

  setUp(closings.clear);

  testWidgets('closed from the start: nothing is mounted', (tester) async {
    await tester.pumpWidget(presence(open: false));
    expect(find.text('layer'), findsNothing);
  });

  testWidgets('closing keeps the layer for the exit with closing true, then unmounts it', (tester) async {
    await tester.pumpWidget(presence(open: true));
    expect(closings.last, isFalse);
    await tester.pumpWidget(presence(open: false));
    expect(find.text('layer'), findsOneWidget);
    expect(closings.last, isTrue);
    await tester.pump(exit - const Duration(milliseconds: 1));
    expect(find.text('layer'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 1));
    expect(find.text('layer'), findsNothing);
  });

  testWidgets('opening again within the exit keeps the child mounted and not closing', (tester) async {
    await tester.pumpWidget(presence(open: true));
    final Element first = tester.element(find.text('layer'));
    await tester.pumpWidget(presence(open: false));
    await tester.pump(exit ~/ 2);
    await tester.pumpWidget(presence(open: true));
    expect(closings.last, isFalse);
    await tester.pump(exit);
    expect(find.text('layer'), findsOneWidget);
    expect(tester.element(find.text('layer')), same(first));
  });
}
