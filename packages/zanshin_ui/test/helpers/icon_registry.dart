// SPDX-License-Identifier: MIT

import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin_ui/src/icons/icon_registry.dart';

/// The real icon registry, loaded once per test file by [setUpIconRegistry].
late IconRegistry testIconRegistry;

/// Loads [testIconRegistry] in a `setUpAll`, where real async runs and no tester is needed; `flutter test` bundles
/// the transformed glyphs. A test that loads the registry inside a `testWidgets` body uses
/// `tester.runAsync(IconRegistry.load)` instead.
// WHY: `IconRegistry.load` asks for `packages/zanshin_ui/assets/…`, but in this package's own run the bundle keys its
// assets without that prefix; flutter_test's asset mock retries a `packages/<this package>/` key without it.
void setUpIconRegistry() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    testIconRegistry = await IconRegistry.load();
  });
}
