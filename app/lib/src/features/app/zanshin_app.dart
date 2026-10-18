// SPDX-License-Identifier: MIT

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:inject_annotation/inject_annotation.dart';
import 'package:inject_flutter/inject_flutter.dart';
import 'package:material_ui/material_ui.dart';
import 'package:yaru/yaru.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

import '../home/home_page.dart';
import '../window/window_chrome_builder.dart';
import 'zanshin_app_view_model.dart';

part 'zanshin_app.factory.dart';

class ZanshinApp extends StatelessWidget {
  @assistedInject
  const ZanshinApp({
    required this._homePageFactory,
    required this._viewModelFactory,
    @assisted super.key,
  });

  final HomePageFactory _homePageFactory;
  final ViewModelFactory<ZanshinAppViewModel> _viewModelFactory;

  // static ThemeData _buildTheme(ZanshinColors zc, Brightness brightness) {
  //   final base = brightness == Brightness.dark ? ThemeData.dark() : ThemeData.light();
  //   return base.copyWith(
  //     scaffoldBackgroundColor: zc.bg,
  //     colorScheme: base.colorScheme.copyWith(
  //       primary: zc.accent,
  //       surface: zc.bgCard,
  //       onSurface: zc.textPrimary,
  //     ),
  //     textTheme: base.textTheme.apply(
  //       bodyColor: zc.textPrimary,
  //       displayColor: zc.textPrimary,
  //     ),
  //     inputDecorationTheme: InputDecorationTheme(
  //       filled: true,
  //       fillColor: zc.bgCard2,
  //       border: OutlineInputBorder(
  //         borderRadius: BorderRadius.circular(6),
  //         borderSide: BorderSide(color: zc.border),
  //       ),
  //       enabledBorder: OutlineInputBorder(
  //         borderRadius: BorderRadius.circular(6),
  //         borderSide: BorderSide(color: zc.border),
  //       ),
  //       focusedBorder: OutlineInputBorder(
  //         borderRadius: BorderRadius.circular(6),
  //         borderSide: BorderSide(color: zc.accent),
  //       ),
  //       isDense: true,
  //       contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
  //     ),
  //     extensions: [zc],
  //   );
  // }
  //
  // @override
  // Widget build(BuildContext context) => MaterialApp(
  //   title: 'Zanshin',
  //   debugShowCheckedModeBanner: false,
  //   theme: _buildTheme(ZanshinColors.light, Brightness.light),
  //   darkTheme: _buildTheme(ZanshinColors.dark, Brightness.dark),
  //   themeMode: ThemeMode.dark,
  //   home: _homePageFactory.create(),
  // );

  @override
  Widget build(BuildContext context) => _viewModelFactory(
    init: (vm) => vm.init(),
    builder: (context, vm, _) {
      if (!kIsWeb && Platform.isLinux) {
        return YaruTheme(
          builder: (context, yaru, child) => _ZanshinMaterialApp(
            themeMode: vm.selectedMode,
            lightTheme: yaru.theme,
            darkTheme: yaru.darkTheme,
            home: _homePageFactory.create(),
          ),
        );
      }

      // The token theme for both modes. The window root follows the theme
      // the MaterialApp resolved, so the first frame before the shell
      // answered follows the system's brightness too, and takes full screen
      // and the traffic-light block from the window's chrome report.
      final ZsAppearance appearance = vm.appearance;
      return _ZanshinMaterialApp(
        themeMode: vm.effectiveMode,
        lightTheme: ZsAppTheme.build(appearance.copyWith(theme: ZsTheme.paper)),
        darkTheme: ZsAppTheme.build(appearance.copyWith(theme: ZsTheme.night)),
        builder: (context, child) => WindowChromeBuilder(
          builder: (context, chrome) => ZsRoot(
            appearance: appearance.copyWith(
              theme: ZsTheme.of(Theme.of(context).brightness),
              fullScreen: chrome?.fullScreen,
              trafficLights: chrome?.trafficLights,
            ),
            shellTheme: vm.shellTheme,
            child: child ?? const SizedBox.shrink(),
          ),
        ),
        home: _homePageFactory.create(),
      );
    },
  );
}

/// The project window's `MaterialApp` over [home] (Story 11.3: the floating shell's `HomePage`).
class _ZanshinMaterialApp extends StatelessWidget {
  const _ZanshinMaterialApp({
    required this.lightTheme,
    required this.darkTheme,
    required this.themeMode,
    required this.home,
    this.builder,
  });

  final ThemeData? lightTheme;
  final ThemeData? darkTheme;
  final ThemeMode themeMode;
  final Widget home;

  /// Wraps the navigator; the window's root scope on macOS.
  final TransitionBuilder? builder;

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
