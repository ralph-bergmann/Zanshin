// SPDX-License-Identifier: MIT

import 'package:zanshin/src/features/window/app_window_actions.dart';

/// [AppWindowActions] that records what was asked: the windows opened and every Settings target.
class FakeWindowActions implements AppWindowActions {
  var projects = 0;
  var configurations = 0;

  /// Every `openSettings` call's target, in order.
  final settings = <SettingsTarget?>[];

  @override
  Future<void> openProjects() async => projects++;

  @override
  Future<void> openRevsetConfigs() async => configurations++;

  @override
  Future<void> openSettings({SettingsTarget? target}) async => settings.add(target);
}
