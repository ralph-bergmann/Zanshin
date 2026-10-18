// SPDX-License-Identifier: MIT

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin_shell/zanshin_shell.dart' show WindowDragArea;
import 'package:zanshin_ui/src/design/zs_appearance.dart';
import 'package:zanshin_ui/src/design/zs_colors.dart';
import 'package:zanshin_ui/src/materials/zs_window_fill.dart';
import 'package:zanshin_ui/src/materials/zs_window_scaffold.dart';

import '../helpers/zs_host.dart';

/// A header control: 80 × 28, like a medium button, and opaque to the pointer.
const _control = SizedBox(
  key: ValueKey<String>('control'),
  width: 80,
  height: 28,
  child: ColoredBox(color: Color(0xFF808080)),
);

/// The scaffold filling an 800 × 600 window.
Widget _window(ZsWindowScaffold scaffold, {ZsAppearance appearance = const ZsAppearance()}) =>
    zsHost(SizedBox(width: 800, height: 600, child: scaffold), appearance: appearance, group: false);

/// The header's box: the one with the `--fl-border` hairline at its bottom.
Finder _header(ZsColors colors) => find.byWidgetPredicate(
  (widget) =>
      widget is DecoratedBox &&
      widget.decoration is BoxDecoration &&
      (widget.decoration as BoxDecoration).border == Border(bottom: BorderSide(color: colors.flBorder)),
);

Color? _titleColor(WidgetTester tester, String title) => tester.widget<Text>(find.text(title)).style?.color;

void main() {
  for (final ZsTheme theme in ZsTheme.values) {
    for (final (String label, Rect? block, double firstX, double midY) in const <(String, Rect?, double, double)>[
      ('the reference block', null, 91, 26),
      ('a measured block (centre y 27)', Rect.fromLTWH(20, 20, 60, 14), 92, 27),
    ]) {
      testWidgets('in ${theme.name} at $label: a 52 header with a hairline, the title at $firstX on y $midY', (
        tester,
      ) async {
        final appearance = ZsAppearance(theme: theme, trafficLights: block);
        await tester.pumpWidget(
          _window(
            const ZsWindowScaffold(
              title: 'Projects',
              header: <Widget>[_control],
              body: SizedBox.expand(key: ValueKey<String>('body')),
            ),
            appearance: appearance,
          ),
        );
        final colors = ZsColors.resolve(appearance);

        expect(find.byType(ZsWindowFill), findsOneWidget);
        expect(tester.getRect(_header(colors)), const Rect.fromLTWH(0, 0, 800, 52));
        expect(tester.getTopLeft(find.text('Projects')).dx, firstX);
        expect(tester.getCenter(find.text('Projects')).dy, moreOrLessEquals(midY));
        expect(tester.getCenter(find.byKey(const ValueKey<String>('control'))).dy, moreOrLessEquals(midY));
        expect(tester.getRect(find.byKey(const ValueKey<String>('control'))).right, 800 - 12);
        expect(tester.getRect(find.byKey(const ValueKey<String>('body'))), const Rect.fromLTWH(0, 52, 800, 548));
        expect(_titleColor(tester, 'Projects'), colors.text);
      });

      testWidgets('in ${theme.name} at $label the centred header centres its controls and hides the title', (
        tester,
      ) async {
        await tester.pumpWidget(
          _window(
            const ZsWindowScaffold(
              title: 'General',
              titleHidden: true,
              align: ZsWindowHeaderAlign.center,
              header: <Widget>[_control],
              body: SizedBox.expand(),
            ),
            appearance: ZsAppearance(theme: theme, trafficLights: block),
          ),
        );

        expect(find.text('General'), findsNothing);
        final Offset centre = tester.getCenter(find.byKey(const ValueKey<String>('control')));
        expect(centre.dx, 400);
        expect(centre.dy, moreOrLessEquals(midY));
      });
    }

    testWidgets('in ${theme.name} the title dims to --text-dim in an inactive window', (tester) async {
      final appearance = ZsAppearance(theme: theme, inactive: true);
      await tester.pumpWidget(
        _window(
          const ZsWindowScaffold(title: 'Projects', body: SizedBox.expand()),
          appearance: appearance,
        ),
      );

      expect(_titleColor(tester, 'Projects'), ZsColors.resolve(appearance).textDim);
    });
  }

  testWidgets('with a sidebar the title starts at sidebar + 12, the sidebar runs the full height under its hairline', (
    tester,
  ) async {
    await tester.pumpWidget(
      _window(
        const ZsWindowScaffold(
          title: 'Projects',
          header: <Widget>[_control],
          sidebar: SizedBox(key: ValueKey<String>('sidebar'), width: 200),
          body: SizedBox.expand(key: ValueKey<String>('body')),
        ),
      ),
    );

    expect(tester.getTopLeft(find.text('Projects')).dx, 200 + 12);
    expect(tester.getRect(find.byKey(const ValueKey<String>('sidebar'))), const Rect.fromLTWH(0, 52, 200, 548));
    expect(tester.getRect(_header(ZsColors.night)), const Rect.fromLTWH(200, 0, 600, 52));
    expect(tester.getRect(find.byKey(const ValueKey<String>('body'))), const Rect.fromLTWH(200, 52, 600, 548));
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is DecoratedBox &&
            widget.decoration is BoxDecoration &&
            (widget.decoration as BoxDecoration).border == Border(right: BorderSide(color: ZsColors.night.flBorder)),
      ),
      findsOneWidget,
    );
  });

  testWidgets('a window without a size takes the header and the body', (tester) async {
    await tester.pumpWidget(
      zsHost(
        const Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 620,
            child: ZsWindowScaffold(title: 'General', body: SizedBox(height: 120)),
          ),
        ),
        group: false,
      ),
    );

    expect(tester.getSize(find.byType(ZsWindowScaffold)), const Size(620, 52 + 120));
  });

  testWidgets("the header's empty space and its title reach the drag area; a control keeps its press", (tester) async {
    await tester.pumpWidget(
      _window(const ZsWindowScaffold(title: 'Projects', header: <Widget>[_control], body: SizedBox.expand())),
    );
    final Iterable<RenderObject> dragAreas = find
        .descendant(of: find.byType(WindowDragArea), matching: find.byType(GestureDetector))
        .evaluate()
        .map((element) => element.renderObject!);
    bool drags(Offset at) =>
        tester.hitTestOnBinding(at).path.any((entry) => dragAreas.any((area) => identical(entry.target, area)));

    expect(drags(const Offset(400, 26)), isTrue, reason: 'empty header space');
    expect(drags(tester.getCenter(find.text('Projects'))), isTrue, reason: 'the title takes no pointer');
    expect(drags(tester.getCenter(find.byKey(const ValueKey<String>('control')))), isFalse);
    expect(drags(const Offset(400, 300)), isFalse, reason: 'the body');
  });
}
