// SPDX-License-Identifier: MIT

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:zanshin_ui/src/design/graph_theme.dart';
import 'package:zanshin_ui/src/design/zs_app_theme.dart';
import 'package:zanshin_ui/src/design/zs_appearance.dart';
import 'package:zanshin_ui/src/design/zs_colors.dart';

void main() {
  test('night and paper take the canvas roles from ZsColors', () {
    expect(GraphTheme.night.canvas, ZsColors.night.canvas);
    expect(GraphTheme.night.canvasBase, ZsColors.night.canvasBase);
    expect(GraphTheme.paper.canvas, ZsColors.paper.canvas);
    expect(GraphTheme.paper.canvasBase, ZsColors.paper.canvasBase);
    expect(GraphTheme.resolve(const ZsAppearance(theme: ZsTheme.paper)), GraphTheme.paper);
  });

  test('night and paper take the day-axis roles from ZsColors', () {
    for (final (GraphTheme graph, ZsColors colors) in <(GraphTheme, ZsColors)>[
      (GraphTheme.night, ZsColors.night),
      (GraphTheme.paper, ZsColors.paper),
    ]) {
      expect(graph.dayGuide, colors.borderStrong);
      expect(graph.dayLabelText, colors.textMuted);
      expect(graph.dayLabelFill, colors.cardSolid);
      expect(graph.dayLabelBorder, colors.border);
    }
  });

  // Each card role and the token it derives from, as (role, token) getters.
  final cardRoles = <String, (Color Function(GraphTheme), Color Function(ZsColors))>{
    'cardFill': ((g) => g.cardFill, (c) => c.cardSolid),
    'cardFillHover': ((g) => g.cardFillHover, (c) => c.cardSolidHi),
    'cardBorder': ((g) => g.cardBorder, (c) => c.borderStrong),
    'cardBorderHover': ((g) => g.cardBorderHover, (c) => c.edgeHov),
    'cardSelectedBorder': ((g) => g.cardSelectedBorder, (c) => c.accentLine),
    'workingCopyLine': ((g) => g.workingCopyLine, (c) => c.co),
    'workingCopyTint': ((g) => g.workingCopyTint, (c) => c.coSoft),
    'atBadgeFill': ((g) => g.atBadgeFill, (c) => c.co),
    'atBadgeText': ((g) => g.atBadgeText, (c) => c.coInk),
    'cardText': ((g) => g.cardText, (c) => c.text),
    'cardTextMuted': ((g) => g.cardTextMuted, (c) => c.textMuted),
    'cardTextDim': ((g) => g.cardTextDim, (c) => c.textDim),
    'cardTextFaint': ((g) => g.cardTextFaint, (c) => c.textFaint),
    'conflict': ((g) => g.conflict, (c) => c.conflict),
    'hatch': ((g) => g.hatch, (c) => c.hatch),
    'hatchMark': ((g) => g.hatchMark, (c) => c.hatchMark),
    'focusRing': ((g) => g.focusRing, (c) => c.focusRing),
  };

  test('night, paper and the inactive window take the card roles from ZsColors', () {
    const inactive = ZsAppearance(inactive: true);
    for (final (GraphTheme graph, ZsColors colors) in <(GraphTheme, ZsColors)>[
      (GraphTheme.night, ZsColors.night),
      (GraphTheme.paper, ZsColors.paper),
      (GraphTheme.resolve(inactive), ZsColors.resolve(inactive)),
    ]) {
      for (final MapEntry(key: name, value: (role, token)) in cardRoles.entries) {
        expect(role(graph), token(colors), reason: name);
      }
    }
  });

  test('lerp, copyWith, == and hashCode cover every card role', () {
    final GraphTheme half = GraphTheme.night.lerp(GraphTheme.paper, .5);
    for (final MapEntry(key: name, value: (role, token)) in cardRoles.entries) {
      expect(role(half), Color.lerp(token(ZsColors.night), token(ZsColors.paper), .5), reason: name);
    }
    final GraphTheme all = GraphTheme.night.copyWith(
      cardFill: ZsColors.paper.cardSolid,
      cardFillHover: ZsColors.paper.cardSolidHi,
      cardBorder: ZsColors.paper.borderStrong,
      cardBorderHover: ZsColors.paper.edgeHov,
      cardSelectedBorder: ZsColors.paper.accentLine,
      workingCopyLine: ZsColors.paper.co,
      workingCopyTint: ZsColors.paper.coSoft,
      atBadgeFill: ZsColors.paper.co,
      atBadgeText: ZsColors.paper.coInk,
      cardText: ZsColors.paper.text,
      cardTextMuted: ZsColors.paper.textMuted,
      cardTextDim: ZsColors.paper.textDim,
      cardTextFaint: ZsColors.paper.textFaint,
      conflict: ZsColors.paper.conflict,
      hatch: ZsColors.paper.hatch,
      hatchMark: ZsColors.paper.hatchMark,
      focusRing: ZsColors.paper.focusRing,
    );
    for (final MapEntry(key: name, value: (role, token)) in cardRoles.entries) {
      expect(role(all), token(ZsColors.paper), reason: name);
      // One role swapped makes another theme.
      final GraphTheme one = switch (name) {
        'cardFill' => GraphTheme.night.copyWith(cardFill: const Color(0x01020304)),
        'cardFillHover' => GraphTheme.night.copyWith(cardFillHover: const Color(0x01020304)),
        'cardBorder' => GraphTheme.night.copyWith(cardBorder: const Color(0x01020304)),
        'cardBorderHover' => GraphTheme.night.copyWith(cardBorderHover: const Color(0x01020304)),
        'cardSelectedBorder' => GraphTheme.night.copyWith(cardSelectedBorder: const Color(0x01020304)),
        'workingCopyLine' => GraphTheme.night.copyWith(workingCopyLine: const Color(0x01020304)),
        'workingCopyTint' => GraphTheme.night.copyWith(workingCopyTint: const Color(0x01020304)),
        'atBadgeFill' => GraphTheme.night.copyWith(atBadgeFill: const Color(0x01020304)),
        'atBadgeText' => GraphTheme.night.copyWith(atBadgeText: const Color(0x01020304)),
        'cardText' => GraphTheme.night.copyWith(cardText: const Color(0x01020304)),
        'cardTextMuted' => GraphTheme.night.copyWith(cardTextMuted: const Color(0x01020304)),
        'cardTextDim' => GraphTheme.night.copyWith(cardTextDim: const Color(0x01020304)),
        'cardTextFaint' => GraphTheme.night.copyWith(cardTextFaint: const Color(0x01020304)),
        'conflict' => GraphTheme.night.copyWith(conflict: const Color(0x01020304)),
        'hatch' => GraphTheme.night.copyWith(hatch: const Color(0x01020304)),
        'hatchMark' => GraphTheme.night.copyWith(hatchMark: const Color(0x01020304)),
        _ => GraphTheme.night.copyWith(focusRing: const Color(0x01020304)),
      };
      expect(one, isNot(GraphTheme.night), reason: name);
      expect(one.hashCode, isNot(GraphTheme.night.hashCode), reason: name);
    }
  });

  for (final ZsTheme theme in ZsTheme.values) {
    test('ZsAppTheme.build registers the ${theme.name} graph theme once', () {
      final ThemeData data = ZsAppTheme.build(ZsAppearance(theme: theme));
      expect(data.extensions.values.whereType<GraphTheme>(), hasLength(1));
      expect(data.extension<GraphTheme>(), GraphTheme.resolve(ZsAppearance(theme: theme)));
    });
  }

  testWidgets('of falls back to night without a registered graph theme', (tester) async {
    late GraphTheme found;
    await tester.pumpWidget(
      Theme(
        data: ThemeData(),
        child: Builder(
          builder: (context) {
            found = GraphTheme.of(context);
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    expect(found, GraphTheme.night);
  });

  test('lerp interpolates the canvas base and copyWith replaces a role', () {
    expect(GraphTheme.night.lerp(GraphTheme.paper, 0), GraphTheme.night);
    expect(GraphTheme.night.lerp(GraphTheme.paper, 1), GraphTheme.paper);
    expect(GraphTheme.night.lerp(null, .5), GraphTheme.night);
    expect(GraphTheme.night.copyWith(canvasBase: ZsColors.paper.canvasBase).canvasBase, ZsColors.paper.canvasBase);
    final GraphTheme half = GraphTheme.night.lerp(GraphTheme.paper, .5);
    expect(half.dayGuide, Color.lerp(ZsColors.night.borderStrong, ZsColors.paper.borderStrong, .5));
    expect(half.dayLabelText, Color.lerp(ZsColors.night.textMuted, ZsColors.paper.textMuted, .5));
    expect(half.dayLabelFill, Color.lerp(ZsColors.night.cardSolid, ZsColors.paper.cardSolid, .5));
    expect(half.dayLabelBorder, Color.lerp(ZsColors.night.border, ZsColors.paper.border, .5));
    final GraphTheme swapped = GraphTheme.night.copyWith(
      dayGuide: ZsColors.paper.borderStrong,
      dayLabelText: ZsColors.paper.textMuted,
      dayLabelFill: ZsColors.paper.cardSolid,
      dayLabelBorder: ZsColors.paper.border,
    );
    expect(swapped.dayGuide, ZsColors.paper.borderStrong);
    expect(swapped.dayLabelText, ZsColors.paper.textMuted);
    expect(swapped.dayLabelFill, ZsColors.paper.cardSolid);
    expect(swapped.dayLabelBorder, ZsColors.paper.border);
    expect(swapped, isNot(GraphTheme.night));
    expect(swapped.hashCode, isNot(GraphTheme.night.hashCode));
  });
}
