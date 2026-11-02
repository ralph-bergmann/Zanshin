// SPDX-License-Identifier: MIT

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../widgetbook/catalogue.dart';

/// The DS manifest (`flutter test` runs in `app/`).
const _manifest = '../_bmad-output/implementation-artifacts/design_system/_ds_manifest.json';

/// DS components the catalogue shows, by the use case that shows them.
const _covered = <String, String>{
  'Button': 'controls/button/state-matrix',
  'IconButton': 'controls/iconbutton/state-matrix',
  'Icon': 'icons/glyphs/sizes',
  'NamiMark': 'projects/project-capsule/states',
  'Kbd': 'controls/kbd/state-matrix',
  'ProjectRow': 'projects/projects-window/tree',
  'Badge': 'controls/badge/state-matrix',
  'Chip': 'controls/chip/state-matrix',
  'ConfirmDialog': 'controls/confirmdialog/state-matrix',
  'Disclosure': 'controls/disclosure/state-matrix',
  'Link': 'controls/link/state-matrix',
  'Presence': 'controls/presence/state-matrix',
  'ProgressBar': 'controls/progressbar/state-matrix',
  'Radio': 'controls/radio/state-matrix',
  'RadioGroup': 'controls/radio/interactive',
  'ScrollArea': 'controls/scrollarea/state-matrix',
  'Skeleton': 'controls/skeleton/state-matrix',
  'Spinner': 'controls/spinner/state-matrix',
  'Tooltip': 'controls/tooltip/state-matrix',
  'Checkbox': 'controls/checkbox/state-matrix',
  'SearchField': 'controls/searchfield/state-matrix',
  'Segmented': 'controls/segmented/state-matrix',
  'Select': 'controls/select/state-matrix',
  'Slider': 'controls/slider/state-matrix',
  'Switch': 'controls/switch/state-matrix',
  'TextField': 'controls/textfield/state-matrix',
  'AtBadge': 'graph/card/states',
  'WorkspaceTag': 'graph/card/states',
  'BookmarkChip': 'graph/card/states',
  'ChangeCard': 'graph/card/states',
  'ChangeId': 'graph/card/states',
  'DayLabel': 'graph/viewport/recording',
  'DayAxis': 'graph/viewport/recording',
  'Flag': 'graph/card/states',
  'GraphPorts': 'graph/viewport/recording',
  'GraphEdge': 'graph/viewport/recording',
  'HatchSwatch': 'graph/card/states',
  'Menu': 'controls/menu/state-matrix',
  'ProjectMenu': 'projects/project-capsule/menu-open',
  'DragGhost': 'materials/drag-ghost/kinds',
  'StaleNotice': 'graph/stale-notice/variants',
  'Callout': 'materials/menu-material/with-and-without-arrow',
  'Dialog': 'windows/projects-window/projects-window',
  'Island': 'materials/island/shapes',
  'IslandSeparator': 'materials/island/shapes',
  'Popover': 'controls/popover/state-matrix',
  'PopoverHeader': 'controls/popover/interactive',
  'PopoverSeparator': 'controls/popover/interactive',
  'OptionRow': 'controls/popover/interactive',
  'OptionLink': 'controls/popover/state-matrix',
  'ResizeEdge': 'controls/resize-edge/state-matrix',
  'Window': 'windows/floating-shell/floating-shell',
  'ImmutablePage': 'windows/settings-window/settings-window',
  'SettingsGroup': 'windows/settings-window/settings-window',
  'SettingsPage': 'windows/settings-window/settings-window',
  'SettingsRow': 'windows/settings-window/settings-window',
};

/// DS components an open story builds, by its story id.
const _openStories = <String, String>{
  'AtPill': '10.6',
  'PeekCard': '10.6',
  'DiffHunk': '10.24',
  'DiffView': '10.24',
  'FileRow': '10.8',
  'GraphEnd': '10.19',
  'StackCard': '10.17',
  'DropMenu': '10.10',
  'Toast': '10.23',
  'PushDialog': '11.8',
  'SearchScopes': '10.21',
  'SearchDollar': '10.21',
  'GraphSearch': '10.21',
  'SearchMenu': '10.21',
  'SearchPopover': '10.21',
  'SearchGroup': '10.21',
  'SearchRow': '10.21',
  'SearchMatch': '10.21',
  'SearchTag': '10.21',
  'SearchAvatar': '10.21',
  'RevsetDialog': '10.22',
  'CalloutText': '10.14',
};

/// DS components that never become a catalogue use case, with the reason.
const _noUseCase = <String, String>{
  'Wordmark': 'a path drawn only inside the splash card',
  'TrafficLights': "macOS's native window buttons",
};

void main() {
  test('every DS manifest component has a catalogue use case, an open story or a reason (Story 11.10)', () {
    final manifest = jsonDecode(File(_manifest).readAsStringSync()) as Map<String, Object?>;
    final components = <String>{
      for (final Object? component in manifest['components']! as List<Object?>)
        (component! as Map<String, Object?>)['name']! as String,
    };
    final lists = <String, Set<String>>{
      'covered': _covered.keys.toSet(),
      'openStories': _openStories.keys.toSet(),
      'noUseCase': _noUseCase.keys.toSet(),
    };
    final listed = <String>{for (final Set<String> names in lists.values) ...names};

    expect(components.difference(listed), isEmpty, reason: 'manifest components in no list');
    expect(listed.difference(components), isEmpty, reason: 'listed names not in the manifest (stale)');
    for (final MapEntry<String, Set<String>> a in lists.entries) {
      for (final MapEntry<String, Set<String>> b in lists.entries) {
        if (a.key.compareTo(b.key) < 0) {
          expect(a.value.intersection(b.value), isEmpty, reason: 'in both ${a.key} and ${b.key}');
        }
      }
    }

    final Set<String> paths = catalogueUseCasePaths;
    for (final MapEntry<String, String> entry in _covered.entries) {
      expect(paths, contains(entry.value), reason: '${entry.key}: no use case ${entry.value}');
    }
  });
}
