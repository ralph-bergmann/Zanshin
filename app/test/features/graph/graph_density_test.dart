// SPDX-License-Identifier: MIT

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/src/features/graph/graph_canvas.dart';
import 'package:zanshin/src/features/graph/graph_card.dart';
import 'package:zanshin/src/features/graph/graph_viewport.dart';
import 'package:zanshin/src/features/graph/recorded_graph_layout.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

import '../../../widgetbook/graph/fake_content.dart';
import '../../../widgetbook/graph/graph_recordings.g.dart';
import '../../helpers/icon_registry.dart';
import '../../helpers/shell_host.dart';

Finder _cardOf(int node) => find.byWidgetPredicate((w) => w is GraphCard && w.node == node, skipOffstage: false);

void main() {
  setUpIconRegistry();

  testWidgets('the cards and the gaps between rows follow the density, live (Story 11.20)', (tester) async {
    useShellWindow(tester, const Size(4000, 2800));
    final (String input, String output) = graphRecordings['design-default compact compact']!;
    final layout = RecordedGraphLayout.fromSpec(input, output, content: fakeContent);
    final cards = GraphCardController(now: 0);
    addTearDown(cards.dispose);
    // The newest row (k = 0) and one some rows down; k = the rows between them in units.
    int k(int node) => (layout.rows - layout.unit - layout.rowOf(node)) ~/ layout.unit;
    final int top = List<int>.generate(layout.nodeCount, (n) => n).firstWhere((n) => k(n) == 0);
    final int lower = List<int>.generate(layout.nodeCount, (n) => n).firstWhere((n) => k(n) == 2);

    Future<(double, double)> measure(ZsDensity density) async {
      await tester.pumpWidget(
        shellHost(
          GraphCanvas(layout: layout, cards: cards),
          appearance: ZsAppearance(density: density),
        ),
      );
      await tester.pump();
      final Rect a = tester.getRect(_cardOf(top)).deflate(graphCardOverhang);
      final Rect b = tester.getRect(_cardOf(lower)).deflate(graphCardOverhang);
      return (a.height, b.top - a.top);
    }

    expect(await measure(ZsDensity.compact), (62, 2 * (62 + 48)));
    expect(await measure(ZsDensity.comfy), (74, 2 * (74 + 60)));
    expect(await measure(ZsDensity.balanced), (68, 2 * (68 + 54)));
  });
}
