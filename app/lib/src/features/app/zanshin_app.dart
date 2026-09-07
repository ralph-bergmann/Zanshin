// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:inject_annotation/inject_annotation.dart';
import 'package:inject_flutter/inject_flutter.dart';
import 'package:material_ui/material_ui.dart';
import 'package:yaru/yaru.dart';
import 'package:zanshin_shell/zanshin_shell.dart';

import '../home/home_page.dart';
import 'zanshin_app_view_model.dart';

part 'zanshin_app.factory.dart';

class ZanshinApp extends StatelessWidget {
  @assistedInject
  const ZanshinApp({
    required this._homePageFactory,
    required this._viewModelFactory,
    @assisted super.key,
  });

  // Temporarily unused while `home` shows the Yaru test page below.
  // ignore: unused_field
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
      void onModeChanged(ThemeMode mode) => unawaited(vm.setThemeMode(mode));

      if (!kIsWeb && Platform.isLinux) {
        return YaruTheme(
          builder: (context, yaru, child) => _ExampleHome(
            themeMode: vm.selectedMode,
            selectedMode: vm.selectedMode,
            onModeChanged: onModeChanged,
            lightTheme: yaru.theme,
            darkTheme: yaru.darkTheme,
          ),
        );
      }

      final ShellTheme? shellTheme = vm.shellTheme;
      if (shellTheme == null) {
        // First frame before the platform answered: follow the system via
        // Flutter's own brightness until the shell theme arrives.
        return _ExampleHome(
          themeMode: vm.effectiveMode,
          selectedMode: vm.selectedMode,
          onModeChanged: onModeChanged,
          lightTheme: null,
          darkTheme: null,
        );
      }

      return _ExampleHome(
        themeMode: vm.effectiveMode,
        selectedMode: vm.selectedMode,
        onModeChanged: onModeChanged,
        lightTheme: createYaruLightTheme(primaryColor: shellTheme.accentColor),
        darkTheme: createYaruDarkTheme(primaryColor: shellTheme.accentColor),
      );
    },
  );
}

class _ExampleHome extends StatelessWidget {
  const _ExampleHome({
    required this.lightTheme,
    required this.darkTheme,
    required this.themeMode,
    required this.selectedMode,
    required this.onModeChanged,
  });

  final ThemeData? lightTheme;
  final ThemeData? darkTheme;
  final ThemeMode themeMode;

  /// The user's raw choice (may be `system` while [themeMode] is resolved).
  final ThemeMode selectedMode;
  final ValueChanged<ThemeMode> onModeChanged;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Yaru Test',
    theme: lightTheme ?? yaruLight,
    themeMode: themeMode,
    darkTheme: darkTheme ?? yaruDark,
    home: _Example(selectedMode: selectedMode, onModeChanged: onModeChanged),
  );
}

class _Example extends StatelessWidget {
  const _Example({required this.selectedMode, required this.onModeChanged});

  final ThemeMode selectedMode;
  final ValueChanged<ThemeMode> onModeChanged;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: WindowDragArea(
      child: AppBar(
        title: const Text('hallo ralph, dies ist dein Yaru Test'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: SegmentedButton<ThemeMode>(
              showSelectedIcon: false,
              style: const ButtonStyle(visualDensity: VisualDensity.compact),
              segments: const [
                ButtonSegment(
                  value: ThemeMode.light,
                  icon: Icon(Icons.light_mode, size: 16),
                  tooltip: 'Light',
                ),
                ButtonSegment(
                  value: ThemeMode.dark,
                  icon: Icon(Icons.dark_mode, size: 16),
                  tooltip: 'Dark',
                ),
                ButtonSegment(
                  value: ThemeMode.system,
                  icon: Icon(Icons.brightness_auto, size: 16),
                  tooltip: 'System',
                ),
              ],
              selected: {selectedMode},
              onSelectionChanged: (selection) => onModeChanged(selection.first),
            ),
          ),
        ],
      ),
    ),
    body: const CheckboxPage(),
  );
}

class CheckboxPage extends StatefulWidget {
  const CheckboxPage({super.key});

  @override
  State<CheckboxPage> createState() => _CheckboxPageState();
}

class _CheckboxPageState extends State<CheckboxPage> {
  final List<bool?> _checkboxValues = [false, null, true];
  final List<bool?> _buttonValues = [false, null, true];
  final List<bool?> _listTileValues = [false, null, true];

  @override
  Widget build(BuildContext context) => YaruScrollViewUndershoot.builder(
    builder: (context, controller) => ListView(
      controller: controller,
      padding: const EdgeInsets.all(kYaruPagePadding),
      children: [
        for (var i = 0; i < _checkboxValues.length; ++i) ...[
          Row(
            children: [
              YaruCheckbox(
                value: _checkboxValues[i],
                onChanged: (v) => setState(() => _checkboxValues[i] = v),
                tristate: true,
              ),
              const SizedBox(width: 10),
              YaruCheckbox(
                value: _checkboxValues[i],
                onChanged: null,
                tristate: true,
              ),
            ],
          ),
          const SizedBox(height: 10),
        ],
        const Divider(),
        for (var i = 0; i < _buttonValues.length; ++i) ...[
          YaruCheckButton(
            title: const Text('YaruCheckButton'),
            value: _buttonValues[i],
            onChanged: (v) => setState(() => _buttonValues[i] = v),
            tristate: true,
          ),
          const SizedBox(height: 10),
        ],
        const Divider(),
        for (var i = 0; i < _listTileValues.length; ++i) ...[
          YaruCheckboxListTile(
            value: _listTileValues[i],
            onChanged: (v) => setState(() => _listTileValues[i] = v),
            tristate: true,
            title: const Text('YaruCheckboxListTile'),
          ),
        ],
      ],
    ),
  );
}
