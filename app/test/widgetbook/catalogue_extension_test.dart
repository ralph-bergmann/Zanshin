// SPDX-License-Identifier: MIT

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marionette_flutter/marionette_flutter.dart';
import 'package:widgetbook/widgetbook.dart' show FieldCodec, Widgetbook;
import 'package:zanshin/src/features/graph/graph_viewport.dart';
import 'package:zanshin_shell_platform_interface/zanshin_shell_platform_interface.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

import '../../widgetbook/catalogue.dart';
import '../../widgetbook/catalogue_extension.dart';
import '../../widgetbook/graph/placeholder_card.dart';
import '../helpers/catalogue.dart';
import '../helpers/icon_registry.dart';
import '../helpers/recording_shell.dart';

const _switch = 'controls/switch/state-matrix';

Map<String, String> _query(String route) => Uri.parse(route).queryParameters;

void main() {
  setUpIconRegistry();

  group('catalogueRoute', () {
    final Set<String> paths = catalogueUseCasePaths;

    test('the path alone', () {
      final String route = catalogueRoute(const <String, String>{'path': _switch}, paths: paths);
      expect(_query(route), <String, String>{'path': _switch});
    });

    test('the appearance values go into the Appearance addon\'s group', () {
      final String route = catalogueRoute(const <String, String>{
        'path': _switch,
        'theme': 'paper',
        'accent': 'green',
        'contrast': 'true',
        'reduceMotion': 'false',
        'reduceTransparency': 'true',
        'inactive': 'true',
      }, paths: paths);
      expect(_query(route)['path'], _switch);
      expect(FieldCodec.decodeQueryGroup(_query(route)['appearance']), <String, String>{
        'theme': 'paper',
        'accent': 'green',
        'contrast': 'true',
        'reduceMotion': 'false',
        'reduceTransparency': 'true',
        'inactive': 'true',
      });
    });

    for (final (String what, Map<String, String> params) in <(String, Map<String, String>)>[
      ('a missing path', const <String, String>{'theme': 'paper'}),
      ('an unknown path', const <String, String>{'path': 'controls/nothing/state-matrix'}),
      ('an unknown theme', const <String, String>{'path': _switch, 'theme': 'sepia'}),
      ('an unknown accent', const <String, String>{'path': _switch, 'accent': 'teal'}),
      ('a flag that is no boolean', const <String, String>{'path': _switch, 'inactive': 'yes'}),
    ]) {
      test('rejects $what', () {
        expect(() => catalogueRoute(params, paths: paths), throwsFormatException);
      });
    }
  });

  group('openInCatalogue', () {
    late RecordingShell shell;
    setUp(() => ZanshinShellPlatform.instance = shell = RecordingShell());
    tearDown(() => shell.close());

    testWidgets('path=controls/switch/state-matrix&theme=paper shows the switch matrix in paper', (tester) async {
      useCatalogueWindow(tester);
      final catalogue = GlobalKey<ZanshinCatalogueState>();
      await tester.pumpWidget(catalogueAt('/', key: catalogue));
      final MarionetteExtensionResult result = openInCatalogue(const <String, String>{
        'path': _switch,
        'theme': 'paper',
      }, catalogue.currentState!);
      expect(result, isA<MarionetteExtensionSuccess>());
      await tester.pump();
      await tester.pump();
      expect(find.byType(ZsSwitch), findsWidgets);
      expect(canvasOf(ZsTheme.paper), findsWidgets);
      expect(catalogue.currentState!.route, (result as MarionetteExtensionSuccess).data['route']);
    });

    for (final path in <String>['graph/viewport/recording', 'graph/viewport/scale']) {
      testWidgets('path=$path opens the Graph viewport with placeholder cards', (tester) async {
        useCatalogueWindow(tester);
        final catalogue = GlobalKey<ZanshinCatalogueState>();
        await tester.pumpWidget(catalogueAt('/', key: catalogue));
        final MarionetteExtensionResult result = openInCatalogue(<String, String>{
          'path': path,
        }, catalogue.currentState!);
        expect(result, isA<MarionetteExtensionSuccess>());
        await tester.pump();
        await tester.pump();
        expect(find.byType(GraphViewport), findsOneWidget);
        expect(find.byType(GraphPlaceholderCard), findsWidgets);
      });
    }

    testWidgets('every appearance value reaches the use case', (tester) async {
      useCatalogueWindow(tester);
      final catalogue = GlobalKey<ZanshinCatalogueState>();
      await tester.pumpWidget(catalogueAt('/', key: catalogue));
      final MarionetteExtensionResult result = openInCatalogue(const <String, String>{
        'path': _switch,
        'theme': 'paper',
        'accent': 'green',
        'contrast': 'true',
        'reduceMotion': 'true',
        'reduceTransparency': 'true',
        'inactive': 'true',
      }, catalogue.currentState!);
      expect(result, isA<MarionetteExtensionSuccess>());
      await tester.pump();
      await tester.pump();
      expect(
        ZsAppearance.of(tester.element(find.byType(ZsSwitch).first)),
        const ZsAppearance(
          theme: ZsTheme.paper,
          family: ZsAccentFamily.green,
          increasedContrast: true,
          reduceMotion: true,
          reduceTransparency: true,
          inactive: true,
        ),
      );
    });

    testWidgets('opening the route already shown starts it afresh', (tester) async {
      useCatalogueWindow(tester);
      final catalogue = GlobalKey<ZanshinCatalogueState>();
      await tester.pumpWidget(catalogueAt('/', key: catalogue));
      const params = <String, String>{'path': _switch};
      openInCatalogue(params, catalogue.currentState!);
      await tester.pump();
      await tester.pump();
      final State<StatefulWidget> first = tester.state(find.byType(Widgetbook));
      openInCatalogue(params, catalogue.currentState!);
      await tester.pump();
      await tester.pump();
      expect(tester.state(find.byType(Widgetbook)), isNot(same(first)));
    });

    testWidgets('an invalid value answers invalid params and changes nothing', (tester) async {
      useCatalogueWindow(tester);
      final catalogue = GlobalKey<ZanshinCatalogueState>();
      await tester.pumpWidget(catalogueAt('/', key: catalogue));
      final MarionetteExtensionResult result = openInCatalogue(const <String, String>{
        'path': _switch,
        'theme': 'sepia',
      }, catalogue.currentState!);
      expect(result, isA<MarionetteExtensionInvalidParams>());
      expect((result as MarionetteExtensionInvalidParams).detail, contains('theme'));
      expect(catalogue.currentState!.route, '/');
    });
  });
}
