// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:material_ui/material_ui.dart' show ThemeMode;
import 'package:zanshin_core/zanshin_core.dart' show ConfigEntry, ConfigScope, ConfigValueSource, WorkingCopyAuthor;
import 'package:zanshin_settings/zanshin_settings.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

import '../../l10n/strings.dart';
import '../window/window_zoom.dart';
import 'immutable_heads.dart' show tomlStringValue;
import 'settings_view_model.dart';
import 'settings_widgets.dart';

/// "From ‹scope› config" when [entry] comes from another layer than [own], else null (Story 11.7).
String? settingsSourceHint(AppLocalizations s, ConfigEntry? entry, ConfigValueSource own) {
  if (entry == null || entry.source == own) {
    return null;
  }
  return s.settingsFromScope(switch (entry.source) {
    ConfigValueSource.defaults => 'default', // l10n-ignore: jj's layer name
    ConfigValueSource.system => 'system', // l10n-ignore: jj's layer name
    ConfigValueSource.envBase || ConfigValueSource.envOverrides => 'environment', // l10n-ignore: jj's layer name
    ConfigValueSource.user => 'user', // l10n-ignore: jj's layer name
    ConfigValueSource.repo => 'repo', // l10n-ignore: jj's layer name
    ConfigValueSource.workspace => 'workspace', // l10n-ignore: jj's layer name
  });
}

/// The working-copy-author fact after an identity write (9.28), the command verbatim.
class SettingsAuthorFact extends StatelessWidget {
  /// The fact of [vm]'s last identity write, or nothing.
  const SettingsAuthorFact({required this.vm, super.key});

  /// The view model.
  final SettingsViewModel vm;

  @override
  Widget build(BuildContext context) {
    final WorkingCopyAuthor? author = vm.workingCopyAuthor;
    if (author == null) {
      return const SizedBox.shrink();
    }
    final ZsColors colors = ZsColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
      child: Text(
        context.l10n.settingsAuthorFact(
          author.name,
          author.email,
          'jj metaedit --update-author',
        ), // l10n-ignore: jj's command
        key: const ValueKey<String>('settings-author-fact'),
        style: ZsType.meta.copyWith(fontSize: ZsType.fsId, height: 1.45, color: colors.textDim),
      ),
    );
  }
}

/// Settings › General (Story 11.7): Appearance (Theme, Density, Accent colour), While you scroll (Hide controls),
/// Diffs (Layout, Changed words and jj's `diff.color-words.*` at user scope) and Identity (`user.name`, `user.email`
/// at user scope).
class SettingsGeneralTab extends StatelessWidget {
  /// The tab over [vm].
  const SettingsGeneralTab({required this.vm, super.key});

  /// The view model.
  final SettingsViewModel vm;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations s = context.l10n;
    final AppSettings prefs = vm.preferences;
    ConfigEntry? entry(String key) => vm.effective(key, project: false);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 18,
      children: <Widget>[
        SettingsGroup(
          title: s.settingsAppearance,
          children: <Widget>[
            SettingsRow(
              label: s.settingsTheme,
              child: ZsSegmented<ThemeMode>(
                variant: ZsSegmentedVariant.inset,
                label: s.settingsTheme,
                identifier: 'settings-theme',
                segments: <ZsSegment<ThemeMode>>[
                  ZsSegment<ThemeMode>(value: ThemeMode.light, label: s.settingsThemePaper, icon: ZI.sun),
                  ZsSegment<ThemeMode>(value: ThemeMode.dark, label: s.settingsThemeNight, icon: ZI.moon),
                  ZsSegment<ThemeMode>(value: ThemeMode.system, label: s.settingsThemeAuto, icon: ZI.auto),
                ],
                value: prefs.appearance.themeMode,
                onChanged: vm.setThemeMode,
              ),
            ),
            SettingsRow(
              label: s.settingsDensity,
              hint: s.settingsDensityHint,
              child: ZsSegmented<DensitySetting>(
                variant: ZsSegmentedVariant.inset,
                label: s.settingsDensity,
                identifier: 'settings-density',
                segments: <ZsSegment<DensitySetting>>[
                  ZsSegment<DensitySetting>(value: DensitySetting.compact, label: s.settingsDensityCompact),
                  ZsSegment<DensitySetting>(value: DensitySetting.balanced, label: s.settingsDensityBalanced),
                  ZsSegment<DensitySetting>(value: DensitySetting.comfy, label: s.settingsDensityComfy),
                ],
                value: prefs.appearance.density,
                onChanged: (density) =>
                    vm.updatePreferences((settings) => settings.copyWith.appearance(density: density)),
              ),
            ),
            SettingsRow(
              label: s.settingsZoom,
              hint: s.settingsZoomHint,
              child: ZsSelect<int>(
                label: s.settingsZoom,
                identifier: 'settings-zoom',
                options: <ZsSelectEntry<int>>[
                  for (final int step in zoomSteps)
                    ZsSelectOption<int>(
                      value: step,
                      label: step == zoomActualSize ? s.settingsZoomActualSize : s.settingsZoomStep(step),
                    ),
                ],
                value: zoomStepOf(prefs.appearance.zoom),
                onChanged: (zoom) => vm.updatePreferences((settings) => settings.copyWith.appearance(zoom: zoom)),
              ),
            ),
            SettingsRow(
              label: s.settingsAccent,
              hint: s.settingsAccentHint,
              child: ZsSegmented<AccentSource>(
                variant: ZsSegmentedVariant.inset,
                label: s.settingsAccent,
                identifier: 'settings-accent',
                segments: <ZsSegment<AccentSource>>[
                  ZsSegment<AccentSource>(value: AccentSource.followMacOS, label: s.settingsAccentMacOS),
                  ZsSegment<AccentSource>(value: AccentSource.zanshin, label: s.settingsAccentZanshin),
                ],
                value: prefs.appearance.accentSource,
                onChanged: (source) =>
                    vm.updatePreferences((settings) => settings.copyWith.appearance(accentSource: source)),
              ),
            ),
          ],
        ),
        SettingsGroup(
          title: s.settingsWhileScrolling,
          children: <Widget>[
            SettingsRow(
              label: s.settingsHideControls,
              hint: s.settingsHideControlsHint,
              child: ZsSwitch(
                label: s.settingsHideControlsSwitch,
                identifier: 'settings-hide-controls',
                value: prefs.general.hideControls,
                onChanged: (hide) => vm.updatePreferences((settings) => settings.copyWith.general(hideControls: hide)),
              ),
            ),
          ],
        ),
        SettingsGroup(
          title: s.settingsDiffs,
          children: <Widget>[
            SettingsRow(
              label: s.settingsDiffLayout,
              child: ZsSegmented<DiffLayoutSetting>(
                variant: ZsSegmentedVariant.inset,
                label: s.settingsDiffLayoutLabel,
                identifier: 'settings-diff-layout',
                segments: <ZsSegment<DiffLayoutSetting>>[
                  ZsSegment<DiffLayoutSetting>(value: DiffLayoutSetting.unified, label: s.settingsDiffUnified),
                  ZsSegment<DiffLayoutSetting>(value: DiffLayoutSetting.sideBySide, label: s.settingsDiffSideBySide),
                ],
                value: prefs.general.diffLayout,
                onChanged: (layout) =>
                    vm.updatePreferences((settings) => settings.copyWith.general(diffLayout: layout)),
              ),
            ),
            SettingsRow(
              label: s.settingsDiffMarks,
              hint: switch (prefs.general.diffMarks) {
                DiffMarksSetting.words => s.settingsDiffMarksZanshinHint,
                DiffMarksSetting.jj => s.settingsDiffMarksJjHint,
              },
              child: ZsSegmented<DiffMarksSetting>(
                variant: ZsSegmentedVariant.inset,
                label: s.settingsDiffMarksLabel,
                identifier: 'settings-diff-marks',
                segments: <ZsSegment<DiffMarksSetting>>[
                  ZsSegment<DiffMarksSetting>(value: DiffMarksSetting.words, label: s.settingsDiffMarksZanshin),
                  ZsSegment<DiffMarksSetting>(value: DiffMarksSetting.jj, label: s.settingsDiffMarksJj),
                ],
                value: prefs.general.diffMarks,
                onChanged: (marks) => vm.updatePreferences((settings) => settings.copyWith.general(diffMarks: marks)),
              ),
            ),
            _diffNumberRow(
              s,
              key: SettingsKeys.diffInline,
              label: s.settingsDiffInline,
              hint: switch (prefs.general.diffMarks) {
                DiffMarksSetting.words => s.settingsDiffInlineZanshinHint,
                DiffMarksSetting.jj => s.settingsDiffInlineHint,
              },
              identifier: 'settings-diff-inline',
              fallback: 3,
              min: -1,
              fixed: const <int>[0, 1, 2, 3, 5],
              optionLabel: (n) => switch (n) {
                0 => s.settingsDiffInlineNever,
                -1 => s.settingsDiffInlineAlways,
                _ => s.settingsDiffInlineUpTo(n),
              },
            ),
            _diffNumberRow(
              s,
              key: SettingsKeys.diffContext,
              label: s.settingsDiffContext,
              hint: s.settingsDiffContextHint,
              identifier: 'settings-diff-context',
              fallback: 3,
              min: 0,
              fixed: const <int>[0, 1, 2, 3, 5, 10, 20],
              optionLabel: (n) => '$n',
            ),
            _diffConflictRow(s),
          ],
        ),
        SettingsGroup(
          title: s.settingsIdentity,
          children: <Widget>[
            for (final (String key, String label, String id) in <(String, String, String)>[
              (SettingsKeys.userName, s.settingsName, 'settings-user-name'),
              (SettingsKeys.userEmail, s.settingsEmail, 'settings-user-email'),
            ])
              SettingsRow(
                label: label,
                hint: settingsSourceHint(s, entry(key), ConfigValueSource.user),
                configKey: key,
                child: SizedBox(
                  width: 240,
                  child: SettingsTextField(
                    value: vm.stringValue(key, project: false),
                    label: label,
                    identifier: id,
                    error: vm.errors[key],
                    register: vm.registerFlush,
                    unregister: vm.unregisterFlush,
                    onCommit: (text) => vm.setConfig(ConfigScope.user, key, text),
                  ),
                ),
              ),
          ],
        ),
        SettingsAuthorFact(vm: vm),
      ],
    );
  }

  /// [base] plus the source note (none for jj's defaults or the user config) and the open project's override note.
  String? _diffHint(AppLocalizations s, String key, String? base) {
    final ConfigEntry? entry = vm.effective(key, project: false);
    final String? source = entry?.source == ConfigValueSource.defaults
        ? null
        : settingsSourceHint(s, entry, ConfigValueSource.user);
    final String? project = vm.projectSetsOwn(key) ? s.settingsProjectSetsOwn : null;
    final String hint = <String?>[base, source, project].nonNulls.join(' ');
    return hint.isEmpty ? null : hint;
  }

  /// A write error, else "jj can't read …" while the raw value is unreadable.
  String? _diffError(AppLocalizations s, String key, {required bool unreadable}) =>
      vm.errors[key] ?? (unreadable ? s.settingsJjCantRead(vm.effective(key, project: false)?.value ?? '') : null);

  /// A `diff.color-words.*` integer row: [fixed] choices (with −1 last when [min] is −1), the effective value added in
  /// order when off the list; no entry is jj's [fallback], a value jj can't read chooses nothing.
  Widget _diffNumberRow(
    AppLocalizations s, {
    required String key,
    required String label,
    required String hint,
    required String identifier,
    required int fallback,
    required int min,
    required List<int> fixed,
    required String Function(int n) optionLabel,
  }) {
    final String? raw = vm.effective(key, project: false)?.value;
    // [fallback] mirrors jj-cli's built-in default at v0.47.0 and applies only when no layer lists the key.
    final int? parsed = raw == null ? fallback : int.tryParse(raw.trim());
    final int? value = parsed != null && parsed >= min ? parsed : null;
    final List<int> finite = <int>{...fixed, if (value != null && value >= 0) value}.toList()..sort();
    final choices = <int>[...finite, if (min < 0) -1];
    return SettingsRow(
      label: label,
      hint: _diffHint(s, key, hint),
      error: _diffError(s, key, unreadable: value == null),
      configKey: key,
      child: ZsSelect<int?>(
        label: label,
        identifier: identifier,
        options: <ZsSelectEntry<int?>>[
          for (final int n in choices) ZsSelectOption<int?>(value: n, label: optionLabel(n)),
        ],
        value: value,
        onChanged: (n) => unawaited(vm.setConfig(ConfigScope.user, key, '$n')),
      ),
    );
  }

  Widget _diffConflictRow(AppLocalizations s) {
    const String key = SettingsKeys.diffConflict;
    final String? raw = vm.effective(key, project: false)?.value;
    const materialize = 'materialize'; // l10n-ignore: jj's config value
    const pair = 'pair'; // l10n-ignore: jj's config value
    // `materialize` mirrors jj-cli's built-in default at v0.47.0 and applies only when no layer lists the key.
    final String? text = raw == null ? materialize : tomlStringValue(raw);
    final String? value = text == materialize || text == pair ? text : null;
    return SettingsRow(
      label: s.settingsDiffConflict,
      hint: _diffHint(s, key, switch (value) {
        materialize => s.settingsDiffConflictMaterializeHint,
        pair => s.settingsDiffConflictPairHint,
        _ => null,
      }),
      error: _diffError(s, key, unreadable: value == null),
      configKey: key,
      child: ZsSegmented<String?>(
        variant: ZsSegmentedVariant.inset,
        label: s.settingsDiffConflict,
        identifier: 'settings-diff-conflict',
        segments: <ZsSegment<String?>>[
          ZsSegment<String?>(value: materialize, label: s.settingsDiffConflictMaterialize),
          ZsSegment<String?>(value: pair, label: s.settingsDiffConflictPair),
        ],
        value: value,
        onChanged: (choice) => unawaited(vm.setConfig(ConfigScope.user, key, choice ?? materialize)),
      ),
    );
  }
}
