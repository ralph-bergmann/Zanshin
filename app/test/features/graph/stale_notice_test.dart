// SPDX-License-Identifier: MIT

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/src/features/graph/stale_notice.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

import '../../helpers/icon_registry.dart';
import '../../helpers/shell_host.dart';

const _message = 'The working copy is stale (not updated since operation aaaaaaaaaaaa).';

Future<void> _pump(WidgetTester tester, StaleNotice notice) async {
  useShellWindow(tester);
  await tester.pumpWidget(shellHost(Align(alignment: Alignment.topCenter, child: notice)));
}

void main() {
  setUpIconRegistry();

  testWidgets('with the action: the sentence, the command, "Update working copy" with update-stale in its tooltip', (
    tester,
  ) async {
    var updates = 0;
    await _pump(
      tester,
      StaleNotice(command: 'jj op integrate aaaaaaaaaaaa', message: _message, onUpdate: () => updates++),
    );
    expect(find.text('Working copy is stale'), findsOneWidget);
    expect(find.text('·'), findsOneWidget);
    expect(find.text('jj op integrate aaaaaaaaaaaa'), findsOneWidget);
    expect(find.byWidgetPredicate((w) => w is ZsTooltip && w.message == _message), findsOneWidget);
    expect(find.byWidgetPredicate((w) => w is ZsTooltip && w.message == 'jj workspace update-stale'), findsOneWidget);
    expect(tester.getSize(find.byType(ZsGlass)).height, 44);
    await tester.tap(find.text('Update working copy'));
    expect(updates, 1);
  });

  testWidgets('busy: the button shows busy and ignores presses', (tester) async {
    var updates = 0;
    await _pump(
      tester,
      StaleNotice(command: StaleNotice.updateCommand, message: _message, onUpdate: () => updates++, busy: true),
    );
    expect(tester.widget<ZsButton>(find.byType(ZsButton)).busy, isTrue);
    await tester.tap(find.text('Update working copy'));
    expect(updates, 0);
  });

  testWidgets('without the action: an icon-only Copy writes the command to the clipboard', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map<Object?, Object?>)['text'] as String?;
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await _pump(tester, const StaleNotice(command: StaleNotice.updateCommand));
    expect(find.text('Update working copy'), findsNothing);
    final ZsButton copy = tester.widget<ZsButton>(find.byType(ZsButton));
    expect(copy.iconOnly, isTrue);
    expect(copy.label, 'Copy — jj workspace update-stale');
    await tester.tap(find.byType(ZsButton));
    await tester.pump();
    expect(copied, 'jj workspace update-stale');
  });

  testWidgets("a live region labelled with the sentence, the command and jj's message; the button a focusable", (
    tester,
  ) async {
    final SemanticsHandle semantics = tester.ensureSemantics();
    await _pump(tester, StaleNotice(command: StaleNotice.updateCommand, message: _message, onUpdate: () {}));
    expect(
      tester.getSemantics(find.byType(StaleNotice)),
      isSemantics(isLiveRegion: true, label: 'Working copy is stale · jj workspace update-stale. $_message'),
    );
    expect(find.bySemanticsLabel('Update working copy'), findsOneWidget);
    expect(
      tester.getSemantics(find.bySemanticsLabel('Update working copy')),
      isSemantics(isFocusable: true, isButton: true),
    );
    semantics.dispose();
  });
}
