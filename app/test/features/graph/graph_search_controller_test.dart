// SPDX-License-Identifier: MIT

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/src/features/graph/graph_search_controller.dart';
import 'package:zanshin/src/features/graph/graph_search_model.dart';
import 'package:zanshin/src/features/graph/graph_search_store.dart';
import 'package:zanshin/src/features/graph/graph_view_model.dart';
import 'package:zanshin_settings/zanshin_settings.dart';

import '../../helpers/fake_graph_search_source.dart';
import '../../helpers/scripted_graph_source.dart';

void main() {
  test('goTo enters Recent by default; recent: false (a rail pick, Story 10.14) leaves it as it was', () async {
    final source = ScriptedGraphSource();
    final model = GraphViewModel();
    final store = MemoryGraphSearchStore();
    final search = GraphSearchController(model: model, source: FakeGraphSearchSource(), store: store);
    addTearDown(() {
      search.dispose();
      model.dispose();
    });
    model.init(source, revset: search.revset);
    await pumpEventQueue();

    search.goTo('b', bookmark: 'main', recent: false);
    expect(model.selected, 'b');
    expect(search.recent, isEmpty);
    expect(store.loadRecent(), isEmpty);
    search.goTo('zzz', commitId: 'czzz', recent: false);
    expect(search.recent, isEmpty);
    expect(search.view, isA<GraphAllView>(), reason: 'a hidden one still switches to all(), persisted');
    expect(store.loadView(), isA<GraphAllView>());

    search.goTo('c', bookmark: 'dev');
    expect(search.recent, <GraphRecent>[const GraphRecentGoTo('c', bookmark: 'dev')]);
  });

  test('Story 10.19: a gap\'s Show in all() reads `\$ all()` and ✕ returns to the default search; a failed show '
      'changes nothing; an active filter is replaced and stays in Recent', () async {
    final source = ScriptedGraphSource();
    final model = GraphViewModel();
    final search = GraphSearchController(
      model: model,
      source: FakeGraphSearchSource(),
      store: MemoryGraphSearchStore(),
    );
    addTearDown(() {
      search.dispose();
      model.dispose();
    });
    model.init(source, revset: search.revset);
    await pumpEventQueue();

    const gap = GraphGapTarget(child: 'a', commitId: 'a', targets: <String>['b']);
    await search.showGap(gap);
    expect(search.view, isNot(isA<GraphAllView>()), reason: 'show refused: nothing changes');
    expect(source.requests, hasLength(1));

    final filter = GraphFilter.author('me');
    search.apply(filter);
    await pumpEventQueue();
    source.parentsOf = <String, List<String>>{
      'a': <String>['h'],
    };
    await search.showGap(gap);
    await pumpEventQueue();
    expect(search.view, isA<GraphAllView>());
    expect(source.requests.last.revset, 'all()');
    expect(search.recent, contains(GraphRecentFilter(filter)));
    search.showDefault();
    await pumpEventQueue();
    expect(search.view, GraphShownView.defaultSearch);
    expect(source.requests.last.revset, 'L');
  });

  group('Story 10.22: the jj log configurations', () {
    const mine = RevsetConfiguration(
      id: 'c1',
      name: 'Mine',
      rules: <RevsetRule>[RevsetRule(fn: RevsetRuleFunction.mine)],
    );
    const lena = RevsetConfiguration(
      id: 'c2',
      name: 'Lena',
      rules: <RevsetRule>[RevsetRule(fn: RevsetRuleFunction.author, value: 'lena')],
    );

    Future<({GraphSearchController search, ScriptedGraphSource source, ValueNotifier<AppSettings> settings})> rig({
      String home = revsetDefaultLog,
      GraphShownView view = GraphShownView.defaultSearch,
    }) async {
      final source = ScriptedGraphSource();
      final model = GraphViewModel();
      final settings = ValueNotifier<AppSettings>(
        AppSettings(
          graph: GraphSettings(revsetConfigs: const <RevsetConfiguration>[mine, lena], revsetDefault: home),
        ),
      );
      final store = MemoryGraphSearchStore()..saveView(view);
      final search = GraphSearchController(
        model: model,
        source: FakeGraphSearchSource(),
        store: store,
        settings: settings,
      );
      addTearDown(() {
        search.dispose();
        model.dispose();
        settings.dispose();
      });
      model.init(source, revset: search.revset);
      await pumpEventQueue();
      return (search: search, source: source, settings: settings);
    }

    test('the default search resolves through the settings: jj log, all() or a configuration', () async {
      expect((await rig()).source.requests.single.revset, 'L');
      expect((await rig(home: revsetDefaultAll)).source.requests.single.revset, 'all()');
      final ({GraphSearchController search, ValueNotifier<AppSettings> settings, ScriptedGraphSource source}) r =
          await rig(home: 'c2');
      expect(r.source.requests.single.revset, 'author(substring:"lena")');
      expect(r.search.defaultSearchRevset, 'author(substring:"lena")');
      r.search.showLog();
      await pumpEventQueue();
      expect(r.search.view, const GraphLogView());
      expect(r.source.requests.last.revset, 'L');
      r.search.showConfig('c1');
      await pumpEventQueue();
      expect(r.source.requests.last.revset, 'mine()');
    });

    test('a shown configuration that is gone reads as the default search, at load and when removed', () async {
      expect((await rig(view: const GraphConfigView('gone'))).search.view, GraphShownView.defaultSearch);

      final ({GraphSearchController search, ValueNotifier<AppSettings> settings, ScriptedGraphSource source}) r =
          await rig(view: const GraphConfigView('c1'));
      expect(r.source.requests.single.revset, 'mine()');
      r.settings.value = r.settings.value.copyWith(
        graph: r.settings.value.graph.copyWith(revsetConfigs: const <RevsetConfiguration>[lena]),
      );
      await pumpEventQueue();
      expect(r.search.view, GraphShownView.defaultSearch);
      expect(r.source.requests.map((q) => q.revset), <String?>['mine()', 'L']);
    });

    test("a change of the shown configuration's expression redraws once; any other change redraws nothing", () async {
      final ({GraphSearchController search, ValueNotifier<AppSettings> settings, ScriptedGraphSource source}) r =
          await rig(view: const GraphConfigView('c2'));
      AppSettings edit(List<RevsetConfiguration> configs, {String? home}) => r.settings.value.copyWith(
        graph: r.settings.value.graph.copyWith(revsetConfigs: configs, revsetDefault: home ?? revsetDefaultLog),
      );
      r.settings.value = edit(<RevsetConfiguration>[
        mine.copyWith(name: 'renamed'),
        lena.copyWith(name: 'also renamed'),
      ]);
      r.settings.value = r.settings.value.copyWith(graph: r.settings.value.graph.copyWith(cardWidth: 300));
      await pumpEventQueue();
      expect(r.source.requests, hasLength(1), reason: 'names, other entries and other settings send nothing');

      r.settings.value = edit(<RevsetConfiguration>[
        mine,
        lena.copyWith(
          rules: const <RevsetRule>[RevsetRule(fn: RevsetRuleFunction.author, value: 'lena', ci: true)],
        ),
      ]);
      await pumpEventQueue();
      expect(r.source.requests.map((q) => q.revset), <String?>[
        'author(substring:"lena")',
        'author(substring-i:"lena")',
      ]);
    });

    test('a change of only the default search redraws a graph that shows the default search, once', () async {
      final ({GraphSearchController search, ValueNotifier<AppSettings> settings, ScriptedGraphSource source}) r =
          await rig();
      r.settings.value = r.settings.value.copyWith(graph: r.settings.value.graph.copyWith(revsetDefault: 'c2'));
      await pumpEventQueue();
      expect(r.search.view, GraphShownView.defaultSearch);
      expect(r.source.requests.map((q) => q.revset), <String?>['L', 'author(substring:"lena")']);
    });

    test('showSaving sends one request with what the save wrote', () async {
      final ({GraphSearchController search, ValueNotifier<AppSettings> settings, ScriptedGraphSource source}) r =
          await rig(view: const GraphConfigView('c2'));
      r.search.showSaving(
        const GraphConfigView('c1'),
        () => r.settings.value = r.settings.value.copyWith(
          graph: r.settings.value.graph.copyWith(
            revsetConfigs: <RevsetConfiguration>[
              mine.copyWith(rules: const <RevsetRule>[RevsetRule(fn: RevsetRuleFunction.mine, not: true)]),
              lena.copyWith(rules: const <RevsetRule>[]),
            ],
          ),
        ),
      );
      await pumpEventQueue();
      expect(r.source.requests.map((q) => q.revset), <String?>['author(substring:"lena")', '~mine()']);
      expect(r.search.view, const GraphConfigView('c1'));
    });
  });
}
