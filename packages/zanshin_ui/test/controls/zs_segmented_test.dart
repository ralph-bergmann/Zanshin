// SPDX-License-Identifier: MIT

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin_ui/src/controls/zs_control_core.dart';
import 'package:zanshin_ui/src/controls/zs_segmented.dart';
import 'package:zanshin_ui/src/design/zs_appearance.dart';
import 'package:zanshin_ui/src/design/zs_colors.dart';
import 'package:zanshin_ui/src/design/zs_motion.dart';

import '../helpers/controls.dart';
import '../helpers/zs_host.dart';

const _segments = <ZsSegment<String>>[
  ZsSegment(value: 'free', label: 'Free'),
  ZsSegment(value: 'soon', label: 'Soon', disabledReason: 'Open a project first'),
  ZsSegment(value: 'compact', label: 'Compact'),
];

Widget _segmented(
  String value,
  ValueChanged<String> onChanged, {
  List<ZsSegment<String>> segments = _segments,
  ZsSegmentedVariant variant = ZsSegmentedVariant.standard,
  ZsSegmentedSize size = ZsSegmentedSize.md,
  ZsAppearance appearance = const ZsAppearance(),
  FocusNode? before,
}) => zsHost(
  Row(
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[
      if (before != null) Focus(focusNode: before, child: const SizedBox(width: 10, height: 10)),
      ZsSegmented<String>(
        segments: segments,
        value: value,
        onChanged: onChanged,
        label: 'Layout',
        variant: variant,
        size: size,
        identifier: 'layout',
      ),
    ],
  ),
  appearance: appearance,
  overlay: true,
);

/// The thumb: the second rounded rect of the track, in --fl-on.
Rect _thumb(WidgetTester tester) {
  late Rect thumb;
  expect(
    find.byType(ZsSegmented<String>),
    paints..something((method, arguments) {
      if (method == #drawRRect && sameColor((arguments[1] as Paint).color, ZsColors.night.flOn)) {
        thumb = (arguments[0] as RRect).outerRect;
        return true;
      }
      return false;
    }),
  );
  return thumb;
}

void main() {
  useMacFocus();

  testWidgets('outer heights 26 · 36 · 30 · 22', (tester) async {
    for (final (ZsSegmentedVariant variant, ZsSegmentedSize size, double height)
        in <(ZsSegmentedVariant, ZsSegmentedSize, double)>[
          (ZsSegmentedVariant.standard, ZsSegmentedSize.md, 26),
          (ZsSegmentedVariant.tabs, ZsSegmentedSize.md, 36),
          (ZsSegmentedVariant.inset, ZsSegmentedSize.md, 30),
          (ZsSegmentedVariant.standard, ZsSegmentedSize.sm, 22),
        ]) {
      await tester.pumpWidget(_segmented('free', (_) {}, variant: variant, size: size));
      expect(tester.getSize(find.byType(ZsSegmented<String>)).height, height);
    }
  });

  testWidgets('the thumb lies under the chosen segment and slides there on --dur-toggle', (tester) async {
    await tester.pumpWidget(_segmented('free', (_) {}));
    final Rect free = tester.getRect(find.byType(ZsControlCore).first);
    final Rect origin = tester.getRect(find.byType(ZsSegmented<String>));
    expect(_thumb(tester), free.shift(-origin.topLeft));
    await tester.pumpWidget(_segmented('compact', (_) {}));
    final Rect compact = tester.getRect(find.byType(ZsControlCore).last).shift(-origin.topLeft);
    await tester.pump();
    await tester.pump(ZsMotion.full.durToggle ~/ 2);
    final Rect mid = _thumb(tester);
    expect(mid.left, greaterThan(free.left - origin.left));
    expect(mid.left, lessThan(compact.left));
    await tester.pump(ZsMotion.full.durToggle);
    expect(_thumb(tester), compact);
  });

  testWidgets('under reduce motion the thumb is simply there', (tester) async {
    const reduced = ZsAppearance(reduceMotion: true);
    await tester.pumpWidget(_segmented('free', (_) {}, appearance: reduced));
    final Rect origin = tester.getRect(find.byType(ZsSegmented<String>));
    await tester.pumpWidget(_segmented('compact', (_) {}, appearance: reduced));
    await tester.pump();
    expect(_thumb(tester), tester.getRect(find.byType(ZsControlCore).last).shift(-origin.topLeft));
  });

  testWidgets('hover brightens only the label', (tester) async {
    await tester.pumpWidget(_segmented('free', (_) {}));
    expect(tester.widget<Text>(find.text('Compact')).style?.color, ZsColors.night.textMuted);
    await hover(tester, find.text('Compact'));
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(find.text('Compact')).style?.color, ZsColors.night.text);
  });

  testWidgets('one Tab stop; ←/→ choose and skip the disabled segment, wrapping', (tester) async {
    var value = 'free';
    final before = FocusNode();
    addTearDown(before.dispose);
    Widget build() => _segmented(value, (v) => value = v, before: before);
    await tester.pumpWidget(build());
    before.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    expect(value, 'compact', reason: 'past the disabled "Soon"');
    await tester.pumpWidget(build());
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    expect(value, 'free', reason: 'wrapping');
    await tester.pumpWidget(build());
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.debugLabel, isNot(startsWith('ZsSegment')), reason: 'one Tab stop');
  });

  testWidgets('when the chosen segment is disabled the Tab stop is the first enabled one', (tester) async {
    final before = FocusNode();
    addTearDown(before.dispose);
    await tester.pumpWidget(_segmented('soon', (_) {}, before: before));
    before.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'ZsSegment 0');
  });

  testWidgets('VoiceOver: a radio group named by its label; tabs are selected tabs', (tester) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    await tester.pumpWidget(_segmented('free', (_) {}));
    expect(
      tester.getSemantics(find.bySemanticsLabel('Free')),
      isSemantics(isInMutuallyExclusiveGroup: true, hasCheckedState: true, isChecked: true),
    );
    expect(find.bySemanticsLabel('Layout'), findsOneWidget);
    await tester.pumpWidget(_segmented('free', (_) {}, variant: ZsSegmentedVariant.tabs));
    expect(
      tester.getSemantics(find.bySemanticsLabel('Free')),
      isSemantics(hasSelectedState: true, isSelected: true),
    );
    handle.dispose();
  });

  testWidgets('increased contrast edges the track and the thumb with --border-strong', (tester) async {
    const contrast = ZsAppearance(increasedContrast: true);
    await tester.pumpWidget(_segmented('free', (_) {}, appearance: contrast));
    final Color edge = ZsColors.resolve(contrast).borderStrong;
    expect(
      find.byType(ZsSegmented<String>),
      paints
        ..something(ringOf(color: edge, inset: 1))
        ..something(ringOf(color: edge, inset: 1)),
    );
  });
}
