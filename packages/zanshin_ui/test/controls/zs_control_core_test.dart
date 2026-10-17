// SPDX-License-Identifier: MIT

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin_ui/src/controls/zs_button.dart';
import 'package:zanshin_ui/src/controls/zs_checkbox.dart';
import 'package:zanshin_ui/src/controls/zs_chip.dart';
import 'package:zanshin_ui/src/controls/zs_control_core.dart';
import 'package:zanshin_ui/src/controls/zs_disclosure.dart';
import 'package:zanshin_ui/src/controls/zs_focus_ring.dart';
import 'package:zanshin_ui/src/controls/zs_link.dart';
import 'package:zanshin_ui/src/controls/zs_popover.dart';
import 'package:zanshin_ui/src/controls/zs_radio.dart';
import 'package:zanshin_ui/src/controls/zs_segmented.dart';
import 'package:zanshin_ui/src/controls/zs_select.dart';
import 'package:zanshin_ui/src/controls/zs_slider.dart';
import 'package:zanshin_ui/src/controls/zs_switch.dart';
import 'package:zanshin_ui/src/controls/zs_text_field.dart';
import 'package:zanshin_ui/src/controls/zs_tooltip.dart';
import 'package:zanshin_ui/src/design/zs_appearance.dart';
import 'package:zanshin_ui/src/design/zs_metrics.dart';
import 'package:zanshin_ui/src/design/zs_motion.dart';
import 'package:zanshin_ui/src/icons/zanshin_icon.dart';

import '../helpers/controls.dart';
import '../helpers/icon_registry.dart';
import '../helpers/zs_host.dart';

/// A 60 × 30 control on the core that records its last status.
class _Probe extends StatelessWidget {
  const _Probe({
    required this.onStatus,
    this.onActivate,
    this.disabledReason,
    this.busy = false,
    this.enabled = true,
    this.statesController,
    this.focusNode,
  });

  final ValueChanged<ZsControlStatus> onStatus;
  final VoidCallback? onActivate;
  final String? disabledReason;
  final bool busy;
  final bool enabled;
  final WidgetStatesController? statesController;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) => ZsControlCore(
    identifier: 'probe',
    onActivate: onActivate,
    enabled: enabled,
    disabledReason: disabledReason,
    busy: busy,
    statesController: statesController,
    focusNode: focusNode,
    semantics: const SemanticsProperties(button: true, label: 'Probe'),
    ring: ZsRingPlacement.outside,
    ringRadius: 9,
    builder: (context, status) {
      onStatus(status);
      return const SizedBox(width: 60, height: 30);
    },
  );
}

/// A focusable neighbour, so Tab has somewhere to go.
Widget _other(FocusNode node) => Focus(focusNode: node, child: const SizedBox(width: 20, height: 20));

void main() {
  useMacFocus();

  late ZsControlStatus status;
  void record(ZsControlStatus value) => status = value;

  testWidgets('a click acts, takes no focus and shows no ring', (tester) async {
    var activated = 0;
    final node = FocusNode();
    addTearDown(node.dispose);
    await tester.pumpWidget(zsHost(_Probe(onStatus: record, onActivate: () => activated++, focusNode: node)));
    await tester.tap(find.byType(_Probe));
    await tester.pump();
    expect(activated, 1);
    expect(node.hasFocus, isFalse);
    expect(status.focusVisible, isFalse);
  });

  testWidgets('pressed is set on pointer down and cleared on up', (tester) async {
    await tester.pumpWidget(zsHost(_Probe(onStatus: record, onActivate: () {})));
    final TestGesture gesture = await tester.startGesture(tester.getCenter(find.byType(_Probe)));
    await tester.pump();
    expect(status.pressed, isTrue);
    await gesture.up();
    await tester.pump();
    expect(status.pressed, isFalse);
  });

  testWidgets('Tab focuses it with a visible ring that fades in on --dur-focus while it settles', (tester) async {
    final before = FocusNode();
    addTearDown(before.dispose);
    await tester.pumpWidget(
      zsHost(
        Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            _other(before),
            _Probe(onStatus: record, onActivate: () {}),
          ],
        ),
      ),
    );
    before.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(status.focusVisible, isTrue);
    const ZsMetrics metrics = ZsMetrics.standard;
    final box = RRect.fromRectAndRadius(Offset.zero & const Size(60, 30), const Radius.circular(9));
    // Halfway through the fade the ring is part-way transparent and still settling outward.
    await tester.pump(ZsMotion.full.durFocus ~/ 2);
    final double t = ZsMotion.full.easeState.transform(.5);
    final double at = metrics.focusOffset + metrics.focusSettle * (1 - t);
    expect(
      find.byType(ZsFocusRing),
      paints..drrect(outer: box.inflate(at + metrics.focusW), inner: box.inflate(at)),
    );
    await tester.pump(ZsMotion.full.durFocus);
    expect(
      find.byType(ZsFocusRing),
      paints..drrect(
        outer: box.inflate(metrics.focusOffset + metrics.focusW),
        inner: box.inflate(metrics.focusOffset),
      ),
    );
  });

  testWidgets('↩ and Space activate and show the press while held', (tester) async {
    var activated = 0;
    final node = FocusNode();
    addTearDown(node.dispose);
    await tester.pumpWidget(zsHost(_Probe(onStatus: record, onActivate: () => activated++, focusNode: node)));
    node.requestFocus();
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(activated, 1);
    expect(status.pressed, isTrue);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(status.pressed, isFalse);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(activated, 2);
  });

  testWidgets('a key press whose activation moves focus away ends with the focus', (tester) async {
    final node = FocusNode();
    final elsewhere = FocusNode();
    addTearDown(node.dispose);
    addTearDown(elsewhere.dispose);
    await tester.pumpWidget(
      zsHost(
        Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            _Probe(onStatus: record, onActivate: elsewhere.requestFocus, focusNode: node),
            Focus(focusNode: elsewhere, child: const SizedBox.square(dimension: 10)),
          ],
        ),
      ),
    );
    node.requestFocus();
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(elsewhere.hasPrimaryFocus, isTrue);
    expect(status.pressed, isFalse, reason: 'the key-up goes to the node that took focus');
    await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
    node.requestFocus();
    await tester.pump();
    await tester.tap(find.byType(_Probe));
    await tester.pump();
    expect(status.pressed, isFalse, reason: 'a click after it ends with its pointer up');
  });

  testWidgets('hover shows, but not in an inactive window', (tester) async {
    await tester.pumpWidget(zsHost(_Probe(onStatus: record, onActivate: () {})));
    await hover(tester, find.byType(_Probe));
    expect(status.hovered, isTrue);
    await tester.pumpWidget(
      zsHost(
        _Probe(onStatus: record, onActivate: () {}),
        appearance: const ZsAppearance(inactive: true),
      ),
    );
    expect(status.hovered, isFalse);
    expect(status.inactive, isTrue);
  });

  testWidgets('disabled with a reason: no Tab stop, no keys, no click, the reason in a tooltip and the hint', (
    tester,
  ) async {
    var activated = 0;
    final before = FocusNode();
    final after = FocusNode();
    addTearDown(before.dispose);
    addTearDown(after.dispose);
    final SemanticsHandle handle = tester.ensureSemantics();
    await tester.pumpWidget(
      zsHost(
        Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            _other(before),
            _Probe(onStatus: record, onActivate: () => activated++, disabledReason: 'Working copy is stale'),
            _other(after),
          ],
        ),
        overlay: true,
      ),
    );
    before.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(after.hasPrimaryFocus, isTrue, reason: 'the disabled control is skipped');
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.tap(find.byType(_Probe), warnIfMissed: false);
    expect(activated, 0);
    expect(status.disabled, isTrue);
    expect(
      tester.getSemantics(find.bySemanticsIdentifier('probe')),
      matchesSemantics(
        identifier: 'probe',
        label: 'Probe',
        hint: 'Working copy is stale',
        isButton: true,
        hasEnabledState: true,
      ),
    );
    await hover(tester, find.byType(_Probe));
    await tester.pump(ZsMotion.full.delayTooltip);
    await tester.pump(ZsMotion.full.durHover);
    expect(find.text('Working copy is stale'), findsOneWidget);
    expect(find.byType(ZsTooltip), findsOneWidget);
    handle.dispose();
  });

  testWidgets('a disabled control lies at --disabled-opacity', (tester) async {
    await tester.pumpWidget(zsHost(_Probe(onStatus: record, enabled: false)));
    expect(tester.widget<Opacity>(find.byType(Opacity)).opacity, ZsMetrics.standard.disabledOpacity);
  });

  testWidgets('busy: presses are ignored, the cursor is progress and the value reads busy', (tester) async {
    var activated = 0;
    final SemanticsHandle handle = tester.ensureSemantics();
    await tester.pumpWidget(zsHost(_Probe(onStatus: record, onActivate: () => activated++, busy: true)));
    await tester.tap(find.byType(_Probe));
    expect(activated, 0);
    await hover(tester, find.byType(_Probe));
    expect(activeCursor(), SystemMouseCursors.progress);
    expect(status.hovered, isFalse);
    expect(tester.getSemantics(find.bySemanticsIdentifier('probe')), isSemantics(value: 'busy'));
    handle.dispose();
  });

  testWidgets('a forced states controller wins until a real event changes that state', (tester) async {
    final states = WidgetStatesController(<WidgetState>{WidgetState.hovered, WidgetState.focused});
    addTearDown(states.dispose);
    await tester.pumpWidget(zsHost(_Probe(onStatus: record, onActivate: () {}, statesController: states)));
    expect(status.hovered, isTrue);
    expect(status.focusVisible, isTrue, reason: 'a forced focused counts as focus-visible');
    states.update(WidgetState.pressed, true);
    await tester.pump();
    expect(status.pressed, isTrue);
  });

  testWidgets('the cursor is the arrow', (tester) async {
    await tester.pumpWidget(zsHost(_Probe(onStatus: record, onActivate: () {})));
    await hover(tester, find.byType(_Probe));
    expect(activeCursor(), SystemMouseCursors.basic);
  });

  group('every interactive control', () {
    setUpIconRegistry();

    testWidgets('is labelled for its tap target (labeledTapTargetGuideline)', (tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      await tester.pumpWidget(
        zsHost(
          SizedBox(
            width: 420,
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                ZsButton(label: 'Commit', onPressed: () {}),
                ZsIconButton(icon: ZI.fetch, label: 'Fetch', onPressed: () {}),
                ZsSwitch(value: true, onChanged: (_) {}, label: 'Show elided'),
                ZsCheckbox(value: false, onChanged: (_) {}, label: 'Viewed'),
                ZsRadioGroup<String>(
                  label: 'Strategy',
                  value: 'merge',
                  onChanged: (_) {},
                  options: const <ZsRadioOption<String>>[
                    ZsRadioOption<String>(value: 'merge', label: 'Merge'),
                    ZsRadioOption<String>(value: 'rebase', label: 'Rebase'),
                  ],
                ),
                ZsSegmented<String>(
                  label: 'Density',
                  value: 'free',
                  onChanged: (_) {},
                  segments: const <ZsSegment<String>>[
                    ZsSegment<String>(value: 'free', label: 'Free'),
                    ZsSegment<String>(value: 'compact', label: 'Compact'),
                  ],
                ),
                ZsSlider(value: 40, onChanged: (_) {}, label: 'Card width'),
                ZsSelect<String>(
                  label: 'Fetch from',
                  value: 'origin',
                  onChanged: (_) {},
                  options: const <ZsSelectEntry<String>>[ZsSelectOption<String>(value: 'origin', label: 'origin')],
                ),
                ZsChip(label: 'Aa', onChanged: (_) {}),
                ZsLink(label: 'Open log', onPressed: () {}),
                const SizedBox(width: 160, child: ZsTextField(label: 'Summary')),
                const SizedBox(width: 160, child: ZsSearchField()),
                const SizedBox(
                  width: 160,
                  child: ZsDisclosure(label: 'Conflicts', child: SizedBox(height: 20)),
                ),
                SizedBox(
                  width: 160,
                  child: ZsOptionLink(label: 'More', onPressed: () {}),
                ),
              ],
            ),
          ),
          overlay: true,
          icons: true,
        ),
      );
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      handle.dispose();
    });
  });
}
