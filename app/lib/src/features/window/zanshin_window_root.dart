// SPDX-License-Identifier: MIT

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:inject_annotation/inject_annotation.dart';
import 'package:inject_flutter/inject_flutter.dart';
import 'package:material_ui/material_ui.dart';
import 'package:yaru/yaru.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

import '../app/zanshin_app_view_model.dart';
import 'active_window_tracker.dart';
import 'window_chrome_builder.dart';

part 'zanshin_window_root.factory.dart';

/// The root of every app window (Story 11.12 item 5): each window is built from the `WindowManager`'s context, so it
/// has no theme or DI ancestor of its own, and this root installs them over the shared DI graph.
///
/// A `material_ui` `MaterialApp` with the token theme for both modes from a [ZanshinAppViewModel] (Yaru's on Linux)
/// over [child]; its builder wraps the navigator in [WindowChromeBuilder] (full screen and the measured
/// traffic-light block, Story 11.4) and [ZsRoot], whose appearance is the view model's with the window's chrome report
/// and the key status the [ActiveWindowTracker] reports for this window's view (inactive while another window is
/// key; DS tokens/inactive.css). Inside the root, `KeyedSubtree(ValueKey('window:<windowKey>'))` lets Marionette's
/// `ancestor_keys` scope a listing to one window (decision 16.31).
///
/// Every window gets its own view model from the factory, over the same settings store and shell reports, so a
/// theme switch from any window restyles every window. [child] stays window-agnostic.
class ZanshinWindowRoot extends StatelessWidget {
  /// The root of the window [windowKey] showing [child].
  @assistedInject
  const ZanshinWindowRoot({
    required this._viewModelFactory,
    required this._tracker,
    @assisted required this.windowKey,
    @assisted required this.child,
    @assisted super.key,
  });

  final ViewModelFactory<ZanshinAppViewModel> _viewModelFactory;
  final ActiveWindowTracker _tracker;

  /// The window's key (`AppWindows`), which names the root's subtree key.
  final String windowKey;

  /// The window's content.
  final Widget child;

  @override
  Widget build(BuildContext context) => _viewModelFactory(
    init: (vm) => vm.init(),
    builder: (context, vm, _) {
      if (!kIsWeb && Platform.isLinux) {
        return YaruTheme(
          builder: (context, yaru, _) => _WindowMaterialApp(
            themeMode: vm.selectedMode,
            lightTheme: yaru.theme,
            darkTheme: yaru.darkTheme,
            builder: (context, navigator) => _keyed(navigator),
            home: child,
          ),
        );
      }

      // The token theme for both modes. The window root follows the theme the MaterialApp resolved, so the first
      // frame before the shell answered follows the system's brightness too, and takes full screen and the
      // traffic-light block from the window's chrome report and the key status from the tracker.
      final ZsAppearance appearance = vm.appearance;
      return _WindowMaterialApp(
        themeMode: vm.effectiveMode,
        lightTheme: ZsAppTheme.build(appearance.copyWith(theme: ZsTheme.paper)),
        darkTheme: ZsAppTheme.build(appearance.copyWith(theme: ZsTheme.night)),
        builder: (context, navigator) => WindowChromeBuilder(
          builder: (context, chrome) => ListenableBuilder(
            listenable: _tracker,
            builder: (context, _) => ZsRoot(
              appearance: appearance.copyWith(
                theme: ZsTheme.of(Theme.of(context).brightness),
                fullScreen: chrome?.fullScreen,
                trafficLights: chrome?.trafficLights,
                inactive: !_tracker.isActive(View.of(context).viewId),
              ),
              shellTheme: vm.shellTheme,
              child: _keyed(navigator),
            ),
          ),
        ),
        home: child,
      );
    },
  );

  Widget _keyed(Widget? navigator) =>
      KeyedSubtree(key: ValueKey<String>('window:$windowKey'), child: navigator ?? const SizedBox.shrink());
}

/// A window's `MaterialApp` over [home].
class _WindowMaterialApp extends StatelessWidget {
  const _WindowMaterialApp({
    required this.lightTheme,
    required this.darkTheme,
    required this.themeMode,
    required this.builder,
    required this.home,
  });

  final ThemeData? lightTheme;
  final ThemeData? darkTheme;
  final ThemeMode themeMode;
  final Widget home;

  /// Wraps the navigator; the window's root scope.
  final TransitionBuilder builder;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Zanshin',
    theme: lightTheme ?? yaruLight,
    themeMode: themeMode,
    darkTheme: darkTheme ?? yaruDark,
    builder: builder,
    home: home,
  );
}
