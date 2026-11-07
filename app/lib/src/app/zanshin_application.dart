// SPDX-License-Identifier: MIT

import 'package:inject_annotation/inject_annotation.dart';
import 'package:zanshin_settings/zanshin_settings.dart';

import '../features/window/app_windows.dart';
import '../features/window/window_appearance_sync.dart';
import '../features/window/window_zoom.dart';
import 'app_exit_handler.dart';
import 'app_window_coordinator.dart';
import 'boot/zanshin_bootstrap.dart';
import 'menu/app_menu.dart';

/// The app over its DI graph: what the boot starts once the graph exists.
///
/// The window coordinator (Story 11.12) decides the first window, reopens the last open project without holding up
/// the boot (Story 11.5) and keeps the windows in step with the open project; the menu bar's model (Story 11.13) acts
/// on the windows and the coordinator.
@inject
@singleton
class ZanshinApplication {
  /// The app over its [_coordinator], its [menu], the [_settings], the app's [_windows], the [_exitHandler] and the
  /// [_appearance] sync.
  ZanshinApplication(this._coordinator, this.menu, this._settings, this._windows, this._exitHandler, this._appearance);

  final AppWindowCoordinator _coordinator;

  /// The menu bar's model, which the boot's window host shows above every window.
  final AppMenuModel menu;

  final SettingsStore _settings;
  final AppWindows _windows;
  final AppExitHandler _exitHandler;
  final WindowAppearanceSync _appearance;

  /// Starts the app and answers its first window: the windows follow the stored zoom (Story 11.20) from before the
  /// first window, which is created at it, for the app's life; ⌘Q asks the close guards and closes the worker; the
  /// native chrome follows the theme; then the coordinator starts.
  BootFirstWindow start() {
    bindWindowZoom(_settings, _windows);
    _exitHandler.start();
    _appearance.start();
    return _coordinator.start();
  }
}
