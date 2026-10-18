// SPDX-License-Identifier: MIT

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' show TextField;
import 'package:zanshin_ui/src/controls/zs_field_list.dart';
import 'package:zanshin_ui/src/controls/zs_kbd.dart';
import 'package:zanshin_ui/src/controls/zs_text_field.dart';
import 'package:zanshin_ui/src/design/zs_appearance.dart';
import 'package:zanshin_ui/src/design/zs_colors.dart';
import 'package:zanshin_ui/src/design/zs_metrics.dart';

import '../helpers/controls.dart';
import '../helpers/icon_registry.dart';
import '../helpers/zs_host.dart';

Widget _field(
  Widget field, {
  ZsAppearance appearance = const ZsAppearance(),
}) => zsHost(SizedBox(width: 240, child: field), appearance: appearance, overlay: true, icons: true);

/// The well: the first rounded rect the field paints.
RRect _well(WidgetTester tester, Finder field) {
  late RRect well;
  var found = false;
  expect(
    field,
    paints..something((method, arguments) {
      if (!found && method == #drawRRect) {
        found = true;
        well = arguments[0] as RRect;
        return true;
      }
      return false;
    }),
  );
  return well;
}

void main() {
  setUpIconRegistry();
  useMacFocus();
  const ZsColors c = ZsColors.night;
  const ZsMetrics m = ZsMetrics.standard;

  group('ZsTextField', () {
    testWidgets('rest: --field-bg with a 1 px --fl-border; hover --border-strong', (tester) async {
      await tester.pumpWidget(_field(const ZsTextField(placeholder: 'Summary')));
      final Finder field = find.byType(ZsTextField);
      expect(tester.getSize(field).height, 30);
      expect(
        field,
        paints
          ..something(rrectOf(color: c.fieldBg))
          ..something(ringOf(color: c.flBorder, inset: 1)),
      );
      expect(tester.widget<Text>(find.text('Summary')).style?.color, c.textFaint);
      await hover(tester, field);
      await tester.pumpAndSettle();
      expect(field, paints..something(ringOf(color: c.borderStrong, inset: 1)));
      expect(activeCursor(), SystemMouseCursors.text);
    });

    testWidgets('any focus, a click included: an --accent-line edge and a 3 px --accent-ring halo', (tester) async {
      await tester.pumpWidget(_field(const ZsTextField()));
      final Finder field = find.byType(ZsTextField);
      await tester.tap(field);
      await tester.pumpAndSettle();
      final RRect well = _well(tester, field);
      expect(field, paints..drrect(outer: well.inflate(m.fieldHalo), inner: well, color: c.accentRing));
      expect(field, paints..something(ringOf(color: c.accentLine, inset: 1)));
    });

    testWidgets('a forced states controller adds hover and focus (the catalogue matrix)', (tester) async {
      final states = WidgetStatesController(<WidgetState>{WidgetState.hovered});
      addTearDown(states.dispose);
      await tester.pumpWidget(_field(ZsTextField(statesController: states)));
      final Finder field = find.byType(ZsTextField);
      await tester.pumpAndSettle();
      expect(field, paints..something(ringOf(color: c.borderStrong, inset: 1)));
      states.value = <WidgetState>{WidgetState.focused};
      await tester.pumpAndSettle();
      expect(field, paints..something(ringOf(color: c.accentLine, inset: 1)));
    });

    testWidgets('error: an --error edge, an --error-ring halo when focused, and the message line', (tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _field(const ZsTextField(error: 'Unknown function', identifier: 'revset', label: 'Revset')),
      );
      final Finder field = find.byType(ZsTextField);
      expect(field, paints..something(ringOf(color: c.error, inset: 1)));
      expect(tester.widget<Text>(find.text('Unknown function')).style?.color, c.rem);
      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();
      expect(field, paints..something(ringOf(color: c.errorRing)));
      expect(
        tester.getSemantics(find.bySemanticsIdentifier('revset')),
        isSemantics(label: 'Revset', hint: 'Unknown function', isTextField: true),
      );
      handle.dispose();
    });

    testWidgets('without a row label the placeholder names the field', (tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      await tester.pumpWidget(_field(const ZsTextField(placeholder: 'Summary', identifier: 'summary')));
      expect(
        tester.getSemantics(find.bySemanticsIdentifier('summary')),
        isSemantics(label: 'Summary', isTextField: true),
      );
      handle.dispose();
    });

    testWidgets('read-only: no fill, a dashed edge, --text-muted, still the I-beam', (tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _field(
          ZsTextField(
            controller: ZsTextEditingController(text: '~/.config/jj/config.toml'),
            readOnly: true,
            identifier: 'path',
          ),
        ),
      );
      final Finder field = find.byType(ZsTextField);
      expect(
        field,
        paints
          ..something(rrectOf(color: const Color(0x00000000)))
          ..path(color: c.flBorder),
      );
      expect(tester.widget<TextField>(find.byType(TextField)).style?.color, c.textMuted);
      await hover(tester, field);
      expect(activeCursor(), SystemMouseCursors.text);
      expect(
        tester.getSemantics(find.bySemanticsIdentifier('path')),
        isSemantics(isTextField: true, isReadOnly: true),
      );
      handle.dispose();
    });

    testWidgets('an inactive window: a focused field looks at rest, no halo and no caret', (tester) async {
      final focus = FocusNode();
      addTearDown(focus.dispose);
      const inactive = ZsAppearance(inactive: true);
      await tester.pumpWidget(_field(ZsTextField(focusNode: focus), appearance: inactive));
      focus.requestFocus();
      await tester.pumpAndSettle();
      final Finder field = find.byType(ZsTextField);
      expect(field, paints..something(ringOf(color: c.flBorder, inset: 1)));
      expect(field, isNot(paints..something(ringOf(color: ZsColors.resolve(inactive).accentRing))));
      expect(tester.widget<TextField>(find.byType(TextField)).cursorColor, const Color(0x00000000));
    });

    testWidgets('the selected glyphs are drawn in --selection-text while the field has focus', (tester) async {
      final controller = ZsTextEditingController(text: 'abc');
      addTearDown(controller.dispose);
      await tester.pumpWidget(_field(ZsTextField(controller: controller)));
      controller.selection = const TextSelection(baseOffset: 1, extentOffset: 2);
      final BuildContext context = tester.element(find.byType(TextField));
      final TextSpan span = controller.buildTextSpan(context: context, withComposing: true);
      expect(span.children, hasLength(3));
      expect((span.children![1] as TextSpan).text, 'b');
      expect((span.children![1] as TextSpan).style?.color, c.selectionText);
      expect(controller.buildTextSpan(context: context, withComposing: false).children, isNull);
    });

    testWidgets('disabled with a reason: .4, no focus, the reason as hint', (tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      await tester.pumpWidget(_field(const ZsTextField(disabledReason: 'Working copy is stale', identifier: 'f')));
      await tester.tap(find.byType(ZsTextField), warnIfMissed: false);
      await tester.pump();
      expect(FocusManager.instance.primaryFocus?.debugLabel, isNot('ZsTextField'));
      expect(find.byType(Opacity), findsWidgets);
      expect(tester.getSemantics(find.bySemanticsIdentifier('f')), isSemantics(hint: 'Working copy is stale'));
      handle.dispose();
    });

    testWidgets(
      'the context menu: Undo · Redo — Cut · Copy · Paste — Select all, shortcuts in the column',
      (tester) async {
        final controller = ZsTextEditingController(text: 'feat');
        addTearDown(controller.dispose);
        await tester.pumpWidget(_field(ZsTextField(controller: controller)));
        final TestGesture mouse = await tester.startGesture(
          tester.getCenter(find.byType(TextField)),
          kind: PointerDeviceKind.mouse,
          buttons: kSecondaryMouseButton,
        );
        await mouse.up();
        await tester.pumpAndSettle();
        for (final label in <String>['Undo', 'Redo', 'Cut', 'Copy', 'Paste', 'Select all']) {
          expect(find.text(label), findsOneWidget);
        }
        expect(find.text('⌘A'), findsOneWidget);
        await tester.tap(find.text('Select all'));
        // The activation blink: off, then on, then the command.
        await tester.pump(const Duration(milliseconds: 200));
        await tester.pumpAndSettle();
        expect(controller.selection, const TextSelection(baseOffset: 0, extentOffset: 4));
      },
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    );

    testWidgets(
      'the context menu enables each row by the field: no history, nothing selected, then everything selected',
      (tester) async {
        final SemanticsHandle handle = tester.ensureSemantics();
        final controller = ZsTextEditingController(text: 'feat');
        addTearDown(controller.dispose);
        await tester.pumpWidget(_field(ZsTextField(controller: controller)));
        Future<void> openMenu() async {
          final TestGesture mouse = await tester.startGesture(
            tester.getCenter(find.byType(TextField)),
            kind: PointerDeviceKind.mouse,
            buttons: kSecondaryMouseButton,
          );
          await mouse.up();
          await tester.pumpAndSettle();
        }

        Matcher enabled({required bool on}) => isSemantics(hasEnabledState: true, isEnabled: on);
        await openMenu();
        expect(controller.selection.isCollapsed, isTrue);
        for (final label in <String>['Undo', 'Redo', 'Cut', 'Copy']) {
          expect(tester.getSemantics(find.bySemanticsLabel(label)), enabled(on: false), reason: label);
        }
        expect(tester.getSemantics(find.bySemanticsLabel('Select all')), enabled(on: true));
        await tester.tap(find.text('Select all'));
        await tester.pump(const Duration(milliseconds: 200));
        await tester.pumpAndSettle();
        await openMenu();
        expect(controller.selection, const TextSelection(baseOffset: 0, extentOffset: 4));
        for (final label in <String>['Cut', 'Copy']) {
          expect(tester.getSemantics(find.bySemanticsLabel(label)), enabled(on: true), reason: label);
        }
        expect(tester.getSemantics(find.bySemanticsLabel('Select all')), enabled(on: false));
        handle.dispose();
      },
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    );

    testWidgets('with a field list attached ↓ ↑ Home End ↩ drive the list and the first Esc detaches it', (
      tester,
    ) async {
      final list = ZsFieldListController();
      addTearDown(list.dispose);
      final focus = FocusNode();
      addTearDown(focus.dispose);
      final activated = <int>[];
      list.attach(count: 3, enabled: (i) => i != 1, onActivate: activated.add);
      await tester.pumpWidget(_field(ZsTextField(focusNode: focus, fieldList: list)));
      focus.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      expect(list.active, 0);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      expect(list.active, 2, reason: 'the disabled row is skipped');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      expect(list.active, 0, reason: 'wrapping');
      await tester.sendKeyEvent(LogicalKeyboardKey.end);
      expect(list.active, 2);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(activated, <int>[2]);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      expect(list.attached, isFalse);
      expect(focus.hasFocus, isTrue, reason: 'focus stays in the field');
    });
  });

  group('ZsSearchField', () {
    testWidgets('a quiet --fl-hover fill at rest, --fl-on on hover, the placeholder a rung up on hover', (
      tester,
    ) async {
      await tester.pumpWidget(_field(const ZsSearchField(placeholder: 'Search projects')));
      final Finder field = find.byType(ZsSearchField);
      expect(tester.getSize(field).height, 30);
      expect(field, paints..something(rrectOf(color: c.flHover)));
      expect(tester.widget<Text>(find.text('Search projects')).style?.color, c.textFaint);
      await hover(tester, field);
      await tester.pumpAndSettle();
      expect(field, paints..something(rrectOf(color: c.flOn)));
      expect(tester.widget<Text>(find.text('Search projects')).style?.color, c.textDim);
    });

    testWidgets('a forced states controller adds hover and focus', (tester) async {
      final states = WidgetStatesController(<WidgetState>{WidgetState.hovered});
      addTearDown(states.dispose);
      await tester.pumpWidget(_field(ZsSearchField(statesController: states)));
      final Finder field = find.byType(ZsSearchField);
      await tester.pumpAndSettle();
      expect(field, paints..something(rrectOf(color: c.flOn)));
      states.value = <WidgetState>{WidgetState.focused};
      await tester.pumpAndSettle();
      expect(field, paints..something(ringOf(color: c.accentLine)));
    });

    testWidgets('a forced focus hides the key cap, as real focus does', (tester) async {
      final states = WidgetStatesController(<WidgetState>{WidgetState.focused});
      addTearDown(states.dispose);
      await tester.pumpWidget(_field(ZsSearchField(statesController: states, shortcutLabel: '/')));
      expect(find.byType(ZsKbd), findsNothing);
    });

    testWidgets('the key cap shows while empty and unfocused; the ✕ replaces it with a query', (tester) async {
      final controller = ZsTextEditingController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(_field(ZsSearchField(controller: controller, shortcutLabel: '/')));
      expect(find.byType(ZsKbd), findsOneWidget);
      await tester.tap(find.byType(TextField));
      await tester.pump();
      expect(find.byType(ZsKbd), findsNothing);
      await tester.enterText(find.byType(TextField), 'zan');
      await tester.pump();
      expect(find.bySemanticsLabel('Clear'), findsOneWidget);
      await tester.tap(find.bySemanticsLabel('Clear'));
      await tester.pump();
      expect(controller.text, isEmpty);
    });

    testWidgets('Esc clears; Esc on an empty field leaves it', (tester) async {
      final controller = ZsTextEditingController(text: 'zan');
      addTearDown(controller.dispose);
      final focus = FocusNode();
      addTearDown(focus.dispose);
      await tester.pumpWidget(_field(ZsSearchField(controller: controller, focusNode: focus)));
      focus.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      expect(controller.text, isEmpty);
      expect(focus.hasFocus, isTrue);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(focus.hasFocus, isFalse);
    });

    testWidgets('increased contrast edges it with --border-strong; inactive: no edge, no halo, no caret', (
      tester,
    ) async {
      const contrast = ZsAppearance(increasedContrast: true);
      await tester.pumpWidget(_field(const ZsSearchField(), appearance: contrast));
      expect(
        find.byType(ZsSearchField),
        paints..something(ringOf(color: ZsColors.resolve(contrast).borderStrong, inset: 1)),
      );
      final focus = FocusNode();
      addTearDown(focus.dispose);
      await tester.pumpWidget(_field(ZsSearchField(focusNode: focus), appearance: const ZsAppearance(inactive: true)));
      focus.requestFocus();
      await tester.pumpAndSettle();
      expect(find.byType(ZsSearchField), isNot(paints..something(ringOf(color: c.accentLine))));
      expect(tester.widget<TextField>(find.byType(TextField)).cursorColor, const Color(0x00000000));
    });
  });
}
