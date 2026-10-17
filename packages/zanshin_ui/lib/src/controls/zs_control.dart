// SPDX-License-Identifier: MIT

/// The marker every Zs control widget implements, so tools can recognise the controls without the package knowing
/// them: the app's shared Marionette configuration treats a widget that is a [ZsControl] as interactive (decision
/// 16.31).
///
/// Claude's proposal (Story 11.11): a marker interface keeps `zanshin_ui` free of `marionette_flutter`.
abstract interface class ZsControl {
  /// The control's `Semantics(identifier:)`, which agents match on (never coordinates); null for none.
  String? get identifier;
}
