// SPDX-License-Identifier: MIT

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin_ui/src/controls/zs_link.dart';
import 'package:zanshin_ui/src/design/zs_appearance.dart';
import 'package:zanshin_ui/src/design/zs_colors.dart';

import '../helpers/controls.dart';
import '../helpers/zs_host.dart';

Widget _link({bool quiet = false, bool external = false, ZsAppearance appearance = const ZsAppearance()}) => zsHost(
  ZsLink(label: 'Read more', onPressed: () {}, quiet: quiet, external: external, identifier: 'link'),
  appearance: appearance,
);

Color? _color(WidgetTester tester) =>
    tester.widget<Text>(find.descendant(of: find.byType(ZsLink), matching: find.byType(Text))).style?.color;

/// Whether the link paints its underline (the text's foreground painter).
bool _underlined(WidgetTester tester) {
  final CustomPaint paint = tester.widget<CustomPaint>(
    find.descendant(of: find.byType(ZsLink), matching: find.byType(CustomPaint)).last,
  );
  return paint.foregroundPainter != null;
}

void main() {
  useMacFocus();
  const ZsColors c = ZsColors.night;

  testWidgets('inline: --accent-live-text, underlined on hover, --text while pressed', (tester) async {
    await tester.pumpWidget(_link());
    expect(_color(tester), c.accentLiveText);
    expect(_underlined(tester), isFalse);
    await hover(tester, find.byType(ZsLink));
    await tester.pumpAndSettle();
    expect(_underlined(tester), isTrue);
    final TestGesture press = await tester.startGesture(tester.getCenter(find.byType(ZsLink)));
    await tester.pumpAndSettle();
    expect(_color(tester), c.text);
    await press.up();
  });

  testWidgets('an inactive window keeps the live accent', (tester) async {
    const inactive = ZsAppearance(inactive: true);
    await tester.pumpWidget(_link(appearance: inactive));
    expect(_color(tester), ZsColors.resolve(inactive).accentLiveText);
    expect(ZsColors.resolve(inactive).accentLiveText, c.accentLiveText);
  });

  testWidgets('quiet: --text-dim to --text on hover, never underlined', (tester) async {
    await tester.pumpWidget(_link(quiet: true));
    expect(_color(tester), c.textDim);
    await hover(tester, find.byType(ZsLink));
    await tester.pumpAndSettle();
    expect(_color(tester), c.text);
    expect(_underlined(tester), isFalse);
  });

  testWidgets('the cursor stays the arrow', (tester) async {
    await tester.pumpWidget(_link());
    await hover(tester, find.byType(ZsLink));
    expect(activeCursor(), SystemMouseCursors.basic);
  });

  testWidgets('VoiceOver: a link; external adds " ↗" and "opens in browser"', (tester) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    await tester.pumpWidget(_link(external: true));
    expect(find.text('Read more ↗'), findsOneWidget);
    expect(
      tester.getSemantics(find.bySemanticsIdentifier('link')),
      isSemantics(label: 'Read more, opens in browser', isLink: true),
    );
    handle.dispose();
  });
}
