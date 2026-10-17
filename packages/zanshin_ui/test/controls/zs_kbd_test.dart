// SPDX-License-Identifier: MIT

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin_ui/src/controls/zs_kbd.dart';
import 'package:zanshin_ui/src/design/zs_colors.dart';
import 'package:zanshin_ui/src/design/zs_type.dart';

import '../helpers/zs_host.dart';

void main() {
  testWidgets('a key cap: --fs-xs mono in --text-muted on --bg-card-2 with a --border edge, radius 3', (tester) async {
    await tester.pumpWidget(zsHost(const ZsKbd('⌘')));
    final Text text = tester.widget(find.text('⌘'));
    expect(text.style?.fontSize, ZsType.fsXs);
    expect(text.style?.fontFamily, ZsType.monoFamily);
    expect(text.style?.color, ZsColors.night.textMuted);
    final DecoratedBox box = tester.widget(find.byType(DecoratedBox));
    final decoration = box.decoration as BoxDecoration;
    expect(decoration.color, ZsColors.night.bgCard2);
    expect((decoration.border! as Border).top.color, ZsColors.night.border);
    expect(decoration.borderRadius, BorderRadius.circular(3));
  });

  testWidgets('it is not focusable', (tester) async {
    await tester.pumpWidget(zsHost(const ZsKbd('/')));
    expect(find.descendant(of: find.byType(ZsKbd), matching: find.byType(Focus)), findsNothing);
  });
}
