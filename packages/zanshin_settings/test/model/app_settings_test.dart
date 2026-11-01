// SPDX-License-Identifier: MIT

import 'package:flutter_test/flutter_test.dart';
import 'package:freezed_annotation/freezed_annotation.dart' show CheckedFromJsonException;
import 'package:material_ui/material_ui.dart' show ThemeMode;
import 'package:zanshin_settings/zanshin_settings.dart';

void main() {
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
      'appearance': {'themeMode': 'dark', 'accentSource': 'followMacOS'},
      'layout': {'inspectorWidth': 460.0, 'panelWidth': 300.0},
      'general': {'hideControls': true, 'diffLayout': 'unified'},
      'projects': {'projects': <Object?>[], 'groups': <Object?>[], 'openProject': null},
      'graph': {
        'layout': 'free',
        'detailedCards': true,
        'groupStacks': true,
        'cardWidth': 240.0,
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

  test('the Zanshin accent source survives a JSON round trip', () {
    const settings = AppSettings(appearance: AppearanceSettings(accentSource: AccentSource.zanshin));
    expect(settings.toJson(), {
      'appearance': {'themeMode': 'system', 'accentSource': 'zanshin'},
      'layout': {'inspectorWidth': 460.0, 'panelWidth': 300.0},
      'general': {'hideControls': true, 'diffLayout': 'unified'},
      'projects': {'projects': <Object?>[], 'groups': <Object?>[], 'openProject': null},
      'graph': {
        'layout': 'free',
        'detailedCards': true,
        'groupStacks': true,
        'cardWidth': 240.0,
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
    expect(settings.toJson()['layout'], {'inspectorWidth': 512.0, 'panelWidth': 255.5});
    expect(settings.toJson()['general'], {'hideControls': false, 'diffLayout': 'unified'});
    expect(AppSettings.fromJson(settings.toJson()), settings);
  });

  test('the diff layout defaults to unified and Side by side survives a JSON round trip', () {
    expect(const GeneralSettings().diffLayout, DiffLayoutSetting.unified);
    expect(GeneralSettings.fromJson({'hideControls': false}).diffLayout, DiffLayoutSetting.unified);
    expect(GeneralSettings.fromJson({'diffLayout': 'stacked'}).diffLayout, DiffLayoutSetting.unified);
    const settings = AppSettings(general: GeneralSettings(diffLayout: DiffLayoutSetting.sideBySide));
    expect(settings.toJson()['general'], {'hideControls': true, 'diffLayout': 'sideBySide'});
    expect(AppSettings.fromJson(settings.toJson()), settings);
  });

  test('an out-of-range width is kept as stored; the shell clamps it where it uses it', () {
    expect(LayoutSettings.fromJson({'panelWidth': 900}).panelWidth, 900);
  });

  test('a wrongly typed width or flag throws CheckedFromJsonException', () {
    expect(() => LayoutSettings.fromJson({'panelWidth': 'wide'}), throwsA(isA<CheckedFromJsonException>()));
    expect(() => GeneralSettings.fromJson({'hideControls': 'yes'}), throwsA(isA<CheckedFromJsonException>()));
  });

  test('the graph options default to Free, detailed cards, grouped stacks and 240 px', () {
    const graph = GraphSettings();
    expect(graph.layout, GraphLayoutSetting.free);
    expect(graph.detailedCards, isTrue);
    expect(graph.groupStacks, isTrue);
    expect(graph.cardWidth, 240);
  });

  test('changed graph options survive a JSON round trip', () {
    const settings = AppSettings(
      graph: GraphSettings(
        layout: GraphLayoutSetting.compact,
        detailedCards: false,
        groupStacks: false,
        cardWidth: 300,
      ),
    );
    expect(settings.toJson()['graph'], {
      'layout': 'compact',
      'detailedCards': false,
      'groupStacks': false,
      'cardWidth': 300.0,
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
