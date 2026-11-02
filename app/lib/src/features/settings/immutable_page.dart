// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:zanshin_core/zanshin_core.dart' show RevsetCount;
import 'package:zanshin_ui/zanshin_ui.dart';

import '../../l10n/strings.dart';
import '../graph/hatch_swatch.dart';
import 'immutable_heads.dart';
import 'project_tab.dart' show immutableCountText;
import 'settings_view_model.dart';
import 'settings_widgets.dart';

/// Settings › Project › Immutable commits (Story 11.7; DS components/settings/ImmutablePage.*): the effective
/// `revset-aliases."immutable_heads()"` as switches, bookmark chips and a custom revset, the TOML as written, the
/// immutable count, and Reset to jj's default. Every change writes at repo scope at once.
class SettingsImmutablePage extends StatelessWidget {
  /// The page over [vm], back to [project] through [onBack].
  const SettingsImmutablePage({required this.vm, required this.project, required this.onBack, super.key});

  /// The view model.
  final SettingsViewModel vm;

  /// The project's name, the back button's.
  final String project;

  /// Back to the Project tab.
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations s = context.l10n;
    final ZsColors colors = ZsColors.of(context);
    final ImmutableHeads heads = vm.immutableHeads;
    void write(ImmutableHeads next) => unawaited(vm.writeImmutable(next));
    Widget builtin(int index, String label, String hint, String id) {
      final String term = immutableBuiltins[index];
      return SettingsRow(
        label: label,
        hint: hint,
        configKey: term,
        child: ZsSwitch(
          label: label,
          identifier: id,
          value: heads.builtins.contains(term),
          onChanged: (on) =>
              write(heads.copyWith(builtins: <String>{...heads.builtins.where((t) => t != term), if (on) term})),
        ),
      );
    }

    final String trunk = vm.stringValue(trunkKey, project: true) ?? s.settingsTrunkDefault;
    final choices = <String>[
      for (final String name in vm.bookmarks)
        if (!heads.bookmarks.contains(name)) name,
    ];
    final String expr = heads.compose();
    final RevsetCount? count = vm.immutableCount;
    final TextStyle toml = ZsType.command.copyWith(height: 1.6, color: colors.textMuted);
    return SettingsPage(
      back: project,
      onBack: onBack,
      title: s.settingsImmutableTitle,
      intro: s.settingsImmutableIntro,
      children: <Widget>[
        SettingsGroup(
          title: s.settingsImmutableBuiltIn,
          meta: builtinImmutableHeads,
          children: <Widget>[
            builtin(0, s.settingsImmutableTrunk, s.settingsImmutableTrunkHint(trunk), 'settings-immutable-trunk'),
            builtin(1, s.settingsImmutableTags, s.settingsImmutableTagsHint, 'settings-immutable-tags'),
            builtin(
              2,
              s.settingsImmutableRemoteBookmarks,
              s.settingsImmutableRemoteBookmarksHint,
              'settings-immutable-remote-bookmarks',
            ),
            builtin(
              3,
              s.settingsImmutableRemoteTags,
              s.settingsImmutableRemoteTagsHint,
              'settings-immutable-remote-tags',
            ),
          ],
        ),
        SettingsGroup(
          title: s.settingsImmutableAlso,
          children: <Widget>[
            SettingsRow(
              label: s.settingsImmutableOthers,
              hint: s.settingsImmutableOthersHint,
              configKey: 'trunk().. & ~mine()', // l10n-ignore: jj's revset
              child: ZsSwitch(
                label: s.settingsImmutableOthers,
                identifier: 'settings-immutable-others',
                value: heads.others,
                onChanged: (on) => write(heads.copyWith(others: on)),
              ),
            ),
            SettingsRow(
              label: s.settingsImmutableBookmarks,
              hint: s.settingsImmutableBookmarksHint,
              stack: true,
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: <Widget>[
                  for (final String name in heads.bookmarks)
                    ZsChip(
                      label: name,
                      kind: ZsChipKind.filter,
                      mono: true,
                      identifier: 'settings-immutable-chip-$name',
                      onRemove: () =>
                          write(heads.copyWith(bookmarks: <String>[...heads.bookmarks.where((b) => b != name)])),
                    ),
                  ZsMenuAnchor(
                    identifier: 'settings-immutable-add-menu',
                    semanticLabel: s.settingsImmutableAddBookmark,
                    entries: <ZsMenuEntry>[
                      for (final String name in choices)
                        ZsMenuItem(
                          label: name,
                          mono: true,
                          identifier: 'settings-immutable-add-$name',
                          onSelected: () => write(heads.copyWith(bookmarks: <String>[...heads.bookmarks, name])),
                        ),
                    ],
                    builder: (context, controller) => ZsChip(
                      label: s.settingsImmutableAddBookmark,
                      kind: ZsChipKind.add,
                      identifier: 'settings-immutable-add',
                      onPressed: choices.isEmpty ? null : controller.open,
                    ),
                  ),
                ],
              ),
            ),
            SettingsRow(
              label: s.settingsImmutableCustom,
              hint: s.settingsImmutableCustomHint,
              stack: true,
              child: SettingsTextField(
                value: heads.custom,
                label: s.settingsImmutableCustom,
                mono: true,
                placeholder: 'description(glob:"hotfix:*")', // l10n-ignore: jj's revset
                identifier: 'settings-immutable-custom',
                error: vm.errors[immutableHeadsKey],
                register: vm.registerFlush,
                unregister: vm.unregisterFlush,
                validate: (text) async => text.trim().isEmpty ? null : vm.revsetError(text.trim()),
                onCommit: (text) => vm.writeImmutable(heads.copyWith(custom: text.trim())),
              ),
            ),
          ],
        ),
        SettingsGroup(
          title: s.settingsImmutableResult,
          bare: true,
          children: <Widget>[
            DecoratedBox(
              decoration: BoxDecoration(
                color: colors.codeBg,
                border: Border.all(color: colors.flBorder),
                borderRadius: BorderRadius.circular(ZsMetrics.of(context).radiusWell),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  spacing: 10,
                  children: <Widget>[
                    Text.rich(
                      key: const ValueKey<String>('settings-immutable-toml'),
                      TextSpan(
                        style: toml,
                        children: <InlineSpan>[
                          const TextSpan(text: '[revset-aliases]\n'), // l10n-ignore: TOML
                          TextSpan(
                            text: '"immutable_heads()"', // l10n-ignore: jj's config key
                            style: toml.copyWith(color: colors.text),
                          ),
                          TextSpan(text: ' = ${tomlString(expr)}'),
                        ],
                      ),
                    ),
                    if (count != null)
                      Row(
                        spacing: 6,
                        children: <Widget>[
                          const HatchSwatch(),
                          Flexible(
                            child: Text.rich(
                              key: const ValueKey<String>('settings-immutable-result-count'),
                              TextSpan(
                                style: ZsType.secondary.copyWith(color: colors.textDim),
                                children: <InlineSpan>[
                                  TextSpan(
                                    text: immutableCountText(s, count),
                                    style: TextStyle(color: colors.text, fontWeight: FontWeight.w600),
                                  ),
                                  TextSpan(text: ' ${s.settingsImmutableCountSuffix(count.n)}'),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 10, 4, 0),
              child: Row(
                spacing: 12,
                children: <Widget>[
                  Expanded(
                    child: Text(
                      s.settingsImmutableRootNote('root()', '--ignore-immutable'), // l10n-ignore: jj's words
                      style: ZsType.meta.copyWith(fontSize: ZsType.fsId, height: 1.45, color: colors.textDim),
                    ),
                  ),
                  // `jj config unset --repo` only reaches an alias in the repo config.
                  if (!heads.isDefault && vm.hasRepoValue(immutableHeadsKey))
                    ZsButton(
                      label: s.settingsImmutableReset,
                      size: ZsButtonSize.md,
                      identifier: 'settings-immutable-reset',
                      onPressed: () => unawaited(vm.resetImmutable()),
                    ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }
}
