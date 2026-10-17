// SPDX-License-Identifier: MIT

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin_ui/src/design/zs_appearance.dart';
import 'package:zanshin_ui/src/design/zs_motion.dart';
import 'package:zanshin_ui/src/materials/zs_menu_material.dart';
import 'package:zanshin_ui/src/materials/zs_surface_transition.dart';

import '../helpers/zs_host.dart';

/// `translate(dx, dy) scale(scale)` as the transition writes it.
Matrix4 _pose({double dx = 0, double dy = 0, double scale = 1}) =>
    Matrix4.diagonal3Values(scale, scale, 1)..setTranslationRaw(dx, dy, 0);

/// Matches a matrix entry by entry within 1e-9.
Matcher _near(Matrix4 expected) => isA<Matrix4>().having(
  (matrix) => matrix.storage.toList(),
  'storage',
  pairwiseCompare<double, double>(expected.storage, (e, a) => (e - a).abs() < 1e-9, 'within 1e-9 of'),
);

/// One row of the motion table: durations in milliseconds, the entrance's start and the exit's end pose (at full
/// motion), and the transform origin.
typedef _Row = ({ZsSurfaceMotion motion, int enter, int exit, Matrix4 from, Matrix4 to, Alignment origin});

final _table = <_Row>[
  (
    motion: ZsSurfaceMotion.menu,
    enter: 110,
    exit: 120,
    from: _pose(scale: .97),
    to: _pose(),
    origin: Alignment.topLeft,
  ),
  (
    motion: ZsSurfaceMotion.popover,
    enter: 160,
    exit: 120,
    from: _pose(dy: -4, scale: .98),
    to: _pose(dy: -2, scale: .99),
    origin: Alignment.topRight,
  ),
  (
    motion: ZsSurfaceMotion.callout,
    enter: 160,
    exit: 120,
    from: _pose(dx: -4),
    to: _pose(),
    origin: Alignment.center,
  ),
  (
    motion: ZsSurfaceMotion.sheet,
    enter: 220,
    exit: 180,
    from: _pose(dy: 8, scale: .985),
    to: _pose(dy: 4, scale: .99),
    origin: Alignment.center,
  ),
];

Widget _surface(
  ZsSurfaceMotion motion, {
  bool closing = false,
  VoidCallback? onClosed,
  bool reduceMotion = false,
  Alignment? origin,
}) => zsHost(
  ZsSurfaceTransition(
    motion: motion,
    closing: closing,
    onClosed: onClosed,
    origin: origin,
    child: const ZsMenuMaterial(child: SizedBox(width: 200, height: 100)),
  ),
  appearance: ZsAppearance(reduceMotion: reduceMotion),
);

Finder _inside(Type type) => find.descendant(of: find.byType(ZsSurfaceTransition), matching: find.byType(type));

double _opacity(WidgetTester tester) => tester.widget<FadeTransition>(_inside(FadeTransition)).opacity.value;

Matrix4 _transform(WidgetTester tester) => tester.widget<Transform>(_inside(Transform)).transform;

Future<void> _pumpMs(WidgetTester tester, int ms) => tester.pump(Duration(milliseconds: ms));

void main() {
  for (final _Row row in _table) {
    final String name = row.motion.name;

    testWidgets('the $name enters in ${row.enter} ms and leaves in ${row.exit} ms', (tester) async {
      var closed = 0;
      await tester.pumpWidget(_surface(row.motion, onClosed: () => closed++));
      expect(_opacity(tester), 0);
      expect(_transform(tester), _near(row.from));
      expect(tester.widget<Transform>(_inside(Transform)).alignment, row.origin);
      expect(tester.widget<IgnorePointer>(_inside(IgnorePointer)).ignoring, isFalse);

      await _pumpMs(tester, row.enter ~/ 2);
      expect(_opacity(tester), closeTo(ZsMotion.full.easeGlide.transform(.5), 1e-6), reason: 'the glide curve');
      await _pumpMs(tester, row.enter - row.enter ~/ 2 - 1);
      expect(_opacity(tester), lessThan(1));
      expect(_transform(tester), isNot(_near(Matrix4.identity())));
      await _pumpMs(tester, 1);
      expect(_opacity(tester), 1);
      expect(_transform(tester), Matrix4.identity());

      await tester.pumpWidget(_surface(row.motion, closing: true, onClosed: () => closed++));
      expect(_opacity(tester), 1, reason: 'the exit starts from rest');
      expect(_transform(tester), Matrix4.identity());
      expect(tester.widget<IgnorePointer>(_inside(IgnorePointer)).ignoring, isTrue);
      await _pumpMs(tester, row.exit ~/ 2);
      expect(_opacity(tester), closeTo(1 - ZsMotion.full.easeExit.transform(.5), 1e-6), reason: 'the exit curve');
      await _pumpMs(tester, row.exit - row.exit ~/ 2 - 1);
      expect(_opacity(tester), greaterThan(0));
      expect(closed, 0);
      await _pumpMs(tester, 1);
      expect(_opacity(tester), 0);
      expect(_transform(tester), _near(row.to));
      expect(closed, 1);
      await _pumpMs(tester, 500);
      expect(closed, 1, reason: 'once per exit');
    });

    testWidgets('under reduce motion the $name only fades, over the same durations', (tester) async {
      await tester.pumpWidget(_surface(row.motion, reduceMotion: true));
      expect(_opacity(tester), 0);
      expect(_transform(tester), Matrix4.identity());
      await _pumpMs(tester, row.enter ~/ 2);
      expect(_opacity(tester), allOf(greaterThan(0), lessThan(1)));
      expect(_transform(tester), Matrix4.identity());
      await _pumpMs(tester, row.enter - row.enter ~/ 2 - 1);
      expect(_opacity(tester), lessThan(1));
      await _pumpMs(tester, 1);
      expect(_opacity(tester), 1);

      await tester.pumpWidget(_surface(row.motion, closing: true, reduceMotion: true));
      await _pumpMs(tester, row.exit ~/ 2);
      expect(_opacity(tester), allOf(greaterThan(0), lessThan(1)));
      expect(_transform(tester), Matrix4.identity());
      await _pumpMs(tester, row.exit - row.exit ~/ 2);
      expect(_opacity(tester), 0);
      expect(_transform(tester), Matrix4.identity());
    });
  }

  testWidgets('closing during the entrance starts the exit from rest', (tester) async {
    await tester.pumpWidget(_surface(ZsSurfaceMotion.popover));
    await _pumpMs(tester, 50);
    expect(_opacity(tester), lessThan(1));
    await tester.pumpWidget(_surface(ZsSurfaceMotion.popover, closing: true));
    expect(_opacity(tester), 1);
    expect(_transform(tester), Matrix4.identity());
    await _pumpMs(tester, 120);
    expect(_opacity(tester), 0);
  });

  testWidgets('reopening during the exit restarts the entrance from its start', (tester) async {
    var closed = 0;
    await tester.pumpWidget(_surface(ZsSurfaceMotion.popover));
    await _pumpMs(tester, 160);
    await tester.pumpWidget(_surface(ZsSurfaceMotion.popover, closing: true, onClosed: () => closed++));
    await _pumpMs(tester, 60);
    await tester.pumpWidget(_surface(ZsSurfaceMotion.popover, onClosed: () => closed++));
    expect(_opacity(tester), 0);
    expect(_transform(tester), _near(_pose(dy: -4, scale: .98)));
    await _pumpMs(tester, 159);
    expect(_opacity(tester), lessThan(1));
    await _pumpMs(tester, 1);
    expect(_opacity(tester), 1);
    expect(closed, 0);
  });

  testWidgets('a surface removed during its exit never reports closed', (tester) async {
    var closed = 0;
    await tester.pumpWidget(_surface(ZsSurfaceMotion.menu));
    await _pumpMs(tester, 110);
    await tester.pumpWidget(_surface(ZsSurfaceMotion.menu, closing: true, onClosed: () => closed++));
    await _pumpMs(tester, 60);
    await tester.pumpWidget(zsHost(const SizedBox()));
    await _pumpMs(tester, 500);
    expect(closed, 0);
  });

  testWidgets('an origin replaces the motion origin', (tester) async {
    await tester.pumpWidget(_surface(ZsSurfaceMotion.menu, origin: Alignment.topRight));
    expect(tester.widget<Transform>(_inside(Transform)).alignment, Alignment.topRight);
  });
}
