// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/src/features/bookmarks/bookmark_list_model.dart';
import 'package:zanshin/src/features/graph/graph_layout.dart';
import 'package:zanshin/src/features/graph/graph_ports.dart';
import 'package:zanshin/src/features/graph/graph_search_model.dart';
import 'package:zanshin/src/features/graph/recorded_graph_layout.dart';
import 'package:zanshin_core/zanshin_core.dart';

import '../../helpers/fake_bookmark_list.dart';
import '../../helpers/scripted_graph_source.dart';
import '../graph/graph_harness.dart';

/// local main (synced with main@origin), feat rewritten locally (one commit ahead of feat@origin, both on change k2),
/// the untracked release/1.5.x@origin beyond the view, and jj's `git` mirror.
List<Bookmark> _rows() => <Bookmark>[
  localRow('feat', 'k2', synced: false),
  remoteRow('feat', 'git', 'k2'),
  remoteRow(
    'feat',
    'origin',
    'k2',
    synced: false,
    ahead: const RefDistance(lower: 0, upper: 0),
    behind: const RefDistance(lower: 1, upper: 1),
  ),
  localRow('main', 'k1'),
  remoteRow('main', 'git', 'k1'),
  remoteRow('main', 'origin', 'k1'),
  remoteRow('release/1.5.x', 'origin', 'hid', tracked: false, synced: false),
];

Future<BookmarkRig> _rig(List<Bookmark> rows, {GraphLayout Function(GraphRequest request)? respond}) async {
  final rig = BookmarkRig(FakeBookmarkListSource(rows), respond: respond);
  addTearDown(rig.dispose);
  await pumpEventQueue();
  return rig;
}

BookmarkRow _row(BookmarkRig rig, String display) => rig.model.rows.singleWhere((r) => r.display == display);

void main() {
  test(
    'every non-git row in the source order, keyed by (name, remote); a target outside the layout is dimmed',
    () async {
      final BookmarkRig rig = await _rig(_rows());
      expect(rig.model.loaded, isTrue);
      expect(rig.model.rows.map((r) => r.display), <String>[
        'feat',
        'feat@origin',
        'main',
        'main@origin',
        'release/1.5.x@origin',
      ]);
      expect(rig.model.rows.map((r) => r.remote), <String?>[null, 'origin', null, 'origin', 'origin']);
      expect(_row(rig, 'main').key, 'k1');
      expect(_row(rig, 'main').visible, isTrue);
      expect(_row(rig, 'release/1.5.x@origin').visible, isFalse);
      // One lookup and one content page, both at the layout's operation.
      expect(rig.source.finds.single.operationId, 'op1');
      expect(rig.source.finds.single.expression, 'change_id(k2) | change_id(k1) | change_id(hid)');
      expect(rig.source.contents.single.commitIds, <String>['ck2', 'ck1', 'chid']);
      expect(_row(rig, 'release/1.5.x@origin').subject, 'about chid');
      expect(_row(rig, 'release/1.5.x@origin').commitId, 'chid');
      expect(_row(rig, 'release/1.5.x@origin').prefix, 3, reason: 'a hidden target takes the lookup\'s prefix');
      expect(_row(rig, 'main').prefix, 2, reason: 'a shown one the layout\'s');
    },
  );

  test('the state comes from 9.29\'s flags and distances only, never from pairing the targets', () async {
    final BookmarkRig rig = await _rig(_rows());
    // feat and feat@origin share a change id but synced is false: arrows, no ✓.
    expect(
      (_row(rig, 'feat').state, _row(rig, 'feat').count, _row(rig, 'feat').other),
      (
        BookmarkRowState.ahead,
        '1',
        'origin',
      ),
    );
    expect(
      (_row(rig, 'feat@origin').state, _row(rig, 'feat@origin').count, _row(rig, 'feat@origin').other),
      (
        BookmarkRowState.behind,
        '1',
        'feat',
      ),
    );
    expect(_row(rig, 'main').state, BookmarkRowState.synced);
    expect(_row(rig, 'main@origin').state, BookmarkRowState.synced);
    expect(_row(rig, 'release/1.5.x@origin').state, BookmarkRowState.remote);
  });

  test('bookmarkRowState: local only, deleted, not created yet, conflicted, diverged, N+ and not pushed', () {
    (BookmarkRowState, String?, String?) of(Bookmark b, List<Bookmark> all, {bool divergent = false}) =>
        bookmarkRowState(b, all, divergent: divergent);
    final Bookmark solo = localRow('solo', 'a');
    expect(of(solo, <Bookmark>[solo]).$1, BookmarkRowState.local);
    // The untracked remote of that name does not count.
    expect(of(solo, <Bookmark>[solo, remoteRow('solo', 'origin', 'b', tracked: false)]).$1, BookmarkRowState.local);
    expect(of(localRow('gone', null, synced: false), const <Bookmark>[]).$1, BookmarkRowState.deleted);
    expect(of(remoteRow('new', 'origin', null, synced: false), const <Bookmark>[]).$1, BookmarkRowState.notCreated);
    expect(of(localRow('c', 'a', conflicted: true), const <Bookmark>[]).$1, BookmarkRowState.conflicted);
    expect(of(solo, <Bookmark>[solo], divergent: true).$1, BookmarkRowState.divergent);
    final Bookmark both = remoteRow(
      'x',
      'origin',
      'b',
      synced: false,
      ahead: const RefDistance(lower: 2),
      behind: const RefDistance(lower: 1, upper: 1),
    );
    final Bookmark local = localRow('x', 'a', synced: false);
    expect(of(local, <Bookmark>[local, both]), (BookmarkRowState.diverged, null, 'origin'));
    expect(of(both, <Bookmark>[local, both]), (BookmarkRowState.diverged, null, 'x'));
    final Bookmark far = remoteRow('y', 'origin', 'b', synced: false, ahead: const RefDistance(lower: 2));
    expect(of(far, <Bookmark>[far]), (BookmarkRowState.ahead, '2+', 'y'));
    final Bookmark unpushed = localRow('z', 'a', synced: false);
    expect(
      of(unpushed, <Bookmark>[unpushed, remoteRow('z', 'origin', null, synced: false)]).$1,
      BookmarkRowState.notPushed,
    );
  });

  test('a visible pick selects, reveals and pulses without a request, and enters no Recent', () async {
    final BookmarkRig rig = await _rig(_rows());
    final int requests = rig.graphSource.requests.length;
    rig.model.pick(_row(rig, 'main'));
    expect(rig.graph.selected, 'k1');
    expect(rig.graph.pulse.value?.key, 'k1');
    expect(rig.graphSource.requests, hasLength(requests));
    expect(rig.search.recent, isEmpty);
  });

  test('a hidden pick asks once for all(), persists it and lands the target, not @', () async {
    final BookmarkRig rig = await _rig(_rows());
    final int requests = rig.graphSource.requests.length;
    rig.model.pick(_row(rig, 'release/1.5.x@origin'));
    await pumpEventQueue();
    expect(rig.graphSource.requests, hasLength(requests + 1));
    expect(rig.graphSource.requests.last.revset, 'all()');
    expect(rig.search.view, isA<GraphAllView>());
    expect(rig.store.loadView(), isA<GraphAllView>());
    expect(rig.graph.selected, 'hid');
    expect(rig.graph.reveal?.key, 'hid');
    expect(rig.search.recent, isEmpty);
    // The landed all() shows it: the row is no longer dimmed, without another read.
    expect(_row(rig, 'release/1.5.x@origin').visible, isTrue);
    expect(rig.source.reads, 1);
    // A later relayout (Card width issues none at all) keeps the anchor: no jump to @ (prototype defect 1).
    rig.graph.reload();
    await pumpEventQueue();
    expect(rig.graph.reveal, isNull);
  });

  test('a divergent target reads "divergent"; a pick selects its first node', () async {
    GraphLayout layout(GraphRequest request) => handLayout(
      const <(String, int, int)>[('k0', 2, 0), ('cdv1', 1, 0), ('cdv2', 0, 1)],
      workingCopy: 0,
      changeIds: const <String>['k0', 'dv', 'dv'],
      commitIds: const <String>['ck0', 'cdv1', 'cdv2'],
      flags: const <int>[0, RecordedGraphLayout.flagDivergent, RecordedGraphLayout.flagDivergent],
      operationId: 'op1',
    );
    final rig = BookmarkRig(FakeBookmarkListSource(<Bookmark>[localRow('dv', 'dv')]), respond: layout);
    addTearDown(rig.dispose);
    rig.source.commits = <String, List<String>>{
      'dv': <String>['cdv1', 'cdv2'],
    };
    await pumpEventQueue();
    final BookmarkRow row = rig.model.rows.single;
    expect(row.state, BookmarkRowState.divergent);
    expect(row.key, 'cdv1');
    rig.model.pick(row);
    expect(rig.graph.selected, 'cdv1');
  });

  test('a row without a target is not pickable and is dimmed', () async {
    final BookmarkRig rig = await _rig(<Bookmark>[
      localRow('gone', null, synced: false),
      remoteRow('gone', 'origin', 'k1', synced: false),
    ]);
    final BookmarkRow gone = _row(rig, 'gone');
    expect((gone.pickable, gone.visible, gone.state), (false, false, BookmarkRowState.deleted));
    rig.model.pick(gone);
    expect(rig.graph.selected, isNull);
  });

  test('stale: the last rows stay; a visible pick works, a hidden pick is blocked', () async {
    final BookmarkRig rig = await _rig(_rows());
    rig.source.error = staleError('stale');
    rig.graphSource.respond = (_) => throw staleError('stale');
    rig.graph.reload();
    await pumpEventQueue();
    expect(rig.graph.stale, isNotNull);
    expect(rig.model.rows, hasLength(5));
    final BookmarkRow hidden = _row(rig, 'release/1.5.x@origin');
    expect(rig.model.pickBlocked(hidden), isTrue);
    expect(rig.model.pickBlocked(_row(rig, 'main')), isFalse);
    final int requests = rig.graphSource.requests.length;
    rig.model.pick(hidden);
    expect(rig.graphSource.requests, hasLength(requests));
    rig.model.pick(_row(rig, 'main'));
    expect(rig.graph.selected, 'k1');
  });

  test('a stale read sets stale and keeps the rows; the next operation reads again and clears it', () async {
    final BookmarkRig rig = await _rig(_rows());
    rig.source.error = staleError('stale');
    rig.graphSource.respond = (request) => bookmarkLayout(request, op: 'op2');
    rig.graph.reload();
    await pumpEventQueue();
    expect(rig.model.stale, isTrue);
    expect(rig.model.rows, hasLength(5));
    // The graph is not stale: a selection, a reveal or a pulse notifies it, and starts no read.
    final int reads = rig.source.reads;
    rig.graph
      ..select('k1')
      ..goTo('k2');
    await pumpEventQueue();
    expect(rig.source.reads, reads);
    rig.source.error = null;
    rig.graphSource.respond = (request) => bookmarkLayout(request, op: 'op3');
    rig.graph.reload();
    await pumpEventQueue();
    expect(rig.model.stale, isFalse);
  });

  test('another failure keeps the rows with the error; the next operation retries', () async {
    final BookmarkRig rig = await _rig(_rows());
    rig.source.error = const ZanshinFfiException('jj.io_error', 'disk');
    rig.graphSource.respond = (request) => bookmarkLayout(request, op: 'op2');
    rig.graph.reload();
    await pumpEventQueue();
    expect(rig.model.error?.code, 'jj.io_error');
    expect(rig.model.rows, hasLength(5));
    rig.source.error = null;
    rig.graphSource.respond = (request) => bookmarkLayout(request, op: 'op3');
    rig.graph.reload();
    await pumpEventQueue();
    expect(rig.model.error, isNull);
  });

  test('an external jj bookmark create: the row appears once the graph reloads at the new operation', () async {
    final BookmarkRig rig = await _rig(_rows());
    rig.source.list = <Bookmark>[..._rows(), localRow('new', 'k0')];
    // A reload at the same operation reads nothing.
    rig.graph.reload();
    await pumpEventQueue();
    expect(rig.source.reads, 1);
    rig.graphSource.respond = (request) => bookmarkLayout(request, op: 'op2');
    rig.graphSource.emit(const OpHeadsChangedEvent(0, <String>[]));
    await pumpEventQueue();
    expect(rig.source.reads, 2);
    expect(rig.model.rows.last.display, 'new');
  });

  test('reads coalesce: at most one runs and one is queued', () async {
    final BookmarkRig rig = await _rig(_rows());
    rig.source.gate = Completer<void>();
    for (var op = 2; op <= 4; op++) {
      rig.graphSource.respond = (request) => bookmarkLayout(request, op: 'op$op');
      rig.graph.reload();
      await pumpEventQueue();
    }
    expect(rig.source.reads, 2);
    rig.source.gate!.complete();
    rig.source.gate = null;
    await pumpEventQueue();
    expect(rig.source.reads, 3);
  });

  test(
    'Track runs GraphBookmarkTrack through the graph\'s runner; Untrack on a tracked row; none on a local row',
    () async {
      final BookmarkRig rig = await _rig(_rows());
      await rig.model.track(_row(rig, 'release/1.5.x@origin'));
      await rig.model.track(_row(rig, 'main@origin'));
      expect(rig.model.track(_row(rig, 'main')), isNull);
      expect(rig.actions.ran.map((a) => a.command), <String>[
        'jj bookmark track release/1.5.x@origin',
        'jj bookmark untrack main@origin',
      ]);
      expect(rig.actions.ran.first, isA<GraphBookmarkTrack>());
    },
  );
}
