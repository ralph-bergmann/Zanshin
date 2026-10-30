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
