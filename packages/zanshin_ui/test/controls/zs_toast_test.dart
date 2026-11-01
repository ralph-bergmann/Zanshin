// SPDX-License-Identifier: MIT

import 'package:flutter/rendering.dart' show SemanticsRole;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin_ui/src/controls/zs_control_core.dart';
import 'package:zanshin_ui/src/controls/zs_toast.dart';
import 'package:zanshin_ui/src/controls/zs_tooltip.dart';
import 'package:zanshin_ui/src/design/zs_colors.dart';
import 'package:zanshin_ui/src/icons/zanshin_icon.dart';
import 'package:zanshin_ui/src/materials/zs_glass.dart';

import '../helpers/icon_registry.dart';
import '../helpers/zs_host.dart';

void main() {
  setUpIconRegistry();
  tearDown(ZsTooltip.resetWarmWindow);

  var undos = 0;
  var dismisses = 0;
  setUp(() => undos = dismisses = 0);

  Widget toast({ZsToastTone tone = ZsToastTone.success, String? tooltip}) => zsHost(
    ZsToast(
      tone: tone,
      tooltip: tooltip,
      message: const TextSpan(
        children: <InlineSpan>[
          TextSpan(text: 'Abandoned '),
          TextSpan(text: 'ovknlmro'),
        ],
      ),
      actions: <ZsToastAction>[ZsToastAction(label: 'Undo', tooltip: 'jj undo', onPressed: () => undos++)],
      onDismiss: () => dismisses++,
    ),
    overlay: true,
    icons: true,
  );

  Semantics root(WidgetTester tester) =>
      tester.widget<Semantics>(find.descendant(of: find.byType(ZsToast), matching: find.byType(Semantics)).first);

  testWidgets('a 36 px strong glass pill; success has no glyph; Undo is 26 high, × a 26 circle', (tester) async {
    await tester.pumpWidget(toast());
    expect(tester.getSize(find.byType(ZsToast)).height, 36);
    final ZsGlass glass = tester.widget(find.byType(ZsGlass));
    expect(glass.fill, ZsGlassFill.strong);
    expect(glass.blur, ZsGlassBlur.regular);
    final List<ZanshinIcon> icons = tester.widgetList<ZanshinIcon>(find.byType(ZanshinIcon)).toList();
    expect(icons.map((icon) => icon.name), <String>[ZI.close]);
    expect(tester.getSize(find.ancestor(of: find.text('Undo'), matching: find.byType(SizedBox)).first).height, 26);
    expect(
      tester.getSize(find.ancestor(of: find.byType(ZanshinIcon), matching: find.byType(SizedBox)).first),
      const Size.square(26),
    );
    expect(tester.widget<Text>(find.text('Undo')).style?.color, ZsColors.night.text);
  });

  testWidgets('warn shows conflict in --warn, error alert in --rem', (tester) async {
    await tester.pumpWidget(toast(tone: ZsToastTone.warn));
    ZanshinIcon first() => tester.widgetList<ZanshinIcon>(find.byType(ZanshinIcon)).first;
    expect(first().name, ZI.conflict);
    expect(first().color, ZsColors.night.warn);
    await tester.pumpWidget(toast(tone: ZsToastTone.error));
    expect(first().name, ZI.alert);
    expect(first().color, ZsColors.night.rem);
  });

  testWidgets("Undo and × run their callbacks; Undo's tooltip is its command, × is labelled Dismiss", (tester) async {
    await tester.pumpWidget(toast());
    await tester.tap(find.text('Undo'));
    await tester.tap(find.bySemanticsLabel('Dismiss'));
    expect(undos, 1);
    expect(dismisses, 1);
    final ZsTooltip tip = tester.widget(find.ancestor(of: find.text('Undo'), matching: find.byType(ZsTooltip)).first);
    expect(tip.message, 'jj undo');
  });

  testWidgets('success and warn are a live region, error an alert; the label is the plain text', (tester) async {
    await tester.pumpWidget(toast());
    expect(root(tester).properties.liveRegion, isTrue);
    expect(root(tester).properties.role, isNull);
    expect(root(tester).properties.label, 'Abandoned ovknlmro');
    await tester.pumpWidget(toast(tone: ZsToastTone.error));
    expect(root(tester).properties.liveRegion, isFalse);
    expect(root(tester).properties.role, SemanticsRole.alert);
  });

  testWidgets('actionFocusSkip keeps the buttons out of Tab, and lifting it puts them back', (tester) async {
    Widget skipping(bool skip) => zsHost(
      ZsToast(
        message: const TextSpan(text: 'Abandoned'),
        actions: <ZsToastAction>[ZsToastAction(label: 'Undo', tooltip: 'jj undo', onPressed: () {})],
        onDismiss: () {},
        actionFocusSkip: skip,
      ),
      overlay: true,
      icons: true,
    );
    await tester.pumpWidget(skipping(true));
    final nodes = <FocusNode>[
      for (final FocusableActionDetector detector in tester.widgetList(
        find.descendant(of: find.byType(ZsControlCore), matching: find.byType(FocusableActionDetector)),
      ))
        detector.focusNode!,
    ];
    expect(nodes, hasLength(2));
    expect(nodes.map((node) => node.skipTraversal), <bool>[true, true]);
    await tester.pumpWidget(skipping(false));
    expect(nodes.map((node) => node.skipTraversal), <bool>[false, false]);
  });

  testWidgets('a tooltip sits over the text', (tester) async {
    await tester.pumpWidget(toast(tooltip: 'line one\nline two'));
    expect(
      find.byWidgetPredicate((widget) => widget is ZsTooltip && widget.message == 'line one\nline two'),
      findsOneWidget,
    );
  });
}
