// SPDX-License-Identifier: MIT

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/src/features/shell/floating_shell.dart';
import 'package:zanshin/src/features/shell/shell_controller.dart';
import 'package:zanshin/src/features/shell/shell_toast.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

import '../../helpers/icon_registry.dart';
import '../../helpers/shell_host.dart';

const _pill = Key('pill');
const _graphButton = Key('graph-button');

/// A toast entry saying [text], with an Undo button counting its presses in [undos].
ShellToastEntry _entry(String text, {ZsToastTone tone = ZsToastTone.success, List<String>? undos}) => ShellToastEntry(
  tone: tone,
  build: (context, dismiss) => ZsToast(
    tone: tone,
    message: TextSpan(text: text),
    actions: <ZsToastAction>[
      ZsToastAction(label: 'Undo', tooltip: 'jj undo', identifier: 'undo', onPressed: () => undos?.add(text)),
    ],
    onDismiss: dismiss,
  ),
);

final Finder _toastGlass = find.descendant(of: find.byType(ZsToast), matching: find.byType(ZsGlass));

Finder _control(String identifier) =>
    find.byWidgetPredicate((widget) => widget is ZsControlCore && widget.identifier == identifier);

/// Whether the primary focus lies inside the control [identifier].
bool _focused(String identifier) {
  final BuildContext? context = FocusManager.instance.primaryFocus?.context;
  return context != null &&
      find
          .ancestor(of: find.byElementPredicate((element) => element == context), matching: _control(identifier))
          .evaluate()
          .isNotEmpty;
}

void main() {
  setUpIconRegistry();

  late ShellToasts toasts;
  late ShellController controller;
  setUp(() {
    toasts = ShellToasts();
    controller = ShellController();
  });
  tearDown(() {
    toasts.dispose();
    controller.dispose();
  });

  /// The project window's wiring: the shell with an @ pill, its toast slot the view while [ShellToasts.occupied].
  Future<void> pumpShell(WidgetTester tester, {bool reduceMotion = false}) async {
    useShellWindow(tester);
    await tester.pumpWidget(
      shellHost(
        Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
            child: ListenableBuilder(
              listenable: toasts,
              builder: (context, _) => FloatingShell(
                controller: controller,
                graph: const Center(
                  child: Focus(key: _graphButton, autofocus: true, child: SizedBox.square(dimension: 40)),
                ),
                atPill: const SizedBox(key: _pill, width: 80, height: 36),
                toast: toasts.occupied ? ShellToastView(toasts: toasts) : null,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> ms(WidgetTester tester, int ms) => tester.pump(Duration(milliseconds: ms));

  testWidgets('a success hides after 6.5 s, then its exit plays and the @ pill returns', (tester) async {
    await pumpShell(tester);
    expect(find.byKey(_pill), findsOneWidget);
    toasts.show(_entry('Abandoned a'));
    await tester.pump();
    expect(find.text('Abandoned a'), findsOneWidget);
    expect(find.byKey(_pill), findsNothing, reason: 'the pill yields the slot');

    await ms(tester, 6400);
    expect(toasts.current, isNotNull);
    await ms(tester, 200);
    expect(toasts.current, isNull);
    expect(toasts.occupied, isTrue, reason: 'the exit still plays');
    expect(find.text('Abandoned a'), findsOneWidget);

    await ms(tester, 200);
    expect(toasts.occupied, isFalse);
    expect(find.text('Abandoned a'), findsNothing);
    expect(find.byKey(_pill), findsOneWidget);
  });

  testWidgets('hovering pauses the hold; leaving resumes it', (tester) async {
    await pumpShell(tester);
    toasts.show(_entry('Abandoned a'));
    await tester.pump();
    await ms(tester, 300);
    final TestGesture mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: tester.getCenter(find.text('Abandoned a')));
    await tester.pump();

    await ms(tester, 10000);
    expect(toasts.current, isNotNull);

    await mouse.moveTo(Offset.zero);
    await tester.pump();
    await ms(tester, 6300);
    expect(toasts.current, isNull);
  });

  testWidgets('an error stays until ×; × hides at once', (tester) async {
    await pumpShell(tester);
    toasts.show(_entry('Updating failed', tone: ZsToastTone.error));
    await tester.pump();
    await ms(tester, 20000);
    expect(toasts.current, isNotNull);

    await tester.tap(find.bySemanticsLabel('Dismiss'));
    await tester.pump();
    expect(toasts.current, isNull);
    await ms(tester, 200);
    expect(toasts.occupied, isFalse);
  });

  testWidgets('a second toast replaces the first: the old fades in place, the new enters, the hold restarts', (
    tester,
  ) async {
    await pumpShell(tester);
    toasts.show(_entry('Abandoned a'));
    await tester.pump();
    await ms(tester, 4000);
    toasts.show(_entry('Abandoned b'));
    await tester.pump();
    await ms(tester, 60);
    expect(find.text('Abandoned a'), findsOneWidget, reason: 'fading in place');
    expect(find.text('Abandoned b'), findsOneWidget);
    expect(tester.getCenter(find.text('Abandoned a')).dy, isNot(tester.getCenter(find.text('Abandoned b')).dy));

    await ms(tester, 100);
    expect(find.text('Abandoned a'), findsNothing);
    await ms(tester, 6000);
    expect(toasts.current, isNotNull, reason: 'the hold restarted with the new toast');
  });

  testWidgets('it enters with a 10 px rise; under reduce motion it only fades', (tester) async {
    await pumpShell(tester);
    toasts.show(_entry('Abandoned a'));
    await tester.pump();
    final double settled = await () async {
      await ms(tester, 1000);
      return tester.getCenter(find.text('Abandoned a')).dy;
    }();
    toasts.dismiss();
    // The first frame starts the exit's ticker.
    await tester.pump();
    await ms(tester, 400);
    expect(toasts.occupied, isFalse);

    toasts.show(_entry('Abandoned b'));
    await tester.pump();
    await ms(tester, 20);
    expect(tester.getCenter(find.text('Abandoned b')).dy, greaterThan(settled + 5));

    await pumpShell(tester, reduceMotion: true);
    toasts.dismiss();
    await tester.pump();
    await ms(tester, 400);
    expect(toasts.occupied, isFalse);
    toasts.show(_entry('Abandoned c'));
    await tester.pump();
    await ms(tester, 20);
    expect(tester.getCenter(find.text('Abandoned c')).dy, settled);
    expect(ZsFade.of(tester.element(_toastGlass)), lessThan(1), reason: 'it still fades');
  });

  testWidgets('the glass fades through ZsFade, never an Opacity above it', (tester) async {
    await pumpShell(tester);
    toasts.show(_entry('Abandoned a'));
    await tester.pump();
    await ms(tester, 20);
    expect(find.ancestor(of: _toastGlass, matching: find.byType(ZsFade)), findsWidgets);
    expect(find.ancestor(of: _toastGlass, matching: find.byType(Opacity)), findsNothing);
    expect(find.ancestor(of: _toastGlass, matching: find.byType(FadeTransition)), findsNothing);
  });

  testWidgets('its buttons are no Tab stops; F6 moves focus to Undo, then Tab reaches ×', (tester) async {
    final undos = <String>[];
    await pumpShell(tester);
    toasts.show(_entry('Abandoned a', undos: undos));
    await tester.pump();
    await ms(tester, 300);
    final FocusNode graph = Focus.of(
      tester.element(find.descendant(of: find.byKey(_graphButton), matching: find.byType(SizedBox))),
    )..requestFocus();
    await tester.pump();
    expect(graph.hasPrimaryFocus, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(_focused('undo'), isFalse);
    expect(_focused('toast-dismiss'), isFalse);

    graph.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.f6);
    await tester.pump();
    expect(_focused('undo'), isTrue);

    await ms(tester, 10000);
    expect(toasts.current, isNotNull, reason: 'focus inside holds it');

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(_focused('toast-dismiss'), isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(toasts.current, isNull);
    expect(undos, isEmpty);
    await ms(tester, 200);
    await ms(tester, 200);
    expect(toasts.occupied, isFalse);
    expect(graph.hasPrimaryFocus, isTrue, reason: 'focus returns to where F6 took it from');
  });

  testWidgets('a toast replaced under the pointer does not leave the new one paused', (tester) async {
    await pumpShell(tester);
    toasts.show(_entry('Abandoned a long list of changes, one after another'));
    await tester.pump();
    await ms(tester, 300);
    final TestGesture mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    // Over the long toast's text near its start, where the short one does not reach.
    final Offset pointer = tester.getTopLeft(find.textContaining('Abandoned a long')) + const Offset(4, 6);
    await mouse.addPointer(location: pointer);
    await tester.pump();

    toasts.show(_entry('Moved b'));
    await tester.pump();
    await ms(tester, 300);
    expect(tester.getRect(find.byType(ZsToast).last).contains(pointer), isFalse, reason: 'the pointer is off B');
    await ms(tester, 6400);
    expect(toasts.current, isNull);
  });

  test('dismiss of an entry that is no longer current does nothing; exited ends the slot', () {
    final ShellToastEntry a = _entry('a');
    final ShellToastEntry b = _entry('b');
    toasts
      ..show(a)
      ..show(b)
      ..dismiss(a);
    expect(toasts.current, b);
    toasts.dismiss(b);
    expect(toasts.occupied, isTrue);
    toasts.exited();
    expect(toasts.occupied, isFalse);
  });
}
