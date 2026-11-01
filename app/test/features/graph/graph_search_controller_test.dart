// SPDX-License-Identifier: MIT

import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/src/features/graph/graph_search_controller.dart';
import 'package:zanshin/src/features/graph/graph_search_model.dart';
import 'package:zanshin/src/features/graph/graph_search_store.dart';
import 'package:zanshin/src/features/graph/graph_view_model.dart';

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
}
