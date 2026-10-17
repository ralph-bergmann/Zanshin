// SPDX-License-Identifier: MIT

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:zanshin_ui/src/design/zs_app_theme.dart';
import 'package:zanshin_ui/src/design/zs_appearance.dart';
import 'package:zanshin_ui/src/design/zs_colors.dart';
import 'package:zanshin_ui/src/design/zs_type.dart';

void main() {
  for (final ZsTheme zsTheme in ZsTheme.values) {
    group('the ${zsTheme.name} app theme', () {
      final ThemeData theme = ZsAppTheme.build(ZsAppearance(theme: zsTheme));
      final colors = ZsColors.resolve(ZsAppearance(theme: zsTheme));

      test('takes fills instead of ripples, the canvas base, the body role and --text icons', () {
        expect(theme.brightness, zsTheme.brightness);
        expect(theme.splashFactory, NoSplash.splashFactory);
        expect(theme.scaffoldBackgroundColor, colors.canvasBase);
        expect(theme.iconTheme.color, colors.text);
        final TextStyle body = theme.textTheme.bodyMedium!;
        expect(body.fontFamily, ZsType.body.fontFamily);
        expect(body.fontSize, ZsType.body.fontSize);
        expect(body.fontWeight, ZsType.body.fontWeight);
        expect(body.fontVariations, ZsType.body.fontVariations);
        expect(body.height, ZsType.body.height);
        expect(body.leadingDistribution, ZsType.body.leadingDistribution);
        expect(body.letterSpacing, ZsType.body.letterSpacing);
        expect(body.color, colors.text);
      });

      test('every Material component theme with a mouse cursor shows the arrow', () {
        final cursors = <String, WidgetStateProperty<MouseCursor?>?>{
          'bottomNavigationBar': theme.bottomNavigationBarTheme.mouseCursor,
          'checkbox': theme.checkboxTheme.mouseCursor,
          'dataTable heading': theme.dataTableTheme.headingCellCursor,
          'dataTable row': theme.dataTableTheme.dataRowCursor,
          'dropdownMenu': theme.dropdownMenuTheme.menuStyle?.mouseCursor,
          'elevatedButton': theme.elevatedButtonTheme.style?.mouseCursor,
          'filledButton': theme.filledButtonTheme.style?.mouseCursor,
          'floatingActionButton': theme.floatingActionButtonTheme.mouseCursor,
          'iconButton': theme.iconButtonTheme.style?.mouseCursor,
          'listTile': theme.listTileTheme.mouseCursor,
          'menuBar': theme.menuBarTheme.style?.mouseCursor,
          'menuButton': theme.menuButtonTheme.style?.mouseCursor,
          'menu': theme.menuTheme.style?.mouseCursor,
          'outlinedButton': theme.outlinedButtonTheme.style?.mouseCursor,
          'popupMenu': theme.popupMenuTheme.mouseCursor,
          'radio': theme.radioTheme.mouseCursor,
          'segmentedButton': theme.segmentedButtonTheme.style?.mouseCursor,
          'slider': theme.sliderTheme.mouseCursor,
          'switch': theme.switchTheme.mouseCursor,
          'tabBar': theme.tabBarTheme.mouseCursor,
          'textButton': theme.textButtonTheme.style?.mouseCursor,
        };
        for (final MapEntry<String, WidgetStateProperty<MouseCursor?>?>(:key, :value) in cursors.entries) {
          for (final states in const <Set<WidgetState>>[
            <WidgetState>{},
            <WidgetState>{WidgetState.hovered},
          ]) {
            expect(value?.resolve(states), SystemMouseCursors.basic, reason: '$key $states');
          }
        }
      });
    });
  }
}
