// SPDX-License-Identifier: MIT

import 'package:flutter_test/flutter_test.dart';
import 'package:freezed_annotation/freezed_annotation.dart' show CheckedFromJsonException;
import 'package:material_ui/material_ui.dart' show ThemeMode;
import 'package:zanshin_settings/zanshin_settings.dart';

const _seedsJson = <Map<String, Object?>>[
  {'mask': '*.g.dart, *.freezed.dart', 'active': false},
  {'mask': '*.lock', 'active': false},
];

void main() {
  test('the file masks default to the two unticked seeds, also for a file without the key', () {
    const seeds = [FileMask(mask: '*.g.dart, *.freezed.dart'), FileMask(mask: '*.lock')];
    expect(const GeneralSettings().fileMasks, seeds);
    expect(GeneralSettings.fromJson({'hideControls': false}).fileMasks, seeds);
    expect(seeds.every((m) => !m.active), isTrue);
  });

  test('edited file masks survive a JSON round trip and an empty saved list stays empty', () {
    const settings = AppSettings(
      general: GeneralSettings(
        fileMasks: [
          FileMask(mask: '*.arb', active: true),
          FileMask(mask: '*.lock'),
        ],
      ),
    );
    final Map<String, Object?> json = settings.toJson();
    expect((json['general']! as Map<String, Object?>)['fileMasks'], [
      {'mask': '*.arb', 'active': true},
      {'mask': '*.lock', 'active': false},
    ]);
    expect(AppSettings.fromJson(json), settings);
    expect(GeneralSettings.fromJson({'fileMasks': <Object?>[]}).fileMasks, isEmpty);
    expect(() => GeneralSettings.fromJson({'fileMasks': 'x'}), throwsA(isA<CheckedFromJsonException>()));
  });

  test('defaults follow the system theme', () {
    expect(const AppSettings().appearance.themeMode, ThemeMode.system);
  });

  test('a non-default value survives a JSON round trip', () {
    const settings = AppSettings(appearance: AppearanceSettings(themeMode: ThemeMode.dark));
    expect(AppSettings.fromJson(settings.toJson()), settings);
  });

  test('toJson nests the sub-model as a map and encodes the enum by name', () {
    const settings = AppSettings(appearance: AppearanceSettings(themeMode: ThemeMode.dark));
    expect(settings.toJson(), {
      'appearance': {'themeMode': 'dark', 'accentSource': 'followMacOS', 'density': 'compact', 'zoom': 100},
      'layout': {
        'inspectorWidth': 460.0,
        'panelWidth': 300.0,
        'inspectorFilesNarrow': 0.38,
        'inspectorFilesWide': 0.34,
      },
      'general': {
        'hideControls': true,
        'diffLayout': 'unified',
        'diffWordMarks': true,
        'diffWhitespace': 'showAll',
        'diffFileList': 'flat',
        'editor': null,
        'fileMasks': _seedsJson,
        'codeFont': null,
        'codeSize': 11,
      },
      'projects': {'projects': <Object?>[], 'groups': <Object?>[], 'openProject': null},
      'graph': {
        'layout': 'free',
        'detailedCards': true,
        'groupStacks': true,
        'cardWidth': 240.0,
        'showMinimap': true,
        'revsetConfigs': <Object?>[],
        'revsetDefault': 'log',
      },
    });
  });

  test('a missing key takes its default', () {
    expect(AppearanceSettings.fromJson({}).themeMode, ThemeMode.system);
  });

  test('a settings file without accentSource follows the macOS accent', () {
    expect(AppearanceSettings.fromJson({'themeMode': 'dark'}).accentSource, AccentSource.followMacOS);
    expect(AppSettings.fromJson({'appearance': <String, Object?>{}}).appearance.accentSource, AccentSource.followMacOS);
  });

  test('the density defaults to compact, survives a JSON round trip and reads an unknown value as compact', () {
    expect(AppearanceSettings.fromJson(<String, Object?>{}).density, DensitySetting.compact);
    const comfy = AppearanceSettings(density: DensitySetting.comfy);
    expect(AppearanceSettings.fromJson(comfy.toJson()), comfy);
    expect(AppearanceSettings.fromJson(<String, Object?>{'density': 'roomy'}).density, DensitySetting.compact);
  });

  test('the zoom defaults to 100, survives a JSON round trip and keeps an off-step value as stored', () {
    expect(AppearanceSettings.fromJson(<String, Object?>{}).zoom, 100);
    const zoomed = AppearanceSettings(zoom: 125);
    expect(zoomed.toJson()['zoom'], 125);
    expect(AppearanceSettings.fromJson(zoomed.toJson()), zoomed);
    expect(AppearanceSettings.fromJson(<String, Object?>{'zoom': 95}).zoom, 95);
  });

  test('the Zanshin accent source survives a JSON round trip', () {
    const settings = AppSettings(appearance: AppearanceSettings(accentSource: AccentSource.zanshin));
    expect(settings.toJson(), {
      'appearance': {'themeMode': 'system', 'accentSource': 'zanshin', 'density': 'compact', 'zoom': 100},
      'layout': {
        'inspectorWidth': 460.0,
        'panelWidth': 300.0,
        'inspectorFilesNarrow': 0.38,
        'inspectorFilesWide': 0.34,
      },
      'general': {
        'hideControls': true,
        'diffLayout': 'unified',
        'diffWordMarks': true,
        'diffWhitespace': 'showAll',
        'diffFileList': 'flat',
        'editor': null,
        'fileMasks': _seedsJson,
        'codeFont': null,
        'codeSize': 11,
      },
      'projects': {'projects': <Object?>[], 'groups': <Object?>[], 'openProject': null},
      'graph': {
        'layout': 'free',
        'detailedCards': true,
        'groupStacks': true,
        'cardWidth': 240.0,
        'showMinimap': true,
        'revsetConfigs': <Object?>[],
        'revsetDefault': 'log',
      },
    });
    expect(AppSettings.fromJson(settings.toJson()), settings);
  });

  test('the layout widths default to 460 and 300, Hide controls to on', () {
    const settings = AppSettings();
    expect(settings.layout.inspectorWidth, 460);
    expect(settings.layout.panelWidth, 300);
    expect(settings.general.hideControls, isTrue);
  });

  test('a file without layout and general, or with them partial, takes the defaults for what is missing', () {
    expect(AppSettings.fromJson({'appearance': <String, Object?>{}}).layout, const LayoutSettings());
    expect(AppSettings.fromJson({'appearance': <String, Object?>{}}).general, const GeneralSettings());
    final partial = AppSettings.fromJson({
      'layout': {'panelWidth': 360},
      'general': <String, Object?>{},
    });
    expect(partial.layout, const LayoutSettings(panelWidth: 360));
    expect(partial.general.hideControls, isTrue);
  });

  test('changed widths and Hide controls off survive a JSON round trip', () {
    const settings = AppSettings(
      layout: LayoutSettings(inspectorWidth: 512, panelWidth: 255.5),
      general: GeneralSettings(hideControls: false),
    );
    expect(settings.toJson()['layout'], {
      'inspectorWidth': 512.0,
      'panelWidth': 255.5,
      'inspectorFilesNarrow': 0.38,
      'inspectorFilesWide': 0.34,
    });
    expect(settings.toJson()['general'], {
      'hideControls': false,
      'diffLayout': 'unified',
      'diffWordMarks': true,
      'diffWhitespace': 'showAll',
      'diffFileList': 'flat',
      'editor': null,
      'fileMasks': _seedsJson,
      'codeFont': null,
      'codeSize': 11,
    });
    expect(AppSettings.fromJson(settings.toJson()), settings);
  });

  test('the split shares default to 0.38 narrow and 0.34 wide and survive a JSON round trip', () {
    expect(const LayoutSettings().inspectorFilesNarrow, 0.38);
    expect(const LayoutSettings().inspectorFilesWide, 0.34);
    expect(LayoutSettings.fromJson(const <String, Object?>{}).inspectorFilesWide, 0.34);
    const changed = LayoutSettings(inspectorFilesNarrow: 0.5, inspectorFilesWide: 0.25);
    expect(LayoutSettings.fromJson(changed.toJson()), changed);
  });

  test('the diff layout defaults to unified and Side by side survives a JSON round trip', () {
    expect(const GeneralSettings().diffLayout, DiffLayoutSetting.unified);
    expect(GeneralSettings.fromJson({'hideControls': false}).diffLayout, DiffLayoutSetting.unified);
    expect(GeneralSettings.fromJson({'diffLayout': 'stacked'}).diffLayout, DiffLayoutSetting.unified);
    const settings = AppSettings(general: GeneralSettings(diffLayout: DiffLayoutSetting.sideBySide));
    expect(settings.toJson()['general'], {
      'hideControls': true,
      'diffLayout': 'sideBySide',
      'diffWordMarks': true,
      'diffWhitespace': 'showAll',
      'diffFileList': 'flat',
      'editor': null,
      'fileMasks': _seedsJson,
      'codeFont': null,
      'codeSize': 11,
    });
    expect(AppSettings.fromJson(settings.toJson()), settings);
  });

  test('the word marks default to on, off survives a JSON round trip, and an old diffMarks key is ignored', () {
    expect(const GeneralSettings().diffWordMarks, isTrue);
    expect(GeneralSettings.fromJson({'hideControls': false}).diffWordMarks, isTrue);
    const settings = AppSettings(general: GeneralSettings(diffWordMarks: false));
    expect(settings.toJson()['general'], {
      'hideControls': true,
      'diffLayout': 'unified',
      'diffWordMarks': false,
      'diffWhitespace': 'showAll',
      'diffFileList': 'flat',
      'editor': null,
      'fileMasks': _seedsJson,
      'codeFont': null,
      'codeSize': 11,
    });
    expect(AppSettings.fromJson(settings.toJson()), settings);
    for (final style in ['words', 'jj']) {
      final old = GeneralSettings.fromJson({'diffMarks': style});
      expect(old.diffWordMarks, isTrue, reason: style);
      expect(old.toJson().keys, isNot(contains('diffMarks')), reason: style);
    }
    expect(() => GeneralSettings.fromJson({'diffWordMarks': 'off'}), throwsA(isA<CheckedFromJsonException>()));
  });

  test(
    'the whitespace mode defaults to show all, -w survives a JSON round trip, an unknown value reads as show all',
    () {
      expect(const GeneralSettings().diffWhitespace, DiffWhitespaceSetting.showAll);
      expect(GeneralSettings.fromJson({'hideControls': false}).diffWhitespace, DiffWhitespaceSetting.showAll);
      expect(GeneralSettings.fromJson({'diffWhitespace': 'ignoreTabs'}).diffWhitespace, DiffWhitespaceSetting.showAll);
      const settings = AppSettings(general: GeneralSettings(diffWhitespace: DiffWhitespaceSetting.ignoreAll));
      expect(settings.toJson()['general'], {
        'hideControls': true,
        'diffLayout': 'unified',
        'diffWordMarks': true,
        'diffWhitespace': 'ignoreAll',
        'diffFileList': 'flat',
        'editor': null,
        'fileMasks': _seedsJson,
        'codeFont': null,
        'codeSize': 11,
      });
      expect(AppSettings.fromJson(settings.toJson()), settings);
      const amount = GeneralSettings(diffWhitespace: DiffWhitespaceSetting.ignoreChangesInAmount);
      expect(GeneralSettings.fromJson(amount.toJson()), amount);
    },
  );

  test('the file list defaults to flat, tree survives a JSON round trip, an unknown value reads as flat', () {
    expect(const GeneralSettings().diffFileList, DiffFileListSetting.flat);
    expect(GeneralSettings.fromJson({'hideControls': false}).diffFileList, DiffFileListSetting.flat);
    expect(GeneralSettings.fromJson({'diffFileList': 'columns'}).diffFileList, DiffFileListSetting.flat);
    const tree = GeneralSettings(diffFileList: DiffFileListSetting.tree);
    expect(tree.toJson()['diffFileList'], 'tree');
    expect(GeneralSettings.fromJson(tree.toJson()), tree);
  });

  test('the editor defaults to none; a launcher and a custom command survive a JSON round trip', () {
    expect(const GeneralSettings().editor, isNull);
    expect(GeneralSettings.fromJson({'hideControls': false}).editor, isNull);
    for (final editor in ['idea', 'subl {file}:{line}']) {
      final settings = GeneralSettings(editor: editor);
      expect(settings.toJson()['editor'], editor);
      expect(GeneralSettings.fromJson(settings.toJson()), settings);
    }
    expect(() => GeneralSettings.fromJson({'editor': 3}), throwsA(isA<CheckedFromJsonException>()));
  });

  test('the code font defaults to built in and the code size to 11; both survive a JSON round trip', () {
    expect(const GeneralSettings().codeFont, isNull);
    expect(const GeneralSettings().codeSize, 11);
    final old = GeneralSettings.fromJson({'hideControls': false});
    expect(old.codeFont, isNull, reason: 'a file without the keys');
    expect(old.codeSize, 11, reason: 'a file without the keys');
    const settings = GeneralSettings(codeFont: 'Menlo', codeSize: 14);
    expect(settings.toJson()['codeFont'], 'Menlo');
    expect(settings.toJson()['codeSize'], 14);
    expect(GeneralSettings.fromJson(settings.toJson()), settings);
    expect(GeneralSettings.fromJson({'codeSize': 500}).codeSize, 500, reason: 'kept as stored; the view clamps it');
    expect(() => GeneralSettings.fromJson({'codeSize': 'big'}), throwsA(isA<CheckedFromJsonException>()));
  });

  test('an out-of-range width is kept as stored; the shell clamps it where it uses it', () {
    expect(LayoutSettings.fromJson({'panelWidth': 900}).panelWidth, 900);
  });

  test('a wrongly typed width or flag throws CheckedFromJsonException', () {
    expect(() => LayoutSettings.fromJson({'panelWidth': 'wide'}), throwsA(isA<CheckedFromJsonException>()));
    expect(() => GeneralSettings.fromJson({'hideControls': 'yes'}), throwsA(isA<CheckedFromJsonException>()));
  });

  test('the graph options default to Free, detailed cards, grouped stacks, 240 px and the minimap shown', () {
    const graph = GraphSettings();
    expect(graph.layout, GraphLayoutSetting.free);
    expect(graph.detailedCards, isTrue);
    expect(graph.groupStacks, isTrue);
    expect(graph.cardWidth, 240);
    expect(graph.showMinimap, isTrue);
    expect(GraphSettings.fromJson(const <String, Object?>{}).showMinimap, isTrue, reason: 'an older file');
  });

  test('changed graph options survive a JSON round trip', () {
    const settings = AppSettings(
      graph: GraphSettings(
        layout: GraphLayoutSetting.compact,
        detailedCards: false,
        groupStacks: false,
        cardWidth: 300,
        showMinimap: false,
      ),
    );
    expect(settings.toJson()['graph'], {
      'layout': 'compact',
      'detailedCards': false,
      'groupStacks': false,
      'cardWidth': 300.0,
      'showMinimap': false,
      'revsetConfigs': <Object?>[],
      'revsetDefault': 'log',
    });
    expect(AppSettings.fromJson(settings.toJson()), settings);
  });

  test('jj log configurations and the default search survive a JSON round trip', () {
    const settings = AppSettings(
      graph: GraphSettings(
        revsetConfigs: [
          RevsetConfiguration(
            id: 'c-1',
            name: 'Mine, no locks',
            op: RevsetCombine.or,
            rules: [
              RevsetRule(fn: RevsetRuleFunction.mine),
              RevsetRule(fn: RevsetRuleFunction.files, mode: RevsetRuleMode.glob, value: '*.lock', not: true),
              RevsetRule(fn: RevsetRuleFunction.author, value: 'lena', ci: true),
              RevsetRule(fn: RevsetRuleFunction.revset, value: 'trunk()..@', not: true),
            ],
          ),
        ],
        revsetDefault: 'c-1',
      ),
    );
    final Map<String, Object?> json = settings.toJson();
    expect((json['graph']! as Map<String, Object?>)['revsetConfigs'], [
      {
        'id': 'c-1',
        'name': 'Mine, no locks',
        'op': 'or',
        'rules': [
          {'fn': 'mine', 'mode': 'substring', 'value': '', 'ci': false, 'not': false},
          {'fn': 'files', 'mode': 'glob', 'value': '*.lock', 'ci': false, 'not': true},
          {'fn': 'author', 'mode': 'substring', 'value': 'lena', 'ci': true, 'not': false},
          {'fn': 'revset', 'mode': 'substring', 'value': 'trunk()..@', 'ci': false, 'not': true},
        ],
      },
    ]);
    expect(AppSettings.fromJson(json), settings);
    expect(settings.graph.effectiveRevsetDefault, 'c-1');
  });

  test('a default search naming no configuration reads as jj log', () {
    expect(const GraphSettings(revsetDefault: 'gone').effectiveRevsetDefault, revsetDefaultLog);
    expect(const GraphSettings(revsetDefault: 'all').effectiveRevsetDefault, revsetDefaultAll);
  });

  test('a file without graph, or with it partial, takes the defaults for what is missing', () {
    expect(AppSettings.fromJson({'appearance': <String, Object?>{}}).graph, const GraphSettings());
    expect(
      AppSettings.fromJson({
        'graph': {'cardWidth': 320},
      }).graph,
      const GraphSettings(cardWidth: 320),
    );
  });

  test('an unknown graph layout throws CheckedFromJsonException', () {
    expect(() => GraphSettings.fromJson({'layout': 'time'}), throwsA(isA<CheckedFromJsonException>()));
  });

  test('a missing sub-model takes its default', () {
    expect(AppSettings.fromJson({}), const AppSettings());
  });

  test('an unknown key is ignored', () {
    expect(AppSettings.fromJson({'unknown': 1}), const AppSettings());
  });

  test('a wrongly typed sub-model throws CheckedFromJsonException', () {
    expect(() => AppSettings.fromJson({'appearance': 5}), throwsA(isA<CheckedFromJsonException>()));
  });

  test('an unknown enum name throws CheckedFromJsonException', () {
    expect(
      () => AppearanceSettings.fromJson({'themeMode': 'purple'}),
      throwsA(isA<CheckedFromJsonException>()),
    );
  });
}
