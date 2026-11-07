// SPDX-License-Identifier: MIT

import 'package:inject_annotation/inject_annotation.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

/// DI module handing the boot-loaded [IconRegistry] to the graph, like `SettingsModule(store:)`: the registry is
/// loaded before the component exists, so the graph stays synchronous.
@module
class IconModule {
  /// Wraps an already loaded [registry].
  IconModule({required this.registry});

  /// The registry every consumer receives.
  final IconRegistry registry;

  /// Provides the app-wide [IconRegistry].
  @provides
  @singleton
  IconRegistry iconRegistry() => registry;
}
