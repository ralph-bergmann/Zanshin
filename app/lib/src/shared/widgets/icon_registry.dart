// SPDX-License-Identifier: MIT

import 'package:flutter/widgets.dart';
import 'package:inject_annotation/inject_annotation.dart';
import 'package:vector_graphics/vector_graphics.dart';

import 'zanshin_icon.dart';

/// Every glyph of `assets/icons/svg/`, precompiled at build time by `vector_graphics_compiler` and decoded once
/// during the boot (decision 16.32), so a [ZanshinIcon] paints synchronously on its first frame.
///
/// The pictures live as long as the app; an icon edit needs a hot restart.
class IconRegistry {
  IconRegistry._(this._pictures);

  /// Loads every [ZI.all] glyph in parallel from the root asset bundle.
  static Future<IconRegistry> load() async {
    final List<MapEntry<String, PictureInfo>> entries = await Future.wait(<Future<MapEntry<String, PictureInfo>>>[
      for (final String name in ZI.all)
        vg.loadPicture(AssetBytesLoader('assets/icons/svg/$name.svg'), null).then((picture) => MapEntry(name, picture)),
    ]);
    return IconRegistry._(Map<String, PictureInfo>.fromEntries(entries));
  }

  final Map<String, PictureInfo> _pictures;

  /// The picture of the glyph [name], or null for a name the registry does not hold.
  PictureInfo? operator [](String name) => _pictures[name];
}

/// Provides the [IconRegistry] to every window: it sits above the window manager (Claude's proposal, Story 11.1), so
/// the dialog windows share it. Null until the boot has loaded it.
class IconRegistryScope extends InheritedWidget {
  /// Provides [registry] to [child].
  const IconRegistryScope({required this.registry, required super.child, super.key});

  /// The loaded registry, or null while the boot still loads it.
  final IconRegistry? registry;

  /// The nearest registry, or null.
  static IconRegistry? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<IconRegistryScope>()?.registry;

  @override
  bool updateShouldNotify(IconRegistryScope oldWidget) => !identical(registry, oldWidget.registry);
}

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
