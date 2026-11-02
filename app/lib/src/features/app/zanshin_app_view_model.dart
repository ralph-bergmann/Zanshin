// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:inject_annotation/inject_annotation.dart';
import 'package:material_ui/material_ui.dart' show ThemeMode;
import 'package:zanshin_settings/zanshin_settings.dart';
import 'package:zanshin_shell/zanshin_shell.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

/// Theme state for the app root: the persisted [ThemeMode] and accent choice
/// plus the live macOS shell theme, resolved into the mode `MaterialApp` should
/// use and the [ZsAppearance] its windows show.
@inject
class ZanshinAppViewModel extends ChangeNotifier {
  ZanshinAppViewModel(this._settings) {
    // Changes from anywhere (another window, another widget) reach this VM.
    _settings.addListener(notifyListeners);
  }

  final SettingsStore _settings;
  ShellTheme? _shellTheme;
  StreamSubscription<ShellTheme>? _subscription;
  var _disposed = false;

  /// Last theme reported by the macOS shell; null until the platform answered.
  ShellTheme? get shellTheme => _shellTheme;

  /// The user's persisted choice (may be `system`).
  ThemeMode get selectedMode => _settings.value.appearance.themeMode;

  /// The Settings density, which the window roots turn into a text scale.
  DensitySetting get density => _settings.value.appearance.density;

  /// The mode `MaterialApp` should use.
  ///
  /// A forced mode wins outright; in system mode the shell channel is
  /// authoritative for day/night on macOS. The channel keeps reporting the
  /// SYSTEM value even while the window appearance is overridden (the
  /// override is per-window), so switching back to system stays correct.
  ThemeMode get effectiveMode {
    final ShellTheme? shellTheme = _shellTheme;
    return switch (selectedMode) {
      ThemeMode.system when shellTheme != null =>
        shellTheme.brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
      _ => selectedMode,
    };
  }

  /// What the app's windows show: the theme from [effectiveMode] (night until the shell resolves `system`; the window
  /// root follows the `MaterialApp`'s resolved brightness either way), the accent family from the Settings choice
  /// and the shell's report (decision 16.2; [ZsAccentFamily.resolve]), and the shell's accessibility flags.
  ///
  /// Full screen, the traffic-light block and the key status are per window: the window root (`ZanshinWindowRoot`)
  /// copies them in from its chrome report (Story 11.4) and from the active-window tracker (Story 11.12).
  ZsAppearance get appearance => ZsAppearance.fromShell(
    theme: effectiveMode == ThemeMode.light ? ZsTheme.paper : ZsTheme.night,
    accentSource: _settings.value.appearance.accentSource,
    shell: _shellTheme,
  );

  /// One-shot setup for `ViewModelBuilder`'s `init`.
  ///
  /// On macOS: start the shell-theme query and subscription (both unawaited,
  /// so the first frame renders immediately with Flutter's own brightness) and
  /// mirror the persisted choice onto the window chrome once — a saved `dark`
  /// must style the native title bar after a relaunch, not only Flutter.
  void init() {
    if (!_onMacOS) {
      return;
    }
    unawaited(ZanshinShell.getTheme().then(_applyShellTheme));
    _subscription = ZanshinShell.onThemeChanged.listen(_applyShellTheme);
    _mirrorWindowAppearance(selectedMode);
  }

  /// Persists [mode] and mirrors it onto the native window chrome of every app
  /// window (the windows' background, the traffic lights and their rings),
  /// which Flutter theming cannot reach; every window's root follows the store.
  ///
  /// Listeners are notified through the store; the returned future completes
  /// when the settings file has been written.
  Future<void> setThemeMode(ThemeMode mode) {
    final Future<void> written = _settings.update((s) => s.copyWith.appearance(themeMode: mode));
    _mirrorWindowAppearance(mode);
    return written;
  }

  @override
  void dispose() {
    _disposed = true;
    _settings.removeListener(notifyListeners);
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  static bool get _onMacOS => !kIsWeb && Platform.isMacOS;

  void _applyShellTheme(ShellTheme theme) {
    // A late getTheme() answer after dispose must not notify a disposed notifier;
    // an unchanged report (the plugin emits on several notifications) rebuilds nothing.
    if (_disposed || theme == _shellTheme) {
      return;
    }
    _shellTheme = theme;
    notifyListeners();
  }

  void _mirrorWindowAppearance(ThemeMode mode) {
    if (!_onMacOS) {
      return;
    }
    unawaited(
      ZanshinShell.setWindowAppearance(switch (mode) {
        ThemeMode.light => WindowAppearance.light,
        ThemeMode.dark => WindowAppearance.dark,
        ThemeMode.system => WindowAppearance.system,
      }),
    );
  }
}
