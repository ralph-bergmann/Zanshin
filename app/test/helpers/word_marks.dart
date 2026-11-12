// SPDX-License-Identifier: MIT

import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/src/features/graph/inspector_diff.dart';
import 'package:zanshin_ui/zanshin_ui.dart' show ZsColors;

/// Every diff line with word marks in the pumped tree (Story 10.32), by its shown text: its marked runs. Each line is
/// checked at the paint surface on the way: exactly one block per glyph box of a run in the word fill of the line's
/// hue, the paragraph's full height and clipped to it, all painted before the paragraph; its glyphs [ZsColors.text]
/// inside a run, the line's ink outside.
Map<String, List<String>> paintedWordMarks(WidgetTester tester, ZsColors colors) {
  final marked = <String, List<String>>{};
  for (final Element element in find.byType(DiffWordMarks).evaluate()) {
    final marks = element.widget as DiffWordMarks;
    final RenderParagraph paragraph = tester.renderObject(
      find.descendant(of: find.byWidget(marks), matching: find.byType(RichText)),
    );
    final String text = paragraph.text.toPlainText();
    final Color ink = paragraph.text.style!.color!;
    expect(ink, anyOf(colors.add, colors.rem), reason: text);
    expect(marks.color, ink == colors.add ? colors.addWordBg : colors.remWordBg, reason: text);

    // Painted away from the origin, so a block that ignores the paint offset fails.
    const origin = Offset(31, 7);
    final Rect bounds = origin & paragraph.size;
    final blocks = <Rect>[
      for (final TextRange mark in marks.marks)
        for (final TextBox box in paragraph.getBoxesForSelection(
          TextSelection(baseOffset: mark.start, extentOffset: mark.end),
        ))
          Rect.fromLTRB(
            origin.dx + box.left,
            origin.dy,
            origin.dx + box.right,
            origin.dy + paragraph.size.height,
          ).intersect(bounds),
    ]..removeWhere((block) => block.width <= 0);
    final canvas = TestRecordingCanvas();
    element.renderObject!.paint(TestRecordingPaintingContext(canvas), origin);
    final calls = <Invocation>[for (final RecordedInvocation call in canvas.invocations) call.invocation];
    final int glyphs = calls.indexWhere((call) => call.memberName == #drawParagraph);
    expect(glyphs, isNonNegative, reason: text);
    // A paint keeps its colour in 32-bit floats: compare it the way the canvas holds it.
    List<Rect> fills(Iterable<Invocation> part) => <Rect>[
      for (final Invocation call in part)
        if (call.memberName == #drawRect &&
            (call.positionalArguments[1] as Paint).color.toARGB32() == marks.color.toARGB32())
          call.positionalArguments[0] as Rect,
    ];
    expect(fills(calls.take(glyphs)), blocks, reason: text);
    expect(fills(calls.skip(glyphs)), isEmpty, reason: text);

    for (var offset = 0; offset < text.length; offset++) {
      final span = paragraph.text.getSpanForPosition(TextPosition(offset: offset))! as TextSpan;
      final bool inMark = marks.marks.any((mark) => mark.start <= offset && offset < mark.end);
      expect(span.style?.color ?? ink, inMark ? colors.text : ink, reason: '$text @ $offset');
    }
    expect(marked.containsKey(text), isFalse, reason: 'two marked lines read "$text"');
    marked[text] = <String>[for (final TextRange mark in marks.marks) mark.textInside(text)];
  }
  return marked;
}
