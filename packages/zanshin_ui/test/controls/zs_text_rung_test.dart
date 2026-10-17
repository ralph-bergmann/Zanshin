// SPDX-License-Identifier: MIT

import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin_ui/src/controls/zs_text_rung.dart';
import 'package:zanshin_ui/src/design/zs_colors.dart';

void main() {
  const ZsColors c = ZsColors.night;

  test('at rest dim and faint read as themselves', () {
    final rung = ZsTextRung.of(c);
    expect((rung.dim, rung.faint), (c.textDim, c.textFaint));
  });

  test('hover: faint reads as dim', () {
    final rung = ZsTextRung.of(c, hovered: true);
    expect((rung.dim, rung.faint), (c.textDim, c.textDim));
  });

  test('on, pressed, selected, highlighted: dim and faint read as muted, over hover', () {
    final rung = ZsTextRung.of(c, hovered: true, raised: true);
    expect((rung.dim, rung.faint), (c.textMuted, c.textMuted));
  });
}
