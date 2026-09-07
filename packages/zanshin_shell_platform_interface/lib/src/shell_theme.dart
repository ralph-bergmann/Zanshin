// SPDX-License-Identifier: MIT

import 'dart:ui';

import 'package:flutter/foundation.dart' show immutable;

/// A snapshot of the macOS system theme relevant to Zanshin.
@immutable
class ShellTheme {
  const ShellTheme({required this.brightness, required this.accentColor});

  /// Day/night mode of the system (`Brightness.dark` in night mode).
  final Brightness brightness;

  /// The macOS accent color ("Farbakzent" in System Settings), resolved
  /// under the current appearance.
  final Color accentColor;

  @override
  bool operator ==(Object other) =>
      other is ShellTheme && other.brightness == brightness && other.accentColor == accentColor;

  @override
  int get hashCode => Object.hash(brightness, accentColor);

  @override
  String toString() => 'ShellTheme(brightness: ${brightness.name}, accentColor: $accentColor)';
}

/// Appearance override for the app window.
///
/// [system] removes the override so the window follows the OS appearance.
/// Applied per-window on purpose: overriding `NSApp.appearance` instead would
/// also flip Flutter's `platformBrightness` and hide the real system value.
enum WindowAppearance { light, dark, system }
