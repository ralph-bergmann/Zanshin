// SPDX-License-Identifier: MIT

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:widgetbook/widgetbook.dart';
import 'package:zanshin/src/features/graph/graph_card.dart';
import 'package:zanshin/src/features/graph/graph_controls.dart';
import 'package:zanshin/src/features/graph/graph_inspector.dart';
import 'package:zanshin/src/features/graph/graph_search_field.dart';
import 'package:zanshin/src/features/graph/graph_view.dart';
import 'package:zanshin/src/features/graph/graph_view_model.dart';
import 'package:zanshin/src/features/graph/graph_viewport_render.dart';
import 'package:zanshin/src/features/graph/stale_notice.dart';
import 'package:zanshin/src/features/shell/floating_shell.dart';
import 'package:zanshin_shell_platform_interface/zanshin_shell_platform_interface.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

import '../../widgetbook/catalogue.dart';
import '../helpers/catalogue.dart';
import '../helpers/icon_registry.dart';
import '../helpers/recording_shell.dart';

void main() {
  setUpIconRegistry();
  late RecordingShell shell;
  setUp(() => ZanshinShellPlatform.instance = shell = RecordingShell());
  tearDown(() => shell.close());

  final paths = <String>[
    for (final WidgetbookUseCase useCase in WidgetbookRoot(
      children: catalogueDirectories,
    ).leaves.whereType<WidgetbookUseCase>())
      useCase.path,
  ];

  test(
    'the folders are Controls, Materials, Shell, Projects, Windows, Icons and Graph, and every use case has its own path',
    () {
      expect(
        catalogueDirectories.map((node) => node.name),
        <String>['Controls', 'Materials', 'Shell', 'Projects', 'Windows', 'Icons', 'Graph'],
      );
      expect(paths.toSet(), hasLength(paths.length));
      expect(paths, contains('controls/switch/state-matrix'));
      expect(
        paths,
        containsAll(<String>[
          'shell/floating-shell/layout',
          'shell/floating-shell/preview-open',
          'shell/floating-shell/pinned-panel',
          'shell/floating-shell/flyout',
          'shell/floating-shell/calm',
          'shell/floating-shell/slots',
          'projects/project-capsule/states',
          'projects/project-capsule/menu-open',
          'controls/resize-edge/state-matrix',
          'materials/island/fade',
          'materials/canvas/window-canvas',
          'windows/floating-shell/floating-shell',
          'projects/projects-window/tree',
          'projects/projects-window/search',
          'projects/projects-window/no-results',
          'projects/projects-window/empty',
          'projects/projects-window/narrow',
          'projects/projects-window/convert-offer',
          'projects/projects-window/clone-form',
          'projects/projects-window/drop-hint',
          'projects/projects-window/no-identity',
          'projects/projects-window/rename-group',
          'projects/projects-window/moving',
          'materials/drag-ghost/kinds',
          'windows/projects-window/projects-window',
          'windows/window-fill/window-fill',
          'windows/window-scaffold/resizable',
          'windows/window-scaffold/content-sized',
          'windows/window-scaffold/floating',
          'graph/viewport/recording',
          'graph/viewport/scale',
          'graph/viewport/view-model',
          'graph/card/states',
          'graph/peek/open',
          'graph/@-pill/directions',
          'graph/stale-notice/variants',
          'graph/floating-shell/controls',
        ]),
      );
      expect(catalogueUseCasePaths, paths.toSet());
    },
  );

  for (final path in paths) {
    for (final ZsTheme theme in ZsTheme.values) {
      testWidgets('$path builds in ${theme.name}', (tester) async {
        useCatalogueWindow(tester);
        await tester.pumpWidget(catalogueAt('/?path=$path&appearance={theme:${theme.name}}'));
        await tester.pump();
        expect(tester.takeException(), isNull);
        expect(canvasOf(theme), findsWidgets, reason: 'the use case shows under the Appearance addon');
        if (path.startsWith('graph/')) {
          expect(find.byType(ZsCanvas), findsOneWidget, reason: 'the window canvas behind the viewport');
        }
      });
    }

    testWidgets('$path builds with every system flag and the inactive window', (tester) async {
      useCatalogueWindow(tester);
      await tester.pumpWidget(
        catalogueAt(
          '/?path=$path&appearance={accent:green,contrast:true,reduceMotion:true,reduceTransparency:true,'
          'inactive:true}',
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('graph/viewport/recording paints edges (Story 10.4)', (tester) async {
    useCatalogueWindow(tester);
    await tester.pumpWidget(catalogueAt('/?path=graph/viewport/recording&appearance={theme:night}'));
    await tester.pump();
    expect(
      tester.allRenderObjects.whereType<RenderGraphViewport>().single,
      paints..path(color: GraphTheme.night.edge, strokeWidth: 1.5),
    );
  });

  testWidgets('graph/viewport/scale at 50k paints its edges once the isolate has routed them (Story 10.4)', (
    tester,
  ) async {
    useCatalogueWindow(tester);
    await tester.pumpWidget(catalogueAt('/?path=graph/viewport/scale&appearance={theme:night}&knobs={nodes:50k}'));
    await tester.pump();
    PaintPattern edges() => paints..path(color: GraphTheme.night.edge, strokeWidth: 1.5);
    RenderGraphViewport render() => tester.allRenderObjects.whereType<RenderGraphViewport>().single;
    bool painted() {
      try {
        expect(render(), edges());
        return true;
      } on TestFailure {
        return false;
      }
    }

    expect(painted(), isFalse, reason: 'no edge before the route completes');
    // Real time for Isolate.run, then pumps to deliver its result and repaint.
    for (var i = 0; i < 300 && !painted(); i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
      await tester.pump();
    }
    expect(render(), edges());
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'graph/viewport/view-model keeps its model across knob changes: a stale cause stands over the layout; a re-open '
    'starts afresh',
    (tester) async {
      useCatalogueWindow(tester);
      const route = '/?path=graph/viewport/view-model&appearance={theme:night}';
      await tester.pumpWidget(catalogueAt(route));
      await tester.pump();
      await tester.pump();
      expect(find.byType(GraphCard), findsWidgets, reason: 'the first layout landed');
      expect(find.byType(StaleNotice), findsNothing);
      final GraphViewModel model = tester.widget<GraphView>(find.byType(GraphView)).model;

      // What the knob panel does on a pick: the route's query changes, so Widgetbook rebuilds the use case afresh.
      WidgetbookState.of(
        tester.element(find.byType(GraphView)),
      ).updateQueryField(group: 'knobs', field: 'stale cause', value: 'stale');
      await tester.pump();
      await tester.pump();
      expect(find.byType(StaleNotice), findsOneWidget);
      expect(find.byType(GraphCard), findsWidgets, reason: 'the notice stands over the last layout');
      expect(tester.widget<GraphView>(find.byType(GraphView)).model, same(model), reason: 'the knob kept the model');

      tester.state<ZanshinCatalogueState>(find.byType(ZanshinCatalogue)).open(route);
      await tester.pump();
      await tester.pump();
      expect(
        tester.widget<GraphView>(find.byType(GraphView)).model,
        isNot(same(model)),
        reason: 'a re-open of the route shown starts afresh',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'graph/floating-shell/controls at 1440: VIEW shows the search, the count, separators and View options; ACTION '
    'shows New change',
    (tester) async {
      useCatalogueWindow(tester);
      await tester.pumpWidget(catalogueAt('/?path=graph/floating-shell/controls&appearance={theme:night}'));
      await tester.pump();
      await tester.pump();
      final Finder view = find.byType(GraphViewControls);
      expect(find.descendant(of: view, matching: find.byType(GraphSearchField)), findsOneWidget);
      expect(find.descendant(of: view, matching: find.byType(GraphCount)), findsOneWidget);
      expect(find.descendant(of: view, matching: find.byType(ZsIslandSeparator)), findsNWidgets(2));
      expect(find.descendant(of: view, matching: find.byType(GraphViewOptionsButton)), findsOneWidget);
      expect(find.descendant(of: find.byType(NewChangeButton), matching: find.text('New change')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'graph/floating-shell/controls opens with a mutable change selected: the inspector at top 60 with its header, '
    'title, meta, action row and files (Story 10.8)',
    (tester) async {
      useCatalogueWindow(tester);
      await tester.pumpWidget(catalogueAt('/?path=graph/floating-shell/controls&appearance={theme:night}'));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      final Finder inspector = find.byType(GraphInspector);
      expect(inspector, findsOneWidget);
      final GraphViewModel model = tester.widget<GraphView>(find.byType(GraphView)).model;
      expect(model.selected, isNotNull);
      final Finder island = find.descendant(of: inspector, matching: find.byType(ZsIsland)).first;
      final Rect shell = tester.getRect(find.byType(FloatingShell));
      // The use case scales the window into the catalogue's frame: compare in the shell's own coordinates.
      final double scale = shell.width / 1440;
      expect((tester.getRect(island).top - shell.top) / scale, moreOrLessEquals(60, epsilon: 0.5));
      Finder within(String identifier) => find.descendant(
        of: inspector,
        matching: find.byWidgetPredicate((w) => w is ZsButton && w.identifier == identifier),
      );
      expect(within('inspector-edit'), findsOneWidget);
      expect(within('inspector-squash'), findsOneWidget);
      expect(within('inspector-abandon'), findsOneWidget);
      expect(find.descendant(of: inspector, matching: find.byKey(const ValueKey<String>('inspector-meta'))), findsOne);
      expect(find.byWidgetPredicate((w) => w is ZsResizeEdge && w.identifier == 'inspector-edge'), findsOneWidget);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
}
