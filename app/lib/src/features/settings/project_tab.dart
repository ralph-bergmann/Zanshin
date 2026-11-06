// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:intl/intl.dart' show NumberFormat;
import 'package:zanshin_core/zanshin_core.dart' show ConfigEntry, ConfigScope, ConfigValueSource, RevsetCount;
import 'package:zanshin_settings/zanshin_settings.dart' show RemotePollSetting;
import 'package:zanshin_ui/zanshin_ui.dart';

import '../../l10n/strings.dart';
import '../graph/hatch_swatch.dart';
import 'general_tab.dart';
import 'immutable_heads.dart';
import 'remotes_group.dart';
import 'settings_view_model.dart';
import 'settings_widgets.dart';

/// [count] as the Immutable commits rows show it: "10,000+" when capped.
String immutableCountText(AppLocalizations s, RevsetCount count) {
  final String n = NumberFormat.decimalPattern(s.localeName).format(count.n);
  return count.capped ? '$n+' : n;
}

/// The Immutable commits row's summary of [heads] in words (DS ImmutablePage.jsx `zsImmSummary`).
String immutableSummary(AppLocalizations s, ImmutableHeads heads) {
  final bool all = immutableBuiltins.every(heads.builtins.contains);
  final names = <String>[
    if (all)
      s.settingsImmutableSummaryDefault
    else ...<String>[
      if (heads.builtins.contains(immutableBuiltins[0])) s.settingsImmutableSummaryTrunk,
      if (heads.builtins.contains(immutableBuiltins[1])) s.settingsImmutableSummaryTags,
      if (heads.builtins.contains(immutableBuiltins[2])) s.settingsImmutableSummaryRemoteBookmarks,
      if (heads.builtins.contains(immutableBuiltins[3])) s.settingsImmutableSummaryRemoteTags,
    ],
    if (heads.others) s.settingsImmutableSummaryOthers,
    ...heads.bookmarks,
    if (heads.custom.trim().isNotEmpty) s.settingsImmutableSummaryCustom,
  ];
  if (names.isEmpty) {
    return s.settingsImmutableSummaryNone;
  }
  final String text = names.join(', ');
  // Only a localized label is capitalized, never a bookmark name (nor jj's default, which starts with "jj").
  final bool labelFirst = !all && (heads.builtins.isNotEmpty || heads.others || heads.bookmarks.isEmpty);
  return labelFirst ? text[0].toUpperCase() + text.substring(1) : text;
}

/// `HatchSwatch` and the immutable count, the Immutable commits row's value.
class ImmutableCount extends StatelessWidget {
  /// The count of [count], nothing without one.
  const ImmutableCount({required this.count, super.key});

  /// The count, or null.
  final RevsetCount? count;

  @override
  Widget build(BuildContext context) {
    final RevsetCount? count = this.count;
    return Row(
      mainAxisSize: MainAxisSize.min,
      spacing: 6,
      children: <Widget>[
        const HatchSwatch(),
        if (count != null)
          Text(
            immutableCountText(context.l10n, count),
            key: const ValueKey<String>('settings-immutable-count'),
            style: ZsType.command.copyWith(color: ZsColors.of(context).textMuted),
          ),
      ],
    );
  }
}

/// Settings › Project (Story 11.7): Remotes (the remote list with its verbs, Story 11.18; Fetch from `git.fetch`, Push
/// to `git.push`, Check for remote changes),
/// History (Trunk `revset-aliases."trunk()"`, Immutable commits ›) and Identity (a repo-scope `user.email`).
class SettingsProjectTab extends StatefulWidget {
  /// The tab over [vm]; [onImmutableCommits] opens the page.
  const SettingsProjectTab({required this.vm, required this.onImmutableCommits, super.key});

  /// The view model.
  final SettingsViewModel vm;

  /// Opens the Immutable commits page.
  final VoidCallback onImmutableCommits;

  @override
  State<SettingsProjectTab> createState() => _SettingsProjectTabState();
}

class _SettingsProjectTabState extends State<SettingsProjectTab> {
  var _customTrunk = false;

  SettingsViewModel get vm => widget.vm;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations s = context.l10n;
    ConfigEntry? entry(String key) => vm.effective(key, project: true);
    final bool ownEmail = vm.hasRepoValue(SettingsKeys.userEmail);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 18,
      children: <Widget>[
        SettingsRemotesGroup(
          vm: vm,
          children: <Widget>[
            _remoteRow(s, s.settingsFetchFrom, SettingsKeys.gitFetch, vm.fetchDefault, 'settings-git-fetch'),
            _remoteRow(s, s.settingsPushTo, SettingsKeys.gitPush, vm.pushDefault, 'settings-git-push'),
            SettingsRow(
              label: s.settingsRemotePoll,
              child: ZsSegmented<RemotePollSetting>(
                variant: ZsSegmentedVariant.inset,
                label: s.settingsRemotePoll,
                identifier: 'settings-remote-poll',
                segments: <ZsSegment<RemotePollSetting>>[
                  ZsSegment<RemotePollSetting>(value: RemotePollSetting.off, label: s.settingsRemotePollOff),
                  ZsSegment<RemotePollSetting>(value: RemotePollSetting.fiveMinutes, label: s.settingsRemotePoll5),
                  ZsSegment<RemotePollSetting>(value: RemotePollSetting.fifteenMinutes, label: s.settingsRemotePoll15),
                ],
                value: vm.remotePoll,
                onChanged: vm.setRemotePoll,
              ),
            ),
          ],
        ),
        SettingsGroup(
          title: s.settingsHistory,
          children: <Widget>[
            _trunkRow(s, entry(trunkKey)),
            if (_customTrunk)
              SettingsRow(
                label: s.settingsTrunkCustom,
                stack: true,
                child: SettingsTextField(
                  value: vm.stringValue(trunkKey, project: true),
                  label: s.settingsTrunkCustom,
                  mono: true,
                  identifier: 'settings-trunk-custom',
                  register: vm.registerFlush,
                  unregister: vm.unregisterFlush,
                  validate: (text) async => text.trim().isEmpty ? null : vm.revsetError(text),
                  onCommit: (text) => text.trim().isEmpty
                      ? vm.unsetConfig(ConfigScope.repo, trunkKey)
                      : vm.setConfig(ConfigScope.repo, trunkKey, text.trim()),
                ),
              ),
            SettingsRow(
              label: s.settingsImmutableTitle,
              hint: immutableSummary(s, vm.immutableHeads),
              configKey: immutableHeadsKey,
              identifier: 'settings-immutable-commits',
              onOpen: widget.onImmutableCommits,
              child: ImmutableCount(count: vm.immutableCount),
            ),
          ],
        ),
        SettingsGroup(
          title: s.settingsIdentity,
          children: <Widget>[
            SettingsRow(
              label: s.settingsOwnEmail,
              hint: s.settingsOwnEmailHint,
              error: vm.errors[SettingsKeys.userEmail],
              child: ZsSwitch(
                label: s.settingsOwnEmailSwitch,
                identifier: 'settings-own-email',
                value: ownEmail,
                onChanged: (on) => unawaited(
                  on
                      ? vm.setConfig(
                          ConfigScope.repo,
                          SettingsKeys.userEmail,
                          vm.stringValue(SettingsKeys.userEmail, project: true) ?? '',
                        )
                      : vm.unsetConfig(ConfigScope.repo, SettingsKeys.userEmail),
                ),
              ),
            ),
            if (ownEmail)
              SettingsRow(
                label: s.settingsEmail,
                configKey: SettingsKeys.userEmail,
                child: SizedBox(
                  width: 240,
                  child: SettingsTextField(
                    value: vm.stringValue(SettingsKeys.userEmail, project: true),
                    label: s.settingsProjectEmail,
                    identifier: 'settings-project-email',
                    register: vm.registerFlush,
                    unregister: vm.unregisterFlush,
                    onCommit: (text) => vm.setConfig(ConfigScope.repo, SettingsKeys.userEmail, text),
                  ),
                ),
              ),
          ],
        ),
        SettingsAuthorFact(vm: vm),
      ],
    );
  }

  /// Fetch from / Push to: a select of the remotes while the value is one remote name or unset (unset shows the
  /// CLI's resolved default), else the value read-only as its TOML text.
  Widget _remoteRow(AppLocalizations s, String label, String key, List<String> resolved, String identifier) {
    final ConfigEntry? value = entry(key);
    final String? name = tomlStringValue(value?.value);
    final bool single = value == null || (name != null && !name.contains(':') && !name.contains('*'));
    final String? shown = value == null ? resolved.firstOrNull : name;
    final options = <String>[...vm.remotes, if (shown != null && !vm.remotes.contains(shown)) shown];
    final ZsColors colors = ZsColors.of(context);
    return SettingsRow(
      label: label,
      configKey: key,
      hint: settingsSourceHint(s, value, ConfigValueSource.repo),
      error: vm.errors[key],
      child: !single
          ? Text(
              value.value,
              key: ValueKey<String>('$identifier-text'),
              style: ZsType.command.copyWith(color: colors.textMuted),
            )
          : shown == null || options.isEmpty
          ? Text(s.settingsNoRemotes, style: ZsType.secondary.copyWith(color: colors.textDim))
          : ZsSelect<String>(
              label: label,
              mono: true,
              identifier: identifier,
              options: <ZsSelectEntry<String>>[
                for (final String remote in options)
                  ZsSelectOption<String>(
                    value: remote,
                    // jj doesn't rewrite git.fetch / git.push when the remote goes.
                    label: vm.remotes.contains(remote) ? remote : s.settingsNotARemote(remote),
                    mono: true,
                  ),
              ],
              value: shown,
              onChanged: (remote) {
                if (remote != shown) {
                  unawaited(vm.setConfig(ConfigScope.repo, key, remote));
                }
              },
            ),
    );
  }

  ConfigEntry? entry(String key) => vm.effective(key, project: true);

  /// Trunk: a select of the default fetch remote's bookmarks as `<name>@<remote>`, jj's default while unset, and
  /// Custom… for a mono field.
  Widget _trunkRow(AppLocalizations s, ConfigEntry? value) {
    final String? trunk = tomlStringValue(value?.value);
    final String shown = trunk ?? '';
    final choices = <String>[...vm.trunkChoices, if (trunk != null && !vm.trunkChoices.contains(trunk)) trunk];
    return SettingsRow(
      label: s.settingsTrunk,
      configKey: trunkKey,
      hint: settingsSourceHint(s, value, ConfigValueSource.repo),
      error: vm.errors[trunkKey],
      child: ZsSelect<String>(
        label: s.settingsTrunk,
        mono: true,
        identifier: 'settings-trunk',
        options: <ZsSelectEntry<String>>[
          if (trunk == null) ZsSelectOption<String>(value: '', label: s.settingsTrunkDefault),
          for (final String choice in choices) ZsSelectOption<String>(value: choice, label: choice, mono: true),
          const ZsSelectSeparator<String>(),
          ZsSelectCustom<String>(label: s.settingsTrunkCustomEllipsis),
        ],
        value: shown,
        onCustom: () => setState(() => _customTrunk = true),
        onChanged: (choice) {
          if (choice != shown && choice.isNotEmpty) {
            unawaited(vm.setConfig(ConfigScope.repo, trunkKey, choice));
          }
        },
      ),
    );
  }
}
