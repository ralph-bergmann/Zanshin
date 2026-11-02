// SPDX-License-Identifier: MIT

import 'package:freezed_annotation/freezed_annotation.dart';

part 'graph_settings.freezed.dart';
part 'graph_settings.g.dart';

/// The graph's layout mode (Story 10.7): Free (rows follow commit time) or Compact (rows = dependency depth).
enum GraphLayoutSetting {
  /// Rows follow commit time (the default).
  free,

  /// Rows = dependency depth.
  compact,
}

/// The graph's View options (Story 10.7 item 7), app-global: the layout, the card detail, stack grouping and the card
/// width.
@freezed
abstract class GraphSettings with _$GraphSettings {
  /// Creates graph settings; omitted fields take the design's defaults.
  const factory GraphSettings({
    /// The layout mode; [GraphLayoutSetting.free] by default.
    @Default(GraphLayoutSetting.free) GraphLayoutSetting layout,

    /// Detailed (62 px) or compact (40 px) cards; detailed by default.
    @Default(true) bool detailedCards,

    /// Whether linear runs of changes collapse into stack cards; on by default.
    @Default(true) bool groupStacks,

    /// The card width, 240 by default (160–400; the app clamps it where it uses it).
    @Default(240) double cardWidth,

    /// The jj log configurations (Story 10.22), in search-menu order (the default search leads the menu, the rest keep this order); global, not per repository.
    @Default(<RevsetConfiguration>[]) List<RevsetConfiguration> revsetConfigs,

    /// The default search: `log` (the built-in `jj log`), `all` (`all()`) or a [RevsetConfiguration.id]. An id no
    /// configuration has reads as `log` ([effectiveRevsetDefault]).
    @Default(revsetDefaultLog) String revsetDefault,
  }) = _GraphSettings;

  const GraphSettings._();

  /// Decodes from JSON; throws [CheckedFromJsonException] on a malformed document.
  factory GraphSettings.fromJson(Map<String, Object?> json) => _$GraphSettingsFromJson(json);

  /// [revsetDefault], with an id no configuration has read as [revsetDefaultLog].
  String get effectiveRevsetDefault =>
      revsetDefault == revsetDefaultLog ||
          revsetDefault == revsetDefaultAll ||
          revsetConfigs.any((c) => c.id == revsetDefault)
      ? revsetDefault
      : revsetDefaultLog;
}

/// [GraphSettings.revsetDefault] naming the built-in `jj log`.
const revsetDefaultLog = 'log';

/// [GraphSettings.revsetDefault] naming the built-in `all()`.
const revsetDefaultAll = 'all';

/// How a configuration joins its rules (Story 10.22).
enum RevsetCombine {
  /// ` & ` — every rule must match.
  and,

  /// ` | ` — any rule may match.
  or,
}

/// A configuration rule's revset function (Story 10.22).
enum RevsetRuleFunction {
  /// `author(…)`.
  author,

  /// `committer(…)`.
  committer,

  /// `mine()`.
  mine,

  /// `subject(…)`.
  subject,

  /// `description(…)`.
  description,

  /// `files(…)`.
  files,

  /// Free revset text, verbatim (Story 10.28); its rule's mode and case flag are ignored.
  revset,
}

/// A rule's match mode (Story 10.22): the text kinds for the text functions, the path kinds for `files`.
enum RevsetRuleMode {
  /// `substring:` — contains.
  substring,

  /// `exact:` — is exactly.
  exact,

  /// `glob:` — matches glob (text and files).
  glob,

  /// `regex:` — matches regex.
  regex,

  /// `cwd:` — path or folder (files only).
  prefix,

  /// `file:` — exact file (files only).
  file,
}

/// One saved jj log configuration (Story 10.22): a name and structured rules joined by [op].
@freezed
abstract class RevsetConfiguration with _$RevsetConfiguration {
  /// Creates configuration [id] named [name].
  const factory RevsetConfiguration({
    /// Its key, stable across renames.
    required String id,

    /// The name the search menu and the window show; may be empty ("Unnamed").
    @Default('') String name,

    /// How [rules] combine; `&` by default.
    @Default(RevsetCombine.and) RevsetCombine op,

    /// The rules, in order.
    @Default(<RevsetRule>[]) List<RevsetRule> rules,
  }) = _RevsetConfiguration;

  /// Decodes from JSON; throws [CheckedFromJsonException] on a malformed document.
  factory RevsetConfiguration.fromJson(Map<String, Object?> json) => _$RevsetConfigurationFromJson(json);
}

/// One rule of a [RevsetConfiguration] (Story 10.22).
@freezed
abstract class RevsetRule with _$RevsetRule {
  /// Creates a rule on [fn].
  const factory RevsetRule({
    /// The revset function.
    required RevsetRuleFunction fn,

    /// The match mode; ignored for `mine`.
    @Default(RevsetRuleMode.substring) RevsetRuleMode mode,

    /// The value; ignored for `mine`. A blank value drops the rule from the expression.
    @Default('') String value,

    /// Case-insensitive (`-i`); ignored for `mine` and `files`.
    @Default(false) bool ci,

    /// Negated (`~`).
    @Default(false) bool not,
  }) = _RevsetRule;

  /// Decodes from JSON; throws [CheckedFromJsonException] on a malformed document.
  factory RevsetRule.fromJson(Map<String, Object?> json) => _$RevsetRuleFromJson(json);
}
