// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/material.dart';
import 'package:inject_annotation/inject_annotation.dart';
import '../../shared/theme/zanshin_colors.dart';

import '../home/home_page.dart';

part 'zanshin_app.factory.dart';

class ZanshinApp extends StatelessWidget {
  @assistedInject
  const ZanshinApp({
    required this._homePageFactory,
    @assisted super.key,
  });

  final HomePageFactory _homePageFactory;

  static ThemeData _buildTheme(ZanshinColors zc, Brightness brightness) {
    final base = brightness == Brightness.dark ? ThemeData.dark() : ThemeData.light();
    return base.copyWith(
      scaffoldBackgroundColor: zc.bg,
      colorScheme: base.colorScheme.copyWith(
        primary: zc.accent,
        surface: zc.bgCard,
        onSurface: zc.textPrimary,
      ),
      textTheme: base.textTheme.apply(
        bodyColor: zc.textPrimary,
        displayColor: zc.textPrimary,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: zc.bgCard2,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: BorderSide(color: zc.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: BorderSide(color: zc.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: BorderSide(color: zc.accent),
        ),
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      ),
      extensions: [zc],
    );
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Zanshin',
    debugShowCheckedModeBanner: false,
    theme: _buildTheme(ZanshinColors.light, Brightness.light),
    darkTheme: _buildTheme(ZanshinColors.dark, Brightness.dark),
    themeMode: ThemeMode.dark,
    home: _homePageFactory.create(),
  );
}
