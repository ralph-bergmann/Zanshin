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
  });
}
