// SPDX-License-Identifier: MIT

import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/src/features/graph/inspector_diff.dart';
import 'package:zanshin_ui/zanshin_ui.dart' show ZsColors;

/// Every diff line with word marks in the pumped tree (Story 10.32, Story 5.10), by its shown text: its marked runs,
/// each as `-run` (a removed run, `--rem-word-bg`) or `+run` (an added one, `--add-word-bg`). Each line is checked at
/// the paint surface on the way: exactly one block per glyph box of a run in its run's word fill, the paragraph's full
/// height and clipped to it, all painted before the paragraph; its glyphs [ZsColors.text] inside a run, the line's
/// ink outside.
Map<String, List<String>> paintedWordMarks(WidgetTester tester, ZsColors colors) {
  final marked = <String, List<String>>{};
  for (final Element element in find.byType(DiffWordMarks).evaluate()) {
    final marks = element.widget as DiffWordMarks;
    final RenderParagraph paragraph = tester.renderObject(
      find.descendant(of: find.byWidget(marks), matching: find.byType(RichText)),
    );
    final String text = paragraph.text.toPlainText();
    final Color ink = paragraph.text.style!.color!;
    expect(ink, anyOf(colors.add, colors.rem, colors.text, colors.textMuted), reason: text);
    for (final PaintedWordMark mark in marks.marks) {
      expect(mark.color, anyOf(colors.addWordBg, colors.remWordBg), reason: text);
    }

    // Painted away from the origin, so a block that ignores the paint offset fails.
    const origin = Offset(31, 7);
    final Rect bounds = origin & paragraph.size;
    // A paint keeps its colour in 32-bit floats: compare it the way the canvas holds it.
    final blocks = <(Rect, int)>[
      for (final PaintedWordMark mark in marks.marks)
        for (final TextBox box in paragraph.getBoxesForSelection(
          TextSelection(baseOffset: mark.range.start, extentOffset: mark.range.end),
        ))
          (
            Rect.fromLTRB(
              origin.dx + box.left,
              origin.dy,
              origin.dx + box.right,
              origin.dy + paragraph.size.height,
            ).intersect(bounds),
            mark.color.toARGB32(),
          ),
    ]..removeWhere((block) => block.$1.width <= 0);
    final canvas = TestRecordingCanvas();
    element.renderObject!.paint(TestRecordingPaintingContext(canvas), origin);
    final calls = <Invocation>[for (final RecordedInvocation call in canvas.invocations) call.invocation];
    final int glyphs = calls.indexWhere((call) => call.memberName == #drawParagraph);
    expect(glyphs, isNonNegative, reason: text);
    final fillColors = <int>{colors.addWordBg.toARGB32(), colors.remWordBg.toARGB32()};
    List<(Rect, int)> fills(Iterable<Invocation> part) => <(Rect, int)>[
      for (final Invocation call in part)
        if (call.memberName == #drawRect &&
            fillColors.contains((call.positionalArguments[1] as Paint).color.toARGB32()))
          (call.positionalArguments[0] as Rect, (call.positionalArguments[1] as Paint).color.toARGB32()),
    ];
    expect(fills(calls.take(glyphs)), blocks, reason: text);
    expect(fills(calls.skip(glyphs)), isEmpty, reason: text);

    for (var offset = 0; offset < text.length; offset++) {
      final span = paragraph.text.getSpanForPosition(TextPosition(offset: offset))! as TextSpan;
      final bool inMark = marks.marks.any((mark) => mark.range.start <= offset && offset < mark.range.end);
      expect(span.style?.color ?? ink, inMark ? colors.text : ink, reason: '$text @ $offset');
    }
    expect(marked.containsKey(text), isFalse, reason: 'two marked lines read "$text"');
    marked[text] = <String>[
      for (final PaintedWordMark mark in marks.marks)
        '${mark.color == colors.addWordBg ? '+' : '-'}${mark.range.textInside(text)}',
    ];
  }
  return marked;
}
