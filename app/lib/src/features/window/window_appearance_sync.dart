// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:inject_annotation/inject_annotation.dart';
import 'package:material_ui/material_ui.dart' show ThemeMode;
import 'package:zanshin_settings/zanshin_settings.dart';
import 'package:zanshin_shell/zanshin_shell.dart';

/// Mirrors the persisted theme choice onto the native chrome of every app window (the windows' background, the
/// traffic lights and their rings), which Flutter theming cannot reach: the shell applies the last choice to every app
/// window and to each one that becomes key later. A saved `dark` must style the native title bar after a relaunch,
/// not only Flutter.
@inject
@singleton
class WindowAppearanceSync {
  /// The sync over [_settings]' `appearance.themeMode`.
  WindowAppearanceSync(this._settings);

  final SettingsStore _settings;

  /// The mode last sent to the shell; null before [start].
  ThemeMode? _mirrored;

  /// On macOS: mirrors the persisted theme now, then every later change of it and nothing else.
  void start() {
    if (kIsWeb || !Platform.isMacOS) {
      return;
    }
    _mirror();
    _settings.addListener(_mirror);
  }

  void _mirror() {
    final ThemeMode mode = _settings.value.appearance.themeMode;
    if (mode == _mirrored) {
      return;
    }
    _mirrored = mode;
    unawaited(
      ZanshinShell.setWindowAppearance(switch (mode) {
        ThemeMode.light => WindowAppearance.light,
        ThemeMode.dark => WindowAppearance.dark,
        ThemeMode.system => WindowAppearance.system,
      }),
    );
  }
}
