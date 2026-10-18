// SPDX-License-Identifier: MIT

import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin_shell_platform_interface/zanshin_shell_platform_interface.dart';

import '../helpers/catalogue.dart';
import '../helpers/icon_registry.dart';
import '../helpers/recording_shell.dart';

void main() {
  setUpIconRegistry();
  setUp(() => ZanshinShellPlatform.instance = RecordingShell());

  testWidgets('the Appearance addon names each of its fields', (tester) async {
    useCatalogueWindow(tester);
    await tester.pumpWidget(catalogueAt('/?path=controls/switch/state-matrix'));
    await tester.pump();
    await tester.tap(find.text('Addons'));
    await tester.pumpAndSettle();
    for (final label in <String>[
      'Theme',
      'Accent',
      'Increase contrast',
      'Reduce motion',
      'Reduce transparency',
      'Inactive window',
    ]) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
  });
}
