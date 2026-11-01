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
}
