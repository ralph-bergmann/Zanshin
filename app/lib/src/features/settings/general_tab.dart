// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:material_ui/material_ui.dart' show ThemeMode;
import 'package:zanshin_core/zanshin_core.dart' show ConfigEntry, ConfigScope, ConfigValueSource, WorkingCopyAuthor;
import 'package:zanshin_settings/zanshin_settings.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

import '../../l10n/strings.dart';
import '../graph/inspector_diff.dart' show diffContextChoices, diffWhitespaceLabel;
import '../graph/project_files.dart' show detectedEditors, editorLaunchers;
import '../window/window_zoom.dart';
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
/// Diffs (Layout, the Changed words switch, jj's `diff.color-words.max-inline-alternation` and `.context` at user
/// scope, and the inspector's File list, Story 10.39), Editor (Story 10.39) and Identity (`user.name`, `user.email` at
/// user scope).
class SettingsGeneralTab extends StatelessWidget {
  /// The tab over [vm]; [editors] answers the launchers on the login shell's `PATH`.
  const SettingsGeneralTab({required this.vm, this.editors = detectedEditors, super.key});

  /// The view model.
  final SettingsViewModel vm;

  /// The editor launchers found on the login shell's `PATH` ([detectedEditors] in the app).
  final List<String> Function() editors;

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
              label: s.settingsDiffWhitespace,
              child: ZsSelect<DiffWhitespaceSetting>(
                label: s.settingsDiffWhitespace,
                identifier: 'settings-diff-whitespace',
                options: <ZsSelectEntry<DiffWhitespaceSetting>>[
                  for (final DiffWhitespaceSetting setting in DiffWhitespaceSetting.values)
                    ZsSelectOption<DiffWhitespaceSetting>(value: setting, label: diffWhitespaceLabel(s, setting)),
                ],
                value: prefs.general.diffWhitespace,
                onChanged: (whitespace) =>
                    vm.updatePreferences((settings) => settings.copyWith.general(diffWhitespace: whitespace)),
              ),
            ),
            SettingsRow(
              label: s.settingsDiffWordMarks,
              hint: s.settingsDiffWordMarksHint,
              child: ZsSwitch(
                label: s.settingsDiffWordMarksSwitch,
                identifier: 'settings-diff-marks',
                value: prefs.general.diffWordMarks,
                onChanged: (on) => vm.updatePreferences((settings) => settings.copyWith.general(diffWordMarks: on)),
              ),
            ),
            _diffNumberRow(
              s,
              key: SettingsKeys.diffInline,
              label: s.settingsDiffInline,
              hint: s.settingsDiffInlineHint,
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
              fixed: diffContextChoices,
              optionLabel: (n) => '$n',
            ),
            SettingsRow(
              label: s.settingsDiffFileList,
              child: ZsSegmented<DiffFileListSetting>(
                variant: ZsSegmentedVariant.inset,
                label: s.settingsDiffFileList,
                identifier: 'settings-diff-file-list',
                segments: <ZsSegment<DiffFileListSetting>>[
                  ZsSegment<DiffFileListSetting>(value: DiffFileListSetting.flat, label: s.settingsDiffFileListFlat),
                  ZsSegment<DiffFileListSetting>(value: DiffFileListSetting.tree, label: s.settingsDiffFileListTree),
                ],
                value: prefs.general.diffFileList,
                onChanged: (list) => vm.updatePreferences((settings) => settings.copyWith.general(diffFileList: list)),
              ),
            ),
          ],
        ),
        _EditorGroup(vm: vm, editor: prefs.general.editor, detect: editors),
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
}

/// Settings › General › Editor (Story 10.39; Claude's proposal in the style of the rows): "Open files in" chooses
/// None, a launcher found on the login shell's `PATH` (the stored one even when not found) or "Custom command"; with
/// Custom a "Command" row takes the command line, refused without `{file}`. Choosing Custom writes nothing until a
/// command is committed.
class _EditorGroup extends StatefulWidget {
  const _EditorGroup({required this.vm, required this.editor, required this.detect});

  final SettingsViewModel vm;
  final String? editor;
  final List<String> Function() detect;

  @override
  State<_EditorGroup> createState() => _EditorGroupState();
}

class _EditorGroupState extends State<_EditorGroup> {
  late final List<String> _found = widget.detect();

  /// Custom was chosen and no command is stored yet.
  var _custom = false;

  static const _none = 'none';
  static const _customChoice = 'custom';
  static const _file = '{file}'; // l10n-ignore: the marker a command holds
  static const _line = '{line}'; // l10n-ignore: the marker a command holds

  static String _appOf(String launcher) => switch (launcher) {
    'idea' => 'IntelliJ IDEA', // l10n-ignore: a product name
    'code' => 'VS Code', // l10n-ignore: a product name
    _ => 'Zed', // l10n-ignore: a product name
  };

  void _write(String? editor) => widget.vm.updatePreferences((settings) => settings.copyWith.general(editor: editor));

  @override
  Widget build(BuildContext context) {
    final AppLocalizations s = context.l10n;
    final String? editor = widget.editor;
    final bool launcher = editorLaunchers.contains(editor);
    final bool custom = _custom || (editor != null && !launcher);
    final launchers = <String>[
      for (final String each in editorLaunchers)
        if (_found.contains(each) || each == editor) each,
    ];
    return SettingsGroup(
      title: s.settingsEditor,
      children: <Widget>[
        SettingsRow(
          label: s.settingsEditorOpenIn,
          child: ZsSelect<String>(
            label: s.settingsEditorOpenIn,
            identifier: 'settings-editor',
            options: <ZsSelectEntry<String>>[
              ZsSelectOption<String>(value: _none, label: s.settingsEditorNone),
              for (final String each in launchers)
                ZsSelectOption<String>(value: each, label: s.settingsEditorLauncher(_appOf(each), each)),
              ZsSelectOption<String>(value: _customChoice, label: s.settingsEditorCustom),
            ],
            value: custom ? _customChoice : (editor ?? _none),
            onChanged: (choice) {
              setState(() => _custom = choice == _customChoice);
              // Custom writes once its command is committed; until then the stored editor stays.
              if (choice != _customChoice) {
                _write(choice == _none ? null : choice);
              }
            },
          ),
        ),
        if (custom)
          SettingsRow(
            label: s.settingsEditorCommand,
            hint: s.settingsEditorCommandHint(_file, _line),
            child: SizedBox(
              width: 240,
              child: SettingsTextField(
                value: launcher ? '' : editor,
                label: s.settingsEditorCommand,
                identifier: 'settings-editor-command',
                mono: true,
                register: widget.vm.registerFlush,
                unregister: widget.vm.unregisterFlush,
                validate: (text) async => text.contains(_file) ? null : s.settingsEditorCommandNoFile(_file),
                onCommit: (text) async {
                  _write(text);
                  return true;
                },
              ),
            ),
          ),
      ],
    );
  }
}
