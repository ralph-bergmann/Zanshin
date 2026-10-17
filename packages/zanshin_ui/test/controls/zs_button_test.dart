// SPDX-License-Identifier: MIT

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin_ui/src/controls/zs_badge.dart';
import 'package:zanshin_ui/src/controls/zs_button.dart';
import 'package:zanshin_ui/src/controls/zs_spinner.dart';
import 'package:zanshin_ui/src/controls/zs_tooltip.dart';
import 'package:zanshin_ui/src/design/zs_appearance.dart';
import 'package:zanshin_ui/src/design/zs_colors.dart';
import 'package:zanshin_ui/src/icons/zanshin_icon.dart';
import 'package:zanshin_ui/src/materials/zs_surface.dart';

import '../helpers/controls.dart';
import '../helpers/icon_registry.dart';
import '../helpers/zs_host.dart';

WidgetStatesController _forced(Set<WidgetState> states) {
  final controller = WidgetStatesController(states);
  addTearDown(controller.dispose);
  return controller;
}

Widget _button({
  ZsButtonVariant variant = ZsButtonVariant.quiet,
  Set<WidgetState> states = const <WidgetState>{},
  ZsAppearance appearance = const ZsAppearance(),
  ZsButtonSize size = ZsButtonSize.sm,
  bool busy = false,
}) => zsHost(
  ZsButton(
    label: 'Describe…',
    icon: ZI.describe,
    variant: variant,
    size: size,
    busy: busy,
    onPressed: () {},
    statesController: _forced(states),
  ),
  appearance: appearance,
  icons: true,
  overlay: true,
);

void main() {
  setUpIconRegistry();
  useMacFocus();
  const ZsColors night = ZsColors.night;
  const ZsColors paper = ZsColors.paper;

  testWidgets('quiet: rest --fl-hover, hover --fl-on, pressed --fl-press; the label turns --text', (tester) async {
    for (final (Set<WidgetState> states, Color fill, Color text) in <(Set<WidgetState>, Color, Color)>[
      (<WidgetState>{}, night.flHover, night.textMuted),
      (<WidgetState>{WidgetState.hovered}, night.flOn, night.text),
      (<WidgetState>{WidgetState.pressed}, night.flPress, night.text),
    ]) {
      await tester.pumpWidget(_button(states: states));
      await tester.pumpAndSettle();
      expect(find.byType(ZsButton), paints..something(rrectOf(color: fill)));
      expect(tester.widget<Text>(find.text('Describe…')).style?.color, text);
    }
  });

  testWidgets('ghost and danger stay quiet until hover; danger tints red, never a solid fill', (tester) async {
    await tester.pumpWidget(_button(variant: ZsButtonVariant.ghost));
    expect(tester.widget<Text>(find.text('Describe…')).style?.color, night.textDim);
    await tester.pumpWidget(_button(variant: ZsButtonVariant.danger, states: <WidgetState>{WidgetState.hovered}));
    await tester.pumpAndSettle();
    expect(find.byType(ZsButton), paints..something(rrectOf(color: night.dangerHover)));
    expect(tester.widget<Text>(find.text('Describe…')).style?.color, night.rem);
  });

  testWidgets('the gold primary steps fill and inset ring together, in paper too', (tester) async {
    await tester.pumpWidget(
      _button(
        variant: ZsButtonVariant.primary,
        appearance: const ZsAppearance(theme: ZsTheme.paper),
      ),
    );
    expect(find.byType(ZsButton), paints..something(ringOf(color: paper.primaryRing, inset: 1)));
    await tester.pumpWidget(
      _button(
        variant: ZsButtonVariant.primary,
        states: <WidgetState>{WidgetState.hovered},
        appearance: const ZsAppearance(theme: ZsTheme.paper),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(ZsButton), paints..something(ringOf(color: paper.primaryRingHover, inset: 1)));
    expect(tester.widget<ZanshinIcon>(find.byType(ZanshinIcon)).color, paper.primaryIcon);
  });

  testWidgets('destructive is the primary build in red with a --rem icon', (tester) async {
    await tester.pumpWidget(_button(variant: ZsButtonVariant.destructive));
    expect(find.byType(ZsButton), paints..something(ringOf(color: night.destructiveRing, inset: 1)));
    expect(tester.widget<ZanshinIcon>(find.byType(ZanshinIcon)).color, night.rem);
  });

  testWidgets('the gold stays in an inactive window', (tester) async {
    await tester.pumpWidget(_button(variant: ZsButtonVariant.primary, appearance: const ZsAppearance(inactive: true)));
    expect(find.byType(ZsButton), paints..something(ringOf(color: night.primaryRing, inset: 1)));
  });

  testWidgets('increased contrast adds a --border-strong edge to every variant but the gold and the red', (
    tester,
  ) async {
    const contrast = ZsAppearance(increasedContrast: true);
    final c = ZsColors.resolve(contrast);
    await tester.pumpWidget(_button(appearance: contrast));
    expect(find.byType(ZsButton), paints..something(ringOf(color: c.borderStrong, inset: 1)));
    await tester.pumpWidget(_button(variant: ZsButtonVariant.primary, appearance: contrast));
    await tester.pumpAndSettle();
    expect(find.byType(ZsButton), isNot(paints..something(ringOf(color: c.borderStrong, inset: 1))));
  });

  testWidgets('lg is 44 high on --radius-island; the large primary lays the gold over the island glass', (
    tester,
  ) async {
    await tester.pumpWidget(_button(variant: ZsButtonVariant.primary, size: ZsButtonSize.lg));
    expect(tester.getSize(find.byType(ZsButton)).height, 44);
    expect(find.byType(ZsSurface), findsOneWidget);
  });

  testWidgets('busy: a spinner in the icon slot, the label and width hold, the progress cursor', (tester) async {
    await tester.pumpWidget(_button());
    final Size idle = tester.getSize(find.byType(ZsButton));
    await tester.pumpWidget(_button(busy: true));
    expect(find.byType(ZsSpinner), findsOneWidget);
    expect(find.byType(ZanshinIcon), findsNothing);
    expect(find.text('Describe…'), findsOneWidget);
    expect(tester.getSize(find.byType(ZsButton)), idle);
    await hover(tester, find.byType(ZsButton));
    expect(activeCursor(), SystemMouseCursors.progress);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the arrow over every button', (tester) async {
    await tester.pumpWidget(_button(variant: ZsButtonVariant.primary, size: ZsButtonSize.lg));
    await hover(tester, find.byType(ZsButton));
    expect(activeCursor(), SystemMouseCursors.basic);
  });

  testWidgets('icon-only: square, named and tooltipped by its label', (tester) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    await tester.pumpWidget(
      zsHost(
        ZsButton(label: 'Copy command', icon: ZI.copy, iconOnly: true, onPressed: () {}, identifier: 'copy'),
        icons: true,
        overlay: true,
      ),
    );
    expect(tester.getSize(find.byType(ZsButton)), const Size(30, 30));
    expect(find.byType(ZsTooltip), findsOneWidget);
    expect(
      tester.getSemantics(find.bySemanticsIdentifier('copy')),
      matchesSemantics(
        identifier: 'copy',
        label: 'Copy command',
        isButton: true,
        hasEnabledState: true,
        isEnabled: true,
        isFocusable: true,
        hasTapAction: true,
        hasFocusAction: true,
      ),
    );
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    handle.dispose();
  });

  group('ZsIconButton', () {
    Widget iconButton({
      bool active = false,
      Set<WidgetState> states = const <WidgetState>{},
      ZsIconButtonSize size = ZsIconButtonSize.md,
      Object? badge,
      ZsAppearance appearance = const ZsAppearance(),
    }) => zsHost(
      ZsIconButton(
        icon: ZI.fetch,
        label: 'Fetch',
        size: size,
        active: active,
        badge: badge,
        onPressed: () {},
        statesController: _forced(states),
        identifier: 'fetch',
      ),
      appearance: appearance,
      icons: true,
      overlay: true,
    );

    testWidgets('sizes 30 · 36 · 40', (tester) async {
      for (final (ZsIconButtonSize size, double side) in <(ZsIconButtonSize, double)>[
        (ZsIconButtonSize.sm, 30),
        (ZsIconButtonSize.md, 36),
        (ZsIconButtonSize.lg, 40),
      ]) {
        await tester.pumpWidget(iconButton(size: size));
        expect(tester.getSize(find.byType(ZsIconButton)), Size.square(side));
      }
    });

    testWidgets('hover --fl-hover; on --fl-on → hover --fl-on-hover → pressed --fl-press', (tester) async {
      for (final (bool active, Set<WidgetState> states, Color fill) in <(bool, Set<WidgetState>, Color)>[
        (false, <WidgetState>{WidgetState.hovered}, night.flHover),
        (true, <WidgetState>{}, night.flOn),
        (true, <WidgetState>{WidgetState.hovered}, night.flOnHover),
        (true, <WidgetState>{WidgetState.pressed}, night.flPress),
      ]) {
        await tester.pumpWidget(iconButton(active: active, states: states));
        await tester.pumpAndSettle();
        expect(find.byType(ZsIconButton), paints..something(rrectOf(color: fill, size: const Size.square(36))));
      }
    });

    testWidgets('an active button gets a --border-strong edge under increased contrast', (tester) async {
      const contrast = ZsAppearance(increasedContrast: true);
      await tester.pumpWidget(iconButton(active: true, appearance: contrast));
      expect(
        find.byType(ZsIconButton),
        paints..something(ringOf(color: ZsColors.resolve(contrast).borderStrong, inset: 1)),
      );
    });

    testWidgets('the badge joins the name; the button is toggled while active', (tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      await tester.pumpWidget(iconButton(badge: 3, active: true));
      await tester.pumpAndSettle();
      expect(find.byType(ZsBadge), findsOneWidget);
      expect(
        tester.getSemantics(find.bySemanticsIdentifier('fetch')),
        isSemantics(label: 'Fetch, 3', isButton: true, hasToggledState: true, isToggled: true),
      );
      handle.dispose();
    });

    testWidgets('a dot badge adds nothing to the name', (tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      await tester.pumpWidget(iconButton(badge: true));
      await tester.pumpAndSettle();
      expect(find.byType(ZsBadge), findsOneWidget);
      expect(tester.getSemantics(find.bySemanticsIdentifier('fetch')), isSemantics(label: 'Fetch', isButton: true));
      handle.dispose();
    });
  });
}
