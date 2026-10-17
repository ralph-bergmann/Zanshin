// SPDX-License-Identifier: MIT

import 'dart:ui';

import 'package:flutter/foundation.dart' show immutable;

/// How macOS shows scroll bars ("Show scroll bars" in System Settings), `NSScroller.preferredScrollerStyle`.
enum ScrollerStyle {
  /// Always-visible scroll bars that take layout space.
  legacy,

  /// Overlay scroll bars that appear while scrolling.
  overlay,
}

/// A snapshot of the macOS system theme and accessibility state relevant to Zanshin.
///
/// Flutter's macOS embedder reports none of the accessibility flags, so this is where Zanshin reads them. Every field
/// added after [brightness] and [accentColor] is optional: an absent value takes its default, and a value macOS does
/// not report (no `AppleAccentColor`, no system colour) is null.
@immutable
class ShellTheme {
  const ShellTheme({
    required this.brightness,
    required this.accentColor,
    this.appleAccentColor,
    this.reduceMotion = false,
    this.reduceTransparency = false,
    this.increaseContrast = false,
    this.selectedTextBackgroundDark,
    this.selectedTextBackgroundLight,
    this.unemphasizedSelectedTextBackgroundDark,
    this.unemphasizedSelectedTextBackgroundLight,
    this.scrollerStyle = ScrollerStyle.overlay,
    this.jumpToClickedSpot = false,
  });

  /// Day/night mode of the system (`Brightness.dark` in night mode).
  final Brightness brightness;

  /// The macOS accent colour (`NSColor.controlAccentColor`), resolved in the aqua appearance — the value the
  /// "This Mac" hue mapping and the Multicolor check read when [appleAccentColor] is absent.
  ///
  /// Claude's proposal (Story 11.1): re-documented as aqua instead of a second field, now that its only consumer,
  /// the Yaru primary, is gone.
  final Color accentColor;

  /// The `AppleAccentColor` user default: −1 Graphite, 0 Red, 1 Orange, 2 Yellow, 3 Green, 4 Blue, 5 Purple,
  /// 6 Pink; null when absent, which means Multicolor or an iMac's "This Mac" colour.
  final int? appleAccentColor;

  /// `NSWorkspace.accessibilityDisplayShouldReduceMotion`.
  final bool reduceMotion;

  /// `NSWorkspace.accessibilityDisplayShouldReduceTransparency`.
  final bool reduceTransparency;

  /// `NSWorkspace.accessibilityDisplayShouldIncreaseContrast`.
  final bool increaseContrast;

  /// `NSColor.selectedTextBackgroundColor` resolved in darkAqua (Zanshin's night); null if unavailable.
  final Color? selectedTextBackgroundDark;

  /// `NSColor.selectedTextBackgroundColor` resolved in aqua (Zanshin's paper); null if unavailable.
  final Color? selectedTextBackgroundLight;

  /// `NSColor.unemphasizedSelectedTextBackgroundColor` resolved in darkAqua; null if unavailable.
  final Color? unemphasizedSelectedTextBackgroundDark;

  /// `NSColor.unemphasizedSelectedTextBackgroundColor` resolved in aqua; null if unavailable.
  final Color? unemphasizedSelectedTextBackgroundLight;

  /// `NSScroller.preferredScrollerStyle`.
  final ScrollerStyle scrollerStyle;

  /// The `AppleScrollerPagingBehavior` user default: whether a click in the scroll bar track jumps to the spot
  /// clicked ("Click in the scroll bar to: Jump to the spot that's clicked") instead of paging.
  final bool jumpToClickedSpot;

  @override
  bool operator ==(Object other) =>
      other is ShellTheme &&
      other.brightness == brightness &&
      other.accentColor == accentColor &&
      other.appleAccentColor == appleAccentColor &&
      other.reduceMotion == reduceMotion &&
      other.reduceTransparency == reduceTransparency &&
      other.increaseContrast == increaseContrast &&
      other.selectedTextBackgroundDark == selectedTextBackgroundDark &&
      other.selectedTextBackgroundLight == selectedTextBackgroundLight &&
      other.unemphasizedSelectedTextBackgroundDark == unemphasizedSelectedTextBackgroundDark &&
      other.unemphasizedSelectedTextBackgroundLight == unemphasizedSelectedTextBackgroundLight &&
      other.scrollerStyle == scrollerStyle &&
      other.jumpToClickedSpot == jumpToClickedSpot;

  @override
  int get hashCode => Object.hash(
    brightness,
    accentColor,
    appleAccentColor,
    reduceMotion,
    reduceTransparency,
    increaseContrast,
    selectedTextBackgroundDark,
    selectedTextBackgroundLight,
    unemphasizedSelectedTextBackgroundDark,
    unemphasizedSelectedTextBackgroundLight,
    scrollerStyle,
    jumpToClickedSpot,
  );

  @override
  String toString() =>
      'ShellTheme(brightness: ${brightness.name}, accentColor: $accentColor, appleAccentColor: $appleAccentColor, '
      'reduceMotion: $reduceMotion, reduceTransparency: $reduceTransparency, increaseContrast: $increaseContrast, '
      'selectedTextBackgroundDark: $selectedTextBackgroundDark, '
      'selectedTextBackgroundLight: $selectedTextBackgroundLight, '
      'unemphasizedSelectedTextBackgroundDark: $unemphasizedSelectedTextBackgroundDark, '
      'unemphasizedSelectedTextBackgroundLight: $unemphasizedSelectedTextBackgroundLight, '
      'scrollerStyle: ${scrollerStyle.name}, jumpToClickedSpot: $jumpToClickedSpot)';
}

/// Appearance override for the app window.
///
/// [system] removes the override so the window follows the OS appearance.
/// Applied per-window on purpose: overriding `NSApp.appearance` instead would
/// also flip Flutter's `platformBrightness` and hide the real system value.
enum WindowAppearance { light, dark, system }
