// SPDX-License-Identifier: MIT

import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/src/shared/widgets/icon_registry.dart';

/// The app's icon registry, loaded once per test file by [setUpIconRegistry].
late IconRegistry testIconRegistry;

/// Loads [testIconRegistry] in a `setUpAll`, where real async runs and no tester is needed; `flutter test` bundles
/// the transformed glyphs. A test that loads the registry inside a `testWidgets` body uses
/// `tester.runAsync(IconRegistry.load)` instead.
void setUpIconRegistry() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    testIconRegistry = await IconRegistry.load();
  });
}
