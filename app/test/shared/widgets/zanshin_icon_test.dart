// SPDX-License-Identifier: MIT

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/src/shared/design/zs_colors.dart';
import 'package:zanshin/src/shared/design/zs_metrics.dart';
import 'package:zanshin/src/shared/widgets/icon_registry.dart';
import 'package:zanshin/src/shared/widgets/zanshin_icon.dart';

import '../../helpers/icon_registry.dart';

bool _isSaveLayer(Symbol method, List<dynamic> arguments) => method == #saveLayer;

bool _isPicture(Symbol method, List<dynamic> arguments) => method == #drawPicture;

/// [icon] under [registry], in the middle of the test surface.
Widget _host(IconRegistry? registry, Widget icon) => Directionality(
  textDirection: TextDirection.ltr,
  child: IconRegistryScope(
    registry: registry,
    child: Center(child: icon),
  ),
);

void main() {
  setUpIconRegistry();

  testWidgets('every glyph of ZI.all is in the registry', (tester) async {
    for (final String name in ZI.all) {
      expect(testIconRegistry[name], isNotNull, reason: name);
    }
    expect(testIconRegistry['arrow-left'], isNull, reason: 'a retired alias');
  });

  for (final (ZsIconSize size, double side) in const <(ZsIconSize, double)>[
    (ZsIconSize.rail, 19),
    (ZsIconSize.xs, 10),
  ]) {
    testWidgets('a glyph paints at the ${size.name} token, scaled from 16 and tinted in one layer', (tester) async {
      const red = Color(0xFFFF0000);
      await tester.pumpWidget(_host(testIconRegistry, ZanshinIcon(ZI.branch, size: size, color: red)));

      expect(tester.getSize(find.byType(ZanshinIcon)), Size.square(side));
      expect(
        find.byType(ZanshinIcon),
        paints
          ..translate(x: 0, y: 0)
          ..something((method, arguments) {
            if (method != #saveLayer) {
              return false;
            }
            final paint = arguments[1] as Paint;
            return arguments[0] == Offset.zero & Size.square(side) &&
                paint.colorFilter == const ColorFilter.mode(red, BlendMode.srcIn);
          })
          ..scale(x: side / 16, y: side / 16)
          ..something(_isPicture),
      );
    });
  }

  testWidgets('a mounted icon takes a new size token', (tester) async {
    await tester.pumpWidget(_host(testIconRegistry, const ZanshinIcon(ZI.branch, size: ZsIconSize.lg)));
    expect(tester.getSize(find.byType(ZanshinIcon)), const Size.square(16));

    await tester.pumpWidget(_host(testIconRegistry, const ZanshinIcon(ZI.branch, size: ZsIconSize.sm)));
    expect(tester.getSize(find.byType(ZanshinIcon)), const Size.square(12));
    expect(find.byType(ZanshinIcon), paints..scale(x: 12 / 16, y: 12 / 16));
  });

  testWidgets('in a box forced larger than the token the glyph keeps its size, centred', (tester) async {
    await tester.pumpWidget(
      _host(
        testIconRegistry,
        const SizedBox.square(dimension: 24, child: ZanshinIcon(ZI.branch, size: ZsIconSize.lg)),
      ),
    );
    expect(tester.getSize(find.byType(ZanshinIcon)), const Size.square(24));
    expect(
      find.byType(ZanshinIcon),
      paints
        ..translate(x: 4, y: 4)
        ..something((method, arguments) => method == #saveLayer && arguments[0] == Offset.zero & const Size.square(16))
        ..scale(x: 1, y: 1)
        ..something(_isPicture),
    );
  });

  testWidgets('a registry loaded in runAsync paints the glyph on the first pump', (tester) async {
    final IconRegistry? registry = await tester.runAsync(IconRegistry.load);
    await tester.pumpWidget(_host(registry, const ZanshinIcon(ZI.fetch, size: ZsIconSize.md)));

    expect(
      find.byType(ZanshinIcon),
      paints
        ..something(_isSaveLayer)
        ..something(_isPicture),
    );
  });

  testWidgets('without a colour the icon takes the nearest IconTheme, else --text', (tester) async {
    const themed = Color(0xFF00FF00);
    await tester.pumpWidget(
      _host(
        testIconRegistry,
        const Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            IconTheme(
              data: IconThemeData(color: themed),
              child: ZanshinIcon(ZI.plus, size: ZsIconSize.sm, key: Key('themed')),
            ),
            ZanshinIcon(ZI.plus, size: ZsIconSize.sm, key: Key('plain')),
          ],
        ),
      ),
    );
    expect(tester.renderObject<RenderZanshinIcon>(find.byKey(const Key('themed'))).color, themed);
    expect(tester.renderObject<RenderZanshinIcon>(find.byKey(const Key('plain'))).color, ZsColors.night.text);
  });

  testWidgets('an unknown name paints nothing and is reported in debug builds', (tester) async {
    await tester.pumpWidget(_host(testIconRegistry, const ZanshinIcon('no-such-glyph', size: ZsIconSize.lg)));

    expect(tester.takeException(), isA<FlutterError>());
    expect(tester.getSize(find.byType(ZanshinIcon)), const Size.square(16));
    expect(find.byType(ZanshinIcon), paintsNothing);
  });

  testWidgets('without a registry the icon paints nothing', (tester) async {
    await tester.pumpWidget(_host(null, const ZanshinIcon(ZI.branch, size: ZsIconSize.lg)));

    expect(tester.takeException(), isNull);
    expect(find.byType(ZanshinIcon), paintsNothing);
  });
}
