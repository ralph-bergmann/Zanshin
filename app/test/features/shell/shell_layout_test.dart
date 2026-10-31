// SPDX-License-Identifier: MIT

import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/src/features/shell/graph_insets.dart';
import 'package:zanshin/src/features/shell/shell_layout.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

ShellLayout _layout(
  double width, {
  bool pinned = true,
  bool inspector = true,
  bool minimap = false,
  double panel = 300,
  double inspectorWidth = 460,
  bool wasCollapsed = false,
  ZsMetrics metrics = ZsMetrics.standard,
}) => ShellLayout.resolve(
  windowWidth: width,
  metrics: metrics,
  pinned: pinned,
  inspectorOpen: inspector,
  minimapShown: minimap,
  rememberedPanel: panel,
  rememberedInspector: inspectorWidth,
  wasCollapsed: wasCollapsed,
);

void main() {
  test(
    'the collapse rule: 1192 both, 1150 and 1112 the inspector shrinks, 1080 and 1052 the panel, 1051 collapsed',
    () {
      for (final (double width, double panel, double inspector, bool collapsed, double left)
          in const <(double, double, double, bool, double)>[
            (1192, 300, 460, false, 388),
            (1150, 300, 418, false, 388),
            (1112, 300, 380, false, 388),
            (1080, 268, 380, false, 356),
            (1052, 240, 380, false, 328),
            (1051, 300, 460, true, 76),
          ]) {
        final ShellLayout layout = _layout(width);
        expect(layout.collapsed, collapsed, reason: '$width');
        if (!collapsed) {
          expect(layout.panelWidth, panel, reason: '$width');
        }
        expect(layout.inspectorWidth, inspector, reason: '$width');
        expect(layout.insets.left, left, reason: '$width');
        expect(layout.insets.right, layout.inspectorWidth + 24, reason: '$width');
        // At least 320 px of graph stay visible.
        expect(width - layout.insets.left - layout.insets.right, greaterThanOrEqualTo(320), reason: '$width');
      }
    },
  );

  test('widening after a collapse, the panel stays collapsed until 1112 and returns at its remembered 300', () {
    expect(_layout(1052, wasCollapsed: true).collapsed, isTrue);
    expect(_layout(1111, wasCollapsed: true).collapsed, isTrue);
    final ShellLayout back = _layout(1112, wasCollapsed: true);
    expect(back.collapsed, isFalse);
    expect(back.panelWidth, 300);
    expect(back.inspectorWidth, 380);
  });

  test('at the 880 minimum the pinned panel collapses beside the open inspector, which leaves exactly 320', () {
    final ShellLayout layout = _layout(880);
    expect(layout.collapsed, isTrue);
    expect(layout.inspectorWidth, 460);
    expect(880 - layout.insets.left - layout.insets.right, 320);
  });

  test(
    'insets: top 60 (68 in full screen), left 76 without a pin, right by inspector, minimap or the inset, bottom 12',
    () {
      final GraphInsets none = _layout(1440, pinned: false, inspector: false).insets;
      expect(none, const GraphInsets(top: 60, left: 76, right: 12, bottom: 12, inspectorWidth: 0, minimapWidth: 0));
      expect(_layout(1440, pinned: false).insets.inspectorWidth, 460, reason: 'the open inspector');
      expect(_layout(1440, pinned: false, inspector: false, minimap: true).insets.right, 158);
      expect(_layout(1440, pinned: false, inspector: false, minimap: true).insets.minimapWidth, 134);
      expect(_layout(1440, pinned: false, minimap: true).insets.right, 484, reason: 'the inspector wins');
      expect(_layout(1440, inspector: false).insets.left, 388);
      final fullScreen = ZsMetrics.resolve(const ZsAppearance(fullScreen: true));
      expect(_layout(1440, metrics: fullScreen).insets.top, 68);
    },
  );

  test('without a pin the inspector shrinks toward 380 as the window narrows past 420 + its width', () {
    expect(_layout(1440, pinned: false).inspectorWidth, 460);
    expect(_layout(840, pinned: false).inspectorWidth, 420);
    expect(_layout(700, pinned: false).inspectorWidth, 380);
  });

  test('a pinned panel without the inspector keeps 320 of graph beside the minimap column', () {
    final ShellLayout layout = _layout(900, inspector: false, minimap: true, panel: 440);
    expect(layout.collapsed, isFalse);
    expect(layout.panelWidth, 900 - 88 - 158 - 320);
  });

  test('remembered widths outside their ranges are used clamped', () {
    final ShellLayout layout = _layout(2000, panel: 900, inspectorWidth: 100);
    expect(layout.panelWidth, 440);
    expect(layout.inspectorWidth, 380);
  });

  test('the drag limits keep 320 of graph and stay inside the ranges', () {
    expect(_layout(1192).panelMax, 300);
    expect(_layout(2000).panelMax, 440);
    expect(_layout(1000, pinned: false).panelMax, 240);
    expect(_layout(1440, pinned: false).inspectorMax, 720);
    expect(_layout(1192).inspectorMax, 1192 - 388 - 24 - 320);
    expect(_layout(800, pinned: false).inspectorMax, 380);
  });

  test('equal layouts are equal; toString shows the widths', () {
    expect(_layout(1192), _layout(1192));
    expect(_layout(1192).hashCode, _layout(1192).hashCode);
    expect(_layout(1192), isNot(_layout(1150)));
    expect(_layout(1192).toString(), contains('panel: 300.0'));
  });
}
