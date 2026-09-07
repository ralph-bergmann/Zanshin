// SPDX-License-Identifier: MIT

import 'package:inject_annotation/inject_annotation.dart';

import 'settings_store.dart';

/// DI module handing a pre-loaded [SettingsStore] to the graph.
///
/// The store is loaded *before* the component exists —
/// `MainComponent.create(settingsModule: SettingsModule(store: await SettingsStore.open()))` —
/// so the graph stays synchronous: no `@asynchronous` provider, no `Future`
/// entry points, and `ViewModelFactory` chains stay plain.
@module
class SettingsModule {
  /// Wraps an already loaded [store].
  SettingsModule({required this.store});

  /// The store every consumer receives.
  final SettingsStore store;

  /// Provides the app-wide [SettingsStore].
  @provides
  @singleton
  SettingsStore settingsStore() => store;
}
