// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/src/widgets/_window.dart';
import 'package:flutter/widgets.dart';
import 'package:marionette_flutter/marionette_flutter.dart';
import 'package:zanshin/src/app/zanshin_marionette.dart';
import 'package:zanshin/src/features/window/active_window_tracker.dart';
import 'package:zanshin/src/features/window/app_windows.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

import 'catalogue.dart';
import 'catalogue_extension.dart';
import 'folders/windows.dart';

/// The catalogue's window.
const _windowKey = 'widgetbook';
const _windowTitle = 'Zanshin catalogue';
const _windowSize = Size(1440, 900);

/// The review catalogue (decision 16.29): `flutter run -d macos -t widgetbook/main.dart` from `app/`.
///
/// It runs in a window of its own, as the app does: every window is created from Dart, and the first one must be
/// part of `runWidget`. The catalogue window is a project-kind window, so it keeps the process alive; the windows the
/// use cases open take their inactive look from the catalogue's own [ActiveWindowTracker]. In debug builds Marionette
/// drives it with the app's configuration and the `zanshinCatalogue.open` extension.
Future<void> main() async {
  final catalogue = GlobalKey<ZanshinCatalogueState>();
  if (kDebugMode) {
    MarionetteBinding.ensureInitialized(zanshinMarionetteConfiguration);
    registerCatalogueExtension(() => catalogue.currentState!);
  } else {
    WidgetsFlutterBinding.ensureInitialized();
  }
  SemanticsBinding.instance.ensureSemantics();
  zsRingFollowsInput();
  final IconRegistry registry = await IconRegistry.load();
  final windows = AppWindows();
  final tracker = ActiveWindowTracker();
  // WHY: the windowing API is experimental and `@internal` (flutter#30701); the app's mains use it the same way.
  // ignore: invalid_use_of_internal_member
  final WindowEntry entry = await windows.create(
    key: _windowKey,
    title: _windowTitle,
    size: _windowSize,
    builder: (context) => CatalogueWindows(
      windows: windows,
      tracker: tracker,
      child: ZanshinCatalogue(key: catalogue),
    ),
  );
  runWidget(
    IconRegistryScope(
      registry: registry,
      // WHY: the first window must be part of `runWidget`; `WindowManager` is the windowing API's `@internal` host.
      // ignore: invalid_use_of_internal_member
      child: WindowManager(initialWindows: <WindowEntry>[entry]),
    ),
  );
}
