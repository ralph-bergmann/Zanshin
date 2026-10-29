// SPDX-License-Identifier: MIT

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin_ui/src/controls/zs_focus_ring.dart';

import '../helpers/zs_host.dart';

// Its own file: the hooks are global and stay for the rest of the isolate.
void main() {
  testWidgets('a pointer press hides the rings; a navigation key shows them; typing, ↩, ⌘ and Shift do not', (
    tester,
  ) async {
    zsRingFollowsInput();
    addTearDown(() => FocusManager.instance.highlightStrategy = FocusHighlightStrategy.automatic);
    final field = FocusNode();
    final controller = TextEditingController();
    addTearDown(field.dispose);
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      zsHost(
        Column(
          children: <Widget>[
            const SizedBox(width: 50, height: 50),
            SizedBox(
              width: 100,
              height: 20,
              child: EditableText(
                controller: controller,
                focusNode: field,
                style: const TextStyle(),
                cursorColor: const Color(0xFF000000),
                backgroundCursorColor: const Color(0xFF000000),
              ),
            ),
          ],
        ),
      ),
    );
    FocusHighlightMode mode() => FocusManager.instance.highlightMode;

    await tester.tapAt(const Offset(5, 5));
    expect(mode(), FocusHighlightMode.touch);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    expect(mode(), FocusHighlightMode.traditional);

    await tester.tapAt(const Offset(5, 5));
    await tester.sendKeyEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    expect(mode(), FocusHighlightMode.touch, reason: 'Shift alone and ⌘C move no focus');

    field.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(mode(), FocusHighlightMode.touch, reason: 'typing and ↩ in a text field are no navigation');
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    expect(mode(), FocusHighlightMode.traditional, reason: 'Tab leaves the field');
  });
}
