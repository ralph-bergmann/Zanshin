// SPDX-License-Identifier: MIT

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:inject_annotation/inject_annotation.dart';
import 'package:yaru/yaru.dart';

import '../home/home_page.dart';

part 'zanshin_app.factory.dart';

class ZanshinApp extends StatelessWidget {
  @assistedInject
  const ZanshinApp({
    required this._homePageFactory,
    @assisted super.key,
  });

  final HomePageFactory _homePageFactory;

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
  Widget build(BuildContext context) {
    const ThemeMode themeMode = ThemeMode.light;

    if (!kIsWeb && Platform.isLinux) {
      return YaruTheme(
        builder: (context, yaru, child) => _ExampleHome(
          themeMode: themeMode,
          lightTheme: yaru.theme,
          darkTheme: yaru.darkTheme,
        ),
      );
    }

    return _ExampleHome(
      themeMode: themeMode,
      lightTheme: yaruLight,
      darkTheme: yaruDark,
    );
  }
}

class _ExampleHome extends StatelessWidget {
  const _ExampleHome({
    required this.lightTheme,
    required this.darkTheme,
    required this.themeMode,
  });

  final ThemeData lightTheme;
  final ThemeData darkTheme;
  final ThemeMode themeMode;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Yaru Test',
    theme: lightTheme,
    themeMode: themeMode,
    darkTheme: darkTheme,
    home: const _Example(),
  );
}

class _Example extends StatelessWidget {
  const _Example({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('hallo ralph, dies ist dein Yaru Test')),
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
