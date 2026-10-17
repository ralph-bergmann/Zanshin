// SPDX-License-Identifier: MIT

import 'package:material_ui/material_ui.dart';

import 'zs_appearance.dart';
import 'zs_colors.dart';
import 'zs_elevation.dart';
import 'zs_type.dart';

/// Builds the app's [ThemeData] from the tokens, for the Material parts that remain: `MaterialApp` as the host of
/// Navigator, Overlay, localisations and the token extensions, and text editing. No visible control is Material- or
/// Yaru-styled (decision 16.1); the accent role comes from the family tokens, not from a macOS-accent primary.
// WHY: `ZsAppTheme.build` is the shape the stories name; the class only groups the builder with its private
// constants, there is nothing to construct.
// ignore: avoid_classes_with_only_static_members
abstract final class ZsAppTheme {
  /// The arrow everywhere (DS readme.md:106): the Material component themes that have a mouse cursor get
  /// [SystemMouseCursors.basic]; the Zs controls own their cursors (11.11).
  static const _arrow = WidgetStatePropertyAll<MouseCursor?>(SystemMouseCursors.basic);

  static const _arrowButton = ButtonStyle(mouseCursor: _arrow);

  static const _arrowMenu = MenuStyle(mouseCursor: _arrow);

  /// The theme [appearance] shows: night is dark, paper light; [ZsColors] and [ZsElevation] ride along resolved.
  static ThemeData build(ZsAppearance appearance) {
    final colors = ZsColors.resolve(appearance);
    final ColorScheme scheme = switch (appearance.theme) {
      // Only primary, secondary, surface, onSurface and error are mapped; the other roles keep Material's defaults,
      // which the Zs controls (11.11) do not read. Claude's proposal (Story 11.1): secondary mirrors the accent.
      ZsTheme.night => ColorScheme.dark(
        primary: colors.accent,
        onPrimary: colors.accentInk,
        secondary: colors.accent,
        onSecondary: colors.accentInk,
        surface: colors.cardSolid,
        onSurface: colors.text,
        error: colors.error,
      ),
      ZsTheme.paper => ColorScheme.light(
        primary: colors.accent,
        onPrimary: colors.accentInk,
        secondary: colors.accent,
        onSecondary: colors.accentInk,
        surface: colors.cardSolid,
        onSurface: colors.text,
        error: colors.error,
      ),
    };
    return ThemeData(
      brightness: appearance.theme.brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: colors.canvasBase,
      fontFamily: ZsType.sansFamily,
      textTheme: _textTheme(colors),
      // The DS uses fills, not ripples (DS readme.md:102).
      splashFactory: NoSplash.splashFactory,
      hoverColor: colors.flHover,
      highlightColor: colors.flOn,
      focusColor: colors.focusRing,
      // A nested Theme re-installs this IconTheme; `--text`, like the window root's.
      iconTheme: IconThemeData(color: colors.text),
      extensions: <ThemeExtension<dynamic>>[colors, ZsElevation.resolve(appearance)],
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(mouseCursor: _arrow),
      checkboxTheme: const CheckboxThemeData(mouseCursor: _arrow),
      dataTableTheme: const DataTableThemeData(headingCellCursor: _arrow, dataRowCursor: _arrow),
      dropdownMenuTheme: const DropdownMenuThemeData(menuStyle: _arrowMenu),
      elevatedButtonTheme: const ElevatedButtonThemeData(style: _arrowButton),
      filledButtonTheme: const FilledButtonThemeData(style: _arrowButton),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(mouseCursor: _arrow),
      iconButtonTheme: const IconButtonThemeData(style: _arrowButton),
      listTileTheme: const ListTileThemeData(mouseCursor: _arrow),
      menuBarTheme: const MenuBarThemeData(style: _arrowMenu),
      menuButtonTheme: const MenuButtonThemeData(style: _arrowButton),
      menuTheme: const MenuThemeData(style: _arrowMenu),
      outlinedButtonTheme: const OutlinedButtonThemeData(style: _arrowButton),
      popupMenuTheme: const PopupMenuThemeData(mouseCursor: _arrow),
      radioTheme: const RadioThemeData(mouseCursor: _arrow),
      segmentedButtonTheme: const SegmentedButtonThemeData(style: _arrowButton),
      sliderTheme: const SliderThemeData(mouseCursor: _arrow),
      switchTheme: const SwitchThemeData(mouseCursor: _arrow),
      tabBarTheme: const TabBarThemeData(mouseCursor: _arrow),
      textButtonTheme: const TextButtonThemeData(style: _arrowButton),
    );
  }

  /// The Material text styles from the type roles, in `--text`.
  ///
  /// Claude's proposal (Story 11.1) for the mapping: display and headline take the inspector title, titles the
  /// dialog, panel and card-subject roles, body the body and secondary roles, labels the control and meta roles.
  static TextTheme _textTheme(ZsColors colors) => const TextTheme(
    displayLarge: ZsType.inspectorTitle,
    displayMedium: ZsType.inspectorTitle,
    displaySmall: ZsType.inspectorTitle,
    headlineLarge: ZsType.inspectorTitle,
    headlineMedium: ZsType.inspectorTitle,
    headlineSmall: ZsType.inspectorTitle,
    titleLarge: ZsType.dialogTitle,
    titleMedium: ZsType.panelTitle,
    titleSmall: ZsType.cardSubject,
    bodyLarge: ZsType.body,
    bodyMedium: ZsType.body,
    bodySmall: ZsType.secondary,
    labelLarge: ZsType.control,
    labelMedium: ZsType.meta,
    labelSmall: ZsType.meta,
  ).apply(bodyColor: colors.text, displayColor: colors.text);
}
