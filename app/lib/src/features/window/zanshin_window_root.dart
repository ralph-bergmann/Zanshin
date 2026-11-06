// SPDX-License-Identifier: MIT

import 'package:inject_annotation/inject_annotation.dart';
import 'package:inject_flutter/inject_flutter.dart';
import 'package:material_ui/material_ui.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

import '../../l10n/strings.dart';
import '../app/zanshin_app_view_model.dart';
import 'active_window_tracker.dart';
import 'window_chrome_builder.dart';
import 'window_zoom.dart';

part 'zanshin_window_root.factory.dart';

/// The root of every app window (Story 11.12 item 5): each window is built from the `WindowManager`'s context, so it
/// has no theme or DI ancestor of its own, and this root installs them over the shared DI graph.
///
/// A `material_ui` `MaterialApp` with the token theme for both modes from a [ZanshinAppViewModel] over [child]; its
/// builder wraps the navigator in [WindowChromeBuilder] (full screen and the measured traffic-light block, Story 11.4)
/// and [ZsRoot], whose appearance is the view model's with the window's chrome report and the key status the
/// [ActiveWindowTracker] reports for this window's view (inactive while another window is key; DS
/// tokens/inactive.css). Inside the root, `KeyedSubtree(ValueKey('window:<windowKey>'))` lets Marionette's
/// `ancestor_keys` scope a listing to one window (decision 16.31).
///
/// Every window gets its own view model from the factory, over the same settings store and shell reports, so a
/// theme switch from any window restyles every window. [child] stays window-agnostic.
///
/// A window sized to its content (Settings, Story 11.7) passes [sizeToContent]: a navigator's overlay takes the largest
/// size its constraints allow, so the child then sits in an `Overlay.wrap(alwaysSizeToContent: true)` under the
/// builder, with no `home` and no navigator, as the catalogue's `catalogueAppBuilder` does.
///
/// Story 11.20: the Settings density reaches the token layer through the view model's appearance (rows, cards and
/// gaps; text keeps its size), and the Settings zoom scales the whole content in a [WindowZoomBox] with a
/// [MediaQuery] in zoomed units ([zoomedMediaQuery]); the measured traffic-light block is divided by the zoom.
class ZanshinWindowRoot extends StatelessWidget {
  /// The root of the window [windowKey] showing [child].
  @assistedInject
  const ZanshinWindowRoot({
    required this._viewModelFactory,
    required this._tracker,
    @assisted required this.windowKey,
    @assisted required this.child,
    @assisted this.sizeToContent,
    @assisted super.key,
  });

  final ViewModelFactory<ZanshinAppViewModel> _viewModelFactory;
  final ActiveWindowTracker _tracker;

  /// The window's key (`AppWindows`), which names the root's subtree key.
  final String windowKey;

  /// The window's content.
  final Widget child;

  /// Whether the window takes its content's size (null: no).
  final bool? sizeToContent;

  @override
  Widget build(BuildContext context) => _viewModelFactory(
    init: (vm) => vm.init(),
    builder: (context, vm, _) {
      // The token theme for both modes. The window root follows the theme the MaterialApp resolved, so the first
      // frame before the shell answered follows the system's brightness too, and takes full screen and the
      // traffic-light block from the window's chrome report and the key status from the tracker.
      final ZsAppearance appearance = vm.appearance;
      final bool contentSized = sizeToContent ?? false;
      final double zoom = vm.zoomScale;
      return _WindowMaterialApp(
        themeMode: vm.effectiveMode,
        lightTheme: ZsAppTheme.build(appearance.copyWith(theme: ZsTheme.paper)),
        darkTheme: ZsAppTheme.build(appearance.copyWith(theme: ZsTheme.night)),
        builder: (context, navigator) => WindowChromeBuilder(
          builder: (context, chrome) => ListenableBuilder(
            listenable: _tracker,
            builder: (context, _) => MediaQuery(
              data: zoomedMediaQuery(MediaQuery.of(context), zoom),
              child: WindowZoomBox(
                scale: zoom,
                child: ZsRoot(
                  appearance: appearance.copyWith(
                    theme: ZsTheme.of(Theme.of(context).brightness),
                    fullScreen: chrome?.fullScreen,
                    // In zoomed units, so the bar keeps its rule (block end + 12) under zoom; the native buttons
                    // themselves never scale.
                    trafficLights: _zoomedRect(chrome?.trafficLights, zoom),
                    inactive: !_tracker.isActive(View.of(context).viewId),
                  ),
                  shellTheme: vm.shellTheme,
                  child: _keyed(contentSized ? Overlay.wrap(alwaysSizeToContent: true, child: child) : navigator),
                ),
              ),
            ),
          ),
        ),
        home: contentSized ? null : child,
      );
    },
  );

  static Rect? _zoomedRect(Rect? rect, double zoom) =>
      rect == null ? null : Rect.fromLTRB(rect.left / zoom, rect.top / zoom, rect.right / zoom, rect.bottom / zoom);

  Widget _keyed(Widget? navigator) =>
      KeyedSubtree(key: ValueKey<String>('window:$windowKey'), child: navigator ?? const SizedBox.shrink());
}

/// A window's `MaterialApp` over [home], or without a navigator when [home] is null.
class _WindowMaterialApp extends StatelessWidget {
  const _WindowMaterialApp({
    required this.lightTheme,
    required this.darkTheme,
    required this.themeMode,
    required this.builder,
    required this.home,
  });

  final ThemeData lightTheme;
  final ThemeData darkTheme;
  final ThemeMode themeMode;
  final Widget? home;

  /// Wraps the navigator; the window's root scope.
  final TransitionBuilder builder;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Zanshin', // l10n-ignore: the product name
    localizationsDelegates: zanshinLocalizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    theme: lightTheme,
    themeMode: themeMode,
    darkTheme: darkTheme,
    builder: builder,
    home: home,
  );
}
